#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that logs file modifications to changes.md
# ABOUTME: Appends timestamped entries for Edit/Write/MultiEdit operations

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Read hook input
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only track Edit, Write, MultiEdit
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "MultiEdit" ]]; then
    exit 0
fi

# Skip if no file path
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Skip session documentation files
case "$FILE_PATH" in
    "$META_DIR/changes.md"|"$META_DIR/discoveries.md"|"$META_DIR/discoveries.compact.md"|"$META_DIR/README.md"|"$META_DIR/summary.md"|"$SESSION_DIR/CLAUDE.md")
        exit 0
        ;;
esac

# Skip artifacts directory (tracked separately)
if [[ "$FILE_PATH" == "$META_DIR/artifacts/"* ]]; then
    exit 0
fi

# Append to changes.md
CHANGES_MD="$META_DIR/changes.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "- [$TIMESTAMP] $TOOL_NAME: $FILE_PATH" >> "$CHANGES_MD"

# Incrementally refresh files.md token estimate when the target is indexed.
# Does not create or append new entries — session-start.sh seeds the index.
FILES_MD="$META_DIR/files.md"
if [ -f "$FILES_MD" ] && [ -f "$FILE_PATH" ]; then
    SESSION_DIR_NOSLASH="${SESSION_DIR%/}"
    REL="${FILE_PATH#$SESSION_DIR_NOSLASH/}"
    if [ "$REL" != "$FILE_PATH" ] && grep -Fxq "## $REL" "$FILES_MD"; then
        BYTES=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ')
        [ -z "$BYTES" ] && BYTES=0
        TOKENS=$(awk -v b="$BYTES" 'BEGIN { printf "%d", b / 3.75 + 0.5 }')
        [ "$TOKENS" = "0" ] && TOKENS=1
        TODAY=$(date '+%Y-%m-%d')
        NEW_META="~$TOKENS tokens -- updated $TODAY"
        FILES_TMP="$FILES_MD.tmp.$$"
        awk -v target="$REL" -v newmeta="$NEW_META" '
            BEGIN { in_target = 0 }
            $0 == "## " target { in_target = 1; print; next }
            in_target && /^~[0-9]/ { print newmeta; in_target = 0; next }
            in_target && /^## / { print newmeta; print ""; in_target = 0 }
            { print }
        ' "$FILES_MD" > "$FILES_TMP" && mv "$FILES_TMP" "$FILES_MD"
    fi
fi

exit 0
