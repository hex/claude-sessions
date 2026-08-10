#!/usr/bin/env bash
# ABOUTME: Tests for cs_platform(), the OS detection seam behind backend choice
# ABOUTME: Drives it through cs-secrets, its only caller, rather than in isolation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_SECRETS_BIN="$SCRIPT_DIR/../bin/cs-secrets"

# cs-secrets has no source-as-library guard, so the function is reached through
# the CLI. `backend` is the right lever anyway: choosing a secrets backend is
# the only thing the platform value is used for, so these assert the behaviour
# rather than the mechanism that produces it.
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    export CLAUDE_SESSION_NAME="test-session"
    unset CS_SECRETS_BACKEND CS_PLATFORM_OVERRIDE WSL_DISTRO_NAME 2>/dev/null || true
    mkdir -p "$HOME"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    export HOME="$ORIGINAL_HOME"
    unset CLAUDE_SESSION_NAME 2>/dev/null || true
}

ORIGINAL_HOME="$HOME"

# A PATH prefix whose `uname -s` answers whatever the caller wants, so detection
# can be driven without the override that shortcuts it.
stub_uname() {  # kernel-name
    local d="$TEST_TMPDIR/stub"
    mkdir -p "$d"
    printf '#!/bin/sh\nif [ "$1" = "-s" ]; then echo %s; else echo %s; fi\n' "$1" "$1" > "$d/uname"
    chmod +x "$d/uname"
    printf '%s' "$d"
}

# ============================================================================
# Tests
# ============================================================================

# The keychain exists on macOS and nowhere else, so every other platform must
# reach the encrypted file. This is the whole reason the seam still exists.
test_non_macos_platforms_reach_the_encrypted_backend() {
    local p output
    for p in wsl linux; do
        output=$(CS_PLATFORM_OVERRIDE="$p" "$CS_SECRETS_BIN" backend 2>&1) || return 1
        assert_output_contains "$output" "encrypted" "$p should select the encrypted backend" || return 1
        assert_output_not_contains "$output" "keychain" "$p must never select the keychain" || return 1
    done
}

# msys was a platform cs supported and no longer does: it must be refused like
# any other unknown value, not silently accepted as "not macOS".
test_unknown_platform_overrides_are_refused() {
    local p out rc
    for p in msys bogus Darwin MACOS; do
        rc=0
        out=$(CS_PLATFORM_OVERRIDE="$p" "$CS_SECRETS_BIN" backend 2>/dev/null) || rc=$?
        [ "$rc" -ne 0 ] || { echo "override '$p' was accepted (exit 0)"; return 1; }
        case "$out" in
            *keychain*|*encrypted*) echo "override '$p' still reported a backend: $out"; return 1 ;;
        esac
    done
}

test_refused_override_explains_itself_on_stderr() {
    local err
    err=$(CS_PLATFORM_OVERRIDE=bogus "$CS_SECRETS_BIN" backend 2>&1 >/dev/null) || true
    assert_output_contains "$err" "CS_PLATFORM_OVERRIDE" "the refusal should name the variable" || return 1
    assert_output_contains "$err" "bogus" "the refusal should quote the offending value" || return 1
}

# Detection, not just the override, decides the backend. On macOS this is the
# discriminating case: the host really is Darwin and `security` really is
# present, so reaching the encrypted backend proves the uname answer was what
# drove the choice. Off macOS the assertion still holds but proves less.
test_backend_follows_the_detected_kernel() {
    local dir output
    dir="$(stub_uname Linux)"
    unset WSL_DISTRO_NAME
    output=$(PATH="$dir:$PATH" "$CS_SECRETS_BIN" backend 2>&1) || return 1
    assert_output_contains "$output" "encrypted" "a Linux kernel should reach the encrypted backend" || return 1
    assert_output_not_contains "$output" "keychain" "a Linux kernel must not reach the keychain" || return 1
}

# CS_SECRETS_BACKEND is consulted before the platform is ever probed, so it wins
# even when the platform would have chosen otherwise.
test_explicit_backend_wins_over_the_platform() {
    local output
    output=$(CS_SECRETS_BACKEND=encrypted CS_PLATFORM_OVERRIDE=macos "$CS_SECRETS_BIN" backend 2>&1) || return 1
    assert_output_contains "$output" "encrypted" "CS_SECRETS_BACKEND should win over a macos platform" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Platform detector tests"
echo "========================"
echo ""

run_test test_non_macos_platforms_reach_the_encrypted_backend
run_test test_unknown_platform_overrides_are_refused
run_test test_refused_override_explains_itself_on_stderr
run_test test_backend_follows_the_detected_kernel
run_test test_explicit_backend_wins_over_the_platform

report_results
