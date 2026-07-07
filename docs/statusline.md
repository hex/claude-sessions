# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one line of squared, colored segments.

```
claude-sessions > ⎇ main↑1 +2!1 > Fable high > ctx 42% > 5h 23% · 2h14m > wk 41% > $1.23
```

With colors enabled, each segment renders as a square colored block; blocks abut so the background-color change is the divider between them. The plain form above is what `NO_COLOR=1` produces.

## Segments

Default order: `logo,session,notes,git,model,ctx,limits,cost`. A brand badge opens the bar, then identity (which session, which branch, which model), then the gauges.

| Segment | Shows | Source | Color |
|---|---|---|---|
| `logo` | A Claude mark (`✳`) badge; the mark's color pulses while Claude has finished and awaits input | `.cs/local/attention` marker (raised by the Stop hook, cleared on the next prompt or session start) | Claude coral `rgb(217,119,87)`, white mark; the pulse alternates the mark between chiptext and the darker brandshade by epoch-second parity. Claude Code's TUI re-emits only bold/fg/bg from statusline ANSI (terminal blink is dropped) and repaints only on events, so the registration sets `statusLine.refreshInterval: 1` to repaint once a second while idle — that timer animates the pulse. Omitted in plain (`NO_COLOR`) mode |
| `session` | Session name | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename | The session's `claude_session_color` from `.cs/local/state`; grey outside cs sessions |
| `notes` | Queued-task count for the current session, `▤ N` | Non-blank lines of `.cs/local/queue` | Amber `rgb(255,183,77)`; hidden when the queue is empty or absent |
| `git` | Branch, ahead/behind arrows, staged `+N` and modified `!N` counts | One `git status --porcelain=v1 -b` call | Bold slate-blue accent `rgb(79,91,140)`, chip text color |
| `model` | Model display name plus effort level when present | stdin `model.display_name`, `effort.level` | Periwinkle accent (claude's usage-chip purple), white text |
| `ctx` | Context window usage, `ctx 42%` | stdin `context_window.used_percentage` | Grey; amber at 50%, red at 80% (tunable) |
| `limits` | 5-hour and weekly rate limit usage as two adjacent blocks, `5h 23% · 2h14m` and `wk 41%`; the 5-hour block appends the time until the window resets when known | stdin `rate_limits.*.used_percentage`, `rate_limits.five_hour.resets_at` | Grey; each block escalates to amber at 70% and red at 90% on its own value |
| `cost` | Session cost, `$1.23` | stdin `cost.total_cost_usd` | Grey |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name.

Per-segment icons are standard Unicode glyphs (gauge `◔`, star `✦`, branch `⎇`, clock `◷`, half-circle `◑`) from the Geometric Shapes and dingbat ranges, so they render in any monospace font without a patched Nerd Font. The `session` segment carries no icon — its `claude_session_color` background is identity enough. No Nerd Font or private-use glyphs are used.

## Data sources and performance

The render path is deliberately thin: one `jq` pass over stdin, at most one git subprocess, and one small file read (`.cs/local/state` for the session color). There is no transcript parsing, no network access, and no caching. Data gathering is gated per segment, so disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git subprocess never forks.

The one write in the render path: each render stamps the current context-window usage, truncated to an integer, to `.cs/local/context-pct` (machine-local). The task-queue gate (the `narrative-reminder.sh` Stop hook, see [hooks.md](hooks.md)) reads this file to decide whether to suggest compacting before a walk-away drain. Skipped outside a cs session or when the stdin JSON carries no context percentage.

The git call runs with `GIT_OPTIONAL_LOCKS=0` (no index locking for a read-only query) under a 2-second timeout, and is skipped entirely when the workspace has no `.git`.

Failure posture is fail-open: malformed stdin, a missing `jq`, or any internal error degrades to a plain directory-name line and exit 0. A broken status line never breaks the prompt.

## Colors

Color depth is detected per render, in priority order: `FORCE_COLOR=0`, `NO_COLOR`, or `TERM=dumb` force plain text (segments joined with ` > `, no escape codes); `COLORTERM=truecolor`/`24bit` or iTerm2/WezTerm select truecolor; a `*256color*` `TERM` selects 256-color; anything else gets basic ANSI.

The `session` segment's background is the same color claude shows for the session (`/color`), read from `claude_session_color:` in the session's `.cs/local/state`. The eight session colors use Claude Code's own `/color` RGB values (its default dark/light agent-color palette), so the pill, the terminal tab color, and claude's own session accent all agree exactly.

The healthy bar carries the identity blocks as bold accents: the session name in its `claude_session_color`, the branch in slate-blue `rgb(79,91,140)`, and the model in periwinkle `rgb(138,134,236)`, the last matching claude's own usage chip. All three render bold text in the chip's own near-white `rgb(240,242,255)`; the identity segments are also the typographically loudest. Every other segment explicitly resets to normal intensity, since SGR bold is stateful and would otherwise leak rightward across the bar.

The quiet gauges (ctx, the rate limits, and cost) rest on a surface derived from the terminal's own background — a shade of `CS_TERM_BG_RGB`, darker on a light terminal and lighter on a dark one — so they harmonize with the terminal instead of sitting on a fixed grey. Their text is picked for contrast against that surface: a soft warm-dark tone (a heavily darkened shade of the surface, not a harsh near-black) on a light surface, light text on a dark one. When the terminal background is unknown (no OSC 11 result at launch, or outside truecolor) the gauges fall back to a warm neutral taupe with white text.

Color beyond the identity accents is state: warm amber `rgb(255,183,77)` (cs's warning color) past warn thresholds, red past crit. A glance answers in order: which session, which branch, which model, and is anything on fire.

Adjacent segments join with a faint one-eighth bar (`▏`, U+258F) whenever they resolve to the same rendered color, since a plain color-change divider would vanish between two identical blocks; segments with genuinely different colors abut with no glyph, since the color change is already a clear divider. The sliver is inked in a faint shade of the neighbors' own shared background, so it reads as a discreet tonal step rather than a foreign grey line (a light warm grey is the fallback outside truecolor). This is decided by comparing each segment's *resolved* color, not its name: a `claude_session_color` of `orange` renders to the exact same RGB as the logo's coral under a different name, so a name-only comparison would miss that collision.

The `logo` badge's own boundary is the one exception, and always shows a divider, built exactly like every other hairline: `▏` inks only its left ~1/8, and the cell's background — the other ~7/8 — is set to a *neighbor's* color so it disappears into that pill, leaving just the thin ink sliver visible. For same-color pairs the background is the color both neighbors already share; the logo boundary sits between two differing colors, so its divider takes the non-logo neighbor's color (the session pill's), and the sliver is inked in a darker coral (`rgb(184,101,74)`). Giving the cell a distinct background instead — the bright coral, a darker coral, grey, black — makes the whole one-column cell read as a solid block rather than a thin line, which is the trap every naive "colored divider" falls into. Because that divider cell already carries the session pill's background, the session segment drops its own leading pad space there — the divider cell serves as the pad — so the session name stays symmetric in its pill instead of sitting one column right of every other segment.

Inside tmux, Claude Code mutes its own branding and any truecolor status line to a fallback palette. cs sets `CLAUDE_CODE_TMUX_TRUECOLOR=1` in claude's environment at launch (unless you set it yourself) to keep these colors at full saturation.

## Full-width gradient

In truecolor mode the bar stretches to the terminal's full width: after the last segment, a trailing run of cells fades from that segment's own background into the terminal's real background color, so the bar reads as floating rather than stopping short in a sea of blank terminal.

This needs two pieces of information the bar doesn't otherwise require, and degrades gracefully (renders exactly as it would without this feature) when either is missing:

- **Terminal width** — Claude Code sets `$COLUMNS` on the status-line process (documented behavior, Claude Code ≥ 2.1.153); older versions don't set it, and the gradient is simply skipped.
- **The terminal's real background color** — known only when cs's own OSC 11 query succeeds at launch (see [Terminal theme](#terminal-theme) below); exported as `CS_TERM_BG_RGB`. Without it there is no honest fade target — `SGR 49` ("terminal default") is a discrete state, not a point in RGB space, so guessing a plausible background and fading toward the guess would show a visible seam wherever the guess is wrong. cs fails closed instead: no `CS_TERM_BG_RGB`, no gradient.

The gradient is truecolor-only (256-color and basic ANSI don't have the per-channel precision to fade smoothly; it would band). A narrow terminal whose bar already exceeds `$COLUMNS` gets no gradient either, since there is no room left to fill.

## Terminal theme

cs detects the terminal's light/dark theme once at session launch, while it still owns the tty: an OSC 11 background query classified by BT.709 luminance first, falling back to `COLORFGBG` only when the query gets no answer. The query outranks the variable because `COLORFGBG` goes stale across theme changes; OSC 11 asks the live terminal. Inside tmux `COLORFGBG` is a stale snapshot of the tmux server's start-time environment, so cs ignores it there. tmux that proxies OSC 11 forwards a plain query to the client terminal, so under `$TMUX` cs asks with a plain query first and takes any non-black answer as the real background; a pure-black reply is tmux's own default and is not trusted. When the plain query yields nothing trustworthy, cs retries wrapped for DCS passthrough (needs `allow-passthrough on`), then falls back to OS appearance (`defaults read -g AppleInterfaceStyle` on macOS; `unknown` elsewhere), which is right whenever the terminal theme follows the system. The result is exported as `CS_TERM_THEME` for the statusline and hooks; detection runs at launch because an OSC query fired from a render hook would race its reply into claude's input stream. On dark terminals the statusline lifts its neutral grey and softens white text; all other colors are self-backgrounded and theme-independent. Set `CS_TERM_THEME=light|dark` to override detection, and run `cs -detect-theme` to see what detection yields.

Only the OSC 11 path ever learns the terminal's actual background RGB — the `COLORFGBG`/OS-appearance fallbacks classify light or dark without it. When OSC 11 succeeds, cs exports that RGB as `CS_TERM_BG_RGB` (e.g. `250;248;242`) alongside `CS_TERM_THEME`, which is what the [full-width gradient](#full-width-gradient) fades toward. Set `CS_TERM_BG_RGB` yourself to override.

## Configuration

```bash
# Disable entirely (prints nothing)
export CS_STATUSLINE_DISABLE=1

# Choose and order segments
export CS_STATUSLINE_SEGMENTS="session,ctx,git,limits"

# Context thresholds (percent)
export CS_STATUSLINE_CTX_WARN=50
export CS_STATUSLINE_CTX_CRIT=80

# Plain text, no colors
export NO_COLOR=1
```

`CS_SESSIONS_ROOT` is honored the same way the rest of cs honors it.

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
