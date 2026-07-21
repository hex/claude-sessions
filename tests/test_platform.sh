#!/usr/bin/env bash
# ABOUTME: Tests for cs_platform(), the single OS/environment detection seam
# ABOUTME: Validates override validation/caching and uname-based fallback detection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-platform.sh"

# ============================================================================
# Tests
# ============================================================================

test_platform_override_is_honored_and_validated() {
    ( export CS_PLATFORM_OVERRIDE=msys; [ "$(cs_platform)" = "msys" ] ) || return 1
    ( export CS_PLATFORM_OVERRIDE=wsl;  [ "$(cs_platform)" = "wsl" ]  ) || return 1
    # invalid override -> nonzero, error to stderr, nothing on stdout
    local out; out=$( CS_PLATFORM_OVERRIDE=bogus cs_platform 2>/dev/null ); local rc=$?
    [ "$rc" -ne 0 ] || return 1
    [ -z "$out" ] || return 1
}
test_platform_detects_macos_and_msys_from_uname() {
    ( _CS_PLATFORM=""; uname() { echo Darwin; }; [ "$(cs_platform)" = "macos" ] ) || return 1
    ( _CS_PLATFORM=""; uname() { echo MINGW64_NT-10.0; }; [ "$(cs_platform)" = "msys" ] ) || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Platform detector tests"
echo "========================"
echo ""

run_test test_platform_override_is_honored_and_validated
run_test test_platform_detects_macos_and_msys_from_uname

report_results
