#!/usr/bin/env bash
# ABOUTME: Tests for cs remote session features (host registry, stubs, connection, --move-to)
# ABOUTME: Validates remote host management, session stubs, host:session parsing, and list display

set -euo pipefail

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CS_BIN="$SCRIPT_DIR/../bin/cs"
TEST_TMPDIR=""

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"  # Stub out claude so it doesn't launch
    export CS_TEST_DRY_RUN=1       # Prevent actual remote connections
    mkdir -p "$CS_SESSIONS_ROOT"
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TEST_DRY_RUN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_exists() {
    local path="$1" msg="${2:-$path should exist}"
    if [ ! -e "$path" ]; then
        echo "  FAIL: $msg (path does not exist: $path)"
        return 1
    fi
}

assert_not_exists() {
    local path="$1" msg="${2:-$path should not exist}"
    if [ -e "$path" ]; then
        echo "  FAIL: $msg (path exists: $path)"
        return 1
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        if [ -f "$file" ]; then
            echo "    file contents: $(cat "$file")"
        else
            echo "    file does not exist"
        fi
        return 1
    fi
}

assert_file_not_contains() {
    local file="$1" pattern="$2" msg="${3:-$file should not contain '$pattern'}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        return 1
    fi
}

assert_output_contains() {
    local output="$1" pattern="$2" msg="${3:-output should contain '$pattern'}"
    if ! echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $msg"
        echo "    output: $output"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    setup
    if "$test_name" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
    teardown
}

# ============================================================================
# Registry Tests
# ============================================================================

test_remote_add_host() {
    local output
    output=$("$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/.remotes" ".remotes file should be created" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=alex@mac-mini.local" \
        "Should store host entry" || return 1
}

test_remote_add_requires_at_sign() {
    local output
    if output=$("$CS_BIN" -remote add myserver "just-a-hostname" 2>&1); then
        echo "  FAIL: Should have failed for host without @"
        return 1
    fi

    assert_output_contains "$output" "user@hostname" "Error should mention user@hostname format" || return 1
}

test_remote_add_duplicate_updates() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1
    "$CS_BIN" -remote add myserver alex@new-host.local 2>&1

    # Should have updated, not duplicated
    local count
    count=$(grep -c "myserver=" "$CS_SESSIONS_ROOT/.remotes")
    assert_eq "1" "$count" "Should have exactly one entry for myserver" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=alex@new-host.local" \
        "Should have updated host" || return 1
}

test_remote_list_hosts() {
    "$CS_BIN" -remote add server1 alex@host1.local 2>&1
    "$CS_BIN" -remote add server2 bob@host2.local 2>&1

    local output
    output=$("$CS_BIN" -remote list 2>&1)

    assert_output_contains "$output" "server1" "Should list server1" || return 1
    assert_output_contains "$output" "alex@host1.local" "Should show host1 address" || return 1
    assert_output_contains "$output" "server2" "Should list server2" || return 1
    assert_output_contains "$output" "bob@host2.local" "Should show host2 address" || return 1
}

test_remote_list_empty() {
    local output
    output=$("$CS_BIN" -remote list 2>&1)

    assert_output_contains "$output" "No remote hosts" "Should indicate no hosts registered" || return 1
}

test_remote_remove_host() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1
    "$CS_BIN" -remote remove myserver 2>&1

    assert_file_not_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=" \
        "Should have removed host entry" || return 1
}

test_remote_remove_nonexistent() {
    local output
    if output=$("$CS_BIN" -remote remove nonexistent 2>&1); then
        echo "  FAIL: Should have failed for nonexistent host"
        return 1
    fi

    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

test_remote_ls_alias() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1

    local output
    output=$("$CS_BIN" -remote ls 2>&1)

    assert_output_contains "$output" "myserver" "ls alias should work like list" || return 1
}

test_remote_rm_alias() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1
    "$CS_BIN" -remote rm myserver 2>&1

    assert_file_not_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=" \
        "rm alias should work like remove" || return 1
}

test_remote_add_requires_name_and_host() {
    local output
    if output=$("$CS_BIN" -remote add 2>&1); then
        echo "  FAIL: Should have failed without arguments"
        return 1
    fi

    assert_output_contains "$output" "Usage" "Error should show usage" || return 1
}

# ============================================================================
# Stub Creation Tests
# ============================================================================

test_on_flag_creates_stub() {
    local output
    output=$("$CS_BIN" my-session --on alex@mac-mini.local 2>&1)

    local session_dir="$CS_SESSIONS_ROOT/my-session"
    assert_exists "$session_dir/.cs/remote.conf" "remote.conf should be created" || return 1
    assert_file_contains "$session_dir/.cs/remote.conf" "host=alex@mac-mini.local" \
        "remote.conf should contain host" || return 1
}

test_on_flag_with_registered_name() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1

    local output
    output=$("$CS_BIN" my-session --on myserver 2>&1)

    local session_dir="$CS_SESSIONS_ROOT/my-session"
    assert_exists "$session_dir/.cs/remote.conf" "remote.conf should be created" || return 1
    assert_file_contains "$session_dir/.cs/remote.conf" "host=myserver" \
        "remote.conf should store registered name" || return 1
}

test_on_flag_with_unregistered_name_errors() {
    local output
    if output=$("$CS_BIN" my-session --on bogusname 2>&1); then
        echo "  FAIL: Should have failed for unregistered name without @"
        return 1
    fi

    assert_output_contains "$output" "Register" "Error should suggest registering" || return 1
}

test_on_flag_with_existing_local_session_errors() {
    # Create a local session first
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    if output=$("$CS_BIN" my-session --on alex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for existing local session"
        return 1
    fi

    assert_output_contains "$output" "exists locally" "Error should mention local session" || return 1
}

test_on_flag_same_host_reconnects() {
    # Create a remote stub
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session --on alex@mac-mini.local 2>&1)

    # Should succeed (reconnect)
    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=alex@mac-mini.local" \
        "remote.conf should still have same host" || return 1
}

test_on_flag_different_host_warns_and_updates() {
    # Create a remote stub pointing to old host
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@old-host.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session --on alex@new-host.local 2>&1)

    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=alex@new-host.local" \
        "remote.conf should be updated to new host" || return 1
}

# ============================================================================
# Host:Session Parsing Tests
# ============================================================================

test_host_session_syntax_creates_stub() {
    local output
    output=$("$CS_BIN" "alex@mac-mini.local:my-session" 2>&1)

    local session_dir="$CS_SESSIONS_ROOT/my-session"
    assert_exists "$session_dir/.cs/remote.conf" "remote.conf should be created" || return 1
    assert_file_contains "$session_dir/.cs/remote.conf" "host=alex@mac-mini.local" \
        "remote.conf should contain parsed host" || return 1
}

test_host_session_syntax_remembered() {
    # First connection via host:session
    "$CS_BIN" "alex@mac-mini.local:my-session" 2>&1

    # Second connection via just session name should detect remote
    local output
    output=$("$CS_BIN" my-session 2>&1)

    # Should attempt remote connection (dry run shows the command)
    assert_output_contains "$output" "alex@mac-mini.local" \
        "Should connect to remembered host" || return 1
}

# ============================================================================
# Remote Detection Tests
# ============================================================================

test_remote_session_detected() {
    # Create a remote stub
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    # In dry run mode, should show the connection command
    assert_output_contains "$output" "alex@mac-mini.local" \
        "Should detect remote session and show host" || return 1
}

test_local_session_not_detected_as_remote() {
    # Create a normal local session (no remote.conf)
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    touch "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf"

    # This will try to launch claude (stubbed as echo), not connect remotely
    local output
    output=$("$CS_BIN" my-session 2>&1)

    # Should NOT contain remote connection indicators
    if echo "$output" | grep -q "Connecting to"; then
        echo "  FAIL: Local session should not trigger remote connection"
        return 1
    fi
}

# ============================================================================
# Connection Command Tests (dry run)
# ============================================================================

test_connection_prefers_et() {
    # Create a remote stub
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    # Create a fake et binary
    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    echo '#!/bin/sh' > "$fake_bin/et"
    chmod +x "$fake_bin/et"
    export PATH="$fake_bin:$PATH"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "et" "Should use et when available" || return 1
}

test_connection_falls_back_to_ssh() {
    # Create a remote stub
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    # Ensure et is not available (use a restricted PATH)
    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    # Provide ssh but not et
    echo '#!/bin/sh' > "$fake_bin/ssh"
    chmod +x "$fake_bin/ssh"

    # Override PATH to exclude et but include ssh and basic tools
    local output
    output=$(PATH="$fake_bin:/usr/bin:/bin" "$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "ssh" "Should fall back to ssh" || return 1
}

test_connection_uses_tmux() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "tmux" "Connection should use tmux" || return 1
}

test_connection_banner_shows_info() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "my-session" "Banner should show session name" || return 1
    assert_output_contains "$output" "alex@mac-mini.local" "Banner should show host" || return 1
}

# ============================================================================
# Blocking Tests (remote sessions can't use -sync/-secrets)
# ============================================================================

test_sync_blocked_on_remote_session() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    if output=$("$CS_BIN" my-session -sync push 2>&1); then
        echo "  FAIL: -sync should fail on remote session"
        return 1
    fi

    assert_output_contains "$output" "remote session" "Error should mention remote session" || return 1
}

test_secrets_blocked_on_remote_session() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    if output=$("$CS_BIN" my-session -secrets list 2>&1); then
        echo "  FAIL: -secrets should fail on remote session"
        return 1
    fi

    assert_output_contains "$output" "remote session" "Error should mention remote session" || return 1
}

# ============================================================================
# --move-to Tests
# ============================================================================

test_move_to_creates_stub() {
    # Create a local session with some content
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "auto_sync=on" > "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf"
    echo "some work" > "$CS_SESSIONS_ROOT/my-session/notes.txt"

    local output
    output=$("$CS_BIN" my-session --move-to alex@mac-mini.local 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" \
        "remote.conf should be created after move" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=alex@mac-mini.local" \
        "remote.conf should contain target host" || return 1
}

test_move_to_nonexistent_session_errors() {
    local output
    if output=$("$CS_BIN" nonexistent --move-to alex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for nonexistent session"
        return 1
    fi

    # Should error about session not existing
    assert_output_contains "$output" "not found\|does not exist\|No.*session" \
        "Error should indicate session doesn't exist" || return 1
}

test_move_to_already_remote_errors() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@other-host.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    if output=$("$CS_BIN" my-session --move-to alex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for already-remote session"
        return 1
    fi

    assert_output_contains "$output" "already remote" "Error should mention already remote" || return 1
}

test_move_to_with_registered_name() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    output=$("$CS_BIN" my-session --move-to myserver 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" \
        "remote.conf should be created" || return 1
}

test_move_to_shows_rsync_command() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    output=$("$CS_BIN" my-session --move-to alex@mac-mini.local 2>&1)

    assert_output_contains "$output" "rsync" "Should show rsync command in dry run" || return 1
}

# ============================================================================
# List Sessions Tests
# ============================================================================

test_list_shows_remote_location() {
    # Create a remote session
    mkdir -p "$CS_SESSIONS_ROOT/remote-session/.cs/logs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/remote-session/.cs/remote.conf"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/remote-session/.cs/logs/session.log"

    # Create a local session
    mkdir -p "$CS_SESSIONS_ROOT/local-session/.cs/logs"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/local-session/.cs/logs/session.log"

    local output
    output=$("$CS_BIN" -ls 2>&1)

    assert_output_contains "$output" "LOCATION" "Header should include LOCATION column" || return 1
    assert_output_contains "$output" "alex@mac-mini.local" "Should show remote host for remote session" || return 1
}

test_list_shows_registered_name_for_remote() {
    "$CS_BIN" -remote add myserver alex@mac-mini.local 2>&1

    mkdir -p "$CS_SESSIONS_ROOT/remote-session/.cs/logs"
    echo "host=myserver" > "$CS_SESSIONS_ROOT/remote-session/.cs/remote.conf"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/remote-session/.cs/logs/session.log"

    local output
    output=$("$CS_BIN" -ls 2>&1)

    assert_output_contains "$output" "myserver" "Should show registered name" || return 1
}

test_remove_remote_session_removes_stub() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=alex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    echo "y" | "$CS_BIN" -rm my-session 2>&1

    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "Session stub should be removed" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs remote session tests"
echo "======================="
echo ""

# Registry
run_test test_remote_add_host
run_test test_remote_add_requires_at_sign
run_test test_remote_add_duplicate_updates
run_test test_remote_list_hosts
run_test test_remote_list_empty
run_test test_remote_remove_host
run_test test_remote_remove_nonexistent
run_test test_remote_ls_alias
run_test test_remote_rm_alias
run_test test_remote_add_requires_name_and_host

# Stub creation
run_test test_on_flag_creates_stub
run_test test_on_flag_with_registered_name
run_test test_on_flag_with_unregistered_name_errors
run_test test_on_flag_with_existing_local_session_errors
run_test test_on_flag_same_host_reconnects
run_test test_on_flag_different_host_warns_and_updates

# Host:session parsing
run_test test_host_session_syntax_creates_stub
run_test test_host_session_syntax_remembered

# Remote detection
run_test test_remote_session_detected
run_test test_local_session_not_detected_as_remote

# Connection command (dry run)
run_test test_connection_prefers_et
run_test test_connection_falls_back_to_ssh
run_test test_connection_uses_tmux
run_test test_connection_banner_shows_info

# Blocking
run_test test_sync_blocked_on_remote_session
run_test test_secrets_blocked_on_remote_session

# --move-to
run_test test_move_to_creates_stub
run_test test_move_to_nonexistent_session_errors
run_test test_move_to_already_remote_errors
run_test test_move_to_with_registered_name
run_test test_move_to_shows_rsync_command

# List sessions
run_test test_list_shows_remote_location
run_test test_list_shows_registered_name_for_remote
run_test test_remove_remote_session_removes_stub

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo ""
