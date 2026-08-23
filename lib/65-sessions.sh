# ABOUTME: Cross-session search, the session listing table, and session removal.
# ABOUTME: Backs 'cs -search', 'cs -list', and 'cs -rm'.

search_sessions() {
    local query="" include_archived="" arg
    for arg in "$@"; do
        case "$arg" in
            --include-archived) include_archived="true" ;;
            *) [ -n "$query" ] || query="$arg" ;;
        esac
    done

    if [ -z "$query" ]; then
        error "Usage: cs -search <query> [--include-archived]"
    fi

    # grep exits 2 when the pattern will not compile and 1 on a clean no-match.
    # The per-file calls below map every non-zero status to `continue`, so an
    # uncompilable pattern made every file miss and the run finished by printing
    # "No results" — a false negative presented as an authoritative answer. The
    # pattern is invariant across files, so probe it once, with the same grep and
    # the same flags the loops use. Probed before the SESSIONS_ROOT check so a
    # typo is not reported as an empty machine.
    local probe_status=0
    grep -in -- "$query" /dev/null >/dev/null 2>&1 || probe_status=$?
    if [ "$probe_status" -gt 1 ]; then
        error "Invalid search pattern '$query': grep cannot compile it"
    fi

    if [ ! -d "$SESSIONS_ROOT" ]; then
        info "No sessions found"
        return 0
    fi

    local found=0
    local search_files=".cs/README.md"
    local search_globs=".cs/memory/*.md"

    for session_dir in "$SESSIONS_ROOT"/*/; do
        [ -d "$session_dir" ] || continue
        if [ -z "$include_archived" ] && _session_is_archived "$session_dir"; then
            continue
        fi
        local session_name
        session_name=$(basename "$session_dir")

        # Resolve symlinks for adopted sessions
        local real_dir
        real_dir=$(cd "$session_dir" 2>/dev/null && pwd -P) || continue

        # Search fixed files
        for relpath in $search_files; do
            local filepath="$real_dir/$relpath"
            [ -f "$filepath" ] || continue
            local matches
            matches=$(grep -in -- "$query" "$filepath" 2>/dev/null) || continue
            while IFS= read -r line; do
                # %s for the matched line: `echo -e` ate escapes in file content,
                # so a line containing \c truncated the result there and dropped
                # everything after it.
                printf "${GOLD}%s${NC}: ${DIM}%s${NC}: %s\n" "$session_name" "$relpath" "$line"
                found=$((found + 1))
            done <<< "$matches"
        done

        # Search glob patterns (memory files)
        for filepath in "$real_dir"/$search_globs; do
            [ -f "$filepath" ] || continue
            local relpath="${filepath#"$real_dir"/}"
            local matches
            matches=$(grep -in -- "$query" "$filepath" 2>/dev/null) || continue
            while IFS= read -r line; do
                # %s for the matched line: `echo -e` ate escapes in file content,
                # so a line containing \c truncated the result there and dropped
                # everything after it.
                printf "${GOLD}%s${NC}: ${DIM}%s${NC}: %s\n" "$session_name" "$relpath" "$line"
                found=$((found + 1))
            done <<< "$matches"
        done
    done

    if [ "$found" -eq 0 ]; then
        info "No results for '$query'"
    fi
}

# True when a directory is a cs session. A .cs/ directory marks the current
# layout; a root CLAUDE.md marks a pre-.cs/ session that has not been migrated.
# SESSIONS_ROOT also holds unrelated directories (editor config, an empty
# worktrees holder) that carry neither.
is_session_dir() {
    [ -d "$1/.cs" ] || [ -f "$1/CLAUDE.md" ]
}

# The name cs knows a directory by, or non-zero when the directory is not a
# session cs can open. Backs bare `cs` opening the session you are standing in.
#
# Detects on .cs/ alone, where is_session_dir also accepts a root CLAUDE.md:
# listing a stray directory is a cosmetic error, launching one is not.
_session_name_for_dir() {  # dir
    local dir root rest
    [ -d "$1/.cs" ] || return 1
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    root=$(cd "${SESSIONS_ROOT:-}" 2>/dev/null && pwd -P) || return 1

    # Both sides resolved before comparing: a sessions root reached through a
    # symlinked parent (macOS /var -> /private/var) never prefix-matches a
    # resolved directory otherwise. Same lesson as _session_root_is_cs_owned.
    case "$dir" in
        "$root"/*)
            rest="${dir#"$root"/}"
            case "$rest" in
                */*) return 1 ;;  # inside a session, not the session itself
                *) printf '%s\n' "$rest"; return 0 ;;
            esac
            ;;
    esac

    # An adopted session lives at the user's own project path and is linked into
    # the root under its cs name — which is the name the lock, the secrets
    # namespace and Claude Code's --name all key on, so it is the answer here.
    local link
    for link in "${SESSIONS_ROOT:-}"/*; do
        [ -L "$link" ] || continue
        [ "$(cd "$link" 2>/dev/null && pwd -P)" = "$dir" ] || continue
        printf '%s\n' "${link##*/}"
        return 0
    done
    return 1
}

# Print every session name, one per line, as completion candidates. Symlinks
# count: `cs -adopt` links repos that live elsewhere on disk into SESSIONS_ROOT,
# and the marker tests resolve through the link. Kept free of git and keychain
# lookups so a TAB press stays fast.
complete_sessions() {
    [ -d "$SESSIONS_ROOT" ] || return 0

    local dir
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        printf '%s\n' "${dir##*/}"
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 | sort -z)
}

# Emit completion candidates for a given subject. Shell completion scripts call
# this instead of reimplementing enumeration in zsh glob and bash find dialects.
cmd_complete() {
    case "${1:-}" in
        sessions) complete_sessions ;;
        *) error "Unknown completion subject: ${1:-<none>}" ;;
    esac
}

# The session bare `cs` opens from where it was run, or nothing when it would
# show the picker instead. Answers for the dispatch and for the `cs -list` hint
# alike, so the hint can never name a command that does something else.
#
# Nothing inside a launched session, whose shells inherit its name: there the
# request would be to open a second copy of the session you are already in.
_bare_cs_target() {
    [ -z "${CLAUDE_SESSION_NAME:-}" ] || return 1
    _session_name_for_dir "$PWD"
}

# The picker binary, or non-zero when none is installed. Every caller asks
# through here — the collision menu offers its row only when this answers, so
# the menu can never name a picker that run_tui would then fail to find.
_tui_bin() {
    local bin
    bin="$(command -v cs-tui 2>/dev/null || true)"
    if [ -z "$bin" ]; then
        # Not on PATH (cs may be run by explicit path with its own dir off
        # PATH, which the installer permits): probe the sibling next to this
        # script.
        local _self_dir
        _self_dir="$(dirname "$0")"
        if [ -x "$_self_dir/cs-tui" ]; then bin="$_self_dir/cs-tui"; fi
    fi
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    printf '%s\n' "$bin"
}

# The interactive session manager. The picker prints its choice on stdout — the
# session name, optionally followed by flags — and cs re-enters itself with it,
# so every launch takes the same path an explicit `cs <name>` does. Returns
# non-zero when no picker binary is installed, leaving the caller to say so.
run_tui() {
    local tui_bin
    tui_bin="$(_tui_bin)" || return 1

    # Detect the terminal theme while cs still owns the tty so the picker gets
    # a light/dark palette; reused by the session we launch next.
    _export_term_theme
    local tui_output
    tui_output=$(CS_VERSION="$VERSION" CS_BIN="$0" "$tui_bin") || exit $?
    if [ -n "$tui_output" ]; then
        local selected="${tui_output%%$'\n'*}"
        if [ "$tui_output" != "$selected" ]; then
            local tui_flags="${tui_output#*$'\n'}"
            exec "$0" "$selected" $tui_flags
        else
            exec "$0" "$selected"
        fi
    fi
    exit 0
}

# List all sessions
list_sessions() {
    local tag_filter="" archived_only=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag)
                shift
                [ -n "${1:-}" ] || error "Usage: cs -list [--archived] [--tag <tag>]"
                # Stored tags are always lowercase (cs -tag add lowercases on
                # write); lowercase the filter too so it matches regardless
                # of case, mirroring the TUI's parse_tag_query.
                tag_filter=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
                shift
                ;;
            --archived)
                archived_only="true"
                shift
                ;;
            *) error "Unknown list option: $1. Usage: cs -list [--archived] [--tag <tag>]" ;;
        esac
    done

    if [ ! -d "$SESSIONS_ROOT" ]; then
        info "No sessions found"
        return 0
    fi

    local sessions=()
    local hidden_archived=0
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        if [ -n "$tag_filter" ]; then
            _tags_read "$dir/.cs/README.md" | grep -Fqx "$tag_filter" || continue
        fi
        if [ -n "$archived_only" ]; then
            _session_is_archived "$dir" || continue
        elif _session_is_archived "$dir"; then
            hidden_archived=$((hidden_archived + 1))
            continue
        fi
        sessions+=("$(basename "$dir")")
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 | sort -z)

    if [ ${#sessions[@]} -eq 0 ]; then
        info "No sessions found"
        _list_archived_trailer "$hidden_archived"
        return 0
    fi

    # Dump the keychain once; per-session counts are computed inline in the
    # display loop. No associative array — bash 3.2 lacks `local -A`.
    local keychain_dump=""
    if command -v cs-secrets >/dev/null 2>&1; then
        keychain_dump=$(security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="cs:[^"]*"' || true)
    fi

    # Find max session name length for column alignment
    local max_len=7  # minimum "SESSION" header length
    for session in "${sessions[@]}"; do
        if [ ${#session} -gt $max_len ]; then
            max_len=${#session}
        fi
    done

    # Print header
    printf "${RUST}%-${max_len}s  %-16s  %s${NC}\n" "SESSION" "CREATED" "MODIFIED"
    printf "${COMMENT}%-${max_len}s  %-16s  %s${NC}\n" "$(printf '%*s' "$max_len" '' | tr ' ' '-')" "----------------" "----------------"

    # Print sessions
    for session in "${sessions[@]}"; do
        local session_dir="$SESSIONS_ROOT/$session"
        local created="-"
        local modified="-"

        local log_file="$session_dir/.cs/local/session.log"
        # Fall back to older locations for unmigrated sessions
        [ ! -f "$log_file" ] && log_file="$session_dir/.cs/logs/session.log"
        [ ! -f "$log_file" ] && log_file="$session_dir/logs/session.log"
        if [ -f "$log_file" ]; then
            # Parse created timestamp using bash builtins (avoids forking head|grep|cut)
            local line started=""
            local lines_read=0
            while IFS= read -r line && [ $lines_read -lt 4 ]; do
                lines_read=$((lines_read + 1))
                if [[ "$line" == Started:* ]]; then
                    started="${line#Started: }"
                    break
                fi
            done < "$log_file"
            if [ -z "$started" ]; then
                # Parse timestamp from "YYYY-MM-DD HH:MM:SS - Session started" format
                IFS= read -r line < "$log_file" || true
                if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                    started="${BASH_REMATCH[1]}"
                fi
            fi
            if [ -n "$started" ]; then
                # Trim to YYYY-MM-DD HH:MM
                created="${started%:*}"
            fi
            modified=$(get_file_mtime "$log_file")
        fi

        # Count this session's secrets from the one-time keychain dump. The
        # trailing ':' keeps 'foo' from matching 'foobar' entries; grep -F so
        # session names with '.'/'-' are matched literally.
        local secret_count=0
        if [ -n "$keychain_dump" ]; then
            secret_count=$(printf '%s\n' "$keychain_dump" | grep -cF "\"cs:${session}:" || true)
        fi

        # Build secret indicator (accounts for display width in padding)
        local secret_indicator=""
        local indicator_len=0
        if [ "$secret_count" -gt 0 ]; then
            secret_indicator=" (${ICON_LOCK} ${secret_count})"
            indicator_len=${#secret_indicator}
        fi

        # Calculate padding (max_len - session length - indicator length)
        local pad_len=$((max_len - ${#session} - indicator_len))
        [ $pad_len -lt 0 ] && pad_len=0
        local padding=$(printf '%*s' "$pad_len" '')

        # Print with proper alignment
        if [ "$secret_count" -gt 0 ]; then
            printf "${GOLD}%s${NC}${COMMENT}%s${NC}%s  ${COMMENT}%-16s  %s${NC}\n" "$session" "$secret_indicator" "$padding" "$created" "$modified"
        else
            printf "${GOLD}%s${NC}%s  ${COMMENT}%-16s  %s${NC}\n" "$session" "$padding" "$created" "$modified"
        fi
    done

    _list_archived_trailer "$hidden_archived"
}

# Remove a session
# Remove each named session in turn; every deletion keeps its own confirm.
# All names are validated before anything is deleted: an empty name would
# resolve to the sessions root itself and rm -rf every session.
remove_session() {
    local force="" arg _name
    local names
    names=()
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force="true" ;;
            -*) error "Unknown remove option: $arg. Usage: cs -remove <session-name>... [--force]" ;;
            *)
                [ -n "$arg" ] || error "Usage: cs -remove <session-name>... [--force] (empty session name)"
                names+=("$arg") ;;
        esac
    done
    [ "${#names[@]}" -ge 1 ] || error "Usage: cs -remove <session-name>... [--force]"
    for _name in "${names[@]}"; do
        _remove_one_session "$_name" "$force"
    done
}

_remove_one_session() {
    local session_name="$1"
    local force="${2:-}"
    [ -n "$session_name" ] || error "Refusing to remove an empty session name"

    # Reject path traversal before any filesystem action: '.'/'..' and any
    # name with a slash would resolve rm -rf outside the sessions root. A
    # worktree name (<base>@<task>) has an @ but never a slash, so it passes.
    case "$session_name" in
        .|..|*/*) error "Invalid session name: $session_name" ;;
    esac

    local session_dir="$SESSIONS_ROOT/$session_name"

    if [ ! -d "$session_dir" ] && [ ! -L "$session_dir" ]; then
        error "Session not found: $session_name"
    fi

    if [ -z "$force" ] && session_is_live "$session_dir/.cs"; then
        error "Session '$session_name' is live (pid $(read_lock_pid "$session_dir/.cs")); use --force to remove anyway"
    fi

    # Worktree sessions: unregister from git, not just delete the directory.
    case "$session_name" in
        *@*)
            local wt_base_name="${session_name%%@*}"
            local wt_base_dir
            wt_base_dir=$(_resolve_session_dir "$wt_base_name")
            if [ -d "$wt_base_dir" ] && [ -f "$session_dir/.git" ]; then
                local wt_branch
                wt_branch=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
                read -r -p $'\033[0;31mRemove worktree session '"'$session_name'"$'? Uncommitted work in it is discarded. [y/N] \033[0m' confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    info "Cancelled"
                    return 0
                fi
                git -C "$wt_base_dir" worktree remove --force "$session_dir" \
                    || error "git worktree remove failed for $session_dir"
                if [ -n "$wt_branch" ] \
                    && git -C "$wt_base_dir" rev-parse -q --verify "refs/heads/$wt_branch" >/dev/null 2>&1; then
                    read -r -p "Delete branch $wt_branch too? [y/N] " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        git -C "$wt_base_dir" branch -D "$wt_branch" 2>/dev/null || true
                    fi
                fi
                _spawn_discard_seeds "$session_name"
                info "Removed worktree session: $session_name"
                return 0
            fi
            ;;
    esac

    # Confirm deletion
    if [ -L "$session_dir" ]; then
        local target
        target="$(_resolve_symlink_dir "$session_dir")"
        read -r -p $'\033[0;31mRemove adopted session '"'$session_name'"$'? (removes symlink only, project at '"$target"$' is preserved) [y/N] \033[0m' confirm
    else
        read -r -p $'\033[0;31mRemove session '"'$session_name'"$'? [y/N] \033[0m' confirm
    fi
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        return 0
    fi

    if [ -L "$session_dir" ]; then
        rm "$session_dir"
        info "Removed session link: $session_name (project directory preserved)"
    else
        rm -rf "$session_dir"
        info "Removed session: $session_name"
    fi
    _spawn_discard_seeds "$session_name"
}

# Launch Claude Code
# Register or remove the cs-statusline entry in Claude Code's settings.json.
# Enable overwrites whatever is registered (the command is explicit consent);
# Strip the statusLine registration when (and only when) it points at
# cs-statusline; a status line the user configured themselves is left alone.
# Returns 0 when stripped, 1 when absent or foreign, 2 when the write failed.

# Compact duration string from seconds: 45s, 12m, 3h, 2d. Arg: secs.
_humanize_secs() {  # secs
    local s="$1"
    case "$s" in ''|*[!0-9]*) echo "0s"; return 0;; esac
    if   [ "$s" -lt 60 ];    then echo "${s}s"
    elif [ "$s" -lt 3600 ];  then echo "$(( s / 60 ))m"
    elif [ "$s" -lt 86400 ]; then echo "$(( s / 3600 ))h"
    else echo "$(( s / 86400 ))d"
    fi
}

# List cs sessions whose process is currently alive on THIS machine.
cmd_live() {
    if [ ! -d "$SESSIONS_ROOT" ]; then
        echo "No other live cs sessions."
        return 0
    fi
    local now current others=0
    now="$(date +%s)"
    current="${CLAUDE_SESSION_NAME:-}"

    local dir name meta actor up agent status states
    states="$(agent_states)"
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        meta="$dir/.cs"
        session_display_live "$meta" "$now" || continue
        name="$(basename "$dir")"
        actor="$(session_actor_slug "$dir")"
        up="$(_humanize_secs "$(session_uptime_secs "$meta" "$now")")"
        agent="$(agent_state_of "$states" "$name")"
        if [ "$name" = "$current" ]; then
            status="(this session)"
        else
            others=$(( others + 1 ))
            status="$(session_status "$dir")"
        fi
        # The agent column stays padded when Claude Code advertises nothing, so
        # the objective still lines up on a host that keeps no session records.
        printf "${GREEN}●${NC} ${GOLD}%-18s${NC} ${COMMENT}%-10s %-5s %-7s${NC} %s\n" \
            "$name" "$actor" "$up" "$agent" "$status"
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 | sort -z)

    if [ "$others" -eq 0 ]; then
        echo "No other live cs sessions."
    fi
}
