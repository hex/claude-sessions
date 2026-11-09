#!/usr/bin/env bash
# ABOUTME: Checks the cs-images plugin's shipped manifest, settings, skill and installer payload.
# ABOUTME: Runs its picture and rendering tests with the engine kit and validates its hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-images"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_and_its_module() {
    assert_file_exists "$MOD/.claude-plugin/plugin.json" "cs-images manifest exists" || return 1
    assert_eq "cs-images" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    assert_eq "cs" "$(jq -r .author.name "$MOD/.claude-plugin/plugin.json")" "plugin author" || return 1
    assert_eq '["./register.tsx"]' "$(jq -c .modules "$MOD/hooks/hooks.json")" "one register module" || return 1
    assert_file_exists "$MOD/hooks/register.tsx" "the named module exists" || return 1
}

test_mod_declares_both_config_rows() {
    local manifest="$MOD/.claude-plugin/plugin.json"
    assert_eq '{"type":"boolean","title":"cs: Draw images in replies","default":true}' "$(jq -c '.userConfig.drawImages | {type,title,default}' "$manifest")" "drawImages row" || return 1
    assert_eq '{"type":"number","title":"cs: Image cell height, in widths","default":2}' "$(jq -c '.userConfig.cellHeightRatio | {type,title,default}' "$manifest")" "cellHeightRatio row" || return 1
}

test_mod_is_deployed_by_the_installer() {
    local file
    for file in .claude-plugin/plugin.json hooks/hooks.json hooks/picture.ts hooks/register.tsx skills/show-image/SKILL.md; do
        assert_file_exists "$MOD/$file" "the mod has $file" || return 1
        assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-images/$file" "install.sh lists $file" || return 1
    done
}

test_show_image_skill_names_itself_and_its_triggers() {
    local skill="$MOD/skills/show-image/SKILL.md"
    assert_file_exists "$skill" "show-image skill exists" || return 1
    assert_eq 'name: show-image' "$(sed -n '2p' "$skill")" "frontmatter name" || return 1
    assert_eq 'description: This skill should be used when the user asks to see, show or display an image, screenshot, photo or chart that is a file on disk, or asks for an explanation in pictures, such as "show me in pictures", "explain it visually" or "draw me a picture".' "$(sed -n '3p' "$skill")" "frontmatter trigger" || return 1
    assert_file_contains "$skill" '^!\[short name\](/absolute/path.png)$' "standalone image example" || return 1
    assert_file_contains "$skill" 'png, jpg, jpeg, gif, heic, webp, tif, tiff, bmp, in any letter case' "supported formats" || return 1
    assert_file_contains "$skill" '^- A flow, a structure or states: write a mermaid diagram' "diagrams come first for flows" || return 1
    assert_file_contains "$skill" 'make one image with one provider' "generation stays to one image" || return 1
    assert_file_contains "$skill" 'Before drawing a generated image, open the file the tool reports and compare it with your own explanation and diagram' "a generated image is checked before it is shown" || return 1
    assert_file_contains "$skill" 'Never put secrets, credentials, client data or private file contents' "the image description leaves the machine" || return 1
}

test_mod_tests_pass_under_the_engine_test_kit() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-images-test.$$" status=0
    env -u ANTHROPIC_API_KEY CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" > "$raw" 2>&1 || status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    if grep -q 'unknown command' <<< "$out"; then
        echo "    SKIP: this claude has no plugin test"
        return 77
    fi
    assert_eq "0" "$status" "plugin test exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" " 0 fail" "no kit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the kit ran tests" || return 1
}

test_mod_validates() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-images-validate.$$" status=0
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1 || status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_declares_both_config_rows
run_test test_mod_is_deployed_by_the_installer
run_test test_show_image_skill_names_itself_and_its_triggers
run_test test_mod_tests_pass_under_the_engine_test_kit
run_test test_mod_validates

report_results
