#!/usr/bin/env bash
# ABOUTME: Tests for run_all.sh, the aggregating gate that runs every suite
# ABOUTME: Pins shard coverage, failure reporting, and per-suite output capture

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

RUN_ALL="$SCRIPT_DIR/run_all.sh"

# Build a directory of fake suites for run_all.sh to drive. Each records the
# fact that it ran by creating a file named after itself, so coverage is counted
# from the filesystem rather than from parsing the runner's own output. Suites
# write distinct files, never a shared one, so concurrent shards cannot lose a
# record to an interleaved append. Arg: how many suites; a name passed after it
# is made to fail.
make_suite_dir() {  # count, [failing_name]
    local count="$1" failing="${2:-}" i name
    SUITE_DIR="$TEST_TMPDIR/suites"
    RAN_DIR="$TEST_TMPDIR/ran"
    mkdir -p "$SUITE_DIR" "$RAN_DIR"
    i=1
    while [ "$i" -le "$count" ]; do
        name="test_fake$i.sh"
        {
            printf '#!/usr/bin/env bash\n'
            printf 'printf "marker-from-%s\\n"\n' "$name"
            printf ': > "%s/%s"\n' "$RAN_DIR" "$name"
            if [ "$name" = "$failing" ]; then
                printf 'exit 1\n'
            fi
        } > "$SUITE_DIR/$name"
        i=$((i + 1))
    done
    # test_lib.sh is the shared harness, not a suite: the runner must skip it
    # even when it is sitting in the same directory.
    printf '#!/usr/bin/env bash\nexit 3\n' > "$SUITE_DIR/test_lib.sh"
}

ran_count() { ls -1 "$RAN_DIR" 2>/dev/null | grep -c . ; }

# ============================================================================
# Tests
# ============================================================================

test_run_all_runs_every_suite_exactly_once() {
    make_suite_dir 7
    local out rc=0
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected exit 0, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 7 ] || { echo "expected 7 suites to run, got $(ran_count)"; return 1; }
    printf '%s' "$out" | grep -q 'all 7 suites passed' || { echo "missing pass line"; printf '%s\n' "$out"; return 1; }
}

test_run_all_skips_the_shared_harness() {
    make_suite_dir 3
    local out
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || return 1
    [ ! -f "$RAN_DIR/test_lib.sh" ] || { echo "test_lib.sh was run as a suite"; return 1; }
    printf '%s' "$out" | grep -q 'all 3 suites passed' || { echo "harness counted as a suite"; return 1; }
}

test_run_all_serial_mode_runs_every_suite() {
    make_suite_dir 7
    local out rc=0
    out=$(CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected exit 0, got $rc"; return 1; }
    [ "$(ran_count)" -eq 7 ] || { echo "serial run covered $(ran_count)/7"; return 1; }
}

test_run_all_reports_the_failing_suite_by_name() {
    make_suite_dir 5 test_fake3.sh
    local out rc=0
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || { echo "expected exit 1 for a failing suite, got $rc"; return 1; }
    printf '%s' "$out" | grep -q 'test_fake3.sh' || { echo "failing suite not named"; printf '%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -q 'FAILED: 1/5' || { echo "wrong failure tally"; printf '%s\n' "$out"; return 1; }
    # A failure must not stop the other suites: the gate reports every failure
    # in one run rather than making the developer re-run to find the next.
    [ "$(ran_count)" -eq 5 ] || { echo "a failing suite cut the run short at $(ran_count)/5"; return 1; }
}

test_run_all_keeps_each_suites_own_output() {
    make_suite_dir 6
    local out
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || return 1
    local i
    for i in 1 2 3 4 5 6; do
        printf '%s' "$out" | grep -q "marker-from-test_fake$i.sh" \
            || { echo "lost output of test_fake$i.sh"; printf '%s\n' "$out"; return 1; }
        printf '%s' "$out" | grep -q "=== test_fake$i.sh ===" \
            || { echo "lost header of test_fake$i.sh"; return 1; }
    done
}

# A shard runs a disjoint slice, and the slices together cover every suite once.
# Pinned directly because CI drives lanes this way and a silent overlap would
# show as a green run that tested some suites twice and others never.
test_run_all_shards_partition_the_suite_list() {
    make_suite_dir 7
    local n out
    for n in 1 2 3; do
        out=$(CS_TEST_SHARD="$n/3" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || {
            echo "shard $n/3 failed"; printf '%s\n' "$out"; return 1; }
    done
    [ "$(ran_count)" -eq 7 ] || { echo "3 shards covered $(ran_count)/7 suites"; return 1; }
}

test_run_all_rejects_a_malformed_shard() {
    make_suite_dir 2
    local rc=0
    CS_TEST_SHARD="4/2" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "expected exit 2 for shard 4/2, got $rc"; return 1; }
    rc=0
    CS_TEST_SHARD="x/2" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "expected exit 2 for shard x/2, got $rc"; return 1; }
}

test_run_all_rejects_a_malformed_job_count() {
    make_suite_dir 2
    local rc=0
    CS_TEST_JOBS=0 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "expected exit 2 for CS_TEST_JOBS=0, got $rc"; return 1; }
    rc=0
    CS_TEST_JOBS=nope CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "expected exit 2 for CS_TEST_JOBS=nope, got $rc"; return 1; }
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Test gate runner tests"
echo "======================"
echo ""

run_test test_run_all_runs_every_suite_exactly_once
run_test test_run_all_skips_the_shared_harness
run_test test_run_all_serial_mode_runs_every_suite
run_test test_run_all_reports_the_failing_suite_by_name
run_test test_run_all_keeps_each_suites_own_output
run_test test_run_all_shards_partition_the_suite_list
run_test test_run_all_rejects_a_malformed_shard
run_test test_run_all_rejects_a_malformed_job_count

report_results
