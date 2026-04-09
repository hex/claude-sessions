#!/usr/bin/env bash
# ABOUTME: Tests for cs -learn and cs -learnings cross-session learnings log
# ABOUTME: Validates JSONL format, append-only behavior, session filtering, and help text

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override setup to have a sessions root for learnings
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CLAUDE_SESSION_NAME 2>/dev/null || true
}

# ============================================================================
# -learn subcommand
# ============================================================================

test_learn_creates_learnings_file() {
    export CLAUDE_SESSION_NAME="test-session"
    "$CS_BIN" -learn "sed -i on macOS requires empty '' argument" > /dev/null 2>&1
    assert_exists "$CS_SESSIONS_ROOT/learnings.jsonl" \
        "learnings.jsonl should be created" || return 1
}

test_learn_writes_valid_jsonl() {
    export CLAUDE_SESSION_NAME="test-session"
    "$CS_BIN" -learn "first insight" > /dev/null 2>&1
    "$CS_BIN" -learn "second insight" > /dev/null 2>&1

    local learnings_file="$CS_SESSIONS_ROOT/learnings.jsonl"
    local line_count
    line_count=$(wc -l < "$learnings_file" | tr -d ' ')
    assert_eq "2" "$line_count" "Should have 2 entries" || return 1

    while IFS= read -r line; do
        if ! echo "$line" | jq -e . > /dev/null 2>&1; then
            echo "  FAIL: Invalid JSON: $line"
            return 1
        fi
    done < "$learnings_file"
}

test_learn_includes_session_name() {
    export CLAUDE_SESSION_NAME="my-project"
    "$CS_BIN" -learn "test insight" > /dev/null 2>&1

    local entry_session
    entry_session=$(jq -r '.session' "$CS_SESSIONS_ROOT/learnings.jsonl")
    assert_eq "my-project" "$entry_session" "Should record session name" || return 1
}

test_learn_includes_timestamp() {
    export CLAUDE_SESSION_NAME="test-session"
    "$CS_BIN" -learn "test insight" > /dev/null 2>&1

    local ts
    ts=$(jq -r '.ts' "$CS_SESSIONS_ROOT/learnings.jsonl")
    if ! [[ "$ts" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]; then
        echo "  FAIL: Timestamp format wrong: $ts"
        return 1
    fi
}

test_learn_preserves_insight_verbatim() {
    export CLAUDE_SESSION_NAME="test-session"
    local insight="quotes \"are\" preserved and so are 'apostrophes'"
    "$CS_BIN" -learn "$insight" > /dev/null 2>&1

    local stored
    stored=$(jq -r '.insight' "$CS_SESSIONS_ROOT/learnings.jsonl")
    assert_eq "$insight" "$stored" "Insight should be stored verbatim" || return 1
}

test_learn_without_session_name_uses_unknown() {
    unset CLAUDE_SESSION_NAME
    "$CS_BIN" -learn "orphan insight" > /dev/null 2>&1

    local session
    session=$(jq -r '.session' "$CS_SESSIONS_ROOT/learnings.jsonl")
    assert_eq "unknown" "$session" "Should fall back to 'unknown' session" || return 1
}

test_learn_requires_argument() {
    export CLAUDE_SESSION_NAME="test-session"
    if "$CS_BIN" -learn 2>&1 > /dev/null; then
        echo "  FAIL: Should fail with no insight"
        return 1
    fi
}

test_learn_appends_not_overwrites() {
    export CLAUDE_SESSION_NAME="test-session"
    "$CS_BIN" -learn "first" > /dev/null 2>&1
    "$CS_BIN" -learn "second" > /dev/null 2>&1
    "$CS_BIN" -learn "third" > /dev/null 2>&1

    local count
    count=$(wc -l < "$CS_SESSIONS_ROOT/learnings.jsonl" | tr -d ' ')
    assert_eq "3" "$count" "Should have 3 entries after 3 appends" || return 1
}

# ============================================================================
# -learnings subcommand
# ============================================================================

test_learnings_shows_empty_message() {
    local output
    output=$("$CS_BIN" -learnings 2>&1)
    assert_output_contains "$output" "No learnings" \
        "Should show empty message when no file" || return 1
}

test_learnings_lists_all() {
    export CLAUDE_SESSION_NAME="alpha"
    "$CS_BIN" -learn "alpha insight one" > /dev/null 2>&1
    "$CS_BIN" -learn "alpha insight two" > /dev/null 2>&1
    export CLAUDE_SESSION_NAME="beta"
    "$CS_BIN" -learn "beta insight" > /dev/null 2>&1

    local output
    output=$("$CS_BIN" -learnings 2>&1)
    assert_output_contains "$output" "alpha insight one" "Should show alpha" || return 1
    assert_output_contains "$output" "beta insight" "Should show beta" || return 1
}

test_learnings_filter_by_session() {
    export CLAUDE_SESSION_NAME="alpha"
    "$CS_BIN" -learn "alpha insight" > /dev/null 2>&1
    export CLAUDE_SESSION_NAME="beta"
    "$CS_BIN" -learn "beta insight" > /dev/null 2>&1

    local output
    output=$("$CS_BIN" -learnings alpha 2>&1)
    assert_output_contains "$output" "alpha insight" "Should show alpha" || return 1
    assert_output_not_contains "$output" "beta insight" "Should NOT show beta" || return 1
}

# ============================================================================
# Help text
# ============================================================================

test_help_shows_learn() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "-learn" "Help should mention -learn" || return 1
    assert_output_contains "$output" "-learnings" "Help should mention -learnings" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs learnings tests"
echo "=================="
echo ""

run_test test_learn_creates_learnings_file
run_test test_learn_writes_valid_jsonl
run_test test_learn_includes_session_name
run_test test_learn_includes_timestamp
run_test test_learn_preserves_insight_verbatim
run_test test_learn_without_session_name_uses_unknown
run_test test_learn_requires_argument
run_test test_learn_appends_not_overwrites
run_test test_learnings_shows_empty_message
run_test test_learnings_lists_all
run_test test_learnings_filter_by_session
run_test test_help_shows_learn

report_results
