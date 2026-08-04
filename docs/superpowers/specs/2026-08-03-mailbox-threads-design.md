# Mailbox threads and mail wake-up

Date: 2026-08-03
Status: proposed (revision 6)

**Depends on `2026-08-03-mailbox-atomic-delivery-design.md`.** That change moves
the mailbox to a maildir and fixes the shared-append corruption in both mail and
the walk-away queue. Everything here assumes `mail/{tmp,new,cur}` exists, unread
is a count of `new/*.json`, and a message is delivered atomically. Building
threads on the old append would put a transcript feature on a substrate that
drops messages.

This change adds a fourth directory, `mail/out/`, holding messages this session
sent.

## Problem

**No conversation.** Every message is an island. A recipient can send something
back, but nothing links the two and neither side can re-read the exchange. After
a rotation an agent has no way to find out what it already said. The mailbox is
inbox-only: `_mail_send` writes to the recipient and the sender keeps no record
(`lib/53-mail.sh:102`).

**Mail only lands when a human types.** The unread digest is built by
`hooks/scope-prompt.sh`, a `UserPromptSubmit` hook, so a session learns about
mail on Alex's next keystroke and not before. Agent-to-agent work cannot advance
without a human in the loop.

## Design

### Thread identity

Every message document gains three fields:

```json
{ "id": "1754230000-4821-9173", "ts": 1754230000, "thread": "a3f9c1",
  "in_reply_to": null, "from": "sessionA", "to": "sessionB",
  "actor": "alice-example-com", "kind": "text", "body": "..." }
```

- `thread` — 6 hex digits, generated at thread start with
  `printf '%06x' $(( ((RANDOM << 15) | RANDOM) & 0xFFFFFF ))` (verified under
  bash 3.2.57). Short because an agent has to retype it. 24 bits is not enough
  on its own: a mailbox accumulates roots without bound and reaches roughly a 1%
  birthday-collision chance at 581 of them, and a collision would merge two
  unrelated transcripts and misroute replies. So generation retries against the
  thread ids already present in the mailbox, and thread lookup refuses an id
  that matches documents with two different correspondents rather than guessing.
- `in_reply_to` — the `id` of the message being answered, or `null` for a root.
  This, not the timestamp, orders the transcript: `ts` is whole seconds
  (`date +%s`), a question and its reply inside one second is the normal cadence
  for agent-to-agent exchange, and any ts-based tie-break renders replies above
  the questions they answer. Filenames cannot substitute — the delivery spec
  makes clear they are not a monotonic clock.
- `to` — the target session, so `out/` documents know where they went.

`out/` is written by the sender at send time, using the same tmp-then-rename
discipline as delivery.

### Commands

| Form | Behavior |
|---|---|
| `cs -msg <session> "body"` | Starts a thread. Prints `sent to freya (thread a3f9c1)`. |
| `cs -msg --reply <thread> "body"` | Replies; target derived from the thread. |
| `cs -msg <session> --reply <thread> "body"` | Replies with the target stated. |
| `cs -msg thread <id>` | Prints the merged transcript, root first. |
| `cs -msg` | Unread, unchanged, each line carrying its thread id. |
| `cs -msg log` | Full history (`cur/` + `new/` + `out/`), thread ids shown. |

`run_mail` (`lib/53-mail.sh:165`) currently treats any first word that is not
`""` or `log` as a target session, so it needs a real command table: `log`,
`thread`, `--reply` and `-` become reserved first words, and only an unreserved
word is a target. Without this, `cs -msg thread a3f9c1` fails with "No such
session: thread".

The session-scoped alias (`lib/99-main.sh:248`) forwards everything except bare
and lone-`log` into the send path, where unrecognized words are appended to the
body (`lib/53-mail.sh:30`) — so `cs freya -msg thread a3f9c1` would silently mail
freya the text "thread a3f9c1". The existing lone-`log` guard
(`lib/99-main.sh:257`) is the pattern; it extends to every reserved word.

### Reply routing

`--reply` scans `new/`, `cur/` then `out/` for the thread and takes the peer
from the newest match: `from` for a received message, `to` for a sent one.

An explicitly named target must **equal** the derived peer. Accepting a
different one silently misroutes a reply on a typo, records the wrong peer in
`out/`, and then poisons every later newest-match derivation in that thread. The
explicit form exists for exactly one case: derivation came back empty, which is
reachable and tested — `from` is `${CLAUDE_SESSION_NAME:-}`
(`lib/53-mail.sh:89`) and sending from outside a session is supported
(`tests/test_msg.sh:46`). Empty derivation with no explicit target is an error
naming the fix. An unknown thread id is an error rather than a new thread; a typo
that silently starts a fresh conversation is worse than a refusal.

### Transcript

`cs -msg thread <id>` collects the thread's documents from `new/`, `cur/` and
`out/`, and orders them by three stated rules, because a thread is a tree and
half of it may be on another machine:

1. Start from the document with `in_reply_to: null`. If there is none — the root
   lives in the other session's mailbox, which the machine-local constraint makes
   normal — start from the earliest filename present.
2. Walk the chain. Where several documents reply to one parent, order siblings by
   filename.
3. Documents unreachable from the walk print after it, in filename order, under a
   line saying part of the thread is not on this machine.

Sent messages render `-> `, received `<- `. Reading a thread does not mark
anything read; `cs -msg` remains the only reader that moves files into `cur/`.

`cs -msg threads` (a grouped listing) is out of scope — `log` showing thread ids
covers finding one.

### Waking a session on new mail

A `Stop` hook check folds into `hooks/narrative-reminder.sh` rather than becoming
a new hook file, which would cost five registration sites. On `Stop`, unread mail
blocks the stop with a reason naming the count and telling the session to run
`cs -msg`.

**Queue interaction.** The check returns early while the walk-away queue is
`armed` or `draining`: the drain owns `Stop` (`hooks/narrative-reminder.sh:173`)
and stealing a turn would shift its pop one turn late and mis-attribute any tool
failure to the current task's circuit breaker (`hooks/tool-failure-logger.sh:62`).
But an **empty queue is never gating, whatever its recorded state says**.
`cs -queue start` writes `armed` on an empty queue (`lib/55-queue.sh:181`) and the
queue section cannot clear that state because its length is zero, so keying the
early return on state alone would suppress every mail wake permanently. The wake
reads `queue.state` itself, since `QSTATE` is only read today when the queue is
non-empty (`hooks/narrative-reminder.sh:174`).

**The re-wake guard is a snapshot, not a watermark.** `mail/woke` holds the list
of `new/` filenames present at the last wake; the hook blocks when `new/` holds
any file not in that list, then rewrites the list. Both a count and a
newest-filename high-water mark are wrong here. A count strands itself above the
live number, because unread drops to zero every time `cs -msg` moves files to
`cur/`. A newest-filename mark assumes filenames only increase, and the delivery
spec establishes they do not — same-second order is by unpadded pid, and the
clock can go backwards — so a later arrival can sort below the mark and never
wake anyone. A set membership test depends on neither property, and it is
bounded by the unread count, which the digest already bounds at five for
display.

Messages of kind `task` never trigger a wake — the queue owns them
(`lib/53-mail.sh:54`) — but they do enter the snapshot, so a task-only arrival
cannot leave a later text message unable to wake. Deciding this reads the `kind`
of each file not in the snapshot, bounded by arrivals in one turn.

The rotation nudge writes its marker before emitting
(`hooks/narrative-reminder.sh:290`) because a repeated nudge is worse than a
missed one. Both wakes invert that order — see "Emit before recording" below.

**Only the lead wakes.** A tmux-backed teammate is a full `claude` process with
its own top-level `Stop`, and the `agent_id` guard at
`hooks/narrative-reminder.sh:11` filters in-process subagents only. Left ungated,
one arrival wakes the lead and every idle teammate, all racing to `cs -msg` where
the first `mv` wins (`lib/53-mail.sh:142`) — so a teammate can consume mail the
lead then never sees, and N processes write one snapshot. Both wakes are gated on
the same `IS_LEAD` the session-start hook already computes
(`hooks/session-start.sh:371`).

`Stop` covers the turn-end case only: it fires as a turn ends, so it reaches a
session that has just finished work, not one already parked at the prompt.

**Consecutive `Stop` blocks are capped.** Claude Code reads
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8) and, past it, overrides the hook
and ends the turn. The wake blocks at most once per arrival, so the cap is not
reachable by mail alone, but the drain and the rotation nudge share the budget.

### Waking an idle session

A session parked at the prompt emits neither `Stop` nor `UserPromptSubmit`, so
no turn-boundary hook can reach it. Claude Code's `FileChanged` event does: it is
served by a chokidar watcher living on the CLI's own event loop, independent of
turn state, so an external `rename(2)` into a watched directory runs a hook while
the session is idle. That is exactly how mail is delivered
(`lib/53-mail.sh:102`), so the mailbox needs no new write to become observable.

The wake is a second hook entry, `FileChanged`, watching the recipient's
`mail/new/`:

- **No `matcher`.** `matcher` does double duty — it seeds the watch path
  (`isAbsolute(k) ? k : join(cwd, k)`, split on `|`) *and* supplies the dispatch
  query, which for this event is `basename(file_path)`. A matcher naming the
  maildir therefore watches it and then never fires, because no message's
  basename equals the directory's path. Maildir filenames are unpredictable by
  construction, so no basename matcher can be written either.
- **`watchPaths` from `SessionStart` instead.** The `SessionStart` output schema
  accepts `watchPaths` ("Absolute paths to watch for FileChanged hooks"), so the
  absolute maildir path joins the object `hooks/session-start.sh:651` already
  emits. The watcher early-returns on an empty initial path set, so supplying the
  path at session start is what arms it at all.
- **The maildir must exist before the path is emitted.** chokidar is given the
  path with no existence check, and a watch armed on a path missing *two* levels
  — both `mail/` and `new/` — never fires again for the process's lifetime, even
  after the directories appear and a message is renamed in. That is the state of
  every session that has never exchanged mail: `hooks/session-start.sh:107`
  creates `.cs/local/` only, `create_session_structure` and the worktree
  bootstrap (`lib/30-worktree.sh:27`) create `.cs/{local,memory}`, and the
  maildir is created lazily on first send or read (`lib/53-mail.sh:19`). So
  `session-start.sh` creates `mail/{tmp,new,cur}` before emitting the path,
  guarded like its sibling `mkdir` calls. Without this the wake is silently
  inert for exactly the population it exists to serve — fresh `cs -spawn`
  workers and new worktree sessions, which have never received mail by
  definition.
- **Only the lead emits the path.** `session-start.sh` runs for every top-level
  `claude` resolving the session, tmux-backed teammates included; its `agent_id`
  guard covers in-process subagents only. Arming a watcher in each would wake N
  claudes on one arrival, all racing to `cs -msg`, where the first `mv` wins
  (`lib/53-mail.sh:142`) and the rest spend a turn on "No unread mail" — with no
  guarantee the addressed actor is the winner. The path is emitted under the
  existing `IS_LEAD` gate (`hooks/session-start.sh:371`).
- **`asyncRewake: true`, and the hook exits 2.** These sit on the command object
  beside `type` and `command`. Without them the hook still runs — and delivers
  nothing: a successful `FileChanged` hook's output is discarded, and
  `additionalContext` is not in that event's output schema. Only the exit-2 path
  reaches the model, enqueued as `{mode: "task-notification", priority: "next"}`.
- **The payload is `rewakeMessage` then the hook's stderr**, wrapped in a
  system-reminder. Stderr is not the only channel: the composed text is
  `${rewakeMessage} ${stderr || stdout}`, so stdout is a fallback used whenever
  stderr is empty. Writing to exactly one of them is what makes the message
  predictable. `rewakeSummary` is the one-line terminal label.
- **`rewakeMessage` and `rewakeSummary` are marked `@internal`** in the schema,
  unlike `asyncRewake` and `watchPaths`. If a later Claude Code drops them the
  wake still works and the prefix degrades to `Stop hook blocking error from
  command "...":` — accurate but alarming, so `cs -doctor` checks for it.

Measured end to end against Claude Code 2.1.221: a session idle at the composer
for 20 s with zero prompts ever submitted ran the hook 1 s after the rename, and
then woke and completed a turn unaided. Two different latencies matter and only
the first is fast: the hook fires about a second after delivery (floored by the
watcher's `awaitWriteFinish.stabilityThreshold` of 500 ms), while visible turn
start took roughly 20 s. Nothing here should promise a one-second wake.

**Mail already unread when the watcher arms never triggers an idle wake.** The
watcher runs with `ignoreInitial: true`, so only arrivals after `SessionStart`
produce events, and anything delivered during the startup window is missed too.
Those are recovered by the `Stop` wake and the prompt digest, and a `cs -spawn`
worker is covered because its launch kick guarantees a first turn.

Arriving as a system-reminder rather than as page content is what makes the wake
actionable: the same instruction delivered as data is treated as data, and
correctly ignored.

**What the wake says.** The hook receives `file_path` and `event`, so it names
the count and tells the session to run `cs -msg` — the same reason string the
`Stop` wake uses, and for the same reason it does not inline bodies. A `task`
kind is silent here exactly as it is in the digest: the queue already owns it,
and waking on it would race the drain. The reason also tells the session to reply
only when the message needs an answer and never merely to acknowledge, because
two woken sessions exchanging courtesies is an unbounded loop (see the ceiling
below).

**The hook filters `file_path` first.** A matcher-less entry is match-all across
the *union* of every watch path in the session — other `FileChanged` matchers and
every hook's `watchPaths`, not just cs's — so the hook exits 0 unless `file_path`
lies under its own `mail/new/`, before any other work. `unlink` is dispatched as
well as `add`, so `cs -msg` moving files to `cur/` runs the hook once per file;
the filter and the snapshot make those runs inert, but the filter is what keeps
another plugin's file traffic out of cs's hook entirely.

**Coalescing, and what the snapshot means.** One arrival is one hook run, so five
messages landing together would otherwise wake five times. `mail/woke` governs
both wakes: a run exits 2 only when `new/` holds a file absent from the snapshot.

The invariant is **the snapshot is the set of arrivals already discharged** —
announced by a wake, or owned by another mechanism that will deliver them
(`task` kind, owned by the drain). So a run writes the snapshot exactly when it
discharges something: the wake it just emitted, or a `task` arrival the drain
already owns. A run silenced by a gate discharges nothing and writes nothing; see
the gate rule below.

**Concurrent writers.** Both wakes write this file, and the idle wake overlaps
*itself* — one hook run per arriving file, run in the background. Two rules:

- Write tmp-then-rename with a **per-process** tmp name (`woke.tmp.$$`, the shape
  already used for `queue.popping.$$` at `hooks/narrative-reminder.sh:197`). The
  fixed-name `$FILE.tmp` pattern used elsewhere in that hook is single-writer;
  two writers sharing one tmp name truncate and splice each other, and the rename
  then publishes the spliced file — tmp+rename alone does not save it.
- Accept duplicates. Each writer lists all of `new/` and last write wins, so a
  stale scan can drop a filename back out of the snapshot and re-announce it
  later. Every race resolves toward waking twice, never toward losing a wake,
  because membership is per-file and filenames are unique forever. Exactly-once
  would need a lock, and macOS stock userland has no `flock(1)`. Per-writer
  snapshots are worse: they do not fix idle-vs-idle overlap and they add
  cross-wake double-announces.

**Emit before recording.** The rotation nudge writes its marker before emitting
(`hooks/narrative-reminder.sh:290`) because a duplicate nudge is worse than a
lost one. For a wake the preference inverts: compose and emit first, record
after. A kill in between then costs a duplicate wake rather than a silent strand,
and the strand is not recoverable where it matters — an idle unattended worker
submits no prompt, so there is no digest, and ends no turn, so there is no `Stop`
wake. Its next chance would be the next arrival, which may never come.

**A ceiling on wakes.** Nothing else bounds them: the drain's breakers gate
drains only, and `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` counts consecutive `Stop`
blocks, which a wake-started turn is not. Two sessions told to correspond can
volley indefinitely, and `_notify_spawner` already means N finishing workers wake
one spawner N times. So the hook keeps a rolling count beside the snapshot and
stays silent past a ceiling, letting the digest carry the backlog until the next
human prompt resets it (`hooks/scope-prompt.sh` runs on every prompt). Shipping
default-on autonomy with no breaker at all is out of character for a codebase
where the drain has three.

**Degrading on older Claude Code.** A `FileChanged` entry in `settings.json` is
inert on a version that does not know the event, and `watchPaths` in the
`SessionStart` output is an unknown key that is ignored. So the wake is
additive: where it is unavailable, mail behaves exactly as it does today. `cs
-doctor` reports whether the running Claude Code serves the event.

**On by default.** A wake spends tokens unprompted, which is the point: an
agent-to-agent exchange that cannot advance without a human keystroke is the
problem this change exists to close, and a wake nobody enabled is a wake nobody
gets. `CS_NO_MAIL_WAKE=1` silences it for a session that should stay quiet,
following `CS_NO_ITERM2` (`hooks/narrative-reminder.sh:68`).

**One gate rule for both gates.** A run suppressed by `CS_NO_MAIL_WAKE` or by the
queue exits 0 **without touching the snapshot**. Recording a suppressed arrival
would mark it discharged for the `Stop` wake as well — which the operator did not
disable — so the message would surface only on the next human keystroke, which is
exactly the gap this change exists to close. Leaving it unrecorded costs one
`kind` read per later run and yields a single catch-up wake once the gate lifts.

The tempting opposite argument — that an unrecorded arrival could suppress a
later one — does not hold under set membership: a later arrival is a new
filename, always absent from the snapshot, and wakes on its own account
regardless of what was left behind.

**Queue interaction, again.** The idle wake gates on the queue exactly as the
`Stop` wake does, and for the same reason: a rewake enqueued at `priority:
"next"` while a drain is armed or draining steals a turn, shifting the pop one
turn late and mis-attributing a tool failure to the current task's breaker
(`hooks/tool-failure-logger.sh:62`, which counts turn-blind, against a budget the
drain resets at every pop). The same exception holds — an empty queue is never
gating whatever `queue.state` records — and it matters more here, because
`cs -spawn` workers are both the sessions that run drains and the sessions that
most need the wake.

**The wake is not strictly between turns.** `priority: "next"` is the
background-task-notification path, delivered at the next tool boundary, so a wake
arriving while a session is mid-turn interrupts it rather than waiting for it to
finish — the same cost this spec cites when rejecting `PostToolUse` polling. The
queue gate covers the case where that interruption is expensive; elsewhere it is
accepted, and it is the price of not polling.

## Testing

Extends `tests/test_msg.sh`, TDD, one failing test at a time; `build.sh` runs
first because the suite exercises `bin/cs`.

1. A send stamps a `thread`, lands in the target's `new/`, and writes the
   sender's `out/`; the sender's own unread count does not move.
2. `--reply` derives the target from the thread and reuses its id.
3. `--reply` errors on an unknown thread; errors when derivation is empty and no
   target is given; errors when an explicit target differs from a non-empty
   derived peer; succeeds when derivation is empty and a target is given.
4. Thread generation retries on a collision with an existing root, and lookup
   refuses an id whose documents name two different correspondents.
5. `cs -msg thread <id>` orders a question and its same-second reply by
   `in_reply_to`; renders an orphan section when the root is absent.
6. `cs freya -msg thread abc` errors instead of mailing the words.
7. The wake fires once per new arrival; fires again after the recipient has read
   and a further message arrives; does not fire for `task`-kind; does not fire
   while a non-empty queue is armed or draining; **does** fire when the queue is
   empty and its recorded state is `armed`.

8. The idle wake: the `FileChanged` hook exits 2 on a text arrival absent from
   the snapshot and exits 0 on a `task` arrival; a second arrival already in the
   snapshot does not re-exit 2; the reason names the count and `cs -msg`, never a
   body. The end-to-end wake needs a live session, so it stays a documented
   manual smoke (`docs/windows-manual-smoke.md` is the precedent): idle a session
   at the composer, `cs -msg` it from a second shell, observe the turn start. The
   smoke must first confirm hooks are running at all — Claude Code skips every
   hook when workspace trust has not been accepted, saying so only in
   `--debug-file` while the UI looks normal, so an unconfirmed smoke passes
   vacuously.
9. `session-start.sh` **creates** `mail/{tmp,new,cur}` and then emits the
    absolute path in `watchPaths` — asserted against a session directory that has
    never exchanged mail, which is the state that made the watcher inert. The
    entry is emitted only when `IS_LEAD=1`.
10. A gated run records nothing: with `CS_NO_MAIL_WAKE=1`, and again with a
    non-empty armed queue, the hook exits 0 **and `mail/woke` is unchanged**, and
    the next ungated `Stop` then blocks for that same arrival. The idle wake does
    fire when the queue is empty and its recorded state is `armed`.
11. The hook exits 0 for a `file_path` outside its own `mail/new/`, and for an
    `unlink` event, before consulting the snapshot.
12. The snapshot is written tmp-then-rename under a per-process name, and a run
    that does not wake never writes it. Two concurrent writers seeded with
    different views leave a parseable file (the assertion is on the file, not on
    the wake count — duplicates are accepted).
13. Wakes stop at the ceiling and resume after a prompt resets the counter.

Surfaces: `README.md`, `docs/session-layout.md` (`out/`, `woke`), `docs/hooks.md`
(both wakes), `install.sh` (the `FileChanged` registration and its uninstall),
`lib/60-doctor.sh` (whether the running Claude Code serves the event, whether it
still honours `rewakeMessage`, and a note that an adopted session on a network
mount gets no filesystem events and so no idle wake),
`completions/_cs` and `completions/cs.bash` (`--reply`, `thread`),
`lib/10-help.sh`, and `CHANGELOG.md`.

## Rejected

**Reply routing without a transcript.** Cheaper by one directory, but an agent
could reply into a conversation it cannot read, which is most of the value gone.

**Thread id = the first message's `id`.** Free, but 20-odd characters of digits
and dashes is not retypable, and the field would mean two things at once.

**Ordering the transcript by `ts`, or by filename.** Whole-second timestamps put
a reply above its question in the common case, and filenames are not a clock.

**`PostToolUse` polling for the wake.** Runs on every tool call, interrupts
mid-thought, and still cannot reach a session idle at the prompt.

**Sender-side `tmux send-keys` for the idle wake.** Reaches an idle session, and
was the only candidate before `FileChanged`. Rejected on two counts, either
fatal. Nothing records the target's pane: the window id captured at spawn feeds
an info message only (`lib/52-spawn.sh:76`), the statusline's `TMUX_PANE` is
never persisted (`bin/cs-statusline:557`), and the durable `spawned-by`
(`lib/75-launch.sh:168`) points the wrong way and is deleted after the final
drain (`hooks/narrative-reminder.sh:213`) — leaving name-matching, which
`lib/52-spawn.sh:50` warns is unreliable under automatic-rename. And the keys
land in the input box and submit **as user input**, indistinguishable from Alex
typing, in a pane Alex may be attached to. `FileChanged` needs no pane and
fabricates nothing.

**MCP Channels (`notifications/claude/channel`).** Does wake a fully idle
session. Rejected for now on three counts: a cs-authored stdio server is not on
the preview allowlist, so it needs
`--dangerously-load-development-channels`, which opens a **blocking confirmation
dialog at startup** and so breaks unattended `cs -spawn`; availability is behind
a remote flag that defaults off, first-party auth only, plus an org toggle; and
the payload arrives as page content, which the recipient correctly treats as
data — a probe worded exactly as cs mail woke the session and was then declined
as injection. Reconsider if cs ships a channel as an allowlisted plugin.

**Peer-session delivery over a Unix socket.** The binary carries a session
registry and a socket sender for exactly this, but the accessor that would
publish a session's own socket path is a no-op stub and no live session
registers one. Real code, inert build. Watch, do not build on.

**Agent-team messaging.** The teammate inbox is polled once a second and
auto-submits to an idle teammate, which is the behavior cs wants — but it
addresses only teammates a lead spawned inside one session's lifetime, and cs
sessions are independently launched, symmetric, and outlive any one
conversation.

**The `Notification` event (`idle_prompt`).** The one event that fires from pure
idleness, and useless here: its output has no injection field, so it can ring a
bell and nothing more.
