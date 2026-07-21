#!/usr/bin/env bash
# ABOUTME: Tests for the MSYS launch guard: session prep runs to completion but
# ABOUTME: the Claude exec is skipped in favor of a "launch it from WSL" message.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# A fake CLAUDE_CODE_BIN that proves it was invoked by touching a sentinel
# file, instead of a bash function stub (the real launch happens in a
# subprocess, so a function defined in the test shell would never be seen).
_install_fake_launcher() {
    local stub="$TEST_TMPDIR/fake-claude"
    cat > "$stub" << 'STUB_EOF'
#!/usr/bin/env bash
touch "$LAUNCH_SENTINEL"
STUB_EOF
    chmod +x "$stub"
    export CLAUDE_CODE_BIN="$stub"
    export LAUNCH_SENTINEL="$TEST_TMPDIR/launched"
}

test_msys_prepares_but_does_not_launch() {
    _install_fake_launcher
    CS_PLATFORM_OVERRIDE=msys "$CS_BIN" winsess <<< "" >"$TEST_TMPDIR/out" 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/winsess" ] || return 1          # prepared
    [ ! -f "$LAUNCH_SENTINEL" ] || return 1                  # not launched
    grep -q "launch it from WSL" "$TEST_TMPDIR/out" || return 1
}

# Positive control: without the msys override (default platform on this dev
# box is macos), the same launch must still reach the real exec path. This
# guards against the msys check firing unconditionally.
test_non_msys_still_launches() {
    _install_fake_launcher
    "$CS_BIN" winsess <<< "" >"$TEST_TMPDIR/out" 2>&1 || return 1
    [ -f "$LAUNCH_SENTINEL" ] || return 1
}

# A fake tmux that proves it was invoked by touching a sentinel file. The seam
# is CS_TMUX_BIN (an env var read by a subprocess), not a bash function stub —
# a function defined in this test shell can't cross the subprocess boundary
# into "$CS_BIN" -spawn.
_install_fake_tmux() {
    local stub="$TEST_TMPDIR/fake-tmux"
    cat > "$stub" << 'STUB_EOF'
#!/usr/bin/env bash
touch "$TMUX_CALLED_SENTINEL"
STUB_EOF
    chmod +x "$stub"
    export CS_TMUX_BIN="$stub"
    export TMUX_CALLED_SENTINEL="$TEST_TMPDIR/tmux-called"
}

test_msys_refuses_spawn_before_tmux() {
    _install_fake_tmux
    local rc=0
    CS_PLATFORM_OVERRIDE=msys "$CS_BIN" -spawn foo >"$TEST_TMPDIR/out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || return 1
    [ ! -f "$TMUX_CALLED_SENTINEL" ] || return 1
    grep -q "WSL" "$TEST_TMPDIR/out" || return 1
}

run_test test_msys_prepares_but_does_not_launch
run_test test_non_msys_still_launches
run_test test_msys_refuses_spawn_before_tmux

report_results
