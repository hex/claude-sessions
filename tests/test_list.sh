#!/usr/bin/env bash
# ABOUTME: Tests for `cs -list` (list_sessions), including bash 3.2 portability
# ABOUTME: Guards against bash 4+ constructs (associative arrays) breaking the listing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# `cs -list` renders the session table under the current bash.
test_list_renders_sessions() {
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "cs -list should list session alpha" || return 1
    assert_output_contains "$out" "beta" "cs -list should list session beta"
}

# `cs -list` must work under bash <4 (no associative arrays), e.g. macOS stock
# /bin/bash 3.2. Regression: list_sessions used `local -A`, which aborts there
# with "local: -A: invalid option" under set -euo pipefail. Skips when no such
# bash is available (e.g. Linux where /bin/bash is modern).
test_list_runs_under_old_bash() {
    local old_bash=/bin/bash
    if [ ! -x "$old_bash" ] || "$old_bash" -c 'declare -A _x' 2>/dev/null; then
        echo "    SKIP: no bash lacking associative arrays available"
        return 0
    fi
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out rc=0
    out=$("$old_bash" "$CS_BIN" -list 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: cs -list aborted under bash <4 (rc=$rc)"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "alpha" "cs -list should list alpha under bash <4" || return 1
    assert_output_contains "$out" "beta" "cs -list should list beta under bash <4"
}

# A non-session directory under the sessions root (editor config, an empty cs
# artifact) must not be listed, so that -list and tab-completion agree on what a
# session is.
test_list_omits_non_session_directories() {
    create_test_session alpha >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.obsidian"
    mkdir -p "$CS_SESSIONS_ROOT/worktrees"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "cs -list should list a real session" || return 1
    assert_output_not_contains "$out" ".obsidian" "cs -list should omit editor config" || return 1
    assert_output_not_contains "$out" "worktrees" "cs -list should omit the empty worktrees holder" || return 1
}

# A pre-.cs/ session keeps its state beside a root CLAUDE.md; -list still shows it.
test_list_includes_a_legacy_session() {
    local legacy="$CS_SESSIONS_ROOT/legacy"
    mkdir -p "$legacy/logs"
    echo "# Session" > "$legacy/CLAUDE.md"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "legacy" "cs -list should list a pre-.cs/ session" || return 1
}

echo ""
echo "cs -list tests"
echo "=============="
echo ""

run_test test_list_renders_sessions
run_test test_list_omits_non_session_directories
run_test test_list_includes_a_legacy_session
run_test test_list_runs_under_old_bash

report_results
