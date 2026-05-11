#!/usr/bin/env bash
# ABOUTME: Tests for Claude session UUID pre-allocation and frontmatter binding
# ABOUTME: Validates new-session UUID write, resume reads, env export, lazy migration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset cs session env vars (matches test_auto_memory.sh pattern)
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_CLAUDE_SESSION_ID 2>/dev/null || true
}

# UUID v4 regex: 8-4-4-4-12 hex, version nibble = 4, variant nibble in 8-b.
# Used both to validate generated UUIDs and to anchor regex assertions in tests.
UUID_V4_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# ============================================================================
# Cycle 1: new-session writes UUID to frontmatter AND passes --session-id
# ============================================================================

test_new_session_allocates_and_records_uuid() {
    # Capture spawn output. CLAUDE_CODE_BIN=echo (set by setup) means cs's
    # `exec $CLAUDE_CODE_BIN <args>` prints the args to stdout — that's how
    # we inspect what claude would have been invoked with.
    local output
    output=$("$CS_BIN" test-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"

    assert_file_exists "$session_dir/.cs/README.md" \
        "session README should exist after first cs launch" || return 1

    assert_file_contains "$session_dir/.cs/README.md" "^claude_session_id:" \
        "README frontmatter should record claude_session_id" || return 1

    # Extract the recorded UUID. Frontmatter line shape: 'claude_session_id: <uuid>'.
    local recorded_uuid
    recorded_uuid=$(grep -E '^claude_session_id:' "$session_dir/.cs/README.md" \
        | head -1 \
        | sed -E 's/^claude_session_id:[[:space:]]*//; s/^"//; s/"$//')

    if [[ ! "$recorded_uuid" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: recorded claude_session_id is not a valid v4 UUID"
        echo "    recorded: '$recorded_uuid'"
        return 1
    fi

    assert_output_contains "$output" "--session-id $recorded_uuid" \
        "claude spawn should pass --session-id <recorded-uuid>" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_uuid.sh"
echo ""
run_test test_new_session_allocates_and_records_uuid
report_results
