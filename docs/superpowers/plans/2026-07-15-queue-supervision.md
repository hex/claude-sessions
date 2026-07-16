# Walk-Away Queue Supervision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Circuit breakers that park a queue drain going bad (failures / context / five-hour window) plus an append-only notification inbox with a surface-once digest and `cs -queue log` — zero new hook files, zero statusline changes.

**Architecture:** Breakers evaluate at the drain's single choke point (the Stop hook's draining branch) using signals that already exist on disk; a per-task failure counter is fed by the existing failure logger. Five drain-lifecycle events append to `.cs/local/notifications.jsonl`; a cursor file makes the digest fire exactly once, spliced into the existing UserPromptSubmit and SessionStart context payloads.

**Tech Stack:** bash 3.2 + BSD userland (hooks are standalone scripts; lib/ fragments assembled into bin/cs by build.sh), jq.

**Spec:** docs/superpowers/specs/2026-07-15-queue-supervision-design.md

## Global Constraints

- `bin/cs` is GENERATED. Edit `lib/` fragments, run `./build.sh`, commit the regenerated `bin/cs` in the SAME commit. Hooks under `hooks/` are standalone (NOT assembled into bin/cs) — hook edits need no rebuild, but Task 3 touches lib/ and does.
- bash 3.2 + BSD userland only: no `local -A`, no `mapfile`, BSD awk/sed/stat/date. Hooks cannot source bin/cs — the jq append recipe is deliberately duplicated between the two writers (documented dual-writer constraint).
- Every assertion in a bash test function needs `|| return 1` (run_test suppresses errexit).
- Hooks must never break their contracts: tool-failure-logger stays silent and non-blocking; scope-prompt must NEVER block a prompt (every error path exits 0); narrative-reminder emits decisions only as JSON via `jq -nc` (task text is arbitrary).
- **File contracts (shared by Tasks 1-4, all under `<session>/.cs/local/`):**
  - `failures` — single integer line; absent or non-numeric reads as 0; writers use atomic tmp+mv; the drain resets it by `rm -f`.
  - `notifications.jsonl` — append-only; one `jq -nc` JSON object per line. Fields: always `ts` (integer epoch) and `event`; `drain_started` adds `queued` (number); `task_done` adds `task` (string); `breaker_tripped` adds `reason` ("failures"|"context"|"five_hour"), `reading` (number), `limit` (number), `remaining` (number); `drain_finished` adds `done` (number); `gate_declined` has no extras.
  - `notifications.seen` — single integer line: count of jsonl lines already auto-surfaced; absent/non-numeric reads as 0. Advanced ONLY by the digest injectors, never by `cs -queue log`.
- Thresholds: `CS_QUEUE_MAX_FAILURES` (default 5), `CS_QUEUE_MAX_CTX` (default 85), `CS_QUEUE_MAX_5H` (default 85); non-numeric overrides fall back to the default. Five-hour freshness window: `stamped_at` within 1800s, else that breaker skips silently.
- Existing behavior is Hyrum-frozen: the gate wording, armed/draining block messages (apart from the new breaker debrief), `cs -queue list` output, and `queue`/`queue.state`/`queue.done`/`queue.declined` semantics are unchanged.
- Test suites: `bash tests/run_all.sh` green before every commit; `cd tui && cargo test` once in the final task (regression only — no Rust changes in this plan).
- Never use foreground `sleep` in tests to wait on anything — these are synchronous hook invocations; no waiting exists in this plan.

---

### Task 1: Per-task failure counter

**Files:**
- Modify: `hooks/tool-failure-logger.sh` (after the session.log append at line 34)
- Create: `tests/test_queue_supervision.sh`

**Interfaces:**
- Consumes: PostToolUseFailure stdin JSON (`.tool_name`, `.error`), `CLAUDE_SESSION_*` env.
- Produces: `.cs/local/failures` per the file contract. Task 2's breaker reads it and resets it with `rm -f`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_queue_supervision.sh` (mode 755):

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for walk-away queue supervision: the failure counter, circuit
# ABOUTME: breakers at the drain choke point, the notification inbox, and digest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + exported ambient env, the shape the hooks expect.
_qs_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
}

_fail_once() {  # simulate one tool failure through the real hook
    echo '{"tool_name":"Bash","error":"boom"}' | bash "$HOOKS_DIR/tool-failure-logger.sh"
}

test_failure_counter_increments() {
    _qs_session "fc"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "first failure counts" || return 1
    _fail_once || return 1
    _fail_once || return 1
    assert_eq "3" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "count accumulates" || return 1
}

test_failure_counter_recovers_from_garbage() {
    _qs_session "fcg"
    printf 'not-a-number\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _fail_once || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/failures")" "garbage reads as 0, then increments" || return 1
}

test_failure_counter_still_logs_to_session_log() {
    _qs_session "fcl"
    _fail_once || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" "existing log behavior preserved" || return 1
}

run_test test_failure_counter_increments
run_test test_failure_counter_recovers_from_garbage
run_test test_failure_counter_still_logs_to_session_log
report_results
```

- [ ] **Step 2: Run to confirm failure**

Run: `chmod +x tests/test_queue_supervision.sh && bash tests/test_queue_supervision.sh`
Expected: FAIL — `failures` file never created (`cat` errors → assert_eq mismatch).

- [ ] **Step 3: Implement**

In `hooks/tool-failure-logger.sh`, after the `echo "[$(date ...)] Tool failure: ..." >> "$LOG_FILE"` line and before `exit 0`:

```bash
# Count failures for the queue circuit breaker. Reset per task by the drain
# (Stop hook); absent or non-numeric reads as 0. Best-effort — this hook
# stays silent and non-blocking no matter what.
{
    FAILS_FILE="$META_DIR/local/failures"
    CUR=$(cat "$FAILS_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$CUR" in ''|*[!0-9]*) CUR=0;; esac
    printf '%s\n' $((CUR + 1)) > "$FAILS_FILE.tmp" && mv "$FAILS_FILE.tmp" "$FAILS_FILE"
} 2>/dev/null || true
```

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_queue_supervision.sh`
Expected: PASS (3/3).

Run: `bash tests/run_all.sh`
Expected: all suites pass (test_hooks.sh's existing tool-failure-logger tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add hooks/tool-failure-logger.sh tests/test_queue_supervision.sh
git commit -m "feat: count tool failures per task for the queue circuit breaker"
```

---

### Task 2: Circuit breakers + inbox writers in the drain

**Files:**
- Modify: `hooks/narrative-reminder.sh` (queue section, lines 38-117)
- Modify: `tests/test_queue_supervision.sh` (append tests)

**Interfaces:**
- Consumes: `failures` (Task 1), `context-pct` and `limits` (existing statusline stamps), queue files, threshold env vars.
- Produces: `notifications.jsonl` events `drain_started` / `task_done` / `breaker_tripped` / `drain_finished` per the file contract; `failures` reset via `rm -f` at arm and at each advance. Task 4 reads the jsonl; Task 3 adds the fifth event elsewhere.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_queue_supervision.sh` (helpers first, then tests; add matching `run_test` lines before `report_results`):

```bash
# Drive one Stop-hook turn end through the real hook. Echo '{}' = main agent.
_stop_turn() {
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh"
}

_arm_queue() {  # tasks...
    local qdir="$CLAUDE_SESSION_META_DIR/local" t
    for t in "$@"; do printf '%s\n' "$t" >> "$qdir/queue"; done
    printf 'armed\n' > "$qdir/queue.state"
}

_inbox() { cat "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl" 2>/dev/null; }

test_drain_writes_lifecycle_events() {
    _qs_session "lc"
    _arm_queue "task one" "task two"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "starting a walk-away run" "armed turn injects first task" || return 1
    assert_output_contains "$(_inbox)" '"event":"drain_started"' "arm records drain_started" || return 1
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "drain advances" || return 1
    assert_output_contains "$(_inbox)" '"event":"task_done"' "advance records task_done" || return 1
    assert_output_contains "$(_inbox)" '"task":"task one"' "task_done carries the task text" || return 1
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "all tasks complete" "drain finishes" || return 1
    assert_output_contains "$(_inbox)" '"event":"drain_finished"' "finish recorded" || return 1
}

test_task_text_with_quotes_survives_jq_append() {
    _qs_session "qq"
    _arm_queue 'fix the "flaky" test `now`' "second"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    _inbox | jq -e 'select(.event == "task_done") | .task == "fix the \"flaky\" test `now`"' >/dev/null \
        || { echo "  FAIL: quoted task text mangled in inbox"; return 1; }
}

test_failures_breaker_parks_the_drain() {
    _qs_session "fb"
    _arm_queue "will fail" "never reached"
    _stop_turn >/dev/null || return 1              # armed -> draining
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "circuit breaker" "debrief names the breaker" || return 1
    assert_output_contains "$out" "failures" "debrief names the reason" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "queue parked" || return 1
    assert_output_contains "$(_inbox)" '"event":"breaker_tripped"' "trip recorded" || return 1
    assert_output_contains "$(_inbox)" '"reason":"failures"' "trip reason recorded" || return 1
    # The remaining task is intact — nothing lost.
    grep -q "never reached" "$CLAUDE_SESSION_META_DIR/local/queue" \
        || { echo "  FAIL: remaining task lost on trip"; return 1; }
}

test_failures_reset_at_arm_and_each_advance() {
    _qs_session "fr"
    printf '4\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _arm_queue "one" "two" "three"
    _stop_turn >/dev/null || return 1              # arm resets stale count
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/failures" ] \
        || { echo "  FAIL: arm should reset the counter"; return 1; }
    printf '3\n' > "$CLAUDE_SESSION_META_DIR/local/failures"   # below threshold
    _stop_turn >/dev/null || return 1              # advance: no trip, reset again
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/failures" ] \
        || { echo "  FAIL: advance should reset the counter"; return 1; }
    assert_eq "draining" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "sub-threshold count does not trip" || return 1
}

test_context_breaker_parks_and_missing_ctx_never_trips() {
    _qs_session "cb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '91\n' > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "context" "context trip named" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "parked" || return 1

    _qs_session "cb2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    rm -f "$CLAUDE_SESSION_META_DIR/local/context-pct"
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "missing context-pct drains on" || return 1
}

test_five_hour_breaker_fresh_trips_stale_skips() {
    _qs_session "hb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 90\nstamped_at: %s\n' "$(date +%s)" \
        > "$CLAUDE_SESSION_META_DIR/local/limits"
    local out
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "five" "fresh over-threshold trips" || return 1
    assert_eq "idle" "$(cat "$CLAUDE_SESSION_META_DIR/local/queue.state")" "parked" || return 1

    _qs_session "hb2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf 'five_hour_used_pct: 90\nstamped_at: %s\n' "$(( $(date +%s) - 3600 ))" \
        > "$CLAUDE_SESSION_META_DIR/local/limits"
    out=$(_stop_turn) || return 1
    assert_output_contains "$out" "next task" "stale stamp skips the breaker" || return 1
    assert_output_not_contains "$(_inbox)" "breaker_tripped" "silent skip: no inbox entry" || return 1
}

test_threshold_env_overrides() {
    _qs_session "ov"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '2\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    local out
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=2 bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "override lowers the threshold" || return 1

    _qs_session "ov2"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '5\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    out=$(echo '{}' | CS_QUEUE_MAX_FAILURES=banana bash "$HOOKS_DIR/narrative-reminder.sh") || return 1
    assert_output_contains "$out" "circuit breaker" "garbage override falls back to default 5" || return 1
}
```

`run_test` lines to add: `test_drain_writes_lifecycle_events`, `test_task_text_with_quotes_survives_jq_append`, `test_failures_breaker_parks_the_drain`, `test_failures_reset_at_arm_and_each_advance`, `test_context_breaker_parks_and_missing_ctx_never_trips`, `test_five_hour_breaker_fresh_trips_stale_skips`, `test_threshold_env_overrides`.

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_queue_supervision.sh`
Expected: the 7 new tests FAIL (no inbox file, no breaker behavior); the 3 Task-1 tests stay green.

- [ ] **Step 3: Implement**

In `hooks/narrative-reminder.sh`, insert helpers after `_qlen()` (line 51):

```bash
# Append one event to the notification inbox. Task text is arbitrary -> jq.
# Best-effort: inbox failure must never break the drain.
_inbox_append() {  # jq --arg/--argjson pairs..., then the jq object program
    jq -nc "$@" >> "$QDIR/notifications.jsonl" 2>/dev/null || true
}

_num_or() {  # value, default -> prints value if a plain integer, else default
    case "${1:-}" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac
}

# Evaluate the circuit breakers. Prints "reason reading limit" and returns 0
# when one trips; returns 1 otherwise. Order: failures, context, five_hour.
_breaker_check() {
    local max_fail max_ctx max_5h fails ctx fiveh stamped now
    max_fail=$(_num_or "${CS_QUEUE_MAX_FAILURES:-}" 5)
    max_ctx=$(_num_or "${CS_QUEUE_MAX_CTX:-}" 85)
    max_5h=$(_num_or "${CS_QUEUE_MAX_5H:-}" 85)

    fails=$(_num_or "$(cat "$QDIR/failures" 2>/dev/null | tr -d '[:space:]')" 0)
    if [ "$fails" -ge "$max_fail" ]; then
        echo "failures $fails $max_fail"
        return 0
    fi

    ctx=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
    case "$ctx" in
        ''|*[!0-9]*) : ;;
        *) if [ "$ctx" -ge "$max_ctx" ]; then
               echo "context $ctx $max_ctx"
               return 0
           fi ;;
    esac

    if [ -f "$QDIR/limits" ]; then
        fiveh=$(awk -F': ' '/^five_hour_used_pct:/ {print $2; exit}' "$QDIR/limits" 2>/dev/null | tr -d '[:space:]')
        stamped=$(awk -F': ' '/^stamped_at:/ {print $2; exit}' "$QDIR/limits" 2>/dev/null | tr -d '[:space:]')
        now=$(date +%s)
        case "$fiveh$stamped" in *[!0-9]*|'') : ;; *)
            if [ $((now - stamped)) -le 1800 ] && [ "$fiveh" -ge "$max_5h" ]; then
                echo "five_hour $fiveh $max_5h"
                return 0
            fi ;;
        esac
    fi
    return 1
}
```

In the **armed branch** (line 58-66), after the `printf 'draining\n' ...` state flip, add:

```bash
        rm -f "$QDIR/failures"
        _inbox_append --arg ts "$(date +%s)" --arg q "$QLEN" \
            '{ts: ($ts|tonumber), event: "drain_started", queued: ($q|tonumber)}'
```

In the **draining branch** (line 68-89), after `printf '%s\n' "$DONE_TASK" >> "$QDIR/queue.done"` add the task_done append:

```bash
            _inbox_append --arg ts "$(date +%s)" --arg task "$DONE_TASK" \
                '{ts: ($ts|tonumber), event: "task_done", task: $task}'
```

After the `NEWLEN` computation, extend the empty case's block (before its `jq -nc` emit) with:

```bash
                DONE_COUNT=$(_qlen "$QDIR/queue.done")
                _inbox_append --arg ts "$(date +%s)" --arg d "$DONE_COUNT" \
                    '{ts: ($ts|tonumber), event: "drain_finished", done: ($d|tonumber)}'
                rm -f "$QDIR/failures"
```

Then, in the non-empty path, BEFORE computing `NEXT` and injecting it, insert the breaker gate:

```bash
            if TRIP=$(_breaker_check); then
                set -- $TRIP
                REASON_KIND="$1"; READING="$2"; LIMIT="$3"
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                _inbox_append --arg ts "$(date +%s)" --arg r "$REASON_KIND" \
                    --arg v "$READING" --arg l "$LIMIT" --arg n "$NEWLEN" \
                    '{ts: ($ts|tonumber), event: "breaker_tripped", reason: $r, reading: ($v|tonumber), limit: ($l|tonumber), remaining: ($n|tonumber)}'
                rm -f "$QDIR/failures"
                REASON="cs task queue: circuit breaker tripped — $REASON_KIND at $READING (threshold $LIMIT). The queue is parked with $NEWLEN task(s) remaining; nothing was lost. Summarize the walk-away run so far and anything that needs the user's attention. They can re-arm with: cs -queue start."
                jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
                exit 0
            fi
            rm -f "$QDIR/failures"
```

(the existing `NEXT=$(awk ...)` / block emission follows unchanged).

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_queue_supervision.sh`
Expected: PASS (10/10).

Run: `bash tests/run_all.sh`
Expected: all suites pass — test_hooks.sh's existing queue-drain tests must stay green (the drain's message shapes are unchanged apart from the new debrief path).

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_queue_supervision.sh
git commit -m "feat: circuit breakers park a bad drain; inbox records drain lifecycle"
```

---

### Task 3: gate_declined writer + cs -queue log

**Files:**
- Modify: `lib/55-queue.sh` (defer arm, new `log` subcommand, usage string)
- Modify: `completions/_cs` (queue_cmds gains `log`)
- Modify: `completions/cs.bash` (queue_cmds gains `log`)
- Modify: `lib/10-help.sh` (queue help lines gain `-queue log`)
- Modify: `tests/test_queue_supervision.sh` (append tests)
- Modify: `bin/cs` (regenerated)

**Interfaces:**
- Consumes: `notifications.jsonl` file contract.
- Produces: `gate_declined` event; `cs -queue log` (oldest-first pretty print; empty message `No queue activity recorded.`; never touches `notifications.seen`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_queue_supervision.sh` (plus `run_test` lines):

```bash
test_defer_records_gate_declined() {
    _qs_session "gd"
    "$CS_BIN" -queue defer >/dev/null 2>&1 || { echo "  FAIL: defer exited non-zero"; return 1; }
    assert_output_contains "$(_inbox)" '"event":"gate_declined"' "defer writes the event" || return 1
    [ -f "$CLAUDE_SESSION_META_DIR/local/queue.declined" ] \
        || { echo "  FAIL: existing declined stamp must still be written"; return 1; }
}

test_queue_log_prints_events_oldest_first() {
    _qs_session "ql"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    local out
    out=$("$CS_BIN" -queue log 2>&1) || { echo "  FAIL: log exited non-zero"; return 1; }
    assert_output_contains "$out" "drain_started" "log shows the start" || return 1
    assert_output_contains "$out" "task_done" "log shows the task" || return 1
    assert_output_contains "$out" "only task" "log shows the task text" || return 1
    assert_output_contains "$out" "drain_finished" "log shows the finish" || return 1
    # oldest first: drain_started line appears before drain_finished line
    printf '%s\n' "$out" | awk '/drain_started/{s=NR} /drain_finished/{f=NR} END{exit !(s && f && s < f)}' \
        || { echo "  FAIL: log must print oldest-first"; return 1; }
    # log never advances the surfacing cursor
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/notifications.seen" ] \
        || { echo "  FAIL: log must not touch the cursor"; return 1; }
}

test_queue_log_empty_message() {
    _qs_session "qle"
    local out
    out=$("$CS_BIN" -queue log 2>&1) || return 1
    assert_output_contains "$out" "No queue activity recorded." "empty inbox message" || return 1
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_queue_supervision.sh`
Expected: the 3 new tests FAIL (`log` hits the usage error; defer writes no event).

- [ ] **Step 3: Implement**

In `lib/55-queue.sh`, add after `_queue_clear`:

```bash
_queue_log() {  # qdir
    local inbox="$1/notifications.jsonl"
    if [ ! -s "$inbox" ]; then
        echo "No queue activity recorded."
        return 0
    fi
    # Tolerant per-line parse (torn lines skipped); oldest-first is file order.
    jq -rR '
        fromjson? // empty |
        (.ts | strftime("%Y-%m-%d %H:%M")) + "  " + .event +
        (if .task then ": " + .task
         elif .reason then ": " + .reason + " (" + (.reading|tostring) + " >= " + (.limit|tostring) + "), " + (.remaining|tostring) + " remaining"
         elif .done then ": " + (.done|tostring) + " done"
         else "" end)
    ' "$inbox"
}
```

Replace the `defer` arm and usage line in `run_queue`:

```bash
        defer) mkdir -p "$qdir"; printf '%s\n' "$(date +%s)" > "$qdir/queue.declined.tmp" \
                   && mv "$qdir/queue.declined.tmp" "$qdir/queue.declined"
               jq -nc --arg ts "$(date +%s)" '{ts: ($ts|tonumber), event: "gate_declined"}' \
                   >> "$qdir/notifications.jsonl" 2>/dev/null || true;;
        log)   _queue_log "$qdir";;
        *)     error "Usage: cs -queue [add \"<task>\" | list | rm <n> | clear | log]";;
```

In `completions/_cs`, the `queue_cmds` array gains:

```zsh
        'log:Show the walk-away run journal (drains, breaker trips)'
```

In `completions/cs.bash`: `queue_cmds="add list ls rm clear start defer log"`.

In `lib/10-help.sh`, after the `-queue clear` line add:

```
  -queue log          Show the walk-away run journal (drains, breaker trips)
```

- [ ] **Step 4: Build, run, verify**

Run: `./build.sh && bash tests/test_queue_supervision.sh && bash tests/run_all.sh`
Expected: all PASS (test_queue.sh's existing subcommand tests unaffected; completions drift guard sees `log`).

- [ ] **Step 5: Commit**

```bash
git add lib/55-queue.sh lib/10-help.sh completions/_cs completions/cs.bash tests/test_queue_supervision.sh bin/cs
git commit -m "feat: cs -queue log journal reader; defer records gate_declined"
```

---

### Task 4: Surface-once digest at prompt and session start

**Files:**
- Modify: `hooks/scope-prompt.sh` (digest block + `_digest_exit` at the five early exits + final splice)
- Modify: `hooks/session-start.sh` (append digest to CONTEXT before the final jq)
- Modify: `tests/test_queue_supervision.sh` (append tests)

**Interfaces:**
- Consumes: `notifications.jsonl`, `notifications.seen` file contracts.
- Produces: the digest string (one line, `cs queue while you were away: ...`), cursor advancement. Digest fires only when unseen entries include at least one of task_done / breaker_tripped / drain_finished (gate_declined/drain_started alone advance the cursor silently — the user was present for those).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_queue_supervision.sh` (plus `run_test` lines):

```bash
_prompt_turn() {  # prompt-text -> hook stdout
    printf '{"prompt": "%s"}' "$1" | bash "$HOOKS_DIR/scope-prompt.sh"
}

test_digest_surfaces_once_at_prompt() {
    _qs_session "dg"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1              # drain finishes: 3 events queued
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_contains "$out" "while you were away" "digest injected" || return 1
    assert_output_contains "$out" "1 task(s) done" "digest counts tasks" || return 1
    out=$(_prompt_turn "hello again") || return 1
    assert_output_not_contains "$out" "while you were away" "second prompt injects nothing" || return 1
}

test_digest_includes_breaker_reason() {
    _qs_session "dgb"
    _arm_queue "a" "b"
    _stop_turn >/dev/null || return 1
    printf '9\n' > "$CLAUDE_SESSION_META_DIR/local/failures"
    _stop_turn >/dev/null || return 1              # trips
    local out
    out=$(_prompt_turn "hi") || return 1
    assert_output_contains "$out" "breaker tripped: failures" "digest names the trip" || return 1
}

test_declined_only_inbox_stays_silent_but_cursor_advances() {
    _qs_session "dgs"
    "$CS_BIN" -queue defer >/dev/null 2>&1 || return 1
    local out
    out=$(_prompt_turn "hello") || return 1
    assert_output_not_contains "$out" "while you were away" "decline alone is not digest-worthy" || return 1
    assert_eq "1" "$(cat "$CLAUDE_SESSION_META_DIR/local/notifications.seen")" "cursor still advanced" || return 1
}

test_digest_on_code_prompt_splices_with_scope_block() {
    _qs_session "dgc"
    # A real git repo with a token-matching file so scope grounding has
    # something to inject (the splice needs both payloads present).
    (cd "$CLAUDE_SESSION_DIR" && git init -q && echo x > login.ts \
        && git add login.ts && git commit -qm init) 2>/dev/null
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    # A prompt that classifies positive for scope grounding (work verb).
    local out
    out=$(_prompt_turn "fix the login bug") || return 1
    assert_output_contains "$out" "while you were away" "digest present on code prompts" || return 1
    assert_output_contains "$out" "Scope (auto-grounded)" "scope block still present (spliced, not replaced)" || return 1
}

test_digest_at_session_start() {
    _qs_session "dgr"
    _arm_queue "only task"
    _stop_turn >/dev/null || return 1
    _stop_turn >/dev/null || return 1
    local out
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_contains "$out" "while you were away" "resume surfaces the digest" || return 1
    out=$(printf '{"source":"resume","session_id":"s1","cwd":"%s"}' "$CLAUDE_SESSION_DIR" \
        | bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_not_contains "$out" "while you were away" "second start injects nothing" || return 1
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_queue_supervision.sh`
Expected: the 5 new tests FAIL (no digest anywhere).

- [ ] **Step 3: Implement**

**Shared digest recipe** (duplicated in both hooks by the standalone-hook constraint; the jq program is the shared contract):

```bash
# Build the surface-once digest from unseen inbox lines. Sets DIGEST (may be
# empty) and, when there were unseen lines, advances the cursor — surfacing is
# at-most-once even when the digest itself is empty (decline-only content).
_build_digest() {  # meta_local_dir
    local qdir="$1" inbox seen total
    DIGEST=""
    inbox="$qdir/notifications.jsonl"
    [ -s "$inbox" ] || return 0
    total=$(grep -c '' "$inbox" 2>/dev/null) || return 0
    seen=$(cat "$qdir/notifications.seen" 2>/dev/null | tr -d '[:space:]')
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    [ "$total" -gt "$seen" ] || return 0
    DIGEST=$(tail -n +$((seen + 1)) "$inbox" 2>/dev/null | jq -rRs '
        [split("\n")[] | select(length > 0) | (fromjson? // empty)] as $e |
        ($e | map(select(.event == "task_done")) | length) as $done |
        ($e | map(select(.event == "breaker_tripped")) | .[-1]) as $trip |
        ($e | map(select(.event == "drain_finished")) | length) as $fin |
        if ($done + $fin) == 0 and $trip == null then "" else
            "cs queue while you were away: \($done) task(s) done" +
            (if $trip != null then "; breaker tripped: \($trip.reason) (\($trip.reading) >= \($trip.limit)), \($trip.remaining) remaining" else "" end) +
            (if $fin > 0 then "; drain finished" else "" end) +
            ". Run cs -queue log for detail."
        end' 2>/dev/null) || DIGEST=""
    printf '%s\n' "$total" > "$qdir/notifications.seen.tmp" 2>/dev/null \
        && mv "$qdir/notifications.seen.tmp" "$qdir/notifications.seen" 2>/dev/null || true
}
```

**hooks/scope-prompt.sh**: insert the helper plus this block immediately after the `PROMPT=$(...)` line (line 22):

```bash
# --- Queue inbox digest (surface-once) ---
DIGEST=""
[ -n "${CLAUDE_SESSION_META_DIR:-}" ] && _build_digest "$CLAUDE_SESSION_META_DIR/local"

# Every pass-through exit below this point must still deliver a pending
# digest; a digest-only prompt turn emits just the digest as context.
_digest_exit() {
    if [ -n "$DIGEST" ]; then
        jq -n --arg c "$DIGEST" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    fi
    exit 0
}
```

Then replace the five later pass-through exits with `_digest_exit`:
- line 64: `[ "${CS_SCOPE_DISABLE:-}" = "1" ] && _digest_exit`
- line 67: `[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || _digest_exit`
- line 69: `[ -n "$PROMPT" ] || _digest_exit`
- lines 84 and 90 (negative classification): `_digest_exit   # negative classification: silent pass-through`

And splice into the final emission (line ~225): immediately before the final `jq -n --arg c "$BLOCK" ...`, add:

```bash
if [ -n "$DIGEST" ]; then
    BLOCK="$DIGEST

$BLOCK"
fi
```

(The three exits at lines 11/21/22 stay plain `exit 0` — they run before the digest is built.)

**hooks/session-start.sh**: add the same `_build_digest` helper after `META_DIR` is established (line 29), and immediately before the final `jq -n --arg context "$CONTEXT" ...` emission, add:

```bash
# Queue inbox digest (surface-once; same recipe as scope-prompt.sh).
DIGEST=""
_build_digest "$META_DIR/local"
if [ -n "$DIGEST" ]; then
    CONTEXT="${CONTEXT}

--- $DIGEST"
fi
```

(`META_DIR` is set unconditionally at session-start.sh:29 and `CONTEXT` via the heredoc at :110, so both are defined on every path that reaches the final emission.)

- [ ] **Step 4: Run to verify green**

Run: `bash tests/test_queue_supervision.sh`
Expected: PASS (18/18).

Run: `bash tests/run_all.sh`
Expected: all suites pass — scope-prompt's existing objective-capture and scope tests and session-start's tests must stay green (digest is additive; with an empty inbox every path behaves exactly as before).

- [ ] **Step 5: Commit**

```bash
git add hooks/scope-prompt.sh hooks/session-start.sh tests/test_queue_supervision.sh
git commit -m "feat: surface unseen queue notifications once at prompt or session start"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` (features list + command reference)
- Modify: `docs/hooks.md` (narrative-reminder, tool-failure-logger, scope-prompt, session-start entries)

**Interfaces:**
- Consumes: the shipped surface from Tasks 1-4. No code.

- [ ] **Step 1: Document**

README features list, after the walk-away queue bullet (or the Session archive bullet if the queue has none), add:

```markdown
- **Walk-away supervision** - a draining queue is watched by circuit breakers: too many tool failures in one task (default 5, `CS_QUEUE_MAX_FAILURES`), context past 85% (`CS_QUEUE_MAX_CTX`), or the 5-hour rate-limit window past 85% (`CS_QUEUE_MAX_5H`) parks the queue with a debrief instead of feeding the next task — nothing is lost, `cs -queue start` re-arms. Everything that happened while you were away (tasks done, breaker trips) lands in a per-machine journal: a one-line digest surfaces once on your return, and `cs -queue log` shows the full history.
```

README command reference, after the `cs -queue clear` line:

```
cs -queue log               # Walk-away run journal (tasks done, breaker trips)
```

docs/hooks.md: extend the narrative-reminder entry with the breaker behavior (three tripwires, thresholds + env overrides, park + debrief, per-task failure reset), the tool-failure-logger entry with the `failures` counter, and the scope-prompt/session-start entries with the surface-once digest. Match the file's existing entry style — read it first; keep each addition to 2-4 sentences.

- [ ] **Step 2: Verify and commit**

Run: `bash tests/run_all.sh && cd tui && cargo test`
Expected: all suites pass; cargo 247/247 (regression only — no Rust changes on this branch).

```bash
git add README.md docs/hooks.md
git commit -m "docs: document queue circuit breakers, inbox, and cs -queue log"
```

---

## Self-Review Notes

- Spec coverage: failure counter (T1), three breakers + trip action + resets + four inbox writers (T2), gate_declined + `cs -queue log` + completions/help (T3), surface-once digest at both injection points with splice semantics (T4), README/docs (T5). Spec tests 1-8 map to T1 (1), T2 (2-6), T3 (8 partial: log + drift guard), T4 (7), with the help mention riding run_all's help test.
- The spec's "digest appends to existing additionalContext rather than replacing" is honored: code-work prompts splice DIGEST above BLOCK; pass-through prompts (which today emit nothing) emit digest-only JSON — additive in both cases, nothing replaced.
- Type consistency: `_inbox_append` takes jq arg pairs + program; both writers (hook, lib) append the same field shapes as the Global Constraints contract; `_build_digest` is duplicated verbatim in two hooks by the standalone constraint, and its jq program is the single shared recipe.
- Known judgment calls encoded: cursor advances even when the digest is empty (decline-only content) — surfacing is at-most-once by design; `grep -c ''` counts lines including a torn last line, matching `tail -n +N` line addressing.
