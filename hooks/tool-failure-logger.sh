#!/usr/bin/env bash
# ABOUTME: PostToolUseFailure hook that logs failed tool calls for debugging
# ABOUTME: Writes tool name, error, and timestamp to .cs/logs/session.log

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

LOG_FILE="$META_DIR/logs/session.log"
if [ ! -d "$(dirname "$LOG_FILE")" ]; then
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
ERROR=$(echo "$INPUT" | jq -r '.error // "no error message"')

# Truncate error to first line and 200 chars to keep logs readable
ERROR_SHORT=$(echo "$ERROR" | head -1 | cut -c1-200)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tool failure: $TOOL_NAME - $ERROR_SHORT" >> "$LOG_FILE"

exit 0
