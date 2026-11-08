#!/usr/bin/env bash
# ABOUTME: Tests for tests/lint_shell.sh, the shellcheck gate CI runs
# ABOUTME: Covers the error gate and the warning count held to .shellcheck-warnings

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

LINT="$SCRIPT_DIR/lint_shell.sh"

# A throwaway repo shaped like cs: the four assembled binaries the lint names,
# and one tracked script carrying exactly one warning (SC2034, unused variable).
_lint_repo() {  # baseline
    REPO="$TEST_TMPDIR/repo"
    mkdir -p "$REPO/bin" "$REPO/tests"
    local b
    for b in cs cs-secrets cs-statusline cs-subagent-statusline; do
        printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/bin/$b"
    done
    printf '#!/usr/bin/env bash\nunused=1\n' > "$REPO/one.sh"
    cp "$LINT" "$REPO/tests/lint_shell.sh"
    printf '%s\n' "$1" > "$REPO/.shellcheck-warnings"
    git -C "$REPO" init -q
    git -C "$REPO" add -A
}

_lint() {
    ( cd "$REPO" && bash tests/lint_shell.sh )
}

test_rising_warnings_fail() {
    require_tool shellcheck || return $?
    _lint_repo 0
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "one warning over a baseline of 0 must fail" || return 1
    assert_output_contains "$out" "shellcheck warnings rose from 0 to 1" \
        "the failure must give both counts" || return 1
}

# A lower count must lower the baseline in the same change, or the next
# change could add warnings back up to the old number unnoticed.
test_falling_warnings_fail_until_the_baseline_drops() {
    require_tool shellcheck || return $?
    _lint_repo 2
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "one warning under a baseline of 2 must fail" || return 1
    assert_output_contains "$out" "shellcheck warnings fell from 2 to 1. Lower .shellcheck-warnings to 1" \
        "the failure must say what to set the baseline to" || return 1
}

test_warnings_at_the_baseline_pass() {
    require_tool shellcheck || return $?
    _lint_repo 1
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 0 "$rc" "a count equal to the baseline must pass: $out" || return 1
    assert_output_contains "$out" "shellcheck warnings: 1 (baseline 1)" \
        "a pass must print the count" || return 1
}

# The error gate runs before the count: an error fails even when the
# warning count matches.
test_an_error_level_finding_fails() {
    require_tool shellcheck || return $?
    _lint_repo 1
    printf '#!/usr/bin/env bash\nif true; then\n' > "$REPO/broken.sh"
    git -C "$REPO" add broken.sh
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "a script that does not parse must fail" || return 1
    assert_output_contains "$out" "lint_shell: shellcheck found errors (above)" \
        "the failure must come from the error gate" || return 1
}

# Findings from every file count, whichever file they come from and however
# the files are spread over the lint's runs.
test_warnings_from_every_file_count() {
    require_tool shellcheck || return $?
    _lint_repo 3
    printf '#!/usr/bin/env bash\nunused_two=1\n' > "$REPO/two.sh"
    printf '#!/usr/bin/env bash\nunused_three=1\n' > "$REPO/three.sh"
    git -C "$REPO" add two.sh three.sh
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 0 "$rc" "three files with one warning each meet a baseline of 3: $out" || return 1
    assert_output_contains "$out" "shellcheck warnings: 3 (baseline 3)" \
        "every file's warning must be counted" || return 1
}

# A shellcheck that cannot run on a file (exit 2 or more) is a broken lint,
# never a file with no findings.
test_a_shellcheck_that_cannot_run_is_an_error() {
    require_tool shellcheck || return $?
    _lint_repo 1
    local fake="$TEST_TMPDIR/fakebin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *one.sh) exit 3 ;; esac; done\nexec "%s" "$@"\n' "$(command -v shellcheck)" > "$fake/shellcheck"
    chmod +x "$fake/shellcheck"
    local out rc=0
    out=$( cd "$REPO" && PATH="$fake:$PATH" bash tests/lint_shell.sh 2>&1 ) || rc=$?
    assert_eq 2 "$rc" "a shellcheck exit of 3 must stop the lint: $out" || return 1
    assert_output_contains "$out" "lint_shell: shellcheck could not run on one.sh (exit 3)" \
        "the error must name the file and the exit" || return 1
}

# The fan-out takes every processor, so it must yield to whoever is typing.
# Compared with the caller, because run_all already runs this suite under nice.
test_shellcheck_runs_below_the_caller_priority() {
    require_tool shellcheck || return $?
    _lint_repo 1
    local fake="$TEST_TMPDIR/fakebin" seen="$TEST_TMPDIR/nice"
    mkdir -p "$fake"
    printf '#!/bin/sh\nps -o nice= -p $$ | tr -d " " >> "%s"\nexec "%s" "$@"\n' "$seen" "$(command -v shellcheck)" > "$fake/shellcheck"
    chmod +x "$fake/shellcheck"
    local caller out rc=0
    caller=$(ps -o nice= -p $$ | tr -d ' ')
    out=$( cd "$REPO" && PATH="$fake:$PATH" bash tests/lint_shell.sh 2>&1 ) || rc=$?
    assert_eq 0 "$rc" "the lint must pass here: $out" || return 1
    assert_eq 6 "$(wc -l < "$seen" | tr -d ' ')" "the four binaries, one.sh and lint_shell.sh must each reach the fake" || return 1
    local level
    while IFS= read -r level; do
        [ "$level" -gt "$caller" ] || { echo "shellcheck ran at nice $level, the caller is at $caller"; return 1; }
    done < "$seen"
}

# A number past bash's integer range makes both comparisons error out and
# fall through to the pass line, so it is refused like any other bad value.
test_a_baseline_that_is_not_a_number_is_an_error() {
    require_tool shellcheck || return $?
    local bad out rc
    for bad in "about 110" "99999999999999999999"; do
        _lint_repo "$bad"
        rc=0
        out=$(_lint 2>&1) || rc=$?
        assert_eq 2 "$rc" "baseline '$bad' must not be compared" || return 1
        assert_output_contains "$out" ".shellcheck-warnings must hold a whole number of at most 9 digits, found '$bad'" \
            "the error must quote the bad baseline" || return 1
        rm -rf "$REPO"
    done
}

run_test test_rising_warnings_fail
run_test test_falling_warnings_fail_until_the_baseline_drops
run_test test_warnings_at_the_baseline_pass
run_test test_an_error_level_finding_fails
run_test test_warnings_from_every_file_count
run_test test_a_shellcheck_that_cannot_run_is_an_error
run_test test_a_baseline_that_is_not_a_number_is_an_error
run_test test_shellcheck_runs_below_the_caller_priority

report_results
