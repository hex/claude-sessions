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
    # The single funnel for both render sites (run_status and cmd_live) and
    # for the _session_objective fallback, which under `cs -live` is another
    # session's README. Scrubbed on read, not on write: the write path only
    # guards this session's own text, and the threat is a file it never wrote.
    printf '%s' "$status" | _scrub_controls
}

# Print one "<name><tab><state>" line per session Claude Code advertises as
# running ('busy', 'waiting', 'idle'). Claude Code writes one document per
# session at <claude dir>/sessions/<pid>.json and unlinks it on a clean exit; a
# crash orphans it, so a record counts only while its pid is still alive AND
# still reports the process start time the record holds. Without that second
# test a pid the kernel has since handed to an unrelated process would read as
# the session still running.
#
# The whole set is read in one pass — one jq, one ps, one awk — so the fork
# count stays flat however many sessions are live. Callers render every live
# session, and asking per session cost two forks each.
agent_states() {
    local dir="${CS_CLAUDE_DIR:-$HOME/.claude}/sessions" records pidlist="" started pid rest
    [ -d "$dir" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    records="$(jq -r '
        select((.name // "") != "" and (.status // "") != "" and .pid != null)
        | [(.pid | tostring), (.procStart // ""), .name, .status] | @tsv
    ' "$dir"/*.json 2>/dev/null || true)"
    [ -n "$records" ] || return 0

    # Collecting the pids in the shell rather than forking cut keeps this to the
    # three forks the comment above promises.
    while IFS="$(printf '\t')" read -r pid rest; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        pidlist="${pidlist:+$pidlist,}$pid"
    done <<< "$records"
    [ -n "$pidlist" ] || return 0

    # ps prints the start time in the caller's zone and pads the field while the
    # record holds UTC, so the join compares trimmed strings in UTC. Without
    # that, every record outside UTC reads as a pid the kernel has recycled.
    started="$(TZ=UTC "${CS_PS_BIN:-ps}" -o pid=,lstart= -p "$pidlist" 2>/dev/null || true)"

    # Scrubbed like session_status: another process wrote these documents. tr
    # keeps tab and newline, which are this table's own structure.
    # ps output reaches awk through the environment, not -v: an assignment made
    # with -v is processed for escapes and cannot carry the embedded newlines
    # that separate one process from the next.
    CS_PS_RUNNING="$started" awk -F'\t' '
        BEGIN {
            n = split(ENVIRON["CS_PS_RUNNING"], lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line !~ /^[0-9]+[[:space:]]/) continue
                p = line;     sub(/[[:space:]].*$/, "", p)
                start = line; sub(/^[0-9]+[[:space:]]+/, "", start)
                alive[p] = start
            }
        }
        ($1 in alive) && ($2 == "" || alive[$1] == $2) { print $3 "\t" $4 }
    ' <<< "$records" | _scrub_controls
}

# Print the state from an agent_states table for one session, empty when the
# table holds none. Pure shell: the table is read once by the caller and looked
# up per row without another process.
agent_state_of() {  # table, name
    local name rest
    [ -n "$1" ] || return 0
    while IFS="$(printf '\t')" read -r name rest; do
        if [ "$name" = "$2" ]; then
            printf '%s' "$rest"
            return 0
        fi
    done <<< "$1"
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
