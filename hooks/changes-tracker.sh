#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that logs file modifications to changes.md
# ABOUTME: Appends timestamped entries for Edit/Write/MultiEdit operations

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
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
    "$SESSION_DIR/changes.md"|"$SESSION_DIR/discoveries.md"|"$SESSION_DIR/README.md"|"$SESSION_DIR/summary.md"|"$SESSION_DIR/CLAUDE.md")
        exit 0
        ;;
esac

# Skip artifacts directory (tracked separately)
if [[ "$FILE_PATH" == "$SESSION_DIR/artifacts/"* ]]; then
    exit 0
fi

# Append to changes.md
CHANGES_MD="$SESSION_DIR/changes.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "- [$TIMESTAMP] $TOOL_NAME: $FILE_PATH" >> "$CHANGES_MD"

exit 0
