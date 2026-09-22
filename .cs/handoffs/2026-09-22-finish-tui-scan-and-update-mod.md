---
parent: 871dc9b2-d6e5-4018-8128-0c5bb4019329
created: 2026-09-22T11:23:18Z
purpose: Hand two built branches (fix/tui-scan-off-render-thread, feat/update-mod) through Alex's /codex:review and /finish; then the git-config follow-up or the rotate polish on Alex's yes
status: consumed
consumed_by: 524ba3e7-6207-4c5a-af51-85392a3f541f
---

# Continuation: finish the TUI scan fix and the cs-update mod

You have zero memory of the previous conversation. Everything you need is
here plus the 2026-09-22 entries in
`.cs/memory/narrative.hex-users-noreply-github-com.md` (measurements,
traps, rulings) and the earlier handoff
`.cs/handoffs/2026-09-22-finish-cs-update-mod.md` (consumed; still the
full record for the cs-update mod branch).

## 1. Next Step

Nothing to build. Two branches are BUILT, installed, and waiting on Alex:

1. `fix/tui-scan-off-render-thread` (3 commits over main `7bb472a`:
   `43f2357`, `2e162e3`, plus the CHANGELOG commit if it landed separately;
   check `git log main..fix/tui-scan-off-render-thread`). This is the one
   currently checked out and installed (`~/.local/bin/cs-tui` copied by hand
   from `tui/target/release/cs-tui`; `cs -doctor` drift OK).
2. `feat/update-mod` (head `fcee081`, the cs-update mod; 16 commits over
   `7bb472a`; see the consumed handoff for its rulings).

Alex runs `/codex:review` and `/finish` on each; you cannot. When a Codex
review lands, fold its findings in one fix dispatch, re-run the touched
suites, reinstall, hand back. For the TUI branch the suite is
`cd tui && cargo test` (349 tests) plus `cargo clippy --release` (8
pre-existing warnings on main; anything above 8 is yours).

BEFORE Alex runs `/codex:review --base main --scope branch`: the untracked
`scratchpad/` at the repo root makes the native reviewer stop and ask
"may I leave the untracked scratchpad/ untouched?" (measured this morning,
exit 0, no findings). Move it aside first:
`mv scratchpad /private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/871dc9b2-d6e5-4018-8128-0c5bb4019329/scratchpad-repo`
and move it back after. Do NOT pass free text to `/codex:review`; the
companion treats any non-flag word as focus text and exits 1 ("does not
support custom focus text"). Flags are `--base <ref> --scope branch
--wait|--background`.

After a merge of the TUI branch: `rm -rf .superpowers/sdd/2026-09-22-cs-update-mod`
is still pending from the update-mod branch's own merge (its ledger is in
git by then). Then install from main and confirm `cs -doctor` shows no drift.

If Alex says yes to a follow-up instead, the two candidates, in order:

- Read `.git/config` in-process instead of forking `git remote get-url
  origin` per checkout session (91 of 139 sessions here; `parse_git_remote`
  in `tui/src/session.rs` ~line 1008). Removes the 91 forks per rescan.
  Worktrees: `.git` is a FILE with `gitdir: <path>`; follow it, then
  `commondir` if present, then read `config`. Keep `is_git_checkout`.
- The startup scan in `tui/src/main.rs:35` still runs on the main thread
  before the first frame; same ~14 s cost on a loaded machine.
- Rotate polish (native task #664) only on Alex's explicit yes; design is
  in the narrative entry "cs-update mod: feasibility read from the contract".

## 2. Settled and rejected

- ROOT CAUSE (measured): the picker's 10 s rescan forks `git remote get-url`
  once per checkout session across a 14-thread pool
  (`std::thread::available_parallelism`). One fork = 0.76 s wall under load
  (timed directly). A scan took ~14 s; REFRESH=10 s is measured from scan
  START, so the next scan began ~1 s after the previous ended: the picker
  was inside `scan_sessions` ~14 of every 15 s. Key presses queued until it
  returned. Evidence: scratchpad/tui-kids.tsv (10 Hz single-fork probe,
  190 rows/45 s: `0 0 0 0 0 0 14 14 ... 12 11 10 ... 1 1 1 14 14 ...`).
- My first sampler LIED: it forked once per child per tick, so a "tick"
  was 1.5-4 s and I reported a "5.5 s cadence". Corrected in the narrative.
  Rule: probe with one fork per sample (`ps -axo ppid=` + grep).
- The fix: scan worker thread (request/drain/swap, mirrors the preview
  worker in `tui/src/app.rs`). `auto_refresh` only sends a request;
  `drain_scans` in the loop swaps the result and pins the selection by
  name; `accept_scan` drops a result whose generation is not the pending
  one. Four user-triggered rescans (delete, batch delete, rename, archive)
  go through `rescan_now`, which runs synchronously and clears the pending
  generation, so a worker read that predates the change never puts a
  deleted row back. `scan_sessions_in` became `pub(crate)` because the
  worker must scan the root captured at `App::new` (the test root override
  is thread-local and invisible on the worker).
- REJECTED (advisor caught it, first cut `43f2357` had it): putting
  `scan_pending` into `has_timed_state`. That made `is_animating` true for
  the whole scan, so the loop painted at 10 fps for ~14 s with nothing to
  show. Fixed in `2e162e3`: `scan_in_flight()` only shortens the poll
  timeout; `else if animating { redraw }` is untouched; `drain_scans` is
  the sole repaint trigger for a result.
- Measurements, same machine, same probe (scratchpad/tui-ab.sh, 30 Down
  presses via tmux send-keys on a throwaway pane, load avg ~18): pre-fix
  max 936 ms mean 128 ms (three stalls >340 ms during bursts); fixed max
  145 ms mean 65 ms, no stall. Idle CPU 60 s: pre-fix 5.6% of a core
  (loaded sample, 119 s), fixed 2.5% (settled). The 14 s scans happen when
  the machine is loaded, which is Alex's normal state (several claude
  sessions); on a quiet machine a scan is ~1-2 s.
- MEASUREMENT TRAP: at load avg 148 (a cargo build running) each probe
  primitive (tmux capture-pane, perl, ps -ax) cost 300-650 ms, so a latency
  run taken then read 400-1800 ms and measured the probe, not the TUI.
  Before/after must run back to back on a settled machine.
- zsh trap hit again: `set -- $r` does not word-split in the Bash tool's
  zsh; use `read -r a b < <(...)` inside a bash script.
- Tests: the calling-thread assertion in
  `auto_refresh_rescans_and_keeps_selection_by_name` was watched go red by
  mutating `auto_refresh` back to synchronous (perl one-liner, then
  restored, restore verified by grep count 0). Stale-drop test
  `a_rescan_superseded_by_rescan_now_is_dropped`. 349/349.
- Vale on CHANGELOG.md: only line 10 (my entry) is mine; the hook re-lints
  the whole file and prints ~600 pre-existing alerts. Line 10 is clean.
- `/codex:review on feat/update-mod` failed (focus text); with
  `--base main --scope branch --background` it ran but stopped on the
  untracked scratchpad/ (see Next Step).

## 3. Primary Request and Intent

Alex's words, in order, this conversation: "how can we do a perfomance test
for our TUI, I think it's resource heavy"; "live tui"; "done" (opened the
picker); "it freezes when I move with arrow keys for example"; "let's do
both" (trace the cadence AND build fix 1). Before that, the rotation wake
executed the consumed handoff's next step: Codex review of feat/update-mod
(Alex ran `/codex:review on feat/update-mod`, then
`/codex:review --base main --scope branch --background`; both reported
above). Alex also set the session colour to red.

## 4. Key Technical Concepts

- Measured on Claude Code 2.1.278, cs TUI (ratatui 0.29 / crossterm 0.28):
  `run_event_loop` in `tui/src/main.rs` blocks on `event::poll(timeout)`;
  timeout is HEARTBEAT 100 ms while animating or a scan is in flight, else
  the time to the next REFRESH (10 s). `is_animating` = shimmer while
  recently active OR `has_timed_state` (status, flashes, revealed secret,
  delete countdown, pending previews).
- `read_queue`/`queue_active` in `tui/src/ui.rs` ~1792 do directory reads
  inside every frame while the queue panel is open (read in source, not
  measured, left alone).
- A single `git -C <checkout> remote get-url origin` = 0.76 s wall on the
  loaded machine (measured), Xcode's git shim.
- 139 session dirs, 91 with `.git` (counted).

## 5. Files and Code Sections

- `tui/src/app.rs`: `spawn_scan_worker`, fields `scan_pending: Option<u64>`,
  `scan_generation`, `scan_requests`, `scan_results`; `auto_refresh`,
  `scan_in_flight`, `drain_scans`, `accept_scan`, `rescan_now`;
  `wait_for_scan` (cfg(test)); two tests named above.
- `tui/src/main.rs`: timeout uses `app.scan_in_flight()`; `drain_scans`
  before the REFRESH check.
- `tui/src/session.rs`: `pub(crate) fn scan_sessions_in`.
- `CHANGELOG.md`: new `## Unreleased` / `### Performance` entry.
- Probes (untracked, scratchpad/ at repo root): tui-sample.sh (wall-clock
  cpu/rss/children), tui-kids.sh (10 Hz child count), tui-keys.sh
  (press/latency), tui-ab.sh (before/after runner); data tui-idle*.tsv,
  tui-kids*.tsv, tui-keys-*.tsv.

## 6. Problem Solving

Gate provenance for the TUI branch: cargo test 349/349 on both code
commits; clippy 8 warnings = main's 8; release build clean; doctor drift
OK; advisor review folded (one blocking finding, fixed and re-measured).
Not run: tests/run_all.sh (no bash surfaces touched), ghost (remote-tests
has no host store on claude-tmux 2026.9.1).

## 7. Pending Tasks

Native list (survives /clear): #663 completed (cs-update mod BUILT,
unmerged); #665 completed (cadence traced); #666 in_progress (TUI scan
fix BUILT, unmerged, awaiting Codex + finish); #664 pending (rotate polish,
awaiting Alex's yes); #606, #554 parked. Also unmerged from earlier:
`fix/rotate-prune-snippet` (`43a71bd`).

## 8. Current Work

Handoff written at ~71% context right after reporting the TUI fix with the
before/after table. Nothing in flight; no agents, no tmux throwaway
sessions (tuiperf killed), no worktrees (tui-before removed). Narrative has
today's entries uncommitted (autosave covers it; commit with this handoff).
