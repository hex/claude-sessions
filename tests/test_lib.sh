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

# Skip the calling test on native Windows (Git Bash / MSYS2), where tmux and
# the Claude launch are unavailable (Tier 2 is session management only). Usage,
# at the top of a test that drives launch/tmux/spawn:
#     _skip_on_msys && return 0
# Honors CS_PLATFORM_OVERRIDE so the skip path is exercisable off Windows.
# Quiet predicate: true on native Windows / MSYS. Honors CS_PLATFORM_OVERRIDE so
# it is exercisable off Windows. Use this to guard a single MSYS-invalid
# assertion inside an otherwise-valid test; use _skip_on_msys to skip a whole one.
_is_msys() {
    local p="${CS_PLATFORM_OVERRIDE:-}"
    if [ -z "$p" ]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) p=msys ;;
            *) p=other ;;
        esac
    fi
    [ "$p" = "msys" ]
}

_skip_on_msys() {
    if _is_msys; then
        echo "    SKIP (native Windows / MSYS: launch/tmux unavailable)"
        return 0
    fi
    return 1
}

# Make a directory reject new files, and prove it did. Windows emulates the
# POSIX mode bits without enforcing them against the owner, so `chmod 500`
# leaves the directory writable there and a test modelling a FAILED write
# silently models a successful one -- it then reports the code as broken for
# not handling a failure that never happened. Returns 2 when the denial cannot
# be established, so callers skip rather than assert against a fixture that
# never reached the branch. Pair with _allow_writes.
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

# The host itself, ignoring CS_PLATFORM_OVERRIDE. _is_msys answers what the code
# under test should believe, which a suite may pin (SUITE_PIN_NONMSYS) so a
# platform-gated path runs on Windows CI. Anything that touches the real
# filesystem must ask this instead: a suite pretending to be Linux is still
# writing to an NTFS volume where an executable needs its .exe name.
_is_real_msys() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# Stage one tool into a stub PATH directory, for tests that build a PATH missing
# exactly one command. Two Git Bash behaviours conspire here: `command -v grep`
# answers /usr/bin/grep though the file is grep.exe (MSYS hides the suffix from
# `command -v` and from `[ -e ]` alike), and `ln -s` copies rather than links.
# A copy of an .exe under a name Windows does not recognise as executable will
# not launch, so the stub PATH loses every tool instead of the one under
# suppression, and the test then fails somewhere unrelated to its subject.
# On Windows both spellings are written; elsewhere the reported path is enough.
# Returns non-zero when the tool cannot be staged, so callers can say so.
_stub_tool() {  # dir, tool
    local dir="$1" tool="$2" src
    src=$(command -v "$tool" 2>/dev/null) || return 1
    # A builtin or function answers with its own name, not a path. It travels
    # with the shell, so there is nothing to stage and nothing missing.
    case "$src" in /*) ;; *) return 0 ;; esac
    [ -e "$src" ] || src="${src}.exe"
    [ -e "$src" ] || return 1
    if _is_real_msys; then
        # Copy outright rather than trying `ln -s` first. It SUCCEEDS there
        # while writing a placeholder Windows will not execute, so the `||`
        # fallback never runs and the stub fills with files that resolve on the
        # PATH and then fail to launch. Both names, since the loader wants .exe
        # and the callers spell the tool without it.
        cp -p "$src" "$dir/$tool" 2>/dev/null || return 1
        cp -p "$src" "$dir/$tool.exe" 2>/dev/null || return 1
        return 0
    fi
    ln -sf "$src" "$dir/$tool" 2>/dev/null || cp -p "$src" "$dir/$tool" 2>/dev/null || return 1
    case "$src" in
        *.exe) ln -sf "$src" "$dir/$tool.exe" 2>/dev/null \
                   || cp -p "$src" "$dir/$tool.exe" 2>/dev/null || true ;;
    esac
    return 0
}

# Stage a whole whitelist into a stub PATH dir. Tools genuinely absent from the
# host are skipped; a tool present but unstageable is a harness failure, since a
# silently missing one turns "X is absent" into "everything is absent".
# Staging is then proved by RUNNING one of them: on Windows a staged file can
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
        # Git Bash cannot host this harness at all: its coreutils link against
        # msys-2.0.dll, which Windows resolves beside the executable, so a
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

# Install a jq shim (on $TEST_TMPDIR/crlfbin, echoed for prepending to PATH)
# that wraps the real jq and re-emits every output line with CRLF, reproducing
# native jq.exe under Git Bash — where stdout runs in text mode and `read`
# leaves a trailing \r on each extracted field. Lets the CR-handling paths be
# exercised on any platform. Returns non-zero (skip) when jq is unavailable.
_install_crlf_jq() {
    local real_jq shimdir
    real_jq="$(command -v jq)" || return 1
    shimdir="$TEST_TMPDIR/crlfbin"
    mkdir -p "$shimdir"
    cat > "$shimdir/jq" <<STUB
#!/usr/bin/env bash
"$real_jq" "\$@" | while IFS= read -r _l; do printf '%s\r\n' "\$_l"; done
STUB
    chmod +x "$shimdir/jq"
    printf '%s' "$shimdir"
}

# Install a jq shim reproducing what a COMMAND SUBSTITUTION sees on Git Bash:
# jq.exe emits CRLF, but MSYS bash strips the trailing \r\n along with the
# trailing newline, so every line EXCEPT the last arrives carrying a \r. That
# asymmetry is what makes a multi-key loop corrupt every key but the final one
# while the final one looks perfectly healthy. Echoes the dir to prepend to
# PATH; returns non-zero (skip) when jq is unavailable.
_install_msys_jq() {
    local real_jq shimdir
    real_jq="$(command -v jq)" || return 1
    shimdir="$TEST_TMPDIR/msysjqbin"
    mkdir -p "$shimdir"
    cat > "$shimdir/jq" <<STUB
#!/usr/bin/env bash
"$real_jq" "\$@" | awk 'NR>1 { printf "\r\n" } { printf "%s", \$0 } END { if (NR) printf "\n" }'
STUB
    chmod +x "$shimdir/jq"
    printf '%s' "$shimdir"
}

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

# Suites that drive the Claude launch path set SUITE_PIN_NONMSYS=1 at the top of
# the file. On a real MSYS runner the launch short-circuits (Tier 2 is session
# management only), so those tests would never reach the behavior they assert.
# Pin a supported non-msys platform there so the launch path runs on Windows CI.
# Fires ONLY when the real platform is msys and no explicit override is set, so
# the macOS and Linux lanes keep exercising their own platform. linux (not macos)
# is used: it reaches the launch path without any macOS-only tool calls.
_apply_suite_platform_pin() {
    [ "${SUITE_PIN_NONMSYS:-}" = "1" ] || return 0
    [ -z "${CS_PLATFORM_OVERRIDE:-}" ] || return 0
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) export CS_PLATFORM_OVERRIDE=linux ;;
    esac
}

# --- Test Runner ---

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  $test_name..."
    setup
    _apply_suite_platform_pin
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

assert_output_contains() {
    local output="$1"; local pattern="$2"; local msg="${3:-output should contain '$pattern'}"
    if ! echo "$output" | grep -q -- "$pattern"; then
        echo "  FAIL: $msg"
        echo "    output: $(echo "$output" | head -5)"
        return 1
    fi
}

assert_output_not_contains() {
    local output="$1"; local pattern="$2"; local msg="${3:-output should not contain '$pattern'}"
    if echo "$output" | grep -q -- "$pattern"; then
        echo "  FAIL: $msg"
        return 1
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
