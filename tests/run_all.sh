#!/usr/bin/env bash
# ABOUTME: Runs every bash test suite and fails if any suite fails
# ABOUTME: Aggregates per-suite exit codes (a plain for-loop only reports the last)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=()
total=0
for suite in "$SCRIPT_DIR"/test_*.sh; do
    # test_lib.sh is the shared harness, not a suite — it exits non-zero by
    # design when sourced standalone (SCRIPT_DIR guard).
    [ "$(basename "$suite")" = "test_lib.sh" ] && continue
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
