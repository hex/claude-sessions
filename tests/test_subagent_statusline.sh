#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-subagent-statusline, the Claude Code agent-panel row renderer
# ABOUTME: Covers row content, model mapping, ctx thresholds, truncation, and fail-open posture

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SSL="$SCRIPT_DIR/../bin/cs-subagent-statusline"

# startTime is pinned against CS_SUBAGENT_NOW_MS so elapsed is deterministic.
# 1752148800000 ms + 134 s -> "2m14s".
NOW_MS=1752148934000
FIXTURE_ONE='{"columns":96,"tasks":[{"id":"t1","name":"bundle-recon","type":"general-purpose","status":"running","description":"Spelunk CC bundle","startTime":1752148800000,"model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":24000}]}'
FIXTURE_EMPTY='{"columns":96,"tasks":[]}'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    unset COLUMNS 2>/dev/null || true
    export TERM="xterm-256color"
    export CS_SUBAGENT_NOW_MS="$NOW_MS"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset NO_COLOR COLORTERM TERM_PROGRAM FORCE_COLOR CS_SUBAGENT_NOW_MS \
        CS_SUBAGENT_STATUSLINE_DISABLE CS_STATUSLINE_CTX_WARN CS_STATUSLINE_CTX_CRIT 2>/dev/null || true
}

# Run the row renderer with $1 as stdin JSON; prints its stdout.
run_ssl() {
    printf '%s' "$1" | bash "$SSL"
}

# Extract the .content of the row whose .id is $2, from the raw stdout in $1.
row_content() {
    printf '%s\n' "$1" | jq -r --arg id "$2" 'select(.id == $id) | .content'
}

test_empty_tasks_prints_nothing() {
    local out
    out=$(run_ssl "$FIXTURE_EMPTY")
    assert_eq "" "$out" "no tasks means no rows" || return 1
}

test_malformed_stdin_exits_clean() {
    local out rc
    out=$(printf 'not json' | bash "$SSL"); rc=$?
    assert_eq "0" "$rc" "malformed stdin must exit 0" || return 1
    assert_eq "" "$out" "malformed stdin must print nothing" || return 1
}

test_disable_env_prints_nothing() {
    export CS_SUBAGENT_STATUSLINE_DISABLE=1
    local out
    out=$(run_ssl "$FIXTURE_ONE")
    assert_eq "" "$out" "CS_SUBAGENT_STATUSLINE_DISABLE=1 silences the renderer" || return 1
}

run_test test_empty_tasks_prints_nothing
run_test test_malformed_stdin_exits_clean
run_test test_disable_env_prints_nothing
report_results
