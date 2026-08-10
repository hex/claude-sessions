#!/usr/bin/env bash
# ABOUTME: Builds the /voice skill's writing corpus from Claude Code transcripts
# ABOUTME: Keeps the user's typed messages, drops harness noise, redacts credential shapes
set -euo pipefail

TRANSCRIPTS_ROOT="${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
VOICE_DIR="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice"
MAX_MESSAGES=4000
SHORT_CHARS=20
PASTE_CHARS=2000

command -v jq >/dev/null 2>&1 || {
    echo "voice: jq is required (brew install jq / apt-get install jq)" >&2
    exit 1
}
if [ ! -d "$TRANSCRIPTS_ROOT" ]; then
    echo "voice: no transcript directory at $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Transcripts sit one level deep (<project>/<session>.jsonl). Subagent
# transcripts sit deeper (<project>/<session>/subagents/agent-*.jsonl) and
# their "user" messages are dispatch prompts, not the user's typing; the
# depth bound excludes them, the name filter is belt and braces.
find "$TRANSCRIPTS_ROOT" -mindepth 2 -maxdepth 2 -name '*.jsonl' ! -name 'agent-*.jsonl' > "$workdir/files"

files_scanned=0
files_failed=0
: > "$workdir/all.jsonl"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    files_scanned=$((files_scanned + 1))
    proj="$(basename "$(dirname "$f")")"
    if ! jq -cR --arg proj "$proj" --argjson paste "$PASTE_CHARS" '
        # A line is credential-shaped if it carries a keyword=value pair, a known
        # token family prefix, credentials embedded in a URL, or a high-entropy
        # run. Prefix families are listed because keyword matching alone misses
        # every token pasted on its own. This stays best-effort by nature: a
        # deny-list cannot enumerate every secret, so the corpus is written to a
        # 0700 directory and the profile is told never to copy anything
        # credential-shaped out of it.
        def looks_secret:
              test("(api[_-]?key|token|secret|password|passwd|bearer)[[:space:]]*[=:][[:space:]]*[^[:space:]]+"; "i")
           or test("bearer[[:space:]]+[A-Za-z0-9._~+/=-]{12,}"; "i")
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
           # A long opaque run, but only when it mixes case AND digits the way
           # encoded secrets do. Requiring all three is what keeps a 40-hex git
           # SHA (no uppercase) and a long absolute path (no digits) out: both
           # are ordinary engineering prose and carry the voice this corpus
           # exists to capture.
           or ([match("[A-Za-z0-9+/=]{40,}"; "g").string]
               | any(test("[a-z]") and test("[A-Z]") and test("[0-9]")));
        fromjson? | select(type == "object")
        | select(.type == "user")
        | select((.isMeta // false) | not)
        | select((.isSidechain // false) | not)
        | (.message.content // "") as $c
        | (if ($c | type) == "string" then $c
           elif ($c | type) == "array"
           then ($c | map(select(type == "object" and .type == "text") | .text) | join(" "))
           else "" end) as $raw
        | ($raw | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $t
        # Claude Code stamps who originated the turn. Only some values mean a
        # human typed it; sdk and system turns are machine-authored and would
        # otherwise be distilled as the user'"'"'s writing voice. An absent field
        # predates the stamp, so it defaults to keeping the message.
        | ((.promptSource // "typed")
           | . as $src
           | ["typed", "queued", "suggestion_accepted"] | index($src) | not) as $machine
        | (if ($t | length) == 0 then "not-typed"
           elif $machine then "machine"
           elif ($t | startswith("Caveat:")) then "sentinel"
           elif ($t | startswith("This session is being continued")) then "sentinel"
           elif ($t | test("<command-name>|<local-command-stdout>|<system-reminder>|Stop hook feedback:|\\[Request interrupted|TASKMASTER|<task-notification>|<teammate-message|<bash-input>|<bash-stdout>|<bash-stderr>")) then "sentinel"
           elif ($t | length) > $paste then "paste"
           else null end) as $drop
        | {ts: (.timestamp // ""), proj: $proj, drop: $drop,
           text: (if $drop != null then ""
                  else ($t | split("\n")
                        | map(if looks_secret then "[redacted line]" else . end)
                        | join("\n"))
                  end)}
    ' "$f" >> "$workdir/all.jsonl" 2>/dev/null; then
        files_failed=$((files_failed + 1))
    fi
done < "$workdir/files"

kept=$(jq -s '[.[] | select(.drop == null)] | length' "$workdir/all.jsonl")
if [ "$kept" -eq 0 ]; then
    echo "voice: no typed messages found under $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

jq -r -s \
    --arg built "$(date '+%Y-%m-%d %H:%M')" \
    --argjson scanned "$files_scanned" \
    --argjson failed "$files_failed" \
    --argjson max "$MAX_MESSAGES" \
    --argjson short "$SHORT_CHARS" '
    map(select(.drop == null)) as $typed
    | (map(select(.drop == "sentinel")) | length) as $n_sentinel
    | (map(select(.drop == "paste")) | length) as $n_paste
    | (map(select(.drop == "not-typed")) | length) as $n_nottyped
    | (map(select(.drop == "machine")) | length) as $n_machine
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
        "Dropped: \($n_sentinel) harness-injected, \($n_paste) pastes over 2000 chars, \($n_nottyped) non-typed, \($n_machine) machine-authored",
        "",
        "---"
      ]
      + ($body | map("[\(.proj), \(.ts[0:10])]\n\(.text)\n---"))
      + ["", "## Short-ack frequency (top \($appendix | length))", ""]
      + ($appendix | map("  \(.n)  \(.text)"))
      ) | join("\n")
' "$workdir/all.jsonl" > "$workdir/corpus.md"

mkdir -p "$VOICE_DIR"
chmod 700 "$VOICE_DIR"
mv "$workdir/corpus.md" "$VOICE_DIR/corpus.md"
echo "voice: corpus built at $VOICE_DIR/corpus.md ($kept typed messages considered)"
