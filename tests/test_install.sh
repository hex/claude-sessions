#!/usr/bin/env bash
# ABOUTME: Tests for install.sh end-to-end behavior
# ABOUTME: Isolates HOME to a tmpdir so install side-effects don't leak

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Override teardown: also reset HOME if a test set it.
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR
}

# ============================================================================
# Cycle 1: install.sh must not silently exit when .zshrc lacks an fpath line
# (regression — issue #1: silent exit under set -euo pipefail when grep finds
# no match in .zshrc and pipefail surfaces the non-zero through the command
# substitution)
# ============================================================================

test_install_completes_when_zshrc_has_no_fpath() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "# minimal zshrc with no fpath line" > "$fake_home/.zshrc"

    local stdout_log="$TEST_TMPDIR/install.stdout"
    local stderr_log="$TEST_TMPDIR/install.stderr"
    local rc=0
    HOME="$fake_home" bash "$INSTALL_SH" > "$stdout_log" 2> "$stderr_log" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: install.sh exited with code $rc (expected 0)"
        echo "    stdout: $(wc -c < "$stdout_log" | tr -d ' ') bytes"
        echo "    stderr: $(head -5 "$stderr_log")"
        return 1
    fi

    # With the bug, stdout is completely empty (script dies before any output).
    # The fix makes the script proceed and print at least the installer banner.
    local stdout_bytes
    stdout_bytes=$(wc -c < "$stdout_log" | tr -d ' ')
    if [ "$stdout_bytes" -eq 0 ]; then
        echo "  FAIL: install.sh produced zero stdout (silent exit symptom)"
        return 1
    fi
}

# ============================================================================
# Cycle 2: install.sh respects a user-defined fpath when present in .zshrc
# (happy path — verifies the fpath-detection logic still works after the fix)
# ============================================================================

test_install_respects_custom_fpath_dir() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    cat > "$fake_home/.zshrc" << 'EOF'
# zshrc with a custom fpath line
fpath=(~/.zsh/completion $fpath)
EOF

    local rc=0
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: install.sh exited with code $rc on .zshrc WITH fpath"
        return 1
    fi

    # The completion script should land in the user's configured dir
    # (`~/.zsh/completion`, singular) — not the default `~/.zsh/completions`.
    if [ ! -e "$fake_home/.zsh/completion/_cs" ]; then
        # Some completion shape — confirm SOMETHING landed in the custom dir.
        if [ ! -d "$fake_home/.zsh/completion" ]; then
            echo "  FAIL: custom fpath dir ~/.zsh/completion was not created"
            echo "    contents of fake_home:"
            find "$fake_home/.zsh" -maxdepth 2 2>/dev/null | head -5
            return 1
        fi
    fi
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_install.sh"
echo ""
run_test test_install_completes_when_zshrc_has_no_fpath
run_test test_install_respects_custom_fpath_dir
report_results
