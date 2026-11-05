#!/usr/bin/env bash
# ABOUTME: Builds the /write-as-me skill's writing corpus from Claude Code transcripts
# ABOUTME: Keeps the user's typed messages, drops harness noise, redacts credential shapes
set -euo pipefail

TRANSCRIPTS_ROOT="${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
VOICE_DIR="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice"
MAX_MESSAGES=4000
SHORT_CHARS=20
PASTE_CHARS=2000

# Claude Code names a project directory after the directory claude launched in,
# with every character that is not a letter or digit turned into "-". A project
# matching one of these jq regexes is a test session: a harness or a probe
# script wrote its prompts, so none of them is the user's typing.
TEST_SESSION_PROJECTS=(
    '^-private-tmp-'          # /tmp on macOS: agent scratchpads and E2E harness checkouts
    '^-tmp-'                  # /tmp as Linux spells it
    '^-private-var-folders-'  # $TMPDIR on macOS, where mktemp -d puts a suite's throwaway project
    '--cs-local-'             # a session's .cs/local/, cs's machine-local state, where live probes launch claude
)

command -v jq >/dev/null 2>&1 || {
    echo "write-as-me: jq is required (brew install jq / apt-get install jq)" >&2
    exit 1
}
if [ ! -d "$TRANSCRIPTS_ROOT" ]; then
    echo "write-as-me: no transcript directory at $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

# Shared by the transcript pass and the supplementary-source pass.
LOOKS_SECRET_DEF='
    # A line is credential-shaped if it carries a keyword=value pair, a known
    # token family prefix, credentials embedded in a URL, or a high-entropy
    # run. Prefix families are listed because keyword matching alone misses
    # every token pasted on its own. This stays best-effort by nature: a
    # deny-list cannot enumerate every secret, so the corpus is written to a
    # 0700 directory and the profile is told never to copy anything
    # credential-shaped out of it.
    def looks_secret:
          test("(api[_-]?key|token|secret|password|passwd|bearer)[[:space:]]*[=:][[:space:]]*[^[:space:]]+"; "i")
       # The bearer value must look like a token, not a word. A plain 12+
       # character run matches ordinary English (bearer authentication,
       # bearer authorization, bearer responsibility), so require at least
       # one non-letter in the captured value.
       or ([match("bearer[[:space:]]+([A-Za-z0-9._~+/=-]{12,})"; "gi").captures[0].string]
           | any(test("[^A-Za-z]")))
       or test("\\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}")
       or test("\\bglpat-[A-Za-z0-9_-]{16,}")
       or test("\\bxox[baprs]-[A-Za-z0-9-]{10,}")
       or test("\\bsk[-_](live|test)[-_][A-Za-z0-9]{16,}"; "i")
       # Anchored on the issuer rather than on `sk-` alone. A bare `sk-`
       # rule fires on ordinary hyphenated prose (task-, risk-, disk-), and
       # a run of 16 unbroken alnum never matches this shape anyway because
       # the `api03-` segment breaks it.
       or test("\\bsk-ant-[A-Za-z0-9_-]{16,}"; "i")
       or test("\\bnpm_[A-Za-z0-9]{16,}")
       or test("\\bAKIA[0-9A-Z]{12,}")
       or test("\\bAIza[A-Za-z0-9_-]{20,}")
       or test("\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}")
       or test("[a-z][a-z0-9+.-]*://[^/[:space:]]+:[^@[:space:]]+@")
       # A long opaque run, but only when it looks encoded rather than
       # typed. Three conditions, each excluding a real shape that is not a
       # secret. Rejecting pure lowercase hex keeps a 40-char git SHA out.
       # Counting slashes keeps deep paths out: `/` sits in the class above,
       # so a build path stays one unbroken run, and any digit in it (IL2CPP
       # in a Unity tree, a versioned directory) would otherwise qualify; an
       # encoded blob carries at most an incidental slash while a path is
       # mostly slashes. Requiring a digit and a letter keeps prose runs out.
       # Case is deliberately NOT required in both directions: an all-caps
       # token of 40+ characters is a credential, and there is no benign
       # engineering shape of that form.
       # NOTE: no apostrophes in this block. The whole jq program is a
       # single-quoted bash string, so one would terminate it.
       or ([match("[A-Za-z0-9+/=]{40,}"; "g").string]
           | any(test("[0-9]") and test("[A-Za-z]")
                 and ((test("^[0-9a-f]+$")) | not)
                 and (([match("/"; "g")] | length) <= 1)));
'

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Transcripts sit one level deep (<project>/<session>.jsonl). Subagent
# transcripts sit deeper (<project>/<session>/subagents/agent-*.jsonl) and
# their "user" messages are dispatch prompts, not the user's typing; the
# depth bound excludes them, the name filter is belt and braces.
find "$TRANSCRIPTS_ROOT" -mindepth 2 -maxdepth 2 -name '*.jsonl' ! -name 'agent-*.jsonl' > "$workdir/files"
test_projects="$(printf '%s\n' "${TEST_SESSION_PROJECTS[@]}" | jq -R . | jq -cs .)"

files_scanned=0
files_failed=0
: > "$workdir/all.jsonl"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    files_scanned=$((files_scanned + 1))
    proj="$(basename "$(dirname "$f")")"
    # Read whole with --rawfile and split inside jq, not line by line with -R:
    # jq 1.7.1's -R splits a multibyte character 4095 bytes into a line and
    # puts a replacement character in its place, and a transcript line runs
    # that long whenever a message carries tool output or an image.
    if ! jq -cn --rawfile t "$f" --arg proj "$proj" --argjson paste "$PASTE_CHARS" \
            --argjson test_projects "$test_projects" "$LOOKS_SECRET_DEF"'
        ($test_projects | any(. as $re | $proj | test($re))) as $test_session
        | $t | split("\n")[]
        | fromjson? | select(type == "object")
        | select(.type == "user")
        | select((.isMeta // false) | not)
        | select((.isSidechain // false) | not)
        | (.message.content // "") as $c
        | (if ($c | type) == "string" then $c
           elif ($c | type) == "array"
           then ($c | map(select(type == "object" and .type == "text") | .text) | join(" "))
           else "" end) as $raw
        | ($raw | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $t
        # Claude Code records a paste between <pasted_content id="X"> and
        # </pasted_content id="X">. The block is text the user pasted, so it
        # goes, and what they typed around it stays.
        | ($t | gsub("<pasted_content id=\"(?<id>[^\"]*)\">[\\s\\S]*?</pasted_content id=\"\\k<id>\">"; "")
              | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $typed
        # Claude Code stamps who originated the turn. Only some values mean a
        # human typed it; sdk and system turns are machine-authored and would
        # otherwise be distilled as the user'"'"'s writing voice. An absent field
        # predates the stamp, so it defaults to keeping the message.
        | ((.promptSource // "typed")
           | . as $src
           | ["typed", "queued", "suggestion_accepted"] | index($src) | not) as $src_machine
        # cs hands claude a kick as its launch prompt, which Claude Code stamps
        # "typed". Patterns mirror handoff_arg (lib/40-state.sh) and spawn_kick
        # (lib/75-launch.sh); test_cs_launch_kicks_dropped pins both wordings.
        | ($src_machine
           or ($t | test("^Continue from the pending rotation handoff(: read \\.cs/handoffs/|\\.$)"))
           or ($t | test("^Spawned by .* Send results with: cs -msg "))
           or ($t | test("^Your (brief is \\.cs/brief\\.md: read it first\\.|walk-away queue is armed with [0-9]+ task)"))) as $machine
        | (if ($t | length) == 0 then "not-typed"
           elif $machine then "machine"
           elif ($t | startswith("Caveat:")) then "sentinel"
           elif ($t | startswith("This session is being continued")) then "sentinel"
           elif ($t | test("<command-name>|<local-command-stdout>|<system-reminder>|Stop hook feedback:|\\[Request interrupted|TASKMASTER|<task-notification>|<teammate-message|<bash-input>|<bash-stdout>|<bash-stderr>")) then "sentinel"
           elif $test_session then "test-session"
           # A side agent relays its note through a draft the user sends
           # unedited, which Claude Code stamps typed: its own side-agent
           # wrapper, and the claude-council heads-up mod Tell Claude draft
           # ("A side check by codex (not you) flagged this:", also seen as
           # "raised this:").
           elif ($t | startswith("Here is a note offered by a side agent:")) then "side-note"
           elif ($t | startswith("A side check by ")) then "side-check"
           elif ($typed | length) == 0 then "tagged-paste"
           elif ($typed | length) > $paste then "paste"
           else null end) as $drop
        | {ts: (.timestamp // ""), proj: $proj, drop: $drop, cut: ($typed != $t),
           text: (if $drop != null then ""
                  else ($typed | split("\n")
                        | map(if looks_secret then "[redacted line]" else . end)
                        | join("\n"))
                  end)}
    ' >> "$workdir/all.jsonl" 2>/dev/null; then
        files_failed=$((files_failed + 1))
    fi
done < "$workdir/files"

kept=$(jq -s '[.[] | select(.drop == null)] | length' "$workdir/all.jsonl")
if [ "$kept" -eq 0 ]; then
    echo "write-as-me: no typed messages found under $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

sources=0
for src in "$VOICE_DIR/sources/"*.md; do
    [ -f "$src" ] && sources=$((sources + 1))
done

jq -r -s \
    --arg built "$(date '+%Y-%m-%d %H:%M')" \
    --argjson scanned "$files_scanned" \
    --argjson failed "$files_failed" \
    --argjson max "$MAX_MESSAGES" \
    --argjson short "$SHORT_CHARS" \
    --argjson sources "$sources" '
    map(select(.drop == null)) as $typed
    | (map(select(.drop == "sentinel")) | length) as $n_sentinel
    | (map(select(.drop == "paste")) | length) as $n_paste
    | (map(select(.drop == "not-typed")) | length) as $n_nottyped
    | (map(select(.drop == "machine")) | length) as $n_machine
    | (map(select(.drop == "test-session")) | length) as $n_test
    | (map(select(.drop == "side-note")) | length) as $n_side_note
    | (map(select(.drop == "side-check")) | length) as $n_side_check
    | (map(select(.drop == "tagged-paste")) | length) as $n_tagged
    | ($typed | map(select(.cut)) | length) as $n_cut
    | ($typed | map(select((.text | length) < $short and (.text != "[redacted line]")))) as $acks
    | ($typed | map(select((.text | length) >= $short))) as $long
    | ($long | group_by(.text) | map(max_by(.ts)) | sort_by(.ts) | reverse) as $uniq
    | ($uniq[0:$max]) as $body
    | ($acks | group_by(.text) | map({text: .[0].text, n: length})
       | sort_by(-.n) | .[0:50]) as $appendix
    | ([
        "# Voice corpus",
        "",
        "Built: \($built)",
        "Files scanned: \($scanned) (\($failed) unreadable)",
        ("Messages kept: \($body | length) (from \($long | length) typed, "
         + "\(($long | length) - ($uniq | length)) duplicates collapsed)"
         + (if ($uniq | length) > $max then ", capped at \($max)" else "" end)),
        "Short acks in appendix: \($acks | length) occurrences, \($appendix | length) distinct",
        ("Dropped: \($n_sentinel) harness-injected, \($n_paste) pastes over 2000 chars, \($n_nottyped) non-typed, "
         + "\($n_machine) machine-authored, \($n_test) from test sessions, \($n_side_note) side-agent notes, "
         + "\($n_side_check) side checks, \($n_tagged) tagged pastes with no typed text"),
        "Tagged pastes cut from typed messages: \($n_cut)"
      ]
      + (if $sources > 0
         then ["Supplementary sources: \($sources) file\(if $sources == 1 then "" else "s" end)"]
         else [] end)
      + ["", "---"]
      + ($body | map("[\(.proj), \(.ts[0:10])]\n\(.text)\n---"))
      + ["", "## Short-ack frequency (top \($appendix | length))", ""]
      + ($appendix | map("  \(.n)  \(.text)"))
      ) | join("\n")
' "$workdir/all.jsonl" > "$workdir/corpus.md"

# Supplementary sources are writing no transcript holds (an exported chat,
# say), kept by hand under sources/. The corpus is rebuilt wholesale, so they
# are appended on every build, in name order, each under a heading naming its
# file. A source's own leading title line is dropped in favour of that heading,
# and its lines pass the same credential-shape redactor as the transcripts: a
# hand-scrubbed file is still one missed paste away from the corpus.
for src in "$VOICE_DIR/sources/"*.md; do
    [ -f "$src" ] || continue
    {
        printf '\n## Supplementary source: %s\n\n' "$(basename "$src")"
        # Whole, for the reason the transcript read gives; the final newline is
        # dropped before the split so it adds no empty line of its own.
        awk 'NR == 1 && /^# / { next } { print }' "$src" \
            | jq -rn --rawfile s /dev/stdin "$LOOKS_SECRET_DEF"' $s | rtrimstr("\n") | split("\n")[]
                | if looks_secret then "[redacted line]" else . end'
    } >> "$workdir/corpus.md"
done

mkdir -p "$VOICE_DIR"
chmod 700 "$VOICE_DIR"
chmod 600 "$workdir/corpus.md"
mv "$workdir/corpus.md" "$VOICE_DIR/corpus.md"
echo "write-as-me: corpus built at $VOICE_DIR/corpus.md ($kept typed messages considered)"
