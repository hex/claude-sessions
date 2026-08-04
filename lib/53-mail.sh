# ABOUTME: Backs 'cs -msg', the cross-session mailbox: send a typed message to
# ABOUTME: another session's maildir; read/log the current session's own mail.

# Bounds render cost, not corruption: delivery is per-message-atomic, so a
# large body can tear nothing. Raised from 4096 only once BOTH shared-file
# appends (mail inbox, walk-away queue) were gone.
MAIL_BODY_MAX=65536

# Strip C0 control characters (keeping tab and newline) and DEL from stdin,
# so a message body cannot smuggle ANSI/OSC sequences into a terminal.
_mail_scrub() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# The mailbox is a maildir: a message is written whole to tmp/, then renamed
# into new/ (unread) — the rename is same-filesystem, so a message is either
# entirely present or entirely absent. 'cs -msg' moves what it prints into
# cur/ (read). Unread is simply the count of new/*.json.
_mail_ensure_maildir() {  # maildir
    mkdir -p "$1/tmp" "$1/new" "$1/cur" "$1/out"
}

# Thread ids are 6 hex digits because an agent has to retype them. RANDOM is 15
# bits, so two draws cover the 24. Collisions matter — a repeat would merge two
# unrelated transcripts and misroute replies — so generation avoids the roots
# already in this mailbox rather than trusting 24 bits on their own.
_mail_new_thread() {  # maildir
    local n try id
    for try in 1 2 3 4 5 6 7 8; do
        id=$(printf '%06x' $(( ((RANDOM << 15) | RANDOM) & 0xFFFFFF )))
        n=$(grep -l "\"thread\":\"$id\"" "$1"/out/*.json "$1"/new/*.json "$1"/cur/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
        [ "${n:-0}" = "0" ] && { printf '%s' "$id"; return 0; }
    done
    printf '%s' "$id"
}

# The sender keeps its own copy of everything it sends, so either end can
# re-read the exchange — without it a rotated agent cannot find out what it
# already said. Best-effort by design: the message is already delivered, and a
# failure to file the copy must never report the send as failed.
_mail_keep_sent() {  # line, fname
    [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || return 0
    local mine="$CLAUDE_SESSION_META_DIR/local/mail"
    _mail_ensure_maildir "$mine" 2>/dev/null || return 0
    if ! { printf '%s\n' "$1" > "$mine/tmp/$2" 2>/dev/null \
            && mv "$mine/tmp/$2" "$mine/out/$2" 2>/dev/null; }; then
        rm -f "$mine/tmp/$2" 2>/dev/null || true
    fi
    return 0
}

_mail_send() {  # target, [--kind|-k KIND] body
    local target="$1"; shift
    local kind="text" body=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kind|-k) [ $# -ge 2 ] || error "--kind needs a value"; shift; kind="$1";;
            *)         body="${body:+$body }$1";;
        esac
        shift
    done
    command -v jq >/dev/null 2>&1 || error "jq is required for cs -msg"
    case "$target" in ''|.|..|*/*) error "cs -msg needs a plain session name as target";; esac
    local target_dir="$SESSIONS_ROOT/$target"
    is_session_dir "$target_dir" || error "No such session: $target"
    if [ "$target" = "${CLAUDE_SESSION_NAME:-}" ]; then
        error "Refusing to send mail to the current session"
    fi
    case "$kind" in notify|task|text|result) : ;; *) error "Unknown kind: $kind (notify|task|text|result)";; esac
    body="$(_trim "$body")"
    # A lone '-' body reads the real body from stdin: a multi-KB handoff does
    # not belong in argv, and this is what makes the larger cap reachable.
    if [ "$body" = "-" ]; then
        body="$(cat)"
        body="$(_trim "$body")"
    fi
    [ -n "$body" ] || error "cs -msg needs a non-empty body"
    local bytes
    bytes=$(LC_ALL=C printf '%s' "$body" | wc -c | tr -d '[:space:]')
    if [ "$bytes" -gt "$MAIL_BODY_MAX" ]; then
        error "Message body exceeds ${MAIL_BODY_MAX} bytes"
    fi
    if [ "$kind" = "task" ]; then
        # $(printf '\n') would collapse to "" (command substitution strips
        # trailing newlines); the literal embedded newline below does not.
        local nl='
'
        case "$body" in
            *"$nl"*) error "task bodies must be a single line (the queue's done log and listing are line-oriented)";;
        esac
        # Queue first, attribution second: if the queue write fails nothing is
        # sent; if the mail write fails the work is still delivered.
        _queue_add "$target_dir/.cs/local" "$body"
    fi
    # Deliver into the RECIPIENT's tmp/, then rename into its new/: both live
    # in one tree, so the rename is atomic even for adopted (symlinked)
    # sessions, where a sender-side tmp/ could sit on another volume and
    # degrade the mv to copy-then-unlink.
    local maildir="$target_dir/.cs/local/mail"
    # Everything after _queue_add must fail gracefully for a task-kind send:
    # the work is already queued, so aborting here makes the sender believe the
    # send failed, and a retry queues the task a second time. The maildir
    # creation and the record-composing jq are as able to fail as the write
    # below (an unwritable mailbox, a mail/ path that is a regular file).
    if ! _mail_ensure_maildir "$maildir" 2>/dev/null; then
        if [ "$kind" = "task" ]; then
            warn "task queued in $target, but its mailbox could not be opened for attribution"
            return 0
        fi
        error "Failed to open ${target}'s mailbox"
    fi
    local now id line fname thread
    now="$(date +%s)"
    # The pid keeps two senders inside one second apart; a bare RANDOM suffix
    # collides ~1 in 32768 per pair and mv clobbers silently.
    id="${now}-$$-${RANDOM}"
    # Generated against the sender's own mailbox, which is where the roots this
    # session started are recorded.
    thread="$(_mail_new_thread "${CLAUDE_SESSION_META_DIR:-$target_dir/.cs}/local/mail")"
    if ! line=$(jq -cn --arg id "$id" --argjson ts "$now" \
        --arg thread "$thread" --arg to "$target" \
        --arg from "${CLAUDE_SESSION_NAME:-}" --arg actor "$(cs_actor_slug)" \
        --arg kind "$kind" --arg body "$body" \
        '{id:$id, ts:$ts, thread:$thread, in_reply_to:null, to:$to, from:$from, actor:$actor, kind:$kind, body:$body}'); then
        if [ "$kind" = "task" ]; then
            warn "task queued in $target, but composing the mail attribution failed"
            return 0
        fi
        error "Failed to compose the message for $target"
    fi
    # Zero-padded epoch keeps lexical order aligned with time order; NOT a
    # monotonic clock (same-second order is by unpadded pid, and the wall
    # clock can go backwards) — nothing may treat name order as arrival order.
    fname="$(printf '%010d' "$now")-${id}.json"
    if ! { printf '%s\n' "$line" > "$maildir/tmp/$fname" \
            && mv "$maildir/tmp/$fname" "$maildir/new/$fname"; }; then
        rm -f "$maildir/tmp/$fname"
        if [ "$kind" = "task" ]; then
            warn "task queued in $target, but recording the mail attribution failed"
            return 0
        fi
        error "Failed to write to ${target}'s mailbox"
    fi
    _mail_keep_sent "$line" "$fname"
    info "sent to $target (thread $thread); surfaces at their next turn"
}

# Shared formatter: print message documents as 'HH:MM  sender  [kind]  body'.
# Each document is a single-line JSON object, so one line-oriented jq pass
# renders them all (no early-exit consumers -> no SIGPIPE risk on big mail).
_mail_print_files() {  # file...
    cat "$@" | jq -rR '
        fromjson? // empty |
        (.ts | if type == "number" then strflocaltime("%H:%M") else "--:--" end) + "  " +
        (if .from == "" then .actor else .from end) + "  [" + .kind + "]  " +
        (.body | gsub("[\n\r]"; " "))
    ' | _mail_scrub
}

_mail_read() {
    local maildir="$CLAUDE_SESSION_META_DIR/local/mail"
    local f files=()
    for f in "$maildir"/new/*.json; do
        [ -f "$f" ] || continue
        files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "No unread mail."
        return 0
    fi
    _mail_print_files "${files[@]}"
    # Exactly what was printed moves to cur/; a message landing between the
    # glob and here stays unread for the next read. One mv for the batch:
    # filenames carry the sender's pid, so a basename cannot collide in cur/.
    _mail_ensure_maildir "$maildir"
    mv "${files[@]}" "$maildir/cur/"
}

_mail_log() {
    local maildir="$CLAUDE_SESSION_META_DIR/local/mail"
    local f files=()
    for f in "$maildir"/cur/*.json "$maildir"/new/*.json; do
        [ -f "$f" ] || continue
        files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "No mail."
        return 0
    fi
    # Interleave read and unread history by filename (the timestamp prefix).
    local sorted=()
    while IFS= read -r f; do
        [ -n "$f" ] && sorted+=("$f")
    done < <(printf '%s\n' "${files[@]}" | awk -F/ '{ print $NF "\t" $0 }' | sort | cut -f2-)
    _mail_print_files "${sorted[@]}"
}

# Dispatcher. Bare = read own inbox; 'log' = full history; else = send.
run_mail() {
    local first="${1:-}"
    case "$first" in
        ""|log)
            [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || error "cs -msg reads the current session's mail; run it inside a session"
            if [ "$first" = "log" ]; then _mail_log; else _mail_read; fi;;
        *)
            shift; _mail_send "$first" "$@";;
    esac
}
