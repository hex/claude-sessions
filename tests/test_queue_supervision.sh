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
    # The drain answers only the lead's Stop: model a cs-launched conversation.
    export CS_LEAD_PID=$$ CLAUDE_PID=$$
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

# The counter is written through a uniquely named temp file, so a leftover at
# the fixed name failures.tmp does not stop the count.
test_failure_counter_ignores_a_stale_tmp() {
    _qs_session "fct"
    mkdir "$CLAUDE_SESSION_META_DIR/local/failures.tmp"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures" 2>/dev/null)" \
        "the failure counts past a stale failures.tmp" || return 1
}

test_failure_counter_still_logs_to_session_log() {
    _qs_session "fcl"
    _fail_once || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" "existing log behavior preserved" || return 1
}

_stop_turn() {  # [hook input JSON]
    local input='{}'
    [ "$#" -eq 0 ] || input="$1"
    printf '%s\n' "$input" | bash "$HOOKS_DIR/stop-blocks.sh"
}

# A Stop whose final assistant message is the given text, as Claude Code
# hands it over in last_assistant_message.
_stop_turn_saying() {  # final message text
    _stop_turn "$(jq -nc --arg m "$1" '{hook_event_name: "Stop", last_assistant_message: $m}')"
}

_qlen() {
    local f n=0
    for f in "$CLAUDE_SESSION_META_DIR/local/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

_arm_queue() {  # tasks...
    local qdir="$CLAUDE_SESSION_META_DIR/local" t i=0
    mkdir -p "$qdir/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$qdir/queue/$(printf '%010d' "$i")-seed"
    done
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
    grep -q "never reached" "$CLAUDE_SESSION_META_DIR/local/queue"/* \
        || { echo "  FAIL: remaining task lost on trip"; return 1; }
}

test_breaker_parks_the_drain_past_a_stale_state_tmp() {
    _qs_session "fbt"
    _arm_queue "will fail" "never reached"
    _stop_turn >/dev/null || return 1              # armed -> draining
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    mkdir "$CLAUDE_SESSION_META_DIR/local/queue.state.tmp"
    _stop_turn >/dev/null || true
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" \
        "the trip parks the queue past a stale queue.state.tmp" || return 1
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

# A task whose turn tripped the failure breaker did not succeed: it stays at
# the head of the queue and is never logged done.
test_failures_breaker_keeps_the_failed_task_queued() {
    _qs_session "fk"
    _arm_queue "will fail" "never reached"
    _stop_turn >/dev/null || return 1              # armed -> draining
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _stop_turn >/dev/null || return 1
    assert_eq "2" "$(_qlen)" "the failed task is still queued" || return 1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.done" "nothing is logged done" || return 1
    assert_output_not_contains "$(_inbox)" '"event":"task_done"' "no task_done for a failed task" || return 1
    assert_output_contains "$(_inbox)" '"remaining":2' "the trip counts the failed task as remaining" || return 1
}

# The last task gets the breaker too: an emptied queue is not "all tasks
# complete" when the turn that emptied it failed.
test_failures_breaker_trips_on_the_last_task() {
    _qs_session "fl"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1              # armed -> draining
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "circuit breaker tripped" "the last task trips the breaker" || return 1
    assert_output_not_contains "$out" "all tasks complete" "a failed last task is not completion" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
    assert_eq "1" "$(_qlen)" "the failed last task is still queued" || return 1
    assert_output_not_contains "$(_inbox)" '"event":"drain_finished"' "no drain_finished" || return 1
    out=$("$CS_BIN" -queue list 2>&1) || return 1
    assert_eq "Queued (1)
  1. only task" "$out" "cs -queue list shows the task queued and nothing done" || return 1
}

# The model can report a task it could not complete with a line of its own;
# the turn then parks the run with that task still queued.
test_reported_failure_parks_with_the_task_queued() {
    _qs_session "rf"
    _arm_queue "deploy it" "after"
    local out
    out=$(_stop_turn) || return 1                  # armed -> draining
    assert_output_contains "$out" "cs-task-failed" "the hand-out names the failure line" || return 1
    out=$(_stop_turn_saying "Could not deploy: credentials are missing.
cs-task-failed") || return 1
    assert_output_contains "$out" "reported the task as not completed" "the debrief names the report" || return 1
    assert_output_not_contains "$out" "next task" "the next task is not handed out" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
    assert_eq "2" "$(_qlen)" "the reported task is still queued" || return 1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.done" "nothing is logged done" || return 1
    assert_output_contains "$(_inbox)" '"reason":"task_failed"' "the report is recorded" || return 1
}

test_reported_failure_on_the_last_task_is_not_completion() {
    _qs_session "rl"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1              # armed -> draining
    local out
    out=$(_stop_turn_saying "Blocked.
cs-task-failed") || return 1
    assert_output_not_contains "$out" "all tasks complete" "a reported failure is not completion" || return 1
    assert_eq "1" "$(_qlen)" "the reported task is still queued" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
}

# A model asked for a line reading exactly cs-task-failed often writes it as a
# markdown code span; that line is the same report.
test_reported_failure_as_a_code_span_parks() {
    _qs_session "rc"
    _arm_queue "first" "second"
    _stop_turn >/dev/null || return 1              # armed -> draining
    _stop_turn_saying "Blocked on missing credentials.

\`cs-task-failed\`" >/dev/null || return 1
    assert_eq "2" "$(_qlen)" "the reported task is still queued" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
}

# Positive control: only a whole line is the report. A message that mentions
# the marker inside a sentence advances as before.
test_marker_inside_a_line_is_not_a_report() {
    _qs_session "rn"
    _arm_queue "first" "second"
    _stop_turn >/dev/null || return 1              # armed -> draining
    local out
    out=$(_stop_turn_saying "Done. No need for cs-task-failed here.") || return 1
    assert_output_contains "$out" "next task" "the drain advances" || return 1
    assert_eq "1" "$(_qlen)" "the finished task is popped" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/queue.done" "^first$" "and logged done" || return 1
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
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=2 bash "$HOOKS_DIR/stop-blocks.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "override lowers the threshold" || return 1

    _qs_session "ov2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=banana bash "$HOOKS_DIR/stop-blocks.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "garbage override falls back to default 5" || return 1
}

# Lay down an inbox whose last line lost its newline to an interrupted write,
# and prove the fixture is genuinely torn before anything appends to it.
_torn_inbox() {
    local inbox="$CLAUDE_SESSION_META_DIR/local/notifications.jsonl"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    # The surviving record uses an event neither writer under test emits here,
    # so a passing assertion cannot be satisfied by the fixture alone.
    printf '{"ts":1,"event":"breaker_tripped","reason":"seed"}\n' >  "$inbox"
    printf '{"ts":2,"event":"task_done","task":"alpha"}'          >> "$inbox"
    [ -n "$(tail -c 1 "$inbox")" ] \
        || { echo "  FAIL: fixture is not torn, so the test cannot reach the splice"; return 1; }
}

# A killed writer leaves the last line unterminated, so the next bare `>>`
# lands on it and the tolerant `fromjson? // empty` reader drops the joined
# line whole — losing the torn record AND the intact one written after it.
# timeline.jsonl's writers repair the tail first, and so must the drain, which
# appends to notifications.jsonl.
# Read the inbox the way _queue_log and the digest do: raw lines through
# `fromjson? // empty`, which drops a line holding two spliced records. A plain
# `jq .` would hide the defect — jq parses concatenated objects as a stream and
# reports both events from the very line the real readers throw away.
_inbox_events() { _inbox | jq -rR 'fromjson? // empty | .event' 2>/dev/null; }

test_drain_does_not_splice_onto_a_torn_inbox() {
    _qs_session "torna"
    _arm_queue "task one"
    _torn_inbox || return 1
    _stop_turn >/dev/null || return 1
    local seen; seen=$(_inbox_events)
    assert_output_contains "$seen" "drain_started" \
        "the drain's own event must survive the torn tail" || return 1
    assert_output_contains "$seen" "breaker_tripped" \
        "the intact record before the torn one must still parse" || return 1
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

# A gate_declined record is one an inbox can still hold from before the queue's
# start moved to the cs mod's band; the digest does not report it.
test_declined_only_inbox_stays_silent_but_cursor_advances() {
    _qs_session "dgs"
    printf '{"ts":1750000000,"event":"gate_declined"}\n' > "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl"
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_not_contains "$out" "while you were away" "decline alone is not digest-worthy" || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/notifications.seen")" "cursor still advanced" || return 1
}

# An inbox line that is valid JSON but not an object is skipped like one that
# does not parse: the notifications beside it are still shown, and the cursor
# is spent only on a digest that was shown.
_inbox_with_non_objects() {
    printf '%s\n' '{"ts":1,"event":"task_done","task":"a"}' '[1]' '7' '{"ts":2,"event":"drain_finished"}' \
        > "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl"
}

test_digest_at_prompt_skips_a_line_that_is_not_an_object() {
    _qs_session "dgn"
    _inbox_with_non_objects
    local out
    out=$(_prompt_turn "hello" | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_eq "1" "$(grep -cxF 'cs queue while you were away: 1 task(s) done; drain finished. Run cs -queue log for detail.' <<< "$out")" \
        "the notifications beside the bad lines are shown" || return 1
    assert_eq "4" "$(cat "$CLAUDE_SESSION_META_DIR/local/notifications.seen")" \
        "the cursor moves past the lines the shown digest covered" || return 1
}

test_digest_at_session_start_skips_a_line_that_is_not_an_object() {
    _qs_session "dgrn"
    _inbox_with_non_objects
    local out
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh" | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_eq "1" "$(grep -cxF -- '--- cs queue while you were away: 1 task(s) done; drain finished. Run cs -queue log for detail.' <<< "$out")" \
        "the notifications beside the bad lines are shown" || return 1
    assert_eq "4" "$(cat "$CLAUDE_SESSION_META_DIR/local/notifications.seen")" \
        "the cursor moves past the lines the shown digest covered" || return 1
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

test_killed_prompt_hook_does_not_swallow_the_digest() {
    _qs_session "dgk"
    (cd "$CLAUDE_SESSION_DIR" && git init -q && echo x > login.ts \
        && git add login.ts && git commit -qm init) 2>/dev/null
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1

    # Stall the hook PAST the point where the digest is built. git is the first
    # command the grounded scan runs, and only a positively-classified prompt
    # gets that far, so a git that blocks parks the hook exactly where the 3s
    # UserPromptSubmit timeout parks it in production.
    local stub="$CLAUDE_SESSION_DIR/stub" marker="$CLAUDE_SESSION_META_DIR/local/stub-reached"
    mkdir -p "$stub"
    cat > "$stub/git" <<'STUB'
#!/bin/sh
printf 'reached\n' > "$STUB_MARKER"
sleep 5
STUB
    chmod +x "$stub/git"
    rm -f "$marker"

    printf '{"prompt": "fix the login bug"}' \
        | STUB_MARKER="$marker" PATH="$stub:$PATH" bash "$HOOKS_DIR/scope-prompt.sh" \
        >/dev/null 2>&1 &
    local pid=$!
    # The hook reaches the stub later on a loaded machine; wait for the stub's
    # marker, then kill the hook while the stub holds it there.
    wait_until test -f "$marker"
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pkill -f "$stub/git" 2>/dev/null
    [ -f "$marker" ] || { echo "  FAIL: hook never reached the grounded scan"; return 1; }

    # The notifications that run never printed must still be pending.
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_contains "$out" "while you were away" \
        "a killed run must leave the digest for the next prompt" || return 1
    assert_output_contains "$out" "1 task(s) done" "and leave it intact" || return 1
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

# The surface-once cursor is written through a uniquely named temp file: a
# leftover notifications.seen.tmp must not make every prompt repeat the digest.
test_digest_cursor_advances_past_a_stale_tmp_at_prompt() {
    _qs_session "dgt"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    mkdir "$CLAUDE_SESSION_META_DIR/local/notifications.seen.tmp"
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_contains "$out" "while you were away" "digest injected" || return 1
    out=$(_prompt_turn "hello again") || return 1
    assert_output_not_contains "$out" "while you were away" "second prompt injects nothing" || return 1
}

test_digest_cursor_advances_past_a_stale_tmp_at_session_start() {
    _qs_session "dgrt"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    mkdir "$CLAUDE_SESSION_META_DIR/local/notifications.seen.tmp"
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
    out=$(echo '{}' | bash "$HOOKS_DIR/stop-blocks.sh" 2>"$err_file") || return 1
    assert_output_contains "$out" "next task" "partial limits drains on" || return 1
    [ ! -s "$err_file" ] || { echo "  FAIL: hook leaked stderr: $(cat "$err_file")"; return 1; }
}

test_ctx_threshold_env_override() {
    _qs_session "ovc"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '50\n' > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_CTX=40 bash "$HOOKS_DIR/stop-blocks.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "CTX override lowers the threshold" || return 1
    assert_output_contains "$out" "context" "trip names context" || return 1
}

test_5h_threshold_env_override() {
    _qs_session "ovh"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 40\nstamped_at: %s\n' "$(date +%s)" > "$CLAUDE_SESSION_META_DIR/local/limits"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_5H=30 bash "$HOOKS_DIR/stop-blocks.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "5H override lowers the threshold" || return 1
    assert_output_contains "$out" "five" "trip names five_hour" || return 1
}

run_test test_failure_counter_increments
run_test test_failure_counter_recovers_from_garbage
run_test test_failure_counter_ignores_a_stale_tmp
run_test test_failure_counter_still_logs_to_session_log
run_test test_drain_writes_lifecycle_events
run_test test_task_text_with_quotes_survives_jq_append
run_test test_failures_breaker_parks_the_drain
run_test test_breaker_parks_the_drain_past_a_stale_state_tmp
run_test test_failures_reset_at_arm_and_each_advance
run_test test_failures_breaker_keeps_the_failed_task_queued
run_test test_failures_breaker_trips_on_the_last_task
run_test test_reported_failure_parks_with_the_task_queued
run_test test_reported_failure_on_the_last_task_is_not_completion
run_test test_reported_failure_as_a_code_span_parks
run_test test_marker_inside_a_line_is_not_a_report
run_test test_context_breaker_parks_and_missing_ctx_never_trips
run_test test_five_hour_breaker_fresh_trips_stale_skips
run_test test_threshold_env_overrides
run_test test_drain_does_not_splice_onto_a_torn_inbox
run_test test_queue_log_prints_events_oldest_first
run_test test_queue_log_empty_message
run_test test_digest_surfaces_once_at_prompt
run_test test_digest_includes_breaker_reason
run_test test_declined_only_inbox_stays_silent_but_cursor_advances
run_test test_digest_at_prompt_skips_a_line_that_is_not_an_object
run_test test_digest_at_session_start_skips_a_line_that_is_not_an_object
run_test test_digest_on_code_prompt_splices_with_scope_block
run_test test_killed_prompt_hook_does_not_swallow_the_digest
run_test test_digest_at_session_start
run_test test_digest_cursor_advances_past_a_stale_tmp_at_prompt
run_test test_digest_cursor_advances_past_a_stale_tmp_at_session_start
run_test test_partial_limits_skips_silently_without_stderr
test_build_digest_fn_in_sync_across_hooks() {
    # _build_digest and _commit_digest are duplicated verbatim between the two
    # injection hooks by the standalone-hook law; this diff is the machine check
    # that the copies have not drifted (the sanctioned-copy pattern used for
    # manifest arrays). They are one mechanism split in two — a hook that built
    # the digest with one copy and retired the cursor with a stale other would
    # lose notifications exactly the way the split exists to prevent.
    local fn a b
    for fn in _build_digest _commit_digest; do
        a=$(awk "/^$fn\\(\\)/,/^\\}/" "$HOOKS_DIR/scope-prompt.sh")
        b=$(awk "/^$fn\\(\\)/,/^\\}/" "$HOOKS_DIR/session-start.sh")
        [ -n "$a" ] || { echo "  FAIL: $fn not found in scope-prompt.sh"; return 1; }
        [ -n "$b" ] || { echo "  FAIL: $fn not found in session-start.sh"; return 1; }
        if [ "$a" != "$b" ]; then
            echo "  FAIL: $fn bodies differ between the two hooks"
            return 1
        fi
    done
}

run_test test_ctx_threshold_env_override
run_test test_5h_threshold_env_override
run_test test_build_digest_fn_in_sync_across_hooks

# An encrypted session keeps its queue, inbox and failure counter behind
# .cs/private; the context and limit readings stay in .cs/local, since they are
# numbers the status line writes. The drain must read each from its own place.
_qs_private() {
    mkdir -p "$TEST_TMPDIR/vault-$CLAUDE_SESSION_NAME/private"
    ln -s "$TEST_TMPDIR/vault-$CLAUDE_SESSION_NAME/private" "$CLAUDE_SESSION_META_DIR/private"
    _mark_hand_made_vault "$(dirname "$CLAUDE_SESSION_META_DIR")"
    PRIV="$TEST_TMPDIR/vault-$CLAUDE_SESSION_NAME/private"
}
_arm_private_queue() {  # tasks...
    local t i=0
    mkdir -p "$PRIV/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$PRIV/queue/$(printf '%010d' "$i")-seed"
    done
    printf 'armed\n' > "$PRIV/queue.state"
}

test_private_failure_counter_counts_in_the_vault() {
    _qs_session "pfc"
    _qs_private
    _fail_once || return 1
    assert_eq "1" "$(cat "$PRIV/failures")" "the counter is in the vault" || return 1
    assert_not_exists "$CLAUDE_SESSION_META_DIR/local/failures" "no plaintext counter" || return 1
}

test_private_drain_hands_tasks_and_records_in_the_vault() {
    _qs_session "pdr"
    _qs_private
    _arm_private_queue "sealed one" "sealed two"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "sealed one" "the vault's first task is handed over" || return 1
    assert_eq "draining" "$(cat "$PRIV/queue.state")" "state kept in the vault" || return 1
    _stop_turn >/dev/null || return 1
    assert_file_contains "$PRIV/queue.done" "sealed one" "done log in the vault" || return 1
    assert_file_contains "$PRIV/notifications.jsonl" "sealed one" "inbox in the vault" || return 1
    local f
    for f in queue queue.state queue.done notifications.jsonl failures; do
        assert_not_exists "$CLAUDE_SESSION_META_DIR/local/$f" "no plaintext $f" || return 1
    done
}

test_private_drain_reads_context_from_local() {
    _qs_session "pcx"
    _qs_private
    _arm_private_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '91\n' > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "circuit breaker" "the context reading in .cs/local trips it" || return 1
    assert_eq "idle" "$(cat "$PRIV/queue.state")" "parked in the vault" || return 1
}

test_private_digest_reads_the_vault_inbox() {
    _qs_session "pdg"
    _qs_private
    _arm_private_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_contains "$out" "while you were away" "the prompt digest reads the vault" || return 1
    assert_file_exists "$PRIV/notifications.seen" "the cursor is in the vault" || return 1
    _arm_private_queue "second"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_contains "$out" "while you were away" "the start digest reads the vault" || return 1
    assert_not_exists "$CLAUDE_SESSION_META_DIR/local/notifications.seen" "no plaintext cursor" || return 1
}

test_locked_vault_queue_hooks_write_nothing() {
    _qs_session "plk"
    ln -s "$TEST_TMPDIR/unmounted-plk/private" "$CLAUDE_SESSION_META_DIR/private"
    _fail_once || return 1
    _stop_turn >/dev/null || return 1
    _prompt_turn "hello" >/dev/null || return 1
    local f
    for f in queue queue.state failures notifications.jsonl notifications.seen; do
        assert_not_exists "$CLAUDE_SESSION_META_DIR/local/$f" "no plaintext $f" || return 1
    done
}

run_test test_private_failure_counter_counts_in_the_vault
run_test test_private_drain_hands_tasks_and_records_in_the_vault
run_test test_private_drain_reads_context_from_local
run_test test_private_digest_reads_the_vault_inbox
run_test test_locked_vault_queue_hooks_write_nothing
report_results
