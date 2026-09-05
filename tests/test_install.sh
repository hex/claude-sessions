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
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR XDG_CONFIG_HOME
}

# The declined marker is a preference memo, and a memo that cannot be written
# must never take the install down with it. install.sh runs under errexit and
# the marker write ends its && list, so a failing touch aborts before
# settings.json is written: hooks land on disk unregistered, the version stamp
# is missing, and the run ends with no completion message. An unwritable
# ~/.config/cs is enough to trigger it — an earlier root-run install leaves
# exactly that.
test_install_survives_an_unwritable_declined_marker_dir() {
    command -v expect >/dev/null 2>&1 \
        || { echo "    SKIP (expect not installed; the decline needs a tty)"; return 0; }
    local fake_home="$TEST_TMPDIR/home-nowrite"
    mkdir -p "$fake_home/.claude" "$fake_home/.config/cs"
    printf '{"statusLine":{"command":"/opt/other/bar"}}\n' > "$fake_home/.claude/settings.json"
    chmod 500 "$fake_home/.config/cs"
    # The decline only happens on a tty, and the pty helper cannot answer a
    # prompt (see test_lib.sh) — so drive it with expect. Answering N is what
    # reaches the marker write; a non-interactive run never does, which is why
    # asserting this without a tty would pass while testing nothing.
    local exp="$TEST_TMPDIR/decline.exp"
    cat > "$exp" <<EXPECT
set timeout 120
spawn env HOME=$fake_home bash $INSTALL_SH
expect {
    -re {status line.*\[y/N\]} { send "n\r"; exp_continue }
    -re {status line.*\[Y/n\]} { send "n\r"; exp_continue }
    eof
}
catch wait result
exit [lindex \$result 3]
EXPECT
    local rc=0
    expect -f "$exp" >/dev/null 2>&1 || rc=$?
    chmod 700 "$fake_home/.config/cs"
    assert_eq "0" "$rc" "declining must not abort the install when the memo cannot be written" || return 1
    # The properties that matter: the user's own bar survived, and the install
    # actually finished rather than dying before it wrote settings.json.
    local sl
    sl=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json" 2>/dev/null)
    assert_eq "/opt/other/bar" "$sl" "a foreign status line must be kept" || return 1
    jq -e '.hooks.SessionStart' "$fake_home/.claude/settings.json" >/dev/null 2>&1 \
        || { echo "  FAIL: hooks were not registered; the install aborted before finishing"; return 1; }
}

# Declining is permanent, and that has to read as its own statement rather than
# a clause at the end of a sentence about what did not happen. The [y/N] branch
# is where it matters most: the DEFAULT answer opts the user out for good, so
# someone pressing enter to skip one release is making a decision they did not
# know they were making.
test_declining_says_permanence_on_its_own_line() {
    command -v expect >/dev/null 2>&1 \
        || { echo "    SKIP (expect not installed; the decline needs a tty)"; return 0; }
    local fake_home="$TEST_TMPDIR/home-declinemsg"
    mkdir -p "$fake_home/.claude"
    printf '{"statusLine":{"command":"/opt/other/bar"}}\n' > "$fake_home/.claude/settings.json"
    local exp="$TEST_TMPDIR/declinemsg.exp" out="$TEST_TMPDIR/declinemsg.out"
    cat > "$exp" <<EXPECT
set timeout 120
log_file -noappend $out
spawn env HOME=$fake_home bash $INSTALL_SH
expect {
    -re {status line.*\[y/N\]} { send "n\r"; exp_continue }
    eof
}
EXPECT
    expect -f "$exp" >/dev/null 2>&1 || true
    # The permanence must be a line of its own, not a trailing clause.
    grep -q "won't be asked again" "$out" \
        || { echo "  FAIL: the decline must state plainly that it is remembered"; return 1; }
    local line
    line=$(grep "won't be asked again" "$out" | head -1)
    case "$line" in
        *"Keeping current status line"*)
            echo "  FAIL: permanence must not ride on the same line as the outcome"; return 1 ;;
    esac
    # And the way back stays with it.
    grep -q "cs -statusline enable" "$out" \
        || { echo "  FAIL: the decline must name the command that undoes it"; return 1; }
}

# Asking someone to install a status bar they have never seen is a weak prompt.
# The installer renders a sample first, built from a fixed payload so the
# preview is the same everywhere and never reads the machine it runs on: the
# real segments pull git state, mail counts and rate limits from whatever
# session is live, which would put a stranger's branch name and unread count
# into an installer preview.
test_install_previews_the_status_line_before_asking() {
    command -v expect >/dev/null 2>&1 \
        || { echo "    SKIP (expect not installed; the prompt needs a tty)"; return 0; }
    local fake_home="$TEST_TMPDIR/home-preview"
    mkdir -p "$fake_home/.claude"
    local exp="$TEST_TMPDIR/preview.exp" out="$TEST_TMPDIR/preview.out"
    cat > "$exp" <<EXPECT
set timeout 120
log_file -noappend $out
spawn env HOME=$fake_home bash $INSTALL_SH
expect {
    -re {status line.*\[Y/n\]} { send "n\r"; exp_continue }
    -re {Complete|complete} { exp_continue }
    eof
}
EXPECT
    expect -f "$exp" >/dev/null 2>&1 || true
    # A sample renders, and it renders BEFORE the question.
    local sample_line prompt_line
    sample_line=$(grep -n 'ctx ' "$out" | head -1 | cut -d: -f1)
    prompt_line=$(grep -n 'as the Claude Code status line' "$out" | head -1 | cut -d: -f1)
    [ -n "$sample_line" ] || { echo "  FAIL: no status line sample rendered"; return 1; }
    [ -n "$prompt_line" ] || { echo "  FAIL: no prompt"; return 1; }
    [ "$sample_line" -lt "$prompt_line" ] \
        || { echo "  FAIL: the sample must render before the question"; return 1; }
    # Labelled: position alone leaves a cold reader with a coloured strip and
    # no statement of what it is, sitting among the installer's own output.
    local label_line
    label_line=$(grep -n 'what it looks like' "$out" | head -1 | cut -d: -f1)
    # The preview must be drawn for the terminal it appears in. The statusline
    # falls back to its DARK palette whenever it can measure nothing, and a
    # subprocess of the installer measures nothing — so a light terminal got a
    # dark bar, which is the one thing a "this is what it looks like" sample
    # must not get wrong. install.sh owns the tty and has just installed the
    # binary that can answer, so it asks.
    grep -q 'CS_TERM_THEME' "$SCRIPT_DIR/../install.sh" \
        || { echo "  FAIL: the preview must render in the terminal's own theme"; return 1; }
    # And it must not PROBE for it: an OSC query writes to /dev/tty, which no
    # capture intercepts, so the escape and its reply paint over the installer.
    # The invocation, not the word: the code comments explain why the probe is
    # avoided, and matching prose would fail on its own rationale.
    if grep -qE '(cs|\$INSTALL_DIR/cs)" *-detect-theme|cs -detect-theme\)' "$SCRIPT_DIR/../install.sh"; then
        echo "  FAIL: the preview must not run the OSC probe; it leaks onto the screen"
        return 1
    fi
    if grep -q ']11;?' "$out" 2>/dev/null; then
        echo "  FAIL: a raw OSC escape reached the installer output"; return 1
    fi
    [ -n "$label_line" ] \
        || { echo "  FAIL: the sample must say what it is"; return 1; }
    [ "$label_line" -lt "$sample_line" ] \
        || { echo "  FAIL: the label must precede the sample it names"; return 1; }
    # And it lines up with the block above it. Every installed-line carries
    # three leading spaces; a flush-left label reads as output that escaped the
    # formatting rather than as part of the run. The bar itself cannot be
    # indented (its opening reset eats leading spaces), so the label is what
    # carries the alignment.
    local label_text
    label_text=$(sed -n "${label_line}p" "$out" | sed 's/\x1b\[[0-9;]*m//g')
    case "$label_text" in
        "   "*) ;;
        *) echo "  FAIL: the label must align with the installer's other lines"; return 1 ;;
    esac
    # Fixed payload: the sample line itself must carry the placeholder session,
    # not whatever is live. Checked on the RENDERED LINE rather than the whole
    # transcript — the installer legitimately prints its own paths, and a
    # transcript-wide grep matches those instead of a leak.
    local sample
    sample=$(sed -n "${sample_line}p" "$out")
    case "$sample" in
        *my-session*) ;;
        *) echo "  FAIL: the sample must use the fixed placeholder session"; return 1 ;;
    esac
    # The live-only segments must not appear: they read git, mail and limits
    # from the running machine.
    case "$sample" in
        *"⎇ "*) echo "  FAIL: the preview rendered the live git branch"; return 1 ;;
    esac
}

# Enter declines exactly as n does. The whole point of the change is that
# cs -update stops asking, so a default that left the question open would
# re-prompt the very people the feature was written for. The decline states
# plainly that it is remembered, and cs -statusline enable reverses it.
test_enter_declines_the_same_as_an_explicit_n() {
    command -v expect >/dev/null 2>&1 \
        || { echo "    SKIP (expect not installed; the prompt needs a tty)"; return 0; }
    local ans
    for ans in "" "n"; do
        local fake_home="$TEST_TMPDIR/home-ans${ans:-enter}"
        mkdir -p "$fake_home/.claude"
        printf '{"statusLine":{"command":"/opt/other/bar"}}\n' > "$fake_home/.claude/settings.json"
        local exp="$TEST_TMPDIR/ans${ans:-enter}.exp"
        cat > "$exp" <<EXPECT
set timeout 120
spawn env HOME=$fake_home bash $INSTALL_SH
expect {
    -re {status line.*\[y/N\]} { send "$ans\r"; exp_continue }
    -re {Complete|complete} { exp_continue }
    eof
}
EXPECT
        expect -f "$exp" >/dev/null 2>&1 || true
        [ -f "$fake_home/.config/cs/statusline-declined" ] \
            || { echo "  FAIL: answer '${ans:-enter}' must be remembered"; return 1; }
        local sl
        sl=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json" 2>/dev/null)
        assert_eq "/opt/other/bar" "$sl" "answer '${ans:-enter}' must keep the current bar" || return 1
    done
}

# Same guard on the disable path, which shares the construct.
test_statusline_disable_survives_an_unwritable_marker_dir() {
    local fake_home="$TEST_TMPDIR/home-disable-nowrite"
    mkdir -p "$fake_home/.claude" "$fake_home/.config/cs"
    printf '{"statusLine":{"command":"%s/.local/bin/cs-statusline"}}\n' "$fake_home" \
        > "$fake_home/.claude/settings.json"
    chmod 500 "$fake_home/.config/cs"
    local rc=0
    HOME="$fake_home" bash "$SCRIPT_DIR/../bin/cs" -statusline disable >/dev/null 2>&1 || rc=$?
    chmod 700 "$fake_home/.config/cs"
    assert_eq "0" "$rc" "disable must not exit non-zero when the memo cannot be written" || return 1
}

# The suite must not read or write the developer's own XDG config dir. Three of
# the marker tests resolved ~/.config/cs from a live XDG_CONFIG_HOME, so with it
# set they failed AND the uninstall test deleted a real marker file.
test_marker_tests_do_not_touch_a_live_xdg_config_home() {
    local guard="$TEST_TMPDIR/xdg-guard"
    mkdir -p "$guard/cs"
    : > "$guard/cs/statusline-declined"
    local fake_home="$TEST_TMPDIR/home-xdg"
    mkdir -p "$fake_home/.claude"
    XDG_CONFIG_HOME="$guard" HOME="$fake_home" bash "$INSTALL_SH" >/dev/null 2>&1 || true
    [ -f "$guard/cs/statusline-declined" ] \
        || { echo "  FAIL: a run deleted a marker outside its own fixture"; return 1; }
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

# bin/cs-tui is a gitignored build artifact and NOTHING regenerates it: build.sh
# assembles bin/cs from lib/ and has no TUI arm, while `cargo build --release`
# writes to tui/target/release/. So a local install shipped whatever stale binary
# happened to be sitting in bin/ — observed shipping a picker 17 days old while
# reporting success, which is the failure mode a version check cannot catch
# (the picker carries no version of its own).
test_local_install_prefers_a_freshly_built_picker() {
    local fake_home="$TEST_TMPDIR/home" repo="$TEST_TMPDIR/repo"
    mkdir -p "$fake_home" "$repo/bin" "$repo/tui/target/release"
    local real="$SCRIPT_DIR/.."
    # Everything the installer reads, borrowed; only the two picker sources are
    # ours, so the test says nothing about the rest of the tree.
    local e
    for e in hooks commands skills completions docs lib README.md CHANGELOG.md LICENSE build.sh; do
        [ -e "$real/$e" ] && ln -s "$(cd "$real" && pwd)/$e" "$repo/$e"
    done
    cp "$real/install.sh" "$repo/install.sh"
    cp "$real/bin/cs" "$real/bin/cs-secrets" "$real/bin/cs-statusline" \
       "$real/bin/cs-subagent-statusline" "$repo/bin/" 2>/dev/null || true
    printf 'STALE PICKER' > "$repo/bin/cs-tui"
    chmod +x "$repo/bin/cs-tui"
    # Distinct mtimes, oldest first: -nt is the whole decision.
    printf 'FRESH PICKER' > "$repo/tui/target/release/cs-tui"
    chmod +x "$repo/tui/target/release/cs-tui"
    touch -t 202001010000 "$repo/bin/cs-tui"

    HOME="$fake_home" bash "$repo/install.sh" > /dev/null 2>&1 || true

    local installed="$fake_home/.local/bin/cs-tui"
    assert_file_exists "$installed" "a picker should have been installed" || return 1
    assert_eq "FRESH PICKER" "$(cat "$installed")" \
        "the newer cargo build must win over a stale bin/cs-tui" || return 1
}

# The reverse: nothing built, so bin/cs-tui is all there is. A release tarball
# ships that and no tui/target at all.
test_local_install_uses_bin_picker_when_nothing_was_built() {
    local fake_home="$TEST_TMPDIR/home2" repo="$TEST_TMPDIR/repo2"
    mkdir -p "$fake_home" "$repo/bin"
    local real="$SCRIPT_DIR/.."
    local e
    for e in hooks commands skills completions docs lib README.md CHANGELOG.md LICENSE build.sh; do
        [ -e "$real/$e" ] && ln -s "$(cd "$real" && pwd)/$e" "$repo/$e"
    done
    cp "$real/install.sh" "$repo/install.sh"
    cp "$real/bin/cs" "$real/bin/cs-secrets" "$real/bin/cs-statusline" \
       "$real/bin/cs-subagent-statusline" "$repo/bin/" 2>/dev/null || true
    printf 'ONLY PICKER' > "$repo/bin/cs-tui"
    chmod +x "$repo/bin/cs-tui"

    HOME="$fake_home" bash "$repo/install.sh" > /dev/null 2>&1 || true

    assert_eq "ONLY PICKER" "$(cat "$fake_home/.local/bin/cs-tui" 2>/dev/null)" \
        "with no build present the shipped picker must still install" || return 1
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
    for arr in CS_HOOKS CS_HOOK_LIBS RETIRED_HOOKS CS_COMMANDS CS_SKILLS RETIRED_SKILLS CS_SKILL_FILES; do
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
    # hooks/ holds two kinds of file: hooks, which install.sh registers against
    # an event, and libraries the hooks source, which must ship and be removed
    # with them but must never be registered. Together they must account for
    # every file, so a new one cannot be silently left uninstalled.
    listed=$( { extract_array "$SCRIPT_DIR/../install.sh" CS_HOOKS
                extract_array "$SCRIPT_DIR/../install.sh" CS_HOOK_LIBS; } | sort)
    actual=$(cd "$SCRIPT_DIR/../hooks" && ls *.sh | sort)
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_HOOKS + CS_HOOK_LIBS does not match hooks/*.sh"
        diff <(echo "$listed") <(echo "$actual") | head -10
        return 1
    fi

    # A library must not be registered as a hook: it has no event and would be
    # invoked with the wrong contract.
    local lib
    for lib in $(extract_array "$SCRIPT_DIR/../install.sh" CS_HOOK_LIBS); do
        if extract_array "$SCRIPT_DIR/../install.sh" CS_HOOKS | grep -qx "$lib"; then
            echo "  FAIL: $lib appears in both CS_HOOKS and CS_HOOK_LIBS"
            return 1
        fi
    done

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

# A declined status-line prompt is remembered, so `cs -update` (which re-runs
# the installer) stops asking. With the marker present the installer says why
# it skipped and how to enable, and never registers.
test_install_honors_declined_statusline_marker() {
    local fake_home="$TEST_TMPDIR/home-sl-declined"
    mkdir -p "$fake_home/.config/cs"
    touch "$fake_home/.config/cs/statusline-declined"
    local out
    out=$(HOME="$fake_home" bash "$INSTALL_SH" 2>&1 < /dev/null) || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ -n "$cmd" ]; then
        echo "  FAIL: statusLine was registered despite the declined marker (got '$cmd')"
        return 1
    fi
    assert_output_contains "$out" "declined earlier"         "install should say the status line was declined earlier" || return 1
    assert_output_contains "$out" "cs -statusline enable"         "install should still say how to enable" || return 1
}

# The marker honors XDG_CONFIG_HOME, and it wins over a foreign status line's
# replace prompt too (the branch the marker exists to silence on every update).
test_install_declined_marker_honors_xdg_and_foreign_statusline() {
    local fake_home="$TEST_TMPDIR/home-sl-declined-xdg"
    local xdg="$TEST_TMPDIR/xdg-config"
    mkdir -p "$fake_home/.claude" "$xdg/cs"
    touch "$xdg/cs/statusline-declined"
    echo '{"statusLine":{"type":"command","command":"node /x/omc-hud.mjs"}}' > "$fake_home/.claude/settings.json"
    local out
    out=$(HOME="$fake_home" XDG_CONFIG_HOME="$xdg" bash "$INSTALL_SH" 2>&1 < /dev/null) || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ "$cmd" != "node /x/omc-hud.mjs" ]; then
        echo "  FAIL: foreign statusLine was replaced (now '$cmd')"
        return 1
    fi
    assert_output_contains "$out" "declined earlier"         "install should say the status line was declined earlier" || return 1
    assert_output_not_contains "$out" "Keeping current status line"         "the declined marker should silence the replace hint" || return 1
}

# An already-registered cs-statusline is refreshed regardless of the marker:
# a stale marker must never make an update silently drop a working bar.
test_install_refreshes_registered_statusline_despite_marker() {
    local fake_home="$TEST_TMPDIR/home-sl-declined-registered"
    mkdir -p "$fake_home/.claude" "$fake_home/.config/cs"
    touch "$fake_home/.config/cs/statusline-declined"
    echo '{"statusLine":{"type":"command","command":"/old/path/cs-statusline"}}' > "$fake_home/.claude/settings.json"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    local cmd
    cmd=$(jq -r '.statusLine.command // ""' "$fake_home/.claude/settings.json")
    if [ "$cmd" != "$fake_home/.local/bin/cs-statusline" ]; then
        echo "  FAIL: registered cs-statusline was not refreshed (got '$cmd')"
        return 1
    fi
}

# disable records the opt-out; enable is the consent that clears it.
test_statusline_disable_sets_and_enable_clears_declined_marker() {
    local fake_home="$TEST_TMPDIR/home-sl-marker"
    local marker="$fake_home/.config/cs/statusline-declined"
    mkdir -p "$fake_home/.claude" "$fake_home/.local/bin"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-statusline"
    chmod +x "$fake_home/.local/bin/cs-statusline"
    echo '{}' > "$fake_home/.claude/settings.json"
    HOME="$fake_home" "$CS_BIN" -statusline disable > /dev/null 2>&1 || {
        echo "  FAIL: cs -statusline disable exited non-zero"
        return 1
    }
    if [ ! -f "$marker" ]; then
        echo "  FAIL: disable did not write the declined marker"
        return 1
    fi
    HOME="$fake_home" "$CS_BIN" -statusline enable > /dev/null 2>&1 || {
        echo "  FAIL: cs -statusline enable exited non-zero"
        return 1
    }
    if [ -f "$marker" ]; then
        echo "  FAIL: enable left the declined marker behind"
        return 1
    fi
}

test_uninstall_removes_declined_marker() {
    local fake_home="$TEST_TMPDIR/uninstall-sl-marker"
    local marker="$fake_home/.config/cs/statusline-declined"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude" "$fake_home/.config/cs"
    touch "$marker"
    echo '{}' > "$fake_home/.claude/settings.json"
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    if [ -f "$marker" ]; then
        echo "  FAIL: declined marker survived uninstall"
        return 1
    fi
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
# Install must remove a stale cs-tui.exe left by a pre-2026.8.8 install so PATH
# / sibling resolution cannot pick the wrong-platform binary.
test_install_removes_stale_opposite_platform_tui() {
    local fake_home="$TEST_TMPDIR/install-tui-clean"
    mkdir -p "$fake_home/.local/bin"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-tui.exe"   # leftover from an older install
    chmod +x "$fake_home/.local/bin/cs-tui.exe"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-tui.exe" ]; then
        echo "  FAIL: stale cs-tui.exe not removed"
        return 1
    fi
    # NB: we do not assert cs-tui was installed — bin/cs-tui is a build artifact,
    # not git-tracked, so it is absent from a fresh CI checkout. The behavior
    # under test is that the opposite-platform binary is removed regardless.
}

# Run install.sh's WEB path with the cs-tui download stubbed, so the checksum
# gate can be driven into each of its "cannot verify" states. Echoes the bin dir.
# CS_TEST_SHA_FETCH=fail   -> the .sha256 sibling 404s
# CS_TEST_SHA_TOOL=fail    -> the digest tool exists but errors, so no digest
_install_tui_with_broken_verification() {  # tag
    local sandbox="$TEST_TMPDIR/tui-verify-$1"
    local bindir="$sandbox/stub"
    mkdir -p "$bindir" "$sandbox/home"
    cp "$INSTALL_SH" "$sandbox/install.sh"

    cat > "$bindir/curl" <<STUB
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*) url="\$a" ;; esac
    prev="\$a"
done
case "\$url" in
    *.sha256) [ "\${CS_TEST_SHA_FETCH:-ok}" = "fail" ] && exit 22 ;;
    *.minisig) [ "\${CS_TEST_SIG_FETCH:-fail}" = "fail" ] && exit 22 ;;
esac
if [ -n "\$out" ]; then
    case "\$out" in
        */cs) printf 'VERSION="9999.9.9"\n' > "\$out" ;;
        *.sha256) printf 'deadbeef  x\n' > "\$out" ;;
        *)    printf 'stub-binary\n' > "\$out" ;;
    esac
fi
exit 0
STUB

    # Shadow both digest tools; whichever install.sh picks, it fails the same way.
    local t
    for t in sha256sum shasum; do
        cat > "$bindir/$t" <<STUB
#!/usr/bin/env bash
[ "\${CS_TEST_SHA_TOOL:-ok}" = "fail" ] && exit 1
printf '%s  %s\n' deadbeef "\$1"
STUB
        chmod +x "$bindir/$t"
    done
    chmod +x "$bindir/curl"

    # Reproduces the one minisign behaviour under test: a -m target that is not
    # there fails, as real minisign does ("No such file or directory", exit 2).
    cat > "$bindir/minisign" <<'STUB'
#!/usr/bin/env bash
m=""; prev=""
for a in "$@"; do
    case "$prev" in -m) m="$a" ;; esac
    prev="$a"
done
[ -f "$m" ] || exit 2
exit 0
STUB
    chmod +x "$bindir/minisign"

    PATH="$bindir:$PATH" HOME="$sandbox/home" bash "$sandbox/install.sh" \
        > "$sandbox/install.out" 2>&1
    printf '%s' "$sandbox/home/.local/bin"
}

# A gate that cannot verify must not pass. lib/20-update.sh's verify_checksum
# says so in as many words ("Fail closed: a verification gate that can't verify
# must not pass"); install.sh reimplemented the same check inline and skipped
# the whole block when the .sha256 could not be fetched, keeping the binary.
test_tui_removed_when_checksum_cannot_be_fetched() {
    local bin
    bin=$(CS_TEST_SHA_FETCH=fail _install_tui_with_broken_verification fetch)
    local f
    for f in "$bin"/cs-tui "$bin"/cs-tui.exe; do
        if [ -f "$f" ]; then
            echo "  FAIL: kept an unverified $f when the checksum could not be fetched"
            return 1
        fi
    done
}

# Same gate, other way to be unable to verify: the digest tool is there but
# produces nothing, which left the comparison unreached and the binary in place.
test_tui_removed_when_digest_cannot_be_computed() {
    local bin
    bin=$(CS_TEST_SHA_TOOL=fail _install_tui_with_broken_verification tool)
    local f
    for f in "$bin"/cs-tui "$bin"/cs-tui.exe; do
        if [ -f "$f" ]; then
            echo "  FAIL: kept an unverified $f when no digest could be computed"
            return 1
        fi
    done
}

# The checksum gate removes a binary it could not verify; the signature block
# below it then ran minisign against that removed path. minisign fails on a file
# that is not there, so the install blamed the release signature for a removal
# the checksum gate had already reported and explained. Both diagnostics claimed
# a different cause, and only one of them happened.
test_tui_signature_not_blamed_for_a_checksum_gate_removal() {
    CS_TEST_SHA_TOOL=fail CS_TEST_SIG_FETCH=ok \
        _install_tui_with_broken_verification sigblame >/dev/null
    local out
    out=$(cat "$TEST_TMPDIR/tui-verify-sigblame/install.out")
    assert_output_contains "$out" "could not be verified" \
        "the checksum gate must still say why it removed the binary" || return 1
    assert_output_not_contains "$out" "signature verification failed" \
        "must not report a signature failure for a binary already removed" || return 1
}

test_uninstall_removes_leftover_cs_tui_exe() {
    local fake_home="$TEST_TMPDIR/uninstall-tui-exe"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude"
    echo '#!/bin/sh' > "$fake_home/.local/bin/cs-tui.exe"
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"
        return 1
    }
    if [ -f "$fake_home/.local/bin/cs-tui.exe" ]; then
        echo "  FAIL: a leftover cs-tui.exe survived uninstall"
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

# --- Uninstall must remove everything install created ---

# install.sh reads the user's fpath line to choose between ~/.zsh/completions and
# the singular ~/.zsh/completion (install.sh:62-69). Uninstall hardcoded the
# plural, so _cs survived for exactly the users that detection exists to serve.
test_uninstall_removes_zsh_completion_from_detected_dir() {
    local fake_home="$TEST_TMPDIR/uninstall-zsh-singular"
    mkdir -p "$fake_home"
    printf 'fpath=(~/.zsh/completion $fpath)\n' > "$fake_home/.zshrc"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_file_exists "$fake_home/.zsh/completion/_cs" \
        "install must place _cs in the fpath-detected dir, or this test proves nothing" || return 1

    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_not_exists "$fake_home/.local/bin/cs" \
        "uninstall body must have run (confirmation accepted)" || return 1
    assert_not_exists "$fake_home/.zsh/completion/_cs" \
        "zsh completion in the fpath-detected dir must be removed" || return 1
}

test_uninstall_removes_zsh_completion_from_default_dir() {
    local fake_home="$TEST_TMPDIR/uninstall-zsh-plural"
    mkdir -p "$fake_home"
    printf 'fpath=(~/.zsh/completions $fpath)\n' > "$fake_home/.zshrc"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_file_exists "$fake_home/.zsh/completions/_cs" \
        "install must place _cs in the default dir, or this test proves nothing" || return 1

    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_not_exists "$fake_home/.zsh/completions/_cs" \
        "zsh completion in the default dir must be removed" || return 1
}

test_uninstall_removes_update_cache() {
    local fake_home="$TEST_TMPDIR/uninstall-cache"
    mkdir -p "$fake_home"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    # check_update_notify writes these on launch; the installer never creates
    # them, so the fixture seeds them the way a real run would.
    mkdir -p "$fake_home/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$fake_home/.cache/cs/update-check"
    printf '2026.99.3\tone summary\n' > "$fake_home/.cache/cs/update-notes-2026.99.3"

    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_not_exists "$fake_home/.local/bin/cs" \
        "uninstall body must have run (confirmation accepted)" || return 1
    assert_not_exists "$fake_home/.cache/cs/update-check" \
        "update-check stamp must not survive uninstall" || return 1
    assert_not_exists "$fake_home/.cache/cs/update-notes-2026.99.3" \
        "notes cache must not survive uninstall" || return 1
    assert_not_exists "$fake_home/.cache/cs" \
        "the update cache directory itself must go" || return 1
}


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
run_test test_tui_removed_when_checksum_cannot_be_fetched
run_test test_tui_removed_when_digest_cannot_be_computed
run_test test_tui_signature_not_blamed_for_a_checksum_gate_removal
run_test test_uninstall_removes_leftover_cs_tui_exe
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

test_filechanged_registration_carries_async_rewake() {
    # The idle mail wake delivers by exiting 2. Without asyncRewake the hook
    # still runs and its output is discarded — a five-second toast the model
    # never sees — so the wake would look wired up and do nothing.
    local inst="$SCRIPT_DIR/../install.sh" reg
    reg=$(grep -E '^ +_merge_cs_hook FileChanged ' "$inst") \
        || { echo "  FAIL: FileChanged is not registered"; return 1; }
    assert_output_contains "$reg" "narrative-reminder.sh" \
        "FileChanged routes to the hook that owns the mail wake" || return 1
    # 6th positional is the rewake flag; a matcher here would break the event
    # (its matcher is tested against the changed file's basename).
    assert_output_contains "$reg" '"" "" true' \
        "registered with no matcher and the rewake flag set" || return 1
    grep -q 'asyncRewake: true' "$inst" \
        || { echo "  FAIL: _merge_cs_hook cannot emit asyncRewake"; return 1; }
    grep -q 'rewakeMessage' "$inst" \
        || { echo "  FAIL: no rewakeMessage prefix; the payload would read as a Stop hook error"; return 1; }
}

# One FileChanged entry now serves two wake kinds — cross-session mail and the
# /clear rotation kick — and the labels are static in settings.json, so they
# cannot name one of them. A rotation auto-start announced as "New cs mail" is
# the wrong story about what just started the turn, and this session's own rule
# is that an unexplained label in the output is the finding, not noise.
test_rewake_labels_do_not_claim_the_wake_is_mail() {
    local inst="$SCRIPT_DIR/../install.sh"
    if grep -qE 'rewake(Message|Summary): "[^"]*[Mm]ail' "$inst"; then
        echo "  FAIL: the rewake labels must not say mail; FileChanged also carries the rotation kick"
        return 1
    fi
    grep -q 'rewakeSummary' "$inst" \
        || { echo "  FAIL: no rewakeSummary; the wake would render unlabelled"; return 1; }
    # The greps above read install.sh's SOURCE, which is the mechanism. Assert
    # the property too — what a real install actually writes into settings.json
    # — or the test still passes when the jq emitting the labels breaks and no
    # label reaches the file at all.
    local fake_home="$TEST_TMPDIR/home-rewake"
    mkdir -p "$fake_home"
    HOME="$fake_home" bash "$INSTALL_SH" >/dev/null 2>&1 \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    local summary
    summary=$(jq -r '.hooks.FileChanged[0].hooks[0].rewakeSummary // ""' \
        "$fake_home/.claude/settings.json")
    [ -n "$summary" ] || { echo "  FAIL: no rewakeSummary reached settings.json"; return 1; }
    case "$summary" in
        *[Mm]ail*) echo "  FAIL: the installed label claims mail: $summary"; return 1 ;;
    esac
}

run_test test_install_survives_an_unwritable_declined_marker_dir
run_test test_install_previews_the_status_line_before_asking
run_test test_declining_says_permanence_on_its_own_line
run_test test_enter_declines_the_same_as_an_explicit_n
run_test test_statusline_disable_survives_an_unwritable_marker_dir
run_test test_marker_tests_do_not_touch_a_live_xdg_config_home
run_test test_filechanged_registration_carries_async_rewake
run_test test_rewake_labels_do_not_claim_the_wake_is_mail
run_test test_uninstall_preserves_foreign_statusline
run_test test_uninstall_removes_zsh_completion_from_detected_dir
run_test test_uninstall_removes_zsh_completion_from_default_dir
run_test test_uninstall_removes_update_cache
run_test test_install_recovers_from_invalid_settings_json
run_test test_local_install_prefers_a_freshly_built_picker
run_test test_local_install_uses_bin_picker_when_nothing_was_built
run_test test_hook_registration_doc_matches_install
run_test test_install_honors_declined_statusline_marker
run_test test_install_declined_marker_honors_xdg_and_foreign_statusline
run_test test_install_refreshes_registered_statusline_despite_marker
run_test test_statusline_disable_sets_and_enable_clears_declined_marker
run_test test_uninstall_removes_declined_marker

# The per-clone merge driver only exists after a cs launch, so a session pulled
# onto a fresh machine before the first `cs <name>` text-merges MEMORY.md — the
# README's own caveat. A global driver closes that window for every clone.
test_install_registers_the_merge_driver_globally() {
    local fake_home="$TEST_TMPDIR/home-merge"
    mkdir -p "$fake_home/.claude"
    HOME="$fake_home" bash "$INSTALL_SH" >/dev/null 2>&1 </dev/null || true
    local driver
    driver=$(HOME="$fake_home" git config --global --get merge.ours.driver 2>/dev/null)
    [ "$driver" = "true" ] || { echo "merge.ours.driver not set globally (got: '$driver')"; return 1; }
}

run_test test_install_registers_the_merge_driver_globally

report_results
