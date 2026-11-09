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
# A run that declares shellcheck in CS_TEST_REQUIRE_TOOLS fails instead, as it
# does for a missing tool. A pin or a version this cannot read fails everywhere:
# a skip there would switch the lint off and say nothing was wrong.
test_checkout_holds_its_shellcheck_baseline() {
    local workflow="$REPO/.github/workflows/test.yml" version='[0-9]+\.[0-9]+\.[0-9]+' pinned installed
    grep -q '^ *SHELLCHECK_VERSION:' "$workflow" || { echo "  FAIL: no SHELLCHECK_VERSION line in .github/workflows/test.yml, so the version the baseline was counted at is unknown"; return 1; }
    # paste keeps a duplicated pin on one line, for the message and for the check below.
    pinned=$(sed -n 's/^ *SHELLCHECK_VERSION:[[:space:]]*//p' "$workflow" | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' | paste -s -d ' ' -)
    [[ $pinned =~ ^v$version$ ]] || { echo "  FAIL: SHELLCHECK_VERSION in .github/workflows/test.yml must be one vN.N.N, found '$pinned'"; return 1; }
    pinned=${pinned#v}
    require_tool shellcheck || return $?
    installed=$(shellcheck --version | sed -n 's/^version: //p')
    [[ $installed =~ ^$version$ ]] || { echo "  FAIL: no version in the output of shellcheck --version, found '$installed'"; return 1; }
    if [ "$installed" != "$pinned" ]; then
        case " $_cs_test_require_tools " in
            *" shellcheck "*)
                echo "  FAIL: shellcheck $installed is not the $pinned CI pins, and CS_TEST_REQUIRE_TOOLS says this run has it"
                return 1
                ;;
        esac
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
