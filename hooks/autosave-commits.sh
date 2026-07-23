#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that autosaves to a shadow git ref on every Write/Edit
# ABOUTME: Crash recovery for all session files via refs/worktree/cs/session/<uuid>, logs narrative edits

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Check if session has git repo (worktree-tolerant: .git may be a file).
# The resolved git dir is reused for the temp-index copy below; it can be
# relative to SESSION_DIR, which is fine since the autosave cd's there.
GIT_DIR=$(git -C "$SESSION_DIR" rev-parse --git-dir 2>/dev/null) || exit 0
[ -n "$GIT_DIR" ] || exit 0

# Read hook input
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only trigger on Edit/Write
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

# Each conversation autosaves to its own per-worktree ref, keyed on the live
# conversation UUID, so concurrent sessions on one checkout never share or
# clobber each other's snapshot chain. A missing/malformed id can't key a ref.
SESSION_UUID=$(echo "$INPUT" | jq -r '.session_id // empty')
_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[[ "$SESSION_UUID" =~ $_UUID_RE ]] || exit 0
SESSION_REF="refs/worktree/cs/session/$SESSION_UUID"

# Extract a log entry if this is a narrative file edit
LATEST_ENTRY=""
case "$FILE_PATH" in
    "$META_DIR"/memory/narrative*.md)
        # Try to find last heading (## Something)
        LATEST_HEADING=$(grep "^##" "$FILE_PATH" 2>/dev/null | tail -1 | sed 's/^#\{1,\}[[:space:]]*//' || true)
        # Try to find last bullet point (- Something)
        LATEST_BULLET=$(grep "^[[:space:]]*-" "$FILE_PATH" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*-[[:space:]]*//' || true)
        if [ -n "$LATEST_HEADING" ]; then
            LATEST_ENTRY="$LATEST_HEADING"
        elif [ -n "$LATEST_BULLET" ]; then
            LATEST_ENTRY="$LATEST_BULLET"
        else
            LATEST_ENTRY=$(grep -v "^#" "$FILE_PATH" 2>/dev/null | grep -v "^[[:space:]]*$" | tail -1 || true)
        fi
        LATEST_ENTRY=$(echo "$LATEST_ENTRY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-100)
        if [ "$LATEST_ENTRY" = "Session narrative" ]; then
            LATEST_ENTRY=""
        fi
        ;;
esac

# Autosave to shadow ref using git plumbing (does not touch HEAD or main branch)
# Fires on ALL Write/Edit — protects all files, not just the narrative
autosave_to_shadow_ref() {
    cd "$SESSION_DIR" || return 0

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Create temporary index from current index
    TEMP_INDEX=$(mktemp)
    cp "$GIT_DIR/index" "$TEMP_INDEX"

    # Stage all current files in the temporary index
    GIT_INDEX_FILE="$TEMP_INDEX" git add -A 2>/dev/null || { rm -f "$TEMP_INDEX"; return 0; }

    # Write tree object from temporary index
    tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree 2>/dev/null) || { rm -f "$TEMP_INDEX"; return 0; }
    rm -f "$TEMP_INDEX"

    # Record the HEAD this snapshot sits on, so crash recovery can tell whether
    # HEAD has since moved (commit/rebase) and the blanket restore would splice
    # a stale snapshot over diverged history. Absent (unborn HEAD) => no trailer,
    # which recovery reads as "unknown base" and refuses the blanket restore.
    base=$(git rev-parse -q --verify HEAD 2>/dev/null || true)
    msg="autosave: $TIMESTAMP"
    [ -n "$base" ] && msg="$msg

cs-base: $base"

    # Chain onto this conversation's previous autosave if it exists
    parent=$(git rev-parse -q --verify "$SESSION_REF" 2>/dev/null || true)
    if [ -n "$parent" ]; then
        commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" -p "$parent" 2>/dev/null) || return 0
    else
        commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" 2>/dev/null) || return 0
    fi

    git update-ref "$SESSION_REF" "$commit" 2>/dev/null || return 0

    if [ -n "$LATEST_ENTRY" ]; then
        echo "[$TIMESTAMP] Autosave: $LATEST_ENTRY" >> "$META_DIR/local/session.log"
    fi
}

if [ "${CS_TEST_SYNC:-}" = "1" ]; then
    autosave_to_shadow_ref
else
    autosave_to_shadow_ref &
fi

exit 0
