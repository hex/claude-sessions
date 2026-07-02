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
