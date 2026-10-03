#!/usr/bin/env bash
# ABOUTME: Tests for cs -encrypt: the refusals, the vault it builds for an existing session,
# ABOUTME: and how it stops. hdiutil, uname and mount are PATH stubs that log every call.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# PATH stubs: uname answers $FAKE_UNAME; hdiutil logs its argv, one call per
# line, and fails the verb named in $FAKE_HDIUTIL_FAIL.
_stubs() {
    local d="$TEST_TMPDIR/stub"
    mkdir -p "$d"
    cat > "$d/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
EOF
    cat > "$d/hdiutil" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_HDIUTIL_LOG"
[ "$1" = "${FAKE_HDIUTIL_FAIL:-}" ] && { echo "hdiutil: $1 failed - stub" >&2; exit 1; }
# The verb named in $FAKE_HDIUTIL_SLOW takes 3 s and logs "<verb>-done" once it finishes.
if [ "$1" = "${FAKE_HDIUTIL_SLOW:-}" ]; then sleep 3; echo "$1-done" >> "$FAKE_HDIUTIL_LOG"; fi
# With $FAKE_LOCK_WATCH set, create records whether that lock names a live pid.
if [ "$1" = "create" ] && [ -n "${FAKE_LOCK_WATCH:-}" ]; then
    p=$(cat "$FAKE_LOCK_WATCH" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo live; else echo "none:$p"; fi > "$FAKE_LOCK_WATCH.seen"
fi
# create makes the container, the one side effect cs relies on.
if [ "$1" = "create" ]; then eval "last=\${$#}"; mkdir -p "$last"; fi
# With $FAKE_MOUNT_FLAG set, attach and detach flip the mount stub's answer.
if [ -n "${FAKE_MOUNT_FLAG:-}" ]; then
    [ "$1" = "attach" ] && : > "$FAKE_MOUNT_FLAG"
    [ "$1" = "detach" ] && rm -f "$FAKE_MOUNT_FLAG"
fi
exit 0
EOF
    chmod +x "$d/uname" "$d/hdiutil"
    export PATH="$d:$PATH"
    export FAKE_HDIUTIL_LOG="$TEST_TMPDIR/hdiutil.log"
    : > "$FAKE_HDIUTIL_LOG"
}

_encrypt() {  # name -> runs cs -encrypt as a human at a terminal would
    CS_ASSUME_TTY=1 "$CS_BIN" -encrypt "$@" </dev/null
}

_vault_path() {  # name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# A refusal writes nothing: no hdiutil call, no vault links, no pre-open.
_assert_nothing_written() {  # name
    local s="$CS_SESSIONS_ROOT/$1/.cs"
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
    local l
    for l in memory plans claude-config private; do
        [ ! -L "$s/$l" ] || { echo "  FAIL: .cs/$l became a link"; return 1; }
    done
    [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: pre-open written"; return 1; }
    [ ! -e "$(_vault_path "$1")" ] || { echo "  FAIL: container created"; return 1; }
}

test_encrypt_refuses_off_macos() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$(FAKE_UNAME=Linux _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs -encrypt needs macOS (hdiutil); Linux is not supported yet." "names the platform" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_without_a_terminal() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$("$CS_BIN" -encrypt enc </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs -encrypt asks for the vault password; run it from a terminal." "says why" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_a_live_session() {
    _stubs
    create_test_session enc >/dev/null
    sleep 300 &
    local live_pid=$! out rc=0
    echo "$live_pid" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    out=$(_encrypt enc 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: the session is running; close it, then encrypt." "names the live session" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_an_unknown_session() {
    _stubs
    local out rc=0
    out=$(_encrypt ghost-town 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "No such session: ghost-town" "names the missing session" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_an_adopted_session() {
    _stubs
    mkdir -p "$TEST_TMPDIR/project/.cs/memory" "$TEST_TMPDIR/project/.cs/local"
    ln -s "$TEST_TMPDIR/project" "$CS_SESSIONS_ROOT/adopted"
    local out rc=0
    out=$(_encrypt adopted 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "adopted: an adopted session cannot be encrypted" "names the adopted session" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_a_feature_worktree_name() {
    _stubs
    local out rc=0
    out=$(_encrypt enc@task 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc@task: encrypt the base session, not a feature worktree" "names the worktree" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_when_any_vault_link_exists() {
    _stubs
    local l
    for l in memory plans claude-config private; do
        rm -rf "${CS_SESSIONS_ROOT:?}/enc"
        create_test_session enc >/dev/null
        rm -rf "$CS_SESSIONS_ROOT/enc/.cs/$l"
        ln -s "$TEST_TMPDIR/elsewhere/$l" "$CS_SESSIONS_ROOT/enc/.cs/$l"
        local out rc=0
        out=$(_encrypt enc 2>&1) || rc=$?
        assert_eq "1" "$rc" "non-zero exit with .cs/$l linked" || return 1
        assert_output_contains "$out" "enc: .cs/$l is already a link; the session is encrypted, or half set up by hand." "names .cs/$l" || return 1
        assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called ($l)" || return 1
    done
}

# .cs/claude-config and .cs/private are never moved, only linked: a real one
# would take the link inside it and keep its files in plaintext.
test_encrypt_refuses_a_real_claude_config_or_private() {
    _stubs
    local l kind
    for l in claude-config private; do
        for kind in dir file; do
            rm -rf "${CS_SESSIONS_ROOT:?}/enc" "$(_vault_path enc)"
            : > "$FAKE_HDIUTIL_LOG"
            _populated_session enc
            if [ "$kind" = dir ]; then
                mkdir -p "$CS_SESSIONS_ROOT/enc/.cs/$l"
            else
                echo "x" > "$CS_SESSIONS_ROOT/enc/.cs/$l"
            fi
            local out rc=0
            out=$(_encrypt enc 2>&1) || rc=$?
            assert_eq "1" "$rc" "non-zero exit with a $kind at .cs/$l" || return 1
            assert_output_contains "$out" "enc: .cs/$l already exists and is not a link; cs -encrypt links it into the vault. Move it aside first." "names .cs/$l ($kind)" || return 1
            _assert_nothing_written enc || return 1
        done
    done
}

test_encrypt_refuses_an_existing_pre_open() {
    _stubs
    create_test_session enc >/dev/null
    printf '#!/bin/sh\necho mine\n' > "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open"
    local before out rc=0
    before=$(cat "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open")
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: .cs/local/pre-open already exists; cs -encrypt writes its own. Move yours aside first." "names the hook" || return 1
    assert_eq "$before" "$(cat "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open")" "pre-open unchanged" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_an_existing_container() {
    _stubs
    create_test_session enc >/dev/null
    mkdir -p "$(_vault_path enc)"
    local out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: $(_vault_path enc) already exists; cs -encrypt will not reuse or overwrite it." "names the container" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

# A closed session holding one of everything the vault takes, plus files that stay.
_populated_session() {  # name
    local s="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$s/memory" "$s/plans" "$s/local/mail/inbox" "$s/handoffs" "$s/checkpoints" "$s/narrative-archive"
    printf -- '---\nstatus: active\ntags: []\n---\n\n## Objective\ntest\n' > "$s/README.md"
    echo "narrative" > "$s/memory/narrative.alice.md"
    echo "plan" > "$s/plans/p.md"
    echo "log" > "$s/local/session.log"
    echo "msg" > "$s/local/mail/inbox/1.json"
    echo "h.md" > "$s/local/pending-handoff"
    echo "handoff" > "$s/handoffs/h.md"
    echo "cp" > "$s/checkpoints/c.md"
    echo "old" > "$s/narrative-archive/a.md"
    echo "claude_session_id=x" > "$s/local/state"
    echo "42" > "$s/local/context-pct"
}

test_encrypt_builds_the_vault_and_detaches() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "exit 0 (output: $out)" || return 1
    local v="$s/vault-mnt" l
    for l in memory plans claude-config private; do
        [ -L "$s/$l" ] || { echo "  FAIL: .cs/$l is not a link"; return 1; }
        assert_eq "vault-mnt/$l" "$(readlink "$s/$l")" ".cs/$l points into the mount" || return 1
        [ -d "$v/$l" ] || { echo "  FAIL: vault has no $l/"; return 1; }
    done
    assert_eq "narrative" "$(cat "$v/memory/narrative.alice.md")" "narrative moved" || return 1
    assert_eq "plan" "$(cat "$v/plans/p.md")" "plans moved" || return 1
    assert_eq "log" "$(cat "$v/private/session.log")" "session.log moved" || return 1
    assert_eq "msg" "$(cat "$v/private/mail/inbox/1.json")" "mail moved" || return 1
    assert_eq "h.md" "$(cat "$v/private/pending-handoff")" "pending-handoff moved" || return 1
    assert_eq "handoff" "$(cat "$v/private/handoffs/h.md")" "handoffs moved" || return 1
    assert_eq "cp" "$(cat "$v/private/checkpoints/c.md")" "checkpoints moved" || return 1
    assert_eq "old" "$(cat "$v/private/narrative-archive/a.md")" "narrative archive moved" || return 1
    local gone
    for gone in local/session.log local/mail local/pending-handoff handoffs checkpoints narrative-archive; do
        [ ! -e "$s/$gone" ] || { echo "  FAIL: plaintext .cs/$gone left behind"; return 1; }
    done
    assert_eq "claude_session_id=x" "$(cat "$s/local/state")" "ids stay in .cs/local" || return 1
    assert_eq "42" "$(cat "$s/local/context-pct")" "status-line numbers stay in .cs/local" || return 1
    [ -e "$v/.metadata_never_index" ] || { echo "  FAIL: Spotlight opt-out missing"; return 1; }
    [ -x "$s/local/pre-open" ] || { echo "  FAIL: pre-open missing or not executable"; return 1; }
    assert_eq "$(_vault_path enc)" "$(cat "$s/local/vault")" ".cs/local/vault names the container" || return 1
    assert_file_contains "$s/README.md" "^tags: \[encrypted\]$" "tagged encrypted" || return 1
    local c; c=$(_vault_path enc)
    assert_eq "create -size 50g -type SPARSEBUNDLE -fs APFS -encryption AES-256 -volname cs-enc $c
attach -nobrowse -mountpoint $s/vault-mnt $c
detach $s/vault-mnt" "$(cat "$FAKE_HDIUTIL_LOG")" "create, attach, then detach" || return 1
    # shellcheck disable=SC2088  # cs prints the literal ~ path
    assert_output_contains "$out" "~/.claude/history.jsonl" "lists copies it could not move" || return 1
}

# A session cloned or synced here and never opened has no .cs/local: it is
# gitignored and born on the first open, and the pre-open hook lives in it.
test_encrypt_builds_a_session_never_opened_on_this_machine() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    rm -rf "$s/local"
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "exit 0 (output: $out)" || return 1
    [ -x "$s/local/pre-open" ] || { echo "  FAIL: pre-open missing or not executable"; return 1; }
    assert_eq "$(_vault_path enc)" "$(cat "$s/local/vault")" ".cs/local/vault names the container" || return 1
    assert_file_contains "$s/README.md" "^tags: \[encrypted\]$" "tagged encrypted" || return 1
}

# An open while cs -encrypt asks for passwords would race its moves; the
# session lock holds it off, and is gone once cs -encrypt ends.
test_encrypt_holds_the_session_lock_while_it_works() {
    _stubs
    _populated_session enc
    local lock="$CS_SESSIONS_ROOT/enc/.cs/session.lock" rc=0
    FAKE_LOCK_WATCH="$lock" _encrypt enc >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "encrypt succeeds" || return 1
    assert_eq "live" "$(cat "$lock.seen" 2>/dev/null)" "a live lock while hdiutil runs" || return 1
    [ ! -e "$lock" ] || { echo "  FAIL: lock left after encrypt: $(cat "$lock")"; return 1; }
}

test_encrypt_releases_the_session_lock_when_it_stops() {
    _stubs
    _populated_session enc
    local lock="$CS_SESSIONS_ROOT/enc/.cs/session.lock" rc=0
    FAKE_HDIUTIL_FAIL=attach _encrypt enc >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "encrypt stops" || return 1
    [ ! -e "$lock" ] || { echo "  FAIL: lock left after a failed encrypt: $(cat "$lock")"; return 1; }
}

test_encrypt_refuses_a_readme_it_cannot_tag() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: .cs/README.md has no YAML frontmatter to carry the encrypted tag." "names the README" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_stops_when_create_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_HDIUTIL_FAIL=create _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: hdiutil create failed; the session is unchanged." "says nothing changed" || return 1
    assert_eq "narrative" "$(cat "$s/memory/narrative.alice.md")" "memory untouched" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: session changed"; return 1; }
}

test_encrypt_stops_when_attach_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_HDIUTIL_FAIL=attach _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: hdiutil could not attach $(_vault_path enc); the session is unchanged. Delete the container before retrying." "names the container" || return 1
    assert_eq "narrative" "$(cat "$s/memory/narrative.alice.md")" "memory untouched" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: session changed"; return 1; }
}

test_encrypt_stops_on_a_failed_move_and_names_what_moved() {
    [ "$(id -u)" != "0" ] || { echo "  SKIP: root ignores the permission that makes the move fail"; return 77; }
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    chmod 555 "$s/local"
    out=$(_encrypt enc 2>&1) || rc=$?
    chmod 755 "$s/local"
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: could not move .cs/local/session.log into the vault. Already moved: .cs/memory .cs/plans. Not moved:" "names moved and unmoved" || return 1
    local l
    for l in memory plans claude-config private; do
        [ ! -L "$s/$l" ] || { echo "  FAIL: .cs/$l linked after a failed move"; return 1; }
    done
    [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: pre-open written after a failed move"; return 1; }
}

# pre-open runs from the session directory before every open. `mount` is a
# stub that reports the vault mounted when FAKE_MOUNTED=1.
_encrypted_session() {  # name -> leaves an encrypted session and a clean hdiutil log
    _stubs
    _populated_session "$1"
    _encrypt "$1" >/dev/null 2>&1 || { echo "  FAIL: fixture encrypt failed"; return 1; }
    cat > "$TEST_TMPDIR/stub/mount" <<'EOF'
#!/bin/sh
{ [ "${FAKE_MOUNTED:-}" = "1" ] || [ -e "${FAKE_MOUNT_FLAG:-/nonexistent}" ]; } && echo "/dev/disk9s1 on $FAKE_MNT (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)"
echo "/dev/disk3s1 on / (apfs, sealed, local, read-only, journaled)"
EOF
    chmod +x "$TEST_TMPDIR/stub/mount"
    FAKE_MNT=$(cd "$CS_SESSIONS_ROOT/$1/.cs/vault-mnt" && pwd -P)
    export FAKE_MNT
    : > "$FAKE_HDIUTIL_LOG"
}

_pre_open() {  # name [env...] -> runs the hook the way _run_pre_open does
    local name="$1"; shift
    (cd "$CS_SESSIONS_ROOT/$name" && env "$@" .cs/local/pre-open </dev/null)
}

test_pre_open_joins_a_mount_held_by_a_running_session() {
    _encrypted_session enc || return 1
    sleep 300 &
    local live=$! rc=0
    echo "$live" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    _pre_open enc FAKE_MOUNTED=1 >/dev/null 2>&1 || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "no prompt, no hdiutil call" || return 1
}

# /clear used to drop the lock while claude ran on; the holder list still names it.
test_pre_open_joins_a_mount_whose_holder_is_alive_without_a_lock() {
    _encrypted_session enc || return 1
    sleep 300 &
    local holder=$! rc=0
    echo "$holder" > "$CS_SESSIONS_ROOT/enc/.cs/local/vault-holders"
    _pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "joined: no detach, no prompt" || return 1
}

# A reopen that kills the waiter must also stop the detach the waiter started,
# or that detach lands on the volume the reopen just attached.
test_pre_open_stops_a_waiter_detach_in_flight() {
    _encrypted_session enc || return 1
    sleep 0.1 &
    local claude=$!
    wait "$claude" 2>/dev/null
    FAKE_HDIUTIL_SLOW=detach _end_conversation enc prompt_input_exit "$claude" "$claude"
    local f="$CS_SESSIONS_ROOT/enc/.cs/local/vault-detach.pid" i=0
    while [ ! -s "$f" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$f" ] || { echo "  FAIL: the waiter recorded no detach child"; return 1; }
    local rc=0
    _pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    sleep 3.5
    assert_eq "0" "$rc" "reopen asks again" || return 1
    assert_eq "detach $FAKE_MNT
detach $FAKE_MNT
attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_HDIUTIL_LOG")" "the waiter's detach never finished" || return 1
}

test_pre_open_detaches_a_leftover_mount_and_asks_again() {
    _encrypted_session enc || return 1
    sleep 300 &
    local waiter=$! rc=0
    echo "$waiter" > "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid"
    _pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    local alive=0
    kill -0 "$waiter" 2>/dev/null && alive=1
    kill "$waiter" 2>/dev/null; wait "$waiter" 2>/dev/null
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "0" "$alive" "the old waiter is killed" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { echo "  FAIL: waiter pid file left"; return 1; }
    assert_eq "detach $FAKE_MNT
attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_HDIUTIL_LOG")" "detach, then a prompting attach" || return 1
}

test_pre_open_refuses_a_leftover_mount_that_will_not_detach() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(_pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 FAKE_HDIUTIL_FAIL=detach 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "run: hdiutil detach $FAKE_MNT" "names the command" || return 1
    assert_eq "detach $FAKE_MNT" "$(cat "$FAKE_HDIUTIL_LOG")" "never attaches silently" || return 1
}

test_pre_open_refuses_without_a_terminal() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(_pre_open enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs: this session is encrypted and needs a terminal to ask for the vault password." "says why" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "no hdiutil call, so no dialog" || return 1
}

test_pre_open_attaches_with_a_prompt() {
    _encrypted_session enc || return 1
    local rc=0
    _pre_open enc CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_HDIUTIL_LOG")" "one attach, no -stdinpass" || return 1
}

# An open that stops before claude runs detaches the vault its pre-open
# mounted; a vault a running conversation holds stays mounted.
_open() {  # name [answers] -> opens the session as a human at a terminal would; the mount stub tracks attach/detach
    printf '%s' "${2:-}" | FAKE_MOUNT_FLAG="$TEST_TMPDIR/mounted" CS_ASSUME_TTY=1 "$CS_BIN" "$1"
}

test_open_that_stops_detaches_the_vault_it_mounted() {
    _encrypted_session enc || return 1
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    local out rc=0
    out=$(_open enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_output_contains "$out" "still holds session.log in plaintext" "stops at the plaintext refusal" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)
detach $FAKE_MNT" "$(cat "$FAKE_HDIUTIL_LOG")" "attach, then detach on the way out" || return 1
}

test_open_that_stops_leaves_a_running_session_vault_mounted() {
    _encrypted_session enc || return 1
    : > "$TEST_TMPDIR/mounted"
    sleep 300 &
    local live=$! rc=0
    echo "$live" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    _open enc >/dev/null 2>&1 || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "joined the mount, never detached it" || return 1
}

# The resume prompt belongs to a session with a conversation to resume; one
# with none starts its first without asking. The fixture's state line is not in
# state-file form, so it records no conversation.
_bind_conversation() {  # name
    printf 'claude_session_id: %s\n' "33333333-3333-4333-8333-333333333333" \
        >> "$CS_SESSIONS_ROOT/$1/.cs/local/state"
}

test_open_cancelled_at_a_prompt_detaches_the_vault_it_mounted() {
    _encrypted_session enc || return 1
    _bind_conversation enc
    local out rc=0
    out=$(_open enc 2>&1) || rc=$?
    assert_eq "130" "$rc" "no answer to 'Continue previous conversation?' cancels" || return 1
    assert_output_contains "$out" "Continue previous conversation?" "stopped at the prompt" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)
detach $FAKE_MNT" "$(cat "$FAKE_HDIUTIL_LOG")" "attach, then detach on the way out" || return 1
}

test_open_that_stops_leaves_a_vault_another_holder_keeps() {
    _encrypted_session enc || return 1
    : > "$TEST_TMPDIR/mounted"
    sleep 300 &
    local holder=$! rc=0
    echo "$holder" > "$CS_SESSIONS_ROOT/enc/.cs/local/vault-holders"
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    _open enc >/dev/null 2>&1 || rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "joined the holder's mount, never detached it" || return 1
}

# The collision menu's session manager replaces this cs with the picker: that
# process no longer opens the vault, so it must not stay listed as a holder.
test_open_handing_off_to_the_session_manager_leaves_the_holders() {
    _encrypted_session enc || return 1
    : > "$TEST_TMPDIR/mounted"
    cat > "$TEST_TMPDIR/stub/cs-tui" <<EOF
#!/bin/sh
grep -qx "\$PPID" "$CS_SESSIONS_ROOT/enc/.cs/local/vault-holders" 2>/dev/null && echo listed > "$TEST_TMPDIR/tui-saw" || echo absent > "$TEST_TMPDIR/tui-saw"
EOF
    chmod +x "$TEST_TMPDIR/stub/cs-tui"
    sleep 300 &
    local live=$! out rc=0
    echo "$live" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    out=$(_open enc "3" 2>&1) || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_output_contains "$out" "3  session manager" "menu row 3 is the session manager" || return 1
    assert_eq "absent" "$(cat "$TEST_TMPDIR/tui-saw" 2>/dev/null)" "the picker's process is not a vault holder" || return 1
}

# A claude that copies the hdiutil log as it stood while it ran.
_claude_snapshot() {
    local c="$TEST_TMPDIR/claude-snap"
    printf '#!/bin/sh\ncp "$FAKE_HDIUTIL_LOG" "%s"\nexit 0\n' "$TEST_TMPDIR/during" > "$c"
    chmod +x "$c"
    printf '%s' "$c"
}

# Resuming, cs runs claude as its child: the vault stays mounted while claude
# runs, and cs, its last holder, detaches it once claude exits.
test_open_resuming_keeps_the_vault_while_claude_runs() {
    _encrypted_session enc || return 1
    _bind_conversation enc
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "y
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$TEST_TMPDIR/during" 2>/dev/null)" "mounted, no detach while claude runs" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)
detach $FAKE_MNT" "$(cat "$FAKE_HDIUTIL_LOG")" "detached after claude exits" || return 1
}

# Fresh, cs execs claude: cs is gone, and the SessionEnd waiter owns the detach.
test_open_fresh_leaves_the_detach_to_the_waiter() {
    _encrypted_session enc || return 1
    _bind_conversation enc
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_HDIUTIL_LOG")" "no detach from cs" || return 1
}

# A first open with no conversation to resume execs claude as a fresh start
# does, so the detach is the waiter's there too.
test_first_open_leaves_the_detach_to_the_waiter() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude without asking: $out" || return 1
    assert_output_not_contains "$out" "Continue previous conversation?" "nothing to resume, so no prompt" || return 1
    assert_eq "attach -nobrowse -mountpoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_HDIUTIL_LOG")" "no detach from cs" || return 1
}

# SessionEnd leaves a waiter that detaches the vault once the lead claude
# exits. The "claude" here is a sleep the test ends; the vault reads mounted.
HOOK_SESSION_END="$SCRIPT_DIR/../hooks/session-end.sh"

_end_conversation() {  # name reason claude_pid lead_pid
    printf '{"session_id":"11111111-2222-3333-4444-555555555555","reason":"%s"}' "$2" |
        CLAUDE_SESSION_NAME="$1" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/$1" \
        CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/$1/.cs" \
        CLAUDE_PID="$3" CS_LEAD_PID="$4" FAKE_MOUNTED=1 \
        bash "$HOOK_SESSION_END" >/dev/null 2>&1
}

_wait_for_log() {  # expected -> polls the hdiutil log up to 10 s
    local i=0
    while [ $i -lt 50 ]; do
        [ "$(cat "$FAKE_HDIUTIL_LOG")" = "$1" ] && return 0
        sleep 0.2; i=$((i + 1))
    done
    return 1
}

_waiter_gone() {  # name -> waits up to 10 s for the waiter to finish
    local f="$CS_SESSIONS_ROOT/$1/.cs/local/vault-waiter.pid" i=0
    while [ $i -lt 50 ]; do
        [ -e "$f" ] || return 0
        sleep 0.2; i=$((i + 1))
    done
    return 1
}

test_session_end_detaches_after_the_lead_exits() {
    _encrypted_session enc || return 1
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    [ -s "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { kill "$claude"; echo "  FAIL: no waiter recorded"; return 1; }
    sleep 1.5
    local early; early=$(cat "$FAKE_HDIUTIL_LOG")
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    assert_eq "" "$early" "no detach while claude still runs" || return 1
    _wait_for_log "detach $FAKE_MNT" || { echo "  FAIL: no detach after exit: $(cat "$FAKE_HDIUTIL_LOG")"; return 1; }
    _waiter_gone enc || { echo "  FAIL: waiter pid file left"; return 1; }
}

test_session_end_leaves_the_vault_for_clear_resume_and_non_leads() {
    _encrypted_session enc || return 1
    local case_ reason lead claude
    for case_ in "clear same" "resume same" "prompt_input_exit other"; do
        reason=${case_% *}
        sleep 300 &
        claude=$!
        if [ "${case_#* }" = same ]; then lead=$claude; else lead=1; fi
        _end_conversation enc "$reason" "$claude" "$lead"
        kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
        [ ! -e "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { echo "  FAIL: waiter started for $case_"; return 1; }
    done
    sleep 1.5
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "no detach for clear, resume or a non-lead" || return 1
}

test_session_end_ignores_a_session_cs_did_not_encrypt() {
    _encrypted_session enc || return 1
    rm "$CS_SESSIONS_ROOT/enc/.cs/local/vault"
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    sleep 1.5
    [ ! -e "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { echo "  FAIL: waiter started"; return 1; }
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "no detach" || return 1
}

test_session_end_waiter_spares_a_reopened_session() {
    _encrypted_session enc || return 1
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    sleep 300 &
    local reopened=$!
    echo "$reopened" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    _waiter_gone enc || { kill "$reopened"; echo "  FAIL: waiter still running"; return 1; }
    kill "$reopened" 2>/dev/null; wait "$reopened" 2>/dev/null
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "the new conversation keeps its mount" || return 1
}

test_session_end_waiter_spares_a_vault_a_holder_keeps() {
    _encrypted_session enc || return 1
    sleep 300 &
    local holder=$!
    echo "$holder" > "$CS_SESSIONS_ROOT/enc/.cs/local/vault-holders"
    sleep 0.1 &
    local claude=$!
    wait "$claude" 2>/dev/null
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    _waiter_gone enc || { kill "$holder"; echo "  FAIL: waiter still running"; return 1; }
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "no detach while a holder lives" || return 1
}

test_session_end_waiter_leaves_a_busy_vault_mounted() {
    _encrypted_session enc || return 1
    sleep 300 &
    local claude=$!
    FAKE_HDIUTIL_FAIL=detach _end_conversation enc prompt_input_exit "$claude" "$claude"
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    _waiter_gone enc || { echo "  FAIL: waiter still running"; return 1; }
    assert_eq "detach $FAKE_MNT" "$(cat "$FAKE_HDIUTIL_LOG")" "one plain detach, never -force" || return 1
}

run_test test_encrypt_refuses_off_macos
run_test test_encrypt_refuses_without_a_terminal
run_test test_encrypt_refuses_a_live_session
run_test test_encrypt_refuses_an_unknown_session
run_test test_encrypt_refuses_an_adopted_session
run_test test_encrypt_refuses_a_feature_worktree_name
run_test test_encrypt_refuses_when_any_vault_link_exists
run_test test_encrypt_refuses_a_real_claude_config_or_private
run_test test_encrypt_refuses_an_existing_pre_open
run_test test_encrypt_refuses_an_existing_container
run_test test_encrypt_builds_the_vault_and_detaches
run_test test_encrypt_builds_a_session_never_opened_on_this_machine
run_test test_encrypt_holds_the_session_lock_while_it_works
run_test test_encrypt_releases_the_session_lock_when_it_stops
run_test test_encrypt_refuses_a_readme_it_cannot_tag
run_test test_encrypt_stops_when_create_fails
run_test test_encrypt_stops_when_attach_fails
run_test test_encrypt_stops_on_a_failed_move_and_names_what_moved
run_test test_pre_open_joins_a_mount_held_by_a_running_session
run_test test_pre_open_joins_a_mount_whose_holder_is_alive_without_a_lock
run_test test_pre_open_stops_a_waiter_detach_in_flight
run_test test_pre_open_detaches_a_leftover_mount_and_asks_again
run_test test_pre_open_refuses_a_leftover_mount_that_will_not_detach
run_test test_pre_open_refuses_without_a_terminal
run_test test_pre_open_attaches_with_a_prompt
run_test test_open_that_stops_detaches_the_vault_it_mounted
run_test test_open_that_stops_leaves_a_running_session_vault_mounted
run_test test_open_cancelled_at_a_prompt_detaches_the_vault_it_mounted
run_test test_open_that_stops_leaves_a_vault_another_holder_keeps
run_test test_open_handing_off_to_the_session_manager_leaves_the_holders
run_test test_open_resuming_keeps_the_vault_while_claude_runs
run_test test_open_fresh_leaves_the_detach_to_the_waiter
run_test test_first_open_leaves_the_detach_to_the_waiter
run_test test_session_end_detaches_after_the_lead_exits
run_test test_session_end_leaves_the_vault_for_clear_resume_and_non_leads
run_test test_session_end_ignores_a_session_cs_did_not_encrypt
run_test test_session_end_waiter_spares_a_reopened_session
run_test test_session_end_waiter_spares_a_vault_a_holder_keeps
run_test test_session_end_waiter_leaves_a_busy_vault_mounted
report_results
