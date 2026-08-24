# Request: expose the resolved theme to the status line

**Ask:** add a `theme` field to the JSON Claude Code passes a `statusLine`
command, carrying the theme Claude Code has already resolved for its own chrome
(`dark`, `light`, and the daltonized/ansi variants, or whatever the resolved
value is when `theme` is `auto`).

## Why the status line cannot work this out for itself

A status line is drawn inside Claude Code's UI, on the terminal's background. To
pick readable colours it needs to know whether that background is light or dark.
Claude Code already knows: with `theme: "auto"` it queries the terminal with
OSC 11 (with a DCS-passthrough variant for tmux), falls back to `COLORFGBG`, and
live-tracks changes through DECSET 2031 theme-change notifications. It does not
pass the answer on.

The payload today carries `session_id`, `transcript_path`, `cwd`, `prompt_id`,
`permission_mode`, `agent_id`, `agent_type`, `effort`, `session_name`, `model`,
`workspace`, `version`, `output_style`, `cost`, `context_window`,
`exceeds_200k_tokens`, `fast_mode`, `thinking`, `rate_limits`, `vim`, `agent`,
`remote`, `pr`, `worktree` — and no theme. No `CLAUDE_*` environment variable
carries it either.

So every status-line tool re-derives what Claude Code has already determined,
and each available signal fails somewhere. Measured on macOS with tmux 3.6a and
iTerm2:

| Signal | Fails when |
|---|---|
| OSC 11 from the render | Unusable: the status line runs once a second into the tty Claude Code owns, so it would open a second reader racing Claude Code's stdin — it can swallow the reply or the user's keystrokes |
| macOS `AppleInterfaceStyle` | Reports the *system*, not the terminal. A terminal with a fixed dark scheme under a light macOS renders light |
| `COLORFGBG` | Inside tmux it is the server's start-time snapshot; observed reading `15;0` (dark) under a cream terminal |
| tmux `#{client_theme}` | Empty unless the terminal reports its theme; iTerm2 does not |
| Measuring once at launch | Wrong after a tmux session is re-attached from a different terminal |

For a terminal that is inside tmux and does not report its theme — a common
combination — **no passive per-render signal exists at all.**

## What was tried

A tmux `client-attached` hook running an OSC 11 probe in a detached window,
whose reply tmux routes to that window's own pane rather than to Claude Code's
tty. The mechanism works; the surrounding machinery produced a new failure class
at each of four reviews, ending with two constraints that cannot both be
satisfied: probe identity must be per-window (several sessions share one tmux
session), and must not be interpolated into the hook string (an unvalidated path
there is a command-injection vector). The approach was abandoned.

## Cost and benefit

One field, already computed, already live-tracked. It removes the need for every
status-line tool to reimplement terminal detection — and for the tmux-plus-
non-reporting-terminal case, it is the only thing that can be correct, because
the information exists solely inside Claude Code.
