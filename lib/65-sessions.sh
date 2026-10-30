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
    local -a search_globs=(".cs/memory/*.md" ".cs/narrative-archive/*/*.md" ".cs/private/narrative-archive/*/*.md")

    # Hidden entries too: a session named before leading dots were refused
    # (.work) is still a session to search.
    for session_dir in "$SESSIONS_ROOT"/*/ "$SESSIONS_ROOT"/.[!.]*/ "$SESSIONS_ROOT"/..?*/; do
        [ -d "$session_dir" ] || continue
        if [ -z "$include_archived" ] && _session_is_archived "$session_dir"; then
            continue
        fi
        local session_name
        session_name=$(basename "$session_dir")

        # Resolve symlinks for adopted sessions
        local real_dir
        real_dir=$(cd -- "$session_dir" 2>/dev/null && pwd -P) || continue

        # Search fixed files
        for relpath in $search_files; do
            local filepath="$real_dir/$relpath"
            [ -f "$filepath" ] || continue
            local matches
            matches=$(grep -in -- "$query" "$filepath" 2>/dev/null) || continue
            while IFS= read -r line; do
                # %s for the matched line: `echo -e` ate escapes in file content,
                # so a line containing \c truncated the result there and dropped
                # everything after it. The line is what the session's repo
                # says, so its control bytes are deleted.
                printf "${GOLD}%s${NC}: ${DIM}%s${NC}: %s\n" "$session_name" "$relpath" "$(printf '%s' "$line" | _scrub_controls)"
                found=$((found + 1))
            done <<< "$matches"
        done

        # Search glob patterns (memory files and rotated narrative chunks).
        # search_globs is an array, not a space-joined string split with an
        # unquoted `for glob in $search_globs`: that split is also subject to
        # pathname expansion, so a pattern like .cs/memory/*.md would expand
        # against the caller's cwd (matching real files there) before it ever
        # reached $real_dir, silently searching the wrong session.
        local glob
        for glob in "${search_globs[@]}"; do
            for filepath in "$real_dir"/$glob; do
                [ -f "$filepath" ] || continue
                # .cs/memory and the narrative archive are tracked, so a clone
                # chooses the file name: it is printed as a plain name.
                local relpath
                relpath=$(_cs_plain_name "${filepath#"$real_dir"/}" 160)
                local matches
                matches=$(grep -in -- "$query" "$filepath" 2>/dev/null) || continue
                while IFS= read -r line; do
                    # %s for the matched line: `echo -e` ate escapes in file content,
                    # so a line containing \c truncated the result there and dropped
                    # everything after it. The line is what the session's repo
                    # says, so its control bytes are deleted.
                    printf "${GOLD}%s${NC}: ${DIM}%s${NC}: %s\n" "$session_name" "$relpath" "$(printf '%s' "$line" | _scrub_controls)"
                    found=$((found + 1))
                done <<< "$matches"
            done
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
# session cs can open. Backs `cs .` opening the session you are standing in.
#
# Detects on .cs/ alone, where is_session_dir also accepts a root CLAUDE.md:
# listing a stray directory is a cosmetic error, launching one is not.
_session_name_for_dir() {  # dir
    local dir root rest
    [ -d "$1/.cs" ] || return 1
    dir=$(cd -- "$1" 2>/dev/null && pwd -P) || return 1
    root=$(cd -- "${SESSIONS_ROOT:-}" 2>/dev/null && pwd -P) || return 1

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
        [ "$(cd -- "$link" 2>/dev/null && pwd -P)" = "$dir" ] || continue
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

    if command -v cs-tui >/dev/null 2>&1; then
        info "Hint: run bare 'cs' for the interactive session manager"
    fi

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

        local log_file="$session_dir/.cs/private/session.log"
        # An encrypted session keeps its log behind .cs/private; every other
        # one in .cs/local. Fall back to older locations for unmigrated sessions
        [ ! -f "$log_file" ] && log_file="$session_dir/.cs/local/session.log"
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
    local force="" delete_files="" arg _name
    local names
    names=()
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force="true" ;;
            --delete-files) delete_files="true" ;;
            -*) error "Unknown remove option: $arg. Usage: cs -remove <session-name>... [--force [--delete-files]]" ;;
            *)
                [ -n "$arg" ] || error "Usage: cs -remove <session-name>... [--force] (empty session name)"
                names+=("$arg") ;;
        esac
    done
    [ "${#names[@]}" -ge 1 ] || error "Usage: cs -remove <session-name>... [--force]"
    # Set by _remove_one_session when a session went but its age state did
    # not: the other names still go, and the run ends non-zero.
    local age_state_left=""
    # Before any name goes: a live session of another conversation's user,
    # or a base with a live feature when the caller is not that base, stops
    # the whole run, so none of the names before it is removed either. So
    # does a session a `cs <name> --remote` server serves, --force or not, as
    # it refuses an open: the server and the sessions it starts run in it.
    for _name in "${names[@]}"; do
        _refuse_live_other_session "$_name" "$SESSIONS_ROOT/$_name/.cs" remove
        _refuse_base_with_live_feature "$_name" remove
        _remote_refuse_live "$_name" "$SESSIONS_ROOT/$_name/.cs" ""
    done
    for _name in "${names[@]}"; do
        _remove_one_session "$_name" "$force" "$delete_files"
    done
    [ -z "$age_state_left" ] || return 1
}

# Top-level entries of a session root that cs did not put there, one name
# per line as _names_as_lines writes them (nothing when there are none). cs
# owns .cs/, .claude/, the session git files and the two CLAUDE files;
# .DS_Store is Finder's. notes.md, changes.md, discoveries.md, logs/ and
# artifacts/ are where legacy cs layouts kept session files at the root. A
# third-party cache (.omc, .claude-crawl) is not cs's to delete silently, so
# it still counts. Fails without perl, as _names_as_lines does.
_session_foreign_entries() {  # session_dir
    local dir="$1" entry name
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name="${entry##*/}"
        case "$name" in
            .cs|.claude|.git|.gitignore|.gitattributes|CLAUDE.md|CLAUDE.local.md|.DS_Store) continue ;;
            notes.md|changes.md|discoveries.md|logs|artifacts) continue ;;
        esac
        printf '%s\0' "$name"
    done | _names_as_lines
}

# The names _session_foreign_entries prints, as one comma-separated line,
# each as a message prints it (_printable_name).
_session_foreign_line() {  # foreign_entries
    local line name out=""
    while IFS= read -r line; do
        printf -v name '%b' "$line"
        out="${out:+$out, }$name"
    done <<< "$1"
    _printable_name "$out"
}

# The confirm's listing of the names _session_foreign_entries prints, one
# per line indented four spaces as _untracked_listing_format prints a file,
# at most 20, then how many are not shown.
_session_foreign_listing() {  # foreign_entries
    local line listing nl=$'\n'
    listing=$(while IFS= read -r line; do printf '1\t%s\n' "$line"; done <<< "$1" \
        | _untracked_listing_format 20) || return 1
    printf '%s' "${listing#*"$nl"}"
}

# The first mount point at or under a directory, from the mount table text on
# stdin (empty when there is none). macOS lists "<dev> on <path> (<opts>)",
# Linux "<dev> on <path> type <fs> (<opts>)", and neither escapes its fields:
# a source may hold " on " and a path " on ", " type " or " (". So each line
# is read the Linux way (cut at its last " type ") and then the macOS way, and
# in each every absolute path that follows an " on " is a candidate. Each cut
# keeps the space after "on", so a source ending in " on", whose " on" shares
# that space with the separator, still leaves the separator to find. Each
# candidate's ancestors are compared with -ef, which sees through letter case
# and symlinks where a string prefix would not.
_mount_under() {  # dir
    local dir="$1" line body text mnt p
    while IFS= read -r line; do
        body="${line% (*}"
        for text in "${body% type *}" "$body"; do
            while :; do
                case "$text" in
                    *" on "*) text="${text#* on}" ;;
                    *) break ;;
                esac
                case "$text" in " /"*) mnt="${text# }" ;; *) continue ;; esac
                p="$mnt"
                while [ -n "$p" ]; do
                    if [ "$p" -ef "$dir" ]; then
                        printf '%s' "$mnt"
                        return 0
                    fi
                    p="${p%/*}"
                done
            done
        done
    done
    return 0
}

# The first volume mounted at or under a directory, from the live mount
# table; empty when there is none. rm -rf and git worktree remove recurse into
# a mount, so every path that deletes a directory asks this first. Fails when
# `mount` does, so the caller refuses instead of guessing.
_volume_mounted_under() {  # dir
    local table
    table=$(mount) || return 1
    _mount_under "$1" <<< "$table"
}

# Paths in a worktree session that git does not track (untracked or
# ignored), one per line (_names_as_lines); git worktree remove --force
# deletes them with no copy on the branch. The set retire reads: the
# worktree's own untracked and ignored files and every file inside a
# submodule, without cs's own bookkeeping (_without_cs_bookkeeping), so a
# CLAUDE.local.md of the user's own and, in tracked mode, an untracked file
# under .cs are listed. Fails when git cannot list them.
_worktree_untracked_paths() {  # worktree_dir
    local listing more
    listing=$(_worktree_others "$1") || return 1
    more=$(_worktree_others "$1" --ignored) || return 1
    [ -z "$more" ] || listing="${listing:+$listing$'\n'}$more"
    more=$(_submodule_others "$1" "") || return 1
    [ -z "$more" ] || more=$(printf '%s\n' "$more" | _without_cs_bookkeeping "$1") || return 1
    [ -z "$more" ] || listing="${listing:+$listing$'\n'}$more"
    [ -z "$listing" ] || printf '%s\n' "$listing"
}

_remove_one_session() {
    local session_name="$1"
    local force="${2:-}"
    local delete_files="${3:-}"
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

    if [ -z "$force" ]; then
        local live_pid
        live_pid=$(live_lock_pid "$session_dir/.cs")
        [ -z "$live_pid" ] || error "Session '$session_name' is live (pid $live_pid); use --force to remove anyway"
    fi

    # An encrypted session mounts its vault inside the session directory by
    # convention, and rm -rf recurses into a mount: removing the session would
    # delete what the vault holds. A link that resolves into this directory
    # means the vault is mounted here, so refuse, --force or not. An adopted
    # session loses only its link below, so it is exempt.
    if [ ! -L "$session_dir" ]; then
        local sub link real_dir real_target
        real_dir=$(cd -- "$session_dir" && pwd -P)
        for sub in $CS_VAULT_LINKS; do
            link="$session_dir/.cs/$sub"
            [ -L "$link" ] || continue
            real_target=$(cd -- "$link" 2>/dev/null && pwd -P) || continue
            case "$real_target" in
                "$real_dir"/*)
                    error "Session '$session_name' has encrypted storage mounted inside it: .cs/$sub points at $(_cs_plain_name "$(readlink "$link")" 160). Removing the session would delete what the vault holds; unmount it, then retry." ;;
            esac
        done
        # A cs -encrypt that stopped partway leaves its volume mounted with no
        # link yet, so the links above cannot see it; the mount table can.
        local mounted
        mounted=$(_volume_mounted_under "$session_dir") \
            || error "cs -rm could not read the mount table, so it cannot tell whether a volume is mounted inside '$session_name'; refusing to remove it."
        [ -z "$mounted" ] \
            || error "Session '$session_name' has a volume mounted inside it at $mounted. Removing the session would delete what the volume holds; unmount it, then retry."
    fi

    # Every confirmation below reads from stdin; a script piping input through
    # a non-tty without --force used to hit a `read` that failed silently and
    # exited 1 with no explanation. Refuse loudly, before any mutation, unless
    # --force stands in for the confirmation or a human is actually there to answer.
    if [ -z "$force" ] && ! cs_interactive; then
        error "cs -rm needs a terminal to confirm removing '$session_name'; use --force to skip confirmation"
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
                local untracked untracked_listing="" nl=$'\n'
                untracked=$(_worktree_untracked_paths "$session_dir") \
                    || error "git could not list the files in $session_dir; refusing to remove what it cannot list"
                if [ -n "$untracked" ]; then
                    untracked_listing=$(_untracked_listing "$session_dir" "$untracked") \
                        || error "cs could not count the files git does not track in $session_dir; refusing to remove what it cannot list"
                fi
                if [ -n "$untracked" ] && [ -n "$force" ] && [ -z "$delete_files" ]; then
                    local untracked_count="${untracked_listing%%"$nl"*}" them=them
                    [ "$untracked_count" != "1 file" ] || them=it
                    error "Worktree session '$session_name' holds $untracked_count git does not track:
${untracked_listing#*"$nl"}
Add --delete-files to remove $them with --force"
                fi
                local confirm
                if [ -n "$force" ]; then
                    confirm="y"
                else
                    [ -z "$untracked" ] || printf '%bAlso deletes %s git does not track:\n%s%b\n' "$RED" \
                        "${untracked_listing%%"$nl"*}" "${untracked_listing#*"$nl"}" "$NC" >&2
                    read -r -p $'\033[0;31mRemove worktree session '"'$session_name'"$'? Uncommitted work in it is discarded. [y/N] \033[0m' confirm
                fi
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    info "Cancelled"
                    return 0
                fi
                git -C "$wt_base_dir" worktree remove --force "$session_dir" \
                    || error "git worktree remove failed for $session_dir"
                if [ -n "$wt_branch" ] \
                    && git -C "$wt_base_dir" rev-parse -q --verify "refs/heads/$wt_branch" >/dev/null 2>&1; then
                    if [ -n "$force" ]; then
                        confirm="n"
                    else
                        read -r -p "Delete branch $wt_branch too? [y/N] " confirm
                    fi
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

    # A cs-created root is also the user's workspace: rm -rf takes whatever
    # they put beside cs's own files (an encrypted image, a checkout). Name
    # those in the confirm, and make --force ask for them by name.
    local foreign=""
    if [ ! -L "$session_dir" ]; then
        foreign=$(_session_foreign_entries "$session_dir") \
            || error "cs could not list the files in $session_dir; refusing to remove what it cannot list"
    fi
    if [ -n "$foreign" ] && [ -n "$force" ] && [ -z "$delete_files" ]; then
        local foreign_line
        foreign_line=$(_session_foreign_line "$foreign") \
            || error "cs could not list the files in $session_dir; refusing to remove what it cannot list"
        error "Session '$session_name' holds files cs did not create: $foreign_line. Add --delete-files to remove them with --force"
    fi

    # Confirm deletion
    local confirm
    if [ -n "$force" ]; then
        confirm="y"
    elif [ -L "$session_dir" ]; then
        local target
        target="$(_resolve_symlink_dir "$session_dir")"
        read -r -p $'\033[0;31mRemove adopted session '"'$session_name'"$'? (removes symlink only, project at '"$target"$' is preserved) [y/N] \033[0m' confirm
    else
        # read -p only shows its prompt on a terminal; the list must reach
        # the user even when the answer is piped in.
        if [ -n "$foreign" ]; then
            local foreign_listing
            foreign_listing=$(_session_foreign_listing "$foreign") \
                || error "cs could not list the files in $session_dir; refusing to remove what it cannot list"
            printf '%bAlso deletes files cs did not create:\n%s%b\n' "$RED" "$foreign_listing" "$NC" >&2
        fi
        read -r -p $'\033[0;31mRemove session '"'$session_name'"$'? [y/N] \033[0m' confirm
    fi
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        return 0
    fi

    local drop_age_state=""
    if [ -L "$session_dir" ]; then
        rm "$session_dir"
        info "Removed session link: $session_name (project directory preserved)"
    else
        rm -rf "$session_dir"
        info "Removed session: $session_name"
        # Gated on the name, not the branch taken: a base@task whose base is
        # gone falls through to the rm -rf above, and a feature session uses
        # its base's secrets (CS_SECRETS_SESSION), so the state is the base's.
        # A dotted name (a hand-made session older than the dot refusal) is
        # skipped as the picker's age_state_dir skips it.
        case "$session_name" in
            *@*|.*) ;;
            *) drop_age_state="true" ;;
        esac
    fi
    _spawn_discard_seeds "$session_name"
    if [ -n "$drop_age_state" ]; then
        _drop_session_age_state "$session_name" || age_state_left="true"
    fi
}

# Remove the age state cs-secrets keeps for a base session outside the
# session directory: ~/.cs-secrets/sessions/<name>/ (recipient pins and
# digests). Twin of age_state_dir in bin/cs-secrets and age_state_dir in
# tui/src/app.rs; the three change together. Prints one line naming the path
# when there was something to remove, nothing otherwise. A name that is not a
# single plain path component is refused before it becomes a path, so "" can
# never resolve to the sessions directory itself. Keychain and encrypted
# stored secrets are not touched. cs-secrets refuses an age command for a
# session the sessions root does not have, so only an `age add` or an export
# that passed that check before the removal can recreate this directory after
# it: their lock (.age.lock) lives inside it. That window is accepted (Alex
# 2026-10-11); a lock shared with the removal was weighed and declined, do not
# add one.
_drop_session_age_state() {  # name
    local name="$1" dir
    case "$name" in
        ''|.*|*/*|*@*)
            warn "Refusing to remove age state for an invalid base session name: '$name'"
            return 1 ;;
    esac
    dir="$HOME/.cs-secrets/sessions/$name"
    # Each parent must be a real directory cs can search: through a link the
    # rm -rf would land on a same-name directory elsewhere, and an unsearchable
    # parent makes a present state read as absent.
    local parent linked=false
    for parent in "$HOME/.cs-secrets" "$HOME/.cs-secrets/sessions"; do
        [ -L "$parent" ] && linked=true
        [ -e "$parent" ] || return 0
        if [ ! -d "$parent" ] || [ ! -x "$parent" ]; then
            warn "Could not check age state: $dir"
            return 1
        fi
    done
    if [ "$linked" = true ]; then
        # Reading through the link is harmless once every parent is known to
        # be searchable; only a state that is there is named as left behind.
        [ -e "$dir" ] || [ -L "$dir" ] || return 0
        warn "Left age state behind a linked ~/.cs-secrets: $dir"
        return 1
    fi
    [ -e "$dir" ] || [ -L "$dir" ] || return 0
    rm -rf "$dir" || { warn "Could not remove age state: $dir"; return 1; }
    info "Removed age state: $dir"
}

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

    local dir name meta actor up agent status states spid
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
        # A session cs <name> --remote serves: the server is no conversation
        # Claude Code advertises, so the agent column says remote and the
        # status leads with the server's pid.
        if spid="$(_remote_server_pid "$meta" "$name")"; then
            agent="remote"
            status="remote-control PID $spid${status:+ · $status}"
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
