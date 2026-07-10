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

test_row_has_model_name_desc_ctx_elapsed() {
    export NO_COLOR=1
    local out c
    out=$(run_ssl "$FIXTURE_ONE")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "Sonnet 5" "model display name" || return 1
    assert_output_contains "$c" "bundle-recon" "agent name" || return 1
    assert_output_contains "$c" "Spelunk CC bundle" "description" || return 1
    assert_output_contains "$c" "ctx 12%" "24000/200000 is 12 percent" || return 1
    assert_output_contains "$c" "2m14s" "134 seconds elapsed" || return 1
}

test_no_model_means_no_model_and_no_ctx() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","startTime":1752148800000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "ctx" "no contextWindowSize means no ctx gauge" || return 1
    assert_output_not_contains "$c" "✦" "no model means no model chip" || return 1
    assert_output_contains "$c" "d" "description still renders" || return 1
}

test_zero_context_window_is_not_a_divide_by_zero() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":0,"tokenCount":5}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "ctx" "contextWindowSize 0 yields no gauge" || return 1
    assert_output_contains "$c" "Sonnet 5" "model still renders" || return 1
}

test_unknown_model_id_renders_verbatim() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-zephyr-9"}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "claude-zephyr-9" "an unknown model degrades to its id, never to invisible" || return 1
}

test_missing_name_falls_back_to_type() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","type":"general-purpose","description":"d"}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "general-purpose" "type is the fallback for a missing name" || return 1
}

test_elapsed_over_an_hour_uses_hours() {
    export NO_COLOR=1
    local fx out c
    # startTime is 3900 s (1h05m) before CS_SUBAGENT_NOW_MS.
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","startTime":1752145034000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "1h05m" "3900 seconds is 1h05m" || return 1
}

test_content_escapes_esc_as_unicode() {
    export COLORTERM=truecolor
    local out
    out=$(run_ssl "$FIXTURE_ONE")
    assert_output_contains "$out" 'u001b' "the raw line must carry the escaped form" || return 1
    printf '%s' "$out" | LC_ALL=C grep -q $'\033' && {
        echo "  FAIL: raw ESC byte leaked into the JSON line"; return 1; }
    printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || {
        echo "  FAIL: emitted line is not valid JSON"; return 1; }
}

test_ctx_escalates_to_amber_then_red() {
    export COLORTERM=truecolor
    local fx out c
    # 110000/200000 = 55% -> past warn (50), below crit (80) -> amber 255;183;77
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":110000}]}'
    out=$(run_ssl "$fx"); c=$(row_content "$out" "t1")
    assert_output_contains "$c" "38;2;255;183;77" "55% context renders amber" || return 1

    # 170000/200000 = 85% -> past crit (80) -> red 220;38;38
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":170000}]}'
    out=$(run_ssl "$fx"); c=$(row_content "$out" "t1")
    assert_output_contains "$c" "38;2;220;38;38" "85% context renders red" || return 1
}

test_plain_mode_has_no_escape_sequences() {
    export NO_COLOR=1
    local out c
    out=$(run_ssl "$FIXTURE_ONE")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "38;2;" "NO_COLOR must suppress SGR parameters" || return 1
    assert_output_contains "$c" "ctx 12%" "text survives in plain mode" || return 1
}

run_test test_empty_tasks_prints_nothing
run_test test_malformed_stdin_exits_clean
run_test test_disable_env_prints_nothing
run_test test_row_has_model_name_desc_ctx_elapsed
run_test test_no_model_means_no_model_and_no_ctx
run_test test_zero_context_window_is_not_a_divide_by_zero
run_test test_unknown_model_id_renders_verbatim
run_test test_missing_name_falls_back_to_type
run_test test_elapsed_over_an_hour_uses_hours
run_test test_content_escapes_esc_as_unicode
run_test test_ctx_escalates_to_amber_then_red
run_test test_plain_mode_has_no_escape_sequences
report_results
