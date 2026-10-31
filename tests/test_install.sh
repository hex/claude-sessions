#!/usr/bin/env bash
# ABOUTME: Tests for install.sh end-to-end behavior
# ABOUTME: Isolates HOME to a tmpdir so install side-effects don't leak

# Each test runs a whole install, so this suite takes about twice the time its
# length suggests (562 s for 3,824 lines on the macOS runner); run_all.sh
# weighs it accordingly when it splits shards and orders its queue.
# run_all-weight: 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

INSTALL_SH="$SCRIPT_DIR/../install.sh"
# The installer's rotate/wrap keys question, as an expect -re pattern.
_ROTATE_WRAP_ASK_RE='Ctrl\+X R.*\[y/n\]'

# Override teardown: also reset HOME if a test set it.
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR XDG_CONFIG_HOME
}

# Content a past cs deployed (mods/cs-rotate/hooks/hooks.json as it shipped),
# so a file holding it is cs's whatever its name: a stand-in for any file an
# install that kept no record left behind. install and uninstall remove only
# files cs wrote, decided by content, so a fixture standing for a file cs left
# behind holds this.
_cs_shipped_content() {
    echo '{"modules":["./register.tsx"]}'
}

# The declined marker is a preference memo, and a memo that cannot be written
# must never take the install down with it. install.sh runs under errexit and
# the marker write ends its && list, so a failing touch aborts before
# settings.json is written: hooks land on disk unregistered, the version stamp
# is missing, and the run ends with no completion message. An unwritable
# ~/.config/cs is enough to trigger it — an earlier root-run install leaves
# exactly that.
test_install_survives_an_unwritable_declined_marker_dir() {
    require_tool expect || return $?
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
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
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
    require_tool expect || return $?
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
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
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
    require_tool expect || return $?
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
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
    eof
}
EXPECT
    expect -f "$exp" >/dev/null 2>&1 || true
    # Read the transcript as the screen shows it: the band layout colours
    # every cell on its own, so a word's letters sit between colour escapes.
    local esc; esc=$(printf '\033')
    sed "s/${esc}\[[0-9;:]*m//g" "$out" > "$out.plain"
    out="$out.plain"
    # A sample renders, and it renders BEFORE the question.
    local sample_line prompt_line
    sample_line=$(grep -n 'ctx' "$out" | head -1 | cut -d: -f1)
    prompt_line=$(grep -n 'as the Claude Code status line' "$out" | head -1 | cut -d: -f1)
    [ -n "$sample_line" ] || { echo "  FAIL: no status line sample rendered"; return 1; }
    [ -n "$prompt_line" ] || { echo "  FAIL: no prompt"; return 1; }
    grep -n 'wk' "$out" >/dev/null 2>&1 \
        || { echo "  FAIL: no rate-limit capsule in the sample"; return 1; }
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
    require_tool expect || return $?
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
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
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

test_install_asks_caps_for_a_chaining_statusline() {
    require_tool expect || return $?
    local state home exp caps rc output
    for state in unrelated chains; do
        home="$TEST_TMPDIR/home-$state"
        exp="$TEST_TMPDIR/$state.exp"
        mkdir -p "$home/.claude"
        case "$state" in
            unrelated) printf '%s\n' '#!/bin/sh' 'printf bar' > "$home/bridge.sh" ;;
            chains) printf '%s\n' '#!/bin/sh' 'exec cs-statusline' > "$home/bridge.sh" ;;
        esac
        printf '%s\n' '{"statusLine":{"command":"~/bridge.sh --example"}}' \
            > "$home/.claude/settings.json"
        cat > "$exp" <<EXPECT
set timeout 120
log_file -noappend $TEST_TMPDIR/$state.out
spawn env -u CLAUDE_CONFIG_DIR HOME=$home XDG_CONFIG_HOME=$home/config bash $INSTALL_SH
expect {
    -re {status line.*\[y/N\]} { send "n"; exp_continue }
    -re {rounded shapes.*\[y/n\]} { send "y"; exp_continue }
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
    timeout { exit 124 }
    eof
}
catch wait result
exit [lindex \$result 3]
EXPECT
        rc=0
        expect -f "$exp" > /dev/null 2>&1 || rc=$?
        assert_eq 0 "$rc" "$state bridge install completes" || return 1
        output=$(sed $'s/\033\\[[0-9;]*m//g' "$TEST_TMPDIR/$state.out" | tr -d '\r')
        # shellcheck disable=SC2088  # the literal path is the value under test
        assert_eq '~/bridge.sh --example' \
            "$(jq -r '.statusLine.command' "$home/.claude/settings.json")" \
            "$state bridge registration stays unchanged" || return 1
        caps="$home/config/cs/statusline-caps"
        if [ "$state" = chains ]; then
            assert_eq "" "$(printf '%s\n' "$output" | grep -F 'Replace current status line' || true)" \
                "a chaining bridge must not be offered replacement" || return 1
            assert_eq '   · Keeping current status line: ~/bridge.sh --example runs cs-statusline.' \
                "$(printf '%s\n' "$output" | grep -F 'Keeping current status line')" \
                "the installer explains why it keeps the bridge" || return 1
            assert_output_not_contains "$output" "To switch to cs-statusline" \
                "a chaining bridge needs no switch hint" || return 1
            assert_not_exists "$home/config/cs/statusline-declined" \
                "keeping a chaining bridge must not record a decline" || return 1
            assert_eq "" "$(printf '%s\n' "$output" | grep -F "     You won't be asked again." || true)" \
                "keeping a chaining bridge needs no permanence hint" || return 1
            assert_eq '   Do the ends of that capsule render as rounded shapes (not boxes)? [y/n] y' \
                "$(printf '%s\n' "$output" | grep -F 'Do the ends of that capsule')" \
                "the retained bridge still gets the caps question" || return 1
            local answer=""
            [ ! -f "$caps" ] || answer=$(cat "$caps")
            assert_eq on "$answer" "a retained chaining bridge receives the caps answer" || return 1
            local pass
            for pass in repeat marked; do
                if [ "$pass" = marked ]; then
                    touch "$home/config/cs/statusline-declined"
                fi
                rc=0
                env -u CLAUDE_CONFIG_DIR HOME="$home" XDG_CONFIG_HOME="$home/config" \
                    bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/$pass.out" 2>&1 || rc=$?
                assert_eq 0 "$rc" "$pass chaining bridge install completes" || return 1
                output=$(sed $'s/\033\\[[0-9;]*m//g' "$TEST_TMPDIR/$pass.out" | tr -d '\r')
                assert_eq '   · Keeping current status line: ~/bridge.sh --example runs cs-statusline.' \
                    "$(printf '%s\n' "$output" | grep -F 'Keeping current status line' || true)" \
                    "$pass install explains why it keeps the bridge" || return 1
                assert_eq "" "$(printf '%s\n' "$output" | grep -F 'Status line not registered (declined earlier)' || true)" \
                    "$pass install must not call a chaining bridge declined" || return 1
                assert_eq "" "$(printf '%s\n' "$output" | grep -F "     You won't be asked again." || true)" \
                    "$pass install needs no permanence hint" || return 1
                if [ "$pass" = repeat ]; then
                    assert_not_exists "$home/config/cs/statusline-declined" \
                        "a non-interactive chaining install must not record a decline" || return 1
                fi
            done
        else
            assert_eq '   Replace current status line (~/bridge.sh --example) with cs-statusline? [y/N] n' \
                "$(printf '%s\n' "$output" | grep 'Replace current status line')" \
                "an unrelated bridge still gets the replacement question" || return 1
            [ ! -e "$caps" ] || { echo "  FAIL: an unrelated bridge must not get a caps answer"; return 1; }
        fi
    done
}

# `cs -statusline caps on|off` records this machine's answer to the rounded-
# caps question, the file bin/cs-statusline reads before drawing a cap.
test_statusline_caps_on_off_writes_the_answer_file() {
    local fake_home="$TEST_TMPDIR/home-caps"
    mkdir -p "$fake_home/.claude"
    HOME="$fake_home" bash "$SCRIPT_DIR/../bin/cs" -statusline caps on >/dev/null 2>&1 || return 1
    assert_file_contains "$fake_home/.config/cs/statusline-caps" "^on$" "caps on writes on" || return 1
    HOME="$fake_home" bash "$SCRIPT_DIR/../bin/cs" -statusline caps off >/dev/null 2>&1 || return 1
    assert_file_contains "$fake_home/.config/cs/statusline-caps" "^off$" "caps off writes off" || return 1
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

# A path as a BRE that matches only itself.
_bre_literal() {  # text
    printf '%s' "$1" | sed 's/[][\.*^$]/\\&/g'
}

# The settings.json backups beside the file, one name per line.
_settings_backups() {  # settings file
    local f
    for f in "$1".cs-bak*; do
        [ -e "$f" ] && basename "$f"
    done
    return 0
}

# A settings.json jq cannot parse holds the user's permissions, env, MCP
# servers and other tools' hooks; replacing it with {} loses them all. The
# install stops before it places anything, with one error naming the file
# and jq's reason, and leaves the file byte for byte as it was, with no
# backup written and nothing else under HOME changed. jq's reason is matched
# up to its "parse error" prefix: the words after it differ between jq
# releases.
test_install_refuses_invalid_settings_json() {
    local fake_home="$TEST_TMPDIR/home-badjson" f rc=0 out before
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    printf '{"permissions":\n' > "$f"
    cp "$f" "$TEST_TMPDIR/badjson.orig"
    before=$(_tree_listing "$fake_home")
    HOME="$fake_home" bash "$INSTALL_SH" > "$TEST_TMPDIR/badjson.out" 2>&1 < /dev/null || rc=$?
    out=$(cat "$TEST_TMPDIR/badjson.out")
    assert_eq "1" "$rc" "install must stop on an unparseable settings.json" || return 1
    assert_output_contains "$out" "^Error: $(_bre_literal "$f") is not valid JSON; left it unchanged and wrote no $(_bre_literal "$f")\.cs-bak\.<stamp> backup: parse error.*; nothing was installed$" \
        "the error names the file and jq's reason, and says nothing was installed" || { echo "$out"; return 1; }
    cmp -s "$TEST_TMPDIR/badjson.orig" "$f" \
        || { echo "  FAIL: settings.json changed although it was refused"; return 1; }
    assert_eq "" "$(_settings_backups "$f")" "a refused file gets no backup" || return 1
    _assert_tree_unchanged "$before" "$fake_home" "install places nothing before it refuses" || return 1
}

# Claude Code reads settings.json as one JSON object. A file holding valid
# JSON of another type (a list, a string, a number) is refused the same way,
# before anything is placed, rather than failing midway on a key read.
test_install_refuses_settings_json_that_is_not_an_object() {
    local fake_home="$TEST_TMPDIR/home-listjson" f rc=0 out before
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    printf '[{"permissions":{}}]\n' > "$f"
    cp "$f" "$TEST_TMPDIR/listjson.orig"
    before=$(_tree_listing "$fake_home")
    HOME="$fake_home" bash "$INSTALL_SH" > "$TEST_TMPDIR/listjson.out" 2>&1 < /dev/null || rc=$?
    out=$(cat "$TEST_TMPDIR/listjson.out")
    assert_eq "1" "$rc" "install must stop on a settings.json that is not an object" || return 1
    assert_output_contains "$out" "^Error: $(_bre_literal "$f") holds a JSON array, not an object; left it unchanged; nothing was installed$" \
        "the error names the file and what it holds, and says nothing was installed" || { echo "$out"; return 1; }
    cmp -s "$TEST_TMPDIR/listjson.orig" "$f" \
        || { echo "  FAIL: settings.json changed although it was refused"; return 1; }
    assert_eq "" "$(_settings_backups "$f")" "a refused file gets no backup" || return 1
    _assert_tree_unchanged "$before" "$fake_home" "install places nothing before it refuses" || return 1
    printf '{}\n{}\n' > "$f"
    rc=0
    HOME="$fake_home" bash "$INSTALL_SH" > "$TEST_TMPDIR/listjson.out" 2>&1 < /dev/null || rc=$?
    out=$(cat "$TEST_TMPDIR/listjson.out")
    assert_eq "1" "$rc" "install must stop on a settings.json holding two objects" || return 1
    assert_output_contains "$out" "^Error: $(_bre_literal "$f") holds more than one JSON value, not one object; left it unchanged; nothing was installed$" \
        "two values are named as such, on one line" || { echo "$out"; return 1; }
}

# A settings.json that is not a regular file, here a FIFO, is never read:
# reading one waits for a writer that never comes. The install refuses it as
# it refuses one jq cannot parse, before it places anything, and leaves it as
# it was.
test_install_refuses_a_settings_json_that_is_not_a_regular_file() {
    local fake_home="$TEST_TMPDIR/home-fifo-settings" f rc=0 out before
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    mkfifo "$f"
    before=$(_tree_listing "$fake_home")
    _run_bounded 60 env HOME="$fake_home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/fifo-settings.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/fifo-settings.out")
    assert_eq "1" "$rc" "install exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    assert_output_contains "$out" "^Error: $(_bre_literal "$f") is not a regular file, so cs did not read it; left it unchanged; nothing was installed$" \
        "the error names the file and says nothing was installed" || { echo "$out"; return 1; }
    [ -p "$f" ] || { echo "  FAIL: the fifo is not left as it was"; return 1; }
    _assert_tree_unchanged "$before" "$fake_home" "install places nothing before it refuses" || return 1
}

# A zero-byte settings.json holds nothing to lose: it is created as cs's
# hooks, like a missing one.
test_install_fills_an_empty_settings_json() {
    local fake_home="$TEST_TMPDIR/home-emptyjson" f rc=0
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    : > "$f"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "an empty settings.json must not stop the install" || return 1
    jq -e '.hooks.SessionStart' "$f" >/dev/null 2>&1 \
        || { echo "  FAIL: hooks were not registered in the empty settings.json"; return 1; }
}

# Every write that changes settings.json leaves the file as it was beside it
# under a UTC-stamped name, and a run that changes nothing writes none.
test_install_backs_up_settings_json_before_changing_it() {
    local fake_home="$TEST_TMPDIR/home-bak" f backups
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    printf '{"permissions":{"allow":["Bash(ls)"]},"env":{"ALICE":"1"}}\n' > "$f"
    cp "$f" "$TEST_TMPDIR/bak.orig"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    backups=$(_settings_backups "$f")
    assert_output_contains "$backups" '^settings\.json\.cs-bak\.[0-9]\{8\}T[0-9]\{6\}Z$' \
        "a stamped backup sits beside settings.json" || return 1
    assert_eq "1" "$(printf '%s\n' "$backups" | grep -c .)" "one change, one backup" || return 1
    cmp -s "$TEST_TMPDIR/bak.orig" "$fake_home/.claude/$backups" \
        || { echo "  FAIL: the backup is not the file as it was"; return 1; }
    jq -e '.env.ALICE == "1" and .permissions.allow == ["Bash(ls)"]' "$f" >/dev/null 2>&1 \
        || { echo "  FAIL: the user's own settings were not kept"; return 1; }
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null \
        || { echo "  FAIL: the second install.sh exited non-zero"; return 1; }
    assert_eq "$backups" "$(_settings_backups "$f")" "a run that changes nothing writes no backup" || return 1
}

# Backups beside settings.json are kept to the five newest: a changing write
# that would leave a sixth removes the oldest. Only cs's stamped names count;
# a file that merely starts with the prefix is the user's and stays.
test_install_keeps_the_five_newest_settings_backups() {
    local fake_home="$TEST_TMPDIR/home-prune" f d stamp
    f="$fake_home/.claude/settings.json"
    d="$fake_home/.claude"
    mkdir -p "$d"
    printf '{"env":{"ALICE":"1"}}\n' > "$f"
    for stamp in 20200101T000000Z 20200101T000000Z.1 20200101T000000Z.2 20200102T000000Z 20200103T000000Z 20200104T000000Z; do
        printf 'old %s\n' "$stamp" > "$f.cs-bak.$stamp"
    done
    printf 'mine\n' > "$f.cs-bak.notes"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    local backups fresh
    backups=$(_settings_backups "$f")
    fresh=$(printf '%s\n' "$backups" | grep -v '^settings\.json\.cs-bak\.2020' | grep -vxF 'settings.json.cs-bak.notes')
    assert_output_contains "$fresh" '^settings\.json\.cs-bak\.[0-9]\{8\}T[0-9]\{6\}Z$' \
        "the backup this install wrote is kept" || return 1
    assert_eq "settings.json.cs-bak.20200101T000000Z.2
settings.json.cs-bak.20200102T000000Z
settings.json.cs-bak.20200103T000000Z
settings.json.cs-bak.20200104T000000Z
$fresh
settings.json.cs-bak.notes" "$backups" \
        "the four newest planted backups, the fresh one and the user's own file remain" || return 1
}

# Another cs writer (a second install, cs -statusline, the cs-update mod
# running install.sh inside a live Claude Code) can rewrite settings.json
# while the installer is working on it. A one-shot slow jq on the merge
# widens the installer's window, and from inside it starts a writer that
# takes the settings lock beside the file (cs's own _cs_lock) and adds a key. Read and write
# taken under that lock, both changes survive; read early and written late,
# the writer's key is lost.
test_install_keeps_a_concurrent_settings_change() {
    local fake_home="$TEST_TMPDIR/home-race" f real stub="$TEST_TMPDIR/race-bin"
    f="$fake_home/.claude/settings.json"
    real=$(command -v jq)
    mkdir -p "$fake_home/.claude" "$stub"
    printf '{"env":{"ALICE":"1"}}\n' > "$f"
    cat > "$TEST_TMPDIR/race-writer.sh" <<EOF
#!/bin/bash
sleep 0.5
. "$SCRIPT_DIR/../hooks/cs-shared.sh"
_cs_lock "$f.mutex.lock" || exit 1
"$real" '.env.BOB = "1"' "$f" > "$f.writer" && mv "$f.writer" "$f"
_cs_unlock "$f.mutex.lock"
: > "$TEST_TMPDIR/race-writer.done"
EOF
    cat > "$stub/jq" <<EOF
#!/bin/bash
case " \$* " in
    *" --arg event "*)
        if mkdir "$TEST_TMPDIR/race-fired" 2>/dev/null; then
            bash "$TEST_TMPDIR/race-writer.sh" < /dev/null > /dev/null 2>&1 &
            sleep 2
        fi
        ;;
esac
exec "$real" "\$@"
EOF
    chmod +x "$stub/jq"
    HOME="$fake_home" PATH="$stub:$PATH" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    # The writer runs detached and may still be at work when install.sh exits.
    wait_until test -e "$TEST_TMPDIR/race-writer.done"
    assert_exists "$TEST_TMPDIR/race-fired" "the slow merge ran" || return 1
    assert_file_exists "$TEST_TMPDIR/race-writer.done" "the concurrent writer finished" || return 1
    jq -e '.env.BOB == "1"' "$f" >/dev/null 2>&1 \
        || { echo "  FAIL: the concurrent writer's change was lost"; return 1; }
    jq -e '.env.ALICE == "1" and (.hooks.SessionStart | length > 0)' "$f" >/dev/null 2>&1 \
        || { echo "  FAIL: the installer's change or the user's key was lost"; return 1; }
    assert_not_exists "$f.lock" "the settings lock is released" || return 1
}

# cs -uninstall reads neither settings.json nor keybindings.json when it is
# not a regular file (here a FIFO, and a link to one): it names each, leaves
# it as it was, and finishes, as it does for a file jq cannot parse.
test_uninstall_leaves_settings_and_keybindings_that_are_not_regular_files_unread() {
    local fake_home="$TEST_TMPDIR/home-fifo-un" f kb rc=0 out
    f="$fake_home/.claude/settings.json"
    kb="$fake_home/.claude/keybindings.json"
    mkdir -p "$fake_home/.claude" "$fake_home/fifos"
    mkfifo "$f" "$fake_home/fifos/keys"
    ln -s "$fake_home/fifos/keys" "$kb"
    printf 'y\n' | _run_bounded 60 env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$fake_home" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/fifo-un.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/fifo-un.out")
    assert_eq "0" "$rc" "uninstall exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    assert_output_contains "$out" "^$(_bre_literal "$f") is not a regular file, so cs did not read it; left it unchanged$" \
        "the settings.json fifo is named" || { echo "$out"; return 1; }
    assert_output_contains "$out" "^Left $(_bre_literal "$kb") as it is: not JSON with a \"bindings\" array$" \
        "the keybindings.json link is named" || { echo "$out"; return 1; }
    [ -p "$f" ] || { echo "  FAIL: the settings.json fifo is not left as it was"; return 1; }
    [ -L "$kb" ] && [ -p "$fake_home/fifos/keys" ] || { echo "  FAIL: the keybindings.json link and its fifo are not left as they were"; return 1; }
}

# cs -uninstall has already removed the binaries when it reaches the settings
# clean-up, so an unparseable settings.json is left byte for byte as it was
# with a warning naming the file and jq's reason, and the uninstall finishes.
test_uninstall_leaves_invalid_settings_json_untouched() {
    local fake_home="$TEST_TMPDIR/home-unbad" f rc=0 out
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    printf '{"permissions":\n' > "$f"
    cp "$f" "$TEST_TMPDIR/unbad.orig"
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/unbad.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/unbad.out")
    assert_eq "0" "$rc" "the uninstall finishes" || return 1
    assert_output_contains "$out" "^$(_bre_literal "$f") is not valid JSON; left it unchanged and wrote no $(_bre_literal "$f")\.cs-bak\.<stamp> backup: parse error" \
        "the warning names the file and jq's reason" || return 1
    cmp -s "$TEST_TMPDIR/unbad.orig" "$f" \
        || { echo "  FAIL: settings.json changed although it was refused"; return 1; }
    assert_eq "" "$(_settings_backups "$f")" "a refused file gets no backup" || return 1
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
# Helper: a checkout at $1 that a local install runs from, holding no picker.
# Everything the installer reads is borrowed from this checkout; only the
# picker sources a test adds are its own, so the test says nothing about the
# rest of the tree.
make_picker_checkout() {  # repo
    local repo="$1" real="$SCRIPT_DIR/.." e
    mkdir -p "$repo/bin"
    for e in hooks commands skills mods completions docs lib README.md CHANGELOG.md LICENSE build.sh; do
        [ -e "$real/$e" ] && ln -s "$(cd "$real" && pwd)/$e" "$repo/$e"
    done
    cp "$real/install.sh" "$repo/install.sh"
    cp "$real/bin/cs" "$real/bin/cs-secrets" "$real/bin/cs-statusline" \
       "$real/bin/cs-subagent-statusline" "$repo/bin/" 2>/dev/null || true
}

test_local_install_prefers_a_freshly_built_picker() {
    local fake_home="$TEST_TMPDIR/home" repo="$TEST_TMPDIR/repo"
    make_picker_checkout "$repo"
    mkdir -p "$fake_home" "$repo/tui/target/release"
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
    # cs -doctor holds the picker to the checkout named here, from any folder.
    assert_eq "checkout $(cd "$repo" && pwd)" "$(cat "$fake_home/.claude/hooks/cs/.tui-origin" 2>/dev/null)" \
        "the install records the checkout the picker came from" || return 1
}

# The reverse: nothing built, so bin/cs-tui is all there is. A release tarball
# ships that and no tui/target at all.
test_local_install_uses_bin_picker_when_nothing_was_built() {
    local fake_home="$TEST_TMPDIR/home2" repo="$TEST_TMPDIR/my repo2"
    make_picker_checkout "$repo"
    mkdir -p "$fake_home"
    printf 'ONLY PICKER' > "$repo/bin/cs-tui"
    chmod +x "$repo/bin/cs-tui"

    HOME="$fake_home" bash "$repo/install.sh" > /dev/null 2>&1 || true

    assert_eq "ONLY PICKER" "$(cat "$fake_home/.local/bin/cs-tui" 2>/dev/null)" \
        "with no build present the shipped picker must still install" || return 1
    assert_eq "checkout $(cd "$repo" && pwd)" "$(cat "$fake_home/.claude/hooks/cs/.tui-origin" 2>/dev/null)" \
        "the record holds a checkout path with a space whole" || return 1
}

# A local install keeps a link at ~/.local/bin/cs-tui to content cs did not
# write, so the picker is still the user's own and the record of where the
# installed picker came from stays as it was.
test_local_install_keeps_the_origin_record_of_a_linked_picker() {
    local fake_home="$TEST_TMPDIR/home3" repo="$TEST_TMPDIR/repo3" out
    make_picker_checkout "$repo"
    printf 'CHECKOUT PICKER' > "$repo/bin/cs-tui"
    chmod +x "$repo/bin/cs-tui"
    mkdir -p "$fake_home/.local/bin" "$fake_home/.claude/hooks/cs"
    printf 'MY PICKER' > "$TEST_TMPDIR/my-picker"
    ln -s "$TEST_TMPDIR/my-picker" "$fake_home/.local/bin/cs-tui"
    printf 'release\n' > "$fake_home/.claude/hooks/cs/.tui-origin"

    out=$(HOME="$fake_home" bash "$repo/install.sh" 2>&1 < /dev/null) || true

    assert_eq "$TEST_TMPDIR/my-picker" "$(readlink "$fake_home/.local/bin/cs-tui")" \
        "the user's link stays in place" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$fake_home/.local/bin/cs-tui")" "the kept link is named" || return 1
    assert_eq "release" "$(cat "$fake_home/.claude/hooks/cs/.tui-origin")" \
        "the record of the kept picker stays" || return 1
}

# hooks/cs-shared.sh is a build artifact: build.sh writes it from lib/02-shared.sh
# so the hooks and cs run ONE copy of the actor and narrative-budget code. The
# committed file must be exactly what the build writes, or the hooks ship code
# the tests never ran (the same drift CI's build-sync job catches for bin/cs).
# Copies into $1 what build.sh reads: lib/, build.sh, install.sh.in and the
# payload files install.sh carries the sha256 of, without the three files
# build.sh writes (bin/cs, hooks/cs-shared.sh, install.sh), so a build there
# that fails to write one leaves it missing rather than a copy of the real one.
_copy_build_inputs() {  # dir
    local repo="$1" real="$SCRIPT_DIR/.." d
    mkdir -p "$repo/bin"
    cp -R "$real/lib" "$repo/lib"
    cp "$real/build.sh" "$real/install.sh.in" "$repo/"
    for d in hooks commands skills mods completions; do
        cp -R "$real/$d" "$repo/$d"
    done
    cp -p "$real/bin/cs-secrets" "$real/bin/cs-statusline" "$real/bin/cs-subagent-statusline" "$repo/bin/"
    rm -f "$repo/hooks/cs-shared.sh"
}

test_build_generates_the_shared_hook_fragment() {
    local repo="$TEST_TMPDIR/build-repo" real="$SCRIPT_DIR/.."
    _copy_build_inputs "$repo"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    assert_file_exists "$repo/hooks/cs-shared.sh" "build.sh writes hooks/cs-shared.sh" || return 1
    if ! diff -u "$real/hooks/cs-shared.sh" "$repo/hooks/cs-shared.sh" > "$TEST_TMPDIR/shared.diff" 2>&1; then
        echo "  FAIL: committed hooks/cs-shared.sh is not what build.sh generates (run ./build.sh)"
        head -20 "$TEST_TMPDIR/shared.diff"
        return 1
    fi
}

# install.sh is a build artifact too: build.sh splices lib/01-manifests.sh (the
# deploy manifests and the settings-strip filter, the code install.sh shares
# with bin/cs) into install.sh.in. A web install runs install.sh from a curl
# pipe and can source nothing, so the sharing happens at build time, and the
# committed install.sh must be what the build writes.
test_build_generates_install_sh_from_its_template() {
    local repo="$TEST_TMPDIR/build-repo2" real="$SCRIPT_DIR/.."
    _copy_build_inputs "$repo"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    assert_file_exists "$repo/install.sh" "build.sh writes install.sh" || return 1
    [ -x "$repo/install.sh" ] || { echo "  FAIL: the generated install.sh is not executable"; return 1; }
    if ! diff -u "$real/install.sh" "$repo/install.sh" > "$TEST_TMPDIR/install.diff" 2>&1; then
        echo "  FAIL: committed install.sh is not what build.sh generates (run ./build.sh)"
        head -20 "$TEST_TMPDIR/install.diff"
        return 1
    fi
}

# A template without exactly one splice marker would build an install.sh with
# no manifests at all, and `bash -n` passes that; set -u would fail it at the
# user's terminal instead.
test_build_refuses_a_template_without_the_marker() {
    local repo="$TEST_TMPDIR/build-repo3" real="$SCRIPT_DIR/.."
    mkdir -p "$repo/bin" "$repo/hooks"
    cp -R "$real/lib" "$repo/lib"
    cp "$real/build.sh" "$repo/"
    cp -p "$real/bin/cs-statusline" "$repo/bin/"
    grep -v '^# @@CS_MANIFESTS@@$' "$real/install.sh.in" > "$repo/install.sh.in"
    local out
    if out=$(cd "$repo" && bash build.sh 2>&1); then
        echo "  FAIL: build.sh accepted a template with no splice marker"; return 1
    fi
    assert_output_contains "$out" "CS_MANIFESTS" "the error names the marker" || return 1
    assert_not_exists "$repo/install.sh" "no install.sh is written from a bad template" || return 1
}

# awk reads a missing splice source as an empty file and exits 0, and an
# installer with no manifests passes bash -n, so the build has to check for the
# source itself or publish an installer that deploys nothing.
test_build_refuses_a_missing_manifests_source() {
    local repo="$TEST_TMPDIR/build-repo4" real="$SCRIPT_DIR/.."
    mkdir -p "$repo/bin" "$repo/hooks"
    cp -R "$real/lib" "$repo/lib"
    cp "$real/build.sh" "$real/install.sh.in" "$repo/"
    cp -p "$real/bin/cs-statusline" "$repo/bin/"
    rm "$repo/lib/01-manifests.sh"
    local out
    if out=$(cd "$repo" && bash build.sh 2>&1); then
        echo "  FAIL: build.sh built an installer with no manifests source"; return 1
    fi
    assert_output_contains "$out" "01-manifests.sh" "the error names the missing source" || return 1
    assert_not_exists "$repo/install.sh" "no install.sh is written without its manifests" || return 1
}

# The built files are read by whoever runs them: a shared checkout's other
# users, and every hook the deployed copy is sourced from. mktemp makes a
# private file, so the mode is set on purpose rather than inherited.
test_build_outputs_are_world_readable() {
    local repo="$TEST_TMPDIR/build-repo5"
    _copy_build_inputs "$repo"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    local f mode
    for f in bin/cs hooks/cs-shared.sh install.sh; do
        # GNU stat first: its -c is invalid on BSD stat (no output, exit 1), while
        # BSD's -f means "filesystem" to GNU stat and prints a block before failing.
        mode=$(stat -c '%a' "$repo/$f" 2>/dev/null || stat -f '%Lp' "$repo/$f")
        assert_eq "755" "$mode" "$f is built 0755" || return 1
    done
}

# Prints the sha256 of file $1.
_sha256_of() {  # file
    shasum -a 256 < "$1" | awk '{print $1}'
}

# The release build adds the sha256 of every file the installer deploys
# under ~/.claude to CS_KNOWN_SHA256 and builds the table into bin/cs and
# install.sh; the table stays sorted without repeats, a second run changes
# nothing, and a plain build adds nothing.
test_release_build_adds_its_payload_to_the_known_table_once() {
    local repo="$TEST_TMPDIR/hashes-repo" snap="$TEST_TMPDIR/hashes-snap" rel digest f
    _copy_build_inputs "$repo"
    printf '\n' >> "$repo/commands/wrap.md"
    digest=$(_sha256_of "$repo/commands/wrap.md")
    assert_eq "0" "$(grep -c "^    $digest$" "$repo/lib/01-manifests.sh")" "the changed wrap.md starts out unknown" || return 1
    (cd "$repo" && bash build.sh --add-release-hashes > /dev/null) || { echo "  FAIL: the release build failed"; return 1; }
    for f in lib/01-manifests.sh bin/cs install.sh; do
        assert_eq "1" "$(grep -c "^    $digest$" "$repo/$f")" "$f lists the changed wrap.md once" || return 1
    done
    ( . "$repo/lib/01-manifests.sh"; _cs_payload_files ) | grep -v '^bin/' > "$TEST_TMPDIR/hashes-files"
    while IFS= read -r rel; do
        digest=$(_sha256_of "$repo/$rel")
        assert_eq "1" "$(grep -c "^    $digest$" "$repo/lib/01-manifests.sh")" "the table lists $rel" || return 1
    done < "$TEST_TMPDIR/hashes-files"
    extract_array "$repo/lib/01-manifests.sh" CS_KNOWN_SHA256 | LC_ALL=C sort -c -u \
        || { echo "  FAIL: CS_KNOWN_SHA256 is not sorted without repeats"; return 1; }
    mkdir -p "$snap"
    for f in lib/01-manifests.sh bin/cs install.sh; do cp "$repo/$f" "$snap/${f##*/}"; done
    (cd "$repo" && bash build.sh --add-release-hashes > /dev/null) || { echo "  FAIL: the second release build failed"; return 1; }
    for f in lib/01-manifests.sh bin/cs install.sh; do
        cmp -s "$snap/${f##*/}" "$repo/$f" || { echo "  FAIL: a second release build changed $f"; return 1; }
    done
    printf '\n' >> "$repo/commands/wrap.md"
    digest=$(_sha256_of "$repo/commands/wrap.md")
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: the plain build failed"; return 1; }
    cmp -s "$snap/01-manifests.sh" "$repo/lib/01-manifests.sh" || { echo "  FAIL: a plain build changed lib/01-manifests.sh"; return 1; }
    assert_eq "0" "$(grep -c "^    $digest$" "$repo/install.sh")" "a plain build adds nothing to the table" || return 1
}

# A misspelt release flag must not pass for a plain build, or the release
# commit ships without its payload in the table.
test_build_refuses_an_unknown_argument() {
    local repo="$TEST_TMPDIR/args-repo" out rc=0
    _copy_build_inputs "$repo"
    cp "$repo/lib/01-manifests.sh" "$TEST_TMPDIR/args-manifests"
    out=$(cd "$repo" && bash build.sh --add-release-hash 2>&1) || rc=$?
    assert_eq "1" "$rc" "build.sh exit status" || { echo "$out"; return 1; }
    assert_eq "error: build.sh takes no argument, or --add-release-hashes (got: --add-release-hash)" "$out" "the error names the argument" || return 1
    assert_not_exists "$repo/bin/cs" "nothing is built" || return 1
    cmp -s "$TEST_TMPDIR/args-manifests" "$repo/lib/01-manifests.sh" || { echo "  FAIL: lib/01-manifests.sh changed"; return 1; }
}

# The release build rewrites the table from the sha256s it holds, so a line
# in it that is not one (a comment) would be dropped; the build refuses it
# instead and leaves the file as it was.
test_release_build_refuses_a_table_line_that_is_not_a_sha256() {
    local repo="$TEST_TMPDIR/note-repo" out rc=0 line
    _copy_build_inputs "$repo"
    awk '{ print } /^CS_KNOWN_SHA256=\($/ { print "    # a note" }' "$repo/lib/01-manifests.sh" > "$TEST_TMPDIR/note-manifests"
    cp "$TEST_TMPDIR/note-manifests" "$repo/lib/01-manifests.sh"
    line=$(grep -n '^    # a note$' "$repo/lib/01-manifests.sh" | cut -d: -f1)
    out=$(cd "$repo" && bash build.sh --add-release-hashes 2>&1) || rc=$?
    assert_eq "1" "$rc" "build.sh exit status" || { echo "$out"; return 1; }
    assert_eq "error: lib/01-manifests.sh line $line, inside CS_KNOWN_SHA256, is not a sha256:     # a note" \
        "$(printf '%s\n' "$out" | tail -1)" "the error names the line" || return 1
    cmp -s "$TEST_TMPDIR/note-manifests" "$repo/lib/01-manifests.sh" || { echo "  FAIL: lib/01-manifests.sh changed"; return 1; }
}

# An empty table cannot be cs's: every install from before the record wrote
# content listed there. The release build refuses it with its own error on
# every bash (bash 3.2 under set -u fails on the empty array expansion) and
# leaves the file as it was.
test_release_build_refuses_an_empty_table() {
    local repo="$TEST_TMPDIR/empty-repo" out rc=0
    _copy_build_inputs "$repo"
    awk '/^CS_KNOWN_SHA256=\($/ { print; skip = 1; next } skip && $0 == ")" { skip = 0 } !skip { print }' \
        "$repo/lib/01-manifests.sh" > "$TEST_TMPDIR/empty-manifests"
    cp "$TEST_TMPDIR/empty-manifests" "$repo/lib/01-manifests.sh"
    assert_eq "0" "$(extract_array "$repo/lib/01-manifests.sh" CS_KNOWN_SHA256 | wc -l | tr -d ' ')" "the fixture's table is empty" || return 1
    out=$(cd "$repo" && bash build.sh --add-release-hashes 2>&1) || rc=$?
    assert_eq "1" "$rc" "build.sh exit status" || { echo "$out"; return 1; }
    assert_eq "error: CS_KNOWN_SHA256 in lib/01-manifests.sh is empty" \
        "$(printf '%s\n' "$out" | tail -1)" "the error says the table is empty" || return 1
    cmp -s "$TEST_TMPDIR/empty-manifests" "$repo/lib/01-manifests.sh" || { echo "  FAIL: lib/01-manifests.sh changed"; return 1; }
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
    for arr in CS_HOOKS CS_HOOK_LIBS RETIRED_HOOKS CS_COMMANDS RETIRED_COMMANDS CS_SKILLS RETIRED_SKILLS CS_SKILL_FILES CS_MOD_FILES CS_MODS_KEPT_OUT; do
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
    # an event, and libraries the hooks source or hand to another tool (the
    # notification icon included), which must ship and be removed with them
    # but must never be registered. Together they must account for every
    # file, so a new one cannot be silently left uninstalled.
    listed=$( { extract_array "$SCRIPT_DIR/../install.sh" CS_HOOKS
                extract_array "$SCRIPT_DIR/../install.sh" CS_HOOK_LIBS; } | sort)
    actual=$(cd "$SCRIPT_DIR/../hooks" && ls | sort)
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_HOOKS + CS_HOOK_LIBS does not match the files under hooks/"
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

# The rotate mod deploys as plain files under ~/.claude/skills/cs, so
# the manifest lists each one. Every listed file exists, and every file the
# mod needs (manifest, hooks list, module) is listed; the bun tests are not.
# The repo's files are the ones git sees (tracked, or new and not ignored):
# Claude Code generates .claude-plugin/types/ inside a mod it loads, ignored
# by its own .gitignore, and a walk of the disk counted those. A mod the
# installer keeps out (CS_MODS_KEPT_OUT) is a directory under mods/, and none
# of its files is listed.
test_mod_files_manifest_matches_the_repo() {
    local entry listed actual kept
    for entry in $(extract_array "$SCRIPT_DIR/../install.sh" CS_MOD_FILES); do
        [ -f "$SCRIPT_DIR/../mods/$entry" ] \
            || { echo "  FAIL: CS_MOD_FILES entry missing from repo: mods/$entry"; return 1; }
    done
    listed=$(extract_array "$SCRIPT_DIR/../install.sh" CS_MOD_FILES | sort)
    actual=$(git -C "$SCRIPT_DIR/../mods" ls-files --cached --others --exclude-standard | grep -v '/test/' | sort)
    for kept in $(extract_array "$SCRIPT_DIR/../install.sh" CS_MODS_KEPT_OUT); do
        [ -d "$SCRIPT_DIR/../mods/$kept" ] \
            || { echo "  FAIL: CS_MODS_KEPT_OUT names no directory under mods/: $kept"; return 1; }
        actual=$(printf '%s\n' "$actual" | grep -v "^$kept/")
    done
    if [ "$listed" != "$actual" ]; then
        echo "  FAIL: CS_MOD_FILES does not match the files under mods/ (test/ and kept-out mods excluded)"
        diff <(echo "$listed") <(echo "$actual") | head -10
        return 1
    fi
}

# A local install deploys the mod byte for byte beside the skills, and
# uninstall takes the directory away again.
test_install_deploys_the_rotate_mod_and_uninstall_removes_it() {
    local fake_home="$TEST_TMPDIR/mod-home"
    mkdir -p "$fake_home/.claude"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    local entry
    for entry in $(extract_array "$SCRIPT_DIR/../install.sh" CS_MOD_FILES); do
        cmp -s "$SCRIPT_DIR/../mods/$entry" "$fake_home/.claude/skills/$entry" \
            || { echo "  FAIL: mod file not deployed or differs: $entry"; return 1; }
    done
    [ ! -e "$fake_home/.claude/skills/cs/test" ] \
        || { echo "  FAIL: the mod's bun tests were deployed"; return 1; }
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    [ ! -d "$fake_home/.claude/skills/cs" ] \
        || { echo "  FAIL: uninstall left ~/.claude/skills/cs behind"; return 1; }
}

# The Spinner tips lines in install's output, each without its leading marker.
_tips_lines() {  # install output
    printf '%s\n' "$1" | grep 'Spinner tips' | sed 's/^.*Spinner tips/Spinner tips/'
}

# The tips file the cs mod ships has the shape Claude Code 2.1.309 reads from a
# spinnerTipsOverride.tipsFile: {"tips": [...]} of at most 200 tips, each an
# object with an id of 1-64 letters, digits, ".", "_" or "-" and a text of at
# most 500 characters, under 262144 bytes; a tip outside it is dropped there.
test_the_cs_tips_file_has_the_shape_claude_code_reads() {
    local f="$SCRIPT_DIR/../mods/cs/tips.json" bad
    [ "$(wc -c < "$f")" -le 262144 ] || { echo "  FAIL: $f is over 262144 bytes"; return 1; }
    bad=$(jq -r '.tips | if type != "array" or length == 0 or length > 200 then "tips is not a list of 1-200"
        else .[] | select((.id | type) != "string" or (.id | test("^[A-Za-z0-9._-]{1,64}$") | not)
            or (.text | type) != "string" or (.text | length) > 500 or (.text | length) == 0)
            | "tip \(.id // "without an id")" end' "$f") \
        || { echo "  FAIL: jq could not read $f"; return 1; }
    assert_eq "" "$bad" "the cs tips file holds a tip Claude Code drops" || return 1
}

# With no tips file named, install names cs's in settings.json beside the
# user's own tips and excludeDefault, which it never touches, says so, and
# records that it named it.
test_install_names_the_cs_tips_file_beside_the_users_tips() {
    local home="$TEST_TMPDIR/tips-home" out
    mkdir -p "$home/.claude"
    printf '{"spinnerTipsOverride":{"tips":["mine"],"excludeDefault":false}}\n' > "$home/.claude/settings.json"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"tips":["mine"],"excludeDefault":false,"tipsFile":"~/.claude/skills/cs/tips.json"}' \
        "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "named" "$(cat "$home/.config/cs/tips-file" 2>/dev/null)" "the tips-file record after install" || return 1
    assert_eq "Spinner tips: named cs's tips file in ~/.claude/settings.json (spinnerTipsOverride.tipsFile)" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# A second install finds cs's tips file named and leaves settings.json and its
# output as they were: no change, no tips line.
test_install_twice_names_the_cs_tips_file_once() {
    local home="$TEST_TMPDIR/tips-twice-home" out backups
    mkdir -p "$home/.claude"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install.sh exited non-zero"; return 1; }
    assert_eq '{"tipsFile":"~/.claude/skills/cs/tips.json"}' \
        "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after the first install" || return 1
    backups=$(_settings_backups "$home/.claude/settings.json")
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: second install.sh exited non-zero"; return 1; }
    assert_eq "$backups" "$(_settings_backups "$home/.claude/settings.json")" "the second install wrote settings.json (a new backup)" || return 1
    assert_eq '{"tipsFile":"~/.claude/skills/cs/tips.json"}' \
        "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after the second install" || return 1
    assert_eq "" "$(_tips_lines "$out")" "the second install's tips line" || return 1
}

# Claude Code reads one tips file: one the user named stays, and install says
# cs's tip is left out.
test_install_keeps_a_tips_file_the_user_named() {
    local home="$TEST_TMPDIR/tips-own-home" out
    mkdir -p "$home/.claude"
    printf '{"spinnerTipsOverride":{"tipsFile":"~/my-tips.json"}}\n' > "$home/.claude/settings.json"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"tipsFile":"~/my-tips.json"}' \
        "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "Spinner tips: ~/.claude/settings.json names its own tipsFile (~/my-tips.json), and Claude Code reads one; cs's tip (turn on the band's prompt bars in /config) is left out" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# A spinnerTipsOverride that is not an object is the user's to fix: install
# completes, leaves it as it is and warns.
test_install_leaves_a_spinner_tips_override_that_is_not_an_object() {
    local home="$TEST_TMPDIR/tips-odd-home" out
    mkdir -p "$home/.claude"
    printf '{"spinnerTipsOverride":"tips please"}\n' > "$home/.claude/settings.json"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '"tips please"' \
        "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "Spinner tips: spinnerTipsOverride in ~/.claude/settings.json is not an object; left as it is, so cs's tip is not in Claude Code's tips" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# Uninstall takes back only cs's tips file: the user's tips stay, and a
# spinnerTipsOverride that held nothing else goes; one naming another file stays.
test_uninstall_removes_only_the_cs_tips_file() {
    local mixed="$TEST_TMPDIR/tips-un-mixed" alone="$TEST_TMPDIR/tips-un-alone" own="$TEST_TMPDIR/tips-un-own" home
    local spelled="$TEST_TMPDIR/tips-un-spelled"
    for home in "$mixed" "$alone" "$own" "$spelled"; do mkdir -p "$home/.claude"; done
    printf '{"spinnerTipsOverride":{"tips":["mine"]}}\n' > "$mixed/.claude/settings.json"
    printf '{"spinnerTipsOverride":{"tipsFile":"~/my-tips.json"}}\n' > "$own/.claude/settings.json"
    printf '{"spinnerTipsOverride":{"tipsFile":"%s/.claude/skills/cs/tips.json"}}\n' "$spelled" > "$spelled/.claude/settings.json"
    for home in "$mixed" "$alone" "$own" "$spelled"; do
        HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero in $home"; return 1; }
        printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > /dev/null 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero in $home"; return 1; }
    done
    assert_eq '{"tips":["mine"]}' "$(jq -c .spinnerTipsOverride "$mixed/.claude/settings.json")" \
        "spinnerTipsOverride with the user's tips after uninstall" || return 1
    assert_eq 'false' "$(jq -c 'has("spinnerTipsOverride")' "$alone/.claude/settings.json")" \
        "spinnerTipsOverride that held only cs's file is gone" || return 1
    assert_eq '{"tipsFile":"~/my-tips.json"}' "$(jq -c .spinnerTipsOverride "$own/.claude/settings.json")" \
        "spinnerTipsOverride naming the user's file after uninstall" || return 1
    assert_eq 'false' "$(jq -c 'has("spinnerTipsOverride")' "$spelled/.claude/settings.json")" \
        "cs's tips file spelled from \$HOME is cs's too" || return 1
}

# Taking cs's tipsFile out of settings.json is a decline: the next install
# records it, leaves the pointer out, and says how to have it back. So does
# every install after it.
test_install_leaves_out_a_cs_tips_file_the_user_took_out() {
    local home="$TEST_TMPDIR/tips-out-home" f out run
    f="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install.sh exited non-zero"; return 1; }
    jq 'del(.spinnerTipsOverride.tipsFile)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    for run in second third; do
        out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: $run install.sh exited non-zero"; return 1; }
        assert_eq '{}' "$(jq -c .spinnerTipsOverride "$f")" "spinnerTipsOverride after the $run install" || return 1
        assert_eq "declined" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after the $run install" || return 1
        assert_eq "Spinner tips: cs's tip stays out of Claude Code's tips, as recorded in $home/.config/cs/tips-file; to have it back, delete that file and run cs -update" \
            "$(_tips_lines "$out")" "the $run install's tips line" || return 1
    done
}

# An empty tipsFile names no file, so emptying cs's is taking it out.
test_install_treats_an_emptied_cs_tips_file_as_taken_out() {
    local home="$TEST_TMPDIR/tips-empty-home" f
    f="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install.sh exited non-zero"; return 1; }
    jq '.spinnerTipsOverride.tipsFile = ""' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: second install.sh exited non-zero"; return 1; }
    assert_eq '{"tipsFile":""}' "$(jq -c .spinnerTipsOverride "$f")" "spinnerTipsOverride after the second install" || return 1
    assert_eq "declined" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after the second install" || return 1
}

# A declined record keeps cs's tips file out of a settings.json that names
# none, and stays as it is.
test_install_names_no_tips_file_after_a_decline() {
    local home="$TEST_TMPDIR/tips-declined-home" out
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'declined\n' > "$home/.config/cs/tips-file"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq 'null' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "declined" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after install" || return 1
    assert_eq "Spinner tips: cs's tip stays out of Claude Code's tips, as recorded in $home/.config/cs/tips-file; to have it back, delete that file and run cs -update" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# An install from before the record named cs's tips file and wrote none: the
# next install records that cs named it and changes nothing in settings.json.
test_install_records_a_cs_tips_file_named_before_the_record() {
    local home="$TEST_TMPDIR/tips-legacy-home" f out backups
    f="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install.sh exited non-zero"; return 1; }
    rm "$home/.config/cs/tips-file"
    backups=$(_settings_backups "$f")
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: second install.sh exited non-zero"; return 1; }
    assert_eq "named" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after the second install" || return 1
    assert_eq "$backups" "$(_settings_backups "$f")" "the second install wrote settings.json (a new backup)" || return 1
    assert_eq '{"tipsFile":"~/.claude/skills/cs/tips.json"}' "$(jq -c .spinnerTipsOverride "$f")" \
        "spinnerTipsOverride after the second install" || return 1
    assert_eq "" "$(_tips_lines "$out")" "the second install's tips line" || return 1
}

# A tips file the user named says nothing about cs's, so the record stays as
# it was.
test_install_keeps_the_tips_record_beside_a_tips_file_the_user_named() {
    local home="$TEST_TMPDIR/tips-own-record-home"
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'named\n' > "$home/.config/cs/tips-file"
    printf '{"spinnerTipsOverride":{"tipsFile":"~/my-tips.json"}}\n' > "$home/.claude/settings.json"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"tipsFile":"~/my-tips.json"}' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" \
        "spinnerTipsOverride after install" || return 1
    assert_eq "named" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after install" || return 1
}

# With no record of consent there is no pointer: a record install cannot
# write leaves cs's tips file unnamed, and the install still finishes.
test_install_names_no_tips_file_when_its_record_cannot_be_written() {
    local home="$TEST_TMPDIR/tips-nowrite-home" out rc=0
    mkdir -p "$home/.claude" "$home/.config/cs"
    chmod 500 "$home/.config/cs"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    chmod 700 "$home/.config/cs"
    assert_eq "0" "$rc" "install.sh exit status with an unwritable ~/.config/cs" || return 1
    jq -e '.hooks.SessionStart' "$home/.claude/settings.json" >/dev/null 2>&1 \
        || { echo "  FAIL: hooks were not registered; the install aborted before finishing"; return 1; }
    assert_eq 'null' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_not_exists "$home/.config/cs/tips-file" "no tips-file record" || return 1
    assert_eq "Spinner tips: could not write $home/.config/cs/tips-file, so cs's tips file is not named in ~/.claude/settings.json" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# A record that says neither named nor declined is never read as consent:
# install keeps cs's tips file out, names the record, and leaves it as it is.
test_install_reads_a_tips_record_it_cannot_parse_as_declined() {
    local home="$TEST_TMPDIR/tips-garbage-home" out
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'maybe\n' > "$home/.config/cs/tips-file"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq 'null' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "maybe" "$(cat "$home/.config/cs/tips-file")" "the tips-file record after install" || return 1
    assert_eq "Spinner tips: $home/.config/cs/tips-file holds neither named nor declined, so cs's tip is kept out as declined
Spinner tips: cs's tip stays out of Claude Code's tips, as recorded in $home/.config/cs/tips-file; to have it back, delete that file and run cs -update" \
        "$(_tips_lines "$out")" "install's tips lines" || return 1
}

# Uninstall forgets the decline with the rest of cs's state.
test_uninstall_removes_the_tips_record() {
    local home="$TEST_TMPDIR/tips-un-record"
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'declined\n' > "$home/.config/cs/tips-file"
    echo '{}' > "$home/.claude/settings.json"
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > /dev/null 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_not_exists "$home/.config/cs/tips-file" "the tips-file record after uninstall" || return 1
}

# A cs mod directory the user linked at their own files is kept, so no cs
# tips file lands in it: install names none and says why.
test_install_names_no_tips_file_it_did_not_deploy() {
    local home="$TEST_TMPDIR/tips-nodeploy-home" target="$TEST_TMPDIR/tips-nodeploy-target" out
    mkdir -p "$home/.claude/skills" "$target/hooks"
    echo 'my register' > "$target/hooks/register.tsx"
    ln -s "$target" "$home/.claude/skills/cs"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq 'null' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" "spinnerTipsOverride after install" || return 1
    assert_eq "Spinner tips: $home/.claude/skills/cs/tips.json was not deployed as a file, so cs's tip is not in Claude Code's tips" \
        "$(_tips_lines "$out")" "install's tips line" || return 1
}

# A tips file the user changed is kept by uninstall as theirs, and so is the
# setting that names it.
test_uninstall_keeps_a_changed_cs_tips_file_and_its_setting() {
    local home="$TEST_TMPDIR/tips-changed-home"
    mkdir -p "$home/.claude"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    printf '["my own tip"]\n' > "$home/.claude/skills/cs/tips.json"
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > /dev/null 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq '["my own tip"]' "$(cat "$home/.claude/skills/cs/tips.json")" "the changed tips file" || return 1
    assert_eq '{"tipsFile":"~/.claude/skills/cs/tips.json"}' "$(jq -c .spinnerTipsOverride "$home/.claude/settings.json")" \
        "spinnerTipsOverride naming the kept file" || return 1
}

# A launch under tmux in iTerm2 hard-links claude into
# ~/.local/share/cs/claude/<version>/; each link holds a whole claude binary,
# so uninstall removes the directory and leaves the rest of ~/.local/share/cs.
test_uninstall_removes_the_claude_links() {
    local fake_home="$TEST_TMPDIR/links-home"
    mkdir -p "$fake_home/.claude" "$fake_home/.local/share/cs/claude/9.9.9" "$fake_home/.local/share/cs/vaults"
    : > "$fake_home/.local/share/cs/claude/9.9.9/claude"
    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    [ ! -e "$fake_home/.local/share/cs/claude" ] \
        || { echo "  FAIL: uninstall left ~/.local/share/cs/claude behind"; return 1; }
    [ -d "$fake_home/.local/share/cs/vaults" ] \
        || { echo "  FAIL: uninstall removed the vaults directory"; return 1; }
}

# rm -rf recurses into a mount, so deleting the session data while a volume is
# mounted inside it would delete what the volume holds. The answers are:
# continue (y), keep keychain secrets (n), delete session data (y). The
# `mount` stub staged in stub-dir comes first on PATH.
_uninstall_with_mounts() {  # case-name stub-dir
    local home="$TEST_TMPDIR/$1-home" root="$TEST_TMPDIR/$1-sessions"
    mkdir -p "$home/.claude" "$root/s1/.cs/vault-mnt"
    echo sealed > "$root/s1/.cs/vault-mnt/notes.md"
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$2:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/$1.out" 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
}

test_uninstall_keeps_session_data_while_a_volume_is_mounted_inside() {
    local root out stub="$TEST_TMPDIR/mount-stub"
    root="$TEST_TMPDIR/umount-mounted-sessions"
    _stub_mount_table "$stub" "/dev/disk9s1 on $root/s1/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)" || return 1
    _uninstall_with_mounts umount-mounted "$stub" || return 1
    out=$(cat "$TEST_TMPDIR/umount-mounted.out")
    assert_file_exists "$root/s1/.cs/vault-mnt/notes.md" "the volume's contents survive" || return 1
    assert_output_contains "$out" "Kept $root: a volume is mounted inside it at $root/s1/.cs/vault-mnt" "says why the data stays" || return 1
}

test_uninstall_keeps_session_data_when_the_mount_table_cannot_be_read() {
    local root out stub="$TEST_TMPDIR/mount-stub"
    root="$TEST_TMPDIR/umount-broken-sessions"
    _stub_mount_unreadable "$stub" || return 1
    _uninstall_with_mounts umount-broken "$stub" || return 1
    out=$(cat "$TEST_TMPDIR/umount-broken.out")
    assert_file_exists "$root/s1/.cs/vault-mnt/notes.md" "the data survives" || return 1
    assert_output_contains "$out" "Kept $root: cs could not read the mount table, so it cannot tell whether a volume is mounted inside it" "says why the data stays" || return 1
}

test_uninstall_deletes_session_data_with_no_volume_mounted_inside() {
    local root stub="$TEST_TMPDIR/mount-stub"
    root="$TEST_TMPDIR/umount-clear-sessions"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    _uninstall_with_mounts umount-clear "$stub" || return 1
    assert_not_exists "$root" "the answered yes deletes the session data" || return 1
}

# The keychain purge runs cs-secrets, so the binary must still be on disk when
# the purge asks for it. The answers are: continue (y), delete keychain
# secrets (y), keep session data (n).
test_uninstall_purges_secrets_before_removing_cs_secrets() {
    local home="$TEST_TMPDIR/purge-home" root="$TEST_TMPDIR/purge-sessions"
    local dump="$TEST_TMPDIR/purge-argv" stub="$TEST_TMPDIR/mount-stub"
    mkdir -p "$home/.claude" "$home/.local/bin" "$root/purge-probe/.cs"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$dump" > "$home/.local/bin/cs-secrets"
    chmod +x "$home/.local/bin/cs-secrets"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    printf 'yyn' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/purge.out" 2>&1 || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_file_exists "$dump" "the purge ran cs-secrets" || return 1
    assert_file_contains "$dump" "^--session purge-probe purge$" "the purge names the session" || return 1
    assert_not_exists "$home/.local/bin/cs-secrets" "cs-secrets is still removed afterwards" || return 1
}

# Deleting the sessions root under a running conversation pulls its files out
# from under it. A session counts as live when its lock holds a running pid or
# its statusline heartbeat is fresh; a lock naming a dead pid does not. The
# answers are: continue (y), keep keychain secrets (n), delete session data (y).
test_uninstall_refuses_to_delete_session_data_while_a_session_is_live() {
    local home="$TEST_TMPDIR/live-home" root="$TEST_TMPDIR/live-sessions" stub="$TEST_TMPDIR/mount-stub"
    mkdir -p "$home/.claude" "$root/live-lock/.cs" "$root/live-beat/.cs/local" "$root/dead-lock/.cs"
    echo "$$" > "$root/live-lock/.cs/session.lock"
    : > "$root/live-beat/.cs/local/context-pct"
    echo 99999999 > "$root/dead-lock/.cs/session.lock"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/live.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/live.out")
    [ "$rc" -ne 0 ] || { echo "  FAIL: uninstall must exit non-zero while a session is live"; return 1; }
    assert_file_exists "$root/live-lock/.cs/session.lock" "the live session's data survives" || return 1
    assert_file_exists "$root/dead-lock/.cs/session.lock" "nothing under the root is deleted" || return 1
    # Exact list: both live sessions, and not the one whose lock names a dead pid.
    assert_output_contains "$out" "^Error: Nothing was uninstalled: these sessions are live: live-beat live-lock\. Close them and run cs -uninstall again\.$" \
        "the refusal names exactly the live sessions" || return 1
}

# Codex (batch 1, round 2): the liveness scan globbed `*`, which skips a
# dot-prefixed session directory. A session named before leading dots were
# refused (.work) can still be live, and uninstall offered to rm -rf the root
# over it. Hidden directories count; only . and .. are skipped.
test_uninstall_refuses_to_delete_session_data_while_a_dotted_session_is_live() {
    local home="$TEST_TMPDIR/dot-home" root="$TEST_TMPDIR/dot-sessions" stub="$TEST_TMPDIR/mount-stub-dot"
    mkdir -p "$home/.claude" "$root/.work/.cs" "$root/plain/.cs"
    echo "$$" > "$root/.work/.cs/session.lock"
    echo 99999999 > "$root/plain/.cs/session.lock"
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    local rc=0 out
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/dot.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/dot.out")
    [ "$rc" -ne 0 ] || { echo "  FAIL: uninstall must exit non-zero while a dot-prefixed session is live"; return 1; }
    assert_file_exists "$root/.work/.cs/session.lock" "the live dotted session's data survives" || return 1
    assert_output_contains "$out" "^Error: Nothing was uninstalled: these sessions are live: \.work\. Close them and run cs -uninstall again\.$" \
        "the refusal names the dotted session" || return 1
}

# A live session is refused the same way when a volume is also mounted inside
# the sessions root: the live refusal comes first and exits non-zero.
test_uninstall_refuses_a_live_session_even_with_a_volume_mounted_inside() {
    local home="$TEST_TMPDIR/livemnt-home" root="$TEST_TMPDIR/livemnt-sessions" stub="$TEST_TMPDIR/mount-stub"
    mkdir -p "$home/.claude" "$root/live-vault/.cs/vault-mnt"
    echo "$$" > "$root/live-vault/.cs/session.lock"
    _stub_mount_table "$stub" "/dev/disk9s1 on $root/live-vault/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)" || return 1
    local rc=0 out
    printf 'yny' | HOME="$home" CS_SESSIONS_ROOT="$root" PATH="$stub:$PATH" "$CS_BIN" -uninstall \
        > "$TEST_TMPDIR/livemnt.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/livemnt.out")
    [ "$rc" -ne 0 ] || { echo "  FAIL: uninstall must exit non-zero while a session is live"; return 1; }
    assert_file_exists "$root/live-vault/.cs/session.lock" "the live session's data survives" || return 1
    assert_output_contains "$out" "^Error: Nothing was uninstalled: these sessions are live: live-vault\. Close them and run cs -uninstall again\.$" \
        "the live refusal wins over the mount warning" || return 1
}

# An earlier opt-in shape had the person symlink the mod's directory under
# ~/.claude/skills at the checkout. Copying through that link would overwrite the checkout's own
# files and leave the link in place; the installer replaces the link with a
# real directory and leaves the link's target alone. The checkout holds cs's
# own mod files (here, content a past cs shipped, so a write through the link
# would show); a link at anything else is the user's and is kept.
test_install_replaces_a_symlinked_mod_directory() {
    local fake_home="$TEST_TMPDIR/modlink-home" elsewhere="$TEST_TMPDIR/modlink-target"
    mkdir -p "$fake_home/.claude/skills" "$elsewhere/hooks" "$elsewhere/.claude-plugin"
    _cs_shipped_content > "$elsewhere/hooks/register.tsx"
    _cs_shipped_content > "$elsewhere/hooks/hooks.json"
    _cs_shipped_content > "$elsewhere/.claude-plugin/plugin.json"
    _cs_shipped_content > "$elsewhere/tips.json"
    ln -s "$elsewhere" "$fake_home/.claude/skills/cs"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    [ ! -L "$fake_home/.claude/skills/cs" ] && [ -d "$fake_home/.claude/skills/cs" ] \
        || { echo "  FAIL: the symlink was not replaced by a real directory"; return 1; }
    assert_eq "$(_cs_shipped_content)" "$(cat "$elsewhere/hooks/register.tsx")" "the link's target is untouched" || return 1
    cmp -s "$SCRIPT_DIR/../mods/cs/hooks/register.tsx" "$fake_home/.claude/skills/cs/hooks/register.tsx" \
        || { echo "  FAIL: the module was not deployed into the real directory"; return 1; }
    # A real mod directory whose hooks/ is the symlink redirects the copy the
    # same way; the installer replaces that link too.
    local sub_home="$TEST_TMPDIR/modsub-home" sub_target="$TEST_TMPDIR/modsub-target"
    mkdir -p "$sub_home/.claude/skills/cs" "$sub_target"
    _cs_shipped_content > "$sub_target/register.tsx"
    _cs_shipped_content > "$sub_target/hooks.json"
    ln -s "$sub_target" "$sub_home/.claude/skills/cs/hooks"
    HOME="$sub_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install.sh exited non-zero (subdir link)"; return 1; }
    [ ! -L "$sub_home/.claude/skills/cs/hooks" ] && [ -d "$sub_home/.claude/skills/cs/hooks" ] \
        || { echo "  FAIL: the hooks/ symlink was not replaced by a real directory"; return 1; }
    assert_eq "$(_cs_shipped_content)" "$(cat "$sub_target/register.tsx")" "the subdirectory link's target is untouched" || return 1
}

# A mod directory linked at the user's own files (their fork of the mod, say)
# is theirs: install keeps the link, places nothing through it or in its
# place, and names it once.
test_install_keeps_a_mod_directory_linked_at_the_users_files() {
    local home="$TEST_TMPDIR/modown-home" target="$TEST_TMPDIR/modown-target" out rc=0
    mkdir -p "$home/.claude/skills" "$target/hooks" "$target/.claude-plugin"
    echo 'my register' > "$target/hooks/register.tsx"
    echo 'my hooks' > "$target/hooks/hooks.json"
    echo 'my plugin' > "$target/.claude-plugin/plugin.json"
    ln -s "$target" "$home/.claude/skills/cs"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "$target" "$(readlink "$home/.claude/skills/cs")" "the link is kept" || return 1
    assert_eq "my register" "$(cat "$target/hooks/register.tsx")" "the link's target is untouched" || return 1
    assert_eq "my hooks" "$(cat "$target/hooks/hooks.json")" "the link's target is untouched" || return 1
    assert_eq "my plugin" "$(cat "$target/.claude-plugin/plugin.json")" "the link's target is untouched" || return 1
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c "Kept $(_bre_literal "$home/.claude/skills/cs"):")" \
        "one warning names the kept link" || return 1
    cmp -s "$SCRIPT_DIR/../mods/cs-update/hooks/register.tsx" "$home/.claude/skills/cs-update/hooks/register.tsx" \
        || { echo "  FAIL: the other mod was not deployed"; return 1; }
}

# A skill directory linked elsewhere (a dotfiles repo, say) is the user's,
# whatever the files behind it hold: cs never makes such a link. Install
# keeps the link, writes nothing through it, names it once and lists it after
# the completion line; uninstall leaves what it points at as it was. Covers a
# link at the skill directory, whose target holds content cs wrote and the
# user's own, and one at a skill's scripts/ directory.
test_install_keeps_a_symlinked_skill_directory_and_writes_nothing_through_it() {
    local home="$TEST_TMPDIR/skilllink-home" ext="$TEST_TMPDIR/skilllink-ext" out rc=0 l
    mkdir -p "$home/.claude/skills/write-as-me" "$ext/rotate" "$ext/finish/scripts" "$ext/scripts"
    _cs_shipped_content > "$ext/rotate/SKILL.md"
    printf 'my finish skill\n' > "$ext/finish/SKILL.md"
    printf 'my finish script\n' > "$ext/finish/scripts/finish.sh"
    _cs_shipped_content > "$ext/scripts/build-corpus.sh"
    ln -s "$ext/rotate" "$home/.claude/skills/rotate"
    ln -s "$ext/finish" "$home/.claude/skills/finish"
    ln -s "$ext/scripts" "$home/.claude/skills/write-as-me/scripts"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    for l in rotate finish write-as-me/scripts; do
        [ -L "$home/.claude/skills/$l" ] || { echo "  FAIL: the link at skills/$l was not kept"; return 1; }
        assert_eq "1" "$(printf '%s\n' "$out" | grep -c "Kept $(_bre_literal "$home/.claude/skills/$l"): a symlink, so cs wrote nothing through it and the skill files under it were not deployed$")" \
            "one warning names the link at skills/$l" || return 1
        printf '%s\n' "$out" | sed -n '/Installation complete/,$p' | grep -q "^ *$(_bre_literal "$home/.claude/skills/$l")$" \
            || { echo "  FAIL: skills/$l is not listed after the completion line"; return 1; }
    done
    assert_eq "$(_cs_shipped_content)" "$(cat "$ext/rotate/SKILL.md")" "the rotate link's target is untouched" || return 1
    assert_eq "my finish skill" "$(cat "$ext/finish/SKILL.md")" "the finish link's SKILL.md is untouched" || return 1
    assert_eq "my finish script" "$(cat "$ext/finish/scripts/finish.sh")" "the finish link's script is untouched" || return 1
    assert_eq "$(_cs_shipped_content)" "$(cat "$ext/scripts/build-corpus.sh")" "the scripts link's target is untouched" || return 1
    cmp -s "$SCRIPT_DIR/../skills/write-as-me/SKILL.md" "$home/.claude/skills/write-as-me/SKILL.md" \
        || { echo "  FAIL: the SKILL.md beside a linked scripts/ was not deployed"; return 1; }
    cmp -s "$SCRIPT_DIR/../skills/feature/SKILL.md" "$home/.claude/skills/feature/SKILL.md" \
        || { echo "  FAIL: an unlinked skill was not deployed"; return 1; }
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/skilllink.un" 2>&1 \
        || { cat "$TEST_TMPDIR/skilllink.un"; echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq "$(_cs_shipped_content)" "$(cat "$ext/rotate/SKILL.md")" "uninstall leaves the rotate link's target" || return 1
    assert_eq "my finish script" "$(cat "$ext/finish/scripts/finish.sh")" "uninstall leaves the finish link's target" || return 1
    assert_eq "$(_cs_shipped_content)" "$(cat "$ext/scripts/build-corpus.sh")" "uninstall leaves the scripts link's target" || return 1
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
    _cs_shipped_content > "$fake_home/.claude/hooks/session-start.sh"
    _cs_shipped_content > "$fake_home/.claude/hooks/files-context.sh"
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

# bash-logger.sh cost every Bash call a hook process and nothing read the lines
# it wrote, so it is retired: an install over one that registered it removes
# the deployed copy and its PreToolUse entry, and keeps a user's own hook that
# shares the event and the matcher.
test_install_retires_the_bash_logger() {
    local home="$TEST_TMPDIR/home-bashlogger" s rc=0 out
    mkdir -p "$home/.claude/hooks/cs"
    _cs_shipped_content > "$home/.claude/hooks/cs/bash-logger.sh"
    s="$home/.claude/settings.json"
    cat > "$s" << 'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]},{"matcher":"Bash","hooks":[{"type":"command","command":"~/bin/my-own-hook.sh","timeout":5}]}]}}
EOF
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_file_not_exists "$home/.claude/hooks/cs/bash-logger.sh" "the deployed bash-logger is removed" || return 1
    assert_eq "0" "$(jq '[.hooks[][] | .hooks[]?.command | select(test("bash-logger"))] | length' "$s")" \
        "no bash-logger registration survives" || return 1
    assert_eq '[{"matcher":"Bash","hooks":[{"type":"command","command":"~/bin/my-own-hook.sh","timeout":5}]}]' \
        "$(jq -c '.hooks.PreToolUse' "$s")" "the user's own hook is all PreToolUse holds" || return 1
}

# A retired hook under ~/.claude/hooks/cs/ that cs did not write is kept, and
# so is its registration, the same rule as for a kept flat hook: install and
# uninstall leave both, and still strip a cs-written copy's file and entry.
test_install_and_uninstall_keep_a_kept_retired_hook_and_its_registration() {
    local home="$TEST_TMPDIR/kept-retired-home" rc=0 out s mine
    s="$home/.claude/settings.json"
    mine='#!/bin/sh
echo my bash logger'
    mkdir -p "$home/.claude/hooks/cs"
    printf '%s\n' "$mine" > "$home/.claude/hooks/cs/bash-logger.sh"
    cat > "$s" << 'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}
JSON
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "$mine" "$(cat "$home/.claude/hooks/cs/bash-logger.sh")" "install keeps the user's bash-logger" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/bash-logger.sh")] | length' "$s")" \
        "install keeps the kept hook's registration" || return 1
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/kept-retired.out" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/kept-retired.out"; return 1; }
    assert_eq "$mine" "$(cat "$home/.claude/hooks/cs/bash-logger.sh")" "uninstall keeps the user's bash-logger" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/bash-logger.sh")] | length' "$s")" \
        "uninstall keeps the kept hook's registration" || return 1
}

# Uninstall over a bash-logger cs wrote removes the file and its registration.
test_uninstall_removes_a_cs_written_retired_hook_and_its_registration() {
    local home="$TEST_TMPDIR/owned-retired-home" rc=0 s
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude/hooks/cs"
    _cs_shipped_content > "$home/.claude/hooks/cs/bash-logger.sh"
    cat > "$s" << 'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}
JSON
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/owned-retired.out" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/owned-retired.out"; return 1; }
    assert_file_not_exists "$home/.claude/hooks/cs/bash-logger.sh" "the cs-written bash-logger is removed" || return 1
    assert_eq "0" "$(jq '[(.hooks // {})[][] | .hooks[]?.command | select(test("bash-logger"))] | length' "$s")" \
        "no bash-logger registration survives" || return 1
}

# A retired hook cs wrote goes only once settings.json no longer registers it:
# an install that stops before the settings are rewritten (here a regular file
# where ~/.claude/commands must be) leaves the file and its registration
# together, so no Bash call runs a hook that is not there.
test_install_that_stops_early_keeps_a_registered_retired_hook() {
    local home="$TEST_TMPDIR/retired-abort-home" rc=0 out s
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude/hooks/cs"
    _cs_shipped_content > "$home/.claude/hooks/cs/bash-logger.sh"
    : > "$home/.claude/commands"
    cat > "$s" << 'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}
JSON
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "1" "$rc" "the install stops at the commands directory" || { echo "$out"; return 1; }
    assert_file_exists "$home/.claude/hooks/cs/bash-logger.sh" "the retired hook stays while it is registered" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/bash-logger.sh")] | length' "$s")" \
        "its registration is unchanged" || return 1
}

# Fills directory $1 with links to every command on the test's PATH except
# jq, for a PATH on which the install finds no jq.
_link_path_without_jq() {  # dir
    link_path_without "$1" jq
}

# cs locks its files through perl, so an install where perl cannot lock
# refuses before it writes anything, naming perl.
test_install_without_perl_refuses_before_changing_anything() {
    local home="$TEST_TMPDIR/noperl-home" bindir="$TEST_TMPDIR/noperl-bin" rc=0 out
    mkdir -p "$home"
    link_path_without "$bindir" 'perl*'
    out=$(HOME="$home" PATH="$bindir" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    [ "$rc" != 0 ] || { echo "  install without perl succeeded"; echo "$out"; return 1; }
    assert_output_contains "$out" "perl" "the refusal names perl" || return 1
    assert_eq "" "$(ls -A "$home")" "nothing written under HOME" || return 1
}

# Without jq the install cannot touch settings.json, so a registered retired
# hook cs wrote stays on disk with its registration.
test_install_without_jq_keeps_a_registered_retired_hook() {
    local home="$TEST_TMPDIR/retired-nojq-home" bindir="$TEST_TMPDIR/retired-nojq-bin" rc=0 out
    mkdir -p "$home/.claude/hooks/cs"
    _cs_shipped_content > "$home/.claude/hooks/cs/bash-logger.sh"
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}' \
        > "$home/.claude/settings.json"
    _link_path_without_jq "$bindir"
    out=$(HOME="$home" PATH="$bindir" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_output_contains "$out" "jq not found" "the install says it left settings alone" || return 1
    assert_file_exists "$home/.claude/hooks/cs/bash-logger.sh" "the retired hook stays while it is registered" || return 1
}

# A retired hook whose only proof of being cs's is its install-record line
# keeps that line while it waits on a registration: a run without jq leaves
# it, and the next run with jq still knows it as cs's and removes it.
test_a_retired_hook_known_by_its_record_survives_a_run_without_jq() {
    local home="$TEST_TMPDIR/retired-record-home" bindir="$TEST_TMPDIR/retired-record-bin" rc=0 out s f digest
    s="$home/.claude/settings.json"
    f="$home/.claude/hooks/cs/bash-logger.sh"
    mkdir -p "$home/.claude/hooks/cs"
    printf '#!/bin/sh\n# an older cs build %s\n' "$RANDOM$RANDOM" > "$f"
    digest=$(shasum -a 256 "$f" | cut -d' ' -f1)
    printf '%s  .claude/hooks/cs/bash-logger.sh\n' "$digest" > "$home/.claude/hooks/cs/.installed"
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}' > "$s"
    _link_path_without_jq "$bindir"
    out=$(HOME="$home" PATH="$bindir" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install without jq" || { echo "$out"; return 1; }
    assert_file_exists "$f" "the registered retired hook waits for a run that can strip it" || return 1
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install with jq" || { echo "$out"; return 1; }
    assert_file_not_exists "$f" "the next run still knows it as cs's and removes it" || return 1
    assert_eq "0" "$(jq '[(.hooks // {})[][] | .hooks[]?.command | select(test("bash-logger"))] | length' "$s")" \
        "and its registration" || return 1
}

# Runs the installer over $1 (a HOME holding a registered bash-logger.sh cs
# wrote) on a tty, and at the status line question runs shell command $2
# with the hook's path as $0 before answering n. Returns the installer's
# exit status, or 99 when it is still running after 60 s.
_install_swapping_retired_hook_at_question() {  # home, sh-command
    local exp="$TEST_TMPDIR/retired-swap.exp" f="$1/.claude/hooks/cs/bash-logger.sh" rc=0
    cat > "$exp" <<EXPECT
set timeout 60
spawn env HOME=$1 bash $INSTALL_SH
expect {
    -re {status line.*\[[yY]/[nN]\]} { exec sh -c {$2} $f; send "n\r"; exp_continue }
    -re {$_ROTATE_WRAP_ASK_RE} { send "n"; exp_continue }
    timeout { exit 99 }
    eof
}
catch wait result
exit [lindex \$result 3]
EXPECT
    expect -f "$exp" >/dev/null 2>&1 || rc=$?
    return "$rc"
}

# Seeds HOME $1 with a bash-logger.sh cs wrote, registered, and a status line
# of the user's own, so the install asks its status line question.
_seed_registered_retired_hook() {  # home
    mkdir -p "$1/.claude/hooks/cs"
    _cs_shipped_content > "$1/.claude/hooks/cs/bash-logger.sh"
    printf '%s\n' '{"statusLine":{"command":"/opt/other/bar"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/cs/bash-logger.sh","timeout":5}]}]}}' \
        > "$1/.claude/settings.json"
}

# Ownership is judged again once the questions are answered: a retired hook
# replaced while the install waited at a question is the user's file now, and
# keeps its content and its registration.
test_a_retired_hook_replaced_during_a_question_is_kept() {
    require_tool expect || return $?
    local home="$TEST_TMPDIR/retired-swap-home" s f rc=0
    s="$home/.claude/settings.json"
    f="$home/.claude/hooks/cs/bash-logger.sh"
    _seed_registered_retired_hook "$home"
    _install_swapping_retired_hook_at_question "$home" 'printf "my own logger\n" > "$0"' || rc=$?
    assert_eq "0" "$rc" "install exit status" || return 1
    assert_eq "my own logger" "$(cat "$f" 2>/dev/null)" "the replaced hook keeps its content" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/bash-logger.sh")] | length' "$s")" \
        "and its registration" || return 1
}

# A retired hook replaced at a question by something that is not a regular
# file (here a link to /dev/zero, which never ends) is the user's too, and is
# kept without being read: the install finishes and keeps its registration.
test_a_retired_hook_replaced_by_a_link_to_a_device_is_kept_unread() {
    require_tool expect || return $?
    local home="$TEST_TMPDIR/retired-dev-home" s f rc=0
    s="$home/.claude/settings.json"
    f="$home/.claude/hooks/cs/bash-logger.sh"
    _seed_registered_retired_hook "$home"
    _install_swapping_retired_hook_at_question "$home" 'rm -f "$0" && ln -s /dev/zero "$0"' || rc=$?
    assert_eq "0" "$rc" "install finishes (99: still running after 60 s)" || return 1
    assert_eq "/dev/zero" "$(readlink "$f")" "the link is kept" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/bash-logger.sh")] | length' "$s")" \
        "and its registration" || return 1
}

# A mod deploys under ~/.claude/skills/<mod>; one that a past version shipped
# and this one does not is a retired skill directory, and a copy left behind
# keeps loading into every Claude Code the machine starts.
test_install_removes_the_retired_hint_mod() {
    local fake_home="$TEST_TMPDIR/home-hintmod"
    mkdir -p "$fake_home/.claude/skills/cs-hint/hooks"
    _cs_shipped_content > "$fake_home/.claude/skills/cs-hint/hooks/hooks.json"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ -d "$fake_home/.claude/skills/cs-hint" ]; then
        echo "  FAIL: retired cs-hint mod directory survived the install"
        return 1
    fi
    assert_dir "$fake_home/.claude/skills/cs" "the shipped mod is still deployed" || return 1
}

# A slash command a past version shipped and this one does not keeps
# answering its name from ~/.claude/commands until something removes it.
# Install removes each one cs wrote, by content, and uninstall removes one
# still there; a user's own file under a retired name is kept by both.
test_install_and_uninstall_remove_retired_commands_cs_wrote() {
    local home="$TEST_TMPDIR/retired-cmd-home" d rc=0 out c
    d="$home/.claude/commands"
    mkdir -p "$d"
    for c in compact-discoveries learn store-secret sweep summary; do
        _cs_shipped_content > "$d/$c.md"
    done
    printf 'my skillify command\n' > "$d/skillify.md"
    printf 'my own command\n' > "$d/mine.md"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    for c in compact-discoveries learn store-secret sweep summary; do
        assert_file_not_exists "$d/$c.md" "install removes the retired $c.md cs wrote" || return 1
    done
    assert_eq "my skillify command" "$(cat "$d/skillify.md")" "install keeps the user's skillify.md" || return 1
    assert_eq "my own command" "$(cat "$d/mine.md")" "install keeps the user's command of a name cs never shipped" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$d/skillify.md"): cs did not write it$" "install names the kept command" || return 1
    _cs_shipped_content > "$d/compact-discoveries.md"
    _cs_shipped_content > "$d/sweep.md"
    out=$(printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall 2>&1) || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { echo "$out"; return 1; }
    assert_file_not_exists "$d/compact-discoveries.md" "uninstall removes the retired command cs wrote" || return 1
    assert_file_not_exists "$d/sweep.md" "uninstall removes the retired sweep.md cs wrote" || return 1
    assert_eq "my skillify command" "$(cat "$d/skillify.md")" "uninstall keeps the user's skillify.md" || return 1
    assert_eq "my own command" "$(cat "$d/mine.md")" "uninstall keeps the user's mine.md" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$d/skillify.md"): cs did not write it" "uninstall names the kept command" || return 1
}

# /wrap runs the memory pass and the summary pass, and no slash command of
# their own answers for either: a fresh install deploys /wrap and
# /checkpoint as commands, and every file wrap.md tells the model to read
# under ~/.claude is in place, each the checkout's copy.
test_install_deploys_wrap_and_the_passes_it_reads_but_no_pass_command() {
    local home="$TEST_TMPDIR/wrap-home" rc=0 out reads p src
    mkdir -p "$home"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "$(printf 'checkpoint.md\nwrap.md')" "$(cd "$home/.claude/commands" && ls)" \
        "the commands cs deploys" || return 1
    reads=$(grep -o '`~/\.claude/[^`]*\.md`' "$home/.claude/commands/wrap.md" | sed 's|^`~/\.claude/||; s|`$||' | sort -u)
    assert_eq "$(printf '%s\n' hooks/cs/wrap-summary.md hooks/cs/wrap-sweep.md skills/rotate/SKILL.md)" \
        "$reads" "the files under ~/.claude that wrap.md reads" || return 1
    for p in $reads; do
        case "$p" in
            hooks/cs/*) src="$SCRIPT_DIR/../hooks/${p#hooks/cs/}" ;;
            *) src="$SCRIPT_DIR/../$p" ;;
        esac
        cmp -s "$src" "$home/.claude/$p" || { echo "  FAIL: ~/.claude/$p is not the checkout's $src"; return 1; }
    done
}

# Every path under directory $1, and each file's checksum, on stdout: two
# listings are the same only when nothing there was added, removed or
# rewritten.
_tree_listing() {  # dir
    (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort)
}

# Passes when the listing $1 (_tree_listing, taken earlier) still describes
# directory $2; otherwise prints what differs.
_assert_tree_unchanged() {  # listing, dir, message
    local now
    now=$(_tree_listing "$2")
    if [ "$1" != "$now" ]; then
        echo "  FAIL: $3"
        diff <(printf '%s\n' "$1") <(printf '%s\n' "$now") | head -20
        return 1
    fi
}

# The retired lists (RETIRED_HOOKS, RETIRED_COMMANDS, RETIRED_SKILLS) name
# files or directories inside one directory each, and install and uninstall
# join every entry onto that directory. An entry that is not a plain name
# would reach outside it, so both refuse the list, naming it and the entry,
# before they change anything. The lists are cs's own, so a scratch build
# carries the entry: $2 appended to list $1, refused as "not a $3 name".
#
# Install runs over a HOME holding what the entry could reach: the three
# directories, a user's skill, an empty directory and a file cs wrote beside
# them, and file $4 (a path under ~/.claude) with content cs wrote, when
# given. Uninstall runs over the same HOME with the binaries, a hook cs wrote
# and the status-line registration added: the first things it removes. Each
# must leave the HOME exactly as it was.
_install_and_uninstall_refuse_a_retired_entry() {  # list, entry, kind, [file under ~/.claude]
    local list="$1" entry="$2" kind="$3" outside="${4:-}"
    local repo="$TEST_TMPDIR/refused-${#entry}-repo" home="$TEST_TMPDIR/refused-${#entry}-home"
    local refusal out rc f before
    refusal="Error: $list entry '$(_bre_literal "$entry")' is not a $kind name"
    _copy_build_inputs "$repo"
    printf '%s\n' "$list+=('$entry')" >> "$repo/lib/01-manifests.sh"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    for f in install.sh bin/cs; do
        assert_eq "1" "$(grep -c "^$list+=('$(_bre_literal "$entry")')$" "$repo/$f")" "the scratch $f carries the entry '$entry'" || return 1
    done

    mkdir -p "$home/.claude/commands" "$home/.claude/hooks/cs" "$home/.claude/skills/mine" "$home/.claude/agents"
    echo "my skill" > "$home/.claude/skills/mine/SKILL.md"
    _cs_shipped_content > "$home/.claude/plugin-copy.json"
    if [ -n "$outside" ]; then
        mkdir -p "$(dirname "$home/.claude/$outside")"
        _cs_shipped_content > "$home/.claude/$outside"
    fi
    before=$(_tree_listing "$home")
    rc=0
    out=$(HOME="$home" bash "$repo/install.sh" 2>&1 < /dev/null) || rc=$?
    assert_eq "1" "$rc" "install exit status for '$entry'" || { echo "$out"; return 1; }
    assert_output_contains "$out" "$refusal" "install names the list and the entry '$entry'" || return 1
    _assert_tree_unchanged "$before" "$home" "install changes nothing for '$entry'" || return 1

    mkdir -p "$home/.local/bin"
    for f in cs cs-secrets cs-statusline cs-subagent-statusline cs-tui; do
        echo "#!/bin/sh" > "$home/.local/bin/$f"
    done
    _cs_shipped_content > "$home/.claude/hooks/cs/session-start.sh"
    jq -n --arg bin "$home/.local/bin" '{
        statusLine: {type: "command", command: "\($bin)/cs-statusline", refreshInterval: 60},
        subagentStatusLine: {type: "command", command: "\($bin)/cs-subagent-statusline"}
    }' > "$home/.claude/settings.json"
    before=$(_tree_listing "$home")
    rc=0
    out=$(printf 'y\n' | HOME="$home" "$repo/bin/cs" -uninstall 2>&1) || rc=$?
    assert_eq "1" "$rc" "uninstall exit status for '$entry'" || { echo "$out"; return 1; }
    assert_output_contains "$out" "$refusal" "uninstall names the list and the entry '$entry'" || return 1
    _assert_tree_unchanged "$before" "$home" "uninstall changes nothing for '$entry'" || return 1
}

# Runs _install_and_uninstall_refuse_a_retired_entry for each entry that
# names no file or directory in the list's directory: the empty one, '.' and
# '..', which name that directory or its parent.
_install_and_uninstall_refuse_retired_entries_that_name_nothing() {  # list, kind
    local entry
    for entry in '' '.' '..'; do
        _install_and_uninstall_refuse_a_retired_entry "$1" "$entry" "$2" || return 1
    done
}

test_install_and_uninstall_refuse_a_retired_command_with_a_path() {
    _install_and_uninstall_refuse_a_retired_entry RETIRED_COMMANDS '../x' file x
}

test_install_and_uninstall_refuse_a_retired_command_that_names_no_file() {
    _install_and_uninstall_refuse_retired_entries_that_name_nothing RETIRED_COMMANDS file
}

test_install_and_uninstall_refuse_a_retired_hook_with_a_path() {
    _install_and_uninstall_refuse_a_retired_entry RETIRED_HOOKS '../../y' file y
}

test_install_and_uninstall_refuse_a_retired_hook_that_names_no_file() {
    _install_and_uninstall_refuse_retired_entries_that_name_nothing RETIRED_HOOKS file
}

test_install_and_uninstall_refuse_a_retired_skill_with_a_path() {
    _install_and_uninstall_refuse_a_retired_entry RETIRED_SKILLS '../x' directory x/SKILL.md
}

test_install_and_uninstall_refuse_a_retired_skill_that_names_no_directory() {
    _install_and_uninstall_refuse_retired_entries_that_name_nothing RETIRED_SKILLS directory
}

# The cs mod shipped as cs-rotate before it took the name cs; a copy left
# under the old name keeps loading into every Claude Code the machine starts,
# beside the mod under its current name.
test_install_removes_the_mod_under_its_old_name() {
    local fake_home="$TEST_TMPDIR/home-oldmodname"
    mkdir -p "$fake_home/.claude/skills/cs-rotate/hooks"
    echo '{"modules":["./register.tsx"]}' > "$fake_home/.claude/skills/cs-rotate/hooks/hooks.json"
    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || {
        echo "  FAIL: install.sh exited non-zero"
        return 1
    }
    if [ -d "$fake_home/.claude/skills/cs-rotate" ]; then
        echo "  FAIL: the mod's old cs-rotate directory survived the install"
        return 1
    fi
    cmp -s "$SCRIPT_DIR/../mods/cs/hooks/register.tsx" "$fake_home/.claude/skills/cs/hooks/register.tsx" \
        || { echo "  FAIL: the mod was not deployed under ~/.claude/skills/cs"; return 1; }
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
    _cs_shipped_content > "$fake_home/.claude/hooks/cs/session-start.sh"
    echo "0.0.0" > "$fake_home/.claude/hooks/cs/.version"
    echo "release" > "$fake_home/.claude/hooks/cs/.tui-origin"
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

# An event entry with its command at the top level and no .hooks array is the
# user's, and passes through install and uninstall as it is, while cs's own
# registrations beside it are added and then stripped.
test_install_and_uninstall_keep_a_flat_shape_hook_entry() {
    local home="$TEST_TMPDIR/flat-entry-home" s rc=0 flat='[{"type":"command","command":"/usr/local/bin/notify-me"}]'
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    printf '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"Notification":%s}}\n' "$flat" > "$s"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/flat-entry.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/flat-entry.out"; return 1; }
    assert_eq "$flat" "$(jq -c '.hooks.Notification' "$s")" "install keeps the flat entry" || return 1
    assert_eq "1" "$(jq '[.hooks.SessionStart[]? | .hooks[]?.command | select(. == "~/.claude/hooks/cs/session-start.sh")] | length' "$s")" \
        "install registers cs's hooks beside it" || return 1
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/flat-entry.un" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/flat-entry.un"; return 1; }
    assert_eq "$flat" "$(jq -c '.hooks.Notification' "$s")" "uninstall keeps the flat entry" || return 1
    assert_eq "0" "$(jq '[.hooks[][] | .hooks[]?.command | select(test("hooks/cs/"))] | length' "$s")" \
        "uninstall strips every cs registration" || return 1
}

# cs's registration under each event the shape tests below use, as install
# writes it (jq -c), and the hooks-list shapes that are the user's to keep:
# no .hooks at all, then false, null, a number, a string, an object, and a
# list of hooks that are not cs's.
SESSION_START_REGISTRATION='{"hooks":[{"type":"command","command":"~/.claude/hooks/cs/session-start.sh","timeout":30}]}'
STOP_REGISTRATION='{"hooks":[{"type":"command","command":"~/.claude/hooks/cs/narrative-reminder.sh","timeout":10}]}'
USER_HOOK_SHAPES='[{"type":"command","command":"notify"},{"matcher":"a","hooks":false},{"matcher":"b","hooks":null},{"hooks":7},{"hooks":"notify"},{"hooks":{"custom":{"type":"command","command":"notify"}}},{"matcher":"c","hooks":[{"type":"command","command":"notify","timeout":5},{"type":"command","command":"log-it"}]}]'

# Runs install and then uninstall over a HOME whose settings.json holds the
# entries $3 (a JSON list, written as jq -c prints it) as the whole of event
# $2. They must come through both exactly as written and in order: after
# install the event holds them followed by $4, cs's registration there ("" for
# an event cs registers nothing under, which then holds them alone); after
# uninstall settings.json is the file it was, byte for byte. $1 names the HOME.
_install_and_uninstall_keep_hook_entries() {  # label, event, entries, cs's entry
    local home="$TEST_TMPDIR/$1-home" s rc=0 expected="$3"
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    jq -n --arg event "$2" --argjson entries "$3" '{hooks: {($event): $entries}}' > "$s"
    cp "$s" "$TEST_TMPDIR/$1.before"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/$1.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/$1.out"; return 1; }
    [ -z "$4" ] || expected="${3%]},$4]"
    assert_eq "$expected" "$(jq -c --arg event "$2" '.hooks[$event]' "$s")" \
        "install keeps the $2 entries in order, with cs's registration after them" || return 1
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/$1.un" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/$1.un"; return 1; }
    assert_eq "$(cat "$TEST_TMPDIR/$1.before")" "$(cat "$s")" \
        "uninstall leaves settings.json as it was before install" || return 1
    cmp -s "$TEST_TMPDIR/$1.before" "$s" || { echo "  FAIL: settings.json after uninstall differs from the file before install"; return 1; }
}

# A .hooks value that is not an array is the user's to shape, in an event cs
# registers too: install and uninstall pass the entry through as it is.
test_install_and_uninstall_keep_a_hooks_false_entry() {
    _install_and_uninstall_keep_hook_entries hooks-false SessionStart '[{"matcher":"startup","hooks":false}]' "$SESSION_START_REGISTRATION"
}

test_install_and_uninstall_keep_a_hooks_object_entry() {
    _install_and_uninstall_keep_hook_entries hooks-object SessionStart '[{"hooks":{"custom":{"type":"command","command":"notify"}}}]' "$SESSION_START_REGISTRATION"
}

test_install_and_uninstall_keep_a_hooks_string_entry() {
    _install_and_uninstall_keep_hook_entries hooks-string SessionStart '[{"hooks":"notify"}]' "$SESSION_START_REGISTRATION"
}

# Every shape together, in an event cs registers its own hook under (Stop)
# and in one it does not (PreToolUse): the entries keep their order and their
# keys' order.
test_install_and_uninstall_keep_every_hooks_shape_in_order() {
    _install_and_uninstall_keep_hook_entries shapes-stop Stop "$USER_HOOK_SHAPES" "$STOP_REGISTRATION"
}

test_install_and_uninstall_keep_every_hooks_shape_in_an_event_cs_registers_nothing_under() {
    _install_and_uninstall_keep_hook_entries shapes-pretooluse PreToolUse "$USER_HOOK_SHAPES" ""
}

# A hooks list may hold elements that are not objects (a string, a number,
# null, a list, false). None of them is cs's registration, so each stays where
# it is, beside the user's hook in the same list.
test_install_and_uninstall_keep_hooks_list_elements_that_are_not_objects() {
    _install_and_uninstall_keep_hook_entries hooks-elements SessionStart \
        '[{"matcher":"startup","hooks":["notify",7,null,["x"],false,{"type":"command","command":"user-start"}]}]' \
        "$SESSION_START_REGISTRATION"
}

# An event's list may hold entries that are not objects. None of them holds
# cs's registration, so each stays where it is.
test_install_and_uninstall_keep_event_entries_that_are_not_objects() {
    _install_and_uninstall_keep_hook_entries event-entries SessionStart \
        '["notify",7,null,["x"],false,{"hooks":[{"type":"command","command":"user-start"}]}]' \
        "$SESSION_START_REGISTRATION"
}

# cs's registration found beside an element that is not an object is still
# taken out of that list, and added once in its own entry.
test_install_takes_its_registration_out_of_a_hooks_list_holding_a_string() {
    local home="$TEST_TMPDIR/hooks-shared-home" s rc=0
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    printf '{"hooks":{"SessionStart":[{"hooks":["notify",%s]}]}}\n' \
        '{"type":"command","command":"~/.claude/hooks/cs/session-start.sh","timeout":5}' > "$s"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/hooks-shared.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/hooks-shared.out"; return 1; }
    assert_eq "[{\"hooks\":[\"notify\"]},$SESSION_START_REGISTRATION]" "$(jq -c '.hooks.SessionStart' "$s")" \
        "install keeps the string and registers cs once, in its own entry" || return 1
}

# Entries written into settings.json after an install: a hooks list holding a
# string under one event, a bare string under another. Uninstall still takes
# every cs registration out and leaves the two as they are.
test_uninstall_strips_cs_beside_entries_that_are_not_objects() {
    local home="$TEST_TMPDIR/strip-beside-home" s rc=0
    s="$home/.claude/settings.json"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/strip-beside.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/strip-beside.out"; return 1; }
    jq '.hooks.PreToolUse = [{"matcher":"Bash","hooks":["notify"]}] | .hooks.Notification = ["notify"]' "$s" > "$s.new" || return 1
    mv "$s.new" "$s"
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/strip-beside.un" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/strip-beside.un"; return 1; }
    assert_eq '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":["notify"]}],"Notification":["notify"]}}' "$(jq -c . "$s")" \
        "uninstall leaves only the two entries" || { cat "$TEST_TMPDIR/strip-beside.un"; return 1; }
}

# The value of an event is the user's when it is not a list. Install adds its
# own hook to ten events and cannot add it to a value like that, so it stops
# before it deploys anything, naming the event, whichever of its events holds
# the value and whatever the value is.
test_install_refuses_an_event_cs_registers_that_is_not_a_list() {
    local home s out rc before pair event value
    for pair in 'SessionStart={"custom":{"hooks":[{"type":"command","command":"user-start"}]}}' \
        'Stop=false' 'FileChanged="notify"' 'CwdChanged=7'; do
        event="${pair%%=*}" value="${pair#*=}"
        home="$TEST_TMPDIR/event-$event-home" s="$TEST_TMPDIR/event-$event-home/.claude/settings.json"
        mkdir -p "$home/.claude"
        jq -n --arg event "$event" --argjson value "$value" '{hooks: {($event): $value}}' > "$s"
        before=$(_tree_listing "$home")
        rc=0
        out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
        assert_eq "1" "$rc" "install exit status for $event" || { echo "$out"; return 1; }
        assert_output_contains "$out" \
            "Error: $(_bre_literal "$s") holds a hooks\.$event that is not a list, so cs's hook cannot be added to it; nothing was installed$" \
            "install names $event" || return 1
        _assert_tree_unchanged "$before" "$home" "install changes nothing for $event" || return 1
    done
}

# Events cs registers nothing under pass through install and uninstall as they
# are, whatever their value: an object, false, a string, a number or null.
test_install_and_uninstall_keep_events_that_are_not_lists() {
    local home="$TEST_TMPDIR/event-values-home" s rc=0 hooks
    hooks='{"PreCompact":{"custom":{"hooks":[{"type":"command","command":"user-pc"}]}},"Notification":false,"PreToolUse":"notify","SubagentStop":7,"PostCompact":null}'
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude"
    jq -n --argjson hooks "$hooks" '{hooks: $hooks}' > "$s"
    cp "$s" "$TEST_TMPDIR/event-values.before"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/event-values.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/event-values.out"; return 1; }
    assert_eq "$hooks" "$(jq -c '.hooks | with_entries(select(.key | IN("PreCompact", "Notification", "PreToolUse", "SubagentStop", "PostCompact")))' "$s")" \
        "install keeps the five events as they are" || return 1
    assert_eq "$SESSION_START_REGISTRATION" "$(jq -c '.hooks.SessionStart[]' "$s")" "install registers cs's hooks beside them" || return 1
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/event-values.un" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/event-values.un"; return 1; }
    assert_eq "$(cat "$TEST_TMPDIR/event-values.before")" "$(cat "$s")" "uninstall leaves settings.json as it was before install" || return 1
    cmp -s "$TEST_TMPDIR/event-values.before" "$s" || { echo "  FAIL: settings.json after uninstall differs from the file before install"; return 1; }
}

# An event cs registered under, turned into an object after the install, is
# the user's from then on: uninstall leaves it as it is, cs's registration
# inside it included, and still strips the events that are lists.
test_uninstall_leaves_an_event_that_is_not_a_list() {
    local home="$TEST_TMPDIR/event-object-home" s rc=0
    s="$home/.claude/settings.json"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/event-object.out" 2>&1 < /dev/null || rc=$?
    assert_eq "0" "$rc" "install exit status" || { cat "$TEST_TMPDIR/event-object.out"; return 1; }
    jq '.hooks.Stop = {custom: .hooks.Stop[0]}' "$s" > "$s.new" || return 1
    mv "$s.new" "$s"
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/event-object.un" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/event-object.un"; return 1; }
    assert_eq "{\"hooks\":{\"Stop\":{\"custom\":$STOP_REGISTRATION}}}" "$(jq -c . "$s")" \
        "uninstall leaves the object event and strips the rest" || { cat "$TEST_TMPDIR/event-object.un"; return 1; }
}

# install.sh reads CS_HOOK_EVENTS before it deploys anything, to refuse an
# event that is not a list; the events it then registers under are the rows of
# _register_cs_hooks. The two are written apart, so they are compared here.
test_hook_events_list_matches_the_registration_table() {
    local listed registered
    listed=$(bash -c '. "$1" && printf "%s\n" "${CS_HOOK_EVENTS[@]}"' _ "$SCRIPT_DIR/../lib/01-manifests.sh" 2>/dev/null | sort)
    registered=$(awk '$1 == "_merge_cs_hook" && $2 ~ /^[A-Z]/ { print $2 }' "$SCRIPT_DIR/../install.sh.in" | sort -u)
    [ -n "$registered" ] || { echo "  FAIL: no _merge_cs_hook row found in install.sh.in"; return 1; }
    assert_eq "$registered" "$listed" "CS_HOOK_EVENTS names the events _register_cs_hooks registers under" || return 1
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
    echo '{"statusLine":{"type":"command","command":"/old/path/cs-statusline","refreshInterval":1}}' \
        > "$fake_home/.claude/settings.json"
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
    # A 60 s refresh timer keeps an idle conversation's heartbeat fresh. Each
    # tick on Claude Code 2.1.286 lists every process with `ps -A`, and at one a
    # second across a dozen sessions that hit the process limit.
    local interval
    interval=$(jq -r '.statusLine.refreshInterval // ""' "$fake_home/.claude/settings.json")
    if [ "$interval" != "60" ]; then
        echo "  FAIL: enable should register refreshInterval 60 (got '$interval')"
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

# A settings.json jq cannot parse says nothing about whose status line it
# holds: disable stops, says the file is unparseable with jq's reason, and
# leaves the file byte for byte and the declined marker unwritten.
test_statusline_disable_refuses_invalid_settings_json() {
    local fake_home="$TEST_TMPDIR/home-sl-badjson" f rc=0 out
    f="$fake_home/.claude/settings.json"
    mkdir -p "$fake_home/.claude"
    printf '{"statusLine":\n' > "$f"
    cp "$f" "$TEST_TMPDIR/sl-badjson.orig"
    out=$(HOME="$fake_home" XDG_CONFIG_HOME="$fake_home/.config" "$CS_BIN" -statusline disable 2>&1) || rc=$?
    assert_eq "1" "$rc" "disable must stop on an unparseable settings.json" || { echo "$out"; return 1; }
    assert_output_contains "$out" "$(_bre_literal "$f") is not valid JSON; left it unchanged and wrote no $(_bre_literal "$f")\.cs-bak\.<stamp> backup: parse error" \
        "the error names the file and jq's reason" || return 1
    cmp -s "$TEST_TMPDIR/sl-badjson.orig" "$f" \
        || { echo "  FAIL: settings.json changed although it was refused"; return 1; }
    assert_eq "" "$(_settings_backups "$f")" "a refused file gets no backup" || return 1
    assert_file_not_exists "$fake_home/.config/cs/statusline-declined" "no decline is recorded" || return 1
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
    echo '{"statusLine":{"type":"command","command":"/old/path/cs-statusline","refreshInterval":1}}' > "$fake_home/.claude/settings.json"
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
    # The refresh writes today's registration: a 60 s timer, not the old 1 s one.
    local interval
    interval=$(jq -r '.statusLine.refreshInterval // ""' "$fake_home/.claude/settings.json")
    if [ "$interval" != "60" ]; then
        echo "  FAIL: the refresh should set refreshInterval 60 (got '$interval')"
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

# Run install.sh's WEB path against signed local release assets. Echoes the bin dir.
# The payload (raw.githubusercontent files) is served from this checkout, so
# it passes the installer's own sha256 check and the run reaches cs-tui.
# CS_TEST_SHA_FETCH=fail   -> the manifest fetch fails
# CS_TEST_SHA_TOOL=fail    -> the digest tool exists but errors, so no digest
# The home starts with the record "checkout /work/cs" unless the caller wrote
# one into $TEST_TMPDIR/tui-verify-<tag>/home first.
_install_tui_with_broken_verification() {  # tag
    local sandbox="$TEST_TMPDIR/tui-verify-$1"
    local bindir="$sandbox/stub" repo real_digest
    repo="$(cd "$SCRIPT_DIR/.." && pwd)"
    if command -v sha256sum > /dev/null 2>&1; then
        real_digest="$(command -v sha256sum)"
    else
        real_digest="$(command -v shasum) -a 256"
    fi
    mkdir -p "$bindir" "$sandbox/home/.claude/hooks/cs"
    ssh-keygen -q -t ed25519 -N '' -C release@example.com -f "$sandbox/key"
    ssh-keygen -q -t ed25519 -N '' -C other@example.com -f "$sandbox/other"
    printf 'release namespaces="cs-release-*" %s\n' "$(cat "$sandbox/key.pub")" > "$sandbox/signers"
    # The installer under test embeds the throwaway key as its trust list.
    sed "s|^CS_RELEASE_SIGNERS=.*|CS_RELEASE_SIGNERS='$(cat "$sandbox/signers")'|" "$INSTALL_SH" > "$sandbox/install.sh"
    printf 'stub-binary\n' > "$sandbox/binary"
    local asset os arch digest key="$sandbox/key"
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    [ "$arch" != x86_64 ] || arch=amd64
    asset="cs-tui-$os-$arch"
    digest=$(shasum -a 256 "$sandbox/binary" | awk '{print $1}')
    [ "${CS_TEST_MANIFEST:-}" != missing-entry ] || asset=cs-tui-other
    printf '%s  %s\n' "$digest" "$asset" > "$sandbox/SHA256SUMS"
    [ "${CS_TEST_MANIFEST:-}" != wrong-key ] || key="$sandbox/other"
    # install.sh verifies in the namespace of the release its bin/cs names.
    local namespace
    namespace="cs-release-v$(grep -m1 '^VERSION=' "$repo/bin/cs" | cut -d'"' -f2)"
    [ "${CS_TEST_MANIFEST:-}" != other-tag ] || namespace=cs-release-v0.0.0
    ssh-keygen -Y sign -f "$key" -n "$namespace" "$sandbox/SHA256SUMS" > "$sandbox/sign.log" 2>&1
    [ "${CS_TEST_MANIFEST:-}" != edited ] || printf '\n' >> "$sandbox/SHA256SUMS"
    # An earlier install's record, which only a picker this install places
    # may replace.
    [ -f "$sandbox/home/.claude/hooks/cs/.tui-origin" ] \
        || printf 'checkout /work/cs\n' > "$sandbox/home/.claude/hooks/cs/.tui-origin"

    cat > "$bindir/curl" <<STUB
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*) url="\$a" ;; esac
    prev="\$a"
done
case "\$url" in
    https://raw.githubusercontent.com/hex/claude-sessions/*)
        rel="\${url#https://raw.githubusercontent.com/hex/claude-sessions/}"
        rel="\${rel#*/}"
        [ -f "$repo/\$rel" ] || exit 22
        cp "$repo/\$rel" "\$out"
        exit 0
        ;;
    */SHA256SUMS)
        [ "\${CS_TEST_SHA_FETCH:-ok}" != fail ] || exit 22
        cp "$sandbox/SHA256SUMS" "\$out"; exit \$? ;;
    */SHA256SUMS.sig)
        [ "\${CS_TEST_MANIFEST:-}" != missing-sig ] || exit 22
        cp "$sandbox/SHA256SUMS.sig" "\$out"; exit \$? ;;
    *.sha256|*.minisig) exit 22 ;;
esac
if [ -n "\$out" ]; then
    cp "$sandbox/binary" "\$out"
fi
exit 0
STUB

    # Shadow both digest tools for the cs-tui gate, which names the file; a
    # digest of stdin (the payload check) goes to the real tool. Whichever
    # tool install.sh picks for cs-tui, it fails the same way.
    local t
    for t in sha256sum shasum; do
        cat > "$bindir/$t" <<STUB
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
if [ ! -f "\$last" ]; then
    exec $real_digest
fi
[ "\${CS_TEST_SHA_TOOL:-ok}" = "fail" ] && exit 1
exec $real_digest "\$last"
STUB
        chmod +x "$bindir/$t"
    done
    chmod +x "$bindir/curl"

    PATH="$bindir:$PATH" HOME="$sandbox/home" bash "$sandbox/install.sh" \
        > "$sandbox/install.out" 2>&1
    printf '%s' "$sandbox/home/.local/bin"
}

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
    # The picker the gate removed was never placed, so the record still
    # describes the one an earlier install put there.
    assert_eq "checkout /work/cs" "$(cat "$TEST_TMPDIR/tui-verify-fetch/home/.claude/hooks/cs/.tui-origin")" \
        "a picker the gate removed leaves the record as it was" || return 1
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

test_tui_signature_not_blamed_for_a_checksum_gate_removal() {
    CS_TEST_SHA_TOOL=fail \
        _install_tui_with_broken_verification sigblame >/dev/null
    local out
    out=$(cat "$TEST_TMPDIR/tui-verify-sigblame/install.out")
    assert_output_contains "$out" "could not be verified" \
        "the checksum gate must still say why it removed the binary" || return 1
    assert_output_not_contains "$out" "signature verification failed" \
        "must not report a signature failure for a binary already removed" || return 1
}

test_tui_requires_an_authenticated_manifest_entry() {
    local bin fault out expected
    bin=$(_install_tui_with_broken_verification authenticated)
    assert_eq 'stub-binary' "$(cat "$bin/cs-tui" 2>/dev/null)" 'signed binary must be installed' || return 1
    for fault in wrong-key other-tag edited missing-entry missing-sig; do
        bin=$(CS_TEST_MANIFEST="$fault" _install_tui_with_broken_verification "$fault")
        assert_not_exists "$bin/cs-tui" "$fault binary is removed" || return 1
        out=$(cat "$TEST_TMPDIR/tui-verify-$fault/install.out")
        case "$fault" in
            wrong-key|other-tag|edited) expected='cs-tui signature verification failed -- removed' ;;
            missing-entry) expected='cs-tui could not be verified (manifest entry or digest unavailable) -- removed' ;;
            missing-sig) expected='cs-tui could not be verified (manifest or signature unavailable) -- removed' ;;
        esac
        assert_eq "   ▲ $expected" "$(printf '%s\n' "$out" | grep -- '-- removed')" "$fault warning" || return 1
        assert_eq 'checkout /work/cs' "$(cat "$TEST_TMPDIR/tui-verify-$fault/home/.claude/hooks/cs/.tui-origin")" 'refused binary keeps origin' || return 1
    done
}

# A verified release asset is recorded as a release picker, which cs -doctor
# has no checkout to hold to.
test_web_install_records_a_release_picker() {
    local bin
    bin=$(_install_tui_with_broken_verification release)
    assert_eq "stub-binary" "$(cat "$bin/cs-tui" 2>/dev/null)" "the verified release asset is installed" \
        || { cat "$TEST_TMPDIR/tui-verify-release/install.out"; return 1; }
    assert_eq "release" "$(cat "$TEST_TMPDIR/tui-verify-release/home/.claude/hooks/cs/.tui-origin" 2>/dev/null)" \
        "the install records a release picker" || return 1
}

# A web install keeps a link at ~/.local/bin/cs-tui to content cs did not
# write, so the verified release asset is not the installed picker and the
# record stays as it was.
test_web_install_keeps_the_origin_record_of_a_linked_picker() {
    local sandbox="$TEST_TMPDIR/tui-verify-keptlink" bin
    mkdir -p "$sandbox/home/.local/bin"
    printf 'MY PICKER' > "$TEST_TMPDIR/my-web-picker"
    ln -s "$TEST_TMPDIR/my-web-picker" "$sandbox/home/.local/bin/cs-tui"
    bin=$(_install_tui_with_broken_verification keptlink)
    assert_eq "$TEST_TMPDIR/my-web-picker" "$(readlink "$bin/cs-tui")" \
        "the user's link stays in place" || { cat "$sandbox/install.out"; return 1; }
    assert_output_contains "$(cat "$sandbox/install.out")" "Kept $(_bre_literal "$bin/cs-tui")" "the kept link is named" || return 1
    assert_eq "checkout /work/cs" "$(cat "$sandbox/home/.claude/hooks/cs/.tui-origin")" \
        "the record of the kept picker stays" || return 1
}

# An install that places no picker leaves the one in place, so the record of
# where that one came from stays as it was.
test_web_install_that_places_no_picker_keeps_its_origin_record() {
    local home sandbox="$TEST_TMPDIR/web-nopicker"
    mkdir -p "$sandbox/home/.local/bin" "$sandbox/home/.claude/hooks/cs"
    printf 'picker from a checkout\n' > "$sandbox/home/.local/bin/cs-tui"
    printf 'checkout /work/cs\n' > "$sandbox/home/.claude/hooks/cs/.tui-origin"
    home=$(_web_install web-nopicker)
    assert_eq "0" "$(cat "$sandbox/install.rc")" "install exit status" || { cat "$sandbox/install.out"; return 1; }
    assert_eq "picker from a checkout" "$(cat "$home/.local/bin/cs-tui")" "no release asset: the picker stays" || return 1
    assert_eq "checkout /work/cs" "$(cat "$home/.claude/hooks/cs/.tui-origin")" "the record of that picker stays" || return 1
}

# Run install.sh's WEB path (a copy outside the checkout) under sandbox $1,
# with a stub curl that serves each raw.githubusercontent file from this
# checkout and 404s every release asset (so cs-tui is skipped). A path named
# in CS_TEST_BREAK (repo-relative, e.g. bin/cs) is served as a dropped
# transfer: half the file is written, then curl exits 18. A path named in
# CS_TEST_TAMPER is served with one line appended. Leaves the exit status in
# $sandbox/install.rc and the output in $sandbox/install.out; echoes the HOME.
_web_install() {  # sandbox-name
    local sandbox="$TEST_TMPDIR/$1" repo
    repo="$(cd "$SCRIPT_DIR/.." && pwd)"
    mkdir -p "$sandbox/stub" "$sandbox/home"
    cp "$INSTALL_SH" "$sandbox/install.sh"
    cat > "$sandbox/stub/curl" <<STUB
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*) url="\$a" ;; esac
    prev="\$a"
done
case "\$url" in
    https://raw.githubusercontent.com/hex/claude-sessions/*) ;;
    *) exit 22 ;;
esac
rel="\${url#https://raw.githubusercontent.com/hex/claude-sessions/}"
rel="\${rel#*/}"
src="$repo/\$rel"
[ -f "\$src" ] || exit 22
[ -n "\$out" ] || exit 2
if [ "\$rel" = "\${CS_TEST_BREAK:-}" ]; then
    head -c "\$(( \$(wc -c < "\$src") / 2 ))" "\$src" > "\$out"
    exit 18
fi
cp "\$src" "\$out"
if [ "\$rel" = "\${CS_TEST_TAMPER:-}" ]; then
    echo 'echo tampered' >> "\$out"
fi
exit 0
STUB
    chmod +x "$sandbox/stub/curl"
    local rc=0
    PATH="$sandbox/stub:$PATH" HOME="$sandbox/home" bash "$sandbox/install.sh" \
        > "$sandbox/install.out" 2>&1 < /dev/null || rc=$?
    printf '%s' "$rc" > "$sandbox/install.rc"
    printf '%s' "$sandbox/home"
}

# Seeds a sandbox HOME with an installed cs and a deployed /wrap command, so
# a failed web install can be checked for what it left in their place.
_seed_installed_cs() {  # home
    mkdir -p "$1/.local/bin" "$1/.claude/commands"
    printf '#!/bin/sh\necho installed cs\n' > "$1/.local/bin/cs"
    chmod 755 "$1/.local/bin/cs"
    printf 'installed wrap command\n' > "$1/.claude/commands/wrap.md"
}

# A web install whose own download of cs drops halfway fails, and the cs
# already installed is still whole: curl never writes onto ~/.local/bin/cs.
test_web_install_keeps_the_installed_cs_when_its_download_breaks() {
    local home
    _seed_installed_cs "$TEST_TMPDIR/break-cs/home"
    home=$(CS_TEST_BREAK=bin/cs _web_install break-cs)
    assert_eq "1" "$(cat "$TEST_TMPDIR/break-cs/install.rc")" "install exit status" \
        || { cat "$TEST_TMPDIR/break-cs/install.out"; return 1; }
    assert_eq "$(printf '#!/bin/sh\necho installed cs')" "$(cat "$home/.local/bin/cs")" "the installed cs is untouched" || return 1
    assert_file_contains "$TEST_TMPDIR/break-cs/install.out" "Failed to download bin/cs" "the failure names the file" || return 1
}

# Every download lands before anything is put in place, so a transfer that
# drops late in the list leaves the earlier files where they were too.
test_web_install_places_nothing_when_a_later_download_breaks() {
    local home
    _seed_installed_cs "$TEST_TMPDIR/break-late/home"
    home=$(CS_TEST_BREAK=commands/wrap.md _web_install break-late)
    assert_eq "1" "$(cat "$TEST_TMPDIR/break-late/install.rc")" "install exit status" \
        || { cat "$TEST_TMPDIR/break-late/install.out"; return 1; }
    assert_eq "$(printf '#!/bin/sh\necho installed cs')" "$(cat "$home/.local/bin/cs")" "cs is untouched" || return 1
    assert_eq "installed wrap command" "$(cat "$home/.claude/commands/wrap.md")" "the command is untouched" || return 1
    assert_file_not_exists "$home/.claude/hooks/cs/session-start.sh" "no hook was deployed" || return 1
}

# An installer read from a pipe (curl ... | bash) has no file of its own, so
# it is the web install wherever it runs: started inside another project that
# has a bin/cs, it downloads, and never installs that project's files. Here
# curl and wget both fail, so the download is the step that stops it.
test_piped_install_is_the_web_install_in_any_directory() {
    local home="$TEST_TMPDIR/piped-home" proj="$TEST_TMPDIR/someproject" shim="$TEST_TMPDIR/piped-nonet" rc=0 tool
    mkdir -p "$home/.local/bin" "$proj/bin" "$shim"
    printf '#!/bin/sh\necho installed cs\n' > "$home/.local/bin/cs"
    printf '#!/bin/sh\necho another project cs\n' > "$proj/bin/cs"
    for tool in curl wget; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 7\n' "$tool" "$shim" > "$shim/$tool"
        chmod +x "$shim/$tool"
    done
    (cd "$proj" && HOME="$home" PATH="$shim:$PATH" bash < "$INSTALL_SH") > "$TEST_TMPDIR/piped.out" 2>&1 || rc=$?
    assert_eq "1" "$rc" "install exit status" || { cat "$TEST_TMPDIR/piped.out"; return 1; }
    assert_file_contains "$TEST_TMPDIR/piped.out" "^Error: Failed to download bin/cs$" "the web install stops at its first download" || return 1
    assert_eq "$(printf '#!/bin/sh\necho installed cs')" "$(cat "$home/.local/bin/cs")" "the installed cs is untouched" || return 1
    assert_eq "curl -fsSL https://raw.githubusercontent.com/hex/claude-sessions/main/bin/cs -o" \
        "$(sed 's/ [^ ]*$//' "$shim/calls")" "the one network call is the download of bin/cs" || return 1
}

# Positive control for the two above: the same stub with nothing broken
# installs every file byte for byte, executables executable.
test_web_install_deploys_the_payload_from_the_stub() {
    local home repo
    repo="$(cd "$SCRIPT_DIR/.." && pwd)"
    home=$(_web_install web-ok)
    assert_eq "0" "$(cat "$TEST_TMPDIR/web-ok/install.rc")" "install exit status" \
        || { cat "$TEST_TMPDIR/web-ok/install.out"; return 1; }
    cmp -s "$repo/bin/cs" "$home/.local/bin/cs" || { echo "  FAIL: bin/cs differs"; return 1; }
    cmp -s "$repo/hooks/session-start.sh" "$home/.claude/hooks/cs/session-start.sh" || { echo "  FAIL: hook differs"; return 1; }
    cmp -s "$repo/commands/wrap.md" "$home/.claude/commands/wrap.md" || { echo "  FAIL: command differs"; return 1; }
    cmp -s "$repo/mods/cs/hooks/register.tsx" "$home/.claude/skills/cs/hooks/register.tsx" || { echo "  FAIL: mod differs"; return 1; }
    assert_eq "755" "$(_file_mode "$home/.local/bin/cs")" "cs mode" || return 1
    assert_eq "755" "$(_file_mode "$home/.claude/hooks/cs/cs-iterm-tab.py")" "hook library mode" || return 1
    assert_eq "755" "$(_file_mode "$home/.claude/skills/finish/scripts/finish.sh")" "skill script mode" || return 1
    assert_eq "644" "$(_file_mode "$home/.claude/commands/wrap.md")" "command mode" || return 1
    assert_eq "644" "$(_file_mode "$home/.claude/hooks/cs/wrap-sweep.md")" "wrap pass mode" || return 1
    [ -z "$(find "$home" -name '.cs-install.*')" ] || { echo "  FAIL: a staging temp file was left beside a destination"; return 1; }
}

# A web install checks every downloaded payload file against the sha256 its
# own (verified) installer carries. One file served altered stops the
# install before anything is placed.
test_web_install_refuses_a_payload_file_that_does_not_match() {
    local home
    _seed_installed_cs "$TEST_TMPDIR/tamper/home"
    home=$(CS_TEST_TAMPER=hooks/session-start.sh _web_install tamper)
    assert_eq "1" "$(cat "$TEST_TMPDIR/tamper/install.rc")" "install exit status" \
        || { cat "$TEST_TMPDIR/tamper/install.out"; return 1; }
    assert_file_contains "$TEST_TMPDIR/tamper/install.out" "hooks/session-start\.sh does not match" "the refusal names the file" || return 1
    assert_eq "$(printf '#!/bin/sh\necho installed cs')" "$(cat "$home/.local/bin/cs")" "cs is untouched" || return 1
    assert_eq "installed wrap command" "$(cat "$home/.claude/commands/wrap.md")" "the command is untouched" || return 1
    assert_file_not_exists "$home/.claude/hooks/cs/session-start.sh" "the altered hook was not deployed" || return 1
}

# Same check for the shell completions, which a web install may go without:
# an altered one is reported and skipped, and the rest installs.
test_web_install_skips_a_completion_that_does_not_match() {
    local home
    home=$(CS_TEST_TAMPER=completions/_cs _web_install tamper-comp)
    assert_eq "0" "$(cat "$TEST_TMPDIR/tamper-comp/install.rc")" "install exit status" \
        || { cat "$TEST_TMPDIR/tamper-comp/install.out"; return 1; }
    assert_file_contains "$TEST_TMPDIR/tamper-comp/install.out" "completions/_cs does not match" "the skip names the file" || return 1
    assert_file_not_exists "$home/.zsh/completions/_cs" "the altered completion was not deployed" || return 1
    cmp -s "$SCRIPT_DIR/../completions/cs.bash" "$home/.bash_completion.d/cs.bash" \
        || { echo "  FAIL: the matching bash completion was not deployed"; return 1; }
}

# The built install.sh carries, for every file a web install downloads, the
# sha256 of that file in the checkout it was built from, as
# "<sha256>  <repo path>" entries of CS_PAYLOAD_SHA256.
test_build_embeds_the_sha256_of_every_payload_file() {
    local repo="$TEST_TMPDIR/build-sha" real entry f expected actual
    real="$(cd "$SCRIPT_DIR/.." && pwd)"
    _copy_build_inputs "$repo"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    actual=$(extract_array "$repo/install.sh" CS_PAYLOAD_SHA256 | tr -d '"' | sort)
    expected=$(
        {
            printf '%s\n' bin/cs bin/cs-secrets bin/cs-statusline bin/cs-subagent-statusline \
                completions/cs.bash completions/_cs
            for entry in $(extract_array "$real/install.sh" CS_HOOK_LIBS) $(extract_array "$real/install.sh" CS_HOOKS); do
                echo "hooks/$entry"
            done
            for entry in $(extract_array "$real/install.sh" CS_COMMANDS); do echo "commands/$entry"; done
            for entry in $(extract_array "$real/install.sh" CS_SKILLS); do echo "skills/$entry/SKILL.md"; done
            for entry in $(extract_array "$real/install.sh" CS_SKILL_FILES); do echo "skills/$entry"; done
            for entry in $(extract_array "$real/install.sh" CS_MOD_FILES); do echo "mods/$entry"; done
        } | while IFS= read -r f; do
            printf '%s  %s\n' "$(shasum -a 256 < "$real/$f" | awk '{print $1}')" "$f"
        done | sort
    )
    [ -n "$actual" ] || { echo "  FAIL: install.sh carries no CS_PAYLOAD_SHA256 entries"; return 1; }
    if [ "$actual" != "$expected" ]; then
        echo "  FAIL: CS_PAYLOAD_SHA256 is not the sha256 of every payload file"
        diff <(echo "$expected") <(echo "$actual") | head -10
        return 1
    fi
    printf '%s\n' "$actual" | grep -vq '^[0-9a-f]\{64\}  [^ ]*$' \
        && { echo "  FAIL: an entry is not '<sha256>  <path>'"; return 1; }
    return 0
}

# The release asset install.sh fetches its payload from the tag it was
# released at when no CS_INSTALL_REF is given, because its sha256s describe
# that tag's files. The release workflow rewrites the one default-ref line;
# a checkout's install.sh keeps main.
test_release_workflow_pins_the_installers_default_ref() {
    local real
    real="$(cd "$SCRIPT_DIR/.." && pwd)"
    assert_eq "1" "$(grep -c '^CS_DEFAULT_REF=main$' "$real/install.sh")" "install.sh has one default-ref line" || return 1
    assert_file_contains "$real/install.sh" 'CS_INSTALL_REF:-\$CS_DEFAULT_REF' "the payload URL reads the default ref" || return 1
    # The workflow step, run here against a copy, rewrites that line to the tag.
    local copy="$TEST_TMPDIR/pin-install.sh" step
    cp "$real/install.sh" "$copy"
    step=$(grep 'CS_DEFAULT_REF=' "$real/.github/workflows/release.yml" | grep 'sed ' | head -1 | sed 's/^ *//')
    [ -n "$step" ] || { echo "  FAIL: release.yml has no step rewriting CS_DEFAULT_REF"; return 1; }
    (cd "$TEST_TMPDIR" && cp "$copy" install.sh && GITHUB_REF_NAME=v2026.99.3 \
        bash -c "${step//sed -i /sed -i.bak }" && mv install.sh "$copy") \
        || { echo "  FAIL: the workflow step failed: $step"; return 1; }
    assert_eq "1" "$(grep -c '^CS_DEFAULT_REF=v2026\.99\.3$' "$copy")" "the copy defaults to the tag" || return 1
}

# ============================================================================
# Ownership: install, update and uninstall touch only files cs wrote
# ============================================================================

# A user's own hooks, commands and skills that share a name with a file cs
# ships or once shipped are theirs: install leaves each in place, says so on
# one line naming it, and still installs everything else and exits 0.
test_install_keeps_user_files_that_share_a_cs_name() {
    local home="$TEST_TMPDIR/own-home" out rc=0 f
    mkdir -p "$home/.claude/hooks" "$home/.claude/commands" "$home/.claude/skills/feature" "$home/.claude/skills/merge"
    printf '#!/bin/sh\necho my session-start\n' > "$home/.claude/hooks/session-start.sh"
    printf '#!/bin/sh\necho my prose lint\n' > "$home/.claude/hooks/prose-lint.sh"
    printf 'my checkpoint command\n' > "$home/.claude/commands/checkpoint.md"
    printf 'my feature skill\n' > "$home/.claude/skills/feature/SKILL.md"
    printf 'my merge skill\n' > "$home/.claude/skills/merge/SKILL.md"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "$(printf '#!/bin/sh\necho my session-start')" "$(cat "$home/.claude/hooks/session-start.sh")" "flat hook kept" || return 1
    assert_eq "$(printf '#!/bin/sh\necho my prose lint')" "$(cat "$home/.claude/hooks/prose-lint.sh")" "retired-name hook kept" || return 1
    assert_eq "my checkpoint command" "$(cat "$home/.claude/commands/checkpoint.md")" "command kept" || return 1
    assert_eq "my feature skill" "$(cat "$home/.claude/skills/feature/SKILL.md")" "skill kept" || return 1
    assert_eq "my merge skill" "$(cat "$home/.claude/skills/merge/SKILL.md")" "retired-name skill kept" || return 1
    for f in hooks/session-start.sh hooks/prose-lint.sh commands/checkpoint.md skills/feature/SKILL.md skills/merge/SKILL.md; do
        assert_output_contains "$out" "$home/\.claude/$f" "a warning names $f" || return 1
    done
    # Everything that is not in the way is still installed.
    cmp -s "$SCRIPT_DIR/../commands/wrap.md" "$home/.claude/commands/wrap.md" || { echo "  FAIL: wrap.md not installed"; return 1; }
    cmp -s "$SCRIPT_DIR/../hooks/session-start.sh" "$home/.claude/hooks/cs/session-start.sh" || { echo "  FAIL: hook not installed"; return 1; }
    # The skipped paths are reported again after the completion line.
    assert_output_contains "$out" "Installation complete" "the install finished" || return 1
    printf '%s\n' "$out" | sed -n '/Installation complete/,$p' | grep -q "$home/.claude/commands/checkpoint.md" \
        || { echo "  FAIL: the skipped command is not listed after the completion line"; return 1; }
}

# A symlink where cs deploys a file is the user's unless what it points at is
# content cs wrote: a dangling link holds nothing cs wrote, so it is kept and
# named like any other file of the user's; a link to cs's own content is
# replaced by the file this install ships, and one line names the link and
# where it pointed, so a link kept for live rebuilds can be made again.
test_install_keeps_a_symlink_that_holds_no_cs_content() {
    local home="$TEST_TMPDIR/link-home" rc=0 out
    mkdir -p "$home/.claude/commands"
    ln -s "$TEST_TMPDIR/nowhere/wrap.md" "$home/.claude/commands/wrap.md"
    _cs_shipped_content > "$TEST_TMPDIR/old-checkpoint.md"
    ln -s "$TEST_TMPDIR/old-checkpoint.md" "$home/.claude/commands/checkpoint.md"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "$TEST_TMPDIR/nowhere/wrap.md" "$(readlink "$home/.claude/commands/wrap.md")" "the dangling link is kept" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.claude/commands/wrap.md")" "the kept link is named" || return 1
    [ ! -L "$home/.claude/commands/checkpoint.md" ] \
        || { echo "  FAIL: the link to cs's own content was not replaced"; return 1; }
    cmp -s "$SCRIPT_DIR/../commands/checkpoint.md" "$home/.claude/commands/checkpoint.md" \
        || { echo "  FAIL: checkpoint.md was not deployed"; return 1; }
    assert_eq '{"modules":["./register.tsx"]}' "$(cat "$TEST_TMPDIR/old-checkpoint.md")" "the link's target is untouched" || return 1
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c "Replaced symlink $(_bre_literal "$home/.claude/commands/checkpoint.md") (to $(_bre_literal "$TEST_TMPDIR/old-checkpoint.md")) with a deployed copy$")" \
        "one line names the replaced link and its target" || { echo "$out"; return 1; }
    assert_output_not_contains "$out" "Replaced symlink $(_bre_literal "$home/.claude/commands/wrap.md")" \
        "the kept link is not called replaced" || return 1
    # The binaries go through the same gate: a link to the user's own script
    # where cs-statusline goes is kept, the script untouched; a link to a copy
    # of cs's own bin/cs (a checkout's build, say) is replaced and named.
    local bin_home="$TEST_TMPDIR/link-bin-home"
    mkdir -p "$bin_home/.local/bin"
    printf '#!/bin/sh\necho my bar\n' > "$TEST_TMPDIR/my-bar.sh"
    ln -s "$TEST_TMPDIR/my-bar.sh" "$bin_home/.local/bin/cs-statusline"
    cp "$SCRIPT_DIR/../bin/cs" "$TEST_TMPDIR/build-cs"
    ln -s "$TEST_TMPDIR/build-cs" "$bin_home/.local/bin/cs"
    rc=0
    out=$(HOME="$bin_home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status (binary link)" || { echo "$out"; return 1; }
    assert_eq "$TEST_TMPDIR/my-bar.sh" "$(readlink "$bin_home/.local/bin/cs-statusline")" "the link where a binary goes is kept" || return 1
    assert_eq "$(printf '#!/bin/sh\necho my bar')" "$(cat "$TEST_TMPDIR/my-bar.sh")" "the user's script is untouched" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$bin_home/.local/bin/cs-statusline")" "the kept binary link is named" || return 1
    assert_output_not_contains "$out" "Replaced symlink $(_bre_literal "$bin_home/.local/bin/cs-statusline")" \
        "the kept binary link is not called replaced" || return 1
    [ ! -L "$bin_home/.local/bin/cs" ] || { echo "  FAIL: the link to cs's own bin/cs was not replaced"; return 1; }
    cmp -s "$SCRIPT_DIR/../bin/cs" "$bin_home/.local/bin/cs" || { echo "  FAIL: bin/cs was not deployed"; return 1; }
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c "Replaced symlink $(_bre_literal "$bin_home/.local/bin/cs") (to $(_bre_literal "$TEST_TMPDIR/build-cs")) with a deployed copy$")" \
        "one line names the replaced binary link and its target" || { echo "$out"; return 1; }
}

# A user's file under a name cs retired is not in the way of anything cs
# deploys: install names it the first time it sees that content, and stays
# quiet about it on later installs until the content changes.
test_install_names_a_kept_retired_name_file_once_per_content() {
    local home="$TEST_TMPDIR/retired-once-home" out rc=0
    mkdir -p "$home/.claude/hooks" "$home/.claude/skills/merge"
    printf '#!/bin/sh\necho my prose lint\n' > "$home/.claude/hooks/prose-lint.sh"
    printf 'my merge skill\n' > "$home/.claude/skills/merge/SKILL.md"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install failed"; return 1; }
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "second install exit status" || { echo "$out"; return 1; }
    assert_output_not_contains "$out" "$(_bre_literal "$home/.claude/hooks/prose-lint.sh")" "the retired-name hook is not named again" || return 1
    assert_output_not_contains "$out" "$(_bre_literal "$home/.claude/skills/merge/SKILL.md")" "the retired-name skill is not named again" || return 1
    assert_eq "my merge skill" "$(cat "$home/.claude/skills/merge/SKILL.md")" "the skill is still kept" || return 1
    printf 'my merge skill, edited\n' > "$home/.claude/skills/merge/SKILL.md"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "$out"; echo "  FAIL: third install failed"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.claude/skills/merge/SKILL.md")" "changed content is named again" || return 1
    assert_output_not_contains "$out" "$(_bre_literal "$home/.claude/hooks/prose-lint.sh")" "the unchanged hook stays quiet" || return 1
}

# A kept flat ~/.claude/hooks/<name> is the user's hook, and so is its
# registration: install leaves the registration of a kept file in place,
# under a current name and a retired one, and still registers cs's own copy.
test_install_keeps_the_registration_of_a_kept_flat_hook() {
    local home="$TEST_TMPDIR/flat-reg-home" rc=0 out s
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude/hooks"
    printf '#!/bin/sh\necho my session-start\n' > "$home/.claude/hooks/session-start.sh"
    printf '#!/bin/sh\necho my prose lint\n' > "$home/.claude/hooks/prose-lint.sh"
    cat > "$s" << 'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}],"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/prose-lint.sh","timeout":10}]}]}}
EOF
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/session-start.sh")] | length' "$s")" \
        "the kept flat hook's registration stays" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/prose-lint.sh")] | length' "$s")" \
        "the kept retired-name hook's registration stays" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/session-start.sh")] | length' "$s")" \
        "cs's own copy is registered" || return 1
}

# Uninstall removes only the flat hooks cs wrote, so a flat
# ~/.claude/hooks/<name> still there afterwards is the user's, and so is its
# registration: uninstall strips cs's own registrations and leaves that one.
test_uninstall_keeps_the_registration_of_a_kept_flat_hook() {
    local home="$TEST_TMPDIR/flat-unreg-home" rc=0 s
    s="$home/.claude/settings.json"
    mkdir -p "$home/.claude/hooks"
    printf '#!/bin/sh\necho my session-start\n' > "$home/.claude/hooks/session-start.sh"
    cat > "$s" << 'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]},{"hooks":[{"type":"command","command":"~/.claude/hooks/cs/session-start.sh","timeout":30}]}]}}
EOF
    printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/flat-unreg.out" 2>&1 || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { cat "$TEST_TMPDIR/flat-unreg.out"; return 1; }
    assert_file_exists "$home/.claude/hooks/session-start.sh" "the user's flat hook is kept" || return 1
    assert_eq "1" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/session-start.sh")] | length' "$s")" \
        "the kept flat hook's registration stays" || return 1
    assert_eq "0" "$(jq '[.hooks[][] | .hooks[]?.command | select(. == "~/.claude/hooks/cs/session-start.sh")] | length' "$s")" \
        "cs's own registration is stripped" || return 1
}

# The installer loads its settings helpers from the payload it verified, never
# from the deployed copy: a kept ~/.claude/hooks/cs/cs-shared.sh that cs did
# not write would otherwise run inside the installer.
test_install_never_sources_a_kept_deployed_cs_shared() {
    local home="$TEST_TMPDIR/seam-home" out rc=0
    mkdir -p "$home/.claude/hooks/cs"
    { cat "$SCRIPT_DIR/../hooks/cs-shared.sh"; printf 'touch "%s/.claude/seam-ran"\n' "$home"; } \
        > "$home/.claude/hooks/cs/cs-shared.sh"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_file_not_exists "$home/.claude/seam-ran" "the kept cs-shared.sh never ran inside the installer" || return 1
    assert_output_contains "$out" "$home/\.claude/hooks/cs/cs-shared\.sh" "the kept file is named" || return 1
    grep -q 'seam-ran' "$home/.claude/hooks/cs/cs-shared.sh" || { echo "  FAIL: the user's cs-shared.sh was replaced"; return 1; }
    assert_file_exists "$home/.claude/settings.json" "settings.json was still written" || return 1
}

# Files cs wrote are still replaced and removed by content, whatever version
# put them there: one equal to what this install ships, and one holding
# content a past cs shipped under a retired name.
test_install_replaces_files_cs_wrote_without_a_record() {
    local home="$TEST_TMPDIR/known-home" rc=0 out
    mkdir -p "$home/.claude/hooks" "$home/.claude/skills/cs-hint/hooks"
    _cs_shipped_content > "$home/.claude/hooks/session-start.sh"
    _cs_shipped_content > "$home/.claude/hooks/files-context.sh"
    _cs_shipped_content > "$home/.claude/skills/cs-hint/hooks/hooks.json"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "install exit status" || { echo "$out"; return 1; }
    assert_file_not_exists "$home/.claude/hooks/session-start.sh" "the flat copy cs wrote is removed" || return 1
    assert_file_not_exists "$home/.claude/hooks/files-context.sh" "the retired hook cs wrote is removed" || return 1
    [ ! -e "$home/.claude/skills/cs-hint" ] || { echo "  FAIL: the retired mod directory cs wrote survived"; return 1; }
}

# Install records what it wrote, and a file still matching its record is
# cs's even when no release ever shipped that content; one changed since is
# the user's and is kept.
test_install_follows_its_record() {
    local home="$TEST_TMPDIR/record-home" record digest out
    mkdir -p "$home"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: first install failed"; return 1; }
    record="$home/.claude/hooks/cs/.installed"
    assert_file_exists "$record" "install writes its record" || return 1
    digest=$(shasum -a 256 "$SCRIPT_DIR/../commands/wrap.md" | awk '{print $1}')
    assert_file_contains "$record" "^$digest  \.claude/commands/wrap\.md$" "the record holds each file's sha256" || return 1
    # A release that shipped this wrap.md would have recorded it so.
    printf 'wrap as a later release shipped it\n' > "$home/.claude/commands/wrap.md"
    digest=$(shasum -a 256 "$home/.claude/commands/wrap.md" | awk '{print $1}')
    grep -v 'commands/wrap\.md$' "$record" > "$record.tmp"
    printf '%s  .claude/commands/wrap.md\n' "$digest" >> "$record.tmp"
    mv "$record.tmp" "$record"
    # The user edits the /checkpoint command cs installed.
    printf 'my own checkpoint\n' > "$home/.claude/commands/checkpoint.md"
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || { echo "$out"; echo "  FAIL: second install failed"; return 1; }
    cmp -s "$SCRIPT_DIR/../commands/wrap.md" "$home/.claude/commands/wrap.md" \
        || { echo "  FAIL: a file matching its record was not replaced"; return 1; }
    assert_eq "my own checkpoint" "$(cat "$home/.claude/commands/checkpoint.md")" "an edited file is kept" || return 1
    assert_output_contains "$out" "$home/\.claude/commands/checkpoint\.md" "the kept file is named" || return 1
}

# An install that stops partway leaves a record true of every file: the ones
# it placed under their new sha256, the ones it never reached under the line
# the last install wrote for them.
test_install_record_holds_what_a_partial_install_placed() {
    local home="$TEST_TMPDIR/partial-home" record digest rc=0 zeros
    zeros=0000000000000000000000000000000000000000000000000000000000000000
    record="$home/.claude/hooks/cs/.installed"
    mkdir -p "$home/.claude/hooks/cs"
    printf '%s  .claude/hooks/cs/session-start.sh\n%s  .claude/skills/rotate/SKILL.md\n' "$zeros" "$zeros" > "$record"
    # A file where the commands directory goes stops the install after the
    # hooks are in place.
    : > "$home/.claude/commands"
    HOME="$home" bash "$INSTALL_SH" > "$TEST_TMPDIR/partial.out" 2>&1 < /dev/null || rc=$?
    assert_eq "1" "$rc" "the install stops at the commands directory" || { cat "$TEST_TMPDIR/partial.out"; return 1; }
    digest=$(shasum -a 256 "$SCRIPT_DIR/../hooks/session-start.sh" | awk '{print $1}')
    assert_file_contains "$record" "^$digest  \.claude/hooks/cs/session-start\.sh$" "the placed hook is recorded" || return 1
    assert_file_not_contains "$record" "^$zeros  \.claude/hooks/cs/session-start\.sh$" "its previous line is gone" || return 1
    assert_file_contains "$record" "^$zeros  \.claude/skills/rotate/SKILL\.md$" "a file never reached keeps its line" || return 1
}

# A release's files under ~/.claude stay cs's when the install record is
# gone, because the release build (build.sh --add-release-hashes) adds their
# sha256s to CS_KNOWN_SHA256. A scratch checkout whose every such file
# differs from this checkout's is built as a release and installed; path $1
# under ~/.claude, which holds the record, is deleted by hand; the next
# checkout, every such file changed again, is installed over it and replaces
# each one. hooks/cs-shared.sh is built from lib/, so it is not changed.
_install_over_a_release_after_deleting() {  # path under ~/.claude
    local repo="$TEST_TMPDIR/release-repo" home="$TEST_TMPDIR/release-home"
    local files="$TEST_TMPDIR/release-files" out rc=0 rel dest
    _copy_build_inputs "$repo"
    ( . "$repo/lib/01-manifests.sh"; _cs_payload_files ) | grep -v '^bin/' > "$files"
    while IFS= read -r rel; do
        [ "$rel" = hooks/cs-shared.sh ] || printf '\n' >> "$repo/$rel"
    done < "$files"
    (cd "$repo" && bash build.sh --add-release-hashes > /dev/null) || { echo "  FAIL: the release build failed"; return 1; }
    mkdir -p "$home"
    HOME="$home" bash "$repo/install.sh" > "$TEST_TMPDIR/release-first.out" 2>&1 < /dev/null \
        || { cat "$TEST_TMPDIR/release-first.out"; echo "  FAIL: the release install failed"; return 1; }
    assert_file_exists "$home/.claude/hooks/cs/.installed" "the release install writes its record" || return 1
    rm -rf "${home:?}/.claude/$1"
    assert_file_not_exists "$home/.claude/hooks/cs/.installed" "the record is gone" || return 1
    while IFS= read -r rel; do
        [ "$rel" = hooks/cs-shared.sh ] || printf '\n' >> "$repo/$rel"
    done < "$files"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: the next build failed"; return 1; }
    out=$(HOME="$home" bash "$repo/install.sh" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "the next install's exit status" || { echo "$out"; return 1; }
    assert_eq "0" "$(printf '%s\n' "$out" | grep -c 'Kept ')" "the next install keeps no file" \
        || { printf '%s\n' "$out" | grep 'Kept '; return 1; }
    while IFS= read -r rel; do
        case "$rel" in
            hooks/*) dest=".claude/hooks/cs/${rel#hooks/}" ;;
            commands/*) dest=".claude/commands/${rel#commands/}" ;;
            skills/*) dest=".claude/skills/${rel#skills/}" ;;
            mods/*) dest=".claude/skills/${rel#mods/}" ;;
            *) echo "  FAIL: no destination under ~/.claude for $rel"; return 1 ;;
        esac
        cmp -s "$repo/$rel" "$home/$dest" || { echo "  FAIL: ~/$dest is not the next checkout's $rel"; return 1; }
    done < "$files"
}

# The whole hooks directory goes: the hooks are deployed fresh, and the
# commands, skills and mods are replaced because the table knows them.
test_install_replaces_a_releases_files_after_its_record_is_deleted() {
    _install_over_a_release_after_deleting hooks/cs
}

# Only the record goes: the release's hooks stay in ~/.claude/hooks/cs, and
# the table is what makes them cs's too.
test_install_replaces_a_releases_files_after_only_its_record_is_deleted() {
    _install_over_a_release_after_deleting hooks/cs/.installed
}

# Uninstall removes what cs installed and nothing that only shares its name:
# a user's command, a user's skill, and a user's file inside a cs mod.
test_uninstall_removes_only_files_cs_wrote() {
    local home="$TEST_TMPDIR/own-uninstall" out
    mkdir -p "$home"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install failed"; return 1; }
    printf 'my checkpoint command\n' > "$home/.claude/commands/checkpoint.md"
    printf 'my notes\n' > "$home/.claude/skills/cs/notes.md"
    mkdir -p "$home/.claude/skills/merge" "$home/.claude/hooks"
    printf 'my merge skill\n' > "$home/.claude/skills/merge/SKILL.md"
    printf '#!/bin/sh\necho mine\n' > "$home/.claude/hooks/bash-logger.sh"
    out=$(printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall 2>&1) || { echo "$out"; echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq "my checkpoint command" "$(cat "$home/.claude/commands/checkpoint.md")" "user's command kept" || return 1
    assert_eq "my merge skill" "$(cat "$home/.claude/skills/merge/SKILL.md")" "user's retired-name skill kept" || return 1
    assert_eq "my notes" "$(cat "$home/.claude/skills/cs/notes.md")" "user's file inside the mod kept" || return 1
    assert_eq "$(printf '#!/bin/sh\necho mine')" "$(cat "$home/.claude/hooks/bash-logger.sh")" "user's flat hook kept" || return 1
    assert_file_not_exists "$home/.claude/commands/wrap.md" "cs's command removed" || return 1
    assert_file_not_exists "$home/.claude/skills/cs/hooks/register.tsx" "cs's mod file removed" || return 1
    assert_file_not_exists "$home/.claude/skills/feature/SKILL.md" "cs's skill removed" || return 1
    [ ! -e "$home/.claude/hooks/cs" ] || { echo "  FAIL: hooks/cs left behind"; return 1; }
    assert_output_contains "$out" "$home/\.claude/commands/checkpoint\.md" "the kept command is named" || return 1
    assert_output_contains "$out" "$home/\.claude/skills/cs/notes\.md" "the kept mod file is named" || return 1
}

# A FIFO where cs deploys a file is never read: reading one waits for a
# writer that never comes. Install keeps it, names it, and finishes. Output
# goes to a file and the run is bounded (_run_bounded), so a hang fails the
# test (142) rather than holding the suite.
test_install_keeps_a_fifo_at_a_deploy_path_unread() {
    local home="$TEST_TMPDIR/fifo-install-home" out rc=0
    mkdir -p "$home/.claude/commands"
    mkfifo "$home/.claude/commands/wrap.md"
    _run_bounded 60 env HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/fifo-install.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/fifo-install.out")
    assert_eq "0" "$rc" "install exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    [ -p "$home/.claude/commands/wrap.md" ] || { echo "  FAIL: the fifo is not left as it was"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.claude/commands/wrap.md"): cs did not write it, so it was not replaced" \
        "the kept fifo is named" || return 1
    cmp -s "$SCRIPT_DIR/../commands/checkpoint.md" "$home/.claude/commands/checkpoint.md" \
        || { echo "  FAIL: the commands beside the fifo were not installed"; return 1; }
}

# A FIFO inside a skill directory cs removes at uninstall is kept unread and
# named, and the uninstall finishes; the skill directory stays around it.
test_uninstall_keeps_a_fifo_in_a_skill_directory_unread() {
    local home="$TEST_TMPDIR/fifo-uninstall-home" out rc=0
    mkdir -p "$home"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install failed"; return 1; }
    mkfifo "$home/.claude/skills/rotate/pipe"
    printf 'y\n' | _run_bounded 60 env HOME="$home" "$CS_BIN" -uninstall > "$TEST_TMPDIR/fifo-uninstall.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/fifo-uninstall.out")
    assert_eq "0" "$rc" "uninstall exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    [ -p "$home/.claude/skills/rotate/pipe" ] || { echo "  FAIL: the fifo is not left as it was"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.claude/skills/rotate/pipe"): cs did not write it" \
        "the kept fifo is named" || return 1
    assert_file_not_exists "$home/.claude/skills/rotate/SKILL.md" "cs's file beside the fifo removed" || return 1
    assert_output_not_contains "$out" "Removed $(_bre_literal "$home/.claude/skills/rotate/")" \
        "the skill directory holding the fifo is not called removed" || return 1
}

# Uninstall judges each file under a skill directory by its whole name, a
# newline in it included. A directory named "x<newline>" holding a path that
# mirrors an absolute one outside ~/.claude must not make that outside file
# a candidate, even one holding content cs shipped; a cs-written file whose
# name holds a newline goes, and a user's file of that shape stays, even one
# whose path's second line is a line of the install record.
test_uninstall_judges_names_holding_a_newline_whole() {
    local home="$TEST_TMPDIR/newline-home" out rc=0 skill victim nl_dir record_line record_shaped
    mkdir -p "$home"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install failed"; return 1; }
    skill="$home/.claude/skills/feature"
    victim="$TEST_TMPDIR/checkout/hooks/session-start.sh"
    mkdir -p "$(dirname "$victim")"
    _cs_shipped_content > "$victim"
    nl_dir="$skill/x"$'\n'
    mkdir -p "$nl_dir$(dirname "$victim")"
    printf 'my mirrored file\n' > "$nl_dir$victim"
    printf 'my notes\n' > "$skill/my"$'\n'"notes.md"
    _cs_shipped_content > "$skill/old"$'\n'"name.md"
    record_line=$(grep '  \.claude/commands/wrap\.md$' "$home/.claude/hooks/cs/.installed")
    [ -n "$record_line" ] || { echo "  FAIL: the install record names no commands/wrap.md"; return 1; }
    record_shaped="$skill/y"$'\n'"$record_line"
    mkdir -p "$(dirname "$record_shaped")"
    printf 'my record-shaped file\n' > "$record_shaped"
    out=$(printf 'y\n' | HOME="$home" "$CS_BIN" -uninstall 2>&1) || rc=$?
    assert_eq "0" "$rc" "uninstall exit status" || { echo "$out"; return 1; }
    assert_eq '{"modules":["./register.tsx"]}' "$(cat "$victim" 2>/dev/null)" "the file outside ~/.claude is untouched" || return 1
    assert_eq "my mirrored file" "$(cat "$nl_dir$victim")" "the user's file under the newline-named directory is kept" || return 1
    assert_eq "my notes" "$(cat "$skill/my"$'\n'"notes.md")" "the user's newline-named file is kept" || return 1
    assert_eq "my record-shaped file" "$(cat "$record_shaped" 2>/dev/null)" "the user's file whose path ends in a record line is kept" || return 1
    assert_file_not_exists "$skill/old"$'\n'"name.md" "cs's newline-named file removed" || return 1
    assert_file_not_exists "$skill/SKILL.md" "cs's skill file removed" || return 1
}

# A path holding a newline cannot sit on one line of the install record, so a
# user's file of that shape under a retired skill directory is named on every
# install and never remembered there. Remembering it would put the path's
# second line in the record as a line of its own, and a path whose second
# line reads "<sha256>  <path>" (a directory named "notes<newline><sha256>  .claude"
# holding commands/wrap.md) would claim the file at that path for cs.
test_install_never_writes_a_path_holding_a_newline_into_the_record() {
    local home="$TEST_TMPDIR/newline-record-home" out rc=0 digest planted
    mkdir -p "$home"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: install failed"; return 1; }
    printf 'my wrap command\n' > "$home/.claude/commands/wrap.md"
    digest=$(shasum -a 256 < "$home/.claude/commands/wrap.md")
    digest="${digest%% *}"
    mkdir -p "$home/.claude/skills/merge"
    planted="$home/.claude/skills/merge/notes"$'\n'"$digest  .claude/commands/wrap.md"
    mkdir -p "$(dirname "$planted")"
    printf 'my notes\n' > "$planted"
    HOME="$home" bash "$INSTALL_SH" > /dev/null 2>&1 < /dev/null || { echo "  FAIL: second install failed"; return 1; }
    out=$(HOME="$home" bash "$INSTALL_SH" 2>&1 < /dev/null) || rc=$?
    assert_eq "0" "$rc" "third install exit status" || { echo "$out"; return 1; }
    assert_eq "0" "$(grep -cxF "$digest  .claude/commands/wrap.md" "$home/.claude/hooks/cs/.installed")" \
        "the record holds no line taken from the planted name" || return 1
    assert_eq "my wrap command" "$(cat "$home/.claude/commands/wrap.md")" "the user's command is kept" || return 1
    assert_eq "my notes" "$(cat "$planted")" "the planted file is kept" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.claude/skills/merge/notes")$" \
        "the planted file is named on every install" || return 1
}

# A link at ~/.local/bin/cs to content cs did not write is kept, and the
# version install reports and stamps is the one it installs, read from its
# own payload: reading it through the kept link, here to a FIFO, waits for a
# writer that never comes.
test_install_reads_its_version_from_the_payload_not_a_kept_link() {
    local home="$TEST_TMPDIR/version-link-home" out rc=0 version
    version=$(grep -m1 '^VERSION=' "$SCRIPT_DIR/../bin/cs" | cut -d'"' -f2)
    [ -n "$version" ] || { echo "  FAIL: bin/cs holds no VERSION line"; return 1; }
    mkdir -p "$home/.local/bin" "$home/fifos"
    mkfifo "$home/fifos/pipe"
    ln -s "$home/fifos/pipe" "$home/.local/bin/cs"
    _run_bounded 60 env HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/version-link.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/version-link.out")
    assert_eq "0" "$rc" "install exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    [ -L "$home/.local/bin/cs" ] && [ -p "$home/fifos/pipe" ] \
        || { echo "  FAIL: the link and the fifo are not left as they were"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$home/.local/bin/cs"): a symlink to content cs did not write, so it was not replaced" \
        "the kept link is named" || return 1
    assert_output_contains "$out" "Installation complete ($(_bre_literal "$version"))$" \
        "the completion line names the version installed" || return 1
    assert_eq "$version" "$(cat "$home/.claude/hooks/cs/.version")" "the hooks are stamped with the version installed" || return 1
}

# The hooks' version stamp is cs's, written as .tui-origin and the install
# record are: a temp file renamed into place, which replaces a FIFO there
# without opening it. A link there is kept and named, as _place_file keeps
# any link to content cs did not write, and so is a directory, which a rename
# would drop the stamp into.
test_install_writes_the_version_stamp_without_opening_what_is_there() {
    local home out rc version stamp
    version=$(grep -m1 '^VERSION=' "$SCRIPT_DIR/../bin/cs" | cut -d'"' -f2)
    [ -n "$version" ] || { echo "  FAIL: bin/cs holds no VERSION line"; return 1; }

    home="$TEST_TMPDIR/stamp-fifo-home"; stamp="$home/.claude/hooks/cs/.version"; rc=0
    mkdir -p "$home/.claude/hooks/cs"
    mkfifo "$stamp"
    _run_bounded 60 env HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/stamp-fifo.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/stamp-fifo.out")
    assert_eq "0" "$rc" "install over a fifo stamp: exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    [ -f "$stamp" ] && [ ! -L "$stamp" ] || { echo "  FAIL: the fifo stamp is not replaced by a file"; return 1; }
    assert_eq "$version" "$(cat "$stamp")" "the fifo is replaced by the stamp" || return 1

    home="$TEST_TMPDIR/stamp-link-home"; stamp="$home/.claude/hooks/cs/.version"; rc=0
    mkdir -p "$home/.claude/hooks/cs" "$home/fifos"
    mkfifo "$home/fifos/pipe"
    ln -s "$home/fifos/pipe" "$stamp"
    _run_bounded 60 env HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/stamp-link.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/stamp-link.out")
    assert_eq "0" "$rc" "install over a link to a fifo: exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    [ -L "$stamp" ] && [ -p "$home/fifos/pipe" ] || { echo "  FAIL: the link and the fifo are not left as they were"; return 1; }
    assert_output_contains "$out" "Kept $(_bre_literal "$stamp"): a symlink to content cs did not write, so it was not replaced" \
        "the kept link is named" || return 1

    home="$TEST_TMPDIR/stamp-dir-home"; stamp="$home/.claude/hooks/cs/.version"; rc=0
    mkdir -p "$stamp"
    _run_bounded 60 env HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/stamp-dir.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/stamp-dir.out")
    assert_eq "0" "$rc" "install over a directory stamp: exit status" || { echo "$out"; return 1; }
    assert_eq "" "$(ls -A "$stamp")" "nothing is put inside the directory" || return 1
    assert_output_contains "$out" "Kept $(_bre_literal "$stamp"): a directory, so it was not replaced" \
        "the kept directory is named" || return 1
    printf '%s\n' "$out" | sed -n '/Installation complete/,$p' | grep -q "^ *$(_bre_literal "$stamp")$" \
        || { echo "  FAIL: the kept directory is not listed at the end"; return 1; }
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


run_test test_install_asks_caps_for_a_chaining_statusline
run_test test_install_completes_when_zshrc_has_no_fpath
run_test test_install_respects_custom_fpath_dir
run_test test_manifest_arrays_in_sync
run_test test_manifest_arrays_match_repo_files
run_test test_skill_files_exist_in_repo
run_test test_mod_files_manifest_matches_the_repo
run_test test_install_deploys_the_rotate_mod_and_uninstall_removes_it
run_test test_the_cs_tips_file_has_the_shape_claude_code_reads
run_test test_install_names_the_cs_tips_file_beside_the_users_tips
run_test test_install_twice_names_the_cs_tips_file_once
run_test test_install_keeps_a_tips_file_the_user_named
run_test test_install_leaves_a_spinner_tips_override_that_is_not_an_object
run_test test_uninstall_removes_only_the_cs_tips_file
run_test test_install_leaves_out_a_cs_tips_file_the_user_took_out
run_test test_install_treats_an_emptied_cs_tips_file_as_taken_out
run_test test_install_names_no_tips_file_after_a_decline
run_test test_install_records_a_cs_tips_file_named_before_the_record
run_test test_install_keeps_the_tips_record_beside_a_tips_file_the_user_named
run_test test_install_names_no_tips_file_when_its_record_cannot_be_written
run_test test_install_reads_a_tips_record_it_cannot_parse_as_declined
run_test test_uninstall_removes_the_tips_record
run_test test_install_names_no_tips_file_it_did_not_deploy
run_test test_uninstall_keeps_a_changed_cs_tips_file_and_its_setting
run_test test_uninstall_removes_the_claude_links
run_test test_uninstall_keeps_session_data_while_a_volume_is_mounted_inside
run_test test_uninstall_keeps_session_data_when_the_mount_table_cannot_be_read
run_test test_uninstall_deletes_session_data_with_no_volume_mounted_inside
run_test test_uninstall_purges_secrets_before_removing_cs_secrets
run_test test_uninstall_refuses_to_delete_session_data_while_a_session_is_live
run_test test_uninstall_refuses_to_delete_session_data_while_a_dotted_session_is_live
run_test test_uninstall_refuses_a_live_session_even_with_a_volume_mounted_inside
run_test test_install_replaces_a_symlinked_mod_directory
run_test test_install_keeps_a_mod_directory_linked_at_the_users_files
run_test test_install_keeps_a_symlinked_skill_directory_and_writes_nothing_through_it
run_test test_strip_filters_in_sync
run_test test_install_deploys_hooks_to_cs_subdir
run_test test_install_migrates_flat_hook_layout
run_test test_install_writes_version_stamp
run_test test_uninstall_strips_hook_registrations
run_test test_install_and_uninstall_keep_a_flat_shape_hook_entry
run_test test_install_and_uninstall_keep_a_hooks_false_entry
run_test test_install_and_uninstall_keep_a_hooks_object_entry
run_test test_install_and_uninstall_keep_a_hooks_string_entry
run_test test_install_and_uninstall_keep_every_hooks_shape_in_order
run_test test_install_and_uninstall_keep_every_hooks_shape_in_an_event_cs_registers_nothing_under
run_test test_install_and_uninstall_keep_hooks_list_elements_that_are_not_objects
run_test test_install_and_uninstall_keep_event_entries_that_are_not_objects
run_test test_install_takes_its_registration_out_of_a_hooks_list_holding_a_string
run_test test_uninstall_strips_cs_beside_entries_that_are_not_objects
run_test test_install_refuses_an_event_cs_registers_that_is_not_a_list
run_test test_install_and_uninstall_keep_events_that_are_not_lists
run_test test_uninstall_leaves_an_event_that_is_not_a_list
run_test test_hook_events_list_matches_the_registration_table
run_test test_install_deploys_statusline_binary
run_test test_install_deploys_subagent_statusline_binary
run_test test_install_skips_statusline_noninteractive
run_test test_statusline_enable_registers
run_test test_statusline_disable_strips_only_ours
run_test test_statusline_disable_refuses_invalid_settings_json
run_test test_install_preserves_foreign_statusline
run_test test_uninstall_removes_statusline
run_test test_install_removes_stale_opposite_platform_tui
run_test test_tui_removed_when_checksum_cannot_be_fetched
run_test test_tui_requires_an_authenticated_manifest_entry
run_test test_tui_removed_when_digest_cannot_be_computed
run_test test_tui_signature_not_blamed_for_a_checksum_gate_removal
run_test test_web_install_records_a_release_picker
run_test test_web_install_keeps_the_origin_record_of_a_linked_picker
run_test test_web_install_that_places_no_picker_keeps_its_origin_record
run_test test_uninstall_removes_leftover_cs_tui_exe
run_test test_web_install_keeps_the_installed_cs_when_its_download_breaks
run_test test_web_install_places_nothing_when_a_later_download_breaks
run_test test_web_install_deploys_the_payload_from_the_stub
run_test test_piped_install_is_the_web_install_in_any_directory
run_test test_web_install_refuses_a_payload_file_that_does_not_match
run_test test_web_install_skips_a_completion_that_does_not_match
run_test test_build_embeds_the_sha256_of_every_payload_file
run_test test_release_workflow_pins_the_installers_default_ref
run_test test_install_keeps_user_files_that_share_a_cs_name
run_test test_install_keeps_the_registration_of_a_kept_flat_hook
run_test test_uninstall_keeps_the_registration_of_a_kept_flat_hook
run_test test_install_names_a_kept_retired_name_file_once_per_content
run_test test_install_keeps_a_symlink_that_holds_no_cs_content
run_test test_install_never_sources_a_kept_deployed_cs_shared
run_test test_install_replaces_files_cs_wrote_without_a_record
run_test test_install_follows_its_record
run_test test_install_record_holds_what_a_partial_install_placed
run_test test_install_replaces_a_releases_files_after_its_record_is_deleted
run_test test_install_replaces_a_releases_files_after_only_its_record_is_deleted
run_test test_uninstall_removes_only_files_cs_wrote
run_test test_install_keeps_a_fifo_at_a_deploy_path_unread
run_test test_uninstall_keeps_a_fifo_in_a_skill_directory_unread
run_test test_uninstall_judges_names_holding_a_newline_whole
run_test test_install_never_writes_a_path_holding_a_newline_into_the_record
run_test test_install_reads_its_version_from_the_payload_not_a_kept_link
run_test test_install_writes_the_version_stamp_without_opening_what_is_there
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

# ============================================================================
# Rotate/wrap keys: the installer offers, once per machine, to bind Ctrl+X R
# to /rotate, Ctrl+X W to /wrap, and Ctrl+X 1 / Ctrl+X 2 to the cs band's
# keys in Claude Code's keybindings.json, and replaces the Option+1 / Option+2
# bindings an older cs wrote.
# ============================================================================

# cs's blocks, as `jq -c` prints them: the two command keys in the Chat
# context, where Claude Code wants command bindings, and the two band
# chords in Global, where the cs mod reads them.
_OK_CHAT_BLOCK='{"context":"Chat","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}}'
_OK_GLOBAL_BLOCK='{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}'
_OK_CS_BLOCKS="$_OK_CHAT_BLOCK,$_OK_GLOBAL_BLOCK"

_need_expect() {
    require_tool expect
}

# Run install.sh on a pty, declining the status line so the rotate/wrap keys
# question is the only one that decides what reaches keybindings.json, and
# answering that question with the given key. Extra VAR=value arguments go to
# the installer's environment. The transcript lands in $TEST_TMPDIR/<label>.out;
# returns the installer's exit status.
_install_answering_rotate_wrap_keys() {  # label, home, answer, [VAR=value...]
    local label="$1" home="$2" ans="$3"; shift 3
    local exp="$TEST_TMPDIR/$label.exp"
    cat > "$exp" <<EXPECT
set timeout 120
log_file -noappend $TEST_TMPDIR/$label.out
spawn env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME=$home $* bash $INSTALL_SH
expect {
    -re {status line.*\[Y/n\]} { send "n"; exp_continue }
    -re {$_ROTATE_WRAP_ASK_RE} { send "$ans"; exp_continue }
    eof
}
catch wait result
exit [lindex \$result 3]
EXPECT
    expect -f "$exp" >/dev/null 2>&1
}

# 1. No keybindings.json: a yes creates it holding exactly cs's two blocks,
# Chat before Global, and the answer is recorded for the next install.
test_rotate_wrap_keys_yes_creates_the_file_with_only_cs_blocks() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-create"
    mkdir -p "$home"
    _install_answering_rotate_wrap_keys ok-create "$home" y \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_CS_BLOCKS]}" "$(jq -c . "$home/.claude/keybindings.json" 2>&1)" \
        "a new keybindings.json holds exactly cs's blocks" || return 1
    assert_eq "yes" "$(cat "$home/.config/cs/option-keys" 2>&1)" "the yes is recorded" || return 1
}

# 2. The user's existing Chat block takes the two command keys and their
# existing Global block the two chords, each beside the user's own; every
# other key is kept, and no second block of either context appears.
test_rotate_wrap_keys_merge_into_the_existing_blocks() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-merge"
    mkdir -p "$home/.claude"
    printf '%s\n' '{"$schema":"https://example.com/kb.json","bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' \
        > "$home/.claude/keybindings.json"
    _install_answering_rotate_wrap_keys ok-merge "$home" y \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"$schema":"https://example.com/kb.json","bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor","ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$home/.claude/keybindings.json" 2>&1)" \
        "the command keys join the user's Chat block, the chords their Global block, and nothing else changes" || return 1
}

# 3. A key the user already binds, in any context, is never overwritten: it is
# left as it is and named in a warning, and the other keys are still added.
test_rotate_wrap_keys_never_overwrite_a_user_binding() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-conflict"
    mkdir -p "$home/.claude"
    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit"}}]}' \
        > "$home/.claude/keybindings.json"
    _install_answering_rotate_wrap_keys ok-conflict "$home" y \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$home/.claude/keybindings.json" 2>&1)" \
        "ctrl+x r keeps the user's action and the other keys are added" || return 1
    grep -q 'ctrl+x r.*chat:submit' "$TEST_TMPDIR/ok-conflict.out" \
        || { echo "  FAIL: no warning naming ctrl+x r and its current action"; return 1; }
}

# 4. A file cs cannot read as {"bindings":[...]} is refused and left byte for
# byte as it was, with no temp file beside it, and the message names it.
test_rotate_wrap_keys_refuse_an_unparseable_file() {
    _need_expect || return $?
    local body i=0
    for body in '{"bindings": [' '{"bindings":{"alt+3":"command:x"}}'; do
        i=$((i + 1))
        local home="$TEST_TMPDIR/home-ok-bad$i" kb
        kb="$home/.claude/keybindings.json"
        mkdir -p "$home/.claude"
        printf '%s\n' "$body" > "$kb"
        cp "$kb" "$TEST_TMPDIR/bad$i.orig"
        _install_answering_rotate_wrap_keys "ok-bad$i" "$home" y \
            || { echo "  FAIL: install.sh exited non-zero on case $i"; return 1; }
        cmp -s "$TEST_TMPDIR/bad$i.orig" "$kb" \
            || { echo "  FAIL: case $i: the file was changed"; return 1; }
        grep -qF "$kb" "$TEST_TMPDIR/ok-bad$i.out" \
            || { echo "  FAIL: case $i: the refusal does not name $kb"; return 1; }
        assert_eq "$kb" "$(find "$home/.claude" -maxdepth 1 -name '*keybindings*')" \
            "case $i: no temp file is left beside it" || return 1
    done
}

# 5. A no leaves the file alone and is remembered: the next install, on a
# terminal too, does not ask again.
test_rotate_wrap_keys_decline_is_remembered() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-no" kb
    kb="$home/.claude/keybindings.json"
    mkdir -p "$home/.claude"
    printf '%s\n' '{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' > "$kb"
    cp "$kb" "$TEST_TMPDIR/no.orig"
    _install_answering_rotate_wrap_keys ok-no1 "$home" n \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    cmp -s "$TEST_TMPDIR/no.orig" "$kb" || { echo "  FAIL: a no changed the file"; return 1; }
    assert_eq "no" "$(cat "$home/.config/cs/option-keys" 2>&1)" "the no is recorded" || return 1
    grep -q 'Ctrl+X R.*\[y/n\]' "$TEST_TMPDIR/ok-no1.out" \
        || { echo "  FAIL: the first install never asked"; return 1; }
    _install_answering_rotate_wrap_keys ok-no2 "$home" y \
        || { echo "  FAIL: the second install exited non-zero"; return 1; }
    if grep -q 'Ctrl+X R.*\[y/n\]' "$TEST_TMPDIR/ok-no2.out"; then
        echo "  FAIL: the second install asked again"; return 1
    fi
    cmp -s "$TEST_TMPDIR/no.orig" "$kb" || { echo "  FAIL: the second install changed the file"; return 1; }
}

# 6. With no terminal there is no one to ask: nothing is written, nothing is
# recorded, and one line says how to be asked.
test_rotate_wrap_keys_non_interactive_writes_nothing_and_says_how() {
    local home="$TEST_TMPDIR/home-ok-pipe"
    mkdir -p "$home"
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" \
        < /dev/null > "$TEST_TMPDIR/ok-pipe.out" 2>&1 \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_file_not_exists "$home/.claude/keybindings.json" "no keybindings.json without a terminal" || return 1
    assert_file_not_exists "$home/.config/cs/option-keys" "no answer recorded without a terminal" || return 1
    assert_eq "1" "$(grep -c 'Ctrl+X R' "$TEST_TMPDIR/ok-pipe.out")" "exactly one line mentions Ctrl+X R" || return 1
    # The whole line: the installer's notes sit in the three-space gutter
    # behind a dot, like every other line it prints.
    grep -qxF '   · Rotate/wrap keys: not bound. To bind Ctrl+X R to /rotate, Ctrl+X W to /wrap and Ctrl+X 1/2 to the cs band, run cs -update in a terminal.' \
        "$TEST_TMPDIR/ok-pipe.out" || { echo "  FAIL: the hint line is missing, reworded or out of the gutter"; return 1; }
}

# 7. Installing again after a yes, with or without a terminal, changes nothing.
test_rotate_wrap_keys_reinstall_after_yes_is_idempotent() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-again" kb
    kb="$home/.claude/keybindings.json"
    mkdir -p "$home/.claude"
    printf '%s\n' '{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' > "$kb"
    _install_answering_rotate_wrap_keys ok-again1 "$home" y \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    cp "$kb" "$TEST_TMPDIR/again.after1"
    _install_answering_rotate_wrap_keys ok-again2 "$home" y \
        || { echo "  FAIL: the second install exited non-zero"; return 1; }
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" < /dev/null > /dev/null 2>&1 \
        || { echo "  FAIL: the third install exited non-zero"; return 1; }
    cmp -s "$TEST_TMPDIR/again.after1" "$kb" || { echo "  FAIL: a re-install changed the file"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Global\",\"bindings\":{\"ctrl+t\":\"app:toggleTodos\",\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\"}},$_OK_CHAT_BLOCK]}" \
        "$(jq -c . "$kb" 2>&1)" "one block per context, each key once" || return 1
}

# A keybindings.json that is not a regular file, here a link to a FIFO, is
# never read on a recorded yes: install names it as it names one of a shape
# cs cannot read, leaves it as it was, and finishes.
test_rotate_wrap_keys_leave_a_keybindings_json_that_is_not_a_regular_file_unread() {
    local home="$TEST_TMPDIR/home-fifo-keys" kb rc=0 out
    kb="$home/.claude/keybindings.json"
    mkdir -p "$home/.claude" "$home/.config/cs" "$home/fifos"
    printf 'yes\n' > "$home/.config/cs/option-keys"
    mkfifo "$home/fifos/keys"
    ln -s "$home/fifos/keys" "$kb"
    _run_bounded 60 env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" < /dev/null \
        > "$TEST_TMPDIR/fifo-keys.out" 2>&1 || rc=$?
    out=$(cat "$TEST_TMPDIR/fifo-keys.out")
    assert_eq "0" "$rc" "install exit status (142: still running after 60 s)" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Rotate/wrap keys: $(_bre_literal "$kb") is not JSON with a \"bindings\" array; left as it is\. Fix it, then run cs -update\.$" \
        "the keybindings.json link is named" || { echo "$out"; return 1; }
    [ -L "$kb" ] && [ -p "$home/fifos/keys" ] || { echo "  FAIL: the link and its fifo are not left as they were"; return 1; }
}

# 8. Uninstall takes back only keys that still hold cs's values, the chords and
# an older cs's Option+1 / Option+2 alike, keeps every user binding (an
# unbinding null included), and deletes a file it leaves holding nothing.
test_rotate_wrap_keys_uninstall_removes_only_cs_values() {
    local home="$TEST_TMPDIR/home-ok-un" kb
    kb="$home/.claude/keybindings.json"
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'yes\n' > "$home/.config/cs/option-keys"
    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x":null,"ctrl+x r":"command:rotate","ctrl+x w":"command:other","alt+1":"command:rotate","alt+2":"chat:submit"}}]}' > "$kb"
    printf 'y\n' | env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x":null,"ctrl+x w":"command:other","alt+2":"chat:submit"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "only ctrl+x r and alt+1, which held cs's values, are removed" || return 1

    local home2="$TEST_TMPDIR/home-ok-un2"
    mkdir -p "$home2/.claude"
    printf '%s\n' "{\"bindings\":[$_OK_CS_BLOCKS]}" > "$home2/.claude/keybindings.json"
    printf 'y\n' | env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home2" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_file_not_exists "$home2/.claude/keybindings.json" "a file left with no bindings is deleted" || return 1
}

# Uninstall drops any block it leaves empty, a Chat block holding only cs's
# command keys included, and keeps a Chat block that still holds the user's
# own key beside them.
test_rotate_wrap_keys_uninstall_drops_only_the_blocks_it_empties() {
    local home="$TEST_TMPDIR/home-ok-un-chat" kb
    kb="$home/.claude/keybindings.json"
    mkdir -p "$home/.claude" "$home/.config/cs"
    printf 'yes\n' > "$home/.config/cs/option-keys"
    printf '%s\n' "{\"bindings\":[$_OK_CHAT_BLOCK,{\"context\":\"Global\",\"bindings\":{\"ctrl+t\":\"app:toggleTodos\",\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\"}}]}" > "$kb"
    printf 'y\n' | env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "the emptied Chat block goes, the Global block keeps the user's key" || return 1

    local home2="$TEST_TMPDIR/home-ok-un-chat2" kb2
    kb2="$home2/.claude/keybindings.json"
    mkdir -p "$home2/.claude" "$home2/.config/cs"
    printf 'yes\n' > "$home2/.config/cs/option-keys"
    printf '%s\n' "{\"bindings\":[{\"context\":\"Chat\",\"bindings\":{\"ctrl+e\":\"chat:externalEditor\",\"ctrl+x r\":\"command:rotate\",\"ctrl+x w\":\"command:wrap\"}},$_OK_GLOBAL_BLOCK]}" > "$kb2"
    printf 'y\n' | env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home2" "$CS_BIN" -uninstall > /dev/null 2>&1 \
        || { echo "  FAIL: cs -uninstall exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}}]}' \
        "$(jq -c . "$kb2" 2>&1)" "the Chat block keeps the user's key, the emptied Global block goes" || return 1
}

# 9. CLAUDE_CONFIG_DIR moves Claude Code's config, keybindings.json included.
test_rotate_wrap_keys_follow_claude_config_dir() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-cfg" cfg="$TEST_TMPDIR/claude-cfg"
    mkdir -p "$home" "$cfg"
    _install_answering_rotate_wrap_keys ok-cfg "$home" y "CLAUDE_CONFIG_DIR=$cfg" \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_CS_BLOCKS]}" "$(jq -c . "$cfg/keybindings.json" 2>&1)" \
        "the file is written in CLAUDE_CONFIG_DIR" || return 1
    assert_file_not_exists "$home/.claude/keybindings.json" "nothing is written under ~/.claude" || return 1
}

# 10. A symlinked keybindings.json (a dotfiles manager's) is written through:
# the link stays a link, and its target takes the keys and keeps its mode.
test_rotate_wrap_keys_write_through_a_symlink() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-link" target="$TEST_TMPDIR/dotfiles/keybindings.json"
    mkdir -p "$home/.claude" "$(dirname "$target")"
    printf '%s\n' '{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}}]}' > "$target"
    chmod 600 "$target"
    ln -s "$target" "$home/.claude/keybindings.json"
    _install_answering_rotate_wrap_keys ok-link "$home" y \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    [ -L "$home/.claude/keybindings.json" ] || { echo "  FAIL: the link was replaced by a file"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Global\",\"bindings\":{\"ctrl+t\":\"app:toggleTodos\",\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\"}},$_OK_CHAT_BLOCK]}" \
        "$(jq -c . "$target" 2>&1)" "the link's target takes the keys" || return 1
    assert_eq "600" "$(_file_mode "$target")" "the target keeps its mode" || return 1
}

# 11. Inside an encrypted session CLAUDE_CONFIG_DIR is the session's
# .cs/claude-config, which every other session cannot see. The keys go to the
# shell's config dir that cs recorded in CLAUDE_SECURESTORAGE_CONFIG_DIR:
# empty selects ~/.claude, a path selects that dir.
test_rotate_wrap_keys_skip_an_encrypted_sessions_config_dir() {
    _need_expect || return $?
    local home="$TEST_TMPDIR/home-ok-enc" sess="$TEST_TMPDIR/enc-sess/.cs/claude-config"
    local cfg="$TEST_TMPDIR/claude-cfg-enc"
    mkdir -p "$home" "$sess" "$cfg"
    _install_answering_rotate_wrap_keys ok-enc "$home" y \
        "CLAUDE_CONFIG_DIR=$sess" "CLAUDE_SECURESTORAGE_CONFIG_DIR=" \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_CS_BLOCKS]}" "$(jq -c . "$home/.claude/keybindings.json" 2>&1)" \
        "an empty recorded dir writes ~/.claude/keybindings.json" || return 1
    assert_file_not_exists "$sess/keybindings.json" "nothing is written in the session's config dir" || return 1

    rm -f "$home/.config/cs/option-keys"
    _install_answering_rotate_wrap_keys ok-enc2 "$home" y \
        "CLAUDE_CONFIG_DIR=$sess" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$cfg" \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_CS_BLOCKS]}" "$(jq -c . "$cfg/keybindings.json" 2>&1)" \
        "a recorded dir takes the keys" || return 1
    assert_file_not_exists "$sess/keybindings.json" "still nothing in the session's config dir" || return 1
}

# Runs the installer with a recorded yes and no terminal over a given
# keybindings.json; the transcript lands in $TEST_TMPDIR/<label>.out.
_install_with_recorded_yes() {  # label, home, keybindings-json
    mkdir -p "$2/.claude" "$2/.config/cs"
    printf 'yes\n' > "$2/.config/cs/option-keys"
    printf '%s\n' "$3" > "$2/.claude/keybindings.json"
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$2" bash "$INSTALL_SH" \
        < /dev/null > "$TEST_TMPDIR/$1.out" 2>&1
}

# 12. A machine an older cs bound Option+1 / Option+2 on: its recorded yes is
# honoured without a terminal, cs's alt+1 and alt+2 make way for the chords,
# and every other binding stays. The one line says what was replaced.
test_rotate_wrap_keys_replace_cs_option_keys() {
    local home="$TEST_TMPDIR/home-ok-mig" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-mig "$home" '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","alt+1":"command:rotate","alt+2":"command:wrap"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor","ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "alt+1 and alt+2 are gone and the chords are bound" || return 1
    grep -qxF "   · Rotate/wrap keys: bound ctrl+x r, ctrl+x w, ctrl+x 1, ctrl+x 2 in $kb (replacing cs's alt+1, alt+2)" \
        "$TEST_TMPDIR/ok-mig.out" || { echo "  FAIL: the replacement line is missing or reworded"; return 1; }
}

# 13. Only cs's own values are taken back: an alt+1 the user binds to anything
# else stays, while cs's alt+2 goes.
test_rotate_wrap_keys_migration_keeps_a_users_alt_key() {
    local home="$TEST_TMPDIR/home-ok-mig2" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-mig2 "$home" '{"bindings":[{"context":"Global","bindings":{"alt+1":"chat:submit","alt+2":"command:wrap"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Global\",\"bindings\":{\"alt+1\":\"chat:submit\",\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\"}},$_OK_CHAT_BLOCK]}" \
        "$(jq -c . "$kb" 2>&1)" "the user's alt+1 stays, cs's alt+2 goes" || return 1
}

# 14. Claude Code waits for a chord's second key once its first is pressed, so
# binding ctrl+x r would silence a user's own bare ctrl+x. That counts as a
# conflict for every chord: the file is left as it is, one warning names the
# chords and the ctrl+x, and cs's Option+1 / Option+2 stay, as the only rotate
# and wrap keys there are. A file that already holds cs's chords beside the
# bare ctrl+x gets the same one warning.
test_rotate_wrap_keys_never_shadow_a_users_ctrl_x() {
    local home kb doc label
    for label in ok-prefix ok-prefix-bound; do
        home="$TEST_TMPDIR/home-$label"
        kb="$home/.claude/keybindings.json"
        case "$label" in
            ok-prefix) doc='{"bindings":[{"context":"Chat","bindings":{"ctrl+x":"chat:externalEditor"}},{"context":"Global","bindings":{"alt+1":"command:rotate","alt+2":"command:wrap"}}]}' ;;
            ok-prefix-bound) doc="{\"bindings\":[{\"context\":\"Chat\",\"bindings\":{\"ctrl+x\":\"chat:externalEditor\",\"ctrl+x r\":\"command:rotate\",\"ctrl+x w\":\"command:wrap\"}},$_OK_GLOBAL_BLOCK]}" ;;
        esac
        _install_with_recorded_yes "$label" "$home" "$doc" \
            || { echo "  FAIL: install.sh exited non-zero ($label)"; return 1; }
        printf '%s\n' "$doc" | cmp -s - "$kb" || { echo "  FAIL: the file was changed ($label)"; return 1; }
        grep -qF "Rotate/wrap keys: ctrl+x r, ctrl+x w, ctrl+x 1, ctrl+x 2 would shadow ctrl+x, which is bound to chat:externalEditor in $kb; left as they are." \
            "$TEST_TMPDIR/$label.out" || { echo "  FAIL: no warning naming the chords and the ctrl+x they would shadow ($label)"; return 1; }
        assert_eq "1" "$(grep -c 'would shadow' "$TEST_TMPDIR/$label.out")" "one shadow warning for the file ($label)" || return 1
    done
}

# 15. Chords already bound beside cs's alt+1 / alt+2: the install only takes
# the alt keys back, and says so.
test_rotate_wrap_keys_take_back_option_keys_beside_bound_chords() {
    local home="$TEST_TMPDIR/home-ok-left" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-left "$home" "{\"bindings\":[$_OK_CHAT_BLOCK,{\"context\":\"Global\",\"bindings\":{\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\",\"alt+1\":\"command:rotate\",\"alt+2\":\"command:wrap\"}}]}" \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_CS_BLOCKS]}" \
        "$(jq -c . "$kb" 2>&1)" "only the chords are left" || return 1
    grep -qxF "   · Rotate/wrap keys: removed cs's alt+1, alt+2 from $kb" "$TEST_TMPDIR/ok-left.out" \
        || { echo "  FAIL: the removal line is missing or reworded"; return 1; }
}

# 16. One chord taken by the user: the free chords are bound and cs's alt+1 /
# alt+2 stay, so /rotate keeps a key.
test_rotate_wrap_keys_one_conflict_keeps_option_keys() {
    local home="$TEST_TMPDIR/home-ok-half" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-half "$home" '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit"}},{"context":"Global","bindings":{"alt+1":"command:rotate","alt+2":"command:wrap"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"alt+1":"command:rotate","alt+2":"command:wrap","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "the free chords are added and the alt keys stay" || return 1
}

# 17. Keys are read the way Claude Code reads them: case, the control /
# option / opt spellings and spacing do not matter, and a null on ctrl+x
# binds nothing, so it is no conflict.
test_rotate_wrap_keys_read_keys_as_claude_code_does() {
    local home="$TEST_TMPDIR/home-ok-spell1" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-spell1 "$home" '{"bindings":[{"context":"Chat","bindings":{"Control+X":"chat:externalEditor"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero (Control+X)"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"Control+X":"chat:externalEditor"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "a bare Control+X is a conflict" || return 1

    home="$TEST_TMPDIR/home-ok-spell2"; kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-spell2 "$home" '{"bindings":[{"context":"Chat","bindings":{"Ctrl+X  R":"command:rotate"}},{"context":"Global","bindings":{"Option+1":"command:rotate","OPT+2":"command:wrap"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero (Option+1)"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"Ctrl+X  R":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "Option+1 / OPT+2 are taken back and Ctrl+X  R counts as bound" || return 1

    home="$TEST_TMPDIR/home-ok-spell3"; kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-spell3 "$home" '{"bindings":[{"context":"Global","bindings":{"ctrl+x":null}}]}' \
        || { echo "  FAIL: install.sh exited non-zero (null)"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Global\",\"bindings\":{\"ctrl+x\":null,\"ctrl+x 1\":\"strip:jump1\",\"ctrl+x 2\":\"strip:jump2\"}},$_OK_CHAT_BLOCK]}" \
        "$(jq -c . "$kb" 2>&1)" "a null ctrl+x leaves every chord free" || return 1
}

# 18. Option+1 / Option+2 stand in for Ctrl+X R and Ctrl+X W only: a band
# chord the user binds elsewhere leaves /rotate and /wrap their chords, so
# cs's dead Option keys still go, and the other keys are bound.
test_rotate_wrap_keys_band_chord_conflict_still_retires_option_keys() {
    local home="$TEST_TMPDIR/home-ok-band" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-band "$home" '{"bindings":[{"context":"Global","bindings":{"ctrl+x 1":"app:redraw","alt+1":"command:rotate","alt+2":"command:wrap"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Global\",\"bindings\":{\"ctrl+x 1\":\"app:redraw\",\"ctrl+x 2\":\"strip:jump2\"}},$_OK_CHAT_BLOCK]}" \
        "$(jq -c . "$kb" 2>&1)" "the user's ctrl+x 1 stays, the alt keys go, the free chords are bound" || return 1
    grep -qxF "   · Rotate/wrap keys: bound ctrl+x r, ctrl+x w, ctrl+x 2 in $kb (replacing cs's alt+1, alt+2)" \
        "$TEST_TMPDIR/ok-band.out" || { echo "  FAIL: the replacement line is missing or reworded"; return 1; }
}

# 19. A file an earlier cs wrote, every key in one Global block: Claude Code
# wants command bindings in the Chat context, so an install moves the two
# command keys into the user's Chat block, leaves the two chords and every
# user key where they are, and says what moved.
test_rotate_wrap_keys_move_command_keys_to_the_chat_context() {
    local home="$TEST_TMPDIR/home-ok-move" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-move "$home" '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x r":"command:rotate","ctrl+x w":"command:wrap","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor","ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "the command keys move to the Chat block; the chords and the user's keys stay" || return 1
    grep -qxF "   · Rotate/wrap keys: moved ctrl+x r, ctrl+x w to the Chat context in $kb" \
        "$TEST_TMPDIR/ok-move.out" || { echo "  FAIL: the move line is missing or reworded"; return 1; }
}

# 20. The install after the move finds every key in its context and leaves the
# file byte for byte as the move wrote it.
test_rotate_wrap_keys_move_is_idempotent() {
    local home="$TEST_TMPDIR/home-ok-move2" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-move2a "$home" '{"bindings":[{"context":"Global","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[$_OK_GLOBAL_BLOCK,$_OK_CHAT_BLOCK]}" "$(jq -c . "$kb" 2>&1)" \
        "the command keys get a Chat block of their own" || return 1
    cp "$kb" "$TEST_TMPDIR/move.after1"
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/ok-move2b.out" 2>&1 \
        || { echo "  FAIL: the second install exited non-zero"; return 1; }
    cmp -s "$TEST_TMPDIR/move.after1" "$kb" || { echo "  FAIL: the second install changed the file"; return 1; }
    if grep -q 'Rotate/wrap keys' "$TEST_TMPDIR/ok-move2b.out"; then
        echo "  FAIL: the second install reported the keys again"; return 1
    fi
}

# 21. A command key in the Global block whose Chat binding is the user's own
# is a conflict, not a move: the file is left as it is and the warning names
# the user's action.
test_rotate_wrap_keys_misplaced_key_the_user_also_binds_stays_a_conflict() {
    local home="$TEST_TMPDIR/home-ok-move-conflict" kb doc
    kb="$home/.claude/keybindings.json"
    doc='{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x r":"command:rotate","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}'
    _install_with_recorded_yes ok-move-conflict "$home" "$doc" \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    printf '%s\n' "$doc" | cmp -s - "$kb" || { echo "  FAIL: the file was changed"; return 1; }
    grep -qF "Rotate/wrap keys: ctrl+x r is already bound to chat:submit in $kb; left as it is." \
        "$TEST_TMPDIR/ok-move-conflict.out" || { echo "  FAIL: the conflict warning is missing or reworded"; return 1; }
    if grep -q 'Rotate/wrap keys: .* to the .* context' "$TEST_TMPDIR/ok-move-conflict.out"; then
        echo "  FAIL: a key in conflict was reported as moved"; return 1
    fi
}

# 22. A command key the Chat block already holds under another spelling and
# the Global block holds too: the Global copy goes, the Chat block keeps its
# one spelling and takes only the key it lacks, and the second install
# changes nothing.
test_rotate_wrap_keys_move_never_doubles_a_key_its_context_holds() {
    local home="$TEST_TMPDIR/home-ok-move-spelt" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-move-spelt "$home" '{"bindings":[{"context":"Chat","bindings":{"Ctrl+X R":"command:rotate"}},{"context":"Global","bindings":{"ctrl+x r":"command:rotate","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq '{"bindings":[{"context":"Chat","bindings":{"Ctrl+X R":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' \
        "$(jq -c . "$kb" 2>&1)" "the Chat block keeps Ctrl+X R once and gains only ctrl+x w; the Global copy goes" || return 1
    grep -qxF "   · Rotate/wrap keys: bound ctrl+x w and moved ctrl+x r to the Chat context in $kb" \
        "$TEST_TMPDIR/ok-move-spelt.out" || { echo "  FAIL: the move line is missing or reworded"; return 1; }
    cp "$kb" "$TEST_TMPDIR/move-spelt.after1"
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/ok-move-spelt2.out" 2>&1 \
        || { echo "  FAIL: the second install exited non-zero"; return 1; }
    cmp -s "$TEST_TMPDIR/move-spelt.after1" "$kb" || { echo "  FAIL: the second install changed the file"; return 1; }
}

# 23. A command key held by a later Chat block and by the Global block: the
# Global copy goes (and its block with it, emptied), the key is not added to
# the first Chat block too, the free keys land in the first Chat block and a
# Global block of their own, and the second install changes nothing.
test_rotate_wrap_keys_move_never_doubles_a_key_a_later_block_holds() {
    local home="$TEST_TMPDIR/home-ok-move-later" kb
    kb="$home/.claude/keybindings.json"
    _install_with_recorded_yes ok-move-later "$home" '{"bindings":[{"context":"Chat","bindings":{"ctrl+s":"submit"}},{"context":"Chat","bindings":{"ctrl+x r":"command:rotate"}},{"context":"Global","bindings":{"ctrl+x r":"command:rotate"}}]}' \
        || { echo "  FAIL: install.sh exited non-zero"; return 1; }
    assert_eq "{\"bindings\":[{\"context\":\"Chat\",\"bindings\":{\"ctrl+s\":\"submit\",\"ctrl+x w\":\"command:wrap\"}},{\"context\":\"Chat\",\"bindings\":{\"ctrl+x r\":\"command:rotate\"}},$_OK_GLOBAL_BLOCK]}" \
        "$(jq -c . "$kb" 2>&1)" "ctrl+x r stays in the later Chat block only; the Global block it emptied goes" || return 1
    cp "$kb" "$TEST_TMPDIR/move-later.after1"
    env -u CLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$home" bash "$INSTALL_SH" < /dev/null > "$TEST_TMPDIR/ok-move-later2.out" 2>&1 \
        || { echo "  FAIL: the second install exited non-zero"; return 1; }
    cmp -s "$TEST_TMPDIR/move-later.after1" "$kb" || { echo "  FAIL: the second install changed the file"; return 1; }
}

run_test test_install_survives_an_unwritable_declined_marker_dir
run_test test_install_previews_the_status_line_before_asking
run_test test_declining_says_permanence_on_its_own_line
run_test test_enter_declines_the_same_as_an_explicit_n
run_test test_statusline_caps_on_off_writes_the_answer_file
run_test test_statusline_disable_survives_an_unwritable_marker_dir
run_test test_marker_tests_do_not_touch_a_live_xdg_config_home
run_test test_filechanged_registration_carries_async_rewake
run_test test_rewake_labels_do_not_claim_the_wake_is_mail
run_test test_uninstall_preserves_foreign_statusline
run_test test_uninstall_removes_zsh_completion_from_detected_dir
run_test test_uninstall_removes_zsh_completion_from_default_dir
run_test test_uninstall_removes_update_cache
run_test test_install_refuses_invalid_settings_json
run_test test_install_refuses_settings_json_that_is_not_an_object
run_test test_install_refuses_a_settings_json_that_is_not_a_regular_file
run_test test_install_fills_an_empty_settings_json
run_test test_install_backs_up_settings_json_before_changing_it
run_test test_install_keeps_the_five_newest_settings_backups
run_test test_install_keeps_a_concurrent_settings_change
run_test test_uninstall_leaves_invalid_settings_json_untouched
run_test test_uninstall_leaves_settings_and_keybindings_that_are_not_regular_files_unread
run_test test_local_install_prefers_a_freshly_built_picker
run_test test_local_install_uses_bin_picker_when_nothing_was_built
run_test test_local_install_keeps_the_origin_record_of_a_linked_picker
run_test test_build_generates_the_shared_hook_fragment
run_test test_build_generates_install_sh_from_its_template
run_test test_build_refuses_a_template_without_the_marker
run_test test_build_refuses_a_missing_manifests_source
run_test test_build_outputs_are_world_readable
run_test test_release_build_adds_its_payload_to_the_known_table_once
run_test test_build_refuses_an_unknown_argument
run_test test_release_build_refuses_a_table_line_that_is_not_a_sha256
run_test test_release_build_refuses_an_empty_table
run_test test_hook_registration_doc_matches_install
run_test test_install_honors_declined_statusline_marker
run_test test_install_declined_marker_honors_xdg_and_foreign_statusline
run_test test_install_refreshes_registered_statusline_despite_marker
run_test test_statusline_disable_sets_and_enable_clears_declined_marker
run_test test_uninstall_removes_declined_marker
run_test test_install_removes_the_retired_hint_mod
run_test test_install_retires_the_bash_logger
run_test test_install_and_uninstall_keep_a_kept_retired_hook_and_its_registration
run_test test_uninstall_removes_a_cs_written_retired_hook_and_its_registration
run_test test_install_that_stops_early_keeps_a_registered_retired_hook
run_test test_install_without_jq_keeps_a_registered_retired_hook
run_test test_install_without_perl_refuses_before_changing_anything
run_test test_a_retired_hook_known_by_its_record_survives_a_run_without_jq
run_test test_a_retired_hook_replaced_during_a_question_is_kept
run_test test_a_retired_hook_replaced_by_a_link_to_a_device_is_kept_unread
run_test test_install_removes_the_mod_under_its_old_name
run_test test_install_and_uninstall_remove_retired_commands_cs_wrote
run_test test_install_deploys_wrap_and_the_passes_it_reads_but_no_pass_command
run_test test_install_and_uninstall_refuse_a_retired_command_with_a_path
run_test test_install_and_uninstall_refuse_a_retired_command_that_names_no_file
run_test test_install_and_uninstall_refuse_a_retired_hook_with_a_path
run_test test_install_and_uninstall_refuse_a_retired_hook_that_names_no_file
run_test test_install_and_uninstall_refuse_a_retired_skill_with_a_path
run_test test_install_and_uninstall_refuse_a_retired_skill_that_names_no_directory
run_test test_rotate_wrap_keys_yes_creates_the_file_with_only_cs_blocks
run_test test_rotate_wrap_keys_merge_into_the_existing_blocks
run_test test_rotate_wrap_keys_never_overwrite_a_user_binding
run_test test_rotate_wrap_keys_refuse_an_unparseable_file
run_test test_rotate_wrap_keys_decline_is_remembered
run_test test_rotate_wrap_keys_non_interactive_writes_nothing_and_says_how
run_test test_rotate_wrap_keys_reinstall_after_yes_is_idempotent
run_test test_rotate_wrap_keys_leave_a_keybindings_json_that_is_not_a_regular_file_unread
run_test test_rotate_wrap_keys_uninstall_removes_only_cs_values
run_test test_rotate_wrap_keys_uninstall_drops_only_the_blocks_it_empties
run_test test_rotate_wrap_keys_follow_claude_config_dir
run_test test_rotate_wrap_keys_write_through_a_symlink
run_test test_rotate_wrap_keys_skip_an_encrypted_sessions_config_dir
run_test test_rotate_wrap_keys_replace_cs_option_keys
run_test test_rotate_wrap_keys_migration_keeps_a_users_alt_key
run_test test_rotate_wrap_keys_never_shadow_a_users_ctrl_x
run_test test_rotate_wrap_keys_take_back_option_keys_beside_bound_chords
run_test test_rotate_wrap_keys_one_conflict_keeps_option_keys
run_test test_rotate_wrap_keys_read_keys_as_claude_code_does
run_test test_rotate_wrap_keys_band_chord_conflict_still_retires_option_keys
run_test test_rotate_wrap_keys_move_command_keys_to_the_chat_context
run_test test_rotate_wrap_keys_move_is_idempotent
run_test test_rotate_wrap_keys_misplaced_key_the_user_also_binds_stays_a_conflict
run_test test_rotate_wrap_keys_move_never_doubles_a_key_its_context_holds
run_test test_rotate_wrap_keys_move_never_doubles_a_key_a_later_block_holds
report_results
