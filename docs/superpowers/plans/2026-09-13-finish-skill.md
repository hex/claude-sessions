# /finish Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `/merge` with `/finish`: integrate a feature worktree's captured commit into its base session while the feature conversation stays open, report GitHub PR state, and remove nothing.

**Architecture:** One unadvertised cs entry, `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>`, owns every invariant (ownership, dirt, mutex, temp-worktree merge, gates, fast-forward). A deterministic script `skills/finish/scripts/finish.sh` does the read-only half (context, capture, PR lookup, report) and prints `key: value` lines the skill reads. `skills/finish/SKILL.md` is the ritual the model follows. The autosave hook learns to label snapshots with the HEAD it started from and to skip while an integrate holds the mutex. Retirement stays exactly today's `cs <base> --merge <task>`.

**Tech Stack:** bash (assembled into `bin/cs` from `lib/*.sh` by `./build.sh`), git plumbing, `gh` (read only), jq, Rust/ratatui for one TUI pane.

**Spec:** `docs/superpowers/specs/2026-09-12-finish-skill-design.md` (committed `14d1a48`). Every line number below was read at `14d1a48`.

## Where this plan departs from the spec's file table

Read these before Task 1; each is a fact found in the source, not a design change. Alex decides whether any of them is wrong.

1. **Autosave hook tests go in `tests/test_shadow_ref.sh`, not `tests/test_hooks.sh`.** That suite already runs the hook in the foreground (`CS_TEST_SYNC=1`), owns a git-repo `setup()`, and holds the existing `cs-base` pin (`test_autosave_stamps_base_head`). `test_hooks.sh` has no git fixture for this hook.
2. **Two hooks tell the feature-worktree Claude that integration only happens via `--merge` after the session closes** (`hooks/session-start.sh:670-673`, `hooks/subagent-context.sh:59`), and `tests/test_hooks.sh` `test_subagent_context_announces_worktree_task` pins "cs --merge". That sentence becomes false the day `/finish` ships. Task 6 rewords both; the spec's file table does not list them.
3. **The TUI's detail pane prints an "ON FINISH" plan** (`tui/src/ui.rs:2042-2076`) whose step 2 reads "merge into <base> … fuse records, remove worktree, delete branch", with three Rust tests pinning that wording (`ui.rs:4512`, `4530`, `4618`). After this change Enter arms `/finish`, which removes nothing, so the pane would lie. Task 7 rewrites the plan text and its tests. The spec names only the footer at `ui.rs:954` (already correct).
4. **The temp-worktree merge also runs with hooks suppressed** (`-c core.hooksPath=<empty dir>`), not only the `worktree add`. A project's `post-merge`/`prepare-commit-msg` hooks would otherwise fire inside `.git/cs/finish/`; the gates the skill discovers are the project's gate, run explicitly in step 8.
5. **`git rev-parse --git-common-dir` answers `.git` (relative) from a main checkout and an absolute path from a linked worktree** (probed 2026-09-13, git 2.50.1). Both the hook and the entry go through one absolutising helper so the mutex resolves to a single directory. Also probed: `git worktree add` accepts a path under `.git/cs/finish/`, and `mkdir` on an existing directory fails, so the spec's temp location and mutex both hold.
6. **The gate command is argv after `--`, executed as `"$@"` in the temp worktree, never a string through `bash -c`.** The skill passes the discovered command's words.
7. **The lock-inspection loop in `merge_worktree_session` (`lib/30-worktree.sh:353-368`) is extracted into `_foreign_live_lock_pid`** so the new entry and the verb share one ownership implementation. The verb's behaviour and its eight lock tests are unchanged.
8. **The "already integrated" outcome prints a machine line `already-integrated <task> <sha>`**, parallel to `integrated <task> <sha> -> <R>`, so `finish.sh`/the skill parse one shape.
9. **`CHANGELOG.md` has no `## Unreleased` heading today**; Task 8 adds one.
10. **In tracked-`.cs` mode the integrate's own `feature-integrated` timeline event dirties the base**, and the retire verb refuses dirt (`lib/30-worktree.sh:381-382`). Retirement is not changed; the report's `retire:` line tells the user to commit the bookkeeping first, and the load-bearing "then `--merge` takes the ancestor path" test stages exactly that sequence.
11. **Every cleanup trap is `EXIT` plus `INT TERM`** (measured: a TERM'd bash skips `EXIT`, exit 143, no cleanup), as `lib/75-launch.sh:112-113` already does. Submodules are updated after the temp merge, not before, so gates see the merged gitlinks.
12. **`finish.sh` reports every porcelain line, including `.cs/`**; the retire verb's untracked filter is a removal-risk filter and integrate removes nothing. And PR lookup answers `unknown` for two OPEN PRs or a MERGED beside an OPEN one (a reused branch), naming the numbers, rather than picking one.

A Codex read-only pass (2026-09-13, sandboxed, no git probes possible there) produced fourteen findings; every one was checked against the source and folded, which is where departures 10–12, the pre-landing re-verification in Task 3, the four launch-kick pins in Task 6, the two extra TUI tests in Task 7, and the exit-status capture in every validation command come from.

## Global Constraints

- **Never edit `bin/cs` directly.** It is assembled from `lib/[0-9]*-*.sh` by `./build.sh`. After editing any `lib/*.sh`, run `./build.sh` and commit the regenerated `bin/cs` with the change; `tests/test_install.sh` `test_manifest_arrays_in_sync` compares `install.sh` against the BUILT `bin/cs`.
- **Shell portability floor: macOS stock `/bin/bash` 3.2.57 with BSD userland**, for `lib/`, `hooks/`, `skills/*/scripts/` AND `tests/`. No `local -A`, `mapfile`, `${var,,}`, `printf '%(...)T'`, `source <()`. No GNU-only `sed -i`, `grep -P`, `stat -c`, `timeout`, `readlink -f`. No `flock`. `mktemp` always takes the template form `mktemp "${TMPDIR:-/tmp}/name.XXXXXX"` (`mktemp -t` is BSD-only). `/dev/null` is not a directory, so `core.hooksPath` gets a real empty directory.
- **`run_test` calls the test function inside an `if`, which disables errexit for the whole body.** Every assertion MUST be followed by `|| return 1`.
- **`assert_file_contains` is a BRE regex, line-based, case-sensitive.** Escape `[`, `]`, `.`, `*`, `\` in literals; copy the pin FROM the production line.
- **No real names, emails, usernames or handles** in fixtures, test names, assertion strings, comments or docs. Placeholders: `myproj`, `fix-auth`, `example-org/example-repo`, `example.com`.
- **cs never pushes and never commits for the user.** The entry's only commit is the merge commit in the temp worktree, fast-forwarded into base.
- **Manifests are pairs marked KEEP IN SYNC:** `CS_SKILLS`, `RETIRED_SKILLS`, `CS_SKILL_FILES` in `lib/00-header.sh:82-104` and `install.sh:143-166`. Edit both or `test_install.sh` fails.
- **A new session-dispatch arm must carry `# hidden: …` ON THE SAME LINE as the `)`**; `tests/test_completions.sh:503-511` derives the completion set from `lib/99-main.sh` and only `grep -v '# hidden'` excludes an arm. Precedent: `lib/99-main.sh:97`. The arm also stays out of the unknown-command string at `lib/99-main.sh:367`, `lib/10-help.sh`, `completions/`, and README.
- **The Bash tool in this harness is zsh.** Write multi-line probes and shims to a file and run them with `bash`.
- **No foreground `sleep`, no foreground full-suite runs.** The edit loop is `bash tests/run_all.sh --changed`; `lib/` and `hooks/` changes take the full suite on ghost via the `claude-tmux:remote-tests` skill, in the background.
- **Never run bare `cargo fmt` in `tui/`.** Match surrounding style by hand.
- **Commit after every task** on branch `feat/finish-skill`. Commit messages: `feat(finish): …`, `fix(autosave): …`, `test(…): …`, `docs(…): …`.
- Baseline at plan time: `main` at `14d1a48`, clean; v2026.9.13 released.

---

### Task 1: The autosave hook labels the HEAD it started from and yields to an integrate

**Files:**
- Modify: `hooks/autosave-commits.sh:88-129` (`autosave_to_shadow_ref`)
- Modify: `docs/hooks.md:101-109` (autosave contract)
- Test: `tests/test_shadow_ref.sh` (append after `test_autosave_writes_per_conversation_ref`)

**Interfaces:**
- Consumes: nothing new.
- Produces: the mutex path contract `<git-common-dir>/cs/integrate.lock` (a directory, taken with plain `mkdir`, released with `rmdir`). Task 2 takes the same path from `lib/30-worktree.sh`; Task 2 adds a pin test that both files spell it identically.

- [ ] **Step 1: Write the three failing tests**

Append to `tests/test_shadow_ref.sh` before the `run_test` block (the file's `setup()` already exports `CS_TEST_SYNC=1` and builds a git repo at `$CLAUDE_SESSION_DIR`):

```bash
# A HEAD that moves while the snapshot is in flight must not relabel the OLD
# tree as sitting on the NEW head: crash recovery reads cs-base to decide
# whether a whole-tree restore is safe. Stage the move with a git shim that
# advances HEAD the moment the hook asks for write-tree — the exact window an
# integrate's fast-forward can land in.
test_autosave_labels_the_head_it_started_from() {
    local real_git shim_dir head_before
    real_git=$(command -v git)
    shim_dir="$TEST_TMPDIR/shim"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/git" << SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "write-tree" ]; then
    ( unset GIT_INDEX_FILE; "$real_git" commit -q --allow-empty -m moved ) >/dev/null 2>&1
fi
exec "$real_git" "\$@"
SHIM
    chmod +x "$shim_dir/git"
    head_before=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"session_id":"22222222-2222-2222-2222-222222222222","tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | PATH="$shim_dir:$PATH" bash "$HOOKS_DIR/autosave-commits.sh"

    # Positive control: the shim really moved HEAD, or the test proves nothing.
    [ "$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)" != "$head_before" ] \
        || { echo "  FAIL: the shim did not move HEAD; the test staged nothing"; return 1; }
    local msg
    msg=$(git -C "$CLAUDE_SESSION_DIR" log -1 --format=%B refs/worktree/cs/session/22222222-2222-2222-2222-222222222222 2>/dev/null || true)
    case "$msg" in
        *"cs-base: $head_before"*) return 0 ;;
        *) echo "  FAIL: cs-base must be the HEAD at hook start ($head_before)"
           echo "    message: $msg"
           return 1 ;;
    esac
}

# An integrate in progress holds <common-dir>/cs/integrate.lock. A snapshot
# taken mid-merge is garbage, so the hook skips — never waits, never steals.
test_autosave_skips_while_the_integrate_lock_is_held() {
    mkdir -p "$CLAUDE_SESSION_DIR/.git/cs/integrate.lock"
    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"session_id":"22222222-2222-2222-2222-222222222222","tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/session/22222222-2222-2222-2222-222222222222 >/dev/null 2>&1; then
        echo "  FAIL: no snapshot may be written while the integrate lock is held"; return 1
    fi
    assert_dir "$CLAUDE_SESSION_DIR/.git/cs/integrate.lock" "the hook must not remove a lock it does not hold" || return 1
}

test_autosave_holds_the_lock_during_the_snapshot_and_releases_it() {
    # Observe the lock at write-tree time through a git shim; a release
    # assertion alone passes when no lock is ever taken.
    local real_git shim_dir
    real_git=$(command -v git)
    shim_dir="$TEST_TMPDIR/shim"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/git" << SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "write-tree" ]; then
    if [ -d .git/cs/integrate.lock ]; then echo held > "$TEST_TMPDIR/lock-seen"; else echo absent > "$TEST_TMPDIR/lock-seen"; fi
fi
exec "$real_git" "\$@"
SHIM
    chmod +x "$shim_dir/git"
    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"session_id":"22222222-2222-2222-2222-222222222222","tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | PATH="$shim_dir:$PATH" bash "$HOOKS_DIR/autosave-commits.sh"
    git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/session/22222222-2222-2222-2222-222222222222 >/dev/null 2>&1 \
        || { echo "  FAIL: snapshot should have been written"; return 1; }
    assert_eq "held" "$(cat "$TEST_TMPDIR/lock-seen" 2>/dev/null)" "the lock is held while the tree is written" || return 1
    assert_not_exists "$CLAUDE_SESSION_DIR/.git/cs/integrate.lock" "the hook releases the lock after the snapshot" || return 1
}
```

Add to the `run_test` block, next to the other autosave tests:

```bash
run_test test_autosave_labels_the_head_it_started_from
run_test test_autosave_skips_while_the_integrate_lock_is_held
run_test test_autosave_holds_the_lock_during_the_snapshot_and_releases_it
```

- [ ] **Step 2: Run the suite to see the three fail**

Run: `bash tests/test_shadow_ref.sh > "$TMPDIR/t1.out" 2>&1; echo "rc=$?"; grep -A3 'FAIL' "$TMPDIR/t1.out"`
Expected: rc=1; the first fails with `cs-base must be the HEAD at hook start`, the second with `no snapshot may be written`, the third with `the lock is held while the tree is written` (the shim saw `absent`).

- [ ] **Step 3: Rewrite `autosave_to_shadow_ref`**

Replace `hooks/autosave-commits.sh:88-129` with:

```bash
# Autosave to shadow ref using git plumbing (does not touch HEAD or main branch)
# Fires on ALL Write/Edit — protects all files, not just the narrative
autosave_to_shadow_ref() {
    cd "$SESSION_DIR" || return 0

    # The HEAD this snapshot sits on, read BEFORE the tree is written. An
    # integrate can fast-forward HEAD while the snapshot is in flight; a label
    # read afterwards would claim the old tree sits on the new HEAD, which is
    # exactly the stale-snapshot case the cs-base trailer exists to expose.
    # Absent (unborn HEAD) => no trailer, which recovery reads as "unknown base"
    # and refuses the blanket restore.
    base=$(git rev-parse -q --verify HEAD 2>/dev/null || true)

    # Serialise against `cs <base> -integrate-feature`, which holds the same
    # directory while it merges and fast-forwards the base. Skip, never wait:
    # a snapshot taken mid-merge is garbage and the next Edit takes another.
    # Taken here, inside the backgrounded function, so there is no window
    # between the check and the fork. Common dir, not --git-dir: a linked
    # worktree's --git-dir is private to that worktree and the integrate runs
    # from the base. lib/30-worktree.sh spells the same path; a test pins both.
    GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    mkdir -p "$GIT_COMMON/cs" 2>/dev/null || return 0
    mkdir "$GIT_COMMON/cs/integrate.lock" 2>/dev/null || return 0
    (
        # EXIT does not fire on TERM/INT (measured: exit 143, no cleanup), so
        # both get a handler that releases and then exits.
        trap 'rmdir "$GIT_COMMON/cs/integrate.lock" 2>/dev/null' EXIT
        trap 'rmdir "$GIT_COMMON/cs/integrate.lock" 2>/dev/null; exit 143' TERM INT

        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

        # Create temporary index from current index
        TEMP_INDEX=$(mktemp "${TMPDIR:-/tmp}/cs-autosave.XXXXXX")
        cp "$GIT_DIR/index" "$TEMP_INDEX"

        # Stage all current files in the temporary index
        GIT_INDEX_FILE="$TEMP_INDEX" git add -A 2>/dev/null || { rm -f "$TEMP_INDEX"; exit 0; }

        # Write tree object from temporary index
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree 2>/dev/null) || { rm -f "$TEMP_INDEX"; exit 0; }
        rm -f "$TEMP_INDEX"

        msg="autosave: $TIMESTAMP"
        [ -n "$base" ] && msg="$msg

cs-base: $base"

        # Chain onto this conversation's previous autosave if it exists
        parent=$(git rev-parse -q --verify "$SESSION_REF" 2>/dev/null || true)
        if [ -n "$parent" ]; then
            commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" -p "$parent" 2>/dev/null) || exit 0
        else
            commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" 2>/dev/null) || exit 0
        fi

        git update-ref "$SESSION_REF" "$commit" 2>/dev/null || exit 0

        if [ -n "$LATEST_ENTRY" ]; then
            echo "[$TIMESTAMP] Autosave: $LATEST_ENTRY" >> "$META_DIR/local/session.log"
        fi
    )
}
```

Note every former `return 0` inside the body became `exit 0`: the body now runs in a subshell so the `trap … EXIT` releases the lock on every path. The `mktemp` gained the template form the constraints require (the old bare `mktemp` was a latent GNU/BSD divergence).

- [ ] **Step 4: Run the suite to see everything pass**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -5`
Expected: `Results: N/N passed, 0 failed` (N = previous count + 3).

- [ ] **Step 5: Update the hook contract in `docs/hooks.md`**

In the `## autosave-commits.sh` section (line 101), replace the `cs-base` bullet (line 107) with:

```markdown
- Records the HEAD the snapshot sits on as a `cs-base` commit trailer, read before the tree is written so a HEAD that moves mid-snapshot is never mislabelled; crash recovery uses it to tell whether HEAD has since moved and refuse an unsafe whole-tree restore
- Skips the snapshot (never waits) while `<git-common-dir>/cs/integrate.lock` exists — the mutex `cs <base> -integrate-feature` holds while it fast-forwards the base — and holds that same directory itself for the duration of the tree write
```

- [ ] **Step 6: Commit**

```bash
git checkout -b feat/finish-skill
git add hooks/autosave-commits.sh docs/hooks.md tests/test_shadow_ref.sh
git commit -m "fix(autosave): label snapshots with the HEAD they started from; yield to an integrate"
```

---

### Task 2: The hidden entry refuses everything it must

**Files:**
- Modify: `lib/30-worktree.sh` (new helpers after `_worktree_untracked_at_risk` at line 73; new `integrate_feature_worktree` after `merge_worktree_session`, i.e. after line 425; `merge_worktree_session:353-368` uses the extracted helper)
- Modify: `lib/99-main.sh:341-350` (new arm before `--merge`)
- Test: `tests/test_worktrees.sh` (new section after `test_merge_rejects_traversal_task_name`'s `run_test` at line 508)

**Interfaces:**
- Produces: `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate argv...>`; exit 1 with `Error: …` on every refusal; on an already-integrated SHA prints `already-integrated <task> <sha>` and exits 0. Task 3 fills in the mutation after the refusals. `_foreign_live_lock_pid session_name lock_file` prints the PID of a live lock the invoker does not own, else nothing. `_git_path_abs checkout_dir <rev-parse-flag>` prints an absolute path. Gate argv contract: everything after `--` is executed verbatim as `"$@"` with the temp worktree as cwd; at least one word is required (`-- true` runs no gate).

- [ ] **Step 1: Confirm cs's error-mode and trap situation before adding a trap**

Run: `grep -n '^set -' lib/00-header.sh; grep -n "trap " lib/*.sh`
Expected: `set -euo pipefail` in the header; the only EXIT traps are in `lib/75-launch.sh:112-113`, on the launch path, which `-integrate-feature` returns before reaching (it `return 0`s from `run_session` the way `-features` does at `lib/99-main.sh:338-342`). So a trap set inside `integrate_feature_worktree` is the only EXIT trap on this path. If the grep shows otherwise, stop and report before continuing.

- [ ] **Step 2: Write the failing refusal tests**

Insert into `tests/test_worktrees.sh` after line 508 (`run_test test_merge_rejects_traversal_task_name`):

```bash
# --- -integrate-feature: integrate while the feature stays open, remove nothing ---

# Build base + feature with one feature commit; prints the feature SHA.
integrate_fixture() {  # base task
    local base_dir wt
    base_dir=$(create_test_session_with_git "$1")
    cs_launch "$1@$2"
    wt="$CS_SESSIONS_ROOT/$1@$2"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    git -C "$wt" rev-parse HEAD
}

test_integrate_refuses_unknown_worktree() {
    create_test_session_with_git "myproj" > /dev/null
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature ghost HEAD -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an unregistered worktree refuses" || return 1
    assert_output_contains "$output" "not a registered worktree" "names the reason" || return 1
}

test_integrate_refuses_sha_not_on_feature_branch() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "base only")
    local stray output status=0
    stray=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$stray" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a commit not reachable from cs/<task> refuses" || return 1
    assert_output_contains "$output" "not reachable from cs/fix-auth" "names the branch" || return 1
}

test_integrate_reports_already_integrated_and_does_nothing() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "already integrated exits 0: $output" || return 1
    assert_output_contains "$output" "already-integrated fix-auth $sha" "machine line printed" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "no commit is made" || return 1
}

test_integrate_refuses_dirty_base() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "edit" >> "$base_dir/CLAUDE.md"
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "dirty base refuses" || return 1
    assert_output_contains "$output" "uncommitted changes" "names the dirt" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
}

test_integrate_refuses_foreign_live_base_lock() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # A live PID that is not an ancestor of the cs process: the ps stub reports
    # PID 1 as every process's parent, so the ancestry walk never reaches $$.
    echo "$$" > "$base_dir/.cs/session.lock"
    local ps_stub output status=0
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CLAUDE_SESSION_NAME="other" CS_PS_BIN="$ps_stub" \
        "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a foreign live base lock refuses" || return 1
    assert_output_contains "$output" "open elsewhere" "names the live base" || return 1
}

test_integrate_ignores_the_feature_lock() {
    # The feature session stays open: its lock is not a blocker because the
    # integrate never touches the feature worktree. Here it only has to get
    # PAST every refusal, which Task 2's placeholder proves by refusing with
    # its own fixed message. Task 3 replaces this pin with the real happy path
    # (test_integrate_lands_a_no_ff_merge_and_keeps_everything repeats the
    # live-lock setup there).
    local sha base_dir wt
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"
    local ps_stub output status=0
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CS_PS_BIN="$ps_stub" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "the placeholder refuses" || return 1
    assert_output_contains "$output" "integrate is not implemented yet (refusals passed)" \
        "every refusal was passed with the feature lock live" || return 1
}

test_integrate_refuses_merge_in_progress() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # Stage a MERGE_HEAD without dirtying the tracked tree.
    git -C "$base_dir" rev-parse HEAD > "$base_dir/.git/MERGE_HEAD"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    rm -f "$base_dir/.git/MERGE_HEAD"
    assert_eq "1" "$status" "a merge in progress refuses" || return 1
    assert_output_contains "$output" "merge or rebase in progress" "names the state" || return 1
}

test_integrate_refuses_stale_mutex_and_names_it() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/cs/integrate.lock"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an existing mutex refuses" || return 1
    assert_output_contains "$output" "$base_dir/.git/cs/integrate.lock" "the refusal names the path" || return 1
    assert_dir "$base_dir/.git/cs/integrate.lock" "the mutex is never stolen" || return 1
}

test_integrate_requires_a_gate_command() {
    local sha output status=0
    sha=$(integrate_fixture myproj fix-auth)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "missing gate argv refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage" || return 1
}

test_integrate_requires_a_sha() {
    # `set -u` would otherwise turn a missing positional into an unbound-variable
    # crash instead of the usage line.
    integrate_fixture myproj fix-auth > /dev/null
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "missing sha refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage, not a shell error" || return 1
    assert_output_not_contains "$output" "unbound variable" "no set -u crash" || return 1
}

test_integrate_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -integrate-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-integrate-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'integrate-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'integrate-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'integrate-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'integrate-feature' "README never lists it" || return 1
}

test_integrate_and_autosave_spell_one_mutex_path() {
    # The hook cannot source lib/, so the path is spelled twice; this is the
    # only thing that keeps the two spellings equal.
    assert_file_contains "$SCRIPT_DIR/../hooks/autosave-commits.sh" 'cs/integrate\.lock' "hook names the mutex" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/30-worktree.sh" 'cs/integrate\.lock' "entry names the mutex" || return 1
}

run_test test_integrate_refuses_unknown_worktree
run_test test_integrate_refuses_sha_not_on_feature_branch
run_test test_integrate_reports_already_integrated_and_does_nothing
run_test test_integrate_refuses_dirty_base
run_test test_integrate_refuses_foreign_live_base_lock
run_test test_integrate_ignores_the_feature_lock
run_test test_integrate_refuses_merge_in_progress
run_test test_integrate_refuses_stale_mutex_and_names_it
run_test test_integrate_requires_a_gate_command
run_test test_integrate_requires_a_sha
run_test test_integrate_is_hidden_from_completion_and_unknown_command_text
run_test test_integrate_and_autosave_spell_one_mutex_path
```

- [ ] **Step 3: Run to see them fail**

Run: `bash tests/test_worktrees.sh 2>&1 | grep -A3 'test_integrate' | head -60`
Expected: every `test_integrate_*` fails with `Unknown session command: -integrate-feature` in the output, except the two pin tests, which fail on the missing `# hidden` arm / missing mutex spelling.

- [ ] **Step 4: Add the helpers to `lib/30-worktree.sh`**

Insert after `_worktree_untracked_at_risk` (after line 73):

```bash
# Print the PID of a live lock on a session that the invoker does not own:
# empty when the lock is absent, its process is dead, or the lock is the
# invoking conversation's own (session_lock_owned_by_invoker). The merge verb
# and the integrate entry both refuse on a non-empty answer.
_foreign_live_lock_pid() {  # session_name lock_file
    local pid
    [ -f "$2" ] || return 0
    pid=$(cat "$2" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
    session_lock_owned_by_invoker "$1" "$pid" && return 0
    printf '%s\n' "$pid"
}

# Absolute form of a `git rev-parse` path answer (--git-dir, --git-common-dir).
# git answers relative to the checkout from a main worktree and absolute from
# a linked one; every path built on the answer (the integrate mutex, the temp
# worktree) must resolve the same from both.
_git_path_abs() {  # checkout_dir rev-parse-flag
    local p
    p=$(git -C "$1" rev-parse "$2" 2>/dev/null) || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *) printf '%s\n' "$1/$p" ;;
    esac
}

# The same merge policy setup_merge_attributes (lib/45-migrate.sh:4) gives a
# checkout, written clone-local: merge.ours.driver into the shared config and
# the three attribute lines into <common>/info/attributes, which every
# worktree of the repo reads and which dirties no tree. The temp worktree
# checks out whatever .gitattributes the base has committed, which may lack
# these lines; without them tracked-mode timeline and narrative appends on
# both sides conflict instead of union-merging.
_setup_merge_attributes_clone_local() {  # base_dir common_dir
    git -C "$1" config merge.ours.driver true 2>/dev/null || true
    local attrs="$2/info/attributes"
    mkdir -p "$2/info"
    if ! grep -q 'MEMORY\.md merge=ours' "$attrs" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$attrs"
    fi
    if ! grep -q 'timeline\.jsonl merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/timeline.jsonl merge=union\n' >> "$attrs"
    fi
    if ! grep -q 'narrative\.\*\.md merge=union' "$attrs" 2>/dev/null; then
        printf '.cs/memory/narrative.*.md merge=union\n' >> "$attrs"
    fi
}

# Tracked-.cs mode: MEMORY.md merges with merge=ours, so a change to it on the
# feature is silently dropped by the merge that follows; say so first.
_warn_memory_index_changed() {  # base_dir ref
    local mb
    mb=$(git -C "$1" merge-base HEAD "$2" 2>/dev/null || echo "")
    if [ -n "$mb" ] \
        && ! git -C "$1" diff --quiet "$mb" "$2" -- .cs/memory/MEMORY.md 2>/dev/null; then
        warn "MEMORY.md changed on $2; merge=ours keeps the base copy. Review: git -C \"$1\" diff $mb $2 -- .cs/memory/MEMORY.md"
    fi
}
```

- [ ] **Step 5: Use the two helpers inside `merge_worktree_session`**

Replace `lib/30-worktree.sh:353-368` (the `local lock lock_session pid` loop) with:

```bash
    local lock lock_session pid
    for lock_session in "$base_name" "$wt_name"; do
        if [ "$lock_session" = "$base_name" ]; then
            lock="$base_dir/.cs/session.lock"
        else
            lock="$wt_dir/.cs/session.lock"
        fi
        pid=$(_foreign_live_lock_pid "$lock_session" "$lock")
        if [ -n "$pid" ]; then
            error "A session is open (PID $pid, $lock); close it before merging"
        fi
    done
```

Replace `lib/30-worktree.sh:393-400` (the `if [ "$mode" = "tracked" ]; then … fi` block inside the `else`) with:

```bash
        if [ "$mode" = "tracked" ]; then
            _warn_memory_index_changed "$base_dir" "$branch"
        fi
```

- [ ] **Step 6: Add `integrate_feature_worktree` with the refusals**

Insert after `merge_worktree_session` (after line 425, before `_append_jsonl`):

```bash
# Remove the temp worktree and release the mutex on every exit path of
# integrate_feature_worktree, including error's exit 1. Globals because an
# EXIT trap runs after the function's locals are gone.
_integrate_cleanup() {
    if [ -n "${_INTEGRATE_TMP:-}" ]; then
        # Remove if present, then prune regardless: a directory gone with its
        # registration surviving is exactly what prune exists for.
        if [ -d "$_INTEGRATE_TMP" ]; then
            git -C "$_INTEGRATE_BASE_DIR" worktree remove --force "$_INTEGRATE_TMP" >/dev/null 2>&1 \
                || rm -rf "$_INTEGRATE_TMP"
        fi
        git -C "$_INTEGRATE_BASE_DIR" worktree prune >/dev/null 2>&1 || true
    fi
    [ -n "${_INTEGRATE_LOCK:-}" ] && rmdir "$_INTEGRATE_LOCK" 2>/dev/null
    return 0
}

# Integrate a feature worktree's captured commit into the base session while
# the feature stays open: merge base HEAD + <sha> in a temporary detached
# worktree, run the gates there, fast-forward the base onto the result. Removes
# nothing — the worktree, the branch and the feature session all remain; the
# merge verb retires them later. Backs the unadvertised
# `cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate...>`
# that skills/finish/scripts/finish.sh drives. Every refusal is an error that
# names the next command.
integrate_feature_worktree() {  # base_name task sha [--from-remote] -- gate...
    local usage="Usage: cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>"
    [ $# -ge 3 ] || error "$usage"
    local base_name="$1" task="$2" sha="$3"
    shift 3
    local from_remote=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-remote) from_remote=1; shift ;;
            --) shift; break ;;
            *) error "$usage" ;;
        esac
    done
    [ $# -gt 0 ] || error "$usage (a gate command is required; pass -- true to run none)"

    local base_dir wt_dir branch
    base_dir=$(_resolve_session_dir "$base_name")
    wt_dir="$SESSIONS_ROOT/$base_name@$task"
    branch="cs/$task"
    [ -d "$base_dir" ] || error "Base session not found: $base_name"
    [ -d "$wt_dir" ] || error "No worktree for feature '$task' (expected $wt_dir)"
    # Herestring, not a pipe: grep -q's early exit would SIGPIPE the writer
    # and pipefail would read that as "not registered".
    local features
    features=$(_worktree_features "$base_name")
    grep -qxF -- "$task" <<< "$features" \
        || error "$wt_dir is not a registered worktree of $base_name (see: git -C \"$base_dir\" worktree list)"

    # Only the base lock matters: the feature worktree is never touched, so
    # its conversation may stay open. A live base that is not this
    # conversation is a refusal, never a wait.
    local pid
    pid=$(_foreign_live_lock_pid "$base_name" "$base_dir/.cs/session.lock")
    [ -z "$pid" ] || error "Base session '$base_name' is open elsewhere (PID $pid); run /finish $task from that conversation"

    sha=$(git -C "$base_dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) \
        || error "Commit not found in $base_name: $sha"
    if [ -n "$from_remote" ]; then
        local base_branch
        base_branch=$(git -C "$base_dir" symbolic-ref -q --short HEAD 2>/dev/null) \
            || error "Base checkout is detached; check out the branch the PR targets, then re-run"
        git -C "$base_dir" merge-base --is-ancestor "$sha" "refs/remotes/origin/$base_branch" 2>/dev/null \
            || error "$sha is not reachable from origin/$base_branch; run: git -C \"$base_dir\" fetch origin, then check the PR's base branch"
    else
        git -C "$base_dir" merge-base --is-ancestor "$sha" "$branch" 2>/dev/null \
            || error "$sha is not reachable from $branch; capture the feature HEAD again"
    fi
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf 'already-integrated %s %s\n' "$task" "$sha"
        return 0
    fi

    if _tree_is_dirty "$base_dir"; then
        error "Base session has uncommitted changes; commit them in $base_dir first"
    fi
    local git_dir common
    git_dir=$(_git_path_abs "$base_dir" --git-dir) || error "Not a git checkout: $base_dir"
    common=$(_git_path_abs "$base_dir" --git-common-dir) || error "Not a git checkout: $base_dir"
    if git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
        || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        error "Base checkout has a merge or rebase in progress; finish or abort it, then re-run"
    fi

    # The mutex the autosave hook honours (hooks/autosave-commits.sh spells
    # the same path). An existing directory is a refusal, never stolen: a
    # stale one is the user's to inspect and remove.
    local lock="$common/cs/integrate.lock"
    mkdir -p "$common/cs"
    if ! mkdir "$lock" 2>/dev/null; then
        error "Another integrate or an in-flight autosave holds $lock; wait a few seconds and re-run. Remove that directory only if it persists with no cs running"
    fi
    _INTEGRATE_LOCK="$lock"
    _INTEGRATE_BASE_DIR="$base_dir"
    _INTEGRATE_TMP=""
    # EXIT alone is not enough: a TERM/INT'd bash skips the EXIT trap
    # (measured: exit 143, no cleanup), stranding the mutex and the temp.
    # Same shape as lib/75-launch.sh:112-113.
    trap '_integrate_cleanup' EXIT
    trap '_integrate_cleanup; exit 130' INT TERM

    _integrate_in_temp "$base_dir" "$wt_dir" "$task" "$sha" "$common" "$from_remote" "$@"
}
```

Then add the stub Task 3 replaces. It runs NOTHING — never the gate argv, which could be a build or formatter that mutates the live base — and refuses with a fixed message the feature-lock test pins:

```bash
# Temp-worktree merge, gates, fast-forward. Task 3 of the plan.
_integrate_in_temp() {  # base_dir wt_dir task sha common from_remote gate...
    error "integrate is not implemented yet (refusals passed)"
}
```

- [ ] **Step 7: Add the hidden dispatch arm**

Insert into `lib/99-main.sh` immediately before the `--merge)` arm (line 341):

```bash
            -integrate-feature) # hidden: driven by skills/finish/scripts/finish.sh, not typed by a user
                shift
                [ -n "${1:-}" ] || error "Usage: cs <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>"
                # Validate <base>@<feature> the same way --merge does, so a
                # task name with path separators is rejected before any
                # filesystem lookup.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                integrate_feature_worktree "$session_name" "$@"
                return 0
                ;;
```

Do NOT touch the unknown-command string at line 367.

- [ ] **Step 8: Build and run the suites**

Run: `./build.sh && bash tests/test_worktrees.sh 2>&1 | tail -8 && bash tests/test_completions.sh 2>&1 | tail -3`
Expected: all `test_integrate_*` pass, every pre-existing merge test still passes (the lock loop refactor is covered by `test_merge_refuses_live_session`, `test_merge_from_live_base_session_succeeds`, `test_merge_foreign_live_base_lock_still_refuses`, `test_merge_reused_live_pid_is_not_treated_as_own_lock`), and `test_completions.sh` stays green (the `# hidden` tag excludes the arm from the derived set).

- [ ] **Step 9: Commit**

```bash
git add lib/30-worktree.sh lib/99-main.sh bin/cs tests/test_worktrees.sh
git commit -m "feat(finish): hidden -integrate-feature entry with every refusal in place"
```

---

### Task 3: The hidden entry merges in a temp worktree, gates there, and fast-forwards base

**Files:**
- Modify: `lib/30-worktree.sh` (replace the `_integrate_in_temp` stub from Task 2)
- Test: `tests/test_worktrees.sh` (append after Task 2's `run_test` lines)

**Interfaces:**
- Consumes: Task 2's entry, `_git_path_abs`, `_warn_memory_index_changed`, `_integrate_cleanup` globals, `_terminate_jsonl` (`lib/40-state.sh:146`), `_read_local_state` (`lib/40-state.sh:40`).
- Produces: on success prints `integrated <task> <sha> -> <result-sha>` and appends a `feature-integrated` timeline event `{ts, event, task, sha, result}`. Base HEAD equals `<result-sha>`; the temp worktree is gone from `git worktree list`; the mutex is released. Task 5's `finish.sh` and the skill parse the summary line.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_worktrees.sh` after Task 2's `run_test` block:

```bash
test_integrate_lands_a_no_ff_merge_and_keeps_everything() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_eq "3" "$(git -C "$base_dir" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" \
        "base HEAD is a merge commit: its sha plus two parents (--no-ff)" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
    # rev-parse, not `branch --list`: git prefixes a branch checked out in a
    # linked worktree with `+`, so the listing never equals the bare name.
    git -C "$base_dir" rev-parse -q --verify refs/heads/cs/fix-auth >/dev/null 2>&1 \
        || { echo "  FAIL: the branch must remain"; return 1; }
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "no temp worktree left registered" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"feature-integrated"' "timeline records the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "\"sha\":\"$sha\"" "event carries the sha" || return 1
    # The merge commit names the feature: it is the only audit trail /finish leaves.
    assert_output_contains "$(git -C "$base_dir" log -1 --format=%s)" "Merge feature fix-auth" "merge subject names the feature" || return 1
}

# The load-bearing local happy path: after an integrate, today's retire verb
# takes its "already merged; cleaning up" branch and merges NOTHING. In
# tracked mode the integrate's own timeline event dirties the base (the
# timeline is tracked there), and the verb refuses dirt — so the test stages
# the general case: a tracked timeline, the refusal, the user's commit of the
# bookkeeping, then the ancestor path. Retirement semantics are unchanged.
test_integrate_then_merge_verb_takes_the_ancestor_path() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(git -C "$wt" rev-parse HEAD)
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || return 1
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "the only dirt after an integrate is the tracked timeline event" || return 1
    output=$("$CS_BIN" myproj --merge fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses the dirty base, as it always has" || return 1
    assert_output_contains "$output" "Base session has uncommitted changes" "the refusal is the verb's own" || return 1
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m "record the integrate")
    local head_after_integrate
    head_after_integrate=$(git -C "$base_dir" rev-parse HEAD)
    status=0
    output=$("$CS_BIN" myproj --merge fix-auth 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds after integrate: $output" || return 1
    assert_output_contains "$output" "already merged; cleaning up" "the verb skips the merge" || return 1
    assert_eq "$head_after_integrate" "$(git -C "$base_dir" rev-parse HEAD)" "retire makes no new commit" || return 1
    assert_not_exists "$wt" "retire removed the worktree" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retire deleted the branch" || return 1
}

test_integrate_red_gate_leaves_base_untouched() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    # The gate records where it ran: a red gate in the LIVE base would also
    # "leave HEAD unchanged", so location is part of what this proves.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; echo GATE-SAYS-NO; exit 3' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "a red gate refuses" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/where" 2>/dev/null)" "/.git/cs/finish/fix-auth." "the red gate ran in the temp" || return 1
    assert_output_contains "$output" "GATE-SAYS-NO" "the gate output is shown" || return 1
    assert_output_contains "$output" "Gate failed" "names the cause" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "base tree unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on failure" || return 1
}

test_integrate_gates_run_in_the_temp_not_the_live_trees() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # The gate records where it ran and proves the merged tree is there.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; test -f feature.txt' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "gate saw the merged tree: $output" || return 1
    local where
    where=$(cat "$TEST_TMPDIR/where")
    assert_output_contains "$where" "/.git/cs/finish/fix-auth." "gate ran in the temp worktree" || return 1
    assert_output_not_contains "$where" "$wt" "gate did not run in the feature worktree" || return 1
    [ "$where" != "$base_dir" ] || { echo "  FAIL: gate ran in the live base"; return 1; }
}

test_integrate_refuses_when_base_moved_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The gate itself moves base HEAD: deterministic, no timing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" commit -q --allow-empty -m moved 2>&1) || status=$?
    assert_eq "1" "$status" "a moved base refuses" || return 1
    assert_output_contains "$output" "moved or changed during the gates" "names the cause" || return 1
    assert_eq "moved" "$(git -C "$base_dir" log -1 --format=%s)" "base keeps only its own new commit" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates() {
    # --ff-only would happily land on a base that went BACKWARDS; the explicit
    # HEAD == B check is what refuses it.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "will be reset away")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" reset -q --hard HEAD~1 2>&1) || status=$?
    assert_eq "1" "$status" "a base reset during gates refuses" || return 1
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_dirtied_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo edit >> "$0/CLAUDE.md"' "$base_dir" 2>&1) || status=$?
    assert_eq "1" "$status" "dirt introduced during gates refuses" || return 1
    assert_output_contains "$output" "changed during the gates" "names the cause" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

test_integrate_terminated_mid_gate_leaves_no_lock_or_temp() {
    # TERM during the gate must still release the mutex and remove the temp:
    # a plain EXIT trap does not fire on TERM. The gate finds cs as its
    # grandparent (the gate subshell is cs's child) and terminates it.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'kill -TERM "$(ps -o ppid= -p $PPID | tr -d " ")"; sleep 2' 2>&1) || status=$?
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on TERM" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed on TERM" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

test_integrate_conflict_names_the_path_and_leaves_no_merge_head() {
    local base_dir wt sha output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a conflict refuses" || return 1
    assert_output_contains "$output" "shared.txt" "names the conflicting path" || return 1
    assert_file_not_exists "$base_dir/.git/MERGE_HEAD" "no MERGE_HEAD in the base" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed" || return 1
}

test_integrate_ignored_mode_fuses_nothing() {
    # Ignored mode: the feature's .cs/ never rides the merge and /finish fuses
    # no records (retire does). The base timeline must gain exactly one event.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# readme" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo '{"ts":"2026-01-01T00:00:00Z","event":"task","note":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    echo "work" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m work)
    local sha
    sha=$(git -C "$wt" rev-parse HEAD)
    "$CS_BIN" proj -integrate-feature t1 "$sha" -- true >/dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    assert_file_exists "$base_dir/result.txt" "code landed" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature records are not fused by integrate" || return 1
    assert_dir "$wt/.cs" "feature .cs untouched" || return 1
}

test_integrate_tracked_mode_warns_on_memory_index_change() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "- [x](x.md) — feature-side pointer" >> "$wt/.cs/memory/MEMORY.md"
    (cd "$wt" && git add .cs/memory/MEMORY.md && git commit -q -m "index")
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_output_contains "$output" "MEMORY.md changed on $sha" "merge=ours drop is announced" || return 1
}

test_integrate_tracked_mode_union_merges_shared_records() {
    # Both sides append to the tracked timeline; the verb's merge policy
    # (merge=union) must reach the temp worktree or this conflicts.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '{"ts":"2026-01-02T00:00:00Z","event":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add .cs/timeline.jsonl && git commit -q -m "feature event")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo '{"ts":"2026-01-03T00:00:00Z","event":"base-side"}' >> "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m "base event")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "union merge lands: $output" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature line kept" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "base-side" "base line kept" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .gitattributes)" "no tree is dirtied to get the policy" || return 1
}

run_test test_integrate_lands_a_no_ff_merge_and_keeps_everything
run_test test_integrate_tracked_mode_union_merges_shared_records
run_test test_integrate_then_merge_verb_takes_the_ancestor_path
run_test test_integrate_red_gate_leaves_base_untouched
run_test test_integrate_gates_run_in_the_temp_not_the_live_trees
run_test test_integrate_refuses_when_base_moved_during_gates
run_test test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates
run_test test_integrate_refuses_when_base_dirtied_during_gates
run_test test_integrate_terminated_mid_gate_leaves_no_lock_or_temp
run_test test_integrate_conflict_names_the_path_and_leaves_no_merge_head
run_test test_integrate_ignored_mode_fuses_nothing
run_test test_integrate_tracked_mode_warns_on_memory_index_change
```

Note on `test_integrate_tracked_mode_warns_on_memory_index_change`: `create_test_session_with_git` tracks `.cs/` (only `.cs/local/` is ignored), so the worktree is tracked mode and `.cs/memory/MEMORY.md` may not exist yet in the fixture; if `setup_auto_memory` does not create it, the test's `>>` creates it and the diff against the merge base still differs. Verify with the run in Step 2 rather than assuming.

- [ ] **Step 2: Run to see them fail**

Run: `bash tests/test_worktrees.sh 2>&1 | grep -B1 -A4 'FAIL' | head -80`
Expected: the eight new tests fail on `integrate is not implemented yet` (or, for the gate-location test, on the missing `where` file).

- [ ] **Step 3: Replace the `_integrate_in_temp` stub**

```bash
# The mutation half of integrate_feature_worktree, entered with the mutex
# held and the cleanup trap armed: merge base HEAD + <sha> in a temporary
# detached worktree under <common>/cs/finish/, run the gate argv there, then
# fast-forward the base onto the result. The fast-forward is the atomic
# "base has not moved" check; a red gate or a conflict leaves base exactly
# as it was. No hook of the project fires inside the temp (core.hooksPath
# points at an empty directory for the add and the merge): the gate argv is
# the project's gate, run explicitly.
_integrate_in_temp() {  # base_dir wt_dir task sha common from_remote gate...
    local base_dir="$1" wt_dir="$2" task="$3" sha="$4" common="$5" from_remote="$6"
    shift 6

    local B
    B=$(git -C "$base_dir" rev-parse HEAD)
    local tmp="$common/cs/finish/$task.$$"
    mkdir -p "$common/cs/finish"
    # /dev/null is not a directory on BSD, so hooks are silenced with a real
    # empty one.
    local no_hooks
    no_hooks=$(mktemp -d "${TMPDIR:-/tmp}/cs-nohooks.XXXXXX")
    if ! git -C "$base_dir" -c core.hooksPath="$no_hooks" worktree add --detach "$tmp" "$B" >/dev/null 2>&1; then
        rmdir "$no_hooks"
        error "git worktree add failed for $tmp"
    fi
    _INTEGRATE_TMP="$tmp"

    local mode
    mode=$(_read_local_state "$wt_dir/.cs/local/state" cs_mode)
    if [ "$mode" = "tracked" ]; then
        _setup_merge_attributes_clone_local "$base_dir" "$common"
        _warn_memory_index_changed "$base_dir" "$sha"
    fi

    # --no-ff locally: the merge commit names the feature and is the audit
    # trail /finish leaves, and it gives the retire verb's ancestor check
    # something to find. --from-remote: the landing commit already exists on
    # origin and names the PR, so a fast-forward is the right shape there.
    local sha7 merge_status=0
    sha7=$(printf '%s' "$sha" | cut -c1-7)
    if [ -n "$from_remote" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-edit "$sha" >/dev/null 2>&1 || merge_status=$?
    else
        git -C "$tmp" -c core.hooksPath="$no_hooks" merge --no-ff --no-edit \
            -m "Merge feature $task ($sha7)" "$sha" >/dev/null 2>&1 || merge_status=$?
    fi
    if [ "$merge_status" != 0 ]; then
        rmdir "$no_hooks"
        local conflicts
        conflicts=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null || true)
        error "Merge of $sha conflicts with $base_dir at $B; base untouched. Conflicting paths:
${conflicts:-(none reported; see git -C \"$tmp\" status)}
Resolve on the feature branch (git merge <base branch> in $wt_dir), then re-run /finish $task"
    fi
    # Submodules after the merge, so the gates see the MERGED gitlinks: a
    # feature that adds or bumps a submodule is otherwise gated against
    # absent or stale contents.
    if [ -f "$tmp/.gitmodules" ]; then
        git -C "$tmp" -c core.hooksPath="$no_hooks" submodule update --init --recursive -q >/dev/null 2>&1 \
            || { rmdir "$no_hooks"; error "submodule update failed in $tmp"; }
    fi
    rmdir "$no_hooks"

    local gate_log
    gate_log=$(mktemp "${TMPDIR:-/tmp}/cs-gate.XXXXXX")
    if ! (cd "$tmp" && "$@") > "$gate_log" 2>&1; then
        cat "$gate_log" >&2
        rm -f "$gate_log"
        error "Gate failed in $tmp (output above); base $base_dir untouched at $B"
    fi
    rm -f "$gate_log"

    # Re-verify the base immediately before landing. --ff-only alone is not
    # the "base unchanged" check: a base reset to an ancestor of B still
    # fast-forwards, and unrelated tracked dirt survives one. The residual
    # window between this check and the merge is the one race left; the
    # mutex keeps cs's own writer (the autosave hook) out of it.
    if [ "$(git -C "$base_dir" rev-parse HEAD)" != "$B" ]; then
        error "Base $base_dir moved during the gates (was $B, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish $task"
    fi
    if _tree_is_dirty "$base_dir" || git -C "$base_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        error "Base $base_dir changed during the gates (uncommitted changes or a merge in progress); commit or abort, then re-run /finish $task"
    fi
    # Fast-forward BEFORE removing the temp: until then the merge commit is
    # reachable only from the temp's detached HEAD.
    local R
    R=$(git -C "$tmp" rev-parse HEAD)
    if ! git -C "$base_dir" merge --ff-only "$R" >/dev/null 2>&1; then
        error "Base $base_dir moved or changed during the gates (was $B); re-run /finish $task"
    fi
    # Keep _INTEGRATE_TMP until the removal is verified, so the EXIT cleanup
    # still has the path if this removal fails; a leftover temp is reported,
    # never silently forgotten.
    if git -C "$base_dir" worktree remove --force "$tmp" >/dev/null 2>&1; then
        _INTEGRATE_TMP=""
    else
        warn "Temporary worktree $tmp could not be removed; run: git -C \"$base_dir\" worktree remove --force \"$tmp\""
    fi

    _terminate_jsonl "$base_dir/.cs/timeline.jsonl"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg event "feature-integrated" \
           --arg task "$task" \
           --arg sha "$sha" \
           --arg result "$R" \
        '{ts: $ts, event: $event, task: $task, sha: $sha, result: $result}' \
        >> "$base_dir/.cs/timeline.jsonl" 2>/dev/null || true
    printf 'integrated %s %s -> %s\n' "$task" "$sha" "$R"
}
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && bash tests/test_worktrees.sh 2>&1 | tail -8`
Expected: all pass. If `test_integrate_tracked_mode_warns_on_memory_index_change` fails because the fixture has no `MEMORY.md` at the merge base, seed one in the fixture before launching the worktree (`echo '# index' > "$base_dir/.cs/memory/MEMORY.md"` and commit) rather than weakening the assertion.

- [ ] **Step 5: Verify the mutation landed, not just that tests are green**

Run the probe from a file with bash:

```bash
d=$(mktemp -d "${TMPDIR:-/tmp}/fin.XXXXXX"); export CS_SESSIONS_ROOT="$d" HOME="$d/h" CLAUDE_CODE_BIN=echo CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
mkdir -p "$HOME"; bash tests/../bin/cs myproj </dev/null >/dev/null 2>&1; bin/cs myproj@f </dev/null >/dev/null 2>&1
echo x > "$d/myproj@f/x.txt"; git -C "$d/myproj@f" add x.txt; git -C "$d/myproj@f" commit -qm x
bin/cs myproj -integrate-feature f "$(git -C "$d/myproj@f" rev-parse HEAD)" -- true
git -C "$d/myproj" log --oneline --graph -3; git -C "$d/myproj" worktree list; ls "$d/myproj/.git/cs/"
```

Expected: a merge commit "Merge feature f (…)" on top, two worktrees listed (base and `myproj@f`), `.git/cs/` holds `finish/` (empty) and no `integrate.lock`.

- [ ] **Step 6: Commit**

```bash
git add lib/30-worktree.sh bin/cs tests/test_worktrees.sh
git commit -m "feat(finish): integrate merges in a temp worktree, gates there, fast-forwards base"
```

---

### Task 4: `--from-remote` lands a PR's merge commit

**Files:**
- Modify: `lib/30-worktree.sh` (no code change expected; this task proves the `--from-remote` branch of Task 2/3 against a real `origin`)
- Test: `tests/test_worktrees.sh` (append)

**Interfaces:**
- Consumes: the `--from-remote` flag from Task 2 (SHA must be reachable from `refs/remotes/origin/<checked-out base branch>`; merge is `--no-edit` without `--no-ff`).
- Produces: nothing new; establishes the bare-origin fixture `integrate_remote_fixture` that Task 5's script tests reuse.

- [ ] **Step 1: Write the failing tests**

```bash
# Base + feature + a bare origin that already carries the base branch. Prints
# the feature SHA. The caller lands the PR on origin however the scenario
# needs (merge commit, squash) and fetches.
integrate_remote_fixture() {  # base task
    local sha base_dir origin
    sha=$(integrate_fixture "$1" "$2")
    base_dir="$CS_SESSIONS_ROOT/$1"
    origin="$TEST_TMPDIR/origin.git"
    git init -q --bare "$origin"
    git -C "$base_dir" remote add origin "$origin"
    git -C "$base_dir" push -q origin HEAD >/dev/null 2>&1
    git -C "$base_dir" push -q origin "cs/$2" >/dev/null 2>&1
    printf '%s\n' "$sha"
}

# Land the feature on origin's base branch the way a merged PR does (a merge
# commit), through a throwaway clone. Prints the landing commit.
land_pr_on_origin() {  # base_dir task [--squash]
    local base_dir="$1" task="$2" how="${3:-}" clone branch
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    clone="$TEST_TMPDIR/pr-clone"
    rm -rf "$clone"
    git clone -q "$TEST_TMPDIR/origin.git" "$clone" 2>/dev/null
    git -C "$clone" checkout -q "$branch"
    if [ "$how" = "--squash" ]; then
        git -C "$clone" merge -q --squash "origin/cs/$task" >/dev/null 2>&1
        git -C "$clone" commit -q -m "feature ($task) (#7)"
    else
        git -C "$clone" merge -q --no-ff --no-edit -m "Merge pull request #7 from example-org/cs/$task" "origin/cs/$task"
    fi
    git -C "$clone" push -q origin "$branch" >/dev/null 2>&1
    git -C "$clone" rev-parse HEAD
}

test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_eq "$M" "$(git -C "$base_dir" rev-parse HEAD)" "base fast-forwards to the PR merge commit, no extra commit" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD \
        || { echo "  FAIL: F should be an ancestor after a merge-commit landing"; return 1; }
    assert_output_contains "$output" "integrated fix-auth $M -> $M" "summary line" || return 1
}

test_integrate_from_remote_after_a_local_integrate_still_lands() {
    # grok's inoperability case: base has a commit origin lacks, so a
    # whole-branch --ff-only would refuse forever. Merging the PR's landing
    # commit as an ordinary merge must still work.
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "local only")
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$M" HEAD \
        || { echo "  FAIL: the PR merge commit must be reachable from base HEAD"; return 1; }
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
}

test_integrate_from_remote_refuses_a_commit_origin_does_not_have() {
    local sha base_dir output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    git -C "$base_dir" fetch -q origin
    # F is on origin/cs/fix-auth but NOT on origin/<base branch>.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" --from-remote -- true 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$output" "not reachable from origin/" "names the remote branch" || return 1
}

test_integrate_from_remote_squash_leaves_feature_tip_unintegrated() {
    # The squash case the skill must report: M lands, F is not an ancestor.
    local sha base_dir M status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth --squash)
    git -C "$base_dir" fetch -q origin
    "$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "squash landing succeeds" || return 1
    assert_file_exists "$base_dir/feature.txt" "content landed" || return 1
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        echo "  FAIL: after a squash F must NOT be an ancestor (the report depends on it)"; return 1
    fi
}

run_test test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit
run_test test_integrate_from_remote_after_a_local_integrate_still_lands
run_test test_integrate_from_remote_refuses_a_commit_origin_does_not_have
run_test test_integrate_from_remote_squash_leaves_feature_tip_unintegrated
```

- [ ] **Step 2: Run**

Run: `bash tests/test_worktrees.sh 2>&1 | tail -8`
Expected: all four pass with Task 3's code. If `land_pr_on_origin`'s clone refuses because the bare origin's HEAD points at an absent `master`, set it: `git -C "$TEST_TMPDIR/origin.git" symbolic-ref HEAD "refs/heads/$branch"` right after the first push in `integrate_remote_fixture`. If a test fails inside the entry (not the fixture), that is a real defect in Task 3's `--from-remote` branch: fix it there, watch the test go green, and say so in the commit message.

- [ ] **Step 3: Commit**

```bash
git add tests/test_worktrees.sh lib/30-worktree.sh bin/cs
git commit -m "test(finish): --from-remote lands merge-commit, mixed and squash PRs against a bare origin"
```

---

### Task 5: `finish.sh` — context, capture, PR state, report

**Files:**
- Create: `skills/finish/scripts/finish.sh` (executable)
- Test: `tests/test_finish_script.sh` (new)

**Interfaces:**
- Consumes: `.cs/local/state` keys `cs_base`, `task_branch` (written by `create_worktree_session`, `lib/30-worktree.sh:315-320`); env `CLAUDE_SESSION_DIR`, `CLAUDE_SESSION_NAME`, `CS_SESSIONS_ROOT`; `gh`, `jq`, `perl`, `git`.
- Produces: `finish.sh prepare [feature]` and `finish.sh report <base> <feature> <captured-sha>`, both printing `key: value` lines (one per line, keys below). Task 6's SKILL.md reads these keys by name.

Keys from `prepare`: `role` (`feature`|`base`), `base`, `task`, `handoff` (feature role only), `worktree`, `branch`, `sha`, `dirt_count`, `dirt` (repeated, one porcelain line each), `base_branch`, `pr_state` (`none`|`OPEN`|`MERGED`|`CLOSED`|`unknown`|`skipped`), `pr_number`, `pr_url`, `pr_merge_commit`, `pr_base_ref`, `pr_reason`, `error`.
Keys from `report`: `landed` (`yes`|`no`), `base_head`, `not_integrated` (commit count on `cs/<task>` after the captured SHA), `dirt_count`, `dirt`, the `pr_*` keys, `retire` (one line of advice).

- [ ] **Step 1: Write the failing tests**

Create `tests/test_finish_script.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for skills/finish/scripts/finish.sh, the read-only half of /finish
# ABOUTME: Context detection, capture, GitHub PR state via a stubbed gh, and the report

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

FINISH="$SCRIPT_DIR/../skills/finish/scripts/finish.sh"

cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Base + feature with one feature commit and a GitHub-shaped origin URL (never
# contacted: gh is stubbed). Prints the feature SHA.
finish_fixture() {  # base task
    local base_dir wt
    base_dir=$(create_test_session_with_git "$1")
    git -C "$base_dir" remote add origin "git@github.com:example-org/example-repo.git"
    cs_launch "$1@$2"
    wt="$CS_SESSIONS_ROOT/$1@$2"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    git -C "$wt" rev-parse HEAD
}

# A gh on PATH that prints $1 as its JSON (or exits $2 with $3 on stderr).
stub_gh() {  # json [exit-code stderr-text]
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMPDIR/gh.argv"
if [ "${2:-0}" != 0 ]; then echo "${3:-gh failed}" >&2; exit ${2:-0}; fi
cat << 'JSON'
$1
JSON
STUB
    chmod +x "$TEST_TMPDIR/bin/gh"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

key() {  # output key
    printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

test_prepare_in_feature_session_hands_off() {
    finish_fixture myproj fix-auth > /dev/null
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj@fix-auth" CLAUDE_SESSION_NAME="myproj@fix-auth" \
        bash "$FINISH" prepare 2>&1)
    assert_eq "feature" "$(key "$out" role)" "feature role detected" || return 1
    assert_eq "myproj" "$(key "$out" base)" "base named" || return 1
    assert_eq "fix-auth" "$(key "$out" task)" "task named" || return 1
    assert_output_contains "$out" "handoff: run /finish fix-auth in session myproj" "hand-off line" || return 1
    assert_output_not_contains "$out" "sha:" "a feature session captures nothing" || return 1
}

test_prepare_in_base_captures_sha_branch_and_dirt() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    echo "uncommitted" > "$CS_SESSIONS_ROOT/myproj@fix-auth/scratch.txt"
    # Tracked-mode session records are the user's work too: never filtered.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/plans"
    echo "# plan" > "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/plans/next.md"
    stub_gh '[]'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "base" "$(key "$out" role)" "base role" || return 1
    assert_eq "yes" "$(key "$out" cs_session)" "a cs base is recognised" || return 1
    assert_eq "$sha" "$(key "$out" sha)" "captured sha is the feature HEAD" || return 1
    assert_eq "cs/fix-auth" "$(key "$out" branch)" "feature is on its branch" || return 1
    assert_eq "2" "$(key "$out" dirt_count)" "both dirty paths counted, .cs/ included" || return 1
    assert_output_contains "$out" "dirt: ?? scratch.txt" "dirt is listed as porcelain" || return 1
    assert_output_contains "$out" "dirt: ?? .cs/plans/" "session records under .cs/ are reported" || return 1
    assert_eq "none" "$(key "$out" pr_state)" "no PR" || return 1
}

test_prepare_in_a_plain_checkout_says_so() {
    local dir="$TEST_TMPDIR/plain"
    mkdir -p "$dir"
    (cd "$dir" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b topic)
    local out
    out=$(CLAUDE_SESSION_DIR="$dir" CLAUDE_SESSION_NAME="plain" bash "$FINISH" prepare 2>&1)
    assert_eq "no" "$(key "$out" cs_session)" "an ordinary checkout is not a cs session" || return 1
    assert_eq "topic" "$(key "$out" base_branch)" "branch reported" || return 1
}

test_prepare_calls_two_open_prs_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":3,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/3","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":5,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/5","mergeCommit":null,"mergedAt":null,"baseRefName":"release","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "two open PRs are ambiguous" || return 1
    assert_output_contains "$out" "pr_reason: ambiguous — #3 OPEN, #5 OPEN" "both are named" || return 1
}

test_prepare_calls_a_reused_branch_unknown() {
    # An old MERGED PR beside a newer OPEN one on the same head: the branch
    # was reused after a landing; neither state describes this capture.
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-01T09:00:00Z","baseRefName":"main","headRefOid":"old","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":9,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/9","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"new","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "merged beside open is ambiguous" || return 1
    assert_output_contains "$out" "#7 MERGED, #9 OPEN" "both are named" || return 1
}

test_prepare_refuses_a_worktree_off_its_branch() {
    finish_fixture myproj fix-auth > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" checkout -q --detach
    local out status=0
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$out" "error: worktree is on detached, not cs/fix-auth" "names the state" || return 1
}

test_prepare_reports_a_merged_pr_and_filters_forks() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":9,"state":"MERGED","url":"https://github.com/other-org/example-repo/pull/9","mergeCommit":{"oid":"ffff"},"mergedAt":"2026-09-13T09:00:00Z","baseRefName":"main","headRefOid":"f0f0","headRepositoryOwner":{"login":"other-org"},"isCrossRepository":true},
      {"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":8,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/8","mergeCommit":{"oid":"def456"},"mergedAt":"2026-09-12T10:00:00Z","baseRefName":"main","headRefOid":"b2b2","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "MERGED" "$(key "$out" pr_state)" "merged state" || return 1
    assert_eq "8" "$(key "$out" pr_number)" "newest mergedAt wins among this repo's PRs; the fork's #9 is ignored" || return 1
    assert_eq "def456" "$(key "$out" pr_merge_commit)" "merge commit oid" || return 1
    assert_eq "main" "$(key "$out" pr_base_ref)" "base ref" || return 1
    assert_eq "b2b2" "$(key "$out" pr_head_oid)" "head oid passed through for the skill to compare with the capture" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "pr list --repo example-org/example-repo --head cs/fix-auth --state all --limit 100" \
        "gh is asked for every state, scoped to origin's repo" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "headRefOid,headRepositoryOwner,isCrossRepository" "the spec's fields are requested" || return 1
}

test_prepare_reports_an_open_pr() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":3,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/3","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "OPEN" "$(key "$out" pr_state)" "open state" || return 1
    assert_eq "3" "$(key "$out" pr_number)" "number" || return 1
}

test_prepare_reports_closed_unmerged_as_closed() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":4,"state":"CLOSED","url":"https://github.com/example-org/example-repo/pull/4","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "CLOSED" "$(key "$out" pr_state)" "closed state" || return 1
    assert_eq "4" "$(key "$out" pr_number)" "number" || return 1
}

test_prepare_never_reads_a_gh_failure_as_no_pr() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '' 4 'gh: To get started with GitHub CLI, please run: gh auth login'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a gh failure is unknown, never none" || return 1
    assert_output_contains "$out" "pr_reason: gh pr list failed: gh: To get started" "reason carries gh's message" || return 1
}

test_prepare_treats_a_vanished_head_repo_as_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":5,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/5","mergeCommit":{"oid":"aaa"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":null,"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a PR whose head repository is gone cannot be attributed" || return 1
    assert_output_contains "$out" "pr_reason: " "reason given" || return 1
}

test_prepare_skips_the_lookup_for_a_non_github_origin() {
    finish_fixture myproj fix-auth > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj" remote set-url origin "https://git.example.com/example-org/example-repo.git"
    stub_gh '[]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "skipped" "$(key "$out" pr_state)" "non-GitHub origin skips" || return 1
    assert_output_contains "$out" "pr_reason: origin is not a GitHub remote" "says why" || return 1
    assert_file_not_exists "$TEST_TMPDIR/gh.argv" "gh was never invoked" || return 1
}

test_report_after_a_local_integrate_gives_the_retire_line() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true > /dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    # One more feature commit after capture: it must be counted as not integrated.
    (cd "$CS_SESSIONS_ROOT/myproj@fix-auth" && git commit -q --allow-empty -m "after capture")
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "yes" "$(key "$out" landed)" "captured sha is an ancestor of base" || return 1
    assert_eq "$(git -C "$CS_SESSIONS_ROOT/myproj" rev-parse HEAD)" "$(key "$out" base_head)" "base head reported" || return 1
    assert_eq "1" "$(key "$out" not_integrated)" "one commit after capture" || return 1
    assert_output_contains "$out" "retire: close the feature session, then: cs myproj --merge fix-auth" "retire line" || return 1
}

test_report_after_a_squash_landing_gives_the_squash_notice() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    # Squash-shaped landing: the content arrives as an unrelated commit, F is not an ancestor.
    (cd "$CS_SESSIONS_ROOT/myproj" && git merge -q --squash cs/fix-auth && git commit -q -m "feature (#7)")
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "no" "$(key "$out" landed)" "F is not an ancestor after a squash" || return 1
    assert_output_contains "$out" "retire: do NOT run cs myproj --merge fix-auth" "squash notice leads the retire line" || return 1
    assert_output_contains "$out" "will try to merge the branch again" "names what the verb would do" || return 1
}

run_test test_prepare_in_feature_session_hands_off
run_test test_prepare_in_base_captures_sha_branch_and_dirt
run_test test_prepare_in_a_plain_checkout_says_so
run_test test_prepare_refuses_a_worktree_off_its_branch
run_test test_prepare_reports_a_merged_pr_and_filters_forks
run_test test_prepare_reports_an_open_pr
run_test test_prepare_calls_two_open_prs_unknown
run_test test_prepare_calls_a_reused_branch_unknown
run_test test_prepare_reports_closed_unmerged_as_closed
run_test test_prepare_never_reads_a_gh_failure_as_no_pr
run_test test_prepare_treats_a_vanished_head_repo_as_unknown
run_test test_prepare_skips_the_lookup_for_a_non_github_origin
run_test test_report_after_a_local_integrate_gives_the_retire_line
run_test test_report_after_a_squash_landing_gives_the_squash_notice

report_results
```

- [ ] **Step 2: Run to see them fail**

Run: `chmod +x tests/test_finish_script.sh; bash tests/test_finish_script.sh 2>&1 | tail -15`
Expected: every test fails (`finish.sh: No such file or directory`).

- [ ] **Step 3: Write `skills/finish/scripts/finish.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: Deterministic front half of the /finish skill: session context, feature capture,
# ABOUTME: GitHub PR state, and the closing report. Mutation goes through cs, never here.
set -euo pipefail

usage() {
    echo "usage: finish.sh prepare [feature] | finish.sh report <base> <feature> <captured-sha>" >&2
    exit 2
}

session_dir="${CLAUDE_SESSION_DIR:-$PWD}"
# Never `dirname "$session_dir"`: an adopted session's CLAUDE_SESSION_DIR is
# the resolved project path, whose parent is not the sessions root. Same
# default write-as-me's build-corpus.sh uses.
sessions_root="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
session_name="${CLAUDE_SESSION_NAME:-$(basename "$session_dir")}"

for tool in git jq perl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

# One key from .cs/local/state; the format lib/40-state.sh writes.
state_get() {  # dir key
    [ -f "$1/.cs/local/state" ] || return 0
    awk -v key="$2" 'index($0, key ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' \
        "$1/.cs/local/state" 2>/dev/null || true
}

# owner/repo when origin is GitHub (https, ssh, or scp-like); empty otherwise.
github_repo() {  # dir
    local url
    url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
    case "$url" in
        https://github.com/*|http://github.com/*|ssh://git@github.com/*|git@github.com:*) ;;
        *) return 0 ;;
    esac
    url="${url#*github.com}"
    url="${url#[:/]}"
    url="${url%.git}"
    url="${url%/}"
    printf '%s\n' "$url"
}

# gh with a 10 s ceiling. perl's alarm exists on every platform cs supports;
# GNU timeout does not.
gh_timed() {
    perl -e 'alarm 10; exec @ARGV or exit 127' -- gh "$@"
}

# PR state for a head branch, as pr_* lines. Three shapes only: none, a state
# with its fields, or unknown with a reason. A gh failure is never "none".
pr_lookup() {  # base_dir branch
    local repo owner json n err
    repo=$(github_repo "$1")
    if [ -z "$repo" ]; then
        echo "pr_state: skipped"
        echo "pr_reason: origin is not a GitHub remote"
        return 0
    fi
    owner="${repo%%/*}"
    if ! command -v gh >/dev/null 2>&1; then
        echo "pr_state: unknown"
        echo "pr_reason: gh is not installed"
        return 0
    fi
    err=$(mktemp "${TMPDIR:-/tmp}/finish-gh.XXXXXX")
    if ! json=$(gh_timed pr list --repo "$repo" --head "$2" --state all --limit 100 \
            --json number,state,url,mergeCommit,mergedAt,baseRefName,headRefOid,headRepositoryOwner,isCrossRepository 2>"$err"); then
        echo "pr_state: unknown"
        echo "pr_reason: gh pr list failed: $(head -c 200 "$err" | tr '\n' ' ')"
        rm -f "$err"
        return 0
    fi
    rm -f "$err"
    if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "pr_state: unknown"
        echo "pr_reason: gh output was not a JSON array"
        return 0
    fi
    # A PR whose head repository is gone cannot be told from a fork's; refuse
    # to guess.
    if [ "$(printf '%s' "$json" | jq '[.[] | select(.headRepositoryOwner == null)] | length')" != 0 ]; then
        echo "pr_state: unknown"
        echo "pr_reason: a PR on $2 has no head repository (deleted fork?); inspect it on GitHub"
        return 0
    fi
    # A fork's same-named branch is not this PR.
    json=$(printf '%s' "$json" | jq -c --arg owner "$owner" \
        '[.[] | select(.headRepositoryOwner.login == $owner and .isCrossRepository == false)]')
    n=$(printf '%s' "$json" | jq 'length')
    if [ "$n" = 0 ]; then
        echo "pr_state: none"
        return 0
    fi
    # Selection policy. One MERGED (newest mergedAt when several, a re-opened
    # and re-merged branch) or one OPEN is a state. Two OPEN PRs, or a MERGED
    # PR beside an OPEN one (branch reused after a landing), cannot be told
    # apart from here: unknown, with the numbers, never a guess.
    local n_open n_merged
    n_open=$(printf '%s' "$json" | jq '[.[] | select(.state == "OPEN")] | length')
    n_merged=$(printf '%s' "$json" | jq '[.[] | select(.state == "MERGED")] | length')
    if [ "$n_open" -gt 1 ] || { [ "$n_open" -gt 0 ] && [ "$n_merged" -gt 0 ]; }; then
        echo "pr_state: unknown"
        echo "pr_reason: ambiguous — $(printf '%s' "$json" | jq -r '[.[] | "#\(.number) \(.state)"] | join(", ")') all have head $2; pick one on GitHub"
        return 0
    fi
    local merged open
    merged=$(printf '%s' "$json" | jq -c '[.[] | select(.state == "MERGED")] | sort_by(.mergedAt) | last // empty')
    if [ -n "$merged" ]; then
        echo "pr_state: MERGED"
        printf '%s' "$merged" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_merge_commit: \(.mergeCommit.oid // "")\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        return 0
    fi
    open=$(printf '%s' "$json" | jq -c '[.[] | select(.state == "OPEN")] | first // empty')
    if [ -n "$open" ]; then
        echo "pr_state: OPEN"
        printf '%s' "$open" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        return 0
    fi
    echo "pr_state: CLOSED"
    printf '%s' "$json" | jq -r 'first | "pr_number: \(.number)\npr_url: \(.url)"'
}

# Everything uncommitted in the worktree, as porcelain lines, unfiltered. The
# retire verb's untracked filter (lib/30-worktree.sh _worktree_untracked_at_risk)
# is a REMOVAL-risk filter that drops records because retirement fuses them;
# integrate fuses nothing, so a new tracked-mode plan or memory file under
# .cs/ is exactly the dirt the user must hear about.
dirt_lines() {  # dir
    local dirt
    dirt=$(git -C "$1" status --porcelain 2>/dev/null || true)
    echo "dirt_count: $(printf '%s' "$dirt" | grep -c . || true)"
    [ -z "$dirt" ] || printf '%s\n' "$dirt" | sed 's/^/dirt: /'
}

cmd_prepare() {  # [feature]
    local feature="${1:-}" cs_base task_branch
    cs_base=$(state_get "$session_dir" cs_base)
    task_branch=$(state_get "$session_dir" task_branch)
    if [ -n "$task_branch" ] && [ -n "$cs_base" ]; then
        # A feature session: integrate mutates the base and runs only from the
        # base's own conversation. Hand off; nothing here changes.
        echo "role: feature"
        echo "base: $cs_base"
        echo "task: ${task_branch#cs/}"
        echo "handoff: run /finish ${task_branch#cs/} in session $cs_base"
        return 0
    fi
    echo "role: base"
    echo "base: $session_name"
    # A cs session has a .cs/ directory; an ordinary checkout does not. The
    # skill's plain-branch path (checkout + merge + branch -d) is only for the
    # latter — a cs base on a non-default branch must never enter it.
    if [ -d "$session_dir/.cs" ]; then echo "cs_session: yes"; else echo "cs_session: no"; fi
    echo "base_branch: $(git -C "$session_dir" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)"
    if [ -z "$feature" ]; then
        echo "task: "
        return 0
    fi
    local task="$feature" wt="$sessions_root/$session_name@$feature"
    echo "task: $task"
    if [ ! -d "$wt" ]; then
        echo "error: no worktree at $wt"
        exit 1
    fi
    echo "worktree: $wt"
    local head_branch
    head_branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)
    echo "branch: $head_branch"
    if [ "$head_branch" != "cs/$task" ]; then
        echo "error: worktree is on $head_branch, not cs/$task"
        exit 1
    fi
    echo "sha: $(git -C "$wt" rev-parse HEAD)"
    dirt_lines "$wt"
    pr_lookup "$session_dir" "cs/$task"
}

cmd_report() {  # base task sha
    local base="$1" task="$2" sha="$3" wt="$sessions_root/$1@$2"
    [ -d "$wt" ] || { echo "error: no worktree at $wt"; exit 1; }
    local landed="no"
    if git -C "$session_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        landed="yes"
    fi
    echo "landed: $landed"
    echo "base_head: $(git -C "$session_dir" rev-parse HEAD)"
    echo "not_integrated: $(git -C "$wt" rev-list --count "$sha..HEAD" 2>/dev/null || echo 0)"
    dirt_lines "$wt"
    pr_lookup "$session_dir" "cs/$task"
    if [ "$landed" = "yes" ]; then
        # Tracked-.cs mode: the integrate's timeline event dirties the base,
        # and the retire verb refuses dirt. Say so rather than let the verb's
        # refusal be the first the user hears of it.
        if [ -n "$(git -C "$session_dir" status --porcelain -- .cs 2>/dev/null)" ]; then
            echo "retire: commit the session bookkeeping in $base (git status -- .cs), close the feature session, then: cs $base --merge $task"
        else
            echo "retire: close the feature session, then: cs $base --merge $task"
        fi
    else
        echo "retire: do NOT run cs $base --merge $task — cs/$task is not an ancestor of base (squash or rebase landing) and the verb will try to merge the branch again; continue on a new task and leave this worktree until the preservation-first retire spec ships"
    fi
}

case "${1:-}" in
    prepare) shift; cmd_prepare "$@" ;;
    report) [ $# -eq 4 ] || usage; cmd_report "$2" "$3" "$4" ;;
    *) usage ;;
esac
```

Then: `chmod +x skills/finish/scripts/finish.sh`.

- [ ] **Step 4: Run**

Run: `bash tests/test_finish_script.sh > "$TMPDIR/t5.out" 2>&1; echo "rc=$?"; grep -E 'Results:|FAIL' "$TMPDIR/t5.out"`
Expected: `rc=0`, `Results: 15/15 passed`. The report tests need Task 3's built `bin/cs`.

- [ ] **Step 5: Portability check under bash 3.2**

Run: `/bin/bash -n skills/finish/scripts/finish.sh && /bin/bash tests/test_finish_script.sh 2>&1 | tail -3`
Expected: parses and passes under the stock shell.

- [ ] **Step 6: Commit**

```bash
git add skills/finish/scripts/finish.sh tests/test_finish_script.sh
git commit -m "feat(finish): finish.sh — context, capture, PR state, report"
```

---

### Task 6: `/finish` replaces `/merge` — skill, manifests, kick, hook wording

**Files:**
- Create: `skills/finish/SKILL.md`
- Delete: `skills/merge/SKILL.md` (and the directory)
- Modify: `lib/00-header.sh:82-104`, `install.sh:143-166` (three arrays each)
- Modify: `lib/75-launch.sh:274`
- Modify: `hooks/session-start.sh:670-673`, `hooks/subagent-context.sh:59`
- Modify: `lib/10-help.sh` (the `-finish` line), `completions/_cs:239`
- Rename: `tests/test_merge_skill.sh` → `tests/test_finish_skill.sh` (rewritten)
- Modify: `tests/test_retired_skills.sh` (pin `merge`), `tests/test_hooks.sh` `test_subagent_context_announces_worktree_task`
- Test: as above

**Interfaces:**
- Consumes: `finish.sh prepare`/`report` keys (Task 5), the entry's summary lines (Tasks 2–3).
- Produces: the `/finish` slash command; `cs <base> -finish <feature>` arms `/finish <feature>`.

- [ ] **Step 1: Write the failing skill tests**

`git mv tests/test_merge_skill.sh tests/test_finish_skill.sh`, then replace its content:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests that the finish skill ships, is registered, and teaches integrate-and-report
# ABOUTME: Contract pins for skills/finish/SKILL.md, finish.sh shipping, and the CS_SKILLS manifests

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/finish/SKILL.md"
REPO="$SCRIPT_DIR/.."

# Same extractor test_install.sh uses: the array body, comments stripped.
skill_array() {  # file name
    awk -v name="$2" '
        $0 ~ "^" name "=\\(" { f = 1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$1"
}

test_finish_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/finish/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "name: finish" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "description:" "frontmatter has a description" || return 1
}

test_finish_skill_is_user_invoked_only() {
    assert_file_contains "$SKILL" "disable-model-invocation: true" \
        "integrating must never start on the model's own initiative" || return 1
}

test_finish_registered_and_merge_retired_in_both_manifests() {
    local f
    for f in "$REPO/lib/00-header.sh" "$REPO/install.sh" "$CS_BIN"; do
        skill_array "$f" CS_SKILLS | grep -qx finish \
            || { echo "  FAIL: finish missing from CS_SKILLS in $f"; return 1; }
        skill_array "$f" CS_SKILLS | grep -qx merge \
            && { echo "  FAIL: merge still listed in CS_SKILLS in $f"; return 1; }
        skill_array "$f" RETIRED_SKILLS | grep -qx merge \
            || { echo "  FAIL: merge missing from RETIRED_SKILLS in $f"; return 1; }
        skill_array "$f" CS_SKILL_FILES | grep -qx 'finish/scripts/finish.sh' \
            || { echo "  FAIL: finish/scripts/finish.sh missing from CS_SKILL_FILES in $f"; return 1; }
    done
    [ ! -d "$REPO/skills/merge" ] || { echo "  FAIL: skills/merge must be removed"; return 1; }
    [ -x "$REPO/skills/finish/scripts/finish.sh" ] || { echo "  FAIL: finish.sh must ship executable"; return 1; }
}

test_finish_skill_teaches_the_ritual() {
    assert_file_contains "$SKILL" "scripts/finish.sh prepare" "runs the capture script" || return 1
    assert_file_contains "$SKILL" "scripts/finish.sh report" "runs the report script" || return 1
    assert_file_contains "$SKILL" "cs <base> -integrate-feature <task> <sha> -- <gate command" "mutates only through the hidden entry" || return 1
    assert_file_contains "$SKILL" "from-remote" "teaches the PR path" || return 1
    assert_file_contains "$SKILL" "temporary detached worktree" "gates run in the temp" || return 1
    assert_file_contains "$SKILL" "pr_state" "reads the PR state keys" || return 1
    assert_file_contains "$SKILL" "unknown" "the unknown PR state exists" || return 1
    assert_file_contains "$SKILL" "AskUserQuestion" "OPEN/unknown need explicit confirmation" || return 1
    assert_file_contains "$SKILL" "do NOT run" "squash notice" || return 1
    assert_file_contains "$SKILL" "cs <base> --merge <task>" "names the retire verb" || return 1
    assert_file_contains "$SKILL" "removes nothing" "retention promise stated" || return 1
    assert_file_contains "$SKILL" "handoff:" "feature-session hand-off documented" || return 1
    assert_file_contains "$SKILL" "NOT part of this integrate" "dirt is reported" || return 1
}

test_finish_skill_keeps_the_plain_branch_context() {
    assert_file_contains "$SKILL" "git merge --no-ff" "ordinary feature branches still merge --no-ff" || return 1
    assert_file_contains "$SKILL" "merged result" "gates run again after a plain-branch merge" || return 1
}

test_finish_skill_never_list() {
    assert_file_contains "$SKILL" "Never push" "publishing rail stated" || return 1
    assert_file_contains "$SKILL" "branch -D" "force delete forbidden" || return 1
    assert_file_contains "$SKILL" "Never treat a gh failure as no PR" "gh failure rail" || return 1
    assert_file_contains "$SKILL" "never runs gates in a live tree" "live-tree rail" || return 1
    assert_file_contains "$SKILL" "cs_session: yes" "a cs base never enters the plain-branch path" || return 1
    assert_file_contains "$SKILL" "Never enter" "plain-branch exclusion stated" || return 1
    assert_file_contains "$SKILL" "Never delete" "deletion rail" || return 1
}

test_finish_kick_arms_the_new_skill() {
    assert_file_contains "$REPO/lib/75-launch.sh" 'merge_kick="/finish \$merge_feature"' "-finish arms /finish" || return 1
    assert_file_not_contains "$REPO/lib/75-launch.sh" '"/merge ' "nothing arms /merge any more" || return 1
}

run_test test_finish_skill_exists_with_frontmatter
run_test test_finish_skill_is_user_invoked_only
run_test test_finish_registered_and_merge_retired_in_both_manifests
run_test test_finish_skill_teaches_the_ritual
run_test test_finish_skill_keeps_the_plain_branch_context
run_test test_finish_skill_never_list
run_test test_finish_kick_arms_the_new_skill

report_results
```

Add to `tests/test_retired_skills.sh`, next to `test_voice_is_listed_as_retired` (mirror its body exactly, with `merge` in place of `voice`):

```bash
# /merge was replaced by /finish: a merge skill directory left from an older
# install keeps answering /merge with the old ritual, which removes worktrees.
test_merge_is_listed_as_retired() {
    local f
    for f in "$INSTALL_SH" "$CS_BIN"; do
        if ! rs_extract_array "$f" RETIRED_SKILLS | grep -qx "merge"; then
            echo "  FAIL: merge missing from RETIRED_SKILLS in $f"
            return 1
        fi
    done
}
run_test test_merge_is_listed_as_retired
```

(Check the file's existing `run_test` placement and variable names — `INSTALL_SH`, `CS_BIN`, `rs_extract_array` — and match them.)

Change the pin in `tests/test_hooks.sh` `test_subagent_context_announces_worktree_task`:

```bash
    assert_output_contains "$output" "/finish" \
        "subagents must know integration goes through /finish in the base" || return 1
    assert_output_contains "$output" "cs --merge" \
        "subagents must know retirement goes through cs --merge" || return 1
```

- [ ] **Step 2: Run to see them fail**

Run: `bash tests/test_finish_skill.sh 2>&1 | tail -12; bash tests/test_retired_skills.sh 2>&1 | tail -4; bash tests/test_hooks.sh 2>&1 | grep -A3 subagent_context_announces`
Expected: skill tests fail on the missing file; retired test fails on the missing entry; the hook pin fails on `/finish`.

- [ ] **Step 3: Write `skills/finish/SKILL.md`**

```markdown
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
   not 0, list every `dirt:` path under the heading "NOT part of this
   integrate" before doing anything else. Never stash, commit or copy them.
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
```

- [ ] **Step 4: Manifests, kick, hooks, help, completion**

`lib/00-header.sh` and `install.sh`, identically:

```bash
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    finish
    write-as-me
)
…
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
    merge   # replaced by finish: integrate and report, never remove
)
…
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
    finish/scripts/finish.sh
)
```

`lib/75-launch.sh:274`: `[ -n "$merge_feature" ] && merge_kick="/finish $merge_feature"`. Also the comment above it (lines 267-270, "Arming the ritual…") still reads true; leave it.

Four existing pins in `tests/test_worktrees.sh` name the old kick and must follow it, or three fail and the fourth goes vacuous: at lines 974, 990 and 1035 change `"/merge fix-auth"` to `"/finish fix-auth"` (positive assertions), and at line 1064 change the negative `"/merge fix-auth"` to `"/finish fix-auth"` so it still detects the kick wrongly overriding the rotation choice. Read each line before editing; the line numbers are as of `14d1a48` and Tasks 2–4 appended below them, so they should be unchanged.

`git rm -r skills/merge`.

`hooks/session-start.sh:670-673` becomes:

```
To integrate this feature while keeping this worktree, ask the user to run /finish $TASK_NAME in session $CS_BASE: it merges a captured commit into the base after the gates pass there and removes nothing, so this session stays open.
When the feature is retired, ask the user to run: cs $CS_BASE --merge $TASK_NAME
That command merges anything not yet integrated, fuses the session records (timeline, narrative), and removes this worktree. It refuses while either session is open, so it runs from a free terminal after this session closes.
Do NOT merge $TASK_BRANCH into the base branch manually and do not delete the branch — that bypasses the record fuse and the cleanup. To abandon the feature instead, ask the user to run: cs -rm $CLAUDE_SESSION_NAME — never run this yourself; it deletes this worktree and its session records.
```

Check `tests/test_hooks.sh` for pins on the old sentence first: `grep -n 'ask the user to run: cs' tests/test_hooks.sh` — keep every pinned substring that still describes the truth (`ask the user to run: cs -rm`, `never run this yourself`).

`hooks/subagent-context.sh:59` becomes:

```
- This session is a feature worktree on branch $TASK_BRANCH; integration happens only via /finish in the base session (run by the user, keeps this worktree) and retirement only via cs --merge after this session closes — never merge or delete that branch yourself"
```

`lib/10-help.sh`, the `-finish` line: `  <base> -finish <feature>  Open <base> and run /finish for <feature> (integrate, keep the worktree)`.
`completions/_cs:239`: `'-finish:Open the base and run /finish for a feature (integrate, keep the worktree)'`.

- [ ] **Step 5: Build, run every touched suite**

Run (capture each suite's exit status; a `| tail` would report tail's):

```bash
./build.sh
for s in test_finish_skill test_retired_skills test_install test_hooks test_help test_completions test_write_as_me_skill test_worktrees; do
    bash "tests/$s.sh" > "$TMPDIR/$s.out" 2>&1; echo "$s rc=$?"; grep -E '^Results:' "$TMPDIR/$s.out"
done
```

Expected: every `rc=0` and every `Results:` line `0 failed`. `test_install.sh` covers manifest sync with the built binary and `finish/scripts/finish.sh` being executable in the repo; `test_worktrees.sh` covers the four kick pins.

- [ ] **Step 6: Commit**

```bash
git add -A skills/finish skills/merge lib/00-header.sh install.sh lib/75-launch.sh hooks/session-start.sh hooks/subagent-context.sh lib/10-help.sh completions/_cs bin/cs tests/test_finish_skill.sh tests/test_retired_skills.sh tests/test_hooks.sh tests/test_worktrees.sh
git status --short   # nothing unexpected staged
git commit -m "feat(finish): /finish replaces /merge — integrate and report, never remove"
```

---

### Task 7: The TUI's ON FINISH plan tells the truth

**Files:**
- Modify: `tui/src/ui.rs:2042-2076` (plan text) and the tests at `tui/src/ui.rs:4512-4547`, `4618-4645`
- Test: `cargo test --manifest-path tui/Cargo.toml`

**Interfaces:**
- Consumes: `_feature_readiness` porcelain unchanged (`ahead`, `merged`, `ff`, …).
- Produces: nothing; the footer at `ui.rs:954` already says `Enter:finish`.

- [ ] **Step 1: Rewrite the three pinned tests first**

Replace `merge_screen_keeps_the_gates_in_the_cleanup_plan` with:

```rust
    #[test]
    fn merge_screen_names_the_temp_gate_and_keeps_the_worktree() {
        // Enter arms /finish: merge in a temp worktree, gate there, fast-forward
        // the base, keep everything. The plan must say where the gate runs and
        // that nothing is removed.
        let mut app = merge_app();
        let text = render_wide(&mut app);
        assert!(text.contains("temp checkout"), "the gate location must be named:\n{text}");
        assert!(text.contains("stay"), "retention must be stated:\n{text}");
        assert!(!text.contains("remove worktree"), "/finish removes nothing:\n{text}");
        assert!(!text.contains("delete branch"), "/finish deletes nothing:\n{text}");
    }
```

Replace `merge_screen_puts_removal_in_the_merge_step_not_after_the_gates` with:

```rust
    #[test]
    fn merge_screen_points_retirement_at_the_verb() {
        // Retirement is still cs <base> --merge <task>, run later by the user.
        let mut app = merge_app();
        let text = render_wide(&mut app);
        assert!(
            text.contains("cs myproj --merge"),
            "the retire verb must be named as a later step:\n{text}"
        );
    }
```

In `merge_screen_keeps_the_whole_plan_on_a_short_terminal`, change the assertion to `text.contains("cs myproj --merge")` with the message "the retire line must survive a 21-row terminal".

In `merge_screen_does_not_promise_a_merge_for_an_already_merged_feature`, change `"already merged"` to `"already integrated"` and keep the "neither merge shape" assertion.

In `merge_screen_does_not_promise_a_merge_for_a_branch_at_base_head` (`ui.rs:4489`), change `"nothing to merge"` to `"nothing to land"` and add `assert!(!text.contains("temp checkout"), "no gate runs when nothing lands:\n{text}")` — the entry returns before creating any checkout in that case.

Replace `merge_screen_names_fast_forward_versus_merge_commit` (`ui.rs:4742`) — its ff-versus-merge distinction no longer exists, every ordinary landing is a merge commit — with:

```rust
    #[test]
    fn merge_screen_promises_a_merge_commit_for_every_ordinary_landing() {
        // The entry merges --no-ff, so the ff/merge-commit split the old
        // verb had is gone: both rows promise a merge commit.
        let mut app = merge_app();
        let text = render_wide(&mut app);
        assert!(text.contains("merge commit"), "an ff-able feature still lands as a merge commit:\n{text}");
        assert!(!text.contains("fast-forward "), "fast-forward is never promised for the landing shape:\n{text}");
        app.merge_selected = 1; // ff: false
        let text = render_wide(&mut app);
        assert!(text.contains("merge commit"), "a non-ff feature lands as a merge commit:\n{text}");
    }
```

(The assertion uses `"fast-forward "` with a trailing space so the step-2 phrase "fast-forward myproj onto the result" — which is the base fast-forwarding onto the temp's result, not the landing shape — needs renaming too: use "land on myproj (merge commit)" for step 2; see Step 3.)

- [ ] **Step 2: Run to see them fail**

Run: `cargo test --manifest-path tui/Cargo.toml merge_screen > "$TMPDIR/t7.out" 2>&1; echo "rc=$?"; grep -E 'test result|FAILED|panicked' "$TMPDIR/t7.out"`
Expected: rc=101; the six rewritten tests fail on the old wording.

- [ ] **Step 3: Rewrite the plan block**

Replace `tui/src/ui.rs:2045-2076` (from the `// Enter arms /merge` comment through the `step 3` push) with:

```rust
        // Enter arms /finish: cs merges base + the captured feature commit in
        // a temporary detached worktree, runs the gates THERE, and fast-forwards
        // the base onto the result. Nothing is removed; retirement is a later,
        // separate verb. `ahead == 0` is the entry's own "already integrated"
        // condition (is-ancestor of base HEAD), so no merge is promised then.
        let nothing_to_merge = f.ahead == 0;
        // The whole plan is conditional: when nothing lands, the entry
        // returns before creating a checkout or running a gate.
        let (step1, step2) = if nothing_to_merge {
            (
                format!("    1  already integrated into {} \u{b7} nothing to land", app.merge_base),
                "    2  no checkout, no gates".to_string(),
            )
        } else {
            (
                format!("    1  merge {} + {} in a temp checkout \u{b7} gates there", app.merge_base, f.branch),
                format!("    2  land on {} (merge commit)", app.merge_base),
            )
        };
        lines.push(Line::from(Span::styled(step1, Style::default().fg(p.ink))));
        lines.push(Line::from(Span::styled(step2, Style::default().fg(p.ink))));
        // Two lines: Paragraph truncates rather than wraps, and a real base
        // and task name would push the verb off the tail of one line.
        lines.push(Line::from(Span::styled("    3  worktree, branch and session stay", Style::default().fg(p.ink))));
        lines.push(Line::from(Span::styled(
            format!("       retire later: cs {} --merge {}", app.merge_base, f.task),
            Style::default().fg(p.mut_),
        )));
```

The detail body grew by one line; if `merge_screen_keeps_the_whole_plan_on_a_short_terminal` (21 rows) fails on the retire line, lower the list's minimum height by one in the same layout arithmetic that already yields to the detail pane (find it by the test's own comment "the list must yield"), rather than shortening the plan.

Check the field names on the feature record (`f.branch`, `f.task`) against the struct the porcelain parser fills (`grep -n 'struct.*Feature\|pub branch\|pub task' tui/src/app.rs`) and use the real names. If `f.ff` is now unread anywhere, `cargo build` warns `dead_code`; keep the field (it is the porcelain contract, column 5) and silence with `#[allow(dead_code)]` on that field only, with a one-line comment naming the column.

- [ ] **Step 4: Run the whole TUI test suite**

Run: `cargo test --manifest-path tui/Cargo.toml 2>&1 | tail -5`
Expected: all pass, no new warnings in the build output (`cargo build --manifest-path tui/Cargo.toml 2>&1 | grep -c warning` unchanged from `main`).

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "feat(tui): the ON FINISH plan describes /finish — gates in a temp, nothing removed"
```

---

### Task 8: Docs, changelog, and the gate

**Files:**
- Modify: `README.md:136-141` (command table), `:185` (TUI paragraph), `:288-305` (worktree section)
- Modify: `CHANGELOG.md` (new `## Unreleased` above `## 2026.9.13`)
- Modify: `docs/hooks.md` (done in Task 1; re-read)
- Test: `tests/test_docs.sh` (no new pin needed; run it), full suite on ghost

- [ ] **Step 1: README**

Line 140: `cs <base> -finish <feature> # Open <base> and run /finish for <feature> (integrate, keep the worktree)`.

Line 185, replace the last two sentences: `Enter leaves the picker and runs `cs <base> -finish <feature>`, which opens the base with `/finish <feature>` armed: it integrates the feature and keeps the worktree. The picker never merges anything itself`.

Lines 288-296, replace the paragraph starting "The `merge` skill" with:

```markdown
The `finish` skill (`/finish <feature>` in the base session) lands a feature
while its conversation stays open: it captures the feature commit, merges
base and feature in a temporary detached worktree, runs the repo's gates
there, fast-forwards the base onto the result, and reports whether a GitHub
PR exists for the branch. It removes nothing. Ordinary feature branches get
the older gated `--no-ff` ritual from the same skill. It is user-invoked
only (`disable-model-invocation: true`).

Retirement stays a separate, explicit verb:
```

so that the existing `cs myproj --merge fix-auth   # merge cs/fix-auth, fuse records, remove worktree` block follows it. Keep the paragraph after it ("Run this from the base session…") unchanged.

- [ ] **Step 2: CHANGELOG**

Insert above `## 2026.9.13`:

```markdown
## Unreleased

### Features
- `/finish <feature>` integrates a feature worktree while its conversation stays open. It captures the feature commit, merges base and feature in a temporary detached worktree under the repo's git directory, runs the repo's gates there, and fast-forwards the base onto the result: a red gate, a conflict, or a base that moved during the gates leaves the base exactly as it was. It reports GitHub PR state for the branch (none, open, merged, closed, or unknown with the reason — a `gh` failure is never read as "no PR") and lands a merged PR by its merge commit, so local integrates and remote PRs mix freely. It removes nothing. Retirement stays `cs <base> --merge <feature>`, and after a squash-merged PR the skill says not to run it.

### Changed
- `/merge` is retired; `/finish` replaces it. `cs <base> -finish <feature>` and the TUI's Enter on the readiness screen now arm `/finish`, which keeps the worktree. The TUI's ON FINISH plan describes the new shape.

### Fixes
- The autosave hook labels each snapshot with the HEAD it started from, read before the tree is written. A HEAD that moved mid-snapshot was labelled onto the old tree, which is the exact case the label exists to expose at crash recovery. The hook also skips (never waits) while an integrate holds the repo's integrate mutex, and holds that mutex itself for the tree write.
```

- [ ] **Step 3: Named suites locally, the full gate on ghost**

`lib/` and `hooks/` changed, so `--changed` would run the full suite locally; skip it. Run `./build.sh`, then the touched suites by name, each with its exit status captured (never `| tail`, which reports tail's status and can SIGPIPE the suite):

```bash
for s in test_shadow_ref test_worktrees test_finish_script test_finish_skill test_retired_skills test_install test_hooks test_help test_completions test_docs; do
    bash "tests/$s.sh" > "$TMPDIR/$s.out" 2>&1; echo "$s rc=$?"; grep -E '^Results:' "$TMPDIR/$s.out"
done
```

Then invoke the `claude-tmux:remote-tests` skill for the full suite on ghost, in the background, with its output captured to a file under the scratchpad.

Expected on ghost: every suite green, `bin/cs` in sync.

- [ ] **Step 4: Install and open cold**

Run: `./install.sh` then `cs -doctor 2>&1 | tail -20`
Expected: doctor reports `finish/scripts/finish.sh` deployed and no drift, and no `merge` skill directory under `~/.claude/skills/`.

Then the discoverability pass: in a throwaway session (`cs finish-probe`, then `cs finish-probe@t1`, one commit in `t1`, back in `finish-probe` type `/finish t1`) confirm the skill runs `prepare`, discovers a gate, calls the entry, and prints the report with the retire line. Then `cs -rm finish-probe@t1` and `cs -rm finish-probe`.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(finish): README, changelog for /finish"
```

Do not merge or release. Report: the branch, the ghost result file, and the three departures Alex has to rule on (hook wording in Task 6, the TUI plan text in Task 7, the `_foreign_live_lock_pid` extraction in Task 2).

---

## Self-review against the spec

- **Decisions 1–10**: 1 (Task 6), 2 (no retire change anywhere; `merge_worktree_session` only gains the shared helper), 3 (Tasks 2–3 entry; Task 5 script; `CS_SKILL_FILES` in Task 6), 4 (Task 3), 5 (Task 2 ownership; Task 5 `role: feature` hand-off), 6 (Task 4), 7 (Task 5 `pr_lookup`), 8 (Task 3 `--no-ff` and `already-integrated`), 9 (Task 5 `dirt:` lines; SKILL.md step 1), 10 (Task 1).
- **Mechanism, entry steps 1–10**: 1–5 Task 2; 6–10 Task 3. Tracked-mode MEMORY.md warning: Task 2 helper, Task 3 call and test.
- **Mechanism, skill steps 1–7**: Task 5 (1–3, 7), SKILL.md (4–6).
- **Squash notice**: Task 5 `report`, Task 6 SKILL.md, Task 4's squash test proves the `landed: no` input.
- **Autosave hook**: Task 1, including "acquire inside the backgrounded function".
- **`-finish` and the TUI**: Task 6 kick line; Task 7 pane (beyond the spec's footer-only reading, flagged above).
- **Testing section**: every listed `test_worktrees.sh` case has a test (Tasks 2–4); both `test_hooks.sh` cases are in `test_shadow_ref.sh` (Task 1, flagged); `test_finish_skill.sh` (Task 6); `test_install.sh` needs no edit — its existing derived checks cover `finish/scripts/finish.sh` and `merge` retirement.
- **Files section**: `docs/hooks.md` (Task 1), README and CHANGELOG (Task 8), `skills/merge/` removed (Task 6). `tests/test_hooks.sh` is touched only for the subagent-context pin.
- **Placeholder scan**: no TBD/TODO; every code step carries its code.
- **Name consistency**: `integrate_feature_worktree`, `_integrate_in_temp`, `_integrate_cleanup`, `_foreign_live_lock_pid`, `_git_path_abs`, `_setup_merge_attributes_clone_local`, `_warn_memory_index_changed`, `finish.sh prepare|report`, keys `role/base/task/handoff/worktree/branch/sha/dirt_count/dirt/base_branch/pr_state/pr_number/pr_url/pr_merge_commit/pr_base_ref/pr_reason/landed/base_head/not_integrated/retire`, summary lines `integrated … -> …` and `already-integrated …`, event `feature-integrated`, mutex `<common>/cs/integrate.lock`, temp `<common>/cs/finish/<task>.<pid>` — used identically in every task.
