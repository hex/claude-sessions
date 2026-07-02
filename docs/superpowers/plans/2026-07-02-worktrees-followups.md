# Worktree feature follow-ups

Source: final whole-branch review of wip/worktrees (merged to main at 05979c2,
2026-07-02). Full triage in that session's SDD ledger. Each item below is a
scoped brief, not started.

## A: Stale worktree registrations

A worktree directory deleted behind git's back (TUI delete, manual `rm -rf`,
`cs -rm` on a severed base) leaves `.git/worktrees/<name>` registered in the
base repo; recreating the same task then fails, and with add/remove stderr
formerly suppressed the error was misleading (stderr now flows, 05979c2).

- Route cs-tui's delete (tui/src/app.rs `execute_delete` and the batch path)
  through `cs -rm` instead of `fs::remove_dir_all`, so worktree sessions
  unregister properly.
- Add a doctor sub-check over `git worktree list --porcelain` for
  registered-but-missing paths, suggesting `git worktree prune`.
- `cs -rm` of an @-dir whose base repo is gone: print prune guidance instead
  of silently falling through to `rm -rf`.
- Opportunistic: flip `grep -qx` to `grep -qxF` in `_doctor_check_worktrees`.

## B: run_test harness fix + suite sweep

`tests/test_lib.sh` `run_test` invokes each test function as an `if`
condition, which disables errexit inside the function body — an `assert_*`
that fails mid-test only registers if guarded with `|| return 1`. Branch-added
tests are guarded; historical suites were never audited.

- Change run_test to run the test as a plain statement in a subshell:
  `set +e; ( set -e; "$test_name" ) 2>&1; local status=$?; set -e` — existing
  `|| return 1` guards keep working, and the subshell stops cd/env leaks
  between tests.
- Sweep all 34 suites for the fallout: benign nonzero commands (bare `grep -q`
  probes, `local x=$(may-fail)`, arithmetic) become failures needing explicit
  `|| true`.
- Fold in: assert session-end deletes refs/worktree/cs/auto (not just the
  legacy name); META_DIR ambient-env gating gap in 3 doctor checks.
- Fold in legacy-ref transition hardening (decided 2026-07-02): during the
  one-upgrade window where a pre-upgrade `refs/cs/auto` may still exist, a
  worktree session's crash-recovery fallback can adopt the BASE's crash ref
  and offer to restore the base's snapshot into the worktree checkout, and
  whichever checkout autosaves first deletes the shared legacy ref before the
  base got its recovery offer. Gate the legacy fallback in
  hooks/session-start.sh to main checkouts only (`[ -d "$SESSION_DIR/.git" ]`
  — a linked worktree cannot have pre-upgrade history) and add doctor
  observability for an un-migrated legacy ref.

## Loose ends (small, no branch needed)

- README says git >= 2.20; `git branch --show-current` needs 2.22 — bump the
  doc or swap to `git symbolic-ref --short -q HEAD`.
- Record two spec deviations in the spec doc: open-time dangling-dir recovery
  descoped to doctor-only; tracked-dirty refusal messages name no paths
  (untracked refusal does, since 05979c2).
- warn()/info() write to stdout repo-wide — any future `$(...)` capture of a
  function calling them corrupts the capture; sweep to stderr needs its own
  pass because existing tests capture warnings from stdout.
