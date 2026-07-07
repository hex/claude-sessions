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
| `.cs/timeline.jsonl` | Structured event log — `started`, `ended`, and `checkpoint` events as newline-delimited JSON. | `union` |
| `.cs/memory/MEMORY.md` | Index of Claude Code's native auto-memory (one line per fact). | `ours` |
| `.cs/memory/<bucket>_*.md` | Native auto-memory fact files (user, feedback, project, reference). Written by the harness. | default |
| `.cs/memory/narrative.<actor>.md` | Per-actor lab notebook. Each co-developer writes their own file; everyone reads all of them on resume. | `union` |
| `.cs/checkpoints/` | Labelled state snapshots from `/checkpoint` (narrative + changes + git HEAD). | default |
| `.cs/plans/` | Design plans and specs kept with the session. | default |
| `.cs/age-recipients/*.pub` | age public keys of everyone allowed to decrypt the session's synced secrets. | default |
| `.cs/secrets.<machine-id>.age` | Per-machine encrypted secret sync file (age; preferred). Each machine writes its own so exports never collide. | default |
| `.cs/secrets.<machine-id>.enc` | Per-machine encrypted secret sync file (OpenSSL + password; legacy). | default |

`<machine-id>` is `${USER}@<short-hostname>` — the same id that names age
recipients. See [secrets.md](secrets.md) for the sync model.

`.cs/session.lock` is a PID-based lock written at the session root (not under
`local/`). It is ephemeral and machine-specific; it exists only while a session
is open and is cleaned up on exit.

## Machine-local files (`.cs/local/`, gitignored)

| File | Purpose |
|------|---------|
| `session.log` | Human-readable audit trail — bash commands, session lifecycle, autosave notes, UUID rebinds. Per-checkout by nature; the shared structured record is `timeline.jsonl`. |
| `state` | Session state bound to this checkout: `claude_session_id` (the conversation UUID to resume) and `claude_session_color` (the `/color` palette entry). Each machine binds its own conversation, so this must not sync. |
| `identity` | Overrides the actor name for shared memory/narrative attribution (precedence: `$CS_ACTOR` > `local/identity` > git `user.email` > git `user.name`). |
| `attention` | Status-line attention marker — raised by the `Stop` hook when Claude finishes, cleared on the next prompt. |
| `queue` | The walk-away task queue (`cs -queue`). |
| `queue.declined` | Cooldown stamp after declining the queue-drain prompt. |
| `watermark` | Per-actor high-water mark for the "shared memory/narrative activity since you were last here" digest injected on resume. |
| `context-pct` | Latest context-window percentage, stamped by the status line and read by the narrative reminder to suggest compaction. |

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
