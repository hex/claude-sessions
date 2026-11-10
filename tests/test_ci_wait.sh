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
    CI_INTERVAL=0
    CI_TMPDIR="${TMPDIR:-/tmp}"
    CI_REPO="$SCRIPT_DIR/.."
    CI_HEAD=$(git -C "$CI_REPO" rev-parse HEAD)
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
    _ci_reply "$(jq -cn --arg status "$1" --argjson attempt "$2" --argjson jobs "$3" --arg head "$CI_HEAD" \
        '{status:$status,attempt:$attempt,headSha:$head,jobs:$jobs}')"
}

_ci_success() { # attempt log
    _ci_run_json completed "$1" '[{"name":"bash","status":"completed","conclusion":"success","steps":[{}],"databaseId":101}]'
    _ci_reply "${2-$'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z job finished\n'}"
}

_ci_wait() {
    CI_RC=0
    (
        cd "$CI_REPO" || exit 4
        if [ "${CI_INTERVAL+x}" = x ]; then
            export CI_WAIT_INTERVAL="$CI_INTERVAL"
        else
            unset CI_WAIT_INTERVAL
        fi
        PATH="$TEST_TMPDIR/fakebin:$PATH" CI_FIXTURE="$TEST_TMPDIR" TMPDIR="$CI_TMPDIR" \
            bash "$CI_WAIT" "$@"
    ) > "$TEST_TMPDIR/stdout" 2> "$TEST_TMPDIR/stderr" || CI_RC=$?
    CI_OUT=$(cat "$TEST_TMPDIR/stdout")
    CI_ERR=$(cat "$TEST_TMPDIR/stderr")
}

_ci_calls() {
    assert_eq "$1" "$(cat "$TEST_TMPDIR/calls")" 'exact gh arguments'
}

_ci_log_lines() { # job text lines
    local job="$1" line
    shift
    for line in "$@"; do
        printf '%s\tUNKNOWN STEP\t2026-11-06T08:22:20Z %s\n' "$job" "$line"
    done
}

test_workflow_run_line_matches_the_log_reader() {
    local workflow="$SCRIPT_DIR/../.github/workflows/test.yml" run_line
    run_line=$(awk '
        /^  [^ ]/ { bash_job = ($0 == "  bash:") }
        bash_job && /^      - / { test_step = ($0 == "      - name: Run bash test suites") }
        bash_job && test_step && /^        run:/ { sub(/^        /, ""); print }
    ' "$workflow")
    assert_eq 'run: bash tests/run_all.sh' "$run_line" \
        "ci_wait.sh:70 needs the bash job's run_all log header" || return 1
}

test_pending_jobs_wait_until_every_conclusion_exists() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"bash","status":"completed","conclusion":"","steps":[],"databaseId":101}]'
    _ci_run_json in_progress 1 '[{"name":"bash","status":"in_progress","conclusion":"","steps":[],"databaseId":101}]'
    _ci_run_json in_progress 1 '[{"name":"bash","status":"completed","conclusion":"success","steps":[{}],"databaseId":101}]'
    _ci_success 1
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'completed success exits 0' || return 1
    assert_eq $'waiting: 1 of 1 jobs pending (attempt 1)\nwaiting: 0 of 1 jobs pending (attempt 1)\nsuccess\t1\tbash\nskipped tests: none' "$CI_OUT" 'waiting line prints only on change' || return 1
    assert_eq '' "$CI_ERR" 'success has no error output' || return 1
    assert_eq 5 "$(cat "$TEST_TMPDIR/count")" 'four status reads and one log read' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
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
    local conclusion
    for conclusion in cancelled failure skipped; do
        _ci_run_json completed 1 "$(jq -cn --arg conclusion "$conclusion" '[{name:"bash",status:"completed",conclusion:$conclusion,steps:[{}],databaseId:101},{name:"runner",status:"completed",conclusion:"cancelled",steps:[],databaseId:102}]')"
        _ci_wait 123
        assert_eq 1 "$CI_RC" 'started non-success job prevents rerun' || return 1
        assert_eq "$conclusion"$'\t1\tbash\ncancelled\t0\trunner' "$CI_OUT" 'mixed job table' || return 1
        assert_eq '' "$CI_ERR" 'verdict has no error output' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_failed_gh_read_reports_stderr() {
    local error
    for error in 'network unavailable' 'HTTP 404: Not Found (https://api.github.com/repos/example/repo/actions/runs/503)'; do
        _ci_fixture || return $?
        _ci_reply '' "$error" 1
        _ci_wait 123
        assert_eq 4 "$CI_RC" 'gh failure exits 4' || return 1
        assert_eq '' "$CI_OUT" 'no verdict from a failed call' || return 1
        assert_eq "ci_wait: gh run view 123 --json status,attempt,headSha,jobs failed: \"$error\"" "$CI_ERR" 'call and stderr quoted' || return 1
        _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]' || return 1
    done
}

test_server_error_on_a_read_is_retried() {
    _ci_fixture || return $?
    CI_INTERVAL=7
    cat > "$TEST_TMPDIR/fakebin/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$CI_FIXTURE/sleeps"
SLEEP
    chmod +x "$TEST_TMPDIR/fakebin/sleep"
    _ci_reply '' 'failed to get run: HTTP 500 (https://api.github.com/repos/example/repo/actions/runs/123?exclude_pull_requests=true)' 1
    _ci_run_json completed 1 '[{"name":"bash","status":"completed","conclusion":"success","steps":[{}],"databaseId":101}]'
    _ci_reply '' 'HTTP 503: Service Unavailable (https://api.github.com/repos/example/repo/actions/runs/123/logs)' 1
    _ci_reply $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z job finished\n'
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'transient server errors do not end the wait' || return 1
    assert_eq $'retrying: gh run view 123 --json status,attempt,headSha,jobs failed: "failed to get run: HTTP 500 (https://api.github.com/repos/example/repo/actions/runs/123?exclude_pull_requests=true)" (retry 1 of 2)\nsuccess\t1\tbash\nretrying: gh run view 123 --log failed: "HTTP 503: Service Unavailable (https://api.github.com/repos/example/repo/actions/runs/123/logs)" (retry 1 of 2)\nskipped tests: none' "$CI_OUT" 'each retry is announced before the verdict' || return 1
    assert_eq '' "$CI_ERR" 'a recovered read has no error output' || return 1
    assert_eq $'["7"]\n["7"]' "$(cat "$TEST_TMPDIR/sleeps")" 'each retry waits one poll interval' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--log"]'
}

test_persistent_server_error_exits_four_after_two_retries() {
    _ci_fixture || return $?
    local error='HTTP 502: Bad Gateway (https://api.github.com/repos/example/repo/actions/runs/123)'
    _ci_reply '' "$error" 1
    _ci_reply '' "$error" 1
    _ci_reply '' "$error" 1
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'a server error on every try exits 4' || return 1
    assert_eq "retrying: gh run view 123 --json status,attempt,headSha,jobs failed: \"$error\" (retry 1 of 2)
retrying: gh run view 123 --json status,attempt,headSha,jobs failed: \"$error\" (retry 2 of 2)" "$CI_OUT" 'both retries are announced' || return 1
    assert_eq "ci_wait: gh run view 123 --json status,attempt,headSha,jobs failed: \"$error\"" "$CI_ERR" 'the last failure is quoted' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_invalid_interval_prints_usage_without_gh() {
    _ci_fixture || return $?
    CI_INTERVAL=abc
    _ci_run_json in_progress 1 '[{"name":"bash","conclusion":"","steps":[]}]'
    _ci_wait 123
    assert_eq 2 "$CI_RC" 'invalid interval exits 2 before gh' || return 1
    assert_eq '' "$CI_OUT" 'invalid interval has no verdict' || return 1
    assert_eq 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' "$CI_ERR" 'invalid interval prints usage' || return 1
    _ci_calls ''
}

test_unavailable_temp_directory_is_a_command_error() {
    _ci_fixture || return $?
    CI_TMPDIR="$TEST_TMPDIR/nonexistent-dir"
    local expected_error
    expected_error=$(mktemp -d "$CI_TMPDIR/ci_wait.XXXXXX" 2>&1) && return 1
    expected_error=$(printf '%s\n' "$expected_error" | sed 's/ci_wait\.[[:alnum:]]\{6\}/ci_wait.XXXXXX/')
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'unavailable temporary directory exits 4' || return 1
    assert_eq '' "$CI_OUT" 'temporary directory failure has no verdict' || return 1
    assert_eq "$expected_error" "$(printf '%s\n' "$CI_ERR" | sed 's/ci_wait\.[[:alnum:]]\{6\}/ci_wait.XXXXXX/')" 'native mktemp diagnostic is preserved' || return 1
    _ci_calls ''
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

_ci_cancelled_build() { # attempt
    _ci_run_json completed "$1" '[{"name":"build (darwin-arm64, macos-latest, aarch64-apple-darwin)","status":"completed","conclusion":"cancelled","steps":[],"databaseId":101},{"name":"release","status":"completed","conclusion":"skipped","steps":[],"databaseId":102},{"name":"linux","status":"completed","conclusion":"success","steps":[{}],"databaseId":103}]'
}

test_zero_step_runner_cancellations_rerun() {
    _ci_fixture || return $?
    _ci_run_json completed 5 "$(jq -cn '[{"name":"rust (macos-latest)","status":"completed","conclusion":"cancelled","steps":[],"databaseId":101},{"name":"bash (macos-latest, 2/2)","status":"completed","conclusion":"cancelled","steps":[],"databaseId":102}] + [range(0;6) | {name:("job-" + tostring),status:"completed",conclusion:"success",steps:[range(0;5) | {}],databaseId:(200 + .)}]')"
    _ci_reply ''
    _ci_success 6
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'successful rerun exits 0' || return 1
    assert_eq $'cancelled\t0\trust (macos-latest)\ncancelled\t0\tbash (macos-latest, 2/2)\nsuccess\t5\tjob-0\nsuccess\t5\tjob-1\nsuccess\t5\tjob-2\nsuccess\t5\tjob-3\nsuccess\t5\tjob-4\nsuccess\t5\tjob-5\ninfrastructure: rerunning failed jobs (1 of 3)\nsuccess\t1\tbash\nskipped tests: none' "$CI_OUT" 'runner cancellations and one rerun' || return 1
    assert_eq '' "$CI_ERR" 'rerun has no error output' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_cancelled_build_and_skipped_release_rerun_after_stale_read() {
    _ci_fixture || return $?
    _ci_cancelled_build 1
    _ci_reply ''
    _ci_cancelled_build 1
    _ci_cancelled_build 1
    _ci_cancelled_build 1
    _ci_success 2
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'dependent skip reruns with its build' || return 1
    assert_eq $'cancelled\t0\tbuild (darwin-arm64, macos-latest, aarch64-apple-darwin)\nskipped\t0\trelease\nsuccess\t1\tlinux\ninfrastructure: rerunning failed jobs (1 of 3)\nwaiting: rerun requested, attempt 2 not started yet\nsuccess\t1\tbash\nskipped tests: none' "$CI_OUT" 'stale attempts print one waiting notice' || return 1
    assert_eq '' "$CI_ERR" 'stale read has no error output' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_rerun_wait_stops_on_the_twenty_first_stale_read() {
    _ci_fixture || return $?
    _ci_cancelled_build 1
    _ci_reply ''
    local i expected=$'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]'
    for ((i = 0; i < 31; i++)); do _ci_cancelled_build 1; done
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'stale rerun limit exits 4' || return 1
    assert_eq 'ci_wait: attempt never rose past 1 after the rerun' "$CI_ERR" 'stale rerun limit names the attempt' || return 1
    assert_eq $'cancelled\t0\tbuild (darwin-arm64, macos-latest, aarch64-apple-darwin)\nskipped\t0\trelease\nsuccess\t1\tlinux\ninfrastructure: rerunning failed jobs (1 of 3)\nwaiting: rerun requested, attempt 2 not started yet' "$CI_OUT" 'one notice and no extra rerun verdicts' || return 1
    assert_eq 23 "$(cat "$TEST_TMPDIR/count")" 'initial read, one rerun, exactly 21 stale reads' || return 1
    for ((i = 0; i < 21; i++)); do
        expected+=$'\n["run","view","123","--json","status,attempt,headSha,jobs"]'
    done
    _ci_calls "$expected"
}

test_each_rerun_gets_its_own_stale_read_limit() {
    _ci_fixture || return $?
    local attempt i expected_calls='' read_call='["run","view","123","--json","status,attempt,headSha,jobs"]'
    for attempt in 1 2; do
        _ci_cancelled_build "$attempt"
        _ci_reply ''
        expected_calls+="$read_call"$'\n["run","rerun","123","--failed"]\n'
        for ((i = 0; i < 15; i++)); do
            _ci_cancelled_build "$attempt"
            expected_calls+="$read_call"$'\n'
        done
    done
    _ci_success 3
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'two reruns with fifteen stale reads each succeed' || return 1
    local table=$'cancelled\t0\tbuild (darwin-arm64, macos-latest, aarch64-apple-darwin)\nskipped\t0\trelease\nsuccess\t1\tlinux'
    assert_eq "$table"$'\ninfrastructure: rerunning failed jobs (1 of 3)\nwaiting: rerun requested, attempt 2 not started yet\n'"$table"$'\ninfrastructure: rerunning failed jobs (2 of 3)\nwaiting: rerun requested, attempt 3 not started yet\nsuccess\t1\tbash\nskipped tests: none' "$CI_OUT" 'one waiting notice per rerun' || return 1
    assert_eq '' "$CI_ERR" 'separate stale waits have no error' || return 1
    assert_eq 36 "$(cat "$TEST_TMPDIR/count")" 'two reruns, thirty stale reads and the final verdict' || return 1
    _ci_calls "$expected_calls$read_call"$'\n["run","view","123","--log"]'
}

test_persistent_cancellations_exhaust_the_rerun_limit() {
    _ci_fixture || return $?
    _ci_cancelled_build 1
    _ci_reply ''
    _ci_cancelled_build 2
    _ci_reply ''
    _ci_cancelled_build 3
    _ci_wait 123 --max-reruns 2
    assert_eq 3 "$CI_RC" 'two retries exhausted exits 3' || return 1
    local table=$'cancelled\t0\tbuild (darwin-arm64, macos-latest, aarch64-apple-darwin)\nskipped\t0\trelease\nsuccess\t1\tlinux'
    assert_eq "$table"$'\ninfrastructure: rerunning failed jobs (1 of 2)\n'"$table"$'\ninfrastructure: rerunning failed jobs (2 of 2)\n'"$table" "$CI_OUT" 'each completed attempt prints its table' || return 1
    assert_eq '' "$CI_ERR" 'exhaustion has no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]\n["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_skipped_job_without_a_cancelled_job_fails() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"release","status":"completed","conclusion":"skipped","steps":[],"databaseId":101}]'
    _ci_wait 123
    assert_eq 1 "$CI_RC" 'skip alone is a failure' || return 1
    assert_eq $'skipped\t0\trelease' "$CI_OUT" 'skipped job table' || return 1
    assert_eq '' "$CI_ERR" 'skip has no command error' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_failed_rerun_reports_stderr() {
    local error
    for error in 'rerun denied' 'HTTP 500: Internal Server Error (https://api.github.com/repos/example/repo/actions/runs/123/rerun-failed-jobs)'; do
        _ci_fixture || return $?
        _ci_cancelled_build 1
        _ci_reply '' "$error" 1
        _ci_wait 123
        assert_eq 4 "$CI_RC" 'failed rerun exits 4' || return 1
        assert_eq "ci_wait: gh run rerun 123 --failed failed: \"$error\"" "$CI_ERR" 'failed rerun names the call' || return 1
        _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","rerun","123","--failed"]' || return 1
    done
}

test_invalid_rerun_limits_print_usage() {
    _ci_fixture || return $?
    local limit
    for limit in '' -1 x 99999999999999999999; do
        _ci_wait 123 --max-reruns "$limit"
        assert_eq 2 "$CI_RC" 'invalid limit exits 2' || return 1
        assert_eq 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' "$CI_ERR" 'invalid limit prints usage' || return 1
    done
    _ci_wait 123 --max-reruns
    assert_eq 2 "$CI_RC" 'missing limit exits 2' || return 1
    _ci_calls ''
}

test_skip_blocks_preserve_job_names_and_reasons() {
    _ci_fixture || return $?
    _ci_run_json completed 2 '[{"name":"bash (ubuntu-latest, 1/2)","status":"completed","conclusion":"success","steps":[{}],"databaseId":101},{"name":"bash (ubuntu-latest, 2/2)","status":"completed","conclusion":"success","steps":[{}],"databaseId":102}]'
    _ci_reply $'bash (ubuntu-latest, 1/2)\tUNKNOWN STEP\t2026-11-06T08:22:20.2359658Z skipped tests:\nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:20.2359658Z skipped tests:\nbash (ubuntu-latest, 1/2)\tUNKNOWN STEP\t2026-11-06T08:22:20.2363989Z   test_queue.sh: test_queue_write\nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:20.2363989Z   test_local_state.sh: test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac (gstat not on PATH)\nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:20.2364988Z   test_mod_mermaid.sh: test_mod_unit_tests_pass_under_the_engine_test_kit (claude not on PATH)\nbash (ubuntu-latest, 1/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z \nbash (ubuntu-latest, 1/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z ================================================================\nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z \nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z ================================================================'
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'skip reports do not change success' || return 1
    assert_eq $'success\t1\tbash (ubuntu-latest, 1/2)\nsuccess\t1\tbash (ubuntu-latest, 2/2)\nskipped tests (bash (ubuntu-latest, 1/2)):\n  test_queue.sh: test_queue_write\nskipped tests (bash (ubuntu-latest, 2/2)):\n  test_local_state.sh: test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac (gstat not on PATH)\n  test_mod_mermaid.sh: test_mod_unit_tests_pass_under_the_engine_test_kit (claude not on PATH)' "$CI_OUT" 'exact per-job skip blocks' || return 1
    assert_eq '' "$CI_ERR" 'log parsing has no error output' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_log_without_a_skip_block_reports_none() {
    _ci_fixture || return $?
    _ci_success 1 $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z ##[group]Run bash tests/run_all.sh\nbash\tUNKNOWN STEP\t2026-11-06T08:22:21Z \nbash\tUNKNOWN STEP\t2026-11-06T08:22:21Z ================================================================\nbash\tUNKNOWN STEP\t2026-11-06T08:22:21Z OK: all 44 suites passed\n'
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'no skips exits 0' || return 1
    assert_eq $'success\t1\tbash\nskipped tests: none' "$CI_OUT" 'explicit no-skips line' || return 1
    assert_eq '' "$CI_ERR" 'no error output' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_only_the_last_skip_block_in_each_job_is_reported() {
    _ci_fixture || return $?
    _ci_success 1 $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z skipped tests:\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z   test_fixture.sh: test_example\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z \nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z skipped tests:\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z   test_real.sh: test_actual\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z \nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z ================================================================'
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'last block exits 0' || return 1
    assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_real.sh: test_actual' "$CI_OUT" 'suite output is not the final skip list' || return 1
    assert_eq '' "$CI_ERR" 'no error output' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_failed_log_fetch_reports_stderr() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"bash","status":"completed","conclusion":"success","steps":[],"databaseId":101}]'
    _ci_reply '' 'logs unavailable' 1
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'missing logs exit 4' || return 1
    assert_eq $'success\t0\tbash' "$CI_OUT" 'no skip verdict without logs' || return 1
    assert_eq 'ci_wait: gh run view 123 --log failed: "logs unavailable"' "$CI_ERR" 'log call error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

_ci_git_range() {
    CI_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$CI_REPO/tests"
    git -C "$CI_REPO" init -q
    git -C "$CI_REPO" config user.name 'Test User'
    git -C "$CI_REPO" config user.email 'test@example.com'
    printf 'run_test test_existing\n' > "$CI_REPO/tests/test_checks.sh"
    git -C "$CI_REPO" add tests/test_checks.sh
    git -C "$CI_REPO" commit -qm 'Register existing check'
    git -C "$CI_REPO" tag base
    printf 'run_test test_new\n# run_test test_comment\n' >> "$CI_REPO/tests/test_checks.sh"
    git -C "$CI_REPO" add tests/test_checks.sh
    git -C "$CI_REPO" commit -qm 'Register another check'
    CI_HEAD=$(git -C "$CI_REPO" rev-parse HEAD)
    printf 'run_test test_after\n' >> "$CI_REPO/tests/test_checks.sh"
    git -C "$CI_REPO" add tests/test_checks.sh
    git -C "$CI_REPO" commit -qm 'Register a later check'
}

_ci_skip_log() { # suite test reason
    printf 'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z skipped tests:\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z   %s: %s%s\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z \nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z ================================================================\n' "$1" "$2" "${3- (tool not on PATH)}"
}

test_skipped_added_registration_stops_the_release() {
    _ci_fixture || return $?
    _ci_git_range
    _ci_success 1 "$(_ci_skip_log test_checks.sh test_new)"
    _ci_wait 123 --since base
    assert_eq 5 "$CI_RC" 'added check skipped exits 5' || return 1
    assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: test_new (tool not on PATH)\nskipped tests added since base:\n  test_checks.sh: test_new (bash)' "$CI_OUT" 'added skip names suite, check and job' || return 1
    assert_eq '' "$CI_ERR" 'skip violation has no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_skips_outside_the_run_commit_range_do_not_fail() {
    _ci_fixture || return $?
    _ci_git_range
    local name
    for name in test_existing test_after test_comment; do
        _ci_success 1 "$(_ci_skip_log test_checks.sh "$name")"
        _ci_wait 123 --since base
        assert_eq 0 "$CI_RC" "$name was not registered in the run range" || return 1
        assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: '"$name (tool not on PATH)" "$CI_OUT" 'skip list stays visible' || return 1
        assert_eq '' "$CI_ERR" 'no command error' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_added_names_are_matched_with_their_suite() {
    _ci_fixture || return $?
    _ci_git_range
    _ci_success 1 "$(_ci_skip_log test_other.sh test_new)"
    _ci_wait 123 --since base
    assert_eq 0 "$CI_RC" 'same name in another suite is not the added registration' || return 1
    assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_other.sh: test_new (tool not on PATH)' "$CI_OUT" 'unrelated suite skip is reported' || return 1
    assert_eq '' "$CI_ERR" 'no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_unknown_revision_reports_the_unresolved_name() {
    _ci_fixture || return $?
    _ci_git_range
    _ci_success 1
    _ci_wait 123 --since missing-revision
    assert_eq 2 "$CI_RC" 'unknown revision exits 2 before gh' || return 1
    assert_eq $'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]\nci_wait: cannot resolve revision "missing-revision": "fatal: Needed a single revision"' "$CI_ERR" 'usage and unresolved revision named' || return 1
    assert_eq '' "$CI_OUT" 'invalid revision has no verdict' || return 1
    _ci_calls ''
}

test_unknown_run_head_reports_the_unresolved_name() {
    _ci_fixture || return $?
    _ci_git_range
    CI_HEAD="missing-head"
    _ci_run_json in_progress 1 '[{"name":"bash","status":"in_progress","conclusion":"","steps":[],"databaseId":101}]'
    _ci_wait 123 --since base
    assert_eq 4 "$CI_RC" 'unknown head exits 4' || return 1
    assert_eq 'ci_wait: run head missing-head is not in this clone; git fetch and run again' "$CI_ERR" 'unresolved head named before waiting' || return 1
    assert_eq '' "$CI_OUT" 'missing head does not wait' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_range_verdict_is_independent_of_working_directory() {
    _ci_fixture || return $?
    _ci_git_range
    local directory repo="$CI_REPO"
    for directory in "$repo" "$repo/tests"; do
        CI_REPO="$directory"
        _ci_success 1 "$(_ci_skip_log test_checks.sh test_new)"
        _ci_wait 123 --since base
        assert_eq 5 "$CI_RC" 'added skip fails from root and tests directory' || return 1
        assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: test_new (tool not on PATH)\nskipped tests added since base:\n  test_checks.sh: test_new (bash)' "$CI_OUT" 'same output from both directories' || return 1
        assert_eq '' "$CI_ERR" 'no directory error' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_renamed_suites_count_as_added_regardless_of_diff_config() {
    _ci_fixture || return $?
    _ci_git_range
    git -C "$CI_REPO" tag before_rename
    git -C "$CI_REPO" mv tests/test_checks.sh tests/test_renamed.sh
    git -C "$CI_REPO" commit -qm 'Rename check suite'
    CI_HEAD=$(git -C "$CI_REPO" rev-parse HEAD)
    local renames
    for renames in true false; do
        git -C "$CI_REPO" config diff.renames "$renames"
        _ci_success 1 "$(_ci_skip_log test_renamed.sh test_existing)"
        _ci_wait 123 --since before_rename
        assert_eq 5 "$CI_RC" 'renamed suite counts as added with either diff setting' || return 1
        assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_renamed.sh: test_existing (tool not on PATH)\nskipped tests added since before_rename:\n  test_renamed.sh: test_existing (bash)' "$CI_OUT" 'renamed suite output' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_moved_and_removed_registrations_are_not_added() {
    _ci_fixture || return $?
    _ci_git_range
    git -C "$CI_REPO" tag before_move
    printf 'run_test test_new\n# run_test test_comment\nrun_test test_existing\n' > "$CI_REPO/tests/test_checks.sh"
    git -C "$CI_REPO" add tests/test_checks.sh
    git -C "$CI_REPO" commit -qm 'Move and remove registrations'
    CI_HEAD=$(git -C "$CI_REPO" rev-parse HEAD)
    local name
    for name in test_existing test_after; do
        _ci_success 1 "$(_ci_skip_log test_checks.sh "$name")"
        _ci_wait 123 --since before_move
        assert_eq 0 "$CI_RC" 'moved and removed registrations do not fail the range' || return 1
        assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: '"$name (tool not on PATH)" "$CI_OUT" 'skip is reported without an added-test verdict' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_invalid_attempt_numbers_are_rejected() {
    _ci_fixture || return $?
    _ci_run_json completed 1.5 '[{"name":"bash","status":"completed","conclusion":"success","steps":[],"databaseId":101}]'
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'fractional attempt exits 4' || return 1
    assert_eq '' "$CI_OUT" 'invalid attempt produces no verdict' || return 1
    assert_eq 'ci_wait: invalid run JSON from gh run view 123: ""' "$CI_ERR" 'invalid attempt is rejected before integer comparison' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_empty_or_garbled_logs_fail_closed() {
    _ci_fixture || return $?
    _ci_git_range
    local log
    for log in '' 'not a GitHub job log'; do
        _ci_success 1 "$log"
        _ci_wait 123 --since base
        assert_eq 4 "$CI_RC" 'empty or garbled logs exit 4' || return 1
        assert_eq $'success\t1\tbash' "$CI_OUT" 'no skip verdict without job logs' || return 1
        assert_eq 'ci_wait: log has no lines for job bash' "$CI_ERR" 'missing job named' || return 1
    done
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_crlf_logs_preserve_the_skip_verdict() {
    _ci_fixture || return $?
    _ci_git_range
    local log
    log=$(_ci_skip_log test_checks.sh test_new)
    _ci_success 1 "$log"
    _ci_wait 123 --since base
    assert_eq 5 "$CI_RC" 'LF skip exits 5' || return 1
    local expected=$'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: test_new (tool not on PATH)\nskipped tests added since base:\n  test_checks.sh: test_new (bash)'
    assert_eq "$expected" "$CI_OUT" 'LF skip output' || return 1
    _ci_success 1 "$(printf '%s\n' "$log" | awk '{printf "%s\r\n", $0}')"
    _ci_wait 123 --since base
    assert_eq 5 "$CI_RC" 'CRLF skip exits 5' || return 1
    assert_eq "$expected" "$CI_OUT" 'CRLF skip output' || return 1
    assert_eq '' "$CI_ERR" 'CRLF parsing emits no errors' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_each_completed_job_needs_log_lines() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"bash","status":"completed","conclusion":"success","steps":[{}],"databaseId":101},{"name":"rust","status":"completed","conclusion":"success","steps":[{}],"databaseId":102}]'
    _ci_reply $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z done\n'
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'missing job log exits 4' || return 1
    assert_eq $'success\t1\tbash\nsuccess\t1\trust' "$CI_OUT" 'job table without skip verdict' || return 1
    assert_eq 'ci_wait: log has no lines for job rust' "$CI_ERR" 'missing rust log named' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_stray_skip_text_without_the_verdict_rule_is_ignored() {
    _ci_fixture || return $?
    _ci_success 1 $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z skipped tests:\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z   test_fixture.sh: test_example\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z \nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z more suite output\nbash\tUNKNOWN STEP\t2026-11-06T08:22:20Z ================================================================'
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'stray header does not change verdict' || return 1
    assert_eq $'success\t1\tbash\nskipped tests: none' "$CI_OUT" 'only a block followed immediately by the rule counts' || return 1
    assert_eq '' "$CI_ERR" 'valid log has no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_run_all_log_requires_a_verdict() {
    _ci_fixture || return $?
    _ci_git_range
    _ci_run_json completed 1 '[{"name":"bash (ubuntu-latest, 2/2)","conclusion":"success","steps":[{}]},{"name":"bash (macos-latest, 2/2)","conclusion":"success","steps":[{}]}]'
    _ci_reply $'bash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:20Z ##[group]Run bash tests/run_all.sh\nbash (macos-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:20Z ##[group]Run bash tests/run_all.sh\nbash (ubuntu-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z skipped tests:\nbash (macos-latest, 2/2)\tUNKNOWN STEP\t2026-11-06T08:22:21Z skipped tests:\n'
    _ci_wait 123 --since base
    assert_eq 4 "$CI_RC" 'truncated run_all log exits 4' || return 1
    assert_eq 'ci_wait: log for job bash (ubuntu-latest, 2/2) has 0 skip lines; run_all verdict count is missing' "$CI_ERR" 'missing verdict names job and counts' || return 1
    assert_eq $'success\t1\tbash (ubuntu-latest, 2/2)\nsuccess\t1\tbash (macos-latest, 2/2)' "$CI_OUT" 'truncated logs print no skip verdict' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_run_all_verdict_count_must_match_the_skip_block() {
    _ci_fixture || return $?
    _ci_success 1 $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z ##[group]Run bash tests/run_all.sh\n'"$(_ci_skip_log test_checks.sh test_existing)"$'\nbash\tUNKNOWN STEP\t2026-11-06T08:22:22Z OK: all 44 suites passed, 2 tests skipped\n'
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'mismatched run_all skip count exits 4' || return 1
    assert_eq 'ci_wait: log for job bash has 1 skip lines; run_all verdict count is 2' "$CI_ERR" 'count mismatch names job and both counts' || return 1
    assert_eq $'success\t1\tbash' "$CI_OUT" 'count mismatch prints no skip verdict' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]' || return 1

    local shape log expected
    for shape in release test-tools test-checks; do
        _ci_fixture || return $?
        case "$shape" in
            release)
                _ci_run_json completed 2 '[{"name":"build (darwin-arm64, macos-latest, aarch64-apple-darwin)","conclusion":"success","steps":[{}]},{"name":"release","conclusion":"success","steps":[{}]}]'
                log=$(_ci_log_lines 'build (darwin-arm64, macos-latest, aarch64-apple-darwin)' 'done'
                    _ci_log_lines release 'done')
                expected=$'success\t1\tbuild (darwin-arm64, macos-latest, aarch64-apple-darwin)\nsuccess\t1\trelease\nskipped tests: none'
                ;;
            test-tools)
                _ci_run_json completed 1 '[{"name":"bash (ubuntu-latest, 2/2)","conclusion":"success","steps":[{}]},{"name":"bash (macos-latest, 2/2)","conclusion":"success","steps":[{}]},{"name":"rust (ubuntu-latest)","conclusion":"success","steps":[{}]}]'
                log=$(_ci_log_lines 'bash (ubuntu-latest, 2/2)' '##[group]Run bash tests/run_all.sh' \
                    'skipped tests:' '  test_local_state.sh: test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac (gstat not on PATH)' \
                    '' '================================================================' 'OK: all 44 suites passed, 1 test skipped'
                    _ci_log_lines 'bash (macos-latest, 2/2)' '##[group]Run bash tests/run_all.sh' \
                    'skipped tests:' '  test_mod_mermaid.sh: test_mod_unit_tests_pass_under_the_engine_test_kit (claude not on PATH)' \
                    '  test_suite_guards.sh: test_release_tags_match_changelog_headings' \
                    '' '================================================================' 'OK: all 44 suites passed, 2 tests skipped'
                    _ci_log_lines 'rust (ubuntu-latest)' 'done')
                expected=$'success\t1\tbash (ubuntu-latest, 2/2)\nsuccess\t1\tbash (macos-latest, 2/2)\nsuccess\t1\trust (ubuntu-latest)\nskipped tests (bash (ubuntu-latest, 2/2)):\n  test_local_state.sh: test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac (gstat not on PATH)\nskipped tests (bash (macos-latest, 2/2)):\n  test_mod_mermaid.sh: test_mod_unit_tests_pass_under_the_engine_test_kit (claude not on PATH)\n  test_suite_guards.sh: test_release_tags_match_changelog_headings'
                ;;
            test-checks)
                _ci_run_json completed 1 '[{"name":"bash (ubuntu-latest, 1/2)","conclusion":"success","steps":[{}]},{"name":"bash (macos-latest, 1/2)","conclusion":"success","steps":[{}]},{"name":"build-sync","conclusion":"success","steps":[{}]}]'
                log=$(_ci_log_lines 'bash (ubuntu-latest, 1/2)' '##[group]Run bash tests/run_all.sh' \
                    'skipped tests:' '  test_queue.sh: test_queue_write' \
                    '' '================================================================' 'OK: all 44 suites passed, 1 test skipped'
                    _ci_log_lines 'bash (macos-latest, 1/2)' '##[group]Run bash tests/run_all.sh' \
                    '' '================================================================' 'OK: all 44 suites passed'
                    _ci_log_lines build-sync 'done')
                expected=$'success\t1\tbash (ubuntu-latest, 1/2)\nsuccess\t1\tbash (macos-latest, 1/2)\nsuccess\t1\tbuild-sync\nskipped tests (bash (ubuntu-latest, 1/2)):\n  test_queue.sh: test_queue_write'
                ;;
        esac
        _ci_reply "$log"
        _ci_wait 123
        assert_eq 0 "$CI_RC" "$shape log with matching counts passes" || return 1
        assert_eq "$expected" "$CI_OUT" "$shape table and skips" || return 1
        assert_eq '' "$CI_ERR" "$shape log has no error" || return 1
        _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]' || return 1
    done
}

test_command_failure_inside_a_function_exits_four() {
    _ci_fixture || return $?
    _ci_git_range
    cat > "$TEST_TMPDIR/fakebin/comm" <<'COMM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$#" "$1" > "$CI_FIXTURE/comm-call"
printf 'comm: simulated failure\n' >&2
exit 5
COMM
    chmod +x "$TEST_TMPDIR/fakebin/comm"
    _ci_success 1
    _ci_wait 123 --since base
    assert_eq 4 "$CI_RC" 'command failure inside a function exits 4' || return 1
    assert_eq 'comm: simulated failure' "$CI_ERR" 'function command error is preserved' || return 1
    assert_eq $'success\t1\tbash\nskipped tests: none' "$CI_OUT" 'command failure cannot print an added-skip verdict' || return 1
    assert_eq $'3\n-23' "$(cat "$TEST_TMPDIR/comm-call")" 'failing comm receives the set comparison arguments' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_empty_since_revision_prints_usage_without_gh() {
    _ci_fixture || return $?
    _ci_success 1
    _ci_wait 123 --since ''
    assert_eq 2 "$CI_RC" 'empty since revision exits 2' || return 1
    assert_eq '' "$CI_OUT" 'empty revision has no verdict' || return 1
    assert_eq 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' "$CI_ERR" 'empty revision prints usage' || return 1
    _ci_calls ''
}

test_missing_since_revision_prints_usage_without_gh() {
    _ci_fixture || return $?
    _ci_wait 123 --since
    assert_eq 2 "$CI_RC" 'missing since revision exits 2' || return 1
    assert_eq '' "$CI_OUT" 'missing revision has no verdict' || return 1
    assert_eq 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' "$CI_ERR" 'missing revision prints usage' || return 1
    _ci_calls ''
}

test_zero_step_failure_prevents_a_cancellation_rerun() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"build","conclusion":"failure","steps":[]},{"name":"runner","conclusion":"cancelled","steps":[]}]'
    _ci_reply ''
    _ci_success 2
    _ci_wait 123
    assert_eq 1 "$CI_RC" 'zero-step failure exits 1 without rerunning' || return 1
    assert_eq $'failure\t0\tbuild\ncancelled\t0\trunner' "$CI_OUT" 'zero-step failure table' || return 1
    assert_eq '' "$CI_ERR" 'job failure has no command error' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_added_skip_without_a_reason_stops_the_release() {
    _ci_fixture || return $?
    _ci_git_range
    _ci_success 1 "$(_ci_skip_log test_checks.sh test_new '')"
    _ci_wait 123 --since base
    assert_eq 5 "$CI_RC" 'added skip without a reason exits 5' || return 1
    assert_eq $'success\t1\tbash\nskipped tests (bash):\n  test_checks.sh: test_new\nskipped tests added since base:\n  test_checks.sh: test_new (bash)' "$CI_OUT" 'reason-free skip names suite, check and job' || return 1
    assert_eq '' "$CI_ERR" 'reason-free skip has no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

test_completed_run_without_jobs_is_not_successful() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[]'
    _ci_reply ''
    _ci_wait 123
    assert_eq 1 "$CI_RC" 'completed run without jobs exits 1' || return 1
    assert_eq '' "$CI_OUT" 'empty job list has no success verdict' || return 1
    assert_eq '' "$CI_ERR" 'empty job list has no command error' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_job_without_steps_is_invalid() {
    _ci_fixture || return $?
    _ci_run_json completed 1 '[{"name":"bash","conclusion":"success"}]'
    _ci_reply $'bash\tUNKNOWN STEP\t2026-11-06T08:22:20Z job finished\n'
    _ci_wait 123
    assert_eq 4 "$CI_RC" 'missing steps key exits 4' || return 1
    assert_eq '' "$CI_OUT" 'invalid job has no verdict' || return 1
    assert_eq 'ci_wait: invalid run JSON from gh run view 123: ""' "$CI_ERR" 'invalid job diagnostic' || return 1
    _ci_calls '["run","view","123","--json","status,attempt,headSha,jobs"]'
}

test_default_poll_interval_is_thirty_seconds() {
    _ci_fixture || return $?
    unset CI_INTERVAL
    cat > "$TEST_TMPDIR/fakebin/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$CI_FIXTURE/sleeps"
SLEEP
    chmod +x "$TEST_TMPDIR/fakebin/sleep"
    _ci_run_json in_progress 1 '[{"name":"bash","conclusion":"","steps":[]}]'
    _ci_success 1
    _ci_wait 123
    assert_eq 0 "$CI_RC" 'default-interval wait succeeds' || return 1
    assert_eq '["30"]' "$(cat "$TEST_TMPDIR/sleeps")" 'default sleep receives exactly 30 seconds' || return 1
    assert_eq $'waiting: 1 of 1 jobs pending (attempt 1)\nsuccess\t1\tbash\nskipped tests: none' "$CI_OUT" 'default interval prints the wait and verdict' || return 1
    assert_eq '' "$CI_ERR" 'default interval has no command error' || return 1
    _ci_calls $'["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--json","status,attempt,headSha,jobs"]\n["run","view","123","--log"]'
}

run_test test_workflow_run_line_matches_the_log_reader
run_test test_pending_jobs_wait_until_every_conclusion_exists
run_test test_failure_and_skipped_dependent_stop
run_test test_cancellation_after_steps_is_a_failure
run_test test_failed_gh_read_reports_stderr
run_test test_server_error_on_a_read_is_retried
run_test test_persistent_server_error_exits_four_after_two_retries
run_test test_invalid_interval_prints_usage_without_gh
run_test test_unavailable_temp_directory_is_a_command_error
run_test test_invalid_arguments_print_usage_without_gh
run_test test_zero_step_runner_cancellations_rerun
run_test test_cancelled_build_and_skipped_release_rerun_after_stale_read
run_test test_rerun_wait_stops_on_the_twenty_first_stale_read
run_test test_each_rerun_gets_its_own_stale_read_limit
run_test test_persistent_cancellations_exhaust_the_rerun_limit
run_test test_skipped_job_without_a_cancelled_job_fails
run_test test_failed_rerun_reports_stderr
run_test test_invalid_rerun_limits_print_usage
run_test test_skip_blocks_preserve_job_names_and_reasons
run_test test_log_without_a_skip_block_reports_none
run_test test_only_the_last_skip_block_in_each_job_is_reported
run_test test_failed_log_fetch_reports_stderr
run_test test_skipped_added_registration_stops_the_release
run_test test_skips_outside_the_run_commit_range_do_not_fail
run_test test_added_names_are_matched_with_their_suite
run_test test_unknown_revision_reports_the_unresolved_name
run_test test_unknown_run_head_reports_the_unresolved_name
run_test test_invalid_attempt_numbers_are_rejected
run_test test_range_verdict_is_independent_of_working_directory
run_test test_renamed_suites_count_as_added_regardless_of_diff_config
run_test test_moved_and_removed_registrations_are_not_added
run_test test_empty_or_garbled_logs_fail_closed
run_test test_crlf_logs_preserve_the_skip_verdict
run_test test_each_completed_job_needs_log_lines
run_test test_stray_skip_text_without_the_verdict_rule_is_ignored
run_test test_run_all_log_requires_a_verdict
run_test test_run_all_verdict_count_must_match_the_skip_block
run_test test_command_failure_inside_a_function_exits_four
run_test test_empty_since_revision_prints_usage_without_gh
run_test test_missing_since_revision_prints_usage_without_gh
run_test test_zero_step_failure_prevents_a_cancellation_rerun
run_test test_added_skip_without_a_reason_stops_the_release
run_test test_completed_run_without_jobs_is_not_successful
run_test test_job_without_steps_is_invalid
run_test test_default_poll_interval_is_thirty_seconds
report_results
