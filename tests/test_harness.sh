#!/usr/bin/env bash
# ABOUTME: Tests for the shared assertions in test_lib.sh that every suite uses
# ABOUTME: A broken assertion reports the wrong verdict for every test at once

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Big enough that the writer cannot finish before an early-matching reader
# exits. The pipe buffer is the threshold that matters, not any round number.
big_output() {  # first line
    printf '%s\n' "$1"
    head -c 200000 /dev/zero | tr '\0' 'x' | fold -w 100
}

# ============================================================================
# Tests
# ============================================================================

# A pattern that matches on the FIRST line of a large output is the worst case:
# an early-exiting reader closes the pipe while the writer still has most of the
# payload to push. Piped, the writer dies of SIGPIPE, pipefail promotes 141 to
# the pipeline status, and the assertion reports a match as a failure -- turning
# a passing test red for reasons that have nothing to do with what it tests.
test_output_contains_survives_an_early_match_in_a_large_output() {
    local out
    out="$(big_output MATCH_ON_LINE_ONE)"
    assert_output_contains "$out" "MATCH_ON_LINE_ONE" \
        "an early match in a large output must be reported as a match" || return 1
}

test_output_not_contains_survives_a_large_output() {
    local out
    out="$(big_output MATCH_ON_LINE_ONE)"
    assert_output_not_contains "$out" "PATTERN_THAT_IS_ABSENT" \
        "an absent pattern in a large output must be reported as absent" || return 1
}

# The repair must not have made the assertions unconditionally true: each one
# still has to report the case it exists to catch.
test_output_contains_still_fails_on_a_real_miss() {
    local rc=0
    assert_output_contains "hello" "goodbye" "expected-miss" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "assert_output_contains passed on a genuine miss"; return 1; }
}

test_output_not_contains_still_fails_on_a_real_hit() {
    local rc=0
    assert_output_not_contains "hello" "hello" "expected-hit" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "assert_output_not_contains passed on a genuine hit"; return 1; }
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Test harness assertion tests"
echo "============================"
echo ""

run_test test_output_contains_survives_an_early_match_in_a_large_output
run_test test_output_not_contains_survives_a_large_output
run_test test_output_contains_still_fails_on_a_real_miss
run_test test_output_not_contains_still_fails_on_a_real_hit

report_results
