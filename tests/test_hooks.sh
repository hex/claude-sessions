#!/usr/bin/env bash
# ABOUTME: Tests for session lifecycle hooks not covered by other test files
# ABOUTME: Covers discoveries-archiver, discoveries-reminder, session-auto-approve, subagent-context, tool-failure-logger

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# Override setup for hook testing
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{logs,artifacts,memory}
    touch "$CLAUDE_SESSION_META_DIR/logs/session.log"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# ============================================================================
# discoveries-archiver.sh
# ============================================================================

test_archiver_skips_small_file() {
    # Create a short discoveries file (under 200 lines)
    {
        echo "# Discoveries & Notes"
        echo ""
        echo "## Finding 1"
        echo "Some content here"
    } > "$CLAUDE_SESSION_META_DIR/discoveries.md"

    echo '{"transcript_path": "/tmp/transcript"}' | bash "$HOOKS_DIR/discoveries-archiver.sh"

    # Archive should NOT be created
    if [[ -f "$CLAUDE_SESSION_META_DIR/discoveries.archive.md" ]]; then
        echo "  FAIL: Should not archive a small file"
        return 1
    fi
}

test_archiver_moves_old_entries() {
    # Create a discoveries file with 250+ lines
    {
        echo "# Discoveries & Notes"
        echo ""
        # Generate ~30 entries of ~8 lines each = ~240 lines
        for i in $(seq 1 30); do
            echo "## Finding $i"
            echo ""
            echo "Detail line 1 for finding $i"
            echo "Detail line 2 for finding $i"
            echo "Detail line 3 for finding $i"
            echo "Detail line 4 for finding $i"
            echo "Detail line 5 for finding $i"
            echo ""
        done
    } > "$CLAUDE_SESSION_META_DIR/discoveries.md"

    local lines_before
    lines_before=$(wc -l < "$CLAUDE_SESSION_META_DIR/discoveries.md" | tr -d ' ')

    echo '{"transcript_path": "/tmp/transcript"}' | bash "$HOOKS_DIR/discoveries-archiver.sh"

    # Archive should be created
    assert_exists "$CLAUDE_SESSION_META_DIR/discoveries.archive.md" \
        "Archive file should be created" || return 1

    # Discoveries should be shorter now
    local lines_after
    lines_after=$(wc -l < "$CLAUDE_SESSION_META_DIR/discoveries.md" | tr -d ' ')
    if [[ "$lines_after" -ge "$lines_before" ]]; then
        echo "  FAIL: Discoveries should be shorter after archiving ($lines_before -> $lines_after)"
        return 1
    fi
}

test_archiver_preserves_header() {
    {
        echo "# Discoveries & Notes"
        echo ""
        for i in $(seq 1 30); do
            echo "## Finding $i"
            echo "Detail for $i"
            echo "More detail"
            echo "Even more"
            echo "Line 4"
            echo "Line 5"
            echo "Line 6"
            echo "Line 7"
            echo ""
        done
    } > "$CLAUDE_SESSION_META_DIR/discoveries.md"

    echo '{}' | bash "$HOOKS_DIR/discoveries-archiver.sh"

    local header
    header=$(head -1 "$CLAUDE_SESSION_META_DIR/discoveries.md")
    assert_eq "# Discoveries & Notes" "$header" "Header should be preserved" || return 1
}

test_archiver_keeps_recent_entries() {
    {
        echo "# Discoveries & Notes"
        echo ""
        for i in $(seq 1 30); do
            echo "## Finding $i"
            echo "Detail for finding $i with enough content"
            echo "Second line for $i"
            echo "Third line for $i"
            echo "Fourth line for $i"
            echo "Fifth line for $i"
            echo "Sixth line for $i"
            echo ""
        done
    } > "$CLAUDE_SESSION_META_DIR/discoveries.md"

    echo '{}' | bash "$HOOKS_DIR/discoveries-archiver.sh"

    # The most recent entries should still be in discoveries
    assert_file_contains "$CLAUDE_SESSION_META_DIR/discoveries.md" "Finding 30" \
        "Most recent entry should be kept" || return 1
}

test_archiver_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    echo '{}' | bash "$HOOKS_DIR/discoveries-archiver.sh"
    # Should exit cleanly with no output
}

test_archiver_logs_rotation() {
    {
        echo "# Discoveries"
        echo ""
        for i in $(seq 1 30); do
            echo "## Entry $i"
            echo "Content $i line 1"
            echo "Content $i line 2"
            echo "Content $i line 3"
            echo "Content $i line 4"
            echo "Content $i line 5"
            echo "Content $i line 6"
            echo ""
        done
    } > "$CLAUDE_SESSION_META_DIR/discoveries.md"

    echo '{}' | bash "$HOOKS_DIR/discoveries-archiver.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Archived discoveries" \
        "Should log the rotation" || return 1
}

# ============================================================================
# discoveries-reminder.sh
# ============================================================================

test_reminder_approves_outside_session() {
    unset CLAUDE_SESSION_NAME
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/discoveries-reminder.sh")
    assert_output_contains "$output" '"approve"' "Should approve outside session" || return 1
}

test_reminder_approves_when_recently_modified() {
    echo "# Recent discoveries" > "$CLAUDE_SESSION_META_DIR/discoveries.md"
    # File was just created, so mtime is now — within cooldown
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/discoveries-reminder.sh")
    assert_output_contains "$output" '"approve"' \
        "Should approve when discoveries recently modified" || return 1
}

test_reminder_blocks_when_stale() {
    echo "# Stale discoveries" > "$CLAUDE_SESSION_META_DIR/discoveries.md"
    # Backdate the file to 10 minutes ago
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CLAUDE_SESSION_META_DIR/discoveries.md" 2>/dev/null || {
        # Fallback: directly use a past mtime
        touch -A -001000 "$CLAUDE_SESSION_META_DIR/discoveries.md" 2>/dev/null || true
    }
    # Also make sure no cooldown file exists
    rm -f "$CLAUDE_SESSION_META_DIR/.discoveries-reminder-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/discoveries-reminder.sh")
    assert_output_contains "$output" '"block"' \
        "Should block when discoveries are stale" || return 1
    assert_output_contains "$output" "Discoveries check" \
        "Should include discovery check message" || return 1
}

test_reminder_respects_cooldown() {
    echo "# Stale discoveries" > "$CLAUDE_SESSION_META_DIR/discoveries.md"
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CLAUDE_SESSION_META_DIR/discoveries.md" 2>/dev/null || true

    # Set cooldown to now
    date +%s > "$CLAUDE_SESSION_META_DIR/.discoveries-reminder-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/discoveries-reminder.sh")
    assert_output_contains "$output" '"approve"' \
        "Should approve during cooldown period" || return 1
}

# ============================================================================
# session-auto-approve.sh
# ============================================================================

test_auto_approve_allows_cs_metadata_write() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/discoveries.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve writes to .cs/ files" || return 1
}

test_auto_approve_allows_cs_edit() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/changes.md" \
        '{tool_name: "Edit", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve edits to .cs/ files" || return 1
}

test_auto_approve_ignores_non_cs_path() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_DIR/src/main.py" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    # Should produce no output (falls through to normal permission prompt)
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-.cs/ paths, got: $output"
        return 1
    fi
}

test_auto_approve_ignores_non_write_tools() {
    local input='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-Write/Edit tools, got: $output"
        return 1
    fi
}

test_auto_approve_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Write","tool_input":{"file_path":"/tmp/anything.md"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# subagent-context.sh
# ============================================================================

test_subagent_injects_session_name() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_NAME" \
        "Should include session name" || return 1
}

test_subagent_injects_session_dir() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_DIR" \
        "Should include session directory" || return 1
}

test_subagent_returns_valid_json() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null 2>&1; then
        echo "  FAIL: Output should have hookSpecificOutput.additionalContext"
        echo "  Output: $output"
        return 1
    fi
}

test_subagent_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# tool-failure-logger.sh
# ============================================================================

test_failure_logged_to_session_log() {
    local input='{"tool_name":"Bash","error":"Command failed with exit code 1"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Tool failure: Bash" \
        "Should log tool name" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Command failed" \
        "Should log error message" || return 1
}

test_failure_log_has_timestamp() {
    local input='{"tool_name":"Write","error":"Permission denied"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$CLAUDE_SESSION_META_DIR/logs/session.log" || {
        echo "  FAIL: Log should have timestamp"
        return 1
    }
}

test_failure_truncates_long_errors() {
    local long_error
    long_error=$(python3 -c "print('x' * 500)")
    local input
    input=$(jq -n --arg err "$long_error" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    local log_line
    log_line=$(grep "Tool failure" "$CLAUDE_SESSION_META_DIR/logs/session.log" | head -1)
    local line_len=${#log_line}
    if [[ "$line_len" -gt 280 ]]; then
        echo "  FAIL: Log line should be truncated ($line_len chars)"
        return 1
    fi
}

test_failure_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Bash","error":"fail"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    # Should exit cleanly without writing anything
    if [[ -s "$CLAUDE_SESSION_META_DIR/logs/session.log" ]]; then
        local content
        content=$(cat "$CLAUDE_SESSION_META_DIR/logs/session.log")
        if [[ -n "$content" ]]; then
            echo "  FAIL: Should not log outside session"
            return 1
        fi
    fi
}

test_failure_handles_missing_error() {
    local input='{"tool_name":"Read"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Tool failure: Read" \
        "Should handle missing error field" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs session hook tests"
echo "====================="
echo ""

# Discoveries archiver
run_test test_archiver_skips_small_file
run_test test_archiver_moves_old_entries
run_test test_archiver_preserves_header
run_test test_archiver_keeps_recent_entries
run_test test_archiver_skips_outside_session
run_test test_archiver_logs_rotation

# Discoveries reminder
run_test test_reminder_approves_outside_session
run_test test_reminder_approves_when_recently_modified
run_test test_reminder_blocks_when_stale
run_test test_reminder_respects_cooldown

# Session auto-approve
run_test test_auto_approve_allows_cs_metadata_write
run_test test_auto_approve_allows_cs_edit
run_test test_auto_approve_ignores_non_cs_path
run_test test_auto_approve_ignores_non_write_tools
run_test test_auto_approve_skips_outside_session

# Subagent context
run_test test_subagent_injects_session_name
run_test test_subagent_injects_session_dir
run_test test_subagent_returns_valid_json
run_test test_subagent_skips_outside_session

# Tool failure logger
run_test test_failure_logged_to_session_log
run_test test_failure_log_has_timestamp
run_test test_failure_truncates_long_errors
run_test test_failure_skips_outside_session
run_test test_failure_handles_missing_error

report_results
