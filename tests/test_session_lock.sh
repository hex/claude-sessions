#!/usr/bin/env bash
# ABOUTME: Tests for session lock mechanism that prevents concurrent access to the same session
# ABOUTME: Validates lock creation, duplicate prevention, stale lock recovery, and --force override

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CS_BIN="$SCRIPT_DIR/../bin/cs"
TEST_TMPDIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"  # Stub out claude so it doesn't launch
    mkdir -p "$CS_SESSIONS_ROOT"
}

teardown() {
    # Kill any leftover background processes from tests
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true

    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [ ! -e "$path" ]; then
        echo "  FAIL: $msg (path does not exist: $path)"
        return 1
    fi
}

assert_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [ -e "$path" ]; then
        echo "  FAIL: $msg (path exists: $path)"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    setup
    if "$test_name" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
    teardown
}

# Helper: create a session directory structure without launching claude
create_test_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    touch "$session_dir/.cs/logs/session.log"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    echo "# test" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q 2>/dev/null && git add -A 2>/dev/null && git commit -q -m "init" 2>/dev/null) || true
}

# ============================================================================
# Tests
# ============================================================================

test_lock_created_on_launch() {
    # Use a custom CLAUDE_CODE_BIN that verifies the lock file exists during session
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

    # Launch a new session - the checker script runs in place of claude
    "$CS_BIN" test-session || {
        echo "  FAIL: Session should launch successfully with lock file created"
        return 1
    }
}

test_lock_prevents_duplicate_session() {
    create_test_session "test-session"

    # Start a background process to provide a live PID
    sleep 300 &
    local live_pid=$!

    # Write lock with the live PID
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    # Try to launch - should fail due to active lock
    local output rc=0
    output=$(echo "n" | "$CS_BIN" test-session 2>&1) || rc=$?

    # Clean up background process
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: Should have failed due to active lock"
        return 1
    fi

    if ! echo "$output" | grep -qi "already open\|in use"; then
        echo "  FAIL: Error should mention session being in use: $output"
        return 1
    fi
}

test_stale_lock_is_reclaimed() {
    create_test_session "test-session"

    # Get a guaranteed dead PID (the subshell exits immediately)
    local dead_pid
    dead_pid=$(bash -c 'echo $$')

    # Verify it's actually dead
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 0
    fi

    # Write lock with dead PID
    echo "$dead_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    # Launch should succeed (stale lock reclaimed)
    echo "n" | "$CS_BIN" test-session || {
        echo "  FAIL: Should have succeeded with stale lock"
        return 1
    }
}

test_force_overrides_live_lock() {
    create_test_session "test-session"

    # Start a background process to provide a live PID
    sleep 300 &
    local live_pid=$!

    # Write lock with the live PID
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    # Launch with --force should succeed despite active lock
    local rc=0
    echo "n" | "$CS_BIN" test-session --force || rc=$?

    # Clean up background process
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: --force should override active lock (exit code: $rc)"
        return 1
    fi
}

test_lock_cleaned_on_session_end() {
    create_test_session "test-session"

    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    # Write a lock file
    echo "$$" > "$meta_dir/session.lock"
    assert_exists "$meta_dir/session.lock" "Lock should exist before hook runs" || return 1

    # Run session-end hook
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"
    export CLAUDE_ARTIFACT_DIR="$meta_dir/artifacts"

    echo '{"session_id": "test-123"}' | "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_not_exists "$meta_dir/session.lock" "Lock should be cleaned up by session-end hook" || return 1
}

test_lock_contains_valid_pid() {
    # Use a custom CLAUDE_CODE_BIN that saves the lock content for inspection
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

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo ""
