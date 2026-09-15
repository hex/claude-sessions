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
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$NOTIFY_LOG" > "$FAKE_BIN/terminal-notifier"
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

_stop() { echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true; }

_assert_no_post() {  # why
    if [ -f "$NOTIFY_LOG" ]; then
        echo "  FAIL: $1: $(cat "$NOTIFY_LOG")"
        return 1
    fi
}

test_stop_posts_when_the_terminal_is_not_frontmost() {
    _notify_session "away"
    unset CS_NO_NOTIFY
    _stop
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    local want="-group cs:away -title cs: away -message finished a turn -appIcon $HOOKS_DIR/cs-logo.png -activate com.googlecode.iterm2"
    if ! grep -Fxq -- "$want" "$NOTIFY_LOG"; then
        echo "  FAIL: argv pin"
        echo "    want: $want"
        echo "    got:  $(cat "$NOTIFY_LOG")"
        return 1
    fi
    [ -f "$HOOKS_DIR/cs-logo.png" ] || { echo "  FAIL: the icon the argv names does not exist"; return 1; }
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
    local ec=0
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || ec=$?
    assert_eq "0" "$ec" "hook must not fail when terminal-notifier is absent" || return 1
}

test_prompt_hook_removes_the_notification() {
    _notify_session "back"
    unset CS_NO_NOTIFY
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    [ -f "$NOTIFY_LOG" ] || { echo "  FAIL: terminal-notifier never ran"; return 1; }
    grep -Fxq -- "-remove cs:back" "$NOTIFY_LOG" \
        || { echo "  FAIL: a new prompt should remove the group: $(cat "$NOTIFY_LOG")"; return 1; }
}

test_teammate_prompt_leaves_the_notification() {
    _notify_session "matesprompt"
    unset CS_NO_NOTIFY CS_LEAD_PID
    echo '{"prompt":"a message from the lead"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
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
    echo '{"source":"startup"}' | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    _assert_no_post "a teammate's start must not remove the lead's notification" || return 1
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
run_test test_teammate_prompt_leaves_the_notification
run_test test_session_start_removes_the_notification
run_test test_teammate_session_start_leaves_the_notification
run_test test_icon_ships_with_the_hooks

report_results
