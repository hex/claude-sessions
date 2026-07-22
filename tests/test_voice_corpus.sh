#!/usr/bin/env bash
# ABOUTME: Tests for the /voice corpus extractor (skills/voice/scripts/build-corpus.sh)
# ABOUTME: Covers typed-message filtering, redaction, dedupe, caps, and error paths

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

VOICE_SCRIPT="$SCRIPT_DIR/../skills/voice/scripts/build-corpus.sh"

# Corpus lands here; setup() exports CS_SESSIONS_ROOT and CS_TRANSCRIPTS_DIR.
corpus_path() { echo "$CS_SESSIONS_ROOT/.voice/corpus.md"; }

# Append one typed-user entry to transcript file $1: text $2, ts $3, extra JSON $4
add_msg() {
    local file="$1" text="$2" ts="${3:-2026-07-01T10:00:00Z}" extra="${4:-}"
    [ -n "$extra" ] || extra='{}'
    mkdir -p "$(dirname "$file")"
    jq -nc --arg t "$text" --arg ts "$ts" --argjson x "$extra" \
        '{type: "user", timestamp: $ts, message: {content: $t}} + $x' >> "$file"
}

proj_file() { echo "$CS_TRANSCRIPTS_DIR/$1/session-1.jsonl"; }

run_build() { "$VOICE_SCRIPT" 2>&1; }

test_typed_string_message_lands_in_corpus() {
    add_msg "$(proj_file projA)" "here is a genuinely typed message about the build system"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "genuinely typed message about the build" \
        "typed string message should be kept" || return 1
    assert_file_contains "$(corpus_path)" "\[projA, 2026-07-01\]" \
        "block carries project and date attribution" || return 1
}

test_array_text_parts_join() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:00:00Z","message":{"content":[{"type":"text","text":"first fragment of the thought"},{"type":"tool_result","content":"IGNORED_TOOL_PAYLOAD"},{"type":"text","text":"second fragment of the thought"}]}}' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "first fragment of the thought second fragment of the thought" \
        "array text parts should join with a space" || return 1
    if grep -qF "IGNORED_TOOL_PAYLOAD" "$(corpus_path)"; then
        echo "  FAIL: tool_result payload leaked into corpus"; return 1
    fi
}

test_tool_result_only_entry_dropped() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:00:00Z","message":{"content":[{"type":"tool_result","content":"TOOL_ONLY_PAYLOAD"}]}}' >> "$f"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "1 non-typed" \
        "stats should count the tool_result-only entry as non-typed" || return 1
}

test_meta_and_sidechain_dropped() {
    add_msg "$(proj_file projA)" "meta message that must never appear anywhere" "2026-07-01T10:00:00Z" '{"isMeta": true}'
    add_msg "$(proj_file projA)" "sidechain message that must never appear anywhere" "2026-07-01T10:00:01Z" '{"isSidechain": true}'
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "must never appear anywhere" "$(corpus_path)"; then
        echo "  FAIL: isMeta/isSidechain entry leaked into corpus"; return 1
    fi
}

test_subagent_transcripts_skipped() {
    add_msg "$CS_TRANSCRIPTS_DIR/projA/sess-uuid/subagents/agent-abc.jsonl" \
        "subagent dispatch prompt that is not the user talking"
    add_msg "$CS_TRANSCRIPTS_DIR/projA/agent-topx.jsonl" \
        "agent-named transcript that is not the user talking"
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "not the user talking" "$(corpus_path)"; then
        echo "  FAIL: subagent transcript leaked into corpus"; return 1
    fi
}

test_harness_sentinels_dropped() {
    local f; f="$(proj_file projA)"
    add_msg "$f" "Caveat: the messages below were generated while running local commands"
    add_msg "$f" "This session is being continued from a previous conversation that ran out"
    add_msg "$f" "<command-name>/compact</command-name> padding padding padding"
    add_msg "$f" "<local-command-stdout>Compacted</local-command-stdout> padding pad"
    add_msg "$f" "<system-reminder>background reminder text goes here</system-reminder>"
    add_msg "$f" "Stop hook feedback: the hook says to do more work right now"
    add_msg "$f" "[Request interrupted by user] and some trailing content here"
    add_msg "$f" "TASKMASTER (1/20): Completion signal not found anywhere at all"
    add_msg "$f" "<task-notification> subagent completion payload with tool ids </task-notification>"
    add_msg "$f" "<teammate-message teammate_id=\"lead\"> agent-team envelope body here"
    add_msg "$f" "<bash-input>ls -la</bash-input> <bash-stdout>total 0</bash-stdout>"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "11 harness-injected" \
        "stats should count all eleven sentinel classes" || return 1
    if grep -q "Completion signal not found" "$(corpus_path)"; then
        echo "  FAIL: sentinel message leaked into corpus"; return 1
    fi
}

test_short_acks_go_to_appendix() {
    local f; f="$(proj_file projA)"
    add_msg "$f" "approved" "2026-07-01T10:00:00Z"
    add_msg "$f" "approved" "2026-07-01T11:00:00Z"
    add_msg "$f" "go" "2026-07-01T12:00:00Z"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "  2  approved" \
        "appendix should count the repeated short ack" || return 1
    assert_file_contains "$(corpus_path)" "  1  go" \
        "appendix should list the single short ack" || return 1
    if grep -q "^\[projA, .*\]$" "$(corpus_path)" && grep -B1 "^approved$" "$(corpus_path)" | grep -q "^\[projA"; then
        echo "  FAIL: short ack appeared as a corpus body block"; return 1
    fi
}

test_paste_over_2000_chars_dropped() {
    local blob
    blob="$(printf '%02100d' 0 | tr '0' 'x')"
    add_msg "$(proj_file projA)" "$blob"
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "xxxxxxxxxx" "$(corpus_path)"; then
        echo "  FAIL: >2000-char paste leaked into corpus"; return 1
    fi
    assert_file_contains "$(corpus_path)" "1 pastes over 2000 chars" \
        "stats should count the dropped paste" || return 1
}

test_credential_lines_redacted() {
    local msg
    msg="$(printf 'line one is ordinary prose talking about deploys\napi_key: supersecretvalue123456\nline three continues the ordinary thought')"
    add_msg "$(proj_file projA)" "$msg"
    add_msg "$(proj_file projA)" "the token parser handles this case fine in ordinary prose"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "\[redacted line\]" \
        "credential-shaped line should be replaced" || return 1
    assert_file_contains "$(corpus_path)" "line one is ordinary prose" \
        "surrounding prose should survive redaction" || return 1
    assert_file_contains "$(corpus_path)" "the token parser handles this case fine" \
        "the word token without a value should not trigger redaction" || return 1
    if grep -q "supersecretvalue123456" "$(corpus_path)"; then
        echo "  FAIL: secret value leaked into corpus"; return 1
    fi
}

test_duplicates_collapse_to_newest() {
    add_msg "$(proj_file projA)" "the duplicated message body typed twice over time" "2026-01-05T10:00:00Z"
    add_msg "$(proj_file projB)" "the duplicated message body typed twice over time" "2026-06-05T10:00:00Z"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local n
    n=$(grep -c "the duplicated message body typed twice" "$(corpus_path)")
    assert_eq "1" "$n" "duplicate should collapse to one occurrence" || return 1
    assert_file_contains "$(corpus_path)" "\[projB, 2026-06-05\]" \
        "collapsed duplicate should keep the newest attribution" || return 1
}

test_newest_first_ordering() {
    add_msg "$(proj_file projA)" "january era message that should come second" "2026-01-10T10:00:00Z"
    add_msg "$(proj_file projA)" "june era message that should come first here" "2026-06-10T10:00:00Z"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local first second
    first=$(grep -n "june era message" "$(corpus_path)" | cut -d: -f1)
    second=$(grep -n "january era message" "$(corpus_path)" | cut -d: -f1)
    if [ -z "$first" ] || [ -z "$second" ]; then
        echo "  FAIL: expected messages missing from corpus"
        return 1
    fi
    if [ "$first" -ge "$second" ]; then
        echo "  FAIL: newest message should appear before older ones ($first vs $second)"
        return 1
    fi
}

test_cap_enforced_at_4000() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    awk 'BEGIN {
        for (i = 1; i <= 4010; i++)
            printf("{\"type\":\"user\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"message\":{\"content\":\"unique corpus filler message number %d for cap testing\"}}\n", i)
    }' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local n
    n=$(grep -c "^\[projA, " "$(corpus_path)")
    assert_eq "4000" "$n" "body should hold exactly the cap" || return 1
    assert_file_contains "$(corpus_path)" "capped at 4000" \
        "stats header should note the cap was hit" || return 1
}

test_empty_transcripts_root_errors() {
    local output ec=0
    output=$(run_build) || ec=$?
    if [ "$ec" -eq 0 ]; then
        echo "  FAIL: expected non-zero exit with no transcripts"; return 1
    fi
    assert_output_contains "$output" "nothing to learn from" \
        "error should say there is nothing to learn from" || return 1
}

test_large_transcript_builds_cleanly() {
    # SIGPIPE probe: total payload well over the 64KB pipe buffer.
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    awk 'BEGIN {
        pad = "steady prose about the work keeps flowing along nicely here"
        big = pad
        while (length(big) < 300) big = big " " pad
        for (i = 1; i <= 300; i++)
            printf("{\"type\":\"user\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"message\":{\"content\":\"message %d says %s\"}}\n", i, big)
    }' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build died on a >64KB transcript"; return 1; }
    assert_file_contains "$(corpus_path)" "message 7 says steady prose" \
        "large-transcript content should land in the corpus" || return 1
}

test_voice_dir_permissions() {
    _skip_on_msys && return 0  # Windows FS doesn't enforce Unix 700 mode bits
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local mode
    mode=$(_file_mode "$CS_SESSIONS_ROOT/.voice")
    assert_eq "700" "$mode" ".voice directory should be private" || return 1
}

test_corrupt_line_skipped_not_fatal() {
    local f; f="$(proj_file projA)"
    add_msg "$f" "first valid message before the corrupt line arrives"
    printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:0' >> "$f"
    add_msg "$f" "second valid message after the corrupt line survives"
    run_build > /dev/null || { echo "  FAIL: build died on a corrupt line"; return 1; }
    assert_file_contains "$(corpus_path)" "first valid message before" \
        "message before the corrupt line should be kept" || return 1
    assert_file_contains "$(corpus_path)" "second valid message after" \
        "message after the corrupt line should be kept" || return 1
    assert_file_contains "$(corpus_path)" "(0 unreadable)" \
        "a file with one bad line is not counted unreadable" || return 1
}

run_test test_typed_string_message_lands_in_corpus
run_test test_array_text_parts_join
run_test test_tool_result_only_entry_dropped
run_test test_meta_and_sidechain_dropped
run_test test_subagent_transcripts_skipped
run_test test_harness_sentinels_dropped
run_test test_short_acks_go_to_appendix
run_test test_paste_over_2000_chars_dropped
run_test test_credential_lines_redacted
run_test test_duplicates_collapse_to_newest
run_test test_newest_first_ordering
run_test test_cap_enforced_at_4000
run_test test_empty_transcripts_root_errors
run_test test_large_transcript_builds_cleanly
run_test test_voice_dir_permissions
run_test test_corrupt_line_skipped_not_fatal

report_results
