#!/usr/bin/env bash
# ABOUTME: Shared test framework for cs shell tests
# ABOUTME: Provides assertion functions, test runner, setup/teardown, and result reporting

# Guard against double-sourcing
[[ -n "${_CS_TEST_LIB_LOADED:-}" ]] && return 0
_CS_TEST_LIB_LOADED=1

set -euo pipefail

# --- State ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# --- Paths ---
# SCRIPT_DIR must be set by the sourcing test file before calling any helpers
# CS_BIN is derived from SCRIPT_DIR
CS_BIN="${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing test_lib.sh}/../bin/cs"
TEST_TMPDIR=""

# --- Setup / Teardown ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
}

# --- Test Runner ---

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

# --- Result Reporting ---

report_results() {
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo "Failed tests:"
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
        exit 1
    fi
    echo ""
}

# --- Assertions ---

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [[ ! -e "$path" ]]; then
        echo "  FAIL: $msg (path does not exist: $path)"
        return 1
    fi
}

assert_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [[ -e "$path" ]]; then
        echo "  FAIL: $msg (path exists: $path)"
        return 1
    fi
}

assert_dir() {
    local path="$1" msg="${2:-$path should be a directory}"
    if [[ ! -d "$path" ]]; then
        echo "  FAIL: $msg (not a directory: $path)"
        return 1
    fi
}

assert_symlink() {
    local path="$1" msg="${2:-$path should be a symlink}"
    if [[ ! -L "$path" ]]; then
        echo "  FAIL: $msg (not a symlink: $path)"
        return 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-$path should be a file}"
    if [[ ! -f "$path" ]]; then
        echo "  FAIL: $msg (not a file: $path)"
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [[ -f "$path" ]]; then
        echo "  FAIL: $msg (file exists: $path)"
        return 1
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        if [[ -f "$file" ]]; then
            echo "    file contents: $(head -20 "$file")"
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

assert_output_contains() {
    local output="$1" pattern="$2" msg="${3:-output should contain '$pattern'}"
    if ! echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $msg"
        echo "    output: $(echo "$output" | head -5)"
        return 1
    fi
}

assert_output_not_contains() {
    local output="$1" pattern="$2" msg="${3:-output should not contain '$pattern'}"
    if echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $msg"
        return 1
    fi
}

# --- Session Helpers ---

# Create a minimal cs session directory structure
create_test_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{memory,artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "# Session" > "$session_dir/CLAUDE.md"
    echo "$session_dir"
}

# Create a session with a git repo initialized
create_test_session_with_git() {
    local name="$1"
    local session_dir
    session_dir=$(create_test_session "$name")
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}
