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
    local mod_crit sl_crit
    mod_crit="$(sed -n 's/^export const DEFAULT_CRIT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    sl_crit="$(sed -n 's/.*_num_or "\${CS_STATUSLINE_CTX_CRIT:-}" \([0-9]*\).*/\1/p' "$SCRIPT_DIR/../bin/cs-statusline")"
    [ -n "$mod_crit" ] && [ -n "$sl_crit" ] || { echo "  FAIL: crit default literal not found in one of the two"; return 1; }
    assert_eq "$sl_crit" "$mod_crit" "mod crit == statusline crit default" || return 1
}

# The capsule paints the bar's own truecolor inks. Each triplet is a literal in
# both files (KEEP IN SYNC): the bar's `rgb="r;g;b"` arms of _sgr, the mod's
# `rgb(r,g,b)` strings. brand has one value; amber and crit pivot on the theme.
test_mod_inks_match_the_statusline_inks() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline" mod="$MOD/hooks/register.tsx"
    local brand amber_light amber_dark crit_light crit_dark
    brand="$(sed -n 's/^ *brand) *rgb="\([0-9;]*\)".*/\1/p' "$sl" | head -1)"
    amber_light="$(sed -n '/^ *amber)/,/;;/p' "$sl" | grep -o 'else rgb="[0-9;]*"' | grep -o '[0-9;]*' | tail -1)"
    amber_dark="$(sed -n '/^ *amber)/,/;;/p' "$sl" | grep -o 'dark" ]; then rgb="[0-9;]*"' | sed 's/.*rgb="//; s/"//')"
    crit_dark="$(sed -n '/^ *crit)/,/;;/p' "$sl" | grep -o 'dark" ] && rgb="[0-9;]*"' | sed 's/.*rgb="//; s/"//')"
    crit_light="$(sed -n '/^ *crit)/,/;;/p' "$sl" | grep -o '|| rgb="[0-9;]*"' | grep -o '[0-9;]*')"
    # The amber arm spells each value twice: once on the measured-background
    # branch (luminance), once on the theme branch. Both spellings are pinned.
    local amber_lum_light amber_lum_dark
    amber_lum_light="$(sed -n '/^ *amber)/,/;;/p' "$sl" | grep -o '1530000 ] && rgb="[0-9;]*"' | sed 's/.*rgb="//; s/"//')"
    amber_lum_dark="$(sed -n '/^ *amber)/,/;;/p' "$sl" | grep -o '1530000 ] && rgb="[0-9;]*" || rgb="[0-9;]*"' | sed 's/.*|| rgb="//; s/"//')"
    [ -n "$amber_lum_light" ] && [ -n "$amber_lum_dark" ] \
        || { echo "  FAIL: the amber arm's measured-background branch not found in bin/cs-statusline"; return 1; }
    assert_eq "$amber_light" "$amber_lum_light" "statusline amber light: theme branch == luminance branch" || return 1
    assert_eq "$amber_dark" "$amber_lum_dark" "statusline amber dark: theme branch == luminance branch" || return 1
    [ -n "$brand" ] && [ -n "$amber_light" ] && [ -n "$amber_dark" ] && [ -n "$crit_dark" ] && [ -n "$crit_light" ] \
        || { echo "  FAIL: an ink is missing from bin/cs-statusline (brand=$brand amber=$amber_light/$amber_dark crit=$crit_light/$crit_dark)"; return 1; }
    local mod_coral mod_amber_light mod_amber_dark mod_crit_light mod_crit_dark
    mod_coral="$(sed -n "s/^ *coral: *'rgb(\([0-9,]*\))'.*/\1/p" "$mod" | tr ',' ';')"
    mod_amber_light="$(sed -n "s/^ *amber: *{ *light: *'rgb(\([0-9,]*\))'.*/\1/p" "$mod" | tr ',' ';')"
    mod_amber_dark="$(sed -n "s/^ *amber: *{.*dark: *'rgb(\([0-9,]*\))'.*/\1/p" "$mod" | tr ',' ';')"
    mod_crit_light="$(sed -n "s/^ *crit: *{ *light: *'rgb(\([0-9,]*\))'.*/\1/p" "$mod" | tr ',' ';')"
    mod_crit_dark="$(sed -n "s/^ *crit: *{.*dark: *'rgb(\([0-9,]*\))'.*/\1/p" "$mod" | tr ',' ';')"
    assert_eq "$brand" "$mod_coral" "mod coral == statusline brand" || return 1
    assert_eq "$amber_light" "$mod_amber_light" "mod amber light == statusline amber light" || return 1
    assert_eq "$amber_dark" "$mod_amber_dark" "mod amber dark == statusline amber dark" || return 1
    assert_eq "$crit_light" "$mod_crit_light" "mod crit light == statusline crit light" || return 1
    assert_eq "$crit_dark" "$mod_crit_dark" "mod crit dark == statusline crit dark" || return 1
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
        return 0
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
        return 0
    fi
    local out raw="${TMPDIR:-/tmp}/cs-mod-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    assert_output_contains "$out" "hooks: session.start, turn.complete, prompt.submit, ui.render{component=AbovePrompt}" "all four hooks inventoried" || return 1
    assert_output_not_contains "$out" '$.prompt.fill' "nothing fills the composer any more" || return 1
    assert_output_contains "$out" 'env reads: CS_ROTATE_BUTTON_CTX, CS_ROTATE_FORCE_CTX, CS_STATUSLINE_CTX_CRIT, CS_STATUSLINE_CTX_WARN, CS_TERM_THEME' "the two thresholds, the bar's bands and the theme are read from the environment" || return 1
    assert_output_not_contains "$out" '$.prompt.submit' "and never submits" || return 1
    assert_output_contains "$out" '$.command.run (via clearAndContinue, rotate)' "the two presses run their commands, and nothing else runs one" || return 1
    assert_output_contains "$out" '$.clock.after (via forceRotation), $.clock.every (via startCountdown)' "the forced /rotate is a one-shot timer and the grace a ticker, nowhere else" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_default_threshold_matches_the_statusline_warn_default
run_test test_mod_inks_match_the_statusline_inks
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
