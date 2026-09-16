---
parent: e85ddb49-003a-4a7c-993a-f8b8c6da2179
created: 2026-09-16T08:57:10Z
purpose: take the held release v2026.9.16 to Alex's gate, then cut cs-statusline's render cost (#632)
status: unconsumed
---

## 1. Next Step

Nothing is in flight. The session was WRAPPED at 2026-09-16 ~12:00 EEST
(`.cs/summary.md` is current, memory swept, narrative at 121 KB of 224 KB), so
this successor starts clean rather than collecting measurements.

Ask Alex which of the two he wants first, with **AskUserQuestion**, and say in
the question that the release pushes 61 commits:

1. **#622, the held release v2026.9.16.** Run the `/release` skill. Alex's
   shape, from memory `project_release_gate_skips_ci`: skip the repeat local
   suite, push the release commit, and tag ONLY after its CI jobs are green;
   background the CI poll rather than watching it
   (`feedback_background_the_ci_poll`). CHANGELOG's `## Unreleased` folds into
   `## 2026.9.16`; version bump lives in `lib/00-header.sh`; `./build.sh` runs
   last, before the commit (`project_lib_bin_build_drift`). Draft notes from an
   earlier attempt are at
   `/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/<older-uuid>/scratchpad/release-notes.md`
   — that scratchpad is from a conversation two rotations back and may be gone;
   regenerate from the CHANGELOG rather than hunting for it. The content is
   much larger than when those notes were written: main is **61 commits ahead
   of origin** and carries #613, #617-#621, #623, #624, #626, #627, #629 and
   #628. Alex holds for an independent Fable review on every release
   (`feedback_hold_for_adversarial_review`), so budget for that wait.
2. **#632, cs-statusline's render cost.** Task description carries the full
   diagnosis. Measured this session: cs-statusline alone is 0.6-0.7 s per
   render at load 17, and `git status` is the slow stage
   (`bin/cs-statusline:1172`, already capped at 2 s by `_timeout`). Two
   candidate fixes, neither designed yet: cache the git state for N seconds, or
   skip git when the previous render is younger than the refresh interval.
   Also open: whether cs's own recipe should keep `refreshInterval: 1` — only
   the logo's attention pulse needs it (`lib/70-statusline.sh:92-95` and
   `install.sh.in:864-870`, which MUST stay in sync), and the sidebar session
   is recommending 3 to Alex for his own settings.

Either way: **nothing is ever pushed without Alex's word**, and the release is
the one exception where pushing IS the task once he approves.

## 2. Settled and rejected

- **#628 is DONE and merged** (`aa5c44b`, 22 commits, `--no-ff`, branch
  deleted), built, installed, doctor drift OK. #630 rode the same branch and is
  closed. Do not reopen either; the summary has the full story.
- **REJECTED during #628, do not revisit:** judging every conversation by its
  first turn (silences a `/resume` at 72% with the knob at 70 — the case Alex
  asked for); adopting the first id seen after `register()` (a `/clear` before
  any answered turn adopts the wrong conversation); putting the loop guard in
  documentation rather than code (Codex round 2 said plainly that prose cannot
  prevent repeated rotation).
- **The forced rotation stays opt-in.** `CS_ROTATE_FORCE_CTX` unset means the
  mod behaves exactly as it did before. Alex chose "with grace" over
  "force rotate only" when offered the diff.
- **The `/clear`-versus-`/resume` discriminator cannot come from the engine.**
  `SessionEnd`'s `reason` (`clear|resume`) is a SHELL hook input
  (`claude-code.d.ts:7090`, read in source), not reachable from a mod, and no
  `resume` command appears in the `command.run` contract. Observing the id
  change from the `ui.render` hook is what works, because the band draws in a
  new conversation before any of its turns end.
- **The blank status line is NOT a cs bug and not a settings problem.**
  MEASURED this session: `~/.claude/settings.json`'s `statusLine` points at the
  iterm-agents-sidebar bridge at `refreshInterval: 1`; the bridge publishes a
  payload then execs `~/.local/bin/cs-statusline`. Under load 25-32 with ~8
  sessions a render took ~1.6 s and Claude Code KILLS an overrunning render
  (bundle strings `statusLine exited ${...}` and `statusLine tick failed`, read
  in the 2.1.273 binary). An old session keeps its last completed line; a new
  one never lands a first render and shows nothing. Ruled out: no `statusLine`
  key in any `settings.local.json`; `install.sh` at 11:41:57 never replaces a
  foreign statusLine (`install.sh.in:681` reads it and only registers cs's own
  when chosen); the bridge run by hand under the new session's exact
  environment exits 0 with output.
- **The sidebar's half is already fixed** (its session, commit `6fdc188`: raw
  payload with no jq, a trap that removes the temp file, 1,290+ orphaned
  `~/.claude/agents-sidebar-status/<pid>.json.<pid>` files swept). It needs
  nothing further from cs. Do not edit the bridge or `settings.json` from this
  session — that was the agreement over cross-session mail.

## 3. Conversation-only facts

Things with no other home. Each marked by how it was established.

- **MEASURED (live run 2, throwaway session `grace-live2`, knob 10, evidence
  committed at `.cs/research/spike-rotate/grace-evidence/live2/` plus
  `live2/wake/`):** turn 1 ended at 7% → no force, band read
  `1: rotate this conversation`. The heavy read turn ended at 22% → `/rotate`
  submitted by the mod → the real rotate skill wrote, committed and armed
  `2026-09-16-cs-test-suite-orientation.md`, and its own narrative recorded the
  forced prompt as *"Rotated at Alex's request"* — the forced prompt is
  indistinguishable from a typed one to the skill. Band then read
  `1: /clear and continue from the handoff · /clear in 20s` stepping to 4s →
  `❯ /clear` → SessionStart consumed the handoff and rebound
  `claude_session_id` → the wake turn ended at **8%** with NO second rotation
  and the forced marker still holding the old id.
  **Honest caveat to carry forward:** the wake sat below the knob, so the
  threshold alone would have stopped it there. The guard's refuse-and-toast arm
  (a `/clear`-born conversation that already starts past the knob) is proven by
  unit test only, never live.
- **MEASURED (this session):** ghost is green on every sha it was asked about —
  `9bf3054`, `8348e72`, `fc1d0aa`, `5e6da12`, and the landing `08ed9e2`, all
  67/67 exit 0. Ghost runs Claude Code 2.1.72 and has no bun, so the 54 bun
  tests and the `claude plugin validate` inventory pins are proven LOCALLY only
  (bash 5 and `/bin/bash` 3.2). Say that split plainly rather than "67/67
  everywhere".
- **MEASURED (this session):** a mutation can survive because a sibling code
  path masks it. The first "rejected `/clear` leaves no birth" test drove both
  rejection sites in one sequence, and the `command.run` hook's rollback
  covered for the missing rollback in `clearAndContinue`. Split into two tests
  (one per rejection path) and both mutations went red. Six Codex rounds ran in
  total across two conversations; round 6 found nothing new.
- **MEASURED (this session):** the Data volume hit 100% (1.1 GB free) mid-gate
  and the failure surfaced as `ENOSPC` writing a BACKGROUND TASK's output file,
  not as anything obviously disk-shaped. Freed 5.7 GB by deleting
  `/private/tmp/claude-501/<dir>` for sessions with no live claude process,
  judged by `lsof -d cwd`, plus `bash-edit-diff` (763 MB). Untouched and Alex's
  to decide: `~/Library/Application Support` 90 GB, `~/.claude-sessions` 33 GB,
  the fignity scratch 9-12 GB, `~/.claude` 8.2 GB, `~/.cache` 8.1 GB. The bulk
  of the 874 GB used is outside `$HOME`.
- **Alex's own words this session, kept:** *"why do we run tests here?"* then
  *"it hogs the machine"* — said while ONE suite (`tests/test_hooks.sh`, run
  twice for a mutation check) was running locally at load 32. Memory
  `feedback_full_gate_runs_on_ghost` now says a single suite is not an
  exemption either. And *"new opened sessions don't have the status line, why
  is that?"* with a screenshot of session `firstborn` showing `0 tokens` and a
  bare name capsule.
- **The redone red-first check that replaced the local suite:** source
  `tests/test_lib.sh`, `eval` the setup/teardown/test functions out of
  `tests/test_hooks.sh` with sed, run the one pin against the real teardown and
  against a mutated one. One second, no suite. Use that shape again.
- **A tmux oddity noted, not investigated:** the pane for session `firstborn`
  sits in a window named `cs: erpk-ai-costs`.

## 4. What this handoff could not carry

Written from live, uncompacted context at ~41%. Nothing was cut for length. The
session was already wrapped when this was written, so `.cs/summary.md` carries
the narrative version of the same story and this file carries only what the
successor needs to act.
