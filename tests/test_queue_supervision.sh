#!/usr/bin/env bash
# ABOUTME: Tests for walk-away queue supervision: the failure counter, circuit
# ABOUTME: breakers at the drain choke point, the notification inbox, and digest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + exported ambient env, the shape the hooks expect.
_qs_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
}

_fail_once() {  # simulate one tool failure through the real hook
    echo '{"tool_name":"Bash","error":"boom"}' | bash "$HOOKS_DIR/tool-failure-logger.sh"
}

test_failure_counter_increments() {
    _qs_session "fc"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "first failure counts" || return 1
    _fail_once || return 1
    _fail_once || return 1
    assert_eq "3" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "count accumulates" || return 1
}

test_failure_counter_recovers_from_garbage() {
    _qs_session "fcg"
    printf 'not-a-number\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "garbage reads as 0, then increments" || return 1
}

test_failure_counter_still_logs_to_session_log() {
    _qs_session "fcl"
    _fail_once || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" "existing log behavior preserved" || return 1
}

run_test test_failure_counter_increments
run_test test_failure_counter_recovers_from_garbage
run_test test_failure_counter_still_logs_to_session_log
report_results
