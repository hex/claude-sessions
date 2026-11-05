#!/usr/bin/env bash
# ABOUTME: Tests for auto memory directory redirect into .cs/memory/
# ABOUTME: Validates settings.local.json creation, gitignore, and migration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
}

# ============================================================================
# Tests
# ============================================================================

test_new_session_creates_memory_dir() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created" || return 1
}

test_new_session_creates_settings_local() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_exists "$session_dir/.claude/settings.local.json" "settings.local.json should exist" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" "autoMemoryDirectory" \
        "settings.local.json should contain autoMemoryDirectory" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" ".cs/memory" \
        "autoMemoryDirectory should point to .cs/memory" || return 1
}

# A hand-edited settings.local.json that jq cannot parse must survive the merge.
# Redirecting jq's output straight onto the file truncates it before jq reads it,
# so a single trailing comma costs the user every setting in the file — and the
# damage is permanent, since jq on empty input succeeds and writes nothing.
test_unparseable_settings_local_survives_merge() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local settings="$CS_SESSIONS_ROOT/test-session/.claude/settings.local.json"
    printf '%s' '{ "permissions": { "allow": ["Bash(ls:*)"] }, }' > "$settings"
    local before
    before=$(cat "$settings")
    # Phase 4 only re-runs the merge when memory, plans or settings is missing.
    # A session predating plansDirectory is the state that reaches it with a
    # settings file already on disk.
    rm -rf "$CS_SESSIONS_ROOT/test-session/.cs/plans"

    # stdout only: create_worktree_session returns its directory by echoing it
    # and lib/99-main.sh captures that, so a complaint on stdout would land
    # inside a worktree session's path.
    local out
    out=$("$CS_BIN" test-session <<< "" 2>/dev/null) || true

    local after
    after=$(cat "$settings")
    assert_eq "$before" "$after" "unparseable settings.local.json must be left intact" || return 1
    local leftover
    leftover=$(find "$CS_SESSIONS_ROOT/test-session/.claude" -name '.settings.local.json.*' 2>/dev/null)
    [ -z "$leftover" ] || { echo "  FAIL: left a temp file behind: $leftover"; return 1; }
    assert_output_not_contains "$out" "Could not parse" \
        "the complaint belongs on stderr, where a command substitution cannot capture it" || return 1
    # The absence above is only half the contract: with the warn deleted
    # entirely it still holds, and the user is then left with a settings file cs
    # silently declined to touch. Pin that it is actually SAID, on stderr.
    rm -rf "$CS_SESSIONS_ROOT/test-session/.cs/plans"
    printf '%s' '{ "permissions": { "allow": ["Bash(ls:*)"] }, }' > "$settings"
    local err
    err=$("$CS_BIN" test-session <<< "" 2>&1 >/dev/null) || true
    assert_output_contains "$err" "Could not parse" \
        "cs must say it left the file alone, not decline in silence" || return 1
}

test_settings_local_is_gitignored() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_file_contains "$session_dir/.gitignore" ".claude/settings.local.json" \
        ".gitignore should exclude settings.local.json" || return 1
}

test_adopt_creates_memory_dir() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_dir "$project_dir/.cs/memory" ".cs/memory/ should be created on adopt" || return 1
    assert_exists "$project_dir/.claude/settings.local.json" \
        "settings.local.json should exist on adopt" || return 1
}

test_adopt_adds_settings_to_gitignore() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && echo "node_modules/" > .gitignore && git add -A && git commit -q -m "init")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_file_contains "$project_dir/.gitignore" ".claude/settings.local.json" \
        "Existing .gitignore should get settings.local.json entry" || return 1
}

test_migration_creates_memory_and_settings() {
    local session_dir="$CS_SESSIONS_ROOT/old-session"
    mkdir -p "$session_dir/.cs/local"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" old-session <<< "" 2>&1 || true

    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created on migration" || return 1
    assert_exists "$session_dir/.claude/settings.local.json" \
        "settings.local.json should be created on migration" || return 1
}

test_migration_moves_existing_auto_memory() {
    local session_dir="$CS_SESSIONS_ROOT/mem_session"
    mkdir -p "$session_dir/.cs/local"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    local encoded_path
    encoded_path=$(_encode_cwd_for_claude_test "$session_dir")
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    mkdir -p "$old_memory_dir"
    echo "build command: cargo test" > "$old_memory_dir/MEMORY.md"
    echo "debug notes here" > "$old_memory_dir/debugging.md"

    "$CS_BIN" mem_session <<< "" 2>&1 || true

    assert_exists "$session_dir/.cs/memory/MEMORY.md" \
        "MEMORY.md should be migrated to .cs/memory/" || return 1
    assert_file_contains "$session_dir/.cs/memory/MEMORY.md" "cargo test" \
        "MEMORY.md content should be preserved" || return 1
    assert_exists "$session_dir/.cs/memory/debugging.md" \
        "debugging.md should be migrated to .cs/memory/" || return 1

    if [[ -d "$old_memory_dir" ]] && [[ "$(ls -A "$old_memory_dir" 2>/dev/null)" ]]; then
        echo "  FAIL: old memory dir should be empty after migration"
        return 1
    fi

    rm -rf "$HOME/.claude/projects/${encoded_path}" 2>/dev/null || true
}

# A session whose next open runs the memory migration (no settings.local.json
# yet), plus the default-location memory dir Claude Code keeps for it. Prints
# the session dir, then the default memory dir, one per line.
_stage_memory_migration() {  # session_name
    local session_dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$session_dir/.cs/local" "$session_dir/.cs/memory"
    printf '# Session Documentation Protocol\n\nSession metadata lives in the .cs/ directory.\n' > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    local encoded_path
    encoded_path=$(_encode_cwd_for_claude_test "$session_dir")
    local default_dir="$HOME/.claude/projects/${encoded_path}/memory"
    mkdir -p "$default_dir"
    printf '%s\n%s\n' "$session_dir" "$default_dir"
}

# A name both sides hold with different content survives on both sides, and a
# subdirectory is copied whole: the migration deletes only what it has an
# identical copy of.
test_migration_keeps_colliding_memory_and_subdirs() {
    local staged session_dir default_dir
    staged=$(_stage_memory_migration mem-collide)
    session_dir=$(sed -n 1p <<< "$staged")
    default_dir=$(sed -n 2p <<< "$staged")
    printf 'session-index-line\n' > "$session_dir/.cs/memory/MEMORY.md"
    printf 'same bytes on both sides\n' > "$session_dir/.cs/memory/shared.md"
    printf 'default-index-line\n' > "$default_dir/MEMORY.md"
    printf 'same bytes on both sides\n' > "$default_dir/shared.md"
    mkdir -p "$default_dir/topics"
    printf 'nested-topic-line\n' > "$default_dir/topics/deep.md"

    "$CS_BIN" mem-collide <<< "" >/dev/null 2>&1 || true

    # The open appends its narrative pointer to MEMORY.md, so only the
    # session's own first line is pinned.
    assert_eq "session-index-line" "$(head -1 "$session_dir/.cs/memory/MEMORY.md")" \
        "the session's own MEMORY.md must keep its content" || return 1
    assert_eq "default-index-line" "$(cat "$session_dir/.cs/memory/MEMORY.md.claude-projects" 2>/dev/null)" \
        "the colliding default MEMORY.md must be kept beside it" || return 1
    assert_eq "same bytes on both sides" "$(cat "$session_dir/.cs/memory/shared.md")" \
        "an identical same-name file stays as it was" || return 1
    assert_not_exists "$session_dir/.cs/memory/shared.md.claude-projects" \
        "an identical same-name file needs no second copy" || return 1
    assert_eq "nested-topic-line" "$(cat "$session_dir/.cs/memory/topics/deep.md" 2>/dev/null)" \
        "a subdirectory's files must be copied" || return 1
    assert_not_exists "$default_dir" \
        "the default memory dir goes once every file has an identical copy" || return 1
}

# A destination reached through a symlink is not an independent copy: a
# session file linked back into the default dir, or a session subdirectory
# linked there, would pass the byte comparison and the source would be
# deleted from under the link. Such a file is left where it is, whole.
test_migration_keeps_a_source_the_destination_links_to() {
    local staged session_dir default_dir
    staged=$(_stage_memory_migration mem-linked)
    session_dir=$(sed -n 1p <<< "$staged")
    default_dir=$(sed -n 2p <<< "$staged")
    printf 'linked-topic-line\n' > "$default_dir/topic.md"
    ln -s "$default_dir/topic.md" "$session_dir/.cs/memory/topic.md"
    mkdir -p "$default_dir/topics"
    printf 'linked-dir-line\n' > "$default_dir/topics/deep.md"
    ln -s "$default_dir/topics" "$session_dir/.cs/memory/topics"

    "$CS_BIN" mem-linked <<< "" >/dev/null 2>&1 || true

    assert_eq "linked-topic-line" "$(cat "$default_dir/topic.md" 2>/dev/null)" \
        "a source the session links to must survive" || return 1
    assert_eq "linked-dir-line" "$(cat "$default_dir/topics/deep.md" 2>/dev/null)" \
        "a source under a linked directory must survive" || return 1
    [ -L "$session_dir/.cs/memory/topic.md" ] || { echo "  FAIL: the session's link was replaced"; return 1; }
    [ -L "$session_dir/.cs/memory/topics" ] || { echo "  FAIL: the session's directory link was replaced"; return 1; }
}

# The destination root itself can be a link back into the default dir (a
# vaulted session links .cs/memory elsewhere, so a linked root is a legal
# layout). Then every destination path is the source path: the byte
# comparison compares a file with itself, and deleting the source would
# delete the only copy. Such a root leaves the default dir whole.
test_migration_keeps_a_source_the_destination_root_links_to() {
    local staged session_dir default_dir
    staged=$(_stage_memory_migration mem-linked-root)
    session_dir=$(sed -n 1p <<< "$staged")
    default_dir=$(sed -n 2p <<< "$staged")
    rmdir "$session_dir/.cs/memory"
    ln -s "$default_dir" "$session_dir/.cs/memory"
    printf 'root-linked-line\n' > "$default_dir/topic.md"
    mkdir -p "$default_dir/topics"
    printf 'root-linked-deep-line\n' > "$default_dir/topics/deep.md"

    "$CS_BIN" mem-linked-root <<< "" >/dev/null 2>&1 || true

    assert_eq "root-linked-line" "$(cat "$default_dir/topic.md" 2>/dev/null)" \
        "a source the destination root links to must survive" || return 1
    assert_eq "root-linked-deep-line" "$(cat "$default_dir/topics/deep.md" 2>/dev/null)" \
        "a nested source under a linked root must survive" || return 1
    [ -L "$session_dir/.cs/memory" ] || { echo "  FAIL: the session's memory root link was replaced"; return 1; }
    [ -d "$session_dir/.cs/memory/" ] || { echo "  FAIL: the session's memory root link dangles"; return 1; }
}

# A copy that fails stops the migration before anything is deleted, including
# the files that did copy.
test_migration_failed_copy_deletes_nothing() {
    local staged session_dir default_dir
    staged=$(_stage_memory_migration mem-fail)
    session_dir=$(sed -n 1p <<< "$staged")
    default_dir=$(sed -n 2p <<< "$staged")
    # A file where the copy needs a directory makes the nested copy fail.
    printf 'session file named topics\n' > "$session_dir/.cs/memory/topics"
    printf 'top-level-line\n' > "$default_dir/top.md"
    mkdir -p "$default_dir/topics"
    printf 'nested-topic-line\n' > "$default_dir/topics/deep.md"

    "$CS_BIN" mem-fail <<< "" >/dev/null 2>&1 || true

    assert_eq "top-level-line" "$(cat "$default_dir/top.md" 2>/dev/null)" \
        "a failed copy must leave every default memory file in place" || return 1
    assert_eq "nested-topic-line" "$(cat "$default_dir/topics/deep.md" 2>/dev/null)" \
        "the file whose copy failed must stay in place" || return 1
    assert_eq "session file named topics" "$(cat "$session_dir/.cs/memory/topics")" \
        "the session's own file must be untouched" || return 1
}

# A logs/ dir alone does not make a directory a flat-layout cs session: the
# flat-layout migration moves README.md and rewrites .gitignore, so it must
# leave a project that only happens to keep logs alone.
test_open_leaves_a_project_with_only_a_logs_dir_unmigrated() {
    local dir="$CS_SESSIONS_ROOT/plain-project"
    mkdir -p "$dir/logs"
    printf 'app started\n' > "$dir/logs/app.log"
    printf '# Plain project\n\nPROJECT-README-KEEP\n' > "$dir/README.md"
    printf 'secret.key\n' > "$dir/.gitignore"

    "$CS_BIN" plain-project <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$dir/README.md" '^PROJECT-README-KEEP$' \
        "the project's README.md must stay at its root" || return 1
    assert_file_contains "$dir/.gitignore" '^secret\.key$' \
        "the project's .gitignore rule must survive" || return 1
    assert_not_exists "$dir/.cs/logs" "the project's logs/ must not be moved into .cs/" || return 1
    assert_exists "$dir/logs/app.log" "the project's log must stay where it was" || return 1
}

# A flat-layout session cs created (its logs/session.log opens with cs's
# header) still migrates into .cs/.
test_open_migrates_a_flat_layout_session() {
    local dir="$CS_SESSIONS_ROOT/flat-session"
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n\nFLAT-LOG-LINE\n' > "$dir/logs/session.log"
    printf '# Session: flat-session\n\nFLAT-README-LINE\n' > "$dir/README.md"
    printf '# Session Documentation Protocol\n\nThis is a Claude Code session managed by the cs tool.\n' > "$dir/CLAUDE.md"

    "$CS_BIN" flat-session <<< "" >/dev/null 2>&1 || true

    assert_not_exists "$dir/README.md" "the session README moves out of the root" || return 1
    assert_file_contains "$dir/.cs/README.md" '^FLAT-README-LINE$' \
        "the session README lands in .cs/" || return 1
    assert_file_contains "$dir/.cs/local/session.log" '^FLAT-LOG-LINE$' \
        "the session log lands in .cs/local/" || return 1
}

# Codex r2 #1: a flat-layout session moves its root README.md into .cs/ and
# then rewrites it. A README.md committed as a link out of the session must
# stop the open before the move, so nothing lands outside.
test_flat_layout_readme_linked_out_of_the_session_refuses_open() {
    local dir="$CS_SESSIONS_ROOT/flat-session" t outside out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-readme"
    printf 'USER-OWNED\n' > "$outside"
    mkdir -p "$dir/logs"
    printf 'Claude Code Session Log\nSession: flat-session\n\nFLAT-LOG-LINE\n' > "$dir/logs/session.log"
    ln -s "$outside" "$dir/README.md"
    printf '# Session Documentation Protocol\n\nThis is a Claude Code session managed by the cs tool.\n' > "$dir/CLAUDE.md"
    _make_launch_sentinel

    out=$(env -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR \
        "$CS_BIN" flat-session <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: README.md is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# ============================================================================
# Frontmatter migration for old sessions
# ============================================================================

# Helper: create an old-style session (no frontmatter in README)
create_old_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    # Old README.md: no frontmatter, starts with heading
    cat > "$session_dir/.cs/README.md" << 'EOF'
# Session: test-old

**Started:** 2026-03-15 10:30:00
**Location:** macbook:~/projects

## Objective

Fix the database connection pooling issue

## Environment

Production PostgreSQL server

## Outcome

[pending]
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m "init")
}

test_migration_adds_frontmatter_to_old_readme() {
    create_old_session "test-old"
    # Verify no frontmatter before migration
    local first_line
    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "# Session: test-old" "$first_line" "Old README should not have frontmatter" || return 1

    # Open session to trigger migration
    local out
    out=$("$CS_BIN" test-old <<< "" 2>&1 || true)

    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "---" "$first_line" "Migrated README should have frontmatter" || return 1
    grep -Fxq -- '  .cs/README.md    added frontmatter' <<< "$out" \
        || { echo "  FAIL: the open says it added frontmatter to the README"; return 1; }
}

test_migration_preserves_existing_content() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "database connection pooling" \
        "Migration should preserve objective text" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "Production PostgreSQL" \
        "Migration should preserve environment text" || return 1
}

test_migration_derives_created_date() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should derive created date from the "Started:" line (2026-03-15)
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "created: 2026-03-15" \
        "Should derive created date from Started line" || return 1
}

# A README with no Started line that git never recorded takes its created date
# from its mtime. Homebrew's gnubin puts GNU stat first on a Mac's PATH, and
# the date is still read in the dialect that stat speaks, not the one OSTYPE
# names.
test_migration_dates_an_untracked_readme_by_mtime_with_gnu_stat_first_on_a_mac() {
    local gnubin session_dir="$CS_SESSIONS_ROOT/test-old"
    gnubin=$(_gnu_stat_first_dir) || { echo "    SKIP: no GNU stat on this machine"; return 77; }
    create_old_session "test-old"
    (cd "$session_dir" && rm -rf .git && git init -q -b main && git config user.email t@t \
        && git config user.name T && git add CLAUDE.md && git commit -q -m "init without the README")
    sed -i.bak '/^\*\*Started:\*\*/d' "$session_dir/.cs/README.md" && rm -f "$session_dir/.cs/README.md.bak"
    touch -t 202001020304 "$session_dir/.cs/README.md"
    assert_eq "" "$(git -C "$session_dir" log --diff-filter=A --format=%as -- .cs/README.md)" \
        "git holds no date for the README" || return 1

    PATH="$gnubin:$PATH" OSTYPE=darwin "$CS_BIN" test-old <<< "" >/dev/null 2>&1 || true

    assert_eq "created: 2020-01-02" "$(grep '^created:' "$session_dir/.cs/README.md")" \
        "the created date is the README's mtime" || return 1
}

test_migration_adds_aliases_from_session_name() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'aliases:' \
        "Should add aliases" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'test-old' \
        "Aliases should contain session name" || return 1
}

test_migration_skips_if_frontmatter_exists() {
    create_old_session "test-old"
    # Manually add frontmatter
    local readme="$CS_SESSIONS_ROOT/test-old/.cs/README.md"
    local content
    content=$(cat "$readme")
    {
        echo "---"
        echo "status: completed"
        echo "created: 2026-01-01"
        echo "tags: [custom]"
        echo 'aliases: ["my-custom-alias"]'
        echo "---"
        echo "$content"
    } > "$readme"

    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should NOT overwrite existing frontmatter
    assert_file_contains "$readme" "status: completed" \
        "Should preserve existing status" || return 1
    assert_file_contains "$readme" "created: 2026-01-01" \
        "Should preserve existing created date" || return 1
    assert_file_contains "$readme" "my-custom-alias" \
        "Should preserve existing aliases" || return 1
}

# ============================================================================
# Session narrative topic file (narrative.md) — relocation of discoveries
# ============================================================================

test_new_session_creates_narrative_file() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$CS_SESSIONS_ROOT/test-session/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_exists "$narrative" "a per-actor narrative file should be created in .cs/memory/" || return 1
    assert_file_contains "$narrative" "type: narrative" \
        "narrative should carry the narrative type" || return 1
}

test_new_session_adds_narrative_pointer() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local index="$CS_SESSIONS_ROOT/test-session/.cs/memory/MEMORY.md"
    assert_file_contains "$index" "](narrative." \
        "MEMORY.md should carry a pointer to the per-actor narrative" || return 1
}

test_narrative_pointer_idempotent_readd() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local session_dir="$CS_SESSIONS_ROOT/test-session"
    # Simulate the harness regenerating MEMORY.md and dropping the pointer
    : > "$session_dir/.cs/memory/MEMORY.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init 2>/dev/null) || true

    "$CS_BIN" test-session <<< "" 2>&1 || true

    local index="$session_dir/.cs/memory/MEMORY.md"
    assert_file_contains "$index" "](narrative." \
        "Dropped narrative pointer should be re-added on resume" || return 1
    # Must not duplicate when already present
    local count
    count=$(grep -c '](narrative\.' "$index")
    assert_eq "1" "$count" "narrative pointer should appear exactly once" || return 1
}

test_resume_folds_discoveries_into_narrative() {
    local session_dir="$CS_SESSIONS_ROOT/disc-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## A real finding worth keeping
The widget frobnicator needs a retry on EAGAIN.
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" disc-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "frobnicator needs a retry on EAGAIN" \
        "discoveries content should be folded into the narrative on resume" || return 1
    # One-shot: the original is consumed so it is not re-folded
    if [ -f "$session_dir/.cs/discoveries.md" ]; then
        echo "  FAIL: discoveries.md should be consumed after fold"
        return 1
    fi
}

test_discoveries_fold_header_uses_git_date() {
    # The fold header date must come from shared git history, not the local
    # clock — two machines folding the same legacy discoveries.md on
    # different days would otherwise write divergent blocks into the same
    # tracked narrative and conflict on merge.
    local session_dir="$CS_SESSIONS_ROOT/disc-dated"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## A dated finding
Dated content.
EOF
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git config user.email t@t \
        && git config user.name T && git add -A \
        && GIT_AUTHOR_DATE="2026-01-15T09:00:00" GIT_COMMITTER_DATE="2026-01-15T09:00:00" \
           git commit -q -m init)

    "$CS_BIN" disc-dated <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "Folded from discoveries.md (2026-01-15)" \
        "fold header should carry the git date of discoveries.md, not today" || return 1
}

test_resume_folds_compact_when_discoveries_header_only() {
    local session_dir="$CS_SESSIONS_ROOT/compact-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    # Active file is header-only, but the compact companion holds real content
    printf '# Discoveries & Notes\n\n' > "$session_dir/.cs/discoveries.md"
    cat > "$session_dir/.cs/discoveries.compact.md" << 'EOF'
## Condensed finding from an earlier compaction
The cache must be invalidated on tenant switch.
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" compact-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "invalidated on tenant switch" \
        "compact.md content must be folded even when discoveries.md is header-only" || return 1
    if [ -f "$session_dir/.cs/discoveries.compact.md" ]; then
        echo "  FAIL: discoveries.compact.md should be consumed after fold"
        return 1
    fi
}

# ============================================================================
# Encrypted storage: .cs/memory and .cs/plans as symlinks into a mountpoint
# ============================================================================

# A session whose memory and plans live on an encrypted volume mounted at
# .cs/vault-mnt, the layout session `rel` uses. Unmounting removes the
# mountpoint, which leaves both symlinks dangling.
_make_vaulted_session() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
    mkdir -p "$meta/vault-mnt"
    mv "$meta/memory" "$meta/vault-mnt/memory"
    mv "$meta/plans" "$meta/vault-mnt/plans"
    ln -s "$meta/vault-mnt/memory" "$meta/memory"
    ln -s "$meta/vault-mnt/plans" "$meta/plans"
}

test_unmounted_storage_refuses_open() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/memory points at $meta/vault-mnt/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling link and nothing else" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
    assert_not_exists "$meta/vault-mnt" "nothing may be created where the volume mounts" || return 1
}

# Writes .cs/local/pre-open with the given body and makes it executable.
_write_pre_open() {  # session, body
    local hook="$CS_SESSIONS_ROOT/$1/.cs/local/pre-open"
    printf '#!/bin/bash\n%s\n' "$2" > "$hook"
    chmod +x "$hook"
}

test_pre_open_mounts_then_session_opens() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _write_pre_open vt "pwd -P > \"$TEST_TMPDIR/pre-open-cwd\"; mv \"$TEST_TMPDIR/unmounted\" .cs/vault-mnt"
    _make_launch_sentinel

    local rc=0
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "cs should open once pre-open mounted the storage" || return 1
    assert_eq "launched" "$(cat "$TEST_TMPDIR/launched" 2>/dev/null)" "claude should launch once" || return 1
    assert_eq "$(cd "$CS_SESSIONS_ROOT/vt" && pwd -P)" "$(cat "$TEST_TMPDIR/pre-open-cwd")" \
        "pre-open should run in the session directory" || return 1
}

test_pre_open_failure_aborts_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "exit 3"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/local/pre-open exited 3; not opening the session." "$out" \
        "cs should name the failed pre-open and its status" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_pre_open_not_executable_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "exit 0"
    chmod -x "$CS_SESSIONS_ROOT/vt/.cs/local/pre-open"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/local/pre-open is not executable; chmod +x it, or remove it." "$out" \
        "cs should refuse a pre-open it cannot run rather than skip it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# .cs/local/ is gitignored, but `git add -f` can still commit a file there, and
# a clone then checks it out. A committed pre-open would run code from whoever
# wrote the repo, so cs refuses one git tracks.
test_pre_open_tracked_by_git_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$CS_SESSIONS_ROOT/vt" add -f .cs/local/pre-open
    git -C "$CS_SESSIONS_ROOT/vt" commit -q -m "track pre-open"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local/pre-open is tracked in git (per-actor state must stay local). Fix with: git -C $CS_SESSIONS_ROOT/vt --literal-pathspecs rm -r --cached -- .cs/local && git -C $CS_SESSIONS_ROOT/vt commit -m 'stop tracking .cs/local'" \
        "$out" "cs should refuse a committed .cs/local before running anything in it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the committed pre-open must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A clone can commit the three files that make a directory a bare git
# directory (HEAD, objects/, refs/) into .cs/local or .cs beside a pre-open.
# git asked there would answer from that directory as from inside a
# repository's git directory and run the commands its config names, so cs
# refuses on the HEAD before it asks git anything.
test_pre_open_tracked_beside_planted_git_directory_files_is_refused() {
    local root="$CS_SESSIONS_ROOT/vt" at out rc
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    _make_launch_sentinel
    for at in .cs/local .cs; do
        mkdir -p "$root/$at/objects" "$root/$at/refs"
        printf 'ref: refs/heads/main\n' > "$root/$at/HEAD"
        : > "$root/$at/objects/k"
        : > "$root/$at/refs/k"
        git -C "$root" add -f .cs/local/pre-open "$at/HEAD" "$at/objects/k" "$at/refs/k"
        git -C "$root" commit -q -m "ship a pre-open beside git directory files in $at"
        rc=0
        out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
        assert_eq "1" "$rc" "cs should exit 1 with the files in $at" || return 1
        assert_eq "Error: $at holds HEAD, so git takes it for a repository and would run commands its config names (cs state must be a plain directory inside the session). Delete $at/HEAD, or cs -rm the session." \
            "$out" "cs should refuse before asking git, naming the HEAD, with the files in $at" || return 1
        assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the committed pre-open must not run with the files in $at" || return 1
        assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch with the files in $at" || return 1
        git -C "$root" rm -q -r --cached "$at/HEAD" "$at/objects" "$at/refs"
        rm -rf "$root/$at/HEAD" "$root/$at/objects" "$root/$at/refs"
    done
}

# A case-insensitive checkout (macOS by default) puts a committed
# .cs/LOCAL/pre-open at .cs/local/pre-open on disk, where a case-sensitive
# pathspec never sees it. The commit is built in the index so the fixture
# holds the upper-case path on every filesystem.
test_pre_open_tracked_under_a_case_variant_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" blob
    printf '#!/bin/bash\ntouch "%s/pre-open-ran"\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/hook"
    blob=$(git -C "$root" hash-object -w "$TEST_TMPDIR/hook")
    git -C "$root" update-index --add --cacheinfo "100755,$blob,.cs/LOCAL/pre-open"
    git -C "$root" commit -q -m "ship a pre-open under a case variant"
    git -C "$root" checkout -q -- .cs/LOCAL/pre-open
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/LOCAL/pre-open is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- .cs/LOCAL && git -C $root commit -m 'stop tracking .cs/LOCAL'" \
        "$out" "cs should refuse the case variant before running anything behind it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the committed pre-open must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A repository as a clone delivers it: one commit holding a session README.
_upstream_session_repo() {  # dir
    mkdir -p "$1/.cs"
    git -C "$1" init -q -b main
    git -C "$1" config user.email jane.roe@example.com
    git -C "$1" config user.name "Jane Roe"
    printf -- '---\nstatus: active\ncreated: 2026-01-01\n---\n# vt\n\n## Objective\n\nx\n' > "$1/.cs/README.md"
    git -C "$1" add -f .cs/README.md
    git -C "$1" commit -q -m init
}

# Commits a task queue the way `cs -queue start` leaves one: a task file and a
# state file that says the user armed the run.
_commit_armed_queue() {  # repo, directory relative to the repo
    mkdir -p "$1/$2/queue"
    printf 'armed\n' > "$1/$2/queue.state"
    printf 'a task the repository wrote\n' > "$1/$2/queue/0000000001-task"
    git -C "$1" add -f "$2"
    git -C "$1" commit -q -m "ship a queue"
}

# With .cs/private present cs reads the queue, the mailbox and the rotation
# marker from it, so a repository that commits one hands cs a queue the user
# never armed. Refused like the same files under .cs/local.
test_cs_files_tracked_in_cs_private_are_refused() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt"
    _upstream_session_repo "$up"
    _commit_armed_queue "$up" .cs/private
    git clone -q "$up" "$root"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- .cs/private && git -C $root commit -m 'stop tracking .cs/private'" \
        "$out" "cs should refuse a committed .cs/private before it reads a queue from it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# The same queue behind a committed link: .cs/private points at a directory
# the repository also tracks, so no path under .cs/private is in the index.
test_cs_files_tracked_behind_a_cs_private_link_are_refused() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt"
    _upstream_session_repo "$up"
    ln -s vault-mnt/private "$up/.cs/private"
    git -C "$up" add .cs/private
    _commit_armed_queue "$up" .cs/vault-mnt/private
    git clone -q "$up" "$root"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/vault-mnt/private/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- .cs/vault-mnt/private && git -C $root commit -m 'stop tracking .cs/vault-mnt/private'" \
        "$out" "cs should refuse tracked files behind the .cs/private link" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# The repository names the directory its link points at, and the refusal
# prints a command with that name in it for the user to run. The name is
# quoted for the shell, so pasting the command runs git and nothing else.
test_the_untrack_command_quotes_a_directory_name_the_repository_chose() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt" evil="v; touch pwned"
    _upstream_session_repo "$up"
    ln -s "$evil/private" "$up/.cs/private"
    git -C "$up" add .cs/private
    _commit_armed_queue "$up" ".cs/$evil/private"
    git clone -q "$up" "$root"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/v__touch_pwned/private/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- .cs/v\;\\ touch\\ pwned/private && git -C $root commit -m 'stop tracking .cs/v__touch_pwned/private'" \
        "$out" "the path in the command is quoted, and the commit message holds no shell character" || return 1
}

# git reads a path on its command line as a pattern, so a directory the
# repository named "*" would make the printed command untrack every file.
# The command says the path is literal: run as printed, it untracks that
# directory and leaves the rest of the repository tracked.
test_the_untrack_command_untracks_only_the_directory_it_names() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt"
    _upstream_session_repo "$up"
    ln -s '../*' "$up/.cs/private"
    git -C "$up" add .cs/private
    mkdir -p "$up/*/queue"
    printf 'armed\n' > "$up/*/queue.state"
    printf 'a task the repository wrote\n' > "$up/*/queue/0000000001-task"
    git -C "$up" add -f -- ':(literal)*'
    git -C "$up" commit -q -m "ship a queue"
    git clone -q "$up" "$root"
    git -C "$root" config user.email jane.roe@example.com
    git -C "$root" config user.name "Jane Roe"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: _/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- \\* && git -C $root commit -m 'stop tracking _'" \
        "$out" "the command names the directory as a literal path" || return 1
    (cd "$TEST_TMPDIR" && bash -c "${out#*Fix with: }") >/dev/null 2>&1 \
        || { echo "  FAIL: the printed command should run"; return 1; }
    assert_eq "" "$(git -C "$root" ls-files -- ':(literal)*')" "the directory is no longer tracked" || return 1
    assert_eq ".cs/README.md .cs/private" "$(git -C "$root" ls-files | tr '\n' ' ' | sed 's/ $//')" \
        "every other file is still tracked" || return 1
}

# Command substitution drops a trailing newline, so a directory whose name
# ends in one must not be asked about under the name without it.
test_tracked_files_in_a_directory_named_with_a_trailing_newline_are_seen() {
    local s="$TEST_TMPDIR/s" d out rc=0
    d="$s/payload"$'\n'
    mkdir -p "$s/.cs" "$d"
    git -C "$s" init -q
    ln -s $'../payload\n' "$s/.cs/private"
    printf 'x\n' > "$d/seed"
    git -C "$s" add .cs/private "$d/seed"
    out=$(bash -c 'source "$1"; cs_tracked_files_notice "$2" "$3"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/private" "$s") || rc=$?
    assert_eq "0" "$rc" "the tracked file is found" || return 1
    assert_eq "payload_/seed is tracked in git (per-actor state must stay local). Fix with: git -C $s --literal-pathspecs rm -r --cached -- \$'payload\\n' && git -C $s commit -m 'stop tracking payload_'" \
        "$out" "the notice names the file and quotes the directory" || return 1
}

# git answers the repository's top and the directory's place in it one line
# each; a repository whose own name ends in a newline still has its tracked
# file found and named.
test_tracked_files_in_a_repository_named_with_a_trailing_newline_are_seen() {
    local s="$TEST_TMPDIR/s"$'\n' out rc=0
    mkdir -p "$s/.cs/local"
    git -C "$s" init -q
    printf 'armed\n' > "$s/.cs/local/queue.state"
    git -C "$s" add .cs/local/queue.state
    out=$(bash -c 'source "$1"; cs_tracked_files_notice "$2" "$3"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/local" "$s") || rc=$?
    assert_eq "0" "$rc" "the tracked file is found" || return 1
    assert_eq ".cs/local/queue.state is tracked in git (per-actor state must stay local). Fix with: git -C $(printf '%q' "$s") --literal-pathspecs rm -r --cached -- .cs/local && git -C $(printf '%q' "$s") commit -m 'stop tracking .cs/local'" \
        "$out" "the notice names the file and quotes the repository" || return 1
}

# In that one-call-per-answer fallback, the message carries the error of the
# call that failed. Real git fails both calls or neither, so a stand-in git
# fails only the --show-prefix call and runs the real git for every other.
test_a_failed_answer_in_the_newline_fallback_names_that_calls_error() {
    local s="$TEST_TMPDIR/s"$'\n' bin="$TEST_TMPDIR/stand-in" real_git out rc=0
    real_git=$(command -v git)
    mkdir -p "$s/.cs/local" "$bin"
    git -C "$s" init -q
    printf 'armed\n' > "$s/.cs/local/queue.state"
    git -C "$s" add .cs/local/queue.state
    printf '#!/bin/bash\nif [ "$#" = 6 ] && [ "$5" = rev-parse ] && [ "$6" = --show-prefix ]; then\n    printf "asked\\n" >> %q\n    printf "fatal: the stand-in refuses --show-prefix\\n" >&2\n    exit 128\nfi\nexec %q "$@"\n' \
        "$TEST_TMPDIR/stand-in-asked" "$real_git" > "$bin/git"
    chmod +x "$bin/git"
    out=$(PATH="$bin:$PATH" bash -c 'source "$1"; cs_tracked_files_notice "$2" "$3"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/local" "$s") || rc=$?
    assert_file_exists "$TEST_TMPDIR/stand-in-asked" "the stand-in was asked for the prefix" || return 1
    assert_eq "0" "$rc" "the check refuses" || return 1
    assert_eq "cs could not ask git whether it tracks a file in .cs/local: fatal: the stand-in refuses --show-prefix" \
        "$out" "and names the error of the call that failed" || return 1
}

# A .cs/private that leads to the session itself would have cs keep its queue
# among the project's files, and the command that untracks a directory would
# untrack the project. The open names the link instead and prints no command.
test_a_cs_private_link_to_the_session_itself_is_refused_without_an_untrack_command() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt"
    _upstream_session_repo "$up"
    ln -s .. "$up/.cs/private"
    git -C "$up" add .cs/private
    git -C "$up" commit -q -m "link private to the session"
    git clone -q "$up" "$root"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private leads to a directory that holds this session's own files, where git tracks .cs/README.md (per-actor state must stay local). Make .cs/private a directory of its own." \
        "$out" "the refusal names the link and prints no command" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# bash 3.2 quotes a path that starts with "~" as it is, and a shell then reads
# it as a home directory: the command names the path from the current one.
test_the_untrack_command_names_a_directory_called_tilde_as_a_path() {
    local s="$TEST_TMPDIR/s" out rc=0
    mkdir -p "$s/.cs" "$s/~"
    git -C "$s" init -q
    ln -s '../~' "$s/.cs/private"
    printf 'x\n' > "$s/~/seed"
    git -C "$s" add .cs/private "$s/~/seed"
    out=$(/bin/bash -c 'source "$1"; cs_tracked_files_notice "$2" "$3"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/private" "$s") || rc=$?
    assert_eq "0" "$rc" "the tracked file is found" || return 1
    assert_eq "_/seed is tracked in git (per-actor state must stay local). Fix with: git -C $s --literal-pathspecs rm -r --cached -- ./~ && git -C $s commit -m 'stop tracking _'" \
        "$out" "the command names ./~" || return 1
}

# zsh reads a word that starts with "=" as a command's path (=git is
# /usr/bin/git) and printf %q leaves it bare: the command names the path from
# the current one.
test_the_untrack_command_names_a_directory_called_equals_as_a_path() {
    local s="$TEST_TMPDIR/s" out rc=0
    mkdir -p "$s/.cs" "$s/=git"
    git -C "$s" init -q
    ln -s '../=git' "$s/.cs/private"
    printf 'x\n' > "$s/=git/seed"
    git -C "$s" add .cs/private "$s/=git/seed"
    out=$(bash -c 'source "$1"; cs_tracked_files_notice "$2" "$3"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/private" "$s") || rc=$?
    assert_eq "0" "$rc" "the tracked file is found" || return 1
    assert_eq "_git/seed is tracked in git (per-actor state must stay local). Fix with: git -C $s --literal-pathspecs rm -r --cached -- ./=git && git -C $s commit -m 'stop tracking _git'" \
        "$out" "the command names ./=git" || return 1
}

# A tracked file the repository gave a long name is named by its first 160
# characters, while the command to paste and its commit message keep the
# directory's whole name, so the command still untracks that directory.
test_the_refusal_cuts_a_long_tracked_name_and_keeps_the_command_whole() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt" long first
    long=$(printf 'x%.0s' $(seq 1 170))
    first=$(printf 'x%.0s' $(seq 1 156))
    _upstream_session_repo "$up"
    ln -s "$long/private" "$up/.cs/private"
    git -C "$up" add .cs/private
    _commit_armed_queue "$up" ".cs/$long/private"
    git clone -q "$up" "$root"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/$first is tracked in git (per-actor state must stay local). Fix with: git -C $root --literal-pathspecs rm -r --cached -- .cs/$long/private && git -C $root commit -m 'stop tracking .cs/$long/private'" \
        "$out" "the file is named by its first 160 characters and the command by the whole path" || return 1
}

# The refusal is about what git tracks: the same queue in a .cs/private made
# by hand and never committed opens.
test_an_untracked_cs_private_directory_opens() {
    local up="$TEST_TMPDIR/upstream" root="$CS_SESSIONS_ROOT/vt"
    _upstream_session_repo "$up"
    git clone -q "$up" "$root"
    mkdir -p "$root/.cs/private/queue"
    printf 'armed\n' > "$root/.cs/private/queue.state"
    printf 'a task the user queued\n' > "$root/.cs/private/queue/0000000001-task"
    _make_launch_sentinel

    local rc=0
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_file_contains "$TEST_TMPDIR/launched" "launched" "claude should launch" || return 1
    assert_eq "armed" "$(cat "$root/.cs/private/queue.state")" "the user's queue stays as it was" || return 1
}

# A vault set up by hand can sit anywhere, and most places are in no git
# repository at all: asking git about such a .cs/private finds nothing
# tracked, and the session opens.
test_a_cs_private_link_into_a_vault_outside_any_repository_opens() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local meta="$CS_SESSIONS_ROOT/vt/.cs" vault="$TEST_TMPDIR/vault"
    mkdir -p "$vault/private"
    mv "$meta/local/session.log" "$vault/private/session.log"
    ln -s "$vault/private" "$meta/private"
    _mark_hand_made_vault "$CS_SESSIONS_ROOT/vt"
    assert_eq "" "$(git -C "$vault/private" rev-parse --git-dir 2>/dev/null)" "the fixture's vault is in no repository" || return 1
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "0" "$rc" "cs should open the session: $out" || return 1
    assert_file_contains "$TEST_TMPDIR/launched" "launched" "claude should launch" || return 1
}

# The hooks record their own answer about tracked files in a shell variable.
# A value of that name inherited from the environment is nobody's answer: cs
# opens the session as if it were not there.
test_an_inherited_tracked_files_answer_does_not_stop_the_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    _make_launch_sentinel

    local out rc=0
    out=$(CS_TRACKED_FILES_META="$root/.cs" CS_TRACKED_FILES_NOTICE="x" "$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "0" "$rc" "cs should open the session: $out" || return 1
    assert_file_contains "$TEST_TMPDIR/launched" "launched" "claude should launch" || return 1
}

# The refusals at the open ask git about the session's own repository. A
# shell can name another one: GIT_DIR and GIT_WORK_TREE point git elsewhere,
# GIT_INDEX_FILE swaps the index (git hands one to every commit hook), and
# GIT_CEILING_DIRECTORIES stops it finding the repository at all. Opens vt
# plain, checks that refusal, then opens it under each variable: the answer
# must be the same one.
_assert_refused_under_any_git_environment() {  # text the refusal holds
    local root="$CS_SESSIONS_ROOT/vt" plain plain_rc=0 out rc var
    mkdir -p "$TEST_TMPDIR/elsewhere"
    git -C "$TEST_TMPDIR/elsewhere" init -q
    _make_launch_sentinel
    plain=$("$CS_BIN" vt <<< "" 2>&1) || plain_rc=$?
    assert_eq "1" "$plain_rc" "cs should refuse with no git variable set: $plain" || return 1
    assert_output_contains "$plain" "$1" "the fixture reaches the refusal under test" || return 1
    for var in "GIT_INDEX_FILE=/dev/null" "GIT_DIR=$TEST_TMPDIR/elsewhere/.git" \
               "GIT_WORK_TREE=$TEST_TMPDIR/elsewhere" "GIT_CEILING_DIRECTORIES=$root/.cs:$root"; do
        rc=0
        out=$(env "$var" "$CS_BIN" vt <<< "" 2>&1) || rc=$?
        assert_eq "1" "$rc" "cs should refuse with ${var%%=*} set: $out" || return 1
        assert_eq "$plain" "$out" "the refusal is the same with ${var%%=*} set" || return 1
    done
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_a_tracked_pre_open_is_refused_whatever_repository_the_shell_names() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$CS_SESSIONS_ROOT/vt" add -f .cs/local/pre-open
    git -C "$CS_SESSIONS_ROOT/vt" commit -q -m "track pre-open"
    _assert_refused_under_any_git_environment ".cs/local/pre-open is tracked in git" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the committed pre-open must not run" || return 1
}

test_tracked_cs_private_is_refused_whatever_repository_the_shell_names() {
    local up="$TEST_TMPDIR/upstream"
    _upstream_session_repo "$up"
    _commit_armed_queue "$up" .cs/private
    git clone -q "$up" "$CS_SESSIONS_ROOT/vt"
    _assert_refused_under_any_git_environment ".cs/private/queue.state is tracked in git" || return 1
}

# The gitlink for a .cs submodule stays in the index after its .git is gone,
# and the index is then the only place that says so.
test_a_cs_gitlink_is_refused_whatever_repository_the_shell_names() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    git -C "$root/.cs" init -q
    git -C "$root/.cs" add -f README.md
    git -C "$root/.cs" -c user.name=t -c user.email=t@example.com commit -q -m "inner"
    git -C "$root" rm -r -q --cached .cs
    # git warns that it is adding an embedded repository; the gitlink is
    # checked below instead of its stderr.
    git -C "$root" add .cs 2>/dev/null
    git -C "$root" commit -q -m "ship .cs as a submodule"
    rm -rf "$root/.cs/.git"
    assert_eq "160000" "$(git -C "$root" ls-files -s -- .cs | cut -d' ' -f1)" "the fixture must index .cs as a gitlink" || return 1
    _assert_refused_under_any_git_environment ".cs is a submodule or nested repository" || return 1
}

# A clone can commit .cs/local laid out like a git repository (git add -f),
# with a config whose core.fsmonitor runs on every ls-files. git asked about
# .cs/local would take it for the repository and run that command; the open
# refuses it by name instead, and git runs nothing from it.
test_a_git_repository_layout_at_cs_local_is_refused_whatever_repository_the_shell_names() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" g="$CS_SESSIONS_ROOT/vt/.cs/local"
    mkdir -p "$g/objects" "$g/refs"
    : > "$g/objects/.keep"
    : > "$g/refs/.keep"
    printf 'ref: refs/heads/main\n' > "$g/HEAD"
    printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = .\n\tfsmonitor = touch %s; false\n' \
        "$TEST_TMPDIR/fsmonitor-ran" > "$g/config"
    git -C "$root" add -f .cs/local/HEAD .cs/local/config .cs/local/objects .cs/local/refs
    git -C "$root" commit -q -m "ship a repository layout"
    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_file_not_exists "$TEST_TMPDIR/fsmonitor-ran" "git must not run the layout's core.fsmonitor" || return 1
    assert_eq "1" "$rc" "cs should refuse the open: $out" || return 1
    assert_eq "Error: .cs/local holds HEAD, so git takes it for a repository and would run commands its config names (cs state must be a plain directory inside the session). Delete .cs/local/HEAD, or cs -rm the session." \
        "$out" "the refusal names the layout" || return 1
    _assert_refused_under_any_git_environment ".cs/local holds HEAD" || return 1
    assert_file_not_exists "$TEST_TMPDIR/fsmonitor-ran" "git must not run the layout's core.fsmonitor under any git variable" || return 1
}

# A checkout cs hides itself in through info/exclude must track none of the
# files cs rewrites at every open.
test_an_exclude_session_conflict_is_refused_whatever_repository_the_shell_names() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    printf 'git_bookkeeping: exclude\n' >> "$root/.cs/local/state"
    git -C "$root" add -f CLAUDE.local.md
    git -C "$root" commit -q -m "track the protocol file"
    _assert_refused_under_any_git_environment "is tracked on the branch" || return 1
}

# Only a pre-open git does not track makes a vault the user set up by hand,
# which is what lets the vault links lead out of the session.
test_a_tracked_pre_open_makes_no_hand_made_vault_whatever_repository_the_shell_names() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" var rc
    _write_pre_open vt "exit 0"
    rc=0
    bash -c 'source "$1"; _cs_hand_made_vault "$2"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root" || rc=$?
    assert_eq "0" "$rc" "an untracked pre-open is a hand-made vault" || return 1
    git -C "$root" add -f .cs/local/pre-open
    git -C "$root" commit -q -m "track pre-open"
    for var in "GIT_CS_TEST_NONE=1" "GIT_INDEX_FILE=/dev/null" "GIT_DIR=$TEST_TMPDIR/nowhere/.git"; do
        rc=0
        env "$var" bash -c 'source "$1"; _cs_hand_made_vault "$2"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root" || rc=$?
        assert_eq "1" "$rc" "a tracked pre-open is no hand-made vault with ${var%%=*} set" || return 1
    done
}

# A clone can also deliver `.cs` itself as a committed symlink to a tracked
# directory: `git ls-files -- .cs/local` then lists nothing, so the tracked
# check passes and the pre-open behind the link would run.
test_pre_open_through_symlinked_cs_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    mv "$root/.cs" "$root/payload"
    ln -s payload "$root/.cs"
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship .cs as a link"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs is a symlink to payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "cs should refuse a symlinked .cs before running anything behind it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the pre-open behind the link must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A repository can also deliver .cs as a submodule: the superproject's index
# holds one gitlink entry for .cs, so a pathspec under it lists nothing,
# while a recursive clone puts the submodule's committed pre-open on disk.
test_pre_open_inside_a_cs_submodule_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$root/.cs" init -q
    git -C "$root/.cs" add -f local/pre-open
    git -C "$root/.cs" -c user.name=t -c user.email=t@example.com commit -q -m "hook"
    git -C "$root" rm -r -q --cached .cs
    git -C "$root" add .cs
    git -C "$root" commit -q -m "ship .cs as a submodule"
    assert_eq "160000" "$(git -C "$root" ls-files -s -- .cs | cut -d' ' -f1)" "the fixture must index .cs as a gitlink" || return 1
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs is a submodule or nested repository (cs state must be a plain directory inside the session). Delete .cs/local/pre-open unless you wrote it, then git rm --cached .cs, remove .cs/.git and git add .cs, then reopen." \
        "$out" "cs should refuse a submodule .cs before running anything inside it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the submodule's pre-open must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1

    # Removing the submodule's own .git leaves the gitlink in the session's
    # index, which still hides everything under .cs from the pathspec check.
    rm -rf "$root/.cs/.git"
    rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs should still exit 1 with the gitlink indexed" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the pre-open must not run after .cs/.git is removed" || return 1
}

# A submodule somewhere under .cs is the session's own business: only a
# gitlink AT .cs hides cs's state from the index.
test_submodule_inside_cs_is_not_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    mkdir -p "$root/.cs/00-reference"
    git -C "$root/.cs/00-reference" init -q
    touch "$root/.cs/00-reference/keep"
    git -C "$root/.cs/00-reference" add keep
    git -C "$root/.cs/00-reference" -c user.name=t -c user.email=t@example.com commit -q -m "ref"
    git -C "$root" add .cs/00-reference
    git -C "$root" commit -q -m "track a reference submodule under .cs"
    assert_eq "160000" "$(git -C "$root" ls-files -s -- .cs/00-reference | cut -d' ' -f1)" "the fixture must index the nested gitlink" || return 1
    _make_launch_sentinel

    local rc=0
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "a gitlink below .cs must not refuse the open" || return 1
    assert_eq "launched" "$(cat "$TEST_TMPDIR/launched" 2>/dev/null)" "claude should launch" || return 1
}

# Without a pre-open the open reaches migration, whose hardening chmods .cs
# and would follow a link to a directory cs does not own.
test_symlinked_cs_without_pre_open_keeps_the_target_mode() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    mv "$root/.cs" "$root/payload"
    rm -f "$root/payload/local/pre-open"
    chmod 755 "$root/payload"
    ln -s payload "$root/.cs"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs is a symlink to payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "cs should refuse the link before migration touches the target" || return 1
    assert_eq "755" "$(_file_mode "$root/payload")" "the link target's mode must be untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_pre_open_through_symlinked_cs_local_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt"
    mv "$root/.cs/local" "$root/payload"
    ln -s ../payload "$root/.cs/local"
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship .cs/local as a link"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local is a symlink to ../payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "cs should refuse a symlinked .cs/local before running anything behind it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the pre-open behind the link must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_pre_open_success_without_mount_still_refuses() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _write_pre_open vt "exit 0"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/memory points at $meta/vault-mnt/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "the dangling-link refusal should still fire" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A session whose Claude Code config lives on its encrypted volume: .cs/claude-config
# is a symlink into vault-mnt, the same shape as memory and plans.
# cs -encrypt writes the session's .cs/local/pre-open; without one the
# config dir is no vault's and its links out are refused.
_make_vaulted_config() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$meta/vault-mnt/claude-config"
    ln -s "$meta/vault-mnt/claude-config" "$meta/claude-config"
    _mark_hand_made_vault "$CS_SESSIONS_ROOT/$1"
}

# Records the Claude Code config variables each launch sees; "unset" when absent.
_make_config_sentinel() {
    cat > "$TEST_TMPDIR/claude" <<EOF
#!/bin/bash
echo "config=\${CLAUDE_CONFIG_DIR-unset} secure=\${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}" >> "$TEST_TMPDIR/launched"
EOF
    chmod +x "$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude"
}

test_claude_config_link_moves_claude_code_into_the_vault() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    local rc=0
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq "config=$CS_SESSIONS_ROOT/vt/.cs/claude-config secure=" "$(cat "$TEST_TMPDIR/launched")" \
        "claude should keep its config in the vault and its login in the default keychain entry" || return 1
}

# A cs launched from inside an encrypted session inherits that session's config
# variables; the session it opens has no vault, so it must get the shell's
# config, not the parent's vault: the dir the parent's launch kept in
# CLAUDE_SECURESTORAGE_CONFIG_DIR, or none for ~/.claude when that is empty,
# the variables a launch from the shell itself would see. A config dir the user
# set themselves is theirs, and a shell with none gets none.
test_session_without_claude_config_drops_an_inherited_vault_config() {
    "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    _make_config_sentinel

    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    CLAUDE_CONFIG_DIR="$TEST_TMPDIR/other/.cs/claude-config" CLAUDE_SECURESTORAGE_CONFIG_DIR="" \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    CLAUDE_CONFIG_DIR="$TEST_TMPDIR/other/.cs/claude-config" CLAUDE_SECURESTORAGE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true

    assert_eq "config=unset secure=unset
config=unset secure=unset
config=$TEST_TMPDIR/profile-b secure=unset
config=$TEST_TMPDIR/profile-b secure=unset" "$(cat "$TEST_TMPDIR/launched")" \
        "a shell with no config dir sets none; an inherited vault config gives way to the shell's recorded one; the user's own config dir is kept" || return 1
}

# Under a non-default profile the login lives in that profile's keychain entry.
test_claude_config_link_keeps_the_shell_profile_login() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq "config=$CS_SESSIONS_ROOT/vt/.cs/claude-config secure=$TEST_TMPDIR/profile-b" \
        "$(cat "$TEST_TMPDIR/launched")" "the keychain entry follows the shell's profile" || return 1
}

test_unmounted_claude_config_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    # memory and plans stay reachable, so the refusal can only come from claude-config.
    mkdir -p "$TEST_TMPDIR/elsewhere"
    mv "$meta/vault-mnt/memory" "$meta/vault-mnt/plans" "$TEST_TMPDIR/elsewhere/"
    rm "$meta/memory" "$meta/plans"
    ln -s "$TEST_TMPDIR/elsewhere/memory" "$meta/memory"
    ln -s "$TEST_TMPDIR/elsewhere/plans" "$meta/plans"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/claude-config points at $meta/vault-mnt/claude-config, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling config link" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch with its config unmounted" || return 1
}

# Opens vt, with its config in the vault, from a shell with no config variables.
_open_vaulted_config_session() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1
}

# The vault config shares the user's settings, instructions and extensions with
# ~/.claude, so an encrypted session runs with the same hooks, skills and plugins.
test_claude_config_links_the_shared_config() {
    mkdir -p "$HOME/.claude/skills/demo"
    printf '{"model":"base"}\n' > "$HOME/.claude/settings.json"

    local rc=0
    _open_vaulted_config_session || rc=$?

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq "$HOME/.claude/settings.json" "$(readlink "$config/settings.json")" \
        "settings.json should link to the shell's config" || return 1
    assert_eq "$HOME/.claude/skills" "$(readlink "$config/skills")" \
        "skills should link to the shell's config" || return 1
}

# Under a non-default profile the shared config is that profile's.
test_claude_config_links_the_shell_profile_config() {
    mkdir -p "$HOME/.claude" "$TEST_TMPDIR/profile-b"
    printf '{"model":"home"}\n' > "$HOME/.claude/settings.json"
    printf '{"model":"profile-b"}\n' > "$TEST_TMPDIR/profile-b/settings.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq "$TEST_TMPDIR/profile-b/settings.json" \
        "$(readlink "$CS_SESSIONS_ROOT/vt/.cs/claude-config/settings.json")" \
        "settings.json should link to the profile's config, not ~/.claude" || return 1
}

# A link to an entry the shell's config lacks would dangle.
test_claude_config_skips_what_the_shell_config_lacks() {
    mkdir -p "$HOME/.claude"
    printf '{}\n' > "$HOME/.claude/settings.json"

    _open_vaulted_config_session || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "settings.json" "$(ls -A "$config")" \
        "only the entry the shell's config has should be linked" || return 1
}

# The session may keep its own settings, or a link it made by hand; and a
# second launch finds its own links already there.
test_claude_config_keeps_its_own_entries() {
    mkdir -p "$HOME/.claude/skills"
    printf '{"model":"base"}\n' > "$HOME/.claude/settings.json"
    printf '{}\n' > "$HOME/.claude/keybindings.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    printf '{"model":"own"}\n' > "$config/settings.json"
    ln -s "$TEST_TMPDIR/gone" "$config/keybindings.json"
    _make_launch_sentinel

    local rc1=0 rc2=0
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc1=$?
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc2=$?

    assert_eq "0 0" "$rc1 $rc2" "both launches should open the session" || return 1
    assert_eq "launched
launched" "$(cat "$TEST_TMPDIR/launched")" "claude should launch twice" || return 1
    assert_eq '{"model":"own"}' "$(cat "$config/settings.json")" \
        "the session's own settings should be kept" || return 1
    assert_eq "$TEST_TMPDIR/gone" "$(readlink "$config/keybindings.json")" \
        "a link the session already has should be kept" || return 1
}

# What Claude Code writes about conversations is the leak the vault closes;
# linking it back to ~/.claude would reopen it.
test_claude_config_never_links_conversation_state() {
    mkdir -p "$HOME/.claude/projects" "$HOME/.claude/backups" "$HOME/.claude/todos"
    printf '{}\n' > "$HOME/.claude/history.jsonl"

    _open_vaulted_config_session || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "" "$(ls -A "$config")" \
        "no conversation state should be shared with the shell's config" || return 1
}

# The vault's .claude.json starts as a copy of the shell's, so onboarding and
# preferences carry over, minus every project's record: each one keeps that
# project's last prompt in plaintext.
test_claude_config_seeds_claude_json_without_projects() {
    printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{"/p":{"lastSessionFirstPrompt":"private words"}}}' \
        > "$HOME/.claude.json"

    local rc=0
    _open_vaulted_config_session || rc=$?

    local seeded="$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json"
    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq '{"hasCompletedOnboarding":true,"projects":{}}' "$(jq -c . "$seeded")" \
        "the copy should keep the settings and drop every project" || return 1
    assert_eq "$seeded" "$(find "$seeded" -perm 600)" "the copy should be readable by its owner only" || return 1
}

# Claude Code keeps .claude.json in $HOME by default, but inside the config dir
# when CLAUDE_CONFIG_DIR is set; the copy comes from wherever the shell's is.
test_claude_config_seeds_the_shell_profile_claude_json() {
    mkdir -p "$TEST_TMPDIR/profile-b"
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    printf '{"from":"profile-b"}\n' > "$TEST_TMPDIR/profile-b/.claude.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq '{"from":"profile-b","projects":{}}' \
        "$(jq -c . "$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json")" \
        "the copy should come from the profile's .claude.json" || return 1
}

# A cs launched from inside another encrypted session inherits that session's
# vault as CLAUDE_CONFIG_DIR; sharing from it would tie this vault to that one.
test_claude_config_shares_from_the_shell_config_not_an_inherited_vault() {
    local other="$TEST_TMPDIR/other/.cs/claude-config"
    mkdir -p "$other" "$HOME/.claude"
    printf '{"model":"other"}\n' > "$other/settings.json"
    printf '{"from":"other"}\n' > "$other/.claude.json"
    printf '{"model":"home"}\n' > "$HOME/.claude/settings.json"
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    CLAUDE_CONFIG_DIR="$other" CLAUDE_SECURESTORAGE_CONFIG_DIR="" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "$HOME/.claude/settings.json" "$(readlink "$config/settings.json")" \
        "settings.json should link to the shell's config" || return 1
    assert_eq '{"from":"home","projects":{}}' "$(jq -c . "$config/.claude.json")" \
        "the copy should come from the shell's .claude.json" || return 1
    assert_eq "config=$config secure=" "$(cat "$TEST_TMPDIR/launched")" \
        "claude should run on this vault and the default login" || return 1

    # Under a shell profile, the parent's launch kept that profile as the
    # shell's config dir: this vault shares from it and logs in through it.
    local profile="$TEST_TMPDIR/profile-b"
    mkdir -p "$profile"
    printf '{"model":"profile-b"}\n' > "$profile/settings.json"
    rm -f "$config/settings.json" "$TEST_TMPDIR/launched"
    CLAUDE_CONFIG_DIR="$other" CLAUDE_SECURESTORAGE_CONFIG_DIR="$profile" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    assert_eq "$profile/settings.json" "$(readlink "$config/settings.json")" \
        "settings.json should link to the shell profile's config" || return 1
    assert_eq "config=$config secure=$profile" "$(cat "$TEST_TMPDIR/launched")" \
        "claude should run on this vault and the shell profile's login" || return 1
}

# A session whose cs files (command log, mail, traces) live on its encrypted
# volume: .cs/private links into vault-mnt. The log cs wrote at creation is
# moved in, as a migration would.
_make_vaulted_private() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$meta/vault-mnt/private"
    mv "$meta/local/session.log" "$meta/vault-mnt/private/session.log"
    ln -s "$meta/vault-mnt/private" "$meta/private"
}

test_private_link_session_opens() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "0" "$rc" "cs should open the session: $out" || return 1
    assert_eq "launched" "$(cat "$TEST_TMPDIR/launched")" "claude should launch once" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/vt/.cs/local/session.log" \
        "the open must not write a plaintext log" || return 1
}

test_unmounted_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    # memory and plans stay reachable, so the refusal can only come from private.
    mkdir -p "$TEST_TMPDIR/elsewhere"
    mv "$meta/vault-mnt/memory" "$meta/vault-mnt/plans" "$TEST_TMPDIR/elsewhere/"
    rm "$meta/memory" "$meta/plans"
    ln -s "$TEST_TMPDIR/elsewhere/memory" "$meta/memory"
    ln -s "$TEST_TMPDIR/elsewhere/plans" "$meta/plans"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private points at $meta/vault-mnt/private, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling private link" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# Once a session keeps its cs files in the vault, a copy left in .cs/local is
# plaintext the vault was meant to hold; cs names it rather than open beside it.
test_plaintext_left_beside_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    printf 'old log\n' > "$meta/local/session.log"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds session.log in plaintext. Move it into .cs/private or delete it, then reopen." \
        "$out" "cs should name the plaintext file" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A mailbox is a directory, not a file: a plaintext one left in .cs/local is
# named the same way, whatever it holds.
test_plaintext_mailbox_left_beside_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mkdir -p "$meta/local/mail/cur"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds mail in plaintext. Move it into .cs/private or delete it, then reopen." \
        "$out" "cs should name the plaintext mailbox" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# The queue, its run mode, its inbox, the traces, the pending-handoff marker,
# the /finish progress record and the memory guard's two snapshots are cs
# files too: each one left in .cs/local is named the same way.
test_plaintext_queue_files_left_beside_private_refuse_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs" name out rc
    for name in queue queue.tmp queue.state queue.done queue.current queue.migrating \
                notifications.jsonl notifications.seen failures rewrite.trace pending-handoff \
                finish-progress.json queue.mode memory-index.snapshot memory-archive.snapshot; do
        case "$name" in queue|queue.tmp) mkdir -p "$meta/local/$name" ;; *) printf 'x\n' > "$meta/local/$name" ;; esac
        rc=0
        out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
        assert_eq "1" "$rc" "cs should exit 1 on $name" || return 1
        assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds $name in plaintext. Move it into .cs/private or delete it, then reopen." \
            "$out" "cs should name $name" || return 1
        rm -rf "${meta:?}/local/$name"
    done
}

# A regular file where a vault link belongs is neither a vault nor a place
# cs can write; the open names it rather than treat the session as locked.
test_a_file_at_a_vault_link_refuses_open() {
    _make_vaulted_session vt
    _make_launch_sentinel
    local meta="$CS_SESSIONS_ROOT/vt/.cs" out rc=0
    printf 'not a vault\n' > "$meta/private"
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private is a file, not a directory or a link into encrypted storage. Remove it, or link it into the vault, then reopen." \
        "$out" "cs should name the file" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

# Checkpoints and a vault narrative's rotated sections belong behind the
# vault too; copies made before the session was encrypted are named. A
# .cs/narrative-archive that is itself a link into the vault is fine.
test_plaintext_checkpoints_and_archive_beside_private_refuse_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs" out rc=0
    mkdir -p "$meta/checkpoints"
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs should exit 1 on checkpoints" || return 1
    assert_eq "Error: vt: .cs/private keeps this session's checkpoints in its vault, but .cs/checkpoints is still plaintext. Move it to .cs/private/checkpoints or delete it, then reopen." \
        "$out" "cs should name .cs/checkpoints" || return 1
    rm -rf "$meta/checkpoints"
    mkdir -p "$meta/narrative-archive/alice"
    rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs should exit 1 on narrative-archive" || return 1
    assert_eq "Error: vt: this session's narrative lives in its vault, but .cs/narrative-archive is still plaintext. Move it to .cs/private/narrative-archive or delete it, then reopen." \
        "$out" "cs should name .cs/narrative-archive" || return 1
    rm -rf "$meta/narrative-archive"
    mkdir -p "$meta/vault-mnt/narrative-archive"
    ln -s "$meta/vault-mnt/narrative-archive" "$meta/narrative-archive"
    rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_output_not_contains "$out" "narrative-archive is still plaintext" "a link into the vault is not a leftover" || return 1
}

# After the first launch the session's .claude.json is Claude Code's to write.
test_claude_config_seeds_claude_json_once() {
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    _open_vaulted_config_session || true
    local seeded="$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json"
    printf '{"from":"session"}\n' > "$seeded"

    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq '{"from":"session"}' "$(jq -c . "$seeded")" \
        "a second launch should keep the session's own .claude.json" || return 1
}

# Without a readable copy Claude Code would start the session as a fresh
# install; an empty file is the case jq alone lets through.
test_claude_config_refuses_an_unreadable_claude_json() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel
    local content out rc
    for content in '{"projects": {,}' ''; do
        printf '%s' "$content" > "$HOME/.claude.json"

        rc=0
        out=$(env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" 2>&1) || rc=$?

        assert_eq "1" "$rc" "cs should exit 1 for '$content'" || return 1
        # The line before it is the stale-lock notice the fixture's own
        # creating launch leaves behind.
        assert_eq "Error: $HOME/.claude.json is not a JSON object cs can copy into $CS_SESSIONS_ROOT/vt/.cs/claude-config; fix it, then reopen." \
            "$(tail -n 1 <<< "$out")" "cs should name the source it cannot copy" || return 1
        assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
        assert_eq "" "$(ls -A "$CS_SESSIONS_ROOT/vt/.cs/claude-config")" \
            "nothing should be left in the session's config" || return 1
    done
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs auto-memory tests"
echo "===================="
echo ""

# cs rewrites settings.local.json through a temp file. The temp name must be
# unique, so a user's own <file>.tmp sibling is never clobbered, and the
# rewritten file must keep the mode the user gave it.
test_settings_merge_leaves_a_tmp_sibling_alone_and_keeps_the_mode() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local settings="$CS_SESSIONS_ROOT/test-session/.claude/settings.local.json"
    assert_exists "$settings" "settings.local.json should exist" || return 1
    printf 'USER-OWNED\n' > "$settings.tmp"
    chmod 750 "$settings"
    # Phase 4 re-runs the merge only when memory, plans or settings is missing.
    rm -rf "$CS_SESSIONS_ROOT/test-session/.cs/plans"

    "$CS_BIN" test-session <<< "" 2>&1 || true

    assert_eq "USER-OWNED" "$(cat "$settings.tmp")" "the user's .tmp sibling is untouched" || return 1
    assert_eq "750" "$(_file_mode "$settings")" "the rewritten file keeps its mode" || return 1
    assert_file_contains "$settings" "autoMemoryDirectory" "the merge still happened" || return 1
}

# A clone delivers every file under .cs, symlinks included, and cs rewrites
# some of them on the first open (the README's frontmatter). A committed
# `.cs/README.md -> ../../outside` would have that write land on a file the
# session does not own. A fresh clone has no .cs/local, so no migration stamp.
test_a_committed_link_out_of_the_session_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" outside="$TEST_TMPDIR/outside-rc"
    printf 'export USER_OWNED=1\n' > "$outside"
    rm -f "$root/.cs/README.md"
    ln -s "$outside" "$root/.cs/README.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship the README as a link"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/README.md is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "export USER_OWNED=1" "$(cat "$outside")" "the file outside the session must be untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# `cs <name> -queue` writes into a session without opening it, so the open's
# scan never runs on that path. A committed .cs/private leading out of the
# session must stop it before the queue file lands in a directory the session
# does not own.
test_a_named_queue_add_refuses_a_link_out_of_the_session() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" outside="$TEST_TMPDIR/outside-private"
    mkdir -p "$outside"
    ln -s "$outside" "$root/.cs/private"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship private as a link"

    local out rc=0
    out=$(env -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR \
        "$CS_BIN" vt -queue add "probe" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "" "$(ls -A "$outside")" "nothing may be written into the directory outside the session" || return 1
}

# The link can sit on a directory above the file cs writes: with .cs/memory
# a link out of the session, every write into the memory directory lands in
# a directory the session does not own.
test_a_committed_directory_link_out_of_the_session_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" outside="$TEST_TMPDIR/outside-dir"
    mkdir -p "$outside"
    printf 'USER-OWNED\n' > "$outside/keep"
    rm -rf "$root/.cs/memory"
    ln -s "$outside" "$root/.cs/memory"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship the memory directory as a link"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/memory is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "keep" "$(ls -A "$outside")" "nothing may be written into the directory outside the session" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A root-level file cs rewrites at open, CLAUDE.local.md, is the same hazard.
test_a_committed_claude_local_link_out_of_the_session_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" outside="$TEST_TMPDIR/outside-local"
    printf 'USER-OWNED\n' > "$outside"
    rm -f "$root/CLAUDE.local.md"
    ln -s "$outside" "$root/CLAUDE.local.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship CLAUDE.local.md as a link"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: CLAUDE.local.md is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside the session must be untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# Codex r1 #2: a link to a directory inside the session is fine, but the scan
# must look inside that directory too: payload/MEMORY.md -> outside would take
# the narrative index line cs appends at open.
# Codex r2 #2: a directory whose name holds a newline would split the scan's
# list of directories to walk, so neither half is scanned and a link out
# behind it is missed. The scan refuses such a directory rather than walk it.
test_a_link_to_a_directory_named_with_a_newline_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" t outside out rc=0 nl=$'pay\nload'
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-mem"
    printf 'USER-OWNED\n' > "$outside"
    mv "$root/.cs/memory" "$root/$nl"
    ln -s "../$nl" "$root/.cs/memory"
    rm -f "$root/$nl/MEMORY.md"
    ln -s "$outside" "$root/$nl/MEMORY.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m "alias memory through a newline"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/memory leads to a directory with a newline in its name, which cs cannot check for links out of the session. Rename it, or cs -rm the session." \
        "$out" "cs should name the link it cannot vet" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A clone chooses a committed link's name and the text it points at, and
# either can carry a terminal escape: a raw ESC or BEL byte, or backslash text
# echo -e would turn into one. The open's refusals print both as plain names,
# each character a plain path lacks replaced by _.
_ESCAPING_NAME=$'e\033[1mb\007\\e[0m'
_ESCAPING_NAME_SHOWN=e__1mb__e_0m

test_a_link_out_of_the_session_is_named_as_a_plain_path() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" bad="$_ESCAPING_NAME" shown="$_ESCAPING_NAME_SHOWN" out rc=0
    mkdir -p "$TEST_TMPDIR/out$bad"
    ln -s "../../../out$bad" "$root/.cs/link$bad"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship a link out with an escape in its name"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/link$shown is a symlink to ../../../out$shown, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "the link and its target are named as plain paths" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_a_link_to_a_directory_named_with_a_newline_is_named_as_a_plain_path() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" bad="$_ESCAPING_NAME" shown="$_ESCAPING_NAME_SHOWN" out rc=0 nl=$'pay\nload'
    mkdir -p "$root/$nl"
    ln -s "../$nl" "$root/.cs/link$bad"
    git -C "$root" add -A
    git -C "$root" commit -q -m "alias a directory through a newline"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/link$shown leads to a directory with a newline in its name, which cs cannot check for links out of the session. Rename it, or cs -rm the session." \
        "$out" "the link is named as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_a_symlinked_cs_local_is_named_by_a_plain_target() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" bad="$_ESCAPING_NAME" shown="$_ESCAPING_NAME_SHOWN" out rc=0
    mv "$root/.cs/local" "$root/pay$bad"
    ln -s "../pay$bad" "$root/.cs/local"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship .cs/local as a link"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local is a symlink to ../pay$shown (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "the link's target is named as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_an_unmounted_vault_link_is_named_by_a_plain_target() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local meta="$CS_SESSIONS_ROOT/vt/.cs" bad="$_ESCAPING_NAME" shown="$_ESCAPING_NAME_SHOWN" out rc=0
    rm -rf "$meta/memory"
    ln -s "vault$bad/memory" "$meta/memory"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/memory points at vault$shown/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "the dangling link's target is named as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A clone can commit cs's encrypted layout: .cs/claude-config linked to a real
# .cs/vault-mnt/claude-config holding a link out. With no pre-open there is no
# vault, so the open walks that directory like any other.
test_a_committed_vault_config_lookalike_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" t outside out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-settings"
    printf 'USER-OWNED\n' > "$outside"
    mkdir -p "$root/.cs/vault-mnt/claude-config"
    ln -s vault-mnt/claude-config "$root/.cs/claude-config"
    ln -s "$outside" "$root/.cs/vault-mnt/claude-config/settings.json"
    git -C "$root" add -f .cs/claude-config .cs/vault-mnt/claude-config/settings.json
    git -C "$root" commit -q -m "a vault config lookalike"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/vault-mnt/claude-config/settings.json is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link out" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A vault set up by hand needs git's answer before its links out are let
# through. When git cannot answer, the open refuses with git's own error, not
# with advice to replace the vault's links or remove the session.
test_a_hand_made_vault_refuses_open_with_gits_error_when_git_cannot_answer() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local meta="$CS_SESSIONS_ROOT/vt/.cs" t outside cfg="$TEST_TMPDIR/broken-gitconfig" out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-settings"
    printf 'USER-OWNED\n' > "$outside"
    _make_vaulted_config vt
    ln -s "$outside" "$meta/vault-mnt/claude-config/settings.json"
    printf '[core\nbad\n' > "$cfg"
    _make_launch_sentinel

    out=$(GIT_CONFIG_GLOBAL="$cfg" "$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: cs could not ask git whether it tracks a file in .cs/local: fatal: bad config line 1 in file $cfg" \
        "$out" "cs should name git's error" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A hook's write through a vault link refuses while git cannot answer whether
# the vault was set up by hand, and says that, in git's words, rather than that
# the link leads out of the session.
test_a_write_through_a_hand_made_vault_link_names_gits_error_when_git_cannot_answer() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" meta="$CS_SESSIONS_ROOT/vt/.cs" t outside cfg="$TEST_TMPDIR/broken-gitconfig" out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-settings"
    printf 'USER-OWNED\n' > "$outside"
    _make_vaulted_config vt
    ln -s "$outside" "$meta/vault-mnt/claude-config/settings.json"
    printf '[core\nbad\n' > "$cfg"
    out=$(cd "$root" && GIT_CONFIG_GLOBAL="$cfg" bash -c 'source "$1"; cs_write_atomic "$2" printf "{}\n"' \
        _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$meta/claude-config/settings.json" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write refuses" || return 1
    assert_eq "cs_write_atomic: $meta/claude-config/settings.json not written: cs could not ask git whether it tracks a file in .cs/local: fatal: bad config line 1 in file $cfg" \
        "$out" "and names git's error" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    rc=0
    ln -s "$outside" "$meta/vault-mnt/claude-config/n"$'\e[1mb\a'".json"
    out=$(cd "$root" && GIT_CONFIG_GLOBAL="$cfg" bash -c 'source "$1"; cs_write_atomic "$2" printf "{}\n"' \
        _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$meta/claude-config/n"$'\e[1mb\a'".json" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a write to a name a clone could choose refuses the same way" || return 1
    assert_eq "cs_write_atomic: $meta/claude-config/n__1mb_.json not written: cs could not ask git whether it tracks a file in .cs/local: fatal: bad config line 1 in file $cfg" \
        "$out" "and prints the name below the session as a plain name" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    rc=0
    out=$(cd "$root" && bash -c 'source "$1"; cs_write_atomic "$2" printf "{}\n"' \
        _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$meta/claude-config/settings.json" 2>&1) || rc=$?
    assert_eq "0" "$rc" "once git answers, the vault's write goes through: $out" || return 1
}

# The same for cs -narrative rotate, whose narrative sits behind the vault's
# .cs/memory link.
test_narrative_rotate_through_a_hand_made_vault_names_gits_error_when_git_cannot_answer() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" meta="$CS_SESSIONS_ROOT/vt/.cs" cfg="$TEST_TMPDIR/broken-gitconfig" out rc=0 i
    mkdir -p "$TEST_TMPDIR/vault/memory" "$TEST_TMPDIR/vault/narrative-archive"
    rm -rf "$meta/memory"
    ln -s "$TEST_TMPDIR/vault/memory" "$meta/memory"
    ln -s "$TEST_TMPDIR/vault/narrative-archive" "$meta/narrative-archive"
    _mark_hand_made_vault "$root"
    { printf '# Session narrative (alice)\n\n'
      for i in 1 2 3; do printf '## 2026-01-0%s\n' "$i"; head -c 3000 /dev/zero | tr '\0' x; printf '\n\n'; done
    } > "$TEST_TMPDIR/vault/memory/narrative.alice.md"
    printf '[core\nbad\n' > "$cfg"
    out=$(GIT_CONFIG_GLOBAL="$cfg" CLAUDE_SESSION_DIR="$root" CLAUDE_SESSION_META_DIR="$meta" CS_ACTOR=alice \
        CS_NARRATIVE_MAX_BYTES=4096 CS_NARRATIVE_KEEP_BYTES=2048 "$CS_BIN" -narrative rotate 2>&1) || rc=$?
    assert_eq "1" "$rc" "the rotation refuses" || return 1
    assert_eq "Error: cs could not ask git whether it tracks a file in .cs/local: fatal: bad config line 1 in file $cfg" \
        "$out" "and names git's error" || return 1
}

# Codex r3 #1: a trailing newline is stripped by command substitution, so the
# physical path came back as a sibling without it and the scan walked nothing.
test_a_link_to_a_directory_named_with_a_trailing_newline_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" t outside out rc=0 nl=$'payload\n'
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-mem"
    printf 'USER-OWNED\n' > "$outside"
    mv "$root/.cs/memory" "$root/$nl"
    ln -s "../$nl" "$root/.cs/memory"
    rm -f "$root/$nl/MEMORY.md"
    ln -s "$outside" "$root/$nl/MEMORY.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m "alias memory through a trailing newline"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/memory leads to a directory with a newline in its name, which cs cannot check for links out of the session. Rename it, or cs -rm the session." \
        "$out" "cs should name the link it cannot vet" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
}

# Codex r3 #2: mail is sent to a target session without opening it, from
# inside a session or from outside any; the target is vetted either way.
test_global_msg_refuses_a_target_linked_out_of_the_session() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" outside="$TEST_TMPDIR/outside-mail"
    mkdir -p "$outside"
    ln -s "$outside" "$root/.cs/private"
    git -C "$root" add -A
    git -C "$root" commit -q -m "ship private as a link"

    local out rc=0
    out=$(env -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR \
        "$CS_BIN" -msg vt "probe" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the link it refuses" || return 1
    assert_eq "" "$(ls -A "$outside")" "nothing may be written into the directory outside the session" || return 1
}

test_a_link_out_behind_an_in_session_directory_link_refuses_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    local root="$CS_SESSIONS_ROOT/vt" t outside out rc=0
    t=$(cd "$TEST_TMPDIR" && pwd -P); outside="$t/outside-mem"
    printf 'USER-OWNED\n' > "$outside"
    mv "$root/.cs/memory" "$root/payload"
    ln -s ../payload "$root/.cs/memory"
    rm -f "$root/payload/MEMORY.md"
    ln -s "$outside" "$root/payload/MEMORY.md"
    git -C "$root" add -A
    git -C "$root" commit -q -m "alias memory"
    rm -f "$root/.cs/local/migrated"
    _make_launch_sentinel

    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: payload/MEMORY.md is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$out" "cs should name the hidden link" || return 1
    assert_eq "USER-OWNED" "$(cat "$outside")" "the file outside is untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

run_test test_new_session_creates_memory_dir
run_test test_new_session_creates_settings_local
run_test test_unparseable_settings_local_survives_merge
run_test test_settings_merge_leaves_a_tmp_sibling_alone_and_keeps_the_mode
run_test test_settings_local_is_gitignored
run_test test_adopt_creates_memory_dir
run_test test_adopt_adds_settings_to_gitignore
run_test test_migration_creates_memory_and_settings
run_test test_migration_moves_existing_auto_memory
run_test test_migration_keeps_colliding_memory_and_subdirs
run_test test_migration_keeps_a_source_the_destination_links_to
run_test test_migration_keeps_a_source_the_destination_root_links_to
run_test test_migration_failed_copy_deletes_nothing
run_test test_open_leaves_a_project_with_only_a_logs_dir_unmigrated
run_test test_open_migrates_a_flat_layout_session
run_test test_flat_layout_readme_linked_out_of_the_session_refuses_open

# Frontmatter migration
run_test test_migration_adds_frontmatter_to_old_readme
run_test test_migration_preserves_existing_content
run_test test_migration_derives_created_date
run_test test_migration_dates_an_untracked_readme_by_mtime_with_gnu_stat_first_on_a_mac
run_test test_migration_adds_aliases_from_session_name
run_test test_migration_skips_if_frontmatter_exists

# Session narrative topic file
run_test test_new_session_creates_narrative_file
run_test test_new_session_adds_narrative_pointer
run_test test_narrative_pointer_idempotent_readd
run_test test_resume_folds_discoveries_into_narrative
run_test test_discoveries_fold_header_uses_git_date
run_test test_resume_folds_compact_when_discoveries_header_only

# Encrypted storage
run_test test_unmounted_storage_refuses_open
run_test test_pre_open_mounts_then_session_opens
run_test test_pre_open_failure_aborts_open
run_test test_pre_open_not_executable_is_refused
run_test test_pre_open_tracked_by_git_is_refused
run_test test_pre_open_tracked_beside_planted_git_directory_files_is_refused
run_test test_pre_open_tracked_under_a_case_variant_is_refused
run_test test_cs_files_tracked_in_cs_private_are_refused
run_test test_cs_files_tracked_behind_a_cs_private_link_are_refused
run_test test_the_untrack_command_quotes_a_directory_name_the_repository_chose
run_test test_the_untrack_command_untracks_only_the_directory_it_names
run_test test_tracked_files_in_a_directory_named_with_a_trailing_newline_are_seen
run_test test_tracked_files_in_a_repository_named_with_a_trailing_newline_are_seen
run_test test_a_failed_answer_in_the_newline_fallback_names_that_calls_error
run_test test_a_cs_private_link_to_the_session_itself_is_refused_without_an_untrack_command
run_test test_the_untrack_command_names_a_directory_called_tilde_as_a_path
run_test test_the_untrack_command_names_a_directory_called_equals_as_a_path
run_test test_the_refusal_cuts_a_long_tracked_name_and_keeps_the_command_whole
run_test test_an_untracked_cs_private_directory_opens
run_test test_a_cs_private_link_into_a_vault_outside_any_repository_opens
run_test test_an_inherited_tracked_files_answer_does_not_stop_the_open
run_test test_a_tracked_pre_open_is_refused_whatever_repository_the_shell_names
run_test test_tracked_cs_private_is_refused_whatever_repository_the_shell_names
run_test test_a_cs_gitlink_is_refused_whatever_repository_the_shell_names
run_test test_a_git_repository_layout_at_cs_local_is_refused_whatever_repository_the_shell_names
run_test test_an_exclude_session_conflict_is_refused_whatever_repository_the_shell_names
run_test test_a_tracked_pre_open_makes_no_hand_made_vault_whatever_repository_the_shell_names
run_test test_pre_open_through_symlinked_cs_is_refused
run_test test_symlinked_cs_without_pre_open_keeps_the_target_mode
run_test test_pre_open_inside_a_cs_submodule_is_refused
run_test test_submodule_inside_cs_is_not_refused
run_test test_pre_open_through_symlinked_cs_local_is_refused
run_test test_pre_open_success_without_mount_still_refuses
run_test test_claude_config_link_moves_claude_code_into_the_vault
run_test test_unmounted_claude_config_refuses_open
run_test test_session_without_claude_config_drops_an_inherited_vault_config
run_test test_claude_config_link_keeps_the_shell_profile_login
run_test test_claude_config_links_the_shared_config
run_test test_claude_config_links_the_shell_profile_config
run_test test_claude_config_skips_what_the_shell_config_lacks
run_test test_claude_config_keeps_its_own_entries
run_test test_claude_config_never_links_conversation_state
run_test test_claude_config_seeds_claude_json_without_projects
run_test test_claude_config_seeds_the_shell_profile_claude_json
run_test test_claude_config_shares_from_the_shell_config_not_an_inherited_vault
run_test test_claude_config_seeds_claude_json_once
run_test test_claude_config_refuses_an_unreadable_claude_json
run_test test_private_link_session_opens
run_test test_unmounted_private_refuses_open
run_test test_plaintext_left_beside_private_refuses_open
run_test test_plaintext_mailbox_left_beside_private_refuses_open
run_test test_plaintext_queue_files_left_beside_private_refuse_open
run_test test_a_file_at_a_vault_link_refuses_open
run_test test_plaintext_checkpoints_and_archive_beside_private_refuse_open

run_test test_a_committed_link_out_of_the_session_refuses_open
run_test test_a_committed_directory_link_out_of_the_session_refuses_open
run_test test_a_named_queue_add_refuses_a_link_out_of_the_session
run_test test_a_committed_claude_local_link_out_of_the_session_refuses_open
run_test test_a_link_out_behind_an_in_session_directory_link_refuses_open
run_test test_a_link_to_a_directory_named_with_a_newline_refuses_open
run_test test_a_link_to_a_directory_named_with_a_trailing_newline_refuses_open
run_test test_a_link_out_of_the_session_is_named_as_a_plain_path
run_test test_a_link_to_a_directory_named_with_a_newline_is_named_as_a_plain_path
run_test test_a_symlinked_cs_local_is_named_by_a_plain_target
run_test test_an_unmounted_vault_link_is_named_by_a_plain_target
run_test test_a_committed_vault_config_lookalike_refuses_open
run_test test_a_hand_made_vault_refuses_open_with_gits_error_when_git_cannot_answer
run_test test_a_write_through_a_hand_made_vault_link_names_gits_error_when_git_cannot_answer
run_test test_narrative_rotate_through_a_hand_made_vault_names_gits_error_when_git_cannot_answer
run_test test_global_msg_refuses_a_target_linked_out_of_the_session

report_results
