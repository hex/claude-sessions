# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one powerline-style line of colored segments.

```
claude-sessions > ctx 42% > Fable high > main↑1 +2!1 > 5h 23% > wk 41% > disc 45K/60K > $1.23
```

With colors enabled, each segment renders as a colored background block with an arrow transition into the next; the plain form above is what `NO_COLOR=1` produces.

## Segments

Default order: `session,model,ctx,git,limits,disc,cost`. Identity first (which session, which model), then the gauges.

| Segment | Shows | Source | Color |
|---|---|---|---|
| `session` | Session name | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename | The session's `claude_session_color` from `.cs/README.md` frontmatter; grey outside cs sessions |
| `ctx` | Context window usage, `ctx 42%` | stdin `context_window.used_percentage` | Grey; amber at 50%, red at 80% (tunable) |
| `model` | Model display name plus effort level when present | stdin `model.display_name`, `effort.level` | Periwinkle accent (claude's usage-chip purple), white text |
| `git` | Branch, ahead/behind arrows, staged `+N` and modified `!N` counts | One `git status --porcelain=v1 -b` call | Grey |
| `limits` | 5-hour and weekly rate limit usage as two adjacent blocks, `5h 23%` and `wk 41%` | stdin `rate_limits.*.used_percentage` | Grey; each block escalates to amber at 70% and red at 90% on its own value |
| `disc` | `discoveries.md` size against its budget, `disc 45K/60K` | File size vs `CS_DISCOVERIES_MAX_SIZE` (default 60K) | Grey through normal accumulation; amber at 85% of budget, red at 95% (discoveries fill slowly, so the nag waits until compaction is due) |
| `cost` | Session cost, `$1.23` | stdin `cost.total_cost_usd` | Grey |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name and `disc` disappears.

## Data sources and performance

The render path is deliberately thin: one `jq` pass over stdin, at most one git subprocess, and at most two small file reads (`README.md` frontmatter for the session color, `discoveries.md` size). There is no transcript parsing, no network access, no caching, and the script never writes anything. Data gathering is gated per segment, so disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git subprocess never forks.

The git call runs with `GIT_OPTIONAL_LOCKS=0` (no index locking for a read-only query) under a 2-second timeout, and is skipped entirely when the workspace has no `.git`.

Failure posture is fail-open: malformed stdin, a missing `jq`, or any internal error degrades to a plain directory-name line and exit 0. A broken status line never breaks the prompt.

## Colors

Color depth is detected per render, in priority order: `FORCE_COLOR=0`, `NO_COLOR`, or `TERM=dumb` force plain text (segments joined with ` > `, no escape codes); `COLORTERM=truecolor`/`24bit` or iTerm2/WezTerm select truecolor; a `*256color*` `TERM` selects 256-color; anything else gets basic ANSI.

The `session` segment's background is the same color claude shows for the session (`/color`), read from `claude_session_color:` in the session's `.cs/README.md` frontmatter.

The healthy bar carries exactly two colored blocks: the session name in its `claude_session_color` (white text) and the model in periwinkle `rgb(153,152,255)` with white text, matching claude's own usage chip. Everything else rests on quiet grey with white text. Color beyond those two accents is state: warm amber `rgb(255,183,77)` (cs's warning color) past warn thresholds, red past crit. A glance answers three questions in order: which session, which model, and is anything on fire.

Adjacent segments that share a background join with a thin chevron (U+E0B1, `›` without Nerd Fonts) instead of the solid arrow, which would vanish between equal colors.

## Terminal theme

cs detects the terminal's light/dark theme once at session launch, while it still owns the tty: an OSC 11 background query classified by BT.709 luminance first, falling back to `COLORFGBG` only when the query gets no answer. The query outranks the variable because `COLORFGBG` goes stale across theme changes; OSC 11 asks the live terminal. Inside tmux neither signal is honest — tmux answers the OSC query itself with its default (black) background instead of the outer terminal's color, and `COLORFGBG` is a snapshot of the tmux server's start-time environment — so under `$TMUX` cs reads the OS appearance instead (`defaults read -g AppleInterfaceStyle` on macOS; `unknown` elsewhere), which is right whenever the terminal theme follows the system. The result is exported as `CS_TERM_THEME` for the statusline and hooks; detection runs at launch because an OSC query fired from a render hook would race its reply into claude's input stream. On dark terminals the statusline lifts its neutral grey and softens white text; all other colors are self-backgrounded and theme-independent. Set `CS_TERM_THEME=light|dark` to override detection, and run `cs -detect-theme` to see what detection yields.

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

`install.sh` deploys the `cs-statusline` binary to `~/.local/bin` unconditionally, but the status bar itself is claimed only with consent: with a terminal attached the installer asks before registering (default yes; it also asks before replacing an existing status line), and a non-interactive install registers nothing and prints how to enable later. Turn it on or off any time:

```bash
cs -statusline enable    # register (overwrites the current status line; the command is your consent)
cs -statusline disable   # remove the registration, only if it points at cs-statusline
```

`cs -uninstall` removes the binary and strips the `statusLine` registration only when it points at `cs-statusline`; a status line you configured yourself is left untouched.

`cs -doctor` includes a Statusline check: OK when registered and executable, FAIL when the registration points at a missing binary, and informational otherwise (the status line is optional).

## Design notes

The design came out of a source study of [claude-powerline](https://github.com/Owloops/claude-powerline) (techniques: the single-call git query, the color-support ladder, per-segment gating of all I/O) and of oh-my-claudecode's HUD as a counterexample (its per-render transcript parsing, unconditional state reads, and multi-line output are the failure modes this script is shaped against). Claude Code delivers everything else needed (session name, context %, rate limits, model, cost) directly in the status-line stdin JSON, which is why the hot path needs no other data source.
