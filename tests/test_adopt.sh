#!/usr/bin/env bash
# ABOUTME: Tests for the cs -adopt command that converts existing projects to cs sessions
# ABOUTME: Validates symlink creation, .cs/ structure, CLAUDE.local.md protocol placement, and edge cases

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# Tests
# ============================================================================

test_adopt_creates_cs_structure() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.cs" ".cs/ directory should exist" || return 1
    assert_dir "$project_dir/.cs/local" ".cs/local/ should exist" || return 1
    assert_exists "$project_dir/.cs/local/session.log" "session.log should exist" || return 1
    assert_exists "$project_dir/.cs/README.md" ".cs/README.md should exist" || return 1
    local nf
    nf=$(ls "$project_dir"/.cs/memory/narrative.*.md 2>/dev/null | head -1)
    assert_exists "$nf" "a per-actor narrative file should exist" || return 1
    assert_not_exists "$project_dir/.cs/sync.conf" "sync.conf must not be created (sync subsystem removed)" || return 1
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

test_adopt_creates_claude_local_md_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_exists "$project_dir/CLAUDE.local.md" "CLAUDE.local.md should be created" || return 1
    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_not_exists "$project_dir/CLAUDE.md" "CLAUDE.md should not be created when none existed" || return 1
}

test_adopt_leaves_existing_claude_md_untouched() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    cat > "$project_dir/CLAUDE.md" << 'EOF'
# My Project Rules

- Use TypeScript for all files
- Follow strict ESLint config
EOF

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_file_contains "$project_dir/CLAUDE.md" "Use TypeScript for all files" \
        "CLAUDE.md should preserve original content" || return 1
    assert_file_not_contains "$project_dir/CLAUDE.md" "Session Documentation Protocol" \
        "CLAUDE.md must not gain the protocol" || return 1
}

test_adopt_refuses_a_directory_already_linked() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt first-name >/dev/null 2>&1)

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt second-name 2>&1); then
        echo "  FAIL: Should have failed for a directory already linked under another name"
        return 1
    fi
    if ! echo "$output" | grep -q "first-name"; then
        echo "  FAIL: Error message should name the existing session 'first-name': $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/second-name" "no symlink should be created for the refused name" || return 1
}

test_adopt_relinks_orphaned_records_interactively() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    printf '\nmarker: orphaned-records-survive\n' >> "$narrative"
    local before
    before=$(cat "$narrative")

    local output rc=0
    output=$(cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: re-adopt should exit 0: $output"; return 1; }

    assert_symlink "$CS_SESSIONS_ROOT/new-name" "new symlink should exist" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/old-name" "old symlink name should stay gone" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file should be byte-identical after re-adopt" || return 1
}

test_adopt_orphaned_records_noninteractive_hints() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    local before
    before=$(cat "$narrative")

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt new-name </dev/null 2>&1); then
        echo "  FAIL: non-interactive re-adopt should fail without a terminal"
        return 1
    fi
    if ! echo "$output" | grep -qi "re-run interactively"; then
        echo "  FAIL: error should hint at re-running interactively: $output"
        return 1
    fi
    assert_dir "$project_dir/.cs" ".cs/ should be untouched" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file must not change on a refused re-adopt" || return 1
}

test_adopt_orphaned_records_decline_cancels() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local output rc=0
    output=$(cd "$project_dir" && printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: declining re-adopt should exit 0: $output"; return 1; }
    if ! echo "$output" | grep -qi "cancelled"; then
        echo "  FAIL: output should say Cancelled: $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no symlink should be created on decline" || return 1
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

    echo "y" | CS_ASSUME_TTY=1 "$CS_BIN" -remove my-session 2>&1

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

test_adopt_into_git_repo_without_claude_md_stages_bookkeeping() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local tracked
    tracked=$(git -C "$project_dir" ls-files .cs/README.md)
    if [[ -z "$tracked" ]]; then
        echo "  FAIL: .cs/README.md should be tracked by git after adopting a repo with no CLAUDE.md"
        return 1
    fi

    local log_output
    log_output=$(git -C "$project_dir" log --oneline --format="%s")
    if ! echo "$log_output" | grep -q "^Adopt as cs session: my-session$"; then
        echo "  FAIL: Adopt commit 'Adopt as cs session: my-session' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

# Adoption commits inside the user's own project repo. A bare `git commit`
# there commits the whole index, so work they had staged is swept into a commit
# titled "Adopt as cs session" — the same defect the narrative rotation commit
# carried, at the other site where cs commits into a checkout it does not own.
test_adopt_commits_only_its_own_bookkeeping() {
    local project_dir="$TEST_TMPDIR/staged-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)
    printf 'work in progress\n' > "$project_dir/user-file.txt"
    git -C "$project_dir" add -- user-file.txt

    (cd "$project_dir" && "$CS_BIN" -adopt staged-session)

    local subject swept staged
    # HEAD must BE the adopt commit first: the fixture's initial commit predates
    # user-file.txt, so "HEAD does not contain it" holds even when no adopt
    # commit was made at all.
    subject=$(git -C "$project_dir" log -1 --format=%s)
    assert_eq "Adopt as cs session: staged-session" "$subject" "HEAD must be the adopt commit" || return 1
    swept=$(git -C "$project_dir" show --name-only --format= HEAD | grep -c 'user-file.txt' || true)
    assert_eq "0" "$swept" "the user's staged file must not ride along in the adopt commit" || return 1
    staged=$(git -C "$project_dir" diff --cached --name-only -- user-file.txt)
    assert_eq "user-file.txt" "$staged" "and it must still be staged afterwards" || return 1
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

test_readme_frontmatter_has_aliases() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" 'aliases:' "Frontmatter should have aliases field" || return 1
    assert_file_contains "$readme" 'test-session' "Aliases should contain session name" || return 1
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

test_adopt_sets_memory_merge_driver() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A)
    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitattributes" "MEMORY.md merge=ours" \
        ".gitattributes should mark MEMORY.md merge=ours" || return 1
    local drv
    drv=$(git -C "$project_dir" config merge.ours.driver 2>/dev/null || echo "")
    assert_eq "true" "$drv" "merge.ours.driver should be configured" || return 1
}

test_adopt_gitignores_cs_local() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt my-session)
    assert_file_contains "$project_dir/.gitignore" ".cs/local/" \
        ".gitignore should ignore .cs/local/" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs -adopt tests"
echo "==============="
echo ""

run_test test_adopt_gitignores_cs_local
run_test test_adopt_sets_memory_merge_driver

run_test test_adopt_creates_cs_structure
run_test test_adopt_creates_symlink
run_test test_adopt_creates_claude_local_md_when_none_exists
run_test test_adopt_leaves_existing_claude_md_untouched
run_test test_adopt_refuses_a_directory_already_linked
run_test test_adopt_relinks_orphaned_records_interactively
run_test test_adopt_orphaned_records_noninteractive_hints
run_test test_adopt_orphaned_records_decline_cancels
run_test test_adopt_fails_if_session_name_exists
run_test test_adopt_validates_session_name
run_test test_list_shows_adopted_sessions
run_test test_remove_adopted_session_removes_symlink_only
run_test test_adopt_preserves_existing_git_repo
run_test test_adopt_inits_git_when_none_exists
run_test test_adopt_into_git_repo_without_claude_md_stages_bookkeeping
run_test test_adopt_commits_only_its_own_bookkeeping

# README frontmatter
run_test test_readme_has_yaml_frontmatter
run_test test_readme_frontmatter_has_status
run_test test_readme_frontmatter_has_created_date
run_test test_readme_frontmatter_has_tags
run_test test_readme_frontmatter_has_aliases
run_test test_readme_objective_still_extractable

report_results
