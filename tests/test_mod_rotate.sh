#!/usr/bin/env bash
# ABOUTME: Tests for the cs mod under mods/cs (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest shape and the default threshold; runs the bun unit tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_and_its_module() {
    assert_eq "cs" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
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

# The forced-rotation threshold is decided twice: by the mod, which acts on it,
# and by the launch notice, which tells the person what it is. A comment kept
# them together; this keeps the number itself together, so a notice can never
# quote a threshold the mod does not use.
test_mod_force_default_matches_the_launch_notice() {
    local mod_default shell_default
    mod_default="$(sed -n 's/^export const FORCE_DEFAULT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    # The fallback the shell resolver prints for an unset value: the line is
    # found by what it does (an empty raw echoing a number), and the number is
    # read off it, so reformatting the line cannot turn a mismatch into a
    # "not found" that passes for a different reason.
    shell_default="$(grep -F 'z "$raw" ] && { echo' "$SCRIPT_DIR/../lib/75-launch.sh" \
        | head -1 | sed -n 's/.*echo \([0-9][0-9]*\).*/\1/p')"
    [ -n "$mod_default" ] || { echo "  FAIL: FORCE_DEFAULT literal not found in register.tsx"; return 1; }
    [ -n "$shell_default" ] || { echo "  FAIL: unset fallback not found in lib/75-launch.sh"; return 1; }
    assert_eq "$mod_default" "$shell_default" "mod FORCE_DEFAULT == the notice's default" || return 1
    # And the two agree on what turns it off, so `off` cannot mean one thing to
    # the mod and another to the notice.
    grep -q "raw.toLowerCase() === 'off'" "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the mod no longer spells the off switch as 'off'"; return 1; }
    grep -q 'off) return 0 ;;' "$SCRIPT_DIR/../lib/75-launch.sh" \
        || { echo "  FAIL: the notice no longer spells the off switch as 'off'"; return 1; }
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

# The countdown's ramp paints the bar's own inks: the session palette, amber
# and crit, each a literal in two languages (KEEP IN SYNC). Read out of _sgr's
# truecolor arm, so a colour changed in the bar and not in the mod fails here.
test_mod_ramp_inks_match_the_statusline() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline" mod="$MOD/hooks/register.tsx"
    local truecolor name sl_rgb mod_rgb
    truecolor="$(sed -n '/^_sgr() {/,/^        256)/p' "$sl")"
    for name in red blue green yellow purple orange pink cyan; do
        sl_rgb="$(sed -n "s/^ *$name) *rgb=\"\([0-9;]*\)\" ;;.*/\1/p" <<< "$truecolor" | tr ';' ',')"
        mod_rgb="$(sed -n "s/.*[{ ]$name: '\([0-9,]*\)'.*/\1/p" "$mod")"
        [ -n "$sl_rgb" ] || { echo "  FAIL: palette colour $name not found in _sgr"; return 1; }
        assert_eq "$sl_rgb" "$mod_rgb" "mod palette $name == statusline $name" || return 1
    done

    local amber crit
    amber="$(sed -n '/^ *amber)$/,/fi ;;/p' <<< "$truecolor")"
    crit="$(sed -n 's/^ *\[ "\$SL_THEME" = "dark" \] && rgb="\([0-9;]*\)" || rgb="\([0-9;]*\)" ;;$/\1 \2/p' <<< "$(sed -n '/^ *crit)$/,/;;/p' <<< "$truecolor")")"
    assert_eq "$(sed -n 's/.*_LUM" -ge \([0-9]*\) \] && rgb="\([0-9;]*\)" || rgb="\([0-9;]*\)".*/\1 \2 \3/p' <<< "$amber" | tr ';' ',')" \
        "$(sed -n 's/.*722 \* rgb\[2\] >= \([0-9]*\) :.*/\1/p' "$mod") $(sed -n "s/^export const AMBER_LIGHT = '\([0-9,]*\)'$/\1/p" "$mod") $(sed -n "s/^export const AMBER_DARK = '\([0-9,]*\)'$/\1/p" "$mod")" \
        "mod amber pivot, light and dark == statusline amber" || return 1
    assert_eq "$(tr ';' ',' <<< "$crit")" \
        "$(sed -n "s/^export const CRIT_DARK = '\([0-9,]*\)'$/\1/p" "$mod") $(sed -n "s/^export const CRIT_LIGHT = '\([0-9,]*\)'$/\1/p" "$mod")" \
        "mod crit dark and light == statusline crit" || return 1
}

# The installer deploys the mod under ~/.claude/skills/cs and a cs
# launch exports the flag Claude Code loads it behind, so the mod runs with
# nothing for the person to place. Both halves are pinned here by name; the
# install and launch suites test the behaviour.
test_mod_is_deployed_by_the_installer_and_enabled_at_launch() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "^    cs/hooks/register.tsx$" "install.sh lists the module" || return 1
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
    assert_output_contains "$out" "hooks: session.start, command.run{command=queue}, turn.complete, prompt.submit, command.run{command=clear}, turn.start, ui.render{component=AbovePrompt}, ui.render{component=Pane}" "all eight hooks inventoried" || return 1
    assert_output_not_contains "$out" '$.prompt.fill' "nothing fills the composer any more" || return 1
    assert_output_contains "$out" 'env reads: CS_BIN, CS_ROTATE_BUTTON_CTX, CS_ROTATE_FORCE_CTX, CS_STATUSLINE_CTX_WARN, CS_TERM_BG_RGB, CS_TERM_THEME' "the cs path, the two thresholds, the bar's warn band, the measured background and the theme are read from the environment" || return 1
    assert_output_contains "$out" '$.process.run, $.session.cwd' "/queue runs cs from its own hook, and nothing else runs a process" || return 1
    assert_output_not_contains "$out" '$.prompt.submit' "and never submits" || return 1
    assert_output_contains "$out" '$.command.run (via askToWrap, clearAndContinue, rotate)' "the keys run their commands, and nothing else runs one" || return 1
    assert_output_contains "$out" '$.clock.after (via forceRotation, startCountdown), $.clock.every (via startCountdown)' "the forced /rotate and the pane's open are one-shot timers and the grace a ticker, nowhere else" || return 1
    assert_output_contains "$out" '$.ui.ask (via askToWrap)' "the wrap key asks through the engine's own dialog" || return 1
    assert_output_contains "$out" '$.ui.close (via openPreview, stopCountdown)' "the handoff pane closes where the count ends, and where it lands after one" || return 1
    assert_output_contains "$out" '$.fs.read (via armedHandoff, forceRotation, readState, readWrapped)' "the wrap marker and the state are read, never a file's age" || return 1
    assert_output_not_contains "$out" '$.fs.stat' "no rule hangs on a modification time" || return 1
    assert_output_contains "$out" '$.ui.open (via openPreview)' "and opens in one place" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_default_threshold_matches_the_statusline_warn_default
run_test test_mod_force_default_matches_the_launch_notice
run_test test_mod_surface_shade_matches_the_statusline_shade
run_test test_mod_ramp_inks_match_the_statusline
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
