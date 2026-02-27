#!/usr/bin/env bash
# ABOUTME: Tests for user consent prompts before auto-downloading age binaries
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
# minisign is no longer a hard dependency (SHA-256 is primary)
# Verify minisign_ensure_binary (download prompt) was removed
# ============================================================================

test_no_minisign_download_prompt() {
    if grep -q 'Download minisign?' "$CS_BIN" 2>/dev/null; then
        echo "  FAIL: bin/cs should not contain 'Download minisign?' (hard dep removed)"
        return 1
    fi
}

test_no_minisign_ensure_binary() {
    if grep -q 'minisign_ensure_binary' "$CS_BIN" 2>/dev/null; then
        echo "  FAIL: bin/cs should not contain minisign_ensure_binary (function removed)"
        return 1
    fi
}

test_has_verify_checksum() {
    assert_file_contains "$CS_BIN" 'verify_checksum' \
        "bin/cs should have verify_checksum function" || return 1
}

test_has_sha256_verification() {
    assert_file_contains "$CS_BIN" 'sha256sum\|shasum' \
        "bin/cs should use sha256sum or shasum for checksum verification" || return 1
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

# minisign hard dep removed, SHA-256 is primary
run_test test_no_minisign_download_prompt
run_test test_no_minisign_ensure_binary
run_test test_has_verify_checksum
run_test test_has_sha256_verification

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
