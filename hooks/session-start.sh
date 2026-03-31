#!/usr/bin/env bash
# ABOUTME: SessionStart hook for cs session management
# ABOUTME: Initializes session environment and provides context to Claude

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract session information
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

# Check if we're in a cs session
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    # Not in a cs session, do nothing
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
ARTIFACT_DIR="${CLAUDE_ARTIFACT_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    # Session directory doesn't exist, something is wrong
    exit 0
fi

# Log session start
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started (source: $SOURCE, ID: $SESSION_ID)" >> "$META_DIR/logs/session.log"
echo "  Working directory: $CWD" >> "$META_DIR/logs/session.log"
echo "" >> "$META_DIR/logs/session.log"

# Auto-pull and crash recovery only on fresh start or resume
# Skip on clear/compact since the session is already running
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "resume" ]; then

# Auto-pull if enabled (runs in background to not block session start)
SYNC_CONFIG="$META_DIR/sync.conf"
if [ -f "$SYNC_CONFIG" ] && [ -d "$SESSION_DIR/.git" ]; then
    AUTO_SYNC=$(grep "^auto_sync=" "$SYNC_CONFIG" 2>/dev/null | cut -d= -f2)
    if [ "$AUTO_SYNC" = "on" ]; then
        (
            cd "$SESSION_DIR" || exit 0

            # Check if remote exists
            if ! git remote get-url origin >/dev/null 2>&1; then
                # Local-only mode - skip auto-pull
                exit 0
            fi

            if git fetch -q origin 2>/dev/null; then
                # Check if upstream is configured
                if ! git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
                    # Try to set up upstream tracking automatically
                    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
                    if ! git branch --set-upstream-to=origin/$CURRENT_BRANCH $CURRENT_BRANCH 2>/dev/null; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-pull skipped: upstream tracking not configured" >> "$META_DIR/logs/session.log"
                        exit 0
                    fi
                fi

                BEHIND=$(git rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo "0")
                if [ "$BEHIND" -gt 0 ]; then
                    if git pull --rebase -q origin main 2>/dev/null; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-pulled $BEHIND commit(s) from remote" >> "$META_DIR/logs/session.log"

                        # Import secrets if secrets.enc was updated and password is set
                        if [ -f "$META_DIR/secrets.enc" ] && [ -n "${CS_SECRETS_PASSWORD:-}" ]; then
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
        ) > /dev/null 2>&1 &
    fi
fi

# Shadow ref: crash recovery and push protection
if [ -d "$SESSION_DIR/.git" ]; then
    # Ensure shadow refs are never pushed
    git -C "$SESSION_DIR" config transfer.hideRefs refs/cs 2>/dev/null || true

    # Recover from orphaned shadow ref (previous session crashed)
    if git -C "$SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        git -C "$SESSION_DIR" checkout refs/cs/auto -- . >/dev/null 2>&1 || true
        git -C "$SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recovered autosaved changes from previous session" \
            >> "$META_DIR/logs/session.log"
    fi
fi

fi # end startup/resume guard

# Export environment variables for the session via CLAUDE_ENV_FILE
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    cat >> "$CLAUDE_ENV_FILE" << EOF
export CLAUDE_SESSION_NAME="$CLAUDE_SESSION_NAME"
export CLAUDE_SESSION_DIR="$SESSION_DIR"
export CLAUDE_SESSION_META_DIR="$META_DIR"
export CLAUDE_ARTIFACT_DIR="$ARTIFACT_DIR"
EOF
fi

# Provide context to Claude about the session
CONTEXT=$(cat << EOF
You are working in a managed Claude Code session: $CLAUDE_SESSION_NAME

Session directory: $CLAUDE_SESSION_DIR
Artifacts directory: $CLAUDE_ARTIFACT_DIR

Session metadata is in the .cs/ directory. The session root is your workspace.

This session has:
- Automatic artifact tracking for scripts and configs
- Documentation templates in .cs/ markdown files
- Command logging to .cs/logs/session.log

Key files to maintain:
- .cs/README.md: Update objective and outcome
- .cs/discoveries.md: Document findings, observations, and ideas
- .cs/changes.md: Automatically logs file modifications

All scripts and config files are automatically saved to .cs/artifacts/.

IMPORTANT: Secrets (API keys, tokens, passwords) are stored securely in the OS keychain.
Use 'cs -secrets list' to see stored secrets, 'cs -secrets get <name>' to retrieve values.
Never write raw credentials to files - use 'cs -secrets set <name>' to store them securely.

See CLAUDE.md in the session directory for complete documentation protocol.
EOF
)

# Dynamic context: add session state info on resume
if [ "$SOURCE" = "resume" ] && [ -d "$SESSION_DIR/.git" ]; then
    DYNAMIC=""

    # Time since last session activity
    LAST_LOG_TIME=$(tail -1 "$META_DIR/logs/session.log" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1 || true)
    if [ -n "$LAST_LOG_TIME" ]; then
        DYNAMIC="${DYNAMIC}Last activity: ${LAST_LOG_TIME}\n"
    fi

    # Recent commits since last session
    COMMIT_COUNT=$(git -C "$SESSION_DIR" rev-list --count --since="7 days ago" HEAD 2>/dev/null || echo "0")
    if [ "$COMMIT_COUNT" -gt 0 ]; then
        RECENT_FILES=$(git -C "$SESSION_DIR" diff --name-only "HEAD~${COMMIT_COUNT}" HEAD 2>/dev/null | head -5 | xargs -n1 basename 2>/dev/null | paste -sd', ' - 2>/dev/null || true)
        DYNAMIC="${DYNAMIC}Recent commits: ${COMMIT_COUNT} in last 7 days"
        if [ -n "$RECENT_FILES" ]; then
            DYNAMIC="${DYNAMIC} (${RECENT_FILES})"
        fi
        DYNAMIC="${DYNAMIC}\n"
    fi

    # Objective from README.md
    OBJECTIVE=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$META_DIR/README.md" 2>/dev/null | head -1 | sed 's/^\[.*\]$//' || true)
    if [ -n "$OBJECTIVE" ] && [ "$OBJECTIVE" != "[Describe what you're trying to accomplish in this session]" ]; then
        DYNAMIC="${DYNAMIC}Objective: ${OBJECTIVE}\n"
    fi

    if [ -n "$DYNAMIC" ]; then
        CONTEXT="${CONTEXT}

--- Session State ---
$(printf '%b' "$DYNAMIC")"
    fi
fi

# Return additional context as JSON
jq -n --arg context "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $context,
        statusMessage: "Loading session..."
    }
}'

exit 0
