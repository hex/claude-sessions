#!/usr/bin/env bash
# ABOUTME: Smoke tests for `cs -help` / `cs -version` output integrity
# ABOUTME: Guards against the unquoted-heredoc command-substitution regression

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# `cs -help` is a `cat << EOF` heredoc. It must not command-substitute its body:
# backticks/$(...) in the help text would run as commands. Regression: the
# tmux "allow-passthrough on" mention was backtick-quoted, so bash executed it
# ("command not found") and dropped the text from the output.
test_help_no_command_substitution() {
    local out
    out=$("$CS_BIN" -help 2>&1)
    assert_output_not_contains "$out" "command not found" \
        "cs -help must not execute its own help text" || return 1
    assert_output_contains "$out" "allow-passthrough on" \
        "the literal help text must survive (not be command-substituted away)"
}

test_version_prints_clean() {
    local out
    out=$("$CS_BIN" -version 2>&1)
    assert_output_not_contains "$out" "command not found" "cs -version must be clean" || return 1
    assert_output_contains "$out" "cs " "cs -version should print the version line"
}

echo ""
echo "cs help/version tests"
echo "====================="
echo ""

run_test test_help_no_command_substitution
run_test test_version_prints_clean

report_results
