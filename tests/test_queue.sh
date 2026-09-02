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

# Deletes the task at the position `list` showed. The two tasks are seeded as
# files rather than through two `cs -queue add` runs on purpose: task names
# carry the adding process's pid unpadded, so two same-second adds from
# different pids sort by pid STRING (999 after 1000) and the arrival order this
# asserts would flake at every digit-length boundary.
test_queue_rm_removes_by_index() {
    local q="$CLAUDE_SESSION_META_DIR/local/queue"
    mkdir -p "$q"
    printf 'keep\n' > "$q/0000000001-00001-0001-1"
    printf 'drop\n' > "$q/0000000002-00001-0002-2"
    "$CS_BIN" -queue rm 2 >/dev/null 2>&1
    assert_eq "1" "$(QCOUNT)" "one task remains" || return 1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "keep" "kept task remains" || return 1
    assert_output_not_contains "$out" "drop" "removed task is gone" || return 1
}

# An index past the end removed nothing and said nothing, but still cleared
# queue.declined — so the gate re-armed and a later drain ran the very task the
# user believed they had deleted.
test_queue_rm_rejects_an_index_past_the_end() {
    local q="$CLAUDE_SESSION_META_DIR/local/queue"
    mkdir -p "$q"
    printf 'keep\n' > "$q/0000000001-00001-0001-1"
    printf 'also keep\n' > "$q/0000000002-00001-0002-2"
    printf 'declined\n' > "$CLAUDE_SESSION_META_DIR/local/queue.declined"

    local out status
    out=$("$CS_BIN" -queue rm 7 2>&1)
    status=$?

    if [ "$status" -eq 0 ]; then
        echo "  FAIL: removing a task that is not there must exit non-zero"
        return 1
    fi
    assert_output_contains "$out" "1-2" "the error should name the valid range" || return 1
    assert_eq "2" "$(QCOUNT)" "both tasks remain" || return 1
    if [ ! -f "$CLAUDE_SESSION_META_DIR/local/queue.declined" ]; then
        echo "  FAIL: a refused removal must not re-arm the gate"
        return 1
    fi
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

# Blank legacy lines are not tasks; a second conversion call is a no-op.
test_legacy_conversion_skips_blanks_and_is_idempotent() {
    printf 'real one\n   \n\nreal two\n' > "$(QFILE)"
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_eq "2" "$(QCOUNT)" "blank lines skipped" || return 1
    assert_output_contains "$out" "2. real two" "order preserved around blanks" || return 1
    out=$("$CS_BIN" -queue list 2>&1)
    assert_eq "2" "$(QCOUNT)" "second call converts nothing twice" || return 1
}

# A queue.migrating stranded by an interrupted conversion (or fed by a stale
# writer holding the renamed inode) is folded in, never clobbered.
test_legacy_conversion_folds_in_stranded_migrating_file() {
    printf 'stranded task\n' > "$CLAUDE_SESSION_META_DIR/local/queue.migrating"
    printf 'fresh task\n' > "$(QFILE)"
    "$CS_BIN" -queue add "added task" >/dev/null 2>&1 || return 1
    assert_eq "3" "$(QCOUNT)" "stranded, fresh and added tasks all present" || return 1
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_output_contains "$out" "1. stranded task" "stranded line converted first" || return 1
    assert_output_contains "$out" "2. fresh task" "fresh line after it" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/queue.migrating" ] || { echo "  migrating leftover"; return 1; }
}

# The stranded file's last line can be UNTERMINATED — that is the tear an
# interrupted conversion actually leaves, and the converter's `|| [ -n "$line" ]`
# exists for it. Appending the fresh queue straight onto such a file splices two
# tasks into one line, and the drain executes what it reads, so a splice is
# worse than a loss. The terminated fixture above cannot reach this.
test_legacy_conversion_does_not_splice_an_unterminated_stranded_line() {
    printf 'stranded task with no newline' > "$CLAUDE_SESSION_META_DIR/local/queue.migrating"
    printf 'fresh task\n' > "$(QFILE)"
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_eq "2" "$(QCOUNT)" "stranded and fresh stay two tasks" || return 1
    assert_output_contains "$out" "1. stranded task with no newline" "stranded line intact" || return 1
    assert_output_contains "$out" "2. fresh task" "fresh line is its own task" || return 1
    assert_output_not_contains "$out" "newlinefresh" "the two lines are not spliced" || return 1
}

# The pre-directory layout used queue.tmp as an awk TEMP FILE, so a killed old
# `-queue rm` or drain pop leaves a regular file where the staging directory
# now belongs. mkdir -p fails over it and errexit aborts every converting entry
# point, session open included — and the old code then unlinked the legacy file
# anyway, destroying the tasks it had failed to write. Upgrade path only: no
# current code can create this state, so only a fixture that plants it reaches
# the branch.
test_legacy_conversion_survives_a_stale_queue_tmp_file() {
    printf 'task one\ntask two\n' > "$(QFILE)"
    printf 'stale awk temp\n' > "$CLAUDE_SESSION_META_DIR/local/queue.tmp"
    local out; out=$("$CS_BIN" -queue list 2>&1) || { echo "  queue verb aborted: $out"; return 1; }
    assert_eq "2" "$(QCOUNT)" "both legacy tasks survived the stale temp file" || return 1
    assert_output_contains "$out" "1. task one" "first task converted" || return 1
    assert_output_contains "$out" "2. task two" "second task converted" || return 1
    [ -d "$CLAUDE_SESSION_META_DIR/local/queue.tmp" ] || { echo "  staging dir not created"; return 1; }
}

# A failed task write must not cost the task. The write is `printf > staging &&
# mv`, and a failed printf is the NON-FINAL command of an && list, so errexit
# never fires: the loop finishes looking successful and unlinking the legacy
# file would destroy whatever never landed.
test_legacy_conversion_keeps_the_legacy_file_when_a_task_cannot_be_written() {
    printf 'must survive\n' > "$(QFILE)"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local/queue.tmp"
    _deny_writes "$CLAUDE_SESSION_META_DIR/local/queue.tmp" || return 0
    "$CS_BIN" -queue list >/dev/null 2>&1 || true
    _allow_writes "$CLAUDE_SESSION_META_DIR/local/queue.tmp"
    assert_eq "0" "$(QCOUNT)" "nothing landed" || return 1
    [ -f "$CLAUDE_SESSION_META_DIR/local/queue.migrating" ] || { echo "  legacy tasks destroyed"; return 1; }
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_eq "1" "$(QCOUNT)" "the retry converts it once writes work" || return 1
    assert_output_contains "$out" "must survive" "the task survived the failed run" || return 1
}

# Keeping the legacy file for retry must not resurrect a task the drain already
# RAN. A task still queued is recognisable by its deterministic name; one
# already executed exists only in the done log, so both are consulted.
test_legacy_conversion_does_not_requeue_an_executed_task() {
    printf 'ran already\nstill pending\n' > "$(QFILE)"
    "$CS_BIN" -queue list >/dev/null 2>&1
    assert_eq "2" "$(QCOUNT)" "both converted" || return 1
    # Model the drain having popped and run the first task.
    rm -f "$CLAUDE_SESSION_META_DIR/local/queue/0000000000-legacy-0001"
    printf 'ran already\n' > "$CLAUDE_SESSION_META_DIR/local/queue.done"
    # Model the retry: a stale writer recreates the legacy file.
    printf 'ran already\nstill pending\n' > "$(QFILE)"
    local out; out=$("$CS_BIN" -queue list 2>&1)
    assert_eq "1" "$(QCOUNT)" "the executed task is not re-queued" || return 1
    assert_output_not_contains "$out" "1. ran already" "executed task stays out of the queue" || return 1
    assert_output_contains "$out" "still pending" "the pending task is untouched" || return 1
}

# The drain works on a session upgraded from the file layout once any queue
# verb (or a session open) has converted it.
test_drain_works_after_legacy_conversion() {
    printf 'legacy drain task\n' > "$(QFILE)"
    "$CS_BIN" -queue list >/dev/null 2>&1 || return 1
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "legacy drain task" "drain injects the converted task" || return 1
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
run_test test_legacy_conversion_skips_blanks_and_is_idempotent
run_test test_legacy_conversion_folds_in_stranded_migrating_file
run_test test_legacy_conversion_does_not_splice_an_unterminated_stranded_line
run_test test_legacy_conversion_survives_a_stale_queue_tmp_file
run_test test_legacy_conversion_keeps_the_legacy_file_when_a_task_cannot_be_written
run_test test_legacy_conversion_does_not_requeue_an_executed_task
run_test test_session_open_converts_legacy_queue_file
run_test test_worktree_open_converts_legacy_queue_file
run_test test_queue_list_numbers_pending
run_test test_queue_rm_removes_by_index
run_test test_queue_rm_rejects_an_index_past_the_end
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

# The fail-safe: if the pop's rename fails, the drain disarms rather than
# re-injecting the task it could not claim. A read-only queue directory makes
# the mv fail without removing the task, which is the only way to reach this
# branch — a second drain winning the race is not reproducible on demand.
test_drain_disarms_when_the_pop_fails() {
    qseed "task one" "task two"
    printf 'draining\n' > "$(QDIR)/queue.state"
    _deny_writes "$(QDIR)/queue" || return 0
    local out; out=$(drain)
    _allow_writes "$(QDIR)/queue"
    assert_eq "idle" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "failed pop disarms the drain" || return 1
    assert_eq "2" "$(qlen)" "no task is lost when the pop fails" || return 1
    assert_output_not_contains "$out" "task two" "no task injected after a failed pop" || return 1
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

# A walk-away run has nobody watching, so the handed task is the only scope
# guidance the agent gets. Without it, a pre-existing bug found while testing
# gets fixed in the same change, and an ambiguous task gets built for every
# reading at once. Both injection points carry the block: the first task of a
# run is as unwatched as the rest.
test_drain_scopes_each_task_to_what_it_asks() {
    qseed "task one" "task two"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "report it as a follow-up in your summary" \
        "first-task message must scope extras to the summary" || return 1
    printf 'draining\n' > "$(QDIR)/queue.state"
    out=$(drain)
    assert_output_contains "$out" "task two" "draining injects the next task" || return 1
    assert_output_contains "$out" "report it as a follow-up in your summary" \
        "next-task message must scope extras to the summary" || return 1
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

run_test test_drain_works_after_legacy_conversion
run_test test_drain_gates_when_idle_nonempty
run_test test_drain_armed_injects_first_task_no_pop
run_test test_drain_armed_mentions_queue_list
run_test test_drain_draining_pops_and_injects_next
run_test test_drain_disarms_when_the_pop_fails
run_test test_drain_empties_and_returns_idle
run_test test_drain_declined_within_cooldown_falls_through
run_test test_drain_ignores_subagents
run_test test_drain_gate_mentions_high_context
run_test test_drain_armed_states_stop_mechanic
run_test test_drain_scopes_each_task_to_what_it_asks
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

# --- Queued text crosses a session boundary and is not trusted ---
# `cs -msg <target> -k task "<body>"` writes a task file straight into ANOTHER
# session's queue, so the bytes rendered below were authored elsewhere. Count raw
# ESC BYTES, never the text of an escape sequence: a prior check of this defect
# grepped for the word and passed while the byte was still reaching the terminal.
_esc_bytes() { printf '%s' "$1" | LC_ALL=C tr -dc "$(printf '\033')" | wc -c | tr -d '[:space:]'; }

test_queue_list_strips_control_bytes_from_a_pending_task() {
    "$CS_BIN" -queue add "$(printf 'run \033[31mred\033[0m job')" >/dev/null 2>&1 || return 1
    local out
    out=$("$CS_BIN" -queue list 2>&1) || return 1
    assert_output_contains "$out" "Pending:" "the pending branch is reached" || return 1
    assert_output_contains "$out" "job" "text after the control byte survives" || return 1
    assert_eq "0" "$(_esc_bytes "$out")" "no raw ESC reaches the terminal" || return 1
}

test_queue_list_strips_control_bytes_from_the_done_log() {
    # queue.done is appended by the drain with the popped cross-session task
    # text. Writing the file directly is what reaches the Done: branch — the
    # only guard is `[ -s "$qdir/queue.done" ]`, which a non-empty write meets.
    printf 'finished \033[31mred\033[0m task\n' > "$CLAUDE_SESSION_META_DIR/local/queue.done"
    local out
    out=$("$CS_BIN" -queue list 2>&1) || return 1
    assert_output_contains "$out" "Done:" "the done branch is reached" || return 1
    assert_output_contains "$out" "task" "text after the control byte survives" || return 1
    assert_eq "0" "$(_esc_bytes "$out")" "no raw ESC reaches the terminal" || return 1
}

test_queue_log_strips_control_bytes() {
    # jq -r DECODES the  the drain stored, so the raw byte reappears here
    # even though the journal on disk holds none.
    printf '{"ts":1750000000,"event":"task_done","task":"run \\u001b[31mred\\u001b[0m"}\n' \
        > "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl"
    local out
    out=$("$CS_BIN" -queue log 2>&1) || return 1
    assert_output_contains "$out" "task_done" "the log branch is reached" || return 1
    assert_eq "0" "$(_esc_bytes "$out")" "no raw ESC reaches the terminal" || return 1
}

run_test test_queue_list_strips_control_bytes_from_a_pending_task
run_test test_queue_list_strips_control_bytes_from_the_done_log
run_test test_queue_log_strips_control_bytes

report_results
