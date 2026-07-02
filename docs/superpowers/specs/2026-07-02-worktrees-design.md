# Worktrees in cs: parallel task sessions — design

Date: 2026-07-02
Status: approved sections, pending final spec review
Decision trail: brainstormed with Alex; approach validated by a 4-provider AI
council (grok, codex, perplexity unanimous for Approach A; antigravity
first-round concurred). Full analyses: `.claude/council-cache/council-agents-1782993567.md`.

## Context and goal

Alex wants to run two or more concurrent Claude sessions on the same project,
each working a different task, each with full cs tooling (hooks, artifacts,
narrative, statusline, secrets, memory), and merge results back without losing
the multi-user story. Today cs actively prevents this: a PID lock forbids
opening a session twice, and cs has zero awareness of git worktrees — three
hooks silently no-op in linked worktrees (`-d .git` tests a file), the autosave
shadow ref `refs/cs/auto` is repo-global, and artifact-tracker teleports
script/config writes into the main session's `.cs/artifacts` regardless of cwd.

The enabling insight: cs's multi-machine merge contract (tracked durable state
with merge drivers — `merge=union` for logs/narratives/timeline, jq driver for
MANIFEST.json, `merge=ours` for MEMORY.md — plus untracked machine-local
`.cs/local/`) is exactly the partition a worktree needs. A linked worktree is
"another machine's clone that shares the object store": git materializes the
tracked half in every checkout and the untracked half stays per-checkout.

One caveat discovered during spec review: not every session tracks `.cs/`. An
adopted repo may gitignore it wholesale — the cs dev repo itself does
(.gitignore:18) — so the design defines two modes: **tracked-`.cs`** (state
forks with the branch, git drivers fuse it at merge) and **ignored-`.cs`**
(each worktree bootstraps its own untracked `.cs/`; `--merge` fuses records
explicitly, applying the same semantics the drivers would have).

## Decisions (approved by Alex 2026-07-02)

1. **One session identity, N worktrees** — not N independent sessions. The
   session keeps one name, memory, notebook, and task list; each worktree is a
   parallel working copy on its own branch.
2. **Explicit user-invoked merge-back** — `cs <session> --merge <task>`. Never
   automatic, never at session end. Honors the v2026.6.9 removal of
   auto-commits to real project branches.
3. **Native Claude worktrees (EnterWorktree, Agent isolation:'worktree') get
   "safe + sane defaults"** — cs stops corrupting/surprising them (artifact
   path guard, namespaced autosave refs, worktree-tolerant `.git` checks) but
   does not manage their lifecycle.
4. **Approach A: a worktree IS a session directory** — `cs myproj@fix-auth`
   creates a real directory `$SESSIONS_ROOT/myproj@fix-auth` via
   `git worktree add`; every existing per-session mechanism engages unchanged.
   Council-validated: no surveyed tool (Claude Code `--worktree`, Claude Squad,
   stravu/crystal, VS Code, jj workspaces) uses a subordinate-registry model.

## Non-goals

- No automatic commits of session or project state, ever (preflights refuse
  dirty trees instead).
- No management of native/ephemeral harness worktrees beyond not breaking them.
- No push/pull automation; sharing stays manual git, as today.
- No per-task splitting of narrative files or artifact directories in v1
  (union-merge scrambling across same-actor parallel tasks is accepted;
  revisit if it bites).
- No TUI redesign; `@`-sessions appear as ordinary entries.

## Design

### Lifecycle

**Create/open: `cs myproj@fix-auth`**

- Name parser: split on the first `@`; both halves must pass the existing
  session-name regex (`^[a-zA-Z0-9._-]+$`, bin/cs:637). `@` is currently
  rejected in names, so no existing session can collide with the new syntax.
- Preconditions (create): base session `myproj` exists and has a git repo; the
  invocation targets the base checkout (worktree-of-a-worktree is refused);
  base checkout is clean, else refuse — `git worktree add` materializes
  committed state only, and a dirty base would silently not carry over
  (commit-boundary problem).
- Create: `git -C <base> worktree add -b cs/fix-auth "$SESSIONS_ROOT/myproj@fix-auth"`.
  If branch `cs/fix-auth` already exists (e.g. fetched from a teammate), reuse
  it (`git worktree add <path> cs/fix-auth`) — teammates meeting on the same
  branch is the correct semantic for a shared task. If the branch is checked
  out in another local worktree, git refuses; surface that error verbatim.
- Placement: a real directory directly under `$SESSIONS_ROOT`, no symlink.
  Sibling of the session dir — the parent's `git add -A` can never reach it
  (nested-checkout mangling avoided by construction). Applies identically to
  adopted sessions (their `.cs/` is committed at adopt time, bin/cs:2861-2867,
  so the checkout carries session state).
- First open: initialize `.cs/local/` (fresh conversation UUID, color, lock)
  and pin `task_branch: cs/fix-auth` in `.cs/local/state`. On every open,
  compare `git rev-parse --abbrev-ref HEAD` against the pinned branch; warn
  loudly on mismatch (someone ran `git switch` inside the worktree).
- Open thereafter: identical to opening any session (resume prompt, UUID
  rebind, migrate_session), because the worktree IS a session dir.

**Merge-back: `cs myproj --merge fix-auth`**

Preflights, in order, each refusing with a specific message:
1. No live session holds the worktree's PID lock (and none holds the base's).
2. Worktree checkout is clean (uncommitted task work cannot merge; tell the
   user what to commit — cs does not commit for them).
3. Base checkout is clean.
4. Merge drivers are configured in repo config (they are per-clone config, not
   tracked; run setup_merge_attributes first — matters on a teammate's fresh
   clone).

Then, in the base checkout:
5. `git merge cs/fix-auth` — union/jq/ours drivers re-fuse timeline,
   narratives, MANIFEST.json. On conflict: stop, leave everything in place,
   list conflicted paths.
6. If the task branch modified `.cs/memory/MEMORY.md`, warn that merge=ours
   discarded those index lines (memory *files* survive; they are new files)
   and show how to import manually.
7. `git worktree remove "$SESSIONS_ROOT/myproj@fix-auth"` (git refuses if
   unclean; we verified clean in step 2), then `git branch -d cs/fix-auth`
   (delete only after worktree removal; git enforces the order), then a
   timeline event recording the merge.

Manual-merge reconciliation: if the user merged `cs/fix-auth` by hand, `--merge`
detects "branch already merged" (`git merge-base --is-ancestor`) and skips to
cleanup (7).

**Ignored-`.cs` repos (e.g. the cs dev repo, .gitignore:18):**

- Create: the worktree materializes without `.cs/`; first open detects this and
  bootstraps a fresh untracked `.cs/` via the existing
  `create_session_structure` path (README stub naming the base session and
  task, fresh `.cs/local/`, empty manifest, narrative file). Full cs tooling
  works from the first prompt.
- Merge (replaces step 5's driver reliance for `.cs` records; code still merges
  via git as normal): `--merge` fuses the worktree's session records into the
  base's `.cs` explicitly, mirroring driver semantics — append `timeline.jsonl`
  and `session.log` (union), append per-actor `narrative.*.md` bodies (union),
  jq-merge `MANIFEST.json` (same dedupe as the driver), copy new memory files
  and artifacts (skip collisions with a warning; never overwrite). MEMORY.md
  index lines from the worktree are reported, not merged (parity with
  merge=ours).
- The clean-worktree preflight applies to *tracked* files only in these repos;
  the untracked `.cs/` is consumed by the fuse step and removed with the
  worktree.
- Dirty-base preflight at create is unnecessary for `.cs` (nothing to carry)
  but still applies to project files.
- Mode detection: `git check-ignore -q .cs` in the base checkout, evaluated at
  create time and recorded in the worktree's `.cs/local/state`
  (`cs_mode: ignored`), so open/merge do not re-derive it against a possibly
  edited .gitignore mid-task.

**Abandon: `cs -rm myproj@fix-auth`**

Extends the existing `-rm` path: `git worktree remove` (with `--force` only if
the user confirms discarding uncommitted work), then prompt whether to delete
the unmerged `cs/fix-auth` branch. Never silent.

### Identity and state partition

| Surface | Worktree session | Rationale |
|---|---|---|
| `CLAUDE_SESSION_NAME` | `myproj@fix-auth` | distinct pill/logs/hook gating |
| Claude conversation | own (cwd-bound transcript discovery) | parallel conversations for free |
| `CLAUDE_CODE_TASK_LIST_ID` | base `myproj` | one shared task list coordinates parallel work |
| Secrets | base `myproj` (`cs:<session>:<name>`, bin/cs-secrets:104) | keychain entries are session-scoped, not task-scoped |
| Tracked `.cs/` | branch checkout | forks with the code, merges back with it |
| `.cs/local/`, PID lock, color | own, fresh | machine-local partition already guarantees this |
| Auto-memory path | own checkout's `.cs/memory` | memory files merge as new files; MEMORY.md caveat above |
| Statusline | own color, `@task` name; git segment already follows cwd | existing machinery, zero change |

### Hook and plumbing changes (fold into existing hooks; no new hooks)

- **autosave-commits.sh**: write `refs/worktree/cs/auto` instead of
  `refs/cs/auto`. Per-worktree refs are git-native isolation — verified
  empirically 2026-07-02 on git 2.50.1: same ref name resolves independently
  per checkout; deletion in one does not affect the other. Replace the
  `[ -d "$SESSION_DIR/.git" ]` guard with a plumbing check
  (`git -C "$SESSION_DIR" rev-parse --git-dir`).
- **session-start.sh / session-end.sh**: same ref rename and guard fix; crash
  detection and cleanup become per-checkout automatically. session-end no
  longer deletes anyone else's autosave chain.
- **Legacy migration**: on resume, if `refs/cs/auto` exists, delete it after
  the first successful `refs/worktree/cs/auto` write (one-time, per clone).
  Doctor's shadow-ref check (bin/cs:1959-1980) follows the new name.
- **artifact-tracker.sh**: redirect a Write into `$CLAUDE_ARTIFACT_DIR` only
  when the resolved target path is inside `$CLAUDE_SESSION_DIR`. Writes
  outside (native harness worktrees, /tmp, other repos) land at the requested
  path untouched. This single guard is the whole native-worktree artifact fix.
- **`.git` shape audit**: replace every `-d .git` / hardcoded `.git/<path>`
  across bin/cs, hooks/, and cs-statusline with `rev-parse --git-dir` /
  `--git-path` / `--show-toplevel`. (cs-statusline already uses `-e`; align it
  with plumbing anyway.)
- **launch_claude_code**: parse `name@task`; export base-session secrets
  namespace and task-list ID; everything else (env, lock, UUID guard, color)
  unchanged — per-checkout by construction.
- **doctor**: three new checks — (a) `$SESSIONS_ROOT/*@*` dir that is not a
  registered worktree of its base (pruned/dangling), (b) `cs/*` branch fully
  merged but its worktree still present, (c) worktree HEAD differs from pinned
  `task_branch`.

### Multi-user and multi-machine semantics

- `.git/worktrees/` registrations are machine-local by git's design (absolute
  paths, never synced) — consistent with the `.cs/local/` philosophy. Nothing
  new to classify.
- The `cs/<task>` branch is the sharing unit: push/pull as today. A teammate
  runs `cs myproj@fix-auth` and gets their own worktree of the shared branch.
  Two machines advancing the same task branch reconcile via the existing
  drivers when they merge — the per-branch version of today's multi-machine
  story.
- Timeline/narrative events from a worktree record that checkout's branch
  (hooks run with `SESSION_DIR` = the worktree), so attribution is correct
  without changes.

## Edge cases and failure modes

- **Dirty base at create / dirty worktree at merge**: refuse with exact paths;
  never commit on the user's behalf.
- **`git switch` inside a worktree**: warn at open (pinned `task_branch`
  mismatch); doctor check (c) catches it between opens.
- **Manual `git worktree remove` or `prune` behind cs's back**: doctor check
  (a); `cs myproj@fix-auth` on a dangling dir offers cleanup + recreate.
- **Worktree-local `git config` writes leak into shared `.git/config`** (all
  worktrees share repo config): cs itself only writes merge-driver config,
  which is intentionally shared. Documented caveat, no code.
- **gc/reachability**: `refs/worktree/*` are real refs and count as
  reachability roots; autosave chains survive gc as they do today.
- **Session lock semantics**: per-checkout lock files mean base and each
  worktree are independently single-occupancy — the original PID lock's
  purpose, preserved.
- **`cs -list` / TUI**: `@`-dirs appear as ordinary sessions (they are);
  annotate with the base name and branch in `-list` output only if trivial.

## Compatibility and constraints

- bash 3.2 + BSD userland throughout (no bash-4 constructs, no GNU-only flags).
- `git worktree` requires git ≥ 2.5; `refs/worktree/*` requires ≥ 2.20 (2018).
  Guard: if `git worktree` is unavailable, `cs name@task` errors with a clear
  message; core cs is unaffected.
- Existing sessions: unaffected until first resume, which migrates the
  autosave ref name. No directory layout changes.
- The 5-site hook registration is untouched (no new hooks; only bodies change).

## Testing (TDD, existing bash harness)

New `tests/test_worktrees.sh`: name parsing (@ carve-out, invalid halves);
create (fresh branch / reuse fetched branch / refuse dirty base / refuse
worktree-of-worktree); open (fresh .cs/local, task_branch pin, mismatch warn);
merge (clean merge fuses union+jq files; refuse dirty worktree/base; conflict
stops and preserves; MEMORY.md warning; already-merged reconciliation; cleanup
order worktree-then-branch); rm (unmerged prompt); doctor (dangling,
merged-but-present, HEAD mismatch). Hook tests extend test_hooks.sh: autosave
writes refs/worktree/cs/auto in both main and linked checkouts without
cross-talk; legacy ref migration; artifact-tracker inside-vs-outside path
guard. Ignored-`.cs` mode: create bootstraps fresh `.cs/`; mode recorded in
local state; `--merge` fuse appends timeline/narrative, jq-merges manifest,
copies memory/artifacts without overwriting, reports MEMORY.md lines. All
tests drive real `bin/cs` against temp dirs with `CLAUDE_CODE_BIN=echo`, per
test_lib.sh conventions.

## Verified assumptions

- `refs/worktree/<name>` isolation and independent deletion: verified
  empirically on git 2.50.1 (scratchpad experiment, 2026-07-02).
- Linked worktree `.git` is a file containing `gitdir:` — confirmed same
  experiment; the `-d .git` hook guards are dead in worktrees today.
- `-adopt` commits `.cs/` into existing repos (bin/cs:2861-2867) — worktrees of
  adopted sessions carry session state — UNLESS the repo gitignores `.cs/`,
  which the cs dev repo itself does (.gitignore:18; discovered 2026-07-02 when
  a narrative commit was refused). Hence the two-mode design.
- Conversation transcripts are discovered per encoded cwd
  (`~/.claude/projects/<encoded-path>/`), so each worktree binds its own
  conversation with no changes.

## References

- Codebase map (5-agent workflow, 2026-07-02): session lifecycle, multi-user
  contract, git usage, Claude integration surface, docs/tests.
- Council analyses and synthesis:
  `.claude/council-cache/council-agents-1782993567.md`.
- Prior art: Claude Code `--worktree`; jj workspaces; Claude Squad;
  stravu/crystal; graphite worktree guidance.
