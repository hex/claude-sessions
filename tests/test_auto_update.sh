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
    # source from a temp file: bash 3.2 (macOS stock) does not reliably define a
    # function via `source <(...)` process substitution.
    grep -A 15 '^verify_checksum()' "$CS_BIN" > "$tmpdir/_vc.sh"
    if ( source "$tmpdir/_vc.sh"; verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
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

    grep -A 15 '^verify_checksum()' "$CS_BIN" > "$tmpdir/_vc.sh"
    if ! ( source "$tmpdir/_vc.sh"; verify_checksum "$tmpdir/test.txt" "$tmpdir/test.txt.sha256" ); then
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
# Release-notes pure functions (sourced from the fragment, no network)
# ============================================================================

_source_update_fragment() {
    YELLOW="" GREEN="" BOLD="" DIM="" NC="" COMMENT="" GOLD=""
    VERSION="0.0.0"
    RELEASES_BASE="https://github.com/hex/claude-sessions/releases"
    CHANGELOG_RAW_URL="test://unused"
    source "$SCRIPT_DIR/../lib/20-update.sh"
}

_write_fixture_changelog() {
    cat > "$1" << 'EOF'
# Changelog

Intro prose with a [link](https://example.com).

<!-- authoring note -->

## 2026.99.3

One fix: the statusline is readable on light terminals.

### Fixes

- **Statusline: readable.** The `chiptext` token was **wrong** in [two places](https://example.com/x).

## 2026.99.2

One change: the locked-session menu is single-keypress.

### Changed

- **Menu: keypress.** Cancel stays the default, so a stray key never force-launches.

## 2026.99.1

One fix: the picker no longer feels laggy.

### Fixes

- **Picker: fast.** Drains the whole input queue before repainting.

## 2026.99.0

Old release that must never be emitted.
EOF
}

test_span_extracts_versions_above_installed() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.0") || return 1
    assert_output_contains "$out" "## 2026.99.3" "newest section present" || return 1
    assert_output_contains "$out" "## 2026.99.2" "middle section present" || return 1
    assert_output_contains "$out" "## 2026.99.1" "oldest pending section present" || return 1
    assert_output_not_contains "$out" "2026.99.0" "installed version's section excluded" || return 1
    assert_output_not_contains "$out" "Intro prose" "preamble excluded" || return 1
}

test_span_empty_when_up_to_date() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.3") || return 1
    assert_eq "" "$out" "no sections when installed == newest" || return 1
}

test_summaries_cap_and_collapse() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_summaries "$fix" "2026.99.0" 2) || return 1
    assert_eq "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "two summaries plus collapse line" || return 1
    assert_output_contains "$out" "2026.99.3	One fix: the statusline is readable on light terminals." \
        "summary is the first prose line, tab-separated" || return 1
    assert_output_contains "$out" "+	… and 1 earlier versions" "collapse line counts the overflow" || return 1
    out=$(changelog_summaries "$fix" "2026.99.0" 5) || return 1
    assert_eq "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "three summaries, no collapse under the cap" || return 1
    assert_output_not_contains "$out" "earlier versions" "no collapse line when uncapped" || return 1
}

test_render_strips_markdown_and_joins_summary() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out
    _write_fixture_changelog "$fix"
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || return 1
    assert_output_contains "$out" "2026.99.3 One fix: the statusline is readable on light terminals." \
        "version and summary share a line" || return 1
    assert_output_contains "$out" "────" "dim rule follows the version heading" || return 1
    assert_output_contains "$out" "Statusline: readable." "bullet title survives" || return 1
    assert_output_contains "$out" "two places" "link renders as its text" || return 1
    GOLD="[G]"
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || { GOLD=""; return 1; }
    GOLD=""
    assert_output_contains "$out" '\[G\]chiptext' "code spans in bullet bodies get the gold tint" || return 1
    assert_output_not_contains "$out" "##" "no literal heading markers" || return 1
    assert_output_not_contains "$out" '\*\*' "no literal bold markers" || return 1
    if printf '%s' "$out" | grep -q '`'; then
        echo "  FAIL: no literal backticks in rendered output"
        return 1
    fi
    if printf '%s' "$out" | grep -q "example.com/x"; then
        echo "  FAIL: link targets must not render"
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
run_test test_span_extracts_versions_above_installed
run_test test_span_empty_when_up_to_date
run_test test_summaries_cap_and_collapse
run_test test_render_strips_markdown_and_joins_summary

report_results
