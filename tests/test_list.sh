#!/usr/bin/env bash
# ABOUTME: Tests for `cs -list` (list_sessions), including bash 3.2 portability
# ABOUTME: Guards against bash 4+ constructs (associative arrays) breaking the listing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# `cs -list` renders the session table under the current bash.
test_list_renders_sessions() {
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "cs -list should list session alpha" || return 1
    assert_output_contains "$out" "beta" "cs -list should list session beta"
}

# `cs -list` must work under bash <4 (no associative arrays), e.g. macOS stock
# /bin/bash 3.2. Regression: list_sessions used `local -A`, which aborts there
# with "local: -A: invalid option" under set -euo pipefail. Skips when no such
# bash is available (e.g. Linux where /bin/bash is modern).
test_list_runs_under_old_bash() {
    local old_bash=/bin/bash
    if [ ! -x "$old_bash" ] || "$old_bash" -c 'declare -A _x' 2>/dev/null; then
        echo "    SKIP: no bash lacking associative arrays available"
        return 77
    fi
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out rc=0
    out=$("$old_bash" "$CS_BIN" -list 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: cs -list aborted under bash <4 (rc=$rc)"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "alpha" "cs -list should list alpha under bash <4" || return 1
    assert_output_contains "$out" "beta" "cs -list should list beta under bash <4"
}

# Homebrew's gnubin puts GNU stat first on a Mac's PATH. The MODIFIED column is
# still the session log's mtime, read in the dialect the stat on PATH speaks,
# not the one OSTYPE names. A `security` that answers nothing stands in for the
# keychain, which the listing reads secret counts from.
test_list_modified_time_with_gnu_stat_first_on_a_mac() {
    local gnubin dir out rc=0
    gnubin=$(_gnu_stat_first_dir) || { echo "    SKIP: no GNU stat on this machine"; return 77; }
    printf '#!/bin/sh\nexit 0\n' > "$gnubin/security"; chmod +x "$gnubin/security"
    dir=$(create_test_session alpha)
    printf '2020-01-02 03:04:05 - Session started\n' > "$dir/.cs/local/session.log"
    touch -t 202001020304.05 "$dir/.cs/local/session.log"
    out=$(PATH="$gnubin:$PATH" OSTYPE=darwin "$CS_BIN" -list 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -list exits 0 with GNU stat first; output: $out" || return 1
    assert_eq "alpha    2020-01-02 03:04  2020-01-02 03:04:05" \
        "$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep '^alpha ')" \
        "the row shows the log's start and its mtime" || return 1
}

# A non-session directory under the sessions root (editor config, an empty cs
# artifact) must not be listed, so that -list and tab-completion agree on what a
# session is.
test_list_omits_non_session_directories() {
    create_test_session alpha >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.obsidian"
    mkdir -p "$CS_SESSIONS_ROOT/worktrees"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "cs -list should list a real session" || return 1
    assert_output_not_contains "$out" ".obsidian" "cs -list should omit editor config" || return 1
    assert_output_not_contains "$out" "worktrees" "cs -list should omit the empty worktrees holder" || return 1
}

# A pre-.cs/ session keeps its state beside a root CLAUDE.md; -list still shows it.
test_list_includes_a_legacy_session() {
    local legacy="$CS_SESSIONS_ROOT/legacy"
    mkdir -p "$legacy/logs"
    echo "# Session" > "$legacy/CLAUDE.md"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "legacy" "cs -list should list a pre-.cs/ session" || return 1
}

# With cs-tui on PATH and every session archived, -list prints the hint,
# `No sessions found` and the archived trailer. The hint is part of the
# listing, so an option -list refuses prints the error alone.
test_list_prints_the_picker_hint_with_the_listing() {
    local rc=0 human
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/bin/cs-tui"
    chmod +x "$TEST_TMPDIR/bin/cs-tui"
    : > "$(create_test_session gamma)/.cs/archived"
    human=$(PATH="$TEST_TMPDIR/bin:$PATH" "$CS_BIN" -list 2>&1 | sed "s/$(printf '\033')\[[0-9;]*m//g")
    assert_eq "Hint: run bare 'cs' for the interactive session manager
No sessions found
1 archived (cs -list --archived)" "$human" "plain -list prints the hint, the empty notice and the trailer" || return 1
    PATH="$TEST_TMPDIR/bin:$PATH" "$CS_BIN" -list --bogus > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
    assert_eq "1" "$rc" "cs -list --bogus exits 1" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/out")" "cs -list --bogus prints no hint" || return 1
    assert_eq "Error: Unknown list option: --bogus. Usage: cs -list [--archived] [--tag <tag>]" \
        "$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$TEST_TMPDIR/err")" "cs -list --bogus prints the error alone" || return 1
}

test_tui_launch_exports_the_cs_binary_path() {
    # The picker forks cs back for its own subcommands, so cs must hand it its
    # own path. The launch itself needs a tty and a resolved cs-tui, neither of
    # which a test has, so pin the exported assignment in the built binary.
    assert_file_contains "$CS_BIN" 'CS_BIN="\$0"' "cs must export its own path to the picker" || return 1
}

echo ""
echo "cs -list tests"
echo "=============="
echo ""

run_test test_list_renders_sessions
run_test test_list_modified_time_with_gnu_stat_first_on_a_mac
run_test test_list_omits_non_session_directories
run_test test_list_includes_a_legacy_session
run_test test_list_runs_under_old_bash
run_test test_list_prints_the_picker_hint_with_the_listing
run_test test_tui_launch_exports_the_cs_binary_path

report_results
