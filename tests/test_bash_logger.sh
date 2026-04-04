#!/usr/bin/env bash
# ABOUTME: Tests for the bash-logger PreToolUse hook
# ABOUTME: Validates command logging to session.log

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/bash-logger.sh"

# Override setup for hook-specific env vars
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/logs"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

send_bash() {
    echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"},\"hook_event_name\":\"PreToolUse\"}" \
        | bash "$HOOK"
}

LOG_FILE=""
update_log() { LOG_FILE="$CLAUDE_SESSION_META_DIR/logs/session.log"; }

# ============================================================================

test_logs_bash_command() {
    update_log
    send_bash "npm run build"
    grep -q "BASH: npm run build" "$LOG_FILE" || { echo "  FAIL: command not in log"; return 1; }
}

test_logs_timestamp() {
    update_log
    send_bash "cargo test"
    grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] BASH:' "$LOG_FILE" \
        || { echo "  FAIL: timestamp format wrong"; return 1; }
}

test_skips_non_bash() {
    update_log
    echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"},"hook_event_name":"PreToolUse"}' \
        | bash "$HOOK"
    if [[ -f "$LOG_FILE" ]] && grep -q "BASH" "$LOG_FILE"; then
        echo "  FAIL: should not log Edit tool"
        return 1
    fi
}

test_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    update_log
    echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"hook_event_name":"PreToolUse"}' \
        | bash "$HOOK"
    if [[ -f "$LOG_FILE" ]] && grep -q "BASH" "$LOG_FILE"; then
        echo "  FAIL: should not log outside cs session"
        return 1
    fi
}

test_truncates_long_commands() {
    update_log
    local long_cmd
    long_cmd=$(python3 -c "print('x' * 300)")
    send_bash "$long_cmd"
    local logged_len
    logged_len=$(grep "BASH:" "$LOG_FILE" | head -1 | wc -c | tr -d ' ')
    if [[ "$logged_len" -gt 250 ]]; then
        echo "  FAIL: logged command too long ($logged_len chars)"
        return 1
    fi
    grep -q '\.\.\.' "$LOG_FILE" || { echo "  FAIL: should have ... suffix"; return 1; }
}

test_multiple_commands_appended() {
    update_log
    send_bash "npm run build"
    send_bash "npm test"
    send_bash "npm run lint"
    local count
    count=$(grep -c "BASH:" "$LOG_FILE")
    if [[ "$count" -ne 3 ]]; then
        echo "  FAIL: expected 3 log entries, got $count"
        return 1
    fi
}

test_never_blocks_exit_zero() {
    update_log
    send_bash "rm -rf /"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  FAIL: hook should always exit 0 (got $rc)"
        return 1
    fi
}

# ============================================================================

echo ""
echo "cs bash-logger tests"
echo "===================="
echo ""

run_test test_logs_bash_command
run_test test_logs_timestamp
run_test test_skips_non_bash
run_test test_skips_outside_session
run_test test_truncates_long_commands
run_test test_multiple_commands_appended
run_test test_never_blocks_exit_zero

report_results
