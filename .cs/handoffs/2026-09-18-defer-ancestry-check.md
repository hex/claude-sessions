---
parent: 601bd3d4-a5e2-4f9a-a65e-1587ba90a07e
created: 2026-09-18T10:21:44Z
purpose: build the deferred tmux ancestry check so a fresh conversation's first status-line render paints instead of being killed
status: consumed
consumed_by: 93a26e53-349e-497f-b923-e180dbeaedf4
---

## 1. Next Step

Build **#659: defer the tmux ancestry check off the cold render path** in
`bin/cs-statusline`. Alex approved it with "rotate and start it" — the build is
the mandate, not another measurement.

**What to change.** `_sl_tmux_is_real` (the ancestry verdict) forks `ps` and an
`awk` at LOAD time, before `main` runs. Measured today: it appears in a
conversation's FIRST render and never again, and it is the difference between a
render that is killed and one that paints.

**The shape.** Defer the verdict on the cold path the way the file already
defers the usage refresh at `bin/cs-statusline:1733`:

```bash
( "${BASH:-bash}" "$_SL_SELF" --refresh-usage >/dev/null 2>&1 & ) >/dev/null 2>&1
```

On a cache miss, render without the verdict and compute it in a detached child
that writes the cache entry, so render 2 finds it warm. Renders 2+ already never
fork `ps`, so steady state is untouched — that is the property to protect and to
pin with a test.

**The one open design question, which decides whether this is worth building:**
what the bar draws on render 1 while the verdict is unknown. The verdict gates
tmux-dependent segments (the pane segment, and the tmux-client lookup). Options
are to omit those segments on render 1, or to assume one answer and correct on
render 2 (a visible flicker). Decide this first — if neither is acceptable,
close #659 as not-built and say so, rather than shipping a flicker nobody wants.

**TDD, red first.** The suite is `tests/test_statusline.sh` (240 tests, ~150 s).
A new test must pin that renders 2+ still fork no `ps`, and the existing pins
`test_warm_render_forks_only_the_interpreter_and_jq` and
`test_io_gating_git_subprocess` must stay green — if either goes red, the change
has altered steady state and is wrong, which is exactly how the previous attempt
was caught.

## 2. Settled and rejected

- **Stale-first rendering: BUILT, REVIEWED, DROPPED.** Branch
  `feat/statusline-stale-first` at **d51ed4d**, unmerged, retained on disk. Do
  not revive it without reading this. It printed the frame the conversation last
  published and refreshed in a detached child. Fable ruled drop; I verified its
  two central claims myself.
  - **Fatal, verified:** the frame is keyed on Claude Code's pid — new for every
    fresh conversation — and is written only at the END of a render that
    survived. So at a fresh conversation's first request no frame exists, and
    the retry loop is unchanged. It only ever served ticks 2+, which were never
    the complaint. Verified: `~/.cache/cs/frame` does not exist before the first
    render.
  - **Also broken, verified:** the refresh child ran in `( ... ) &` with nothing
    forwarding `CS_STATUSLINE_PARENT`, so the child read `$PPID` (the subshell)
    and published under a new key every tick. Measured: four ticks under one
    stable parent left four distinct keys — 65066, 65340, 65454, 65589.
  - Cost I got wrong when recommending it: I told Alex 2 forks/tick today vs ~3
    with the feature. Counted against the code it is **3 vs 8 on bash 3.2**
    (2 vs 6 on bash 4+); the lock alone is 3 of them.
- **Raising `refreshInterval`: REJECTED, verified in source.** The attention
  pulse is second-parity — `bin/cs-statusline:1571` and `:1923` both do
  `[ $(( ${_NOW:-0} % 2 )) -eq 1 ]`. An even interval samples one parity forever
  and the mark freezes on or off depending on the launch second. Interval 3
  alternates on a 6 s period. `tests/test_install.sh:909` pins the value at 1.
  It also slows `.cs/local/context-pct`, whose mtime within 15 minutes is the
  only liveness signal for conversations running outside cs.
- **Cache-warming at launch alone: REJECTED.** Cold-to-warm is ~0.5 s against
  what was then thought a 5-9 s problem.
- **Pre-accepting the folder-trust dialog: DROPPED by Alex** ("drop it the
  pre-accept trust"). The only mechanism is writing
  `projects["<dir>"].hasTrustDialogAccepted` into `~/.claude.json`; there is no
  CLI flag or setting that disables the dialog. Rejected on cost: it would be
  cs's first write to a 515 KB file owned by another program that every live
  claude rewrites — **measured 13 distinct size/mtime states in 60 s, about one
  write every 4.6 s** — to save one keypress per newly created directory. And
  trust is keyed on the exact path and outlives the directory, so the keypress
  is paid once per path ever used, not once per session. Do not re-propose.
- **Keying a frame on `CLAUDE_SESSION_NAME`** instead of the pid is the only
  keying under which a cached frame could serve tick 1 of a fresh conversation.
  Rejected: the bar shown may be hours old. Recorded so nobody re-derives it.

## 3. Conversation-only facts

Measured today on **Claude Code 2.1.276**, macOS, in real `cs` sessions.

**The mechanism.** Claude Code applies no timeout to a status line, but a render
still running when it next wants one is killed, and each kill triggers another
request. A render slower than that gap feeds its own retry loop and the bar
stays blank until an attempt survives.

**The three-arm table** (invoke -> paint; count is invocations before one
survived). Identical probe: fresh conversation, already-trusted directory,
`refreshInterval: 1`, dedicated tmux server, each arm's command logging
start/end so a missing end is a kill:

| arm | paint | invocations |
|---|---|---|
| `printf` (floor) | 0.12 / 0.28 / 0.66 s | 1 each |
| cs-statusline direct | 0.70 / 0.78 / 1.00 / 2.36 / 3.54 s | 1, 1, 1, 3, 4 |
| bridge -> cs-statusline | 5.19 / 7.25 / 7.34 / 8.80 s | 5 to 9 |

Under all three, **2.0-4.0 s** passes between the conversation starting and
Claude Code's first status-line request. Nothing in userspace moves it.

**The interval pairs**, which a fixed timeout cannot explain: a 2 s render dies
117/117 at interval 1 and survives first try at interval 5; a 4 s render
survives first try at interval 10.

**The cold-render breakdown** — PATH shims timestamping start/end per external
command, each execing an ABSOLUTE path so it cannot re-enter itself, inside real
fresh conversations with `CS_STATUSLINE_PARENT` named:

| run | render 1 (cold) | renders 2+ |
|---|---|---|
| 4 | KILLED, span 1058 ms — ps 251, awk 164 | survive, 111-616 ms — jq only |
| 5 | KILLED, span 636 ms — ps 83, awk 72 | mostly survive — jq, sometimes tmux |
| 6 | KILLED, span 618 ms — ps 113, awk 84 | survive, 249-755 ms — jq, sometimes tmux |

`ps` and its `awk` appear in render 1 and never again; the verdict is cached
300 s on `$_PARENT,$TMUX`. Bash starting and parsing the 95 KB script is
~260-320 ms of every render regardless.

**The kill is not a fixed budget.** Renders spanning 618-1058 ms died; one at
755 ms lived and one at 322 ms died. Treat "under ~500 ms" as the only safe
target — there is no documented limit.

**Two probe artifacts I created and then caught — the same bug twice.** Any
process inserted between Claude Code and the render must name the real parent in
`CS_STATUSLINE_PARENT`, or the render's `PPID` is that process (new every tick)
and every per-conversation cache misses forever. It bit the stale-first refresh
child, and then it bit my own timing wrapper, where I nearly reported "killed
renders never warm the caches" as a cs finding. A bridge sets that variable,
which is why the bridged arm behaved while the direct arm did not.

**A third artifact, different class.** An earlier conclusion of "the cost is
diffuse, no single cold-only cost to defer" was read off the runs with the
broken wrapper parent and is **wrong** — the corrected runs show the isolated
`ps`+`awk`. And a `sleep 3.0` arm's "one render completed but never painted" was
my poll loop closing at +60 s while that render ended at +270.8 s. A probe whose
observation window closes before the event cannot report the event's absence.

**A void control worth not repeating:** bare `claude` in a trusted non-cs
directory is NOT a floor control. It lands on a "describe a task for a new
session" screen that draws no status line, so it rendered 115-179 times per run,
completed every one, and painted nothing. A control that cannot display the
thing being measured reads exactly like a failure of the thing being measured.

**Alex's decisions this conversation, in his words:** "drop it the pre-accept
trust"; "check with fable" and later "check with fable first" (twice — he holds
for the foreign-model pass before committing to a direction); "send that to
@iterm-agents-sidebar then proceed"; "ok, proceed"; and "rotate and start it",
which is the mandate for the Next Step above.

**Handed over, not ours:** the sidebar bridge costs ~6 s of the ~7 s and belongs
to the `iterm-agents-sidebar` session. Sent there with the three-arm table
(msg_id 294b7969-1b50-4de4-98f4-d0508ed03e76). cs owns only the middle row. No
reply had arrived when this handoff was written — a successful send means the
message reached that session, not that it was read or accepted.

**Repo state:** `main` at **a85ee08**, clean except the modified handoff file
being rotated and untracked `scratchpad/`. `bin/cs-statusline` byte-matches the
installed copy — nothing from this conversation shipped. Still ~40 commits ahead
of origin, nothing pushed, unreleased; `cs -version` reports 2026.9.17.

**The narrative was rotated** this conversation (7 sections, 118 KB, to
`.cs/narrative-archive/hex-users-noreply-github-com/2026-09-16-05370f31.md`;
live file now 110 KB). `cs -narrative rotate` wrote the rotation but its own
commit failed and said to commit by hand — and because `.cs/` is gitignored
wholesale in this repo, the archive file needed `git add -f` before
`git commit -- <paths>` would take it.

**Probe scripts** are untracked under `scratchpad/` in the session directory and
in this conversation's scratchpad: `slpaint2.sh`, `slsweep.sh`, `slsweep2.sh`,
`slfloor.sh`, `sldecomp.sh`, `sldecomp_real.sh`, `sldecomp_nobridge.sh`,
`slcold.sh`, plus `shimbin/` and `out/`. They are throwaway, not worth
preserving, but they are the only record of how each number was taken.

## Completeness (pass one)

Written from live context at roughly 45%, no compaction. Every fact above is
first-hand from this conversation. Pass two appends the recoverable sections.

## 4. Primary Request and Intent

The conversation woke on `.cs/handoffs/2026-09-18-statusline-first-paint.md` and
ran its next step: find why the status line takes seconds to appear at session
open. That measurement is finished and is section 3's tables. Alex then dropped
the folder-trust half, took a Fable pass on the fix direction, sent the bridge
finding to the sidebar session, approved building the cs-side fix, watched it
get built and then killed by a second Fable pass, and finally approved the
narrower fix that the corrected measurement pointed at — which is this handoff's
Next Step.

The through-line: **the complaint was one thing, and it decomposed into three
owners** — the bridge (~6 s, handed away), cs-statusline's cold render (1-3 s,
#659, the work), and Claude Code's own 2-4 s startup floor (nobody's).

## 5. Key Technical Concepts

- **`bin/cs-statusline`** is standalone, not assembled by `build.sh` (unlike
  `bin/cs`). ~1700 lines, 95 KB, bash 3.2 + BSD compatible. `CS_STATUSLINE_LIB=1`
  sources it as a library without running `main`, which is how the test suite
  reaches internal helpers.
- **The cache layer** it already has, and which #659 should reuse rather than
  reinvent: `_cache_read <kind> <identity> <max-age>` and
  `_cache_write <kind> <identity> <text>`, entries at
  `~/.cache/cs/<kind>/<key>` as `epoch<TAB>identity\ntext`. Identity-guarded and
  torn-read-safe: a half-written entry, a missing file or a foreign identity is
  a miss, never a wrong answer. `_cache_key` sanitises; `_sl_parent_pid` sets
  `_PARENT` from `$PPID` or `CS_STATUSLINE_PARENT`.
- **The fork diet** (#632, #648) is a deliberate, tested property: a warm render
  forks 2 (bash + jq), 3 on bash 3.2 where a `date` fills the shared clock memo.
  Any change that raises this is wrong unless argued explicitly.
- **The pulse** is second-parity at two sites, which is why `refreshInterval`
  is not a free knob.

## 6. Files and Code Sections

- `bin/cs-statusline:1733` — the detached-child idiom to copy for #659.
- `bin/cs-statusline:1571` and `:1923` — the two second-parity pulse sites.
- `bin/cs-statusline` `_sl_tmux_is_real` (around :229-251, `TMUX_REAL_CACHE_TTL=300`)
  — the ancestry verdict to defer; `_cache_write tmux-real "$ident" "$verdict"`
  is its write.
- `bin/cs-statusline` `_render` — two `printf '%s\n' "$out"` sites, plain mode
  and capsule mode, which is where the dropped branch published its frame.
- `lib/70-statusline.sh:95` — where cs registers `refreshInterval: 1`.
- `tests/test_statusline.sh` — 240 tests; `run_sl "$PAYLOAD"` is the driver,
  `_load_sl_functions` the library-mode entry, `setup()` gives each test a
  private `HOME` and `CS_SESSIONS_ROOT`.
- `tests/test_install.sh:909` — pins `refreshInterval` at 1.
- `~/.claude/settings.json` — `statusLine.command` is the sidebar bridge, which
  then execs cs-statusline; `refreshInterval: 1`.
- `~/.claude-sessions/iterm-agents-sidebar/plugin/statusline-bridge.sh` — the
  handed-over arm. Not ours to edit.

## 7. Pending Tasks

Native list (keyed to the session, survives the `/clear`; reconcile against it
rather than mirroring this):

- **#659 pending** — defer the tmux ancestry check. This handoff's Next Step.
- **#554 pending (PARKED)** — SessionStart notice for tool calls left pending.
- **#606 pending (POSTPONED)** — cs --remote via Claude Remote Control.
- #655, #656, #657, #658 completed this conversation. Everything else was
  already closed.

## 8. Current Work

Nothing in flight. `main` is at a85ee08 and clean; the only branch from this
conversation is `feat/statusline-stale-first` at d51ed4d, parked unmerged and
not to be revived (section 2). No tests are failing on main. Two Fable subagents
(`fable-statusline`, `fable-stalefirst`) were spawned and have both reported and
gone idle; nothing waits on them.

The next conversation starts clean at step one of the Next Step: decide what the
bar draws on render 1 while the ancestry verdict is unknown, then build red-first
or close #659 as not-built.

## Completeness (pass two)

Nothing cut.
