# Cross-Session Communication — Phase 1: Presence & Discovery

**Date:** 2026-07-10
**Status:** Design — revised after Fable 5 validation; pending user review
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
the feature inside the repo's standing design law from
`docs/superpowers/plans/2026-06-25-multi-person-codev.md:28` ("No
network/presence: … Never imply 'online'/'active now'"). That law forbids
*networked, cross-machine* presence; **local** process-liveness
(`session.lock` PID + `kill -0`) is a fact cs already surfaces in `cs-tui`
(`tui/src/session.rs:492-499`, `is_pid_alive`), so Phase 1 reuses it rather than
introducing anything the law prohibits.

---

## Goal

Let a cs session, on the same machine, answer two questions:

1. **Which other cs sessions are running right now?** (and who is in them, since when)
2. **What is each of them working on?** (a short, session-set status)

Deliver this as two commands — `cs -live` (discover) and `cs -status` (advertise) —
plus one new per-machine state file. Phase 1 introduces exactly one write path
(`cs -status`) and **changes no hooks**.

## Non-goals (Phase 1)

- No messaging / mailbox / notifications (Phase 2).
- No tmux spawning (Phase 3).
- No cross-machine discovery. `kill -0` cannot reach another host; git sync is async.
- No idle/active heartbeat. Liveness is binary (process alive per `session.lock`);
  status is a human-set string, not an automatic activity tracker.
- No editing another session's status. A session speaks only for itself.
- No `status_at` / "set N minutes ago" timestamp — deferred to Phase 2 (nothing in
  Phase 1 reads it, so it is not stored).

---

## Source-of-truth note

`bin/cs` is a **build artifact** assembled from `lib/*.sh` by `build.sh`. All
implementation edits land in `lib/` fragments, then `build.sh` regenerates
`bin/cs`. Hooks (`hooks/*.sh`) are standalone scripts that **do not** source
`lib/`. Line numbers cite `lib/` / `hooks/` / `tui/` as noted.

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
- Column 3: actor slug for **that** session (see *Actor resolution*).
- Column 4: uptime since last launch, humanised (`3m`, `2h`, `1d`).
- Column 5: status — the session's `presence` text, falling back to its README
  objective, falling back to empty. The current session's status column shows
  `(this session)` in place of its status text.

`cs -live` always lists every live session, **including the current one**. If the
only live session is the current one (or there are none, when invoked outside any
session), it additionally prints `No other live cs sessions.` — that message means
"nothing *else* is live", it never suppresses the current row.

### `cs -status [text] | --clear` — get/set the current session's status (in-session)

- `cs -status "refactoring the parser"` — set the current session's status. Multiple
  unquoted words are joined with single spaces (the `"$*"` convention `_queue_add`
  uses, `lib/55-queue.sh:57`). Newlines in the value are collapsed to spaces so the
  file stays one line.
- `cs -status` (no argument) — print the current session's **effective** status
  (the same fallback chain `-live` uses: `presence` → README objective → `(none)`).
- `cs -status --clear` (alias `-c`) — remove the `presence` file, reverting the
  session to its README-objective fallback.
- `cs -status ""` — rejected with a usage error (use `--clear` to clear); an empty
  string is never written.

Requires an ambient session (`CLAUDE_SESSION_META_DIR` set), exactly like
`run_queue` (`lib/55-queue.sh:51-53`). Outside a session it errors
`cs -status: not inside a session` and exits non-zero. The error text does **not**
advertise a `cs <session> -status` form — `-status` is top-level only (see
*Dispatch wiring*).

Naming: `-status` sits alongside the existing `-statusline` (`bin/cs-statusline`,
which renders the Claude Code status line — unrelated). If the proximity is judged
too close at implementation time, the fallback name is `-doing`; the design is
otherwise identical.

---

## The presence file — the one write path

**Path:** `<session>/.cs/local/presence`
**Format:** a **single line** of UTF-8 text = the current status. No `key=value`,
no timestamp. A single-value local file matches the existing `.cs/local/watermark`
(one SHA) and `queue.state` (one word) precedents, and — unlike reusing
`_set_local_state`/`_read_local_state` (`lib/40-state.sh:42-63`), whose reader does
`gsub(/"/,"")` — it preserves every character of the status text, including quotes.

### Lifecycle

1. **Set** — `cs -status "text"` writes `text` atomically: write `presence.tmp`,
   then `mv` over `presence` (the rename pattern `_queue_set_state` uses,
   `lib/55-queue.sh:4-9`).
2. **Clear** — `cs -status --clear` removes the file.
3. **No seed, no auto-clear.** Session start and session end do **not** touch
   `presence`. Status is **persistent per session** (machine-local). This is safe
   because `cs -live` lists only *live* sessions, so a stale `presence` left by a
   since-exited session never surfaces; on the next launch of that session, its
   last-set status is shown until changed (or `--clear`ed). A session that has never
   run `cs -status` shows its README objective via the fallback — no seed required.

### Multi-user-safety classification (standing mandate)

Per `.cs/memory/project_cs_multi_user_safety.md`, every new session-dir write path
must be classified. `presence` is **per-machine ambient state**:

- Lives under `.cs/local/` → gitignored (`lib/85-adopt-uninstall.sh:13`, backfilled
  by `ensure_cs_gitignore_entries`, `lib/45-migrate.sh:150`), and guarded on every
  resume by `cs_assert_local_untracked` (`lib/45-migrate.sh:21-27`, run at
  `:142`), which errors if anything under `.cs/local` is git-tracked.
- **Single writer under normal use** (the owning session on this machine) → no
  `merge=union`, no semantic merge driver.
- **Known exception — `--force` double-launch.** `_lock_collision_menu`'s `[f]` /
  `--force` (`lib/15-lock.sh:25-27,48-53`) starts a second claude in the *same*
  session dir. Then two processes can both write `presence` (last-writer-wins,
  acceptable for a status string) and the second launch overwrites `session.lock`
  with its own PID (`lib/15-lock.sh:66`); `hooks/session-end.sh:59` later removes
  the lock unconditionally, so whichever process exits first drops the survivor's
  lock and the survivor disappears from `cs -live`. This is a **pre-existing**
  cs / cs-tui limitation of the PID-lock model, not introduced here; Phase 1
  inherits and documents it rather than fixing it.

---

## `cs -live` data flow (all reads except the caller's own `-status`)

For each entry under `SESSIONS_ROOT` (reuse the enumeration in `list_sessions`,
`lib/65-sessions.sh:96-158`, including the `-type l` symlink handling at `:98-101`):

1. **Live?** Read the PID from `<session>/.cs/session.lock` (note: `.cs/`, **not**
   `.cs/local/`). If `kill -0 <pid>` succeeds, the session is live. This mirrors the
   lock in `lib/15-lock.sh` (`lock_file = <meta>/session.lock`, acquired at
   `lib/75-launch.sh:11`) and `cs-tui`'s `read_lock_pid`/`is_pid_alive`
   (`tui/src/session.rs:485-499`). Skip non-live sessions.
2. **Actor** — see *Actor resolution*.
3. **Uptime** — `now − mtime(<session>/.cs/session.lock)`. The lock is (re)stamped
   at each launch/resume — `hooks/prose-lint.sh:34-36` already relies on exactly
   this ("session.lock is stamped when the session starts"). So uptime is "time
   since this session was last launched", which is the intended meaning. (Do **not**
   use the first `session.log` entry — that is the session *creation* time,
   potentially months old, per `list_sessions`' CREATED column,
   `lib/65-sessions.sh:137-158`.)
4. **Status** — the contents of `<session>/.cs/local/presence` if the file exists
   and is non-empty; else the README objective (see *README objective extraction*);
   else empty.
5. Print live rows; mark the invoking session with `(this session)` by matching
   `CLAUDE_SESSION_NAME` against the row's basename (string equality on **name**,
   not path — `main()` resolves symlinks so `CLAUDE_SESSION_DIR` may be the real
   path while enumeration yields the `SESSIONS_ROOT` symlink path,
   `lib/99-main.sh:202-204`).

### Actor resolution

The actor shown must be **that session's** actor, not the invoker's. `cs_actor_slug`
(`lib/40-state.sh:129`) honours the ambient `$CS_ACTOR` **before** the per-session
identity file (`:138-141`), so calling it while `$CS_ACTOR` is exported would print
the caller's slug on every row. Phase 1 therefore adds a small resolver that reads a
given session's actor directly from its dir, ignoring `$CS_ACTOR`:
`<sdir>/.cs/local/identity` if present → else `git -C <sdir> config user.email`
(slugified via `_slugify`, `lib/40-state.sh:119`) → else `git -C <sdir> config
user.name` → else `unknown`.

### README objective extraction

The status fallback reads the objective from `<session>/.cs/README.md`. The objective
is the first non-empty content line under the `## Objective` heading (verified
against `.cs/README.md:12-14` and the create template, `lib/45-migrate.sh:52-57`).
The extractor **must filter the template placeholder** `[Describe what you're trying
to accomplish in this session]` (and any `^\[.*\]$` line) to empty — the existing
extractions already do this (`hooks/session-start.sh:210`, `hooks/session-end.sh:81-82`
via `sed 's/^\[.*\]$//'`). This new extractor lives in `bin/cs` (a `lib/` fragment)
and is only reachable from `cs -live`/`cs -status`; because Phase 1 drops the seed,
no hook-side copy is added, so this does not widen the existing hook/lib duplication.

---

## Dispatch wiring

Per `.cs/memory/project_cs_flag_convention.md`, cs verbs use a single dash and are
dispatched in `main()` (`lib/99-main.sh`): a top-level arm (global flags, ~`:39-135`)
and a session-scoped arm (`cs <name> -flag`, ~`:154-186`).

- `-live` is **global** (like `-list`): wire in the top-level arm only.
- `-status` is **in-session**: wire in the top-level arm, resolving the current
  session from ambient `CLAUDE_SESSION_META_DIR`. It is **not** wired in the
  session-scoped arm; `cs <name> -status` will therefore fall through to that arm's
  "Unknown session command" error (`lib/99-main.sh:188`), which is acceptable — a
  session sets only its own status, and reads of other sessions' statuses happen via
  `-live`. (Note: unlike `-status`, `-queue` *is* dual-wired at `:113-117` and
  `:169-176`; `-status` deliberately is not.)

Both new verbs get shell-completion entries in `completions/_cs` and
`completions/cs.bash`.

---

## Error handling & edge cases

| Case | Behaviour |
|------|-----------|
| `.cs/session.lock` PID dead / lock absent | Session not live; excluded from `-live`, regardless of any stale `presence`. PID is authoritative. |
| PID reuse (dead session's PID reused by an unrelated process) | Rare false-positive "live". Inherited from cs / cs-tui's existing PID-lock model; accepted for v1 and documented. |
| `--force` double-launch (two claudes, one session dir) | Two `presence` writers (last-writer-wins) and a lock-ownership race that can drop the survivor from `-live`. Pre-existing PID-lock limitation; documented, not fixed (see classification). |
| `presence` missing (never `-status`'d) | `-live`/`-status` show the README objective; if that is empty/placeholder, blank / `(none)`. |
| README objective is the unfilled `[Describe…]` placeholder | Filtered to empty by the extractor; status shows blank. |
| Symlinked / adopted / worktree session dirs | Enumerated already (`-type l`); addressed by basename; `(this session)` matched by `CLAUDE_SESSION_NAME`, so symlink vs real path does not break the marker. |
| `cs -status` outside a session | Error `cs -status: not inside a session`, non-zero exit. |
| `cs -status ""` | Usage error; use `--clear` to clear. |
| Empty `SESSIONS_ROOT` | `-live` prints `No other live cs sessions.`, exit 0. |
| `presence` text contains `=`, quotes, tabs | Preserved verbatim (single raw line); only newlines are collapsed to spaces on write. |

---

## Testing strategy (bash 3.2 + BSD userland — CI runs the suite under 3.2)

Add to the existing bash harness (each assertion ends `|| return 1`; `run_test`
disables `errexit`). Fixtures point `CS_SESSIONS_ROOT` (`lib/00-header.sh:9`) at a
temp dir to isolate from the dev repo's own `.cs/` (per
`project_cs_dev_repo_ignores_cs`).

1. **Live included / dead excluded.** Two fake session dirs: one with
   `.cs/session.lock` holding a live PID (a `sleep` we control), one holding a dead
   PID. Assert `cs -live` lists the first, not the second. *(Note: lock at `.cs/`,
   not `.cs/local/`.)*
2. **Status set → shown.** `cs -status "doing X"` in a fixture session; assert
   `.cs/local/presence` contains exactly `doing X` and `cs -live` renders `doing X`.
3. **Status preserves special chars.** `cs -status 'fix the "auth" bug = hard'`;
   assert the file and `-live` show the string verbatim (guards against the
   quote-stripping reader we deliberately did not reuse).
4. **Clear reverts to objective.** With a README objective set and a presence file,
   `cs -status --clear` removes the file; `-live` then shows the objective.
5. **No presence → README objective (live).** A live session with no presence file
   and a filled objective shows the objective; editing the README changes `-live`
   output on the next call (proves the fallback is read live, not seeded).
6. **Placeholder filtered.** A live session whose README still holds the `[Describe…]`
   placeholder and no presence file shows a blank status, not the placeholder text.
7. **Uptime from lock mtime.** Touch `.cs/session.lock` to a known mtime; assert the
   uptime column reflects `now − that mtime`, not the (older) `session.log` creation
   time.
8. **Atomic write leaves no temp.** After `cs -status`, assert no `presence.tmp`
   remains under `.cs/local/`.
9. **Current-session marker.** With `CLAUDE_SESSION_NAME` set to a fixture's
   basename, `cs -live` marks that row `(this session)`, including when the session
   dir is reached via a symlink.
10. **Actor is the session's, not the invoker's.** With `CS_ACTOR=someone-else`
    exported, `cs -live` still shows each fixture session's own identity/git actor,
    not `someone-else`.
11. **`-status` outside a session** errors with the documented message and non-zero
    exit; **`cs -status ""`** errors as a usage error.
12. **Empty root.** Empty `CS_SESSIONS_ROOT` → `-live` prints the no-sessions message,
    exit 0.

---

## Reused primitives (do not reinvent) — citations verified by Fable 5

| Need | Reuse | Location |
|------|-------|----------|
| Identity slug helper | `_slugify` | `lib/40-state.sh:119` |
| Current-session actor | `cs_actor_slug` (current row only; bypass `$CS_ACTOR` for other rows) | `lib/40-state.sh:129` |
| Session enumeration (incl. symlinks) | `list_sessions` scan | `lib/65-sessions.sh:96-158` |
| Liveness (PID + `kill -0`) | `session.lock` at `.cs/session.lock` + lock helpers | `lib/15-lock.sh`; `lib/75-launch.sh:11`; `tui/src/session.rs:485-499` |
| Launch-time stamp for uptime | `session.lock` mtime | `hooks/prose-lint.sh:34-36` |
| Atomic single-value write (tmp + mv) | `_queue_set_state` pattern | `lib/55-queue.sh:4-9` |
| README objective extraction (with placeholder filter) | existing `sed` extractions | `hooks/session-start.sh:210`; `hooks/session-end.sh:81-82` |
| Ambient-session requirement + error pattern | `run_queue` env check | `lib/55-queue.sh:51-53` |
| `.cs/local` untracked guard | `cs_assert_local_untracked` | `lib/45-migrate.sh:21-27` |
| Contributor/who enumeration pattern | `cmd_who` | `lib/40-state.sh:167` |

---

## Definition of done (Phase 1)

- `cs -live` lists live sessions (PID at `.cs/session.lock` + `kill -0`) with each
  session's own actor, uptime-since-launch, and status; marks the current session by
  name.
- `cs -status [text] | --clear` gets/sets/clears the current session's status;
  atomic single-line write; preserves special characters.
- `presence` lives under `.cs/local/`, persistent, single writer (normal use);
  no hooks changed.
- Status fallback reads the README objective live, with the `[Describe…]` placeholder
  filtered.
- Completions updated for `-live` and `-status`.
- Project README updated to document both commands (repo rule: update README when
  adding features).
- All tests above pass under bash 3.2 + BSD in CI.
