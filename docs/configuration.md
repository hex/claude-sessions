# Configuration

cs reads its configuration from environment variables. None are required — cs
runs with sensible defaults out of the box — but you can set any of these in
`~/.bashrc` or `~/.zshrc` to override behavior.

This lists every variable a user would set, plus the ones cs exports for hooks
and helper binaries. It deliberately excludes test seams and internal state —
values cs computes and passes to itself, which change without notice and are
documented in the code that reads them.

## Environment variables you set

```bash
# Sessions directory (default: ~/.claude-sessions)
export CS_SESSIONS_ROOT="/path/to/sessions"

# The actor name that shared memory and narratives are attributed to. Highest
# precedence in the chain $CS_ACTOR > .cs/local/identity > git user.email >
# git user.name, so it is how you override attribution on a machine whose git
# identity is not the one you want recorded.
export CS_ACTOR="alice"

# Skip the update check entirely. cs otherwise asks GitHub for the latest
# release at most hourly and caches the answer under ~/.cache/cs; this stops
# both the request and the write, for an air-gapped machine or simply to keep
# cs off the network.
export CS_NO_UPDATE_CHECK="1"

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
# statusline's full-width gradient fade. Unset, the tail is drawn instead as
# a coverage wash that needs no background colour at all; setting the real
# value switches it to a colour fade that ends exactly on your terminal.
export CS_TERM_BG_RGB="250;248;242"   # r;g;b, 0-255 each

# Disable colors (see https://no-color.org)
export NO_COLOR="1"

# Status line: choose/order segments, or disable entirely
export CS_STATUSLINE_SEGMENTS="logo,session,notes,mail,pane,git,model,ctx,limits,fable"  # this is the default
export CS_STATUSLINE_DISABLE="1"

# Where the machine-global usage cache behind the `fable` segment lives
# (default: $CS_SESSIONS_ROOT/.usage). One record per account per machine, not
# one per session: the endpoint it draws on budgets requests per account.
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the `fable` segment from cache only, never triggering a refresh
export CS_USAGE_NO_REFRESH="1"

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
export CS_REWRITE_PROVIDER="claude"          # claude | openai | gemini | grok
                                            # openai-api | gemini-api | claude-api reach a
                                            # vendor API past an installed CLI

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

# What fills the blank screen while the rewrite runs. `screen` holds your prompt
# in a margin rule that breathes while the rewrite runs, with the engine, the
# model and the time remaining beneath it. `native` is one anchored line
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

# Narrative rotation: rotate when the live file passes MAX, keep about KEEP bytes
export CS_NARRATIVE_MAX_BYTES="131072"
export CS_NARRATIVE_KEEP_BYTES="65536"

# Queue circuit breakers: per-task tool failures, context %, 5h rate-limit %
export CS_QUEUE_MAX_FAILURES="5"
export CS_QUEUE_MAX_CTX="85"
export CS_QUEUE_MAX_5H="85"

# Mail wakes: how many a turn boundary may fire between user prompts,
# and the switch that silences them entirely (see hooks.md)
export CS_MAIL_WAKE_MAX="5"   # this is the default
export CS_NO_MAIL_WAKE="1"

# Disable the iTerm2 attention bounce (the dock bounce a finished turn starts,
# and the attention marker the status line reads). The tab tint is NOT gated by
# this: set_tab_title emits the iTerm2 escapes unconditionally at launch, and
# the colour resets when the session exits.
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
- `CS_CLAUDE_SESSION_ID` - The conversation UUID cs launched or resumed, exported so hooks can tell the launched conversation from any other claude that resolves the same session
- `CS_REAL_EDITOR` - Your own `$EDITOR`, captured before cs repoints `EDITOR`/`VISUAL` at the prompt-rewriter shim. The shim hands every file that is not a composer buffer back to it, so `/memory` and commit messages still open your editor. Set it yourself to pin which editor that is
- `CS_SECRETS_SESSION` - For a worktree session, the base session its secrets key to, so a feature worktree reads the same store as its parent (see [secrets.md](secrets.md))
- `CLAUDE_SESSION_DIR` - Full path to the session directory (workspace root)
- `CLAUDE_SESSION_META_DIR` - Path to the `.cs/` metadata directory
- `CLAUDE_CODE_TASK_LIST_ID` - Set to the session name for task list persistence
- `CLAUDE_CODE_AUTO_MEMORY_PATH` / `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` - Redirect Claude Code's auto-memory writer into `<session>/.cs/memory/`
