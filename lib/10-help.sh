# ABOUTME: The 'cs -help' usage text (show_help).
# ABOUTME: Plus the warn helper and the cs_interactive TTY predicate.

show_help() {
    cat << EOF
cs $VERSION - Claude Code session manager

Usage: cs <session-name>              Create or resume a session
       cs <session-name> -secrets <cmd>  Run secrets command on session
       cs -<command>                  Run a global subcommand

Commands:
  <name>              Create or resume session <name> (locks session)
  <name> --force      Override active session lock
  <base>@<task>       Open a parallel task worktree of session <base>
  <base> --merge <task>  Merge a task worktree back into <base> and remove it
  <name> -secrets <cmd>  Run secrets command on <name> without launching session
  -search <query>     Search across all sessions (--include-archived searches archived too)
  -checkpoint "<label>"  Save labelled state snapshot (run from inside a session)
  -checkpoint list    List checkpoints for current session
  -checkpoint show <name>  Print a specific checkpoint
  -queue add "<task>" Add a task to the session's walk-away queue
  -queue list         Show pending and completed queued tasks
  -queue rm <n>       Remove pending task n
  -queue clear        Empty the queue and stop draining
  -doctor, -diag      Run health checks (Keychain, hooks, memory, audit, tokens)
  -lint <file>...     Flag AI-slop prose tells (em-dashes, banned phrases); 0=clean 1=issues 2=error
  -statusline <cmd>   enable|disable the cs status line in Claude Code settings
  -detect-theme       Show the detected terminal theme (light|dark)
  -list, -ls          List sessions (--tag <tag> filters; --archived shows only archived)
  -adopt <name>       Adopt current directory as a cs session
  -whoami             Show the current actor (for shared, multi-person sessions)
  -who                Show who contributed to shared memory/narrative (git history)
  -live               List sessions running right now on this machine
  -usage              Per-session token usage over the 5h/weekly rate-limit windows
  -tag add|rm <tag>   Tag the current session (frontmatter); -tag list [<name>] to view
  -archive <name>     Archive a session: hidden from listings until reopened
  -unarchive <name>   Restore an archived session to the listings
  -status "<text>"    Set this session's advertised status (also: -status, -status --clear/-c)
  -remove, -rm <name> Remove a session
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
                          logo,session,notes,git,model,ctx,limits,cost)
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

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Offer a way forward when the session is already open elsewhere: start a
# parallel task in a worktree, force a second launch into the same checkout,
# or cancel. Returns only when the user chose force; the new-task choice
# re-execs cs as <session>@<task>; cancel exits 0. Worktree sessions get no
# new-task option (tasks always branch from the base). CS_ASSUME_TTY lets
# tests drive the menu with piped stdin.
# True when a human can answer prompts: stdin is a terminal, or a test
# drives stdin through a pipe with CS_ASSUME_TTY=1. Every interactive gate
# must use this predicate — a bare [ -t 0 ] is untestable from the harness.
cs_interactive() {
    [ -t 0 ] || [ "${CS_ASSUME_TTY:-}" = "1" ]
}

