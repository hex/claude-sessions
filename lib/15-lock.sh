# ABOUTME: PID-based session lock: acquire, release, and the already-open collision menu.
# ABOUTME: Prevents opening one session in two terminals without --force.

# Emit one numbered menu row and register its action, keeping the printed number
# and the dispatch table in lockstep so a keypress N maps to dispatch[N-1]. The
# label is padded so the dim consequence column aligns. n and dispatch are the
# caller's locals (bash dynamic scope), so a row can never desync the two.
_lock_menu_row() {  # action color label consequence
    n=$((n + 1)); dispatch+=("$1")
    printf '    %b%b%d%b  %b%-16s%b%b%s%b\n' \
        "$BOLD" "$2" "$n" "$NC" "$WHITE" "$3" "$NC" "$DIM" "$4" "$NC"
}

_lock_collision_menu() {
    local session_name="$1" lock_pid="$2"
    local choice="" feature="" offers_worktree=1
    # Worktrees can't nest: a worktree session offers only force/cancel.
    case "$session_name" in
        *@*) offers_worktree=0 ;;
    esac

    local color
    color=$(_read_local_state "$SESSIONS_ROOT/$session_name/.cs/local/state" claude_session_color 2>/dev/null || true)

    # Existing feature worktrees of this base (sibling base@* dirs), so the user
    # can jump back into one instead of only forcing or creating. Capped so the
    # fixed actions stay single-keypress addressable (<= 9 total options).
    local features=() f
    if [ "$offers_worktree" -eq 1 ]; then
        for f in "$SESSIONS_ROOT/$session_name"@*; do
            [ -d "$f" ] || continue          # literal glob when none exist
            features+=("${f##*/}")           # basename, fork-free
        done
        [ "${#features[@]}" -gt 6 ] && features=("${features[@]:0:6}")
    fi

    echo
    printf '  %b%b%b  %b %bis already open%b %b· PID %s%b\n' \
        "$YELLOW" "$ICON_LOCK" "$NC" "$(_session_pill "$session_name" "$color")" \
        "$COMMENT" "$NC" "$DIM" "$lock_pid" "$NC"
    echo

    # Display order drives both the printed numbers and the dispatch table (a
    # keypress N maps to dispatch[N-1]); _lock_menu_row keeps the two in lockstep.
    # Sections are cosmetic.
    local dispatch=() n=0 feat
    if [ "${#features[@]}" -gt 0 ]; then
        printf '    %bopen a feature%b\n' "$DIM" "$NC"
        for f in "${features[@]}"; do
            feat="${f#*@}"
            _lock_menu_row "open:$f" "$GREEN" "@$feat" "resume · cs/$feat"
        done
        echo
        printf '    %bor start here%b\n' "$DIM" "$NC"
    fi
    _lock_menu_row "force" "$ORANGE" 'force start' 'two sessions share one checkout'
    if [ "$offers_worktree" -eq 1 ]; then
        _lock_menu_row "new" "$GREEN" 'new feature' 'its own worktree + branch'
    fi
    _lock_menu_row "cancel" "$COMMENT" 'cancel' 'default'

    echo
    printf '    %b›%b ' "$GOLD" "$NC"
    # Single keypress, no Enter. EOF (piped close) falls through to cancel.
    read -rsn1 choice || choice=""
    echo

    local action="cancel"
    if [[ "$choice" =~ ^[1-9]$ ]] && [ "$choice" -le "${#dispatch[@]}" ]; then
        action="${dispatch[$((choice - 1))]}"
    fi

    case "$action" in
        force) return 0 ;;                              # force a second launch here
        open:*) exec "$0" "${action#open:}" ;;          # resume an existing feature
        new)
            printf '    %bFeature name%b  %b›%b ' "$WHITE" "$NC" "$GOLD" "$NC"
            read -r feature || feature=""
            [ -n "$feature" ] && printf '    %b→ creates %s@%s · branch cs/%s%b\n' \
                "$DIM" "$session_name" "$feature" "$feature" "$NC"
            # cs_split_worktree_name validates the name after the re-exec;
            # keeping a second copy of its regex here would just drift.
            exec "$0" "$session_name@$feature"
            ;;
        *) info "Cancelled"; exit 0 ;;
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

# True when target_pid is this cs process or one of its live ancestors. A cs
# launched from inside Claude is a descendant of the process recorded in the
# session lock: fresh launches exec Claude in place, while resume launches keep
# the lock-owning shell as Claude's parent. The bounded BSD/POSIX ps walk fails
# closed on malformed output, disappearing processes, or an unexpectedly deep
# chain. PID 1 can never be a cs lock owner.
_pid_is_self_or_ancestor() {  # target_pid
    local target="$1" current="$$" parent="" depth=0
    case "$target" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$target" -gt 1 ] || return 1

    while [ "$depth" -lt 64 ]; do
        [ "$current" = "$target" ] && return 0
        case "$current" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$current" -gt 1 ] || return 1
        parent=$("${CS_PS_BIN:-ps}" -o ppid= -p "$current" 2>/dev/null \
            | awk 'NR == 1 { print $1 }') || return 1
        case "$parent" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$parent" != "$current" ] || return 1
        current="$parent"
        depth=$((depth + 1))
    done
    return 1
}

# True only for the invoking conversation's own lock. Exact session identity
# prevents a foreign alias of the same checkout from borrowing the ancestry
# exemption; ancestry prevents a stale lock whose PID was reused by an
# unrelated live process from borrowing the name.
session_lock_owned_by_invoker() {  # session_name, lock_pid
    [ -n "${CLAUDE_SESSION_NAME:-}" ] \
        && [ "$CLAUDE_SESSION_NAME" = "$1" ] \
        && _pid_is_self_or_ancestor "$2"
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
# HEARTBEAT_WINDOW_SECS of now_epoch. Detects conversations open outside cs (no
# lock). A future mtime counts as live, matching the TUI's clamping. Takes
# now_epoch like session_uptime_secs so a loop over many sessions reads the
# clock once.
session_heartbeat_alive() {  # meta_dir, now_epoch
    local f="$1/local/context-pct"
    [ -f "$f" ] || return 1
    local mtime
    mtime="$(_epoch_mtime "$f")"
    [ "$(( $2 - mtime ))" -le "$HEARTBEAT_WINDOW_SECS" ]
}

# True when a session should DISPLAY as live: PID-locked, or breathing via the
# statusline heartbeat. Display surfaces (cs -live, cs -usage) use this so they
# match the TUI. The destructive guards (rm/archive/spawn) use strict
# session_is_live, so a session whose process is gone can still be removed
# without --force even if its statusline was touched recently.
session_display_live() {  # meta_dir, now_epoch
    session_is_live "$1" || session_heartbeat_alive "$1" "$2"
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
