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
    # The two fixed pie steps, 13 and 88, are literals in both languages too.
    local sl_steps mod_steps
    sl_steps="$(sed -n '/^_ctx_pie()/,/^}/p' "$SCRIPT_DIR/../bin/cs-statusline" | grep -o '\-ge [0-9][0-9]*' | grep -o '[0-9]*' | sort -n | tr '\n' ' ')"
    mod_steps="$(sed -n '/^export function pie(/,/^}/p' "$MOD/hooks/register.tsx" | grep -o '>= [0-9][0-9]*' | grep -o '[0-9]*' | sort -n | tr '\n' ' ')"
    assert_eq "13 88 " "$sl_steps" "statusline pie has two fixed steps, 13 and 88" || return 1
    assert_eq "$sl_steps" "$mod_steps" "mod pie steps == statusline pie steps" || return 1
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
    assert_output_contains "$out" "hooks: session.start, ui.render{component=AbovePrompt}" "both hooks inventoried" || return 1
    assert_output_not_contains "$out" '$.prompt.fill' "nothing fills the composer any more" || return 1
    assert_output_contains "$out" 'env reads: CS_ROTATE_BUTTON_CTX, CS_STATUSLINE_CTX_CRIT, CS_STATUSLINE_CTX_WARN' "the threshold and the bar's bands are read from the environment" || return 1
    assert_output_not_contains "$out" '$.prompt.submit' "and never submits" || return 1
    assert_output_contains "$out" '$.command.run (via clearAndContinue, rotate)' "the two presses run their commands, and nothing else runs one" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_default_threshold_matches_the_statusline_warn_default
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
