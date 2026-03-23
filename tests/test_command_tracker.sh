#!/usr/bin/env bash
# ABOUTME: Tests for the command-tracker PostToolUse hook
# ABOUTME: Validates command capture, filtering, deduplication, secret scrubbing, and categorization

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/command-tracker.sh"
TEST_TMPDIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{logs,memory,artifacts}
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        echo "  File contents: $(cat "$file" 2>/dev/null | head -10)"
        return 1
    fi
}

assert_file_not_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should not contain '$pattern'}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        return 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [ ! -f "$path" ]; then
        echo "  FAIL: $msg"
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [ -f "$path" ]; then
        echo "  FAIL: $msg"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    setup
    if "$test_name" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
    teardown
}

# Helper: send a Bash tool use to the hook
send_bash_command() {
    local cmd="$1"
    echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"},\"tool_response\":{},\"hook_event_name\":\"PostToolUse\"}" \
        | bash "$HOOK"
}

COMMANDS_FILE=""
update_commands_file() {
    COMMANDS_FILE="$CLAUDE_SESSION_META_DIR/commands.md"
}

# ============================================================================
# Tests
# ============================================================================

test_captures_npm_build() {
    update_commands_file
    send_bash_command "npm run build"
    assert_file_exists "$COMMANDS_FILE" "commands.md should be created" || return 1
    assert_file_contains "$COMMANDS_FILE" "npm run build" "Should capture npm run build" || return 1
}

test_captures_cargo_test() {
    update_commands_file
    send_bash_command "cargo test --release"
    assert_file_contains "$COMMANDS_FILE" "cargo test --release" "Should capture cargo test" || return 1
}

test_captures_piped_command() {
    update_commands_file
    send_bash_command "fd -e rs | xargs wc -l"
    assert_file_contains "$COMMANDS_FILE" "fd -e rs | xargs wc -l" "Should capture piped commands" || return 1
}

test_captures_chained_command() {
    update_commands_file
    send_bash_command "npm install && npm run build"
    assert_file_contains "$COMMANDS_FILE" "npm install && npm run build" "Should capture chained commands" || return 1
}

test_skips_trivial_cd() {
    update_commands_file
    send_bash_command "cd /tmp"
    assert_file_not_exists "$COMMANDS_FILE" "commands.md should not be created for cd" || return 1
}

test_skips_trivial_ls() {
    update_commands_file
    send_bash_command "ls -la"
    assert_file_not_exists "$COMMANDS_FILE" "commands.md should not be created for ls" || return 1
}

test_skips_trivial_pwd() {
    update_commands_file
    send_bash_command "pwd"
    assert_file_not_exists "$COMMANDS_FILE" "commands.md should not be created for pwd" || return 1
}

test_skips_trivial_echo() {
    update_commands_file
    send_bash_command "echo hello"
    assert_file_not_exists "$COMMANDS_FILE" "commands.md should not be created for echo" || return 1
}

test_skips_bare_python() {
    update_commands_file
    send_bash_command "python"
    assert_file_not_exists "$COMMANDS_FILE" "Should skip bare python" || return 1
}

test_allows_python_with_flag() {
    update_commands_file
    send_bash_command "python -c 'print(1)'"
    assert_file_contains "$COMMANDS_FILE" "python -c" "Should capture python -c" || return 1
}

test_skips_bare_vim() {
    update_commands_file
    send_bash_command "vim"
    assert_file_not_exists "$COMMANDS_FILE" "Should skip bare vim" || return 1
}

test_deduplicates_same_command() {
    update_commands_file
    send_bash_command "npm run build"
    send_bash_command "npm run build"
    # Should have count 2, not two separate entries
    local count
    count=$(grep -c "npm run build" "$COMMANDS_FILE" 2>/dev/null || echo "0")
    if [ "$count" -ne 1 ]; then
        echo "  FAIL: Should have exactly 1 entry (got $count)"
        return 1
    fi
    assert_file_contains "$COMMANDS_FILE" "\[2x" "Should show 2x count" || return 1
}

test_scrubs_api_key() {
    update_commands_file
    send_bash_command "API_KEY=sk_live_abc123 curl https://api.example.com"
    assert_file_contains "$COMMANDS_FILE" "REDACTED" "Should redact API_KEY value" || return 1
    assert_file_not_contains "$COMMANDS_FILE" "sk_live_abc123" "Should not contain raw key" || return 1
}

test_scrubs_bearer_token() {
    update_commands_file
    send_bash_command "curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9' https://api.example.com"
    assert_file_contains "$COMMANDS_FILE" "REDACTED" "Should redact Bearer token" || return 1
    assert_file_not_contains "$COMMANDS_FILE" "eyJhbGci" "Should not contain raw token" || return 1
}

test_scrubs_password_flag() {
    update_commands_file
    send_bash_command "mysql --password=secret123 -u admin mydb"
    assert_file_contains "$COMMANDS_FILE" "REDACTED" "Should redact --password value" || return 1
    assert_file_not_contains "$COMMANDS_FILE" "secret123" "Should not contain raw password" || return 1
}

test_categorizes_build() {
    update_commands_file
    send_bash_command "npm run build"
    assert_file_contains "$COMMANDS_FILE" "## Build" "Should have Build category" || return 1
}

test_categorizes_test() {
    update_commands_file
    send_bash_command "pytest -x"
    assert_file_contains "$COMMANDS_FILE" "## Test" "Should have Test category" || return 1
}

test_categorizes_dev() {
    update_commands_file
    send_bash_command "docker compose up -d"
    assert_file_contains "$COMMANDS_FILE" "## Dev" "Should have Dev category" || return 1
}

test_categorizes_lint() {
    update_commands_file
    send_bash_command "eslint src/"
    assert_file_contains "$COMMANDS_FILE" "## Lint" "Should have Lint category" || return 1
}

test_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    update_commands_file
    echo '{"tool_name":"Bash","tool_input":{"command":"npm run build"},"tool_response":{}}' \
        | bash "$HOOK"
    assert_file_not_exists "$COMMANDS_FILE" "Should not create file outside cs session" || return 1
}

test_skips_non_bash_tool() {
    update_commands_file
    echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{}}' \
        | bash "$HOOK"
    assert_file_not_exists "$COMMANDS_FILE" "Should not create file for non-Bash tool" || return 1
}

test_creates_file_with_header() {
    update_commands_file
    send_bash_command "cargo build"
    assert_file_contains "$COMMANDS_FILE" "# Project Commands" "Should have header" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs command-tracker tests"
echo "========================"
echo ""

run_test test_captures_npm_build
run_test test_captures_cargo_test
run_test test_captures_piped_command
run_test test_captures_chained_command
run_test test_skips_trivial_cd
run_test test_skips_trivial_ls
run_test test_skips_trivial_pwd
run_test test_skips_trivial_echo
run_test test_skips_bare_python
run_test test_allows_python_with_flag
run_test test_skips_bare_vim
run_test test_deduplicates_same_command
run_test test_scrubs_api_key
run_test test_scrubs_bearer_token
run_test test_scrubs_password_flag
run_test test_categorizes_build
run_test test_categorizes_test
run_test test_categorizes_dev
run_test test_categorizes_lint
run_test test_skips_outside_session
run_test test_skips_non_bash_tool
run_test test_creates_file_with_header

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo ""
