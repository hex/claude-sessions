# Conversation rotation + handoff lineage — design

Date: 2026-07-16
Status: pending spec review
Decision trail: ranked #5 in the four-provider council deep-research on cs
capability gaps — the council's outlier insight: a session is not a
conversation. Long sessions accumulate many Claude Code conversations (this
dev session's project dir holds 62 transcripts) with no lineage: cs records
exactly one UUID, rebinds silently when Claude Code forks a new one at the
context limit, and offers no first-class "this conversation is full,
continue fresh with context" operation. Research verified against the
installed CC 2.1.211 bundle (brief: .superpowers/sdd/f5-research.md).
Brainstormed with Alex 2026-07-16: v1 = lineage ledger + deliberate
rotation flow, full handshake, tracked handoff store, context nudge at 80%.

## Context and goal

Rotation already happens to every long-lived session: Claude Code forks a
new session UUID when a conversation is continued past the context limit,
users decline resumes, resumes fail. cs's SessionStart hook detects each
UUID change and rebinds `.cs/local/state` — then records the old link only
as one line in the machine-local, untracked `session.log`. Deliberate
rotation exists only as Alex's personal `/handoff` + `/pickup` prompt
commands: manual, unlinked to session UUIDs, stored in an unclassified
location. The goal is to make conversation lineage durable and rotation
first-class: every rotation (implicit or deliberate) becomes a tracked
timeline event, a view renders the conversation chain, and a deliberate
rotate path carries a lineage-stamped handoff from the dying conversation
into the fresh one.

## Decisions (approved by Alex 2026-07-16)

1. **v1 scope = lineage ledger + rotation flow** (both halves, one
   feature): rotated events + conversations view + the deliberate rotate
   handshake. Ledger-only and flow-only were considered and rejected —
   observation without the rotate verb skips the council's actual ask, and
   rotation without the ledger produces links nobody can see.
2. **Full handshake UX**: in-conversation, Claude writes a lineage-stamped
   handoff on request; at the next launch an unconsumed handoff surfaces a
   Rotate option — fresh UUID plus SessionStart injection. (A handoff can
   only be written while the old conversation is alive; the launch prompt
   can only consume, never create.)
3. **Context nudge at 80%**, once per conversation, via the existing Stop
   hook. Default 80 because CC's own `/context` panel warns at 80% and
   auto-compact fires at ~83.5% of a 200k window — the nudge must land
   while there is still budget to write a good handoff. Env override
   `CS_ROTATE_NUDGE_CTX` (the `CS_QUEUE_MAX_*` convention) because it is
   unverified whether the statusline's `used_percentage` is computed
   against the raw or the autocompact-effective window.
4. **Handoffs live in `.cs/handoffs/`, tracked** — shared across machines
   and actors like plans and narratives; lineage frontmatter inside each
   file. Alex's personal `/handoff` command and its `.claude/handoffs/`
   store stay untouched.

## Non-goals

- No `--fork-session` use: it copies the parent transcript, so the child
  is born as full as the parent — a branching primitive, not rotation.
- No `--resume-session-at` use (hidden flag, print-mode caveat, unverified
  in interactive mode).
- No changes to Alex's personal `/handoff` / `/pickup` commands or their
  `.claude/handoffs/` store.
- No auto-rotation: the nudge suggests; the user decides. cs never ends or
  restarts a conversation on its own.
- No TUI surface: no picker column, no conversation count in cs-tui.
- No fork-tree rendering: the view shows the linear chain of this
  session's conversations; `forkedFrom` message stamps and branch
  topologies are out of scope.
- No PreCompact/PostCompact hook subscriptions in v1 (candidate follow-up:
  a `compacted` timeline event).

## Design

### The `rotated` timeline event

One new event type in the existing tracked `timeline.jsonl` (merge=union,
same `jq -nc` append discipline as `started`/`ended`):

```json
{"ts":"<ISO-8601 UTC>","event":"rotated","from":"<old-uuid>","to":"<new-uuid>","reason":"<reason>","handoff":"<filename>"}
```

- `reason` enum: `handoff` (deliberate rotation), `declined-resume` (user
  answered No at the Continue prompt), `resume-failed` (the <3s resume
  fallback), `rebind` (SessionStart discovered a UUID change it did not
  cause — CC's context-limit fork, or a manual `claude --resume` of a
  different conversation).
- `handoff` is present only for `reason: handoff` — the consumed file's
  basename.
- `from` may be an empty string when no UUID was recorded (degenerate but
  legal; the view renders it as `?`).

Two emitters, each recording only what it knows first-hand:

1. **`_exec_fresh_rebind` (lib/40-state.sh)** gains a `reason` argument
   (and an optional handoff filename): it reads the old UUID before
   overwriting state and appends the event. Its two existing callers
   (declined resume, resume-failed fallback — lib/75-launch.sh) pass their
   reasons; the new rotate path passes `handoff` + the filename.
2. **hooks/session-start.sh** appends `reason: rebind` in the existing
   mismatch branch (recorded != live), beside the current session.log
   line. No double emission is possible: the launch paths pre-write state,
   so the hook's mismatch test is false after any launch-side rebind.

### Handoff store: `.cs/handoffs/`

- Files: `YYYY-MM-DD-<slug>.md`, the same naming as Alex's `/handoff`
  artifacts. Body follows the same 7-section continuation-plan format
  (primary intent, key concepts, files and code, problem solving, pending,
  current work, next step).
- Frontmatter is the lineage contract:

```yaml
---
parent: <conversation-uuid>
created: <ISO-8601 UTC>
purpose: <one line>
status: unconsumed | consumed
consumed_by: <conversation-uuid>   # set on consumption
---
```

- Tracked (no gitignore change needed — `create_session_gitignore`
  excludes only `.cs/local/` and friends). Whole-file markdown: no merge
  attribute; concurrent edits are human conflicts, left alone per the
  multi-user law.

### In-conversation half: the `rotate` skill

A new cs-shipped skill `skills/rotate/SKILL.md`, installed the same way as
`store-secret` (install.sh wiring), plus a one-line mention in the session
CLAUDE.md template (lib/35-claudemd.sh — the store-secret precedent) so
sessions know rotation exists. The skill instructs Claude to:

1. Require a purpose (ask if absent — the `/handoff` rule).
2. Write the handoff to `.cs/handoffs/YYYY-MM-DD-<slug>.md`: lineage
   frontmatter (parent = the live conversation UUID from
   `$CS_CLAUDE_SESSION_ID`, falling back to `.cs/local/state`), `status:
   unconsumed`, then the 7-section body distilled from the conversation.
3. Commit the handoff (it is tracked session state, like narratives).
4. Tell the user: exit this conversation, run `cs <session>`, and choose
   `r` at the prompt.

The skill never touches `state`, never emits events, never kills the
conversation — writing the artifact is its entire job.

### Launch half: the three-way prompt (lib/75-launch.sh)

- With no unconsumed handoff, the existing prompt is byte-for-byte
  unchanged: `Continue previous conversation? [Y/n]` (Hyrum guard).
- When `.cs/handoffs/` contains at least one `status: unconsumed` file,
  the prompt becomes:

```
Rotation handoff pending: 2026-07-16-<slug>.md
Continue previous conversation? [Y/n/r]  (r = fresh conversation with handoff)
```

- `r` (case-insensitive) → the rotate path: write the newest unconsumed
  handoff's basename to `.cs/local/pending-handoff`, then
  `_exec_fresh_rebind "$session_dir" handoff "<basename>"` (event emitted
  with both UUIDs, fresh `--session-id` exec as today).
- `Y`/`n` behave exactly as today (the pending handoff stays unconsumed;
  the notice line is the only addition).
- Multiple unconsumed handoffs: the lexicographically last filename wins
  for `r` (the `YYYY-MM-DD-` prefix makes that the newest date; same-day
  ties fall to slug order, which is acceptable); the notice names it.
  Older ones remain until consumed or deleted by hand.

### Consumption: hooks/session-start.sh

In the same hook, after the existing rebind/bind logic: if
`.cs/local/pending-handoff` exists and names a file present in
`.cs/handoffs/`:

1. Splice into the hook's `additionalContext` (append to the existing
   payload, never replace — the F4 digest rule): a rotation preamble
   instructing Claude to read `.cs/handoffs/<file>` FIRST and continue per
   its next-step section. The hook injects the instruction and path, not
   the file body (handoffs can be large; the read costs one tool call in
   the new conversation).
2. Flip the frontmatter `status: unconsumed` → `consumed` and set
   `consumed_by: <live uuid>` (awk in-place via tmp+mv, the hook's
   existing atomic-write pattern).
3. Remove `.cs/local/pending-handoff`.

A stale marker naming a missing file is removed silently (the launch and
the hook run on the same machine by construction — launch execs claude —
so the marker is machine-local state with a one-exec lifespan).

### Context nudge (hooks/narrative-reminder.sh)

In the Stop hook's non-queue path, after the narrative check: if
`context-pct` ≥ `CS_ROTATE_NUDGE_CTX` (default 80; non-numeric override
falls back, the F4 defensive-parse rule) and `.cs/local/rotate-nudged`
does not name the live conversation UUID, append one informational line to
the Stop feedback — context percentage, the suggestion to invoke the
`rotate` skill, and what rotation does — then write the live UUID to
`rotate-nudged`. Once per conversation; never blocks; missing or
non-numeric `context-pct` never fires.

### The view: `cs -conversations`

New verb (both dispatch sites in lib/99-main.sh at 8-space indent, both
completion files, show_help entry without backticks, README section).
Reads `timeline.jsonl` via jq, renders the conversation chain
oldest-first in local time (the `cs -queue log` presentation rule):

```
2026-02-07 09:58  0ab8fcfa  started (startup, resumed 12x)
2026-07-14 21:40  0ab8fcfa > 768dbfbe  rotated (rebind)
2026-07-14 21:40  768dbfbe  started (startup, resumed 5x)
2026-07-16 14:30  768dbfbe > 3f2ab1c0  rotated (handoff: 2026-07-16-continue-f5.md)
2026-07-16 14:30  3f2ab1c0  started (startup)  [current]
```

- One line per conversation's first `started` event; one line per
  `rotated` event with the from > to arrow and reason (plus handoff
  basename when present); repeated resumes of the same UUID are folded
  into a ` resumed Nx` suffix on the conversation's line rather than N
  rows.
- The UUID recorded in `.cs/local/state` gets the `current` marker.
- Missing or event-free timeline prints `No conversation history
  recorded.`
- Read-only: never writes, never advances anything.

### Documentation

- README: new Conversation rotation section (verb, skill, prompt change,
  nudge, env override).
- docs/session-layout.md: `.cs/handoffs/` added to the shared table;
  `pending-handoff` and `rotate-nudged` added to the machine-local table;
  `rotated` added to the timeline event list.
- docs/hooks.md: session-start consumption step and the Stop-hook nudge.

## Storage classification (multi-user law)

- `.cs/handoffs/*.md` — **tracked, shared**: whole-file markdown, no merge
  attribute, human conflicts left alone (the plans/checkpoints class).
- `rotated` events — ride the existing **tracked** `timeline.jsonl`
  (merge=union already set by setup_merge_attributes; append stream).
- `.cs/local/pending-handoff` — **machine-local** marker, one-exec
  lifespan (written by launch, consumed by the SessionStart it execs).
- `.cs/local/rotate-nudged` — **machine-local**, per-conversation nudge
  cursor.
- No dates from the local clock in tracked files beyond the existing
  `date -u` ISO stamps that timeline.jsonl already uses.

## Testing (TDD, vertical slices — tests/test_rotation.sh)

Driving hooks with stdin JSON + env and bin/cs with a stubbed
`CLAUDE_CODE_BIN`, the tests/test_hooks.sh and launch-test patterns. Every
assert carries `|| return 1`.

1. **Event emission, launch side**: declined resume (`echo "n" |`) writes
   a `rotated` event with reason `declined-resume`, `from` = old UUID,
   `to` = the new UUID now in state; the resume-failed fallback (stub
   exits 1 fast) writes reason `resume-failed`.
2. **Event emission, hook side**: SessionStart with a live `.session_id`
   differing from recorded state appends reason `rebind` with both UUIDs;
   matching UUIDs append nothing; `CS_FRESH_REBIND=1` with matching state
   appends nothing (no double emission).
3. **Three-way prompt**: with an unconsumed handoff fixture, the prompt
   names it and accepts `r` → state holds a fresh UUID,
   `pending-handoff` names the fixture, the `rotated` event carries
   reason `handoff` + the basename, the stub received `--session-id`;
   `Y` and `n` leave the handoff unconsumed. With no handoff the prompt
   output is byte-identical to today's (golden assert).
4. **Consumption**: SessionStart with `pending-handoff` set → context
   output mentions the handoff path, frontmatter flips to `consumed` with
   `consumed_by` = live UUID, marker removed; existing additionalContext
   is spliced, not replaced; stale marker (missing file) is removed
   silently with no flip and no injection.
5. **Multiple handoffs**: two unconsumed fixtures → newest is named and
   consumed; the older stays unconsumed.
6. **Nudge**: `context-pct` at 80 → Stop feedback contains the rotation
   suggestion once; a second Stop with the same UUID stays silent; a new
   conversation UUID re-arms it; 79 stays silent; missing/non-numeric
   `context-pct` stays silent; `CS_ROTATE_NUDGE_CTX=90` moves the line;
   non-numeric override falls back to 80.
7. **`cs -conversations`**: fixture timeline (started + rotated mix)
   renders the chain with arrows, reasons, fold count, and the current
   marker; empty timeline prints the empty message; the verb appears in
   both completion files (drift guard) and in help.
8. **Frontmatter robustness**: a handoff whose purpose contains quotes and
   `$()` survives write/flip/render untouched.

Full gates: `bash tests/run_all.sh` + `cd tui && cargo test` (regression
only — no TUI changes).

## Risks

- **Dual emitters for one event type**: the jq append recipe for `rotated`
  exists in bin/cs (`_exec_fresh_rebind`) and hooks/session-start.sh —
  hooks cannot source bin/cs, so the duplication is the documented
  standing constraint (same as F4's inbox writers). The event shape above
  is the shared contract.
- **Tracked-file status flip**: consumption edits `.cs/handoffs/<file>` on
  one machine; if another machine rotates the same handoff concurrently,
  the conflict is a human merge (whole-file markdown, per the law). Low
  likelihood — a handoff targets the machine where the session lives.
- **context-pct window ambiguity**: whether 80 stamped means 80% of raw or
  effective window is unverified; the env override is the escape hatch,
  and the nudge is informational, so miscalibration costs annoyance, not
  breakage.
- **Prompt surface**: the two-way prompt is byte-frozen when no handoff is
  pending; the three-way variant is new surface only in the pending case.
  The golden assert in test 3 enforces the freeze.
- **Skill compliance is prompt-level**: the rotate skill cannot force
  Claude to write correct frontmatter; the launch side is defensive —
  files without `status: unconsumed` are simply not offered, and a
  malformed frontmatter file is ignored (never crashes the prompt).
- **Hyrum**: `timeline.jsonl` consumers (fuse_session_records, the
  worktree merge append) treat it as opaque lines — a new event type is
  additive and safe; `cs -conversations` is the only reader that parses
  `rotated`.
