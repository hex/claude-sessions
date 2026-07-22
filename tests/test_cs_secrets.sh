#!/usr/bin/env bash
# ABOUTME: Tests for cs-secrets encrypted file backend and CLI dispatch
# ABOUTME: Validates store/get/list/delete/purge/export and backend detection

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
    echo "${USER}@$(hostname -s 2>/dev/null || hostname)"
}

# Build a PATH containing every tool cs-secrets needs EXCEPT age, so export-file
# deterministically takes the password (.enc) path even on hosts where age is
# installed. Returns the sandbox bin directory.
_ageless_path() {
    local bindir="$TEST_TMPDIR/ageless-bin"
    if [[ ! -d "$bindir" ]]; then
        mkdir -p "$bindir"
        local tool resolved
        for tool in bash env basename dirname openssl jq hostname cat mkdir chmod ls rm grep sed tr cut head date mktemp mv sleep; do
            resolved=$(command -v "$tool" 2>/dev/null) && ln -sf "$resolved" "$bindir/$tool"
        done
    fi
    echo "$bindir"
}

# Encrypt a JSON payload into a sync file with the shared test password, to
# simulate a file another machine (or a legacy export) committed to git.
_seed_enc_sync_file() {
    local path="$1" json="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$json" | openssl enc -aes-256-cbc -e -pbkdf2 -iter 100000 \
        -out "$path" -pass "pass:$CS_SECRETS_PASSWORD"
}

# Build a sandbox bin dir with a fake `security` (never touches the real macOS
# Keychain) plus the tools cs-secrets needs. FAKE_SECURITY_MODE selects the
# behaviour: "fail" makes `dump-keychain` exit nonzero (a real enumeration
# failure); "readfail" enumerates one credential but makes the per-item
# `find-generic-password` read fail; anything else is a healthy empty keychain.
# Echoes the bin dir.
_make_fake_security() {
    local bindir="$TEST_TMPDIR/kc-bin"
    mkdir -p "$bindir"
    cat > "$bindir/security" <<'FAKE'
#!/usr/bin/env bash
set -u
sub="${1:-}"
sess="${FAKE_SECURITY_SESSION:-test-session}"
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
            *)        exit 44 ;;
        esac
        ;;
    add-generic-password)
        # Record that a store was attempted (without recording the value) so a
        # test can prove no overwrite happened when it should have aborted.
        [ -n "${FAKE_SECURITY_ADDLOG:-}" ] && printf 'store\n' >> "$FAKE_SECURITY_ADDLOG"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKE
    chmod +x "$bindir/security"
    local tool resolved
    for tool in bash env basename dirname openssl jq hostname cat mkdir chmod ls rm grep sed tr cut head date uname; do
        resolved=$(command -v "$tool" 2>/dev/null) && ln -sf "$resolved" "$bindir/$tool"
    done
    echo "$bindir"
}

# --- WCM (Windows Credential Manager) test helpers ---
#
# The real WCM backend shells out to `powershell.exe -File helper.ps1 <verb>`,
# passing session/name via env and the secret as base64 on stdin/stdout. We
# cannot run the P/Invoke .ps1 off Windows, so we drop a functional fake
# `powershell.exe` on PATH that simulates the credential store: it records its
# argv (for the argv-safety assertion), reads CS_WCM_SESSION/CS_WCM_NAME from
# env, and keys a per-credential file off the base64 of session/name.
_wcm_make_fake() {
    local bindir="$TEST_TMPDIR/wcm-bin"
    mkdir -p "$bindir"
    cat > "$bindir/powershell.exe" <<'FAKE'
#!/usr/bin/env bash
# Fake powershell.exe simulating Windows Credential Manager for cs-secrets tests.
set -u
# Record the full argv so a test can prove secrets/metadata never travel there.
printf '%s\n' "$*" >> "$WCM_FAKE_ARGS"

# cs-secrets invokes: -NoProfile -ExecutionPolicy Bypass -File <path> <verb>
verb="${!#}"

# Injected failure seam: simulate a broken helper (PowerShell missing, Add-Type
# compile error, or a CredEnumerate/CredRead that fails with something other
# than ERROR_NOT_FOUND) by exiting nonzero for the named verb (or "all").
if [ -n "${WCM_FAKE_FAIL:-}" ]; then
    case "$WCM_FAKE_FAIL" in
        all|"$verb")
            echo "fake-powershell: simulated $verb failure" >&2
            exit 1
            ;;
    esac
fi

store_dir="$WCM_FAKE_STORE"
sess="${CS_WCM_SESSION:-}"
name="${CS_WCM_NAME:-}"

_hash() { printf '%s' "$1" | openssl base64 -A | tr '/+=' '_.-'; }
sess_dir="$store_dir/$(_hash "$sess")"
cred_file="$sess_dir/$(_hash "$name")"

case "$verb" in
    store)
        b64="$(cat)"
        # Opt-in slow-store seam: touch the marker (store has begun, so the
        # source collect is already done) then pause, so a test can commit a
        # concurrent write in the window between collect and delete-source.
        if [ -n "${WCM_FAKE_SLOW_STORE:-}" ]; then : > "$WCM_FAKE_SLOW_STORE"; sleep 3; fi
        # Simulate the .ps1 blob-size cap (CRED_MAX_CREDENTIAL_BLOB_SIZE).
        bytes=$(printf '%s' "$b64" | openssl base64 -d -A | wc -c | tr -d ' ')
        if [ "$bytes" -gt 2560 ]; then
            exit 2
        fi
        mkdir -p "$sess_dir"
        printf '%s\n%s\n' "$name" "$b64" > "$cred_file"
        exit 0
        ;;
    get)
        # Simulate a corrupt/truncated helper response: exit 0 but emit
        # malformed base64 (openssl base64 -d would return 0 + empty for this).
        if [ -n "${WCM_FAKE_CORRUPT_GET:-}" ]; then
            printf '%s' '!!!not-valid-base64!!!'
            exit 0
        fi
        if [ -f "$cred_file" ]; then
            sed -n '2p' "$cred_file" | tr -d '\n'
            exit 0
        fi
        exit 3
        ;;
    delete)
        if [ -f "$cred_file" ]; then
            rm -f "$cred_file"
            exit 0
        fi
        exit 3
        ;;
    list)
        if [ -d "$sess_dir" ]; then
            for f in "$sess_dir"/*; do
                [ -f "$f" ] || continue
                sed -n '1p' "$f"
            done
        fi
        exit 0
        ;;
    *)
        echo "fake-powershell: unknown verb: $verb" >&2
        exit 64
        ;;
esac
FAKE
    chmod +x "$bindir/powershell.exe"
    echo "$bindir"
}

# Run cs-secrets against the fake WCM backend, passing stdin through.
_wcm_cs() {
    local bindir="$TEST_TMPDIR/wcm-bin"
    PATH="$bindir:$PATH" \
        CS_SECRETS_BACKEND=wcm CS_PLATFORM_OVERRIDE=msys \
        WCM_FAKE_STORE="$TEST_TMPDIR/wcm-store" \
        WCM_FAKE_ARGS="$TEST_TMPDIR/wcm-args" \
        WCM_FAKE_FAIL="${WCM_FAKE_FAIL:-}" \
        WCM_FAKE_CORRUPT_GET="${WCM_FAKE_CORRUPT_GET:-}" \
        "$CS_SECRETS_BIN" "$@"
}

# ============================================================================
# Backend detection
# ============================================================================

test_backend_shows_encrypted() {
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should show encrypted backend" || return 1
}

test_backend_override_via_env() {
    export CS_SECRETS_BACKEND="encrypted"
    local output
    output=$("$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "encrypted" "Should respect CS_SECRETS_BACKEND" || return 1
}

test_backend_wsl_defaults_encrypted_not_keychain() {
    unset CS_SECRETS_BACKEND
    local output
    output=$(CS_PLATFORM_OVERRIDE=wsl "$CS_SECRETS_BIN" backend 2>&1)
    assert_output_contains "$output" "Storage backend: encrypted" "WSL should default to encrypted, not keychain" || return 1
}

test_backend_msys_selects_wcm_when_powershell_present() {
    # With powershell.exe on PATH, MSYS selects the Windows Credential Manager.
    local bindir; bindir=$(mktemp -d)
    printf '#!/bin/sh\nexit 0\n' > "$bindir/powershell.exe"
    chmod +x "$bindir/powershell.exe"
    unset CS_SECRETS_BACKEND
    local output
    output=$(PATH="$bindir:$PATH" CS_PLATFORM_OVERRIDE=msys "$CS_SECRETS_BIN" backend 2>&1)
    rm -rf "$bindir"
    assert_output_contains "$output" "Storage backend: wcm" "MSYS should select wcm when powershell.exe is present" || return 1
}

test_backend_msys_falls_back_to_encrypted_without_powershell() {
    # No powershell.exe on PATH: MSYS falls back to the encrypted-file backend.
    # A sanitized PATH keeps any host-installed powershell.exe from leaking in.
    local bindir; bindir=$(mktemp -d)
    local tool resolved
    for tool in bash env basename dirname openssl jq uname grep sed tr cut; do
        resolved=$(command -v "$tool" 2>/dev/null) && ln -sf "$resolved" "$bindir/$tool"
    done
    unset CS_SECRETS_BACKEND
    local output
    output=$(PATH="$bindir" CS_PLATFORM_OVERRIDE=msys "$CS_SECRETS_BIN" backend 2>&1)
    rm -rf "$bindir"
    assert_output_contains "$output" "Storage backend: encrypted" "MSYS falls back to encrypted without powershell.exe" || return 1
}

# ============================================================================
# Store and retrieve
# ============================================================================

test_store_and_get() {
    "$CS_SECRETS_BIN" set api_key "sk_test_123" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_test_123" "$value" "Should retrieve stored value" || return 1
}

test_store_with_spaces_in_value() {
    "$CS_SECRETS_BIN" set db_url "postgres://user:pass@localhost/my db" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get db_url 2>&1)
    assert_eq "postgres://user:pass@localhost/my db" "$value" "Should handle spaces" || return 1
}

# The value can be supplied on stdin (never argv) so it stays out of ps and the
# bash-logger session.log capture.
test_set_reads_value_from_stdin() {
    printf 'sk_from_stdin' | "$CS_SECRETS_BIN" set api_key >/dev/null 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_from_stdin" "$value" "Should store the value read from stdin" || return 1
}

test_set_reads_value_from_file_redirect() {
    printf 'sk_from_file\n' > "$TEST_TMPDIR/secret.txt"
    "$CS_SECRETS_BIN" set api_key < "$TEST_TMPDIR/secret.txt" >/dev/null 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "sk_from_file" "$value" "Should store the value from a redirected file" || return 1
}

test_store_with_special_chars() {
    "$CS_SECRETS_BIN" set token 'abc!@#$%^&*()_+' 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get token 2>&1)
    assert_eq 'abc!@#$%^&*()_+' "$value" "Should handle special chars" || return 1
}

test_store_overwrites_existing() {
    "$CS_SECRETS_BIN" set api_key "old_value" 2>&1
    "$CS_SECRETS_BIN" set api_key "new_value" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "new_value" "$value" "Should overwrite with new value" || return 1
}

test_get_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" get nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

# ============================================================================
# List
# ============================================================================

test_list_empty() {
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "No secrets" "Should say no secrets" || return 1
}

test_list_shows_stored_secrets() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" set db_pass "xyz" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$output" "api_key" "Should list api_key" || return 1
    assert_output_contains "$output" "db_pass" "Should list db_pass" || return 1
}

test_list_does_not_show_values() {
    "$CS_SECRETS_BIN" set api_key "supersecret" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_not_contains "$output" "supersecret" "List should not show values" || return 1
}

# ============================================================================
# Delete
# ============================================================================

test_delete_removes_secret() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" delete api_key 2>&1
    local output
    if "$CS_SECRETS_BIN" get api_key 2>&1; then
        echo "  FAIL: Secret should be deleted"
        return 1
    fi
}

test_delete_nonexistent_fails() {
    local output
    if output=$("$CS_SECRETS_BIN" delete nonexistent 2>&1); then
        echo "  FAIL: Should fail for nonexistent secret"
        return 1
    fi
    assert_output_contains "$output" "not found" "Error should mention not found" || return 1
}

test_delete_preserves_other_secrets() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" delete key1 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get key2 2>&1)
    assert_eq "val2" "$value" "Other secrets should be preserved" || return 1
}

# ============================================================================
# Purge
# ============================================================================

test_purge_removes_all() {
    "$CS_SECRETS_BIN" set key1 "val1" 2>&1
    "$CS_SECRETS_BIN" set key2 "val2" 2>&1
    "$CS_SECRETS_BIN" set key3 "val3" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "Purged 3" "Should purge 3 secrets" || return 1

    local list_output
    list_output=$("$CS_SECRETS_BIN" list 2>&1)
    assert_output_contains "$list_output" "No secrets" "All secrets should be gone" || return 1
}

test_purge_empty_session() {
    local output
    output=$("$CS_SECRETS_BIN" purge 2>&1)
    assert_output_contains "$output" "No secrets to purge" "Should handle empty purge" || return 1
}

# ============================================================================
# Export
# ============================================================================

test_export_produces_eval_format() {
    "$CS_SECRETS_BIN" set api_key "sk_123" 2>&1
    "$CS_SECRETS_BIN" set db_pass "hunter2" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    assert_output_contains "$output" "export API_KEY=" "Should export API_KEY" || return 1
    assert_output_contains "$output" "export DB_PASS=" "Should export DB_PASS" || return 1
}

test_export_is_eval_safe() {
    "$CS_SECRETS_BIN" set test_key "value with spaces" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" export 2>&1)
    # The export should be eval-safe (properly quoted)
    eval "$output" 2>/dev/null
    assert_eq "value with spaces" "$TEST_KEY" "Eval'd export should set correct value" || return 1
}

# ============================================================================
# Encrypted file internals
# ============================================================================

test_encrypted_file_created() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    assert_exists "$enc_file" "Encrypted file should exist" || return 1
}

test_encrypted_file_not_plaintext() {
    "$CS_SECRETS_BIN" set api_key "visible_secret_value" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    if grep -q "visible_secret_value" "$enc_file" 2>/dev/null; then
        echo "  FAIL: Encrypted file should not contain plaintext secret"
        return 1
    fi
}

test_encrypted_file_permissions() {
    _skip_on_msys && return 0  # Windows FS doesn't enforce Unix 600 mode bits
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    local perms
    perms=$(_file_mode "$enc_file")
    assert_eq "600" "$perms" "Encrypted file should be 600" || return 1
}

test_secrets_dir_permissions() {
    _skip_on_msys && return 0  # Windows FS doesn't enforce Unix 700 mode bits
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local perms
    perms=$(_file_mode "$HOME/.cs-secrets")
    assert_eq "700" "$perms" "Secrets dir should be 700" || return 1
}

# Build a bin dir with a fake `openssl` that simulates a mid-write encryption
# failure: on `enc -e` it truncates the -out target (as real openssl does when
# it opens the output before erroring) and exits nonzero; all other invocations
# (notably `enc -d` decrypt) pass through to the real openssl. Echoes the dir.
_make_openssl_writefail_bin() {
    local bindir="$TEST_TMPDIR/ossl-fail-bin"
    mkdir -p "$bindir"
    local real_openssl; real_openssl=$(command -v openssl)
    cat > "$bindir/openssl" <<OSSL
#!/usr/bin/env bash
enc=0; e=0; out=""; prev=""
for a in "\$@"; do
    case "\$prev" in -out) out="\$a" ;; esac
    case "\$a" in enc) enc=1 ;; -e) e=1 ;; esac
    prev="\$a"
done
if [[ \$enc -eq 1 && \$e -eq 1 ]]; then
    # Reproduce a real partial write: the -out file is opened (truncated) and
    # partially written before openssl errors out.
    [[ -n "\$out" ]] && printf 'PARTIAL' > "\$out"
    echo "openssl: simulated write failure" >&2
    exit 1
fi
exec "$real_openssl" "\$@"
OSSL
    chmod +x "$bindir/openssl"
    echo "$bindir"
}

# A failed encrypted write must NEVER destroy the existing store: the prior
# ciphertext must be byte-for-byte intact and still decryptable to the old value.
test_encrypted_write_failure_preserves_prior_store() {
    "$CS_SECRETS_BIN" set K1 v1 >/dev/null 2>&1
    assert_eq "v1" "$("$CS_SECRETS_BIN" get K1 2>&1)" "precondition: K1=v1 stored" || return 1

    local enc_file="$HOME/.cs-secrets/test-session.enc"
    assert_file_exists "$enc_file" "precondition: store file exists" || return 1
    local before; before=$(openssl dgst -sha256 < "$enc_file")

    local bindir; bindir=$(_make_openssl_writefail_bin)
    local out rc=0
    out=$(PATH="$bindir:$PATH" "$CS_SECRETS_BIN" set K1 v2_should_fail 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: set must return nonzero when the encrypted write fails"
        echo "    output: $out"
        return 1
    fi
    local after; after=$(openssl dgst -sha256 < "$enc_file")
    assert_eq "$before" "$after" "prior ciphertext must be byte-for-byte unchanged after a failed write" || return 1
    assert_eq "v1" "$("$CS_SECRETS_BIN" get K1 2>&1)" "the old secret must still decrypt after a failed write" || return 1

    local tmpcount
    tmpcount=$(find "$HOME/.cs-secrets" -maxdepth 1 -name '.??????' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq 0 "$tmpcount" "no stray temp file must remain after a failed write" || return 1
}

# The success path must persist updates, preserve other secrets, and leave no
# temp file behind.
test_encrypted_write_success_updates_and_leaves_no_temp() {
    "$CS_SECRETS_BIN" set K1 v1 >/dev/null 2>&1
    "$CS_SECRETS_BIN" set K1 v2 >/dev/null 2>&1
    "$CS_SECRETS_BIN" set K2 w1 >/dev/null 2>&1

    assert_eq "v2" "$("$CS_SECRETS_BIN" get K1 2>&1)" "update must persist" || return 1
    assert_eq "w1" "$("$CS_SECRETS_BIN" get K2 2>&1)" "second secret must be stored" || return 1

    # Windows FS doesn't enforce Unix mode bits; the update/no-temp logic below
    # is still valid there, so guard only the mode assertion.
    if ! _is_msys; then
        local perms; perms=$(_file_mode "$HOME/.cs-secrets/test-session.enc")
        assert_eq "600" "$perms" "committed store must keep mode 600" || return 1
    fi

    local tmpcount
    tmpcount=$(find "$HOME/.cs-secrets" -maxdepth 1 -name '.??????' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq 0 "$tmpcount" "success path must leave no temp file" || return 1
}

# ============================================================================
# Session isolation
# ============================================================================

test_sessions_are_isolated() {
    export CLAUDE_SESSION_NAME="session-a"
    "$CS_SECRETS_BIN" set shared_key "value_a" 2>&1

    export CLAUDE_SESSION_NAME="session-b"
    "$CS_SECRETS_BIN" set shared_key "value_b" 2>&1

    export CLAUDE_SESSION_NAME="session-a"
    local value_a
    value_a=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_a" "$value_a" "Session A should have its own value" || return 1

    export CLAUDE_SESSION_NAME="session-b"
    local value_b
    value_b=$("$CS_SECRETS_BIN" get shared_key 2>&1)
    assert_eq "value_b" "$value_b" "Session B should have its own value" || return 1
}

# ============================================================================
# CLI dispatch
# ============================================================================

test_store_alias_works() {
    "$CS_SECRETS_BIN" store api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" get api_key 2>&1)
    assert_eq "abc" "$value" "store alias should work" || return 1
}

test_ls_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local output
    output=$("$CS_SECRETS_BIN" ls 2>&1)
    assert_output_contains "$output" "api_key" "ls alias should work" || return 1
}

test_rm_alias_works() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    "$CS_SECRETS_BIN" rm api_key 2>&1
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: rm alias should delete secret"
        return 1
    fi
}

test_session_flag_overrides_env() {
    export CLAUDE_SESSION_NAME="default-session"
    "$CS_SECRETS_BIN" --session other-session set api_key "abc" 2>&1
    local value
    value=$("$CS_SECRETS_BIN" --session other-session get api_key 2>&1)
    assert_eq "abc" "$value" "--session flag should override env" || return 1

    # Default session should not have it
    if "$CS_SECRETS_BIN" get api_key 2>/dev/null; then
        echo "  FAIL: Default session should not have the secret"
        return 1
    fi
}

test_no_session_errors() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    local output
    if output=$("$CS_SECRETS_BIN" set api_key "abc" </dev/null 2>&1); then
        echo "  FAIL: Should fail without session name"
        return 1
    fi
    assert_output_contains "$output" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
}

test_picker_selects_numbered_session() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    local out
    out=$(printf '2\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || return 1
    assert_output_contains "$out" "No secrets stored for session: beta" || return 1
}

test_picker_prompt_stays_off_stdout() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    local out err
    out=$(printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || return 1
    err=$(cat "$TEST_TMPDIR/picker-err")
    assert_output_contains "$err" "No session specified. Pick one:" || return 1
    assert_output_contains "$err" "1) alpha" || return 1
    assert_output_not_contains "$out" "Pick one" || return 1
    assert_output_contains "$out" "No secrets stored for session: alpha" || return 1
}

test_picker_enter_takes_cwd_default() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    (
        cd "$CS_SESSIONS_ROOT/beta" || exit 1
        local out err
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || exit 1
        err=$(cat "$TEST_TMPDIR/picker-err")
        assert_output_contains "$err" "Session number \[beta\]" || exit 1
        assert_output_contains "$out" "No secrets stored for session: beta" || exit 1
    ) || return 1
}

test_picker_worktree_dir_defaults_to_base() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/alpha@task1/.cs"
    (
        cd "$CS_SESSIONS_ROOT/alpha@task1" || exit 1
        local out err
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>"$TEST_TMPDIR/picker-err") || exit 1
        err=$(cat "$TEST_TMPDIR/picker-err")
        assert_output_not_contains "$err" "alpha@task1" || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_hides_archived_but_cwd_defaults() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs" "$CS_SESSIONS_ROOT/beta/.cs"
    touch "$CS_SESSIONS_ROOT/alpha/.cs/archived"
    local err
    printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list >/dev/null 2>"$TEST_TMPDIR/picker-err" || return 1
    err=$(cat "$TEST_TMPDIR/picker-err")
    assert_output_not_contains "$err" "alpha" || return 1
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_eof_aborts_despite_default() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        if out=$(CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list </dev/null 2>&1); then
            echo "  FAIL: EOF should abort even with a CWD default"
            exit 1
        fi
        assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || exit 1
    ) || return 1
}

test_picker_all_archived_cwd_still_defaults() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    touch "$CS_SESSIONS_ROOT/alpha/.cs/archived"
    (
        cd "$CS_SESSIONS_ROOT/alpha" || exit 1
        local out
        out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>/dev/null) || exit 1
        assert_output_contains "$out" "No secrets stored for session: alpha" || exit 1
    ) || return 1
}

test_picker_rejects_invalid_choice() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    mkdir -p "$CS_SESSIONS_ROOT/alpha/.cs"
    local out
    if out=$(printf '99\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: out-of-range choice should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
    if out=$(printf '\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: empty input with no default should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
}

test_picker_empty_root_errors() {
    unset CLAUDE_SESSION_NAME CS_SECRETS_SESSION
    local out
    if out=$(printf '1\n' | CS_ASSUME_TTY=1 "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: empty sessions root should error"
        return 1
    fi
    assert_output_contains "$out" "No session specified. Set CLAUDE_SESSION_NAME or use --session" || return 1
    assert_output_not_contains "$out" "Pick one" || return 1
}

test_explicit_session_arg_outranks_ambient_namespace() {
    # A launched worktree session carries CS_SECRETS_SESSION=<base> in its
    # environment; `cs <name> -secrets ...` names its target explicitly and
    # must resolve <name>, not the ambient base namespace.
    local output
    output=$(CS_SECRETS_SESSION="ambient-base" "$CS_BIN" "plainsession" -secrets list 2>&1)
    assert_output_contains "$output" "session: plainsession" \
        "explicit -secrets target must outrank ambient CS_SECRETS_SESSION" || return 1
    assert_output_not_contains "$output" "ambient-base" \
        "ambient worktree namespace must not leak into an explicit -secrets call" || return 1
}

test_help_shows_usage() {
    local output
    output=$("$CS_SECRETS_BIN" --help 2>&1) || true
    assert_output_contains "$output" "Usage" "Should show usage" || return 1
}

# ============================================================================
# Per-machine sync files (export-file / import-file)
# ============================================================================

test_export_file_writes_per_machine_enc() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    local mid
    mid=$(_machine_id)
    assert_file_exists "$meta/secrets.${mid}.enc" "export-file must write a per-machine sync file" || return 1
    assert_file_not_exists "$meta/secrets.enc" "export-file must NOT write the shared/unsuffixed name" || return 1
}

test_export_file_skips_rewrite_when_unchanged() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid
    mid=$(_machine_id)
    local f="$meta/secrets.${mid}.enc"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    assert_file_exists "$f" "first export should create the file" || return 1
    cp "$f" "$TEST_TMPDIR/before.enc"
    # Re-export with an unchanged store: bytes must be identical (no random-salt churn).
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    if ! cmp -s "$f" "$TEST_TMPDIR/before.enc"; then
        echo "  FAIL: unchanged re-export rewrote the sync file (byte churn)"
        return 1
    fi
}

test_export_file_rewrites_when_changed() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid
    mid=$(_machine_id)
    local f="$meta/secrets.${mid}.enc"
    "$CS_SECRETS_BIN" set api_key "sk_123" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    cp "$f" "$TEST_TMPDIR/before.enc"
    "$CS_SECRETS_BIN" set api_key "sk_changed" >/dev/null 2>&1
    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file >/dev/null 2>&1
    if cmp -s "$f" "$TEST_TMPDIR/before.enc"; then
        echo "  FAIL: changed store did not rewrite the sync file"
        return 1
    fi
    local dec
    dec=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$f" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$dec" "sk_changed" "re-export should contain the updated value" || return 1
}

test_import_file_merges_all_machines_and_legacy() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-b.enc" '{"from_machine_b":"vb"}'
    _seed_enc_sync_file "$meta/secrets.enc" '{"from_legacy":"vl"}'
    # A locally pre-existing secret must survive a merge import.
    "$CS_SECRETS_BIN" set local_key "vlocal" >/dev/null 2>&1

    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file >/dev/null 2>&1

    assert_eq "vb" "$("$CS_SECRETS_BIN" get from_machine_b 2>&1)" "should import per-machine sync file" || return 1
    assert_eq "vl" "$("$CS_SECRETS_BIN" get from_legacy 2>&1)" "should import legacy unsuffixed sync file" || return 1
    assert_eq "vlocal" "$("$CS_SECRETS_BIN" get local_key 2>&1)" "merge import should preserve local secrets" || return 1
}

test_import_file_skips_undecryptable_files() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"good_key":"vg"}'
    # An .age file we cannot decrypt (no age binary under the sandbox, bogus bytes).
    mkdir -p "$meta"
    printf 'not-a-valid-age-file' > "$meta/secrets.machine-a.age"

    PATH="$(_ageless_path)" "$CS_SECRETS_BIN" import-file >/dev/null 2>&1

    assert_eq "vg" "$("$CS_SECRETS_BIN" get good_key 2>&1)" "should import the decryptable file despite an undecryptable one" || return 1
}

# A transient backend read failure during the merge-import existence probe must
# ABORT the import nonzero and NOT overwrite the (unreadable) existing secret.
# readfail makes the per-key `find-generic-password` probe fail with a
# non-not-found error; the addlog proves no store was attempted.
test_import_file_aborts_on_backend_read_failure_no_overwrite() {
    local bindir; bindir=$(_make_fake_security)
    local addlog="$TEST_TMPDIR/kc-addlog"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"K1":"synced_value"}'

    local out rc=0
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        FAKE_SECURITY_ADDLOG="$addlog" CS_SECRETS_PASSWORD="$CS_SECRETS_PASSWORD" \
        "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: import must abort nonzero when the existence probe read fails"
        echo "    output: $out"
        return 1
    fi
    assert_file_not_exists "$addlog" "must NOT store/overwrite when the existence probe read fails" || return 1
}

# The genuine-not-found path must still store: when the probe reports the secret
# is truly absent (errSecItemNotFound), the merge import proceeds to store it.
test_import_file_stores_when_secret_genuinely_absent() {
    local bindir; bindir=$(_make_fake_security)
    local addlog="$TEST_TMPDIR/kc-addlog"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    _seed_enc_sync_file "$meta/secrets.machine-a.enc" '{"K1":"synced_value"}'

    local out rc=0
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        FAKE_SECURITY_ADDLOG="$addlog" CS_SECRETS_PASSWORD="$CS_SECRETS_PASSWORD" \
        "$CS_SECRETS_BIN" import-file 2>&1) || rc=$?

    assert_eq 0 "$rc" "import must succeed when the secret is genuinely absent" || return 1
    assert_file_exists "$addlog" "a genuinely-absent secret must be stored" || return 1
}

# A jq failure while building the backup JSON must abort the export nonzero and
# write no sync file -- never a partial/empty backup that silently loses secrets.
# readok makes enumeration+read succeed so collection reaches the jq assignment;
# a fake jq fails only on that assignment, leaving other jq calls intact.
test_keychain_export_file_aborts_on_jq_failure() {
    local bindir; bindir=$(_make_fake_security)
    local real_jq; real_jq=$(command -v jq)
    # _make_fake_security symlinks jq; replace the symlink with a real file so
    # the fake applies (and we never write through the symlink to system jq).
    rm -f "$bindir/jq"
    cat > "$bindir/jq" <<JQFAKE
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in *'= \$value'*) echo "jq: simulated failure" >&2; exit 5 ;; esac
done
exec "$real_jq" "\$@"
JQFAKE
    chmod +x "$bindir/jq"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)

    local out rc=0
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readok \
        "$CS_SECRETS_BIN" export-file 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: export-file must abort when json construction (jq) fails"
        echo "    output: $out"
        return 1
    fi
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file on jq construction failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.age" "no age sync file on jq construction failure" || return 1
}

# A grep/sed execution failure in keychain enumeration must fail loud, not read
# as an empty store. A fake sed fails only on the extraction script (svce).
test_keychain_list_loud_on_extraction_failure() {
    local bindir; bindir=$(_make_fake_security)
    local real_sed; real_sed=$(command -v sed)
    # Replace the symlinked sed with a real file so the fake applies.
    rm -f "$bindir/sed"
    cat > "$bindir/sed" <<SEDFAKE
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in *svce*) echo "sed: simulated failure" >&2; exit 2 ;; esac
done
exec "$real_sed" "\$@"
SEDFAKE
    chmod +x "$bindir/sed"

    local out rc=0
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        "$CS_SECRETS_BIN" list 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: list must be nonzero when enumeration extraction (sed) fails"
        echo "    output: $out"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets stored" "an extraction failure must not read as an empty store" || return 1
}

# ============================================================================
# WCM backend (Windows Credential Manager, simulated via fake powershell.exe)
# ============================================================================

test_wcm_roundtrip() {
    _wcm_make_fake >/dev/null
    printf 'hunter2' | _wcm_cs set API_KEY >/dev/null 2>&1 || return 1
    local value
    value=$(_wcm_cs get API_KEY 2>/dev/null) || return 1
    assert_eq "hunter2" "$value" "WCM should round-trip the stored value" || return 1
}

# The security property: the secret and the session:name metadata must NEVER
# reach the powershell.exe argv — they travel via stdin (base64) and env only.
test_wcm_never_puts_secret_or_meta_in_argv() {
    _wcm_make_fake >/dev/null
    printf 'hunter2' | _wcm_cs set API_KEY >/dev/null 2>&1 || return 1
    local args_file="$TEST_TMPDIR/wcm-args"
    assert_file_exists "$args_file" "fake powershell.exe should have recorded its argv" || return 1
    assert_file_contains "$args_file" "Bypass -File" "argv must invoke the helper via -File" || return 1
    assert_file_not_contains "$args_file" "hunter2" "plaintext secret must not appear in argv" || return 1
    # base64('hunter2') == aHVudGVyMg== ; the base64 blob travels on stdin, not argv.
    assert_file_not_contains "$args_file" "aHVudGVyMg" "base64 secret must not appear in argv" || return 1
    assert_file_not_contains "$args_file" "API_KEY" "credential name must not appear in argv" || return 1
    assert_file_not_contains "$args_file" "test-session" "session name must not appear in argv" || return 1
}

test_wcm_missing_key_fails() {
    _wcm_make_fake >/dev/null
    local out
    if out=$(_wcm_cs get MISSING 2>/dev/null); then
        echo "  FAIL: missing key should exit nonzero"
        return 1
    fi
    assert_eq "" "$out" "missing key must produce empty stdout" || return 1
}

test_wcm_unicode_value() {
    _wcm_make_fake >/dev/null
    printf 'héllo-wörld-\xf0\x9f\x94\x91' | _wcm_cs set UNI >/dev/null 2>&1 || return 1
    local value
    value=$(_wcm_cs get UNI 2>/dev/null) || return 1
    assert_eq "$(printf 'héllo-wörld-\xf0\x9f\x94\x91')" "$value" "WCM should round-trip unicode" || return 1
}

test_wcm_multiline_value() {
    _wcm_make_fake >/dev/null
    printf 'line1\nline2\nline3' | _wcm_cs set MULTI >/dev/null 2>&1 || return 1
    local value
    value=$(_wcm_cs get MULTI 2>/dev/null) || return 1
    assert_eq "$(printf 'line1\nline2\nline3')" "$value" "WCM should round-trip multiline" || return 1
}

test_wcm_empty_value_rejected() {
    _wcm_make_fake >/dev/null
    # The CLI rejects an empty value before it reaches the backend.
    if printf '' | _wcm_cs set EMPTY >/dev/null 2>&1; then
        echo "  FAIL: empty value should be rejected"
        return 1
    fi
}

test_wcm_oversize_value_rejected() {
    _wcm_make_fake >/dev/null
    # >2560 bytes: the .ps1 (here, the fake) rejects the blob with exit 2.
    local out
    if out=$(head -c 3000 /dev/zero | tr '\0' 'a' | _wcm_cs set BIG 2>&1); then
        echo "  FAIL: over-size value should be rejected"
        return 1
    fi
    assert_output_contains "$out" "too large" "over-size rejection should explain itself" || return 1
}

test_wcm_list_and_delete() {
    _wcm_make_fake >/dev/null
    printf 'v1' | _wcm_cs set KEY_ONE >/dev/null 2>&1 || return 1
    printf 'v2' | _wcm_cs set KEY_TWO >/dev/null 2>&1 || return 1
    local out
    out=$(_wcm_cs list 2>/dev/null) || return 1
    assert_output_contains "$out" "KEY_ONE" "list should show KEY_ONE" || return 1
    assert_output_contains "$out" "KEY_TWO" "list should show KEY_TWO" || return 1

    _wcm_cs delete KEY_ONE >/dev/null 2>&1 || return 1
    if _wcm_cs get KEY_ONE >/dev/null 2>&1; then
        echo "  FAIL: deleted key should be gone"
        return 1
    fi
    assert_eq "v2" "$(_wcm_cs get KEY_TWO 2>/dev/null)" "delete should preserve the other secret" || return 1
}

test_wcm_delete_nonexistent_fails() {
    _wcm_make_fake >/dev/null
    if _wcm_cs delete NOPE >/dev/null 2>&1; then
        echo "  FAIL: deleting a nonexistent key should fail"
        return 1
    fi
}

# The WCM helper reports distinct exit codes: 2 = oversize blob, 3 = missing
# credential. Those must propagate to the process exit so callers can react.
test_wcm_oversize_returns_exit_2() {
    _wcm_make_fake >/dev/null
    local rc=0
    head -c 3000 /dev/zero | tr '\0' 'a' | _wcm_cs set BIG >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "over-size store must exit exactly 2" || return 1
}

test_wcm_missing_returns_exit_3_empty_stdout() {
    _wcm_make_fake >/dev/null
    local out rc=0
    out=$(_wcm_cs get MISSING 2>/dev/null) || rc=$?
    assert_eq "3" "$rc" "missing get must exit exactly 3" || return 1
    assert_eq "" "$out" "missing get must have empty stdout" || return 1
}

# A real enumeration/helper failure must NOT masquerade as an empty store.
test_wcm_list_enumeration_failure_is_loud() {
    _wcm_make_fake >/dev/null
    local out rc=0
    out=$(WCM_FAKE_FAIL=list _wcm_cs list 2>/dev/null) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  FAIL: list must be nonzero when enumeration fails"; return 1; }
    assert_output_not_contains "$out" "No secrets" "list must not claim an empty store on failure" || return 1
}

test_wcm_purge_enumeration_failure_is_loud() {
    _wcm_make_fake >/dev/null
    local out rc=0
    out=$(WCM_FAKE_FAIL=list _wcm_cs purge 2>/dev/null) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  FAIL: purge must be nonzero when enumeration fails"; return 1; }
    assert_output_not_contains "$out" "Purged" "purge must not claim success on failure" || return 1
    assert_output_not_contains "$out" "No secrets" "purge must not claim an empty store on failure" || return 1
}

# Enumeration succeeds but a per-item delete fails: purge must still be loud.
test_wcm_purge_delete_failure_is_loud() {
    _wcm_make_fake >/dev/null
    printf 'v1' | _wcm_cs set KEY_ONE >/dev/null 2>&1 || return 1
    local out rc=0
    out=$(WCM_FAKE_FAIL=delete _wcm_cs purge 2>/dev/null) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  FAIL: purge must be nonzero when a delete fails"; return 1; }
}

test_wcm_export_enumeration_failure_is_loud() {
    _wcm_make_fake >/dev/null
    local out rc=0
    out=$(WCM_FAKE_FAIL=list _wcm_cs export 2>/dev/null) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  FAIL: export must be nonzero when enumeration fails"; return 1; }
    assert_eq "" "$out" "export must emit nothing on failure" || return 1
}

# The genuinely-empty store must still succeed quietly.
test_wcm_empty_store_lists_cleanly() {
    _wcm_make_fake >/dev/null
    local out
    out=$(_wcm_cs list 2>/dev/null) || return 1
    assert_output_contains "$out" "No secrets stored for session" "empty store should list cleanly" || return 1
}

# An unknown/unimplemented backend must fail loudly, never silently no-op.
test_unknown_backend_guard() {
    local out
    if out=$(CS_SECRETS_BACKEND=bogus "$CS_SECRETS_BIN" get API_KEY 2>&1); then
        echo "  FAIL: unknown backend should exit nonzero"
        return 1
    fi
    assert_output_contains "$out" "Unknown backend" "unknown backend must error loudly" || return 1
}

# The `backend` display command must also reject an unknown backend loudly.
test_unknown_backend_display_is_loud() {
    local out
    if out=$(CS_SECRETS_BACKEND=bogus "$CS_SECRETS_BIN" backend 2>&1); then
        echo "  FAIL: backend display should exit nonzero for an unknown backend"
        return 1
    fi
    assert_output_contains "$out" "Unknown backend" "backend display must error loudly" || return 1
}

# ============================================================================
# Backup/migrate data integrity: a backend failure must FAIL LOUD, never
# produce a partial/empty secret set (which silently loses secrets on restore).
# ============================================================================

# --- encrypted: a decrypt failure must not masquerade as an empty store ---

test_encrypted_get_loud_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt-not-openssl-ciphertext' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" get api_key 2>&1); then
        echo "  FAIL: get on a corrupt store must be nonzero"
        return 1
    fi
    assert_output_not_contains "$out" "not found" "decrypt failure must not read as 'not found'" || return 1
    assert_output_contains "$out" "decrypt" "should explain the decrypt failure" || return 1
}

test_encrypted_list_loud_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: list on a corrupt store must be nonzero"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets" "decrypt failure must not read as an empty store" || return 1
}

test_encrypted_export_file_aborts_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out
    if out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export-file must abort on a decrypt failure"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file may be written on a decrypt failure" || return 1
}

test_encrypted_migrate_aborts_on_decrypt_failure() {
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    printf 'corrupt' > "$HOME/.cs-secrets/test-session.enc"
    local out
    if out=$("$CS_SECRETS_BIN" migrate-backend keychain --from encrypted 2>&1); then
        echo "  FAIL: migrate must abort on a decrypt failure"
        return 1
    fi
    assert_output_not_contains "$out" "Migrated" "must not report a migration on a source failure" || return 1
}

test_encrypted_export_file_empty_store_is_clean() {
    local out
    out=$(PATH="$(_ageless_path)" "$CS_SECRETS_BIN" export-file 2>&1) || return 1
    assert_output_contains "$out" "No secrets to export" "a genuinely-empty store must export cleanly" || return 1
}

# --- keychain: an enumeration failure must abort the backup ---

test_keychain_export_file_aborts_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out
    if out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export-file must abort when keychain enumeration fails"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on enumeration failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file on keychain enumeration failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.age" "no age sync file on keychain enumeration failure" || return 1
}

test_keychain_export_file_empty_store_is_clean() {
    local bindir; bindir=$(_make_fake_security)
    local out
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        "$CS_SECRETS_BIN" export-file 2>&1) || return 1
    assert_output_contains "$out" "No secrets to export" "an empty keychain must export cleanly" || return 1
}

# --- wcm: enumeration or per-item read failure must abort the backup ---

test_wcm_export_file_aborts_on_enumeration_failure() {
    _wcm_make_fake >/dev/null
    local meta="$CS_SESSIONS_ROOT/test-session/.cs"
    local mid; mid=$(_machine_id)
    local out
    if out=$(WCM_FAKE_FAIL=list _wcm_cs export-file 2>&1); then
        echo "  FAIL: export-file must abort when WCM enumeration fails"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on enumeration failure" || return 1
    assert_file_not_exists "$meta/secrets.${mid}.enc" "no sync file on WCM enumeration failure" || return 1
}

test_wcm_export_file_aborts_on_read_failure() {
    _wcm_make_fake >/dev/null
    printf 'v1' | _wcm_cs set KEY_ONE >/dev/null 2>&1 || return 1
    local out
    # Enumeration (list) succeeds but the per-item get fails.
    if out=$(WCM_FAKE_FAIL=get _wcm_cs export-file 2>&1); then
        echo "  FAIL: export-file must abort when a WCM read fails"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets to export" "must not claim empty on a read failure" || return 1
}

test_wcm_export_file_empty_store_is_clean() {
    _wcm_make_fake >/dev/null
    local out
    out=$(_wcm_cs export-file 2>&1) || return 1
    assert_output_contains "$out" "No secrets to export" "an empty WCM store must export cleanly" || return 1
}

# The `export` command (env-var eval output) must also abort, not emit a partial
# set, when a listed credential can't be read.
test_wcm_export_command_aborts_on_read_failure() {
    _wcm_make_fake >/dev/null
    printf 'v1' | _wcm_cs set KEY_ONE >/dev/null 2>&1 || return 1
    local out
    if out=$(WCM_FAKE_FAIL=get _wcm_cs export 2>/dev/null); then
        echo "  FAIL: export command must abort when a WCM read fails"
        return 1
    fi
    assert_eq "" "$out" "export command must emit nothing on a read failure" || return 1
}

# --- strict base64 decode: a corrupt/truncated helper response is not empty ---

test_wcm_get_loud_on_corrupt_base64() {
    _wcm_make_fake >/dev/null
    printf 'hunter2' | _wcm_cs set API_KEY >/dev/null 2>&1 || return 1
    local out rc=0
    out=$(WCM_FAKE_CORRUPT_GET=1 _wcm_cs get API_KEY 2>/dev/null) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  FAIL: get on a corrupt base64 response must be nonzero"; return 1; }
    assert_eq "" "$out" "corrupt base64 must not decode to a (empty) secret" || return 1
}

# --- keychain: list/purge/export must fail loud on a backend command failure ---

test_keychain_list_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" list 2>&1); then
        echo "  FAIL: list must be nonzero when keychain enumeration fails"
        return 1
    fi
    assert_output_not_contains "$out" "No secrets" "enumeration failure must not read as an empty store" || return 1
}

test_keychain_list_empty_is_clean() {
    local bindir; bindir=$(_make_fake_security)
    local out
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        "$CS_SECRETS_BIN" list 2>&1) || return 1
    assert_output_contains "$out" "No secrets stored for session" "an empty keychain must list cleanly" || return 1
}

test_keychain_purge_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" purge 2>&1); then
        echo "  FAIL: purge must be nonzero when keychain enumeration fails"
        return 1
    fi
    assert_output_not_contains "$out" "Purged" "enumeration failure must not report a purge" || return 1
}

test_keychain_export_loud_on_enumeration_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    if out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=fail \
        "$CS_SECRETS_BIN" export 2>&1); then
        echo "  FAIL: export must be nonzero when keychain enumeration fails"
        return 1
    fi
}

test_keychain_export_loud_on_read_failure() {
    local bindir; bindir=$(_make_fake_security)
    local out
    # Enumeration lists one credential but the per-item read fails.
    if out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=readfail \
        FAKE_SECURITY_SESSION=test-session "$CS_SECRETS_BIN" export 2>/dev/null); then
        echo "  FAIL: export must be nonzero when a keychain read fails"
        return 1
    fi
    assert_eq "" "$out" "export must emit nothing on a read failure" || return 1
}

# --- migrate: wcm is a first-class source/target; a partial migration fails ---

test_migrate_encrypted_to_wcm_succeeds() {
    _wcm_make_fake >/dev/null
    "$CS_SECRETS_BIN" set api_key "sk_ok" >/dev/null 2>&1
    local out
    out=$(_wcm_cs migrate-backend wcm --from encrypted 2>&1) || return 1
    assert_output_contains "$out" "Migrated 1 of 1" "encrypted->wcm must migrate all" || return 1
    assert_eq "sk_ok" "$(_wcm_cs get api_key 2>/dev/null)" "migrated secret must be readable from wcm" || return 1
}

test_migrate_wcm_to_encrypted_succeeds() {
    _wcm_make_fake >/dev/null
    printf 'v1' | _wcm_cs set w_key >/dev/null 2>&1 || return 1
    local out
    out=$(_wcm_cs migrate-backend encrypted --from wcm 2>&1) || return 1
    assert_output_contains "$out" "Migrated 1 of 1" "wcm->encrypted must migrate all" || return 1
    assert_eq "v1" "$("$CS_SECRETS_BIN" get w_key 2>/dev/null)" "migrated secret must be readable from encrypted" || return 1
}

test_migrate_partial_write_fails_loud() {
    _wcm_make_fake >/dev/null
    "$CS_SECRETS_BIN" set k1 "v1" >/dev/null 2>&1
    "$CS_SECRETS_BIN" set k2 "v2" >/dev/null 2>&1
    local out
    # Target wcm store fails for every item -> migrated 0 of 2 -> nonzero.
    if out=$(WCM_FAKE_FAIL=store _wcm_cs migrate-backend wcm --from encrypted 2>&1); then
        echo "  FAIL: a partial/failed migration must exit nonzero"
        return 1
    fi
    assert_output_contains "$out" "incomplete" "must report the migration as incomplete" || return 1
}

# ============================================================================
# Concurrency & durability (encrypted backend)
# ============================================================================

# D1: concurrent read-modify-write must not lose updates. Each writer reads the
# store, adds its own key, and writes back. The per-write commit is atomic, but
# the read-modify-write sequence is not: without a mutex, two writers read the
# same base and the second rename clobbers the first writer's key, so keys
# silently vanish. Every key must survive.
test_encrypted_concurrent_stores_no_lost_update() {
    local sess="d1-concurrent"
    local n=15 i
    for i in $(seq 1 "$n"); do
        CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set "key$i" "val$i" >/dev/null 2>&1 &
    done
    wait
    local out
    out=$(CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" list 2>&1)
    for i in $(seq 1 "$n"); do
        assert_output_contains "$out" "key$i" \
            "key$i must survive $n concurrent stores (lost-update race)" || return 1
    done
}

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

# D2: a failed sync export must not destroy the previous good backup. The old
# code encrypted straight to `-out "$enc_output"`, which opens the live sync
# file with O_TRUNC before openssl finishes; a failed/interrupted encrypt then
# leaves the prior backup truncated (pipefail surfaces the failure, but too
# late). A fake openssl truncates the output then fails only on encrypt (-e);
# decrypt (-d), used to read the store and compare the existing file, passes
# through to real openssl. The fix encrypts into a temp and renames on success,
# so a failed export leaves the existing sync file untouched.
test_export_file_atomic_preserves_prior_on_encrypt_failure() {
    local sess="d2-atomic"
    CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k1 v1 >/dev/null 2>&1

    # Seed an existing, valid per-machine sync file (a prior successful export).
    local mid meta sync
    mid=$(_machine_id)
    meta="$CS_SESSIONS_ROOT/$sess/.cs"
    sync="$meta/secrets.${mid}.enc"
    _seed_enc_sync_file "$sync" '{"prior":"good"}'

    # Fake openssl: truncate the -out target then fail on encrypt; pass decrypt
    # and everything else through to the real binary.
    local real_ssl ageless fakedir
    real_ssl=$(command -v openssl)
    ageless=$(_ageless_path)
    fakedir="$TEST_TMPDIR/d2-fakebin"
    mkdir -p "$fakedir"
    cat > "$fakedir/openssl" <<SHIM
#!/usr/bin/env bash
orig=("\$@"); is_enc=0; out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -e) is_enc=1 ;;
        -out) shift; out="\$1" ;;
    esac
    shift
done
if [ "\$is_enc" = 1 ]; then
    : > "\$out"                              # simulate openssl's O_TRUNC open...
    echo "fake openssl: forced encrypt failure" >&2
    exit 1                                   # ...then fail before writing bytes
fi
exec "$real_ssl" "\${orig[@]}"
SHIM
    chmod +x "$fakedir/openssl"

    local out
    if out=$(PATH="$fakedir:$ageless" CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" export-file 2>&1); then
        echo "  FAIL: export must fail loud when encryption fails"
        echo "    output: $out"
        return 1
    fi

    # The prior sync file must still decrypt to its original content.
    local restored
    restored=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "$sync" -pass "pass:$CS_SECRETS_PASSWORD" 2>/dev/null)
    assert_output_contains "$restored" '"prior":"good"' \
        "prior sync file must survive a failed export (non-atomic truncate)" || return 1
}

# codex finding 1: a lock left by a dead process must NOT be silently reaped.
# The earlier reap read the holder PID, classified it dead, then renamed the
# lock away without re-checking that the file still held that PID — a two-waiter
# TOCTOU that could hand two writers the lock at once (the lost update this mutex
# prevents). Acquisition now fails loud after the timeout instead, naming the
# lock to remove. Deterministic: seed the lock with a definitely-dead PID.
test_encrypted_stale_lock_fails_loud_not_reaped() {
    local sess="stale-lock"
    mkdir -p "$HOME/.cs-secrets"
    chmod 700 "$HOME/.cs-secrets"
    # A definitely-dead PID: spawn a child, reap it, reuse its now-free PID.
    local dead
    sh -c 'exit 0' & dead=$!
    wait "$dead" 2>/dev/null
    echo "$dead" > "$HOME/.cs-secrets/.lock.$sess"

    local out rc=0
    out=$(CS_SECRETS_LOCK_TIMEOUT=1 CLAUDE_SESSION_NAME="$sess" "$CS_SECRETS_BIN" set k v 2>&1) || rc=$?
    assert_eq "1" "$rc" "store must fail when the lock is held" || return 1
    assert_output_contains "$out" "timed out" "must fail loud, not silently reap the stale lock" || return 1
    assert_output_contains "$out" "remove:" "must name the lock file to remove" || return 1
    assert_file_not_exists "$HOME/.cs-secrets/$sess.enc" \
        "no store may be written when the lock was never acquired" || return 1
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

# codex F1 review: the export mutex must not couple non-encrypted backends to the
# encrypted backend's ~/.cs-secrets. A keychain/WCM store is atomic per credential
# and never needed the lock; requiring a writable ~/.cs-secrets to export from
# those backends is a regression. Block the path with a plain file where the dir
# would go and confirm a keychain export still works (only the encrypted backend
# takes the lock).
test_keychain_export_does_not_require_cs_secrets_dir() {
    local bindir; bindir=$(_make_fake_security)
    rm -rf "$HOME/.cs-secrets"
    : > "$HOME/.cs-secrets"   # a file, so mkdir -p "$HOME/.cs-secrets" cannot succeed
    local out
    out=$(PATH="$bindir" CS_SECRETS_BACKEND=keychain FAKE_SECURITY_MODE=empty \
        CS_SECRETS_LOCK_TIMEOUT=1 "$CS_SECRETS_BIN" export-file 2>&1) || {
        echo "  FAIL: keychain export must not require a writable ~/.cs-secrets"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "No secrets to export" \
        "keychain export must work without the encrypted backend's ~/.cs-secrets" || return 1
}

# F2: migrate-backend --delete-source must not blanket-purge the source. collect
# reads the source unlocked; a secret stored AFTER that snapshot is not in the
# migrated set, so a blanket purge would delete it without ever migrating it
# (lost). Deleting only the migrated keys leaves the concurrently-added secret
# intact. A slow source-decrypt holds migrate in its collect while B is stored;
# after migrate, B must still be in the encrypted source.
test_migrate_delete_source_preserves_concurrent_store() {
    _wcm_make_fake >/dev/null
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1   # encrypted source starts with A

    # The target (wcm) store runs AFTER the source collect and BEFORE
    # delete-source. WCM_FAKE_SLOW_STORE makes that store touch a marker then
    # pause, giving a deterministic window to commit B into the source between
    # collect and delete-source (a bare sleep races migrate's ~0.8s startup).
    local marker="$TEST_TMPDIR/target-store-began"
    local wcmbin="$TEST_TMPDIR/wcm-bin"
    PATH="$wcmbin:$PATH" CS_SECRETS_BACKEND=wcm CS_PLATFORM_OVERRIDE=msys \
        WCM_FAKE_STORE="$TEST_TMPDIR/wcm-store" WCM_FAKE_ARGS="$TEST_TMPDIR/wcm-args" \
        WCM_FAKE_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend wcm --from encrypted --delete-source >/dev/null 2>&1 &
    # Collect (of {A}) is done once the target store begins; store B into the
    # source now, so B is genuinely absent from the migrated set.
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    "$CS_SECRETS_BIN" set B vB >/dev/null 2>&1
    wait

    assert_eq "vB" "$("$CS_SECRETS_BIN" get B 2>/dev/null)" \
        "migrate --delete-source must preserve a concurrently-stored secret (delete migrated keys, not purge)" || return 1
}

# F2 (codex): a migrated key concurrently deleted from the source before the
# delete-source cleanup runs must NOT abort the migration. backend_delete calls
# error()/exit on a not-found key, and a bare `|| true` cannot catch a function's
# exit — only a subshell boundary can. The migration copy already fully
# succeeded, so a source key that vanished is fine; migrate must still exit 0.
test_migrate_delete_source_tolerates_concurrently_deleted_key() {
    _wcm_make_fake >/dev/null
    "$CS_SECRETS_BIN" set A vA >/dev/null 2>&1

    local marker="$TEST_TMPDIR/target-store-began-2"
    local wcmbin="$TEST_TMPDIR/wcm-bin"
    PATH="$wcmbin:$PATH" CS_SECRETS_BACKEND=wcm CS_PLATFORM_OVERRIDE=msys \
        WCM_FAKE_STORE="$TEST_TMPDIR/wcm-store" WCM_FAKE_ARGS="$TEST_TMPDIR/wcm-args" \
        WCM_FAKE_SLOW_STORE="$marker" \
        "$CS_SECRETS_BIN" migrate-backend wcm --from encrypted --delete-source >/dev/null 2>&1 &
    local mpid=$!
    local waited=0
    until [ -f "$marker" ]; do sleep 0.05; waited=$((waited + 1)); [ "$waited" -gt 200 ] && break; done
    # Concurrently delete the migrated key A from the source before delete-source.
    "$CS_SECRETS_BIN" delete A >/dev/null 2>&1
    local rc=0
    wait "$mpid" || rc=$?

    assert_eq "0" "$rc" \
        "migrate --delete-source must not abort when a migrated key was concurrently deleted from the source" || return 1
    assert_eq "vA" "$(PATH="$wcmbin:$PATH" CS_SECRETS_BACKEND=wcm CS_PLATFORM_OVERRIDE=msys \
        WCM_FAKE_STORE="$TEST_TMPDIR/wcm-store" WCM_FAKE_ARGS="$TEST_TMPDIR/wcm-args" \
        "$CS_SECRETS_BIN" get A 2>/dev/null)" "migrated secret A must have reached the target" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs-secrets tests"
echo "================"
echo ""

# Backend
run_test test_backend_shows_encrypted
run_test test_backend_override_via_env
run_test test_backend_wsl_defaults_encrypted_not_keychain
run_test test_backend_msys_selects_wcm_when_powershell_present
run_test test_backend_msys_falls_back_to_encrypted_without_powershell

# Store and retrieve
run_test test_store_and_get
run_test test_set_reads_value_from_stdin
run_test test_set_reads_value_from_file_redirect
run_test test_store_with_spaces_in_value
run_test test_store_with_special_chars
run_test test_store_overwrites_existing
run_test test_get_nonexistent_fails

# List
run_test test_list_empty
run_test test_list_shows_stored_secrets
run_test test_list_does_not_show_values

# Delete
run_test test_delete_removes_secret
run_test test_delete_nonexistent_fails
run_test test_delete_preserves_other_secrets

# Purge
run_test test_purge_removes_all
run_test test_purge_empty_session

# Export
run_test test_export_produces_eval_format
run_test test_export_is_eval_safe

# Encrypted file internals
run_test test_encrypted_file_created
run_test test_encrypted_file_not_plaintext
run_test test_encrypted_file_permissions
run_test test_secrets_dir_permissions
run_test test_encrypted_write_failure_preserves_prior_store
run_test test_encrypted_write_success_updates_and_leaves_no_temp

# Session isolation
run_test test_sessions_are_isolated

# CLI dispatch
run_test test_store_alias_works
run_test test_ls_alias_works
run_test test_rm_alias_works
run_test test_session_flag_overrides_env
run_test test_no_session_errors
run_test test_picker_selects_numbered_session
run_test test_picker_prompt_stays_off_stdout
run_test test_picker_enter_takes_cwd_default
run_test test_picker_worktree_dir_defaults_to_base
run_test test_picker_hides_archived_but_cwd_defaults
run_test test_picker_eof_aborts_despite_default
run_test test_picker_all_archived_cwd_still_defaults
run_test test_picker_rejects_invalid_choice
run_test test_picker_empty_root_errors
run_test test_explicit_session_arg_outranks_ambient_namespace
run_test test_help_shows_usage

# Per-machine sync files
run_test test_export_file_writes_per_machine_enc
run_test test_export_file_skips_rewrite_when_unchanged
run_test test_export_file_rewrites_when_changed
run_test test_import_file_merges_all_machines_and_legacy
run_test test_import_file_skips_undecryptable_files
run_test test_import_file_aborts_on_backend_read_failure_no_overwrite
run_test test_import_file_stores_when_secret_genuinely_absent
run_test test_keychain_export_file_aborts_on_jq_failure
run_test test_keychain_list_loud_on_extraction_failure

# WCM backend (simulated)
run_test test_wcm_roundtrip
run_test test_wcm_never_puts_secret_or_meta_in_argv
run_test test_wcm_missing_key_fails
run_test test_wcm_unicode_value
run_test test_wcm_multiline_value
run_test test_wcm_empty_value_rejected
run_test test_wcm_oversize_value_rejected
run_test test_wcm_list_and_delete
run_test test_wcm_delete_nonexistent_fails
run_test test_wcm_oversize_returns_exit_2
run_test test_wcm_missing_returns_exit_3_empty_stdout
run_test test_wcm_list_enumeration_failure_is_loud
run_test test_wcm_purge_enumeration_failure_is_loud
run_test test_wcm_purge_delete_failure_is_loud
run_test test_wcm_export_enumeration_failure_is_loud
run_test test_wcm_empty_store_lists_cleanly
run_test test_unknown_backend_guard
run_test test_unknown_backend_display_is_loud

# Backup/migrate data integrity (fail loud, never partial/empty)
run_test test_encrypted_get_loud_on_decrypt_failure
run_test test_encrypted_list_loud_on_decrypt_failure
run_test test_encrypted_export_file_aborts_on_decrypt_failure
run_test test_encrypted_migrate_aborts_on_decrypt_failure
run_test test_encrypted_export_file_empty_store_is_clean
run_test test_keychain_export_file_aborts_on_enumeration_failure
run_test test_keychain_export_file_empty_store_is_clean
run_test test_wcm_export_file_aborts_on_enumeration_failure
run_test test_wcm_export_file_aborts_on_read_failure
run_test test_wcm_export_file_empty_store_is_clean
run_test test_wcm_export_command_aborts_on_read_failure

# Comprehensive sweep: strict base64, keychain list/purge/export, wcm migrate
run_test test_wcm_get_loud_on_corrupt_base64
run_test test_keychain_list_loud_on_enumeration_failure
run_test test_keychain_list_empty_is_clean
run_test test_keychain_purge_loud_on_enumeration_failure
run_test test_keychain_export_loud_on_enumeration_failure
run_test test_keychain_export_loud_on_read_failure
run_test test_migrate_encrypted_to_wcm_succeeds
run_test test_migrate_wcm_to_encrypted_succeeds
run_test test_migrate_partial_write_fails_loud

# Concurrency & durability
run_test test_encrypted_concurrent_stores_no_lost_update
run_test test_encrypted_salt_write_is_atomic_under_concurrency
run_test test_export_file_atomic_preserves_prior_on_encrypt_failure
run_test test_encrypted_stale_lock_fails_loud_not_reaped
run_test test_encrypted_signal_terminates_writer_mid_critical_section
run_test test_encrypted_purge_serialized_with_concurrent_store
run_test test_export_serialized_against_concurrent_store_no_stale_overwrite
run_test test_keychain_export_does_not_require_cs_secrets_dir
run_test test_migrate_delete_source_preserves_concurrent_store
run_test test_migrate_delete_source_tolerates_concurrently_deleted_key

report_results
