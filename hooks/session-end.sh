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

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Log session end
echo "" >> "$SESSION_DIR/logs/session.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (ID: $SESSION_ID)" >> "$SESSION_DIR/logs/session.log"

# Count artifacts
ARTIFACT_COUNT=0
if [ -d "$ARTIFACT_DIR" ]; then
    ARTIFACT_COUNT=$(find "$ARTIFACT_DIR" -type f ! -name "MANIFEST.json" ! -name "*.lock" | wc -l | tr -d ' ')
fi

echo "  Artifacts collected: $ARTIFACT_COUNT" >> "$SESSION_DIR/logs/session.log"

# Create archive if artifacts exist
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
    ARCHIVE_DIR="$SESSION_DIR/archives"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/artifacts-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$ARCHIVE_PATH" -C "$SESSION_DIR" artifacts/ 2>/dev/null || true

    if [ -f "$ARCHIVE_PATH" ]; then
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo "  Archive created: $(basename "$ARCHIVE_PATH") ($ARCHIVE_SIZE)" >> "$SESSION_DIR/logs/session.log"
    fi
fi

# Update global session index
GLOBAL_INDEX="$HOME/.claude-sessions/INDEX.md"

if [ ! -f "$GLOBAL_INDEX" ]; then
    cat > "$GLOBAL_INDEX" << 'EOF'
# Claude Code Sessions Index

This file tracks all cs sessions for quick reference.

## Sessions

EOF
fi

# Append session summary to index
cat >> "$GLOBAL_INDEX" << EOF

### $CLAUDE_SESSION_NAME
- **Ended:** $(date '+%Y-%m-%d %H:%M:%S')
- **Location:** $SESSION_DIR
- **Artifacts:** $ARTIFACT_COUNT files
EOF

# Clean up lock files
find "$ARTIFACT_DIR" -name "*.lock" -delete 2>/dev/null || true

echo "Session management cleanup complete" >> "$SESSION_DIR/logs/session.log"
echo "================================================================================" >> "$SESSION_DIR/logs/session.log"

exit 0
