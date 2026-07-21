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
        for tool in bash env basename dirname openssl jq hostname cat mkdir chmod ls rm grep sed tr cut head date; do
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
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local enc_file="$HOME/.cs-secrets/test-session.enc"
    local perms
    perms=$(_file_mode "$enc_file")
    assert_eq "600" "$perms" "Encrypted file should be 600" || return 1
}

test_secrets_dir_permissions() {
    "$CS_SECRETS_BIN" set api_key "abc" 2>&1
    local perms
    perms=$(_file_mode "$HOME/.cs-secrets")
    assert_eq "700" "$perms" "Secrets dir should be 700" || return 1
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

report_results
