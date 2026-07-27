# In-process rotation via /clear — design

Date: 2026-07-27
Status: pending spec review
Decision trail: Alex asked whether the rotate flow's four manual steps
(invoke rotate, exit Claude Code, relaunch `cs <name>`, press `r`) could be
automated. They cannot be fully automated — Claude Code exposes no way for
the model to exit its own process or to type a slash command into its own
input, so something outside the model must always act. But three of the four
steps turn out to be unnecessary: `/clear` is itself a rotation, and cs's
handoff machinery already runs on that SessionStart source. Design reviewed
adversarially by Fable 2026-07-27, which returned "not safe as specified";
its blocking finding killed the original Phase 2 and four more findings are
folded in below. Verified against the installed CC 2.1.220 bundle.

## Context and goal

Rotation today is a process-restart protocol. The `rotate` skill writes a
lineage-stamped handoff to `.cs/handoffs/`; the next `cs <name>` launch scans
for `status: unconsumed` frontmatter and offers `[Y/n/r/d]`; the `r` answer
writes the handoff basename to `.cs/local/pending-handoff` and calls
`_exec_fresh_rebind`, which allocates a new UUID and `exec`s claude; the
SessionStart hook then consumes the marker and injects a preamble pointing
the fresh conversation at the handoff.

The `r` keypress exists for exactly one purpose: to write one marker file.
Everything downstream of it is driven by that file, and everything upstream
of it — exiting, relaunching — exists only to reach a launch prompt that can
ask the question.

Two facts make the restart avoidable:

1. `/clear` ends the conversation, allocates a fresh UUID, and fires
   SessionStart with `source: "clear"` — all inside the running process.
   Confirmed in the bundle: `yield{type:"conversation_reset",
   newConversationId:randomUUID()}` followed by the hook runner call, and
   `source: E.enum(["startup","resume","clear","compact","fork"])`.
2. The handoff-consumption block (`hooks/session-start.sh:431-455`) and the
   UUID rebind block (`:248-295`) both sit *after* the `startup|resume` guard
   that closes at line 201, so they already run on every source — including
   `clear`.

The goal: make rotation an in-process operation. `rotate` arms the marker,
`/clear` completes it. Two steps, no restart. The exit → relaunch → `r`
route stays working for users who are quitting anyway.

## The finding that shaped the design

The original design had a second phase: emit `initialUserMessage` from the
SessionStart hook so the post-rotation conversation acts on turn one without
waiting for the user, and drop the launcher's positional `handoff_arg` so the
hook became the single owner of that kick on both paths.

**This is a verified no-op on the `/clear` path in CC 2.1.220.** The hook
runner stores the field in a module global (`if(p.initialUserMessage)
PAs=p.initialUserMessage`). That global has exactly one reader in the whole
245MB bundle — `function Cnd(){let e=PAs;return PAs=void 0,e}`, called from
`let N=Cnd();if(N)y.prependUserMessage(N)` in the REPL bootstrap, once per
process. The `/clear` path is `let A=await xBe("clear");if(A.length>0)
e(()=>A)`: it consumes `additionalContext` only. An `initialUserMessage`
emitted on `source: clear` is written and never read. It does not error and
does not warn.

Shipping that phase would have produced a rotation that silently does nothing
on its primary path, while every shell-level test passed — and, because the
same phase removed `handoff_arg`, it would have taken the launcher path's
working kick with it.

Phase 2 is therefore dropped in full. `additionalContext` *is* delivered on
`clear` (same call site), so the preamble arrives; the fresh conversation
simply waits for the user's next message instead of acting immediately. That
is the accepted cost. Re-evaluate only if a future CC version reads
`initialUserMessage` on `source: clear` — re-grep the bundle before assuming
it does.

## Decisions (approved by Alex 2026-07-27)

1. **`/clear` is the recommended rotation route**; exit → relaunch → `r`
   remains supported and documented as the alternative.
2. **Phase 2 dropped entirely** — no `initialUserMessage`, and
   `handoff_arg` stays in `_exec_fresh_rebind`.
3. **One predicate, evaluated once.** The marker's fate is decided in a
   single place; the rebind labeller and the consumer both read the result.
4. **A pre-existing bug in the blast radius gets fixed in the same pass**
   (the `CS_FRESH_REBIND` preamble firing on `/compact`).
5. Two extras included: superseding stale handoffs, and hardening the
   already-running guard.

## Design

### The rotation predicate

Today consumption gates on *marker present + file exists*. That was safe when
the marker lived for milliseconds between the `r` keypress and the exec'd
startup. Arming it from the skill makes its lifetime unbounded — a turn, a
day, a `git pull` from another machine — so the predicate must be complete:

    consume  ⇔  SOURCE ∈ {startup, clear}
                ∧ marker present
                ∧ named handoff file exists
                ∧ its frontmatter status is exactly `unconsumed`

The status check reuses the frontmatter-scoped awk already at
`lib/75-launch.sh:217-225`, which walks line 1's `---` to the closing `---`
so a body quoting the contract line flush-left cannot match. Without it, a
handoff consumed on another machine and pulled in here would still inject
"continue per this handoff" while the status flip silently no-ops and the
timeline records a second rotation for the same file.

Two distinct failure modes, two different responses:

| Predicate fails on | Meaning | Action |
|---|---|---|
| `status` / file missing | The marker is **stale** — its handoff is spent | Remove the marker silently. No preamble, no flip, no event label. |
| `SOURCE` | The marker is **fine, this is just not the moment** | Leave it armed, and skip the staleness check entirely. A compaction or context-fork between `rotate` and `/clear` must not eat it. |

Order matters: `SOURCE` is tested first. On a non-allow-listed source nothing
about the marker is inspected or changed, so a stale marker simply survives
until the next `startup` or `clear` removes it — harmless, and it keeps the
"not the moment" case from needing to reason about file state at all.

This distinction is the whole reason `compact` and `fork` are excluded rather
than treated as consumption points. On `compact` the transcript *is* still
loaded, so injecting "the prior transcript is not loaded; read the handoff
first" would be actively false; but the user's pending rotation is still
legitimate, so the marker survives to the `/clear` that follows.

`resume` is excluded too. No path legitimately consumes there: the launcher
disarms the marker on every non-`r` answer, and an in-app `/resume` is a
continuation, not a rotation.

Evaluating the predicate **once**, early — after `SOURCE` and `META_DIR`
resolve, before the rebind block — and storing the outcome in a variable both
later blocks read, is what keeps the labeller and the consumer from
diverging. Applying "the same predicate" twice in two places is the version
of this that rots.

### Timeline labelling

`_timeline_rotated` (`lib/40-state.sh:99`) emits
`{ts, event:"rotated", from, to, reason}` plus a conditional `handoff` field.
On the launcher `r` path the launcher emits it directly and writes the new
UUID to state before exec, so the hook's rebind block sees no change and does
not double-fire.

The `/clear` path has no launcher, so the hook's rebind block is the sole
emitter — and today it would label a deliberate rotation as a bare
`reason: "rebind"`, losing the handoff name in `cs -conversations`. It reads
the pre-computed predicate result: true → `reason: "handoff"` with the name;
false → `reason: "rebind"` as now.

Gating on the full predicate rather than on marker-presence is what stops a
context-limit fork (which fires the rebind block while consumption is
correctly skipped) from stamping a handoff event for a rotation that never
happened — and then a second one when the real `/clear` lands.

### Arming, and disarming

The skill writes the basename to `.cs/local/pending-handoff` after committing
the handoff, then tells the user to run `/clear`. The marker is machine-local
state under `.cs/local/`; the skill's commit step must not sweep it in.

The skill's opening contract — "never edits `.cs/local/state`, and never
launches anything ... This skill only WRITES the handoff" — no longer holds
and is rewritten rather than quietly falsified.

Disarming is the mirror hazard. Rotate, quit without clearing, answer `Y` the
next morning: the marker must go, or the resumed conversation is told its
transcript isn't loaded. But a *silent* removal creates the trap in reverse —
the user later runs `/clear`, the route they were told to use, and gets a
plain fresh conversation while the handoff stays pending forever. So the
launcher removes the marker on every answer except `r`, **unconditionally**
(not nested inside the `[ -n "$pending_handoff" ]` arms, which would leave a
marker whose handoff was consumed elsewhere uncleaned) and **including the
unattended `cs -spawn` default at `lib/75-launch.sh:230-231`** — and prints a
one-line notice when a marker actually existed.

### Fresh-conversation notice (pre-existing bug)

`_exec_fresh_rebind` exports `CS_FRESH_REBIND=1` before `exec`
(`lib/40-state.sh:145`), so it persists for the entire claude process. The
`elif` consuming it (`hooks/session-start.sh:465`) has no source gate.
Consequence today: any session launched via `n`, `r`, or a resume failure,
then `/compact`ed, is told *"the prior conversation's transcript is not
loaded ... Treat this as a clean break ... Do not assume continuity"* inside
a fully continuous conversation.

The notice fires when the conversation genuinely starts clean:
`SOURCE == clear`, or `SOURCE == startup` with `CS_FRESH_REBIND=1`. Never
otherwise. Adding `clear` unconditionally also fixes the converse gap — a
`/clear` of a session that was *not* launched via rebind currently gets no
such notice at all, and may assume continuity it doesn't have.

### Superseding stale handoffs

A second `rotate` overwrites the marker, so `/clear` consumes only the newest
— leaving the older handoff `unconsumed` forever. Every subsequent launch
then offers `[Y/n/r/d]` for stale context, and an absent-minded `r` rotates
into it. The launcher flow surfaced this immediately; the `/clear` flow
bypasses the launcher, so it lingers unseen. The skill flips its own prior
`unconsumed` handoffs to `superseded` before writing a new one.

### Already-running guard

`lib/75-launch.sh:68-74` matches the *recorded* UUID against `ps` argv. After
any `/clear` the recorded UUID is the post-clear one while the live process's
argv still shows `--session-id <old>`, so a second `cs <session>` passes the
guard and `--resume`s the live conversation — two processes on one
transcript. Pre-existing for `/clear` generally, but promoting `/clear` to
the recommended route makes it reachable in normal use. The guard also
matches the `--name` argument, with the match anchored so a session name that
prefixes another (`sym` vs `sym-comfy-nodes`) cannot false-positive.

## Testing

`tests/test_rotation.sh` currently drives the hook with `source: "startup"`
only (`_start_hook`, lines 314-317), so a wrong allow-list would pass
vacuously. The suite gains a source matrix and the state cases:

- consumes on `clear`; does not on `resume`, `compact`, `fork`
- marker **survives** `compact` and `fork` (armed, not eaten, not deleted)
- marker + already-`consumed` file → no preamble, no flip, marker removed
- each non-`r` answer disarms, including the spawn default, and says so
- `/clear` rotation records `reason: "handoff"` with the name; a fork with an
  armed marker records `reason: "rebind"` and no `handoff` field
- fresh-conversation notice present on `startup`+`CS_FRESH_REBIND` and on
  `clear`; absent on `compact`
- the skill documents `/clear` and supersedes prior handoffs

`assert_file_contains` is a BRE matcher, so bracket literals in any
`[Y/n/r/d]` pin must be escaped or the assertion is unpassable or vacuous.

CC's own handling of the hook output cannot be exercised from a shell test.
The end-to-end `/clear` rotation is verified by hand once, after deploy.

## Out of scope

- `initialUserMessage` and the single-owner kick (dead on `clear`; see above).
- Making `cs` a supervisor loop so it can relaunch itself after claude exits.
  It would remove "close cs / reopen / press r" but not "exit claude", which
  is the step the user cannot delegate anyway — strictly more work for less
  benefit than `/clear`. Worth revisiting only for the case where a rotation
  must pick up a newly built `cs` binary or changed hooks.
- Driving the restart with `tmux send-keys`. cs deliberately contains no
  `send-keys`; injecting keystrokes into a live TUI races the input state.

## Compatibility

All changes are bash 3.2 / BSD-userland safe: `case`-based source
allow-listing and reuse of the existing frontmatter awk. `hooks/session-start.sh`
line 20 already defaults a missing `source` to `startup`, so an older CC that
omits the field keeps working. No migration: an existing armed marker is
either consumed by the next `startup` (as today) or removed as stale.
