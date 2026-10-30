# ABOUTME: main(): the top-level command dispatch and the entry-point call.
# ABOUTME: Assembled last so 'main "$@"' runs after every definition.

# A named verb (cs <name> -queue, -narrative, -secrets) writes into
# the session without opening it, so the open's refusals never ran on this
# path (Codex r2 #3). Run them here before the verb touches anything.
_vet_named_session() {  # session_dir
    is_session_dir "$1" || return 0
    cs_assert_local_untracked "$1"
}

# cs -queue and cs -msg run inside a session read the queue and the mailbox of
# the session the environment names, the same files the hooks stand down
# from while git tracks one of them, so they refuse on the same question. Only
# that question: the open's other refusals walk every link under .cs, which
# would cost these verbs a fork per link on every call.
_vet_current_session() {
    local dir="${CLAUDE_SESSION_DIR:-}" notice
    [ -n "$dir" ] || dir="${CLAUDE_SESSION_META_DIR:-}"
    dir=${dir%/.cs}
    [ -n "$dir" ] && is_session_dir "$dir" || return 0
    ! notice=$(cs_files_tracked_notice "$dir/.cs" "$dir") || error "$notice"
}

# cs -vet-session <dir>: the same question about the session at <dir>,
# whatever the environment names. The cs mod asks it before it arms a
# rotation (a pending-handoff marker git tracks names one the SessionStart
# hook refuses to load) or writes into .cs/local, and /wrap before its marker.
# Prints nothing and exits 0 when cs trusts the files.
cmd_vet_session() {  # session directory
    local notice
    [ $# -eq 1 ] || error "Usage: cs -vet-session <session directory>"
    [ -d "$1/.cs" ] || error "$1 is not a cs session"
    ! notice=$(cs_files_tracked_notice "$1/.cs" "$1") || error "$notice"
}

main() {
    # This launch's arguments as given, for the relaunch an accepted update
    # ends with: the arms below shift them away as they read them.
    local -a launch_argv=("$@")
    # cs IS the launch, and the hooks read that from the ABSENCE of this marker
    # (hooks/cs-resolve.sh preserves an inherited value rather than setting
    # one). A teammate's shell carries CS_RESOLVED_FROM=walk deliberately, so
    # without this an inherited marker rides into everything cs starts —
    # `cs -spawn` most of all — and that session's SessionEnd reads itself as a
    # walked-in front end and declines to clear its own lock. cs never reads the
    # variable, so dropping it here costs nothing and covers every exec path.
    unset CS_RESOLVED_FROM

    # A launcher that composes `<binary> -- <operands>` hands cs the POSIX
    # end-of-options separator, which the unknown-verb arm read as a command
    # nobody could have typed. Drop one, and read the rest exactly as before.
    if [ "${1:-}" = "--" ]; then
        shift
    fi

    if [ $# -eq 0 ]; then
        if [ -t 1 ]; then
            # Bare cs is the picker everywhere, a session directory included;
            # `cs .` is the explicit way to open the session you stand in.
            # `||`, not two statements: run_tui returns non-zero only when no
            # picker is installed, and under `set -e` a bare failing call would
            # end cs there — printing nothing at all on the machines that need
            # the help most.
            run_tui || show_help
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

    # `cs <verb> --help` before the arms: each one resolves a session or parses
    # its own arguments first, so the flag would arrive as data. -secrets is
    # exempt because it forwards to cs-secrets, which holds the reference for
    # its own verbs; a derived usage line would answer in that reference's place.
    case "$cmd" in
        -secrets) ;;
        -*) if _is_help_flag "${2:-}"; then show_verb_help "$cmd"; return $?; fi ;;
    esac

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
        -tui)
            run_tui || error "The session manager (cs-tui) is not installed. Reinstall cs, or run 'cs -list'."
            return 0
            ;;
        -list|-ls)
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
            # Adopt writes the session's files and names them in notice rows,
            # so the palette follows the terminal as an open's does.
            _export_term_theme
            setup_palette
            if [ "${2:-}" = "--worktrees" ]; then
                shift 2
                adopt_worktrees "$@"
            else
                shift
                adopt_session "$@"
            fi
            return 0
            ;;
        -complete) # hidden: shell-completion plumbing, not a user-facing command
            cmd_complete "${2:-}"
            return 0
            ;;
        -vet-session) # asked by the cs mod, /rotate and /wrap before they write into a session
            shift
            cmd_vet_session "$@"
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
            # The session this cs runs in, empty outside every session:
            # cs-secrets refuses its writes to another live session's secrets.
            export CS_SECRETS_CALLER="${CLAUDE_SESSION_NAME:-}"
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
        -narrative)
            shift
            run_narrative "$@"
            return 0
            ;;
        -archive-tasks) # hidden: driven by the rotate skill and /wrap, not typed by a user
            shift
            _vet_current_session
            run_archive_tasks "$@"
            return 0
            ;;
        -queue)
            shift
            _vet_current_session
            run_queue "$@"
            return 0
            ;;
        -msg)
            shift
            _vet_current_session
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
        -encrypt)
            shift
            run_encrypt "$@"
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
        -config)
            shift
            cmd_config "" "$@"
            return $?
            ;;
        -*)
            error "Unknown command: $cmd. Run 'cs -help' for usage."
            ;;
    esac

    # `cs .` opens the session you are standing in, under the name cs knows it
    # by (an adopted project's cs name, not its directory's). Resolved here so
    # the lock, migration and launch are the ones `cs <name>` gets. Never
    # adopts: a directory that is not a session is refused, not made into one.
    if [ "$cmd" = "." ]; then
        cmd=$(_session_name_for_dir "$PWD") \
            || error "Not a cs session: $PWD. Run 'cs -adopt <name>' to make it one, or bare 'cs' to pick a session."
    fi

    local session_name="$cmd"
    local force_flag=""
    local merge_feature=""
    local remote_flag="" remote_mode=""

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
    # The separator can arrive here too, between the session and its flags.
    # Only in this position: further in, `--` is a word in a verb's own
    # arguments — a mail body may legitimately contain one.
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    # `cs <name> <verb> --help` — same reasoning as the global form above,
    # including the -secrets exemption.
    case "${1:-}" in
        -secrets) ;;
        -*) if _is_help_flag "${2:-}"; then show_verb_help "$1"; return $?; fi ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            -secrets)
                shift
                _vet_named_session "$SESSIONS_ROOT/$session_name"
                # A worktree's secrets route to its base, so the base is the
                # session cs-secrets writes into (Codex r3 #3).
                [ -z "$wt_base" ] || _vet_named_session "$SESSIONS_ROOT/$wt_base"
                # The caller's own session, kept before CLAUDE_SESSION_NAME
                # becomes the target: cs-secrets refuses writes to another
                # live session's secrets.
                export CS_SECRETS_CALLER="${CLAUDE_SESSION_NAME:-}"
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
                _vet_named_session "$SESSIONS_ROOT/$session_name"
                # Another session's word never puts work in front of this
                # session's drain: its add travels as task mail for this
                # session's user to accept, and arming or accepting stays with
                # that user. A terminal outside any session is the user.
                local caller="${CLAUDE_SESSION_NAME:-}"
                if _called_from_other_session "$session_name"; then
                    case "${1:-}" in
                        add)
                            shift
                            _mail_send "$session_name" --kind task "$*"
                            return 0
                            ;;
                        start)
                            error "session $caller cannot start $session_name's queue; $session_name's user starts it (cs -queue start inside $session_name)"
                            ;;
                        accept)
                            error "session $caller cannot accept mail into $session_name's queue; $session_name's user accepts it (cs -queue accept ${2:-<id>} inside $session_name)"
                            ;;
                        rm|clear)
                            error "session $caller cannot change $session_name's queue; $session_name's user does that inside $session_name (cs -queue $1)"
                            ;;
                    esac
                fi
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
                # 'thread' names a reading command and always takes an argument,
                # so the lone-word shape above cannot catch it: unguarded,
                # `cs freya -msg thread a3f9c1` silently mails freya the words
                # "thread a3f9c1". Quoting the body into one argument still
                # sends it.
                case "${1:-}" in
                    thread)
                        error "cs $session_name -msg is send-only; to read a thread, run 'cs -msg thread ${2:-<id>}' inside that session"
                        ;;
                esac
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
            -narrative)
                shift
                # Reachable from outside any session — the picker shells out
                # this way. A worktree session's directory is literally
                # "<base>@<task>" under the sessions root and carries its own
                # .cs, so one path serves both forms: a worktree rotates its
                # OWN narrative, unlike -secrets, which routes a worktree to
                # the base's namespace. Guarded on cs's own is_session_dir, not
                # on bare existence: an adopted session is a symlink into the
                # user's project, and a dangling one passes -L but has no .cs
                # behind it, so the failure would surface as rotate_narrative's
                # "run from inside a session" — which answers the global form
                # and misnames this one's fault.
                is_session_dir "$SESSIONS_ROOT/$session_name" \
                    || error "No such session: $session_name"
                # The cut rewrites the narrative a running conversation
                # appends to; from inside another session that waits.
                _refuse_live_other_session "$session_name" "$SESSIONS_ROOT/$session_name/.cs" "rotate the narrative of"
                _vet_named_session "$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_narrative "$@"
                return 0
                ;;
            -config)
                shift
                cmd_config "$session_name" "$@"
                return $?
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
            -features)
                shift
                run_features "$session_name" "$@"
                return 0
                ;;
            -integrate-feature) # hidden: driven by skills/finish/scripts/finish.sh, not typed by a user
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>"
                # Validate <base>@<feature> the same way the launch path does, so a
                # task name with path separators is rejected before any
                # filesystem lookup.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                integrate_feature_worktree "$session_name" "$@"
                return 0
                ;;
            -retire-feature) # hidden: driven by skills/finish/scripts/finish.sh, not typed by a user
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> -retire-feature <task> <sha> [--force]"
                # Validate <base>@<feature> the same way the launch path does,
                # so a task name with path separators (which would build an
                # escaping worktree path) is rejected before any filesystem
                # lookup. cs_split_worktree_name errors on a bad base or task.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                retire_feature_worktree "$session_name" "$@"
                return 0
                ;;
            -finish)
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> -finish <feature>"
                # Validate the same way the launch path does, so a feature name with
                # path separators is rejected before any filesystem lookup.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                merge_feature="$1"
                shift
                ;;
            --force)
                force_flag="true"
                shift
                ;;
            --remote)
                remote_flag="true"
                shift
                ;;
            --permission-mode)
                case "${2:-}" in
                    ''|-*) error "--permission-mode needs a mode: cs $session_name --remote --permission-mode <mode>" ;;
                esac
                remote_mode="$2"
                shift 2
                ;;
            *)
                error "Unknown session command: $1. Use -secrets, -queue, -msg, -narrative, -conversations, -config, -usage, -tag, -features, -finish, --force, --remote, or --permission-mode."
                ;;
        esac
    done

    # --remote serves the session through claude remote-control. The mode is
    # passed through as given; remote-control refuses one it does not know.
    # With none given, _remote_claude_bin takes the one CLAUDE_CODE_BIN sets,
    # else default.
    if [ -n "$remote_mode" ] && [ -z "$remote_flag" ]; then
        error "--permission-mode is an option of --remote: cs $session_name --remote --permission-mode $remote_mode"
    fi
    local remote_in_window=""
    if [ -n "$remote_flag" ]; then
        [ -z "$force_flag" ] \
            || error "--force cannot be used with --remote: a served session never shares its directory with another claude."
        [ -z "$merge_feature" ] \
            || error "-finish cannot be used with --remote: remote-control takes no prompt to run /finish with."
        # Set only on the command _remote_open_window gives the server's tmux
        # window, and kept from everything this run starts.
        remote_in_window="${CS_REMOTE_WINDOW:-}"
        unset CS_REMOTE_WINDOW
    fi

    local session_dir="$SESSIONS_ROOT/$session_name"

    # The launch's own settings come from the session it opens: its file
    # outranks the machine's for the update check below, the theme the launch
    # measures (a file's theme is not measured over) and every launch-only
    # setting. bin/cs loaded the files for the session it was started in,
    # which is another one, or none.
    cs_config_load "$session_dir"

    check_dependencies

    # Check for updates (non-blocking), then offer one on a terminal before
    # anything below opens or claims the session.
    check_update_notify
    offer_update_at_launch ${launch_argv[@]+"${launch_argv[@]}"}
    # The window mark _cs_tmux_window sets is the offer's alone: kept from
    # everything this run starts.
    unset CS_UNATTENDED

    if [ -n "$remote_flag" ]; then
        _remote_claude_bin "$remote_mode"
        remote_mode="$_CS_REMOTE_MODE"
        if [ -n "${TMUX:-}" ] && [ -z "$remote_in_window" ]; then
            _remote_open_window "$session_name" "$remote_mode"
            return 0
        fi
    fi

    # Terminal theme (and its real background RGB when known) for the statusline
    # and hooks, detected while cs still owns the tty and reused by the session
    # launched next.
    _export_term_theme
    # Refresh the palette now that the theme is known so everything below —
    # migration's notices, the collision menu and the launch banner — reads on
    # a light canvas (colors were first set at startup, defaulting to dark).
    setup_palette

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
        # Checked on the base first: a worktree of an encrypted session is
        # refused whether its vault is mounted or not, and a worktree's own
        # copies of its links dangle with nothing to mount, so "mount it"
        # would mislead.
        _refuse_worktree_of_encrypted_base "$wt_base" "$base_dir"
        if [ ! -d "$session_dir" ]; then
            is_new="true"
            # The base's vault links are refused above, so this catches a
            # regular file where one belongs, or plaintext cs files beside a
            # .cs/private made by hand.
            _refuse_unmounted_meta "$wt_base" "$base_dir"
            confirm_clean_worktree_base "$base_dir" "$wt_base"
            session_dir=$(create_worktree_session "$base_dir" "$wt_base" "$wt_task") || exit 1
        else
            # No migrate_session on this path, so its refusal of committed or
            # linked per-actor state runs here, before any .cs/local read.
            cs_assert_local_untracked "$session_dir"
            # A worktree whose own checkout carries vault links refuses by
            # name while they dangle; a base's links never get this far.
            _refuse_unmounted_meta "$session_name" "$session_dir"
            # The backfill a base session gets from migrate_session, which the
            # worktree path below deliberately skips: an older worktree, or one
            # from a clone, still arrives at the umask's mode.
            _harden_session_meta "$session_dir"
            chmod 700 "$session_dir" 2>/dev/null || true
            local pinned head_branch
            pinned=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
            head_branch=$(git -C "$session_dir" branch --show-current 2>/dev/null || echo "")
            if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
                warn "Worktree HEAD is '$head_branch' but this feature expects '$pinned' (did something run git switch here?)"
            fi
            # No migrate_session here: worktree checkouts never predate the
            # worktree feature, and its CLAUDE.md rewrite must never touch a
            # project's own file (ignored-.cs repos track their real CLAUDE.md).
            # Mail and queue migration DO run: a worktree can hold a legacy
            # inbox.jsonl or queue file from the shipped versions, and both
            # conversions touch only .cs/local — never project files.
            migrate_mailbox "$session_dir"
            _queue_convert_legacy "$session_dir/.cs/local"
        fi
    elif [ ! -d "$session_dir" ]; then
        is_new="true"
        create_session_structure "$session_dir"
        # cs created this directory, so its mode is cs's to set. The adopt path
        # deliberately does not do this: there the root is the user's own
        # project, and only the .cs tree inside it belongs to cs.
        chmod 700 "$session_dir" 2>/dev/null || true

        # Initialize local git repo by default
        (
            cd -- "$session_dir" || exit 0
            create_session_gitignore "$session_dir"
            git init -q 2>/dev/null || true
            # cs writes its bookkeeping files with LF. A global core.autocrlf
            # rewrites the checked-out .gitignore to CRLF — every pattern then
            # carries a trailing \r and matches nothing, so files meant to be
            # ignored surface as untracked.
            git config core.autocrlf false 2>/dev/null || true
            git branch -M main 2>/dev/null || true
            setup_merge_attributes "$session_dir"
            git add -A 2>/dev/null || true
            git commit -q -m "Initial session structure" 2>/dev/null || true
        )
    else
        # The sessions root also holds directories that are not sessions;
        # migrate_session would write cs's files into one.
        is_session_dir "$session_dir" \
            || error "$session_dir is not a cs session (no .cs/ directory); cs will not write session files into it. Move it out of $SESSIONS_ROOT or open another name."
        _run_pre_open "$session_name" "$session_dir"
        _refuse_unmounted_meta "$session_name" "$session_dir"
        migrate_session "$session_dir"
    fi

    if [ -n "$merge_feature" ]; then
        local _known
        _known=$(_worktree_features "$session_name")
        case "
$_known
" in
            *"
$merge_feature
"*) ;;
            *) error "No feature worktree '$merge_feature' of '$session_name'. List them with: cs $session_name -features" ;;
        esac
    fi

    # Launch Claude Code
    launch_claude_code "$session_name" "$session_dir" "$is_new" "$force_flag" "$merge_feature" "$remote_mode"
}

main "$@"
