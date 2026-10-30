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
    # Mail is made only inside a .cs, so cs refuses to send it there: unread
    # is '-', as behind a vault that is not mounted.
    assert_eq $'legacy\t0\t-\t-\t0' "$("$CS_BIN" -list --porcelain)" "the porcelain record of a pre-.cs/ session" || return 1
}

PORCELAIN_GOLDEN="$SCRIPT_DIR/fixtures/list-porcelain.txt"

# The sessions the golden file describes. alpha is live by its lock, which
# holds this suite's own pid (running for the whole test, and nothing to
# reap), sits at 41% and has two unread messages and one read one. Its feature
# alpha@fix is a real git worktree, idle at 12% (a heartbeat long cold).
# alpha@stale is a session directory git does not register: listed, never
# counted as alpha's feature. beta's lock pid is dead, and its .cs/private
# links to a vault that is not mounted. gamma is archived, and `bad name`
# is a session cs cannot address.
make_porcelain_sessions() {
    local alpha beta p
    alpha=$(create_test_session_with_git alpha)
    printf '%s\n' "$$" > "$alpha/.cs/session.lock"
    printf '41\n' > "$alpha/.cs/local/context-pct"
    mkdir -p "$alpha/.cs/local/mail/new" "$alpha/.cs/local/mail/cur"
    printf '{}\n' > "$alpha/.cs/local/mail/new/1.json"
    printf '{}\n' > "$alpha/.cs/local/mail/new/2.json"
    printf '{}\n' > "$alpha/.cs/local/mail/cur/3.json"
    git -C "$alpha" worktree add -q -b cs/fix "$CS_SESSIONS_ROOT/alpha@fix"
    mkdir -p "$CS_SESSIONS_ROOT/alpha@fix/.cs/local"
    printf '12\n' > "$CS_SESSIONS_ROOT/alpha@fix/.cs/local/context-pct"
    touch -t 200001010000 "$CS_SESSIONS_ROOT/alpha@fix/.cs/local/context-pct"
    create_test_session alpha@stale >/dev/null
    beta=$(create_test_session beta)
    sleep 300 >/dev/null 2>&1 &
    p=$!
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    printf '%s\n' "$p" > "$beta/.cs/session.lock"
    ln -s "$TEST_TMPDIR/vault-not-mounted" "$beta/.cs/private"
    : > "$(create_test_session gamma)/.cs/archived"
    create_test_session "bad name" >/dev/null
}

# Runs <cs> -list --porcelain over the golden sessions and holds stdout to
# the golden file byte for byte, with nothing on stderr.
assert_porcelain_matches_golden() {  # cs_command...
    local rc=0
    make_porcelain_sessions
    "$@" -list --porcelain > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "cs -list --porcelain exits 0" || return 1
    assert_eq "$(cat "$PORCELAIN_GOLDEN")" "$(cat "$TEST_TMPDIR/out")" "the record set" || return 1
    cmp -s "$PORCELAIN_GOLDEN" "$TEST_TMPDIR/out" \
        || { echo "  FAIL: stdout differs from the golden file in its trailing bytes"; return 1; }
    assert_eq "" "$(cat "$TEST_TMPDIR/err")" "nothing on stderr" || return 1
}

test_list_porcelain_matches_the_golden_file() {
    assert_porcelain_matches_golden "$CS_BIN" || return 1
}

# A session with no lock is live while its statusline heartbeat (context-pct)
# is at most 900 s old, as cs -live counts it. Going idle keeps the reading.
test_list_porcelain_counts_a_heartbeat_as_live() {
    local dir when stamp
    dir=$(create_test_session solo)
    printf '30\n' > "$dir/.cs/local/context-pct"
    assert_eq $'solo\t1\t30\t0\t0' "$("$CS_BIN" -list --porcelain)" "a heartbeat written now is live" || return 1
    when=$(( $(date +%s) - 901 ))
    stamp=$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$dir/.cs/local/context-pct"
    assert_eq $'solo\t0\t30\t0\t0' "$("$CS_BIN" -list --porcelain)" "a heartbeat 901 s old is idle" || return 1
}

# The golden case under stock macOS bash 3.2, with /bin first on PATH so every
# bash cs starts is that one too. Skips where no bash lacks associative arrays.
test_list_porcelain_runs_under_old_bash() {
    local old_bash=/bin/bash
    if [ ! -x "$old_bash" ] || "$old_bash" -c 'declare -A _x' 2>/dev/null; then
        echo "    SKIP: no bash lacking associative arrays available"
        return 77
    fi
    assert_porcelain_matches_golden env "PATH=/bin:$PATH" "$old_bash" "$CS_BIN" || return 1
}

# With cs-tui on PATH and every session archived, plain -list prints the hint,
# `No sessions found` and the archived trailer; --porcelain prints none of
# them, so an empty stdout means no sessions.
test_list_porcelain_prints_only_records() {
    local rc=0 human
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/bin/cs-tui"
    chmod +x "$TEST_TMPDIR/bin/cs-tui"
    : > "$(create_test_session gamma)/.cs/archived"
    human=$(PATH="$TEST_TMPDIR/bin:$PATH" "$CS_BIN" -list 2>&1 | sed "s/$(printf '\033')\[[0-9;]*m//g")
    assert_eq "Hint: run bare 'cs' for the interactive session manager
No sessions found
1 archived (cs -list --archived)" "$human" "plain -list prints the hint, the empty notice and the trailer" || return 1
    PATH="$TEST_TMPDIR/bin:$PATH" "$CS_BIN" -list --porcelain > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
    assert_eq "0" "$rc" "cs -list --porcelain exits 0" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/out")" "stdout carries no records and nothing else" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/err")" "nothing on stderr" || return 1
}

# --porcelain lists every unarchived session and nothing else; a filter
# beside it is a usage error, in either order.
test_list_porcelain_refuses_another_option() {
    local rc args
    create_test_session alpha >/dev/null
    for args in "--porcelain --tag x" "--archived --porcelain"; do
        rc=0
        # shellcheck disable=SC2086  # args is two or three words on purpose
        "$CS_BIN" -list $args > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
        assert_eq "1" "$rc" "cs -list $args exits 1" || return 1
        assert_eq "Error: cs -list --porcelain takes no other option" \
            "$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$TEST_TMPDIR/err")" "cs -list $args names the refusal" || return 1
        assert_eq "" "$(cat "$TEST_TMPDIR/out")" "cs -list $args prints nothing on stdout" || return 1
    done
}

# A root find cannot read is an error that says why, never an empty answer:
# the panel keeps its last rows for an error and draws none for no sessions.
# The mode is put back before any assert, or teardown cannot remove the root.
test_list_porcelain_refuses_an_unreadable_root() {
    local rc=0
    if [ "$(id -u)" = 0 ]; then
        SKIP_REASON="root reads a mode 000 directory"
        echo "    SKIP: $SKIP_REASON"
        return 77
    fi
    create_test_session alpha >/dev/null
    chmod 000 "$CS_SESSIONS_ROOT"
    "$CS_BIN" -list --porcelain > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
    chmod 755 "$CS_SESSIONS_ROOT"
    assert_eq "1" "$rc" "cs -list --porcelain exits 1" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/out")" "stdout carries no records" || return 1
    assert_eq "Error: cannot list the sessions under $CS_SESSIONS_ROOT: Permission denied" \
        "$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$TEST_TMPDIR/err")" "one stderr line names the root and the OS error" || return 1
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
run_test test_tui_launch_exports_the_cs_binary_path
run_test test_list_porcelain_matches_the_golden_file
run_test test_list_porcelain_prints_only_records
run_test test_list_porcelain_refuses_another_option
run_test test_list_porcelain_refuses_an_unreadable_root
run_test test_list_porcelain_counts_a_heartbeat_as_live
run_test test_list_porcelain_runs_under_old_bash

report_results
