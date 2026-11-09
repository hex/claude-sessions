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
# fact that it ran by appending a line to a file named after itself, so coverage
# is counted from the filesystem rather than from parsing the runner's own
# output, and a suite that ran twice shows two lines. Suites write distinct
# files, never a shared one, so concurrent shards cannot lose a record to an
# interleaved append. Arg: how many suites; a name passed after it is made to
# fail.
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
            printf 'echo ran >> "%s/%s"\n' "$RAN_DIR" "$name"
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


# Turn fake suite N into one that never finishes on its own: it waits on a
# helper shell that waits on a long sleep, the way a suite hangs on a
# grandchild (test subshell, cs, tmux) that never returns. The sleep's pid is
# recorded where the test can check it afterwards. With "ignore-term" the
# suite also ignores TERM.
make_suite_hang() {  # n, [ignore-term]
    local name="test_fake$1.sh"
    {
        printf '#!/usr/bin/env bash\n'
        [ "${2:-}" = ignore-term ] && printf "trap '' TERM\n"
        printf 'bash -c '"'"'sleep 40 & printf "%%s\\n" "$!" > "%s/hung.pid"; wait'"'"' &\n' "$TEST_TMPDIR"
        printf 'wait\n'
    } > "$SUITE_DIR/$name"
}

# A suite built on the real test_lib.sh, so its skips reach the gate the way a
# real suite's do. Each body line is bash source for the suite; its run_test
# lines decide which tests run.
make_lib_suite() {  # name, body
    mkdir -p "$SUITE_DIR"
    {
        printf 'SCRIPT_DIR=%q\n' "$SCRIPT_DIR"
        printf 'source %q\n' "$SCRIPT_DIR/test_lib.sh"
        printf '%s\n' "$2"
        printf 'report_results\n'
    } > "$SUITE_DIR/$1"
}

# A tool no machine has, so "not on PATH" never depends on the host.
ABSENT_TOOL=cs-run-all-absent-tool

# ============================================================================
# Tests
# ============================================================================

test_run_all_runs_every_suite_exactly_once() {
    make_suite_dir 7
    local out rc=0
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected exit 0, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 7 ] || { echo "expected 7 suites to run, got $(ran_count)"; return 1; }
    grep -q 'all 7 suites passed' <<< "$out" || { echo "missing pass line"; printf '%s\n' "$out"; return 1; }
}

test_run_all_skips_the_shared_harness() {
    make_suite_dir 3
    local out
    # Pin the lanes. Unset, the nested runner reads the host's core count, so
    # this asserted the developer's machine: 8 lanes on a many-core box, nested
    # inside the outer gate's own lanes, and one suite's log came back empty.
    # Three still exercises interleaved collection, and does it the same way
    # everywhere.
    out=$(CS_TEST_JOBS=3 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || return 1
    [ ! -f "$RAN_DIR/test_lib.sh" ] || { echo "test_lib.sh was run as a suite"; return 1; }
    grep -q 'all 3 suites passed' <<< "$out" || { echo "harness counted as a suite"; return 1; }
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
    grep -q 'test_fake3.sh' <<< "$out" || { echo "failing suite not named"; printf '%s\n' "$out"; return 1; }
    grep -q 'FAILED: 1/5' <<< "$out" || { echo "wrong failure tally"; printf '%s\n' "$out"; return 1; }
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
        grep -q "marker-from-test_fake$i.sh" <<< "$out" \
            || { echo "lost output of test_fake$i.sh"; printf '%s\n' "$out"; return 1; }
        grep -q "=== test_fake$i.sh ===" <<< "$out" \
            || { echo "lost header of test_fake$i.sh"; return 1; }
    done
}

# A skip passes the gate, so the gate has to say it happened: CI's last lines
# name each skipped test, its suite and, for a missing tool, the tool, and the
# verdict counts them. Serial runs keep no log, so this holds in both modes.
test_run_all_names_every_skipped_test_and_counts_them() {
    SUITE_DIR="$TEST_TMPDIR/suites"
    make_lib_suite test_alpha.sh "test_needs_it() { require_tool $ABSENT_TOOL || return \$?; }
test_odd_platform() { echo '    SKIP: not on this platform'; return 77; }
test_ok() { return 0; }
run_test test_needs_it
run_test test_odd_platform
run_test test_ok"
    make_lib_suite test_beta.sh "test_ok() { return 0; }
run_test test_ok"
    local jobs out rc want
    want="$(printf '%s\n' \
        "skipped tests:" \
        "  test_alpha.sh: test_needs_it ($ABSENT_TOOL not on PATH)" \
        "  test_alpha.sh: test_odd_platform" \
        "" \
        "================================================================" \
        "OK: all 2 suites passed, 2 tests skipped")"
    for jobs in 2 1; do
        rc=0
        out=$(env -u CS_TEST_REQUIRE_TOOLS CS_TEST_JOBS=$jobs CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>/dev/null) || rc=$?
        assert_eq "0" "$rc" "skips alone pass the gate at $jobs jobs: $out" || return 1
        assert_eq "$want" "$(printf '%s\n' "$out" | tail -6)" "the summary at $jobs jobs" || return 1
    done
}

test_run_all_verdict_line_is_bare_when_nothing_skipped() {
    SUITE_DIR="$TEST_TMPDIR/suites"
    make_lib_suite test_alpha.sh "test_ok() { return 0; }
run_test test_ok"
    local out
    out=$(CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>/dev/null) || return 1
    assert_eq "OK: all 1 suites passed" "$(printf '%s\n' "$out" | tail -1)" "no skip count without a skip" || return 1
    assert_output_not_contains "$out" "skipped tests:" "no skip list without a skip" || return 1
}

test_run_all_names_skips_beside_a_failure() {
    SUITE_DIR="$TEST_TMPDIR/suites"
    make_lib_suite test_alpha.sh "test_needs_it() { require_tool $ABSENT_TOOL || return \$?; }
run_test test_needs_it"
    make_lib_suite test_beta.sh "test_broken() { return 1; }
run_test test_broken"
    local out rc=0 want
    out=$(env -u CS_TEST_REQUIRE_TOOLS CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>/dev/null) || rc=$?
    assert_eq "1" "$rc" "a failing suite still fails the gate" || return 1
    want="$(printf '%s\n' \
        "skipped tests:" \
        "  test_alpha.sh: test_needs_it ($ABSENT_TOOL not on PATH)" \
        "" \
        "================================================================" \
        "FAILED: 1/2 suites, 1 test skipped" \
        "  - test_beta.sh")"
    assert_eq "$want" "$(printf '%s\n' "$out" | tail -6)" "the summary of a failed run" || return 1
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
    local f
    for f in "$RAN_DIR"/*; do
        [ "$(grep -c . "$f")" = 1 ] || { echo "${f##*/} ran $(grep -c . "$f") times over the 3 shards"; return 1; }
    done
}

# The split itself, on suites of 10, 6, 5 and 1 lines: longest first, each to
# the shard with fewer lines so far, the lower shard on a tie. 10 goes to shard
# 1, 6 to shard 2, 5 to shard 2 (6 < 10), 1 to shard 1 (10 < 11). Balancing by
# count, or breaking the first tie toward shard 2, picks other sets.
test_run_all_shards_balance_by_line_count() {
    make_suite_dir 4
    local n i lines
    for n in 1 2 3 4; do
        case "$n" in 1) lines=10 ;; 2) lines=6 ;; 3) lines=5 ;; 4) lines=1 ;; esac
        {
            printf 'echo ran >> "%s/test_fake%s.sh"\n' "$RAN_DIR" "$n"
            i=1
            while [ "$i" -lt "$lines" ]; do printf '# pad\n'; i=$((i + 1)); done
        } > "$SUITE_DIR/test_fake$n.sh"
    done
    local out got
    out=$(CS_TEST_SHARD=1/2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || {
        echo "shard 1/2 failed"; printf '%s\n' "$out"; return 1; }
    got=$(ls -1 "$RAN_DIR" | tr '\n' ' ')
    [ "$got" = "test_fake1.sh test_fake4.sh " ] || { echo "shard 1/2 ran: $got"; return 1; }
}

# A suite that runs long for its length says so with a `# run_all-weight: N`
# line, and counts as N times its lines. Suites of 10, 6, 4 and 1 lines, the
# 4-line one weighted 3 (12): 12 goes to shard 1, 10 to shard 2, 6 to shard 2
# (10 < 12), 1 to shard 1 (12 < 16). Unweighted, shard 1 runs 10 and 1.
test_run_all_shards_count_a_declared_weight() {
    make_suite_dir 4
    local n i lines
    for n in 1 2 3 4; do
        case "$n" in 1) lines=10 ;; 2) lines=6 ;; 3) lines=4 ;; 4) lines=1 ;; esac
        {
            printf 'echo ran >> "%s/test_fake%s.sh"\n' "$RAN_DIR" "$n"
            i=1
            if [ "$n" = 3 ]; then printf '# run_all-weight: 3\n'; i=2; fi
            while [ "$i" -lt "$lines" ]; do printf '# pad\n'; i=$((i + 1)); done
        } > "$SUITE_DIR/test_fake$n.sh"
    done
    local out got
    out=$(CS_TEST_SHARD=1/2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || {
        echo "shard 1/2 failed"; printf '%s\n' "$out"; return 1; }
    got=$(ls -1 "$RAN_DIR" | tr '\n' ' ')
    [ "$got" = "test_fake3.sh test_fake4.sh " ] || { echo "shard 1/2 ran: $got"; return 1; }
}

# A suite file the gate cannot read is an error, not a suite to leave out: it
# has no line count to place it by, and quietly dropping it from every shard
# would report a green gate that never ran it.
test_run_all_refuses_an_unreadable_suite() {
    make_suite_dir 3
    chmod 000 "$SUITE_DIR/test_fake2.sh"
    local out rc=0
    out=$(CS_TEST_SHARD=1/2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    chmod 644 "$SUITE_DIR/test_fake2.sh"
    [ "$rc" -eq 2 ] || { echo "expected exit 2, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$out" = "cannot read $SUITE_DIR/test_fake2.sh" ] || { echo "unexpected output:"; printf '%s\n' "$out"; return 1; }
}

# A lane that finishes takes the next waiting suite, so no lane sits idle while
# another works through a fixed share. Pinned with a suite that cannot finish
# until every other suite has run: with two lanes it holds one lane, and only a
# shared queue lets the other lane reach the remaining four. A fixed split puts
# two of them behind it on its own lane, and it gives up after 120 s of wall
# time, which a loaded machine starting the other four late stays well inside.
test_run_all_a_free_lane_takes_the_next_suite() {
    make_suite_dir 5
    cat > "$SUITE_DIR/test_fake1.sh" <<EOF
#!/usr/bin/env bash
deadline=\$((SECONDS + 120))
while [ "\$(ls -1 "$RAN_DIR" | grep -c .)" -lt 4 ]; do
    [ "\$SECONDS" -lt "\$deadline" ] || { echo "the other four suites never ran"; exit 1; }
    sleep 0.1
done
: >> "$RAN_DIR/test_fake1.sh"
EOF
    local out rc=0
    out=$(CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected exit 0, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 5 ] || { echo "expected 5 suites to run, got $(ran_count)"; return 1; }
}

# The queue hands out the longest suites first, judged by line count, so the
# slowest suite never starts last behind a lane's worth of short ones. With two
# lanes the two longest suites must both start before any short one has run;
# they meet before either finishes, so neither lane comes free early. Both are
# last in name order, where list order or a fixed split would start them late.
# Each waits for the other for 120 s of wall time at most.
test_run_all_starts_the_longest_suites_first() {
    make_suite_dir 4
    local n other
    for n in 3 4; do
        other=$((7 - n))
        {
            printf '#!/usr/bin/env bash\n'
            printf '[ -e "%s/test_fake1.sh" ] && { echo "a short suite ran first"; exit 1; }\n' "$RAN_DIR"
            printf '[ -e "%s/test_fake2.sh" ] && { echo "a short suite ran first"; exit 1; }\n' "$RAN_DIR"
            printf ': > "%s/started%s"\n' "$TEST_TMPDIR" "$n"
            printf 'deadline=$((SECONDS + 120))\n'
            printf 'until [ -e "%s/started%s" ]; do\n' "$TEST_TMPDIR" "$other"
            printf '    [ "$SECONDS" -lt "$deadline" ] || { echo "the other long suite never started"; exit 1; }\n'
            printf '    sleep 0.1\n'
            printf 'done\n'
            printf ': >> "%s/test_fake%s.sh"\n' "$RAN_DIR" "$n"
        } > "$SUITE_DIR/test_fake$n.sh"
    done
    local out rc=0
    out=$(CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected exit 0, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 4 ] || { echo "expected 4 suites to run, got $(ran_count)"; return 1; }
}

# Shards are balanced by line count, longest suite first, so two long suites
# land on different shards and a CI job's wall time is not two slow suites
# back to back. The long ones are first and third in name order, which a
# round-robin over that order puts on the same shard. Each suite appends a
# line every time it runs, so a suite two shards both claimed shows as two.
test_run_all_shards_split_the_long_suites() {
    make_suite_dir 4
    local n i
    for n in 1 2 3 4; do
        {
            printf '#!/usr/bin/env bash\n'
            printf 'echo ran >> "%s/test_fake%s.sh"\n' "$RAN_DIR" "$n"
            if [ "$n" = 1 ] || [ "$n" = 3 ]; then
                for i in 1 2 3 4 5 6 7 8 9 10; do printf '# long\n'; done
            fi
        } > "$SUITE_DIR/test_fake$n.sh"
    done
    local out
    out=$(CS_TEST_SHARD=1/2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || {
        echo "shard 1/2 failed"; printf '%s\n' "$out"; return 1; }
    if [ -e "$RAN_DIR/test_fake1.sh" ] && [ -e "$RAN_DIR/test_fake3.sh" ]; then
        echo "both long suites ran in shard 1/2"; return 1
    fi
    out=$(CS_TEST_SHARD=2/2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || {
        echo "shard 2/2 failed"; printf '%s\n' "$out"; return 1; }
    for n in 1 2 3 4; do
        [ "$(grep -c . "$RAN_DIR/test_fake$n.sh" 2>/dev/null)" = 1 ] \
            || { echo "test_fake$n.sh ran $(grep -c . "$RAN_DIR/test_fake$n.sh" 2>/dev/null || echo 0) times over the two shards"; return 1; }
    done
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
    if grep -q 'suites passed' <<< "$out"; then
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
    n=$(sed -n '/at [0-9][0-9]* jobs/{s/.*at \([0-9][0-9]*\) jobs.*/\1/p;q;}' <<< "$out")
    [ -n "$n" ] || { echo "runner did not announce its job count"; printf '%s\n' "$out"; return 1; }
    [ "$n" -gt 4 ] || { echo "16 cores must buy more than 4 lanes, got $n"; return 1; }
}

# The ceiling must not become a floor, and the halving must not reach a small
# runner: a 2-core CI box keeps 2 lanes rather than being cut to 1 or
# oversubscribed up to the cap.
test_run_all_does_not_oversubscribe_a_small_runner() {
    make_suite_dir 2
    local out n
    out=$(PATH="$(fake_cores 2):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    n=$(sed -n '/at [0-9][0-9]* jobs/{s/.*at \([0-9][0-9]*\) jobs.*/\1/p;q;}' <<< "$out")
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
        grep -q "test_fake$i.sh" <<< "$err" \
            || { echo "no progress line for test_fake$i.sh"; printf '%s\n' "$err"; return 1; }
    done
    grep -Eq '\[[1-4]/4\] test_fake[1-4]\.sh .*[0-9]+s' <<< "$err" \
        || { echo "progress line must carry [n/total], the name and seconds"; printf '%s\n' "$err"; return 1; }
    grep -q '\[4/4\]' <<< "$err" \
        || { echo "the counter must reach the total"; printf '%s\n' "$err"; return 1; }
}

test_run_all_progress_line_marks_a_failing_suite() {
    make_suite_dir 3 test_fake2.sh
    local err
    err=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1 >/dev/null) || true
    grep -q 'FAIL' <<< "$(grep -E 'test_fake2\.sh' <<< "$err")" \
        || { echo "a failing suite's progress line must say FAIL"; printf '%s\n' "$err"; return 1; }
    grep -q 'FAIL' <<< "$(grep -E 'test_fake1\.sh' <<< "$err")" \
        && { echo "a passing suite's progress line must not say FAIL"; return 1; }
    return 0
}

# The report ends with the suites ranked by wall time, so the slow ones have a
# name instead of a feeling.
test_run_all_report_lists_slowest_suites() {
    make_suite_dir 3
    local out
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>/dev/null)
    grep -q 'slowest' <<< "$out" \
        || { echo "report has no slowest-suites table"; printf '%s\n' "$out"; return 1; }
    grep -Eq '[0-9]+s +test_fake[1-3]\.sh' <<< "$out" \
        || { echo "table rows must be '<seconds>s <suite>'"; printf '%s\n' "$out"; return 1; }
}

# Serial mode streams live and has no lanes, but the same three facts still
# matter: it prints the same progress line after each suite.
test_run_all_serial_mode_also_reports_progress() {
    make_suite_dir 2
    local err
    err=$(CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1 >/dev/null)
    grep -q '\[2/2\] test_fake2\.sh' <<< "$err" \
        || { echo "serial mode must print the progress line too"; printf '%s\n' "$err"; return 1; }
}

# Two gates on one checkout do not overlap: they thrash. The first holds a
# lock under the suite directory for its lifetime; a second refuses at once
# with the holder's pid, runs nothing, and exits 3 so a caller can tell "busy"
# from "failed". A lock whose pid is dead is stale and is taken over.
test_run_all_refuses_a_second_gate_on_the_same_checkout() {
    make_suite_dir 2
    local lock="$SUITE_DIR/.run_all.lock"
    mkdir -p "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    local out rc=0
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 3 ] || { echo "a busy checkout must exit 3, got $rc"; printf '%s\n' "$out"; return 1; }
    grep -q "$$" <<< "$out" || { echo "the refusal must name the holder's pid"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 0 ] || { echo "a refused gate ran $(ran_count) suites"; return 1; }
    [ -d "$lock" ] || { echo "the refused gate must not remove the holder's lock"; return 1; }
}

test_run_all_takes_over_a_stale_lock() {
    make_suite_dir 2
    local lock="$SUITE_DIR/.run_all.lock"
    mkdir -p "$lock"
    # A pid no live process holds: fork a sleep-free child, let it exit, keep its pid.
    ( : ) & local dead=$!; wait "$dead" 2>/dev/null
    printf '%s\n' "$dead" > "$lock/pid"
    local out rc=0
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "a stale lock must be taken over, got rc $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 2 ] || { echo "expected both suites to run"; return 1; }
    [ ! -d "$lock" ] || { echo "the lock must be released on exit"; return 1; }
}

test_run_all_releases_the_lock_when_a_suite_fails() {
    make_suite_dir 2 test_fake1.sh
    local lock="$SUITE_DIR/.run_all.lock"
    CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" >/dev/null 2>&1 || true
    [ ! -d "$lock" ] || { echo "lock left behind after a failing run"; return 1; }
}

# Lanes default to half the cores on a workstation: each lane is a fork tree
# of bash, git and cs, so ten lanes on fourteen cores drove the load average
# to 147 and starved every other process on the box, the statusline included.
# A small runner (four cores or fewer) keeps every core; the cap stays as a
# ceiling above that.
test_run_all_defaults_to_half_the_cores() {
    make_suite_dir 2
    local out n
    out=$(PATH="$(fake_cores 14):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    n=$(sed -n '/at [0-9][0-9]* jobs/{s/.*at \([0-9][0-9]*\) jobs.*/\1/p;q;}' <<< "$out")
    [ "$n" -eq 7 ] || { echo "14 cores must default to 7 lanes, got $n"; printf '%s\n' "$out"; return 1; }
}

test_run_all_keeps_at_least_one_lane_on_a_single_core() {
    make_suite_dir 2
    local out n
    out=$(PATH="$(fake_cores 1):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    n=$(sed -n '/at [0-9][0-9]* jobs/{s/.*at \([0-9][0-9]*\) jobs.*/\1/p;q;}' <<< "$out")
    [ "$n" -eq 1 ] || { echo "1 core must give 1 lane, got $n"; return 1; }
}

# Every lane runs its suites under nice so a gate yields to interactive work.
# The fixture suite prints its own niceness; the runner must have raised it.
test_run_all_runs_suites_under_nice() {
    make_suite_dir 1
    # BSD nice with no arguments prints usage, so the fixture reads its own
    # niceness from ps, which both userlands print with -o nice=.
    printf '#!/usr/bin/env bash\nps -o nice= -p $$ | tr -d " "\n: > "%s/test_fake1.sh"\n' "$RAN_DIR" > "$SUITE_DIR/test_fake1.sh"
    local out n
    out=$(CS_TEST_SUITE_DIR="$SUITE_DIR" CS_TEST_JOBS=1 bash "$RUN_ALL" 2>/dev/null)
    n=$(grep -E -m1 '^[0-9]+$' <<< "$out")
    [ -n "$n" ] && [ "$n" -ge 10 ] || { echo "suites must run at niceness >= 10, saw '${n:-none}'"; printf '%s\n' "$out"; return 1; }
}

# --changed runs only the suites that name a changed path, for the edit loop.
# The fixture suites reference source paths in their text the way real suites
# do; CS_TEST_CHANGED injects the changed list so the tests need no git repo.
make_mapped_suite_dir() {
    make_suite_dir 3
    printf '# exercises hooks/foo-hook.sh\n' >> "$SUITE_DIR/test_fake1.sh"
    printf '# exercises bin/cs-statusline\n' >> "$SUITE_DIR/test_fake2.sh"
    printf '# exercises skills/bar/SKILL.md\n' >> "$SUITE_DIR/test_fake3.sh"
}

test_run_all_changed_selects_the_suites_naming_the_path() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="hooks/foo-hook.sh" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || { echo "run failed"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 1 ] || { echo "expected 1 suite, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
    [ -f "$RAN_DIR/test_fake1.sh" ] || { echo "the suite naming the hook did not run"; return 1; }
    grep -q 'changed: 1 path' <<< "$out" || { echo "must say what it selected and why"; printf '%s\n' "$out"; return 1; }
}

# A one-suite selection is the normal --changed case, and it must still show
# the suite's own output: the lane count says nothing about how many suites
# there are, so a runner that captures on lane count alone and replays on
# suite count discards everything the single suite printed.
test_run_all_shows_suite_output_when_only_one_suite_runs() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_JOBS=4 CS_TEST_CHANGED="hooks/foo-hook.sh" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || { echo "run failed"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 1 ] || { echo "expected 1 suite, ran $(ran_count)"; return 1; }
    grep -q 'marker-from-test_fake1.sh' <<< "$out" || { echo "the only suite's output was swallowed"; printf '%s\n' "$out"; return 1; }
}

test_run_all_changed_runs_its_own_suite_for_a_test_file() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="tests/test_fake3.sh" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 1 ] && [ -f "$RAN_DIR/test_fake3.sh" ] || { echo "a changed suite must run itself, ran $(ran_count)"; return 1; }
}

# bin/cs is assembled from every lib fragment and 45 of 63 suites invoke it, so
# a lib change has no honest subset: it is the full gate, and the runner says
# so rather than guessing.
test_run_all_changed_falls_back_to_the_full_gate_for_lib() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="lib/55-queue.sh" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 3 ] || { echo "a lib change must run every suite, ran $(ran_count)"; return 1; }
    grep -qi 'full gate' <<< "$out" || { echo "must say it fell back to the full gate"; printf '%s\n' "$out"; return 1; }
}

test_run_all_changed_falls_back_for_the_harness_and_an_unmapped_path() {
    make_mapped_suite_dir
    CS_TEST_CHANGED="tests/test_lib.sh" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed >/dev/null 2>&1 || return 1
    [ "$(ran_count)" -eq 3 ] || { echo "a harness change must run every suite, ran $(ran_count)"; return 1; }
    rm -f "$RAN_DIR"/*
    CS_TEST_CHANGED="some/new/file.txt" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed >/dev/null 2>&1 || return 1
    [ "$(ran_count)" -eq 3 ] || { echo "an unmapped path must run every suite, ran $(ran_count)"; return 1; }
}

# Session state, docs and config are not code: they neither select a suite nor
# force the full gate, so a dirty .cs/ or an edited README does not turn an
# edit-loop run into twenty minutes.
test_run_all_changed_ignores_non_code_paths() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="$(printf '.cs/memory/narrative.md\ndocs/hooks.md\nREADME.md\nhooks/foo-hook.sh')" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 1 ] && [ -f "$RAN_DIR/test_fake1.sh" ] || { echo "non-code paths must be ignored, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
    rm -f "$RAN_DIR"/*
    out=$(CS_TEST_CHANGED="docs/hooks.md" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 0 ] || { echo "docs alone must run nothing, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
}

# Skill and command markdown is source: suites pin its frontmatter and wording,
# so a change there selects those suites rather than being waved through as
# documentation.
test_run_all_changed_treats_skill_markdown_as_source() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="skills/bar/SKILL.md" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 1 ] && [ -f "$RAN_DIR/test_fake3.sh" ] || { echo "a skill file must select the suite naming it, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
}

test_run_all_changed_with_nothing_changed_runs_nothing() {
    make_mapped_suite_dir
    local out rc=0
    out=$(CS_TEST_CHANGED="" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "nothing changed must exit 0, got $rc"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 0 ] || { echo "nothing changed must run nothing, ran $(ran_count)"; return 1; }
    grep -qi 'nothing changed' <<< "$out" || { echo "must say nothing changed"; printf '%s\n' "$out"; return 1; }
}

test_run_all_changed_unions_several_paths() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="$(printf 'hooks/foo-hook.sh\nbin/cs-statusline')" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || return 1
    [ "$(ran_count)" -eq 2 ] || { echo "two mapped paths must select two suites, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
    [ ! -f "$RAN_DIR/test_fake3.sh" ] || { echo "an unrelated suite ran"; return 1; }
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Test gate runner tests"
echo "======================"
echo ""


# A suite that never finishes must not hold the gate forever: past the cap it
# is stopped, named, counted as a failure, and the rest of the gate runs.
test_run_all_stops_a_suite_past_the_time_cap() {
    make_suite_dir 3
    make_suite_hang 2
    local out rc=0 t0=$SECONDS
    out=$(CS_TEST_SUITE_TIMEOUT=2 CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || { echo "expected exit 1 for a suite past the cap, got $rc"; printf '%s\n' "$out"; return 1; }
    [ $((SECONDS - t0)) -lt 30 ] || { echo "the gate waited on the hung suite for $((SECONDS - t0))s"; return 1; }
    grep -q 'test_fake2.sh: timed out after 2s' <<< "$out" \
        || { echo "the hung suite was not named as timed out"; printf '%s\n' "$out"; return 1; }
    grep -q 'FAILED: 1/3' <<< "$out" || { echo "wrong failure tally"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 2 ] || { echo "the other suites did not all run: $(ran_count)/2"; return 1; }
    # The suite was waiting on its child; the child must not outlive it.
    local hung
    hung=$(cat "$TEST_TMPDIR/hung.pid")
    ! kill -0 "$hung" 2>/dev/null || { echo "the hung suite's child $hung is still running"; kill "$hung"; return 1; }
}

test_run_all_stops_a_suite_past_the_time_cap_in_serial_mode() {
    make_suite_dir 2
    make_suite_hang 1
    local out rc=0 t0=$SECONDS
    out=$(CS_TEST_SUITE_TIMEOUT=2 CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || { echo "expected exit 1 for a suite past the cap, got $rc"; printf '%s\n' "$out"; return 1; }
    [ $((SECONDS - t0)) -lt 30 ] || { echo "the gate waited on the hung suite for $((SECONDS - t0))s"; return 1; }
    grep -q 'test_fake1.sh: timed out after 2s' <<< "$out" \
        || { echo "the hung suite was not named as timed out"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 1 ] || { echo "the suite after the hung one did not run"; return 1; }
    local hung
    hung=$(cat "$TEST_TMPDIR/hung.pid")
    ! kill -0 "$hung" 2>/dev/null || { echo "the hung suite's child $hung is still running"; kill "$hung"; return 1; }
}

# Every suite gets a watchdog; one left sleeping per suite would outlive the
# gate by the whole cap. An unusual cap makes its sleeps findable by argv.
# The gate runs in the background and gets 30 s: a watchdog that is never
# stopped makes each suite wait out the whole cap, and that must fail here,
# not hang the suite for two hours.
test_run_all_leaves_no_watchdog_behind() {
    make_suite_dir 4
    # A private copy of the runner: a watchdog is a subshell of it, so its
    # command line carries this path and no other gate's does.
    local runner="$TEST_TMPDIR/runner/run_all.sh"
    mkdir -p "${runner%/*}"
    cp "$RUN_ALL" "$runner"
    CS_TEST_SUITE_TIMEOUT=7771 CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$runner" > "$TEST_TMPDIR/gate.out" 2>&1 &
    local gate=$! waited=0
    while kill -0 "$gate" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$gate" 2>/dev/null; then
        kill -TERM "$gate"
        wait "$gate" 2>/dev/null
        pkill -f "$runner"
        echo "the gate did not finish within 30s of 4 instant suites"
        return 1
    fi
    wait "$gate" || { echo "the gate failed"; cat "$TEST_TMPDIR/gate.out"; return 1; }
    # A watchdog leaves within a tick of its suite, later on a loaded machine;
    # one never stopped sleeps out its 7771 s cap, far past this wait.
    local left
    wait_until _nothing_runs "$runner"
    left=$(pgrep -f "$runner" || true)
    [ -z "$left" ] || { echo "watchdogs outlived the gate: $left"; pkill -f "$runner"; return 1; }
}

# Exits 0 when no process has <pattern> in its command line.
_nothing_runs() {  # pattern
    ! pgrep -f "$1" >/dev/null
}

# TERM is a request; a suite that ignores it is still stopped once the grace
# after the cap runs out.
test_run_all_kills_a_suite_that_ignores_term() {
    make_suite_dir 2
    make_suite_hang 1 ignore-term
    local out rc=0 t0=$SECONDS
    out=$(CS_TEST_SUITE_TIMEOUT=2 CS_TEST_JOBS=2 CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
    [ "$rc" -eq 1 ] || { echo "expected exit 1, got $rc"; printf '%s\n' "$out"; return 1; }
    [ $((SECONDS - t0)) -lt 30 ] || { echo "the gate waited on a TERM-proof suite for $((SECONDS - t0))s"; return 1; }
    grep -q 'test_fake1.sh: timed out after 2s' <<< "$out" || { echo "not named as timed out"; printf '%s\n' "$out"; return 1; }
    local hung
    hung=$(cat "$TEST_TMPDIR/hung.pid")
    ! kill -0 "$hung" 2>/dev/null || { echo "the suite's grandchild $hung is still running"; kill "$hung"; return 1; }
}

test_run_all_rejects_a_malformed_time_cap() {
    make_suite_dir 1
    local out rc=0 bad
    for bad in 0 ten -5; do
        rc=0
        out=$(CS_TEST_SUITE_TIMEOUT="$bad" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1) || rc=$?
        [ "$rc" -eq 2 ] || { echo "CS_TEST_SUITE_TIMEOUT=$bad: expected exit 2, got $rc"; return 1; }
        grep -q "invalid CS_TEST_SUITE_TIMEOUT='$bad' (want a positive number of seconds)" <<< "$out" \
            || { echo "CS_TEST_SUITE_TIMEOUT=$bad: wrong message"; printf '%s\n' "$out"; return 1; }
    done
    [ "$(ran_count)" -eq 0 ] || { echo "a malformed cap still ran suites"; return 1; }
}

run_test test_run_all_runs_every_suite_exactly_once
run_test test_run_all_skips_the_shared_harness
run_test test_run_all_serial_mode_runs_every_suite
run_test test_run_all_reports_the_failing_suite_by_name
run_test test_run_all_keeps_each_suites_own_output
run_test test_run_all_shards_partition_the_suite_list
run_test test_run_all_a_free_lane_takes_the_next_suite
run_test test_run_all_starts_the_longest_suites_first
run_test test_run_all_shards_split_the_long_suites
run_test test_run_all_shards_balance_by_line_count
run_test test_run_all_shards_count_a_declared_weight
run_test test_run_all_refuses_an_unreadable_suite
run_test test_run_all_fails_loudly_when_the_log_dir_cannot_be_made
run_test test_run_all_rejects_a_malformed_shard
run_test test_run_all_rejects_a_malformed_job_count
run_test test_run_all_scales_jobs_with_the_core_count
run_test test_run_all_does_not_oversubscribe_a_small_runner
run_test test_run_all_reports_each_suite_as_it_finishes
run_test test_run_all_progress_line_marks_a_failing_suite
run_test test_run_all_report_lists_slowest_suites
run_test test_run_all_serial_mode_also_reports_progress
run_test test_run_all_refuses_a_second_gate_on_the_same_checkout
run_test test_run_all_takes_over_a_stale_lock
run_test test_run_all_releases_the_lock_when_a_suite_fails
run_test test_run_all_defaults_to_half_the_cores
run_test test_run_all_keeps_at_least_one_lane_on_a_single_core
run_test test_run_all_runs_suites_under_nice
run_test test_run_all_changed_selects_the_suites_naming_the_path
run_test test_run_all_changed_runs_its_own_suite_for_a_test_file
run_test test_run_all_shows_suite_output_when_only_one_suite_runs
run_test test_run_all_changed_falls_back_to_the_full_gate_for_lib
run_test test_run_all_changed_falls_back_for_the_harness_and_an_unmapped_path
run_test test_run_all_changed_ignores_non_code_paths
# The Rust crate has no bash suite: cargo test covers it, so a tui/ edit must
# not fall through to the full gate the way an unrecognised source path does.
test_run_all_changed_ignores_the_rust_crate() {
    make_mapped_suite_dir
    local out
    out=$(CS_TEST_CHANGED="tui/src/main.rs" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" --changed 2>&1) || { echo "run failed"; printf '%s\n' "$out"; return 1; }
    [ "$(ran_count)" -eq 0 ] || { echo "a tui-only change must run no bash suite, ran $(ran_count)"; printf '%s\n' "$out"; return 1; }
}

run_test test_run_all_changed_treats_skill_markdown_as_source
run_test test_run_all_changed_ignores_the_rust_crate
run_test test_run_all_changed_with_nothing_changed_runs_nothing
run_test test_run_all_changed_unions_several_paths
run_test test_run_all_stops_a_suite_past_the_time_cap
run_test test_run_all_stops_a_suite_past_the_time_cap_in_serial_mode
run_test test_run_all_leaves_no_watchdog_behind
run_test test_run_all_kills_a_suite_that_ignores_term
run_test test_run_all_rejects_a_malformed_time_cap
run_test test_run_all_names_every_skipped_test_and_counts_them
run_test test_run_all_verdict_line_is_bare_when_nothing_skipped
run_test test_run_all_names_skips_beside_a_failure

# A checkout with one shellcheck warning (SC2034 in one.sh) holding the real
# lint and the real tests/test_lint_checkout.sh. The suite and the harness stay untracked, so
# the lint counts that one warning whatever they contain. An empty pin leaves
# SHELLCHECK_VERSION out of the workflow.
make_lint_checkout() {  # baseline, pinned_version
    LINT_CHECKOUT="$TEST_TMPDIR/checkout"
    mkdir -p "$LINT_CHECKOUT/bin" "$LINT_CHECKOUT/tests" "$LINT_CHECKOUT/.github/workflows"
    local b
    for b in cs cs-secrets cs-statusline cs-subagent-statusline; do
        printf '#!/usr/bin/env bash\ntrue\n' > "$LINT_CHECKOUT/bin/$b"
    done
    printf '#!/usr/bin/env bash\nunused=1\n' > "$LINT_CHECKOUT/one.sh"
    cp "$SCRIPT_DIR/lint_shell.sh" "$LINT_CHECKOUT/tests/lint_shell.sh"
    printf '%s\n' "$1" > "$LINT_CHECKOUT/.shellcheck-warnings"
    printf 'name: Test\n' > "$LINT_CHECKOUT/.github/workflows/test.yml"
    [ -z "$2" ] || printf '          SHELLCHECK_VERSION: v%s\n' "$2" >> "$LINT_CHECKOUT/.github/workflows/test.yml"
    git -C "$LINT_CHECKOUT" init -q
    git -C "$LINT_CHECKOUT" add -A
    cp "$SCRIPT_DIR/test_lib.sh" "$SCRIPT_DIR/test_lint_checkout.sh" "$LINT_CHECKOUT/tests/" || return 1
}

installed_shellcheck_version() {
    shellcheck --version | sed -n 's/^version: //p'
}

# Sets GATE_OUT and GATE_RC. Arguments are env assignments for the gate.
run_gate_over_lint_checkout() {
    GATE_RC=0
    GATE_OUT=$(env -u CS_TEST_REQUIRE_TOOLS "$@" CS_TEST_JOBS=1 CS_TEST_SUITE_DIR="$LINT_CHECKOUT/tests" bash "$RUN_ALL" 2>&1) || GATE_RC=$?
}

# A PATH holding what the gate and the suite call, and no shellcheck. Sets NO_SHELLCHECK_PATH.
make_path_without_shellcheck() {
    NO_SHELLCHECK_PATH="$TEST_TMPDIR/no-shellcheck-bin"
    mkdir -p "$NO_SHELLCHECK_PATH"
    _stub_tools "$NO_SHELLCHECK_PATH" bash sh env git grep sed awk cut tr head tail wc sort uniq paste \
        basename dirname cat date find kill mkdir mktemp nice rm sleep ps chmod ln cp mv stat touch tee xargs getconf uname || return 1
}

test_run_all_fails_when_the_checkout_lint_rises() {
    require_tool shellcheck || return $?
    make_lint_checkout 0 "$(installed_shellcheck_version)" || return 1
    run_gate_over_lint_checkout
    assert_eq 1 "$GATE_RC" "one warning over a baseline of 0 must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "shellcheck warnings rose from 0 to 1" \
        "the gate log must carry the lint's own words" || return 1
    assert_output_contains "$GATE_OUT" "FAILED: 1/1 suites" "the verdict must count the lint suite" || return 1
    assert_output_contains "$GATE_OUT" "  - test_lint_checkout.sh" "the verdict must name the lint suite" || return 1
}

test_run_all_passes_when_the_checkout_lint_holds_its_baseline() {
    require_tool shellcheck || return $?
    make_lint_checkout 1 "$(installed_shellcheck_version)" || return 1
    run_gate_over_lint_checkout
    assert_eq 0 "$GATE_RC" "a count at the baseline must pass the gate: $GATE_OUT" || return 1
    assert_eq "OK: all 1 suites passed" "$(tail -n 1 <<< "$GATE_OUT")" "a clean lint is a plain pass, no skip" || return 1
}

# The count is only meaningful at the version CI pins: another shellcheck, like
# the one on GitHub's Ubuntu image, can report a different number on the same
# tree. A baseline of 0 would fail if the lint ran, so a pass here means it did not.
test_run_all_skips_the_lint_at_a_version_ci_does_not_pin() {
    require_tool shellcheck || return $?
    make_lint_checkout 0 0.0.0 || return 1
    run_gate_over_lint_checkout
    assert_eq 0 "$GATE_RC" "another shellcheck version must not judge the count: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "test_lint_checkout.sh: test_checkout_holds_its_shellcheck_baseline (shellcheck $(installed_shellcheck_version) is not the 0.0.0 CI pins)" \
        "the skip summary must name both versions" || return 1
    assert_eq "OK: all 1 suites passed, 1 test skipped" "$(tail -n 1 <<< "$GATE_OUT")" "the verdict must count the skip" || return 1
}

# A pin the suite cannot read is a broken suite, not a version mismatch: a skip
# here would switch the lint off for good after a rename in the workflow.
test_run_all_fails_when_the_workflow_names_no_shellcheck_pin() {
    require_tool shellcheck || return $?
    make_lint_checkout 1 "" || return 1
    run_gate_over_lint_checkout
    assert_eq 1 "$GATE_RC" "a workflow with no pin must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "no SHELLCHECK_VERSION line in .github/workflows/test.yml" \
        "the failure must name what is missing" || return 1
}

# YAML ends a value at a space and a #, and the workflow's other pins carry a
# comment that way. A baseline of 0 would pass only if the lint did not run.
test_run_all_judges_the_lint_at_a_pin_with_a_trailing_comment() {
    require_tool shellcheck || return $?
    make_lint_checkout 0 "$(installed_shellcheck_version) # with the baseline" || return 1
    run_gate_over_lint_checkout
    assert_eq 1 "$GATE_RC" "a pin with a trailing comment must be judged at the pin: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "shellcheck warnings rose from 0 to 1" "the lint must have run" || return 1
}

test_run_all_fails_on_a_duplicated_shellcheck_pin() {
    require_tool shellcheck || return $?
    make_lint_checkout 1 0.11.0 || return 1
    printf '          SHELLCHECK_VERSION: v0.10.0\n' >> "$LINT_CHECKOUT/.github/workflows/test.yml"
    run_gate_over_lint_checkout
    assert_eq 1 "$GATE_RC" "two pins must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "  FAIL: SHELLCHECK_VERSION in .github/workflows/test.yml must be one vN.N.N, found 'v0.11.0 v0.10.0'" \
        "the failure must name both values" || return 1
}

test_run_all_fails_on_a_shellcheck_pin_that_is_not_a_version() {
    require_tool shellcheck || return $?
    make_lint_checkout 1 0.11 || return 1
    run_gate_over_lint_checkout
    assert_eq 1 "$GATE_RC" "a malformed pin must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "  FAIL: SHELLCHECK_VERSION in .github/workflows/test.yml must be one vN.N.N, found 'v0.11'" \
        "the failure must name the value" || return 1
}

# CI's bash jobs have no shellcheck at the pin, so a pin read only after the
# tool check would let a rename in the workflow pass all of them as a skip.
test_run_all_fails_on_a_malformed_pin_with_no_shellcheck_installed() {
    make_lint_checkout 1 0.11 || return 1
    make_path_without_shellcheck || return 1
    run_gate_over_lint_checkout PATH="$NO_SHELLCHECK_PATH"
    assert_eq 1 "$GATE_RC" "a malformed pin must fail the gate without shellcheck: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "  FAIL: SHELLCHECK_VERSION in .github/workflows/test.yml must be one vN.N.N, found 'v0.11'" \
        "the failure must name the value" || return 1
}

test_run_all_fails_when_the_installed_shellcheck_version_is_unreadable() {
    make_lint_checkout 1 0.11.0 || return 1
    local fake="$TEST_TMPDIR/fake-shellcheck-bin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nexit 1\n' > "$fake/shellcheck"
    chmod +x "$fake/shellcheck"
    run_gate_over_lint_checkout PATH="$fake:$PATH"
    assert_eq 1 "$GATE_RC" "an unreadable version must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "  FAIL: no version in the output of shellcheck --version, found ''" \
        "the failure must say what could not be read" || return 1
}

test_run_all_fails_at_another_version_when_shellcheck_is_declared() {
    require_tool shellcheck || return $?
    make_lint_checkout 1 0.0.0 || return 1
    run_gate_over_lint_checkout CS_TEST_REQUIRE_TOOLS=shellcheck
    assert_eq 1 "$GATE_RC" "a declared shellcheck at another version must fail the gate: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "  FAIL: shellcheck $(installed_shellcheck_version) is not the 0.0.0 CI pins, and CS_TEST_REQUIRE_TOOLS says this run has it" \
        "the failure must name both versions" || return 1
}

test_run_all_skips_the_lint_when_shellcheck_is_absent() {
    make_lint_checkout 1 0.11.0 || return 1
    make_path_without_shellcheck || return 1
    run_gate_over_lint_checkout PATH="$NO_SHELLCHECK_PATH"
    assert_eq 0 "$GATE_RC" "an undeclared absent shellcheck must skip: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "test_lint_checkout.sh: test_checkout_holds_its_shellcheck_baseline (shellcheck not on PATH)" \
        "the skip summary must give the reason" || return 1
    assert_eq "OK: all 1 suites passed, 1 test skipped" "$(tail -n 1 <<< "$GATE_OUT")" "the verdict must count the skip" || return 1
}

test_run_all_fails_when_a_declared_shellcheck_is_absent() {
    make_lint_checkout 1 0.11.0 || return 1
    make_path_without_shellcheck || return 1
    run_gate_over_lint_checkout PATH="$NO_SHELLCHECK_PATH" CS_TEST_REQUIRE_TOOLS=shellcheck
    assert_eq 1 "$GATE_RC" "a declared absent shellcheck must fail: $GATE_OUT" || return 1
    assert_output_contains "$GATE_OUT" "    FAIL: shellcheck is not on PATH, and CS_TEST_REQUIRE_TOOLS says this run has it" \
        "the failure must name the tool" || return 1
}

run_test test_run_all_fails_when_the_checkout_lint_rises
run_test test_run_all_passes_when_the_checkout_lint_holds_its_baseline
run_test test_run_all_skips_the_lint_at_a_version_ci_does_not_pin
run_test test_run_all_fails_when_the_workflow_names_no_shellcheck_pin
run_test test_run_all_judges_the_lint_at_a_pin_with_a_trailing_comment
run_test test_run_all_fails_on_a_duplicated_shellcheck_pin
run_test test_run_all_fails_on_a_shellcheck_pin_that_is_not_a_version
run_test test_run_all_fails_on_a_malformed_pin_with_no_shellcheck_installed
run_test test_run_all_fails_when_the_installed_shellcheck_version_is_unreadable
run_test test_run_all_fails_at_another_version_when_shellcheck_is_declared
run_test test_run_all_skips_the_lint_when_shellcheck_is_absent
run_test test_run_all_fails_when_a_declared_shellcheck_is_absent

report_results
