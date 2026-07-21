# ABOUTME: main(): the top-level command dispatch and the entry-point call.
# ABOUTME: Assembled last so 'main "$@"' runs after every definition.

main() {
    if [ $# -eq 0 ]; then
        if [ -t 1 ]; then
            local tui_bin
            tui_bin="$(command -v cs-tui 2>/dev/null || echo "$(dirname "$0")/cs-tui")"
            if [ -x "$tui_bin" ]; then
                # Detect the terminal theme while cs still owns the tty so the
                # picker gets a light/dark palette; reused by the session we
                # launch next.
                _export_term_theme
                local tui_output
                tui_output=$(CS_VERSION="$VERSION" "$tui_bin") || exit $?
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
            fi
            show_help
        else
            echo "cs <name>        Create or resume a session"
            echo "cs -list         List all sessions"
            echo "cs -search       Search across sessions"
            echo "cs -help         Show full help"
            echo "cs -version      Show version"
        fi
        exit 0
    fi

    local cmd="$1"

    # Handle subcommands (with - prefix)
    case "$cmd" in
        -h|-help|--help)
            show_help
            return 0
            ;;
        -v|-version|--version)
            echo "cs $VERSION"
            return 0
            ;;
        -list|-ls)
            if command -v cs-tui >/dev/null 2>&1; then
                info "Hint: run bare 'cs' for the interactive session manager"
            fi
            shift
            list_sessions "$@"
            return 0
            ;;
        -remove|-rm)
            shift
            remove_session "$@"
            return 0
            ;;
        -adopt)
            adopt_session "${2:-}"
            return 0
            ;;
        -complete) # hidden: shell-completion plumbing, not a user-facing command
            cmd_complete "${2:-}"
            return 0
            ;;
        -whoami)
            cmd_whoami
            return 0
            ;;
        -who)
            cmd_who
            return 0
            ;;
        -secrets)
            shift
            run_secrets "$@"
            return 0
            ;;
        -uninstall)
            run_uninstall
            return 0
            ;;
        -update)
            local update_arg="${2:-}"
            case "$update_arg" in
                --check|-c)
                    check_update
                    ;;
                --force|-f)
                    do_update "true"
                    ;;
                "")
                    do_update
                    ;;
                *)
                    error "Unknown option: $update_arg. Use 'cs -update [--check|--force]'"
                    ;;
            esac
            return 0
            ;;
        -search)
            shift
            search_sessions "$@"
            return 0
            ;;
        -checkpoint)
            shift
            run_checkpoint "$@"
            return 0
            ;;
        -queue)
            shift
            run_queue "$@"
            return 0
            ;;
        -msg)
            shift
            run_mail "$@"
            return 0
            ;;
        -spawn)
            shift
            run_spawn "$@"
            return 0
            ;;
        -conversations)
            shift
            run_conversations "$@"
            return 0
            ;;
        -status)
            shift
            run_status "$@"
            return 0
            ;;
        -live)
            cmd_live
            return 0
            ;;
        -usage)
            shift
            run_usage "$@"
            return $?
            ;;
        -tag)
            shift
            run_tag "$@"
            return $?
            ;;
        -archive)
            shift
            run_archive "$@"
            return $?
            ;;
        -unarchive)
            shift
            run_unarchive "$@"
            return $?
            ;;
        -doctor|-diag)
            run_doctor
            return $?
            ;;
        -detect-theme)
            detect_term_theme
            return 0
            ;;
        -statusline)
            shift
            run_statusline_cmd "$@"
            return $?
            ;;
        -lint)
            shift
            run_lint "$@"
            return $?
            ;;
        -*)
            error "Unknown command: $cmd. Run 'cs -help' for usage."
            ;;
    esac

    local session_name="$cmd"
    local force_flag=""

    # Validate inputs
    local wt_base="" wt_task=""
    if cs_split_worktree_name "$session_name"; then
        wt_base="$CS_WT_BASE"
        wt_task="$CS_WT_TASK"
    else
        validate_session_name "$session_name"
    fi

    # Parse session subcommands with a while loop to support flag combinations
    shift  # Remove session name / cmd
    while [ $# -gt 0 ]; do
        case "$1" in
            -secrets)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                # Worktree secrets live under the base session's namespace
                # (no launched session ever uses cs:<base>@<task>:*); a plain
                # session name is its own target.
                export CS_SECRETS_SESSION="${wt_base:-$session_name}"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_secrets "$@"
                return 0
                ;;
            -queue)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_queue "$@"
                return 0
                ;;
            -msg)
                shift
                # Send-only: the positional session is the TARGET. The sender's
                # own identity comes from the caller's environment (or none).
                # A bare or lone-'log' invocation is a read attempt aimed at
                # the send-only arm; catch it before 'log' becomes a body.
                if [ $# -eq 0 ]; then
                    error "cs $session_name -msg sends mail and needs a body; to read mail, run 'cs -msg' inside that session"
                fi
                if [ $# -eq 1 ] && [ "$1" = "log" ]; then
                    error "cs $session_name -msg is send-only; to read the mail log, run 'cs -msg log' inside that session"
                fi
                run_mail "$session_name" "$@"
                return 0
                ;;
            -conversations)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_conversations "$@"
                return 0
                ;;
            -usage)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_usage "$session_name" "$@"
                return 0
                ;;
            -tag)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_tag "$@"
                return 0
                ;;
            --merge)
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> --merge <feature>"
                merge_worktree_session "$session_name" "$1"
                return 0
                ;;
            --force)
                force_flag="true"
                shift
                ;;
            *)
                error "Unknown session command: $1. Use -secrets, -queue, -conversations, -usage, -tag, --merge, or --force."
                ;;
        esac
    done

    local session_dir="$SESSIONS_ROOT/$session_name"

    check_dependencies

    # Check for updates (non-blocking)
    check_update_notify

    # Define paths (resolve symlinks for adopted sessions so Claude Code
    # sees the original project path, preserving conversation continuity)
    if [ -L "$session_dir" ]; then
        session_dir="$(_resolve_symlink_dir "$session_dir")"
    fi
    local is_new="false"

    if [ -n "$wt_base" ]; then
        # Worktree session: create from the base, or open the existing one.
        local base_dir
        base_dir=$(_resolve_session_dir "$wt_base")
        if [ ! -e "$base_dir" ]; then
            error "Base session not found: $wt_base"
        fi
        if [ ! -d "$session_dir" ]; then
            is_new="true"
            confirm_clean_worktree_base "$base_dir" "$wt_base"
            session_dir=$(create_worktree_session "$base_dir" "$wt_base" "$wt_task")
        else
            local pinned head_branch
            pinned=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
            head_branch=$(git -C "$session_dir" branch --show-current 2>/dev/null || echo "")
            if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
                warn "Worktree HEAD is '$head_branch' but this feature expects '$pinned' (did something run git switch here?)"
            fi
            # No migrate_session here: worktree checkouts never predate the
            # worktree feature, and its CLAUDE.md rewrite must never touch a
            # project's own file (ignored-.cs repos track their real CLAUDE.md).
        fi
    elif [ ! -d "$session_dir" ]; then
        is_new="true"
        create_session_structure "$session_dir"

        # Initialize local git repo by default
        (
            cd "$session_dir" || exit 0
            create_session_gitignore "$session_dir"
            git init -q 2>/dev/null || true
            git branch -M main 2>/dev/null || true
            setup_merge_attributes "$session_dir"
            git add -A 2>/dev/null || true
            git commit -q -m "Initial session structure" 2>/dev/null || true
        )
    else
        migrate_session "$session_dir"
    fi

    # MSYS (Windows Git Bash) can manage sessions but cannot exec Claude Code
    # itself; the session is prepared above, then handed off to WSL to launch.
    if [ "$(cs_platform)" = "msys" ]; then
        info "Session ready at $session_dir."
        info "On Windows, launch it from WSL (Git Bash supports session management only)."
        return 0
    fi

    # Launch Claude Code
    launch_claude_code "$session_name" "$session_dir" "$is_new" "$force_flag"
}

main "$@"
