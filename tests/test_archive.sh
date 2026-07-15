#!/usr/bin/env bash
# ABOUTME: Tests for cs -archive/-unarchive: the tracked .cs/archived marker,
# ABOUTME: idempotency, the live-lock guard, and listing/search/launch effects

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# A minimal session dir with the frontmatter README the tag filter reads.
_archive_session() {  # name, tags_line ("" = default empty tags)
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    {
        echo "---"
        echo "status: active"
        echo "${2:-tags: []}"
        echo "---"
        echo ""
        echo "## Objective"
        echo "archive test session $1"
    } > "$dir/.cs/README.md"
}

test_archive_subcommand_exists() {
    local output
    output=$("$CS_BIN" -archive 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -archive should be a recognized verb" || return 1
    output=$("$CS_BIN" -unarchive 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -unarchive should be a recognized verb" || return 1
}

test_archive_roundtrip_and_marker_content() {
    _archive_session "rt"
    "$CS_BIN" -archive rt >/dev/null 2>&1 || { echo "  FAIL: archive exited non-zero"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/rt/.cs/archived" ] || { echo "  FAIL: marker not created"; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/rt/.cs/archived" "archived: " "marker carries the advisory prefix" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/rt/.cs/archived" " by " "marker names an actor" || return 1
    "$CS_BIN" -unarchive rt >/dev/null 2>&1 || { echo "  FAIL: unarchive exited non-zero"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/rt/.cs/archived" ] || { echo "  FAIL: marker not removed"; return 1; }
}

test_archive_is_idempotent() {
    _archive_session "idem"
    "$CS_BIN" -archive idem >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -archive idem 2>&1) || { echo "  FAIL: re-archive must exit 0"; return 1; }
    assert_output_contains "$output" "Already archived" "re-archive says so" || return 1
    "$CS_BIN" -unarchive idem >/dev/null 2>&1 || return 1
    output=$("$CS_BIN" -unarchive idem 2>&1) || { echo "  FAIL: re-unarchive must exit 0"; return 1; }
    assert_output_contains "$output" "Not archived" "re-unarchive says so" || return 1
}

test_archive_unknown_session_errors() {
    local output
    if output=$("$CS_BIN" -archive no-such-session 2>&1); then
        echo "  FAIL: unknown session should error"
        return 1
    fi
    assert_output_contains "$output" "No such session" "error names the problem" || return 1
    if output=$("$CS_BIN" -unarchive no-such-session 2>&1); then
        echo "  FAIL: unknown session should error"
        return 1
    fi
}

test_archive_no_name_errors_with_usage() {
    local output
    if output=$("$CS_BIN" -archive 2>&1); then
        echo "  FAIL: bare -archive should error"
        return 1
    fi
    assert_output_contains "$output" "Usage" "bare form shows usage" || return 1
}

test_archive_refuses_live_session_without_force() {
    _archive_session "livesess"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/livesess/.cs/session.lock"

    local output rc=0
    output=$("$CS_BIN" -archive livesess 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: live session must refuse archive without --force"
        return 1
    fi
    assert_output_contains "$output" "--force" "refusal names the override" || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/livesess/.cs/archived" ] || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: refused archive must not write the marker"; return 1; }

    "$CS_BIN" -archive livesess --force >/dev/null 2>&1
    rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    [ "$rc" -eq 0 ] || { echo "  FAIL: --force should archive a live session"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/livesess/.cs/archived" ] || { echo "  FAIL: --force marker missing"; return 1; }
}

run_test test_archive_subcommand_exists
run_test test_archive_roundtrip_and_marker_content
run_test test_archive_is_idempotent
run_test test_archive_unknown_session_errors
run_test test_archive_no_name_errors_with_usage
run_test test_archive_refuses_live_session_without_force
report_results
