#!/usr/bin/env bash
# ABOUTME: Tests for the cs -status verb and the .cs/local/presence file.
# ABOUTME: Covers set/get/clear, special-char preservation, README fallback, guards.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

PFILE() { printf '%s' "$CLAUDE_SESSION_META_DIR/local/presence"; }
# Write a README with the given objective under a '## Objective' heading.
seed_readme() { # objective-text
    printf '# test-session\n\n## Objective\n\n%s\n' "$1" > "$CLAUDE_SESSION_DIR/.cs/README.md"
}

test_status_set_writes_presence_file() {
    "$CS_BIN" -status "refactoring the parser" >/dev/null 2>&1
    assert_file_contains "$(PFILE)" "refactoring the parser" "set writes the status" || return 1
    assert_eq "1" "$(grep -c . "$(PFILE)")" "presence is a single line" || return 1
}

# assert_file_contains matches with grep BRE; the string below has no BRE
# metacharacters, so it matches literally. The point is to prove quotes and '='
# survive the write (unlike _read_local_state, which would strip the quotes).
test_status_preserves_quotes_and_equals() {
    "$CS_BIN" -status 'fix the "auth" bug = hard' >/dev/null 2>&1
    assert_file_contains "$(PFILE)" 'fix the "auth" bug = hard' "special chars preserved verbatim" || return 1
}

test_status_joins_multiple_words() {
    "$CS_BIN" -status wiring the mailbox up >/dev/null 2>&1
    assert_file_contains "$(PFILE)" "wiring the mailbox up" "unquoted words are joined" || return 1
}

test_status_get_shows_presence() {
    "$CS_BIN" -status "doing X" >/dev/null 2>&1
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "doing X" "get shows the set status" || return 1
}

test_status_get_falls_back_to_readme_objective() {
    seed_readme "Ship the presence feature"
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "Ship the presence feature" "get falls back to README objective" || return 1
}

test_status_get_none_when_empty() {
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "(none)" "get shows (none) with no status and no objective" || return 1
}

test_status_clear_removes_file() {
    "$CS_BIN" -status "doing X" >/dev/null 2>&1
    "$CS_BIN" -status --clear >/dev/null 2>&1
    assert_file_not_exists "$(PFILE)" "clear removes the presence file" || return 1
}

test_status_empty_string_is_usage_error() {
    if "$CS_BIN" -status "" >/dev/null 2>&1; then
        echo "  FAIL: expected non-zero for empty status"; return 1
    fi
    return 0
}

test_status_requires_session() {
    unset CLAUDE_SESSION_META_DIR
    local out; if out=$("$CS_BIN" -status "x" 2>&1); then
        echo "  FAIL: expected non-zero outside a session"; return 1
    fi
    assert_output_contains "$out" "session" "explains it needs a session" || return 1
}

test_status_set_leaves_no_temp() {
    "$CS_BIN" -status "hello" >/dev/null 2>&1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/presence.tmp" "no temp file remains after set" || return 1
}

test_status_clear_reverts_to_objective() {
    seed_readme "Ship the presence feature"
    "$CS_BIN" -status "temporary note" >/dev/null 2>&1
    "$CS_BIN" -status --clear >/dev/null 2>&1
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "Ship the presence feature" "clear reverts get to the README objective" || return 1
}

test_status_get_filters_readme_placeholder() {
    printf '# test-session\n\n## Objective\n\n[Describe what you are trying to accomplish]\n' > "$CLAUDE_SESSION_DIR/.cs/README.md"
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "(none)" "unfilled placeholder objective yields (none)" || return 1
}

run_test test_status_set_writes_presence_file
run_test test_status_preserves_quotes_and_equals
run_test test_status_joins_multiple_words
run_test test_status_get_shows_presence
run_test test_status_get_falls_back_to_readme_objective
run_test test_status_get_none_when_empty
run_test test_status_clear_removes_file
run_test test_status_empty_string_is_usage_error
run_test test_status_requires_session
# Count raw ESC BYTES, never the text of an escape sequence: a prior check of
# this exact defect was wrong because it grepped for the word rather than the
# byte, and the scrub removes the byte while leaving the printable remainder.
_esc_bytes() { printf '%s' "$1" | LC_ALL=C tr -dc "$(printf '\033\007')" | wc -c | tr -d '[:space:]'; }

test_status_render_strips_control_bytes_from_the_presence_file() {
    # cs is multi-session: another session writes here via `cs -msg`, so the
    # reader does not trust the writer.
    printf 'busy \033[31mRED\033[0m and \007bell' > "$(PFILE)"
    local out
    out=$("$CS_BIN" -status 2>&1) || return 1
    assert_output_contains "$out" "busy" "the printable text survives" || return 1
    assert_output_contains "$out" "bell" "and so does text after the control byte" || return 1
    assert_eq "0" "$(_esc_bytes "$out")" "no raw ESC or BEL reaches the terminal" || return 1
}

test_status_render_strips_control_bytes_from_the_objective_fallback() {
    # With no presence file, session_status falls back to the README objective —
    # which under `cs -live` is ANOTHER session's file, the most genuinely
    # cross-session surface here. Omitting the presence file is what reaches it.
    rm -f "$(PFILE)"
    seed_readme "$(printf 'ship \033[31mred\033[0m thing')"
    local out
    out=$("$CS_BIN" -status 2>&1) || return 1
    assert_output_contains "$out" "ship" "the fallback path is reached and renders" || return 1
    assert_output_contains "$out" "thing" "text after the control byte survives" || return 1
    assert_eq "0" "$(_esc_bytes "$out")" "no raw ESC reaches the terminal" || return 1
}

run_test test_status_set_leaves_no_temp
run_test test_status_clear_reverts_to_objective
run_test test_status_get_filters_readme_placeholder
run_test test_status_render_strips_control_bytes_from_the_presence_file
run_test test_status_render_strips_control_bytes_from_the_objective_fallback

report_results
