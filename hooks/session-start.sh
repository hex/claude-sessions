#!/usr/bin/env bash
# ABOUTME: SessionStart hook for cs session management
# ABOUTME: Initializes session environment and provides context to Claude

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Skip entirely if running inside a subagent call — the parent session
# handles its own lifecycle events; subagents shouldn't add noise
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

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

# Append structured event to timeline.jsonl (machine-readable narrative log)
TIMELINE_FILE="$META_DIR/timeline.jsonl"
TIMELINE_BRANCH=$(git -C "$SESSION_DIR" branch --show-current 2>/dev/null || echo "")
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "started" \
       --arg source "$SOURCE" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    >> "$TIMELINE_FILE" 2>/dev/null || true

# Auto-pull and crash recovery only on fresh start or resume
# Skip on clear/compact since the session is already running
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "resume" ]; then

# Shadow ref: crash recovery and push protection (worktree-tolerant)
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # Ensure legacy shadow refs are never pushed (refs/worktree/* never are)
    git -C "$SESSION_DIR" config transfer.hideRefs refs/cs 2>/dev/null || true

    # Detect an orphaned shadow ref (previous session crashed). Prefer the
    # per-worktree ref; fall back to the legacy repo-global name.
    SHADOW_REF=""
    if git -C "$SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        SHADOW_REF="refs/worktree/cs/auto"
    elif git -C "$SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        SHADOW_REF="refs/cs/auto"
    fi
    if [ -n "$SHADOW_REF" ]; then
        # Generate a summary of what would be restored
        CRASH_DIFF=$(git -C "$SESSION_DIR" diff --stat HEAD "$SHADOW_REF" -- . 2>/dev/null || true)
        CRASH_FILES=$(git -C "$SESSION_DIR" diff --name-only HEAD "$SHADOW_REF" -- . 2>/dev/null | head -10 || true)
        CRASH_FILE_COUNT=$(echo "$CRASH_FILES" | grep -c . 2>/dev/null || echo "0")

        if [ -n "$CRASH_FILES" ] && [ "$CRASH_FILE_COUNT" -gt 0 ]; then
            # Don't auto-restore — inject into context so Claude can ask the user
            CRASH_CONTEXT="CRASH RECOVERY: The previous session ended without saving (crash or timeout). Autosaved changes were found in ${CRASH_FILE_COUNT} file(s):\n\n${CRASH_FILES}\n\nDiff summary:\n${CRASH_DIFF}\n\nIMPORTANT: Ask the user if they want to restore these changes. To restore, run: git -C \"$SESSION_DIR\" checkout $SHADOW_REF -- . && git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF\nTo discard, run: git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Crash recovery: found ${CRASH_FILE_COUNT} unsaved file(s), awaiting user decision" \
                >> "$META_DIR/logs/session.log"
        else
            # No actual changes — just clean up the orphaned ref
            git -C "$SESSION_DIR" update-ref -d "$SHADOW_REF" 2>/dev/null || true
        fi
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
Session started: $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u +%Y-%m-%dT%H:%M:%SZ))

Session directory: $CLAUDE_SESSION_DIR
Artifacts directory: $CLAUDE_ARTIFACT_DIR

Session metadata is in the .cs/ directory. The session root is your workspace.

This session has:
- Automatic artifact tracking for scripts and configs
- Documentation templates in .cs/ markdown files
- Command logging to .cs/logs/session.log

Key files to maintain:
- .cs/README.md: Update objective and outcome
- .cs/memory/narrative.md: Document findings, observations, and ideas

All scripts and config files are automatically saved to .cs/artifacts/.

IMPORTANT: Secrets (API keys, tokens, passwords) are stored securely in the OS keychain.
Use 'cs -secrets list' to see stored secrets, 'cs -secrets get <name>' to retrieve values.
Never write raw credentials to files - use 'cs -secrets set <name>' to store them securely.

See CLAUDE.md in the session directory for complete documentation protocol.
EOF
)

# Set a key in the machine-local state file (.cs/local/state, gitignored —
# these values differ per machine, so they must never reach the git-synced
# README). Replaces any existing line for the key, collapses duplicates.
# Atomic (tmp+mv). KEEP THE FORMAT IN SYNC WITH bin/cs's _set_local_state.
STATE_FILE="$META_DIR/local/state"
local_state_set() {
    local key="$1" value="$2"
    mkdir -p "$META_DIR/local"
    local tmp="$STATE_FILE.tmp"
    {
        if [ -f "$STATE_FILE" ]; then
            awk -v key="$key" 'index($0, key ":") != 1' "$STATE_FILE"
        fi
        printf '%s: %s\n' "$key" "$value"
    } > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Bind claude_session_id in local state to the live conversation.
# Claude Code forks a new UUID when a conversation is continued past the
# context limit; the old transcript stays on disk, so the recorded UUID
# looks healthy while naming the pre-fork conversation and `cs` resumes
# stale history. The hook input names the conversation actually running,
# so it is authoritative on every source.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ "$SESSION_ID" =~ $UUID_RE ]]; then
    RECORDED_UUID=$(awk '/^claude_session_id:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
    if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then
        local_state_set claude_session_id "$SESSION_ID"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Rebound claude_session_id: ${RECORDED_UUID:-none} -> $SESSION_ID" >> "$META_DIR/logs/session.log"
    fi
fi

# Update last_resumed in local state on resume
if [ "$SOURCE" = "resume" ]; then
    local_state_set last_resumed "$(date '+%Y-%m-%d')"
fi

# A fresh session is attended by definition: drop any stale finished-blink
# marker left by the previous conversation's final Stop.
rm -f "$META_DIR/local/attention" 2>/dev/null || true

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

    # Per-actor digest: shared memory/narrative activity since this actor last looked.
    mkdir -p "$META_DIR/local" 2>/dev/null || true
    WATERMARK_FILE="$META_DIR/local/watermark"
    LAST_SEEN=""
    [ -f "$WATERMARK_FILE" ] && LAST_SEEN=$(cat "$WATERMARK_FILE" 2>/dev/null || true)
    HEAD_SHA=$(git -C "$SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
    if [ -n "$LAST_SEEN" ] && [ -n "$HEAD_SHA" ] && [ "$LAST_SEEN" != "$HEAD_SHA" ] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "$LAST_SEEN" >/dev/null 2>&1; then
        DIGEST=$(git -C "$SESSION_DIR" log --no-merges --format='%an' "$LAST_SEEN..HEAD" -- .cs/memory 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(.*\)$/\2 (\1)/' \
            | paste -sd', ' - 2>/dev/null || true)
        if [ -n "$DIGEST" ]; then
            DYNAMIC="${DYNAMIC}Since your last session — shared memory/narrative activity: ${DIGEST}\n"
        fi
    fi
    # Advance the watermark to current HEAD (also seeds it on first resume).
    [ -n "$HEAD_SHA" ] && echo "$HEAD_SHA" > "$WATERMARK_FILE"

    # Objective from README.md
    OBJECTIVE=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$META_DIR/README.md" 2>/dev/null | head -1 | sed 's/^\[.*\]$//' || true)
    if [ -n "$OBJECTIVE" ] && [ "$OBJECTIVE" != "[Describe what you're trying to accomplish in this session]" ]; then
        DYNAMIC="${DYNAMIC}Objective: ${OBJECTIVE}\n"
    fi

    # Cross-session awareness: show most recently active sibling sessions
    SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
    if [ -d "$SESSIONS_ROOT" ]; then
        SIBLINGS=""
        SIBLING_COUNT=0
        # Sort sibling sessions by session.log mtime (most recent first)
        while IFS= read -r log_file; do
            sibling_dir=$(dirname "$(dirname "$(dirname "$log_file")")")
            [ -d "$sibling_dir/.cs" ] || continue
            sibling_name=$(basename "$sibling_dir")
            [ "$sibling_name" = "$CLAUDE_SESSION_NAME" ] && continue
            sibling_obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$sibling_dir/.cs/README.md" 2>/dev/null | head -1 || true)
            [ -z "$sibling_obj" ] && continue
            [[ "$sibling_obj" == "["*"]" ]] && continue
            SIBLINGS="${SIBLINGS}  ${sibling_name}: ${sibling_obj}\n"
            SIBLING_COUNT=$((SIBLING_COUNT + 1))
            [ "$SIBLING_COUNT" -ge 5 ] && break
        done < <(ls -t "$SESSIONS_ROOT"/*/.cs/logs/session.log 2>/dev/null || true)
        if [ -n "$SIBLINGS" ]; then
            DYNAMIC="${DYNAMIC}Other Sessions:\n${SIBLINGS}"
        fi
    fi

    if [ -n "$DYNAMIC" ]; then
        CONTEXT="${CONTEXT}

--- Session State ---
$(printf '%b' "$DYNAMIC")"
    fi
fi

# Append fresh-rebind notice if cs flagged that the user declined to resume
# the prior conversation. Tells claude not to assume continuity with prior
# turns and points at the lazy-read .cs/ files for prior context. Set by
# bin/cs's _exec_fresh_rebind helper just before exec.
if [ "${CS_FRESH_REBIND:-}" = "1" ]; then
    CONTEXT="${CONTEXT}

--- Fresh Conversation ---
The user explicitly started a fresh conversation in this cs session — the prior conversation's transcript is not loaded. Treat this as a clean break, not a continuation.

For prior context, lazily consult as needed:
- .cs/memory/narrative.md  — findings and decisions from earlier work
- .cs/README.md            — session objective

The new conversation has its own UUID (\$CS_CLAUDE_SESSION_ID). Do not assume continuity with previous turns."
fi

# Append crash recovery info if present
if [ -n "${CRASH_CONTEXT:-}" ]; then
    CONTEXT="${CONTEXT}

--- $(printf '%b' "$CRASH_CONTEXT")"
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
