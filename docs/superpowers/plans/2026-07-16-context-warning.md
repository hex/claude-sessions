# 60% Context Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-time in-conversation heads-up (Stop-hook block) when context enters the [60, 80) band, below the existing 80% rotation nudge.

**Architecture:** One new block in `hooks/narrative-reminder.sh`, placed after the rotation nudge block so it reuses the nudge's already-computed `NUDGE_PCT`/`NUDGE_UUID`/`NUDGE_CTX` variables and inherits the queue-yield property (armed/draining queue branches exit earlier). Cursor file per conversation UUID, mirroring `rotate-nudged`. Spec: `docs/superpowers/specs/2026-07-16-context-warning-design.md`.

**Tech Stack:** bash 3.2 + BSD userland, jq, existing `tests/test_rotation.sh` harness.

## Global Constraints

- Everything runs on stock macOS `/bin/bash` 3.2 with BSD userland; hooks are standalone scripts under `set -euo pipefail` (no sourcing `bin/cs`). BSD grep: no `\|` alternation in test patterns — use two separate `grep -q` calls.
- Threshold override: `CS_CTX_WARN_CTX`, default 60, parsed with the hook's existing `_num_or` (non-numeric falls back to the default).
- Band condition exactly: fires when `pct >= CS_CTX_WARN_CTX && pct < NUDGE_CTX` (the effective rotate-nudge threshold computed above the block). Never fires at or above the nudge threshold. An empty band via overrides means it never fires — no guard.
- Cursor: `.cs/local/ctx-warned`, conversation UUID, written atomically (`.tmp` + `mv`), exactly like `rotate-nudged`.
- Copy frozen (the "80%" is intentionally the literal default, not interpolated):
  `Context is at ${NUDGE_PCT}% — past the comfortable-headroom mark. Briefly let the user know so they can steer toward a natural stopping point or plan a rotation; the rotate nudge follows at 80%. One-time notice for this conversation; no action needed now.`
- Emit via `jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'` then `exit 0`.
- The warning block MUST sit below the rotation nudge block (it consumes its variables) and above the `COOLDOWN_FILE=` narrative section.
- Test discipline: every assert `|| return 1`; env overrides unset on every return path; new cycle section inserts immediately before `report_results` (functions + their `run_test` lines together, matching the file's per-cycle registration style); full-UUID-shaped ids only (use the existing `UUID_A`/`UUID_B`).
- `bin/cs` untouched; do not run `./build.sh`. Deploy surface (merge-gate concern, not a task): `~/.claude/hooks/cs/narrative-reminder.sh`.

---

### Task 1: Warning block in narrative-reminder.sh

**Files:**
- Modify: `hooks/narrative-reminder.sh` (between the rotation nudge block's final `fi` and the `COOLDOWN_FILE=` line, ~line 210)
- Test: `tests/test_rotation.sh` (new Cycle 8 section immediately before `report_results`)

**Interfaces:**
- Consumes: `_num_or` (hook helper), `NUDGE_PCT` (digits-only context reading or empty), `NUDGE_UUID` (conversation UUID or empty), `NUDGE_CTX` (effective nudge threshold) — all set unconditionally by the nudge block above; `$QDIR` (the session's `.cs/local`). Test side: `_rot_hook_session`, `_stop_with_ctx`, `UUID_A`, `UUID_B` from `tests/test_rotation.sh`.
- Produces: the `.cs/local/ctx-warned` cursor file; nothing later tasks rely on programmatically.

- [ ] **Step 1: Write the failing tests**

In `tests/test_rotation.sh`, insert immediately BEFORE the final `report_results` line (after the last existing `run_test` line):

```bash
# ============================================================================
# Cycle 8: context warning (Stop hook, [warn, nudge) band)
# ============================================================================

test_ctx_warning_fires_once_in_band() {
    _rot_hook_session "rot-warn"
    local out
    out=$(_stop_with_ctx 60 "$UUID_A") || return 1
    assert_output_contains "$out" '"decision":"block"' "warning delivered as a block" || return 1
    assert_output_contains "$out" "Context is at 60%" "warning names the reading" || return 1
    assert_output_contains "$out" "natural stopping point" "warning carries the frozen copy" || return 1
    assert_eq "$UUID_A" "$(cat "$CLAUDE_SESSION_META_DIR/local/ctx-warned" | tr -d '[:space:]')" \
        "cursor records the warned conversation" || return 1
    out=$(_stop_with_ctx 60 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: same conversation must not be warned twice"
        return 1
    fi
}

test_ctx_warning_rearms_for_new_conversation() {
    _rot_hook_session "rot-warn-rearm"
    _stop_with_ctx 60 "$UUID_A" >/dev/null || return 1
    local out
    out=$(_stop_with_ctx 60 "$UUID_B") || return 1
    assert_output_contains "$out" "stopping point" "new conversation UUID re-arms the warning" || return 1
}

test_ctx_warning_silent_below_band() {
    _rot_hook_session "rot-warn-low"
    local out
    out=$(_stop_with_ctx 59 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: 59 must not warn at default threshold"
        return 1
    fi
}

test_ctx_warning_yields_to_nudge_at_high_ctx() {
    _rot_hook_session "rot-warn-high"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" "rotate skill" "nudge owns readings at its threshold" || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: warning must not fire at or above the nudge threshold"
        return 1
    fi
    out=$(_stop_with_ctx 85 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: after the nudge, the warning may not fire"
        return 1
    fi
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: after the nudge, the nudge may not fire again"
        return 1
    fi
}

test_ctx_warning_threshold_override() {
    _rot_hook_session "rot-warn-env"
    export CS_CTX_WARN_CTX=70
    local out
    out=$(_stop_with_ctx 65 "$UUID_A") || { unset CS_CTX_WARN_CTX; return 1; }
    if printf '%s' "$out" | grep -q "stopping point"; then
        unset CS_CTX_WARN_CTX
        echo "  FAIL: 65 under a 70 override must not warn"
        return 1
    fi
    out=$(_stop_with_ctx 70 "$UUID_A") || { unset CS_CTX_WARN_CTX; return 1; }
    unset CS_CTX_WARN_CTX
    assert_output_contains "$out" "stopping point" "70 at a 70 override warns" || return 1
    _rot_hook_session "rot-warn-env2"
    export CS_CTX_WARN_CTX=banana
    out=$(_stop_with_ctx 60 "$UUID_B") || { unset CS_CTX_WARN_CTX; return 1; }
    unset CS_CTX_WARN_CTX
    assert_output_contains "$out" "stopping point" "non-numeric override falls back to 60" || return 1
}

run_test test_ctx_warning_fires_once_in_band
run_test test_ctx_warning_rearms_for_new_conversation
run_test test_ctx_warning_silent_below_band
run_test test_ctx_warning_yields_to_nudge_at_high_ctx
run_test test_ctx_warning_threshold_override
```

`report_results` stays the file's last line. Note the fixture logic in `test_ctx_warning_yields_to_nudge_at_high_ctx`: the first Stop at 80 exercises the nudge-wins branch; the second Stop at 85 with the same UUID proves neither tier fires after the nudge's cursor is set (85 is outside the warning band, and the nudge is once-per-conversation).

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `/bin/bash tests/test_rotation.sh`
Expected: all existing tests PASS; `test_ctx_warning_fires_once_in_band`, `test_ctx_warning_rearms_for_new_conversation`, and `test_ctx_warning_threshold_override` FAIL (no warning block exists, so the block/copy asserts fire). `test_ctx_warning_silent_below_band` and `test_ctx_warning_yields_to_nudge_at_high_ctx` PASS pre-implementation — they pin behavior that must stay true (silence below the band; nudge precedence), and can only regress after the block lands. Confirm exactly this RED pattern (3 failing) and note it in your report.

- [ ] **Step 3: Implement the warning block**

In `hooks/narrative-reminder.sh`, the rotation nudge block ends with:

```bash
        REASON="Context is at ${NUDGE_PCT}% — consider rotating this conversation. Invoke the rotate skill to distill a handoff into .cs/handoffs/; the user can then reopen the session and answer r for a fresh conversation that continues from it. One-time notice for this conversation; if now is a bad time, simply continue."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi

COOLDOWN_FILE="$META_DIR/.narrative-reminder-cooldown"
```

Insert between that final `fi` and the `COOLDOWN_FILE=` line (blank line on each side):

```bash
# --- Context warning ----------------------------------------------------------
# One-time heads-up when context crosses the wind-down band [warn, nudge).
# At or above the nudge threshold the rotation nudge above owns the turn;
# this tier never fires there. Cursor: conversation UUID last warned.
WARN_CTX=$(_num_or "${CS_CTX_WARN_CTX:-}" 60)
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] \
    && [ "$NUDGE_PCT" -ge "$WARN_CTX" ] && [ "$NUDGE_PCT" -lt "$NUDGE_CTX" ]; then
    WARNED=$(cat "$QDIR/ctx-warned" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$WARNED" != "$NUDGE_UUID" ]; then
        printf '%s\n' "$NUDGE_UUID" > "$QDIR/ctx-warned.tmp" \
            && mv "$QDIR/ctx-warned.tmp" "$QDIR/ctx-warned"
        REASON="Context is at ${NUDGE_PCT}% — past the comfortable-headroom mark. Briefly let the user know so they can steer toward a natural stopping point or plan a rotation; the rotate nudge follows at 80%. One-time notice for this conversation; no action needed now."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi
```

- [ ] **Step 4: Run the suite to verify everything passes**

Run: `/bin/bash tests/test_rotation.sh`
Expected: all tests PASS (31 existing + 5 new). Then run the neighbor suite that also exercises this hook's queue branches: `/bin/bash tests/test_queue_supervision.sh` — expected PASS (the new block sits below the queue branches and must not disturb them).

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_rotation.sh
git commit -m "feat: one-time context warning in the [60,80) band below the rotate nudge"
```

---

### Task 2: Documentation

**Files:**
- Modify: `docs/hooks.md` (the narrative-reminder bullet list, directly after the "Rotation nudge:" bullet)
- Modify: `README.md` (the paragraph beginning `Past 80% context, the narrative-reminder Stop hook nudges once per`, ~line 293)

**Interfaces:**
- Consumes: the behavior shipped in Task 1 (band semantics, override name, cursor path).
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Add the hooks.md bullet**

In `docs/hooks.md`, immediately after the bullet that begins `- Rotation nudge: when context is at or above \`CS_ROTATE_NUDGE_CTX\``, insert:

```markdown
- Context warning: one tier below the nudge — when context is in the `[CS_CTX_WARN_CTX, CS_ROTATE_NUDGE_CTX)` band (defaults 60 to 80; a non-numeric override falls back to its default) and this conversation hasn't been warned (`.cs/local/ctx-warned`, keyed on conversation UUID), emits a one-time `block` telling Claude to let the user know context crossed into wind-down territory. At or above the nudge threshold only the rotation nudge fires — never both in one Stop
```

- [ ] **Step 2: Extend the README paragraph**

In `README.md`, the paragraph

```markdown
Past 80% context, the narrative-reminder Stop hook nudges once per
conversation to invoke the rotate skill (`CS_ROTATE_NUDGE_CTX` overrides the
threshold; a non-numeric value falls back to 80). The nudge yields to an
armed or draining task queue, which owns the turn loop while it runs.
```
becomes
```markdown
At 60% context, the narrative-reminder Stop hook surfaces a
once-per-conversation heads-up so you can steer toward a natural stopping
point (`CS_CTX_WARN_CTX` overrides it; the warning stays silent at or above
the nudge threshold, where rotation takes over). Past 80% context, the same
hook nudges once per conversation to invoke the rotate skill
(`CS_ROTATE_NUDGE_CTX` overrides the threshold; a non-numeric value falls
back to 80). Both tiers yield to an armed or draining task queue, which
owns the turn loop while it runs.
```

- [ ] **Step 3: Verify the suite still passes and commit**

Run: `/bin/bash tests/test_rotation.sh`
Expected: PASS (docs only; a failure means an accidental code edit).

```bash
git add docs/hooks.md README.md
git commit -m "docs: context warning tier beside the rotation nudge"
```
