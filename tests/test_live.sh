#!/usr/bin/env bash
# ABOUTME: Tests for the cs -live verb (list live sessions on this machine).
# ABOUTME: Covers live/dead filtering, actor/uptime/status columns, current marker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_ACTOR 2>/dev/null || true
}
teardown() {
    # Reap sleepers by reading PIDs from the lock files the fixtures wrote (a
    # subshell-safe alternative to a shell array), then drop the temp tree.
    local lf pid
    if [ -n "${CS_SESSIONS_ROOT:-}" ]; then
        for lf in "$CS_SESSIONS_ROOT"/*/.cs/session.lock; do
            [ -f "$lf" ] || continue
            pid="$(cat "$lf" 2>/dev/null || true)"
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Create a live session: real .cs/, lock holding a RUNNING pid. NEVER call this
# via $(...) — the backgrounded sleep inherits the command-substitution's pipe
# write end, so the substitution would block ~300s. Call it directly; the path
# is deterministic ($CS_SESSIONS_ROOT/<name>).
make_live_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}
# Write the Claude Code session record for an already-created session, keyed to
# the pid in that session's lock. The schema and the UTC process-start format
# were both read off live records Claude Code had written; a caller in any other
# zone that formats the time locally will not match what cs reads back. Pass a
# third argument to override the start time and stand in for a recycled pid.
make_registry_record() {  # name, status, [procStart]
    local sdir="$CS_SESSIONS_ROOT/$1" pid start
    pid="$(cat "$sdir/.cs/session.lock")"
    if [ $# -ge 3 ]; then
        start="$3"
    else
        start="$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    fi
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    cat > "$CS_CLAUDE_DIR/sessions/$pid.json" <<EOF
{"pid": $pid, "name": "$1", "status": "$2", "procStart": "$start",
 "cwd": "$sdir", "peerProtocol": 1, "kind": "interactive",
 "messagingSocketPath": "/tmp/cc-socks/$pid.sock"}
EOF
}

# Create a session whose lock holds a dead pid (started, then killed+reaped).
make_dead_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}

# A session with no lock but a fresh statusline heartbeat (context-pct touched
# now): live to the DISPLAY surfaces, matching the TUI, though cs never locked it.
make_heartbeat_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    : > "$sdir/.cs/local/context-pct"   # mtime = now
}
# A session whose heartbeat has gone cold (context-pct older than the 900s window).
make_cold_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    : > "$sdir/.cs/local/context-pct"
    if ! touch -A -003000 "$sdir/.cs/local/context-pct" 2>/dev/null; then
        touch -d "30 minutes ago" "$sdir/.cs/local/context-pct" 2>/dev/null || true
    fi
}

test_live_includes_heartbeat_session() {
    make_heartbeat_session breathing
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "breathing" "heartbeat-live (unlocked) session listed" || return 1
}

test_live_excludes_cold_heartbeat_session() {
    make_cold_session gone-cold
    local out; out="$("$CS_BIN" -live 2>&1)"
    case "$out" in *gone-cold*) echo "  FAIL: cold-heartbeat session listed"; return 1;; esac
    return 0
}

test_live_includes_live_excludes_dead() {
    make_live_session alive-one >/dev/null
    make_dead_session dead-one >/dev/null
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alive-one" "live session listed" || return 1
    case "$out" in *dead-one*) echo "  FAIL: dead session listed"; return 1;; esac
    return 0
}

test_live_shows_presence_status() {
    make_live_session busy-one
    printf 'wiring the mailbox\n' > "$CS_SESSIONS_ROOT/busy-one/.cs/local/presence"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "wiring the mailbox" "status column shows presence" || return 1
}

test_live_falls_back_to_readme_objective() {
    make_live_session obj-one
    printf '# obj-one\n\n## Objective\n\nShip presence\n' > "$CS_SESSIONS_ROOT/obj-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "Ship presence" "status falls back to objective" || return 1
}

test_live_filters_readme_placeholder() {
    make_live_session ph-one
    printf '# ph-one\n\n## Objective\n\n[Describe what you are trying to accomplish]\n' > "$CS_SESSIONS_ROOT/ph-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    case "$out" in *Describe*) echo "  FAIL: placeholder shown as status"; return 1;; esac
    return 0
}

test_live_marks_current_session() {
    make_live_session mine >/dev/null
    export CLAUDE_SESSION_NAME="mine"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "(this session)" "current session marked" || return 1
    unset CLAUDE_SESSION_NAME
}

test_live_actor_is_sessions_own_not_invoker() {
    make_live_session actor-one
    printf 'alice@example.com\n' > "$CS_SESSIONS_ROOT/actor-one/.cs/local/identity"
    export CS_ACTOR="bob@invoker.com"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alice" "row shows the session's own actor" || return 1
    case "$out" in *bob*) echo "  FAIL: invoker CS_ACTOR leaked onto row"; return 1;; esac
    unset CS_ACTOR
}

test_live_none_message_when_no_live() {
    make_dead_session only-dead
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "No other live cs sessions" "prints the empty message" || return 1
}

test_live_marks_current_via_symlink() {
    # Reached through a symlink; the marker matches by CLAUDE_SESSION_NAME
    # (basename), not by resolved path, so the row is still marked.
    local target="$TEST_TMPDIR/real-target" p
    mkdir -p "$target/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$target/.cs/session.lock"
    ln -s "$target" "$CS_SESSIONS_ROOT/linked-one"
    export CLAUDE_SESSION_NAME="linked-one"
    export CLAUDE_SESSION_DIR="$target"   # resolved path, differs from the symlink path
    local out; out="$("$CS_BIN" -live 2>&1)"
    kill "$p" 2>/dev/null || true
    assert_output_contains "$out" "(this session)" "symlinked current session marked by name" || return 1
}

test_live_uptime_from_lock_mtime() {
    make_live_session up-one
    local lock="$CS_SESSIONS_ROOT/up-one/.cs/session.lock"
    # Back-date the lock ~2h. BSD: touch -A -HHMMSS; GNU: touch -d "2 hours ago".
    if ! touch -A -020000 "$lock" 2>/dev/null; then
        touch -d "2 hours ago" "$lock" 2>/dev/null || true
    fi
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "2h" "uptime reflects the lock mtime (~2h)" || return 1
}

test_live_empty_root_message_and_exit0() {
    rm -rf "$CS_SESSIONS_ROOT"   # exercise the [ ! -d "$SESSIONS_ROOT" ] branch
    local out rc
    out="$("$CS_BIN" -live 2>&1)"; rc=$?
    assert_output_contains "$out" "No other live cs sessions" "empty root prints the message" || return 1
    assert_eq "0" "$rc" "empty root exits 0" || return 1
}

test_live_shows_agent_status_from_registry() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session working
    make_registry_record working waiting
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "working.*waiting" "agent status read from the session registry" || return 1
}

test_live_gives_each_session_its_own_agent_status() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session one-busy
    make_registry_record one-busy busy
    make_live_session two-waiting
    make_registry_record two-waiting waiting
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "one-busy.*busy" "first session carries its own state" || return 1
    assert_output_contains "$out" "two-waiting.*waiting" "second session carries its own state" || return 1
    assert_output_not_contains "$out" "one-busy.*waiting" \
        "reading every record at once must not smear one session's state onto another" || return 1
}

test_live_survives_a_record_whose_pid_is_out_of_range() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session healthy
    make_registry_record healthy busy
    # A stale record naming a pid past the kernel's maximum: `ps -p` fails the
    # WHOLE list rather than skipping that one, so batching the lookup would
    # blank every other session's state over a single orphaned document.
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    printf '{"pid": 999999, "name": "ghost", "status": "busy", "procStart": "Mon Jan  1 00:00:00 2001"}\n' \
        > "$CS_CLAUDE_DIR/sessions/999999.json"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "healthy.*busy" \
        "one unusable record must not cost every other session its state" || return 1
}

test_live_ignores_record_with_no_start_time() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session unverifiable
    # A record carrying no start time cannot be told apart from one left by a
    # session whose pid has been reused, so it earns no state. The TUI reader
    # refuses it too; a wildcard here made the same record read one way in
    # cs -live and another in the TUI.
    make_registry_record unverifiable waiting ""
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "unverifiable" "the session is still listed" || return 1
    assert_output_not_contains "$out" "unverifiable.*waiting" \
        "a record with no start time must not be trusted" || return 1
}

test_live_ignores_record_whose_start_time_differs() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session recycled
    make_registry_record recycled waiting "Mon Jan  1 00:00:00 2001"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_not_contains "$out" "recycled.*waiting" \
        "record left by an exited session whose pid was reused is ignored" || return 1
}

run_test test_live_includes_heartbeat_session
run_test test_live_excludes_cold_heartbeat_session
run_test test_live_includes_live_excludes_dead
run_test test_live_shows_presence_status
run_test test_live_shows_agent_status_from_registry
run_test test_live_gives_each_session_its_own_agent_status
run_test test_live_ignores_record_whose_start_time_differs
run_test test_live_ignores_record_with_no_start_time
run_test test_live_survives_a_record_whose_pid_is_out_of_range
run_test test_live_falls_back_to_readme_objective
run_test test_live_filters_readme_placeholder
run_test test_live_marks_current_session
run_test test_live_marks_current_via_symlink
run_test test_live_actor_is_sessions_own_not_invoker
run_test test_live_uptime_from_lock_mtime
run_test test_live_empty_root_message_and_exit0
run_test test_live_none_message_when_no_live

report_results
