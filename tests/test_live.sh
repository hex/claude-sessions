#!/usr/bin/env bash
# ABOUTME: Tests for the cs -live verb (list live sessions on this machine).
# ABOUTME: Covers live/dead filtering, actor/uptime/status columns, current marker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_ACTOR 2>/dev/null || true
}
teardown() {
    # Reap sleepers by reading PIDs from the lock files the fixtures wrote (a
    # subshell-safe alternative to a shell array), then drop the temp tree.
    local lf pid
    if [ -n "${CS_SESSIONS_ROOT:-}" ]; then
        for lf in "$CS_SESSIONS_ROOT"/*/.cs/session.lock; do
            [ -f "$lf" ] || continue
            pid="$(cat "$lf" 2>/dev/null || true)"
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Create a live session: real .cs/, lock holding a RUNNING pid. NEVER call this
# via $(...) — the backgrounded sleep inherits the command-substitution's pipe
# write end, so the substitution would block ~300s. Call it directly; the path
# is deterministic ($CS_SESSIONS_ROOT/<name>).
make_live_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}
# Write the Claude Code session record for an already-created session, keyed to
# the pid in that session's lock. The schema and the UTC process-start format
# were both read off live records Claude Code had written; a caller in any other
# zone that formats the time locally will not match what cs reads back. Pass a
# third argument to override the start time and stand in for a recycled pid.
REGISTRY_FIXTURE="$SCRIPT_DIR/fixtures/claude-session-record.json"

make_registry_record() {  # name, status, [procStart]
    local sdir="$CS_SESSIONS_ROOT/$1" pid start
    pid="$(cat "$sdir/.cs/session.lock")"
    if [ $# -ge 3 ]; then
        start="$3"
    else
        start="$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    fi
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    # Templated from the fixture the TUI's parser test include_str!s, so both
    # readers are held to one document rather than to two hand-written
    # approximations that drift. sed rather than jq on purpose: jq would
    # round-trip the record through a parser and re-emit its own formatting,
    # and then this suite would stop exercising the fixture's actual bytes.
    # Substitutions are key-anchored so the pid inside the socket path cannot be
    # rewritten by accident. sed interpolates the replacement, so a name or
    # status containing & \ or | would corrupt the output; every caller passes a
    # plain identifier. A control-character case would need printf and a \u
    # escape instead of a raw byte here.
    sed -e 's|"pid":70260|"pid":'"$pid"'|' \
        -e 's|/tmp/cc-socks/70260\.sock|/tmp/cc-socks/'"$pid"'.sock|' \
        -e 's|"name":"demo"|"name":"'"$1"'"|' \
        -e 's|"status":"busy"|"status":"'"$2"'"|' \
        -e 's|"procStart":"Sat Aug  8 07:11:34 2026"|"procStart":"'"$start"'"|' \
        "$REGISTRY_FIXTURE" > "$CS_CLAUDE_DIR/sessions/$pid.json"
}

# Create a session whose lock holds a dead pid (started, then killed+reaped).
make_dead_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}

# A session with no lock but a fresh statusline heartbeat (context-pct touched
# now): live to the DISPLAY surfaces, matching the TUI, though cs never locked it.
make_heartbeat_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    : > "$sdir/.cs/local/context-pct"   # mtime = now
}
# A session whose heartbeat has gone cold (context-pct older than the 900s window).
make_cold_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$sdir/.cs/local"
    : > "$sdir/.cs/local/context-pct"
    if ! touch -A -003000 "$sdir/.cs/local/context-pct" 2>/dev/null; then
        touch -d "30 minutes ago" "$sdir/.cs/local/context-pct" 2>/dev/null || true
    fi
}

test_live_includes_heartbeat_session() {
    make_heartbeat_session breathing
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "breathing" "heartbeat-live (unlocked) session listed" || return 1
}

test_live_excludes_cold_heartbeat_session() {
    make_cold_session gone-cold
    local out; out="$("$CS_BIN" -live 2>&1)"
    case "$out" in *gone-cold*) echo "  FAIL: cold-heartbeat session listed"; return 1;; esac
    return 0
}

test_live_includes_live_excludes_dead() {
    make_live_session alive-one >/dev/null
    make_dead_session dead-one >/dev/null
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alive-one" "live session listed" || return 1
    case "$out" in *dead-one*) echo "  FAIL: dead session listed"; return 1;; esac
    return 0
}

test_live_shows_presence_status() {
    make_live_session busy-one
    printf 'wiring the mailbox\n' > "$CS_SESSIONS_ROOT/busy-one/.cs/local/presence"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "wiring the mailbox" "status column shows presence" || return 1
}

test_live_falls_back_to_readme_objective() {
    make_live_session obj-one
    printf '# obj-one\n\n## Objective\n\nShip presence\n' > "$CS_SESSIONS_ROOT/obj-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "Ship presence" "status falls back to objective" || return 1
}

test_live_filters_readme_placeholder() {
    make_live_session ph-one
    printf '# ph-one\n\n## Objective\n\n[Describe what you are trying to accomplish]\n' > "$CS_SESSIONS_ROOT/ph-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    case "$out" in *Describe*) echo "  FAIL: placeholder shown as status"; return 1;; esac
    return 0
}

test_live_marks_current_session() {
    make_live_session mine >/dev/null
    export CLAUDE_SESSION_NAME="mine"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "(this session)" "current session marked" || return 1
    unset CLAUDE_SESSION_NAME
}

test_live_actor_is_sessions_own_not_invoker() {
    make_live_session actor-one
    printf 'alice@example.com\n' > "$CS_SESSIONS_ROOT/actor-one/.cs/local/identity"
    export CS_ACTOR="bob@invoker.com"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alice" "row shows the session's own actor" || return 1
    case "$out" in *bob*) echo "  FAIL: invoker CS_ACTOR leaked onto row"; return 1;; esac
    unset CS_ACTOR
}

test_live_none_message_when_no_live() {
    make_dead_session only-dead
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "No other live cs sessions" "prints the empty message" || return 1
}

test_live_marks_current_via_symlink() {
    # Reached through a symlink; the marker matches by CLAUDE_SESSION_NAME
    # (basename), not by resolved path, so the row is still marked.
    local target="$TEST_TMPDIR/real-target" p
    mkdir -p "$target/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$target/.cs/session.lock"
    ln -s "$target" "$CS_SESSIONS_ROOT/linked-one"
    export CLAUDE_SESSION_NAME="linked-one"
    export CLAUDE_SESSION_DIR="$target"   # resolved path, differs from the symlink path
    local out; out="$("$CS_BIN" -live 2>&1)"
    kill "$p" 2>/dev/null || true
    assert_output_contains "$out" "(this session)" "symlinked current session marked by name" || return 1
}

test_live_uptime_from_lock_mtime() {
    make_live_session up-one
    local lock="$CS_SESSIONS_ROOT/up-one/.cs/session.lock"
    # Back-date the lock ~2h. BSD: touch -A -HHMMSS; GNU: touch -d "2 hours ago".
    if ! touch -A -020000 "$lock" 2>/dev/null; then
        touch -d "2 hours ago" "$lock" 2>/dev/null || true
    fi
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "2h" "uptime reflects the lock mtime (~2h)" || return 1
}

test_live_empty_root_message_and_exit0() {
    rm -rf "$CS_SESSIONS_ROOT"   # exercise the [ ! -d "$SESSIONS_ROOT" ] branch
    local out rc
    out="$("$CS_BIN" -live 2>&1)"; rc=$?
    assert_output_contains "$out" "No other live cs sessions" "empty root prints the message" || return 1
    assert_eq "0" "$rc" "empty root exits 0" || return 1
}

# The fixture is shared with the TUI's parser test, which include_str!s it, so
# an edit here reaches both readers. Each field make_registry_record rewrites
# must appear exactly once, or the substitution silently stops applying and
# every test built on it starts asserting against the fixture's own defaults --
# green, and testing nothing.
test_registry_fixture_sentinels_are_unique() {
    command -v jq >/dev/null 2>&1 || return 0
    jq -e . "$REGISTRY_FIXTURE" >/dev/null 2>&1 \
        || { echo "fixture is not valid JSON"; return 1; }
    local pat seen
    for pat in '"pid":70260' '"name":"demo"' '"status":"busy"' \
               '"procStart":"Sat Aug  8 07:11:34 2026"' '/tmp/cc-socks/70260.sock'; do
        seen="$(grep -o -F "$pat" "$REGISTRY_FIXTURE" | grep -c .)"
        assert_eq "1" "$seen" "fixture sentinel $pat must occur exactly once" || return 1
    done
}

test_live_shows_agent_status_from_registry() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session working
    make_registry_record working waiting
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "working.*waiting" "agent status read from the session registry" || return 1
}

test_live_gives_each_session_its_own_agent_status() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session one-busy
    make_registry_record one-busy busy
    make_live_session two-waiting
    make_registry_record two-waiting waiting
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "one-busy.*busy" "first session carries its own state" || return 1
    assert_output_contains "$out" "two-waiting.*waiting" "second session carries its own state" || return 1
    assert_output_not_contains "$out" "one-busy.*waiting" \
        "reading every record at once must not smear one session's state onto another" || return 1
}

test_live_survives_a_record_whose_pid_is_out_of_range() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session healthy
    make_registry_record healthy busy
    # A stale record naming a pid past the kernel's maximum: `ps -p` fails the
    # WHOLE list rather than skipping that one, so batching the lookup would
    # blank every other session's state over a single orphaned document.
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    printf '{"pid": 999999, "name": "ghost", "status": "busy", "procStart": "Mon Jan  1 00:00:00 2001"}\n' \
        > "$CS_CLAUDE_DIR/sessions/999999.json"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "healthy.*busy" \
        "one unusable record must not cost every other session its state" || return 1
}

test_live_survives_a_malformed_record_sorting_first() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session healthy
    make_registry_record healthy busy
    # One corrupt document must cost only itself. The whole glob goes to a single
    # jq, and jq abandons the run at a parse error, so a malformed file sorting
    # BEFORE a good one took every record after it down as well -- a healthy
    # session silently losing its state because an unrelated one crashed
    # mid-write. Named "1.json" so it sorts ahead of any real pid.
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    printf '{"pid": 1, "name": "broken", "status": NOT-VALID-JSON\n' \
        > "$CS_CLAUDE_DIR/sessions/1.json"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "healthy.*busy" \
        "a malformed record must not cost a healthy session its state" || return 1
}

# ---- the contract shared with parse_agent_record in tui/src/session.rs ----
#
# Two readers answer the same question in two languages and have drifted three
# times. Each case here is pinned on BOTH sides; changing one means changing the
# other. Asserted against agent_states rather than through cs -live, because the
# render collapses distinctions the contract turns on.
states_for() {  # session-name, name-value, status-value
    local sdir="$CS_SESSIONS_ROOT/$1" pid start
    pid="$(cat "$sdir/.cs/session.lock")"
    start="$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    printf '{"pid":%s,"name":"%s","status":"%s","procStart":"%s"}\n' \
        "$pid" "$2" "$3" "$start" > "$CS_CLAUDE_DIR/sessions/$pid.json"
    ( source "$SCRIPT_DIR/../lib/05-term.sh"
      source "$SCRIPT_DIR/../lib/56-presence.sh"
      agent_states )
}

test_agent_states_refuses_an_empty_name() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session s1
    assert_eq "" "$(states_for s1 "" busy)" \
        "an empty name earns no state: it can match no session" || return 1
}

test_agent_states_refuses_an_empty_status() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session s2
    assert_eq "" "$(states_for s2 demo "")" \
        "an empty status says nothing a missing one does not" || return 1
}

test_agent_states_refuses_a_pid_that_is_not_a_number() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session s3
    local sdir="$CS_SESSIONS_ROOT/s3" pid start out
    pid="$(cat "$sdir/.cs/session.lock")"
    start="$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    # A quoted pid is a malformed record, not a session. The TUI's parser reads
    # the digits only when they are unquoted and refuses this outright, so
    # accepting it here would show a state in cs -live that the TUI never shows.
    printf '{"pid":"%s","name":"demo","status":"busy","procStart":"%s"}\n' \
        "$pid" "$start" > "$CS_CLAUDE_DIR/sessions/$pid.json"
    out="$( source "$SCRIPT_DIR/../lib/05-term.sh"
            source "$SCRIPT_DIR/../lib/56-presence.sh"
            agent_states )"
    assert_eq "" "$out" "a quoted pid must earn no state" || return 1
}

test_agent_states_refuses_a_raw_control_byte() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session s4
    # A raw control byte is not legal JSON. jq refuses the whole document, so
    # the session shows no state at all rather than a cleaned one.
    local raw
    raw="bu$(printf '\001')sy"
    assert_eq "" "$(states_for s4 demo "$raw")" \
        "an illegal raw control byte must earn no state" || return 1
}

test_agent_states_strips_an_escaped_control_character() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session s5
    # Six characters -- backslash u 0 0 0 1 -- which is legal JSON. jq decodes
    # it to a byte and _scrub_controls removes that byte, so the rendered text
    # is the value without it.
    local esc="bu\\u0001sy"
    assert_eq "demo	busy" "$(states_for s5 demo "$esc")" \
        "an escaped control character is decoded and scrubbed, not rendered" || return 1
}

test_agent_states_emits_one_row_when_a_later_record_is_malformed() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session healthy
    make_registry_record healthy busy
    # The mirror of the case above, and the one that catches the WRONG repair.
    # jq emits the good record BEFORE hitting the parse error, so a fallback that
    # keeps that partial output and appends its per-file retry lists the session
    # twice.
    #
    # Asserted against agent_states directly, not through cs -live: cmd_live
    # prints one line per session DIRECTORY and resolves state with
    # agent_state_of, which returns the first matching row. A duplicated row is
    # therefore invisible at the CLI, and a test that counted output lines would
    # pass against the appending implementation while claiming to reject it.
    mkdir -p "$CS_CLAUDE_DIR/sessions"
    printf '{"pid": 2, "name": "broken", "status": NOT-VALID-JSON\n' \
        > "$CS_CLAUDE_DIR/sessions/999999999.json"
    local rows state
    rows="$( source "$SCRIPT_DIR/../lib/05-term.sh"
             source "$SCRIPT_DIR/../lib/56-presence.sh"
             agent_states | grep -c '^healthy' || true )"
    assert_eq "1" "$rows" "agent_states must emit exactly one row for a session" || return 1
    # The row COUNT alone cannot see the failure, because a command substitution
    # strips the trailing newline: the retry's first record would be glued onto
    # the partial output's last one, producing a single CORRUPTED row rather
    # than two clean ones, whose status field reads "busy<pid>...". Assert the
    # value, which is what the render surfaces.
    state="$( source "$SCRIPT_DIR/../lib/05-term.sh"
              source "$SCRIPT_DIR/../lib/56-presence.sh"
              agent_state_of "$(agent_states)" healthy )"
    assert_eq "busy" "$state" "the state must survive intact, not absorb the next record" || return 1
}

test_live_ignores_record_with_no_start_time() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session unverifiable
    # A record carrying no start time cannot be told apart from one left by a
    # session whose pid has been reused, so it earns no state. The TUI reader
    # refuses it too; a wildcard here made the same record read one way in
    # cs -live and another in the TUI.
    make_registry_record unverifiable waiting ""
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "unverifiable" "the session is still listed" || return 1
    assert_output_not_contains "$out" "unverifiable.*waiting" \
        "a record with no start time must not be trusted" || return 1
}

test_live_ignores_record_whose_start_time_differs() {
    command -v jq >/dev/null 2>&1 || return 0
    make_live_session recycled
    make_registry_record recycled waiting "Mon Jan  1 00:00:00 2001"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_not_contains "$out" "recycled.*waiting" \
        "record left by an exited session whose pid was reused is ignored" || return 1
}

run_test test_live_includes_heartbeat_session
run_test test_live_excludes_cold_heartbeat_session
run_test test_live_includes_live_excludes_dead
run_test test_live_shows_presence_status
run_test test_registry_fixture_sentinels_are_unique
run_test test_live_shows_agent_status_from_registry
run_test test_live_gives_each_session_its_own_agent_status
run_test test_live_ignores_record_whose_start_time_differs
run_test test_live_ignores_record_with_no_start_time
run_test test_live_survives_a_record_whose_pid_is_out_of_range
run_test test_live_survives_a_malformed_record_sorting_first
run_test test_agent_states_refuses_an_empty_name
run_test test_agent_states_refuses_an_empty_status
run_test test_agent_states_refuses_a_pid_that_is_not_a_number
run_test test_agent_states_refuses_a_raw_control_byte
run_test test_agent_states_strips_an_escaped_control_character
run_test test_agent_states_emits_one_row_when_a_later_record_is_malformed
run_test test_live_falls_back_to_readme_objective
run_test test_live_filters_readme_placeholder
run_test test_live_marks_current_session
run_test test_live_marks_current_via_symlink
run_test test_live_actor_is_sessions_own_not_invoker
run_test test_live_uptime_from_lock_mtime
run_test test_live_empty_root_message_and_exit0
run_test test_live_none_message_when_no_live

report_results
