# Mailbox threads, atomic delivery, and mail wake-up

Date: 2026-08-03
Status: proposed (revision 3)

## Problem

**The inbox loses messages.** `_mail_send` appends a JSON line with
`printf '%s\n' >> inbox.jsonl` (`lib/53-mail.sh:84`). bash's `printf` flushes in
roughly 1KB stdio chunks, so one append is many `write()` calls, and `O_APPEND`
orders chunks rather than lines. Measured on stock bash 3.2, four concurrent
senders writing 4096-byte bodies left **112 of 200 lines intact**; the rest
interleaved into text that `fromjson? // empty` (`lib/53-mail.sh:97`,
`hooks/scope-prompt.sh:115`) silently drops. Concurrent delivery is a designed-in
flow: every spawned worker mails its spawner from its own Stop hook
(`hooks/narrative-reminder.sh:102`), so a fan-out finishing together is the
normal case, not an edge one. This is a live bug and everything below depends on
fixing it first.

**No conversation.** Every message is an island. A recipient can send something
back, but nothing links the two and neither side can re-read the exchange. After
a rotation an agent has no way to find out what it already said.

**Mail only lands when a human types.** The unread digest is built by
`hooks/scope-prompt.sh`, a `UserPromptSubmit` hook, so a session learns about
mail on Alex's next keystroke and not before. Agent-to-agent work cannot advance
without a human in the loop.

## Constraints

- macOS stock `/bin/bash` 3.2 and BSD userland. No bash 4 features, no GNU-only
  `sed`/`awk`/`stat`/`timeout`.
- `.cs/local/` is machine-local and never synced. A thread's two halves live in
  two session directories, possibly on two machines. Nothing may assume both are
  reachable.
- `bin/cs` is a build artifact concatenated from `lib/*.sh` by `build.sh`, and
  `tests/test_msg.sh` runs against `bin/cs`. Every lib edit needs a rebuild
  before the tests mean anything.
- Early-exiting pipe consumers (`grep -q`, `head`, `sed q`) kill `cs` at exit 141
  under `pipefail` on large payloads. Existing mail paths avoid them
  deliberately (`_mail_slice` is bounded `awk`); new paths must too.
- `jq` is already a hard requirement for `cs -msg`.

## Design

### One file per message

`.cs/local/mail/` becomes a maildir:

```
mail/
  tmp/    messages being written
  new/    received, unread
  cur/    received, read
  out/    sent by this session
```

A send writes the complete JSON document to **the recipient's** `tmp/`, then
`mv`s it into the recipient's `new/`. Both directories live in one tree, so the
rename is always same-filesystem and therefore atomic: a message is either
entirely present or entirely absent. Writing to the sender's own `tmp/` would be
wrong twice over. Adopted sessions are symlinks to arbitrary directories
(`lib/85-adopt-uninstall.sh:95`), so a cross-volume `mv` degrades to
copy-then-unlink and exposes a partially copied file inside `new/` — precisely
the non-atomicity this design exists to remove. And a sender running outside any
session has no maildir of its own, which is a supported flow
(`tests/test_msg.sh:46`). The sender creates the recipient's `tmp/`, `new/` and
`cur/` when absent, as `_mail_send` already does for `maildir`
(`lib/53-mail.sh:76`).

There is no append, therefore no interleaving, no torn tail, and no
cap-dependent corruption window. Locking the append was the alternative: it
serializes delivery, lets a killed sender's stale lock block mail, and still
leaves every reader parsing a file a crash can tear.

Filenames are `<ts>-<id>.json`, where `ts` is a zero-padded 10-digit epoch
second and `id` is the message id (`<epoch>-<pid>-<random>`, unchanged from
today), so a lexical sort is chronological and the pid keeps two workers
replying inside one second apart. A bare 15-bit `RANDOM` suffix would collide at
roughly 1 in 32768 per pair and `mv` clobbers silently, which would reintroduce
silent message loss through a different door.

**Unread becomes a file count.** `new/` holds exactly the unread messages;
`cs -msg` moves what it prints into `cur/`. The `seen` cursor and all the
newline arithmetic built on it are deleted:

| Site | Now | Becomes |
|---|---|---|
| `lib/53-mail.sh` `_mail_total`/`_mail_cursor`/`_mail_set_cursor` | `wc -l` past a cursor | count `new/*.json` |
| `bin/cs-statusline:544` `_seg_mail` | `while read` line count minus cursor | count `new/*.json` |
| `tui/src/session.rs:733` `unread_mail_count` | count `\n` bytes, minus cursor | `read_dir(new)` filtered to `*.json` |
| `hooks/scope-prompt.sh:99` `_build_mail_digest` | `awk` line slice past the cursor | bounded scan of `new/*.json` |

All four filter to `*.json`, and that is load-bearing: an unfiltered count picks
up a `.DS_Store`, a `tmp/` leftover, or a subdirectory, and a phantom unread
that `cs -msg` cannot clear is a badge that never goes out in both the TUI and
the status bar. The shell counters need the bash 3.2 `[ -e ]` guard, since there
is no `nullglob` and an unmatched glob comes back literal.

The digest is a redesign, not a retarget. Its five-message bound, 160-character
clamp and task-kind labeling operate on a line slice
(`hooks/scope-prompt.sh:113-124`) and become a bounded, sorted scan of `new/`.
Its contract — a message stays in the digest until `cs -msg` reads it — survives
unchanged, because `new/` is exactly that set.

The torn-line defenses in all of them (and the test at
`tui/src/session.rs:923`) become unnecessary rather than being weakened — an
incomplete message never appears in `new/` at all.

### Threading

Every message document:

```json
{ "id": "1754230000-4821-9173", "ts": 1754230000, "thread": "a3f9c1",
  "in_reply_to": null, "from": "sessionA", "to": "sessionB",
  "actor": "alice-example-com", "kind": "text", "body": "..." }
```

- `thread` — 6 hex digits, e.g. `a3f9c1`, generated at thread start with
  `printf '%06x' $(( ((RANDOM << 15) | RANDOM) & 0xFFFFFF ))` (verified under
  bash 3.2.57). Short because an agent has to retype it; 16.7M values is ample
  for uniqueness within one mailbox pair. `id` is unchanged and still identifies
  a single message.
- `in_reply_to` — the `id` of the message being answered, or `null` for a thread
  root. This, not the timestamp, orders the transcript. `ts` is whole seconds
  (`date +%s`), and a question and its reply inside one second is the normal
  cadence for agent-to-agent exchange, so any ts-based tie-break renders replies
  above the questions they answer.
- `to` — the target session, so `out/` records know where they went.

### Commands

| Form | Behavior |
|---|---|
| `cs -msg <session> "body"` | Starts a thread. Prints `sent to freya (thread a3f9c1)`. |
| `cs -msg <session> -` | Same, body read from stdin. |
| `cs -msg --reply <thread> "body"` | Replies; target derived from the thread. |
| `cs -msg <session> --reply <thread> "body"` | Replies with the target stated. |
| `cs -msg thread <id>` | Prints the merged transcript, root first. |
| `cs -msg` | Unread, unchanged, each line carrying its thread id. |
| `cs -msg log` | Full history (`cur/` + `new/` + `out/`), thread ids shown. |

`run_mail` (`lib/53-mail.sh:130`) currently treats any first word that is not
`""` or `log` as a target session, so it needs a real command table: `log`,
`thread`, `--reply` and `-` become reserved first words, and only an unreserved
word is a target. Without this, `cs -msg thread a3f9c1` fails with
"No such session: thread".

The session-scoped alias (`lib/99-main.sh:248`) forwards everything except bare
and lone-`log` into the send path, where unrecognized words are appended to the
body (`lib/53-mail.sh:45`) — so `cs freya -msg thread a3f9c1` would silently mail
freya the text "thread a3f9c1". The existing lone-`log` guard
(`lib/99-main.sh:257`) is the pattern; it extends to every reserved word.

`--reply` scans `new/`, `cur/` then `out/` for the thread and takes the target
from the newest match: `from` for a received message, `to` for a sent one. When
that value is empty the reply errors and names the fix. Empty is reachable and
tested: `from` is `${CLAUDE_SESSION_NAME:-}` (`lib/53-mail.sh:81`) and sending
from outside a session is a supported flow (`tests/test_msg.sh:46`). Supplying
the target explicitly is then accepted; an explicit target always wins, because
the only case where it can "disagree" with the thread is the empty one. An
unknown thread id errors rather than opening a new thread — a typo that silently
starts a fresh conversation is worse than a refusal.

`cs -msg thread <id>` collects the thread's documents from `new/`, `cur/` and
`out/`, and orders them by three stated rules, because a thread is a tree and
half of it may be missing:

1. Start from the document with `in_reply_to: null`. If there is none — the root
   lives in the other session's mailbox, which the machine-local constraint
   makes normal — start from the earliest filename present.
2. Walk the chain. Where several documents reply to the same parent, order those
   siblings by filename.
3. Documents unreachable from the walk print after it, in filename order, under
   a line saying part of the thread is not on this machine.

Sent messages render `-> `, received `<- `. Reading a thread does not mark
anything read; `cs -msg` remains the only reader that moves files into `cur/`.

`cs -msg threads` (a grouped listing) is deliberately out of scope — `log`
showing thread ids covers finding one.

### Body size

`MAIL_BODY_MAX` becomes 65536, carrying a comment saying what it now bounds:
render cost in the digest builder and the TUI, not corruption. The current 4096
is not undocumented — `tests/test_msg.sh:104` pins the rejection and
`docs/superpowers/specs/2026-07-18-cross-session-mailbox-design.md:34` records
it — so both move together with the new number.

`-` reads the body from stdin, which is what makes the larger cap reachable;
argv is the wrong channel for a multi-KB handoff. Over-cap bodies still error
rather than truncate: a silently clipped handoff is worse than a refused one.

### Waking a session

Two paths, because a `Stop` hook alone cannot do it. `Stop` fires when a turn
ends, so a session parked at the prompt with no active turn emits no event and
still waits for a keystroke.

**Mid-turn arrivals — `Stop`.** An unread check folds into
`hooks/narrative-reminder.sh` (the existing `Stop` hook; a new hook file costs
five registration sites). It sits above the queue section but returns
immediately when the queue state is `armed` or `draining`. During a walk-away
run the drain owns `Stop` (`hooks/narrative-reminder.sh:167-209`) and stealing a
turn from it would shift its pop one turn late and mis-attribute any tool
failure to the current task's circuit breaker
(`hooks/tool-failure-logger.sh:59`). Mail therefore waits for the drain to
finish, and that is stated behavior rather than an accident of ordering.

The wake reads `queue.state` itself rather than relying on `QSTATE`, which today
is only read when the queue is non-empty (`hooks/narrative-reminder.sh:149`); a
stale `draining` beside an empty queue must not suppress mail forever, so an
empty queue counts as not draining regardless of the recorded state.

The guard against re-waking is `mail/woke`, holding **the filename of the newest
message delivered at the last wake** — not a count. A count cannot work here:
unread drops to zero every time `cs -msg` moves files to `cur/`, so a
count-based watermark strands itself above the live number and the session goes
deaf until that many messages pile up at once. Filenames sort chronologically
and never decrease, so the rule is: wake when `new/` holds any file sorting
after `woke`, then write the newest such filename. A session that reads its mail
and does nothing stops normally next turn; genuinely new arrivals still wake it.

Messages of kind `task` never trigger a wake — the walk-away queue already owns
them (`lib/53-mail.sh:74`) — but they do advance `woke`, so a task-only arrival
cannot leave a later text message unable to wake. Deciding this requires reading
the `kind` of each file past the watermark, which is bounded by the number of
new arrivals in one turn, not by mailbox size.

Advancing the watermark before emitting the block is safe, and matches what the
rotation nudge already does (`hooks/narrative-reminder.sh:256`): a kill between
the two loses exactly one wake, which the prompt digest then recovers.

**Idle sessions — deferred.** The `Stop` wake cannot reach a session parked at
the prompt. The sender-side `tmux send-keys` nudge that would have covered it is
not specified here, because review found it rests on a pane that nothing
records: the window id captured at spawn is used only for an info message
(`lib/52-spawn.sh:76`), the statusline's `TMUX_PANE` is never persisted
(`bin/cs-statusline:569`), and the only durable fact is the worker-side
`spawned-by` (`lib/75-launch.sh:168`), which points the wrong way and is deleted
after the final drain (`hooks/narrative-reminder.sh:183`). Resolution would
degrade to matching a window by name, which `lib/52-spawn.sh:50` itself warns is
unreliable under tmux automatic-rename. Worse, `send-keys` into a live Claude
Code pane lands in the input box and submits **as user input**, indistinguishable
from Alex typing, in a pane Alex may be attached to. Closing the idle gap needs
a recorded window-id handshake written at spawn and invalidated on window death;
that is its own change.

### Existing mailboxes

`migrate_session` (`lib/45-migrate.sh:138`) gains a step keyed on one thing:
`mail/inbox.jsonl` exists. It must **not** also require `mail/new` to be absent.
Delivery creates the recipient's maildir on send, while `migrate_session` runs
only when a session is next opened (`lib/99-main.sh:378`), so a session that
receives one new-format message before its next open would have `new/` already
present, the gate would read false forever, and its legacy unread mail would be
stranded — invisible, because every reader now looks only at `new/`. Keyed on
the file alone the step is idempotent and merges rather than initializes.

Each parseable line becomes a document in `cur/`, except lines past the old
`seen` cursor, which land in `new/`. Each gets `thread` set to its own `id` and
`in_reply_to: null`, rendering as a one-message thread. Lines that do not parse
move to `mail/corrupt.jsonl` rather than being dropped — they are evidence of
the tearing this design removes. `inbox.jsonl` and `seen` are deleted afterward,
so no code path reads the old layout and there is no permanent compatibility
branch.

One hole stays open by choice: an un-upgraded `cs` on the same machine (stale
dev checkouts exist) can recreate `inbox.jsonl` with a legacy append after
migration, and that message is only picked up at the recipient's next open, when
migration runs again. Migration being keyed on the file rather than a version
marker is what makes that recoverable instead of permanent.

This is data migration and it needs sign-off before implementation.

## Testing

Extends `tests/test_msg.sh`, TDD, one failing test at a time. `build.sh` runs
before each test run because the suite exercises `bin/cs`.

1. Delivery is atomic **by mechanism**, asserted directly: the send path
   performs no append to a shared file, and every document that appears in
   `new/` parses whole. A timing test — N backgrounded `cs -msg` calls racing —
   does not work as the RED step and must not be written: measured, 8 concurrent
   one-shot 64KB appends over 30 rounds produced zero tearing, because a single
   send's writes are microseconds inside a multi-millisecond process, and real
   `cs` startup adds ~100ms of skew on top. Such a test would pass against the
   broken implementation most runs and flake on CI. The corruption is real —
   it needs sustained overlapping writers to surface — so any soak-style
   reproduction stays out of the default suite.
2. A send stamps a `thread`, lands in the target's `new/`, and writes the
   sender's `out/`; the sender's own unread count does not move.
3. `cs -msg` moves what it printed from `new/` to `cur/`; a second run reports
   nothing unread.
4. `--reply` derives the target from the thread and reuses its id.
5. `--reply` errors on an unknown thread, and on a thread whose derived target
   is empty; the explicit-target form then succeeds.
6. `cs -msg thread <id>` orders a question and its same-second reply by
   `in_reply_to`, not by `ts`.
7. `cs freya -msg thread abc` errors instead of mailing the words.
8. A body over the cap errors; a body at the cap sends; stdin carries a body
   larger than a comfortable argv.
9. The Stop wake fires once per new arrival, not twice; fires again after the
   recipient has read its mail and a further message arrives (the watermark
   regression); does not fire for `task`-kind; does not fire while the queue is
   armed or draining; does fire when the queue is empty but its recorded state
   is stale.
10. Migration splits a legacy `inbox.jsonl` honoring the old `seen` cursor,
    quarantines an unparseable line, and still runs when `new/` already exists.
11. A non-`.json` file in `new/` (a `.DS_Store`, a `tmp/` leftover) is counted
    as unread by none of the four readers.

Rust-side: `tui/src/session.rs` unread tests are rewritten against `new/`,
including the non-`.json` case.

Surfaces to update: `README.md`, `docs/session-layout.md` (the maildir and
`woke`), `docs/hooks.md` (the Stop wake), `docs/statusline.md` (which documents
the line-count basis), `completions/_cs` and `completions/cs.bash` (`--reply`,
`thread`, `-`), `lib/10-help.sh`, `hooks/scope-prompt.sh`, `bin/cs-statusline`,
`tui/`, `tests/test_spawn.sh` and `tests/test_statusline.sh` (both assert
against `inbox.jsonl`), and `CHANGELOG.md`.

## Rejected

**Locking the append.** Keeps every reader and the cursor untouched, but
serializes delivery, lets a killed sender's stale lock block mail, and still
leaves readers parsing a file a crash can tear.

**Threads on the existing append, corruption filed separately.** Fastest to a
demo, but it builds a transcript feature on a substrate that drops messages.

**Thread id = the first message's `id`.** Free, but 20-odd characters of digits
and dashes is not retypable, and the field would mean two things at once.

**Ordering the transcript by `ts`.** Whole-second timestamps put a reply above
its question in the common case.

**`PostToolUse` polling for the wake.** Runs on every tool call, interrupts
mid-thought, and still cannot reach a session that is idle at the prompt.
