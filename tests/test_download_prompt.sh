#!/usr/bin/env bash
# ABOUTME: Tests for user consent prompts before auto-downloading minisign and age binaries
# ABOUTME: Validates that non-interactive contexts skip download and interactive contexts show prompt

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CS_BIN="$SCRIPT_DIR/../bin/cs"
CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    if "$test_name" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
}

# ============================================================================
# minisign_ensure_binary prompt tests (bin/cs)
# ============================================================================

test_minisign_has_consent_prompt() {
    assert_file_contains "$CS_BIN" 'Download minisign?' \
        "minisign_ensure_binary should prompt for consent" || return 1
}

test_minisign_has_noninteractive_guard() {
    assert_file_contains "$CS_BIN" 'Non-interactive shell' \
        "minisign_ensure_binary should handle non-interactive shells" || return 1
}

test_minisign_has_manual_install_hint() {
    assert_file_contains "$CS_BIN" 'brew install minisign' \
        "minisign decline should suggest manual install" || return 1
}

test_minisign_has_download_source_disclosure() {
    assert_file_contains "$CS_BIN" 'github.com/jedisct1/minisign' \
        "minisign prompt should disclose download source" || return 1
}

# ============================================================================
# age_ensure_binary prompt tests (bin/cs-secrets)
# ============================================================================

test_age_has_consent_prompt() {
    assert_file_contains "$CS_SECRETS_BIN" 'Download age?' \
        "age_ensure_binary should prompt for consent" || return 1
}

test_age_has_noninteractive_guard() {
    assert_file_contains "$CS_SECRETS_BIN" 'Non-interactive shell' \
        "age_ensure_binary should handle non-interactive shells" || return 1
}

test_age_has_manual_install_hint() {
    assert_file_contains "$CS_SECRETS_BIN" 'brew install age' \
        "age decline should suggest manual install" || return 1
}

test_age_has_download_source_disclosure() {
    assert_file_contains "$CS_SECRETS_BIN" 'dl.filippo.io/age' \
        "age prompt should disclose download source" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs download prompt tests"
echo "========================"
echo ""

# minisign prompt
run_test test_minisign_has_consent_prompt
run_test test_minisign_has_noninteractive_guard
run_test test_minisign_has_manual_install_hint
run_test test_minisign_has_download_source_disclosure

# age prompt
run_test test_age_has_consent_prompt
run_test test_age_has_noninteractive_guard
run_test test_age_has_manual_install_hint
run_test test_age_has_download_source_disclosure

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
