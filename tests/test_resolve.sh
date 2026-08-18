#!/usr/bin/env bash
# ABOUTME: Tests for cs-resolve.sh, the hook-side session resolver
# ABOUTME: Covers env-first precedence and the cwd walk-up fallback desktop needs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"
RESOLVER="$HOOKS_DIR/cs-resolve.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # CS_ACTOR and the session env are the inputs under test; a developer's
    # exported ones would decide the result instead of the fixture.
    unset CS_ACTOR CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    unset CLAUDE_PROJECT_DIR CLAUDE_CODE_ENTRYPOINT
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_PROJECT_DIR
    unset CLAUDE_CODE_ENTRYPOINT
}

# Run the resolver in a subshell and print the resolved triple, or FAIL.
_resolve() {  # input_json
    (
        # shellcheck disable=SC1090
        . "$RESOLVER" || exit 9
        if cs_resolve_session "${1:-{\}}"; then
            printf '%s|%s|%s\n' "$CLAUDE_SESSION_NAME" "$CLAUDE_SESSION_DIR" "$CLAUDE_SESSION_META_DIR"
        else
            printf 'FAIL\n'
        fi
    )
}

_make_session() {  # dir [name]
    mkdir -p "$1/.cs/local"
    [ -n "${2:-}" ] && printf 'session_name: %s\n' "$2" > "$1/.cs/local/state"
    return 0
}

# The resolver reports physical paths (cd + pwd -P, the lib/30-worktree.sh
# idiom), which is also what the front ends hand a hook: a desktop session
# opened on /tmp reports /private/tmp. Expectations must match that, or every
# case fails on macOS for the symlink rather than for the behaviour.
_phys() {  # dir
    (cd "$1" 2>/dev/null && pwd -P)
}

# ============================================================================
# Env-first: the CLI path must be bit-identical, so a set env wins outright
# ============================================================================

test_env_contract_is_used_verbatim() {
    _make_session "$TEST_TMPDIR/envsess"
    export CLAUDE_SESSION_NAME="from-env"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/envsess"
    export CLAUDE_SESSION_META_DIR="$TEST_TMPDIR/envsess/.cs"
    local got
    got=$(_resolve '{}')
    assert_eq "from-env|$TEST_TMPDIR/envsess|$TEST_TMPDIR/envsess/.cs" "$got" \
        "a set env contract is used as-is" || return 1
}

# A session dir that no longer exists is not a session, however the env reads.
test_env_contract_with_missing_dir_fails() {
    export CLAUDE_SESSION_NAME="ghost"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/does-not-exist"
    local got
    got=$(_resolve '{}')
    assert_eq "FAIL" "$got" "a vanished session dir does not resolve" || return 1
}

# ============================================================================
# Derivation: what desktop needs, since it can publish no env to the session
# ============================================================================

test_derives_from_project_dir() {
    _make_session "$TEST_TMPDIR/proj" "proj"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/proj"
    local got
    got=$(_resolve '{}')
    assert_eq "proj|$(_phys "$TEST_TMPDIR/proj")|$(_phys "$TEST_TMPDIR/proj")/.cs" "$got" \
        "resolves from CLAUDE_PROJECT_DIR" || return 1
}

test_derives_from_input_cwd_when_project_dir_absent() {
    _make_session "$TEST_TMPDIR/viacwd" "viacwd"
    local got
    got=$(_resolve "{\"cwd\":\"$TEST_TMPDIR/viacwd\"}")
    assert_eq "viacwd|$(_phys "$TEST_TMPDIR/viacwd")|$(_phys "$TEST_TMPDIR/viacwd")/.cs" "$got" \
        "falls back to the hook input's cwd" || return 1
}

# Opening a subfolder of a session is a normal thing to do in a GUI.
test_walks_up_from_a_subdirectory() {
    _make_session "$TEST_TMPDIR/deep" "deep"
    mkdir -p "$TEST_TMPDIR/deep/a/b/c"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/deep/a/b/c"
    local got
    got=$(_resolve '{}')
    assert_eq "deep|$(_phys "$TEST_TMPDIR/deep")|$(_phys "$TEST_TMPDIR/deep")/.cs" "$got" \
        "walks up to the nearest .cs" || return 1
}

# The nearest .cs wins: a session cloned inside a session belongs to itself.
test_nearest_session_wins() {
    _make_session "$TEST_TMPDIR/outer" "outer"
    _make_session "$TEST_TMPDIR/outer/inner" "inner"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/outer/inner"
    local got
    got=$(_resolve '{}')
    assert_eq "inner|$(_phys "$TEST_TMPDIR/outer/inner")|$(_phys "$TEST_TMPDIR/outer/inner")/.cs" "$got" \
        "the nearest .cs wins over an enclosing one" || return 1
}

test_no_session_anywhere_fails() {
    mkdir -p "$TEST_TMPDIR/plain/sub"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/plain/sub"
    local got
    got=$(_resolve '{}')
    assert_eq "FAIL" "$got" "a plain directory is not a cs session" || return 1
}

# ============================================================================
# Naming: the symlink name a session was adopted under is not its basename
# ============================================================================

test_name_comes_from_state_not_basename() {
    _make_session "$TEST_TMPDIR/real-project-dir" "chosen-name"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/real-project-dir"
    local got
    got=$(_resolve '{}')
    assert_eq "chosen-name|$(_phys "$TEST_TMPDIR/real-project-dir")|$(_phys "$TEST_TMPDIR/real-project-dir")/.cs" "$got" \
        "session_name in local state outranks the directory basename" || return 1
}

# The two tests above hand-write the state file. Neither says whether cs ever
# writes it — and while it did not, the name lookup could only ever return the
# basename, which is wrong for exactly the session shape it exists to serve.
# This one runs the real `cs -adopt` and asks the resolver what it sees.
test_adopt_records_the_name_the_resolver_reads() {
    local proj="$TEST_TMPDIR/code/some-repo"
    mkdir -p "$proj"
    (
        cd "$proj" \
            && CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions" "$CS_BIN" -adopt chosen-name
    ) >/dev/null 2>&1 || { echo "  FAIL: cs -adopt did not complete"; return 1; }

    export CLAUDE_PROJECT_DIR="$proj"
    local got
    got=$(_resolve '{}')
    assert_eq "chosen-name|$(_phys "$proj")|$(_phys "$proj")/.cs" "$got" \
        "an adopted project resolves to its cs name, not its directory name" || return 1
}

# Every session adopted before cs recorded the name carries no key at all, and
# adopt never runs again for them. Opening one through cs is the moment cs knows
# both the name and the directory, so that is where the backfill belongs.
test_opening_an_adopted_session_backfills_the_name() {
    local root="$TEST_TMPDIR/sessions"
    local proj="$TEST_TMPDIR/code/some-repo"
    mkdir -p "$proj/.cs/local" "$root"
    printf -- '---\nstatus: active\n---\n# Session: legacy-adopted\n' > "$proj/.cs/README.md"
    ln -s "$proj" "$root/legacy-adopted"

    # The launch asks "Continue previous conversation?". An attached stdin hangs
    # the suite; /dev/null reads as EOF and cs cancels with 130. A blank line is
    # the answer that takes the default and completes the open.
    CS_SESSIONS_ROOT="$root" CLAUDE_CODE_BIN="echo" CS_NO_UPDATE_CHECK=1 \
        CS_TERM_THEME=dark "$CS_BIN" legacy-adopted >/dev/null 2>&1 <<< "" \
        || { echo "  FAIL: opening the adopted session did not complete"; return 1; }

    export CLAUDE_PROJECT_DIR="$proj"
    local got
    got=$(_resolve '{}')
    assert_eq "legacy-adopted|$(_phys "$proj")|$(_phys "$proj")/.cs" "$got" \
        "opening an adopted session should teach the resolver its name" || return 1
}

# The other side of that decision. An ordinary session IS its directory, so it
# records no name and the basename stays authoritative — which is what keeps a
# renamed session resolving to what cs now calls it, rather than to a recorded
# name that nothing updates until the next launch.
test_a_renamed_ordinary_session_resolves_to_its_new_name() {
    local root="$TEST_TMPDIR/sessions"
    mkdir -p "$root"
    CS_SESSIONS_ROOT="$root" CLAUDE_CODE_BIN="echo" CS_NO_UPDATE_CHECK=1 \
        CS_TERM_THEME=dark "$CS_BIN" oldname >/dev/null 2>&1 <<< "" \
        || { echo "  FAIL: creating the session did not complete"; return 1; }
    mv "$root/oldname" "$root/newname"

    export CLAUDE_PROJECT_DIR="$root/newname"
    local got
    got=$(_resolve '{}')
    assert_eq "newname|$(_phys "$root/newname")|$(_phys "$root/newname")/.cs" "$got" \
        "a renamed ordinary session resolves to the name cs now knows it by" || return 1
}

test_name_falls_back_to_basename() {
    _make_session "$TEST_TMPDIR/unnamed"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/unnamed"
    local got
    got=$(_resolve '{}')
    assert_eq "unnamed|$(_phys "$TEST_TMPDIR/unnamed")|$(_phys "$TEST_TMPDIR/unnamed")/.cs" "$got" \
        "basename is the fallback name" || return 1
}

# ============================================================================
# Opt-out: after this change a bare `claude` in a session dir is no longer
# cs-blind, so anyone relying on that inertness needs a way back.
# ============================================================================

test_disabled_marker_opts_out() {
    _make_session "$TEST_TMPDIR/optout" "optout"
    touch "$TEST_TMPDIR/optout/.cs/local/disabled"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/optout"
    local got
    got=$(_resolve '{}')
    assert_eq "FAIL" "$got" "a disabled marker opts the session out" || return 1
}

# A hook's working directory is wherever the front end left it, not a statement
# about which session is open. Resolving from it would bind hooks to whatever
# checkout a tool happened to run inside.
test_pwd_alone_does_not_resolve() {
    _make_session "$TEST_TMPDIR/nearby" "nearby"
    local got
    got=$(cd "$TEST_TMPDIR/nearby" && _resolve '{}')
    assert_eq "FAIL" "$got" "cwd alone is not a session signal" || return 1
}

# A hook must still decline, not die, when the resolver is missing: a partial
# install or an upgrade from a cs version that shipped no library would
# otherwise abort every hook under set -e, and the two that answer with an
# approval payload would answer with nothing at all.
test_hooks_decline_when_the_resolver_is_missing() {
    local hooks_src="$SCRIPT_DIR/../hooks" fake="$TEST_TMPDIR/nolib"
    mkdir -p "$fake"
    # Run under cs's actual floor, not the shell running the suite. A `.` of a
    # missing file kills a non-interactive bash 3.2 outright, where bash 5 lets
    # `||` catch it, so this exact defect is invisible to a homebrew-bash run.
    local sh=/bin/bash
    [ -x "$sh" ] || sh=bash
    local h rc out failures=0
    for h in narrative-reminder session-start autosave-commits; do
        cp "$hooks_src/$h.sh" "$fake/"
    done
    for h in narrative-reminder session-start autosave-commits; do
        out=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_PROJECT_DIR \
            "$sh" "$fake/$h.sh" <<< '{"tool_name":"Write","cwd":"/"}' 2>/dev/null)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "  FAIL: $h.sh exited $rc without its resolver instead of declining"
            failures=$((failures + 1))
        fi
        case "$h" in
            narrative-reminder)
                case "$out" in
                    *approve*) : ;;
                    *) echo "  FAIL: $h.sh must still emit its approve payload, got [$out]"
                       failures=$((failures + 1)) ;;
                esac
                ;;
        esac
    done
    [ "$failures" -eq 0 ] || return 1
}

# A corrupt library is readable, so a bare `[ -r ]` test lets it through and the
# hook aborts at the syntax error before its fallback is even defined. A
# truncated download reaches this, and a payload hook that dies prints nothing.
test_hooks_decline_when_the_resolver_is_corrupt() {
    local fake="$TEST_TMPDIR/badlib" sh=/bin/bash
    [ -x "$sh" ] || sh=bash
    mkdir -p "$fake"
    cp "$SCRIPT_DIR/../hooks/narrative-reminder.sh" "$fake/"
    local case_name out rc failures=0
    for case_name in syntax empty; do
        case "$case_name" in
            syntax) printf 'this is ( not valid bash\n' > "$fake/cs-resolve.sh" ;;
            empty)  : > "$fake/cs-resolve.sh" ;;
        esac
        out=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_PROJECT_DIR \
            "$sh" "$fake/narrative-reminder.sh" <<< '{}' 2>/dev/null)
        rc=$?
        [ "$rc" -eq 0 ] || { echo "  FAIL: $case_name library made the hook exit $rc"; failures=$((failures + 1)); }
        case "$out" in
            *approve*) : ;;
            *) echo "  FAIL: $case_name library suppressed the approve payload, got [$out]"
               failures=$((failures + 1)) ;;
        esac
    done
    [ "$failures" -eq 0 ] || return 1
}

run_test test_hooks_decline_when_the_resolver_is_missing
run_test test_hooks_decline_when_the_resolver_is_corrupt

# A parse-check catches truncation but not a library that parses clean and then
# fails when run: an inserted conflict marker like ======= is a valid-looking
# command. Sourcing it dies at execution, and as the last command of the guard's
# && chain that aborts the hook. Exit 2 from a PreToolUse hook is Claude Code's
# blocking code, so this must degrade to a decline.
test_hooks_decline_when_the_resolver_fails_at_runtime() {
    local fake="$TEST_TMPDIR/runtimebad" sh=/bin/bash
    [ -x "$sh" ] || sh=bash
    mkdir -p "$fake"
    cp "$SCRIPT_DIR/../hooks/narrative-reminder.sh" "$fake/"
    cp "$SCRIPT_DIR/../hooks/cs-resolve.sh" "$fake/"
    printf '=======\n' >> "$fake/cs-resolve.sh"
    "$sh" -n "$fake/cs-resolve.sh" 2>/dev/null \
        || { echo "  FAIL: fixture must PARSE clean or it tests the wrong thing"; return 1; }
    local out rc
    out=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_PROJECT_DIR \
        "$sh" "$fake/narrative-reminder.sh" <<< '{}' 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: a runtime-failing library made the hook exit $rc"; return 1; }
    case "$out" in
        *approve*) : ;;
        *) echo "  FAIL: approve payload suppressed, got [$out]"; return 1 ;;
    esac
}

run_test test_hooks_decline_when_the_resolver_fails_at_runtime
run_test test_pwd_alone_does_not_resolve
run_test test_env_contract_is_used_verbatim
run_test test_env_contract_with_missing_dir_fails
run_test test_derives_from_project_dir
run_test test_derives_from_input_cwd_when_project_dir_absent
run_test test_walks_up_from_a_subdirectory
run_test test_nearest_session_wins
# The walk is documented as stopping AT $HOME. It tested the boundary after
# checking for .cs, so a stray ~/.cs would have adopted every project directly
# under home into a phantom session named after the home directory.
test_home_itself_is_not_a_session_root() {
    local fh="$TEST_TMPDIR/fakehome"
    mkdir -p "$fh/.cs/local" "$fh/proj"
    local got
    got=$(HOME="$fh" CLAUDE_PROJECT_DIR="$fh/proj" _resolve '{}')
    assert_eq "FAIL" "$got" "a stray .cs at \$HOME must not capture a project under it" || return 1
}

run_test test_home_itself_is_not_a_session_root
run_test test_no_session_anywhere_fails
run_test test_name_comes_from_state_not_basename
run_test test_adopt_records_the_name_the_resolver_reads
run_test test_opening_an_adopted_session_backfills_the_name
run_test test_a_renamed_ordinary_session_resolves_to_its_new_name
run_test test_name_falls_back_to_basename
# The marker applies to the env path too, so the opt-out means "this directory
# is not a cs session" rather than "keep one front end out".
test_disabled_marker_opts_out_on_the_env_path() {
    _make_session "$TEST_TMPDIR/optout-env" "optout-env"
    touch "$TEST_TMPDIR/optout-env/.cs/local/disabled"
    export CLAUDE_SESSION_NAME="optout-env"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/optout-env"
    local got
    got=$(_resolve '{}')
    assert_eq "FAIL" "$got" "the disabled marker silences a cs-launched session too" || return 1
}

run_test test_disabled_marker_opts_out
run_test test_disabled_marker_opts_out_on_the_env_path

# ============================================================================
# Terminal CLI: a session is only ever entered there through `cs`, which
# exports the contract, so the directory the shell happens to sit in says
# nothing. Claude Code names its own front end in CLAUDE_CODE_ENTRYPOINT.
# ============================================================================

test_terminal_cli_does_not_derive_from_the_directory() {
    _make_session "$TEST_TMPDIR/bare" "bare"
    export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/bare"
    export CLAUDE_CODE_ENTRYPOINT="cli"
    local got
    got=$(_resolve '{}')
    assert_eq "FAIL" "$got" "a bare terminal claude in a session folder stays cs-blind" || return 1
}

test_terminal_cli_does_not_derive_from_the_input_cwd() {
    _make_session "$TEST_TMPDIR/barecwd" "barecwd"
    export CLAUDE_CODE_ENTRYPOINT="cli"
    local got
    got=$(_resolve "{\"cwd\":\"$TEST_TMPDIR/barecwd\"}")
    assert_eq "FAIL" "$got" "the cwd of a terminal claude is not a session signal" || return 1
}

# The gate reads the front end, not the session: `cs` exports the contract and
# the env arm answers before any of this, so a cs launch is untouched by it.
test_the_cli_gate_leaves_the_env_contract_alone() {
    _make_session "$TEST_TMPDIR/cssess"
    export CLAUDE_SESSION_NAME="from-cs"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/cssess"
    export CLAUDE_SESSION_META_DIR="$TEST_TMPDIR/cssess/.cs"
    export CLAUDE_CODE_ENTRYPOINT="cli"
    local got
    got=$(_resolve '{}')
    assert_eq "from-cs|$TEST_TMPDIR/cssess|$TEST_TMPDIR/cssess/.cs" "$got" \
        "a cs-launched CLI session resolves from its exported contract" || return 1
}

# The other direction, which is the whole reason the walk exists: desktop can
# publish no contract, so the directory is all it has. Naming a front end the
# gate does not know must not silence it either — only an affirmative "cli"
# declines, so an unset or unfamiliar entrypoint still resolves.
test_other_front_ends_still_derive_from_the_directory() {
    local ep got failures=0
    for ep in claude-desktop claude-desktop-3p claude-vscode claude-in-teams sdk-ts local-agent ""; do
        _make_session "$TEST_TMPDIR/fe" "fe"
        export CLAUDE_PROJECT_DIR="$TEST_TMPDIR/fe"
        if [ -n "$ep" ]; then
            export CLAUDE_CODE_ENTRYPOINT="$ep"
        else
            unset CLAUDE_CODE_ENTRYPOINT
        fi
        got=$(_resolve '{}')
        if [ "$got" != "fe|$(_phys "$TEST_TMPDIR/fe")|$(_phys "$TEST_TMPDIR/fe")/.cs" ]; then
            echo "  FAIL: entrypoint [${ep:-unset}] lost its session, got [$got]"
            failures=$((failures + 1))
        fi
        rm -rf "$TEST_TMPDIR/fe"
    done
    [ "$failures" -eq 0 ] || return 1
}

run_test test_terminal_cli_does_not_derive_from_the_directory
run_test test_terminal_cli_does_not_derive_from_the_input_cwd
run_test test_the_cli_gate_leaves_the_env_contract_alone
run_test test_other_front_ends_still_derive_from_the_directory

report_results
