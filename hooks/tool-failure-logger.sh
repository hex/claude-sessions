#!/usr/bin/env bash
# ABOUTME: PostToolUseFailure hook that logs failed tool calls for debugging
# ABOUTME: Writes tool name, error, and timestamp to .cs/local/session.log

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# shellcheck source=cs-resolve.sh
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Only run in cs sessions
cs_resolve_session "$INPUT" || exit 0

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
