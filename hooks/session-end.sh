#!/usr/bin/env bash
# ABOUTME: SessionEnd hook for cs session management
# ABOUTME: Archives artifacts and logs session completion

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract session information
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

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
    exit 0
fi

# Log session end
echo "" >> "$META_DIR/logs/session.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (ID: $SESSION_ID)" >> "$META_DIR/logs/session.log"

# Count artifacts
ARTIFACT_COUNT=0
if [ -d "$ARTIFACT_DIR" ]; then
    ARTIFACT_COUNT=$(find "$ARTIFACT_DIR" -type f ! -name "MANIFEST.json" ! -name "*.lock" | wc -l | tr -d ' ')
fi

echo "  Artifacts collected: $ARTIFACT_COUNT" >> "$META_DIR/logs/session.log"

# Create archive if artifacts exist
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
    ARCHIVE_DIR="$META_DIR/archives"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/artifacts-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$ARCHIVE_PATH" -C "$META_DIR" artifacts/ 2>/dev/null || true

    if [ -f "$ARCHIVE_PATH" ]; then
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo "  Archive created: $(basename "$ARCHIVE_PATH") ($ARCHIVE_SIZE)" >> "$META_DIR/logs/session.log"
    fi
fi

# Auto-push if enabled
SYNC_CONFIG="$META_DIR/sync.conf"
if [ -f "$SYNC_CONFIG" ] && [ -d "$SESSION_DIR/.git" ]; then
    AUTO_SYNC=$(grep "^auto_sync=" "$SYNC_CONFIG" 2>/dev/null | cut -d= -f2)
    if [ "$AUTO_SYNC" = "on" ]; then
        cd "$SESSION_DIR" || true

        # Check if remote exists
        HAS_REMOTE=0
        if git remote get-url origin >/dev/null 2>&1; then
            HAS_REMOTE=1
        fi

        # Export secrets if password is set
        if [ -n "${CS_SECRETS_PASSWORD:-}" ]; then
            for loc in "$(dirname "$0")/cs-secrets" "$HOME/.local/bin/cs-secrets"; do
                if [ -x "$loc" ]; then
                    "$loc" --session "$CLAUDE_SESSION_NAME" export-file 2>/dev/null || true
                    break
                fi
            done
        fi

        # Stage, commit, and push (or commit locally)
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            # Build descriptive commit message from changed files
            CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null)
            FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
            if [ "$FILE_COUNT" -eq 1 ]; then
                COMMIT_MSG="🔄 $(basename "$CHANGED_FILES")"
            else
                FILE_LIST=$(echo "$CHANGED_FILES" | xargs -n1 basename 2>/dev/null | head -5 | paste -sd', ' -)
                if [ "$FILE_COUNT" -gt 5 ]; then
                    FILE_LIST="$FILE_LIST +$((FILE_COUNT - 5)) more"
                fi
                COMMIT_MSG="🔄 ${FILE_COUNT} files: $FILE_LIST"
            fi
            if git commit -q -m "$COMMIT_MSG" 2>/dev/null; then
                if [ $HAS_REMOTE -eq 1 ]; then
                    if git push -q origin main 2>/dev/null; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-pushed to remote" >> "$META_DIR/logs/session.log"
                    else
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-push failed (will retry next session)" >> "$META_DIR/logs/session.log"
                    fi
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-committed locally (no remote)" >> "$META_DIR/logs/session.log"
                fi
            fi
        fi
    fi
fi

# Clean up lock files
find "$ARTIFACT_DIR" -name "*.lock" -delete 2>/dev/null || true
rm -f "$META_DIR/session.lock" 2>/dev/null || true

echo "Session management cleanup complete" >> "$META_DIR/logs/session.log"
echo "================================================================================" >> "$META_DIR/logs/session.log"

exit 0
