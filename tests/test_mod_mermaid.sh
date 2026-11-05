#!/usr/bin/env bash
# ABOUTME: Tests for the cs-mermaid mod under mods/cs-mermaid (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest and its /config field and the installer listing; runs the engine test kit and plugin validate when claude is present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-mermaid"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_its_module_and_the_config_field() {
    assert_eq "cs-mermaid" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    assert_eq "boolean" "$(jq -r .userConfig.drawDiagrams.type "$MOD/.claude-plugin/plugin.json")" "the /config row is a toggle" || return 1
    assert_eq "true" "$(jq -r .userConfig.drawDiagrams.default "$MOD/.claude-plugin/plugin.json")" "on by default" || return 1
    grep -q "export const OPTION = 'drawDiagrams'" "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the module reads a field the manifest does not declare"; return 1; }
}

test_mod_is_deployed_by_the_installer() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-mermaid/hooks/register.tsx" "install.sh lists the module" || return 1
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-mermaid/skills/show-me/SKILL.md" "install.sh lists the show-me skill" || return 1
}

# The skill deploys inside the mod, so the engine lists it as cs-mermaid:show-me
# (measured on 2.1.304); its description is what makes the model pick it unasked.
test_show_me_skill_names_itself_and_its_triggers() {
    local skill="$MOD/skills/show-me/SKILL.md"
    assert_eq "name: show-me" "$(sed -n '2p' "$skill")" "frontmatter name" || return 1
    assert_file_contains "$skill" '^description: This skill should be used when the user asks to "show me"' "third-person description with the trigger phrase" || return 1
    assert_file_contains "$skill" '^graph TD$' "the flowchart example uses the dialect the mod draws" || return 1
    if grep -q 'sequenceDiagram' "$skill"; then
        echo "  FAIL: the skill shows a diagram type the mod cannot draw"; return 1
    fi
}

# The tests import claude-code/testing, the engine's own kit, so they run under
# `claude plugin test`, not bare bun; the kit runs only with function hooks on.
test_mod_unit_tests_pass_under_the_engine_test_kit() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-mermaid-test.$$"
    env -u ANTHROPIC_API_KEY CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    if grep -q 'unknown command' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) has no plugin test"
        return 77
    fi
    assert_eq "0" "$status" "plugin test exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

test_mod_validate_inventories_the_hooks_and_calls() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-mermaid-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    assert_output_contains "$out" 'hooks: ui.render{component=AssistantMessage}' "the mod only draws replies" || return 1
    assert_output_contains "$out" 'calls: $.config.list, $.env.get, $.ui.resolve' "the mod reads the theme row and the terminal cs measured, and draws; no files, writes, processes or network" || return 1
}

run_test test_mod_manifest_names_the_plugin_its_module_and_the_config_field
run_test test_mod_is_deployed_by_the_installer
run_test test_show_me_skill_names_itself_and_its_triggers
run_test test_mod_unit_tests_pass_under_the_engine_test_kit
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
