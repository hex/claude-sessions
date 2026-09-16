#!/usr/bin/env bash
# ABOUTME: Tests for the cs-hint mod under mods/cs-hint (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest shape and the shared handoff rule; runs the bun unit tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-hint"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_and_its_module() {
    assert_eq "cs-hint" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
}

# Both mods decide "armed" by the SessionStart hook's rule, each in its own
# copy of isUnconsumed (KEEP IN SYNC). The two bodies are pinned equal here.
test_mod_handoff_rule_matches_the_rotate_mods() {
    local rule
    rule='/^export function isUnconsumed/,/^}/p'
    local hint rotate
    hint="$(sed -n "$rule" "$MOD/hooks/register.tsx")"
    rotate="$(sed -n "$rule" "$SCRIPT_DIR/../mods/cs-rotate/hooks/register.tsx")"
    [ -n "$hint" ] || { echo "  FAIL: isUnconsumed not found in cs-hint"; return 1; }
    assert_eq "$rotate" "$hint" "isUnconsumed is the same function in both mods" || return 1
}

# The installer deploys the mod under ~/.claude/skills/cs-hint and a cs
# launch exports the flag Claude Code loads it behind. Both halves are pinned
# here by name; the install and launch suites test the behaviour.
test_mod_is_deployed_by_the_installer_and_enabled_at_launch() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-hint/hooks/register.tsx" "install.sh lists the module" || return 1
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
    # A Claude Code from before function hooks validates the manifest and
    # prints no inventory; the pins below are about the inventory.
    if ! printf '%s' "$out" | grep -q 'hooks:'; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 0
    fi
    assert_output_contains "$out" "hooks: session.start, turn.complete, prompt.submit, ui.render{component=PromptHint}" "all four hooks inventoried" || return 1
    assert_output_contains "$out" 'env reads: CS_NO_HINTS' "the off switch is the one variable read" || return 1
    assert_output_not_contains "$out" '$.command.run' "nothing runs a command" || return 1
    assert_output_not_contains "$out" '$.prompt.' "nothing fills or submits the composer" || return 1
    assert_output_contains "$out" '$.clock.every' "the refresh is a ticker" || return 1
    assert_output_not_contains "$out" '$.clock.after' "and nothing else is timed" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_handoff_rule_matches_the_rotate_mods
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
