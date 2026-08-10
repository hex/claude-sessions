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
# The default caps well below the core count on purpose: wall time is bounded by
# the slowest single suite, so shards past that point buy nothing and only
# oversubscribe a shared CI runner. CS_TEST_JOBS=1 restores a serial run, which
# streams each suite's output live rather than buffering it.
detect_jobs() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    [ "$n" -ge 1 ] || n=1
    [ "$n" -le 4 ] || n=4
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

if [ "$jobs_n" -gt 1 ] && [ "$total" -gt 1 ]; then
    # Each suite writes to its own log keyed by position, so the report below
    # replays them in the same order a serial run would print them -- the
    # concurrency is invisible in the output. Failures are recorded as marker
    # files because a background subshell cannot append to the parent's array.
    logdir="$(mktemp -d)"
    trap 'rm -rf "$logdir"' EXIT
    j=0
    while [ "$j" -lt "$jobs_n" ]; do
        (
            k=$j
            while [ "$k" -lt "$total" ]; do
                if ! bash "${selected[$k]}" > "$logdir/$k.log" 2>&1; then
                    : > "$logdir/$k.fail"
                fi
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
    for suite in "${selected[@]}"; do
        echo "=== $(basename "$suite") ==="
        if ! bash "$suite"; then
            failed+=("$(basename "$suite")")
        fi
    done
fi

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
