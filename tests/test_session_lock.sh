#!/usr/bin/env bash
# ABOUTME: Tests for session lock mechanism that prevents concurrent access to the same session
# ABOUTME: Validates lock creation, duplicate prevention, stale lock recovery, and --force override

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"


# Override teardown to kill background processes and unset session env vars
teardown() {
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true

    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Helper: create a session directory structure without launching claude
create_lock_test_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs/local"
    touch "$session_dir/.cs/local/session.log"
    echo "# test" > "$session_dir/CLAUDE.md"
    # Machine-local state must never be committed, as a real session's .gitignore
    # ensures; otherwise cs_assert_local_untracked refuses to open the session.
    printf '.cs/local/\n' > "$session_dir/.gitignore"
    (cd "$session_dir" && git init -q 2>/dev/null && git add -A 2>/dev/null && git commit -q -m "init" 2>/dev/null) || true
}

# A picker on PATH, for the tests that assert the session-manager row or a
# keypress number below it. The row is gated on a resolvable `cs-tui`, and CI
# never builds one (bin/cs-tui is untracked), so a test that assumes the host
# has one is asserting the developer's machine. Selecting nothing keeps
# run_tui's exit path clean; callers that care record the call themselves.
_stub_picker_dir() {
    local dir="$TEST_TMPDIR/stubbin"
    mkdir -p "$dir"
    cat > "$dir/cs-tui" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$dir/cs-tui"
    printf '%s\n' "$dir"
}

# A PATH with no cs-tui on any entry, for the tests that decide which of
# _tui_bin's two probes is under test. Non-zero when one still resolves, so the
# caller can skip rather than assert something it did not actually arrange.
_path_without_picker() {
    local out="" d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -x "$d/cs-tui" ] && continue
        out="${out:+$out:}$d"
    done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
    PATH="$out" command -v cs-tui >/dev/null 2>&1 && return 1
    printf '%s\n' "$out"
}

# ============================================================================
# Tests
# ============================================================================

test_lock_created_on_launch() {
    cat > "$TEST_TMPDIR/check-lock" << 'SCRIPT'
#!/bin/bash
if [ -f "$CLAUDE_SESSION_META_DIR/session.lock" ]; then
    exit 0
fi
echo "LOCK_NOT_FOUND" >&2
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/check-lock"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/check-lock"

    "$CS_BIN" test-session || {
        echo "  FAIL: Session should launch successfully with lock file created"
        return 1
    }
}

test_lock_prevents_duplicate_session() {
    create_lock_test_session "test-session"

    sleep 300 &
    local live_pid=$!

    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output rc=0
    output=$(echo "n" | "$CS_BIN" test-session 2>&1) || rc=$?

    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [[ "$rc" -eq 0 ]]; then
        echo "  FAIL: Should have failed due to active lock"
        return 1
    fi

    if ! grep -q "Session is live (PID" <<< "$output"; then
        echo "  FAIL: Error should say the session is live: $output"
        return 1
    fi
}

test_stale_lock_is_reclaimed() {
    create_lock_test_session "test-session"

    local dead_pid
    dead_pid=$(bash -c 'echo $$')

    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 77
    fi

    echo "$dead_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    echo "n" | "$CS_BIN" test-session || {
        echo "  FAIL: Should have succeeded with stale lock"
        return 1
    }
}

test_force_overrides_live_lock() {
    create_lock_test_session "test-session"

    sleep 300 &
    local live_pid=$!

    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local rc=0
    echo "n" | "$CS_BIN" test-session --force || rc=$?

    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    if [[ "$rc" -ne 0 ]]; then
        echo "  FAIL: --force should override active lock (exit code: $rc)"
        return 1
    fi
}

# An open reads the lock by live_lock_pid's rule: a lock naming a process
# group ("-1", "0") holds no session, so the open reclaims it; a live pid
# with whitespace around it holds the session, and the refusal names the pid.
test_open_reads_the_lock_by_the_one_lock_rule() {
    local lock="$CS_SESSIONS_ROOT/test-session/.cs/session.lock" content out rc
    for content in -1 0; do
        rm -rf "$CS_SESSIONS_ROOT/test-session"
        create_lock_test_session "test-session"
        printf '%s' "$content" > "$lock"
        rc=0
        out=$("$CS_BIN" test-session </dev/null 2>&1) || rc=$?
        assert_eq "0" "$rc" "the open over a lock of '$content' exits 0 (output: $out)" || return 1
        assert_eq "Removing stale session lock (PID $content)" "$(grep -F 'session lock' <<< "$out")" \
            "the open reclaims the lock of '$content'" || return 1
    done
    rm -rf "$CS_SESSIONS_ROOT/test-session"
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    printf ' %s\n' "$live_pid" > "$lock"
    rc=0
    out=$("$CS_BIN" test-session </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "the open over a padded live pid exits 1" || return 1
    assert_eq "Error: Session is live (PID $live_pid)" "$(grep -F 'is live' <<< "$out")" \
        "the refusal names the pid alone" || return 1
}

# The stale-lock line prints what the lock holds as a plain name: a lock is a
# file in the session, which a clone or a link can fill with anything, and
# none of its newlines or escape bytes reach the terminal. (The launch banner
# that follows is cs's own colour, so the check is for the lock's sequence.)
test_stale_lock_line_prints_the_lock_as_a_plain_name() {
    create_lock_test_session "test-session"
    printf '123\n\033[31mred' > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"
    local out rc=0
    out=$("$CS_BIN" test-session </dev/null 2>&1) || rc=$?
    assert_eq "0" "$rc" "the open over the multi-line lock exits 0 (output: $out)" || return 1
    assert_eq "Removing stale session lock (PID 123___31mred)" "$(grep -F 'session lock' <<< "$out")" \
        "the line names the lock's text as one plain name" || return 1
    assert_eq "" "$(grep -F "$(printf '\033[31m')" <<< "$out")" "the lock's escape sequence reaches no line of the output" || return 1
}

# .cs/session.lock is a file cs creates and removes. A link there is never
# written through or followed, and a directory is never taken for a stale
# lock: the open stops before any write, names what it found and leaves it as
# it was. LOCK_REFUSAL_TAIL is the end of each refusal.
LOCK_REFUSAL_TAIL="where cs keeps the session lock; remove it and open the session again"

test_open_refuses_a_dangling_link_in_the_locks_place() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" out rc=0
    create_lock_test_session "test-session"
    ln -s nonexistent "$meta/session.lock"
    out=$("$CS_BIN" test-session </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open over a dangling link exits 1" || return 1
    assert_eq "Error: $meta/session.lock is a link, $LOCK_REFUSAL_TAIL" "$(tail -1 <<< "$out")" \
        "the refusal names the link" || return 1
    assert_eq "nonexistent" "$(readlink "$meta/session.lock")" "the dangling link is left as it was" || return 1
    assert_not_exists "$meta/nonexistent" "nothing is created where the link points" || return 1
}

# A link to a file in the session that holds a live pid, with --force, which
# writes the lock over a live holder: the file keeps its content.
test_forced_open_refuses_a_link_to_a_session_file_in_the_locks_place() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" out rc=0
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    printf '%s\n' "$live_pid" > "$meta/brief.md"
    ln -s brief.md "$meta/session.lock"
    out=$("$CS_BIN" test-session --force </dev/null 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "the forced open over a link to a session file exits 1" || return 1
    assert_eq "Error: $meta/session.lock is a link, $LOCK_REFUSAL_TAIL" "$(tail -1 <<< "$out")" \
        "the refusal names the link" || return 1
    assert_eq "$live_pid" "$(cat "$meta/brief.md")" "the file the link names is unchanged" || return 1
    assert_eq "brief.md" "$(readlink "$meta/session.lock")" "the link is left as it was" || return 1
}

test_open_refuses_a_directory_in_the_locks_place() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" out rc=0
    create_lock_test_session "test-session"
    mkdir "$meta/session.lock"
    out=$("$CS_BIN" test-session </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open over a directory exits 1" || return 1
    assert_eq "Error: $meta/session.lock is a directory, $LOCK_REFUSAL_TAIL" "$(tail -1 <<< "$out")" \
        "the refusal names the directory" || return 1
    assert_dir "$meta/session.lock" "the directory is left as it was" || return 1
}

# A fifo in the lock's place is refused before the open writes to it: a write
# would block with no reader, holding the openers' mutex. perl's alarm ends a
# blocked open, so the test fails instead of hanging; the output goes to a
# file, since a writer left blocked on the fifo would hold a $( ) open, and a
# non-blocking read of the fifo then lets any such writer finish.
test_open_refuses_a_fifo_in_the_locks_place() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" out rc=0
    create_lock_test_session "test-session"
    mkfifo "$meta/session.lock"
    perl -e 'alarm 20; exec @ARGV or die' "$CS_BIN" test-session </dev/null > "$TEST_TMPDIR/fifo-open.out" 2>&1 || rc=$?
    perl -MFcntl -e 'sysopen(my $f, $ARGV[0], O_RDONLY | O_NONBLOCK) or exit; select(undef, undef, undef, 0.5); sysread($f, my $b, 64)' "$meta/session.lock"
    out=$(cat "$TEST_TMPDIR/fifo-open.out")
    assert_eq "1" "$rc" "the open over a fifo exits 1" || return 1
    assert_eq "Error: $meta/session.lock is not a regular file, $LOCK_REFUSAL_TAIL" "$(tail -1 <<< "$out")" \
        "the refusal names the fifo" || return 1
    [ -p "$meta/session.lock" ] || { echo "  FAIL: the fifo is left as it was"; return 1; }
}

# The release at an open's exit never follows a link in the lock's place, even
# one naming a file that holds this open's pid. The link is put there after the
# open took the lock, by the ps the live-duplicate guard runs (CS_PS_BIN): it
# moves the open's pid into a session file, puts a link to that file in the
# lock's place, and reports a claude already running under the session's name,
# so the open stops and its exit trap releases the lock.
test_release_leaves_a_link_in_the_locks_place() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" out rc=0
    create_lock_test_session "test-session"
    cat > "$TEST_TMPDIR/ps" << PS
#!/bin/bash
meta='$meta' copy='$TEST_TMPDIR/held.copy'
PS
    cat >> "$TEST_TMPDIR/ps" << 'PS'
cat "$meta/session.lock" > "$meta/held"
cp "$meta/held" "$copy"
rm -f "$meta/session.lock"
ln -s held "$meta/session.lock"
echo "claude --name test-session "
PS
    chmod +x "$TEST_TMPDIR/ps"
    out=$(CS_PS_BIN="$TEST_TMPDIR/ps" "$CS_BIN" test-session </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open stops at the live-duplicate guard (output: $out)" || return 1
    assert_eq "held" "$(readlink "$meta/session.lock")" "the release leaves the link in the lock's place" || return 1
    assert_eq "$(cat "$TEST_TMPDIR/held.copy")" "$(cat "$meta/held")" "the file the link names is unchanged" || return 1
}

# The collision menu waits on a person, and a link can take the lock's place
# while it does: choosing force then refuses the link, naming it, rather than
# writing through it. The open's output comes through a fifo, so the link goes
# in once the menu's last row is printed (the first check is long past) and
# the keypress is written only after that.
test_force_from_the_menu_refuses_a_link_put_in_the_locks_place_meanwhile() {
    local meta="$CS_SESSIONS_ROOT/test-session/.cs" line rest rc=0 cs_pid
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    printf '%s\n' "$live_pid" > "$meta/session.lock"
    printf '%s\n' "$live_pid" > "$meta/brief.md"
    mkfifo "$TEST_TMPDIR/keys" "$TEST_TMPDIR/menu"
    exec 4<>"$TEST_TMPDIR/keys"
    PATH="$(_path_without_picker)" CS_ASSUME_TTY=1 "$CS_BIN" test-session < "$TEST_TMPDIR/keys" > "$TEST_TMPDIR/menu" 2>&1 &
    cs_pid=$!
    exec 5<"$TEST_TMPDIR/menu"
    while IFS= read -r -t 30 -u 5 line; do
        case "$line" in *cancel*) break ;; esac
    done
    case "$line" in
        *cancel*) ;;
        *) exec 4>&- 5<&-; kill "$live_pid" "$cs_pid" 2>/dev/null; echo "  FAIL: the collision menu never showed"; return 1 ;;
    esac
    rm -f "$meta/session.lock"
    ln -s brief.md "$meta/session.lock"
    printf '1' >&4
    exec 4>&-
    rest=$(cat <&5)
    exec 5<&-
    wait "$cs_pid" || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "force over a link put in the lock's place exits 1 (output: $rest)" || return 1
    assert_eq "Error: $meta/session.lock is a link, $LOCK_REFUSAL_TAIL" "$(tail -1 <<< "$rest")" \
        "the refusal names the link" || return 1
    assert_eq "$live_pid" "$(cat "$meta/brief.md")" "the file the link names is unchanged" || return 1
    assert_eq "brief.md" "$(readlink "$meta/session.lock")" "the link is left as it was" || return 1
}

test_lock_cleaned_on_session_end() {
    create_lock_test_session "test-session"

    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    echo "$$" > "$meta_dir/session.lock"
    assert_exists "$meta_dir/session.lock" "Lock should exist before hook runs" || return 1

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    # Pinned, not inherited. cs-resolve.sh preserves an existing
    # CS_RESOLVED_FROM rather than setting it, and session-start.sh exports
    # `walk` into a teammate's environment — so running this suite from a
    # teammate shell silently tested the OTHER branch and reported a failure
    # that looked like a flake.
    # The hook models the lead: the claude firing it is the process cs
    # exec'd into, so CLAUDE_PID is the launch pid.
    echo '{"session_id": "test-123"}' | CS_RESOLVED_FROM=env CS_LEAD_PID=$$ CLAUDE_PID=$$ "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_not_exists "$meta_dir/session.lock" "Lock should be cleaned up by session-end hook" || return 1
}

# A `claude -p` run from the lead's Bash tool (a plugin, a council query, a
# script) inherits the exported contract, so its SessionEnd resolves from the
# env like the lead's. It is not the lead: its claude is neither the launch
# pid nor the launch's child. Stripping the lock there lets `cs <name>` open a
# duplicate while the lead is live.
test_session_end_keeps_the_lock_for_a_child_that_inherited_the_contract() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    sleep 300 &
    local lead_pid=$!
    echo "$lead_pid" > "$meta_dir/session.lock"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    # CLAUDE_PID is this test runner: alive, not the lead, not its child.
    echo '{"session_id": "child-1", "reason": "other"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID="$lead_pid" CLAUDE_PID=$$ "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_eq "$lead_pid" "$(cat "$meta_dir/session.lock" 2>/dev/null)" \
        "a nested claude that inherited the contract must not strip the lead's lock" || return 1
}

# A second terminal force-opened the session (--force or the collision menu's
# force start), so the lock names that launch now. The first launch's lead
# conversation then ends: the lock is not its own, and removing it leaves the
# live session unlocked, so `cs -rm` deletes it under the second claude.
test_session_end_leaves_the_lock_a_forced_open_took() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    sleep 300 &
    local forced_pid=$!
    echo "$forced_pid" > "$meta_dir/session.lock"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    # The ending claude is the first launch's lead: CLAUDE_PID is its launch pid.
    echo '{"session_id": "lead-a", "reason": "other"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID=$$ CLAUDE_PID=$$ "$SCRIPT_DIR/../hooks/session-end.sh"
    local kept
    kept=$(cat "$meta_dir/session.lock" 2>/dev/null)
    kill "$forced_pid" 2>/dev/null

    assert_eq "$forced_pid" "$kept" \
        "a lead whose lock a forced open replaced must leave that live lock" || return 1
}

# The lead ends and the lock names a launch that has since died (it crashed
# after a forced open): the lock is stale, so the lead clears it, as a hook
# that walked in would.
test_session_end_lead_clears_a_stale_lock_it_does_not_own() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs" dead
    bash -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$meta_dir/session.lock"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    echo '{"session_id": "lead-a", "reason": "other"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_PID=$$ CLAUDE_PID=$$ "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_not_exists "$meta_dir/session.lock" \
        "a dead holder's lock is cleared when the lead ends" || return 1
}

# The resume arm runs claude as cs's child, so the lead's CLAUDE_PID is not
# the launch pid; its claim on the launch (.cs/local/lead-pid) names it. A
# /clear or a /resume ends a conversation but not that claude, so the claim
# and the lock stay as they are; another claude's end leaves both too; the
# lead's own end removes the lock its launch holds and marks the claim ended,
# which the next launch clears. The launch is one that takes the claim
# (CS_LEAD_CLAIM), as every launch cs makes is.
test_session_end_removes_the_lock_and_marks_the_lead_claim_ended() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs" lead
    bash -c 'exit 0' & lead=$!; wait "$lead"
    echo "$$" > "$meta_dir/session.lock"
    mkdir -p "$meta_dir/local"
    printf '%s %s %s\n' "$$" "$lead" "lead-a" > "$meta_dir/local/lead-pid"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    echo '{"session_id": "lead-a", "reason": "clear"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_CLAIM=1 CS_LEAD_PID=$$ CLAUDE_PID="$lead" "$SCRIPT_DIR/../hooks/session-end.sh"
    local after_clear_lock after_clear_claim
    after_clear_lock=$(cat "$meta_dir/session.lock" 2>/dev/null)
    after_clear_claim=$(cat "$meta_dir/local/lead-pid" 2>/dev/null)
    echo '{"session_id": "lead-a", "reason": "resume"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_CLAIM=1 CS_LEAD_PID=$$ CLAUDE_PID="$lead" "$SCRIPT_DIR/../hooks/session-end.sh"
    local after_resume_lock after_resume_claim
    after_resume_lock=$(cat "$meta_dir/session.lock" 2>/dev/null)
    after_resume_claim=$(cat "$meta_dir/local/lead-pid" 2>/dev/null)
    echo '{"session_id": "child-1", "reason": "other"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_CLAIM=1 CS_LEAD_PID=$$ CLAUDE_PID=999999 "$SCRIPT_DIR/../hooks/session-end.sh"
    local after_child_lock after_child_claim
    after_child_lock=$(cat "$meta_dir/session.lock" 2>/dev/null)
    after_child_claim=$(cat "$meta_dir/local/lead-pid" 2>/dev/null)
    echo '{"session_id": "lead-a", "reason": "other"}' \
        | CS_RESOLVED_FROM=env CS_LEAD_CLAIM=1 CS_LEAD_PID=$$ CLAUDE_PID="$lead" "$SCRIPT_DIR/../hooks/session-end.sh"
    local after_end_claim
    after_end_claim=$(cat "$meta_dir/local/lead-pid" 2>/dev/null)

    assert_eq "$$" "$after_clear_lock" "a /clear leaves the lock" || return 1
    assert_eq "$$ $lead lead-a" "$after_clear_claim" "a /clear leaves the claim" || return 1
    assert_eq "$$" "$after_resume_lock" "a /resume leaves the lock" || return 1
    assert_eq "$$ $lead lead-a" "$after_resume_claim" "a /resume leaves the claim" || return 1
    assert_eq "$$" "$after_child_lock" "another claude's end leaves the lock" || return 1
    assert_eq "$$ $lead lead-a" "$after_child_claim" "another claude's end leaves the claim" || return 1
    assert_not_exists "$meta_dir/session.lock" "the lead's end removes its launch's lock" || return 1
    assert_eq "$$ $lead lead-a ended" "$after_end_claim" "the lead's end marks its claim ended" || return 1
}

# /clear and /resume end a conversation but not the claude that holds the
# lock: it keeps running, so the next `cs <name>` must still meet the
# collision check.
test_session_end_keeps_the_lock_for_clear_and_resume() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs" reason
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"
    for reason in clear resume; do
        echo "$$" > "$meta_dir/session.lock"
        printf '{"session_id": "test-123", "reason": "%s"}' "$reason" \
            | CS_RESOLVED_FROM="env" "$SCRIPT_DIR/../hooks/session-end.sh"
        assert_eq "$$" "$(cat "$meta_dir/session.lock" 2>/dev/null)" "lock kept after reason $reason" || return 1
    done
}

# The other half of that branch, which nothing covered — which is why the
# inherited value could flip the test above and read as a flake. A teammate
# resolved by walking into the directory does not own the lock: stripping it
# would let `cs <name>` open a duplicate of the lead with no collision menu.
test_session_end_leaves_a_live_lock_it_does_not_own() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$meta_dir/session.lock"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    echo '{"session_id": "test-123"}' | CS_RESOLVED_FROM=walk "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_exists "$meta_dir/session.lock" \
        "a walked-in front end must not strip a live lock it did not take" || return 1
    assert_eq "$live_pid" "$(cat "$meta_dir/session.lock")" \
        "the owner's pid must survive untouched" || return 1
}

# ...but a stale one it does not own is still cleared, or a crashed session
# stays locked out forever.
test_session_end_clears_a_stale_lock_even_when_walked_in() {
    create_lock_test_session "test-session"
    local meta_dir="$CS_SESSIONS_ROOT/test-session/.cs"

    # A pid that cannot be alive: max_pid + 1 on every platform cs supports.
    echo "4194305" > "$meta_dir/session.lock"

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$meta_dir"

    echo '{"session_id": "test-123"}' | CS_RESOLVED_FROM=walk "$SCRIPT_DIR/../hooks/session-end.sh"

    assert_not_exists "$meta_dir/session.lock" \
        "a dead owner's lock must be cleared however the hook resolved" || return 1
}

# The exit trap releases the lock by the session's path, and that path is
# data: a sessions root holding a quote, a double quote, a command
# substitution and a space must run nothing and still release the lock. The
# trap fires only where cs outlives claude, so the second open resumes a
# conversation that has no transcript, which runs claude as a child.
test_exit_trap_releases_the_lock_under_a_root_with_shell_metacharacters() {
    local root="$TEST_TMPDIR/r 'q\" \$(touch sentinel) x"
    mkdir -p "$root"
    export CS_SESSIONS_ROOT="$root"
    (cd "$TEST_TMPDIR" && "$CS_BIN" lock-meta < /dev/null > /dev/null 2>&1) || return 1
    assert_file_exists "$root/lock-meta/.cs/README.md" "the first open creates the session" || return 1
    local rc=0
    (cd "$TEST_TMPDIR" && echo y | "$CS_BIN" lock-meta > /dev/null 2>&1) || rc=$?
    assert_eq "" "$(find "$TEST_TMPDIR" -name sentinel)" "the trap runs no command from the path" || return 1
    assert_not_exists "$root/lock-meta/.cs/session.lock" "the trap releases the lock" || return 1
    assert_eq "0" "$rc" "the resumed open exits cleanly through its trap" || return 1
}

# The session lock is taken through perl; an open on a machine without it
# says so, and never blames another cs for holding the lock.
test_open_without_perl_names_perl() {
    local bindir="$TEST_TMPDIR/noperl-bin" rc=0 output
    link_path_without "$bindir" 'perl*'
    export CLAUDE_CODE_BIN="true"
    output=$(PATH="$bindir" "$CS_BIN" test-session < /dev/null 2>&1) || rc=$?
    [ "$rc" != 0 ] || { echo "  open without perl succeeded"; return 1; }
    assert_output_contains "$output" "perl" "the refusal names perl" || return 1
    assert_output_not_contains "$output" "Another cs is opening" "no other cs is blamed" || return 1
}

test_lock_contains_valid_pid() {
    cat > "$TEST_TMPDIR/save-lock" << 'SCRIPT'
#!/bin/bash
cat "$CLAUDE_SESSION_META_DIR/session.lock" > "$CLAUDE_SESSION_DIR/.lock-content"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/save-lock"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/save-lock"

    "$CS_BIN" test-session

    local lock_content
    lock_content=$(cat "$CS_SESSIONS_ROOT/test-session/.lock-content" 2>/dev/null || echo "")

    if ! [[ "$lock_content" =~ ^[0-9]+$ ]]; then
        echo "  FAIL: Lock should contain a numeric PID, got: '$lock_content'"
        return 1
    fi
}


test_collision_menu_new_task_creates_worktree() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # Menu key '2' = new worktree, then task name, then dirty-base consent (the
    # first launch's migration leaves uncommitted backfill in the fixture repo).
    # No newline after '2': the menu reads a single keypress, so the digit must
    # not share a line with the task name.
    output=$(printf '2fix-auth\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "new-task path should launch cleanly, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/test-session@fix-auth" "worktree session created from the menu" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "original session's lock must be untouched" || return 1
}

test_collision_menu_cancel_is_default() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "EOF should default to cancel and exit cleanly" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "lock untouched on cancel" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session@fix-auth" "no worktree on cancel" || return 1
}

test_collision_menu_force_proceeds() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # Menu key '1' = force (single keypress, no Enter); the trailing 'n' answers
    # the downstream launch prompt.
    output=$(printf '1n\n' | CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "force path should launch, got: $output" || return 1
    assert_output_contains "$output" "Overriding active session lock" "force warning shown" || return 1
}

test_collision_menu_four_cancels() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # Key '4' is the explicit cancel — force, new feature, session manager,
    # cancel. A single keypress, no Enter required.
    output=$(printf '4' | PATH="$(_stub_picker_dir):$PATH" CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "key 4 cancels and exits cleanly" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown for key 4" || return 1
    # An unrecognised key cancels too, so the message alone would pass on any
    # numbering: pin that 4 is the number the menu printed against cancel.
    assert_output_contains "$output" "4.*cancel" "cancel is the fourth row" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "lock untouched on key-4 cancel" || return 1
}

test_collision_menu_shows_numbered_options() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "is live" "menu says the session is live" || return 1
    assert_output_contains "$output" "force start" "menu offers force start" || return 1
    assert_output_contains "$output" "new feature" "menu offers new feature" || return 1
    assert_output_contains "$output" "cancel" "menu offers cancel" || return 1
}

# cs IS the launch, and the hooks derive "this is the launch" from the ABSENCE
# of CS_RESOLVED_FROM (hooks/cs-resolve.sh preserves an inherited value rather
# than setting one). A teammate shell carries CS_RESOLVED_FROM=walk on purpose,
# so `cs -spawn` from one used to hand the new launch a marker saying it was
# somebody else's — and that session then declined to clear its own lock at
# SessionEnd. cs must not pass the marker on to anything it runs.
test_launch_does_not_inherit_the_resolver_marker() {
    create_lock_test_session "test-session"
    cat > "$TEST_TMPDIR/claude-stub" << 'STUB'
#!/bin/bash
printf '%s\n' "${CS_RESOLVED_FROM-<unset>}" > "$CS_MARKER_PROBE"
exit 0
STUB
    chmod +x "$TEST_TMPDIR/claude-stub"

    local probe="$TEST_TMPDIR/marker-seen"
    # 'n' declines the resume prompt, so the launch actually reaches the stub
    # instead of exiting at EOF.
    printf 'n' | CS_MARKER_PROBE="$probe" CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub" \
        CS_RESOLVED_FROM=walk CS_ASSUME_TTY=1 "$CS_BIN" test-session > /dev/null 2>&1 || true

    assert_exists "$probe" "the stub launch must have run" || return 1
    assert_eq "<unset>" "$(cat "$probe")" \
        "cs must not carry an inherited resolver marker into the launch" || return 1
}

# The picker is the way out of a collision that is neither "force it" nor
# "start something new here": another session entirely. Offered only when a
# picker binary is actually resolvable — a row that can only fail is worse
# than no row.
test_collision_menu_offers_session_manager() {
    create_lock_test_session "test-session"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(PATH="$(_stub_picker_dir):$PATH" CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "session manager" "menu offers the session manager" || return 1
}

# Choosing it runs the picker, never the force path and never cancel.
test_collision_menu_opens_session_manager() {
    create_lock_test_session "test-session"
    # A picker that records the call and selects nothing, so run_tui exits 0
    # instead of re-execing cs with a session name.
    local stubdir
    stubdir=$(_stub_picker_dir)
    cat > "$stubdir/cs-tui" << STUB
#!/usr/bin/env bash
touch "$TEST_TMPDIR/picker-ran"
STUB
    chmod +x "$stubdir/cs-tui"

    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # '3' = session manager (force, new feature, session manager, cancel).
    output=$(printf '3' | PATH="$stubdir:$PATH" CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_eq "0" "$status" "session-manager path should exit cleanly, got: $output" || return 1
    assert_exists "$TEST_TMPDIR/picker-ran" "the picker was launched" || return 1
    assert_output_not_contains "$output" "Cancelled" "session manager must not fall through to cancel" || return 1
    assert_output_not_contains "$output" "Overriding active session lock" \
        "session manager must not force the lock" || return 1
    assert_eq "$live_pid" "$(cat "$CS_SESSIONS_ROOT/test-session/.cs/session.lock")" \
        "lock untouched when the picker is opened" || return 1
}

# cs may be run by explicit path with its own directory off PATH, which the
# installer permits — so _tui_bin falls back to the picker sitting beside the
# running script. Only the miss path was covered; a probe that never fires
# would look identical from every other test.
test_collision_menu_finds_the_picker_beside_cs() {
    create_lock_test_session "test-session"
    local path_no_tui
    path_no_tui=$(_path_without_picker) || { echo "    SKIP (cs-tui resolves from PATH regardless)"; return 77; }

    # cs and a picker as siblings, reachable only by explicit path.
    mkdir -p "$TEST_TMPDIR/sibling"
    cp "$CS_BIN" "$TEST_TMPDIR/sibling/cs"
    chmod +x "$TEST_TMPDIR/sibling/cs"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/sibling/cs-tui"
    chmod +x "$TEST_TMPDIR/sibling/cs-tui"

    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(PATH="$path_no_tui" CS_ASSUME_TTY=1 "$TEST_TMPDIR/sibling/cs" test-session < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "session manager" \
        "the picker beside cs must be found when PATH has none" || return 1
}

# No picker installed, no row: the option must not name a command that errors.
# Both of cs's probes have to miss — the PATH, and the sibling next to the
# running script — so cs is copied away from bin/ and the picker's directory
# is dropped from PATH.
test_collision_menu_omits_session_manager_without_picker() {
    create_lock_test_session "test-session"
    mkdir -p "$TEST_TMPDIR/nopicker"
    cp "$CS_BIN" "$TEST_TMPDIR/nopicker/cs"
    chmod +x "$TEST_TMPDIR/nopicker/cs"

    local path_no_tui
    path_no_tui=$(_path_without_picker) || { echo "    SKIP (cs-tui still resolves with every holding directory dropped)"; return 77; }

    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(PATH="$path_no_tui" CS_ASSUME_TTY=1 "$TEST_TMPDIR/nopicker/cs" test-session < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "force start" "the menu still renders without a picker" || return 1
    assert_output_not_contains "$output" "session manager" \
        "no session-manager row when no picker is installed" || return 1
}

# A base with existing feature worktrees lists them as openable options above
# the fixed actions, so the user can resume one instead of only forcing/creating.
test_collision_menu_lists_existing_features() {
    create_lock_test_session "test-session"
    mkdir -p "$CS_SESSIONS_ROOT/test-session@fix-auth"
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?
    assert_output_contains "$output" "open a feature" "menu shows the feature section" || return 1
    assert_output_contains "$output" "@fix-auth" "menu lists the existing feature" || return 1
}

# The menu reads a single keypress, so it can address at most nine options and
# the feature list is capped to leave room for the four fixed rows. Nothing else
# covers the cap, and exceeding it fails silently: the tenth row renders and
# simply never responds to its own number.
test_collision_menu_caps_features_so_every_row_stays_reachable() {
    create_lock_test_session "test-session"
    local f
    for f in a b c d e g; do
        mkdir -p "$CS_SESSIONS_ROOT/test-session@$f"
    done
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(PATH="$(_stub_picker_dir):$PATH" CS_ASSUME_TTY=1 "$CS_BIN" test-session < /dev/null 2>&1) || status=$?

    local listed
    listed=$(grep -c 'resume · cs/' <<< "$output" || true)
    assert_eq "5" "$listed" "six worktrees must be capped to five listed rows" || return 1
    # The last row carries the highest number the keypress reader can accept.
    assert_output_contains "$output" "9.*cancel" "cancel is the ninth and last addressable row" || return 1
}

# Choosing a listed feature resumes it (re-exec base@feature), never the
# new-feature prompt and never cancel.
test_collision_menu_opens_existing_feature() {
    create_lock_test_session "test-session"
    "$CS_BIN" "test-session@fix-auth" < /dev/null > /dev/null 2>&1 || true
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    # '1' = the single listed feature (single keypress, no Enter).
    output=$(printf '1' | CS_ASSUME_TTY=1 "$CS_BIN" test-session 2>&1) || status=$?
    assert_output_not_contains "$output" "Feature name" "opening a feature must not prompt for a new name" || return 1
    assert_output_not_contains "$output" "Cancelled" "opening a feature must not cancel" || return 1
}

# A spawn's token proves ITS window to ITS session only. The collision menu
# re-execs cs for a feature of the session; carried in the environment, the
# token would let a seed staged for that feature (with the published token
# copied in) be consumed unasked by the redirected launch (Codex round 2,
# audit H2). The token is dropped before the lock is taken.
test_collision_menu_redirect_carries_no_spawn_token() {
    create_lock_test_session "test-session"
    "$CS_BIN" "test-session@fix-auth" < /dev/null > /dev/null 2>&1 || true
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'feedfacefeedfacefeedfacefeedface\nboss\nplanted task\n' > "$CS_SESSIONS_ROOT/.spawn/test-session@fix-auth.seed"

    local output status=0
    output=$(printf '1' | CS_ASSUME_TTY=1 CS_SPAWN_TOKEN=feedfacefeedfacefeedfacefeedface "$CS_BIN" test-session 2>&1) || status=$?
    kill "$live_pid" 2>/dev/null || true
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/test-session@fix-auth.seed" \
        "the redirected launch must leave the feature's seed staged" || return 1
    [ ! -d "$CS_SESSIONS_ROOT/test-session@fix-auth/.cs/local/queue" ] \
        || { echo "  FAIL: the redirected launch consumed a seed with the original launch's token"; return 1; }
    assert_output_not_contains "$output" "armed with" "no kick from the planted seed" || return 1
}

# The menu's force choice must carry through to the live-duplicate UUID guard:
# choosing "force start" and then being refused with "use --force" is a dead end.
test_collision_menu_force_bypasses_live_duplicate_guard() {
    create_lock_test_session "test-session"
    local uuid="11111111-2222-4333-8444-555555555555"
    printf 'claude_session_id: %s\n' "$uuid" > "$CS_SESSIONS_ROOT/test-session/.cs/local/state"

    # ps stub reports a claude process already holding this UUID.
    local stub="$TEST_TMPDIR/ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
echo "  47533 ??       0:00.42 claude --resume $uuid"
STUB
    chmod +x "$stub"

    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session/.cs/session.lock"

    local output status=0
    output=$(printf '1n\n' | CS_ASSUME_TTY=1 CS_PS_BIN="$stub" "$CS_BIN" test-session 2>&1) || status=$?
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true

    assert_output_not_contains "$output" "is live elsewhere" \
        "menu force must bypass the live-duplicate guard like --force" || return 1
    assert_eq "0" "$status" "menu-forced launch should proceed, got: $output" || return 1
}

test_collision_menu_on_worktree_session_offers_no_new_task() {
    create_lock_test_session "test-session"
    "$CS_BIN" "test-session@t1" < /dev/null > /dev/null 2>&1 || true
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/test-session@t1/.cs/session.lock"

    local output status=0
    # A worktree session offers no new-feature row, so its order is force,
    # session manager, cancel — '3' is cancel in that context.
    output=$(printf '3' | PATH="$(_stub_picker_dir):$PATH" CS_ASSUME_TTY=1 "$CS_BIN" "test-session@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "worktree collision exits cleanly" || return 1
    assert_output_not_contains "$output" "new feature" "no new-feature option for a worktree session" || return 1
    # Any key past the last row cancels too, so pin the number the menu printed
    # against cancel — otherwise this passes whether or not the row above it
    # exists.
    assert_output_contains "$output" "3.*cancel" "cancel is the third row on a worktree session" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/test-session@t1@n" "no nested worktree possible" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "Session lock tests"
echo "=================="
echo ""


_race_lock_once() {  # meta_dir, round -> prints the number of openers that took the lock
    local meta_dir="$1" gate="$TEST_TMPDIR/gate.$2" winners="$TEST_TMPDIR/winners.$2" settled="$TEST_TMPDIR/settled.$2" i pids=""
    rm -f "$meta_dir/session.lock"
    : > "$winners"
    : > "$settled"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        # Each opener is its own bash process, as each cs is: the lock holds
        # $$, and in a subshell that would be this runner's pid for all twenty.
        LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" LOCK_GATE="$gate" LOCK_WINNERS="$winners" LOCK_SETTLED="$settled" bash -c '
            . "$LOCK_LIB/05-term.sh"
            . "$LOCK_LIB/02-shared.sh"
            . "$LOCK_LIB/15-lock.sh"
            cs_interactive() { return 1; }
            warn() { :; }
            until [ -e "$LOCK_GATE" ]; do :; done
            # The refusal exits, so the acquire runs in a subshell; its $$ is
            # still this opener. A real winner goes on to run claude; this one
            # stays alive until every opener has settled (or 120 s of wall
            # time), else a late loser would rightly reclaim the lock of a dead
            # holder and win in turn. Openers take turns, so twenty take about
            # a second, longer on a loaded machine.
            if ( acquire_session_lock "$LOCK_META" "" lockrace >/dev/null 2>&1 ); then
                echo "$$" >> "$LOCK_WINNERS"
                echo "$$" >> "$LOCK_SETTLED"
                deadline=$((SECONDS + 120))
                while [ "$(wc -l < "$LOCK_SETTLED")" -lt 20 ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
            else
                echo "$$" >> "$LOCK_SETTLED"
            fi
        ' &
        pids="$pids $!"
    done
    # Every opener is started and spinning on the gate before it opens.
    sleep 1
    touch "$gate"
    wait $pids 2>/dev/null || true
    wc -l < "$winners" | tr -d ' '
}

# Two `cs <name>` started together both read "no lock", both write their pid,
# both launch: one UUID, two claudes. The lock must be taken atomically, so of
# twenty openers released at the same instant exactly one holds it. The
# openers are the real acquire function on its non-interactive refusal path,
# spinning on a gate file so their check-then-write windows overlap. One round
# does not always land two writes inside a plain check-then-write window, so
# the race runs eight rounds and any round with a second winner fails.
test_simultaneous_opens_take_the_lock_in_turn() {
    create_lock_test_session "lockrace"
    local meta_dir="$CS_SESSIONS_ROOT/lockrace/.cs" round counts=""
    for round in 1 2 3 4 5 6 7 8; do
        counts="$counts $(_race_lock_once "$meta_dir" "$round")"
    done
    assert_eq " 1 1 1 1 1 1 1 1" "$counts" "exactly one of 20 simultaneous openers holds the lock, every round" || return 1
}

# A stale lock (dead holder) met by two openers at once: both fail the create
# and read the dead pid. If the first removes it, creates its own and returns
# while the second is still between its read and its remove, the second's
# remove deletes the first's live lock and both go on to launch. Reclaim and
# create must take turns. The second opener is paused inside its rm by an rm
# on its PATH that waits on a gate file; the first runs with the real rm. The
# gate opens once the first has returned or had a second and a half to.
test_stale_lock_reclaim_does_not_remove_a_newer_holders_lock() {
    create_lock_test_session "lockreclaim"
    local meta_dir="$CS_SESSIONS_ROOT/lockreclaim/.cs" shim="$TEST_TMPDIR/rmshim"
    local paused="$TEST_TMPDIR/rm.paused" gate="$TEST_TMPDIR/rm.gate" winners="$TEST_TMPDIR/reclaim.winners"
    local dead pid_a pid_b i=0
    bash -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$meta_dir/session.lock"
    : > "$winners"
    mkdir -p "$shim"
    cat > "$shim/rm" <<SHIM
#!/bin/bash
case "\$*" in
    *"/session.lock") touch "$paused"; until [ -e "$gate" ]; do sleep 0.05; done ;;
esac
exec /bin/rm "\$@"
SHIM
    chmod +x "$shim/rm"
    _reclaim_opener() {  # PATH -> runs one opener in the background
        LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" LOCK_WINNERS="$winners" PATH="$1" bash -c '
            . "$LOCK_LIB/05-term.sh"
            . "$LOCK_LIB/02-shared.sh"
            . "$LOCK_LIB/15-lock.sh"
            cs_interactive() { return 1; }
            warn() { :; }
            acquire_session_lock "$LOCK_META" "" lockreclaim >/dev/null 2>&1 && { echo "$$" >> "$LOCK_WINNERS"; sleep 3; }
        ' &
    }
    _reclaim_opener "$shim:$PATH"; pid_b=$!
    wait_until test -e "$paused"
    assert_file_exists "$paused" "the second opener reached its remove of the stale lock" || { touch "$gate"; wait; return 1; }
    _reclaim_opener "$PATH"; pid_a=$!
    while kill -0 "$pid_a" 2>/dev/null && [ ! -s "$winners" ] && [ "$i" -lt 30 ]; do sleep 0.05; i=$((i + 1)); done
    touch "$gate"
    wait "$pid_a" "$pid_b" 2>/dev/null || true
    assert_eq "1" "$(wc -l < "$winners" | tr -d ' ')" "exactly one of the two openers of a stale lock holds it" || return 1
}

# SessionEnd clears a dead holder's lock when the hook is not the lead's. It
# reads the pid and removes the file, so it races an opener exactly as a
# second opener did: paused between its read of the dead pid and its remove,
# it would delete the live lock an opener made meanwhile, and the next open
# would find no lock at all. The hook is paused inside its rm by an rm on its
# PATH that waits on a gate file; the opener runs with the real rm.
test_session_end_stale_clear_does_not_remove_a_newer_holders_lock() {
    create_lock_test_session "lockhook"
    local meta_dir="$CS_SESSIONS_ROOT/lockhook/.cs" shim="$TEST_TMPDIR/rmshim-hook"
    local paused="$TEST_TMPDIR/hookrm.paused" gate="$TEST_TMPDIR/hookrm.gate" winners="$TEST_TMPDIR/hook.winners"
    local dead pid_hook pid_open i=0
    bash -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$meta_dir/session.lock"
    : > "$winners"
    mkdir -p "$shim"
    cat > "$shim/rm" <<SHIM
#!/bin/bash
case "\$*" in
    *"/session.lock") touch "$paused"; until [ -e "$gate" ]; do sleep 0.05; done ;;
esac
exec /bin/rm "\$@"
SHIM
    chmod +x "$shim/rm"
    echo '{"session_id": "hook-race"}' | PATH="$shim:$PATH" CLAUDE_SESSION_NAME=lockhook \
        CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/lockhook" CLAUDE_SESSION_META_DIR="$meta_dir" \
        CS_RESOLVED_FROM=walk "$SCRIPT_DIR/../hooks/session-end.sh" >/dev/null 2>&1 &
    pid_hook=$!
    wait_until test -e "$paused"
    assert_file_exists "$paused" "the hook reached its remove of the stale lock" || { touch "$gate"; wait; return 1; }
    LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" LOCK_WINNERS="$winners" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        cs_interactive() { return 1; }
        warn() { :; }
        acquire_session_lock "$LOCK_META" "" lockhook >/dev/null 2>&1 && { echo "$$" >> "$LOCK_WINNERS"; sleep 4; }
    ' &
    pid_open=$!
    while kill -0 "$pid_open" 2>/dev/null && [ ! -s "$winners" ] && [ "$i" -lt 30 ]; do sleep 0.05; i=$((i + 1)); done
    touch "$gate"
    wait "$pid_hook" 2>/dev/null || true
    # Once the hook is let go the opener takes the mutex and the lock, later on
    # a loaded machine; wait for its win before reading the lock.
    wait_until test -s "$winners"
    assert_eq "$(cat "$winners")" "$(cat "$meta_dir/session.lock" 2>/dev/null)" \
        "the opener that took the lock still holds it after the hook's stale clear" || { wait; return 1; }
    wait "$pid_open" 2>/dev/null || true
}

# A forced open decides to replace a live lock after it lets the openers' mutex
# go, since the collision menu waits on a person. The lead's SessionEnd may
# take the mutex in that gap and read its own pid from the lock. If the forced
# open then writes its pid without the mutex, the lead's remove deletes the
# forced open's lock, and the session runs on unlocked. The forced open is
# paused at its override warning, the hook inside its rm by a stand-in rm that
# waits on a gate file; the forced open is let go first.
test_forced_open_lock_survives_the_lead_ending_meanwhile() {
    create_lock_test_session "lockforce"
    local meta_dir="$CS_SESSIONS_ROOT/lockforce/.cs" shim="$TEST_TMPDIR/rmshim-force"
    local hook_paused="$TEST_TMPDIR/force-hookrm.paused" hook_gate="$TEST_TMPDIR/force-hookrm.gate"
    local open_paused="$TEST_TMPDIR/force-open.paused" open_gate="$TEST_TMPDIR/force-open.gate"
    local opener_pid="$TEST_TMPDIR/force-open.pid" lead pid_hook pid_open
    sleep 300 &
    lead=$!
    echo "$lead" > "$meta_dir/session.lock"
    mkdir -p "$shim"
    cat > "$shim/rm" <<SHIM
#!/bin/bash
case "\$*" in
    *"/session.lock") touch "$hook_paused"; until [ -e "$hook_gate" ]; do sleep 0.05; done ;;
esac
exec /bin/rm "\$@"
SHIM
    chmod +x "$shim/rm"
    LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" PAUSED="$open_paused" GATE="$open_gate" \
        OPENER_PID="$opener_pid" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        cs_interactive() { return 1; }
        warn() { touch "$PAUSED"; until [ -e "$GATE" ]; do sleep 0.05; done; }
        echo "$$" > "$OPENER_PID"
        acquire_session_lock "$LOCK_META" true lockforce >/dev/null 2>&1
    ' &
    pid_open=$!
    wait_until test -e "$open_paused"
    assert_file_exists "$open_paused" "the forced open reached its override" \
        || { touch "$open_gate" "$hook_gate"; kill "$lead"; wait; return 1; }
    echo '{"session_id": "lead-a", "reason": "other"}' | PATH="$shim:$PATH" CLAUDE_SESSION_NAME=lockforce \
        CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/lockforce" CLAUDE_SESSION_META_DIR="$meta_dir" \
        CS_RESOLVED_FROM=env CS_LEAD_PID="$lead" CLAUDE_PID="$lead" \
        "$SCRIPT_DIR/../hooks/session-end.sh" >/dev/null 2>&1 &
    pid_hook=$!
    wait_until test -e "$hook_paused"
    assert_file_exists "$hook_paused" "the lead's SessionEnd reached its remove of its own lock" \
        || { touch "$open_gate" "$hook_gate"; kill "$lead"; wait; return 1; }
    # The forced open goes on while the hook holds the mutex. Without the mutex
    # it writes its pid at once; with it, it waits, and the hook is let go
    # after a look of one to two seconds, well inside the five the open waits
    # on the mutex.
    local opener rc_open=0 deadline
    opener=$(cat "$opener_pid")
    touch "$open_gate"
    deadline=$((SECONDS + 2))
    until [ "$(cat "$meta_dir/session.lock" 2>/dev/null)" = "$opener" ] || [ "$SECONDS" -ge "$deadline" ]; do
        sleep 0.05
    done
    touch "$hook_gate"
    wait "$pid_hook" 2>/dev/null || true
    wait "$pid_open" 2>/dev/null || rc_open=$?
    kill "$lead" 2>/dev/null
    assert_eq "0" "$rc_open" "the forced open took the lock" || return 1
    assert_eq "$opener" "$(cat "$meta_dir/session.lock" 2>/dev/null)" \
        "the forced open still holds the lock after the lead's SessionEnd" || return 1
}

# An open that is cancelled, at the resume prompt for one, clears its own lock
# from cs's exit trap: it reads the pid in the lock and removes the file when
# the pid is its own. A forced open in another terminal may replace the lock in
# between. If the cleanup reads and removes without the openers' mutex, its
# remove deletes the forced open's lock, and that session runs on unlocked:
# cs -rm, -archive and -spawn no longer see it as live. The cleanup is paused
# inside its rm by a stand-in rm that waits on a gate file, and the forced
# open is started meanwhile.
test_cancelled_open_cleanup_leaves_the_lock_a_forced_open_took_meanwhile() {
    create_lock_test_session "lockcancel"
    local meta_dir="$CS_SESSIONS_ROOT/lockcancel/.cs" shim="$TEST_TMPDIR/rmshim-cancel"
    local rm_paused="$TEST_TMPDIR/cancel-rm.paused" rm_gate="$TEST_TMPDIR/cancel-rm.gate"
    local opener_pid="$TEST_TMPDIR/cancel-open.pid" pid_cancel pid_open
    mkdir -p "$shim"
    cat > "$shim/rm" <<SHIM
#!/bin/bash
case "\$*" in
    *"/session.lock") touch "$rm_paused"; until [ -e "$rm_gate" ]; do sleep 0.05; done ;;
esac
exec /bin/rm "\$@"
SHIM
    chmod +x "$shim/rm"
    PATH="$shim:$PATH" LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        echo "$$" > "$LOCK_META/session.lock"
        trap "release_session_lock \"\$LOCK_META\"" EXIT
        exit 0
    ' >/dev/null 2>&1 &
    pid_cancel=$!
    wait_until test -e "$rm_paused"
    assert_file_exists "$rm_paused" "the cancelled open's cleanup reached its remove of its own lock" \
        || { touch "$rm_gate"; wait; return 1; }
    LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" OPENER_PID="$opener_pid" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        cs_interactive() { return 1; }
        warn() { :; }
        echo "$$" > "$OPENER_PID"
        acquire_session_lock "$LOCK_META" true lockcancel >/dev/null 2>&1
    ' &
    pid_open=$!
    # The forced open goes on while the cleanup sits in its rm. Without the
    # mutex around the cleanup it writes its pid at once; with it, it waits,
    # and the cleanup is let go after a look of one to two seconds, well
    # inside the five the open waits on the mutex.
    local opener="" rc_open=0 deadline
    deadline=$((SECONDS + 2))
    until { [ -s "$opener_pid" ] && [ "$(cat "$meta_dir/session.lock" 2>/dev/null)" = "$(cat "$opener_pid")" ]; } \
        || [ "$SECONDS" -ge "$deadline" ]; do
        sleep 0.05
    done
    touch "$rm_gate"
    wait "$pid_cancel" 2>/dev/null || true
    wait "$pid_open" 2>/dev/null || rc_open=$?
    opener=$(cat "$opener_pid" 2>/dev/null)
    assert_eq "0" "$rc_open" "the forced open took the lock" || return 1
    assert_eq "$opener" "$(cat "$meta_dir/session.lock" 2>/dev/null)" \
        "the forced open still holds the lock after the cancelled open's cleanup" || return 1
}

# Start a process that holds <lock file> through _cs_lock until killed, with
# no child: it blocks in bash's own read on a fifo. Its pid is MUTEX_HOLDER.
_hold_session_mutex() {  # lock file
    local ready="$TEST_TMPDIR/mutex.ready"
    mkfifo "$TEST_TMPDIR/mutex.fifo"
    bash -c 'source "$1"; _cs_lock "$2" || exit 1; : > "$3"; read -r _ <> "$4"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$1" "$ready" "$TEST_TMPDIR/mutex.fifo" &
    MUTEX_HOLDER=$!
    wait_until test -e "$ready"
    [ -e "$ready" ] || { echo "  FAIL: the holder never took $1"; return 1; }
}

# An opener that cannot take the .cs/session.mutex.lock mutex (another cs
# holds it) must not touch session.lock. Going ahead without it after the
# wait reopens the stale-reclaim race the mutex closes: the holder may be
# paused between reading a dead pid and removing the file. The opener
# refuses, after the five-second wait. The wait is timed around the
# acquire_session_lock call alone, by the shell that makes it and with no
# process of its own: starting that shell and sourcing the libraries take
# as long as the machine's load makes them, and that is not the wait.
test_open_refuses_when_the_lock_mutex_stays_held() {
    create_lock_test_session "lockheld"
    local meta_dir="$CS_SESSIONS_ROOT/lockheld/.cs" dead rc=0 out took
    bash -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$meta_dir/session.lock"
    _hold_session_mutex "$meta_dir/session.mutex.lock" || return 1
    out=$(LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" TOOK="$TEST_TMPDIR/lockheld.took" bash -c '
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        cs_interactive() { return 1; }
        warn() { :; }
        s=$SECONDS
        record_took() { echo $((SECONDS - s)) > "$TOOK"; }
        trap record_took EXIT
        acquire_session_lock "$LOCK_META" "" lockheld
    ' 2>&1) || rc=$?
    took=$(cat "$TEST_TMPDIR/lockheld.took")
    kill "$MUTEX_HOLDER" 2>/dev/null; wait "$MUTEX_HOLDER" 2>/dev/null
    assert_eq "1" "$rc" "the open refuses while another cs holds the lock mutex" || return 1
    assert_output_contains "$out" "Another cs is opening this session ($meta_dir/session.mutex.lock is held)" "the refusal names the mutex" || return 1
    assert_eq "$dead" "$(cat "$meta_dir/session.lock")" "the lock file is left as it was" || return 1
    [ "$took" -ge 4 ] && [ "$took" -le 6 ] || { echo "  FAIL: the open refused after ${took}s, not about 5s"; return 1; }
}

# The exit trap's cleanup takes the same mutex. While another cs holds it past
# the five-second wait, the cleanup leaves session.lock as it was, prints
# nothing, and the trap goes on: the holder may be a forced open about to
# write its pid, and the next open reclaims a lock whose pid is dead.
test_cancelled_open_cleanup_leaves_the_lock_when_the_mutex_stays_held() {
    create_lock_test_session "lockbusy"
    local meta_dir="$CS_SESSIONS_ROOT/lockbusy/.cs" rc=0 out
    local owner_pid="$TEST_TMPDIR/busy-owner.pid" after_trap="$TEST_TMPDIR/busy-after-trap"
    _hold_session_mutex "$meta_dir/session.mutex.lock" || return 1
    out=$(LOCK_LIB="$SCRIPT_DIR/../lib" LOCK_META="$meta_dir" OWNER_PID="$owner_pid" AFTER="$after_trap" bash -c '
        set -euo pipefail
        . "$LOCK_LIB/05-term.sh"
        . "$LOCK_LIB/02-shared.sh"
        . "$LOCK_LIB/15-lock.sh"
        echo "$$" > "$LOCK_META/session.lock"
        echo "$$" > "$OWNER_PID"
        trap "release_session_lock \"\$LOCK_META\"; : > \"\$AFTER\"" EXIT
        exit 0
    ' 2>&1) || rc=$?
    kill "$MUTEX_HOLDER" 2>/dev/null; wait "$MUTEX_HOLDER" 2>/dev/null
    assert_eq "0" "$rc" "the exit status is the cancelled open's own" || return 1
    assert_eq "" "$out" "the cleanup prints nothing when it cannot take the mutex" || return 1
    assert_file_exists "$after_trap" "the exit trap ran on past the cleanup" || return 1
    assert_eq "$(cat "$owner_pid")" "$(cat "$meta_dir/session.lock" 2>/dev/null)" \
        "the lock file is left as it was" || return 1
}

# Earlier cs versions kept the mutex as a directory, .cs/session.lock.d,
# holding a pid. One left on disk, even naming a live process, is not the
# mutex: an open goes ahead at once and leaves it as it was. The mutex file
# an open leaves behind is ignored by the session's .gitignore, so it is
# never committed. "At once" is read from what the open runs, not the clock:
# taking a directory lock means a mkdir of it, and waiting on its holder
# means polling with sleep, so stand-ins on PATH log every mkdir naming the
# directory and every sleep, and both logs stay empty.
test_open_ignores_a_mutex_directory_and_leaves_its_mutex_file_ignored() {
    local session_dir="$CS_SESSIONS_ROOT/lockdir" meta_dir rc=0
    local shim="$TEST_TMPDIR/dirshim" calls="$TEST_TMPDIR/dirshim.log"
    meta_dir="$session_dir/.cs"
    "$CS_BIN" lockdir <<< "" >/dev/null 2>&1 || { echo "  FAIL: the first launch failed"; return 1; }
    rm -f "$meta_dir/session.lock"
    mkdir "$meta_dir/session.lock.d"
    echo "$$" > "$meta_dir/session.lock.d/pid"
    mkdir -p "$shim"
    : > "$calls"
    cat > "$shim/mkdir" <<SHIM
#!/bin/bash
case "\$*" in
    *session.lock.d*) echo "mkdir \$*" >> "$calls" ;;
esac
exec "$(command -v mkdir)" "\$@"
SHIM
    cat > "$shim/sleep" <<SHIM
#!/bin/bash
echo "sleep \$*" >> "$calls"
exec "$(command -v sleep)" "\$@"
SHIM
    chmod +x "$shim/mkdir" "$shim/sleep"
    PATH="$shim:$PATH" "$CS_BIN" lockdir <<< "" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the open succeeds beside a mutex directory" || return 1
    assert_eq "" "$(cat "$calls")" "the open neither took nor waited on the directory" || return 1
    assert_eq "$$" "$(cat "$meta_dir/session.lock.d/pid")" "the directory is left as it was" || return 1
    assert_file_exists "$meta_dir/session.mutex.lock" "the open took the mutex file" || return 1
    git -C "$session_dir" check-ignore -q .cs/session.mutex.lock \
        || { echo "  FAIL: .cs/session.mutex.lock is not ignored by the session's .gitignore"; return 1; }
}

run_test test_lock_created_on_launch
run_test test_simultaneous_opens_take_the_lock_in_turn
run_test test_stale_lock_reclaim_does_not_remove_a_newer_holders_lock
run_test test_session_end_stale_clear_does_not_remove_a_newer_holders_lock
run_test test_forced_open_lock_survives_the_lead_ending_meanwhile
run_test test_cancelled_open_cleanup_leaves_the_lock_a_forced_open_took_meanwhile
run_test test_open_refuses_when_the_lock_mutex_stays_held
run_test test_cancelled_open_cleanup_leaves_the_lock_when_the_mutex_stays_held
run_test test_open_ignores_a_mutex_directory_and_leaves_its_mutex_file_ignored
run_test test_lock_prevents_duplicate_session
run_test test_stale_lock_is_reclaimed
run_test test_force_overrides_live_lock
run_test test_open_reads_the_lock_by_the_one_lock_rule
run_test test_stale_lock_line_prints_the_lock_as_a_plain_name
run_test test_open_refuses_a_dangling_link_in_the_locks_place
run_test test_forced_open_refuses_a_link_to_a_session_file_in_the_locks_place
run_test test_open_refuses_a_directory_in_the_locks_place
run_test test_open_refuses_a_fifo_in_the_locks_place
run_test test_release_leaves_a_link_in_the_locks_place
run_test test_force_from_the_menu_refuses_a_link_put_in_the_locks_place_meanwhile
run_test test_lock_cleaned_on_session_end
run_test test_session_end_keeps_the_lock_for_a_child_that_inherited_the_contract
run_test test_session_end_removes_the_lock_and_marks_the_lead_claim_ended
run_test test_session_end_leaves_the_lock_a_forced_open_took
run_test test_session_end_lead_clears_a_stale_lock_it_does_not_own
run_test test_session_end_keeps_the_lock_for_clear_and_resume
run_test test_session_end_leaves_a_live_lock_it_does_not_own
run_test test_session_end_clears_a_stale_lock_even_when_walked_in
run_test test_open_without_perl_names_perl
run_test test_lock_contains_valid_pid
run_test test_exit_trap_releases_the_lock_under_a_root_with_shell_metacharacters
run_test test_collision_menu_new_task_creates_worktree
run_test test_collision_menu_cancel_is_default
run_test test_collision_menu_four_cancels
run_test test_collision_menu_shows_numbered_options
run_test test_launch_does_not_inherit_the_resolver_marker
run_test test_collision_menu_offers_session_manager
run_test test_collision_menu_opens_session_manager
run_test test_collision_menu_omits_session_manager_without_picker
run_test test_collision_menu_finds_the_picker_beside_cs
run_test test_collision_menu_lists_existing_features
run_test test_collision_menu_caps_features_so_every_row_stays_reachable
run_test test_collision_menu_opens_existing_feature
run_test test_collision_menu_redirect_carries_no_spawn_token
run_test test_collision_menu_force_proceeds
run_test test_collision_menu_force_bypasses_live_duplicate_guard
run_test test_collision_menu_on_worktree_session_offers_no_new_task

report_results
