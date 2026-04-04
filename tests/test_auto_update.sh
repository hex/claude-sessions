#!/usr/bin/env bash
# ABOUTME: Tests for cs -update subcommand (manual update, check, force)
# ABOUTME: Validates help text, subcommand routing, and that auto-update is not offered

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# ============================================================================
# Help text tests
# ============================================================================

test_help_shows_update_command() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "-update" \
        "Help should show -update command" || return 1
}

test_help_shows_check_and_force() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_contains "$output" "\-\-check" \
        "Help should show --check flag" || return 1
    assert_output_contains "$output" "\-\-force" \
        "Help should show --force flag" || return 1
}

test_help_does_not_show_auto_update() {
    local output
    output=$("$CS_BIN" -help 2>&1)

    assert_output_not_contains "$output" "CS_AUTO_UPDATE" \
        "Help should not reference CS_AUTO_UPDATE env var" || return 1
    local update_section
    update_section=$(echo "$output" | sed -n '/-update/,/^  -/p' | head -5)
    if echo "$update_section" | grep -q -- "auto"; then
        echo "  FAIL: Update section should not mention auto"
        return 1
    fi
}

# ============================================================================
# Subcommand routing tests
# ============================================================================

test_update_unknown_arg_errors() {
    local output
    if output=$("$CS_BIN" -update bogus 2>&1); then
        echo "  FAIL: Should have failed for unknown argument"
        return 1
    fi

    assert_output_contains "$output" "Unknown option" \
        "Should show unknown option error" || return 1
}

test_update_auto_is_unknown() {
    local output
    if output=$("$CS_BIN" -update auto 2>&1); then
        echo "  FAIL: 'cs -update auto' should fail (feature removed)"
        return 1
    fi

    assert_output_contains "$output" "Unknown option" \
        "auto should be treated as unknown option" || return 1
}

# ============================================================================
# Checksum verification tests
# ============================================================================

test_verify_checksum_present_in_source() {
    if ! grep -q 'verify_checksum()' "$CS_BIN"; then
        echo "  FAIL: bin/cs should define verify_checksum function"
        return 1
    fi
}

test_verify_checksum_catches_mismatch() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "hello world" > "$tmpdir/test.txt"
    echo "0000000000000000000000000000000000000000000000000000000000000000  test.txt" > "$tmpdir/test.txt.sha256"

    local result
    if ( source <(grep -A 15 '^verify_checksum()' "$CS_BIN"); verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
        rm -rf "$tmpdir"
        echo "  FAIL: verify_checksum should reject mismatched checksum"
        return 1
    fi

    rm -rf "$tmpdir"
}

test_verify_checksum_accepts_match() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "hello world" > "$tmpdir/test.txt"

    if command -v sha256sum &>/dev/null; then
        sha256sum "$tmpdir/test.txt" > "$tmpdir/test.txt.sha256"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$tmpdir/test.txt" > "$tmpdir/test.txt.sha256"
    else
        rm -rf "$tmpdir"
        echo "  SKIP: no sha256sum or shasum available"
        return 0
    fi

    if ! ( source <(grep -A 15 '^verify_checksum()' "$CS_BIN"); verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
        rm -rf "$tmpdir"
        echo "  FAIL: verify_checksum should accept matching checksum"
        return 1
    fi

    rm -rf "$tmpdir"
}

test_do_update_downloads_checksum() {
    if ! grep -q 'install.sh.sha256' "$CS_BIN"; then
        echo "  FAIL: do_update should download install.sh.sha256"
        return 1
    fi
}

test_signature_is_optional() {
    if ! grep -A 1 'install.sh.minisig' "$CS_BIN" | grep -q '2>/dev/null'; then
        echo "  FAIL: minisig download should be best-effort"
        return 1
    fi
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs update tests"
echo "==============="
echo ""

run_test test_help_shows_update_command
run_test test_help_shows_check_and_force
run_test test_help_does_not_show_auto_update
run_test test_update_unknown_arg_errors
run_test test_update_auto_is_unknown
run_test test_verify_checksum_present_in_source
run_test test_verify_checksum_catches_mismatch
run_test test_verify_checksum_accepts_match
run_test test_do_update_downloads_checksum
run_test test_signature_is_optional

report_results
