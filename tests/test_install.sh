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

# An empty or invalid settings.json must not abort the install; it should be
# backed up and replaced with a valid object so hook registration proceeds.
test_install_recovers_from_invalid_settings_json() {
    command -v jq >/dev/null 2>&1 || return 0  # jq path only
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home/.claude"
    printf 'not json at all {{{' > "$fake_home/.claude/settings.json"

    local rc=0
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "install must not abort on invalid settings.json" || return 1
    assert_file_exists "$fake_home/.claude/settings.json.cs-bak" \
        "invalid settings.json should be backed up" || return 1
    jq -e . "$fake_home/.claude/settings.json" >/dev/null 2>&1 \
        || { echo "  FAIL: settings.json is not valid JSON after install"; return 1; }
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
    for arr in CS_HOOKS RETIRED_HOOKS CS_COMMANDS CS_SKILLS CS_SKILL_FILES; do
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

test_skill_files_exist_in_repo() {
    local entry
    for entry in $(extract_array "$SCRIPT_DIR/../install.sh" CS_SKILL_FILES); do
        if [ ! -f "$SCRIPT_DIR/../skills/$entry" ]; then
            echo "  FAIL: CS_SKILL_FILES entry missing from repo: skills/$entry"
            return 1
        fi
        if [ ! -x "$SCRIPT_DIR/../skills/$entry" ]; then
            echo "  FAIL: skill support script not executable: skills/$entry"
            return 1
        fi
    done
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

test_install_deploys_subagent_statusline_binary() {
    local fake_home="$TEST_TMPDIR/home-ssl"
    mkdir -p "$fake_home"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ ! -x "$fake_home/.local/bin/cs-subagent-statusline" ]; then
        echo "  FAIL: cs-subagent-statusline not deployed executable to ~/.local/bin"
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

# A cross-platform reinstall must not leave cs-tui and cs-tui.exe side by side.
# On this (non-Windows) platform, install must remove a stale cs-tui.exe so PATH
# / sibling resolution cannot pick the wrong-platform binary.
test_install_removes_stale_opposite_platform_tui() {
    local fake_home="$TEST_TMPDIR/install-tui-clean"
    mkdir -p "$fake_home/.local/bin"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-tui.exe"   # stale Windows binary
    chmod +x "$fake_home/.local/bin/cs-tui.exe"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-tui.exe" ]; then
        echo "  FAIL: stale cs-tui.exe not removed on a non-Windows install"
        return 1
    fi
    # NB: we do not assert cs-tui was installed — bin/cs-tui is a build artifact,
    # not git-tracked, so it is absent from a fresh CI checkout. The behavior
    # under test is that the opposite-platform binary is removed regardless.
}

# On native Windows the TUI installs as cs-tui.exe; uninstall must remove that
# filename too, not only the Unix-named cs-tui.
# The name the release workflow PUBLISHES for native Windows and the name
# install.sh FETCHES there are set in two different files and only ever meet
# during a real release -- which has never run the Windows matrix entry. Derive
# each from its own source and pin them together.
_release_windows_tui_artifact() {
    local yml="$SCRIPT_DIR/../.github/workflows/release.yml"
    local platform ext
    platform=$(grep -o 'platform: windows-[a-z0-9]*' "$yml" | head -1 | sed 's/platform: //')
    ext=$(grep -A3 'platform: windows-' "$yml" | grep -o 'ext: "[^"]*"' | head -1 | sed -e 's/ext: "//' -e 's/"$//')
    [ -n "$platform" ] || return 1
    printf 'cs-tui-%s%s' "$platform" "$ext"
}

# Run install.sh's WEB path as if on Git Bash, recording every URL it requests.
# Copied to a bin/-less dir so install.sh selects INSTALL_METHOD=web; uname and
# curl are stubbed so the run needs no network and no Windows host.
_install_urls_on_msys() {
    local sandbox="$TEST_TMPDIR/msys-install"
    local bindir="$sandbox/stub" log="$sandbox/urls.txt"
    mkdir -p "$bindir" "$sandbox/home"
    cp "$INSTALL_SH" "$sandbox/install.sh"

    cat > "$bindir/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    -s) echo "MINGW64_NT-10.0-22631" ;;
    -m) echo "x86_64" ;;
    *)  echo "MINGW64_NT-10.0-22631" ;;
esac
STUB

    cat > "$bindir/curl" <<STUB
#!/usr/bin/env bash
# Record every requested URL, then satisfy the request with a stub payload so
# install.sh proceeds far enough to reach the TUI fetch.
out=""; url=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*) url="\$a" ;; esac
    prev="\$a"
done
[ -n "\$url" ] && printf '%s\n' "\$url" >> "$log"
if [ -n "\$out" ]; then
    case "\$out" in
        */cs) printf 'VERSION="9999.9.9"\n' > "\$out" ;;
        *)    printf 'stub\n' > "\$out" ;;
    esac
fi
exit 0
STUB
    chmod +x "$bindir/uname" "$bindir/curl"

    PATH="$bindir:$PATH" HOME="$sandbox/home" bash "$sandbox/install.sh" >/dev/null 2>&1
    cat "$log" 2>/dev/null
}

test_release_windows_tui_artifact_matches_what_install_fetches() {
    local expected; expected=$(_release_windows_tui_artifact) || {
        echo "  FAIL: release.yml has no windows platform matrix entry"
        return 1
    }

    local urls; urls=$(_install_urls_on_msys)
    local fetched
    fetched=$(printf '%s\n' "$urls" | grep -o 'cs-tui-[a-z0-9-]*\(\.exe\)\{0,1\}$' | head -1)

    if [ -z "$fetched" ]; then
        echo "  FAIL: install.sh requested no cs-tui artifact on a Git Bash host"
        printf '%s\n' "$urls" | sed 's/^/    /'
        return 1
    fi
    assert_eq "$expected" "$fetched" \
        "install.sh must fetch the artifact name release.yml publishes" || {
        printf '%s\n' "$urls" | sed 's/^/    /'
        return 1
    }

    # The signature and checksum siblings must be fetched under the SAME base,
    # or verification silently no-ops and an unverified binary is kept.
    printf '%s\n' "$urls" | grep -q "${expected}\.sha256\$" \
        || { echo "  FAIL: no ${expected}.sha256 requested"; return 1; }
    printf '%s\n' "$urls" | grep -q "${expected}\.minisig\$" \
        || { echo "  FAIL: no ${expected}.minisig requested"; return 1; }
}

test_uninstall_removes_windows_cs_tui_exe() {
    local fake_home="$TEST_TMPDIR/uninstall-tui-exe"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-tui.exe"
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-tui.exe" ]; then
        echo "  FAIL: cs-tui.exe (Windows TUI) survived uninstall"
        return 1
    fi
}

test_uninstall_removes_subagent_statusline() {
    local fake_home="$TEST_TMPDIR/uninstall-ssl"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-subagent-statusline"
    cat > "$fake_home/.claude/settings.json" << EOF
{"subagentStatusLine":{"type":"command","command":"$fake_home/.local/bin/cs-subagent-statusline"}}
EOF
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-subagent-statusline" ]; then
        echo "  FAIL: cs-subagent-statusline binary not removed"
        return 1
    fi
    if jq -e '.subagentStatusLine' "$fake_home/.claude/settings.json" > /dev/null 2>&1; then
        echo "  FAIL: subagentStatusLine registration survived uninstall"
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
run_test test_skill_files_exist_in_repo
run_test test_strip_filters_in_sync
run_test test_install_deploys_hooks_to_cs_subdir
run_test test_install_migrates_flat_hook_layout
run_test test_install_writes_version_stamp
run_test test_uninstall_strips_hook_registrations
run_test test_install_deploys_statusline_binary
run_test test_install_deploys_subagent_statusline_binary
run_test test_install_skips_statusline_noninteractive
run_test test_statusline_enable_registers
run_test test_statusline_disable_strips_only_ours
run_test test_install_preserves_foreign_statusline
run_test test_uninstall_removes_statusline
run_test test_install_removes_stale_opposite_platform_tui
run_test test_release_windows_tui_artifact_matches_what_install_fetches
run_test test_uninstall_removes_windows_cs_tui_exe
run_test test_uninstall_removes_subagent_statusline
test_hook_registration_doc_matches_install() {
    # docs/hooks.md restates install.sh's _merge_cs_hook registrations as a
    # JSON block readers trust for timeouts; pin file+timeout pairs so an
    # install.sh change fails here instead of silently outdating the doc.
    local doc="$SCRIPT_DIR/../docs/hooks.md" regs file timeout rest
    regs=$(grep -E '^ +_merge_cs_hook ' "$SCRIPT_DIR/../install.sh")
    [ -n "$regs" ] || { echo "  FAIL: no _merge_cs_hook registrations found in install.sh"; return 1; }
    while read -r _ _ file timeout rest; do
        [ -n "$file" ] || continue
        grep -qF "cs/${file}\", \"timeout\": ${timeout}" "$doc" || {
            echo "  FAIL: docs/hooks.md registration block missing/stale for $file (timeout $timeout)"
            return 1
        }
    done <<< "$regs"
}

run_test test_uninstall_preserves_foreign_statusline
run_test test_install_recovers_from_invalid_settings_json
run_test test_hook_registration_doc_matches_install
report_results
