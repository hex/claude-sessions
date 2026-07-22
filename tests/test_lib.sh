#!/usr/bin/env bash
# ABOUTME: Shared test framework for cs shell tests
# ABOUTME: Provides assertion functions, test runner, setup/teardown, and result reporting

# Guard against double-sourcing
[[ -n "${_CS_TEST_LIB_LOADED:-}" ]] && return 0
_CS_TEST_LIB_LOADED=1

set -euo pipefail

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
_skip_on_msys() {
    local p="${CS_PLATFORM_OVERRIDE:-}"
    if [ -z "$p" ]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) p=msys ;;
            *) p=other ;;
        esac
    fi
    if [ "$p" = "msys" ]; then
        echo "    SKIP (native Windows / MSYS: launch/tmux unavailable)"
        return 0
    fi
    return 1
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
