#!/usr/bin/env bash
# ABOUTME: Tests for `cs -lint` — deterministic prose linter that flags lexical
# ABOUTME: AI-slop tells (em-dashes, curated banned phrases) outside code fences

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Run the linter; sets OUT (combined stdout+stderr) and RC (exit code)
lint() {
    OUT=$("$CS_BIN" -lint "$@" 2>&1) && RC=0 || RC=$?
}

test_clean_prose_exits_zero() {
    local f="$TEST_TMPDIR/clean.md"
    cat > "$f" <<'PROSE'
# Notes

The team shipped the parser on Tuesday. It reads the config and validates
each field before the run starts.
PROSE
    lint "$f"
    assert_eq "0" "$RC" "clean prose should exit 0" || return 1
}

test_em_dash_flagged() {
    local f="$TEST_TMPDIR/dash.md"
    printf '%s\n' "Title" "The fix was simple — we named the actor." > "$f"
    lint "$f"
    assert_eq "1" "$RC" "em-dash should exit 1" || return 1
    assert_output_contains "$OUT" "em-dash" "should name the em-dash violation" || return 1
}

test_em_dash_reports_line_number() {
    local f="$TEST_TMPDIR/dash2.md"
    printf '%s\n' "Clean first line." "Second line has an em-dash — here." > "$f"
    lint "$f"
    assert_output_contains "$OUT" ":2:" "violation should cite line 2" || return 1
}

test_banned_phrase_flagged() {
    local f="$TEST_TMPDIR/phrase.md"
    printf '%s\n' "It's worth noting that the cache is warm." > "$f"
    lint "$f"
    assert_eq "1" "$RC" "banned phrase should exit 1" || return 1
    assert_output_contains "$OUT" "worth noting" "should echo the matched phrase" || return 1
}

test_phrase_case_insensitive() {
    local f="$TEST_TMPDIR/case.md"
    printf '%s\n' "AT THE END OF THE DAY the build passed." > "$f"
    lint "$f"
    assert_eq "1" "$RC" "phrase match should be case-insensitive" || return 1
}

test_em_dash_in_code_fence_ignored() {
    local f="$TEST_TMPDIR/fence.md"
    cat > "$f" <<'PROSE'
Run the command below.

```
echo "range 1 — 9"
```

The output is clean prose.
PROSE
    lint "$f"
    assert_eq "0" "$RC" "em-dash inside a fenced code block should be ignored" || return 1
}

test_phrase_in_code_fence_ignored() {
    local f="$TEST_TMPDIR/fence2.md"
    cat > "$f" <<'PROSE'
Sample output:

```
log: it's worth noting the retry count
```

Done.
PROSE
    lint "$f"
    assert_eq "0" "$RC" "banned phrase inside a fence should be ignored" || return 1
}

test_missing_file_exits_2() {
    lint "$TEST_TMPDIR/does-not-exist.md"
    assert_eq "2" "$RC" "missing file should exit 2 (distinct from a violation)" || return 1
}

test_multiple_files_one_dirty_exit_1() {
    local a="$TEST_TMPDIR/a.md" b="$TEST_TMPDIR/b.md"
    printf '%s\n' "All clean here." > "$a"
    printf '%s\n' "Needless to say, it worked." > "$b"
    lint "$a" "$b"
    assert_eq "1" "$RC" "one dirty file among many should exit 1" || return 1
    assert_output_contains "$OUT" "b.md" "should name the dirty file" || return 1
}

test_multiple_files_all_clean_exit_0() {
    local a="$TEST_TMPDIR/c.md" b="$TEST_TMPDIR/d.md"
    printf '%s\n' "The runner starts the job." > "$a"
    printf '%s\n' "The reader parses each row." > "$b"
    lint "$a" "$b"
    assert_eq "0" "$RC" "all-clean set should exit 0" || return 1
}

test_expanded_phrase_flagged() {
    local f="$TEST_TMPDIR/exp.md"
    printf '%s\n' "Here's the thing about the parser." > "$f"
    lint "$f"
    assert_eq "1" "$RC" "expanded blocklist phrase should be flagged" || return 1
}

test_single_word_adverbs_not_flagged() {
    # Design boundary: single-word adverbs and lazy extremes are judge-only, never
    # blocked deterministically (they occur in nearly all legitimate prose).
    local f="$TEST_TMPDIR/adv.md"
    printf '%s\n' "We just ran it and it actually passed every single time, always." > "$f"
    lint "$f"
    assert_eq "0" "$RC" "single-word adverbs/extremes must not be blocked by cs -lint" || return 1
}

echo "Running prose-lint tests..."
run_test test_clean_prose_exits_zero
run_test test_em_dash_flagged
run_test test_em_dash_reports_line_number
run_test test_banned_phrase_flagged
run_test test_phrase_case_insensitive
run_test test_em_dash_in_code_fence_ignored
run_test test_phrase_in_code_fence_ignored
run_test test_missing_file_exits_2
run_test test_multiple_files_one_dirty_exit_1
run_test test_multiple_files_all_clean_exit_0
run_test test_expanded_phrase_flagged
run_test test_single_word_adverbs_not_flagged

report_results
