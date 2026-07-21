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
test_platform_detects_wsl_and_linux_from_uname() {
    # WSL via the WSL_DISTRO_NAME env var
    ( _CS_PLATFORM=""; uname() { echo Linux; }; export WSL_DISTRO_NAME=Ubuntu
      [ "$(cs_platform)" = "wsl" ] ) || return 1
    # WSL via the /proc/version marker: shadow grep to simulate 'microsoft' present
    ( _CS_PLATFORM=""; uname() { echo Linux; }; unset WSL_DISTRO_NAME
      grep() { return 0; }
      [ "$(cs_platform)" = "wsl" ] ) || return 1
    # Plain linux: Linux uname, no WSL env var, marker absent
    ( _CS_PLATFORM=""; uname() { echo Linux; }; unset WSL_DISTRO_NAME
      grep() { return 1; }
      [ "$(cs_platform)" = "linux" ] ) || return 1
}
test_statusline_theme_degrades_off_macos() {
    # Off macOS, _sl_detect_theme resolves a valid theme WITHOUT calling `defaults`
    # (the macOS-only appearance probe is gated on OSTYPE). cs-statusline is sourced
    # as a library via CS_STATUSLINE_LIB=1 so main() does not render.
    ( export CS_STATUSLINE_LIB=1
      source "$SCRIPT_DIR/../bin/cs-statusline"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO SL_THEME
      OSTYPE="linux-gnu"
      _defaults_called=0; defaults() { _defaults_called=1; return 0; }
      _sl_detect_theme
      [ "${SL_THEME:-}" = "light" ] || return 1
      [ "$_defaults_called" = "0" ] || return 1 ) || return 1
}
test_cs_platform_copies_match_lib() {
    local ref; ref=$(sed -n '/^cs_platform() {/,/^}/p' lib/02-platform.sh)
    for f in bin/cs-secrets bin/cs-statusline; do
        local copy; copy=$(sed -n '/^cs_platform() {/,/^}/p' "$f")
        [ "$copy" = "$ref" ] || { echo "drift in $f"; return 1; }
    done
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
run_test test_platform_detects_wsl_and_linux_from_uname
run_test test_statusline_theme_degrades_off_macos
run_test test_cs_platform_copies_match_lib

report_results
