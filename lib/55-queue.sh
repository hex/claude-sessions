# ABOUTME: The session walk-away task queue (add/list/rm/clear).
# ABOUTME: Backs 'cs -queue'.

_queue_set_state() {  # atomic single-word write; "" removes the file
    local qdir="$1" val="$2"
    mkdir -p "$qdir"
    if [ -z "$val" ]; then rm -f "$qdir/queue.state"; return 0; fi
    printf '%s\n' "$val" > "$qdir/queue.state.tmp" && mv "$qdir/queue.state.tmp" "$qdir/queue.state"
}

_queue_add() {  # qdir, text
    local qdir="$1" text="$2"
    text="${text#"${text%%[![:space:]]*}"}"  # ltrim
    text="${text%"${text##*[![:space:]]}"}"  # rtrim
    [ -n "$text" ] || { error "cs -queue add needs a non-empty task"; }
    mkdir -p "$qdir"
    printf '%s\n' "$text" >> "$qdir/queue"
    rm -f "$qdir/queue.declined"   # queue changed: allow the gate to re-ask
}

_queue_list() {  # qdir
    local qdir="$1"
    if [ -s "$qdir/queue" ]; then
        echo "Pending:"
        awk 'NF{ printf "  %d. %s\n", ++n, $0 }' "$qdir/queue"
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
    case "$n" in ''|*[!0-9]*) error "cs -queue rm needs a line number";; esac
    [ -f "$qdir/queue" ] || { error "queue is empty"; }
    awk -v target="$n" 'NF{ c++ } { if (c==target && NF) next; print }' "$qdir/queue" \
        > "$qdir/queue.tmp" && mv "$qdir/queue.tmp" "$qdir/queue"
    rm -f "$qdir/queue.declined"
}

_queue_clear() {  # qdir
    local qdir="$1"
    rm -f "$qdir/queue" "$qdir/queue.state" "$qdir/queue.declined"
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

