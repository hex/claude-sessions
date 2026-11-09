#!/usr/bin/env bash
# ABOUTME: Tests that migrating an existing session never destroys a user-authored CLAUDE.md
# ABOUTME: Phase 5 must append the cs protocol, not wholesale-overwrite the file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A resume (existing dir → migrate_session) must not clobber user content in
# CLAUDE.md that happens not to mention '.cs/'.
test_migrate_preserves_user_claude_md() {
    local dir
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nDO-NOT-DELETE-THIS-LINE\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" "DO-NOT-DELETE-THIS-LINE" \
        "migrate must preserve the user's CLAUDE.md content" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "the user's CLAUDE.md must no longer gain the protocol" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "the protocol lands in CLAUDE.local.md" || return 1
}

# Idempotent: a second resume must not append the protocol twice.
test_migrate_claude_md_idempotent() {
    local dir count
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nkeep-me\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    count=$(grep -c 'cs:session-protocol' "$dir/CLAUDE.local.md")
    assert_eq "1" "$count" "protocol sentinel must appear exactly once after two resumes" || return 1
    assert_file_contains "$dir/CLAUDE.md" "keep-me" "user file untouched across resumes" || return 1
}

test_create_path_writes_local_md() {
    local dir="$CS_SESSIONS_ROOT/fresh"
    "$CS_BIN" "fresh" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "new session gets CLAUDE.local.md" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "new session gets no CLAUDE.md" || return 1
    assert_file_contains "$dir/.gitignore" "CLAUDE.local.md" \
        "session .gitignore covers the local file" || return 1
}

test_pure_cs_claude_md_moves_wholesale() {
    local dir out
    dir=$(create_test_session "pure")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nSee .cs/ for metadata.\n' > "$dir/CLAUDE.md"
    out=$("$CS_BIN" "pure" < /dev/null 2>&1 || true)
    assert_file_not_exists "$dir/CLAUDE.md" "pure cs file is removed after the move" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "content moved to CLAUDE.local.md" || return 1
    grep -Fxq -- '  CLAUDE.local.md  holds the cs session protocol, moved from CLAUDE.md' <<< "$out" \
        || { echo "  FAIL: the open says the whole protocol moved from CLAUDE.md"; return 1; }
}

test_mixed_claude_md_splits_at_first_sentinel() {
    local dir out
    dir=$(create_test_session "mixed")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nprotocol body .cs/\n\n<!-- cs:memory-note -->\nnote body\n' > "$dir/CLAUDE.md"
    out=$("$CS_BIN" "mixed" < /dev/null 2>&1 || true)
    assert_file_contains "$dir/CLAUDE.md" "USER-KEEP" "user head stays" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" "cs sections left CLAUDE.md" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" "protocol in local file" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" "memory note rode along" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "USER-KEEP" "user head did not ride along" || return 1
    grep -Fxq -- "  CLAUDE.local.md  holds cs's sections, moved from CLAUDE.md, where your own lines stay" <<< "$out" \
        || { echo "  FAIL: the open says cs's sections moved and the user's head stayed"; return 1; }
}

test_pre_sentinel_template_left_alone() {
    local dir
    dir=$(create_test_session "presentinel")
    printf '# Session Documentation Protocol\n\nSession metadata lives in the .cs/ directory.\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "presentinel" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" ".cs/ directory" "pre-sentinel file untouched" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:memory-note" \
        "no managed sections scribbled into the legacy file" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:wrap-cues" \
        "no wrap-cues appended to the legacy file either" || return 1
    assert_file_not_exists "$dir/CLAUDE.local.md" "no second protocol file for pre-sentinel sessions" || return 1
}

test_user_local_md_never_overwritten() {
    local dir
    dir=$(create_test_session "userlocal")
    printf 'MY-PERSONAL-LOCAL-NOTES\n' > "$dir/CLAUDE.local.md"
    printf '<!-- cs:session-protocol -->\nprotocol body .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "userlocal" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "MY-PERSONAL-LOCAL-NOTES" \
        "a user-authored CLAUDE.local.md survives migration" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "cs content appended after the user's" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "the pure-cs CLAUDE.md is still consumed" || return 1
}

test_adopt_leaves_project_claude_md_alone() {
    # adopt_session resolves its target via `pwd -P` and symlinks it into
    # $SESSIONS_ROOT/<name> — the project directory itself must live OUTSIDE
    # $CS_SESSIONS_ROOT, or that symlink target collides with the fixture
    # and trips the pre-existing "session already exists" guard. Matches the
    # idiom in tests/test_adopt.sh ($TEST_TMPDIR/my-project, adopted as a
    # differently-named session).
    local dir="$TEST_TMPDIR/adoptme-proj"
    mkdir -p "$dir"
    printf '# Project Rules\nADOPT-KEEP-ONCE\n' > "$dir/CLAUDE.md"
    ( cd "$dir" && git init -q . 2>/dev/null ) || return 1
    ( cd "$dir" && "$CS_BIN" -adopt "adoptme" < /dev/null > /dev/null 2>&1 ) || true
    local n
    n=$(grep -c 'ADOPT-KEEP-ONCE' "$dir/CLAUDE.md")
    assert_eq "1" "$n" "adopt must not duplicate the project CLAUDE.md" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "the protocol stays out of the project file" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "adopt writes the local protocol file" || return 1
}

test_migration_idempotent_byte_for_byte() {
    local dir
    dir=$(create_test_session "idem")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\nprotocol .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cp "$dir/CLAUDE.md" "$dir/.first-md" && cp "$dir/CLAUDE.local.md" "$dir/.first-local"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cmp -s "$dir/CLAUDE.md" "$dir/.first-md" || { echo "  FAIL: CLAUDE.md changed on second run"; return 1; }
    cmp -s "$dir/CLAUDE.local.md" "$dir/.first-local" || { echo "  FAIL: CLAUDE.local.md changed on second run"; return 1; }
}

test_memory_note_lands_in_local_md() {
    local dir out
    dir=$(create_test_session "note")
    printf '<!-- cs:session-protocol -->\nprotocol only, no note, references .cs/\n' > "$dir/CLAUDE.md"
    out=$("$CS_BIN" "note" < /dev/null 2>&1 || true)
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" \
        "Phase 9 adds the note to the local file" || return 1
    grep -Fxq -- '  CLAUDE.local.md  added cs:memory-note' <<< "$out" \
        || { echo "  FAIL: the open says it added the note"; return 1; }
    assert_file_not_exists "$dir/CLAUDE.md" "CLAUDE.md not recreated by Phase 9" || return 1
}

test_gitignore_backfill_idempotent() {
    local dir
    dir=$(create_test_session "gi")
    printf '*.tmp\n' > "$dir/.gitignore"
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    local n
    n=$(grep -c 'CLAUDE.local.md' "$dir/.gitignore")
    assert_eq "1" "$n" "gitignore entry added exactly once" || return 1
}

test_worktree_bootstrap_writes_local_md() {
    local dir
    dir=$(create_test_session "wtbase")
    ( cd "$dir" && git init -q . 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null ) || return 1
    "$CS_BIN" "wtbase@task1" < /dev/null > /dev/null 2>&1 || true
    if [ -d "$CS_SESSIONS_ROOT/wtbase@task1" ]; then
        assert_file_contains "$CS_SESSIONS_ROOT/wtbase@task1/CLAUDE.local.md" "cs:session-protocol" \
            "worktree session gets its own protocol file" || return 1
    else
        echo "  FAIL: worktree session was not created"
        return 1
    fi
}

# Ignored mode: the base's .gitignore excludes .cs/ but says nothing about
# CLAUDE.local.md (a real project repo has no reason to know about it) — the
# worktree bootstrap must keep the protocol file out of `git status` via the
# clone-local info/exclude instead of touching that .gitignore.
test_old_template_head_moves_wholesale() {
    local dir
    dir=$(create_test_session "oldtemplate")
    printf '# Session Documentation Protocol\n\nold body referencing .cs/\n\n<!-- cs:memory-note -->\nnote body\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "oldtemplate" < /dev/null > /dev/null 2>&1 || true
    assert_file_not_exists "$dir/CLAUDE.md" "old-template head moves wholesale, CLAUDE.md is gone" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "# Session Documentation Protocol" \
        "old-template heading moved to CLAUDE.local.md" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" \
        "memory-note sentinel moved to CLAUDE.local.md" || return 1
}

# The final reviewer's repro: a tracked base created and committed before the
# CLAUDE.local.md backfill existed, never launched since (worktree creation
# does not migrate the base). Its checked-out .gitignore has no
# CLAUDE.local.md entry, so the worktree's own copy of the file must be
# covered by the clone-local info/exclude in tracked mode too, or it reads
# as untracked and blocks retirement's preflight.
test_worktree_from_unmigrated_base_can_merge() {
    local dir
    dir=$(create_test_session "unmigrated")
    ( cd "$dir" && git init -q . 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null ) || return 1
    "$CS_BIN" "unmigrated@task1" < /dev/null > /dev/null 2>&1 || true
    local wt="$CS_SESSIONS_ROOT/unmigrated@task1"
    if [ -d "$wt" ]; then
        local exclude
        exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null || echo "" )
        # git reports an absolute path for a worktree and a relative one for a
        # plain repo. Resolve by existence
        # rather than re-deriving cs's own classification here — duplicating it
        # let a bug in both cancel out and the assertion pass regardless.
        [ -f "$exclude" ] || exclude="$wt/$exclude"
        assert_file_contains "$exclude" "CLAUDE.local.md" \
            "tracked-mode worktree from an unmigrated base still excludes CLAUDE.local.md, unblocking the merge preflight" || return 1
    else
        echo "  FAIL: worktree session was not created"
        return 1
    fi
}

test_worktree_ignored_mode_excludes_local_md_via_clone_exclude() {
    local dir
    dir=$(create_test_session "wtignored")
    printf '.cs/\n' > "$dir/.gitignore"
    ( cd "$dir" && git init -q . 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null ) || return 1
    "$CS_BIN" "wtignored@task1" < /dev/null > /dev/null 2>&1 || true
    local wt="$CS_SESSIONS_ROOT/wtignored@task1"
    if [ -d "$wt" ]; then
        local exclude
        exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null || echo "")
        # git reports an absolute path for a worktree and a relative one for a
        # plain repo. Resolve by existence
        # rather than re-deriving cs's own classification here — duplicating it
        # let a bug in both cancel out and the assertion pass regardless.
        [ -f "$exclude" ] || exclude="$wt/$exclude"
        assert_file_contains "$exclude" "CLAUDE.local.md" \
            "ignored-mode worktree excludes the protocol file via the clone-local exclude" || return 1
        assert_file_not_contains "$wt/.gitignore" "CLAUDE.local.md" \
            "the project's own .gitignore is never touched" || return 1
    else
        echo "  FAIL: ignored-mode worktree session was not created"
        return 1
    fi
}

# Every CLAUDE.md / CLAUDE.local.md rewrite goes through a temp file in the
# same directory. Its name must be unique, so a sibling the user named
# <file>.tmp is never clobbered, and the rewritten file keeps its mode. The
# fixture reaches all four rewrites: the Discovered Commands strip and the
# head split on CLAUDE.md, the protocol-wording rewrite and the memory-rules
# retirement on CLAUDE.local.md.
test_migration_rewrites_leave_tmp_siblings_alone_and_keep_modes() {
    local dir
    dir=$(create_test_session "tmpsib")
    printf '# User Head\n\n## Discovered Commands\n\n- make test\n\n<!-- cs:session-protocol -->\nold protocol .cs/\n' > "$dir/CLAUDE.md"
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nAppend only to your own; read all narrative.*.md on resume to restore your\nworking narrative and see teammates'"'"' in-progress findings.\n\n<!-- cs:memory-rules -->\n## Auto-memory bucket guidance\nold rules\n\n<!-- cs:wrap-cues -->\n' > "$dir/CLAUDE.local.md"
    printf 'USER-OWNED-MD\n' > "$dir/CLAUDE.md.tmp"
    printf 'USER-OWNED-LOCAL\n' > "$dir/CLAUDE.local.md.tmp"
    chmod 750 "$dir/CLAUDE.md" "$dir/CLAUDE.local.md"

    "$CS_BIN" "tmpsib" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/CLAUDE.md" "Discovered Commands" "commands section stripped" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" "head split happened" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "protocol wording rewritten" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "Auto-memory bucket guidance" "memory rules retired" || return 1
    assert_eq "USER-OWNED-MD" "$(cat "$dir/CLAUDE.md.tmp")" "CLAUDE.md.tmp is untouched" || return 1
    assert_eq "USER-OWNED-LOCAL" "$(cat "$dir/CLAUDE.local.md.tmp")" "CLAUDE.local.md.tmp is untouched" || return 1
    assert_eq "750" "$(_file_mode "$dir/CLAUDE.md")" "CLAUDE.md keeps its mode" || return 1
    assert_eq "750" "$(_file_mode "$dir/CLAUDE.local.md")" "CLAUDE.local.md keeps its mode" || return 1
}

# A CLAUDE.local.md that is a symlink is rewritten THROUGH the link: the target
# gets the new text and keeps its mode, and the link stays a link.
test_migration_rewrite_through_a_symlink_keeps_the_targets_mode() {
    local dir
    dir=$(create_test_session "linked")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nAppend only to your own; read all narrative.*.md on resume to restore your\nworking narrative and see teammates'"'"' in-progress findings.\n\n<!-- cs:memory-note -->\nnote\n<!-- cs:wrap-cues -->\n' > "$dir/real-local.md"
    chmod 750 "$dir/real-local.md"
    ln -s real-local.md "$dir/CLAUDE.local.md"

    "$CS_BIN" "linked" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "protocol wording rewritten" || return 1
    assert_eq "750" "$(_file_mode "$dir/CLAUDE.local.md")" "the rewritten file keeps the target's mode" || return 1
    [ -L "$dir/CLAUDE.local.md" ] || { echo "  FAIL: the symlink was replaced by a regular file"; return 1; }
    assert_file_not_contains "$dir/real-local.md" "read all narrative" "the rewrite went through the link into the target" || return 1
}

run_test test_migrate_preserves_user_claude_md
run_test test_migration_rewrites_leave_tmp_siblings_alone_and_keep_modes
run_test test_migration_rewrite_through_a_symlink_keeps_the_targets_mode
run_test test_migrate_claude_md_idempotent
run_test test_create_path_writes_local_md
run_test test_pure_cs_claude_md_moves_wholesale
run_test test_mixed_claude_md_splits_at_first_sentinel
run_test test_pre_sentinel_template_left_alone
run_test test_user_local_md_never_overwritten
run_test test_adopt_leaves_project_claude_md_alone
run_test test_migration_idempotent_byte_for_byte
run_test test_memory_note_lands_in_local_md
run_test test_gitignore_backfill_idempotent
run_test test_worktree_bootstrap_writes_local_md
run_test test_old_template_head_moves_wholesale
run_test test_worktree_from_unmigrated_base_can_merge
run_test test_worktree_ignored_mode_excludes_local_md_via_clone_exclude

# A session repo cloned with autocrlf enabled arrives with
# CRLF line endings. The frontmatter-bounded field strip opens on /^---$/, which
# does not match "---\r", so fm is never set, the gate reports nothing found, and
# the machine-local fields survive migration — a regression against the looser
# match this replaced.
test_migrate_moves_machine_local_fields_out_of_a_crlf_readme() {
    local dir
    dir=$(create_test_session "crlfproj")
    printf -- '---\r\nstatus: active\r\nclaude_session_id: 11111111-2222-3333-4444-555555555555\r\nclaude_session_color: cyan\r\naliases: ["crlfproj"]\r\n---\r\n\r\n# Session: crlfproj\r\n\r\n## Outcome\r\n\r\nupdated: the docs by hand\r\n' \
        > "$dir/.cs/README.md"
    # Fixture sanity: the file really is CRLF, or this tests the LF path again.
    # Counted rather than matched: a CR carried through a shell variable is the
    # the value autocrlf is most likely to mangle, and this test exists for that
    # Bash — a guard that cannot survive the platform it guards proves nothing.
    [ "$(LC_ALL=C tr -cd '\r' < "$dir/.cs/README.md" | wc -c | tr -d '[:space:]')" -gt 0 ] \
        || { echo "  FAIL: fixture is not CRLF"; return 1; }

    "$CS_BIN" "crlfproj" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/.cs/README.md" '^claude_session_id:' \
        "the machine-local uuid must be moved out of the frontmatter" || return 1
    assert_file_not_contains "$dir/.cs/README.md" '^claude_session_color:' \
        "and so must the colour" || return 1
    assert_file_contains "$dir/.cs/local/state" "11111111-2222-3333-4444-555555555555" \
        "the uuid must land in machine-local state, not be discarded" || return 1
    # The body line beginning "updated:" is the user's prose and must survive —
    # the whole reason the strip is bounded to the frontmatter.
    assert_file_contains "$dir/.cs/README.md" "updated: the docs by hand" \
        "a body line that looks like a field is user content" || return 1
    # The corruption this really guards: unrecognised frontmatter made Phase 6
    # PREPEND a second block, orphaning the first in the body where every
    # frontmatter reader stops before it.
    local fences
    fences=$(grep -c '^---' "$dir/.cs/README.md" | tr -d '[:space:]')
    assert_eq "2" "$fences" "exactly one frontmatter block, opened and closed" || return 1
}

test_migrate_does_not_strip_a_body_line_when_the_fence_is_unclosed() {
    # Line 1 is `---` so Phase 6 leaves the file alone, but nothing closes the
    # block — so the "bounded to the frontmatter" scan runs to EOF and deletes a
    # body line that merely begins with one of the four key names. Without a
    # closing fence there is no way to tell frontmatter from prose, and
    # rewriting prose is the worse failure.
    local dir
    dir=$(create_test_session "unfenced")
    printf -- '---\nstatus: active\nclaude_session_id: 99999999-8888-7777-6666-555555555555\n\n## Outcome\n\nupdated: the deploy notes\n' \
        > "$dir/.cs/README.md"
    "$CS_BIN" "unfenced" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/.cs/README.md" "updated: the deploy notes" \
        "a body line must survive when the block was never closed" || return 1
}

run_test test_migrate_moves_machine_local_fields_out_of_a_crlf_readme
run_test test_migrate_does_not_strip_a_body_line_when_the_fence_is_unclosed

# Files cs wrote before rotation existed carry the read-all sentence in three
# places cs owns: the narrative's own frontmatter, its MEMORY.md pointer and the
# protocol block in CLAUDE.local.md. A resume rewrites all three once.
test_migrate_rewrites_read_all_wording_cs_wrote() {
    local dir
    dir=$(create_test_session "wordy")
    # Exactly 7 header lines (---, name, description, type, ---, title, blank),
    # so this body line lands on line 8 — the same line the frontmatter gate and
    # the 1,8 sed window reach. Pins the boundary: without the description-line
    # anchor, this body line would get rewritten too.
    printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook and work-in-progress narrative for alice. Looser bar than durable memory. Read all narrative.*.md on resume.\ntype: narrative\n---\n# Session narrative (alice)\n\n## 2026-01-01 — kept: body mentions Read all narrative.*.md on resume. verbatim\n' \
        > "$dir/.cs/memory/narrative.alice.md"
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' \
        > "$dir/.cs/memory/MEMORY.md"
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nAppend only to your own; read all narrative.*.md on resume to restore your\nworking narrative and see teammates'"'"' in-progress findings.\n\n<!-- cs:memory-note -->\nnote\n' \
        > "$dir/CLAUDE.local.md"
    CS_ACTOR=alice "$CS_BIN" "wordy" < /dev/null > /dev/null 2>&1 || true

    local desc
    desc=$(sed -n '3p' "$dir/.cs/memory/narrative.alice.md")
    case "$desc" in
        *"Read all narrative"*) echo "  FAIL: frontmatter description still says read all: $desc"; return 1 ;;
        *"narrative-archive"*) ;;
        *) echo "  FAIL: frontmatter description does not point at the archive: $desc"; return 1 ;;
    esac
    assert_file_contains "$dir/.cs/memory/narrative.alice.md" "body mentions Read all narrative\.\*\.md on resume\. verbatim" \
        "the narrative body is never rewritten" || return 1
    assert_eq "## 2026-01-01 — kept: body mentions Read all narrative.*.md on resume. verbatim" "$(sed -n '8p' "$dir/.cs/memory/narrative.alice.md")" \
        "line 8 (first body line) untouched" || return 1
    assert_file_not_contains "$dir/.cs/memory/MEMORY.md" "read all narrative" "index pointer rewritten" || return 1
    assert_file_contains "$dir/.cs/memory/MEMORY.md" "narrative-archive" "index pointer names the archive" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "protocol sentence rewritten" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "grep on demand, never preload" "with the live-plus-archive instruction" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->" "the following block is untouched" || return 1
}

# The two wording rewrites under .cs/memory go through a uniquely named temp
# file too: <file>.tmp siblings are left alone and both files keep their mode.
test_migrate_memory_wording_rewrites_leave_tmp_siblings_alone_and_keep_modes() {
    local dir
    dir=$(create_test_session "wordysib")
    printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook and work-in-progress narrative for alice. Looser bar than durable memory. Read all narrative.*.md on resume.\ntype: narrative\n---\n# Session narrative (alice)\n' \
        > "$dir/.cs/memory/narrative.alice.md"
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' \
        > "$dir/.cs/memory/MEMORY.md"
    printf 'USER-OWNED-NARRATIVE\n' > "$dir/.cs/memory/narrative.alice.md.tmp"
    printf 'USER-OWNED-INDEX\n' > "$dir/.cs/memory/MEMORY.md.tmp"
    chmod 750 "$dir/.cs/memory/narrative.alice.md" "$dir/.cs/memory/MEMORY.md"

    CS_ACTOR=alice "$CS_BIN" "wordysib" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/.cs/memory/narrative.alice.md" "Read all narrative" "description rewritten" || return 1
    assert_file_not_contains "$dir/.cs/memory/MEMORY.md" "read all narrative" "index pointer rewritten" || return 1
    assert_eq "USER-OWNED-NARRATIVE" "$(cat "$dir/.cs/memory/narrative.alice.md.tmp" 2>/dev/null)" "narrative .tmp sibling untouched" || return 1
    assert_eq "USER-OWNED-INDEX" "$(cat "$dir/.cs/memory/MEMORY.md.tmp" 2>/dev/null)" "MEMORY.md.tmp untouched" || return 1
    assert_eq "750" "$(_file_mode "$dir/.cs/memory/narrative.alice.md")" "the narrative keeps its mode" || return 1
    assert_eq "750" "$(_file_mode "$dir/.cs/memory/MEMORY.md")" "MEMORY.md keeps its mode" || return 1
}

test_migrate_read_all_rewrite_is_idempotent() {
    local dir
    dir=$(create_test_session "wordy2")
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' \
        > "$dir/.cs/memory/MEMORY.md"
    CS_ACTOR=alice "$CS_BIN" "wordy2" < /dev/null > /dev/null 2>&1 || true
    local once
    once=$(cat "$dir/.cs/memory/MEMORY.md")
    CS_ACTOR=alice "$CS_BIN" "wordy2" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$once" "$(cat "$dir/.cs/memory/MEMORY.md")" "second resume leaves the index byte-identical" || return 1
}

# The wording that replaced read-all said "read the live narrative.*.md on
# resume", which nobody can do at 801 KB either. A resume rewrites that vintage
# too, in the same three places, to the owner-in-full / teammate-by-digest rule.
test_migrate_rewrites_read_the_live_wording_cs_wrote() {
    local dir
    dir=$(create_test_session "livewordy")
    printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook and work-in-progress narrative for alice. Looser bar than durable memory. Read the live narrative.*.md on resume; older sections are archived under .cs/narrative-archive/.\ntype: narrative\n---\n# Session narrative (alice)\n\n## 2026-01-01 — kept: body says Read the live narrative.*.md on resume verbatim\n' \
        > "$dir/.cs/memory/narrative.alice.md"
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read the live narrative.*.md on resume, older sections under .cs/narrative-archive/\n' \
        > "$dir/.cs/memory/MEMORY.md"
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\n3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates'"'"'): findings, in-progress state, observations\n\nAppend only to your own; on resume read the live narrative.*.md (rotation keeps\nthem small). Older sections sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload.\n\n<!-- cs:memory-note -->\nnote\n' \
        > "$dir/CLAUDE.local.md"
    # A teammate's narrative carries the same old wording and is not ours to touch.
    printf -- '---\nname: session-narrative-bob\ndescription: Session lab-notebook and work-in-progress narrative for bob. Looser bar than durable memory. Read the live narrative.*.md on resume; older sections are archived under .cs/narrative-archive/.\ntype: narrative\n---\n# Session narrative (bob)\n' \
        > "$dir/.cs/memory/narrative.bob.md"
    CS_ACTOR=alice "$CS_BIN" "livewordy" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/.cs/memory/narrative.bob.md" "Read the live narrative" \
        "a teammate's narrative is never rewritten by this actor's resume" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "yours + teammates" "the read-list item is rewritten too" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "Yours in full; a teammate's only where the resume digest says it grew" \
        "the read-list item carries the delta rule" || return 1

    local desc
    desc=$(sed -n '3p' "$dir/.cs/memory/narrative.alice.md")
    case "$desc" in
        *"Read the live narrative"*) echo "  FAIL: frontmatter description still says read the live: $desc"; return 1 ;;
        *"resume digest names"*) ;;
        *) echo "  FAIL: frontmatter description does not carry the digest rule: $desc"; return 1 ;;
    esac
    assert_eq "## 2026-01-01 — kept: body says Read the live narrative.*.md on resume verbatim" "$(sed -n '8p' "$dir/.cs/memory/narrative.alice.md")" \
        "line 8 (first body line) untouched" || return 1
    assert_file_not_contains "$dir/.cs/memory/MEMORY.md" "read the live narrative" "index pointer rewritten" || return 1
    assert_file_contains "$dir/.cs/memory/MEMORY.md" "resume digest names" "index pointer carries the digest rule" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "read the live narrative" "protocol sentence rewritten" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "read your own in full" "with the owner-in-full rule" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "grep on demand, never preload" "archive instruction kept" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->" "the following block is untouched" || return 1
}

# The current template's own "Narratives are per-actor (...) so co-developers
# never conflict." line must not trip the rewrite gate, or every resume rewrites
# CLAUDE.local.md (mtime churn; a symlink becomes a regular file).
test_migrate_leaves_a_current_protocol_block_alone() {
    local dir
    dir=$(create_test_session "current")
    CS_ACTOR=alice "$CS_BIN" "current" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "so co-developers never conflict" "fixture carries the current template" || return 1
    touch -t 202001010000 "$dir/CLAUDE.local.md"
    touch -t 202101010000 "$dir/.cs/mtime-ref"
    CS_ACTOR=alice "$CS_BIN" "current" < /dev/null > /dev/null 2>&1 || true
    if [ "$dir/CLAUDE.local.md" -nt "$dir/.cs/mtime-ref" ]; then
        echo "  FAIL: a second resume rewrote an already-current CLAUDE.local.md"; return 1
    fi
}

# The protocol paragraph exists in two places cs owns: the template a fresh
# session gets, and the awk that rewrites an old session's copy. Nothing else
# compares them, so a wording change landing in one produces sessions whose
# CLAUDE.local.md disagrees with a fresh one, with every gate green.
test_migrated_protocol_matches_the_template() {
    local fresh migrated
    fresh=$(create_test_session "freshproto")
    CS_ACTOR=alice "$CS_BIN" "freshproto" < /dev/null > /dev/null 2>&1 || true

    migrated=$(create_test_session "oldproto")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nAppend only to your own; read all narrative.*.md on resume to restore your\nworking narrative and see teammates'"'"' in-progress findings.\n\n<!-- cs:memory-note -->\nnote\n' \
        > "$migrated/CLAUDE.local.md"
    CS_ACTOR=alice "$CS_BIN" "oldproto" < /dev/null > /dev/null 2>&1 || true

    local want got
    want=$(grep -n 'Append only to your own' "$fresh/CLAUDE.local.md" | head -1 | cut -d: -f1)
    [ -n "$want" ] || { echo "  FAIL: the template has no protocol paragraph to compare against"; return 1; }
    want=$(sed -n "${want},$((want + 2))p" "$fresh/CLAUDE.local.md")
    got=$(grep -n 'Append only to your own' "$migrated/CLAUDE.local.md" | head -1 | cut -d: -f1)
    [ -n "$got" ] || { echo "  FAIL: the migrated file has no protocol paragraph"; return 1; }
    got=$(sed -n "${got},$((got + 2))p" "$migrated/CLAUDE.local.md")
    assert_eq "$want" "$got" "the migration must write the same protocol paragraph the template does" || return 1
}

run_test test_migrate_rewrites_read_all_wording_cs_wrote
run_test test_migrate_memory_wording_rewrites_leave_tmp_siblings_alone_and_keep_modes
run_test test_migrated_protocol_matches_the_template
run_test test_migrate_leaves_a_current_protocol_block_alone
run_test test_migrate_rewrites_read_the_live_wording_cs_wrote
run_test test_migrate_read_all_rewrite_is_idempotent

# The protocol block cs shipped July-2026 through August-2026 wraps the same
# sentence across four lines instead of two ("Note: narratives are per-actor
# ... so co-developers never / conflict. Append only to your own ... read all /
# narrative.*.md on resume to restore your working narrative and see teammates'
# / in-progress findings."). A real-session survey found this vintage on 12 of
# 17 sessions still carrying the read-all sentence — the majority, not an edge
# case.
test_migrate_rewrites_the_older_protocol_wording() {
    local dir
    dir=$(create_test_session "oldwordy")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nNote: narratives are per-actor (narrative.<actor>.md) so co-developers never\nconflict. Append only to your own (run `cs -whoami` for your actor); read all\nnarrative.*.md on resume to restore your working narrative and see teammates'"'"'\nin-progress findings.\n\n<!-- cs:memory-note -->\nnote body\n' \
        > "$dir/CLAUDE.local.md"
    CS_ACTOR=alice "$CS_BIN" "oldwordy" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "old-vintage sentence rewritten" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "grep on demand, never preload" "with the live-plus-archive instruction" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->" "the following block is untouched" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "note body" "and its body survives" || return 1

    local once
    once=$(cat "$dir/CLAUDE.local.md")
    CS_ACTOR=alice "$CS_BIN" "oldwordy" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$once" "$(cat "$dir/CLAUDE.local.md")" "second resume leaves the file byte-identical" || return 1
}

# A session repo cloned with autocrlf carries CRLF line endings in
# CLAUDE.local.md too. The current-vintage awk match compares $0 (the whole
# line, trailing \r included) against a literal LF-only string, so the exact
# match never fires and the file churns identically on every resume instead of
# ever getting rewritten.
test_migrate_handles_a_crlf_protocol_block() {
    local dir
    dir=$(create_test_session "crlfwordy")
    printf -- '<!-- cs:session-protocol -->\r\n# Session Documentation Protocol\r\n\r\nAppend only to your own; read all narrative.*.md on resume to restore your\r\nworking narrative and see teammates'"'"' in-progress findings.\r\n\r\n<!-- cs:memory-note -->\r\nnote\r\n' \
        > "$dir/CLAUDE.local.md"
    CS_ACTOR=alice "$CS_BIN" "crlfwordy" < /dev/null > /dev/null 2>&1 || true

    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "CRLF sentence rewritten" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "grep on demand, never preload" "with the live-plus-archive instruction" || return 1

    local once
    once=$(cat "$dir/CLAUDE.local.md")
    CS_ACTOR=alice "$CS_BIN" "crlfwordy" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$once" "$(cat "$dir/CLAUDE.local.md")" "second resume leaves the file byte-identical (no churn)" || return 1
}

run_test test_migrate_rewrites_the_older_protocol_wording
run_test test_migrate_handles_a_crlf_protocol_block

# Every Secure Secrets Handling section cs has written into a CLAUDE.local.md,
# heading first, oldest last, separated by a line of @@. The by-hand paths they
# describe store the value and delete the scratch file as two steps, pipe it,
# or pass it in argv; the current section stores and deletes in one Bash
# command from a mktemp file outside the session.
_secrets_section_vintages() {
    cat << 'EOF'
## Secure Secrets Handling

Secrets live in the cs session store, never in a project file. `cs -secrets set`
and the `store-secret` skill read the value on **stdin** via a file redirect —
never `echo`/`printf` a secret into a pipe or a Bash heredoc, either of which
puts the plaintext in the Bash command itself.

Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —
so it stays out of the tool result and the transcript. A retrieved value is read
by a command, never printed, echoed, piped, or written to a file (that includes
`cs -secrets export` output). `cs -secrets --help` lists the rest of the verbs.

**When you find a credential already in the workspace**, invoke the
`store-secret` skill — it carries the full procedure. Replace the literal with
the reference the file wants — `${API_KEY}` in a config, `$(cs -secrets get
API_KEY)` in a shell script. Doing it by hand instead, the safe path is exactly
this: write the value with the **Write** tool to a file OUTSIDE the session
directory (any Write inside it is snapshotted into the autosave ref and survives
`rm`), run `cs -secrets set NAME < that-file`, then delete the scratch file
immediately.
@@
## Secure Secrets Handling

Secrets live in the cs session store, never in a project file. `cs -secrets set`
and the `store-secret` skill read the value on **stdin** via a file redirect —
never `echo`/`printf` a secret into a pipe or a Bash heredoc: the bash-logger
records the whole Bash command, plaintext and all, in `.cs/local/session.log`.

Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —
so it stays out of the tool result and the transcript. A retrieved value is read
by a command, never printed, echoed, piped, or written to a file (that includes
`cs -secrets export` output). `cs -secrets --help` lists the rest of the verbs.

**When you find a credential already in the workspace**, invoke the
`store-secret` skill — it carries the full procedure. Replace the literal with
the reference the file wants — `${API_KEY}` in a config, `$(cs -secrets get
API_KEY)` in a shell script. Doing it by hand instead, the safe path is exactly
this: write the value with the **Write** tool to a file OUTSIDE the session
directory (any Write inside it is snapshotted into the autosave ref and survives
`rm`), run `cs -secrets set NAME < that-file`, then delete the scratch file
immediately.
@@
## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```
Never print or echo a retrieved secret, and don't paste `cs -secrets export` output into a file — consume the value inline, e.g. `some-command --token "$(cs -secrets get API_KEY)"`, so the plaintext stays out of the tool result and the session transcript.

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), invoke the `store-secret` skill and replace the literal
with a reference appropriate to the file — an env-var placeholder like
`${API_KEY}` in configs, or `$(cs -secrets get API_KEY)` in shell scripts —
noting that the value now lives in `cs -secrets`. The skill writes the value to
a scratch file with the Write tool (which the bash-logger does not capture),
feeds it in via a stdin redirect so the plaintext never reaches argv or the
command log (`cs -secrets set <name> < scratch-file`), and deletes the scratch
file afterward. If the skill is unavailable and you do this by hand, you MUST
delete the scratch file immediately after, and never `echo`/`printf` a secret
into a pipe — the bash-logger records the whole Bash command (secret and all)
in `.cs/local/session.log`.
@@
## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as CS_SECRET_<NAME> environment variables
```
Never print or echo a retrieved secret, and don't paste `cs -secrets export` output into a file — consume the value inline, e.g. `some-command --token "$(cs -secrets get API_KEY)"`, so the plaintext stays out of the tool result and the session transcript.

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), invoke the `store-secret` skill and replace the literal
with a reference appropriate to the file — an env-var placeholder like
`${API_KEY}` in configs, or `$(cs -secrets get API_KEY)` in shell scripts —
noting that the value now lives in `cs -secrets`. The skill writes the value to
a scratch file with the Write tool (which the bash-logger does not capture),
feeds it in via a stdin redirect so the plaintext never reaches argv or the
command log (`cs -secrets set <name> < scratch-file`), and deletes the scratch
file afterward. If the skill is unavailable and you do this by hand, you MUST
delete the scratch file immediately after, and never `echo`/`printf` a secret
into a pipe — the bash-logger records the whole Bash command (secret and all)
in `.cs/local/session.log`.
@@
## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), store it with the `store-secret` skill and replace it
with a reference. The skill writes the value to a scratch file with the Write
tool (which the bash-logger does not capture) and feeds it in via a stdin
redirect, so the plaintext never reaches argv or the command log:
```bash
cs -secrets set <name> < /path/to/scratch-file   # value on stdin, not in argv
```
Never `echo`/`printf` a secret into a pipe — the bash-logger records the whole
Bash command (secret and all) in `.cs/local/session.log`.
@@
## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), store it and replace it with a reference. Pass the value
on stdin so it never hits argv or the command log:
```bash
printf '%s' "the-secret-value" | cs -secrets set <name>
```
@@
## Secure Secrets Handling

Sensitive data is automatically detected and stored securely (macOS Keychain or encrypted file):

**Auto-detected patterns:**
- Files: .env, filenames containing key, secret, password, token, credential, auth
- Content: Variables like API_KEY, SECRET_TOKEN, PASSWORD, etc.

**What happens:**
1. Sensitive values are extracted and stored securely
2. The artifact file contains redacted placeholders
3. MANIFEST.json lists which secrets exist (not the values)

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** that wasn't auto-captured (unusual patterns, embedded credentials, etc.), use cs -secrets directly:
```bash
cs -secrets set <name> <value>     # Store manually
```
@@
## Secure Secrets Handling

Sensitive data is automatically detected and stored securely (macOS Keychain, Windows Credential Manager, or encrypted file):

**Auto-detected patterns:**
- Files: .env, filenames containing key, secret, password, token, credential, auth
- Content: Variables like API_KEY, SECRET_TOKEN, PASSWORD, etc.

**What happens:**
1. Sensitive values are extracted and stored securely
2. The artifact file contains redacted placeholders
3. MANIFEST.json lists which secrets exist (not the values)

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** that wasn't auto-captured (unusual patterns, embedded credentials, etc.), use cs -secrets directly:
```bash
cs -secrets set <name> <value>     # Store manually
```
EOF
}

# The one Secure Secrets Handling section of a file: its heading through the
# line before the next heading or sentinel, trailing blank lines dropped.
_secrets_section_of() {  # file
    awk '
        /^## Secure Secrets Handling$/ { f = 1 }
        f && (/^## / || /^<!-- /) && !/^## Secure Secrets Handling$/ { f = 0 }
        f { lines[++n] = $0 }
        END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
    ' "$1"
}

# A CLAUDE.local.md carrying the n-th vintage between a user block and the
# memory note, as an older session's file lies on disk. The other cs sections
# are tombstones, so no other phase appends to the file and a whole-file
# comparison across a resume measures this rewrite alone.
_write_secrets_fixture() {  # file, n
    {
        printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nUSER-KEEP above the section\n\n'
        _secrets_section_vintages | awk -v want="$2" 'BEGIN { n = 1 } /^@@$/ { n++; next } n == want { print }'
        printf '\n<!-- cs:memory-note -->\nnote body\n<!-- cs:wrap-cues -->\n<!-- cs:session-commits -->\n<!-- cs:mermaid-diagrams -->\n'
    } > "$1"
}

# A resume rewrites each section cs wrote to the section a new session gets
# today, and nothing around it. The expected text comes from the create path,
# not from this file.
test_migrate_rewrites_every_secrets_section_cs_wrote() {
    local dir fresh want n total
    "$CS_BIN" "freshsecrets" < /dev/null > /dev/null 2>&1 || true
    fresh="$CS_SESSIONS_ROOT/freshsecrets/CLAUDE.local.md"
    want=$(_secrets_section_of "$fresh")
    assert_output_contains "$want" 'rc=\$?; rm -f "\$f"; exit \$rc' "the fresh section stores and deletes in one command" || return 1
    total=$(_secrets_section_vintages | grep -c '^@@$')
    total=$((total + 1))
    n=1
    while [ "$n" -le "$total" ]; do
        dir=$(create_test_session "secrets$n")
        _write_secrets_fixture "$dir/CLAUDE.local.md" "$n"
        CS_ACTOR=alice "$CS_BIN" "secrets$n" < /dev/null > /dev/null 2>&1 || true
        assert_eq "$want" "$(_secrets_section_of "$dir/CLAUDE.local.md")" "vintage $n is rewritten to the current section" || return 1
        assert_eq "1" "$(grep -c '^## Secure Secrets Handling$' "$dir/CLAUDE.local.md")" "vintage $n keeps one section" || return 1
        assert_file_contains "$dir/CLAUDE.local.md" "USER-KEEP above the section" "vintage $n: the block before stays" || return 1
        assert_file_contains "$dir/CLAUDE.local.md" "^note body$" "vintage $n: the block after stays" || return 1
        n=$((n + 1))
    done
}

# A section the user edited, by one word anywhere in it, is theirs: the whole
# section stays byte for byte, the by-hand sentence included.
test_migrate_leaves_an_edited_secrets_section_alone() {
    local dir before
    dir=$(create_test_session "editedsecrets")
    _write_secrets_fixture "$dir/CLAUDE.local.md" 1
    sed 's/^Consume a secret inline/Consume every secret inline/' "$dir/CLAUDE.local.md" > "$dir/CLAUDE.local.md.edited"
    mv "$dir/CLAUDE.local.md.edited" "$dir/CLAUDE.local.md"
    assert_file_contains "$dir/CLAUDE.local.md" "^Consume every secret inline" "the fixture carries the edit" || return 1
    before=$(cat "$dir/CLAUDE.local.md")
    CS_ACTOR=alice "$CS_BIN" "editedsecrets" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$before" "$(cat "$dir/CLAUDE.local.md")" "an edited section is left byte for byte" || return 1
}

# The second resume finds the current section and writes nothing: the file's
# modification time stays where it was, so a stamp that keys on it stays fresh.
# The stamp the first resume wrote is removed in between, or the second resume
# would skip the phase for that reason alone.
test_migrate_secrets_rewrite_is_a_no_op_the_second_time() {
    local dir once
    dir=$(create_test_session "twicesecrets")
    _write_secrets_fixture "$dir/CLAUDE.local.md" 1
    CS_ACTOR=alice "$CS_BIN" "twicesecrets" < /dev/null > /dev/null 2>&1 || true
    once=$(cat "$dir/CLAUDE.local.md")
    rm -f "$dir/.cs/local/migrated"
    touch -t 202401010000 "$dir/CLAUDE.local.md"
    touch -t 202401010001 "$dir/.cs/README.md"
    CS_ACTOR=alice "$CS_BIN" "twicesecrets" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$once" "$(cat "$dir/CLAUDE.local.md")" "the second resume leaves the file byte-identical" || return 1
    if [ "$dir/CLAUDE.local.md" -nt "$dir/.cs/README.md" ]; then
        echo "  FAIL: the second resume rewrote CLAUDE.local.md (its mtime moved)"; return 1
    fi
}

# A CLAUDE.local.md with no Secure Secrets Handling section gets none from the
# rewrite and stays as it was.
test_migrate_leaves_a_file_without_a_secrets_section_alone() {
    local dir before
    dir=$(create_test_session "nosecrets")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nUSER-KEEP\n\n<!-- cs:memory-note -->\nnote body\n<!-- cs:wrap-cues -->\n<!-- cs:session-commits -->\n<!-- cs:mermaid-diagrams -->\n' > "$dir/CLAUDE.local.md"
    before=$(cat "$dir/CLAUDE.local.md")
    CS_ACTOR=alice "$CS_BIN" "nosecrets" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$before" "$(cat "$dir/CLAUDE.local.md")" "a file without the section is untouched" || return 1
}

run_test test_migrate_rewrites_every_secrets_section_cs_wrote
run_test test_migrate_leaves_an_edited_secrets_section_alone
run_test test_migrate_secrets_rewrite_is_a_no_op_the_second_time
run_test test_migrate_leaves_a_file_without_a_secrets_section_alone

# An encrypted session (.cs/private present) keeps its objective, outcome and
# session log in the vault, so its protocol gains a block that says so and
# overrides the plaintext-README instructions above it. Locked sessions are
# refused before migrate runs, so only the mounted case reaches this phase.
make_encrypted_test_session() {
    local dir
    dir=$(create_test_session "$1")
    mkdir -p "$TEST_TMPDIR/vault-$1/private"
    ln -s "$TEST_TMPDIR/vault-$1/private" "$dir/.cs/private"
    _mark_hand_made_vault "$dir"
    echo "$dir"
}

test_encrypted_session_gains_the_encrypted_protocol() {
    local dir out
    dir=$(make_encrypted_test_session "vaulted")
    out=$(CS_ACTOR=alice "$CS_BIN" "vaulted" < /dev/null 2>&1 || true)
    # Positive control: the open reached migrate_session's later phases.
    assert_file_contains "$dir/CLAUDE.local.md" "cs:wrap-cues" \
        "migrate ran on the encrypted session" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:encrypted-protocol" \
        "the encrypted session gains the encrypted-protocol block" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "top of your narrative" \
        "the objective and outcome go to the narrative" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '\.cs/private/session\.log' \
        "the block names the session log behind .cs/private" || return 1
    grep -Fxq -- '  CLAUDE.local.md  added the encrypted-session protocol' <<< "$out" \
        || { echo "  FAIL: the open says it added the encrypted-session protocol"; return 1; }
}

test_plain_session_has_no_encrypted_protocol() {
    local dir
    dir=$(create_test_session "plainproto")
    CS_ACTOR=alice "$CS_BIN" "plainproto" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:wrap-cues" \
        "migrate ran on the plain session" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "cs:encrypted-protocol" \
        "a plain session never gains the encrypted block" || return 1
}

test_encrypted_protocol_is_idempotent() {
    local dir once
    dir=$(make_encrypted_test_session "vaulttwice")
    CS_ACTOR=alice "$CS_BIN" "vaulttwice" < /dev/null > /dev/null 2>&1 || true
    once=$(cat "$dir/CLAUDE.local.md")
    CS_ACTOR=alice "$CS_BIN" "vaulttwice" < /dev/null > /dev/null 2>&1 || true
    assert_eq "1" "$(grep -c 'cs:encrypted-protocol' "$dir/CLAUDE.local.md")" \
        "the block is added once" || return 1
    assert_eq "$once" "$(cat "$dir/CLAUDE.local.md")" \
        "a second open leaves the file byte-identical" || return 1
}

test_migrate_adds_the_diagram_instruction_once() {
    local dir out
    dir=$(create_test_session "diagrams")
    printf '%s\n' '<!-- cs:session-protocol -->' 'Keep these project rules.' > "$dir/CLAUDE.local.md"
    out=$(CS_ACTOR=alice "$CS_BIN" diagrams < /dev/null 2>&1) \
        || { echo "  FAIL: migrating the diagram session failed"; return 1; }
    assert_eq "1" "$(grep -cFx '<!-- cs:mermaid-diagrams -->' "$dir/CLAUDE.local.md")" \
        "migration adds the diagram sentinel once" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '^Mermaid flowchart fences' \
        "migration adds the diagram instruction" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '^Keep these project rules\.$' \
        "migration keeps the existing rules" || return 1
    grep -Fxq -- '  CLAUDE.local.md  added the diagram instruction' <<< "$out" \
        || { echo "  FAIL: migration reports the added diagram instruction"; return 1; }
    cp "$dir/CLAUDE.local.md" "$TEST_TMPDIR/first-local"
    rm -f "$dir/.cs/local/migrated"
    out=$(CS_ACTOR=alice "$CS_BIN" diagrams <<< "" 2>&1) \
        || { echo "  FAIL: the second diagram migration failed: $out"; return 1; }
    cmp -s "$TEST_TMPDIR/first-local" "$dir/CLAUDE.local.md" \
        || { echo "  FAIL: the second diagram migration changed the file"; return 1; }
    assert_output_not_contains "$out" 'added the diagram instruction' \
        "the second migration reports no diagram addition" || return 1
}

test_migrate_preserves_the_diagram_tombstone() {
    local dir out
    dir=$(create_test_session "no-diagrams")
    printf '%s\n' '<!-- cs:mermaid-diagrams -->' > "$dir/CLAUDE.local.md"
    out=$(CS_ACTOR=alice "$CS_BIN" no-diagrams < /dev/null 2>&1) \
        || { echo "  FAIL: migrating the opted-out diagram session failed"; return 1; }
    assert_eq "1" "$(grep -cFx '<!-- cs:mermaid-diagrams -->' "$dir/CLAUDE.local.md")" \
        "migration preserves one diagram tombstone" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '^Mermaid flowchart fences' \
        "migration keeps the diagram instruction opted out" || return 1
    assert_output_not_contains "$out" 'added the diagram instruction' \
        "migration reports no diagram addition for a tombstone" || return 1
}

run_test test_migrate_adds_the_diagram_instruction_once
run_test test_migrate_preserves_the_diagram_tombstone
run_test test_encrypted_session_gains_the_encrypted_protocol
run_test test_plain_session_has_no_encrypted_protocol
run_test test_encrypted_protocol_is_idempotent

report_results
