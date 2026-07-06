#!/usr/bin/env bash
# ABOUTME: SessionEnd hook for cs session management
# ABOUTME: Logs session completion, records the timeline event, regenerates the sessions index

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
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Log session end
echo "" >> "$META_DIR/local/session.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (source: $SOURCE, ID: $SESSION_ID)" >> "$META_DIR/local/session.log"

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

# Delete shadow autosave refs (no longer needed after clean session end);
# refs/worktree/* deletion only affects this checkout's ref.
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
    git -C "$SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
fi

# Clean up lock files
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

echo "Session management cleanup complete" >> "$META_DIR/local/session.log"
echo "================================================================================" >> "$META_DIR/local/session.log"

exit 0
