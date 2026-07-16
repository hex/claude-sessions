# 60% context warning — design

Date: 2026-07-16
Status: pending spec review
Decision trail: Alex, 2026-07-16 — "cs should warn users when they go above
60% context usage". Second of the three-feature post-batch arc. Shape
approved via AskUserQuestion: a NEW one-time in-conversation warning tier
below the existing 80% rotation nudge (chosen over retuning the existing
surfaces and over statusline-only emphasis; the statusline ctx segment
already colors amber at 50 and red at 80, and the rotate nudge Stop-blocks
once at 80). Design approved: [60,80) band, `CS_CTX_WARN_CTX` override,
`ctx-warned` cursor, verbatim copy below.

## Context and goal

The statusline shows context passively; the rotation nudge interrupts once
at 80% with a concrete action. Between "ambient color" and "rotate now"
there is no moment where the user actually learns their context crossed
into wind-down territory. The goal: one early, in-conversation heads-up at
60% so the user can steer toward a stopping point before the 80% nudge
demands an action. Two tiers: awareness at 60, action at 80.

## Decisions

1. **A second one-time Stop-block in `hooks/narrative-reminder.sh`**,
   placed immediately after the rotation nudge block. It therefore
   inherits the nudge's yield property: an armed or draining queue exits
   in the branches above and never reaches either tier, and the drain's
   own context breaker governs walk-away runs.
2. **Band condition, not shared state**: the warning fires only when
   `pct >= CS_CTX_WARN_CTX && pct < <effective rotate-nudge threshold>`.
   A conversation that jumps straight past 80 (large paste, hot resume)
   gets only the nudge — action supersedes awareness, never two
   interruptions back to back. A warning at 60 does not suppress the
   nudge at 80. Precedence lives in mutually exclusive ranges; neither
   tier reads the other's cursor, keeping them independently testable.
   The band compares against the same `NUDGE_CTX` value the nudge block
   computed (including any `CS_ROTATE_NUDGE_CTX` override); if overrides
   make the band empty (`CS_CTX_WARN_CTX >= NUDGE_CTX`), the warning
   simply never fires — documented, not guarded.
3. **Threshold override `CS_CTX_WARN_CTX`, default 60**, parsed with the
   hook's existing `_num_or` (non-numeric falls back to the default),
   matching `CS_ROTATE_NUDGE_CTX`'s convention.
4. **Cursor `.cs/local/ctx-warned`**: the conversation UUID last warned,
   machine-local, written atomically (tmp + mv) exactly like
   `rotate-nudged`. Same UUID never warned twice; a rotated (new-UUID)
   conversation re-arms.
5. **Copy, frozen** (Claude-facing, like the nudge; `NN` is the live
   reading):

   > Context is at NN% — past the comfortable-headroom mark. Briefly let
   > the user know so they can steer toward a natural stopping point or
   > plan a rotation; the rotate nudge follows at 80%. One-time notice
   > for this conversation; no action needed now.

   Emitted via `jq -nc --arg` as `{decision: "block", reason: ...}`, the
   only Stop-hook surface Claude sees. The "80%" in the copy states the
   default escalation tier; it is intentionally not interpolated from
   the override (copy stays frozen and testable).

## Behavior

In `hooks/narrative-reminder.sh`, after the rotation nudge block's closing
`fi` and before the `COOLDOWN_FILE=` line:

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

It reuses `NUDGE_PCT` (validated digits-only context reading), `NUDGE_UUID`
(conversation UUID), and `NUDGE_CTX` (effective nudge threshold) already
computed by the nudge block above — the warning block must stay below it.

## Out of scope

- Statusline threshold changes (amber stays at 50), rotate-nudge changes,
  queue-gate changes.
- No CLAUDE.md template text: the instruction to relay the warning lives
  in the block reason itself.
- No cursor cleanup: like `rotate-nudged`, a stale UUID is simply
  overwritten by the next conversation's warning.

## Testing

New cycle in `tests/test_rotation.sh` (it owns the `_stop_with_ctx`
Stop-simulation helper; a separate suite would duplicate it). All cases
use full-UUID-shaped ids, every assert `|| return 1`, registration above
`report_results`:

1. At 60 with a fresh UUID → `"decision":"block"`, reason contains
   `Context is at 60%` and `natural stopping point`; cursor
   `.cs/local/ctx-warned` records the UUID.
2. Second Stop, same UUID, still 60 → no warning text in output.
3. Same reading, new UUID → warns again.
4. At 59 → silent (below band).
5. At 80 → the ROTATE nudge fires (reason names the rotate skill), the
   warning does not; a following Stop at 85, same UUID → neither fires.
6. `CS_CTX_WARN_CTX=70`: 65 silent, 70 warns (override unset afterward,
   mirroring the existing nudge override test's hygiene).
7. Non-numeric `CS_CTX_WARN_CTX=abc`: 60 still warns (fallback).

## Files

- `hooks/narrative-reminder.sh` — the block above.
- `tests/test_rotation.sh` — the seven cases.
- `docs/hooks.md` — one bullet beside the rotation-nudge bullet.
- `README.md` — the rotation-nudge paragraph ("Past 80% context, ...",
  which documents `CS_ROTATE_NUDGE_CTX`) gains a leading sentence for the
  60% tier: a once-per-conversation heads-up, `CS_CTX_WARN_CTX` override,
  silent at or above the nudge threshold.

Deploy surface: `~/.claude/hooks/cs/narrative-reminder.sh`.
