#!/usr/bin/env bash
# ABOUTME: Tests for the cs -msg cross-session mailbox: send validation,
# ABOUTME: task-to-queue delivery, read/log cursors, and the hook mail digest.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_SESSION_NAME="sender"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/sender"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    mkdir -p "$CS_SESSIONS_ROOT/receiver/.cs/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

INBOX() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"; }

test_send_writes_full_record() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    assert_file_exists "$(INBOX)" "inbox created" || return 1
    local line; line=$(head -1 "$(INBOX)")
    assert_eq "sender" "$(printf '%s' "$line" | jq -r .from)" "from is sender session" || return 1
    assert_eq "text" "$(printf '%s' "$line" | jq -r .kind)" "kind defaults to text" || return 1
    assert_eq "hello there" "$(printf '%s' "$line" | jq -r .body)" "body preserved" || return 1
    assert_eq "null" "$(printf '%s' "$line" | jq -r .ref)" "ref null" || return 1
    local id ts actor
    id=$(printf '%s' "$line" | jq -r .id); ts=$(printf '%s' "$line" | jq -r .ts); actor=$(printf '%s' "$line" | jq -r .actor)
    assert_output_contains "$id" "-" "id has epoch-pid-random shape" || return 1
    case "$ts" in ''|*[!0-9]*) echo "  ts not numeric: $ts"; return 1;; esac
    [ -n "$actor" ] || { echo "  actor empty"; return 1; }
}

test_send_from_outside_session_has_empty_from() {
    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR "$CS_BIN" -msg receiver "note" >/dev/null 2>&1 || return 1
    assert_eq "" "$(head -1 "$(INBOX)" | jq -r .from)" "from empty outside a session" || return 1
}

test_send_session_scoped_alias() {
    "$CS_BIN" receiver -msg "via alias" >/dev/null 2>&1 || return 1
    assert_file_contains "$(INBOX)" "via alias" "session-scoped arm sends" || return 1
}

test_send_joins_unquoted_multiword_body() {
    "$CS_BIN" -msg receiver hello there world >/dev/null 2>&1 || return 1
    assert_eq "hello there world" "$(head -1 "$(INBOX)" | jq -r .body)" "unquoted words joined" || return 1
}

test_send_rejects_unknown_target() {
    ! "$CS_BIN" -msg nosuch "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_slash_in_target() {
    ! "$CS_BIN" -msg "../receiver" "x" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -msg "a/b" "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_self() {
    mkdir -p "$CS_SESSIONS_ROOT/sender/.cs/local"
    ! "$CS_BIN" -msg sender "me to me" >/dev/null 2>&1 || return 1
}

test_send_rejects_bad_kind() {
    ! "$CS_BIN" -msg receiver -k bogus "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_ref_without_result() {
    ! "$CS_BIN" -msg receiver --ref some-id "x" >/dev/null 2>&1 || return 1
    "$CS_BIN" -msg receiver -k result --ref some-id "ok" >/dev/null 2>&1 || return 1
    assert_eq "some-id" "$(head -1 "$(INBOX)" | jq -r .ref)" "ref stored on result" || return 1
}

test_send_rejects_empty_and_oversize_body() {
    ! "$CS_BIN" -msg receiver "   " >/dev/null 2>&1 || return 1
    local big; big=$(printf 'a%.0s' $(seq 1 4097))
    ! "$CS_BIN" -msg receiver "$big" >/dev/null 2>&1 || return 1
    [ ! -f "$(INBOX)" ] || { echo "  inbox written on failed send"; return 1; }
}

RQUEUE() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/queue"; }

test_task_kind_lands_in_recipient_queue() {
    "$CS_BIN" -msg receiver -k task "review the tui diff" >/dev/null 2>&1 || return 1
    assert_file_exists "$(RQUEUE)" "queue file created" || return 1
    assert_file_contains "$(RQUEUE)" "review the tui diff" "task queued" || return 1
    assert_file_contains "$(INBOX)" "review the tui diff" "attribution recorded" || return 1
    assert_eq "task" "$(head -1 "$(INBOX)" | jq -r .kind)" "kind is task" || return 1
}

test_task_kind_clears_declined_flag() {
    touch "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined"
    "$CS_BIN" -msg receiver -k task "another" >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined" ] || { echo "  declined flag survived"; return 1; }
}

test_task_kind_rejects_multiline_body() {
    ! "$CS_BIN" -msg receiver -k task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    [ ! -f "$(RQUEUE)" ] || { echo "  queue written despite rejection"; return 1; }
    [ ! -f "$(INBOX)" ] || { echo "  inbox written despite rejection"; return 1; }
}

run_test test_send_writes_full_record
run_test test_send_from_outside_session_has_empty_from
run_test test_send_session_scoped_alias
run_test test_send_joins_unquoted_multiword_body
run_test test_send_rejects_unknown_target
run_test test_send_rejects_slash_in_target
run_test test_send_rejects_self
run_test test_send_rejects_bad_kind
run_test test_send_rejects_ref_without_result
run_test test_send_rejects_empty_and_oversize_body
run_test test_task_kind_lands_in_recipient_queue
run_test test_task_kind_clears_declined_flag
run_test test_task_kind_rejects_multiline_body

# Read receiver's mail: point the ambient session env at receiver.
_as_receiver() {
    CLAUDE_SESSION_NAME="receiver" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/receiver/.cs" \
    "$CS_BIN" "$@"
}

test_read_prints_unread_then_advances() {
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1
    "$CS_BIN" -msg receiver "second" >/dev/null 2>&1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "first" "first body shown" || return 1
    assert_output_contains "$out" "second" "second body shown" || return 1
    assert_output_contains "$out" "sender" "sender attributed" || return 1
    assert_output_contains "$out" "[text]" "kind tagged" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "No unread mail" "second read is empty" || return 1
}

test_log_reprints_everything_without_moving_cursors() {
    "$CS_BIN" -msg receiver "logged" >/dev/null 2>&1
    _as_receiver -msg >/dev/null 2>&1 || return 1
    local out; out=$(_as_receiver -msg log 2>&1) || return 1
    assert_output_contains "$out" "logged" "log shows read mail" || return 1
    assert_eq "1" "$(cat "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/seen")" "seen cursor unmoved by log" || return 1
}

test_read_outside_session_errors() {
    ! env -u CLAUDE_SESSION_META_DIR "$CS_BIN" -msg >/dev/null 2>&1 || return 1
}

test_read_strips_control_characters() {
    "$CS_BIN" -msg receiver "$(printf 'evil \033[2J clear')" >/dev/null 2>&1 || return 1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    case "$out" in *"$(printf '\033')"*) echo "  ESC survived rendering"; return 1;; esac
    assert_output_contains "$out" "evil" "body otherwise shown" || return 1
}

test_read_ignores_torn_final_line_until_completed() {
    "$CS_BIN" -msg receiver "whole" >/dev/null 2>&1
    printf '{"id":"x","ts":1,"from":"sender","actor":"a","kind":"text","body":"torn' \
        >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "whole" "complete line shown" || return 1
    assert_output_not_contains "$out" "torn" "torn line hidden" || return 1
    assert_eq "1" "$(cat "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/seen")" "cursor stops before torn line" || return 1
    printf '","ref":null}\n' >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "torn" "completed line delivered" || return 1
}

test_read_survives_corrupt_line_and_big_inbox() {
    mkdir -p "$CS_SESSIONS_ROOT/receiver/.cs/local/mail"
    printf 'not json at all\n' >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    local i=0
    while [ "$i" -lt 400 ]; do
        printf '{"id":"b%s","ts":1,"from":"s","actor":"a","kind":"text","body":"filler message %s padding padding padding padding padding padding padding padding padding padding padding padding padding padding","ref":null}\n' "$i" "$i"
        i=$((i + 1))
    done >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    local out rc=0
    out=$(_as_receiver -msg 2>&1) || rc=$?
    assert_eq "0" "$rc" "big inbox read exits 0 (no SIGPIPE 141)" || return 1
    assert_output_contains "$out" "filler message 399" "last message present" || return 1
}

run_test test_read_prints_unread_then_advances
run_test test_log_reprints_everything_without_moving_cursors
run_test test_read_outside_session_errors
run_test test_read_strips_control_characters
run_test test_read_ignores_torn_final_line_until_completed
run_test test_read_survives_corrupt_line_and_big_inbox

report_results
