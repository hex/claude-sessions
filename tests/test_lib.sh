#!/usr/bin/env bash
# ABOUTME: Shared test framework for cs shell tests
# ABOUTME: Provides assertion functions, test runner, setup/teardown, and result reporting

# Guard against double-sourcing
[[ -n "${_CS_TEST_LIB_LOADED:-}" ]] && return 0
_CS_TEST_LIB_LOADED=1

set -euo pipefail

# Hooks resolve a session from the directory they are opened on, so an ambient
# CLAUDE_PROJECT_DIR binds a hook under test to a REAL session: assertions that
# it declines outside a session fail, and — worse — ones that assert silence
# stay green while the hook writes into that live session. Cleared here rather
# than in setup() because suites override setup() and this must hold for all of
# them. CS_ACTOR is cleared for the same reason: it decides resolved identity.
unset CLAUDE_PROJECT_DIR CS_ACTOR 2>/dev/null || true

# --- State ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

# --- Paths ---
# SCRIPT_DIR must be set by the sourcing test file before calling any helpers
# CS_BIN is derived from SCRIPT_DIR
CS_BIN="${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing test_lib.sh}/../bin/cs"
TEST_TMPDIR=""

# Portable octal file-mode reader. BSD (macOS) uses `stat -f "%Lp"`; GNU (Linux)
# uses `stat -c "%a"`. They are NOT interchangeable via a `stat -f ... || stat -c`
# fallback: GNU's `-f` is --file-system, which prints a block of text to stdout
# and only THEN errors on the bogus `%Lp` operand — so `$(A || B)` captures that
# leaked text concatenated with B's output. Select the implementation up front;
# only GNU stat carries --version.
_file_mode() {
    if stat --version >/dev/null 2>&1; then
        stat -c "%a" "$1"
    else
        stat -f "%Lp" "$1"
    fi
}

# Make a directory reject new files, and prove it did. A filesystem that does
# not enforce the POSIX mode bits against the owner leaves the directory
# writable after `chmod 500`, and a test modelling a FAILED write silently
# models a successful one -- it then reports the code as broken for not
# handling a failure that never happened. Returns 2 when the denial cannot be
# established, so callers skip rather than assert against a fixture that never
# reached the branch. Pair with _allow_writes.
_deny_writes() {  # dir
    local dir="$1"
    chmod 500 "$dir" 2>/dev/null || return 2
    if : > "$dir/.write-probe" 2>/dev/null; then
        rm -f "$dir/.write-probe" 2>/dev/null || true
        chmod 700 "$dir" 2>/dev/null || true
        echo "    SKIP (this filesystem does not deny the owner writes to a read-only directory)"
        return 2
    fi
    return 0
}

_allow_writes() {  # dir
    chmod 700 "$1" 2>/dev/null || true
}

# Stage one tool into a stub PATH directory, for tests that build a PATH missing
# exactly one command. Returns non-zero when the tool cannot be staged, so
# callers can say so.
_stub_tool() {  # dir, tool
    local dir="$1" tool="$2" src
    src=$(command -v "$tool" 2>/dev/null) || return 1
    # A builtin or function answers with its own name, not a path. It travels
    # with the shell, so there is nothing to stage and nothing missing.
    case "$src" in /*) ;; *) return 0 ;; esac
    [ -e "$src" ] || return 1
    ln -sf "$src" "$dir/$tool" 2>/dev/null || cp -p "$src" "$dir/$tool" 2>/dev/null || return 1
    return 0
}

# Stage a whole whitelist into a stub PATH dir. Tools genuinely absent from the
# host are skipped; a tool present but unstageable is a harness failure, since a
# silently missing one turns "X is absent" into "everything is absent".
# Staging is then proved by RUNNING one of them: a staged file can
# resolve on the PATH and still refuse to launch, which reads downstream as a
# defect in whatever the test was actually checking.
_stub_tools() {  # dir, tools...
    local dir="$1"; shift
    local t missing="" probe=""
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || continue
        if _stub_tool "$dir" "$t"; then
            case "$t" in cat|echo|true) ;; *) [ -n "$probe" ] || probe="$t" ;; esac
        else
            missing="$missing $t"
        fi
    done
    if [ -n "$probe" ]; then
        local rc=0
        PATH="$dir" "$probe" --version >/dev/null 2>&1 || rc=$?
        # Only 126 (found, not executable) and 127 (not found) mean it failed to
        # launch. Every other status says it ran, including the usage error a
        # BSD tool gives for --version, so the probe stays tool-agnostic.
        #
        # Some hosts cannot run this harness: a tool that resolves its own
        # libraries beside the executable means a
        # relocated copy will not start. Removing the PATH entries that hold the
        # suppressed tool is no better there, because rg, jq and grep share
        # /usr/bin. Return 2 for "cannot build one here" so callers skip rather
        # than report a defect in whatever they were checking.
        if [ "$rc" = "126" ] || [ "$rc" = "127" ]; then
            echo "    SKIP (a stub PATH is not constructible here: staged '$probe' will not run, exit $rc)"
            return 2
        fi
    fi
    [ -z "$missing" ] || { echo "  FAIL: could not stage into the stub PATH:$missing"; return 1; }
    return 0
}


# cs's live-duplicate guard scans the machine's whole process table for the
# session name or its UUID. The gate runs suites in parallel and many of them
# launch a session called test-session, so a suite reading the real `ps` sees a
# sibling suite's process and is told the session is already running elsewhere.
#
# This is installed at source time, not in setup(): two dozen suites define
# their own setup() and never call the shared one, and those are the heaviest
# `cs` users — the collision would stay live in exactly the suites most likely
# to hit it. Sourcing test_lib.sh is the one thing every suite does.
#
# It answers ONLY the machine-wide argv scan. The other consumers of CS_PS_BIN
# read real per-process facts and must keep getting them: lib/15-lock.sh asks
# `-o ppid=` to walk the invoker's ancestry, lib/56-presence.sh asks
# `-o pid=,lstart=` to join against recycled pids. Answering those with silence
# would make the ancestry walk fail closed and the presence join find nothing,
# so a test touching either would pass or fail on the stub's invention.
CS_PS_STUB="${TMPDIR:-/tmp}/cs-test-ps-stub.$$"
cat > "$CS_PS_STUB" <<'PSSTUB'
#!/bin/sh
for _arg in "$@"; do
    case "$_arg" in
        -*A*o|-Ao|args=) exec true ;;
    esac
done
exec /bin/ps "$@"
PSSTUB
chmod +x "$CS_PS_STUB"
export CS_PS_STUB
export CS_PS_BIN="$CS_PS_STUB"
# No EXIT trap here: several suites set their own, and the last one registered
# wins — a trap installed at source time is silently replaced, then fires in
# whichever suite did not, where `set -u` makes the expansion fatal. The stub is
# one small file under the temp dir the OS reclaims; leaking it beats owning an
# exit path that belongs to the suite.

# --- Setup / Teardown ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    # Never hit GitHub or the real ~/.cache/cs from a test session launch.
    export CS_NO_UPDATE_CHECK=1
    # Never fire iTerm2 escapes (dock bounce) at the developer's terminal from
    # a test run; the iterm2 suite re-enables this per test with its own seams.
    export CS_NO_ITERM2=1
    # Isolate from the developer's real ~/.claude/projects/ so transcript
    # discovery sees only what the test seeds. Same env var used by
    # _doctor_check_token_cost and the Phase 8 binding helpers.
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    mkdir -p "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR"
    # cs's live-duplicate guard scans the machine's whole process table for the
    # session name or UUID. Suites run in parallel and many launch a session
    # called test-session, so reading the real `ps` lets one suite see another
    # suite's process and call the session already running. Report no processes
    # by default; a test that exercises the guard overrides CS_PS_BIN with its
    # own canned output.
    # cs's terminal-theme signals are env-based, and a real cs session exports
    # them at launch. Clear them so a test controls its own inputs instead of
    # inheriting the developer's session.
    unset CS_TERM_THEME CS_TERM_BG_RGB 2>/dev/null || true
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR CS_NO_UPDATE_CHECK CS_NO_ITERM2
}

# --- Test Runner ---

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    setup
    if "$test_name" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
    teardown
}

# --- Result Reporting ---

report_results() {
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo "Failed tests:"
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
        exit 1
    fi
    echo ""
}

# --- Assertions ---

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_exists() {
    local path="$1"; local msg="${2:-$path should exist}"
    if [[ ! -e "$path" ]]; then
        echo "  FAIL: $msg (path does not exist: $path)"
        return 1
    fi
}

assert_not_exists() {
    local path="$1"; local msg="${2:-$path should not exist}"
    if [[ -e "$path" ]]; then
        echo "  FAIL: $msg (path exists: $path)"
        return 1
    fi
}

assert_dir() {
    local path="$1"; local msg="${2:-$path should be a directory}"
    if [[ ! -d "$path" ]]; then
        echo "  FAIL: $msg (not a directory: $path)"
        return 1
    fi
}

assert_symlink() {
    local path="$1"; local msg="${2:-$path should be a symlink}"
    if [[ ! -L "$path" ]]; then
        echo "  FAIL: $msg (not a symlink: $path)"
        return 1
    fi
}

assert_file_exists() {
    local path="$1"; local msg="${2:-$path should be a file}"
    if [[ ! -f "$path" ]]; then
        echo "  FAIL: $msg (not a file: $path)"
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1"; local msg="${2:-$path should not exist}"
    if [[ -f "$path" ]]; then
        echo "  FAIL: $msg (file exists: $path)"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"; local pattern="$2"; local msg="${3:-$file should contain '$pattern'}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        if [[ -f "$file" ]]; then
            echo "    file contents: $(head -20 "$file")"
        else
            echo "    file does not exist"
        fi
        return 1
    fi
}

assert_file_not_contains() {
    local file="$1"; local pattern="$2"; local msg="${3:-$file should not contain '$pattern'}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  FAIL: $msg"
        return 1
    fi
}

# Fed by here-string rather than by a pipe, and deliberately so: `grep -q` exits
# at the first match, so `echo "$output" | grep -q` leaves echo writing into a
# closed pipe. echo dies of SIGPIPE (141), `pipefail` promotes that to the
# pipeline's status, and a pattern that MATCHED is reported as a failure -- the
# earlier the match and the larger the output, the likelier it is. A here-string
# is a file, not a pipe, so there is no reader to close.
assert_output_contains() {
    local output="$1"; local pattern="$2"; local msg="${3:-output should contain '$pattern'}"
    if ! grep -q -- "$pattern" <<< "$output"; then
        echo "  FAIL: $msg"
        echo "    output: $(head -5 <<< "$output")"
        return 1
    fi
}

assert_output_not_contains() {
    local output="$1"; local pattern="$2"; local msg="${3:-output should not contain '$pattern'}"
    if grep -q -- "$pattern" <<< "$output"; then
        echo "  FAIL: $msg"
        return 1
    fi
}

# --- Terminal Helpers ---

# Run a command with a real pty on stdout and stderr, for the code paths gated
# on `[ -t 1 ]` / `[ -t 2 ]`. script(1) is the only way to get one, and its
# argument order is not portable: BSD (macOS) takes `script -q FILE CMD ARGS`,
# util-linux takes `script -q -c "CMD ARGS" FILE`. Handed the BSD form,
# util-linux treats the command as a filename and never runs it — which reads as
# "the command drew nothing" and fails rendering assertions on the Linux lane
# while every one of them passes on a mac.
_pty_run() {  # command, args...
    # A pty makes `[ -t 1 ]` true, so every terminal side effect cs normally
    # suppresses under test fires for real — including `tmux rename-window` and
    # `allow-rename off`, which renamed the DEVELOPER's live window to the
    # fixture's session name and locked it there ("cs: adopted-name" is a test
    # fixture, and it stuck because reset_tab_title never runs across cs's exec).
    # TMUX is what set_tab_title branches on, so dropping it here contains every
    # such test at the harness rather than asking each one to remember.
    if script --version 2>/dev/null | grep -q util-linux; then
        # A newline, not /dev/null: util-linux hands the child a pty that never
        # reaches EOF, so a command that stops to ask something waits on it for
        # as long as the runner allows -- a cs launch asking whether to continue
        # the previous conversation hung the whole Linux lane until the job's
        # own timeout. The newline answers the way the rest of the suite does,
        # by taking the default, and `timeout` bounds anything that asks twice
        # so the next such prompt fails in seconds and names itself.
        ( unset TMUX; printf '\n' | timeout 60 script -q -c "$*" /dev/null )
    else
        # script(1) tcgetattr's its OWN stdin and dies on a socket, which is
        # what a CI runner or an agent harness often hands it; /dev/null still
        # gets the child a pty.
        #
        # `timeout` for the same reason the util-linux arm has one, and it was
        # missing here: a command that stops to ask something on the pty waits
        # forever, since /dev/null answers nothing and the pty never reaches
        # EOF. A cs launch offering to continue a previous conversation sat on
        # that prompt for 92 minutes before anyone noticed the suite was not
        # slow but stuck. Bounded, the prompt fails in seconds and names itself.
        # stdin is inherited when the caller piped something in, so a test can
        # answer a prompt; /dev/null only when it did not, since script(1)
        # tcgetattr's its own stdin and dies on the socket a CI runner or agent
        # harness hands it.
        if [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
            ( unset TMUX; timeout 60 script -q /dev/null "$@" )
        else
            ( unset TMUX; timeout 60 script -q /dev/null "$@" < /dev/null )
        fi
    fi
}

# --- Launch Helpers ---

# Create an executable stub that prints its environment, so a test can assert
# what cs exported into the claude process. Point CLAUDE_CODE_BIN at the echoed
# path. Used by launch/theme tests in place of the default "echo" stub, which
# does not show env.
_make_env_stub() {
    local stub="$TEST_TMPDIR/claude-env-stub"
    cat > "$stub" << 'STUB_EOF'
#!/usr/bin/env bash
env
STUB_EOF
    chmod +x "$stub"
    echo "$stub"
}

# --- Session Helpers ---

# Create a minimal cs session directory structure
create_test_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{memory,local}
    printf '# Session: %s\n' "$name" > "$session_dir/.cs/README.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    echo "$session_dir"
}

# Create a session with a git repo initialized. Ships the same .gitignore
# a real `cs <name>` launch writes (see create_session_gitignore in bin/cs)
# so per-machine state (.cs/local/, *.lock, .claude/settings.local.json)
# reads as ignored rather than untracked, matching a real base session.
create_test_session_with_git() {
    local name="$1"
    local session_dir
    session_dir=$(create_test_session "$name")
    cat > "$session_dir/.gitignore" << 'GITIGNORE'
*.lock
*.tmp
*.bak
.cs/local/
.cs/archives/
.cs/.narrative-reminder-cooldown
.claude/settings.local.json
CLAUDE.local.md
.DS_Store
Thumbs.db
.vscode/
.idea/
.obsidian/
*.swp
*.swo
*~
GITIGNORE
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

# Parse a JSONL file the way cs reads it — one record per line, malformed lines
# dropped (lib/54-conversations.sh's `fromjson? // empty`) — and print each
# surviving record's .event, comma-joined. A line holding two records spliced
# together yields NEITHER, which is what makes this the right lens for a torn
# tail: it shows the loss the reader actually suffers, not the bytes on disk.
jsonl_events() {  # file
    jq -rRs '[split("\n")[] | select(length > 0) | (fromjson? // empty) | .event] | join(",")' \
        "$1" 2>/dev/null
}

# True when a file's last byte is not a newline. Command substitution strips
# trailing newlines, so a terminated file yields the empty string here.
jsonl_tail_is_torn() {  # file
    [ -s "$1" ] && [ -n "$(tail -c 1 "$1" 2>/dev/null)" ]
}
