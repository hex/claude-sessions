#!/usr/bin/env bash
# ABOUTME: Tests for the cs -adopt command that converts existing projects to cs sessions
# ABOUTME: Validates symlink creation, .cs/ structure, CLAUDE.md merging, and edge cases

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

test_adopt_creates_cs_structure() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

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

    assert_symlink "$CS_SESSIONS_ROOT/my-session" "Session symlink should exist" || return 1

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

    cat > "$project_dir/CLAUDE.md" << 'EOF'
# My Project Rules

- Use TypeScript for all files
- Follow strict ESLint config
EOF

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

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

    if ! echo "$output" | grep -qi "already"; then
        echo "  FAIL: Error message should mention 'already': $output"
        return 1
    fi
}

test_adopt_fails_if_session_name_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    mkdir -p "$CS_SESSIONS_ROOT/my-session"

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

    echo "y" | "$CS_BIN" -remove my-session 2>&1

    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "Symlink should be removed" || return 1
    assert_dir "$project_dir" "Original project should still exist" || return 1
    assert_dir "$project_dir/.cs" ".cs/ should still exist in original project" || return 1
}

test_adopt_preserves_existing_git_repo() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

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
# README.md frontmatter
# ============================================================================

test_readme_has_yaml_frontmatter() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    local first_line
    first_line=$(head -1 "$readme")
    assert_eq "---" "$first_line" "README should start with YAML frontmatter delimiter" || return 1
}

test_readme_frontmatter_has_status() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "status:" "Frontmatter should have status field" || return 1
}

test_readme_frontmatter_has_created_date() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "created: 20" "Frontmatter should have created date" || return 1
}

test_readme_frontmatter_has_tags() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "tags:" "Frontmatter should have tags field" || return 1
}

test_readme_objective_still_extractable() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    # The sed pattern used by session-start.sh should still work
    local obj
    obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$readme" | head -1)
    assert_eq "[Describe what you're trying to accomplish in this session]" "$obj" \
        "Objective should still be extractable with existing sed pattern" || return 1
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

# README frontmatter
run_test test_readme_has_yaml_frontmatter
run_test test_readme_frontmatter_has_status
run_test test_readme_frontmatter_has_created_date
run_test test_readme_frontmatter_has_tags
run_test test_readme_objective_still_extractable

report_results
