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
export CS_STATUSLINE_SEGMENTS="logo,session,notes,mail,pane,git,model,ctx,limits"  # this is the default
export CS_STATUSLINE_DISABLE="1"

# Opt a session out of the scope-prompt auto-grounding hook
export CS_SCOPE_DISABLE="1"

# Opt a session out of the scope-prompt stage trace (see hooks.md)
export CS_SCOPE_TRACE_DISABLE="1"

# Opt a session out of first-prompt Objective capture (see hooks.md)
export CS_OBJECTIVE_CAPTURE_DISABLE="1"

# Opt a session out of the clarify guideline (see hooks.md).
# Separate from CS_SCOPE_DISABLE on purpose: silencing grounding should not
# silence the questions. Skip a single turn instead with a leading ~ .
export CS_CLARIFY_DISABLE="1"

# Opt a session out of prompt rewriting (ctrl+g in the composer; see hooks.md).
# Separate from CS_CLARIFY_DISABLE: the questions and the rewriter are
# independent. When set, cs leaves your $EDITOR alone entirely.
export CS_REWRITE_DISABLE="1"

# Who rewrites prompts. The default is Claude, through the `claude` CLI and your
# existing login. `openai` and `gemini` prefer that vendor's CLI when its binary
# is on PATH — `codex` and `agy` respectively, both using your subscription — and
# fall back to the vendor's API when it is not, reading OPENAI_API_KEY or
# GEMINI_API_KEY from the environment. With neither a CLI nor a key, the rewrite
# declines and your prompt stays as typed.
#
# The CLI arms cost about ten seconds against about one for the API arms, and
# the interface is frozen for that whole time. That is the trade the default
# makes for you: no key, no per-token charge.
# Append `-api` to reach a vendor's API even when its CLI is installed. That is
# the only way to get Gemini's lite tier, which agy's catalogue does not carry
# and which is the fastest option there is: measured on one machine with agy and
# codex both present, gemini 7.3s vs gemini-api 0.9s, openai 12.8s vs openai-api
# 2.0s. `claude-api` calls Anthropic's Messages endpoint instead of driving the
# whole Claude Code agent, which is why the bare `claude` default takes ~13s.
# Every -api arm needs that vendor's key and declines without one.
export CS_REWRITE_PROVIDER="claude"          # claude | openai | gemini
                                             # | openai-api | gemini-api | claude-api

# The model that rewrites prompts, and how long to wait for it. It reaches every
# arm: the API request, `agy --model`, `codex -m`. Left unset, each vendor CLI
# uses the model configured in that tool, which is your setting and not cs's to
# override.
#
# The id belongs to whichever engine answers, and the namespaces differ. Ask the
# engine: `agy models` lists agy's, and its ids embed the reasoning effort
# (`gemini-3.6-flash-low`), so the bare family name `gemini-3.6-flash` is
# rejected. The API arms take the vendor's own API ids. An id the engine does not
# accept declines the rewrite and leaves your prompt as typed — cs never
# translates between the two namespaces.
#
# Defaults, used only where cs picks: claude-haiku-4-5-20251001 and, on the API
# arms, gpt-4.1-mini and gemini-flash-lite-latest. Reasoning models are a poor
# fit whatever the provider: they can spend most of the output budget on
# reasoning and return a rewrite truncated mid-sentence, which cs declines — so
# ctrl+g intermittently does nothing at all.
export CS_REWRITE_MODEL="gemini-3.6-flash-low"        # agy's id, for the gemini CLI arm
export CS_REWRITE_TIMEOUT="25"                        # seconds; needs timeout(1)

# What fills the blank screen while the rewrite runs. `screen` shows a header,
# the model, and your prompt above the spinner. `native` is one anchored line
# in Claude Code's own idiom, with the elapsed appearing only after five
# seconds. `line` is one centred line with a spinner and a clock. `static`
# prints once and never animates, so a wedged rewrite looks the same as a
# working one. Only `screen` echoes your prompt. An unrecognised value falls
# back to `screen`.
export CS_REWRITE_PROGRESS="screen"          # screen | native | line | static

# Replace the rewriter itself. Reads the rough prompt on stdin, writes the
# rewrite to stdout, non-zero to leave the prompt untouched.
export CS_REWRITE_CMD="/path/to/my-rewriter"

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

# Mail wakes: how many a turn boundary may fire between user prompts,
# and the switch that silences them entirely (see hooks.md)
export CS_MAIL_WAKE_MAX="5"   # this is the default
export CS_NO_MAIL_WAKE="1"

# Disable the iTerm2 integrations (tab color, attention dock bounce)
export CS_NO_ITERM2="1"

# Override the tmux binary cs -spawn uses (default: tmux on PATH)
export CS_TMUX_BIN="/opt/homebrew/bin/tmux"

# Force the detected platform instead of probing for it; any other
# value is rejected. Read by cs -secrets only, to choose between the
# macOS keychain and the encrypted file
export CS_PLATFORM_OVERRIDE="linux"   # macos, wsl, or linux
```

## Environment variables cs sets for you

These are exported automatically when you start a session, so the Claude Code
process and its hooks can find the session:

- `CLAUDE_SESSION_NAME` - The session name (e.g., `myproject`)
- `CLAUDE_SESSION_DIR` - Full path to the session directory (workspace root)
- `CLAUDE_SESSION_META_DIR` - Path to the `.cs/` metadata directory
- `CLAUDE_CODE_TASK_LIST_ID` - Set to the session name for task list persistence
- `CLAUDE_CODE_AUTO_MEMORY_PATH` / `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` - Redirect Claude Code's auto-memory writer into `<session>/.cs/memory/`
