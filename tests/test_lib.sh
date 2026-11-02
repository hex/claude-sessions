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
# The two conversation ids go too: doctor judges the shadow ref of whichever id
# it inherits, so a suite run inside a live conversation would check that
# conversation's ref instead of the state the test set up.
# CLAUDE_CONFIG_DIR goes because it outranks HOME: an install or uninstall
# under a fake HOME would still read and write the keybindings.json of the
# config dir the suite was started from.
# The session identity goes because cs trusts it: a send under test files its
# sent copy in the mailbox of the session the suite was started from, and
# signs the mail with that session's name.
unset CLAUDE_PROJECT_DIR CS_ACTOR CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR 2>/dev/null || true
# CS_SECRETS_SESSION is the same identity for cs-secrets, which reads it ahead
# of the session name: a feature worktree exports its base session there.
# CS_SECRETS_CALLER is the session cs-secrets refuses writes on behalf of,
# set by cs's -secrets arms and read ahead of CLAUDE_SESSION_NAME.
unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_SECRETS_SESSION CS_SECRETS_CALLER 2>/dev/null || true
# CS_CLAUDE_DIR outranks HOME for Claude Code's settings.json, and a
# SessionStart hook appends the session it ran for to CLAUDE_ENV_FILE.
unset CS_CLAUDE_DIR CLAUDE_ENV_FILE 2>/dev/null || true
# CLAUDE_PID and CS_LEAD_PID name the claude a hook fires for and the cs that
# launched it: inherited, a hook under test reads the caller's own process, so
# a suite run by a tmux teammate sees a teammate and one run by a lead sees
# the lead. A test that models either sets it itself. CS_LEAD_CLAIM says the
# launch takes the lead's claim; inherited from a lead's launch, it would turn
# the claim on for a test that models a launch without it.
unset CLAUDE_PID CS_LEAD_PID CS_LEAD_CLAIM 2>/dev/null || true
# stop-notices.sh waits for stop-blocks.sh's verdict on the same Stop
# before it speaks, up to CS_STOP_VERDICT_WAIT seconds. A suite runs the two
# hooks one at a time, so the verdict never comes and every lead Stop would
# pay the whole wait; the handshake tests set the wait themselves.
export CS_STOP_VERDICT_WAIT=0

# --- State ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILURES=()
SKIPS=()
# Why the running test skipped, when its guard knows: require_tool sets it,
# run_test clears it before each test and records it with the skip.
SKIP_REASON=""
# The tools CI declares (CS_TEST_REQUIRE_TOOLS) and the file run_all.sh
# collects skips in (CS_TEST_SKIP_LOG), read once here. Several suites unset
# every exported CS_* variable in setup(), which runs before each test, so
# require_tool and run_test read these unexported copies instead.
_cs_test_require_tools="${CS_TEST_REQUIRE_TOOLS:-}"
_cs_test_skip_log="${CS_TEST_SKIP_LOG:-}"

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
# only GNU stat carries --version. Reads through a symlink (-L), so a linked
# file reports its target's mode, not the link's own 755.
_file_mode() {
    if stat --version >/dev/null 2>&1; then
        stat -L -c "%a" "$1"
    else
        stat -L -f "%Lp" "$1"
    fi
}

# A directory whose `stat` is GNU coreutils' stat, for a caller to put first on
# PATH the way Homebrew's gnubin does on a Mac. GNU stat reads -f as
# --file-system and prints text instead of failing, so code that asks BSD
# stat first reads that text. Callers also run cs with OSTYPE=darwin, so a
# Linux runner, whose own stat is GNU, stands in for that Mac (bash keeps an
# OSTYPE it inherits). Prints the directory; fails when this machine has no
# GNU stat, and the caller skips.
_gnu_stat_first_dir() {
    local c gnu=""
    for c in gstat /opt/homebrew/opt/coreutils/libexec/gnubin/stat \
        /usr/local/opt/coreutils/libexec/gnubin/stat stat; do
        c=$(command -v "$c" 2>/dev/null) || continue
        if "$c" --version 2>/dev/null | grep -q 'GNU coreutils'; then
            gnu="$c"
            break
        fi
    done
    [ -n "$gnu" ] || return 1
    mkdir -p "$TEST_TMPDIR/gnubin"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$gnu" > "$TEST_TMPDIR/gnubin/stat"
    chmod +x "$TEST_TMPDIR/gnubin/stat"
    printf '%s\n' "$TEST_TMPDIR/gnubin"
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
    if { : > "$dir/.write-probe"; } 2>/dev/null; then
        rm -f "$dir/.write-probe" 2>/dev/null || true
        chmod 700 "$dir" 2>/dev/null || true
        echo "    SKIP (this filesystem does not deny the owner writes to a read-only directory)"
        return 2
    fi
    return 0
}

# Stage a read-only FILE and confirm this process is actually denied writing
# through it: as root, or on a filesystem that ignores mode bits, chmod 400
# denies nothing and a test built on it would report broken error handling in
# code that is fine. Returns 2 when the write is not denied, the same shape
# _deny_writes uses, so callers return 77 (skipped).
_deny_file_write() {  # path
    local f="$1"
    : > "$f" 2>/dev/null || return 2
    chmod 400 "$f" 2>/dev/null || return 2
    if { : > "$f"; } 2>/dev/null; then
        chmod 600 "$f" 2>/dev/null || true
        rm -f "$f" 2>/dev/null || true
        echo "    SKIP (this filesystem does not deny the owner writes to a read-only file)"
        return 2
    fi
    return 0
}

# The guard for a test that needs a command: `require_tool <tool>... || return $?`.
# Every tool on PATH returns 0. A missing tool skips the test (77), unless
# CS_TEST_REQUIRE_TOOLS, a space-separated list, names it: CI declares the
# tools its job installs, and there a missing one is a broken runner, so the
# test fails naming it instead of reading green having judged nothing. Every
# tool is checked first, so a declared one fails even behind an undeclared one.
# Call it directly, never inside $( ), and pass its status through unchanged:
# a helper's caller that maps any failure to 77 turns the failure back into
# a skip.
require_tool() {  # tool...
    local tool missing="" declared_missing=0
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 && continue
        case " $_cs_test_require_tools " in
            *" $tool "*)
                echo "    FAIL: $tool is not on PATH, and CS_TEST_REQUIRE_TOOLS says this run has it"
                declared_missing=1
                ;;
            *) missing="${missing:+$missing }$tool" ;;
        esac
    done
    [ "$declared_missing" -eq 0 ] || return 1
    [ -n "$missing" ] || return 0
    echo "    SKIP: $missing not on PATH"
    SKIP_REASON="$missing not on PATH"
    return 77
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

# Name claude's per-project transcript dir for a cwd the way Claude Code does:
# realpath it, then replace every character outside [A-Za-z0-9] with '-'
# (2.1.289: `.replace(/[^a-zA-Z0-9]/g,"-")`). Tests seed transcripts at this
# name so cs's discovery (_claude_project_dir) finds them.
_encode_cwd_for_claude_test() {  # cwd
    local resolved
    resolved=$(cd "$1" && pwd -P)
    printf '%s' "$resolved" | sed 's/[^A-Za-z0-9]/-/g'
}

# Stage a `mount` into dir that prints the given lines as the mount table, for
# a test that runs cs with dir first on PATH. Returns non-zero when the stub
# cannot be staged.
_stub_mount_table() {  # dir, line...
    local dir="$1"; shift
    mkdir -p "$dir" || return 1
    printf '%s\n' "$@" > "$dir/table" || return 1
    printf '#!/bin/sh\ncat "%s"\n' "$dir/table" > "$dir/mount" || return 1
    chmod +x "$dir/mount"
}

# Stage a `mount` into dir that fails to read the mount table. Returns non-zero
# when the stub cannot be staged.
_stub_mount_unreadable() {  # dir
    mkdir -p "$1" || return 1
    printf '#!/bin/sh\necho "mount: cannot read table" >&2\nexit 1\n' > "$1/mount" || return 1
    chmod +x "$1/mount"
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

# --- Suite-wide isolation, applied when this file is sourced ---
#
# At source time rather than in setup(): 22 suites define their own setup()
# and never call this one, so anything placed there reaches only the suites
# that happen to inherit it. Sourcing is the one step every suite shares.
#
# A private HOME per suite process. A test that seeds a secret, a config
# marker or a settings.json must never land it in the developer's real
# dotfiles, and a launched cs must never write the real update cache.
# git reads its identity from $HOME/.gitconfig, so the real one is carried
# across in env-var form first, with a placeholder when there is none:
# a bare CI runner has no global config, and every session-creating suite
# commits.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || echo cs-test)}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo cs-test@example.com)}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export HOME="$(mktemp -d)/home"
mkdir -p "$HOME"
# XDG_DATA_HOME inherited from the developer's shell would point the install
# and uninstall tests at the real data directory, whatever HOME says. Scoped
# here, at source time, as HOME is. XDG_CONFIG_HOME does the same to cs's
# per-machine preferences, which an uninstall under test deletes.
unset XDG_DATA_HOME XDG_CONFIG_HOME
# The scope-prompt hook's own deadline (CS_SCOPE_BUDGET_MS) is off the table
# for every suite that drives the hook: tests time nothing, and a loaded
# runner must not turn a scan assertion into a skip. The deadline tests in
# test_scope_prompt.sh set their own budgets per run.
# Eight suites unset every CS_* variable in their own setup(): clarify,
# objective_capture, prompt_rewriter, prompt_rewriter_model,
# prompt_rewriter_vendor, scope_prompt, statusline and subagent_statusline.
# The two that assert on the scope block (test_clarify.sh,
# test_scope_prompt.sh) set it again there. The same loop drops CS_PS_BIN,
# CS_TITLE_TTY and CS_NO_UPDATE_CHECK, which costs nothing: none of the eight
# reaches the code that reads them (the lock walk, presence, launch, the
# update check and the SessionStart hook). Do not re-fix; a suite that
# starts to run one of those sets the variable again after its loop.
export CS_SCOPE_BUDGET_MS="600000"
# The SessionStart hook re-asserts the session's tab title: through the tmux
# server when TMUX is set, else as an escape on a terminal device. Fourteen
# suites run that hook, and under the developer's own tmux the fixture's name
# lands on the live window (`cs: test-session`). Scoped here, at source time,
# so no suite has to remember to.
unset TMUX TMUX_PANE
export CS_TITLE_TTY="$HOME/title-tty"
# A title claim under iTerm2 also runs the iTerm tab helper, which reaches the
# developer's real iTerm through its Python API. Dropped here for the same
# reason as TMUX; the tab-helper tests set it per call.
unset LC_TERMINAL
export CS_NO_UPDATE_CHECK=1
# The binaries under review come first on PATH, so a test that runs
# `cs-secrets` exercises this tree and not whatever install.sh last put in
# ~/.local/bin — and CI, which installs nothing, finds them at all.
_CS_TEST_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin"
case ":$PATH:" in *":$_CS_TEST_BIN:"*) ;; *) export PATH="$_CS_TEST_BIN:$PATH" ;; esac

# Retire moves ignored files to the system trash with `trash` (macOS) or
# `gio trash` (Linux). No test may reach the developer's real trash: these
# stand-ins come first on PATH for every suite and refuse loudly. A test that
# exercises the trash puts its own stand-in in front (fake_trash_bin).
_CS_TEST_TRASH_GUARD="${HOME%/home}/trash-guard"
mkdir -p "$_CS_TEST_TRASH_GUARD"
for _cs_trash_cmd in trash gio; do
    printf '#!/usr/bin/env bash\necho "a test reached the system trash command: %s $*" >&2\nexit 1\n' \
        "$_cs_trash_cmd" > "$_CS_TEST_TRASH_GUARD/$_cs_trash_cmd"
    chmod +x "$_CS_TEST_TRASH_GUARD/$_cs_trash_cmd"
done
unset _cs_trash_cmd
export PATH="$_CS_TEST_TRASH_GUARD:$PATH"

# A directory holding a stand-in for the system trash command, to put first
# on PATH: named `trash`, or `gio` taking `trash` as its first argument. Both
# record each path they are given in $TEST_TMPDIR/trash.log; `moves` then
# moves each into $TEST_TMPDIR/trash-bin as <n>-<name>, `fails` moves nothing
# and exits 1.
fake_trash_bin() {  # moves|fails trash|gio
    local bin="$TEST_TMPDIR/fake-$2-$1" log="$TEST_TMPDIR/trash.log" can="$TEST_TMPDIR/trash-bin"
    mkdir -p "$bin" "$can"
    {
        echo '#!/usr/bin/env bash'
        [ "$2" = gio ] && echo '[ "$1" = trash ] || { echo "gio: unexpected command $1" >&2; exit 2; }; shift'
        echo "for p in \"\$@\"; do printf '%s\\n' \"\$p\" >> '$log'; done"
        if [ "$1" = moves ]; then
            echo "n=0; for p in \"\$@\"; do n=\$((n + 1)); mv \"\$p\" '$can'/\"\$n-\${p##*/}\" || exit 1; done"
        else
            echo "echo 'trash: the items could not be moved (stand-in failure)' >&2; exit 1"
        fi
    } > "$bin/$2"
    chmod +x "$bin/$2"
    echo "$bin"
}

# --- Setup / Teardown ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
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

# Status 77 is "skipped", not "passed": a test whose fixture the machine cannot
# produce (a privilege it does not have, a kernel answer it cannot provoke) has
# proven nothing, and counting it as OK is how missing coverage hides. The test
# says why on its way out; the tally keeps skips in their own column so a run
# that skips everything cannot read as a green one. Under run_all.sh each skip
# is also appended to CS_TEST_SKIP_LOG as the test's name, a tab and the
# reason require_tool gave (empty for any other skip), which is where the
# gate's summary counts them.
# How many tests the running suite will call, counted once: its `run_test`
# lines whose test is a function the suite defines over several lines. A
# one-line test body belongs to a throwaway suite written inside a string
# (test_harness.sh, test_run_all.sh), and its run_test lines are not this
# suite's. A suite that calls run_test from a loop under-counts, and the
# counter then reads past its total rather than lying about a test's place.
_cs_test_total() {
    if [ -z "${_CS_TEST_TOTAL:-}" ]; then
        _CS_TEST_TOTAL=$(awk '
            FNR == NR { if (match($0, /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{ *$/)) { sub(/\(\).*/, ""); def[$0] = 1 }; next }
            /^run_test / && ($2 in def) { c++ }
            END { print c + 0 }' "$0" "$0" 2>/dev/null || echo 0)
    fi
    printf '%s' "$_CS_TEST_TOTAL"
}

run_test() {
    local test_name="$1" status=0
    TESTS_RUN=$((TESTS_RUN + 1))
    SKIP_REASON=""
    echo "  [$TESTS_RUN/$(_cs_test_total)] $test_name..."
    setup
    "$test_name" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "    OK"
    elif [ "$status" -eq 77 ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        SKIPS+=("$test_name")
        if [ -n "$_cs_test_skip_log" ]; then
            printf '%s\t%s\n' "$test_name" "$SKIP_REASON" >> "$_cs_test_skip_log"
        fi
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$test_name")
    fi
    teardown
}

# --- Result Reporting ---

report_results() {
    local skip_column=""
    [[ ${TESTS_SKIPPED:-0} -gt 0 ]] && skip_column=", $TESTS_SKIPPED skipped"
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed$skip_column"
    if [[ ${#SKIPS[@]} -gt 0 ]]; then
        echo "Skipped tests:"
        for s in "${SKIPS[@]}"; do
            echo "  - $s"
        done
    fi
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

# Fails when <text> holds an ESC (0x1b) or BEL (0x07) byte, the bytes that
# start and end a terminal escape sequence.
assert_no_escape_bytes() {
    local text="$1" msg="${2:-}" n
    n=$(printf '%s' "$text" | LC_ALL=C tr -dc '\033\007' | wc -c | tr -d ' ')
    if [[ "$n" != 0 ]]; then
        echo "  FAIL: $msg ($n ESC or BEL bytes)"
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

# The text of the one notice stop-notices.sh printed: its output must be exactly
# one {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":<text>}}
# and nothing else. Any other output, a block or approve decision among it,
# prints "not a notice" alone, so neither an exact nor a contains assert on the
# text can pass on it; the output itself goes to stderr for the failure log.
stop_notice_text() {  # hook output
    jq -sre 'if length == 1 and (.[0] | type) == "object"
                and (.[0] | keys) == ["hookSpecificOutput"]
                and (.[0].hookSpecificOutput | keys) == ["additionalContext", "hookEventName"]
                and .[0].hookSpecificOutput.hookEventName == "Stop"
                and (.[0].hookSpecificOutput.additionalContext | type) == "string"
             then .[0].hookSpecificOutput.additionalContext else error end' <<< "$1" 2>/dev/null \
        || { printf 'not a notice'; printf '    hook output: %s\n' "$1" >&2; }
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
        # No `timeout` on this arm, unlike the util-linux one: timeout is GNU
        # coreutils and stock BSD userland has none, so calling it here fails
        # every pty suite on macos-latest with "command not found". Backgrounding
        # script(1) under a watchdog instead costs it the controlling terminal it
        # exists to provide. So a command that stops to ask something WILL hang
        # this arm — a test that would prompt belongs on a plain pipe, where the
        # same output renders and a here-string can answer.
        ( unset TMUX; script -q /dev/null "$@" < /dev/null )
    fi
}

# Runs a command in its own process group and kills the whole group once $1
# seconds pass: install.sh and cs set an EXIT trap, and a shell holding one
# puts off a signal until the command substitution it waits on returns, so
# signalling the shell alone never stops one blocked inside a substitution.
# Exits with the command's status, or 142 when the time ran out.
_run_bounded() {  # seconds, command...
    perl -e '
        my $secs = shift;
        my $pid = fork;
        defined $pid or die "fork: $!\n";
        if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n" }
        my $late = 0;
        $SIG{ALRM} = sub { $late = 1; kill "KILL", -$pid };
        alarm $secs;
        1 while waitpid($pid, 0) == -1 && $!{EINTR};
        exit 142 if $late;
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$@"
}

# Runs <command> until it succeeds, so a test waits on the event it means and
# not on a count of polls: a loaded machine starts a detached writer seconds
# late, and the count runs out first. The 120 s guard only stops a hang.
# Returns 0 once the command succeeds, else 1 at the guard. Prints nothing; the
# test's own assertion after the wait says what was missing. A condition that
# needs more than one command goes in a small function passed by name.
wait_until() {  # command...
    local deadline=$((SECONDS + 120))
    until "$@"; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.05
    done
}

# Exits 0 when ps shows <pattern> in the command line of <pid>, printing
# nothing. A script started in the background shows the shell that forked it
# until it has exec'd, so a test that hands its pid on for its argv to be read
# waits on this first: wait_until pid_args_match "$pid" fake-claude.
pid_args_match() {  # pid, pattern
    ps -o args= -p "$1" 2>/dev/null | grep -q -- "$2"
}

# Waits until <file> exists or <pid>, a child of this shell, has exited, so a
# test waits on the step it means and not on a count of polls that load
# stretches or shrinks. The 300 s guard only stops a hang. Returns 0, printing
# nothing, once the file is there. Otherwise prints "  FAIL: <what>: " and why,
# and returns 1: the exit status when the pid exited first (it is reaped here),
# or "not there after 300 s", the pid then killed. The file's existence is the
# event, so its writer makes it whole in one step (a touch, or a write and a mv).
wait_for_file_or_exit() {  # file, pid, what
    local deadline=$((SECONDS + 300)) rc=0
    while [ ! -e "$1" ] && kill -0 "$2" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 0.05
    done
    [ -e "$1" ] && return 0
    if kill -0 "$2" 2>/dev/null; then
        kill -KILL "$2" 2>/dev/null
        echo "  FAIL: $3: not there after 300 s"
    else
        wait "$2" || rc=$?
        echo "  FAIL: $3: it exited first, status $rc"
    fi
    return 1
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

# Point CLAUDE_CODE_BIN, exported, at a claude stub that appends "launched" to
# $TEST_TMPDIR/launched on each launch, so a test can tell a refusal from a
# launch. The export lands in the calling shell; a call inside $(...) would
# leave CLAUDE_CODE_BIN as it was.
_make_launch_sentinel() {
    printf '#!/bin/bash\necho launched >> "%s"\n' "$TEST_TMPDIR/launched" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude"
}

# Mark a session's vault as set up by hand: such a vault mounts from
# .cs/local/pre-open, and only while one exists may the four vault links lead
# outside the session. The script does nothing; the test mounts nothing.
_mark_hand_made_vault() {  # session_dir
    mkdir -p "$1/.cs/local"
    printf '#!/bin/sh\nexit 0\n' > "$1/.cs/local/pre-open"
    chmod +x "$1/.cs/local/pre-open"
}

# Write a BASH_ENV file whose DEBUG trap removes <session_dir> just after a
# cs verb's own "is the .cs there" check ([ -d "$CLAUDE_SESSION_META_DIR" ])
# passes, the way `cs -rm --force` can land while the verb runs, so the
# writers behind that check are what meet the removal. It removes once and
# leaves <file>.removed when it has. Prints the file's path.
_seam_remove_after_the_meta_check() {  # session_dir
    local seam="$TEST_TMPDIR/seam-after-check.sh"
    {
        printf 'SEAM_DIR=%q\nSEAM_MARK=%q\n' "$1" "$seam"
        cat <<'SEAM'
set -o functrace
_seam_after_check() {
    [ ! -e "$SEAM_MARK.removed" ] || return 0
    if [ -e "$SEAM_MARK.armed" ]; then
        rm -rf "$SEAM_DIR"; : > "$SEAM_MARK.removed"; return 0
    fi
    case "$BASH_COMMAND" in '[ -d "$CLAUDE_SESSION_META_DIR" ]') : > "$SEAM_MARK.armed" ;; esac
    return 0
}
trap _seam_after_check DEBUG
SEAM
    } > "$seam"
    printf '%s' "$seam"
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

# The line of <output> that is exactly <row>, then the line under it: a
# notice row and the action line cs prints beneath it.
row_and_action() {  # output, row
    printf '%s\n' "$1" | grep -F -x -A1 -- "$2"
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

# Fills directory $1 with links to every command on the current PATH except
# those whose name matches glob $2, for a PATH that lacks a tool (jq, perl).
link_path_without() {  # dir, name glob
    local dir f IFS=:
    mkdir -p "$1"
    for dir in $PATH; do
        for f in "$dir"/*; do
            [ -x "$f" ] && [ ! -d "$f" ] || continue
            # shellcheck disable=SC2254  # the glob is the caller's pattern
            case "${f##*/}" in $2) continue ;; esac
            [ -e "$1/${f##*/}" ] || ln -s "$f" "$1/${f##*/}"
        done
    done
}

# Every bash this machine offers, one path a line: /bin/bash, then each other
# one on PATH. A Mac with Homebrew has two (3.2 and 5.x); a Linux runner one.
every_bash() {
    local seen=" " b
    for b in /bin/bash $(type -aP bash 2>/dev/null); do
        [ -x "$b" ] || continue
        case "$seen" in *" $b "*) continue ;; esac
        seen="$seen$b "
        printf '%s\n' "$b"
    done
}

# A UTF-8 locale this machine has, empty when it has none.
utf8_locale() {
    local have name
    have="$(locale -a 2>/dev/null || true)"
    for name in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
        case "
$have
" in *"
$name
"*) printf '%s' "$name"; return 0 ;; esac
    done
}

# The locale assignments a bash made to itself, read from the set -x trace in
# file $1 (default PS4): a temporary `LC_ALL=C cmd` traces as a line of its
# own, while a locale handed to a command as an argument of env traces inside
# the env line. Empty when the shell assigned none.
shell_locale_assignments() {  # trace file
    grep -E '^\++ ((local|export|declare|typeset|readonly) )?(LC_[A-Z_]+|LANG|LANGUAGE)=' "$1" || true
}
