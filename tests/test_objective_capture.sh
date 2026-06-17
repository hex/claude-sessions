#!/usr/bin/env bash
# ABOUTME: Tests for the objective-capture path folded into the scope-prompt UserPromptSubmit hook
# ABOUTME: Validates first-substantive-prompt capture, freeze, skips, safety, and no-ops

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/scope-prompt.sh"

PLACEHOLDER="[Describe what you're trying to accomplish in this session]"

# --- Hook-specific setup / teardown (overrides test_lib's) ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # Drop ambient cs/Claude env so a live session can't leak values the hook reads.
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    export CLAUDE_SESSION_NAME="test-obj"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Write a README whose Objective section holds $1 (defaults to the template placeholder).
make_readme() {
    local obj="${1:-$PLACEHOLDER}"
    printf '# Session\n\n## Objective\n\n%s\n\n## Outcome\n\n[Describe the result]\n' \
        "$obj" > "$CLAUDE_SESSION_META_DIR/README.md"
}

# Feed a prompt to the hook as the harness would (JSON on stdin).
run_hook() {
    local prompt="$1"
    jq -n --arg p "$prompt" '{prompt: $p, hook_event_name: "UserPromptSubmit"}' | "$HOOK"
}

# The current Objective line (first non-empty, non-heading line under ## Objective).
objective_line() {
    sed -n '/^## Objective/,/^## /{/^## /d;/^$/d;p;}' "$CLAUDE_SESSION_META_DIR/README.md" | head -1
}

# --- Tests ---

test_captures_first_substantive_prompt() {
    make_readme
    run_hook "we need to fix the CS TUI on light terminal themes" >/dev/null
    assert_eq "we need to fix the CS TUI on light terminal themes" "$(objective_line)" \
        "first substantive prompt becomes the objective"
}

test_skips_slash_command() {
    make_readme
    run_hook "/color red" >/dev/null
    assert_eq "$PLACEHOLDER" "$(objective_line)" "slash commands are not captured"
}

test_skips_bang_passthrough() {
    make_readme
    run_hook "!printenv CS_TERM_THEME" >/dev/null
    assert_eq "$PLACEHOLDER" "$(objective_line)" "shell passthrough is not captured"
}

test_skips_trivially_short_prompt() {
    make_readme
    run_hook "hi" >/dev/null
    assert_eq "$PLACEHOLDER" "$(objective_line)" "tiny greetings are not captured"
}

test_does_not_overwrite_existing_objective() {
    make_readme "Build the auth flow"
    run_hook "actually let's talk about something else entirely here" >/dev/null
    assert_eq "Build the auth flow" "$(objective_line)" "a real objective is never overwritten"
}

test_does_not_touch_outcome_placeholder() {
    make_readme
    run_hook "implement the retry wrapper around fetch" >/dev/null
    # Section-scoped: capturing the Objective must leave the Outcome [...] alone.
    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "Describe the result" \
        "Outcome placeholder is not clobbered by objective capture"
    assert_eq "implement the retry wrapper around fetch" "$(objective_line)" \
        "Objective itself was still captured"
}

test_freezes_after_first_capture() {
    make_readme
    run_hook "implement the retry wrapper around fetch" >/dev/null
    run_hook "and now add exponential backoff to it as well" >/dev/null
    assert_eq "implement the retry wrapper around fetch" "$(objective_line)" \
        "only the first substantive prompt is captured"
}

test_truncates_long_prompt() {
    make_readme
    local long
    long=$(printf 'fix the %0.s' {1..40})  # ~320 chars
    run_hook "$long" >/dev/null
    local line; line=$(objective_line)
    # 100 chars + a single ellipsis glyph.
    if [ "${#line}" -gt 105 ]; then
        echo "  FAIL: objective not truncated (len=${#line})"
        return 1
    fi
    case "$line" in *…) : ;; *) echo "  FAIL: truncated objective lacks ellipsis: $line"; return 1 ;; esac
}

test_arbitrary_chars_are_data_not_code() {
    make_readme
    local canary="$TEST_TMPDIR/canary"
    # $(...) would create the canary if the prompt were ever evaluated.
    run_hook "run \$(touch $canary) now please" >/dev/null
    assert_not_exists "$canary" "prompt text must never be executed"

    # Backslash and ampersand must survive verbatim — proves the awk ENVIRON
    # write path does no escape/replacement processing. Kept short so the
    # asserted span isn't lost to truncation; grep -F so the backslash is literal.
    make_readme
    run_hook 'keep A & B and \n verbatim here' >/dev/null
    if ! grep -Fq 'A & B and \n verbatim' "$CLAUDE_SESSION_META_DIR/README.md"; then
        echo "  FAIL: special characters were not written verbatim"
        return 1
    fi
}

test_opt_out_via_disable_env() {
    make_readme
    CS_OBJECTIVE_CAPTURE_DISABLE=1 run_hook "fix the broken thing now please" >/dev/null
    assert_eq "$PLACEHOLDER" "$(objective_line)" "disable env suppresses capture"
}

test_noop_outside_cs_session() {
    unset CLAUDE_SESSION_NAME
    # Must exit 0 and not crash even with no session.
    run_hook "fix the broken thing now please" >/dev/null
}

test_graceful_malformed_input() {
    make_readme
    printf 'not json at all' | "$HOOK" >/dev/null
    assert_eq "$PLACEHOLDER" "$(objective_line)" "malformed stdin leaves the placeholder intact"
}

run_test test_captures_first_substantive_prompt
run_test test_skips_slash_command
run_test test_skips_bang_passthrough
run_test test_skips_trivially_short_prompt
run_test test_does_not_overwrite_existing_objective
run_test test_does_not_touch_outcome_placeholder
run_test test_freezes_after_first_capture
run_test test_truncates_long_prompt
run_test test_arbitrary_chars_are_data_not_code
run_test test_opt_out_via_disable_env
run_test test_noop_outside_cs_session
run_test test_graceful_malformed_input

report_results
