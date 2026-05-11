#!/usr/bin/env bash
# ABOUTME: Tests for auto-memory bucket guidance block in session CLAUDE.md
# ABOUTME: Validates new-session insertion, lazy migration, and user opt-out

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Sentinel marker injected at the top of the managed block. Presence means
# cs has touched this section — migration treats it as "do not modify."
SENTINEL='<!-- cs:memory-rules -->'

# ============================================================================
# Cycle 1: new session CLAUDE.md contains the memory-rules block
# ============================================================================

test_new_session_has_memory_rules_block() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_exists "$claude_md" "session CLAUDE.md should exist" || return 1
    assert_file_contains "$claude_md" "cs:memory-rules" \
        "CLAUDE.md should contain the cs:memory-rules sentinel" || return 1
    assert_file_contains "$claude_md" "Auto-memory bucket guidance" \
        "CLAUDE.md should contain the section header" || return 1
    assert_file_contains "$claude_md" "user_\*\.md\|user_\\\*\.md" \
        "CLAUDE.md should mention user_*.md bucket in the signal-phrase table" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_memory_rules.sh"
echo ""
run_test test_new_session_has_memory_rules_block
report_results
