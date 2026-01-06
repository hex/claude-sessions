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
    local global_flags="-list -ls -remove -rm -sync -s -secrets -update -uninstall -help -h -version -v"

    # Sync subcommands
    local sync_cmds="init push pull status st auto clone"

    # Secrets subcommands
    local secrets_cmds="set store get list ls delete rm purge export export-file import-file migrate backend"

    # Get list of session names
    _cs_sessions() {
        if [[ -d "$sessions_root" ]]; then
            find "$sessions_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
        fi
    }

    # Determine context based on previous words
    local in_sync=false
    local in_secrets=false
    local has_session=false
    local after_remove=false

    for ((i=1; i < cword; i++)); do
        case "${words[i]}" in
            -sync|-s)
                in_sync=true
                in_secrets=false
                ;;
            -secrets)
                in_secrets=true
                in_sync=false
                ;;
            -remove|-rm)
                after_remove=true
                ;;
            -*)
                # Other flags don't change context
                ;;
            *)
                # A non-flag word that's not a subcommand is likely a session name
                if ! $in_sync && ! $in_secrets && ! $after_remove; then
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

    # Context: after -sync or -s, complete with sync subcommands
    if $in_sync; then
        COMPREPLY=($(compgen -W "$sync_cmds" -- "$cur"))
        return
    fi

    # Context: after -secrets, complete with secrets subcommands
    if $in_secrets; then
        COMPREPLY=($(compgen -W "$secrets_cmds" -- "$cur"))
        return
    fi

    # Context: after session name, complete with -sync or -secrets
    if $has_session; then
        COMPREPLY=($(compgen -W "-sync -s -secrets" -- "$cur"))
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
