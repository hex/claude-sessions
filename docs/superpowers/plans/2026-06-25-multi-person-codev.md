# Multi-Person Co-Development Awareness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cs` aware that multiple people can co-develop in one project whose `.cs/` is committed to git, so each person's contributions are attributed and visible — without reintroducing any networked coordination.

**Architecture:** Identity comes from git (`user.name`/`user.email`), wrapped in a thin local shim so it survives shared machines / CI / mismatched emails. The `.cs/` tree splits into *shared* (committed, attributed) and *per-actor* (a single gitignored `.cs/local/` directory). The real leak-guard is **staging discipline** — cs never runs `git add .cs`, it allowlist-stages shared files and refuses to run if `.cs/local/` is tracked. Visibility (memories index, on-resume digest, `cs -who`, TUI) is pure async *attribution* derived from git history — never live presence.

**Tech Stack:** Bash (must run on macOS stock `/bin/bash` 3.2), git plumbing, BSD `sed`/`tr`, the existing `tests/test_lib.sh` harness, Rust/ratatui for the TUI (Phase 4 only).

## What lives where (locked)

| Shared — committed, attributed | Local — `.cs/local/`, gitignored, per-machine |
|---|---|
| `memory/*.md` (durable memories, `author:` stamped) | `session.lock` (a lock can't be shared) |
| `MEMORY.md` (tracked index, `merge=ours` + regen) | `watermark` (each actor's private "last seen" SHA) |
| `CLAUDE.md` (project instructions) | cooldown markers (local reminder throttles) |
| narrative journal `journal/<actor-slug>/*.md` (per-actor files, committed) | `logs/`, `timeline.jsonl` (verbose machine noise/bloat) |

`.cs/local/` holds only what is *impossible* to share (lock, per-clone watermark) or pure machine noise. Everything representing a person's thinking or learning — memories and narrative — is shared.

## Global Constraints

- **bash 3.2 floor:** no `local -A`, no `printf '%(...)T'`, no `${var^^}`, no `mapfile`/`readarray`. Use `tr`/`sed` for case and substitution. Hooks/statusline run under minimal-PATH `/bin/bash`.
- **macOS BSD tooling:** `sed -i ''` (not `-i`); prefer POSIX BRE; avoid GNU-only flags.
- **NEVER `git add -A` / `git add .cs`** when staging session metadata — stage by explicit allowlist only.
- **No auto-commit:** session-end must not commit (removed in v2026.6.9 — keep it removed). Shared `.cs/` changes are committed only on explicit user action.
- **No network/presence:** all collaboration features derive from local git state. Never imply "online"/"active now"; use "recent activity"/"since your last session".
- **Naming/comments:** files start with two `# ABOUTME:` lines; names describe purpose, not history; no "new"/"legacy"/"improved" in names or comments.
- **Index decision (locked):** `MEMORY.md` index IS tracked in git (browsable on GitHub), made conflict-safe via deterministic ordering + `merge=ours` + regenerate-after-merge.
- **Memory mutation (locked):** memories stay **mutable / edit-in-place** (today's behavior). No append-only-supersedes ledger.
- **Actor slug:** filesystem-safe, lowercase, `[a-z0-9-]` only; derived by `_slugify`.

---

## Phasing Overview

This plan delivers **Phase 1 (foundation)** in full, bite-sized TDD detail — it ships working, testable value on its own (identity + `.cs/local/` + leak guard) and every later phase depends on its interfaces. Phases 2–4 are a roadmap; each gets its own detailed plan once its predecessor lands, because their exact code depends on Phase 1's landed function names and the directory contract.

- **Phase 1 — Foundation:** actor identity resolver, `.cs/local/` dir, gitignore, staging guard, `cs whoami`. *(this document, detailed)*
- **Phase 2 — Attributed shared state:** `author:` frontmatter on memories, tracked/derived `MEMORY.md` with `merge=ours` + regenerate-after-merge, per-actor maildir narrative journal. *(roadmap)*
- **Phase 3 — Visibility:** per-actor watermark, on-resume digest (session-start hook), `cs -who`. *(roadmap)*
- **Phase 4 — Polish:** TUI activity/attribution panel. *(roadmap)*

---

## Phase 1 — File Structure

- **Modify `bin/cs`:**
  - Add `_slugify` and `cs_actor_slug` (identity resolution).
  - Add `cs_assert_local_untracked` (staging guard).
  - Add `cmd_whoami` + a `whoami)` dispatch arm in `main()`.
  - `create_session_structure` (bin/cs:990): create `.cs/local/`.
  - `migrate_session` (bin/cs:1134): ensure `.cs/local/` on resume.
  - `create_session_gitignore` (bin/cs:2535): add `.cs/local/`.
  - `adopt_session` (bin/cs:2616–2640): add `.cs/local/` to merge-entries; call the guard before its commit.
- **Create `tests/test_actor_identity.sh`:** resolver precedence + slugify + whoami.
- **Modify `tests/test_adopt.sh`:** assert `.cs/local/` exists and is gitignored after adopt.
- **Modify `tests/test_migrate.sh`** (or the existing migration test file; if none, fold into `test_actor_identity.sh`): assert `.cs/local/` created on resume.

The resolver and guard are pure functions with no session side effects, so they are unit-testable by sourcing `bin/cs` is not possible (it runs `main`); instead test them through observable command behavior (`cs whoami`) and through structural assertions, matching the existing black-box test style in `test_adopt.sh`.

---

## Phase 1 — Tasks

### Task 1: Actor identity resolver (`_slugify` + `cs_actor_slug`)

**Files:**
- Modify: `bin/cs` (add two functions near the other small helpers, e.g. just above `create_session_structure` at bin/cs:984)
- Test: `tests/test_actor_identity.sh` (create)

**Interfaces:**
- Produces: `_slugify "<raw string>"` → echoes a lowercase `[a-z0-9-]` slug (runs of non-alnum collapse to a single `-`, leading/trailing `-` stripped). `cs_actor_slug` → echoes the resolved actor slug using precedence `$CS_ACTOR` > `$CLAUDE_SESSION_META_DIR/local/identity` (first line) > `git config user.email` > `git config user.name` > `"unknown"`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_actor_identity.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for actor identity resolution (cs_actor_slug, _slugify, cs whoami)
# ABOUTME: Validates precedence (env > local file > git email > git name) and slug safety

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_ACTOR
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# Run cs whoami inside an adopted project and capture the actor line.
_whoami_in() {
    # $1 = project dir
    ( cd "$1" && CLAUDE_SESSION_META_DIR="$1/.cs" "$CS_BIN" whoami 2>/dev/null )
}

test_actor_slug_from_git_email() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "Alex.Geana@Example.com" && git config user.name "Alex Geana" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    local out
    out=$(_whoami_in "$project_dir")
    assert_output_contains "$out" "alex-geana-example-com" "slug should derive from normalized git email" || return 1
}

test_actor_slug_env_override_wins() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    local out
    out=$( cd "$project_dir" && CLAUDE_SESSION_META_DIR="$project_dir/.cs" CS_ACTOR="Bob The Builder" "$CS_BIN" whoami 2>/dev/null )
    assert_output_contains "$out" "bob-the-builder" "CS_ACTOR env should override git identity" || return 1
}

test_actor_slug_local_file_over_git() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    printf 'carol@team.io\n' > "$project_dir/.cs/local/identity"

    local out
    out=$(_whoami_in "$project_dir")
    assert_output_contains "$out" "carol-team-io" "local/identity file should override git identity" || return 1
}

echo ""
echo "cs actor identity tests"
echo "======================="
echo ""

run_test test_actor_slug_from_git_email
run_test test_actor_slug_env_override_wins
run_test test_actor_slug_local_file_over_git

report_results
```

> Helper: `assert_output_contains "$output" "<substring>" "<message>"` is defined in `tests/test_lib.sh:156` (string-in-captured-output). For file contents use `assert_file_contains`. `setup` (auto-run by `run_test`) sets an isolated `CS_SESSIONS_ROOT` and `CLAUDE_CODE_BIN=echo`; `$CS_BIN` points at `bin/cs`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — `cs whoami` is an unknown command (Task 2 not yet done), so output won't contain the slug.

- [ ] **Step 3: Write minimal implementation**

In `bin/cs`, just above `create_session_structure()` (bin/cs:984), add:

```bash
# Normalize an arbitrary identity string to a filesystem-safe slug.
_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-*$//'
}

# Resolve the current actor as a slug.
# Precedence: $CS_ACTOR > .cs/local/identity (first line) > git user.email > git user.name > "unknown"
cs_actor_slug() {
    local raw=""
    if [ -n "${CS_ACTOR:-}" ]; then
        raw="$CS_ACTOR"
    elif [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -f "$CLAUDE_SESSION_META_DIR/local/identity" ]; then
        IFS= read -r raw < "$CLAUDE_SESSION_META_DIR/local/identity"
    else
        raw=$(git config user.email 2>/dev/null || true)
        [ -z "$raw" ] && raw=$(git config user.name 2>/dev/null || true)
    fi
    [ -z "$raw" ] && raw="unknown"
    _slugify "$raw"
}
```

(Task 2 adds the `whoami` command that surfaces this; the test goes green at the end of Task 2. Implement Task 1 and Task 2 back-to-back, committing once at the end of Task 2 — they share the same first green.)

- [ ] **Step 4: Commit boundary deferred to Task 2** (resolver is not observable until `whoami` exists).

---

### Task 2: `cs whoami` command + mismatch warning

**Files:**
- Modify: `bin/cs` (add `cmd_whoami`; add `whoami)` arm in `main()` global dispatch — grep `bin/cs` for the global command `case` in `main()` and place it beside other no-session commands like `-help`)
- Test: `tests/test_actor_identity.sh` (already created in Task 1)

**Interfaces:**
- Consumes: `cs_actor_slug`, `_slugify` (Task 1), existing `warn` helper.
- Produces: `cs whoami` prints `actor: <slug>`; if `.cs/local/identity` exists and its slug differs from the git-config slug, prints a `warn` line containing `differs from git identity`.

- [ ] **Step 1: Add the mismatch test to `tests/test_actor_identity.sh`**

```bash
test_whoami_warns_on_identity_mismatch() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    printf 'carol@team.io\n' > "$project_dir/.cs/local/identity"

    local out
    out=$( cd "$project_dir" && CLAUDE_SESSION_META_DIR="$project_dir/.cs" "$CS_BIN" whoami 2>&1 )
    assert_output_contains "$out" "differs from git identity" "whoami should warn when local identity != git identity" || return 1
}
```

Add `run_test test_whoami_warns_on_identity_mismatch` to the runner block.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — `whoami` unknown command; no warning emitted.

- [ ] **Step 3: Implement `cmd_whoami` and dispatch**

Add the function near `cs_actor_slug`:

```bash
# Print the resolved actor slug; warn if the pinned local identity disagrees with git.
cmd_whoami() {
    echo "actor: $(cs_actor_slug)"
    if [ -n "${CLAUDE_SESSION_META_DIR:-}" ] && [ -f "$CLAUDE_SESSION_META_DIR/local/identity" ]; then
        local file_slug="" git_raw="" git_slug=""
        file_slug=$(_slugify "$(head -1 "$CLAUDE_SESSION_META_DIR/local/identity")")
        git_raw=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || true)
        git_slug=$(_slugify "$git_raw")
        if [ -n "$git_slug" ] && [ "$file_slug" != "$git_slug" ]; then
            warn "cs actor '$file_slug' differs from git identity '$git_slug' (using cs actor)"
        fi
    fi
}
```

> `bin/cs` runs under `set -euo pipefail` (bin/cs:5), so every `local` is initialized with `=""` above. `cs_actor_slug` from Task 1 already guards optional env with `${VAR:-}`.

In `main()`'s global command `case`, add:

```bash
        whoami)
            cmd_whoami
            ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_actor_identity.sh`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_actor_identity.sh
git commit -m "feat: actor identity resolver and cs whoami"
```

---

### Task 3: Create `.cs/local/` on session create and resume

**Files:**
- Modify: `bin/cs:990` (`create_session_structure`) and `bin/cs:1134` (`migrate_session` Phase 2 mkdir)
- Test: `tests/test_actor_identity.sh` (add structural test) or `tests/test_adopt.sh`

**Interfaces:**
- Produces: every created or resumed session has a `.cs/local/` directory.

- [ ] **Step 1: Write failing test** (add to `tests/test_actor_identity.sh`)

```bash
test_local_dir_created_on_adopt() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    assert_dir "$project_dir/.cs/local" ".cs/local/ should be created on adopt" || return 1
}
```

Add `run_test test_local_dir_created_on_adopt`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — `.cs/local` does not exist.

- [ ] **Step 3: Implement**

`bin/cs:990`, change:

```bash
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
```
to:
```bash
    mkdir -p "$session_dir/.cs"/{artifacts,logs,local}
```

`bin/cs:1134`, change:

```bash
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
```
to:
```bash
    mkdir -p "$session_dir/.cs"/{artifacts,logs,local}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_actor_identity.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_actor_identity.sh
git commit -m "feat: create .cs/local/ for per-actor state"
```

---

### Task 4: Gitignore `.cs/local/`

**Files:**
- Modify: `bin/cs:2535` (`create_session_gitignore` heredoc) and `bin/cs:2616` (`adopt_session` merge-entries heredoc)
- Test: `tests/test_adopt.sh`

**Interfaces:**
- Produces: the session `.gitignore` always ignores `.cs/local/`.

- [ ] **Step 1: Write failing test** (add to `tests/test_adopt.sh`)

```bash
test_adopt_gitignores_cs_local() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt my-session)
    assert_file_contains "$project_dir/.gitignore" ".cs/local/" \
        ".gitignore should ignore .cs/local/" || return 1
}
```

Add `run_test test_adopt_gitignores_cs_local` to the runner.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_adopt.sh`
Expected: FAIL — `.cs/local/` absent from `.gitignore`.

- [ ] **Step 3: Implement**

In `create_session_gitignore` (bin/cs:2535 heredoc), add under "Transient files":

```
# Per-actor local state (never shared)
.cs/local/
```

In `adopt_session` merge-entries (bin/cs:2616 heredoc), add the line:

```
.cs/local/
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_adopt.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_adopt.sh
git commit -m "feat: gitignore .cs/local/ in created and adopted sessions"
```

---

### Task 5: Staging guard — refuse to run if `.cs/local/` is tracked

**Files:**
- Modify: `bin/cs` (add `cs_assert_local_untracked`; call it inside `adopt_session` immediately before its `git add .cs/ CLAUDE.md .gitignore` at bin/cs:2640)
- Test: `tests/test_actor_identity.sh`

**Interfaces:**
- Consumes: existing `error` helper (prints to stderr and exits non-zero).
- Produces: `cs_assert_local_untracked "<session_dir>"` exits with an error if any path under `.cs/local/` is tracked in git; no-op otherwise.

- [ ] **Step 1: Write failing test** (add to `tests/test_actor_identity.sh`)

```bash
test_guard_blocks_tracked_local() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir/.cs/local"
    ( cd "$project_dir" \
        && git init -q && git config user.email a@b.c && git config user.name A \
        && echo "leak" > .cs/local/oops \
        && git add -f .cs/local/oops \
        && git commit -q -m "accidentally track local" )

    # Resume/migrate should refuse while .cs/local is tracked.
    local out rc
    out=$( cd "$project_dir" && "$CS_BIN" -adopt s1 2>&1 ); rc=$?
    # Adopt refuses (already a repo with tracked local) OR a resume guard fires;
    # assert the guard message regardless of which entry point runs it.
    assert_output_contains "$out" ".cs/local/ is tracked" "guard should report tracked .cs/local/" || return 1
}
```

> If `-adopt` is not the entry point that runs the guard in your wiring, call the guard from the resume path and drive the test through a resume instead. The assertion is on the guard's message, not the command.

Add `run_test test_guard_blocks_tracked_local`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — no guard message; adopt proceeds.

- [ ] **Step 3: Implement**

Add near `cs_actor_slug`:

```bash
# Refuse to proceed if per-actor local state has been committed to git.
cs_assert_local_untracked() {
    local dir="$1"
    [ -d "$dir/.git" ] || return 0
    if [ -n "$(git -C "$dir" ls-files -- .cs/local 2>/dev/null)" ]; then
        error ".cs/local/ is tracked in git (per-actor state must stay local). Fix with: git -C \"$dir\" rm -r --cached .cs/local && git commit -m 'stop tracking .cs/local'"
    fi
}
```

In `adopt_session`, immediately before the existing `git add .cs/ CLAUDE.md .gitignore` (bin/cs:2640), add:

```bash
            cs_assert_local_untracked "$target_dir"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_actor_identity.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

There is no aggregate runner; tests are per-file. Run each `test_*.sh` and confirm all report green:

```bash
for t in tests/test_*.sh; do echo "== $t =="; bash "$t" || break; done
```
Expected: every file's `report_results` prints all-pass — pay attention to `test_adopt.sh`, `test_actor_identity.sh`, `test_no_sync.sh`.

- [ ] **Step 6: Commit**

```bash
git add bin/cs tests/test_actor_identity.sh
git commit -m "feat: guard against committing .cs/local/ per-actor state"
```

---

## Phase 1 — Self-Review Checklist

- [ ] `_slugify` output is `[a-z0-9-]` only, no leading/trailing dash, runs collapsed (verified by `test_actor_slug_from_git_email`).
- [ ] Precedence env > file > git-email > git-name > "unknown" all covered by tests.
- [ ] `.cs/local/` created on both create and resume paths (Task 3) and gitignored on both create and adopt paths (Task 4).
- [ ] Guard message string `.cs/local/ is tracked` matches between implementation (Task 5 Step 3) and test (Task 5 Step 1).
- [ ] No `git add -A` / `git add .cs` introduced; `adopt_session` still stages by allowlist.
- [ ] bash 3.2: only `tr`/`sed`, `IFS= read`, `[ ]` tests used — no `local -A`, no `${x^^}`.
- [ ] `set -u` safety: every `local` initialized; `${VAR:-}` guards on optional env.

---

## Phase 2 — Roadmap: Attributed shared state (own plan once Phase 1 lands)

- **Memory `author:` frontmatter:** when a memory file is written, stamp `author: <cs_actor_slug>` and `created: <date>` in frontmatter. Resolver = `cs_actor_slug` (Phase 1).
- **Tracked derived index (`MEMORY.md`):**
  - Regenerator sorts entries by `(timestamp, author, content-hash)` — never filename — for stable diffs; emits an `AUTO-GENERATED BY cs — DO NOT EDIT` banner; writes atomically (`mktemp` + `mv`).
  - `.gitattributes`: `…/MEMORY.md merge=ours`; cs sets `git config merge.ours.driver true` on init/adopt (one bash-3.2-safe line).
  - **Regenerate-after-merge** (load-bearing): on session-start, if any `memory/*.md` is newer than `MEMORY.md`, rebuild it — this makes `merge=ours` correct instead of lossy (otherwise a merge silently drops a teammate's new memories from the index).
- **Per-actor maildir narrative (SHARED — locked):** replace single append `narrative.md` with a committed `journal/<actor-slug>/<timestamp>.<hash>.md`, one entry per file (handles same-actor-two-clones with zero conflicts). Everyone reads all; each writes only their own. Derive a combined view on demand. Committed/shared so teammates see each other's lab-notebook — the core "see each other's contributions" payoff. Migrate the existing single `narrative.md` into the resolved actor's journal dir on first run.

## Phase 3 — Roadmap: Visibility (own plan)

- **Watermark:** `.cs/local/watermark` stores the last-seen commit SHA (per-clone, gitignored — already covered by Phase 1's `.cs/local/`).
- **On-resume digest:** session-start hook runs `git log <watermark>..HEAD -- .cs/memory .cs/journal` and injects "Since your last session: Bob added 2 memories, +14 narrative lines"; advances the watermark. Reuses the existing context-injection path in `hooks/session-start.sh` (same mechanism as CRASH RECOVERY text).
- **`cs -who`:** on-demand feed from `git log` over shared `.cs/` grouped by actor — labeled "recent activity", never "online".
- **Watermark edge cases (from council):** key by commit; if the SHA vanished after a rebase, fall back to merge-base and say "history changed".

## Phase 4 — Roadmap: TUI activity panel (own plan)

- Add an author/last-activity column or panel to the Rust TUI, fed by the same `git log` data as `cs -who`. **Activity/recency only — never presence.** This is the most surface and least leverage; build last, only if it earns its keep.

---

## Blind spots carried forward (council, address in the owning phase)

- **Auto-commit must stay dead.** One-fact-per-file multiplies commit volume; never auto-commit shared `.cs/`. Commit on explicit checkpoint only. *(Phase 2/commit-model.)*
- **Secrets:** git identity ≠ encryption identity. `secrets.age` multi-recipient is its own design; removing a recipient does not revoke access to history. *(Out of scope here; track separately.)*
- **History bloat / binary artifacts:** keep logs, timelines, raw artifacts in `.cs/local/` (untracked) by default; require explicit publish for anything shared. *(Phase 2/3.)*
- **CLAUDE.md is a shared mutable file** and will conflict if edited concurrently — acceptable for small teams; revisit if it becomes hot.
