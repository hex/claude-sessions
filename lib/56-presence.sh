# ABOUTME: Per-session advertised status (presence). Backs 'cs -status'.
# ABOUTME: A single-line status file at .cs/local/presence, read by 'cs -live'.

# Absolute path to a session's presence file. Arg: the session's .cs meta dir.
_presence_file() {  # meta_dir
    printf '%s' "$1/local/presence"
}

# Write a one-line status atomically (tmp+mv). Newlines/CRs collapse to spaces so
# the file stays exactly one line. Arg: meta_dir, text.
_write_presence() {  # meta_dir, text
    local meta_dir="$1" text="$2" file
    file="$(_presence_file "$meta_dir")"
    mkdir -p "$(dirname "$file")"
    text="$(printf '%s' "$text" | tr '\n\r' '  ')"
    printf '%s\n' "$text" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Print a session's raw presence status (empty if unset). Arg: meta_dir.
_read_presence() {  # meta_dir
    local file line
    file="$(_presence_file "$1")"
    [ -f "$file" ] || return 0
    IFS= read -r line < "$file" || true
    printf '%s' "${line:-}"
}

# Print a session's objective from its README (first non-empty line under the
# '## Objective' heading), with the unfilled [Describe...] placeholder filtered
# to empty. Arg: session_dir (the session root, whose README is .cs/README.md).
_session_objective() {  # session_dir
    local readme="$1/.cs/README.md"
    [ -f "$readme" ] || return 0
    awk '
        /^##[[:space:]]+Objective/ { grab=1; next }
        grab && /^##[[:space:]]/    { exit }
        grab && NF {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\[.*\]$/) next
            print line
            exit
        }
    ' "$readme" 2>/dev/null || true
}

# Print a session's effective status: presence file, else README objective,
# else empty. Arg: session_dir (the session root).
session_status() {  # session_dir
    local session_dir="$1" status
    status="$(_read_presence "$session_dir/.cs")"
    [ -n "$status" ] || status="$(_session_objective "$session_dir")"
    printf '%s' "$status"
}

# Dispatcher for 'cs -status'. In-session only (ambient env), like run_queue.
run_status() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -status must be run inside a cs session"
    fi
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    if [ $# -eq 0 ]; then
        local session_dir status
        session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}"
        status="$(session_status "$session_dir")"
        if [ -n "$status" ]; then printf '%s\n' "$status"; else echo "(none)"; fi
        return 0
    fi
    case "$1" in
        --clear|-c)
            rm -f "$(_presence_file "$meta_dir")"
            ;;
        "")
            error "cs -status: empty status; use 'cs -status --clear' to clear"
            ;;
        *)
            _write_presence "$meta_dir" "$*"
            ;;
    esac
}
