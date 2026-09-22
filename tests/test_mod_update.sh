#!/usr/bin/env bash
# ABOUTME: Tests for the cs-update mod under mods/cs-update (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest and its /config field, the cache-name pin against lib/20-update.sh; runs the bun tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-update"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_its_module_and_the_config_field() {
    assert_eq "cs-update" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    assert_eq "boolean" "$(jq -r .userConfig.showReleaseNotes.type "$MOD/.claude-plugin/plugin.json")" "the /config row is a toggle" || return 1
    assert_eq "true" "$(jq -r .userConfig.showReleaseNotes.default "$MOD/.claude-plugin/plugin.json")" "on by default" || return 1
    grep -q "export const OPTION = 'showReleaseNotes'" "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the module reads a field the manifest does not declare"; return 1; }
}

# The cache file is named in two languages: bash writes it, the mod reads it.
test_mod_reads_the_cache_file_bash_writes() {
    grep -q 'update-notes-full-\$UPDATE_AVAILABLE' "$SCRIPT_DIR/../lib/20-update.sh" \
        || { echo "  FAIL: lib/20-update.sh no longer writes update-notes-full-<version>"; return 1; }
    grep -q 'update-notes-full-\${version}' "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the mod no longer reads update-notes-full-<version>"; return 1; }
}

test_mod_is_deployed_by_the_installer_and_checked_by_doctor() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-update/hooks/register.tsx" "install.sh lists the module" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/60-doctor.sh" "_doctor_check_mod cs-update" "doctor has a row for it" || return 1
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

test_mod_validate_inventories_the_hooks_and_calls() {
    if ! command -v claude >/dev/null 2>&1; then
        echo "    SKIP: claude not on PATH"
        return 77
    fi
    local out raw="${TMPDIR:-/tmp}/cs-mod-update-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    assert_output_contains "$out" 'env reads: CS_UPDATE_AVAILABLE, CS_UPDATE_BIN, HOME' "the mod reads the launch verdict and nothing else" || return 1
    assert_output_contains "$out" '$.process.run (via runUpdate)' "the update runs in one place" || return 1
    assert_output_not_contains "$out" '$.http.fetch' "no network in the mod" || return 1
}

run_test test_mod_manifest_names_the_plugin_its_module_and_the_config_field
run_test test_mod_reads_the_cache_file_bash_writes
run_test test_mod_is_deployed_by_the_installer_and_checked_by_doctor
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
