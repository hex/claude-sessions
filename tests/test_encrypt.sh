#!/usr/bin/env bash
# ABOUTME: Tests for cs -encrypt: the refusals, the vault it builds for an existing session,
# ABOUTME: and how it stops. diskutil, uname and mount are PATH stubs that log every call.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# The vault prompt draws a lock glyph when the shell exports CS_NERD_FONTS=1;
# these tests read the rows without it.
export CS_NERD_FONTS=0
# NO_COLOR blanks every colour cs draws; one test reads the palette's amber.
unset NO_COLOR

# PATH stubs: uname answers $FAKE_UNAME; diskutil logs its argv, one call per
# line, and fails the verb named in $FAKE_DISKUTIL_FAIL (create, attach or
# eject, or --help for the probe `diskutil image --help`). What create and
# attach read on stdin, the vault password, is kept in $FAKE_DISKUTIL_LOG.stdin
# with its length in bytes, one line per call, so a stray newline shows.
_stubs() {
    local d="$TEST_TMPDIR/stub"
    mkdir -p "$d"
    cat > "$d/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
EOF
    cat > "$d/diskutil" <<'EOF'
#!/bin/sh
verb=$1
[ "$1" = image ] && verb=$2
echo "$*" >> "$FAKE_DISKUTIL_LOG"
case "$verb" in create|attach) pw=$(cat; printf .); pw=${pw%.}; printf '%s [%s bytes]\n' "$pw" "${#pw}" >> "$FAKE_DISKUTIL_LOG.stdin" ;; esac
[ "$verb" = "${FAKE_DISKUTIL_FAIL:-}" ] && { echo "diskutil: $verb failed - stub" >&2; exit 1; }
# The first $FAKE_DISKUTIL_WRONG attaches answer as the real one does to a wrong password.
if [ "$verb" = "attach" ] && [ -n "${FAKE_DISKUTIL_WRONG:-}" ]; then
    n=$(grep -c ' attach ' "$FAKE_DISKUTIL_LOG")
    [ "$n" -le "$FAKE_DISKUTIL_WRONG" ] && { echo "Error: Incorrect passphrase"; exit 1; }
fi
# The verb named in $FAKE_DISKUTIL_HOLD never finishes by itself: it stays in
# flight until something stops it, or until the log is gone, so a test that
# fails leaves nothing running.
if [ "$verb" = "${FAKE_DISKUTIL_HOLD:-}" ]; then
    while [ -e "$FAKE_DISKUTIL_LOG" ]; do sleep 0.1; done
    exit 0
fi
# With $FAKE_LOCK_WATCH set, create records whether that lock names a live pid.
if [ "$verb" = "create" ] && [ -n "${FAKE_LOCK_WATCH:-}" ]; then
    p=$(cat "$FAKE_LOCK_WATCH" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo live; else echo "none:$p"; fi > "$FAKE_LOCK_WATCH.seen"
fi
# create makes the container, the one side effect cs relies on.
if [ "$verb" = "create" ]; then eval "last=\${$#}"; mkdir -p "$last"; fi
# With $FAKE_MOUNT_FLAG set, attach and eject flip the mount stub's answer.
if [ -n "${FAKE_MOUNT_FLAG:-}" ]; then
    [ "$verb" = "attach" ] && : > "$FAKE_MOUNT_FLAG"
    [ "$verb" = "eject" ] && rm -f "$FAKE_MOUNT_FLAG"
fi
# The real attach prints its device table, and the real eject a line.
if [ "$verb" = "attach" ]; then printf '/dev/disk9s1\tApple_APFS_Volume\t/stub/mount\n'; fi
if [ "$verb" = "eject" ]; then echo "Disk ejected"; fi
exit 0
EOF
    chmod +x "$d/uname" "$d/diskutil"
    export PATH="$d:$PATH"
    export FAKE_DISKUTIL_LOG="$TEST_TMPDIR/diskutil.log"
    : > "$FAKE_DISKUTIL_LOG"
    : > "$FAKE_DISKUTIL_LOG.stdin"
}

# The line a human types at a vault password prompt.
VAULT_PW_LINE='vault pw
'

_encrypt() {  # name -> runs cs -encrypt as a human at a terminal would, typing the new password twice
    printf '%s%s' "$VAULT_PW_LINE" "$VAULT_PW_LINE" | CS_ASSUME_TTY=1 "$CS_BIN" -encrypt "$@"
}

_vault_path() {  # name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# A refusal writes nothing: no diskutil call, no vault links, no pre-open.
_assert_nothing_written() {  # name
    local s="$CS_SESSIONS_ROOT/$1/.cs"
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
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
    assert_output_contains "$out" "cs -encrypt needs macOS (diskutil); Linux is not supported yet." "names the platform" || return 1
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
    assert_output_contains "$out" "enc: the session is live; close it, then encrypt." "names the live session" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_an_unknown_session() {
    _stubs
    local out rc=0
    out=$(_encrypt ghost-town 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "No such session: ghost-town" "names the missing session" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
}

test_encrypt_refuses_an_adopted_session() {
    _stubs
    mkdir -p "$TEST_TMPDIR/project/.cs/memory" "$TEST_TMPDIR/project/.cs/local"
    ln -s "$TEST_TMPDIR/project" "$CS_SESSIONS_ROOT/adopted"
    local out rc=0
    out=$(_encrypt adopted 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "adopted: an adopted session cannot be encrypted" "names the adopted session" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
}

test_encrypt_refuses_a_feature_worktree_name() {
    _stubs
    local out rc=0
    out=$(_encrypt enc@task 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc@task: encrypt the base session, not a feature worktree" "names the worktree" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
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
        assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called ($l)" || return 1
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
            : > "$FAKE_DISKUTIL_LOG"
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
}

test_encrypt_refuses_an_existing_container() {
    _stubs
    create_test_session enc >/dev/null
    mkdir -p "$(_vault_path enc)"
    local out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: $(_vault_path enc) already exists; cs -encrypt will not reuse or overwrite it." "names the container" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
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
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0 proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    mkdir -p "$proj"
    echo "conversation" > "$proj/44444444-4444-4444-8444-444444444444.jsonl"
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
    assert_eq "image create blank --encrypt --stdinpassphrase --format UDSB --size 50g --volumeName cs-enc --fs APFS $c
image attach --stdinpassphrase --nobrowse --mountPoint $s/vault-mnt $c
eject $s/vault-mnt" "$(cat "$FAKE_DISKUTIL_LOG")" "create, attach, then eject" || return 1
    assert_eq "vault pw [8 bytes]
vault pw [8 bytes]" "$(cat "$FAKE_DISKUTIL_LOG.stdin")" "the password typed once reaches create and attach on stdin, with no newline" || return 1
    assert_eq "conversation" "$(cat "$v/claude-config/projects/${proj##*/}/44444444-4444-4444-8444-444444444444.jsonl" 2>/dev/null)" \
        "the conversation moved to where the encrypted session's claude reads it" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: plaintext transcripts left at $proj"; return 1; }
    assert_output_contains "$out" "enc  new vault" "cs names the session and what it is making" || return 1
    assert_output_contains "$out" "    password › " "cs asks for the new password" || return 1
    assert_output_contains "$out" "    again › " "and asks for it again" || return 1
    # shellcheck disable=SC2088  # cs prints the literal ~ path
    assert_output_contains "$out" "  - this session's lines in ~/.claude/history.jsonl" "lists what stays in plaintext" || return 1
    assert_output_not_contains "$out" "this session's transcripts in" "the transcripts are not on that list: they moved" || return 1
    assert_output_not_contains "$out" "Apple_APFS_Volume" "diskutil's device table is not shown" || return 1
    assert_output_not_contains "$out" "Disk ejected" "nor its eject line" || return 1
}

# A conversations folder that is a link is left where it is: moving the link
# would move no conversation. The closing list then names it, since what it
# points to stays outside the vault in plain text.
test_encrypt_names_a_linked_conversations_folder_it_leaves() {
    _stubs
    _populated_session enc
    local proj real out rc=0
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    real="$TEST_TMPDIR/kept-elsewhere"
    mkdir -p "$real"
    echo "conversation" > "$real/44444444-4444-4444-8444-444444444444.jsonl"
    ln -s "$real" "$proj"
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "exit 0 (output: $out)" || return 1
    assert_eq "$real" "$(readlink "$proj")" "the link is left as it was" || return 1
    assert_eq "conversation" "$(cat "$real/44444444-4444-4444-8444-444444444444.jsonl")" "the conversation stays where the link points" || return 1
    assert_output_contains "$out" "  - this session's conversations: $proj is a link, so cs left it, and the folder it points to, outside the vault" "the closing list names the linked folder" || return 1
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

# cs -encrypt reads the terminal's theme before it draws its rows, as an open
# does: on a light terminal the new vault row takes the light palette's amber.
# Output goes to a pty, so cs draws in colour; the passwords come down a pipe,
# so no terminal query reads them, and COLORFGBG names the light background.
test_encrypt_prompt_follows_a_light_terminal() {
    _stubs
    _populated_session enc
    local run="$TEST_TMPDIR/encrypt-on-a-light-terminal" out light_amber
    cat > "$run" <<EOF
#!/bin/sh
printf '%s%s' '$VAULT_PW_LINE' '$VAULT_PW_LINE' | COLORFGBG='0;15' CS_ASSUME_TTY=1 '$CS_BIN' -encrypt enc
EOF
    chmod +x "$run"
    light_amber=$(printf '\033[38;2;162;122;58m')
    out=$(_pty_run "$run" 2>&1) || true
    # Matched as text: assert_output_contains reads a regex, where the
    # colour's [ opens a bracket expression.
    case "$out" in
        *"${light_amber}new vault"*) ;;
        *) echo "  FAIL: the new vault row is not drawn in the light palette (output: $out)"; return 1 ;;
    esac
}

# An open while cs -encrypt asks for passwords would race its moves; the
# session lock holds it off, and is gone once cs -encrypt ends.
test_encrypt_holds_the_session_lock_while_it_works() {
    _stubs
    _populated_session enc
    local lock="$CS_SESSIONS_ROOT/enc/.cs/session.lock" rc=0
    FAKE_LOCK_WATCH="$lock" _encrypt enc >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "encrypt succeeds" || return 1
    assert_eq "live" "$(cat "$lock.seen" 2>/dev/null)" "a live lock while diskutil runs" || return 1
    [ ! -e "$lock" ] || { echo "  FAIL: lock left after encrypt: $(cat "$lock")"; return 1; }
}

test_encrypt_releases_the_session_lock_when_it_stops() {
    _stubs
    _populated_session enc
    local lock="$CS_SESSIONS_ROOT/enc/.cs/session.lock" rc=0
    FAKE_DISKUTIL_FAIL=attach _encrypt enc >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "encrypt stops" || return 1
    [ ! -e "$lock" ] || { echo "  FAIL: lock left after a failed encrypt: $(cat "$lock")"; return 1; }
}

# The EXIT trap releases the lock of whatever sessions root cs runs under: a
# root holding a space, quotes and a $( is a path to release, never code to run.
test_encrypt_releases_the_lock_under_a_root_with_quotes() {
    _stubs
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/odd root/it's \"q\" \$(touch pwned)"
    mkdir -p "$CS_SESSIONS_ROOT"
    _populated_session enc
    local lock="$CS_SESSIONS_ROOT/enc/.cs/session.lock" rc=0
    (cd "$TEST_TMPDIR" && FAKE_DISKUTIL_FAIL=attach _encrypt enc >/dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "encrypt stops" || return 1
    [ ! -e "$lock" ] || { echo "  FAIL: lock left after a failed encrypt: $(cat "$lock")"; return 1; }
    [ ! -e "$TEST_TMPDIR/pwned" ] || { echo "  FAIL: the root's \$( ran as code"; return 1; }
}

# cs -encrypt checks that the session is not live, then takes its lock. An
# open in another terminal can take the lock between the two. cs -encrypt must
# then refuse, with nothing written, and leave the open's lock as it is: two
# processes each holding the session would run claude while the moves run.
# cs -encrypt is paused after its check by a stand-in awk that waits on a gate
# file while it reads the session README, and the open takes the lock
# meanwhile and stays alive, blocked on a fifo, until the asserts are done.
test_encrypt_refuses_an_open_that_took_the_lock_after_its_check() {
    _stubs
    _populated_session enc
    local meta="$CS_SESSIONS_ROOT/enc/.cs" shim="$TEST_TMPDIR/awkshim" real_awk
    local paused="$TEST_TMPDIR/awk.paused" gate="$TEST_TMPDIR/awk.gate"
    local opened="$TEST_TMPDIR/open.ready" fifo="$TEST_TMPDIR/open.fifo"
    local pid_encrypt pid_open rc=0 out="$TEST_TMPDIR/encrypt.out"
    real_awk=$(command -v awk)
    mkdir -p "$shim"
    cat > "$shim/awk" <<SHIM
#!/bin/bash
case "\$*" in
    *"/enc/.cs/README.md")
        if [ ! -e "$paused" ]; then
            touch "$paused"; until [ -e "$gate" ]; do sleep 0.05; done
        fi ;;
esac
exec "$real_awk" "\$@"
SHIM
    chmod +x "$shim/awk"
    PATH="$shim:$PATH" _encrypt enc >"$out" 2>&1 &
    pid_encrypt=$!
    wait_until test -e "$paused"
    assert_file_exists "$paused" "cs -encrypt reached its README read after the live check" \
        || { touch "$gate"; wait "$pid_encrypt"; return 1; }
    mkfifo "$fifo"
    LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta" READY="$opened" FIFO="$fifo" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        cs_interactive() { return 1; }
        acquire_session_lock "$LOCK_META" "" enc >/dev/null 2>&1 || exit 1
        : > "$READY"
        read -r _ <> "$FIFO"
    ' &
    pid_open=$!
    wait_until test -e "$opened"
    assert_file_exists "$opened" "the open took the session lock" \
        || { touch "$gate"; wait "$pid_encrypt"; kill "$pid_open" 2>/dev/null; wait "$pid_open"; return 1; }
    touch "$gate"
    wait "$pid_encrypt" || rc=$?
    local lock_now
    lock_now=$(cat "$meta/session.lock" 2>/dev/null)
    kill "$pid_open" 2>/dev/null; wait "$pid_open" 2>/dev/null
    assert_eq "1" "$rc" "cs -encrypt refuses" || return 1
    assert_eq "Error: enc: the session is live; close it, then encrypt." "$(cat "$out")" \
        "cs -encrypt names the running session" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "diskutil never called" || return 1
    assert_eq "$pid_open" "$lock_now" "the open still holds the session lock" || return 1
}

# Start a process that holds <lock file> through _cs_lock until killed, with
# no child: it blocks in bash's own read on a fifo. Its pid is MUTEX_HOLDER.
_hold_session_mutex() {  # lock file
    local ready="$TEST_TMPDIR/mutex.ready"
    mkfifo "$TEST_TMPDIR/mutex.fifo"
    bash -c 'source "$1"; _cs_lock "$2" || exit 1; : > "$3"; read -r _ <> "$4"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$1" "$ready" "$TEST_TMPDIR/mutex.fifo" &
    MUTEX_HOLDER=$!
    wait_until test -e "$ready"
    [ -e "$ready" ] || { echo "  FAIL: the holder never took $1"; return 1; }
}

# While another cs holds the openers' mutex past its five-second wait, that
# holder may be between reading a dead pid and removing the lock, so
# cs -encrypt refuses rather than going on without it, and writes nothing.
test_encrypt_refuses_while_the_openers_mutex_stays_held() {
    _stubs
    _populated_session enc
    local meta="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    _hold_session_mutex "$meta/session.mutex.lock" || return 1
    out=$(_encrypt enc 2>&1) || rc=$?
    kill "$MUTEX_HOLDER" 2>/dev/null; wait "$MUTEX_HOLDER" 2>/dev/null
    assert_eq "1" "$rc" "cs -encrypt refuses" || return 1
    assert_eq "Error: enc: another cs is opening this session ($meta/session.mutex.lock is held); try again in a moment." "$out" \
        "cs -encrypt names the held mutex" || return 1
    [ ! -e "$meta/session.lock" ] || { echo "  FAIL: session.lock written: $(cat "$meta/session.lock")"; return 1; }
    _assert_nothing_written enc || return 1
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

# The conversations move after everything under .cs/. When that move fails
# the vault stays mounted, since it may hold the only whole copy, the message
# names what has moved, and the session is not linked into the vault.
# Once the vault holds whole copies, what cs cannot remove outside it is no
# reason to stop: cs -encrypt names what is left in plain text and goes on.
test_encrypt_names_what_it_could_not_remove_outside_the_vault() {
    [ "$(id -u)" != "0" ] || { echo "  SKIP: root ignores the permission that makes the removal fail"; return 77; }
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" id=44444444-4444-4444-8444-444444444444 out rc=0 proj c
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    mkdir -p "$proj"
    echo "conversation" > "$proj/$id.jsonl"
    chmod 555 "$CS_TRANSCRIPTS_DIR"
    out=$(_encrypt enc 2>&1) || rc=$?
    chmod 755 "$CS_TRANSCRIPTS_DIR"
    c=$(_vault_path enc)
    assert_eq "0" "$rc" "cs -encrypt goes on: $out" || return 1
    assert_eq "conversation" "$(cat "$s/vault-mnt/claude-config/projects/${proj##*/}/$id.jsonl" 2>/dev/null)" "the vault holds the whole conversation" || return 1
    assert_output_contains "$out" "enc: the vault holds whole copies of this session's conversations, but cs could not remove them all from outside it. What is left in $proj is in plain text; remove it by hand. Removing it failed with: rmdir: " "names what is left outside" || return 1
    [ -L "$s/memory" ] || { echo "  FAIL: the session was not linked into the vault"; return 1; }
    assert_eq "image create blank --encrypt --stdinpassphrase --format UDSB --size 50g --volumeName cs-enc --fs APFS $c
image attach --stdinpassphrase --nobrowse --mountPoint $s/vault-mnt $c
eject $s/vault-mnt" "$(cat "$FAKE_DISKUTIL_LOG")" "the vault is built and detached" || return 1
}


# The new password is typed twice before anything is made: two that differ,
# or none, stop with the session as it was.
test_encrypt_refuses_passwords_that_differ_or_are_empty() {
    _stubs
    _populated_session enc
    local out rc=0
    out=$(printf 'one\ntwo\n' | CS_ASSUME_TTY=1 "$CS_BIN" -encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit for two that differ" || return 1
    assert_output_contains "$out" "enc: the two passwords differ; the session is unchanged." "says they differ" || return 1
    _assert_nothing_written enc || return 1
    rc=0
    out=$(printf '\n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit for none" || return 1
    assert_output_contains "$out" "enc: no password entered; the session is unchanged." "says none was entered" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_stops_when_create_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_DISKUTIL_FAIL=create _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: diskutil could not create the vault; the session is unchanged. diskutil said: diskutil: create failed - stub" "says nothing changed, and what diskutil said" || return 1
    assert_eq "narrative" "$(cat "$s/memory/narrative.alice.md")" "memory untouched" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: session changed"; return 1; }
}

test_encrypt_stops_when_attach_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_DISKUTIL_FAIL=attach _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: diskutil could not attach $(_vault_path enc); the session is unchanged. Delete the container before retrying. diskutil said: diskutil: attach failed - stub" "names the container, and what diskutil said" || return 1
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
_encrypted_session() {  # name -> leaves an encrypted session and clean diskutil logs
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
    : > "$FAKE_DISKUTIL_LOG"
    : > "$FAKE_DISKUTIL_LOG.stdin"
}

_pre_open() {  # name [env...] -> runs the hook from the session directory, as _run_pre_open does, with the password typed; cs's CS_LIVE_LOCK_PID goes in env
    local name="$1"; shift
    (cd "$CS_SESSIONS_ROOT/$name" && printf '%s' "$VAULT_PW_LINE" | env "$@" .cs/local/pre-open)
}

test_pre_open_joins_a_mount_held_by_a_running_session() {
    _encrypted_session enc || return 1
    sleep 300 &
    local live=$! rc=0
    echo "$live" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    _pre_open enc FAKE_MOUNTED=1 CS_LIVE_LOCK_PID="$live" >/dev/null 2>&1 || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "no prompt, no diskutil call" || return 1
}

# The pre-open takes cs's reading of the session lock from CS_LIVE_LOCK_PID
# and never reads the lock itself. Run without it (by hand, or by a cs that
# does not set it), a mount counts as held by no running session, even
# under a live lock: it is detached and the password asked for again.
test_pre_open_without_the_lock_pid_detaches_and_asks_again() {
    _encrypted_session enc || return 1
    sleep 300 &
    local live=$! rc=0
    echo "$live" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    _pre_open enc -u CS_LIVE_LOCK_PID FAKE_MOUNTED=1 CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "eject $FAKE_MNT
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "detach, then a prompting attach" || return 1
}

# A CS_LIVE_LOCK_PID that names no running process (a dead pid, or 0 and 00,
# which kill -0 takes for the caller's process group) is not a running
# session either: run by hand with one, the pre-open detaches the mount and
# asks for the password again.
test_pre_open_with_a_lock_pid_that_is_not_running_detaches_and_asks_again() {
    _encrypted_session enc || return 1
    sleep 300 &
    local dead=$! value rc
    kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null
    for value in "$dead" 0 00; do
        : > "$FAKE_DISKUTIL_LOG"
        rc=0
        _pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 CS_LIVE_LOCK_PID="$value" >/dev/null 2>&1 || rc=$?
        assert_eq "0" "$rc" "exit 0 with CS_LIVE_LOCK_PID=$value" || return 1
        assert_eq "eject $FAKE_MNT
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "CS_LIVE_LOCK_PID=$value: detach, then a prompting attach" || return 1
    done
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "joined: no detach, no prompt" || return 1
}

# A reopen that kills the waiter must also stop the detach the waiter started,
# or that detach lands on the volume the reopen just attached.
test_pre_open_stops_a_waiter_detach_in_flight() {
    _encrypted_session enc || return 1
    sleep 0.1 &
    local claude=$!
    wait "$claude" 2>/dev/null
    FAKE_DISKUTIL_HOLD=eject _end_conversation enc prompt_input_exit "$claude" "$claude"
    local f="$CS_SESSIONS_ROOT/enc/.cs/local/vault-detach.pid"
    # The detached waiter records its detach child later on a loaded machine.
    wait_until test -s "$f"
    [ -s "$f" ] || { echo "  FAIL: the waiter recorded no detach child"; return 1; }
    local detach rc=0
    detach=$(cat "$f")
    kill -0 "$detach" 2>/dev/null || { echo "  FAIL: the waiter's detach is not in flight before the reopen"; return 1; }
    _pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    local alive=0
    kill -0 "$detach" 2>/dev/null && alive=1
    assert_eq "0" "$rc" "reopen asks again" || return 1
    assert_eq "0" "$alive" "the waiter's detach is stopped when the reopen returns" || return 1
    assert_eq "eject $FAKE_MNT
eject $FAKE_MNT
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "the waiter's detach never finished" || return 1
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
    assert_eq "eject $FAKE_MNT
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "detach, then a prompting attach" || return 1
}

test_pre_open_refuses_a_leftover_mount_that_will_not_detach() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(_pre_open enc FAKE_MOUNTED=1 CS_ASSUME_TTY=1 FAKE_DISKUTIL_FAIL=eject 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "run: diskutil eject $FAKE_MNT" "names the command" || return 1
    assert_eq "eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "never attaches silently" || return 1
}

test_pre_open_refuses_without_a_terminal() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(_pre_open enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs: this session is encrypted and needs a terminal to ask for the vault password." "says why" || return 1
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "no diskutil call, so no dialog" || return 1
}

test_pre_open_attaches_with_a_prompt() {
    _encrypted_session enc || return 1
    local rc=0
    _pre_open enc CS_ASSUME_TTY=1 >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "one attach, the password on stdin" || return 1
}

# The hook shows its own prompt and nothing of diskutil's on a good password,
# and diskutil's error on a bad one.
test_pre_open_shows_its_prompt_and_only_diskutil_errors() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(_pre_open enc CS_ASSUME_TTY=1 2>&1) || rc=$?
    assert_eq "0" "$rc" "exit 0" || return 1
    assert_eq "Vault password for enc: " "$out" "the prompt, and no device table" || return 1
    assert_eq "vault pw [8 bytes]" "$(cat "$FAKE_DISKUTIL_LOG.stdin")" "the password reaches attach on stdin, with no newline" || return 1
    rc=0
    out=$(_pre_open enc CS_ASSUME_TTY=1 FAKE_DISKUTIL_FAIL=attach 2>&1) || rc=$?
    assert_eq "1" "$rc" "a refused password stops the open" || return 1
    assert_eq "Vault password for enc: 
cs: the vault did not open. diskutil said: diskutil: attach failed - stub" "$out" "what diskutil said" || return 1
}

# A wrong password is asked for again, three times at most; anything else
# diskutil refuses ends the open at once (the test above).
test_pre_open_asks_again_after_a_wrong_password() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(cd "$CS_SESSIONS_ROOT/enc" && printf 'nope\n%s' "$VAULT_PW_LINE" | CS_ASSUME_TTY=1 FAKE_DISKUTIL_WRONG=1 .cs/local/pre-open 2>&1) || rc=$?
    assert_eq "0" "$rc" "the second password opens it" || return 1
    assert_eq "Vault password for enc: 
cs: wrong password.
Vault password for enc: " "$out" "says it was wrong, asks again" || return 1
    assert_eq "nope [4 bytes]
vault pw [8 bytes]" "$(cat "$FAKE_DISKUTIL_LOG.stdin")" "each typed password reaches its own attach" || return 1
    : > "$FAKE_DISKUTIL_LOG"
    rc=0
    out=$(cd "$CS_SESSIONS_ROOT/enc" && printf 'a\nb\nc\nd\n' | CS_ASSUME_TTY=1 FAKE_DISKUTIL_WRONG=9 .cs/local/pre-open 2>&1) || rc=$?
    assert_eq "1" "$rc" "three wrong passwords stop the open" || return 1
    assert_eq "Vault password for enc: 
cs: wrong password.
Vault password for enc: 
cs: wrong password.
Vault password for enc: 
cs: three wrong passwords; the vault stays locked." "$out" "three asks, then the reason" || return 1
    assert_eq "3" "$(grep -c ' attach ' "$FAKE_DISKUTIL_LOG")" "a fourth password is never read" || return 1
}

# Through cs, the hook draws the rows cs hands it: the session and what the
# vault is, then the row that takes the password.
test_open_draws_the_vault_prompt_cs_hands_the_hook() {
    _encrypted_session enc || return 1
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    local out rc=0
    out=$(printf 'nope\n%s' "$VAULT_PW_LINE" | FAKE_DISKUTIL_WRONG=1 FAKE_MOUNT_FLAG="$TEST_TMPDIR/mounted" CS_ASSUME_TTY=1 "$CS_BIN" enc 2>&1) || rc=$?
    assert_eq "enc  vault locked
    password › 
    wrong password
    password › " "$(printf '%s\n' "$out" | head -4)" "the session, what the vault is, the ask, the wrong-password row" || return 1
}

# Ctrl-C at the hook's prompt ends it with 130: cs ends the same way, with
# no error line of its own.
test_open_ends_quietly_when_the_pre_open_was_cancelled() {
    _encrypted_session enc || return 1
    printf '#!/bin/bash\nexit 130\n' > "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open"
    local out rc=0
    out=$(_open enc 2>&1) || rc=$?
    assert_eq "130" "$rc" "cs exits as a cancelled command does" || return 1
    assert_eq "" "$out" "and prints nothing" || return 1
}

# A session an earlier cs encrypted carries the pre-open that cs wrote; the
# open replaces it with its own before running it. One written by hand has
# no cs mark on its second line and stays.
test_open_replaces_a_pre_open_another_cs_wrote() {
    _encrypted_session enc || return 1
    local hook="$CS_SESSIONS_ROOT/enc/.cs/local/pre-open" out rc=0
    printf '#!/bin/bash\n%s\necho ran >> "%s"\n' \
        "# Written by cs -encrypt: mounts this session vault, asking for its password at every open." \
        "$TEST_TMPDIR/earlier-hook-ran" > "$hook"
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    [ ! -e "$TEST_TMPDIR/earlier-hook-ran" ] || { echo "  FAIL: the earlier hook ran"; return 1; }
    assert_eq "image --help
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "cs checked for the image verbs, then its hook attached the vault" || return 1
    [ -x "$hook" ] || { echo "  FAIL: the rewritten pre-open is not executable"; return 1; }
}

# Where diskutil has no image verbs, the hook an earlier cs wrote is the one
# that still opens the vault, so the open runs it as it is.
test_open_keeps_an_earlier_pre_open_where_diskutil_has_no_image_verbs() {
    _encrypted_session enc || return 1
    local hook="$CS_SESSIONS_ROOT/enc/.cs/local/pre-open" out rc=0
    printf '#!/bin/bash\n%s\necho ran >> "%s"\n' \
        "# Written by cs -encrypt: mounts this session vault, asking for its password at every open." \
        "$TEST_TMPDIR/earlier-hook-ran" > "$hook"
    out=$(FAKE_DISKUTIL_FAIL=--help CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_eq "ran" "$(cat "$TEST_TMPDIR/earlier-hook-ran" 2>/dev/null)" "the earlier hook ran" || return 1
    assert_eq "image --help" "$(cat "$FAKE_DISKUTIL_LOG")" "cs asked diskutil for the image verbs and called nothing else" || return 1
}

# An open that stops before claude runs detaches the vault its pre-open
# mounted; a vault a running conversation holds stays mounted.
_open() {  # name [answers] -> opens the session as a human at a terminal would; an open that mounts the vault reads $VAULT_PW_LINE first; the mount stub tracks attach/eject
    printf '%s' "${2:-}" | FAKE_MOUNT_FLAG="$TEST_TMPDIR/mounted" CS_ASSUME_TTY=1 "$CS_BIN" "$1"
}

test_open_that_stops_detaches_the_vault_it_mounted() {
    _encrypted_session enc || return 1
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    local out rc=0
    out=$(_open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open stops" || return 1
    assert_output_contains "$out" "still holds session.log in plaintext" "stops at the plaintext refusal" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)
eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "attach, then detach on the way out" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "joined the mount, never detached it" || return 1
}

# The open's exit reads the lock by live_lock_pid's rule: "-1" and "0" name
# process groups and "+<pid>" is not a pid, so no running session holds the
# vault and the open that mounted it detaches it.
test_open_that_stops_reads_the_lock_by_the_one_lock_rule() {
    _encrypted_session enc || return 1
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    local text out rc
    for text in "-1" "0" "+$$"; do
        : > "$FAKE_DISKUTIL_LOG"
        rm -f "$TEST_TMPDIR/mounted"
        printf '%s\n' "$text" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
        rc=0
        out=$(_open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
        assert_eq "1" "$rc" "the open over a lock of '$text' stops: $out" || return 1
        assert_output_contains "$out" "still holds session.log in plaintext" "stops at the plaintext refusal" || return 1
        assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)
eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "a lock of '$text' does not keep the vault mounted" || return 1
    done
}

# An open over a mounted vault reads the lock by live_lock_pid's rule before
# its pre-open runs: "0" and "00" name a process group, not a running
# session, so the pre-open detaches the mount and asks for the password.
test_open_over_a_mounted_vault_reads_the_lock_by_the_one_lock_rule() {
    _encrypted_session enc || return 1
    echo "plaintext" > "$CS_SESSIONS_ROOT/enc/.cs/local/session.log"
    local text out rc
    for text in "0" "00"; do
        : > "$FAKE_DISKUTIL_LOG"
        : > "$TEST_TMPDIR/mounted"
        printf '%s\n' "$text" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
        rc=0
        out=$(_open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
        assert_eq "1" "$rc" "the open over a lock of '$text' stops: $out" || return 1
        assert_output_contains "$out" "still holds session.log in plaintext" "stops at the plaintext refusal" || return 1
        assert_eq "eject $FAKE_MNT
image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)
eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "a lock of '$text' does not join the mount without the password" || return 1
    done
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
    out=$(_open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
    assert_eq "130" "$rc" "no answer to 'Continue previous conversation?' cancels" || return 1
    assert_output_contains "$out" "Continue previous conversation?" "stopped at the prompt" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)
eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "attach, then detach on the way out" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "joined the holder's mount, never detached it" || return 1
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

# A claude that copies the diskutil log as it stood while it ran.
_claude_snapshot() {
    local c="$TEST_TMPDIR/claude-snap"
    printf '#!/bin/sh\ncp "$FAKE_DISKUTIL_LOG" "%s"\nexit 0\n' "$TEST_TMPDIR/during" > "$c"
    chmod +x "$c"
    printf '%s' "$c"
}

# Resuming, cs runs claude as its child: the vault stays mounted while claude
# runs, and cs, its last holder, detaches it once claude exits.
test_open_resuming_keeps_the_vault_while_claude_runs() {
    _encrypted_session enc || return 1
    _bind_conversation enc
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "${VAULT_PW_LINE}y
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$TEST_TMPDIR/during" 2>/dev/null)" "mounted, no detach while claude runs" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)
eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "detached after claude exits" || return 1
}

# Fresh, cs execs claude: cs is gone, and the SessionEnd waiter owns the detach.
test_open_fresh_leaves_the_detach_to_the_waiter() {
    _encrypted_session enc || return 1
    _bind_conversation enc
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "no detach from cs" || return 1
}

# A first open with no conversation to resume execs claude as a fresh start
# does, so the detach is the waiter's there too.
test_first_open_leaves_the_detach_to_the_waiter() {
    _encrypted_session enc || return 1
    local out rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_snapshot)" _open enc "$VAULT_PW_LINE" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude without asking: $out" || return 1
    assert_output_not_contains "$out" "Continue previous conversation?" "nothing to resume, so no prompt" || return 1
    assert_eq "image attach --stdinpassphrase --nobrowse --mountPoint $FAKE_MNT $(_vault_path enc)" "$(cat "$FAKE_DISKUTIL_LOG")" "no detach from cs" || return 1
}

# A session cs -encrypt sealed before it moved conversations keeps them in
# Claude Code's own projects folder, where the encrypted session's claude
# never looks. With the vault mounted, the open moves them in, as cs -encrypt
# does, or names what stops it and opens without moving anything.
_plain_conversation() {  # name, id, text -> writes the conversation outside the vault; prints its folder
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/$1")"
    mkdir -p "$proj"
    printf '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"%s"}}\n' "$3" > "$proj/$2.jsonl"
    printf '%s' "$proj"
}

_vault_projects() {  # name -> the folder in the vault where the session's claude keeps its conversations
    printf '%s/.cs/vault-mnt/claude-config/projects/%s' "$CS_SESSIONS_ROOT/$1" "$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/$1")"
}

_claude_args() {  # -> a claude that writes its arguments, one a line, to $TEST_TMPDIR/claude-args
    local c="$TEST_TMPDIR/claude-args-stub"
    cat > "$c" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$TEST_TMPDIR/claude-args"
EOF
    chmod +x "$c"
    printf '%s' "$c"
}

test_open_moves_conversations_left_outside_the_vault() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "before the vault")
    vault=$(_vault_projects enc)
    printf 'claude_session_id: %s\n' "$id" >> "$CS_SESSIONS_ROOT/enc/.cs/local/state"
    out=$(CLAUDE_CODE_BIN="$(_claude_args)" _open enc "${VAULT_PW_LINE}y
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_output_contains "$out" "enc: moved this session's conversations from $proj into its vault." "says what it moved" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: plaintext conversations left at $proj"; return 1; }
    assert_file_contains "$vault/$id.jsonl" "before the vault" "the conversation is where the session's claude reads it" || return 1
    assert_eq "$id" "$(awk 'prev == "--resume" { print } { prev = $0 }' "$TEST_TMPDIR/claude-args")" "claude resumes it" || return 1
    rc=0
    out=$(CLAUDE_CODE_BIN="$(_claude_args)" _open enc "${VAULT_PW_LINE}y
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the next open reaches claude: $out" || return 1
    assert_output_not_contains "$out" "moved this session's conversations" "the next open has nothing to move" || return 1
}

# A session opened since it was encrypted has a folder of its own in the
# vault already: the conversations from outside join it. Claude Code makes an
# empty memory/ in every project folder, so both sides have one; an empty
# folder holds nothing to lose, and it is no reason to move nothing.
test_open_moves_conversations_beside_those_in_the_vault() {
    _encrypted_session enc || return 1
    local old=44444444-4444-4444-8444-444444444444 new=55555555-5555-4555-8555-555555555555 proj vault out rc=0
    proj=$(_plain_conversation enc "$old" "before the vault")
    mkdir -p "$proj/$old/subagents" "$proj/memory"
    echo "agent" > "$proj/$old/subagents/agent-a.jsonl"
    vault=$(_vault_projects enc)
    mkdir -p "$vault/memory"
    echo "in the vault" > "$vault/$new.jsonl"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_output_contains "$out" "enc: moved this session's conversations from $proj into its vault." "says what it moved" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: plaintext conversations left at $proj"; return 1; }
    assert_file_contains "$vault/$old.jsonl" "before the vault" "the conversation from outside joined the vault's" || return 1
    assert_eq "agent" "$(cat "$vault/$old/subagents/agent-a.jsonl" 2>/dev/null)" "with its subagents" || return 1
    assert_eq "in the vault" "$(cat "$vault/$new.jsonl")" "the vault's own conversation is untouched" || return 1
}

test_open_moves_nothing_when_a_conversation_is_on_both_sides() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 other=66666666-6666-4666-8666-666666666666 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "outside")
    _plain_conversation enc "$other" "also outside" >/dev/null
    vault=$(_vault_projects enc)
    mkdir -p "$vault"
    echo "inside" > "$vault/$id.jsonl"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open goes on: $out" || return 1
    assert_output_contains "$out" "enc: $proj/$id.jsonl is in the vault too, as .cs/claude-config/projects/${proj##*/}/$id.jsonl, so cs moved none of the conversations in $proj. Keep the copy you want in the vault, remove the other, then reopen." "names the clash and what to do" || return 1
    assert_file_contains "$proj/$id.jsonl" "outside" "the conversation outside is untouched" || return 1
    assert_eq "inside" "$(cat "$vault/$id.jsonl")" "the one in the vault is untouched" || return 1
    assert_file_contains "$proj/$other.jsonl" "also outside" "nothing else moved" || return 1
}

test_open_moves_nothing_through_a_linked_conversations_folder() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj real out rc=0
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    real="$TEST_TMPDIR/kept-elsewhere"
    mkdir -p "$real"
    echo "conversation" > "$real/$id.jsonl"
    ln -s "$real" "$proj"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open goes on: $out" || return 1
    assert_output_contains "$out" "enc: $proj is a link, so cs moved nothing from it; the conversations in the folder it points to stay outside the vault, in plain text." "says what stays in plain text" || return 1
    assert_eq "$real" "$(readlink "$proj")" "the link is left as it was" || return 1
    assert_eq "conversation" "$(cat "$real/$id.jsonl")" "the conversation stays where the link points" || return 1
    [ ! -e "$(_vault_projects enc)/$id.jsonl" ] || { echo "  FAIL: the conversation was moved through the link"; return 1; }
}

# Claude Code lists each running claude in sessions/<pid>.json in its config
# folder, with the folder it runs in; one running in the session outside cs
# writes its conversation outside the vault.
test_open_moves_nothing_while_a_claude_writes_outside_the_vault() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj out rc=0 dir
    proj=$(_plain_conversation enc "$id" "outside")
    dir=$(cd "$CS_SESSIONS_ROOT/enc" && pwd -P)
    sleep 300 &
    local live=$!
    mkdir -p "$HOME/.claude/sessions"
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s","kind":"interactive"}' "$live" "$id" "$dir" > "$HOME/.claude/sessions/$live.json"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    assert_eq "0" "$rc" "the open goes on: $out" || return 1
    assert_output_contains "$out" "enc: a claude (pid $live) runs in this session outside cs and writes its conversations to $proj, so cs moved none of them into the vault. Reopen once it has ended." "names the running claude" || return 1
    assert_file_contains "$proj/$id.jsonl" "outside" "the conversation outside is untouched" || return 1
    [ ! -e "$(_vault_projects enc)/$id.jsonl" ] || { echo "  FAIL: the conversation was moved while claude wrote it"; return 1; }
}

# A vault with no room: cp and mv, asked to carry something out of the
# conversations folder outside the vault, write each file cut short where it
# would land, then fail as a full disk makes them. Everything else they do
# for real.
_vault_without_room() {
    local d="$TEST_TMPDIR/stub" tool real
    for tool in cp mv; do
        real=$(PATH=/bin:/usr/bin command -v "$tool")
        cat > "$d/$tool" <<EOF
#!/bin/sh
for last in "\$@"; do :; done
case "\$last" in "\$CS_TRANSCRIPTS_DIR"/*) exec $real "\$@" ;; esac
crossing=0
for arg in "\$@"; do
    case "\$arg" in
        "\$CS_TRANSCRIPTS_DIR"/*)
            crossing=1
            land=\$last
            [ -d "\$last" ] && land="\$last/\${arg##*/}"
            /bin/cp -pPR "\$arg" "\$last"
            find "\$land" -type f -exec sh -c ': > "\$1"' _ {} \;
            ;;
    esac
done
[ "\$crossing" = 1 ] || exec $real "\$@"
echo "$tool: \$last: No space left on device" >&2
exit 1
EOF
        chmod +x "$d/$tool"
    done
}

# A copy into the vault that stops part-way leaves the conversations outside
# whole and nothing of them under the session's folder in the vault, where
# the next open would bind a conversation cut short.
test_open_leaves_no_cut_conversation_in_a_vault_without_room() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "before the vault")
    vault=$(_vault_projects enc)
    _vault_without_room
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "" "$(find "$FAKE_MNT" -name '*.jsonl')" "the vault holds nothing of the conversation" || return 1
    [ ! -e "$vault" ] || { echo "  FAIL: the vault has a folder for the session"; return 1; }
    assert_file_contains "$proj/$id.jsonl" "before the vault" "the conversation outside is whole" || return 1
    assert_eq "1" "$rc" "the open stops: $out" || return 1
    assert_output_contains "$out" "enc: could not copy the session's conversations from $proj into its vault. They are all still in $proj, whole, and the vault holds none of them. cp said: cp: " "names the whole copy" || return 1
}

test_encrypt_leaves_no_cut_conversation_in_a_vault_without_room() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" id=44444444-4444-4444-8444-444444444444 out rc=0 proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    mkdir -p "$proj"
    echo "conversation" > "$proj/$id.jsonl"
    _vault_without_room
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "" "$(find "$s/vault-mnt" -name '*.jsonl')" "the vault holds nothing of the conversation" || return 1
    assert_eq "conversation" "$(cat "$proj/$id.jsonl")" "the conversation outside is whole" || return 1
    assert_eq "1" "$rc" "cs -encrypt stops: $out" || return 1
    assert_output_contains "$out" "enc: could not copy the session's conversations ($proj) into the vault. They are all still there, whole, and the vault holds none of them. Already moved: .cs/memory .cs/plans .cs/local/session.log .cs/local/mail .cs/local/pending-handoff .cs/handoffs .cs/checkpoints .cs/narrative-archive. The vault is still mounted at .cs/vault-mnt; finish by hand or move those back, then detach it. cp said: cp: " "names the whole copy and what moved" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: the session was linked into the vault"; return 1; }
}

# A move that stopped after the vault had its copies leaves the same content
# on both sides. That is no clash: the copy outside goes, and the rest moves.
test_open_removes_a_copy_outside_that_the_vault_already_holds() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 other=66666666-6666-4666-8666-666666666666 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "moved before")
    _plain_conversation enc "$other" "still outside" >/dev/null
    mkdir -p "$proj/$id/subagents"
    echo "agent" > "$proj/$id/subagents/agent-a.jsonl"
    vault=$(_vault_projects enc)
    mkdir -p "$vault"
    cp -pR "$proj/$id.jsonl" "$proj/$id" "$vault/"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_output_not_contains "$out" "is in the vault too" "the same content on both sides is no clash" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: plaintext conversations left at $proj: $(ls -A "$proj")"; return 1; }
    assert_file_contains "$vault/$id.jsonl" "moved before" "the vault keeps its copy" || return 1
    assert_eq "agent" "$(cat "$vault/$id/subagents/agent-a.jsonl" 2>/dev/null)" "with its subagents" || return 1
    assert_file_contains "$vault/$other.jsonl" "still outside" "the conversation only outside moved in" || return 1
}

test_open_names_what_it_could_not_remove_outside_the_vault() {
    [ "$(id -u)" != "0" ] || { echo "  SKIP: root ignores the permission that makes the removal fail"; return 77; }
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "before the vault")
    vault=$(_vault_projects enc)
    chmod 555 "$CS_TRANSCRIPTS_DIR"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    chmod 755 "$CS_TRANSCRIPTS_DIR"
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_file_contains "$vault/$id.jsonl" "before the vault" "the vault holds the whole conversation" || return 1
    assert_output_contains "$out" "enc: the vault holds whole copies of this session's conversations, but cs could not remove them all from outside it. What is left in $proj is in plain text; remove it by hand. Removing it failed with: rmdir: " "names what is left outside" || return 1
}

# An empty folder in the vault holds nothing to lose either: the folder from
# outside takes its place.
test_open_moves_a_folder_over_an_empty_one_in_the_vault() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj vault out rc=0
    proj=$(_plain_conversation enc "$id" "before the vault")
    mkdir -p "$proj/memory"
    echo "note" > "$proj/memory/n.md"
    vault=$(_vault_projects enc)
    mkdir -p "$vault/memory"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    assert_output_not_contains "$out" "is in the vault too" "an empty folder in the vault is no clash" || return 1
    assert_eq "note" "$(cat "$vault/memory/n.md" 2>/dev/null)" "the folder from outside is the vault's now" || return 1
    assert_eq "n.md" "$(ls -A "$vault/memory")" "and holds only what it held outside" || return 1
    assert_file_contains "$vault/$id.jsonl" "before the vault" "the conversation moved too" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: plaintext conversations left at $proj"; return 1; }
}

# The open says what it did: that it moved conversations only when it moved
# one, what else it moved by name, and what it only removed outside.
test_open_says_it_moved_conversations_only_when_it_moved_one() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 proj vault out rc=0
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/enc")"
    vault=$(_vault_projects enc)
    mkdir -p "$proj/memory" "$vault"
    echo "in the vault" > "$vault/$id.jsonl"
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open reaches claude: $out" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: the empty folder is left at $proj"; return 1; }
    assert_output_not_contains "$out" "moved" "an empty folder outside is removed without a word" || return 1

    mkdir -p "$proj"
    echo "index" > "$proj/sessions-index.json"
    rc=0
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the second open reaches claude: $out" || return 1
    assert_eq "index" "$(cat "$vault/sessions-index.json" 2>/dev/null)" "the file moved" || return 1
    assert_output_contains "$out" "enc: moved sessions-index.json from $proj into its vault.$" "names what moved" || return 1
    assert_output_not_contains "$out" "conversations" "and calls it no conversation" || return 1

    mkdir -p "$proj"
    cp -p "$vault/$id.jsonl" "$proj/$id.jsonl"
    rc=0
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the third open reaches claude: $out" || return 1
    [ ! -e "$proj" ] || { echo "  FAIL: the copy is left at $proj"; return 1; }
    assert_output_contains "$out" "enc: removed from $proj what its vault already holds: $id.jsonl.$" "names the copy it removed outside" || return 1
    assert_output_not_contains "$out" ": moved" "and moved nothing" || return 1
}

# Two opens that reach the move together would both copy: the move runs
# under the openers' mutex, and an open that cannot take it moves nothing.
test_open_moves_nothing_while_another_cs_holds_the_openers_mutex() {
    _encrypted_session enc || return 1
    local id=44444444-4444-4444-8444-444444444444 meta="$CS_SESSIONS_ROOT/enc/.cs" proj out rc=0
    proj=$(_plain_conversation enc "$id" "before the vault")
    _hold_session_mutex "$meta/session.mutex.lock" || return 1
    out=$(_open enc "${VAULT_PW_LINE}n
" 2>&1) || rc=$?
    kill "$MUTEX_HOLDER" 2>/dev/null; wait "$MUTEX_HOLDER" 2>/dev/null
    assert_file_contains "$proj/$id.jsonl" "before the vault" "the conversation outside is untouched" || return 1
    [ ! -e "$(_vault_projects enc)" ] || { echo "  FAIL: the vault has a folder for the session"; return 1; }
    assert_eq "1" "$rc" "the open stops: $out" || return 1
    assert_output_contains "$out" "enc: another cs is opening this session ($meta/session.mutex.lock is held), so cs moved none of its conversations into the vault; try again in a moment." "names the held mutex" || return 1
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

# The waiter is detached and acts once the lead has exited, later on a loaded
# machine, so these wait on what it leaves behind; non-zero only at the guard.
_log_is() {  # expected
    [ "$(cat "$FAKE_DISKUTIL_LOG")" = "$1" ]
}

_wait_for_log() {  # expected -> waits until the diskutil log reads exactly that
    wait_until _log_is "$1"
}

_waiter_gone() {  # name -> waits until the waiter has removed its pid file
    wait_until test ! -e "$CS_SESSIONS_ROOT/$1/.cs/local/vault-waiter.pid"
}

test_session_end_detaches_after_the_lead_exits() {
    _encrypted_session enc || return 1
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    [ -s "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { kill "$claude"; echo "  FAIL: no waiter recorded"; return 1; }
    sleep 1.5
    local early; early=$(cat "$FAKE_DISKUTIL_LOG")
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    assert_eq "" "$early" "no detach while claude still runs" || return 1
    _wait_for_log "eject $FAKE_MNT" || { echo "  FAIL: no detach after exit: $(cat "$FAKE_DISKUTIL_LOG")"; return 1; }
    _waiter_gone enc || { echo "  FAIL: waiter pid file left"; return 1; }
}

# The detach child's pid file is written by the waiter long after the open
# checked the session; a link planted there since must not carry the write.
test_session_end_detach_pid_does_not_follow_a_link() {
    _encrypted_session enc || return 1
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    printf 'USER-OWNED\n' > "$t/victim"
    ln -s "$t/victim" "$CS_SESSIONS_ROOT/enc/.cs/local/vault-detach.pid"
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    _wait_for_log "eject $FAKE_MNT" || { echo "  FAIL: no detach after exit: $(cat "$FAKE_DISKUTIL_LOG")"; return 1; }
    _waiter_gone enc || { echo "  FAIL: waiter pid file left"; return 1; }
    assert_eq "USER-OWNED" "$(cat "$t/victim")" "the link's target is untouched" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "no detach for clear, resume or a non-lead" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "no detach" || return 1
}

# While git tracks .cs/local the waiter still detaches the vault when claude
# exits (a mounted vault left behind is the worse outcome), but records no pid
# there: the tracked directory is left as git has it.
test_session_end_waiter_records_nothing_while_git_tracks_the_control_files() {
    _encrypted_session enc || return 1
    local s="$CS_SESSIONS_ROOT/enc" changed
    git -C "$s" init -q && git -C "$s" add -f .cs/local \
        && git -C "$s" -c user.name=test -c user.email=test@example.com commit -q -m "ship the control directory" \
        || { echo "  FAIL: fixture commit failed"; return 1; }
    assert_eq "" "$(git -C "$s" status --porcelain --ignored -- .cs/local)" "the fixture starts clean" || return 1
    sleep 300 &
    local claude=$!
    _end_conversation enc prompt_input_exit "$claude" "$claude"
    changed=$(git -C "$s" status --porcelain --ignored -- .cs/local)
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    assert_eq "" "$changed" "no waiter pid lands in the tracked .cs/local" || return 1
    _wait_for_log "eject $FAKE_MNT" || { echo "  FAIL: no detach after exit: $(cat "$FAKE_DISKUTIL_LOG")"; return 1; }
    sleep 0.5
    changed=$(git -C "$s" status --porcelain --ignored -- .cs/local)
    assert_eq "" "$changed" "nor a detach pid once the waiter has run" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "the new conversation keeps its mount" || return 1
}

# The waiter reads the lock by live_lock_pid's rule: a lock of "-1", "0" or
# "+<pid>" written after SessionEnd names no reopened conversation, so the
# waiter detaches the vault once the lead claude exits.
test_session_end_waiter_reads_the_lock_by_the_one_lock_rule() {
    _encrypted_session enc || return 1
    local text claude
    for text in "-1" "0" "+$$"; do
        : > "$FAKE_DISKUTIL_LOG"
        sleep 300 &
        claude=$!
        _end_conversation enc prompt_input_exit "$claude" "$claude"
        printf '%s\n' "$text" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
        kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
        _waiter_gone enc || { echo "  FAIL: waiter still running over a lock of '$text'"; return 1; }
        assert_eq "eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "a lock of '$text' does not keep the vault mounted" || return 1
    done
}

# A waiter whose cs-shared.sh lacks live_lock_pid cannot read the lock by the
# one rule, so it leaves the vault mounted for the next open to handle, even
# over the lock of the claude that has just exited.
test_session_end_waiter_without_the_lock_rule_keeps_the_vault() {
    _encrypted_session enc || return 1
    local partial="$TEST_TMPDIR/partial-hooks"
    mkdir -p "$partial"
    cp "$SCRIPT_DIR/../hooks/"*.sh "$partial/"
    printf '\nunset -f live_lock_pid\n' >> "$partial/cs-shared.sh"
    sleep 300 &
    local claude=$!
    echo "$claude" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    printf '{"session_id":"11111111-2222-3333-4444-555555555555","reason":"prompt_input_exit"}' |
        CLAUDE_SESSION_NAME=enc CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/enc" \
        CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/enc/.cs" \
        CLAUDE_PID="$claude" CS_LEAD_PID="$claude" FAKE_MOUNTED=1 \
        bash "$partial/session-end.sh" >/dev/null 2>&1
    [ -s "$CS_SESSIONS_ROOT/enc/.cs/local/vault-waiter.pid" ] || { kill "$claude"; echo "  FAIL: no waiter recorded"; return 1; }
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    _waiter_gone enc || { echo "  FAIL: waiter still running"; return 1; }
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "the vault stays mounted" || return 1
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
    assert_eq "" "$(cat "$FAKE_DISKUTIL_LOG")" "no detach while a holder lives" || return 1
}

test_session_end_waiter_leaves_a_busy_vault_mounted() {
    _encrypted_session enc || return 1
    sleep 300 &
    local claude=$!
    FAKE_DISKUTIL_FAIL=eject _end_conversation enc prompt_input_exit "$claude" "$claude"
    kill "$claude" 2>/dev/null; wait "$claude" 2>/dev/null
    _waiter_gone enc || { echo "  FAIL: waiter still running"; return 1; }
    assert_eq "eject $FAKE_MNT" "$(cat "$FAKE_DISKUTIL_LOG")" "one plain detach, never -force" || return 1
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
run_test test_encrypt_names_a_linked_conversations_folder_it_leaves
run_test test_encrypt_builds_a_session_never_opened_on_this_machine
run_test test_encrypt_prompt_follows_a_light_terminal
run_test test_encrypt_holds_the_session_lock_while_it_works
run_test test_encrypt_releases_the_session_lock_when_it_stops
run_test test_encrypt_releases_the_lock_under_a_root_with_quotes
run_test test_encrypt_refuses_an_open_that_took_the_lock_after_its_check
run_test test_encrypt_refuses_while_the_openers_mutex_stays_held
run_test test_encrypt_refuses_a_readme_it_cannot_tag
run_test test_encrypt_names_what_it_could_not_remove_outside_the_vault
run_test test_encrypt_refuses_passwords_that_differ_or_are_empty
run_test test_encrypt_stops_when_create_fails
run_test test_encrypt_stops_when_attach_fails
run_test test_encrypt_stops_on_a_failed_move_and_names_what_moved
run_test test_pre_open_joins_a_mount_held_by_a_running_session
run_test test_pre_open_without_the_lock_pid_detaches_and_asks_again
run_test test_pre_open_with_a_lock_pid_that_is_not_running_detaches_and_asks_again
run_test test_pre_open_joins_a_mount_whose_holder_is_alive_without_a_lock
run_test test_pre_open_stops_a_waiter_detach_in_flight
run_test test_pre_open_detaches_a_leftover_mount_and_asks_again
run_test test_pre_open_refuses_a_leftover_mount_that_will_not_detach
run_test test_pre_open_refuses_without_a_terminal
run_test test_pre_open_attaches_with_a_prompt
run_test test_pre_open_shows_its_prompt_and_only_diskutil_errors
run_test test_pre_open_asks_again_after_a_wrong_password
run_test test_open_draws_the_vault_prompt_cs_hands_the_hook
run_test test_open_ends_quietly_when_the_pre_open_was_cancelled
run_test test_open_replaces_a_pre_open_another_cs_wrote
run_test test_open_keeps_an_earlier_pre_open_where_diskutil_has_no_image_verbs
run_test test_open_that_stops_detaches_the_vault_it_mounted
run_test test_open_that_stops_leaves_a_running_session_vault_mounted
run_test test_open_that_stops_reads_the_lock_by_the_one_lock_rule
run_test test_open_over_a_mounted_vault_reads_the_lock_by_the_one_lock_rule
run_test test_open_cancelled_at_a_prompt_detaches_the_vault_it_mounted
run_test test_open_that_stops_leaves_a_vault_another_holder_keeps
run_test test_open_handing_off_to_the_session_manager_leaves_the_holders
run_test test_open_resuming_keeps_the_vault_while_claude_runs
run_test test_open_fresh_leaves_the_detach_to_the_waiter
run_test test_first_open_leaves_the_detach_to_the_waiter
run_test test_open_moves_conversations_left_outside_the_vault
run_test test_open_moves_conversations_beside_those_in_the_vault
run_test test_open_moves_nothing_when_a_conversation_is_on_both_sides
run_test test_open_moves_nothing_through_a_linked_conversations_folder
run_test test_open_moves_nothing_while_a_claude_writes_outside_the_vault
run_test test_open_leaves_no_cut_conversation_in_a_vault_without_room
run_test test_encrypt_leaves_no_cut_conversation_in_a_vault_without_room
run_test test_open_removes_a_copy_outside_that_the_vault_already_holds
run_test test_open_names_what_it_could_not_remove_outside_the_vault
run_test test_open_moves_a_folder_over_an_empty_one_in_the_vault
run_test test_open_says_it_moved_conversations_only_when_it_moved_one
run_test test_open_moves_nothing_while_another_cs_holds_the_openers_mutex
run_test test_session_end_detaches_after_the_lead_exits
run_test test_session_end_detach_pid_does_not_follow_a_link
run_test test_session_end_leaves_the_vault_for_clear_resume_and_non_leads
run_test test_session_end_ignores_a_session_cs_did_not_encrypt
run_test test_session_end_waiter_records_nothing_while_git_tracks_the_control_files
run_test test_session_end_waiter_spares_a_reopened_session
run_test test_session_end_waiter_reads_the_lock_by_the_one_lock_rule
run_test test_session_end_waiter_without_the_lock_rule_keeps_the_vault
run_test test_session_end_waiter_spares_a_vault_a_holder_keeps
run_test test_session_end_waiter_leaves_a_busy_vault_mounted
report_results
