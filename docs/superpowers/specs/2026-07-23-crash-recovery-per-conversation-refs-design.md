# Per-conversation autosave refs — design

**Date:** 2026-07-23
**Status:** approved (pending spec review)
**Predecessor:** PR #5 (`fix/crash-recovery-restore-safety`) — the data-safety half:
recovery refuses the blanket restore when HEAD has moved off the snapshot's
recorded `cs-base`. This spec covers the concurrency half.

## Problem

Every checkout shares **one** autosave ref, `refs/worktree/cs/auto`. All
conversations running on that checkout write to it, and crash recovery infers
"the previous session crashed" purely from that ref existing and differing from
HEAD — with no way to distinguish a dead session's leftovers from a live
sibling's in-flight work. Two consequences, both observed in the 2026-07-22
incident:

1. **False crash prompt.** A second conversation started on a checkout whose
   first conversation was still alive read the live sibling's ref and announced a
   crash that never happened.
2. **Protection-stripping.** Because the ref is shared and `session-end` deletes
   it unconditionally, whichever conversation exits first removes the other's
   crash protection, and interleaved autosave chains mean a restore could splice
   two conversations' work together.

## Goal / non-goals

**Goal:** concurrent conversations on one checkout never read, write, or delete
each other's autosave state, so the false prompt and the protection-stripping
are both structurally impossible.

**Non-goals:** surfacing a *dead* sibling's crashed work to a bystander
conversation (explicitly declined — it would reintroduce liveness detection).
Recovery of a crashed conversation happens when *that* conversation is reopened.

## Design

### Identity & namespace

Each conversation owns `refs/worktree/cs/session/<uuid>`, where `<uuid>` is the
live conversation UUID from the hook input's `session_id` (also exported as
`CS_CLAUDE_SESSION_ID`).

The namespace is deliberately **not** `refs/worktree/cs/auto/<uuid>`: git forbids
a ref named `auto` and a directory `auto/` from coexisting (a directory/file
conflict), so reusing that path would break every existing install on upgrade. A
fresh `.../session/<uuid>` namespace avoids the conflict and lets the legacy ref
drain during migration. `refs/worktree/*` is git's per-worktree ref namespace, so
these refs are already isolated per checkout and never pushed.

### Autosave (`autosave-commits.sh`)

- Read `session_id` from the hook input.
- Write snapshots to `refs/worktree/cs/session/<uuid>` instead of the shared
  `auto` ref.
- Keep the `cs-base: <HEAD>` commit trailer from PR #5 unchanged (recovery still
  needs it to gate the restore).
- Chains remain per-conversation (each snapshot chains onto that conversation's
  previous snapshot).

### Recovery (`session-start.sh`)

- On `startup`/`resume`, look **only** at `refs/worktree/cs/session/<uuid>` for
  the current conversation's UUID.
- If it exists and differs from HEAD, run the existing base-guarded recovery
  prompt from PR #5 (offer the self-verifying blanket restore only when the
  recorded base still matches HEAD; otherwise per-file guidance).
- Never enumerate or read another UUID's ref for recovery. This is what makes the
  false positive impossible.

### session-end (`session-end.sh`)

- Delete **only** `refs/worktree/cs/session/<uuid>` for the ending conversation.
- Remove the unconditional shared-ref deletion. A sibling's clean exit can no
  longer strip this conversation's protection.

### UUID rebind (context-fork)

Claude Code forks a new conversation UUID when a conversation is continued past
the context limit; `session-start.sh` already detects this (`RECORDED_UUID` !=
`SESSION_ID`) and records a `rotated` event. On that rebind, **rename** the old
UUID's session ref to the new UUID (`update-ref` new, delete old) so the
in-flight snapshot follows the live identity rather than being orphaned. A fork
is a clean continuation, not a crash.

### Migration from the legacy shared ref

On startup, if a legacy `refs/worktree/cs/auto` (or the pre-namespaced
`refs/cs/auto`) exists, **claim it once** into the current conversation's session
ref, then proceed with normal per-conversation recovery. The claim is race-safe
via a compare-and-swap delete: read the legacy ref's sha, then
`git update-ref -d <legacy-ref> <sha>` — the CAS delete succeeds for exactly one
racing conversation (the second's delete fails because the expected old value is
gone), and only that winner then creates its own session ref from the captured
sha. The base-HEAD guard still protects the resulting restore. This drains any
pre-upgrade ref within one session, after which all state is per-conversation.

### Garbage collection

On startup, enumerate `refs/worktree/cs/session/*` (`for-each-ref`, which lists
only the current worktree's per-worktree refs, so GC never reaches across
checkouts). For each ref whose UUID is **not** the current conversation's, if its
tip commit is older than 14 days (`git log -1 --format=%ct`), delete it. This
bounds orphan accumulation from conversations that crashed and were never
reopened, while keeping a two-week safety window for reopening a crashed
conversation. GC never touches the current conversation's own ref.

Accepted tradeoff: a sibling conversation left *open* for more than 14 days
without any Write/Edit (so its ref tip stops advancing) can have its ref pruned
by a peer conversation's startup GC. Reopening/editing that conversation
re-establishes the ref; the window is generous enough that this is not expected
in practice.

## Edge cases

- **Unborn HEAD / no index:** unchanged from today — autosave and recovery
  already fail safe (no ref written, recovery routes to refuse/skip).
- **Worktree isolation:** `refs/worktree/*` resolves per-worktree, so a base
  session and its feature worktrees keep independent session-ref sets already.
- **GC clock:** age is derived from the ref's own commit date (git), not local
  wall-clock assumptions; comparison is epoch subtraction (bash 3.2 / BSD safe).
- **Transition window:** during the upgrade, a pre-upgrade conversation may still
  hold the legacy shared ref while a post-upgrade conversation adopts it. The
  atomic rename serializes the adoption and the base guard prevents an unsafe
  restore; this is a one-time transition artifact, not a steady-state path.

## Testing plan

- Autosave writes to `refs/worktree/cs/session/<uuid>` (keyed on the hook's
  `session_id`), carrying the `cs-base` trailer.
- Two conversations (distinct UUIDs) autosaving on one checkout produce two
  independent refs; neither reads nor deletes the other's.
- Recovery for conversation A ignores conversation B's ref entirely (the
  false-positive regression test — the incident, reproduced).
- `session-end` for A deletes only A's ref; B's ref survives.
- UUID rebind renames A's ref to the new UUID; the snapshot is preserved and
  recoverable under the new identity.
- Legacy shared ref is claimed once at startup (CAS delete) into the current
  session ref; a second concurrent claimer finds it already gone and claims
  nothing.
- GC deletes a foreign ref older than 14 days and preserves a fresh one and the
  current conversation's own ref.
- All PR #5 base-guard behavior continues to hold on the per-session ref.

## Out of scope (tracked follow-ups, not this spec)

- The ownership-blind `session-end.sh` `rm -f session.lock` — with per-session
  refs it no longer causes a false crash, so it is decoupled from this work.
- Surfacing a dead sibling's crash to a bystander (declined by design).
- `cs -doctor` keys its shadow-ref check on `CS_CLAUDE_SESSION_ID` (the launch
  UUID). After a context-fork the ref lives under the new UUID while the env
  still holds the pre-fork one, so doctor can cosmetically report "autosave may
  be broken" for the rest of that conversation. Cosmetic only; a follow-up could
  resolve the live UUID the way the hooks do.
