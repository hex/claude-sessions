#!/usr/bin/env bash
# ABOUTME: Tests for cs -usage, the per-session token table over rate-limit windows
# ABOUTME: Covers requestId dedup, window filtering, limits anchoring, sorting, scoped form

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# ISO-8601 UTC timestamp N minutes in the past (BSD date first, GNU fallback).
_iso_mins_ago() {
    date -u -v-"$1"M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%S.000Z
}

# Write a transcript project dir for a session dir, echoing the project dir.
# Uses the same symlink-resolved encoding as _claude_project_dir.
_transcripts_for() {
    local sdir="$1" resolved encoded
    resolved=$( (cd "$sdir" && pwd -P) || printf '%s' "$sdir" )
    encoded=$(echo "$resolved" | sed 's|/|-|g; s|\.|-|g')
    local proj="$CS_TRANSCRIPTS_DIR/$encoded"
    mkdir -p "$proj"
    printf '%s' "$proj"
}

test_usage_subcommand_exists() {
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -usage should be a recognized verb" || return 1
}

run_test test_usage_subcommand_exists

# Three lines share requestId req_A (streamed content blocks repeat usage);
# a naive sum triples req_A. Deduped: in 1000+2000=3000, out 250+500=750.
test_usage_dedups_by_request_id() {
    local sdir="$CS_SESSIONS_ROOT/dedup-sess"
    mkdir -p "$sdir/.cs/local"
    local proj now
    proj=$(_transcripts_for "$sdir")
    now=$(_iso_mins_ago 5)
    cat > "$proj/conv1.jsonl" << EOF
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","requestId":"req_A","timestamp":"$now","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":250}}}
{"type":"assistant","requestId":"req_A","timestamp":"$now","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":250}}}
{"type":"assistant","requestId":"req_A","timestamp":"$now","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":250}}}
{"type":"assistant","requestId":"req_B","timestamp":"$now","message":{"model":"claude-fable-5","usage":{"input_tokens":2000,"cache_creation_input_tokens":200,"output_tokens":500}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    # IN = input + cache_creation = 3000+300 = 3.3K; OUT = 750
    assert_output_contains "$output" "dedup-sess" "session with usage should appear" || return 1
    assert_output_contains "$output" "3.3K" "deduped IN should be 3.3K (naive would be 9.9K)" || return 1
    assert_output_contains "$output" "750" "deduped OUT should be 750" || return 1
}

# One request 5 minutes old (inside 5h and week), one 6 hours old (outside
# 5h, inside week): the two window columns must differ.
test_usage_window_boundaries() {
    local sdir="$CS_SESSIONS_ROOT/window-sess"
    mkdir -p "$sdir/.cs/local"
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/conv1.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 5)","message":{"model":"m","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","requestId":"r2","timestamp":"$(_iso_mins_ago 360)","message":{"model":"m","usage":{"input_tokens":5000,"cache_creation_input_tokens":0,"output_tokens":900}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    # 5h window: 1.0K in / 100 out. Week window: 6.0K in / 1.0K out.
    assert_output_contains "$output" "1.0K / 100" "5h column shows only the recent request" || return 1
    assert_output_contains "$output" "6.0K / 1.0K" "week column shows both requests" || return 1
}

run_test test_usage_dedups_by_request_id
run_test test_usage_window_boundaries

# A seeded limits file anchors the header and the 5h window at resets_at - 5h.
test_usage_header_anchored_by_limits_file() {
    local sdir="$CS_SESSIONS_ROOT/anchor-sess"
    mkdir -p "$sdir/.cs/local"
    local now reset5 resetw
    now=$(date +%s)
    reset5=$((now + 3600))    # 5h window began 4h ago
    resetw=$((now + 86400))
    cat > "$sdir/.cs/local/limits" << EOF
five_hour_used_pct: 62
five_hour_resets_at: $reset5
seven_day_used_pct: 41
seven_day_resets_at: $resetw
stamped_at: $now
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_contains "$output" "5h 62%" "header shows 5h used pct" || return 1
    assert_output_contains "$output" "week 41%" "header shows week used pct" || return 1
    assert_output_contains "$output" "resets" "header shows reset time" || return 1
    assert_output_not_contains "$output" "windows are rolling" "anchored header replaces rolling label" || return 1
}

# Anchoring is real: a request 4.5h old is OUTSIDE a 5h window that began 4h
# ago (resets_at = now+1h), but inside a rolling now-5h window. The fixture
# session name deliberately has no hyphen: the grep proves the 5h cell is '-',
# and a hyphen in the name would satisfy the pattern regardless of the cells.
test_usage_window_start_is_resets_minus_span() {
    local sdir="$CS_SESSIONS_ROOT/anchormath"
    mkdir -p "$sdir/.cs/local"
    local now
    now=$(date +%s)
    cat > "$sdir/.cs/local/limits" << EOF
five_hour_used_pct: 10
five_hour_resets_at: $((now + 3600))
seven_day_used_pct: 10
seven_day_resets_at: $((now + 86400))
stamped_at: $now
EOF
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/conv1.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 270)","message":{"model":"m","usage":{"input_tokens":7000,"cache_creation_input_tokens":0,"output_tokens":700}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    # 5h cell renders '-' (request predates the anchored window start) while
    # the week cell carries the tokens — that ordering proves the anchor math.
    assert_output_contains "$output" "anchormath" "row appears via week usage" || return 1
    echo "$output" | grep "anchormath" | grep -q -- "-.*7.0K / 700" || {
        echo "  FAIL: 5h cell should be '-' while week cell has 7.0K / 700"
        return 1
    }
}

run_test test_usage_header_anchored_by_limits_file
run_test test_usage_window_start_is_resets_minus_span
report_results
