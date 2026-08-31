#!/usr/bin/env bash
# ABOUTME: Tests for the cs -search command that searches across all sessions
# ABOUTME: Validates search output format, filtering, and edge cases

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# ============================================================================
# Tests
# ============================================================================

test_search_finds_in_narrative() {
    create_test_session "project-alpha"
    echo "## PostgreSQL migration failed on staging server" > "$CS_SESSIONS_ROOT/project-alpha/.cs/memory/narrative.md"

    local output
    output=$("$CS_BIN" -search "postgresql" 2>&1)

    assert_output_contains "$output" "project-alpha" "Should show session name" || return 1
    assert_output_contains "$output" "PostgreSQL" "Should show matched content" || return 1
}

test_search_finds_in_memory() {
    create_test_session "debug-api"
    echo "User prefers cargo test for running tests" > "$CS_SESSIONS_ROOT/debug-api/.cs/memory/MEMORY.md"

    local output
    output=$("$CS_BIN" -search "cargo test" 2>&1)

    assert_output_contains "$output" "debug-api" "Should show session name" || return 1
    assert_output_contains "$output" "cargo test" "Should show matched content" || return 1
}

test_search_finds_in_readme() {
    create_test_session "fix-auth"
    cat > "$CS_SESSIONS_ROOT/fix-auth/.cs/README.md" << 'EOF'
# Session: fix-auth

## Objective
Fix the JWT token refresh bug in the authentication middleware
EOF

    local output
    output=$("$CS_BIN" -search "JWT token" 2>&1)

    assert_output_contains "$output" "fix-auth" "Should show session name" || return 1
    assert_output_contains "$output" "JWT" "Should show matched content" || return 1
}

test_search_across_multiple_sessions() {
    create_test_session "session-one"
    create_test_session "session-two"
    create_test_session "session-three"

    echo "Database uses PostgreSQL 16" > "$CS_SESSIONS_ROOT/session-one/.cs/memory/narrative.md"
    echo "Redis cache for hot queries" > "$CS_SESSIONS_ROOT/session-two/.cs/memory/narrative.md"
    echo "PostgreSQL needs vacuum on large tables" > "$CS_SESSIONS_ROOT/session-three/.cs/memory/narrative.md"

    local output
    output=$("$CS_BIN" -search "PostgreSQL" 2>&1)

    assert_output_contains "$output" "session-one" "Should find in session-one" || return 1
    assert_output_contains "$output" "session-three" "Should find in session-three" || return 1
    assert_output_not_contains "$output" "session-two" "Should NOT find in session-two" || return 1
}

test_search_case_insensitive() {
    create_test_session "my-session"
    echo "Docker compose up failed with network error" > "$CS_SESSIONS_ROOT/my-session/.cs/memory/narrative.md"

    local output
    output=$("$CS_BIN" -search "docker" 2>&1)

    assert_output_contains "$output" "Docker" "Case-insensitive search should match" || return 1
}

test_search_no_results() {
    create_test_session "empty-session"
    echo "Nothing interesting here" > "$CS_SESSIONS_ROOT/empty-session/.cs/memory/narrative.md"

    local output
    output=$("$CS_BIN" -search "xyznonexistent" 2>&1)

    assert_output_contains "$output" "No results" "Should show no-results message" || return 1
}

test_search_no_query() {
    local output
    if output=$("$CS_BIN" -search 2>&1); then
        echo "  FAIL: Should exit with error for missing query"
        return 1
    fi
    assert_output_contains "$output" "Usage" "Should show usage hint" || return 1
}

test_search_follows_symlinks() {
    local real_dir="$TEST_TMPDIR/real-project"
    mkdir -p "$real_dir/.cs"/{memory,local}
    echo "Real project uses Rust nightly" > "$real_dir/.cs/memory/narrative.md"
    ln -s "$real_dir" "$CS_SESSIONS_ROOT/adopted-proj"

    local output
    output=$("$CS_BIN" -search "Rust nightly" 2>&1)

    assert_output_contains "$output" "adopted-proj" "Should find in symlinked session" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs -search tests"
echo "================"
echo ""

run_test test_search_finds_in_narrative
run_test test_search_finds_in_memory
# A dash-prefixed query must be treated as a search term, not a grep option.
test_search_dash_prefixed_query() {
    create_test_session "flags"
    echo "the --verbose flag enables debug output" > "$CS_SESSIONS_ROOT/flags/.cs/memory/narrative.md"

    local output status=0
    output=$("$CS_BIN" -search "--verbose" 2>&1) || status=$?
    assert_eq "0" "$status" "dash-prefixed query must not error, got: $output" || return 1
    assert_output_contains "$output" "flags" "dash-prefixed query still matches content" || return 1
}

run_test test_search_finds_in_readme
run_test test_search_across_multiple_sessions
run_test test_search_case_insensitive
test_search_errors_on_uncompilable_pattern() {
    # grep exits 2 when the pattern will not compile and 1 on a clean no-match.
    # `|| continue` folded both into the same bucket, so a typo'd bracket made
    # every file miss and the run answered "No results" — a false negative
    # dressed as an authoritative answer.
    create_test_session "alpha" >/dev/null
    printf 'the abc marker\n' > "$CS_SESSIONS_ROOT/alpha/.cs/memory/narrative.md"
    # Reachability control: a VALID pattern over the same fixture must match, or
    # the failing half below would pass for the wrong reason.
    local sane
    sane=$("$CS_BIN" -search "abc marker" 2>&1) \
        || { echo "  FAIL: control search exited non-zero: $sane"; return 1; }
    assert_output_contains "$sane" "abc marker" "control: the fixture is searchable" || return 1

    local output rc=0
    output=$("$CS_BIN" -search 'a[' 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: an uncompilable pattern must not exit 0"; return 1; }
    assert_output_not_contains "$output" "No results" \
        "a pattern that never compiled is not an answer about matches" || return 1
    assert_output_contains "$output" "a\[" "the error echoes the offending pattern" || return 1
}

test_search_error_does_not_mangle_a_backslash_pattern() {
    # error() rendered its message with `echo -e`, which consumes escapes in the
    # interpolated value: \c truncates the message (and its newline) outright and
    # \t becomes a literal tab. Backslashes are common in uncompilable BREs, so
    # the diagnostic broke on exactly the inputs it exists to report.
    create_test_session "alpha" >/dev/null
    local output rc=0
    output=$("$CS_BIN" -search 'a\c[' 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: an uncompilable pattern must not exit 0"; return 1; }
    assert_output_contains "$output" 'a\\c\[' "the pattern survives verbatim into the message" || return 1
}

test_search_output_does_not_mangle_a_matched_line() {
    # The match render used `echo -e` too, so a file whose content carries \c
    # truncated the result line — and everything after it on that line.
    create_test_session "alpha" >/dev/null
    printf 'literal backslash c here: a\\c and trailing text\n' \
        > "$CS_SESSIONS_ROOT/alpha/.cs/memory/narrative.md"
    local output
    output=$("$CS_BIN" -search "literal backslash" 2>&1) || return 1
    assert_output_contains "$output" "trailing text" \
        "content after a backslash escape must survive the render" || return 1
}

run_test test_search_no_results
run_test test_search_no_query
run_test test_search_follows_symlinks
run_test test_search_dash_prefixed_query
run_test test_search_errors_on_uncompilable_pattern
run_test test_search_error_does_not_mangle_a_backslash_pattern
run_test test_search_output_does_not_mangle_a_matched_line

test_search_finds_in_narrative_archive() {
    create_test_session "project-beta"
    mkdir -p "$CS_SESSIONS_ROOT/project-beta/.cs/narrative-archive/alice"
    printf '<!-- rotated from narrative.alice.md: 3 sections through 2026-07-01 -->\n\n## 2026-06-30 — the vault incident\nrotated needle-vault\n' \
        > "$CS_SESSIONS_ROOT/project-beta/.cs/narrative-archive/alice/2026-07-01-0123abcd.md"

    local output
    output=$("$CS_BIN" -search "needle-vault" 2>&1)

    assert_output_contains "$output" "project-beta" "Should show session name" || return 1
    assert_output_contains "$output" ".cs/narrative-archive/alice/2026-07-01-0123abcd.md" "Should show the archive path" || return 1
}

run_test test_search_finds_in_narrative_archive

report_results
