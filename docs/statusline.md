# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one powerline-style line of colored segments.

```
claude-sessions > ctx 42% > Fable high > main↑1 +2!1 > 5h 23% > wk 41% > disc 45K/60K > $1.23
```

With colors enabled, each segment renders as a colored background block with an arrow transition into the next; the plain form above is what `NO_COLOR=1` produces.

## Segments

Default order: `session,ctx,model,git,limits,disc,cost`.

| Segment | Shows | Source | Color |
|---|---|---|---|
| `session` | Session name | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename | The session's `claude_session_color` from `.cs/README.md` frontmatter; grey outside cs sessions |
| `ctx` | Context window usage, `ctx 42%` | stdin `context_window.used_percentage` | Neutral grey; yellow at 50%, red at 80% (tunable) |
| `model` | Model display name plus effort level when present | stdin `model.display_name`, `effort.level` | Neutral grey |
| `git` | Branch, ahead/behind arrows, staged `+N` and modified `!N` counts | One `git status --porcelain=v1 -b` call | Grey |
| `limits` | 5-hour and weekly rate limit usage as two adjacent blocks, `5h 23%` and `wk 41%` | stdin `rate_limits.*.used_percentage` | The pair mirrors claude's usage bar: periwinkle for 5h, slate for the week; each block escalates to yellow at 70% and red at 90% on its own value |
| `disc` | `discoveries.md` size against its budget, `disc 45K/60K` | File size vs `CS_DISCOVERIES_MAX_SIZE` (default 60K) | Yellow at 70% of budget, red at 90% |
| `cost` | Session cost, `$1.23` | stdin `cost.total_cost_usd` | Grey |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name and `disc` disappears.

## Data sources and performance

The render path is deliberately thin: one `jq` pass over stdin, at most one git subprocess, and at most two small file reads (`README.md` frontmatter for the session color, `discoveries.md` size). There is no transcript parsing, no network access, no caching, and the script never writes anything. Data gathering is gated per segment, so disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git subprocess never forks.

The git call runs with `GIT_OPTIONAL_LOCKS=0` (no index locking for a read-only query) under a 2-second timeout, and is skipped entirely when the workspace has no `.git`.

Failure posture is fail-open: malformed stdin, a missing `jq`, or any internal error degrades to a plain directory-name line and exit 0. A broken status line never breaks the prompt.

## Colors

Color depth is detected per render, in priority order: `FORCE_COLOR=0`, `NO_COLOR`, or `TERM=dumb` force plain text (segments joined with ` > `, no escape codes); `COLORTERM=truecolor`/`24bit` or iTerm2/WezTerm select truecolor; a `*256color*` `TERM` selects 256-color; anything else gets basic ANSI.

The `session` segment's background is the same color claude shows for the session (`/color`), read from `claude_session_color:` in the session's `.cs/README.md` frontmatter.

Color means state, not decoration: healthy segments sit on neutral grey, the session name carries the one identity accent (its `claude_session_color`), the limits pair keeps the two purples from claude's own usage bar (periwinkle `rgb(140,140,232)` for the 5-hour block, slate `rgb(95,95,135)` for the weekly block), and yellow/red appear only when a threshold fires. Light backgrounds (periwinkle, yellow) take dark text for contrast; all colors have 256-color and basic-ANSI fallbacks.

Adjacent segments that share a background join with a thin chevron (U+E0B1, `›` without Nerd Fonts) instead of the solid arrow, which would vanish between equal colors.

`CS_NERD_FONTS=1` enables the powerline arrow separator (U+E0B0) and per-segment icons (home, gauge, microchip, branch, clock, calendar, book, from the Font Awesome and powerline glyph ranges). Without it, separators are `>` and segments are plain text.

## Configuration

```bash
# Disable entirely (prints nothing)
export CS_STATUSLINE_DISABLE=1

# Choose and order segments
export CS_STATUSLINE_SEGMENTS="session,ctx,git,limits"

# Context thresholds (percent)
export CS_STATUSLINE_CTX_WARN=50
export CS_STATUSLINE_CTX_CRIT=80

# Powerline glyphs and segment icons (otherwise ASCII '>' and plain text)
export CS_NERD_FONTS=1

# Plain text, no colors
export NO_COLOR=1
```

`CS_SESSIONS_ROOT` and `CS_DISCOVERIES_MAX_SIZE` are honored the same way the rest of cs honors them.

## Install, uninstall, doctor

`install.sh` deploys `cs-statusline` to `~/.local/bin` and registers it as `statusLine` in `~/.claude/settings.json`. An existing status line is never replaced silently: with a terminal attached the installer asks first, otherwise it keeps the current one and prints how to switch.

`cs -uninstall` removes the binary and strips the `statusLine` registration only when it points at `cs-statusline`; a status line you configured yourself is left untouched.

`cs -doctor` includes a Statusline check: OK when registered and executable, FAIL when the registration points at a missing binary, and informational otherwise (the status line is optional).

## Design notes

The design came out of a source study of [claude-powerline](https://github.com/Owloops/claude-powerline) (techniques: the single-call git query, the color-support ladder, per-segment gating of all I/O) and of oh-my-claudecode's HUD as a counterexample (its per-render transcript parsing, unconditional state reads, and multi-line output are the failure modes this script is shaped against). Claude Code delivers everything else needed (session name, context %, rate limits, model, cost) directly in the status-line stdin JSON, which is why the hot path needs no other data source.
