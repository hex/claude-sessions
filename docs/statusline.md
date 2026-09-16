# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one line of rounded capsules on the terminal's own background.

```
✳ claude-sessions  ·  ⎇ main↑1 +2!1  ·  ✦ Fable 5.1 medium  ◑ ctx 42%  ◷ 5h 31% ⋮ ◶ wk 84% · 5d16h
```

One capsule carries identity — the Claude mark, the session, the branch, the model — and one carries the context gauge. The quota capsule (5h, joined by a vertical ellipsis to wk once wk reaches 50) is always there; the Fable window gets its own capsule at 50. Colour is state: bold amber ink on a number past its warn threshold, and the capsule inverts to red at crit, its text pulsing white/pink on the attention clock. The plain form (`NO_COLOR=1`) is `claude-sessions · ⎇ main↑1 +2!1 · ✦ Fable 5.1 medium > ◑ ctx 42% > ◷ 5h 31% ⋮ ◶ wk 84% · 5d16h`.

## Segments

Default order: `logo,session,notes,mail,git,model,ctx,limits`. One capsule holds identity (which session, which branch, which model); one holds the context gauge; one quota capsule always follows, holding 5h and, from 50, wk after a vertical ellipsis; on a Fable session the model window gets its own capsule from 50. `pane` and `fable` ship but leave the default order — name them in `CS_STATUSLINE_SEGMENTS` to show them. The `cost` segment ships too, off by default the same way.

| Name | Group | Rest | Hot | Hidden when | Source |
|---|---|---|---|---|---|
| `logo` | identity | `✳` in brand coral, bold; pulses brand/brandshade by epoch parity while `.cs/local/attention` exists | — | plain mode (no colour) | `.cs/local/attention` marker (raised by the Stop hook, cleared on the next prompt or session start) |
| `session` | identity | name, bold, primary ink | — | never | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename |
| `notes` | identity | `▤ N`, amber ink, regular, directly after the session | — | queue empty or absent | Task files in `.cs/local/queue/` (one file per task) |
| `mail` | identity | `✉ N`, amber ink, regular, after notes | — | nothing unread | Count of `.cs/local/mail/new/*.json` documents (`cs -msg` moves what it prints to `cur/`); only `.json` files count, so a stray `.DS_Store` or staging leftover never shows a phantom unread |
| `pane` | identity | `◫ 7` (the `%` dropped), secondary ink; only when named | — | not named, or outside a real tmux | `TMUX_PANE` from inherited environment (no fork); requires `TMUX` too, and that this process is genuinely inside that tmux server, so an inherited pane id never renders |
| `git` | identity | branch with the arrows and `+N!N` marks, bold ink | — | no `.git` | One `git status --porcelain=v1 -b` call |
| `model` | identity | display name in bold ink; the effort word, regular weight, in Claude Code's own `/effort` colour for its level (low gold, medium green, high blue, xhigh violet, max a blue-to-pink gradient across its letters) | — | no model on stdin | stdin `model.display_name`, `effort.level` |
| `ctx` | ctx | `◔ ctx N%`, secondary ink; the pie fills with the band: `○` below 13, `◔` to warn, `◑` through amber, `◕` at crit, `●` from 88 | amber ink on the number at 40; crit inversion at 65 (`CS_STATUSLINE_CTX_WARN`/`_CRIT`; the half and three-quarter steps follow them) | no `context_window` on stdin | stdin `context_window.used_percentage` |
| `limits` | limits | `◷ 5h N%` | the quota capsule `5h N% ⋮ wk N%` (5h always, wk from 50, joined by a vertical ellipsis) and a separate `fable N%` capsule from 50 on a Fable session: `5h N% · 2h14m`, `wk N% · 5d16h`, `fable N% · 18h`; neutral below 70, amber ink at 70, crit inversion at 90; the countdown joins 5h at 70 and the coarse windows at 80 | wk and fable below 50 | stdin `rate_limits.*.used_percentage`, `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at`, plus the usage cache when the model is Fable |
| `fable` | limits | accepted as a name: the Fable window alone when `limits` is not named; a no-op beside `limits` | — | below 70, like every window | `GET /api/oauth/usage`, cached machine-globally (see [Fable usage](#fable-usage)) |
| `cost` | cost | `$N.NN`, secondary ink, its own capsule after limits; only when named | — | not named, or no cost on stdin | stdin `cost.total_cost_usd` |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name. `pane`, `fable` and `cost` ship but stay off the default order — name them in `CS_STATUSLINE_SEGMENTS` to turn them on.

The limits group folds the three windows into one rule. The Fable window is model-scoped and lives only in the usage cache (see [Fable usage](#fable-usage)); it joins the candidate list only on a Fable session, and its refresh kick keeps its existing gate: the cache is read and the refresher detached whether or not the capsule ends up shown, so a hidden Fable window is still polled at its 600-second floor. The countdown appears once a window is tight: for 5h whenever it shows (its reveal and its countdown gate are both 70), for wk and fable at 80 and up.

The two files the render writes, `.cs/local/context-pct` and `.cs/local/limits`, are produced in `_parse_stdin` before any segment runs and stay untouched by the gating above. Hiding a capsule never hides a heartbeat.

Segment icons are standard Unicode glyphs (the context pie `○ ◔ ◑ ◕ ●`, star `✦`, branch `⎇`, clock `◷`, week `◶`, open star `✧`, pane `◫`, envelope `✉`) from the Geometric Shapes and dingbat ranges, so they render in any monospace font without a patched Nerd Font. The `session` segment carries no icon — the capsule and its position are the identity. The capsule caps (U+E0B6, U+E0B4) are the one private-use exception, so they are drawn only once this machine has answered the installer's question about them (see [Colors](#colors)).

## Data sources and performance

The render's cost is its fork count. The bar repaints once a second (`refreshInterval: 1`, so the Claude mark can pulse), and on a loaded machine every external command costs what the scheduler charges (measured at 0.3 s per fork at load 25); a render that forks a dozen commands runs past the limit Claude Code gives a status line and the tick is killed. So a warm render forks exactly two: the interpreter and one `jq` pass over stdin (a bash without a builtin clock, macOS's stock 3.2, adds one `date`). Everything else it needs is a builtin read of a small file, and every other fork sits behind a cache or a cadence:

| Fork | Kept | Where | Comes back |
|------|------|-------|-----------|
| `git status` (the `git` segment) | 5 s | `~/.cache/cs/git/` | one render in five, so a branch switch or a dirty file shows within five seconds |
| `ps` + `awk`, the tmux ancestry walk (is this process really in the tmux server `TMUX` names) | 5 min | `~/.cache/cs/tmux-real/`, by parent pid and `TMUX` | once per conversation: the parent (Claude Code) is the same for every render, and a process that only inherited `TMUX` has a different parent, so it cannot inherit the verdict; a `ps` that cannot answer is never cached. A wrapper Claude Code runs in place of the script (a status-line bridge, a new process each tick) sets `CS_STATUSLINE_PARENT` to the pid it is itself the child of, and both parent-keyed caches key on that |
| `tmux display-message`, the attached client's theme and tty | 5 s | `~/.cache/cs/tmux-client/`, by parent pid and `TMUX` | asked once per theme pass, both fields from one query, and once in five renders; a theme toggle or a re-attach from another terminal shows within five seconds |
| `jq --stream` over Claude Code's `.claude.json` for the account id (Fable sessions) | 5 min | `~/.cache/cs/org/`, by config path | an account swap shows within five minutes; the refresher, which attributes a reading and detects a swap across its own fetch, always reads the config itself and renews the entry |
| `jq` over the Fable usage record, and `date` for its reset countdown | with the record | `fable.<account>.json.fields` beside it: pct, resets_at, fetched_at, next_poll_at, and the reset as an epoch, one per line | written by the refresher with the JSON, never by a render, so a slow parse of an old record cannot overwrite a newer sidecar; the refresher honours the JSON's schedule (so a recorded backoff is never skipped) and rewrites a sidecar that disagrees with it from the JSON, without a fetch; a record with no sidecar (from before it existed) is parsed with `jq` until the next refresh |
| `mv` for the `.cs/local/context-pct` and `.cs/local/limits` stamps | 60 s when the value is unchanged | `<stamp>.at` beside each, `epoch value`; a teammate's heartbeat touch keeps its own | a changed value is written at once; an unchanged one once a minute, which is the heartbeat (its readers allow 900 s for the mtime and 1800 s for `stamped_at`) |

A cache entry is two lines: `epoch<TAB>identity`, then the text. The identity is the raw value the file name was made from (the workspace path, the config path, `<parent pid>,<TMUX>`), so two values that sanitise to the same name (`/x/a/b` and `/x/a-b`) never answer for each other, and the age is arithmetic against the render's one clock rather than a `find` or `stat` fork; the terminal-theme entry under `~/.cache/cs/term/` (see [Colors](#colors)) carries an epoch too. Every cache write is a builtin `printf`, and a read takes an entry only when both its lines are complete, so a torn read is a miss, never a wrong answer. Data gathering is still gated per segment: disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git line is neither forked for nor cached. There is no transcript parsing and no network access; a Fable session reads the usage cache and never fetches from the render (see [Fable usage](#fable-usage)).

The writes in the render path are machine-local and best-effort: the render stamps the current context-window usage, truncated to an integer, to `.cs/local/context-pct`; the value is written only by the conversation whose id `.cs/local/state` records as launched, and any other conversation in the directory (a tmux teammate) touches the file instead, keeping the liveness heartbeat alive without replacing the lead's reading. The task-queue gate (the `narrative-reminder.sh` Stop hook, see [hooks.md](hooks.md)) reads this file to decide whether to suggest compacting before a walk-away drain. Skipped outside a cs session or when the stdin JSON carries no context percentage.

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

The bearer is Claude Code's own OAuth token. On macOS that comes from the
Keychain (`security find-generic-password -s "Claude Code-credentials"`); on
Linux and WSL2, where there is no Keychain, Claude Code keeps the same document
in plaintext at `<config_home>/.credentials.json` and cs reads that instead. cs
**reads** that
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

Hence one cache for the host, at `$CS_SESSIONS_ROOT/.usage/fable.<account>.json`,
rather than one per session, and a 600-second floor between polls: cs
contributes about six requests an hour per account, however many sessions are
open. The file is keyed by account rather than holding one record for the
machine, so that two sessions signed into different accounts each keep their own
cadence — with a single shared record, whichever account was not in it had to
override the interval to replace it, and two such sessions then fetched on every
render, defeating the floor entirely. The floor is 600 rather
than 300 because claude-swap, which many cs users run alongside, polls the same
account on its own 180-second floor — at 300 the two together would already
exceed the ceiling before Claude Code's own polls. Nothing visible changes,
since a reading stays usable for 1800 seconds.

A lock serialises refreshers across sessions. A lock older than 120 seconds is
treated as abandoned and reclaimed by *renaming* it: with a plain remove, two
contenders that both see it stale can both proceed, the second deleting the
first's fresh lock. A 429 backs off for `Retry-After` plus a minute, floored at
ten — a 429 does not reliably clear at its stated horizon.

Polling happens only while the active model is Fable, because the trigger lives
inside the segment and the segment is gated on the model. A session on any other
model costs the budget nothing.

### When the Fable capsule does not render

The capsule is null-when-nothing, and deliberately strict about it: usage below 70%, no cache, no
Fable window on the account, no `jq` or `curl`, no readable credential, or a
reading older than 1800 seconds. Identity is structural rather than checked: a
record is addressed by account, so a reading can never be found under the wrong
one, and a refresh that cannot identify the account it fetched for stores
nothing at all. A failed refresh keeps that account's last good number; a
response that is not this API's JSON — a captive portal's 200, say — counts as a
failure rather than as an account with no Fable window.

Structure rather than comparison, because accounts get swapped precisely when
one is near a limit — the moment a stale percentage misleads most, and the
moment a check that has to be remembered at every read is likeliest to be missed
at one of them. The countdown
is always recomputed from `resets_at` at render time, so it stays accurate even
when the percentage beside it is a few minutes old.

The git call runs with `GIT_OPTIONAL_LOCKS=0` (no index locking for a read-only query) under a 2-second timeout, and is skipped entirely when the workspace has no `.git`. The workspace is Claude Code's `workspace.current_dir`: in a session adopted with `cs -adopt`, or a `<base>@<feature>` worktree, that is the checkout itself, so the branch shown is the project's. A plain session directory is its own one-commit repo on `main`, and a bar reading `main !2` there is that repo and its dirty `.cs` files, not some project the conversation happens to discuss; adopt the project to see its branch.

Failure posture is fail-open: malformed stdin, a missing `jq`, or any internal error degrades to a plain directory-name line and exit 0. A broken status line never breaks the prompt.

## Colors

Color depth is detected per render, in priority order: `FORCE_COLOR=0`, `NO_COLOR`, or `TERM=dumb` force plain text (segments joined with ` > `, no escape codes); `COLORTERM=truecolor`/`24bit` or iTerm2/WezTerm select truecolor; a `*256color*` `TERM` selects 256-color; anything else gets basic ANSI.

| Token | Role | Truecolor | 256 | Basic |
|---|---|---|---|---|
| `surface` | every capsule fill | `CS_TERM_BG_RGB` shaded 10% away from itself (`_bg_shade`), taupe fallback when unmeasured | 254/237 | 90 |
| `ink` | primary text | a 35% shade of the surface on a light surface, `white` on a dark one | 236/255 | 97 |
| `ink2` | secondary text, dots, gauge labels | a 55% shade of the surface (lifted toward white on a dark surface), like `ink` | 241/250 | 37/97 |
| `brand` | the mark | `217;119;87` | 173 | 33 |
| `brandshade` | the pulse's dim phase | `184;101;74` | 167 | 33 |
| `periwinkle` | the subagent rows' model capsule | light: `76;29;149`; dark: `196;181;253` | 55/147 | 35/95 |
| `amber` | hot numbers, notes and mail counts | light: `180;83;9`; dark: `253;230;138` — light/dark by the measured `CS_TERM_BG_RGB`, by theme only when unmeasured | 130/221 | 33/93 |
| `crit` | inverted capsule fill | light: `215;0;21`; dark: `255;69;58` | 160/203 | 31 |
| `critink` | inverted capsule text | `255;255;255` on both themes | 231 | 97 |
| `effort-*` | the effort word | Claude Code's /effort picker colours, pixel-sampled; lifted a third toward white on dark; `effort-max-1..3` are the gradient stops | 136/179, 28/71, 63/105, 93/135, 110·140·175 / 153·183·218 | 33, 32, 34, 35, 36·35·95 |
| `critshade` | the crit pulse's dim phase | `255;205;200` | 224 | 97 |

Every capsule fill is `surface`, a shade of the terminal's own background so the bar harmonizes with the terminal instead of sitting on a fixed grey; darker on a light terminal, lighter on a dark one. On a cream terminal (`253;246;227`) the derived surface comes out `227;221;204`, a warm off-white a few shades darker — so the values above are the fallback for an unmeasured background and a reference for what the derived shade lands near, not fixed paints.

`amber` is ink, painted straight onto the capsule surface rather than as a fill of its own — a fill chosen for black text on it fails contrast once it is the text color instead, which is why hot numbers use this separate ink token. The session palette (`red`, `blue`, … `orange`) stays in `_sgr` untouched: it is Claude Code's shared eight-color tab palette, KEEP IN SYNC with `_session_color_rgb` in `bin/cs`. The bar itself never paints with it: the session name is `ink` like the branch and the model. `crit` is its own token so the gauge's red never depends on that palette's `red`. The reset countdown shares the number's ink: it is part of the same reading.

Removed from the bar: `hairline`, `chiptext` (the mark's bright phase uses `brand` instead), `black`, and `amber` as a fill. `periwinkle` stays for the [subagent rows'](#subagent-rows) model capsule. Those rows otherwise paint with `rowname`, `rowmeta`, `amber` and `crit` through `_paint` → `_sgr`, the same `amber`/`crit` tokens the bar uses, so a row's hot ctx and the bar always agree on the two hot colors.

Capsule ends are the Powerline glyphs U+E0B6 and U+E0B4, drawn as fill-colored ink on the terminal's default background so they read as rounded ends. They need a font that carries them (any Nerd Font does), and a font without them shows a box at every capsule edge. A terminal cannot be asked whether it has a glyph, so cs asks you: the installer shows a sample capsule and asks whether its ends look rounded, and records the answer per machine in `~/.config/cs/statusline-caps` (`on` or `off`). Until a machine has answered, the capsules are square chips with the same spacing. `cs -statusline caps on|off|ask` rewrites the answer, `cs -doctor` reports it, and `CS_STATUSLINE_CAPS=1` or `=0` in the environment overrides the file either way. Caps render at every color level — the cap's ink is the capsule's fill, which 256-color and basic terminals both have — and never in plain mode.

Inside tmux, Claude Code mutes its own branding and any truecolor status line to a fallback palette. cs sets `CLAUDE_CODE_TMUX_TRUECOLOR=1` in claude's environment at launch (unless you set it yourself) to keep these colors at full saturation, and inside tmux publishes the same value into the session's environment so teammate panes claude opens get it as well.

## Subagent rows

`cs-subagent-statusline` styles Claude Code's agent panel — the task tree under the prompt while subagents run — the way `cs-statusline` styles the bar. Claude Code pipes `{columns, tasks[]}` to the registered `subagentStatusLine.command` on every panel repaint; the script prints one `{"id","content"}` JSON line per row it overrides. An omitted `id` keeps that row's default rendering, which is why printing nothing is always safe.

```
⤷ ✦ Sonnet 5  bundle-recon · Spelunk CC bundle  ○ ctx 12%  ◷ 2m14s
⤷ ✦ Opus 4.8  code-reviewer · Review the diff  ◑ ctx 61%  ◷ 0m18s
```

Left to right: a descent glyph marking the row as spawned work, the model capsule in the bar's periwinkle, the agent's name (falling back to its `type`), the description, the agent's **own** context-window usage, and time since it started. Model, context, and elapsed are the three columns Claude Code's default row (`name · description · token count`) lacks, and they are what make agents at different tiers distinguishable — a recon agent at ctx 12% and a synthesizer dying at ctx 84% otherwise look identical. The gauge escalates amber/red on the same `CS_STATUSLINE_CTX_WARN`/`CS_STATUSLINE_CTX_CRIT` thresholds the bar uses, so a row and the bar always agree on where amber and red start.

Rows are null-when-nothing like the bar's segments: no `model` means no capsule and no gauge (`contextWindowSize` arrives only once the model is resolved, Claude Code ≥ 2.1.205), a `contextWindowSize` of 0 means no gauge, no `startTime` means no clock. Model ids arrive resolved (`claude-sonnet-5`), not as the display names the main bar receives, and the name is derived from the id rather than looked up: the family is capitalised, numeric parts join with dots (`claude-fable-5-1` → `Fable 5.1`), a trailing word is kept as a stage tag (`-preview`), and an 8-digit build date (after `-` or Vertex's `@`) and a `[1m]` context marker are dropped. A family nobody has listed still resolves (`claude-zephyr-9` → `Zephyr 9`); an id that does not fit the shape renders verbatim — a new model must degrade to ugly, never to invisible.

A row never exceeds the payload's `columns`, because one that does wraps the panel. Parts are shed in order of what they are worth: first the description's tail, cut with a single ellipsis; then the description entirely, once its remainder falls under a small floor; then elapsed. The ctx gauge outranks all of them, because a runaway agent's percentage is the thing worth seeing. When even the core — glyph, model capsule, name, gauge — will not fit, the row is not emitted at all, and Claude Code's default rendering stands; a default row beats a wrapped one. Unlike the bar, rows are not self-backgrounded capsules: they sit on the terminal background inside Claude Code's own panel, so only foreground colors are used.

Tabs, newlines, and carriage returns in a name or description are collapsed to spaces before the fields are packed. The pack is `jq`'s `@tsv`, which would otherwise encode them as the two-character sequences `\t` and `\n` — a transport detail that would then render literally in the panel. `@tsv` also doubles a backslash, which the reader undoes, so a description containing one keeps a single backslash.

Each row's `content` is emitted with `jq -c`, which escapes the ESC byte as the six-character sequence `\u001b`. That is the contract, not a nicety: Claude Code `JSON.parse`s every stdout line and schema-checks it against `{id, content}`, and a hand-rolled JSON string carrying a raw control byte fails that check and is silently skipped.

The rest of the contract was established by reading the Claude Code bundle (2.1.206); none of it is in the public docs:

- **Rows keep rendering while you view an agent's transcript.** Entering that view marks the task `retain: true` and clears its `evictAfter`, so it stays in the row set and keeps ticking.
- **A "you are here" marker is impossible.** Claude Code passes `viewingAgentTaskId` into its own row builder but never into the command's stdin, so the script cannot know which agent you are looking at — and does not pretend to.
- **The command is not invoked when the last agent exits.** The invoker short-circuits on an empty row set before running it, so this script can never clear state it wrote. That is why the rows feed nothing to the main bar: an `agents` segment sourced from here would stay stale forever after the last agent exits.
- **The registration is read at Claude Code startup.** `cs -statusline enable` registers `subagentStatusLine` alongside `statusLine`, and Claude Code must be restarted before a new registration takes effect; a mid-session edit is silently ignored.

Failure posture matches the bar: fail-open, always exit 0, print nothing rather than something wrong. Claude Code kills the command at 5 seconds; the hot path is one `jq` pass over stdin and one `jq -c` per row — no git, no network, no file reads. `CS_SUBAGENT_STATUSLINE_DISABLE=1` silences the rows without touching the bar.

`bin/cs-subagent-statusline` sources `bin/cs-statusline` in library mode (`CS_STATUSLINE_LIB=1`) for the color ladder, palette, and width measurement — the alternative was a third hand-synced copy of the palette, which would rot — so it must sit beside `cs-statusline`; `install.sh` installs both into the same directory.

## Terminal theme

cs detects the terminal's light/dark theme once at session launch, while it still owns the tty: an OSC 11 background query classified by BT.709 luminance first, falling back to `COLORFGBG` when the query gets no answer, then to OS appearance when neither says anything. The query outranks the variable because `COLORFGBG` goes stale across theme changes; OSC 11 asks the live terminal. Inside tmux `COLORFGBG` is a stale snapshot of the tmux server's start-time environment, so cs ignores it there. tmux that proxies OSC 11 forwards a plain query to the client terminal, so under `$TMUX` cs asks with a plain query first and takes any non-black answer as the real background; a pure-black reply is tmux's own default and is not trusted. When the plain query yields nothing trustworthy, cs retries wrapped for DCS passthrough (needs `allow-passthrough on`), then falls back to OS appearance (`defaults read -g AppleInterfaceStyle` on macOS; `unknown` elsewhere), which is right whenever the terminal theme follows the system. The launch detection sets the palette for cs's own UI and the TUI picker (exported as `CS_TERM_THEME`), and sets a `CS_TERM_THEME_AUTO` marker so the statusline knows the value came from auto-detection rather than an explicit pin. The status line never asks the operating system what the terminal looks like: the system's appearance says nothing about a terminal with a fixed scheme or one embedded in an app, which is where relying on it was reliably wrong. A terminal that can answer for itself does so through the rungs above; a terminal that cannot is taken to be dark, the assumption the rest of cs makes with nothing to go on. The cost is that a light terminal which reports nothing and was not launched by cs renders the dark palette — pin `CS_TERM_THEME=light` there. It cannot re-run the OSC query from a render, which would race its reply into claude's input stream. Setting `CS_TERM_THEME=light|dark` yourself is an explicit pin (no auto marker) that wins everywhere — use it when the terminal's theme is decoupled from the system. A session already open when the terminal switches keeps its launch palette until relaunched, on every platform: the rungs that could notice mid-session are the terminal's own answers, and a terminal that does not report its theme has none. On dark terminals the statusline lifts its neutral grey and softens white text; all other colors sit on their own capsule fill and are theme-independent. Run `cs -detect-theme` to see what launch detection yields.

A session cs did not launch carries none of that, so two further rungs sit above the OS appearance and describe the terminal rather than the system. Outside tmux the statusline reads `COLORFGBG`, the terminal's own statement about itself; inside tmux it ignores it for the same reason the launch detector does — there it is the server's start-time snapshot and goes stale across theme changes. Inside tmux it instead asks the server for the attached client's reported theme (`#{client_theme}`), which is live and describes the client, but which only terminals that report their theme populate at all; when it is empty the ladder falls through. Neither rung reaches a terminal that is inside tmux and reports nothing, and for that combination no passive per-render signal exists.


`TMUX` is ordinary environment and is inherited wholesale, so a program launched from a tmux pane passes it to everything it spawns — including a window it opens in a terminal of its own. That child claims a tmux membership it does not have, and every rung keyed off `TMUX` then reads the wrong terminal: the client rung asks a client that is not ours, and `COLORFGBG` is skipped to avoid a staleness that does not apply. The second field of `TMUX` is the tmux server pid, which is the one part of the claim that can be checked rather than believed — a process in a real pane has that server among its ancestors. The statusline walks its own ancestry once per render (a single `ps`, only when `TMUX` is set) and, when the server is absent, treats the whole inherited terminal description as describing somewhere else: it takes dark rather than the inherited `CS_TERM_THEME`, drops `CS_TERM_BG_RGB` so the capsule surface does not shade toward another terminal's background, and hides the [pane segment](#segments) rather than print a pane id belonging to someone else's session. An explicit `CS_TERM_THEME` pin still wins over all of this. Observed with terminal-embedding apps that shell out before opening their own window, where the symptom is a light bar on a dark window.

Every signal above describes the terminal cs was launched from, which is the wrong terminal once a tmux session is re-attached from a different one — the palette then tracks the window cs started in rather than the window you are looking at, until the session is relaunched. Measuring again on attach needs a query the statusline cannot safely make from a render, and the attempts to make it from elsewhere each traded one fault for another; the reliable fix is for the host to report the theme it has already resolved.

Only the OSC 11 path ever learns the terminal's actual background RGB — the `COLORFGBG`/OS-appearance fallbacks classify light or dark without it. When OSC 11 succeeds, cs exports that RGB as `CS_TERM_BG_RGB` (e.g. `250;248;242`) alongside `CS_TERM_THEME_AUTO`, which is what shades the capsule surface. When it is absent, cs first tries to find the measurement anyway: launch writes it to `~/.cache/cs/term/<key>`, keyed by the tmux client tty (cs's own tty outside tmux), and a render with no `CS_TERM_*` asks tmux which client its pane is on and reads it back. That is what lets a pane cs never launched — an agent-teams teammate is spawned straight off the tmux server and inherits nothing — draw the same bar as every other pane on that terminal. The key is the terminal's identity, so re-attaching from a different terminal misses rather than returning a stale answer. tty names are recycled by the OS, though, so the key alone is not enough: entries also expire, and one older than twelve hours is refused rather than trusted. The entry is `theme rgb epoch` (rgb as `-` when there is none), the epoch being what the render ages it by; an entry without one, from an older cs, is refused the same way until the next launch rewrites it.

When even that misses, the capsule surface falls back to a fixed warm taupe instead of a derived shade — lighter on a dark terminal, deeper on a light one. Deriving an exact shade of the measured background needs truecolor's per-channel precision; classifying light or dark for the taupe fallback does not. Inside tmux the host mutes a truecolor status line to a fallback palette unless `CLAUDE_CODE_TMUX_TRUECOLOR` is set. cs exports it at launch for the claude it starts, and publishes it into the tmux session that launch runs in (`tmux set-environment`), so every pane opened in that tmux session afterwards, an agent-team teammate claude splits off included, inherits it; a pane in a tmux session no cs launch has run in renders that same taupe fallback in 256-color rather than the derived shade.

`CS_TERM_BG_RGB` stays at its launch value for the life of the session, so a terminal that changes background mid-session keeps deriving its capsule surface from the old one. Set it yourself to override.

### Pinning the background

A measured background always outranks the assumption, and supplying one by hand is how the capsule surface becomes an exact shade of your terminal rather than a shade of the theme's guess. Export it in the shell that terminal starts:

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

# Force the Powerline rounded caps (U+E0B6/U+E0B4) on (1) or off (0),
# overriding this machine's recorded answer in ~/.config/cs/statusline-caps
export CS_STATUSLINE_CAPS="0"

# Context thresholds (percent)
export CS_STATUSLINE_CTX_WARN=40
export CS_STATUSLINE_CTX_CRIT=65

# Where the machine-global usage cache lives (default $CS_SESSIONS_ROOT/.usage)
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the fable capsule from cache only, never kicking a refresh
export CS_USAGE_NO_REFRESH=1

# Set by a wrapper Claude Code runs in place of cs-statusline (a status-line
# bridge that is a new process each tick): the pid the wrapper is the child
# of, so the per-conversation caches key on Claude Code rather than the
# wrapper. Never set it in a shell profile.
export CS_STATUSLINE_PARENT="$PPID"

# Plain text, no colors
export NO_COLOR=1
```

`CS_SESSIONS_ROOT` is honored the same way the rest of cs honors it.

## Install, uninstall, doctor

`install.sh` deploys the `cs-statusline` and `cs-subagent-statusline` binaries to `~/.local/bin` unconditionally, but the status bar itself is claimed only with consent: with a terminal attached the installer renders a sample of the bar (a fixed payload, pinned to the segments that need no live session, in the terminal's theme where it publishes one) and then asks before registering (default yes; it also asks before replacing an existing status line), and a non-interactive install registers nothing and prints how to enable later. Consent registers both keys — the bar and the [subagent rows](#subagent-rows) — exactly as `cs -statusline enable` does.

A "no" is remembered in `~/.config/cs/statusline-declined` (under `$XDG_CONFIG_HOME` when set), so `cs -update` — which re-runs the installer — stops asking on every release and prints one line saying how to enable instead. `cs -statusline disable` writes the same marker; `cs -statusline enable` clears it, and `cs -uninstall` removes it. Turn both on or off any time:

```bash
cs -statusline enable    # register bar + subagent rows (overwrites the current status line; the command is your consent)
cs -statusline disable   # remove both registrations, each only if it points at the cs binary
```

Claude Code reads both registrations at startup, so `enable` takes effect after the next restart — the command says so when it runs.

`cs -uninstall` removes both binaries and strips the `statusLine` and `subagentStatusLine` registrations only when they point at the cs binaries; a status line or row renderer you configured yourself is left untouched.

`cs -doctor` includes a Statusline check and a parallel Subagent statusline check: OK when registered and executable, FAIL when a registration points at a missing binary. The Statusline check WARNs when cs-statusline is absent — unregistered, or a status line of your own — because it is the only writer of `.cs/local/context-pct`, and without that file the rotation nudge and the queue's context circuit breaker both go silently inert. The status line itself stays optional; the warning is about the gating that depends on it.

## Design notes

The design came out of a source study of [claude-powerline](https://github.com/Owloops/claude-powerline) (techniques: the single-call git query, the color-support ladder, per-segment gating of all I/O) and of oh-my-claudecode's HUD as a counterexample (its per-render transcript parsing, unconditional state reads, and multi-line output are the failure modes this script is shaped against). Claude Code delivers everything else needed (session name, context %, rate limits, model, cost) directly in the status-line stdin JSON, which is why the hot path needs no other data source.
