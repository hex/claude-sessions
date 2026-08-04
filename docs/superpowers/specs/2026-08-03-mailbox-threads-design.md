# Mailbox threads and mail wake-up

Date: 2026-08-03
Status: proposed (revision 5)

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
(`lib/53-mail.sh:84`).

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

`run_mail` (`lib/53-mail.sh:130`) currently treats any first word that is not
`""` or `log` as a target session, so it needs a real command table: `log`,
`thread`, `--reply` and `-` become reserved first words, and only an unreserved
word is a target. Without this, `cs -msg thread a3f9c1` fails with "No such
session: thread".

The session-scoped alias (`lib/99-main.sh:248`) forwards everything except bare
and lone-`log` into the send path, where unrecognized words are appended to the
body (`lib/53-mail.sh:45`) — so `cs freya -msg thread a3f9c1` would silently mail
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
(`lib/53-mail.sh:81`) and sending from outside a session is supported
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
`armed` or `draining`: the drain owns `Stop` (`hooks/narrative-reminder.sh:167`)
and stealing a turn would shift its pop one turn late and mis-attribute any tool
failure to the current task's circuit breaker (`hooks/tool-failure-logger.sh:59`).
But an **empty queue is never gating, whatever its recorded state says**.
`cs -queue start` writes `armed` on an empty queue (`lib/55-queue.sh:77`) and the
queue section cannot clear that state because its length is zero, so keying the
early return on state alone would suppress every mail wake permanently. The wake
reads `queue.state` itself, since `QSTATE` is only read today when the queue is
non-empty (`hooks/narrative-reminder.sh:149`).

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
(`lib/53-mail.sh:74`) — but they do enter the snapshot, so a task-only arrival
cannot leave a later text message unable to wake. Deciding this reads the `kind`
of each file not in the snapshot, bounded by arrivals in one turn.

Writing the snapshot before emitting the block matches what the rotation nudge
already does (`hooks/narrative-reminder.sh:256`): a kill between the two loses
exactly one wake, which the prompt digest then recovers.

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
- **`asyncRewake: true`, and the hook exits 2.** These sit on the command object
  beside `type` and `command`. Without them the hook still runs — and delivers
  nothing: a successful `FileChanged` hook's output is discarded, and
  `additionalContext` is not in that event's output schema. Only the exit-2 path
  reaches the model, enqueued as `{mode: "task-notification", priority: "next"}`.
- **The payload is the hook's stderr**, prefixed by `rewakeMessage` and wrapped in
  a system-reminder; stdout is discarded. `rewakeSummary` is the one-line label
  shown in the terminal.

Measured end to end against Claude Code 2.1.221: a session idle at the composer
for 20 s with zero prompts ever submitted ran the hook 1 s after the rename, then
started and completed a turn on its own. Latency has a floor of the watcher's
`awaitWriteFinish.stabilityThreshold` (500 ms).

Arriving as a system-reminder rather than as page content is what makes the wake
actionable: the same instruction delivered as data is treated as data, and
correctly ignored.

**What the wake says.** The hook receives `file_path` and `event`, so it names
the count and tells the session to run `cs -msg` — the same reason string the
`Stop` wake uses, and for the same reason it does not inline bodies. A `task`
kind is silent here exactly as it is in the digest: the queue already owns it,
and waking on it would race the drain.

**Coalescing.** One arrival is one hook run, so five messages landing together
would otherwise wake five times. The `mail/woke` snapshot governs both wakes: the
hook exits 2 only when `new/` holds a file absent from the snapshot, then rewrites
it. The snapshot's set-membership property is what makes it safe to share — it
depends on neither a monotonic count nor filename order.

**Degrading on older Claude Code.** A `FileChanged` entry in `settings.json` is
inert on a version that does not know the event, and `watchPaths` in the
`SessionStart` output is an unknown key that is ignored. So the wake is
additive: where it is unavailable, mail behaves exactly as it does today. `cs
-doctor` reports whether the running Claude Code serves the event.

**Opt-in.** A wake spends tokens unprompted. That is the point for a `cs -spawn`
worker and an intrusion for a session parked mid-thought, so the idle wake is
enabled per session rather than globally.

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
   at the composer, `cs -msg` it from a second shell, observe the turn start.
9. `session-start.sh` emits an absolute `watchPaths` entry for the maildir, and
   omits it when the mailbox cannot be resolved.

Surfaces: `README.md`, `docs/session-layout.md` (`out/`, `woke`), `docs/hooks.md`
(both wakes), `install.sh` (the `FileChanged` registration and its uninstall),
`lib/60-doctor.sh` (whether the running Claude Code serves the event),
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
never persisted (`bin/cs-statusline:569`), and the durable `spawned-by`
(`lib/75-launch.sh:168`) points the wrong way and is deleted after the final
drain (`hooks/narrative-reminder.sh:183`) — leaving name-matching, which
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
