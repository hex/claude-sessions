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

## 3b. Codex round 4 — arrived while this handoff was being written

Dispatched through the `/codex:` plugin. **Verdict: FIX, NOT CLOSED.** Verbatim
substance, because the report file is not on disk (the plugin returns it in the
agent result, not `scratchpad/review/`):

1. **Important — `lib/60-doctor.sh:664`.** ESRCH proves absence only in the
   caller's PID namespace. The writer records only `$$` (`lib/30-worktree.sh:655`).
   If a checkout is shared with a container, a live holder's recorded pid can be
   absent in doctor's namespace and this branch recommends removing its lock.
   `hidepid` does not block `kill -0`, but PID namespaces still constrain pid
   lookup. Source-checked, not reproduced.
2. **Minor — `lib/60-doctor.sh:660`.** The `LC_ALL=C` prefix does not reliably
   pin bash 3.2's active locale: the prefix is INSIDE the substitution, and
   3.2's temporary-assignment path does not invoke its locale setter
   (bash-3.2/variables.c). Probe under `fr_FR.UTF-8`:
   `$(LC_ALL=C printf "%.1f" 1)` → `1,0`, while `$(LC_ALL=C; printf "%.1f" 1)`
   → `1.0`. The kill.def path itself matches between 3.2 and 5.3 (both print
   `strerror(errno)`), so the wording depends on libc's active locale.
3. **Minor — `tests/test_doctor.sh:1221`.** Pid 1 does not guarantee EPERM
   coverage: a sufficiently privileged caller gets success instead, so the test
   can pass without exercising the EPERM branch.

It confirmed under bash 3.2.57: success for `$$`, EPERM for pid 1, rejection of
`999999999999`, ESRCH for a reaped pid. `bash -n` clean. No suite ran.

**My read, for the successor to accept or overturn:** #2 is the one I would fix
first and it is cheap — move the assignment so it applies to the shell, e.g.
`err=$( LC_ALL=C; kill -0 "$pid" 2>&1 )`, and re-probe on 3.2. #1 is real but
the writer/reader share a checkout and a namespace in every case cs supports
(the shared-with-a-container case is hypothetical here); the honest options are
to record the boot-relative start time beside the pid, or to soften only the
ESRCH advice. #3 is a coverage gap, not a defect. **None of this is a
correctness regression against main**, which used `pgrep` and was strictly
worse. Alex may reasonably take the branch as-is and file the rest.

## 4. Primary Request and Intent

This conversation was woken by a rotation carrying
`.cs/handoffs/2026-09-17-parallel-test-races.md` (now `status: consumed`) and
did exactly what it asked: fix **#609, #603 and #638 in one branch**, in that
order. Alex sent one message in the whole conversation, quoted in section 3.

## 5. Files and Code Sections

Read the diff, not a summary: `git diff main...HEAD` on
`fix/parallel-test-races`. The pieces that matter:

- `tui/src/app.rs` — `CS_BIN_ENV_LOCK` (~2567), `cs_bin()` (14),
  `enter_runs_the_action_belonging_to_the_highlighted_row`,
  `a_preview_in_flight_when_rotate_runs_never_reaches_the_cache`,
  `drain_previews` (777), `request_preview` (756).
- `lib/30-worktree.sh` — `_integrate_cleanup` (~525) and the lock acquisition
  in `integrate_feature_worktree` (~630).
- `lib/60-doctor.sh` — `_doctor_check_integrate_lock` (~634).
- `tests/test_doctor.sh` — four lock tests at the end of the integrate block.
- `tests/test_worktrees.sh` — `test_integrate_cleanup_releases_the_lock_only_once`.
- `tests/test_run_all.sh`, `tests/test_scope_prompt.sh` — every herestring.
- `CHANGELOG.md` `## Unreleased` — three entries added by this branch.
- `scratchpad/review/` (untracked) — `prompt.md`, `prompt2.md`, `prompt3.md`,
  `codex-round1.md`, `codex-round2.md`, `codex-round3.md`, `branch.diff`.

## 6. Problem Solving

The review briefs are reusable: `scratchpad/review/prompt.md` (whole branch),
`prompt2.md` and `prompt3.md` (closures). For a round 4 brief, take prompt3 and
swap in the `kill -0` closure and the three questions Codex answered above.
Reviews name every consumer by path (`feedback_review_names_consumers`).

`git log` carries the rest: each commit body states what it fixed, the
measurement, and the review round that asked for it.

## 7. Pending Tasks

The native task list is keyed to the session and survives the `/clear`.
Reconcile against this list; do not mirror it.

- **#609, #603, #638 — closed this conversation**, all three on the branch.
- **#642 pending, NOT started.** cs-statusline `--refresh-usage` forks find at
  ~150/s (section 3). Needs Alex's go, not the peer's.
- **#640 pending.** Four Minors from the v2026.9.16 release review.
- **#554 pending (PARKED).** SessionStart notice for pending tool calls.
- **#606 pending (POSTPONED).** `cs --remote` via Claude Remote Control.

## 8. Current Work

`fix/parallel-test-races` at `f40497c`, 8 commits over main `2ce9b0f`, ghost
67/67 on every code sha. Codex round 4 in section 3b. One unnamed Fable review
agent was still running at rotation; its brief is section 1's.

Working tree at rotation: `.cs/memory/MEMORY.md` and
`.cs/memory/narrative.hex-users-noreply-github-com.md` modified (the narrative
carries a dated correction to the #638 entry), plus untracked `scratchpad/`.
A new memory file `.cs/memory/feedback_codex_via_plugin.md` was written.

## Completeness (pass two)

Nothing cut. The one thing I could not carry: whether the unnamed Fable agent
ever reported, and what it said.
