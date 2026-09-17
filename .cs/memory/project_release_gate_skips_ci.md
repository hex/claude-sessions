---
name: release-gate-skips-ci
description: "FIXED 2026-08-10: /release Step 0b pushes and waits for CI on the release CONTENT before the tag. Alex's preferred shape since 2026-09-02: skip the third local full run, push the release commit, gate the tag on the Test workflow's five jobs for that SHA. Plain `bash` here is 5.x while the floor and macos-latest are 3.2."
metadata: 
  node_type: memory
  type: project
  originSessionId: 4d3668b9-bb52-46a6-8897-6639b749b244
  modified: 2026-08-10T09:04:03.628Z
---

The `/release` runbook's Step 5 says "run the full test suite" and means
`bash tests/run_all.sh` on this machine. It never inspects GitHub Actions. So a
required lane can be red for weeks and every release still reports green.

It did: `test-windows-msys` broke on 2026-08-04 and `v2026.8.5`, `v2026.8.6`
and `v2026.8.7` all shipped with it failing. v2026.8.7 additionally introduced
four newly-red suites that the local gate could not see.

**Two independent blind spots, both real:**

1. **CI is never consulted.** Check `gh run list --workflow=test.yml --branch main`
   before believing a release is clean, and read the JOB conclusions. A run
   whose only failing job is `cancelled` is a platform verdict, not a code one.
2. **The local shell is not the target shell.** `bash` on this machine is
   Homebrew 5.3.9; the documented floor is 3.2 and `macos-latest` runs 3.2.57.
   Run `/bin/bash tests/run_all.sh` explicitly, because bash 5 hides real 3.2 defects
   (e.g. `command -v` answering from the hash table, which a one-command
   `PATH=` assignment does not invalidate in 3.2 but does in 5).

**How to apply:** treat "all suites passed" as an incomplete claim until you
have named the shell it ran under and looked at the CI run for the commit.
Before tagging, run the suite under `/bin/bash` AND check the Test workflow on
`main`. Lanes cs cannot run locally (Git Bash) are only ever verified by CI, so
pushing and reading the run is the check, not an afterthought.

**FIXED on 2026-08-10 — the runbook now has the guard.** `.claude/commands/release.md`
gained a Step 0b: push anything unpushed, wait for `test.yml` on `HEAD`, read
every JOB conclusion (an overall "success" is not enough), and confirm the run's
`headSha` is the commit being released from. v2026.8.12 was the first tag cut
from content CI had already judged.

The recurrence that forced it: v2026.8.10 and v2026.8.11 were BOTH tagged on
commits whose CI then went red, and both were repaired by the very next commit —
so `main` looked healthy while the *tags* pointed at red. Both failures were
Linux-only and neither could reproduce on a macOS dev box: a signed-`pid_t`
split in `kill` (macOS refuses an out-of-range pid, Linux wraps it onto -1 and
succeeds), then a SIGPIPE race in `assert_output_contains` that only lost on a
2-core runner. Local green is one platform's opinion, and this repo's local
platform is the one that hides Linux defects.

Related: [[windows-support-state]] for which suites are currently red there,
[[feedback-background-the-ci-poll]] for not foreground-polling the lane, and
[[pipefail-sigpipe-early-exit]] for the second of the two failures.

**Extension (2026-09-02, the local gate is optional once CI covers the SHA):**
Alex, mid-release, on the THIRD local 63-suite run of the day: "doesnt the
full gate run on ci as well?" then "kill the local gate". The Test workflow
runs the same suites on ubuntu and macos-latest under bash 3.2, so the local
run adds nothing but time once the release commit is pushed. Validated shape:
run only the touched suites locally under `/bin/bash`, commit and push the
release commit, poll `test.yml` on that SHA in the background, and create the
tag/`gh release` only after all five jobs are green. The tag is the
irreversible step, and gating it on CI is stricter than Step 0b's
content-before-tag rule, not looser. Related: [[feedback-background-the-ci-poll]].

**Extension (2026-09-03, v2026.9.7): /release Step 4's review pass earns its place on the release's own content.** Four quality agents over `v2026.9.6..HEAD` found two live defects in code the release was about to ship — a runner whose two copies of one predicate silently swallowed a single suite's output, and a test asserting the developer's environment — plus measured cleanups. Neither is a correctness bug of the kind Step 4b hunts, and both had passed four full local gates and a green CI run. Run the pass on the committed range when the working-tree diff is only the version bump; that diff is not the release.


**Extension (2026-09-16, v2026.9.16):** the content push went red on macos-latest for a bash-3.2
`unbound variable` that ghost (bash 5.3) cannot see; fixed, re-pushed, CI green, then released.
When a session-state commit sits on top of the "Release vX" commit, tag the release commit with
`gh release create vX --target <FULL sha>`; a short sha fails with "target_commitish is invalid".
The tree difference between the two commits was `.cs/` only, so the CI run on the push head still
judged the release tree. See [[full-gate-runs-on-ghost]].
