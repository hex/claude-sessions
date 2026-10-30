#!/usr/bin/env bash
# ABOUTME: Tests for the cs-panel mod under mods/cs-panel (a Claude Code function-hooks plugin that lists every cs session in a pane).
# ABOUTME: Pins the manifest, the installer listing and the kit's copy of the golden porcelain; runs the engine test kit, tsc and plugin validate when claude is present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-panel"

setup() { :; }
teardown() { :; }

# What the mod hooks, as `claude plugin validate` prints it: the command, its
# own pane's render and focus ring, its close, and the main loop's turn edges.
HOOKS_LINE='./register.tsx hooks: session.start, command.run{command=cs-panel}, ui.render{component=Pane, requestId=cs-panel}, ui.focus{requestId=cs-panel}, ui.close{id=cs-panel}, turn.start, turn.complete'

test_mod_manifest_names_the_plugin_and_its_module() {
    local manifest="$MOD/.claude-plugin/plugin.json"
    assert_eq "cs-panel" "$(jq -r .name "$manifest")" "plugin name" || return 1
    assert_eq "1" "$(jq '.modules | length' "$MOD/hooks/hooks.json")" "one hooks module" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    # Opened only by /cs-panel: no /config row turns an unasked open on.
    assert_eq "false" "$(jq 'has("userConfig")' "$manifest")" "no userConfig" || return 1
}

test_mod_is_deployed_by_the_installer() {
    local file
    for file in .claude-plugin/plugin.json hooks/hooks.json hooks/register.tsx hooks/draw.tsx hooks/sessions.ts; do
        assert_file_exists "$MOD/$file" "the mod has $file" || return 1
        assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-panel/$file" "install.sh lists $file" || return 1
    done
}

# The kit reads no file, so its tests import the golden answer from
# test/golden.ts; the text between its backticks is the fixture tests/test_list.sh
# holds `cs -list --porcelain` to, byte for byte.
test_mod_kit_golden_is_the_porcelain_fixture() {
    local literal
    literal="$(mktemp "${TMPDIR:-/tmp}/cs-panel-golden.XXXXXX")" || { echo "  FAIL: could not make a temp file"; return 1; }
    awk 'found == 0 && /^export const GOLDEN = `/ { found = 1; sub(/^export const GOLDEN = `/, "") }
         found == 1 { if ($0 == "`") { found = 2; next } print }
         END { if (found != 2) exit 1 }' "$MOD/test/golden.ts" > "$literal"
    local status=$?
    if [ "$status" -ne 0 ]; then rm -f "$literal"; echo "  FAIL: test/golden.ts holds no GOLDEN literal closed by a lone backtick"; return 1; fi
    if ! cmp -s "$literal" "$SCRIPT_DIR/fixtures/list-porcelain.txt"; then
        diff "$SCRIPT_DIR/fixtures/list-porcelain.txt" "$literal" | head -10
        rm -f "$literal"
        echo "  FAIL: test/golden.ts differs from tests/fixtures/list-porcelain.txt"
        return 1
    fi
    rm -f "$literal"
}

# The tests import claude-code/testing, the engine's own kit, so they run under
# `claude plugin test`, not bare bun; the kit runs only with function hooks on.
test_mod_unit_tests_pass_under_the_engine_test_kit() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-panel-test.$$"
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

# The engine writes its types under .claude-plugin/types on first use and
# gitignores them; a checkout without them borrows the cs mod's copy for the
# check and removes it after. The check runs a config of its own, written
# beside the mod and removed after, covering hooks/ and test/.
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
    assert_eq "0" "$status" "tsc exits 0" || { echo "$out"; return 1; }
}

test_mod_validate_inventories_the_hooks_and_calls() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-panel-validate.$$"
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
    assert_output_contains "$out" '$.process.run (via runCs)' "every cs run goes through runCs" || return 1
    assert_output_contains "$out" 'env reads: CLAUDE_SESSION_NAME, CS_BIN' "the launch's two exports, nothing else" || return 1
    assert_output_not_contains "$out" '$.fs.write' "the mod writes no file" || return 1
    assert_output_not_contains "$out" '$.http.fetch' "the mod reaches no network" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_is_deployed_by_the_installer
run_test test_mod_kit_golden_is_the_porcelain_fixture
run_test test_mod_unit_tests_pass_under_the_engine_test_kit
run_test test_mod_typechecks_against_the_engine_contract
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
