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
# Frontmatter migration for old sessions
# ============================================================================

# Helper: create an old-style session (no frontmatter in README)
create_old_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    # Old README.md: no frontmatter, starts with heading
    cat > "$session_dir/.cs/README.md" << 'EOF'
# Session: test-old

**Started:** 2026-03-15 10:30:00
**Location:** macbook:~/projects

## Objective

Fix the database connection pooling issue

## Environment

Production PostgreSQL server

## Outcome

[pending]
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m "init")
}

test_migration_adds_frontmatter_to_old_readme() {
    create_old_session "test-old"
    # Verify no frontmatter before migration
    local first_line
    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "# Session: test-old" "$first_line" "Old README should not have frontmatter" || return 1

    # Open session to trigger migration
    "$CS_BIN" test-old <<< "" 2>&1 || true

    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "---" "$first_line" "Migrated README should have frontmatter" || return 1
}

test_migration_preserves_existing_content() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "database connection pooling" \
        "Migration should preserve objective text" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "Production PostgreSQL" \
        "Migration should preserve environment text" || return 1
}

test_migration_derives_created_date() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should derive created date from the "Started:" line (2026-03-15)
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "created: 2026-03-15" \
        "Should derive created date from Started line" || return 1
}

test_migration_adds_aliases_from_session_name() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'aliases:' \
        "Should add aliases" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'test-old' \
        "Aliases should contain session name" || return 1
}

test_migration_skips_if_frontmatter_exists() {
    create_old_session "test-old"
    # Manually add frontmatter
    local readme="$CS_SESSIONS_ROOT/test-old/.cs/README.md"
    local content
    content=$(cat "$readme")
    {
        echo "---"
        echo "status: completed"
        echo "created: 2026-01-01"
        echo "tags: [custom]"
        echo 'aliases: ["my-custom-alias"]'
        echo "---"
        echo "$content"
    } > "$readme"

    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should NOT overwrite existing frontmatter
    assert_file_contains "$readme" "status: completed" \
        "Should preserve existing status" || return 1
    assert_file_contains "$readme" "created: 2026-01-01" \
        "Should preserve existing created date" || return 1
    assert_file_contains "$readme" "my-custom-alias" \
        "Should preserve existing aliases" || return 1
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

# Frontmatter migration
run_test test_migration_adds_frontmatter_to_old_readme
run_test test_migration_preserves_existing_content
run_test test_migration_derives_created_date
run_test test_migration_adds_aliases_from_session_name
run_test test_migration_skips_if_frontmatter_exists

report_results
