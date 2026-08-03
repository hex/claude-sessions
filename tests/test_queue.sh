#!/usr/bin/env bash
# ABOUTME: Tests for the cs -queue verb and the Stop-hook drain.
# ABOUTME: Covers add/list/rm/clear/start/defer and the outside-a-session error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

QFILE() { printf '%s' "$CLAUDE_SESSION_META_DIR/local/queue"; }

# Count task files in a queue directory.
QCOUNT() {
    local f n=0
    for f in "$(QFILE)"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Queueing is atomic by MECHANISM (spec test 2): each add lands as its own
# whole file in the queue directory, staged in a sibling tmp dir and renamed
# into place — no append to a shared file the drain could read torn.
test_queue_add_writes_one_file_per_task() {
    "$CS_BIN" -queue add "first task" >/dev/null 2>&1
    "$CS_BIN" -queue add "second task" >/dev/null 2>&1
    [ -d "$(QFILE)" ] || { echo "  queue is not a directory"; return 1; }
    assert_eq "2" "$(QCOUNT)" "one file per task" || return 1
    local f found1=0 found2=0
    for f in "$(QFILE)"/*; do
        [ -f "$f" ] || continue
        case "$(cat "$f")" in
            "first task")  found1=1 ;;
            "second task") found2=1 ;;
        esac
    done
    [ "$found1" = 1 ] || { echo "  first task content missing"; return 1; }
    [ "$found2" = 1 ] || { echo "  second task content missing"; return 1; }
    for f in "$CLAUDE_SESSION_META_DIR/local/queue.tmp"/*; do
        [ -e "$f" ] && { echo "  staging leftover: $f"; return 1; }
    done
    return 0
}

test_queue_list_numbers_pending() {
    "$CS_BIN" -queue add "alpha" >/dev/null 2>&1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "1" "list is numbered" || return 1
    assert_output_contains "$out" "alpha" "list shows the task" || return 1
}

test_queue_rm_removes_by_index() {
    "$CS_BIN" -queue add "keep" >/dev/null 2>&1
    "$CS_BIN" -queue add "drop" >/dev/null 2>&1
    "$CS_BIN" -queue rm 2 >/dev/null 2>&1
    assert_eq "1" "$(QCOUNT)" "one task remains" || return 1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "keep" "kept task remains" || return 1
    assert_output_not_contains "$out" "drop" "removed task is gone" || return 1
}

test_queue_clear_empties_and_resets_state() {
    "$CS_BIN" -queue add "x" >/dev/null 2>&1
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    "$CS_BIN" -queue clear >/dev/null 2>&1
    assert_not_exists "$(QFILE)" "queue directory removed" || return 1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.state" "state reset" || return 1
}

test_queue_start_sets_armed() {
    "$CS_BIN" -queue start >/dev/null 2>&1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/queue.state" "armed" "start arms" || return 1
}

test_queue_defer_writes_declined_epoch() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "defer stamps declined" || return 1
}

test_queue_add_clears_declined() {
    "$CS_BIN" -queue defer >/dev/null 2>&1
    "$CS_BIN" -queue add "new" >/dev/null 2>&1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/queue.declined" "add re-enables gating" || return 1
}

test_queue_requires_session() {
    unset CLAUDE_SESSION_META_DIR
    local out; if out=$("$CS_BIN" -queue add "x" 2>&1); then
        echo "  FAIL: expected non-zero outside a session"; return 1
    fi
    assert_output_contains "$out" "session" "explains it needs a session" || return 1
}

test_queue_add_via_session_scoped_arm() {
    # cs <session> -queue ... resolves the target from the name arg, not the
    # ambient env, so clear the env a launched session would export.
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    local sdir="$CS_SESSIONS_ROOT/scoped-session"
    mkdir -p "$sdir/.cs"
    "$CS_BIN" scoped-session -queue add "from outside" >/dev/null 2>&1
    local f found=0
    for f in "$sdir/.cs/local/queue"/*; do
        [ -f "$f" ] || continue
        case "$(cat "$f")" in "from outside") found=1 ;; esac
    done
    [ "$found" = 1 ] || { echo "  session-scoped add did not land in the named session"; return 1; }
}

# A pre-directory queue is a single FILE at the queue path. Any queue verb
# converts it first (mv aside, then one file per line, order preserved) so an
# upgraded session neither errors on mkdir nor strands its queued tasks.
test_queue_verbs_convert_a_legacy_queue_file() {
    printf 'legacy one\nlegacy two\n' > "$(QFILE)"
    "$CS_BIN" -queue add "third" >/dev/null 2>&1 || { echo "  add failed over a legacy file"; return 1; }
    [ -d "$(QFILE)" ] || { echo "  legacy file not converted to a directory"; return 1; }
    assert_eq "3" "$(QCOUNT)" "legacy lines and the new task all queued" || return 1
    [ ! -f "$(QFILE).migrating" ] || { echo "  conversion leftover"; return 1; }
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "1. legacy one" "legacy order preserved first" || return 1
    assert_output_contains "$out" "2. legacy two" "legacy order preserved second" || return 1
    assert_output_contains "$out" "3. third" "new task after the legacy ones" || return 1
}

# Session open converts too, so the statusline, TUI and drain (which never
# write) see the directory without waiting for a queue verb.
test_session_open_converts_legacy_queue_file() {
    create_test_session opensess >/dev/null
    printf 'opened task\n' > "$CS_SESSIONS_ROOT/opensess/.cs/local/queue"
    CLAUDE_CODE_BIN=echo "$CS_BIN" opensess < /dev/null > /dev/null 2>&1 || true
    [ -d "$CS_SESSIONS_ROOT/opensess/.cs/local/queue" ] \
        || { echo "  open did not convert the legacy queue"; return 1; }
    grep -q "opened task" "$CS_SESSIONS_ROOT/opensess/.cs/local/queue"/* \
        || { echo "  legacy task lost on open"; return 1; }
}

# The worktree open path bypasses migrate_session; queue conversion must run
# there too, exactly as mail migration does.
test_worktree_open_converts_legacy_queue_file() {
    create_test_session_with_git wtqbase >/dev/null
    CLAUDE_CODE_BIN=echo "$CS_BIN" "wtqbase@feat" < /dev/null > /dev/null 2>&1 || true
    local wtlocal="$CS_SESSIONS_ROOT/wtqbase@feat/.cs/local"
    [ -d "$CS_SESSIONS_ROOT/wtqbase@feat" ] || { echo "  worktree session not created"; return 1; }
    mkdir -p "$wtlocal"
    printf 'worktree task\n' > "$wtlocal/queue"
    CLAUDE_CODE_BIN=echo "$CS_BIN" "wtqbase@feat" < /dev/null > /dev/null 2>&1 || true
    [ -d "$wtlocal/queue" ] || { echo "  worktree open did not convert the legacy queue"; return 1; }
    grep -q "worktree task" "$wtlocal/queue"/* || { echo "  legacy task lost on worktree open"; return 1; }
}

run_test test_queue_add_writes_one_file_per_task
run_test test_queue_verbs_convert_a_legacy_queue_file
run_test test_session_open_converts_legacy_queue_file
run_test test_worktree_open_converts_legacy_queue_file
run_test test_queue_list_numbers_pending
run_test test_queue_rm_removes_by_index
run_test test_queue_clear_empties_and_resets_state
run_test test_queue_start_sets_armed
run_test test_queue_defer_writes_declined_epoch
run_test test_queue_add_clears_declined
run_test test_queue_requires_session
run_test test_queue_add_via_session_scoped_arm

QDIR() { printf '%s' "$CLAUDE_SESSION_META_DIR/local"; }
drain() { echo "${1:-{}}" | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null; }

# Seed the queue directory with one file per task, in argument order.
qseed() {
    local i=0 t
    mkdir -p "$(QDIR)/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$(QDIR)/queue/$(printf '%010d' "$i")-seed"
    done
}

# Count task files in the queue directory.
qlen() {
    local f n=0
    for f in "$(QDIR)/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

test_drain_gates_when_idle_nonempty() {
    qseed "do the thing"
    local out; out=$(drain)
    assert_output_contains "$out" '"block"' "idle+nonempty blocks to gate" || return 1
    assert_output_contains "$out" "AskUserQuestion" "gate tells agent to ask" || return 1
    assert_file_not_exists "$(QDIR)/queue.state" "gate does not change state" || return 1
}

test_drain_armed_injects_first_task_no_pop() {
    qseed "task one" "task two"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task one" "armed injects first task" || return 1
    assert_eq "draining" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "armed -> draining" || return 1
    assert_eq "2" "$(qlen)" "no pop on first injection" || return 1
}

test_drain_armed_mentions_queue_list() {
    qseed "task one" "task two" "task three"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "cs -queue list" \
        "mirror instruction must name cs -queue list (the message shows only the first task)" || return 1
}

test_drain_draining_pops_and_injects_next() {
    qseed "task one" "task two"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task two" "draining injects the next task" || return 1
    assert_file_contains "$(QDIR)/queue.done" "task one" "finished task logged to done" || return 1
    assert_eq "1" "$(qlen)" "one task popped" || return 1
    for f in "$(QDIR)"/queue.popping.*; do
        [ -e "$f" ] && { echo "  pop staging leftover: $f"; return 1; }
    done
    return 0
}

test_drain_empties_and_returns_idle() {
    qseed "last task"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "complete" "announces completion" || return 1
    assert_eq "idle" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "returns to idle" || return 1
}

test_drain_declined_within_cooldown_falls_through() {
    qseed "queued"
    printf '%s\n' "$(date +%s)" > "$(QDIR)/queue.declined"
    local out; out=$(drain)
    assert_output_not_contains "$out" "AskUserQuestion" "recent decline suppresses the gate" || return 1
}

test_drain_ignores_subagents() {
    qseed "queued"
    local out; out=$(drain '{"agent_id":"sub-1"}')
    assert_output_not_contains "$out" "AskUserQuestion" "subagent stop never drains" || return 1
}

test_drain_gate_mentions_high_context() {
    qseed "queued"
    printf '82\n' > "$(QDIR)/context-pct"
    local out; out=$(drain)
    assert_output_contains "$out" "82" "gate surfaces context %" || return 1
    assert_output_contains "$out" "compact" "gate recommends compaction when high" || return 1
}

test_drain_armed_states_stop_mechanic() {
    # The armed message must make the turn-driven contract explicit: end the turn
    # and the next task arrives automatically; the agent must never pop or edit the
    # queue file itself. Without this the agent may ask "what's next?" or hand-pop.
    qseed "task one" "task two"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "end your turn" "armed message must instruct ending the turn" || return 1
    assert_output_contains "$out" "Do not read or edit the queue" "armed message must forbid manual queue edits" || return 1
}

test_drain_completion_asks_for_debrief() {
    # Popping the last task must close the final native task and prompt a debrief,
    # not merely announce that the queue is empty (which leaves a dangling in-progress).
    qseed "last task"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "final native task" "completion must close the final native task" || return 1
    assert_output_contains "$out" "summary" "completion must ask for a walk-away summary" || return 1
}

test_drain_high_context_defines_compact_action() {
    # The heavy-context gate offers a third 'Compact first' option; that option must
    # define its follow-through (run no queue command) so the agent does not guess
    # start/defer and either mis-arm or suppress the re-ask.
    qseed "queued"
    printf '82\n' > "$(QDIR)/context-pct"
    local out; out=$(drain)
    assert_output_contains "$out" "Compact first" "heavy-context gate offers a Compact first option" || return 1
    assert_output_contains "$out" "run no queue command" "Compact first must define its follow-through" || return 1
}

test_drain_narrative_reminder_scopes_to_own() {
    # With no queue the hook falls through to the narrative nag. In a shared session
    # the newest narrative may belong to a teammate, so the reminder must scope edits
    # to the actor's OWN narrative and never target a teammate's notebook.
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory"
    printf '# narrative\n' > "$CLAUDE_SESSION_META_DIR/memory/narrative.colleague.md"
    touch -t 202001010000 "$CLAUDE_SESSION_META_DIR/memory/narrative.colleague.md"
    local out; out=$(drain)
    assert_output_contains "$out" '"block"' "stale narrative blocks with a reminder" || return 1
    assert_output_contains "$out" "cs -whoami" "reminder tells the agent how to resolve its own actor" || return 1
    assert_output_contains "$out" "teammate" "reminder must warn against editing a teammate's narrative" || return 1
}

run_test test_drain_gates_when_idle_nonempty
run_test test_drain_armed_injects_first_task_no_pop
run_test test_drain_armed_mentions_queue_list
run_test test_drain_draining_pops_and_injects_next
run_test test_drain_empties_and_returns_idle
run_test test_drain_declined_within_cooldown_falls_through
run_test test_drain_ignores_subagents
run_test test_drain_gate_mentions_high_context
run_test test_drain_armed_states_stop_mechanic
run_test test_drain_completion_asks_for_debrief
run_test test_drain_high_context_defines_compact_action
run_test test_drain_narrative_reminder_scopes_to_own

test_statusline_stamps_context_pct() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline"
    echo '{"context_window":{"used_percentage":73.4}}' | bash "$sl" >/dev/null 2>&1 || true
    assert_file_exists "$(QDIR)/context-pct" "statusline stamps context-pct" || return 1
    assert_file_contains "$(QDIR)/context-pct" "73" "stamps truncated integer" || return 1
}

run_test test_statusline_stamps_context_pct

report_results
