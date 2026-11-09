#!/usr/bin/env bash
# ABOUTME: Runs tests/lint_shell.sh on this checkout, so a full run_all.sh fails on what CI's shellcheck job would
# ABOUTME: Holds the shellcheck warning count to .shellcheck-warnings; test_run_all.sh drives this suite over fixtures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

REPO="$SCRIPT_DIR/.."

# The baseline was counted at the shellcheck version the workflow pins, and a
# release's new checks change the count on a tree nobody touched. So another
# version, such as the one GitHub's Ubuntu image ships to the bash jobs, skips
# here and leaves the judgment to CI's shellcheck job, which installs the pin.
test_checkout_holds_its_shellcheck_baseline() {
    require_tool shellcheck || return $?
    local pinned installed
    pinned=$(sed -n 's/^ *SHELLCHECK_VERSION: v//p' "$REPO/.github/workflows/test.yml")
    [ -n "$pinned" ] || { echo "  FAIL: no SHELLCHECK_VERSION line in .github/workflows/test.yml, so the version the baseline was counted at is unknown"; return 1; }
    installed=$(shellcheck --version | sed -n 's/^version: //p')
    if [ "$installed" != "$pinned" ]; then
        SKIP_REASON="shellcheck $installed is not the $pinned CI pins"
        echo "    SKIP: $SKIP_REASON"
        return 77
    fi
    local out rc=0
    out=$( cd "$REPO" && bash tests/lint_shell.sh 2>&1 ) || rc=$?
    assert_eq 0 "$rc" "tests/lint_shell.sh must pass on this checkout: $out" || return 1
}

run_test test_checkout_holds_its_shellcheck_baseline

report_results
