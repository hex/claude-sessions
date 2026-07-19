#!/usr/bin/env bash
# ABOUTME: Tests for cs -remove/-rm: multi-name removal, per-name confirms,
# ABOUTME: fail-fast on unknown names, and the usage error with no name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

test_remove_multiple_names_each_confirmed() {
    create_test_session r1 >/dev/null
    create_test_session r2 >/dev/null
    printf 'y\ny\n' | "$CS_BIN" -rm r1 r2 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r1" ] || { echo "  r1 survived"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r2" ] || { echo "  r2 survived"; return 1; }
}

test_remove_decline_skips_that_session_only() {
    create_test_session r3 >/dev/null
    create_test_session r4 >/dev/null
    printf 'n\ny\n' | "$CS_BIN" -rm r3 r4 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r3" ] || { echo "  declined r3 was removed"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r4" ] || { echo "  r4 survived"; return 1; }
}

test_remove_single_name_still_works() {
    create_test_session r5 >/dev/null
    printf 'y\n' | "$CS_BIN" -rm r5 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r5" ] || { echo "  r5 survived"; return 1; }
}

test_remove_no_name_errors() {
    ! "$CS_BIN" -rm >/dev/null 2>&1 || return 1
}

test_remove_unknown_name_fails_fast() {
    create_test_session r6 >/dev/null
    ! printf 'y\n' | "$CS_BIN" -rm nosuch r6 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r6" ] || { echo "  fail-fast still removed a later name"; return 1; }
}

test_remove_empty_name_rejected_before_any_deletion() {
    create_test_session r7 >/dev/null
    ! printf 'y\ny\n' | "$CS_BIN" -rm r7 "" >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT" ] || { echo "  sessions root deleted"; return 1; }
    [ -d "$CS_SESSIONS_ROOT/r7" ] || { echo "  r7 removed despite invalid list"; return 1; }
    ! "$CS_BIN" -rm "" >/dev/null 2>&1 || return 1
}

test_remove_refuses_live_session_without_force() {
    create_test_session live1 >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/live1/.cs/session.lock"

    local out rc=0
    out=$(printf 'y\n' | "$CS_BIN" -rm live1 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: live session must refuse removal without --force"
        return 1
    fi
    assert_output_contains "$out" "--force" "refusal names the override" || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; return 1; }
    [ -d "$CS_SESSIONS_ROOT/live1" ] || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: refused removal still deleted the session"; return 1; }

    printf 'y\n' | "$CS_BIN" -rm live1 --force >/dev/null 2>&1
    rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    [ "$rc" -eq 0 ] || { echo "  FAIL: --force should remove a live session"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/live1" ] || { echo "  FAIL: --force did not remove"; return 1; }
}

test_remove_discards_pending_spawn_seeds() {
    create_test_session seeded >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\ndo a task\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale"
    printf 'other\n' > "$CS_SESSIONS_ROOT/.spawn/other.seed"

    printf 'n\n' | "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  declined removal still discarded the seed"; return 1; }

    printf 'y\n' | "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  seed survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale" ] || { echo "  stale seed survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/other.seed" ] || { echo "  another session's seed was deleted"; return 1; }
}

test_remove_worktree_session_discards_seeds() {
    local base="$CS_SESSIONS_ROOT/wbase"
    create_test_session wbase >/dev/null
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md
    git -C "$base" -c user.email=t@t -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$CS_SESSIONS_ROOT/wbase@t" -b cs/t
    mkdir -p "$CS_SESSIONS_ROOT/wbase@t/.cs/local"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed"

    printf 'y\n' | "$CS_BIN" -rm "wbase@t" >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/wbase@t" ] || { echo "  worktree session survived"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed" ] || { echo "  worktree seed survived removal"; return 1; }
}

test_remove_allows_heartbeat_only_session_without_force() {
    # The live guard is strict PID-lock by decision: a heartbeat-live but
    # unlocked session (fresh context-pct, no session.lock) is still removable
    # without --force. cs -live shows it; cs -rm does not refuse it.
    create_test_session breathing >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/breathing/.cs/local"
    : > "$CS_SESSIONS_ROOT/breathing/.cs/local/context-pct"
    printf 'y\n' | "$CS_BIN" -rm breathing >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/breathing" ] || { echo "  heartbeat-only session wrongly refused rm"; return 1; }
}

run_test test_remove_empty_name_rejected_before_any_deletion
run_test test_remove_refuses_live_session_without_force
run_test test_remove_allows_heartbeat_only_session_without_force
run_test test_remove_discards_pending_spawn_seeds
run_test test_remove_worktree_session_discards_seeds
run_test test_remove_multiple_names_each_confirmed
run_test test_remove_decline_skips_that_session_only
run_test test_remove_single_name_still_works
run_test test_remove_no_name_errors
run_test test_remove_unknown_name_fails_fast

report_results
