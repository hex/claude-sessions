#!/usr/bin/env bash
# ABOUTME: Tests for how cs reads its argument list before dispatching
# ABOUTME: Covers the `--` end-of-options separator a launcher may insert

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Run cs with a stubbed claude, answering the resume prompt with the default.
_cs() {  # args...
    CLAUDE_CODE_BIN="$(_make_env_stub)" "$CS_BIN" "$@" 2>&1 <<< ""
}

# ============================================================================
# `--` ends the options and names an operand. Scape composes its harness
# command that way, and cs read the separator as a verb it did not know.
# ============================================================================

test_separator_before_a_session_name_opens_that_session() {
    local out
    out=$(_cs -- alpha)

    assert_output_contains "$out" "CLAUDE_SESSION_NAME=alpha" \
        "'cs -- alpha' should open the session named alpha" || return 1
    assert_output_not_contains "$out" "Unknown command" \
        "the separator is not a command" || return 1
}

test_separator_before_a_verb_runs_that_verb() {
    local out
    out=$(_cs -- -list)

    assert_output_contains "$out" "No sessions found" \
        "'cs -- -list' should run the list verb against the empty fixture root" || return 1
}

# Nothing after the separator is a bare `cs`, which off a terminal prints the
# short command summary rather than opening the picker.
test_a_lone_separator_reads_as_no_arguments() {
    local out
    out=$(_cs --)

    assert_output_contains "$out" "cs -list" \
        "'cs --' alone should behave as bare cs" || return 1
    assert_output_not_contains "$out" "Unknown command" \
        "a lone separator is not a command" || return 1
}

# The same separator can arrive after the session name, where the session
# subcommand parser reads its own argument list.
test_separator_after_a_session_name_still_takes_its_flags() {
    local out
    out=$(_cs beta -- --force)

    assert_output_contains "$out" "CLAUDE_SESSION_NAME=beta" \
        "'cs beta -- --force' should open beta" || return 1
    assert_output_not_contains "$out" "Unknown session command" \
        "the separator is not a session subcommand" || return 1
}

# The other side of "only in that position". Past the verb, `--` is a word in
# that verb's own arguments — a mail body may legitimately open with one, and
# stripping it there would edit the user's message.
test_a_separator_inside_a_verbs_arguments_survives() {
    _cs target >/dev/null 2>&1
    _cs target -msg -- "hello" >/dev/null 2>&1 \
        || { echo "  FAIL: the send did not complete"; return 1; }

    local body
    body=$(cat "$CS_SESSIONS_ROOT"/target/.cs/local/mail/new/*.json 2>/dev/null)
    assert_output_contains "$body" "-- hello" \
        "a separator inside a mail body belongs to the body" || return 1
}

echo ""
echo "cs argument dispatch tests"
echo "=========================="
echo ""

run_test test_separator_before_a_session_name_opens_that_session
run_test test_separator_before_a_verb_runs_that_verb
run_test test_a_lone_separator_reads_as_no_arguments
run_test test_separator_after_a_session_name_still_takes_its_flags
run_test test_a_separator_inside_a_verbs_arguments_survives

report_results
