# Conversation Rotation + Handoff Lineage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make conversation lineage durable (a `rotated` timeline event + `cs -conversations` view) and rotation first-class (a `rotate` skill writing lineage-stamped handoffs to tracked `.cs/handoffs/`, a three-way launch prompt that consumes them, and a once-per-conversation context nudge).

**Architecture:** Every rotation — implicit (CC forks a UUID at the context limit, user declines resume, resume fails) or deliberate (handoff handshake) — lands as one `rotated` event in the existing tracked `timeline.jsonl`. Two emitters, each recording what it knows first-hand: `_exec_fresh_rebind` in bin/cs (it makes launch-side rebind decisions) and hooks/session-start.sh (it discovers CC-initiated UUID changes). The deliberate flow is a handshake: the `rotate` skill writes the handoff while the old conversation is alive; the next launch offers `r`; SessionStart injects and consumes.

**Tech Stack:** bash 3.2 + BSD userland, jq, existing cs test harness (tests/test_lib.sh).

**Spec:** docs/superpowers/specs/2026-07-16-conversation-rotation-design.md — read it if a requirement here seems ambiguous; the spec governs.

## Global Constraints

- bash 3.2 + BSD only: no `local -A`, no `mapfile`, no `source <()`, no GNU-only sed/awk/stat flags. CI runs the whole suite under stock /bin/bash 3.2.
- `bin/cs` is GENERATED from `lib/` by `./build.sh`. Every task: edit `lib/`, run `./build.sh`, THEN run tests (tests execute `bin/cs`), and commit `bin/cs` in the SAME commit as the `lib/` change.
- Every test assertion line ends with `|| return 1` (the harness disables errexit inside tests).
- Dispatch case arms in lib/99-main.sh use exactly 8-space indentation (tests/test_completions.sh extracts them by that indent).
- A new verb registers in BOTH completion files: completions/_cs AND completions/cs.bash.
- lib/10-help.sh's show_help is an unquoted heredoc: NO backticks anywhere in help text.
- Hooks are standalone scripts that cannot source bin/cs; the `rotated` jq append recipe is therefore duplicated between lib/40-state.sh and hooks/session-start.sh by necessity. The shared contract, verbatim: `{ts: <ISO-8601 UTC>, event: "rotated", from: <old-uuid-or-"">, to: <new-uuid>, reason: "handoff"|"declined-resume"|"resume-failed"|"rebind"}` plus `handoff: <basename>` only when reason is `handoff`.
- Timeline appends are best-effort (`2>/dev/null || true`): a timeline failure must never break a launch or a hook.
- hooks/session-start.sh gates on `UUID_RE` — every test session UUID must be a full UUID-shaped string (e.g. `11111111-1111-4111-8111-111111111111`), never a short token like `uuid-1`.
- The existing two-way prompt string `Continue previous conversation? [Y/n] ` is byte-frozen when no unconsumed handoff exists.
- No TUI changes; `cd tui && cargo test` runs as regression only.

## File Structure

- `lib/40-state.sh` — `_timeline_rotated` helper + `_exec_fresh_rebind` reason/handoff args (modify)
- `lib/75-launch.sh` — three-way prompt + caller reasons (modify)
- `hooks/session-start.sh` — rebind event + handoff consumption (modify)
- `hooks/narrative-reminder.sh` — context nudge (modify)
- `skills/rotate/SKILL.md` — the rotate skill (create)
- `lib/00-header.sh`, `install.sh` — CS_SKILLS registration (modify)
- `lib/35-claudemd.sh` — session CLAUDE.md template mention (modify)
- `lib/54-conversations.sh` — `run_conversations` (create)
- `lib/99-main.sh`, `lib/10-help.sh`, `completions/_cs`, `completions/cs.bash` — verb wiring (modify)
- `README.md`, `docs/session-layout.md`, `docs/hooks.md` — docs (modify)
- `tests/test_rotation.sh` — the suite, grown task by task (create)

---

### Task 1: The `rotated` event — emitters in `_exec_fresh_rebind` and session-start.sh

**Files:**
- Modify: `lib/40-state.sh` (function `_exec_fresh_rebind`, ~line 101; add `_timeline_rotated` above it)
- Modify: `lib/75-launch.sh:191` and `lib/75-launch.sh:208` (the two `_exec_fresh_rebind` callers)
- Modify: `hooks/session-start.sh:179-185` (the rebind branch)
- Create: `tests/test_rotation.sh`

**Interfaces:**
- Consumes: `_read_local_state`/`_set_local_state` (lib/40-state.sh), `TIMELINE_FILE` (session-start.sh:73), the `jq -nc ... >> timeline 2>/dev/null || true` pattern (lib/50-checkpoint.sh:80-86).
- Produces: `_timeline_rotated SESSION_DIR FROM TO REASON [HANDOFF]` (later tasks call `_exec_fresh_rebind "$session_dir" handoff "<basename>"`); the `rotated` event shape from Global Constraints, which Task 6's view parses.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_rotation.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for conversation rotation: the rotated timeline event, the
# ABOUTME: handoff handshake (prompt, consumption), the context nudge, and cs -conversations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

UUID_A="11111111-1111-4111-8111-111111111111"
UUID_B="22222222-2222-4222-8222-222222222222"

# Args-echoing claude stub; exits 1 on --resume when $1 = fail-resume.
_stub_claude() {  # [fail-resume]
    local mode="${1:-}"
    if [ "$mode" = "fail-resume" ]; then
        cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
case "$*" in *--resume*) exit 1;; esac
echo "STUB_ARGS: $*"
exit 0
SCRIPT
    else
        cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
echo "STUB_ARGS: $*"
exit 0
SCRIPT
    fi
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

# Create a real session via cs itself (is_new=true launches without a prompt;
# the stub exits immediately). Returns nothing; the dir is $CS_SESSIONS_ROOT/$1.
_rot_session() {  # name
    _stub_claude
    "$CS_BIN" "$1" </dev/null >/dev/null 2>&1 || true
}

# Ambient env + session dir for driving hooks directly (no cs launch).
_rot_hook_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
}

_timeline() { cat "$CLAUDE_SESSION_META_DIR/timeline.jsonl" 2>/dev/null; }

# ============================================================================
# Cycle 1: rotated event emission
# ============================================================================

test_hook_mismatch_emits_rebind_event() {
    _rot_hook_session "rot-hook"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    echo "{\"session_id\":\"$UUID_B\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"resume\"}" \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null)
    [ -n "$ev" ] || { echo "  FAIL: no rotated event emitted"; return 1; }
    assert_output_contains "$ev" "\"from\":\"$UUID_A\"" "event carries the old UUID" || return 1
    assert_output_contains "$ev" "\"to\":\"$UUID_B\"" "event carries the new UUID" || return 1
    assert_output_contains "$ev" '"reason":"rebind"' "hook-discovered change is a rebind" || return 1
}

test_hook_matching_uuid_emits_nothing() {
    _rot_hook_session "rot-hook-same"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    echo "{\"session_id\":\"$UUID_A\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"resume\"}" \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    local n
    n=$(_timeline | grep -c '"event":"rotated"' 2>/dev/null || true)
    assert_eq "0" "$n" "matching UUIDs must not emit a rotated event" || return 1
}

test_decline_resume_emits_declined_event() {
    _rot_session "rot-decline"
    local dir="$CS_SESSIONS_ROOT/rot-decline"
    local old
    old=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    "$CS_BIN" rot-decline <<< "n" >/dev/null 2>&1 || true
    local new
    new=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    [ "$new" != "$old" ] || { echo "  FAIL: decline did not rebind"; return 1; }
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"declined-resume"' "decline reason recorded" || return 1
    assert_output_contains "$ev" "\"from\":\"$old\"" "old UUID recorded" || return 1
    assert_output_contains "$ev" "\"to\":\"$new\"" "new UUID recorded" || return 1
}

test_resume_failure_emits_resume_failed_event() {
    _rot_session "rot-fail"
    local dir="$CS_SESSIONS_ROOT/rot-fail"
    _stub_claude fail-resume
    "$CS_BIN" rot-fail <<< "" >/dev/null 2>&1 || true
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"resume-failed"' "fast resume failure recorded" || return 1
}

run_test test_hook_mismatch_emits_rebind_event
run_test test_hook_matching_uuid_emits_nothing
run_test test_decline_resume_emits_declined_event
run_test test_resume_failure_emits_resume_failed_event

report_results
```

Convention for every later task: `report_results` stays the file's LAST line; each cycle's tests and `run_test` lines insert ABOVE it. (The harness runs setup/teardown around each `run_test`, so every test gets a fresh `$CS_SESSIONS_ROOT` and must create its own session/fixtures.)

- [ ] **Step 2: Run to verify failure**

Run: `./build.sh && bash tests/test_rotation.sh`
Expected: all four FAIL (no rotated events are emitted anywhere yet).

- [ ] **Step 3: Implement the emitters**

In `lib/40-state.sh`, insert above `_exec_fresh_rebind`:

```bash
# Append a rotated event to the tracked timeline: the durable link between
# the conversation being left and the one about to start. Shape shared with
# hooks/session-start.sh's rebind emitter (hooks cannot source bin/cs).
# Best-effort — a timeline failure must never break a launch.
_timeline_rotated() {  # session_dir, from, to, reason, [handoff]
    local session_dir="$1" from="$2" to="$3" reason="$4" handoff="${5:-}"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg from "$from" \
           --arg to "$to" \
           --arg reason "$reason" \
           --arg handoff "$handoff" \
           '{ts: $ts, event: "rotated", from: $from, to: $to, reason: $reason}
            + (if $handoff == "" then {} else {handoff: $handoff} end)' \
        >> "$session_dir/.cs/timeline.jsonl" 2>/dev/null || true
}
```

Change `_exec_fresh_rebind`'s head (keep everything from `local session_color` down unchanged):

```bash
_exec_fresh_rebind() {
    local session_dir="$1"
    local reason="${2:-declined-resume}"
    local handoff="${3:-}"
    local session_name
    session_name=$(basename "$session_dir")
    local old_uuid
    old_uuid=$(_read_local_state "$session_dir/.cs/local/state" claude_session_id)
    local new_uuid
    new_uuid=$(_alloc_uuid)
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$new_uuid"
    _timeline_rotated "$session_dir" "$old_uuid" "$new_uuid" "$reason" "$handoff"
```

Update the two callers in `lib/75-launch.sh`:
- Line 191 (the <3s resume-failure fallback): `_exec_fresh_rebind "$session_dir" resume-failed`
- Line 208 (the declined-resume fresh-spawn branch): `_exec_fresh_rebind "$session_dir" declined-resume`

In `hooks/session-start.sh`, extend the rebind branch (after the existing session.log echo at :183):

```bash
    if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then
        local_state_set claude_session_id "$SESSION_ID"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Rebound claude_session_id: ${RECORDED_UUID:-none} -> $SESSION_ID" >> "$META_DIR/local/session.log"
        # Durable lineage: a UUID change the launch path did not pre-record is
        # a rotation cs discovered (CC's context-limit fork, or a manual
        # resume of a different conversation). Shape shared with bin/cs's
        # _timeline_rotated.
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --arg from "${RECORDED_UUID:-}" \
               --arg to "$SESSION_ID" \
               '{ts: $ts, event: "rotated", from: $from, to: $to, reason: "rebind"}' \
            >> "$TIMELINE_FILE" 2>/dev/null || true
    fi
```

- [ ] **Step 4: Build and run to green**

Run: `./build.sh && bash tests/test_rotation.sh`
Expected: 4/4 PASS. Also run `bash tests/test_uuid.sh` and `bash tests/test_local_state.sh` (nearest neighbors to the changed function).

- [ ] **Step 5: Commit**

```bash
git add lib/40-state.sh lib/75-launch.sh hooks/session-start.sh tests/test_rotation.sh bin/cs
git commit -m "feat: rotated timeline event from launch rebinds and hook-discovered UUID changes"
```

---

### Task 2: The `rotate` skill + registration

**Files:**
- Create: `skills/rotate/SKILL.md`
- Modify: `lib/00-header.sh:69-72` (CS_SKILLS array)
- Modify: `install.sh:126-129` (CS_SKILLS array)
- Modify: `lib/35-claudemd.sh` (one line after the Wrap-up Command paragraph)
- Test: `tests/test_rotation.sh` (append), plus run `tests/test_commands.sh`, `tests/test_install.sh`, `tests/test_migrate_claude_md.sh` for regressions

**Interfaces:**
- Consumes: the CS_SKILLS deploy loop (install.sh:350-375, lib/85-adopt-uninstall.sh:259, lib/60-doctor.sh:82) — registration is array-append only.
- Produces: the handoff file contract Task 3 greps and Task 4 flips: frontmatter lines `parent:`, `created:`, `purpose:`, `status: unconsumed` between `---` fences, in `.cs/handoffs/YYYY-MM-DD-<slug>.md`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_rotation.sh` (before the `run_test` block, then register; keep all run_test lines together at the end of each cycle):

```bash
# ============================================================================
# Cycle 2: the rotate skill ships and is registered
# ============================================================================

test_rotate_skill_exists_with_frontmatter() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    [ -f "$skill" ] || { echo "  FAIL: skills/rotate/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$skill")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$skill" "name: rotate" "frontmatter names the skill" || return 1
    assert_file_contains "$skill" "description:" "frontmatter has a description" || return 1
    assert_file_contains "$skill" "status: unconsumed" "skill teaches the frontmatter contract" || return 1
    assert_file_contains "$skill" ".cs/handoffs/" "skill targets the tracked handoff store" || return 1
}

test_rotate_skill_registered_in_both_manifests() {
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../lib/00-header.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from lib/00-header.sh CS_SKILLS"; return 1; }
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../install.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from install.sh CS_SKILLS"; return 1; }
}

run_test test_rotate_skill_exists_with_frontmatter
run_test test_rotate_skill_registered_in_both_manifests
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_rotation.sh` — the two new tests FAIL.

- [ ] **Step 3: Create the skill and register it**

`skills/rotate/SKILL.md`:

```markdown
---
name: rotate
description: Rotate the current cs conversation - write a lineage-stamped handoff to .cs/handoffs/ so the user can continue in a fresh conversation with context. Invoke when the user asks to rotate, or accepts a context-heavy rotation suggestion.
---

Rotation ends this conversation's useful life deliberately: you distill the
work into a handoff file, and the next `cs` launch offers the user a fresh
conversation seeded with it. This skill only WRITES the handoff — it never
ends the conversation, never edits .cs/local/state, and never launches
anything.

## Prerequisites

Only works in a cs session: check that `$CLAUDE_SESSION_NAME` is set. If
empty, tell the user rotation needs a cs session and stop.

A rotation needs a purpose — one line describing what the next conversation
should do. If the user did not give one, ask before writing anything.

## Process

1. Determine the parent conversation UUID: `$CS_CLAUDE_SESSION_ID`, or if
   unset, the `claude_session_id` line of `.cs/local/state`.
2. Pick a short kebab-case slug from the purpose (e.g. `continue-f5-plan`).
3. Write `.cs/handoffs/YYYY-MM-DD-<slug>.md` (today's date; create the
   directory if missing) with EXACTLY this frontmatter, then the body:

   ```
   ---
   parent: <parent-uuid>
   created: <ISO-8601 UTC timestamp>
   purpose: <the one-line purpose>
   status: unconsumed
   ---
   ```

   The body is a continuation plan with these sections, distilled from the
   live conversation: 1. Primary Request and Intent; 2. Key Technical
   Concepts; 3. Files and Code Sections (with the snippets that matter);
   4. Problem Solving; 5. Pending Tasks; 6. Current Work; 7. Next Step.
   Write for a successor with zero conversation memory.
4. Commit the handoff (it is tracked session state, like narratives).
5. Tell the user: exit this conversation, run `cs <session-name>`, and
   answer `r` at the "Continue previous conversation?" prompt to start
   fresh from this handoff. Until then the handoff stays pending; answering
   `Y` keeps this conversation resumable and the handoff waits.
```

`lib/00-header.sh` — add to the array:

```bash
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
)
```

`install.sh` — same three-line array gains `rotate` identically.

`lib/35-claudemd.sh` — locate the Wrap-up Command paragraph (the line beginning `When the session is complete, use the `/wrap` command`) and add this as a new paragraph directly after it, inside the same section:

```
When a conversation's context grows heavy or a work phase completes, invoke the `rotate` skill: it writes a handoff to .cs/handoffs/ so the user can reopen the session and answer `r` for a fresh conversation that continues from it. `cs -conversations` shows the session's conversation chain.
```

(Template-only change: newly created/adopted sessions get it; existing sessions learn the skill name from the Task 5 nudge instead. If test_migrate_claude_md.sh pins the template body and fails, update its expected text to match — that is the test tracking the template, not a behavior break.)

- [ ] **Step 4: Run to green**

Run: `./build.sh && bash tests/test_rotation.sh && bash tests/test_commands.sh && bash tests/test_install.sh && bash tests/test_migrate_claude_md.sh && bash tests/test_doctor.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/rotate/SKILL.md lib/00-header.sh install.sh lib/35-claudemd.sh tests/test_rotation.sh bin/cs
git commit -m "feat: rotate skill writes lineage-stamped handoffs to .cs/handoffs/"
```

---

### Task 3: The three-way launch prompt

**Files:**
- Modify: `lib/75-launch.sh:153-175` (the Continue prompt block)
- Test: `tests/test_rotation.sh` (append)

**Interfaces:**
- Consumes: `_exec_fresh_rebind SESSION_DIR handoff BASENAME` (Task 1); the handoff frontmatter contract (`status: unconsumed`) from Task 2.
- Produces: `.cs/local/pending-handoff` containing the chosen basename — Task 4's hook consumes it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_rotation.sh`:

```bash
# ============================================================================
# Cycle 3: three-way launch prompt
# ============================================================================

_seed_handoff() {  # session_dir, basename, status
    mkdir -p "$1/.cs/handoffs"
    cat > "$1/.cs/handoffs/$2" << EOF
---
parent: $UUID_A
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: $3
---

## 7. Next Step
Continue the test.
EOF
}

test_prompt_unchanged_without_handoff() {
    _rot_session "rot-plain"
    local output
    output=$("$CS_BIN" rot-plain <<< "n" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "prompt present" || return 1
    printf '%s' "$output" | grep -q '\[Y/n\] ' \
        || { echo "  FAIL: two-way prompt suffix must stay byte-identical"; return 1; }
    if printf '%s' "$output" | grep -q '\[Y/n/r\]'; then
        echo "  FAIL: three-way prompt must not appear without a pending handoff"
        return 1
    fi
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: pending notice must not appear without a pending handoff"
        return 1
    fi
}

test_rotate_answer_consumes_pending_handoff() {
    _rot_session "rot-r"
    local dir="$CS_SESSIONS_ROOT/rot-r"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    local old
    old=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    local output
    output=$("$CS_BIN" rot-r <<< "r" 2>&1) || true
    assert_output_contains "$output" "Rotation handoff pending" "notice names the pending handoff" || return 1
    assert_output_contains "$output" "2026-07-16-test.md" "notice carries the basename" || return 1
    assert_output_contains "$output" "[Y/n/r]" "prompt is three-way" || return 1
    local new
    new=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    [ "$new" != "$old" ] || { echo "  FAIL: r must rebind to a fresh UUID"; return 1; }
    assert_eq "2026-07-16-test.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "marker names the handoff for the SessionStart hook" || return 1
    assert_output_contains "$output" "STUB_ARGS: " "stub launched" || return 1
    assert_output_contains "$output" "--session-id $new" "fresh conversation via --session-id" || return 1
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"handoff"' "deliberate rotation reason" || return 1
    assert_output_contains "$ev" '"handoff":"2026-07-16-test.md"' "event names the handoff" || return 1
}

test_continue_and_no_leave_handoff_unconsumed() {
    _rot_session "rot-yn"
    local dir="$CS_SESSIONS_ROOT/rot-yn"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    "$CS_BIN" rot-yn <<< "n" >/dev/null 2>&1 || true
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: unconsumed" \
        "n leaves the handoff pending" || return 1
    [ ! -f "$dir/.cs/local/pending-handoff" ] || { echo "  FAIL: n must not set the marker"; return 1; }
}

test_consumed_handoffs_do_not_trigger_prompt() {
    _rot_session "rot-consumed"
    local dir="$CS_SESSIONS_ROOT/rot-consumed"
    _seed_handoff "$dir" "2026-07-16-done.md" "consumed"
    local output
    output=$("$CS_BIN" rot-consumed <<< "n" 2>&1) || true
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: consumed handoff must not resurface"
        return 1
    fi
}

test_newest_of_multiple_handoffs_wins() {
    _rot_session "rot-multi"
    local dir="$CS_SESSIONS_ROOT/rot-multi"
    _seed_handoff "$dir" "2026-07-14-old.md" "unconsumed"
    _seed_handoff "$dir" "2026-07-16-new.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-multi <<< "r" 2>&1) || true
    assert_eq "2026-07-16-new.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "lexicographically last basename wins" || return 1
    assert_file_contains "$dir/.cs/handoffs/2026-07-14-old.md" "status: unconsumed" \
        "older handoff untouched" || return 1
}

run_test test_prompt_unchanged_without_handoff
run_test test_rotate_answer_consumes_pending_handoff
run_test test_continue_and_no_leave_handoff_unconsumed
run_test test_consumed_handoffs_do_not_trigger_prompt
run_test test_newest_of_multiple_handoffs_wins
```

(`assert_output_contains` greps with `grep -q -- "$pattern"` — tests/test_lib.sh:176 — so leading-dash patterns are safe as the plain second argument.)

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_rotation.sh` — the five new tests FAIL (no three-way prompt exists).

- [ ] **Step 3: Implement the prompt**

In `lib/75-launch.sh`, replace the prompt block (lines 153-175) with:

```bash
    # For existing sessions, ask if user wants to continue previous conversation
    local continue_flag=""
    if [ "$is_new" = "false" ]; then
        # Deliberate rotation: an unconsumed handoff written by the rotate
        # skill adds a third answer. Lexicographically last basename wins
        # (the YYYY-MM-DD- prefix makes that the newest date).
        local pending_handoff="" _hf
        for _hf in "$session_dir/.cs/handoffs"/*.md; do
            [ -f "$_hf" ] || continue
            grep -q '^status: unconsumed$' "$_hf" 2>/dev/null || continue
            pending_handoff="$_hf"
        done
        if [ -n "$pending_handoff" ]; then
            printf "${DIM}Rotation handoff pending:${NC} %s\n" "$(basename "$pending_handoff")"
            printf "${DIM}Continue previous conversation?${NC} [Y/n/r] ${DIM}(r = fresh conversation with handoff)${NC} "
        else
            printf "${DIM}Continue previous conversation?${NC} [Y/n] "
        fi
        read -r response || exit 130
        case "$response" in
            [nN]|[nN][oO])
                continue_flag=""
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    mkdir -p "$session_dir/.cs/local"
                    printf '%s\n' "$(basename "$pending_handoff")" > "$session_dir/.cs/local/pending-handoff"
                    echo ""
                    _exec_fresh_rebind "$session_dir" handoff "$(basename "$pending_handoff")"
                fi
                # r without a pending handoff was never offered: treat as the
                # default resume answer.
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
            *)
                # Prefer --resume <uuid> when the session has a recorded UUID:
                # it names the exact conversation, vs --continue which means
                # "most recent" and may resolve to a sibling Claude session
                # the user ran in a different terminal between cs launches.
                if [ -n "$claude_session_id" ]; then
                    continue_flag="--resume $claude_session_id"
                else
                    continue_flag="--continue"
                fi
                ;;
        esac
        echo ""
    fi
```

(`_exec_fresh_rebind` execs and never returns, so the resume fallback in the `[rR]` arm only runs when no handoff was pending. The bare-glob loop is bash-3.2-safe: with no matches the literal pattern fails the `-f` guard.)

- [ ] **Step 4: Build and run to green**

Run: `./build.sh && bash tests/test_rotation.sh && bash tests/test_uuid.sh && bash tests/test_archive.sh && bash tests/test_session_lock.sh`
Expected: all PASS (the archive reopen test and UUID cycle-7 tests exercise the untouched two-way path).

- [ ] **Step 5: Commit**

```bash
git add lib/75-launch.sh tests/test_rotation.sh bin/cs
git commit -m "feat: three-way launch prompt consumes pending rotation handoffs"
```

---

### Task 4: SessionStart consumption

**Files:**
- Modify: `hooks/session-start.sh:301-316` (restructure the CS_FRESH_REBIND block into a precedence chain)
- Test: `tests/test_rotation.sh` (append)

**Interfaces:**
- Consumes: `.cs/local/pending-handoff` (Task 3), the frontmatter contract (Task 2), `SESSION_ID` (hook stdin), `META_DIR`.
- Produces: the consumed handoff (`status: consumed` + `consumed_by:`), rotation context in additionalContext.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_rotation.sh`:

```bash
# ============================================================================
# Cycle 4: SessionStart consumes the pending handoff
# ============================================================================

_start_hook() {  # session_id [extra env pre-exported by caller]
    echo "{\"session_id\":\"$1\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"startup\"}" \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}

test_pending_handoff_is_consumed_and_injected() {
    _rot_hook_session "rot-consume"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    assert_output_contains "$out" "Conversation Rotation" "rotation preamble injected" || return 1
    assert_output_contains "$out" ".cs/handoffs/2026-07-16-test.md" "preamble names the handoff path" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: consumed" \
        "frontmatter flipped" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "consumed_by: $UUID_B" \
        "consumer recorded" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] || { echo "  FAIL: marker must be removed"; return 1; }
    assert_output_contains "$out" "managed Claude Code session" "existing context spliced, not replaced" || return 1
}

test_rotation_preamble_wins_over_fresh_rebind_block() {
    _rot_hook_session "rot-precedence"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B") || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    assert_output_contains "$out" "Conversation Rotation" "rotation preamble present" || return 1
    if printf '%s' "$out" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind block must yield to the rotation preamble"
        return 1
    fi
}

test_fresh_rebind_block_survives_without_handoff() {
    _rot_hook_session "rot-fresh-only"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B") || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    assert_output_contains "$out" "Fresh Conversation" "fresh block still fires alone" || return 1
}

test_stale_marker_is_removed_silently() {
    _rot_hook_session "rot-stale"
    printf '%s\n' "2026-01-01-gone.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] || { echo "  FAIL: stale marker must be removed"; return 1; }
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: stale marker must not inject a preamble"
        return 1
    fi
}

test_handoff_with_hostile_purpose_survives_flip() {
    _rot_hook_session "rot-hostile"
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/handoffs"
    cat > "$CLAUDE_SESSION_DIR/.cs/handoffs/2026-07-16-hostile.md" << 'EOF'
---
parent: 11111111-1111-4111-8111-111111111111
created: 2026-07-16T10:00:00Z
purpose: continue "phase 2" of $(dangerous) `work`
status: unconsumed
---

Body with $(subshell) and "quotes".
EOF
    printf '%s\n' "2026-07-16-hostile.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" >/dev/null || return 1
    local f="$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-hostile.md"
    assert_file_contains "$f" "status: consumed" "flip succeeded despite hostile content" || return 1
    assert_file_contains "$f" 'continue "phase 2" of .(dangerous)' "purpose intact (quotes, subshell)" || return 1
    assert_file_contains "$f" 'Body with .(subshell) and "quotes".' "body intact" || return 1
}

run_test test_pending_handoff_is_consumed_and_injected
run_test test_rotation_preamble_wins_over_fresh_rebind_block
run_test test_fresh_rebind_block_survives_without_handoff
run_test test_stale_marker_is_removed_silently
run_test test_handoff_with_hostile_purpose_survives_flip
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_rotation.sh` — the four new tests FAIL.

- [ ] **Step 3: Implement consumption**

In `hooks/session-start.sh`, replace the CS_FRESH_REBIND block (lines 301-316) with:

```bash
# Deliberate rotation: the launch's r answer left a pending-handoff marker.
# Consume it — flip the handoff's frontmatter to consumed, record the
# consumer, remove the marker — and inject a preamble pointing Claude at the
# handoff file. A stale marker (file gone) is removed silently.
ROTATION_HANDOFF=""
PENDING_MARKER="$META_DIR/local/pending-handoff"
if [ -f "$PENDING_MARKER" ]; then
    HANDOFF_BASENAME=$(cat "$PENDING_MARKER" 2>/dev/null | tr -d '[:space:]' || true)
    HANDOFF_FILE="$META_DIR/handoffs/$HANDOFF_BASENAME"
    if [ -n "$HANDOFF_BASENAME" ] && [ -f "$HANDOFF_FILE" ]; then
        ROTATION_HANDOFF="$HANDOFF_BASENAME"
        awk -v uuid="$SESSION_ID" '
            !flipped && $0 == "status: unconsumed" {
                print "status: consumed"
                print "consumed_by: " uuid
                flipped = 1
                next
            }
            { print }
        ' "$HANDOFF_FILE" > "$HANDOFF_FILE.tmp" 2>/dev/null \
            && mv "$HANDOFF_FILE.tmp" "$HANDOFF_FILE" 2>/dev/null \
            || rm -f "$HANDOFF_FILE.tmp" 2>/dev/null || true
    fi
    rm -f "$PENDING_MARKER" 2>/dev/null || true
fi

# The rotation preamble and the fresh-rebind notice are mutually exclusive:
# the rotate path also exports CS_FRESH_REBIND, and "clean break" plus
# "continue per the handoff" would contradict each other.
if [ -n "$ROTATION_HANDOFF" ]; then
    CONTEXT="${CONTEXT}

--- Conversation Rotation ---
This fresh conversation continues rotated work. Read .cs/handoffs/$ROTATION_HANDOFF FIRST — it is the previous conversation's handoff; continue per its next-step section. The prior transcript is not loaded; the handoff plus .cs/memory/narrative.*.md carry the context."
elif [ "${CS_FRESH_REBIND:-}" = "1" ]; then
    CONTEXT="${CONTEXT}

--- Fresh Conversation ---
The user explicitly started a fresh conversation in this cs session — the prior conversation's transcript is not loaded. Treat this as a clean break, not a continuation.

For prior context, lazily consult as needed:
- .cs/memory/narrative.*.md — findings and decisions from earlier work (append only to your own actor's file)
- .cs/README.md            — session objective

Do not assume continuity with previous turns."
fi
```

(Keep the original comment above the old block if it still reads true, or fold its content into the new comments; the Fresh Conversation text itself is byte-identical to today's.)

- [ ] **Step 4: Run to green**

Run: `bash tests/test_rotation.sh && bash tests/test_hooks.sh`
Expected: all PASS. (No build needed — hooks are standalone — but run `./build.sh` anyway if any lib/ file was touched.)

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_rotation.sh
git commit -m "feat: SessionStart consumes pending rotation handoffs into context"
```

---

### Task 5: The context nudge

**Files:**
- Modify: `hooks/narrative-reminder.sh` (insert between the queue section's closing `fi` at line 188 and the COOLDOWN_FILE logic at line 191)
- Test: `tests/test_rotation.sh` (append)

**Interfaces:**
- Consumes: `$QDIR/context-pct` (stamped by cs-statusline), Stop payload `session_id`, `CS_ROTATE_NUDGE_CTX`.
- Produces: `.cs/local/rotate-nudged` (the nudged conversation UUID), a one-time block naming the `rotate` skill.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_rotation.sh`:

```bash
# ============================================================================
# Cycle 5: context nudge (Stop hook)
# ============================================================================

_stop_with_ctx() {  # ctx-pct-or-empty, session_id
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    else
        rm -f "$CLAUDE_SESSION_META_DIR/local/context-pct"
    fi
    echo "{\"session_id\":\"$2\"}" | bash "$HOOKS_DIR/narrative-reminder.sh"
}

test_nudge_fires_once_at_threshold() {
    _rot_hook_session "rot-nudge"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" '"decision":"block"' "nudge delivered as a block" || return 1
    assert_output_contains "$out" "rotate" "nudge names the rotate skill" || return 1
    assert_output_contains "$out" "80%" "nudge names the reading" || return 1
    assert_eq "$UUID_A" "$(cat "$CLAUDE_SESSION_META_DIR/local/rotate-nudged" | tr -d '[:space:]')" \
        "cursor records the nudged conversation" || return 1
    out=$(_stop_with_ctx 85 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: same conversation must not be nudged twice"
        return 1
    fi
}

test_nudge_rearms_for_new_conversation() {
    _rot_hook_session "rot-nudge-rearm"
    _stop_with_ctx 80 "$UUID_A" >/dev/null || return 1
    local out
    out=$(_stop_with_ctx 80 "$UUID_B") || return 1
    assert_output_contains "$out" "rotate" "new conversation UUID re-arms the nudge" || return 1
}

test_nudge_silent_below_threshold_and_without_signal() {
    _rot_hook_session "rot-nudge-quiet"
    local out
    out=$(_stop_with_ctx 79 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: 79 must not nudge at default threshold"
        return 1
    fi
    out=$(_stop_with_ctx "" "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: missing context-pct must never nudge"
        return 1
    fi
    out=$(_stop_with_ctx "hot" "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: non-numeric context-pct must never nudge"
        return 1
    fi
}

test_nudge_threshold_override() {
    _rot_hook_session "rot-nudge-env"
    export CS_ROTATE_NUDGE_CTX=90
    local out
    out=$(_stop_with_ctx 85 "$UUID_A") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    if printf '%s' "$out" | grep -q "rotate skill"; then
        unset CS_ROTATE_NUDGE_CTX
        echo "  FAIL: 85 under a 90 override must not nudge"
        return 1
    fi
    out=$(_stop_with_ctx 90 "$UUID_A") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    unset CS_ROTATE_NUDGE_CTX
    assert_output_contains "$out" "rotate" "90 at a 90 override nudges" || return 1
    _rot_hook_session "rot-nudge-env2"
    export CS_ROTATE_NUDGE_CTX=banana
    out=$(_stop_with_ctx 80 "$UUID_B") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    unset CS_ROTATE_NUDGE_CTX
    assert_output_contains "$out" "rotate" "non-numeric override falls back to 80" || return 1
}

test_nudge_yields_to_queue_drain() {
    _rot_hook_session "rot-nudge-queue"
    printf 'task one\n' > "$CLAUDE_SESSION_META_DIR/local/queue"
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" "cs task queue" "queue owns the turn loop" || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: nudge must yield to an armed queue"
        return 1
    fi
}

run_test test_nudge_fires_once_at_threshold
run_test test_nudge_rearms_for_new_conversation
run_test test_nudge_silent_below_threshold_and_without_signal
run_test test_nudge_threshold_override
run_test test_nudge_yields_to_queue_drain
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_rotation.sh` — the five new tests FAIL.

- [ ] **Step 3: Implement the nudge**

In `hooks/narrative-reminder.sh`, insert between the queue section's final `fi` (line 188) and the `COOLDOWN_FILE=` line (line 191):

```bash
# --- Rotation nudge -----------------------------------------------------------
# One-time suggestion to rotate when context runs hot. Delivered as a block
# (the only Stop-hook surface Claude sees); an armed or draining queue never
# reaches here (its branches exit above), so the drain's context breaker owns
# hot-context handling during walk-away runs. Cursor: the conversation UUID
# last nudged, machine-local.
NUDGE_CTX=$(_num_or "${CS_ROTATE_NUDGE_CTX:-}" 80)
NUDGE_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
NUDGE_PCT=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
case "$NUDGE_PCT" in ''|*[!0-9]*) NUDGE_PCT="";; esac
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] && [ "$NUDGE_PCT" -ge "$NUDGE_CTX" ]; then
    NUDGED=$(cat "$QDIR/rotate-nudged" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$NUDGED" != "$NUDGE_UUID" ]; then
        printf '%s\n' "$NUDGE_UUID" > "$QDIR/rotate-nudged.tmp" \
            && mv "$QDIR/rotate-nudged.tmp" "$QDIR/rotate-nudged"
        REASON="Context is at ${NUDGE_PCT}% — consider rotating this conversation. Invoke the rotate skill to distill a handoff into .cs/handoffs/; the user can then reopen the session and answer r for a fresh conversation that continues from it. One-time notice for this conversation; if now is a bad time, simply continue."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi
```

(`_num_or` and `QDIR` already exist in this hook — lines 59-61 and 41.)

- [ ] **Step 4: Run to green**

Run: `bash tests/test_rotation.sh && bash tests/test_queue_supervision.sh && bash tests/test_hooks.sh`
Expected: all PASS (queue tests prove the drain paths still win).

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_rotation.sh
git commit -m "feat: once-per-conversation rotation nudge when context passes CS_ROTATE_NUDGE_CTX"
```

---

### Task 6: `cs -conversations` + docs

**Files:**
- Create: `lib/54-conversations.sh`
- Modify: `lib/99-main.sh` (top-level arm after `-queue` at :115-119; session-scoped arm after `-queue` at :200-207; the session-scoped `*)` error string listing valid options)
- Modify: `lib/10-help.sh` (one line after the `-queue log` line)
- Modify: `completions/_cs` (global_flags array; the session-scoped opts list if one exists — mirror how `-queue` appears there)
- Modify: `completions/cs.bash` (`global_flags` string at :14; `session_opts` at :32)
- Modify: `README.md` (new "Conversation rotation" subsection near the queue/archive feature docs)
- Modify: `docs/session-layout.md` (shared table: `.cs/handoffs/`; machine-local table: `pending-handoff`, `rotate-nudged`; timeline event list: `rotated`)
- Modify: `docs/hooks.md` (session-start consumption step; narrative-reminder nudge)
- Test: `tests/test_rotation.sh` (append); `tests/test_completions.sh` and `tests/test_help.sh` as regressions

**Interfaces:**
- Consumes: the `rotated`/`started` events (Task 1), `_read_local_state` (lib/40-state.sh).
- Produces: `run_conversations` (no arguments; errors outside a session context).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_rotation.sh`:

```bash
# ============================================================================
# Cycle 6: cs -conversations
# ============================================================================

test_conversations_renders_chain() {
    _rot_hook_session "rot-view"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    cat > "$CLAUDE_SESSION_META_DIR/timeline.jsonl" << EOF
{"ts":"2026-07-14T09:00:00Z","event":"started","source":"startup","session_id":"$UUID_A","branch":"main"}
{"ts":"2026-07-14T12:00:00Z","event":"started","source":"resume","session_id":"$UUID_A","branch":"main"}
{"ts":"2026-07-15T08:00:00Z","event":"checkpoint","label":"x","file":"y","branch":"main"}
{"ts":"2026-07-16T10:00:00Z","event":"rotated","from":"$UUID_A","to":"$UUID_B","reason":"handoff","handoff":"2026-07-16-test.md"}
{"ts":"2026-07-16T10:00:05Z","event":"started","source":"startup","session_id":"$UUID_B","branch":"main"}
EOF
    local out
    out=$("$CS_BIN" -conversations 2>&1) || return 1
    assert_output_contains "$out" "11111111  started (startup, resumed 1x)" "first conversation folds resumes" || return 1
    assert_output_contains "$out" "11111111 > 22222222  rotated (handoff: 2026-07-16-test.md)" "rotation arrow with handoff" || return 1
    assert_output_contains "$out" "[current]" "live conversation marked" || return 1
    if printf '%s' "$out" | grep -q "checkpoint"; then
        echo "  FAIL: non-conversation events must not render"
        return 1
    fi
}

test_conversations_empty_timeline() {
    _rot_hook_session "rot-view-empty"
    rm -f "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    local out
    out=$("$CS_BIN" -conversations 2>&1) || return 1
    assert_output_contains "$out" "No conversation history recorded." "empty message" || return 1
}

test_conversations_requires_session_context() {
    local out rc=0
    out=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR "$CS_BIN" -conversations 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: must error outside a session"; return 1; }
    assert_output_contains "$out" "inside a cs session" "error names the requirement" || return 1
}

test_conversations_session_scoped_form() {
    _rot_hook_session "rot-view-scoped"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    printf '{"ts":"2026-07-14T09:00:00Z","event":"started","source":"startup","session_id":"%s","branch":"main"}\n' "$UUID_A" \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    local out
    out=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR \
        "$CS_BIN" rot-view-scoped -conversations 2>&1) || return 1
    assert_output_contains "$out" "11111111  started (startup)" "scoped form renders" || return 1
}

run_test test_conversations_renders_chain
run_test test_conversations_empty_timeline
run_test test_conversations_requires_session_context
run_test test_conversations_session_scoped_form
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_rotation.sh` — the four new tests FAIL (`Unknown option: -conversations`).

- [ ] **Step 3: Implement the verb**

Create `lib/54-conversations.sh`:

```bash
# ABOUTME: cs -conversations: the session's conversation chain from timeline.jsonl.
# ABOUTME: Renders started/rotated events with lineage arrows in local time.

run_conversations() {
    [ $# -eq 0 ] || error "Usage: cs -conversations"
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -conversations must be run inside a cs session, or as: cs <session> -conversations"
    fi
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    if [ ! -s "$timeline" ]; then
        echo "No conversation history recorded."
        return 0
    fi
    local current
    current=$(_read_local_state "$CLAUDE_SESSION_META_DIR/local/state" claude_session_id)
    # One line per conversation's first started event (later starteds fold
    # into a resumed-count suffix); one line per rotated event. Torn or
    # foreign lines are skipped by the tolerant per-line parse.
    jq -rRs --arg current "$current" '
        [split("\n")[] | select(length > 0) | (fromjson? // empty)
         | select(.event == "started" or .event == "rotated")] as $ev |
        (reduce $ev[] as $e ({};
            if $e.event == "started"
            then .[$e.session_id] = (.[$e.session_id] // 0) + 1
            else . end)) as $n |
        (reduce $ev[] as $e ({seen: {}, out: []};
            if $e.event == "started" then
                if .seen[$e.session_id] then . else
                    .seen[$e.session_id] = true |
                    .out += [{ts: $e.ts,
                        txt: ($e.session_id[0:8] + "  started (" + ($e.source // "?")
                            + (if ($n[$e.session_id] // 1) > 1
                               then ", resumed " + (($n[$e.session_id] - 1) | tostring) + "x"
                               else "" end)
                            + ")"
                            + (if $current != "" and $e.session_id == $current
                               then "  [current]" else "" end))}]
                end
            else
                .out += [{ts: $e.ts,
                    txt: ((if ($e.from // "") == "" then "?" else $e.from[0:8] end)
                        + " > " + ($e.to[0:8]) + "  rotated (" + ($e.reason // "?")
                        + (if ($e.handoff // "") != "" then ": " + $e.handoff else "" end)
                        + ")")}]
            end)).out[] |
        ((try (.ts | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) catch .ts))
            + "  " + .txt
    ' "$timeline"
}
```

`lib/99-main.sh` — top-level arm, directly after the `-queue` arm (exactly 8-space indent):

```bash
        -conversations)
            shift
            run_conversations "$@"
            return 0
            ;;
```

Session-scoped arm, directly after the session-scoped `-queue` arm:

```bash
            -conversations)
                shift
                export CLAUDE_SESSION_NAME="$session_name"
                export CLAUDE_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CLAUDE_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_conversations "$@"
                return 0
                ;;
```

And extend the session-scoped catch-all error string: `"Unknown session command: $1. Use -secrets, -queue, -conversations, -usage, -tag, --merge, or --force."`

`lib/10-help.sh` — after the `-queue log` line (no backticks):

```
  -conversations      Show the session's conversation chain (rotations, lineage)
```

`completions/_cs` — in `global_flags`, after the `-queue` entry:

```
        '-conversations:Show the session'\''s conversation chain'
```

Also mirror wherever `_cs` lists session-scoped commands (search for how `-usage` appears in the `has_session` context and add `-conversations` beside it).

`completions/cs.bash` — line 14 `global_flags` gains ` -conversations`; line 32 `session_opts` becomes `"-secrets -queue -conversations -usage -tag --force --merge"`.

`README.md` — add a "Conversation rotation" subsection beside the walk-away queue docs covering: the `rotate` skill and the handoff store, the `[Y/n/r]` prompt, the once-per-conversation 80% nudge and `CS_ROTATE_NUDGE_CTX`, `cs -conversations`, and the `rotated` timeline event (reasons: handoff, declined-resume, resume-failed, rebind).

`docs/session-layout.md` — shared table row for `.cs/handoffs/` (tracked, whole-file markdown, human-merge); machine-local table rows for `pending-handoff` and `rotate-nudged`; extend the timeline description with the `rotated` event.

`docs/hooks.md` — note session-start's handoff consumption and narrative-reminder's rotation nudge.

- [ ] **Step 4: Build and run to green**

Run: `./build.sh && bash tests/test_rotation.sh && bash tests/test_completions.sh && bash tests/test_help.sh`
Expected: all PASS (the completions drift guard extracts `-conversations` from the dispatch and finds it in both files).

- [ ] **Step 5: Full gates and commit**

Run: `bash tests/run_all.sh` and `cd tui && cargo test` (regression only).
Expected: all suites PASS; 247 cargo tests unchanged.

```bash
git add lib/54-conversations.sh lib/99-main.sh lib/10-help.sh completions/_cs completions/cs.bash README.md docs/session-layout.md docs/hooks.md tests/test_rotation.sh bin/cs
git commit -m "feat: cs -conversations renders the conversation chain; rotation docs"
```
