#!/usr/bin/env bash
# ABOUTME: Tests for cs-secrets encrypted file backend and CLI dispatch
# ABOUTME: Validates store/get/list/delete/purge/export and backend detection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

# Override setup to use encrypted backend with a test-scoped secrets dir
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_SECRETS_BACKEND="encrypted"
    export CS_SECRETS_PASSWORD="test-password-for-ci"
    export HOME="$TEST_TMPDIR/home"
    export CLAUDE_SESSION_NAME="test-session"
    mkdir -p "$CS_SESSIONS_ROOT" "$HOME"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_SECRETS_BACKEND CS_SECRETS_PASSWORD CLAUDE_SESSION_NAME 2>/dev/null || true
    # Restore HOME
    export HOME="$ORIGINAL_HOME"
}

# Save real HOME before tests override it
ORIGINAL_HOME="$HOME"

# ============================================================================
# Backend detection
# ============================================================================

test_backend_shows_encrypted() {
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should show encrypted backend" || return 1
}

test_backend_override_via_env() {
    export CS_SECRETS_BACKEND="encrypted"
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should respect CS_SECRETS_BACKEND" || return 1
}

# ============================================================================
# Store and retrieve
# ============================================================================

test_store_and_get() {
    "$CS_SECRETS_BIN" set api_key "sk_test_123" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_test_123" "$value" "Should retrieve stored value" || return 1
}

test_store_with_spaces_in_value() {
    "$CS_SECRETS_BIN" set db_url "postgres://user:pass@localhost/my db" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get db_url 2>&1)
    assert_eq "postgres://user:pass@localhost/my db" "$value" "Should handle spaces" || return 1
}

test_store_with_special_chars() {
    "$CS_SECRETS_BIN" set token 'abc!@#$%^&*()_+' 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get token 2>&1)
    assert_eq 'abc!@#$%^&*()_+' "$value" "Should handle special chars" || return 1
}

test_store_overwrites_existing() {
    "$CS_SECRETS_BIN" set api_key "old_value" 2>&1
    "$CS_SECRETS_BIN" set api_key "new_value" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "new_value" "$value" "Should overwrite with new value" || return 1
}

test_get_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" get nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

# ============================================================================
# List
# ============================================================================

test_list_empty() {
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "No secrets" "Should say no secrets" || return 1
}

test_list_shows_stored_secrets() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" set db_pass "xyz" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "api_key" "Should list api_key" || return 1
    assert_output_contains "$output" "db_pass" "Should list db_pass" || return 1
}

test_list_does_not_show_values() {
    "$CS_SECRETS_BIN" set api_key "supersecret" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_not_contains "$output" "supersecret" "List should not show values" || return 1
}

# ============================================================================
# Delete
# ============================================================================

test_delete_removes_secret() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" delete api_key 2>&1
    local output
    if "$CS_SECRETS_BIN" get api_key 2>&1; then
        echo "  FAIL: Secret should be deleted"
        return 1
    fi
}

test_delete_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" delete nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

test_delete_preserves_other_secrets() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" delete key1 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get key2 2>&1)
    assert_eq "val2" "$value" "Other secrets should be preserved" || return 1
}

# ============================================================================
# Purge
# ============================================================================

test_purge_removes_all() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" set key3 "val3" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "Purged 3" "Should purge 3 secrets" || return 1

    local list_output
    list_output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$list_output" "No secrets" "All secrets should be gone" || return 1
}

test_purge_empty_session() {
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "No secrets to purge" "Should handle empty purge" || return 1
}

# ============================================================================
# Export
# ============================================================================

test_export_produces_eval_format() {
    "$CS_SECRETS_BIN" set api_key "sk_123" 2>&1
    "$CS_SECRETS_BIN" set db_pass "hunter2" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    assert_output_contains "$output" "export API_KEY=" "Should export API_KEY" || return 1
    assert_output_contains "$output" "export DB_PASS=" "Should export DB_PASS" || return 1
}

test_export_is_eval_safe() {
    "$CS_SECRETS_BIN" set test_key "value with spaces" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    # The export should be eval-safe (properly quoted)
    eval "$output" 2>/dev/null
    assert_eq "value with spaces" "$TEST_KEY" "Eval'd export should set correct value" || return 1
}

# ============================================================================
# Encrypted file internals
# ============================================================================

test_encrypted_file_created() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    assert_exists "$enc_file" "Encrypted file should exist" || return 1
}

test_encrypted_file_not_plaintext() {
    "$CS_SECRETS_BIN" set api_key "visible_secret_value" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    if grep -q "visible_secret_value" "$enc_file" 2>/dev/null; then
        echo "  FAIL: Encrypted file should not contain plaintext secret"
        return 1
    fi
}

test_encrypted_file_permissions() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    local perms
    perms=$(stat -f "%Lp" "$enc_file" 2>/dev/null || stat -c "%a" "$enc_file" 2>/dev/null)
    assert_eq "600" "$perms" "Encrypted file should be 600" || return 1
}

test_secrets_dir_permissions() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local perms
    perms=$(stat -f "%Lp" "$HOME/.cs-secrets" 2>/dev/null || stat -c "%a" "$HOME/.cs-secrets" 2>/dev/null)
    assert_eq "700" "$perms" "Secrets dir should be 700" || return 1
}

# ============================================================================
# Session isolation
# ============================================================================

test_sessions_are_isolated() {
    export CLAUDE_SESSION_NAME="session-a"
    "$CS_SECRETS_BIN" set shared_key "value_a" 2>&1

    export CLAUDE_SESSION_NAME="session-b"
    "$CS_SECRETS_BIN" set shared_key "value_b" 2>&1

    export CLAUDE_SESSION_NAME="session-a"
    local value_a
    value_a=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_a" "$value_a" "Session A should have its own value" || return 1

    export CLAUDE_SESSION_NAME="session-b"
    local value_b
    value_b=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_b" "$value_b" "Session B should have its own value" || return 1
}

# ============================================================================
# CLI dispatch
# ============================================================================

test_store_alias_works() {
    "$CS_SECRETS_BIN" store api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "abc" "$value" "store alias should work" || return 1
}

test_ls_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" ls 2>&1)
    assert_output_contains "$output" "api_key" "ls alias should work" || return 1
}

test_rm_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" rm api_key 2>&1
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: rm alias should delete secret"
        return 1
    fi
}

test_session_flag_overrides_env() {
    export CLAUDE_SESSION_NAME="default-session"
    "$CS_SECRETS_BIN" --session other-session set api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" --session other-session get api_key 2>&1)
    assert_eq "abc" "$value" "--session flag should override env" || return 1

    # Default session should not have it
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: Default session should not have the secret"
        return 1
    fi
}

test_no_session_errors() {
    unset CLAUDE_SESSION_NAME
    local output
    if output=$("$CS_SECRETS_BIN" set api_key "abc" 2>&1); then
        echo "  FAIL: Should fail without session name"
        return 1
    fi
}

test_help_shows_usage() {
    local output
    output=$("$CS_SECRETS_BIN" --help 2>&1) || true
    assert_output_contains "$output" "Usage" "Should show usage" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs-secrets tests"
echo "================"
echo ""

# Backend
run_test test_backend_shows_encrypted
run_test test_backend_override_via_env

# Store and retrieve
run_test test_store_and_get
run_test test_store_with_spaces_in_value
run_test test_store_with_special_chars
run_test test_store_overwrites_existing
run_test test_get_nonexistent_fails

# List
run_test test_list_empty
run_test test_list_shows_stored_secrets
run_test test_list_does_not_show_values

# Delete
run_test test_delete_removes_secret
run_test test_delete_nonexistent_fails
run_test test_delete_preserves_other_secrets

# Purge
run_test test_purge_removes_all
run_test test_purge_empty_session

# Export
run_test test_export_produces_eval_format
run_test test_export_is_eval_safe

# Encrypted file internals
run_test test_encrypted_file_created
run_test test_encrypted_file_not_plaintext
run_test test_encrypted_file_permissions
run_test test_secrets_dir_permissions

# Session isolation
run_test test_sessions_are_isolated

# CLI dispatch
run_test test_store_alias_works
run_test test_ls_alias_works
run_test test_rm_alias_works
run_test test_session_flag_overrides_env
run_test test_no_session_errors
run_test test_help_shows_usage

report_results
