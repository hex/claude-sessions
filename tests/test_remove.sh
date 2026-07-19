#!/usr/bin/env bash
# ABOUTME: Tests for cs -remove/-rm: multi-name removal, per-name confirms,
# ABOUTME: fail-fast on unknown names, and the usage error with no name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

test_remove_multiple_names_each_confirmed() {
    create_test_session r1 >/dev/null
    create_test_session r2 >/dev/null
    printf 'y\ny\n' | "$CS_BIN" -rm r1 r2 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r1" ] || { echo "  r1 survived"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r2" ] || { echo "  r2 survived"; return 1; }
}

test_remove_decline_skips_that_session_only() {
    create_test_session r3 >/dev/null
    create_test_session r4 >/dev/null
    printf 'n\ny\n' | "$CS_BIN" -rm r3 r4 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r3" ] || { echo "  declined r3 was removed"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r4" ] || { echo "  r4 survived"; return 1; }
}

test_remove_single_name_still_works() {
    create_test_session r5 >/dev/null
    printf 'y\n' | "$CS_BIN" -rm r5 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r5" ] || { echo "  r5 survived"; return 1; }
}

test_remove_no_name_errors() {
    ! "$CS_BIN" -rm >/dev/null 2>&1 || return 1
}

test_remove_unknown_name_fails_fast() {
    create_test_session r6 >/dev/null
    ! printf 'y\n' | "$CS_BIN" -rm nosuch r6 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r6" ] || { echo "  fail-fast still removed a later name"; return 1; }
}

test_remove_empty_name_rejected_before_any_deletion() {
    create_test_session r7 >/dev/null
    ! printf 'y\ny\n' | "$CS_BIN" -rm r7 "" >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT" ] || { echo "  sessions root deleted"; return 1; }
    [ -d "$CS_SESSIONS_ROOT/r7" ] || { echo "  r7 removed despite invalid list"; return 1; }
    ! "$CS_BIN" -rm "" >/dev/null 2>&1 || return 1
}

test_remove_refuses_live_session_without_force() {
    create_test_session live1 >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/live1/.cs/session.lock"

    local out rc=0
    out=$(printf 'y\n' | "$CS_BIN" -rm live1 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: live session must refuse removal without --force"
        return 1
    fi
    assert_output_contains "$out" "--force" "refusal names the override" || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; return 1; }
    [ -d "$CS_SESSIONS_ROOT/live1" ] || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: refused removal still deleted the session"; return 1; }

    printf 'y\n' | "$CS_BIN" -rm live1 --force >/dev/null 2>&1
    rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    [ "$rc" -eq 0 ] || { echo "  FAIL: --force should remove a live session"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/live1" ] || { echo "  FAIL: --force did not remove"; return 1; }
}

run_test test_remove_empty_name_rejected_before_any_deletion
run_test test_remove_refuses_live_session_without_force
run_test test_remove_multiple_names_each_confirmed
run_test test_remove_decline_skips_that_session_only
run_test test_remove_single_name_still_works
run_test test_remove_no_name_errors
run_test test_remove_unknown_name_fails_fast

report_results
