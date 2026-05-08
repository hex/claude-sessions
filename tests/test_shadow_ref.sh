#!/usr/bin/env bash
# ABOUTME: Tests for shadow ref autosave in discovery-commits, session-end, and session-start hooks
# ABOUTME: Validates shadow ref creation, main branch isolation, crash recovery, and push protection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# Override setup for shadow ref testing (git repo with specific config)
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    export CS_TEST_SYNC=1  # Run hook git operations in foreground for testing

    mkdir -p "$CLAUDE_SESSION_DIR/.cs/logs"
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/artifacts"

    (
        cd "$CLAUDE_SESSION_DIR"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# Discoveries" > .cs/discoveries.md
        echo "initial" > README.md
        git add -A
        git commit -q -m "Initial commit"
    )
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR CS_TEST_SYNC 2>/dev/null || true
}

# ============================================================================
# discovery-commits.sh: shadow ref autosave
# ============================================================================

test_autosave_creates_shadow_ref() {
    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/discoveries.md"

    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/discoveries.md"'"}}' \
        | bash "$HOOKS_DIR/discovery-commits.sh"
    sleep 1

    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/cs/auto should exist after autosave"
        return 1
    fi
}

test_autosave_does_not_touch_main() {
    local head_before head_after
    head_before=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/discoveries.md"

    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/discoveries.md"'"}}' \
        | bash "$HOOKS_DIR/discovery-commits.sh"
    sleep 1

    head_after=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    if [[ "$head_before" != "$head_after" ]]; then
        echo "  FAIL: HEAD should not change after autosave"
        echo "    before: $head_before"
        echo "    after:  $head_after"
        return 1
    fi
}

test_autosave_chains_multiple_saves() {
    echo "## First" >> "$CLAUDE_SESSION_DIR/.cs/discoveries.md"
    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/discoveries.md"'"}}' \
        | bash "$HOOKS_DIR/discovery-commits.sh"
    sleep 1

    local ref_after_first
    ref_after_first=$(git -C "$CLAUDE_SESSION_DIR" rev-parse refs/cs/auto 2>/dev/null || echo "none")

    echo "## Second" >> "$CLAUDE_SESSION_DIR/.cs/discoveries.md"
    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/discoveries.md"'"}}' \
        | bash "$HOOKS_DIR/discovery-commits.sh"
    sleep 1

    local ref_after_second
    ref_after_second=$(git -C "$CLAUDE_SESSION_DIR" rev-parse refs/cs/auto 2>/dev/null || echo "none")

    if [[ "$ref_after_first" = "$ref_after_second" ]]; then
        echo "  FAIL: shadow ref should advance after second autosave"
        return 1
    fi

    local parent
    parent=$(git -C "$CLAUDE_SESSION_DIR" log --format=%P -1 refs/cs/auto 2>/dev/null || echo "")
    if [[ "$parent" != "$ref_after_first" ]]; then
        echo "  FAIL: second autosave should chain onto first"
        echo "    expected parent: $ref_after_first"
        echo "    actual parent:   $parent"
        return 1
    fi
}

# ============================================================================
# session-end.sh: clean commit + shadow ref cleanup
# ============================================================================

test_session_end_deletes_shadow_ref() {
    (
        cd "$CLAUDE_SESSION_DIR"
        tree=$(git write-tree)
        commit=$(echo "autosave" | git commit-tree "$tree")
        git update-ref refs/cs/auto "$commit"
    )

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/cs/auto should be deleted after session end"
        return 1
    fi
}

test_session_end_commits_to_main() {
    local commit_count_before commit_count_after
    commit_count_before=$(git -C "$CLAUDE_SESSION_DIR" rev-list --count HEAD)

    echo "new content" > "$CLAUDE_SESSION_DIR/notes.txt"
    echo "auto_sync=on" > "$CLAUDE_SESSION_DIR/.cs/sync.conf"

    echo '{"session_id":"test-456"}' | bash "$HOOKS_DIR/session-end.sh"

    commit_count_after=$(git -C "$CLAUDE_SESSION_DIR" rev-list --count HEAD)

    if [[ "$commit_count_after" -le "$commit_count_before" ]]; then
        echo "  FAIL: session end should create one commit on main"
        echo "    before: $commit_count_before"
        echo "    after:  $commit_count_after"
        return 1
    fi
}

# ============================================================================
# session-start.sh: crash recovery + push protection
# ============================================================================

test_recovery_detects_crash_and_injects_context() {
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "recovered content" > recovered.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add recovered.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(echo "autosave" | git commit-tree "$tree")
        git update-ref refs/cs/auto "$commit"
        rm recovered.txt
    )

    if [[ -f "$CLAUDE_SESSION_DIR/recovered.txt" ]]; then
        echo "  FAIL: recovered.txt should not exist before recovery"
        return 1
    fi

    local output
    output=$(echo '{"session_id":"test-789","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if [[ -f "$CLAUDE_SESSION_DIR/recovered.txt" ]]; then
        echo "  FAIL: recovered.txt should NOT be auto-restored (ask user first)"
        return 1
    fi

    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/cs/auto should still exist until user decides"
        return 1
    fi

    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: hook output should contain CRASH RECOVERY context"
        echo "  Output: $(echo "$output" | head -5)"
        return 1
    fi

    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
}

test_shadow_ref_not_pushed() {
    echo '{"session_id":"test-abc","cwd":"'"$CLAUDE_SESSION_DIR"'"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null

    local hide_refs
    hide_refs=$(git -C "$CLAUDE_SESSION_DIR" config --get-all transfer.hideRefs 2>/dev/null || true)

    if [[ "$hide_refs" != *"refs/cs"* ]]; then
        echo "  FAIL: transfer.hideRefs should include refs/cs"
        echo "    actual: '$hide_refs'"
        return 1
    fi
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs shadow ref autosave tests"
echo "============================="
echo ""

run_test test_autosave_creates_shadow_ref
run_test test_autosave_does_not_touch_main
run_test test_autosave_chains_multiple_saves
run_test test_session_end_deletes_shadow_ref
run_test test_session_end_commits_to_main
run_test test_recovery_detects_crash_and_injects_context
run_test test_shadow_ref_not_pushed

report_results
