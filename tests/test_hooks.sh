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
# session-start.sh: cross-session context
# ============================================================================

# Setup for session-start tests needs CS_SESSIONS_ROOT with sibling sessions
session_start_setup() {
    setup
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session lives inside SESSIONS_ROOT
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{logs,artifacts,memory}
    touch "$CLAUDE_SESSION_META_DIR/logs/session.log"

    # Initialize git so the dynamic context block runs
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > README.md && git add -A && git commit -q -m init)

    # Create README with frontmatter and placeholder objective
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: []
aliases: ["current-session"]
---
# Session: current-session

## Objective

Current session objective
EOF
}

session_start_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

# Helper: create a sibling session with an objective
create_sibling_session() {
    local name="$1"
    local objective="$2"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs"/{logs,artifacts}
    cat > "$dir/.cs/README.md" << EOF
## Objective

$objective
EOF
    # Touch log to set modification time
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started" > "$dir/.cs/logs/session.log"
}

test_session_start_includes_sibling_sessions() {
    session_start_setup

    create_sibling_session "api-refactor" "Refactor REST API to use GraphQL"
    create_sibling_session "auth-migration" "Migrate auth from JWT to Clerk"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "api-refactor"; then
        echo "  FAIL: Should include sibling session api-refactor"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q "auth-migration"; then
        echo "  FAIL: Should include sibling session auth-migration"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_excludes_current_session() {
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Current session should NOT appear in the sibling list
    # (it's already the session being started)
    if echo "$context" | grep -q "Other Sessions" && echo "$context" | grep -q "current-session:"; then
        echo "  FAIL: Should not include current session in sibling list"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_shows_objectives() {
    session_start_setup

    create_sibling_session "my-project" "Build the analytics dashboard"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "analytics dashboard"; then
        echo "  FAIL: Should include sibling objective text"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_limits_sibling_count() {
    session_start_setup

    # Create 10 sibling sessions
    for i in $(seq 1 10); do
        create_sibling_session "session-$i" "Objective for session $i"
    done

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Should show at most 5 siblings
    local sibling_count
    sibling_count=$(echo "$context" | grep -c "^  [a-z]" || echo "0")
    if [[ "$sibling_count" -gt 5 ]]; then
        echo "  FAIL: Should limit to 5 siblings (got $sibling_count)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_updates_last_resumed() {
    session_start_setup

    # Verify no last_resumed yet
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "last_resumed:" \
        "Should not have last_resumed before resume" || { session_start_teardown; return 1; }

    # Trigger resume
    echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "last_resumed: 20" \
        "Should set last_resumed after resume" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_last_resumed_not_set_on_startup() {
    session_start_setup

    # source=startup should NOT set last_resumed
    echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "last_resumed:" \
        "Should not set last_resumed on startup" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_skips_siblings_on_startup() {
    session_start_setup

    create_sibling_session "other" "Some work"

    # source=startup (fresh session, not resume)
    local output
    output=$(echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # On startup, no dynamic context is injected (including siblings)
    if echo "$context" | grep -q "Other Sessions"; then
        echo "  FAIL: Should not inject siblings on startup (only on resume)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

# ============================================================================
# session-end.sh: index.md generation
# ============================================================================

# Setup for index tests: need SESSIONS_ROOT with sessions that have frontmatter
index_setup() {
    setup
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{logs,artifacts}
    touch "$CLAUDE_SESSION_META_DIR/logs/session.log"
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: [testing, hooks]
---
# Session: current-session

## Objective

Test the index generation feature

## Environment

Local dev
EOF
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && git add -A && git commit -q -m init)
}

index_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

# Helper: create a session with frontmatter
create_indexed_session() {
    local name="$1"
    local status="$2"
    local objective="$3"
    local tags="${4:-}"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs"/{logs,artifacts}
    touch "$dir/.cs/logs/session.log"
    cat > "$dir/.cs/README.md" << EOF
---
status: $status
created: 2026-04-01
tags: [$tags]
---
# Session: $name

## Objective

$objective

## Outcome

[pending]
EOF
}

test_session_end_generates_index() {
    index_setup

    create_indexed_session "api-work" "active" "Build the API" "api, backend"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" "index.md should be generated" || { index_teardown; return 1; }

    index_teardown
}

test_index_lists_all_sessions() {
    index_setup

    create_indexed_session "alpha" "active" "Alpha objective"
    create_indexed_session "beta" "completed" "Beta objective"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "alpha" "Should list alpha" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "beta" "Should list beta" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "current-session" "Should list current session" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_objectives() {
    index_setup

    create_indexed_session "my-project" "active" "Build the dashboard"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Build the dashboard" \
        "Should include objective text" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_status() {
    index_setup

    create_indexed_session "done-project" "completed" "Old work"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "completed" \
        "Should show status" || { index_teardown; return 1; }

    index_teardown
}

test_index_skips_remote_stubs() {
    index_setup

    create_indexed_session "remote-sess" "active" "Remote work"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/remote-sess/.cs/remote.conf"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_not_contains "$CS_SESSIONS_ROOT/index.md" "remote-sess" \
        "Should skip remote stubs" || { index_teardown; return 1; }

    index_teardown
}

test_index_has_auto_generated_notice() {
    index_setup

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Auto-generated" \
        "Should have auto-generated notice" || { index_teardown; return 1; }

    index_teardown
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

# Session start: cross-session context
run_test test_session_start_includes_sibling_sessions
run_test test_session_start_excludes_current_session
run_test test_session_start_shows_objectives
run_test test_session_start_limits_sibling_count
run_test test_session_start_updates_last_resumed
run_test test_session_start_last_resumed_not_set_on_startup
run_test test_session_start_skips_siblings_on_startup

# Session end: index.md generation
run_test test_session_end_generates_index
run_test test_index_lists_all_sessions
run_test test_index_shows_objectives
run_test test_index_shows_status
run_test test_index_skips_remote_stubs
run_test test_index_has_auto_generated_notice

report_results
