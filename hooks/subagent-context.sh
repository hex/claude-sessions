#!/usr/bin/env bash
# ABOUTME: SubagentStart hook that injects cs session context into subagents
# ABOUTME: Ensures spawned agents know about the session directory and secrets handling

set -euo pipefail

# Read hook input from stdin
cat > /dev/null

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

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

CONTEXT=$(cat << EOF
You are a subagent in a managed Claude Code session: $CLAUDE_SESSION_NAME

Session directory: $SESSION_DIR

Key rules:
- NEVER write raw API keys, tokens, or passwords to files — store them in the session secret store ('cs -secrets set <name>', value on stdin) and reference them by name
- Your final message is your deliverable — the parent reads it directly. Return findings there; do not write them to the session narrative (that notebook is per-actor, kept by the lead) unless you were asked to.
EOF
)

# Feature worktree sessions: subagents inherit the integration contract.
TASK_BRANCH=$(awk '/^task_branch:/ { print $2; exit }' "$SESSION_DIR/.cs/local/state" 2>/dev/null || true)
if [ -n "$TASK_BRANCH" ]; then
    CONTEXT="${CONTEXT}
- This session is a feature worktree on branch $TASK_BRANCH; integration happens only via cs --merge (run by the user) — never merge or delete that branch yourself"
fi

jq -n --arg context "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: $context,
        statusMessage: "Injecting session context..."
    }
}'

exit 0
