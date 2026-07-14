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
    assert_output_contains "$output" "windows are rolling" "no-limits-file header states rolling windows" || return 1
}

run_test test_usage_subcommand_exists

# Three lines share requestId req_A (streamed content blocks repeat usage);
# a naive sum triples req_A. Deduped IN = input + cache_creation =
# (1000+100) + (2000+200) = 3300 (3.3K); naive IN would be
# (1000+100)*3 + (2000+200) = 5500 (5.5K). Deduped OUT = 250+500=750.
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
    assert_output_contains "$output" "3.3K" "deduped IN should be 3.3K (naive would be 5.5K)" || return 1
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

# A truncated line (a torn write from a concurrently-appended live transcript)
# sits between two valid lines in one file, with a second valid file
# lexicographically after it in the same session. Garbage must be skipped,
# never fatal to the rest of the scan: the sums must include the valid lines
# from BOTH files, a total impossible if the scan died at the garbage line.
test_usage_tolerates_truncated_transcript_line() {
    local sdir="$CS_SESSIONS_ROOT/garbage-sess"
    mkdir -p "$sdir/.cs/local"
    local proj now
    proj=$(_transcripts_for "$sdir")
    now=$(_iso_mins_ago 5)
    cat > "$proj/a-conv1.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$now","message":{"model":"m","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","requestId":"rX","timestamp":"$now","mess
{"type":"assistant","requestId":"r2","timestamp":"$now","message":{"model":"m","usage":{"input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":200}}}
EOF
    cat > "$proj/b-conv2.jsonl" << EOF
{"type":"assistant","requestId":"r3","timestamp":"$now","message":{"model":"m","usage":{"input_tokens":4000,"cache_creation_input_tokens":0,"output_tokens":400}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_contains "$output" "garbage-sess" "session with a truncated line still appears" || return 1
    # Sum across both files, skipping the garbage line: in 1000+2000+4000=7000,
    # out 100+200+400=700.
    echo "$output" | grep "garbage-sess" | grep -q "7.0K / 700" || {
        echo "  FAIL: sums should include valid lines from both files despite the truncated line (7.0K / 700)"
        return 1
    }
}

run_test test_usage_dedups_by_request_id
run_test test_usage_window_boundaries
run_test test_usage_tolerates_truncated_transcript_line

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

# Both resets_at epochs are in the past (a stale limits file, e.g. left behind
# by a statusline that stopped rendering). Anchoring must not trust an expired
# reset: the header falls back to the stale-stamp message, and the 5h window
# stays rolling rather than smearing to [expired-reset - 5h, now]. Fixture
# session name deliberately has no hyphen — see anchormath above for why.
test_usage_expired_anchor_falls_back_to_rolling() {
    local sdir="$CS_SESSIONS_ROOT/stalesess"
    mkdir -p "$sdir/.cs/local"
    local now
    now=$(date +%s)
    cat > "$sdir/.cs/local/limits" << EOF
five_hour_used_pct: 80
five_hour_resets_at: $((now - 7200))
seven_day_used_pct: 55
seven_day_resets_at: $((now - 3600))
stamped_at: $now
EOF
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/conv1.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 360)","message":{"model":"m","usage":{"input_tokens":7000,"cache_creation_input_tokens":0,"output_tokens":700}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_contains "$output" "stale rate-limit stamp" "expired resets produce the stale-stamp header" || return 1
    assert_output_contains "$output" "windows are rolling" "stale header still states rolling windows" || return 1
    # Rolling 5h correctly excludes a 6h-old request (cell '-'); the old
    # smeared window (expired-reset - 5h) wrongly included it. This ordering
    # is the discriminating assertion for the fix.
    echo "$output" | grep "stalesess" | grep -q -- "-.*7.0K / 700" || {
        echo "  FAIL: 5h cell should be '-' (rolling 5h excludes a 6h-old request) while week cell has 7.0K / 700"
        return 1
    }
}

run_test test_usage_header_anchored_by_limits_file
run_test test_usage_window_start_is_resets_minus_span
run_test test_usage_expired_anchor_falls_back_to_rolling

# Two sessions: bigger 5h usage sorts first; each row shows only its own tokens.
test_usage_attribution_and_sort() {
    local a="$CS_SESSIONS_ROOT/aa-small" b="$CS_SESSIONS_ROOT/bb-big"
    mkdir -p "$a/.cs/local" "$b/.cs/local"
    local pa pb now
    pa=$(_transcripts_for "$a"); pb=$(_transcripts_for "$b")
    now=$(_iso_mins_ago 5)
    cat > "$pa/c.jsonl" << EOF
{"type":"assistant","requestId":"ra","timestamp":"$now","message":{"model":"m","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":10}}}
EOF
    cat > "$pb/c.jsonl" << EOF
{"type":"assistant","requestId":"rb","timestamp":"$now","message":{"model":"m","usage":{"input_tokens":900000,"cache_creation_input_tokens":0,"output_tokens":90000}}}
EOF
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_contains "$output" "aa-small" "small session listed" || return 1
    assert_output_contains "$output" "bb-big" "big session listed" || return 1
    # bb-big sorts above aa-small despite aa < bb alphabetically
    local first
    first=$(echo "$output" | grep -n -e "aa-small" -e "bb-big" | sort -t: -k1,1n | head -1)
    case "$first" in
        *bb-big*) : ;;
        *) echo "  FAIL: bb-big should sort first (5h usage desc), got: $first"; return 1 ;;
    esac
}

# Sessions with no window usage are hidden by default and shown with --all.
test_usage_hides_zero_rows_unless_all() {
    create_test_session "idle-sess" >/dev/null || return 1
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_not_contains "$output" "idle-sess" "zero-usage session hidden by default" || return 1
    output=$("$CS_BIN" -usage --all 2>&1) || true
    assert_output_contains "$output" "idle-sess" "--all shows zero-usage session" || return 1
}

# A live session (lock held by a running pid) gets the live marker.
test_usage_live_marker() {
    local sdir="$CS_SESSIONS_ROOT/live-sess"
    mkdir -p "$sdir/.cs/local"
    printf '%s\n' "$$" > "$sdir/.cs/session.lock"
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/c.jsonl" << EOF
{"type":"assistant","requestId":"rl","timestamp":"$(_iso_mins_ago 5)","message":{"model":"m","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":10}}}
EOF
    local output
    output=$(NO_COLOR=1 "$CS_BIN" -usage 2>&1) || true
    echo "$output" | grep "live-sess" | grep -q "●" || {
        echo "  FAIL: live session row should carry the ● marker"
        return 1
    }
}

run_test test_usage_attribution_and_sort
run_test test_usage_hides_zero_rows_unless_all
run_test test_usage_live_marker

# Scoped form: one row per conversation file with a LIFETIME column.
test_usage_scoped_per_conversation() {
    local sdir="$CS_SESSIONS_ROOT/scoped-sess"
    mkdir -p "$sdir/.cs/local"
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/aaaa1111-2222-3333-4444-555566667777.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 5)","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":100}}}
EOF
    cat > "$proj/bbbb1111-2222-3333-4444-555566667777.jsonl" << EOF
{"type":"assistant","requestId":"r2","timestamp":"$(_iso_mins_ago 20000)","message":{"model":"claude-opus-4-8","usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"output_tokens":5000}}}
EOF
    local output
    output=$("$CS_BIN" -usage scoped-sess 2>&1) || true
    assert_output_contains "$output" "aaaa1111" "recent conversation row present" || return 1
    assert_output_contains "$output" "bbbb1111" "old conversation row present (lifetime view has no prefilter)" || return 1
    assert_output_contains "$output" "claude-opus-4-8" "model column shows per-conversation model" || return 1
    assert_output_contains "$output" "LIFETIME" "scoped view has a lifetime column" || return 1
    # Old conversation: zero in both windows, 50.0K / 5.0K lifetime.
    echo "$output" | grep "bbbb1111" | grep -q "50.0K / 5.0K" || {
        echo "  FAIL: lifetime column should show 50.0K / 5.0K for the old conversation"
        return 1
    }
}

# Site-B arm: cs <name> -usage works and unknown session errors cleanly.
test_usage_scoped_site_b() {
    local sdir="$CS_SESSIONS_ROOT/siteb-sess"
    mkdir -p "$sdir/.cs/local"
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/c.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 5)","message":{"model":"m","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":10}}}
EOF
    local output
    output=$("$CS_BIN" siteb-sess -usage 2>&1) || true
    assert_output_not_contains "$output" "Unknown session command" "site-B arm accepts -usage" || return 1
    assert_output_contains "$output" "LIFETIME" "site-B form renders the scoped view" || return 1
}

test_usage_scoped_unknown_session_errors() {
    local output
    if output=$("$CS_BIN" -usage no-such-session 2>&1); then
        echo "  FAIL: expected non-zero exit for unknown session"
        return 1
    fi
    assert_output_contains "$output" "No such session" "clear error for unknown session" || return 1
}

# A subagent transcript lives in a subdir named after its parent conversation's
# uuid; the scoped view must fold its tokens into that conversation's row.
test_usage_scoped_folds_subagent_transcripts() {
    local sdir="$CS_SESSIONS_ROOT/subagent-sess"
    mkdir -p "$sdir/.cs/local"
    local proj
    proj=$(_transcripts_for "$sdir")
    cat > "$proj/cccc1111-2222-3333-4444-555566667777.jsonl" << EOF
{"type":"assistant","requestId":"r1","timestamp":"$(_iso_mins_ago 5)","message":{"model":"claude-fable-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":100}}}
EOF
    mkdir -p "$proj/cccc1111-2222-3333-4444-555566667777"
    cat > "$proj/cccc1111-2222-3333-4444-555566667777/agent-x.jsonl" << EOF
{"type":"assistant","requestId":"r2","timestamp":"$(_iso_mins_ago 5)","message":{"model":"claude-fable-5","usage":{"input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":50}}}
EOF
    local output
    output=$("$CS_BIN" -usage subagent-sess 2>&1) || true
    assert_output_contains "$output" "cccc1111" "conversation row present" || return 1
    # Combined: in 1000+500=1500 -> 1.5K, out 100+50=150.
    echo "$output" | grep "cccc1111" | grep -q "1.5K / 150" || {
        echo "  FAIL: 5h cell should fold subagent tokens into 1.5K / 150"
        return 1
    }
}

run_test test_usage_scoped_per_conversation
run_test test_usage_scoped_site_b
run_test test_usage_scoped_unknown_session_errors
run_test test_usage_scoped_folds_subagent_transcripts
report_results
