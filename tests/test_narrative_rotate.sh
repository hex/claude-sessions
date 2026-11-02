#!/usr/bin/env bash
# ABOUTME: Tests for cs -narrative rotate: byte-budgeted archival of a narrative's oldest sections
# ABOUTME: Pins the cut rule, content addressing, concurrency guards, that it makes no commit, and union-merge safety

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
    # The BUDGET guard's own wording, not the bare "nothing to rotate" prefix:
    # the first-section guard further down prints that too, so the loose pin
    # stayed green with the budget check deleted.
    assert_output_contains "$output" "nothing to rotate:.*(budget" "must name the budget it is under" || return 1
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

# The live narrative is rewritten through a temp file; it keeps the mode it
# had. 750 carries an execute bit, which no umask gives a newly written file.
# Claude runs cs -narrative rotate from whatever directory its shell is in. A
# clone can commit a directory laid out like a git repository anywhere in the
# session, with a config naming a clean filter for every file; git, run from
# inside it, would take it for the repository and run that filter on the
# archived text. The rotation runs no command the clone's config names.
test_rotate_runs_no_filter_from_a_repository_layout_it_is_run_in() {
    local g="$SESSION_DIR/vendor/pkg" rc=0
    mkdir -p "$g/objects" "$g/refs" "$g/info"
    printf 'ref: refs/heads/main\n' > "$g/HEAD"
    printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = .\n[filter "x"]\n\tclean = touch %s; cat\n' \
        "$TEST_TMPDIR/filter-ran" > "$g/config"
    printf '* filter=x\n' > "$g/info/attributes"
    _make_narrative "$LIVE" 10 500
    (cd "$g" && "$CS_BIN" -narrative rotate > /dev/null 2>&1) || rc=$?
    assert_file_not_exists "$TEST_TMPDIR/filter-ran" "git must not run the layout's clean filter" || return 1
    assert_eq "0" "$rc" "the rotation succeeds" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the rotation happened" || return 1
}

test_rotate_keeps_the_live_files_mode() {
    _make_narrative "$LIVE" 10 500
    chmod 750 "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the rotation happened" || return 1
    assert_eq "750" "$(_file_mode "$LIVE")" "the live narrative keeps its mode" || return 1
}

# A live narrative linked to a file inside the session is rewritten through
# the link: the target holds the kept tail and the link stays a link. One
# linked outside the session is refused before anything is archived, since a
# clone can commit `narrative.x.md -> ~/.zshrc` (audit M8).
test_rotate_writes_through_a_symlinked_narrative() {
    local real="$SESSION_DIR/notes/narrative.md"
    mkdir -p "$SESSION_DIR/notes"
    _make_narrative "$real" 10 500
    ln -s ../../notes/narrative.md "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    [ -L "$LIVE" ] || { echo "  FAIL: the symlink was replaced by a regular file"; return 1; }
    assert_file_not_contains "$real" "section 1$" "the target was rotated" || return 1
    assert_file_contains "$real" "section 10$" "the target keeps the newest section" || return 1
}

test_rotate_refuses_a_narrative_linked_out_of_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local real="$t/elsewhere/narrative.md" out rc=0 before
    mkdir -p "$t/elsewhere"
    _make_narrative "$real" 10 500
    before=$(cat "$real")
    ln -s "$real" "$LIVE"
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/memory/narrative.alice.md leads to $real, outside the session; cs will not rotate through it." \
        "$out" "the refusal names the link" || return 1
    assert_eq "$before" "$(cat "$real")" "the target is untouched" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive/alice" "nothing was archived" || return 1
}

test_rotate_names_a_narrative_linked_out_by_a_plain_path() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    local out rc=0
    mkdir -p "$t/elsewhere$bad"
    _make_narrative "$t/elsewhere$bad/narrative.md" 10 500
    ln -s "$t/elsewhere$bad/narrative.md" "$LIVE"
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/memory/narrative.alice.md leads to $t/elsewhere$shown/narrative.md, outside the session; cs will not rotate through it." \
        "$out" "the refusal names where the link leads as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
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
    cp "$LIVE" "$TEST_TMPDIR/midpoint.md"
    printf '\n## 2026-09-01 — late note\nlanded during rotation\n' >> "$TEST_TMPDIR/midpoint.md"
    export CS_NARRATIVE_ROTATE_MIDPOINT="$TEST_TMPDIR/midpoint.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "^## 2026-09-01 — late note$" "the late section is in the live file" || return 1
    assert_file_contains "$LIVE" "landed during rotation" "with its body" || return 1
    assert_file_contains "$LIVE" "section 8$" "and the rotation still happened" || return 1
    assert_file_not_contains "$LIVE" "section 7$" "with section 7 archived" || return 1
}

test_rotate_aborts_when_the_archived_run_changed_underneath() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' "$LIVE" > "$TEST_TMPDIR/midpoint.md"
    export CS_NARRATIVE_ROTATE_MIDPOINT="$TEST_TMPDIR/midpoint.md"
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
    sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' "$LIVE" > "$TEST_TMPDIR/midpoint.md"
    export CS_NARRATIVE_ROTATE_MIDPOINT="$TEST_TMPDIR/midpoint.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 && { echo "  FAIL: must abort"; return 1; }
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "a chunk that predates this run survives the abort" || return 1
}

# The midpoint seam is a fixture the live file is replaced with, never code:
# a value that is a command must not run, and is refused as naming no file.
test_rotate_midpoint_seam_never_executes_its_value() {
    _make_narrative "$LIVE" 10 500
    export CS_NARRATIVE_ROTATE_MIDPOINT="touch '$TEST_TMPDIR/executed'"
    local output
    if output=$("$CS_BIN" -narrative rotate 2>&1); then
        assert_not_exists "$TEST_TMPDIR/executed" "the seam's value is not run as a command" || return 1
        echo "  FAIL: a seam value that names no file must be refused"
        return 1
    fi
    assert_not_exists "$TEST_TMPDIR/executed" "the seam's value is not run as a command" || return 1
    assert_output_contains "$output" "CS_NARRATIVE_ROTATE_MIDPOINT names no file" "says why it refused" || return 1
}

test_rotate_leaves_no_temp_files_behind() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local strays
    strays=$(find "$SESSION_DIR/.cs" -name '.*rotate*' -o -name '.body.*' -o -name '*.md.tmp' | wc -l | tr -d ' ')
    assert_eq "0" "$strays" "no snapshot, body or tmp files remain" || return 1
}

test_rotate_refuses_an_unreadable_narrative() {
    _make_narrative "$LIVE" 10 500
    chmod 000 "$LIVE"
    local output status
    output=$("$CS_BIN" -narrative rotate 2>&1)
    status=$?
    chmod 644 "$LIVE"
    [ "$status" -ne 0 ] || { echo "  FAIL: must exit non-zero on an unreadable narrative"; return 1; }
    assert_output_contains "$output" "Cannot read" "a cs error names the failure, not a bare bash message" || return 1
}

test_rotate_refuses_an_unwritable_archive_dir() {
    _make_narrative "$LIVE" 10 500
    mkdir -p "$ARCHIVE_DIR"
    chmod 555 "$ARCHIVE_DIR"
    local output status
    output=$("$CS_BIN" -narrative rotate 2>&1)
    status=$?
    chmod 755 "$ARCHIVE_DIR"
    [ "$status" -ne 0 ] || { echo "  FAIL: must exit non-zero when the archive dir cannot be written"; return 1; }
    assert_output_contains "$output" "Cannot write" "a cs error names the failure" || return 1
    local strays
    strays=$(find "$SESSION_DIR/.cs/memory" -name '.narrative.*.rotate.*' | wc -l | tr -d ' ')
    assert_eq "0" "$strays" "the snapshot is not left behind" || return 1
    assert_file_contains "$LIVE" "section 10$" "the live file is untouched" || return 1
}

# ============================================================================
# git and timeline
# ============================================================================

_init_tracked_repo() {
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
}

# cs -narrative rotate makes no commit (Alex, 2026-10-14: "No commits at
# all"): the trimmed live file and the new archive chunk stay on disk,
# uncommitted, and nothing is staged, so work the user had staged stays
# staged and alone. The output is the one line the wrap reports.
test_rotate_makes_no_commit_and_leaves_the_cut_on_disk() {
    _make_narrative "$LIVE" 10 500
    _init_tracked_repo
    printf 'work in progress\n' > "$SESSION_DIR/user-file.txt"
    git -C "$SESSION_DIR" add -- user-file.txt
    local head output status staged chunk
    head=$(git -C "$SESSION_DIR" rev-parse HEAD)
    output=$("$CS_BIN" -narrative rotate 2>&1) || { echo "  FAIL: rotate failed: $output"; return 1; }
    assert_eq "$head" "$(git -C "$SESSION_DIR" rev-parse HEAD)" "no commit is made" || return 1
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    case "$output" in
        "rotated 7 sections ("*") -> .cs/narrative-archive/alice/$(basename "$chunk"); live file now "*" KB") ;;
        *) echo "  FAIL: the output is not the one rotation line: $output"; return 1 ;;
    esac
    status=$(git -C "$SESSION_DIR" status --porcelain -- .cs/memory .cs/narrative-archive)
    assert_eq " M .cs/memory/narrative.alice.md
?? .cs/narrative-archive/" "$status" "the cut is on disk, uncommitted and unstaged" || return 1
    staged=$(git -C "$SESSION_DIR" diff --cached --name-only)
    assert_eq "user-file.txt" "$staged" "only the user's own staged file is staged" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the rotation happened" || return 1
}

# Mid-merge, the rotation still cuts and stages nothing, so nothing of it
# rides into the user's merge commit.
test_rotate_mid_merge_stages_nothing() {
    _make_narrative "$LIVE" 10 500
    _init_tracked_repo
    git -C "$SESSION_DIR" checkout -q -b other
    printf 'theirs\n' > "$SESSION_DIR/conflict.txt"
    git -C "$SESSION_DIR" add -- conflict.txt
    git -C "$SESSION_DIR" commit -q -m theirs
    git -C "$SESSION_DIR" checkout -q -
    printf 'ours\n' > "$SESSION_DIR/conflict.txt"
    git -C "$SESSION_DIR" add -- conflict.txt
    git -C "$SESSION_DIR" commit -q -m ours
    git -C "$SESSION_DIR" merge other > /dev/null 2>&1 || true
    printf 'resolved\n' > "$SESSION_DIR/conflict.txt"
    git -C "$SESSION_DIR" add -- conflict.txt
    [ -f "$SESSION_DIR/.git/MERGE_HEAD" ] || { echo "  FAIL: fixture did not reach a mid-merge state"; return 1; }
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || { echo "  FAIL: rotate failed: $output"; return 1; }
    assert_eq "conflict.txt" "$(git -C "$SESSION_DIR" diff --cached --name-only)" "only the user's resolution is staged" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the rotation itself still happened" || return 1
    [ -f "$SESSION_DIR/.git/MERGE_HEAD" ] || { echo "  FAIL: the merge is no longer in progress"; return 1; }
}

# However the repo ignores the session's files (all of .cs/, all of it with
# the narrative force-added once, or only the archive), the rotation runs,
# makes no commit, stages nothing and prints only its rotation line.
test_rotate_in_an_ignored_tree_commits_and_stages_nothing() {
    local shape before output after
    for shape in cs-ignored force-added archive-ignored; do
        rm -rf "$SESSION_DIR/.git" "$SESSION_DIR/.gitignore" "$SESSION_DIR/.cs/narrative-archive"
        _make_narrative "$LIVE" 10 500
        case "$shape" in
            cs-ignored)
                printf '.cs/\n' > "$SESSION_DIR/.gitignore"
                (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
                    && git add -A && git commit -q -m init) ;;
            force-added)
                printf '.cs/\n' > "$SESSION_DIR/.gitignore"
                (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
                    && git add -- .gitignore && git add -f -- .cs/memory/narrative.alice.md && git commit -q -m init) ;;
            archive-ignored)
                printf '.cs/narrative-archive/\n' > "$SESSION_DIR/.gitignore"
                (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
                    && git add -- .gitignore .cs/memory/narrative.alice.md && git commit -q -m init) ;;
        esac
        before=$(git -C "$SESSION_DIR" rev-list --count HEAD)
        output=$("$CS_BIN" -narrative rotate 2>&1) || { echo "  FAIL: rotate failed ($shape): $output"; return 1; }
        after=$(git -C "$SESSION_DIR" rev-list --count HEAD)
        assert_eq "$before" "$after" "no commit ($shape)" || return 1
        assert_eq "" "$(git -C "$SESSION_DIR" diff --cached --name-only)" "nothing is staged ($shape)" || return 1
        assert_eq "1" "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" "one output line ($shape): $output" || return 1
        case "$output" in rotated\ 7\ sections*) ;; *) echo "  FAIL: not the rotation line ($shape): $output"; return 1 ;; esac
        assert_file_contains "$LIVE" "section 8$" "the rotation itself still ran ($shape)" || return 1
    done
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

# An encrypted session's narrative lives in a vault behind the .cs/memory
# link. Its rotated sections must stay in the vault too: never in plaintext
# .cs/narrative-archive, which autosave and backups read.
_vault_memory() {
    VAULT="$TEST_TMPDIR/vault"
    mkdir -p "$VAULT"
    mv "$SESSION_DIR/.cs/memory" "$VAULT/memory"
    ln -s "$VAULT/memory" "$SESSION_DIR/.cs/memory"
}

test_rotate_archives_an_encrypted_narrative_behind_private() {
    _vault_memory
    mkdir -p "$VAULT/private"
    ln -s "$VAULT/private" "$SESSION_DIR/.cs/private"
    _mark_hand_made_vault "$SESSION_DIR"
    _make_narrative "$LIVE" 10 500
    local output archive
    output=$("$CS_BIN" -narrative rotate 2>&1) || { echo "$output"; return 1; }
    assert_file_not_contains "$LIVE" "section 7$" "section 7 is archived" || return 1
    assert_eq "1" "$(find "$VAULT/private/narrative-archive/alice" -name '2026-08-08-*.md' | wc -l | tr -d ' ')" \
        "one chunk inside the vault" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "nothing in plaintext .cs/narrative-archive" || return 1
    assert_output_contains "$output" "-> .cs/private/narrative-archive/alice/2026-08-08-" "names the vault path" || return 1
    archive=$(jq -r 'select(.event == "narrative_rotated") | .archive' "$SESSION_DIR/.cs/timeline.jsonl")
    case "$archive" in .cs/private/narrative-archive/alice/2026-08-08-*.md) ;; *) echo "  FAIL: timeline archive: $archive"; return 1 ;; esac
}

test_rotate_uses_a_narrative_archive_linked_into_the_vault() {
    _vault_memory
    mkdir -p "$VAULT/narrative-archive"
    ln -s "$VAULT/narrative-archive" "$SESSION_DIR/.cs/narrative-archive"
    _mark_hand_made_vault "$SESSION_DIR"
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_eq "1" "$(find "$VAULT/narrative-archive/alice" -name '2026-08-08-*.md' | wc -l | tr -d ' ')" \
        "the chunk goes through the existing link" || return 1
}

test_rotate_refuses_an_encrypted_narrative_with_nowhere_private_to_archive() {
    _vault_memory
    _make_narrative "$LIVE" 10 500
    local before output rc=0
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation refuses" || return 1
    assert_output_contains "$output" "narrative.alice.md lives on encrypted storage (.cs/memory is a link), and neither .cs/private nor .cs/narrative-archive is there to hold its archive" \
        "names the missing link" || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "the live file is untouched" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "nothing in plaintext .cs/narrative-archive" || return 1
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

# ============================================================================
# union merge across clones
# ============================================================================

# Origin with the narrative committed under merge=union, plus clones A and B
# that each carry the session env when cs runs inside them.
_make_clones() {
    _make_narrative "$LIVE" 10 500
    # The attributes a real session carries: without union on the timeline, two
    # clones that each create .cs/timeline.jsonl would add/add-conflict.
    printf '.cs/memory/narrative.*.md merge=union\n.cs/timeline.jsonl merge=union\n' > "$SESSION_DIR/.gitattributes"
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
    CLONE_A="$TEST_TMPDIR/clone-a"; CLONE_B="$TEST_TMPDIR/clone-b"
    git clone -q "$SESSION_DIR" "$CLONE_A" && git -C "$CLONE_A" config user.email alice@example.com && git -C "$CLONE_A" config user.name alice
    git clone -q "$SESSION_DIR" "$CLONE_B" && git -C "$CLONE_B" config user.email alice@example.com && git -C "$CLONE_B" config user.name alice
}

# Rotates in a clone, then commits the cut the way its user would: cs makes no
# commit of its own, so what reaches the other clone is the user's commit.
_rotate_in() {  # clone dir, [keep bytes]
    CLAUDE_SESSION_DIR="$1" CLAUDE_SESSION_META_DIR="$1/.cs" CS_NARRATIVE_KEEP_BYTES="${2:-$CS_NARRATIVE_KEEP_BYTES}" \
        "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    git -C "$1" add -- .cs/memory .cs/narrative-archive .cs/timeline.jsonl && git -C "$1" commit -q -m "user commits the rotation"
}

test_rotate_then_peer_append_merges_without_resurrection() {
    _make_clones
    _rotate_in "$CLONE_A" || return 1
    printf '\n## 2026-09-02 — from b\nappended on the other machine\n' >> "$CLONE_B/.cs/memory/narrative.alice.md"
    git -C "$CLONE_B" commit -qam "append on b"
    git -C "$CLONE_A" fetch -q "$CLONE_B" main
    git -C "$CLONE_A" merge -q --no-edit FETCH_HEAD > /dev/null 2>&1 || { echo "  FAIL: merge conflicted"; git -C "$CLONE_A" status --short; return 1; }
    local merged="$CLONE_A/.cs/memory/narrative.alice.md"
    assert_file_not_contains "$merged" "section 1$" "archived sections must not come back" || return 1
    assert_file_not_contains "$merged" "section 7$" "none of them" || return 1
    assert_file_contains "$merged" "section 8$" "the kept tail is intact" || return 1
    assert_file_contains "$merged" "appended on the other machine" "and the peer's append survives" || return 1
    assert_eq "4" "$(grep -c '^## ' "$merged")" "sections 8, 9, 10 and the appended one" || return 1
}

test_two_clones_rotating_at_different_cuts_merge_clean() {
    _make_clones
    _rotate_in "$CLONE_A" || return 1
    # B rotates with a larger tail budget, so its cut is earlier.
    _rotate_in "$CLONE_B" 3000 || return 1
    git -C "$CLONE_A" fetch -q "$CLONE_B" main
    git -C "$CLONE_A" merge -q --no-edit FETCH_HEAD > /dev/null 2>&1 || { echo "  FAIL: merge conflicted"; git -C "$CLONE_A" status --short; return 1; }
    local merged="$CLONE_A/.cs/memory/narrative.alice.md"
    assert_file_not_contains "$merged" "section 1$" "the earliest sections stay archived" || return 1
    assert_file_not_contains "$merged" "section 5$" "B's cut (sections 1-5) is applied" || return 1
    assert_file_contains "$merged" "section 6$" "the less aggressive cut wins: section 6 survives" || return 1
    assert_file_contains "$merged" "section 7$" "and so does section 7" || return 1
    assert_eq "5" "$(grep -c '^## ' "$merged")" "sections 6-10, no duplicated tail" || return 1
    assert_file_contains "$merged" "section 10$" "the newest section survives" || return 1
    # Both chunks exist; neither conflicts with the other (distinct names).
    assert_eq "2" "$(find "$CLONE_A/.cs/narrative-archive/alice" -name '*.md' | wc -l | tr -d ' ')" "two distinct chunks after the merge" || return 1
}

# ============================================================================
# session-scoped form: cs <name> -narrative rotate
# ============================================================================

# Rotation is reachable from outside any session — the picker shells out this
# way, and so does a plain terminal. Drop the ambient session env first so only
# the positional name can resolve the target.
_leave_session() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
}

test_named_rotate_works_from_outside_a_session() {
    _make_narrative "$LIVE" 10 500
    _leave_session
    local output
    output=$("$CS_BIN" test-session -narrative rotate 2>&1) || { echo "  FAIL: $output"; return 1; }
    assert_output_contains "$output" "rotated" "the named form must rotate" || return 1
    assert_dir "$ARCHIVE_DIR" "an archive chunk must be written" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the oldest section must be archived" || return 1
    assert_file_contains "$LIVE" "section 10$" "the newest section must survive" || return 1
}

test_named_rotate_targets_the_named_session_not_the_ambient_one() {
    # An ambient session env must lose to the positional name, or the picker
    # would rotate whichever session its own shell happened to be standing in.
    local other="$CS_SESSIONS_ROOT/other"
    mkdir -p "$other/.cs/local" "$other/.cs/memory"
    _make_narrative "$other/.cs/memory/narrative.alice.md" 10 500
    _make_narrative "$LIVE" 10 500
    export CLAUDE_SESSION_NAME="other"
    export CLAUDE_SESSION_DIR="$other"
    export CLAUDE_SESSION_META_DIR="$other/.cs"
    "$CS_BIN" test-session -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the named session must rotate" || return 1
    assert_file_contains "$other/.cs/memory/narrative.alice.md" "section 1$" "the ambient session must be untouched" || return 1
}

test_named_rotate_on_a_worktree_uses_its_own_narrative() {
    # A worktree session's directory is literally "<base>@<task>" under the
    # sessions root and carries its own .cs — so its narrative is its own,
    # unlike its secrets, which -secrets deliberately routes to the base.
    local wt="$CS_SESSIONS_ROOT/test-session@feat"
    mkdir -p "$wt/.cs/local" "$wt/.cs/memory"
    _make_narrative "$wt/.cs/memory/narrative.alice.md" 10 500
    _make_narrative "$LIVE" 10 500
    _leave_session
    "$CS_BIN" test-session@feat -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_not_contains "$wt/.cs/memory/narrative.alice.md" "section 1$" "the worktree's own narrative must rotate" || return 1
    assert_file_contains "$LIVE" "section 1$" "the base narrative must be untouched" || return 1
}

test_named_rotate_honours_the_caller_actor_over_the_session_identity() {
    # cs_actor_slug puts $CS_ACTOR above the session's pinned local/identity,
    # and the named form keeps that order: you rotate YOUR narrative in that
    # session, never the one that machine last pinned there.
    printf 'bob@example.com\n' > "$SESSION_DIR/.cs/local/identity"
    _make_narrative "$LIVE" 10 500
    _make_narrative "$SESSION_DIR/.cs/memory/narrative.bob-example-com.md" 10 500
    _leave_session
    "$CS_BIN" test-session -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_not_contains "$LIVE" "section 1$" "CS_ACTOR wins: alice's narrative rotates" || return 1
    assert_file_contains "$SESSION_DIR/.cs/memory/narrative.bob-example-com.md" "section 1$" "bob's narrative is untouched" || return 1
}

test_named_rotate_under_budget_is_a_noop() {
    _make_narrative "$LIVE" 2 100
    _leave_session
    local before after output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" test-session -narrative rotate 2>&1) || return 1
    after=$(_bytes "$LIVE")
    assert_eq "$before" "$after" "live file must be untouched under budget" || return 1
    assert_output_contains "$output" "nothing to rotate:.*(budget" "must name the budget it is under" || return 1
}

# Rotating cuts the narrative a running conversation appends to: from inside
# another session that waits for the target to close. A plain terminal and a
# base rotating its own feature are the user, as before.
test_named_rotate_from_another_session_refuses_a_live_target() {
    _make_narrative "$LIVE" 10 500
    local before; before=$(_bytes "$LIVE")
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$SESSION_DIR/.cs/session.lock"
    local output rc=0
    output=$(CLAUDE_SESSION_NAME=other "$CS_BIN" test-session -narrative rotate 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "the rotate exits 1" || return 1
    assert_eq "Error: session other cannot rotate the narrative of session test-session while it is live (pid $live_pid); --force does not override that from another session. Close test-session first." \
        "$output" "the refusal names both sessions" || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "the narrative is untouched" || return 1
    assert_not_exists "$ARCHIVE_DIR" "nothing is archived" || return 1
}

test_named_rotate_from_a_plain_shell_rotates_a_live_session() {
    _make_narrative "$LIVE" 10 500
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$SESSION_DIR/.cs/session.lock"
    _leave_session
    local output rc=0
    output=$("$CS_BIN" test-session -narrative rotate 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "0" "$rc" "a plain terminal rotates it (output: $output)" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "the oldest section is archived" || return 1
}

test_named_rotate_from_a_base_rotates_its_live_feature() {
    local wt="$CS_SESSIONS_ROOT/test-session@feat"
    mkdir -p "$wt/.cs/local" "$wt/.cs/memory"
    _make_narrative "$wt/.cs/memory/narrative.alice.md" 10 500
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$wt/.cs/session.lock"
    local output rc=0
    output=$(CLAUDE_SESSION_NAME=test-session "$CS_BIN" test-session@feat -narrative rotate 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "0" "$rc" "the base rotates its own feature (output: $output)" || return 1
    assert_file_not_contains "$wt/.cs/memory/narrative.alice.md" "section 1$" "the feature's oldest section is archived" || return 1
}

test_named_rotate_refuses_an_unknown_session() {
    _leave_session
    local output
    output=$("$CS_BIN" no-such-session -narrative rotate 2>&1) && { echo "  FAIL: must refuse an absent session"; return 1; }
    assert_output_contains "$output" "No such session" "the error must name the real problem" || return 1
}

# The named form writes into a session without opening it, so the open's scan
# never runs on that path. A committed .cs/timeline.jsonl leading out of the
# session must stop the rotation before the event line is appended to it.
test_named_rotate_refuses_a_timeline_linked_out_of_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local victim="$t/victim" out rc=0
    printf 'USER-OWNED\n' > "$victim"
    _make_narrative "$LIVE" 10 500
    ln -s "$victim" "$SESSION_DIR/.cs/timeline.jsonl"
    _leave_session
    out=$("$CS_BIN" test-session -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/timeline.jsonl is a symlink to $victim, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "the refusal names the link" || return 1
    assert_eq "USER-OWNED" "$(cat "$victim")" "the file outside the session is untouched" || return 1
    assert_not_exists "$ARCHIVE_DIR" "nothing was archived" || return 1
}

# The snapshot rotation copies the narrative into must not have a name a clone
# can guess: with its pid known (exec keeps it), a planted link at that name
# would have cp truncate a file outside the session.
test_rotate_snapshot_name_is_not_predictable() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local victim="$t/victim"
    printf 'USER-OWNED\n' > "$victim"
    _make_narrative "$LIVE" 10 500
    bash -c 'ln -s "$1" "$2/.cs/memory/.narrative.alice.rotate.$$" && exec "$3" -narrative rotate' \
        _ "$victim" "$SESSION_DIR" "$CS_BIN" >/dev/null 2>&1 || true
    assert_eq "USER-OWNED" "$(cat "$victim")" "the file outside the session is untouched" || return 1
}

test_named_rotate_usage_names_the_form_the_user_typed() {
    # The dispatcher's usage line is reached by BOTH forms. Telling someone who
    # correctly named a session to run it "from inside a session" prescribes the
    # precondition this arm exists to remove — and followed literally from
    # another session it would rotate that session's narrative instead.
    _leave_session
    local output
    output=$("$CS_BIN" test-session -narrative frobnicate 2>&1) && { echo "  FAIL: must refuse"; return 1; }
    assert_output_contains "$output" "<name> -narrative rotate" "usage must name the session-scoped form" || return 1
    assert_output_not_contains "$output" "from inside a session" "usage must not prescribe a precondition this form removes" || return 1
}

test_named_rotate_refuses_a_directory_that_is_not_a_session() {
    _leave_session
    mkdir -p "$CS_SESSIONS_ROOT/stray"
    local output
    output=$("$CS_BIN" stray -narrative rotate 2>&1) && { echo "  FAIL: must refuse a non-session directory"; return 1; }
    assert_output_contains "$output" "No such session" "a directory with no .cs is not a session" || return 1
}

# The budget is what a resume carries, and it is duplicated: bin/cs is the built
# artifact, lib/51-narrative.sh the source. A change to one alone drifts silently
# — the tests source the lib while the user runs the binary, so the suite would
# stay green while the shipped default was something else.
test_narrative_budget_is_one_value_in_both_copies() {
    local lib="$SCRIPT_DIR/../lib/02-shared.sh" bin="$SCRIPT_DIR/../bin/cs"
    local lib_max lib_keep bin_max bin_keep
    lib_max=$(grep -o 'CS_NARRATIVE_MAX_DEFAULT=[0-9]*' "$lib" | head -1 | cut -d= -f2)
    lib_keep=$(grep -o 'CS_NARRATIVE_KEEP_DEFAULT=[0-9]*' "$lib" | head -1 | cut -d= -f2)
    bin_max=$(grep -o 'CS_NARRATIVE_MAX_DEFAULT=[0-9]*' "$bin" | head -1 | cut -d= -f2)
    bin_keep=$(grep -o 'CS_NARRATIVE_KEEP_DEFAULT=[0-9]*' "$bin" | head -1 | cut -d= -f2)
    [ -n "$lib_max" ] && [ -n "$bin_max" ] || { echo "  FAIL: budget constant missing from lib or bin"; return 1; }
    assert_eq "$lib_max" "$bin_max" "the max budget must match between lib and bin" || return 1
    assert_eq "$lib_keep" "$bin_keep" "the keep budget must match between lib and bin" || return 1
    # Every resume reads the whole live file, which runs between the tail and
    # the budget, so the pair sets the recurring cost: 128 KiB and 64 KiB put
    # an average resume near 96 KiB. Both sit far under the Read tool's 256 KiB
    # ceiling, and the tail is half the budget so rotation stays infrequent.
    assert_eq "131072" "$lib_max" "the budget is 128 KiB" || return 1
    assert_eq "65536" "$lib_keep" "and the kept tail is half of it" || return 1
    # The hooks carry no copy of their own: both take the budget from
    # cs-shared.sh, build.sh's copy of the lib fragment (test_install pins that
    # file to the build). A numeric default left behind in a hook would keep
    # flagging files that are comfortably under the real budget, a warning the
    # user cannot act on, since cs -narrative rotate would call them a no-op.
    local shared="$SCRIPT_DIR/../hooks/cs-shared.sh" hook
    assert_eq "$lib_max" "$(grep -o 'CS_NARRATIVE_MAX_DEFAULT=[0-9]*' "$shared" | head -1 | cut -d= -f2)" \
        "the hooks' library carries the same budget" || return 1
    for hook in stop-notices.sh session-start.sh; do
        assert_file_contains "$SCRIPT_DIR/../hooks/$hook" '_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT"' \
            "$hook takes the budget from the shared library" || return 1
        if grep -q -e 'NARRATIVE_MAX=[0-9]' -e 'MAX_BYTES:-}" [0-9]' "$SCRIPT_DIR/../hooks/$hook"; then
            echo "  FAIL: $hook carries its own numeric budget default"; return 1
        fi
    done
}

# The validator's zero check runs on the normalised number, not the text: a
# `0` pattern matches one zero and lets `00` through as a zero-byte budget,
# which rotates on every run and warns on every narrative.
test_narrative_budget_reads_any_spelling_of_zero_as_the_default() {
    # shellcheck source=../lib/02-shared.sh
    . "$SCRIPT_DIR/../lib/02-shared.sh"
    assert_eq "5" "$(_narrative_budget 0 5)" "0 falls back" || return 1
    assert_eq "5" "$(_narrative_budget 00 5)" "00 falls back" || return 1
    assert_eq "5" "$(_narrative_budget 000 5)" "000 falls back" || return 1
    assert_eq "8" "$(_narrative_budget 08 5)" "08 is decimal 8" || return 1
    assert_eq "5" "$(_narrative_budget "" 5)" "empty falls back" || return 1
    assert_eq "5" "$(_narrative_budget abc 5)" "non-numeric falls back" || return 1
    assert_eq "5" "$(_narrative_budget 99999999999999999999 5)" "a value past 64 bits falls back, not wraps" || return 1
    assert_eq "5" "$(_narrative_budget 9999999999999999 5)" "16 digits falls back" || return 1
    assert_eq "999999999999999" "$(_narrative_budget 999999999999999 5)" "15 digits is kept" || return 1
}

# The heading scan runs inside rotate_narrative's command substitution, a
# forked copy of the shell, and a bash linked against libintl can die when it
# changes its own locale there. The trace shows every assignment the shell
# itself made while the scan ran; awk gets its C locale as an argument of env.
# Offsets are C-locale byte counts: the em dash (\342\200\224) is 3 bytes.
test_narrative_headings_counts_bytes_and_leaves_the_shells_own_locale_alone() {
    local b utf8 out own expected
    utf8="$(utf8_locale)"
    printf '# T\n\n## a \342\200\224 b\nxx\n## c \342\200\224 d\n' > "$TEST_TMPDIR/headings.md"
    expected="$(printf '5 ## a \342\200\224 b\n19 ## c \342\200\224 d')"
    for b in $(every_bash); do
        out="$(env -i PATH="$PATH" HOME="$HOME" ${utf8:+"LC_ALL=$utf8"} "$b" -c '
            source "$1"; set -x; _narrative_headings "$2"' x "$SCRIPT_DIR/../lib/51-narrative.sh" \
            "$TEST_TMPDIR/headings.md" 2>"$TEST_TMPDIR/trace")"
        assert_eq "$expected" "$out" "$b: each heading at its byte offset" || return 1
        own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
        assert_eq "" "$own" "$b must not assign its own locale inside _narrative_headings" || return 1
    done
}

test_named_rotate_refuses_a_dangling_adopted_link() {
    # An adopted session is a symlink into the user's project. When that project
    # moves, the link dangles — a bare -L guard admits it and the failure then
    # surfaces as the global form's message.
    _leave_session
    ln -s "$TEST_TMPDIR/gone" "$CS_SESSIONS_ROOT/dangling"
    local output
    output=$("$CS_BIN" dangling -narrative rotate 2>&1) && { echo "  FAIL: must refuse a broken link"; return 1; }
    assert_output_contains "$output" "No such session" "a dangling adopted link is not a session" || return 1
}

test_named_rotate_rejects_an_unknown_subcommand() {
    _leave_session
    local output
    output=$("$CS_BIN" test-session -narrative frobnicate 2>&1) && { echo "  FAIL: unknown subcommand must fail"; return 1; }
    # The dispatcher's own refusal, not just a nonzero exit: deleting the whole
    # -narrative arm also exits nonzero, with "Unknown session command".
    assert_output_contains "$output" "Usage: cs -narrative rotate" "the narrative dispatcher must be the one refusing" || return 1
}

test_unknown_session_command_error_lists_narrative() {
    _leave_session
    local output
    output=$("$CS_BIN" test-session -bogus 2>&1) || true
    assert_output_contains "$output" "-narrative" "the session-verb error must list -narrative" || return 1
}

test_help_shows_the_named_narrative_form() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "<name> -narrative rotate" "help must document the named form" || return 1
    # show_verb_help derives from show_help, so the verb's own help answers for
    # both forms in one edit.
    output=$("$CS_BIN" -narrative --help 2>&1)
    assert_output_contains "$output" "<name> -narrative rotate" "cs -narrative --help must show the named form" || return 1
}

echo ""
echo "cs narrative rotation tests"
echo "==========================="
echo ""

# Without a pre-open nothing marks the vault as the user's own, so an archive
# link out of the session is refused before any chunk is written through it.
test_rotate_refuses_an_archive_linked_out_without_a_pre_open() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local out rc=0
    mkdir -p "$t/away"
    ln -s "$t/away" "$SESSION_DIR/.cs/narrative-archive"
    _make_narrative "$LIVE" 10 500
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/narrative-archive/alice leads to $t/away/alice, outside the session; cs will not rotate through it." \
        "$out" "the refusal names the link" || return 1
    assert_eq "" "$(ls -A "$t/away")" "nothing was archived outside" || return 1
    assert_file_contains "$LIVE" "section 1$" "the live narrative is whole" || return 1
}

test_rotate_names_an_archive_linked_out_by_a_plain_path() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    local out rc=0
    mkdir -p "$t/away$bad"
    ln -s "$t/away$bad" "$SESSION_DIR/.cs/narrative-archive"
    _make_narrative "$LIVE" 10 500
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/narrative-archive/alice leads to $t/away$shown/alice, outside the session; cs will not rotate through it." \
        "$out" "the refusal names where the link leads as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_eq "" "$(ls -A "$t/away$bad")" "nothing was archived outside" || return 1
}

# Codex r1 #4: the archive chunk's temp name was predictable (it carries the
# chunk's own hash), so a clone could plant it as a link out of the session.
# The name is learned the way an attacker would: by rotating a copy.
test_rotate_does_not_write_through_a_planted_temp_link() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    _make_narrative "$LIVE" 10 500
    cp -R "$SESSION_DIR" "$TEST_TMPDIR/probe"
    CLAUDE_SESSION_DIR="$TEST_TMPDIR/probe" CLAUDE_SESSION_META_DIR="$TEST_TMPDIR/probe/.cs" \
        "$CS_BIN" -narrative rotate >/dev/null 2>&1 || return 1
    local name; name=$(basename "$(ls "$TEST_TMPDIR/probe/.cs/narrative-archive/alice/"*.md)")
    printf 'USER-OWNED\n' > "$t/victim"
    mkdir -p "$ARCHIVE_DIR"
    ln -s "$t/victim" "$ARCHIVE_DIR/.$name.tmp"
    "$CS_BIN" -narrative rotate >/dev/null 2>&1 || true
    assert_eq "USER-OWNED" "$(cat "$t/victim")" "the file behind the planted temp link is untouched" || return 1
}

# The chunk's final name can be planted the same way, as a link to a
# directory outside, where mv would drop the chunk.
test_rotate_does_not_move_the_chunk_through_a_planted_link() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    _make_narrative "$LIVE" 10 500
    cp -R "$SESSION_DIR" "$TEST_TMPDIR/probe"
    CLAUDE_SESSION_DIR="$TEST_TMPDIR/probe" CLAUDE_SESSION_META_DIR="$TEST_TMPDIR/probe/.cs" \
        "$CS_BIN" -narrative rotate >/dev/null 2>&1 || return 1
    local name; name=$(basename "$(ls "$TEST_TMPDIR/probe/.cs/narrative-archive/alice/"*.md)")
    mkdir -p "$t/away" "$ARCHIVE_DIR"
    ln -s "$t/away" "$ARCHIVE_DIR/$name"
    "$CS_BIN" -narrative rotate >/dev/null 2>&1 || true
    assert_eq "" "$(ls -A "$t/away")" "nothing lands in the directory outside" || return 1
}

# The checks read a path as in the session by its spelling under
# CLAUDE_SESSION_DIR, so a CLAUDE_SESSION_META_DIR naming the same .cs another
# way (relative, through a linked parent, with a ./ in it) is checked as the
# session's own .cs.
test_rotate_checks_a_metadata_dir_spelled_another_way() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local meta out rc
    mkdir -p "$t/away"
    ln -s "$t/away" "$SESSION_DIR/.cs/narrative-archive"
    ln -s "$CS_SESSIONS_ROOT" "$TEST_TMPDIR/sessions-link"
    _make_narrative "$LIVE" 10 500
    for meta in test-session/.cs "$TEST_TMPDIR/sessions-link/test-session/.cs" "$SESSION_DIR/./.cs"; do
        rc=0
        out=$(cd "$CS_SESSIONS_ROOT" && CLAUDE_SESSION_META_DIR="$meta" "$CS_BIN" -narrative rotate 2>&1) || rc=$?
        assert_eq "1" "$rc" "the rotation must fail with the metadata dir spelled $meta" || return 1
        assert_eq "Error: .cs/narrative-archive/alice leads to $t/away/alice, outside the session; cs will not rotate through it." \
            "$out" "the refusal names the link (metadata dir $meta)" || return 1
        assert_eq "" "$(ls -A "$t/away")" "nothing was archived outside (metadata dir $meta)" || return 1
    done
    assert_file_contains "$LIVE" "section 1$" "the live narrative is whole" || return 1
}

# The same for a .cs/memory link out: the refusal comes before the snapshot,
# so no copy of the narrative is left beside it outside the session.
test_rotate_leaves_nothing_beside_a_memory_link_out_with_a_relative_metadata_dir() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local out rc=0 before
    mkdir -p "$t/away" "$SESSION_DIR/.cs/private"
    rmdir "$SESSION_DIR/.cs/memory"
    ln -s "$t/away" "$SESSION_DIR/.cs/memory"
    _make_narrative "$t/away/narrative.alice.md" 10 500
    before=$(cat "$t/away/narrative.alice.md")
    out=$(cd "$CS_SESSIONS_ROOT" && CLAUDE_SESSION_META_DIR=test-session/.cs "$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: .cs/memory/narrative.alice.md leads to $t/away/narrative.alice.md, outside the session; cs will not rotate through it." \
        "$out" "the refusal names the link" || return 1
    assert_eq "narrative.alice.md" "$(ls -A "$t/away")" "no snapshot is left outside" || return 1
    assert_eq "$before" "$(cat "$t/away/narrative.alice.md")" "the narrative is untouched" || return 1
    assert_not_exists "$SESSION_DIR/.cs/private/narrative-archive" "nothing was archived" || return 1
}

# A metadata dir that is not the session's own .cs names a different session
# from the one the checks are made against; cs refuses rather than pick one.
test_rotate_refuses_a_metadata_dir_of_another_session() {
    local other="$CS_SESSIONS_ROOT/other" out rc=0
    mkdir -p "$other/.cs/memory"
    _make_narrative "$other/.cs/memory/narrative.alice.md" 10 500
    _make_narrative "$LIVE" 10 500
    out=$(CLAUDE_SESSION_META_DIR="$other/.cs" "$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: CLAUDE_SESSION_META_DIR is $other/.cs, not $SESSION_DIR/.cs; cs -narrative rotate needs both to name one session." \
        "$out" "the refusal names both directories" || return 1
    assert_file_contains "$other/.cs/memory/narrative.alice.md" "section 1$" "the other narrative is whole" || return 1
    assert_file_contains "$LIVE" "section 1$" "this narrative is whole" || return 1
    assert_not_exists "$other/.cs/narrative-archive" "nothing was archived in the other session" || return 1
}

# mkdir -p makes every level the archive needs, so a link above the levels
# that do not exist yet decides where they land: .cs/private leading out
# would put the archive outside the session. The leave check on the archive
# dir alone cannot see that, because its parent does not exist yet.
test_rotate_refuses_an_archive_dir_mkdir_would_make_outside_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local out rc=0
    mkdir -p "$t/away" "$SESSION_DIR/mem"
    rmdir "$SESSION_DIR/.cs/memory"
    ln -s ../mem "$SESSION_DIR/.cs/memory"
    ln -s "$t/away" "$SESSION_DIR/.cs/private"
    _make_narrative "$LIVE" 10 500
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "cs_mkdir_inside: $SESSION_DIR/.cs/private/narrative-archive/alice leads to $t/away/narrative-archive/alice, outside the session $SESSION_DIR
Error: Cannot write to $SESSION_DIR/.cs/private/narrative-archive/alice" "$out" "the refusal names where mkdir would land" || return 1
    assert_eq "" "$(ls -A "$t/away")" "nothing was made outside" || return 1
    assert_eq "narrative.alice.md" "$(ls -A "$SESSION_DIR/mem")" "no snapshot is left behind" || return 1
    assert_file_contains "$LIVE" "section 1$" "the live narrative is whole" || return 1
}

# The snapshot is made in the directory the live file's name sits in, so a
# .cs/memory link out is refused even when the narrative there links back in.
test_rotate_refuses_a_memory_dir_linked_out_for_its_snapshot() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local out rc=0
    mkdir -p "$t/away" "$SESSION_DIR/notes" "$SESSION_DIR/.cs/private"
    _make_narrative "$SESSION_DIR/notes/narrative.md" 10 500
    rmdir "$SESSION_DIR/.cs/memory"
    ln -s "$t/away" "$SESSION_DIR/.cs/memory"
    ln -s "$SESSION_DIR/notes/narrative.md" "$t/away/narrative.alice.md"
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "rotate_narrative: $SESSION_DIR/.cs/memory leads to $t/away, outside the session $SESSION_DIR
Error: Cannot write to $SESSION_DIR/.cs/memory" "$out" "the refusal names the link" || return 1
    assert_eq "narrative.alice.md" "$(ls -A "$t/away")" "no snapshot is made outside" || return 1
    assert_file_contains "$SESSION_DIR/notes/narrative.md" "section 1$" "the narrative is whole" || return 1
}

# A rewrite that fails takes back what the rotation wrote: the snapshot and
# the chunk it made, so the archive never holds sections the live file kept.
test_rotate_takes_back_its_snapshot_and_chunk_when_the_rewrite_fails() {
    local out rc=0
    mkdir -p "$SESSION_DIR/notes"
    _make_narrative "$SESSION_DIR/notes/narrative.md" 10 500
    ln -s ../../notes/narrative.md "$LIVE"
    chmod 555 "$SESSION_DIR/notes"
    out=$("$CS_BIN" -narrative rotate 2>&1) || rc=$?
    chmod 755 "$SESSION_DIR/notes"
    assert_eq "1" "$rc" "the rotation must fail" || return 1
    assert_eq "Error: could not rewrite narrative.alice.md" "$(printf '%s\n' "$out" | tail -1)" "names the failed rewrite" || return 1
    assert_eq "" "$(find "$SESSION_DIR/.cs/memory" -name '.narrative.*.rotate.*')" "the snapshot is not left behind" || return 1
    assert_eq "" "$(ls -A "$ARCHIVE_DIR")" "the chunk is taken back" || return 1
    assert_file_contains "$SESSION_DIR/notes/narrative.md" "section 1$" "the narrative is whole" || return 1
}

run_test test_rotate_is_a_recognised_subcommand
run_test test_rotate_under_budget_is_a_noop
run_test test_rotate_requires_a_session
run_test test_rotate_rejects_unknown_subcommand
run_test test_help_shows_narrative
run_test test_rotate_archives_oldest_sections_and_keeps_tail
run_test test_rotate_runs_no_filter_from_a_repository_layout_it_is_run_in
run_test test_rotate_keeps_the_live_files_mode
run_test test_rotate_writes_through_a_symlinked_narrative
run_test test_rotate_refuses_a_narrative_linked_out_of_the_session
run_test test_rotate_names_a_narrative_linked_out_by_a_plain_path
run_test test_rotate_refuses_an_archive_linked_out_without_a_pre_open
run_test test_rotate_names_an_archive_linked_out_by_a_plain_path
run_test test_rotate_does_not_write_through_a_planted_temp_link
run_test test_rotate_does_not_move_the_chunk_through_a_planted_link
run_test test_rotate_checks_a_metadata_dir_spelled_another_way
run_test test_rotate_leaves_nothing_beside_a_memory_link_out_with_a_relative_metadata_dir
run_test test_rotate_refuses_a_metadata_dir_of_another_session
run_test test_rotate_refuses_an_archive_dir_mkdir_would_make_outside_the_session
run_test test_rotate_refuses_a_memory_dir_linked_out_for_its_snapshot
run_test test_rotate_takes_back_its_snapshot_and_chunk_when_the_rewrite_fails
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
run_test test_rotate_midpoint_seam_never_executes_its_value
run_test test_rotate_leaves_no_temp_files_behind
run_test test_rotate_refuses_an_unreadable_narrative
run_test test_rotate_refuses_an_unwritable_archive_dir
run_test test_rotate_makes_no_commit_and_leaves_the_cut_on_disk
run_test test_rotate_mid_merge_stages_nothing
run_test test_rotate_in_an_ignored_tree_commits_and_stages_nothing
run_test test_rotate_outside_git_still_rotates
run_test test_rotate_appends_a_timeline_event
run_test test_rotate_archives_an_encrypted_narrative_behind_private
run_test test_rotate_uses_a_narrative_archive_linked_into_the_vault
run_test test_rotate_refuses_an_encrypted_narrative_with_nowhere_private_to_archive
run_test test_rotate_does_not_splice_onto_a_torn_timeline
run_test test_rotate_then_peer_append_merges_without_resurrection
run_test test_two_clones_rotating_at_different_cuts_merge_clean
run_test test_named_rotate_works_from_outside_a_session
run_test test_named_rotate_targets_the_named_session_not_the_ambient_one
run_test test_named_rotate_on_a_worktree_uses_its_own_narrative
run_test test_named_rotate_honours_the_caller_actor_over_the_session_identity
run_test test_named_rotate_under_budget_is_a_noop
run_test test_named_rotate_from_another_session_refuses_a_live_target
run_test test_named_rotate_from_a_plain_shell_rotates_a_live_session
run_test test_named_rotate_from_a_base_rotates_its_live_feature
run_test test_named_rotate_refuses_an_unknown_session
run_test test_named_rotate_refuses_a_timeline_linked_out_of_the_session
run_test test_rotate_snapshot_name_is_not_predictable
run_test test_named_rotate_usage_names_the_form_the_user_typed
run_test test_named_rotate_refuses_a_directory_that_is_not_a_session
run_test test_narrative_budget_is_one_value_in_both_copies
run_test test_narrative_budget_reads_any_spelling_of_zero_as_the_default
run_test test_narrative_headings_counts_bytes_and_leaves_the_shells_own_locale_alone
run_test test_named_rotate_refuses_a_dangling_adopted_link
run_test test_named_rotate_rejects_an_unknown_subcommand
run_test test_unknown_session_command_error_lists_narrative
run_test test_help_shows_the_named_narrative_form

report_results
