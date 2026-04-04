#!/usr/bin/env bash
# ABOUTME: Tests for auto memory directory redirect into .cs/memory/
# ABOUTME: Validates settings.local.json creation, gitignore, and migration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# ============================================================================
# Tests
# ============================================================================

test_new_session_creates_memory_dir() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created" || return 1
}

test_new_session_creates_settings_local() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_exists "$session_dir/.claude/settings.local.json" "settings.local.json should exist" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" "autoMemoryDirectory" \
        "settings.local.json should contain autoMemoryDirectory" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" ".cs/memory" \
        "autoMemoryDirectory should point to .cs/memory" || return 1
}

test_settings_local_is_gitignored() {
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

    (cd "$project_dir" && git init -q && echo "node_modules/" > .gitignore && git add -A && git commit -q -m "init")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_file_contains "$project_dir/.gitignore" ".claude/settings.local.json" \
        "Existing .gitignore should get settings.local.json entry" || return 1
}

test_migration_creates_memory_and_settings() {
    local session_dir="$CS_SESSIONS_ROOT/old-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" old-session <<< "" 2>&1 || true

    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created on migration" || return 1
    assert_exists "$session_dir/.claude/settings.local.json" \
        "settings.local.json should be created on migration" || return 1
}

test_migration_moves_existing_auto_memory() {
    local session_dir="$CS_SESSIONS_ROOT/mem-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    local real_path
    real_path="$(cd "$session_dir" && pwd -P)"
    local encoded_path
    encoded_path=$(echo "$real_path" | sed 's|/|-|g; s|\.|-|g')
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    mkdir -p "$old_memory_dir"
    echo "build command: cargo test" > "$old_memory_dir/MEMORY.md"
    echo "debug notes here" > "$old_memory_dir/debugging.md"

    "$CS_BIN" mem-session <<< "" 2>&1 || true

    assert_exists "$session_dir/.cs/memory/MEMORY.md" \
        "MEMORY.md should be migrated to .cs/memory/" || return 1
    assert_file_contains "$session_dir/.cs/memory/MEMORY.md" "cargo test" \
        "MEMORY.md content should be preserved" || return 1
    assert_exists "$session_dir/.cs/memory/debugging.md" \
        "debugging.md should be migrated to .cs/memory/" || return 1

    if [[ -d "$old_memory_dir" ]] && [[ "$(ls -A "$old_memory_dir" 2>/dev/null)" ]]; then
        echo "  FAIL: old memory dir should be empty after migration"
        return 1
    fi

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

report_results
