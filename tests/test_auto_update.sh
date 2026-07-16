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

_write_fixture_changelog_oldstyle() {
    cat > "$1" << 'EOF'
# Changelog

## 2026.99.7

### Fixes

- **Bullet-first: no summary line.** Body text.

## 2026.99.6

- **Hard-wrapped bullet.** This bullet line is
  wrapped across two source lines by hand.

## 2026.99.5

One fix: normal section for contrast.

## 2026.99.4

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

test_render_emits_escape_bytes_not_literal_backslash() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" out expected_esc
    _write_fixture_changelog "$fix"
    GOLD='\033[33m'
    expected_esc=$(printf '%b' "$GOLD")
    out=$(changelog_span "$fix" "2026.99.0" | render_changelog) || { GOLD=""; return 1; }
    GOLD=""
    if printf '%s' "$out" | grep -q -- '\\033'; then
        echo "  FAIL: color codes must be emitted as escape bytes, not literal backslash-033 text"
        return 1
    fi
    # BSD sed's replacement-string parser silently drops a literal backslash
    # before a digit (see 's/x/[\0]/' on a match), so the check above passes
    # vacuously on this platform even when the sed splice never expands the
    # escape: the leading backslash is eaten and only a bare '0' leaks into
    # the text. Assert byte-for-byte that the expanded escape sequence itself
    # (not a mangled remnant of it) wraps the code span.
    if ! printf '%s' "$out" | grep -qF -- "${expected_esc}chiptext"; then
        echo "  FAIL: code span must be wrapped in the expanded escape byte sequence"
        return 1
    fi
}

test_render_flushes_headers_for_bullet_first_sections() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-oldstyle.md" out
    _write_fixture_changelog_oldstyle "$fix"
    out=$(changelog_span "$fix" "2026.99.4" | render_changelog) || return 1
    assert_output_contains "$out" "2026.99.7" "bullet-first section header renders" || return 1
    assert_output_contains "$out" "2026.99.6" "hard-wrapped section header renders" || return 1
    assert_output_contains "$out" "2026.99.5 One fix: normal section for contrast." "prose summary still joins its header" || return 1
    assert_output_contains "$out" "Bullet-first: no summary line." "bullet renders under its own header" || return 1
}

test_render_width_floor_survives_tiny_terminals() {
    _source_update_fragment
    local fix="$TEST_TMPDIR/CHANGELOG-oldstyle.md" out
    _write_fixture_changelog_oldstyle "$fix"
    COLUMNS=3
    export COLUMNS
    out=$(changelog_span "$fix" "2026.99.4" | render_changelog) || { unset COLUMNS; return 1; }
    unset COLUMNS
    assert_output_contains "$out" "2026.99.7" "renderer survives tiny width" || return 1
}

# ============================================================================
# Release-notes surfaces (curl stubbed via PATH; HOME faked)
# ============================================================================

# The e2e tests fake HOME; save the real one ONCE at file scope. test_lib.sh
# does NOT save it (only test_cs_secrets.sh does, locally to that file), and
# under set -u an unbound restore would abort the whole suite.
ORIGINAL_HOME="$HOME"

# Stub curl: the version probe (-w) reports v2026.99.3; the changelog fetch
# (-o) copies the fixture, or fails when no fixture path was baked in.
_make_curl_stub() {  # stub-dir, fixture-path-or-empty
    cat > "$1/curl" << STUB
#!/usr/bin/env bash
case "\$*" in
    *" -w "*|*"-w"*)
        printf '%s' "https://github.com/hex/claude-sessions/releases/tag/v2026.99.3"
        exit 0
        ;;
esac
out=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; fi
    prev="\$a"
done
if [ -n "$2" ] && [ -n "\$out" ]; then
    cp "$2" "\$out"
    exit 0
fi
exit 22
STUB
    chmod +x "$1/curl"
}

test_check_shows_rendered_span() {
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" stub="$TEST_TMPDIR/stub-bin" out
    _write_fixture_changelog "$fix"
    mkdir -p "$stub"
    _make_curl_stub "$stub" "$fix"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    out=$(PATH="$stub:$PATH" "$CS_BIN" -update --check 2>&1) || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available" "check still announces" || return 1
    assert_output_contains "$out" "2026.99.3 One fix: the statusline is readable on light terminals." \
        "check renders the span" || return 1
    assert_output_contains "$out" "Menu: keypress." "older pending section included" || return 1
    assert_output_not_contains "$out" "##" "no raw markdown in check output" || return 1
}

test_check_falls_back_when_fetch_fails() {
    local stub="$TEST_TMPDIR/stub-bin" out
    mkdir -p "$stub"
    _make_curl_stub "$stub" ""
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    out=$(PATH="$stub:$PATH" "$CS_BIN" -update --check 2>&1) || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available" "check still announces" || return 1
    assert_output_contains "$out" "releases" "fallback names the releases page" || return 1
}

test_launch_banner_shows_notes_card() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    printf '2026.99.3\tOne fix: the statusline is readable.\n2026.99.2\tOne change: the menu is single-keypress.\n+\t… and 1 earlier versions\n' \
        > "$HOME/.cache/cs/update-notes-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    out=$("$CS_BIN" "notes-card-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available:" "banner one-liner intact" || return 1
    assert_output_contains "$out" "2026.99.3" "card shows the newest version" || return 1
    assert_output_contains "$out" "One fix: the statusline is readable." "card shows its summary" || return 1
    assert_output_contains "$out" "and 1 earlier versions" "card shows the collapse line" || return 1
}

test_launch_banner_quiet_on_empty_notes_cache() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    : > "$HOME/.cache/cs/update-notes-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    out=$("$CS_BIN" "notes-quiet-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "Update available:" "one-liner still shown" || return 1
    assert_output_not_contains "$out" "One fix: the statusline is readable." \
        "no card rows from the tombstone (the populated-cache test proves this string DOES render when present)" || return 1
    assert_output_not_contains "$out" "earlier versions" "no collapse line from the tombstone" || return 1
}

test_notify_writes_notes_cache() {
    local fix="$TEST_TMPDIR/CHANGELOG-fixture.md" stub="$TEST_TMPDIR/stub-bin"
    _write_fixture_changelog "$fix"
    mkdir -p "$stub"
    _make_curl_stub "$stub" "$fix"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cache/cs"
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-2026.90.0"
    unset CS_NO_UPDATE_CHECK
    PATH="$stub:$PATH" "$CS_BIN" "notes-notify-session" < /dev/null > /dev/null 2>&1 || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1
    local cache="$HOME/.cache/cs/update-notes-2026.99.3"
    assert_file_exists "$cache" "notify writes the notes cache" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$cache" "2026.99.3	One fix: the statusline is readable on light terminals." \
        "cache holds tab-separated summaries" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_not_exists "$HOME/.cache/cs/update-notes-2026.90.0" "stale notes caches pruned" || { export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
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
run_test test_render_emits_escape_bytes_not_literal_backslash
run_test test_render_flushes_headers_for_bullet_first_sections
run_test test_render_width_floor_survives_tiny_terminals
run_test test_check_shows_rendered_span
run_test test_check_falls_back_when_fetch_fails
run_test test_launch_banner_shows_notes_card
run_test test_launch_banner_quiet_on_empty_notes_cache
run_test test_notify_writes_notes_cache

report_results
