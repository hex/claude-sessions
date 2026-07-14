# ABOUTME: Bash completion script for cs (Claude Code session manager)
# ABOUTME: Provides tab-completion for session names, commands, and subcommands

_cs_completions() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    # Global flags
    local global_flags="-list -ls -adopt -remove -rm -whoami -who -secrets -checkpoint -queue -search -lint -statusline -detect-theme -doctor -diag -update -uninstall -help -h -version -v -live -usage -status"

    # Secrets subcommands
    local secrets_cmds="set store get list ls delete rm purge export export-file import-file migrate migrate-backend backend age"

    # Checkpoint subcommands
    local checkpoint_cmds="list show"

    # Queue subcommands
    local queue_cmds="add list ls rm clear start defer"

    # Update subcommands
    local update_cmds="--check -c --force -f"

    # Session-level options
    local session_opts="-secrets -queue --force --merge"

    # Get list of session names. cs owns the definition of a session, including
    # which symlinks and marker directories count; asking it keeps this script
    # from drifting out of step with `cs -list`.
    _cs_sessions() {
        cs -complete sessions 2>/dev/null
    }

    # Append the session names that prefix-match $1 to COMPREPLY. Names are matched
    # as data with a case glob rather than fed to `compgen -W`, whose word list is
    # split on IFS and expanded: an unquoted name with a space would split into
    # pieces and one with a star would pathname-expand against the cwd.
    _cs_add_session_matches() {
        local cur="$1" line
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                "$cur"*) COMPREPLY+=("$line") ;;
            esac
        done < <(_cs_sessions)
    }

    # Determine context based on previous words
    local in_secrets=false
    local in_update=false
    local in_checkpoint=false
    local in_queue=false
    local has_session=false
    local after_remove=false

    for ((i=1; i < cword; i++)); do
        case "${words[i]}" in
            -secrets)
                in_secrets=true
                in_update=false
                in_checkpoint=false
                in_queue=false
                ;;
            -update)
                in_update=true
                in_secrets=false
                in_checkpoint=false
                in_queue=false
                ;;
            -checkpoint)
                in_checkpoint=true
                in_secrets=false
                in_update=false
                in_queue=false
                ;;
            -queue)
                in_queue=true
                in_secrets=false
                in_update=false
                in_checkpoint=false
                ;;
            -remove|-rm)
                after_remove=true
                ;;
            -*)
                # Other flags don't change context
                ;;
            *)
                # A non-flag word that's not a subcommand is likely a session name
                if ! $in_secrets && ! $after_remove && ! $in_update && ! $in_checkpoint && ! $in_queue; then
                    has_session=true
                fi
                ;;
        esac
    done

    # Context: after -remove/-rm, complete with session names
    if $after_remove && [[ $cword -eq 2 ]]; then
        COMPREPLY=()
        _cs_add_session_matches "$cur"
        return
    fi

    # Context: after -update, complete with update subcommands
    if $in_update; then
        COMPREPLY=($(compgen -W "$update_cmds" -- "$cur"))
        return
    fi

    # Context: after -secrets, complete with secrets subcommands
    if $in_secrets; then
        COMPREPLY=($(compgen -W "$secrets_cmds" -- "$cur"))
        return
    fi

    # Context: after -checkpoint, complete with checkpoint subcommands
    if $in_checkpoint; then
        COMPREPLY=($(compgen -W "$checkpoint_cmds" -- "$cur"))
        return
    fi

    # Context: after -queue, complete with queue subcommands
    if $in_queue; then
        COMPREPLY=($(compgen -W "$queue_cmds" -- "$cur"))
        return
    fi

    # Context: after session name, complete with session options
    if $has_session; then
        COMPREPLY=($(compgen -W "$session_opts" -- "$cur"))
        return
    fi

    # First argument: session names and global flags. Offer both, so that a bare
    # `cs <TAB>` answers "what can I type here" in full. A leading dash rules out
    # every session name, so skip the enumeration entirely in that case.
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
        if [[ "$cur" != -* ]]; then
            _cs_add_session_matches "$cur"
        fi
        return
    fi

    # Default: no completions
    COMPREPLY=()
}

# Register the completion function
complete -F _cs_completions cs
