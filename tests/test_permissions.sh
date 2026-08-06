#!/usr/bin/env bash
# ABOUTME: Tests that cs keeps its own session data private without touching user dirs.
# ABOUTME: Covers create, adopt (must not re-permission a project), and the migrate backfill.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# BSD stat, not GNU `stat -c`: the floor is macOS userland.
_mode() {  # path -> e.g. drwx------
    stat -f '%Sp' "$1" 2>/dev/null
}

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
    # A permissive root and a permissive umask: the shape in which the defect is
    # visible. On a machine whose ~/.claude-sessions happens to be 0700 the
    # session modes are masked by the parent and the bug hides.
    chmod 755 "$CS_SESSIONS_ROOT"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN 2>/dev/null || true
}

test_create_keeps_session_data_private_under_a_lax_umask() {
    ( umask 022; "$CS_BIN" alpha <<< "" >/dev/null 2>&1 ) || true
    local sdir="$CS_SESSIONS_ROOT/alpha"
    assert_dir "$sdir" "the session was created" || return 1
    # Fixture sanity: under umask 022 a bare mkdir yields 0755, so a 0700 result
    # can only come from cs setting it.
    ( umask 022; mkdir -p "$TEST_TMPDIR/control" )
    assert_eq "drwxr-xr-x" "$(_mode "$TEST_TMPDIR/control")" \
        "control: the umask really is 022, or this test proves nothing" || return 1

    # Only .cs itself is set: reaching anything inside needs execute on it, so
    # a private .cs makes every file and subdirectory under it unreachable to
    # others whatever their own modes are.
    assert_eq "drwx------" "$(_mode "$sdir/.cs")" \
        "the session's own data directory is private" || return 1
    assert_eq "drwx------" "$(_mode "$sdir")" \
        "and so is a session root cs created" || return 1
}

test_adopt_does_not_re_permission_the_user_project() {
    # adopt calls create_session_structure with the user's OWN directory. Their
    # project may be deliberately group- or world-readable — a shared checkout, a
    # served directory — and cs has no business changing that. Only the .cs/
    # tree it creates inside is cs's to lock down.
    local proj="$TEST_TMPDIR/myproject"
    mkdir -p "$proj"
    chmod 755 "$proj"
    echo "# project" > "$proj/README.md"
    ( cd "$proj" && git init -q && git config user.email a@example.com \
        && git config user.name Tester && git add -A && git commit -q -m init )
    assert_eq "drwxr-xr-x" "$(_mode "$proj")" "fixture: the project starts world-readable" || return 1

    ( umask 022; cd "$proj" && "$CS_BIN" -adopt adopted <<< "" >/dev/null 2>&1 ) || true
    assert_dir "$proj/.cs" "adopt created the session data directory" || return 1

    assert_eq "drwxr-xr-x" "$(_mode "$proj")" \
        "cs must not change the mode of a directory the user already had" || return 1
    assert_eq "drwx------" "$(_mode "$proj/.cs")" \
        "but the data cs writes inside it is private" || return 1
}

test_open_tightens_an_existing_world_readable_session() {
    # Sessions created before cs set a mode are still 0755 on disk. Opening one
    # must bring it up to the current contract rather than leaving the older
    # sessions — the ones with the most history in them — permanently exposed.
    local sdir="$CS_SESSIONS_ROOT/legacy"
    mkdir -p "$sdir/.cs"/{local,memory}
    cat > "$sdir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-01-01
tags: []
aliases: ["legacy"]
---
# Session: legacy

## Objective
Pre-existing session
EOF
    chmod 755 "$sdir" "$sdir/.cs" "$sdir/.cs/local"
    assert_eq "drwxr-xr-x" "$(_mode "$sdir/.cs")" "fixture: starts world-readable" || return 1

    ( umask 022; "$CS_BIN" legacy <<< "" >/dev/null 2>&1 ) || true
    assert_eq "drwx------" "$(_mode "$sdir/.cs")" \
        "opening an existing session tightens its data directory" || return 1
    assert_eq "drwx------" "$(_mode "$sdir")" \
        "and its root" || return 1
}

test_open_does_not_tighten_an_adopted_project_root() {
    # The backfill has the same boundary as create: an adopted session's root is
    # the user's project, reached through a symlink. Tightening it on open would
    # re-permission their directory behind their back, on every launch.
    local proj="$TEST_TMPDIR/adoptedproj"
    mkdir -p "$proj"
    chmod 755 "$proj"
    echo "# project" > "$proj/README.md"
    ( cd "$proj" && git init -q && git config user.email a@example.com \
        && git config user.name Tester && git add -A && git commit -q -m init )
    ( umask 022; cd "$proj" && "$CS_BIN" -adopt adopted2 <<< "" >/dev/null 2>&1 ) || true
    assert_exists "$CS_SESSIONS_ROOT/adopted2" "adopt created the session link" || return 1
    chmod 755 "$proj"

    ( umask 022; "$CS_BIN" adopted2 <<< "" >/dev/null 2>&1 ) || true
    assert_eq "drwxr-xr-x" "$(_mode "$proj")" \
        "re-opening an adopted session must not re-permission the project root" || return 1
    assert_eq "drwx------" "$(_mode "$proj/.cs")" \
        "the data directory is still brought private" || return 1
}

run_test test_create_keeps_session_data_private_under_a_lax_umask
run_test test_adopt_does_not_re_permission_the_user_project
run_test test_open_tightens_an_existing_world_readable_session
run_test test_open_does_not_tighten_an_adopted_project_root

report_results
