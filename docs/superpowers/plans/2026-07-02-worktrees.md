# Worktree-Backed Parallel Task Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cs myproj@fix-auth` opens a parallel Claude session in a git worktree of session `myproj`, with full cs tooling; `cs myproj --merge fix-auth` fuses the work back and removes the worktree.

**Architecture:** A worktree is a first-class session directory created as a *sibling* under `$SESSIONS_ROOT` (never nested in the base). Tracked `.cs/` state rides the branch and re-fuses via existing merge drivers; repos that don't track `.cs/` get a bootstrapped `.cs/` fused explicitly at merge. Autosave crash-recovery moves to git-native per-worktree refs (`refs/worktree/cs/auto`). Spec: `docs/superpowers/specs/2026-07-02-worktrees-design.md`.

**Tech Stack:** bash 3.2, BSD userland, git ≥ 2.20 (worktrees + `refs/worktree/*`), jq, the repo's own test harness (`tests/test_lib.sh`).

## Global Constraints

- bash 3.2 compatible: no `local -A`, no `${var,,}`, no `printf %(...)T`, no `readarray`.
- BSD userland: `sed -i ''` (not `sed -i`), no GNU-only regex (`\+` silently no-ops; use `\{1,\}`).
- NEVER auto-commit or auto-push; preflights refuse dirty state with instructions instead.
- No new hook files — modify existing hook bodies only (5-site registration stays untouched).
- New shell files start with two `# ABOUTME:` lines.
- No emojis anywhere.
- Branch namespace: `cs/<task>`. Worktree dir: `$SESSIONS_ROOT/<base>@<task>`. Local-state keys: `task_branch`, `cs_mode` (`tracked`|`ignored`), `cs_base`.
- Run a suite with `bash tests/test_<name>.sh`; run everything with `for f in tests/test_*.sh; do bash "$f" || exit 1; done`. Test output must be pristine.
- Commit after every green step; never `git add -A` without a fresh `git status`.

---

### Task 1: Worktree name parsing

**Files:**
- Modify: `bin/cs` (after `validate_session_name`, which ends at line 640)
- Modify: `bin/cs` `main()` validation call (line 3220)
- Test: `tests/test_worktrees.sh` (create)

**Interfaces:**
- Consumes: `validate_session_name <name>` (errors and exits on invalid), `error <msg>` (prints and exits 1).
- Produces: `cs_split_worktree_name <name>` — returns 0 and sets globals `CS_WT_BASE` and `CS_WT_TASK` when `<name>` contains `@`; returns 1 for plain names; errors (exit 1) when either half is invalid. Later tasks call this from `main()` and `remove_session()`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_worktrees.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for worktree-backed parallel task sessions
# ABOUTME: Covers name parsing, creation, launch env, merge-back, removal, doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# --- Name parsing (via cs CLI behavior) ---

test_worktree_name_rejected_without_base() {
    local output
    output=$("$CS_BIN" "@fix-auth" 2>&1 || true)
    assert_output_contains "$output" "Session name" "empty base half must be rejected"
}

test_worktree_name_rejects_bad_task_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@fix/auth" 2>&1 || true)
    assert_output_contains "$output" "task name" "slash in task half must be rejected"
}

test_plain_names_still_work() {
    local output
    output=$("$CS_BIN" "-list" 2>&1)
    assert_output_not_contains "$output" "Unknown" "plain subcommands unaffected"
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_plain_names_still_work
report_results
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_worktrees.sh`
Expected: `test_worktree_name_rejected_without_base` and `test_worktree_name_rejects_bad_task_half` FAIL (current code prints the generic "Session name must contain only alphanumeric..." for both, so the second test fails on the "task name" expectation; the first may pass by accident — confirm at least one real failure before proceeding).

- [ ] **Step 3: Implement the splitter and wire validation**

In `bin/cs`, insert after `validate_session_name` (after line 640):

```bash
# Split a worktree session name <base>@<task> into CS_WT_BASE / CS_WT_TASK.
# Returns 1 for plain names (no @). Errors out when either half is invalid.
# @ is safe as a separator: validate_session_name has never admitted it, so
# no existing session name can contain one.
cs_split_worktree_name() {
    local name="$1"
    case "$name" in
        *@*) ;;
        *) return 1 ;;
    esac
    CS_WT_BASE="${name%%@*}"
    CS_WT_TASK="${name#*@}"
    if [ -z "$CS_WT_BASE" ]; then
        error "Session name cannot be empty before '@' (expected <base>@<task>)"
    fi
    validate_session_name "$CS_WT_BASE"
    if [ -z "$CS_WT_TASK" ] || ! [[ "$CS_WT_TASK" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "Worktree task name must contain only alphanumeric characters, hyphens, underscores, and dots"
    fi
    return 0
}
```

In `main()`, replace line 3220 (`validate_session_name "$session_name"`) with:

```bash
    local wt_base="" wt_task=""
    if cs_split_worktree_name "$session_name"; then
        wt_base="$CS_WT_BASE"
        wt_task="$CS_WT_TASK"
    else
        validate_session_name "$session_name"
    fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_worktrees.sh`
Expected: 3/3 PASS. (`myproj@fix-auth` with a valid task will currently fall through to "create a session literally named with @" — Task 2 intercepts that; these tests only pin the validation surface.)

- [ ] **Step 5: Commit**

```bash
git add tests/test_worktrees.sh bin/cs
git commit -m "feat: parse <base>@<task> worktree session names"
```

---

### Task 2: Worktree creation

**Files:**
- Modify: `bin/cs` (new functions after `cs_split_worktree_name`; `main()` block at lines 3257-3276)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `CS_WT_BASE`/`CS_WT_TASK` from Task 1; `_alloc_uuid` (bin/cs:893), `_alloc_random_color`, `_set_local_state <file> <key> <value>` (bin/cs:944), `ensure_narrative_file <dir>` (bin/cs:684), `setup_auto_memory <dir>` (bin/cs:643), `warn`/`info`/`error`.
- Produces: `create_worktree_session <base_dir> <base_name> <task>` — creates the worktree + branch, initializes `.cs/local/state` (keys `claude_session_id`, `claude_session_color`, `task_branch`, `cs_mode`, `cs_base`), bootstraps `.cs/` in ignored mode, prints the worktree path. `bootstrap_worktree_meta <wt_dir> <base_name> <task>` — `.cs/` skeleton only; NEVER touches the checkout's `CLAUDE.md` (it is the project's own file in ignored-mode repos).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_worktrees.sh` before the `run_test` block, and add the new `run_test` lines:

```bash
# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    assert_dir "$wt" "worktree dir should exist"
    assert_file_exists "$wt/.git" "linked worktree .git should be a file"
    assert_eq "cs/fix-auth" "$(git -C "$wt" branch --show-current)" "worktree on task branch"
    assert_file_exists "$wt/.cs/artifacts/MANIFEST.json" "tracked .cs rides the checkout"
    assert_file_contains "$wt/.cs/local/state" "task_branch: cs/fix-auth"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked"
    assert_file_contains "$wt/.cs/local/state" "cs_base: myproj"
    # Fresh identity, not the base's
    local base_uuid wt_uuid
    base_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$base_dir/.cs/local/state")
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$wt/.cs/local/state")
    [ "$base_uuid" != "$wt_uuid" ] || { echo "  FAIL: worktree must get its own UUID"; return 1; }
}

test_worktree_create_refuses_dirty_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "change" >> "$base_dir/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty base must refuse"
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal"
}

test_worktree_create_reuses_existing_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" branch cs/fix-auth
    cs_launch "myproj@fix-auth"
    assert_eq "cs/fix-auth" "$(git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" branch --show-current)" \
        "existing branch is reused, not errored on"
}

test_worktree_create_ignored_mode_bootstraps_cs() {
    # A repo whose .gitignore excludes .cs/ entirely (like the cs dev repo)
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,artifacts,logs,local}
    echo "[]" > "$base_dir/.cs/artifacts/MANIFEST.json"
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_dir "$wt/.cs/artifacts" "ignored mode bootstraps .cs skeleton"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored"
    assert_eq "# Project CLAUDE.md" "$(cat "$wt/CLAUDE.md")" \
        "bootstrap must not overwrite the project's CLAUDE.md"
}

test_worktree_of_worktree_refused() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj@fix-auth@deeper" 2>&1 || true)
    assert_output_contains "$output" "task name" "second @ lands in the task half and is rejected"
}
```

New `run_test` lines (keep before `report_results`):

```bash
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_worktree_of_worktree_refused
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_worktrees.sh`
Expected: the five new tests FAIL (no worktree machinery exists; `cs myproj@fix-auth` currently creates a plain directory named `myproj@fix-auth`).

- [ ] **Step 3: Implement creation**

In `bin/cs`, add after `cs_split_worktree_name`:

```bash
# Create the .cs/ skeleton inside a worktree whose repo does not track .cs/
# (ignored mode). Leaves the checkout's CLAUDE.md alone — in these repos it
# is the project's own tracked file.
bootstrap_worktree_meta() {
    local wt_dir="$1" base_name="$2" task="$3"
    mkdir -p "$wt_dir/.cs"/{artifacts,logs,local,memory}
    cat > "$wt_dir/.cs/README.md" << EOF
---
status: active
created: $(date '+%Y-%m-%d')
tags: [worktree]
aliases: ["$base_name@$task"]
---
# Session: $base_name@$task

Task worktree of session '$base_name' on branch cs/$task.

## Objective

[Describe this task]
EOF
    echo "[]" > "$wt_dir/.cs/artifacts/MANIFEST.json"
    cat > "$wt_dir/.cs/logs/session.log" << EOF
Claude Code Session Log
Session: $base_name@$task
Started: $(date '+%Y-%m-%d %H:%M:%S')

================================================================================

EOF
    ensure_narrative_file "$wt_dir"
}

# Create a linked git worktree of a base session as a sibling session dir.
# Refuses on dirty tracked files (a worktree materializes committed state
# only). Prints the new worktree path.
create_worktree_session() {
    local base_dir="$1" base_name="$2" task="$3"
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    if ! git -C "$base_dir" rev-parse --git-dir >/dev/null 2>&1; then
        error "Session '$base_name' has no git repo; worktrees need one"
    fi
    if [ -f "$base_dir/.git" ]; then
        error "Session '$base_name' is itself a worktree; create tasks from the main checkout"
    fi
    if ! git -C "$base_dir" diff --quiet 2>/dev/null \
        || ! git -C "$base_dir" diff --cached --quiet 2>/dev/null; then
        error "Session '$base_name' has uncommitted changes; commit them first (a worktree materializes committed state only)"
    fi
    local untracked
    untracked=$(git -C "$base_dir" ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
    if [ -n "$untracked" ]; then
        warn "Untracked files will not appear in the worktree:"
        printf '%s\n' "$untracked" >&2
    fi

    if git -C "$base_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        git -C "$base_dir" worktree add "$wt_dir" "$branch" >/dev/null 2>&1 \
            || error "git worktree add failed (is branch '$branch' checked out in another worktree?)"
    else
        git -C "$base_dir" worktree add -b "$branch" "$wt_dir" >/dev/null 2>&1 \
            || error "git worktree add failed"
    fi

    local mode="tracked"
    if [ -z "$(git -C "$base_dir" ls-files -- .cs 2>/dev/null)" ]; then
        mode="ignored"
        bootstrap_worktree_meta "$wt_dir" "$base_name" "$task"
    fi

    local state="$wt_dir/.cs/local/state"
    _set_local_state "$state" claude_session_id "$(_alloc_uuid)"
    _set_local_state "$state" claude_session_color "$(_alloc_random_color)"
    _set_local_state "$state" task_branch "$branch"
    _set_local_state "$state" cs_mode "$mode"
    _set_local_state "$state" cs_base "$base_name"

    setup_auto_memory "$wt_dir"

    echo "$wt_dir"
}
```

In `main()`, replace the create-or-migrate block (lines 3257-3276, from `local is_new="false"` through the `migrate_session` else-branch) with:

```bash
    local is_new="false"

    if [ -n "$wt_base" ]; then
        # Worktree session: create from the base, or open the existing one.
        local base_dir="$SESSIONS_ROOT/$wt_base"
        if [ ! -e "$base_dir" ]; then
            error "Base session not found: $wt_base"
        fi
        if [ -L "$base_dir" ]; then
            base_dir="$(readlink -f "$base_dir")"
        fi
        if [ ! -d "$session_dir" ]; then
            is_new="true"
            session_dir=$(create_worktree_session "$base_dir" "$wt_base" "$wt_task")
        else
            local pinned head_branch
            pinned=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
            head_branch=$(git -C "$session_dir" branch --show-current 2>/dev/null || echo "")
            if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
                warn "Worktree HEAD is '$head_branch' but this task expects '$pinned' (did something run git switch here?)"
            fi
            migrate_session "$session_dir"
        fi
    elif [ ! -d "$session_dir" ]; then
        is_new="true"
        create_session_structure "$session_dir"

        # Initialize local git repo by default
        (
            cd "$session_dir" || exit 0
            create_session_gitignore "$session_dir"
            git init -q 2>/dev/null || true
            git branch -M main 2>/dev/null || true
            setup_merge_attributes "$session_dir"
            git add -A 2>/dev/null || true
            git commit -q -m "Initial session structure" 2>/dev/null || true
        )
    else
        migrate_session "$session_dir"
    fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_worktrees.sh`
Expected: all PASS.

- [ ] **Step 5: Run the adjacent suites to catch regressions**

Run: `bash tests/test_adopt.sh && bash tests/test_actor_identity.sh && bash tests/test_uuid.sh && bash tests/test_session_lock.sh`
Expected: all PASS (the plain-session path through `main()` is byte-identical logic, only re-indented into the new branch structure).

- [ ] **Step 6: Commit**

```bash
git add tests/test_worktrees.sh bin/cs
git commit -m "feat: create worktree task sessions via cs <base>@<task>"
```

---

### Task 3: Launch identity — shared task list and secrets namespace

**Files:**
- Modify: `bin/cs` `launch_claude_code()` (line 2577)
- Modify: `bin/cs-secrets` (line 1168)
- Modify: `hooks/artifact-tracker.sh` (line 138)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `_read_local_state` and the `cs_base` key written by Task 2; `_make_env_stub` from test_lib.sh:183.
- Produces: env contract — worktree launches export `CLAUDE_CODE_TASK_LIST_ID=<base>` and `CS_SECRETS_SESSION=<base>`; `cs-secrets` and the artifact hook's keychain fallback prefer `CS_SECRETS_SESSION` over `CLAUDE_SESSION_NAME`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_worktrees.sh`:

```bash
test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out
    stub=$(_make_env_stub)
    env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" < /dev/null 2>/dev/null || true)
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name"
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj" "task list is shared with the base"
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base"
}

run_test test_worktree_launch_exports_base_identity
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_worktrees.sh`
Expected: FAIL on `CLAUDE_CODE_TASK_LIST_ID=myproj` (current export is the full session name) and on `CS_SECRETS_SESSION`.

Note: opening an existing session prompts "Continue previous conversation? [Y/n]"; `< /dev/null` makes `read` fail and cs takes the fresh-rebind path, which still execs the stub — the env assertions are unaffected.

- [ ] **Step 3: Implement the env split**

In `bin/cs` `launch_claude_code()`, replace line 2577 (`export CLAUDE_CODE_TASK_LIST_ID="$session_name"`) with:

```bash
    # Worktree sessions coordinate through the base session's task list and
    # keychain namespace; cs_base is only set in worktree local state.
    local cs_base
    cs_base=$(_read_local_state "$session_dir/.cs/local/state" cs_base)
    export CLAUDE_CODE_TASK_LIST_ID="${cs_base:-$session_name}"
    if [ -n "$cs_base" ]; then
        export CS_SECRETS_SESSION="$cs_base"
    fi
```

In `bin/cs-secrets`, replace line 1168 (`SESSION_NAME="${CLAUDE_SESSION_NAME:-}"`) with:

```bash
SESSION_NAME="${CS_SECRETS_SESSION:-${CLAUDE_SESSION_NAME:-}}"
```

In `hooks/artifact-tracker.sh`, replace line 138 (`local service="cs:${CLAUDE_SESSION_NAME}:${name}"`) with:

```bash
            local service="cs:${CS_SECRETS_SESSION:-$CLAUDE_SESSION_NAME}:${name}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_worktrees.sh && bash tests/test_secrets.sh 2>/dev/null; bash tests/test_artifact_tracker.sh`
Expected: all PASS (plain sessions have no `cs_base` key, so `CS_SECRETS_SESSION` stays unset and both fallbacks read `CLAUDE_SESSION_NAME` exactly as before).

- [ ] **Step 5: Commit**

```bash
git add bin/cs bin/cs-secrets hooks/artifact-tracker.sh tests/test_worktrees.sh
git commit -m "feat: worktree sessions share the base task list and secrets namespace"
```

---

### Task 4: Autosave shadow ref — migrate to refs/worktree/cs/auto

**Files:**
- Modify: `hooks/autosave-commits.sh` (lines 19-21, 76, 83)
- Modify: `hooks/session-start.sh` (lines 59-80)
- Modify: `hooks/session-end.sh` (lines 77-79)
- Modify: `bin/cs` `_doctor_check_shadow_ref()` (line 1966)
- Modify: every test referencing `refs/cs/auto` (discover with `rg -l 'refs/cs/auto' tests/`)
- Test: `tests/test_shadow_ref.sh` (existing suite), `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: the autosave ref name `refs/worktree/cs/auto` (git-native per-worktree isolation — verified on git 2.50.1: same name resolves independently per checkout; deletion is per-checkout). Legacy `refs/cs/auto` is still honored for crash detection and deleted on clean session end.

- [ ] **Step 1: Update the existing shadow-ref tests and add isolation tests**

Run `rg -l 'refs/cs/auto' tests/` and in each hit replace assertions' expected ref name with `refs/worktree/cs/auto`, keeping one legacy-named test per behavior below. Then append to `tests/test_shadow_ref.sh` (following its existing test-function style; it drives hooks with `CS_TEST_SYNC=1`):

```bash
test_autosave_refs_isolated_per_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "s1")
    git -C "$base_dir" worktree add -b cs/t1 "$CS_SESSIONS_ROOT/s1@t1" -q
    # Autosave in the base
    (cd "$base_dir" && echo x > f.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1 CLAUDE_SESSION_DIR="$base_dir" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"f.txt"}}')
    # Autosave in the worktree
    (cd "$CS_SESSIONS_ROOT/s1@t1" && echo y > g.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1@t1 CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/s1@t1" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"g.txt"}}')
    local base_sha wt_sha
    base_sha=$(git -C "$base_dir" rev-parse refs/worktree/cs/auto)
    wt_sha=$(git -C "$CS_SESSIONS_ROOT/s1@t1" rev-parse refs/worktree/cs/auto)
    [ "$base_sha" != "$wt_sha" ] || { echo "  FAIL: refs must be per-checkout"; return 1; }
}

test_autosave_works_in_linked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "s1")
    git -C "$base_dir" worktree add -b cs/t1 "$CS_SESSIONS_ROOT/s1@t1" -q
    (cd "$CS_SESSIONS_ROOT/s1@t1" && echo y > g.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1@t1 CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/s1@t1" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"g.txt"}}')
    git -C "$CS_SESSIONS_ROOT/s1@t1" rev-parse -q --verify refs/worktree/cs/auto > /dev/null \
        || { echo "  FAIL: autosave must fire in a linked worktree (.git is a file)"; return 1; }
}

run_test test_autosave_refs_isolated_per_worktree
run_test test_autosave_works_in_linked_worktree
```

- [ ] **Step 2: Run to verify failures**

Run: `bash tests/test_shadow_ref.sh`
Expected: renamed-ref tests FAIL (hook still writes `refs/cs/auto`); `test_autosave_works_in_linked_worktree` FAIL (the `-d .git` guard exits early in a worktree).

- [ ] **Step 3: Implement the ref migration**

`hooks/autosave-commits.sh` — replace lines 18-21:

```bash
# Check if session has git repo (worktree-tolerant: .git may be a file)
if ! git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi
```

Replace line 76 (`parent=$(git rev-parse -q --verify refs/cs/auto 2>/dev/null || true)`) with:

```bash
    parent=$(git rev-parse -q --verify refs/worktree/cs/auto 2>/dev/null || true)
```

Replace line 83 (`git update-ref refs/cs/auto "$commit" 2>/dev/null || return 0`) with:

```bash
    git update-ref refs/worktree/cs/auto "$commit" 2>/dev/null || return 0
    # One-time cleanup of the pre-namespaced ref
    git update-ref -d refs/cs/auto 2>/dev/null || true
```

`hooks/session-start.sh` — replace lines 58-80 (the whole `if [ -d "$SESSION_DIR/.git" ]` block) with:

```bash
# Shadow ref: crash recovery and push protection (worktree-tolerant)
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # Ensure legacy shadow refs are never pushed (refs/worktree/* never are)
    git -C "$SESSION_DIR" config transfer.hideRefs refs/cs 2>/dev/null || true

    # Detect an orphaned shadow ref (previous session crashed). Prefer the
    # per-worktree ref; fall back to the legacy repo-global name.
    SHADOW_REF=""
    if git -C "$SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        SHADOW_REF="refs/worktree/cs/auto"
    elif git -C "$SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        SHADOW_REF="refs/cs/auto"
    fi
    if [ -n "$SHADOW_REF" ]; then
        # Generate a summary of what would be restored
        CRASH_DIFF=$(git -C "$SESSION_DIR" diff --stat HEAD "$SHADOW_REF" -- . 2>/dev/null || true)
        CRASH_FILES=$(git -C "$SESSION_DIR" diff --name-only HEAD "$SHADOW_REF" -- . 2>/dev/null | head -10 || true)
        CRASH_FILE_COUNT=$(echo "$CRASH_FILES" | grep -c . 2>/dev/null || echo "0")

        if [ -n "$CRASH_FILES" ] && [ "$CRASH_FILE_COUNT" -gt 0 ]; then
            # Don't auto-restore — inject into context so Claude can ask the user
            CRASH_CONTEXT="CRASH RECOVERY: The previous session ended without saving (crash or timeout). Autosaved changes were found in ${CRASH_FILE_COUNT} file(s):\n\n${CRASH_FILES}\n\nDiff summary:\n${CRASH_DIFF}\n\nIMPORTANT: Ask the user if they want to restore these changes. To restore, run: git -C \"$SESSION_DIR\" checkout $SHADOW_REF -- . && git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF\nTo discard, run: git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Crash recovery: found ${CRASH_FILE_COUNT} unsaved file(s), awaiting user decision" \
                >> "$META_DIR/logs/session.log"
        else
            # No actual changes — just clean up the orphaned ref
            git -C "$SESSION_DIR" update-ref -d "$SHADOW_REF" 2>/dev/null || true
        fi
    fi
fi
```

`hooks/session-end.sh` — replace lines 76-79 with:

```bash
# Delete shadow autosave refs (no longer needed after clean session end);
# refs/worktree/* deletion only affects this checkout's ref.
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
    git -C "$SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
fi
```

`bin/cs` `_doctor_check_shadow_ref()` — replace line 1966 with:

```bash
    shadow_sha=$(git -C "$dir" show-ref --verify refs/worktree/cs/auto 2>/dev/null | awk '{print $1}' || true)
```

and update the two message strings on lines 1970 and 1976 from `refs/cs/auto` to `refs/worktree/cs/auto`.

- [ ] **Step 3b: Audit the remaining `-d .git` guards in bin/cs**

Run `rg -n '\-d "?\$[a-z_]*dir"?/\.git' bin/cs` and fix the two sites reachable
with a worktree directory, where `.git`-is-a-file makes the guard silently
skip:

`setup_merge_attributes` (bin/cs:1081) — replace `[ -d "$dir/.git" ] || return 0` with:

```bash
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
```

`cs_assert_local_untracked` (bin/cs:1107) — replace `[ -d "$dir/.git" ] || return 0` with:

```bash
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
```

Leave the creation-path guards (`adopt_session` line 2844, `main()` git-init
decision) alone: they answer "does a repo need to be created here?", where a
worktree can never occur.

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_shadow_ref.sh && bash tests/test_hooks.sh && bash tests/test_worktrees.sh && bash tests/test_doctor.sh 2>/dev/null; true`
Expected: all PASS (run whichever doctor suite exists — check with `ls tests/ | grep doctor`).

- [ ] **Step 5: Commit**

```bash
git add hooks/autosave-commits.sh hooks/session-start.sh hooks/session-end.sh bin/cs tests/
git commit -m "feat: per-worktree autosave refs via refs/worktree/cs/auto"
```

---

### Task 5: Artifact tracker — stop teleporting writes from outside the session

**Files:**
- Modify: `hooks/artifact-tracker.sh` (insert after line 64, the `SHOULD_TRACK` early-allow)
- Test: `tests/test_artifact_tracker.sh` (existing suite)

**Interfaces:**
- Consumes: hook env contract (`CLAUDE_SESSION_DIR`, `CLAUDE_ARTIFACT_DIR`).
- Produces: Writes targeting paths outside the session checkout pass through untouched — this is the entire "safe + sane defaults" fix for Claude's native worktrees and any external path.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_artifact_tracker.sh` (match its existing invocation style — it pipes hook-input JSON with env set):

```bash
test_write_outside_session_dir_passes_through() {
    local session_dir
    session_dir=$(create_test_session "s1")
    local outside="$TEST_TMPDIR/native-worktree"
    mkdir -p "$outside"
    local input output
    input=$(jq -nc --arg p "$outside/setup.sh" \
        '{tool_name:"Write", tool_input:{file_path:$p, content:"echo hi"}}')
    output=$(echo "$input" | CLAUDE_SESSION_NAME=s1 \
        CLAUDE_SESSION_DIR="$session_dir" \
        CLAUDE_ARTIFACT_DIR="$session_dir/.cs/artifacts" \
        bash "$SCRIPT_DIR/../hooks/artifact-tracker.sh")
    assert_output_not_contains "$output" "updatedInput" \
        "writes outside the session checkout must not be redirected"
    assert_output_contains "$output" '"permissionDecision": "allow"' "plain allow"
}

run_test test_write_outside_session_dir_passes_through
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_artifact_tracker.sh`
Expected: new test FAILS (`setup.sh` is a tracked extension, so today it gets `updatedInput` teleporting it into `.cs/artifacts`).

- [ ] **Step 3: Implement the path guard**

In `hooks/artifact-tracker.sh`, insert after line 64 (after the `SHOULD_TRACK -eq 0` early-allow block):

```bash
# Only redirect writes that target the session checkout itself. Writes into
# native harness worktrees, /tmp, or other repos land where the tool asked;
# resolve the parent dir so symlinked spellings of the session path match.
FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P || dirname "$FILE_PATH")
SESSION_DIR_REAL=$(cd "$SESSION_DIR" 2>/dev/null && pwd -P || echo "$SESSION_DIR")
case "$FILE_DIR/" in
    "$SESSION_DIR_REAL"/*) : ;;
    *)
        echo '{"permissionDecision": "allow"}'
        exit 0
        ;;
esac
```

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_artifact_tracker.sh && bash tests/test_hooks.sh`
Expected: all PASS — including the existing redirect tests, whose target paths live inside the session dir.

- [ ] **Step 5: Commit**

```bash
git add hooks/artifact-tracker.sh tests/test_artifact_tracker.sh
git commit -m "fix: artifact tracker only redirects writes inside the session checkout"
```

---

### Task 6: Merge-back — cs <base> --merge <task>

**Files:**
- Modify: `bin/cs` (new `merge_worktree_session()` after `create_worktree_session`; `main()` session-flag loop at lines 3224-3243)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `setup_merge_attributes` (bin/cs:1079), `_read_local_state`, locks at `<dir>/.cs/session.lock` (bin/cs:372).
- Produces: `merge_worktree_session <base_name> <task>` — preflights, merges `cs/<task>`, calls `fuse_session_records` in ignored mode (Task 7 — until then a stub is fine ONLY if Task 7 lands in the same session; otherwise implement Task 7 first... they are ordered adjacent deliberately: this task ships the tracked path, Task 7 ships the fuse), removes worktree + branch, appends a timeline event. CLI: `cs <base> --merge <task>`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_worktrees.sh`:

```bash
test_merge_tracked_worktree_fuses_and_cleans_up() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Simulate task work: code + session records, committed on the branch
    echo "fix" > "$wt/auth.txt"
    echo '{"ts":"2026-07-02T00:00:00Z","event":"task"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1)
    assert_file_exists "$base_dir/auth.txt" "code merged into base"
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"task"' "timeline union-merged"
    assert_not_exists "$wt" "worktree removed after merge"
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted"
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "worktree-merged" "merge recorded"
}

test_merge_refuses_dirty_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "uncommitted" >> "$wt/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty worktree refused"
    assert_dir "$wt" "worktree preserved on refusal"
}

test_merge_refuses_live_session() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "session is open" "live lock refused"
    rm -f "$wt/.cs/session.lock"
}

test_merge_conflict_stops_and_preserves() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "conflict" "conflict reported"
    assert_dir "$wt" "worktree preserved on conflict"
    (cd "$base_dir" && git merge --abort 2>/dev/null || true)
}

run_test test_merge_tracked_worktree_fuses_and_cleans_up
run_test test_merge_refuses_dirty_worktree
run_test test_merge_refuses_live_session
run_test test_merge_conflict_stops_and_preserves
```

- [ ] **Step 2: Run to verify failures**

Run: `bash tests/test_worktrees.sh`
Expected: all four FAIL (`--merge` is currently "Unknown session command").

- [ ] **Step 3: Implement merge**

In `bin/cs`, add after `create_worktree_session`:

```bash
# Merge a task worktree's branch back into the base session, fuse session
# records, and remove the worktree. Explicit and user-invoked only; every
# preflight refuses rather than committing on the user's behalf.
merge_worktree_session() {
    local base_name="$1" task="$2"
    local base_dir="$SESSIONS_ROOT/$base_name"
    [ -L "$base_dir" ] && base_dir="$(readlink -f "$base_dir")"
    local wt_dir="$SESSIONS_ROOT/$base_name@$task"
    local branch="cs/$task"

    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for task '$task' (expected $wt_dir)"

    local lock pid
    for lock in "$base_dir/.cs/session.lock" "$wt_dir/.cs/session.lock"; do
        if [ -f "$lock" ]; then
            pid=$(cat "$lock" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                error "A session is open (PID $pid, $lock); close it before merging"
            fi
        fi
    done

    if ! git -C "$wt_dir" diff --quiet 2>/dev/null \
        || ! git -C "$wt_dir" diff --cached --quiet 2>/dev/null; then
        error "Worktree has uncommitted changes; commit them in $wt_dir first (cs never commits for you)"
    fi
    if ! git -C "$base_dir" diff --quiet 2>/dev/null \
        || ! git -C "$base_dir" diff --cached --quiet 2>/dev/null; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi

    setup_merge_attributes "$base_dir"

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)

    if git -C "$base_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
        info "Branch $branch is already merged; cleaning up"
    else
        if [ "$mode" = "tracked" ]; then
            local mb
            mb=$(git -C "$base_dir" merge-base HEAD "$branch" 2>/dev/null || echo "")
            if [ -n "$mb" ] \
                && ! git -C "$base_dir" diff --quiet "$mb" "$branch" -- .cs/memory/MEMORY.md 2>/dev/null; then
                warn "MEMORY.md changed on $branch; merge=ours keeps the base copy. Review: git -C \"$base_dir\" diff $mb $branch -- .cs/memory/MEMORY.md"
            fi
        fi
        if ! git -C "$base_dir" merge --no-edit "$branch"; then
            error "Merge conflicts in $base_dir; resolve and commit (or git merge --abort), then re-run: cs $base_name --merge $task"
        fi
    fi

    if [ "$mode" = "ignored" ]; then
        fuse_session_records "$wt_dir/.cs" "$base_dir/.cs"
    fi

    # --force: the worktree legitimately holds untracked files (.cs/local,
    # settings.local.json, the whole .cs in ignored mode) that our preflight
    # deliberately does not count as dirt.
    git -C "$base_dir" worktree remove --force "$wt_dir" 2>/dev/null \
        || error "git worktree remove failed for $wt_dir"
    git -C "$base_dir" branch -d "$branch" >/dev/null 2>&1 \
        || warn "Branch $branch was not deleted (not fully merged?)"

    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "worktree-merged" \
           --arg task "$task" \
        '{ts: $ts, event: $event, task: $task}' \
        >> "$base_dir/.cs/timeline.jsonl" 2>/dev/null || true
    info "Merged $branch and removed worktree $base_name@$task"
}
```

Until Task 7 lands, add this placeholder-free minimal fuse so ignored mode degrades loudly instead of failing on a missing function (Task 7 replaces it wholesale):

```bash
# Fuse session records from a worktree .cs into the base .cs (ignored mode).
fuse_session_records() {
    local src="$1" dst="$2"
    [ -f "$src/timeline.jsonl" ] && cat "$src/timeline.jsonl" >> "$dst/timeline.jsonl"
    warn "Session-record fuse is partial pending full implementation; review $src manually"
}
```

In `main()`'s session-flag `while` loop (lines 3224-3243), add a case before `--force`:

```bash
            --merge)
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> --merge <task>"
                merge_worktree_session "$session_name" "$1"
                return 0
                ;;
```

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_worktrees.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_worktrees.sh
git commit -m "feat: cs <base> --merge <task> fuses and removes task worktrees"
```

---

### Task 7: Ignored-mode session-record fuse

**Files:**
- Modify: `bin/cs` (replace the minimal `fuse_session_records` from Task 6)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `.cs` layouts on both sides; jq expression identical to the manifest merge driver (bin/cs:1084).
- Produces: `fuse_session_records <src_cs_dir> <dst_cs_dir>` — appends timeline/log (union), appends narrative bodies past their YAML frontmatter, copies memory topic files and artifacts without overwriting, jq-merges MANIFEST.json, reports (never merges) MEMORY.md.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_worktrees.sh`:

```bash
test_merge_ignored_mode_fuses_records() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,artifacts,logs,local}
    echo "[]" > "$base_dir/.cs/artifacts/MANIFEST.json"
    echo "base note" > "$base_dir/.cs/memory/note-base.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    # Task work: code (committed) + session records (untracked .cs)
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo '{"event":"from-task"}' >> "$wt/.cs/timeline.jsonl"
    echo "task memory" > "$wt/.cs/memory/note-task.md"
    echo "artifact body" > "$wt/.cs/artifacts/run.sh"
    echo '[{"filename":"run.sh","timestamp":"2026-07-02T00:00:00Z"}]' \
        > "$wt/.cs/artifacts/MANIFEST.json"
    printf -- '---\nname: n\n---\n# Session narrative (tester)\n\n## Task finding\n' \
        > "$wt/.cs/memory/narrative.tester.md"
    "$CS_BIN" "proj" --merge "t1" > /dev/null 2>&1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "from-task" "timeline appended"
    assert_file_exists "$base_dir/.cs/memory/note-task.md" "memory file copied"
    assert_file_exists "$base_dir/.cs/memory/note-base.md" "base memory untouched"
    assert_file_exists "$base_dir/.cs/artifacts/run.sh" "artifact copied"
    assert_file_contains "$base_dir/.cs/artifacts/MANIFEST.json" "run.sh" "manifest jq-merged"
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "Task finding" "narrative body appended"
    assert_file_not_contains "$base_dir/.cs/memory/narrative.tester.md" "name: n" "frontmatter not duplicated"
    assert_not_exists "$wt" "worktree removed"
    assert_file_exists "$base_dir/result.txt" "code merged"
}

run_test test_merge_ignored_mode_fuses_records
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_worktrees.sh`
Expected: FAILS on memory/artifact/narrative assertions (Task 6's minimal fuse only appends the timeline).

- [ ] **Step 3: Implement the full fuse**

Replace the Task 6 `fuse_session_records` in `bin/cs` entirely with:

```bash
# Fuse session records from a worktree .cs into the base .cs (ignored mode:
# the repo does not track .cs/, so git merge cannot carry these). Applies the
# same semantics the merge drivers give tracked repos: union append for
# timeline/log/narratives, jq manifest merge, copy-never-overwrite for memory
# topic files and artifacts, base-wins for MEMORY.md.
fuse_session_records() {
    local src="$1" dst="$2"
    local f base

    [ -f "$src/timeline.jsonl" ] && cat "$src/timeline.jsonl" >> "$dst/timeline.jsonl"
    if [ -f "$src/logs/session.log" ]; then
        mkdir -p "$dst/logs"
        { echo ""; cat "$src/logs/session.log"; } >> "$dst/logs/session.log"
    fi

    mkdir -p "$dst/memory"
    for f in "$src"/memory/narrative.*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [ -f "$dst/memory/$base" ]; then
            # Append the body past the closing --- of the YAML frontmatter
            awk 'c==2 {print} /^---$/ {c++}' "$f" >> "$dst/memory/$base"
        else
            cp "$f" "$dst/memory/$base"
        fi
    done

    for f in "$src"/memory/*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            MEMORY.md) continue ;;
            narrative.*.md) continue ;;
        esac
        if [ -f "$dst/memory/$base" ]; then
            warn "memory/$base already exists in the base; skipped"
        else
            cp "$f" "$dst/memory/$base"
        fi
    done

    mkdir -p "$dst/artifacts"
    for f in "$src"/artifacts/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [ "$base" = "MANIFEST.json" ] && continue
        if [ -f "$dst/artifacts/$base" ]; then
            warn "artifacts/$base already exists in the base; skipped"
        else
            cp "$f" "$dst/artifacts/$base"
        fi
    done
    if [ -f "$src/artifacts/MANIFEST.json" ] && [ -f "$dst/artifacts/MANIFEST.json" ]; then
        jq -s '.[0] + .[1] | unique_by([.filename, .timestamp]) | sort_by(.timestamp)' \
            "$dst/artifacts/MANIFEST.json" "$src/artifacts/MANIFEST.json" \
            > "$dst/artifacts/MANIFEST.json.csmerge" 2>/dev/null \
            && mv "$dst/artifacts/MANIFEST.json.csmerge" "$dst/artifacts/MANIFEST.json" \
            || rm -f "$dst/artifacts/MANIFEST.json.csmerge"
    fi

    if [ -f "$src/memory/MEMORY.md" ]; then
        info "MEMORY.md index lines from the task were not merged (base copy kept)"
    fi
}
```

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_worktrees.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_worktrees.sh
git commit -m "feat: fuse ignored-mode session records at worktree merge"
```

---

### Task 8: Removal — cs -rm of a worktree session

**Files:**
- Modify: `bin/cs` `remove_session()` (lines 2280-2313)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `task_branch` local-state key; `cs_split_worktree_name` semantics (path pattern only — removal must work even when local state is damaged).
- Produces: `cs -rm <base>@<task>` unregisters the worktree via `git worktree remove --force` after confirmation and offers to delete the branch. Plain `-rm` behavior unchanged.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_worktrees.sh`:

```bash
test_rm_worktree_unregisters_and_prompts_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Confirm removal, decline branch deletion
    printf 'y\nn\n' | "$CS_BIN" -rm "myproj@fix-auth" > /dev/null 2>&1
    assert_not_exists "$wt" "worktree dir removed"
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept when declined"
}

run_test test_rm_worktree_unregisters_and_prompts_branch
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_worktrees.sh`
Expected: FAILS — current `remove_session` does `rm -rf`, which deletes the directory but leaves the worktree registered (`git worktree list` still shows it) and never prompts about the branch.

- [ ] **Step 3: Implement worktree-aware removal**

In `remove_session()` (bin/cs:2280), insert after the existence check (after line 2291):

```bash
    # Worktree sessions: unregister from git, not just delete the directory.
    case "$session_name" in
        *@*)
            local wt_base_name="${session_name%%@*}"
            local wt_base_dir="$SESSIONS_ROOT/$wt_base_name"
            [ -L "$wt_base_dir" ] && wt_base_dir="$(readlink -f "$wt_base_dir")"
            if [ -d "$wt_base_dir" ] && [ -f "$session_dir/.git" ]; then
                local wt_branch
                wt_branch=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
                read -r -p $'\033[0;31mRemove worktree session '"'$session_name'"$'? Uncommitted work in it is discarded. [y/N] \033[0m' confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    info "Cancelled"
                    return 0
                fi
                git -C "$wt_base_dir" worktree remove --force "$session_dir" 2>/dev/null \
                    || error "git worktree remove failed for $session_dir"
                if [ -n "$wt_branch" ] \
                    && git -C "$wt_base_dir" rev-parse -q --verify "refs/heads/$wt_branch" >/dev/null 2>&1; then
                    read -r -p "Delete branch $wt_branch too? [y/N] " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        git -C "$wt_base_dir" branch -D "$wt_branch" 2>/dev/null || true
                    fi
                fi
                info "Removed worktree session: $session_name"
                return 0
            fi
            ;;
    esac
```

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_worktrees.sh && bash tests/test_remove.sh 2>/dev/null; true`
Expected: PASS (run whichever removal suite exists — `ls tests/ | grep -i remov`).

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_worktrees.sh
git commit -m "feat: cs -rm unregisters worktree sessions via git worktree remove"
```

---

### Task 9: Doctor — worktree health checks

**Files:**
- Modify: `bin/cs` (new `_doctor_check_worktrees()` near `_doctor_check_shadow_ref`, line 1959; register in the doctor runner beside line 2105)
- Test: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `_doctor_ok` / `_doctor_warn` (used by every doctor check), `task_branch` local-state key.
- Produces: doctor warnings for (a) `@`-dirs not registered as worktrees, (b) HEAD differing from the pinned `task_branch`, (c) fully-merged branches whose worktree lingers.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_worktrees.sh`:

```bash
test_doctor_flags_dangling_and_merged_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@done-task"
    # Simulate a completed-but-unmerged-cleanup state: merge manually
    (cd "$CS_SESSIONS_ROOT/myproj@done-task" && echo x > f && git add f && git commit -q -m t)
    (cd "$base_dir" && git merge -q --no-edit cs/done-task)
    # And a dangling dir that git does not know about
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost/.cs/local"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_contains "$output" "ghost" "dangling @-dir flagged"
    assert_output_contains "$output" "done-task" "merged-but-present worktree flagged"
}

run_test test_doctor_flags_dangling_and_merged_worktrees
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_worktrees.sh`
Expected: FAILS (doctor has no worktree awareness).

- [ ] **Step 3: Implement the check**

In `bin/cs`, add before `_doctor_check_shadow_ref` (line 1959):

```bash
_doctor_check_worktrees() {
    local root="$SESSIONS_ROOT"
    local d name base_name base_dir d_real pinned head_branch
    for d in "$root"/*@*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        base_name="${name%%@*}"
        base_dir="$root/$base_name"
        [ -L "$base_dir" ] && base_dir="$(readlink -f "$base_dir")"
        if [ ! -d "$base_dir" ]; then
            _doctor_warn "Worktrees: $name has no base session '$base_name'"
            continue
        fi
        d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
        if ! git -C "$base_dir" worktree list --porcelain 2>/dev/null \
            | grep -qx "worktree $d_real"; then
            _doctor_warn "Worktrees: $name is not a registered worktree of $base_name (pruned or created by hand?)"
            continue
        fi
        pinned=$(_read_local_state "$d/.cs/local/state" task_branch)
        head_branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "")
        if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
            _doctor_warn "Worktrees: $name HEAD is '$head_branch', expected '$pinned'"
            continue
        fi
        if [ -n "$pinned" ] \
            && git -C "$base_dir" merge-base --is-ancestor "$pinned" HEAD 2>/dev/null; then
            _doctor_warn "Worktrees: $name branch $pinned is fully merged; finish with: cs $base_name --merge ${name#*@}"
        else
            _doctor_ok "Worktrees: $name on ${head_branch:-<detached>}"
        fi
    done
}
```

Register it in the doctor runner: locate the call list containing `_doctor_check_shadow_ref` (line 2105) and add `_doctor_check_worktrees` on the next line.

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_worktrees.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs tests/test_worktrees.sh
git commit -m "feat: doctor checks for dangling, desynced, and merged worktrees"
```

---

### Task 10: Full suite, docs, changelog

**Files:**
- Modify: `README.md` (worktree section under the session docs; update the feature list at line 28 area)
- Modify: `CHANGELOG.md` (new entry at top)
- Test: entire suite

**Interfaces:**
- Consumes: everything above.
- Produces: documented feature; green tree.

- [ ] **Step 1: Run the full test suite**

Run: `for f in tests/test_*.sh; do echo "== $f"; bash "$f" || exit 1; done`
Expected: every suite PASSES with pristine output. Fix anything that fails before touching docs (all test failures are ours).

- [ ] **Step 2: Write README section**

Add to `README.md` after the "Sharing a session between machines" section (line ~177), following its heading style:

```markdown
### Parallel task worktrees

Work two tasks on one session at the same time, each in its own Claude
conversation:

    cs myproj@fix-auth     # creates a git worktree of myproj on branch cs/fix-auth
    cs myproj@perf         # a second, independent working copy

Each worktree is a full cs session (own conversation, color, artifacts, crash
recovery) that shares the base session's task list and secrets. Session
records fork with the branch and re-fuse at merge:

    cs myproj --merge fix-auth   # merge cs/fix-auth, fuse records, remove worktree

cs never commits for you: creation and merge refuse dirty checkouts and tell
you what to commit. Abandon a task with `cs -rm myproj@fix-auth`. Repos that
gitignore `.cs/` get a per-worktree `.cs/` whose records are fused explicitly
at merge. Requires git >= 2.20.
```

- [ ] **Step 3: Add CHANGELOG entry**

Prepend to `CHANGELOG.md` under a new version heading, matching the file's existing format (inspect the top entry for the exact heading style):

```markdown
- Parallel task worktrees: `cs <base>@<task>` opens an isolated worktree
  session on branch `cs/<task>`; `cs <base> --merge <task>` merges it back,
  fuses session records, and removes the worktree; `cs -rm <base>@<task>`
  abandons one. Autosave crash-recovery moved to per-worktree
  `refs/worktree/cs/auto` (legacy `refs/cs/auto` migrates on resume). The
  artifact tracker no longer redirects writes targeting paths outside the
  session checkout. Doctor gains worktree health checks.
```

- [ ] **Step 4: Final full-suite run and commit**

Run: `for f in tests/test_*.sh; do bash "$f" > /dev/null || { echo "FAIL: $f"; exit 1; }; done && echo ALL GREEN`
Expected: `ALL GREEN`

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document parallel task worktrees"
```

---

## Post-plan notes for the executor

- The spec (`docs/superpowers/specs/2026-07-02-worktrees-design.md`) is the
  arbiter for any behavior question this plan under-specifies.
- Existing suites that may reference renamed things: `rg -l 'refs/cs/auto' tests/ bin/ hooks/ docs/` after Task 4 must return only CHANGELOG/spec/plan mentions.
- Do NOT touch install.sh hook registration — no hooks were added or removed.
- The statusline needs no changes; verify by running `bash tests/test_statusline.sh` at the end.
