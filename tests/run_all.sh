#!/usr/bin/env bash
# ABOUTME: Runs every bash test suite and fails if any suite fails
# ABOUTME: Aggregates per-suite exit codes (a plain for-loop only reports the last)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the suites live. Overridable so the gate's own tests can drive it over a
# directory of fixtures instead of the real suite list -- without the override
# they would glob this directory and recurse into themselves.
SUITE_DIR="${CS_TEST_SUITE_DIR:-$SCRIPT_DIR}"

# Optional sharding for CI parallelism: CS_TEST_SHARD="N/M" runs shard N of M
# (round-robin over the suite list, so slow suites spread across shards). Unset
# runs every suite. The round-robin index counts only real suites (test_lib.sh
# is skipped first), so every shard on an identical runner image computes the
# same assignment and the shards together cover each suite exactly once.
shard_n=1; shard_m=1
if [ -n "${CS_TEST_SHARD:-}" ]; then
    shard_n=${CS_TEST_SHARD%%/*}
    shard_m=${CS_TEST_SHARD##*/}
    case "${shard_n}:${shard_m}" in
        *[!0-9]*:*|*:*[!0-9]*|:*|*:) echo "invalid CS_TEST_SHARD='$CS_TEST_SHARD' (want N/M)" >&2; exit 2 ;;
    esac
    if [ "$shard_m" -lt 1 ] || [ "$shard_n" -lt 1 ] || [ "$shard_n" -gt "$shard_m" ]; then
        echo "invalid CS_TEST_SHARD='$CS_TEST_SHARD' (need 1<=N<=M)" >&2; exit 2
    fi
fi

# How many suites run at once. Suites are independent -- test_lib.sh gives every
# test its own mktemp -d and scopes CS_SESSIONS_ROOT, CS_TRANSCRIPTS_DIR, HOME,
# CS_CLAUDE_DIR and CS_TMUX_BIN inside it -- so concurrent suites cannot collide.
# The default is half the cores on a workstation, up to a ceiling. A lane is
# not one process: each suite forks a tree of bash, git and cs, so lanes equal
# to the core count oversubscribe the box several times over (ten lanes on
# fourteen cores drove the load average to 147 and starved the statusline, the
# editor and every other session). Half leaves the other half for the person at
# the keyboard. A small runner (four cores or fewer, the CI shape) has nobody
# at the keyboard and keeps every core: halving it would double the CI lane's
# wall time for no one's benefit. Wall time is the greater of the slowest
# single suite and the total divided by the lanes, so lanes pay off until those
# two meet; the ceiling is where they converge, and past it round-robin
# assignment loses to imbalance. CS_TEST_JOBS overrides; CS_TEST_JOBS=1
# restores a serial run, which streams each suite's output live rather than
# buffering it.
detect_jobs() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -gt 4 ] && n=$((n / 2))
    [ "$n" -ge 1 ] || n=1
    [ "$n" -le 10 ] || n=10
    printf '%s' "$n"
}
if [ -n "${CS_TEST_JOBS:-}" ]; then
    jobs_n="$CS_TEST_JOBS"
    case "$jobs_n" in ''|*[!0-9]*) echo "invalid CS_TEST_JOBS='$CS_TEST_JOBS' (want a positive integer)" >&2; exit 2 ;; esac
    [ "$jobs_n" -ge 1 ] || { echo "invalid CS_TEST_JOBS='$CS_TEST_JOBS' (want a positive integer)" >&2; exit 2; }
else
    jobs_n="$(detect_jobs)"
fi

# Select this shard's suites, in glob order.
selected=()
idx=-1
for suite in "$SUITE_DIR"/test_*.sh; do
    [ -e "$suite" ] || continue
    # test_lib.sh is the shared harness, not a suite -- it exits non-zero by
    # design when sourced standalone (SCRIPT_DIR guard).
    [ "$(basename "$suite")" = "test_lib.sh" ] && continue
    idx=$((idx + 1))
    if [ "$shard_m" -gt 1 ] && [ "$(( idx % shard_m ))" -ne "$(( shard_n - 1 ))" ]; then
        continue
    fi
    selected+=("$suite")
done

total=${#selected[@]}
failed=()

if [ "$total" -eq 0 ]; then
    echo "no suites matched $SUITE_DIR/test_*.sh" >&2
    exit 2
fi

# One gate per checkout. Two full gates on the same box do not overlap, they
# thrash, and a second one started by mistake (a release step beside a manual
# run) is the way a two-minute gate becomes twenty. The lock is a directory
# under the suite dir, taken with mkdir because that is atomic on every
# filesystem cs runs on and needs no flock, which macOS lacks. It holds the
# owner's pid: a live pid means busy, exit 3 so a caller can tell busy from
# failed; a dead pid is a crashed gate's leftover and is taken over.
lock="$SUITE_DIR/.run_all.lock"
_release_lock() {
    [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$lock"
}
if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        echo "another run_all.sh holds $lock (pid $holder); wait for it or stop it" >&2
        exit 3
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "cannot take $lock" >&2; exit 2; }
fi
printf '%s\n' "$$" > "$lock/pid"
trap '_release_lock' EXIT

# Say what the run is about to do. A gate that takes minutes should account for
# them, and the lane count is the one number that explains the wall time.
echo "running $total suites at $jobs_n jobs" >&2

# Every suite's log, exit and wall time land in one scratch directory keyed by
# position, whether the lanes run concurrently or one at a time. Checked,
# because an empty logdir is silently catastrophic rather than noisy: every
# suite is launched with its output redirected into this directory, bash
# abandons a command whose redirection fails, and the missing log then reads as
# a suite that produced no output and did not fail. The gate would report every
# suite passing having run none of them.
logdir="$(mktemp -d)" || { echo "cannot create a scratch directory for the test logs" >&2; exit 2; }
trap 'rm -rf "$logdir"; _release_lock' EXIT
donefile="$logdir/done"
: > "$donefile"

# Run suite k under nice, so a gate yields to whoever is typing: capture its
# output, stamp its seconds and whether it failed, and say so on stderr the
# moment it finishes. The progress counter is the number
# of suites finished so far, not k, so it climbs in finishing order while the
# report below still replays in list order. The one-line append to the done
# file is under PIPE_BUF, so concurrent lanes cannot tear it, and the count is
# read back from that file rather than from a variable a background subshell
# could not share. In serial mode the suite streams live and the log doubles
# as the record.
run_suite() {  # index
    local k="$1" name t0 t1 secs mark
    name=$(basename "${selected[$k]}")
    t0=$(date +%s)
    if [ "$jobs_n" -gt 1 ]; then
        nice -n 10 bash "${selected[$k]}" > "$logdir/$k.log" 2>&1 || : > "$logdir/$k.fail"
    else
        nice -n 10 bash "${selected[$k]}" 2>&1 | tee "$logdir/$k.log"
        [ "${PIPESTATUS[0]}" -eq 0 ] || : > "$logdir/$k.fail"
    fi
    t1=$(date +%s)
    secs=$((t1 - t0))
    printf '%s\n' "$secs" > "$logdir/$k.secs"
    printf '%s\n' "$k" >> "$donefile"
    mark=""
    [ -f "$logdir/$k.fail" ] && mark=" FAIL"
    printf '[%s/%s] %s %ss%s\n' "$(grep -c . "$donefile")" "$total" "$name" "$secs" "$mark" >&2
}

if [ "$jobs_n" -gt 1 ] && [ "$total" -gt 1 ]; then
    # Each suite writes to its own log keyed by position, so the report below
    # replays them in the same order a serial run would print them -- the
    # concurrency is invisible in the output. Failures are recorded as marker
    # files because a background subshell cannot append to the parent's array.
    j=0
    while [ "$j" -lt "$jobs_n" ]; do
        (
            k=$j
            while [ "$k" -lt "$total" ]; do
                run_suite "$k"
                k=$((k + jobs_n))
            done
        ) &
        j=$((j + 1))
    done
    wait

    k=0
    while [ "$k" -lt "$total" ]; do
        echo "=== $(basename "${selected[$k]}") ==="
        cat "$logdir/$k.log" 2>/dev/null
        [ -f "$logdir/$k.fail" ] && failed+=("$(basename "${selected[$k]}")")
        k=$((k + 1))
    done
else
    k=0
    while [ "$k" -lt "$total" ]; do
        echo "=== $(basename "${selected[$k]}") ==="
        run_suite "$k"
        [ -f "$logdir/$k.fail" ] && failed+=("$(basename "${selected[$k]}")")
        k=$((k + 1))
    done
fi

# The slow suites get a name. Top of the list is where a minute of wall time
# is hiding; the whole list is what a lane-count change has to be judged by.
echo ""
echo "slowest suites:"
k=0
while [ "$k" -lt "$total" ]; do
    printf '%s %s\n' "$(cat "$logdir/$k.secs" 2>/dev/null || echo 0)" "$(basename "${selected[$k]}")"
    k=$((k + 1))
done | sort -rn | head -10 | while read -r secs name; do
    printf '  %4ss  %s\n' "$secs" "$name"
done

echo ""
echo "================================================================"
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${#failed[@]}/$total suites"
    for f in "${failed[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo "OK: all $total suites passed"
