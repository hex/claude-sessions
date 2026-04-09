#!/usr/bin/env bash
# ABOUTME: Tests for cs -checkpoint save/list/show subcommands
# ABOUTME: Validates checkpoint creation, listing, content snapshot, and timeline integration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override setup to provide a full session environment
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Create a session
    local session_dir="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=off" > "$session_dir/.cs/sync.conf"
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-04-09
tags: []
aliases: ["test-session"]
---
# Session: test-session

## Objective
Test checkpoints
EOF
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## Auth refactor complete
Moved JWT validation to middleware layer.

## Migration strategy
Rolling deploy with feature flag.
EOF
    cat > "$session_dir/.cs/changes.md" << 'EOF'
# Changes Log

- 2026-04-09: Modified auth/middleware.ts
- 2026-04-09: Added tests/auth.test.ts
EOF
    echo "# Test" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m init)

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
    export CLAUDE_ARTIFACT_DIR="$session_dir/.cs/artifacts"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# ============================================================================
# -checkpoint save
# ============================================================================

test_checkpoint_creates_file() {
    "$CS_BIN" -checkpoint "auth refactor done" > /dev/null 2>&1
    assert_dir "$CLAUDE_SESSION_META_DIR/checkpoints" "checkpoints dir should exist" || return 1
    local count
    count=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | wc -l | tr -d ' ')
    assert_eq "1" "$count" "Should have 1 checkpoint file" || return 1
}

test_checkpoint_filename_has_timestamp() {
    "$CS_BIN" -checkpoint "test label" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    local name
    name=$(basename "$f")
    if ! [[ "$name" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}- ]]; then
        echo "  FAIL: Filename should start with date: $name"
        return 1
    fi
}

test_checkpoint_includes_label() {
    "$CS_BIN" -checkpoint "finished auth" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    assert_file_contains "$f" "finished auth" "Checkpoint should include label" || return 1
}

test_checkpoint_snapshots_discoveries() {
    "$CS_BIN" -checkpoint "test" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    assert_file_contains "$f" "Auth refactor complete" \
        "Checkpoint should snapshot discoveries" || return 1
}

test_checkpoint_snapshots_changes() {
    "$CS_BIN" -checkpoint "test" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    assert_file_contains "$f" "auth/middleware.ts" \
        "Checkpoint should snapshot changes" || return 1
}

test_checkpoint_records_git_head() {
    "$CS_BIN" -checkpoint "test" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    # Should contain a git SHA (at least 7 hex chars)
    if ! grep -qE 'HEAD.*[0-9a-f]{7}' "$f"; then
        echo "  FAIL: Should record git HEAD SHA"
        cat "$f"
        return 1
    fi
}

test_checkpoint_requires_label() {
    if "$CS_BIN" -checkpoint 2>&1 > /dev/null; then
        echo "  FAIL: Should fail without label"
        return 1
    fi
}

test_checkpoint_requires_active_session() {
    unset CLAUDE_SESSION_NAME
    if "$CS_BIN" -checkpoint "orphan" 2>&1 > /dev/null; then
        echo "  FAIL: Should fail without CLAUDE_SESSION_NAME"
        return 1
    fi
}

test_checkpoint_appends_to_timeline() {
    "$CS_BIN" -checkpoint "timeline test" > /dev/null 2>&1
    assert_exists "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        "Timeline should be written" || return 1
    if ! jq -e 'select(.event == "checkpoint" and .label == "timeline test")' \
        "$CLAUDE_SESSION_META_DIR/timeline.jsonl" > /dev/null; then
        echo "  FAIL: Should append checkpoint event to timeline"
        cat "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
        return 1
    fi
}

test_multiple_checkpoints() {
    "$CS_BIN" -checkpoint "first" > /dev/null 2>&1
    sleep 1
    "$CS_BIN" -checkpoint "second" > /dev/null 2>&1
    local count
    count=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | wc -l | tr -d ' ')
    assert_eq "2" "$count" "Should have 2 checkpoints" || return 1
}

# ============================================================================
# -checkpoint list
# ============================================================================

test_checkpoint_list_empty() {
    local output
    output=$("$CS_BIN" -checkpoint list 2>&1)
    assert_output_contains "$output" "No checkpoints" \
        "Should show empty message" || return 1
}

test_checkpoint_list_shows_all() {
    "$CS_BIN" -checkpoint "first label" > /dev/null 2>&1
    sleep 1
    "$CS_BIN" -checkpoint "second label" > /dev/null 2>&1

    local output
    output=$("$CS_BIN" -checkpoint list 2>&1)
    assert_output_contains "$output" "first label" "Should list first" || return 1
    assert_output_contains "$output" "second label" "Should list second" || return 1
}

# ============================================================================
# -checkpoint show
# ============================================================================

test_checkpoint_show_prints_content() {
    "$CS_BIN" -checkpoint "auth done" > /dev/null 2>&1
    local f
    f=$(find "$CLAUDE_SESSION_META_DIR/checkpoints" -name "*.md" | head -1)
    local name
    name=$(basename "$f" .md)

    local output
    output=$("$CS_BIN" -checkpoint show "$name" 2>&1)
    assert_output_contains "$output" "auth done" "Should show label" || return 1
    assert_output_contains "$output" "Auth refactor complete" "Should show discoveries snapshot" || return 1
}

# ============================================================================
# Help text
# ============================================================================

test_help_shows_checkpoint() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "-checkpoint" \
        "Help should mention -checkpoint" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs checkpoint tests"
echo "==================="
echo ""

run_test test_checkpoint_creates_file
run_test test_checkpoint_filename_has_timestamp
run_test test_checkpoint_includes_label
run_test test_checkpoint_snapshots_discoveries
run_test test_checkpoint_snapshots_changes
run_test test_checkpoint_records_git_head
run_test test_checkpoint_requires_label
run_test test_checkpoint_requires_active_session
run_test test_checkpoint_appends_to_timeline
run_test test_multiple_checkpoints
run_test test_checkpoint_list_empty
run_test test_checkpoint_list_shows_all
run_test test_checkpoint_show_prints_content
run_test test_help_shows_checkpoint

report_results
