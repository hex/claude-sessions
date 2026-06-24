#!/usr/bin/env bash
# ABOUTME: Guards that the removed sync/remote subsystem stays gone
# ABOUTME: cs -sync/-remote and session --on/--move-to must error, not dispatch

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

test_sync_global_command_removed() {
    local out ec
    out=$("$CS_BIN" -sync 2>&1); ec=$?
    [ "$ec" -ne 0 ] || { echo "  FAIL: 'cs -sync' should exit non-zero"; return 1; }
    assert_output_contains "$out" "Unknown command" "'cs -sync' must report an unknown command" || return 1
}

test_remote_global_command_removed() {
    local out ec
    out=$("$CS_BIN" -remote 2>&1); ec=$?
    [ "$ec" -ne 0 ] || { echo "  FAIL: 'cs -remote' should exit non-zero"; return 1; }
    assert_output_contains "$out" "Unknown command" "'cs -remote' must report an unknown command" || return 1
}

test_session_on_flag_removed() {
    local out ec
    out=$("$CS_BIN" demo --on somehost 2>&1); ec=$?
    [ "$ec" -ne 0 ] || { echo "  FAIL: 'cs <name> --on' should exit non-zero"; return 1; }
    assert_output_contains "$out" "Unknown session command" "'--on' must be an unknown session command" || return 1
}

test_session_move_to_flag_removed() {
    local out ec
    out=$("$CS_BIN" demo --move-to somehost 2>&1); ec=$?
    [ "$ec" -ne 0 ] || { echo "  FAIL: 'cs <name> --move-to' should exit non-zero"; return 1; }
    assert_output_contains "$out" "Unknown session command" "'--move-to' must be an unknown session command" || return 1
}

test_help_has_no_sync_or_remote() {
    local out
    out=$("$CS_BIN" -help 2>&1)
    assert_output_not_contains "$out" "-sync" "help must not mention -sync" || return 1
    assert_output_not_contains "$out" "Remote Commands" "help must not list Remote Commands" || return 1
    assert_output_not_contains "$out" "Sync Commands" "help must not list Sync Commands" || return 1
}

echo ""
echo "cs sync/remote removal guards"
echo "============================="
echo ""

run_test test_sync_global_command_removed
run_test test_remote_global_command_removed
run_test test_session_on_flag_removed
run_test test_session_move_to_flag_removed
run_test test_help_has_no_sync_or_remote

report_results
