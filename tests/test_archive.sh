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
test_open_auto_unarchives_with_notice() {
    local dir="$CS_SESSIONS_ROOT/reopen"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    echo "# test" > "$dir/CLAUDE.md"
    # Machine-local state must never be committed, as a real session's
    # .gitignore ensures; otherwise cs_assert_local_untracked refuses to open.
    printf '.cs/local/\n' > "$dir/.gitignore"
    (cd "$dir" && git init -q 2>/dev/null && git add -A 2>/dev/null && git commit -q -m "init" 2>/dev/null) || true

    "$CS_BIN" -archive reopen >/dev/null 2>&1 || return 1
    [ -f "$dir/.cs/archived" ] || { echo "  FAIL: setup: marker missing"; return 1; }

    cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"

    # Reopening an existing session dir means is_new=false, which triggers the
    # "Continue previous conversation?" prompt (see tests/test_session_lock.sh
    # for the same pattern); answer "n" so the launch proceeds non-interactively.
    local output rc=0
    output=$(echo "n" | "$CS_BIN" reopen 2>&1) || rc=$?
    unset CLAUDE_CODE_BIN
    [ "$rc" -eq 0 ] || { echo "  FAIL: open exited non-zero: $output"; return 1; }
    [ ! -f "$dir/.cs/archived" ] || { echo "  FAIL: marker should be removed at launch"; return 1; }
    assert_output_contains "$output" "Unarchived: reopen" "launch prints the notice" || return 1
}

test_unarchive_rejects_flags_and_extra_names() {
    _archive_session "ua1"
    _archive_session "ua2"
    "$CS_BIN" -archive ua1 >/dev/null 2>&1 || return 1
    "$CS_BIN" -archive ua2 >/dev/null 2>&1 || return 1
    local output
    if output=$("$CS_BIN" -unarchive --force ua1 2>&1); then
        echo "  FAIL: flag must be rejected"
        return 1
    fi
    assert_output_contains "$output" "Unknown unarchive option" "flag rejection names the option" || return 1
    if output=$("$CS_BIN" -unarchive ua1 ua2 2>&1); then
        echo "  FAIL: extra name must error"
        return 1
    fi
    [ -f "$CS_SESSIONS_ROOT/ua1/.cs/archived" ] || { echo "  FAIL: refused call must not unarchive"; return 1; }
    "$CS_BIN" -unarchive ua1 >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/ua1/.cs/archived" ] || { echo "  FAIL: single-name unarchive must still work"; return 1; }
}

test_list_tag_trailer_counts_only_tagged_archived() {
    _archive_session "tagged-arch" "tags: [api]"
    _archive_session "untagged-arch" "tags: []"
    _archive_session "tagged-live" "tags: [api]"
    "$CS_BIN" -archive tagged-arch >/dev/null 2>&1 || return 1
    "$CS_BIN" -archive untagged-arch >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -list --tag api 2>&1) || true
    assert_output_contains "$output" "tagged-live" "unarchived tagged session listed" || return 1
    assert_output_not_contains "$output" "tagged-arch" "archived tagged session hidden" || return 1
    assert_output_contains "$output" "1 archived (cs -list --archived)" "trailer counts only the tag-matching archived session" || return 1
}

test_search_flag_before_query() {
    _archive_session "ffq"
    echo "needle-ffq here" >> "$CS_SESSIONS_ROOT/ffq/.cs/README.md"
    "$CS_BIN" -archive ffq >/dev/null 2>&1 || return 1
    local output
    output=$("$CS_BIN" -search --include-archived "needle-ffq" 2>&1) || true
    assert_output_contains "$output" "ffq" "flag-first order finds the archived session" || return 1
}

run_test test_search_skips_archived_by_default
run_test test_search_empty_query_still_errors
run_test test_open_auto_unarchives_with_notice
run_test test_unarchive_rejects_flags_and_extra_names
run_test test_list_tag_trailer_counts_only_tagged_archived
run_test test_search_flag_before_query
report_results
