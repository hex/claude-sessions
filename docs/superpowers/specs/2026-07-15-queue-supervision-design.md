# Walk-away queue supervision: circuit breakers + notification inbox — design

Date: 2026-07-15
Status: pending spec review
Decision trail: ranked #4 in the four-provider council deep-research on cs
capability gaps (the walk-away queue drains unsupervised — nothing stops a
drain that is failing, burning context, or eating the rate-limit window, and
nothing tells the returning user what happened). Brainstormed with Alex
2026-07-15: v1 scope = breakers + inbox with ZERO new hook files; the Claude
Code Notification-event listener (permission-prompt/idle capture) was
considered and DEFERRED — Alex uses CC's native remote control for real-time
phone alerts, so the listener's residual value is forensic history only.

## Context and goal

`cs -queue` lets Alex line up tasks and walk away: a Stop-hook gate asks
once, then a drain loop feeds Claude one task per turn until the queue
empties. The drain is unsupervised: a broken task can fail forever, burn
context to the ceiling, or spend the five-hour rate-limit window on
retries — and the returning user reconstructs events from session.log by
hand. The goal is supervision using signals cs already collects: tripwires
that park a drain going bad, and a small per-machine journal of what
happened, surfaced once on return.

## Decisions (approved by Alex 2026-07-15)

1. **v1 = circuit breakers + notification inbox, zero new hook files.** All
   logic folds into existing hooks; the CC `Notification` listener is a
   deferred follow-up.
2. **Inbox CLI = `cs -queue log`** — the inbox is the queue's story in v1;
   no new top-level verb.
3. **Inbox records drain lifecycle only**: `drain_started`, `task_done`,
   `breaker_tripped`, `drain_finished`, `gate_declined`.
4. Controller conventions accepted with the design: per-task failure
   counting; thresholds 5 failures / 85% context / 85% five-hour window
   with `CS_QUEUE_MAX_FAILURES` / `CS_QUEUE_MAX_CTX` / `CS_QUEUE_MAX_5H`
   env overrides; trip action = park + inbox entry + debrief (queue file
   intact); digest auto-surfaces unseen entries once.

## Non-goals

- No new hook files: no CC `Notification` listener (deferred), no new
  events subscribed.
- No TUI surface: no breaker column, no inbox pane (the picker's QUEUE
  column is untouched).
- No auto-compaction on the context breaker — parking is the only trip
  action; compacting mid-drain unattended risks a working context.
- No dollar-cost breaker (subscription pricing makes the five-hour window
  the real currency).
- No danger-command breaker in bash-logger (its "never blocks" contract
  stands; flagged as out of scope, not solved).
- No multi-machine inbox sync — `.cs/local/` is machine-local by law.

## Design

### Storage (all in `<session>/.cs/local/`, machine-local)

- `notifications.jsonl` — append-only inbox. One JSON object per line,
  written with `jq -nc` (the timeline.jsonl pattern; task text is
  arbitrary, so never hand-assembled). Common fields: `ts` (epoch),
  `event`. Per-event extras: `task` (task_done), `reason` and `readings`
  (breaker_tripped), `done`/`remaining` counts (drain_finished).
- `notifications.seen` — cursor: the count of inbox lines already surfaced
  to the user. The jsonl itself is never mutated (append-only + cursor,
  not clear-on-read).
- `failures` — single integer, the current task's tool-failure count.
  Atomic tmp+mv writes (the `queue.state` pattern).

Existing inputs consumed, no changes needed: `context-pct` (stamped by
cs-statusline) and `limits` (`five_hour_used_pct` + `stamped_at`, stamped
by cs-statusline since the cs-usage feature — bin/cs-statusline:118,122).

### Circuit breakers (hooks/narrative-reminder.sh, draining branch)

The drain advances in exactly one place — the Stop hook's draining branch
(narrative-reminder.sh:68+). Breakers evaluate there, after the pop of the
completed task and before injecting the next one:

1. **Failures**: `failures` ≥ `CS_QUEUE_MAX_FAILURES` (default 5).
2. **Context**: `context-pct` ≥ `CS_QUEUE_MAX_CTX` (default 85).
3. **Five-hour window**: `five_hour_used_pct` from `limits` ≥
   `CS_QUEUE_MAX_5H` (default 85) — only when `stamped_at` is fresh
   (within 1800s). A stale stamp skips this breaker silently rather than
   tripping on old data (the event set stays at the approved five; the
   blind spot is documented under Risks).

Trip action: set `queue.state` to `idle` (the existing fail-safe pattern),
append `breaker_tripped` to the inbox with the reason and the readings,
and emit a `block` debrief naming what tripped, the reading vs threshold,
and how many tasks remain. The `queue` file is left intact — `cs -queue
start` re-arms after the user has looked.

Counter lifecycle: the armed→draining transition (narrative-reminder.sh:58-66)
zeroes `failures`; each drain advance zeroes it again after evaluating the
breaker. "Per task" needs no tool-success hook — the reset rides the drain
itself.

Failure producer: hooks/tool-failure-logger.sh already fires on every
PostToolUseFailure and appends to session.log; it additionally increments
`failures` (read-add-one, tmp+mv). It stays non-blocking and silent.

Threshold parsing is defensive: a non-numeric env override falls back to
the default rather than erroring inside a hook.

### Inbox writers

All five events are written by code that already runs at the right moment:

- `drain_started` — armed→draining transition (narrative-reminder.sh).
- `task_done` — each drain advance, with the popped task text.
- `breaker_tripped` — the trip path above.
- `drain_finished` — the queue-emptied path, with done count.
- `gate_declined` — `run_queue`'s `defer` subcommand (lib/55-queue.sh:62),
  beside the existing `queue.declined` stamp.

A tiny shared append helper lives in each writer's own file (two writers:
the Stop hook and lib/55-queue.sh) — hooks are standalone scripts that
cannot source bin/cs, so the jq append line is duplicated by necessity,
matching how queue-file access is already duplicated between the hook's
awk and bin/cs's helpers (documented dual-reader constraint).

### Inbox surfacing

- **Digest, once**: unseen entries (lines past the `notifications.seen`
  cursor) are summarized and injected as context, then the cursor
  advances. Two injection points, whichever fires first:
  hooks/scope-prompt.sh (UserPromptSubmit `additionalContext`, beside the
  attention-marker clear at :16) and hooks/session-start.sh (startup and
  resume context). The digest is short — counts by event plus the last
  breaker reason if any: `While you were away: 4 tasks done, 1 breaker
  trip (context 91% >= 85%). cs -queue log for detail.`
- **`cs -queue log`**: pretty-prints the full inbox oldest-first
  (timestamp, event, detail per line), reads via jq, empty inbox prints
  `No queue activity recorded.` It does NOT advance the cursor — the
  cursor tracks only what was auto-surfaced. `run_queue`'s usage string
  gains `log` (start/defer stay deliberately undocumented there — they
  are agent-facing); both completion files' `queue_cmds` gain `log`;
  help and README updated.

### Storage classification (multi-user law)

Three new files, all under `.cs/local/` (already gitignored by every
session's `.gitignore`): machine-local, no sync, no merge semantics. No
git-synced write path is added anywhere.

## Testing (TDD, vertical slices)

Bash (`tests/test_queue_supervision.sh`, driving the hooks and bin/cs the
way tests/test_hooks.sh drives them — hooks invoked directly with stdin
JSON and `CLAUDE_SESSION_*` env):

1. Failure counter: tool-failure-logger increments `failures`; the count
   survives multiple failures; armed→draining zeroes it; each drain
   advance zeroes it.
2. Failures breaker: with `failures` at the threshold, the draining Stop
   parks to idle, leaves `queue` intact, appends `breaker_tripped` with
   reason `failures`, and the block reason names the threshold. Below
   threshold: drain proceeds, no entry.
3. Context breaker: `context-pct` at/over threshold parks; under does not;
   missing/non-numeric `context-pct` never trips.
4. Five-hour breaker: fresh `limits` over threshold parks; stale
   `stamped_at` (>1800s) skips silently and drains on (no inbox entry);
   missing `limits` never trips.
5. Env overrides: `CS_QUEUE_MAX_FAILURES=2` trips at 2; non-numeric
   override falls back to the default.
6. Inbox events: drain_started on arm→drain flip; task_done carries the
   task text (a task containing quotes/backticks survives the jq append);
   drain_finished on empty; gate_declined on `cs -queue defer`.
7. Surface-once: unseen entries appear in scope-prompt's
   additionalContext once, cursor advances, second prompt injects
   nothing; session-start path mirrors this.
8. `cs -queue log`: prints all events oldest-first; empty inbox message;
   cursor unchanged by log. Completions drift guard picks up `log`; help
   test.

Full gates: `bash tests/run_all.sh` + `cd tui && cargo test` (unchanged,
regression only).

## Risks

- **Hook-side duplication is the price of standalone hooks**: the jq
  append recipe exists in two writers; a format change must touch both
  (same standing constraint as queue-file access). The spec's field list
  above is the shared contract.
- **Signal freshness**: `context-pct` and `limits` are only as fresh as
  the statusline's last render. The five-hour breaker guards with
  `stamped_at` and goes silently blind when the stamp is stale (no inbox
  noise; the failures and context breakers still stand watch).
  `context-pct` has no stamp, but it is rewritten every render and a
  drain implies active rendering — accepted as-is (same trust the
  existing 60%-gate warning already places in it).
- **Two processes touch `failures`** (failure logger increments, Stop hook
  resets): both use atomic tmp+mv writes; a lost increment under exact
  concurrency degrades the breaker by one count, never corrupts state.
- **Digest injection points already emit context** (scope grounding,
  resume context): the digest appends to existing `additionalContext`
  payloads rather than replacing them — the plan must splice, not
  overwrite.
- **Hyrum**: `cs -queue list` output, the gate's wording, and the drain's
  block phrasing are observable; breakers add a new debrief message but
  do not alter existing message shapes.
