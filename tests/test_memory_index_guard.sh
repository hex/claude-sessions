#!/usr/bin/env bash
# ABOUTME: Tests for hooks/memory-index-guard.sh, the guard on /wrap's memory-pass MEMORY.md rewrites
# ABOUTME: Covers removed and dangling pointers, the memory archive, the byte and line budgets, a missing snapshot, and restore

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

GUARD="$SCRIPT_DIR/../hooks/memory-index-guard.sh"

# A session root holding a MEMORY.md with two pointers and the two entries
# they name; the guard runs from it.
_guard_session() {
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/memory" "$SESSION/.cs/local"
    INDEX="$SESSION/.cs/memory/MEMORY.md"
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never do alpha twice
- [Beta fact](project_beta.md): beta only runs on Tuesdays
EOF
    : > "$SESSION/.cs/memory/feedback_alpha.md"
    : > "$SESSION/.cs/memory/project_beta.md"
}

_guard() {  # subcommand...
    ( cd "$SESSION" && bash "$GUARD" "$@" )
}

test_check_fails_when_a_link_is_removed() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail when a pointer's link is gone" || return 1
    assert_output_contains "$out" "removed: project_beta.md" \
        "check must name the link that was removed" || return 1
}

# Appends one pointer line padded so MEMORY.md ends at exactly $1 bytes, and
# the entry it names.
_pad_index_to() {  # bytes
    local head='- [Pad](project_pad.md): ' size fill
    : > "$SESSION/.cs/memory/project_pad.md"
    size=$(wc -c < "$INDEX")
    fill=$(( $1 - size - ${#head} - 1 ))
    { printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' x; printf '\n'; } >> "$INDEX"
    assert_eq "$1" "$(wc -c < "$INDEX" | tr -d ' ')" "fixture must be $1 bytes" || return 1
}

test_check_fails_over_the_byte_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    _pad_index_to 24401 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail one byte past the budget" || return 1
    assert_output_contains "$out" "over budget: 24401 bytes > 24400" \
        "check must print the size against the budget" || return 1
}

# Claude Code also stops loading MEMORY.md at a line limit, and every line
# counts toward it: blank lines, headings, and a last line with no newline,
# which wc -l would not count.
test_check_fails_over_the_line_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    local i out rc=0
    for i in $(seq 1 97); do printf '\n## Heading %s\n' "$i"; done >> "$INDEX"
    assert_eq 196 "$(wc -l < "$INDEX" | tr -d ' ')" "fixture must be 196 lines" || return 1
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "check must pass at the line budget: $out" || return 1
    assert_output_contains "$out" "MEMORY.md: 196/196 lines" \
        "a pass must print the line count against the budget" || return 1
    printf '%s' '## Tail with no newline' >> "$INDEX"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail one line past the budget" || return 1
    assert_output_contains "$out" "over budget: 197 lines > 196" \
        "check must count the last line with no newline" || return 1
}

# Claude Code counts lines after turning a CRLF, a lone CR, U+2028 and U+2029
# each into one line break, so check counts each of them as one too.
test_check_counts_the_line_breaks_claude_code_counts() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    local i seps="" out rc=0
    for i in $(seq 3 190); do printf '## Heading %s\n' "$i"; done >> "$INDEX"
    for i in $(seq 1 12); do seps="${seps}x"$'\342\200\250'"y"$'\r'; done
    printf '%s\n' "$seps" >> "$INDEX"
    assert_eq 191 "$(wc -l < "$INDEX" | tr -d ' ')" "fixture must be 191 newline-ended lines" || return 1
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail past the budget Claude Code counts" || return 1
    assert_eq "over budget: 214 lines > 196" "$(grep '^over budget' <<< "$out")" \
        "a lone CR and U+2028 each count as a line break, a CRLF as one" || return 1
    printf '%s\n' "a"$'\342\200\251'"b" >> "$INDEX"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check still fails" || return 1
    assert_eq "MEMORY.md: 216/196 lines" "$(grep '^MEMORY.md: .* lines$' <<< "$out")" \
        "U+2029 counts as a line break" || return 1
}

# step 6 runs check once per sweep even when nothing was written; with no
# snapshot there is nothing to compare, and that must never read as a pass.
test_check_without_a_snapshot_is_an_error() {
    _guard_session
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with no snapshot must not pass" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot; run snapshot before editing MEMORY.md" \
        "the error must name the missing snapshot and the fix" || return 1
}

test_check_without_the_index_is_an_error() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    rm "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with MEMORY.md gone must not pass" || return 1
    assert_output_contains "$out" "no .cs/memory/MEMORY.md here; run from the session root" \
        "the error must name the missing index" || return 1
}

# Rewriting a pointer shorter and adding a new one is what step 6 asks for.
test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never alpha twice
- [Beta fact](project_beta.md): beta only on Tuesdays
- [Gamma](reference_gamma.md): the gamma board
EOF
    : > "$SESSION/.cs/memory/reference_gamma.md"
    _pad_index_to 24400 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a rewrite keeping every link within budget must pass: $out" || return 1
    assert_output_contains "$out" "MEMORY.md: 24400/24400 bytes" \
        "a pass must still print the size against the budget" || return 1
}

# The budget is bytes: an em dash is three bytes and one character, so a
# character count would pass a file that Claude Code truncates.
test_check_counts_bytes_not_characters() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Delta](project_delta.md): delta — then epsilon' >> "$INDEX"
    : > "$SESSION/.cs/memory/project_delta.md"
    _pad_index_to 24401 || return 1
    local chars
    chars=$(LC_ALL=en_US.UTF-8 wc -m < "$INDEX" | tr -d ' ')
    [ "$chars" -le 24400 ] || { echo "  FAIL: fixture must fit the budget in characters, has $chars"; return 1; }
    local rc=0
    _guard check > /dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "24401 bytes must fail even when the characters fit" || return 1
}

# restore puts back exactly what snapshot took, byte for byte: cs never
# rewrites MEMORY.md content of its own.
test_restore_puts_back_the_snapshot_byte_for_byte() {
    _guard_session
    printf '%s\n' '- [Delta](project_delta.md): delta — no trailing newline next' >> "$INDEX"
    printf '%s' 'last line without newline' >> "$INDEX"
    cp "$INDEX" "$TEST_TMPDIR/original"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md)' > "$INDEX"
    _guard restore > /dev/null || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: restore must reproduce the snapshot exactly"; return 1; }
}

test_restore_without_a_snapshot_leaves_the_index_alone() {
    _guard_session
    cp "$INDEX" "$TEST_TMPDIR/original"
    local out rc=0
    out=$(_guard restore 2>&1) || rc=$?
    assert_eq 2 "$rc" "restore with no snapshot must fail" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot" \
        "the error must name the missing snapshot" || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: a failed restore must not touch MEMORY.md"; return 1; }
}

test_unknown_subcommand_prints_usage() {
    _guard_session
    local out rc=0
    out=$(_guard verify 2>&1) || rc=$?
    assert_eq 2 "$rc" "an unknown subcommand must fail" || return 1
    assert_output_contains "$out" "usage: memory-index-guard.sh snapshot|check|restore|refs" \
        "the error must list the subcommands" || return 1
}

# A pointer is its first link; a link inside its summary is supporting text.
test_check_passes_when_a_supporting_link_is_dropped() {
    _guard_session
    printf '%s\n' '- [Gamma](project_gamma.md): see [vendor docs](https://example.com/docs)' >> "$INDEX"
    : > "$SESSION/.cs/memory/project_gamma.md"
    _guard snapshot > /dev/null || return 1
    sed -i.bak 's|: see \[vendor docs\](https://example.com/docs)|: vendor configuration|' "$INDEX"
    grep -q 'vendor configuration' "$INDEX" || { echo "  FAIL: fixture edit did not land"; return 1; }
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "dropping a supporting link keeps every pointer: $out" || return 1
}

# Merging two pointers into one is forbidden even when the merged line still
# mentions the other entry's file.
test_check_fails_when_two_pointers_are_merged() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): Tuesdays; see [Alpha](feedback_alpha.md)' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a merged pointer must fail" || return 1
    assert_output_contains "$out" "removed: feedback_alpha.md" \
        "check must name the pointer the merge removed" || return 1
}

# Every entry in a memory bucket needs a pointer, including one this sweep
# wrote after the snapshot: an unindexed entry is never read again.
test_check_fails_on_an_unindexed_bucket_entry() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    : > "$SESSION/.cs/memory/project_delta.md"
    : > "$SESSION/.cs/memory/notes.md"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a bucket entry with no pointer must fail" || return 1
    assert_output_contains "$out" "unindexed: project_delta.md" \
        "check must name the entry with no pointer" || return 1
    assert_output_not_contains "$out" "notes.md" \
        "a file outside the four buckets is not an entry" || return 1
}

# A pointer whose entry file is not in .cs/memory leads nowhere: Claude Code
# loads the pointer, and the file it names cannot be read.
test_check_fails_on_a_pointer_to_a_missing_entry() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Gone](project_gone.md): an entry that is not there' >> "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a pointer to a missing entry must fail" || return 1
    assert_eq "dangling: project_gone.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check must name the pointer with no entry, and nothing else" || return 1
}

# A pointer names an entry file only when its target is a bare file name
# ending in .md, with no / and no :. A URL names none, whatever it ends in,
# and neither does a link to a section of a file; in MEMORY.md or in the
# archive, check passes them.
test_check_passes_a_pointer_that_names_no_entry_file() {
    _guard_session
    _guard_archive
    printf '%s\n' '- [Docs](https://example.com/docs): vendor docs' \
        '- [Usage](project_tool.md#usage): the usage section' >> "$INDEX"
    printf '%s\n' '- [Board](https://example.com/board.md): the old board' >> "$ARCHIVE"
    _guard snapshot > /dev/null || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a pointer that names no entry file must pass: $out" || return 1
    assert_eq "" "$(grep -v '^MEMORY.md: ' <<< "$out")" "check names nothing" || return 1
}

# The archive index: an ordinary reference entry whose body lists pointers in
# MEMORY.md's own shape, one of them to an entry archived by an earlier sweep,
# with a pointer to it in MEMORY.md.
_guard_archive() {
    ARCHIVE="$SESSION/.cs/memory/reference_memory_archive.md"
    cat > "$ARCHIVE" << 'EOF'
---
name: memory-archive
description: "Pointers moved out of MEMORY.md; each entry still applies when its subject comes up"
metadata:
  type: reference
---

- [Old study](project_old.md): a study that closed
EOF
    : > "$SESSION/.cs/memory/project_old.md"
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): pointers moved out of this index' >> "$INDEX"
}

# The /wrap pass may move a pointer line verbatim from MEMORY.md into the
# archive: a move, not a loss. check names it and passes, and an entry whose
# only pointer is in the archive is indexed.
test_check_passes_a_pointer_moved_to_the_archive() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): beta only runs on Tuesdays' >> "$ARCHIVE"
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' \
        '- [Memory archive](reference_memory_archive.md): pointers moved out of this index' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a pointer moved to the archive must pass: $out" || return 1
    assert_eq "demoted: project_beta.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the moved pointer, and nothing else" || return 1
}

# A pointer in both files is a move left half done.
test_check_fails_on_a_pointer_in_the_index_and_the_archive() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): beta only runs on Tuesdays' >> "$ARCHIVE"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a pointer in both files must fail" || return 1
    assert_eq "duplicate: project_beta.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the pointer in both files, and nothing else" || return 1
}

# The archive is read only through its pointer in MEMORY.md; one inside the
# archive itself does not count.
test_check_fails_when_the_index_has_no_pointer_to_the_archive() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' \
        '- [Beta fact](project_beta.md): beta only runs on Tuesdays' > "$INDEX"
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): pointers moved out of this index' >> "$ARCHIVE"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "an archive with no pointer in MEMORY.md must fail" || return 1
    assert_eq "removed: reference_memory_archive.md
unindexed: reference_memory_archive.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the archive as removed and unindexed, and nothing else" || return 1
}

test_check_fails_on_an_archive_pointer_to_a_missing_entry() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Lost](project_lost.md): not there' >> "$ARCHIVE"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "an archive pointer to a missing entry must fail" || return 1
    assert_eq "dangling: project_lost.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the archive pointer with no entry, and nothing else" || return 1
}

# snapshot keeps the archive too: a pointer that was in the archive and is now
# in neither file is lost, as one lost from MEMORY.md is, whether or not its
# entry is a bucket file and whether or not the file is still there.
test_check_fails_on_a_pointer_dropped_from_the_archive() {
    _guard_session
    _guard_archive
    printf '%s\n' "- [Narrative; bob](narrative.bob.md): bob's notebook" >> "$ARCHIVE"
    : > "$SESSION/.cs/memory/narrative.bob.md"
    _guard snapshot > /dev/null || return 1
    grep -v 'narrative\.bob\.md' "$ARCHIVE" > "$TEST_TMPDIR/archive" && cp "$TEST_TMPDIR/archive" "$ARCHIVE"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a pointer dropped from the archive must fail" || return 1
    assert_eq "removed: narrative.bob.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the pointer dropped from the archive, and nothing else" || return 1
}

test_check_fails_on_an_archived_pointer_dropped_with_its_entry() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    grep -v 'project_old\.md' "$ARCHIVE" > "$TEST_TMPDIR/archive" && cp "$TEST_TMPDIR/archive" "$ARCHIVE"
    rm "$SESSION/.cs/memory/project_old.md"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "an archived pointer dropped with its entry must fail" || return 1
    assert_eq "removed: project_old.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the pointer dropped from the archive, and nothing else" || return 1
}

# restore puts back MEMORY.md alone; a pointer this sweep moved to the archive
# is then in both files, and check says so.
test_restore_after_a_move_leaves_the_pointer_in_both_files() {
    _guard_session
    _guard_archive
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): beta only runs on Tuesdays' >> "$ARCHIVE"
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' \
        '- [Memory archive](reference_memory_archive.md): pointers moved out of this index' > "$INDEX"
    cp "$ARCHIVE" "$TEST_TMPDIR/archive"
    _guard restore > /dev/null || return 1
    cmp -s "$TEST_TMPDIR/archive" "$ARCHIVE" || { echo "  FAIL: restore must leave the archive as it was"; return 1; }
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "the pointer is in both files after restore" || return 1
    assert_eq "duplicate: project_beta.md" "$(grep -v '^MEMORY.md: ' <<< "$out")" \
        "check names the pointer the restore put back" || return 1
}

# .cs/memory is tracked, so a clone chooses the entry file names and the
# pointers MEMORY.md holds, and a name can carry a terminal escape: a raw ESC
# or BEL byte, or backslash text echo -e would turn into one. check names a
# removed pointer, a pointer with no entry and an unindexed entry as plain
# names, each character a plain name lacks replaced by _.
test_check_names_a_pointer_and_an_entry_as_plain_names() {
    _guard_session
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m out rc=0
    printf '%s\n' "- [Odd](feedback_o$bad.md): odd" >> "$INDEX"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' \
        '- [Beta fact](project_beta.md): beta only runs on Tuesdays' > "$INDEX"
    : > "$SESSION/.cs/memory/project_p$bad.md"
    printf '%s\n' "- [Dangling](project_d$bad.md): no entry" >> "$INDEX"
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check fails" || return 1
    assert_eq "dangling: project_d$shown.md" "$(grep '^dangling:' <<< "$out")" \
        "check names the pointer with no entry as a plain name" || return 1
    assert_eq "removed: feedback_o$shown.md" "$(grep '^removed:' <<< "$out")" \
        "check names the removed pointer as a plain name" || return 1
    assert_eq "unindexed: project_p$shown.md" "$(grep '^unindexed:' <<< "$out")" \
        "check names the unindexed entry as a plain name" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches Claude" || return 1
}

# A fresh session has no MEMORY.md until Claude Code writes the first entry,
# so the first sweep snapshots nothing and must still reach a passing check.
test_first_sweep_snapshots_an_absent_index_as_empty() {
    _guard_session
    rm "$INDEX" "$SESSION/.cs/memory/feedback_alpha.md" "$SESSION/.cs/memory/project_beta.md"
    local out rc=0
    out=$(_guard snapshot 2>&1) || rc=$?
    assert_eq 0 "$rc" "snapshot with no MEMORY.md yet must succeed: $out" || return 1
    [ -f "$SESSION/.cs/local/memory-index.snapshot" ] && [ ! -s "$SESSION/.cs/local/memory-index.snapshot" ] \
        || { echo "  FAIL: the snapshot of an absent index must be an empty file"; return 1; }
    : > "$SESSION/.cs/memory/project_first.md"
    printf '%s\n' '- [First](project_first.md): the first entry' > "$INDEX"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a first sweep that indexes its entry must pass: $out" || return 1
    : > "$SESSION/.cs/memory/project_second.md"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a first sweep still fails on an unindexed entry" || return 1
    assert_output_contains "$out" "unindexed: project_second.md" \
        "check must name the entry with no pointer" || return 1
}

# An absent index is only a fresh session inside a session root; anywhere else
# snapshot must refuse rather than record an empty index.
test_snapshot_outside_a_session_root_is_an_error() {
    mkdir -p "$TEST_TMPDIR/elsewhere"
    local out rc=0
    out=$( cd "$TEST_TMPDIR/elsewhere" && bash "$GUARD" snapshot 2>&1 ) || rc=$?
    assert_eq 2 "$rc" "snapshot outside a session root must fail" || return 1
    assert_output_contains "$out" "no .cs/memory here; run from the session root" \
        "the error must name the missing directory" || return 1
    [ ! -e "$TEST_TMPDIR/elsewhere/.cs" ] || { echo "  FAIL: snapshot must not create .cs outside a session root"; return 1; }
}

test_check_with_an_unreadable_snapshot_is_an_error() {
    [ "$(id -u)" -ne 0 ] || return 77
    _guard_session
    _guard snapshot > /dev/null || return 1
    chmod 000 "$SESSION/.cs/local/memory-index.snapshot"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    chmod 600 "$SESSION/.cs/local/memory-index.snapshot"
    assert_eq 2 "$rc" "an unreadable snapshot must not read as an empty one" || return 1
    assert_output_contains "$out" "cannot read .cs/local/memory-index.snapshot" \
        "the error must name the snapshot" || return 1
}


# An encrypted session's MEMORY.md lives in its vault; the snapshot is a copy
# of it, so it goes behind .cs/private too, never into .cs/local.
test_snapshot_goes_into_the_private_dir() {
    _guard_session
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$SESSION/.cs/private"
    _mark_hand_made_vault "$SESSION"
    local out
    out=$(_guard snapshot 2>&1) || { echo "  FAIL: snapshot exited non-zero: $out"; return 1; }
    assert_eq "$(cat "$INDEX")" "$(cat "$TEST_TMPDIR/vault/private/memory-index.snapshot")" \
        "the snapshot should be the index, in the private dir" || return 1
    assert_file_not_exists "$SESSION/.cs/local/memory-index.snapshot" \
        "nothing may be copied into .cs/local" || return 1
    _guard check > /dev/null || { echo "  FAIL: check should read the private snapshot"; return 1; }
}

test_snapshot_refuses_a_locked_private_dir() {
    _guard_session
    ln -s "$TEST_TMPDIR/unmounted/private" "$SESSION/.cs/private"
    local out rc=0
    out=$(_guard snapshot 2>&1) || rc=$?
    assert_eq 2 "$rc" "snapshot must fail while the vault is locked" || return 1
    assert_eq "memory-index-guard: .cs/private is locked; mount the session's vault, then retry" \
        "$out" "snapshot must say why" || return 1
    assert_file_not_exists "$SESSION/.cs/local/memory-index.snapshot" \
        "nothing may be copied into .cs/local" || return 1
}

# The snapshot lives in .cs/local, and while git tracks a file there a
# repository wrote it: a snapshot taken there would sit beside it, and a
# committed one restored would put the repository's index over the session's.
# Every subcommand refuses, naming the file, and touches nothing.
test_every_subcommand_refuses_while_git_tracks_a_control_file() {
    _guard_session
    local before snap="$SESSION/.cs/local/memory-index.snapshot" sub out rc
    printf -- '- [Planted](project_planted.md): from the repository\n' > "$snap"
    git -C "$SESSION" init -q
    git -C "$SESSION" add .cs/local/memory-index.snapshot
    before=$(cat "$INDEX")
    for sub in snapshot check restore refs; do
        rc=0
        out=$(_guard "$sub" 2>&1) || rc=$?
        assert_eq 2 "$rc" "$sub refuses" || return 1
        assert_eq "memory-index-guard: .cs/local/memory-index.snapshot is tracked in git (per-actor state must stay local). Fix with: git -C $SESSION --literal-pathspecs rm -r --cached -- .cs/local && git -C $SESSION commit -m 'stop tracking .cs/local'" \
            "$out" "$sub names the tracked file" || return 1
        assert_eq "$before" "$(cat "$INDEX")" "$sub leaves MEMORY.md as it was" || return 1
        assert_eq "- [Planted](project_planted.md): from the repository" "$(cat "$snap")" \
            "$sub leaves the snapshot as it was" || return 1
    done
}

# The pointers and the entries are compared with comm, which needs them sorted
# the way it reads them: both sorts and comm get the C locale through env, so
# the lists come out in byte order (uppercase, then "_", then lowercase) in any
# caller's locale, and the shell never changes its own locale for them, which
# can crash a bash linked against libintl in the forked copies they run in.
test_check_lists_in_byte_order_without_the_shell_assigning_its_own_locale() {
    local b utf8 out rc own
    utf8="$(utf8_locale)"
    _guard_session
    rm "$SESSION/.cs/memory/feedback_alpha.md" "$SESSION/.cs/memory/project_beta.md"
    printf '%s\n' '- [A](project_a.md): a' '- [B](project_B.md): b' '- [C](project__c.md): c' \
        '- [Keep](feedback_keep.md): kept' > "$INDEX"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Keep](feedback_keep.md): kept' > "$INDEX"
    : > "$SESSION/.cs/memory/feedback_keep.md"
    : > "$SESSION/.cs/memory/project_yak.md"
    : > "$SESSION/.cs/memory/project_Zed.md"
    for b in $(every_bash); do
        rc=0
        out=$(cd "$SESSION" && env ${utf8:+"LC_ALL=$utf8"} "$b" -x "$GUARD" check 2>"$TEST_TMPDIR/trace") || rc=$?
        assert_eq 1 "$rc" "$b: check fails on the removed and unindexed entries" || return 1
        assert_eq "removed: project_B.md
removed: project__c.md
removed: project_a.md
unindexed: project_Zed.md
unindexed: project_yak.md
MEMORY.md: 33/24400 bytes
MEMORY.md: 1/196 lines" "$out" "$b: the report, in byte order" || return 1
        own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
        assert_eq "" "$own" "$b must not assign its own locale during check" || return 1
    done
}

test_refs_reports_dead_paths_once_in_sorted_order() {
    _guard_session
    printf '%s\n' 'Read `hooks/gone.sh`, `README.md`, and `hooks/gone.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    printf '%s\n' 'Also `hooks/gone.sh`.' > "$SESSION/.cs/memory/project_beta.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'dead: .cs/memory/feedback_alpha.md: README.md
dead: .cs/memory/feedback_alpha.md: hooks/gone.sh
dead: .cs/memory/project_beta.md: hooks/gone.sh' "$out" \
        "refs names each dead path once per entry, in sorted order" || return 1
    assert_eq 0 "$rc" "dead references are advisory" || return 1
}

test_refs_skips_only_immediate_dated_gone_markers() {
    _guard_session
    cat > "$SESSION/.cs/memory/feedback_alpha.md" << 'EOF'
Read `hooks/old.sh` (gone 2026-10-22) and `hooks/twin.sh` (gone 2026-10-22).
The unmarked twin is `hooks/twin.sh`.
EOF
    local out suffix
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/twin.sh' "$out" \
        "a gone marker skips only its reference occurrence" || return 1
    for suffix in ' (gone)' ' was removed (gone 2026-10-22)' \
        ' (gone 22-10-2026)' ' (gone 2026-1-22)' ' (gone 2026/10/22)' \
        '  (gone 2026-10-22)' '(gone 2026-10-22)' $'\t(gone 2026-10-22)' \
        $'\n (gone 2026-10-22)'; do
        printf 'Read `x.sh`%s\n' "$suffix" > "$SESSION/.cs/memory/feedback_alpha.md"
        out=$(_guard refs 2>&1) || return 1
        assert_eq 'dead: .cs/memory/feedback_alpha.md: x.sh' "$out" \
            "an inexact or separated gone marker does not suppress a reference" || return 1
    done
    mkdir -p "$SESSION/hooks"
    : > "$SESSION/hooks/restored.sh"
    : > "$SESSION/hooks/live.sh"
    printf '%s\n' 'Read `hooks/restored.sh` (gone 2026-10-22) and `hooks/live.sh`.' \
        'Also `hooks/old.sh` (gone 2026-10-22).' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "marked live and dead references are silent and excluded from the count" || return 1
}

test_refs_reports_a_verb_absent_from_the_dispatcher() {
    local PATH=/bin:/usr/bin
    _guard_session
    mkdir -p "$SESSION/bin"
    printf '%s\n' 'case "$1" in' '    -present) ;;' 'esac' > "$SESSION/bin/cs"
    printf '%s\n' 'Run `cs -absent`.' > "$SESSION/.cs/memory/project_beta.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'dead: .cs/memory/project_beta.md: cs -absent' "$out" \
        "refs names a verb the dispatcher does not contain" || return 1
    assert_eq 0 "$rc" "a dead verb is advisory" || return 1
}

test_refs_counts_live_paths_identifiers_and_verbs_once() {
    local PATH=/bin:/usr/bin
    _guard_session
    rm "$INDEX"
    mkdir -p "$SESSION/bin" "$SESSION/lib" "$SESSION/hooks"
    printf '%s\n' 'case "$1" in' '    -present) ;;' 'esac' > "$SESSION/bin/cs"
    printf '%s\n' '_cs_present() { :; }' > "$SESSION/lib/helpers.sh"
    : > "$SESSION/hooks/present.sh"
    printf '%s\n' 'Use `hooks/present.sh`, `_cs_present` and `cs -present`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    printf '%s\n' 'Also `_cs_present` and `hooks/present.sh`.' \
        > "$SESSION/.cs/memory/project_beta.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'ok: 3 references in 2 entries, none dead' "$out" \
        "refs counts distinct live references across entries" || return 1
    assert_eq 0 "$rc" "live references pass" || return 1
    mv "$SESSION/lib/helpers.sh" "$SESSION/helpers.sh"
    rmdir "$SESSION/lib"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 3 references in 2 entries, none dead' "$out" \
        "identifier lookup uses the root when lib is absent" || return 1
    rm "$SESSION/helpers.sh"
    mkdir -p "$SESSION/.git"
    printf '%s\n' '_cs_present' > "$SESSION/.git/identifier"
    printf '%s\n' '_cs_present' > "$SESSION/.cs/local/identifier"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_present
dead: .cs/memory/project_beta.md: _cs_present' "$out" \
        "a deleted definition cannot match memory, local state or git metadata" || return 1
    mkdir -p "$SESSION/lib"
    printf '%s\n' 'cs_present() { :; }' > "$SESSION/hooks/helper.sh"
    printf '%s\n' 'Use `cs_present` and `hooks/`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    : > "$SESSION/.cs/memory/project_beta.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "cs identifiers and directories are live references" || return 1
    : > "$SESSION/cs_notes.md"
    printf '%s\n' 'Read `cs_notes.md`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a path starting with cs_ still resolves as a path" || return 1
    : > "$SESSION/hooks/topic:one.md"
    printf '%s\n' 'Read `hooks/topic:one.md`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a colon inside a relative path does not make it a URL" || return 1
    printf '%s\n' 'Use `_cs_missing`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_missing' "$out" \
        "an identifier absent from bin, lib and hooks is dead" || return 1
    : > "$TEST_TMPDIR/outside.md"
    ln -s "$TEST_TMPDIR/outside.md" "$SESSION/hooks/outside.md"
    printf '%s\n' 'Read `../outside.md` and `hooks/outside.md`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: ../outside.md
dead: .cs/memory/feedback_alpha.md: hooks/outside.md' "$out" \
        "existing files outside the checkout are dead, including symlink targets" || return 1
}

test_refs_ignores_frontmatter_the_index_and_narratives() {
    _guard_session
    mkdir -p "$SESSION/hooks"
    : > "$SESSION/hooks/present.sh"
    cat > "$SESSION/.cs/memory/feedback_alpha.md" << 'EOF'
---
description: '`hooks/header-only.sh` and `cs -header-only`'
---
Use `hooks/present.sh`.
EOF
    printf '%s\n' 'See `hooks/index-only.sh`.' > "$INDEX"
    printf '%s\n' 'Used `hooks/narrative-only.sh`.' > "$SESSION/.cs/memory/narrative.example.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "refs reads entry bodies only, excluding the index and narratives" || return 1
    assert_eq 0 "$rc" "ignored references do not fail the scan" || return 1
}

test_refs_ignores_placeholders_and_tokens_with_other_shapes() {
    _guard_session
    cat > "$SESSION/.cs/memory/feedback_alpha.md" << 'EOF'
Try `hooks/<name>.sh`, `hooks/.../entry.md`, `hooks/*.sh` and `hooks/$NAME.sh`.
Also `hooks/name>.sh`, `_cs_<name>` and `cs -<verb>`.
Ignore `hooks/two words.sh`, `ordinary`, `notes.txt`, `cs -present args`,
`https://example.com/hooks/example.sh`, `/outside/file.md` and `~/notes.md`.
EOF
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
        "placeholders and other token shapes are not references" || return 1
    assert_eq 0 "$rc" "ignored tokens do not fail the scan" || return 1
}

test_refs_without_memory_is_an_error() {
    SESSION="$TEST_TMPDIR/elsewhere"
    mkdir -p "$SESSION"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'memory-index-guard: no .cs/memory here; run from the session root' "$out" \
        "refs names the missing memory directory" || return 1
    assert_eq 2 "$rc" "refs outside a session root must fail" || return 1
    assert_not_exists "$SESSION/.cs" "refs creates no session state" || return 1
}

test_refs_finds_basenames_in_subdirectories() {
    _guard_session
    mkdir -p "$SESSION/tests" "$SESSION/.git"
    : > "$SESSION/tests/helper.sh"
    : > "$SESSION/.git/hidden.sh"
    printf '%s\n' 'Read `helper.sh`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a basename found under tests is live and counted" || return 1
    printf '%s\n' 'Read `hidden.sh` and `hooks/helper.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hidden.sh
dead: .cs/memory/feedback_alpha.md: hooks/helper.sh' "$out" \
        "basename lookup excludes git and paths still resolve from the root" || return 1
}

test_refs_skips_names_without_lowercase_letters() {
    _guard_session
    printf '%s\n' 'Names: `CLAUDE_SESSION_NAME/DIR`, `DATABASE_URL`, `123/456`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
        "names without lowercase letters are neither reported nor counted" || return 1
}

test_refs_skips_host_paths() {
    _guard_session
    printf '%s\n' 'Read `example.com/api/v2/incidents/unresolved.json`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
        "host paths are neither reported nor counted" || return 1
    mkdir -p "$SESSION/example.com-tools"
    : > "$SESSION/example.com-tools/file.sh"
    printf '%s\n' 'Read `example.com-tools/file.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a directory with a domain inside its name is still a path" || return 1
}

test_refs_requires_path_characters() {
    _guard_session
    local token out
    for token in 's/^#\+//' '[y/N]' '--force/-f' '-doctor/-diag' \
        'CLAUDE_SESSION_NAME/DIR' 'DATABASE_URL=postgres://user:pass@host' \
        'docs/superpowers/{plans,specs}' 'example.com/api/v2/incidents/unresolved.json' \
        '.sh'; do
        printf 'Read `%s`.\n' "$token" > "$SESSION/.cs/memory/feedback_alpha.md"
        out=$(_guard refs 2>&1) || return 1
        assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
            "$token is neither reported nor counted as a path" || return 1
    done
}

test_refs_resolves_line_suffixes_and_preserves_dead_tokens() {
    _guard_session
    mkdir -p "$SESSION/hooks"
    : > "$SESSION/hooks/x.sh"
    printf '%s\n' 'Read `hooks/x.sh:12`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a line suffix resolves to the live file" || return 1
    rm "$SESSION/hooks/x.sh"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/x.sh:12' "$out" \
        "a missing file retains its line suffix in the dead report" || return 1
    : > "$SESSION/hooks/x.sh"
    printf '%s\n' 'Read `x.sh:12`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a line suffix is stripped before matching a basename extension" || return 1
    : > "$SESSION/hooks/topic:one.md"
    : > "$SESSION/hooks/x.sh:12"
    printf '%s\n' 'Read `hooks/topic:one.md:9` and `hooks/x.sh:12:34`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "only the final numeric suffix is stripped and internal colons stay" || return 1
    printf '%s\n' 'Read `hooks/x.sh/` and `hooks/x.sh:10-20`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "trailing slashes and line ranges resolve to the live file" || return 1
    rm "$SESSION/hooks/x.sh"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/x.sh/
dead: .cs/memory/feedback_alpha.md: hooks/x.sh:10-20' "$out" \
        "missing files retain trailing slashes and ranges in the dead report" || return 1
}

test_refs_skips_branch_prefixes() {
    _guard_session
    local prefix out
    for prefix in feat fix perf chore docs ci test refactor release; do
        printf 'Read `%s/anything`.\n' "$prefix" > "$SESSION/.cs/memory/feedback_alpha.md"
        out=$(_guard refs 2>&1) || return 1
        assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
            "$prefix branches are neither reported nor counted" || return 1
    done
    mkdir -p "$SESSION/features"
    : > "$SESSION/features/anything"
    : > "$SESSION/feat.md"
    printf '%s\n' 'Read `features/anything` and `feat.md`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "branch prefixes match the complete first segment before a slash" || return 1
}

test_refs_uses_the_installed_dispatcher_or_skips_verbs() {
    _guard_session
    mkdir -p "$TEST_TMPDIR/commands"
    local PATH="$TEST_TMPDIR/commands:/bin:/usr/bin" out
    printf '%s\n' '#!/bin/bash' 'case "$1" in' '    -secrets) ;;' 'esac' \
        > "$TEST_TMPDIR/commands/cs"
    chmod +x "$TEST_TMPDIR/commands/cs"
    printf '%s\n' 'Run `cs -secrets`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "verbs resolve through PATH without a repository dispatcher" || return 1
    mkdir -p "$SESSION/bin"
    printf '%s\n' 'case "$1" in' '    -other) ;;' 'esac' > "$SESSION/bin/cs"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "the installed dispatcher takes precedence over bin/cs" || return 1
    rm "$TEST_TMPDIR/commands/cs"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: cs -secrets' "$out" \
        "a verb absent from the fallback dispatcher is dead" || return 1
    rm "$SESSION/bin/cs"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
        "verbs are skipped when neither dispatcher exists" || return 1
    printf '%s\n' 'case "$1" in' '    -secrets) ;;' 'esac' > "$SESSION/bin/cs"
    local rc=0
    out=$(cs() { :; }; export -f cs; _guard refs 2>&1) || rc=$?
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "an exported cs function falls back to bin/cs without stderr" || return 1
    assert_eq 0 "$rc" "the fallback scan succeeds with an exported function" || return 1
}

test_refs_matches_only_complete_dispatcher_arms() {
    _guard_session
    local PATH=/bin:/usr/bin out
    mkdir -p "$SESSION/bin"
    printf '%s\n' 'case "$1" in' '    -remove|-rm) ;;' 'esac' > "$SESSION/bin/cs"
    printf '%s\n' 'Run `cs -rm`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a verb in a compound case arm is live" || return 1
    printf '%s\n' 'case "$1" in' '    -rmdir) ;;' 'esac' '# find . -name foo' \
        > "$SESSION/bin/cs"
    printf '%s\n' 'Run `cs -rm` and `cs -name`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: cs -name
dead: .cs/memory/feedback_alpha.md: cs -rm' "$out" \
        "deleted verbs cannot match longer arms or comments" || return 1
}

test_refs_recognizes_dot_led_paths() {
    _guard_session
    mkdir -p "$SESSION/.github/workflows"
    : > "$SESSION/.github/workflows/ci.yml"
    : > "$SESSION/.cs/memory/x.md"
    printf '%s\n' 'Read `.github/workflows/ci.yml` and `.cs/memory/x.md`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 3 entries, none dead' "$out" \
        "dot-led paths with a name before the last dot are counted" || return 1
    printf '%s\n' 'Read `.github/workflows/gone.yml`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: .github/workflows/gone.yml' "$out" \
        "a missing dot-led path is dead" || return 1
}

test_refs_scans_unclosed_frontmatter_as_body() {
    _guard_session
    printf '%s\n' '---' 'description: `hooks/unclosed.sh`' 'Body with `hooks/unclosed.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/unclosed.sh' "$out" \
        "unclosed frontmatter is scanned as body text" || return 1
}

test_refs_ignores_backticks_inside_code_fences() {
    _guard_session
    printf '%s\n' '```sh' 'echo `hooks/fenced-tick.sh`' '```' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 0 references in 2 entries, none dead' "$out" \
        "backticks inside a code fence are neither reported nor counted" || return 1
    printf '%s\n' 'Read `hooks/outside-fence.sh`.' >> "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/outside-fence.sh' "$out" \
        "reference scanning resumes after the closing fence" || return 1
    printf '%s\n' '   ```sh' 'Read `hooks/indented.sh`.' ' ```' \
        'Read `hooks/outside.sh`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/outside.sh' "$out" \
        "indented fences hide their tokens and resume scanning after closing" || return 1
    printf '%s\n' '~~~sh' 'Read `hooks/tilde.sh`.' '~~~' \
        'Read `hooks/outside.sh`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/outside.sh' "$out" \
        "tilde fences hide their tokens and resume scanning after closing" || return 1
    printf '%s\n' '````sh' '```' 'Read `hooks/short-fence.sh`.' \
        '~~~~' 'Read `hooks/wrong-marker.sh`.' '```` not a closer' \
        'Read `hooks/non-closing.sh`.' '`````   ' 'Read `hooks/outside.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: hooks/outside.sh' "$out" \
        "fences close only with the same marker at least as long and no text" || return 1
}

test_refs_distinguishes_search_hits_from_traversal_errors() {
    [ "$(id -u)" -ne 0 ] || return 77
    _guard_session
    mkdir -p "$SESSION/blocked" "$SESSION/helpers" "$SESSION/node_modules" \
        "$SESSION/target" "$SESSION/.cs/vault-mnt"
    printf '%s\n' '_cs_found() { :; }' > "$SESSION/helpers/present.sh"
    local token out rc
    for token in missing.sh _cs_missing; do
        printf 'Read `%s`.\n' "$token" > "$SESSION/.cs/memory/feedback_alpha.md"
        chmod 000 "$SESSION/blocked"
        rc=0
        out=$(_guard refs 2>&1) || rc=$?
        chmod 700 "$SESSION/blocked"
        assert_eq 2 "$rc" "a search error without a hit fails the scan" || return 1
        assert_eq "memory-index-guard: cannot search for $token" "$out" \
            "a search error identifies the unresolved token" || return 1
    done
    for token in present.sh _cs_found; do
        printf 'Read `%s`.\n' "$token" > "$SESSION/.cs/memory/feedback_alpha.md"
        chmod 000 "$SESSION/blocked"
        rc=0
        out=$(_guard refs 2>&1) || rc=$?
        chmod 700 "$SESSION/blocked"
        assert_eq 0 "$rc" "a hit is live despite an unreadable directory" || return 1
        assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
            "a hit produces a clean live report regardless of traversal errors" || return 1
    done
    printf '%s\n' '_cs_ignored' > "$SESSION/node_modules/ignored.sh"
    : > "$SESSION/target/ignored.sh"
    : > "$SESSION/.cs/vault-mnt/ignored.sh"
    printf '%s\n' 'Read `ignored.sh` and `_cs_ignored`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    chmod 000 "$SESSION/node_modules" "$SESSION/target" "$SESSION/.cs/vault-mnt"
    rc=0
    out=$(_guard refs 2>&1) || rc=$?
    chmod 700 "$SESSION/node_modules" "$SESSION/target" "$SESSION/.cs/vault-mnt"
    assert_eq 0 "$rc" "pruned directories cannot cause search errors" || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_ignored
dead: .cs/memory/feedback_alpha.md: ignored.sh' "$out" \
        "pruned dependencies, build output and vault files are not lookup hits" || return 1
}

test_refs_finds_memory_basenames_in_git_sessions() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' > "$SESSION/.gitignore"
    : > "$SESSION/.cs/memory/narrative.example.md"
    printf '%s\n' 'Read `MEMORY.md` and `narrative.example.md`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "memory basenames stay live when git ignores the session state" || return 1
}

test_refs_ignores_gitignored_copies() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' 'scratch/' '.claude/worktrees/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/scratch" "$SESSION/.claude/worktrees/example"
    printf '%s\n' '_cs_copy' > "$SESSION/scratch/copied.sh"
    printf '%s\n' '_cs_copy' > "$SESSION/.claude/worktrees/example/copied.sh"
    printf '%s\n' 'Read `copied.sh`, `scratch/copied.sh` and `_cs_copy`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out expected
    expected='dead: .cs/memory/feedback_alpha.md: _cs_copy
dead: .cs/memory/feedback_alpha.md: copied.sh'
    out=$(_guard refs 2>&1) || return 1
    assert_eq "$expected" "$out" "ignored copies cannot keep references live" || return 1
    mkdir -p "$SESSION/scratch/x/.cs/memory"
    mv "$SESSION/scratch/copied.sh" "$SESSION/scratch/x/.cs/memory/copied.sh"
    expected="$expected
dead: .cs/memory/feedback_alpha.md: scratch/copied.sh"
    out=$(_guard refs 2>&1) || return 1
    assert_eq "$expected" "$out" "nested ignored memory cannot keep references live" || return 1
}

test_refs_excludes_deleted_tracked_files() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' 'scratch/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/src" "$SESSION/scratch"
    : > "$SESSION/src/deleted.sh"
    git -C "$SESSION" add src/deleted.sh
    rm "$SESSION/src/deleted.sh"
    : > "$SESSION/scratch/deleted.sh"
    printf '%s\n' 'Read `deleted.sh` and `src/deleted.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: deleted.sh
dead: .cs/memory/feedback_alpha.md: src/deleted.sh' "$out" \
        "tracked files removed from disk cannot keep references live" || return 1
}

test_refs_includes_untracked_files_outside_lib() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/lib" "$SESSION/source files"
    printf '%s\n' '_cs_untracked' > "$SESSION/source files/untracked.sh"
    printf '%s\n' 'Read `untracked.sh` and `_cs_untracked`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 2 references in 2 entries, none dead' "$out" \
        "untracked files outside lib resolve names and identifiers" || return 1
}

test_refs_resolves_memory_basenames_without_git() {
    _guard_session
    printf '%s\n' 'Read `MEMORY.md`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "non-git sessions resolve memory basenames" || return 1
}

test_refs_prunes_nested_state_without_git() {
    _guard_session
    mkdir -p "$SESSION/nested/.cs/memory" "$SESSION/nested/node_modules" \
        "$SESSION/nested/.git" "$SESSION/nested/target"
    printf '%s\n' '_cs_nested' > "$SESSION/nested/.cs/memory/entry.md"
    : > "$SESSION/nested/node_modules/dependency.sh"
    : > "$SESSION/nested/.git/internal.sh"
    : > "$SESSION/nested/target/built.sh"
    printf '%s\n' 'Read `_cs_nested`, `dependency.sh`, `internal.sh` and `built.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_nested
dead: .cs/memory/feedback_alpha.md: built.sh
dead: .cs/memory/feedback_alpha.md: dependency.sh
dead: .cs/memory/feedback_alpha.md: internal.sh' "$out" \
        "non-git searches prune nested state and build directories" || return 1
}

test_refs_resolves_exact_paths_on_disk_in_git_sessions() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' 'scratch/' '.claude/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/tests" "$SESSION/lib" "$SESSION/scratch" \
        "$SESSION/hooks" "$SESSION/.claude/worktrees/w/hooks"
    : > "$SESSION/build.sh"
    : > "$SESSION/scratch/keep.sh"
    : > "$SESSION/.claude/worktrees/w/hooks/gone.sh"
    : > "$TEST_TMPDIR/outside.sh"
    ln -s "$TEST_TMPDIR/outside.sh" "$SESSION/hooks/outside.sh"
    printf '%s\n' 'Read `tests/`, `lib/`, `./build.sh` and `scratch/keep.sh`.' \
        'Read `hooks/gone.sh`, `gone.sh` and `hooks/outside.sh`.' \
        > "$SESSION/.cs/memory/feedback_alpha.md"
    local out
    out=$(_guard refs 2>&1) || return 1
    assert_eq 'dead: .cs/memory/feedback_alpha.md: gone.sh
dead: .cs/memory/feedback_alpha.md: hooks/gone.sh
dead: .cs/memory/feedback_alpha.md: hooks/outside.sh' "$out" \
        "exact paths resolve on disk inside the root without borrowing worktree copies" || return 1
}

test_refs_ignores_untracked_nested_repositories() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' > "$SESSION/.gitignore"
    git init -q "$SESSION/inner"
    printf '%s\n' 'Nested repository.' > "$SESSION/inner/README.md"
    printf '%s\n' 'Read `_cs_inner`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_inner' "$out" \
        "a nested repository does not abort identifier lookup or print stderr" || return 1
    assert_eq 0 "$rc" "a missing identifier beside a nested repository exits zero" || return 1
}

test_refs_does_not_search_inside_submodules() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/vendor"
    printf '%s\n' '_cs_in_sub' > "$SESSION/vendor/helper.sh"
    local tree commit out rc=0
    tree=$(git -C "$SESSION" mktree < /dev/null) || return 1
    commit=$(printf '%s\n' 'Fixture' | git -C "$SESSION" -c user.name=Example \
        -c user.email=contributor@example.com commit-tree "$tree") || return 1
    git -C "$SESSION" update-index --add --cacheinfo "160000,$commit,vendor"
    printf '%s\n' 'Read `_cs_in_sub`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_in_sub' "$out" \
        "submodule contents do not resolve identifiers or print stderr" || return 1
    assert_eq 0 "$rc" "an identifier found only in a submodule exits zero" || return 1
}

test_refs_searches_regular_files_beside_directory_symlinks() {
    _guard_session
    git -C "$SESSION" init -q
    printf '%s\n' '.cs/' > "$SESSION/.gitignore"
    mkdir -p "$SESSION/real"
    ln -s real "$SESSION/link"
    printf '%s\n' '_cs_regular' > "$SESSION/helper.sh"
    git -C "$SESSION" add link helper.sh
    printf '%s\n' 'Read `_cs_regular`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    local out rc=0
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'ok: 1 references in 2 entries, none dead' "$out" \
        "a tracked regular file resolves beside a directory symlink without stderr" || return 1
    assert_eq 0 "$rc" "a live identifier beside a directory symlink exits zero" || return 1
    printf '%s\n' 'Read `_cs_absent`.' > "$SESSION/.cs/memory/feedback_alpha.md"
    out=$(_guard refs 2>&1) || rc=$?
    assert_eq 'dead: .cs/memory/feedback_alpha.md: _cs_absent' "$out" \
        "a directory symlink does not abort a missing identifier lookup" || return 1
    assert_eq 0 "$rc" "a missing identifier beside a directory symlink exits zero" || return 1
}

run_test test_refs_ignores_untracked_nested_repositories
run_test test_refs_does_not_search_inside_submodules
run_test test_refs_searches_regular_files_beside_directory_symlinks
run_test test_refs_resolves_exact_paths_on_disk_in_git_sessions
run_test test_refs_excludes_deleted_tracked_files
run_test test_refs_includes_untracked_files_outside_lib
run_test test_refs_resolves_memory_basenames_without_git
run_test test_refs_prunes_nested_state_without_git
run_test test_refs_ignores_gitignored_copies
run_test test_refs_finds_memory_basenames_in_git_sessions
run_test test_refs_distinguishes_search_hits_from_traversal_errors
run_test test_refs_ignores_backticks_inside_code_fences
run_test test_refs_scans_unclosed_frontmatter_as_body
run_test test_refs_recognizes_dot_led_paths
run_test test_refs_matches_only_complete_dispatcher_arms
run_test test_refs_uses_the_installed_dispatcher_or_skips_verbs
run_test test_refs_skips_branch_prefixes
run_test test_refs_resolves_line_suffixes_and_preserves_dead_tokens
run_test test_refs_requires_path_characters
run_test test_refs_skips_host_paths
run_test test_refs_skips_names_without_lowercase_letters
run_test test_refs_finds_basenames_in_subdirectories
run_test test_refs_without_memory_is_an_error
run_test test_refs_ignores_placeholders_and_tokens_with_other_shapes
run_test test_refs_ignores_frontmatter_the_index_and_narratives
run_test test_refs_counts_live_paths_identifiers_and_verbs_once
run_test test_refs_reports_a_verb_absent_from_the_dispatcher
run_test test_refs_reports_dead_paths_once_in_sorted_order
run_test test_refs_skips_only_immediate_dated_gone_markers
run_test test_check_fails_when_a_link_is_removed
run_test test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget
run_test test_check_counts_bytes_not_characters
run_test test_check_without_a_snapshot_is_an_error
run_test test_check_without_the_index_is_an_error
run_test test_check_fails_over_the_byte_budget
run_test test_check_fails_over_the_line_budget
run_test test_restore_puts_back_the_snapshot_byte_for_byte
run_test test_restore_without_a_snapshot_leaves_the_index_alone
run_test test_unknown_subcommand_prints_usage

run_test test_check_passes_when_a_supporting_link_is_dropped
run_test test_check_fails_when_two_pointers_are_merged
run_test test_check_fails_on_an_unindexed_bucket_entry
run_test test_check_fails_on_a_pointer_to_a_missing_entry
run_test test_check_passes_a_pointer_moved_to_the_archive
run_test test_check_fails_on_a_pointer_in_the_index_and_the_archive
run_test test_check_fails_when_the_index_has_no_pointer_to_the_archive
run_test test_check_fails_on_an_archive_pointer_to_a_missing_entry
run_test test_restore_after_a_move_leaves_the_pointer_in_both_files
run_test test_check_fails_on_a_pointer_dropped_from_the_archive
run_test test_check_fails_on_an_archived_pointer_dropped_with_its_entry
run_test test_check_passes_a_pointer_that_names_no_entry_file
run_test test_check_counts_the_line_breaks_claude_code_counts
run_test test_check_names_a_pointer_and_an_entry_as_plain_names
run_test test_first_sweep_snapshots_an_absent_index_as_empty
run_test test_snapshot_outside_a_session_root_is_an_error
run_test test_check_with_an_unreadable_snapshot_is_an_error
run_test test_snapshot_goes_into_the_private_dir
run_test test_snapshot_refuses_a_locked_private_dir
run_test test_every_subcommand_refuses_while_git_tracks_a_control_file
run_test test_check_lists_in_byte_order_without_the_shell_assigning_its_own_locale

report_results
