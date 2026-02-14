#!/usr/bin/env bash
# ABOUTME: Stop hook that reminds Claude to update discoveries.md periodically
# ABOUTME: Uses cooldown to avoid nagging - reminds at most once per 5 minutes

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

DISCOVERIES_FILE="$META_DIR/discoveries.md"
COOLDOWN_FILE="$META_DIR/.discoveries-reminder-cooldown"
COOLDOWN_SECONDS=300  # 5 minutes

CURRENT_TIME=$(date +%s)

# Check cooldown - don't nag if we reminded recently
if [ -f "$COOLDOWN_FILE" ]; then
    LAST_REMINDER=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    ELAPSED=$((CURRENT_TIME - LAST_REMINDER))

    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        # Still in cooldown period
        echo '{"decision": "approve"}'
        exit 0
    fi
fi

# Check if discoveries.md exists and when it was last modified
if [ ! -f "$DISCOVERIES_FILE" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Get file modification time
if [[ "$OSTYPE" == "darwin"* ]]; then
    DISCOVERIES_MTIME=$(stat -f %m "$DISCOVERIES_FILE" 2>/dev/null || echo "0")
else
    DISCOVERIES_MTIME=$(stat -c %Y "$DISCOVERIES_FILE" 2>/dev/null || echo "0")
fi

# If discoveries.md was modified recently (within cooldown period), no reminder needed
DISCOVERIES_AGE=$((CURRENT_TIME - DISCOVERIES_MTIME))
if [ "$DISCOVERIES_AGE" -lt "$COOLDOWN_SECONDS" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Update cooldown marker
echo "$CURRENT_TIME" > "$COOLDOWN_FILE"

# Return reminder prompt - use "block" + "reason" so Claude sees it
cat << EOF
{
  "decision": "block",
  "reason": "Discoveries check: (1) Review existing entries in $DISCOVERIES_FILE — if any have been disproven or superseded by your recent work, correct or remove them now. (2) If you have new findings to add, use the Task tool with run_in_background to append them. If nothing to change, just acknowledge and continue."
}
EOF

exit 0
