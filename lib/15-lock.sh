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
    local session_name="$1" lock_pid="$2" resume="${3:-}"
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
        # Five, not six: the fixed rows below can run to four (force, new
        # feature, session manager, cancel) and a tenth option would not be
        # addressable by a single keypress.
        [ "${#features[@]}" -gt 5 ] && features=("${features[@]:0:5}")
    fi

    echo
    printf '  %b%b%b  %b %bis live%b %b· PID %s%b\n' \
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
    # The way out that is neither forcing this session nor starting work here:
    # go pick a different one. Offered only when a picker is installed, so the
    # row can never name a command that answers with "not installed".
    if _tui_bin >/dev/null 2>&1; then
        _lock_menu_row "tui" "$GOLD" 'session manager' 'browse every session'
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
        open:*)                                         # resume an existing feature
            if [ -n "$resume" ]; then
                exec "$0" "${action#open:}" --resume
            fi
            exec "$0" "${action#open:}"
            ;;
        tui) _vault_leave; exec "$0" -tui ;;            # pick a different session
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

# Stops cs, naming <lock file>, when it is anything but a regular file or
# absent. cs creates and removes the session lock as a regular file: a write
# or a read would go through a link to whatever it names, a directory would
# pass for a stale lock that rm cannot remove, and a write to a fifo blocks
# with no reader while the openers' mutex is held. Called before anything is
# written.
_refuse_session_lock_not_a_file() {  # lock_file
    [ ! -L "$1" ] || error "$1 is a link, where cs keeps the session lock; remove it and open the session again"
    [ ! -d "$1" ] || error "$1 is a directory, where cs keeps the session lock; remove it and open the session again"
    [ ! -e "$1" ] || [ -f "$1" ] || error "$1 is not a regular file, where cs keeps the session lock; remove it and open the session again"
}

# Take the PID-based session lock of <meta_dir> to prevent concurrent access.
# The lock is taken by creating the file, which the filesystem does for
# exactly one process (noclobber: the open fails when the file exists), never
# by a check followed by a write: two opens started together both saw no
# lock, both wrote their pid, and both launched a claude on one UUID. A loser
# reads the winner's pid and takes the live-lock path; a lock that names no
# running process by live_lock_pid's rule ("0" and "-1" included) is removed
# and the create tried again, with a bound so a lock that
# keeps reappearing cannot spin forever. Creating and reclaiming take turns
# under the .cs/session.mutex.lock mutex (_cs_lock): an opener that read a
# dead pid and then removed the file could otherwise delete the live lock
# another opener had just made in its place, and both would launch. A cs from
# before that mutex took a session.lock.d directory instead, and the two do
# not wait on each other: an older opener still between reading a dead pid
# and removing the file while this version installs could remove a new
# opener's lock. That window is an update run in the middle of an open; it is
# accepted and named in the CHANGELOG rather than bridged with the old pid
# judgement. A caller that cannot take the mutex (another cs still holds it
# after the wait) must refuse rather than go on without it, since that holder
# may be between reading a dead pid and removing the file.
# Returns 0 holding the lock; 1 when a live process holds it, with its pid in
# _CS_LOCK_LIVE_PID and the mutex released; 2 when the mutex cannot be taken,
# with session.lock untouched. Exits when perl is missing or the bound is hit.
_take_session_lock() {  # meta_dir
    local meta_dir="$1"
    local lock_file="$meta_dir/session.lock" mutex="$meta_dir/session.mutex.lock"
    local lock_pid attempt=0
    _CS_LOCK_LIVE_PID=""

    # Without perl the mutex can never be taken, which is no sign of another
    # opener: say what is missing instead.
    if ! perl -MFcntl=:flock -e 1 >/dev/null 2>&1; then
        echo -e "${RED}Error: cs needs perl to lock this session ($meta_dir); install perl and retry${NC}" >&2
        exit 1
    fi
    _refuse_session_lock_not_a_file "$lock_file"
    _cs_lock "$mutex" || return 2
    while :; do
        if ( set -C; echo "$$" > "$lock_file" ) 2>/dev/null; then
            # Verify: the create was ours only when the file still says so
            # (a force from another opener could have replaced it meanwhile).
            if [ "$(cat "$lock_file" 2>/dev/null)" = "$$" ]; then
                _cs_unlock "$mutex"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        lock_pid="$(live_lock_pid "$meta_dir")"

        if [ -n "$lock_pid" ]; then
            # PID is alive — session is in use
            _cs_unlock "$mutex"
            _CS_LOCK_LIVE_PID="$lock_pid"
            return 1
        fi
        lock_pid="$(read_lock_pid "$meta_dir")"

        if [ "$attempt" -ge 5 ]; then
            _cs_unlock "$mutex"
            error "Could not take the session lock $lock_file after $attempt attempts (another cs keeps writing it?)"
        fi
        if [ -e "$lock_file" ]; then
            # PID is dead — stale lock. Its text is whatever the file holds,
            # which a clone or a link put there can choose, so it is printed
            # as a plain name.
            warn "Removing stale session lock (PID $(_cs_plain_name "${lock_pid:-unknown}" 40))"
            rm -f "$lock_file"
        fi
        # The file vanished between the failed create and the look at it, or
        # was just removed as stale: try the create again.
    done
}

# Acquire the session lock for an open, through _take_session_lock. An opener
# that cannot take the mutex refuses. A live holder meets the collision menu
# at a terminal, which waits on a person, so the mutex is let go before it. A
# force (flag or collision menu) replaces the lock outright: that is what
# force means. It takes the mutex again to write the replacement, since a
# SessionEnd clearing its own lock reads and removes it under the mutex.
# Before any of that, a live holder that is a `cs <name> --remote` server
# refuses every open, and an open for --remote (remote set) refuses any live
# holder (_remote_refuse_live).
acquire_session_lock() {
    local meta_dir="$1"
    local force="${2:-}"
    local session_name="$3"
    local remote="${4:-}"
    # Set for `cs <name> --resume`: the menu's feature open and the hint below
    # carry it, so the open they lead to answers the resume prompt as this one
    # would have.
    local resume="${5:-}"
    local lock_file="$meta_dir/session.lock" mutex="$meta_dir/session.mutex.lock"
    local lock_pid taken=0

    _take_session_lock "$meta_dir" || taken=$?
    case "$taken" in
        0) return 0 ;;
        1) lock_pid="$_CS_LOCK_LIVE_PID" ;;
        2)
            echo -e "${RED}Error: Another cs is opening this session ($mutex is held)${NC}" >&2
            echo -e "${DIM}Try again in a moment: cs $session_name${NC}" >&2
            exit 1
            ;;
        *) error "_take_session_lock returned $taken for $meta_dir" ;;
    esac

    _remote_refuse_live "$session_name" "$meta_dir" "$lock_pid" "$remote"
    if [ "$force" = "true" ]; then
        warn "Overriding active session lock (PID $lock_pid)"
    elif cs_interactive; then
        _lock_collision_menu "$session_name" "$lock_pid" "$resume"
        # The menu returns only when the user chose force. Record the
        # choice so the rest of the launch (live-duplicate UUID guard
        # included) honors it exactly like an explicit --force.
        CS_COLLISION_FORCE=1
        warn "Overriding active session lock (PID $lock_pid)"
    else
        echo -e "${RED}Error: Session is live (PID $lock_pid)${NC}" >&2
        echo -e "${DIM}Use --force to override: cs $session_name --force${resume:+ --resume}${NC}" >&2
        exit 1
    fi
    # The replacement is written under the mutex again: a SessionEnd
    # that read its own pid while the mutex was free would otherwise
    # remove this lock right after it is written.
    if ! _cs_lock "$mutex"; then
        echo -e "${RED}Error: Another cs is opening this session ($mutex is held)${NC}" >&2
        echo -e "${DIM}Try again in a moment: cs $session_name --force${NC}" >&2
        exit 1
    fi
    # The lock records one pid. When this forced open ends first, its
    # exit removes the lock and the other holder runs unprotected;
    # that is decided, and locks do not record every holder. A link or a
    # directory put in the lock's place since it was read is refused, not
    # written through.
    _refuse_session_lock_not_a_file "$lock_file"
    echo "$$" > "$lock_file"
    _cs_unlock "$mutex"
    return 0
}

# Release session lock if owned by current process. The read of the pid and
# the removal happen under the openers' mutex (.cs/session.mutex.lock): a
# forced open that replaced the lock between the two would otherwise have its
# lock removed here and run on unlocked. This runs from cs's exit traps, so
# when the mutex cannot be taken for any reason (perl missing, this process
# already holding another _cs_lock, another cs holding it past the five-second
# wait) the lock is left as it is, nothing is printed and the status is 0; the
# lock left behind names a dead pid, and the next open reclaims it. The exit
# can therefore wait up to five seconds while another cs holds the mutex. Both
# are decided; do not re-fix. A link in the lock's place is never followed
# and is left where it is, as a directory is.
release_session_lock() {
    local meta_dir="$1"
    local lock_file="$meta_dir/session.lock"
    local mutex="$meta_dir/session.mutex.lock"

    if [ ! -L "$lock_file" ] && [ -f "$lock_file" ]; then
        _cs_lock "$mutex" 2>/dev/null || return 0
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$lock_file"
        fi
        _cs_unlock "$mutex"
    fi
}

# read_lock_pid and live_lock_pid live in lib/02-shared.sh, so the hooks read
# a session lock by the same rule.

# True (exit 0) when a session's process is currently alive on this machine,
# by live_lock_pid's rule. Arg: meta_dir (the session's .cs dir).
session_is_live() {  # meta_dir
    [ -n "$(live_lock_pid "$1")" ]
}

# True when target_pid is this cs process or one of its live ancestors. A cs
# launched from inside Claude is a descendant of the process recorded in the
# session lock: Claude runs in place of cs on a fresh launch and on a resume
# that is sure to land, and as a child of the lock-owning shell otherwise. The
# bounded BSD/POSIX ps walk fails closed on malformed output, disappearing
# processes, or an unexpectedly deep chain. PID 1 can never be a cs lock owner.
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

# True when cs runs inside a session (CLAUDE_SESSION_NAME) other than <name>.
# A terminal outside every session is the user, never another session.
_called_from_other_session() {  # name
    [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ "$CLAUDE_SESSION_NAME" != "$1" ]
}

# Refuses <verb> (remove, archive, rotate the narrative of) on session <name>
# while its claude is running when cs runs inside a session that does not own
# it, --force or not: the flag skips the live check only from a terminal
# outside every session and for the caller's own sessions. A session owns itself and, from its base,
# its own features (<base>@<task>); a feature owns neither its base nor a
# sibling. An idle target is left to the verb's own checks. Called directly,
# never in $(...), so the error ends cs.
_refuse_live_other_session() {  # name meta_dir verb
    _called_from_other_session "$1" || return 0
    case "$CLAUDE_SESSION_NAME" in
        *@*) ;;
        *) case "$1" in "$CLAUDE_SESSION_NAME"@*) return 0 ;; esac ;;
    esac
    local pid
    pid="$(live_lock_pid "$2")"
    [ -n "$pid" ] || return 0
    error "session $CLAUDE_SESSION_NAME cannot $3 session $1 while it is live (pid $pid); --force does not override that from another session. Close $1 first."
}

# Refuses <verb> (remove, archive) on base session <name> while one of its
# features (<name>@<task>) is live, when cs runs inside any session but <name>
# itself, --force or not: a feature's worktree points into its base's
# repository. Only a terminal outside every session and the base itself are
# not refused; a sibling feature is, and so is the live feature itself, whose
# own worktree the base holds. Called directly, never in $(...), so the error
# ends cs. A feature is <name>'s when <name>@<its task> is the same directory
# as the feature's (-ef), not when the names match as strings: a volume that
# ignores letter case or Unicode normalization finds one directory under
# several spellings, and a glob compares bytes.
_refuse_base_with_live_feature() {  # name verb
    [ -n "${CLAUDE_SESSION_NAME:-}" ] || return 0
    [ "$CLAUDE_SESSION_NAME" != "$1" ] || return 0
    case "$1" in *@*) return 0 ;; esac
    local feature entry pid
    for feature in "$SESSIONS_ROOT"/*@*; do
        entry="${feature##*/}"
        [ "$SESSIONS_ROOT/$1@${entry#*@}" -ef "$feature" ] || continue
        [ -d "$feature/.cs" ] || continue
        pid="$(live_lock_pid "$feature/.cs")"
        [ -n "$pid" ] || continue
        error "session $CLAUDE_SESSION_NAME cannot $2 session $1 while its feature ${feature##*/} is live (pid $pid); --force does not override that from another session. Close ${feature##*/} first."
    done
}

# Epoch mtime of a file, 0 on error. Arg: path. GNU stat is asked first, as
# _cs_file_mode does: BSD stat rejects -c with no output, while GNU stat reads
# -f as --file-system and prints that, and OSTYPE is no guide to which stat
# PATH finds (Homebrew's gnubin puts GNU stat on a Mac).
_epoch_mtime() {  # path
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# How long after the last statusline write a lockless conversation still counts
# as live, matching the TUI's HEARTBEAT_WINDOW_SECS. A conversation opened
# outside cs writes no lock, but its statusline touches .cs/local/context-pct
# every minute or two while it is open: an idle bar repaints once a minute.
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
# without --force even if its statusline was touched recently. Uninstall's
# delete of the whole sessions root uses this broader test: it has no --force,
# and a conversation opened outside cs holds no lock.
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
