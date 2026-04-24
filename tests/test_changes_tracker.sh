#!/usr/bin/env bash
# ABOUTME: Tests for changes-tracker.sh — PostToolUse hook that logs file
# ABOUTME: modifications and (now) refreshes .cs/files.md token estimates.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/changes-tracker.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"
    touch "$CLAUDE_SESSION_META_DIR/changes.md"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Helper: send a Write PostToolUse event for a file
send_write() {
    local abs_path="$1"
    jq -n --arg path "$abs_path" \
        '{tool_name: "Write", tool_input: {file_path: $path}, hook_event_name: "PostToolUse"}' \
        | bash "$HOOK"
}

# ============================================================================
# changes.md logging (baseline behavior — must still work)
# ============================================================================

test_appends_to_changes_md() {
    echo "hello" > "$CLAUDE_SESSION_DIR/foo.sh"
    send_write "$CLAUDE_SESSION_DIR/foo.sh" >/dev/null 2>&1
    if ! grep -q "foo.sh" "$CLAUDE_SESSION_META_DIR/changes.md"; then
        echo "  FAIL: changes.md should record the write"
        return 1
    fi
}

# ============================================================================
# files.md incremental update
# ============================================================================

test_updates_token_count_for_indexed_file() {
    cat > "$CLAUDE_SESSION_META_DIR/files.md" <<'EOF'
# Files

## README.md
~100 tokens -- updated 2026-01-01

EOF
    echo "# Short" > "$CLAUDE_SESSION_DIR/README.md"
    send_write "$CLAUDE_SESSION_DIR/README.md" >/dev/null 2>&1

    if grep -q "~100 tokens" "$CLAUDE_SESSION_META_DIR/files.md"; then
        echo "  FAIL: stale token count (~100) was not refreshed"
        cat "$CLAUDE_SESSION_META_DIR/files.md"
        return 1
    fi
    local today
    today=$(date '+%Y-%m-%d')
    if ! grep -q "updated $today" "$CLAUDE_SESSION_META_DIR/files.md"; then
        echo "  FAIL: tokens line should carry today's date ($today)"
        cat "$CLAUDE_SESSION_META_DIR/files.md"
        return 1
    fi
}

test_preserves_description_on_update() {
    cat > "$CLAUDE_SESSION_META_DIR/files.md" <<'EOF'
# Files

## README.md
Project readme — hand-written description.
~100 tokens -- updated 2026-01-01

EOF
    echo "# Short" > "$CLAUDE_SESSION_DIR/README.md"
    send_write "$CLAUDE_SESSION_DIR/README.md" >/dev/null 2>&1

    if ! grep -q "Project readme — hand-written description." "$CLAUDE_SESSION_META_DIR/files.md"; then
        echo "  FAIL: hand-written description was lost"
        cat "$CLAUDE_SESSION_META_DIR/files.md"
        return 1
    fi
}

test_skips_update_when_files_md_missing() {
    # No seed — files.md doesn't exist
    echo "foo" > "$CLAUDE_SESSION_DIR/README.md"
    send_write "$CLAUDE_SESSION_DIR/README.md" >/dev/null 2>&1

    if [ -f "$CLAUDE_SESSION_META_DIR/files.md" ]; then
        echo "  FAIL: changes-tracker must not CREATE files.md — that's session-start's job"
        return 1
    fi
}

test_skips_update_for_unindexed_file() {
    cat > "$CLAUDE_SESSION_META_DIR/files.md" <<'EOF'
# Files

## existing.md
~50 tokens -- updated 2026-01-01

EOF
    echo "new contents" > "$CLAUDE_SESSION_DIR/brand-new.md"
    send_write "$CLAUDE_SESSION_DIR/brand-new.md" >/dev/null 2>&1

    if grep -q "brand-new.md" "$CLAUDE_SESSION_META_DIR/files.md"; then
        echo "  FAIL: unindexed file should not be added by changes-tracker"
        cat "$CLAUDE_SESSION_META_DIR/files.md"
        return 1
    fi
    if ! grep -q "^## existing.md$" "$CLAUDE_SESSION_META_DIR/files.md"; then
        echo "  FAIL: existing entry was accidentally modified"
        cat "$CLAUDE_SESSION_META_DIR/files.md"
        return 1
    fi
}

# ============================================================================
# Run
# ============================================================================

echo "Running changes-tracker tests..."
run_test test_appends_to_changes_md
run_test test_updates_token_count_for_indexed_file
run_test test_preserves_description_on_update
run_test test_skips_update_when_files_md_missing
run_test test_skips_update_for_unindexed_file

report_results
