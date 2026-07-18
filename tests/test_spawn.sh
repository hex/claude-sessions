#!/usr/bin/env bash
# ABOUTME: Tests for cs -spawn: validation, seed staging, tmux window wiring,
# ABOUTME: launch-path seed consumption, and the spawned-by drain notify.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
# Hooks resolve `cs` via PATH (the drain notify calls it); point them at the
# repo build for the whole suite.
export PATH="$SCRIPT_DIR/../bin:$PATH"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    export CLAUDE_CODE_BIN="echo"
    # Recording tmux fake: logs argv, one call per line; behavior driven by
    # state files in $TEST_TMPDIR/tmux-state (see comments inside).
    export CS_TMUX_BIN="$TEST_TMPDIR/fake-tmux"
    export FAKE_TMUX_DIR="$TEST_TMPDIR/tmux-state"
    mkdir -p "$FAKE_TMUX_DIR"
    cat > "$CS_TMUX_BIN" << 'FAKE'
#!/usr/bin/env bash
# Fake tmux: append argv to log; simulate state via files in $FAKE_TMUX_DIR.
#   has-session  -> exit 0 iff $FAKE_TMUX_DIR/session-exists exists
#   new-session  -> creates session-exists (fails if $FAKE_TMUX_DIR/race);
#                   with -P prints @0
#   set-option   -> records @cs_managed into $FAKE_TMUX_DIR/managed
#   show-option  -> prints contents of $FAKE_TMUX_DIR/managed (if any)
#   list-windows -> prints lines of $FAKE_TMUX_DIR/windows (if any)
#   new-window   -> with -P prints @7
printf '%s\n' "$*" >> "$FAKE_TMUX_DIR/log"
case "$1" in
    has-session)  [ -f "$FAKE_TMUX_DIR/session-exists" ]; exit $? ;;
    new-session)  # real tmux rejects a duplicate -s name; model that too
                  if [ -f "$FAKE_TMUX_DIR/race" ] || [ -f "$FAKE_TMUX_DIR/session-exists" ]; then exit 1; fi
                  touch "$FAKE_TMUX_DIR/session-exists"
                  case "$*" in *" -P "*) echo '@0';; esac ;;
    # tmux 3.6a rejects '='-anchored targets on the options commands (verified
    # live 2026-07-18: "no such session: =cs"); model that so the suite pins
    # the plain-target requirement for these two.
    set-option)   case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  printf '1\n' > "$FAKE_TMUX_DIR/managed" ;;
    show-option)  case "$*" in *"-t =cs"*) echo "no such session: =cs" >&2; exit 1;; esac
                  [ -f "$FAKE_TMUX_DIR/managed" ] && cat "$FAKE_TMUX_DIR/managed" ;;
    list-windows) [ -f "$FAKE_TMUX_DIR/windows" ] && cat "$FAKE_TMUX_DIR/windows" ;;
    new-window)   case "$*" in *" -P "*) echo '@7';; esac ;;
esac
exit 0
FAKE
    chmod +x "$CS_TMUX_BIN"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TMUX_BIN FAKE_TMUX_DIR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

SEED() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.seed"; }

test_spawn_rejects_bad_names_and_missing_tmux() {
    ! "$CS_BIN" -spawn "bad name" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn "../x" >/dev/null 2>&1 || return 1
    ! CS_TMUX_BIN=/nonexistent/tmux "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_rejects_live_target() {
    create_test_session worker >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs"
    printf '%s\n' "$$" > "$CS_SESSIONS_ROOT/worker/.cs/session.lock"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_writes_seed_and_opens_window() {
    local out
    out=$(CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker \
        --task "first job" --task "second job" 2>&1) || return 1
    assert_file_exists "$(SEED)" "seed written" || return 1
    assert_eq "boss" "$(sed -n 1p "$(SEED)")" "line 1 is spawner" || return 1
    assert_eq "first job" "$(sed -n 2p "$(SEED)")" "task order kept" || return 1
    assert_eq "second job" "$(sed -n 3p "$(SEED)")" "second task" || return 1
    assert_output_contains "$out" "@0" "window id echoed" || return 1
    assert_output_contains "$out" "tmux attach -t cs" "attach hint" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session -d -s cs" "created cs session" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "set-option -t cs @cs_managed 1" "ownership stamped" || return 1
}

test_spawn_tmux_targets_are_exact_match_anchored() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    # Resolver commands must anchor with =; the options commands must NOT
    # (tmux 3.6a rejects '=' targets on set-option/show-option), and they are
    # unambiguous anyway because they only run once exact 'cs' exists.
    ! grep -E -- '^(has-session|list-windows|new-window) .*-t cs( |$)' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  unanchored resolver target found"; return 1; }
    grep -F -- '-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  no anchored resolver target"; return 1; }
    ! grep -E -- '^(set-option|show-option) .*-t =cs' "$FAKE_TMUX_DIR/log" >/dev/null \
        || { echo "  anchored options-command target found"; return 1; }
}

test_spawn_empty_spawner_writes_blank_first_line() {
    env -u CLAUDE_SESSION_NAME "$CS_BIN" -spawn worker --task "solo" >/dev/null 2>&1 || return 1
    assert_eq "" "$(sed -n 1p "$(SEED)")" "blank spawner line" || return 1
    assert_eq "solo" "$(sed -n 2p "$(SEED)")" "task on line 2" || return 1
}

test_spawn_without_task_writes_no_seed() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written without --task"; return 1; }
}

test_spawn_refuses_existing_seed() {
    "$CS_BIN" -spawn worker --task "a" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --task "b" >/dev/null 2>&1 || return 1
    assert_eq "a" "$(sed -n 2p "$(SEED)")" "original seed untouched" || return 1
}

test_spawn_rejects_multiline_and_empty_task() {
    ! "$CS_BIN" -spawn worker --task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -spawn worker --task "   " >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on rejected task"; return 1; }
}

test_spawn_refuses_unmanaged_cs_session() {
    touch "$FAKE_TMUX_DIR/session-exists"     # a session named cs exists...
    rm -f "$FAKE_TMUX_DIR/managed"            # ...but carries no @cs_managed
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_refuses_duplicate_window() {
    touch "$FAKE_TMUX_DIR/session-exists"
    printf '1\n' > "$FAKE_TMUX_DIR/managed"
    printf 'worker\n' > "$FAKE_TMUX_DIR/windows"
    ! "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
}

test_spawn_window_command_is_quoted_absolute() {
    "$CS_BIN" -spawn worker >/dev/null 2>&1 || return 1
    grep -F "'/" "$FAKE_TMUX_DIR/log" >/dev/null || { echo "  window cmd not quoted-absolute"; return 1; }
    assert_file_contains "$FAKE_TMUX_DIR/log" "'worker'" "name quoted" || return 1
}

test_spawn_accepts_worktree_name() {
    "$CS_BIN" -spawn base@feature >/dev/null 2>&1 || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "base@feature" "worktree window opened" || return 1
}

test_spawn_new_session_race_falls_through_to_new_window() {
    touch "$FAKE_TMUX_DIR/race"   # new-session fails as if a concurrent spawner won
    local out
    out=$("$CS_BIN" -spawn worker 2>&1) || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-session" "new-session attempted" || return 1
    assert_file_contains "$FAKE_TMUX_DIR/log" "new-window" "fell through to new-window" || return 1
    assert_output_contains "$out" "@7" "window id from the fallthrough" || return 1
}

WQ() { printf '%s' "$CS_SESSIONS_ROOT/worker/.cs/local"; }

# Launch recipe (same as tests/test_uuid.sh): CLAUDE_CODE_BIN=echo makes cs's
# `exec $CLAUDE_CODE_BIN <args>` print claude's argv; <<< "" answers any read.
_launch_worker() {
    "$CS_BIN" worker <<< "" 2>&1
}

test_launch_consumes_seed_queues_arms_and_kicks() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nfirst job\nsecond job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    assert_file_contains "$(WQ)/queue" "first job" "task 1 queued" || return 1
    assert_file_contains "$(WQ)/queue" "second job" "task 2 queued" || return 1
    assert_eq "first job" "$(sed -n 1p "$(WQ)/queue")" "queue order kept" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "kick prompt in claude argv" || return 1
    assert_output_contains "$out" "2 task(s)" "kick counts tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
}

test_launch_empty_spawner_gets_no_reply_wiring() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf '\nonly job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    assert_file_contains "$(WQ)/queue" "only job" "task queued" || return 1
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written for empty spawner"; return 1; }
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
    assert_output_not_contains "$out" "Spawned by" "no spawner attribution" || return 1
    assert_output_not_contains "$out" "-k result" "no reply instructions" || return 1
}

test_launch_without_seed_keeps_color_behavior() {
    local out; out=$(_launch_worker) || return 1
    assert_output_not_contains "$out" "armed with" "no kick without seed" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed without seed"; return 1; }
}

test_launch_sets_aside_stale_seed() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nold job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  stale seed still active"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed.stale" "stale set aside" || return 1
    [ ! -f "$(WQ)/queue" ] || { echo "  stale seed queued work"; return 1; }
    assert_output_not_contains "$out" "armed with" "no kick from stale seed" || return 1
}

test_launch_stale_warning_names_the_stale_file() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nold job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "worker.seed.stale" "warning names the stale file" || return 1
}

test_launch_fresh_boundary_seed_is_consumed() {
    # A seed 30 minutes old is comfortably inside the 3600s TTL.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nboundary job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '-30 minutes' +%Y%m%d%H%M)" \
        "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$("$CS_BIN" worker <<< "" 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "fresh-side seed consumed" || return 1
}

test_launch_seed_bypasses_resume_ask() {
    # First launch creates the session; second would normally ask "Continue
    # previous conversation? [Y/n]". With a seed, no ask: stdin is closed so
    # a read would die, proving the prompt was skipped.
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nresume job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$("$CS_BIN" worker < /dev/null 2>&1) || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "seed consumed on resume" || return 1
    assert_output_not_contains "$out" "Continue previous conversation" "resume ask bypassed" || return 1
}

run_test test_spawn_rejects_bad_names_and_missing_tmux
run_test test_spawn_rejects_live_target
run_test test_spawn_writes_seed_and_opens_window
run_test test_spawn_without_task_writes_no_seed
run_test test_spawn_refuses_existing_seed
run_test test_spawn_rejects_multiline_and_empty_task
run_test test_spawn_refuses_unmanaged_cs_session
run_test test_spawn_refuses_duplicate_window
run_test test_spawn_window_command_is_quoted_absolute
run_test test_spawn_accepts_worktree_name
run_test test_spawn_new_session_race_falls_through_to_new_window
run_test test_spawn_tmux_targets_are_exact_match_anchored
run_test test_spawn_empty_spawner_writes_blank_first_line
run_test test_launch_consumes_seed_queues_arms_and_kicks
run_test test_launch_empty_spawner_gets_no_reply_wiring
run_test test_launch_without_seed_keeps_color_behavior
run_test test_launch_sets_aside_stale_seed
run_test test_launch_stale_warning_names_the_stale_file
run_test test_launch_fresh_boundary_seed_is_consumed
run_test test_launch_seed_bypasses_resume_ask

# Drain harness (same recipe as tests/test_queue_supervision.sh): the Stop
# hook is narrative-reminder.sh; CLAUDE_SESSION_* env selects the session.
_worker_env() {
    CLAUDE_SESSION_NAME="worker" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/worker" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/worker/.cs" \
    "$@"
}
_worker_stop_turn() {
    echo '{}' | PATH="$SCRIPT_DIR/../bin:$PATH" _worker_env bash "$HOOKS_DIR/narrative-reminder.sh"
}
_arm_worker_queue() {  # tasks...
    create_test_session worker >/dev/null 2>&1 || true
    create_test_session boss >/dev/null 2>&1 || true
    local t
    for t in "$@"; do printf '%s\n' "$t" >> "$CS_SESSIONS_ROOT/worker/.cs/local/queue"; done
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
}
BOSS_INBOX() { printf '%s' "$CS_SESSIONS_ROOT/boss/.cs/local/mail/inbox.jsonl"; }

test_drain_finished_notifies_spawner_once() {
    _arm_worker_queue "only task"
    _worker_stop_turn >/dev/null || return 1        # armed -> draining, task 1 injected
    _worker_stop_turn >/dev/null || return 1        # task done -> drain_finished
    assert_file_exists "$(BOSS_INBOX)" "spawner inbox written" || return 1
    assert_file_contains "$(BOSS_INBOX)" "queue drained: 1 task(s) done" "notify body" || return 1
    assert_eq "notify" "$(head -1 "$(BOSS_INBOX)" | jq -r .kind)" "kind notify" || return 1
    assert_eq "worker" "$(head -1 "$(BOSS_INBOX)" | jq -r .from)" "from worker" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" ] || { echo "  spawned-by not one-shot"; return 1; }
    # A later, unrelated drain must not re-notify.
    printf 'later task\n' >> "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "1" "$(wc -l < "$(BOSS_INBOX)" | tr -d '[:space:]')" "no second notify" || return 1
}

test_breaker_trip_notifies_and_keeps_spawned_by() {
    _arm_worker_queue "task a" "task b"
    _worker_stop_turn >/dev/null || return 1        # draining, task a injected
    printf '9\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/failures"
    _worker_stop_turn >/dev/null || return 1        # trips the failure breaker
    assert_file_contains "$(BOSS_INBOX)" "breaker tripped" "trip notified" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" "spawned-by kept on trip" || return 1
}

test_drain_without_spawned_by_sends_nothing() {
    _arm_worker_queue "solo task"
    rm -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    [ ! -f "$(BOSS_INBOX)" ] || { echo "  notify sent without spawned-by"; return 1; }
}

run_test test_drain_finished_notifies_spawner_once
run_test test_breaker_trip_notifies_and_keeps_spawned_by
run_test test_drain_without_spawned_by_sends_nothing

report_results
