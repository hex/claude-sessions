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

# cs's live-duplicate guard scans the whole machine's process table for the
# session name or its UUID. Suites run in parallel and fifteen of them launch a
# session called test-session, so a suite that reads the real `ps` intermittently
# sees a sibling suite's process and reports the session as already running. The
# process table is a shared resource like ~/.claude/projects and the terminal:
# setup() has to isolate it, or the isolation depends on every test author
# remembering the seam.
# The first version of this test called the shared setup() and passed, while two
# dozen suites that define their own setup() went on reading the real ps. A test
# that only proves the invariant where the fix already applies is worse than no
# test: it reports the exposure as closed. Assert the property a suite with its
# own setup() actually gets.
test_process_table_isolation_survives_a_suite_that_overrides_setup() {
    local probe="$TEST_TMPDIR/probe.sh"
    cat > "$probe" <<PROBE
#!/usr/bin/env bash
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/test_lib.sh"
setup() { :; }   # the pattern 24 suites use
setup
[ -n "\${CS_PS_BIN:-}" ] || { echo MISSING; exit 1; }
"\$CS_PS_BIN" -Ao args= | head -1
echo "OK"
PROBE
    chmod +x "$probe"
    local out
    out=$(/bin/bash "$probe" 2>&1) || { echo "  FAIL: probe suite errored: $out"; return 1; }
    case "$out" in
        MISSING*) echo "  FAIL: a suite with its own setup() gets no CS_PS_BIN"; return 1 ;;
        OK) : ;;
        *) echo "  FAIL: the argv scan returned output for an overriding suite: $out"; return 1 ;;
    esac
}

# The stub must not blind the other ps consumers: the lock's ancestry walk and
# presence's pid join read real per-process facts through the same seam.
test_process_table_stub_passes_through_other_ps_forms() {
    local out
    out=$("$CS_PS_BIN" -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')
    case "$out" in
        ''|*[!0-9]*) echo "  FAIL: -o ppid= must return this process's real parent, got '$out'"; return 1 ;;
    esac
}

test_setup_isolates_the_process_table() {
    [ -n "${CS_PS_BIN:-}" ] \
        || { echo "  FAIL: setup() must export CS_PS_BIN so no test reads the real ps"; return 1; }
    [ -x "$CS_PS_BIN" ] \
        || { echo "  FAIL: CS_PS_BIN must point at an executable stub: $CS_PS_BIN"; return 1; }
    local out
    out="$("$CS_PS_BIN" -Ao args= 2>/dev/null)"
    [ -z "$out" ] \
        || { echo "  FAIL: the default ps stub must report no processes, got: $out"; return 1; }
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
run_test test_setup_isolates_the_process_table
run_test test_process_table_isolation_survives_a_suite_that_overrides_setup
run_test test_process_table_stub_passes_through_other_ps_forms

report_results
