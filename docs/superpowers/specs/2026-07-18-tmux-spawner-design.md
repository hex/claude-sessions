# tmux Spawner (`cs -spawn`) — Design

Phase 3 of the cross-session comms roadmap (Phase 1 presence shipped
2026-07-10, Phase 2 mailbox shipped 2026-07-18). One cs session — or Alex at a
terminal — launches another session in a tmux window, optionally hands it work,
and hears back over the mailbox. Machine-local by nature.

Design adversarially reviewed by codex (gpt-5.6-sol), 12 findings; 9 adopted,
2 scoped down with recorded reasons, 1 folded (see "Review record").

## Goal

`cs -spawn worker --task "run the release checklist"` opens session `worker`
in a dedicated tmux session, with its walk-away queue seeded and armed and a
kick prompt that starts the first turn. When the queue drains, the spawner's
next turn digest says so. `cs -spawn worker` without `--task` just opens the
session in tmux, nothing else.

## Decisions locked during brainstorm

- Worker-first, watchable: unattended drain is the design center; attaching to
  watch is free (`tmux attach -t cs`).
- Spawned sessions live in a dedicated tmux session named `cs` on the DEFAULT
  server (not a private socket), one window per cs session, created detached.
- A finished worker stays open and notifies; closing is a human act.
- `--task` both seeds and arms the queue — the spawn command is the consent.
- Spawn may create brand-new sessions: the window runs the normal `cs <name>`
  launch, which already scaffolds new sessions, resumes existing ones, and
  creates `base@task` worktrees.

## CLI

`cs -spawn <name> [--task "text"]...` — single-dash verb, both dispatch arms
in `lib/99-main.sh`, implemented in a new `lib/52-spawn.sh`.

Validation, in order, each failure a hard `error`:

1. `<name>` passes the same gate as a launch: `cs_split_worktree_name` for
   `base@task` names, else `validate_session_name` (lib/25-deps.sh) — the
   conservative charset is the primary command-injection defense.
2. tmux binary present.
3. Target not already live (`session_is_live`).
4. No window named `<name>` already in the `cs` tmux session.
5. Each `--task` body: non-empty after trim, no CR/LF (queue lines are
   line-oriented; same rule as `cs -msg -k task`).
6. If `--task` given and `$SESSIONS_ROOT/.spawn/<name>.seed` already exists:
   error "a pending spawn for <name> exists" (prevents silent task loss from
   concurrent or repeated spawns).

## Spawn seed

Only written when `--task` is present. Location: `$SESSIONS_ROOT/.spawn/<name>.seed`
— a staging directory OUTSIDE any session dir, so nothing ever pre-creates a
partial `.cs/` (which would make `is_session_dir` misread a new session as
existing). Format: line 1 = spawner session name (`CLAUDE_SESSION_NAME`, may
be empty when spawned from outside a session), lines 2..N = one task each.
Written to `<name>.seed.tmp` then `mv` (atomic; combined with rule 6 above, no
torn reads and no last-writer-wins task loss).

## Launch-path consumption (lib/75-launch.sh)

`launch_claude_code` gains one step at a single choke point: after the
already-running guard passes and the session scaffold/resume state is settled,
immediately before the exec branching:

1. If `$SESSIONS_ROOT/.spawn/<session_name>.seed` exists:
   - Fresher than 3600 seconds (mtime): parse with `while IFS= read -r`;
     line 1 → spawner; each task line → `_queue_add "$META/local"`; write
     `armed` to `queue.state`; if spawner non-empty, write it to
     `.cs/local/spawned-by`; delete the seed; compose the kick prompt.
   - Older: `mv` it to `<name>.seed.stale` and `warn` — a stale spawn never
     surprise-arms a queue days later; recovery is explicit (read the .stale
     file, re-spawn).
2. Kick prompt (only when a seed was consumed) rides the exec as claude's
   positional initial prompt, threaded to whichever exec arm runs. With a
   spawner: "Spawned by <spawner>. Your walk-away queue is armed with N
   task(s); begin. Send results with: cs -msg <spawner> -k result \"...\"".
   Without: "Your walk-away queue is armed with N task(s); begin." (no reply
   instructions, no spawned-by — result routing to nowhere is not suggested).

If the exec still fails after consumption, degradation is defined: the queue
stays armed and drains on the session's next open; only the kick prompt is
lost. No launch records or startup acknowledgements — that machinery has no
matching failure in a same-user, single-machine model.

Seeds also apply on a normal `cs <name>` open (not just via spawn windows).
That is intended: it is what makes a died-before-launch window self-healing,
and the TTL bounds the surprise window to an hour.

## tmux mechanics (lib/52-spawn.sh)

All tmux calls behind a thin wrapper function so tests can stub them.

1. Window command: `<absolute path of running cs> <name>`, both single-quote
   encoded (`'` → `'\''`) — the tmux server's PATH may lack `~/.local/bin`,
   and quoting is defense in depth behind the name validation.
2. If no tmux session `cs` exists: `tmux new-session -d -s cs -n <name>
   <cmd>`, then stamp ownership: `tmux set-option -t cs @cs_managed 1`. If
   `new-session` fails because a concurrent spawner just created it, fall
   through to the new-window arm (one retry).
3. If session `cs` exists: require `tmux show-option -t cs -v @cs_managed`
   to return `1`; an unmarked pre-existing session named `cs` belongs to the
   human — refuse with guidance rather than adding windows to it (the
   personal tmux server is never colonized).
4. Add the window with `tmux new-window -t cs -n <name> -P -F '#{window_id}'
   <cmd>` — the printed window ID is captured and echoed to the user.
5. Confirmation: `spawned <name> in tmux session cs (window %ID). Attach:
   tmux attach -t cs`. When claude exits, the window closes with it.

## Result-up (hooks/narrative-reminder.sh)

Automatic, best-effort — never breaks the hook, no delivery guarantee beyond
the mailbox's own:

- Where the drain writes its `drain_finished` event (line ~142): if
  `.cs/local/spawned-by` exists and the installed `cs` binary is on PATH,
  run `cs -msg <spawned-by> -k notify "queue drained: N task(s) done"`, then
  delete `spawned-by` — one-shot, so later unrelated drains never re-notify
  the old spawner.
- Where `breaker_tripped` is recorded: same notify with the trip reason,
  but `spawned-by` is kept — the eventual real drain still reports.
- Failures are swallowed (`2>/dev/null || true`) like every other digest-side
  effect.

Richer per-task results are advisory: the kick prompt instructs the worker's
Claude to send `-k result` messages; nothing enforces it.

## Queue interplay

Seeding appends to whatever queue the target already has — identical
semantics to `cs -msg -k task`. FIFO order, existing arming, decline, and
breaker rules all apply unchanged. Attribution of the drain-finished notify is
to the whole drain, not per-batch; batch isolation was reviewed and rejected
as YAGNI (see record).

## Trust model

Same OS user, one machine, unchanged from the mailbox: anyone who can run
`cs -spawn` can already run `tmux` and `cs` directly. The injection defenses
(charset validation + quoting) protect against accidents and malformed names,
not against a hostile same-user process.

## Files touched

| File | Change |
|---|---|
| `lib/52-spawn.sh` | new: `run_spawn`, seed writer, tmux wrapper |
| `lib/75-launch.sh` | seed consumption + kick prompt threading |
| `lib/99-main.sh` | `-spawn` in both dispatch arms |
| `lib/10-help.sh` | help lines |
| `hooks/narrative-reminder.sh` | spawned-by notify on drain_finished / breaker_tripped |
| `completions/_cs`, `completions/cs.bash` | `-spawn` (drift-net tests enforce) |
| `bin/cs` | regenerated by `./build.sh` |
| `tests/test_spawn.sh` | new suite |
| `README.md`, `docs/session-layout.md`, `docs/hooks.md` | docs |

## Testing

TDD; bash 3.2 + BSD; every assert `|| return 1`. tmux calls stubbed via the
wrapper (a test shim function or PATH-shadowed fake `tmux` recording argv), so
the suite runs without touching any real tmux server. Coverage:

- validation: bad name, worktree name accepted, missing tmux, already-live
  target, duplicate window, empty/multiline task, existing seed refusal.
- seed: tmp+mv write, exact format (spawner line + task lines), empty-spawner
  first line.
- consumption (via the real launch path with `CLAUDE_CODE_BIN=echo`): tasks
  queued in order, queue armed, spawned-by written (and not written for empty
  spawner), seed deleted, kick prompt in exec argv (present with seed, absent
  without), stale seed moved aside + warning, fresh-vs-stale boundary.
- tmux wrapper: recorded argv shows single-quoted command, `-P -F` capture,
  ownership stamp on create, refusal on unmarked existing `cs` session,
  new-session collision retry.
- result-up: drain_finished with spawned-by sends the notify into the
  spawner's inbox and deletes spawned-by; second drain sends nothing;
  breaker_tripped notifies and keeps spawned-by; missing cs binary or send
  failure leaves the drain unaffected.

## Non-goals

- No pane splitting, no attach automation, no layout management.
- No recursive-spawn depth limit (the already-live check stops direct loops).
- No worker supervision beyond existing queue breakers.
- No batch IDs / per-batch attribution.
- No cross-machine anything.
- No `--reply-to` override (empty spawner simply gets no reply wiring).

## Review record (codex gpt-5.6-sol, 2026-07-18)

Adopted: #1 injection (validate_session_name/cs_split_worktree_name gate +
single-quote encoding + absolute cs path), #3+#2 merged (tmp+mv seed write +
refuse existing seed), #4 format validation (CR/LF bans, IFS= read -r), #6
stale-seed TTL (3600s, .stale set-aside), #8 one-shot spawned-by (delete after
drain notify; tripped notifies but keeps it), #9 reworded to automatic
best-effort, #10 tmux ownership marker (@cs_managed; refuse unmarked `cs`
session), #11 partial (-P -F window-id capture + new-session collision retry;
startup handshake skipped — liveness is observable via cs -live), #12 empty
spawner gets no reply wiring.

Scoped down: #5 transactional consumption — consumption sits after the
already-running guard and immediately before exec; the residual failure
(exec dies) degrades to a defined, correct state (armed queue drains on next
open). #7 batch isolation — appending to a live queue is the queue's normal
contract; batch IDs rejected as YAGNI.
