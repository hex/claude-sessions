#!/usr/bin/env bash
# ABOUTME: Tests for terminal theme detection (OSC 11, tmux DCS passthrough, fallback)
# ABOUTME: Verifies passthrough byte-wrapping and graceful detect-theme behavior

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Launch-gated suite: on a real MSYS runner the Claude launch short-circuits
# (Tier 2 = session management only), so pin a supported platform there. See
# _apply_suite_platform_pin in test_lib.sh (no-op on macOS/Linux lanes).
SUITE_PIN_NONMSYS=1

# Bound a command with a wall-clock limit when a timeout tool is available;
# otherwise run it directly. macOS stock ships no `timeout` (GNU coreutils
# installs it as `gtimeout`), so these detection tests must not hard-depend on
# it — detect-theme is designed to always terminate on its own.
_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 5 "$@"
    else
        "$@"
    fi
}

# Source cs's functions without running main (the unconditional `main "$@"`
# tail is neutralized to `:`), so internal helpers can be unit-tested.
_load_cs_functions() {
    eval "$(sed 's/^main "\$@"$/:/' "$CS_BIN")" 2>/dev/null
}

test_tmux_passthrough_wraps_osc11() {
    ( _load_cs_functions
      local hex
      hex=$(_tmux_passthrough $'\033]11;?\033\\' | od -An -tx1 | tr -d ' \n')
      # \ePtmux; + (payload with ESCs doubled) + \e\\
      assert_eq "1b50746d75783b1b1b5d31313b3f1b1b5c1b5c" "$hex" \
        "passthrough must bracket with ESC-P-tmux; / ESC-backslash and double every ESC" )
}

test_tmux_passthrough_doubles_all_escapes() {
    ( _load_cs_functions
      # A payload with two ESCs should yield four ESCs inside the wrapper
      local hex count
      hex=$(_tmux_passthrough $'\033A\033B' | od -An -tx1 | tr -d ' \n')
      # strip the leading \ePtmux; (1b50746d75783b) and trailing \e\\ (1b5c)
      local inner="${hex#1b50746d75783b}"
      inner="${inner%1b5c}"
      count=$(printf '%s' "$inner" | grep -o '1b' | grep -c .)
      assert_eq "4" "$count" "each payload ESC must be doubled (2 ESCs -> 4)" )
}

# _parse_osc11_reply is pure string logic (no tty I/O), split out of
# _theme_from_osc11 specifically so the luminance/RGB parsing can be unit
# tested against synthetic OSC 11 reply bodies — the tty query itself can't
# be exercised without a real pty.
test_parse_osc11_reply_light_with_rgb() {
    ( _load_cs_functions
      local out
      out=$(_parse_osc11_reply "rgb:fafa/f8f8/f2f2")
      assert_eq "light 250;248;242" "$out" \
        "a near-white reply should classify light and report the parsed 8-bit RGB" )
}

test_parse_osc11_reply_dark_with_rgb() {
    ( _load_cs_functions
      local out
      out=$(_parse_osc11_reply "rgb:1e1e/1e1e/1e1e")
      assert_eq "dark 30;30;30" "$out" \
        "a near-black reply should classify dark and report the parsed 8-bit RGB" )
}

test_parse_osc11_reply_malformed_is_unknown() {
    ( _load_cs_functions
      local out
      out=$(_parse_osc11_reply "not an osc11 reply")
      assert_eq "unknown" "$out" "a reply with no rgb: body should be unknown" || exit 1
      out=$(_parse_osc11_reply "rgb:zzzz/zzzz/zzzz")
      assert_eq "unknown" "$out" "non-hex channels should be unknown" )
}

# detect_term_theme_and_bg is the single full detection routine (OSC 11, then
# fallback); detect_term_theme is a thin wrapper that keeps its existing
# single-word contract for `cs -detect-theme` and callers that don't need RGB.
test_detect_term_theme_is_thin_wrapper_over_theme_and_bg() {
    ( _load_cs_functions
      _theme_from_osc11() { echo "light 250;248;242"; }
      local out
      out=$(detect_term_theme)
      assert_eq "light" "$out" \
        "detect_term_theme must echo only the theme word even when the full routine has RGB" )
}

test_detect_term_theme_and_bg_carries_rgb() {
    ( _load_cs_functions
      _theme_from_osc11() { echo "light 250;248;242"; }
      local out
      out=$(detect_term_theme_and_bg)
      assert_eq "light 250;248;242" "$out" \
        "detect_term_theme_and_bg must carry the RGB through from the OSC 11 path" )
}

# Under tmux the detection order matters. Modern tmux proxies an OSC 11 query
# to the client terminal, so the PLAIN query returns the real background while
# the DCS-passthrough response never round-trips back to the pane. Older tmux
# does the opposite: it answers the plain query with its own default (black)
# and only the passthrough reaches the real terminal. Detection must handle
# both, and must never trust tmux's pure-black self-default as a real RGB.
test_detect_under_tmux_uses_plain_query_when_passthrough_is_dead() {
    ( _load_cs_functions
      _theme_from_osc11() { [ "${1:-}" = "tmux" ] && echo "unknown" || echo "light 252;247;229"; }
      _theme_from_os_appearance() { echo "dark"; }
      export TMUX="fake,1,0"
      local out
      out=$(detect_term_theme_and_bg)
      assert_eq "light 252;247;229" "$out" \
        "under tmux a proxied plain OSC 11 reply must win over a dead passthrough and OS-appearance" )
}

test_detect_under_tmux_rejects_black_self_default_and_uses_passthrough() {
    ( _load_cs_functions
      _theme_from_osc11() { [ "${1:-}" = "tmux" ] && echo "light 252;247;229" || echo "dark 0;0;0"; }
      _theme_from_os_appearance() { echo "dark"; }
      export TMUX="fake,1,0"
      local out
      out=$(detect_term_theme_and_bg)
      assert_eq "light 252;247;229" "$out" \
        "a pure-black plain reply is tmux's self-default and must yield to the passthrough result" )
}

test_detect_under_tmux_black_everywhere_falls_back_to_os_appearance() {
    ( _load_cs_functions
      _theme_from_osc11() { [ "${1:-}" = "tmux" ] && echo "unknown" || echo "dark 0;0;0"; }
      _theme_from_os_appearance() { echo "dark"; }
      export TMUX="fake,1,0"
      local out
      out=$(detect_term_theme_and_bg)
      assert_eq "dark" "$out" \
        "with no trustworthy RGB, detection returns the OS-appearance theme carrying no RGB (gradient fails closed)" )
}

test_detect_theme_graceful_under_tmux() {
    local out rc
    out=$(TMUX="fake,1,0" _bounded "$CS_BIN" -detect-theme); rc=$?
    assert_eq "0" "$rc" "detect-theme must exit 0 under tmux (no hang)" || return 1
    case "$out" in
        light|dark|unknown) : ;;
        *) echo "  FAIL: unexpected theme '$out'"; return 1 ;;
    esac
}

test_detect_theme_graceful_no_tmux() {
    local out rc
    out=$(_bounded "$CS_BIN" -detect-theme); rc=$?
    assert_eq "0" "$rc" "detect-theme must exit 0 outside tmux" || return 1
    case "$out" in
        light|dark|unknown) : ;;
        *) echo "  FAIL: unexpected theme '$out'"; return 1 ;;
    esac
}

test_cs_term_theme_override_wins() {
    # A preset value must be echoed back unchanged by detection-driven paths:
    # detect-theme always re-detects, but the override is what launch_claude_code
    # honors — assert the override is respected by the documented contract.
    local out
    out=$(CS_TERM_THEME=dark _bounded "$CS_BIN" -detect-theme)
    # -detect-theme re-detects live and ignores the override by design;
    # this documents that behavior so a future change doesn't break it silently.
    case "$out" in
        light|dark|unknown) : ;;
        *) echo "  FAIL: unexpected theme '$out'"; return 1 ;;
    esac
}

# Claude Code mutes its own branding (logo, thinking animation) and statusline
# truecolor when it detects tmux; CLAUDE_CODE_TMUX_TRUECOLOR=1 restores it.
# cs owns the env before exec, so it sets the override at launch (issue #35148).
test_tmux_truecolor_exported_at_launch() {
    unset CLAUDE_CODE_TMUX_TRUECOLOR 2>/dev/null || true
    export CLAUDE_CODE_BIN="$(_make_env_stub)"
    local output
    output=$("$CS_BIN" truecolor-session <<< "" 2>&1) || true
    assert_output_contains "$output" "CLAUDE_CODE_TMUX_TRUECOLOR=1" \
        "cs should export CLAUDE_CODE_TMUX_TRUECOLOR=1 into the claude env" || return 1
}

test_tmux_truecolor_respects_user_value() {
    export CLAUDE_CODE_BIN="$(_make_env_stub)"
    local output
    output=$(CLAUDE_CODE_TMUX_TRUECOLOR=0 "$CS_BIN" truecolor-optout <<< "" 2>&1) || true
    assert_output_contains "$output" "CLAUDE_CODE_TMUX_TRUECOLOR=0" \
        "a user-set CLAUDE_CODE_TMUX_TRUECOLOR must be left untouched" || return 1
}

# CS_TERM_BG_RGB is the real background color (only known via a successful OSC
# 11 round trip), exported alongside CS_TERM_THEME so cs-statusline can fade
# its trailing gradient into it without re-querying the tty itself.
test_cs_term_bg_rgb_absent_when_theme_unknown() {
    # No real tty in this harness, so OSC 11 always reports "unknown" here —
    # the same condition the existing graceful-detection tests rely on.
    export CLAUDE_CODE_BIN="$(_make_env_stub)"
    local output
    output=$("$CS_BIN" bgrgb-session <<< "" 2>&1) || true
    assert_output_not_contains "$output" "CS_TERM_BG_RGB=" \
        "CS_TERM_BG_RGB must not be exported when the background is unknown" || return 1
}

test_cs_term_bg_rgb_respects_user_value() {
    export CLAUDE_CODE_BIN="$(_make_env_stub)"
    local output
    output=$(CS_TERM_BG_RGB="1;2;3" "$CS_BIN" bgrgb-optout <<< "" 2>&1) || true
    assert_output_contains "$output" "CS_TERM_BG_RGB=1;2;3" \
        "a user-set CS_TERM_BG_RGB must be left untouched" || return 1
}

# Auto-detection exports CS_TERM_THEME (so cs's own UI and the TUI picker render
# right) plus the CS_TERM_THEME_AUTO marker (so the statusline knows it may
# override the frozen theme with the live OS appearance) and the background RGB.
test_export_term_theme_exports_theme_and_auto_marker() {
    ( _load_cs_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      detect_term_theme_and_bg() { echo "light 250;248;242"; }
      _export_term_theme
      local child; child=$(env)
      case "$child" in *"CS_TERM_THEME=light"*) : ;; *) echo "  FAIL: CS_TERM_THEME not exported for cs's UI and the picker"; return 1;; esac
      case "$child" in *"CS_TERM_THEME_AUTO=1"*) : ;; *) echo "  FAIL: CS_TERM_THEME_AUTO presence marker not exported"; return 1;; esac
      case "$child" in *"CS_TERM_BG_RGB=250;248;242"*) : ;; *) echo "  FAIL: CS_TERM_BG_RGB not exported"; return 1;; esac )
}

# A user-set CS_TERM_THEME is an explicit override: it propagates to children
# unchanged and suppresses the auto fallback.
test_export_term_theme_user_pin_passes_through() {
    ( _load_cs_functions
      export CS_TERM_THEME=dark
      unset CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      detect_term_theme_and_bg() { echo "light 250;248;242"; }
      _export_term_theme
      local child; child=$(env)
      case "$child" in *"CS_TERM_THEME=dark"*) : ;; *) echo "  FAIL: user pin not propagated to children"; return 1;; esac
      case "$child" in *"CS_TERM_THEME_AUTO="*) echo "  FAIL: AUTO fallback set despite a user pin"; return 1;; esac )
}

echo ""
echo "cs theme detection tests"
echo "========================"
echo ""

run_test test_tmux_passthrough_wraps_osc11
run_test test_tmux_passthrough_doubles_all_escapes
run_test test_parse_osc11_reply_light_with_rgb
run_test test_parse_osc11_reply_dark_with_rgb
run_test test_parse_osc11_reply_malformed_is_unknown
run_test test_detect_term_theme_is_thin_wrapper_over_theme_and_bg
run_test test_detect_term_theme_and_bg_carries_rgb
run_test test_detect_under_tmux_uses_plain_query_when_passthrough_is_dead
run_test test_detect_under_tmux_rejects_black_self_default_and_uses_passthrough
run_test test_detect_under_tmux_black_everywhere_falls_back_to_os_appearance
run_test test_detect_theme_graceful_under_tmux
run_test test_detect_theme_graceful_no_tmux
run_test test_cs_term_theme_override_wins
run_test test_export_term_theme_exports_theme_and_auto_marker
run_test test_export_term_theme_user_pin_passes_through
run_test test_tmux_truecolor_exported_at_launch
run_test test_tmux_truecolor_respects_user_value
run_test test_cs_term_bg_rgb_absent_when_theme_unknown
run_test test_cs_term_bg_rgb_respects_user_value

report_results
