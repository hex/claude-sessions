# ABOUTME: The session walk-away task queue (add/list/rm/clear).
# ABOUTME: Backs 'cs -queue'.

_queue_set_state() {  # atomic single-word write; "" removes the file
    local qdir="$1" val="$2"
    cs_mkdir_inside "$qdir"
    if [ -z "$val" ]; then rm -f "$qdir/queue.state"; return 0; fi
    cs_write_atomic "$qdir/queue.state" printf '%s\n' "$val"
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
            { printf '\n' >> "$legacy"; } 2>/dev/null || return 0
            { cat "$qdir/queue" >> "$legacy"; } 2>/dev/null || return 0
            rm -f "$qdir/queue"
        else
            mv "$qdir/queue" "$legacy" 2>/dev/null || return 0
        fi
    fi
    [ -f "$legacy" ] || return 0
    # The pre-directory layout used queue.tmp as an awk TEMP FILE, so a killed
    # old-cs rm or drain pop leaves a regular file exactly where the staging
    # directory now goes. Making the directory fails over it, which under errexit aborts
    # every entry point that converts — including session open, leaving the
    # session unopenable. Clear a non-directory at either path first.
    [ -d "$qdir/queue" ]     || rm -f "$qdir/queue"
    [ -d "$qdir/queue.tmp" ] || rm -f "$qdir/queue.tmp"
    # A directory that cannot be made stops here, the legacy file kept, with
    # cs_mkdir_inside's message the only one: under errexit the 1 ends cs as
    # the failed call itself would, and where errexit is off the writes below
    # would each print a raw redirection error instead.
    cs_mkdir_inside "$qdir/queue" && cs_mkdir_inside "$qdir/queue.tmp" || return 1
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
# A task body is one line: the done log and the listing are line-oriented.
# Every way in checks here: cs -queue add, task-kind mail (through
# _queue_add), and cs -spawn --task before it stages its seed.
_queue_require_single_line() {  # text
    # $(printf '\n') would collapse to "" (command substitution strips
    # trailing newlines); the literal embedded newline below does not.
    local nl='
'
    case "$1" in
        *"$nl"*) error "task bodies must be a single line (the queue's done log and listing are line-oriented)";;
    esac
}

_queue_add() {  # qdir, text
    _queue_write_task "$1" "$2" \
        || error "could not write the task into $1/queue; it is not queued"
}

# Write one task into the queue; returns 1 when the write fails, having left
# nothing behind, and records the path of the file it wrote in _QUEUE_ADDED,
# so a caller queueing several can take them back. A task that breaks the
# queue's rules (empty, more than one line) is refused with an error.
_queue_write_task() {  # qdir, text
    local qdir="$1" text="$2"
    _QUEUE_ADDED=""
    text="$(_trim "$text")"
    [ -n "$text" ] || { error "cs -queue add needs a non-empty task"; }
    _queue_require_single_line "$text"
    # Senders write into other sessions' queues (task-kind mail), so a
    # recipient that has not reopened since the upgrade converts here.
    _queue_convert_legacy "$qdir"
    # errexit is off here (callers test the status), so a directory that
    # cannot be made has to stop the write itself.
    cs_mkdir_inside "$qdir/queue" && cs_mkdir_inside "$qdir/queue.tmp" || return 1
    # The zero-padded per-process sequence keeps several adds from one process
    # inside one second (a spawn seed's task list) in submission order; guard
    # against an inherited same-named env var poisoning the counter. The random
    # suffix covers what the sequence cannot: two cs processes that recycled the
    # same pid within one second, where both counters start at 1.
    case "${_QUEUE_SEQ:-}" in ''|*[!0-9]*) _QUEUE_SEQ=0;; esac
    _QUEUE_SEQ=$((10#$_QUEUE_SEQ + 1))
    local fname
    fname="$(printf '%010d' "$(date +%s)")-$$-$(printf '%04d' "$_QUEUE_SEQ")-${RANDOM}"
    # errexit does not see a failed left operand, so the failure is returned.
    if ! { printf '%s\n' "$text" > "$qdir/queue.tmp/$fname" \
            && mv "$qdir/queue.tmp/$fname" "$qdir/queue/$fname"; }; then
        rm -f "$qdir/queue.tmp/$fname"
        return 1
    fi
    _QUEUE_ADDED="$qdir/queue/$fname"
}

# Queue a task that arrived as task-kind mail, by its message id. The user's
# accept is the only way mail reaches the queue: the sender named itself, so
# the body waits in the mailbox (new/ unread, cur/ once read) until someone at
# this session chooses it. Each id is accepted once: queue.accepted records
# the id BEFORE the queue file lands, and the file carries the id in its name,
# so a second accept racing this one (the lock serialises them) or a retry
# after a kill between the two writes refuses. The receipt goes first because
# the other order lets a retry replay a task the drain already consumed: the
# drain deletes the file and logs only the body, so nothing would match. A
# kill after the receipt loses the queued copy instead, which the error names
# and the user can redo by hand; a lost copy is visible, a replay is not.
_queue_accept() {  # qdir, message id
    local qdir="$1" id="$2" f found="" matches=0 kind body
    [ -n "$id" ] || error "cs -queue accept needs a message id (shown by cs -msg)"
    # The shape the digest and the listing offer an accept command for: an id
    # outside it was never shown whole, so nobody can have agreed to its mail.
    case "$id" in *[!A-Za-z0-9._-]*) error "cs -queue accept: $id is not a message id";; esac
    [ "${#id}" -le 40 ] || error "cs -queue accept: $id is not a message id"
    # Every document is read: an id two mails share names neither of them.
    for f in "$qdir"/mail/new/*.json "$qdir"/mail/cur/*.json; do
        [ -f "$f" ] || continue
        # A document that is not the one asked for, or not JSON, prints nothing.
        if [ "$(jq -r --arg id "$id" 'select(.id == $id) | "found"' "$f" 2>/dev/null)" = found ]; then
            found="$f"
            matches=$((matches + 1))
        fi
    done
    [ -n "$found" ] || error "no mail with id $id in this session's mailbox"
    [ "$matches" -eq 1 ] || error "$matches mails in this session's mailbox carry the id $id; cs -queue accept cannot tell which one was meant"
    # The kind is judged inside jq, on the document's own value: $( ) drops a
    # trailing newline and a NUL, so "task\n" would read as task out here
    # while the digest and the listing, which compare the whole string, show
    # it no accept command. Any other kind comes back marked, with every byte
    # outside a plain word replaced, for the refusal to name.
    kind=$(jq -r '(.kind // "text") | if . == "task" then "task"
        else "other:" + ((if type == "string" then . else tostring end) | gsub("[^A-Za-z0-9._-]"; "_"))[0:16] end' "$found")
    [ "$kind" = "task" ] || error "message $id is ${kind#other:} mail, not a task; only task-kind mail can be queued"
    body=$(jq -r '.body // "" | if type == "string" then . else tostring end' "$found")
    body="$(_trim "$body")"
    [ -n "$body" ] || error "message $id carries an empty task"
    _queue_require_single_line "$body"
    _queue_convert_legacy "$qdir"
    # The accepted message moves from mail/new to mail/cur at the end, so a
    # link either way out of the session is refused here, before the receipt
    # or the task is written: refused at the move, the accept would be
    # recorded and a retry once the link is fixed would be told it was
    # already accepted.
    cs_mkdir_inside "$qdir/queue" && cs_mkdir_inside "$qdir/queue.tmp" \
        && cs_mkdir_inside "$qdir/mail/new" && cs_mkdir_inside "$qdir/mail/cur" || return 1
    local lock="$qdir/queue.accept.mutex.lock" fname
    _cs_lock "$lock" || error "another cs -queue accept holds $lock; retry in a moment"
    if [ -f "$qdir/queue.accepted" ] && grep -qxF -- "$id" "$qdir/queue.accepted"; then
        _cs_unlock "$lock"
        error "message $id was already accepted into the queue (if no copy is queued or done, an earlier accept was interrupted: cs -queue add it by hand)"
    fi
    for f in "$qdir"/queue/*-accept-"$id"; do
        [ -f "$f" ] || continue
        _cs_unlock "$lock"
        error "message $id is already in the queue"
    done
    fname="$(printf '%010d' "$(date +%s)")-accept-$id"
    if ! cs_append_inside "$qdir/queue.accepted" printf '%s\n' "$id"; then
        _cs_unlock "$lock"
        error "could not record the accept in $qdir/queue.accepted"
    fi
    if ! { printf '%s\n' "$body" > "$qdir/queue.tmp/$fname" \
            && mv "$qdir/queue.tmp/$fname" "$qdir/queue/$fname"; }; then
        rm -f "$qdir/queue.tmp/$fname"
        _cs_unlock "$lock"
        error "could not write the task into $qdir/queue; its accept is recorded, so re-queue it with: cs -queue add"
    fi
    _cs_unlock "$lock"
    # Accepting is reading: the message leaves new/ so it neither wakes nor
    # digests again. A failed move leaves it unread, which over-shows the
    # accept command but never re-queues.
    case "$found" in
        "$qdir"/mail/new/*) mv "$found" "$qdir/mail/cur/" 2>/dev/null || true ;;
    esac
    # The body is another session's text on its way to this terminal: shown
    # scrubbed, while the queued file keeps it as mailed.
    info "queued: $(printf '%s' "$body" | _scrub_controls)"
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
# The sections are separated by a blank line: /queue shows this through Claude
# Code's markdown renderer, which otherwise reads the Done heading as part of
# the last pending item.
_queue_list() {  # qdir
    local qdir="$1" f n=0 text len done_len
    len=$(_queue_len "$qdir")
    for f in "$qdir/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        [ "$n" -eq 1 ] && echo "Queued ($len)"
        text=$(<"$f")
        printf '  %d. %s\n' "$n" "${text//$'\n'/ }"
    done
    [ "$n" -gt 0 ] || echo "Queue is empty."
    if [ -s "$qdir/queue.done" ]; then
        done_len=$(awk 'NF{ c++ } END{ print c+0 }' "$qdir/queue.done")
        printf '\nDone (%d)\n' "$done_len"
        awk 'NF{ printf "  - %s\n", $0 }' "$qdir/queue.done"
    fi
}

_queue_rm() {  # qdir, index
    local qdir="$1" n="$2" len
    case "$n" in ''|*[!0-9]*) error "cs -queue rm needs a task number";; esac
    len=$(_queue_len "$qdir")
    [ "$len" -gt 0 ] || { error "queue is empty"; }
    # Refuse before touching anything: an index past the end names no task.
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
}

_queue_clear() {  # qdir
    local qdir="$1"
    rm -rf "$qdir/queue" "$qdir/queue.tmp"
    rm -f "$qdir/queue.state" "$qdir/queue.mode" "$qdir/queue.failed" "$qdir/queue.current"
}

# Arms the queue and records how its tasks run: in the conversation (no mode
# file), each in a subagent, or each as a workflow. The Stop hook reads the
# mode when it hands over a task, and forgets it when the run ends.
#
# A drain in a running session is refused before anything is written: the Stop
# hook's armed branch replaces queue.current without reading it, so re-arming
# mid-drain would hand out the first task again, log nothing done for the one
# in progress, and lose a cs-task-failed line from that turn. A draining state
# with no live lock holder is left by a crash or a close, with no turn in
# progress to run twice, so it re-arms like any other state. The read and the
# writes are not one step: a drain that ends in between costs one more start,
# never a task.
_queue_start() {  # qdir, [mode]
    local qdir="$1" mode="${2:-}" state pid
    case "$mode" in
        ''|subagents|workflow) ;;
        *) error "cs -queue start takes subagents or workflow, not '$mode'" ;;
    esac
    state=$(cat "$qdir/queue.state" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$state" = draining ]; then
        pid=$(live_lock_pid "$CLAUDE_SESSION_META_DIR")
        [ -z "$pid" ] || error "the queue is draining in the running session (pid $pid); the next Stop hands out the next task by itself. To stop the run, cs -queue clear removes the queued tasks with it."
    fi
    cs_mkdir_inside "$qdir"
    case "$mode" in
        '') rm -f "$qdir/queue.mode" ;;
        *) cs_write_atomic "$qdir/queue.mode" printf '%s\n' "$mode" ;;
    esac
    _queue_set_state "$qdir" armed
}

_queue_log() {  # qdir
    local inbox="$1/notifications.jsonl"
    if [ ! -s "$inbox" ]; then
        echo "No queue activity recorded."
        return 0
    fi
    # Tolerant per-line parse (torn lines skipped); oldest-first is file order.
    # Read whole and split inside jq: jq 1.7.1's -R splits a multibyte
    # character at its 4096-byte read buffer.
    jq -rn --rawfile inbox "$inbox" '
        $inbox | split("\n")[] | fromjson? // empty |
        (.ts | strflocaltime("%Y-%m-%d %H:%M")) + "  " + .event +
        (if .task then ": " + .task
         elif .reason then ": " + .reason + " (" + (.reading|tostring) + " >= " + (.limit|tostring) + "), " + (.remaining|tostring) + " remaining"
         elif .done then ": " + (.done|tostring) + " done"
         else "" end)
    ' | _scrub_controls
}

# Dispatcher. Runs inside a session (env) or via the session-scoped arm.
run_queue() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -queue must be run inside a cs session, or as: cs <session> -queue ..."
    fi
    # A claude still running after its session was removed keeps the
    # session's environment; its queue is gone with it.
    [ -d "$CLAUDE_SESSION_META_DIR" ] || error "No such session: ${CLAUDE_SESSION_NAME:-${CLAUDE_SESSION_META_DIR%/.cs}}"
    # The queue sits with the session's other cs files: behind .cs/private in
    # an encrypted session, where a locked vault refuses rather than queue a
    # task beside it in plaintext.
    local qdir
    qdir=$(cs_private_dir "$CLAUDE_SESSION_META_DIR") \
        || error "this session keeps its queue in encrypted storage that is not mounted (.cs/private $(cs_private_state "$CLAUDE_SESSION_META_DIR")). Mount it, then retry."
    _queue_convert_legacy "$qdir"
    local sub="${1:-list}"
    case "$sub" in
        add)   shift; _queue_add "$qdir" "$*";;
        accept) shift; _queue_accept "$qdir" "${1:-}";;
        # Scrubbed once here rather than inside _queue_list's two branches:
        # one construct that cannot be half-removed, and one tr fork instead
        # of one per queued task.
        # _queue_list is a pure reader — it emits no palette variables and
        # never calls error() — so the pipeline eats nothing cs owns.
        list|ls) _queue_list "$qdir" | _scrub_controls;;
        rm)    shift; _queue_rm "$qdir" "${1:-}";;
        clear) _queue_clear "$qdir";;
        start) shift; _queue_start "$qdir" "${1:-}";;
        log)   _queue_log "$qdir";;
        *)     error "Usage: cs -queue [add \"<task>\" | accept <message id> | list | rm <n> | clear | log | start [subagents|workflow]]";;
    esac
}

