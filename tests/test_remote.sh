#!/usr/bin/env bash
# ABOUTME: Tests for cs remote session features (host registry, stubs, connection, --move-to)
# ABOUTME: Validates remote host management, session stubs, host:session parsing, and list display

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override setup to add remote-specific env vars
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_TEST_DRY_RUN=1       # Prevent actual remote connections
    mkdir -p "$CS_SESSIONS_ROOT"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TEST_DRY_RUN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
}

# ============================================================================
# Registry Tests
# ============================================================================

test_remote_add_host() {
    local output
    output=$("$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/.remotes" ".remotes file should be created" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=hex@mac-mini.local" \
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
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1
    "$CS_BIN" -remote add myserver hex@new-host.local 2>&1

    local count
    count=$(grep -c "myserver=" "$CS_SESSIONS_ROOT/.remotes")
    assert_eq "1" "$count" "Should have exactly one entry for myserver" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/.remotes" "myserver=hex@new-host.local" \
        "Should have updated host" || return 1
}

test_remote_list_hosts() {
    "$CS_BIN" -remote add server1 hex@host1.local 2>&1
    "$CS_BIN" -remote add server2 bob@host2.local 2>&1

    local output
    output=$("$CS_BIN" -remote list 2>&1)

    assert_output_contains "$output" "server1" "Should list server1" || return 1
    assert_output_contains "$output" "hex@host1.local" "Should show host1 address" || return 1
    assert_output_contains "$output" "server2" "Should list server2" || return 1
    assert_output_contains "$output" "bob@host2.local" "Should show host2 address" || return 1
}

test_remote_list_empty() {
    local output
    output=$("$CS_BIN" -remote list 2>&1)

    assert_output_contains "$output" "No remote hosts" "Should indicate no hosts registered" || return 1
}

test_remote_remove_host() {
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1
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
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1

    local output
    output=$("$CS_BIN" -remote ls 2>&1)

    assert_output_contains "$output" "myserver" "ls alias should work like list" || return 1
}

test_remote_rm_alias() {
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1
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
    output=$("$CS_BIN" my-session --on hex@mac-mini.local 2>&1)

    local session_dir="$CS_SESSIONS_ROOT/my-session"
    assert_exists "$session_dir/.cs/remote.conf" "remote.conf should be created" || return 1
    assert_file_contains "$session_dir/.cs/remote.conf" "host=hex@mac-mini.local" \
        "remote.conf should contain host" || return 1
}

test_on_flag_with_registered_name() {
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1

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
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    if output=$("$CS_BIN" my-session --on hex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for existing local session"
        return 1
    fi

    assert_output_contains "$output" "exists locally" "Error should mention local session" || return 1
}

test_on_flag_same_host_reconnects() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session --on hex@mac-mini.local 2>&1)

    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=hex@mac-mini.local" \
        "remote.conf should still have same host" || return 1
}

test_on_flag_different_host_warns_and_updates() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@old-host.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session --on hex@new-host.local 2>&1)

    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=hex@new-host.local" \
        "remote.conf should be updated to new host" || return 1
}

# ============================================================================
# Host:Session Parsing Tests
# ============================================================================

test_host_session_syntax_creates_stub() {
    local output
    output=$("$CS_BIN" "hex@mac-mini.local:my-session" 2>&1)

    local session_dir="$CS_SESSIONS_ROOT/my-session"
    assert_exists "$session_dir/.cs/remote.conf" "remote.conf should be created" || return 1
    assert_file_contains "$session_dir/.cs/remote.conf" "host=hex@mac-mini.local" \
        "remote.conf should contain parsed host" || return 1
}

test_host_session_syntax_remembered() {
    "$CS_BIN" "hex@mac-mini.local:my-session" 2>&1

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "hex@mac-mini.local" \
        "Should connect to remembered host" || return 1
}

# ============================================================================
# Remote Detection Tests
# ============================================================================

test_remote_session_detected() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "hex@mac-mini.local" \
        "Should detect remote session and show host" || return 1
}

test_local_session_not_detected_as_remote() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    touch "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    if echo "$output" | grep -q "Connecting to"; then
        echo "  FAIL: Local session should not trigger remote connection"
        return 1
    fi
}

# ============================================================================
# Connection Command Tests (dry run)
# ============================================================================

test_connection_prefers_et() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

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
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    echo '#!/bin/sh' > "$fake_bin/ssh"
    chmod +x "$fake_bin/ssh"

    local output
    output=$(PATH="$fake_bin:/usr/bin:/bin" "$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "ssh" "Should fall back to ssh" || return 1
}

test_connection_uses_tmux() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "tmux" "Connection should use tmux" || return 1
}

test_et_uses_command_flag() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    echo '#!/bin/sh' > "$fake_bin/et"
    chmod +x "$fake_bin/et"
    export PATH="$fake_bin:$PATH"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "et hex@mac-mini.local -c" \
        "et should use -c flag for command" || return 1
}

test_ssh_uses_tty_flag() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    echo '#!/bin/sh' > "$fake_bin/ssh"
    chmod +x "$fake_bin/ssh"

    local output
    output=$(PATH="$fake_bin:/usr/bin:/bin" "$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "ssh hex@mac-mini.local -t" \
        "ssh should use -t flag for TTY" || return 1
}

test_connection_banner_shows_info() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" "my-session" "Banner should show session name" || return 1
    assert_output_contains "$output" "hex@mac-mini.local" "Banner should show host" || return 1
}

test_connection_uses_absolute_cs_path() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    output=$("$CS_BIN" my-session 2>&1)

    assert_output_contains "$output" ".local/bin/cs my-session" \
        "Remote command should use absolute path to cs" || return 1
}

# ============================================================================
# Blocking Tests (remote sessions can't use -sync/-secrets)
# ============================================================================

test_sync_blocked_on_remote_session() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    if output=$("$CS_BIN" my-session -sync push 2>&1); then
        echo "  FAIL: -sync should fail on remote session"
        return 1
    fi

    assert_output_contains "$output" "remote session" "Error should mention remote session" || return 1
}

test_secrets_blocked_on_remote_session() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

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
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "auto_sync=on" > "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf"
    echo "some work" > "$CS_SESSIONS_ROOT/my-session/notes.txt"

    local output
    output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" \
        "remote.conf should be created after move" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "host=hex@mac-mini.local" \
        "remote.conf should contain target host" || return 1
}

test_move_to_nonexistent_session_errors() {
    local output
    if output=$("$CS_BIN" nonexistent --move-to hex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for nonexistent session"
        return 1
    fi

    assert_output_contains "$output" "not found\|does not exist\|No.*session" \
        "Error should indicate session doesn't exist" || return 1
}

test_move_to_already_remote_errors() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@other-host.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

    local output
    if output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1); then
        echo "  FAIL: Should have failed for already-remote session"
        return 1
    fi

    assert_output_contains "$output" "already remote" "Error should mention already remote" || return 1
}

test_move_to_with_registered_name() {
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    output=$("$CS_BIN" my-session --move-to myserver 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" \
        "remote.conf should be created" || return 1
}

test_move_to_shows_rsync_command() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local output
    output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1)

    assert_output_contains "$output" "rsync" "Should show rsync command in dry run" || return 1
}

test_move_to_queries_remote_sessions_root() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"

    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/ssh" << 'SCRIPT'
#!/bin/sh
echo "/data/sessions"
SCRIPT
    chmod +x "$fake_bin/ssh"
    export PATH="$fake_bin:$PATH"

    local output
    output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1)

    assert_output_contains "$output" "/data/sessions/my-session" \
        "Should use remote CS_SESSIONS_ROOT in rsync destination" || return 1

    assert_file_contains "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" "root=/data/sessions" \
        "remote.conf should cache detected root" || return 1
}

test_move_to_cleans_local_files() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs/logs"
    echo "auto_sync=on" > "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf"
    echo "some work" > "$CS_SESSIONS_ROOT/my-session/notes.txt"
    echo "# My Project" > "$CS_SESSIONS_ROOT/my-session/CLAUDE.md"

    local output
    output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1)

    assert_exists "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf" \
        "remote.conf should survive cleanup" || return 1

    if [[ -f "$CS_SESSIONS_ROOT/my-session/notes.txt" ]]; then
        echo "  FAIL: notes.txt should be removed after move"
        return 1
    fi
    if [[ -f "$CS_SESSIONS_ROOT/my-session/CLAUDE.md" ]]; then
        echo "  FAIL: CLAUDE.md should be removed after move"
        return 1
    fi
    if [[ -f "$CS_SESSIONS_ROOT/my-session/.cs/sync.conf" ]]; then
        echo "  FAIL: sync.conf should be removed after move"
        return 1
    fi
}

test_move_to_preserves_adopted_session_files() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir/.cs"
    echo "important work" > "$project_dir/main.py"
    ln -s "$project_dir" "$CS_SESSIONS_ROOT/my-session"

    local output
    output=$("$CS_BIN" my-session --move-to hex@mac-mini.local 2>&1)

    assert_exists "$project_dir/.cs/remote.conf" \
        "remote.conf should be created in adopted session" || return 1

    if [[ ! -f "$project_dir/main.py" ]]; then
        echo "  FAIL: adopted project files should be preserved"
        return 1
    fi
}

# ============================================================================
# List Sessions Tests
# ============================================================================

test_list_shows_remote_location() {
    mkdir -p "$CS_SESSIONS_ROOT/remote-session/.cs/logs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/remote-session/.cs/remote.conf"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/remote-session/.cs/logs/session.log"

    mkdir -p "$CS_SESSIONS_ROOT/local-session/.cs/logs"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/local-session/.cs/logs/session.log"

    local output
    output=$("$CS_BIN" -ls 2>&1)

    assert_output_contains "$output" "LOCATION" "Header should include LOCATION column" || return 1
    assert_output_contains "$output" "hex@mac-mini.local" "Should show remote host for remote session" || return 1
}

test_list_shows_registered_name_for_remote() {
    "$CS_BIN" -remote add myserver hex@mac-mini.local 2>&1

    mkdir -p "$CS_SESSIONS_ROOT/remote-session/.cs/logs"
    echo "host=myserver" > "$CS_SESSIONS_ROOT/remote-session/.cs/remote.conf"
    echo "Started: 2026-01-01 12:00:00" > "$CS_SESSIONS_ROOT/remote-session/.cs/logs/session.log"

    local output
    output=$("$CS_BIN" -ls 2>&1)

    assert_output_contains "$output" "myserver" "Should show registered name" || return 1
}

test_remove_remote_session_removes_stub() {
    mkdir -p "$CS_SESSIONS_ROOT/my-session/.cs"
    echo "host=hex@mac-mini.local" > "$CS_SESSIONS_ROOT/my-session/.cs/remote.conf"

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
run_test test_et_uses_command_flag
run_test test_ssh_uses_tty_flag
run_test test_connection_banner_shows_info
run_test test_connection_uses_absolute_cs_path

# Blocking
run_test test_sync_blocked_on_remote_session
run_test test_secrets_blocked_on_remote_session

# --move-to
run_test test_move_to_creates_stub
run_test test_move_to_nonexistent_session_errors
run_test test_move_to_already_remote_errors
run_test test_move_to_with_registered_name
run_test test_move_to_shows_rsync_command
run_test test_move_to_queries_remote_sessions_root
run_test test_move_to_cleans_local_files
run_test test_move_to_preserves_adopted_session_files

# List sessions
run_test test_list_shows_remote_location
run_test test_list_shows_registered_name_for_remote
run_test test_remove_remote_session_removes_stub

report_results
