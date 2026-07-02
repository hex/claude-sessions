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

# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' > "$base_dir/.cs/local/state"
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

test_worktree_create_succeeds_with_untracked_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "stray" > "$base_dir/stray.txt"   # untracked, must not corrupt the captured path
    local output status=0
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "cs must exit 0 despite the untracked-files warning"
    assert_output_not_contains "$output" "No such file" \
        "captured worktree path must not be corrupted by the warning"
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree created"
}

test_worktree_reopen_preserves_project_claude_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,artifacts,logs,local}
    echo "[]" > "$base_dir/.cs/artifacts/MANIFEST.json"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    cs_launch "proj@task1"   # reopen — the path that used to run migrate_session
    assert_eq "# Project CLAUDE.md" "$(cat "$CS_SESSIONS_ROOT/proj@task1/CLAUDE.md")" \
        "reopen must not rewrite the project's CLAUDE.md"
}

test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out
    stub=$(_make_env_stub)
    env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" <<< "n" 2>/dev/null || true)
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name"
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj" "task list is shared with the base"
    assert_output_not_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj@" "task list id must be the base, not the worktree name"
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base"
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_plain_names_still_work
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_worktree_of_worktree_refused
run_test test_worktree_create_succeeds_with_untracked_base
run_test test_worktree_reopen_preserves_project_claude_md
run_test test_worktree_launch_exports_base_identity
report_results
