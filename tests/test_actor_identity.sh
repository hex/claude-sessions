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

echo ""
echo "cs actor identity tests"
echo "======================="
echo ""

run_test test_actor_slug_from_git_email
run_test test_actor_slug_env_override_wins
run_test test_actor_slug_local_file_over_git
run_test test_whoami_warns_on_identity_mismatch
run_test test_local_dir_created_on_adopt

report_results
