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
report_results
