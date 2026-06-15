#!/usr/bin/env bash
# ABOUTME: Tests for session lifecycle hooks not covered by other test files
# ABOUTME: Covers session-auto-approve, subagent-context, tool-failure-logger

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
# narrative-reminder.sh
# ============================================================================

_backdate() {
    # backdate a file ~10 minutes so the staleness check fires
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$1" 2>/dev/null || true
}

test_narrative_reminder_approves_outside_session() {
    local output
    output=$(echo '{}' | CLAUDE_SESSION_NAME= bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve outside a cs session" || return 1
}

test_narrative_reminder_approves_when_recently_modified() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve when narrative recently modified" || return 1
}

test_narrative_reminder_blocks_when_stale() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "Should block when narrative is stale" || return 1
    assert_output_contains "$output" "narrative.md" "Reminder should point at narrative.md" || return 1
}

test_narrative_reminder_respects_cooldown() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    date +%s > "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Fresh cooldown should suppress the reminder" || return 1
}

test_narrative_reminder_approves_for_subagent() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{"agent_id":"sub-1"}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Subagent should always approve" || return 1
    assert_output_not_contains "$output" "block" "Subagent should never be blocked" || return 1
}

# ============================================================================
# session-auto-approve.sh
# ============================================================================

test_auto_approve_allows_cs_metadata_write() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve writes to .cs/ files" || return 1
}

test_auto_approve_allows_cs_edit() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/summary.md" \
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

test_failure_handles_huge_multiline_error() {
    # Regression: echo "$err" | head -1 | cut writes >64KB before head closes,
    # causing SIGPIPE in echo. With pipefail, this killed the hook silently.
    # Reproduce with a large multi-line error like a long stack trace.
    local huge_error
    huge_error=$(python3 -c "print('\n'.join(['x' * 500 for _ in range(500)]))")
    local input
    input=$(jq -n --arg err "$huge_error" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Tool failure: Bash" \
        "Should log huge multi-line error without crashing" || return 1
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
    # Isolate from an ambient CS_FRESH_REBIND (set when the suite runs from inside
    # a freshly-rebound cs session); the positive test re-supplies it inline.
    unset CS_FRESH_REBIND 2>/dev/null || true
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

# Helper: seed README frontmatter with a recorded claude_session_id
seed_recorded_uuid() {
    local uuid="$1"
    sed -i.bak "/^created:/a\\
claude_session_id: $uuid" "$CLAUDE_SESSION_META_DIR/README.md" && rm -f "$CLAUDE_SESSION_META_DIR/README.md.bak"
}

test_session_start_rebinds_uuid_to_live_session() {
    session_start_setup

    # README records an old conversation; the hook reports a different live one
    # (claude forks a new UUID on context-limit continuation, leaving the old
    # transcript on disk — the recorded binding goes stale)
    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind claude_session_id to the live session UUID" || { session_start_teardown; return 1; }
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "aaaaaaaa-1111-2222-3333-444444444444" \
        "Stale UUID should be gone after rebind" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_uuid_on_startup() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind on startup too (live UUID is authoritative on every source)" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_ignores_invalid_session_id() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # Non-UUID session_id (eg. jq null fallback or harness stub) must not
    # clobber a valid recorded binding
    echo '{"session_id":"not-a-uuid","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "Recorded UUID should survive an invalid live session_id" || { session_start_teardown; return 1; }

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
# timeline.jsonl
# ============================================================================

test_session_start_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Need README with frontmatter for full context
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-09
tags: []
aliases: ["test-session"]
---
# Session: test-session
EOF

    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && git add -A && git commit -q -m init) 2>/dev/null || true

    echo '{"session_id":"abc","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1

    assert_exists "$timeline" "timeline.jsonl should be created" || return 1
    # Should contain a started event
    if ! jq -e '. | select(.event == "started")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain a started event"
        echo "  Content: $(cat "$timeline")"
        return 1
    fi
}

test_session_end_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    echo '{"session_id":"abc","source":"user_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$timeline" "timeline.jsonl should be created on end" || return 1
    if ! jq -e '. | select(.event == "ended")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain an ended event"
        return 1
    fi
}

test_timeline_events_are_valid_jsonl() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Write a fake event
    echo '{"ts":"2026-04-09T20:00:00Z","event":"started","source":"resume"}' >> "$timeline"
    echo '{"ts":"2026-04-09T20:30:00Z","event":"ended","source":"user_exit"}' >> "$timeline"

    # Each line must be valid JSON
    while IFS= read -r line; do
        if ! echo "$line" | jq -e . > /dev/null 2>&1; then
            echo "  FAIL: Invalid JSON line: $line"
            return 1
        fi
    done < "$timeline"
}

test_timeline_subagent_skipped() {
    # Subagents shouldn't write to parent's timeline
    # (test indirectly: session-start with agent_id should not append)
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"
    echo '{}' > "$CLAUDE_SESSION_META_DIR/README.md"

    # SubagentStart doesn't fire session-start, but if a subagent somehow invokes it
    # with agent_id in payload, the hook should skip the timeline append.
    # (This test documents the expectation even though in practice SubagentStart
    # is a different hook event.)
    echo '{"session_id":"abc","source":"startup","agent_id":"sub-123"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1 || true

    # Timeline should not exist or should not have a started event from this
    if [[ -f "$timeline" ]] && jq -e '. | select(.event == "started" and .subagent == true)' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: subagent invocation should not add timeline entry"
        return 1
    fi
}

# ============================================================================
# session-end.sh: updated timestamp in frontmatter
# ============================================================================

test_session_end_sets_updated_timestamp() {
    index_setup

    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated:" \
        "Should not have updated before session end" || { index_teardown; return 1; }

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated: 20" \
        "Should set updated after session end" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_generates_index_with_many_changes() {
    # Regression: when git has 6+ uncommitted files, the FILE_LIST pipeline
    # used to trip SIGPIPE + pipefail, killing the script before index.md
    # was generated.
    index_setup

    # Enable auto-sync so the buggy block runs
    echo "auto_sync=on" > "$CLAUDE_SESSION_META_DIR/sync.conf"

    # Create more than 5 uncommitted files in the session repo
    for i in 1 2 3 4 5 6 7 8; do
        echo "content $i" > "$CLAUDE_SESSION_DIR/file_$i.txt"
    done

    echo '{"session_id":"test-123","source":"user_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" \
        "index.md should be generated even with 6+ uncommitted files" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_updates_existing_timestamp() {
    index_setup

    # Add an old updated timestamp
    sed -i.bak '/^tags:/a\
updated: 2026-01-01' "$CLAUDE_SESSION_META_DIR/README.md" && rm -f "$CLAUDE_SESSION_META_DIR/README.md.bak"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    # Should be today, not the old date
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated: 2026-01-01" \
        "Should overwrite old date" || { index_teardown; return 1; }
    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated: $(date '+%Y-%m-%d')" \
        "Should have today's date" || { index_teardown; return 1; }

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

# Session auto-approve
run_test test_narrative_reminder_approves_outside_session
run_test test_narrative_reminder_approves_when_recently_modified
run_test test_narrative_reminder_blocks_when_stale
run_test test_narrative_reminder_respects_cooldown
run_test test_narrative_reminder_approves_for_subagent
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
run_test test_failure_handles_huge_multiline_error
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
run_test test_session_start_rebinds_uuid_to_live_session
run_test test_session_start_rebinds_uuid_on_startup
run_test test_session_start_rebind_ignores_invalid_session_id

# Session end: index.md generation
run_test test_session_end_generates_index
run_test test_index_lists_all_sessions
run_test test_index_shows_objectives
run_test test_index_shows_status
run_test test_index_skips_remote_stubs
run_test test_index_has_auto_generated_notice

# Timeline
run_test test_session_start_appends_to_timeline

# ============================================================================
# session-start.sh: CS_FRESH_REBIND signal — tailored additionalContext when
# the user declined to resume the prior conversation
# ============================================================================

test_session_start_fresh_rebind_injects_clean_break_notice() {
    session_start_setup

    local output context
    output=$(CS_FRESH_REBIND=1 \
        echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_FRESH_REBIND=1 bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind context block missing"
        echo "  Context tail: $(echo "$context" | tail -8)"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q "clean break"; then
        echo "  FAIL: fresh-rebind block should mention the clean break"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_without_fresh_rebind_omits_clean_break_notice() {
    session_start_setup

    # No CS_FRESH_REBIND env — context must NOT include the block.
    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if echo "$context" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind block must not appear when CS_FRESH_REBIND is unset"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

run_test test_session_start_fresh_rebind_injects_clean_break_notice
run_test test_session_start_without_fresh_rebind_omits_clean_break_notice
run_test test_session_end_appends_to_timeline
run_test test_timeline_events_are_valid_jsonl
run_test test_timeline_subagent_skipped

# Session end: updated timestamp
run_test test_session_end_sets_updated_timestamp
run_test test_session_end_generates_index_with_many_changes
run_test test_session_end_updates_existing_timestamp

# ============================================================================
# Retired-hooks cleanup (install.sh + run_uninstall)
# ============================================================================

test_retired_hooks_strip_settings_json() {
    # Settings.json with one retired hook (PreCompact only) and one current hook (PostToolUse)
    local settings='{"hooks":{"PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local p="$HOME/.claude/hooks/discoveries-archiver.sh"
    local t="~/.claude/hooks/discoveries-archiver.sh"
    local stripped
    stripped=$(echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
            | .hooks |= with_entries(select(.value | length > 0))
            | if .hooks == {} then del(.hooks) else . end
        else . end
    ')
    if echo "$stripped" | jq -e '.hooks.PreCompact' >/dev/null 2>&1; then
        echo "  FAIL: PreCompact event should be empty/gone after stripping its only (retired) hook"
        echo "  got: $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[0].command' >/dev/null 2>&1; then
        echo "  FAIL: PostToolUse should still have its (current) hook after stripping unrelated retired"
        return 1
    fi
}

test_retired_hooks_strip_preserves_coexisting_hook() {
    # Two hooks under SAME event — one retired, one current. Only the retired should be stripped.
    local settings='{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10},{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local p="$HOME/.claude/hooks/discoveries-archiver.sh"
    local t="~/.claude/hooks/discoveries-archiver.sh"
    local stripped
    stripped=$(echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
        else . end
    ')
    local remaining_count
    remaining_count=$(echo "$stripped" | jq '.hooks.PostToolUse[0].hooks | length')
    if [ "$remaining_count" != "1" ]; then
        echo "  FAIL: expected 1 hook to remain in PostToolUse[0], got $remaining_count"
        echo "  $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[] | select(.command | contains("discovery-commits"))' >/dev/null 2>&1; then
        echo "  FAIL: discovery-commits entry should remain"
        return 1
    fi
}

run_test test_retired_hooks_strip_settings_json
run_test test_retired_hooks_strip_preserves_coexisting_hook

# ============================================================================
# install.sh: cs-hook merge must preserve co-shipped non-cs entries inside
# the same {hooks: [...]} wrapper. Spec tests — embed the exact jq filter
# install.sh must use.
# ============================================================================

# Filter shape documented here as the source of truth. install.sh's 12
# event-specific filters must follow the same pattern: dive into nested
# .hooks, strip only the matching command, drop wrappers that emptied out,
# leave flat or unrelated wrappers untouched, then append the cs entry.
_install_merge_filter() {
    cat << 'JQ'
.hooks[$event] = (
    ((.hooks[$event] // []) | map(
        if .hooks then
            .hooks |= map(select(.command != $path and .command != $tilde))
        else . end
    ) | map(select(.hooks == null or (.hooks | length > 0))))
    + [{ "hooks": [{ "type": "command", "command": $tilde, "timeout": $timeout }] }]
)
JQ
}

test_install_preserves_coshipped_hook_in_wrapper() {
    # User has a non-cs hook co-located inside the same wrapper as cs's hook.
    # Common pattern when the user hand-edited settings.json to add another
    # hook next to cs's. The merge must NOT drop the user's hook.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings
    settings=$(cat << EOF
{"hooks":{"SessionStart":[{"hooks":[
  {"type":"command","command":"~/bin/claude-status","timeout":5},
  {"type":"command","command":"$tilde","timeout":30}
]}]}}
EOF
)
    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local user_hook_count
    user_hook_count=$(echo "$result" | jq '[.. | objects | select(.command == "~/bin/claude-status")] | length')
    if [ "$user_hook_count" != "1" ]; then
        echo "  FAIL: claude-status should survive merge exactly once, got $user_hook_count"
        echo "  Result: $result"
        return 1
    fi

    local cs_hook_count
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')
    if [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: cs hook should appear exactly once, got $cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_drops_emptied_wrapper_when_only_cs_hook_present() {
    # Pre-existing standalone wrapper containing only cs's hook. After merge,
    # we want exactly one wrapper containing one cs entry — not two.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local wrapper_count cs_hook_count
    wrapper_count=$(echo "$result" | jq '.hooks.SessionStart | length')
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')

    if [ "$wrapper_count" != "1" ] || [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: expected 1 wrapper + 1 cs entry; got wrappers=$wrapper_count cs_entries=$cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_leaves_flat_entries_alone() {
    # Old-shape flat entries (no .hooks nesting) must pass through untouched.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"type":"command","command":"~/bin/claude-status","timeout":5}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    if ! echo "$result" | jq -e '.hooks.SessionStart[] | select(.command == "~/bin/claude-status")' >/dev/null; then
        echo "  FAIL: flat-shape claude-status entry was dropped"
        echo "  Result: $result"
        return 1
    fi
}

run_test test_install_preserves_coshipped_hook_in_wrapper
run_test test_install_drops_emptied_wrapper_when_only_cs_hook_present
run_test test_install_leaves_flat_entries_alone

report_results
