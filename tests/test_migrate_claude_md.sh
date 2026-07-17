#!/usr/bin/env bash
# ABOUTME: Tests that migrating an existing session never destroys a user-authored CLAUDE.md
# ABOUTME: Phase 5 must append the cs protocol, not wholesale-overwrite the file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A resume (existing dir → migrate_session) must not clobber user content in
# CLAUDE.md that happens not to mention '.cs/'.
test_migrate_preserves_user_claude_md() {
    local dir
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nDO-NOT-DELETE-THIS-LINE\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" "DO-NOT-DELETE-THIS-LINE" \
        "migrate must preserve the user's CLAUDE.md content" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "the user's CLAUDE.md must no longer gain the protocol" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "the protocol lands in CLAUDE.local.md" || return 1
}

# Idempotent: a second resume must not append the protocol twice.
test_migrate_claude_md_idempotent() {
    local dir count
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nkeep-me\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    count=$(grep -c 'cs:session-protocol' "$dir/CLAUDE.local.md")
    assert_eq "1" "$count" "protocol sentinel must appear exactly once after two resumes" || return 1
    assert_file_contains "$dir/CLAUDE.md" "keep-me" "user file untouched across resumes" || return 1
}

test_create_path_writes_local_md() {
    local dir="$CS_SESSIONS_ROOT/fresh"
    "$CS_BIN" "fresh" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "new session gets CLAUDE.local.md" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "new session gets no CLAUDE.md" || return 1
    assert_file_contains "$dir/.gitignore" "CLAUDE.local.md" \
        "session .gitignore covers the local file" || return 1
}

test_pure_cs_claude_md_moves_wholesale() {
    local dir
    dir=$(create_test_session "pure")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nSee .cs/ for metadata.\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "pure" < /dev/null > /dev/null 2>&1 || true
    assert_file_not_exists "$dir/CLAUDE.md" "pure cs file is removed after the move" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "content moved to CLAUDE.local.md" || return 1
}

test_mixed_claude_md_splits_at_first_sentinel() {
    local dir
    dir=$(create_test_session "mixed")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nprotocol body .cs/\n\n<!-- cs:memory-note -->\nnote body\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "mixed" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" "USER-KEEP" "user head stays" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" "cs sections left CLAUDE.md" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" "protocol in local file" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" "memory note rode along" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "USER-KEEP" "user head did not ride along" || return 1
}

test_pre_sentinel_template_left_alone() {
    local dir
    dir=$(create_test_session "presentinel")
    printf '# Session Documentation Protocol\n\nSession metadata lives in the .cs/ directory.\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "presentinel" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" ".cs/ directory" "pre-sentinel file untouched" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:memory-note" \
        "no managed sections scribbled into the legacy file" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:wrap-cues" \
        "no wrap-cues appended to the legacy file either" || return 1
    assert_file_not_exists "$dir/CLAUDE.local.md" "no second protocol file for pre-sentinel sessions" || return 1
}

test_user_local_md_never_overwritten() {
    local dir
    dir=$(create_test_session "userlocal")
    printf 'MY-PERSONAL-LOCAL-NOTES\n' > "$dir/CLAUDE.local.md"
    printf '<!-- cs:session-protocol -->\nprotocol body .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "userlocal" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "MY-PERSONAL-LOCAL-NOTES" \
        "a user-authored CLAUDE.local.md survives migration" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "cs content appended after the user's" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "the pure-cs CLAUDE.md is still consumed" || return 1
}

test_adopt_leaves_project_claude_md_alone() {
    # adopt_session resolves its target via `pwd -P` and symlinks it into
    # $SESSIONS_ROOT/<name> — the project directory itself must live OUTSIDE
    # $CS_SESSIONS_ROOT, or that symlink target collides with the fixture
    # and trips the pre-existing "session already exists" guard. Matches the
    # idiom in tests/test_adopt.sh ($TEST_TMPDIR/my-project, adopted as a
    # differently-named session).
    local dir="$TEST_TMPDIR/adoptme-proj"
    mkdir -p "$dir"
    printf '# Project Rules\nADOPT-KEEP-ONCE\n' > "$dir/CLAUDE.md"
    ( cd "$dir" && git init -q . 2>/dev/null ) || return 1
    ( cd "$dir" && "$CS_BIN" -adopt "adoptme" < /dev/null > /dev/null 2>&1 ) || true
    local n
    n=$(grep -c 'ADOPT-KEEP-ONCE' "$dir/CLAUDE.md")
    assert_eq "1" "$n" "adopt must not duplicate the project CLAUDE.md" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "the protocol stays out of the project file" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "adopt writes the local protocol file" || return 1
}

test_migration_idempotent_byte_for_byte() {
    local dir
    dir=$(create_test_session "idem")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\nprotocol .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cp "$dir/CLAUDE.md" "$dir/.first-md" && cp "$dir/CLAUDE.local.md" "$dir/.first-local"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cmp -s "$dir/CLAUDE.md" "$dir/.first-md" || { echo "  FAIL: CLAUDE.md changed on second run"; return 1; }
    cmp -s "$dir/CLAUDE.local.md" "$dir/.first-local" || { echo "  FAIL: CLAUDE.local.md changed on second run"; return 1; }
}

test_memory_note_lands_in_local_md() {
    local dir
    dir=$(create_test_session "note")
    printf '<!-- cs:session-protocol -->\nprotocol only, no note, references .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "note" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" \
        "Phase 9 adds the note to the local file" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "CLAUDE.md not recreated by Phase 9" || return 1
}

test_gitignore_backfill_idempotent() {
    local dir
    dir=$(create_test_session "gi")
    printf '*.tmp\n' > "$dir/.gitignore"
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    local n
    n=$(grep -c 'CLAUDE.local.md' "$dir/.gitignore")
    assert_eq "1" "$n" "gitignore entry added exactly once" || return 1
}

test_worktree_bootstrap_writes_local_md() {
    local dir
    dir=$(create_test_session "wtbase")
    ( cd "$dir" && git init -q . 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null ) || return 1
    "$CS_BIN" "wtbase@task1" < /dev/null > /dev/null 2>&1 || true
    if [ -d "$CS_SESSIONS_ROOT/wtbase@task1" ]; then
        assert_file_contains "$CS_SESSIONS_ROOT/wtbase@task1/CLAUDE.local.md" "cs:session-protocol" \
            "worktree session gets its own protocol file" || return 1
    else
        echo "  FAIL: worktree session was not created"
        return 1
    fi
}

run_test test_migrate_preserves_user_claude_md
run_test test_migrate_claude_md_idempotent
run_test test_create_path_writes_local_md
run_test test_pure_cs_claude_md_moves_wholesale
run_test test_mixed_claude_md_splits_at_first_sentinel
run_test test_pre_sentinel_template_left_alone
run_test test_user_local_md_never_overwritten
run_test test_adopt_leaves_project_claude_md_alone
run_test test_migration_idempotent_byte_for_byte
run_test test_memory_note_lands_in_local_md
run_test test_gitignore_backfill_idempotent
run_test test_worktree_bootstrap_writes_local_md

report_results
