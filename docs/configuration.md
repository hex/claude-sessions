# Configuration

cs reads its configuration from environment variables and, for most of them,
from the [settings files](#settings-file) `cs -config` writes. cs needs none of
them and runs with sensible defaults out of the box. Set any of these in
`~/.bashrc` or `~/.zshrc`, or keep one with `cs -config set`, to override
behavior.

This lists every variable a user would set, plus the ones cs exports for hooks
and helper binaries. It deliberately excludes test seams and internal state —
values cs computes and passes to itself, which change without notice and are
documented in the code that reads them.

## Installation, updates, and settings

### Installed components

The installer deploys these components:

| Component | Names and location |
|---|---|
| Binaries | `cs`, `cs-secrets`, `cs-statusline`, `cs-subagent-statusline`, and `cs-tui` in `~/.local/bin/`. |
| Hooks and wrap passes | `~/.claude/hooks/cs/`, including the memory and summary passes that `/wrap` reads. |
| Commands | `/checkpoint` and `/wrap` in `~/.claude/commands/`. |
| Skills | `store-secret`, `prose-hygiene`, `rotate`, `finish`, `feature`, and `write-as-me` in `~/.claude/skills/`. |
| Mods | `cs`, `cs-update`, `cs-mermaid` and `cs-panel` in `~/.claude/skills/`. |
| Spinner tip | `~/.claude/skills/cs/tips.json`, named in `settings.json` as `spinnerTipsOverride.tipsFile`. See [band settings](#band-settings). |

See [hook and mod behavior](hooks.md) and [rotate and wrap keys](#rotate-and-wrap-keys).

### Settings backups

- Settings changes create sibling backups named `settings.json.cs-bak.<UTC stamp>` and preserve the original file mode.
- Backups with the same timestamp get numbered suffixes.
- Unchanged writes create no backup.
- cs retains the five newest backups.

### Installed content and user files

- The `.installed` record in `~/.claude/hooks/cs/` stores SHA-256 checksums.
- Install, update, and uninstall replace or remove only content cs wrote, including content shipped by a past release without a record.
- User files stay in place and appear in `Kept <path>` warnings.

Preserved files have these rules:

- Retired user files warn once per content. Paths with newlines cannot enter the record and warn each time.
- FIFOs, devices, and links to them stay unread.
- Symlinked skill directories stay untouched.
- Retired commands disappear only when cs wrote them.
- Content checking and replacement are separate operations. A concurrent rewrite can occur between them.

### Picker origin

| Record | Behavior |
|---|---|
| `.tui-origin` | Sits beside `.version`, outside `.installed`, and records `checkout <path>` or `release` for doctor's picker check. |
| No picker installed | The origin stays unchanged. |
| User's picker link preserved | The origin stays unchanged. |
| Uninstall | Removes `.tui-origin`. |

### Release verification and notes

- Updates authenticate `SHA256SUMS` with `SHA256SUMS.sig` using `ssh-keygen -Y verify`, then check the installer's SHA-256 digest.
- Web installs apply the same check to the picker binary. Missing verification tools, assets, or manifest entries and failed checks refuse the download.
- The verifier requires SSH signature support, the `release` identity, and the release's own `cs-release-vX.Y.Z` namespace, so a signature made for one tag never verifies another. `cs -update` refuses a release older than the installed cs. Embedded allowed signers and revoked public keys define which keys it trusts.
- An update refuses an installer that drops any revoked key from the installed list. Minisign is not used.
- `cs -update --check` prints the full pending release notes.
- A terminal launch offers a pending release once (`Update now? [y/N]`); a declined version is kept in `~/.cache/cs/update-declined` and not asked about again until a newer one is pending. In the session the update mod then names it in one line instead of opening its pane.
- The launch asks only once the release's `SHA256SUMS.sig` downloads (the same file `cs -update` verifies, fetched with the update check's 2 s connect and 4 s total timeouts). Until the signature is up, or when the check fails offline, the launch asks nothing and records nothing, so a later launch asks once the signature is there.
- A launch in a tmux window cs opened itself (`cs -spawn`, `cs <name> --remote` inside tmux) is not asked, since nobody sits at that window to answer. The banner line and the update mod still name the release there.
- The [in-session switches](#in-session-switches) describe the compact launch card and the [update mod](hooks.md#cs-update-not-a-hook-script--a-claude-code-mod).

## Environment variables you set

An export in your shell wins over every file. The [settings file](#settings-file)
is where a setting persists without one: every cs command, hook and status line
repaint reads it, a `cs -spawn` window and a teammate pane included, which a
shell export never reaches.

```bash
# Sessions directory (default: ~/.claude-sessions). A relative CS_SESSIONS_ROOT
# is taken from the directory cs (or cs-secrets) is started in.
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

# Override Claude Code binary (default: claude). A wrapper script must exec
# claude, or start exactly one claude: see hooks.md on how a hook knows the lead
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
# the same OSC 11 query as CS_TERM_THEME, when it succeeds). The statusline's
# capsule surface is a shade of it; unset, it shades an assumed dark or light
# background by 10%.
export CS_TERM_BG_RGB="250;248;242"   # r;g;b, 0-255 each

# Disable colors (see https://no-color.org)
export NO_COLOR="1"

# Status line: choose/order segments, or disable entirely
export CS_STATUSLINE_SEGMENTS="logo,session,notes,mail,git,model,ctx,limits"  # this is the default

export CS_STATUSLINE_DISABLE="1"

# Status line layout: quiet (the default), the items as text on the terminal
# background (docs/statusline.md, Quiet layout); band, one full-width row that
# fades from the band color into the terminal background (Band layout); or
# capsules. The band's color, which also tints quiet's session chip, its final
# width and the frame Claude Code draws around the line:
export CS_STATUSLINE_LAYOUT="band"
export CS_STATUSLINE_BAND="periwinkle"   # palette name, brand, periwinkle, r;g;b, session, none
export CS_STATUSLINE_COLS=160            # final width in cells; unset: measured, less the frame
export CS_STATUSLINE_FRAME=4             # columns the prompt frame takes from a measured width

# Force the Powerline rounded caps (U+E0B6/U+E0B4) on (1) or off (0),
# overriding this machine's recorded answer in ~/.config/cs/statusline-caps
export CS_STATUSLINE_CAPS="0"

# Where the machine-global usage cache behind the `fable` segment lives
# (default: $CS_SESSIONS_ROOT/.usage). One record per account per machine, not
# one per session: the endpoint it draws on budgets requests per account.
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the `fable` segment from cache only, never triggering a refresh
export CS_USAGE_NO_REFRESH="1"

# Every switch below that silences something the model would otherwise see is
# listed by `cs -doctor` under "Authority", with its live on/off state.

# Opt a session out of the scope-prompt auto-grounding hook
export CS_SCOPE_DISABLE="1"

# Opt a session out of the scope-prompt stage trace (see hooks.md)
export CS_SCOPE_TRACE_DISABLE="1"

# Milliseconds the scope-prompt hook allows its cheap front half before it
# skips the grounded scan on a slow machine (default 1500), so the digests,
# the date note and the clarify guideline reach the model instead of dying
# with a scan the registered timeout kills. 0 skips the scan on every prompt;
# a value that is not a number, or longer than seven digits, is the default; so
# is a value of 1000 or less on a shell whose clock ticks in whole seconds
# (bash 3.2), which cannot judge a budget of one tick.
export CS_SCOPE_BUDGET_MS="1500"

# Opt a session out of first-prompt Objective capture (see hooks.md)
export CS_OBJECTIVE_CAPTURE_DISABLE="1"

# Opt a session out of the date reminder: the one-line note scope-prompt adds
# when the calendar day has changed since the conversation last heard the date
# (see hooks.md).
export CS_DATE_REMINDER_DISABLE="1"

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
# declines and your prompt stays as typed. `grok` (or `xai`) has no CLI to
# prefer: it calls xAI's API, reading XAI_API_KEY or GROK_API_KEY.
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
# Every -api arm needs that vendor's key (`claude-api` reads ANTHROPIC_API_KEY)
# and declines without one.
export CS_REWRITE_PROVIDER="claude"          # claude | openai | gemini | grok | xai
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
# Defaults, used only where cs picks: claude-haiku-4-5-20251001 (the default
# rewriter and claude-api) and, on the other API arms, gpt-4.1-mini,
# gemini-flash-lite-latest and grok-4.3. Reasoning models are a poor
# fit whatever the provider: they can spend most of the output budget on
# reasoning and return a rewrite truncated mid-sentence, which cs declines — so
# ctrl+g intermittently does nothing at all.
export CS_REWRITE_MODEL="gemini-3.6-flash-low"        # agy's id, for the gemini CLI arm
export CS_REWRITE_TIMEOUT="25"                        # whole seconds; 0 or a non-number means 25

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

# Statusline context gauge escalation thresholds (see statusline.md). Each takes
# a plain integer of at most three digits; anything else falls back to the
# default shown. A value above 100 is out of the gauge's reach and so switches
# that band off, the same idiom cs -doctor uses on the Stop hook's tiers below.
export CS_STATUSLINE_CTX_WARN="40"
export CS_STATUSLINE_CTX_CRIT="65"

# Disable the subagent (agent-panel) statusline rows without unregistering
export CS_SUBAGENT_STATUSLINE_DISABLE="1"

# Context tiers in the Stop hook: one-time warning band start, rotation nudge
export CS_CTX_WARN_CTX="40"
export CS_ROTATE_NUDGE_CTX="65"

# Context percentage at which the cs mod's band draws its rotate key (Ctrl+X 1)
# above the prompt (default: the status line's warn band, 40).
# The mod reads it from the launched process's environment.
export CS_ROTATE_BUTTON_CTX="40"

# Forced rotation with grace (on at 80 unless set): once a turn ends with context
# at or past this percentage the mod runs /rotate itself, once per
# conversation, then counts the band down for 20 seconds and runs the /clear
# that continues from the handoff. Pressing 1 clears at once; sending a
# prompt stops the countdown. On at 80 unless set; `off` or `0` disables it,
# and a value that is not a number from 1 to 100 falls back to 80 rather than off. A
# conversation born of a /clear that already starts past it is never forced
# (a toast says so once); one met at launch or through /resume is.
export CS_ROTATE_FORCE_CTX="80"

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

# Rotation auto-start: after /clear on an armed handoff the session wakes
# itself and begins the handoff's next step with no typing. The delay is the
# interval between kick writes, repeated (up to 30 times) until the wake lands,
# since Claude Code's file watch arms only once session start has finished; 0
# writes once, with no retry. A non-numeric value falls back to the default.
# The opt-out restores the previous behaviour, where the rotation waits for a
# word from you.
export CS_ROTATION_KICK_DELAY="2"   # this is the default
export CS_NO_ROTATION_WAKE="1"

# Disable the iTerm2 attention bounce (the dock bounce a finished turn starts
# with shell integration, until the next prompt, and the attention marker
# the status line reads). Under tmux it also starts
# claude as found on PATH and with tmux's TERM_PROGRAM, so the tab gets no
# progress line and no Claude icon. Unset, cs enables both under tmux. The
# status line also stops reading its theme and background from the iTerm2
# profile (docs/statusline.md, Terminal theme).
# cs -doctor reports the integration state.
export CS_NO_ITERM2="1"

# Leave the Task tools to Claude Code's model default. A cs launch exports
# CLAUDE_CODE_ENABLE_TODO_TOOLS=1 because Claude Code 2.1.233+ withholds
# TaskCreate/TaskList/TaskUpdate/TaskGet on Opus 4.8, Sonnet 5 and Fable 5,
# and the rotation wake, the walk-away drain and the rotate skill all address
# the native task list. Set this to get the context those tool definitions
# cost back; the drain and the handoff then coordinate by message text alone.
export CS_NO_TASK_TOOLS="1"

# Launch without CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, even when the shell
# carries it. A cs launch exports it so the cs mod the installer deployed
# (the band's Ctrl+X 1 rotate key, past 40% context by default) loads; the flag
# also loads any other function-hooks plugin on the machine. Without this knob
# cs keeps a value already in the shell (0 keeps function hooks off).
export CS_NO_FUNCTION_HOOKS="1"

# Override the tmux binary cs -spawn and cs <name> --remote use (default: tmux on PATH)
export CS_TMUX_BIN="/opt/homebrew/bin/tmux"

# Not a setting. cs -spawn puts the staged seed's token here in the tmux
# window it opens, so that window takes the seed without asking; every
# other open of the name is asked. The launch drops it before claude
# starts. Setting it by hand does nothing unless it matches the seed.
# export CS_SPAWN_TOKEN

# Not a setting. cs <name> --remote run inside tmux opens a window
# remote:<name> in the cs tmux session that runs cs <name> --remote again
# with this set, so that run serves in its window instead of opening
# another. cs drops it before the server starts. The window's command also
# sets CS_SESSIONS_ROOT and CLAUDE_CODE_BIN to the caller's sessions root and
# the absolute claude the caller checked, since tmux starts a window with the
# tmux server's environment.
# export CS_REMOTE_WINDOW

# Not a setting. Every tmux window cs opens (cs -spawn, cs <name> --remote
# inside tmux) runs its command with this set to 1, since nobody sits at that
# window: the launch there does not ask about a pending update. cs drops it
# before claude or the server starts.
# export CS_UNATTENDED

# Force the detected platform instead of probing for it; any other
# value is rejected. Read by cs -secrets only, to choose between the
# macOS keychain and the encrypted file
export CS_PLATFORM_OVERRIDE="linux"   # macos, wsl, or linux
```

## Settings file

Two files hold settings in one format: this machine's
`~/.config/cs/config` (under `$XDG_CONFIG_HOME/cs/` when you set that), and a
session's own `.cs/local/config`, which outranks it in that session. `cs
-config` writes both:

```
cs -config list [--porcelain]          every setting: its value, where it comes from, when a change applies, then the lines the files skip
cs -config get <KEY>                   the value readers see now; empty when nothing sets it
cs -config set <KEY> <value>           keep it in this machine's file
cs -config unset <KEY>                 remove it from this machine's file
cs <name> -config list|get|set|unset   the same, for that session's own file
```

```
$ cs -config set CS_STATUSLINE_LAYOUT band
CS_STATUSLINE_LAYOUT=band in ~/.config/cs/config: applies at the next repaint
$ cs my-session -config set CS_SCOPE_DISABLE 1
CS_SCOPE_DISABLE=1 in my-session/.cs/local/config: applies at your next prompt
```

`set` refuses a key the files never hold, a key that is no cs setting and a
value the setting's readers would not take, each by name. When your shell
also exports the key, `set` still writes the file and says on stderr that the
export wins until you unset it there. `cs <name> -config set` and `unset` run
the same checks as opening the session first, so cs refuses a session whose
`.cs/local` git tracks, or whose config links out of the session, before it
writes anything.

**Precedence.** Each reader takes, per setting, your environment, else the
session's file, else this machine's, else the default, every time it runs: the
status line at each repaint, a hook at each event, cs at each command. An
edit applies without a relaunch, by the time the table below names.
A launch reads the session it opens and exports no value it read from a file
to claude, so nothing a file set can later pose as your shell's export. The
terminal theme cs measures at launch is a measurement, not an export of yours:
`CS_TERM_THEME` in a file wins over it. A teammate pane and a Claude Code
started outside cs carry no session, so they read this machine's file only.

**Format.** One `KEY=value` per line. Readers read the file line by line and
never run it as shell: they strip no quotes, trim no spaces and expand
nothing. Lines starting with `#` and blank lines are comments. Every reader
skips a line that is not `KEY=value`, a key that is not a setting and a value
its setting refuses, and the writer keeps them; `cs -config list` and `cs
-doctor` name each with its line number and why. A skipped session value lets
this machine's value apply. A key on two lines takes the last; `set` collapses
them into one line at the end. On and off settings take `1` and `0`, and a
session's `0` turns off this machine's `1`; an exported `CS_X=0` keeps the
meaning it has in your shell.

**Never in the file.** These stay environment variables, and `set` says why:
`CS_SECRETS_PASSWORD` (a secret), `CLAUDE_CODE_BIN`, `CS_TMUX_BIN`,
`CS_REWRITE_CMD` and `CS_REAL_EDITOR` (each names a program cs runs, and a
file a plugin can write must not choose one), `CS_SESSIONS_ROOT` (where every
session lives), `CS_SECRETS_BACKEND` and `CS_PLATFORM_OVERRIDE` (where
cs-secrets looks), `CS_USAGE_DIR` (a directory the status line writes to),
`CS_ACTOR` (a session pins its identity in `.cs/local/identity`) and
`CS_STATUSLINE_CAPS` (its own record, which `cs -statusline caps` writes).

`cs -uninstall` keeps `~/.config/cs/config` and says so; a session's file
stays with its session.

| Setting | Takes | Default | When a change applies |
|---|---|---|---|
| `CS_STATUSLINE_DISABLE` | `1` (on) or `0` (off) | off | at the next repaint |
| `CS_STATUSLINE_LAYOUT` | `quiet`, `band`, `capsules` | quiet | at the next repaint |
| `CS_STATUSLINE_SEGMENTS` | a comma-separated list of logo, session, notes, mail, pane, git, model, ctx, limits, fable and cost, each at most once | logo,session,notes,mail,git,model,ctx,limits | at the next repaint |
| `CS_STATUSLINE_BAND` | a palette name, brand, periwinkle, session, none or r;g;b | session | at the next repaint |
| `CS_STATUSLINE_COLS` | a column count from 1 to 9999 | measured | at the next repaint |
| `CS_STATUSLINE_FRAME` | a whole number of 1 to 3 digits | 4 | at the next repaint |
| `CS_STATUSLINE_CTX_WARN` | a whole number of 1 to 3 digits | 40 | at the next repaint |
| `CS_STATUSLINE_CTX_CRIT` | a whole number of 1 to 3 digits | 65 | at the next repaint |
| `CS_USAGE_NO_REFRESH` | `1` (on) or `0` (off) | off | at the next repaint |
| `CS_SUBAGENT_STATUSLINE_DISABLE` | `1` (on) or `0` (off) | off | at the next repaint |
| `CS_SCOPE_DISABLE` | `1` (on) or `0` (off) | off | at your next prompt |
| `CS_SCOPE_TRACE_DISABLE` | `1` (on) or `0` (off) | off | at your next prompt |
| `CS_SCOPE_BUDGET_MS` | milliseconds, 1 to 7 digits (0 skips the scan) | 1500 | at your next prompt |
| `CS_OBJECTIVE_CAPTURE_DISABLE` | `1` (on) or `0` (off) | off | at your next prompt |
| `CS_DATE_REMINDER_DISABLE` | `1` (on) or `0` (off) | off | at your next prompt |
| `CS_CLARIFY_DISABLE` | `1` (on) or `0` (off) | off | at your next prompt |
| `CS_CTX_WARN_CTX` | a whole number of 1 to 3 digits | 40 | when the next turn ends |
| `CS_ROTATE_NUDGE_CTX` | a whole number of 1 to 3 digits | 65 | when the next turn ends |
| `CS_QUEUE_MAX_FAILURES` | a whole number of 1 to 3 digits | 5 | when the next turn ends |
| `CS_QUEUE_MAX_CTX` | a whole number of 1 to 3 digits | 85 | when the next turn ends |
| `CS_QUEUE_MAX_5H` | a whole number of 1 to 3 digits | 85 | when the next turn ends |
| `CS_MAIL_WAKE_MAX` | a whole number of 1 to 3 digits | 5 | when the next turn ends |
| `CS_NO_MAIL_WAKE` | `1` (on) or `0` (off) | off | when the next turn ends |
| `CS_NARRATIVE_MAX_BYTES` | a byte count above 0, at most 15 digits | 131072 | when the next turn ends |
| `CS_NARRATIVE_KEEP_BYTES` | a byte count above 0, at most 15 digits | 65536 | when the next turn ends |
| `CS_ROTATE_FORCE_CTX` | `off`, `0` or a percentage from 1 to 100 | 80 | by your next prompt |
| `CS_ROTATE_BUTTON_CTX` | a whole number of 1 to 3 digits | the warn % | by your next prompt |
| `CS_NO_ROTATION_WAKE` | `1` (on) or `0` (off) | off | at the next `/clear` or launch |
| `CS_ROTATION_KICK_DELAY` | seconds, 1 to 7 digits | 2 | at the next rotation |
| `CS_REWRITE_PROVIDER` | `claude`, `claude-api`, `openai`, `openai-api`, `gemini`, `gemini-api`, `grok`, `xai` | claude | at the next ctrl+g |
| `CS_REWRITE_MODEL` | letters, digits and `. _ : / -`, starting with a letter or digit, at most 128 characters | per provider | at the next ctrl+g |
| `CS_REWRITE_TIMEOUT` | seconds, 1 to 7 digits | 25 | at the next ctrl+g |
| `CS_REWRITE_PROGRESS` | `screen`, `native`, `line`, `static` | screen | at the next ctrl+g |
| `CS_REWRITE_DISABLE` | `1` (on) or `0` (off) | off | on: at the next ctrl+g; off after a launch with it on: at the next launch, which installs the ctrl+g shim |
| `CS_TERM_THEME` | `light`, `dark` | detected | at the next repaint |
| `CS_TERM_BG_RGB` | r;g;b, each 0 to 255 | detected | at the next repaint |
| `CS_NO_ITERM2` | `1` (on) or `0` (off) | off | the tab title, the bell bounce and the status line's iTerm reads: now; the launch's iTerm tmux path: at the next launch |
| `CS_NERD_FONTS` | `1` (on) or `0` (off) | off | at the next cs command |
| `CS_NO_TASK_TOOLS` | `1` (on) or `0` (off) | off | at the next launch |
| `CS_NO_UPDATE_CHECK` | `1` (on) or `0` (off) | off | at the next launch |
| `CS_NO_FUNCTION_HOOKS` | `1` (on) or `0` (off) | off | at the next launch; on, no mod loads, the cs panel included |

## Rotate and wrap keys

The installer offers, once per machine, to bind four keys in Claude Code's
`keybindings.json` (in `$CLAUDE_CONFIG_DIR` when you set it, otherwise
`~/.claude/keybindings.json`). Run inside an encrypted session, where
`CLAUDE_CONFIG_DIR` is the session's `.cs/claude-config`, cs writes the shell's
file instead, the one that session links:

```json
{"bindings": [{"context": "Chat", "bindings": {"ctrl+x r": "command:rotate", "ctrl+x w": "command:wrap"}}, {"context": "Global", "bindings": {"ctrl+x 1": "strip:jump1", "ctrl+x 2": "strip:jump2"}}]}
```

The two command keys sit in the `Chat` context, where Claude Code wants a
`command:` binding (2.1.310 warns of one in any other named context), and the
two band chords in `Global`, where the `cs` mod reads them.

Ctrl+X then R submits `/rotate`, and Ctrl+X then W submits `/wrap`, band or no
band. Ctrl+X then 1 or 2 presses the `cs` mod's band above the
prompt: 1 its rotate key, or its `/clear` after arming a handoff, and 2 its
wrap key. The band has no key of its own, so a digit you type to answer a
question never presses it; without these two chords it answers only a click or
Ctrl+X Tab. Text you are typing stays in the prompt. Claude Code drops a Ctrl+X that gets no second
key within 3 seconds. The chords need no terminal setting. Ctrl+X 1 and
Ctrl+X 2 reach the band only because Claude Code mounts no handler of its own
for `strip:jump1` and `strip:jump2` (measured on 2.1.291 and 2.1.292); a
release that mounts one takes the chord from the band without a warning.

- A yes merges the two command keys into the file's first `Chat` block and
  the two chords into its first `Global` block (adding a block where there
  is none, and creating the file when there is none). A cs key that sits in a
  block of the other context, as an earlier cs put every key in `Global`, is
  moved into its own, and the install says so (`moved ctrl+x r, ctrl+x w to
  the Chat context`). cs never replaces a key you already
  bind to something else, in any context: it keeps your action and names the
  key in a warning. A bare `ctrl+x` you bind counts too: Claude Code would
  wait for a second key and never run yours, so cs binds none of the chords
  and names them, with your key, in one warning. cs
  refuses a file that is not JSON with a `bindings` array and leaves it
  untouched.
- cs 2026.10.6 bound Option+1 and Option+2 (`alt+1`, `alt+2`), which iTerm2
  uses to switch panes. On a machine that answered yes, an install removes
  those two where they still hold cs's values and binds the chords, with or
  without a terminal. An `alt+1` or `alt+2` you bound to something else stays.
  cs's own stay too when Ctrl+X R or Ctrl+X W conflicts, so the command
  whose chord is taken keeps a key; a conflict on Ctrl+X 1 or Ctrl+X 2 does
  not keep them.
- The installer records the answer in `~/.config/cs/option-keys` (`yes` or
  `no`; `$XDG_CONFIG_HOME/cs/option-keys` when you set that). After a `no` it
  never asks again. After a `yes`, every install and `cs -update` adds any of
  the keys nothing binds, so a machine that bound Ctrl+X R and Ctrl+X W before
  gets Ctrl+X 1 and Ctrl+X 2 on its next update, without another
  prompt. Claude Code picks the file up
  without a relaunch. An encrypted session launched before the file existed
  gets it at its next launch, when cs links it into the session.
- With no terminal attached (CI, a pipe) and no recorded answer, the installer
  asks nothing, writes nothing and records nothing; it prints one line saying
  to run `cs -update` in a terminal.
- To change the answer, remove `~/.config/cs/option-keys` and run `cs -update`
  (or `./install.sh`) in a terminal; it asks again. To drop the keys after a
  `yes`, answer `no` there and delete the four entries from `keybindings.json`.
- `cs -uninstall` removes only the keys that still hold cs's values, the
  chords and an earlier cs's `alt+1` and `alt+2` alike, drops any block
  that leaves empty, deletes the file when it holds nothing else (a symlinked
  file keeps its link and gets `{"bindings": []}` written through it), and
  removes the recorded answer.
- `cs -doctor` reports the state: bound, declined, not asked, a conflict on
  one of the chords (or on a bare `ctrl+x`), a key not bound yet (as on
  a machine that still has the Option keys, until its next `cs -update`), a
  key outside its context (until its next `cs -update`), cs's
  `alt+1` or `alt+2` still there beside the chords, or an unparseable file.
- cs reads keys the way Claude Code does: `Ctrl+X`, `control+x` and
  `ctrl+x  r` with two spaces are the same keys as `ctrl+x` and `ctrl+x r`,
  and `Option+1` is `alt+1`.

## Band settings

Three rows of Claude Code's `/config` menu shape the cs mod's band above the
prompt (the cs plugin's `userConfig`, stored by Claude Code in
`settings.json`). A change reloads the mod.

| Row | Values | Default | What it does |
|-----|--------|---------|--------------|
| `cs.bandPrompts` | on, off | off | Draws the rail: a bar per prompt and the name of one prompt before the bars; a press on a bar scrolls to its prompt. The band's other words draw either way. |
| `cs.bandPrompt` | `latest`, `read` | `latest` | `latest` names the newest prompt and draws its bar thick. `read` names the prompt being read, the one whose row stands highest on screen, and follows your scroll. |
| `cs.bandBars` | a whole number, 1 or more | `10` | The most prompt bars the band draws, the named prompt's always among them; older prompts fold into one `…N` run, and newer ones into one `M…` run when the named prompt is older than the bars reach. |

`/config` refuses a value the band cannot draw (a bar count under 1 or not
whole), naming the row beside it. A bad value stored some other way, such
as by editing `settings.json`, leaves the band without the rail and says so in
one toast; the rest of the mod runs.

### Spinner tip

Claude Code's spinner tips say how to turn on the prompt bars. The installer
names cs's tips file, `~/.claude/skills/cs/tips.json`, in `settings.json`:

```json
{"spinnerTipsOverride": {"tipsFile": "~/.claude/skills/cs/tips.json"}}
```

- The installer writes `tipsFile` only when `settings.json` names no tips
  file. Claude Code reads one tips file, so a file you named stays, and the
  installer says that Claude Code does not show cs's tip.
- The installer never changes `tips`, `label`, `excludeDefault`, or
  `spinnerTipsEnabled`. With `spinnerTipsEnabled` set to `false`, Claude Code
  shows no tips, cs's included.
- Claude Code picks a tip during one turn and shows it under the spinner of
  the next turn. It reads the tips file once per session, so a session
  started before an edit to the file shows the old tips.
- `cs -uninstall` removes `tipsFile` when it names cs's file and the file is
  gone. If you changed the file, uninstall keeps the file and the setting.

To turn cs's tip off, delete the `tipsFile` line or set it to `""`. The
installer records each choice in `~/.config/cs/tips-file` (under
`$XDG_CONFIG_HOME` when you set it): `named` after it names cs's file, and
`declined` after you take the file out. `cs -update` then leaves the setting
alone. To get cs's tip back, delete `~/.config/cs/tips-file` and run
`cs -update`. The installer reads a record that holds any other value as
`declined` and warns. `cs -uninstall` deletes the record.

## In-session switches

Bare `/cs` (or `/cs-panel`) opens a pane of these switches and of cs's settings
together: the `/config` rows of `cs`, `cs-update` and `cs-mermaid`, then every
setting `cs -config list` names. `c` changes the selected row, `u` removes a
setting from the file that holds it, and `p` changes it for this session only;
a setting your environment pins is read-only there. See
[the panel mod](hooks.md#cs-panel-not-a-hook-script--a-claude-code-mod).

The release-notes pane is a Claude Code `/config` row, `cs-update.showReleaseNotes`
(on by default). Off, a launch opens no pane; `/cs-update` still opens it.
The launch banner's compact notes card draws only when `CS_NO_FUNCTION_HOOKS=1`
or `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0` withholds the mod, since otherwise
the mod shows the full notes in the session.

Mermaid drawing is a Claude Code `/config` row, `cs-mermaid.drawDiagrams` (on by
default). Off, ` ```mermaid ` fences in replies show as source. The diagram
instruction lives under `cs:mermaid-diagrams` in a cs session's `CLAUDE.local.md`;
neither this toggle nor `.cs/local/disabled` removes it. To opt out of the
instruction, delete its prose but keep the `<!-- cs:mermaid-diagrams -->`
comment so migration does not add it again.

## Environment variables cs sets for you

These are exported automatically when you start a session, so the Claude Code
process and its hooks can find the session:

- `CLAUDE_SESSION_NAME` - The session name (e.g., `myproject`)
- `CS_CLAUDE_SESSION_ID` - The conversation UUID cs launched or resumed, exported so hooks can tell the launched conversation from any other claude that resolves the same session
- `CS_LEAD_PID` - Exported by every cs launch, never set by hand: the pid cs hands to claude. A hook takes a claude as the one cs launched when its `CLAUDE_PID` equals this or when the claim that claude's SessionStart wrote to `.cs/local/lead-pid` names it (see [hooks.md](hooks.md#how-a-hook-finds-its-session-cs-resolvesh))
- `CS_LEAD_CLAIM` - Exported as `1` by every cs launch, never set by hand: says the launch clears `.cs/local/lead-pid` and takes the lead's claim there. Under a launch without it, which a cs from before the claim made, the hooks take only the claude whose `CLAUDE_PID` equals `CS_LEAD_PID` for the lead
- `CS_REAL_EDITOR` - Your own `$EDITOR`, captured before cs repoints `EDITOR`/`VISUAL` at the prompt-rewriter shim. The shim hands every file that is not a composer buffer back to it, so `/memory` and commit messages still open your editor. Set it yourself to pin which editor that is
- `CS_SECRETS_SESSION` - For a worktree session, the base session its secrets key to, so a feature worktree reads the same store as its parent (see [secrets.md](secrets.md))
- `CLAUDE_SESSION_DIR` - Full path to the session directory (workspace root)
- `CLAUDE_SESSION_META_DIR` - Path to the `.cs/` metadata directory
- `CLAUDE_CODE_TASK_LIST_ID` - Set to the session name for task list persistence; a feature worktree gets its own list under its `base@task` name, not the base's
- `CLAUDE_CODE_AUTO_MEMORY_PATH` / `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` - Redirect [Claude Code auto memory](https://code.claude.com/docs/en/memory) into `<session>/.cs/memory/`. Claude Code owns the memory-file format and cs owns the storage path. See [memory records](session-layout.md#shared-files).
- `CS_BIN` - Exported by every cs launch, never set by hand: the absolute path of the running cs, replacing any value inherited from a parent launch. The mods run cs through it (`cs -update`, `/queue`), since the claude process's `PATH` is not the launching shell's
- `CS_UPDATE_AVAILABLE` - Exported by a cs launch, never set by hand: the version a newer cs was found at. The cs-update mod reads it to draw the release-notes pane. Absent when nothing is pending
- `CS_UPDATE_DECLINED` - Exported by a cs launch, never set by hand: the pending version, when you declined it at a launch's offer to update. The cs-update mod then says in one line that the release is there instead of opening its pane. Absent otherwise
- `CS_LIVE_LOCK_PID` - Set only for `.cs/local/pre-open`, never by hand: the pid in `.cs/session.lock` when that pid is a running process, empty otherwise. A pre-open reads it to tell whether the session is running instead of reading the lock (see [session-layout.md](session-layout.md))
