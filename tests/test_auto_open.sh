#!/usr/bin/env bash
# ABOUTME: Tests for bare `cs` opening the session you are standing in
# ABOUTME: Covers the cwd -> session-name resolver and the dispatch that uses it

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Resolve a directory to the session name cs knows it by, in a subshell holding
# the fixture root. Prints the name, or nothing when the directory is not a
# session cs can open.
_resolve_from() {  # dir
    (
        SESSIONS_ROOT="$CS_SESSIONS_ROOT"
        # shellcheck source=lib/65-sessions.sh
        source "$SCRIPT_DIR/../lib/65-sessions.sh"
        _session_name_for_dir "$1" || true
    )
}

# ============================================================================
# Cycle 1: a session directory resolves to its name
# ============================================================================

test_session_directory_resolves_to_its_name() {
    local dir
    dir=$(create_test_session "alpha")

    assert_eq "alpha" "$(_resolve_from "$dir")" \
        "a session directory should resolve to the name cs knows it by" || return 1
}

# ============================================================================
# Cycle 2: an adopted session resolves to the name it was adopted under, not
# the basename of the project directory it lives at
# ============================================================================

test_adopted_session_resolves_to_the_name_it_was_adopted_under() {
    local project="$TEST_TMPDIR/work/some-repo"
    mkdir -p "$project/.cs"
    ln -s "$project" "$CS_SESSIONS_ROOT/adopted-name"

    assert_eq "adopted-name" "$(_resolve_from "$project")" \
        "an adopted session should resolve to its cs name, not its directory name" || return 1
}

# ============================================================================
# The four directories that must NOT resolve, or must resolve to exactly one
# name. Every one of them is a way to open the wrong session, or a session that
# has no name to open.
# ============================================================================

test_feature_worktree_resolves_to_its_full_name() {
    local dir="$CS_SESSIONS_ROOT/base@feature"
    mkdir -p "$dir/.cs"

    # base@feature is the name every other surface takes; resolving to 'base'
    # would open the base checkout from inside the feature worktree.
    assert_eq "base@feature" "$(_resolve_from "$dir")" \
        "a feature worktree should resolve to <base>@<feature>" || return 1
}

test_subdirectory_of_a_session_does_not_resolve() {
    local dir
    dir=$(create_test_session "gamma")
    mkdir -p "$dir/lib"

    assert_eq "" "$(_resolve_from "$dir/lib")" \
        "standing inside a session, not at its root, should fall through to the picker" || return 1
}

test_nested_session_below_a_session_does_not_resolve() {
    local dir
    dir=$(create_test_session "delta")
    mkdir -p "$dir/vendor/other/.cs"

    # Two levels below the root there is no name to open: cs addresses sessions
    # by the single path element under the sessions root.
    assert_eq "" "$(_resolve_from "$dir/vendor/other")" \
        "a .cs directory nested below a session should not resolve to a name" || return 1
}

test_legacy_claude_md_directory_does_not_resolve() {
    local dir="$CS_SESSIONS_ROOT/legacy"
    mkdir -p "$dir"
    echo "# Session" > "$dir/CLAUDE.md"

    # is_session_dir accepts this shape for listing. Opening is a stronger
    # claim, and a bare CLAUDE.md is carried by nearly every repo.
    assert_eq "" "$(_resolve_from "$dir")" \
        "a directory marked only by CLAUDE.md should not resolve to a session" || return 1
}

test_unregistered_session_outside_the_root_does_not_resolve() {
    local dir="$TEST_TMPDIR/elsewhere/clone"
    mkdir -p "$dir/.cs"

    assert_eq "" "$(_resolve_from "$dir")" \
        "a .cs directory cs has no session for should fall through to the picker" || return 1
}

# ============================================================================
# Cycle 3: bare `cs` in a session directory opens that session
# ============================================================================

# A fake picker on PATH. Bare `cs` prefers cs-tui wherever it resolves, and a
# test must never reach the real one — it would take over the terminal and hang.
# Its marker goes to stderr: stdout is the selection cs parses.
_stub_picker_dir() {
    local dir="$TEST_TMPDIR/stub-bin"
    mkdir -p "$dir"
    printf '#!/bin/sh\nprintf "PICKER_RAN\\n" >&2\nexit 0\n' > "$dir/cs-tui"
    chmod +x "$dir/cs-tui"
    printf '%s' "$dir"
}

# A fake claude that reports the session it was launched for.
_stub_claude() {
    local stub="$TEST_TMPDIR/claude-stub"
    printf '#!/bin/sh\nprintf "LAUNCHED %%s\\n" "$*"\n' > "$stub"
    chmod +x "$stub"
    printf '%s' "$stub"
}

# Run cs from a directory under a real pty, with both the picker and claude
# stubbed. Only a pty makes `[ -t 1 ]` true, and without one every assertion
# below would be measuring the non-interactive cheat-sheet instead.
_cs_in() {  # dir, args...
    local dir="$1"; shift
    local stubdir claude_stub
    stubdir=$(_stub_picker_dir)
    claude_stub=$(_stub_claude)
    (
        cd "$dir" || exit 1
        export PATH="$stubdir:$PATH"
        export CLAUDE_CODE_BIN="$claude_stub"
        # The suite runs inside a live cs session, whose exported session name
        # would suppress auto-open in every test here. Each test states its own.
        if [ -n "${TEST_LIVE_SESSION_NAME:-}" ]; then
            export CLAUDE_SESSION_NAME="$TEST_LIVE_SESSION_NAME"
        else
            unset CLAUDE_SESSION_NAME
        fi
        export CS_TERM_THEME=dark
        _pty_run "$CS_BIN" "$@" 2>&1
    ) | tr -d '\r'
}

test_bare_cs_in_a_session_directory_opens_that_session() {
    local dir
    dir=$(create_test_session "epsilon")

    local out
    out=$(_cs_in "$dir")

    assert_output_contains "$out" "LAUNCHED --name epsilon" \
        "bare cs in a session directory should open that session" || return 1
    assert_output_not_contains "$out" "PICKER_RAN" \
        "bare cs in a session directory should not reach the picker" || return 1
}

test_adopted_session_opens_under_its_cs_name() {
    local project="$TEST_TMPDIR/work/some-repo"
    mkdir -p "$project/.cs"
    ln -s "$project" "$CS_SESSIONS_ROOT/adopted-name"

    local out
    out=$(_cs_in "$project")

    # 'some-repo' here would open — and create — a session that is not this one.
    assert_output_contains "$out" "LAUNCHED --name adopted-name" \
        "an adopted project should open under the name it was adopted as" || return 1
    assert_output_not_contains "$out" "--name some-repo" \
        "the project's directory name is not a session name" || return 1
}

# ============================================================================
# Cycle 4: the picker is still reachable — from inside a live session, by
# name, and everywhere that is not a session
# ============================================================================

test_bare_cs_inside_a_launched_session_shows_the_picker() {
    local dir
    dir=$(create_test_session "zeta")

    local out
    export TEST_LIVE_SESSION_NAME="zeta"
    out=$(_cs_in "$dir")
    unset TEST_LIVE_SESSION_NAME

    # A shell inside a launched session inherits its name. Opening the session
    # again from there is never the intent, and the lock would refuse it anyway.
    assert_output_contains "$out" "PICKER_RAN" \
        "bare cs inside a launched session should show the picker" || return 1
    assert_output_not_contains "$out" "LAUNCHED" \
        "bare cs inside a launched session should not open a second copy" || return 1
}

test_tui_verb_shows_the_picker_from_inside_a_session_directory() {
    local dir
    dir=$(create_test_session "eta")

    local out
    out=$(_cs_in "$dir" -tui)

    assert_output_contains "$out" "PICKER_RAN" \
        "cs -tui should show the picker even where bare cs would open a session" || return 1
    assert_output_not_contains "$out" "LAUNCHED" \
        "cs -tui should not open the session it is standing in" || return 1
}

test_bare_cs_outside_any_session_shows_the_picker() {
    local dir="$TEST_TMPDIR/somewhere"
    mkdir -p "$dir"

    local out
    out=$(_cs_in "$dir")

    assert_output_contains "$out" "PICKER_RAN" \
        "bare cs outside a session should still show the picker" || return 1
}

# ============================================================================
# Cycle 5: opening by standing in the directory is the same open as by name,
# including its refusals
# ============================================================================

test_bare_cs_refuses_a_session_that_is_already_running() {
    local dir
    dir=$(create_test_session "theta")
    printf 'claude_session_id: 11111111-2222-4333-8444-555555555555\n' \
        > "$dir/.cs/local/state"

    # The live-duplicate guard reads ps; CS_PS_BIN is its test seam.
    local ps_stub="$TEST_TMPDIR/ps-stub"
    printf '#!/bin/sh\nprintf "claude --name theta\\n"\n' > "$ps_stub"
    chmod +x "$ps_stub"

    local out
    export CS_PS_BIN="$ps_stub"
    out=$(_cs_in "$dir")
    unset CS_PS_BIN

    assert_output_contains "$out" "already running elsewhere" \
        "bare cs should refuse a live session exactly as 'cs <name>' does" || return 1
    assert_output_not_contains "$out" "LAUNCHED" \
        "a refused open must not reach claude" || return 1
}

test_list_hint_names_the_command_that_reaches_the_picker() {
    local dir
    dir=$(create_test_session "iota")

    local inside outside
    inside=$(_cs_in "$dir" -list)
    outside=$(_cs_in "$CS_SESSIONS_ROOT" -list)

    assert_output_contains "$inside" "cs -tui" \
        "inside a session, the -list hint should name 'cs -tui'" || return 1
    assert_output_contains "$outside" "bare 'cs'" \
        "outside a session, the -list hint should still name bare cs" || return 1
}

# ============================================================================
# Cycle 6: the machine with no picker installed still gets an answer
# ============================================================================

test_bare_cs_without_a_picker_falls_back_to_help() {
    # Two ways cs finds the picker, and this case has to defeat both: a copy
    # with no cs-tui beside it, run on a PATH with the picker's directory
    # removed. Every other test here stages a fake picker, so nothing else
    # reaches the arm where cs has none.
    local bindir="$TEST_TMPDIR/no-picker"
    mkdir -p "$bindir"
    cp "$CS_BIN" "$bindir/cs"
    chmod +x "$bindir/cs"

    # Every directory holding one, not just the first `command -v` answer: this
    # host carries two (an install and a cargo build), and dropping one left the
    # picker reachable — the test then measured the picker, not this arm.
    local slim
    slim=$(printf '%s' "$PATH" | tr ':' '\n' \
        | while IFS= read -r d; do [ -x "$d/cs-tui" ] || printf '%s\n' "$d"; done \
        | paste -sd: -)
    if PATH="$slim" command -v cs-tui >/dev/null 2>&1; then
        echo "  FAIL: harness could not build a PATH without cs-tui"
        return 1
    fi

    # Wrapped so the exit status survives the pty: the regression this pins
    # printed nothing and exited 1, where the contract is help and exit 0.
    local runner="$TEST_TMPDIR/run-cs.sh"
    printf '#!/bin/sh\n"%s"\nprintf "EXIT=%%s\\n" "$?"\n' "$bindir/cs" > "$runner"
    chmod +x "$runner"

    local where="$TEST_TMPDIR/not-a-session"
    mkdir -p "$where"

    local out
    out=$(
        cd "$where" || exit 1
        export PATH="$slim"
        unset CLAUDE_SESSION_NAME
        export CS_TERM_THEME=dark
        _pty_run "$runner" 2>&1
    ) || true
    out=$(printf '%s' "$out" | tr -d '\r')

    assert_output_contains "$out" "Create or resume a session" \
        "without a picker, bare cs should fall back to the full help" || return 1
    assert_output_contains "$out" "EXIT=0" \
        "falling back to help is not an error" || return 1
}

echo ""
echo "cs auto-open tests"
echo "=================="
echo ""

run_test test_session_directory_resolves_to_its_name
run_test test_adopted_session_resolves_to_the_name_it_was_adopted_under
run_test test_feature_worktree_resolves_to_its_full_name
run_test test_subdirectory_of_a_session_does_not_resolve
run_test test_nested_session_below_a_session_does_not_resolve
run_test test_legacy_claude_md_directory_does_not_resolve
run_test test_unregistered_session_outside_the_root_does_not_resolve
run_test test_bare_cs_in_a_session_directory_opens_that_session
run_test test_adopted_session_opens_under_its_cs_name
run_test test_bare_cs_inside_a_launched_session_shows_the_picker
run_test test_tui_verb_shows_the_picker_from_inside_a_session_directory
run_test test_bare_cs_outside_any_session_shows_the_picker
run_test test_bare_cs_refuses_a_session_that_is_already_running
run_test test_list_hint_names_the_command_that_reaches_the_picker
run_test test_bare_cs_without_a_picker_falls_back_to_help

report_results
