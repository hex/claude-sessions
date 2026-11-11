#!/usr/bin/env bash
# ABOUTME: Tests that cs's git-heavy paths run the git xcrun names instead of the /usr/bin/git stub
# ABOUTME: A stand-in xcrun names a logging git; a git first on PATH or a bad answer keeps PATH's git

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A stand-in xcrun that logs each call and answers <answer> for `-f git`, and a
# logging git that runs /usr/bin/git. PATH puts them before /usr/bin, so the
# git on PATH is /usr/bin/git, the stub cs replaces.
_fake_xcrun() {  # answer
    FAKEBIN="$TEST_TMPDIR/fakebin"
    GIT_LOG="$TEST_TMPDIR/git.log"
    XCRUN_LOG="$TEST_TMPDIR/xcrun.log"
    mkdir -p "$FAKEBIN" "$TEST_TMPDIR/xcode"
    : > "$GIT_LOG"; : > "$XCRUN_LOG"
    printf '#!/bin/sh\necho "$*" >> "%s"\nexec /usr/bin/git "$@"\n' "$GIT_LOG" > "$TEST_TMPDIR/xcode/git"
    chmod +x "$TEST_TMPDIR/xcode/git"
    printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$*" = "-f git" ] || exit 1\necho "%s"\n' "$XCRUN_LOG" "$1" > "$FAKEBIN/xcrun"
    chmod +x "$FAKEBIN/xcrun"
    TEST_PATH="$FAKEBIN:/usr/bin:/bin:$PATH"
}

_need_usr_bin_git() {
    [ -x /usr/bin/git ] || { echo "    SKIP: no /usr/bin/git on this machine"; return 77; }
}

# Run <snippet> in a fresh bash (BASH_UNDER_TEST, else the first on PATH) that
# has sourced cs's shared library.
_with_shared() {  # snippet
    PATH="$TEST_PATH" "${BASH_UNDER_TEST:-bash}" -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$HOOKS_DIR/cs-shared.sh" "$1"
}

# The bashes to run a snippet under: /bin/bash (3.2 on a Mac) and the bash
# this suite runs under, when they differ.
_bashes() {
    printf '%s\n' /bin/bash
    [ "$BASH" -ef /bin/bash ] || printf '%s\n' "$BASH"
}

# With git on PATH being /usr/bin/git, _cs_use_direct_git asks xcrun once and
# every git call after it runs the git xcrun named.
test_direct_git_runs_the_git_xcrun_names() {
    _need_usr_bin_git || return $?
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    local out
    out=$(_with_shared '_cs_use_direct_git; git --version >/dev/null; v=$(git --version); echo "$v"' 2>&1) || {
        echo "  FAIL: the snippet failed: $out"; return 1; }
    assert_eq "-f git" "$(cat "$XCRUN_LOG")" "xcrun is asked once, for git" || return 1
    assert_eq "--version
--version" "$(cat "$GIT_LOG")" "both git calls, the one in a subshell too, run xcrun's git"
}

# A git someone put before /usr/bin on PATH is the one cs runs, and xcrun is
# not asked.
test_direct_git_keeps_a_git_first_on_path() {
    _need_usr_bin_git || return $?
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    printf '#!/bin/sh\necho "own $*" >> "%s"\nexec /usr/bin/git "$@"\n' "$GIT_LOG" > "$FAKEBIN/git"
    chmod +x "$FAKEBIN/git"
    local out
    out=$(_with_shared '_cs_use_direct_git; git --version >/dev/null; type -t git' 2>&1) || {
        echo "  FAIL: the snippet failed: $out"; return 1; }
    assert_eq "file" "$out" "git stays the command on PATH" || return 1
    assert_eq "" "$(cat "$XCRUN_LOG")" "xcrun is not asked" || return 1
    assert_eq "own --version" "$(cat "$GIT_LOG")" "the git first on PATH ran"
}

# An xcrun that fails, answers nothing, or names something that is not an
# executable file leaves git as PATH's /usr/bin/git.
test_direct_git_keeps_path_git_on_a_bad_answer() {
    _need_usr_bin_git || return $?
    local answer out
    mkdir -p "$TEST_TMPDIR/xcode"
    printf 'not a program\n' > "$TEST_TMPDIR/xcode/plain"
    for answer in "" "$TEST_TMPDIR/xcode/plain" "$TEST_TMPDIR/xcode" "$TEST_TMPDIR/xcode/missing" FAIL; do
        _fake_xcrun "$answer"
        [ "$answer" = FAIL ] && printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/xcrun"
        out=$(_with_shared '_cs_use_direct_git; git --version >/dev/null; type -t git' 2>&1) || {
            echo "  FAIL: the snippet failed for answer '$answer': $out"; return 1; }
        assert_eq "file" "$out" "git stays /usr/bin/git when xcrun answers '$answer'" || return 1
        assert_eq "" "$(cat "$GIT_LOG")" "no other git ran for answer '$answer'" || return 1
    done
}

# A variable set on a git call reaches the git that runs, and is gone after
# the call, under bash 3.2 and the suite's bash.
test_direct_git_passes_a_call_prefix_through() {
    _need_usr_bin_git || return $?
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    local repo="$TEST_TMPDIR/repo" b out
    git init -q "$repo"
    while IFS= read -r b; do
        out=$(cd "$TEST_TMPDIR" && BASH_UNDER_TEST="$b" _with_shared \
            "_cs_use_direct_git; GIT_DIR='$repo/.git' git rev-parse --git-dir; echo \"after=\${GIT_DIR:-}\"" 2>&1) || {
            echo "  FAIL: the snippet failed under $b: $out"; return 1; }
        assert_eq "$repo/.git
after=" "$out" "under $b the prefix reaches git and does not stay" || return 1
    done < <(_bashes)
    assert_eq "$(_bashes | sed 's/.*/rev-parse --git-dir/')" "$(cat "$GIT_LOG")" "each call ran xcrun's git"
}

# A session directory holding a git repository with one commit, made with the
# suite's own git before the stand-ins are on PATH.
_session_fixture() {
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/memory"
    (
        cd "$SESSION" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name Test
        echo "# Session narrative" > .cs/memory/narrative.md
        echo initial > README.md
        git add -A
        git commit -q -m initial
    )
}

# Run hook <name> on stdin <event> as the lead of the fixture session.
_run_hook() {  # hook event
    printf '%s\n' "$2" | env CLAUDE_SESSION_NAME=test-session CLAUDE_SESSION_DIR="$SESSION" \
        CLAUDE_SESSION_META_DIR="$SESSION/.cs" CS_TEST_SYNC=1 CS_LEAD_PID=$$ CLAUDE_PID=$$ \
        PATH="$TEST_PATH" bash "$HOOKS_DIR/$1" >/dev/null 2>&1
}

# The autosave after an edit makes its snapshot with xcrun's git.
test_autosave_runs_the_git_xcrun_names() {
    _need_usr_bin_git || return $?
    _session_fixture
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    echo "## New finding" >> "$SESSION/.cs/memory/narrative.md"
    _run_hook autosave-commits.sh '{"session_id":"22222222-2222-2222-2222-222222222222","tool_name":"Edit","tool_input":{"file_path":"'"$SESSION/.cs/memory/narrative.md"'"}}'
    assert_eq "-f git" "$(cat "$XCRUN_LOG")" "autosave asks xcrun once" || return 1
    assert_eq "1" "$(grep -c '^write-tree$' "$GIT_LOG")" "the snapshot's tree is written by xcrun's git" || return 1
    git -C "$SESSION" rev-parse -q --verify refs/worktree/cs/session/22222222-2222-2222-2222-222222222222 >/dev/null \
        || { echo "  FAIL: the autosave made no snapshot ref"; return 1; }
}

# A resumed session's start runs its git checks with xcrun's git; a /clear,
# which makes few git calls, does not ask xcrun.
test_session_start_runs_the_git_xcrun_names_on_resume_only() {
    _need_usr_bin_git || return $?
    _session_fixture
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    _run_hook session-start.sh '{"session_id":"10000000-0000-0000-0000-000000000001","source":"resume","cwd":"'"$SESSION"'","hook_event_name":"SessionStart"}'
    assert_eq "-f git" "$(cat "$XCRUN_LOG")" "a resume asks xcrun once" || return 1
    assert_eq "yes" "$(grep -qx -- "-C $SESSION rev-parse --git-dir" "$GIT_LOG" && echo yes)" "the shadow-ref check runs xcrun's git" || return 1
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    _run_hook session-start.sh '{"session_id":"10000000-0000-0000-0000-000000000001","source":"clear","cwd":"'"$SESSION"'","hook_event_name":"SessionStart"}'
    assert_eq "" "$(cat "$XCRUN_LOG")" "a /clear does not ask xcrun"
}

# Opening a session runs its git calls with xcrun's git; listing sessions does
# not ask xcrun.
test_cs_open_runs_the_git_xcrun_names() {
    _need_usr_bin_git || return $?
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    local out rc=0
    out=$(PATH="$TEST_PATH" "$CS_BIN" fresh 2>&1 </dev/null) || rc=$?
    assert_eq "0" "$rc" "cs fresh exits 0; output: $out" || return 1
    assert_eq "-f git" "$(cat "$XCRUN_LOG")" "opening a session asks xcrun once" || return 1
    [ -s "$GIT_LOG" ] || { echo "  FAIL: opening a session ran no git through xcrun's git"; return 1; }
    _fake_xcrun "$TEST_TMPDIR/xcode/git"
    PATH="$TEST_PATH" "$CS_BIN" -list >/dev/null 2>&1 </dev/null || true
    assert_eq "" "$(cat "$XCRUN_LOG")" "cs -list does not ask xcrun"
}

run_test test_direct_git_runs_the_git_xcrun_names
run_test test_autosave_runs_the_git_xcrun_names
run_test test_session_start_runs_the_git_xcrun_names_on_resume_only
run_test test_cs_open_runs_the_git_xcrun_names
run_test test_direct_git_keeps_a_git_first_on_path
run_test test_direct_git_keeps_path_git_on_a_bad_answer
run_test test_direct_git_passes_a_call_prefix_through

report_results
