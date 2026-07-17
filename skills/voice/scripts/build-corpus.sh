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
        | (if ($t | length) == 0 then "not-typed"
           elif ($t | startswith("Caveat:")) then "sentinel"
           elif ($t | startswith("This session is being continued")) then "sentinel"
           elif ($t | test("<command-name>|<local-command-stdout>|<system-reminder>|Stop hook feedback:|\\[Request interrupted|TASKMASTER|<task-notification>|<teammate-message|<bash-input>|<bash-stdout>|<bash-stderr>")) then "sentinel"
           elif ($t | length) > $paste then "paste"
           else null end) as $drop
        | {ts: (.timestamp // ""), proj: $proj, drop: $drop,
           text: (if $drop != null then ""
                  else ($t | split("\n")
                        | map(if test("(api[_-]?key|token|secret|password|bearer)[[:space:]]*[=:][[:space:]]*[^[:space:]]+"; "i")
                                 or test("sk-[A-Za-z0-9]{16,}")
                                 or test("[A-Za-z0-9+/=]{40,}")
                              then "[redacted line]" else . end)
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
        "Dropped: \($n_sentinel) harness-injected, \($n_paste) pastes over 2000 chars, \($n_nottyped) non-typed",
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
