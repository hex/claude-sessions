# Configuration

cs reads its configuration from environment variables. None are required — cs
runs with sensible defaults out of the box — but you can set any of these in
`~/.bashrc` or `~/.zshrc` to override behavior.

## Environment variables you set

```bash
# Sessions directory (default: ~/.claude-sessions)
export CS_SESSIONS_ROOT="/path/to/sessions"

# Legacy password for secrets sync (age encryption preferred - see secrets.md)
export CS_SECRETS_PASSWORD="your-secure-password"

# Override secrets backend (keychain or encrypted)
export CS_SECRETS_BACKEND="keychain"

# Override Claude Code binary (default: claude)
export CLAUDE_CODE_BIN="claude"

# Nerd Font icons in cs banners and session listings (lock, host);
# the status line uses standard Unicode and is unaffected by this
export CS_NERD_FONTS="1"

# Force the light/dark theme (session-picker TUI palette, statusline, hooks).
# Unset (default), cs auto-detects the terminal background before launch; the
# exact detection cascade lives in docs/statusline.md ("Terminal theme").
# Set this to override; `cs -detect-theme` prints what detection yields.
export CS_TERM_THEME="light"   # or "dark"

# Override the terminal's real background color (default: auto-detected via
# the same OSC 11 query as CS_TERM_THEME, when it succeeds). Drives the
# statusline's full-width gradient fade; unset means no gradient.
export CS_TERM_BG_RGB="250;248;242"   # r;g;b, 0-255 each

# Disable colors (see https://no-color.org)
export NO_COLOR="1"

# Status line: choose/order segments, or disable entirely
export CS_STATUSLINE_SEGMENTS="logo,session,notes,pane,git,model,ctx,limits,cost"  # this is the default
export CS_STATUSLINE_DISABLE="1"

# Opt a session out of the scope-prompt auto-grounding hook
export CS_SCOPE_DISABLE="1"

# Opt a session out of first-prompt Objective capture (see hooks.md)
export CS_OBJECTIVE_CAPTURE_DISABLE="1"

# Statusline context gauge escalation thresholds (see statusline.md)
export CS_STATUSLINE_CTX_WARN="50"
export CS_STATUSLINE_CTX_CRIT="80"

# Disable the subagent (agent-panel) statusline rows without unregistering
export CS_SUBAGENT_STATUSLINE_DISABLE="1"

# Context tiers in the Stop hook: one-time warning band start, rotation nudge
export CS_CTX_WARN_CTX="60"
export CS_ROTATE_NUDGE_CTX="80"

# Queue circuit breakers: per-task tool failures, context %, 5h rate-limit %
export CS_QUEUE_MAX_FAILURES="5"
export CS_QUEUE_MAX_CTX="85"
export CS_QUEUE_MAX_5H="85"

# Disable the iTerm2 integrations (tab color, attention dock bounce)
export CS_NO_ITERM2="1"

# Override the tmux binary cs -spawn uses (default: tmux on PATH)
export CS_TMUX_BIN="/opt/homebrew/bin/tmux"
```

## Environment variables cs sets for you

These are exported automatically when you start a session, so the Claude Code
process and its hooks can find the session:

- `CLAUDE_SESSION_NAME` - The session name (e.g., `myproject`)
- `CLAUDE_SESSION_DIR` - Full path to the session directory (workspace root)
- `CLAUDE_SESSION_META_DIR` - Path to the `.cs/` metadata directory
- `CLAUDE_CODE_TASK_LIST_ID` - Set to the session name for task list persistence
- `CLAUDE_CODE_AUTO_MEMORY_PATH` / `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` - Redirect Claude Code's auto-memory writer into `<session>/.cs/memory/`
