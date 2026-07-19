# ABOUTME: PID-based session lock: acquire, release, and the already-open collision menu.
# ABOUTME: Prevents opening one session in two terminals without --force.

_lock_collision_menu() {
    local session_name="$1" lock_pid="$2"
    local choice="" task="" offers_worktree=1
    # Worktrees can't nest: a worktree session offers only force/cancel.
    case "$session_name" in
        *@*) offers_worktree=0 ;;
    esac

    # Pad action labels to a common width so the dim consequence column aligns.
    local force_l worktree_l cancel_l
    printf -v force_l    '%-14s' 'force start'
    printf -v worktree_l '%-14s' 'new worktree'
    printf -v cancel_l   '%-14s' 'cancel'

    echo
    echo -e "  ${YELLOW}${ICON_LOCK}${NC}  ${BOLD}${WHITE}${session_name}${NC} ${COMMENT}is already open${NC} ${DIM}· PID ${lock_pid}${NC}"
    echo
    echo -e "    ${BOLD}${ORANGE}1${NC}  ${WHITE}${force_l}${NC}${DIM}two sessions share one checkout${NC}"
    if [ "$offers_worktree" -eq 1 ]; then
        echo -e "    ${BOLD}${GREEN}2${NC}  ${WHITE}${worktree_l}${NC}${DIM}parallel task on its own branch${NC}"
        echo -e "    ${BOLD}${COMMENT}3${NC}  ${WHITE}${cancel_l}${NC}${DIM}(default)${NC}"
    else
        echo -e "    ${BOLD}${COMMENT}2${NC}  ${WHITE}${cancel_l}${NC}${DIM}(default)${NC}"
    fi
    echo
    printf '    %b›%b ' "$GOLD" "$NC"
    # Single keypress, no Enter. EOF (piped close) falls through to cancel.
    read -rsn1 choice || choice=""
    echo

    case "$choice" in
        1) return 0 ;;                                  # force a second launch here
        2)
            # '2' is cancel on a worktree session, which can't nest another.
            if [ "$offers_worktree" -eq 0 ]; then
                info "Cancelled"; exit 0
            fi
            read -r -p "    Task name: " task || task=""
            # cs_split_worktree_name validates the task after the re-exec;
            # keeping a second copy of its regex here would just drift.
            exec "$0" "$session_name@$task"
            ;;
        *) info "Cancelled"; exit 0 ;;                  # 3 / Enter / any other key
    esac
}

# Acquire a PID-based session lock to prevent concurrent access
acquire_session_lock() {
    local meta_dir="$1"
    local force="${2:-}"
    local session_name="$3"
    local lock_file="$meta_dir/session.lock"

    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            # PID is alive — session is in use
            if [ "$force" = "true" ]; then
                warn "Overriding active session lock (PID $lock_pid)"
            elif cs_interactive; then
                _lock_collision_menu "$session_name" "$lock_pid"
                # The menu returns only when the user chose force. Record the
                # choice so the rest of the launch (live-duplicate UUID guard
                # included) honors it exactly like an explicit --force.
                CS_COLLISION_FORCE=1
                warn "Overriding active session lock (PID $lock_pid)"
            else
                echo -e "${RED}Error: Session is already open (PID $lock_pid)${NC}" >&2
                echo -e "${DIM}Use --force to override: cs $session_name --force${NC}" >&2
                exit 1
            fi
        else
            # PID is dead — stale lock
            warn "Removing stale session lock (PID ${lock_pid:-unknown})"
            rm -f "$lock_file"
        fi
    fi

    echo "$$" > "$lock_file"
}

# Release session lock if owned by current process
release_session_lock() {
    local meta_dir="$1"
    local lock_file="$meta_dir/session.lock"

    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$lock_file"
        fi
    fi
}

# Print the PID recorded in a session's lock file (empty if none). Arg: meta_dir.
read_lock_pid() {  # meta_dir
    local f="$1/session.lock"
    [ -f "$f" ] || return 0
    cat "$f" 2>/dev/null || true
}

# True (exit 0) when a session's process is currently alive on this machine.
# Arg: meta_dir (the session's .cs dir).
session_is_live() {  # meta_dir
    local pid
    pid="$(read_lock_pid "$1")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Epoch mtime of a file (BSD/GNU stat), 0 on error. Arg: path.
_epoch_mtime() {  # path
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f %m "$1" 2>/dev/null || echo 0
    else
        stat -c %Y "$1" 2>/dev/null || echo 0
    fi
}

# How long after the last statusline write a lockless conversation still counts
# as live, matching the TUI's HEARTBEAT_WINDOW_SECS. A conversation opened
# outside cs writes no lock, but its statusline touches .cs/local/context-pct
# every few seconds while active.
HEARTBEAT_WINDOW_SECS=900

# True when the statusline heartbeat is fresh: context-pct was written within
# HEARTBEAT_WINDOW_SECS of now. Detects conversations open outside cs (no lock).
# A future mtime counts as live, matching the TUI's clamping.
session_heartbeat_alive() {  # meta_dir
    local f="$1/local/context-pct"
    [ -f "$f" ] || return 1
    local now mtime
    now="$(date +%s)"
    mtime="$(_epoch_mtime "$f")"
    [ "$(( now - mtime ))" -le "$HEARTBEAT_WINDOW_SECS" ]
}

# True when a session should DISPLAY as live: PID-locked, or breathing via the
# statusline heartbeat. Display surfaces (cs -live, cs -usage) use this so they
# match the TUI. The destructive guards (rm/archive/spawn) use strict
# session_is_live, so a session whose process is gone can still be removed
# without --force even if its statusline was touched recently.
session_display_live() {  # meta_dir
    session_is_live "$1" || session_heartbeat_alive "$1"
}

# Seconds since a session was last launched (its lock file's mtime).
# Args: meta_dir, now_epoch. Prints 0 if the lock is absent/unreadable.
session_uptime_secs() {  # meta_dir, now_epoch
    local f="$1/session.lock" now="$2" started
    [ -f "$f" ] || { echo 0; return 0; }
    started="$(_epoch_mtime "$f")"
    case "$started" in ''|*[!0-9]*) echo 0; return 0;; esac
    [ "$started" -gt 0 ] || { echo 0; return 0; }
    echo $(( now - started ))
}

