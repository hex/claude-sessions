#!/usr/bin/env bash
# ABOUTME: Tests for the cs-rotate mod under mods/cs-rotate (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest shape and the default threshold; runs the bun unit tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-rotate"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_and_its_module() {
    assert_eq "cs-rotate" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
}

# By default the band appears where the status bar turns amber and the Stop
# hook gives its one-time headroom notice. Both defaults are literals in two
# languages, so this test is the only thing holding them together.
test_mod_default_threshold_matches_the_statusline_warn_default() {
    local mod_default sl_warn
    mod_default="$(sed -n 's/^export const DEFAULT_PERCENT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    sl_warn="$(sed -n 's/.*_num_or "\${CS_STATUSLINE_CTX_WARN:-}" \([0-9]*\).*/\1/p' "$SCRIPT_DIR/../bin/cs-statusline")"
    [ -n "$mod_default" ] || { echo "  FAIL: DEFAULT_PERCENT literal not found in register.tsx"; return 1; }
    [ -n "$sl_warn" ] || { echo "  FAIL: ctx warn default not found in bin/cs-statusline"; return 1; }
    assert_eq "$sl_warn" "$mod_default" "mod default == statusline warn default" || return 1
}

# The band paints the bar's own capsule fill: a shade of the terminal
# background nudged away from itself. The shift and the luminance pivot are
# literals in two languages (KEEP IN SYNC), so this test is the only thing
# holding _bg_shade and surfaceColor together.
test_mod_surface_shade_matches_the_statusline_shade() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline" mod="$MOD/hooks/register.tsx"
    local sl_shift sl_pivot mod_shift mod_pivot
    sl_shift="$(sed -n '/^_bg_shade()/,/^}/p' "$sl" | sed -n 's/.*shift=\([0-9]*\).*/\1/p' | head -1)"
    sl_pivot="$(sed -n '/^_bg_shade()/,/^}/p' "$sl" | sed -n 's/.*_LUM" -ge \([0-9]*\).*/\1/p' | head -1)"
    mod_shift="$(sed -n 's/^export const SURFACE_SHIFT = \([0-9]*\)$/\1/p' "$mod")"
    mod_pivot="$(sed -n 's/.*722 \* b >= \([0-9]*\)$/\1/p' "$mod")"
    [ -n "$sl_shift" ] && [ -n "$sl_pivot" ] || { echo "  FAIL: _bg_shade's shift or pivot not found in bin/cs-statusline"; return 1; }
    [ -n "$mod_shift" ] && [ -n "$mod_pivot" ] || { echo "  FAIL: SURFACE_SHIFT or the luminance pivot not found in register.tsx"; return 1; }
    assert_eq "$sl_shift" "$mod_shift" "mod surface shift == statusline _bg_shade shift" || return 1
    assert_eq "$sl_pivot" "$mod_pivot" "mod luminance pivot == statusline _bg_shade pivot" || return 1
}

# The installer deploys the mod under ~/.claude/skills/cs-rotate and a cs
# launch exports the flag Claude Code loads it behind, so the mod runs with
# nothing for the person to place. Both halves are pinned here by name; the
# install and launch suites test the behaviour.
test_mod_is_deployed_by_the_installer_and_enabled_at_launch() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-rotate/hooks/register.tsx" "install.sh lists the module" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/75-launch.sh" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS" "launch exports the loader flag" || return 1
}

test_mod_unit_tests_pass_under_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        echo "    SKIP: bun not on PATH"
        return 77
    fi
    local out
    out="$(cd "$MOD" && bun test 2>&1)" || { echo "$out"; return 1; }
    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

# `claude plugin validate` inventories the module's hooks and $ calls with the
# function-hooks flag OFF, so this runs wherever the binary is.
test_mod_validate_inventories_the_hooks_and_calls() {
    if ! command -v claude >/dev/null 2>&1; then
        echo "    SKIP: claude not on PATH"
        return 77
    fi
    local out raw="${TMPDIR:-/tmp}/cs-mod-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    # A Claude Code from before function hooks validates the manifest and
    # prints no inventory; the pins below are about the inventory.
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    assert_output_contains "$out" "hooks: session.start, turn.complete, prompt.submit, command.run{command=clear}, turn.start, ui.render{component=AbovePrompt}, ui.render{component=Pane}" "all seven hooks inventoried" || return 1
    assert_output_not_contains "$out" '$.prompt.fill' "nothing fills the composer any more" || return 1
    assert_output_contains "$out" 'env reads: CS_ROTATE_BUTTON_CTX, CS_ROTATE_FORCE_CTX, CS_STATUSLINE_CTX_WARN, CS_TERM_BG_RGB' "the two thresholds, the bar's warn band and the measured background are read from the environment" || return 1
    assert_output_not_contains "$out" '$.prompt.submit' "and never submits" || return 1
    assert_output_contains "$out" '$.command.run (via askToWrap, clearAndContinue, rotate)' "the keys run their commands, and nothing else runs one" || return 1
    assert_output_contains "$out" '$.clock.after (via forceRotation, startCountdown), $.clock.every (via startCountdown)' "the forced /rotate and the pane's open are one-shot timers and the grace a ticker, nowhere else" || return 1
    assert_output_contains "$out" '$.ui.ask (via askToWrap)' "the wrap key asks through the engine's own dialog" || return 1
    assert_output_contains "$out" '$.ui.close (via openPreview, stopCountdown)' "the handoff pane closes where the count ends, and where it lands after one" || return 1
    assert_output_contains "$out" '$.fs.read (via armedHandoff, forceRotation, ownsRotation, readWrapped)' "the wrap marker is read, never a file's age" || return 1
    assert_output_not_contains "$out" '$.fs.stat' "no rule hangs on a modification time" || return 1
    assert_output_contains "$out" '$.ui.open (via openPreview)' "and opens in one place" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_default_threshold_matches_the_statusline_warn_default
run_test test_mod_surface_shade_matches_the_statusline_shade
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
