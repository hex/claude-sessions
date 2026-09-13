---
name: finish
description: Integrate a finished feature into its base while the feature conversation stays open - capture the feature commit, merge base+feature in a temporary worktree, run the repo's gates there, fast-forward the base, and report GitHub PR state. Removes nothing; retirement stays with cs <base> --merge. Invoke when the user asks to finish, land, or integrate a feature or worktree.
disable-model-invocation: true
---

Finishing is a ritual, not a git command: capture, gates on the merged
result, land, report. This skill integrates work that is already reviewed
to the user's standard; it is the mechanical closer, not a review. It
**removes nothing**: the feature worktree, its branch and its session all
remain until the user retires them with `cs <base> --merge <task>`.

## Detect the context

Run `~/.claude/skills/finish/scripts/finish.sh prepare [feature]` from the
workspace and read its `key: value` lines.

1. **`role: feature`** — this workspace is a cs feature worktree. Print the
   `handoff:` line verbatim (`run /finish <task> in session <base>`) and stop.
   Integrate mutates the base and runs only from the base's own conversation;
   this session stays open.
2. **`role: base` with a task** — the invocation named a feature
   (`/finish fix-auth`, which is what `cs <base> -finish <feature>` arms from
   the TUI picker). Follow **The ritual** below with the keys `prepare`
   printed. An `error:` line is a stop: print it and stop.
3. **`role: base`, `cs_session: yes`, no task** — a cs base session with no
   feature named. Run `cs <base> -features`, show the list, and ask which
   feature to finish (AskUserQuestion). Never enter **Plain branch** from a
   cs session, whatever branch it is on: that path checks out another branch
   and deletes the current one.
4. **`role: base`, `cs_session: no`, non-default `base_branch`** — an
   ordinary checkout on a feature branch, not a cs session. Follow **Plain
   branch** below; it is the one place this skill runs gates in a live tree
   and deletes a branch, both scoped to that ordinary checkout.
5. Otherwise (default branch, nothing named) say there is nothing to finish
   and stop.

## Discover the gates

Project instructions govern absolutely. Read the project's instruction
files — CLAUDE.md and anything it imports, CONTRIBUTING.md, the README's
development section — for build steps, test commands and generated
artifacts. A repo that generates a file from source fragments needs its
build run BEFORE tests, exactly as its instructions say.

Without instructions, use the first conventional entry point that exists:
`tests/run_all.sh`, a `Makefile` test target, `package.json` scripts.test,
`cargo test`, `go test ./...`, `pytest`. If none exists, ask the user once
for the gate command and use it for the rest of the conversation.

The gate is passed to cs as words after `--`, never as a shell string. Two
commands become `-- sh -c 'first && second'`.

## The ritual

1. **Capture.** From `prepare`: `sha` is the feature commit this integrate
   will land — nothing committed after it is included. If `dirt_count` is
   not 0, list every `dirt:` path under the heading
   "NOT part of this integrate" before doing anything else. Never stash,
   commit or copy them.
2. **PR state.** Read `pr_state`:
   - `none` — proceed with the local path.
   - `MERGED` — the PR path (step 4). `pr_merge_commit` and `pr_base_ref`
     are the inputs.
   - `OPEN` — report `pr_url`. A local integrate now would land work whose
     PR is still open; ask with AskUserQuestion (integrate locally anyway /
     stop) and proceed only on an explicit yes.
   - `CLOSED` — report it as closed-unmerged; treat as `none`.
   - `unknown` — report `pr_reason` verbatim. Same AskUserQuestion as OPEN
     before any local integrate. Never treat a gh failure as no PR.
   - `skipped` — origin is not GitHub; say so, local path.
3. **Local path.** Run, from the base session:
   `cs <base> -integrate-feature <task> <sha> -- <gate command words>`.
   cs merges base HEAD and `<sha>` in a temporary detached worktree, runs
   the gate there, and fast-forwards the base onto the result; a red gate,
   a conflict, or a base that moved leaves the base untouched and the
   message names the next command. The skill never runs `git merge` against
   a cs worktree and never runs gates in a live tree. Two outcomes:
   `integrated <task> <sha> -> <result>` or `already-integrated <task> <sha>`.
4. **PR path.** `git fetch origin`. Confirm `base_branch` equals
   `pr_base_ref`; if not, stop and say which branch to check out. Then
   `cs <base> -integrate-feature <task> <pr_merge_commit> --from-remote -- <gate command words>`.
   The same temporary detached worktree, gate and fast-forward apply. When
   the base has nothing origin lacks this fast-forwards onto the PR's
   landing commit and makes no new commit; when the base already carries a
   local integrate, cs makes one merge commit joining the two histories.
   If `pr_head_oid` differs from the captured `sha`, say so: the PR landed
   an older or newer tip than the worktree holds now.
5. **Report.** Run
   `~/.claude/skills/finish/scripts/finish.sh report <base> <task> <sha>`
   and end with, in this order: what landed (`sha -> base_head`); the
   `not_integrated` count ("N commits on cs/<task> after the captured
   commit are NOT integrated"); the dirt list; the PR line; and the
   `retire:` line verbatim. When `landed: no` after a PR path, the retire
   line is the **squash notice** — print it exactly; do NOT run
   `cs <base> --merge <task>` for this task and say why: the branch is not
   an ancestor of base, so the verb will try to merge it again.

## After a green integrate — offers, not actions

- Offer `/checkpoint <feature>-integrated`.
- If the project instructions document a deploy step, offer it (one
  question). Never deploy unprompted.
- Keep-working advice for the feature session: `git merge <base branch>`
  in the worktree brings the landing back; never rebase once a PR exists;
  after a squash landing, continue on a new task.

## Plain branch

An ordinary checkout on a non-default branch, not a cs worktree. A clean
tree is required (`git status --porcelain` empty; offer to commit, stop if
declined). Preflight gates on the branch; `git checkout <target>`, then
`git merge --no-ff <branch>` with a message summarising the feature; gates
again on the merged result; delete the merged branch with `git branch -d`
only when the post-merge gates are green. Ask when the target is ambiguous.

## When a gate fails

Diagnose it — that is why this is a skill and not a script. Find the root
cause per the project's debugging rules, fix forward on the feature branch,
and re-run the ritual from the top: the capture takes the new commit. Never
bypass, skip, or weaken a gate.

## Never

- Never push, to any remote — publishing is the user's decision.
- Never delete anything in a cs session: no worktree removal, no
  `git branch -d` and never `git branch -D` on a cs branch, no
  `cs <base> --merge` on the user's behalf. (**Plain branch** on an ordinary
  checkout may `git branch -d` a merged branch after green gates.)
- Never merge over dirt or copy `.env`/untracked inputs into the temp.
- Never mutate a live foreign base: the entry refuses; do not work around it.
- Never treat a gh failure as no PR.
- Never run gates in a live cs tree; the entry runs them in the temp.
  (**Plain branch** runs them in its ordinary checkout, as before.)
