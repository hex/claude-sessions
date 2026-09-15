---
name: finish
description: Land a finished feature in its base and retire its worktree - capture the feature commit, merge base+feature in a temporary worktree, run the repo's gates there, fast-forward the base, report GitHub PR state, then remove the worktree and branch once the feature conversation is closed. Invoke when the user asks to finish, land, integrate or retire a feature or worktree.
disable-model-invocation: true
---

Finishing is a ritual, not a git command: capture, gates on the merged
result, land, report, retire. This skill integrates work that is already
reviewed to the user's standard; it is the mechanical closer, not a review.
The landing never touches the feature worktree. Retirement (fuse its session
records into the base, remove the worktree, delete the branch) runs in the
same ritual, but only once the feature conversation is closed: a directory
cannot be removed from under a running Claude, so while that conversation is
still open the skill says so plainly and the user closes it and runs
`/finish <task>` again. Abandoning a feature instead is `cs -rm <base>@<task>`,
the user's own call.

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

The gate runs in a clean detached checkout of the merged commit, so gitignored
files are not there: installed dependencies, `.env`, build output. When the
project needs an install step before its tests (a lockfile, a `.env.example`,
a vendored directory) and its instructions do not say so, ask the user once
what creates them and fold it into the gate: `-- sh -c 'npm ci && npm test'`.

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
   The same temporary detached worktree and fast-forward apply. When the
   base has nothing origin lacks this fast-forwards onto the PR's landing
   commit and makes no new commit, and cs skips the gate (the report says
   `gate skipped`: the commit passed the PR's CI and there is nothing local
   to test); when the base already carries a local integrate, cs makes one
   merge commit joining the two histories, a tree CI never saw, and the
   gate runs on it.
   If `pr_head_oid` differs from the captured `sha`, say so: the PR landed
   an older or newer tip than the worktree holds now.
5. **Report.** The entry's own summary line says what happened:
   `integrated <task> <sha> -> <result>`, `already-integrated <task> <sha>`,
   or a refusal (a red gate, a conflict, or a base that moved) that leaves
   the base untouched and names the next command. On a refusal, report that
   message verbatim and stop; never run `report` against a base the entry
   never touched.

   Only after an `integrated` or `already-integrated` line, run
   `~/.claude/skills/finish/scripts/finish.sh report <base> <task> <sha>`
   and read its `retire:` key.
6. **Retire.** The worktree goes through one entry and nothing else:
   - `retire: ready` — run `cs <base> -retire-feature <task> <sha>`.
   - `retire: not-landed` — the branch is not an ancestor of base (a squash
     or rebase landing). When `pr_state` is `MERGED` AND `pr_head_oid`
     equals the captured `sha`, that is the PR's evidence the work is in:
     run `cs <base> -retire-feature <task> <sha> --force`. A `pr_head_oid`
     that differs means the PR landed an older or newer tip than the
     worktree holds, so the branch may carry work the PR never had: print
     both shas and stop. Any other `pr_state`: print `retire_note` and
     stop; nothing is removed. (The entry refuses a tip past the captured
     commit under --force as well.)
   - `retire: N commit(s) ... not integrated` — print it and stop; the next
     `/finish <task>` captures them.

   The entry answers `retired <task> <sha>` or refuses. Print a refusal
   verbatim: it is written for the user, and the one that matters most says
   the feature conversation is still open and asks them to close it
   themselves and run `/finish <task>` here again. Never work around a
   refusal — no `git worktree remove`, no `git branch -d`/`-D`, no signals
   or keystrokes into the other session.
7. **Report.** End with, in this order: what landed (`sha -> base_head`);
   the `not_integrated` count ("N commits on cs/<task> after the captured
   commit are NOT integrated"); the dirt list ("NOT part of this integrate",
   and now gone with the worktree when retirement succeeded — say so); the
   PR line; and the retirement outcome (the `retired` line, or the refusal
   and what the user does next).

## After a green integrate — offers, not actions

- If the repo has submodules, tell the user to run `git submodule update` in
  the base after a landing: the merge moved the gitlinks, the working
  contents did not follow.
- Offer `/checkpoint <feature>-integrated`.
- If the project instructions document a deploy step, offer it (one
  question). Never deploy unprompted.
- When retirement was refused because the feature conversation is still
  open and the user means to keep working there: `git merge <base branch>`
  in the worktree brings the landing back; never rebase once a PR exists;
  after a squash landing, continue on a new task.

## Plain branch

An ordinary checkout on a non-default branch, not a cs worktree. A clean
tree is required (`git status --porcelain` empty; offer to commit, stop if
declined). Preflight gates on the branch; `git checkout <target>`, then
`git merge --no-ff <branch>` with a message summarising the feature; run
gates again on the merged result; delete the merged branch with
`git branch -d` only when the post-merge gates are green. Ask when the
target is ambiguous.

## When a gate fails

Diagnose it — that is why this is a skill and not a script. In the ritual
above, the base session has no checkout of the feature branch to fix
anything in: report the gate's output and stop, and never reproduce or
patch the failure locally against the base or its temp worktree. The fix
lands in the feature session, or the user makes it directly; once it
lands, re-run `/finish` from the top and the new capture picks it up. In
**Plain branch**, this checkout already holds the branch, so find the root
cause per the project's debugging rules and fix forward here before
re-running gates. Never bypass, skip, or weaken a gate.

## Never

- Never push, to any remote — publishing is the user's decision.
- Never delete anything in a cs session yourself: no `git worktree remove`,
  no `git branch -d` and never `git branch -D` on a cs branch. Removal
  happens only inside `cs <base> -retire-feature`, which refuses over an
  open conversation, dirt, or a branch the base lacks. (**Plain branch** on
  an ordinary checkout may `git branch -d` a merged branch after green
  gates.)
- Never merge over dirt or copy `.env`/untracked inputs into the temp.
- Never mutate a live foreign base: the entry refuses; do not work around it.
- Never treat a gh failure as no PR.
- Never run gates in a live cs tree; the entry runs them in the temp.
  (**Plain branch** runs them in its ordinary checkout, as before.)
