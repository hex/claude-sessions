#!/usr/bin/env bash
# ABOUTME: Tests for prose-lint.sh — Stop hook that blocks turn-end when prose
# ABOUTME: written this session (summary.md, memory/*.md) carries AI-slop tells

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/prose-lint.sh"
export CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory" "$CLAUDE_SESSION_META_DIR/logs"
    touch "$CLAUDE_SESSION_META_DIR/session.lock"
    sleep 0.05
}

teardown() {
    [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

run_hook() { OUT=$(echo "${1:-{\}}" | bash "$HOOK"); }

test_blocks_on_em_dash_in_summary() {
    printf '%s\n' "# Summary" "The fix shipped — clean." > "$CLAUDE_SESSION_META_DIR/summary.md"
    run_hook '{}'
    assert_output_contains "$OUT" "block" "should block on em-dash in summary written this session" || return 1
}

test_blocks_on_phrase_in_memory_entry() {
    printf '%s\n' "Needless to say, the cache warmed." > "$CLAUDE_SESSION_META_DIR/memory/feedback_x.md"
    run_hook '{}'
    assert_output_contains "$OUT" "block" "should block on banned phrase in a memory entry" || return 1
}

test_approves_clean_summary() {
    printf '%s\n' "# Summary" "The runner parsed each row and finished." > "$CLAUDE_SESSION_META_DIR/summary.md"
    run_hook '{}'
    assert_output_contains "$OUT" "approve" "clean summary should approve" || return 1
    assert_output_not_contains "$OUT" "block" "clean summary must not block" || return 1
}

test_no_prose_files_approves() {
    run_hook '{}'
    assert_output_contains "$OUT" "approve" "no prose files should approve" || return 1
}

test_skips_inside_subagent() {
    printf '%s\n' "Slop — here." > "$CLAUDE_SESSION_META_DIR/summary.md"
    run_hook '{"agent_id":"sub-123"}'
    assert_output_not_contains "$OUT" "block" "must not block inside a subagent" || return 1
}

test_skips_outside_cs_session() {
    printf '%s\n' "Slop — here." > "$CLAUDE_SESSION_META_DIR/summary.md"
    unset CLAUDE_SESSION_NAME
    run_hook '{}'
    assert_output_not_contains "$OUT" "block" "must not block outside a cs session" || return 1
}

test_skips_file_older_than_session_start() {
    printf '%s\n' "Old slop — from a prior session." > "$CLAUDE_SESSION_META_DIR/summary.md"
    touch -t 202001010000 "$CLAUDE_SESSION_META_DIR/summary.md"
    run_hook '{}'
    assert_output_not_contains "$OUT" "block" "pre-session prose must not trigger a block" || return 1
}

test_discoveries_md_is_excluded() {
    printf '%s\n' "An aside — with an em-dash." > "$CLAUDE_SESSION_META_DIR/discoveries.md"
    run_hook '{}'
    assert_output_not_contains "$OUT" "block" "discoveries.md is out of scope for the hard block" || return 1
}

test_memory_index_is_excluded() {
    printf '%s\n' "- [Entry](feedback_x.md) — a one-line index hook" > "$CLAUDE_SESSION_META_DIR/memory/MEMORY.md"
    run_hook '{}'
    assert_output_not_contains "$OUT" "block" "MEMORY.md index must not be linted as prose" || return 1
}

test_narrative_md_is_excluded() {
    printf '%s\n' "An aside — with an em-dash." > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    run_hook '{}'
    assert_output_not_contains "$OUT" "block" "narrative.md lab notebook must not be linted as prose" || return 1
}

test_loop_guard_allows_after_cap() {
    printf '%s\n' "Slop — persists." > "$CLAUDE_SESSION_META_DIR/summary.md"
    run_hook '{}'; assert_output_contains "$OUT" "block" "1st attempt blocks" || return 1
    run_hook '{}'; assert_output_contains "$OUT" "block" "2nd attempt blocks" || return 1
    run_hook '{}'; assert_output_contains "$OUT" "block" "3rd attempt blocks" || return 1
    run_hook '{}'; assert_output_contains "$OUT" "approve" "4th attempt allows stop (loop guard)" || return 1
}

echo "Running prose-lint hook tests..."
run_test test_blocks_on_em_dash_in_summary
run_test test_blocks_on_phrase_in_memory_entry
run_test test_approves_clean_summary
run_test test_no_prose_files_approves
run_test test_skips_inside_subagent
run_test test_skips_outside_cs_session
run_test test_skips_file_older_than_session_start
run_test test_discoveries_md_is_excluded
run_test test_memory_index_is_excluded
run_test test_narrative_md_is_excluded
run_test test_loop_guard_allows_after_cap

report_results
