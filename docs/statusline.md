# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one line of squared, colored segments.

```
claude-sessions > ⎇ main↑1 +2!1 > Fable high > ctx 42% > 5h 23% · 2h14m > wk 41% > $1.23
```

With colors enabled, each segment renders as a square colored block; blocks abut so the background-color change is the divider between them. The plain form above is what `NO_COLOR=1` produces.

## Segments

Default order: `logo,session,notes,mail,pane,git,model,ctx,limits,fable`. A brand badge opens the bar, then identity (which session, which pane, which branch, which model), then the gauges. The `cost` segment ships but is off by default — add it to `CS_STATUSLINE_SEGMENTS` to show it.

| Segment | Shows | Source | Color |
|---|---|---|---|
| `logo` | A Claude mark (`✳`) badge; the mark's color pulses while Claude has finished and awaits input | `.cs/local/attention` marker (raised by the Stop hook, cleared on the next prompt or session start) | Claude coral `rgb(217,119,87)`, white mark; the pulse alternates the mark between chiptext and the darker brandshade by epoch-second parity. Claude Code's TUI re-emits only bold/fg/bg from statusline ANSI (terminal blink is dropped) and repaints only on events, so the registration sets `statusLine.refreshInterval: 1` to repaint once a second while idle — that timer animates the pulse. Omitted in plain (`NO_COLOR`) mode |
| `session` | Session name | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename | The session's `claude_session_color` from `.cs/local/state`; grey outside cs sessions |
| `notes` | Queued-task count for the current session, `▤ N` | Task files in `.cs/local/queue/` (one file per task) | Amber `rgb(255,183,77)`; hidden when the queue is empty or absent |
| `mail` | Unread cross-session mail for the current session, `✉ N` | Count of `.cs/local/mail/new/*.json` documents (`cs -msg` moves what it prints to `cur/`); only `.json` files count, so a stray `.DS_Store` or staging leftover never shows a phantom unread | Amber `rgb(255,183,77)`; hidden when nothing is unread or the maildir is absent |
| `pane` | The tmux pane hosting the conversation, `◫ %7` — a target usable verbatim in tmux commands and other chats | `TMUX_PANE` from inherited environment (no fork); requires `TMUX` too, and that this process is genuinely inside that tmux server, so an inherited pane id never renders | Grey; hidden outside tmux |
| `git` | Branch, ahead/behind arrows, staged `+N` and modified `!N` counts | One `git status --porcelain=v1 -b` call | Bold slate-blue accent `rgb(79,91,140)`, chip text color |
| `model` | Model display name plus effort level when present | stdin `model.display_name`, `effort.level` | Periwinkle accent (claude's usage-chip purple), white text |
| `ctx` | Context window usage, `ctx 42%` | stdin `context_window.used_percentage` | Grey; amber at 50%, red at 80% (tunable) |
| `limits` | 5-hour and weekly rate limit usage as two adjacent blocks, `5h 62% · 2h14m` and `wk 85% · 5d16h`; each block appends the time until its window resets when known, but only once usage is tight — the 5-hour countdown shows at 50% and up, the weekly at 80% and up, so the suffix appears as the window fills rather than while there's headroom. The countdown reads compactly (`45m`, `2h14m`), rolling into days past 24 hours (`5d16h`) | stdin `rate_limits.*.used_percentage`, `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at` | Grey; each block escalates to amber at 70% and red at 90% on its own value |
| `fable` | Fable's own weekly usage as a single block, `fable 86% · 1d20h`, rendered only when the active model is Fable. Fable draws on a model-scoped weekly bucket that the plan-wide `5h` and `wk` numbers do not describe, so without this block a Fable session shows two figures for a limit that is not the one about to bite. The countdown appends at 80% and up, like `wk` | `GET /api/oauth/usage`, cached machine-globally (see [Fable usage](#fable-usage)) | Grey; escalates to amber at 70% and red at 90% |
| `cost` | Session cost, `$1.23` (opt-in; not in the default order) | stdin `cost.total_cost_usd` | Grey |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name.

Per-segment icons are standard Unicode glyphs (gauge `◔`, star `✦`, branch `⎇`, clock `◷`, half-circle `◑`, open star `✧`, pane `◫`, envelope `✉`) from the Geometric Shapes and dingbat ranges, so they render in any monospace font without a patched Nerd Font. The `session` segment carries no icon — its `claude_session_color` background is identity enough. No Nerd Font or private-use glyphs are used.

## Data sources and performance

The render path is deliberately thin: one `jq` pass over stdin, at most one git subprocess, and one small file read (`.cs/local/state` for the session color). There is no transcript parsing and no network access. Data gathering is gated per segment, so disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git subprocess never forks — and a session on any model but Fable never touches the usage cache described below.

The writes in the render path are machine-local and best-effort: each render stamps the current context-window usage, truncated to an integer, to `.cs/local/context-pct`. The task-queue gate (the `narrative-reminder.sh` Stop hook, see [hooks.md](hooks.md)) reads this file to decide whether to suggest compacting before a walk-away drain. Skipped outside a cs session or when the stdin JSON carries no context percentage.

The same render also stamps `.cs/local/limits` (5-hour and weekly used percentages and reset epochs) so `cs -usage` can anchor its windows at the true reset boundaries; both files are machine-local and best-effort.

## Fable usage

One figure on the bar cannot come from stdin. Claude Code puts exactly two
rate-limit windows there — the plan-wide five-hour and seven-day ones — and
picks them explicitly; the per-model windows it also computes are projected only
into its control-protocol `get_usage` response, which is the SDK and remote
thin-client channel rather than anything a hook can read. Fable draws on a
model-scoped weekly bucket, so on a Fable session the `5h` and `wk` numbers
describe a limit that is not the one about to bite.

So cs fetches that one figure itself, from the same endpoint Claude Code polls:

```
GET https://api.anthropic.com/api/oauth/usage
```

The Fable bucket is the entry in the response's `limits[]` array whose
`scope.model.display_name` names a model — the unified windows ride in that same
array with a null model scope, which is why the filter keys on the display name
rather than on position. Its `percent` is already 0–100 on the wire, and its
`resets_at` is an ISO 8601 string rather than the epoch integer the stdin schema
uses, so it is converted at read time.

The bearer is Claude Code's own OAuth token, read from the macOS Keychain
(`security find-generic-password -s "Claude Code-credentials"`). cs **reads** that
credential and never refreshes or writes it: Claude Code owns the refresh cycle,
so an expired token surfaces here as a 401 to back off from, not as something to
repair. The token reaches `curl` on stdin as a `-K` config line, never on a
command line where `ps` would expose it to every process on the machine.

**The render performs no network I/O.** It reads a cache, and only on a Fable
session, where it costs one extra `jq` that reads the cache and Claude Code's
config together. When that cache is due, the render detaches
`cs-statusline --refresh-usage` — a mode of this same script, so the feature adds
no second binary and nothing to the install manifest — and renders whatever the
cache already holds.

### Why the cache is machine-global

That endpoint admits roughly **28–30 requests per identity per rolling
60 minutes**, and under one of the two observed 429 regimes the identity is the
account rather than the token. Capacity returns only as old requests age out, so
a burst saturates the account for a full hour and pausing does not restore
headroom early. The budget is shared with Claude Code itself and with any other
tool on the machine that polls it.

Hence one cache for the host, at `$CS_SESSIONS_ROOT/.usage/fable.json`, rather
than one per session, and a 300-second floor between polls: cs contributes about
twelve requests an hour however many sessions are open. A `mkdir` lock
serialises refreshers across sessions (a lock older than 120 seconds is treated
as abandoned), and a 429 backs off for `Retry-After` plus a minute, floored at
ten — a 429 does not reliably clear at its stated horizon.

Polling happens only while the active model is Fable, because the trigger lives
inside the segment and the segment is gated on the model. A session on any other
model costs the budget nothing.

### When the chip does not render

The chip is null-when-nothing, and deliberately strict about it: no cache, no
Fable window on the account, no `jq` or `curl`, a reading older than 1800
seconds, or a reading stamped with a different account than the one now signed
in. That last check exists because accounts get swapped precisely when one is
near a limit — the moment a stale percentage would mislead most. The countdown
is always recomputed from `resets_at` at render time, so it stays accurate even
when the percentage beside it is a few minutes old.

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

## Subagent rows

`cs-subagent-statusline` styles Claude Code's agent panel — the task tree under the prompt while subagents run — the way `cs-statusline` styles the bar. Claude Code pipes `{columns, tasks[]}` to the registered `subagentStatusLine.command` on every panel repaint; the script prints one `{"id","content"}` JSON line per row it overrides. An omitted `id` keeps that row's default rendering, which is why printing nothing is always safe.

```
⤷ ✦ Sonnet 5  bundle-recon · Spelunk CC bundle  ◔ ctx 12%  ◷ 2m14s
⤷ ✦ Opus 4.8  code-reviewer · Review the diff  ◔ ctx 61%  ◷ 0m18s
```

Left to right: a descent glyph marking the row as spawned work, the model chip in the bar's periwinkle, the agent's name (falling back to its `type`), the description, the agent's **own** context-window usage, and time since it started. Model, context, and elapsed are the three columns Claude Code's default row (`name · description · token count`) lacks, and they are what make agents at different tiers distinguishable — a recon agent at ctx 12% and a synthesizer dying at ctx 84% otherwise look identical. The gauge escalates amber/red on the same `CS_STATUSLINE_CTX_WARN`/`CS_STATUSLINE_CTX_CRIT` thresholds the bar uses.

Rows are null-when-nothing like the bar's segments: no `model` means no chip and no gauge (`contextWindowSize` arrives only once the model is resolved, Claude Code ≥ 2.1.205), a `contextWindowSize` of 0 means no gauge, no `startTime` means no clock. Model ids arrive resolved (`claude-sonnet-5`), not as the display names the main bar receives, and are matched on a prefix so dated suffixes and `[1m]` context markers resolve; an unrecognised id renders verbatim — a new model must degrade to ugly, never to invisible.

A row never exceeds the payload's `columns`, because one that does wraps the panel. Parts are shed in order of what they are worth: first the description's tail, cut with a single ellipsis; then the description entirely, once its remainder falls under a small floor; then elapsed. The ctx gauge outranks all of them, because a runaway agent's percentage is the thing worth seeing. When even the core — glyph, model chip, name, gauge — will not fit, the row is not emitted at all, and Claude Code's default rendering stands; a default row beats a wrapped one. Unlike the bar, rows are not self-backgrounded pills: they sit on the terminal background inside Claude Code's own panel, so only foreground colors are used.

Tabs, newlines, and carriage returns in a name or description are collapsed to spaces before the fields are packed. The pack is `jq`'s `@tsv`, which would otherwise encode them as the two-character sequences `\t` and `\n` — a transport detail that would then render literally in the panel. `@tsv` also doubles a backslash, which the reader undoes, so a description containing one keeps a single backslash.

Each row's `content` is emitted with `jq -c`, which escapes the ESC byte as the six-character sequence `\u001b`. That is the contract, not a nicety: Claude Code `JSON.parse`s every stdout line and schema-checks it against `{id, content}`, and a hand-rolled JSON string carrying a raw control byte fails that check and is silently skipped.

The rest of the contract was established by reading the Claude Code bundle (2.1.206); none of it is in the public docs:

- **Rows keep rendering while you view an agent's transcript.** Entering that view marks the task `retain: true` and clears its `evictAfter`, so it stays in the row set and keeps ticking.
- **A "you are here" marker is impossible.** Claude Code passes `viewingAgentTaskId` into its own row builder but never into the command's stdin, so the script cannot know which agent you are looking at — and does not pretend to.
- **The command is not invoked when the last agent exits.** The invoker short-circuits on an empty row set before running it, so this script can never clear state it wrote. That is why the rows feed nothing to the main bar: an `agents` segment sourced from here would stay stale forever after the last agent exits.
- **The registration is read at Claude Code startup.** `cs -statusline enable` registers `subagentStatusLine` alongside `statusLine`, and Claude Code must be restarted before a new registration takes effect; a mid-session edit is silently ignored.

Failure posture matches the bar: fail-open, always exit 0, print nothing rather than something wrong. Claude Code kills the command at 5 seconds; the hot path is one `jq` pass over stdin and one `jq -c` per row — no git, no network, no file reads. `CS_SUBAGENT_STATUSLINE_DISABLE=1` silences the rows without touching the bar.

`bin/cs-subagent-statusline` sources `bin/cs-statusline` in library mode (`CS_STATUSLINE_LIB=1`) for the color ladder, palette, and width measurement — the alternative was a third hand-synced copy of the palette, which would rot — so it must sit beside `cs-statusline`; `install.sh` installs both into the same directory.

## Full-width gradient

In truecolor mode the bar stretches to the terminal's full width: after the last segment, a trailing run of cells fades from the neutral gauge-surface tone into the terminal's real background color, so the bar reads as floating rather than stopping short in a sea of blank terminal. The fade deliberately anchors on the quiet surface tone, **not** the last segment's own color — the final segment is often a gauge that escalates to amber or red near a limit, and inheriting that would flood the whole empty tail with the alarm color. Anchoring on surface keeps the empty end quiet regardless of usage.

This needs two pieces of information the bar doesn't otherwise require, and degrades gracefully (renders exactly as it would without this feature) when either is missing:

- **Terminal width** — Claude Code sets `$COLUMNS` on the status-line process (documented behavior, Claude Code ≥ 2.1.153); older versions don't set it, and the gradient is simply skipped.
- **The terminal's real background color** — known only when cs's own OSC 11 query succeeds at launch (see [Terminal theme](#terminal-theme) below); exported as `CS_TERM_BG_RGB`. Without it there is no honest fade target — `SGR 49` ("terminal default") is a discrete state, not a point in RGB space, so guessing a plausible background and fading toward the guess would show a visible seam wherever the guess is wrong. cs used to fail closed on that reasoning: no `CS_TERM_BG_RGB`, no gradient. The reasoning was right — a guessed endpoint does show a seam — but it assumed the only way to reach the terminal is to name its colour. It is not. A block element paints only part of its cell (`░` covers roughly a quarter), so the rest of every cell is the terminal's own background, whatever it is. Where there is no measurement the tail is therefore a coverage wash rather than a colour fade: it reaches the terminal exactly, on a light terminal, a dark one, one that switches theme mid-session, and one with a translucent or image background — none of which a named colour survives.

The gradient is truecolor-only (256-color and basic ANSI don't have the per-channel precision to fade smoothly; it would band). A narrow terminal whose bar already exceeds `$COLUMNS` gets no gradient either, since there is no room left to fill.

## Terminal theme

cs detects the terminal's light/dark theme once at session launch, while it still owns the tty: an OSC 11 background query classified by BT.709 luminance first, falling back to `COLORFGBG` when the query gets no answer, then to OS appearance when neither says anything. The query outranks the variable because `COLORFGBG` goes stale across theme changes; OSC 11 asks the live terminal. Inside tmux `COLORFGBG` is a stale snapshot of the tmux server's start-time environment, so cs ignores it there. tmux that proxies OSC 11 forwards a plain query to the client terminal, so under `$TMUX` cs asks with a plain query first and takes any non-black answer as the real background; a pure-black reply is tmux's own default and is not trusted. When the plain query yields nothing trustworthy, cs retries wrapped for DCS passthrough (needs `allow-passthrough on`), then falls back to OS appearance (`defaults read -g AppleInterfaceStyle` on macOS; `unknown` elsewhere), which is right whenever the terminal theme follows the system. The launch detection sets the palette for cs's own UI and the TUI picker (exported as `CS_TERM_THEME`), and sets a `CS_TERM_THEME_AUTO` marker so the statusline knows the value came from auto-detection rather than an explicit pin. The status line never asks the operating system what the terminal looks like: the system's appearance says nothing about a terminal with a fixed scheme or one embedded in an app, which is where relying on it was reliably wrong. A terminal that can answer for itself does so through the rungs above; a terminal that cannot is taken to be dark, the assumption the rest of cs makes with nothing to go on. The cost is that a light terminal which reports nothing and was not launched by cs renders the dark palette — pin `CS_TERM_THEME=light` there. It cannot re-run the OSC query from a render, which would race its reply into claude's input stream. Setting `CS_TERM_THEME=light|dark` yourself is an explicit pin (no auto marker) that wins everywhere — use it when the terminal's theme is decoupled from the system. A session already open when the terminal switches keeps its launch palette until relaunched, on every platform: the rungs that could notice mid-session are the terminal's own answers, and a terminal that does not report its theme has none. On dark terminals the statusline lifts its neutral grey and softens white text; all other colors are self-backgrounded and theme-independent. Run `cs -detect-theme` to see what launch detection yields.

A session cs did not launch carries none of that, so two further rungs sit above the OS appearance and describe the terminal rather than the system. Outside tmux the statusline reads `COLORFGBG`, the terminal's own statement about itself; inside tmux it ignores it for the same reason the launch detector does — there it is the server's start-time snapshot and goes stale across theme changes. Inside tmux it instead asks the server for the attached client's reported theme (`#{client_theme}`), which is live and describes the client, but which only terminals that report their theme populate at all; when it is empty the ladder falls through. Neither rung reaches a terminal that is inside tmux and reports nothing, and for that combination no passive per-render signal exists.


`TMUX` is ordinary environment and is inherited wholesale, so a program launched from a tmux pane passes it to everything it spawns — including a window it opens in a terminal of its own. That child claims a tmux membership it does not have, and every rung keyed off `TMUX` then reads the wrong terminal: the client rung asks a client that is not ours, and `COLORFGBG` is skipped to avoid a staleness that does not apply. The second field of `TMUX` is the tmux server pid, which is the one part of the claim that can be checked rather than believed — a process in a real pane has that server among its ancestors. The statusline walks its own ancestry once per render (a single `ps`, only when `TMUX` is set) and, when the server is absent, treats the whole inherited terminal description as describing somewhere else: it takes dark rather than the inherited `CS_TERM_THEME`, drops `CS_TERM_BG_RGB` so the [gradient](#full-width-gradient) does not fade toward another terminal's background, and hides the [pane segment](#segments) rather than print a pane id belonging to someone else's session. An explicit `CS_TERM_THEME` pin still wins over all of this. Observed with terminal-embedding apps that shell out before opening their own window, where the symptom is a light bar on a dark window.

Every signal above describes the terminal cs was launched from, which is the wrong terminal once a tmux session is re-attached from a different one — the palette then tracks the window cs started in rather than the window you are looking at, until the session is relaunched. Measuring again on attach needs a query the statusline cannot safely make from a render, and the attempts to make it from elsewhere each traded one fault for another; the reliable fix is for the host to report the theme it has already resolved.

Only the OSC 11 path ever learns the terminal's actual background RGB — the `COLORFGBG`/OS-appearance fallbacks classify light or dark without it. When OSC 11 succeeds, cs exports that RGB as `CS_TERM_BG_RGB` (e.g. `250;248;242`) alongside `CS_TERM_THEME_AUTO`, which is what the [full-width gradient](#full-width-gradient) fades toward. When it is absent, cs first tries to find the measurement anyway: launch writes it to `~/.cache/cs/term/<key>`, keyed by the tmux client tty (cs's own tty outside tmux), and a render with no `CS_TERM_*` asks tmux which client its pane is on and reads it back. That is what lets a pane cs never launched — an agent-teams teammate is spawned straight off the tmux server and inherits nothing — draw the same bar as every other pane on that terminal. The key is the terminal's identity, so re-attaching from a different terminal misses rather than returning a stale answer. tty names are recycled by the OS, though, so the key alone is not enough: entries also expire, and one older than twelve hours is refused rather than trusted.

When even that misses, the tail switches mechanism rather than disappearing: it becomes a coverage wash of `░` drawn as foreground on the terminal's default background, so the uncovered part of each cell is the terminal itself and no colour is ever named. Unicode offers only four coverage levels, too few to be smooth, so the block stays `░` and the colour does the fine work, ramping in truecolor to within a couple of units of a conventional page of the resolved theme. A measured `CS_TERM_BG_RGB` still takes the colour fade, which can end exactly on the terminal's value rather than approach it.

Both of those need truecolor, and inside tmux the host mutes a truecolor status line to a fallback palette unless `CLAUDE_CODE_TMUX_TRUECOLOR` is set — which cs exports at launch, so a pane cs launched keeps full colour and one it did not does not. Rather than emit 24-bit for the host to snap (a warm off-white's nearest palette neighbour is a pink, so a smooth ramp came out as flat blocks), cs detects that case and drops to the 256 palette deliberately. Such a bar cannot ramp at all, so its tail is a row of evenly spaced `·` at one dim palette grey — foreground-only again, so the cells between them are the terminal's own colour. Setting `CLAUDE_CODE_TMUX_TRUECOLOR=1` in the tmux server environment restores full colour and the gradient for those panes.

`CS_TERM_BG_RGB` stays at its launch value for the life of the session, so a terminal that changes background mid-session keeps fading toward the old one. Set it yourself to override.

### Pinning the background

A measured background always outranks the assumption, and supplying one by hand is the only way to make the fade's far end vanish completely into the terminal. Export it in the shell that terminal starts:

```sh
export CS_TERM_BG_RGB='20;23;41'   # r;g;b, 0-255 each
```

To find the value: read it from the terminal's own theme settings, or screenshot the window and sample a pixel of empty background — anywhere with no text, well away from the status bar. Any image editor's colour picker will do; from the command line, with Pillow installed:

```sh
python3 -c "from PIL import Image; im=Image.open('shot.png').convert('RGB'); print(im.getpixel((100,40)))"
```

Sample two or three points and check they agree, so a compression artifact or a translucent window's blur does not become the pinned value.

## Configuration

```bash
# Disable entirely (prints nothing)
export CS_STATUSLINE_DISABLE=1

# Disable only the agent-panel rows (the bar is untouched)
export CS_SUBAGENT_STATUSLINE_DISABLE=1

# Choose and order segments
export CS_STATUSLINE_SEGMENTS="session,ctx,git,limits"

# Context thresholds (percent)
export CS_STATUSLINE_CTX_WARN=50
export CS_STATUSLINE_CTX_CRIT=80

# Where the machine-global usage cache lives (default $CS_SESSIONS_ROOT/.usage)
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the fable chip from cache only, never kicking a refresh
export CS_USAGE_NO_REFRESH=1

# Plain text, no colors
export NO_COLOR=1
```

`CS_SESSIONS_ROOT` is honored the same way the rest of cs honors it.

## Install, uninstall, doctor

`install.sh` deploys the `cs-statusline` and `cs-subagent-statusline` binaries to `~/.local/bin` unconditionally, but the status bar itself is claimed only with consent: with a terminal attached the installer asks before registering (default yes; it also asks before replacing an existing status line), and a non-interactive install registers nothing and prints how to enable later. Consent registers both keys — the bar and the [subagent rows](#subagent-rows) — exactly as `cs -statusline enable` does. Turn both on or off any time:

```bash
cs -statusline enable    # register bar + subagent rows (overwrites the current status line; the command is your consent)
cs -statusline disable   # remove both registrations, each only if it points at the cs binary
```

Claude Code reads both registrations at startup, so `enable` takes effect after the next restart — the command says so when it runs.

`cs -uninstall` removes both binaries and strips the `statusLine` and `subagentStatusLine` registrations only when they point at the cs binaries; a status line or row renderer you configured yourself is left untouched.

`cs -doctor` includes a Statusline check and a parallel Subagent statusline check: OK when registered and executable, FAIL when a registration points at a missing binary. The Statusline check WARNs when cs-statusline is absent — unregistered, or a status line of your own — because it is the only writer of `.cs/local/context-pct`, and without that file the rotation nudge and the queue's context circuit breaker both go silently inert. The status line itself stays optional; the warning is about the gating that depends on it.

## Design notes

The design came out of a source study of [claude-powerline](https://github.com/Owloops/claude-powerline) (techniques: the single-call git query, the color-support ladder, per-segment gating of all I/O) and of oh-my-claudecode's HUD as a counterexample (its per-render transcript parsing, unconditional state reads, and multi-line output are the failure modes this script is shaped against). Claude Code delivers everything else needed (session name, context %, rate limits, model, cost) directly in the status-line stdin JSON, which is why the hot path needs no other data source.
