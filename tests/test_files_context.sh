#!/usr/bin/env bash
# ABOUTME: Tests for files-context.sh — PreToolUse-on-Read hook that injects
# ABOUTME: file descriptions from .cs/files.md as additionalContext before Reads

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/files-context.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Seed a fixed files.md with three entries — with description, with description, without
seed_files_md() {
    cat > "$CLAUDE_SESSION_META_DIR/files.md" <<'EOF'
# Files

## README.md
Project readme.
~120 tokens -- updated 2026-04-24

## src/main.ts
Entry point.
~520 tokens -- updated 2026-04-24

## bin/runner
~45 tokens -- updated 2026-04-24

EOF
}

# Helper: send a Read PreToolUse event with absolute file_path
send_read() {
    local abs_path="$1"
    jq -n --arg path "$abs_path" \
        '{tool_name: "Read", tool_input: {file_path: $path}, hook_event_name: "PreToolUse"}' \
        | bash "$HOOK"
}

# Helper: send an Edit (non-Read) event
send_edit() {
    local abs_path="$1"
    jq -n --arg path "$abs_path" \
        '{tool_name: "Edit", tool_input: {file_path: $path}, hook_event_name: "PreToolUse"}' \
        | bash "$HOOK"
}

# ============================================================================
# Injection cases
# ============================================================================

test_injects_context_for_indexed_path() {
    seed_files_md
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/src/main.ts")
    assert_output_contains "$output" "additionalContext" \
        "should emit additionalContext" || return 1
    assert_output_contains "$output" "Entry point" \
        "should include the description" || return 1
    assert_output_contains "$output" "520 tokens" \
        "should include the token estimate" || return 1
}

test_injects_for_entry_without_description() {
    seed_files_md
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/bin/runner")
    assert_output_contains "$output" "additionalContext" \
        "entries with no description should still emit" || return 1
    assert_output_contains "$output" "45 tokens" \
        "token estimate should still be emitted" || return 1
}

test_hook_event_name_in_output() {
    seed_files_md
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/README.md")
    assert_output_contains "$output" "PreToolUse" \
        "hookEventName must be PreToolUse" || return 1
}

# ============================================================================
# Passthrough cases
# ============================================================================

test_unindexed_path_passes_through() {
    seed_files_md
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/some/unknown/file.py")
    assert_output_not_contains "$output" "additionalContext" \
        "no additionalContext for unindexed paths" || return 1
}

test_missing_files_md_passes_through() {
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/README.md")
    assert_output_not_contains "$output" "additionalContext" \
        "no output when files.md is absent" || return 1
}

test_non_read_tool_passes_through() {
    seed_files_md
    local output
    output=$(send_edit "$CLAUDE_SESSION_DIR/src/main.ts")
    assert_output_not_contains "$output" "additionalContext" \
        "Edit tool should not trigger injection" || return 1
}

test_outside_cs_session_passes_through() {
    seed_files_md
    unset CLAUDE_SESSION_NAME
    local output
    output=$(send_read "$CLAUDE_SESSION_DIR/src/main.ts")
    assert_output_not_contains "$output" "additionalContext" \
        "no injection outside cs session" || return 1
}

# ============================================================================
# Run
# ============================================================================

echo "Running files-context tests..."
run_test test_injects_context_for_indexed_path
run_test test_injects_for_entry_without_description
run_test test_hook_event_name_in_output
run_test test_unindexed_path_passes_through
run_test test_missing_files_md_passes_through
run_test test_non_read_tool_passes_through
run_test test_outside_cs_session_passes_through

report_results
