# ABOUTME: The session walk-away task queue (add/list/rm/clear).
# ABOUTME: Backs 'cs -queue'.

_queue_set_state() {  # atomic single-word write; "" removes the file
    local qdir="$1" val="$2"
    mkdir -p "$qdir"
    if [ -z "$val" ]; then rm -f "$qdir/queue.state"; return 0; fi
    printf '%s\n' "$val" > "$qdir/queue.state.tmp" && mv "$qdir/queue.state.tmp" "$qdir/queue.state"
}

# Convert a pre-directory queue (a single line-per-task FILE at the queue
# path) into per-task files, preserving order via zero-padded sequence names
# that sort before any epoch-named task. mv-aside first, so a stale writer
# holding the old inode never re-materializes converted lines; a leftover
# .migrating from an interrupted conversion is picked up first. No-op when
# the queue is already a directory or absent.
_queue_convert_legacy() {  # qdir
    local qdir="$1" legacy="$1/queue.migrating"
    if [ -f "$qdir/queue" ]; then
        # A leftover from an interrupted conversion holds real tasks; fold it
        # in before renaming the fresh file over it.
        if [ -f "$legacy" ]; then
            # Terminate the leftover first: an interrupted conversion can strand
            # a file whose last line has no newline, and appending straight onto
            # it would splice two tasks into one. The converter skips the blank
            # line this adds when the leftover was already terminated, and the
            # queue executes what it reads, so a splice is worse than anything.
            printf '\n' >> "$legacy" 2>/dev/null || return 0
            cat "$qdir/queue" >> "$legacy" 2>/dev/null || return 0
            rm -f "$qdir/queue"
        else
            mv "$qdir/queue" "$legacy" 2>/dev/null || return 0
        fi
    fi
    [ -f "$legacy" ] || return 0
    # The pre-directory layout used queue.tmp as an awk TEMP FILE, so a killed
    # old-cs rm or drain pop leaves a regular file exactly where the staging
    # directory now goes. mkdir -p fails over it, which under errexit aborts
    # every entry point that converts — including session open, leaving the
    # session unopenable. Clear a non-directory at either path first.
    [ -d "$qdir/queue" ]     || rm -f "$qdir/queue"
    [ -d "$qdir/queue.tmp" ] || rm -f "$qdir/queue.tmp"
    mkdir -p "$qdir/queue" "$qdir/queue.tmp"
    local line seq=0 fname failed=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *[![:space:]]*) : ;; *) continue ;; esac
        seq=$((seq + 1))
        fname="0000000000-legacy-$(printf '%04d' "$seq")"
        # Keeping the legacy file for retry (below) means a task that DID land
        # and was then popped and run by the drain would be re-created here and
        # executed a second time. Names are deterministic, so a task still
        # queued is recognisable by its name; one already executed is only
        # recognisable in the done log. The queue runs what it reads, so
        # re-execution is the worse failure and both are checked.
        if [ -e "$qdir/queue/$fname" ] ||
           { [ -f "$qdir/queue.done" ] && grep -Fxq -- "$line" "$qdir/queue.done"; }; then
            continue
        fi
        if ! { printf '%s\n' "$line" > "$qdir/queue.tmp/$fname" \
                && mv "$qdir/queue.tmp/$fname" "$qdir/queue/$fname"; }; then
            failed=1
        fi
    done < "$legacy"
    # Only drop the legacy file once every task reached the queue. Unlinking it
    # after a partial conversion destroys the tasks that never landed, and this
    # is the one copy of them.
    [ "$failed" -eq 0 ] && rm -f "$legacy"
    return 0
}

# The queue is a directory of one file per task. A task is written whole to
# the sibling queue.tmp/ staging dir and renamed into place, so the drain can
# never read a torn entry — the queue executes what it reads, which makes a
# spliced line worse than a lost one. Names are <zero-padded epoch>-<pid>-<n>;
# lexical order approximates arrival order (same caveats as mail filenames).
_queue_add() {  # qdir, text
    local qdir="$1" text="$2"
    text="$(_trim "$text")"
    [ -n "$text" ] || { error "cs -queue add needs a non-empty task"; }
    # Senders write into other sessions' queues (task-kind mail), so a
    # recipient that has not reopened since the upgrade converts here.
    _queue_convert_legacy "$qdir"
    mkdir -p "$qdir/queue" "$qdir/queue.tmp"
    # The zero-padded per-process sequence keeps several adds from one process
    # inside one second (a spawn seed's task list) in submission order; guard
    # against an inherited same-named env var poisoning the counter. The random
    # suffix covers what the sequence cannot: two cs processes that recycled the
    # same pid within one second, where both counters start at 1.
    case "${_QUEUE_SEQ:-}" in ''|*[!0-9]*) _QUEUE_SEQ=0;; esac
    _QUEUE_SEQ=$((10#$_QUEUE_SEQ + 1))
    local fname
    fname="$(printf '%010d' "$(date +%s)")-$$-$(printf '%04d' "$_QUEUE_SEQ")-${RANDOM}"
    printf '%s\n' "$text" > "$qdir/queue.tmp/$fname" \
        && mv "$qdir/queue.tmp/$fname" "$qdir/queue/$fname"
    rm -f "$qdir/queue.declined"   # queue changed: allow the gate to re-ask
}

# Count of queued task files ([ -f ] also guards bash 3.2's literal
# unmatched glob and skips the odd subdirectory).
_queue_len() {  # qdir
    local f n=0
    for f in "$1/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    echo "$n"
}

# One enumeration, and every regular file is a task — the same rule _queue_len
# counts and _queue_rm indexes, so the number shown here is the number that
# deletes. Filtering blank files here (they cannot occur: both writers trim and
# reject empties) would renumber the list out of step with rm.
_queue_list() {  # qdir
    local qdir="$1" f n=0 text
    for f in "$qdir/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        [ "$n" -eq 1 ] && echo "Pending:"
        text=$(<"$f")
        printf '  %d. %s\n' "$n" "${text//$'\n'/ }"
    done
    [ "$n" -gt 0 ] || echo "Queue is empty."
    if [ -s "$qdir/queue.done" ]; then
        echo "Done:"
        awk 'NF{ printf "  - %s\n", $0 }' "$qdir/queue.done"
    fi
}

_queue_rm() {  # qdir, index
    local qdir="$1" n="$2" len
    case "$n" in ''|*[!0-9]*) error "cs -queue rm needs a task number";; esac
    len=$(_queue_len "$qdir")
    [ "$len" -gt 0 ] || { error "queue is empty"; }
    # Refuse before touching anything: an index past the end used to fall
    # through the loop silently and still clear queue.declined below, re-arming
    # the gate so a later drain ran the task the user believed they had removed.
    if [ "$n" -lt 1 ] || [ "$n" -gt "$len" ]; then
        error "no task $n in the queue (1-$len)"
    fi
    local f i=0
    for f in "$qdir/queue"/*; do
        [ -f "$f" ] || continue
        i=$((i + 1))
        if [ "$i" -eq "$n" ]; then
            rm -f "$f"
            break
        fi
    done
    rm -f "$qdir/queue.declined"
}

_queue_clear() {  # qdir
    local qdir="$1"
    rm -rf "$qdir/queue" "$qdir/queue.tmp"
    rm -f "$qdir/queue.state" "$qdir/queue.declined"
}

_queue_log() {  # qdir
    local inbox="$1/notifications.jsonl"
    if [ ! -s "$inbox" ]; then
        echo "No queue activity recorded."
        return 0
    fi
    # Tolerant per-line parse (torn lines skipped); oldest-first is file order.
    jq -rR '
        fromjson? // empty |
        (.ts | strflocaltime("%Y-%m-%d %H:%M")) + "  " + .event +
        (if .task then ": " + .task
         elif .reason then ": " + .reason + " (" + (.reading|tostring) + " >= " + (.limit|tostring) + "), " + (.remaining|tostring) + " remaining"
         elif .done then ": " + (.done|tostring) + " done"
         else "" end)
    ' "$inbox" | _scrub_controls
}

# Dispatcher. Runs inside a session (env) or via the session-scoped arm.
run_queue() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -queue must be run inside a cs session, or as: cs <session> -queue ..."
    fi
    local qdir="$CLAUDE_SESSION_META_DIR/local"
    _queue_convert_legacy "$qdir"
    local sub="${1:-list}"
    case "$sub" in
        add)   shift; _queue_add "$qdir" "$*";;
        # Scrubbed once here rather than inside _queue_list's two branches:
        # one construct that cannot be half-removed, and one tr fork instead
        # of one per queued task (forks are expensive under MSYS).
        # _queue_list is a pure reader — it emits no palette variables and
        # never calls error() — so the pipeline eats nothing cs owns.
        list|ls) _queue_list "$qdir" | _scrub_controls;;
        rm)    shift; _queue_rm "$qdir" "${1:-}";;
        clear) _queue_clear "$qdir";;
        start) _queue_set_state "$qdir" armed;;
        defer) mkdir -p "$qdir"; printf '%s\n' "$(date +%s)" > "$qdir/queue.declined.tmp" \
                   && mv "$qdir/queue.declined.tmp" "$qdir/queue.declined"
               _terminate_jsonl "$qdir/notifications.jsonl"
               jq -nc --arg ts "$(date +%s)" '{ts: ($ts|tonumber), event: "gate_declined"}' \
                   >> "$qdir/notifications.jsonl" 2>/dev/null || true;;
        log)   _queue_log "$qdir";;
        *)     error "Usage: cs -queue [add \"<task>\" | list | rm <n> | clear | log]";;
    esac
}

