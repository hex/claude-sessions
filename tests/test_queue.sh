#!/usr/bin/env bash
# ABOUTME: Tests for the cs -queue verb and the Stop-hook drain.
# ABOUTME: Covers add/list/rm/clear/start/defer and the outside-a-session error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

QFILE() { printf '%s' "$CLAUDE_SESSION_META_DIR/local/queue"; }

test_queue_add_appends_a_line() {
    "$CS_BIN" -queue add "first task" >/dev/null 2>&1
    "$CS_BIN" -queue add "second task" >/dev/null 2>&1
    assert_file_contains "$(QFILE)" "first task" "add writes the task" || return 1
    assert_eq "2" "$(grep -c . "$(QFILE)")" "two tasks queued" || return 1
}

test_queue_list_numbers_pending() {
    "$CS_BIN" -queue add "alpha" >/dev/null 2>&1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "1" "list is numbered" || return 1
    assert_output_contains "$out" "alpha" "list shows the task" || return 1
}

test_queue_rm_removes_by_index() {
    "$CS_BIN" -queue add "keep" >/dev/null 2>&1
    "$CS_BIN" -queue add "drop" >/dev/null 2>&1
    "$CS_BIN" -queue rm 2 >/dev/null 2>&1
    assert_file_contains "$(QFILE)" "keep" "kept task remains" || return 1
    assert_file_not_contains "$(QFILE)" "drop" "removed task is gone" || return 1
}

test_queue_clear_empties_and_resets_state() {
    "$CS_BIN" -queue add "x" >/dev/null 2>&1
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    "$CS_BIN" -queue clear >/dev/null 2>&1
    assert_file_not_exists "$(QFILE)" "queue file removed" || return 1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.state" "state reset" || return 1
}

test_queue_start_sets_armed() {
    "$CS_BIN" -queue start >/dev/null 2>&1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/queue.state" "armed" "start arms" || return 1
}

test_queue_defer_writes_declined_epoch() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "defer stamps declined" || return 1
}

test_queue_add_clears_declined() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    "$CS_BIN" -queue add "new" >/dev/null 2>&1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "add re-enables gating" || return 1
}

test_queue_requires_session() {
    unset CLAUDE_SESSION_META_DIR
    local out; if out=$("$CS_BIN" -queue add "x" 2>&1); then
        echo "  FAIL: expected non-zero outside a session"; return 1
    fi
    assert_output_contains "$out" "session" "explains it needs a session" || return 1
}

run_test test_queue_add_appends_a_line
run_test test_queue_list_numbers_pending
run_test test_queue_rm_removes_by_index
run_test test_queue_clear_empties_and_resets_state
run_test test_queue_start_sets_armed
run_test test_queue_defer_writes_declined_epoch
run_test test_queue_add_clears_declined
run_test test_queue_requires_session
report_results
