# tmux Spawner (`cs -spawn`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cs -spawn <name> [--task "..."]...` opens a cs session in a cs-owned tmux window, optionally seeding + arming its walk-away queue, with drain completion notified back to the spawner over the mailbox.

**Architecture:** A new `lib/52-spawn.sh` validates, writes an atomic seed file to `$SESSIONS_ROOT/.spawn/<name>.seed`, and opens a tmux window running the normal `cs <name>` launch. The launch path (`lib/75-launch.sh`) consumes fresh seeds after the already-running guard and before exec: queues tasks, arms, writes `spawned-by`, and passes a kick prompt as claude's positional argument (replacing the color slash-command for that launch, and bypassing the interactive resume ask). The Stop-hook drain (`hooks/narrative-reminder.sh`) sends a one-shot mailbox notify to the spawner on drain-finished. Spec: `docs/superpowers/specs/2026-07-18-tmux-spawner-design.md`.

**Tech Stack:** bash 3.2, BSD userland, tmux (behind a `CS_TMUX_BIN` wrapper so tests never touch a real server), jq (mailbox side), existing cs test harness.

## Global Constraints

- bash 3.2 + BSD userland only: no `local -A`, no `mapfile`, no GNU-only flags; empty arrays must not be expanded under `set -u`.
- `bin/cs` is generated: after ANY `lib/*.sh` edit run `./build.sh` BEFORE tests (tests execute `bin/cs`). Never edit `bin/cs` directly.
- Every test assertion ends with `|| return 1`.
- Tests NEVER touch a real tmux server: all tmux calls go through `"${CS_TMUX_BIN:-tmux}"` and tests point `CS_TMUX_BIN` at a recording fake.
- Seed file: `$SESSIONS_ROOT/.spawn/<name>.seed`; line 1 = spawner name (may be empty), lines 2..N = one task each; written tmp+`mv`; spawn refuses when a seed already exists; consumption TTL 3600 seconds (older seeds move to `<name>.seed.stale`).
- Name gate: `cs_split_worktree_name` for `base@task` names, else `validate_session_name` (lib/25-deps.sh). tmux command line single-quote encoded on top of that.
- tmux session name `cs` on the default server; ownership stamped/required via user option `@cs_managed=1`; window IDs captured with `-P -F '#{window_id}'`.
- Kick prompt strings, verbatim: with spawner `Spawned by <spawner>. Your walk-away queue is armed with <N> task(s); begin. Send results with: cs -msg <spawner> -k result "..."`; without spawner `Your walk-away queue is armed with <N> task(s); begin.`
- Hook side effects are best-effort: `2>/dev/null`, `|| true`, never break the hook.
- Commit after each task; stage files explicitly, never `git add -A`; leave the pre-existing `.gitignore`/`CLAUDE.md` working-tree changes alone.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/52-spawn.sh` (create) | `run_spawn` (parse/validate), `_spawn_precheck`, seed writer, `_spawn_window`, `_tmux`/`_sq`/`_cs_self` helpers |
| `lib/75-launch.sh` (modify) | seed consumption + `launch_prompt` threading + resume-ask bypass |
| `lib/40-state.sh` (modify) | `_exec_fresh_rebind` honors `CS_SPAWN_KICK` |
| `lib/99-main.sh`, `lib/10-help.sh`, `completions/_cs`, `completions/cs.bash` (modify) | dispatch, help, completion drift-net |
| `hooks/narrative-reminder.sh` (modify) | spawned-by notify on drain_finished / breaker_tripped |
| `tests/test_spawn.sh` (create) | full suite (auto-discovered by `tests/run_all.sh`) |
| `README.md`, `docs/session-layout.md`, `docs/hooks.md` (modify) | docs |

---

### Task 1: `cs -spawn` verb — validation, seed, tmux window

**Files:**
- Create: `lib/52-spawn.sh`
- Modify: `lib/99-main.sh` (global arm after the `-msg` arm; session-scoped arm NOT added — spawn's target is positional and spawning is not a per-session subcommand)
- Modify: `lib/10-help.sh` (after the `-msg log` help line)
- Modify: `completions/_cs` (both `-msg` sites), `completions/cs.bash` (`global_flags` only — `-spawn` is not a session subcommand, so NOT in `session_opts`)
- Test: `tests/test_spawn.sh`

**Interfaces:**
- Consumes: `error`/`info` (lib/05-term.sh), `_trim` (lib/05-term.sh), `validate_session_name` (lib/25-deps.sh), `cs_split_worktree_name` (lib/30-worktree.sh), `session_is_live` (lib/15-lock.sh), `SESSIONS_ROOT`, `CLAUDE_SESSION_NAME`.
- Produces: `run_spawn "$@"`; seed files at `$SESSIONS_ROOT/.spawn/<name>.seed` in the exact format Task 2 consumes; `CS_TMUX_BIN` override honored by every tmux call.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_spawn.sh`:

```bash
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
    new-session)  if [ -f "$FAKE_TMUX_DIR/race" ]; then exit 1; fi
                  touch "$FAKE_TMUX_DIR/session-exists"
                  case "$*" in *" -P "*) echo '@0';; esac ;;
    set-option)   printf '1\n' > "$FAKE_TMUX_DIR/managed" ;;
    show-option)  [ -f "$FAKE_TMUX_DIR/managed" ] && cat "$FAKE_TMUX_DIR/managed" ;;
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

report_results
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_spawn.sh`
Expected: all 11 FAIL (`-spawn` is an unknown command).

- [ ] **Step 3: Implement `lib/52-spawn.sh`**

```bash
# ABOUTME: Backs 'cs -spawn': open a session in the cs-owned tmux session,
# ABOUTME: optionally staging tasks the launch path arms on open.

# Every tmux call goes through this wrapper; tests point CS_TMUX_BIN at a fake.
_tmux() {
    "${CS_TMUX_BIN:-tmux}" "$@"
}

# Single-quote encode one word for a shell command line handed to tmux.
_sq() {  # text
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Absolute path of the running cs binary (the tmux server's PATH may lack
# ~/.local/bin, so the window command must not rely on lookup).
_cs_self() {
    case "$0" in
        */*) printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")";;
        *)   command -v -- "$0" 2>/dev/null || printf '%s' "$0";;
    esac
}

# Pre-window checks that must pass BEFORE the seed is written, so a refused
# spawn never leaves a pending seed behind.
_spawn_precheck() {  # name
    local name="$1"
    command -v "${CS_TMUX_BIN:-tmux}" >/dev/null 2>&1 || error "cs -spawn needs tmux"
    if session_is_live "$SESSIONS_ROOT/$name/.cs"; then
        error "Session $name is already live"
    fi
    if _tmux has-session -t cs 2>/dev/null; then
        local owned
        owned=$(_tmux show-option -t cs -v @cs_managed 2>/dev/null || true)
        [ "$owned" = "1" ] || error "A tmux session named 'cs' exists but was not created by cs; close or rename it"
        if _tmux list-windows -t cs -F '#{window_name}' 2>/dev/null | grep -Fxq "$name"; then
            error "A window named $name already exists in tmux session cs"
        fi
    fi
}

_spawn_window() {  # name
    local name="$1" cmd wid
    cmd="$(_sq "$(_cs_self)") $(_sq "$name")"
    if ! _tmux has-session -t cs 2>/dev/null; then
        if wid=$(_tmux new-session -d -s cs -n "$name" -P -F '#{window_id}' "$cmd" 2>/dev/null); then
            _tmux set-option -t cs @cs_managed 1
            info "spawned $name in tmux session cs (window $wid). Attach: tmux attach -t cs"
            return 0
        fi
        # A concurrent spawner won the new-session race: fall through and add
        # a window to the session it just created.
    fi
    wid=$(_tmux new-window -t cs -n "$name" -P -F '#{window_id}' "$cmd") \
        || error "tmux new-window failed for $name"
    info "spawned $name in tmux session cs (window $wid). Attach: tmux attach -t cs"
}

run_spawn() {
    local name="" nl='
'
    local tasks
    tasks=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --task)
                [ $# -ge 2 ] || error "--task needs a value"
                shift
                local t
                t="$(_trim "$1")"
                [ -n "$t" ] || error "cs -spawn --task needs a non-empty task"
                case "$t" in *"$nl"*) error "task bodies must be a single line (the queue file is line-oriented)";; esac
                tasks+=("$t");;
            -*) error "Unknown option: $1. Usage: cs -spawn <name> [--task \"...\"] ...";;
            *)
                [ -z "$name" ] || error "cs -spawn takes exactly one session name"
                name="$1";;
        esac
        shift
    done
    [ -n "$name" ] || error "Usage: cs -spawn <name> [--task \"...\"] ..."
    if ! cs_split_worktree_name "$name"; then
        validate_session_name "$name"
    fi
    _spawn_precheck "$name"
    if [ "${#tasks[@]}" -gt 0 ]; then
        local sdir="$SESSIONS_ROOT/.spawn" seed
        seed="$sdir/$name.seed"
        [ ! -f "$seed" ] || error "A pending spawn for $name exists: $seed"
        mkdir -p "$sdir"
        {
            printf '%s\n' "${CLAUDE_SESSION_NAME:-}"
            local _t
            for _t in "${tasks[@]}"; do printf '%s\n' "$_t"; done
        } > "$seed.tmp" && mv "$seed.tmp" "$seed"
    fi
    _spawn_window "$name"
}
```

- [ ] **Step 4: Wire dispatch, help, completions**

`lib/99-main.sh`, directly after the global `-msg` arm:

```bash
        -spawn)
            shift
            run_spawn "$@"
            return 0
            ;;
```

`lib/10-help.sh`, after the `-msg log` line:

```
  -spawn <name>       Open a session in the cs tmux session (--task "..." seeds and arms its queue)
```

`completions/_cs`: add `'-spawn:Open a session in a cs-owned tmux window'` next to the `-msg` entry in the GLOBAL list only (~line 103). Do not add it to `session_opts` (~line 203) — spawn is not a per-session subcommand.

`completions/cs.bash`: add `-spawn` to `global_flags` (line 14) only, not `session_opts`.

- [ ] **Step 5: Build and run**

Run: `./build.sh && bash tests/test_spawn.sh`
Expected: 11/11 PASS.

- [ ] **Step 6: Full suites**

Run: `set -o pipefail; bash tests/run_all.sh 2>&1 | tail -8`
Expected: all suites pass, including the completion drift-net in `tests/test_completions.sh` (if it fails on `-spawn`, the completions edit in Step 4 is incomplete — fix the completions, never the test).

- [ ] **Step 7: Commit**

```bash
git add lib/52-spawn.sh lib/99-main.sh lib/10-help.sh completions/_cs completions/cs.bash bin/cs tests/test_spawn.sh
git commit -m "feat: cs -spawn opens a session in the cs-owned tmux session"
```

---

### Task 2: Launch-path seed consumption + kick prompt

**Files:**
- Modify: `lib/75-launch.sh` (three edits: seed consumption block, resume-ask bypass, `launch_prompt` in the three claude invocations)
- Modify: `lib/40-state.sh` (`_exec_fresh_rebind` honors `CS_SPAWN_KICK`)
- Test: `tests/test_spawn.sh`

**Interfaces:**
- Consumes: seed files from Task 1 (`$SESSIONS_ROOT/.spawn/<name>.seed`, line 1 spawner, rest tasks); `_queue_add qdir text` (lib/55-queue.sh); `_epoch_mtime path` (lib/15-lock.sh); `warn` (lib/10-help.sh).
- Produces: on launch — tasks queued in order, `queue.state` = `armed`, `.cs/local/spawned-by` (only when spawner non-empty), seed deleted, `CS_SPAWN_KICK` exported, kick prompt as claude's positional arg replacing the color arg; stale seeds moved to `<name>.seed.stale`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_spawn.sh` (tests before the `run_test` block, `run_test` lines after the existing ones, `report_results` last):

```bash
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

run_test test_launch_consumes_seed_queues_arms_and_kicks
run_test test_launch_empty_spawner_gets_no_reply_wiring
run_test test_launch_without_seed_keeps_color_behavior
run_test test_launch_sets_aside_stale_seed
run_test test_launch_seed_bypasses_resume_ask
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_spawn.sh`
Expected: the five new tests FAIL (seeds ignored by launch).

- [ ] **Step 3: Implement — seed consumption in `lib/75-launch.sh`**

Insert directly after the `CS_CLAUDE_SESSION_ID` export block (the `fi` following `export CS_CLAUDE_SESSION_ID="$claude_session_id"`) and before the `# Status indicator` comment:

```bash
    # Spawn seed: tasks staged by cs -spawn for this session. Consumed here,
    # after the already-running guard and before any exec arm, so a window
    # that died before launching self-heals on the session's next open. A
    # stale seed (>1h) is set aside, never silently armed days later.
    local spawn_kick=""
    local _seed="$SESSIONS_ROOT/.spawn/$session_name.seed"
    if [ -f "$_seed" ]; then
        local _now _age
        _now=$(date +%s)
        _age=$(( _now - $(_epoch_mtime "$_seed") ))
        if [ "$_age" -gt 3600 ]; then
            mv "$_seed" "$_seed.stale" 2>/dev/null || true
            warn "Stale spawn seed set aside: $_seed.stale (re-run cs -spawn if still wanted)"
        else
            local _spawner="" _line _n=0 _first=1
            while IFS= read -r _line || [ -n "$_line" ]; do
                if [ "$_first" = 1 ]; then _spawner="$_line"; _first=0; continue; fi
                [ -n "$_line" ] || continue
                _queue_add "$session_dir/.cs/local" "$_line"
                _n=$((_n + 1))
            done < "$_seed"
            if [ "$_n" -gt 0 ]; then
                printf 'armed\n' > "$session_dir/.cs/local/queue.state.tmp" \
                    && mv "$session_dir/.cs/local/queue.state.tmp" "$session_dir/.cs/local/queue.state"
                if [ -n "$_spawner" ]; then
                    printf '%s\n' "$_spawner" > "$session_dir/.cs/local/spawned-by"
                    spawn_kick="Spawned by $_spawner. Your walk-away queue is armed with $_n task(s); begin. Send results with: cs -msg $_spawner -k result \"...\""
                else
                    spawn_kick="Your walk-away queue is armed with $_n task(s); begin."
                fi
            fi
            rm -f "$_seed"
        fi
    fi
    # The kick prompt takes claude's single positional-prompt slot, displacing
    # the /color re-apply for this one launch (color returns next open).
    local launch_prompt="${spawn_kick:-$color_arg}"
    export CS_SPAWN_KICK="$spawn_kick"
```

- [ ] **Step 4: Implement — resume-ask bypass in `lib/75-launch.sh`**

In the `is_new = "false"` branch, replace:

```bash
        if [ -n "$pending_handoff" ]; then
            printf "${DIM}Rotation handoff pending:${NC} %s\n" "$(basename "$pending_handoff")"
            printf "${DIM}Continue previous conversation?${NC} [Y/n/r] ${DIM}(r = fresh conversation with handoff)${NC} "
        else
            printf "${DIM}Continue previous conversation?${NC} [Y/n] "
        fi
        read -r response || exit 130
```

with:

```bash
        # A spawned launch is unattended: take the default (resume) instead
        # of parking the tmux window on an interactive ask.
        if [ -n "$spawn_kick" ]; then
            response=""
        else
            if [ -n "$pending_handoff" ]; then
                printf "${DIM}Rotation handoff pending:${NC} %s\n" "$(basename "$pending_handoff")"
                printf "${DIM}Continue previous conversation?${NC} [Y/n/r] ${DIM}(r = fresh conversation with handoff)${NC} "
            else
                printf "${DIM}Continue previous conversation?${NC} [Y/n] "
            fi
            read -r response || exit 130
        fi
```

(`response` must not be declared inside the else-arm; it is already assigned by `read` today — keep it a plain assignment.)

- [ ] **Step 5: Implement — thread `launch_prompt` through the three invocations**

In `lib/75-launch.sh`, replace all three `${color_arg:+"$color_arg"}` occurrences (the `$continue_flag` invocation and the two `exec` arms) with `${launch_prompt:+"$launch_prompt"}`.

In `lib/40-state.sh` `_exec_fresh_rebind`, after the `color_arg` assignment lines:

```bash
    local color_arg=""
    [ -n "$session_color" ] && color_arg="/color $session_color"
```

append:

```bash
    # A spawn kick (exported by launch_claude_code) outranks the color
    # re-apply for this launch; both ride claude's single prompt slot.
    local launch_prompt="${CS_SPAWN_KICK:-$color_arg}"
```

and replace `${color_arg:+"$color_arg"}` in its exec line with `${launch_prompt:+"$launch_prompt"}`.

- [ ] **Step 6: Build and run**

Run: `./build.sh && bash tests/test_spawn.sh`
Expected: 16/16 PASS.

- [ ] **Step 7: Full suites**

Run: `set -o pipefail; bash tests/run_all.sh 2>&1 | tail -8`
Expected: all suites pass — watch `tests/test_uuid.sh`, `tests/test_local_state.sh`, `tests/test_theme.sh` (they assert on claude argv through the same exec arms).

- [ ] **Step 8: Commit**

```bash
git add lib/75-launch.sh lib/40-state.sh bin/cs tests/test_spawn.sh
git commit -m "feat: launch consumes spawn seeds — queue, arm, kick prompt"
```

---

### Task 3: Drain-finished notify to the spawner

**Files:**
- Modify: `hooks/narrative-reminder.sh` (two insertions in the drain choke point)
- Test: `tests/test_spawn.sh`

**Interfaces:**
- Consumes: `.cs/local/spawned-by` (Task 2); `cs -msg <target> -k notify "..."` (shipped mailbox); the existing `drain_finished` / `breaker_tripped` `_inbox_append` sites; `QDIR`, `DONE_COUNT`, `REASON_KIND`/`READING`/`LIMIT`/`NEWLEN` variables already in scope at those sites.
- Produces: one-shot spawner notification; `spawned-by` deleted on drain-finished, kept on breaker-trip.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_spawn.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_spawn.sh`
Expected: the first two new tests FAIL (no notify sent); the third may already pass — that is fine, it pins the negative.

- [ ] **Step 3: Implement in `hooks/narrative-reminder.sh`**

At the `drain_finished` site — directly after this existing line:

```bash
                _inbox_append --arg ts "$(date +%s)" --arg d "$DONE_COUNT" \
                    '{ts: ($ts|tonumber), event: "drain_finished", done: ($d|tonumber)}'
```

insert:

```bash
                # Spawned worker: tell the spawner its batch is done. One-shot
                # (spawned-by is deleted) so later unrelated drains stay
                # silent. Best-effort: a failed send never breaks the drain.
                if [ -s "$QDIR/spawned-by" ]; then
                    SPAWNER=""
                    IFS= read -r SPAWNER < "$QDIR/spawned-by" || true
                    if [ -n "$SPAWNER" ] && command -v cs >/dev/null 2>&1; then
                        cs -msg "$SPAWNER" -k notify "queue drained: $DONE_COUNT task(s) done" >/dev/null 2>&1 || true
                    fi
                    rm -f "$QDIR/spawned-by"
                fi
```

At the `breaker_tripped` site — directly after its `_inbox_append ... breaker_tripped ...'` statement — insert:

```bash
                # Spawned worker: surface the trip to the spawner but KEEP
                # spawned-by, so the eventual real drain still reports.
                if [ -s "$QDIR/spawned-by" ]; then
                    SPAWNER=""
                    IFS= read -r SPAWNER < "$QDIR/spawned-by" || true
                    if [ -n "$SPAWNER" ] && command -v cs >/dev/null 2>&1; then
                        cs -msg "$SPAWNER" -k notify "breaker tripped: $REASON_KIND ($READING >= $LIMIT), $NEWLEN task(s) remaining" >/dev/null 2>&1 || true
                    fi
                fi
```

- [ ] **Step 4: Run and full suites**

Run: `bash tests/test_spawn.sh && set -o pipefail && bash tests/run_all.sh 2>&1 | tail -5`
Expected: 19/19 in test_spawn.sh; all suites green (hooks are standalone — no `./build.sh` needed for this task).

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_spawn.sh
git commit -m "feat: spawned workers notify their spawner when the queue drains"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (Features bullet next to the cross-session mail one; plain hyphen title separator, matching the other Features bullets)
- Modify: `docs/session-layout.md` (rows relative to their tables' roots, trailing periods, matching row style)
- Modify: `docs/hooks.md` (narrative-reminder + launch behavior)

**Interfaces:** none (docs only).

- [ ] **Step 1: README bullet**

```markdown
- **tmux spawner** - `cs -spawn <name>` opens a session in a cs-owned tmux
  session (`tmux attach -t cs`); `--task "..."` seeds and arms its walk-away
  queue so it starts working unattended, and the spawner hears back over
  cross-session mail when the queue drains. Same-machine only.
```

- [ ] **Step 2: docs/session-layout.md**

In the `.cs/local/` table:

```markdown
| `spawned-by` | Spawner session name for a `cs -spawn`ed worker; deleted after the drain-finished notify (one-shot). |
```

In the section describing `$SESSIONS_ROOT` top-level contents (or a new short paragraph if none exists):

```markdown
`.spawn/` at the sessions root stages `<name>.seed` files written by
`cs -spawn --task`: line 1 is the spawner, remaining lines are tasks. The
launch consumes fresh seeds (queued, armed, kick prompt); seeds older than an
hour are set aside as `<name>.seed.stale` and never applied silently.
```

- [ ] **Step 3: docs/hooks.md**

In the narrative-reminder.sh (Stop hook / drain) section, add a bullet matching the surrounding style:

```markdown
- Spawned workers report back: when `.cs/local/spawned-by` exists, drain
  completion sends the spawner a mailbox notify and deletes the marker
  (one-shot); a breaker trip notifies but keeps the marker so the eventual
  drain still reports.
```

- [ ] **Step 4: Verify docs against code**

Run: `rg -n -- '-spawn|spawned-by|\.spawn/' README.md docs/session-layout.md docs/hooks.md bin/cs hooks/narrative-reminder.sh | head -25`
Expected: every documented flag, path, and behavior has a matching source line.

- [ ] **Step 5: Full-suite sanity gate and commit**

Run: `set -o pipefail; bash tests/run_all.sh 2>&1 | tail -3`
Expected: all suites pass (some suites pin docs content).

```bash
git add README.md docs/session-layout.md docs/hooks.md
git commit -m "docs: tmux spawner (cs -spawn)"
```
