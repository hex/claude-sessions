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
    # The attach hint keys on $TMUX; unset it so the baseline is deterministic
    # regardless of whether the suite itself runs inside tmux.
    unset TMUX 2>/dev/null || true
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
BRIEF() { printf '%s' "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"; }

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

# A brief is the multi-line counterpart of --task: a file the spawned session
# reads before it begins. It is staged beside the seed, verbatim, and a brief
# alone is reason enough for a seed, since the seed carries the spawner.
test_spawn_stages_brief_beside_the_seed() {
    printf '# Goal\n\nAdd the refresh-token path.\n\n## Done when\n- suite green\n' > "$TEST_TMPDIR/brief.md"
    CLAUDE_SESSION_NAME="boss" "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 || return 1
    assert_file_exists "$(BRIEF)" "brief staged" || return 1
    cmp -s "$TEST_TMPDIR/brief.md" "$(BRIEF)" || { echo "  staged brief differs from the source"; return 1; }
    assert_file_exists "$(SEED)" "a brief alone writes a seed" || return 1
    assert_eq "boss" "$(sed -n 1p "$(SEED)")" "seed carries the spawner" || return 1
    assert_eq "1" "$(wc -l < "$(SEED)" | tr -d ' ')" "seed carries no tasks" || return 1
}

test_spawn_brief_and_tasks_stage_together() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" --task "first job" >/dev/null 2>&1 || return 1
    assert_file_exists "$(BRIEF)" "brief staged" || return 1
    assert_eq "first job" "$(sed -n 2p "$(SEED)")" "task staged with the brief" || return 1
}

test_spawn_rejects_unreadable_or_empty_brief_before_staging() {
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/absent.md" >/dev/null 2>&1 || return 1
    : > "$TEST_TMPDIR/empty.md"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/empty.md" >/dev/null 2>&1 || return 1
    printf 'secret brief\n' > "$TEST_TMPDIR/locked.md"
    chmod 000 "$TEST_TMPDIR/locked.md"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/locked.md" >/dev/null 2>&1 && rc=1
    chmod 600 "$TEST_TMPDIR/locked.md"
    [ "$rc" = 0 ] || { echo "  an unreadable brief was accepted"; return 1; }
    ! "$CS_BIN" -spawn worker --brief >/dev/null 2>&1 || return 1
    [ ! -f "$(SEED)" ] || { echo "  seed written on a rejected brief"; return 1; }
    [ ! -f "$(BRIEF)" ] || { echo "  brief staged on a rejected brief"; return 1; }
    [ ! -f "$FAKE_TMUX_DIR/log" ] || { echo "  a window was opened on a rejected brief"; return 1; }
}

# The seed is the launch's signal that staging is complete. A brief that
# could not be copied must stop the spawn before the seed exists, or the
# window opens and the session launches without the brief it was promised.
test_spawn_failed_brief_copy_publishes_no_seed() {
    printf 'brief body\n' > "$TEST_TMPDIR/brief.md"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    chmod 500 "$CS_SESSIONS_ROOT/.spawn"
    local rc=0
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/brief.md" >/dev/null 2>&1 && rc=1
    chmod 700 "$CS_SESSIONS_ROOT/.spawn"
    [ "$rc" = 0 ] || { echo "  a failed brief copy still reported success"; return 1; }
    [ ! -f "$(SEED)" ] || { echo "  seed published after the brief copy failed"; return 1; }
    # The precheck's has-session is logged too; only the window commands count.
    ! grep -E -q '^(new-session|new-window) ' "$FAKE_TMUX_DIR/log" 2>/dev/null \
        || { echo "  a window was opened after the brief copy failed"; return 1; }
}

# The seed refusal already covers a pending brief: a brief never exists
# without its seed. This pins that a second spawn cannot swap the brief out
# from under the pending one.
test_spawn_refuses_to_replace_a_pending_brief() {
    printf 'first\n' > "$TEST_TMPDIR/one.md"
    printf 'second\n' > "$TEST_TMPDIR/two.md"
    "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/one.md" >/dev/null 2>&1 || return 1
    rm -f "$FAKE_TMUX_DIR/session-exists"
    ! "$CS_BIN" -spawn worker --brief "$TEST_TMPDIR/two.md" >/dev/null 2>&1 || return 1
    assert_eq "first" "$(cat "$(BRIEF)")" "pending brief untouched" || return 1
}

test_spawn_attach_hint_uses_switch_client_inside_tmux() {
    # tmux attach refuses to nest; from inside tmux the user needs switch-client.
    local out
    out=$(TMUX="/tmp/tmux-1000/default,1234,0" "$CS_BIN" -spawn worker 2>&1) || return 1
    assert_output_contains "$out" "tmux switch-client -t cs" "switch-client hint inside tmux" || return 1
    assert_output_not_contains "$out" "tmux attach -t cs" "no attach hint inside tmux" || return 1
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

# Count task files in the worker's queue directory.
WQ_COUNT() {
    local f n=0
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Content of the lexically first queued task (empty when none).
WQ_FIRST() {
    local f
    for f in "$(WQ)/queue"/*; do
        [ -f "$f" ] || continue
        cat "$f"
        return 0
    done
}

# Launch recipe (same as tests/test_uuid.sh): CLAUDE_CODE_BIN=echo makes cs's
# `exec $CLAUDE_CODE_BIN <args>` print claude's argv; <<< "" answers any read.
_launch_worker() {
    "$CS_BIN" worker <<< "" 2>&1
}

test_launch_consumes_seed_queues_arms_and_kicks() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nfirst job\nsecond job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    grep -q "first job" "$(WQ)/queue"/* || { echo "  task 1 not queued"; return 1; }
    grep -q "second job" "$(WQ)/queue"/* || { echo "  task 2 not queued"; return 1; }
    assert_eq "first job" "$(WQ_FIRST)" "queue order kept" || return 1
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
    grep -q "only job" "$(WQ)/queue"/* || { echo "  task not queued"; return 1; }
    [ ! -f "$(WQ)/spawned-by" ] || { echo "  spawned-by written for empty spawner"; return 1; }
    assert_output_contains "$out" "armed with 1 task(s)" "kick present" || return 1
    assert_output_not_contains "$out" "Spawned by" "no spawner attribution" || return 1
    assert_output_not_contains "$out" "-k result" "no reply instructions" || return 1
}

# A staged brief becomes the session's own file, .cs/brief.md, and the kick
# sends the session to it before anything else. With no tasks there is no
# queue to drain, so the report-back is by hand and the kick says how.
test_launch_moves_brief_into_the_session_and_kicks_to_it() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    printf '# Goal\nrefresh tokens\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "brief moved into the session" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/worker/.cs/brief.md" "refresh tokens" "brief content kept" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" ] || { echo "  staged brief left behind"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.seed" ] || { echo "  seed not deleted"; return 1; }
    assert_output_contains "$out" "Spawned by boss" "spawner named" || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_not_contains "$out" "armed with" "no queue promised without tasks" || return 1
    assert_output_contains "$out" "cs -msg boss -k result" "reply instructions present" || return 1
    assert_file_contains "$(WQ)/spawned-by" "boss" "spawned-by recorded for a brief-only spawn" || return 1
    [ ! -f "$(WQ)/queue.state" ] || { echo "  queue armed with no tasks"; return 1; }
}

test_launch_brief_with_tasks_kicks_to_both() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nfirst job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local out; out=$(_launch_worker) || return 1
    assert_output_contains "$out" "Your brief is .cs/brief.md" "kick names the brief" || return 1
    assert_output_contains "$out" "armed with 1 task(s)" "kick counts tasks" || return 1
    assert_file_contains "$(WQ)/queue.state" "armed" "queue armed" || return 1
}

# A brief the launch cannot move into the session must stop the launch with
# the seed and brief still staged, so the next open retries; consuming the
# seed would start the session without the brief, and leave the brief to
# attach to some later, unrelated spawn of the same name.
test_launch_failed_brief_delivery_keeps_the_seed_and_brief() {
    # First open creates the session; then the brief's destination is made
    # undeliverable (a sealed directory in its place) while the staging
    # directory stays writable, so only the delivery can fail.
    _launch_worker >/dev/null || return 1
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    chmod 500 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\nfirst job\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    printf 'brief body\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    local rc=0 out
    out=$(_launch_worker) || rc=$?
    chmod 700 "$CS_SESSIONS_ROOT/worker/.cs/brief.md"
    [ "$rc" != 0 ] || { echo "  launch succeeded without delivering the brief"; return 1; }
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.seed" "seed kept for a retry" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" "brief kept for a retry" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md/worker.brief.md" ] || { echo "  a brief appeared in the session anyway"; return 1; }
    assert_eq "0" "$(WQ_COUNT)" "no task queued without the brief" || return 1
    assert_output_not_contains "$out" "Spawned by" "no kick without the brief" || return 1
    assert_output_contains "$out" "brief" "the failure names the brief" || return 1
}

test_launch_stale_seed_sets_its_brief_aside_too() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    printf 'old brief\n' > "$CS_SESSIONS_ROOT/.spawn/worker.brief.md"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/worker.seed"
    local out; out=$(_launch_worker) || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/.spawn/worker.brief.md.stale" "stale brief set aside" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/worker.brief.md" ] || { echo "  stale brief still staged"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/brief.md" ] || { echo "  stale brief applied to the session"; return 1; }
    assert_output_not_contains "$out" "Your brief is" "no kick from a stale brief" || return 1
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
    assert_eq "0" "$(WQ_COUNT)" "stale seed queued no work" || return 1
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
run_test test_spawn_stages_brief_beside_the_seed
run_test test_spawn_brief_and_tasks_stage_together
run_test test_spawn_rejects_unreadable_or_empty_brief_before_staging
run_test test_spawn_failed_brief_copy_publishes_no_seed
run_test test_spawn_refuses_to_replace_a_pending_brief
run_test test_spawn_attach_hint_uses_switch_client_inside_tmux
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
run_test test_launch_moves_brief_into_the_session_and_kicks_to_it
run_test test_launch_brief_with_tasks_kicks_to_both
run_test test_launch_failed_brief_delivery_keeps_the_seed_and_brief
run_test test_launch_stale_seed_sets_its_brief_aside_too
run_test test_launch_sets_aside_stale_seed
run_test test_launch_stale_warning_names_the_stale_file
run_test test_launch_fresh_boundary_seed_is_consumed
run_test test_launch_seed_bypasses_resume_ask

# Drain harness (same recipe as tests/test_queue_supervision.sh): the Stop
# hook is narrative-reminder.sh; CLAUDE_SESSION_* env selects the session.
_worker_env() {
    CS_LEAD_PID=$$ CLAUDE_PID=$$ \
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
    local t i=0
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    for t in "$@"; do
        i=$((i + 1))
        printf '%s\n' "$t" > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/$(printf '%010d' "$i")-seed"
    done
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    printf 'boss\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
}
# First unread message in boss's maildir, as a file path (empty when none).
BOSS_MSG() {
    local f
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || return 1
        printf '%s' "$f"
        return 0
    done
}

# Count of unread messages in boss's maildir.
BOSS_MSG_COUNT() {
    local f n=0
    for f in "$CS_SESSIONS_ROOT/boss/.cs/local/mail/new"/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

test_drain_finished_notifies_spawner_once() {
    _arm_worker_queue "only task"
    _worker_stop_turn >/dev/null || return 1        # armed -> draining, task 1 injected
    _worker_stop_turn >/dev/null || return 1        # task done -> drain_finished
    local msg; msg=$(BOSS_MSG) || { echo "  spawner mail not delivered"; return 1; }
    assert_file_contains "$msg" "queue drained: 1 task(s) done" "notify body" || return 1
    assert_eq "notify" "$(jq -r .kind "$msg")" "kind notify" || return 1
    assert_eq "worker" "$(jq -r .from "$msg")" "from worker" || return 1
    [ ! -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" ] || { echo "  spawned-by not one-shot"; return 1; }
    # A later, unrelated drain must not re-notify.
    mkdir -p "$CS_SESSIONS_ROOT/worker/.cs/local/queue"
    printf 'later task\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue/0000000009-later"
    printf 'armed\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/queue.state"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "1" "$(BOSS_MSG_COUNT)" "no second notify" || return 1
}

test_breaker_trip_notifies_and_keeps_spawned_by() {
    _arm_worker_queue "task a" "task b"
    _worker_stop_turn >/dev/null || return 1        # draining, task a injected
    printf '9\n' > "$CS_SESSIONS_ROOT/worker/.cs/local/failures"
    _worker_stop_turn >/dev/null || return 1        # trips the failure breaker
    local msg; msg=$(BOSS_MSG) || { echo "  trip mail not delivered"; return 1; }
    assert_file_contains "$msg" "breaker tripped" "trip notified" || return 1
    assert_file_exists "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by" "spawned-by kept on trip" || return 1
}

test_drain_without_spawned_by_sends_nothing() {
    _arm_worker_queue "solo task"
    rm -f "$CS_SESSIONS_ROOT/worker/.cs/local/spawned-by"
    _worker_stop_turn >/dev/null || return 1
    _worker_stop_turn >/dev/null || return 1
    assert_eq "0" "$(BOSS_MSG_COUNT)" "notify sent without spawned-by" || return 1
}

run_test test_drain_finished_notifies_spawner_once
run_test test_breaker_trip_notifies_and_keeps_spawned_by
run_test test_drain_without_spawned_by_sends_nothing

report_results
