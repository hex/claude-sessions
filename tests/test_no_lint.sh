#!/usr/bin/env bash
# ABOUTME: Guards that the removed prose linter stays gone
# ABOUTME: cs -lint must error, and the prose-lint Stop hook must be retired, not orphaned

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

REPO_ROOT="$SCRIPT_DIR/.."

# Print the entries of a bash array literal from a script file, one per line.
lint_extract_array() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 ~ "^"name"=\\(" { f=1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$file"
}

test_lint_global_command_removed() {
    local out ec
    out=$("$CS_BIN" -lint /dev/null 2>&1); ec=$?
    [ "$ec" -ne 0 ] || { echo "  FAIL: 'cs -lint' should exit non-zero"; return 1; }
    assert_output_contains "$out" "Unknown command" "'cs -lint' must report an unknown command" || return 1
}

test_help_has_no_lint() {
    local out
    out=$("$CS_BIN" -help 2>&1)
    assert_output_not_contains "$out" "\-lint" "help must not mention -lint" || return 1
}

test_lint_internals_gone_from_binary() {
    assert_file_not_contains "$CS_BIN" "run_lint" \
        "bin/cs must not carry the run_lint implementation" || return 1
    assert_file_not_contains "$CS_BIN" "lint_prose_file" \
        "bin/cs must not carry the lint_prose_file implementation" || return 1
    assert_file_not_contains "$CS_BIN" "PROSE_SLOP_PHRASES" \
        "bin/cs must not carry the banned-phrase table" || return 1
}

# The safety-critical pin. error() ends in `exit 1` (lib/05-term.sh), and the
# prose-lint hook read exit 1 as "violations found" and blocked turn-end. An
# upgrade that drops the verb while leaving the hook deployed and registered
# would block every turn-end with an empty violation list, three times a
# session, until the hook's own loop guard relented. RETIRED_HOOKS is what
# deletes the deployed file and strips its settings.json registration on
# upgrade, so membership here is the thing that makes the removal safe.
test_prose_lint_hook_is_retired() {
    local f
    for f in "$REPO_ROOT/install.sh" "$CS_BIN"; do
        if ! lint_extract_array "$f" RETIRED_HOOKS | grep -qx "prose-lint.sh"; then
            echo "  FAIL: prose-lint.sh must be listed in RETIRED_HOOKS in $f"
            return 1
        fi
        if lint_extract_array "$f" CS_HOOKS | grep -qx "prose-lint.sh"; then
            echo "  FAIL: prose-lint.sh must not still be listed in CS_HOOKS in $f"
            return 1
        fi
    done
}

test_prose_lint_hook_file_removed() {
    assert_file_not_exists "$REPO_ROOT/hooks/prose-lint.sh" \
        "hooks/prose-lint.sh must be deleted, not left shipping" || return 1
}

test_install_does_not_register_prose_lint() {
    assert_file_not_contains "$REPO_ROOT/install.sh" "_merge_cs_hook Stop *prose-lint" \
        "install.sh must not register prose-lint.sh against the Stop event" || return 1
}

# A shipped prompt that calls a removed verb sends every session down a dead
# path; the caller has no way to tell a missing verb from a clean file.
test_no_shipped_prompt_invokes_lint() {
    local hits
    hits=$(grep -rl -- "cs -lint" "$REPO_ROOT/commands" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" 2>/dev/null || true)
    assert_eq "" "$hits" "no shipped command, skill or hook may invoke the removed cs -lint" || return 1
}

test_completions_do_not_offer_lint() {
    assert_file_not_contains "$REPO_ROOT/completions/cs.bash" "\-lint" \
        "bash completion must not offer -lint" || return 1
    assert_file_not_contains "$REPO_ROOT/completions/_cs" "'\-lint:" \
        "zsh completion must not offer -lint" || return 1
}

echo ""
echo "cs prose-lint removal guards"
echo "============================"
echo ""

run_test test_lint_global_command_removed
run_test test_help_has_no_lint
run_test test_lint_internals_gone_from_binary
run_test test_prose_lint_hook_is_retired
run_test test_prose_lint_hook_file_removed
run_test test_install_does_not_register_prose_lint
run_test test_no_shipped_prompt_invokes_lint
run_test test_completions_do_not_offer_lint

report_results
