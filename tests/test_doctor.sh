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
}

test_doctor_reports_pass_for_healthy_session() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "OK" "healthy session should show OK status" || return 1
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

# Helper: build a directory that looks like a cs source checkout
make_fake_checkout() {
    local dir="$1"
    mkdir -p "$dir/hooks" "$dir/bin"
    : > "$dir/install.sh"
    : > "$dir/bin/cs"
}

test_doctor_warns_on_hook_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout"
    mkdir -p "$deployed"
    echo 'echo source-version' > "$checkout/hooks/session-start.sh"
    echo 'echo deployed-version' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "differs from source" \
        "doctor should warn when a deployed hook differs from checkout source" || return 1
}

test_doctor_warns_on_undeployed_hook() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout"
    mkdir -p "$deployed"
    echo 'echo only-in-source' > "$checkout/hooks/brand-new.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "not deployed" \
        "doctor should warn when a source hook has no deployed copy" || return 1
}

test_doctor_drift_silent_when_in_sync() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout"
    mkdir -p "$deployed"
    echo 'echo same' > "$checkout/hooks/session-start.sh"
    cp "$checkout/hooks/session-start.sh" "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -q "differs from source\|not deployed"; then
        echo "  FAIL: in-sync hooks should not produce drift warnings"
        echo "$output" | grep "Hook drift"
        return 1
    fi
}

test_doctor_drift_skipped_outside_checkout() {
    local plain="$TEST_TMPDIR/not-a-checkout" deployed="$TEST_TMPDIR/deployed"
    mkdir -p "$plain" "$deployed"
    echo 'echo deployed' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$plain" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -qi "drift"; then
        echo "  FAIL: drift check should be silent outside a cs source checkout"
        return 1
    fi
}

test_doctor_warns_on_command_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_cmds="$TEST_TMPDIR/commands"
    make_fake_checkout "$checkout"
    mkdir -p "$checkout/commands" "$deployed_cmds" "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/commands/summary.md"
    echo 'deployed version' > "$deployed_cmds/summary.md"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_COMMANDS_DIR="$deployed_cmds" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Command drift" \
        "doctor should warn when a deployed command differs from checkout source" || return 1
}

test_doctor_warns_on_skill_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_skills="$TEST_TMPDIR/skills"
    make_fake_checkout "$checkout"
    mkdir -p "$checkout/skills/store-secret" "$deployed_skills/store-secret" "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/skills/store-secret/SKILL.md"
    echo 'deployed version' > "$deployed_skills/store-secret/SKILL.md"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_SKILLS_DIR="$deployed_skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Skill drift" \
        "doctor should warn when a deployed skill differs from checkout source" || return 1
}

test_doctor_warns_on_version_mismatch() {
    local deployed="$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$deployed"
    echo "0.0.0" > "$deployed/.version"

    local output
    output=$(CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Deployed version" \
        "doctor should warn when the deployed stamp differs from cs VERSION" || return 1
    assert_output_contains "$output" "0.0.0" \
        "warning should name the stamped version" || return 1
}

test_doctor_version_silent_without_stamp() {
    local deployed="$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$deployed"
    echo 'echo x' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -q "Deployed version.*WARN\|WARN.*Deployed version"; then
        echo "  FAIL: missing stamp should not produce a version warning"
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

# --- Settings.json hook-resolve scan ---
# Catches the inverse direction of _doctor_check_hooks_registered: hooks registered
# in settings.json that point at files which do not exist on disk. This is the
# class of orphan that aboutme-validator.sh exemplified — a feature-branch
# experiment registered the hook in settings.json without the file ever shipping.

test_doctor_runs_settings_hooks_resolve_check() {
    local fake_claude="$TEST_TMPDIR/claude-resolve"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/exists.sh"
    chmod +x "$fake_claude/hooks/exists.sh"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$fake_claude/hooks/exists.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths" "doctor should report a hook-paths summary" || return 1
}

test_doctor_warns_on_settings_hook_missing_file() {
    local fake_claude="$TEST_TMPDIR/claude-orphan"
    mkdir -p "$fake_claude/hooks"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "$fake_claude/hooks/aboutme-validator.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "WARN.*Hook paths\|registered hook.*missing\|aboutme-validator" \
        "doctor should warn when a registered hook points at a missing file" || return 1
}

test_doctor_passes_when_all_settings_hooks_resolve() {
    local fake_claude="$TEST_TMPDIR/claude-clean"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$fake_claude/hooks/real.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "$fake_claude/hooks/real.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths.*OK\|Hook paths.*resolve\|Hook paths.*all" \
        "all-resolved hooks should produce an OK status" || return 1
    assert_output_not_contains "$output" "registered hook.*missing" \
        "no warning should be raised when every hook file exists" || return 1
}

test_doctor_settings_hooks_resolve_handles_no_hooks_section() {
    local fake_claude="$TEST_TMPDIR/claude-nohooks"
    mkdir -p "$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{ "permissions": {"allow": [], "deny": []} }
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths" \
        "check should still run when settings.json has no hooks key" || return 1
    assert_output_not_contains "$output" "registered hook.*missing" \
        "missing hooks key is not a leak" || return 1
}

test_doctor_settings_hooks_resolve_expands_tilde() {
    # settings.json typically uses ~/ in the command path; the check must expand it.
    local fake_claude="$TEST_TMPDIR/claude-tilde"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    local fake_home="$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/hooks/real.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(HOME="$fake_home" CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "missing" \
        "tilde-prefixed paths must be expanded before existence check" || return 1
}

test_doctor_skips_inline_shell_hook_commands() {
    # Inline shell snippets (e.g. an `if [ -z "$TMUX" ]...` PreToolUse hook) are
    # valid hook commands, not file paths, and must not be flagged as missing.
    local fake_claude="$TEST_TMPDIR/claude-inline"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    jq -n --arg real "$fake_claude/hooks/real.sh" '{
      hooks: {
        PreToolUse: [
          {hooks: [{type: "command", command: "if [ -z \"$TMUX\" ]; then echo hi >&2; fi"}]},
          {matcher: "Bash", hooks: [{type: "command", command: $real}]}
        ]
      }
    }' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "registered hook.*missing" \
        "inline shell-snippet hook commands must not be flagged as missing files" || return 1
}

test_doctor_statusline_ok_when_registered_and_executable() {
    local fake_claude="$TEST_TMPDIR/sl-claude"
    local fake_bin="$TEST_TMPDIR/sl-bin"
    mkdir -p "$fake_claude" "$fake_bin"
    printf '#!/bin/sh\n' > "$fake_bin/cs-statusline"
    chmod +x "$fake_bin/cs-statusline"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$fake_bin/cs-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Statusline" "doctor should run a Statusline check" || return 1
    if echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: Statusline check failed for a healthy registration"
        return 1
    fi
}

test_doctor_statusline_fails_when_binary_missing() {
    local fake_claude="$TEST_TMPDIR/sl-claude-missing"
    mkdir -p "$fake_claude"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$TEST_TMPDIR/absent/cs-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    if ! echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: missing cs-statusline binary not reported as FAIL"
        echo "$output" | grep "Statusline" || echo "  (no Statusline line at all)"
        return 1
    fi
}

test_doctor_statusline_no_fail_when_not_registered() {
    local fake_claude="$TEST_TMPDIR/sl-claude-none"
    mkdir -p "$fake_claude"
    echo '{}' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Statusline" "doctor should mention the Statusline check even when unregistered" || return 1
    if echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: unregistered statusline must not FAIL (it is optional)"
        return 1
    fi
}

echo "Running doctor tests..."
run_test test_doctor_subcommand_exists
run_test test_doctor_runs_default_checks_from_session
run_test test_doctor_reports_pass_for_healthy_session
run_test test_doctor_fails_when_hook_not_executable
run_test test_doctor_exits_nonzero_on_failure
run_test test_doctor_warns_on_hook_drift
run_test test_doctor_warns_on_undeployed_hook
run_test test_doctor_drift_silent_when_in_sync
run_test test_doctor_drift_skipped_outside_checkout
run_test test_doctor_warns_on_command_drift
run_test test_doctor_warns_on_skill_drift
run_test test_doctor_warns_on_version_mismatch
run_test test_doctor_version_silent_without_stamp
run_test test_doctor_runs_without_session
run_test test_doctor_runs_audit_check
run_test test_doctor_audit_counts_settings_contents
run_test test_doctor_audit_handles_missing_settings
run_test test_doctor_runs_settings_hooks_resolve_check
run_test test_doctor_warns_on_settings_hook_missing_file
run_test test_doctor_passes_when_all_settings_hooks_resolve
run_test test_doctor_settings_hooks_resolve_handles_no_hooks_section
run_test test_doctor_settings_hooks_resolve_expands_tilde
run_test test_doctor_skips_inline_shell_hook_commands
run_test test_doctor_statusline_ok_when_registered_and_executable
run_test test_doctor_statusline_fails_when_binary_missing
run_test test_doctor_statusline_no_fail_when_not_registered
run_test test_doctor_runs_token_cost_check
run_test test_doctor_token_cost_sums_jsonl
run_test test_doctor_token_cost_handles_no_transcripts
report_results
