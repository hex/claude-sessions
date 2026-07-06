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
    assert_file_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "migrate must add the cs session protocol" || return 1
}

# Idempotent: a second resume must not append the protocol twice.
test_migrate_claude_md_idempotent() {
    local dir count
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nkeep-me\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    count=$(grep -c 'cs:session-protocol' "$dir/CLAUDE.md")
    assert_eq "1" "$count" "protocol sentinel must appear exactly once after two resumes" || return 1
}

run_test test_migrate_preserves_user_claude_md
run_test test_migrate_claude_md_idempotent

report_results
