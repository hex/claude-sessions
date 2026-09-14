#!/usr/bin/env bash
# ABOUTME: Tests for worktree-backed parallel task sessions
# ABOUTME: Covers name parsing, creation, launch env, merge-back, removal, doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"


# --- Name parsing (via cs CLI behavior) ---

test_worktree_name_rejected_without_base() {
    local output
    output=$("$CS_BIN" "@fix-auth" 2>&1 || true)
    assert_output_contains "$output" "Session name" "empty base half must be rejected" || return 1
}

test_worktree_name_rejects_bad_task_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@fix/auth" 2>&1 || true)
    assert_output_contains "$output" "feature name" "slash in feature half must be rejected" || return 1
}

test_plain_names_still_work() {
    local output
    output=$("$CS_BIN" "-list" 2>&1)
    assert_output_not_contains "$output" "Unknown" "plain subcommands unaffected" || return 1
}

# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Land the feature tip into the base through the integrate entry with a
# trivial gate, the way /finish does before it retires; prints the sha.
land_feature() {  # base task
    local wt="$CS_SESSIONS_ROOT/$1@$2" sha
    sha=$(git -C "$wt" rev-parse HEAD) || return 1
    "$CS_BIN" "$1" -integrate-feature "$2" "$sha" -- true >/dev/null 2>&1 || return 1
    printf '%s\n' "$sha"
}

# Build a ps seam for the ownership walk. Process inspection may be restricted
# in a test sandbox; production uses BSD ps, while these integration tests
# inject the one parent edge relevant to the scenario.
fixed_parent_ps_stub() {
    local parent="$1" stub="$TEST_TMPDIR/parent-ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
printf '%s\n' "$parent"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    assert_dir "$wt" "worktree dir should exist" || return 1
    assert_file_exists "$wt/.git" "linked worktree .git should be a file" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$wt" branch --show-current)" "worktree on task branch" || return 1
    assert_file_exists "$wt/.cs/README.md" "tracked .cs rides the checkout" || return 1
    assert_file_contains "$wt/.cs/local/state" "task_branch: cs/fix-auth" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_base: myproj" || return 1
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
    assert_output_contains "$output" "uncommitted" "dirty base must refuse" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

test_worktree_create_reuses_existing_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" branch cs/fix-auth
    cs_launch "myproj@fix-auth"
    assert_eq "cs/fix-auth" "$(git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" branch --show-current)" \
        "existing branch is reused, not errored on" || return 1
}

test_worktree_create_ignored_mode_bootstraps_cs() {
    # A repo whose .gitignore excludes .cs/ entirely (like the cs dev repo)
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_dir "$wt/.cs/memory" "ignored mode bootstraps .cs skeleton" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "# Project CLAUDE.md" "$(cat "$wt/CLAUDE.md")" \
        "bootstrap must not overwrite the project's CLAUDE.md" || return 1
}

test_ignored_mode_worktree_starts_with_nothing_untracked() {
    # Ignored mode only means .cs is not TRACKED — it does not mean the project
    # ignores it. A project that never gitignored .cs/ gets a worktree whose .cs
    # skeleton cs itself just wrote, untracked, which the merge preflight then
    # refuses. cs must not manufacture its own merge blocker.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    # No .gitignore entry for .cs/ — this is the freya shape.
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    assert_eq "" "$others" "a fresh ignored-mode worktree must have nothing untracked" || return 1
}

test_ignored_mode_worktree_retires_without_a_manual_exclude() {
    # The end the user actually hits: create, commit work, /finish lands it,
    # then retires the worktree.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "untracked files that removal would destroy" \
        "cs must not refuse over the .cs skeleton it wrote itself" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_tolerates_a_worktree_predating_the_cs_exclude() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked, and upgrading cs must unblock it without the user editing
    # info/exclude by hand. Model that by stripping the entry after creation.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so this test exercises the preflight rather than the exclude.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "untracked files that removal would destroy" \
        "an older worktree's .cs skeleton must not block retirement" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_still_refuses_real_untracked_work() {
    # The carve-out is scoped to cs's own bookkeeping. A file the user would
    # lose must still stop the removal — that is what the gate is for.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_contains "$output" "untracked files that removal would destroy" \
        "real untracked work must still refuse" || return 1
    assert_output_contains "$output" "notes.txt" "the refusal names the file at risk" || return 1
    assert_dir "$wt" "the worktree survives a refusal" || return 1
}

test_worktree_of_worktree_refused() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj@fix-auth@deeper" 2>&1 || true)
    assert_output_contains "$output" "feature name" "second @ lands in the feature half and is rejected" || return 1
}

test_worktree_create_succeeds_with_untracked_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "stray" > "$base_dir/stray.txt"   # untracked, must not corrupt the captured path
    local output status=0
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "cs must exit 0 despite the untracked-files warning" || return 1
    assert_output_not_contains "$output" "No such file" \
        "captured worktree path must not be corrupted by the warning" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree created" || return 1
}

test_worktree_reopen_preserves_project_claude_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    cs_launch "proj@task1"   # reopen — the path that used to run migrate_session
    assert_eq "# Project CLAUDE.md" "$(cat "$CS_SESSIONS_ROOT/proj@task1/CLAUDE.md")" \
        "reopen must not rewrite the project's CLAUDE.md" || return 1
}

test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out _try
    stub=$(_make_env_stub)
    # The reopen launch execs the stub, which prints its env. On a loaded runner
    # the launch can occasionally race the create launch's lock/PID cleanup and
    # take a cancel path, capturing empty output. Retry until the exported
    # identity appears, so the assertions test the identity, not runner load; a
    # genuine failure to export still fails all attempts.
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=myproj@fix-auth"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name" || return 1
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj" "task list is shared with the base" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj@" "task list id must be the base, not the worktree name" || return 1
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base" || return 1
}

# Claude Code v2.1.233+ leaves the Task tools out on Opus 4.8, Sonnet 5 and
# Fable 5 unless the session opts in. cs's rotation wake, the walk-away drain
# and the rotate skill all address the native task list, so a launch has to
# opt in or those instructions land on a conversation with no list to keep.
# CS_NO_TASK_TOOLS=1 leaves the choice to Claude Code for users who want the
# context back.
# Both launches run under `env -u CLAUDE_CODE_ENABLE_TODO_TOOLS`: a cs session
# exports it, so a suite run from inside one inherits it and the opt-out arm
# reads the developer's environment instead of what cs decided. CI never sets
# it, so the failure appears only on a developer machine.
test_launch_enables_the_task_tools_unless_opted_out() {
    local stub env_out
    stub=$(_make_env_stub)
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=1" "a cs launch opts the session into the Task tools" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CS_NO_TASK_TOOLS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools-off" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools-off"*) break ;; esac
    done
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=" "CS_NO_TASK_TOOLS leaves the decision to Claude Code" || return 1
}

test_retire_after_integrate_removes_worktree_and_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Simulate task work: code + session records, committed on the branch
    echo "fix" > "$wt/auth.txt"
    echo '{"ts":"2026-07-02T00:00:00Z","event":"task"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1)
    assert_eq "retired fix-auth $sha" "$output" "the entry's own summary line" || return 1
    assert_file_exists "$base_dir/auth.txt" "code landed by the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"task"' "timeline union-merged" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "worktree-retired" "retirement recorded" || return 1
}

test_retire_refuses_dirty_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "uncommitted" >> "$wt/CLAUDE.md"
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty worktree refused" || return 1
    assert_dir "$wt" "worktree preserved on refusal" || return 1
}

test_retire_refuses_a_live_feature_session_and_says_what_to_do() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1 || true)
    assert_output_contains "$output" "the 'myproj@fix-auth' conversation is open in it (PID $$)" \
        "the refusal names the open conversation" || return 1
    assert_output_contains "$output" "Close that session yourself (/exit there), then run /finish fix-auth here again" \
        "and tells the user, plainly, what to do" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    rm -f "$wt/.cs/session.lock"
}

test_retire_from_live_base_session_succeeds() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="11111111-1111-4111-8111-111111111111"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # The lock owner is this test shell, an ancestor of the cs subprocess just
    # like a cs launcher/Claude process is an ancestor of an in-session Bash tool.
    echo "$$" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "$$")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    assert_eq "0" "$status" "the live base session should be allowed to retire: $output" || return 1
    assert_not_exists "$wt" "retired worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retired branch deleted" || return 1
}

test_retire_from_inside_the_feature_session_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local wt_uuid
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2; exit}' "$wt/.cs/local/state")
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    echo "$$" > "$wt/.cs/session.lock"
    local output status=0
    output=$(cd "$wt" && CLAUDE_SESSION_NAME="myproj@fix-auth" \
        CS_CLAUDE_SESSION_ID="$wt_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a feature session must not remove its own live worktree"; return 1; }
    assert_output_contains "$output" "This is the 'myproj@fix-auth' conversation itself" \
        "self-retire refusal identifies the dangerous scenario" || return 1
    assert_output_contains "$output" "Close this session, then run /finish fix-auth in 'myproj'" \
        "self-retire refusal gives the hand-off" || return 1
    assert_dir "$wt" "self-retire refusal preserves the worktree" || return 1
}

test_retire_foreign_live_base_lock_still_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="22222222-2222-4222-8222-222222222222"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$base_dir/.cs/session.lock"

    local output status=0
    output=$(CLAUDE_SESSION_NAME="foreign" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a foreign live base lock must refuse"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "foreign live lock keeps the hard refusal" || return 1
    assert_dir "$wt" "foreign-lock refusal preserves the worktree" || return 1
}

test_retire_reused_live_pid_is_not_treated_as_own_lock() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="33333333-3333-4333-8333-333333333333"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # A stale lock can point at a PID later reused by an unrelated live process.
    # The matching name and UUID are insufficient: that PID must own this cs call.
    sleep 30 &
    local reused_pid=$!
    echo "$reused_pid" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "1")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    kill "$reused_pid" 2>/dev/null || true
    wait "$reused_pid" 2>/dev/null || true

    [ "$status" -ne 0 ] || { echo "  FAIL: a reused foreign PID must not be exempted"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "reused live PID keeps the hard refusal" || return 1
    assert_dir "$wt" "reused-PID refusal preserves the worktree" || return 1
}

test_retire_refuses_an_unintegrated_feature() {
    # Retirement never merges: a commit the base lacks is a refusal that
    # names /finish, whatever the old merge verb would have done with it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "an unintegrated feature is refused" || return 1
    assert_output_contains "$output" "is not integrated into myproj; run /finish fix-auth before retiring" \
        "the refusal names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_file_not_exists "$base_dir/shared.txt" "nothing was merged" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth | tr -d ' *+')" "branch kept" || return 1
}

test_retire_refuses_commits_after_the_captured_one() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "one" > "$wt/one.txt"
    (cd "$wt" && git add one.txt && git commit -q -m one)
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "two" > "$wt/two.txt"
    (cd "$wt" && git add two.txt && git commit -q -m two)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a tip the base lacks is refused" || return 1
    assert_output_contains "$output" "1 commit(s) on cs/fix-auth after $sha are not integrated; run /finish fix-auth again" \
        "the refusal counts the commits and names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_force_takes_a_squash_landed_branch() {
    # A PR squash-merged on GitHub leaves cs/<task> a non-ancestor of the base
    # forever; the skill passes --force on that evidence, and the branch goes
    # with -D since -d would refuse it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "squashed elsewhere" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "0" "$status" "force retires: $output" || return 1
    assert_eq "retired fix-auth $sha" "$output" "the summary line" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "unmerged branch deleted under force" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "force never merges" || return 1
}

test_retire_force_still_refuses_untracked_work() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "precious" > "$wt/never-added.txt"
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "1" "$status" "force skips the ancestry check only" || return 1
    assert_output_contains "$output" "never-added.txt" "the refusal names the path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_rejects_traversal_task_name() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    # A task argument with path separators would build an escaping worktree
    # path; the entry must reject it with the feature-name charset error before
    # touching the filesystem, matching the launch path's validation.
    local output status=0
    output=$("$CS_BIN" "myproj" -retire-feature "e/../../x" deadbeef 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a task name with path separators must be rejected"; return 1; }
    assert_output_contains "$output" "alphanumeric" "rejects a traversal task name with the charset error" || return 1
}

test_retire_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -retire-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-retire-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'retire-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'retire-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'retire-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'retire-feature' "README never lists it" || return 1
}

test_merge_verb_is_gone() {
    local base_dir output status=0
    base_dir=$(create_test_session_with_git "myproj")
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?
    assert_eq "1" "$status" "--merge is not a session command any more" || return 1
    assert_output_contains "$output" "Unknown session command: --merge" "and says so" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" '[-]-merge' "help does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" '[-]-merge' "zsh completion does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" '[-]-merge' "bash completion does not list it" || return 1
}

# With core.autocrlf enabled, a CRLF-rewritten .gitignore
# carries a trailing \r on every pattern and matches nothing, so files cs means
# to ignore surface as untracked — which then blocks retirement.
test_session_repo_pins_autocrlf_off() {
    local cfg="$TEST_TMPDIR/gitconfig-autocrlf"
    printf '[core]\n\tautocrlf = true\n' > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" "$CS_BIN" acrlf <<< "" >/dev/null 2>&1
    local repo="$CS_SESSIONS_ROOT/acrlf"
    [ -d "$repo/.git" ] || { echo "  FAIL: session repo not created"; return 1; }
    # --local, not the effective value: a global autocrlf=false on the dev box
    # would otherwise satisfy this without cs having written anything.
    assert_eq "false" "$(git -C "$repo" config --local --get core.autocrlf 2>/dev/null)" \
        "a session repo must pin core.autocrlf off in its own config" || return 1
}

# cs records the protocol file in the worktree's info/exclude, at whatever path
# git reports for it. A worktree's git-path is absolute; mis-reading that as
# relative sends the entry to a nonsense path,
# leaves CLAUDE.local.md untracked, and blocks retirement.
test_worktree_excludes_protocol_file() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    [ -f "$wt/CLAUDE.local.md" ] || { echo "  FAIL: protocol file not written to the worktree"; return 1; }
    (cd "$wt" && git check-ignore -q CLAUDE.local.md) \
        || { echo "  FAIL: CLAUDE.local.md is not ignored inside the worktree"
             echo "  status: $( (cd "$wt" && git status --porcelain) | tr '\n' ' ')"; return 1; }
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_plain_names_still_work
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_ignored_mode_worktree_starts_with_nothing_untracked
run_test test_ignored_mode_worktree_retires_without_a_manual_exclude
run_test test_retire_tolerates_a_worktree_predating_the_cs_exclude
run_test test_retire_still_refuses_real_untracked_work
run_test test_worktree_of_worktree_refused
run_test test_worktree_create_succeeds_with_untracked_base
run_test test_worktree_reopen_preserves_project_claude_md
run_test test_worktree_launch_exports_base_identity
run_test test_launch_enables_the_task_tools_unless_opted_out
run_test test_retire_after_integrate_removes_worktree_and_branch
run_test test_retire_refuses_dirty_worktree
run_test test_retire_refuses_a_live_feature_session_and_says_what_to_do
run_test test_retire_from_live_base_session_succeeds
run_test test_retire_from_inside_the_feature_session_refuses
run_test test_retire_foreign_live_base_lock_still_refuses
run_test test_retire_reused_live_pid_is_not_treated_as_own_lock
run_test test_retire_refuses_an_unintegrated_feature
run_test test_retire_refuses_commits_after_the_captured_one
run_test test_retire_force_takes_a_squash_landed_branch
run_test test_retire_force_still_refuses_untracked_work
run_test test_retire_rejects_traversal_task_name
run_test test_retire_is_hidden_from_completion_and_unknown_command_text
run_test test_merge_verb_is_gone

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
    # integrate never touches the feature worktree.
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"
    local ps_stub
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CS_PS_BIN="$ps_stub" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds with the feature lock live: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
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
test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt() {
    # In tracked-.cs mode the integrate's own timeline event dirties the base.
    # Retirement touches no base file, so that dirt is no reason to refuse:
    # /finish lands and retires in one run, and the bookkeeping stays the
    # user's to commit.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "the only dirt after an integrate is the tracked timeline event" || return 1
    local head_after_integrate
    head_after_integrate=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds over bookkeeping dirt: $output" || return 1
    assert_eq "$head_after_integrate" "$(git -C "$base_dir" rev-parse HEAD)" "retire makes no new commit" || return 1
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "and commits nothing on the user's behalf" || return 1
    assert_not_exists "$wt" "retire removed the worktree" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retire deleted the branch" || return 1
}

test_retire_still_refuses_real_base_dirt() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "half-typed" >> "$base_dir/CLAUDE.md"
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a dirty base file outside .cs still refuses" || return 1
    assert_output_contains "$output" "Base session has uncommitted changes" "the refusal is the verb's own" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
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

# An untracked base file colliding with a path the feature adds must be caught
# before the gate runs at all: _tree_is_dirty only sees tracked dirt, so
# without this check the gate would run to completion and only THEN hit an
# un-diagnosable ff-only abort.
test_integrate_refuses_untracked_collision_before_the_gate() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "stale" > "$base_dir/feature.txt"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'touch "$0/marker"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "an untracked collision refuses" || return 1
    assert_output_contains "$output" "feature.txt" "names the colliding path" || return 1
    assert_file_not_exists "$TEST_TMPDIR/marker" "the gate never ran" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "stale" "$(cat "$base_dir/feature.txt")" "the untracked file survives with its content" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
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
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
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
    # a plain EXIT trap does not fire on TERM. Bash exec-optimizes the last
    # command of `(cd "$tmp" && "$@")`, so the gate's PPID is cs itself, not
    # a subshell one level down — walk up while the ancestor's argv still
    # names -integrate-feature and terminate the topmost one, which lands on
    # cs under either fork shape.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The marker is written only after the gate has SEEN the mutex held, so a
    # run that never took the lock (or never reached the gate) cannot pass the
    # release assertions below by never having acquired anything.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c '
        test -d "$0" || exit 9
        : > "$1"
        target=""; p=$PPID
        while [ "${p:-1}" -gt 1 ]; do
            case "$(ps -o args= -p "$p" 2>/dev/null)" in
                *" -integrate-feature "*) target=$p ;;
                *) break ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
        done
        kill -TERM "$target"; sleep 2
    ' "$base_dir/.git/cs/integrate.lock" "$TEST_TMPDIR/gate-ran" 2>&1) || status=$?
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_file_exists "$TEST_TMPDIR/gate-ran" "the gate ran with the mutex held" || return 1
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
    assert_output_contains "$output" "git merge $(git -C "$base_dir" symbolic-ref --short HEAD) in $wt" \
        "the advice names the base's real branch and the worktree to run it in" || return 1
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

# The base's own landing is the one merge cs does NOT run with hooks
# suppressed: it is the user's checkout and their post-merge hook is entitled
# to fire. A hook that commits leaves base past the commit cs just landed, so
# the summary must name where the base actually ended up.
test_integrate_survives_a_base_post_merge_hook_that_commits() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/hooks"
    cat > "$base_dir/.git/hooks/post-merge" << 'HOOK'
#!/usr/bin/env bash
git commit -q --allow-empty -m "post-merge bookkeeping"
HOOK
    chmod +x "$base_dir/.git/hooks/post-merge"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "a landing whose hook commits still succeeds: $output" || return 1
    assert_eq "post-merge bookkeeping" "$(git -C "$base_dir" log -1 --format=%s)" "the hook's commit is the base tip" || return 1
    assert_output_contains "$output" "post-merge hook moved" "the hook's move is announced" || return 1
    assert_output_contains "$output" "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" \
        "the summary names the head the base really has" || return 1
    assert_file_exists "$base_dir/feature.txt" "the feature still landed" || return 1
}

run_test test_integrate_lands_a_no_ff_merge_and_keeps_everything
# The gate runs the project's build, and a build that writes into the tree
# would otherwise land content nobody reviewed: what cs fast-forwards the base
# onto is the merge commit, so a gate-written file either vanishes or, once
# committed by the gate, rides in unseen. Refuse instead.
test_integrate_refuses_a_gate_that_writes_into_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo stale > CLAUDE.md' 2>&1) || status=$?
    assert_eq "1" "$status" "a tree-writing gate refuses" || return 1
    assert_output_contains "$output" "CLAUDE.md" "names the path the gate changed" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs/finish" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_a_gate_that_commits_in_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    # A real commit: `git add . && git commit` with nothing changed exits 1 and
    # would be caught as a red gate instead, proving nothing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo generated > built.txt && git add . && git commit -q -m gate-made' 2>&1) || status=$?
    assert_eq "1" "$status" "a committing gate refuses" || return 1
    assert_output_not_contains "$output" "Gate failed" "the gate itself was green; this is the tamper refusal" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
}

test_integrate_refuses_a_gate_that_moves_the_temp_head() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git checkout -q "$head" 2>&1) || status=$?
    assert_eq "1" "$status" "a gate that moves the temp HEAD refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

run_test test_integrate_survives_a_base_post_merge_hook_that_commits
run_test test_integrate_refuses_a_gate_that_writes_into_the_temp
run_test test_integrate_refuses_a_gate_that_commits_in_the_temp
# A detached base has no branch to land on: the ff-only would move a
# detached HEAD and leave the branch behind. The refusal belongs before the
# local/PR split, so both paths get it.
test_integrate_refuses_a_detached_base() {
    local sha base_dir branch head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    head=$(git -C "$base_dir" rev-parse HEAD)
    git -C "$base_dir" checkout -q --detach
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "the local path refuses a detached base" || return 1
    assert_output_contains "$output" "Base checkout is detached" "names the state" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse "$branch")" "the branch is unmoved" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "HEAD is unmoved" || return 1
}

run_test test_integrate_refuses_a_gate_that_moves_the_temp_head
run_test test_integrate_refuses_a_detached_base
run_test test_integrate_tracked_mode_union_merges_shared_records
run_test test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt
run_test test_retire_still_refuses_real_base_dirt
run_test test_integrate_red_gate_leaves_base_untouched
run_test test_integrate_refuses_untracked_collision_before_the_gate
run_test test_integrate_gates_run_in_the_temp_not_the_live_trees
run_test test_integrate_refuses_when_base_moved_during_gates
run_test test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates
run_test test_integrate_refuses_when_base_dirtied_during_gates
run_test test_integrate_terminated_mid_gate_leaves_no_lock_or_temp
run_test test_integrate_conflict_names_the_path_and_leaves_no_merge_head
run_test test_integrate_ignored_mode_fuses_nothing
run_test test_integrate_tracked_mode_warns_on_memory_index_change

test_retire_ignored_mode_fuses_records() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "base note" > "$base_dir/.cs/memory/note-base.md"
    printf -- '---\ndescription: seed\n---\n# Session narrative (tester)\n\n## Prior finding\n' \
        > "$base_dir/.cs/memory/narrative.tester.md"
    printf -- '---\ndescription: plain-seed\n---\n# Session narrative (plain)\n' \
        > "$base_dir/.cs/memory/narrative.plain.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    # Task work: code (committed) + session records (untracked .cs)
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo '{"event":"from-task"}' >> "$wt/.cs/timeline.jsonl"
    echo "task memory" > "$wt/.cs/memory/note-task.md"
    printf -- '---\nname: n\n---\n# Session narrative (tester)\n\n## Task finding\n\n---\n\n## After rule\n' \
        > "$wt/.cs/memory/narrative.tester.md"
    printf -- '---\nname: other-n\n---\n# Session narrative (other)\n\n## Other finding\n' \
        > "$wt/.cs/memory/narrative.other.md"
    printf -- '# Session narrative (plain)\n\n## Plain finding\n' \
        > "$wt/.cs/memory/narrative.plain.md"
    echo "task version" > "$wt/.cs/memory/note-base.md"
    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }
    assert_output_contains "$output" "memory/note-base.md already exists in the base; skipped" \
        "memory collision warned" || return 1
    assert_eq "base note" "$(cat "$base_dir/.cs/memory/note-base.md")" "memory collision keeps base copy" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "from-task" "timeline appended" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-task.md" "memory file copied" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-base.md" "base memory untouched" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "Task finding" "narrative body appended" || return 1
    assert_file_not_contains "$base_dir/.cs/memory/narrative.tester.md" "name: n" "frontmatter not duplicated" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "description: seed" "base frontmatter kept" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "After rule" \
        "body after horizontal rule survives" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "Plain finding" \
        "no-frontmatter body appended" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "description: plain-seed" \
        "plain base frontmatter kept" || return 1
    assert_file_exists "$base_dir/.cs/memory/narrative.other.md" "unseen narrative copied" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.other.md" "name: other-n" "first copy keeps frontmatter" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_file_exists "$base_dir/result.txt" "code landed by the integrate" || return 1
}

run_test test_retire_ignored_mode_fuses_records

test_retire_fuse_survives_a_torn_timeline_tail() {
    # A crash mid-append leaves a last line with no newline. Appending onto it
    # splices two records into one, and the reader's tolerant `fromjson? //
    # empty` then drops BOTH — the splice and the record that followed it.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add -A && git commit -q -m init)
    # Torn tail: the last record has no terminating newline.
    printf '{"event":"base-last"}' > "$base_dir/.cs/timeline.jsonl"
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    # Fixture sanity: the base tail really is unterminated, or the splice the
    # test is about cannot happen.
    assert_eq "}" "$(tail -c 1 "$base_dir/.cs/timeline.jsonl")" \
        "fixture must leave the base timeline unterminated" || return 1

    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }

    # Parse the way cs reads it: one record per line, malformed lines dropped.
    local events
    events=$(jq -rRs '[split("\n")[] | select(length > 0) | (fromjson? // empty) | .event] | join(",")' \
        "$base_dir/.cs/timeline.jsonl" 2>/dev/null)
    assert_output_contains "$events" "base-last" \
        "the torn base record must survive the fuse" || return 1
    assert_output_contains "$events" "from-task" \
        "the fused record must survive the fuse" || return 1
}

run_test test_retire_fuse_survives_a_torn_timeline_tail

test_rm_worktree_unregisters_and_prompts_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Confirm removal, decline branch deletion
    printf 'y\nn\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm "myproj@fix-auth" > /dev/null 2>&1
    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept when declined" || return 1
}

test_rm_worktree_force_noninteractive_keeps_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    "$CS_BIN" -rm "myproj@fix-auth" --force </dev/null >/dev/null 2>&1 || return 1

    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    # The nested branch-delete question defaults to NO under --force: this
    # assertion pins that rule, not just that removal succeeded.
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept under --force with no tty" || return 1
}

run_test test_rm_worktree_unregisters_and_prompts_branch
run_test test_rm_worktree_force_noninteractive_keeps_branch

test_doctor_flags_dangling_and_merged_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@done-task"
    # Simulate a completed-but-unmerged-cleanup state: merge manually.
    # --no-ff so the base HEAD moves past the branch tip; a fast-forward
    # would leave tip == HEAD, indistinguishable from a fresh worktree.
    (cd "$CS_SESSIONS_ROOT/myproj@done-task" && echo x > f && git add f && git commit -q -m t)
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/done-task)
    # And a dangling dir that git does not know about
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost/.cs/local"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_contains "$output" "ghost" "dangling @-dir flagged" || return 1
    assert_output_contains "$output" "myproj@done-task branch cs/done-task is fully merged" \
        "merged-but-present worktree flagged" || return 1
}

run_test test_doctor_flags_dangling_and_merged_worktrees

test_doctor_fresh_worktree_not_flagged_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fresh-task"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_not_contains "$output" "fully merged" \
        "fresh worktree (tip == base HEAD) must not read as merged" || return 1
    assert_output_contains "$output" "Worktrees: myproj@fresh-task on cs/fresh-task" \
        "fresh worktree reported OK" || return 1
}

run_test test_doctor_fresh_worktree_not_flagged_merged


test_retire_refuses_untracked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "committed" > "$wt/done.txt"
    (cd "$wt" && git add done.txt && git commit -q -m work)
    echo "precious" > "$wt/never-added.txt"   # untracked user work
    local output status=0
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: retire must refuse"; return 1; }
    assert_output_contains "$output" "untracked" "refusal names the problem" || return 1
    assert_output_contains "$output" "never-added.txt" "refusal names the exact path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "precious" "$(cat "$wt/never-added.txt")" "untracked work survives" || return 1
}

run_test test_retire_refuses_untracked_worktree

test_worktree_secrets_flag_targets_base_namespace() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create the worktree first
    local output
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1)
    assert_output_contains "$output" "session: myproj" \
        "worktree -secrets flag must target the base namespace" || return 1
    assert_output_not_contains "$output" "session: myproj@fix-auth" \
        "must not target the nonexistent worktree namespace" || return 1
}

run_test test_worktree_secrets_flag_targets_base_namespace


test_worktree_create_dirty_base_consent_yes() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "consented creation should launch, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@t1" "worktree created after consent" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/myproj@t1/.cs/local/state" "task_branch: cs/t1" \
        "worktree fully initialized" || return 1
}

test_worktree_create_dirty_base_consent_no() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "declined consent cancels cleanly, got: $output" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@t1" "no worktree without consent" || return 1
}

run_test test_worktree_create_dirty_base_consent_yes
run_test test_worktree_create_dirty_base_consent_no
run_test test_session_repo_pins_autocrlf_off
run_test test_worktree_excludes_protocol_file

test_features_lists_only_verified_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # A directory that looks like a worktree but was never registered with git.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@hand-made/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "fix-auth" "a registered worktree is listed" || return 1
    assert_output_not_contains "$output" "hand-made" "an unregistered lookalike must be excluded" || return 1
}

run_test test_features_lists_only_verified_worktrees

test_features_is_empty_for_a_base_with_no_worktrees() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_eq "" "$output" "a base with no features prints nothing" || return 1
}

run_test test_features_is_empty_for_a_base_with_no_worktrees

test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one() {
    # The verification compares whole lines. A one-sided anchor would verify
    # "wip" against the registered "wip-2", which is precisely the unregistered
    # directory this function exists to exclude. Prefix-colliding task names are
    # ordinary, so this is a realistic collision, not a contrived one.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    mkdir -p "$CS_SESSIONS_ROOT/myproj@wip/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "wip-2" "the registered worktree is listed" || return 1
    assert_output_not_contains "$output" $'^wip\t' "an unregistered prefix must not verify" || return 1
}

run_test test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one

# Field positions in a -features --porcelain record.
_feat_field() {  # line field_number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

test_features_untracked_is_not_reported_as_dirty() {
    # _tree_is_dirty deliberately excludes untracked files: a worktree holding
    # only untracked files is NOT dirty, but is still refused, by a different
    # gate with a different message. A porcelain-non-empty test would conflate
    # them and the screen would disagree with the gate.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 6)" "untracked files must not set wt_dirty" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the untracked file must be counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_untracked_is_not_reported_as_dirty

test_features_does_not_count_the_bookkeeping_the_merge_gate_skips() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked. The merge gate filters exactly that set and would succeed, so
    # readiness reporting "blocked" sends the user hunting for work to commit
    # that is not theirs and does not exist.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so the readiness path is reached with something to filter.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 7)" \
        "cs's own bookkeeping is not untracked work" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" \
        "readiness must agree with the gate that would let this merge through" || return 1
}

run_test test_features_does_not_count_the_bookkeeping_the_merge_gate_skips

test_features_still_counts_real_untracked_work_in_an_old_worktree() {
    # The filter is scoped to cs's bookkeeping. A file the user would lose must
    # still show up in the count and in the state, or readiness becomes a lie in
    # the other direction.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 7)" "the user's file is still counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_still_counts_real_untracked_work_in_an_old_worktree

test_features_fresh_worktree_is_not_already_merged() {
    # A fresh worktree's branch sits AT base HEAD, where merge-base
    # --is-ancestor is also true. Reporting that as already-merged is
    # destructive: cs reads is-ancestor as "already merged; cleaning up" and
    # removes the worktree and deletes the branch.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 4)" "a branch AT base HEAD is not already merged" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a fresh clean worktree is ready" || return 1
}

run_test test_features_fresh_worktree_is_not_already_merged

test_features_reports_a_branch_strictly_behind_as_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 4)" "a tip strictly behind base HEAD is merged" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "state must say merged" || return 1
}

run_test test_features_reports_a_branch_strictly_behind_as_merged

test_features_counts_commits_ahead() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo one > "$wt/a.txt"; (cd "$wt" && git add -A && git commit -q -m one)
    echo two > "$wt/b.txt"; (cd "$wt" && git add -A && git commit -q -m two)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "2" "$(_feat_field "$line" 3)" "two commits ahead of base HEAD" || return 1
    assert_eq "cs/fix-auth" "$(_feat_field "$line" 2)" "branch comes from the state pin" || return 1
}

run_test test_features_counts_commits_ahead

test_features_reports_a_live_worktree_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$wt/.cs/session.lock"
    assert_eq "worktree" "$(_feat_field "$line" 9)" "a live lock on the feature worktree is lock=worktree" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live worktree lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_worktree_lock_distinctly

test_features_reports_a_live_base_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "$$" > "$base_dir/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$base_dir/.cs/session.lock"
    assert_eq "base" "$(_feat_field "$line" 9)" "a live lock on the base is lock=base" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live base lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_base_lock_distinctly

test_features_ignores_a_dead_lock_pid() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local dead_pid
    dead_pid=$(bash -c 'echo $$')
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 0
    fi
    echo "$dead_pid" > "$wt/.cs/session.lock"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "none" "$(_feat_field "$line" 9)" "a dead pid must not be reported as a lock" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a dead pid must not set state=locked" || return 1
}

run_test test_features_ignores_a_dead_lock_pid

test_features_human_table_names_the_state() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_contains "$output" "FEATURE" "the table carries a header" || return 1
    assert_output_contains "$output" "fix-auth" "the feature is listed" || return 1
    assert_output_contains "$output" "ready" "the state is named" || return 1
}

run_test test_features_human_table_names_the_state

test_finish_arms_the_ritual_without_merging() {
    # -finish opens the base with the ritual armed. It must not merge: the
    # branch is still unmerged and the worktree still exists afterwards.
    # The base session directory already exists (created by
    # create_test_session_with_git below), so this launch is a resume, not a
    # fresh session: it hits the "Continue previous conversation?" prompt, so
    # stdin needs an answer rather than an immediate EOF (< /dev/null exits
    # the launch at that prompt before the exec line is ever reached).
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the launch prompt must arm the ritual" || return 1
    assert_dir "$wt" "the worktree must survive -finish" || return 1
    assert_file_not_exists "$base_dir/auth.txt" "-finish must not merge" || return 1
}

run_test test_finish_arms_the_ritual_without_merging

test_finish_survives_declining_the_resume() {
    # Answering n takes _exec_fresh_rebind, which builds its OWN prompt chain.
    # Missing it drops the merge intent silently on a routine answer.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' \
        > "$CS_SESSIONS_ROOT/myproj/.cs/local/state"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "n" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "a declined resume must keep the merge kick" || return 1
}

run_test test_finish_survives_declining_the_resume

test_finish_rejects_an_unknown_feature() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "no-such-feature" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "no-such-feature" "the refusal must name the feature" || return 1
}

run_test test_finish_rejects_an_unknown_feature

test_finish_rejects_a_prefix_lookalike() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    local output
    output=$("$CS_BIN" "myproj" -finish "wip" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "No feature worktree 'wip'" \
        "a prefix of a real feature must be refused" || return 1
}

run_test test_finish_rejects_a_prefix_lookalike

test_finish_rejects_a_traversal_feature_name() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "../escape" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name" "a path separator must be rejected" || return 1
}

run_test test_finish_rejects_a_traversal_feature_name

test_finish_warns_when_it_displaces_a_spawn_kick() {
    # Both ride claude's single prompt slot. The merge kick wins because the
    # user took the action seconds ago — but the displacement must not be
    # silent, and the warning must not promise the queue runs after the merge:
    # the drain is the Stop hook, which fires at the first turn end.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'other-session\nfirst staged task\n' > "$CS_SESSIONS_ROOT/.spawn/myproj.seed"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the merge kick takes the slot" || return 1
    assert_output_contains "$output" "walk-away queue is armed" "the displacement must be announced" || return 1
    assert_output_not_contains "$output" "after the merge" "must not promise sequencing it cannot enforce" || return 1
}

run_test test_finish_warns_when_it_displaces_a_spawn_kick

test_finish_yields_to_an_explicit_rotation_choice() {
    # r is the user explicitly choosing the rotation handoff at the prompt;
    # a merge armed moments earlier must not silently override that choice.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    mkdir -p "$base_dir/.cs/handoffs"
    cat > "$base_dir/.cs/handoffs/2026-07-16-test.md" << 'EOF'
---
parent: 00000000-0000-4000-8000-000000000000
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: unconsumed
---

## 7. Next Step
Continue the test.
EOF
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "r" 2>&1 || true)
    assert_output_contains "$output" "Rotation handoff takes this launch; re-run: cs myproj -finish fix-auth" \
        "the displaced merge must be announced" || return 1
    assert_output_not_contains "$output" "/finish fix-auth" "the explicit r choice must not be overridden" || return 1
    assert_output_contains "$output" ".cs/handoffs/2026-07-16-test.md" "the handoff prompt must run instead" || return 1
}

run_test test_finish_yields_to_an_explicit_rotation_choice

test_features_table_says_one_file_not_one_files() {
    # The count comes from git, so 1 is an ordinary value. The TUI and this
    # table must word it identically or the same fact reads two ways.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_not_contains "$output" "1 files" "singular count must not say files" || return 1
    assert_output_contains "$output" "1 file untracked" "expected the singular form" || return 1
}

run_test test_features_table_says_one_file_not_one_files

# --- -integrate-feature --from-remote: land a PR's merge commit ---

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
    local L
    L=$(git -C "$base_dir" rev-parse HEAD)
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$M" HEAD \
        || { echo "  FAIL: the PR merge commit must be reachable from base HEAD"; return 1; }
    git -C "$base_dir" merge-base --is-ancestor "$L" HEAD \
        || { echo "  FAIL: the base's local-only commit must survive the landing"; return 1; }
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

report_results
