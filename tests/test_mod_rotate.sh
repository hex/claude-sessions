#!/usr/bin/env bash
# ABOUTME: Tests for the cs-rotate mod under mods/cs-rotate (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest shape and the crit threshold; runs the bun unit tests and plugin validate when present.

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

# The band appears where the status bar turns red. Both defaults are literals in
# two languages, so this test is the only thing holding them together.
test_mod_crit_threshold_matches_the_statusline_default() {
    local mod_crit sl_crit
    mod_crit="$(sed -n 's/^export const CRIT_PERCENT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    sl_crit="$(sed -n 's/.*_num_or "\${CS_STATUSLINE_CTX_CRIT:-}" \([0-9]*\).*/\1/p' "$SCRIPT_DIR/../bin/cs-statusline")"
    [ -n "$mod_crit" ] || { echo "  FAIL: CRIT_PERCENT literal not found in register.tsx"; return 1; }
    [ -n "$sl_crit" ] || { echo "  FAIL: ctx crit default not found in bin/cs-statusline"; return 1; }
    assert_eq "$sl_crit" "$mod_crit" "mod crit == statusline crit default" || return 1
}

# The mod is a plugin under the user's own skills dir; the installer must not
# deploy it while the loader is behind CLAUDE_CODE_ENABLE_FUNCTION_HOOKS.
test_mod_is_not_in_the_install_manifest() {
    assert_file_not_contains "$SCRIPT_DIR/../install.sh" "cs-rotate" "install.sh leaves the mod alone" || return 1
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
    assert_output_contains "$out" '$.prompt.fill' "the press fills the composer" || return 1
    assert_output_not_contains "$out" '$.prompt.submit' "and never submits" || return 1
    assert_output_not_contains "$out" '$.command.run' "and never runs a command itself" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_crit_threshold_matches_the_statusline_default
run_test test_mod_is_not_in_the_install_manifest
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
