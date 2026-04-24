#!/usr/bin/env bash
# ABOUTME: Walks a session workspace and maintains .cs/files.md with per-file
# ABOUTME: token estimates. Preserves hand-written descriptions across runs.

set -uo pipefail

ROOT_ARG="${1:-}"
if [ -n "$ROOT_ARG" ]; then
    ROOT="${ROOT_ARG%/}"
    META_DIR="$ROOT/.cs"
else
    ROOT="${CLAUDE_SESSION_DIR:-}"
    ROOT="${ROOT%/}"
    META_DIR="${CLAUDE_SESSION_META_DIR:-$ROOT/.cs}"
fi

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "files-scan: session dir not found: ${ROOT:-<unset>}" >&2
    exit 1
fi
if [ ! -d "$META_DIR" ]; then
    echo "files-scan: .cs dir not found: $META_DIR" >&2
    exit 1
fi

OUT="$META_DIR/files.md"
TMP="$OUT.tmp.$$"

# Parse existing files.md into a path -> description map.
# Format per entry:
#   ## relative/path
#   (optional) one-line description
#   ~N tokens -- updated YYYY-MM-DD
declare -A DESC
if [ -f "$OUT" ]; then
    current_path=""
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^~[0-9] ]]; then
            current_path=""
        elif [ -n "$current_path" ] && [ -n "$line" ]; then
            DESC["$current_path"]="$line"
        fi
    done < "$OUT"
fi

today=$(date '+%Y-%m-%d')

{
    printf '# Files\n\n'
    while IFS= read -r f; do
        rel="${f#$ROOT/}"
        bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        [ -z "$bytes" ] && bytes=0
        tokens=$(awk -v b="$bytes" 'BEGIN { printf "%d", b / 3.75 + 0.5 }')
        [ "$tokens" = "0" ] && tokens=1
        printf '## %s\n' "$rel"
        if [ -n "${DESC[$rel]:-}" ]; then
            printf '%s\n' "${DESC[$rel]}"
        fi
        printf '~%s tokens -- updated %s\n\n' "$tokens" "$today"
    done < <(
        find "$ROOT" \
            \( -name .git -o -name .cs -o -name node_modules -o -name dist -o -name build \) -prune \
            -o -type f ! -name '.DS_Store' -print \
        | sort
    )
} > "$TMP"

mv "$TMP" "$OUT"
