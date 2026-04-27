#!/usr/bin/env bash
# ABOUTME: Tests for cs -doctor health check subcommand
# ABOUTME: Validates check execution, status reporting, and exit codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-04-21
tags: []
aliases: ["test-session"]
---
# Session: test-session

## Objective
Test doctor
EOF
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## Sample finding
Short.
EOF
    echo "# Test" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m init)

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

test_doctor_subcommand_exists() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -doctor should be a recognized subcommand" || return 1
}

test_doctor_runs_default_checks_from_session() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Keychain" "should report Keychain check" || return 1
    assert_output_contains "$output" "Git" "should report git sync check" || return 1
    assert_output_contains "$output" "Hooks" "should report hooks check" || return 1
    assert_output_contains "$output" "Discoveries" "should report discoveries size check" || return 1
}

test_doctor_reports_pass_for_healthy_session() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "OK" "healthy session should show OK status" || return 1
}

test_doctor_warns_when_discoveries_over_budget() {
    local big_file="$CLAUDE_SESSION_META_DIR/discoveries.md"
    yes "## Filler entry content line padding padding padding" | head -1500 > "$big_file"
    local output
    output=$(CS_DISCOVERIES_MAX_SIZE=5000 "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "WARN\|over budget\|exceeds" \
        "oversized discoveries.md should produce a warning" || return 1
}

test_doctor_fails_when_hook_not_executable() {
    local fake_hook_dir="$TEST_TMPDIR/hooks"
    mkdir -p "$fake_hook_dir"
    touch "$fake_hook_dir/session-start.sh"
    chmod 644 "$fake_hook_dir/session-start.sh"
    local output
    output=$(CS_HOOKS_DIR="$fake_hook_dir" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "FAIL\|not executable" \
        "non-executable hook should produce a failure" || return 1
}

test_doctor_exits_nonzero_on_failure() {
    local fake_hook_dir="$TEST_TMPDIR/hooks"
    mkdir -p "$fake_hook_dir"
    touch "$fake_hook_dir/session-start.sh"
    chmod 644 "$fake_hook_dir/session-start.sh"
    local ec
    CS_HOOKS_DIR="$fake_hook_dir" "$CS_BIN" -doctor > /dev/null 2>&1
    ec=$?
    if [[ "$ec" == "0" ]]; then
        echo "  FAIL: doctor should exit non-zero when a check FAILs (got $ec)"
        return 1
    fi
}

test_doctor_runs_without_session() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Keychain" "global-only checks should still run" || return 1
    assert_output_not_contains "$output" "must be run from inside" \
        "doctor should not require a session context" || return 1
}

test_doctor_runs_audit_check() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Audit" "doctor should report an audit summary" || return 1
}

test_doctor_audit_counts_settings_contents() {
    local fake_claude="$TEST_TMPDIR/claude"
    mkdir -p "$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "/x.sh"}]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "/y.sh"}, {"type": "command", "command": "/z.sh"}]}
    ]
  },
  "permissions": {"allow": ["Bash(ls:*)", "Read"], "deny": ["Write(secrets/**)"]},
  "mcpServers": {"foo": {}, "bar": {}},
  "env": {"FOO": "1"}
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "3 hooks" "should count 3 hook commands across PreToolUse matchers" || return 1
    assert_output_contains "$output" "2 MCPs" "should count 2 MCP servers" || return 1
    assert_output_contains "$output" "3 perm rules" "should count 2 allow + 1 deny = 3 perm rules" || return 1
    assert_output_contains "$output" "1 env vars" "should count 1 env var" || return 1
}

test_doctor_does_not_flag_utility_hooks_as_missing() {
    # files-scan.sh is a utility invoked by session-start.sh — it lives in
    # ~/.claude/hooks/ but is intentionally absent from settings.json.
    # The hooks_registered check must skip it.
    local fake_hooks="$TEST_TMPDIR/utility-hooks"
    mkdir -p "$fake_hooks"
    touch "$fake_hooks/files-scan.sh"
    chmod +x "$fake_hooks/files-scan.sh"
    local output
    output=$(CS_HOOKS_DIR="$fake_hooks" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "missing in settings.json: files-scan.sh" \
        "utility hooks must not be flagged as unregistered" || return 1
}

test_doctor_runs_token_cost_check() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Tokens" "doctor should report a tokens summary inside a session" || return 1
}

test_doctor_token_cost_sums_jsonl() {
    local fake_transcripts="$TEST_TMPDIR/transcripts"
    local encoded
    encoded=$(echo "$CLAUDE_SESSION_DIR" | sed 's|/|-|g; s|\.|-|g')
    local proj_dir="$fake_transcripts/$encoded"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/session1.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":250}}}
{"type":"assistant","message":{"usage":{"input_tokens":2000,"output_tokens":500}}}
EOF
    cat > "$proj_dir/session2.jsonl" << 'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":3000,"output_tokens":750}}}
EOF
    local output
    output=$(CS_TRANSCRIPTS_DIR="$fake_transcripts" "$CS_BIN" -doctor 2>&1) || true
    # Expected: 6000 input, 1500 output
    assert_output_contains "$output" "6.0K input" "should sum input_tokens to 6000 across files" || return 1
    assert_output_contains "$output" "1.5K output" "should sum output_tokens to 1500" || return 1
}

test_doctor_token_cost_handles_no_transcripts() {
    local fake_transcripts="$TEST_TMPDIR/empty-transcripts"
    mkdir -p "$fake_transcripts"
    local output
    output=$(CS_TRANSCRIPTS_DIR="$fake_transcripts" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Tokens" "tokens check should still run when no transcripts exist" || return 1
    assert_output_contains "$output" "no transcripts" "should report missing transcripts gracefully" || return 1
}

test_doctor_audit_handles_missing_settings() {
    local fake_claude="$TEST_TMPDIR/claude-empty"
    mkdir -p "$fake_claude"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Audit" "audit check should still run when settings.json is missing" || return 1
}

echo "Running doctor tests..."
run_test test_doctor_subcommand_exists
run_test test_doctor_runs_default_checks_from_session
run_test test_doctor_reports_pass_for_healthy_session
run_test test_doctor_warns_when_discoveries_over_budget
run_test test_doctor_fails_when_hook_not_executable
run_test test_doctor_exits_nonzero_on_failure
run_test test_doctor_runs_without_session
run_test test_doctor_runs_audit_check
run_test test_doctor_audit_counts_settings_contents
run_test test_doctor_audit_handles_missing_settings
run_test test_doctor_runs_token_cost_check
run_test test_doctor_token_cost_sums_jsonl
run_test test_doctor_token_cost_handles_no_transcripts
run_test test_doctor_does_not_flag_utility_hooks_as_missing
report_results
