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
if ! command -v _cs_terminate_jsonl >/dev/null 2>&1; then
    _cs_terminate_jsonl() {
        [ -s "$1" ] || return 0
        [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
        printf '\n' >> "$1" 2>/dev/null || true
    }
fi
# Not in a cs session, do nothing. Resolves from the env under the CLI and
# from the opened directory under front ends that cannot export one.
cs_resolve_session "$INPUT" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Log session end. Ensure the gitignored machine-local dir exists first so an
# append into a missing dir cannot abort this hook (and its cleanup) under set -e.
mkdir -p "$META_DIR/local" 2>/dev/null || true
echo "" >> "$META_DIR/local/session.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (source: $SOURCE, ID: $SESSION_ID)" >> "$META_DIR/local/session.log"

# Append structured event to timeline.jsonl
TIMELINE_FILE="$META_DIR/timeline.jsonl"
TIMELINE_BRANCH=$(git -C "$SESSION_DIR" branch --show-current 2>/dev/null || echo "")
_cs_terminate_jsonl "$TIMELINE_FILE" 2>/dev/null || true
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "ended" \
       --arg source "$SOURCE" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    >> "$TIMELINE_FILE" 2>/dev/null || true

# Delete only the ending conversation's own autosave ref (no longer needed
# after a clean end). A sibling conversation's ref is left untouched, so a
# concurrent session's crash protection is never stripped by this exit.
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        git -C "$SESSION_DIR" update-ref -d "refs/worktree/cs/session/$SESSION_ID" 2>/dev/null || true
    fi
fi

# Clean up the lock, but only one this launch owns. Only `cs` writes a lock, so
# a hook that resolved by walking a directory belongs to another front end and
# is not the owner: closing a desktop conversation on a directory a CLI session
# is live in would otherwise strip that session's lock, letting `cs <name>` open
# a duplicate with no collision menu. A stale lock is still cleared either way, so a
# crashed session does not stay locked out. Ownership cannot be the $$ test
# lib/15-lock.sh uses — a hook is a different process.
if [ "${CS_RESOLVED_FROM:-env}" = "env" ]; then
    rm -f "$META_DIR/session.lock" 2>/dev/null || true
else
    _cs_lock_pid=$(cat "$META_DIR/session.lock" 2>/dev/null | tr -d '[:space:]') || true
    case "${_cs_lock_pid:-}" in
        ''|*[!0-9]*) rm -f "$META_DIR/session.lock" 2>/dev/null || true ;;
        *) kill -0 "$_cs_lock_pid" 2>/dev/null || rm -f "$META_DIR/session.lock" 2>/dev/null || true ;;
    esac
fi

# Regenerate sessions index.md at the sessions root
# CS_SESSIONS_ROOT is not exported into a session, so this used to fall back to
# the session's parent directory unconditionally. That is right for a session
# living under the sessions root and wrong for an adopted one, whose directory
# is an unrelated project path — the index landed in that project's parent.
# Default to the sessions root itself, and only write an index where sessions
# actually live.
# Compare physical against physical, on BOTH sides. The resolver reports a
# physical SESSION_DIR (cd + pwd -P) while the CLI exports a logical one built
# from $HOME, so normalizing only the root stops the index being written for any
# home reached through a symlink (/home -> /var/home, and every /tmp test env).
# ${HOME:-} matches cs-resolve.sh: main never read HOME here, so under set -u
# an unset one turned a step that should skip into an abort.
_cs_root_default="${HOME:-/nonexistent}/.claude-sessions"
SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$_cs_root_default}"
if [ -d "$SESSIONS_ROOT" ]; then
    SESSIONS_ROOT=$(cd "$SESSIONS_ROOT" 2>/dev/null && pwd -P) || SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$_cs_root_default}"
fi
SESSION_DIR_PHYS=$(cd "$SESSION_DIR" 2>/dev/null && pwd -P) || SESSION_DIR_PHYS="$SESSION_DIR"
case "$SESSION_DIR_PHYS" in
    "$SESSIONS_ROOT"/*) : ;;
    *) [ -n "${CS_SESSIONS_ROOT:-}" ] || SESSIONS_ROOT="" ;;
esac
if [ -n "$SESSIONS_ROOT" ] && [ -d "$SESSIONS_ROOT" ]; then
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
