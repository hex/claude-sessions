# Session layout (`.cs/`)

Every cs session is a directory under `~/.claude-sessions/` (override with
`CS_SESSIONS_ROOT`). The directory itself is the workspace — Claude works on
project files there. All session *metadata* lives in a single `.cs/`
subdirectory, and the whole session directory is its own local git repo.

The one distinction that governs everything below is **shared vs machine-local**:

- **Shared** — committed to the session's git repo. When a session is cloned or
  synced to another machine (or shared with a co-developer), these travel with
  it. Append-heavy shared files use a git merge policy (see below) so concurrent
  writers don't conflict.
- **Machine-local** — everything under `.cs/local/`, which is gitignored. This is
  per-checkout state that must *not* sync: another machine has its own copy and
  merging them would be wrong.

## Shared files

| Path | Purpose | Merge |
|------|---------|-------|
| `.cs/README.md` | Session objective (captured from the first prompt) and outcome. Human-edited. | default |
| `.cs/summary.md` | Distilled session summary, written by `/wrap` and `/summary`. | default |
| `.cs/timeline.jsonl` | Structured event log — `started`, `ended`, `checkpoint`, and `rotated` events as newline-delimited JSON. | `union` |
| `.cs/memory/MEMORY.md` | Index of Claude Code's native auto-memory (one line per fact). | `ours` |
| `.cs/memory/<bucket>_*.md` | Native auto-memory fact files (user, feedback, project, reference). Written by the harness. | default |
| `.cs/memory/narrative.<actor>.md` | Per-actor lab notebook. Each co-developer writes their own file; everyone reads all of them on resume. | `union` |
| `.cs/checkpoints/` | Labelled state snapshots from `/checkpoint` (narrative + changes + git HEAD). | default |
| `.cs/archived` | Archive marker written by `cs -archive` (date + actor). Tracked so the archived state syncs; removed on open or `cs -unarchive`. | default |
| `.cs/handoffs/` | Lineage-stamped conversation handoffs written by the `rotate` skill (parent UUID, purpose, continuation plan). Consumed by the next launch's `r` answer. | default |
| `.cs/plans/` | Design plans and specs kept with the session. | default |
| `.cs/age-recipients/*.pub` | age public keys of everyone allowed to decrypt the session's synced secrets. | default |
| `.cs/secrets.<machine-id>.age` | Per-machine encrypted secret sync file (age; preferred). Each machine writes its own so exports never collide. | default |
| `.cs/secrets.<machine-id>.enc` | Per-machine encrypted secret sync file (OpenSSL + password; legacy). | default |

`<machine-id>` is `${USER}@<short-hostname>` — the same id that names age
recipients. See [secrets.md](secrets.md) for the sync model.

`.cs/session.lock` is a PID-based lock written at the session root (not under
`local/`). It is ephemeral and machine-specific; it exists only while a session
is open and is cleaned up on exit. `.cs/.narrative-reminder-cooldown` is a
similar gitignored transient at the `.cs/` root — the narrative reminder's
5-minute cooldown stamp.

`CLAUDE.local.md`, also at the session root, carries the cs session protocol:
it is machine-local and gitignored, cs regenerates it on each machine, and a
user-owned `CLAUDE.md` is never touched.

## Machine-local files (`.cs/local/`, gitignored)

| File | Purpose |
|------|---------|
| `session.log` | Human-readable audit trail — bash commands, session lifecycle, autosave notes, UUID rebinds. Per-checkout by nature; the shared structured record is `timeline.jsonl`. |
| `state` | Session state bound to this checkout: `claude_session_id` (the conversation UUID to resume), `claude_session_color` (the `/color` palette entry), `last_resumed` (last resume date), and, for task worktrees, `task_branch` and `cs_base`. Each machine binds its own conversation, so this must not sync. |
| `identity` | Overrides the actor name for shared memory/narrative attribution (precedence: `$CS_ACTOR` > `local/identity` > git `user.email` > git `user.name`). |
| `attention` | Status-line attention marker — raised by the `Stop` hook when Claude finishes, cleared on the next prompt. |
| `presence` | This session's advertised status (`cs -status`): a single line read by `cs -live`. Falls back to the README objective when unset. |
| `pending-handoff` | Basename of the `.cs/handoffs/` file the user chose with `r` at the resume prompt; consumed and cleared by the next SessionStart. |
| `rotate-nudged` | Conversation UUID last nudged to rotate by the narrative reminder — keeps the 80%-context nudge to once per conversation. |
| `queue` | The walk-away task queue (`cs -queue`). |
| `queue.state` | Drain state machine for the queue: `idle`, `armed`, or `draining`. |
| `queue.done` | Log of completed queued tasks, appended as each is drained. |
| `queue.declined` | Cooldown stamp after declining the queue-drain prompt. |
| `notifications.jsonl` | Per-machine queue inbox — drain lifecycle events (`drain_started`, `task_done`, `breaker_tripped`, `drain_finished`) read by `cs -queue log` and the surface-once digest. |
| `notifications.seen` | Cursor for that digest, so unseen inbox entries surface at most once. |
| `ctx-warned` | Conversation UUID already given the one-time 60% context warning (the tier below the rotation nudge). |
| `.prose-lint-attempts` | Loop-guard counter for the `prose-lint` Stop hook (allows the stop after repeated unresolved blocks). |
| `watermark` | Per-actor high-water mark for the "shared memory/narrative activity since you were last here" digest injected on resume. |
| `context-pct` | Latest context-window percentage, stamped by the status line; the narrative reminder reads it to suggest compaction, and cs-tui uses its mtime as the liveness heartbeat for conversations opened outside cs. |
| `limits` | Latest 5-hour/weekly rate-limit readings, stamped by the status line; read by `cs -usage` window anchoring and the queue's rate-limit breaker. |
| `failures` | Per-task tool-failure counter written by `tool-failure-logger.sh`; feeds the queue's failures circuit breaker, reset at each drain advance. |
| `mail/inbox.jsonl` | Cross-session mailbox: one JSON message per line, appended by senders (`cs -msg`). |
| `mail/notified` | Digest cursor: inbox line count already announced by a hook digest. |
| `mail/seen` | Read cursor: inbox line count already printed by `cs -msg`. |

## Merge policy

The session repo ships a `.gitattributes` that keeps append-heavy shared files
conflict-free:

- `merge=union` — `timeline.jsonl`, `narrative.*.md`: concurrent additions from
  different writers are both kept.
- `merge=ours` — `MEMORY.md`: the index is regenerated, so a machine keeps its
  own version rather than conflicting.

Human-authored prose (`README.md`, `summary.md`) uses the default merge — a
genuine divergence there is a real conflict a person should reconcile.

## Migration

Legacy layouts are migrated in place on the next `cs <name>` open, via the
numbered phases in `migrate_session()`: a flat pre-`.cs/` layout is moved under
`.cs/`, a legacy `discoveries.md` is folded into the narrative, retired
command-tracker files are pruned, and machine-local fields are moved out of
shared files into `.cs/local/`. Migration is idempotent — a modern session is
left untouched.
