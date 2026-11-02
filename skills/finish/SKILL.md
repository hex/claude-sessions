---
name: finish
description: Land a finished feature in its base and retire its worktree - capture the feature commit, merge base+feature in a temporary worktree (running the repo's gates there only when asked with --gate), fast-forward the base, report GitHub PR state, then remove the worktree and branch, at once or by itself once the feature conversation closes. Invoke when the user asks to finish, land, integrate or retire a feature or worktree.
disable-model-invocation: true
---

Finishing is a ritual, not a git command: capture, merge, land, report,
retire. This skill integrates work that is already
reviewed to the user's standard; it is the mechanical closer, not a review.
The landing never touches the feature worktree. Retirement (fuse its session
records into the base, remove the worktree, delete the branch) runs in the
same ritual. A directory cannot be removed from under a running Claude, so
while the feature conversation is still live the entry stages the retire in
the base instead, and this session's Stop hook runs it by itself once that
conversation closes; the user closes it when they are done there and nothing
else is asked of them. Abandoning a feature instead is `cs -rm <base>@<task>`,
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
   (with `--gate`) and deletes a branch, both scoped to that ordinary checkout.
5. Otherwise (default branch, nothing named) say there is nothing to finish
   and stop.

## Gates are opt-in

`/finish` runs no tests unless the invocation asks for them:
`/finish <task> --gate`, or the user asks in words to run the tests or gates.
Read `--gate` off the arguments before anything else and never pass it to
`finish.sh`. Without it, the gate command words are `-- true` (cs's own
spelling of no gate) in both the local and the PR path, `--ci-green` is never
added, and the report says `gate: none (/finish <task> --gate runs the tests)`.
With it, discover the gates below and pass them instead. The same rule holds
in **Plain branch**.

## Discover the gates

Only with `--gate`. Project instructions govern absolutely. Read the project's instruction
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
   `cs <base> -integrate-feature <task> <sha> -- <gate command words>`
   (`-- true` without `--gate`). cs merges base HEAD and `<sha>` in a
   temporary detached worktree, runs the gate there, and fast-forwards the base onto the result; a red gate,
   a conflict, or a base that moved leaves the base untouched and the
   message names the next command. The skill never runs `git merge` against
   a cs worktree and never runs gates in a live tree. Two outcomes:
   `integrated <task> <sha> -> <result>` or `already-integrated <task> <sha>`.
4. **PR path.** `git fetch origin`. Confirm `base_branch` equals
   `pr_base_ref`; if not, stop and say which branch to check out. Then
   `cs <base> -integrate-feature <task> <pr_merge_commit> --from-remote -- <gate command words>`.
   Without `--gate` the gate words are `-- true` and nothing below about
   `--ci-green` applies. With it, add `--ci-green` after `--from-remote` only when `prepare` reported
   `pr_checks: success`; with `failure`, `pending`, `none` (no checks ran,
   or every one of them was skipped), `unknown` (its `pr_checks_reason`
   says why) or no line, leave it off and say in the
   report why the gate ran. `pr_checks` describes the landing commit
   (`pr_merge_commit`) itself, the check runs and statuses origin recorded
   on it, not the PR head's: a merge commit that took newer base changes is
   a tree the head's checks never ran on. The same temporary detached
   worktree and fast-forward apply. When the base has nothing origin lacks
   this fast-forwards onto the PR's landing commit and makes no new commit,
   and with `--ci-green` cs skips the gate (the report says `gate skipped`:
   that commit's checks passed on origin and there is nothing local to
   test); when the base already carries a local integrate, cs makes one
   merge commit joining the two histories, a tree those checks never saw,
   and the gate runs on it.
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
   - `retire: content-landed` — the branch is not an ancestor of base, but
     every path it changed since it left the base (`retire_paths_checked`
     counts them) is byte for byte on base HEAD, so retiring it loses only
     history. Run `cs <base> -retire-feature <task> <sha> --force`, whatever
     `pr_state` and `pr_head_oid` say, and with no PR at all (a local
     squash or a cherry-pick lands content the same way).
   - `retire: not-landed` — the branch is not an ancestor of base (a squash
     or rebase landing) and base HEAD holds some path it changed
     differently: the `retire_differs:` lines name up to ten, and
     `retire_differs_more:` counts the rest. A captured commit that shares
     no history with base (no merge base) is `not-landed` too, with no
     path lines, since there is no change of its own to compare; what
     follows applies to it with no paths to print. When `pr_state` is `MERGED`
     AND `pr_head_oid` equals the captured `sha`, that is the PR's evidence
     the work is in:
     run `cs <base> -retire-feature <task> <sha> --force`. A `pr_head_oid`
     that differs means the PR landed an older or newer tip than the
     worktree holds, so the branch may carry work the PR never had: print
     both shas and the differing paths, and stop. Any other `pr_state`:
     print `retire_note` and the differing paths, and stop; nothing is
     removed. (The entry refuses a tip past the captured commit unless
     the base already holds that tip; under --force it refuses one even
     then.)
   - `retire: N commit(s) ... not integrated` — print it and stop; the next
     `/finish <task>` captures them.

   The entry answers `retired <task> <sha>`, `staged <task> <sha>: ...`, or
   refuses. `staged` means the feature conversation is still live in the
   worktree: the entry recorded the retire in the base
   (`.cs/local/retire-staged/<task>`), and the base's Stop hook runs it once
   that conversation's lock is gone, with every refusal intact. Relay the
   line and tell the user the worktree and branch go by themselves after
   they close that conversation; nothing else is needed, and a later turn
   here reports `retired` or the refusal. Before `retired` it
   may print `Moved N ignored files to the system trash:` with one line per
   file it moved, and one per directory it moved whole (its path and the
   number of files inside): relay that block whole, since the user's ignored
   files went there. In ignored mode it may also print `The feature's
   <file> is kept at <path>` for the feature's README.md or summary.md:
   relay each such line, since that is where the feature's copy now lives.
   A refusal can carry the same block (`... before this failed:`); print it
   with the refusal. Print a refusal
   verbatim: it is written for the user. Never work around a
   refusal — no `git worktree remove`, no `git branch -d`/`-D`, no signals
   or keystrokes into the other session, and never close the feature
   conversation for the user.
7. **Report.** End with, in this order: what landed (`sha -> base_head`);
   the `not_integrated` count ("N commits on cs/<task> after the captured
   commit are NOT integrated"); the dirt list ("NOT part of this integrate",
   and now gone with the worktree when retirement succeeded — say so); the
   PR line; and the retirement outcome (the `retired` line, the `staged`
   line with the one sentence above, or the refusal and what the user does
   next).

## After a green integrate — offers, not actions

- If the repo has submodules, tell the user to run `git submodule update` in
  the base after a landing: the merge moved the gitlinks, the working
  contents did not follow.
- Offer `/checkpoint <feature>-integrated`.
- If the project instructions document a deploy step, offer it (one
  question). Never deploy unprompted.
- When retirement was staged because the feature conversation is still live
  and the user means to keep working there: `git merge <base branch>`
  in the worktree brings the landing back; never rebase once a PR exists;
  after a squash landing, continue on a new task. The stage still runs when
  that conversation closes, and the entry then refuses a tip past the
  captured commit, so new work there is never lost.

## Plain branch

An ordinary checkout on a non-default branch, not a cs worktree. A clean
tree is required (`git status --porcelain` empty; offer to commit, stop if
declined). With `--gate`, preflight gates on the branch first. Then
`git checkout <target>` and `git merge --no-ff <branch>` with a message
summarising the feature; with `--gate`, run gates again on the merged result
and delete the merged branch with `git branch -d` only when the post-merge
gates are green; without it, delete the merged branch with `git branch -d`
right after the merge. Ask when the
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
re-running gates. Once the user asked for a gate, never bypass, skip, or
weaken it.

## Never

- Never push, to any remote — publishing is the user's decision.
- Never delete anything in a cs session yourself: no `git worktree remove`,
  no `git branch -d` and never `git branch -D` on a cs branch. Removal
  happens only inside `cs <base> -retire-feature`, which stages itself over
  a live conversation and refuses over dirt or a branch the base lacks. (**Plain branch** on
  an ordinary checkout may `git branch -d` a merged branch after the merge,
  and after green gates when `--gate` was given.)
- Never merge over dirt or copy `.env`/untracked inputs into the temp.
- Never mutate a live foreign base: the entry refuses; do not work around it.
- Never treat a gh failure as no PR.
- Never run gates in a live cs tree; the entry runs them in the temp.
  (**Plain branch** runs them in its ordinary checkout, as before.)
