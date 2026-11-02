#!/usr/bin/env bash
# ABOUTME: Tests for cs <name> --remote: serving a session through claude remote-control,
# ABOUTME: with a fake claude that records argv, env names and signals (no real server).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

CS_BIN="$SCRIPT_DIR/../bin/cs"

# setup and teardown run under the suite's errexit and outside run_test's
# count, so a command failing in either would end the suite with no FAIL line
# and no Results line. SUITE_PHASE names the one running; an exit inside it
# says which command stopped the suite, counts it as a failure and still
# reports the results.
SUITE_PHASE=""
on_suite_exit() {
    local rc=$? cmd="$BASH_COMMAND"
    [ -n "$SUITE_PHASE" ] || return 0
    echo "  FAIL: $SUITE_PHASE stopped the suite at \`$cmd\` (status $rc)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$SUITE_PHASE")
    SUITE_PHASE=""
    report_results
    exit 1
}
trap on_suite_exit EXIT

# A teardown step that failed without stopping the suite: said, and counted.
teardown_failed() {  # what
    echo "  FAIL: $SUITE_PHASE: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$SUITE_PHASE")
}

# The fake claude. --version prints "FAKE_CLAUDE_VERSION (Claude Code)", as
# Claude Code does, or FAKE_CLAUDE_VERSION_LINE as it is when that is set, and
# exits FAKE_CLAUDE_VERSION_EXIT (0 by default). Any other call appends
# what it was given to $FAKE_CLAUDE_LOG: argv, which cs variables are set (the
# names only, never a value), its cwd, its pid and parent, and what the session
# lock and .cs/local/remote.pid held when it started. FAKE_CLAUDE_MODE then
# picks how it ends:
#   exit:<n>  print an error line to stderr when n is not 0, exit n at once
#   serve     say "ready" on $FAKE_READY_FIFO, then wait for a signal; HUP,
#             INT and TERM are logged and end it with 0, as the real server
#             does; with no signal in 120 s it exits 9, so a run that
#             loses its server never hangs the suite. When FAKE_CLOUD_SESSION
#             names a script, the server first runs it to its end as a child,
#             as a conversation it starts, with the server's environment.
write_fake_claude() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/claude" << 'FAKE'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' "${FAKE_CLAUDE_VERSION_LINE:-${FAKE_CLAUDE_VERSION:-2.1.299} (Claude Code)}"
    exit "${FAKE_CLAUDE_VERSION_EXIT:-0}"
fi
log="$FAKE_CLAUDE_LOG"
meta="${CLAUDE_SESSION_META_DIR:-}"
{
    printf 'bin=%s\n' "$0"
    printf 'argv='; printf '[%s]' "$@"; printf '\n'
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY+present}"
    printf 'CLAUDE_SESSION_NAME=%s\n' "${CLAUDE_SESSION_NAME:+set}"
    printf 'CLAUDE_SESSION_DIR=%s\n' "${CLAUDE_SESSION_DIR:+set}"
    printf 'CLAUDE_SESSION_META_DIR=%s\n' "${CLAUDE_SESSION_META_DIR:+set}"
    printf 'CLAUDE_CODE_TASK_LIST_ID=%s\n' "${CLAUDE_CODE_TASK_LIST_ID:+set}"
    printf 'CLAUDE_COWORK_MEMORY_PATH_OVERRIDE=%s\n' "${CLAUDE_COWORK_MEMORY_PATH_OVERRIDE:+set}"
    printf 'CS_LEAD_PID=%s\n' "${CS_LEAD_PID:+set}"
    printf 'CS_REMOTE_WINDOW=%s\n' "${CS_REMOTE_WINDOW+present}"
    printf 'CS_UNATTENDED=%s\n' "${CS_UNATTENDED+present}"
    printf 'pwd=%s\n' "$(pwd -P)"
    printf 'pid=%s\n' "$$"
    printf 'ppid=%s\n' "$(ps -o ppid= -p $$ | tr -d ' ')"
    printf 'lock=%s\n' "$(cat "$meta/session.lock" 2>/dev/null)"
    printf 'remote_pid=%s\n' "$(cat "$meta/local/remote.pid" 2>/dev/null)"
} >> "$log"
mode="${FAKE_CLAUDE_MODE:-exit:0}"
case "$mode" in
    exit:*)
        n="${mode#exit:}"
        [ "$n" = 0 ] || echo "Error: You must be logged in to use Remote Control." >&2
        exit "$n"
        ;;
    serve)
        # Waits in the read builtin on a fifo nobody writes, not on a child:
        # a child in the same process group takes the signal too, and its
        # death could end the wait before the trap ran.
        on_signal() { echo "signal $1" >> "$log"; exit 0; }
        trap 'on_signal HUP' HUP
        trap 'on_signal INT' INT
        trap 'on_signal TERM' TERM
        [ -z "${FAKE_CLOUD_SESSION:-}" ] || bash "$FAKE_CLOUD_SESSION"
        mkfifo "$FAKE_READY_FIFO.hold"
        exec 4<>"$FAKE_READY_FIFO.hold"
        printf 'ready\n' > "$FAKE_READY_FIFO"
        read -t 120 -u 4 _ || true
        echo "no signal" >> "$log"
        exit 9
        ;;
esac
FAKE
    chmod +x "$TEST_TMPDIR/bin/claude"
}

# Recording tmux: one line of argv per call; new-session prints a window id.
write_fake_tmux() {
    export CS_TMUX_BIN="$TEST_TMPDIR/fake-tmux"
    cat > "$CS_TMUX_BIN" << 'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
case "$1" in
    has-session) exit 1 ;;
    new-session) case "$*" in *" -P "*) echo '@0' ;; esac ;;
esac
exit 0
FAKE
    chmod +x "$CS_TMUX_BIN"
}

setup() {
    # test_name is run_test's local, visible here because bash scopes
    # dynamically.
    SUITE_PHASE="setup of ${test_name:-a test}"
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$CS_CLAUDE_DIR"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    export FAKE_CLAUDE_LOG="$TEST_TMPDIR/claude.log"
    export FAKE_TMUX_LOG="$TEST_TMPDIR/tmux.log"
    export FAKE_WRAPPER_LOG="$TEST_TMPDIR/wrapper.log"
    export FAKE_READY_FIFO="$TEST_TMPDIR/ready"
    write_fake_claude
    write_fake_tmux
    export PATH="$TEST_TMPDIR/bin:$PATH"
    export CLAUDE_CODE_BIN="claude"
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_VERSION FAKE_CLOUD_SESSION ANTHROPIC_API_KEY CS_REMOTE_WINDOW TMUX 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_TERM_THEME CS_TERM_BG_RGB 2>/dev/null || true
    SERVE_PID=""
    STARTED_PIDS=""
    SUITE_PHASE=""
}

# Stops only what the test started: the serving process group, and the
# processes it recorded in STARTED_PIDS. The serving group holds the release
# cs leaves beside the server, so the session is removed only once that group
# is empty.
teardown() {
    SUITE_PHASE="teardown of ${test_name:-a test}"
    if [ -n "${SERVE_PID:-}" ]; then
        kill -TERM -- -"$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
        group_gone_within_10s "$SERVE_PID" \
            || { kill -KILL -- -"$SERVE_PID" 2>/dev/null || true; teardown_failed "process group $SERVE_PID still ran 10 s after its server was stopped"; }
        SERVE_PID=""
    fi
    local pid
    for pid in $STARTED_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    { exec 3<&-; } 2>/dev/null || true
    rm -rf "$TEST_TMPDIR" || teardown_failed "could not remove $TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN CS_TRANSCRIPTS_DIR CS_CLAUDE_DIR 2>/dev/null || true
    SUITE_PHASE=""
}

# True once no process is left in process group <pgid>, waiting up to 10 s.
group_gone_within_10s() {  # pgid
    local i=0
    while kill -0 -- -"$1" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    ! kill -0 -- -"$1" 2>/dev/null
}

# Run a command to its end in a process group of its own, as a terminal runs
# it, with its input from RUN_CS_STDIN (/dev/null when unset), its output in
# $TEST_TMPDIR/out and its status in CS_RC. Its stderr goes to the file
# RUN_CS_STDERR names when that is set, and into out with stdout otherwise.
# The release cs leaves beside the server runs in that group too, so the run
# is over only once the group is empty; the wait keeps the next step from
# racing it.
run_in_its_own_group() {  # command...
    CS_RC=0
    if [ -n "${RUN_CS_STDERR:-}" ]; then
        perl -e 'setpgrp(0,0); exec @ARGV' "$@" > "$TEST_TMPDIR/out" 2> "$RUN_CS_STDERR" < "${RUN_CS_STDIN:-/dev/null}" &
    else
        perl -e 'setpgrp(0,0); exec @ARGV' "$@" > "$TEST_TMPDIR/out" 2>&1 < "${RUN_CS_STDIN:-/dev/null}" &
    fi
    local leader=$!
    wait "$leader" || CS_RC=$?
    group_gone_within_10s "$leader" \
        || { echo "  FAIL: $* left process group $leader running 10 s after it ended"; return 1; }
}

run_cs() {  # cs args...
    run_in_its_own_group "$CS_BIN" "$@"
}

# run_cs, failing unless cs exits 0; cs's output is shown when it does not.
run_cs_ok() {  # cs args...
    run_cs "$@" || return 1
    assert_eq "0" "$CS_RC" "cs $* exits 0" || { cat "$TEST_TMPDIR/out"; return 1; }
}

# One line of the fake's log, by key (the first such line).
log_value() {  # key
    sed -n "s/^$1=//p" "$FAKE_CLAUDE_LOG" | head -1
}

# Start `cs <args>` serving in its own process group, as a tmux window or a
# terminal runs it, and wait (on a fifo, no polling) until the fake server
# says it is up. SIGINT and SIGHUP are reset to their defaults: a background
# job of a non-interactive shell starts with SIGINT ignored, a suite run
# under nohup starts with SIGHUP ignored, and a shell cannot trap a signal it
# started with ignored, so the fake would never see either.
start_serving() {  # cs args...
    mkfifo "$FAKE_READY_FIFO"
    exec 3<>"$FAKE_READY_FIFO"
    FAKE_CLAUDE_MODE=serve perl -e '$SIG{INT}="DEFAULT"; $SIG{HUP}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
        "$CS_BIN" "$@" > "$TEST_TMPDIR/serve.out" 2>&1 &
    SERVE_PID=$!
    local line=""
    read -t 60 -u 3 line || true
    [ "$line" = "ready" ] || { echo "  FAIL: the fake server never said ready"; cat "$TEST_TMPDIR/serve.out"; return 1; }
}

# Signal the serving process group, as closing a terminal or a tmux window
# does, collect cs's exit status into SERVE_RC, and wait for the release cs
# left in the group to finish.
stop_serving() {  # signal
    kill -"$1" -- -"$SERVE_PID"
    SERVE_RC=0
    wait "$SERVE_PID" || SERVE_RC=$?
    group_gone_within_10s "$SERVE_PID" \
        || { echo "  FAIL: process group $SERVE_PID still runs 10 s after its server stopped"; return 1; }
    SERVE_PID=""
}

# Run a command on a pseudo-terminal of its own, as a tmux window or a
# terminal tab runs it: the command is the session leader there. Once the
# fake server says ready, either type Ctrl-C (ctrlc) or close the terminal
# (hangup), then print how the command ended, once its process group (the
# release cs leaves beside the server included) is empty. Only the kernel
# signals anything here.
drive_on_a_terminal() {  # ctrlc|hangup, command...
    local mode="$1"
    shift
    mkfifo "$FAKE_READY_FIFO"
    FAKE_CLAUDE_MODE=serve python3 - "$mode" "$FAKE_READY_FIFO" "$@" << 'PY'
import os, pty, select, signal, sys, time
mode, fifo, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
rfd = os.open(fifo, os.O_RDWR)
pid, fd = pty.fork()
if pid == 0:
    # Defaults, as on a fresh terminal: a suite under nohup ignores SIGHUP.
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.execvp(cmd[0], cmd)
def group_gone_within_10s():
    end = time.time() + 10
    while time.time() < end:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.2)
    return False
out, ready, start = b"", False, time.time()
while time.time() - start < 60 and not ready:
    r, _, _ = select.select([fd, rfd], [], [], 0.5)
    if rfd in r:
        os.read(rfd, 64)
        ready = True
    if fd in r:
        try:
            out += os.read(fd, 65536)
        except OSError:
            break
if not ready:
    print("never ready: " + out.decode("utf-8", "replace")[-1000:])
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    group_gone_within_10s()
    sys.exit(0)
if mode == "ctrlc":
    os.write(fd, b"\x03")
    while True:
        try:
            if not os.read(fd, 65536):
                break
        except OSError:
            break
else:
    os.close(fd)
_, status = os.waitpid(pid, 0)
ended = "exit %d" % os.WEXITSTATUS(status) if os.WIFEXITED(status) else "signal %d" % os.WTERMSIG(status)
print(ended if group_gone_within_10s() else ended + ", and its process group still ran 10 s later")
PY
}

# True once <file> is gone, waiting up to 10 s: what cs leaves behind is
# removed just after the server exits, not by it.
gone_within_10s() {  # file
    local i=0
    while [ -e "$1" ] && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    [ ! -e "$1" ]
}

# A session directory with a lock held by a running process, as an open
# `cs <name>` leaves it. Called directly, never through $(...): the sleeper
# would hold the substitution's pipe open, and its pid would not reach
# STARTED_PIDS.
make_open_session() {  # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    STARTED_PIDS="$STARTED_PIDS $!"
    printf '%s\n' "$!" > "$sdir/.cs/session.lock"
}

# A process standing in for the server of session <name>: its argv carries
# `remote-control --name <name>`, as the server's does. Its pid is left in
# FAKE_SERVER_PID. Called directly, for the reason make_open_session is.
start_fake_server_process() {  # name
    perl -e 'sleep 60' remote-control --name "$1" --permission-mode default > /dev/null 2>&1 &
    FAKE_SERVER_PID=$!
    STARTED_PIDS="$STARTED_PIDS $!"
}

# A running process the test started, as a stand-in for some other program.
# Its pid is left in OTHER_PID. Called directly, for the reason
# make_open_session is.
start_unrelated_process() {
    sleep 60 > /dev/null 2>&1 &
    OTHER_PID=$!
    STARTED_PIDS="$STARTED_PIDS $!"
}

# The command the server's tmux window runs for demo in plan mode, from a
# caller whose sessions root is CS_SESSIONS_ROOT and whose claude is the fake.
window_command() {
    local self
    self="$(cd "$SCRIPT_DIR/../bin" && pwd)/cs"
    printf '%s' "env CS_UNATTENDED=1 sh -c '\"\$@\" || { s=\$?; printf \"\\nclaude remote-control exited with status %s. Press Enter to close this window.\\n\" \"\$s\"; read -r _; exit \"\$s\"; }' cs-remote env CS_REMOTE_WINDOW=1 'CS_SESSIONS_ROOT=$CS_SESSIONS_ROOT' 'CLAUDE_CODE_BIN=$TEST_TMPDIR/bin/claude' '$self' 'demo' --remote --permission-mode 'plan'"
}

strip_ansi() {
    sed $'s/\033\\[[0-9;]*m//g'
}

# ---------------------------------------------------------------------------

# remote-control's first run in a git directory asks for a spawn mode at its
# terminal, which nobody sees in a tmux window, unless --spawn names one; cs
# names same-dir, so the sessions it starts run in the session dir.
test_remote_runs_remote_control_by_absolute_path_with_the_default_mode() {
    run_cs_ok demo --remote || return 1
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "claude runs by its absolute path" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" \
        "remote-control gets the session name, the default permission mode and same-dir spawn mode, after the verb" || return 1
    assert_eq "$(cd "$CS_SESSIONS_ROOT/demo" && pwd -P)" "$(log_value pwd)" "the server runs in the session dir" || return 1
}

test_remote_passes_the_permission_mode_it_was_given() {
    run_cs_ok demo --remote --permission-mode plan || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][plan][--spawn=same-dir]" "$(log_value argv)" \
        "the mode given to --permission-mode reaches remote-control" || return 1
}

test_remote_strips_the_api_key_and_keeps_the_cs_exports() {
    ANTHROPIC_API_KEY=sk-ant-example-not-a-key run_cs_ok demo --remote || return 1
    assert_eq "" "$(log_value ANTHROPIC_API_KEY)" "ANTHROPIC_API_KEY is absent from the server's env" || return 1
    local v
    for v in CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_CODE_TASK_LIST_ID \
        CLAUDE_COWORK_MEMORY_PATH_OVERRIDE CS_LEAD_PID; do
        assert_eq "set" "$(log_value "$v")" "$v is exported to the server" || return 1
    done
}

test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs() {
    run_cs_ok demo --remote || return 1
    assert_eq "$(log_value pid)" "$(log_value lock)" "the lock names the server while it serves" || return 1
    assert_eq "$(log_value pid)" "$(log_value remote_pid)" ".cs/local/remote.pid names the server" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is gone once the release is done" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is gone once the release is done" || return 1
}

# remote-control takes no prompt, so a seed cs -spawn staged for the session
# is not run; one line says it waits for the next interactive open.
test_remote_says_a_staged_spawn_seed_stays_staged() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'token-0\nspawner\nfirst task\n' > "$CS_SESSIONS_ROOT/.spawn/demo.seed"
    run_cs_ok demo --remote || return 1
    assert_eq "A spawn seed is staged for demo; it stays staged for the next cs demo, since claude remote-control takes no prompt to start it with." \
        "$(strip_ansi < "$TEST_TMPDIR/out" | grep -F 'spawn seed')" "one line says the seed stays staged" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "token-0
spawner
first task" "$(cat "$CS_SESSIONS_ROOT/.spawn/demo.seed")" "the seed is left as it was" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" "the server ran" || return 1
}

test_remote_shows_the_servers_error_and_exits_with_its_status() {
    FAKE_CLAUDE_MODE=exit:1 run_cs demo --remote || return 1
    assert_eq "1" "$CS_RC" "cs exits with the server's status" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/out")" "Error: You must be logged in to use Remote Control." "the server's own error is shown as is" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/session.lock" "the lock is gone after a failed start" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is gone after a failed start" || return 1
}

test_remote_refuses_a_claude_older_than_the_measured_version() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION=2.1.298 "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "an older claude is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude is 2.1.298. Update Claude Code, then retry." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names both versions" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_remote_accepts_a_newer_claude_by_number_not_by_text() {
    FAKE_CLAUDE_VERSION=2.1.1000 run_cs_ok demo --remote || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" \
        "2.1.1000 is newer than 2.1.299" || return 1
}

test_remote_refuses_a_claude_that_names_no_version() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION=unknown "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a version cs cannot read is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude --version printed no version number." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal says what was read" || return 1
}

test_remote_refuses_a_claude_whose_version_check_fails() {
    local rc=0 out
    out=$(FAKE_CLAUDE_VERSION_EXIT=1 "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a failed version check is refused" || return 1
    assert_eq "Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/claude --version exited with status 1." \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal says the version check failed" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

# The notice cs prints on stderr when CLAUDE_CODE_BIN carries permission
# options, and the refusal for any other option it carries.
NOTE_DROP="drops --allow-dangerously-skip-permissions from CLAUDE_CODE_BIN: remote-control takes no such option and needs none for bypassPermissions."
refusal_of() {  # what CLAUDE_CODE_BIN carries, [command word]
    printf '%s' "Error: CLAUDE_CODE_BIN carries $1, which cs --remote cannot pass to ${2:-claude} remote-control: it carries over only --permission-mode <mode> and --dangerously-skip-permissions, as remote-control's own --permission-mode, and drops --allow-dangerously-skip-permissions. Set CLAUDE_CODE_BIN to the command alone, or with only those options, for --remote."
}

test_remote_carries_the_permission_mode_in_claude_code_bin_and_says_so() {
    local err="$TEST_TMPDIR/err"
    CLAUDE_CODE_BIN="claude --permission-mode bypassPermissions --allow-dangerously-skip-permissions" \
        RUN_CS_STDERR="$err" run_cs_ok demo --remote || { cat "$err"; return 1; }
    assert_eq "cs --remote carries permission mode bypassPermissions from CLAUDE_CODE_BIN's --permission-mode bypassPermissions to claude remote-control. It $NOTE_DROP" \
        "$(strip_ansi < "$err" | grep -F 'CLAUDE_CODE_BIN')" "one line on stderr names the mode carried and what was dropped" || { cat "$err"; return 1; }
    assert_eq "1" "$(grep -c 'CLAUDE_CODE_BIN' "$err")" "the line is printed once" || return 1
    assert_eq "" "$(grep -F 'CLAUDE_CODE_BIN' "$TEST_TMPDIR/out" || true)" "the line is not on stdout" || return 1
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "claude runs by its absolute path" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][bypassPermissions][--spawn=same-dir]" "$(log_value argv)" \
        "remote-control gets the mode CLAUDE_CODE_BIN carries, and no other option of it" || return 1
}

# The mode given to cs --remote --permission-mode wins over the one
# CLAUDE_CODE_BIN carries, and the line says so.
test_remote_permission_mode_given_wins_over_the_one_carried() {
    local err="$TEST_TMPDIR/err"
    CLAUDE_CODE_BIN="claude --dangerously-skip-permissions --allow-dangerously-skip-permissions" \
        RUN_CS_STDERR="$err" run_cs_ok demo --remote --permission-mode plan || { cat "$err"; return 1; }
    assert_eq "cs --remote runs claude remote-control in permission mode plan from its own --permission-mode, over bypassPermissions from CLAUDE_CODE_BIN's --dangerously-skip-permissions. It $NOTE_DROP" \
        "$(strip_ansi < "$err" | grep -F 'CLAUDE_CODE_BIN')" "the line names both modes" || { cat "$err"; return 1; }
    assert_eq "[remote-control][--name][demo][--permission-mode][plan][--spawn=same-dir]" "$(log_value argv)" \
        "remote-control gets the mode --remote was given" || return 1
}

# CLAUDE_CODE_BIN splits on blanks wherever cs runs it, so a quote in it is a
# character of an option, not quoting, and blanks between options are
# separators. A quoted mode is one word that is no mode, and the words after
# it are words of their own, the command word among them, so the refusal
# names them all, one blank apart.
test_remote_names_carried_and_refused_options_as_written() {
    local err="$TEST_TMPDIR/err" rc=0 out
    CLAUDE_CODE_BIN=" claude  --permission-mode=plan   --allow-dangerously-skip-permissions " \
        RUN_CS_STDERR="$err" run_cs_ok demo --remote || { cat "$err"; return 1; }
    assert_eq "cs --remote carries permission mode plan from CLAUDE_CODE_BIN's --permission-mode=plan to claude remote-control. It $NOTE_DROP" \
        "$(strip_ansi < "$err" | grep -F 'CLAUDE_CODE_BIN')" "the option carried is named as written" || { cat "$err"; return 1; }
    assert_eq "[remote-control][--name][demo][--permission-mode][plan][--spawn=same-dir]" "$(log_value argv)" \
        "remote-control gets the mode alone" || return 1
    rm -rf "${CS_SESSIONS_ROOT:?}/demo" "$FAKE_CLAUDE_LOG"
    out=$(CLAUDE_CODE_BIN="claude --permission-mode 'ask claude first'" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a quoted mode is refused" || { printf '%s\n' "$out"; return 1; }
    assert_eq "$(refusal_of "--permission-mode 'ask claude first'")" \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names every word after the command, the command word inside them too" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "claude never ran" || return 1
}

# Each permission option, read as Claude Code 2.1.299 reads it: a mode option
# takes the next word or the value after "=", the last one wins, and
# --dangerously-skip-permissions wins over any of them.
test_remote_carries_each_permission_option() {
    local row bin mode note err="$TEST_TMPDIR/err"
    for row in "claude --dangerously-skip-permissions|bypassPermissions|cs --remote carries permission mode bypassPermissions from CLAUDE_CODE_BIN's --dangerously-skip-permissions to claude remote-control." \
        "claude --permission-mode=acceptEdits|acceptEdits|cs --remote carries permission mode acceptEdits from CLAUDE_CODE_BIN's --permission-mode=acceptEdits to claude remote-control." \
        "claude --permission-mode manual|manual|cs --remote carries permission mode manual from CLAUDE_CODE_BIN's --permission-mode manual to claude remote-control." \
        "claude --permission-mode plan --permission-mode dontAsk|dontAsk|cs --remote carries permission mode dontAsk from CLAUDE_CODE_BIN's --permission-mode dontAsk to claude remote-control." \
        "claude --permission-mode plan --dangerously-skip-permissions|bypassPermissions|cs --remote carries permission mode bypassPermissions from CLAUDE_CODE_BIN's --dangerously-skip-permissions to claude remote-control." \
        "claude --allow-dangerously-skip-permissions|default|cs --remote $NOTE_DROP"; do
        bin="${row%%|*}"; mode="${row#*|}"; note="${mode#*|}"; mode="${mode%%|*}"
        rm -rf "${CS_SESSIONS_ROOT:?}/demo" "$FAKE_CLAUDE_LOG"
        CLAUDE_CODE_BIN="$bin" RUN_CS_STDERR="$err" run_cs_ok demo --remote || { echo "  with CLAUDE_CODE_BIN=$bin"; cat "$err"; return 1; }
        assert_eq "$note" "$(strip_ansi < "$err" | grep -F 'CLAUDE_CODE_BIN')" "the line for $bin" || { cat "$err"; return 1; }
        assert_eq "[remote-control][--name][demo][--permission-mode][$mode][--spawn=same-dir]" "$(log_value argv)" \
            "remote-control runs in $mode for $bin" || return 1
    done
}

# Any other option, a restrictive one too, would be lost on the sessions
# remote-control starts, so it is refused by name before anything is opened.
# A mode option's value is checked against claude's modes, so an option in
# its place is not carried with it, and a mode option needs a value.
test_remote_refuses_options_it_cannot_drop_before_opening_anything() {
    local rest named rc out
    for rest in "--disallowedTools Bash" "--settings /x.json" "--sandbox" "--foo" \
        "--permission-mode plan --disallowedTools Bash" "--permission-mode --sandbox" \
        "--plan-mode-required" "--dangerously-skip-permissions=1" "--enable-auto-mode" \
        "--inherit-permission-mode dontAsk" "--permission-mode" "--permission-mode=plann"; do
        rc=0
        out=$(CLAUDE_CODE_BIN="claude $rest" "$CS_BIN" demo --remote 2>&1) || rc=$?
        assert_eq "1" "$rc" "claude $rest is refused" || { printf '%s\n' "$out"; return 1; }
        named="$rest"
        [ "$rest" != "--permission-mode plan --disallowedTools Bash" ] || named="--disallowedTools Bash"
        assert_eq "$(refusal_of "$named")" \
            "$(printf '%s' "$out" | strip_ansi)" "the refusal names what claude $rest carries that cs cannot drop" || return 1
        assert_file_not_exists "$FAKE_CLAUDE_LOG" "claude never ran for claude $rest" || return 1
        [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: claude $rest created the session"; return 1; }
    done
}

# Inside tmux, on a session that exists, the refusal comes before the window,
# the lock and remote.pid, and leaves the session dir as it was.
test_remote_inside_tmux_refuses_an_option_it_cannot_drop_before_any_window() {
    "$CS_BIN" demo > /dev/null 2>&1 <<< "" || return 1
    local sdir="$CS_SESSIONS_ROOT/demo" before rc=0 out
    # The fake claude runs no SessionEnd hook, so the open's lock stays.
    rm -f "$FAKE_CLAUDE_LOG" "$sdir/.cs/session.lock"
    before=$(cd "$sdir" && find . -print | sort)
    out=$(CLAUDE_CODE_BIN="claude --sandbox" TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "claude --sandbox is refused inside tmux" || { printf '%s\n' "$out"; return 1; }
    assert_eq "$(refusal_of --sandbox)" \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal is on the caller's terminal" || return 1
    assert_eq "" "$(grep -e '^new-session' -e '^new-window' "$FAKE_TMUX_LOG" 2>/dev/null || true)" "no window is opened" || return 1
    assert_file_not_exists "$sdir/.cs/session.lock" "no lock is taken" || return 1
    assert_file_not_exists "$sdir/.cs/local/remote.pid" "no remote.pid is written" || return 1
    assert_eq "$before" "$(cd "$sdir" && find . -print | sort)" "the session dir is as it was" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "claude never ran" || return 1
}

# The window is handed the claude checked here, an absolute path with no
# options, and the mode carried, so the line is printed once, on the
# caller's terminal, and the window's own run has nothing to carry, whatever
# CLAUDE_CODE_BIN says in the environment it starts from.
test_remote_window_gets_the_command_alone_and_the_line_shows_once() {
    local err="$TEST_TMPDIR/err" werr="$TEST_TMPDIR/window-err" cmd
    CLAUDE_CODE_BIN="claude --permission-mode plan" TMUX="/tmp/fake,1,0" \
        RUN_CS_STDERR="$err" run_cs_ok demo --remote || { cat "$err"; return 1; }
    assert_eq "cs --remote carries permission mode plan from CLAUDE_CODE_BIN's --permission-mode plan to claude remote-control." \
        "$(strip_ansi < "$err" | grep -F 'CLAUDE_CODE_BIN')" "the caller is told what was carried" || { cat "$err"; return 1; }
    assert_eq "new-session -d -s cs -n remote:demo -P -F #{window_id} $(window_command)" \
        "$(grep '^new-session' "$FAKE_TMUX_LOG")" "the window gets the absolute claude with no options, and the mode carried" || return 1
    cmd=$(sed -n 's/^new-session -d -s cs -n remote:demo -P -F #{window_id} //p' "$FAKE_TMUX_LOG")
    CLAUDE_CODE_BIN="claude --permission-mode bypassPermissions" TMUX="/tmp/fake,1,0" \
        RUN_CS_STDERR="$werr" run_in_its_own_group sh -c "$cmd" || return 1
    assert_eq "0" "$CS_RC" "the window's server ran" || { cat "$TEST_TMPDIR/out" "$werr"; return 1; }
    assert_eq "0" "$(grep -c 'CLAUDE_CODE_BIN' "$werr")" "the window prints no second line" || { cat "$werr"; return 1; }
    assert_eq "[remote-control][--name][demo][--permission-mode][plan][--spawn=same-dir]" "$(log_value argv)" \
        "the window's remote-control runs in the mode carried" || return 1
}

# CLAUDE_CODE_BIN's command word is what runs remote-control, so a wrapper in
# front of claude is that word. Its own words are no permission options and
# refuse it by name; one carrying only permission options whose --version
# fails, as BSD env's does, is refused by the version check, after the line
# naming the mode carried.
test_remote_with_a_wrapper_whose_version_check_fails_is_refused() {
    cat > "$TEST_TMPDIR/bin/with-env" << 'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "with-env: illegal option -- -" >&2; exit 1; }
printf '[%s]' "$@" >> "$FAKE_WRAPPER_LOG"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/with-env"
    local rc=0 out
    out=$(CLAUDE_CODE_BIN="with-env FOO=1 claude" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "the wrapper's own words refuse it" || { printf '%s\n' "$out"; return 1; }
    assert_eq "$(refusal_of "FOO=1 claude" with-env)" \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names the wrapper's words" || return 1
    rc=0
    out=$(CLAUDE_CODE_BIN="with-env --dangerously-skip-permissions" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "the wrapper is refused" || { printf '%s\n' "$out"; return 1; }
    assert_eq "cs --remote carries permission mode bypassPermissions from CLAUDE_CODE_BIN's --dangerously-skip-permissions to with-env remote-control.
Error: cs --remote needs Claude Code 2.1.299 or later for claude remote-control; $TEST_TMPDIR/bin/with-env --version exited with status 1." \
        "$(printf '%s' "$out" | strip_ansi)" "the line names the wrapper and what was dropped, the refusal its version check" || return 1
    assert_file_not_exists "$TEST_TMPDIR/wrapper.log" "the wrapper never ran remote-control" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "claude never ran" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: a refused --remote created the session"; return 1; }
}

# A wrapper whose --version passes, as 1Password's op does (2.30.0, past the
# floor by number), is refused by name: `op run -- claude` by its own words,
# before op runs at all, and op carrying only permission options, since its
# output carries no "(Claude Code)", so the word is not claude. Nothing is
# opened.
test_remote_refuses_a_wrapper_whose_version_is_not_claude_codes() {
    cat > "$TEST_TMPDIR/bin/op" << 'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "2.30.0"; exit 0; }
printf '[%s]' "$@" >> "$FAKE_WRAPPER_LOG"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/op"
    local rc=0 out
    out=$(CLAUDE_CODE_BIN="op run -- claude" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "the wrapper's own words refuse it" || { printf '%s\n' "$out"; return 1; }
    assert_eq "$(refusal_of "run -- claude" op)" \
        "$(printf '%s' "$out" | strip_ansi)" "the refusal names the wrapper's words" || return 1
    rc=0
    out=$(CLAUDE_CODE_BIN="op --permission-mode plan" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "the wrapper is refused" || { printf '%s\n' "$out"; return 1; }
    assert_eq "cs --remote carries permission mode plan from CLAUDE_CODE_BIN's --permission-mode plan to op remote-control.
Error: cs --remote runs op remote-control, and op is not Claude Code: op --version printed \"2.30.0\". Set CLAUDE_CODE_BIN to claude itself for --remote." \
        "$(printf '%s' "$out" | strip_ansi)" "the line names the wrapper and what was dropped, the refusal what its --version printed" || return 1
    assert_file_not_exists "$TEST_TMPDIR/wrapper.log" "the wrapper never ran remote-control" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "claude never ran" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: a refused --remote created the session"; return 1; }
}

# With nothing carried, the command word is not checked for Claude Code's
# mark: a claude whose --version prints the number alone still serves.
test_remote_runs_a_plain_claude_whose_version_has_no_mark() {
    FAKE_CLAUDE_VERSION_LINE=2.1.299 run_cs_ok demo --remote || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" \
        "the server ran" || return 1
}

test_remote_refuses_a_session_open_locally() {
    "$CS_BIN" demo > /dev/null 2>&1 <<< "" || return 1
    rm -f "$FAKE_CLAUDE_LOG"
    make_open_session demo
    local pid rc=0 out
    pid="$(cat "$CS_SESSIONS_ROOT/demo/.cs/session.lock")"
    out=$("$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session open locally is not served" || return 1
    assert_eq "Error: Session demo is live (PID $pid); cs demo --remote serves only a session that is not live. Close it first." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the open session's pid" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
}

test_local_open_is_refused_while_the_session_is_served() {
    start_serving demo --remote || return 1
    local spid rc out
    spid="$(log_value pid)"
    for flag in "" --force; do
        rc=0
        out=$(CS_ASSUME_TTY=1 "$CS_BIN" demo $flag 2>&1 <<< "1") || rc=$?
        assert_eq "1" "$rc" "cs demo $flag is refused while demo is served" \
            || { printf '%s\n' "$out"; cat "$FAKE_CLAUDE_LOG"; return 1; }
        assert_eq "Error: Session demo is served by cs demo --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window." \
            "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the server" || return 1
    done
    assert_eq "1" "$(grep -c '^argv=' "$FAKE_CLAUDE_LOG")" "no second claude started in the served dir" || return 1
    stop_serving TERM || return 1
    assert_eq "0" "$SERVE_RC" "the server stopped cleanly" || return 1
}

# A conversation the server starts, for FAKE_CLOUD_SESSION: a child of the
# server carrying the server's environment, whose pid Claude Code stamps as
# CLAUDE_PID. It runs cs's real SessionStart hook, records the claim on the
# launch and whether the hooks take it for the lead or show it a guest, then
# runs cs's real SessionEnd hook with a reason other than /clear or /resume
# and records the lock, remote.pid and the claim. One key=value per line in
# $TEST_TMPDIR/cloud.log.
write_cloud_session() {
    local hooks
    hooks="$(cd "$SCRIPT_DIR/../hooks" && pwd)"
    cat > "$TEST_TMPDIR/cloud-session" << CLOUD
#!/usr/bin/env bash
hooks='$hooks' log='$TEST_TMPDIR/cloud.log'
CLOUD
    cat >> "$TEST_TMPDIR/cloud-session" << 'CLOUD'
export CLAUDE_PID=$$
meta="$CLAUDE_SESSION_META_DIR"
printf '{"session_id":"cloud-1","source":"startup","hook_event_name":"SessionStart"}' \
    | bash "$hooks/session-start.sh" > /dev/null 2>&1
. "$hooks/cs-resolve.sh"
{
    printf 'cloud_pid=%s\n' "$$"
    printf 'claim_after_start=%s\n' "$(cat "$meta/local/lead-pid" 2>/dev/null)"
    if cs_is_lead; then echo "lead=1"; else echo "lead=0"; fi
    if cs_is_shown_nested_child; then echo "guest=1"; else echo "guest=0"; fi
} >> "$log"
printf '{"session_id":"cloud-1","reason":"other","hook_event_name":"SessionEnd"}' \
    | bash "$hooks/session-end.sh" > /dev/null 2>&1
{
    printf 'lock_after_end=%s\n' "$(cat "$meta/session.lock" 2>/dev/null)"
    printf 'remote_pid_after_end=%s\n' "$(cat "$meta/local/remote.pid" 2>/dev/null)"
    printf 'claim_after_end=%s\n' "$(cat "$meta/local/lead-pid" 2>/dev/null)"
} >> "$log"
CLOUD
    export FAKE_CLOUD_SESSION="$TEST_TMPDIR/cloud-session"
}

cloud_value() {  # key
    sed -n "s/^$1=//p" "$TEST_TMPDIR/cloud.log" | head -1
}

# A conversation started from the phone is the lead of the session the server
# holds: it claims the server's launch, so the hooks take it for the lead, and
# its end marks the claim ended but leaves the server's lock and remote.pid
# while the server runs. The session stays refused to a local open.
test_remote_conversation_the_server_starts_is_the_lead_and_keeps_the_lock() {
    write_cloud_session
    start_serving demo --remote || return 1
    local spid cpid rc=0 out
    spid="$(log_value pid)"
    cpid="$(cloud_value cloud_pid)"
    assert_eq "$spid $cpid cloud-1" "$(cloud_value claim_after_start)" "the conversation claims the server's launch" || return 1
    assert_eq "1" "$(cloud_value lead)" "the hooks take the conversation for the lead" || return 1
    assert_eq "0" "$(cloud_value guest)" "the hooks do not show the conversation a guest" || return 1
    assert_eq "$spid" "$(cloud_value lock_after_end)" "the conversation's end leaves the server's lock" || return 1
    assert_eq "$spid" "$(cloud_value remote_pid_after_end)" "the conversation's end leaves remote.pid" || return 1
    assert_eq "$spid $cpid cloud-1 ended" "$(cloud_value claim_after_end)" "the conversation's end marks its claim ended" || return 1
    out=$("$CS_BIN" demo 2>&1 < /dev/null) || rc=$?
    assert_eq "1" "$rc" "cs demo is refused after the conversation ended" || { printf '%s\n' "$out"; return 1; }
    assert_eq "Error: Session demo is served by cs demo --remote (remote-control PID $spid); stop it first with Ctrl-C in its window, or close the window." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the refusal names the server" || return 1
    stop_serving TERM || return 1
    assert_eq "0" "$SERVE_RC" "the server stopped cleanly" || return 1
}

# Session demo as `cs demo --remote` leaves it while it serves, with a process
# standing in for its server: the stand-in's argv carries
# `remote-control --name <shown name>`, the session lock and
# .cs/local/remote.pid name it, and its child stands for a conversation it
# started from the phone. Leaves the pids in STAND_IN_PID and STAND_IN_CHILD.
# Called directly, for the reason make_open_session is.
start_stand_in_server() {  # shown name
    "$CS_BIN" demo > /dev/null 2>&1 <<< "" || return 1
    mkfifo "$TEST_TMPDIR/stand-in"
    exec 3<>"$TEST_TMPDIR/stand-in"
    perl -e 'my $c = fork(); if ($c == 0) { sleep 60; exit 0 } open(my $f, ">", shift) or exit 1; print $f "$c\n"; close $f; waitpid($c, 0)' \
        "$TEST_TMPDIR/stand-in" remote-control --name "$1" --permission-mode default > /dev/null 2>&1 &
    STAND_IN_PID=$!
    STARTED_PIDS="$STARTED_PIDS $STAND_IN_PID"
    STAND_IN_CHILD=""
    read -t 10 -u 3 STAND_IN_CHILD || true
    [ -n "$STAND_IN_CHILD" ] || { echo "  FAIL: the stand-in server never named its child"; return 1; }
    STARTED_PIDS="$STARTED_PIDS $STAND_IN_CHILD"
    printf '%s\n' "$STAND_IN_PID" > "$CS_SESSIONS_ROOT/demo/.cs/session.lock"
    printf '%s\n' "$STAND_IN_PID" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
}

# Run cs's real <hook> for the stand-in's child with <payload>, in the
# environment a conversation the server starts inherits from it.
phone_conversation_hook() {  # hook, payload
    local sdir="$CS_SESSIONS_ROOT/demo"
    printf '%s' "$2" | CLAUDE_SESSION_NAME=demo CLAUDE_SESSION_DIR="$sdir" CLAUDE_SESSION_META_DIR="$sdir/.cs" \
        CS_LEAD_PID="$STAND_IN_PID" CS_LEAD_CLAIM=1 CLAUDE_PID="$STAND_IN_CHILD" \
        bash "$SCRIPT_DIR/../hooks/$1" > /dev/null 2>&1
}

# Once the server is gone, the phone lead's end removes the lock it left, as
# the end of any lead removes a lock naming a process that no longer runs.
test_phone_lead_end_removes_the_lock_once_its_server_is_gone() {
    start_stand_in_server demo || return 1
    local meta="$CS_SESSIONS_ROOT/demo/.cs"
    phone_conversation_hook session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1" "$(cat "$meta/local/lead-pid")" "the conversation claims the server's launch" || return 1
    kill "$STAND_IN_PID"
    wait "$STAND_IN_PID" 2>/dev/null || true
    phone_conversation_hook session-end.sh '{"session_id":"phone-1","reason":"other","hook_event_name":"SessionEnd"}' || return 1
    assert_file_not_exists "$meta/session.lock" "the end removes the lock of the server that is gone" || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1 ended" "$(cat "$meta/local/lead-pid")" "the end marks the claim ended" || return 1
}

# A remote.pid whose pid runs remote-control for another session is no server
# of this one: the lead's end removes the lock that names its own launch.
test_phone_lead_end_removes_the_lock_when_remote_pid_serves_another_session() {
    start_stand_in_server demo-2 || return 1
    local meta="$CS_SESSIONS_ROOT/demo/.cs"
    phone_conversation_hook session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1" "$(cat "$meta/local/lead-pid")" "the conversation claims the launch" || return 1
    phone_conversation_hook session-end.sh '{"session_id":"phone-1","reason":"other","hook_event_name":"SessionEnd"}' || return 1
    kill -0 "$STAND_IN_PID" 2>/dev/null || { echo "  FAIL: the process remote.pid names stopped before the end"; return 1; }
    assert_file_not_exists "$meta/session.lock" "the end removes the lock naming its own launch" || return 1
}

# A tmux on PATH for the hooks, which run `tmux` itself: one line of argv per
# call in $TEST_TMPDIR/title-tmux.log, and the pane's @cs_session kept as tmux
# keeps it, so list-panes answers with the name a set-option gave.
write_title_tmux() {
    cat > "$TEST_TMPDIR/bin/tmux" << TMUX
#!/bin/bash
log='$TEST_TMPDIR/title-tmux.log' pane='$TEST_TMPDIR/title-tmux.pane'
TMUX
    cat >> "$TEST_TMPDIR/bin/tmux" << 'TMUX'
printf '%s\n' "$*" >> "$log"
case "$1" in
    set-option) case " $* " in *" -u "*) rm -f "$pane" ;; *) printf '%s\n' "${!#}" > "$pane" ;; esac ;;
    list-panes) cat "$pane" 2>/dev/null ;;
esac
exit 0
TMUX
    chmod +x "$TEST_TMPDIR/bin/tmux"
}

# Run cs's real <hook> for the stand-in's child inside tmux pane %9.
phone_conversation_hook_in_tmux() {  # hook, payload
    TMUX=/tmp/cs-test-tmux,1,0 TMUX_PANE=%9 phone_conversation_hook "$@"
}

# While the server serves the session, its tmux window keeps the
# remote:<name> name `cs <name> --remote` gave it: the phone lead's start and
# end run no tmux title step, so tmux is never called.
test_phone_lead_leaves_the_servers_tmux_window_name() {
    start_stand_in_server demo || return 1
    write_title_tmux
    local meta="$CS_SESSIONS_ROOT/demo/.cs"
    phone_conversation_hook_in_tmux session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1" "$(cat "$meta/local/lead-pid")" "the conversation is the lead" || return 1
    assert_file_not_exists "$TEST_TMPDIR/title-tmux.log" "the lead's start calls no tmux" || return 1
    phone_conversation_hook_in_tmux session-end.sh '{"session_id":"phone-1","reason":"other","hook_event_name":"SessionEnd"}' || return 1
    assert_file_not_exists "$TEST_TMPDIR/title-tmux.log" "the lead's end calls no tmux" || return 1
    assert_eq "$STAND_IN_PID" "$(cat "$meta/session.lock")" "the end leaves the server's lock" || return 1
}

# The lead's start names pane %9's window after the session and its end
# releases the pane, with exactly the tmux calls the hooks make.
assert_lead_titles_the_window() {
    local meta="$CS_SESSIONS_ROOT/demo/.cs" log="$TEST_TMPDIR/title-tmux.log"
    phone_conversation_hook_in_tmux session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1" "$(cat "$meta/local/lead-pid")" "the conversation is the lead" || return 1
    assert_eq "select-pane -t %9 -T cs: demo
display-message -p -t %9 #{socket_path}#{window_id}
set-option -p -t %9 @cs_session demo
list-panes -t %9 -F #{@cs_session}
rename-window -t %9 cs: demo
set-window-option -t %9 allow-rename off
set-window-option -t %9 allow-set-title off" "$(cat "$log" 2>/dev/null)" "the lead's start titles the pane and names the window" || return 1
    rm -f "$log"
    phone_conversation_hook_in_tmux session-end.sh '{"session_id":"phone-1","reason":"other","hook_event_name":"SessionEnd"}' || return 1
    assert_eq "display-message -p -t %9 #{socket_path}#{window_id}
set-option -p -u -t %9 @cs_session
list-panes -t %9 -F #{@cs_session}
set-window-option -t %9 automatic-rename on
set-window-option -t %9 allow-rename on
set-window-option -t %9 allow-set-title on" "$(cat "$log" 2>/dev/null)" "the lead's end releases the pane and the window names itself" || return 1
}

# With no remote.pid no server serves the session, and the lead titles the
# window as every lead does.
test_lead_titles_the_tmux_window_without_a_remote_pid() {
    start_stand_in_server demo || return 1
    rm -f "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    write_title_tmux
    assert_lead_titles_the_window || return 1
}

# A remote.pid whose pid serves another session is no server of this one.
test_phone_lead_titles_the_tmux_window_when_remote_pid_serves_another_session() {
    start_stand_in_server demo-2 || return 1
    write_title_tmux
    assert_lead_titles_the_window || return 1
    kill -0 "$STAND_IN_PID" 2>/dev/null || { echo "  FAIL: the process remote.pid names stopped before the end"; return 1; }
}

# Outside tmux the tab is titled `cs: <name> (remote)` by the server's launch:
# while the server serves the session, the phone lead's start writes no tab
# title to the terminal.
test_phone_lead_writes_no_tab_title_outside_tmux() {
    start_stand_in_server demo || return 1
    local meta="$CS_SESSIONS_ROOT/demo/.cs" tty="$TEST_TMPDIR/title-tty"
    rm -f "$tty"
    CS_TITLE_TTY="$tty" phone_conversation_hook session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$STAND_IN_PID $STAND_IN_CHILD phone-1" "$(cat "$meta/local/lead-pid")" "the conversation is the lead" || return 1
    assert_file_not_exists "$tty" "the lead's start writes no tab title" || return 1
}

# With no remote.pid no server serves the session, and the lead's start
# writes the tab title every lead writes outside tmux.
test_lead_writes_the_tab_title_outside_tmux_without_a_remote_pid() {
    start_stand_in_server demo || return 1
    rm -f "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local tty="$TEST_TMPDIR/title-tty"
    rm -f "$tty"
    CS_TITLE_TTY="$tty" phone_conversation_hook session-start.sh '{"session_id":"phone-1","source":"startup","hook_event_name":"SessionStart"}' || return 1
    assert_eq "$(printf '\033]0;cs: demo\007')" "$(cat "$tty" 2>/dev/null)" "the lead's start writes the tab title" || return 1
}

test_remote_stops_cleanly_when_its_window_hangs_up() {
    start_serving demo --remote || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "remote.pid is written while serving" || return 1
    stop_serving HUP || return 1
    assert_eq "0" "$SERVE_RC" "cs exits 0 when the server stops cleanly on SIGHUP" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_on_ctrl_c() {
    start_serving demo --remote || return 1
    stop_serving INT || return 1
    assert_eq "0" "$SERVE_RC" "cs exits with the server's 0, not 130" || { cat "$TEST_TMPDIR/serve.out"; return 1; }
    assert_eq "1" "$(grep -cx 'signal INT' "$FAKE_CLAUDE_LOG")" "the server got the interrupt" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_when_its_terminal_closes() {
    local result
    result=$(drive_on_a_terminal hangup "$CS_BIN" demo --remote)
    assert_eq "exit 0" "$result" "the server stops cleanly when its terminal goes away" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup itself" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_stops_cleanly_on_ctrl_c_typed_at_its_terminal() {
    local result
    result=$(drive_on_a_terminal ctrlc "$CS_BIN" demo --remote)
    assert_eq "exit 0" "$result" "the server stops cleanly on Ctrl-C" || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    assert_eq "1" "$(grep -cx 'signal INT' "$FAKE_CLAUDE_LOG")" "the server got the interrupt itself" || return 1
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_remote_refuses_force_finish_and_a_mode_without_remote() {
    local rc out
    rc=0; out=$("$CS_BIN" demo --remote --force 2>&1) || rc=$?
    assert_eq "1" "$rc" "--force with --remote is refused" || return 1
    assert_eq "Error: --force cannot be used with --remote: a served session never shares its directory with another claude." \
        "$(printf '%s' "$out" | strip_ansi)" "--force refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --remote -finish feat 2>&1) || rc=$?
    assert_eq "1" "$rc" "-finish with --remote is refused" || return 1
    assert_eq "Error: -finish cannot be used with --remote: remote-control takes no prompt to run /finish with." \
        "$(printf '%s' "$out" | strip_ansi)" "-finish refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --permission-mode plan 2>&1) || rc=$?
    assert_eq "1" "$rc" "--permission-mode without --remote is refused" || return 1
    assert_eq "Error: --permission-mode is an option of --remote: cs demo --remote --permission-mode plan" \
        "$(printf '%s' "$out" | strip_ansi)" "--permission-mode refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --remote --permission-mode 2>&1) || rc=$?
    assert_eq "1" "$rc" "--permission-mode with no mode is refused" || return 1
    assert_eq "Error: --permission-mode needs a mode: cs demo --remote --permission-mode <mode>" \
        "$(printf '%s' "$out" | strip_ansi)" "missing mode refusal" || return 1
    rc=0; out=$("$CS_BIN" demo --permission-mode --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "an option in the mode's place is refused" || return 1
    assert_eq "Error: --permission-mode needs a mode: cs demo --remote --permission-mode <mode>" \
        "$(printf '%s' "$out" | strip_ansi)" "an option is not taken as the mode" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "remote-control never ran" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/demo" ] || { echo "  FAIL: a refused --remote created the session"; return 1; }
}

test_remote_inside_tmux_opens_its_own_window_in_the_cs_session() {
    local rc=0 out self
    out=$(TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote --permission-mode plan 2>&1) || rc=$?
    assert_eq "0" "$rc" "the window opens" || { printf '%s\n' "$out"; return 1; }
    assert_eq "new-session -d -s cs -n remote:demo -P -F #{window_id} $(window_command)" \
        "$(grep '^new-session' "$FAKE_TMUX_LOG")" "the window runs cs --remote by absolute path, marked as the window" || return 1
    assert_eq "remote:demo runs in tmux session cs (window @0). Attach: tmux switch-client -t cs" \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the caller is told where it runs" || return 1
    assert_file_not_exists "$FAKE_CLAUDE_LOG" "the caller's own terminal starts no server" || return 1
}

# tmux starts a window with the tmux server's environment, not the caller's.
# The window still serves the caller's sessions root with the claude the
# caller checked, here against a server whose root and PATH lead elsewhere.
test_remote_window_serves_the_callers_root_with_the_callers_claude() {
    local other_root="$TEST_TMPDIR/server-sessions" other_bin="$TEST_TMPDIR/server-bin" cmd
    mkdir -p "$other_root" "$other_bin"
    cp "$TEST_TMPDIR/bin/claude" "$other_bin/claude"
    TMUX="/tmp/fake,1,0" run_cs_ok demo --remote || return 1
    cmd=$(sed -n 's/^new-session -d -s cs -n remote:demo -P -F #{window_id} //p' "$FAKE_TMUX_LOG")
    [ -n "$cmd" ] || { echo "  FAIL: no window was opened"; cat "$FAKE_TMUX_LOG"; return 1; }
    CS_SESSIONS_ROOT="$other_root" PATH="$other_bin:$PATH" CLAUDE_CODE_BIN=claude TMUX="/tmp/fake,1,0" \
        run_in_its_own_group sh -c "$cmd" || return 1
    assert_eq "0" "$CS_RC" "the window's server ran" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "$(cd "$CS_SESSIONS_ROOT" && pwd -P)/demo" "$(log_value pwd)" "the window serves the caller's sessions root" || return 1
    assert_eq "$TEST_TMPDIR/bin/claude" "$(log_value bin)" "the window runs the claude the caller checked" || return 1
    [ ! -e "$other_root/demo" ] || { echo "  FAIL: the window created demo under the tmux server's root"; return 1; }
}

# Nobody sits at the server's window, so its launch asks nothing about a
# pending release, records no answer for the person and serves. Here the
# window's input ends at once; on an open input the question would wait for
# good. curl answers the signature probe, so the window's mark alone keeps
# the question away.
test_remote_window_serves_without_asking_about_an_update() {
    local cmd
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    : > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    printf '#!/bin/sh\ncase "$*" in *"/download/v2026.99.3/SHA256SUMS.sig -o "*) exit 0 ;; esac\nexit 22\n' > "$TEST_TMPDIR/bin/curl"
    chmod +x "$TEST_TMPDIR/bin/curl"
    TMUX="/tmp/fake,1,0" run_cs_ok demo --remote || return 1
    cmd=$(sed -n 's/^new-session -d -s cs -n remote:demo -P -F #{window_id} //p' "$FAKE_TMUX_LOG")
    [ -n "$cmd" ] || { echo "  FAIL: no window was opened"; cat "$FAKE_TMUX_LOG"; return 1; }
    CS_NO_UPDATE_CHECK='' CS_ASSUME_TTY=1 TMUX="/tmp/fake,1,0" run_in_its_own_group sh -c "$cmd" || return 1
    assert_eq "0" "$CS_RC" "the window's server ran" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_output_not_contains "$(cat "$TEST_TMPDIR/out")" "Update now?" "the window is not asked" || return 1
    assert_not_exists "$HOME/.cache/cs/update-declined" "no declined record" || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" "the server runs in the window" || return 1
    assert_eq "" "$(log_value CS_UNATTENDED)" "the window's mark never reaches the server" || return 1
}

test_remote_inside_tmux_without_tmux_names_remote() {
    local rc=0 out
    out=$(CS_TMUX_BIN="$TEST_TMPDIR/no-such-tmux" TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "no window opens without tmux" || return 1
    assert_eq "Error: cs --remote needs tmux" "$(printf '%s' "$out" | strip_ansi)" "the error names --remote" || return 1
}

# A server restarted at once can have its lock and remote.pid written before
# the release of the server before it wakes. That release removes only files
# that still name its own server; another process stands in for the later
# open here.
test_remote_release_leaves_the_files_of_a_later_open() {
    start_serving demo --remote || return 1
    start_unrelated_process
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/session.lock"
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    stop_serving TERM || return 1
    assert_eq "$OTHER_PID" "$(cat "$CS_SESSIONS_ROOT/demo/.cs/session.lock" 2>/dev/null)" "the later open's lock is left" || return 1
    assert_eq "$OTHER_PID" "$(cat "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" 2>/dev/null)" "the later open's remote.pid is left" || return 1
}

# A session cs --remote serves this way gets its vault detached by the
# release once the server exits, as SessionEnd detaches it after claude.
# hdiutil and mount are PATH stubs: mount reports the vault mounted until
# hdiutil detaches it, and hdiutil logs every call.
test_remote_release_detaches_the_vault_its_open_mounted() {
    run_cs_ok demo --remote || return 1
    local meta="$CS_SESSIONS_ROOT/demo/.cs" stub="$TEST_TMPDIR/stub" mnt flag="$TEST_TMPDIR/mounted"
    mkdir -p "$stub" "$meta/vault-mnt"
    mnt="$(cd "$meta/vault-mnt" && pwd -P)"
    cat > "$stub/hdiutil" << 'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_HDIUTIL_LOG"
[ "$1" = detach ] && rm -f "$FAKE_MOUNT_FLAG"
exit 0
EOF
    cat > "$stub/mount" << 'EOF'
#!/bin/sh
[ -e "$FAKE_MOUNT_FLAG" ] && echo "/dev/disk9s1 on $FAKE_MNT (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)"
echo "/dev/disk3s1 on / (apfs, sealed, local, read-only, journaled)"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$meta/local/pre-open"
    chmod +x "$stub/hdiutil" "$stub/mount" "$meta/local/pre-open"
    printf '%s\n' "$TEST_TMPDIR/demo.sparsebundle" > "$meta/local/vault"
    : > "$flag"
    FAKE_MOUNT_FLAG="$flag" FAKE_HDIUTIL_LOG="$TEST_TMPDIR/hdiutil.log" FAKE_MNT="$mnt" PATH="$stub:$PATH" \
        run_cs_ok demo --remote || return 1
    assert_eq "detach $mnt" "$(cat "$TEST_TMPDIR/hdiutil.log" 2>/dev/null)" "the release detached the vault" || { cat "$TEST_TMPDIR/out"; return 1; }
}

test_remote_inside_tmux_refuses_an_open_or_served_session_on_the_callers_terminal() {
    make_open_session demo
    local pid rc=0 out
    pid="$(cat "$CS_SESSIONS_ROOT/demo/.cs/session.lock")"
    out=$(TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session open locally is refused" || return 1
    assert_eq "Error: Session demo is live (PID $pid); cs demo --remote serves only a session that is not live. Close it first." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the open refusal" || return 1
    start_fake_server_process demo
    printf '%s\n' "$FAKE_SERVER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    rc=0
    out=$(TMUX="/tmp/fake,1,0" "$CS_BIN" demo --remote 2>&1) || rc=$?
    assert_eq "1" "$rc" "a served session is refused" || return 1
    assert_eq "Error: Session demo is served by cs demo --remote (remote-control PID $FAKE_SERVER_PID); stop it first with Ctrl-C in its window, or close the window." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the served refusal" || return 1
    assert_eq "" "$(grep -E '^new-(session|window)' "$FAKE_TMUX_LOG" 2>/dev/null || true)" "no window opens" || return 1
}

test_remote_in_its_window_serves_there_instead_of_opening_another() {
    CS_REMOTE_WINDOW=1 TMUX="/tmp/fake,1,0" run_cs_ok demo --remote || return 1
    assert_eq "[remote-control][--name][demo][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" "the server runs in the window" || return 1
    assert_eq "" "$(grep -E '^new-(session|window)' "$FAKE_TMUX_LOG" 2>/dev/null || true)" "no further window opens" || return 1
    assert_eq "" "$(log_value CS_REMOTE_WINDOW)" "the window marker never reaches the server" || return 1
}

test_remote_failure_in_its_window_waits_for_enter() {
    local rc=0 out
    out=$(FAKE_CLAUDE_MODE=exit:1 TMUX="/tmp/fake,1,0" sh -c "$(window_command)" 2>&1 <<< "") || rc=$?
    assert_eq "1" "$rc" "the window ends with the server's status" || return 1
    assert_eq "claude remote-control exited with status 1. Press Enter to close this window." \
        "$(printf '%s' "$out" | strip_ansi | tail -1)" "the window stays until the error is read" || return 1
}

test_remote_window_close_reaches_the_server() {
    local result
    result=$(TMUX="/tmp/fake,1,0" drive_on_a_terminal hangup sh -c "$(window_command)")
    assert_eq "1" "$(grep -cx 'signal HUP' "$FAKE_CLAUDE_LOG")" "the server got the hangup through the window's sh: $result" \
        || { cat "$FAKE_CLAUDE_LOG"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" || { echo "  FAIL: remote.pid is left after the server exits"; return 1; }
    gone_within_10s "$CS_SESSIONS_ROOT/demo/.cs/session.lock" || { echo "  FAIL: the lock is left after the server exits"; return 1; }
}

test_live_shows_a_served_session_as_remote_with_the_server_pid() {
    make_open_session demo
    start_fake_server_process demo
    local spid="$FAKE_SERVER_PID"
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local out
    out=$("$CS_BIN" -live 2>&1 | strip_ansi | grep ' demo ') || { echo "  FAIL: demo is not listed live"; return 1; }
    assert_output_contains "$out" "remote  remote-control PID $spid" "the agent column says remote and the status names the server" || return 1
}

test_doctor_reports_a_live_server_and_removes_a_stale_pid_file() {
    make_open_session live
    start_fake_server_process live
    local spid="$FAKE_SERVER_PID" dpid out
    printf '%s\n' "$spid" > "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid"
    mkdir -p "$CS_SESSIONS_ROOT/gone/.cs/local"
    sleep 60 > /dev/null 2>&1 &
    dpid=$!
    kill "$dpid"; wait "$dpid" 2>/dev/null || true
    printf '%s\n' "$dpid" > "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid"
    out=$("$CS_BIN" -doctor 2>&1 | strip_ansi) || true
    assert_eq "  [ OK ] Remote: live is served by claude remote-control (PID $spid)" \
        "$(grep -F 'Remote: live' <<< "$out")" "a live server is reported" || return 1
    assert_eq "  [WARN] Remote: gone's .cs/local/remote.pid named PID $dpid, which is no longer gone's claude remote-control server, and nothing removed it when that server ended; removed it now." \
        "$(grep -F 'Remote: gone' <<< "$out")" "a stale pid file is reported" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/gone/.cs/local/remote.pid" "the stale pid file is removed" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/live/.cs/local/remote.pid" "a live server's pid file is kept" || return 1
}

# A server whose release never ran (its process group killed with SIGKILL, a
# crash, a restart) leaves session.lock and remote.pid naming its pid. Once
# that pid belongs to another program, the session is not served: -live does
# not show it as remote, --force opens it as it opens any session whose lock
# names a live process, and -doctor removes the file.
test_a_remote_pid_another_process_took_over_serves_nothing() {
    run_cs_ok demo || return 1
    rm -f "$FAKE_CLAUDE_LOG"
    start_unrelated_process
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/session.lock"
    printf '%s\n' "$OTHER_PID" > "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid"
    local out
    out=$("$CS_BIN" -live 2>&1 | strip_ansi | grep ' demo ') || { echo "  FAIL: demo is not listed live"; return 1; }
    assert_output_not_contains "$out" "remote" "-live does not show the other process as demo's server: $out" || return 1
    printf '\n' > "$TEST_TMPDIR/enter"
    RUN_CS_STDIN="$TEST_TMPDIR/enter" run_cs_ok demo --force || return 1
    assert_eq "Overriding active session lock (PID $OTHER_PID)" \
        "$(strip_ansi < "$TEST_TMPDIR/out" | grep -F 'Overriding active session lock')" "--force overrides the lock" || { cat "$TEST_TMPDIR/out"; return 1; }
    assert_eq "1" "$(grep -c '^argv=' "$FAKE_CLAUDE_LOG")" "claude opened the session" || return 1
    out=$("$CS_BIN" -doctor 2>&1 | strip_ansi) || true
    assert_eq "  [WARN] Remote: demo's .cs/local/remote.pid named PID $OTHER_PID, which is no longer demo's claude remote-control server, and nothing removed it when that server ended; removed it now." \
        "$(grep -F 'Remote: demo' <<< "$out")" "the doctor reports the file" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/demo/.cs/local/remote.pid" "the doctor removes the file" || return 1
    kill -0 "$OTHER_PID" 2>/dev/null || { echo "  FAIL: the other process was stopped"; return 1; }
}

run_test test_remote_runs_remote_control_by_absolute_path_with_the_default_mode
run_test test_remote_passes_the_permission_mode_it_was_given
run_test test_remote_strips_the_api_key_and_keeps_the_cs_exports
run_test test_remote_holds_the_lock_and_records_the_server_pid_while_it_runs
run_test test_remote_says_a_staged_spawn_seed_stays_staged
run_test test_remote_shows_the_servers_error_and_exits_with_its_status
run_test test_remote_refuses_a_claude_older_than_the_measured_version
run_test test_remote_accepts_a_newer_claude_by_number_not_by_text
run_test test_remote_refuses_a_claude_that_names_no_version
run_test test_remote_refuses_a_claude_whose_version_check_fails
run_test test_remote_carries_the_permission_mode_in_claude_code_bin_and_says_so
run_test test_remote_permission_mode_given_wins_over_the_one_carried
run_test test_remote_names_carried_and_refused_options_as_written
run_test test_remote_carries_each_permission_option
run_test test_remote_refuses_options_it_cannot_drop_before_opening_anything
run_test test_remote_inside_tmux_refuses_an_option_it_cannot_drop_before_any_window
run_test test_remote_window_gets_the_command_alone_and_the_line_shows_once
run_test test_remote_with_a_wrapper_whose_version_check_fails_is_refused
run_test test_remote_refuses_a_wrapper_whose_version_is_not_claude_codes
run_test test_remote_runs_a_plain_claude_whose_version_has_no_mark
run_test test_remote_refuses_a_session_open_locally
run_test test_local_open_is_refused_while_the_session_is_served
run_test test_remote_conversation_the_server_starts_is_the_lead_and_keeps_the_lock
run_test test_phone_lead_end_removes_the_lock_once_its_server_is_gone
run_test test_phone_lead_end_removes_the_lock_when_remote_pid_serves_another_session
run_test test_phone_lead_leaves_the_servers_tmux_window_name
run_test test_lead_titles_the_tmux_window_without_a_remote_pid
run_test test_phone_lead_writes_no_tab_title_outside_tmux
run_test test_lead_writes_the_tab_title_outside_tmux_without_a_remote_pid
run_test test_phone_lead_titles_the_tmux_window_when_remote_pid_serves_another_session
run_test test_remote_stops_cleanly_when_its_window_hangs_up
run_test test_remote_stops_cleanly_on_ctrl_c
run_test test_remote_stops_cleanly_when_its_terminal_closes
run_test test_remote_stops_cleanly_on_ctrl_c_typed_at_its_terminal
run_test test_remote_refuses_force_finish_and_a_mode_without_remote
run_test test_remote_inside_tmux_opens_its_own_window_in_the_cs_session
run_test test_remote_inside_tmux_without_tmux_names_remote
run_test test_remote_release_leaves_the_files_of_a_later_open
run_test test_remote_release_detaches_the_vault_its_open_mounted
run_test test_remote_inside_tmux_refuses_an_open_or_served_session_on_the_callers_terminal
run_test test_remote_in_its_window_serves_there_instead_of_opening_another
run_test test_remote_window_serves_the_callers_root_with_the_callers_claude
run_test test_remote_window_serves_without_asking_about_an_update
run_test test_remote_failure_in_its_window_waits_for_enter
run_test test_remote_window_close_reaches_the_server
run_test test_live_shows_a_served_session_as_remote_with_the_server_pid
run_test test_doctor_reports_a_live_server_and_removes_a_stale_pid_file
run_test test_a_remote_pid_another_process_took_over_serves_nothing


# A feature session's server is named as its conversations are: with a '+'
# for the '@', the form Claude Code's SendMessage accepts.
test_remote_names_a_feature_sessions_server_with_a_plus() {
    create_test_session_with_git "myproj" > /dev/null
    run_cs_ok "myproj@feat" --remote || return 1
    assert_eq "[remote-control][--name][myproj+feat][--permission-mode][default][--spawn=same-dir]" "$(log_value argv)" \
        "remote-control gets base+feature" || return 1
}

run_test test_remote_names_a_feature_sessions_server_with_a_plus

report_results
