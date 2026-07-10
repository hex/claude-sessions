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
# Create a session whose lock holds a dead pid (started, then killed+reaped).
make_dead_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
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

run_test test_live_includes_live_excludes_dead
run_test test_live_shows_presence_status
run_test test_live_falls_back_to_readme_objective
run_test test_live_filters_readme_placeholder
run_test test_live_marks_current_session
run_test test_live_marks_current_via_symlink
run_test test_live_actor_is_sessions_own_not_invoker
run_test test_live_uptime_from_lock_mtime
run_test test_live_empty_root_message_and_exit0
run_test test_live_none_message_when_no_live

report_results
