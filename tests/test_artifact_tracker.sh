#!/usr/bin/env bash
# ABOUTME: Tests for the artifact-tracker PreToolUse hook
# ABOUTME: Validates path rewriting, secret detection, content redaction, and MANIFEST updates

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/artifact-tracker.sh"

# Override setup for hook-specific env vars
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    mkdir -p "$CLAUDE_ARTIFACT_DIR"
    mkdir -p "$CLAUDE_SESSION_META_DIR/logs"
    echo "[]" > "$CLAUDE_ARTIFACT_DIR/MANIFEST.json"

    # Create a fake cs-secrets that logs store calls instead of touching keychain
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/cs" << 'FAKECS'
#!/bin/bash
if [[ "$1" == "-secrets" && "$2" == "set" ]]; then
    echo "$3=$4" >> "${CLAUDE_SESSION_META_DIR}/stored-secrets.log"
fi
FAKECS
    chmod +x "$TEST_TMPDIR/bin/cs"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# Helper: send a Write tool use to the hook
send_write() {
    local file_path="$1"
    local content="$2"
    jq -n \
        --arg tool "Write" \
        --arg path "$file_path" \
        --arg content "$content" \
        '{tool_name: $tool, tool_input: {file_path: $path, content: $content}, hook_event_name: "PreToolUse"}' \
        | bash "$HOOK"
}

# Helper: send a non-Write tool use
send_non_write() {
    echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"},"hook_event_name":"PreToolUse"}' \
        | bash "$HOOK"
}

# ============================================================================
# Passthrough tests
# ============================================================================

test_non_write_tool_passes_through() {
    local output
    output=$(send_non_write)
    assert_output_contains "$output" '"permissionDecision": "allow"' \
        "Non-Write tool should pass through" || return 1
    # Should NOT contain updatedInput
    assert_output_not_contains "$output" "updatedInput" \
        "Non-Write should not have updatedInput" || return 1
}

test_outside_session_passes_through() {
    unset CLAUDE_SESSION_NAME
    local output
    output=$(send_write "/tmp/test.sh" "#!/bin/bash\necho hello")
    assert_output_contains "$output" '"permissionDecision": "allow"' \
        "Outside session should pass through" || return 1
    assert_output_not_contains "$output" "updatedInput" \
        "Outside session should not rewrite path" || return 1
}

test_non_artifact_extension_passes_through() {
    local output
    output=$(send_write "/tmp/document.txt" "Just plain text")
    assert_output_contains "$output" '"permissionDecision": "allow"' \
        ".txt should pass through" || return 1
    assert_output_not_contains "$output" "updatedInput" \
        ".txt should not be redirected" || return 1
}

# ============================================================================
# Path rewriting tests
# ============================================================================

test_sh_file_redirected_to_artifacts() {
    local output
    output=$(send_write "/tmp/build.sh" "#!/bin/bash\necho building")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/build.sh" "$new_path" "Should redirect to artifacts dir" || return 1
}

test_py_file_redirected_to_artifacts() {
    local output
    output=$(send_write "/home/user/script.py" "print('hello')")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/script.py" "$new_path" "Python file should redirect" || return 1
}

test_json_file_redirected_to_artifacts() {
    local output
    output=$(send_write "/tmp/config.json" '{"key": "value"}')
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/config.json" "$new_path" "JSON file should redirect" || return 1
}

test_yaml_file_redirected_to_artifacts() {
    local output
    output=$(send_write "/tmp/config.yaml" "key: value")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/config.yaml" "$new_path" "YAML file should redirect" || return 1
}

test_env_file_redirected_to_artifacts() {
    local output
    output=$(send_write "/tmp/.env" "DATABASE_URL=postgres://localhost/db")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/.env" "$new_path" ".env file should redirect" || return 1
}

# ============================================================================
# Duplicate filename handling
# ============================================================================

test_duplicate_filename_gets_counter() {
    # First write creates build.sh
    send_write "/tmp/build.sh" "#!/bin/bash\necho v1" > /dev/null
    # Actually create the file so the hook sees it exists
    echo "v1" > "$CLAUDE_ARTIFACT_DIR/build.sh"

    # Second write should get build_1.sh
    local output
    output=$(send_write "/tmp/build.sh" "#!/bin/bash\necho v2")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/build_1.sh" "$new_path" "Duplicate should get _1 suffix" || return 1
}

test_multiple_duplicates_increment() {
    echo "v1" > "$CLAUDE_ARTIFACT_DIR/deploy.sh"
    echo "v2" > "$CLAUDE_ARTIFACT_DIR/deploy_1.sh"

    local output
    output=$(send_write "/tmp/deploy.sh" "#!/bin/bash\necho v3")
    local new_path
    new_path=$(echo "$output" | jq -r '.updatedInput.file_path')
    assert_eq "$CLAUDE_ARTIFACT_DIR/deploy_2.sh" "$new_path" "Should increment to _2" || return 1
}

# ============================================================================
# Sensitive file detection
# ============================================================================

test_env_extension_detected_as_sensitive() {
    local output
    output=$(send_write "/tmp/.env" "NORMAL_VAR=hello")
    # .env files are always flagged as sensitive by extension
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local is_sensitive
    is_sensitive=$(echo "$manifest" | jq '.[0].contains_secrets')
    assert_eq "1" "$is_sensitive" ".env should be flagged as sensitive" || return 1
}

test_filename_with_secret_detected() {
    local output
    output=$(send_write "/tmp/api-secret.yaml" "endpoint: https://api.example.com")
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local is_sensitive
    is_sensitive=$(echo "$manifest" | jq '.[0].contains_secrets')
    assert_eq "1" "$is_sensitive" "File with 'secret' in name should be flagged" || return 1
}

test_filename_with_key_detected() {
    local output
    output=$(send_write "/tmp/ssh-key.conf" "host: example.com")
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local is_sensitive
    is_sensitive=$(echo "$manifest" | jq '.[0].contains_secrets')
    assert_eq "1" "$is_sensitive" "File with 'key' in name should be flagged" || return 1
}

test_normal_script_not_flagged() {
    local output
    output=$(send_write "/tmp/build.sh" "#!/bin/bash\necho building")
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local is_sensitive
    is_sensitive=$(echo "$manifest" | jq '.[0].contains_secrets')
    assert_eq "0" "$is_sensitive" "Normal script should not be flagged" || return 1
}

# ============================================================================
# Content-based secret detection
# ============================================================================

test_api_key_in_content_detected() {
    local content='API_KEY=sk_live_abc123
DATABASE_URL=postgres://localhost/db'
    local output
    output=$(send_write "/tmp/config.sh" "$content")
    local redacted_content
    redacted_content=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$redacted_content" "REDACTED" \
        "API_KEY value should be redacted" || return 1
    assert_output_not_contains "$redacted_content" "sk_live_abc123" \
        "Raw API key should not appear" || return 1
}

test_secret_token_in_content_detected() {
    local content='SECRET_TOKEN=mysupersecretvalue
APP_NAME=myapp'
    local output
    output=$(send_write "/tmp/app.conf" "$content")
    local redacted_content
    redacted_content=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$redacted_content" "REDACTED" \
        "SECRET_TOKEN should be redacted" || return 1
    assert_output_not_contains "$redacted_content" "mysupersecretvalue" \
        "Raw secret should not appear" || return 1
}

test_password_in_content_detected() {
    local content='DB_PASSWORD=hunter2
DB_HOST=localhost'
    local output
    output=$(send_write "/tmp/db.conf" "$content")
    local redacted_content
    redacted_content=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$redacted_content" "REDACTED" \
        "DB_PASSWORD should be redacted" || return 1
    assert_output_not_contains "$redacted_content" "hunter2" \
        "Raw password should not appear" || return 1
}

test_non_sensitive_content_not_redacted() {
    local content='APP_NAME=myapp
APP_PORT=3000
DEBUG=true'
    local output
    output=$(send_write "/tmp/config.sh" "$content")
    local returned_content
    returned_content=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$returned_content" "APP_NAME=myapp" \
        "Non-sensitive vars should be preserved" || return 1
    assert_output_contains "$returned_content" "APP_PORT=3000" \
        "Non-sensitive vars should be preserved" || return 1
}

# ============================================================================
# Redaction format tests
# ============================================================================

test_redacts_unquoted_value() {
    local content='API_KEY=sk_live_abc123'
    local output
    output=$(send_write "/tmp/test.sh" "$content")
    local redacted
    redacted=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$redacted" "API_KEY=" "Key should be preserved" || return 1
    assert_output_contains "$redacted" "REDACTED" "Value should be redacted" || return 1
}

test_redacts_double_quoted_value() {
    local content='API_KEY="sk_live_abc123"'
    local output
    output=$(send_write "/tmp/test.sh" "$content")
    local redacted
    redacted=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_not_contains "$redacted" "sk_live_abc123" \
        "Double-quoted value should be redacted" || return 1
}

test_redacts_single_quoted_value() {
    local content="API_KEY='sk_live_abc123'"
    local output
    output=$(send_write "/tmp/test.sh" "$content")
    local redacted
    redacted=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_not_contains "$redacted" "sk_live_abc123" \
        "Single-quoted value should be redacted" || return 1
}

test_redacts_yaml_style_value() {
    local content='api_key: sk_live_abc123'
    local output
    output=$(send_write "/tmp/config.yaml" "$content")
    local redacted
    redacted=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_not_contains "$redacted" "sk_live_abc123" \
        "YAML-style value should be redacted" || return 1
}

# ============================================================================
# MANIFEST.json tests
# ============================================================================

test_manifest_updated_with_artifact() {
    send_write "/tmp/build.sh" "#!/bin/bash\necho hello" > /dev/null
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local count
    count=$(echo "$manifest" | jq length)
    assert_eq "1" "$count" "MANIFEST should have 1 entry" || return 1

    local filename
    filename=$(echo "$manifest" | jq -r '.[0].filename')
    assert_eq "build.sh" "$filename" "Filename should be build.sh" || return 1
}

test_manifest_records_original_path() {
    send_write "/home/user/scripts/deploy.py" "print('deploying')" > /dev/null
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local original_path
    original_path=$(echo "$manifest" | jq -r '.[0].original_path')
    assert_eq "/home/user/scripts/deploy.py" "$original_path" \
        "Should record original path" || return 1
}

test_manifest_has_timestamp() {
    send_write "/tmp/test.sh" "echo hi" > /dev/null
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local timestamp
    timestamp=$(echo "$manifest" | jq -r '.[0].timestamp')
    # Should be ISO 8601 format
    if ! [[ "$timestamp" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]; then
        echo "  FAIL: Timestamp should be ISO 8601 format, got: $timestamp"
        return 1
    fi
}

test_manifest_lists_secret_names() {
    local content='API_KEY=abc123
SECRET_TOKEN=xyz789'
    send_write "/tmp/secrets.env" "$content" > /dev/null
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local secrets
    secrets=$(echo "$manifest" | jq -r '.[0].secrets // [] | join(",")')
    assert_output_contains "$secrets" "API_KEY" "Should list API_KEY in secrets" || return 1
    assert_output_contains "$secrets" "SECRET_TOKEN" "Should list SECRET_TOKEN in secrets" || return 1
}

test_manifest_accumulates_entries() {
    send_write "/tmp/a.sh" "echo a" > /dev/null
    send_write "/tmp/b.py" "print('b')" > /dev/null
    send_write "/tmp/c.yaml" "key: c" > /dev/null
    local manifest
    manifest=$(cat "$CLAUDE_ARTIFACT_DIR/MANIFEST.json")
    local count
    count=$(echo "$manifest" | jq length)
    assert_eq "3" "$count" "MANIFEST should have 3 entries" || return 1
}

# ============================================================================
# Session log tests
# ============================================================================

test_artifact_logged_to_session_log() {
    send_write "/tmp/build.sh" "#!/bin/bash" > /dev/null
    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "Artifact captured: build.sh" \
        "Session log should record artifact capture" || return 1
}

test_secret_count_logged() {
    local content='API_KEY=abc123
SECRET_TOKEN=xyz789'
    send_write "/tmp/secrets.env" "$content" > /dev/null
    assert_file_contains "$CLAUDE_SESSION_META_DIR/logs/session.log" "secrets stored" \
        "Session log should mention secrets stored" || return 1
}

# ============================================================================
# Comments and edge cases
# ============================================================================

test_comments_not_treated_as_secrets() {
    local content='# API_KEY=this_is_a_comment
APP_NAME=myapp'
    local output
    output=$(send_write "/tmp/config.sh" "$content")
    local returned_content
    returned_content=$(echo "$output" | jq -r '.updatedInput.content')
    assert_output_contains "$returned_content" "# API_KEY=this_is_a_comment" \
        "Commented-out lines should not be redacted" || return 1
}

test_all_tracked_extensions() {
    # Verify all documented extensions are tracked
    for ext in sh bash zsh py js ts rb pl conf config json yaml yml toml ini env; do
        local output
        output=$(send_write "/tmp/test.$ext" "content")
        if ! echo "$output" | jq -e '.updatedInput.file_path' > /dev/null 2>&1; then
            echo "  FAIL: .$ext should be tracked as artifact"
            return 1
        fi
    done
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs artifact-tracker tests"
echo "========================="
echo ""

# Passthrough
run_test test_non_write_tool_passes_through
run_test test_outside_session_passes_through
run_test test_non_artifact_extension_passes_through

# Path rewriting
run_test test_sh_file_redirected_to_artifacts
run_test test_py_file_redirected_to_artifacts
run_test test_json_file_redirected_to_artifacts
run_test test_yaml_file_redirected_to_artifacts
run_test test_env_file_redirected_to_artifacts

# Duplicate handling
run_test test_duplicate_filename_gets_counter
run_test test_multiple_duplicates_increment

# Sensitive detection
run_test test_env_extension_detected_as_sensitive
run_test test_filename_with_secret_detected
run_test test_filename_with_key_detected
run_test test_normal_script_not_flagged

# Content-based detection
run_test test_api_key_in_content_detected
run_test test_secret_token_in_content_detected
run_test test_password_in_content_detected
run_test test_non_sensitive_content_not_redacted

# Redaction formats
run_test test_redacts_unquoted_value
run_test test_redacts_double_quoted_value
run_test test_redacts_single_quoted_value
run_test test_redacts_yaml_style_value

# MANIFEST.json
run_test test_manifest_updated_with_artifact
run_test test_manifest_records_original_path
run_test test_manifest_has_timestamp
run_test test_manifest_lists_secret_names
run_test test_manifest_accumulates_entries

# Session log
run_test test_artifact_logged_to_session_log
run_test test_secret_count_logged

# Edge cases
run_test test_comments_not_treated_as_secrets
run_test test_all_tracked_extensions

report_results
