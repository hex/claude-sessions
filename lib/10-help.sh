# ABOUTME: The 'cs -help' usage text (show_help).
# ABOUTME: Plus the warn helper and the cs_interactive TTY predicate.

show_help() {
    cat << EOF
cs $VERSION - Claude Code session manager

Usage: cs                             Open the session you are standing in,
                                      or the session manager if you are not in one
       cs <session-name>              Create or resume a session
       cs <session-name> -secrets <cmd>  Run secrets command on session
       cs -<command>                  Run a global subcommand

Commands:
  <name>              Create or resume session <name> (locks session)
  <name> --force      Override active session lock
  <base>@<feature>    Open a parallel feature worktree of session <base>
  <base> --merge <feature>  Merge a feature worktree back into <base> and remove it
  <base> -features          List a base's feature worktrees and their merge readiness
  <base> -finish <feature>  Open <base> and run the merge ritual for <feature>
  <name> -secrets <cmd>  Run secrets command on <name> without launching session
  <name> -narrative rotate  Rotate <name>'s narrative without launching session
  -search <query>     Search across all sessions (--include-archived searches archived too)
  -checkpoint "<label>"  Save labelled state snapshot (run from inside a session)
  -checkpoint list    List checkpoints for current session
  -checkpoint show <name>  Print a specific checkpoint
  -narrative rotate   Archive the oldest sections of your narrative once it passes its byte budget (/wrap runs it)
  -queue add "<task>" Add a task to the session's walk-away queue
  -queue list         Show pending and completed queued tasks
  -queue rm <n>       Remove pending task n
  -queue clear        Empty the queue and stop draining
  -queue log          Show the walk-away run journal (drains, breaker trips)
  -msg <session> "<body>"  Send a message to another session (--kind notify|task|text|result; '-' reads the body from stdin)
  -msg --reply <thread> "<body>"  Reply into a thread; the target comes from the thread
  -msg                Read this session's unread mail
  -msg log            Show this session's full mail history
  -msg thread <id>    Show one thread as a conversation, oldest first
  -spawn <name>       Open a session in the cs tmux session (--task "..." seeds and arms its queue)
  -conversations      Show the session's conversation chain (rotations, lineage)
  -doctor, -diag      Run health checks (Keychain, hooks, memory, audit, tokens)
  -statusline <cmd>   enable|disable the cs status line in Claude Code settings
  -detect-theme       Show the detected terminal theme (light|dark)
  -tui                Open the interactive session manager (bare 'cs' does too, outside a session)
  -list, -ls          List sessions (--tag <tag> filters; --archived shows only archived)
  -adopt <name>       Adopt current directory as a cs session
  -whoami             Show the current actor (for shared, multi-person sessions)
  -who                Show who contributed to shared memory/narrative (git history)
  -live               List sessions running right now on this machine
  -usage              Per-session token usage over the 5h/weekly rate-limit windows
  -tag add|rm <tag>   Tag the current session (frontmatter); -tag list [<name>] to view
  -archive <name>... [--force]  Archive sessions (hidden until reopened; --force if live)
  -unarchive <name>...  Restore archived sessions to the listings
  -status "<text>"    Set this session's advertised status (also: -status, -status --clear/-c)
  -remove, -rm <name>... [--force]  Remove sessions (each asks its own confirm; --force if live)
  -secrets <cmd>      Manage current session secrets (requires CLAUDE_SESSION_NAME)
  -update             Update cs to latest version
    --check, -c       Check for updates without installing
    --force, -f       Force reinstall even if up to date
  -uninstall          Uninstall cs and all components
  -help, -h           Show this help message
  -version, -v        Show version

Secrets Commands:
  set, store <name>   Store a secret (prompts if value not provided)
  get <name>          Retrieve a secret value
  list, ls            List all secrets for session
  delete, rm <name>   Delete a secret
  purge               Delete ALL secrets for session
  export              Export secrets as environment variables
  backend             Show which storage backend is active

  For encrypted-file sync (export-file/import-file), age public-key setup,
  and legacy migration, run 'cs -secrets' to see the full secrets reference.

Environment:
  CS_SESSIONS_ROOT    Override sessions directory (default: ~/.claude-sessions)
  CLAUDE_CODE_BIN     Override claude binary name (default: claude)
  CLAUDE_SESSION_NAME Current session name (set automatically)
  CS_SECRETS_PASSWORD Master password for encrypted secrets backend
  CS_NERD_FONTS       Set to 1 for Nerd Font icons (default: Unicode)
  NO_COLOR            Disable all colors (see no-color.org)
  CS_STATUSLINE_DISABLE   Set to 1 to render nothing in the status line
  CS_STATUSLINE_SEGMENTS  Status line segments, csv order (default:
                          logo,session,notes,mail,pane,git,model,ctx,limits,fable;
                          'cost' also available, off by default)
  CS_TERM_THEME           Override terminal theme detection (light|dark);
                          cs -detect-theme shows what detection yields.
                          Under tmux, detection queries the outer terminal via
                          DCS passthrough (needs 'allow-passthrough on'), else
                          falls back to the OS appearance — set this to override.

Examples:
  cs debug-api                      Create or resume 'debug-api' session
  cs my-session -secrets list       List secrets for 'my-session'
  cs -search "postgres migration"   Search across all sessions
  cs -list                          List all sessions
  cs -rm old-session                Remove 'old-session'

Sessions are stored in: $SESSIONS_ROOT
EOF
}

# Message through %s, like error()/info(): escapes in interpolated text are data.
# Print the full help's own lines for one verb, and nothing else. Derived rather
# than a second copy: adding a flag to a verb updates `cs -help` and
# `cs <verb> --help` in the same edit, so the two can never disagree. Exits
# non-zero only if the verb has no documented line, which is a help-text bug
# rather than a user error.
show_verb_help() {  # verb
    local verb="$1" lines
    # Match the verb as a whole token ANYWHERE on the line, splitting on commas
    # too: the help lists aliases together ("-doctor, -diag") and prefixes the
    # session forms ("<base> -features"), so a first-field test finds neither.
    lines=$(show_help 2>/dev/null \
        | awk -v v="$verb" '{ orig = $0; n = split($0, f, /[[:space:],]+/);
              for (i = 1; i <= n; i++) if (f[i] == v) { print orig; break } }') || true
    if [ -z "$lines" ]; then
        printf 'No help recorded for %s. Run: cs -help\n' "$verb" >&2
        return 1
    fi
    printf 'Usage:\n%s\n' "$lines"
}

# True when the next argument is a help flag. `<verb> --help` has to be answered
# BEFORE the verb resolves a session or parses arguments, or the flag arrives
# somewhere that reads it as data — `cs -msg --help` reported "No such session:
# --help", which sends the reader looking for a session rather than for docs.
_is_help_flag() {  # arg
    case "${1:-}" in -h|-help|--help) return 0 ;; *) return 1 ;; esac
}

warn() {
    printf "${YELLOW}%s${NC}\n" "$1"
}

# Offer a way forward when the session is already open elsewhere: open one of
# its existing feature worktrees, start a new parallel feature, force a second
# launch into the same checkout, or cancel. Returns only when the user chose
# force; the open-feature and new-feature choices re-exec cs as
# <session>@<feature>; cancel exits 0. Worktree sessions get no new-feature
# option (features always branch from the base). CS_ASSUME_TTY lets
# tests drive the menu with piped stdin.
# True when a human can answer prompts: stdin is a terminal, or a test
# drives stdin through a pipe with CS_ASSUME_TTY=1. Every interactive gate
# must use this predicate — a bare [ -t 0 ] is untestable from the harness.
cs_interactive() {
    [ -t 0 ] || [ "${CS_ASSUME_TTY:-}" = "1" ]
}

