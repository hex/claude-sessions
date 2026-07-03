# Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-session, machine-local queue of prompts that cs drains autonomously at Stop-hook turn boundaries after a single confirmation gate, with a native task-list mirror and a TUI entry point.

**Architecture:** A plain-text queue file under `.cs/local/` is the source of truth. The `-queue` CLI verb and the Rust TUI manage it. The existing Stop hook (`narrative-reminder.sh`) reads it and, when armed, hands the agent its next task via a `{"decision":"block","reason":...}` response — the same mechanism that already drives the narrative nag. The statusline stamps context % into a sibling file the gate reads.

**Tech Stack:** bash 3.2 (bin/cs, hooks, cs-statusline), Rust (tui/, ratatui 0.29), jq, awk. Bash test harness in `tests/` + `cargo test` for the TUI.

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec):

- **bash 3.2 + BSD userland.** No `local -A`, no `${var,,}`, no `readarray`. Use `awk`/`printf`, BSD-safe `sed` (`s/x*/…/`, never GNU `\+`). `printf '%(%s)T'` is unreliable — use `date +%s`.
- **No auto-commit of user work; never `git add -A`.** All queue state lives in `.cs/local/`, which is gitignored (`create_session_gitignore`, bin/cs:3164) — never committed.
- **Dynamic block reasons emit via `jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'`** (the `prose-lint.sh:97` pattern), NEVER the `narrative-reminder.sh` raw heredoc — queue text is arbitrary and would break JSON.
- **Captured helpers stay silent:** a bash function whose stdout is `$(...)`-captured must not call `info`/`warn` (they write to stdout, bin/cs:145/370) and must not `error`/`exit` (only kills the subshell). Usage/exit gates live in the caller.
- **Atomic writes:** rewrites (rm/clear/pop) use tmp+mv (`_set_local_state` pattern, bin/cs:1287). Appends (add) use `>>` with a single `printf` line — atomic per line and race-free against concurrent adds (a tmp+mv rewrite would lose updates).
- **Test harness (`tests/test_lib.sh`):** `run_test` runs each test inside an `if`, disabling errexit in the body — so **every assert needs `|| return 1`**. New test functions must be registered in the suite file's bottom `run_test` block or they never run. No runner script: `for f in tests/test_*.sh; do bash "$f"; done`.
- **Rust:** adding a field to `Session` (session.rs:8) requires updating every `Session { … }` literal in `sample_sessions()` (app.rs:1348) and the session.rs test fixtures, or `cargo test` won't compile.
- **State-file values:** `queue.state` ∈ {`idle`,`armed`,`draining`} (absent ⇒ idle). `queue.declined` holds a `date +%s` epoch. Gate context threshold = **60**. Decline cooldown = **600** seconds.

---

### Task 1: `-queue` CLI verb (file ops + dispatch + help)

**Files:**
- Modify: `bin/cs` — add `run_queue` + `_queue_*` helpers; wire `-queue` into the top-level dispatch (near bin/cs:3573) and the session-scoped flag arm (near bin/cs:3648); add help lines (bin/cs:308-332).
- Modify: `completions/cs.bash`, `completions/_cs` — add the `-queue` verb.
- Create: `tests/test_queue.sh`

**Interfaces:**
- Produces: queue files under `<session>/.cs/local/`: `queue` (one prompt/line), `queue.done`, `queue.state` (single word), `queue.declined` (epoch). CLI: `cs <session> -queue add "text" | list | rm <n> | clear | start | defer`.
- Consumes: `_read_local_state` is not used (queue files are plain, not `key: value`). Resolves the target `.cs/local` from `CLAUDE_SESSION_META_DIR`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_queue.sh`:

```bash
#!/usr/bin/env bash
# Tests for the cs -queue verb and the Stop-hook drain.
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

test_queue_add_appends_a_line() {
    "$CS_BIN" -queue add "first task" >/dev/null 2>&1
    "$CS_BIN" -queue add "second task" >/dev/null 2>&1
    assert_file_contains "$(QFILE)" "first task" "add writes the task" || return 1
    assert_eq "2" "$(grep -c . "$(QFILE)")" "two tasks queued" || return 1
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
    assert_file_contains "$(QFILE)" "keep" "kept task remains" || return 1
    assert_file_not_contains "$(QFILE)" "drop" "removed task is gone" || return 1
}

test_queue_clear_empties_and_resets_state() {
    "$CS_BIN" -queue add "x" >/dev/null 2>&1
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    "$CS_BIN" -queue clear >/dev/null 2>&1
    assert_file_not_exists "$(QFILE)" "queue file removed" || return 1
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

run_test test_queue_add_appends_a_line
run_test test_queue_list_numbers_pending
run_test test_queue_rm_removes_by_index
run_test test_queue_clear_empties_and_resets_state
run_test test_queue_start_sets_armed
run_test test_queue_defer_writes_declined_epoch
run_test test_queue_add_clears_declined
run_test test_queue_requires_session
report_results
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_queue.sh`
Expected: FAIL — `cs -queue` is an unknown command (falls through to the `-*)` catch-all at bin/cs:3627).

- [ ] **Step 3: Implement `run_queue` + helpers in bin/cs**

Add near the other subcommand dispatchers (e.g. after `run_checkpoint`, bin/cs:2119). Captured helpers stay silent; the dispatcher owns the `error` gate:

```bash
# --- Task queue (cs -queue) ---------------------------------------------------
# Machine-local queue of prompts drained by the Stop hook. Files live in
# <session>/.cs/local/: queue (one prompt/line), queue.done, queue.state
# (idle|armed|draining), queue.declined (epoch). Plain files so the standalone
# Stop hook can read them without bin/cs's helpers.

_queue_set_state() {  # atomic single-word write; "" removes the file
    local qdir="$1" val="$2"
    mkdir -p "$qdir"
    if [ -z "$val" ]; then rm -f "$qdir/queue.state"; return 0; fi
    printf '%s\n' "$val" > "$qdir/queue.state.tmp" && mv "$qdir/queue.state.tmp" "$qdir/queue.state"
}

_queue_add() {  # qdir, text
    local qdir="$1" text="$2"
    text="${text#"${text%%[![:space:]]*}"}"  # ltrim
    text="${text%"${text##*[![:space:]]}"}"  # rtrim
    [ -n "$text" ] || { error "cs -queue add needs a non-empty task"; }
    mkdir -p "$qdir"
    printf '%s\n' "$text" >> "$qdir/queue"
    rm -f "$qdir/queue.declined"   # queue changed: allow the gate to re-ask
}

_queue_list() {  # qdir
    local qdir="$1"
    if [ -s "$qdir/queue" ]; then
        echo "Pending:"
        awk 'NF{ printf "  %d. %s\n", ++n, $0 }' "$qdir/queue"
    else
        echo "Queue is empty."
    fi
    if [ -s "$qdir/queue.done" ]; then
        echo "Done:"
        awk 'NF{ printf "  - %s\n", $0 }' "$qdir/queue.done"
    fi
}

_queue_rm() {  # qdir, index
    local qdir="$1" n="$2"
    case "$n" in ''|*[!0-9]*) error "cs -queue rm needs a line number";; esac
    [ -f "$qdir/queue" ] || { error "queue is empty"; }
    awk -v target="$n" 'NF{ c++ } { if (c==target && NF) next; print }' "$qdir/queue" \
        > "$qdir/queue.tmp" && mv "$qdir/queue.tmp" "$qdir/queue"
    rm -f "$qdir/queue.declined"
}

_queue_clear() {  # qdir
    local qdir="$1"
    rm -f "$qdir/queue" "$qdir/queue.state" "$qdir/queue.declined"
}

# Dispatcher. Runs inside a session (env) or via the session-scoped arm.
run_queue() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -queue must be run inside a cs session, or as: cs <session> -queue ..."
    fi
    local qdir="$CLAUDE_SESSION_META_DIR/local"
    local sub="${1:-list}"
    case "$sub" in
        add)   shift; _queue_add "$qdir" "$*";;
        list|ls) _queue_list "$qdir";;
        rm)    shift; _queue_rm "$qdir" "${1:-}";;
        clear) _queue_clear "$qdir";;
        start) _queue_set_state "$qdir" armed;;
        defer) mkdir -p "$qdir"; printf '%s\n' "$(date +%s)" > "$qdir/queue.declined";;
        *)     error "Usage: cs -queue [add \"<task>\" | list | rm <n> | clear]";;
    esac
}
```

Note: `_queue_rm`'s awk removes the Nth *non-blank* line (matches `_queue_list`'s numbering).

- [ ] **Step 4: Wire `-queue` into both dispatch sites**

Top-level (in-session `cs -queue …`), add before the catch-all `-*)` at bin/cs:3627, mirroring `-secrets` (bin/cs:3573):

```bash
        -queue)
            shift
            run_queue "$@"
            return 0
            ;;
```

Session-scoped (`cs <session> -queue …` from another terminal): first Read bin/cs:3640-3670 to see the flag arm that handles `-secrets` (bin/cs:3648) — it exports `CLAUDE_SESSION_NAME/DIR/META_DIR` from `$session_name`. Add an adjacent `-queue)` arm mirroring it exactly, then `run_queue "$@"`, and match the surrounding `exit`/`return` used by the `-secrets` arm:

```bash
            -queue)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_queue "$@"
                exit $?
                ;;
```

- [ ] **Step 5: Add help lines** (bin/cs:308-332 heredoc, matching the two-space-indent/aligned style):

```
  -queue add "<task>" Add a task to the session's walk-away queue
  -queue list         Show pending and completed queued tasks
  -queue rm <n>       Remove pending task n
  -queue clear        Empty the queue and stop draining
```

- [ ] **Step 6: Update completions**

In `completions/cs.bash` and `completions/_cs`, add `-queue` to the verb list (grep those files for `-checkpoint` and add `-queue` alongside, matching the surrounding format). Run `bash tests/test_completions.sh` if it exists — it may assert every verb appears in completions.

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash tests/test_queue.sh`
Expected: PASS (8/8).

- [ ] **Step 8: Commit**

```bash
git add bin/cs tests/test_queue.sh completions/cs.bash completions/_cs
git commit -m "feat: cs -queue verb (add/list/rm/clear/start/defer)"
```

---

### Task 2: Stop-hook drain state machine

**Files:**
- Modify: `hooks/narrative-reminder.sh` — insert the drain block after the attention-flag raise (~line 35) and before the narrative cooldown logic.
- Modify: `tests/test_queue.sh` — add drain tests + register them.

**Interfaces:**
- Consumes: the queue files from Task 1; `CLAUDE_SESSION_META_DIR`; `queue.state`; `queue.declined`; `context-pct` (optional, from Task 3 — absent is handled).
- Produces: on stdout, either `{"decision":"approve"}` (fall through) or `{"decision":"block","reason":...}` (gate / task injection). Mutates `queue`, `queue.done`, `queue.state`.

- [ ] **Step 1: Write the failing drain tests** (append to `tests/test_queue.sh` before `report_results`, and add matching `run_test` lines):

```bash
QDIR() { printf '%s' "$CLAUDE_SESSION_META_DIR/local"; }
drain() { echo "${1:-{}}" | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null; }

test_drain_gates_when_idle_nonempty() {
    printf 'do the thing\n' > "$(QDIR)/queue"
    local out; out=$(drain)
    assert_output_contains "$out" '"block"' "idle+nonempty blocks to gate" || return 1
    assert_output_contains "$out" "AskUserQuestion" "gate tells agent to ask" || return 1
    assert_file_not_exists "$(QDIR)/queue.state" "gate does not change state" || return 1
}

test_drain_armed_injects_first_task_no_pop() {
    printf 'task one\ntask two\n' > "$(QDIR)/queue"
    printf 'armed\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task one" "armed injects first task" || return 1
    assert_eq "draining" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "armed -> draining" || return 1
    assert_eq "2" "$(grep -c . "$(QDIR)/queue")" "no pop on first injection" || return 1
}

test_drain_draining_pops_and_injects_next() {
    printf 'task one\ntask two\n' > "$(QDIR)/queue"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "task two" "draining injects the next task" || return 1
    assert_file_contains "$(QDIR)/queue.done" "task one" "finished task logged to done" || return 1
    assert_eq "1" "$(grep -c . "$(QDIR)/queue")" "one task popped" || return 1
}

test_drain_empties_and_returns_idle() {
    printf 'last task\n' > "$(QDIR)/queue"
    printf 'draining\n' > "$(QDIR)/queue.state"
    local out; out=$(drain)
    assert_output_contains "$out" "complete" "announces completion" || return 1
    assert_eq "idle" "$(cat "$(QDIR)/queue.state" | tr -d '[:space:]')" "returns to idle" || return 1
}

test_drain_declined_within_cooldown_falls_through() {
    printf 'queued\n' > "$(QDIR)/queue"
    printf '%s\n' "$(date +%s)" > "$(QDIR)/queue.declined"
    local out; out=$(drain)
    assert_output_not_contains "$out" "AskUserQuestion" "recent decline suppresses the gate" || return 1
}

test_drain_ignores_subagents() {
    printf 'queued\n' > "$(QDIR)/queue"
    local out; out=$(drain '{"agent_id":"sub-1"}')
    assert_output_not_contains "$out" "AskUserQuestion" "subagent stop never drains" || return 1
}

test_drain_gate_mentions_high_context() {
    printf 'queued\n' > "$(QDIR)/queue"
    printf '82\n' > "$(QDIR)/context-pct"
    local out; out=$(drain)
    assert_output_contains "$out" "82" "gate surfaces context %" || return 1
    assert_output_contains "$out" "compact" "gate recommends compaction when high" || return 1
}
```

Register: add `run_test test_drain_...` lines for all seven before `report_results`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_queue.sh`
Expected: the new drain tests FAIL (the hook has no queue logic yet).

- [ ] **Step 3: Insert the drain block into `hooks/narrative-reminder.sh`**

Place it after the attention-flag `touch` (narrative-reminder.sh:35) and before `COOLDOWN_FILE=...`. It reads plain files (no bin/cs helpers), emits dynamic reasons via `jq -nc --arg`, and `exit 0`s on any block so it short-circuits the narrative nag (priority rule):

```bash
# --- Task queue drain (walk-away mode) ---------------------------------------
# Hands the agent its next queued task when armed; asks once when idle. Wins
# over the narrative nag (returns early). Queue text is arbitrary -> jq emit.
QDIR="$META_DIR/local"
QUEUE="$QDIR/queue"
QSTATE_FILE="$QDIR/queue.state"

_qlen() { [ -f "$1" ] && grep -c '[^[:space:]]' "$1" 2>/dev/null || echo 0; }

QLEN=$(_qlen "$QUEUE")
if [ "$QLEN" -gt 0 ]; then
    QSTATE=$(cat "$QSTATE_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$QSTATE" ] || QSTATE="idle"

    if [ "$QSTATE" = "armed" ]; then
        TASK=$(awk 'NF{print; exit}' "$QUEUE")
        printf 'draining\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        REASON="cs task queue — starting a walk-away run. Work through the queued tasks one at a time; I will hand you the next after each finishes. Mirror the queue into your native task list: create one task per queued item and mark each completed as you finish it.

First task: $TASK"
        jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
        exit 0
    fi

    if [ "$QSTATE" = "draining" ]; then
        DONE_TASK=$(awk 'NF{print; exit}' "$QUEUE")
        if awk 'popped==0 && NF { popped=1; next } { print }' "$QUEUE" \
                > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"; then
            printf '%s\n' "$DONE_TASK" >> "$QDIR/queue.done"
            NEWLEN=$(_qlen "$QUEUE")
            if [ "$NEWLEN" -le 0 ]; then
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                jq -nc '{decision:"block", reason:"cs task queue — all tasks complete. The queue is now empty."}'
                exit 0
            fi
            NEXT=$(awk 'NF{print; exit}' "$QUEUE")
            REASON="cs task queue — next task ($NEWLEN remaining). Mark the previous native task completed and this one in-progress, then do it.

Task: $NEXT"
            jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
            exit 0
        else
            # pop failed: disarm rather than re-inject the same task (fail-safe)
            printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        fi
    fi

    if [ "$QSTATE" = "idle" ]; then
        DECLINED="$QDIR/queue.declined"
        GATE=1
        if [ -f "$DECLINED" ]; then
            DECL_AT=$(cat "$DECLINED" 2>/dev/null | tr -d '[:space:]')
            NOW=$(date +%s)
            if [ -n "$DECL_AT" ] && [ $((NOW - DECL_AT)) -lt 600 ]; then
                GATE=0            # within cooldown: fall through to narrative
            else
                rm -f "$DECLINED"
            fi
        fi
        if [ "$GATE" = "1" ]; then
            CTX=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]')
            CTX_LINE="Context usage is unknown."
            COMPACT=""
            case "$CTX" in
                ''|*[!0-9]*) : ;;
                *) CTX_LINE="Context is at ${CTX}%."
                   [ "$CTX" -ge 60 ] && COMPACT=" Context is heavy — offer the user a 'Compact first' option (they run /compact) before starting." ;;
            esac
            REASON="cs task queue — $QLEN task(s) are queued for a walk-away run. $CTX_LINE$COMPACT Use AskUserQuestion to ask whether to work through them now (options: Start / Not yet). On Start, run: cs -queue start (then stop; I will hand you each task). On Not yet, run: cs -queue defer."
            jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
            exit 0
        fi
    fi
fi
# (falls through to the narrative reminder below when not gating/draining)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_queue.sh`
Expected: PASS (15/15). Then `bash tests/test_hooks.sh` — the existing narrative tests must still pass (the drain only fires when a queue exists; those fixtures have none).

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_queue.sh
git commit -m "feat: Stop hook drains the task queue when armed"
```

---

### Task 3: Statusline context-% stamp

**Files:**
- Modify: `bin/cs-statusline` — stamp `SL_CTX` into `.cs/local/context-pct` after it is read (cs-statusline:89).
- Modify: `tests/test_queue.sh` — add a stamp test + register it.

**Interfaces:**
- Consumes: `SL_CTX` (decimal string, may be empty), `SESSIONS_ROOT` (cs-statusline:7), `CLAUDE_SESSION_NAME`.
- Produces: `<session>/.cs/local/context-pct` (integer, or absent when unknown) — read by Task 2's gate.

- [ ] **Step 1: Write the failing test** (append to `tests/test_queue.sh` + register):

```bash
test_statusline_stamps_context_pct() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline"
    echo '{"context_window":{"used_percentage":73.4}}' | bash "$sl" >/dev/null 2>&1 || true
    assert_file_exists "$(QDIR)/context-pct" "statusline stamps context-pct" || return 1
    assert_file_contains "$(QDIR)/context-pct" "73" "stamps truncated integer" || return 1
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_queue.sh`
Expected: FAIL — no `context-pct` file written.

- [ ] **Step 3: Add the stamp to `bin/cs-statusline`**

Immediately after `SL_CTX` is populated (the `IFS= read -r SL_CTX` block ending ~cs-statusline:89), add an inline write (no fork; truncate to int; skip when empty):

```bash
# Stamp context % for the task-queue gate (the Stop hook reads this file).
# Machine-local, per the .cs/local partition; truncated to an integer.
if [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${SL_CTX:-}" ]; then
    _pctdir="$SESSIONS_ROOT/$CLAUDE_SESSION_NAME/.cs/local"
    if mkdir -p "$_pctdir" 2>/dev/null; then
        printf '%s\n' "${SL_CTX%%.*}" > "$_pctdir/context-pct.tmp" 2>/dev/null \
            && mv "$_pctdir/context-pct.tmp" "$_pctdir/context-pct" 2>/dev/null || true
    fi
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_queue.sh` — PASS. Then `bash tests/test_hooks.sh` and any statusline test file — still green.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_queue.sh
git commit -m "feat: statusline stamps context-pct for the queue gate"
```

---

### Task 4: TUI — add-to-queue keybinding

**Files:**
- Modify: `tui/src/app.rs` — `Mode::QueueAdd`; `queue_input: TextInput` field; `a` key in `handle_normal`; `handle_queue_add`; `execute_queue_add`; mode dispatch at app.rs:589; update `sample_sessions()` only if a Session field changes (it does not in this task).
- Test: `tui/src/app.rs` `#[cfg(test)]` module (app.rs:1343).

**Interfaces:**
- Consumes: `session::sessions_root()` (session.rs:131); the highlighted session (as `execute_rename`/`execute_delete` obtain it, app.rs:1065/1133).
- Produces: appends a line to `sessions_root().join(name).join(".cs/local/queue")` — the same file Task 1's CLI and Task 2's hook use.

- [ ] **Step 1: Write the failing tests** (in the app.rs test module, app.rs:1343):

```rust
#[test]
fn key_a_enters_queue_add_mode() {
    let mut app = App::new(sample_sessions());
    app.handle_key(KeyEvent::from(KeyCode::Char('a')));
    assert_eq!(app.mode, Mode::QueueAdd);
}

#[test]
fn queue_add_typing_accumulates() {
    let mut app = App::new(sample_sessions());
    app.handle_key(KeyEvent::from(KeyCode::Char('a')));
    app.handle_key(KeyEvent::from(KeyCode::Char('h')));
    app.handle_key(KeyEvent::from(KeyCode::Char('i')));
    assert_eq!(app.queue_input.text(), "hi");
}

#[test]
fn queue_add_enter_appends_to_queue_file() {
    let tmp = std::env::temp_dir().join(format!("cs-tui-q-{}", std::process::id()));
    std::env::set_var("CS_SESSIONS_ROOT", &tmp);
    let name = "alpha";                     // must match sample_sessions()[0]
    std::fs::create_dir_all(tmp.join(name).join(".cs/local")).unwrap();
    let mut app = App::new(sample_sessions());
    app.selected = 0;
    app.handle_key(KeyEvent::from(KeyCode::Char('a')));
    for c in "do X".chars() { app.handle_key(KeyEvent::from(KeyCode::Char(c))); }
    app.handle_key(KeyEvent::from(KeyCode::Enter));
    let q = std::fs::read_to_string(tmp.join(name).join(".cs/local/queue")).unwrap();
    assert!(q.contains("do X"));
    assert_eq!(app.mode, Mode::Normal);
    std::fs::remove_dir_all(&tmp).ok();
}
```

(If `sample_sessions()[0]` is not named `alpha`, or the selected-index field is not `selected`, adjust to the actual names — read app.rs:1348 and app.rs:1065 first.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd tui && cargo test key_a_enters_queue_add_mode queue_add_typing_accumulates queue_add_enter_appends_to_queue_file`
Expected: compile error (`Mode::QueueAdd`, `queue_input` undefined).

- [ ] **Step 3: Add the mode, field, key, and handlers**

`Mode` enum (app.rs:206) — add `QueueAdd,`. `App` struct — add `queue_input: TextInput,` beside `create_input` (app.rs:292) and initialise it in `App::new` (mirror `create_input: TextInput::default()` or however create_input is built). Mode dispatch (app.rs:589) — add `Mode::QueueAdd => self.handle_queue_add(key),`. In `handle_normal` (near app.rs:674) add:

```rust
KeyCode::Char('a') => {
    self.queue_input.clear();
    self.mode = Mode::QueueAdd;
    Action::None
}
```

Then the two handlers (mirror `handle_create_session` app.rs:944 / `execute_create` app.rs:978, and the selected-session lookup from `execute_rename` app.rs:1133):

```rust
fn handle_queue_add(&mut self, key: KeyEvent) -> Action {
    match key.code {
        KeyCode::Esc => { self.mode = Mode::Normal; }
        KeyCode::Enter => { return self.execute_queue_add(); }
        KeyCode::Left => { self.queue_input.move_left(); }
        KeyCode::Right => { self.queue_input.move_right(); }
        KeyCode::Backspace => { self.queue_input.backspace(); }
        KeyCode::Char(c) => { self.queue_input.insert(c); }
        _ => {}
    }
    Action::None
}

fn execute_queue_add(&mut self) -> Action {
    let text = self.queue_input.text().trim().to_string();
    self.mode = Mode::Normal;
    if text.is_empty() { return Action::None; }
    let name = match self.filtered.get(self.selected).and_then(|&i| self.sessions.get(i)) {
        Some(s) => s.name.clone(),
        None => return Action::None,
    };
    let dir = session::sessions_root().join(&name).join(".cs").join("local");
    let _ = std::fs::create_dir_all(&dir);
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("queue")) {
        let _ = writeln!(f, "{}", text);
    }
    self.set_status(format!("Queued task for {}", name));
    Action::None
}
```

(Match the exact `TextInput` method names — `move_left`/`move_right`/`backspace`/`insert` per app.rs:19; and the selected-index/`filtered` field names per `execute_delete` app.rs:1065. `set_status` per `execute_create`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && cargo test`
Expected: PASS (existing 114+ app tests still green; 3 new pass).

- [ ] **Step 5: Commit**

```bash
git add tui/src/app.rs
git commit -m "feat: TUI 'a' adds a task to the highlighted session's queue"
```

---

### Task 5: TUI — queue-depth badge

**Files:**
- Modify: `tui/src/session.rs` — add `queue_depth: u32` to `Session` (session.rs:8); populate in `scan_sessions_in` (session.rs:146) parallel to `secrets_count`; update session.rs test fixtures.
- Modify: `tui/src/ui.rs` — render a gutter badge when `queue_depth > 0` (mirror the secrets gutter icon, ui.rs:175-182), pushed into `name_spans` before ui.rs:244.
- Modify: `tui/src/app.rs` — add `queue_depth: 0` (or a value) to every `Session { … }` literal in `sample_sessions()` (app.rs:1348).

**Interfaces:**
- Consumes: the `.cs/local/queue` file written by Tasks 1/4.
- Produces: `Session.queue_depth`, surfaced as a picker badge.

- [ ] **Step 1: Write the failing test** (session.rs test module, session.rs:487, using the `setup_session` helper at session.rs:493):

```rust
#[test]
fn scan_counts_queue_depth() {
    let tmp = std::env::temp_dir().join(format!("cs-qd-{}", std::process::id()));
    let root = tmp.as_path();
    setup_session(root, "beta");
    let local = root.join("beta").join(".cs/local");
    std::fs::create_dir_all(&local).unwrap();
    std::fs::write(local.join("queue"), "t1\nt2\nt3\n").unwrap();
    let sessions = scan_sessions_in(root);
    let beta = sessions.iter().find(|s| s.name == "beta").unwrap();
    assert_eq!(beta.queue_depth, 3);
    std::fs::remove_dir_all(&tmp).ok();
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tui && cargo test scan_counts_queue_depth`
Expected: compile error (`queue_depth` not a field).

- [ ] **Step 3: Add the field, populate it, render it**

`Session` struct (session.rs:8): add `pub queue_depth: u32,`. In `scan_sessions_in` (session.rs:146), where each `Session` is built (alongside `secrets_count`), compute:

```rust
let queue_depth = std::fs::read_to_string(session_dir.join(".cs/local/queue"))
    .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count() as u32)
    .unwrap_or(0);
```

and add `queue_depth,` to the struct literal. (Use the same `session_dir` variable that `secrets_count` uses; read session.rs:146 to match its name.)

`ui.rs` — after the lock-icon gutter span block (ui.rs:168-182), mirror it for the depth badge, before `name_lines.push(...)` (ui.rs:244):

```rust
if s.queue_depth > 0 {
    name_spans.push(Span::styled(
        format!("[{}q] ", s.queue_depth),
        Style::default().fg(theme.accent),   // match the secrets-icon styling call
    ));
}
```

(Match the exact `Span`/`Style`/theme accessor used by the secrets gutter icon at ui.rs:175-182.)

- [ ] **Step 4: Update fixtures**

Add `queue_depth: 0,` to every `Session { … }` literal in `sample_sessions()` (app.rs:1348) and to any `Session { … }` literals in session.rs tests. Compile-driven: `cargo test` will name each site until all are updated.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd tui && cargo test`
Expected: PASS (new test + all existing).

- [ ] **Step 6: Commit**

```bash
git add tui/src/session.rs tui/src/ui.rs tui/src/app.rs
git commit -m "feat: TUI shows a queue-depth badge per session"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (a `-queue` section + the TUI `a` key), `CHANGELOG.md` (Unreleased entry), `docs/hooks.md` (note narrative-reminder.sh now also drains the queue), `docs/statusline.md` (the context-pct stamp).

- [ ] **Step 1: README** — add a "Task queue" subsection near the worktree/secrets docs: the `-queue add/list/rm/clear` verbs, the walk-away gate flow (queue, confirm once, drains at each stop, mirrors to the native task list, no mid-drain pause), and the TUI `a` keybinding + depth badge.

- [ ] **Step 2: CHANGELOG** — under `## [Unreleased]`, an `### Added` bullet: "cs -queue: a per-session walk-away task queue drained by the Stop hook after a one-time confirmation, with a native task-list mirror, a context-% compaction nudge at the gate, and a TUI add key + depth badge."

- [ ] **Step 3: docs/hooks.md** — in the `narrative-reminder.sh` / Stop section, note it now also drains `.cs/local/queue` (priority over the narrative nag) and emits task text via `jq -nc --arg`.

- [ ] **Step 4: docs/statusline.md** — note the statusline stamps `.cs/local/context-pct` for the queue gate.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md docs/hooks.md docs/statusline.md
git commit -m "docs: task queue (-queue, drain hook, statusline stamp, TUI)"
```

---

## Self-Review

**Spec coverage:**
- Data files (queue/done/state/declined/context-pct) → Tasks 1 (queue/done/state/declined) + 3 (context-pct). ✓
- State machine (idle→armed→draining, gate, pop, guards) → Task 2. ✓
- Trust-and-pop + done log → Task 2 Step 3. ✓
- Runaway guard (inject only after pop succeeds) → Task 2 Step 3 (`if awk … && mv …; then … else disarm`). ✓
- Decline cooldown (600s, cleared on queue change) → Task 1 (`_queue_add`/`_queue_rm`/`_queue_clear` rm declined; `defer` writes epoch) + Task 2 (cooldown check). ✓
- FIFO / append-to-bottom → Task 1 `_queue_add` uses `>>`; drain takes first non-blank line. ✓
- Native-list mirror instructions → Task 2 reason text (arm + draining). ✓
- Gate context / >60 compaction nudge → Task 2 gate + Task 3 stamp. ✓
- No mid-drain pause → drain never checks context once `draining`. ✓
- `-queue` CLI (single-dash, subcommand grammar) → Task 1. ✓
- Dual dispatch (in-session + `cs <session> -queue`) → Task 1 Step 4. ✓
- TUI add + depth badge → Tasks 4 + 5. ✓
- Fold into existing Stop hook, no new hook file → Task 2 (edits narrative-reminder.sh only). ✓
- Subagent pass-through → Task 2 relies on the existing `agent_id` guard above the drain block. ✓
- jq emission for dynamic reason → Task 2 Step 3. ✓
- Docs → Task 6. ✓

**Placeholder scan:** No TBD/TODO. The few "match the exact name" notes (TextInput methods, selected-index field, secrets-icon styling) are pinned to specific existing anchors the implementer reads — not open-ended.

**Type/name consistency:** `queue.state` values {idle,armed,draining} used identically in Tasks 1 and 2. `run_queue`/`_queue_*` names consistent. `queue_depth: u32` defined in Task 5 and added to fixtures in the same task. The queue file path `<session>/.cs/local/queue` is identical across CLI (Task 1), hook (Task 2), TUI add (Task 4), and scan (Task 5).

**Known soft spots (flagged, not placeholders):** the session-scoped dispatch arm (Task 1 Step 4) and the Rust selected-session lookup (Task 4) require reading a specific adjacent function first because the exact surrounding control flow / field names aren't reproduced here; both name the exact anchor to read.
