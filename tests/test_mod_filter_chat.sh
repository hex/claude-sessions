#!/usr/bin/env bash
# ABOUTME: Tests for the cs-filter-chat mod under mods/cs-filter-chat (a Claude Code function-hooks plugin that restyles the chat per session).
# ABOUTME: Pins the manifest, holds the installer to the mod's files, lints the hook source, and runs plugin validate, tsc and the engine test kit when claude is present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-filter-chat"

setup() { :; }
teardown() { :; }

# The one shape every session registers (rationale decision 1): its exact
# inventory, as `claude plugin validate` prints it.
HOOKS_LINE='./register.tsx hooks: session.start, command.run{command=filter-chat}, ui.press{plugin=cs, element=cs-filter-chat}, ui.render{component=UserMessage}, ui.render{component=AssistantMessage}, ui.render{component=ToolUse}, ui.render{component=ToolGroup}, ui.render{component=ToolResult}, ui.render{component=ToolProgress}, ui.render{component=TurnDuration}, ui.render{component=CommandOutput}, ui.render{component=SessionMode}'

test_mod_manifest_names_the_plugin_and_its_module_and_declares_no_state() {
    local manifest="$MOD/.claude-plugin/plugin.json"
    assert_eq "cs-filter-chat" "$(jq -r .name "$manifest")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_eq "1" "$(jq '.modules | length' "$MOD/hooks/hooks.json")" "one hooks module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    # The switch is a file the mod reads, never $.state: no state types to declare.
    assert_eq "false" "$(jq 'has("types")' "$manifest")" "no state types" || return 1
}

# No install switch (ruling 1): the on/off is the cs setting CS_FILTER_CHAT,
# never a /config row. The one /config row is the you ink, a pick of the theme
# keys settings.ts YOU_INKS lists (the mod throws on a manifest option it
# lacks), remember by default.
test_mod_manifest_declares_one_config_row_the_you_ink() {
    local manifest="$MOD/.claude-plugin/plugin.json" code
    assert_eq '["youInk"]' "$(jq -c '.userConfig | keys' "$manifest")" "one userConfig field" || return 1
    assert_eq "string remember" "$(jq -r '.userConfig.youInk | "\(.type) \(.default)"' "$manifest")" "a string field, remember by default" || return 1
    code="$(sed -n "s/^export const YOU_INKS = \[\(.*\)\] as const .*/\1/p" "$MOD/hooks/settings.ts" | tr -d "' ")"
    assert_eq "remember,planMode,success,merged,error,text" "$code" "settings.ts YOU_INKS" || return 1
    assert_eq "$code" "$(jq -r '.userConfig.youInk.options | join(",")' "$manifest")" "the manifest's options are YOU_INKS, in order" || return 1
}

# The installer lists every mod file it deploys, each of cs-filter-chat's among them.
test_mod_is_listed_by_the_installer() {
    local file
    for file in .claude-plugin/plugin.json hooks/hooks.json hooks/draw.tsx hooks/register.tsx hooks/session.ts hooks/settings.ts hooks/verdict.ts hooks/words.ts; do
        assert_file_exists "$MOD/$file" "the mod has $file" || return 1
        assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-filter-chat/$file" "install.sh lists $file" || return 1
    done
}

# Nothing filter chat registers awaits across a tool call or a stream, it never
# reads a classic hook or rewrites the prompt, it has no install switch, and
# it runs no command (rationale decision 4, ruling 1, (b) "No $.command.run").
test_mod_source_never_spells_the_refused_events_or_command_run() {
    local event hits
    for event in tool.call turn.step prompt.compose config.set; do
        hits="$(grep -rnF -e "'$event'" -e "\"$event\"" "$MOD/hooks")"
        [ -z "$hits" ] || { echo "  FAIL: the hooks name $event:"; echo "$hits"; return 1; }
    done
    hits="$(grep -rnF -e "'classic." -e '"classic.' -e '$.command.run' "$MOD/hooks")"
    [ -z "$hits" ] || { echo "  FAIL: the hooks name a classic event or \$.command.run:"; echo "$hits"; return 1; }
}

test_mod_validate_inventories_the_one_shape() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-filter-chat-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    local line
    line="$(grep -F './register.tsx hooks:' <<< "$out" | sed 's/^[^.]*//')"
    assert_eq "$HOOKS_LINE" "$line" "the exact hooks inventory" || return 1
}

# The engine writes its types under .claude-plugin/types and a tsconfig.json
# beside the manifest on first use, and gitignores both; a checkout without
# the types borrows the cs mod's copy for the check and removes it after. A
# copy already present is used as it is. The check runs a config of its own,
# written beside the mod and removed after, never the engine's tsconfig.json:
# the engine's includes ../../tests, and this mod's tests live in test/.
test_mod_typechecks_against_the_engine_contract() {
    require_tool npx || return $?
    local target="$MOD/.claude-plugin/types" source="$SCRIPT_DIR/../mods/cs/.claude-plugin/types" copied=0
    if [ ! -d "$target" ]; then
        if [ ! -d "$source" ]; then
            echo "    SKIP: no engine-written types here or in mods/cs (the engine writes them on first use)"
            return 77
        fi
        cp -R "$source" "$target" || { echo "  FAIL: could not copy the engine types"; return 1; }
        copied=1
    fi
    local config out status
    config="$(mktemp "$MOD/tsconfig.check.XXXXXX")" || { [ "$copied" -eq 0 ] || rm -rf "$target"; echo "  FAIL: could not write the check's tsconfig"; return 1; }
    printf '%s\n' '{"extends": "./.claude-plugin/types/tsconfig.json", "include": ["hooks/**/*", "test/**/*"]}' > "$config"
    out="$(cd "$MOD" && npx tsc -p "$(basename "$config")" 2>&1)"
    status=$?
    rm -f "$config"
    [ "$copied" -eq 0 ] || rm -rf "$target"
    assert_eq "0" "$status" "tsc exits 0, painters.typecheck.ts included" || { echo "$out"; return 1; }
}

# The tests import claude-code/testing, the engine's own kit, so they run under
# `claude plugin test`, not bare bun; the kit runs only with function hooks on.
test_mod_unit_tests_pass_under_the_engine_test_kit() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-filter-chat-test.$$"
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

run_test test_mod_manifest_names_the_plugin_and_its_module_and_declares_no_state
run_test test_mod_manifest_declares_one_config_row_the_you_ink
run_test test_mod_is_listed_by_the_installer
run_test test_mod_source_never_spells_the_refused_events_or_command_run
run_test test_mod_validate_inventories_the_one_shape
run_test test_mod_typechecks_against_the_engine_contract
run_test test_mod_unit_tests_pass_under_the_engine_test_kit

report_results
