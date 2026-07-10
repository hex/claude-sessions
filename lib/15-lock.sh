# ABOUTME: PID-based session lock: acquire, release, and the already-open collision menu.
# ABOUTME: Prevents opening one session in two terminals without --force.

_lock_collision_menu() {
    local session_name="$1" lock_pid="$2"
    local choice="" task=""
    echo -e "${YELLOW}Session '$session_name' is already open (PID $lock_pid).${NC}"
    case "$session_name" in
        *@*) ;;
        *) echo "  [n] start a parallel task in a worktree (cs $session_name@<task>)" ;;
    esac
    echo "  [f] force a second launch here (two sessions will share one checkout)"
    echo "  [c] cancel (default)"
    read -r -p "> " choice || choice="c"
    case "$choice" in
        [nN])
            case "$session_name" in
                *@*) info "Cancelled"; exit 0 ;;
            esac
            read -r -p "Task name: " task || task=""
            # cs_split_worktree_name validates the task after the re-exec;
            # keeping a second copy of its regex here would just drift.
            exec "$0" "$session_name@$task"
            ;;
        [fF])
            return 0
            ;;
        *)
            info "Cancelled"
            exit 0
            ;;
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
                # The menu returns only when the user chose force
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

