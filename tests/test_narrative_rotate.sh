#!/usr/bin/env bash
# ABOUTME: Tests for cs -narrative rotate: byte-budgeted archival of a narrative's oldest sections
# ABOUTME: Pins the cut rule, content addressing, concurrency guards, git commit and union-merge safety

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Every test rotates actor alice's narrative inside one session. CS_ACTOR is
# the top-precedence identity override, so the machine's git identity never
# leaks into the file name under test.
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_ACTOR="alice"
    mkdir -p "$CS_SESSIONS_ROOT"
    SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$SESSION_DIR/.cs"/{local,memory}
    printf '# Session: test-session\n' > "$SESSION_DIR/.cs/README.md"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$SESSION_DIR"
    export CLAUDE_SESSION_META_DIR="$SESSION_DIR/.cs"
    LIVE="$SESSION_DIR/.cs/memory/narrative.alice.md"
    ARCHIVE_DIR="$SESSION_DIR/.cs/narrative-archive/alice"
    # Small budgets so fixtures stay readable: rotate above 4 KiB, keep 2 KiB.
    export CS_NARRATIVE_MAX_BYTES=4096
    export CS_NARRATIVE_KEEP_BYTES=2048
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_ACTOR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_NARRATIVE_MAX_BYTES CS_NARRATIVE_KEEP_BYTES CS_NARRATIVE_ROTATE_MIDPOINT 2>/dev/null || true
}

# A narrative with the header block cs writes (5 frontmatter lines + H1) and N
# dated sections. Section i is "\n## 2026-08-DD — section i\n" + BODY bytes of
# 'x' + "\n": with a one-digit i that is exactly 29 + BODY + 1 bytes (the em dash
# is 3 bytes); section 10 is one byte longer. Line layout: header = lines 1-6,
# section i = lines 6+3i-2 .. 6+3i.
_make_narrative() {  # file, sections, body_bytes
    local file="$1" n="$2" body="$3" i filler
    filler=$(head -c "$body" /dev/zero | tr '\0' 'x')
    {
        printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook for alice.\ntype: narrative\n---\n# Session narrative (alice)\n'
        i=1
        while [ "$i" -le "$n" ]; do
            printf '\n## 2026-08-%02d — section %d\n%s\n' $(( (i % 28) + 1 )) "$i" "$filler"
            i=$((i + 1))
        done
    } > "$file"
}

_bytes() { wc -c < "$1" | tr -d ' '; }

# ============================================================================
# under budget
# ============================================================================

test_rotate_is_a_recognised_subcommand() {
    _make_narrative "$LIVE" 2 100
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -narrative must dispatch" || return 1
}

test_rotate_under_budget_is_a_noop() {
    _make_narrative "$LIVE" 2 100          # ~1.3 KB, under the 4 KiB budget
    local before after output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    after=$(_bytes "$LIVE")
    assert_eq "$before" "$after" "live file must be untouched under budget" || return 1
    assert_output_contains "$output" "nothing to rotate" "must say it did nothing" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "no archive dir is created under budget" || return 1
}

test_rotate_requires_a_session() {
    unset CLAUDE_SESSION_META_DIR
    if "$CS_BIN" -narrative rotate > /dev/null 2>&1; then
        echo "  FAIL: must refuse outside a session"
        return 1
    fi
}

test_rotate_rejects_unknown_subcommand() {
    if "$CS_BIN" -narrative frobnicate > /dev/null 2>&1; then
        echo "  FAIL: unknown subcommand must fail"
        return 1
    fi
}

test_help_shows_narrative() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "-narrative rotate" "help must mention -narrative rotate" || return 1
}

# ============================================================================
# over budget: the cut rule
# ============================================================================

test_rotate_archives_oldest_sections_and_keeps_tail() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "^## 2026-08-09 — section 8$" "section 8 opens the kept tail" || return 1
    assert_file_contains "$LIVE" "section 10$" "the newest section stays" || return 1
    assert_file_not_contains "$LIVE" "section 7$" "section 7 is archived" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "section 1 is archived" || return 1
    local tail_bytes
    tail_bytes=$(( $(_bytes "$LIVE") - $(head -7 "$LIVE" | wc -c | tr -d ' ') ))
    assert_eq "1590" "$tail_bytes" "the tail is exactly sections 8, 9 and 10" || return 1
}

test_rotate_keeps_the_header_block() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local first six
    first=$(head -1 "$LIVE")
    assert_eq "---" "$first" "frontmatter still opens the file" || return 1
    six=$(sed -n '6p' "$LIVE")
    assert_eq "# Session narrative (alice)" "$six" "the H1 is still line 6" || return 1
}

test_rotate_cuts_on_a_heading_boundary() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    # Line 7 is the blank line that precedes every section; line 8 is a heading.
    local seven eight
    seven=$(sed -n '7p' "$LIVE"); eight=$(sed -n '8p' "$LIVE")
    assert_eq "" "$seven" "a blank line separates header and first kept section" || return 1
    case "$eight" in "## "*) ;; *) echo "  FAIL: line 8 is not a heading: $eight"; return 1 ;; esac
}

test_rotate_writes_one_chunk_whose_body_is_verbatim() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local count chunk
    count=$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')
    assert_eq "1" "$count" "exactly one chunk" || return 1
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    # Chunk header is exactly two comment lines and a blank line.
    assert_file_contains "$chunk" "^<!-- rotated from narrative\.alice\.md: 7 sections through 2026-08-08 -->$" "chunk names its origin, count and through-date" || return 1
    # Verbatim: original == header block (lines 1-7) + archived body + kept
    # tail (the rotated live file from line 8), byte for byte.
    { head -7 "$TEST_TMPDIR/original.md"; sed '1,3d' "$chunk"; tail -n +8 "$LIVE"; } > "$TEST_TMPDIR/rebuilt.md"
    if ! cmp -s "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md"; then
        echo "  FAIL: header + chunk body + live tail does not rebuild the original byte for byte"
        cmp "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md" || true
        return 1
    fi
}

test_rotate_reports_what_it_did() {
    _make_narrative "$LIVE" 10 500
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_output_contains "$output" "rotated 7 sections" "reports the section count" || return 1
    assert_output_contains "$output" "narrative-archive/alice/" "names the archive path" || return 1
}

# ============================================================================
# edge cases: a zero-length header, and a pipeline that must not close early
# ============================================================================

# No frontmatter, no H1: the first byte of the file is the first heading, so
# head_end is 0. head -c 0 aborts on BSD, so the live rewrite must not run
# head at all when there is nothing before the first kept section.
test_rotate_handles_a_narrative_with_no_header_block() {
    local n=10 body=500 i filler
    filler=$(head -c "$body" /dev/zero | tr '\0' 'x')
    {
        i=1
        while [ "$i" -le "$n" ]; do
            if [ "$i" -eq 1 ]; then
                printf '## 2026-08-%02d — section %d\n%s\n' $(( (i % 28) + 1 )) "$i" "$filler"
            else
                printf '\n## 2026-08-%02d — section %d\n%s\n' $(( (i % 28) + 1 )) "$i" "$filler"
            fi
            i=$((i + 1))
        done
    } > "$LIVE"
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local first_line
    first_line=$(head -1 "$LIVE")
    case "$first_line" in "## "*) ;; *) echo "  FAIL: live file does not open on a heading: $first_line"; return 1 ;; esac
    local chunk
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    [ -n "$chunk" ] || { echo "  FAIL: no archive chunk was written"; return 1; }
    { sed '1,3d' "$chunk"; cat "$LIVE"; } > "$TEST_TMPDIR/rebuilt.md"
    if ! cmp -s "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md"; then
        echo "  FAIL: chunk body + live file does not rebuild the original byte for byte"
        cmp "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md" || true
        return 1
    fi
}

# Past ~1700 headings, a `... | head -1 | cut ...` pipeline takes SIGPIPE when
# head closes early; that must not leak the rotation snapshot under pipefail.
test_rotate_handles_many_headings_without_a_broken_pipe() {
    _make_narrative "$LIVE" 2000 20
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local leaked
    leaked=$(find "$SESSION_DIR/.cs/memory" -name '.narrative.alice.rotate.*' | wc -l | tr -d ' ')
    assert_eq "0" "$leaked" "no rotation snapshot is left behind" || return 1
}

# ============================================================================
# edge rules
# ============================================================================

test_rotate_keeps_an_oversized_final_section_whole() {
    # 3 sections of 3000 bytes: every section alone exceeds KEEP=2048, so the
    # tail is exactly the last section and the first two are archived.
    _make_narrative "$LIVE" 3 3000
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "section 3$" "the final section is kept" || return 1
    assert_file_not_contains "$LIVE" "section 2$" "section 2 is archived" || return 1
    local heads
    heads=$(grep -c '^## ' "$LIVE")
    assert_eq "1" "$heads" "exactly one section remains" || return 1
}

test_rotate_with_a_single_section_is_a_warned_noop() {
    _make_narrative "$LIVE" 1 6000
    local before output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "a single-section file is left alone" || return 1
    assert_output_contains "$output" "fewer than two sections" "explains why nothing moved" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "no chunk is written" || return 1
}

test_rotate_never_leaves_the_removed_hunk_at_eof() {
    # Whatever the budgets, at least one complete section must follow the cut.
    export CS_NARRATIVE_KEEP_BYTES=1
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local heads
    heads=$(grep -c '^## ' "$LIVE")
    assert_eq "1" "$heads" "the final section survives even with KEEP=1" || return 1
    assert_file_contains "$LIVE" "section 10$" "and it is the newest one" || return 1
}

test_rotate_treats_undated_headings_by_position() {
    # An undated heading in the archived run neither breaks the cut nor the name:
    # through-date comes from the last dated heading before the cut.
    _make_narrative "$LIVE" 10 500
    # Replace section 3's heading with an undated one, keeping the byte count
    # irrelevant: the cut is by position, not by date.
    sed 's/^## 2026-08-04 — section 3$/## undated topic note/' "$LIVE" > "$LIVE.tmp" && mv "$LIVE.tmp" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local chunk
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    assert_file_contains "$chunk" "^## undated topic note$" "the undated section rode along" || return 1
    case "$(basename "$chunk")" in 2026-08-08-*.md) ;; *) echo "  FAIL: chunk name should carry through-date 2026-08-08: $(basename "$chunk")"; return 1 ;; esac
}

test_rotate_names_a_fully_undated_run_undated() {
    _make_narrative "$LIVE" 10 500
    sed 's/^## 2026-08-[0-9][0-9] — section \([1-7]\)$/## topic \1/' "$LIVE" > "$LIVE.tmp" && mv "$LIVE.tmp" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local chunk
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    case "$(basename "$chunk")" in undated-*.md) ;; *) echo "  FAIL: expected undated-<blob>.md, got $(basename "$chunk")"; return 1 ;; esac
}

# ============================================================================
# content addressing
# ============================================================================

_expected_chunk_name() {  # original file (10x500 fixture)
    local blob
    blob=$(sed -n '8,28p' "$1" | git hash-object --stdin | cut -c1-8)
    echo "2026-08-08-$blob.md"
}

test_rotate_chunk_name_is_content_addressed() {
    _make_narrative "$LIVE" 10 500
    local expected
    expected=$(_expected_chunk_name "$LIVE")
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_exists "$ARCHIVE_DIR/$expected" "chunk is named <through-date>-<blob8>.md from its own bytes" || return 1
}

test_rotate_rerun_is_a_noop() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local after output
    after=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_output_contains "$output" "nothing to rotate" "second run finds the file under budget" || return 1
    assert_eq "$after" "$(_bytes "$LIVE")" "second run changes nothing" || return 1
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "still one chunk" || return 1
}

test_rotate_accepts_an_identical_existing_chunk() {
    # Two machines archiving the same prefix produce the same file. Simulate the
    # second machine by restoring the original narrative after a first rotation.
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    cp "$TEST_TMPDIR/original.md" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "the identical chunk is reused, not duplicated" || return 1
    assert_file_contains "$LIVE" "section 8$" "and the live file was rotated again" || return 1
}

test_rotate_refuses_a_differing_chunk_with_the_same_name() {
    _make_narrative "$LIVE" 10 500
    local expected
    expected=$(_expected_chunk_name "$LIVE")
    mkdir -p "$ARCHIVE_DIR"
    printf 'not the same bytes\n' > "$ARCHIVE_DIR/$expected"
    local before output
    before=$(_bytes "$LIVE")
    if output=$("$CS_BIN" -narrative rotate 2>&1); then
        echo "  FAIL: must refuse to overwrite a differing chunk"
        return 1
    fi
    assert_output_contains "$output" "different content" "says why it refused" || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "live file untouched after the refusal" || return 1
    assert_eq "not the same bytes" "$(head -1 "$ARCHIVE_DIR/$expected")" "existing chunk untouched" || return 1
}

# ============================================================================
# concurrency
# ============================================================================

test_rotate_keeps_an_append_that_lands_mid_rotation() {
    _make_narrative "$LIVE" 10 500
    export CS_NARRATIVE_ROTATE_MIDPOINT="printf '\n## 2026-09-01 — late note\nlanded during rotation\n' >> '$LIVE'"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "^## 2026-09-01 — late note$" "the late section is in the live file" || return 1
    assert_file_contains "$LIVE" "landed during rotation" "with its body" || return 1
    assert_file_contains "$LIVE" "section 8$" "and the rotation still happened" || return 1
    assert_file_not_contains "$LIVE" "section 7$" "with section 7 archived" || return 1
}

test_rotate_aborts_when_the_archived_run_changed_underneath() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    export CS_NARRATIVE_ROTATE_MIDPOINT="sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' '$LIVE' > '$LIVE.x' && mv '$LIVE.x' '$LIVE'"
    local output
    if output=$("$CS_BIN" -narrative rotate 2>&1); then
        echo "  FAIL: must abort when the prefix changed"
        return 1
    fi
    assert_output_contains "$output" "changed during rotation" "says what happened" || return 1
    assert_file_contains "$LIVE" "section 2 (edited)" "the edited live file is left as the editor left it" || return 1
    assert_file_contains "$LIVE" "section 1$" "nothing was removed" || return 1
    assert_eq "0" "$(find "$SESSION_DIR/.cs/narrative-archive" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" "the chunk written this run is removed on abort" || return 1
}

test_rotate_abort_leaves_a_preexisting_identical_chunk_alone() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    cp "$TEST_TMPDIR/original.md" "$LIVE"
    export CS_NARRATIVE_ROTATE_MIDPOINT="sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' '$LIVE' > '$LIVE.x' && mv '$LIVE.x' '$LIVE'"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 && { echo "  FAIL: must abort"; return 1; }
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "a chunk that predates this run survives the abort" || return 1
}

test_rotate_leaves_no_temp_files_behind() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local strays
    strays=$(find "$SESSION_DIR/.cs" -name '.*rotate*' -o -name '.body.*' -o -name '*.md.tmp' | wc -l | tr -d ' ')
    assert_eq "0" "$strays" "no snapshot, body or tmp files remain" || return 1
}

# ============================================================================
# git and timeline
# ============================================================================

_init_tracked_repo() {
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
}

test_rotate_commits_live_and_chunk_when_tracked() {
    _make_narrative "$LIVE" 10 500
    _init_tracked_repo
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local subject dirty
    subject=$(git -C "$SESSION_DIR" log -1 --format=%s)
    assert_eq "cs: rotate narrative.alice (7 sections -> narrative-archive)" "$subject" "one commit with the rotation subject" || return 1
    dirty=$(git -C "$SESSION_DIR" status --porcelain -- .cs/memory .cs/narrative-archive)
    assert_eq "" "$dirty" "live file and chunk are both committed" || return 1
}

test_rotate_skips_the_commit_when_cs_is_ignored() {
    _make_narrative "$LIVE" 10 500
    printf '.cs/\n' > "$SESSION_DIR/.gitignore"
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
    local before output after
    before=$(git -C "$SESSION_DIR" rev-list --count HEAD)
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    after=$(git -C "$SESSION_DIR" rev-list --count HEAD)
    assert_eq "$before" "$after" "no commit when the narrative is not tracked" || return 1
    assert_output_contains "$output" "not tracked" "says the archive was left uncommitted" || return 1
    assert_file_contains "$LIVE" "section 8$" "the rotation itself still ran" || return 1
}

test_rotate_outside_git_still_rotates() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "section 8$" "rotation does not need a repo" || return 1
}

test_rotate_appends_a_timeline_event() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_exists "$SESSION_DIR/.cs/timeline.jsonl" "timeline written" || return 1
    if ! jq -e 'select(.event == "narrative_rotated" and .actor == "alice" and .sections == 7)' \
        "$SESSION_DIR/.cs/timeline.jsonl" > /dev/null; then
        echo "  FAIL: expected a narrative_rotated event for alice with 7 sections"
        cat "$SESSION_DIR/.cs/timeline.jsonl"
        return 1
    fi
    local archive
    archive=$(jq -r 'select(.event == "narrative_rotated") | .archive' "$SESSION_DIR/.cs/timeline.jsonl")
    case "$archive" in .cs/narrative-archive/alice/2026-08-08-*.md) ;; *) echo "  FAIL: archive field should be session-relative: $archive"; return 1 ;; esac
}

test_rotate_does_not_splice_onto_a_torn_timeline() {
    _make_narrative "$LIVE" 10 500
    local timeline="$SESSION_DIR/.cs/timeline.jsonl"
    printf '{"ts":"2026-01-01T00:00:00Z","event":"started","session_id":"1111"}\n' > "$timeline"
    printf '{"ts":"2026-01-02T00:00:00Z","event":"rotated","reason":"torn"}' >> "$timeline"
    jsonl_tail_is_torn "$timeline" || { echo "  FAIL: fixture is terminated; the splice cannot happen"; return 1; }
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local events
    events=$(jsonl_events "$timeline")
    assert_output_contains "$events" "rotated" "the torn record survives" || return 1
    assert_output_contains "$events" "narrative_rotated" "and so does the record appended after it" || return 1
}

echo ""
echo "cs narrative rotation tests"
echo "==========================="
echo ""

run_test test_rotate_is_a_recognised_subcommand
run_test test_rotate_under_budget_is_a_noop
run_test test_rotate_requires_a_session
run_test test_rotate_rejects_unknown_subcommand
run_test test_help_shows_narrative
run_test test_rotate_archives_oldest_sections_and_keeps_tail
run_test test_rotate_keeps_the_header_block
run_test test_rotate_cuts_on_a_heading_boundary
run_test test_rotate_writes_one_chunk_whose_body_is_verbatim
run_test test_rotate_reports_what_it_did
run_test test_rotate_handles_a_narrative_with_no_header_block
run_test test_rotate_handles_many_headings_without_a_broken_pipe
run_test test_rotate_keeps_an_oversized_final_section_whole
run_test test_rotate_with_a_single_section_is_a_warned_noop
run_test test_rotate_never_leaves_the_removed_hunk_at_eof
run_test test_rotate_treats_undated_headings_by_position
run_test test_rotate_names_a_fully_undated_run_undated
run_test test_rotate_chunk_name_is_content_addressed
run_test test_rotate_rerun_is_a_noop
run_test test_rotate_accepts_an_identical_existing_chunk
run_test test_rotate_refuses_a_differing_chunk_with_the_same_name
run_test test_rotate_keeps_an_append_that_lands_mid_rotation
run_test test_rotate_aborts_when_the_archived_run_changed_underneath
run_test test_rotate_abort_leaves_a_preexisting_identical_chunk_alone
run_test test_rotate_leaves_no_temp_files_behind
run_test test_rotate_commits_live_and_chunk_when_tracked
run_test test_rotate_skips_the_commit_when_cs_is_ignored
run_test test_rotate_outside_git_still_rotates
run_test test_rotate_appends_a_timeline_event
run_test test_rotate_does_not_splice_onto_a_torn_timeline

report_results
