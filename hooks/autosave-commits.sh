#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that autosaves to a shadow git ref on every Write/Edit
# ABOUTME: Crash recovery for all session files via refs/worktree/cs/session/<uuid>, logs narrative edits

set -euo pipefail

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# shellcheck source=cs-resolve.sh
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
# errexit is suspended across the source, not just around it: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) fails INSIDE the sourced file, where set -e fires
# before any outer || can catch it. Exit 2 out of a PreToolUse hook is
# Claude Code's blocking code. Whatever the source defined before failing
# still stands; the check below decides whether it is usable.
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
set +e
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Only run in cs sessions
cs_resolve_session "" || exit 0

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
