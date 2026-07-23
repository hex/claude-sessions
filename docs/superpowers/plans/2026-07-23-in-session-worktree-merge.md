# In-session Worktree Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `cs <base> --merge <feature>` from the live base conversation while preserving hard refusal for the feature conversation, foreign live sessions, and reused PIDs.

**Architecture:** Add one fail-closed PID-ancestry predicate beside the existing lock helpers and combine it with exact ambient session-name matching. Apply that ownership predicate only in the worktree merge guard, with an earlier explicit Scenario A refusal; leave the merge and cleanup transaction unchanged.

**Tech Stack:** macOS stock `/bin/bash` 3.2, BSD `ps`, git worktrees, the repository's Bash test harness.

## Global Constraints

- Edit `lib/*.sh`, never `bin/cs`; regenerate with `./build.sh`.
- Use no Bash 4 features and no GNU-only userland flags.
- Exempt only the verified invoking session's own lock.
- Keep all pending or machine-specific state out of tracked files; this design adds no pending state.

---

### Task 1: Lock-ownership regression coverage

**Files:**
- Modify: `tests/test_worktrees.sh`

**Interfaces:**
- Consumes: `cs <base> --merge <feature>`, `.cs/session.lock`, `.cs/local/state`.
- Produces: four integration tests pinning base ownership, feature self-merge, foreign identity, and PID reuse.

- [ ] **Step 1: Write the failing Scenario B test**

Create an ignored-`.cs` base and feature, commit a feature file, add a feature
timeline record, write the test shell's PID to the base lock, and invoke:

```bash
CLAUDE_SESSION_NAME="myproj" \
CS_CLAUDE_SESSION_ID="$base_uuid" \
"$CS_BIN" "myproj" --merge "fix-auth"
```

Assert exit zero, merged code and timeline data, and removed worktree.

- [ ] **Step 2: Write the failing Scenario A test**

Write the test shell's PID to the feature lock and invoke the merge from the
feature directory with `CLAUDE_SESSION_NAME="myproj@fix-auth"`. Assert nonzero,
an error containing `Close 'myproj@fix-auth'`, and preservation of the
worktree.

- [ ] **Step 3: Write foreign-lock and PID-reuse tests**

For the foreign case, make the base lock PID an ancestor but set
`CLAUDE_SESSION_NAME="foreign"` with the base UUID. For PID reuse, set the base
lock to a live `sleep` child while passing the matching base name and UUID.
Both must retain the existing `session is open` refusal.

- [ ] **Step 4: Run the focused suite and verify RED**

Run:

```bash
bash tests/test_worktrees.sh
```

Expected: Scenario B fails because the current guard reports `A session is
open`; Scenario A fails because it receives only the generic refusal. The
foreign and PID-reuse tests already refuse.

### Task 2: Ownership-aware merge guard

**Files:**
- Modify: `lib/15-lock.sh`
- Modify: `lib/30-worktree.sh`

**Interfaces:**
- Produces: `_pid_is_self_or_ancestor <pid>` and
  `session_lock_owned_by_invoker <session-name> <lock-pid>`.
- Consumes: `CLAUDE_SESSION_NAME`, `$$`, and `ps -o ppid= -p`.

- [ ] **Step 1: Add the fail-closed ancestry helper**

Implement a bounded parent walk:

```bash
_pid_is_self_or_ancestor() {
    local target="$1" current="$$" parent="" depth=0
    case "$target" in ''|*[!0-9]*) return 1 ;; esac
    while [ "$depth" -lt 64 ]; do
        [ "$current" = "$target" ] && return 0
        [ "$current" -gt 1 ] || return 1
        parent=$(ps -o ppid= -p "$current" 2>/dev/null \
            | awk 'NR == 1 { print $1 }')
        case "$parent" in ''|*[!0-9]*) return 1 ;; esac
        [ "$parent" != "$current" ] || return 1
        current="$parent"
        depth=$((depth + 1))
    done
    return 1
}
```

Add the exact-name wrapper:

```bash
session_lock_owned_by_invoker() {
    [ -n "${CLAUDE_SESSION_NAME:-}" ] \
        && [ "$CLAUDE_SESSION_NAME" = "$1" ] \
        && _pid_is_self_or_ancestor "$2"
}
```

- [ ] **Step 2: Narrow Scenario A**

Before the lock loop, reject an exact worktree-session invoker:

```bash
if [ "${CLAUDE_SESSION_NAME:-}" = "$base_name@$task" ]; then
    error "Cannot merge '$base_name@$task' from inside that worktree session. Close '$base_name@$task', then run: cs $base_name --merge $task (from '$base_name' or a free terminal)"
fi
```

- [ ] **Step 3: Exempt only the verified base lock**

Associate each lock path with its session name. When a PID is live, continue
only if `session_lock_owned_by_invoker "$lock_session" "$pid"` succeeds;
otherwise preserve the existing hard error.

- [ ] **Step 4: Build and verify GREEN**

Run:

```bash
./build.sh
bash tests/test_worktrees.sh
```

Expected: generated `bin/cs` passes syntax checking and every worktree test
passes.

### Task 3: Merge-skill documentation

**Files:**
- Modify: `skills/merge/SKILL.md`
- Modify: `tests/test_merge_skill.sh`

**Interfaces:**
- Produces: user guidance matching the new Scenario A/B behavior.

- [ ] **Step 1: Add a failing contract assertion**

Require the skill to contain `from the base session` and
`Close the feature session`.

- [ ] **Step 2: Verify RED**

Run:

```bash
bash tests/test_merge_skill.sh
```

Expected: the new wording assertions fail against the old universal hand-off
paragraph.

- [ ] **Step 3: Replace the universal hand-off paragraph**

State that the verb may run from the base session once the feature is closed,
that any foreign live lock still refuses, and that self-merge from the feature
requires closing it and handing the exact command to the base/free terminal.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
bash tests/test_merge_skill.sh
```

Expected: all merge-skill contract tests pass.

### Task 4: Full verification and trace

**Files:**
- Verify generated: `bin/cs`
- Verify all changed source and test files.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: fresh build, full-suite evidence, exact citations, and an edge-case trace.

- [ ] **Step 1: Regenerate and compare**

Run `./build.sh`, `bash -n bin/cs`, and inspect `git diff --check` plus the
fragment/generated diff.

- [ ] **Step 2: Run focused and full tests**

Run:

```bash
bash tests/test_worktrees.sh
bash tests/test_merge_skill.sh
bash tests/run_all.sh
```

Expected: zero failures.

- [ ] **Step 3: Exercise sandboxed Scenario A and B**

Use the real generated `bin/cs` against temporary git repositories and live
parent locks. Confirm base-session merge removes the feature and feature-session
self-merge preserves it with the narrowed error.

- [ ] **Step 4: Trace every lock combination**

Check base-own/worktree-closed, feature-own, foreign base, foreign feature,
stale base, stale feature, reused PID, missing ambient identity, and a foreign
alias sharing a resolved checkout. Re-read the four named hazards and record
whether code or the retained guard addresses each.

- [ ] **Step 5: Recompute citations**

Run `nl -ba` over `lib/15-lock.sh`, `lib/30-worktree.sh`,
`lib/75-launch.sh`, `lib/45-migrate.sh`, and `skills/merge/SKILL.md` after all
edits. Use only those final line numbers in the report.

