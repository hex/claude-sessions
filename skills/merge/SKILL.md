---
name: merge
description: Close out a feature branch or cs task worktree - run the repo's gates, merge --no-ff, re-run gates on the merged result, clean up. Invoke when the user asks to merge a branch or worktree, or to close out a finished feature.
---

Merging is a ritual, not a git command: gates before, merge, gates after,
cleanup only when everything is green. This skill closes out work that is
already reviewed to the user's standard — it is the mechanical closer, not
a quality gate or a review.

## Prerequisites

- A clean tree. If `git status --porcelain` shows uncommitted changes,
  offer to commit them first; if the user declines, stop. Never merge
  over an uncommitted tree.
- A context (below). If neither applies — already on the default branch
  with nothing to merge — say so and stop.

## Detect the context

1. **cs task worktree**: the workspace is a cs session named
   `<base>@<task>`, or `git rev-parse --git-dir` differs from
   `git rev-parse --git-common-dir` inside a cs-managed worktree
   session. The merge verb here is `cs <base> --merge <task>` — it
   fuses the session records, merges the branch, and removes the
   worktree. This skill wraps it with gates.
2. **Feature branch**: an ordinary checkout on a non-default branch.
   The target is the branch it forked from — usually the repo's
   default branch (`git merge-base` confirms ancestry); ask the user
   when the target is ambiguous.

## Discover the gates

Project instructions govern absolutely. Read CLAUDE.md (and the rules
it imports) for build steps, test commands, generated artifacts, and
deploy steps — a repo that generates a file from source fragments needs
its build run BEFORE tests and the generated file committed with the
branch, exactly as its instructions say.

Without instructions, use the first conventional entry point that
exists: `tests/run_all.sh`, a `Makefile` test target, `package.json`
scripts.test, `cargo test`, `go test ./...`, `pytest`. If none exists,
ask the user once for the gate command and use it for the rest of the
conversation.

## The ritual

1. **Preflight gates** on the branch (worktree context: inside the
   worktree): the build step first if the repo has one, then the full
   test gate. Everything green before anything merges.
2. **Merge.**
   - Feature branch: `git checkout <target>`, then
     `git merge --no-ff <branch>` with a merge message summarizing the
     feature.
   - Task worktree: run `cs <base> --merge <task>` from outside the
     worktree; it merges and cleans up the worktree itself.
3. **Gates again on the merged result** (worktree context: in the base
   session checkout). A merge that was green on the branch can still
   break the target.
4. **Cleanup**: delete the merged feature branch with `git branch -d` —
   but not until the post-merge gates are green. The worktree verb
   already cleaned up its own.

## When a gate fails

Diagnose it — that is why this is a skill and not a script. Find the
root cause per the project's debugging rules, fix forward on the
branch, and re-run the ritual from the top. A post-merge failure leaves
the merge commit in place: report it with the failing output and let
the user decide between fix-forward and revert. Never bypass, skip, or
weaken a gate to make a merge pass.

## After a green merge — offers, not actions

- If the project instructions document a deploy step, offer to run it
  (one question). Never deploy unprompted.
- In a cs session, offer `/checkpoint <feature>-merged`.

## Never

- Never push, to any remote — publishing is the user's decision, made
  separately.
- Never merge over uncommitted changes.
- Never delete a branch until the post-merge gates are green, and never
  use `git branch -D` on unmerged work.
- Never bypass a failing gate or force a merge.
