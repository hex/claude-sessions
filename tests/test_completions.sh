#!/usr/bin/env bash
# ABOUTME: Guards against drift between bin/cs's command dispatch and the shell completions
# ABOUTME: Every top-level -command in bin/cs must appear in completions/_cs and completions/cs.bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_FILE="$SCRIPT_DIR/../bin/cs"
ZSH_COMP="$SCRIPT_DIR/../completions/_cs"
BASH_COMP="$SCRIPT_DIR/../completions/cs.bash"

# Extract single-dash top-level command tokens from the main dispatch case
# (the 8-space-indented arms only, so nested case arms like -update's are excluded).
dispatch_commands() {
    awk '/# Handle subcommands \(with - prefix\)/,/^    esac/' "$CS_FILE" \
        | grep -oE '^ {8}-[a-zA-Z|-]+\)' \
        | tr -d ' )' \
        | tr '|' '\n' \
        | grep -E '^-[a-z]' \
        | grep -vE '^--' \
        | grep -v '^-\*' \
        | sort -u
}

test_dispatch_extraction_is_sane() {
    local cmds
    cmds=$(dispatch_commands)
    assert_output_contains "$cmds" "-adopt" "extraction should find -adopt" || return 1
    assert_output_contains "$cmds" "-whoami" "extraction should find -whoami" || return 1
}

test_zsh_completion_covers_all_commands() {
    local missing="" cmd
    for cmd in $(dispatch_commands); do
        if ! grep -qF "'$cmd:" "$ZSH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/_cs missing:$missing"
        return 1
    fi
}

test_bash_completion_covers_all_commands() {
    local missing="" cmd
    for cmd in $(dispatch_commands); do
        if ! grep -qE "[\" ]$cmd[\" ]" "$BASH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/cs.bash missing:$missing"
        return 1
    fi
}

echo ""
echo "cs completion drift tests"
echo "========================="
echo ""

run_test test_dispatch_extraction_is_sane
run_test test_zsh_completion_covers_all_commands
run_test test_bash_completion_covers_all_commands

report_results
