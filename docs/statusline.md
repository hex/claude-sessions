# Status line

`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one line: by default the [quiet layout](#quiet-layout), the items as text on the terminal's own background; with `CS_STATUSLINE_LAYOUT=band`, the [band](#band-layout), a full-width row fading from the session's color into the terminal; with `CS_STATUSLINE_LAYOUT=capsules`, the rounded capsules on the terminal's own background described next.

```
✳ claude-sessions  ·  ⎇ main↑1 +2!1  ·  ✦ Fable 5.1 medium  ◑ ctx 42%  ◷ 5h 31% ⋮ ◶ wk 84% · 5d16h
```

One capsule carries identity — the Claude mark, the session, the branch, the model — and one carries the context gauge. The quota capsule (5h, joined by a vertical ellipsis to wk once wk reaches 50) is always there; the Fable window gets its own capsule at 50. Colour is state: bold amber ink on a number past its warn threshold, and the capsule inverts to red at crit, its text white on the red. The plain form (`NO_COLOR=1`) is `claude-sessions · ⎇ main↑1 +2!1 · ✦ Fable 5.1 medium > ◑ ctx 42% > ◷ 5h 31% ⋮ ◶ wk 84% · 5d16h`.

The capsules are one of three layouts. The default, the [quiet layout](#quiet-layout), draws the same items as text on the terminal background, and the [band](#band-layout) draws them on one full-width row that fades from the session's color into the terminal background. The segment table below holds for all three.

## Segments

Default order: `logo,session,notes,mail,git,model,ctx,limits`. One capsule holds identity (which session, which branch, which model); one holds the context gauge; one quota capsule always follows, holding 5h and, from 50, wk after a vertical ellipsis; on a Fable session the model window gets its own capsule from 50. `pane` and `fable` ship but leave the default order — name them in `CS_STATUSLINE_SEGMENTS` to show them. The `cost` segment ships too, off by default the same way.

| Name | Group | Rest | Hot | Hidden when | Source |
|---|---|---|---|---|---|
| `logo` | identity | `✳` in brand coral, bold; brandshade while `.cs/local/attention` exists | — | plain mode (no colour) | `.cs/local/attention` marker (raised by the Stop hook, cleared on the next prompt or session start) |
| `session` | identity | name, bold, primary ink | — | never | stdin `session_name`, falling back to `CLAUDE_SESSION_NAME`, then the workspace dir basename ; a session whose `.cs/README.md` frontmatter tags include `encrypted` gets a lock after the name (U+F023, secondary ink) once `cs -statusline caps` answered yes, `enc` until then |
| `notes` | identity | `▤ N`, the queue count, amber ink, regular, directly after the session | — | queue empty or absent | Task files in `.cs/local/queue/` (one file per task; `.cs/private/queue/` in an [encrypted session](session-layout.md#encrypted-sessions)) |
| `mail` | identity | `✉ N`, amber ink, regular, after notes | — | nothing unread | Count of `.cs/local/mail/new/*.json` documents (`.cs/private/mail/` in an encrypted session; `cs -msg` moves what it prints to `cur/`); only `.json` files count, so a stray `.DS_Store` or staging leftover never shows a phantom unread |
| `pane` | identity | `◫ 7` (the `%` dropped), secondary ink; only when named | — | not named, or outside a real tmux | `TMUX_PANE` from inherited environment (no fork); requires `TMUX` too, and that this process is genuinely inside that tmux server, so an inherited pane id never renders |
| `git` | identity | branch with the arrows and `+N!N` marks, bold ink | — | no `.git` here or above | One `git status --porcelain=v1 -b` call |
| `model` | identity | display name in bold ink; the effort word, regular weight, in Claude Code's own `/effort` colour for its level (low gold, medium green, high blue, xhigh violet, max a blue-to-pink gradient across its letters) | — | no model on stdin | stdin `model.display_name`, `effort.level` |
| `ctx` | ctx | `◔ ctx N%`, secondary ink; the pie fills with the band: `○` below 13, `◔` to warn, `◑` through amber, `◕` at crit, `●` from 88 | amber ink on the number at 40; crit inversion at 65 (`CS_STATUSLINE_CTX_WARN`/`_CRIT`; the half and three-quarter steps follow them) | no `context_window` on stdin | stdin `context_window.used_percentage` |
| `limits` | limits | `◷ 5h N%` | the quota capsule `5h N% ⋮ wk N%` (5h always, wk from 50, joined by a vertical ellipsis) and a separate `fable N%` capsule from 50 on a Fable session: `5h N% · 2h14m`, `wk N% · 5d16h`, `fable N% · 18h`; neutral below 70, amber ink at 70, crit inversion at 90; the countdown joins 5h at 70 and the coarse windows at 80 | wk and fable below 50 | stdin `rate_limits.*.used_percentage`, `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at`, plus the usage cache when the model is Fable |
| `fable` | limits | accepted as a name: the Fable window alone when `limits` is not named; a no-op beside `limits` | — | below 50, like wk | `GET /api/oauth/usage`, cached machine-globally (see [Fable usage](#fable-usage)) |
| `cost` | cost | `$N.NN`, secondary ink, its own capsule after limits; only when named | — | not named, or no cost on stdin | stdin `cost.total_cost_usd` |

Every segment is null-when-nothing: missing data means the segment and its separator simply do not render. Outside a cs session, `session` falls back to the directory name. `pane`, `fable` and `cost` ship but stay off the default order — name them in `CS_STATUSLINE_SEGMENTS` to turn them on.

The limits group folds the three windows into one rule. The Fable window is model-scoped and lives only in the usage cache (see [Fable usage](#fable-usage)); it joins the candidate list only on a Fable session, and its refresh kick keeps its existing gate: the cache is read and the refresher detached whether or not the capsule ends up shown, so a hidden Fable window is still polled at its 600-second floor. The countdown appears once a window is tight: for 5h at 70 and up (the 5h window itself is always shown), for wk and fable at 80 and up.

The two files the render writes, `.cs/local/context-pct` and `.cs/local/limits`, are produced in `_parse_stdin` before any segment runs and stay untouched by the gating above. Hiding a capsule never hides a heartbeat.

Segment icons are standard Unicode glyphs (the context pie `○ ◔ ◑ ◕ ●`, star `✦`, branch `⎇`, clock `◷`, week `◶`, open star `✧`, pane `◫`, envelope `✉`) from the Geometric Shapes and dingbat ranges, so they render in any monospace font without a patched Nerd Font. The `session` segment carries no icon — the capsule and its position are the identity. The capsule caps (U+E0B6, U+E0B4) are the one private-use exception, so they are drawn only once this machine has answered the installer's question about them (see [Colors](#colors)).

## Data sources and performance

The render's cost is its fork count. The bar repaints on Claude Code's events and once a minute while idle, from the `refreshInterval: 60` that cs registers; at one second, Claude Code 2.1.286 stops a render still running when the next one is due and runs `ps -A` twice to stop it, so on a loaded machine, where a render can take longer than a second, the bar stays blank and each session runs about two `ps -A` a second. On a loaded machine every external command costs what the scheduler charges (measured at 0.3 s per fork at load 25); a render that forks a dozen commands runs past the limit Claude Code gives a status line and the tick is killed. So a warm render runs one program: a single `jq` pass over stdin (a bash without a builtin clock, macOS's stock 3.2, adds one `date`). The count an endpoint agent charges for is a little higher than that, because a command substitution is itself a process: measured on a quiet machine, three per warm render on bash 5 (this script, the substitution's shell, `jq`) and five on 3.2. Everything else the render needs is a builtin read of a small file, and every other fork sits behind a cache or a cadence:

| Fork | Kept | Where | Comes back |
|------|------|-------|-----------|
| `git status` (the `git` segment) | 5 s | `~/.cache/cs/git/` | the first render after five seconds, so a branch switch or a dirty file shows at the next repaint after that, within a minute while idle |
| `ps` + `awk`, the tmux ancestry walk (is this process really in the tmux server `TMUX` names) | 5 min | `~/.cache/cs/tmux-real/`, by parent pid and `TMUX` | once per conversation, and never on the render path: the parent (Claude Code) is the same for every render, and a process that only inherited `TMUX` has a different parent, so it cannot inherit the verdict. On a miss the render answers real and a detached child does the walk, keyed on the same parent, so the next render reads a settled verdict; a `ps` that cannot answer is never cached, and the render after it spawns another child. A wrapper Claude Code runs in place of the script (a status-line bridge, a new process each tick) sets `CS_STATUSLINE_PARENT` to the pid it is itself the child of, and both parent-keyed caches key on that |
| `tmux display-message`, the attached client's theme, tty, control mode and terminal type, and this pane's width | 5 s | `~/.cache/cs/tmux-client3/`, by parent pid and `TMUX` | asked once per theme pass, all five fields from one query (`-t "$TMUX_PANE"` when set), and again by the first render after five seconds; a theme toggle or a re-attach from another terminal shows at the next repaint after that, within a minute while idle. The [band layout](#band-layout) reads the width from the same answer |
| `PlistBuddy`, the background colours of the iTerm2 profile, and an `awk` over the colors (in iTerm2 only, see [Terminal theme](#terminal-theme)) | 60 s | `~/.cache/cs/iterm-profile/`, by profile name | on a miss, one run per eight profile names until the profile turns up, one for its name and separate-colors flag and one for its color components. The cache keeps a profile it cannot read as `none`, so the render does not ask again until the entry expires |
| `defaults read -g AppleInterfaceStyle`, the macOS appearance (only for an iTerm2 profile with separate light and dark colours) | 5 s | `~/.cache/cs/macos-appearance/` | the first render after five seconds, so a dark-mode switch shows at the next repaint after that, within a minute while idle |
| `stty size </dev/tty`, the terminal's width (band layout only, outside a real tmux, with no width on stdin or in `CS_STATUSLINE_COLS`) | 5 min | `~/.cache/cs/stty/`, by parent pid | once per conversation; the cache keeps an empty answer (no terminal) too, so a render with no terminal does not ask again until the entry expires |
| `tty`, this render's own terminal device (the key of the measured background outside tmux) | 5 min | `~/.cache/cs/tty/`, by parent pid | once per conversation, and only on a render outside tmux that reaches the measured-background rung (see [Terminal theme](#terminal-theme)); under Claude Code stdin is the JSON pipe, so the answer is empty, and only a render started from a shell gets a device |
| `jq --stream` over Claude Code's `.claude.json` for the account id (Fable sessions) | 5 min | `~/.cache/cs/org/`, by config path | an account swap shows within five minutes, or six while idle; the refresher, which attributes a reading and detects a swap across its own fetch, always reads the config itself and renews the entry |
| `jq` over the Fable usage record, and `date` for its reset countdown | with the record | `fable.<account>.json.fields` beside it: pct, resets_at, fetched_at, next_poll_at, and the reset as an epoch, one per line | written by the refresher with the JSON, never by a render, so a slow parse of an old record cannot overwrite a newer sidecar; the refresher honours the JSON's schedule (so a recorded backoff is never skipped) and rewrites a sidecar that disagrees with it from the JSON, without a fetch; a record with no sidecar (from before it existed) is parsed with `jq` until the next refresh |
| `mv` for the `.cs/local/context-pct` and `.cs/local/limits` stamps | 60 s when the value is unchanged | `<stamp>.at` beside each, `epoch value`; a teammate's heartbeat touch keeps its own | a changed value is written at once; an unchanged one once a minute, which is the heartbeat (its readers allow 900 s for the mtime and 1800 s for `stamped_at`) |

The parent-keyed buckets (`tmux-real/`, `tmux-client3/`, `tmux-walking/`, `tty/` and `stty/`, plus `tmux-client/` and `tmux-client2/`, the two- and three-field forms cs no longer writes) gain an entry per conversation, so the usage refresher (see [Fable usage](#fable-usage)), which already runs detached and under its own lock, removes their entries older than an hour. An hour is far past every one of their TTLs (5 s, 10 s and 5 min), so a removed entry was already a miss and a conversation that needs it again recomputes it. The sweep runs only where the refresher does (a Fable session with `curl`), and the render never sweeps.

A cache entry is two lines: `epoch<TAB>identity`, then the text. The identity is the raw value the file name was made from (the workspace path, the config path, `<parent pid>,<TMUX>`), so two values that sanitise to the same name (`/x/a/b` and `/x/a-b`) never answer for each other, and the age is arithmetic against the render's one clock rather than a `find` or `stat` fork; the terminal-theme entry under `~/.cache/cs/term/` (see [Colors](#colors)) carries an epoch too. Every cache write is a builtin `printf`, and a read takes an entry only when both its lines are complete, so a torn read is a miss, never a wrong answer. Data gathering is still gated per segment: disabling `git` in `CS_STATUSLINE_SEGMENTS` means the git line is neither forked for nor cached. There is no transcript parsing and no network access; a Fable session reads the usage cache and never fetches from the render (see [Fable usage](#fable-usage)).

The writes in the render path are machine-local and best-effort: the render stamps the current context-window usage, truncated to an integer, to `.cs/local/context-pct`; the value is written only by the conversation whose id `.cs/local/state` records as launched, and any other conversation in the directory (a tmux teammate) touches the file instead, keeping the liveness heartbeat alive without replacing the lead's reading. The task-queue gate (the `narrative-reminder.sh` Stop hook, see [hooks.md](hooks.md)) reads this file to decide whether to suggest compacting before a walk-away drain. Skipped outside a cs session or when the stdin JSON carries no context percentage.

The same render also stamps `.cs/local/limits` (5-hour and weekly used percentages and reset epochs) so `cs -usage` can anchor its windows at the true reset boundaries; both files are machine-local and best-effort.

Neither stamp builds a session: the render makes only the last level, `.cs/local`, and only inside a `.cs` that exists, so a render for a session `cs -rm` removed creates nothing. Both stamps also stand down while git tracks a file in the session's control directory (see [hooks.md](hooks.md#how-a-hook-finds-its-session-cs-resolvesh)). A render cannot afford to ask git, so it reads the answer each hook run leaves in `~/.cache/cs/tracked/<session name>` and writes neither file while that mark exists. It reads the mark only for a name the hooks would write one for: not empty, holding no `/`, with `HOME` set.

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

The Fable bucket is the first entry in the response's `limits[]` array whose
`scope.model.display_name` starts with `fable`, case-insensitively. The unified
windows ride in that same array with a null model scope, which is why the filter
keys on the display name rather than on position. Its `percent` is already 0–100 on the wire, and its
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
session. The render reads the record's fields from a `.fields` file the
refresher writes beside the cache, with shell builtins and no `jq`; only a
record without that file is parsed with `jq`, until the next refresh writes one.
The account id comes from a 300-second cache of Claude Code's config, and only
a miss reads the config itself, in one `jq --stream` pass. When the usage cache
is due, the render detaches
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
ten and capped at an hour — a 429 does not reliably clear at its stated
horizon, and a header of more than fifteen digits takes the floor.

Polling happens only while the active model is Fable, because the trigger lives
inside the segment and the segment is gated on the model. A session on any other
model costs the budget nothing.

### When the Fable capsule does not render

The capsule is null-when-nothing, and deliberately strict about it: usage below 50%, no cache, no
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

The git call runs with `GIT_OPTIONAL_LOCKS=0` (no index locking for a read-only query) under a 2-second timeout, and is skipped entirely when neither the workspace nor any directory above it holds a `.git`. The workspace is Claude Code's `workspace.current_dir`, which follows the Bash tool's working directory: a `cd` into a subdirectory of the checkout keeps the branch, since the segment climbs to the nearest `.git` (a directory, or the file a worktree keeps) and caches under that checkout. In a session adopted with `cs -adopt`, or a `<base>@<feature>` worktree, that is the checkout itself, so the branch shown is the project's. The same climb means a session directory without a `.git` of its own, under a sessions root that is itself a git checkout, shows that root's branch and dirty counts. A plain session directory is its own one-commit repo on `main`, and a bar reading `main !2` there is that repo and its dirty `.cs` files, not some project the conversation happens to discuss; adopt the project to see its branch.

Failure posture is fail-open: malformed stdin, a missing `jq`, or any internal error degrades to a plain directory-name line and exit 0. A broken status line never breaks the prompt.

## Colors

Color depth is detected per render, in priority order: `FORCE_COLOR=0`, `NO_COLOR`, or `TERM=dumb` force plain text (segments joined with ` > `, no escape codes); inside a real tmux (not an inherited `TMUX`) without `CLAUDE_CODE_TMUX_TRUECOLOR`, the level is 256-color, since the host would quantise truecolor output anyway; otherwise `COLORTERM=truecolor`/`24bit` or iTerm2/WezTerm select truecolor; a `*256color*` `TERM` selects 256-color; anything else gets basic ANSI.

| Token | Role | Truecolor | 256 | Basic |
|---|---|---|---|---|
| `surface` | every capsule fill | `CS_TERM_BG_RGB` shaded 10% (`_bg_shade`); assumes dark `28;28;28` / light `255;255;255` when unmeasured | 254/237 | 90 |
| `ink` | primary text | a 35% shade of the surface on a light surface, `white` on a dark one | 236/255 | 97 |
| `ink2` | secondary text, dots, gauge labels | a 55% shade of the surface (lifted toward white on a dark surface), like `ink` | 241/250 | 37/97 |
| `brand` | the mark | `217;119;87` | 173 | 33 |
| `brandshade` | the mark while the attention marker exists | `184;101;74` | 167 | 31 |
| `periwinkle` | the subagent rows' model capsule | light: `76;29;149`; dark: `196;181;253` | 55/147 | 35/95 |
| `amber` | hot numbers, notes and mail counts | light: `180;83;9`; dark: `251;191;36` — light/dark by the measured `CS_TERM_BG_RGB`, by theme only when unmeasured | 130/214 | 33/93 |
| `crit` | inverted capsule fill | light: `215;0;21`; dark: `255;69;58` | 160/203 | 31 |
| `critink` | inverted capsule text | `255;255;255` on both themes | 231 | 97 |
| `effort-*` | the effort word | Claude Code's /effort picker colours, pixel-sampled; lifted a third toward white on dark; `effort-max-1..3` are the gradient stops | 136/179, 28/71, 63/105, 93/135, 110·140·175 / 153·183·218 | 33, 32, 34, 35, 36·35·95 |

Every capsule fill is `surface`, a shade of the terminal's own background so the bar harmonizes with the terminal instead of sitting on a fixed grey; darker on a light terminal, lighter on a dark one. On a cream terminal (`253;246;227`) the derived surface comes out `227;221;204`, a warm off-white a few shades darker — so the values above are the fallback for an unmeasured background and a reference for what the derived shade lands near, not fixed paints.

`amber` is ink, painted straight onto the capsule surface rather than as a fill of its own — a fill chosen for black text on it fails contrast once it is the text color instead, which is why hot numbers use this separate ink token. The session palette (`red`, `blue`, … `orange`) stays in `_sgr` untouched: it is Claude Code's shared eight-color session palette, KEEP IN SYNC with `_session_color_rgb` in `bin/cs` (the session pill). The bar itself never paints with it: the session name is `ink` like the branch and the model. `crit` is its own token so the gauge's red never depends on that palette's `red`. The reset countdown shares the number's ink: it is part of the same reading.

Removed from the bar: `hairline`, `chiptext` (the mark uses `brand` instead), `black`, and `amber` as a fill. `periwinkle` stays for the [subagent rows'](#subagent-rows) model capsule. Those rows otherwise paint with `rowname`, `rowmeta`, `amber` and `crit` through `_paint` → `_sgr`, the same `amber`/`crit` tokens the bar uses, so a row's hot ctx and the bar always agree on the two hot colors.

Capsule ends are the Powerline glyphs U+E0B6 and U+E0B4, drawn as fill-colored ink on the terminal's default background so they read as rounded ends. They need a font that carries them (any Nerd Font does), and a font without them shows a box at every capsule edge. A terminal cannot be asked whether it has a glyph, so cs asks you: the installer shows a sample capsule and asks whether its ends look rounded, and records the answer per machine in `~/.config/cs/statusline-caps` (`on` or `off`). Until a machine has answered, the capsules are square chips with the same spacing. `cs -statusline caps on|off|ask` rewrites the answer, `cs -doctor` reports it, and `CS_STATUSLINE_CAPS=1` or `=0` in the environment overrides the file either way. Caps render at every color level — the cap's ink is the capsule's fill, which 256-color and basic terminals both have — and never in plain mode.

Inside tmux, Claude Code mutes its own branding and any truecolor status line to a fallback palette. cs sets `CLAUDE_CODE_TMUX_TRUECOLOR=1` in claude's environment at launch (unless you set it yourself) to keep these colors at full saturation, and inside tmux publishes the same value into the session's environment so teammate panes claude opens get it as well.

## Quiet layout

The quiet layout is the default: an unset `CS_STATUSLINE_LAYOUT`, an empty value, `quiet` and any value other than `band` and `capsules` draw it. It draws the same items as the capsules as text on the terminal's own background, with no fill. It has no width, so `CS_STATUSLINE_COLS` and `CS_STATUSLINE_FRAME` do not apply to it.

```
 ✳ my-session   ·  ✦ Opus high  ·  ○ ctx 8%  ·  ◷ 5h 23%
```

The mark and the session name, with the lock of an encrypted session, sit in one chip with a fill space on each side. The [band's color rules](#band-layout) pick its color: `CS_STATUSLINE_BAND`, else the session's own color. The fill is that color seen through the terminal background, 35% of it on a dark terminal and 15% on a light one: session blue `106;155;204` fills `51;70;98` on a dark `21;24;40` and `230;232;223` on cream `253;246;227`. The session name is bold in a shade of the same color, 60% of the way to white on a dark terminal and halfway to black on a light one: `195;215;234` and `53;78;102` for blue. With no color the fill is the background lifted a step, `61;64;90` on the dark and `223;216;197` on cream, and the name is the terminal's own foreground. The mark is always Claude's coral `217;119;87`, bold, even while the attention marker shades it on the capsules.

After the chip the line falls into runs. A run starts at each new group and at each item that `  ·  ` joins. Labels, joiners and every other item without a role of its own, such as the model name and the branch's marks, take one fade ink per run. The first run is 35% of the way from the quiet ink to the terminal background, the last run 55%, and the runs between step evenly from one to the other. The quiet ink is `214;222;240` on a dark terminal and 24% of each background channel on a light one. With three runs on a dark `21;24;40` the fades are `147;153;170`, `128;133;150` and `108;114;130`; on cream `253;246;227` they are `127;124;114`, `146;143;131` and `166;161;149`. The background is the one the band fades into (see [Band layout](#band-layout)).

A reading (the ctx and quota percentages, the cost) is the terminal's own foreground (`39`), bold, in every run, so the numbers stay the easiest thing on the line to read and read on whatever background the terminal wears, whatever theme cs believes it has. An item in amber ink (a reading past its warn threshold, the notes and mail counts) is bold `amber`. A reading at crit and the label just before it in its group are one red chip, `critink` bold on `crit`, with a fill space on each side. The chip closes at the first item that is not part of it, so `wk` after a crit `5h` stays outside. A two-space joiner beside a red chip loses one space to the chip's fill space, so the dot between two crit groups is ` · `.

The model's glyph `✦` takes the color of the effort word after it, `effort-max-1` for `max`. The effort word keeps its own color. With no effort the glyph takes its run's fade, like the model name.

The branch is the terminal's own green (`32`), its glyph and its name, with the path before the last `/` in the same green faint (`2;32`), so `feat/` sits back and the branch's own name stands out. Its marks, the ahead and behind arrows (`↑1`) included, take its run's fade.

Below truecolor there is no fade and no session tint. The chip is a gray: on a dark terminal `241` with white `231` text at 256 colors, and bright black (100) with bright white (97) at basic; on a light terminal `253` at 256 colors and white (47) at basic, with the terminal's own foreground. At 256 colors labels and joiners are `ink2`. At basic, whose `ink` and `ink2` are white tokens made for the capsules' fill, they are bright black (90). Readings are the terminal's own foreground (39), bold, at every level, so they read on a light or a dark terminal. Plain mode (`NO_COLOR` and the rest) ignores the layout and prints the plain line the capsules print.

## Band layout

`CS_STATUSLINE_LAYOUT=band` draws the same items as the capsules on one full-width band instead. The band's fill fades, cell by cell, from the band color at the left edge to the terminal background at the right: a strip of the session's color that dissolves into the terminal. The band is opt-in: only `band` draws it, and an unset `CS_STATUSLINE_LAYOUT`, an empty value and any value other than `band` and `capsules` draw the [quiet layout](#quiet-layout).

```
 ✳ my-session  ·  ✦ Opus high  ·  ○ ctx 8%  ·  ◷ 5h 23%
```

Items start one cell in, after a cell of band. The joiners inside a group are the capsules' joiners (`  ·  `, ` ⋮ `, and blank fill for the others), and `  ·  ` joins one group to the next as well, since the band has no gaps between capsules. After the last item the fade runs on as blank cells to the band's last cell, which is exactly the terminal background. Items wider than the band are all printed, none cut, and Claude Code truncates the line.

Each render picks the band color, first match winning:

1. `CS_STATUSLINE_BAND`: a session-palette name (`red`, `blue`, `green`, `yellow`, `purple`, `orange`, `pink`, `cyan`), `brand`, `periwinkle`, an `r;g;b` triplet of 0-255 values, `session` (step 2), or `none` (step 3). Any other value is step 2, never an error on the bar.
2. The session's own color, `claude_session_color` in `.cs/local/state`, through the same palette the session pill uses.
3. A neutral: the terminal background lifted a step, `+40;+40;+50` on a dark terminal and `-30` a channel on a light one, held within 0-255.

A color from step 1 or 2 is then desaturated and pulled toward the background, so the band is a tint of the terminal and text reads on its first cells. Each channel moves halfway to the color's luminance, `(r×299 + g×587 + b×114) / 1000`, and then 78% of the way to the background. Session blue `106;155;204` starts the band at `224;224;215` on a cream `253;246;227` and at `44;52;70` on a dark `21;24;40`. The neutral of step 3 is already a step off the background, so the band starts at it unchanged: `223;216;197` on cream, `68;68;78` on a dark `28;28;28`. The background is the one read live from the iTerm2 profile (see [Terminal theme](#terminal-theme)), unless you set `CS_TERM_BG_RGB` yourself; then `CS_TERM_BG_RGB` when it parses; else the one the `surface` token assumes (dark `28;28;28`, light `255;255;255`).

It picks the band's width W the same way:

1. `CS_STATUSLINE_COLS`, a whole number from 1 to 9999, taken as the final width: a caller that sets it (a test, a wrapper that measured the frame itself) already knows the cells it may use, so no frame comes off it.
2. `.columns` in the stdin JSON, when the payload carries one (the agent-panel payload does; the status-line payload of Claude Code 2.1.310 does not, so this rung waits for a future one).
3. Inside a tmux this process is really in (the same verdict the pane id uses), the pane's width, `#{pane_width}` of `TMUX_PANE`. It rides on the theme pass's one `tmux display-message` query and its five-second cache.
4. The terminal's width from `stty size </dev/tty`, kept five minutes under the parent pid like the `tty` answer, so a resize shows when that entry expires.
5. 120.

A measured width (steps 2 to 5) loses the frame. Claude Code 2.1.310 draws the status line inside its prompt frame, two columns in on each side, and truncates past it with `…`. `CS_STATUSLINE_FRAME` (a whole number, default 4) sets the frame; with `statusLine.padding` set in Claude Code's settings, add twice the padding. The band is never narrower than 20 cells, `CS_STATUSLINE_COLS` included.

An item in amber ink (a reading past its warn threshold, the notes and mail counts) is `amber` text, bold on either theme, on the gradient, as on the capsules. A group at crit is a solid red island holding every item of the group and the joiners between them, in `critink` bold on `crit`, with a fill space on each side. The island has no gradient under it, and the fade resumes after it at the color its cell position gives.

On a dark terminal, primary text on the band (bold `ink`, and `white`) is `255;255;255`, regular `ink` is `214;222;240` and `ink2` (labels and joiners) is `150;165;200`. On a light one the three are dark shades of the band's color before its desaturation and pull: 34%, 44% and 56% of each channel, so session blue writes primary text in `36;52;69` and labels in `59;86;114`, and the cream neutral `223;216;197` gives `75;73;66` and `124;120;110`. A light band draws every item at regular weight, the mark included; the amber reading and the crit island stay bold. A dark band keeps bold items bold. The brand mark, the effort word, the session palette and `periwinkle` keep their own colors.

Below truecolor the band has no gradient. At 256 colors a flat `surface` fill runs across W cells (237 dark, 254 light), the inks and islands in their 256 tokens; at basic, the same with the basic tokens. Plain mode (`NO_COLOR` and the rest) ignores the layout and prints the plain line the capsules print.

A 200-column band renders in 20 to 30 ms on a Mac at load 15, the same as the capsules: starting bash and the one `jq` pass dominate, and the per-cell work is shell arithmetic. Width costs no fork on a warm render: the tmux width comes with the client query, and `stty` runs at most once in five minutes per conversation.

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

cs detects the terminal's light/dark theme once at session launch, while it still owns the tty: an OSC 11 background query classified by BT.709 luminance first, falling back to `COLORFGBG` when the query gets no answer, then to OS appearance when neither says anything. The query outranks the variable because `COLORFGBG` goes stale across theme changes; OSC 11 asks the live terminal. Inside tmux `COLORFGBG` is a stale snapshot of the tmux server's start-time environment, so cs ignores it there. tmux that proxies OSC 11 forwards a plain query to the client terminal, so under `$TMUX` cs asks with a plain query first and takes any non-black answer as the real background; a pure-black reply is tmux's own default and is not trusted. When the plain query yields nothing trustworthy, cs retries wrapped for DCS passthrough (needs `allow-passthrough on`), then falls back to OS appearance (`defaults read -g AppleInterfaceStyle` on macOS; `unknown` elsewhere), which is right whenever the terminal theme follows the system. The launch detection sets the palette for cs's own UI and the TUI picker (exported as `CS_TERM_THEME`), and sets a `CS_TERM_THEME_AUTO` marker so the statusline knows the value came from auto-detection rather than an explicit pin. The status line asks the operating system what the terminal looks like only where the terminal's own settings say it follows the system (an iTerm2 profile, below): the system's appearance says nothing about a terminal with a fixed scheme or one embedded in an app, which is where relying on it was reliably wrong. A terminal that can answer for itself does so through the rungs above; a terminal that cannot is taken to be dark, the assumption the rest of cs makes with nothing to go on. The cost is that a light terminal which reports nothing and was not launched by cs renders the dark palette — pin `CS_TERM_THEME=light` there. It cannot re-run the OSC query from a render, which would race its reply into claude's input stream. Setting `CS_TERM_THEME=light|dark` yourself is an explicit pin (no auto marker) that wins everywhere — use it when the terminal's theme is decoupled from the system. A session already open when the terminal switches keeps its launch palette until relaunched, unless one of the rungs below notices: they are the terminal's own answers and iTerm2's settings, and a terminal that offers neither has none. On dark terminals the statusline lifts its neutral grey and softens white text; all other colors sit on their own capsule fill and are theme-independent. Run `cs -detect-theme` to see what launch detection yields.

A session cs did not launch carries none of that, and the theme of one it did launch goes stale, so the statusline makes four checks of its own, in order, before it falls back to the `CS_TERM_THEME` a launch exported and then to dark. The last reads back the background cs measured at launch for this terminal, described further down. The first and third describe the terminal rather than the system. Inside tmux the statusline asks the server for the attached client's reported theme (`#{client_theme}`), which is live and describes the client, but which only terminals that report their theme populate at all; when it is empty the ladder falls through. Outside tmux it reads `COLORFGBG`, the terminal's own statement about itself; inside tmux it ignores it for the same reason the launch detector does — there it is the server's start-time snapshot and goes stale across theme changes. Apart from iTerm2, no rung reaches a terminal that is inside tmux and reports nothing, and for that combination no passive per-render signal exists.

The second check reads iTerm2's own settings. It runs when `TERM_PROGRAM` is `iTerm.app` or `LC_TERMINAL` is `iTerm2`, `ITERM_PROFILE` names the pane's profile, the session is not over ssh (`SSH_CONNECTION` unset, since the preferences on disk would be another machine's) and `CS_NO_ITERM2` is unset. Inside tmux, `ITERM_PROFILE` and `LC_TERMINAL` describe the terminal that started the pane, and the client attached now may be another terminal, so the check also needs that client to be iTerm2: in control mode (iTerm2's tmux integration, `#{client_control_mode}`) or of a terminal type tmux reports as iTerm2 (`#{client_termtype}`). It reads that profile from `~/Library/Preferences/com.googlecode.iterm2.plist` with `PlistBuddy`. A profile with *Use Separate Colors for Light and Dark Mode* follows macOS, so the status line asks for the appearance (`defaults read -g AppleInterfaceStyle`) and takes that theme with the profile's background for it. Any other profile is dark when its one background's luminance is below 128 and light otherwise. iTerm2 reports no theme through tmux, so inside tmux only this check follows a dark-mode switch. The status line reads the profile at most once a minute and the appearance at most every five seconds, so a switch shows at the first repaint once the appearance's five seconds are up. The background read this way is the one the quiet chip and the band blend with, ahead of `CS_TERM_BG_RGB` unless you set that yourself. The check cannot see iTerm2's own theme setting: with it pinned to Light or Dark, a profile with separate colors still follows macOS here. A profile missing from the preferences, or one whose colors the status line cannot read, falls through to the next check, and so does one listed after a profile with no name, since that shifts the names from their places.


`TMUX` is ordinary environment and is inherited wholesale, so a program launched from a tmux pane passes it to everything it spawns — including a window it opens in a terminal of its own. That child claims a tmux membership it does not have, and every rung keyed off `TMUX` then reads the wrong terminal: the client rung asks a client that is not ours, and `COLORFGBG` is skipped to avoid a staleness that does not apply. The second field of `TMUX` is the tmux server pid, which is the one part of the claim that can be checked rather than believed — a process in a real pane has that server among its ancestors. The statusline walks its ancestry once per conversation (a single `ps`, only when `TMUX` is set) and, when the server is absent, treats the whole inherited terminal description as describing somewhere else: it takes dark rather than the inherited `CS_TERM_THEME`, drops `CS_TERM_BG_RGB` so the capsule surface does not shade toward another terminal's background, and hides the [pane segment](#segments) rather than print a pane id belonging to someone else's session. An explicit `CS_TERM_THEME` pin still wins over all of this. Observed with terminal-embedding apps that shell out before opening their own window, where the symptom is a light bar on a dark window.

The walk itself is kept off the render that pays for it. It is the one cost a render meets exactly once — it appears in a conversation's first render and in none after — and the first render is the one Claude Code kills for running too long, which starts the retry loop that leaves the bar blank. So the first render answers real, what every pane cs launches is, and spawns a detached child to walk the tree and leave the verdict for the next render. A foreign environment therefore draws its own terminal's palette for one render, up to a minute while idle, and is corrected on the one after; a real pane never sees a wrong palette at all. The child walks from the parent rather than from the render, which has exited by then, and the parent's chain to the server is the render's chain without its first hop.

One walk runs at a time. A `ps` that stalls never writes a verdict, so without a guard every render would spawn another walker against it — on every render, per conversation, for as long as the session stays open. The render that spawns a walk marks it in flight under the same parent identity (`~/.cache/cs/tmux-walking/`, ten seconds), and a render that finds a fresh mark draws without spawning. Past the ten seconds one render tries again, so a child that died before clearing its mark wedges nothing. The walker bounds itself as well: it waits five seconds of wall time on its `ps` (one `sleep` in a watchdog, which load cannot stretch the way it stretched a count of short sleeps), shorter than the mark, and kills it by the pid recorded at its start, so a stalled walker has ended before a replacement can be spawned. A killed walk is a `ps` that could not answer, and leaves no verdict. The usage refresher (`--refresh-usage`) skips the terminal altogether — it draws nothing, so it runs no walk, reads no theme and asks tmux nothing. The mark costs one file write on a cache miss and nothing on a hit, and never a fork; the child clears it, and the usage refresher sweeps the bucket with the other parent-keyed ones.

Every signal above describes the terminal cs was launched from, which is the wrong terminal once a tmux session is re-attached from a different one — the palette then tracks the window cs started in rather than the window you are looking at, until the session is relaunched. Measuring again on attach needs a query the statusline cannot safely make from a render, and the attempts to make it from elsewhere each traded one fault for another; the reliable fix is for the host to report the theme it has already resolved.

Only the OSC 11 path ever learns the terminal's actual background RGB — the `COLORFGBG`/OS-appearance fallbacks classify light or dark without it. When OSC 11 succeeds, cs exports that RGB as `CS_TERM_BG_RGB` (e.g. `250;248;242`) alongside `CS_TERM_THEME_AUTO`, which is what shades the capsule surface. When it is absent, cs first tries to find the measurement anyway: launch writes it to `~/.cache/cs/term/<key>`, keyed by the tmux client tty (cs's own tty outside tmux), and a render with no `CS_TERM_*` asks tmux which client its pane is on and reads it back. That is what lets a pane cs never launched — an agent-teams teammate is spawned straight off the tmux server and inherits nothing — draw the same bar as every other pane on that terminal. The key is the terminal's identity, so re-attaching from a different terminal misses rather than returning a stale answer. tty names are recycled by the OS, though, so the key alone is not enough: entries also expire, and one older than twelve hours is refused rather than trusted. The entry is `theme rgb epoch` (rgb as `-` when there is none), the epoch being what the render ages it by; an entry without one, from an older cs, is refused the same way until the next launch rewrites it.

When even that misses, the capsule surface shades an assumed background by 10%: dark `28;28;28` becomes `50;50;50`, light `255;255;255` becomes `229;229;229`. Shading a measured or assumed RGB needs truecolor's per-channel precision; classifying light or dark for the fixed fallback palette does not. Inside tmux the host mutes a truecolor status line to a fallback palette unless `CLAUDE_CODE_TMUX_TRUECOLOR` is set. cs exports it at launch for the claude it starts, and publishes it into the tmux session that launch runs in (`tmux set-environment`), so every pane opened in that tmux session afterwards, an agent-team teammate claude splits off included, inherits it; a pane in a tmux session no cs launch has run in renders the fixed 256-color palette rather than the derived shade.

An auto-detected `CS_TERM_BG_RGB` keeps its launch value while the live theme still matches the one detected at launch, so a terminal that changes background without changing theme keeps deriving its capsule surface from the old one. The render drops it when the live theme differs from the launch theme, or when the environment was inherited from another terminal, and the surface shades the assumed background. An RGB you set yourself is never dropped, so set it to override. One exported with no launch detection behind it carries no auto marker; when a launch detects the theme beside one you set, it leaves your RGB in place and marks it with `CS_TERM_BG_RGB_PINNED`. In iTerm2 the quiet chip and the band take the profile's background instead of an auto-detected one; the capsule surface still shades `CS_TERM_BG_RGB`.

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

# The layout: quiet (the default, see Quiet layout), band (see Band layout)
# or capsules
export CS_STATUSLINE_LAYOUT="band"

# The band's color: a session-palette name, brand, periwinkle, an r;g;b
# triplet, session (the session's own color, the default) or none (neutral)
export CS_STATUSLINE_BAND="periwinkle"

# The band's final width in cells, no frame taken off (default: stdin
# .columns, the tmux pane, the terminal, else 120, each less the frame)
export CS_STATUSLINE_COLS=160

# Columns Claude Code's prompt frame takes from a measured width (default 4;
# add 2 x statusLine.padding when you set it)
export CS_STATUSLINE_FRAME=4

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

Both commands read `settings.json` with jq first. On a file jq cannot parse they stop with an error naming the file and jq's reason, and change nothing: the file stays byte for byte, they write no `settings.json.cs-bak.<UTC stamp>` backup, and `disable` records no decline. Before any change they do make, they write that stamped backup beside the file.

`cs -uninstall` removes both binaries and strips the `statusLine` and `subagentStatusLine` registrations only when they point at the cs binaries; a status line or row renderer you configured yourself is left untouched.

`cs -doctor` includes a Statusline check and a parallel Subagent statusline check: OK when registered and executable, FAIL when a registration points at a missing binary. The Statusline check WARNs when cs-statusline is not registered and when a status line of your own is, because cs-statusline is the only writer of `.cs/local/context-pct`, and without that file the rotation nudge and the queue's context circuit breaker both go silently inert. A status line of your own can chain to cs-statusline (a bridge that runs it), so inside a session the file decides: when `context-pct` holds a number written within the last 15 minutes, the check reports OK with the reading's age and the command, and otherwise the warning adds "unless it chains to cs-statusline". The status line itself stays optional; the warning is about the gating that depends on it.

## Design notes

The design came out of a source study of [claude-powerline](https://github.com/Owloops/claude-powerline) (techniques: the single-call git query, the color-support ladder, per-segment gating of all I/O) and of oh-my-claudecode's HUD as a counterexample (its per-render transcript parsing, unconditional state reads, and multi-line output are the failure modes this script is shaped against). Claude Code delivers everything else needed (session name, context %, rate limits, model, cost) directly in the status-line stdin JSON, which is why the hot path needs no other data source.
