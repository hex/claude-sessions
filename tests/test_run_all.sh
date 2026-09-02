#!/usr/bin/env bash
# ABOUTME: Tests for run_all.sh, the aggregating gate that runs every suite
# ABOUTME: Pins shard coverage, failure reporting, and per-suite output capture

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

RUN_ALL="$SCRIPT_DIR/run_all.sh"

# These tests spawn run_all.sh, which reads both of these from the environment,
# and the outer gate launches suites with a plain `bash` that passes its own
# environment straight through. Left ambient, a sharded CI lane would make this
# suite shard its own FIXTURES -- so the one suite that tests sharding is the
# one that fails, on healthy code, exactly when the feature is in use. Each test
# sets what it needs explicitly.
unset CS_TEST_SHARD CS_TEST_JOBS 2>/dev/null || true

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

# Put a fake core count in front of run_all's detection. It reads `sysctl -n
# hw.ncpu` first and falls back to `nproc`, so both are shimmed: the Linux lane
# never reaches sysctl and the macOS lane never reaches nproc.
fake_cores() {  # count
    local n="$1" d="$TEST_TMPDIR/fakebin"
    mkdir -p "$d"
    printf '#!/usr/bin/env bash\nprintf %s\n' "$n" > "$d/sysctl"
    printf '#!/usr/bin/env bash\nprintf %s\n' "$n" > "$d/nproc"
    chmod +x "$d/sysctl" "$d/nproc"
    printf '%s' "$d"
}

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

# A gate that cannot create its scratch dir must fail, not pass. Every suite is
# launched with its output redirected into that dir, so an empty path makes the
# redirection fail, which makes bash abandon the command -- the suite never runs
# at all. Reporting "all N suites passed" there is the worst possible answer: a
# release gate goes green having executed nothing.
test_run_all_fails_loudly_when_the_log_dir_cannot_be_made() {
    make_suite_dir 3
    local stub="$TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/mktemp"
    chmod +x "$stub/mktemp"
    local out rc=0
    out=$(PATH="$stub:$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "exited 0 with no usable log dir"; printf '%s\n' "$out"; return 1; }
    if printf '%s' "$out" | grep -q 'suites passed'; then
        echo "claimed suites passed while running none"; printf '%s\n' "$out"; return 1
    fi
    [ "$(ran_count)" -eq 0 ] || { echo "expected no suite to have run"; return 1; }
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

# The auto-detected job count has to track the machine. Measured against the
# real suite list, a 14-core box finishes in 2.2 minutes at ten lanes against
# 5.0 at four, because the total suite time far exceeds the slowest single
# suite and lanes sit idle. Asserted as a range, not as the ceiling's value: a
# test that restates the constant passes no matter what the constant is.
test_run_all_scales_jobs_with_the_core_count() {
    make_suite_dir 2
    local out
    out=$(PATH="$(fake_cores 16):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    local n
    n=$(printf '%s' "$out" | sed -n 's/.*at \([0-9][0-9]*\) jobs.*/\1/p' | head -1)
    [ -n "$n" ] || { echo "runner did not announce its job count"; printf '%s\n' "$out"; return 1; }
    [ "$n" -gt 4 ] || { echo "16 cores must buy more than 4 lanes, got $n"; return 1; }
}

# The ceiling must not become a floor: a small CI runner keeps its own core
# count rather than being oversubscribed up to the cap.
test_run_all_does_not_oversubscribe_a_small_runner() {
    make_suite_dir 2
    local out n
    out=$(PATH="$(fake_cores 2):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    n=$(printf '%s' "$out" | sed -n 's/.*at \([0-9][0-9]*\) jobs.*/\1/p' | head -1)
    [ "$n" -eq 2 ] || { echo "a 2-core runner must use 2 lanes, got $n"; printf '%s\n' "$out"; return 1; }
}

# A gate that takes minutes says nothing between its opening line and its
# report, so a slow run reads like a hung one. Each suite prints one line to
# stderr the moment it finishes: its position, its name, its seconds. The
# replayed report stays as it was.
test_run_all_reports_each_suite_as_it_finishes() {
    make_suite_dir 4
    local err
    err=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1 >/dev/null)
    local i
    for i in 1 2 3 4; do
        printf '%s' "$err" | grep -q "test_fake$i.sh" \
            || { echo "no progress line for test_fake$i.sh"; printf '%s\n' "$err"; return 1; }
    done
    printf '%s' "$err" | grep -Eq '\[[1-4]/4\] test_fake[1-4]\.sh .*[0-9]+s' \
        || { echo "progress line must carry [n/total], the name and seconds"; printf '%s\n' "$err"; return 1; }
    printf '%s' "$err" | grep -q '\[4/4\]' \
        || { echo "the counter must reach the total"; printf '%s\n' "$err"; return 1; }
}

test_run_all_progress_line_marks_a_failing_suite() {
    make_suite_dir 3 test_fake2.sh
    local err
    err=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1 >/dev/null) || true
    printf '%s' "$err" | grep -E 'test_fake2\.sh' | grep -q 'FAIL' \
        || { echo "a failing suite's progress line must say FAIL"; printf '%s\n' "$err"; return 1; }
    printf '%s' "$err" | grep -E 'test_fake1\.sh' | grep -q 'FAIL' \
        && { echo "a passing suite's progress line must not say FAIL"; return 1; }
    return 0
}

# The report ends with the suites ranked by wall time, so the slow ones have a
# name instead of a feeling.
test_run_all_report_lists_slowest_suites() {
    make_suite_dir 3
    local out
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>/dev/null)
    printf '%s' "$out" | grep -q 'slowest' \
        || { echo "report has no slowest-suites table"; printf '%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -Eq '[0-9]+s +test_fake[1-3]\.sh' \
        || { echo "table rows must be '<seconds>s <suite>'"; printf '%s\n' "$out"; return 1; }
}

# Serial mode streams live and has no lanes, but the same three facts still
# matter: it prints the same progress line after each suite.
test_run_all_serial_mode_also_reports_progress() {
    make_suite_dir 2
    local err
    err=$(CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1 >/dev/null)
    printf '%s' "$err" | grep -q '\[2/2\] test_fake2\.sh' \
        || { echo "serial mode must print the progress line too"; printf '%s\n' "$err"; return 1; }
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
run_test test_run_all_fails_loudly_when_the_log_dir_cannot_be_made
run_test test_run_all_rejects_a_malformed_shard
run_test test_run_all_rejects_a_malformed_job_count
run_test test_run_all_scales_jobs_with_the_core_count
run_test test_run_all_does_not_oversubscribe_a_small_runner
run_test test_run_all_reports_each_suite_as_it_finishes
run_test test_run_all_progress_line_marks_a_failing_suite
run_test test_run_all_report_lists_slowest_suites
run_test test_run_all_serial_mode_also_reports_progress

report_results
