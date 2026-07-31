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
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
# The trailing `|| true` matters as much as the parse-check: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) would otherwise abort here as the last command of
# the chain. Exit 2 out of a PreToolUse hook is Claude Code's blocking code.
# Whatever the source managed to define still stands; the check below decides.
# errexit is suspended across the source, not just around it: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) fails INSIDE the sourced file, where set -e fires
# before any outer || can catch it. Exit 2 out of a PreToolUse hook is
# Claude Code's blocking code. Whatever the source defined before failing
# still stands; the check below decides whether it is usable.
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
set +e
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
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
