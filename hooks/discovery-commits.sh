#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that creates git commits when discoveries.md is updated
# ABOUTME: Extracts the latest discovery entry and uses it as the commit message

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

# Only trigger on Edit/Write to discoveries.md
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" != "$META_DIR/discoveries.md" ]; then
    exit 0
fi

# Parse the latest discovery entry from discoveries.md
DISCOVERIES_FILE="$META_DIR/discoveries.md"
if [ ! -f "$DISCOVERIES_FILE" ]; then
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

# Create commit with discovery entry as message
(
    cd "$SESSION_DIR" || exit 0

    # Stage all changes (including the discovery)
    git add -A 2>/dev/null || true

    # Only commit if there are changes
    if ! git diff --cached --quiet 2>/dev/null; then
        # Prefix with emoji for discovery commits
        COMMIT_MSG="📝 $LATEST_ENTRY"

        if git commit -q -m "$COMMIT_MSG" 2>/dev/null; then
            # Log the discovery commit
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$TIMESTAMP] Discovery commit: $LATEST_ENTRY" >> "$META_DIR/logs/session.log"

            # If remote exists and auto-sync is enabled, push
            SYNC_CONFIG="$META_DIR/sync.conf"
            if [ -f "$SYNC_CONFIG" ]; then
                AUTO_SYNC=$(grep "^auto_sync=" "$SYNC_CONFIG" 2>/dev/null | cut -d= -f2)
                if [ "$AUTO_SYNC" = "on" ] && git remote get-url origin >/dev/null 2>&1; then
                    if git push -q origin main 2>/dev/null; then
                        echo "[$TIMESTAMP] Pushed discovery commit to remote" >> "$META_DIR/logs/session.log"
                    fi
                fi
            fi
        fi
    fi
) &

exit 0
