#!/usr/bin/env bash
# ABOUTME: Tests for walk-away queue supervision: the failure counter, circuit
# ABOUTME: breakers at the drain choke point, the notification inbox, and digest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + exported ambient env, the shape the hooks expect.
_qs_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
}

_fail_once() {  # simulate one tool failure through the real hook
    echo '{"tool_name":"Bash","error":"boom"}' | bash "$HOOKS_DIR/tool-failure-logger.sh"
}

test_failure_counter_increments() {
    _qs_session "fc"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "first failure counts" || return 1
    _fail_once || return 1
    _fail_once || return 1
    assert_eq "3" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "count accumulates" || return 1
}

test_failure_counter_recovers_from_garbage() {
    _qs_session "fcg"
    printf 'not-a-number\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "garbage reads as 0, then increments" || return 1
}

test_failure_counter_still_logs_to_session_log() {
    _qs_session "fcl"
    _fail_once || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" "existing log behavior preserved" || return 1
}

_stop_turn() {
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh"
}

_arm_queue() {  # tasks...
    local qdir="$CLAUDE_SESSION_META_DIR/local" t
    for t in "$@"; do printf '%s\n' "$t" >> "$qdir/queue"; done
    printf 'armed\n' > "$qdir/queue.state"
}

_inbox() { cat "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl" 2>/dev/null; }

test_drain_writes_lifecycle_events() {
    _qs_session "lc"
    _arm_queue "task one" "task two"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "starting a walk-away run" "armed turn injects first task" || return 1
    assert_output_contains "$(_inbox)" '"event":"drain_started"' "arm records drain_started" || return 1
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "drain advances" || return 1
    assert_output_contains "$(_inbox)" '"event":"task_done"' "advance records task_done" || return 1
    assert_output_contains "$(_inbox)" '"task":"task one"' "task_done carries the task text" || return 1
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "all tasks complete" "drain finishes" || return 1
    assert_output_contains "$(_inbox)" '"event":"drain_finished"' "finish recorded" || return 1
}

test_task_text_with_quotes_survives_jq_append() {
    _qs_session "qq"
    _arm_queue 'fix the "flaky" test `now`' "second"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    _inbox | jq -e 'select(.event == "task_done") | .task == "fix the \"flaky\" test `now`"' >/dev/null \
        || { echo "  FAIL: quoted task text mangled in inbox"; return 1; }
}

test_failures_breaker_parks_the_drain() {
    _qs_session "fb"
    _arm_queue "will fail" "never reached"
    _stop_turn >/dev/null || return 1              # armed -> draining
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "circuit breaker" "debrief names the breaker" || return 1
    assert_output_contains "$out" "failures" "debrief names the reason" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
    assert_output_contains "$(_inbox)" '"event":"breaker_tripped"' "trip recorded" || return 1
    assert_output_contains "$(_inbox)" '"reason":"failures"' "trip reason recorded" || return 1
    # The remaining task is intact — nothing lost.
    grep -q "never reached" "$CLAUDE_SESSION_META_DIR/local/queue" \
        || { echo "  FAIL: remaining task lost on trip"; return 1; }
}

test_failures_reset_at_arm_and_each_advance() {
    _qs_session "fr"
    printf '4\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _arm_queue "one" "two" "three"
    _stop_turn >/dev/null || return 1              # arm resets stale count
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/failures" ] \
        || { echo "  FAIL: arm should reset the counter"; return 1; }
    printf '3\n' > "$CLAUDE_SESSION_META_DIR/local/failures"   # below threshold
    _stop_turn >/dev/null || return 1              # advance: no trip, reset again
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/failures" ] \
        || { echo "  FAIL: advance should reset the counter"; return 1; }
    assert_eq "draining" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "sub-threshold count does not trip" || return 1
}

test_context_breaker_parks_and_missing_ctx_never_trips() {
    _qs_session "cb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '91\n' > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "context" "context trip named" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "parked" || return 1

    _qs_session "cb2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    rm -f "$CLAUDE_SESSION_META_DIR/local/context-pct"
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "missing context-pct drains on" || return 1
}

test_five_hour_breaker_fresh_trips_stale_skips() {
    _qs_session "hb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 90\nstamped_at: %s\n' "$(date +%s)" \
        > "$CLAUDE_SESSION_META_DIR/local/limits"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "five" "fresh over-threshold trips" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "parked" || return 1

    _qs_session "hb2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 90\nstamped_at: %s\n' "$(( $(date +%s) - 3600 ))" \
        > "$CLAUDE_SESSION_META_DIR/local/limits"
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "stale stamp skips the breaker" || return 1
    assert_output_not_contains "$(_inbox)" "breaker_tripped" "silent skip: no inbox entry" || return 1
}

test_threshold_env_overrides() {
    _qs_session "ov"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '2\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=2 bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "override lowers the threshold" || return 1

    _qs_session "ov2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=banana bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "garbage override falls back to default 5" || return 1
}

test_defer_records_gate_declined() {
    _qs_session "gd"
    "$CS_BIN" -queue defer >/dev/null 2>&1 || { echo "  FAIL: defer exited non-zero"; return 1; }
    assert_output_contains "$(_inbox)" '"event":"gate_declined"' "defer writes the event" || return 1
    [ -f "$CLAUDE_SESSION_META_DIR/local/queue.declined" ] \
        || { echo "  FAIL: existing declined stamp must still be written"; return 1; }
}

test_queue_log_prints_events_oldest_first() {
    _qs_session "ql"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    local out
    out=$("$CS_BIN" -queue log 2>&1) || { echo "  FAIL: log exited non-zero"; return 1; }
    assert_output_contains "$out" "drain_started" "log shows the start" || return 1
    assert_output_contains "$out" "task_done" "log shows the task" || return 1
    assert_output_contains "$out" "only task" "log shows the task text" || return 1
    assert_output_contains "$out" "drain_finished" "log shows the finish" || return 1
    # oldest first: drain_started line appears before drain_finished line
    printf '%s\n' "$out" | awk '/drain_started/{s=NR} /drain_finished/{f=NR} END{exit !(s && f && s < f)}' \
        || { echo "  FAIL: log must print oldest-first"; return 1; }
    # log never advances the surfacing cursor
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/notifications.seen" ] \
        || { echo "  FAIL: log must not touch the cursor"; return 1; }
}

test_queue_log_empty_message() {
    _qs_session "qle"
    local out
    out=$("$CS_BIN" -queue log 2>&1) || return 1
    assert_output_contains "$out" "No queue activity recorded." "empty inbox message" || return 1
}

_prompt_turn() {  # prompt-text -> hook stdout
    printf '{"prompt": "%s"}' "$1" | bash "$HOOKS_DIR/scope-prompt.sh"
}

test_digest_surfaces_once_at_prompt() {
    _qs_session "dg"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1              # drain finishes: 3 events queued
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_contains "$out" "while you were away" "digest injected" || return 1
    assert_output_contains "$out" "1 task(s) done" "digest counts tasks" || return 1
    out=$(_prompt_turn "hello again") || return 1
    assert_output_not_contains "$out" "while you were away" "second prompt injects nothing" || return 1
}

test_digest_includes_breaker_reason() {
    _qs_session "dgb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '9\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _stop_turn >/dev/null || return 1              # trips
    local out
    out=$(_prompt_turn "hi") || return 1
    assert_output_contains "$out" "breaker tripped: failures" "digest names the trip" || return 1
}

test_declined_only_inbox_stays_silent_but_cursor_advances() {
    _qs_session "dgs"
    "$CS_BIN" -queue defer >/dev/null 2>&1 || return 1
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_not_contains "$out" "while you were away" "decline alone is not digest-worthy" || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/notifications.seen")" "cursor still advanced" || return 1
}

test_digest_on_code_prompt_splices_with_scope_block() {
    _qs_session "dgc"
    # A real git repo with a token-matching file so scope grounding has
    # something to inject (the splice needs both payloads present).
    (cd "$CLAUDE_SESSION_DIR" && git init -q && echo x > login.ts \
        && git add login.ts && git commit -qm init) 2>/dev/null
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    # A prompt that classifies positive for scope grounding (work verb).
    local out
    out=$(_prompt_turn "fix the login bug") || return 1
    assert_output_contains "$out" "while you were away" "digest present on code prompts" || return 1
    assert_output_contains "$out" "Scope (auto-grounded)" "scope block still present (spliced, not replaced)" || return 1
}

test_digest_at_session_start() {
    _qs_session "dgr"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    local out
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_contains "$out" "while you were away" "resume surfaces the digest" || return 1
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_not_contains "$out" "while you were away" "second start injects nothing" || return 1
}

test_partial_limits_skips_silently_without_stderr() {
    _qs_session "pl"
    _arm_queue "a" "b"
    _stop_turn >/dev/null 2>&1 || return 1
    printf 'stamped_at: %s\n' "$(date +%s)" > "$CLAUDE_SESSION_META_DIR/local/limits"
    local out err_file="$CLAUDE_SESSION_META_DIR/local/stderr.capture"
    out=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>"$err_file") || return 1
    assert_output_contains "$out" "next task" "partial limits drains on" || return 1
    [ ! -s "$err_file" ] || { echo "  FAIL: hook leaked stderr: $(cat "$err_file")"; return 1; }
}

test_ctx_threshold_env_override() {
    _qs_session "ovc"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '50\n' > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_CTX=40 bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "CTX override lowers the threshold" || return 1
    assert_output_contains "$out" "context" "trip names context" || return 1
}

test_5h_threshold_env_override() {
    _qs_session "ovh"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 40\nstamped_at: %s\n' "$(date +%s)" > "$CLAUDE_SESSION_META_DIR/local/limits"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_5H=30 bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "5H override lowers the threshold" || return 1
    assert_output_contains "$out" "five" "trip names five_hour" || return 1
}

run_test test_failure_counter_increments
run_test test_failure_counter_recovers_from_garbage
run_test test_failure_counter_still_logs_to_session_log
run_test test_drain_writes_lifecycle_events
run_test test_task_text_with_quotes_survives_jq_append
run_test test_failures_breaker_parks_the_drain
run_test test_failures_reset_at_arm_and_each_advance
run_test test_context_breaker_parks_and_missing_ctx_never_trips
run_test test_five_hour_breaker_fresh_trips_stale_skips
run_test test_threshold_env_overrides
run_test test_defer_records_gate_declined
run_test test_queue_log_prints_events_oldest_first
run_test test_queue_log_empty_message
run_test test_digest_surfaces_once_at_prompt
run_test test_digest_includes_breaker_reason
run_test test_declined_only_inbox_stays_silent_but_cursor_advances
run_test test_digest_on_code_prompt_splices_with_scope_block
run_test test_digest_at_session_start
run_test test_partial_limits_skips_silently_without_stderr
run_test test_ctx_threshold_env_override
run_test test_5h_threshold_env_override
report_results
