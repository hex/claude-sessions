#!/usr/bin/env bash
# ABOUTME: Tests for cs auto-update setting (global config, CLI, env var override)
# ABOUTME: Validates get/set global config, -update auto subcommand, and CS_AUTO_UPDATE

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CS_BIN="$SCRIPT_DIR/../bin/cs"
TEST_TMPDIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"  # Stub out claude so it doesn't launch
    mkdir -p "$CS_SESSIONS_ROOT"
    # Clear any inherited auto-update env var
    unset CS_AUTO_UPDATE 2>/dev/null || true
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_AUTO_UPDATE 2>/dev/null || true
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [ ! -e "$path" ]; then
        echo "  FAIL: $msg (path does not exist: $path)"
        return 1
    fi
}

assert_output_contains() {
    local output="$1" pattern="$2" msg="${3:-output should contain '$pattern'}"
    if ! echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $msg"
        echo "    output: $output"
        return 1
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        if [ -f "$file" ]; then
            echo "    file contents: $(cat "$file")"
        else
            echo "    file does not exist"
        fi
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

# ============================================================================
# -update auto subcommand tests
# ============================================================================

test_update_auto_shows_off_by_default() {
    local output
    output=$("$CS_BIN" -update auto 2>&1)

    assert_output_contains "$output" "Auto-update: off" \
        "Should show off when no config exists" || return 1
}

test_update_auto_on() {
    local output
    output=$("$CS_BIN" -update auto on 2>&1)

    assert_output_contains "$output" "Auto-update set to: on" \
        "Should confirm auto-update enabled" || return 1

    # Config file should exist with the setting
    assert_exists "$CS_SESSIONS_ROOT/.cs.conf" \
        "Global config should be created" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.cs.conf" "auto_update=on" \
        "Config should contain auto_update=on" || return 1
}

test_update_auto_off() {
    # Enable first, then disable
    "$CS_BIN" -update auto on 2>&1
    local output
    output=$("$CS_BIN" -update auto off 2>&1)

    assert_output_contains "$output" "Auto-update set to: off" \
        "Should confirm auto-update disabled" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.cs.conf" "auto_update=off" \
        "Config should contain auto_update=off" || return 1
}

test_update_auto_shows_current_setting() {
    "$CS_BIN" -update auto on 2>&1

    local output
    output=$("$CS_BIN" -update auto 2>&1)

    assert_output_contains "$output" "Auto-update: on" \
        "Should show current setting as on" || return 1
}

test_update_auto_invalid_value() {
    local output
    if output=$("$CS_BIN" -update auto maybe 2>&1); then
        echo "  FAIL: Should have failed for invalid value"
        return 1
    fi

    assert_output_contains "$output" "Usage" \
        "Error should show usage" || return 1
}

test_update_auto_toggle_preserves_other_config() {
    # Write another config key first
    echo "other_setting=foo" > "$CS_SESSIONS_ROOT/.cs.conf"

    "$CS_BIN" -update auto on 2>&1

    assert_file_contains "$CS_SESSIONS_ROOT/.cs.conf" "other_setting=foo" \
        "Other config keys should be preserved" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.cs.conf" "auto_update=on" \
        "auto_update should be added" || return 1
}

test_update_auto_upsert_no_duplicate() {
    "$CS_BIN" -update auto on 2>&1
    "$CS_BIN" -update auto off 2>&1
    "$CS_BIN" -update auto on 2>&1

    local count
    count=$(grep -c "auto_update=" "$CS_SESSIONS_ROOT/.cs.conf")
    assert_eq "1" "$count" \
        "Should have exactly one auto_update entry after multiple toggles" || return 1
}

# ============================================================================
# Help text tests
# ============================================================================

test_help_shows_auto_update_subcommand() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "auto.*on|off" \
        "Help should show auto subcommand for update" || return 1
}

test_help_shows_cs_auto_update_env() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "CS_AUTO_UPDATE" \
        "Help should document CS_AUTO_UPDATE env var" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs auto-update tests"
echo "===================="
echo ""

# -update auto subcommand
run_test test_update_auto_shows_off_by_default
run_test test_update_auto_on
run_test test_update_auto_off
run_test test_update_auto_shows_current_setting
run_test test_update_auto_invalid_value
run_test test_update_auto_toggle_preserves_other_config
run_test test_update_auto_upsert_no_duplicate

# Help text
run_test test_help_shows_auto_update_subcommand
run_test test_help_shows_cs_auto_update_env

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
