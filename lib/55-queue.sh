# ABOUTME: The session walk-away task queue (add/list/rm/clear).
# ABOUTME: Backs 'cs -queue'.

_queue_set_state() {  # atomic single-word write; "" removes the file
    local qdir="$1" val="$2"
    mkdir -p "$qdir"
    if [ -z "$val" ]; then rm -f "$qdir/queue.state"; return 0; fi
    printf '%s\n' "$val" > "$qdir/queue.state.tmp" && mv "$qdir/queue.state.tmp" "$qdir/queue.state"
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
    mkdir -p "$qdir/queue" "$qdir/queue.tmp"
    # The zero-padded per-process sequence keeps several adds from one process
    # inside one second (a spawn seed's task list) in submission order; guard
    # against an inherited same-named env var poisoning the counter.
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

_queue_list() {  # qdir
    local qdir="$1" f n=0 text
    if [ "$(_queue_len "$qdir")" -gt 0 ]; then
        echo "Pending:"
        for f in "$qdir/queue"/*; do
            [ -f "$f" ] || continue
            text=$(cat "$f")
            case "$text" in *[![:space:]]*) : ;; *) continue ;; esac
            n=$((n + 1))
            printf '  %d. %s\n' "$n" "${text//$'\n'/ }"
        done
    else
        echo "Queue is empty."
    fi
    if [ -s "$qdir/queue.done" ]; then
        echo "Done:"
        awk 'NF{ printf "  - %s\n", $0 }' "$qdir/queue.done"
    fi
}

_queue_rm() {  # qdir, index
    local qdir="$1" n="$2"
    case "$n" in ''|*[!0-9]*) error "cs -queue rm needs a task number";; esac
    [ "$(_queue_len "$qdir")" -gt 0 ] || { error "queue is empty"; }
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
    ' "$inbox"
}

# Dispatcher. Runs inside a session (env) or via the session-scoped arm.
run_queue() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -queue must be run inside a cs session, or as: cs <session> -queue ..."
    fi
    local qdir="$CLAUDE_SESSION_META_DIR/local"
    local sub="${1:-list}"
    case "$sub" in
        add)   shift; _queue_add "$qdir" "$*";;
        list|ls) _queue_list "$qdir";;
        rm)    shift; _queue_rm "$qdir" "${1:-}";;
        clear) _queue_clear "$qdir";;
        start) _queue_set_state "$qdir" armed;;
        defer) mkdir -p "$qdir"; printf '%s\n' "$(date +%s)" > "$qdir/queue.declined.tmp" \
                   && mv "$qdir/queue.declined.tmp" "$qdir/queue.declined"
               jq -nc --arg ts "$(date +%s)" '{ts: ($ts|tonumber), event: "gate_declined"}' \
                   >> "$qdir/notifications.jsonl" 2>/dev/null || true;;
        log)   _queue_log "$qdir";;
        *)     error "Usage: cs -queue [add \"<task>\" | list | rm <n> | clear | log]";;
    esac
}

