#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that autosaves to a shadow git ref when discovery files are updated
# ABOUTME: Writes to refs/cs/auto using git plumbing, keeping main branch untouched

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

# Check if session has git repo
if [ ! -d "$SESSION_DIR/.git" ]; then
    exit 0
fi

# Read hook input
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only trigger on Edit/Write
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

# Match any discovery file (active, archive, or compact)
DISCOVERIES_FILE=""
case "$FILE_PATH" in
    "$META_DIR/discoveries.md"|"$META_DIR/discoveries.archive.md"|"$META_DIR/discoveries.compact.md")
        DISCOVERIES_FILE="$FILE_PATH"
        ;;
    *)
        exit 0
        ;;
esac

if [ -z "$FILE_PATH" ] || [ ! -f "$DISCOVERIES_FILE" ]; then
    exit 0
fi

# Extract the latest meaningful entry (last heading, bullet, or paragraph)
# Strategy: Look for the last non-empty line that's a heading (##) or bullet (-)
LATEST_ENTRY=""

# Try to find last heading (## Something)
LATEST_HEADING=$(grep "^##" "$DISCOVERIES_FILE" 2>/dev/null | tail -1 | sed 's/^##\+[[:space:]]*//' || true)

# Try to find last bullet point (- Something)
LATEST_BULLET=$(grep "^[[:space:]]*-" "$DISCOVERIES_FILE" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*-[[:space:]]*//' || true)

# Use heading if found, otherwise bullet, otherwise last non-empty line
if [ -n "$LATEST_HEADING" ]; then
    LATEST_ENTRY="$LATEST_HEADING"
elif [ -n "$LATEST_BULLET" ]; then
    LATEST_ENTRY="$LATEST_BULLET"
else
    # Fallback: last non-empty, non-heading line
    LATEST_ENTRY=$(grep -v "^#" "$DISCOVERIES_FILE" 2>/dev/null | grep -v "^[[:space:]]*$" | tail -1 || true)
fi

# Trim whitespace and limit length
LATEST_ENTRY=$(echo "$LATEST_ENTRY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-100)

# Skip if no meaningful entry found
if [ -z "$LATEST_ENTRY" ] || [ "$LATEST_ENTRY" = "Discoveries & Notes" ]; then
    exit 0
fi

# Autosave to shadow ref using git plumbing (does not touch HEAD or main branch)
autosave_to_shadow_ref() {
    cd "$SESSION_DIR" || return 0

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || return 0

    # Create temporary index from current index
    TEMP_INDEX=$(mktemp)
    cp "$GIT_DIR/index" "$TEMP_INDEX"

    # Stage all current files in the temporary index
    GIT_INDEX_FILE="$TEMP_INDEX" git add -A 2>/dev/null || { rm -f "$TEMP_INDEX"; return 0; }

    # Write tree object from temporary index
    tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree 2>/dev/null) || { rm -f "$TEMP_INDEX"; return 0; }
    rm -f "$TEMP_INDEX"

    # Chain onto previous autosave if it exists
    parent=$(git rev-parse -q --verify refs/cs/auto 2>/dev/null || true)
    if [ -n "$parent" ]; then
        commit=$(echo "autosave: $TIMESTAMP" | git commit-tree "$tree" -p "$parent" 2>/dev/null) || return 0
    else
        commit=$(echo "autosave: $TIMESTAMP" | git commit-tree "$tree" 2>/dev/null) || return 0
    fi

    git update-ref refs/cs/auto "$commit" 2>/dev/null || return 0

    echo "[$TIMESTAMP] Autosave: $LATEST_ENTRY" >> "$META_DIR/logs/session.log"
}

if [ "${CS_TEST_SYNC:-}" = "1" ]; then
    autosave_to_shadow_ref
else
    autosave_to_shadow_ref &
fi

exit 0
