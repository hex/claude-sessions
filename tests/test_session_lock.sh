#!/usr/bin/env bash
# ABOUTME: Tests for session lock mechanism that prevents concurrent access to the same session
# ABOUTME: Validates lock creation, duplicate prevention, stale lock recovery, and --force override

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to kill background processes and unset session env vars
teardown() {
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true

    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Helper: create a session directory structure without launching claude
create_lock_test_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs/local"
    touch "$session_dir/.cs/local/session.log"
    echo "# test" > "$session_dir/CLAUDE.md"
    # Machine-local state must never be committed, as a real session's .gitignore
    # ensures; otherwise cs_assert_local_untracked refuses to open the session.
    printf '.cs/local/\n' > "$session_dir/.gitignore"
    (cd "$session_dir" && git init -q 2>/dev/null && git add -A 2>/dev/null && git commit -q -m "init" 2>/dev/null) || true
}

# ============================================================================
# Tests
# ============================================================================

test_lock_created_on_launch() {
    cat > "$TEST_TMPDIR/check-lock" << 'SCRIPT'
#!/bin/bash
if [ -f "$CLAUDE_SESSION_META_DIR/session.lock" ]; then
    exit 0
fi
echo "LOCK_NOT_FOUND" >&2
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/check-lock"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/check-lock"

    "$CS_BIN" test-session || {
        echo "  FAIL: Session should launch successfully with lock file created"
        return 1
    }
}

test_lock_prevents_duplicate_session() {
    create_lock_test_session "test-session"

    sleep 300 &
    local live_pid=$!

    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output rc=0
    output=$(echo "n" | "$CS_BIN" test-session 2>&1) || rc=$?

    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [[ "$rc" -eq 0 ]]; then
        echo "  FAIL: Should have failed due to active lock"
        return 1
    fi

    if ! echo "$output" | grep -qi "already open\|in use"; then
        echo "  FAIL: Error should mention session being in use: $output"
        return 1
    fi
}

test_stale_lock_is_reclaimed() {
    create_lock_test_session "test-session"

    local dead_pid
    dead_pid=$(bash -c 'echo $$')

    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 0
    fi

    echo "$dead_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    echo "n" | "$CS_BIN" test-session || {
        echo "  FAIL: Should have succeeded with stale lock"
        return 1
    }
}

test_force_overrides_live_lock() {
    create_lock_test_session "test-session"

    sleep 300 &
    local live_pid=$!

    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local rc=0
    echo "n" | "$CS_BIN" test-session --force || rc=$?

    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [[ "$rc" -ne 0 ]]; then
        echo "  FAIL: --force should override active lock (exit code: $rc)"
        return 1
    fi
}

test_lock_cleaned_on_session_end() {
    create_lock_test_session "test-session"

    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    echo "$$" > "$meta_dir/session.lock"
    assert_exists "$meta_dir/session.lock" "Lock should exist before hook runs" || return 1

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    echo '{"session_id": "test-123"}' | "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_not_exists "$meta_dir/session.lock" "Lock should be cleaned up by session-end hook" || return 1
}

test_lock_contains_valid_pid() {
    cat > "$TEST_TMPDIR/save-lock" << 'SCRIPT'
#!/bin/bash
cat "$CLAUDE_SESSION_META_DIR/session.lock" > "$CLAUDE_SESSION_DIR/.lock-content"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/save-lock"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/save-lock"

    "$CS_BIN" test-session

    local lock_content
    lock_content=$(cat "$CS_SESSIONS_ROOT/test-session/.lock-content" 2>/dev/null || echo "")

    if ! [[ "$lock_content" =~ ^[0-9]+$ ]]; then
        echo "  FAIL: Lock should contain a numeric PID, got: '$lock_content'"
        return 1
    fi
}


test_collision_menu_new_task_creates_worktree() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # Three answers: menu choice, task name, dirty-base consent (the first
    # launch's migration leaves uncommitted backfill in the fixture repo).
    output=$(printf 'n\nfix-auth\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "new-task path should launch cleanly, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/test-session@fix-auth" "worktree session created from the menu" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "original session's lock must be untouched" || return 1
}

test_collision_menu_cancel_is_default() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "EOF should default to cancel and exit cleanly" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "lock untouched on cancel" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session@fix-auth" "no worktree on cancel" || return 1
}

test_collision_menu_force_proceeds() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(printf 'f\nn\n' | CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "force path should launch, got: $output" || return 1
    assert_output_contains "$output" "Overriding active session lock" "force warning shown" || return 1
}

test_collision_menu_on_worktree_session_offers_no_new_task() {
    create_lock_test_session "test-session"
    "$CS_BIN" "test-session@t1" < /dev/null > /dev/null 2>&1 || true
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session@t1/.cs/session.lock"

    local output status=0
    output=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" "test-session@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "worktree collision exits cleanly" || return 1
    assert_output_not_contains "$output" "parallel task" "no new-task option for a worktree session" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session@t1@n" "no nested worktree possible" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Session lock tests"
echo "=================="
echo ""

run_test test_lock_created_on_launch
run_test test_lock_prevents_duplicate_session
run_test test_stale_lock_is_reclaimed
run_test test_force_overrides_live_lock
run_test test_lock_cleaned_on_session_end
run_test test_lock_contains_valid_pid
run_test test_collision_menu_new_task_creates_worktree
run_test test_collision_menu_cancel_is_default
run_test test_collision_menu_force_proceeds
run_test test_collision_menu_on_worktree_session_offers_no_new_task

report_results
