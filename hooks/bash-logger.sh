#!/usr/bin/env bash
# ABOUTME: PreToolUse hook that logs every Bash command to session.log
# ABOUTME: Creates an audit trail of all commands Claude runs during a session

# No set -e: this hook must never block a command from running
set -uo pipefail

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# shellcheck source=cs-resolve.sh
[ -r "$_cs_lib" ] && . "$_cs_lib"
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Only run in cs sessions
cs_resolve_session "" || exit 0

META_DIR="${CLAUDE_SESSION_META_DIR:-${CLAUDE_SESSION_DIR:-}/.cs}"
if [ -z "$META_DIR" ] || [ ! -d "$META_DIR/local" ]; then
    exit 0
fi

# Read hook input
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name' 2>/dev/null)
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$COMMAND" ]; then
    exit 0
fi

# Truncate long commands for the log (keep first 200 chars)
if [ ${#COMMAND} -gt 200 ]; then
    COMMAND="${COMMAND:0:200}..."
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] BASH: $COMMAND" >> "$META_DIR/local/session.log"

exit 0
