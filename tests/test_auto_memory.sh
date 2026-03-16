#!/usr/bin/env bash
# ABOUTME: Tests for auto memory directory redirect into .cs/memory/
# ABOUTME: Validates settings.local.json creation, gitignore, and migration

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

assert_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [ ! -e "$path" ]; then
        echo "  FAIL: $msg (path does not exist: $path)"
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

test_new_session_creates_memory_dir() {
    # Creating a new session should create .cs/memory/
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created" || return 1
}

test_new_session_creates_settings_local() {
    # Creating a new session should create .claude/settings.local.json
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_exists "$session_dir/.claude/settings.local.json" "settings.local.json should exist" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" "autoMemoryDirectory" \
        "settings.local.json should contain autoMemoryDirectory" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" ".cs/memory" \
        "autoMemoryDirectory should point to .cs/memory" || return 1
}

test_settings_local_is_gitignored() {
    # .claude/settings.local.json should be in .gitignore
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_file_contains "$session_dir/.gitignore" ".claude/settings.local.json" \
        ".gitignore should exclude settings.local.json" || return 1
}

test_adopt_creates_memory_dir() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_dir "$project_dir/.cs/memory" ".cs/memory/ should be created on adopt" || return 1
    assert_exists "$project_dir/.claude/settings.local.json" \
        "settings.local.json should exist on adopt" || return 1
}

test_adopt_adds_settings_to_gitignore() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    # Init a git repo with an existing .gitignore
    (cd "$project_dir" && git init -q && echo "node_modules/" > .gitignore && git add -A && git commit -q -m "init")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_file_contains "$project_dir/.gitignore" ".claude/settings.local.json" \
        "Existing .gitignore should get settings.local.json entry" || return 1
}

test_migration_creates_memory_and_settings() {
    # Simulate a pre-existing session without .cs/memory or .claude/
    local session_dir="$CS_SESSIONS_ROOT/old-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    cat > "$session_dir/.cs/sync.conf" << 'EOF'
auto_sync=on
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    # Opening the session triggers migrate_session
    "$CS_BIN" old-session <<< "" 2>&1 || true

    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created on migration" || return 1
    assert_exists "$session_dir/.claude/settings.local.json" \
        "settings.local.json should be created on migration" || return 1
}

test_migration_moves_existing_auto_memory() {
    # Simulate an existing session with auto memory at the default location
    local session_dir="$CS_SESSIONS_ROOT/mem-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    cat > "$session_dir/.cs/sync.conf" << 'EOF'
auto_sync=on
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    # Create auto memory at the default Claude Code location
    local real_path
    real_path="$(cd "$session_dir" && pwd -P)"
    local encoded_path
    encoded_path=$(echo "$real_path" | sed 's|/|-|g; s|\.|-|g')
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    mkdir -p "$old_memory_dir"
    echo "build command: cargo test" > "$old_memory_dir/MEMORY.md"
    echo "debug notes here" > "$old_memory_dir/debugging.md"

    # Opening the session triggers migration
    "$CS_BIN" mem-session <<< "" 2>&1 || true

    # Memory files should be moved into .cs/memory/
    assert_exists "$session_dir/.cs/memory/MEMORY.md" \
        "MEMORY.md should be migrated to .cs/memory/" || return 1
    assert_file_contains "$session_dir/.cs/memory/MEMORY.md" "cargo test" \
        "MEMORY.md content should be preserved" || return 1
    assert_exists "$session_dir/.cs/memory/debugging.md" \
        "debugging.md should be migrated to .cs/memory/" || return 1

    # Old location should be cleaned up
    if [ -d "$old_memory_dir" ] && [ "$(ls -A "$old_memory_dir" 2>/dev/null)" ]; then
        echo "  FAIL: old memory dir should be empty after migration"
        return 1
    fi

    # Clean up the projects dir we created
    rm -rf "$HOME/.claude/projects/${encoded_path}" 2>/dev/null || true
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs auto-memory tests"
echo "===================="
echo ""

run_test test_new_session_creates_memory_dir
run_test test_new_session_creates_settings_local
run_test test_settings_local_is_gitignored
run_test test_adopt_creates_memory_dir
run_test test_adopt_adds_settings_to_gitignore
run_test test_migration_creates_memory_and_settings
run_test test_migration_moves_existing_auto_memory

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
