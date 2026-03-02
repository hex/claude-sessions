#!/usr/bin/env bash
# ABOUTME: SubagentStart hook that injects cs session context into subagents
# ABOUTME: Ensures spawned agents know about session directory, artifacts, and secrets

set -euo pipefail

# Read hook input from stdin
cat > /dev/null

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
ARTIFACT_DIR="${CLAUDE_ARTIFACT_DIR:-}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

CONTEXT=$(cat << EOF
You are a subagent in a managed Claude Code session: $CLAUDE_SESSION_NAME

Session directory: $SESSION_DIR
Artifacts directory: $ARTIFACT_DIR

Key rules:
- NEVER write raw API keys, tokens, or passwords to files
- Scripts and configs are tracked in .cs/artifacts/
- Document findings in .cs/discoveries.md
- Log changes in .cs/changes.md
EOF
)

jq -n --arg context "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: $context,
        statusMessage: "Injecting session context..."
    }
}'

exit 0
