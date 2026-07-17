#!/usr/bin/env bash
# ABOUTME: Tests for iTerm2 awareness: the attention dock bounce fired by the
# ABOUTME: hooks through it2attention, and the doctor's integration-surface line

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + ambient env + a fake it2 toolkit that logs its argv instead
# of emitting terminal escapes. test_lib's setup exports CS_NO_ITERM2=1 for
# every suite; tests that expect a fire unset it explicitly.
_it2_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
    export IT2_LOG="$TEST_TMPDIR/it2.log"
    export CS_IT2_DIR="$TEST_TMPDIR/it2bin"
    export CS_IT2_TTY="$TEST_TMPDIR/tty-sink"
    mkdir -p "$CS_IT2_DIR"
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$IT2_LOG" > "$CS_IT2_DIR/it2attention"
    chmod +x "$CS_IT2_DIR/it2attention"
}

test_stop_hook_bounces_dock_in_iterm() {
    _it2_session "bounce"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "start" "turn end should start the bounce" || return 1
}

test_no_bounce_outside_iterm() {
    _it2_session "notiterm"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="Apple_Terminal"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: it2attention fired outside iTerm2: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_no_bounce_when_disabled() {
    _it2_session "killed"
    export CS_NO_ITERM2=1
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: CS_NO_ITERM2 must disable the bounce: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_missing_it2_tool_is_silent_and_harmless() {
    _it2_session "notool"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    rm -f "$CS_IT2_DIR/it2attention"
    local ec=0
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || ec=$?
    assert_eq "0" "$ec" "hook must not fail when it2 is absent" || return 1
}

test_prompt_hook_stops_the_bounce() {
    _it2_session "stopper"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "a new prompt should stop the bounce" || return 1
}

test_session_start_stops_the_bounce() {
    _it2_session "starter"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"source":"resume"}' | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "session start should stop a stale bounce" || return 1
}

test_doctor_reports_iterm2_surface() {
    _it2_session "docsess"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    local out
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "iTerm2" "doctor should mention iTerm2 inside it" || return 1
    assert_output_contains "$out" "attention bounce active" "it2 present reads as active" || return 1

    rm -f "$CS_IT2_DIR/it2attention"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "shell integration not installed" \
        "missing it2 reads as tab-color-only" || return 1

    export TERM_PROGRAM="Apple_Terminal"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$out" "iTerm2" "doctor stays silent outside iTerm2" || return 1
}

run_test test_stop_hook_bounces_dock_in_iterm
run_test test_no_bounce_outside_iterm
run_test test_no_bounce_when_disabled
run_test test_missing_it2_tool_is_silent_and_harmless
run_test test_prompt_hook_stops_the_bounce
run_test test_session_start_stops_the_bounce
run_test test_doctor_reports_iterm2_surface

report_results
