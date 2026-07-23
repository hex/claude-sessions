#!/usr/bin/env bash
# ABOUTME: Runs every bash test suite and fails if any suite fails
# ABOUTME: Aggregates per-suite exit codes (a plain for-loop only reports the last)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional sharding for CI parallelism: CS_TEST_SHARD="N/M" runs shard N of M
# (round-robin over the suite list, so slow suites spread across shards). Unset
# runs every suite — the default for local runs and the non-Windows lanes. The
# round-robin index counts only real suites (test_lib.sh is skipped first), so
# every shard on an identical runner image computes the same assignment and the
# shards together cover each suite exactly once.
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

failed=()
total=0
idx=-1
for suite in "$SCRIPT_DIR"/test_*.sh; do
    # test_lib.sh is the shared harness, not a suite — it exits non-zero by
    # design when sourced standalone (SCRIPT_DIR guard).
    [ "$(basename "$suite")" = "test_lib.sh" ] && continue
    idx=$((idx + 1))
    if [ "$shard_m" -gt 1 ] && [ "$(( idx % shard_m ))" -ne "$(( shard_n - 1 ))" ]; then
        continue
    fi
    total=$((total + 1))
    echo "=== $(basename "$suite") ==="
    if ! bash "$suite"; then
        failed+=("$(basename "$suite")")
    fi
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
