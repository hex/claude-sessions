#!/usr/bin/env bash
# ABOUTME: Tests for the cs -queue verb and the Stop-hook drain.
# ABOUTME: Covers add/list/rm/clear/start/defer and the outside-a-session error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

QFILE() { printf '%s' "$CLAUDE_SESSION_META_DIR/local/queue"; }

test_queue_add_appends_a_line() {
    "$CS_BIN" -queue add "first task" >/dev/null 2>&1
    "$CS_BIN" -queue add "second task" >/dev/null 2>&1
    assert_file_contains "$(QFILE)" "first task" "add writes the task" || return 1
    assert_eq "2" "$(grep -c . "$(QFILE)")" "two tasks queued" || return 1
}

test_queue_list_numbers_pending() {
    "$CS_BIN" -queue add "alpha" >/dev/null 2>&1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "1" "list is numbered" || return 1
    assert_output_contains "$out" "alpha" "list shows the task" || return 1
}

test_queue_rm_removes_by_index() {
    "$CS_BIN" -queue add "keep" >/dev/null 2>&1
    "$CS_BIN" -queue add "drop" >/dev/null 2>&1
    "$CS_BIN" -queue rm 2 >/dev/null 2>&1
    assert_file_contains "$(QFILE)" "keep" "kept task remains" || return 1
    assert_file_not_contains "$(QFILE)" "drop" "removed task is gone" || return 1
}

test_queue_clear_empties_and_resets_state() {
    "$CS_BIN" -queue add "x" >/dev/null 2>&1
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    "$CS_BIN" -queue clear >/dev/null 2>&1
    assert_file_not_exists "$(QFILE)" "queue file removed" || return 1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.state" "state reset" || return 1
}

test_queue_start_sets_armed() {
    "$CS_BIN" -queue start >/dev/null 2>&1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/queue.state" "armed" "start arms" || return 1
}

test_queue_defer_writes_declined_epoch() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "defer stamps declined" || return 1
}

test_queue_add_clears_declined() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    "$CS_BIN" -queue add "new" >/dev/null 2>&1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "add re-enables gating" || return 1
}

test_queue_requires_session() {
    unset CLAUDE_SESSION_META_DIR
    local out; if out=$("$CS_BIN" -queue add "x" 2>&1); then
        echo "  FAIL: expected non-zero outside a session"; return 1
    fi
    assert_output_contains "$out" "session" "explains it needs a session" || return 1
}

test_queue_add_via_session_scoped_arm() {
    # cs <session> -queue ... resolves the target from the name arg, not the
    # ambient env, so clear the env a launched session would export.
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    local sdir="$CS_SESSIONS_ROOT/scoped-session"
    mkdir -p "$sdir/.cs"
    "$CS_BIN" scoped-session -queue add "from outside" >/dev/null 2>&1
    assert_file_contains "$sdir/.cs/local/queue" "from outside" "session-scoped add lands in the named session" || return 1
}

run_test test_queue_add_appends_a_line
run_test test_queue_list_numbers_pending
run_test test_queue_rm_removes_by_index
run_test test_queue_clear_empties_and_resets_state
run_test test_queue_start_sets_armed
run_test test_queue_defer_writes_declined_epoch
run_test test_queue_add_clears_declined
run_test test_queue_requires_session
run_test test_queue_add_via_session_scoped_arm

QDIR() { printf '%s' "$CLAUDE_SESSION_META_DIR/local"; }
drain() { echo "${1:-{}}" | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null; }

test_drain_gates_when_idle_nonempty() {
    printf 'do the thing\n' > "$(QDIR)/queue"
    local out; out=$(drain)
    assert_output_contains "$out" '"block"' "idle+nonempty blocks to gate" || return 1
    assert_output_contains "$out" "AskUserQuestion" "gate tells agent to ask" || return 1
    assert_file_not_exists "$(QDIR)/queue.state" "gate does not change state" || return 1
}

test_drain_armed_injects_first_task_no_pop() {
    printf 'task one\ntask two\n' > "$(QDIR)/queue"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task one" "armed injects first task" || return 1
    assert_eq "draining" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "armed -> draining" || return 1
    assert_eq "2" "$(grep -c . "$(QDIR)/queue")" "no pop on first injection" || return 1
}

test_drain_armed_mentions_queue_list() {
    printf 'task one\ntask two\ntask three\n' > "$(QDIR)/queue"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "cs -queue list" \
        "mirror instruction must name cs -queue list (the message shows only the first task)" || return 1
}

test_drain_draining_pops_and_injects_next() {
    printf 'task one\ntask two\n' > "$(QDIR)/queue"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task two" "draining injects the next task" || return 1
    assert_file_contains "$(QDIR)/queue.done" "task one" "finished task logged to done" || return 1
    assert_eq "1" "$(grep -c . "$(QDIR)/queue")" "one task popped" || return 1
}

test_drain_empties_and_returns_idle() {
    printf 'last task\n' > "$(QDIR)/queue"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "complete" "announces completion" || return 1
    assert_eq "idle" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "returns to idle" || return 1
}

test_drain_declined_within_cooldown_falls_through() {
    printf 'queued\n' > "$(QDIR)/queue"
    printf '%s\n' "$(date +%s)" > "$(QDIR)/queue.declined"
    local out; out=$(drain)
    assert_output_not_contains "$out" "AskUserQuestion" "recent decline suppresses the gate" || return 1
}

test_drain_ignores_subagents() {
    printf 'queued\n' > "$(QDIR)/queue"
    local out; out=$(drain '{"agent_id":"sub-1"}')
    assert_output_not_contains "$out" "AskUserQuestion" "subagent stop never drains" || return 1
}

test_drain_gate_mentions_high_context() {
    printf 'queued\n' > "$(QDIR)/queue"
    printf '82\n' > "$(QDIR)/context-pct"
    local out; out=$(drain)
    assert_output_contains "$out" "82" "gate surfaces context %" || return 1
    assert_output_contains "$out" "compact" "gate recommends compaction when high" || return 1
}

run_test test_drain_gates_when_idle_nonempty
run_test test_drain_armed_injects_first_task_no_pop
run_test test_drain_armed_mentions_queue_list
run_test test_drain_draining_pops_and_injects_next
run_test test_drain_empties_and_returns_idle
run_test test_drain_declined_within_cooldown_falls_through
run_test test_drain_ignores_subagents
run_test test_drain_gate_mentions_high_context

test_statusline_stamps_context_pct() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline"
    echo '{"context_window":{"used_percentage":73.4}}' | bash "$sl" >/dev/null 2>&1 || true
    assert_file_exists "$(QDIR)/context-pct" "statusline stamps context-pct" || return 1
    assert_file_contains "$(QDIR)/context-pct" "73" "stamps truncated integer" || return 1
}

run_test test_statusline_stamps_context_pct

report_results
