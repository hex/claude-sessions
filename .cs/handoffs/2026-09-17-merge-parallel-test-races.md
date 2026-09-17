---
parent: 655bde7e-d351-4345-a86e-24ba3c1e59b2
created: 2026-09-17T09:30:00Z
purpose: collect the two in-flight reviews of fix/parallel-test-races, fold anything material, then offer Alex the merge gate
status: unconsumed
---

## 1. Next Step

Two adversarial reviews of **fix/parallel-test-races at f40497c** were still
running when this conversation rotated. Collect both, fold anything material
(new commit + a fresh ghost run on the landing sha), then take the merge to
Alex with **polish-first as the first option** (`feedback_polish_before_merge`).

- **Codex round 4**, dispatched through the `/codex:` plugin
  (`Agent` tool, `subagent_type: "codex:codex-rescue"`). Its completion
  notification may already be gone with this conversation; if nothing arrives,
  re-dispatch the same brief — it is in
  `scratchpad/review/prompt3.md` plus the round-4 additions listed in section 6.
- **A fresh unnamed Fable review agent** on the final sha, brief in section 6.
  A NAMED teammate `fable-review` was dispatched first and **vanished from
  `ListAgents` without ever reporting** — do not wait on a named one again.

Alex gates the merge. Nothing is pushed; main is 5 commits ahead of origin and
unreleased, and he has NOT asked for a release.

Standing gates, unchanged:
- Every `tests/test_*.sh` run goes to ghost, never here:
  `ssh ghost@ghost 'rm -f ci/claude-sessions/suite.status' </dev/null` then
  `bash ~/.claude/plugins/cache/hex-plugins/claude-tmux/2026.9.1/scripts/remote-tests.sh --host ghost@ghost </dev/null`,
  polled in a background loop. The suite is 67; ghost keeps ONE `suite.log`.
- `./build.sh` before committing whenever `lib/` changed (CI fails on drift).
- Ghost is bash 5.3 and cannot see a bash-3.2 defect; probe with `/bin/bash -u -c`.

## 2. Settled and rejected

**The branch: 8 commits over main `2ce9b0f`, ghost 67/67 on every code sha.**

- `ec9388e` — tui (#609). Two races.
- `b5ea183` — the two ghost flakes (#638).
- `55343f6` → `f87090b` → `5713e71` → `f40497c` — the integrate lock (#603),
  three review rounds deep.
- `9bb1475`, `c950373`, `f6f12a3` — build, narrative, handoff stamp.

**Rejected, with the reason each lost:**

- **#609: "a background thread outlives its test".** The handoff that opened
  this conversation asserted it. Wrong: every cs fork in the tui is
  synchronous. The real cause is
  `enter_runs_the_action_belonging_to_the_highlighted_row`, which presses Enter
  on EVERY `MENU_ITEMS` row — including Archive and Secrets, which fork cs —
  while holding no lock and setting no `CS_BIN`. It forked whichever recording
  stub a concurrent test had set. With no stub it forked the REAL
  `cs -archive alpha` against Alex's sessions on every `cargo test` run.
- **#638: "not the SIGPIPE class".** I ruled it out on a 3000-iteration probe
  that passed. The probe was wrong, not the hypothesis: its match sat at the
  END of the string, so the producer had finished writing. **Rule worth
  keeping: a `printf|grep -q` probe for this class must put the match EARLY and
  keep the producer writing.** Instrumenting the real test on a loaded ghost
  caught `PIPESTATUS=141 0`.
- **#603: `pgrep -f 'cs .*-integrate-feature'`** — answers for any integrate on
  the machine, so a fixture's orphan lock read as held whenever another suite
  was landing.
- **#603: `kill -0` alone** (round 1 → 2) — EPERM for a holder owned by another
  user read as stale.
- **#603: `ps -p`** (round 2 → 3) — procps exits 1 for a live pid it cannot read
  under a restricted `/proc`, so exit 1 was not evidence of absence and the
  `rm -r` advice could fire on a live holder. The `CS_PS_BIN` seam went with it.
- **Rejected for the in-flight preview test: waiting on the real worker.** The
  render's re-request queues a fresh read to the same worker; under load both
  land in one drain and the fresh one is cached legitimately, so the assertion
  fails on correct behaviour.

## 3. Conversation-only facts

Everything here exists nowhere else.

- **MEASURED, #609 before/after.** The pair
  `archive_key_archives_the_selected_session` + `enter_runs_the_action...`:
  **24/30 red before, 0/30 after**. `a_preview_in_flight_when_rotate_runs...`
  under `--test-threads=1` with six `yes` hogs: **1/25 red before, 0/25 after**.
  Full `cargo test` 3 × 348 green.
- **MEASURED, #638 on ghost (macOS 26.6.2, bash 5.3.9, 16 cores), 12 CPU hogs.**
  Before: `test_run_all` 2/20, `test_scope_prompt` 1/20. (A third scope
  failure in the first sweep was MY kill of a duplicate loop, not a flake —
  the honest before is 2/20 and 1/20.) After: **0/20 and 0/20.**
  The instrumented run: 3 failures in 40, one at an instrumented site with
  `PIPESTATUS=141 0`; the other two at sites my `perl` instrumentation missed
  (the backslash-continuation form).
- **MEASURED, the bash `kill -0` verdict table, identical on bash 3.2 (local)
  and 5.3 (ghost), `LC_ALL=C`:** self → rc 0, empty message; pid 1 → rc 1,
  `kill: (1) - Operation not permitted`; 99999999 → rc 1,
  `kill: (99999999) - No such process`; 999999999999 → rc 1,
  `kill: 999999999999: arguments must be process or job IDs`. That last one is
  what the "unknown" test uses.
- **MEASURED, cleanup idempotence (bash 3.2, sourced probe):** the pre-`f87090b`
  body removes a successor's lock on the second pass (`successor-REMOVED`); the
  new one keeps it (`successor-kept`).
- **MEASURED: `ps -p 1` exits 0 on this Mac and on ghost**; `ps -p 99999999`
  exits 1 on both. Codex's round-3 objection was about procps under a
  restricted `/proc`, which neither machine has — I could not falsify it
  locally and took the argument on its merits.
- **Codex behaviour, this conversation:** a raw `codex exec` **stalled on
  "Reading additional input from stdin"** until the call added `</dev/null`.
  Alex then said, verbatim: *"when we use codex we should use it with the
  plugin /codex:"* — recorded as memory `feedback_codex_via_plugin.md`
  (`/codex:` plugin: `codex:rescue` skill, `codex:codex-rescue` agent; never a
  raw `codex exec` from Bash).
- **Alex's only other words this conversation:** none. The rest was the wake.
- **A peer session named `claude` messaged twice about cs-statusline**, and
  Alex has seen it and agrees it is mine (per that peer). Measurements, theirs:
  under the sidebar bridge each tick is ~34-35 execs of which ~14 are the
  render; the render alone is 6-8 execs without `CS_STATUSLINE_PARENT` and
  8-12 with it — **so no fork diet is needed on the render path** (#632 already
  did it). The problem is `cs-statusline --refresh-usage` (spawned at
  `bin/cs-statusline:1685`): two ticks measured **492 and 408 execs in ~3 s,
  of which find×481 and find×400** — ~150 find/s. An orphaned worker at
  `ppid 1` ran 1m23s. Filed as **task #642, not started**; suspects are the
  three sweep finds at `bin/cs-statusline:1161-1165` being re-entered and the
  worker's lifetime not being tied to its render. I told them I would not start
  it on a peer's word, only Alex's.
- **Counts:** ghost ran 6 times today, 67/67 on every code sha (one red run in
  between was my own uncommitted-tree sync, not a defect). Codex: 3 raw rounds
  (FIX, FIX, FIX) + round 4 via the plugin, in flight. Fable: 1 named agent
  lost, 1 unnamed in flight.

## Completeness (pass one)

Written from live context at ~80%, no compaction. Pass one carries everything
that dies with the conversation; pass two appends the recoverable sections.
