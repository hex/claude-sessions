#!/usr/bin/env bash
# ABOUTME: Stop hook that reminds Claude to update discoveries.md periodically
# ABOUTME: Uses cooldown to avoid nagging - reminds at most once per 5 minutes

set -euo pipefail

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# Belt-and-suspenders: skip if running inside a subagent
# (Stop hooks auto-convert to SubagentStop so this shouldn't fire, but just in case)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

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

# Build the reminder message
REASON="Discoveries check: (1) Review existing entries in $DISCOVERIES_FILE — if any have been disproven or superseded by your recent work, correct or remove them now. (2) If you have new findings to add, use the Task tool with run_in_background to append them. Write findings as regular content — do NOT prepend status metadata like 'N chars - under budget' or similar size checks; those are ephemeral and pollute the file. If nothing to change, just acknowledge and continue."

# Check if discoveries.md exceeds the size budget (default 60KB ≈ 12-15K tokens)
# Override via CS_DISCOVERIES_MAX_SIZE env var (bytes)
MAX_SIZE="${CS_DISCOVERIES_MAX_SIZE:-60000}"
DISCOVERIES_SIZE=$(wc -c < "$DISCOVERIES_FILE" | tr -d ' ')
if [ "$DISCOVERIES_SIZE" -gt "$MAX_SIZE" ]; then
    REASON="$REASON (3) discoveries.md is over budget (${DISCOVERIES_SIZE} bytes, max ${MAX_SIZE}). Summarize the oldest entries into .cs/discoveries.compact.md (append to existing if present), then remove those entries from discoveries.md. Keep the most recent entries intact. Split on ## heading boundaries."
fi

# Return reminder prompt - use "block" + "reason" so Claude sees it
cat << EOF
{
  "decision": "block",
  "reason": "$REASON"
}
EOF

exit 0
