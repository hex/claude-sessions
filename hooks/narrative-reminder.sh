#!/usr/bin/env bash
# ABOUTME: Stop hook that reminds Claude to update the session narrative periodically
# ABOUTME: Cooldown-gated (at most once per 5 minutes); tracks the newest .cs/memory/narrative.*.md

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

# Claude just finished a turn: raise the machine-local attention flag the
# statusline blinks until the user next interacts. Cleared by scope-prompt.sh
# on the next prompt and by session-start.sh at launch. Lives in .cs/local/
# (per-machine state, never git-synced). Raised before the cooldown gates so
# every turn end signals, not just the ones that remind.
mkdir -p "$META_DIR/local" 2>/dev/null || true
touch "$META_DIR/local/attention" 2>/dev/null || true

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

# Per-actor narratives: track the most recently modified narrative.*.md.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
for _nf in "$META_DIR"/memory/narrative*.md; do
    [ -f "$_nf" ] || continue
    if [[ "$OSTYPE" == "darwin"* ]]; then
        _m=$(stat -f %m "$_nf" 2>/dev/null || echo 0)
    else
        _m=$(stat -c %Y "$_nf" 2>/dev/null || echo 0)
    fi
    if [ "$_m" -ge "$NARRATIVE_MTIME" ]; then
        NARRATIVE_MTIME="$_m"
        NARRATIVE_FILE="$_nf"
    fi
done

# Nothing to nag about until a narrative file exists
if [ -z "$NARRATIVE_FILE" ]; then
    echo '{"decision": "approve"}'
    exit 0
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
