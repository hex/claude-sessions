# Cross-Session Communication — Phase 1: Presence & Discovery

**Date:** 2026-07-10
**Status:** Design (approved for spec write; pending Fable 5 validation + user review)
**Scope of this document:** Phase 1 only. Phases 2–3 are described in *Roadmap* for context but are **out of scope** here.

---

## Roadmap (context — not built in Phase 1)

The overall feature lets a cs session detect other open cs sessions, exchange
messages with them, and optionally launch a new session in tmux. Four user-facing
use cases — (a) orchestration, (b) human co-dev, (c) signals/notifications,
(d) task handoff — collapse onto **three primitives**:

1. **Presence & discovery** — know which sessions are live and what they are doing.  ← **Phase 1 (this doc)**
2. **Typed mailbox** — address a session and drop a `{kind: notify|task|text|result}` message it reads at a checkpoint.  ← Phase 2
3. **tmux spawner** — launch a session in a tmux pane and wire task-down / result-up over the mailbox.  ← Phase 3

**Transport decision (all phases):** file-based, checkpoint-delivered — the
continuation of the existing `cs -queue` + `.cs/local/` model. No daemon, no
socket, no networked coordination.

**Machine-local decision (all phases):** everything is single-host. This keeps
the feature fully inside the repo's standing design law from
`docs/superpowers/plans/2026-06-25-multi-person-codev.md:28` ("No
network/presence: … Never imply 'online'/'active now'"). That law forbids
*networked, cross-machine* presence; **local** process-liveness (`session.lock`
PID + `kill -0`) is a fact cs already surfaces in `cs-tui`
(`tui/src/session.rs` `is_pid_alive`), so Phase 1 reuses it rather than
introducing anything the law prohibits.

---

## Goal

Let a cs session, on the same machine, answer two questions:

1. **Which other cs sessions are running right now?** (and who is in them, since when)
2. **What is each of them working on?** (a short, session-set status)

Deliver this as two commands — `cs -live` (discover) and `cs -status` (advertise) —
plus one new per-machine state file. Phase 1 introduces exactly one write path.

## Non-goals (Phase 1)

- No messaging / mailbox / notifications (Phase 2).
- No tmux spawning (Phase 3).
- No cross-machine discovery. `kill -0` cannot reach another host; git sync is async.
- No idle/active heartbeat. Liveness is binary (process alive per `session.lock`),
  status is a human-set string — not an automatic activity tracker.
- No editing another session's status. A session speaks only for itself.

---

## Source-of-truth note

`bin/cs` is a **build artifact** assembled from `lib/*.sh` by `build.sh`.
All implementation edits land in `lib/` fragments (and `hooks/*.sh`), then
`build.sh` regenerates `bin/cs`. Line numbers below cite `lib/` unless stated.

---

## Commands

### `cs -live` — list live sessions (global)

Lists every cs session under `SESSIONS_ROOT` whose process is currently alive on
this machine. Global, like `cs -list` — does not require being inside a session.

Output (one row per live session, current session marked):

```
● bugfix-auth      alex   12m   Fix JWT refresh race in login flow
● tui-todo-pane    alex    3m   (this session)
```

- Column 1: `●` live marker.
- Column 2: session name (directory basename under `SESSIONS_ROOT`).
- Column 3: actor slug (`cs_actor_slug`).
- Column 4: uptime, humanised (`3m`, `2h`, `1d`).
- Column 5: status — the session's `presence.status`, falling back to its README
  objective, falling back to empty. The current session's status column shows
  `(this session)` instead of its status text.

`cs -live` always lists every live session, **including the current one**. If the
only live session is the current one (or there are none at all, when invoked
outside any session), it prints `No other live cs sessions.` in place of / below
the listing — i.e. the message means "nothing *else* is live", never suppressing
the current row.

### `cs -status [text]` — get/set the current session's status (in-session)

- `cs -status "refactoring the parser"` — set the current session's status.
- `cs -status` (no argument) — print the current session's status.

Requires an ambient session (`CLAUDE_SESSION_META_DIR` set), exactly like
`cs -queue`. Outside a session it errors: `cs -status: not inside a session`.

Naming: `-status` sits alongside the existing `-statusline` (`bin/cs-statusline`).
They are distinct (`-statusline` renders the Claude Code status line; `-status`
is this session's advertised activity). If the proximity is judged too close at
implementation time, the fallback name is `-doing`; the design is otherwise
identical.

---

## The presence file — the one write path

**Path:** `<session>/.cs/local/presence`
**Format:** `key=value` lines (matches the existing `.cs/local/state` convention
in `lib/40-state.sh`):

```
status=Fix JWT refresh race in login flow
status_at=1752134400
```

- `status` — one line of free text (newlines stripped on write).
- `status_at` — epoch seconds when the status was set (local clock).

### Lifecycle

1. **Seed (session-start).** `hooks/session-start.sh` writes `presence` if absent:
   `status` = the README objective (see *README objective extraction* below),
   `status_at` = now. This makes `cs -live` informative before anyone runs
   `cs -status`.
2. **Set (`cs -status "text"`).** Atomic rewrite: write to `presence.tmp`, then
   `mv` over `presence` — the pattern `_queue_set_state` uses at
   `lib/55-queue.sh:4-8`. Updates both `status` and `status_at`.
3. **Clear (session-end).** `hooks/session-end.sh` removes `presence` next to the
   existing `session.lock` cleanup (`hooks/session-end.sh:59`). Belt-and-braces
   only — a dead PID already makes the record irrelevant to `cs -live`.

### Multi-user-safety classification (standing mandate)

Per `.cs/memory/project_cs_multi_user_safety.md`, every new session-dir write path
must be classified before shipping. `presence` is **per-machine ambient state**:

- Lives under `.cs/local/` → gitignored, never committed; enforced by
  `cs_assert_local_untracked` (`lib/45-migrate.sh:70-76`).
- **Single writer** (the owning session, on this machine) → no concurrent writers,
  so no `merge=union` and no semantic merge driver are needed.
- `status_at` uses the local clock, which is permitted **because the file is
  untracked**. The "dates come from git history, not wall-clock" rule applies only
  to git-tracked files.

---

## `cs -live` data flow (all reads except the caller's own seed)

For each entry under `SESSIONS_ROOT` (reuse the enumeration in `list_sessions`,
`lib/65-sessions.sh:96-158`, including the `-type l` symlink handling):

1. **Live?** Read the PID from `<session>/.cs/local/session.lock`; if `kill -0 <pid>`
   succeeds, the session is live. This mirrors the lock check in `lib/15-lock.sh`
   and `cs-tui`'s `is_pid_alive` (`tui/src/session.rs`). Skip non-live sessions.
2. **Actor.** Resolve via the existing identity path (`cs_actor_slug`,
   `lib/40-state.sh:127-146`) against the session dir.
3. **Uptime.** `now − start`, where `start` is the first `session.log` entry
   timestamp (fallback: `session.lock` mtime).
4. **Status.** `presence.status` if present and non-empty; else the README
   objective; else empty.
5. Print live rows; mark the invoking session with `(this session)` (matched by
   `CLAUDE_SESSION_DIR` / `CLAUDE_SESSION_NAME` when set).

### README objective extraction

The seed and the `-live` fallback both need the session's objective line from
`<session>/.cs/README.md`. cs already reads README in `search_sessions`
(`lib/65-sessions.sh:5-56`). Phase 1 adds a small helper that returns the
Objective — the first non-empty content line under the `## Objective` /
`Objective:` heading in the README body — trimmed to one line, or empty if absent.

---

## Dispatch wiring

Per `.cs/memory/project_cs_flag_convention.md`, cs verbs use a single dash and are
dispatched in `main()` (`lib/99-main.sh`). Two sites exist: a top-level arm
(global flags, ~`:39-135`) and a session-scoped arm (`cs <name> -flag`, ~`:154-186`).

- `-live` is **global** (like `-list`): wire in the top-level arm only. `cs <name> -live`
  is meaningless (it lists all sessions regardless).
- `-status` is **in-session** (like `-queue`): wire in the top-level arm, resolving
  the current session from ambient `CLAUDE_SESSION_META_DIR`. It is *not* wired in
  the session-scoped arm — a session sets only its own status, and reads of other
  sessions' statuses happen through `-live`.

Both new verbs need shell-completion entries in `completions/_cs` and
`completions/cs.bash` (the `cs -complete` surface).

---

## Error handling & edge cases

| Case | Behaviour |
|------|-----------|
| `session.lock` PID dead / lock absent | Session not live; excluded from `-live`, regardless of any stale `presence`. PID is authoritative. |
| PID reuse (dead session's PID reused by unrelated process) | Rare false-positive "live". Inherited from `cs-tui`'s existing model; accepted for v1 and documented. |
| `presence` missing (session predates feature, or seed skipped) | `-live` shows the session (if live) with status from README objective, else blank. |
| README has no objective | Seed and fallback yield an empty status; row still prints. |
| Symlinked / worktree session dirs | Enumerated already (`-type l`); addressed by directory basename. |
| `cs -status` outside a session | Error `cs -status: not inside a session` (mirrors `-queue`). |
| Empty `SESSIONS_ROOT` | `-live` prints `No other live cs sessions.` cleanly, exit 0. |
| `status` text contains newlines / `=` | Newlines stripped to one line on write; value read as everything after the first `=` so embedded `=` is preserved. |

---

## Testing strategy (bash 3.2 + BSD userland — CI runs the suite under 3.2)

Add to the existing bash test harness (each assertion ends `|| return 1`; the
harness disables `errexit` inside `run_test`).

1. **Live included / dead excluded.** Create two fake session dirs under a temp
   `CS_SESSIONS_ROOT`: one with a `session.lock` holding a live PID (e.g. a
   `sleep` we control), one holding a dead PID. Assert `cs -live` lists the first,
   not the second.
2. **Status set → shown.** In a fixture session, `cs -status "doing X"`, then assert
   `presence` contains `status=doing X` and that `cs -live` renders `doing X`.
3. **Seed from README.** Session-start seeding writes `status=<objective>` when
   `presence` is absent and README has an objective.
4. **Atomic write leaves no temp.** After `cs -status`, assert no `presence.tmp`
   remains in `.cs/local/`.
5. **Current-session marker.** With `CLAUDE_SESSION_DIR` pointed at a fixture,
   `cs -live` marks that row `(this session)`.
6. **Empty root.** With an empty `CS_SESSIONS_ROOT`, `cs -live` prints the
   no-sessions message and exits 0.
7. **`-status` outside a session** errors with the documented message and non-zero exit.

Fixtures set `CS_SESSIONS_ROOT` to a temp dir (per `project_cs_dev_repo_ignores_cs`
guidance to isolate the test env from the dev repo's own `.cs/`).

---

## Reused primitives (do not reinvent)

| Need | Reuse | Location |
|------|-------|----------|
| Identity / actor slug | `cs_actor_slug`, `_slugify` | `lib/40-state.sh:127`, `bin/cs:1360` |
| Session enumeration | `list_sessions` scan | `lib/65-sessions.sh:96` |
| Liveness (PID + `kill -0`) | `session.lock` + lock helpers | `lib/15-lock.sh`; `tui/src/session.rs` `is_pid_alive` |
| Atomic state write | `_queue_set_state` (tmp + mv) | `lib/55-queue.sh:4` |
| README read | `search_sessions` pattern | `lib/65-sessions.sh:5` |
| `.cs/local` untracked guard | `cs_assert_local_untracked` | `lib/45-migrate.sh:70` |
| Contributor/who enumeration pattern | `cmd_who` | `lib/40-state.sh:162` |

---

## Definition of done (Phase 1)

- `cs -live` lists live sessions with actor, uptime, status; marks current session.
- `cs -status [text]` gets/sets the current session's status; atomic write.
- `presence` seeded at session-start from README objective; cleared at session-end.
- New write path classified and gitignored under `.cs/local/`.
- Completions updated for `-live` and `-status`.
- README (project) updated to document both commands (per repo rule: update README
  when adding features).
- Tests above pass under bash 3.2 + BSD in CI.
