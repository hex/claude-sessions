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

    local sessions_root="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"

    # Global flags
    local global_flags="-list -ls -remove -rm -secrets -checkpoint -search -update -uninstall -help -h -version -v"

    # Secrets subcommands
    local secrets_cmds="set store get list ls delete rm purge export export-file import-file migrate backend"

    # Checkpoint subcommands
    local checkpoint_cmds="list show"

    # Update subcommands
    local update_cmds="--check -c --force -f"

    # Session-level options
    local session_opts="-secrets --force"

    # Get list of session names
    _cs_sessions() {
        if [[ -d "$sessions_root" ]]; then
            find "$sessions_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
        fi
    }

    # Determine context based on previous words
    local in_secrets=false
    local in_update=false
    local in_checkpoint=false
    local has_session=false
    local after_remove=false

    for ((i=1; i < cword; i++)); do
        case "${words[i]}" in
            -secrets)
                in_secrets=true
                in_update=false
                in_checkpoint=false
                ;;
            -update)
                in_update=true
                in_secrets=false
                in_checkpoint=false
                ;;
            -checkpoint)
                in_checkpoint=true
                in_secrets=false
                in_update=false
                ;;
            -remove|-rm)
                after_remove=true
                ;;
            -*)
                # Other flags don't change context
                ;;
            *)
                # A non-flag word that's not a subcommand is likely a session name
                if ! $in_secrets && ! $after_remove && ! $in_update && ! $in_checkpoint; then
                    has_session=true
                fi
                ;;
        esac
    done

    # Context: after -remove/-rm, complete with session names
    if $after_remove && [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$(_cs_sessions)" -- "$cur"))
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

    # Context: after session name, complete with session options
    if $has_session; then
        COMPREPLY=($(compgen -W "$session_opts" -- "$cur"))
        return
    fi

    # First argument: session names and global flags
    if [[ $cword -eq 1 ]]; then
        if [[ "$cur" == -* ]]; then
            # Completing a flag
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
        else
            # Completing a session name
            COMPREPLY=($(compgen -W "$(_cs_sessions)" -- "$cur"))
        fi
        return
    fi

    # Default: no completions
    COMPREPLY=()
}

# Register the completion function
complete -F _cs_completions cs
