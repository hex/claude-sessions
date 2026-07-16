#!/usr/bin/env bash
# ABOUTME: PostToolUseFailure hook that logs failed tool calls for debugging
# ABOUTME: Writes tool name, error, and timestamp to .cs/local/session.log

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

LOG_FILE="$META_DIR/local/session.log"
if [ ! -d "$(dirname "$LOG_FILE")" ]; then
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
ERROR=$(echo "$INPUT" | jq -r '.error // "no error message"')

# Truncate error to first line and 200 chars to keep logs readable
# || true protects against SIGPIPE from head closing input early
ERROR_SHORT=$(echo "$ERROR" | head -1 | cut -c1-200 || true)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tool failure: $TOOL_NAME - $ERROR_SHORT" >> "$LOG_FILE"

# Count failures for the queue circuit breaker. Reset per task by the drain
# (Stop hook); absent or non-numeric reads as 0. Best-effort — this hook
# stays silent and non-blocking no matter what.
{
    FAILS_FILE="$META_DIR/local/failures"
    CUR=$(cat "$FAILS_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$CUR" in ''|*[!0-9]*) CUR=0;; esac
    printf '%s\n' $((CUR + 1)) > "$FAILS_FILE.tmp" && mv "$FAILS_FILE.tmp" "$FAILS_FILE"
} 2>/dev/null || true

exit 0
