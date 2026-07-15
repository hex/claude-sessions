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

test_list_hides_archived_and_prints_trailer() {
    _archive_session "visible-a"
    _archive_session "hidden-a"
    "$CS_BIN" -archive hidden-a >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -list 2>&1) || true
    assert_output_contains "$output" "visible-a" "plain session listed" || return 1
    assert_output_not_contains "$output" "hidden-a" "archived session hidden" || return 1
    assert_output_contains "$output" "1 archived (cs -list --archived)" "trailer counts the hidden" || return 1
}

test_list_archived_shows_only_archived() {
    _archive_session "plain-b"
    _archive_session "arch-b"
    "$CS_BIN" -archive arch-b >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -list --archived 2>&1) || true
    assert_output_contains "$output" "arch-b" "archived session listed" || return 1
    assert_output_not_contains "$output" "plain-b" "plain session excluded" || return 1
    # No trailer in the --archived view — nothing is hidden by the archive rule.
    assert_output_not_contains "$output" "cs -list --archived)" "no trailer when showing archived" || return 1
}

test_list_archived_composes_with_tag() {
    _archive_session "arch-tagged" "tags: [api]"
    _archive_session "arch-untagged" "tags: []"
    "$CS_BIN" -archive arch-tagged >/dev/null 2>&1 || return 1
    "$CS_BIN" -archive arch-untagged >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -list --archived --tag api 2>&1) || true
    assert_output_contains "$output" "arch-tagged" "archived+tagged listed" || return 1
    assert_output_not_contains "$output" "arch-untagged" "archived without the tag excluded" || return 1
}

test_list_trailer_prints_even_when_all_sessions_archived() {
    _archive_session "only-one"
    "$CS_BIN" -archive only-one >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -list 2>&1) || true
    assert_output_contains "$output" "No sessions found" "empty default view says so" || return 1
    assert_output_contains "$output" "1 archived (cs -list --archived)" "trailer still points at the archive" || return 1
}

test_search_skips_archived_by_default() {
    _archive_session "srch-plain"
    _archive_session "srch-arch"
    echo "needle-xyzzy in plain" >> "$CS_SESSIONS_ROOT/srch-plain/.cs/README.md"
    echo "needle-xyzzy in archived" >> "$CS_SESSIONS_ROOT/srch-arch/.cs/README.md"
    "$CS_BIN" -archive srch-arch >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -search "needle-xyzzy" 2>&1) || true
    assert_output_contains "$output" "srch-plain" "plain session searched" || return 1
    assert_output_not_contains "$output" "srch-arch" "archived session skipped" || return 1
    output=$("$CS_BIN" -search "needle-xyzzy" --include-archived 2>&1) || true
    assert_output_contains "$output" "srch-plain" "plain still found with flag" || return 1
    assert_output_contains "$output" "srch-arch" "archived found with flag" || return 1
}

test_search_empty_query_still_errors() {
    local output
    if output=$("$CS_BIN" -search --include-archived 2>&1); then
        echo "  FAIL: flag without a query should error"
        return 1
    fi
    assert_output_contains "$output" "Usage" "usage error preserved" || return 1
}

run_test test_archive_subcommand_exists
run_test test_archive_roundtrip_and_marker_content
run_test test_archive_is_idempotent
run_test test_archive_unknown_session_errors
run_test test_archive_no_name_errors_with_usage
run_test test_archive_refuses_live_session_without_force
run_test test_list_hides_archived_and_prints_trailer
run_test test_list_archived_shows_only_archived
run_test test_list_archived_composes_with_tag
run_test test_list_trailer_prints_even_when_all_sessions_archived
run_test test_search_skips_archived_by_default
run_test test_search_empty_query_still_errors
report_results
