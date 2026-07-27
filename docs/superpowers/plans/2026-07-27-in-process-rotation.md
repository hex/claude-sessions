# In-process rotation via /clear — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make conversation rotation an in-process operation — `rotate` arms a marker, `/clear` completes it — instead of a four-step process restart.

**Architecture:** The rotate skill writes `.cs/local/pending-handoff` itself, so the launcher's `r` keypress is no longer the only way to arm it. `hooks/session-start.sh` resolves the marker's fate **once**, before the UUID-rebind block, against a four-clause predicate (source ∈ {startup, clear} ∧ marker present ∧ file exists ∧ frontmatter `status: unconsumed`); the timeline labeller and the consumption block both read that single result. The launcher disarms a marker the user declined, audibly.

**Tech Stack:** POSIX shell / bash 3.2, `jq`, `awk`. `bin/cs` is a build artifact assembled by `build.sh` from `lib/*.sh` — never edit it directly. Hooks are standalone scripts that source nothing from `lib/`.

## Global Constraints

- Must run on macOS stock `/bin/bash` 3.2 and BSD userland. No bash 4+ (`local -A`, `printf %(...)T`, `source <()`), no GNU-only `sed`/`awk`/`stat`/`timeout`.
- `hooks/session-start.sh` runs under `set -euo pipefail`. A bare `[ ... ] && VAR=1` as the last command of a `case` arm returns 1 and kills the script — always use an explicit `if`.
- Never edit `bin/cs`; edit `lib/*.sh` and run `build.sh`.
- `assert_file_contains` is a BRE matcher — escape bracket literals (`\[Y/n/r/d\]`) or the assertion is unpassable or vacuous.
- Comments: no temporal or historical framing ("new", "improved", "used to"). Describe the code as it is.
- Never `git add -A`. Stage named paths only.
- The rotation marker lives in `.cs/local/` (machine-local); it must never be committed.

---

### Task 1: Resolve the rotation marker once, gated by source and status

**Files:**
- Modify: `hooks/session-start.sh` (add helper near the other `_build_*` helpers; add resolution block immediately before the rebind block at `:248`; simplify the consumption block at `:431-455`)
- Test: `tests/test_rotation.sh`

**Interfaces:**
- Produces: `_handoff_is_unconsumed <file>` — exit 0 when the file's YAML frontmatter carries `status: unconsumed`, non-zero otherwise.
- Produces: `ROTATION_HANDOFF` — handoff basename when consumable this SessionStart, empty otherwise. Read by Tasks 2 and 3.
- Produces: `PENDING_MARKER` — absolute path to `.cs/local/pending-handoff`.
- Modifies: `_start_hook <session_id> [source]` in the test file — source defaults to `startup`, so all existing call sites are unchanged.

- [ ] **Step 1: Make the test helper able to drive any source**

`tests/test_rotation.sh:314-317` hardcodes `"source":"startup"`, so every rotation test would pass a wrong allow-list vacuously. Replace it with:

```bash
_start_hook() {  # session_id [source] [extra env pre-exported by caller]
    echo "{\"session_id\":\"$1\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"${2:-startup}\"}" \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/test_rotation.sh` after `test_stale_marker_is_removed_silently`:

```bash
# The marker is consumable only where a genuinely fresh conversation begins.
test_clear_source_consumes_pending_handoff() {
    _rot_hook_session "rot-clear"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "Conversation Rotation" "clear consumes the marker" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: consumed" \
        "frontmatter flipped on clear" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: marker must be removed after a clear consumption"; return 1; }
}

# compact and fork keep the transcript loaded, so consuming there would inject
# "the prior transcript is not loaded" into a conversation where it is. The
# marker is left ARMED — the pending rotation is still legitimate.
test_compact_and_fork_leave_marker_armed() {
    local src
    for src in compact fork resume; do
        _rot_hook_session "rot-armed-$src"
        _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
        printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
        printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
        local out
        out=$(_start_hook "$UUID_B" "$src") || return 1
        if printf '%s' "$out" | grep -q "Conversation Rotation"; then
            echo "  FAIL: source $src must not consume the marker"; return 1
        fi
        assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: unconsumed" \
            "$src leaves the handoff unconsumed" || return 1
        [ -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
            || { echo "  FAIL: source $src must leave the marker armed"; return 1; }
    done
}

# A handoff consumed elsewhere (another machine, then pulled) must not
# re-inject its preamble, and its status must not be rewritten.
test_spent_handoff_is_not_reconsumed() {
    _rot_hook_session "rot-spent"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "consumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a spent handoff must not inject a preamble"; return 1
    fi
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "consumed_by:" \
        "no consumer recorded for a spent handoff" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: a marker naming a spent handoff is stale and must be removed"; return 1; }
}

# The status check is frontmatter-scoped: a body quoting the contract line
# flush-left must not make a discarded handoff look pending.
test_body_quote_does_not_revive_a_discarded_handoff() {
    _rot_hook_session "rot-revive"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "discarded"
    printf 'status: unconsumed\n' >> "$CLAUDE_SESSION_DIR/.cs/handoffs/2026-07-16-test.md"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a flush-left body quote must not revive a discarded handoff"; return 1
    fi
}
```

Register them with the other Cycle 4 tests:

```bash
run_test test_clear_source_consumes_pending_handoff
run_test test_compact_and_fork_leave_marker_armed
run_test test_spent_handoff_is_not_reconsumed
run_test test_body_quote_does_not_revive_a_discarded_handoff
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/test_rotation.sh`
Expected: FAIL. `test_compact_and_fork_leave_marker_armed` fails first (today every source consumes); `test_spent_handoff_is_not_reconsumed` fails because consumption gates only on file existence.

- [ ] **Step 4: Add the frontmatter predicate helper**

In `hooks/session-start.sh`, alongside the other helper functions (after `_build_digest`):

```bash
# True when a handoff file's YAML frontmatter (line 1 "---" through the next
# "---") carries status: unconsumed. Scoped to the frontmatter so a body that
# quotes the contract line flush-left cannot match. Same scan as the launch
# path's pending-handoff detection (hooks cannot source bin/cs).
_handoff_is_unconsumed() {  # handoff_file
    awk '
        NR==1 {
            if ($0 != "---") { rc=1; closed=1; exit }
            next
        }
        !closed && $0 == "---" { rc = (matched ? 0 : 1); closed=1; exit }
        !closed && $0 == "status: unconsumed" { matched=1 }
        END { if (!closed) rc=1; exit rc }
    ' "$1" 2>/dev/null
}
```

- [ ] **Step 5: Resolve the marker once, before the rebind block**

Insert immediately above the `UUID_RE=` line at `hooks/session-start.sh:254`:

```bash
# Resolve the pending rotation marker's fate once: the rebind block's timeline
# label and the consumption block far below both read ROTATION_HANDOFF, so the
# two cannot drift apart.
#
# Source is tested first. On a source that continues an existing conversation
# the marker is neither inspected nor changed, so a compaction or a
# context-limit fork between the rotate skill and /clear cannot eat a pending
# rotation. Only where a genuinely fresh conversation begins does a spent or
# missing handoff make the marker stale and worth dropping.
ROTATION_HANDOFF=""
PENDING_MARKER="$META_DIR/local/pending-handoff"
case "$SOURCE" in
    startup|clear)
        if [ -f "$PENDING_MARKER" ]; then
            HANDOFF_BASENAME=$(cat "$PENDING_MARKER" 2>/dev/null | tr -d '[:space:]' || true)
            HANDOFF_FILE="$META_DIR/handoffs/$HANDOFF_BASENAME"
            if [ -n "$HANDOFF_BASENAME" ] && [ -f "$HANDOFF_FILE" ] \
                && _handoff_is_unconsumed "$HANDOFF_FILE"; then
                ROTATION_HANDOFF="$HANDOFF_BASENAME"
            else
                rm -f "$PENDING_MARKER" 2>/dev/null || true
            fi
        fi
        ;;
esac
```

- [ ] **Step 6: Reduce the consumption block to the flip**

Replace `hooks/session-start.sh:431-455` (the block opening `# Deliberate rotation: the launch's r answer left a pending-handoff marker.` through its closing `fi`) with:

```bash
# Consume the rotation resolved above: flip the handoff's frontmatter to
# consumed, record the consumer, and drop the marker. Only the first status
# line (the frontmatter's) flips; a body quoting it flush-left stays intact.
if [ -n "$ROTATION_HANDOFF" ]; then
    HANDOFF_FILE="$META_DIR/handoffs/$ROTATION_HANDOFF"
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
    rm -f "$PENDING_MARKER" 2>/dev/null || true
fi
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test_rotation.sh`
Expected: PASS, including the pre-existing `test_pending_handoff_is_consumed_and_injected`, `test_stale_marker_is_removed_silently`, and `test_handoff_with_hostile_purpose_survives_flip`.

- [ ] **Step 8: Commit**

```bash
git add hooks/session-start.sh tests/test_rotation.sh
git commit -m "feat(rotation): gate handoff consumption by source and status"
```

---

### Task 2: Label a /clear rotation as a handoff in the timeline

**Files:**
- Modify: `hooks/session-start.sh:264-268` (the rebind block's `rotated` event)
- Test: `tests/test_rotation.sh`

**Interfaces:**
- Consumes: `ROTATION_HANDOFF` from Task 1.
- Event shape must match `_timeline_rotated` (`lib/40-state.sh:99`): `{ts, event:"rotated", from, to, reason}` plus a `handoff` key only when non-empty.

- [ ] **Step 1: Write the failing tests**

```bash
# A /clear rotation has no launcher to emit the event, so the hook's rebind
# block is the sole emitter and must not label a deliberate rotation "rebind".
test_clear_rotation_records_handoff_reason() {
    _rot_hook_session "rot-label"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" clear >/dev/null || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"handoff"' "clear rotation is a handoff" || return 1
    assert_output_contains "$ev" '"handoff":"2026-07-16-test.md"' "event names the handoff" || return 1
}

# A fork with an armed marker rebinds but does not rotate: labelling it
# "handoff" would record a rotation that never happened, and the real /clear
# would then emit a second event for the same file.
test_fork_with_armed_marker_records_rebind() {
    _rot_hook_session "rot-label-fork"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" fork >/dev/null || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"rebind"' "a fork is not a handoff rotation" || return 1
    if printf '%s' "$ev" | grep -q '"handoff"'; then
        echo "  FAIL: a fork event must carry no handoff field"; return 1
    fi
}
```

Register both with `run_test`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_rotation.sh`
Expected: `test_clear_rotation_records_handoff_reason` FAILS with `"reason":"rebind"`.

- [ ] **Step 3: Emit the label**

Replace the `jq -nc` invocation at `hooks/session-start.sh:264-268` with:

```bash
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --arg from "${RECORDED_UUID:-}" \
               --arg to "$SESSION_ID" \
               --arg handoff "$ROTATION_HANDOFF" \
               '{ts: $ts, event: "rotated", from: $from, to: $to,
                 reason: (if $handoff == "" then "rebind" else "handoff" end)}
                + (if $handoff == "" then {} else {handoff: $handoff} end)' \
            >> "$META_DIR/timeline.jsonl" 2>/dev/null || true
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_rotation.sh`
Expected: PASS, including `test_hook_mismatch_emits_rebind_event` (no marker → still `rebind`).

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_rotation.sh
git commit -m "feat(rotation): label an in-process rotation as a handoff"
```

---

### Task 3: Gate the fresh-conversation notice by source

**Files:**
- Modify: `hooks/session-start.sh:465` (the `elif [ "${CS_FRESH_REBIND:-}" = "1" ]` arm)
- Test: `tests/test_rotation.sh`

**Interfaces:**
- Consumes: `SOURCE`, `CS_FRESH_REBIND`, `ROTATION_HANDOFF`.

This fixes a live bug. `_exec_fresh_rebind` exports `CS_FRESH_REBIND=1` before `exec` (`lib/40-state.sh:145`), so it persists for the whole claude process, and the consuming `elif` has no source gate. Any session launched via `n`, `r`, or a resume failure and then `/compact`ed is told *"the prior conversation's transcript is not loaded … Treat this as a clean break … Do not assume continuity"* inside a fully continuous conversation.

- [ ] **Step 1: Write the failing tests**

```bash
test_fresh_notice_absent_on_compact() {
    _rot_hook_session "rot-fresh-compact"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B" compact) || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    if printf '%s' "$out" | grep -q "Fresh Conversation"; then
        echo "  FAIL: a compaction continues the conversation — no clean-break notice"
        return 1
    fi
}

# A /clear IS a clean break, whether or not the launch was a rebind.
test_fresh_notice_present_on_clear_without_rebind_env() {
    _rot_hook_session "rot-fresh-clear"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "Fresh Conversation" "clear is a clean break" || return 1
}
```

Register both with `run_test`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_rotation.sh`
Expected: `test_fresh_notice_absent_on_compact` FAILS (notice present today).

- [ ] **Step 3: Compute the notice condition, then gate on it**

Insert above the `if [ -n "$ROTATION_HANDOFF" ]; then` preamble block at `hooks/session-start.sh:460`:

```bash
# The clean-break notice belongs only where the conversation genuinely starts
# clean: a /clear, or a launch that rebound to a fresh UUID. CS_FRESH_REBIND is
# exported before exec and so outlives the launch, which is why the source must
# be checked too — without it a later /compact of a rebound session is told its
# transcript is not loaded while it still is.
#
# An explicit if inside the case arm: `[ ... ] && VAR=1` as an arm's last
# command returns 1 under set -e.
FRESH_NOTICE=""
case "$SOURCE" in
    clear)
        FRESH_NOTICE=1
        ;;
    startup)
        if [ "${CS_FRESH_REBIND:-}" = "1" ]; then
            FRESH_NOTICE=1
        fi
        ;;
esac
```

Then change the `elif` at what is now `hooks/session-start.sh:465`:

```bash
elif [ -n "$FRESH_NOTICE" ]; then
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_rotation.sh`
Expected: PASS, including `test_fresh_rebind_block_survives_without_handoff` (drives `startup` with `CS_FRESH_REBIND=1`) and `test_rotation_preamble_wins_over_fresh_rebind_block`.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_rotation.sh
git commit -m "fix(hooks): stop telling a compacted conversation it is a clean break"
```

---

### Task 4: Disarm a declined rotation marker, audibly

**Files:**
- Modify: `lib/75-launch.sh` (helper above `launch_session`'s resume prompt; calls in the `[nN]`, `[dD]`, and `*)` arms at `:246-300`)
- Test: `tests/test_rotation.sh`

**Interfaces:**
- Produces: `_disarm_rotation_marker <session_dir>` — removes `.cs/local/pending-handoff` and prints a notice when one existed; silent no-op otherwise.

Task 1's allow-list stops a declined marker misfiring *immediately* (a resumed conversation cannot consume). This closes the *deferred* misfire: the marker would otherwise survive the resume and be consumed by an unrelated `/clear` hours later, injecting a handoff the user already declined.

- [ ] **Step 1: Write the failing tests**

```bash
test_declining_resume_disarms_the_marker() {
    local ans
    for ans in "" n d; do
        _rot_session "rot-disarm-${ans:-default}"
        local dir="$CS_SESSIONS_ROOT/rot-disarm-${ans:-default}"
        _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
        printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
        local output
        output=$("$CS_BIN" "rot-disarm-${ans:-default}" <<< "$ans" 2>&1) || true
        [ ! -f "$dir/.cs/local/pending-handoff" ] \
            || { echo "  FAIL: answer '${ans:-default}' must disarm the marker"; return 1; }
        assert_output_contains "$output" "Rotation marker disarmed" \
            "answer '${ans:-default}' announces the disarm" || return 1
    done
}

# A marker whose handoff was consumed elsewhere leaves the prompt at [Y/n] —
# the disarm must not be nested inside the pending-handoff arms.
test_marker_without_pending_handoff_is_disarmed() {
    _rot_session "rot-disarm-orphan"
    local dir="$CS_SESSIONS_ROOT/rot-disarm-orphan"
    _seed_handoff "$dir" "2026-07-16-test.md" "consumed"
    printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
    "$CS_BIN" rot-disarm-orphan <<< "n" >/dev/null 2>&1 || true
    [ ! -f "$dir/.cs/local/pending-handoff" ] \
        || { echo "  FAIL: an orphaned marker must be disarmed too"; return 1; }
}
```

Register both with `run_test` in Cycle 3.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_rotation.sh`
Expected: FAIL — the marker file survives every answer today.

- [ ] **Step 3: Add the helper**

In `lib/75-launch.sh`, above `launch_session`:

```bash
# Drop a rotation marker the user declined to consume. Armed by the rotate
# skill for a /clear, or by an earlier r, it must not outlive the answer: left
# in place it would be consumed by an unrelated /clear hours later, injecting a
# handoff the user already passed on. Announced, because a silent removal turns
# the /clear route into a no-op the user cannot explain.
_disarm_rotation_marker() {  # session_dir
    local marker="$1/.cs/local/pending-handoff"
    [ -f "$marker" ] || return 0
    rm -f "$marker" 2>/dev/null || true
    printf "${DIM}Rotation marker disarmed; the handoff stays pending — answer r, or re-run the rotate skill.${NC}\n"
}
```

- [ ] **Step 4: Call it on every non-r answer**

In `lib/75-launch.sh`, add `_disarm_rotation_marker "$session_dir"` as the first statement of the `[nN]|[nN][oO])` arm, the `[dD])` arm, and the `*)` arm (which is also where the unattended `cs -spawn` default at `:230-231` lands). Do not add it to the `[rR])` arm — that arm writes the marker.

- [ ] **Step 5: Rebuild and run**

Run: `bash build.sh && bash tests/test_rotation.sh`
Expected: PASS, including `test_continue_and_no_leave_handoff_unconsumed` and `test_discard_answer_dismisses_pending_handoff`.

- [ ] **Step 6: Commit**

```bash
git add lib/75-launch.sh bin/cs tests/test_rotation.sh
git commit -m "feat(launch): disarm a declined rotation marker and say so"
```

---

### Task 5: Arm the marker from the rotate skill

**Files:**
- Modify: `skills/rotate/SKILL.md`
- Test: `tests/test_rotation.sh`

**Interfaces:**
- Consumes: the marker path and consumption contract from Task 1.

- [ ] **Step 1: Write the failing test**

`tests/test_rotation.sh` already asserts skill content in `test_rotate_skill_exists_with_frontmatter` (line 121). Add:

```bash
test_rotate_skill_documents_the_clear_route() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    assert_file_contains "$skill" "pending-handoff" \
        "skill arms the marker itself" || return 1
    assert_file_contains "$skill" "/clear" \
        "skill points the user at the in-process route" || return 1
    assert_file_contains "$skill" "superseded" \
        "skill retires its own stale handoffs" || return 1
    assert_file_not_contains "$skill" "never edits .cs/local/state" \
        "the stale no-state contract is gone" || return 1
}
```

Register it with `run_test`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_rotation.sh`
Expected: FAIL on the first assertion.

- [ ] **Step 3: Rewrite the skill**

Replace `skills/rotate/SKILL.md` lines 6-10 (the opening contract) with:

```markdown
Rotation ends this conversation's useful life deliberately: you distill the
work into a handoff file and arm it, and the next fresh conversation — most
easily one the user starts with `/clear`, without leaving Claude Code —
continues from it. This skill writes the handoff and the pending marker. It
never ends the conversation and never launches anything.
```

Insert between the current steps 4 and 5:

```markdown
5. Retire your own leftovers: for every other file in `.cs/handoffs/` whose
   frontmatter still says `status: unconsumed`, flip that one frontmatter line
   to `status: superseded`. An older pending handoff otherwise keeps the
   launch prompt offering `[Y/n/r/d]` for context that is out of date.
6. Arm the handoff: write its basename (no path) to
   `.cs/local/pending-handoff`. This is machine-local state — do not commit it,
   and do not stage it with the handoff in step 4.
```

Replace the final step's instructions with:

```markdown
7. Tell the user: run `/clear` to rotate now — the fresh conversation picks up
   this handoff automatically, without leaving Claude Code. It will not act
   until they send their next message, which can simply be what they want done.
   If they would rather stop for the day, exiting and answering `r` at the next
   `cs <session-name>` launch does the same thing; answering `Y` or `n` instead
   disarms the marker (the handoff stays pending, and `d` discards it).
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_rotation.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/rotate/SKILL.md tests/test_rotation.sh
git commit -m "feat(rotate): arm the handoff and rotate in-process via /clear"
```

---

### Task 6: Keep the already-running guard working after a /clear

**Files:**
- Modify: `lib/75-launch.sh:68-74`
- Test: `tests/test_uuid.sh` (the guard's existing test home, alongside `test_live_duplicate_refuses_without_force` at `:459`)

**Interfaces:**
- Consumes: `CS_PS_BIN` (the `ps` stub hook), `_seed_doctor_session <name> <uuid>`, and `$session_name` / `$claude_session_id` inside `launch_session`.
- Produces: `_seed_ps_stub_with_name <name> <uuid>` — echoes the stub path, mirroring `_seed_ps_stub_with_uuid` at `tests/test_uuid.sh:448`.

After an in-app `/clear` the recorded UUID is the post-clear one while the live process's argv still names the launch UUID, so the UUID test stops matching and a second `cs <session>` `--resume`s the live conversation — two processes on one transcript. Promoting `/clear` to the recommended rotation route makes this reachable in ordinary use.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_uuid.sh`, next to the existing live-duplicate tests:

```bash
# Build a ps stub whose argv names a session but carries an unrelated UUID —
# the shape a live conversation takes after an in-app /clear rebinds state.
_seed_ps_stub_with_name() {  # session_name, launch_uuid
    local name="$1" uuid="$2"
    local stub="$TEST_TMPDIR/ps-stub-name"
    cat > "$stub" << STUB
#!/usr/bin/env bash
echo "  47533 ??       0:00.42 claude --name $name --session-id $uuid"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_live_duplicate_detected_after_clear_rebind() {
    local recorded="11111111-2222-4333-8444-555555555555"
    local launched="99999999-8888-4777-8666-555555555555"
    _seed_doctor_session "test-session" "$recorded" >/dev/null
    local stub
    stub=$(_seed_ps_stub_with_name "test-session" "$launched")

    local output rc=0
    output=$(CS_PS_BIN="$stub" "$CS_BIN" test-session <<< "" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: a live conversation whose UUID was rebound by /clear must still be detected"
        echo "    output: $(echo "$output" | tail -5)"
        return 1
    fi
    assert_output_contains "$output" "already running" \
        "error should call out the live duplicate" || return 1
}

# A session name that prefixes another session's must not collide.
test_live_duplicate_ignores_a_longer_sibling_name() {
    local recorded="11111111-2222-4333-8444-555555555555"
    local launched="99999999-8888-4777-8666-555555555555"
    _seed_doctor_session "test-session" "$recorded" >/dev/null
    local stub
    stub=$(_seed_ps_stub_with_name "test-session-extra" "$launched")

    local output
    output=$(CS_PS_BIN="$stub" "$CS_BIN" test-session <<< "" 2>&1) || true

    assert_output_not_contains "$output" "already running" \
        "a longer sibling name must not block the launch" || return 1
}
```

Register both with `run_test`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_uuid.sh`
Expected: `test_live_duplicate_detected_after_clear_rebind` FAILS — the launch proceeds, because the recorded UUID no longer appears in the live process's argv.

- [ ] **Step 3: Match the name too**

Replace `lib/75-launch.sh:69-73` with:

```bash
        local _ps_out
        _ps_out=$("${CS_PS_BIN:-ps}" -Ao args= 2>/dev/null || true)
        # An in-app /clear rebinds the recorded UUID while the live process's
        # argv still names its launch UUID, so the UUID test alone goes blind.
        # --name is stable for the process's whole life. The trailing delimiter
        # keeps a name that prefixes another (sym vs sym-comfy-nodes) from
        # matching; the appended newline covers --name being the final argument.
        _ps_out="$_ps_out"$'\n'
        if [[ "$_ps_out" == *"$claude_session_id"* ]] \
            || [[ "$_ps_out" == *"--name $session_name "* ]] \
            || [[ "$_ps_out" == *"--name $session_name"$'\n'* ]]; then
            error "Session $session_name is already running elsewhere (UUID $claude_session_id). Use --force to override."
        fi
```

- [ ] **Step 4: Rebuild and run**

Run: `bash build.sh && bash tests/test_uuid.sh && bash tests/test_session_lock.sh && bash tests/test_worktrees.sh`
Expected: PASS. Those three suites are the other `CS_PS_BIN` consumers, so they are where a broken guard shows up. `_seed_ps_stub_with_uuid` emits no `--name`, so the pre-existing tests keep passing through the UUID branch.

- [ ] **Step 5: Commit**

```bash
git add lib/75-launch.sh bin/cs tests/test_uuid.sh
git commit -m "fix(launch): keep the already-running guard working after a /clear"
```

---

### Task 7: Sweep the docs and the context nudge

**Files:**
- Modify: `hooks/narrative-reminder.sh:235`, `docs/hooks.md:15` and `:39`, `docs/session-layout.md:35` and `:63`, `README.md:50` and the rotation section at `~293-345`, `CHANGELOG.md`

The nudge string is the primary discovery surface — it is how users learn the flow exists. Leaving it pointed at the `r` route means nobody finds `/clear`.

- [ ] **Step 1: Rewrite the nudge**

`hooks/narrative-reminder.sh:235` — replace the `REASON=` string's tail so it reads:

```
Context is at ${NUDGE_PCT}% — consider rotating this conversation. Invoke the rotate skill to distill a handoff into .cs/handoffs/ and arm it; the user then runs /clear to continue in a fresh conversation without leaving Claude Code. One-time notice for this conversation; if now is a bad time, simply continue.
```

- [ ] **Step 2: Update the reference docs**

- `docs/hooks.md:15` — the consumption bullet: the marker is armed by the rotate skill or the launch's `r` answer, consumed only on source `startup` or `clear`, only while the handoff is `unconsumed`; a spent or missing handoff makes it stale and it is removed silently; on any other source it is left armed.
- `docs/hooks.md:39` — the rotation-nudge bullet: point at `/clear`.
- `docs/hooks.md` fresh-conversation bullet — note the notice now fires on `clear`, or on `startup` with `CS_FRESH_REBIND`, and never on `compact`.
- `docs/session-layout.md:35` — the `.cs/handoffs/` row: add `superseded` to the status vocabulary.
- `docs/session-layout.md:63` — the `pending-handoff` row: armed by the rotate skill or the `r` answer; consumed by the next `startup` or `clear` SessionStart; disarmed by any other resume-prompt answer.
- `README.md:50` — rotation is `rotate` then `/clear`, with exit → relaunch → `r` as the alternative.
- `README.md:293-345` — rewrite the walkthrough around the in-process route; keep the `[Y/n/r/d]` prompt documented.
- `CHANGELOG.md` — add an `## Unreleased` section above the current top release header. Verify with `head -20 CHANGELOG.md` that no existing release header is consumed by the insertion.

- [ ] **Step 3: Verify no stale instructions remain**

Run: `rg -n 'answer r|answer `r`|press r' README.md docs/ hooks/ skills/`
Expected: every remaining hit is a deliberate description of the launch-prompt alternative, not the primary instruction.

- [ ] **Step 4: Commit**

```bash
git add hooks/narrative-reminder.sh docs/hooks.md docs/session-layout.md README.md CHANGELOG.md
git commit -m "docs(rotation): document the in-process /clear route"
```

---

### Task 8: Full gates, rebuild, deploy, and verify by hand

**Files:** none modified beyond `bin/cs` (rebuild)

- [ ] **Step 1: Rebuild from the fragments**

Run: `bash build.sh`
Expected: `bin/cs` reassembled. Confirm `git diff --stat bin/cs` shows only the intended changes.

- [ ] **Step 2: Run the whole suite to a log**

```bash
bash tests/run_all.sh > /tmp/cs-suite.log 2>&1; echo "exit=$?"; tail -30 /tmp/cs-suite.log
```

Never pipe `run_all.sh` to `tail` directly — it buffers and you see nothing until the end. Expected: every suite green.

- [ ] **Step 3: Deploy locally**

Copy `bin/cs` and `bin/cs-statusline` to `~/.local/bin/`, and `hooks/session-start.sh` plus `hooks/narrative-reminder.sh` to `~/.claude/hooks/cs/`. Use the repo's existing install path (`install.sh`) if it supports a local-only refresh.

- [ ] **Step 4: Verify the end-to-end rotation by hand**

Claude Code's own hook handling cannot be exercised from a shell test. In a scratch cs session: invoke the rotate skill, confirm `.cs/local/pending-handoff` exists, run `/clear`, and confirm the fresh conversation reports having read the handoff. Then confirm `cs -conversations` shows the hop as `rotated (handoff: <name>)`.

- [ ] **Step 5: Commit and report**

```bash
git add bin/cs
git commit -m "build: reassemble bin/cs"
```

Report the suite result verbatim — pass counts, and any failure with its output.

---

## Self-Review

**Spec coverage.** Predicate/allow-list → Task 1. Stale-vs-not-due distinction → Task 1 Steps 5-6 and its `test_compact_and_fork_leave_marker_armed`. Single evaluation → Task 1 Step 5, consumed by Tasks 2 and 3. Timeline labelling → Task 2. Arming + superseding + skill contract rewrite → Task 5. Disarm → Task 4. `CS_FRESH_REBIND` gate → Task 3. Already-running guard → Task 6. Docs and nudge → Task 7. Test source matrix → Task 1 Step 1 plus the per-task tests. Manual end-to-end → Task 8 Step 4. No spec section is unimplemented.

**Placeholders.** None. Every code step carries the literal text to write; the only judgement calls are prose rewrites in Task 7, which specify the required content.

**Type consistency.** `_handoff_is_unconsumed` (Task 1) is called only in Task 1. `ROTATION_HANDOFF` is set in Task 1 and read in Tasks 2 and 3 under that exact name. `PENDING_MARKER` is set in Task 1 and read in Task 1's consumption block. `_disarm_rotation_marker` (Task 4) takes `session_dir`, matching its three call sites. `FRESH_NOTICE` is set and read only in Task 3. The `rotated` event keys (`ts`, `event`, `from`, `to`, `reason`, `handoff`) match `_timeline_rotated` at `lib/40-state.sh:99`.

**One risk the plan cannot retire.** Task 1 Step 5 places the resolution block before the rebind block, which means `_handoff_is_unconsumed` must already be defined at that point — it is, since Step 4 puts it with the other helpers near the top. An implementer who instead defines it lower will get a "command not found" that `2>/dev/null` inside the helper will *not* mask, so it fails loudly rather than silently returning non-zero. Confirm the ordering when applying Step 4.
