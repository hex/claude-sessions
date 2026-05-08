#!/usr/bin/env bash
# ABOUTME: Tests for user consent prompts before auto-downloading age binaries
# ABOUTME: Validates that non-interactive contexts skip download and interactive contexts show prompt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

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

report_results
