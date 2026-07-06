#!/usr/bin/env bash
# ABOUTME: Guards against drift between bin/cs's command dispatch and the shell completions
# ABOUTME: Every top-level -command in bin/cs must appear in completions/_cs and completions/cs.bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_FILE="$SCRIPT_DIR/../bin/cs"
SECRETS_FILE="$SCRIPT_DIR/../bin/cs-secrets"
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

# Extract secrets subcommand tokens from bin/cs-secrets' argument parser: the
# single combined arm (set|store|...|backend), plus age, which takes its own arm.
secrets_subcommands() {
    {
        grep -oE '^ +set\|store\|[a-z|-]+\)' "$SECRETS_FILE" \
            | tr -d ' )' \
            | tr '|' '\n'
        echo "age"
    } | grep -E '^[a-z]' | sort -u
}

test_secrets_extraction_is_sane() {
    local cmds
    cmds=$(secrets_subcommands)
    assert_output_contains "$cmds" "age" "extraction should find age" || return 1
    assert_output_contains "$cmds" "migrate-backend" "extraction should find migrate-backend" || return 1
    assert_output_contains "$cmds" "export-file" "extraction should find export-file" || return 1
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

test_zsh_completion_covers_all_secrets_subcommands() {
    local missing="" cmd
    for cmd in $(secrets_subcommands); do
        if ! grep -qF "'$cmd:" "$ZSH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/_cs missing secrets subcommands:$missing"
        return 1
    fi
}

test_bash_completion_covers_all_secrets_subcommands() {
    local missing="" cmd
    for cmd in $(secrets_subcommands); do
        if ! grep -qE "[\" ]$cmd[\" ]" "$BASH_COMP" 2>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "  FAIL: completions/cs.bash missing secrets subcommands:$missing"
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
run_test test_secrets_extraction_is_sane
run_test test_zsh_completion_covers_all_secrets_subcommands
run_test test_bash_completion_covers_all_secrets_subcommands

report_results
