#!/usr/bin/env bash
# ABOUTME: Tests for the finished-turn macOS notification: the Stop hook posts
# ABOUTME: one through terminal-notifier only when the terminal is not frontmost

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$(cd "$SCRIPT_DIR/../hooks" && pwd)"

# A session dir, the lead's identity, a terminal identity, and fakes for the
# two macOS tools first on PATH: terminal-notifier logs its argv one call per
# line, lsappinfo answers `front` with a canned ASN and `info` with whatever
# bundle id FAKE_FRONT_BUNDLE names. test_lib's setup exports CS_NO_NOTIFY=1
# for every suite; tests that expect a post unset it explicitly.
_notify_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
    export CS_LEAD_PID=4242 CLAUDE_PID=4242
    export __CFBundleIdentifier="com.googlecode.iterm2"
    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export FAKE_FRONT_BUNDLE="com.apple.Safari"
    export FAKE_BIN="$TEST_TMPDIR/fakebin"
    mkdir -p "$FAKE_BIN"
    printf '#!/bin/sh\ncat >/dev/null\necho "$@" >> "%s"\n' "$NOTIFY_LOG" > "$FAKE_BIN/terminal-notifier"
    cat > "$FAKE_BIN/lsappinfo" <<'FAKE'
#!/bin/sh
case "$1" in
    front) echo "ASN:0x0-0x1234:" ;;
    info)  printf '"CFBundleIdentifier"="%s"\n' "$FAKE_FRONT_BUNDLE" ;;
    *)     exit 1 ;;
esac
FAKE
    chmod +x "$FAKE_BIN/terminal-notifier" "$FAKE_BIN/lsappinfo"
    export PATH="$FAKE_BIN:$PATH"
}

# Each hook's exit status and stderr are kept so a negative arm can tell "did
# not post" from "died before it could": an exit 2 blocks Claude Code, and
# stderr reaches the user.
HOOK_EC=0
_hook() {  # hook-file json
    HOOK_EC=0
    echo "$2" | bash "$HOOKS_DIR/$1" >/dev/null 2>"$TEST_TMPDIR/hook.err" || HOOK_EC=$?
}
_stop() { _hook narrative-reminder.sh '{}'; }

_assert_no_post() {  # why
    if [ -f "$NOTIFY_LOG" ]; then
        echo "  FAIL: $1: $(cat "$NOTIFY_LOG")"
        return 1
    fi
    assert_eq "0" "$HOOK_EC" "the hook must exit 0 on the no-post path" || return 1
    if [ -s "$TEST_TMPDIR/hook.err" ]; then
        echo "  FAIL: the hook wrote to stderr on the no-post path: $(head -c 200 "$TEST_TMPDIR/hook.err")"
        return 1
    fi
}

test_stop_posts_when_the_terminal_is_not_frontmost() {
    _notify_session "away"
    unset CS_NO_NOTIFY
    _stop
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    local want="-group cs:away -title cs: away -message finished a turn -activate com.googlecode.iterm2"
    if ! grep -Fxq -- "$want" "$NOTIFY_LOG"; then
        echo "  FAIL: argv pin"
        echo "    want: $want"
        echo "    got:  $(cat "$NOTIFY_LOG")"
        return 1
    fi
}

test_no_post_when_the_terminal_is_frontmost() {
    _notify_session "here"
    unset CS_NO_NOTIFY
    export FAKE_FRONT_BUNDLE="com.googlecode.iterm2"
    _stop
    _assert_no_post "posted with the terminal frontmost" || return 1
}

test_terminal_identity_falls_back_to_term_program() {
    _notify_session "plain"
    unset CS_NO_NOTIFY __CFBundleIdentifier
    export TERM_PROGRAM="Apple_Terminal"
    _stop
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    grep -Fq -- "-activate com.apple.Terminal" "$NOTIFY_LOG" \
        || { echo "  FAIL: Apple_Terminal should map to its bundle id: $(cat "$NOTIFY_LOG")"; return 1; }
}

test_no_post_when_the_terminal_is_unknown() {
    _notify_session "unknown"
    unset CS_NO_NOTIFY __CFBundleIdentifier TERM_PROGRAM LC_TERMINAL
    _stop
    _assert_no_post "posted without knowing which app is the terminal" || return 1
}

test_no_post_when_the_frontmost_probe_fails() {
    _notify_session "noprobe"
    unset CS_NO_NOTIFY
    printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/lsappinfo"
    _stop
    _assert_no_post "posted although lsappinfo failed" || return 1
}

test_no_post_when_disabled() {
    _notify_session "off"
    export CS_NO_NOTIFY=1
    _stop
    _assert_no_post "CS_NO_NOTIFY must disable the notification" || return 1
}

test_no_post_from_a_teammate() {
    _notify_session "mate"
    unset CS_NO_NOTIFY CS_LEAD_PID
    _stop
    _assert_no_post "a teammate's Stop must not post" || return 1
}

test_missing_notifier_is_silent_and_harmless() {
    _notify_session "notool"
    unset CS_NO_NOTIFY
    rm -f "$FAKE_BIN/terminal-notifier"
    # Hide the developer's real one too, so the hook sees none: every PATH
    # entry holding one is replaced by a shadow of itself without it, since the
    # same directory usually holds jq and the rest the hook needs.
    local dir shadow entry newpath="" IFS=:
    for dir in $PATH; do
        entry="$dir"
        if [ -x "$dir/terminal-notifier" ]; then
            shadow="$TEST_TMPDIR/shadow$(printf '%s' "$dir" | tr / _)"
            mkdir -p "$shadow"
            for entry in "$dir"/*; do
                [ "$(basename "$entry")" = terminal-notifier ] && continue
                ln -s "$entry" "$shadow/" 2>/dev/null || true
            done
            entry="$shadow"
        fi
        newpath="${newpath:+$newpath:}$entry"
    done
    unset IFS
    export PATH="$newpath"
    command -v terminal-notifier >/dev/null 2>&1 && { echo "  FAIL: fixture: terminal-notifier still on PATH"; return 1; }
    _stop
    _assert_no_post "posted with no terminal-notifier on PATH" || return 1
}

test_prompt_hook_removes_the_notification() {
    _notify_session "back"
    unset CS_NO_NOTIFY
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    grep -Fxq -- "-remove cs:back" "$NOTIFY_LOG" \
        || { echo "  FAIL: a new prompt should remove the group: $(cat "$NOTIFY_LOG")"; return 1; }
}

test_prompt_hook_still_reads_the_prompt_after_the_remove() {
    _notify_session "stdin"
    unset CS_NO_NOTIFY
    # The fake drains stdin as the real terminal-notifier does (piped stdin is
    # message data): a hook that hands it the prompt's stdin swallows every
    # prompt in production, and a fake that ignored stdin would pass it here.
    touch "$CLAUDE_SESSION_META_DIR/local/mail/wakes" 2>/dev/null || { mkdir -p "$CLAUDE_SESSION_META_DIR/local/mail"; touch "$CLAUDE_SESSION_META_DIR/local/mail/wakes"; }
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    grep -Fxq -- "-remove cs:stdin" "$NOTIFY_LOG" || { echo "  FAIL: the remove never ran"; return 1; }
    [ ! -e "$CLAUDE_SESSION_META_DIR/local/mail/wakes" ] \
        || { echo "  FAIL: the hook lost the prompt to terminal-notifier's stdin (wake budget not reset)"; return 1; }
}

test_teammate_prompt_leaves_the_notification() {
    _notify_session "matesprompt"
    unset CS_NO_NOTIFY CS_LEAD_PID
    _hook scope-prompt.sh '{"prompt":"a message from the lead"}'
    _assert_no_post "a teammate's prompt must not remove the lead's notification" || return 1
}

test_session_start_removes_the_notification() {
    _notify_session "fresh"
    unset CS_NO_NOTIFY
    echo '{"source":"resume"}' | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    grep -Fxq -- "-remove cs:fresh" "$NOTIFY_LOG" \
        || { echo "  FAIL: session start should remove a stale group: $(cat "$NOTIFY_LOG")"; return 1; }
}

test_teammate_session_start_leaves_the_notification() {
    _notify_session "matestart"
    unset CS_NO_NOTIFY CS_LEAD_PID
    _hook session-start.sh '{"source":"startup"}'
    _assert_no_post "a teammate's start must not remove the lead's notification" || return 1
}

# A fake cs.app under the test HOME, where the installer assembles the real
# one: its binary logs argv like the PATH fake, tagged so the two can be told
# apart. Groups are per sender app, so the post and both removes must reach
# the same binary or a remove can never clear a post.
_fake_bundle() {
    export FAKE_APP="$HOME/.local/share/cs/cs.app"
    mkdir -p "$FAKE_APP/Contents/MacOS"
    printf '#!/bin/sh\ncat >/dev/null\necho "bundle $@" >> "%s"\n' "$NOTIFY_LOG" > "$FAKE_APP/Contents/MacOS/terminal-notifier"
    chmod +x "$FAKE_APP/Contents/MacOS/terminal-notifier"
}

test_post_and_removes_go_through_the_bundle_when_installed() {
    _notify_session "owl"
    unset CS_NO_NOTIFY
    _fake_bundle
    _stop
    _hook scope-prompt.sh '{"prompt":"back"}'
    _hook session-start.sh '{"source":"startup"}'
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: nothing ran"; return 1; }
    grep -Fq -- "bundle -group cs:owl -title cs: owl -message finished a turn -activate com.googlecode.iterm2" "$NOTIFY_LOG" \
        || { echo "  FAIL: the post did not go through the bundle: $(cat "$NOTIFY_LOG")"; return 1; }
    [ "$(grep -Fxc -- "bundle -remove cs:owl" "$NOTIFY_LOG")" = 2 ] \
        || { echo "  FAIL: both removes must go through the bundle: $(cat "$NOTIFY_LOG")"; return 1; }
    if grep -q '^-' "$NOTIFY_LOG"; then
        echo "  FAIL: a call reached the PATH notifier while the bundle exists: $(cat "$NOTIFY_LOG")"
        return 1
    fi
}

test_post_falls_back_to_the_path_notifier_without_the_bundle() {
    _notify_session "plainpath"
    unset CS_NO_NOTIFY
    _stop
    grep -Fxq -- "-group cs:plainpath -title cs: plainpath -message finished a turn -activate com.googlecode.iterm2" "$NOTIFY_LOG" \
        || { echo "  FAIL: argv pin without the bundle: $(cat "$NOTIFY_LOG")"; return 1; }
}

test_doctor_reports_the_notifier() {
    _notify_session "doc"
    unset CS_NO_NOTIFY
    local out
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "Notification: terminal-notifier on PATH, no cs.app bundle (no owl icon; run ./install.sh)" \
        "PATH notifier without the bundle reads as owl-less" || return 1
    _fake_bundle
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "Notification: cs.app bundle differs from the installed terminal-notifier (run ./install.sh)" \
        "a bundle whose binary is not the PATH notifier's reads as stale" || return 1
    mkdir -p "$FAKE_APP/Contents/Resources"
    shasum -a 256 "$FAKE_BIN/terminal-notifier" | cut -d' ' -f1 > "$FAKE_APP/Contents/Resources/cs-source.sha256"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "Notification: cs.app bundle active (owl icon)" \
        "a bundle recording the PATH notifier's digest reads as active" || return 1
    export CS_NO_NOTIFY=1
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "Notification: disabled (CS_NO_NOTIFY)" "the opt-out is reported" || return 1
}

# Homebrew's bin/terminal-notifier is a wrapper script beside the app; the
# installer assembles from the app's binary and records its digest, so the
# doctor must hash that binary, not the wrapper it found on PATH.
test_doctor_hashes_the_keg_app_binary_not_the_wrapper() {
    _notify_session "keg"
    unset CS_NO_NOTIFY
    local keg="$TEST_TMPDIR/keg"
    mkdir -p "$keg/bin" "$keg/terminal-notifier.app/Contents/MacOS"
    printf '#!/bin/sh\nexec "$(dirname "$0")/../terminal-notifier.app/Contents/MacOS/terminal-notifier" "$@"\n' > "$keg/bin/terminal-notifier"
    printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$keg/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    chmod +x "$keg/bin/terminal-notifier" "$keg/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    rm -f "$FAKE_BIN/terminal-notifier"
    ln -s "$keg/bin/terminal-notifier" "$FAKE_BIN/terminal-notifier"
    _fake_bundle
    mkdir -p "$FAKE_APP/Contents/Resources"
    shasum -a 256 "$keg/terminal-notifier.app/Contents/MacOS/terminal-notifier" | cut -d' ' -f1 > "$FAKE_APP/Contents/Resources/cs-source.sha256"
    local out
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "Notification: cs.app bundle active (owl icon)" \
        "the recorded digest is the keg app binary's, and the doctor hashes the same file" || return 1
}

test_uninstall_removes_the_bundle() {
    _notify_session "uninst"
    _fake_bundle
    "$CS_BIN" -uninstall <<< "y" >/dev/null 2>&1 || true
    [ ! -e "$FAKE_APP" ] || { echo "  FAIL: cs -uninstall left $FAKE_APP"; return 1; }
}

test_icon_ships_with_the_hooks() {
    grep -q '^    cs-logo.png$' "$SCRIPT_DIR/../lib/01-manifests.sh" \
        || { echo "  FAIL: cs-logo.png is not in CS_HOOK_LIBS"; return 1; }
    [ -s "$HOOKS_DIR/cs-logo.png" ] || { echo "  FAIL: hooks/cs-logo.png missing"; return 1; }
}

run_test test_stop_posts_when_the_terminal_is_not_frontmost
run_test test_no_post_when_the_terminal_is_frontmost
run_test test_terminal_identity_falls_back_to_term_program
run_test test_no_post_when_the_terminal_is_unknown
run_test test_no_post_when_the_frontmost_probe_fails
run_test test_no_post_when_disabled
run_test test_no_post_from_a_teammate
run_test test_missing_notifier_is_silent_and_harmless
run_test test_prompt_hook_removes_the_notification
run_test test_prompt_hook_still_reads_the_prompt_after_the_remove
run_test test_teammate_prompt_leaves_the_notification
run_test test_session_start_removes_the_notification
run_test test_teammate_session_start_leaves_the_notification
run_test test_post_and_removes_go_through_the_bundle_when_installed
run_test test_post_falls_back_to_the_path_notifier_without_the_bundle
run_test test_doctor_reports_the_notifier
run_test test_doctor_hashes_the_keg_app_binary_not_the_wrapper
run_test test_uninstall_removes_the_bundle
run_test test_icon_ships_with_the_hooks

report_results
