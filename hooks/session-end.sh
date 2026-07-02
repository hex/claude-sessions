#!/usr/bin/env bash
# ABOUTME: SessionEnd hook for cs session management
# ABOUTME: Archives artifacts and logs session completion

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Skip entirely if running inside a subagent call
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# Extract session information
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
SOURCE=$(echo "$INPUT" | jq -r '.source // "user_exit"')

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
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (source: $SOURCE, ID: $SESSION_ID)" >> "$META_DIR/logs/session.log"

# Append structured event to timeline.jsonl
TIMELINE_FILE="$META_DIR/timeline.jsonl"
TIMELINE_BRANCH=$(git -C "$SESSION_DIR" branch --show-current 2>/dev/null || echo "")
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "ended" \
       --arg source "$SOURCE" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    >> "$TIMELINE_FILE" 2>/dev/null || true

# Skip artifact archiving on sigint for faster exit
if [ "$SOURCE" = "sigint" ]; then
    echo "  Skipping artifact archive (interrupted)" >> "$META_DIR/logs/session.log"
fi

# Count artifacts
ARTIFACT_COUNT=0
if [ -d "$ARTIFACT_DIR" ]; then
    ARTIFACT_COUNT=$(find "$ARTIFACT_DIR" -type f ! -name "MANIFEST.json" ! -name "*.lock" | wc -l | tr -d ' ')
fi

echo "  Artifacts collected: $ARTIFACT_COUNT" >> "$META_DIR/logs/session.log"

# Create archive if artifacts exist (skip on sigint for faster exit)
if [ "$ARTIFACT_COUNT" -gt 0 ] && [ "$SOURCE" != "sigint" ]; then
    ARCHIVE_DIR="$META_DIR/archives"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/artifacts-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$ARCHIVE_PATH" -C "$META_DIR" artifacts/ 2>/dev/null || true

    if [ -f "$ARCHIVE_PATH" ]; then
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo "  Archive created: $(basename "$ARCHIVE_PATH") ($ARCHIVE_SIZE)" >> "$META_DIR/logs/session.log"
    fi
fi

# Delete shadow autosave ref (no longer needed after clean session end)
if [ -d "$SESSION_DIR/.git" ]; then
    git -C "$SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
fi

# Clean up lock files
find "$ARTIFACT_DIR" -name "*.lock" -delete 2>/dev/null || true
rm -f "$META_DIR/session.lock" 2>/dev/null || true

# Regenerate sessions index.md at the sessions root
SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$(dirname "$SESSION_DIR")}"
if [ -d "$SESSIONS_ROOT" ]; then
    INDEX_FILE="$SESSIONS_ROOT/index.md"
    {
        echo "# Sessions"
        echo ""
        echo "> Auto-generated on session end. Do not edit manually."
        echo ""
        echo "| Session | Status | Objective | Created |"
        echo "|---------|--------|-----------|---------|"
        for dir in "$SESSIONS_ROOT"/*/; do
            [ -d "$dir/.cs" ] || continue
            local_name=$(basename "$dir")
            local_readme="$dir/.cs/README.md"
            [ -f "$local_readme" ] || continue
            # Extract frontmatter fields (always in first few lines)
            local_status=$(head -6 "$local_readme" | grep '^status:' | sed 's/^status: *//' || true)
            local_created=$(head -6 "$local_readme" | grep '^created:' | sed 's/^created: *//' || true)
            # Extract objective
            local_obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$local_readme" 2>/dev/null | head -1 || true)
            [[ "$local_obj" == "["*"]" ]] && local_obj=""
            echo "| [${local_name}](${local_name}/.cs/README.md) | ${local_status:-—} | ${local_obj:-—} | ${local_created:-—} |"
        done
    } > "$INDEX_FILE" 2>/dev/null || true
fi

echo "Session management cleanup complete" >> "$META_DIR/logs/session.log"
echo "================================================================================" >> "$META_DIR/logs/session.log"

exit 0
