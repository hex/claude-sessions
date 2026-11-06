#!/usr/bin/env bash
# ABOUTME: Exercises CI verdicts and retries through scripted GitHub CLI responses.
# ABOUTME: Checks output, exit codes and every CLI argument without network access.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
CI_WAIT="$SCRIPT_DIR/ci_wait.sh"

_ci_fixture() {
    require_tool jq git || return $?
    mkdir -p "$TEST_TMPDIR/fakebin" "$TEST_TMPDIR/replies"
    printf '0\n' > "$TEST_TMPDIR/count"
    : > "$TEST_TMPDIR/calls"
    REPLY_COUNT=0
    cat > "$TEST_TMPDIR/fakebin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$CI_FIXTURE/calls"
n=$(cat "$CI_FIXTURE/count")
n=$((n + 1))
printf '%s\n' "$n" > "$CI_FIXTURE/count"
if [ ! -f "$CI_FIXTURE/replies/$n.out" ]; then
    printf 'unexpected gh call %s\n' "$n" >&2
    exit 99
fi
cat "$CI_FIXTURE/replies/$n.out"
cat "$CI_FIXTURE/replies/$n.err" >&2
exit "$(cat "$CI_FIXTURE/replies/$n.rc")"
GH
    chmod +x "$TEST_TMPDIR/fakebin/gh"
}

_ci_reply() { # stdout stderr exit
    REPLY_COUNT=$((REPLY_COUNT + 1))
    printf '%s' "$1" > "$TEST_TMPDIR/replies/$REPLY_COUNT.out"
    printf '%s' "${2:-}" > "$TEST_TMPDIR/replies/$REPLY_COUNT.err"
    printf '%s\n' "${3:-0}" > "$TEST_TMPDIR/replies/$REPLY_COUNT.rc"
}

_ci_run_json() { # status attempt jobs
    _ci_reply "$(jq -cn --arg status "$1" --argjson attempt "$2" --argjson jobs "$3" \
        '{status:$status,attempt:$attempt,headSha:"abc123",jobs:$jobs}')"
}

_ci_success() { # attempt
    _ci_run_json completed "$1" '[{"name":"bash","status":"completed","conclusion":"success","steps":[{}],"databaseId":101}]'
}

_ci_wait() {
    CI_RC=0
    PATH="$TEST_TMPDIR/fakebin:$PATH" CI_FIXTURE="$TEST_TMPDIR" CI_WAIT_INTERVAL=0 \
        bash "$CI_WAIT" "$@" > "$TEST_TMPDIR/stdout" 2> "$TEST_TMPDIR/stderr" || CI_RC=$?
    CI_OUT=$(cat "$TEST_TMPDIR/stdout")
    CI_ERR=$(cat "$TEST_TMPDIR/stderr")
}

_ci_calls() {
    assert_eq "$1" "$(cat "$TEST_TMPDIR/calls")" 'exact gh arguments'
}

test_pending_jobs_wait_until_every_conclusion_exists() {
    _ci_fixture || return $?
    _ci_run_json in_progress 1 '[{"name":"bash","status":"in_progress","conclusion":"","steps":[],"databaseId":101}]'
    _ci_run_json in_progress 1 '[{"name":"bash","status":"in_progress","conclusion":"","steps":[],"databaseId":101}]'
    _ci_success 1
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'completed success exits 0' || return 1
    assert_eq $'waiting: 1 of 1 jobs pending (attempt 1)\nsuccess\t1\tbash' "$CI_OUT" 'waiting line prints only on change' || return 1
    assert_eq '' "$CI_ERR" 'success has no error output' || return 1
    assert_eq 3 "$(cat "$TEST_TMPDIR/count")" 'three reads before success' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_failure_and_skipped_dependent_stop() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"build","status":"completed","conclusion":"failure","steps":[{}],"databaseId":101},{"name":"release","status":"completed","conclusion":"skipped","steps":[],"databaseId":102}]'
    _ci_wait 123
    assert_eq 1 "$CI_RC" 'failed job exits 1' || return 1
    assert_eq $'failure\t1\tbuild\nskipped\t0\trelease' "$CI_OUT" 'complete job table' || return 1
    assert_eq '' "$CI_ERR" 'verdict has no error output' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_cancellation_after_steps_is_a_failure() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"bash","status":"completed","conclusion":"cancelled","steps":[{}],"databaseId":101}]'
    _ci_wait 123
    assert_eq 1 "$CI_RC" 'started cancellation exits 1' || return 1
    assert_eq $'cancelled\t1\tbash' "$CI_OUT" 'cancelled job table' || return 1
    assert_eq '' "$CI_ERR" 'verdict has no error output' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_failed_gh_read_reports_stderr() {
    _ci_fixture || return $?
    _ci_reply '' 'network unavailable' 1
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'gh failure exits 4' || return 1
    assert_eq '' "$CI_OUT" 'no verdict from a failed call' || return 1
    assert_eq 'ci_wait: gh run view 123 --json status,attempt,headSha,jobs failed: "network unavailable"' "$CI_ERR" 'call and stderr quoted' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_invalid_arguments_print_usage_without_gh() {
    _ci_fixture || return $?
    local arg
    for arg in missing bad-id unknown-option; do
        case "$arg" in
            missing) _ci_wait ;;
            bad-id) _ci_wait 12x ;;
            unknown-option) _ci_wait 123 --unknown ;;
        esac
        assert_eq 2 "$CI_RC" "$arg exits 2" || return 1
        assert_eq '' "$CI_OUT" 'usage goes to stderr' || return 1
        assert_eq 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' "$CI_ERR" 'exact usage' || return 1
    done
    _ci_calls ''
}

run_test test_pending_jobs_wait_until_every_conclusion_exists
run_test test_failure_and_skipped_dependent_stop
run_test test_cancellation_after_steps_is_a_failure
run_test test_failed_gh_read_reports_stderr
run_test test_invalid_arguments_print_usage_without_gh
report_results
