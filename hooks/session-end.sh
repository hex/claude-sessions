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
# SessionEnd names why the conversation ended in `reason`: clear, resume,
# logout, prompt_input_exit or other. "missing" marks a payload without one.
END_REASON=$(echo "$INPUT" | jq -r '.reason // "missing"')

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# cs-shared.sh is build.sh's copy of lib/02-shared.sh (the tmux window title).
# Same guard, same reasons.
_cs_shared="$(dirname "$0")/cs-shared.sh"
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
# shellcheck source=cs-shared.sh
[ -r "$_cs_shared" ] && "${BASH:-/bin/bash}" -n "$_cs_shared" 2>/dev/null && . "$_cs_shared"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
# Without the library there is no telling whether the session keeps its log in
# a vault, so nothing is logged rather than risk writing it in plaintext.
if ! command -v cs_private_dir >/dev/null 2>&1; then
    cs_private_dir() { return 1; }
fi
if ! command -v cs_local_dir >/dev/null 2>&1; then
    cs_local_dir() { return 1; }
fi
# A write this hook cannot make is skipped without a word, and the link check
# on appends and new directories lives in cs-shared.sh; without the library
# they are made unchecked, as they were before the check existed.
CS_WRITE_QUIET=1
if ! command -v cs_append_inside >/dev/null 2>&1; then
    cs_append_inside() { local f="$1"; shift; { "$@" >> "$f"; } 2>/dev/null; }
fi
if ! command -v cs_write_atomic >/dev/null 2>&1; then
    cs_write_atomic() { return 1; }
fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
if ! command -v _cs_terminate_jsonl >/dev/null 2>&1; then
    _cs_terminate_jsonl() {
        [ -s "$1" ] || return 0
        [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
        cs_append_inside "$1" printf '\n' || true
    }
fi
# Not in a cs session, do nothing. Resolves from the env under the CLI and
# from the opened directory under front ends that cannot export one.
cs_resolve_session "$INPUT" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# This pane no longer runs the session: the tmux window, which is the tab, is
# named after the cs sessions still running in its other panes, or names
# itself again when none is left. A /clear ends here too, and its SessionStart
# claims the pane back straight after. Only the launched conversation
# releases it: a `claude -p` run from inside the session inherits its
# TMUX_PANE, and its end must not take the lead's claim with it. Under
# `cs <name> --remote` the window is the server's, named remote:<name> by its
# launch, and the phone lead never claimed it (session-start.sh): while
# .cs/local/remote.pid names a server running remote-control for this session
# (_remote_server_pid) the window is left as it is.
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v cs_tmux_title_window >/dev/null 2>&1 \
    && command -v cs_is_lead >/dev/null 2>&1 && cs_is_lead \
    && ! { command -v _remote_server_pid >/dev/null 2>&1 \
        && _remote_server_pid "$META_DIR" "${CLAUDE_SESSION_NAME:-}" >/dev/null; }; then
    cs_tmux_title_window "$TMUX_PANE" ""
fi

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Log session end. Ensure the gitignored machine-local dir exists first so an
# append into a missing dir cannot abort this hook (and its cleanup) under set -e.
# An encrypted session logs into its vault; while the vault is locked the log
# goes nowhere, never into .cs/local.
# A .cs/local git tracks is left as git has it (cs_local_dir).
# The directory is made as the last level of a .cs that is there, never with
# -p: `cs -rm <name> --force` can remove the session while its claude is still
# ending, after the check above, and mkdir -p would build the removed session
# again from its path. Every other write below is a file in a directory that
# already exists, so with the session gone each one fails and writes nothing.
_cs_end_make_local_dir() {
    [ -n "$LOCAL_DIR" ] && [ ! -d "$LOCAL_DIR" ] || return 0
    if command -v _cs_refuses_write >/dev/null 2>&1; then
        ! _cs_refuses_write cs_mkdir_inside "$LOCAL_DIR" "$META_DIR" || return 1
    fi
    mkdir "$LOCAL_DIR" 2>/dev/null || [ -d "$LOCAL_DIR" ]
}
LOCAL_DIR=$(cs_local_dir "$META_DIR") || LOCAL_DIR=""
_cs_end_make_local_dir || true
if _log_dir=$(cs_private_dir "$META_DIR"); then SESSION_LOG="$_log_dir/session.log"; else SESSION_LOG=/dev/null; fi
cs_append_inside "$SESSION_LOG" printf '%s\n' "" "$(date '+%Y-%m-%d %H:%M:%S') - Session ended (source: $END_REASON, ID: $SESSION_ID)" || true

# Append structured event to timeline.jsonl
TIMELINE_FILE="$META_DIR/timeline.jsonl"
TIMELINE_BRANCH=$(git -C "$SESSION_DIR" branch --show-current 2>/dev/null || echo "")
_cs_terminate_jsonl "$TIMELINE_FILE" 2>/dev/null || true
cs_append_inside "$TIMELINE_FILE" jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "ended" \
       --arg source "$END_REASON" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    || true

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
# A /clear or /resume ends the conversation but not the claude that holds the
# lock, so the lock stays until that claude exits.
# A claude started from inside the session (a `claude -p` from the Bash tool,
# a plugin, a script) inherits the exported contract, so it resolves from the
# env like the lead; it is not the lead, and its end must not strip the lead's
# lock either. cs_is_lead tells the two apart by the launch pid and the
# lead's claim on it.
# Even the lead removes a live lock only when it names its own launch
# (CS_LEAD_PID, the pid cs wrote): a forced open from another terminal
# replaces the lock with its own pid while this conversation runs on, and that
# second launch still holds the session when this one ends.
# Under `cs <name> --remote` the launch is the remote-control server, and the
# lead is a conversation it started from the phone: the server holds the lock
# after that conversation ends, so the lock stays while .cs/local/remote.pid
# names a server still running remote-control for this session
# (_remote_server_pid, cs-shared.sh). The server's own exit releases it.
_cs_lock_owner="" _cs_lock_clear=1
if [ "${CS_RESOLVED_FROM:-env}" = "env" ] \
    && { ! command -v cs_is_nested_child >/dev/null 2>&1 || ! cs_is_nested_child; }; then
    case "$END_REASON" in
        clear|resume) _cs_lock_clear=0 ;;
        *) _cs_lock_owner="${CS_LEAD_PID:-}" ;;
    esac
fi
if [ "$_cs_lock_clear" = 1 ] && command -v _cs_lock >/dev/null 2>&1 \
    && command -v live_lock_pid >/dev/null 2>&1 \
    && _cs_lock "$META_DIR/session.mutex.lock"; then
    # Under the openers' mutex: a read of a dead pid followed by a remove would
    # otherwise delete the lock an opener took in between. A hook that cannot
    # take the mutex, or whose cs-shared.sh lacks live_lock_pid, leaves the
    # lock; the next open reclaims a dead one itself. live_lock_pid prints
    # nothing for a lock that names no running process by the one lock rule.
    _cs_lock_pid=$(live_lock_pid "$META_DIR")
    case "$_cs_lock_pid" in
        '') rm -f "$META_DIR/session.lock" 2>/dev/null || true ;;
        "$_cs_lock_owner")
            if ! command -v _remote_server_pid >/dev/null 2>&1 \
                || ! _remote_server_pid "$META_DIR" "${CLAUDE_SESSION_NAME:-}" >/dev/null; then
                rm -f "$META_DIR/session.lock" 2>/dev/null || true
            fi
            ;;
    esac
    _cs_unlock "$META_DIR/session.mutex.lock"
fi
# The lead's claim on its launch (.cs/local/lead-pid, cs_lead_claim) stays,
# marked ended at the lead's terminal end (cs_lead_claim_end). This hook runs
# while the lead still lives, and a claude another SessionEnd hook starts
# would claim a launch with no claim and take the recorded conversation and
# an armed rotation; the claim keeps it a guest, and the end mark keeps it
# one after the lead has exited. A /clear or /resume carries on in the same
# claude and leaves the claim as it is. The next launch clears the file
# (cs-resolve.sh says why nothing else claims it before).
if [ -n "$_cs_lock_owner" ] && [ -n "$LOCAL_DIR" ] && command -v cs_lead_claim_end >/dev/null 2>&1; then
    cs_lead_claim_end "$LOCAL_DIR" || true
fi

# A feature whose retire /finish staged in the base: the base's Stop hook runs
# it once this lock is gone, and a base idle at its prompt has no Stop coming,
# so this end tells it by mail, which wakes an idle lead (stop-blocks.sh,
# the mail wake). Only a real end of the lead's conversation: a /clear or
# /resume keeps the lock, and the retire would only re-stage. The stage is
# looked for under the base's directory in the sessions root, where every
# feature's base lives (an adopted base as a link). cs is reached as the Stop
# hook reaches it: on PATH, or where install.sh puts it.
if [ -n "$_cs_lock_owner" ] && [ -f "$META_DIR/local/state" ]; then
    _fe_base=$(awk 'index($0, "cs_base:") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$META_DIR/local/state" 2>/dev/null || true)
    _fe_task="${CLAUDE_SESSION_NAME:-}"; _fe_task="${_fe_task#*@}"
    _fe_root="${CS_SESSIONS_ROOT:-${HOME:-/nonexistent}/.claude-sessions}"
    if [ -n "$_fe_base" ] && [ -n "$_fe_task" ] && [ "$_fe_task" != "${CLAUDE_SESSION_NAME:-}" ] \
        && [ -f "$_fe_root/$_fe_base/.cs/local/retire-staged/$_fe_task" ]; then
        _fe_cs=$(command -v cs 2>/dev/null || true)
        [ -n "$_fe_cs" ] || { [ -x "${HOME:-/nonexistent}/.local/bin/cs" ] && _fe_cs="$HOME/.local/bin/cs"; }
        [ -z "$_fe_cs" ] || "$_fe_cs" -msg "$_fe_base" -k notify \
            "Feature $_fe_task closed; the retire /finish staged for it runs when your current turn ends." \
            </dev/null >/dev/null 2>&1 || true
    fi
fi

# A session cs -encrypt built detaches its vault when the lead conversation
# ends, so the next open asks for the password again. Claude Code still holds
# the transcript under .cs/claude-config open while this hook runs, so a waiter
# detaches once that claude exits. Before detaching it checks the lock again,
# which SessionEnd removed above, so a reopen in the meantime holds the mount,
# and .cs/local/vault-holders, where every cs that opened the vault is listed.
# The detach is plain, never -force: whatever still holds the volume keeps it
# mounted, and the next open's pre-open handles the leftover. A /clear or
# /resume carries on in the same claude.
if [ -f "$META_DIR/local/vault" ] && [ "${CS_RESOLVED_FROM:-env}" = "env" ] \
    && command -v cs_is_lead >/dev/null 2>&1 && cs_is_lead; then
    case "$END_REASON" in
        clear|resume) ;;
        *)
            nohup /bin/bash -c '
                dir=$1 pid=$2 ldir=$3 shared=$4
                while kill -0 "$pid" 2>/dev/null; do sleep 1; done
                alive() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; kill -0 "$1" 2>/dev/null; }
                held=""
                # The lock is read by live_lock_pid from cs-shared.sh, the
                # one lock rule. A waiter that cannot load it keeps the vault
                # mounted, and the next open handles the leftover.
                if . "$shared" 2>/dev/null && command -v live_lock_pid >/dev/null 2>&1; then
                    [ -z "$(live_lock_pid "$dir/.cs")" ] || held=1
                else
                    held=1
                fi
                if [ -z "$held" ] && [ -f "$dir/.cs/local/vault-holders" ]; then
                    while read -r h; do alive "$h" && held=1; done < "$dir/.cs/local/vault-holders"
                fi
                if [ -z "$held" ] && mnt=$(cd -- "$dir/.cs/vault-mnt" 2>/dev/null && pwd -P) \
                    && mount | grep -F " on $mnt (" >/dev/null; then
                    # A child with a recorded pid, so a reopen can stop it.
                    # Long after the open checked the session: the builtin
                    # test refuses a link planted here since.
                    hdiutil detach "$mnt" >/dev/null 2>&1 &
                    # Recorded only where cs keeps its own files: a .cs/local
                    # git tracks gets no pid ($ldir is empty then).
                    if [ -n "$ldir" ]; then
                        [ -L "$ldir/vault-detach.pid" ] || echo "$!" > "$ldir/vault-detach.pid"
                    fi
                    wait "$!" || true
                    [ -z "$ldir" ] || rm -f "$ldir/vault-detach.pid"
                fi
                [ -z "$ldir" ] || rm -f "$ldir/vault-waiter.pid"
            ' cs-vault-waiter "$SESSION_DIR" "$CLAUDE_PID" "$LOCAL_DIR" "$_cs_shared" </dev/null >/dev/null 2>&1 &
            # Written at once, not through cs_write_atomic: the waiter deletes
            # this file as it ends, and a slower write could land after that.
            # The builtin test refuses a planted link in its place.
            [ -z "$LOCAL_DIR" ] || [ -L "$LOCAL_DIR/vault-waiter.pid" ] || echo "$!" > "$LOCAL_DIR/vault-waiter.pid"
            disown 2>/dev/null || true
            ;;
    esac
fi

# Regenerate sessions index.md at the sessions root
# cs exports CS_SESSIONS_ROOT into a session only when the user set it, made
# absolute when it was relative; unset, the root is the default below. The
# session's parent directory is no stand-in: right for a session living under
# the sessions root, wrong for an adopted one, whose directory is an unrelated
# project path, so the index would land in that project's parent. Default to
# the sessions root itself, and only write an index where sessions actually
# live.
# Compare physical against physical, on BOTH sides. The resolver reports a
# physical SESSION_DIR (cd + pwd -P) while the CLI exports a logical one built
# from $HOME, so normalizing only the root stops the index being written for any
# home reached through a symlink (/home -> /var/home, and every /tmp test env).
# ${HOME:-} matches cs-resolve.sh: main never read HOME here, so under set -u
# an unset one turned a step that should skip into an abort.
_cs_root_default="${HOME:-/nonexistent}/.claude-sessions"
SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$_cs_root_default}"
if [ -d "$SESSIONS_ROOT" ]; then
    SESSIONS_ROOT=$(cd -- "$SESSIONS_ROOT" 2>/dev/null && pwd -P) || SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$_cs_root_default}"
fi
SESSION_DIR_PHYS=$(cd -- "$SESSION_DIR" 2>/dev/null && pwd -P) || SESSION_DIR_PHYS="$SESSION_DIR"
case "$SESSION_DIR_PHYS" in
    "$SESSIONS_ROOT"/*) : ;;
    *) [ -n "${CS_SESSIONS_ROOT:-}" ] || SESSIONS_ROOT="" ;;
esac
if [ -n "$SESSIONS_ROOT" ] && [ -d "$SESSIONS_ROOT" ]; then
    INDEX_FILE="$SESSIONS_ROOT/index.md"
    { {
        echo "# Sessions"
        echo ""
        echo "> Auto-generated on session end. Do not edit manually."
        echo ""
        echo "| Session | Status | Objective | Created |"
        echo "|---------|--------|-----------|---------|"
        # One awk reads every README: a per-session pipeline of head, grep and
        # sed forked ~6 processes per session, ~8 s at 138 sessions, and
        # SessionEnd runs on every /clear. The shell keeps only the glob, its
        # order and the builtin tests; names reach awk through the environment,
        # which does not rewrite backslashes as -v would.
        _cs_index_names=""
        for dir in "$SESSIONS_ROOT"/*/; do
            [ -d "$dir/.cs" ] || continue
            [ -f "$dir/.cs/README.md" ] || continue
            _cs_index_dir="${dir%/}"
            _cs_index_names="${_cs_index_names}${_cs_index_dir##*/}
"
        done
        CS_INDEX_ROOT="$SESSIONS_ROOT" CS_INDEX_NAMES="$_cs_index_names" awk '
            BEGIN {
                count = split(ENVIRON["CS_INDEX_NAMES"], names, "\n")
                for (i = 1; i <= count; i++) {
                    name = names[i]
                    if (name == "") continue
                    readme = ENVIRON["CS_INDEX_ROOT"] "/" name "/.cs/README.md"
                    status = ""; created = ""; objective = ""; n_status = 0; n_created = 0
                    in_objective = 0; objective_found = 0; line_no = 0
                    while ((getline line < readme) > 0) {
                        line_no++
                        # Frontmatter fields sit in the first few lines.
                        if (line_no <= 6 && line ~ /^status:/) {
                            value = line
                            sub(/^status: */, "", value)
                            status = (n_status++ ? status "\n" value : value)
                        }
                        if (line_no <= 6 && line ~ /^created:/) {
                            value = line
                            sub(/^created: */, "", value)
                            created = (n_created++ ? created "\n" value : value)
                        }
                        # The first non-empty line under "## Objective".
                        if (objective_found) continue
                        if (!in_objective) {
                            if (line ~ /^## Objective/) in_objective = 1
                            continue
                        }
                        if (line ~ /^## /) { in_objective = 0; continue }
                        if (line == "") continue
                        objective = line; objective_found = 1
                    }
                    close(readme)
                    # A shell capture drops trailing newlines; so does this.
                    sub(/\n+$/, "", status); sub(/\n+$/, "", created)
                    if (objective ~ /^\[/ && objective ~ /\]$/) objective = ""
                    printf "| [%s](%s/.cs/README.md) | %s | %s | %s |\n", name, name, \
                        (status == "" ? "—" : status), (objective == "" ? "—" : objective), \
                        (created == "" ? "—" : created)
                }
            }'
    } > "$INDEX_FILE"; } 2>/dev/null || true
fi

cs_append_inside "$SESSION_LOG" printf '%s\n' "Session management cleanup complete" \
    "================================================================================" || true

exit 0
