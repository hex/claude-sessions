#!/usr/bin/env bash
# ABOUTME: Stop hook that reminds Claude to update the session narrative periodically
# ABOUTME: Cooldown-gated (at most once per 5 minutes); points at .cs/memory/narrative.md

set -euo pipefail

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
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

NARRATIVE_FILE="$META_DIR/memory/narrative.md"
COOLDOWN_FILE="$META_DIR/.narrative-reminder-cooldown"
COOLDOWN_SECONDS=300  # 5 minutes

CURRENT_TIME=$(date +%s)

# Cooldown: don't nag if we reminded recently
if [ -f "$COOLDOWN_FILE" ]; then
    LAST_REMINDER=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    ELAPSED=$((CURRENT_TIME - LAST_REMINDER))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        echo '{"decision": "approve"}'
        exit 0
    fi
fi

# Nothing to nag about until the narrative file exists
if [ ! -f "$NARRATIVE_FILE" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# File modification time (cross-platform)
if [[ "$OSTYPE" == "darwin"* ]]; then
    NARRATIVE_MTIME=$(stat -f %m "$NARRATIVE_FILE" 2>/dev/null || echo "0")
else
    NARRATIVE_MTIME=$(stat -c %Y "$NARRATIVE_FILE" 2>/dev/null || echo "0")
fi

# Recently updated — no reminder needed
NARRATIVE_AGE=$((CURRENT_TIME - NARRATIVE_MTIME))
if [ "$NARRATIVE_AGE" -lt "$COOLDOWN_SECONDS" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Update cooldown marker and remind
echo "$CURRENT_TIME" > "$COOLDOWN_FILE"

REASON="Narrative check: (1) Review existing entries in $NARRATIVE_FILE — if any have been disproven or superseded by your recent work, correct or remove them now. (2) If you have new findings to add, append them as regular content. If nothing to change, just acknowledge and continue."

cat << EOF
{
  "decision": "block",
  "reason": "$REASON"
}
EOF

exit 0
