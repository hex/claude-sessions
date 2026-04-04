#!/usr/bin/env bash
# ABOUTME: Tests for the cs -search command that searches across all sessions
# ABOUTME: Validates search output format, filtering, and edge cases

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# ============================================================================
# Tests
# ============================================================================

test_search_finds_in_discoveries() {
    create_test_session "project-alpha"
    echo "## PostgreSQL migration failed on staging server" > "$CS_SESSIONS_ROOT/project-alpha/.cs/discoveries.md"

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

    echo "Database uses PostgreSQL 16" > "$CS_SESSIONS_ROOT/session-one/.cs/discoveries.md"
    echo "Redis cache for hot queries" > "$CS_SESSIONS_ROOT/session-two/.cs/discoveries.md"
    echo "PostgreSQL needs vacuum on large tables" > "$CS_SESSIONS_ROOT/session-three/.cs/discoveries.md"

    local output
    output=$("$CS_BIN" -search "PostgreSQL" 2>&1)

    assert_output_contains "$output" "session-one" "Should find in session-one" || return 1
    assert_output_contains "$output" "session-three" "Should find in session-three" || return 1
    assert_output_not_contains "$output" "session-two" "Should NOT find in session-two" || return 1
}

test_search_case_insensitive() {
    create_test_session "my-session"
    echo "Docker compose up failed with network error" > "$CS_SESSIONS_ROOT/my-session/.cs/discoveries.md"

    local output
    output=$("$CS_BIN" -search "docker" 2>&1)

    assert_output_contains "$output" "Docker" "Case-insensitive search should match" || return 1
}

test_search_no_results() {
    create_test_session "empty-session"
    echo "Nothing interesting here" > "$CS_SESSIONS_ROOT/empty-session/.cs/discoveries.md"

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
    mkdir -p "$real_dir/.cs"/{memory,artifacts,logs}
    echo "Real project uses Rust nightly" > "$real_dir/.cs/discoveries.md"
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

run_test test_search_finds_in_discoveries
run_test test_search_finds_in_memory
run_test test_search_finds_in_readme
run_test test_search_across_multiple_sessions
run_test test_search_case_insensitive
run_test test_search_no_results
run_test test_search_no_query
run_test test_search_follows_symlinks

report_results
