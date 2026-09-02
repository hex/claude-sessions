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

# The ceiling must not become a floor, and the halving must not reach a small
# runner: a 2-core CI box keeps 2 lanes rather than being cut to 1 or
# oversubscribed up to the cap.
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
    printf '%s' "$out" | grep -q "$$" || { echo "the refusal must name the holder's pid"; printf '%s\n' "$out"; return 1; }
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
    n=$(printf '%s' "$out" | sed -n 's/.*at \([0-9][0-9]*\) jobs.*/\1/p' | head -1)
    [ "$n" -eq 7 ] || { echo "14 cores must default to 7 lanes, got $n"; printf '%s\n' "$out"; return 1; }
}

test_run_all_keeps_at_least_one_lane_on_a_single_core() {
    make_suite_dir 2
    local out n
    out=$(PATH="$(fake_cores 1):$PATH" CS_TEST_SUITE_DIR="$SUITE_DIR" bash "$RUN_ALL" 2>&1)
    n=$(printf '%s' "$out" | sed -n 's/.*at \([0-9][0-9]*\) jobs.*/\1/p' | head -1)
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
    n=$(printf '%s' "$out" | grep -E '^[0-9]+$' | head -1)
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
    printf '%s' "$out" | grep -q 'changed: 1 path' || { echo "must say what it selected and why"; printf '%s\n' "$out"; return 1; }
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
    printf '%s' "$out" | grep -qi 'full gate' || { echo "must say it fell back to the full gate"; printf '%s\n' "$out"; return 1; }
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
    printf '%s' "$out" | grep -qi 'nothing changed' || { echo "must say nothing changed"; printf '%s\n' "$out"; return 1; }
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
run_test test_run_all_refuses_a_second_gate_on_the_same_checkout
run_test test_run_all_takes_over_a_stale_lock
run_test test_run_all_releases_the_lock_when_a_suite_fails
run_test test_run_all_defaults_to_half_the_cores
run_test test_run_all_keeps_at_least_one_lane_on_a_single_core
run_test test_run_all_runs_suites_under_nice
run_test test_run_all_changed_selects_the_suites_naming_the_path
run_test test_run_all_changed_runs_its_own_suite_for_a_test_file
run_test test_run_all_changed_falls_back_to_the_full_gate_for_lib
run_test test_run_all_changed_falls_back_for_the_harness_and_an_unmapped_path
run_test test_run_all_changed_ignores_non_code_paths
run_test test_run_all_changed_treats_skill_markdown_as_source
run_test test_run_all_changed_with_nothing_changed_runs_nothing
run_test test_run_all_changed_unions_several_paths

report_results
