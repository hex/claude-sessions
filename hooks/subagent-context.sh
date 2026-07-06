#!/usr/bin/env bash
# ABOUTME: SubagentStart hook that injects cs session context into subagents
# ABOUTME: Ensures spawned agents know about the session directory and secrets handling

set -euo pipefail

# Read hook input from stdin
cat > /dev/null

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

CONTEXT=$(cat << EOF
You are a subagent in a managed Claude Code session: $CLAUDE_SESSION_NAME

Session directory: $SESSION_DIR

Key rules:
- NEVER write raw API keys, tokens, or passwords to files
- Document findings in .cs/memory/narrative.md
EOF
)

# Worktree task sessions: subagents inherit the integration contract.
TASK_BRANCH=$(awk '/^task_branch:/ { print $2; exit }' "$SESSION_DIR/.cs/local/state" 2>/dev/null || true)
if [ -n "$TASK_BRANCH" ]; then
    CONTEXT="${CONTEXT}
- This session is a task worktree on branch $TASK_BRANCH; integration happens only via cs --merge (run by the user) — never merge or delete that branch yourself"
fi

jq -n --arg context "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: $context,
        statusMessage: "Injecting session context..."
    }
}'

exit 0
