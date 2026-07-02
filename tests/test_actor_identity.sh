#!/usr/bin/env bash
# ABOUTME: Tests for actor identity resolution (cs_actor_slug, _slugify, cs whoami)
# ABOUTME: Validates precedence (env > local file > git email > git name) and slug safety

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_ACTOR
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# Run cs whoami inside an adopted project and capture the actor line.
_whoami_in() {
    # $1 = project dir
    ( cd "$1" && CLAUDE_SESSION_META_DIR="$1/.cs" "$CS_BIN" -whoami 2>/dev/null )
}

test_actor_slug_from_git_email() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "Alex.Geana@Example.com" && git config user.name "Alex Geana" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    local out
    out=$(_whoami_in "$project_dir")
    assert_output_contains "$out" "alex-geana-example-com" "slug should derive from normalized git email" || return 1
}

test_actor_slug_env_override_wins() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    local out
    out=$( cd "$project_dir" && CLAUDE_SESSION_META_DIR="$project_dir/.cs" CS_ACTOR="Bob The Builder" "$CS_BIN" -whoami 2>/dev/null )
    assert_output_contains "$out" "bob-the-builder" "CS_ACTOR env should override git identity" || return 1
}

test_actor_slug_local_file_over_git() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    mkdir -p "$project_dir/.cs/local"
    printf 'carol@team.io\n' > "$project_dir/.cs/local/identity"

    local out
    out=$(_whoami_in "$project_dir")
    assert_output_contains "$out" "carol-team-io" "local/identity file should override git identity" || return 1
}

test_whoami_warns_on_identity_mismatch() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    mkdir -p "$project_dir/.cs/local"
    printf 'carol@team.io\n' > "$project_dir/.cs/local/identity"

    local out
    out=$( cd "$project_dir" && CLAUDE_SESSION_META_DIR="$project_dir/.cs" "$CS_BIN" -whoami 2>&1 )
    assert_output_contains "$out" "differs from git identity" "whoami should warn when local identity != git identity" || return 1
}
test_local_dir_created_on_adopt() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    assert_dir "$project_dir/.cs/local" ".cs/local/ should be created on adopt" || return 1
}

test_guard_blocks_tracked_local() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    # Simulate the bad state: per-actor local state committed to git.
    ( cd "$project_dir" && echo leak > .cs/local/oops && git add -f .cs/local/oops && git commit -q -m bad )

    # Resuming the session must refuse while .cs/local is tracked.
    local out
    out=$( "$CS_BIN" s1 <<< "" 2>&1 || true )
    assert_output_contains "$out" ".cs/local/ is tracked" "guard should report tracked .cs/local/" || return 1
}

test_narrative_is_per_actor() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" && git config user.name "Alex" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    assert_exists "$project_dir/.cs/memory/narrative.alex-example-com.md" \
        "per-actor narrative file should exist" || return 1
    assert_not_exists "$project_dir/.cs/memory/narrative.md" \
        "generic narrative.md should not be created for a new session" || return 1
    assert_file_contains "$project_dir/.cs/memory/MEMORY.md" "narrative.alex-example-com.md" \
        "index should point at the per-actor narrative" || return 1
}

test_legacy_narrative_migrates_to_actor() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "bob@team.io" && git config user.name "Bob" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    # Revert to a pre-Phase-2 legacy state: a single narrative.md + legacy index pointer.
    rm -f "$project_dir/.cs/memory/narrative.bob-team-io.md"
    printf '%s\n' '# Session narrative' 'OLD ENTRY ABC' > "$project_dir/.cs/memory/narrative.md"
    printf '%s\n' '- [Session narrative (lab notebook)](narrative.md): old' > "$project_dir/.cs/memory/MEMORY.md"

    # Resume the session -> migrate_session -> ensure_narrative_file migrates it.
    ( "$CS_BIN" s1 <<< "" >/dev/null 2>&1 || true )

    assert_exists "$project_dir/.cs/memory/narrative.bob-team-io.md" \
        "legacy narrative.md should migrate to the actor's file" || return 1
    assert_not_exists "$project_dir/.cs/memory/narrative.md" \
        "legacy narrative.md should be gone after migration" || return 1
    assert_file_contains "$project_dir/.cs/memory/narrative.bob-team-io.md" "OLD ENTRY ABC" \
        "migrated narrative should keep its content" || return 1
    assert_file_not_contains "$project_dir/.cs/memory/MEMORY.md" "(narrative.md)" \
        "stale legacy index pointer should be removed" || return 1
}

test_who_lists_contributors() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name Alice )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    ( cd "$project_dir" && mkdir -p .cs/memory && echo m1 > .cs/memory/m1.md \
        && git add -A && git commit -q -m m1 --author="Bob <bob@x.io>" )

    local out
    out=$( cd "$project_dir" && "$CS_BIN" -who 2>&1 )
    assert_output_contains "$out" "Contributors" "who should print a contributors header" || return 1
    assert_output_contains "$out" "Bob" "who should list a contributing author" || return 1
}

test_who_lists_contributors_in_linked_worktree() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name Alice )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    ( cd "$project_dir" && mkdir -p .cs/memory && echo m1 > .cs/memory/m1.md \
        && git add -A && git commit -q -m m1 --author="Bob <bob@x.io>" )
    git -C "$project_dir" worktree add -b cs/t1 "$TEST_TMPDIR/proj-t1" -q

    local out
    out=$( CLAUDE_SESSION_DIR="$TEST_TMPDIR/proj-t1" "$CS_BIN" -who 2>&1 )
    assert_output_contains "$out" "Contributors" \
        "who should print a contributors header from a linked worktree (.git is a file)" || return 1
    assert_output_contains "$out" "Bob" \
        "who should list a contributing author from a linked worktree" || return 1
}

test_migrate_adds_local_to_existing_gitignore() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    # Simulate a pre-6.10 session: a .gitignore that predates the .cs/local/ rule.
    printf '%s\n' '*.log' 'node_modules/' > "$project_dir/.gitignore"

    # Resume the session -> migrate_session should backfill the ignore entry.
    ( "$CS_BIN" s1 <<< "" >/dev/null 2>&1 || true )

    assert_file_contains "$project_dir/.gitignore" ".cs/local/" \
        "resume should add .cs/local/ to an existing .gitignore" || return 1
    assert_file_contains "$project_dir/.gitignore" "node_modules/" \
        "resume must not clobber existing .gitignore entries" || return 1
}

echo ""
echo "cs actor identity tests"
echo "======================="
echo ""

run_test test_actor_slug_from_git_email
run_test test_actor_slug_env_override_wins
run_test test_actor_slug_local_file_over_git
run_test test_whoami_warns_on_identity_mismatch
run_test test_local_dir_created_on_adopt
run_test test_guard_blocks_tracked_local
run_test test_narrative_is_per_actor
run_test test_legacy_narrative_migrates_to_actor
run_test test_who_lists_contributors
run_test test_who_lists_contributors_in_linked_worktree
run_test test_migrate_adds_local_to_existing_gitignore

report_results
