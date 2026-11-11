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

# Each row's MODIFIED is its own log's mtime, and a session with no log reads
# '-' without shifting the times of the sessions listed after it. Run in both
# stat dialects where this machine has both: the system stat, then GNU first.
test_list_modified_time_belongs_to_its_own_row() {
    local alpha gamma out rc=0 secs="" gnubin
    alpha=$(create_test_session alpha)
    create_test_session beta >/dev/null
    gamma=$(create_test_session gamma)
    printf '2020-01-02 03:04:05 - Session started\n' > "$alpha/.cs/local/session.log"
    touch -t 202001020304.05 "$alpha/.cs/local/session.log"
    printf '2021-02-03 04:05:06 - Session started\n' > "$gamma/.cs/local/session.log"
    touch -t 202102030405.06 "$gamma/.cs/local/session.log"
    _list_rows_match() {
        assert_eq "0" "$rc" "cs -list exits 0; output: $out" || return 1
        local rows
        rows=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -E '^(alpha|beta|gamma) ')
        assert_eq "alpha    2020-01-02 03:04  2020-01-02 03:04$1
beta     -                 -
gamma    2021-02-03 04:05  2021-02-03 04:05$2" "$rows" "each row shows its own log's mtime"
    }
    # An empty keychain, so a real one on this machine cannot add a count.
    mkdir -p "$TEST_TMPDIR/nokeys"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/nokeys/security"; chmod +x "$TEST_TMPDIR/nokeys/security"
    stat -c %y /dev/null >/dev/null 2>&1 && secs=yes
    out=$(PATH="$TEST_TMPDIR/nokeys:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    if [ -n "$secs" ]; then _list_rows_match ":05" ":06" || return 1
    else _list_rows_match "" "" || return 1; fi
    gnubin=$(_gnu_stat_first_dir) || return 0
    printf '#!/bin/sh\nexit 0\n' > "$gnubin/security"; chmod +x "$gnubin/security"
    rc=0
    out=$(PATH="$gnubin:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    _list_rows_match ":05" ":06" || return 1
}

# The listing reads every log's mtime with one stat. A stat that answers only
# some of the files and fails, as when a log goes between the listing finding it
# and reading it, still leaves each row with its own log's time: the stand-in
# drops the last file's line from any call naming several files.
test_list_modified_time_survives_a_stat_that_misses_a_file() {
    local alpha beta fakebin="$TEST_TMPDIR/partialstat" real_stat out rc=0 rows secs=""
    real_stat=$(command -v stat)
    alpha=$(create_test_session alpha)
    beta=$(create_test_session beta)
    printf '2020-01-02 03:04:05 - Session started\n' > "$alpha/.cs/local/session.log"
    touch -t 202001020304.05 "$alpha/.cs/local/session.log"
    printf '2021-02-03 04:05:06 - Session started\n' > "$beta/.cs/local/session.log"
    touch -t 202102030405.06 "$beta/.cs/local/session.log"
    mkdir -p "$fakebin"
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/security"
    cat > "$fakebin/stat" <<EOF
#!/bin/bash
files=0
for a in "\$@"; do case "\$a" in /*) files=\$((files + 1)) ;; esac; done
[ "\$files" -gt 1 ] || exec "$real_stat" "\$@"
"$real_stat" "\$@" | sed '\$d'
exit 1
EOF
    chmod +x "$fakebin/security" "$fakebin/stat"
    "$real_stat" -c %y /dev/null >/dev/null 2>&1 && secs=yes
    out=$(PATH="$fakebin:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -list exits 0; output: $out" || return 1
    rows=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -E '^(alpha|beta) ')
    if [ -n "$secs" ]; then
        assert_eq "alpha    2020-01-02 03:04  2020-01-02 03:04:05
beta     2021-02-03 04:05  2021-02-03 04:05:06" "$rows" "each row keeps its own log's mtime"
    else
        assert_eq "alpha    2020-01-02 03:04  2020-01-02 03:04
beta     2021-02-03 04:05  2021-02-03 04:05" "$rows" "each row keeps its own log's mtime"
    fi
}

# The listing finds a session's log wherever cs has kept it: .cs/private (an
# encrypted session), .cs/local, .cs/logs, or logs/ in a pre-.cs/ session; and
# .cs/private before .cs/local when both are there.
test_list_reads_the_log_from_each_of_its_places() {
    local root="$CS_SESSIONS_ROOT" out rc=0 rows
    create_test_session enc >/dev/null
    create_test_session loc >/dev/null
    create_test_session old >/dev/null
    mkdir -p "$root/enc/.cs/private" "$root/old/.cs/logs" "$root/pre/logs"
    echo "# Session" > "$root/pre/CLAUDE.md"
    printf '2020-01-01 01:01:00 - Session started\n' > "$root/enc/.cs/private/session.log"
    printf '2029-09-09 09:09:00 - Session started\n' > "$root/enc/.cs/local/session.log"
    printf '2020-02-02 02:02:00 - Session started\n' > "$root/loc/.cs/local/session.log"
    printf '2020-03-03 03:03:00 - Session started\n' > "$root/old/.cs/logs/session.log"
    printf '2020-04-04 04:04:00 - Session started\n' > "$root/pre/logs/session.log"
    mkdir -p "$TEST_TMPDIR/nokeys"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/nokeys/security"; chmod +x "$TEST_TMPDIR/nokeys/security"
    out=$(PATH="$TEST_TMPDIR/nokeys:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -list exits 0; output: $out" || return 1
    rows=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -E '^(enc|loc|old|pre) ' | cut -c1-25)
    assert_eq "enc      2020-01-01 01:01
loc      2020-02-02 02:02
old      2020-03-03 03:03
pre      2020-04-04 04:04" "$rows" "each session's created time comes from its own log's place"
}

# A log that goes after the listing has found it, here deleted by the first
# stat call, reads '-' for both times, and the sessions after it still print.
test_list_survives_a_log_that_goes_mid_listing() {
    local aa bb cc fakebin="$TEST_TMPDIR/vanish" real_stat out rc=0 rows
    real_stat=$(command -v stat)
    aa=$(create_test_session aa)
    bb=$(create_test_session bb)
    cc=$(create_test_session cc)
    printf '2020-01-02 03:04:05 - Session started\n' > "$aa/.cs/local/session.log"
    printf '2020-01-02 03:04:05 - Session started\n' > "$bb/.cs/local/session.log"
    printf '2020-01-02 03:04:05 - Session started\n' > "$cc/.cs/local/session.log"
    mkdir -p "$fakebin"
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/security"
    cat > "$fakebin/stat" <<EOF
#!/bin/sh
rm -f "$bb/.cs/local/session.log"
exec "$real_stat" "\$@"
EOF
    chmod +x "$fakebin/security" "$fakebin/stat"
    out=$(PATH="$fakebin:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -list exits 0; output: $out" || return 1
    rows=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -E '^(aa|bb|cc) ' | cut -c1-25 | sed 's/ *$//')
    assert_eq "aa       2020-01-02 03:04
bb       -
cc       2020-01-02 03:04" "$rows" "the gone log's row reads '-' and the rest still print" || return 1
    assert_output_not_contains "$out" "No such file" "nothing is said about the gone log"
}

# A session's secret count is the number of keychain entries under its own
# name: 'alpha' does not take the entries of 'alphabet', nor 'bet' those of
# 'alphabet', and a session with none shows no count.
test_list_counts_each_sessions_own_secrets() {
    local fakebin="$TEST_TMPDIR/fakebin" out rc=0 rows
    create_test_session alpha >/dev/null
    create_test_session alphabet >/dev/null
    create_test_session bet >/dev/null
    create_test_session beta >/dev/null
    mkdir -p "$fakebin"
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/cs-secrets"
    cat > "$fakebin/security" <<'EOF'
#!/bin/sh
cat <<'DUMP'
keychain: "/Users/example/Library/Keychains/login.keychain-db"
    "acct"<blob>="cs"
    "svce"<blob>="cs:alpha:API_KEY"
    "svce"<blob>="cs:alpha:DB_PASSWORD"
    "svce"<blob>="cs:alphabet:TOKEN"
    "svce"<blob>="other-app:alpha:KEY"
DUMP
EOF
    chmod +x "$fakebin/cs-secrets" "$fakebin/security"
    out=$(PATH="$fakebin:$PATH" "$CS_BIN" -list 2>&1) || rc=$?
    assert_eq "0" "$rc" "cs -list exits 0; output: $out" || return 1
    rows=$(printf '%s\n' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" \
        | sed -nE 's/^(alpha|alphabet|bet|beta)( \([^ ]* ([0-9]+)\))? .*/\1=\3/p')
    assert_eq "alpha=2
alphabet=1
bet=
beta=" "$rows" "each session counts only its own secrets"
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
run_test test_list_modified_time_belongs_to_its_own_row
run_test test_list_modified_time_survives_a_stat_that_misses_a_file
run_test test_list_reads_the_log_from_each_of_its_places
run_test test_list_survives_a_log_that_goes_mid_listing
run_test test_list_counts_each_sessions_own_secrets
run_test test_list_omits_non_session_directories
run_test test_list_includes_a_legacy_session
run_test test_list_runs_under_old_bash
run_test test_list_prints_the_picker_hint_with_the_listing
run_test test_tui_launch_exports_the_cs_binary_path

report_results
