# /finish skill — design

Date: 2026-09-12
Status: draft for Alex's review
Decision trail: brainstormed with Alex 2026-09-12; an 8-provider council endorsed an
integrate/retire split (`.claude/council-cache/council-agents-1789239422.md`); a Codex
adversarial review and a Codex validation pass struck every retire-side guarantee of that
split; a 5-provider council then validated the narrowed integrate-only shape and added the
temp-merge gate (`.claude/council-cache/council-1789241548.md`). Every claim below that
names a line number was checked against the source at `c74237f`.

## Context and goal

Closing out a feature worktree today is one atomic verb, `cs <base> --merge <task>`
(`lib/30-worktree.sh` `merge_worktree_session`): it refuses unless every lock but the invoking
base's own is dead, refuses dirty trees, `git merge --no-edit`s the branch (or, when the branch
is already an ancestor of base HEAD, prints "already merged; cleaning up" and skips the merge,
lines 390–391), fuses the feature's `.cs/` records into the base, `git worktree remove --force`s
the feature directory, and deletes the branch. The `/merge` skill wraps it in gates. Because the
verb deletes the feature session's working directory, it cannot run while that session is a live
conversation — which is Alex's first complaint. The second is that `/merge` should make landing
a feature easy; the third is that cs should know whether a GitHub PR exists for a worktree
branch, so nothing is landed twice or forgotten. Features land both ways: a local merge into the
base, or a PR merged remotely. The ask is "as automated and safe as possible", and: no new cs
verbs — solve it as a slash command.

The July 2026 in-session merge design rejected splitting integrate from cleanup because a
"fuse now, remove later" state needed durable pending state and idempotent fusion. This design
does not reopen that: **it never removes anything**. It adds integration while the feature
stays open and leaves retirement exactly as it is, until a separate preservation-first spec
rebuilds it.

## Decisions

1. **`/finish [feature]` replaces `/merge`.** It integrates and reports; it retains every
   worktree and branch. `skills/merge` is retired through `RETIRED_SKILLS`.
2. **Retire is unchanged.** `cs <base> --merge <feature>` keeps its name, semantics and
   feature-closed precondition. `/finish` tells the user when the verb is safe to run and when
   it is not (see Squash below). Preservation-first retirement is out of scope here.
3. **The invariants live in cs, not in prose.** `skills/finish/scripts/finish.sh` (shipped via
   `CS_SKILL_FILES`) discovers gates, queries `gh`, and reports; the mutation itself is one
   unadvertised cs entry, `cs <base> -integrate-feature <task> <sha>` (no help text, no
   completions, no README), so there is exactly one implementation of lock, dirt and merge
   logic — Alex's choice over a self-contained script or a sourced library.
4. **Gate the merge result, never a live tree.** In a temporary detached worktree of base HEAD,
   merge the captured feature SHA, run the repo's gates there, then `git merge --ff-only` the
   result into base. The fast-forward is the atomic "base has not moved" check; a red gate
   leaves base untouched; no gate ever runs in the live base or the live feature worktree.
5. **Mutation only from the owning base conversation.** Invoked from a feature session, the
   skill prints the hand-off (`run /finish <feature> in <base>`) and stops; the feature stays
   open. Ownership is the existing exact-name-plus-ancestor signal
   (`lib/15-lock.sh` `session_lock_owned_by_invoker`, lines 200–203); a live foreign base is a
   refusal.
6. **Both landing paths end the same way.** Local: merge the captured SHA. PR merged remotely:
   merge the PR's `mergeCommit` as an ordinary merge — never `--ff-only` the whole remote base,
   which stops working the first time a local integrate puts a commit on base that origin lacks.
7. **PR state is reported, never acted on destructively.** Three states — none, `<STATE> #N`,
   unknown-with-reason — and a `gh` failure is never read as "no PR".
8. **`--no-ff`, with an already-integrated pre-check.** The merge commit is made in the temp
   worktree and names the feature; it is the audit trail `/finish` has, since it fuses no
   records, and it gives the verb's ancestor check something to find at retire time. When the
   captured SHA is already an ancestor of base HEAD, report "already integrated" and do nothing.
9. **Dirt is reported, not hidden.** Uncommitted files in the feature worktree at capture time
   are listed as "NOT part of this integrate". Today's verb refuses dirt; silence would be a
   regression.
10. **The autosave hook gets two fixes it needs regardless.** It reads the `cs-base` label
    (`hooks/autosave-commits.sh:110`) *after* writing the tree, so a HEAD that moves mid-snapshot
    mislabels the snapshot; capture HEAD first. And it takes the same `mkdir` mutex the
    integrate entry holds, skipping (never waiting) when busy.

## What cs itself changes

"Only a slash command" is true of the surface, not of the diff. Every file cs touches:

| file | change |
|---|---|
| `lib/30-worktree.sh` | new `integrate_feature_worktree` behind the hidden `-integrate-feature` entry: ownership + dirt + temp-merge + gates + ff-only |
| `lib/99-main.sh` | dispatch the hidden entry; no help, no completion, no README |
| `hooks/autosave-commits.sh` | capture HEAD before the tree write; acquire the integrate mutex inside `autosave_to_shadow_ref`, skip when busy |
| `lib/75-launch.sh:274` | kick string `/merge <feature>` → `/finish <feature>` |
| `lib/00-header.sh`, `install.sh` | `CS_SKILLS` += finish, `RETIRED_SKILLS` += merge, `CS_SKILL_FILES` += `finish/scripts/finish.sh` |
| `skills/finish/SKILL.md`, `skills/finish/scripts/finish.sh` | new |
| `tests/test_merge_skill.sh` → `tests/test_finish_skill.sh`, `tests/test_worktrees.sh`, `tests/test_hooks.sh` | pins below |
| `tui/src/ui.rs:954`, `docs/` | the Merge mode's meaning changes (below) |

## Mechanism

### The hidden entry: `cs <base> -integrate-feature <task> <sha>`

Runs in the base checkout. In order; every refusal is an `error` with the exact next command.

1. Resolve `<base>` and `<task>`; require the worktree `$SESSIONS_ROOT/<base>@<task>` to be
   registered in the base's `git worktree list` (the same check `_worktree_features` makes).
2. Ownership: base lock absent, dead, or owned by the invoker per
   `session_lock_owned_by_invoker`; anything else refuses. The feature lock is **not** a
   blocker — integrate never touches the feature worktree.
3. `<sha>` must be reachable from `cs/<task>` (`git merge-base --is-ancestor <sha> cs/<task>`)
   and must not already be an ancestor of base HEAD (then report "already integrated", exit 0).
4. Base tracked tree clean (`_tree_is_dirty`); no `MERGE_HEAD`/rebase in progress.
5. Take the mutex: `mkdir "$(git rev-parse --git-common-dir)/cs/integrate.lock"`; refuse if
   it exists (an unexplained stale lock is a refusal, never stolen — the message names the path).
   `trap` removes it on every exit.
6. Record `B=$(git rev-parse HEAD)`. Create the temp worktree with hooks suppressed:
   `git -c core.hooksPath="$empty" worktree add --detach "$tmp" "$B"` where `$empty` is a
   fresh `mktemp -d` directory (`/dev/null` is not a directory on BSD); init submodules if
   `.gitmodules` exists. The temp dir is under `$(git rev-parse --git-common-dir)/cs/finish/`, so
   it is on the same filesystem and never inside any session directory.
7. `git -C "$tmp" merge --no-ff --no-edit -m "Merge feature <task> (<sha7>)" <sha>`. With
   `--from-remote` the merge is `--no-edit` without `--no-ff`: the landing commit already
   exists on origin and names the PR, so a fast-forward is the right shape there. A conflict
   is a refusal: report the conflicting paths, remove the temp, base untouched.
8. Run the gates in `$tmp` (the command string comes from the skill, see below); red is a
   refusal with the gate output, temp removed, base untouched.
9. `R=$(git -C "$tmp" rev-parse HEAD)`; **before** removing the temp,
   `git merge --ff-only "$R"` in base. If base moved since `B` this refuses; report "base moved
   during gates; re-run". Only then `git worktree remove --force "$tmp"`.
10. Append a `feature-integrated` event (`task`, `sha`, `result`) to `.cs/timeline.jsonl` and
    print a machine-readable summary line the skill parses: `integrated <task> <sha> -> <R>`.

Tracked-`.cs` mode: the merge in step 7 carries `.cs/` on the branch exactly as the verb's merge
does today, and the same `MEMORY.md merge=ours` warning is printed when the branch changed it
(the check at lines 393–399 moves into the shared path). Nothing else is fused.

### The skill: `skills/finish/SKILL.md` + `scripts/finish.sh`

`finish.sh` is the deterministic front half; the model discovers the gates and makes the
decisions the design leaves to a human.

1. **Context.** From the workspace: base session vs feature session (`.cs/local/state`
   `cs_base`, `task_branch`). In a feature session with no argument: print the hand-off and
   stop. In the base with an argument: proceed. An ordinary non-cs feature branch keeps the old
   skill's context 2 (plain `git merge --no-ff` after gates) — that path is unchanged.
2. **Capture.** `F=$(git -C <wt> rev-parse HEAD)`; require `HEAD` to be `cs/<task>`; record
   `git -C <wt> status --porcelain` for the dirt report.
3. **PR lookup.** `gh pr list --repo <owner/repo from origin> --head cs/<task> --state all
   --limit 100 --json number,state,url,mergeCommit,mergedAt,baseRefName,headRefOid,
   headRepositoryOwner,isCrossRepository`. Filter to PRs whose `headRepositoryOwner` matches
   the resolved repository (a fork's same-named branch is not this PR). Outcomes:
   - no match → `none`;
   - one `MERGED` (newest `mergedAt` when several) → PR path;
   - an `OPEN` PR → report; local integrate needs explicit confirmation (AskUserQuestion);
   - `CLOSED` unmerged → report as closed, treat as `none` for the decision;
   - `gh` absent, unauthenticated, offline, timeout (10 s), or ambiguous → `unknown: <reason>`;
     local integrate proceeds only after the same confirmation as OPEN. A repo whose `origin`
     is not GitHub skips the lookup and says so.
4. **Gates.** Discovered as the old skill does (project instructions first, then the
   conventional entry points). The command string is passed to the hidden entry; the entry runs
   it, the skill never runs gates in a live tree.
5. **Local path.** `cs <base> -integrate-feature <task> $F -- <gate command>`.
6. **PR path.** `git fetch origin`; `M=<mergeCommit>`; require `M` reachable from
   `origin/<baseRefName>` and `<baseRefName>` to be the branch checked out in base; then
   `cs <base> -integrate-feature <task> $M -- <gate command>` — the entry accepts any commit
   reachable from `origin/<baseRefName>` for this path (flag `--from-remote`), and the same
   temp-merge/gates/ff-only apply. After it lands, report whether `F` is an ancestor of the new
   base HEAD: yes → "landed"; no (squash or rebase merge) → the Squash notice.
7. **Report.** Always ends with: what landed (`sha → result`), commits on `cs/<task>` after `F`
   ("not integrated"), the dirt list, the PR line, and the retire line — either
   `close the feature session, then: cs <base> --merge <task>` or the Squash notice.

### Squash-merged PRs (measured)

After a squash merge, `cs/<task>` is not an ancestor of base, so today's verb would
`git merge --no-edit cs/<task>`. Probed 2026-09-12 in a throwaway repo: with no further commits
on base this merges clean as a redundant merge commit (no content duplication); with base moved
after the squash — the normal case — it **conflicts** and leaves the base checkout with
`MERGE_HEAD`, which the verb reports as "Merge conflicts in <base>; resolve and commit (or
git merge --abort)". So the retire line for this case is:

> PR #N landed as a squash; `cs/<task>` is not an ancestor of base. Do **not** run
> `cs <base> --merge <task>` — it will try to merge the branch again. Continue on a new task;
> retirement of this worktree waits for the preservation-first retire spec.

No coverage inference, no reset, no deletion.

### The autosave hook

In `autosave_to_shadow_ref` (the backgrounded function, `hooks/autosave-commits.sh:134`), first
thing: `base=$(git rev-parse -q --verify HEAD)`, then
`mkdir "$GIT_COMMON/cs/integrate.lock" 2>/dev/null || return 0` (skip this snapshot; a snapshot
taken mid-merge is garbage anyway). The body after the `mkdir` runs in a subshell with
`trap 'rmdir "$GIT_COMMON/cs/integrate.lock"' EXIT`, so every existing `return 0` path releases
it. The tree write is labelled with that captured `base`, never a later `rev-parse`.
`GIT_COMMON` is `git rev-parse --git-common-dir` — not the per-worktree `--git-dir` the hook
derives at line 44 — and the entry uses the same expression, so both sides compute one path.
Acquiring inside the backgrounded function, not at the hook's top, is what closes the
check-then-fork window.

### `-finish` and the TUI

`cs <base> -finish <feature>` keeps its shape and now means "open the base and integrate
`<feature>`, keeping everything". The TUI's `Mode::Merge` footer (`tui/src/ui.rs:954`,
`Enter:finish`) is already the right word; its readiness column keeps `_feature_readiness`'s
states, whose `ready` now reads as "retire-ready" — the skill is what tells the user whether
integrate is also possible. Adding an integrate-readiness column to `-features` porcelain is
out of scope.

### The temp worktree and the CoW memo

The temp checkout is a plain worktree of base HEAD, so it carries no untracked build cache; on
this repo that is a 6–8 s cold `cargo build` per `/finish`, measured in
`.cs/research/worktrees-cow.md`. The C3 shape there (one `clonefile(2)` of the build directory
plus an mtime restore) is the optimisation if that ever matters; it is not part of this spec.

## SKILL.md outline (the plan carries the full text)

- frontmatter: `name: finish`, `disable-model-invocation: true`, description naming integrate
  and PR reporting, and that nothing is removed.
- Prerequisites: base session or hand-off; `finish.sh` present; gates discovered.
- The ritual: capture → PR lookup → gates+merge via the entry → report. The skill never runs
  `git merge` itself against a cs worktree; it never runs gates in a live tree.
- Squash notice, keep-working advice (`git merge <base>` in the worktree; never rebase once a
  PR exists; after a squash land, continue on a new task).
- Never: push; `-D`; merge over dirt; mutate a live foreign base; delete anything; copy `.env`
  or untracked inputs from a live tree into the temp; treat a `gh` failure as no PR.
- After a green integrate: offer `/checkpoint <feature>-integrated`; print the retire line.

## Out of scope

- Preservation-first retirement (archive-then-destroy). Next spec; `/finish` depends on nothing
  in it.
- Squash-aware retire.
- A PR or integrate column in `-features` porcelain and the TUI.
- Carrying build caches into the temp worktree.
- Multiple concurrent integrates of one base (the mutex serialises; a second invocation
  refuses).

## Testing

`tests/test_worktrees.sh` (the hidden entry, real git fixtures, `CS_TEST_SYNC=1` for the hook):
- after a `--no-ff` integrate, `cs <base> --merge <task>` takes the ancestor path and merges
  nothing (the load-bearing local happy path);
- already-integrated SHA → exit 0, no commit;
- dirty base → refusal, base HEAD unchanged; foreign live base lock → refusal;
- base moved between gate start and ff → refusal names "base moved", temp removed, base HEAD
  unchanged;
- red gate → refusal with output, base HEAD unchanged, no temp worktree left in
  `git worktree list`;
- conflict in the temp merge → refusal naming the path, no `MERGE_HEAD` in base;
- stale mutex directory → refusal naming the path;
- `--from-remote` with a commit not reachable from `origin/<base>` → refusal.

`tests/test_hooks.sh`:
- `cs-base` equals HEAD at hook start when HEAD moves during the snapshot;
- hook skips when the mutex exists and writes no ref.

`tests/test_finish_skill.sh` (contract pins, as today's `test_merge_skill.sh`): frontmatter;
user-invoked only; both manifests; the ritual teaches capture, temp-merge via the entry, the
three PR states, the squash notice, and the never-list; `lib/75-launch.sh` kicks `/finish`.

`tests/test_install.sh`: `finish/scripts/finish.sh` ships executable; `merge` is retired.

## Files

- `lib/30-worktree.sh`, `lib/99-main.sh`, `hooks/autosave-commits.sh`, `lib/75-launch.sh`
- `lib/00-header.sh`, `install.sh` (manifests)
- `skills/finish/SKILL.md`, `skills/finish/scripts/finish.sh`; `skills/merge/` removed
- `tests/test_worktrees.sh`, `tests/test_hooks.sh`, `tests/test_finish_skill.sh`,
  `tests/test_install.sh`
- `docs/hooks.md` (autosave contract), `README.md`, `CHANGELOG.md` (Unreleased)
