#!/usr/bin/env bash
# ABOUTME: PreToolUse hook that logs every Bash command to session.log
# ABOUTME: Creates an audit trail of all commands Claude runs during a session

# No set -e: this hook must never block a command from running
set -uo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

META_DIR="${CLAUDE_SESSION_META_DIR:-${CLAUDE_SESSION_DIR:-}/.cs}"
if [ -z "$META_DIR" ] || [ ! -d "$META_DIR/logs" ]; then
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] BASH: $COMMAND" >> "$META_DIR/logs/session.log"

exit 0
