#!/usr/bin/env bash
# ABOUTME: Tests for worktree-backed parallel task sessions
# ABOUTME: Covers name parsing, creation, launch env, merge-back, removal, doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"


# --- Name parsing (via cs CLI behavior) ---

test_worktree_name_rejected_without_base() {
    local output
    output=$("$CS_BIN" "@fix-auth" 2>&1 || true)
    assert_output_contains "$output" "Session name" "empty base half must be rejected" || return 1
}

test_worktree_name_rejects_bad_task_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@fix/auth" 2>&1 || true)
    assert_output_contains "$output" "feature name" "slash in feature half must be rejected" || return 1
}

# Both halves refuse a leading dot: the base half is a session name, and the
# feature half becomes the branch cs/<feature>, a ref git refuses.
test_worktree_name_rejects_a_leading_dot_in_either_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@.hidden" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name cannot start with a dot" "a leading dot in the feature half is refused" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@.hidden" "no worktree is created for it" || return 1
    output=$("$CS_BIN" ".myproj@fix" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "Session name cannot start with a dot" "a leading dot in the base half is refused" || return 1
}

test_plain_names_still_work() {
    local output
    output=$("$CS_BIN" "-list" 2>&1)
    assert_output_not_contains "$output" "Unknown" "plain subcommands unaffected" || return 1
}

# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Land the feature tip into the base through the integrate entry with a
# trivial gate, the way /finish does before it retires; prints the sha.
land_feature() {  # base task
    local wt="$CS_SESSIONS_ROOT/$1@$2" sha
    sha=$(git -C "$wt" rev-parse HEAD) || return 1
    "$CS_BIN" "$1" -integrate-feature "$2" "$sha" -- true >/dev/null 2>&1 || return 1
    printf '%s\n' "$sha"
}

# Field positions in a -features --porcelain record.
_feat_field() {  # line field_number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# Build a ps seam for the ownership walk. Process inspection may be restricted
# in a test sandbox; production uses BSD ps, while these integration tests
# inject the one parent edge relevant to the scenario.
fixed_parent_ps_stub() {
    local parent="$1" stub="$TEST_TMPDIR/parent-ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
printf '%s\n' "$parent"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    assert_dir "$wt" "worktree dir should exist" || return 1
    assert_file_exists "$wt/.git" "linked worktree .git should be a file" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$wt" branch --show-current)" "worktree on task branch" || return 1
    assert_file_exists "$wt/.cs/README.md" "tracked .cs rides the checkout" || return 1
    assert_file_contains "$wt/.cs/local/state" "task_branch: cs/fix-auth" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_base: myproj" || return 1
    # Fresh identity, not the base's
    local base_uuid wt_uuid
    base_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$base_dir/.cs/local/state")
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$wt/.cs/local/state")
    [ "$base_uuid" != "$wt_uuid" ] || { echo "  FAIL: worktree must get its own UUID"; return 1; }
}

# A worktree of an encrypted session carries the same vault links; opening it
# while the vault is locked refuses by name, as the base does, before
# anything writes through the dangling links.
test_worktree_open_refuses_a_locked_vault() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" out rc=0
    rm -rf "$wt/.cs/memory"
    ln -s "$TEST_TMPDIR/unmounted/memory" "$wt/.cs/memory"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open refuses" || return 1
    assert_eq "Error: myproj@fix-auth: .cs/memory points at $TEST_TMPDIR/unmounted/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "names the dangling link" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

# Creating a worktree checks out the base's committed vault links; with the
# vault locked they dangle, and setup would mkdir through them halfway
# through registering the worktree. Refuse before git sees anything, and
# refuse the encrypted base outright, since mounting it would only lead there.
test_worktree_create_refuses_a_locked_base_vault() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    rm -rf "$base_dir/.cs/memory"
    ln -s "$TEST_TMPDIR/unmounted/memory" "$base_dir/.cs/memory"
    git -C "$base_dir" add -A .cs/memory
    git -C "$base_dir" -c user.email=t@example.com -c user.name=t commit -qm "vault link"
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "refuses the encrypted base instead of asking to mount it" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "no task branch on refusal" || return 1
}

# cs -encrypt links the four names relative to .cs/ ("vault-mnt/<name>"), so a
# checkout of them resolves inside the worktree, where nothing is mounted; and
# a base whose .cs/ is ignored gives the worktree plaintext files of its own.
# Until worktrees of an encrypted session are designed, both refuse by name.
_encrypt_base_links() {  # base_dir; links shaped as cs -encrypt writes them, vault mounted
    local base="$1" sub
    rm -rf "$base/.cs/memory"
    for sub in memory plans claude-config private; do
        mkdir -p "$base/.cs/vault-mnt/$sub"
        ln -s "vault-mnt/$sub" "$base/.cs/$sub"
    done
    echo sealed > "$base/.cs/vault-mnt/memory/narrative.md"
}

test_worktree_create_refuses_an_encrypted_base() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    _encrypt_base_links "$base_dir"
    git -C "$base_dir" add -A .cs
    git -C "$base_dir" -c user.email=t@example.com -c user.name=t commit -qm "vault links"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "no task branch on refusal" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

test_worktree_create_refuses_an_encrypted_base_with_untracked_links() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    _encrypt_base_links "$base_dir"
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the create refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

test_worktree_open_refuses_once_its_base_is_encrypted() {
    local base_dir out rc=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    _encrypt_base_links "$base_dir"
    _make_launch_sentinel
    out=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open refuses" || return 1
    assert_eq "Error: myproj: .cs/memory links into encrypted storage, and feature worktrees of an encrypted session are not supported yet." \
        "$out" "names the base's vault link" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

test_worktree_create_refuses_dirty_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "change" >> "$base_dir/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty base must refuse" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

# An existing branch is reused from its own tip, which may sit behind the
# base: the launch says so, naming the branch and how far behind it is.
test_worktree_create_reuses_existing_branch() {
    local base_dir output
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" branch cs/fix-auth
    echo "later" >> "$base_dir/CLAUDE.md"
    git -C "$base_dir" commit -q -am "later work"
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1 || true)
    assert_eq "cs/fix-auth" "$(git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" branch --show-current)" \
        "existing branch is reused, not errored on" || return 1
    assert_output_contains "$output" "Branch cs/fix-auth already exists; the feature starts from its tip, 1 commit behind myproj" \
        "the launch names the reused branch and its distance" || return 1
}

# A detached base has no branch for the feature to land on at /finish:
# creation refuses before any worktree exists, so the user hears it first.
test_worktree_create_refuses_a_detached_base() {
    local base_dir output rc=0
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" checkout -q --detach
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "a detached base refuses" || return 1
    assert_eq "Error: Session 'myproj' is detached (no branch checked out), so a feature would have no branch to land on. Check out the branch the feature should land on, then try again." \
        "$(printf '%s\n' "$output" | tail -n 1)" "names the state and the fix" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
    git -C "$base_dir" rev-parse -q --verify refs/heads/cs/fix-auth >/dev/null 2>&1 \
        && { echo "  FAIL: no branch created on refusal"; return 1; }
    return 0
}

test_worktree_create_ignored_mode_bootstraps_cs() {
    # A repo whose .gitignore excludes .cs/ entirely (like the cs dev repo)
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_dir "$wt/.cs/memory" "ignored mode bootstraps .cs skeleton" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "# Project CLAUDE.md" "$(cat "$wt/CLAUDE.md")" \
        "bootstrap must not overwrite the project's CLAUDE.md" || return 1
}

test_ignored_mode_worktree_starts_with_nothing_untracked() {
    # Ignored mode only means .cs is not TRACKED — it does not mean the project
    # ignores it. A project that never gitignored .cs/ gets a worktree whose .cs
    # skeleton cs itself just wrote, untracked, which the merge preflight then
    # refuses. cs must not manufacture its own merge blocker.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    # No .gitignore entry for .cs/ — this is the freya shape.
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    assert_eq "" "$others" "a fresh ignored-mode worktree must have nothing untracked" || return 1
}

test_ignored_mode_worktree_retires_without_a_manual_exclude() {
    # The end the user actually hits: create, commit work, /finish lands it,
    # then retires the worktree.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "that removal would destroy" \
        "cs must not refuse over the .cs skeleton it wrote itself" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_tolerates_a_worktree_predating_the_cs_exclude() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked, and upgrading cs must unblock it without the user editing
    # info/exclude by hand. Model that by stripping the entry after creation.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so this test exercises the preflight rather than the exclude.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    echo "feature" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "task work")
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_output_not_contains "$output" "that removal would destroy" \
        "an older worktree's .cs skeleton must not block retirement" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

test_retire_still_refuses_real_untracked_work() {
    # The carve-out is scoped to cs's own bookkeeping. A file the user would
    # lose must still stop the removal — that is what the gate is for.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md CLAUDE.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local sha output
    sha=$(land_feature proj task1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1 || true)
    assert_eq "Error: Worktree has 1 untracked file that removal would destroy; commit or remove it first:
    notes.txt" "$output" "real untracked work must still refuse, naming the file at risk" || return 1
    assert_dir "$wt" "the worktree survives a refusal" || return 1
}

# A landed feature proj@task1 whose base tracks apps/web/src/app.ts and
# ignores what $1 lists, one pattern per line. Prints the landed sha.
_landed_feature_ignoring() {  # gitignore-lines
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local} "$base_dir/apps/web/src"
    echo "# Project readme" > "$base_dir/README.md"
    echo 'export {}' > "$base_dir/apps/web/src/app.ts"
    printf '%s\n' "$1" > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md .gitignore apps && git commit -q -m init)
    cs_launch "proj@task1"
    land_feature proj task1
}

# git keeps no copy of an ignored file, so retire never deletes one it
# cannot regenerate: it moves it to the system trash and says so, then
# removes the worktree. cs's own ignored bookkeeping and Finder's .DS_Store
# go with the worktree.
test_retire_moves_ignored_work_to_the_system_trash() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0
    sha=$(_landed_feature_ignoring '*.log
.DS_Store
.env
__screenshots__/') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    echo "unsaved" > "$wt/build.log"
    : > "$wt/.DS_Store"
    echo "KEY=value" > "$wt/apps/web/.env"
    mkdir -p "$wt/apps/web/src/__screenshots__"
    touch "$wt/apps/web/src/__screenshots__/a.png" "$wt/apps/web/src/__screenshots__/b.png"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 4 ignored files to the system trash:
    $wt/apps/web/src/__screenshots__/  (2 files)
    $wt/apps/web/.env
    $wt/build.log
retired task1 $sha" "$output" "retire names where each file it moved to the trash came from" || return 1
    assert_eq "$wt/apps/web/src/__screenshots__
$wt/apps/web/.env
$wt/build.log" "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets each entry once, by its full path" || return 1
    assert_eq "KEY=value" "$(cat "$TEST_TMPDIR/trash-bin/2-.env")" "the ignored file is in the trash, intact" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

# Ignored trees a build or an install regenerates go with the worktree, a
# file inside one included however precious its name: no refusal, no trash.
test_retire_deletes_regenerable_trees_with_the_worktree() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0
    sha=$(_landed_feature_ignoring 'node_modules/
__pycache__/
.venv/
.dart_tool/
.direnv/
.hypothesis/') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    mkdir -p "$wt/apps/web/node_modules/pkg" "$wt/apps/web/src/__pycache__" "$wt/.venv/bin" \
        "$wt/apps/mobile/.dart_tool" "$wt/.direnv" "$wt/.hypothesis/examples"
    : > "$wt/apps/mobile/.dart_tool/package_config.json"
    : > "$wt/.direnv/env"
    : > "$wt/.hypothesis/examples/0a1b"
    echo "module.exports = 1" > "$wt/apps/web/node_modules/pkg/index.js"
    echo "TOKEN=x" > "$wt/apps/web/node_modules/pkg/.env"
    : > "$wt/apps/web/src/__pycache__/app.cpython-312.pyc"
    : > "$wt/.venv/bin/python"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
retired task1 $sha" "$output" "nothing is moved to the trash" || return 1
    assert_not_exists "$TEST_TMPDIR/trash.log" "the trash command is never run" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

# A trash command that fails leaves everything where it was: retire refuses
# before it removes anything, and lists what it could not move.
test_retire_refuses_when_the_trash_command_fails() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0
    sha=$(_landed_feature_ignoring '.env') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin fails trash)
    echo "KEY=value" > "$wt/apps/web/.env"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses: $output" || return 1
    assert_eq "Error: Could not move 1 ignored file to the system trash, so nothing was removed; anything the trash command did move is in the trash. Move or delete it, then run /finish task1 here again:
    apps/web/.env
trash: trash: the items could not be moved (stand-in failure)" "$output" "the refusal names the file and the trash command's error" || return 1
    assert_eq "KEY=value" "$(cat "$wt/apps/web/.env")" "the ignored file is where it was" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
}

# With no trash command at all, retire refuses rather than delete.
test_retire_refuses_without_a_trash_command() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin="$TEST_TMPDIR/no-trash-bin" output status=0
    sha=$(_landed_feature_ignoring '.env') || { echo "  FAIL: integrate fixture"; return 1; }
    link_path_without "$bin" trash
    rm -f "$bin/gio"
    echo "KEY=value" > "$wt/apps/web/.env"
    output=$(PATH="$bin" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses: $output" || return 1
    assert_eq "Error: Worktree has 1 ignored file that retiring moves to the system trash, but neither trash nor gio is installed, so nothing was removed. Move or delete it, then run /finish task1 here again:
    apps/web/.env" "$output" "the refusal names the file and the missing commands" || return 1
    assert_eq "KEY=value" "$(cat "$wt/apps/web/.env")" "the ignored file is where it was" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
}

# A name holding a newline reaches the trash command as it is on disk; the
# listing shows the newline as "?".
test_retire_moves_an_ignored_file_whose_name_holds_a_newline() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 name
    sha=$(_landed_feature_ignoring 'notes*') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    name="notes"$'\n'"final.txt"
    echo "kept" > "$wt/$name"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 1 ignored file to the system trash:
    $wt/notes?final.txt
retired task1 $sha" "$output" "the listing shows the newline as ?" || return 1
    assert_eq "$wt/$name" "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets the name with its newline" || return 1
    assert_eq "kept" "$(cat "$TEST_TMPDIR/trash-bin/1-$name")" "the file is in the trash, intact" || return 1
}

# A name holding an escape or a carriage return would recolour or overwrite
# the listing on a terminal: the listing prints each control character as
# "?", and the trash command gets the name as it is on disk.
test_retire_moves_an_ignored_file_whose_name_holds_control_characters() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 name
    sha=$(_landed_feature_ignoring 'notes*') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    name="notes"$'\033'"[31m"$'\r'"final"$'\t'".txt"
    echo "kept" > "$wt/$name"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 1 ignored file to the system trash:
    $wt/notes?[31m?final?.txt
retired task1 $sha" "$output" "the listing shows each control character as ?" || return 1
    assert_eq "$wt/$name" "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets the name as it is on disk" || return 1
    assert_eq "kept" "$(cat "$TEST_TMPDIR/trash-bin/1-$name")" "the file is in the trash, intact" || return 1
}

# A literal "?" and a newline print alike, but they are two names on disk:
# each is its own entry and each reaches the trash.
test_retire_moves_two_ignored_names_that_print_alike() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 newline_name
    sha=$(_landed_feature_ignoring 'a?b*') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    newline_name="a"$'\n'"b"
    echo "question mark" > "$wt/a?b"
    echo "newline" > "$wt/$newline_name"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 2 ignored files to the system trash:
    $wt/a?b
    $wt/a?b
retired task1 $sha" "$output" "both names are listed, each showing a newline as ?" || return 1
    assert_eq "question mark" "$(cat "$TEST_TMPDIR/trash-bin/1-a?b")" "the name holding ? is in the trash" || return 1
    assert_eq "newline" "$(cat "$TEST_TMPDIR/trash-bin/2-$newline_name")" "the name holding a newline is in the trash" || return 1
}

# An entry stands for one name exactly: "a?b" is not the start of "a<newline>bc".
test_retire_moves_an_ignored_name_that_starts_another_shown_alike() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 newline_name
    sha=$(_landed_feature_ignoring 'a?b*') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    newline_name="a"$'\n'"bc"
    echo "question mark" > "$wt/a?b"
    echo "newline" > "$wt/$newline_name"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 2 ignored files to the system trash:
    $wt/a?b
    $wt/a?bc
retired task1 $sha" "$output" "each name is listed once" || return 1
    assert_eq "question mark" "$(cat "$TEST_TMPDIR/trash-bin/1-a?b")" "the name holding ? is in the trash" || return 1
    assert_eq "newline" "$(cat "$TEST_TMPDIR/trash-bin/2-$newline_name")" "the name holding a newline is in the trash" || return 1
}

# git lists a nested repository as one path. Retire counts the files under it
# and trashes it by the name it has on disk: a backslash followed by "n" and
# a newline are two different things in a name, and both are kept.
test_retire_moves_an_ignored_nested_repository_named_with_a_backslash_and_a_newline() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 name other="$TEST_TMPDIR/other"
    sha=$(_landed_feature_ignoring 'dep*') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    name='dep\n'$'\n'"x"
    git init -q "$other"
    mkdir "$wt/$name"
    printf 'gitdir: %s\n' "$other/.git" > "$wt/$name/.git"
    echo "kept" > "$wt/$name/a"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 2 ignored files to the system trash:
    $wt/dep\\n?x/  (2 files)
retired task1 $sha" "$output" "the listing shows the backslash as it is and the newline as ?" || return 1
    assert_eq "$wt/$name" "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets the directory by the name it has on disk" || return 1
    assert_eq "kept" "$(cat "$TEST_TMPDIR/trash-bin/1-$name/a")" "the repository is in the trash, intact" || return 1
}

# A directory holding a stand-in `trash` to put first on PATH. It records
# each call on one line of $TEST_TMPDIR/trash-calls.log, as the number of
# paths the call held and their size in bytes with a NUL after each. The
# first $1 calls also record their paths in $TEST_TMPDIR/trash.log and move
# them into $TEST_TMPDIR/trash-bin; every later call moves nothing and exits 1.
measuring_trash_bin() {  # calls that succeed
    local bin="$TEST_TMPDIR/measuring-trash" calls="$TEST_TMPDIR/trash-calls.log"
    mkdir -p "$bin" "$TEST_TMPDIR/trash-bin"
    : > "$calls"
    cat > "$bin/trash" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$#" "\$(printf '%s\0' "\$@" | wc -c | tr -d '[:space:]')" >> '$calls'
if [ "\$(wc -l < '$calls' | tr -d '[:space:]')" -gt $1 ]; then
    echo 'trash: the items could not be moved (stand-in failure)' >&2
    exit 1
fi
printf '%s\n' "\$@" >> '$TEST_TMPDIR/trash.log'
mv "\$@" '$TEST_TMPDIR/trash-bin/'
EOF
    chmod +x "$bin/trash"
    echo "$bin"
}

# 600 ignored files beside a tracked one, each its own entry, named
# obj-<101..700>-<230 zeros>.o: their paths together are longer than the
# 128 KiB one call of the trash command gets.
_six_hundred_ignored_objects() {  # worktree
    local i zeros
    zeros=$(printf '%0230d' 0)
    for i in $(seq 101 700); do : > "$1/obj-$i-$zeros.o"; done
    echo "kept" > "$1/obj-101-$zeros.o"
}

# The system refuses to run a command line past a fixed size, so retire
# hands the trash command its paths over several calls, none holding more
# than 128 KiB of them.
test_retire_trashes_more_ignored_files_than_one_command_line_holds() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 zeros
    sha=$(_landed_feature_ignoring '*.o') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(measuring_trash_bin 600)
    zeros=$(printf '%0230d' 0)
    _six_hundred_ignored_objects "$wt"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: ${output:0:800}" || return 1
    assert_eq "" "$(awk '$2 > 131072' "$TEST_TMPDIR/trash-calls.log")" \
        "no call of the trash command holds more than 128 KiB of paths" || return 1
    assert_eq "600" "$(awk '{ paths += $1 } END { print paths }' "$TEST_TMPDIR/trash-calls.log")" \
        "the calls hold every path once" || return 1
    assert_eq "$(for i in $(seq 101 700); do printf '%s/obj-%s-%s.o\n' "$wt" "$i" "$zeros"; done)" \
        "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets each file by its full path, in the listing's order" || return 1
    assert_eq "kept" "$(cat "$TEST_TMPDIR/trash-bin/obj-101-$zeros.o")" "a file is in the trash, intact" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 600 ignored files to the system trash:
$(for i in $(seq 101 700); do printf '    %s/obj-%s-%s.o\n' "$wt" "$i" "$zeros"; done)
retired task1 $sha" "$output" "retire lists every file it moved" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

# When a later call of the trash command fails, retire refuses: it lists
# what it could not move, and what the earlier calls moved to the trash.
test_retire_lists_what_it_trashed_when_a_later_trash_call_fails() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0 zeros moved left
    sha=$(_landed_feature_ignoring '*.o') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(measuring_trash_bin 1)
    zeros=$(printf '%0230d' 0)
    _six_hundred_ignored_objects "$wt"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses: ${output:0:800}" || return 1
    moved=$(sed -n 1p "$TEST_TMPDIR/trash-calls.log")
    moved="${moved%% *}"
    left=$((600 - moved))
    if [ "$moved" -lt 1 ] || [ "$left" -lt 21 ]; then
        echo "  FAIL: the first call must hold some of the 600 paths and leave more than 20, it held $moved"
        return 1
    fi
    assert_eq "Error: Could not move $left ignored files to the system trash, so the worktree was not removed; anything the trash command did move is in the trash. Move or delete them, then run /finish task1 here again:
$(for i in $(seq $((101 + moved)) $((120 + moved))); do printf '    obj-%s-%s.o\n' "$i" "$zeros"; done)
    ... and $((left - 20)) more
trash: trash: the items could not be moved (stand-in failure)
Moved $moved ignored files to the system trash before this failed:
$(for i in $(seq 101 $((100 + moved))); do printf '    %s/obj-%s-%s.o\n' "$wt" "$i" "$zeros"; done)" \
        "$output" "the refusal lists what is left and what the first call moved" || return 1
    assert_eq "kept" "$(cat "$TEST_TMPDIR/trash-bin/obj-101-$zeros.o")" "the first call's files are in the trash" || return 1
    assert_file_exists "$wt/obj-$((101 + moved))-$zeros.o" "the first file of the failed call is where it was" || return 1
    assert_file_exists "$wt/obj-700-$zeros.o" "the last file is where it was" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
}

# A removal that fails after the trash step leaves the worktree, and the
# refusal says what is already in the trash and where it came from.
test_retire_lists_what_it_trashed_when_the_removal_then_fails() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@task1" sha bin output status=0
    sha=$(_landed_feature_ignoring '.env') || { echo "  FAIL: integrate fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    echo "KEY=value" > "$wt/apps/web/.env"
    git -C "$base_dir" worktree lock "$wt"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a locked worktree cannot be removed: $output" || return 1
    assert_eq "Error: git worktree remove failed for $wt; nothing was fused or deleted" "$(printf '%s\n' "$output" | head -n 1)" \
        "the refusal names the failed removal" || return 1
    assert_eq "Moved 1 ignored file to the system trash before this failed:
    $wt/apps/web/.env" "$(printf '%s\n' "$output" | tail -n 2)" "and what is already in the trash" || return 1
    assert_eq "KEY=value" "$(cat "$TEST_TMPDIR/trash-bin/1-.env")" "the file is in the trash" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
}

# Where macOS's trash is missing, GLib's `gio trash` stands in.
test_retire_moves_ignored_work_with_gio_when_trash_is_missing() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha bin="$TEST_TMPDIR/no-trash-bin" gio output status=0
    sha=$(_landed_feature_ignoring '.env') || { echo "  FAIL: integrate fixture"; return 1; }
    link_path_without "$bin" trash
    rm -f "$bin/gio"
    gio=$(fake_trash_bin moves gio)
    echo "KEY=value" > "$wt/apps/web/.env"
    output=$(PATH="$gio:$bin" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire proceeds: $output" || return 1
    assert_eq "$wt/apps/web/.env" "$(cat "$TEST_TMPDIR/trash.log")" "gio trash gets the file" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

# Every refusal that says nothing was removed comes before the trash step:
# a worktree holding an ignored file and refused for any other reason keeps
# that file where it is, and the trash command is never run.
test_retire_refuses_before_it_trashes_anything() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" base_dir="$CS_SESSIONS_ROOT/proj" sha bin case expected output status
    bin=$(fake_trash_bin moves trash)
    for case in hidden-edit no-mode untracked own-claude-local-md locked-vault base-dirty \
        settings-link unreadable-settings failed-carry private-not-a-directory; do
        rm -rf "$wt" "$base_dir" "$TEST_TMPDIR/trash.log"
        sha=$(_landed_feature_ignoring '.env') || { echo "  FAIL: $case: integrate fixture"; return 1; }
        echo "KEY=value" > "$wt/apps/web/.env"
        case "$case" in
            hidden-edit)
                git -C "$wt" update-index --skip-worktree README.md
                echo "local edit" >> "$wt/README.md"
                expected="Error: Worktree has edits git diff does not show (skip-worktree or assume-unchanged), which removal would destroy; commit them, or undo them and clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged), first:
README.md" ;;
            no-mode)
                grep -v '^cs_mode:' "$wt/.cs/local/state" > "$TEST_TMPDIR/state" && mv "$TEST_TMPDIR/state" "$wt/.cs/local/state"
                expected="Error: $wt/.cs/local/state names no cs_mode, so cs cannot tell whether git or the record fuse carries $wt/.cs; nothing was removed. Add the line 'cs_mode: tracked' if git tracks .cs in proj, else 'cs_mode: ignored', then run /finish task1 again." ;;
            untracked)
                echo "draft" > "$wt/notes.txt"
                expected="Error: Worktree has 1 untracked file that removal would destroy; commit or remove it first:
    notes.txt" ;;
            own-claude-local-md)
                echo "my own notes for this checkout" > "$wt/CLAUDE.local.md"
                expected="Error: Worktree has 1 untracked file that removal would destroy; commit or remove it first:
    CLAUDE.local.md" ;;
            locked-vault)
                rm -rf "$base_dir/.cs/plans"
                ln -s "$TEST_TMPDIR/unmounted-vault/plans" "$base_dir/.cs/plans"
                expected="Error: cannot fuse the worktree's records: $base_dir/.cs/plans is locked. Mount it, then retry." ;;
            base-dirty)
                echo "an edit" >> "$base_dir/README.md"
                expected="Error: Base session has uncommitted changes; commit them in $base_dir first" ;;
            settings-link)
                printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$TEST_TMPDIR/elsewhere.json"
                rm -f "$wt/.claude/settings.local.json"
                ln -s "$TEST_TMPDIR/elsewhere.json" "$wt/.claude/settings.local.json"
                expected="Error: $wt/.claude/settings.local.json is a link, and cs reads the feature's permission rules only from a file of its own. Nothing was removed. Put the rules in a file there, or delete the link, then run /finish task1 again." ;;
            unreadable-settings)
                printf '%s\n' '{"permissions": [1, 2]}' > "$wt/.claude/settings.local.json"
                expected="Error: $wt/.claude/settings.local.json is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot add the feature's permission rules to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish task1 again." ;;
            failed-carry)
                printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$wt/.claude/settings.local.json"
                rm -rf "$base_dir/.claude" "$TEST_TMPDIR/outside-claude"
                mkdir -p "$TEST_TMPDIR/outside-claude"
                ln -s "$TEST_TMPDIR/outside-claude" "$base_dir/.claude"
                expected="cs_mkdir_inside: $base_dir/.claude leads to $(cd "$TEST_TMPDIR/outside-claude" && pwd -P), outside the session $base_dir
Error: Could not add the feature's permission rules to $base_dir/.claude/settings.local.json; nothing was removed" ;;
            private-not-a-directory)
                # A regular file, not a link: the vault-link check before the
                # base-dirty check passes it, and the record fuse's own check
                # after the rules carry refuses it.
                rm -rf "$base_dir/.cs/private"
                echo "not a vault" > "$base_dir/.cs/private"
                expected="cs: /finish progress not recorded: .cs/private is not a directory
Error: cannot fuse the worktree's records: $base_dir/.cs/private is not a directory. Nothing was removed. Move it out of $base_dir/.cs, then run /finish task1 again." ;;
        esac
        status=0
        output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "$case: the retire refuses: $output" || return 1
        assert_eq "$expected" "$output" "$case: the refusal" || return 1
        assert_eq "KEY=value" "$(cat "$wt/apps/web/.env")" "$case: the ignored file is where it was" || return 1
        assert_not_exists "$TEST_TMPDIR/trash.log" "$case: the trash command is never run" || return 1
    done
}

test_worktree_of_worktree_refused() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj@fix-auth@deeper" 2>&1 || true)
    assert_output_contains "$output" "feature name" "second @ lands in the feature half and is rejected" || return 1
}

test_worktree_create_succeeds_with_untracked_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "stray" > "$base_dir/stray.txt"   # untracked, must not corrupt the captured path
    local output status=0
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "cs must exit 0 despite the untracked-files warning" || return 1
    assert_output_not_contains "$output" "No such file" \
        "captured worktree path must not be corrupted by the warning" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree created" || return 1
}

test_worktree_reopen_preserves_project_claude_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    cs_launch "proj@task1"   # reopen — the path that used to run migrate_session
    assert_eq "# Project CLAUDE.md" "$(cat "$CS_SESSIONS_ROOT/proj@task1/CLAUDE.md")" \
        "reopen must not rewrite the project's CLAUDE.md" || return 1
}

# A feature reopen skips migrate_session, so it carries its own refusal of a
# linked .cs/local: the checkout would otherwise read and migrate state
# behind the link.
test_worktree_reopen_refuses_a_symlinked_cs_local() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    mv "$wt/.cs/local" "$wt/payload"
    ln -s ../payload "$wt/.cs/local"

    local out rc=0
    out=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local is a symlink to ../payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "$out" "the reopen should refuse the link before reading state behind it" || return 1
}

# Feature creation writes the worktree's state before the caller sees the
# directory, so the refusal has to sit inside create_worktree_session, right
# after the checkout: a base whose history commits `.cs/local` as a link
# would otherwise have its first state writes land behind the link.
test_worktree_creation_refuses_a_committed_cs_local_link() {
    create_test_session_with_git "myproj" > /dev/null
    local base="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base/payload" && touch "$base/payload/keep"
    rm -rf "$base/.cs/local"
    ln -s ../payload "$base/.cs/local"
    git -C "$base" add -A
    git -C "$base" commit -q -m "ship .cs/local as a link"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    local out rc=0
    out=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_output_contains "$out" "Error: .cs/local is a symlink to ../payload (cs state must be a real directory inside the session). Delete .cs/local/pre-open unless you wrote it, replace the link with the directory, then reopen." \
        "creation should refuse the link right after the checkout" || return 1
    assert_not_exists "$wt/payload/state" "no state may be written behind the link" || return 1
}

test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out _try
    stub=$(_make_env_stub)
    # The reopen launch execs the stub, which prints its env. On a loaded runner
    # the launch can occasionally race the create launch's lock/PID cleanup and
    # take a cancel path, capturing empty output. Retry until the exported
    # identity appears, so the assertions test the identity, not runner load; a
    # genuine failure to export still fails all attempts.
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=myproj@fix-auth"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name" || return 1
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj@fix-auth" "a feature keeps its own task list, not the base's" || return 1
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base" || return 1
}

# A shell inside a feature carries its base in CS_SECRETS_SESSION, and one a
# cs -secrets arm started carries CS_SECRETS_CALLER. A base session launched
# from such a shell is keyed to itself and is its own caller, so its claude
# gets neither.
test_base_launch_drops_an_inherited_secrets_identity() {
    create_test_session "otherbase" > /dev/null
    local stub="$TEST_TMPDIR/claude-secrets-identity" seen="$TEST_TMPDIR/secrets-identity" out
    printf '#!/bin/sh\necho "CS_SECRETS_SESSION=${CS_SECRETS_SESSION-<unset>} CS_SECRETS_CALLER=${CS_SECRETS_CALLER-<unset>}" > "%s"\n' "$seen" > "$stub"
    chmod +x "$stub"
    out=$(CS_SECRETS_SESSION=myproj CS_SECRETS_CALLER=myproj@fix-auth CLAUDE_CODE_BIN="$stub" \
        "$CS_BIN" "otherbase" <<< "n" 2>&1) || { echo "  FAIL: the launch failed: $out"; return 1; }
    assert_eq "CS_SECRETS_SESSION=<unset> CS_SECRETS_CALLER=<unset>" "$(cat "$seen" 2>&1)" \
        "the launched claude carries no other session's secrets identity" || return 1
}

# Claude Code v2.1.233+ leaves the Task tools out on Opus 4.8, Sonnet 5 and
# Fable 5 unless the session opts in. cs's rotation wake, the walk-away drain
# and the rotate skill all address the native task list, so a launch has to
# opt in or those instructions land on a conversation with no list to keep.
# CS_NO_TASK_TOOLS=1 leaves the choice to Claude Code for users who want the
# context back.
# Both launches run under `env -u CLAUDE_CODE_ENABLE_TODO_TOOLS`: a cs session
# exports it, so a suite run from inside one inherits it and the opt-out arm
# reads the developer's environment instead of what cs decided. CI never sets
# it, so the failure appears only on a developer machine.
test_launch_enables_the_task_tools_unless_opted_out() {
    local stub env_out
    stub=$(_make_env_stub)
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=1" "a cs launch opts the session into the Task tools" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_TODO_TOOLS CS_NO_TASK_TOOLS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "tasktools-off" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=tasktools-off"*) break ;; esac
    done
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_TODO_TOOLS=" "CS_NO_TASK_TOOLS leaves the decision to Claude Code" || return 1
}

# Claude Code loads function-hooks plugins, cs's rotate mod among them, only
# behind CLAUDE_CODE_ENABLE_FUNCTION_HOOKS. A cs launch exports it so the mod
# the installer deployed actually runs; CS_NO_FUNCTION_HOOKS=1 withholds it,
# and a value the shell already set (0 to keep them off) is kept, not forced.
# `env -u` for the same reason as the Task tools test above.
test_launch_enables_function_hooks_unless_opted_out() {
    local stub env_out
    stub=$(_make_env_stub)
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS -u CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1" "a cs launch turns function hooks on" || return 1
    # The negative arms first prove the launch happened: an empty capture would
    # satisfy "not contains" without testing anything.
    for _try in 1 2 3 4 5; do
        env_out=$(env -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS CS_NO_FUNCTION_HOOKS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-off" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-off"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=fnhooks-off" "the opt-out launch reached claude" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=" "CS_NO_FUNCTION_HOOKS withholds the flag" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CS_NO_FUNCTION_HOOKS=1 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-inherited" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-inherited"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=fnhooks-inherited" "the inherited-flag launch reached claude" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=" "CS_NO_FUNCTION_HOOKS also drops a flag the shell inherited" || return 1
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0 CLAUDE_CODE_BIN="$stub" "$CS_BIN" "fnhooks-kept" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=fnhooks-kept"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0" "a value the shell set is kept" || return 1
}

test_retire_after_integrate_removes_worktree_and_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Simulate task work: code + session records, committed on the branch
    echo "fix" > "$wt/auth.txt"
    echo '{"ts":"2026-07-02T00:00:00Z","event":"task"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1)
    assert_eq "retired fix-auth $sha" "$output" "the entry's own summary line" || return 1
    assert_file_exists "$base_dir/auth.txt" "code landed by the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"task"' "timeline union-merged" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "worktree-retired" "retirement recorded" || return 1
}

test_retire_refuses_dirty_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "uncommitted" >> "$wt/CLAUDE.md"
    local sha output
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty worktree refused" || return 1
    assert_dir "$wt" "worktree preserved on refusal" || return 1
}

# git worktree remove --force recurses into a mount, so a volume mounted inside
# the feature worktree would lose what it holds.
test_retire_refuses_a_volume_mounted_inside_the_worktree() {
    local wt sha stub="$TEST_TMPDIR/retire-mount" output status=0
    create_test_session_with_git "myproj" >/dev/null
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$wt/.cs/vault-mnt"
    echo sealed > "$wt/.cs/vault-mnt/notes.md"
    _stub_mount_table "$stub" "/dev/disk9s1 on $wt/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)" || return 1
    output=$(PATH="$stub:$PATH" "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retirement refuses" || return 1
    assert_eq "Error: The feature is landed, but its worktree has a volume mounted inside it at $wt/.cs/vault-mnt, and removing the worktree would delete what the volume holds. Unmount it, then run /finish fix-auth here again." \
        "$output" "names the mount" || return 1
    assert_file_exists "$wt/.cs/vault-mnt/notes.md" "the volume's contents survive" || return 1
}

test_retire_refuses_when_the_mount_table_cannot_be_read() {
    local wt sha d="$TEST_TMPDIR/retire-mount-broken" output status=0
    create_test_session_with_git "myproj" >/dev/null
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    _stub_mount_unreadable "$d" || return 1
    output=$(PATH="$d:$PATH" "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retirement refuses" || return 1
    # The stub's own stderr line comes first; the refusal is the last line.
    assert_eq "Error: cs could not read the mount table, so it cannot tell whether a volume is mounted inside $wt; refusing to remove the worktree." \
        "$(printf '%s\n' "$output" | tail -n 1)" "says why" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_stages_itself_while_the_feature_conversation_is_open() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local stage="$base_dir/.cs/local/retire-staged/fix-auth"
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "a staged retire is not a refusal: $output" || return 1
    assert_eq "staged fix-auth $sha: the 'myproj@fix-auth' conversation is open in its worktree (PID $$); the worktree and branch are removed from this session once that conversation closes" \
        "$output" "the line says the removal is automatic" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "sha: $sha
force: 0" "$(cat "$stage")" "the stage records the captured commit and the force decision" || return 1
    # A second /finish while the conversation is still open rewrites the same stage.
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "0" "$status" "a repeat stage is not an error: $output" || return 1
    assert_eq "sha: $sha
force: 1" "$(cat "$stage")" "the repeat rewrites the stage with its own force decision" || return 1
    rm -f "$wt/.cs/session.lock"
}

test_retire_refuses_to_stage_when_the_stage_cannot_be_written() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"
    : > "$base_dir/.cs/local/retire-staged"   # a file where the stage directory goes
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "an unwritable stage is a refusal" || return 1
    assert_output_contains "$output" "Error: The feature is landed, but its worktree is still here: the 'myproj@fix-auth' conversation is open in it (PID $$), and cs could not stage its removal at $base_dir/.cs/local/retire-staged/fix-auth" \
        "the refusal names the stage it could not write" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    rm -f "$wt/.cs/session.lock"
}

test_retire_removes_its_stage_when_it_retires() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local stage="$base_dir/.cs/local/retire-staged/fix-auth"
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"
    "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" >/dev/null 2>&1 || return 1
    assert_file_exists "$stage" "staged while open" || return 1
    rm -f "$wt/.cs/session.lock"
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retires once the conversation closed: $output" || return 1
    assert_eq "retired fix-auth $sha" "$output" "the retire line" || return 1
    assert_not_exists "$stage" "a retired feature has no stage" || return 1
}

test_features_reports_a_locked_worktree_with_a_stage_as_staged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha line
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"
    "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" >/dev/null 2>&1 || return 1
    line=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_eq "worktree" "$(_feat_field "$line" 9)" "the lock column names the worktree: $line" || return 1
    assert_eq "staged" "$(_feat_field "$line" 10)" "the state reads staged: $line" || return 1
    rm -f "$wt/.cs/session.lock"
}

# The base's Stop hook, driven as its lead conversation (cs's exec arm makes
# claude carry cs's pid, so CS_LEAD_PID equals CLAUDE_PID), with the built cs
# on PATH the way an installed one is.
_base_stop() {  # base_dir
    printf '{}\n' | CLAUDE_SESSION_NAME="myproj" CLAUDE_SESSION_DIR="$1" \
        CLAUDE_SESSION_META_DIR="$1/.cs" CS_LEAD_PID=$$ CLAUDE_PID=$$ \
        PATH="$(cd "$(dirname "$CS_BIN")" && pwd):$PATH" \
        bash "$SCRIPT_DIR/../hooks/narrative-reminder.sh" 2>/dev/null | jq -r '.reason // .systemMessage // ""'
}

# A landed feature whose retire is staged behind an open conversation: the
# stage path and the captured sha are printed, one per line.
_staged_feature() {  # base_dir
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sha
    cs_launch "myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    sha=$(land_feature myproj fix-auth) || return 1
    echo "$$" > "$wt/.cs/session.lock"
    "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" >/dev/null 2>&1 || return 1
    printf '%s\n%s\n' "$1/.cs/local/retire-staged/fix-auth" "$sha"
}

# The stage path alone. Not `_staged_feature | head -n 1`: head exits after
# the first line and on Linux the fixture's second write then dies of EPIPE,
# which read as a fixture failure on the ubuntu runner.
_staged_path() {  # base_dir
    local lines
    lines=$(_staged_feature "$1") || return 1
    printf '%s\n' "${lines%%$'\n'*}"
}

test_stop_hook_leaves_a_staged_retire_while_the_feature_conversation_is_open() {
    local base_dir stage out
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    out=$(_base_stop "$base_dir")
    case "$out" in *retire*) echo "  the hook spoke of the retire while the conversation is open: $out"; return 1 ;; esac
    assert_file_exists "$stage" "stage kept" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree kept" || return 1
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
}

test_stop_hook_retires_a_staged_feature_once_its_conversation_closed() {
    local base_dir stage sha out
    base_dir=$(create_test_session_with_git "myproj")
    { read -r stage; read -r sha; } < <(_staged_feature "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
    out=$(_base_stop "$base_dir")
    assert_output_contains "$out" "cs: the 'myproj@fix-auth' conversation closed, and the retire /finish staged ran: retired fix-auth $sha" \
        "the lead's next Stop reports the retire" || return 1
    assert_not_exists "$stage" "stage consumed" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted" || return 1
}

test_stop_hook_reports_a_staged_retire_the_entry_refuses_and_drops_the_stage() {
    local base_dir stage out wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$wt/.cs/session.lock"
    echo "wip" > "$wt/auth.txt"
    out=$(_base_stop "$base_dir")
    assert_output_contains "$out" "cs: the 'myproj@fix-auth' conversation closed, and the retire /finish staged did not go through: Error: Worktree has uncommitted changes; commit them in $wt first (cs never commits for you)" \
        "the refusal reaches the model verbatim" || return 1
    assert_output_contains "$out" "run /finish fix-auth again" "and names the next step" || return 1
    assert_not_exists "$stage" "a refused stage is dropped, so it is reported once" || return 1
    assert_dir "$wt" "worktree kept" || return 1
}

test_stop_hook_of_a_teammate_leaves_a_staged_retire_alone() {
    local base_dir stage out
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
    out=$(printf '{}\n' | env -u CS_LEAD_PID -u CLAUDE_PID CLAUDE_SESSION_NAME="myproj" CLAUDE_SESSION_DIR="$base_dir" \
        CLAUDE_SESSION_META_DIR="$base_dir/.cs" PATH="$(cd "$(dirname "$CS_BIN")" && pwd):$PATH" \
        bash "$SCRIPT_DIR/../hooks/narrative-reminder.sh" 2>/dev/null | jq -r '.reason // .systemMessage // ""')
    case "$out" in *retire*) echo "  a teammate's Stop touched the staged retire: $out"; return 1 ;; esac
    assert_file_exists "$stage" "stage kept for the lead" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree kept" || return 1
}

test_stop_hook_drops_a_stage_whose_worktree_is_already_gone() {
    local base_dir stage out
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -rf "$CS_SESSIONS_ROOT/myproj@fix-auth"
    out=$(_base_stop "$base_dir")
    assert_output_contains "$out" "cs: the feature worktree $CS_SESSIONS_ROOT/myproj@fix-auth is already gone, so the retire /finish staged for fix-auth has nothing to do; its stage was dropped." \
        "a worktree removed another way is reported, not retired" || return 1
    assert_not_exists "$stage" "stage dropped" || return 1
}

test_stop_hook_reports_a_missing_cs_binary_and_keeps_the_stage() {
    local base_dir stage out
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
    out=$(printf '{}\n' | CLAUDE_SESSION_NAME="myproj" CLAUDE_SESSION_DIR="$base_dir" \
        CLAUDE_SESSION_META_DIR="$base_dir/.cs" CS_LEAD_PID=$$ CLAUDE_PID=$$ \
        HOME="$TEST_TMPDIR/nohome" PATH="/usr/bin:/bin" \
        bash "$SCRIPT_DIR/../hooks/narrative-reminder.sh" 2>/dev/null | jq -r '.reason // .systemMessage // ""')
    assert_output_contains "$out" "no cs binary was found on PATH or at ~/.local/bin/cs, so its staged retire could not run; run /finish fix-auth again" \
        "the hook says what it could not find" || return 1
    assert_file_exists "$stage" "stage kept" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree kept" || return 1
}

test_stop_hook_keeps_a_stage_whose_run_restaged_behind_a_warning() {
    local base_dir stage sha out
    base_dir=$(create_test_session_with_git "myproj")
    { read -r stage; read -r sha; } < <(_staged_feature "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    # An ended run (a pid nothing runs) whose output warned before it re-staged.
    local run="$base_dir/.cs/local/retire-runs/fix-auth"
    mkdir -p "${run%/*}"
    printf '%s\n' 999999 > "$run.run"
    printf 'Warning: something about the base\nstaged fix-auth %s: the conversation reopened its worktree (PID 1); the worktree and branch are removed from this session once that conversation closes\n' "$sha" > "$run.out"
    out=$(_base_stop "$base_dir")
    case "$out" in *retire*) echo "  a re-stage was reported as an outcome: $out"; return 1 ;; esac
    assert_file_exists "$stage" "stage kept" || return 1
    assert_not_exists "$run.run" "run record cleared" || return 1
    assert_not_exists "$run.out" "run output cleared" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree kept" || return 1
}

test_stop_hook_leaves_a_run_still_going() {
    local base_dir stage out sleeper
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    local run="$base_dir/.cs/local/retire-runs/fix-auth"
    mkdir -p "${run%/*}"
    sleep 60 &
    sleeper=$!
    printf '%s\n' "$sleeper" > "$run.run"
    : > "$run.out"
    out=$(_base_stop "$base_dir")
    kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
    case "$out" in *retire*) echo "  a running retire was reported: $out"; return 1 ;; esac
    assert_file_exists "$stage" "stage kept" || return 1
    assert_file_exists "$run.run" "run record kept while it runs" || return 1
}

# A retire that outruns the settle and succeeds: the entry leaves the stage
# in place under --staged, so the Stop that finds the run ended still has
# something to report and drops the stage with the run's records.
test_stop_hook_reports_a_staged_success_that_outran_the_settle() {
    local base_dir stage sha out sleeper
    base_dir=$(create_test_session_with_git "myproj")
    { read -r stage; read -r sha; } < <(_staged_feature "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
    local run="$base_dir/.cs/local/retire-runs/fix-auth"
    mkdir -p "${run%/*}"
    "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --staged > "$run.out" 2>&1 || { echo "  FAIL: staged retire: $(cat "$run.out")"; return 1; }
    assert_file_exists "$stage" "a staged success leaves the stage for the hook" || return 1
    sleep 60 &
    sleeper=$!
    printf '%s\n' "$sleeper" > "$run.run"
    out=$(_base_stop "$base_dir")
    case "$out" in *retire*) echo "  reported while the run was still going: $out"; return 1 ;; esac
    kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
    out=$(_base_stop "$base_dir")
    assert_output_contains "$out" "cs: the 'myproj@fix-auth' conversation closed, and the retire /finish staged ran: retired fix-auth $sha" \
        "the Stop that finds the run ended reports the success" || return 1
    assert_not_exists "$stage" "stage dropped" || return 1
    assert_not_exists "$run.run" "run record dropped" || return 1
    assert_not_exists "$run.out" "run output dropped" || return 1
}

test_stop_hook_drops_an_unreadable_stage_and_says_so() {
    local base_dir stage out
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    rm -f "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock"
    printf 'sha: not-a-commit\nforce: maybe\n' > "$stage"
    out=$(_base_stop "$base_dir")
    assert_output_contains "$out" "cs: the staged retire of fix-auth at $stage was unreadable and was removed; run /finish fix-auth again." \
        "an unreadable stage is reported, not acted on" || return 1
    assert_not_exists "$stage" "unreadable stage removed" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree kept" || return 1
}

# A base held open by a conversation this caller is no part of: a live
# process that is a sibling of the test shell, so no cs it runs descends from
# it. Started in the test's own shell (a background job of a command
# substitution dies with it); the caller reads $! and kills it.
_foreign_base_lock() {  # base_dir
    echo "$!" > "$1/.cs/session.lock"
}

test_retire_refuses_a_foreign_caller_before_it_stages() {
    local base_dir output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$wt/.cs/session.lock"
    sleep 120 &
    local holder=$!
    _foreign_base_lock "$base_dir"
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    kill "$holder" 2>/dev/null
    assert_eq "1" "$status" "a foreign caller is refused" || return 1
    assert_eq "Error: Base session 'myproj' is open elsewhere (PID $holder); run /finish fix-auth from that conversation" "$output" "before anything is staged" || return 1
    assert_not_exists "$base_dir/.cs/local/retire-staged/fix-auth" "no stage written by a caller the base refuses" || return 1
    rm -f "$wt/.cs/session.lock" "$base_dir/.cs/session.lock"
}

test_retire_staged_runs_a_recorded_stage_without_the_base_ancestry() {
    local base_dir output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sha stage="$base_dir/.cs/local/retire-staged/fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    sleep 120 &
    local holder=$!
    _foreign_base_lock "$base_dir"
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --staged 2>&1) || status=$?
    assert_eq "1" "$status" "--staged without a stage is refused" || return 1
    assert_eq "Error: No stage at $stage records retiring fix-auth at $sha with force=0; run /finish fix-auth to stage it" "$output" "and says what is missing" || return 1
    mkdir -p "${stage%/*}"
    printf 'sha: %s\nforce: 1\n' "$sha" > "$stage"   # a stage for a different decision
    status=0
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --staged 2>&1) || status=$?
    assert_eq "1" "$status" "a stage recording another force decision is not this one" || return 1
    printf 'sha: %s\nforce: 0\n' "$sha" > "$stage"
    status=0
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --staged 2>&1) || status=$?
    assert_eq "0" "$status" "the recorded stage stands in for the base ancestry: $output" || return 1
    kill "$holder" 2>/dev/null
    assert_eq "retired fix-auth $sha" "$output" "and the retire goes through" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_file_exists "$stage" "a staged run leaves the stage for the hook to drop" || return 1
    rm -f "$base_dir/.cs/session.lock"
}

test_retire_refuses_while_an_opener_holds_the_feature_mutex() {
    local base_dir output status=0 holder
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    perl -e 'use Fcntl qw(:flock); open(my $f, "+<", $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 30' \
        "$wt/.cs/session.mutex.lock" &
    holder=$!
    sleep 1
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    assert_eq "1" "$status" "the removal waits for no one and refuses" || return 1
    assert_eq "Error: Could not take the openers' mutex of $wt (another cs is opening or closing it); nothing was removed. Run /finish fix-auth again." "$output" "and says why" || return 1
    assert_dir "$wt" "worktree kept" || return 1
}

test_retire_restages_when_the_feature_reopened_under_the_mutex() {
    # The lock appears after the first check and before the mutex is taken:
    # a ps seam cannot order that, so the second read is driven directly by
    # a lock written by a live process between the two reads of live_lock_pid.
    local base_dir output status=0 stub="$TEST_TMPDIR/relock"
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sha stage="$base_dir/.cs/local/retire-staged/fix-auth"
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    # The mount-table read sits between the two lock reads; a mount shim that
    # also writes the feature lock is the reopen.
    mkdir -p "$stub"
    # The real mount is resolved before the shim shadows it: /sbin/mount on
    # macOS, /usr/bin/mount on the ubuntu runner.
    cat > "$stub/mount" <<STUB
#!/bin/sh
echo "$$" > "$wt/.cs/session.lock"
exec "$(command -v mount)" "\$@"
STUB
    chmod +x "$stub/mount"
    output=$(PATH="$stub:$PATH" "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    rm -f "$wt/.cs/session.lock"
    assert_eq "0" "$status" "a reopen before the removal is staged, not refused: $output" || return 1
    assert_output_contains "$output" "staged fix-auth $sha: the 'myproj@fix-auth' conversation reopened its worktree" "the line says it reopened" || return 1
    assert_dir "$wt" "worktree kept" || return 1
    assert_file_exists "$stage" "staged again" || return 1
}

# The feature's SessionEnd, as the lead of its conversation ending for real,
# with the built cs on PATH.
_feature_end() {  # base_dir reason
    printf '{"session_id":"s","reason":"%s","hook_event_name":"SessionEnd"}\n' "$2" \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj@fix-auth" \
          CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/myproj@fix-auth/.cs" CS_LEAD_PID=$$ CLAUDE_PID=$$ \
          PATH="$(cd "$(dirname "$CS_BIN")" && pwd):$PATH" \
          bash "$SCRIPT_DIR/../hooks/session-end.sh" >/dev/null 2>&1
}

test_feature_end_mails_the_base_when_a_retire_is_staged() {
    local base_dir stage mail
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    _feature_end "$base_dir" other
    mail=$(cat "$base_dir"/.cs/local/mail/new/*.json 2>/dev/null | jq -r '[.from, .kind, .body] | join("|")')
    assert_eq "myproj@fix-auth|notify|Feature fix-auth closed; the retire /finish staged for it runs when your current turn ends." \
        "$mail" "one notify mail from the feature to its base" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/session.lock" "the end released the lock first" || return 1
}

test_feature_end_sends_nothing_on_clear_or_without_a_stage() {
    local base_dir stage
    base_dir=$(create_test_session_with_git "myproj")
    stage=$(_staged_path "$base_dir") || { echo "  FAIL: stage fixture"; return 1; }
    _feature_end "$base_dir" clear
    assert_eq "" "$(ls -A "$base_dir/.cs/local/mail/new" 2>/dev/null)" "a /clear keeps the lock and sends nothing" || return 1
    rm -f "$stage"
    _feature_end "$base_dir" other
    assert_eq "" "$(ls -A "$base_dir/.cs/local/mail/new" 2>/dev/null)" "an end with nothing staged sends nothing" || return 1
}

test_retire_from_live_base_session_succeeds() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="11111111-1111-4111-8111-111111111111"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # The lock owner is this test shell, an ancestor of the cs subprocess just
    # like a cs launcher/Claude process is an ancestor of an in-session Bash tool.
    echo "$$" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "$$")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    assert_eq "0" "$status" "the live base session should be allowed to retire: $output" || return 1
    assert_not_exists "$wt" "retired worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retired branch deleted" || return 1
}

test_retire_from_inside_the_feature_session_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local wt_uuid
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2; exit}' "$wt/.cs/local/state")
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    echo "$$" > "$wt/.cs/session.lock"
    local output status=0
    output=$(cd "$wt" && CLAUDE_SESSION_NAME="myproj@fix-auth" \
        CS_CLAUDE_SESSION_ID="$wt_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a feature session must not remove its own live worktree"; return 1; }
    assert_output_contains "$output" "This is the 'myproj@fix-auth' conversation itself" \
        "self-retire refusal identifies the dangerous scenario" || return 1
    assert_output_contains "$output" "Close this session, then run /finish fix-auth in 'myproj'" \
        "self-retire refusal gives the hand-off" || return 1
    assert_dir "$wt" "self-retire refusal preserves the worktree" || return 1
}

test_retire_foreign_live_base_lock_still_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="22222222-2222-4222-8222-222222222222"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$base_dir/.cs/session.lock"

    local output status=0
    output=$(CLAUDE_SESSION_NAME="foreign" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a foreign live base lock must refuse"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "foreign live lock keeps the hard refusal" || return 1
    assert_dir "$wt" "foreign-lock refusal preserves the worktree" || return 1
}

test_retire_reused_live_pid_is_not_treated_as_own_lock() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="33333333-3333-4333-8333-333333333333"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }

    # A stale lock can point at a PID later reused by an unrelated live process.
    # The matching name and UUID are insufficient: that PID must own this cs call.
    sleep 30 &
    local reused_pid=$!
    echo "$reused_pid" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "1")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    kill "$reused_pid" 2>/dev/null || true
    wait "$reused_pid" 2>/dev/null || true

    [ "$status" -ne 0 ] || { echo "  FAIL: a reused foreign PID must not be exempted"; return 1; }
    assert_output_contains "$output" "is open elsewhere" "reused live PID keeps the hard refusal" || return 1
    assert_dir "$wt" "reused-PID refusal preserves the worktree" || return 1
}

# Retire reads the feature's lock by live_lock_pid's rule: "-1" and "0" name
# process groups and "+<pid>" is not a pid, so none of them is the feature's
# conversation. The live foreign base lock behind it is the next refusal.
test_retire_reads_the_feature_lock_by_the_one_lock_rule() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "$$" > "$base_dir/.cs/session.lock"

    local text output status
    for text in "-1" "0" "+$$"; do
        printf '%s\n' "$text" > "$wt/.cs/session.lock"
        status=0
        output=$(CLAUDE_SESSION_NAME="foreign" \
            "$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "retire over a feature lock of '$text' exits 1: $output" || return 1
        assert_eq "Error: Base session 'myproj' is open elsewhere (PID $$); run /finish fix-auth from that conversation" \
            "$output" "a feature lock of '$text' is not a live conversation" || return 1
        assert_dir "$wt" "the worktree stays over a feature lock of '$text'" || return 1
    done
}

# A sha the base does not have is refused by name, the sha as given.
test_retire_names_a_commit_the_base_lacks() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    land_feature myproj fix-auth > /dev/null || { echo "  FAIL: integrate fixture"; return 1; }
    local missing="0123456789abcdef0123456789abcdef01234567" output status=0
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$missing" 2>&1) || status=$?
    assert_eq "1" "$status" "a commit the base lacks is refused: $output" || return 1
    assert_eq "Error: Commit not found in myproj: $missing" "$output" "the refusal names the sha given" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_refuses_an_unintegrated_feature() {
    # Retirement never merges: a commit the base lacks is a refusal that
    # names /finish, whatever the old merge verb would have done with it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "an unintegrated feature is refused" || return 1
    assert_output_contains "$output" "is not integrated into myproj; run /finish fix-auth before retiring" \
        "the refusal names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_file_not_exists "$base_dir/shared.txt" "nothing was merged" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth | tr -d ' *+')" "branch kept" || return 1
}

test_retire_refuses_commits_after_the_captured_one() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "one" > "$wt/one.txt"
    (cd "$wt" && git add one.txt && git commit -q -m one)
    local sha output status=0
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "two" > "$wt/two.txt"
    (cd "$wt" && git add two.txt && git commit -q -m two)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a tip the base lacks is refused" || return 1
    assert_output_contains "$output" "1 commit(s) on cs/fix-auth after $sha are not integrated; run /finish fix-auth again" \
        "the refusal counts the commits and names /finish" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_force_takes_a_squash_landed_branch() {
    # A PR squash-merged on GitHub leaves cs/<task> a non-ancestor of the base
    # forever; the skill passes --force on that evidence, and the branch goes
    # with -D since -d would refuse it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "squashed elsewhere" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "0" "$status" "force retires: $output" || return 1
    assert_eq "retired fix-auth $sha" "$output" "the summary line" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "unmerged branch deleted under force" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "force never merges" || return 1
}

test_retire_force_refuses_commits_after_the_captured_one() {
    # --force skips only "is the captured commit in the base": a commit made
    # on the branch after the PR's capture is work the PR never carried, and
    # deleting the branch would lose it.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "in the pr" > "$wt/a.txt"
    (cd "$wt" && git add a.txt && git commit -q -m "A")
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "after the pr" > "$wt/b.txt"
    (cd "$wt" && git add b.txt && git commit -q -m "B")
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "1" "$status" "force refuses a tip past the captured commit" || return 1
    assert_output_contains "$output" "1 commit(s) on cs/fix-auth after $sha are not integrated; run /finish fix-auth again" \
        "the refusal counts the unlanded commits" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "+cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth | tr -d ' ')" "branch kept" || return 1
}

test_retire_fuses_nothing_when_removal_fails_and_retry_fuses_once() {
    # Records are fused only once the worktree is gone: a removal that fails
    # (here: a locked worktree) leaves the base's records untouched and the
    # worktree's own in place, so the retry after unlocking fuses exactly once.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    printf '{"event":"base-seed"}\n' > "$base_dir/.cs/timeline.jsonl"
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    git -C "$base_dir" worktree lock "$wt"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a locked worktree cannot be removed: $output" || return 1
    assert_dir "$wt" "worktree survives" || return 1
    assert_file_exists "$wt/.cs/timeline.jsonl" "the worktree's records are back where they were" || return 1
    assert_eq "1" "$(grep -c "base-seed" "$base_dir/.cs/timeline.jsonl")" "base records untouched" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "from-task" "nothing fused on a failed removal" || return 1
    git -C "$base_dir" worktree unlock "$wt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retry retires: $output" || return 1
    assert_not_exists "$wt" "worktree removed on retry" || return 1
    assert_eq "1" "$(grep -c "from-task" "$base_dir/.cs/timeline.jsonl")" "fused exactly once" || return 1
}

# An encrypted base keeps its log behind .cs/private, and a locked vault
# cannot take the worktree's. Retire refuses before anything moves: the
# worktree stays whole with its records, nothing is stranded in a .retire-*
# staging directory, and the retry once the vault is mounted fuses once.
test_retire_with_a_locked_base_vault_leaves_the_worktree_whole() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    ln -s "$TEST_TMPDIR/vault-mnt/private" "$base_dir/.cs/private"
    _mark_hand_made_vault "$base_dir"

    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?

    assert_eq "1" "$status" "retire refuses while the base vault is locked: $output" || return 1
    assert_output_contains "$output" "$base_dir/.cs/private is locked" "the refusal names the vault" || return 1
    assert_dir "$wt" "the worktree survives" || return 1
    assert_file_exists "$wt/.cs/timeline.jsonl" "the worktree keeps its records in place" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "from-task" "nothing is fused" || return 1
    local stranded
    stranded=$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*')
    assert_eq "" "$stranded" "no records are stranded in a staging directory" || return 1

    mkdir -p "$TEST_TMPDIR/vault-mnt/private"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retry with the vault mounted retires: $output" || return 1
    assert_not_exists "$wt" "worktree removed on retry" || return 1
    assert_eq "1" "$(grep -c "from-task" "$base_dir/.cs/timeline.jsonl")" "fused exactly once" || return 1
}

# A fuse write that fails after the worktree is gone (a full disk, an
# unwritable base) must not count as fused: the staging directory holding
# the only copy of the records stays, and retire names it and exits 1. The
# base's memory directory is made read-only so the narrative copy fails.
test_retire_keeps_the_records_when_a_fuse_write_fails() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf 'only copy of the task notes\n' > "$wt/.cs/memory/narrative.example.md"
    local sha output status=0 aside
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 555 "$base_dir/.cs/memory"

    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    chmod 755 "$base_dir/.cs/memory"

    assert_eq "1" "$status" "retire reports the failed fuse: $output" || return 1
    assert_output_contains "$output" "its session records could not be fused" "the error says the fuse failed" || return 1
    aside=$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*' | head -1)
    assert_file_exists "$aside/cs/memory/narrative.example.md" "the staged records survive the failed fuse" || return 1
}

test_retire_refusal_for_an_open_session_comes_after_the_landing_check() {
    # An open conversation on an UNLANDED feature must hear "/finish first",
    # not "the feature is landed, close the session".
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "work" > "$wt/w.txt"
    (cd "$wt" && git add w.txt && git commit -q -m work)
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "$$" > "$wt/.cs/session.lock"
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    rm -f "$wt/.cs/session.lock"
    assert_eq "1" "$status" "refused" || return 1
    assert_output_contains "$output" "is not integrated into myproj; run /finish fix-auth before retiring" "the landing check speaks first" || return 1
    assert_output_not_contains "$output" "The feature is landed" "no false reassurance" || return 1
}

test_retire_force_still_refuses_untracked_work() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "precious" > "$wt/never-added.txt"
    local sha output status=0
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" --force 2>&1) || status=$?
    assert_eq "1" "$status" "force skips the ancestry check only" || return 1
    assert_output_contains "$output" "never-added.txt" "the refusal names the path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_retire_rejects_traversal_task_name() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    # A task argument with path separators would build an escaping worktree
    # path; the entry must reject it with the feature-name charset error before
    # touching the filesystem, matching the launch path's validation.
    local output status=0
    output=$("$CS_BIN" "myproj" -retire-feature "e/../../x" deadbeef 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a task name with path separators must be rejected"; return 1; }
    assert_output_contains "$output" "alphanumeric" "rejects a traversal task name with the charset error" || return 1
}

test_retire_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -retire-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-retire-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'retire-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'retire-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'retire-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'retire-feature' "README never lists it" || return 1
}

test_merge_verb_is_gone() {
    local base_dir output status=0
    base_dir=$(create_test_session_with_git "myproj")
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?
    assert_eq "1" "$status" "--merge is not a session command any more" || return 1
    assert_output_contains "$output" "Unknown session command: --merge" "and says so" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" '[-]-merge' "help does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" '[-]-merge' "zsh completion does not list it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" '[-]-merge' "bash completion does not list it" || return 1
}

# With core.autocrlf enabled, a CRLF-rewritten .gitignore
# carries a trailing \r on every pattern and matches nothing, so files cs means
# to ignore surface as untracked — which then blocks retirement.
test_session_repo_pins_autocrlf_off() {
    local cfg="$TEST_TMPDIR/gitconfig-autocrlf"
    printf '[core]\n\tautocrlf = true\n' > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" "$CS_BIN" acrlf <<< "" >/dev/null 2>&1
    local repo="$CS_SESSIONS_ROOT/acrlf"
    [ -d "$repo/.git" ] || { echo "  FAIL: session repo not created"; return 1; }
    # --local, not the effective value: a global autocrlf=false on the dev box
    # would otherwise satisfy this without cs having written anything.
    assert_eq "false" "$(git -C "$repo" config --local --get core.autocrlf 2>/dev/null)" \
        "a session repo must pin core.autocrlf off in its own config" || return 1
}

# cs records the protocol file in the worktree's info/exclude, at whatever path
# git reports for it. A worktree's git-path is absolute; mis-reading that as
# relative sends the entry to a nonsense path,
# leaves CLAUDE.local.md untracked, and blocks retirement.
test_worktree_excludes_protocol_file() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    [ -f "$wt/CLAUDE.local.md" ] || { echo "  FAIL: protocol file not written to the worktree"; return 1; }
    (cd "$wt" && git check-ignore -q CLAUDE.local.md) \
        || { echo "  FAIL: CLAUDE.local.md is not ignored inside the worktree"
             echo "  status: $( (cd "$wt" && git status --porcelain) | tr '\n' ' ')"; return 1; }
}

# A project adopted with cs -adopt: a repo with one commit of its own, and
# cs's files in the working tree, uncommitted. Prints the project dir.
adopted_base() {  # name
    local dir="$TEST_TMPDIR/$1"
    mkdir -p "$dir"
    printf '# P\n' > "$dir/README.md"
    (cd "$dir" && git init -q && git config core.autocrlf false && git add README.md && git commit -q -m init)
    (cd "$dir" && "$CS_BIN" -adopt "$1" < /dev/null > /dev/null 2>&1) || return 1
    (cd "$dir" && pwd -P)
}

# The common info/exclude of the repo at <dir>.
common_exclude() {  # dir
    printf '%s/info/exclude\n' "$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
}

# Adopt records that the session's features expect git to carry .cs. Until the
# user commits it, a feature is refused, and the base's .cs stays visible to git.
test_feature_of_an_adopted_base_waits_for_git_to_carry_cs() {
    local dir out rc=0
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }

    out=$("$CS_BIN" proj@t1 < /dev/null 2>&1) || rc=$?

    assert_eq 1 "$rc" "the feature is refused" || return 1
    assert_eq "Error: Session 'proj' expects git to carry .cs (cs_mode: tracked in $dir/.cs/local/state), but git tracks nothing under .cs there. Commit it first (git add .cs .gitignore .gitattributes, then git commit, in $dir), or set that line to 'cs_mode: ignored' to keep .cs out of git, which features then hide through .git/info/exclude." \
        "$out" "the refusal names both ways on" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/proj@t1" "no worktree is created" || return 1
    assert_eq "" "$(git -C "$dir" branch --list cs/t1)" "no branch is created" || return 1
    assert_file_not_contains "$(common_exclude "$dir")" '^\.cs/$' "the base's .cs is not hidden from git" || return 1
    assert_eq "?? .cs/" "$(git -C "$dir" status --porcelain -- .cs)" "git still shows the base's .cs" || return 1
}

# Once the user commits .cs, git carries it: the feature is tracked, nothing
# hides the base's .cs, and the feature lands and retires.
test_feature_of_an_adopted_base_is_tracked_once_cs_is_committed() {
    local dir wt sha out
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }
    (cd "$dir" && git add .cs .gitignore .gitattributes && git commit -q -m "track cs") || { echo "  FAIL: commit fixture"; return 1; }

    cs_launch proj@t1
    wt="$CS_SESSIONS_ROOT/proj@t1"

    assert_file_contains "$wt/.cs/local/state" '^cs_mode: tracked$' "the feature is tracked" || return 1
    assert_file_exists "$wt/.cs/README.md" "git carried .cs into the checkout" || return 1
    assert_file_not_contains "$(common_exclude "$dir")" '^\.cs/$' "nothing hides the base's .cs" || return 1
    printf 'work\n' > "$wt/work.txt"
    (cd "$wt" && git add work.txt && git commit -q -m work)
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate failed"; return 1; }
    assert_file_exists "$dir/work.txt" "the feature landed on the base" || return 1
    out=$("$CS_BIN" proj -retire-feature t1 "$sha" < /dev/null 2>&1) || { echo "  FAIL: retire failed: $out"; return 1; }
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

# Git's answer wins once it tracks .cs: a feature is tracked even where the
# base still records ignored, since the record fuse would rewrite the tracked
# records the checkout already holds.
test_feature_is_tracked_once_git_tracks_cs_whatever_the_record_says() {
    local dir
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }
    awk '!/^cs_mode:/' "$dir/.cs/local/state" > "$dir/.cs/local/state.tmp" && mv "$dir/.cs/local/state.tmp" "$dir/.cs/local/state"
    printf 'cs_mode: ignored\n' >> "$dir/.cs/local/state"
    (cd "$dir" && git add .cs .gitignore .gitattributes && git commit -q -m "track cs") || { echo "  FAIL: commit fixture"; return 1; }

    cs_launch proj@t1

    assert_file_contains "$CS_SESSIONS_ROOT/proj@t1/.cs/local/state" '^cs_mode: tracked$' "the feature is tracked" || return 1
    assert_file_not_contains "$(common_exclude "$dir")" '^\.cs/$' "nothing hides the base's .cs" || return 1
}

# A recorded ignored keeps .cs out of git: the feature hides it through the
# common exclude, and the record fuse carries its records back at retire.
test_feature_of_an_adopted_base_recorded_ignored_keeps_cs_out_of_git() {
    local dir wt sha out
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }
    printf 'cs_mode: ignored\n' >> "$dir/.cs/local/state"
    awk '!/^cs_mode: tracked$/' "$dir/.cs/local/state" > "$dir/.cs/local/state.tmp" && mv "$dir/.cs/local/state.tmp" "$dir/.cs/local/state"

    cs_launch proj@t1
    wt="$CS_SESSIONS_ROOT/proj@t1"

    assert_file_contains "$wt/.cs/local/state" '^cs_mode: ignored$' "the feature is ignored" || return 1
    assert_file_contains "$(common_exclude "$dir")" '^\.cs/$' "the feature hides .cs through the common exclude" || return 1
    printf 'work\n' > "$wt/work.txt"
    (cd "$wt" && git add work.txt && git commit -q -m work)
    printf 'feature finding\n' > "$wt/.cs/memory/note-feature.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate failed"; return 1; }
    out=$("$CS_BIN" proj -retire-feature t1 "$sha" < /dev/null 2>&1) || { echo "  FAIL: retire failed: $out"; return 1; }
    assert_not_exists "$wt" "the worktree is retired" || return 1
    assert_eq "feature finding" "$(cat "$dir/.cs/memory/note-feature.md")" "the feature's record reached the base" || return 1
}

# A project that ignores .cs itself gets ignored-mode features with no hand
# edit, once the user commits the rules adopt added to its .gitignore.
test_feature_of_an_adopted_base_that_ignores_cs_is_ignored() {
    local dir="$TEST_TMPDIR/proj" out
    mkdir -p "$dir"
    printf '.cs/\n' > "$dir/.gitignore"
    (cd "$dir" && git init -q && git config core.autocrlf false && git add .gitignore && git commit -q -m init)
    (cd "$dir" && "$CS_BIN" -adopt proj < /dev/null > /dev/null 2>&1) || { echo "  FAIL: adopt fixture"; return 1; }
    dir=$(cd "$dir" && pwd -P)
    (cd "$dir" && git commit -q -m "cs rules" -- .gitignore) || { echo "  FAIL: commit fixture"; return 1; }

    out=$("$CS_BIN" proj@t1 < /dev/null 2>&1) || { echo "  FAIL: the feature was refused: $out"; return 1; }

    assert_file_contains "$CS_SESSIONS_ROOT/proj@t1/.cs/local/state" '^cs_mode: ignored$' "the feature is ignored" || return 1
}

# A session adopted before adopt recorded a mode, with .cs untracked, keeps
# the inference from the index: the feature is ignored.
test_feature_of_a_base_with_no_recorded_mode_infers_it() {
    local dir
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }
    awk '!/^cs_mode:/' "$dir/.cs/local/state" > "$dir/.cs/local/state.tmp" && mv "$dir/.cs/local/state.tmp" "$dir/.cs/local/state"

    cs_launch proj@t1

    assert_file_contains "$CS_SESSIONS_ROOT/proj@t1/.cs/local/state" '^cs_mode: ignored$' "the mode is inferred" || return 1
    assert_file_contains "$(common_exclude "$dir")" '^\.cs/$' "and the base's .cs is hidden as before" || return 1
}

# A recorded mode cs does not know is refused, never guessed at.
test_feature_refuses_a_recorded_mode_it_does_not_know() {
    local dir out rc=0
    dir=$(adopted_base proj) || { echo "  FAIL: adopt fixture"; return 1; }
    awk '!/^cs_mode:/' "$dir/.cs/local/state" > "$dir/.cs/local/state.tmp" && mv "$dir/.cs/local/state.tmp" "$dir/.cs/local/state"
    printf 'cs_mode: both\n' >> "$dir/.cs/local/state"

    out=$("$CS_BIN" proj@t1 < /dev/null 2>&1) || rc=$?

    assert_eq 1 "$rc" "the feature is refused" || return 1
    assert_eq "Error: Session 'proj' names cs_mode 'both' in $dir/.cs/local/state; cs knows tracked and ignored. Fix that line, then create the feature again." \
        "$out" "the refusal names the value" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/proj@t1" "no worktree is created" || return 1
}

# A folder adopted with no repo gets git init and no commit, so its HEAD names
# no commit: a feature has nothing to branch from. Refused by cs, whatever
# mode the base records, before git would make an orphan branch of it.
test_feature_of_a_base_with_no_commit_is_refused() {
    local dir out rc mode
    dir="$TEST_TMPDIR/proj"
    mkdir -p "$dir"
    printf '# P\n' > "$dir/README.md"
    (cd "$dir" && "$CS_BIN" -adopt proj < /dev/null > /dev/null 2>&1) || { echo "  FAIL: adopt fixture"; return 1; }
    dir=$(cd "$dir" && pwd -P)
    for mode in ignored tracked; do
        awk '!/^cs_mode:/' "$dir/.cs/local/state" > "$dir/.cs/local/state.tmp" && mv "$dir/.cs/local/state.tmp" "$dir/.cs/local/state"
        printf 'cs_mode: %s\n' "$mode" >> "$dir/.cs/local/state"
        rc=0
        out=$("$CS_BIN" proj@t1 < /dev/null 2>&1) || rc=$?
        assert_eq 1 "$rc" "the feature is refused (cs_mode $mode)" || return 1
        assert_eq "Error: Session 'proj' has no commit yet, so a feature has nothing to branch from or land on. Make a first commit in $dir (cs commits nothing for you), then try again." \
            "$out" "the refusal says the base has no commit (cs_mode $mode)" || return 1
        assert_not_exists "$CS_SESSIONS_ROOT/proj@t1" "no worktree is created (cs_mode $mode)" || return 1
        assert_eq "" "$(git -C "$dir" branch --list cs/t1)" "no branch is created (cs_mode $mode)" || return 1
    done
}

# A feature whose base has lost its commit (HEAD names a branch with none)
# cannot be landed or retired: both say so before git is asked about HEAD.
test_integrate_and_retire_refuse_a_base_with_no_commit() {
    local base_dir wt sha out rc
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@t1"
    wt="$CS_SESSIONS_ROOT/myproj@t1"
    printf 'work\n' > "$wt/work.txt"
    (cd "$wt" && git add work.txt && git commit -q -m work)
    sha=$(git -C "$wt" rev-parse HEAD)
    git -C "$base_dir" symbolic-ref HEAD refs/heads/unborn

    rc=0
    out=$("$CS_BIN" myproj -integrate-feature t1 "$sha" -- true < /dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "integrate is refused" || return 1
    assert_eq "Error: Session 'myproj' has no commit yet, so a feature has nothing to branch from or land on. Make a first commit in $base_dir (cs commits nothing for you), then try again." \
        "$out" "integrate says the base has no commit" || return 1
    rc=0
    out=$("$CS_BIN" myproj -retire-feature t1 "$sha" < /dev/null 2>&1) || rc=$?
    assert_eq 1 "$rc" "retire is refused" || return 1
    assert_eq "Error: Session 'myproj' has no commit yet, so a feature has nothing to branch from or land on. Make a first commit in $base_dir (cs commits nothing for you), then try again." \
        "$out" "retire says the base has no commit" || return 1
    assert_dir "$wt" "the worktree is kept" || return 1
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_worktree_name_rejects_a_leading_dot_in_either_half
run_test test_plain_names_still_work
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_open_refuses_a_locked_vault
run_test test_worktree_create_refuses_a_locked_base_vault
run_test test_worktree_create_refuses_an_encrypted_base
run_test test_worktree_create_refuses_an_encrypted_base_with_untracked_links
run_test test_worktree_open_refuses_once_its_base_is_encrypted
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_refuses_a_detached_base
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_ignored_mode_worktree_starts_with_nothing_untracked
run_test test_ignored_mode_worktree_retires_without_a_manual_exclude
run_test test_feature_of_an_adopted_base_waits_for_git_to_carry_cs
run_test test_feature_of_an_adopted_base_is_tracked_once_cs_is_committed
run_test test_feature_is_tracked_once_git_tracks_cs_whatever_the_record_says
run_test test_feature_of_an_adopted_base_recorded_ignored_keeps_cs_out_of_git
run_test test_feature_of_an_adopted_base_that_ignores_cs_is_ignored
run_test test_feature_of_a_base_with_no_recorded_mode_infers_it
run_test test_feature_refuses_a_recorded_mode_it_does_not_know
run_test test_feature_of_a_base_with_no_commit_is_refused
run_test test_integrate_and_retire_refuse_a_base_with_no_commit
run_test test_retire_tolerates_a_worktree_predating_the_cs_exclude
run_test test_retire_still_refuses_real_untracked_work
run_test test_retire_moves_ignored_work_to_the_system_trash
run_test test_retire_deletes_regenerable_trees_with_the_worktree
run_test test_retire_refuses_when_the_trash_command_fails
run_test test_retire_refuses_without_a_trash_command
run_test test_retire_moves_ignored_work_with_gio_when_trash_is_missing
run_test test_retire_refuses_before_it_trashes_anything
run_test test_retire_moves_an_ignored_file_whose_name_holds_a_newline
run_test test_retire_moves_an_ignored_file_whose_name_holds_control_characters
run_test test_retire_moves_two_ignored_names_that_print_alike
run_test test_retire_moves_an_ignored_name_that_starts_another_shown_alike
run_test test_retire_moves_an_ignored_nested_repository_named_with_a_backslash_and_a_newline
run_test test_retire_trashes_more_ignored_files_than_one_command_line_holds
run_test test_retire_lists_what_it_trashed_when_a_later_trash_call_fails
run_test test_retire_lists_what_it_trashed_when_the_removal_then_fails

# Ignored build trees hold tens of thousands of files. The refusal names each
# whole tree once with its file count, under the total, so the files that are
# the user's work stay readable beside them.
test_retire_refusal_collapses_untracked_trees() {
    local wt="$CS_SESSIONS_ROOT/proj@task1" sha output status=0
    sha=$(_landed_feature_ignoring 'node_modules/
.svelte-kit/
.env') || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$wt/apps/web/node_modules/pkg" "$wt/apps/web/.svelte-kit/out" "$wt/apps/web/src/__screenshots__" "$wt/scratch"
    (cd "$wt/apps/web/node_modules/pkg" && touch f{1..3000})
    (cd "$wt/apps/web/.svelte-kit/out" && touch f{1..1200})
    (cd "$wt/scratch" && touch f{1..1200})
    touch "$wt/apps/web/src/__screenshots__/a.png" "$wt/apps/web/src/__screenshots__/b.png"
    echo KEY=value > "$wt/apps/web/.env"
    echo draft > "$wt/notes.txt"
    output=$("$CS_BIN" "proj" -retire-feature "task1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "retire refuses: $output" || return 1
    assert_eq "Error: Worktree has 1,203 untracked files that removal would destroy; commit or remove them first:
    scratch/                       (1,200 files)
    apps/web/src/__screenshots__/  (2 files)
    notes.txt" "$output" "the refusal collapses each untracked tree to one counted line and lists no ignored file" || return 1
    assert_file_exists "$wt/apps/web/.env" "the ignored file survives the refusal" || return 1
}

run_test test_retire_refusal_collapses_untracked_trees

# cs and the TUI list files a removal would destroy in one format, pinned by
# one fixture both render: input.txt holds the tracked paths, the file count
# of each directory git does not list into, and the paths at risk, separated
# by empty lines; expected.txt holds the count phrase, then the entry lines.
# A path is written as cs lists it, one per line: a newline in a name as "\n",
# a backslash as "\\". The fixture holds a name with a newline and one with
# an escape and a tab, each control character printing as "?", a name with
# a direction-flipping and a zero-width character beside an accent and a
# space, each of those two characters printing as one "?", a name holding
# every direction-flipping and zero-width character and C1 controls
# (U+0080, U+0085, U+009B, U+009F), each printing as one "?", beside the
# characters just outside each range of them in Unicode (U+2010, U+202F,
# U+200A, U+2029, U+205F, U+2061, U+2065, U+206A, U+061B, U+061D, U+FEFE,
# U+FF00, U+00A0) and U+00A1, which print as themselves, and a directory
# named in two-byte characters, which pads by characters.
test_untracked_listing_renders_the_shared_fixture() {
    local fixture="$SCRIPT_DIR/fixtures/untracked-listing" out status=0
    out=$( source "$SCRIPT_DIR/../lib/30-worktree.sh"
           _untracked_listing_render < "$fixture/input.txt" ) || status=$?
    assert_eq "0" "$status" "the fixture renders: $out" || return 1
    assert_eq "$(cat "$fixture/expected.txt")" "$out" "the listing matches the shared fixture" || return 1
}

# Names are bytes to cs, and a name need not be valid UTF-8 (the shared
# fixture must be, since the TUI reads it as text). A C1 control (U+009B,
# bytes \302\233) prints as one "?"; a \302 that starts no C1 control, before
# an ASCII letter or at the end of the name, prints as itself.
test_printable_name_keeps_a_lead_byte_that_starts_no_c1_control() {
    local out
    out=$( source "$SCRIPT_DIR/../lib/30-worktree.sh"
           _printable_name $'a\302b\302\233c\302' )
    assert_eq $'a\302b?c\302' "$out" "the C1 control is one ?, each stray \\302 as itself" || return 1
}

run_test test_untracked_listing_renders_the_shared_fixture
run_test test_printable_name_keeps_a_lead_byte_that_starts_no_c1_control
run_test test_worktree_of_worktree_refused
run_test test_worktree_create_succeeds_with_untracked_base
run_test test_worktree_reopen_preserves_project_claude_md
run_test test_worktree_reopen_refuses_a_symlinked_cs_local
run_test test_worktree_creation_refuses_a_committed_cs_local_link
run_test test_worktree_launch_exports_base_identity
run_test test_base_launch_drops_an_inherited_secrets_identity
run_test test_launch_enables_the_task_tools_unless_opted_out
run_test test_launch_enables_function_hooks_unless_opted_out
run_test test_retire_after_integrate_removes_worktree_and_branch
run_test test_retire_refuses_dirty_worktree
run_test test_retire_stages_itself_while_the_feature_conversation_is_open
run_test test_retire_refuses_to_stage_when_the_stage_cannot_be_written
run_test test_retire_removes_its_stage_when_it_retires
run_test test_features_reports_a_locked_worktree_with_a_stage_as_staged
run_test test_stop_hook_leaves_a_staged_retire_while_the_feature_conversation_is_open
run_test test_stop_hook_retires_a_staged_feature_once_its_conversation_closed
run_test test_stop_hook_reports_a_staged_retire_the_entry_refuses_and_drops_the_stage
run_test test_stop_hook_of_a_teammate_leaves_a_staged_retire_alone
run_test test_stop_hook_drops_an_unreadable_stage_and_says_so
run_test test_stop_hook_drops_a_stage_whose_worktree_is_already_gone
run_test test_stop_hook_reports_a_missing_cs_binary_and_keeps_the_stage
run_test test_stop_hook_keeps_a_stage_whose_run_restaged_behind_a_warning
run_test test_stop_hook_leaves_a_run_still_going
run_test test_stop_hook_reports_a_staged_success_that_outran_the_settle
run_test test_retire_refuses_a_foreign_caller_before_it_stages
run_test test_retire_staged_runs_a_recorded_stage_without_the_base_ancestry
run_test test_retire_refuses_while_an_opener_holds_the_feature_mutex
run_test test_retire_restages_when_the_feature_reopened_under_the_mutex
run_test test_feature_end_mails_the_base_when_a_retire_is_staged
run_test test_feature_end_sends_nothing_on_clear_or_without_a_stage
run_test test_retire_refuses_a_volume_mounted_inside_the_worktree
run_test test_retire_refuses_when_the_mount_table_cannot_be_read
run_test test_retire_from_live_base_session_succeeds
run_test test_retire_from_inside_the_feature_session_refuses
run_test test_retire_foreign_live_base_lock_still_refuses
run_test test_retire_reused_live_pid_is_not_treated_as_own_lock
run_test test_retire_reads_the_feature_lock_by_the_one_lock_rule
run_test test_retire_names_a_commit_the_base_lacks
run_test test_retire_refuses_an_unintegrated_feature
run_test test_retire_refuses_commits_after_the_captured_one
run_test test_retire_force_takes_a_squash_landed_branch
run_test test_retire_force_still_refuses_untracked_work
run_test test_retire_force_refuses_commits_after_the_captured_one
run_test test_retire_fuses_nothing_when_removal_fails_and_retry_fuses_once
run_test test_retire_with_a_locked_base_vault_leaves_the_worktree_whole
run_test test_retire_keeps_the_records_when_a_fuse_write_fails
run_test test_retire_refusal_for_an_open_session_comes_after_the_landing_check
run_test test_retire_rejects_traversal_task_name
run_test test_retire_is_hidden_from_completion_and_unknown_command_text
run_test test_merge_verb_is_gone

# --- -integrate-feature: integrate while the feature stays open, remove nothing ---

# Build base + feature with one feature commit; prints the feature SHA.
integrate_fixture() {  # base task
    local base_dir wt
    base_dir=$(create_test_session_with_git "$1")
    cs_launch "$1@$2"
    wt="$CS_SESSIONS_ROOT/$1@$2"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    git -C "$wt" rev-parse HEAD
}

test_integrate_refuses_unknown_worktree() {
    create_test_session_with_git "myproj" > /dev/null
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature ghost HEAD -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an unregistered worktree refuses" || return 1
    assert_output_contains "$output" "not a registered worktree" "names the reason" || return 1
}

test_integrate_refuses_sha_not_on_feature_branch() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "base only")
    local stray output status=0
    stray=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$stray" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a commit not reachable from cs/<task> refuses" || return 1
    assert_output_contains "$output" "not reachable from cs/fix-auth" "names the branch" || return 1
}

test_integrate_reports_already_integrated_and_does_nothing() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "already integrated exits 0: $output" || return 1
    assert_output_contains "$output" "already-integrated fix-auth $sha" "machine line printed" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "no commit is made" || return 1
}

# A sha the base does not have is refused by name, the sha as given.
test_integrate_names_a_commit_the_base_lacks() {
    local base_dir head
    integrate_fixture myproj fix-auth > /dev/null
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    local missing="0123456789abcdef0123456789abcdef01234567" output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$missing" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a commit the base lacks is refused: $output" || return 1
    assert_eq "Error: Commit not found in myproj: $missing" "$output" "the refusal names the sha given" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
}

test_integrate_refuses_dirty_base() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "edit" >> "$base_dir/CLAUDE.md"
    local head output status=0
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "dirty base refuses" || return 1
    assert_output_contains "$output" "uncommitted changes" "names the dirt" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
}

test_integrate_refuses_foreign_live_base_lock() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # A live PID that is not an ancestor of the cs process: the ps stub reports
    # PID 1 as every process's parent, so the ancestry walk never reaches $$.
    echo "$$" > "$base_dir/.cs/session.lock"
    local ps_stub output status=0
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CLAUDE_SESSION_NAME="other" CS_PS_BIN="$ps_stub" \
        "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a foreign live base lock refuses" || return 1
    assert_output_contains "$output" "open elsewhere" "names the live base" || return 1
}

# Integrate reads the base's lock by live_lock_pid's rule: a lock of "-1",
# "0" or "+<pid>" names no running conversation, so integrate goes on: the
# base's own HEAD, which the feature branch grew from, is already landed.
test_integrate_reads_the_base_lock_by_the_one_lock_rule() {
    local base_dir
    integrate_fixture myproj fix-auth > /dev/null
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local landed
    landed=$(git -C "$base_dir" rev-parse HEAD)
    local text output status
    for text in "-1" "0" "+$$"; do
        printf '%s\n' "$text" > "$base_dir/.cs/session.lock"
        status=0
        output=$(CLAUDE_SESSION_NAME="other" \
            "$CS_BIN" myproj -integrate-feature fix-auth "$landed" -- true 2>&1) || status=$?
        assert_eq "0" "$status" "integrate over a base lock of '$text' exits 0: $output" || return 1
        assert_eq "already-integrated fix-auth $landed" "$output" \
            "a base lock of '$text' is not a live conversation" || return 1
    done
}

# A TERM'd integrate runs its cleanup from the signal handler and again from
# the EXIT trap. Between the two another integrate can take the lock, so the
# second pass must not remove a directory it no longer owns.
test_integrate_cleanup_releases_the_lock_only_once() {
    local lock="$TEST_TMPDIR/cleanup-twice/integrate.lock"
    mkdir -p "$lock"
    echo 4242 > "$lock/pid"
    ( source "$SCRIPT_DIR/../lib/30-worktree.sh"
      _INTEGRATE_LOCK="$lock"; _INTEGRATE_BASE_DIR="$TEST_TMPDIR"; _INTEGRATE_TMP=""
      _integrate_cleanup
      [ -d "$lock" ] && { echo "  FAIL: the first pass must remove the lock"; exit 1; }
      # The successor's lock, taken between the two passes.
      mkdir "$lock" && echo 9999 > "$lock/pid"
      _integrate_cleanup
      [ -d "$lock" ] || { echo "  FAIL: the second pass removed the successor's lock"; exit 1; }
    ) || return 1
}

# cs runs under set -e. A lock something else already removed makes the
# handler's rm fail; that must not abort the handler before it forgets the
# path, or the EXIT pass would remove a successor's lock.
test_integrate_cleanup_forgets_a_lock_it_could_not_remove() {
    local lock="$TEST_TMPDIR/cleanup-gone/integrate.lock"
    mkdir -p "$TEST_TMPDIR/cleanup-gone"
    ( set -e
      source "$SCRIPT_DIR/../lib/30-worktree.sh"
      _INTEGRATE_LOCK="$lock"; _INTEGRATE_BASE_DIR="$TEST_TMPDIR"; _INTEGRATE_TMP=""
      _integrate_cleanup
      [ -z "$_INTEGRATE_LOCK" ] || { echo "  FAIL: a failed rm must still forget the lock path"; exit 1; }
      mkdir "$lock" && echo 9999 > "$lock/pid"
      _integrate_cleanup
      [ -d "$lock" ] || { echo "  FAIL: the second pass removed the successor's lock"; exit 1; }
    ) || return 1
}

test_integrate_ignores_the_feature_lock() {
    # The feature session stays open: its lock is not a blocker because the
    # integrate never touches the feature worktree.
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"
    local ps_stub
    ps_stub=$(fixed_parent_ps_stub 1)
    output=$(CS_PS_BIN="$ps_stub" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds with the feature lock live: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
}

test_integrate_refuses_merge_in_progress() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # Stage a MERGE_HEAD without dirtying the tracked tree.
    git -C "$base_dir" rev-parse HEAD > "$base_dir/.git/MERGE_HEAD"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    rm -f "$base_dir/.git/MERGE_HEAD"
    assert_eq "1" "$status" "a merge in progress refuses" || return 1
    assert_output_contains "$output" "merge or rebase in progress" "names the state" || return 1
}

test_integrate_refuses_stale_mutex_and_names_it() {
    local sha base_dir
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/cs/integrate.lock"
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "an existing mutex refuses" || return 1
    assert_output_contains "$output" "$base_dir/.git/cs/integrate.lock" "the refusal names the path" || return 1
    assert_dir "$base_dir/.git/cs/integrate.lock" "the mutex is never stolen" || return 1
}

test_integrate_requires_a_gate_command() {
    local sha output status=0
    sha=$(integrate_fixture myproj fix-auth)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "missing gate argv refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage" || return 1
}

test_integrate_requires_a_sha() {
    # `set -u` would otherwise turn a missing positional into an unbound-variable
    # crash instead of the usage line.
    integrate_fixture myproj fix-auth > /dev/null
    local output status=0
    output=$("$CS_BIN" myproj -integrate-feature fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "missing sha refuses" || return 1
    assert_output_contains "$output" "Usage: cs <base> -integrate-feature" "prints usage, not a shell error" || return 1
    assert_output_not_contains "$output" "unbound variable" "no set -u crash" || return 1
}

test_integrate_is_hidden_from_completion_and_unknown_command_text() {
    grep -q '^            -integrate-feature) # hidden' "$SCRIPT_DIR/../lib/99-main.sh" \
        || { echo "  FAIL: the arm must carry '# hidden' on its own line for test_completions"; return 1; }
    assert_file_not_contains "$SCRIPT_DIR/../lib/99-main.sh" 'Unknown session command.*-integrate-feature' \
        "the unknown-command string must not advertise the entry" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../lib/10-help.sh" 'integrate-feature' "help never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/_cs" 'integrate-feature' "zsh completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../completions/cs.bash" 'integrate-feature' "bash completion never lists it" || return 1
    assert_file_not_contains "$SCRIPT_DIR/../README.md" 'integrate-feature' "README never lists it" || return 1
}

test_integrate_and_autosave_spell_one_mutex_path() {
    # The hook cannot source lib/, so the path is spelled twice; this is the
    # only thing that keeps the two spellings equal.
    assert_file_contains "$SCRIPT_DIR/../hooks/autosave-commits.sh" 'cs/integrate\.lock' "hook names the mutex" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/30-worktree.sh" 'cs/integrate\.lock' "entry names the mutex" || return 1
}

run_test test_integrate_refuses_unknown_worktree
run_test test_integrate_refuses_sha_not_on_feature_branch
run_test test_integrate_reports_already_integrated_and_does_nothing
run_test test_integrate_names_a_commit_the_base_lacks
run_test test_integrate_refuses_dirty_base
run_test test_integrate_refuses_foreign_live_base_lock
run_test test_integrate_reads_the_base_lock_by_the_one_lock_rule
run_test test_integrate_cleanup_releases_the_lock_only_once
run_test test_integrate_cleanup_forgets_a_lock_it_could_not_remove
run_test test_integrate_ignores_the_feature_lock
run_test test_integrate_refuses_merge_in_progress
run_test test_integrate_refuses_stale_mutex_and_names_it
run_test test_integrate_requires_a_gate_command
run_test test_integrate_requires_a_sha
run_test test_integrate_is_hidden_from_completion_and_unknown_command_text
run_test test_integrate_and_autosave_spell_one_mutex_path

test_integrate_lands_a_no_ff_merge_and_keeps_everything() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    assert_output_contains "$output" "integrated fix-auth $sha -> $head" "summary line names the result" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content is on base" || return 1
    assert_eq "3" "$(git -C "$base_dir" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" \
        "base HEAD is a merge commit: its sha plus two parents (--no-ff)" || return 1
    assert_dir "$wt" "the feature worktree remains" || return 1
    # rev-parse, not `branch --list`: git prefixes a branch checked out in a
    # linked worktree with `+`, so the listing never equals the bare name.
    git -C "$base_dir" rev-parse -q --verify refs/heads/cs/fix-auth >/dev/null 2>&1 \
        || { echo "  FAIL: the branch must remain"; return 1; }
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "no temp worktree left registered" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"feature-integrated"' "timeline records the integrate" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "\"sha\":\"$sha\"" "event carries the sha" || return 1
    # The merge commit names the feature: it is the only audit trail /finish leaves.
    assert_output_contains "$(git -C "$base_dir" log -1 --format=%s)" "Merge feature fix-auth" "merge subject names the feature" || return 1
}

# The load-bearing local happy path: after an integrate, today's retire verb
# takes its "already merged; cleaning up" branch and merges NOTHING. In
# tracked mode the integrate's own timeline event dirties the base (the
# timeline is tracked there), and the verb refuses dirt — so the test stages
# the general case: a tracked timeline, the refusal, the user's commit of the
# bookkeeping, then the ancestor path. Retirement semantics are unchanged.
test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt() {
    # In tracked-.cs mode the integrate's own timeline event dirties the base.
    # Retirement touches no base file, so that dirt is no reason to refuse:
    # /finish lands and retires in one run, and the bookkeeping stays the
    # user's to commit.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "the only dirt after an integrate is the tracked timeline event" || return 1
    local head_after_integrate
    head_after_integrate=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds over bookkeeping dirt: $output" || return 1
    assert_eq "$head_after_integrate" "$(git -C "$base_dir" rev-parse HEAD)" "retire makes no new commit" || return 1
    assert_eq " M .cs/timeline.jsonl" "$(git -C "$base_dir" status --porcelain)" \
        "and commits nothing on the user's behalf" || return 1
    assert_not_exists "$wt" "retire removed the worktree" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "retire deleted the branch" || return 1
}

test_retire_still_refuses_real_base_dirt() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    echo "half-typed" >> "$base_dir/CLAUDE.md"
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "a dirty base file outside .cs still refuses" || return 1
    assert_output_contains "$output" "Base session has uncommitted changes" "the refusal is the verb's own" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
}

test_integrate_red_gate_leaves_base_untouched() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    # The gate records where it ran: a red gate in the LIVE base would also
    # "leave HEAD unchanged", so location is part of what this proves.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; echo GATE-SAYS-NO; exit 3' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "a red gate refuses" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/where" 2>/dev/null)" "/cs-finish-fix-auth." "the red gate ran in the temp" || return 1
    assert_output_contains "$output" "GATE-SAYS-NO" "the gate output is shown" || return 1
    assert_output_contains "$output" "Gate failed" "names the cause" || return 1
    assert_output_contains "$output" "clean checkout" "and says the gate ran without gitignored files" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "base tree unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on failure" || return 1
}

# An untracked base file colliding with a path the feature adds must be caught
# before the gate runs at all: _tree_is_dirty only sees tracked dirt, so
# without this check the gate would run to completion and only THEN hit an
# un-diagnosable ff-only abort.
test_integrate_refuses_untracked_collision_before_the_gate() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "stale" > "$base_dir/feature.txt"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'touch "$0/marker"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "1" "$status" "an untracked collision refuses" || return 1
    assert_output_contains "$output" "feature.txt" "names the colliding path" || return 1
    assert_file_not_exists "$TEST_TMPDIR/marker" "the gate never ran" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "stale" "$(cat "$base_dir/feature.txt")" "the untracked file survives with its content" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_gates_run_in_the_temp_not_the_live_trees() {
    local sha base_dir wt output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # The gate records where it ran and proves the merged tree is there.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'pwd > "$0/where"; test -f feature.txt' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "gate saw the merged tree: $output" || return 1
    local where
    where=$(cat "$TEST_TMPDIR/where")
    assert_output_contains "$where" "/cs-finish-fix-auth." "gate ran in the temp worktree" || return 1
    # Tools refuse paths under a .git directory (Vite's server.fs.deny has
    # **/.git/**), so a gate run there fails for reasons of its location.
    assert_output_not_contains "$where" "/.git/" "the temp worktree is outside any .git directory" || return 1
    assert_output_not_contains "$where" "$wt" "gate did not run in the feature worktree" || return 1
    [ "$where" != "$base_dir" ] || { echo "  FAIL: gate ran in the live base"; return 1; }
}

test_integrate_refuses_when_base_moved_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The gate itself moves base HEAD: deterministic, no timing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" commit -q --allow-empty -m moved 2>&1) || status=$?
    assert_eq "1" "$status" "a moved base refuses" || return 1
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
    assert_eq "moved" "$(git -C "$base_dir" log -1 --format=%s)" "base keeps only its own new commit" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates() {
    # --ff-only would happily land on a base that went BACKWARDS; the explicit
    # HEAD == B check is what refuses it.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "will be reset away")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" reset -q --hard HEAD~1 2>&1) || status=$?
    assert_eq "1" "$status" "a base reset during gates refuses" || return 1
    assert_output_contains "$output" "moved during the gates" "names the cause" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_when_base_dirtied_during_gates() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo edit >> "$0/CLAUDE.md"' "$base_dir" 2>&1) || status=$?
    assert_eq "1" "$status" "dirt introduced during gates refuses" || return 1
    assert_output_contains "$output" "changed during the gates" "names the cause" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

test_integrate_terminated_mid_gate_leaves_no_lock_or_temp() {
    # TERM during the gate must still release the mutex and remove the temp:
    # a plain EXIT trap does not fire on TERM. Bash exec-optimizes the last
    # command of `(cd "$tmp" && "$@")`, so the gate's PPID is cs itself, not
    # a subshell one level down — walk up while the ancestor's argv still
    # names -integrate-feature and terminate the topmost one, which lands on
    # cs under either fork shape.
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # The marker is written only after the gate has SEEN the mutex held, so a
    # run that never took the lock (or never reached the gate) cannot pass the
    # release assertions below by never having acquired anything. A private
    # TMPDIR holds the gate's output log, so a leftover is this run's alone.
    local gate_tmp="$TEST_TMPDIR/gate-tmpdir"
    mkdir -p "$gate_tmp"
    output=$(TMPDIR="$gate_tmp" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c '
        test -d "$0" || exit 9
        : > "$1"
        target=""; p=$PPID
        while [ "${p:-1}" -gt 1 ]; do
            case "$(ps -o args= -p "$p" 2>/dev/null)" in
                *" -integrate-feature "*) target=$p ;;
                *) break ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
        done
        kill -TERM "$target"; sleep 2
    ' "$base_dir/.git/cs/integrate.lock" "$TEST_TMPDIR/gate-ran" 2>&1) || status=$?
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_file_exists "$TEST_TMPDIR/gate-ran" "the gate ran with the mutex held" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released on TERM" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed on TERM" || return 1
    assert_eq "" "$(ls "$gate_tmp")" "nothing left in TMPDIR on TERM, the gate log included" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

# A gate log or a temp worktree the cleanup cannot remove (macOS's user
# immutable flag) must not stop the cleanup: the mutex is still released, so
# the next integrate runs.
test_integrate_terminated_mid_gate_releases_the_lock_when_its_files_stay() {
    require_tool chflags || return $?
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    local gate_tmp="$TEST_TMPDIR/gate-tmpdir"
    mkdir -p "$gate_tmp"
    output=$(TMPDIR="$gate_tmp" "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c '
        test -d "$0" || exit 9
        chflags uchg "$TMPDIR"/cs-gate.* || exit 8
        : > kept && chflags uchg kept || exit 7
        : > "$1"
        target=""; p=$PPID
        while [ "${p:-1}" -gt 1 ]; do
            case "$(ps -o args= -p "$p" 2>/dev/null)" in
                *" -integrate-feature "*) target=$p ;;
                *) break ;;
            esac
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " ")
        done
        kill -TERM "$target"; sleep 2
    ' "$base_dir/.git/cs/integrate.lock" "$TEST_TMPDIR/gate-ran" 2>&1) || status=$?
    chflags -R nouchg "$gate_tmp" 2>/dev/null || :
    [ "$status" != 0 ] || { echo "  FAIL: a terminated integrate must not exit 0"; return 1; }
    assert_file_exists "$TEST_TMPDIR/gate-ran" "the gate ran with the mutex held and its log immutable" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released although the gate log and the temp worktree stay" || return 1
}

test_integrate_conflict_names_the_path_and_leaves_no_merge_head() {
    local base_dir wt sha output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    local head
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "a conflict refuses" || return 1
    assert_output_contains "$output" "shared.txt" "names the conflicting path" || return 1
    assert_output_contains "$output" "git merge $(git -C "$base_dir" symbolic-ref --short HEAD) in $wt" \
        "the advice names the base's real branch and the worktree to run it in" || return 1
    assert_file_not_exists "$base_dir/.git/MERGE_HEAD" "no MERGE_HEAD in the base" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
}

test_integrate_ignored_mode_fuses_nothing() {
    # Ignored mode: the feature's .cs/ never rides the merge and /finish fuses
    # no records (retire does). The base timeline must gain exactly one event.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# readme" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo '{"ts":"2026-01-01T00:00:00Z","event":"task","note":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    echo "work" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m work)
    local sha
    sha=$(git -C "$wt" rev-parse HEAD)
    "$CS_BIN" proj -integrate-feature t1 "$sha" -- true >/dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    assert_file_exists "$base_dir/result.txt" "code landed" || return 1
    assert_file_not_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature records are not fused by integrate" || return 1
    assert_dir "$wt/.cs" "feature .cs untouched" || return 1
}

test_integrate_tracked_mode_warns_on_memory_index_change() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "- [x](x.md) — feature-side pointer" >> "$wt/.cs/memory/MEMORY.md"
    (cd "$wt" && git add .cs/memory/MEMORY.md && git commit -q -m "index")
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_output_contains "$output" "MEMORY.md changed on $sha" "merge=ours drop is announced" || return 1
}

test_integrate_tracked_mode_union_merges_shared_records() {
    # Both sides append to the tracked timeline; the verb's merge policy
    # (merge=union) must reach the temp worktree or this conflicts.
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '{"ts":"2026-01-02T00:00:00Z","event":"feature-side"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add .cs/timeline.jsonl && git commit -q -m "feature event")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo '{"ts":"2026-01-03T00:00:00Z","event":"base-side"}' >> "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m "base event")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "union merge lands: $output" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "feature-side" "feature line kept" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "base-side" "base line kept" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .gitattributes)" "no tree is dirtied to get the policy" || return 1
}

# The base's own landing is the one merge cs does NOT run with hooks
# suppressed: it is the user's checkout and their post-merge hook is entitled
# to fire. A hook that commits leaves base past the commit cs just landed, so
# the summary must name where the base actually ended up.
test_integrate_survives_a_base_post_merge_hook_that_commits() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$base_dir/.git/hooks"
    cat > "$base_dir/.git/hooks/post-merge" << 'HOOK'
#!/usr/bin/env bash
git commit -q --allow-empty -m "post-merge bookkeeping"
HOOK
    chmod +x "$base_dir/.git/hooks/post-merge"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "a landing whose hook commits still succeeds: $output" || return 1
    assert_eq "post-merge bookkeeping" "$(git -C "$base_dir" log -1 --format=%s)" "the hook's commit is the base tip" || return 1
    assert_output_contains "$output" "post-merge hook moved" "the hook's move is announced" || return 1
    assert_output_contains "$output" "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" \
        "the summary names the head the base really has" || return 1
    assert_file_exists "$base_dir/feature.txt" "the feature still landed" || return 1
}

run_test test_integrate_lands_a_no_ff_merge_and_keeps_everything
# The gate runs the project's build, and a build that writes into the tree
# would otherwise land content nobody reviewed: what cs fast-forwards the base
# onto is the merge commit, so a gate-written file either vanishes or, once
# committed by the gate, rides in unseen. Refuse instead.
test_integrate_refuses_a_gate_that_writes_into_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo stale > CLAUDE.md' 2>&1) || status=$?
    assert_eq "1" "$status" "a tree-writing gate refuses" || return 1
    assert_output_contains "$output" "CLAUDE.md" "names the path the gate changed" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_output_not_contains "$(git -C "$base_dir" worktree list)" "cs-finish-" "temp worktree removed" || return 1
    assert_not_exists "$base_dir/.git/cs/integrate.lock" "mutex released" || return 1
}

test_integrate_refuses_a_gate_that_commits_in_the_temp() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    # A real commit: `git add . && git commit` with nothing changed exits 1 and
    # would be caught as a red gate instead, proving nothing.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo generated > built.txt && git add . && git commit -q -m gate-made' 2>&1) || status=$?
    assert_eq "1" "$status" "a committing gate refuses" || return 1
    assert_output_not_contains "$output" "Gate failed" "the gate itself was green; this is the tamper refusal" || return 1
    assert_output_contains "$output" "re-run /finish fix-auth" "names the next command" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
}

test_integrate_refuses_a_gate_that_moves_the_temp_head() {
    local sha base_dir head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    head=$(git -C "$base_dir" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git checkout -q "$head" 2>&1) || status=$?
    assert_eq "1" "$status" "a gate that moves the temp HEAD refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_output_not_contains "$output" "integrated fix-auth" "no summary line" || return 1
    assert_file_not_exists "$base_dir/feature.txt" "nothing landed" || return 1
}

run_test test_integrate_survives_a_base_post_merge_hook_that_commits
run_test test_integrate_refuses_a_gate_that_writes_into_the_temp
run_test test_integrate_refuses_a_gate_that_commits_in_the_temp
# A detached base has no branch to land on: the ff-only would move a
# detached HEAD and leave the branch behind. The refusal belongs before the
# local/PR split, so both paths get it.
test_integrate_refuses_a_detached_base() {
    local sha base_dir branch head output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    head=$(git -C "$base_dir" rev-parse HEAD)
    git -C "$base_dir" checkout -q --detach
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "1" "$status" "the local path refuses a detached base" || return 1
    assert_output_contains "$output" "Base checkout is detached" "names the state" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse "$branch")" "the branch is unmoved" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "HEAD is unmoved" || return 1
}

run_test test_integrate_refuses_a_gate_that_moves_the_temp_head
run_test test_integrate_refuses_a_detached_base
run_test test_integrate_tracked_mode_union_merges_shared_records
run_test test_integrate_then_retire_tolerates_tracked_bookkeeping_dirt
run_test test_retire_still_refuses_real_base_dirt
run_test test_integrate_red_gate_leaves_base_untouched
run_test test_integrate_refuses_untracked_collision_before_the_gate
run_test test_integrate_gates_run_in_the_temp_not_the_live_trees
run_test test_integrate_refuses_when_base_moved_during_gates
run_test test_integrate_refuses_when_base_reset_to_an_ancestor_during_gates
run_test test_integrate_refuses_when_base_dirtied_during_gates
run_test test_integrate_terminated_mid_gate_leaves_no_lock_or_temp
run_test test_integrate_terminated_mid_gate_releases_the_lock_when_its_files_stay
run_test test_integrate_conflict_names_the_path_and_leaves_no_merge_head
run_test test_integrate_ignored_mode_fuses_nothing
run_test test_integrate_tracked_mode_warns_on_memory_index_change

# The feature's tree lands in the base before cs writes the base's timeline
# event, and nothing scanned the base since it opened: a link the feature
# committed at .cs/timeline.jsonl would carry that write out of the session.
test_integrate_and_retire_never_write_through_a_landed_timeline_link() {
    local sha base_dir wt output status=0 outside="$TEST_TMPDIR/outside-timeline"
    local outside_p
    base_dir=$(create_test_session_with_git "myproj")
    echo '{"ts":"2026-01-01T00:00:00Z","event":"seed"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git add .cs/timeline.jsonl && git commit -q -m seed)
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    printf 'outside\n' > "$outside"
    outside_p="$(cd "$TEST_TMPDIR" && pwd -P)/outside-timeline"
    (cd "$wt" && rm .cs/timeline.jsonl && ln -s "$outside" .cs/timeline.jsonl \
        && git add .cs/timeline.jsonl && git commit -q -m "link the timeline out")
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "the landing itself succeeds: $output" || return 1
    assert_symlink "$base_dir/.cs/timeline.jsonl" "the feature's link landed in the base" || return 1
    assert_output_contains "$output" "timeline.jsonl leads to $outside_p" "the refusal names the link" || return 1
    assert_eq "outside" "$(cat "$outside")" "integrate wrote nothing outside the session" || return 1
    status=0
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire itself succeeds: $output" || return 1
    assert_output_contains "$output" "timeline.jsonl leads to $outside_p" "the retire names the link too" || return 1
    assert_eq "outside" "$(cat "$outside")" "retire wrote nothing outside the session" || return 1
}

run_test test_integrate_and_retire_never_write_through_a_landed_timeline_link

# A feature can commit MEMORY.md as a link whose target text reads as a
# pointer line. The merge installs the link in the temp checkout, and the
# pointer carryover then appended that line through it.
test_integrate_never_appends_memory_pointers_through_a_committed_index_link() {
    local sha base_dir wt output status=0 outside
    # Enough levels to climb to / from any temp checkout.
    local up="../../../../../../../../../../../../../../../../../../../../../../../../"
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    outside="$(cd "$TEST_TMPDIR" && pwd -P)/outside-index"
    printf 'outside\n' > "$outside"
    (cd "$wt/.cs/memory" && printf 'topic\n' > x.md && mkdir -- '- [X](x.md)' && : > '- [X](x.md)/.keep' \
        && rm -f MEMORY.md && ln -s -- "- [X](x.md)/$up${outside#/}" MEMORY.md \
        && git add -A . && git commit -q -m "link the index out")
    assert_eq "outside" "$(cat "$wt/.cs/memory/MEMORY.md")" "the fixture's link reaches the outside file" || return 1
    sha=$(git -C "$wt" rev-parse HEAD)
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "outside" "$(cat "$outside")" "nothing was appended outside the session" || return 1
    assert_eq "1" "$status" "the integrate refuses: $output" || return 1
    assert_output_contains "$output" "MEMORY.md leads to $outside" "the refusal names the link" || return 1
}

run_test test_integrate_never_appends_memory_pointers_through_a_committed_index_link

# Ignored mode: git overwrites the base's ignored timeline with a link the
# feature force-added, and retire then has the worktree's own timeline to
# fuse into the base. It refuses before removing anything, naming the record.
test_retire_never_fuses_records_through_a_landed_timeline_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt sha output status=0 outside
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# readme" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    wt="$CS_SESSIONS_ROOT/proj@t1"
    outside="$(cd "$TEST_TMPDIR" && pwd -P)/outside-fuse"
    printf 'outside\n' > "$outside"
    (cd "$wt" && rm -f .cs/timeline.jsonl && ln -s "$outside" .cs/timeline.jsonl \
        && git add -f .cs/timeline.jsonl && git commit -q -m "link the timeline out")
    sha=$(git -C "$wt" rev-parse HEAD)
    git -C "$wt" checkout -q --detach HEAD~1
    echo '{"ts":"2026-01-01T00:00:00Z","event":"task","note":"feature-side"}' > "$wt/.cs/timeline.jsonl"
    "$CS_BIN" proj -integrate-feature t1 "$sha" -- true >/dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    assert_symlink "$base_dir/.cs/timeline.jsonl" "the feature's link landed over the base's ignored timeline" || return 1
    output=$("$CS_BIN" proj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "outside" "$(cat "$outside")" "the fuse wrote nothing outside the session" || return 1
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs" "nothing was removed: $output" || return 1
    assert_eq ".cs/timeline.jsonl" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the timeline" || return 1
    assert_file_contains "$wt/.cs/timeline.jsonl" "feature-side" "the worktree keeps its timeline" || return 1
}

run_test test_retire_never_fuses_records_through_a_landed_timeline_link

# A feature can commit .cs itself as a link. Once it lands, the base's whole
# metadata directory is that link, and the retire's progress record must not
# create its directory on the far side.
test_retire_never_creates_the_progress_directory_through_a_landed_cs_link() {
    local sha base_dir wt output status=0 outside="$TEST_TMPDIR/outside-cs"
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    mkdir "$outside"
    (cd "$wt" && git rm -rq --cached .cs && mv .cs "$TEST_TMPDIR/feature-cs" && ln -s "$outside" .cs \
        && git add .cs && git commit -q -m "link the metadata out")
    sha=$(git -C "$wt" rev-parse HEAD)
    rm "$wt/.cs" && git -C "$wt" checkout -q --detach HEAD~1 \
        && cp -R "$TEST_TMPDIR/feature-cs/local" "$wt/.cs/local" \
        || { echo "  FAIL: could not put the worktree's own .cs back"; return 1; }
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the worktree is clean at the parent commit" || return 1
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "the landing itself succeeds: $output" || return 1
    assert_symlink "$base_dir/.cs" "the feature's link landed in the base" || return 1
    assert_eq "" "$(ls -A "$outside")" "integrate created nothing outside the session" || return 1
    status=0
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "" "$(ls -A "$outside")" "retire created nothing outside the session" || return 1
    assert_eq "0" "$status" "the retire itself succeeds: $output" || return 1
    assert_output_contains "$output" "/finish progress not recorded" "the unrecorded run is named" || return 1
}

run_test test_retire_never_creates_the_progress_directory_through_a_landed_cs_link

# merge=ours keeps the base's MEMORY.md, but a pointer to a topic only the
# feature wrote must still reach the base: appended once, after the base's
# own lines, and a pointer both sides name is not doubled.
test_integrate_tracked_mode_appends_feature_memory_pointers() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [A](a.md): base wording' > "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git add .cs/memory/MEMORY.md && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    printf '%s\n' '- [A](a.md): feature wording' '- [X](x.md): feature-side' '- [X again](x.md): duplicate' \
        > "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "index")
    sha=$(git -C "$wt" rev-parse HEAD)
    printf '%s\n' '- [B](b.md): base-side' >> "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git add .cs/memory/MEMORY.md && git commit -q -m "base pointer")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_eq "- [A](a.md): base wording
- [B](b.md): base-side
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "base index kept, the feature's new pointer appended once" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .cs/memory)" \
        "the appended pointer is committed, not left as dirt" || return 1
}

run_test test_integrate_tracked_mode_appends_feature_memory_pointers

# A topic the base deleted after the feature branched stays deleted: the merge
# drops the file, and the feature's old pointer to it is not appended back.
test_integrate_tracked_mode_skips_pointers_to_base_deleted_topics() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [A](a.md): base' '- [T](t.md): old topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "t topic" > "$base_dir/.cs/memory/t.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '- [X](x.md): feature-side' >> "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "feature topic")
    sha=$(git -C "$wt" rev-parse HEAD)
    printf '%s\n' '- [A](a.md): base' > "$base_dir/.cs/memory/MEMORY.md"
    (cd "$base_dir" && git rm -q .cs/memory/t.md && git add .cs/memory/MEMORY.md && git commit -q -m "drop topic t")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_not_exists "$base_dir/.cs/memory/t.md" "the base's deletion of t.md stands" || return 1
    assert_eq "- [A](a.md): base
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "no pointer to the deleted topic comes back; the new one is appended" || return 1
}

run_test test_integrate_tracked_mode_skips_pointers_to_base_deleted_topics

# Writes the memory archive at <memory_dir>: a reference entry whose body is
# the given pointer lines.
_write_memory_archive() {  # memory_dir pointer-line...
    local dir="$1"
    shift
    { printf -- '---\nname: memory-archive\ndescription: "Pointers moved out of MEMORY.md"\nmetadata:\n  type: reference\n---\n\n'
      printf '%s\n' "$@"; } > "$dir/reference_memory_archive.md"
}

# A pointer the base moved from MEMORY.md into its archive after the feature
# branched is still in the feature's index; it is indexed in the base, and
# the merge does not bring it back into MEMORY.md.
test_integrate_tracked_mode_keeps_a_pointer_the_base_archived_out_of_the_index() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [A](a.md): base' '- [P](p.md): a closed study' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '- [X](x.md): feature-side' >> "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "feature topic")
    sha=$(git -C "$wt" rev-parse HEAD)
    printf '%s\n' '- [A](a.md): base' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        > "$base_dir/.cs/memory/MEMORY.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [P](p.md): a closed study'
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "archive P")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_eq "- [A](a.md): base
- [Memory archive](reference_memory_archive.md): moved pointers
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "the archived pointer stays out of MEMORY.md; the feature's new one is appended" || return 1
}

run_test test_integrate_tracked_mode_keeps_a_pointer_the_base_archived_out_of_the_index

# Base and feature each move a different pointer into the archive: both
# appends land, as they do for the timeline and the narratives, and no tree
# is dirtied to get that.
test_integrate_tracked_mode_union_merges_the_memory_archive() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        '- [P](p.md): p' '- [Q](q.md): q' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "q topic" > "$base_dir/.cs/memory/q.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier'
    echo "old topic" > "$base_dir/.cs/memory/old.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base index")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '- [Q](q.md): q' >> "$wt/.cs/memory/reference_memory_archive.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "feature archives Q")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo '- [P](p.md): p' >> "$base_dir/.cs/memory/reference_memory_archive.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base archives P")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "both archive appends merge: $output" || return 1
    assert_eq "- [Old](old.md): archived earlier
- [P](p.md): p
- [Q](q.md): q" "$(grep '^- ' "$base_dir/.cs/memory/reference_memory_archive.md")" \
        "the archive keeps the base's and the feature's pointers" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .gitattributes)" "no tree is dirtied to get the policy" || return 1
}

run_test test_integrate_tracked_mode_union_merges_the_memory_archive

# The clone-local attributes file can end with no newline (a hand edit); the
# line cs appends to it still starts a line of its own, so the archive
# union-merges.
test_integrate_tracked_mode_union_merges_the_archive_after_attributes_with_no_final_newline() {
    local sha base_dir wt output status=0
    base_dir=$(create_test_session_with_git "myproj")
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        '- [P](p.md): p' '- [Q](q.md): q' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "q topic" > "$base_dir/.cs/memory/q.md"
    _write_memory_archive "$base_dir/.cs/memory"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base index")
    mkdir -p "$base_dir/.git/info"
    printf '%s\n%s\n%s' '.cs/memory/MEMORY.md merge=ours' '.cs/timeline.jsonl merge=union' \
        '.cs/memory/narrative.*.md merge=union' > "$base_dir/.git/info/attributes"
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo '- [Q](q.md): q' >> "$wt/.cs/memory/reference_memory_archive.md"
    (cd "$wt" && git add .cs/memory && git commit -q -m "feature archives Q")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo '- [P](p.md): p' >> "$base_dir/.cs/memory/reference_memory_archive.md"
    (cd "$base_dir" && git add .cs/memory && git commit -q -m "base archives P")
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "both archive appends merge: $output" || return 1
    assert_eq "- [P](p.md): p
- [Q](q.md): q" "$(grep '^- ' "$base_dir/.cs/memory/reference_memory_archive.md")" \
        "the archive keeps the base's and the feature's pointers" || return 1
}

run_test test_integrate_tracked_mode_union_merges_the_archive_after_attributes_with_no_final_newline

test_retire_ignored_mode_fuses_records() {
    local base_dir="$CS_SESSIONS_ROOT/proj" esc="esc"$'\033'"[31m.md"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "base note" > "$base_dir/.cs/memory/note-base.md"
    echo "esc note" > "$base_dir/.cs/memory/$esc"
    echo "shared note" > "$base_dir/.cs/memory/note-shared.md"
    printf -- '---\ndescription: seed\n---\n# Session narrative (tester)\n\n## Prior finding\n' \
        > "$base_dir/.cs/memory/narrative.tester.md"
    printf -- '---\ndescription: plain-seed\n---\n# Session narrative (plain)\n' \
        > "$base_dir/.cs/memory/narrative.plain.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    # A global autocrlf would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    # Task work: code (committed) + session records (untracked .cs)
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo '{"event":"from-task"}' >> "$wt/.cs/timeline.jsonl"
    echo "task memory" > "$wt/.cs/memory/note-task.md"
    printf -- '---\nname: n\n---\n# Session narrative (tester)\n\n## Task finding\n\n---\n\n## After rule\n' \
        > "$wt/.cs/memory/narrative.tester.md"
    printf -- '---\nname: other-n\n---\n# Session narrative (other)\n\n## Other finding\n' \
        > "$wt/.cs/memory/narrative.other.md"
    printf -- '# Session narrative (plain)\n\n## Plain finding\n' \
        > "$wt/.cs/memory/narrative.plain.md"
    echo "task version" > "$wt/.cs/memory/note-base.md"
    echo "esc task version" > "$wt/.cs/memory/$esc"
    echo "shared note" > "$wt/.cs/memory/note-shared.md"
    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }
    assert_output_contains "$output" "memory/note-base.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "an inherited topic the feature edited is named" || return 1
    assert_eq "memory/esc?[31m.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "$(printf '%s\n' "$output" | grep -F 'memory/esc')" "a control character in the topic's name shows as ?" || return 1
    assert_output_not_contains "$output" "note-shared.md" \
        "a topic byte-identical to the base's is skipped silently" || return 1
    assert_eq "task version" "$(cat "$base_dir/.cs/memory/note-base.md")" \
        "the feature's edit replaces the copy the base left unchanged" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "from-task" "timeline appended" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-task.md" "memory file copied" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-base.md" "base memory untouched" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "Task finding" "narrative body appended" || return 1
    assert_file_not_contains "$base_dir/.cs/memory/narrative.tester.md" "name: n" "frontmatter not duplicated" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "description: seed" "base frontmatter kept" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "After rule" \
        "body after horizontal rule survives" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "Plain finding" \
        "no-frontmatter body appended" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "description: plain-seed" \
        "plain base frontmatter kept" || return 1
    assert_file_exists "$base_dir/.cs/memory/narrative.other.md" "unseen narrative copied" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.other.md" "name: other-n" "first copy keeps frontmatter" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_file_exists "$base_dir/result.txt" "code landed by the integrate" || return 1
}

run_test test_retire_ignored_mode_fuses_records

# The repo does not track .cs/, so git gives the feature none of the base's
# context: cs copies the memory topics, the index, plans/ and summary.md.
# Never a narrative (the feature writes its own), .cs/local, or the timeline.
test_worktree_create_ignored_mode_copies_base_context() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local,plans}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "topic body" > "$base_dir/.cs/memory/topic.md"
    printf '%s\n' '- [Topic](topic.md): base pointer' > "$base_dir/.cs/memory/MEMORY.md"
    echo "base narrative" > "$base_dir/.cs/memory/narrative.other.md"
    echo "plan body" > "$base_dir/.cs/plans/plan-a.md"
    echo "summary body" > "$base_dir/.cs/summary.md"
    echo "base-only" > "$base_dir/.cs/local/marker"
    echo '{"event":"base-only"}' > "$base_dir/.cs/timeline.jsonl"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "topic body" "$(cat "$wt/.cs/memory/topic.md" 2>/dev/null)" "topic copied" || return 1
    assert_eq "- [Topic](topic.md): base pointer" "$(head -1 "$wt/.cs/memory/MEMORY.md" 2>/dev/null)" \
        "index copied with the base's lines first" || return 1
    assert_eq "plan body" "$(cat "$wt/.cs/plans/plan-a.md" 2>/dev/null)" "plans copied" || return 1
    assert_eq "summary body" "$(cat "$wt/.cs/summary.md" 2>/dev/null)" "summary copied" || return 1
    assert_not_exists "$wt/.cs/memory/narrative.other.md" "a narrative is never copied" || return 1
    assert_not_exists "$wt/.cs/local/marker" ".cs/local is never copied" || return 1
    assert_file_not_contains "$wt/.cs/timeline.jsonl" "base-only" "the timeline is never copied" || return 1
}

run_test test_worktree_create_ignored_mode_copies_base_context

# plans/ is copied file by file: a regular file at any depth comes over, a
# link inside plans/ (to a file or a dir, such as another session's plans)
# does not, neither as its target's content nor as the link.
test_worktree_create_ignored_mode_copies_no_plan_links() {
    local base_dir="$CS_SESSIONS_ROOT/proj" other="$CS_SESSIONS_ROOT/other/.cs/plans"
    mkdir -p "$base_dir/.cs"/{memory,local,plans/sub} "$other/deep"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "nested body" > "$base_dir/.cs/plans/sub/plan-b.md"
    echo "other plan" > "$other/secret.md"
    echo "other deep" > "$other/deep/deep.md"
    ln -s "$other/secret.md" "$base_dir/.cs/plans/linked.md"
    ln -s "$other/deep" "$base_dir/.cs/plans/sub/linkdir"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "nested body" "$(cat "$wt/.cs/plans/sub/plan-b.md" 2>/dev/null)" "a nested plan is copied" || return 1
    assert_eq "sub" "$(ls -A "$wt/.cs/plans")" "plans/ holds no link" || return 1
    assert_eq "plan-b.md" "$(ls -A "$wt/.cs/plans/sub")" "plans/sub holds no link" || return 1
}

run_test test_worktree_create_ignored_mode_copies_no_plan_links

# A plan under a directory whose name starts with a dash, or ends in a
# newline, is a regular file like any other and comes over to the feature.
test_worktree_create_ignored_mode_copies_plans_under_odd_dir_names() {
    local base_dir="$CS_SESSIONS_ROOT/proj" nl_dir
    nl_dir="$(printf 'tail\n_')"; nl_dir="${nl_dir%_}"
    mkdir -p "$base_dir/.cs"/{memory,local} "$base_dir/.cs/plans/-sub" "$base_dir/.cs/plans/$nl_dir"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    echo "dash body" > "$base_dir/.cs/plans/-sub/plan.md"
    echo "newline body" > "$base_dir/.cs/plans/$nl_dir/plan.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "dash body" "$(cat "$wt/.cs/plans/-sub/plan.md" 2>/dev/null)" "a plan under -sub/ is copied" || return 1
    assert_eq "newline body" "$(cat "$wt/.cs/plans/$nl_dir/plan.md" 2>/dev/null)" \
        "a plan under a dir ending in a newline is copied" || return 1
}

run_test test_worktree_create_ignored_mode_copies_plans_under_odd_dir_names

# Ignored mode keeps the base's MEMORY.md too, and appends each feature
# pointer whose target the base index does not name.
test_retire_ignored_mode_appends_feature_memory_pointers() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [A](a.md): base wording' > "$base_dir/.cs/memory/MEMORY.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '%s\n' '- [A](a.md): feature wording' '- [X](x.md): feature-side' > "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq "- [A](a.md): base wording
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "base index kept, the feature's new pointer appended" || return 1
}

run_test test_retire_ignored_mode_appends_feature_memory_pointers

# Ignored mode reads the base's archive too: a pointer the base moved there
# while the feature was open does not come back into MEMORY.md.
test_retire_ignored_mode_keeps_a_pointer_the_base_archived_out_of_the_index() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [A](a.md): base' '- [P](p.md): a closed study' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '%s\n' '- [A](a.md): base' '- [P](p.md): a closed study' '- [X](x.md): feature-side' \
        > "$wt/.cs/memory/MEMORY.md"
    echo "x topic" > "$wt/.cs/memory/x.md"
    printf '%s\n' '- [A](a.md): base' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        > "$base_dir/.cs/memory/MEMORY.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [P](p.md): a closed study'
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq "- [A](a.md): base
- [Memory archive](reference_memory_archive.md): moved pointers
- [X](x.md): feature-side" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "the archived pointer stays out of MEMORY.md; the feature's new one is appended" || return 1
}

run_test test_retire_ignored_mode_keeps_a_pointer_the_base_archived_out_of_the_index

# Base and feature each move a different pointer into the archive they both
# started from: the retire keeps the base's archive and appends the feature's
# pointer, so each lands once, as the union merge gives a tracked session.
test_retire_ignored_mode_merges_the_memory_archive() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        '- [P](p.md): p' '- [Q](q.md): q' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "q topic" > "$base_dir/.cs/memory/q.md"
    echo "old topic" > "$base_dir/.cs/memory/old.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier'
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' '- [P](p.md): p' \
        > "$wt/.cs/memory/MEMORY.md"
    echo '- [Q](q.md): q' >> "$wt/.cs/memory/reference_memory_archive.md"
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' '- [Q](q.md): q' \
        > "$base_dir/.cs/memory/MEMORY.md"
    echo '- [P](p.md): p' >> "$base_dir/.cs/memory/reference_memory_archive.md"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq '---
name: memory-archive
description: "Pointers moved out of MEMORY.md"
metadata:
  type: reference
---

- [Old](old.md): archived earlier
- [P](p.md): p
- [Q](q.md): q' "$(cat "$base_dir/.cs/memory/reference_memory_archive.md")" \
        "the base's archive, frontmatter and lines, gains the feature's pointer once" || return 1
    assert_output_contains "$output" "reference_memory_archive.md: appended 1 pointer(s) from the feature (base lines kept)" \
        "the retire says what it appended" || return 1
    assert_eq "- [Memory archive](reference_memory_archive.md): moved pointers
- [Q](q.md): q" "$(cat "$base_dir/.cs/memory/MEMORY.md")" \
        "the base index is kept; the pointer the base archived stays out" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
}

run_test test_retire_ignored_mode_merges_the_memory_archive

# A base with no archive takes the feature's whole, frontmatter and all.
test_retire_ignored_mode_carries_a_memory_archive_the_base_lacks() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [A](a.md): a' '- [P](p.md): p' > "$base_dir/.cs/memory/MEMORY.md"
    echo "a topic" > "$base_dir/.cs/memory/a.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '%s\n' '- [A](a.md): a' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        > "$wt/.cs/memory/MEMORY.md"
    _write_memory_archive "$wt/.cs/memory" '- [P](p.md): p'
    cp "$wt/.cs/memory/reference_memory_archive.md" "$TEST_TMPDIR/feature-archive"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    cmp -s "$TEST_TMPDIR/feature-archive" "$base_dir/.cs/memory/reference_memory_archive.md" \
        || { echo "  FAIL: the base gets the feature's archive byte for byte"; return 1; }
    assert_not_exists "$wt" "worktree removed" || return 1
}

run_test test_retire_ignored_mode_carries_a_memory_archive_the_base_lacks

# The base resolves a duplicate: by deleting the archive's copy while the
# feature leaves the archive it was handed as it was: the retire leaves the
# base's archive as it is, so the deleted line stays deleted.
test_retire_ignored_mode_keeps_a_line_the_base_deleted_from_an_archive_the_feature_left() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        '- [P](p.md): p' > "$base_dir/.cs/memory/MEMORY.md"
    echo "p topic" > "$base_dir/.cs/memory/p.md"
    echo "old topic" > "$base_dir/.cs/memory/old.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier' '- [P](p.md): p'
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier'
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq '---
name: memory-archive
description: "Pointers moved out of MEMORY.md"
metadata:
  type: reference
---

- [Old](old.md): archived earlier' "$(cat "$base_dir/.cs/memory/reference_memory_archive.md")" \
        "the base's archive keeps the line it deleted out" || return 1
    assert_output_not_contains "$output" "reference_memory_archive.md: appended" \
        "the retire appends nothing to the archive" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
}

run_test test_retire_ignored_mode_keeps_a_line_the_base_deleted_from_an_archive_the_feature_left

# A base that deleted its archive while the feature left the copy it was
# handed as it was stays without one, as for any other file the feature left.
test_retire_ignored_mode_leaves_an_archive_the_base_deleted_and_the_feature_left_deleted() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        > "$base_dir/.cs/memory/MEMORY.md"
    echo "old topic" > "$base_dir/.cs/memory/old.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier'
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    rm "$base_dir/.cs/memory/reference_memory_archive.md"
    printf '%s\n' '- [Old](old.md): archived earlier' > "$base_dir/.cs/memory/MEMORY.md"
    local sha output status=0
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_not_exists "$base_dir/.cs/memory/reference_memory_archive.md" \
        "the archive the base deleted stays deleted" || return 1
    assert_file_not_contains "$base_dir/.cs/memory/MEMORY.md" 'reference_memory_archive\.md' \
        "the base index gains no pointer to an archive it does not have" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
}

run_test test_retire_ignored_mode_leaves_an_archive_the_base_deleted_and_the_feature_left_deleted

# The fuse reads the record of the archive the feature was handed to tell
# whether the feature changed it. A record that cannot be read refuses the
# retire before the worktree is removed, as for any other inherited file.
test_retire_ignored_mode_refuses_when_the_archive_record_cannot_be_read() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local record="$wt/.cs/local/inherited-topics/reference_memory_archive.md"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Memory archive](reference_memory_archive.md): moved pointers' \
        > "$base_dir/.cs/memory/MEMORY.md"
    echo "old topic" > "$base_dir/.cs/memory/old.md"
    _write_memory_archive "$base_dir/.cs/memory" '- [Old](old.md): archived earlier'
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 000 "$record"
    [ ! -r "$record" ] || return 77
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    find "$CS_SESSIONS_ROOT" -path '*/local/inherited-topics/*' -type f -exec chmod 600 {} + 2>/dev/null
    assert_eq "1" "$status" "the retire fails: $output" || return 1
    assert_output_contains "$output" "could not read what the feature inherited for memory/reference_memory_archive.md" \
        "the error names the archive" || return 1
    assert_output_contains "$output" "Could not classify the session records in $wt/.cs; nothing was removed" \
        "the retire refuses before it removes anything" || return 1
    assert_dir "$wt/.cs/memory" "the worktree and its records are still there" || return 1
}

run_test test_retire_ignored_mode_refuses_when_the_archive_record_cannot_be_read

# An ignored-mode feature starts with a copy of the base's topics. One the
# base deleted while the feature was open, and the feature never touched, is
# not a topic the feature wrote: the fuse leaves it deleted, pointer and all.
_ignored_base_with_two_topics() {  # prints nothing; base at $CS_SESSIONS_ROOT/proj
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Gone](gone.md): a topic' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "gone topic" > "$base_dir/.cs/memory/gone.md"
    echo "kept topic" > "$base_dir/.cs/memory/kept.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
}

test_retire_ignored_mode_leaves_a_base_deleted_topic_deleted() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local odd=$'gone\nagain.md'
    _ignored_base_with_two_topics
    echo "odd topic" > "$base_dir/.cs/memory/$odd"
    cs_launch "proj@t1"
    assert_eq "gone topic" "$(cat "$wt/.cs/memory/gone.md")" "the feature inherited the topic" || return 1
    assert_eq "odd topic" "$(cat "$wt/.cs/memory/$odd")" "and the one with a newline in its name" || return 1
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "feature topic" > "$wt/.cs/memory/new.md"
    printf '%s\n' '- [New](new.md): feature-side' >> "$wt/.cs/memory/MEMORY.md"
    rm "$base_dir/.cs/memory/gone.md" "$base_dir/.cs/memory/$odd"
    printf '%s\n' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/gone.md" "the deleted topic stays deleted" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/$odd" "whatever its name holds" || return 1
    assert_eq "feature topic" "$(cat "$base_dir/.cs/memory/new.md")" "a topic the feature wrote still lands" || return 1
    assert_eq "" "$(grep -F 'gone.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "no pointer comes back for the deleted topic" || return 1
    assert_eq "- [New](new.md): feature-side" "$(grep -F 'new.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "the feature's own pointer still lands" || return 1
    assert_output_not_contains "$output" "gone.md" "an untouched deleted topic is not mentioned" || return 1
}

run_test test_retire_ignored_mode_leaves_a_base_deleted_topic_deleted

# The feature edited a topic it inherited and the base deleted meanwhile: the
# edit is work, so the feature's text comes back, its pointer with it, and
# the retire says which topic, each control character in its name as "?".
test_retire_ignored_mode_brings_back_a_deleted_topic_the_feature_edited() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local esc="esc"$'\033'"[31m.md"
    _ignored_base_with_two_topics
    echo "esc topic" > "$base_dir/.cs/memory/$esc"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "gone topic, with a feature note" > "$wt/.cs/memory/gone.md"
    echo "esc topic, with a feature note" > "$wt/.cs/memory/$esc"
    rm "$base_dir/.cs/memory/gone.md" "$base_dir/.cs/memory/kept.md" "$base_dir/.cs/memory/$esc"
    : > "$base_dir/.cs/memory/MEMORY.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    assert_eq "gone topic, with a feature note" "$(cat "$base_dir/.cs/memory/gone.md")" \
        "the feature's edit is back in the base" || return 1
    assert_output_contains "$output" "memory/gone.md was deleted in the base and edited in the feature" \
        "the retire names the topic" || return 1
    assert_eq "memory/esc?[31m.md was deleted in the base and edited in the feature; the feature's version is back in the base" \
        "$(printf '%s\n' "$output" | grep -F 'memory/esc')" "the retire shows a control character in the topic's name as ?" || return 1
    assert_eq "- [Gone](gone.md): a topic" "$(grep -F 'gone.md' "$base_dir/.cs/memory/MEMORY.md")" \
        "its pointer comes back with it" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/kept.md" "the untouched deleted topic stays deleted" || return 1
    assert_eq "" "$(grep -F 'kept.md' "$base_dir/.cs/memory/MEMORY.md")" "and so does its pointer" || return 1
}

run_test test_retire_ignored_mode_brings_back_a_deleted_topic_the_feature_edited

# A topic both sides edited cannot go back without overwriting one edit: the
# retire refuses before it removes anything, naming the topic, and the features
# screen counts it as a file the removal would destroy.
test_retire_ignored_mode_refuses_a_topic_both_sides_edited() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "kept topic, feature edit" > "$wt/.cs/memory/kept.md"
    echo "kept topic, base edit" > "$base_dir/.cs/memory/kept.md"
    echo "feature topic" > "$wt/.cs/memory/new.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "1" "$(_feat_field "$line" 7)" "one file at risk: $line" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/memory/kept.md" "$output" "the refusal names the topic and nothing else" || return 1
    assert_eq "kept topic, feature edit" "$(cat "$wt/.cs/memory/kept.md")" "the feature's edit is still there" || return 1
    assert_eq "kept topic, base edit" "$(cat "$base_dir/.cs/memory/kept.md")" "the base's edit is untouched" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/new.md" "nothing was fused" || return 1
    # Positive control: once the user settles the topic, the same worktree retires.
    cp "$wt/.cs/memory/kept.md" "$base_dir/.cs/memory/kept.md"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "feature topic" "$(cat "$base_dir/.cs/memory/new.md")" "the feature's topic lands" || return 1
}

run_test test_retire_ignored_mode_refuses_a_topic_both_sides_edited

# A record whose directory is a file in the base, or a link out of the
# session, cannot be carried: the retire refuses before it removes anything,
# naming the record, and the features screen counts it as a file the removal
# would destroy. A link that stays in the session, as an encrypted session's
# vault links do, is a directory like any other.
test_retire_ignored_mode_refuses_a_record_whose_directory_is_a_file_in_the_base() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/artifacts"
    echo "feature report" > "$wt/.cs/artifacts/report.txt"
    echo "base notes" > "$base_dir/.cs/artifacts"
    mkdir -p "$wt/.cs/handoffs" "$TEST_TMPDIR/outside" "$wt/.cs/briefs" "$base_dir/.cs/vault-mnt/briefs"
    echo "feature handoff" > "$wt/.cs/handoffs/h.md"
    ln -s "$TEST_TMPDIR/outside" "$base_dir/.cs/handoffs"
    echo "feature brief" > "$wt/.cs/briefs/b.md"
    ln -s vault-mnt/briefs "$base_dir/.cs/briefs"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "2" "$(_feat_field "$line" 7)" "two files at risk: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there: $output" || return 1
    assert_output_contains "$output" "The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:" \
        "the refusal says why" || return 1
    assert_eq ".cs/artifacts/report.txt
.cs/handoffs/h.md" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names both records" || return 1
    assert_eq "base notes" "$(cat "$base_dir/.cs/artifacts")" "the base's file is untouched" || return 1
    assert_eq "" "$(ls -A "$TEST_TMPDIR/outside")" "nothing was written out of the session" || return 1
    # Positive control: once the file and the link are out of the way, the
    # records land, the brief through the link that stays in the session.
    rm "$base_dir/.cs/artifacts" "$base_dir/.cs/handoffs"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "feature report" "$(cat "$base_dir/.cs/artifacts/report.txt")" "the feature's record lands" || return 1
    assert_eq "feature brief" "$(cat "$base_dir/.cs/vault-mnt/briefs/b.md")" "the brief lands through the link" || return 1
}

run_test test_retire_ignored_mode_refuses_a_record_whose_directory_is_a_file_in_the_base

# A record in a directory named .cs inside the feature's .cs (a session tree
# copied into plans/, say) needs that directory made in the base, and cs makes
# a directory named .cs only as a session's own. The retire refuses before it
# removes anything, naming the record; once the record is out of the way the
# retire goes through.
test_retire_ignored_mode_refuses_a_record_under_a_directory_named_cs() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/plans/.cs"
    echo "a note" > "$wt/.cs/plans/.cs/note.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there: $output" || return 1
    assert_output_contains "$output" "Nothing was removed." "the refusal comes before the removal" || return 1
    assert_eq ".cs/plans/.cs/note.md" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the record" || return 1
    assert_not_exists "$base_dir/.cs/plans/.cs" "nothing is made in the base" || return 1
    assert_eq "" "$(cd "$CS_SESSIONS_ROOT" && ls -d .retire-* 2>/dev/null)" "no records are set aside" || return 1
    # Positive control: without the record the retire goes through.
    rm -r "$wt/.cs/plans/.cs"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through: $output" || return 1
    assert_not_exists "$wt" "the worktree is removed" || return 1
}

run_test test_retire_ignored_mode_refuses_a_record_under_a_directory_named_cs

# The narratives merge by a rule of their own, but only a regular file can be
# merged. A narrative that is a link into the feature's own .cs/local reads as
# missing once .cs is set aside, and deleting the staging directory would then
# delete the only copy of the notes.
test_retire_ignored_mode_refuses_a_narrative_that_is_a_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '## Only copy of the task notes\n' > "$wt/.cs/local/notes"
    ln -s "$wt/.cs/local/notes" "$wt/.cs/memory/narrative.example.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs/memory" "nothing was removed: $output" || return 1
    assert_eq "## Only copy of the task notes" "$(cat "$wt/.cs/local/notes" 2>/dev/null)" "the notes are still there" || return 1
    assert_eq ".cs/memory/narrative.example.md" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the narrative" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the features screen counts it: $line" || return 1
    # Positive control: the same notes as a regular file merge into the base.
    rm "$wt/.cs/memory/narrative.example.md"
    mv "$wt/.cs/local/notes" "$wt/.cs/memory/narrative.example.md"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "## Only copy of the task notes" "$(cat "$base_dir/.cs/memory/narrative.example.md" 2>/dev/null)" \
        "the notes land in the base" || return 1
}

run_test test_retire_ignored_mode_refuses_a_narrative_that_is_a_link

# A record merged by a rule of its own still needs its directory in the base.
# A file where the base's .cs/memory should be is found before anything is
# removed, not by the merge once the worktree is gone.
test_retire_ignored_mode_refuses_a_narrative_whose_directory_is_a_file_in_the_base() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git config user.email tester@example.com \
        && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '## Task finding\n' > "$wt/.cs/memory/narrative.example.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    rm -r "$base_dir/.cs/memory"
    echo "base notes" > "$base_dir/.cs/memory"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs/memory" "nothing was removed: $output" || return 1
    # The index and the narrative cs wrote at the launch need the directory too.
    assert_eq ".cs/memory/MEMORY.md
.cs/memory/narrative.example.md
.cs/memory/narrative.tester-example-com.md" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the merged records" || return 1
    assert_eq "3" "$(_feat_field "$line" 7)" "the features screen counts them: $line" || return 1
    assert_eq "base notes" "$(cat "$base_dir/.cs/memory")" "the base's file is untouched" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*')" "nothing is left staged" || return 1
    # Positive control: with the file out of the way, the narrative lands.
    rm "$base_dir/.cs/memory"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "## Task finding" "$(cat "$base_dir/.cs/memory/narrative.example.md" 2>/dev/null)" "the narrative lands" || return 1
}

run_test test_retire_ignored_mode_refuses_a_narrative_whose_directory_is_a_file_in_the_base

# The refusal says to delete what it lists. Once the feature holds nothing
# the fuse has to put under .cs/memory (the copy it was handed of a topic is
# left as it was), a file there in the base stands in no record's way: the
# features screen reads merged, and the retire goes through.
test_retire_ignored_mode_retires_over_a_memory_file_once_nothing_goes_there() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line listed rel status=0
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "kept topic" > "$base_dir/.cs/memory/kept.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git config user.email tester@example.com \
        && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/plans"
    echo "feature plan" > "$wt/.cs/plans/p.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    rm -r "$base_dir/.cs/memory"
    echo "base notes" > "$base_dir/.cs/memory"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    listed=$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')
    assert_eq ".cs/memory/MEMORY.md
.cs/memory/narrative.tester-example-com.md" "$listed" "the refusal lists the index and the narrative" || return 1
    while IFS= read -r rel; do
        rm "$wt/$rel" || return 1
    done <<< "$listed"
    assert_eq "kept.md" "$(ls -A "$wt/.cs/memory")" "the copy of the topic is all that is left there" || return 1
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "0" "$(_feat_field "$line" 7)" "no file at risk: $line" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "the features screen reads merged: $line" || return 1
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
    assert_eq "base notes" "$(cat "$base_dir/.cs/memory")" "the base's file is untouched" || return 1
    assert_eq "feature plan" "$(cat "$base_dir/.cs/plans/p.md" 2>/dev/null)" "the plan lands" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*')" "nothing is left staged" || return 1
}

run_test test_retire_ignored_mode_retires_over_a_memory_file_once_nothing_goes_there

# A base encrypted after the feature was made keeps .cs/memory, plans,
# claude-config and private as links into its vault, and a locked vault
# leaves them all dangling. The retire says to mount it, before and instead
# of listing the records that cannot go through the dangling links: deleting
# them, as that list says, would delete the feature's only narrative. The
# features screen reads vault-locked, with nothing at risk, in the retire's
# order: untracked work in the worktree comes first.
test_retire_and_features_name_a_locked_base_vault_before_any_record() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0 sub
    local mnt="$CS_SESSIONS_ROOT/proj/.cs/vault-mnt"
    mkdir -p "$base_dir/.cs"/{memory,local}
    printf '%s\n' '- [Kept](kept.md): a topic' > "$base_dir/.cs/memory/MEMORY.md"
    echo "kept topic" > "$base_dir/.cs/memory/kept.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git config user.email tester@example.com \
        && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '## Task finding\n' >> "$wt/.cs/memory/narrative.tester-example-com.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    for sub in memory plans claude-config private; do
        mkdir -p "$mnt/$sub"
        if [ -d "$base_dir/.cs/$sub" ]; then
            cp -R "$base_dir/.cs/$sub/." "$mnt/$sub/" && rm -r "$base_dir/.cs/$sub" || return 1
        fi
        ln -s "vault-mnt/$sub" "$base_dir/.cs/$sub"
    done
    _mark_hand_made_vault "$base_dir"
    mv "$mnt" "$TEST_TMPDIR/vault-unmounted"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "vault-locked" "$(_feat_field "$line" 10)" "the features screen reads vault-locked: $line" || return 1
    assert_eq "0" "$(_feat_field "$line" 7)" "with nothing at risk: $line" || return 1
    echo "scratch" > "$wt/scratch.txt"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "untracked" "$(_feat_field "$line" 10)" "untracked work comes first, as in the retire: $line" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "counting only that file: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "Error: Worktree has 1 untracked file that removal would destroy; commit or remove it first:
    scratch.txt" "$(printf '%s\n' "$output" | tail -n 2)" "the retire agrees: $output" || return 1
    rm "$wt/scratch.txt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: cannot fuse the worktree's records: $base_dir/.cs/private is locked. Mount it, then retry." \
        "the refusal says to mount the vault" || return 1
    assert_output_not_contains "$output" "by hand" "and lists no records to merge or delete" || return 1
    assert_file_contains "$wt/.cs/memory/narrative.tester-example-com.md" "^## Task finding$" "nothing was removed" || return 1
    # Any one link dangling is the same refusal, naming that link.
    mv "$TEST_TMPDIR/vault-unmounted" "$mnt"
    mv "$mnt/memory" "$TEST_TMPDIR/memory-away"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "vault-locked" "$(_feat_field "$line" 10)" "one dangling link reads vault-locked too: $line" || return 1
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: cannot fuse the worktree's records: $base_dir/.cs/memory is locked. Mount it, then retry." \
        "the refusal names the dangling link" || return 1
    assert_output_not_contains "$output" "by hand" "and lists no records to merge or delete" || return 1
    # Positive control: mounted whole, the screen reads merged and the
    # narrative lands in the vault.
    mv "$TEST_TMPDIR/memory-away" "$mnt/memory"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "merged" "$(_feat_field "$line" 10)" "the features screen reads merged: $line" || return 1
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through: $output" || return 1
    assert_file_contains "$mnt/memory/narrative.tester-example-com.md" "^## Task finding$" "the narrative lands in the vault" || return 1
}

run_test test_retire_and_features_name_a_locked_base_vault_before_any_record

# The feature's log is appended to the base's machine-local log, so that is
# the destination checked before anything is removed.
test_retire_ignored_mode_refuses_a_log_the_base_cannot_take() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf 'feature command\n' > "$wt/.cs/local/session.log"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir "$base_dir/.cs/local/session.log"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_dir "$wt/.cs/memory" "nothing was removed: $output" || return 1
    assert_eq ".cs/local/session.log" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the log" || return 1
    # Positive control: with the directory out of the way, the log lands.
    rmdir "$base_dir/.cs/local/session.log"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_file_contains "$base_dir/.cs/local/session.log" "^feature command$" "the log lands" || return 1
}

run_test test_retire_ignored_mode_refuses_a_log_the_base_cannot_take

# A worktree made while cs kept the log at .cs/logs/session.log and used
# since holds two logs, and both go to the base's. The one at .cs/logs/ goes
# first: cs stopped writing there when the log moved to .cs/local/, so its
# lines are the earlier ones and the base's log stays in the order they ran.
test_retire_ignored_mode_fuses_both_of_a_feature_logs() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/logs"
    printf 'earlier command one\nearlier command two\n' > "$wt/.cs/logs/session.log"
    printf 'later command\n' > "$wt/.cs/local/session.log"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    printf 'base command\n' > "$base_dir/.cs/local/session.log"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq "base command

earlier command one
earlier command two

later command" "$(cat "$base_dir/.cs/local/session.log")" "the base's log holds its own lines, then each log's, earlier first" || return 1
    assert_not_exists "$base_dir/.cs/logs" "nothing lands at the path the log moved from" || return 1
}

run_test test_retire_ignored_mode_fuses_both_of_a_feature_logs

# Each of the two logs is read, so each has to be a regular file: a link at
# either is refused by name before anything is removed.
test_retire_ignored_mode_refuses_either_log_that_is_a_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/logs"
    printf 'earlier command\n' > "$wt/.cs/local/earlier.log"
    ln -s "$wt/.cs/local/earlier.log" "$wt/.cs/logs/session.log"
    printf 'later command\n' > "$wt/.cs/local/session.log"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "earlier command" "$(cat "$wt/.cs/local/earlier.log" 2>/dev/null)" "nothing was removed: $output" || return 1
    assert_eq ".cs/logs/session.log" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the linked log" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the features screen counts it: $line" || return 1
    assert_file_not_exists "$base_dir/.cs/local/session.log" "nothing was fused" || return 1
    # The log in .cs/local is held to the same rule.
    rm "$wt/.cs/logs/session.log"
    mv "$wt/.cs/local/earlier.log" "$wt/.cs/logs/session.log"
    mv "$wt/.cs/local/session.log" "$wt/.cs/local/later.log"
    ln -s "$wt/.cs/local/later.log" "$wt/.cs/local/session.log"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq ".cs/local/session.log" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
        "the refusal names the linked log" || return 1
    assert_eq "later command" "$(cat "$wt/.cs/local/later.log" 2>/dev/null)" "nothing was removed: $output" || return 1
    # Positive control: as regular files, both land.
    rm "$wt/.cs/local/session.log"
    mv "$wt/.cs/local/later.log" "$wt/.cs/local/session.log"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "
earlier command

later command" "$(cat "$base_dir/.cs/local/session.log")" "both logs land" || return 1
}

run_test test_retire_ignored_mode_refuses_either_log_that_is_a_link

# The directory a log sits in is held to the same rule: a feature .cs/local or
# .cs/logs that is a link would have the fuse read a log from wherever it
# leads. Each is refused by name before anything is removed, and the features
# screen counts it.
test_retire_ignored_mode_refuses_a_log_directory_that_is_a_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    local out="$TEST_TMPDIR/outside-local" logs="$TEST_TMPDIR/outside-logs" kept="$TEST_TMPDIR/local-kept" dir
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    printf 'base command\n' > "$base_dir/.cs/local/session.log"
    cp -R "$wt/.cs/local" "$kept"
    cp -R "$wt/.cs/local" "$out"
    printf 'outside local line\n' >> "$out/session.log"
    rm -rf "$wt/.cs/local"
    ln -s "$out" "$wt/.cs/local"
    mkdir -p "$logs"
    printf 'outside logs line\n' > "$logs/session.log"
    for dir in local logs; do
        if [ "$dir" = logs ]; then
            rm "$wt/.cs/local"
            cp -R "$kept" "$wt/.cs/local"
            ln -s "$logs" "$wt/.cs/logs"
        fi
        line=$("$CS_BIN" proj -features --porcelain 2>&1)
        status=0
        output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "the retire refuses a .cs/$dir link: $output" || return 1
        assert_eq "Error: The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/$dir" "$output" "the refusal says why for .cs/$dir" || return 1
        assert_eq ".cs/$dir" "$(printf '%s\n' "$output" | awk 'listed; /again:$/ { listed = 1 }')" \
            "the refusal names only the linked .cs/$dir" || return 1
        assert_eq "1" "$(_feat_field "$line" 7)" "the features screen counts the .cs/$dir link: $line" || return 1
        assert_dir "$wt/.cs/memory" "nothing was removed for .cs/$dir: $output" || return 1
        assert_eq "base command" "$(cat "$base_dir/.cs/local/session.log")" "the base's log is as it was for .cs/$dir" || return 1
    done
    # Positive control: with the link gone, the retire goes through, and no
    # line from outside reaches the base's log.
    rm "$wt/.cs/logs"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "0" "$(grep -c '^outside' "$base_dir/.cs/local/session.log")" "nothing from outside lands in the base's log" || return 1
}

run_test test_retire_ignored_mode_refuses_a_log_directory_that_is_a_link

# Every record under .cs that the base lacks goes back to it, at any depth,
# not just topics and narratives: plans, a summary, handoffs, a brief,
# artifacts, archived narrative sections, a nested topic, a non-.md note. A
# plan the create copied in and only the feature edited replaces the base's
# unchanged copy, named. A summary the feature edited is its own prose and goes
# under the feature's path, .cs/features/<task>/, leaving the base's alone.
# The README cs wrote for the feature, left as written, is the feature's own
# bookkeeping and goes with it.
test_retire_ignored_mode_carries_every_record_the_base_lacks() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 rel
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.cs/plans"
    echo "base plan" > "$base_dir/.cs/plans/base-plan.md"
    echo "base summary" > "$base_dir/.cs/summary.md"
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    mkdir -p "$wt/.cs/plans/sub" "$wt/.cs/handoffs" "$wt/.cs/artifacts" \
        "$wt/.cs/narrative-archive/someone" "$wt/.cs/memory/sub"
    for rel in plans/feat-plan.md plans/sub/deep-plan.md handoffs/2026-01-01-h.md brief.md \
            artifacts/report.html narrative-archive/someone/old.md memory/sub/deep.md memory/notes.txt; do
        echo "feature $rel" > "$wt/.cs/$rel"
    done
    echo "base plan, feature edit" > "$wt/.cs/plans/base-plan.md"
    echo "base summary, feature edit" > "$wt/.cs/summary.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire exits 0: $output" || return 1
    for rel in plans/feat-plan.md plans/sub/deep-plan.md handoffs/2026-01-01-h.md brief.md \
            artifacts/report.html narrative-archive/someone/old.md memory/sub/deep.md memory/notes.txt; do
        assert_eq "feature $rel" "$(cat "$base_dir/.cs/$rel" 2>/dev/null)" "$rel lands in the base" || return 1
    done
    assert_eq "base plan, feature edit" "$(cat "$base_dir/.cs/plans/base-plan.md")" "the edited plan lands" || return 1
    assert_eq "base summary" "$(cat "$base_dir/.cs/summary.md")" "the base summary is untouched" || return 1
    assert_eq "base summary, feature edit" "$(cat "$base_dir/.cs/features/t1/summary.md" 2>/dev/null)" "the edited summary lands under the feature's path" || return 1
    assert_output_contains "$output" "plans/base-plan.md was edited in the feature and not in the base; the feature's version is now in the base" \
        "the plan's replacement is named" || return 1
    assert_output_contains "$output" "The feature's summary.md is kept at $base_dir/.cs/features/t1/summary.md" \
        "where the summary went is named" || return 1
    assert_output_not_contains "$output" "summary.md was edited" "the summary replaces nothing" || return 1
    assert_eq "# Session: proj" "$(cat "$base_dir/.cs/README.md")" "the base README is untouched" || return 1
    assert_not_exists "$base_dir/.cs/features/t1/README.md" "the README left as written goes with the worktree" || return 1
    assert_output_not_contains "$output" "README" "the feature's own README is not mentioned" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_ignored_mode_carries_every_record_the_base_lacks

# The README cs writes for a feature asks for its objective, and the feature's
# /wrap rewrites the summary it inherited. Both are the feature's own prose:
# once edited they go to .cs/features/<task>/ in the base, the base's own README
# and summary stay as they are, and nothing about them holds up the retire or
# reads as at risk on the features screen.
test_retire_ignored_mode_keeps_the_feature_readme_and_summary_under_its_path() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    echo "base summary" > "$base_dir/.cs/summary.md"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '\nShip the t1 feature.\n' >> "$wt/.cs/README.md"
    printf '# Session Summary: proj@t1\n\nThe feature wrap summary.\n' > "$wt/.cs/summary.md"
    cp "$wt/.cs/README.md" "$TEST_TMPDIR/feature-readme"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "0" "$(_feat_field "$line" 7)" "nothing is at risk: $line" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "the feature reads as merged: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through: $output" || return 1
    # The walk's order is the file system's, so the lines are compared sorted.
    # The pointer is the one the launch put in the feature's index for its
    # narrative.
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
The feature's README.md is kept at $base_dir/.cs/features/t1/README.md
The feature's summary.md is kept at $base_dir/.cs/features/t1/summary.md
retired t1 $sha" "$(printf '%s\n' "$output" | LC_ALL=C sort)" "the retire names where each went, and nothing else" || return 1
    cmp -s "$TEST_TMPDIR/feature-readme" "$base_dir/.cs/features/t1/README.md" \
        || { echo "  FAIL: the feature's README, objective and all, is not under its path"; return 1; }
    assert_eq "# Session Summary: proj@t1

The feature wrap summary." "$(cat "$base_dir/.cs/features/t1/summary.md")" "the feature's summary is under its path" || return 1
    assert_eq "# Session: proj" "$(cat "$base_dir/.cs/README.md")" "the base README is untouched" || return 1
    assert_eq "base summary" "$(cat "$base_dir/.cs/summary.md")" "the base summary is untouched" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_ignored_mode_keeps_the_feature_readme_and_summary_under_its_path

# A feature name can come back once its first worktree is retired. The second
# feature's README and summary never overwrite the first's: each goes to the
# first free name beside it (README.2.md, summary.2.md). A base with no summary
# of its own gets the feature's under the feature's path too.
test_retire_ignored_mode_keeps_a_second_feature_of_the_same_name_beside_the_first() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 round
    _ignored_base_with_two_topics
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    for round in first second; do
        cs_launch "proj@t1"
        echo "$round" > "$wt/$round.txt"
        (cd "$wt" && git add "$round.txt" && git commit -q -m "$round")
        printf '\nThe %s objective.\n' "$round" >> "$wt/.cs/README.md"
        printf 'The %s summary.\n' "$round" > "$wt/.cs/summary.md"
        sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture, $round"; return 1; }
        status=0
        output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
        assert_eq "0" "$status" "the $round retire goes through: $output" || return 1
    done
    assert_eq "The feature's README.md is kept at $base_dir/.cs/features/t1/README.2.md
The feature's summary.md is kept at $base_dir/.cs/features/t1/summary.2.md
retired t1 $sha" "$(printf '%s\n' "$output" | LC_ALL=C sort)" "the second retire names the free names" || return 1
    assert_eq "1" "$(grep -c '^The first objective\.$' "$base_dir/.cs/features/t1/README.md")" "the first README is as it was" || return 1
    assert_eq "0" "$(grep -c 'second' "$base_dir/.cs/features/t1/README.md")" "and holds nothing of the second" || return 1
    assert_eq "1" "$(grep -c '^The second objective\.$' "$base_dir/.cs/features/t1/README.2.md")" "the second README is beside it" || return 1
    assert_eq "The first summary." "$(cat "$base_dir/.cs/features/t1/summary.md")" "the first summary is as it was" || return 1
    assert_eq "The second summary." "$(cat "$base_dir/.cs/features/t1/summary.2.md")" "the second summary is beside it" || return 1
    assert_not_exists "$base_dir/.cs/summary.md" "the base, which had no summary, still has none" || return 1
    assert_eq "# Session: proj" "$(cat "$base_dir/.cs/README.md")" "the base README is untouched" || return 1
}

run_test test_retire_ignored_mode_keeps_a_second_feature_of_the_same_name_beside_the_first

# The first free name under the feature's path passes over a dangling link
# there (one out of the session, here): the README and summary take the next
# name, the retire goes through, and nothing is left set aside. A later
# feature of the same name whose README and summary hold the same bytes as
# copies already there writes nothing: the base keeps one copy of each.
test_retire_ignored_mode_passes_over_a_dangling_link_and_keeps_one_copy_under_the_feature_path() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local out="$TEST_TMPDIR/outside"
    _ignored_base_with_two_topics
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    mkdir -p "$out" "$base_dir/.cs/features/t1"
    ln -s "$out/README.md" "$base_dir/.cs/features/t1/README.md"
    ln -s "$out/summary.md" "$base_dir/.cs/features/t1/summary.md"
    cs_launch "proj@t1"
    echo "first" > "$wt/first.txt"
    (cd "$wt" && git add first.txt && git commit -q -m first)
    printf '\nThe t1 objective.\n' >> "$wt/.cs/README.md"
    printf 'The t1 summary.\n' > "$wt/.cs/summary.md"
    cp "$wt/.cs/README.md" "$TEST_TMPDIR/feature-readme"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture, first"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through past the dangling links: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
The feature's README.md is kept at $base_dir/.cs/features/t1/README.2.md
The feature's summary.md is kept at $base_dir/.cs/features/t1/summary.2.md
retired t1 $sha" "$(printf '%s\n' "$output" | LC_ALL=C sort)" "the retire names the names past the links" || return 1
    cmp -s "$TEST_TMPDIR/feature-readme" "$base_dir/.cs/features/t1/README.2.md" \
        || { echo "  FAIL: the feature's README is not at README.2.md"; return 1; }
    assert_eq "The t1 summary." "$(cat "$base_dir/.cs/features/t1/summary.2.md")" "the feature's summary is at summary.2.md" || return 1
    assert_eq "" "$(ls -A "$out")" "nothing is written through the links" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
    assert_eq "" "$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name '.retire-*')" "nothing is left set aside" || return 1
    cs_launch "proj@t1"
    echo "second" > "$wt/second.txt"
    (cd "$wt" && git add second.txt && git commit -q -m second)
    cp "$TEST_TMPDIR/feature-readme" "$wt/.cs/README.md"
    printf 'The t1 summary.\n' > "$wt/.cs/summary.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture, second"; return 1; }
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the second retire goes through: $output" || return 1
    assert_eq "retired t1 $sha" "$output" "the second retire carries nothing the base holds already" || return 1
    assert_eq "README.2.md README.md summary.2.md summary.md" \
        "$(cd "$base_dir/.cs/features/t1" && ls -A | LC_ALL=C sort | paste -sd' ' -)" \
        "the base keeps one copy of each" || return 1
}

run_test test_retire_ignored_mode_passes_over_a_dangling_link_and_keeps_one_copy_under_the_feature_path

# Archives completed row #1 of a task list, kept back behind an open #2, from
# the session at <dir> as the actor alice. Claude Code keeps the list's rows
# under ~/.claude/tasks/<list id>, every character of the id outside
# [a-zA-Z0-9_-] read as '-'. Keeps a copy of the row at $TEST_TMPDIR/<subject>.row.
_archive_first_row_from() {  # dir list_id subject
    local store
    store="$HOME/.claude/tasks/$(printf '%s' "$2" | LC_ALL=C tr -c 'a-zA-Z0-9_-' '-')"
    mkdir -p "$store"
    : > "$store/.lock"
    jq -n --arg subject "$3" '{id: "1", subject: $subject, description: "done", status: "completed", blocks: [], blockedBy: []}' \
        > "$store/1.json"
    jq -n '{id: "2", subject: "next", description: "open", status: "pending", blocks: [], blockedBy: []}' \
        > "$store/2.json"
    cp "$store/1.json" "$TEST_TMPDIR/$3.row"
    printf 'yes\n' > "$1/.cs/local/task-archive"
    CLAUDE_SESSION_DIR="$1" CLAUDE_SESSION_META_DIR="$1/.cs" CLAUDE_CODE_TASK_LIST_ID="$2" CS_ACTOR=alice \
        "$CS_BIN" -archive-tasks run
}

# A feature's native task list is its own (base@task) and numbers from 1, as
# the base's does, so on one machine the base and its feature both archive a
# row #1 under one actor the same day. Each list keeps its own directory under
# the actor's, so the fuse carries the feature's archive into the base beside
# the base's own rather than refusing it.
test_retire_ignored_mode_carries_a_feature_task_archive_beside_the_base_one() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 day
    day=$(date +%Y-%m-%d)
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    output=$(_archive_first_row_from "$base_dir" proj base-row 2>&1) || { echo "  FAIL: the base's archive run: $output"; return 1; }
    output=$(_archive_first_row_from "$wt" "proj@t1" feature-row 2>&1) || { echo "  FAIL: the feature's archive run: $output"; return 1; }
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire carries the feature's archive: $output" || return 1
    cmp -s "$TEST_TMPDIR/base-row.row" "$base_dir/.cs/task-archive/$day/alice/proj/json/1.json" \
        || { echo "  FAIL: the base's row #1 is not where its list keeps it, as it was"; return 1; }
    cmp -s "$TEST_TMPDIR/feature-row.row" "$base_dir/.cs/task-archive/$day/alice/proj-t1/json/1.json" \
        || { echo "  FAIL: the feature's row #1 is not in the base beside it, as it was"; return 1; }
    assert_eq "1" "$(grep -c '^## #1 \[completed\] feature-row$' "$base_dir/.cs/task-archive/$day/alice/proj-t1/tasks.md")" \
        "the feature's snapshot lands with it" || return 1
    assert_eq "0" "$(grep -c 'feature-row' "$base_dir/.cs/task-archive/$day/alice/proj/tasks.md")" \
        "the base's snapshot holds only its own list" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_ignored_mode_carries_a_feature_task_archive_beside_the_base_one

# What the fuse cannot carry without overwriting the base, it refuses to
# destroy: a plan both sides edited, a brief each side wrote, the feature's
# README once edited where the base holds a file at .cs/features (the path the
# README goes to), a repository nested under .cs with its history, and a
# link. The refusal lists them all, each control character in a name as "?",
# the README apart, under the path it goes to and with no word of merging it
# into the base's .cs, and nothing moves, not even what could go.
test_retire_ignored_mode_refuses_records_it_cannot_carry() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.cs/plans"
    echo "base plan" > "$base_dir/.cs/plans/base-plan.md"
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    echo "not a directory" > "$base_dir/.cs/features"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "base plan, feature edit" > "$wt/.cs/plans/base-plan.md"
    echo "base plan, base edit" > "$base_dir/.cs/plans/base-plan.md"
    echo "feature brief" > "$wt/.cs/brief.md"
    echo "base brief" > "$base_dir/.cs/brief.md"
    echo "## Outcome" >> "$wt/.cs/README.md"
    mkdir -p "$wt/.cs/scratch-repo"
    (cd "$wt/.cs/scratch-repo" && git init -q && echo kept > kept.txt && git add kept.txt && git commit -q -m kept)
    ln -s "$base_dir/README.md" "$wt/.cs/plans/link.md"
    ln -s "$base_dir/README.md" "$wt/.cs/plans/esc"$'\033'"[31m"$'\n'"line.md"
    echo "could land" > "$wt/.cs/plans/new.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "6" "$(_feat_field "$line" 7)" "six files at risk: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/brief.md
.cs/plans/base-plan.md
.cs/plans/esc?[31m?line.md
.cs/plans/link.md
.cs/scratch-repo/
The feature's own README and summary go to $base_dir/.cs/features/t1/, and cs cannot make that directory: the base holds a file, a dangling link or a link out of the session on the way to it. Move that aside, or delete each from $wt/.cs, then run /finish t1 again:
.cs/README.md" "$output" "the refusal names all six, each control character as ?, the README under the path it goes to, and nothing else" || return 1
    assert_eq "kept" "$(git -C "$wt/.cs/scratch-repo" show HEAD:kept.txt 2>/dev/null)" "the nested repository keeps its history" || return 1
    assert_eq "base plan, base edit" "$(cat "$base_dir/.cs/plans/base-plan.md")" "the base's plan is untouched" || return 1
    assert_eq "not a directory" "$(cat "$base_dir/.cs/features")" "the base's file at .cs/features is untouched" || return 1
    assert_file_not_exists "$base_dir/.cs/plans/new.md" "nothing was fused" || return 1
    assert_file_exists "$wt/.cs/plans/new.md" "and nothing was removed" || return 1
}

run_test test_retire_ignored_mode_refuses_records_it_cannot_carry

# A base whose .cs/features/<task> links out of the session cannot take the
# feature's README and summary. Alone in the refusal, they are named under the
# path they go to, the refusal says nothing was removed, and nothing reaches
# the link's target.
test_retire_ignored_mode_refuses_the_feature_readme_and_summary_through_a_features_link_out() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output line status=0
    local out="$TEST_TMPDIR/outside"
    _ignored_base_with_two_topics
    echo "# Session: proj" > "$base_dir/.cs/README.md"
    mkdir -p "$out" "$base_dir/.cs/features"
    ln -s "$out" "$base_dir/.cs/features/t1"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '\nThe t1 objective.\n' >> "$wt/.cs/README.md"
    printf 'The t1 summary.\n' > "$wt/.cs/summary.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "2" "$(_feat_field "$line" 7)" "the features screen counts the README and summary: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: The feature's own README and summary go to $base_dir/.cs/features/t1/, and cs cannot make that directory: the base holds a file, a dangling link or a link out of the session on the way to it. Nothing was removed. Move that aside, or delete each from $wt/.cs, then run /finish t1 again:
.cs/README.md
.cs/summary.md" "$output" "the refusal names the path the README and summary go to" || return 1
    assert_eq "" "$(ls -A "$out")" "nothing reaches the link's target" || return 1
    assert_dir "$wt/.cs/memory" "nothing was removed" || return 1
    assert_eq "# Session: proj" "$(cat "$base_dir/.cs/README.md")" "the base README is untouched" || return 1
}

run_test test_retire_ignored_mode_refuses_the_feature_readme_and_summary_through_a_features_link_out

# .cs itself made a repository is refused whole: walked into, its .git would
# be copied into the base's .cs as files.
test_retire_ignored_mode_refuses_a_cs_that_is_itself_a_repository() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    (cd "$wt/.cs" && git init -q && git add memory/kept.md && git commit -q -m "notes history")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: The feature's session records hold files the record fuse cannot carry into $base_dir/.cs: the base holds a different file at the same path, or a file or a link out of the session where the path needs a directory, or the path needs a new directory named .cs, or the file is a link or a repository. Nothing was removed. Merge each into $base_dir/.cs by hand, or delete it from $wt/.cs, then run /finish t1 again:
.cs/" "$output" "the refusal names .cs itself and nothing else" || return 1
    assert_eq "notes history" "$(git -C "$wt/.cs" log -1 --format=%s 2>/dev/null)" ".cs keeps its history" || return 1
    assert_not_exists "$base_dir/.cs/.git" "the base's .cs gets no .git" || return 1
}

run_test test_retire_ignored_mode_refuses_a_cs_that_is_itself_a_repository

# A repo that tracks .cs carries it through git, so an untracked file under
# .cs is no more carried than one anywhere else: the retire refuses and names
# it. Only cs's own machine-local files (.cs/local, the locks) go with the
# worktree unasked.
test_retire_tracked_mode_refuses_untracked_session_records() {
    local base_dir wt sha output line status=0 rel
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@t1"
    wt="$CS_SESSIONS_ROOT/myproj@t1"
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    mkdir -p "$wt/.cs/plans" "$wt/.cs/handoffs"
    for rel in plans/feat-plan.md memory/new-topic.md memory/narrative.someone.md handoffs/h.md summary.md; do
        echo "feature $rel" > "$wt/.cs/$rel"
    done
    : > "$wt/.cs/session.lock"
    sha=$(land_feature myproj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" myproj -features --porcelain 2>&1)
    assert_eq "5" "$(_feat_field "$line" 7)" "five files at risk: $line" || return 1
    output=$("$CS_BIN" myproj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    # git tracks nothing under these three directories, so each is one entry.
    assert_eq "" "$(git -C "$wt" ls-files .cs/memory .cs/handoffs .cs/plans)" "fixture: git tracks nothing there" || return 1
    assert_eq "Error: Worktree has 5 untracked files that removal would destroy; commit or remove them first:
    .cs/memory/    (2 files)
    .cs/handoffs/  (1 file)
    .cs/plans/     (1 file)
    .cs/summary.md" "$output" "the refusal counts all five and names where they are" || return 1
    assert_eq "feature memory/new-topic.md" "$(cat "$wt/.cs/memory/new-topic.md")" "the topic is still there" || return 1
    assert_eq "feature plans/feat-plan.md" "$(cat "$wt/.cs/plans/feat-plan.md")" "the plan is still there" || return 1
    # Positive control: committed, they land with the feature and the worktree retires.
    (cd "$wt" && git add .cs && git commit -q -m "session records")
    sha=$(land_feature myproj t1) || { echo "  FAIL: second integrate"; return 1; }
    status=0
    output=$("$CS_BIN" myproj -retire-feature t1 "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "feature plans/feat-plan.md" "$(cat "$base_dir/.cs/plans/feat-plan.md")" "the plan landed" || return 1
}

run_test test_retire_tracked_mode_refuses_untracked_session_records

# cs writes the root CLAUDE.local.md with its protocol sentinel, and that copy
# goes with the worktree. One without the sentinel is the user's own: git
# keeps no copy of it, so the retire refuses and names it.
test_retire_refuses_a_user_authored_claude_local_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    assert_file_contains "$wt/CLAUDE.local.md" "cs:session-protocol" "cs wrote the protocol file" || return 1
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "my own notes for this checkout" > "$wt/CLAUDE.local.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: Worktree has 1 untracked file that removal would destroy; commit or remove it first:
    CLAUDE.local.md" "$output" "the refusal names the file" || return 1
    assert_eq "my own notes for this checkout" "$(cat "$wt/CLAUDE.local.md")" "the notes are still there" || return 1
}

run_test test_retire_refuses_a_user_authored_claude_local_md

# Claude Code writes the permission grants made in a feature to its
# .claude/settings.local.json, which git does not carry. The retire adds each
# allow entry the base lacks to the base's file, after the base's own, and
# leaves every other key of both files where it is. Besides permissions.allow,
# the feature's file holds cs's autoMemoryDirectory (the worktree's own
# .cs/memory) and plansDirectory, and here a deny entry.
test_retire_carries_the_feature_permission_grants_into_the_base() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"env": {"A": "1"}, "permissions": {"allow": ["Bash(ls:*)", "Read"]}}' \
        > "$base_dir/.claude/settings.local.json"
    cs_launch "proj@t1"
    assert_eq "$wt/.cs/memory" "$(jq -r .autoMemoryDirectory "$wt/.claude/settings.local.json")" \
        "cs pointed the feature's memory at its own .cs" || return 1
    jq '.permissions = {allow: ["Bash(make:*)", "Read", "Bash(make:*)"], deny: ["Bash(rm:*)"]}' \
        "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '["Bash(ls:*)","Read","Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" \
        "the grant survives after the base's own, once" || return 1
    assert_eq '{"A":"1"}' "$(jq -c .env "$base_dir/.claude/settings.local.json")" "the base's other keys stay" || return 1
    assert_eq '["env","permissions"]' "$(jq -c 'keys_unsorted' "$base_dir/.claude/settings.local.json")" \
        "no autoMemoryDirectory or plansDirectory from the feature" || return 1
    assert_eq '["Bash(rm:*)"]' "$(jq -c .permissions.deny "$base_dir/.claude/settings.local.json")" \
        "the feature's deny rule comes too" || return 1
}

run_test test_retire_carries_the_feature_permission_grants_into_the_base

# A feature's deny and ask rules go to the base with its grants, by the same
# union: a feature that allows Bash(git:*) but denies Bash(git push:*) must
# not leave the base allowing the push.
test_retire_carries_the_feature_deny_and_ask_rules_into_the_base() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"], "deny": ["Bash(rm:*)"]}}' > "$base_dir/.claude/settings.local.json"
    cs_launch "proj@t1"
    jq '.permissions = {allow: ["Bash(git:*)"], deny: ["Bash(git push:*)", "Bash(rm:*)"], ask: ["Bash(git commit:*)"]}' \
        "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '{"allow":["Read","Bash(git:*)"],"deny":["Bash(rm:*)","Bash(git push:*)"],"ask":["Bash(git commit:*)"]}' \
        "$(jq -c .permissions "$base_dir/.claude/settings.local.json")" \
        "the base allows git and still denies the push, after its own rules, once" || return 1
}

run_test test_retire_carries_the_feature_deny_and_ask_rules_into_the_base

# A base with no settings file gets one holding the feature's allow list only.
test_retire_creates_the_base_settings_with_the_feature_grants_alone() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    rm -rf "$base_dir/.claude"
    jq '.permissions.allow = ["Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '{"permissions":{"allow":["Bash(make:*)"]}}' "$(jq -c . "$base_dir/.claude/settings.local.json" 2>&1)" \
        "the base's file holds the grant and nothing else" || return 1
}

run_test test_retire_creates_the_base_settings_with_the_feature_grants_alone

# The base's own claude can make .claude between the retire's look for it and
# its mkdir. A DEBUG trap stands in for that claude: it makes the directory
# just before the retire's mkdir runs. The directory is there, which is all
# the carry needs.
test_base_claude_dir_counts_one_another_writer_made_first() {
    local base="$TEST_TMPDIR/claude-race/proj" out rc=0
    mkdir -p "$base/.cs"
    out=$(CS_TEST_PEER_RAN="$TEST_TMPDIR/peer-ran" CS_TEST_PEER_DIR="$base/.claude" "$BASH" -c '
        . "$1/02-shared.sh"; . "$1/30-worktree.sh"
        set -o functrace
        _peer() {
            case "$BASH_COMMAND" in mkdir\ *) ;; *) return 0 ;; esac
            [ ! -e "$CS_TEST_PEER_RAN" ] || return 0
            : > "$CS_TEST_PEER_RAN"
            command mkdir "$CS_TEST_PEER_DIR"
        }
        trap _peer DEBUG
        _make_base_claude_dir "$2"' _ "$SCRIPT_DIR/../lib" "$base" 2>&1) || rc=$?
    assert_exists "$TEST_TMPDIR/peer-ran" "the second writer ran before the retire's mkdir" || return 1
    assert_eq "0" "$rc" "the base's .claude counts as made: $out" || return 1
    assert_eq "" "$out" "and nothing is said about it" || return 1
}

run_test test_base_claude_dir_counts_one_another_writer_made_first

# A settings file the union cannot read, the feature's or the base's, refuses
# the retire before anything is removed and names the file.
test_retire_refuses_a_settings_file_it_cannot_read() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/settings.local.json"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    printf '{' > "$wt/.claude/settings.local.json"
    before=$(cat "$base_dir/.claude/settings.local.json")
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude/settings.local.json is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot add the feature's permission rules to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish t1 again." \
        "the refusal names the feature's file" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1

    printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$wt/.claude/settings.local.json"
    printf '%s\n' '{"permissions": {"allow": "Read"}}' > "$base_dir/.claude/settings.local.json"
    before=$(cat "$base_dir/.claude/settings.local.json")
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Error: $base_dir/.claude/settings.local.json is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot add the feature's permission rules to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish t1 again." \
        "the refusal names the base's file" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1

    # Valid JSON is not enough: one object, with a permissions object and an
    # allow list where they are present. A second document's grants would be
    # dropped, and a null would read as absent.
    local bad i
    bad=("$wt/.claude/settings.local.json" '{"permissions": {"deny": "Bash(git push:*)"}}'
         "$wt/.claude/settings.local.json" '{"permissions": null}'
         "$base_dir/.claude/settings.local.json" '{"permissions": {"allow": null}}'
         "$wt/.claude/settings.local.json" '{"permissions": {"allow": false}}'
         "$wt/.claude/settings.local.json" $'{"permissions": {"allow": ["Read"]}}\n{"permissions": {"allow": ["Bash(make:*)"]}}')
    for i in 0 2 4 6 8; do
        printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$wt/.claude/settings.local.json"
        printf '%s\n' '{"permissions": {"allow": ["Bash(ls:*)"]}}' > "$base_dir/.claude/settings.local.json"
        printf '%s\n' "${bad[$((i + 1))]}" > "${bad[$i]}"
        before=$(cat "$base_dir/.claude/settings.local.json")
        status=0
        output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "the retire refuses ${bad[$((i + 1))]}: $output" || return 1
        assert_output_contains "$output" "Error: ${bad[$i]} is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot add the feature's permission rules to $base_dir/.claude/settings.local.json. Nothing was removed. Fix it, then run /finish t1 again." \
            "the refusal names ${bad[$i]}" || return 1
        assert_dir "$wt/.cs/memory" "the worktree is still there" || return 1
        assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1
    done
}

run_test test_retire_refuses_a_settings_file_it_cannot_read

# A settings file the repository tracks is carried by git like any other
# file: the retire leaves the base's as the integrate and the base's own
# commits made it, and does not bring back a grant the base dropped since.
test_retire_leaves_a_tracked_settings_file_to_git() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(old:*)"]}}' > "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add -f .claude/settings.local.json && git commit -q -m "share settings")
    cs_launch "proj@t1"
    jq '.permissions.allow += ["Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt .claude/settings.local.json && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    jq '.permissions.allow -= ["Bash(old:*)"]' "$base_dir/.claude/settings.local.json" > "$base_dir/.claude/s.json" \
        && mv "$base_dir/.claude/s.json" "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git commit -q -m "drop a grant" -- .claude/settings.local.json)
    before=$(cat "$base_dir/.claude/settings.local.json")
    assert_eq '["Read","Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" \
        "the integrate landed the feature's grant" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .claude)" "and the base's checkout is clean" || return 1
}

run_test test_retire_leaves_a_tracked_settings_file_to_git

# The base can start tracking the file after the feature was made from it:
# the feature's checkout does not track it, the base's does, and git owns the
# base's copy all the same. A grant the base chose not to commit stays out.
test_retire_leaves_a_settings_file_the_base_tracks_since_to_git() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    jq '.permissions.allow = ["Read", "Bash(*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add -f .claude/settings.local.json && git commit -q -m "share settings")
    assert_eq "" "$(git -C "$wt" ls-files -- .claude/settings.local.json)" "the feature's checkout does not track it" || return 1
    before=$(cat "$base_dir/.claude/settings.local.json")
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .claude)" "and the base's checkout is clean" || return 1
}

run_test test_retire_leaves_a_settings_file_the_base_tracks_since_to_git

# The base's settings.local.json can be a link the base keeps ignored, to a
# file it shares through git. cs writes nothing through a link at that path,
# wherever it points: the file is left as it is, and the retire lists on
# stdout each rule the union would have added, for the user to add by hand.
# It reads the feature's file to list them, so a feature file it cannot read
# is refused by name before anything is removed.
test_retire_writes_no_permission_rules_through_a_settings_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before rules
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"], "deny": ["Bash(rm:*)"]}}' > "$base_dir/team-settings.json"
    ln -s ../team-settings.json "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add team-settings.json && git commit -q -m "share settings")
    before=$(cat "$base_dir/team-settings.json")
    rules=$(cat "$wt/.claude/settings.local.json")
    printf '{' > "$wt/.claude/settings.local.json"
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses a feature file it cannot read: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude/settings.local.json is not one JSON object, or its permissions is not an object, or its permissions.allow, deny or ask is not a list, so cs cannot list the feature's permission rules that $base_dir/.claude/settings.local.json, a link, does not take. Nothing was removed. Fix it, then run /finish t1 again." \
        "the refusal names the feature's file" || return 1
    assert_dir "$wt/.cs/memory" "nothing was removed" || return 1
    printf '%s\n' "$rules" | jq '.permissions = {allow: ["Read", "Bash(make:*)", "Bash(make:*)"], deny: ["Bash(rm:*)"], ask: ["Bash(git push:*)"]}' \
        > "$wt/.claude/settings.local.json"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>"$TEST_TMPDIR/stderr") || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output $(cat "$TEST_TMPDIR/stderr")" || return 1
    assert_eq "$before" "$(cat "$base_dir/team-settings.json")" "the shared file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain)" "and the base's checkout is clean" || return 1
    assert_symlink "$base_dir/.claude/settings.local.json" "the link stays" || return 1
    assert_eq "$base_dir/.claude/settings.local.json is a link, and cs writes nothing through it. Add by hand the feature's permission rules it lacks that the base needs:
  allow: \"Bash(make:*)\"
  ask: \"Bash(git push:*)\"" "$(printf '%s\n' "$output" | awk '/ is a link, and cs writes nothing through it/ { on = 1 } on && !/^(  |\/)/ { on = 0 } on')" \
        "stdout lists each rule the union would have added, once: $output" || return 1
}

run_test test_retire_writes_no_permission_rules_through_a_settings_link

# On a volume that folds case, a base that tracks .claude/Settings.local.json
# has git's file at the path cs reads, and git owns it all the same.
test_retire_leaves_a_settings_file_tracked_in_another_case_to_git() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    jq '.permissions.allow = ["Read", "Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/Settings.local.json"
    [ -e "$base_dir/.claude/settings.local.json" ] || { echo "    SKIP (this volume does not fold case)"; return 77; }
    (cd "$base_dir" && git add -f .claude/Settings.local.json && git commit -q -m "share settings")
    before=$(cat "$base_dir/.claude/Settings.local.json")
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/Settings.local.json")" "the base's file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain -- .claude)" "and the base's checkout is clean" || return 1
}

run_test test_retire_leaves_a_settings_file_tracked_in_another_case_to_git

# A git that cannot say whether a checkout tracks settings.local.json has not
# said it does not: the retire refuses with git's own error, naming the file,
# before anything is removed. The stand-in git fails only that question, for
# one checkout, and hands every other call to the real git.
test_retire_refuses_when_git_cannot_say_whether_it_tracks_the_settings() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 real side
    local bindir="$TEST_TMPDIR/git-bin"
    real=$(command -v git) || return 1
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    jq '.permissions.allow = ["Read", "Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$bindir"
    for side in "$wt" "$base_dir"; do
        cat > "$bindir/git" <<EOF
#!/bin/bash
case " \$* " in *" -C $side ls-files "*settings.local.json*)
    echo "fatal: index file corrupt" >&2
    exit 128 ;;
esac
exec "$real" "\$@"
EOF
        chmod +x "$bindir/git"
        status=0
        output=$(PATH="$bindir:$PATH" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "the retire refuses for $side: $output" || return 1
        assert_output_contains "$output" "Error: cs could not ask git whether it tracks $side/.claude/settings.local.json: fatal: index file corrupt. Nothing was removed." \
            "the refusal gives git's own error for $side" || return 1
        assert_dir "$wt/.cs/memory" "nothing was removed" || return 1
        assert_file_not_exists "$base_dir/.claude/settings.local.json" "nothing was carried" || return 1
    done
    # Positive control: with the real git, the rules are carried.
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '["Read","Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" "the rules are carried" || return 1
}

run_test test_retire_refuses_when_git_cannot_say_whether_it_tracks_the_settings

# The retire reads the feature's permission rules only from a file of the
# feature's own. A link at that path, leading anywhere or nowhere, is refused
# by name before anything is removed, whatever the base's file is.
test_retire_refuses_a_feature_settings_file_that_is_a_link() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 target
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    printf '%s\n' '{"permissions": {"allow": ["Bash(make:*)"]}}' > "$TEST_TMPDIR/elsewhere.json"
    rm "$wt/.claude/settings.local.json"
    for target in "$TEST_TMPDIR/elsewhere.json" "$TEST_TMPDIR/nowhere.json"; do
        ln -sf "$target" "$wt/.claude/settings.local.json"
        status=0
        output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
        assert_eq "1" "$status" "the retire refuses a link to $target: $output" || return 1
        assert_output_contains "$output" "Error: $wt/.claude/settings.local.json is a link, and cs reads the feature's permission rules only from a file of its own. Nothing was removed. Put the rules in a file there, or delete the link, then run /finish t1 again." \
            "the refusal names the link to $target" || return 1
        assert_dir "$wt/.cs/memory" "nothing was removed" || return 1
    done
    # A link at the base's path too: the feature's link is still refused.
    mkdir -p "$base_dir/.claude"
    ln -s ../team-settings.json "$base_dir/.claude/settings.local.json"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses with both linked: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude/settings.local.json is a link, and cs reads the feature's permission rules only from a file of its own." \
        "the refusal names the feature's link" || return 1
    rm "$base_dir/.claude/settings.local.json"
    # Positive control: the same rules in a file of the feature's own go.
    rm "$wt/.claude/settings.local.json"
    cp "$TEST_TMPDIR/elsewhere.json" "$wt/.claude/settings.local.json"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '["Bash(make:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" "the rules are carried" || return 1
}

run_test test_retire_refuses_a_feature_settings_file_that_is_a_link

# The retire reads the settings files only to add the feature's rules to the
# base's. One it leaves alone, tracked or behind a link, is never read, so
# what it holds is no reason to refuse.
test_retire_reads_no_settings_file_it_leaves_alone() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 before
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    jq '.permissions.allow = ["Read", "Bash(make:*)"]' "$wt/.claude/settings.local.json" > "$wt/.claude/s.json" \
        && mv "$wt/.claude/s.json" "$wt/.claude/settings.local.json"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    mkdir -p "$base_dir/.claude"
    printf '%s\n' '{"permissions": {"allow": "Read"}}' > "$base_dir/team-settings.json"
    ln -s ../team-settings.json "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add team-settings.json && git commit -q -m "share settings")
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through a link to a file it cannot read: $output" || return 1
    assert_eq '{"permissions": {"allow": "Read"}}' "$(cat "$base_dir/team-settings.json")" "the file is untouched" || return 1
    # With the base's rules unreadable, every rule of the feature's is listed.
    assert_eq "$base_dir/.claude/settings.local.json is a link, and cs writes nothing through it. Add by hand the feature's permission rules it lacks that the base needs:
  allow: \"Read\"
  allow: \"Bash(make:*)\"" "$(printf '%s\n' "$output" | awk '/ is a link, and cs writes nothing through it/ { on = 1 } on && !/^(  |\/)/ { on = 0 } on')" \
        "stdout lists every rule of the feature's: $output" || return 1
    # The same file tracked at the base's own path.
    cs_launch "proj@t2"
    echo "done" > "$CS_SESSIONS_ROOT/proj@t2/result2.txt"
    (cd "$CS_SESSIONS_ROOT/proj@t2" && git add result2.txt && git commit -q -m "task two")
    sha=$(land_feature proj t2) || { echo "  FAIL: integrate fixture"; return 1; }
    rm "$base_dir/.claude/settings.local.json"
    printf '%s\n' '{"permissions": {"allow": "Read"}}' > "$base_dir/.claude/settings.local.json"
    (cd "$base_dir" && git add -f .claude/settings.local.json && git commit -q -m "track settings")
    before=$(cat "$base_dir/.claude/settings.local.json")
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t2" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire goes through a tracked file it cannot read: $output" || return 1
    assert_eq "$before" "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as git left it" || return 1
    assert_eq "" "$(git -C "$base_dir" status --porcelain)" "and the base's checkout is clean" || return 1
}

run_test test_retire_reads_no_settings_file_it_leaves_alone

# The base's .claude can itself be a link inside the session, to a directory
# whose settings.local.json the base tracks, and git sees no file at
# .claude/settings.local.json behind it, ignored or tracked. cs writes nothing
# through that link either: the file is left as git left it, and the retire
# lists on stdout each rule the union would have added, naming the link. A
# .claude that leads out of the session is still refused by the write.
test_retire_writes_no_permission_rules_through_a_linked_claude_dir() {
    local base_dir="$CS_SESSIONS_ROOT/proj" sha1 sha2 sha3 output status=0 before git_before task out
    _ignored_base_with_two_topics
    for task in t1 t2 t3; do
        cs_launch "proj@$task"
        printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(make:*)"]}}' \
            > "$CS_SESSIONS_ROOT/proj@$task/.claude/settings.local.json"
        echo "done" > "$CS_SESSIONS_ROOT/proj@$task/result-$task.txt"
        (cd "$CS_SESSIONS_ROOT/proj@$task" && git add "result-$task.txt" && git commit -q -m "task $task")
    done
    sha1=$(land_feature proj t1) || { echo "  FAIL: integrate fixture t1"; return 1; }
    sha2=$(land_feature proj t2) || { echo "  FAIL: integrate fixture t2"; return 1; }
    sha3=$(land_feature proj t3) || { echo "  FAIL: integrate fixture t3"; return 1; }
    mkdir -p "$base_dir/team-claude"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/team-claude/settings.local.json"
    (cd "$base_dir" && git add -f team-claude/settings.local.json && git commit -q -m "share settings")
    rm -rf "$base_dir/.claude"
    ln -s team-claude "$base_dir/.claude"
    before=$(cat "$base_dir/team-claude/settings.local.json")
    git_before=$(git -C "$base_dir" status --porcelain)
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha1" 2>"$TEST_TMPDIR/stderr") || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output $(cat "$TEST_TMPDIR/stderr")" || return 1
    assert_eq "$before" "$(cat "$base_dir/team-claude/settings.local.json")" "the tracked file is as git left it" || return 1
    assert_eq "$git_before" "$(git -C "$base_dir" status --porcelain)" "and the base's git status is as it was" || return 1
    assert_symlink "$base_dir/.claude" "the link stays" || return 1
    assert_eq "$base_dir/.claude is a link, and cs writes nothing through it. Add by hand the feature's permission rules it lacks that the base needs:
  allow: \"Bash(make:*)\"" "$(printf '%s\n' "$output" | awk '/ is a link, and cs writes nothing through it/ { on = 1 } on && !/^(  |\/)/ { on = 0 } on')" \
        "stdout names the link and lists each rule the union would have added: $output" || return 1
    # A .claude leading out of the session: the write refuses it, as before.
    out="$TEST_TMPDIR/outside-claude"
    mkdir -p "$out"
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$out/settings.local.json"
    rm "$base_dir/.claude"
    ln -s "$out" "$base_dir/.claude"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t3" "$sha3" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses a .claude out of the session: $output" || return 1
    assert_output_contains "$output" "cs_mkdir_inside: $base_dir/.claude leads to $(cd "$out" && pwd -P), outside the session $base_dir" \
        "the refusal names where the link leads" || return 1
    assert_output_contains "$output" "Error: Could not add the feature's permission rules to $base_dir/.claude/settings.local.json; nothing was removed" \
        "the refusal names the file" || return 1
    assert_dir "$CS_SESSIONS_ROOT/proj@t3/.cs/memory" "nothing was removed" || return 1
    assert_eq '{"permissions": {"allow": ["Read"]}}' "$(cat "$out/settings.local.json")" "the outside file is untouched" || return 1
    # The base tracks the link itself.
    rm "$base_dir/.claude"
    ln -s team-claude "$base_dir/.claude"
    (cd "$base_dir" && git add .claude && git commit -q -m "share .claude")
    assert_eq "" "$(git -C "$base_dir" ls-files -- .claude/settings.local.json)" "git sees no file behind the tracked link" || return 1
    git_before=$(git -C "$base_dir" status --porcelain)
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t2" "$sha2" 2>"$TEST_TMPDIR/stderr") || status=$?
    assert_eq "0" "$status" "the retire succeeds past a tracked link: $output $(cat "$TEST_TMPDIR/stderr")" || return 1
    assert_eq "$before" "$(cat "$base_dir/team-claude/settings.local.json")" "the tracked file is as git left it, past a tracked link" || return 1
    assert_eq "$git_before" "$(git -C "$base_dir" status --porcelain)" "and the base's git status is as it was, past a tracked link" || return 1
    assert_eq "$base_dir/.claude is a link, and cs writes nothing through it. Add by hand the feature's permission rules it lacks that the base needs:
  allow: \"Bash(make:*)\"" "$(printf '%s\n' "$output" | awk '/ is a link, and cs writes nothing through it/ { on = 1 } on && !/^(  |\/)/ { on = 0 } on')" \
        "stdout names the tracked link and lists the rules: $output" || return 1
}

run_test test_retire_writes_no_permission_rules_through_a_linked_claude_dir

# A feature can commit its .claude as a link, and git sees no file behind a
# linked directory on that side either. One cs cannot follow to a directory
# inside the worktree, because it leads out or through more links than cs
# follows, is refused by name before anything is removed, whether the feature
# landed through the integrate or is retired with --force: cs reads the
# feature's rules only from a file inside the worktree.
test_retire_refuses_a_feature_claude_dir_that_links_out_of_the_worktree() {
    local base_dir="$CS_SESSIONS_ROOT/proj" sha1 sha2 output status=0 task wt hop
    local out="$TEST_TMPDIR/outside-claude"
    _ignored_base_with_two_topics
    mkdir -p "$out"
    printf '%s\n' '{"permissions": {"allow": ["Bash(elsewhere:*)"]}}' > "$out/settings.local.json"
    for task in t1 t2; do
        wt="$CS_SESSIONS_ROOT/proj@$task"
        cs_launch "proj@$task"
        rm -rf "$wt/.claude"
        ln -s "$out" "$wt/.claude"
        echo "done" > "$wt/result-$task.txt"
        (cd "$wt" && git add "result-$task.txt" .claude && git commit -q -m "task $task")
    done
    sha1=$(git -C "$CS_SESSIONS_ROOT/proj@t1" rev-parse HEAD)
    # Landed, then the base puts a directory of its own in the link's place.
    sha2=$(land_feature proj t2) || { echo "  FAIL: integrate fixture t2"; return 1; }
    (cd "$base_dir" && git rm -q .claude && mkdir .claude && echo x > .claude/keep \
        && git add .claude/keep && git commit -q -m "a .claude of the base's own")
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/settings.local.json"
    output=$("$CS_BIN" "proj" -retire-feature "t2" "$sha2" 2>&1) || status=$?
    wt="$CS_SESSIONS_ROOT/proj@t2"
    assert_eq "1" "$status" "the retire refuses a landed feature: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude is a link cs cannot follow to a directory inside $wt, and cs reads the feature's permission rules only from a file inside it. Nothing was removed. Replace the link with a directory of the feature's own, or remove it, and commit that, then run /finish t2 again." \
        "the refusal names the landed feature's link" || return 1
    assert_dir "$wt/.cs/memory" "the landed feature's worktree is still there" || return 1
    assert_eq '{"permissions": {"allow": ["Read"]}}' "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was" || return 1
    # Not landed, retired with --force.
    wt="$CS_SESSIONS_ROOT/proj@t1"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha1" --force 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses with --force: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude is a link cs cannot follow to a directory inside $wt, and cs reads the feature's permission rules only from a file inside it. Nothing was removed. Replace the link with a directory of the feature's own, or remove it, and commit that, then run /finish t1 again." \
        "the refusal names the link with --force" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there with --force" || return 1
    assert_eq '{"permissions": {"allow": ["Read"]}}' "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was with --force" || return 1
    assert_eq '{"permissions": {"allow": ["Bash(elsewhere:*)"]}}' "$(cat "$out/settings.local.json")" "the outside file is untouched" || return 1
    # A chain of 18 links that ends inside the worktree: the kernel follows
    # it, and cs follows 16.
    mkdir "$wt/.cs/local/claude"
    cp "$out/settings.local.json" "$wt/.cs/local/claude/settings.local.json"
    ln -s claude "$wt/.cs/local/hop17"
    for hop in 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
        ln -s "hop$((hop + 1))" "$wt/.cs/local/hop$hop"
    done
    rm "$wt/.claude"
    ln -s .cs/local/hop1 "$wt/.claude"
    (cd "$wt" && git add .claude && git commit -q -m "a long chain")
    sha1=$(git -C "$wt" rev-parse HEAD)
    assert_eq '{"permissions": {"allow": ["Bash(elsewhere:*)"]}}' "$(cat "$wt/.claude/settings.local.json")" "the kernel follows the chain" || return 1
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha1" --force 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses a chain it cannot follow: $output" || return 1
    assert_output_contains "$output" "Error: $wt/.claude is a link cs cannot follow to a directory inside $wt, and cs reads the feature's permission rules only from a file inside it. Nothing was removed." \
        "the refusal names the link at the head of the chain" || return 1
    assert_dir "$wt/.cs/memory" "the worktree is still there past the chain" || return 1
    assert_eq '{"permissions": {"allow": ["Read"]}}' "$(cat "$base_dir/.claude/settings.local.json")" "the base's file is as it was past the chain" || return 1
    # Positive control: the same rules in a directory of the feature's own go.
    rm "$wt/.claude"
    mkdir "$wt/.claude"
    cp "$out/settings.local.json" "$wt/.claude/settings.local.json"
    (cd "$wt" && git add -A .claude && git commit -q -m "a .claude of the feature's own")
    sha1=$(git -C "$wt" rev-parse HEAD)
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha1" --force 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '["Read","Bash(elsewhere:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" "the rules are carried" || return 1
}

run_test test_retire_refuses_a_feature_claude_dir_that_links_out_of_the_worktree

# A feature .claude that links to a directory inside the worktree is read
# where it leads. A settings file git tracks there is git's to carry, like one
# tracked at .claude/settings.local.json: nothing is added to the base's. One
# git does not track there is the feature's own file, and its rules go. Only
# cs's own directories under .cs can hold such a file without the retire
# refusing it as untracked work.
test_retire_asks_git_about_the_file_a_feature_claude_link_leads_to() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    cs_launch "proj@t2"
    rm -rf "$wt/.claude"
    mkdir "$wt/team-claude"
    printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(make:*)"]}}' > "$wt/team-claude/settings.local.json"
    ln -s team-claude "$wt/.claude"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt .claude team-claude/settings.local.json && git commit -q -m "task")
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    (cd "$base_dir" && git rm -q .claude && mkdir .claude && echo x > .claude/keep \
        && git add .claude/keep && git commit -q -m "a .claude of the base's own")
    printf '%s\n' '{"permissions": {"allow": ["Read"]}}' > "$base_dir/.claude/settings.local.json"
    assert_eq "team-claude/settings.local.json" "$(git -C "$wt" ls-files -- team-claude .claude/settings.local.json)" \
        "the feature tracks the file where the link leads, and git sees none behind the link" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds: $output" || return 1
    assert_eq '{"permissions": {"allow": ["Read"]}}' "$(cat "$base_dir/.claude/settings.local.json")" \
        "nothing is added from a file git tracks where the link leads" || return 1
    assert_output_not_contains "$output" "is a link" "and nothing is said about a link" || return 1
    # A link into .cs/local, to a file git does not track.
    wt="$CS_SESSIONS_ROOT/proj@t2"
    rm -rf "$wt/.claude"
    mkdir "$wt/.cs/local/claude"
    printf '%s\n' '{"permissions": {"allow": ["Read", "Bash(lint:*)"]}}' > "$wt/.cs/local/claude/settings.local.json"
    ln -s .cs/local/claude "$wt/.claude"
    echo "done" > "$wt/result2.txt"
    (cd "$wt" && git add result2.txt .claude && git commit -q -m "task two")
    sha=$(git -C "$wt" rev-parse HEAD)
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t2" "$sha" --force 2>&1) || status=$?
    assert_eq "0" "$status" "the retire succeeds for a file git does not track: $output" || return 1
    assert_eq '["Read","Bash(lint:*)"]' "$(jq -c .permissions.allow "$base_dir/.claude/settings.local.json")" \
        "the rules of a file git does not track are carried" || return 1
}

run_test test_retire_asks_git_about_the_file_a_feature_claude_link_leads_to

# The record of what the feature inherited is what tells a deleted topic from
# a new one. A record that is there and cannot be read must stop the fuse:
# guessing "new" would bring the deleted topic back and report success.
test_retire_ignored_mode_refuses_when_the_inherited_record_cannot_be_read() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    local odd=$'g\e[1mone\a caf\xc3\xa9 \xe2\x80\xaedm.exe\xe2\x80\x8b.md'
    _ignored_base_with_two_topics
    echo "odd topic" > "$base_dir/.cs/memory/$odd"
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    rm "$base_dir/.cs/memory/$odd"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 000 "$wt/.cs/local/inherited-topics/$odd"
    [ ! -r "$wt/.cs/local/inherited-topics/$odd" ] || return 77
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    find "$CS_SESSIONS_ROOT" -path '*/local/inherited-topics/*' -type f -exec chmod 600 {} + 2>/dev/null
    assert_eq "1" "$status" "the retire fails: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/$odd" "the deleted topic did not come back" || return 1
    assert_eq "could not read what the feature inherited for memory/g?[1mone? caf"$'\xc3\xa9'" ?dm.exe?.md, so cs cannot tell whether the base deleted or changed it" \
        "$(printf '%s\n' "$output" | grep -F 'could not read what the feature inherited')" \
        "the error names the topic, each control byte and each direction or zero-width character in its name as one ?" || return 1
    assert_no_escape_bytes "$output" "no escape byte in the name reaches the terminal" || return 1
    assert_output_contains "$output" "Could not classify the session records in $wt/.cs; nothing was removed" \
        "the retire refuses before it removes anything" || return 1
    assert_dir "$wt/.cs/memory" "the worktree and its records are still there" || return 1
}

run_test test_retire_ignored_mode_refuses_when_the_inherited_record_cannot_be_read

# The same when the record directory itself cannot be searched: a file that
# cannot be seen inside it is not a topic the feature wrote.
test_retire_ignored_mode_refuses_when_the_inherited_directory_cannot_be_searched() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    rm "$base_dir/.cs/memory/gone.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    chmod 000 "$wt/.cs/local/inherited-topics"
    if [ -e "$wt/.cs/local/inherited-topics/gone.md" ]; then
        chmod 700 "$wt/.cs/local/inherited-topics"; return 77
    fi
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    find "$CS_SESSIONS_ROOT" -type d -name inherited-topics -exec chmod 700 {} + 2>/dev/null
    assert_eq "1" "$status" "the retire fails: $output" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/gone.md" "the deleted topic did not come back" || return 1
    assert_output_contains "$output" "could not read what the feature inherited for memory/gone.md" \
        "the error names the topic" || return 1
    assert_dir "$wt/.cs/memory" "the worktree and its records are still there" || return 1
}

run_test test_retire_ignored_mode_refuses_when_the_inherited_directory_cannot_be_searched

# The list of files a removal would destroy is read as bytes. In a locale
# that cannot decode a name, a failed conversion must never read as "nothing
# to lose": the retire would force-remove the worktree and the user's
# ignored file with it instead of moving it to the trash.
test_retire_trashes_ignored_work_when_a_name_does_not_decode_in_the_locale() {
    # A multibyte locale that is not UTF-8 and in which bash still parses cs.
    local loc
    loc=$(locale -a 2>/dev/null | grep -m1 -x -e 'zh_CN\.GBK' -e 'ja_JP\.SJIS' -e 'zh_TW\.Big5') || true
    [ -n "$loc" ] || { echo "    SKIP (no GBK, SJIS or Big5 locale here)"; return 77; }
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    (cd "$base_dir" && echo 'secret.env' >> .gitignore && git commit -q -am "ignore the env file")
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "snow" > "$wt/.cs/memory/$(printf '\342\230\203').md"
    # The records fused at retire are UTF-8 whatever the locale: a pointer
    # and a narrative note holding a character GBK cannot decode.
    printf -- '- [Snow \342\200\224 notes](snow.md): a topic\n' >> "$wt/.cs/memory/MEMORY.md"
    echo "snow topic" > "$wt/.cs/memory/snow.md"
    printf -- '---\nname: n\n---\nbase note\n' > "$base_dir/.cs/memory/narrative.alice.md"
    printf -- '---\nname: n\n---\nfeature note \342\200\224 done\n' > "$wt/.cs/memory/narrative.alice.md"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    # Ignored, so git lists it after the .cs entries: past the name the
    # conversion stops on.
    echo "valuable" > "$wt/secret.env"
    local bin
    bin=$(fake_trash_bin moves trash)
    output=$(PATH="$bin:$PATH" LC_ALL="$loc" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "$wt/secret.env" "$(cat "$TEST_TMPDIR/trash.log")" "the ignored file goes to the trash" || return 1
    assert_eq "valuable" "$(cat "$TEST_TMPDIR/trash-bin/1-secret.env")" "intact" || return 1
    assert_eq "- [Snow $(printf '\342\200\224') notes](snow.md): a topic" "$(tail -n 1 "$base_dir/.cs/memory/MEMORY.md")" \
        "the feature's pointer reaches the base index" || return 1
    assert_eq "---
name: n
---
base note
feature note $(printf '\342\200\224') done" "$(cat "$base_dir/.cs/memory/narrative.alice.md")" \
        "the feature's narrative note is appended to the base's" || return 1
}

run_test test_retire_trashes_ignored_work_when_a_name_does_not_decode_in_the_locale

test_retire_fuse_survives_a_torn_timeline_tail() {
    # A crash mid-append leaves a last line with no newline. Appending onto it
    # splices two records into one, and the reader's tolerant `fromjson? //
    # empty` then drops BOTH — the splice and the record that followed it.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add -A && git commit -q -m init)
    # Torn tail: the last record has no terminating newline.
    printf '{"event":"base-last"}' > "$base_dir/.cs/timeline.jsonl"
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    printf '{"event":"from-task"}\n' > "$wt/.cs/timeline.jsonl"
    # Fixture sanity: the base tail really is unterminated, or the splice the
    # test is about cannot happen.
    assert_eq "}" "$(tail -c 1 "$base_dir/.cs/timeline.jsonl")" \
        "fixture must leave the base timeline unterminated" || return 1

    local output merge_status
    local sha
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "retire exits 0" \
        || { echo "  retire output: $output"; return 1; }

    # Parse the way cs reads it: one record per line, malformed lines dropped.
    local events
    events=$(jq -rRs '[split("\n")[] | select(length > 0) | (fromjson? // empty) | .event] | join(",")' \
        "$base_dir/.cs/timeline.jsonl" 2>/dev/null)
    assert_output_contains "$events" "base-last" \
        "the torn base record must survive the fuse" || return 1
    assert_output_contains "$events" "from-task" \
        "the fused record must survive the fuse" || return 1
}

run_test test_retire_fuse_survives_a_torn_timeline_tail

# Whether the retire fuses .cs or leaves it to git depends on the mode the
# create recorded. A state file without one says neither, so nothing under
# .cs is known to be carried: the retire refuses and the worktree stays.
test_retire_refuses_a_worktree_whose_state_names_no_mode() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0
    _ignored_base_with_two_topics
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "feature topic" > "$wt/.cs/memory/new.md"
    grep -v '^cs_mode:' "$wt/.cs/local/state" > "$wt/.cs/local/state.tmp"
    mv "$wt/.cs/local/state.tmp" "$wt/.cs/local/state"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "$wt/.cs/local/state names no cs_mode, so cs cannot tell whether git or the record fuse carries $wt/.cs; nothing was removed" \
        "the refusal names the state file" || return 1
    assert_eq "feature topic" "$(cat "$wt/.cs/memory/new.md" 2>/dev/null)" "the feature's topic is still there" || return 1
    assert_file_not_exists "$base_dir/.cs/memory/new.md" "and nothing was fused" || return 1
}

run_test test_retire_refuses_a_worktree_whose_state_names_no_mode

# A tracked file marked skip-worktree (or assume-unchanged) hides its edit
# from git diff, and git keeps no copy of the edit: removal would destroy it.
# The refusal shows each control character in a name, and each character
# that flips the direction of the text after it or takes no room, as one "?".
test_retire_refuses_an_edit_git_diff_does_not_show() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" sha output status=0 name
    local shown=$'esc?[31m?line ?lmy.exe? caf\xc3\xa9.yml'
    name=$'esc\033[31m\nline \xe2\x80\xaelmy.exe\xe2\x80\x8b caf\xc3\xa9.yml'
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    echo "default: 1" > "$base_dir/config.yml"
    echo "default: 2" > "$base_dir/other.yml"
    echo "default: 3" > "$base_dir/$name"
    ln -s defaults-a "$base_dir/profile"
    printf 'defaults-a' > "$base_dir/alias"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    git -C "$wt" update-index --skip-worktree config.yml
    echo "local: tuned" >> "$wt/config.yml"
    git -C "$wt" update-index --skip-worktree -- "$name"
    echo "local: tuned as well" >> "$wt/$name"
    git -C "$wt" update-index --assume-unchanged other.yml
    echo "local: tuned too" >> "$wt/other.yml"
    git -C "$wt" update-index --assume-unchanged profile
    ln -sfn defaults-b "$wt/profile"
    # A link whose target spells the file's old bytes: same blob, other type.
    git -C "$wt" update-index --assume-unchanged alias
    rm "$wt/alias" && ln -s defaults-a "$wt/alias"
    sha=$(land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has edits git diff does not show (skip-worktree or assume-unchanged), which removal would destroy; commit them, or undo them and clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged), first:" \
        "the refusal says why" || return 1
    assert_eq "alias
config.yml
$shown
other.yml
profile" "$(printf '%s\n' "$output" | awk 'listed; /first:$/ { listed = 1 }')" "the refusal names the three files, the retargeted link and the file now a link" || return 1
    assert_eq "default: 1
local: tuned" "$(cat "$wt/config.yml")" "the edit is still there" || return 1
    assert_eq "defaults-b" "$(readlink "$wt/profile")" "the link still has its new target" || return 1
    # Positive control: an unedited flagged file or link is no reason to refuse.
    git -C "$wt" update-index --no-assume-unchanged other.yml
    git -C "$wt" checkout -q -- other.yml
    git -C "$wt" update-index --no-skip-worktree -- "$name"
    git -C "$wt" checkout -q -- "$name"
    git -C "$wt" show HEAD:config.yml > "$wt/config.yml"
    ln -sfn defaults-a "$wt/profile"
    rm "$wt/alias" && printf 'defaults-a' > "$wt/alias"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "an unedited flagged file retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_an_edit_git_diff_does_not_show

# An initialised submodule is a checkout of its own: git ls-files in the
# worktree does not list the files inside it, and removal destroys them.
test_retire_refuses_untracked_and_ignored_work_inside_a_submodule() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" lib="$TEST_TMPDIR/sublib"
    local sha output status=0
    mkdir -p "$lib"
    (cd "$lib" && git init -q && git config core.autocrlf false && echo lib > lib.txt \
        && printf '*.env\n' > .gitignore && git add -A && git commit -q -m lib)
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init \
        && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
            git submodule add -q "$lib" sub && git commit -q -m "add submodule") \
        || { echo "  FAIL: submodule fixture"; return 1; }
    cs_launch "proj@t1"
    (cd "$wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        git submodule update --init -q) \
        || { echo "  FAIL: submodule fixture"; return 1; }
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo "secret" > "$wt/sub/secret.env"
    echo "notes" > "$wt/sub/notes.txt"
    # The integrate updates submodules in its temporary worktree.
    sha=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: Worktree has 2 untracked files that removal would destroy; commit or remove them first:
    sub/notes.txt
    sub/secret.env" "$output" "the refusal names both files inside the submodule" || return 1
    assert_eq "secret" "$(cat "$wt/sub/secret.env" 2>/dev/null)" "the ignored file is still there" || return 1
    # Positive control: an initialised submodule holding nothing extra retires.
    rm "$wt/sub/secret.env" "$wt/sub/notes.txt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "a clean submodule retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_untracked_and_ignored_work_inside_a_submodule

# A landed feature proj@t1 whose base holds the submodule vendor/sub,
# initialised in the base, and ignores *.log. git worktree add leaves
# vendor/sub empty in the feature's worktree: the submodule is never
# populated there. Prints the landed sha.
_landed_feature_beside_an_unpopulated_submodule() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" lib="$TEST_TMPDIR/sublib"
    mkdir -p "$lib"
    (cd "$lib" && git init -q && git config core.autocrlf false && echo lib > lib.txt \
        && git add -A && git commit -q -m lib) || return 1
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n*.log\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init \
        && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
            git submodule add -q "$lib" vendor/sub && git commit -q -m "add submodule") || return 1
    cs_launch "proj@t1"
    [ -d "$wt/vendor/sub" ] && [ ! -e "$wt/vendor/sub/.git" ] && [ -z "$(ls -A "$wt/vendor/sub")" ] || return 1
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task") || return 1
    # The integrate updates submodules in its temporary worktree.
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always land_feature proj t1
}

# git lists nothing inside a directory its index holds as a submodule, so
# files written into one the worktree never populated are invisible to git
# status, and removal destroys them: the retire refuses and names them, and
# readiness counts them. The trash is never run.
test_retire_refuses_files_in_a_submodule_directory_never_populated() {
    local wt="$CS_SESSIONS_ROOT/proj@t1" sha bin line output status=0
    sha=$(_landed_feature_beside_an_unpopulated_submodule) || { echo "  FAIL: submodule fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    mkdir -p "$wt/vendor/sub/build"
    echo "notes" > "$wt/vendor/sub/build/notes.txt"
    echo "KEY=value" > "$wt/vendor/sub/local.env"
    assert_eq "" "$(git -C "$wt" status --porcelain --ignored -- vendor)" "fixture: git status shows nothing there" || return 1
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "2" "$(_feat_field "$line" 7)" "readiness counts both files: $line" || return 1
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_eq "Error: Worktree has 2 untracked files that removal would destroy; commit or remove them first:
    vendor/sub/build/  (1 file)
    vendor/sub/local.env" "$output" "the refusal names both files under the submodule's path" || return 1
    assert_eq "notes" "$(cat "$wt/vendor/sub/build/notes.txt")" "the file is still there" || return 1
    assert_not_exists "$TEST_TMPDIR/trash.log" "the trash command is never run" || return 1
    # Positive control: the empty submodule directory retires.
    rm -r "$wt/vendor/sub/build" "$wt/vendor/sub/local.env"
    status=0
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "an empty submodule directory retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_files_in_a_submodule_directory_never_populated

# An ignored file beside a submodule the worktree never populated is an
# entry of its own: the directory holding both is not collapsed, so the
# trash gets that file and nothing at or above the submodule's path.
test_retire_trashes_only_the_ignored_file_beside_an_unpopulated_submodule() {
    local wt="$CS_SESSIONS_ROOT/proj@t1" sha bin output status=0
    sha=$(_landed_feature_beside_an_unpopulated_submodule) || { echo "  FAIL: submodule fixture"; return 1; }
    bin=$(fake_trash_bin moves trash)
    echo "trace" > "$wt/vendor/trace.log"
    output=$(PATH="$bin:$PATH" "$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "the retire proceeds: $output" || return 1
    assert_eq "MEMORY.md: appended 1 pointer(s) from the feature (base lines kept)
Moved 1 ignored file to the system trash:
    $wt/vendor/trace.log
retired t1 $sha" "$output" "retire names the one file it moved" || return 1
    assert_eq "$wt/vendor/trace.log" "$(cat "$TEST_TMPDIR/trash.log")" "the trash gets the file, not its directory" || return 1
    assert_eq "trace" "$(cat "$TEST_TMPDIR/trash-bin/1-trace.log")" "the file is in the trash, intact" || return 1
}

run_test test_retire_trashes_only_the_ignored_file_beside_an_unpopulated_submodule

# A submodule keeps its own index, so a flagged file inside it hides its edit
# from the submodule's git diff and from the worktree's: removal destroys it.
# The refusal shows a control character in the submodule's path as "?".
test_retire_refuses_an_edit_git_diff_does_not_show_inside_a_submodule() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" lib="$TEST_TMPDIR/sublib"
    local sha output line status=0 sub="sub"$'\033'"x"
    mkdir -p "$lib"
    (cd "$lib" && git init -q && git config core.autocrlf false && echo lib > lib.txt \
        && git add -A && git commit -q -m lib)
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init \
        && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
            git submodule add -q "$lib" "$sub" && git commit -q -m "add submodule") \
        || { echo "  FAIL: submodule fixture"; return 1; }
    cs_launch "proj@t1"
    (cd "$wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        git submodule update --init -q) \
        || { echo "  FAIL: submodule fixture"; return 1; }
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    git -C "$wt/$sub" update-index --assume-unchanged lib.txt
    echo "local: tuned" >> "$wt/$sub/lib.txt"
    # The integrate updates submodules in its temporary worktree.
    sha=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        land_feature proj t1) || { echo "  FAIL: integrate fixture"; return 1; }
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "1" "$(_feat_field "$line" 6)" "wt_dirty: $line" || return 1
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the retire refuses: $output" || return 1
    assert_output_contains "$output" "Worktree has edits git diff does not show (skip-worktree or assume-unchanged), which removal would destroy; commit them, or undo them and clear the flag (git update-index --no-skip-worktree / --no-assume-unchanged), first:" \
        "the refusal says why" || return 1
    assert_eq "sub?x/lib.txt" "$(printf '%s\n' "$output" | awk 'listed; /first:$/ { listed = 1 }')" \
        "the refusal names the file inside the submodule" || return 1
    assert_eq "lib
local: tuned" "$(cat "$wt/$sub/lib.txt")" "the edit is still there" || return 1
    # Positive control: the flagged file left as committed retires.
    echo lib > "$wt/$sub/lib.txt"
    status=0
    output=$("$CS_BIN" "proj" -retire-feature "t1" "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "an unedited flagged file in a submodule retires: $output" || return 1
    assert_not_exists "$wt" "the worktree is retired" || return 1
}

run_test test_retire_refuses_an_edit_git_diff_does_not_show_inside_a_submodule

test_rm_worktree_unregisters_and_prompts_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Confirm removal, decline branch deletion
    printf 'y\nn\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm "myproj@fix-auth" > /dev/null 2>&1
    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept when declined" || return 1
}

test_rm_worktree_force_noninteractive_keeps_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    "$CS_BIN" -rm "myproj@fix-auth" --force </dev/null >/dev/null 2>&1 || return 1

    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    # The nested branch-delete question defaults to NO under --force: this
    # assertion pins that rule, not just that removal succeeded.
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept under --force with no tty" || return 1
}

run_test test_rm_worktree_unregisters_and_prompts_branch
run_test test_rm_worktree_force_noninteractive_keeps_branch

test_doctor_flags_dangling_and_merged_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@done-task"
    # Simulate a completed-but-unmerged-cleanup state: merge manually.
    # --no-ff so the base HEAD moves past the branch tip; a fast-forward
    # would leave tip == HEAD, indistinguishable from a fresh worktree.
    (cd "$CS_SESSIONS_ROOT/myproj@done-task" && echo x > f && git add f && git commit -q -m t)
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/done-task)
    # And a dangling dir that git does not know about
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost/.cs/local"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_contains "$output" "ghost" "dangling @-dir flagged" || return 1
    assert_output_contains "$output" "myproj@done-task branch cs/done-task is fully merged" \
        "merged-but-present worktree flagged" || return 1
}

run_test test_doctor_flags_dangling_and_merged_worktrees

test_doctor_fresh_worktree_not_flagged_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fresh-task"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_not_contains "$output" "fully merged" \
        "fresh worktree (tip == base HEAD) must not read as merged" || return 1
    assert_output_contains "$output" "Worktrees: myproj@fresh-task on cs/fresh-task" \
        "fresh worktree reported OK" || return 1
}

run_test test_doctor_fresh_worktree_not_flagged_merged


test_retire_refuses_untracked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "committed" > "$wt/done.txt"
    (cd "$wt" && git add done.txt && git commit -q -m work)
    echo "precious" > "$wt/never-added.txt"   # untracked user work
    local output status=0
    local sha
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    output=$("$CS_BIN" "myproj" -retire-feature "fix-auth" "$sha" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: retire must refuse"; return 1; }
    assert_output_contains "$output" "untracked" "refusal names the problem" || return 1
    assert_output_contains "$output" "never-added.txt" "refusal names the exact path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "precious" "$(cat "$wt/never-added.txt")" "untracked work survives" || return 1
}

run_test test_retire_refuses_untracked_worktree

test_worktree_secrets_flag_targets_base_namespace() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create the worktree first
    local output
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1)
    assert_output_contains "$output" "session: myproj" \
        "worktree -secrets flag must target the base namespace" || return 1
    assert_output_not_contains "$output" "session: myproj@fix-auth" \
        "must not target the nonexistent worktree namespace" || return 1
}

run_test test_worktree_secrets_flag_targets_base_namespace

# Codex r3 #3: a worktree's secrets route to the base session, so the base
# is vetted too; a base link out of the session refuses the verb.
test_worktree_secrets_flag_vets_the_base_session() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local outside="$TEST_TMPDIR/outside-private" output status=0
    mkdir -p "$outside"
    ln -s "$outside" "$CS_SESSIONS_ROOT/myproj/.cs/private"
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1) || status=$?
    assert_eq "1" "$status" "cs should exit 1" || return 1
    assert_eq "Error: .cs/private is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
        "$output" "the refusal names the base's link" || return 1
}

run_test test_worktree_secrets_flag_vets_the_base_session


test_worktree_create_dirty_base_consent_yes() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "consented creation should launch, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@t1" "worktree created after consent" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/myproj@t1/.cs/local/state" "task_branch: cs/t1" \
        "worktree fully initialized" || return 1
}

test_worktree_create_dirty_base_consent_no() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "declined consent cancels cleanly, got: $output" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@t1" "no worktree without consent" || return 1
}

# A base whose index tracks .cs gives its features tracked mode, which expects
# the checkout to carry .cs. Two checkouts do not: a cs/<feature> branch made
# before the base tracked .cs, and a new branch cut from a HEAD that does not
# hold the .cs the user has staged, after "y" at the dirty-base prompt.
# Creating the feature is creating a session, so cs makes its .cs and the
# feature opens, then opens again resuming its conversation, like any other.
_base_tracking_cs_since_its_second_commit() {  # base_dir, [branch made at the first commit]
    mkdir -p "$1"
    echo "# P" > "$1/README.md"
    (cd "$1" && git init -q && git add -A && git commit -q -m init) || return 1
    [ -z "${2:-}" ] || git -C "$1" branch "$2" || return 1
    mkdir -p "$1/.cs/memory"
    printf '# Session: proj\n' > "$1/.cs/README.md"
    printf '.cs/local/\n.claude/settings.local.json\nCLAUDE.local.md\n' > "$1/.gitignore"
    git -C "$1" add -A
}

test_tracked_feature_opens_on_a_branch_older_than_the_base_cs() {
    local base="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" out rc=0
    _base_tracking_cs_since_its_second_commit "$base" cs/t1 || { echo "  FAIL: fixture"; return 1; }
    git -C "$base" commit -q -m "track .cs"
    out=$("$CS_BIN" "proj@t1" < /dev/null 2>&1) || rc=$?
    assert_eq "0" "$rc" "the feature opens: $out" || return 1
    assert_eq "cs/t1 tracked proj" \
        "$(_read_state_keys "$wt/.cs/local/state" task_branch cs_mode cs_base)" "its state names the branch, the mode and the base" || return 1
    rc=0
    out=$("$CS_BIN" "proj@t1" <<< "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the feature opens again, resuming: $out" || return 1
}

test_tracked_feature_opens_from_a_head_without_the_staged_cs() {
    local base="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" out rc=0
    _base_tracking_cs_since_its_second_commit "$base" || { echo "  FAIL: fixture"; return 1; }
    out=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" "proj@t1" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the feature opens after the consent: $out" || return 1
    assert_eq "cs/t1 tracked proj" \
        "$(_read_state_keys "$wt/.cs/local/state" task_branch cs_mode cs_base)" "its state names the branch, the mode and the base" || return 1
    rc=0
    out=$("$CS_BIN" "proj@t1" <<< "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the feature opens again, resuming: $out" || return 1
}

# The values of <keys> in a state file, space-joined in the order asked.
_read_state_keys() {  # state, key...
    local state="$1" key out=""
    shift
    for key in "$@"; do
        out="$out $(sed -n "s/^$key: //p" "$state" 2>/dev/null)"
    done
    printf '%s\n' "${out# }"
}

run_test test_tracked_feature_opens_on_a_branch_older_than_the_base_cs
run_test test_tracked_feature_opens_from_a_head_without_the_staged_cs
run_test test_worktree_create_dirty_base_consent_yes
run_test test_worktree_create_dirty_base_consent_no
run_test test_session_repo_pins_autocrlf_off
run_test test_worktree_excludes_protocol_file

test_features_lists_only_verified_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # A directory that looks like a worktree but was never registered with git.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@hand-made/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "fix-auth" "a registered worktree is listed" || return 1
    assert_output_not_contains "$output" "hand-made" "an unregistered lookalike must be excluded" || return 1
}

run_test test_features_lists_only_verified_worktrees

test_features_is_empty_for_a_base_with_no_worktrees() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_eq "" "$output" "a base with no features prints nothing" || return 1
}

run_test test_features_is_empty_for_a_base_with_no_worktrees

test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one() {
    # The verification compares whole lines. A one-sided anchor would verify
    # "wip" against the registered "wip-2", which is precisely the unregistered
    # directory this function exists to exclude. Prefix-colliding task names are
    # ordinary, so this is a realistic collision, not a contrived one.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    mkdir -p "$CS_SESSIONS_ROOT/myproj@wip/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "wip-2" "the registered worktree is listed" || return 1
    assert_output_not_contains "$output" $'^wip\t' "an unregistered prefix must not verify" || return 1
}

run_test test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one

test_features_untracked_is_not_reported_as_dirty() {
    # _tree_is_dirty deliberately excludes untracked files: a worktree holding
    # only untracked files is NOT dirty, but is still refused, by a different
    # gate with a different message. A porcelain-non-empty test would conflate
    # them and the screen would disagree with the gate.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 6)" "untracked files must not set wt_dirty" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the untracked file must be counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_untracked_is_not_reported_as_dirty

# Readiness agrees with the retire gate: an ignored file does not block a
# retire (it goes to the trash), so it is not counted as untracked work.
test_features_does_not_count_ignored_files_as_untracked() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" line
    printf '.env\n' >> "$(git -C "$wt" rev-parse --git-common-dir)/info/exclude"
    echo "KEY=value" > "$wt/.env"
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 7)" "an ignored file is not untracked work" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "the feature is ready" || return 1
}

run_test test_features_does_not_count_ignored_files_as_untracked

# The features screen reads the same fact the retire refuses on.
test_features_reports_an_edit_git_diff_does_not_show_as_dirty() {
    local base_dir="$CS_SESSIONS_ROOT/proj" wt="$CS_SESSIONS_ROOT/proj@t1" line
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    echo "default: 1" > "$base_dir/config.yml"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    git -C "$wt" update-index --skip-worktree config.yml
    echo "local: tuned" >> "$wt/config.yml"
    line=$("$CS_BIN" proj -features --porcelain 2>&1)
    assert_eq "1" "$(_feat_field "$line" 6)" "wt_dirty: $line" || return 1
    assert_eq "dirty" "$(_feat_field "$line" 10)" "state: $line" || return 1
}

run_test test_features_reports_an_edit_git_diff_does_not_show_as_dirty

test_features_does_not_count_the_bookkeeping_the_merge_gate_skips() {
    # A worktree created before cs excluded its own bookkeeping still has .cs/
    # untracked. The merge gate filters exactly that set and would succeed, so
    # readiness reporting "blocked" sends the user hunting for work to commit
    # that is not theirs and does not exist.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"

    local exclude
    exclude=$( (cd "$wt" && git rev-parse --git-path info/exclude) 2>/dev/null )
    case "$exclude" in /*|[A-Za-z]:[\\/]*) : ;; *) exclude="$wt/$exclude" ;; esac
    grep -v -e '^\.cs/$' -e '^\.claude/settings\.local\.json$' "$exclude" > "$exclude.tmp" 2>/dev/null || true
    mv "$exclude.tmp" "$exclude"
    # Fixture sanity: without the entry the skeleton really is untracked again,
    # so the readiness path is reached with something to filter.
    local others
    others=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)
    case "$others" in
        *.cs/*) : ;;
        *) echo "  FAIL: fixture did not reproduce the untracked .cs skeleton"; return 1 ;;
    esac

    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 7)" \
        "cs's own bookkeeping is not untracked work" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" \
        "readiness must agree with the gate that would let this merge through" || return 1
}

run_test test_features_does_not_count_the_bookkeeping_the_merge_gate_skips

test_features_still_counts_real_untracked_work_in_an_old_worktree() {
    # The filter is scoped to cs's bookkeeping. A file the user would lose must
    # still show up in the count and in the state, or readiness becomes a lie in
    # the other direction.
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    (cd "$base_dir" && git init -q && git config core.autocrlf false \
        && git add README.md && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    echo "unsaved" > "$wt/notes.txt"
    local line
    line=$("$CS_BIN" "proj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 7)" "the user's file is still counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_still_counts_real_untracked_work_in_an_old_worktree

test_features_fresh_worktree_is_not_already_merged() {
    # A fresh worktree's branch sits AT base HEAD, where merge-base
    # --is-ancestor is also true. Reporting that as already-merged is
    # destructive: cs reads is-ancestor as "already merged; cleaning up" and
    # removes the worktree and deletes the branch.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 4)" "a branch AT base HEAD is not already merged" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a fresh clean worktree is ready" || return 1
}

run_test test_features_fresh_worktree_is_not_already_merged

test_features_reports_a_branch_strictly_behind_as_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 4)" "a tip strictly behind base HEAD is merged" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "state must say merged" || return 1
}

run_test test_features_reports_a_branch_strictly_behind_as_merged

test_features_counts_commits_ahead() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo one > "$wt/a.txt"; (cd "$wt" && git add -A && git commit -q -m one)
    echo two > "$wt/b.txt"; (cd "$wt" && git add -A && git commit -q -m two)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "2" "$(_feat_field "$line" 3)" "two commits ahead of base HEAD" || return 1
    assert_eq "cs/fix-auth" "$(_feat_field "$line" 2)" "branch comes from the state pin" || return 1
}

run_test test_features_counts_commits_ahead

test_features_reports_a_live_worktree_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$wt/.cs/session.lock"
    assert_eq "worktree" "$(_feat_field "$line" 9)" "a live lock on the feature worktree is lock=worktree" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live worktree lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_worktree_lock_distinctly

# -features reads both locks by live_lock_pid's rule: "-1", "0" and "+<pid>"
# name no running conversation, so the record says lock=none.
test_features_reads_the_locks_by_the_one_lock_rule() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local text line where
    for where in "$wt" "$base_dir"; do
        for text in "-1" "0" "+$$"; do
            printf '%s\n' "$text" > "$where/.cs/session.lock"
            line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
            rm -f "$where/.cs/session.lock"
            assert_eq "none" "$(_feat_field "$line" 9)" "a lock of '$text' in $where is lock=none: $line" || return 1
        done
    done
}

run_test test_features_reads_the_locks_by_the_one_lock_rule

test_features_reports_a_live_base_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "$$" > "$base_dir/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$base_dir/.cs/session.lock"
    assert_eq "base" "$(_feat_field "$line" 9)" "a live lock on the base is lock=base" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live base lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_base_lock_distinctly

test_features_ignores_a_dead_lock_pid() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local dead_pid
    dead_pid=$(bash -c 'echo $$')
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 77
    fi
    echo "$dead_pid" > "$wt/.cs/session.lock"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "none" "$(_feat_field "$line" 9)" "a dead pid must not be reported as a lock" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a dead pid must not set state=locked" || return 1
}

run_test test_features_ignores_a_dead_lock_pid

test_features_human_table_names_the_state() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_contains "$output" "FEATURE" "the table carries a header" || return 1
    assert_output_contains "$output" "fix-auth" "the feature is listed" || return 1
    assert_output_contains "$output" "ready" "the state is named" || return 1
}

run_test test_features_human_table_names_the_state

test_finish_arms_the_ritual_without_merging() {
    # -finish opens the base with the ritual armed. It must not merge: the
    # branch is still unmerged and the worktree still exists afterwards.
    # The base session directory already exists (created by
    # create_test_session_with_git below), so this launch is a resume, not a
    # fresh session: it hits the "Continue previous conversation?" prompt, so
    # stdin needs an answer rather than an immediate EOF (< /dev/null exits
    # the launch at that prompt before the exec line is ever reached).
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the launch prompt must arm the ritual" || return 1
    assert_dir "$wt" "the worktree must survive -finish" || return 1
    assert_file_not_exists "$base_dir/auth.txt" "-finish must not merge" || return 1
}

run_test test_finish_arms_the_ritual_without_merging

test_finish_survives_declining_the_resume() {
    # Answering n takes _exec_fresh_rebind, which builds its OWN prompt chain.
    # Missing it drops the merge intent silently on a routine answer.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' \
        > "$CS_SESSIONS_ROOT/myproj/.cs/local/state"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "n" 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "a declined resume must keep the merge kick" || return 1
}

run_test test_finish_survives_declining_the_resume

test_finish_rejects_an_unknown_feature() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "no-such-feature" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "no-such-feature" "the refusal must name the feature" || return 1
}

run_test test_finish_rejects_an_unknown_feature

test_finish_rejects_a_prefix_lookalike() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    local output
    output=$("$CS_BIN" "myproj" -finish "wip" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "No feature worktree 'wip'" \
        "a prefix of a real feature must be refused" || return 1
}

run_test test_finish_rejects_a_prefix_lookalike

test_finish_rejects_a_traversal_feature_name() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "../escape" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name" "a path separator must be rejected" || return 1
}

run_test test_finish_rejects_a_traversal_feature_name

test_finish_warns_when_it_displaces_a_spawn_kick() {
    # Both ride claude's single prompt slot. The merge kick wins because the
    # user took the action seconds ago — but the displacement must not be
    # silent, and the warning must not promise the queue runs after the merge:
    # the drain is the Stop hook, which fires at the first turn end.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    # The seed as cs -spawn writes it (line 1 the token, line 2 the spawner),
    # opened as the spawn's own window via CS_SPAWN_TOKEN, so the seed is
    # consumed unasked and the two kicks compete.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'feedfacefeedfacefeedfacefeedface\nother-session\nfirst staged task\n' > "$CS_SESSIONS_ROOT/.spawn/myproj.seed"
    local output
    output=$(CS_SPAWN_TOKEN=feedfacefeedfacefeedfacefeedface "$CS_BIN" "myproj" -finish "fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "/finish fix-auth" "the merge kick takes the slot" || return 1
    assert_output_contains "$output" "walk-away queue is armed" "the displacement must be announced" || return 1
    assert_output_not_contains "$output" "after the merge" "must not promise sequencing it cannot enforce" || return 1
}

run_test test_finish_warns_when_it_displaces_a_spawn_kick

# A worktree open runs no migrate_session, so Phase 8 never binds a transcript
# for it. With the recorded id gone and a conversation on disk, the open offers
# that conversation rather than starting a new one over it.
test_worktree_without_its_recorded_id_binds_the_folders_conversation() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth" state uuid="55555555-5555-4555-8555-555555555555"
    state="$wt/.cs/local/state"
    awk 'index($0, "claude_session_id:") != 1' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$wt")"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$uuid" > "$proj/$uuid.jsonl"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "  .cs/local/state  bound claude_session_id to $uuid" "the open binds the transcript it found" || return 1
    assert_output_contains "$output" "Continue previous conversation?" "a real conversation is offered" || return 1
    assert_output_contains "$output" "--resume $uuid" "the default answer resumes it" || return 1
    assert_eq "$uuid" "$(awk '/^claude_session_id:/ { print $2; exit }' "$state")" "the binding is recorded" || return 1
}

run_test test_worktree_without_its_recorded_id_binds_the_folders_conversation

test_finish_yields_to_an_explicit_rotation_choice() {
    # r is the user explicitly choosing the rotation handoff at the prompt;
    # a merge armed moments earlier must not silently override that choice.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # The prompt belongs to a session with a conversation to resume; one with
    # none starts its first without asking. Record the one the handoff's
    # parent names.
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' >> "$base_dir/.cs/local/state"
    mkdir -p "$base_dir/.cs/handoffs"
    cat > "$base_dir/.cs/handoffs/2026-07-16-test.md" << 'EOF'
---
parent: 00000000-0000-4000-8000-000000000000
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: unconsumed
---

## 7. Next Step
Continue the test.
EOF
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "r" 2>&1 || true)
    assert_output_contains "$output" "Rotation handoff takes this launch; re-run: cs myproj -finish fix-auth" \
        "the displaced merge must be announced" || return 1
    assert_output_not_contains "$output" "/finish fix-auth" "the explicit r choice must not be overridden" || return 1
    assert_output_contains "$output" ".cs/handoffs/2026-07-16-test.md" "the handoff prompt must run instead" || return 1
}

run_test test_finish_yields_to_an_explicit_rotation_choice

test_features_table_says_one_file_not_one_files() {
    # The count comes from git, so 1 is an ordinary value. The TUI and this
    # table must word it identically or the same fact reads two ways.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_not_contains "$output" "1 files" "singular count must not say files" || return 1
    assert_output_contains "$output" "1 file untracked" "expected the singular form" || return 1
}

run_test test_features_table_says_one_file_not_one_files

# --- -integrate-feature --from-remote: land a PR's merge commit ---

# Base + feature + a bare origin that already carries the base branch. Prints
# the feature SHA. The caller lands the PR on origin however the scenario
# needs (merge commit, squash) and fetches.
integrate_remote_fixture() {  # base task
    local sha base_dir origin
    sha=$(integrate_fixture "$1" "$2")
    base_dir="$CS_SESSIONS_ROOT/$1"
    origin="$TEST_TMPDIR/origin.git"
    git init -q --bare "$origin"
    git -C "$base_dir" remote add origin "$origin"
    git -C "$base_dir" push -q origin HEAD >/dev/null 2>&1
    git -C "$base_dir" push -q origin "cs/$2" >/dev/null 2>&1
    printf '%s\n' "$sha"
}

# Land the feature on origin's base branch the way a merged PR does (a merge
# commit), through a throwaway clone. Prints the landing commit.
land_pr_on_origin() {  # base_dir task [--squash]
    local base_dir="$1" task="$2" how="${3:-}" clone branch
    branch=$(git -C "$base_dir" symbolic-ref --short HEAD)
    clone="$TEST_TMPDIR/pr-clone"
    rm -rf "$clone"
    git clone -q "$TEST_TMPDIR/origin.git" "$clone" 2>/dev/null
    git -C "$clone" checkout -q "$branch"
    if [ "$how" = "--squash" ]; then
        git -C "$clone" merge -q --squash "origin/cs/$task" >/dev/null 2>&1
        git -C "$clone" commit -q -m "feature ($task) (#7)"
    else
        git -C "$clone" merge -q --no-ff --no-edit -m "Merge pull request #7 from example-org/cs/$task" "origin/cs/$task"
    fi
    git -C "$clone" push -q origin "$branch" >/dev/null 2>&1
    git -C "$clone" rev-parse HEAD
}

test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_eq "$M" "$(git -C "$base_dir" rev-parse HEAD)" "base fast-forwards to the PR merge commit, no extra commit" || return 1
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD \
        || { echo "  FAIL: F should be an ancestor after a merge-commit landing"; return 1; }
    assert_output_contains "$output" "integrated fix-auth $M -> $M" "summary line" || return 1
}

test_integrate_from_remote_after_a_local_integrate_still_lands() {
    # grok's inoperability case: base has a commit origin lacks, so a
    # whole-branch --ff-only would refuse forever. Merging the PR's landing
    # commit as an ordinary merge must still work.
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    (cd "$base_dir" && git commit -q --allow-empty -m "local only")
    local L
    L=$(git -C "$base_dir" rev-parse HEAD)
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    git -C "$base_dir" merge-base --is-ancestor "$M" HEAD \
        || { echo "  FAIL: the PR merge commit must be reachable from base HEAD"; return 1; }
    git -C "$base_dir" merge-base --is-ancestor "$L" HEAD \
        || { echo "  FAIL: the base's local-only commit must survive the landing"; return 1; }
    assert_file_exists "$base_dir/feature.txt" "feature content on base" || return 1
}

# The entry never sees CI; the skill does, through finish.sh's pr_checks, and
# says so with --ci-green. Only then, and only when the base has nothing origin
# lacks (the temp merge is a fast-forward onto the PR's landing commit, the
# tree those checks ran on), is the local gate redundant: it would repeat the
# checks in a clean checkout that lacks the project's gitignored dependencies.
test_integrate_from_remote_skips_the_gate_with_ci_green_when_base_is_an_ancestor() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote --ci-green -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_not_exists "$TEST_TMPDIR/gate-ran" "the gate did not run" || return 1
    assert_output_contains "$output" "gate skipped" "the report says the gate was skipped" || return 1
    assert_output_contains "$output" "checks passed" "and why: the PR's checks passed on that tree" || return 1
    assert_eq "$M" "$(git -C "$base_dir" rev-parse HEAD)" "base still fast-forwards to the PR merge commit" || return 1
}

# Without --ci-green nothing vouches for the landing commit: a merged PR with
# absent, failed or bypassed checks keeps its gate.
test_integrate_from_remote_runs_the_gate_without_ci_green() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "remote landing succeeds: $output" || return 1
    assert_exists "$TEST_TMPDIR/gate-ran" "the gate ran" || return 1
    assert_output_not_contains "$output" "gate skipped" "no skip reported" || return 1
}

# The base's own commit changes the merged tree, so the checks that passed on
# origin say nothing about it and the gate must still run.
test_integrate_from_remote_runs_the_gate_when_base_diverged() {
    local sha base_dir M output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    echo "local change" > "$base_dir/local.txt"
    (cd "$base_dir" && git add local.txt && git commit -q -m "local only")
    M=$(land_pr_on_origin "$base_dir" fix-auth)
    git -C "$base_dir" fetch -q origin
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote --ci-green -- sh -c 'touch "$0/gate-ran"' "$TEST_TMPDIR" 2>&1) || status=$?
    assert_eq "0" "$status" "mixed landing succeeds: $output" || return 1
    assert_exists "$TEST_TMPDIR/gate-ran" "the gate ran on the merge the checks never saw" || return 1
    assert_output_not_contains "$output" "gate skipped" "no skip reported" || return 1
}

# --ci-green describes a PR, so it means nothing on the local path.
test_integrate_refuses_ci_green_without_from_remote() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" --ci-green -- true 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$output" "--ci-green needs --from-remote" "names the rule" || return 1
}

test_integrate_from_remote_refuses_a_commit_origin_does_not_have() {
    local sha base_dir output status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    git -C "$base_dir" fetch -q origin
    # F is on origin/cs/fix-auth but NOT on origin/<base branch>.
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" --from-remote -- true 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$output" "not reachable from origin/" "names the remote branch" || return 1
}

test_integrate_from_remote_squash_leaves_feature_tip_unintegrated() {
    # The squash case the skill must report: M lands, F is not an ancestor.
    local sha base_dir M status=0
    sha=$(integrate_remote_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    M=$(land_pr_on_origin "$base_dir" fix-auth --squash)
    git -C "$base_dir" fetch -q origin
    "$CS_BIN" myproj -integrate-feature fix-auth "$M" --from-remote -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "squash landing succeeds" || return 1
    assert_file_exists "$base_dir/feature.txt" "content landed" || return 1
    if git -C "$base_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        echo "  FAIL: after a squash F must NOT be an ancestor (the report depends on it)"; return 1
    fi
}

run_test test_integrate_from_remote_fast_forwards_onto_the_pr_merge_commit
run_test test_integrate_from_remote_after_a_local_integrate_still_lands
run_test test_integrate_from_remote_skips_the_gate_with_ci_green_when_base_is_an_ancestor
run_test test_integrate_from_remote_runs_the_gate_without_ci_green
run_test test_integrate_from_remote_runs_the_gate_when_base_diverged
run_test test_integrate_refuses_ci_green_without_from_remote
run_test test_integrate_from_remote_refuses_a_commit_origin_does_not_have
run_test test_integrate_from_remote_squash_leaves_feature_tip_unintegrated

# --- /finish progress: the record the cs mod reads to toast and draw the gate band ---

# One field of the base's progress record, as jq -r prints it.
progress_field() {  # record_file jq_filter
    jq -r "$2" "$1" 2>/dev/null
}

test_finish_progress_records_a_landing() {
    local sha base_dir record output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>&1) || status=$?
    assert_eq "0" "$status" "integrate succeeds: $output" || return 1
    assert_file_exists "$record" "the landing leaves a progress record" || return 1
    assert_eq "landed" "$(progress_field "$record" .step)" "the outcome is landed" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    assert_eq "$sha" "$(progress_field "$record" .sha)" "carries the captured sha" || return 1
    assert_eq "$(git -C "$base_dir" rev-parse HEAD)" "$(progress_field "$record" .result)" "carries the commit the base landed on" || return 1
    case "$(progress_field "$record" .pid)" in ''|*[!0-9]*) echo "  FAIL: pid is not a number"; return 1 ;; esac
    case "$(progress_field "$record" .ts)" in ''|*[!0-9]*) echo "  FAIL: ts is not epoch seconds"; return 1 ;; esac
    [ -n "$(progress_field "$record" '.id // empty')" ] || { echo "  FAIL: the record has no id"; return 1; }
}

test_finish_progress_records_no_gate_step_for_a_true_gate() {
    local sha base_dir record status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_eq "landed" "$(progress_field "$record" .step)" "the outcome is landed" || return 1
    assert_eq "false" "$(progress_field "$record" 'has("gate_started")')" "-- true runs no gate worth a band" || return 1
}

test_finish_progress_records_the_gate_step_before_the_gate_runs() {
    local sha base_dir record before after status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    before=$(date +%s)
    # The gate copies the record as it stands while the gate runs.
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'cp "$0" "$1"' "$record" "$TEST_TMPDIR/seen" >/dev/null 2>&1 || status=$?
    after=$(date +%s)
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_file_exists "$TEST_TMPDIR/seen" "the record existed while the gate ran" || return 1
    assert_eq "gate" "$(progress_field "$TEST_TMPDIR/seen" .step)" "the step during the gate is gate" || return 1
    assert_eq "fix-auth" "$(progress_field "$TEST_TMPDIR/seen" .task)" "the gate step names the task" || return 1
    local started
    started=$(progress_field "$TEST_TMPDIR/seen" .gate_started)
    case "$started" in ''|*[!0-9]*) echo "  FAIL: gate_started is not epoch seconds: $started"; return 1 ;; esac
    [ "$started" -ge "$before" ] && [ "$started" -le "$after" ] \
        || { echo "  FAIL: gate_started $started is outside the run ($before..$after)"; return 1; }
    case "$(progress_field "$TEST_TMPDIR/seen" .pid)" in ''|*[!0-9]*) echo "  FAIL: the gate step has no pid"; return 1 ;; esac
    assert_eq "landed" "$(progress_field "$record" .step)" "the run still lands" || return 1
    assert_eq "$(progress_field "$TEST_TMPDIR/seen" .id)" "$(progress_field "$record" .id)" "one run, one id" || return 1
}

test_finish_progress_records_a_red_gate_and_a_moved_base_as_refused() {
    local sha base_dir record head status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    record="$base_dir/.cs/local/finish-progress.json"
    head=$(git -C "$base_dir" rev-parse HEAD)
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'echo GATE-SAYS-NO; exit 3' >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a red gate refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a red gate is refused" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    local reason
    reason=$(progress_field "$record" .reason)
    case "$reason" in
        "Gate failed in "*"(output above); base $base_dir untouched at $head") ;;
        *) echo "  FAIL: the reason is the refusal's first line, got: $reason"; return 1 ;;
    esac

    status=0
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- git -C "$base_dir" commit -q --allow-empty -m moved >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a moved base refuses" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a moved base is refused" || return 1
    assert_eq "Base $base_dir moved during the gates (was $head, now $(git -C "$base_dir" rev-parse --short HEAD)); re-run /finish fix-auth" \
        "$(progress_field "$record" .reason)" "the moved-base reason is one line" || return 1
}

test_finish_progress_records_a_conflict_as_refused() {
    local base_dir wt sha record head status=0
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    sha=$(git -C "$wt" rev-parse HEAD)
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    head=$(git -C "$base_dir" rev-parse HEAD)
    record="$base_dir/.cs/local/finish-progress.json"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "1" "$status" "a conflict refuses" || return 1
    assert_eq "$head" "$(git -C "$base_dir" rev-parse HEAD)" "base HEAD unchanged" || return 1
    assert_eq "refused" "$(progress_field "$record" .step)" "a conflict is refused" || return 1
    assert_eq "Merge of $sha conflicts with $base_dir at $head; base untouched. Conflicting paths:" \
        "$(progress_field "$record" .reason)" "the reason is the refusal's first line" || return 1
}

test_finish_progress_records_a_retirement() {
    local sha base_dir record landed_id output status=0
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "fix" > "$CS_SESSIONS_ROOT/myproj@fix-auth/auth.txt"
    (cd "$CS_SESSIONS_ROOT/myproj@fix-auth" && git add auth.txt && git commit -q -m "task work")
    sha=$(land_feature myproj fix-auth) || { echo "  FAIL: integrate fixture"; return 1; }
    record="$base_dir/.cs/local/finish-progress.json"
    landed_id=$(progress_field "$record" .id)
    output=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" 2>&1) || status=$?
    assert_eq "0" "$status" "retire succeeds: $output" || return 1
    assert_eq "retired" "$(progress_field "$record" .step)" "the outcome is retired" || return 1
    assert_eq "fix-auth" "$(progress_field "$record" .task)" "names the task" || return 1
    [ "$(progress_field "$record" .id)" != "$landed_id" ] || { echo "  FAIL: the retire is a run of its own and needs its own id"; return 1; }
}

# An encrypted session keeps cs's files behind .cs/private, a link into its
# vault; a locked vault (the link dangles) gets no plaintext record instead.
test_finish_progress_goes_behind_private_in_an_encrypted_session() {
    local sha base_dir status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$base_dir/.cs/private"
    _mark_hand_made_vault "$base_dir"
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true >/dev/null 2>&1 || status=$?
    assert_eq "0" "$status" "integrate succeeds" || return 1
    assert_eq "landed" "$(progress_field "$TEST_TMPDIR/vault/private/finish-progress.json" .step)" "the record is in the vault" || return 1
    assert_not_exists "$base_dir/.cs/local/finish-progress.json" "no plaintext record" || return 1
}

test_finish_progress_drops_the_record_while_the_vault_is_locked() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    ln -s "$TEST_TMPDIR/unmounted/private" "$base_dir/.cs/private"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true 2>/dev/null) || status=$?
    assert_eq "0" "$status" "a locked vault does not stop the landing" || return 1
    assert_eq "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" "$output" "the output is unchanged" || return 1
    assert_not_exists "$base_dir/.cs/local/finish-progress.json" "no plaintext record" || return 1
    assert_not_exists "$TEST_TMPDIR/unmounted" "nothing is created where the vault mounts" || return 1
}

# Progress is advisory: a record that cannot be written costs one warning on
# stderr, never the landing, its exit status or its output.
test_finish_progress_write_failure_changes_nothing_but_one_warning() {
    local sha base_dir output status=0
    sha=$(integrate_fixture myproj fix-auth)
    base_dir="$CS_SESSIONS_ROOT/myproj"
    # A directory where the record goes: cs_write_atomic refuses it on every write.
    mkdir -p "$base_dir/.cs/local/finish-progress.json"
    output=$("$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- sh -c 'exit 0' 2>"$TEST_TMPDIR/stderr") || status=$?
    assert_eq "0" "$status" "the landing still succeeds" || return 1
    assert_eq "integrated fix-auth $sha -> $(git -C "$base_dir" rev-parse HEAD)" "$output" "stdout is the summary line alone" || return 1
    assert_file_exists "$base_dir/feature.txt" "the feature landed" || return 1
    assert_eq "1" "$(wc -l < "$TEST_TMPDIR/stderr" | tr -d ' ')" "exactly one line on stderr: $(cat "$TEST_TMPDIR/stderr")" || return 1
    assert_file_contains "$TEST_TMPDIR/stderr" "^cs: /finish progress not recorded: could not write $base_dir/.cs/local/finish-progress.json$" \
        "the one line is the warning" || return 1
}

run_test test_finish_progress_records_a_landing
run_test test_finish_progress_records_no_gate_step_for_a_true_gate
run_test test_finish_progress_records_the_gate_step_before_the_gate_runs
run_test test_finish_progress_records_a_red_gate_and_a_moved_base_as_refused
run_test test_finish_progress_records_a_conflict_as_refused
run_test test_finish_progress_records_a_retirement
run_test test_finish_progress_goes_behind_private_in_an_encrypted_session
run_test test_finish_progress_drops_the_record_while_the_vault_is_locked
run_test test_finish_progress_write_failure_changes_nothing_but_one_warning

report_results

# --- The name claude is given ---

# Claude Code's SendMessage refuses any address with an '@' in it, so a peer
# could never message a feature session named after its directory. cs hands
# claude the name with a '+' for the '@' and keeps the '@' form everywhere
# else: in CLAUDE_SESSION_NAME, on disk, in cs -msg.
test_worktree_launch_names_claude_with_a_plus_and_keeps_the_at_in_its_env() {
    create_test_session_with_git "myproj" > /dev/null
    printf '#!/bin/bash\nprintf "argv=%%s\\n" "$*" > "%s"\nprintf "name=%%s\\n" "${CLAUDE_SESSION_NAME:-}" >> "%s"\n' \
        "$TEST_TMPDIR/launch" "$TEST_TMPDIR/launch" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude"
    "$CS_BIN" "myproj@fix-auth" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$TEST_TMPDIR/launch" "^argv=--name myproj+fix-auth --session-id " \
        "claude is named base+feature" || return 1
    assert_file_contains "$TEST_TMPDIR/launch" "^name=myproj@fix-auth$" \
        "CLAUDE_SESSION_NAME keeps the base@feature form" || return 1
}

# The live-duplicate guard reads the name claude was given back from ps, so
# it looks for the '+' form.
test_worktree_open_refuses_a_running_claude_named_with_the_plus() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local ps_stub="$TEST_TMPDIR/ps-stub"
    printf '#!/bin/sh\nprintf "claude --name myproj+fix-auth\\n"\n' > "$ps_stub"
    chmod +x "$ps_stub"
    _make_launch_sentinel
    local out rc=0
    out=$(CS_PS_BIN="$ps_stub" "$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open refuses" || return 1
    assert_output_contains "$out" "Session myproj@fix-auth is already running elsewhere" \
        "the refusal names the session as cs does" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}
