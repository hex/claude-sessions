# ABOUTME: Backs 'cs -msg', the cross-session mailbox: send a typed message to
# ABOUTME: another session's maildir; read/log the current session's own mail.

# Bounds render cost, not corruption: delivery is per-message-atomic, so a
# large body can tear nothing. Raised from 4096 only once BOTH shared-file
# appends (mail inbox, walk-away queue) were gone.
MAIL_BODY_MAX=65536

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
    local try id
    for try in 1 2 3 4 5 6 7 8; do
        id=$(printf '%06x' $(( ((RANDOM << 15) | RANDOM) & 0xFFFFFF )))
        # -q stops at the first match and reads files, never a pipe, so it
        # cannot raise SIGPIPE under pipefail.
        if ! grep -q "\"thread\":\"$id\"" \
            "$1"/out/*.json "$1"/new/*.json "$1"/cur/*.json 2>/dev/null; then
            printf '%s' "$id"
            return 0
        fi
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

# Derive the peer and the message being answered from a thread this session can
# see. The newest match wins: 'from' when we received it, 'to' when we sent it.
# Ordering is by filename, which is only a tie-break here — the peer is the same
# at either end of a two-party thread.
_mail_reply_peer() {  # maildir, thread -> "peer<TAB>parent id"; rc 1 unknown, 2 ambiguous
    local maildir="$1" id="$2" f found=1 seen="" peer="" parent="" to="" from=""
    # One jq per document covering both ends and the id; the loop runs in this
    # shell, so the last iteration's values are the newest message's.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=0
        IFS=$'\037' read -r to from parent <<EOF
$(jq -r '[(.to // ""), (.from // ""), (.id // "")] | join("\u001f")' "$f" 2>/dev/null || true)
EOF
        case "$f" in
            "$maildir"/out/*) peer="$to" ;;
            *)                peer="$from" ;;
        esac
        # Six hex digits repeat eventually — a mailbox accumulates roots without
        # bound — and a repeat would merge two unrelated transcripts. Refusing
        # beats guessing: a misrouted reply lands in a stranger's conversation.
        case "$peer" in
            '') : ;;
            *) case "$seen" in
                   '') seen="$peer" ;;
                   "$peer") : ;;
                   *) return 2 ;;
               esac ;;
        esac
    done < <(_mail_thread_files "$maildir" "$id" 2>/dev/null)
    [ "$found" = 0 ] || return 1
    # Unit separator, not tab: tab is IFS whitespace, so bash collapses runs of
    # it and an empty peer would shift the parent id into the caller's first
    # field — silently turning "cannot tell who" into a confident wrong answer.
    printf '%s\037%s' "$peer" "$parent"
}

_mail_send() {  # target, [--kind|-k KIND] [--reply THREAD] body
    local target="$1"; shift
    local kind="text" body="" reply_thread="" reply_parent=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kind|-k)   [ $# -ge 2 ] || error "--kind needs a value"; shift; kind="$1";;
            --reply|-r)  [ $# -ge 2 ] || error "--reply needs a thread id"; shift; reply_thread="$1";;
            *)           body="${body:+$body }$1";;
        esac
        shift
    done
    if [ -n "$reply_thread" ]; then
        [ -n "${CLAUDE_SESSION_META_DIR:-}" ] \
            || error "cs -msg --reply resolves the thread from a session's mailbox; run it inside a session"
        local pair derived rc=0
        pair=$(_mail_reply_peer "$CLAUDE_SESSION_META_DIR/local/mail" "$reply_thread") || rc=$?
        case "$rc" in
            0) : ;;
            2) error "thread $reply_thread names more than one correspondent; it is not a single conversation" ;;
            *) error "No such thread: $reply_thread (cs -msg log lists them)" ;;
        esac
        IFS=$'\037' read -r derived reply_parent <<< "$pair"
        # An explicit target must EQUAL the derived peer. Accepting a different
        # one silently misroutes the reply on a typo, records the wrong peer in
        # out/, and poisons every later derivation in the thread.
        if [ -n "$derived" ]; then
            if [ -n "$target" ] && [ "$target" != "$derived" ]; then
                error "thread $reply_thread is with $derived, not $target"
            fi
            target="$derived"
        elif [ -z "$target" ]; then
            # Reachable: 'from' is empty on mail sent from outside a session.
            error "cannot tell who thread $reply_thread is with; name the target: cs -msg <session> --reply $reply_thread ..."
        fi
    fi
    command -v jq >/dev/null 2>&1 || error "jq is required for cs -msg"
    validate_session_ref "$target"
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
    # A reply joins the thread it answers; a root gets a fresh id, generated
    # against the sender's own mailbox where its earlier roots are recorded.
    if [ -n "$reply_thread" ]; then
        thread="$reply_thread"
    else
        thread="$(_mail_new_thread "${CLAUDE_SESSION_META_DIR:-$target_dir/.cs}/local/mail")"
    fi
    # The body rides on stdin, never as an --arg: `cs -msg <target> -` exists
    # precisely so a multi-KB handoff need not go through argv, and putting it
    # back into jq's argv undid that. -Rs makes the whole of stdin one string,
    # byte for byte, and printf adds nothing to it.
    if ! line=$(printf '%s' "$body" | jq -cRs --arg id "$id" --argjson ts "$now" \
        --arg thread "$thread" --arg to "$target" --arg parent "$reply_parent" \
        --arg from "${CLAUDE_SESSION_NAME:-}" --arg actor "$(cs_actor_slug)" \
        --arg kind "$kind" \
        '{id:$id, ts:$ts, thread:$thread,
          in_reply_to:(if $parent == "" then null else $parent end),
          to:$to, from:$from, actor:$actor, kind:$kind, body:.}'); then
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

# Shared formatter: 'HH:MM  -> peer  [kind]  (thread)  body', with <- for a
# message this session received. Direction is taken from the record rather than
# the file's directory, which keeps this a single line-oriented jq pass over
# every document — and with no early-exit consumer, no SIGPIPE risk on big mail.
# The thread id is rendered because an agent cannot reply into a thread whose id
# it was never shown.
_mail_print_files() {  # file...
    cat "$@" | jq -rR --arg me "${CLAUDE_SESSION_NAME:-}" '
        fromjson? // empty |
        (if $me != "" and (.from // "") == $me then "->" else "<-" end) as $dir |
        (if $dir == "->" then (.to // "?")
         elif (.from // "") == "" then (.actor // "?")
         else .from end) as $peer |
        (.ts | if type == "number" then strflocaltime("%H:%M") else "--:--" end) + "  " +
        $dir + " " + $peer + "  [" + (.kind // "text") + "]  (" + (.thread // "------") + ")  " +
        ((.body // "") | gsub("[\n\r]"; " "))
    ' | _scrub_controls
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
    # Sent copies belong in the history too: without out/, a session cannot see
    # what it said, and cannot find the thread id of any conversation it started.
    for f in "$maildir"/cur/*.json "$maildir"/new/*.json "$maildir"/out/*.json; do
        [ -f "$f" ] || continue
        files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "No mail."
        return 0
    fi
    # Interleave sent, read and unread by filename (the timestamp prefix).
    local sorted=()
    while IFS= read -r f; do
        [ -n "$f" ] && sorted+=("$f")
    done < <(printf '%s\n' "${files[@]}" | awk -F/ '{ print $NF "\t" $0 }' | sort | cut -f2-)
    _mail_print_files "${sorted[@]}"
}

# Collect a thread's documents from everywhere this session holds them: what it
# received (unread and read) and what it sent. Half a thread normally lives in
# the other session's mailbox, which the machine-local design makes ordinary.
# Prints paths in basename order — every caller wants that order, so sorting
# here keeps the mailbox's one ordering rule in one place. One jq pass over the
# whole mailbox rather than a fork per message: nothing prunes a maildir, so a
# per-file fork grows without bound and is paid on every reply as well as every
# thread read.
_mail_thread_files() {  # maildir, thread id -> prints paths, rc 1 when none
    local f all=() out
    # An unmatched glob arrives as its own literal text, and jq given one
    # nonexistent path fails the whole invocation — including the files that do
    # exist. Collect what is really there first.
    for f in "$1"/new/*.json "$1"/cur/*.json "$1"/out/*.json; do
        [ -f "$f" ] && all+=("$f")
    done
    [ "${#all[@]}" -gt 0 ] || return 1
    # One pass for the common case, but jq treats a JSON *parse* error as fatal
    # to the whole invocation and never opens the files after it — so a single
    # torn or forged document would hide every later one, across all three
    # boxes. Every other reader here tolerates a bad document; this one falls
    # back to reading them individually so it does too.
    if ! out=$(jq -r --arg id "$2" 'select((.thread // "") == $id) | input_filename' \
        "${all[@]}" 2>/dev/null); then
        out=""
        for f in "${all[@]}"; do
            [ "$(jq -r '.thread // ""' "$f" 2>/dev/null || true)" = "$2" ] || continue
            out="$out$f
"
        done
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | awk -F/ 'NF {print $NF "\t" $0}' | sort | cut -f2-
}

# Emit one document and everything that answers it, depth first. Reads the
# arrays _mail_thread declares (bash scopes dynamically), so it is only ever
# called from there.
_mail_emit_subtree() {  # index
    local idx="$1" j
    [ "${used[$idx]}" = "0" ] || return 0
    used[$idx]=1
    order+=("${files[$idx]}")
    for ((j = 0; j < n; j++)); do
        if [ "${used[$j]}" = "0" ] && [ -n "${ids[$idx]}" ] \
            && [ "${parents[$j]}" = "${ids[$idx]}" ]; then
            _mail_emit_subtree "$j"
        fi
    done
}

_mail_thread() {  # thread id
    local id="${1:-}"
    [ -n "$id" ] || error "cs -msg thread needs a thread id (cs -msg log lists them)"
    local maildir="$CLAUDE_SESSION_META_DIR/local/mail"
    local files=() f
    # Already in filename order, so siblings answering one parent stay in it.
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(_mail_thread_files "$maildir" "$id" 2>/dev/null || true)
    # An unknown id is an error rather than an empty transcript: a typo that
    # silently shows nothing reads as "the exchange is gone".
    [ "${#files[@]}" -gt 0 ] || error "No such thread: $id"

    # Order by the in_reply_to chain, not by time: ts is whole seconds and a
    # question with its reply inside one second is the normal cadence between
    # agents, so any ts tie-break renders replies above what they answer.
    # Filenames cannot substitute either — same-second order is by unpadded pid.
    local n=${#files[@]} i
    local ids=() parents=() used=() order=() orphans=()
    for ((i = 0; i < n; i++)); do
        # One jq per document for both fields, not one each.
        IFS=$'\037' read -r "ids[$i]" "parents[$i]" <<EOF
$(jq -r '[(.id // ""), (.in_reply_to // "")] | join("\u001f")' "${files[$i]}" 2>/dev/null || true)
EOF
        used[$i]=0
    done

    # Start at the root. Having none is ordinary, not broken: the root lives in
    # the other session's mailbox whenever they started the thread.
    local root=-1
    for ((i = 0; i < n; i++)); do
        case "${parents[$i]}" in ''|null) root=$i; break ;; esac
    done
    [ "$root" -ge 0 ] || root=0
    _mail_emit_subtree "$root"

    for ((i = 0; i < n; i++)); do
        [ "${used[$i]}" = "0" ] && orphans+=("${files[$i]}")
    done

    _mail_print_files "${order[@]}"
    if [ "${#orphans[@]}" -gt 0 ]; then
        echo "  --- the rest of this thread is not on this machine ---"
        _mail_print_files "${orphans[@]}"
    fi
}

# Dispatcher. Reserved first words name a command, not a target session —
# without this table `cs -msg thread a3f9c1` fails with "No such session:
# thread". A body that genuinely starts with a reserved word is still sendable
# by quoting it into a single argument.
run_mail() {
    local first="${1:-}"
    case "$first" in
        ""|log)
            [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || error "cs -msg reads the current session's mail; run it inside a session"
            if [ "$first" = "log" ]; then _mail_log; else _mail_read; fi;;
        thread)
            shift
            [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || error "cs -msg thread reads the current session's mail; run it inside a session"
            _mail_thread "${1:-}";;
        --reply|-r)
            # No target stated: it comes from the thread. The flag stays in the
            # stream so one parser handles both this and the explicit form.
            _mail_send "" "$@";;
        *)
            shift; _mail_send "$first" "$@";;
    esac
}
