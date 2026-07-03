# Task queue in cs: walk-away drain of user-authored prompts — design

Date: 2026-07-03
Status: pending spec review
Decision trail: brainstormed with Alex, sharpened from GitHub issue
anthropics/claude-code#33920 ("side threads"). Feasibility of the underlying
mechanisms was checked with an independent Fable-5 pass (advisor tool down),
which empirically confirmed the Stop-hook `block`/`reason` drain and the
`.cs/local/` partition as safe substrates.

## Context and goal

Alex wants a queue of prompts he authors ahead of time that cs works through on
its own once he steps away. He loads up "do X, then Y, then Z", confirms once,
and walks off; when he comes back the list has been drained top to bottom. This
is the user-driven half of issue #33920 — not a live side-thread, but a
persisted to-do list the agent pulls from at turn boundaries.

The enabling insight: the "hand the agent its next instruction when it stops"
mechanism already exists and is proven in this repo. A cs Stop hook that returns
`{"decision":"block","reason":"..."}` feeds the reason straight back to the agent
as its next turn — that is exactly how `narrative-reminder.sh` and the TASKMASTER
hook already drive this session. A queue "drains" by having the Stop hook inject
the next task's text. No new session type, no IPC, no TUI-internal changes to
Claude Code.

Two facts shape the design:

- **Context percentage is not in the Stop-hook stdin.** It arrives only in the
  statusline input JSON as `.context_window.used_percentage` (`bin/cs-statusline`).
  So the "context is heavy" signal at the confirmation gate needs the statusline
  (which runs every render) to stamp the latest value into a machine-local file
  the hook can read.
- **The agent cannot compact itself.** `/compact` and `/clear` are user-typed
  slash commands with no agent tool and no hook injection path. So any
  compaction prompt is a recommendation *to Alex*, which only makes sense while
  he is present — i.e. at the front gate, before he walks away.

## Decisions (approved by Alex 2026-07-03)

1. **Unattended drain with a single front-door gate.** When the agent stops and
   the queue is non-empty, it asks *once* (via AskUserQuestion) whether to work
   through the list. On confirmation it drains every task at each stop boundary
   with no further questions until the queue is empty.
2. **No mid-drain pause.** Once armed, the drain runs straight through and trusts
   Claude Code's built-in auto-compact for overflow. The only context check is at
   the gate, so Alex can compact before stepping away.
3. **File is the source of truth; the native task list is a one-way mirror.** The
   queue lives in a machine-local file. The native TaskCreate/TaskList list is
   seeded from it and repainted from it; it is never authoritative and never
   written back to the file.
4. **FIFO, append to the bottom.** Top line is always the next task. `-queue add`
   and the TUI add push onto the end. A task added during a drain lands at the
   bottom and is absorbed quietly — no re-gate.
5. **Single-dash `-queue` verb** with a subcommand grammar (`add` / `list` /
   `rm` / `clear`), matching cs's verb convention (`-secrets`, `-checkpoint`).
6. **Add from the TUI too**, plus a per-session queue-depth badge in the picker.

## Non-goals

- Not a live side-thread; the queue is authored ahead of time, not produced by a
  parallel conversation (that is the other half of #33920, deferred).
- No per-task confirmation, dependencies, priorities, or scheduling. It is an
  ordered list of prompts, nothing more.
- No auto-compaction and no mid-drain context management.
- No cross-machine sharing of the queue. Like all `.cs/local/` state it is
  per-checkout / per-actor; in a shared session each person has their own queue.
- No multi-line task bodies in v1 (one prompt per line).

## Design

### Data (all in `.cs/local/`, gitignored, per the multi-user partition)

- **`queue`** — pending tasks, one single-line prompt per line, in run order
  (top = next). Empty/whitespace lines are ignored.
- **`queue.done`** — tasks already drained, appended as they complete, so nothing
  is silently dropped and `-queue list` can show a trail.
- **`queue.state`** — exactly one word: `idle`, `armed`, or `draining`. Absent
  means `idle`.
- **`queue.declined`** — an epoch timestamp written by `-queue defer`. Its
  presence within the cooldown window means "state is idle, but do not re-gate
  yet". Removed when the queue changes (add/rm/clear) or the cooldown expires.
  Kept separate from `queue.state` so the transient drain state stays a clean
  three-value enum.
- **`context-pct`** — the latest context percentage as an integer, stamped by the
  statusline on each render. Missing or stale ⇒ treated as unknown at the gate.

Placing the queue in `.cs/local/` keeps it clear of git's merge machinery, the
no-auto-commit rule, and the tracked/untracked partition — it is ephemeral
per-machine state by construction.

### The state machine (Stop hook)

The Stop hook fires whenever the agent stops. Its complete logic:

1. **Not a cs session, or a subagent** (`agent_id` present) ⇒ approve, do nothing.
2. **Queue empty** ⇒ if state was `draining`, reset to `idle` and emit a one-time
   "queue complete" note; otherwise approve.
3. **Queue non-empty, state `idle`** ⇒ *the gate*. Block with a reason that tells
   the agent to run AskUserQuestion: "N tasks queued, context at X% [recommend
   compacting first if X > 60], start working through them?" The hook changes no
   state. The agent, on the answer, runs `cs -queue start` (⇒ `armed`) or
   `cs -queue defer` (⇒ `declined <now>`).
4. **Queue non-empty, state `armed`** ⇒ first injection. Block with line 1's text;
   set state `draining`. Nothing is popped — nothing has run yet.
5. **Queue non-empty, state `draining`** ⇒ the injected task just finished. Move
   line 1 to `queue.done`, then block with the new line 1 and stay `draining`.

The three states exist to answer the one question the hook otherwise cannot:
*did the task I last handed out already run?* `armed` = "confirmed, nothing
dispatched — inject, do not pop"; `draining` = "something was dispatched and just
returned — pop it, then inject the next". Collapsing them is an off-by-one that
either skips task 1 or pops a task that never ran.

**Trust-and-pop.** The hook only knows the agent *stopped*, not whether it
*succeeded*. Rather than depend on the agent confirming each task (fragile; one
forgotten confirmation re-injects the same task forever), the hook pops
unconditionally and records to `queue.done`. A failed task is skipped, not
looped — the correct failure mode for unattended work. The agent is instructed to
surface any failure in its turn output so it is visible in the transcript.

**Runaway guard.** In the `draining` branch the hook injects the next task *only
after* confirming line 1 was actually removed from the file (the pop write
succeeded and the file is now shorter). If the pop write fails, it disarms (state
`idle`) and approves rather than re-injecting the same task — a fail-safe that
needs no persisted counter. Combined with the built-in `stop_hook_active` flag,
this bounds the drain: the queue strictly shrinks every cycle, so it terminates
in N stops.

**Priority against the narrative-nag.** Only one `block`/`reason` may be returned
per stop. While state is `armed` or `draining`, the narrative reminder yields;
the queue drain wins. This folds into the existing Stop hook (see plumbing).

### Agent responsibilities (driven by the injected reason text)

The agent's only jobs, all prompted by the hook's reason:

- At the gate: run AskUserQuestion; on "start" run `cs -queue start` and end the
  turn (the hook drives everything after); on "not yet" run `cs -queue defer`.
- On each injected task: do the work; on completion just stop (the hook pops).
- Maintain the native-list mirror (below).

### Native-list mirror (the visible checklist)

When the drain arms, the injection reason instructs the agent to seed the native
task list with one TaskCreate per queued item, mark each completed as it drains,
and mark the next in-progress. The file is authoritative: if context compacts
mid-drain and the native list is lost, the next injection reason restates the
remaining queue and the agent rebuilds it. The mirror is cosmetics that repaint
themselves; the file is what survives.

### CLI (`-queue`, single-dash verb)

- `cs <session> -queue add "text"` — append a task (also usable as `cs -queue add`
  from inside a session via `CLAUDE_SESSION_NAME`).
- `cs <session> -queue` or `-queue list` — print the numbered pending queue and
  the done trail.
- `cs <session> -queue rm <n>` — remove pending item n.
- `cs <session> -queue clear` — empty the pending queue and reset state to `idle`.

Modeled on `-secrets <cmd>` and `-checkpoint <cmd>`. Writes are atomic
(temp-file rename) to survive concurrent adds from multiple terminals.

### Statusline stamp and gate context

`bin/cs-statusline` already parses `.context_window.used_percentage`. Add a short
write that stamps the integer value into `.cs/local/context-pct` on each render.
The gate reads that file; if it is over 60, the AskUserQuestion the agent presents
offers "Compact first" alongside "Start" and "Not yet". Missing/unreadable ⇒ the
gate says "context unknown" and proceeds. There is no mid-drain context check.

### TUI add (Rust, `tui/src/app.rs`)

Add a normal-mode keybinding (a free key, likely `a`) that enters a text-input
mode modeled on the TUI's existing input modes (search `/`, new `n`), and on
Enter appends the typed line to the highlighted session's `.cs/local/queue`
(atomic write, same contract as the CLI). Add a small "N queued" badge to each
session row so queue depth is visible in the picker. This is the only piece in
Rust rather than bash and carries its own test.

### Hook and plumbing changes (fold into existing hooks; no new hooks)

- The drain logic folds into the existing Stop hook (`narrative-reminder.sh` is
  the current Stop hook), per the repo's no-new-hook-file convention; the drain
  runs first and short-circuits the narrative nag while armed/draining.
- `bin/cs-statusline`: the `context-pct` stamp.
- `bin/cs`: the `-queue` verb and its subcommands.
- `tui/src/app.rs` (+ `ui.rs` for the badge): TUI add and depth badge.

## Edge cases and failure modes

- **Gate declined** ⇒ `declined <now>`; the hook suppresses re-gating for a
  10-minute cooldown, or until the queue changes (add/rm) or the session
  restarts, whichever comes first. Avoids nagging every stop.
- **Add mid-drain** ⇒ appended to the bottom, drained FIFO after current items,
  reflected in the mirror; no re-gate (Alex already confirmed this run).
- **Add after drain finished** (state back to `idle`) ⇒ not mid-drain; the next
  stop hits a fresh gate.
- **Task fails / agent stops without finishing** ⇒ trust-and-pop to `queue.done`;
  the agent surfaces the failure in its output. v1 does not retry.
- **User types a prompt mid-drain** ⇒ handled as a normal turn; the drain resumes
  on the next stop (queue still armed). No explicit pause command in v1.
- **Runaway** ⇒ `stop_hook_active` + non-decreasing queue length ⇒ disarm and
  approve.
- **Subagent stop** ⇒ never drains (`agent_id` present ⇒ pass through).
- **Statusline never ran** (fresh session) ⇒ `context-pct` absent ⇒ gate proceeds
  with "context unknown".
- **Concurrent adds from two terminals** ⇒ atomic temp-file rename; last writer
  wins the rename, no partial lines.

## Compatibility and constraints

- bash 3.2 + BSD userland: no `local -A`, no `${var,,}`, no GNU-only sed/awk;
  atomic writes via `mktemp` + `mv`.
- No auto-commit / no `git add -A`: the queue is `.cs/local/`, gitignored, never
  committed.
- Command-substitution trap: any `-queue` helper whose stdout is captured must
  send warnings to stderr and must not `exit` from within `$(...)`.
- The `run_test` errexit trap: every assertion in the new tests needs
  `|| return 1`.

## Testing (TDD, existing bash harness + Rust)

- **Stop-hook state machine**: feed synthetic Stop JSON (with/without
  `stop_hook_active` and `agent_id`) and assert the emitted decision/reason and
  the resulting `queue.state`. Cover every transition: gate fires; arm ⇒ inject
  task 1 (no pop); draining pop sequence; empty ⇒ idle + complete note; decline
  cooldown; mid-drain add; runaway guard; nag yields to drain; subagent
  pass-through. Modeled on `tests/test_hooks.sh`.
- **CLI**: `-queue add/list/rm/clear` file mutations, atomicity, and
  `CLAUDE_SESSION_NAME` resolution. Modeled on `tests/test_cs_secrets.sh`.
- **Statusline**: stamps `context-pct` from input JSON; missing field is handled.
- **TUI**: Rust test for the queue-input mode's file write and the depth badge.

## Verified assumptions

- Stop hook `{"decision":"block","reason":"..."}` re-invokes the agent with the
  reason as its next instruction — observed live this session
  (`narrative-reminder.sh`, TASKMASTER).
- `.context_window.used_percentage` is present in the statusline input JSON
  (`bin/cs-statusline` already reads it) and absent from Stop-hook stdin.
- `.cs/local/` is gitignored and guard-enforced untracked (`bin/cs` refuses a
  tracked `.cs/local`).
- The TUI is a Rust binary (`tui/src/*.rs`) invoked by `bin/cs` as the session
  picker; it already has text-input modes to model the queue-add on.

## Build order

1. Queue file + `-queue` CLI (`add`/`list`/`rm`/`clear`), atomic writes, tests.
2. Stop-hook state machine + drain (gate, arm, draining, guards), folded into the
   existing Stop hook; tests.
3. Statusline `context-pct` stamp + gate context; test.
4. Native-mirror instructions in the injection reasons.
5. TUI add + depth badge (Rust); test.

Steps 1–4 deliver a fully working queue before the TUI piece lands; the TUI is
separable if we choose to fast-follow it.

## References

- GitHub issue anthropics/claude-code#33920 (side threads).
- `bin/cs-statusline` (context percentage source).
- `hooks/narrative-reminder.sh` (the Stop-hook block/reason pattern to fold into).
- `docs/superpowers/specs/2026-07-02-worktrees-design.md` (the `.cs/local/`
  partition and no-new-hook-file conventions this reuses).
