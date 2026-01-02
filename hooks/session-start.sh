#!/usr/bin/env bash
# ABOUTME: SessionStart hook for cs session management
# ABOUTME: Initializes session environment and provides context to Claude

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract session information
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Check if we're in a cs session
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    # Not in a cs session, do nothing
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
ARTIFACT_DIR="${CLAUDE_ARTIFACT_DIR:-}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    # Session directory doesn't exist, something is wrong
    exit 0
fi

# Log session start
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started (ID: $SESSION_ID)" >> "$SESSION_DIR/logs/session.log"
echo "  Working directory: $CWD" >> "$SESSION_DIR/logs/session.log"
echo "" >> "$SESSION_DIR/logs/session.log"

# Auto-pull if enabled (runs in background to not block session start)
SYNC_CONFIG="$SESSION_DIR/sync.conf"
if [ -f "$SYNC_CONFIG" ] && [ -d "$SESSION_DIR/.git" ]; then
    AUTO_SYNC=$(grep "^auto_sync=" "$SYNC_CONFIG" 2>/dev/null | cut -d= -f2)
    if [ "$AUTO_SYNC" = "on" ]; then
        (
            cd "$SESSION_DIR" || exit 0
            if git fetch -q origin 2>/dev/null; then
                BEHIND=$(git rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo "0")
                if [ "$BEHIND" -gt 0 ]; then
                    if git pull --rebase -q origin main 2>/dev/null; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-pulled $BEHIND commit(s) from remote" >> "$SESSION_DIR/logs/session.log"

                        # Import secrets if secrets.enc was updated and password is set
                        if [ -f "$SESSION_DIR/secrets.enc" ] && [ -n "${CS_SECRETS_PASSWORD:-}" ]; then
                            for loc in "$(dirname "$0")/cs-secrets" "$HOME/.local/bin/cs-secrets"; do
                                if [ -x "$loc" ]; then
                                    "$loc" --session "$CLAUDE_SESSION_NAME" import-file 2>/dev/null || true
                                    break
                                fi
                            done
                        fi
                    fi
                fi
            fi
        ) &
    fi
fi

# Export environment variables for the session via CLAUDE_ENV_FILE
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    cat >> "$CLAUDE_ENV_FILE" << EOF
export CLAUDE_SESSION_NAME="$CLAUDE_SESSION_NAME"
export CLAUDE_SESSION_DIR="$SESSION_DIR"
export CLAUDE_ARTIFACT_DIR="$ARTIFACT_DIR"
EOF
fi

# Provide context to Claude about the session
CONTEXT=$(cat << EOF
You are working in a managed Claude Code session: $CLAUDE_SESSION_NAME

Session directory: $CLAUDE_SESSION_DIR
Artifacts directory: $CLAUDE_ARTIFACT_DIR

This session has:
- Automatic artifact tracking for scripts and configs
- Documentation templates in markdown files
- Command logging to logs/session.log

Key files to maintain:
- README.md: Update objective and outcome
- discoveries.md: Document findings, observations, and ideas
- changes.md: Automatically logs file modifications

All scripts and config files are automatically saved to artifacts/.

IMPORTANT: Environment variables, API keys, access tokens, and credentials for this session
may be stored in the artifacts directory. When you need credentials or env configuration,
check \$CLAUDE_ARTIFACT_DIR first (look for .env, .envrc, credentials.*, or similar files).

See CLAUDE.md in the session directory for complete documentation protocol.
EOF
)

# Return additional context as JSON
jq -n --arg context "$CONTEXT" '{
    additionalContext: $context
}'

exit 0
