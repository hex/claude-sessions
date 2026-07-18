# ABOUTME: Backs 'cs -msg', the cross-session mailbox: send a typed message to
# ABOUTME: another session's inbox; read/log the current session's own inbox.

MAIL_BODY_MAX=4096

# Strip C0 control characters (keeping tab and newline) and DEL from stdin,
# so a message body cannot smuggle ANSI/OSC sequences into a terminal.
_mail_scrub() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# Count complete (newline-terminated) lines. wc -l counts newline bytes, so a
# torn final line still being written is excluded from cursor math.
_mail_total() {  # file
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d '[:space:]'
    else
        echo 0
    fi
}

_mail_cursor() {  # cursor_file
    local v=""
    if [ -f "$1" ]; then IFS= read -r v < "$1" || true; fi
    case "$v" in ''|*[!0-9]*) v=0;; esac
    echo "$v"
}

_mail_set_cursor() {  # cursor_file, value
    printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Print inbox lines from..to inclusive. awk bounds both ends without the
# early-exit SIGPIPE risk of head/sed on large files.
_mail_slice() {  # file, from_line, to_line
    awk -v a="$2" -v b="$3" 'NR>=a && NR<=b' "$1"
}

_mail_send() {  # target, [--kind|-k KIND] [--ref ID] body
    local target="$1"; shift
    local kind="text" ref="" body=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kind|-k) shift; kind="${1:-}";;
            --ref)     shift; ref="${1:-}";;
            *)         body="${body:+$body }$1";;
        esac
        shift
    done
    command -v jq >/dev/null 2>&1 || error "jq is required for cs -msg"
    case "$target" in ''|*/*) error "cs -msg needs a plain session name as target";; esac
    local target_dir="$SESSIONS_ROOT/$target"
    is_session_dir "$target_dir" || error "No such session: $target"
    if [ "$target" = "${CLAUDE_SESSION_NAME:-}" ]; then
        error "Refusing to send mail to the current session"
    fi
    case "$kind" in notify|task|text|result) : ;; *) error "Unknown kind: $kind (notify|task|text|result)";; esac
    if [ -n "$ref" ] && [ "$kind" != "result" ]; then
        error "--ref is only valid with --kind result"
    fi
    body="${body#"${body%%[![:space:]]*}"}"  # ltrim
    body="${body%"${body##*[![:space:]]}"}"  # rtrim
    [ -n "$body" ] || error "cs -msg needs a non-empty body"
    local bytes
    bytes=$(LC_ALL=C printf '%s' "$body" | wc -c | tr -d '[:space:]')
    if [ "$bytes" -gt "$MAIL_BODY_MAX" ]; then
        error "Message body exceeds ${MAIL_BODY_MAX} bytes"
    fi
    local maildir="$target_dir/.cs/local/mail"
    mkdir -p "$maildir"
    local now line
    now="$(date +%s)"
    line=$(jq -cn --arg id "${now}-$$-${RANDOM}" --argjson ts "$now" \
        --arg from "${CLAUDE_SESSION_NAME:-}" --arg actor "$(cs_actor_slug)" \
        --arg kind "$kind" --arg body "$body" --arg ref "$ref" \
        '{id:$id, ts:$ts, from:$from, actor:$actor, kind:$kind, body:$body,
          ref:(if $ref == "" then null else $ref end)}')
    printf '%s\n' "$line" >> "$maildir/inbox.jsonl" \
        || error "Failed to write to ${target}'s mailbox"
    info "sent to $target; surfaces at their next turn"
}

# Dispatcher. Bare = read own inbox; 'log' = full history; else = send.
run_mail() {
    local first="${1:-}"
    case "$first" in
        "")  error "cs -msg: reading arrives in a later task";;
        log) error "cs -msg log: reading arrives in a later task";;
        *)   shift; _mail_send "$first" "$@";;
    esac
}
