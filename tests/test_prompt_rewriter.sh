#!/usr/bin/env bash
# ABOUTME: Tests for the $EDITOR shim that rewrites Claude Code's composer buffer in place
# ABOUTME: Covers the rewrite, the pass-through classes, and fail-safe behaviour on rewriter failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SHIM="$SCRIPT_DIR/../hooks/prompt-rewriter.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    # A stub rewriter: uppercases nothing, just wraps, so the assertion is about
    # the shim's plumbing and not about any model's output.
    STUB="$TEST_TMPDIR/stub-rewrite.sh"
    cat > "$STUB" <<'STUBEOF'
#!/bin/bash
printf 'PRECISE: %s' "$(cat)"
STUBEOF
    chmod +x "$STUB"
    export CS_REWRITE_CMD="$STUB"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Claude Code hands the shim a file named claude-prompt-<uuid>.md holding the
# composer buffer, then reads the file back and replaces the composer with it.
composer_file() {  # content
    local f="$TEST_TMPDIR/claude-prompt-11111111-2222-3333-4444-555555555555.md"
    printf '%s' "$1" > "$f"
    printf '%s' "$f"
}

test_rewrites_the_composer_file_in_place() {
    local f; f=$(composer_file "make the login thing better")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "PRECISE: make the login thing better" "$(cat "$f")" \
        "the composer file holds the rewritten prompt"
}

# A file that is not the composer buffer belongs to the user's real editor.
test_non_composer_file_goes_to_the_real_editor() {
    local f="$TEST_TMPDIR/CLAUDE.md"
    printf 'my memory file\n' > "$f"
    local marker="$TEST_TMPDIR/real-editor-ran"
    cat > "$TEST_TMPDIR/fake-editor.sh" <<EOF
#!/bin/bash
printf '%s' "\$1" > "$marker"
EOF
    chmod +x "$TEST_TMPDIR/fake-editor.sh"
    CS_REAL_EDITOR="$TEST_TMPDIR/fake-editor.sh" "$SHIM" "$f" >/dev/null 2>&1
    assert_exists "$marker" "the real editor was exec'd for a non-composer file" || return 1
    assert_eq "my memory file" "$(cat "$f")" "and the file was not rewritten"
}

test_slash_command_passes_through() {
    local f; f=$(composer_file "/color red")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "/color red" "$(cat "$f")" "a slash command is already precise"
}

test_bang_passthrough_passes_through() {
    local f; f=$(composer_file "!printenv PATH")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "!printenv PATH" "$(cat "$f")" "shell passthrough is not prose"
}

test_memory_entry_passes_through() {
    local f; f=$(composer_file "#remember the deploy runs at 5")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "#remember the deploy runs at 5" "$(cat "$f")" "a memory entry is not a request"
}

test_empty_buffer_passes_through() {
    local f; f=$(composer_file "   ")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "   " "$(cat "$f")" "an empty buffer has nothing to rewrite"
}

# The composer buffer carries placeholders, not the pasted bodies. Rewriting the
# placeholder away destroys the attachment.
test_pasted_text_placeholder_passes_through() {
    local f; f=$(composer_file "explain this [Pasted text #1 +40 lines]")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "explain this [Pasted text #1 +40 lines]" "$(cat "$f")" \
        "a buffer carrying a paste placeholder is left alone"
}

test_image_placeholder_passes_through() {
    local f; f=$(composer_file "what is wrong here [Image #1]")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "what is wrong here [Image #1]" "$(cat "$f")" \
        "a buffer carrying an image placeholder is left alone"
}

# Fail-safe: the user's typed text must survive every rewriter failure.
test_failing_rewriter_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\nexit 7\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "a rewriter that exits non-zero must not lose the prompt"
}

test_empty_rewrite_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\ncat >/dev/null; printf ""\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "an empty rewrite must not erase the prompt"
}

test_whitespace_only_rewrite_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\ncat >/dev/null; printf "  \\n "\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "a whitespace-only rewrite must not erase the prompt"
}

test_opt_out_via_disable_env() {
    local f; f=$(composer_file "make the login thing better")
    CS_REWRITE_DISABLE=1 "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "CS_REWRITE_DISABLE suppresses the rewrite"
}

# The rewriter is a separate switch from the clarifying-questions guideline.
test_clarify_disable_does_not_suppress_the_rewriter() {
    local f; f=$(composer_file "make the login thing better")
    CS_CLARIFY_DISABLE=1 "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "PRECISE: make the login thing better" "$(cat "$f")" \
        "CS_CLARIFY_DISABLE governs the guideline, not the rewriter"
}

test_prompt_text_is_data_not_code() {
    local canary="$TEST_TMPDIR/canary"
    local f; f=$(composer_file "run \$(touch $canary) now")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_not_exists "$canary" "prompt text must never be executed"
}

test_shim_never_leaves_a_temp_file_behind() {
    local f; f=$(composer_file "make the login thing better")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_not_exists "$f.cs-tmp" "the tmp+rename leaves no residue"
}

run_test test_rewrites_the_composer_file_in_place
run_test test_non_composer_file_goes_to_the_real_editor
run_test test_slash_command_passes_through
run_test test_bang_passthrough_passes_through
run_test test_memory_entry_passes_through
run_test test_empty_buffer_passes_through
run_test test_pasted_text_placeholder_passes_through
run_test test_image_placeholder_passes_through
run_test test_failing_rewriter_leaves_the_buffer_untouched
run_test test_empty_rewrite_leaves_the_buffer_untouched
run_test test_whitespace_only_rewrite_leaves_the_buffer_untouched
run_test test_opt_out_via_disable_env
run_test test_clarify_disable_does_not_suppress_the_rewriter
run_test test_prompt_text_is_data_not_code
run_test test_shim_never_leaves_a_temp_file_behind

report_results
