#!/usr/bin/env bash
# ABOUTME: Tests for the cs -adopt command that converts existing projects to cs sessions
# ABOUTME: Validates symlink creation, .cs/ structure, CLAUDE.md merging, and edge cases

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
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
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

assert_symlink() {
    local path="$1" msg="${2:-$path should be a symlink}"
    if [ ! -L "$path" ]; then
        echo "  FAIL: $msg (not a symlink: $path)"
        return 1
    fi
}

assert_dir() {
    local path="$1" msg="${2:-$path should be a directory}"
    if [ ! -d "$path" ]; then
        echo "  FAIL: $msg (not a directory: $path)"
        return 1
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        return 1
    fi
}

assert_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [ -e "$path" ]; then
        echo "  FAIL: $msg (path exists: $path)"
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
# Tests
# ============================================================================

test_adopt_creates_cs_structure() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    # Run adopt from the project directory
    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # Verify .cs/ structure was created
    assert_dir "$project_dir/.cs" ".cs/ directory should exist" || return 1
    assert_dir "$project_dir/.cs/artifacts" ".cs/artifacts/ should exist" || return 1
    assert_dir "$project_dir/.cs/logs" ".cs/logs/ should exist" || return 1
    assert_exists "$project_dir/.cs/artifacts/MANIFEST.json" "MANIFEST.json should exist" || return 1
    assert_exists "$project_dir/.cs/logs/session.log" "session.log should exist" || return 1
    assert_exists "$project_dir/.cs/README.md" ".cs/README.md should exist" || return 1
    assert_exists "$project_dir/.cs/discoveries.md" "discoveries.md should exist" || return 1
    assert_exists "$project_dir/.cs/changes.md" "changes.md should exist" || return 1
    assert_exists "$project_dir/.cs/sync.conf" "sync.conf should exist" || return 1
}

test_adopt_creates_symlink() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # Symlink should exist at sessions root
    assert_symlink "$CS_SESSIONS_ROOT/my-session" "Session symlink should exist" || return 1

    # Symlink should point to the project directory
    local target
    target="$(readlink -f "$CS_SESSIONS_ROOT/my-session")"
    local real_project
    real_project="$(cd "$project_dir" && pwd -P)"
    assert_eq "$real_project" "$target" "Symlink should point to project directory" || return 1
}

test_adopt_creates_claude_md_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_exists "$project_dir/CLAUDE.md" "CLAUDE.md should be created" || return 1
    assert_file_contains "$project_dir/CLAUDE.md" "Session Documentation Protocol" \
        "CLAUDE.md should contain session protocol" || return 1
}

test_adopt_merges_existing_claude_md() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    # Create an existing CLAUDE.md with project-specific content
    cat > "$project_dir/CLAUDE.md" << 'EOF'
# My Project Rules

- Use TypeScript for all files
- Follow strict ESLint config
EOF

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # Should contain BOTH the session protocol AND the original content
    assert_file_contains "$project_dir/CLAUDE.md" "Session Documentation Protocol" \
        "CLAUDE.md should contain session protocol after merge" || return 1
    assert_file_contains "$project_dir/CLAUDE.md" "Use TypeScript for all files" \
        "CLAUDE.md should preserve original content after merge" || return 1
}

test_adopt_fails_if_already_cs_session() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir/.cs"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt my-session 2>&1); then
        echo "  FAIL: Should have failed for directory with existing .cs/"
        return 1
    fi

    # Should mention that it's already a cs session
    if ! echo "$output" | grep -qi "already"; then
        echo "  FAIL: Error message should mention 'already': $output"
        return 1
    fi
}

test_adopt_fails_if_session_name_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    mkdir -p "$CS_SESSIONS_ROOT/my-session"  # Pre-existing session

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt my-session 2>&1); then
        echo "  FAIL: Should have failed for existing session name"
        return 1
    fi

    if ! echo "$output" | grep -qi "already exists"; then
        echo "  FAIL: Error message should mention 'already exists': $output"
        return 1
    fi
}

test_adopt_validates_session_name() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt "bad name!" 2>&1); then
        echo "  FAIL: Should have failed for invalid session name"
        return 1
    fi
}

test_list_shows_adopted_sessions() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # cs -list should show the adopted session
    local output
    output=$("$CS_BIN" -list 2>&1)

    if ! echo "$output" | grep -q "my-session"; then
        echo "  FAIL: cs -list should show adopted session 'my-session'"
        echo "  Output: $output"
        return 1
    fi
}

test_remove_adopted_session_removes_symlink_only() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # Remove should remove the symlink
    echo "y" | "$CS_BIN" -remove my-session 2>&1

    # Symlink should be gone
    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "Symlink should be removed" || return 1

    # Original project should still exist with .cs/
    assert_dir "$project_dir" "Original project should still exist" || return 1
    assert_dir "$project_dir/.cs" ".cs/ should still exist in original project" || return 1
}

test_adopt_preserves_existing_git_repo() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    # Init a git repo with a commit
    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    # Original commit should still be in history (adopt adds a new commit on top)
    local log_output
    log_output=$(cd "$project_dir" && git log --oneline --format="%s")
    if ! echo "$log_output" | grep -q "initial"; then
        echo "  FAIL: Original git commit 'initial' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

test_adopt_inits_git_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.git" "Git repo should be initialized" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs -adopt tests"
echo "==============="
echo ""

run_test test_adopt_creates_cs_structure
run_test test_adopt_creates_symlink
run_test test_adopt_creates_claude_md_when_none_exists
run_test test_adopt_merges_existing_claude_md
run_test test_adopt_fails_if_already_cs_session
run_test test_adopt_fails_if_session_name_exists
run_test test_adopt_validates_session_name
run_test test_list_shows_adopted_sessions
run_test test_remove_adopted_session_removes_symlink_only
run_test test_adopt_preserves_existing_git_repo
run_test test_adopt_inits_git_when_none_exists

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
