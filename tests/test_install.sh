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
# Manifest arrays: install.sh and bin/cs must agree, and must match the repo
# ============================================================================

CS_BIN="$SCRIPT_DIR/../bin/cs"

# Print the entries of a bash array literal from a script file, one per line,
# with trailing comments and whitespace stripped.
extract_array() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 ~ "^"name"=\\(" { f=1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$file"
}

test_manifest_arrays_in_sync() {
    local arr a b
    for arr in CS_HOOKS RETIRED_HOOKS CS_COMMANDS CS_SKILLS; do
        a=$(extract_array "$SCRIPT_DIR/../install.sh" "$arr" | sort)
        b=$(extract_array "$CS_BIN" "$arr" | sort)
        if [ -z "$a" ]; then
            echo "  FAIL: $arr not found in install.sh"
            return 1
        fi
        if [ -z "$b" ]; then
            echo "  FAIL: $arr not found in bin/cs"
            return 1
        fi
        if [ "$a" != "$b" ]; then
            echo "  FAIL: $arr differs between install.sh and bin/cs"
            diff <(echo "$a") <(echo "$b") | head -10
            return 1
        fi
    done
}

# Print the jq filter body of _strip_hook_registration from a script file,
# whitespace-normalized: the lines between the `--arg t "$t"` argument line
# and the closing single-quote line.
extract_strip_filter() {
    local file="$1"
    awk '
        /_strip_hook_registration\(\)/ { infn=1 }
        infn && /--arg t "\$t"/ { grab=1; next }
        grab {
            if ($0 ~ /^[ \t]*'\''/) exit
            gsub(/^[ \t]+|[ \t]+$/, "")
            if (length) print
        }
    ' "$file"
}

test_strip_filters_in_sync() {
    local a b
    a=$(extract_strip_filter "$SCRIPT_DIR/../install.sh")
    b=$(extract_strip_filter "$CS_BIN")
    if [ -z "$a" ]; then
        echo "  FAIL: _strip_hook_registration filter not found in install.sh"
        return 1
    fi
    if [ -z "$b" ]; then
        echo "  FAIL: _strip_hook_registration filter not found in bin/cs"
        return 1
    fi
    if [ "$a" != "$b" ]; then
        echo "  FAIL: _strip_hook_registration jq filter differs between install.sh and bin/cs"
        diff <(echo "$a") <(echo "$b") | head -10
        return 1
    fi
}

test_manifest_arrays_match_repo_files() {
    local listed actual
    listed=$(extract_array "$SCRIPT_DIR/../install.sh" CS_HOOKS | sort)
    actual=$(cd "$SCRIPT_DIR/../hooks" && ls *.sh | sort)
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_HOOKS does not match hooks/*.sh"
        diff <(echo "$listed") <(echo "$actual") | head -10
        return 1
    fi

    listed=$(extract_array "$SCRIPT_DIR/../install.sh" CS_COMMANDS | sort)
    actual=$(cd "$SCRIPT_DIR/../commands" && ls *.md | sort)
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_COMMANDS does not match commands/*.md"
        diff <(echo "$listed") <(echo "$actual") | head -10
        return 1
    fi

    listed=$(extract_array "$SCRIPT_DIR/../install.sh" CS_SKILLS | sort)
    actual=$(cd "$SCRIPT_DIR/../skills" && ls -d ./*/ | sed 's|^\./||; s|/$||' | sort)
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_SKILLS does not match skills/ directories"
        diff <(echo "$listed") <(echo "$actual") | head -10
        return 1
    fi
}

# ============================================================================
# Hook deployment: binaries and registrations live under ~/.claude/hooks/cs/
# ============================================================================

test_install_deploys_hooks_to_cs_subdir() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }

    if [ ! -f "$fake_home/.claude/hooks/cs/session-start.sh" ]; then
        echo "  FAIL: session-start.sh not deployed under hooks/cs/"
        ls "$fake_home/.claude/hooks" 2>/dev/null | head -5
        return 1
    fi
    if [ ! -f "$fake_home/.claude/hooks/cs/scope-prompt.sh" ]; then
        echo "  FAIL: scope-prompt.sh not deployed under hooks/cs/"
        return 1
    fi

    local cnt
    cnt=$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/session-start.sh")] | length' \
        "$fake_home/.claude/settings.json")
    if [ "$cnt" != "1" ]; then
        echo "  FAIL: expected 1 subdir registration for session-start.sh, got $cnt"
        return 1
    fi
}

test_install_migrates_flat_hook_layout() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home/.claude/hooks"
    # Deployed binaries at the parent level: one current hook, one retired
    echo '#!/bin/sh' > "$fake_home/.claude/hooks/session-start.sh"
    echo '#!/bin/sh' > "$fake_home/.claude/hooks/files-context.sh"
    cat > "$fake_home/.claude/settings.json" << 'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}],"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"~/.claude/hooks/files-context.sh","timeout":5}]}]}}
EOF

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }

    if [ -f "$fake_home/.claude/hooks/session-start.sh" ]; then
        echo "  FAIL: parent-level session-start.sh binary not removed"
        return 1
    fi
    if [ -f "$fake_home/.claude/hooks/files-context.sh" ]; then
        echo "  FAIL: retired files-context.sh binary not removed"
        return 1
    fi
    if [ ! -f "$fake_home/.claude/hooks/cs/session-start.sh" ]; then
        echo "  FAIL: subdir session-start.sh missing after migration"
        return 1
    fi

    local flat sub
    flat=$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/session-start.sh")] | length' \
        "$fake_home/.claude/settings.json")
    sub=$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/session-start.sh")] | length' \
        "$fake_home/.claude/settings.json")
    if [ "$flat" != "0" ]; then
        echo "  FAIL: parent-level registration survived migration ($flat left)"
        return 1
    fi
    if [ "$sub" != "1" ]; then
        echo "  FAIL: expected exactly 1 subdir registration, got $sub (double-registration?)"
        return 1
    fi
    if jq -e '[.hooks[][] | .hooks[]?.command | select(test("files-context"))] | length > 0' \
        "$fake_home/.claude/settings.json" > /dev/null; then
        echo "  FAIL: retired files-context.sh registration survived"
        return 1
    fi
}

test_install_writes_version_stamp() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }

    local stamp expected
    if [ ! -f "$fake_home/.claude/hooks/cs/.version" ]; then
        echo "  FAIL: no .version stamp written to hooks/cs/"
        return 1
    fi
    stamp=$(cat "$fake_home/.claude/hooks/cs/.version")
    expected=$(grep -m1 '^VERSION=' "$CS_BIN" | cut -d'"' -f2)
    if [ "$stamp" != "$expected" ]; then
        echo "  FAIL: stamp '$stamp' does not match bin/cs VERSION '$expected'"
        return 1
    fi
}

test_uninstall_strips_hook_registrations() {
    local fake_home="$TEST_TMPDIR/uninstall-home"
    mkdir -p "$fake_home/.claude/hooks/cs"
    echo '#!/bin/sh' > "$fake_home/.claude/hooks/cs/session-start.sh"
    echo "0.0.0" > "$fake_home/.claude/hooks/cs/.version"
    # Tilde-form registrations in both layouts, plus a non-cs hook that must survive
    cat > "$fake_home/.claude/settings.json" << 'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/cs/session-start.sh","timeout":30}]}],"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/prose-lint.sh","timeout":15}]},{"hooks":[{"type":"command","command":"~/bin/my-own-hook.sh","timeout":5}]}]}}
EOF

    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }

    if [ -f "$fake_home/.claude/hooks/cs/session-start.sh" ]; then
        echo "  FAIL: deployed hook binary not removed"
        return 1
    fi
    if [ -d "$fake_home/.claude/hooks/cs" ]; then
        echo "  FAIL: hooks/cs directory not removed (stale .version blocking rmdir?)"
        return 1
    fi

    local cs_cnt user_cnt
    cs_cnt=$(jq '[.hooks // {} | .[][] | .hooks[]?.command | select(test("claude/hooks"))] | length' \
        "$fake_home/.claude/settings.json")
    user_cnt=$(jq '[.hooks // {} | .[][] | .hooks[]?.command | select(. == "~/bin/my-own-hook.sh")] | length' \
        "$fake_home/.claude/settings.json")
    if [ "$cs_cnt" != "0" ]; then
        echo "  FAIL: cs hook registrations survived uninstall ($cs_cnt left)"
        jq '.hooks' "$fake_home/.claude/settings.json"
        return 1
    fi
    if [ "$user_cnt" != "1" ]; then
        echo "  FAIL: non-cs hook registration was removed (expected it preserved)"
        return 1
    fi
}

# ============================================================================
# Cycle: cs-statusline deployment + statusLine registration
# ============================================================================

test_install_deploys_statusline_binary() {
    local fake_home="$TEST_TMPDIR/home-sl"
    mkdir -p "$fake_home"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ ! -x "$fake_home/.local/bin/cs-statusline" ]; then
        echo "  FAIL: cs-statusline not deployed executable to ~/.local/bin"
        return 1
    fi
}

test_install_skips_statusline_noninteractive() {
    local fake_home="$TEST_TMPDIR/home-sl-reg"
    mkdir -p "$fake_home"
    local out
    out=$(HOME="$fake_home" bash "$INSTALL_SH" 2>&1 < /dev/null) || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ -n "$cmd" ]; then
        echo "  FAIL: statusLine was registered without consent (got '$cmd')"
        return 1
    fi
    assert_output_contains "$out" "cs -statusline enable" \
        "non-interactive install should say how to enable the status line" || return 1
}

test_statusline_enable_registers() {
    local fake_home="$TEST_TMPDIR/home-sl-enable"
    mkdir -p "$fake_home/.claude" "$fake_home/.local/bin"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-statusline"
    chmod +x "$fake_home/.local/bin/cs-statusline"
    echo '{}' > "$fake_home/.claude/settings.json"
    HOME="$fake_home" "$CS_BIN" -statusline enable > /dev/null 2>&1 || {
        echo "  FAIL: cs -statusline enable exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    case "$cmd" in
        */cs-statusline) ;;
        *)
            echo "  FAIL: enable did not register cs-statusline (got '$cmd')"
            return 1
            ;;
    esac
    # The attention pulse animates on Claude Code's refresh timer; without
    # refreshInterval the bar only repaints on events and freezes when idle.
    local interval
    interval=$(jq -r '.statusLine.refreshInterval // ""' "$fake_home/.claude/settings.json")
    if [ "$interval" != "1" ]; then
        echo "  FAIL: enable should register refreshInterval 1 (got '$interval')"
        return 1
    fi
}

test_statusline_disable_strips_only_ours() {
    local fake_home="$TEST_TMPDIR/home-sl-disable"
    mkdir -p "$fake_home/.claude"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$fake_home/.local/bin/cs-statusline" > "$fake_home/.claude/settings.json"
    HOME="$fake_home" "$CS_BIN" -statusline disable > /dev/null 2>&1 || {
        echo "  FAIL: cs -statusline disable exited non-zero"
        return 1
    }
    if jq -e '.statusLine' "$fake_home/.claude/settings.json" > /dev/null 2>&1; then
        echo "  FAIL: disable left the cs-statusline registration behind"
        return 1
    fi
    # A foreign status line must survive disable untouched.
    echo '{"statusLine":{"type":"command","command":"node /x/omc-hud.mjs"}}' > "$fake_home/.claude/settings.json"
    HOME="$fake_home" "$CS_BIN" -statusline disable > /dev/null 2>&1 || true
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ "$cmd" != "node /x/omc-hud.mjs" ]; then
        echo "  FAIL: disable touched a foreign status line (now '$cmd')"
        return 1
    fi
}

test_install_preserves_foreign_statusline() {
    local fake_home="$TEST_TMPDIR/home-sl-foreign"
    mkdir -p "$fake_home/.claude"
    cat > "$fake_home/.claude/settings.json" << 'EOF'
{"statusLine":{"type":"command","command":"node /Users/x/.claude/hud/omc-hud.mjs"}}
EOF
    local out
    out=$(HOME="$fake_home" bash "$INSTALL_SH" 2>&1 < /dev/null) || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ "$cmd" != "node /Users/x/.claude/hud/omc-hud.mjs" ]; then
        echo "  FAIL: foreign statusLine was replaced non-interactively (now '$cmd')"
        return 1
    fi
    assert_output_contains "$out" "cs-statusline" "install should mention how to enable cs-statusline" || return 1
}

test_uninstall_removes_statusline() {
    local fake_home="$TEST_TMPDIR/uninstall-sl"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-statusline"
    cat > "$fake_home/.claude/settings.json" << EOF
{"statusLine":{"type":"command","command":"$fake_home/.local/bin/cs-statusline"}}
EOF
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-statusline" ]; then
        echo "  FAIL: cs-statusline binary not removed"
        return 1
    fi
    if jq -e '.statusLine' "$fake_home/.claude/settings.json" > /dev/null 2>&1; then
        echo "  FAIL: statusLine registration survived uninstall"
        return 1
    fi
}

test_uninstall_preserves_foreign_statusline() {
    local fake_home="$TEST_TMPDIR/uninstall-sl-foreign"
    mkdir -p "$fake_home/.claude"
    cat > "$fake_home/.claude/settings.json" << 'EOF'
{"statusLine":{"type":"command","command":"node /Users/x/.claude/hud/omc-hud.mjs"}}
EOF
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ "$cmd" != "node /Users/x/.claude/hud/omc-hud.mjs" ]; then
        echo "  FAIL: foreign statusLine was stripped by uninstall (now '$cmd')"
        return 1
    fi
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_install.sh"
echo ""
run_test test_install_completes_when_zshrc_has_no_fpath
run_test test_install_respects_custom_fpath_dir
run_test test_manifest_arrays_in_sync
run_test test_manifest_arrays_match_repo_files
run_test test_strip_filters_in_sync
run_test test_install_deploys_hooks_to_cs_subdir
run_test test_install_migrates_flat_hook_layout
run_test test_install_writes_version_stamp
run_test test_uninstall_strips_hook_registrations
run_test test_install_deploys_statusline_binary
run_test test_install_skips_statusline_noninteractive
run_test test_statusline_enable_registers
run_test test_statusline_disable_strips_only_ours
run_test test_install_preserves_foreign_statusline
run_test test_uninstall_removes_statusline
run_test test_uninstall_preserves_foreign_statusline
report_results
