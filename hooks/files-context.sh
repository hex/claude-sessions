#!/usr/bin/env bash
# ABOUTME: PreToolUse-on-Read hook. Injects the description + token estimate
# ABOUTME: for the target file from .cs/files.md as additionalContext.

set -uo pipefail

# Pass through outside cs sessions
[ -n "${CLAUDE_SESSION_NAME:-}" ] || exit 0

META_DIR="${CLAUDE_SESSION_META_DIR:-${CLAUDE_SESSION_DIR:-}/.cs}"
FILES_MD="$META_DIR/files.md"
[ -f "$FILES_MD" ] || exit 0

INPUT=$(cat)
IFS=$'\t' read -r TOOL_NAME FILE_PATH < <(echo "$INPUT" | jq -r '[.tool_name, (.tool_input.file_path // "")] | @tsv' 2>/dev/null)
[ "${TOOL_NAME:-}" = "Read" ] || exit 0
[ -n "${FILE_PATH:-}" ] || exit 0

# Strip the session-dir prefix so we can look up by the relative path used in files.md
SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
SESSION_DIR="${SESSION_DIR%/}"
REL="${FILE_PATH#$SESSION_DIR/}"

# Fast-path: exit cheaply when the target isn't indexed (avoids full awk scan)
grep -Fxq "## $REL" "$FILES_MD" || exit 0

# Find the entry for REL in files.md. Entry shape:
#   ## <path>
#   (optional) description line(s)
#   ~N tokens -- updated YYYY-MM-DD
ENTRY=$(awk -v target="$REL" '
    $0 == "## " target { in_entry = 1; desc = ""; meta = ""; next }
    in_entry && /^~/ { meta = $0; exit }
    in_entry && /^## / { exit }
    in_entry && NF { desc = desc (desc ? " " : "") $0 }
    END {
        if (meta) {
            if (desc) print desc " (" meta ")"
            else print meta
        }
    }
' "$FILES_MD")

[ -n "$ENTRY" ] || exit 0

jq -n --arg ctx "files.md says: $ENTRY" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $ctx
    }
}'
