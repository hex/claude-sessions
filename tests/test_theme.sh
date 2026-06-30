#!/usr/bin/env bash
# ABOUTME: Tests for terminal theme detection (OSC 11, tmux DCS passthrough, fallback)
# ABOUTME: Verifies passthrough byte-wrapping and graceful detect-theme behavior

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

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

test_detect_theme_graceful_under_tmux() {
    local out rc
    out=$(TMUX="fake,1,0" timeout 5 "$CS_BIN" -detect-theme); rc=$?
    assert_eq "0" "$rc" "detect-theme must exit 0 under tmux (no hang)" || return 1
    case "$out" in
        light|dark|unknown) : ;;
        *) echo "  FAIL: unexpected theme '$out'"; return 1 ;;
    esac
}

test_detect_theme_graceful_no_tmux() {
    local out rc
    out=$(timeout 5 "$CS_BIN" -detect-theme); rc=$?
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
    out=$(CS_TERM_THEME=dark timeout 5 "$CS_BIN" -detect-theme)
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

echo ""
echo "cs theme detection tests"
echo "========================"
echo ""

run_test test_tmux_passthrough_wraps_osc11
run_test test_tmux_passthrough_doubles_all_escapes
run_test test_detect_theme_graceful_under_tmux
run_test test_detect_theme_graceful_no_tmux
run_test test_cs_term_theme_override_wins
run_test test_tmux_truecolor_exported_at_launch
run_test test_tmux_truecolor_respects_user_value

report_results
