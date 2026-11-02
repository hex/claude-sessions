#!/usr/bin/env bash
# ABOUTME: Tests for cs -remove/-rm: multi-name removal, per-name confirms,
# ABOUTME: fail-fast on unknown names, and the usage error with no name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

test_remove_multiple_names_each_confirmed() {
    create_test_session r1 >/dev/null
    create_test_session r2 >/dev/null
    printf 'y\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r1 r2 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r1" ] || { echo "  r1 survived"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r2" ] || { echo "  r2 survived"; return 1; }
}

test_remove_decline_skips_that_session_only() {
    create_test_session r3 >/dev/null
    create_test_session r4 >/dev/null
    printf 'n\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r3 r4 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r3" ] || { echo "  declined r3 was removed"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r4" ] || { echo "  r4 survived"; return 1; }
}

test_remove_single_name_still_works() {
    create_test_session r5 >/dev/null
    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r5 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r5" ] || { echo "  r5 survived"; return 1; }
}

test_remove_no_name_errors() {
    ! "$CS_BIN" -rm >/dev/null 2>&1 || return 1
}

test_remove_unknown_name_fails_fast() {
    create_test_session r6 >/dev/null
    ! printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm nosuch r6 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r6" ] || { echo "  fail-fast still removed a later name"; return 1; }
}

test_remove_empty_name_rejected_before_any_deletion() {
    create_test_session r7 >/dev/null
    ! printf 'y\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r7 "" >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT" ] || { echo "  sessions root deleted"; return 1; }
    [ -d "$CS_SESSIONS_ROOT/r7" ] || { echo "  r7 removed despite invalid list"; return 1; }
    ! "$CS_BIN" -rm "" >/dev/null 2>&1 || return 1
}

# The live refusal names the pid live_lock_pid reads: whitespace and leading
# zeros around a running pid are not part of it.
test_remove_live_refusal_names_the_pid_the_lock_rule_reads() {
    create_test_session live1 >/dev/null
    printf '  00%s\n\n' "$$" > "$CS_SESSIONS_ROOT/live1/.cs/session.lock"
    local out rc=0
    out=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm live1 2>&1) || rc=$?
    assert_eq "1" "$rc" "the removal exits 1" || return 1
    assert_eq "Error: Session 'live1' is live (pid $$); use --force to remove anyway" "$out" \
        "the refusal names the pid alone" || return 1
    assert_dir "$CS_SESSIONS_ROOT/live1" "the session stays" || return 1
}

test_remove_refuses_live_session_without_force() {
    create_test_session live1 >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/live1/.cs/session.lock"

    local out rc=0
    out=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm live1 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: live session must refuse removal without --force"
        return 1
    fi
    assert_output_contains "$out" "--force" "refusal names the override" || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; return 1; }
    [ -d "$CS_SESSIONS_ROOT/live1" ] || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: refused removal still deleted the session"; return 1; }

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm live1 --force >/dev/null 2>&1
    rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    [ "$rc" -eq 0 ] || { echo "  FAIL: --force should remove a live session"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/live1" ] || { echo "  FAIL: --force did not remove"; return 1; }
}

test_remove_discards_pending_spawn_seeds() {
    create_test_session seeded >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\ndo a task\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale"
    printf 'other\n' > "$CS_SESSIONS_ROOT/.spawn/other.seed"
    # A spawn killed before it published leaves its staging file; so may one
    # for a session whose name merely starts the same way.
    printf 'killed\n' > "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.Ab12Cd"
    printf 'theirs\n' > "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.seed.Ef34Gh"
    # An open killed outright leaves the seed it claimed; session
    # seeded.seed.claim's claim starts the same way.
    printf 'claimed\n' > "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.claim.4242"
    printf 'theirs\n' > "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.claim.seed.claim.77"

    printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  declined removal still discarded the seed"; return 1; }

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  seed survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale" ] || { echo "  stale seed survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/other.seed" ] || { echo "  another session's seed was deleted"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.Ab12Cd" ] || { echo "  an interrupted spawn's staging file survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.seed.Ef34Gh" ] || { echo "  the staging file of session seeded.seed was deleted"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.claim.4242" ] || { echo "  a killed open's claimed seed survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/.seeded.seed.claim.seed.claim.77" ] || { echo "  the claim of session seeded.seed.claim was deleted"; return 1; }
}

# The sessions root may hold a space; the staging-file cleanup must remove
# exactly the staging file, not a path its words happen to name.
test_remove_discards_spawn_staging_under_a_root_with_a_space() {
    local root="$TEST_TMPDIR/cs root"
    mkdir -p "$root"
    printf 'bystander\n' > "$TEST_TMPDIR/cs"
    CS_SESSIONS_ROOT="$root" create_test_session seeded >/dev/null
    mkdir -p "$root/.spawn"
    printf 'killed\n' > "$root/.spawn/.seeded.seed.Ab12Cd"
    printf 'y\n' | CS_SESSIONS_ROOT="$root" CS_ASSUME_TTY=1 "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ ! -f "$root/.spawn/.seeded.seed.Ab12Cd" ] || { echo "  the staging file survived removal"; return 1; }
    assert_file_exists "$TEST_TMPDIR/cs" "a file named by the root's first word is untouched" || return 1
}

# The brief staged with a seed dies with the session too: a leftover would
# reach a future same-name session as a brief nobody wrote for it.
test_remove_discards_pending_spawn_brief() {
    create_test_session briefed >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.seed"
    printf 'do this\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md.stale"
    printf 'theirs\n' > "$CS_SESSIONS_ROOT/.spawn/other.brief.md"

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm briefed >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md" ] || { echo "  brief survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md.stale" ] || { echo "  stale brief survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/other.brief.md" ] || { echo "  another session's brief was deleted"; return 1; }
}

test_remove_worktree_session_discards_seeds() {
    local base="$CS_SESSIONS_ROOT/wbase"
    create_test_session wbase >/dev/null
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md
    git -C "$base" -c user.email=t@t -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$CS_SESSIONS_ROOT/wbase@t" -b cs/t
    mkdir -p "$CS_SESSIONS_ROOT/wbase@t/.cs/local"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed.stale"
    printf 'do this\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.brief.md"
    printf 'old brief\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.brief.md.stale"

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm "wbase@t" >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/wbase@t" ] || { echo "  worktree session survived"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed" ] || { echo "  worktree seed survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed.stale" ] || { echo "  worktree stale seed survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.brief.md" ] || { echo "  worktree brief survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.brief.md.stale" ] || { echo "  worktree stale brief survived removal"; return 1; }
}

test_remove_allows_heartbeat_only_session_without_force() {
    # The live guard is strict PID-lock by decision: a heartbeat-live but
    # unlocked session (fresh context-pct, no session.lock) is still removable
    # without --force. cs -live shows it; cs -rm does not refuse it.
    create_test_session breathing >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/breathing/.cs/local"
    : > "$CS_SESSIONS_ROOT/breathing/.cs/local/context-pct"
    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm breathing >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/breathing" ] || { echo "  heartbeat-only session wrongly refused rm"; return 1; }
}

test_remove_noninteractive_without_force_errors_loudly() {
    create_test_session n1 >/dev/null
    local out rc=0
    out=$("$CS_BIN" -rm n1 </dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: non-interactive rm without --force must not exit 0"; return 1; }
    assert_output_contains "$out" "needs a terminal" "error names the missing terminal" || return 1
    [ -d "$CS_SESSIONS_ROOT/n1" ] || { echo "  FAIL: session was removed despite the refusal"; return 1; }
}

test_remove_force_skips_the_prompt() {
    create_test_session n2 >/dev/null
    "$CS_BIN" -rm n2 --force </dev/null >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/n2" ] || { echo "  FAIL: --force did not remove the session"; return 1; }
}

# The refusal names every file cs did not create on its one line: a
# backslash in a name prints as itself, a control character as "?".
test_remove_force_refuses_when_session_holds_files_cs_did_not_create() {
    local dir
    dir=$(create_test_session f1)
    mkdir "$dir/journal.sparsebundle"
    echo keep > "$dir/start"
    touch "$dir/a\\b" "$dir/esc"$'\033'".txt" "$dir/nl"$'\n'"break.txt"
    local out rc=0
    out=$("$CS_BIN" -rm f1 --force </dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: --force removed a session holding foreign files"; return 1; }
    assert_eq "Error: Session 'f1' holds files cs did not create: a\\b, esc?.txt, journal.sparsebundle, nl?break.txt, start. Add --delete-files to remove them with --force" \
        "$out" "refusal names each foreign entry on one line" || return 1
    assert_dir "$dir/journal.sparsebundle" "foreign entry must survive the refusal" || return 1
}

# A root can hold thousands of files cs did not create. The refusal names
# every one on its one line however long that line gets: here 4,500 names of
# 240 bytes, over a megabyte, more than one exec's arguments and environment
# may carry on macOS or Linux.
test_remove_force_refusal_names_every_foreign_entry_of_a_large_root() {
    local dir pad i=1 name names=() expected out rc=0
    dir=$(create_test_session f9)
    pad=$(printf '%0229d' 0)
    while [ "$i" -le 4500 ]; do
        printf -v name 'entry-%04d-%s' "$i" "$pad"
        : > "$dir/$name"
        names+=("$name")
        i=$((i + 1))
    done
    expected=$(printf '%s, ' "${names[@]}")
    expected="${expected%, }"
    out=$("$CS_BIN" -rm f9 --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses the session" || return 1
    assert_eq "Error: Session 'f9' holds files cs did not create: $expected. Add --delete-files to remove them with --force" \
        "$out" "the refusal names all 4,500 entries" || return 1
}

test_remove_force_with_delete_files_removes_foreign_files() {
    local dir
    dir=$(create_test_session f2)
    mkdir "$dir/journal.sparsebundle"
    "$CS_BIN" -rm f2 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "session with foreign files should be gone" || return 1
}

test_remove_force_ignores_cs_owned_entries_and_ds_store() {
    local dir
    dir=$(create_test_session f3)
    mkdir -p "$dir/.claude" "$dir/.git"
    touch "$dir/.gitignore" "$dir/.gitattributes" "$dir/CLAUDE.local.md" "$dir/.DS_Store"
    # Legacy cs layouts kept these at the root; they are cs's, not the user's.
    mkdir -p "$dir/logs" "$dir/artifacts"
    touch "$dir/notes.md" "$dir/changes.md" "$dir/discoveries.md"
    "$CS_BIN" -rm f3 --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "a session holding only cs-owned entries should still go under --force" || return 1
}

# The confirm lists a session root's files cs did not create one name per
# row, as the worktree confirm lists what git does not track, a control
# character in a name shown as "?".
test_remove_confirm_lists_foreign_entries() {
    local dir
    dir=$(create_test_session f4)
    touch "$dir/notes.txt" "$dir/line"$'\n'"break.txt"
    local out
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm f4 2>&1) || return 1
    assert_eq "Also deletes files cs did not create:
    line?break.txt
    notes.txt
Cancelled" "$out" "confirm lists each foreign entry on a row of its own" || return 1
    assert_dir "$dir" "declined session must survive" || return 1
}

# Past twenty names the confirm counts the rest, as the worktree confirm does.
test_remove_confirm_caps_foreign_entries_at_twenty() {
    local dir i=1 expected="Also deletes files cs did not create:"
    dir=$(create_test_session f5)
    while [ "$i" -le 22 ]; do
        touch "$dir/$(printf 'draft-%02d.md' "$i")"
        [ "$i" -gt 20 ] || expected="$expected
    $(printf 'draft-%02d.md' "$i")"
        i=$((i + 1))
    done
    local out
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm f5 2>&1) || return 1
    assert_eq "$expected
    ... and 2 more
Cancelled" "$out" "confirm lists twenty foreign entries and counts the rest" || return 1
    assert_dir "$dir" "declined session must survive" || return 1
}

# A cloned session's repo chooses the names at its root, and a name can carry a
# terminal escape: a raw ESC or BEL byte, or backslash text echo -e would turn
# into one. It can also carry a character that flips the direction of the
# text after it (U+202E) or one that takes no room (U+200B), so the name
# reads as another file's. The confirm and the --force refusal print each
# control byte, and each such character, in a name as one "?" and its other
# text, an accent and a space among it, as written. A name made only of
# control bytes is still named, so it still holds the --force refusal.
test_remove_names_foreign_entries_without_control_direction_or_zero_width_characters() {
    local bad=$'e\033[1mb\007\\e[0m' dir out rc=0
    local turned=$'caf\xc3\xa9 \xe2\x80\xaetxt.exe\xe2\x80\x8b.md' shown=$'caf\xc3\xa9 ?txt.exe?.md'
    dir=$(create_test_session f5)
    touch "$dir/n$bad"
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm f5 2>&1) || return 1
    assert_eq "Also deletes files cs did not create:
    ne?[1mb?\\e[0m
Cancelled" "$out" "the confirm prints the entry without its control bytes" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal from the confirm" || return 1
    dir=$(create_test_session f6)
    touch "$dir/"$'\033\007'
    out=$("$CS_BIN" -rm f6 --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a session holding an entry of control bytes only" || return 1
    assert_output_contains "$out" "holds files cs did not create: ??\. Add --delete-files" \
        "the refusal prints the entry without its control bytes" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal from the refusal" || return 1
    assert_dir "$dir" "the refused session survives" || return 1
    dir=$(create_test_session f7)
    touch "$dir/$turned"
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm f7 2>&1) || return 1
    assert_eq "Also deletes files cs did not create:
    $shown
Cancelled" "$out" "the confirm prints each direction or zero-width character as one ?" || return 1
    rc=0
    out=$("$CS_BIN" -rm f7 --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a session holding the entry" || return 1
    assert_eq "Error: Session 'f7' holds files cs did not create: $shown. Add --delete-files to remove them with --force" \
        "$out" "the refusal prints each direction or zero-width character as one ?" || return 1
    assert_file_exists "$dir/$turned" "the refused entry survives" || return 1
}

# An encrypted session mounts its vault inside the session directory by
# convention; rm -rf would recurse into the mount and delete what the vault
# holds, even under --force --delete-files. Unmounted, the links dangle and
# removal goes ahead.
_vaulted_session() {  # name; echoes the session dir
    local dir
    dir=$(create_test_session "$1")
    mkdir -p "$dir/.cs/vault-mnt/memory"
    echo sealed > "$dir/.cs/vault-mnt/memory/narrative.md"
    rm -rf "$dir/.cs/memory"
    ln -s "$dir/.cs/vault-mnt/memory" "$dir/.cs/memory"
    echo "$dir"
}

test_remove_refuses_while_the_vault_is_mounted_inside() {
    local dir out rc=0
    dir=$(_vaulted_session v1)
    out=$("$CS_BIN" -rm v1 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'v1' has encrypted storage mounted inside it: .cs/memory points at $dir/.cs/vault-mnt/memory. Removing the session would delete what the vault holds; unmount it, then retry." \
        "$out" "names the mounted link" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the vault's contents survive" || return 1
}

# A clone chooses the text a committed link points at, and it can carry a
# terminal escape: a raw ESC or BEL byte, or backslash text echo -e would
# turn into one. The refusal prints it as a plain name, each character a
# plain path lacks replaced by _.
test_remove_names_a_mounted_vault_link_by_a_plain_target() {
    local dir out rc=0 bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    dir=$(create_test_session v3)
    mkdir -p "$dir/.cs/vault$bad/memory"
    rm -rf "$dir/.cs/memory"
    ln -s "vault$bad/memory" "$dir/.cs/memory"
    out=$("$CS_BIN" -rm v3 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'v3' has encrypted storage mounted inside it: .cs/memory points at vault$shown/memory. Removing the session would delete what the vault holds; unmount it, then retry." \
        "$out" "the link's target is named as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_dir "$dir" "the session survives" || return 1
}

test_remove_goes_ahead_once_the_vault_is_unmounted() {
    local dir
    dir=$(_vaulted_session v2)
    rm -rf "$dir/.cs/vault-mnt/memory"
    "$CS_BIN" -rm v2 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "an unmounted encrypted session is removed" || return 1
}

# A cs -encrypt that stops partway leaves its volume mounted at .cs/vault-mnt
# before any vault link exists, so only the mount table shows it.
_half_encrypted_session() {  # name; echoes the session dir
    local dir
    dir=$(create_test_session "$1")
    mkdir -p "$dir/.cs/vault-mnt/memory"
    echo sealed > "$dir/.cs/vault-mnt/memory/narrative.md"
    echo "$dir"
}

test_remove_refuses_a_volume_mounted_inside_without_vault_links() {
    local dir stub="$TEST_TMPDIR/mount-stub" out rc=0
    dir=$(_half_encrypted_session h1)
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" \
        "/dev/disk9s1 on $dir/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)" || return 1
    out=$(PATH="$stub:$PATH" "$CS_BIN" -rm h1 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'h1' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry." \
        "$out" "names the mount point" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

test_remove_reads_a_linux_mount_table() {
    local dir stub="$TEST_TMPDIR/mount-stub" out rc=0
    dir=$(_half_encrypted_session h2)
    _stub_mount_table "$stub" "/dev/sda1 on / type ext4 (rw,relatime)" \
        "/dev/loop9 on $dir/.cs/vault-mnt type ext4 (rw,relatime)" || return 1
    out=$(PATH="$stub:$PATH" "$CS_BIN" -rm h2 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'h2' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry." \
        "$out" "names the mount point without the filesystem type" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

# A sibling whose name extends this one's ("h3x" beside "h3") holds the mount:
# a string-prefix match would refuse the wrong session.
test_remove_ignores_a_volume_mounted_in_another_session() {
    local dir other stub="$TEST_TMPDIR/mount-stub"
    dir=$(create_test_session h3)
    other=$(_half_encrypted_session h3x)
    _stub_mount_table "$stub" "/dev/disk9s1 on $other/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)" || return 1
    PATH="$stub:$PATH" "$CS_BIN" -rm h3 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "the session without a mount is removed" || return 1
    assert_file_exists "$other/.cs/vault-mnt/memory/narrative.md" "the other session is untouched" || return 1
}

test_remove_refuses_when_the_mount_table_cannot_be_read() {
    local dir d="$TEST_TMPDIR/mount-broken" out rc=0
    dir=$(create_test_session h4)
    _stub_mount_unreadable "$d" || return 1
    out=$(PATH="$d:$PATH" "$CS_BIN" -rm h4 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_output_contains "$out" "Error: cs -rm could not read the mount table, so it cannot tell whether a volume is mounted inside 'h4'; refusing to remove it." "says why" || return 1
    assert_dir "$dir" "the session survives" || return 1
}

# Runs `cs -rm <args>` with a mount stub first on PATH and gives it 30 s, so a
# parse that never ends fails the test instead of hanging the suite. The scan
# runs in a command-substitution child of cs, so that child goes first. Prints
# the output, then "rc=<status>" (124 for a run that had to be stopped).
_rm_within_30s() {  # stub-dir args...
    local stub="$1" out="$TEST_TMPDIR/rm-within.out" pid i=0 rc=0
    shift
    PATH="$stub:$PATH" "$CS_BIN" -rm "$@" </dev/null >"$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge 150 ]; then
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            cat "$out"
            echo "rc=124"
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    wait "$pid" || rc=$?
    cat "$out"
    echo "rc=$rc"
}

# A mount source may itself hold " on " (an NFS export, an SMB share name).
# Another session's line like that must not stall the scan.
test_remove_reads_past_a_mount_source_holding_on() {
    local dir other stub="$TEST_TMPDIR/mount-stub" out
    dir=$(create_test_session h5)
    other=$(_half_encrypted_session h5x)
    _stub_mount_table "$stub" "host:/export on disk on $other/.cs/vault-mnt (nfs)" || return 1
    out=$(_rm_within_30s "$stub" h5 --force --delete-files)
    assert_eq "Removed session: h5
rc=0" "$out" "removal finishes" || return 1
    assert_not_exists "$dir" "the session without a mount is removed" || return 1
}

# In the last two lines the source ends in " on", so its " on" and the
# separator share one space.
test_remove_refuses_a_mount_whose_source_holds_on() {
    local dir stub="$TEST_TMPDIR/mount-stub" out line
    dir=$(_half_encrypted_session h6)
    for line in "host:/export on disk on $dir/.cs/vault-mnt (nfs)" \
        "host:/export on on $dir/.cs/vault-mnt (nfs)" \
        "host:/export on on $dir/.cs/vault-mnt type nfs (rw)"; do
        _stub_mount_table "$stub" "$line" || return 1
        out=$(_rm_within_30s "$stub" h6 --force --delete-files)
        assert_eq "Error: Session 'h6' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry.
rc=1" "$out" "names the mount point: $line" || return 1
        assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive: $line" || return 1
    done
}

# macOS never prints " type <fs>", so a path holding " type " (here in the
# sessions root) is still the mount point, not a Linux line to cut short.
test_remove_reads_a_macos_mount_point_holding_type() {
    local root="$TEST_TMPDIR/project type archive" dir stub="$TEST_TMPDIR/mount-stub" out
    mkdir -p "$root"
    dir=$(CS_SESSIONS_ROOT="$root" _half_encrypted_session h7)
    _stub_mount_table "$stub" "/dev/disk9s1 on $dir/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)" || return 1
    out=$(CS_SESSIONS_ROOT="$root" _rm_within_30s "$stub" h7 --force --delete-files)
    assert_eq "Error: Session 'h7' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry.
rc=1" "$out" "names the mount point" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

# A worktree session beside a base repo, with one untracked and one
# git-ignored file the user added. Echoes the worktree path.
_worktree_with_user_files() {  # base-name
    local base="$CS_SESSIONS_ROOT/$1" wt="$CS_SESSIONS_ROOT/$1@t"
    create_test_session "$1" >/dev/null
    printf '*.img\n.cs/local/\n' > "$base/.gitignore"
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md .gitignore
    git -C "$base" -c user.email=t@example.com -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$wt" -b "cs/$1-t"
    mkdir -p "$wt/.cs/local"
    echo draft > "$wt/notes.txt"
    echo secret > "$wt/journal.img"
    echo "$wt"
}

test_remove_force_refuses_worktree_with_untracked_or_ignored_files() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf1)
    out=$("$CS_BIN" -rm wf1@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a worktree holding untracked files" || return 1
    assert_eq "Error: Worktree session 'wf1@t' holds 2 files git does not track:
    journal.img
    notes.txt
Add --delete-files to remove them with --force" "$out" "refusal counts and lists the untracked and ignored files" || return 1
    assert_file_exists "$wt/journal.img" "ignored file must survive the refusal" || return 1
}

test_remove_force_with_delete_files_removes_worktree() {
    local wt
    wt=$(_worktree_with_user_files wf2)
    "$CS_BIN" -rm wf2@t --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$wt" "worktree should be gone with --delete-files" || return 1
}

test_remove_worktree_confirm_lists_untracked_files() {
    local wt out
    wt=$(_worktree_with_user_files wf3)
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm wf3@t 2>&1) || return 1
    assert_eq "Also deletes 2 files git does not track:
    journal.img
    notes.txt
Cancelled" "$out" "confirm counts and lists untracked and ignored files" || return 1
    assert_dir "$wt" "declined worktree must survive" || return 1
}

# A worktree session shaped like a web app after a dev run: ignored build
# trees holding thousands of files, an untracked screenshot directory beside
# tracked source, and two loose files. Echoes the worktree path.
_worktree_with_build_trees() {  # base-name
    local base="$CS_SESSIONS_ROOT/$1" wt="$CS_SESSIONS_ROOT/$1@t"
    create_test_session "$1" >/dev/null
    printf 'node_modules/\n.svelte-kit/\n.env\n.cs/local/\n' > "$base/.gitignore"
    mkdir -p "$base/apps/web/src"
    echo 'export {}' > "$base/apps/web/src/app.ts"
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md .gitignore apps
    git -C "$base" -c user.email=t@example.com -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$wt" -b "cs/$1-t"
    mkdir -p "$wt/.cs/local" "$wt/apps/web/node_modules/pkg" "$wt/apps/web/.svelte-kit/out" \
        "$wt/apps/web/src/__screenshots__"
    (cd "$wt/apps/web/node_modules/pkg" && touch f{1..3000})
    (cd "$wt/apps/web/.svelte-kit/out" && touch f{1..1200})
    touch "$wt/apps/web/src/__screenshots__/a.png" "$wt/apps/web/src/__screenshots__/b.png"
    echo KEY=value > "$wt/apps/web/.env"
    echo draft > "$wt/notes.txt"
    echo "$wt"
}

# A whole ignored or untracked tree is one line carrying its file count, the
# header carries the total, and loose files follow by path.
test_remove_worktree_confirm_collapses_untracked_trees() {
    local wt out
    wt=$(_worktree_with_build_trees wf4)
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm wf4@t 2>&1) || return 1
    assert_eq "Also deletes 4,204 files git does not track:
    apps/web/node_modules/         (3,000 files)
    apps/web/.svelte-kit/          (1,200 files)
    apps/web/src/__screenshots__/  (2 files)
    apps/web/.env
    notes.txt
Cancelled" "$out" "confirm collapses each untracked tree to one counted line" || return 1
    assert_dir "$wt" "declined worktree must survive" || return 1
}

test_remove_force_refusal_collapses_untracked_trees() {
    local wt out rc=0
    wt=$(_worktree_with_build_trees wf5)
    out=$("$CS_BIN" -rm wf5@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a worktree holding untracked trees" || return 1
    assert_eq "Error: Worktree session 'wf5@t' holds 4,204 files git does not track:
    apps/web/node_modules/         (3,000 files)
    apps/web/.svelte-kit/          (1,200 files)
    apps/web/src/__screenshots__/  (2 files)
    apps/web/.env
    notes.txt
Add --delete-files to remove them with --force" "$out" "refusal collapses each untracked tree to one counted line" || return 1
    assert_file_exists "$wt/apps/web/.env" "ignored file must survive the refusal" || return 1
}

# git lists a repository nested in the worktree as one path ending in "/",
# untracked or ignored; its count is every file under it, its .git included.
test_remove_worktree_confirm_counts_the_files_in_a_nested_repository() {
    local wt out other="$TEST_TMPDIR/other"
    wt=$(_worktree_with_user_files wf6)
    rm "$wt/notes.txt" "$wt/journal.img"
    git init -q "$other"
    printf 'vendor/\n' >> "$(git -C "$wt" rev-parse --git-common-dir)/info/exclude"
    mkdir -p "$wt/dep" "$wt/vendor/dep2"
    printf 'gitdir: %s\n' "$other/.git" > "$wt/dep/.git"
    printf 'gitdir: %s\n' "$other/.git" > "$wt/vendor/dep2/.git"
    touch "$wt/dep/a" "$wt/dep/b" "$wt/vendor/dep2/c"
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm wf6@t 2>&1) || return 1
    assert_eq "Also deletes 5 files git does not track:
    dep/     (3 files)
    vendor/  (2 files)
Cancelled" "$out" "a nested repository counts every file under it" || return 1
}

test_remove_force_refusal_names_one_file_as_it() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf7)
    rm "$wt/journal.img"
    out=$("$CS_BIN" -rm wf7@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a worktree holding an untracked file" || return 1
    assert_eq "Error: Worktree session 'wf7@t' holds 1 file git does not track:
    notes.txt
Add --delete-files to remove it with --force" "$out" "the refusal names one file as it" || return 1
}

# A worktree's .claude/ holds the settings file cs writes beside what the
# user keeps there. Only the settings file is cs's: the rest is listed like
# any other file git does not track, as retire lists it.
test_remove_worktree_lists_the_users_files_under_dot_claude() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf8)
    rm "$wt/notes.txt" "$wt/journal.img"
    mkdir -p "$wt/.claude/commands" "$wt/.claude/agents"
    echo "ship" > "$wt/.claude/commands/ship.md"
    git -C "$wt" add .claude/commands/ship.md
    git -C "$wt" -c user.email=t@example.com -c user.name=t commit -qm "a project command"
    echo '{}' > "$wt/.claude/settings.local.json"
    echo "review" > "$wt/.claude/agents/reviewer.md"
    out=$("$CS_BIN" -rm wf8@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses a worktree holding the user's own .claude files: $out" || return 1
    assert_eq "Error: Worktree session 'wf8@t' holds 1 file git does not track:
    .claude/agents/  (1 file)
Add --delete-files to remove it with --force" "$out" "the refusal lists the user's file and not cs's settings" || return 1
    assert_file_exists "$wt/.claude/agents/reviewer.md" "the user's file survives the refusal" || return 1
}

# Finder's .DS_Store is no one's work at any depth, as retire treats it: it
# neither counts in a listing nor makes --force refuse.
test_remove_worktree_leaves_out_ds_store_at_any_depth() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf9)
    rm "$wt/notes.txt" "$wt/journal.img"
    mkdir -p "$wt/docs/deep"
    echo "draft" > "$wt/docs/deep/notes.md"
    : > "$wt/docs/deep/.DS_Store"
    : > "$wt/docs/.DS_Store"
    out=$("$CS_BIN" -rm wf9@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses over the user's file: $out" || return 1
    assert_eq "Error: Worktree session 'wf9@t' holds 1 file git does not track:
    docs/  (1 file)
Add --delete-files to remove it with --force" "$out" "the listing counts the user's file and no .DS_Store" || return 1
    rm "$wt/docs/deep/notes.md"
    rc=0
    out=$("$CS_BIN" -rm wf9@t --force </dev/null 2>&1) || rc=$?
    assert_eq "0" "$rc" "a worktree holding only .DS_Store files goes with --force: $out" || return 1
    assert_not_exists "$wt" "the worktree is removed" || return 1
}

# cs writes the root CLAUDE.local.md with its protocol sentinel, and cs's
# exclude ignores that name. One without the sentinel is the user's own, as
# retire treats it: it is listed, and --force refuses over it.
test_remove_worktree_lists_a_user_authored_claude_local_md() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf10)
    rm "$wt/notes.txt" "$wt/journal.img"
    echo 'CLAUDE.local.md' >> "$(git -C "$wt" rev-parse --git-common-dir)/info/exclude"
    echo "my own notes for this checkout" > "$wt/CLAUDE.local.md"
    out=$("$CS_BIN" -rm wf10@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses over the user's CLAUDE.local.md: $out" || return 1
    assert_eq "Error: Worktree session 'wf10@t' holds 1 file git does not track:
    CLAUDE.local.md
Add --delete-files to remove it with --force" "$out" "the refusal names the file" || return 1
    printf '<!-- cs:session-protocol -->\n# Session protocol\n' > "$wt/CLAUDE.local.md"
    rc=0
    out=$("$CS_BIN" -rm wf10@t --force </dev/null 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs's own protocol file goes with --force: $out" || return 1
    assert_not_exists "$wt" "the worktree is removed" || return 1
}

# An initialised submodule is a checkout of its own: git ls-files in the
# worktree does not list the files inside it, and removal destroys them.
# They are listed, as retire lists them, each as an entry of its own.
test_remove_worktree_lists_files_inside_an_initialised_submodule() {
    local wt out rc=0 lib="$TEST_TMPDIR/sublib"
    wt=$(_worktree_with_user_files wf11)
    rm "$wt/notes.txt" "$wt/journal.img"
    mkdir -p "$lib"
    (cd "$lib" && git init -q && echo lib > lib.txt && printf '*.env\n' > .gitignore && git add -A \
        && git -c user.email=t@example.com -c user.name=t commit -q -m lib) || { echo "  FAIL: submodule fixture"; return 1; }
    (cd "$wt" && git -c protocol.file.allow=always submodule add -q "$lib" sub \
        && git -c user.email=t@example.com -c user.name=t commit -q -m "add submodule") \
        || { echo "  FAIL: submodule fixture"; return 1; }
    echo "secret" > "$wt/sub/secret.env"
    echo "notes" > "$wt/sub/notes.txt"
    out=$("$CS_BIN" -rm wf11@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses over files inside the submodule: $out" || return 1
    assert_eq "Error: Worktree session 'wf11@t' holds 2 files git does not track:
    sub/notes.txt
    sub/secret.env
Add --delete-files to remove them with --force" "$out" "the refusal names both files inside the submodule" || return 1
    assert_eq "secret" "$(cat "$wt/sub/secret.env")" "the ignored file survives the refusal" || return 1
}

# git lists nothing inside a directory its index holds as a submodule, so
# files written into one the worktree never populated are listed under the
# submodule's path, as retire refuses over them, and an ignored file beside
# it is an entry of its own: the directory holding the submodule is not
# collapsed.
test_remove_worktree_lists_files_in_a_submodule_directory_never_populated() {
    local wt out rc=0 lib="$TEST_TMPDIR/sublib"
    wt=$(_worktree_with_user_files wf13)
    rm "$wt/notes.txt" "$wt/journal.img"
    mkdir -p "$lib"
    (cd "$lib" && git init -q && echo lib > lib.txt && git add -A \
        && git -c user.email=t@example.com -c user.name=t commit -q -m lib) || { echo "  FAIL: submodule fixture"; return 1; }
    (cd "$wt" && git -c protocol.file.allow=always submodule add -q "$lib" vendor/sub \
        && git -c user.email=t@example.com -c user.name=t commit -q -m "add submodule" \
        && git submodule deinit -q -f vendor/sub) || { echo "  FAIL: submodule fixture"; return 1; }
    assert_eq "" "$(ls -A "$wt/vendor/sub")" "fixture: the submodule directory is empty" || return 1
    mkdir -p "$wt/vendor/sub/build"
    echo "notes" > "$wt/vendor/sub/build/notes.txt"
    echo "KEY=value" > "$wt/vendor/sub/local.env"
    echo "trace" > "$wt/vendor/trace.img"
    out=$("$CS_BIN" -rm wf13@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses over the files in the submodule directory: $out" || return 1
    assert_eq "Error: Worktree session 'wf13@t' holds 3 files git does not track:
    vendor/sub/build/  (1 file)
    vendor/sub/local.env
    vendor/trace.img
Add --delete-files to remove them with --force" "$out" "the refusal names each file, the submodule's directory never collapsed" || return 1
    assert_eq "KEY=value" "$(cat "$wt/vendor/sub/local.env")" "the file survives the refusal" || return 1
}

# A repo that tracks .cs carries it through git (tracked mode), so an
# untracked file under .cs is the user's work like one anywhere else, as
# retire treats it. In ignored mode the whole .cs is cs's.
test_remove_tracked_mode_worktree_lists_untracked_session_records() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf12)
    rm "$wt/notes.txt" "$wt/journal.img"
    echo "# records" > "$wt/.cs/README.md"
    git -C "$wt" add .cs/README.md
    git -C "$wt" -c user.email=t@example.com -c user.name=t commit -qm "session records"
    printf 'cs_mode: tracked\n' > "$wt/.cs/local/state"
    mkdir -p "$wt/.cs/memory"
    echo "topic" > "$wt/.cs/memory/new-topic.md"
    : > "$wt/.cs/session.lock"
    out=$("$CS_BIN" -rm wf12@t --force </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force refuses over an untracked record in tracked mode: $out" || return 1
    assert_eq "Error: Worktree session 'wf12@t' holds 1 file git does not track:
    .cs/memory/  (1 file)
Add --delete-files to remove it with --force" "$out" "the refusal names the record and not cs's lock or state" || return 1
    printf 'cs_mode: ignored\n' > "$wt/.cs/local/state"
    rc=0
    out=$("$CS_BIN" -rm wf12@t --force </dev/null 2>&1) || rc=$?
    assert_eq "0" "$rc" "in ignored mode .cs is cs's and goes with --force: $out" || return 1
    assert_not_exists "$wt" "the worktree is removed" || return 1
}

# The pins and recipient digests `cs -secrets age add` keeps for a session
# live under ~/.cs-secrets/sessions/<name>/, outside the session directory.
# Removing a base session drops them and says so on one line naming the path.
test_remove_base_session_drops_its_age_state() {
    create_test_session agebase >/dev/null
    local age_dir="$HOME/.cs-secrets/sessions/agebase"
    mkdir -p "$age_dir"
    printf 'age1pin\n' > "$age_dir/age-trusted"
    local out
    out=$("$CS_BIN" -rm agebase --force </dev/null 2>&1) || { echo "  cs -rm failed: $out"; return 1; }
    assert_not_exists "$age_dir" "the base session's age state must go with it" || return 1
    assert_eq "Removed age state: $age_dir" "$(printf '%s\n' "$out" | grep '^Removed age state: ')" \
        "cs -rm names the age state it removed" || return 1
}

test_remove_base_session_without_age_state_prints_no_age_line() {
    create_test_session agenone >/dev/null
    local out
    out=$("$CS_BIN" -rm agenone --force </dev/null 2>&1) || { echo "  cs -rm failed: $out"; return 1; }
    assert_eq "" "$(printf '%s\n' "$out" | grep 'age state' || true)" \
        "nothing removed, nothing named" || return 1
}

# A base@task session uses its base's secrets (CS_SECRETS_SESSION is the
# base), so removing it must leave the base's age state alone.
test_remove_worktree_session_keeps_the_base_age_state() {
    local base="$CS_SESSIONS_ROOT/agewt"
    create_test_session agewt >/dev/null
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md
    git -C "$base" -c user.email=t@t -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$CS_SESSIONS_ROOT/agewt@t" -b cs/t
    mkdir -p "$CS_SESSIONS_ROOT/agewt@t/.cs/local"
    local age_dir="$HOME/.cs-secrets/sessions/agewt"
    mkdir -p "$age_dir"
    printf 'age1pin\n' > "$age_dir/age-trusted"
    local out
    out=$("$CS_BIN" -rm "agewt@t" --force </dev/null 2>&1) || { echo "  cs -rm failed: $out"; return 1; }
    assert_not_exists "$CS_SESSIONS_ROOT/agewt@t" "the worktree session is removed" || return 1
    assert_eq "age1pin" "$(cat "$age_dir/age-trusted")" "the base's age state survives" || return 1
    assert_eq "" "$(printf '%s\n' "$out" | grep 'age state' || true)" "no age state is named" || return 1
}

# A base@task whose base is gone falls through to the plain directory
# removal; the name still decides, so no age state goes with it.
test_remove_orphaned_worktree_session_keeps_age_state() {
    mkdir -p "$CS_SESSIONS_ROOT/ageorph@t/.cs/local"
    local base_age="$HOME/.cs-secrets/sessions/ageorph"
    local own_age="$HOME/.cs-secrets/sessions/ageorph@t"
    mkdir -p "$base_age" "$own_age"
    "$CS_BIN" -rm "ageorph@t" --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/ageorph@t" "the orphaned worktree dir is removed" || return 1
    assert_dir "$base_age" "the base's age state survives" || return 1
    assert_dir "$own_age" "a feature name never reaches the age state" || return 1
}

test_remove_adopted_link_keeps_age_state() {
    local project_dir="$TEST_TMPDIR/age-adopted-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt ageadopt >/dev/null 2>&1)
    [ -L "$CS_SESSIONS_ROOT/ageadopt" ] || { echo "  adopt did not create the link"; return 1; }
    local age_dir="$HOME/.cs-secrets/sessions/ageadopt"
    mkdir -p "$age_dir"
    printf 'age1pin\n' > "$age_dir/age-trusted"
    "$CS_BIN" -rm ageadopt --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/ageadopt" "the link is removed" || return 1
    assert_eq "age1pin" "$(cat "$age_dir/age-trusted")" "an adopted link's removal keeps age state" || return 1
}

# The helper itself refuses any name that is not one plain path component,
# so no caller can turn it on ~/.cs-secrets/sessions/ or above.
test_drop_age_state_refuses_escaping_names() {
    local secrets="$HOME/.cs-secrets"
    mkdir -p "$secrets/sessions/keep" "$secrets/sessions/.hidden"
    printf 'x\n' > "$secrets/sessions/keep/age-trusted"
    printf 'x\n' > "$secrets/sessions/age-root-marker"
    local name rc out
    for name in "" "." ".." ".hidden" "keep/.." "../sessions" "keep@t"; do
        rc=0
        out=$( source "$SCRIPT_DIR/../lib/05-term.sh"
               source "$SCRIPT_DIR/../lib/10-help.sh"
               source "$SCRIPT_DIR/../lib/65-sessions.sh"
               _drop_session_age_state "$name" 2>&1 ) || rc=$?
        assert_eq "1" "$rc" "name '$name' must be refused" || return 1
        assert_eq "Refusing to remove age state for an invalid base session name: '$name'" "$out" \
            "refusal for '$name' names it" || return 1
    done
    assert_eq "x" "$(cat "$secrets/sessions/keep/age-trusted")" "another session's state survives" || return 1
    assert_eq "x" "$(cat "$secrets/sessions/age-root-marker")" "the sessions dir survives" || return 1
    assert_dir "$secrets/sessions/.hidden" "a dot-named dir survives" || return 1
    # A glob character is a plain name: the path is exact, so '*' removes
    # nothing when no session is literally named '*'.
    rc=0
    out=$( source "$SCRIPT_DIR/../lib/05-term.sh"
           source "$SCRIPT_DIR/../lib/10-help.sh"
           source "$SCRIPT_DIR/../lib/65-sessions.sh"
           _drop_session_age_state "*" 2>&1 ) || rc=$?
    assert_eq "0" "$rc" "'*' with no such dir is a no-op" || return 1
    assert_eq "" "$out" "'*' with no such dir names nothing" || return 1
    assert_eq "x" "$(cat "$secrets/sessions/keep/age-trusted")" "'*' is not expanded as a glob" || return 1
}

# A session made by hand under a leading-dot name predates the dot-name
# refusal and stays removable. Its age state is never cs's to name, but its
# removal must not stop the names after it in the same cs -rm.
test_remove_dotted_session_does_not_stop_the_next_name() {
    mkdir -p "$CS_SESSIONS_ROOT/.olddot/.cs/local"
    create_test_session agenext >/dev/null
    local out rc=0
    out=$("$CS_BIN" -rm .olddot agenext --force </dev/null 2>&1) || rc=$?
    assert_not_exists "$CS_SESSIONS_ROOT/.olddot" "the dotted session is removed" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/agenext" "the name after it is removed too" || return 1
    assert_eq "0" "$rc" "cs -rm succeeds" || { echo "  output: $out"; return 1; }
}

# The age state is removed after its session is gone. When that removal
# fails, cs -rm names the path, still removes the names after it, and exits 1
# so a script sees that the run left something behind.
test_remove_age_state_failure_names_it_and_finishes_the_run() {
    rm -rf "$HOME/.cs-secrets"
    create_test_session agefail >/dev/null
    create_test_session agefailnext >/dev/null
    local age_root="$HOME/.cs-secrets/sessions"
    local age_dir="$age_root/agefail"
    mkdir -p "$age_dir"
    printf 'age1pin\n' > "$age_dir/age-trusted"
    chmod 500 "$age_root"
    local out rc=0
    out=$("$CS_BIN" -rm agefail agefailnext --force </dev/null 2>&1) || rc=$?
    chmod 700 "$age_root"
    assert_not_exists "$CS_SESSIONS_ROOT/agefail" "the session itself is removed" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/agefailnext" "the name after it is removed too" || return 1
    assert_dir "$age_dir" "the age state that could not go is still there" || return 1
    assert_eq "Could not remove age state: $age_dir" \
        "$(printf '%s\n' "$out" | sed -n 's/.*\(Could not remove age state: [^[:cntrl:]]*\).*/\1/p')" \
        "the failure names the path" || { echo "  output: $out"; return 1; }
    assert_eq "1" "$rc" "cs -rm exits 1 after a partial run" || { echo "  output: $out"; return 1; }
}

# ~/.cs-secrets or its sessions dir may be a link to anywhere; following it
# would rm -rf a same-name directory there. The drop refuses through a link,
# names the path it left, still removes the names after it, and exits 1.
test_remove_age_state_refuses_a_linked_secrets_parent() {
    local level elsewhere age_dir out rc
    for level in secrets sessions; do
        rm -rf "$HOME/.cs-secrets" "$TEST_TMPDIR/elsewhere-$level"
        elsewhere="$TEST_TMPDIR/elsewhere-$level"
        case "$level" in
            secrets)
                mkdir -p "$elsewhere/sessions/agelink"
                ln -s "$elsewhere" "$HOME/.cs-secrets"
                printf 'keep\n' > "$elsewhere/sessions/agelink/age-trusted" ;;
            sessions)
                mkdir -p "$elsewhere/agelink" "$HOME/.cs-secrets"
                ln -s "$elsewhere" "$HOME/.cs-secrets/sessions"
                printf 'keep\n' > "$elsewhere/agelink/age-trusted" ;;
        esac
        age_dir="$HOME/.cs-secrets/sessions/agelink"
        create_test_session agelink >/dev/null
        create_test_session agelinknext >/dev/null
        rc=0
        out=$("$CS_BIN" -rm agelink agelinknext --force </dev/null 2>&1) || rc=$?
        assert_not_exists "$CS_SESSIONS_ROOT/agelink" "the session is removed ($level)" || return 1
        assert_not_exists "$CS_SESSIONS_ROOT/agelinknext" "the name after it is removed too ($level)" || return 1
        assert_eq "keep" "$(cat "$age_dir/age-trusted")" "nothing behind the link is deleted ($level)" || return 1
        assert_eq "Left age state behind a linked ~/.cs-secrets: $age_dir" \
            "$(printf '%s\n' "$out" | sed -n 's/.*\(Left age state behind a linked [^[:cntrl:]]*\).*/\1/p')" \
            "the refusal names only the state that is there ($level)" || { echo "  output: $out"; return 1; }
        assert_eq "1" "$rc" "cs -rm exits 1 ($level)" || return 1
    done
    rm -rf "$HOME/.cs-secrets"
}

# A sessions dir cs cannot search hides whether the state is there; that is a
# failure to report, never "nothing to remove".
test_remove_age_state_unsearchable_parent_is_a_failure() {
    rm -rf "$HOME/.cs-secrets"
    create_test_session agehidden >/dev/null
    create_test_session agehiddennext >/dev/null
    local age_root="$HOME/.cs-secrets/sessions"
    local age_dir="$age_root/agehidden"
    mkdir -p "$age_dir"
    printf 'age1pin\n' > "$age_dir/age-trusted"
    chmod 000 "$age_root"
    local out rc=0
    out=$("$CS_BIN" -rm agehidden agehiddennext --force </dev/null 2>&1) || rc=$?
    chmod 700 "$age_root"
    assert_not_exists "$CS_SESSIONS_ROOT/agehiddennext" "the name after it is removed too" || return 1
    assert_dir "$age_dir" "the unreachable state is still there" || return 1
    assert_eq "Could not check age state: $age_dir" \
        "$(printf '%s\n' "$out" | sed -n 's/.*\(Could not check age state: [^[:cntrl:]]*agehidden\)$/\1/p;s/.*\(Could not check age state: [^[:cntrl:]]*agehidden\)[^[:alnum:]].*/\1/p')" \
        "the failure names the path" || { echo "  output: $out"; return 1; }
    assert_eq "1" "$rc" "cs -rm exits 1" || return 1
}

test_remove_age_state_unsearchable_linked_parent_is_a_failure() {
    rm -rf "$HOME/.cs-secrets"
    create_test_session agelkhid >/dev/null
    create_test_session agelkhidnext >/dev/null
    local elsewhere="$TEST_TMPDIR/age-elsewhere-hidden"
    mkdir -p "$elsewhere/agelkhid" "$HOME/.cs-secrets"
    printf 'age1pin\n' > "$elsewhere/agelkhid/age-trusted"
    ln -s "$elsewhere" "$HOME/.cs-secrets/sessions"
    local age_dir="$HOME/.cs-secrets/sessions/agelkhid"
    chmod 000 "$elsewhere"
    local out rc=0
    out=$("$CS_BIN" -rm agelkhid agelkhidnext --force </dev/null 2>&1) || rc=$?
    chmod 700 "$elsewhere"
    assert_not_exists "$CS_SESSIONS_ROOT/agelkhidnext" "the name after it is removed too" || return 1
    assert_dir "$elsewhere/agelkhid" "the unreachable state is still there" || return 1
    assert_eq "Could not check age state: $age_dir" \
        "$(printf '%s\n' "$out" | sed -n 's/.*\(Could not check age state: [^[:cntrl:]]*agelkhid\)$/\1/p;s/.*\(Could not check age state: [^[:cntrl:]]*agelkhid\)[^[:alnum:]].*/\1/p')" \
        "the failure names the path" || { echo "  output: $out"; return 1; }
    assert_eq "1" "$rc" "cs -rm exits 1" || return 1
}

test_remove_force_on_adopted_removes_only_the_link() {
    local project_dir="$TEST_TMPDIR/adopted-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt n3 >/dev/null 2>&1)

    "$CS_BIN" -rm n3 --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/n3" "symlink should be gone" || return 1
    assert_dir "$project_dir/.cs" "project .cs/ should still be present" || return 1
}

# A conversation inside one session cannot pull another session out from
# under its running claude: --force skips the live check only for the
# caller's own sessions and from a terminal outside every session.
test_remove_live_other_session_refused_even_with_force() {
    local dir out rc=0
    dir=$(create_test_session receiver)
    mkdir -p "$dir/.cs/local/queue"
    echo "review the diff" > "$dir/.cs/local/queue/0001"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$dir/.cs/session.lock"
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm receiver --force --delete-files </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "the removal exits 1" || return 1
    assert_eq "Error: session sender cannot remove session receiver while it is live (pid $live_pid); --force does not override that from another session. Close receiver first." \
        "$out" "the refusal names both sessions" || return 1
    assert_file_exists "$dir/.cs/local/queue/0001" "the receiver and its queue survive" || return 1
}

# A session `cs <name> --remote` serves is refused as the open refuses it, with
# --force too, naming the server: removing it would delete the directory the
# server and the conversations it starts run in. The stand-in server is a
# process whose argv carries `remote-control --name <name>`, as the real
# server's does, holding the lock and .cs/local/remote.pid.
test_remove_refuses_a_served_session_with_and_without_force() {
    local dir out rc spid flag seen=""
    dir=$(create_test_session served)
    perl -e 'sleep 60' remote-control --name served --permission-mode default > /dev/null 2>&1 &
    spid=$!
    printf '%s\n' "$spid" > "$dir/.cs/session.lock"
    printf '%s\n' "$spid" > "$dir/.cs/local/remote.pid"
    for flag in "" --force; do
        rc=0
        out=$("$CS_BIN" -rm served $flag </dev/null 2>&1) || rc=$?
        seen="${seen}[cs -rm served${flag:+ $flag}] rc=$rc kept=$([ -d "$dir" ] && echo yes || echo no) $out
"
    done
    { kill "$spid"; wait "$spid"; } 2>/dev/null
    local refusal="Error: Session served is served by cs served --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window."
    assert_eq "[cs -rm served] rc=1 kept=yes $refusal
[cs -rm served --force] rc=1 kept=yes $refusal" "${seen%
}" "cs -rm refuses the served session with and without --force, naming the server" || return 1
}

# A feature session's server runs as `remote-control --name base+feature`,
# the name cs hands claude, so the served check looks for that form.
test_remove_refuses_a_served_feature_session() {
    local dir out rc=0 spid
    dir=$(create_test_session "myproj@feat")
    perl -e 'sleep 60' remote-control --name myproj+feat --permission-mode default > /dev/null 2>&1 &
    spid=$!
    printf '%s\n' "$spid" > "$dir/.cs/session.lock"
    printf '%s\n' "$spid" > "$dir/.cs/local/remote.pid"
    out=$("$CS_BIN" -rm "myproj@feat" --force </dev/null 2>&1) || rc=$?
    { kill "$spid"; wait "$spid"; } 2>/dev/null
    assert_eq "1" "$rc" "cs -rm refuses" || return 1
    assert_eq "Error: Session myproj@feat is served by cs myproj@feat --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window." \
        "$out" "naming the server" || return 1
    assert_dir "$dir" "the session stays" || return 1
}

# An idle session goes from inside another one exactly as it does today.
test_remove_idle_other_session_from_inside_a_session() {
    local dir
    dir=$(create_test_session receiver)
    mkdir -p "$dir/.cs/local/queue"
    echo "review the diff" > "$dir/.cs/local/queue/0001"
    CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm receiver --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "the idle session is removed" || return 1
}

# A base owns its own features, so --force still takes a live one from it.
test_remove_live_own_feature_from_its_base_with_force() {
    local wt
    wt=$(_worktree_with_user_files sender)
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$wt/.cs/session.lock"
    local out rc=0
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm sender@t --force --delete-files </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "0" "$rc" "the base removes its own live feature (output: $out)" || return 1
    assert_not_exists "$wt" "the feature is gone" || return 1
}

# A feature owns neither its base nor a sibling feature.
test_remove_from_a_feature_refuses_its_live_base_and_a_live_sibling() {
    create_test_session sender >/dev/null
    create_test_session sender@b >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/sender/.cs/session.lock"
    echo "$live_pid" > "$CS_SESSIONS_ROOT/sender@b/.cs/session.lock"
    local target out rc
    for target in sender sender@b; do
        rc=0
        out=$(CLAUDE_SESSION_NAME=sender@a "$CS_BIN" -rm "$target" --force </dev/null 2>&1) || rc=$?
        assert_eq "1" "$rc" "removing $target exits 1" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        assert_eq "Error: session sender@a cannot remove session $target while it is live (pid $live_pid); --force does not override that from another session. Close $target first." \
            "$out" "the refusal names $target" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        assert_dir "$CS_SESSIONS_ROOT/$target" "$target survives" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
    done
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    return 0
}

# A feature's worktree points into its base's repository, so from inside any
# session but the base itself a base is not removed while one of its features
# is live, --force or not: not from another base, not from a sibling feature,
# and not from the live feature itself.
test_remove_base_refused_while_its_feature_is_live() {
    create_test_session receiver >/dev/null
    create_test_session receiver@x >/dev/null
    sleep 300 &
    local live_pid=$! caller flag out rc
    echo "$live_pid" > "$CS_SESSIONS_ROOT/receiver@x/.cs/session.lock"
    for caller in sender receiver@y receiver@x; do
        for flag in "" --force; do
            rc=0
            # shellcheck disable=SC2086 # an empty flag is no argument
            out=$(CLAUDE_SESSION_NAME="$caller" "$CS_BIN" -rm receiver $flag </dev/null 2>&1) || rc=$?
            assert_eq "1" "$rc" "removing receiver from $caller ${flag:-without --force} exits 1" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
            assert_eq "Error: session $caller cannot remove session receiver while its feature receiver@x is live (pid $live_pid); --force does not override that from another session. Close receiver@x first." \
                "$out" "the refusal from $caller names the live feature" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
            assert_dir "$CS_SESSIONS_ROOT/receiver" "receiver survives" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        done
    done
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    return 0
}

# The base itself and a plain terminal remove an idle base whose feature is
# live, as they always have.
test_remove_base_with_a_live_feature_from_itself_and_a_plain_shell() {
    local caller out rc
    sleep 300 &
    local live_pid=$!
    for caller in receiver ""; do
        create_test_session receiver >/dev/null
        create_test_session receiver@x >/dev/null
        echo "$live_pid" > "$CS_SESSIONS_ROOT/receiver@x/.cs/session.lock"
        rc=0
        out=$(CLAUDE_SESSION_NAME="$caller" "$CS_BIN" -rm receiver --force </dev/null 2>&1) || rc=$?
        assert_eq "0" "$rc" "removing receiver from '${caller:-a plain shell}' exits 0: $out" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        assert_not_exists "$CS_SESSIONS_ROOT/receiver" "receiver is removed from '${caller:-a plain shell}'" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
    done
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    return 0
}

# A volume that ignores letter case finds receiver under RECEIVER, so the base
# named in another case is the same base and is refused the same way, from
# another base and from a sibling feature.
test_remove_base_named_in_another_case_refused_while_its_feature_is_live() {
    create_test_session receiver >/dev/null
    create_test_session receiver@x >/dev/null
    [ -d "$CS_SESSIONS_ROOT/RECEIVER" ] || { echo "    SKIP: the sessions root tells letter case apart"; return 77; }
    sleep 300 &
    local live_pid=$! caller out rc
    echo "$live_pid" > "$CS_SESSIONS_ROOT/receiver@x/.cs/session.lock"
    for caller in sender receiver@y; do
        create_test_session receiver >/dev/null
        rc=0
        out=$(CLAUDE_SESSION_NAME="$caller" "$CS_BIN" -rm RECEIVER --force </dev/null 2>&1) || rc=$?
        assert_eq "1" "$rc" "removing RECEIVER from $caller exits 1" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        assert_eq "Error: session $caller cannot remove session RECEIVER while its feature receiver@x is live (pid $live_pid); --force does not override that from another session. Close receiver@x first." \
            "$out" "the refusal from $caller names the live feature" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
        assert_dir "$CS_SESSIONS_ROOT/receiver" "receiver survives" || { kill "$live_pid"; wait "$live_pid" 2>/dev/null; return 1; }
    done
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    return 0
}

# The same holds when the feature's directory spells its base in another case
# than the base's own directory does.
test_remove_base_refused_while_a_feature_spelled_in_another_case_is_live() {
    create_test_session receiver >/dev/null
    [ -d "$CS_SESSIONS_ROOT/RECEIVER" ] || { echo "    SKIP: the sessions root tells letter case apart"; return 77; }
    create_test_session Receiver@feat >/dev/null
    sleep 300 &
    local live_pid=$! out rc=0
    echo "$live_pid" > "$CS_SESSIONS_ROOT/Receiver@feat/.cs/session.lock"
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm receiver --force </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "removing receiver exits 1" || return 1
    assert_eq "Error: session sender cannot remove session receiver while its feature Receiver@feat is live (pid $live_pid); --force does not override that from another session. Close Receiver@feat first." \
        "$out" "the refusal names the live feature as its directory spells it" || return 1
    assert_dir "$CS_SESSIONS_ROOT/receiver" "receiver survives" || return 1
}

# A volume that ignores Unicode normalization finds a base made in NFC under
# its NFD spelling, so that spelling is refused the same way.
test_remove_base_named_in_another_normalization_refused_while_its_feature_is_live() {
    local nfc nfd
    nfc=$(printf 'caf\303\251')
    nfd=$(printf 'cafe\314\201')
    create_test_session "$nfc" >/dev/null
    create_test_session "$nfc@x" >/dev/null
    [ -d "$CS_SESSIONS_ROOT/$nfd" ] || { echo "    SKIP: the sessions root tells Unicode normalization forms apart"; return 77; }
    sleep 300 &
    local live_pid=$! out rc=0
    echo "$live_pid" > "$CS_SESSIONS_ROOT/$nfc@x/.cs/session.lock"
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm "$nfd" --force </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "removing the NFD spelling exits 1" || return 1
    assert_eq "Error: session sender cannot remove session $nfd while its feature $nfc@x is live (pid $live_pid); --force does not override that from another session. Close $nfc@x first." \
        "$out" "the refusal names the live feature" || return 1
    assert_dir "$CS_SESSIONS_ROOT/$nfc" "the base survives" || return 1
}

# Only the base's own features hold it: another base's live feature does not,
# even when that base's name starts with this one's.
test_remove_base_not_held_by_another_base_live_feature() {
    create_test_session receiver >/dev/null
    create_test_session receiver2@x >/dev/null
    sleep 300 &
    local live_pid=$! out rc=0
    echo "$live_pid" > "$CS_SESSIONS_ROOT/receiver2@x/.cs/session.lock"
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm receiver --force </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "0" "$rc" "removing receiver exits 0: $out" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/receiver" "receiver is removed" || return 1
}

# Every name is checked before any goes: an idle session listed first is not
# removed when a later name is another session that is live.
test_remove_from_inside_a_session_checks_every_name_first() {
    create_test_session idle1 >/dev/null
    create_test_session receiver >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/receiver/.cs/session.lock"
    local out rc=0
    out=$(CLAUDE_SESSION_NAME=sender "$CS_BIN" -rm idle1 receiver --force </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "the removal exits 1" || return 1
    assert_eq "Error: session sender cannot remove session receiver while it is live (pid $live_pid); --force does not override that from another session. Close receiver first." \
        "$out" "the refusal names the live session" || return 1
    assert_dir "$CS_SESSIONS_ROOT/idle1" "the idle session listed first survives" || return 1
    assert_dir "$CS_SESSIONS_ROOT/receiver" "the live session survives" || return 1
}

run_test test_remove_live_other_session_refused_even_with_force
run_test test_remove_refuses_a_served_session_with_and_without_force
run_test test_remove_idle_other_session_from_inside_a_session
run_test test_remove_live_own_feature_from_its_base_with_force
run_test test_remove_from_a_feature_refuses_its_live_base_and_a_live_sibling
run_test test_remove_base_refused_while_its_feature_is_live
run_test test_remove_base_with_a_live_feature_from_itself_and_a_plain_shell
run_test test_remove_base_named_in_another_case_refused_while_its_feature_is_live
run_test test_remove_base_refused_while_a_feature_spelled_in_another_case_is_live
run_test test_remove_base_named_in_another_normalization_refused_while_its_feature_is_live
run_test test_remove_base_not_held_by_another_base_live_feature
run_test test_remove_from_inside_a_session_checks_every_name_first
run_test test_remove_empty_name_rejected_before_any_deletion
run_test test_remove_base_session_drops_its_age_state
run_test test_remove_base_session_without_age_state_prints_no_age_line
run_test test_remove_worktree_session_keeps_the_base_age_state
run_test test_remove_orphaned_worktree_session_keeps_age_state
run_test test_remove_adopted_link_keeps_age_state
run_test test_drop_age_state_refuses_escaping_names
run_test test_remove_dotted_session_does_not_stop_the_next_name
run_test test_remove_age_state_failure_names_it_and_finishes_the_run
run_test test_remove_age_state_refuses_a_linked_secrets_parent
run_test test_remove_age_state_unsearchable_parent_is_a_failure
run_test test_remove_age_state_unsearchable_linked_parent_is_a_failure
run_test test_remove_refuses_live_session_without_force
run_test test_remove_live_refusal_names_the_pid_the_lock_rule_reads
run_test test_remove_allows_heartbeat_only_session_without_force
run_test test_remove_discards_pending_spawn_seeds
run_test test_remove_discards_spawn_staging_under_a_root_with_a_space
run_test test_remove_discards_pending_spawn_brief
run_test test_remove_worktree_session_discards_seeds
run_test test_remove_multiple_names_each_confirmed
run_test test_remove_decline_skips_that_session_only
run_test test_remove_single_name_still_works
run_test test_remove_no_name_errors
run_test test_remove_unknown_name_fails_fast
run_test test_remove_noninteractive_without_force_errors_loudly
run_test test_remove_force_skips_the_prompt
run_test test_remove_force_refuses_when_session_holds_files_cs_did_not_create
run_test test_remove_force_refusal_names_every_foreign_entry_of_a_large_root
run_test test_remove_force_with_delete_files_removes_foreign_files
run_test test_remove_force_ignores_cs_owned_entries_and_ds_store
run_test test_remove_confirm_lists_foreign_entries
run_test test_remove_confirm_caps_foreign_entries_at_twenty
run_test test_remove_names_foreign_entries_without_control_direction_or_zero_width_characters
run_test test_remove_force_refuses_worktree_with_untracked_or_ignored_files
run_test test_remove_force_with_delete_files_removes_worktree
run_test test_remove_worktree_confirm_lists_untracked_files
run_test test_remove_worktree_confirm_collapses_untracked_trees
run_test test_remove_force_refusal_collapses_untracked_trees
run_test test_remove_worktree_confirm_counts_the_files_in_a_nested_repository
run_test test_remove_force_refusal_names_one_file_as_it
run_test test_remove_worktree_lists_the_users_files_under_dot_claude
run_test test_remove_worktree_leaves_out_ds_store_at_any_depth
run_test test_remove_worktree_lists_a_user_authored_claude_local_md
run_test test_remove_worktree_lists_files_inside_an_initialised_submodule
run_test test_remove_worktree_lists_files_in_a_submodule_directory_never_populated
run_test test_remove_tracked_mode_worktree_lists_untracked_session_records
run_test test_remove_force_on_adopted_removes_only_the_link
run_test test_remove_refuses_while_the_vault_is_mounted_inside
run_test test_remove_names_a_mounted_vault_link_by_a_plain_target
run_test test_remove_goes_ahead_once_the_vault_is_unmounted
run_test test_remove_refuses_a_volume_mounted_inside_without_vault_links
run_test test_remove_reads_a_linux_mount_table
run_test test_remove_ignores_a_volume_mounted_in_another_session
run_test test_remove_refuses_when_the_mount_table_cannot_be_read
run_test test_remove_reads_past_a_mount_source_holding_on
run_test test_remove_refuses_a_mount_whose_source_holds_on
run_test test_remove_reads_a_macos_mount_point_holding_type

report_results
