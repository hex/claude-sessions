#!/usr/bin/env bash
# ABOUTME: Concurrency tests for cs-secrets: locking, atomic writes, signals
# ABOUTME: Split from test_cs_secrets.sh because these sleeps are the gate's long pole

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

# Override setup to use encrypted backend with a test-scoped secrets dir
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_SECRETS_BACKEND="encrypted"
    export CS_SECRETS_PASSWORD="test-password-for-ci"
    export HOME="$TEST_TMPDIR/home"
    export CLAUDE_SESSION_NAME="test-session"
    # No age anywhere, so export-file deterministically takes the password
    # (.enc) path even on a host that has age installed. The path does not
    # exist, which the CS_AGE_BIN seam reads as "no age on this machine".
    export CS_AGE_BIN="$TEST_TMPDIR/no-such-age"
    mkdir -p "$CS_SESSIONS_ROOT" "$HOME"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_SECRETS_BACKEND CS_SECRETS_PASSWORD CLAUDE_SESSION_NAME 2>/dev/null || true
    # Restore HOME
    export HOME="$ORIGINAL_HOME"
}

# Save real HOME before tests override it
ORIGINAL_HOME="$HOME"

# --- Sync-file test helpers ---

# Reproduce the machine identifier cs-secrets uses to name per-machine sync
# files (hostname-derived, matches age_get_machine_id in bin/cs-secrets).
_machine_id() {
    local user host
    user="${USER:-}"
    [ -n "$user" ] || user=$(id -un 2>/dev/null) || user=""
    host=$(hostname -s 2>/dev/null || hostname 2>/dev/null) || host=""
    host=${host//$'\r'/}
    printf '%s@%s' "${user:-unknown}" "${host:-unknown}"
}

# The PATH to run cs-secrets under when a test needs the password (.enc) export
# path. age is disabled through the CS_AGE_BIN seam that setup exports, so the
# PATH itself needs no surgery: a whitelist-rebuilt PATH could not start the
# interpreter at all on some hosts, which surfaced as a bare exit 127.
_ageless_path() {
    printf '%s' "$PATH"
}

# Encrypt a JSON payload into a sync file with the shared test password, to
# simulate a file another machine (or a legacy export) committed to git. Fails
# loud: a seed that silently produced nothing turns every downstream assertion
# into a lie about the import rather than about the seeding.
_seed_enc_sync_file() {
    local path="$1" json="$2" rc=0
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$json" | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$path" -pass "pass:$CS_SECRETS_PASSWORD" || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$path" ]; then
        echo "  FAIL: could not seed sync file $path (openssl exit $rc, $(ls -l "$path" 2>&1))"
        return 1
    fi
}

# Print what an import actually did when an assertion about its result fails.
# The import's own summary ("Imported N secret(s) from M sync file(s)" /
# "Skipped X undecryptable file(s)") names which candidate files it accepted,
# which distinguishes a file that was never a candidate from one that was
# rejected during decrypt or validation.
_report_import() {
    local rc="$1" out="$2" meta="$3"
    echo "    import rc=$rc, output: $out"
    ls -l "$meta"/secrets*.enc 2>&1 | sed 's/^/    /'
    # Which keys actually landed. A key that lists but will not `get` is a name
    # mangled on the way in; a key missing from the list never reached the
    # store, whatever the import's own count claimed.
    echo "    backend now holds:"
    "$CS_SECRETS_BIN" list 2>&1 | sed 's/^/      /'
    ls -l "$HOME/.cs-secrets" 2>&1 | sed 's/^/      /'
}

# Build a sandbox bin dir holding a fake `security` (never touches the real
# macOS Keychain). Callers PREPEND it to PATH so the fake shadows the real tool
# while the rest of the system stays reachable -- a rebuilt PATH holding only
# copies of the tools cannot always start `#!/usr/bin/env bash`, which surfaces
# as a bare exit 127.
# FAKE_SECURITY_MODE selects the behaviour: "fail" makes `dump-keychain` exit
# nonzero (a real enumeration failure); "readfail" enumerates one credential but
# makes the per-item `find-generic-password` read fail; anything else is a
# healthy empty keychain. Echoes the bin dir.
_make_fake_security() {
    local bindir="$TEST_TMPDIR/kc-bin"
    mkdir -p "$bindir"
    cat > "$bindir/security" <<'FAKE'
#!/usr/bin/env bash
set -u
sub="${1:-}"
sess="${FAKE_SECURITY_SESSION:-test-session}"

# Argument shape used by cs-secrets: -a <account> -s <service> [-w [value]] [-U]
acct=""; service=""; value=""; have_value=0
while [ $# -gt 0 ]; do
    case "$1" in
        -a) acct="${2:-}"; shift 2 ;;
        -s) service="${2:-}"; shift 2 ;;
        -w) if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then value="$2"; have_value=1; shift 2; else shift; fi ;;
        *)  shift ;;
    esac
done

# FAKE_SECURITY_STORE turns the fake into a functional credential store, which
# is what the migration tests need: a real second backend to move secrets into
# and read back. Without it the fixed-response modes below apply, which is what
# the error-path tests need.
store="${FAKE_SECURITY_STORE:-}"
slot() { printf '%s/%s' "$store" "$(printf '%s' "$service" | tr -c 'A-Za-z0-9_.-' '_')"; }

case "$sub" in
    dump-keychain)
        case "${FAKE_SECURITY_MODE:-}" in
            fail)
                echo "security: keychain access failed" >&2
                exit 1
                ;;
            readfail|readok)
                # Enumerate exactly one matching credential so the caller
                # proceeds to read it (readfail then hits a read failure,
                # readok returns a value).
                printf '    "svce"<blob>="cs:%s:K1"\n' "$sess"
                exit 0
                ;;
            *)
                if [ -n "$store" ]; then
                    for f in "$store"/*; do
                        [ -f "$f" ] || continue
                        printf '    "svce"<blob>="%s"\n' "$(head -1 "$f")"
                    done
                fi
                exit 0
                ;;
        esac
        ;;
    find-generic-password)
        # A per-item read. readfail = a real read error (exit 1); readok =
        # success with a value; anything else = errSecItemNotFound (exit 44).
        case "${FAKE_SECURITY_MODE:-}" in
            readfail) exit 1 ;;
            readok)   printf 'v_from_keychain\n'; exit 0 ;;
        esac
        if [ -n "$store" ] && [ -f "$(slot)" ]; then
            tail -n +2 "$(slot)"; exit 0
        fi
        exit 44
        ;;
    add-generic-password)
        # Record that a store was attempted (without recording the value) so a
        # test can prove no overwrite happened when it should have aborted.
        [ -n "${FAKE_SECURITY_ADDLOG:-}" ] && printf 'store\n' >> "$FAKE_SECURITY_ADDLOG"
        # A store that touches a marker then waits lets a test interleave a
        # concurrent mutation while this write is still in flight.
        if [ -n "${FAKE_SECURITY_SLOW_STORE:-}" ]; then
            : > "$FAKE_SECURITY_SLOW_STORE"
            sleep 1
        fi
        case "${FAKE_SECURITY_MODE:-}" in
            storefail) echo "security: could not add credential" >&2; exit 1 ;;
        esac
        if [ -n "$store" ]; then
            mkdir -p "$store"
            { printf '%s\n' "$service"; [ "$have_value" -eq 1 ] && printf '%s' "$value"; } > "$(slot)"
        fi
        exit 0
        ;;
    delete-generic-password)
        if [ -n "$store" ]; then
            [ -f "$(slot)" ] || exit 44
            rm -f "$(slot)"
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKE
    chmod +x "$bindir/security"
    echo "$bindir"
}

# ============================================================================
# Backend detection
# ============================================================================

# Why these live apart from test_cs_secrets.sh.
#
# Every test here proves something about two cs-secrets processes racing, and
# the only way to hold a writer inside its critical section is to slow it down
# on purpose — an openssl shim that sleeps on encrypt, then a sleep long enough
# for the peer to reach the contended read. Those sleeps are the assertion, not
# padding: remove them and the test passes against a store with no locking at
# all.
#
# That made the combined suite the parallel gate's long pole (89s against a few
# seconds for most suites), and a long pole bounds the whole run no matter how
# many lanes run_all.sh opens — one file cannot be split across lanes. Splitting
# them out lets the fast majority rejoin the pack while these run beside it.
#
# Keep the split on that basis: a test belongs here when it is slow BECAUSE it
# synchronises two processes, not merely because it is slow.

# D3: first-use salt creation must be atomic. get_encryption_password derives
# the key from a machine id plus a random salt persisted on first use. The
# original `openssl rand -hex 32 > SALT_FILE` opens the file EMPTY before
# openssl fills it; a second process reading the salt in that window derives its
# key from an empty salt and its store becomes permanently undecryptable. With
# real openssl the window is microseconds and never observed, so a slow-`rand`
# openssl shim widens it deterministically (real openssl still does the actual
# encrypt/decrypt). The fix publishes a fully-written salt in one atomic step,
# so the second writer either sees no salt (and creates its own, losing the
# exclusive-create race) or reads the winner's COMPLETE salt — never an empty one.
test_encrypted_salt_write_is_atomic_under_concurrency() {
    unset CS_SECRETS_PASSWORD   # force the machine-id + salt derivation path
    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/ssl-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
# Delay only the salt generation so SALT_FILE stays mid-write for a beat;
# everything else (encrypt/decrypt) passes straight through to real openssl.
if [ "\$1" = "rand" ]; then sleep 0.4; fi
exec "$real_ssl" "\$@"
SHIM
    chmod +x "$shim/openssl"

    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="salt-A" "$CS_SECRETS_BIN" set k "vA" >/dev/null 2>&1 &
    sleep 0.15   # B reaches the salt read while A's file is still mid-write
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="salt-B" "$CS_SECRETS_BIN" set k "vB" >/dev/null 2>&1 &
    wait

    # Read back with the real (fast) openssl. Both stores must decrypt: neither
    # may have been written under an empty or transient salt.
    local got_a got_b
    got_a=$(CLAUDE_SESSION_NAME="salt-A" "$CS_SECRETS_BIN" get k 2>&1)
    got_b=$(CLAUDE_SESSION_NAME="salt-B" "$CS_SECRETS_BIN" get k 2>&1)
    assert_eq "vA" "$got_a" "salt-A must decrypt after concurrent first-use salt write" || return 1
    assert_eq "vB" "$got_b" "salt-B must decrypt (must not read a half-written salt)" || return 1
}

# codex finding 2: a signal during the critical section must TERMINATE the
# writer. Bash does not auto-exit after an INT/TERM/HUP trap handler returns; a
# handler that only released the lock would let execution continue lock-less
# through the write, so another process could interleave (the lost update this
# mutex prevents). A slow-encrypt openssl shim holds the writer in the critical
# section; we TERM it there and assert it did not go on to report success and
# left no lock behind.
test_encrypted_signal_terminates_writer_mid_critical_section() {
    local sess="sig-term"
    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/sig-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
# Slow only the encrypt so the writer sits in the critical section; decrypt and
# everything else pass through to the real binary.
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && sleep 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$shim/openssl"

    local logf="$TEST_TMPDIR/sig-out.log"
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k v >"$logf" 2>&1 &
    local pid=$!
    sleep 0.6            # let it acquire and enter the slow encrypt
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    local rc=$?

    assert_output_not_contains "$(cat "$logf")" "Stored secret" \
        "a TERM in the critical section must terminate the writer, not complete the store" || return 1
    [ "$rc" -ne 0 ] || { echo "  FAIL: writer must exit non-zero when TERMed mid-store (got $rc)"; return 1; }
    assert_file_not_exists "$HOME/.cs-secrets/.lock.$sess" \
        "the lock must be released after the signal" || return 1
}

# codex round 3 finding: encrypted_purge deleted the store without holding the
# per-session mutex, so it raced concurrent store/delete. A store that read the
# store under lock could rename its update into place AFTER purge deleted the
# file, resurrecting purged secrets (or purge could drop a just-committed
# update). Purge must hold the same lock across the whole operation. A slow-
# encrypt store holds the lock while a purge is launched; serialized, the purge
# runs after the store commits and leaves the store empty, not resurrected.
test_encrypted_purge_serialized_with_concurrent_store() {
    local sess="purge-race"
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    local real_ssl shim
    real_ssl=$(command -v openssl)
    shim="$TEST_TMPDIR/purge-shim"
    mkdir -p "$shim"
    cat > "$shim/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && sleep 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$shim/openssl"

    # Store B holds the lock through a slow encrypt; purge is launched during it.
    PATH="$shim:$PATH" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1 &
    sleep 0.6
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" purge >/dev/null 2>&1
    wait

    # Serialized, purge runs after the store commits -> the store is empty. The
    # bug lets store's rename resurrect the secrets after purge "succeeded".
    local out
    out=$(CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$out" "No secrets" \
        "a purge serialized with a concurrent store must leave the store empty, not resurrected" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/$sess.enc" \
        "purge must remove the store file even against a concurrent store" || return 1
}

# F1: export must serialize against store on the same session, or an older
# export can rename a stale snapshot over a newer sync backup. Export A reads the
# store, then a store adds a secret, then a second export commits the newer set;
# without the mutex A resumes and overwrites the newer backup with its stale
# snapshot, silently losing the secret. A slow-encrypt shim holds export A in its
# encrypt while B is added and re-exported; serialized, the last export wins and
# the backup keeps every secret.
test_export_serialized_against_concurrent_store_no_stale_overwrite() {
    local sess="export-race"
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    # Force the .enc path (no age) and slow ONLY the export's encrypt. The shim
    # uses ABSOLUTE openssl/sleep paths: it runs under the ageless sandbox PATH,
    # which deliberately omits both, so a bare `sleep`/`openssl` would silently
    # no-op the injection (and the race would never open).
    local real_ssl real_sleep ageless slowdir
    real_ssl=$(command -v openssl)
    real_sleep=$(command -v sleep)
    ageless=$(_ageless_path)
    slowdir="$TEST_TMPDIR/export-slow"
    mkdir -p "$slowdir"
    cat > "$slowdir/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0
for a in "\$@"; do [ "\$a" = "-e" ] && is_enc=1; done
[ "\$is_enc" = 1 ] && "$real_sleep" 2
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$slowdir/openssl"

    local mid meta sync
    mid=$(_machine_id)
    meta="$CS_SESSIONS_ROOT/$sess/.cs"
    sync="$meta/secrets.${mid}.enc"

    # Export A reads {A} and slow-encrypts (holds the lock ~2s with the fix).
    PATH="$slowdir:$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1 &
    sleep 0.5
    # Add B and re-export (fast). Serialized behind A's lock with the fix.
    PATH="$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1
    PATH="$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    wait

    # The backup must still contain B: A's stale snapshot must not overwrite it.
    local restored
    restored=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "$sync" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$restored" "vB" \
        "export must not rename a stale snapshot over a newer sync backup (F1)" || return 1
}

# F2: migrate-backend --delete-source must not blanket-purge the source. collect
# reads the source unlocked; a secret stored AFTER that snapshot is not in the
# migrated set, so a blanket purge would delete it without ever migrating it
# (lost). Deleting only the migrated keys leaves the concurrently-added secret
# intact. A slow source-decrypt holds migrate in its collect while B is stored;
# after migrate, B must still be in the encrypted source.
test_migrate_delete_source_preserves_concurrent_store() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store-1"
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    # A store that stalls mid-write lets a concurrent `set` land in the source
    # between the migration reading it and deleting it.
    local marker="$TEST_TMPDIR/target-store-began-1"
    PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" FAKE_SECURITY_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend keychain --from encrypted --delete-source >/dev/null 2>&1 &
    local mpid=$!
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1
    wait "$mpid" || true

    assert_eq "vB" "$("$CS_SECRETS_BIN" get B 2>/dev/null)" \
        "a secret stored during the migration must survive --delete-source" || return 1
}

# F2 (codex): a migrated key concurrently deleted from the source before the
# delete-source cleanup runs must NOT abort the migration. backend_delete calls
# error()/exit on a not-found key, and a bare `|| true` cannot catch a function's
# exit — only a subshell boundary can. The migration copy already fully
# succeeded, so a source key that vanished is fine; migrate must still exit 0.
test_migrate_delete_source_tolerates_concurrently_deleted_key() {
    local bindir; bindir=$(_make_fake_security)
    local kcstore="$TEST_TMPDIR/kc-store-2"
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    local marker="$TEST_TMPDIR/target-store-began-2"
    PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" FAKE_SECURITY_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend keychain --from encrypted --delete-source >/dev/null 2>&1 &
    local mpid=$!
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    # Concurrently delete the migrated key A from the source before delete-source.
    "$CS_SECRETS_BIN" delete A >/dev/null 2>&1
    local rc=0
    wait "$mpid" || rc=$?

    assert_eq "0" "$rc" \
        "migrate --delete-source must not abort when a migrated key was concurrently deleted from the source" || return 1
    # The suite pins CS_SECRETS_BACKEND=encrypted; read the TARGET back explicitly
    # or this asserts against the source the migration just deleted from.
    assert_eq "vA" "$(PATH="$bindir:$PATH" FAKE_SECURITY_STORE="$kcstore" \
        CS_SECRETS_BACKEND=keychain "$CS_SECRETS_BIN" get A 2>/dev/null)" \
        "migrated secret A must have reached the target" || return 1
}

run_test test_encrypted_salt_write_is_atomic_under_concurrency
run_test test_encrypted_signal_terminates_writer_mid_critical_section
run_test test_encrypted_purge_serialized_with_concurrent_store
run_test test_export_serialized_against_concurrent_store_no_stale_overwrite
run_test test_migrate_delete_source_preserves_concurrent_store
run_test test_migrate_delete_source_tolerates_concurrently_deleted_key

report_results
