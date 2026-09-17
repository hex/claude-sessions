#!/usr/bin/env bash
# ABOUTME: Tests for the mod band layout engine under docs/mods-layout.js.
# ABOUTME: Runs its bun unit tests and pins the seam the design lab loads it through.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
DOCS="$SCRIPT_DIR/../docs"

setup() { :; }
teardown() { :; }

# The engine is a plain script, not a module: the lab opens from file://, where
# a module script is blocked by CORS. Both halves of that are pinned here.
test_lab_loads_the_engine_as_a_plain_script() {
    assert_file_exists "$DOCS/mods-layout.js" "the engine exists" || return 1
    assert_file_contains "$DOCS/mods-design-lab.html" '<script src="mods-layout.js"></script>' \
        "the lab loads the engine with a plain script tag" || return 1
    assert_file_not_contains "$DOCS/mods-design-lab.html" 'src="mods-layout.js" type="module"' \
        "and not as a module (file:// blocks those)" || return 1
}

# bun imports the same file the browser does, through the CommonJS guard.
test_engine_exports_for_bun_and_for_the_browser() {
    assert_file_contains "$DOCS/mods-layout.js" 'module.exports = api' "a CommonJS export for the tests" || return 1
    assert_file_contains "$DOCS/mods-layout.js" 'root.ModLayout = api' "a global for the lab" || return 1
}

test_engine_unit_tests_pass_under_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        echo "    SKIP: bun not on PATH"
        return 77
    fi
    local out
    out="$(cd "$DOCS" && bun test 2>&1)" || { echo "$out"; return 1; }
    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

run_test test_lab_loads_the_engine_as_a_plain_script
run_test test_engine_exports_for_bun_and_for_the_browser
run_test test_engine_unit_tests_pass_under_bun

report_results
