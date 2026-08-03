# Mailbox threads, body limits, and mail wake-up

Date: 2026-08-03
Status: proposed

## Problem

`cs -msg` delivers a message into another session's inbox and stops there. Three
gaps follow from that.

**No conversation.** Every message is an island. An agent that receives "can you
check X?" can send a message back, but nothing links the two, and neither side
can re-read the exchange. After a rotation, an agent has no way to find out what
it already said.

**A cap nobody chose.** `MAIL_BODY_MAX=4096` (`lib/53-mail.sh:4`) rejects any
body over 4096 bytes. It arrived with the original send path in `c214c4e` with no
comment, no test, and no mention in the README or docs. It does not guard what it
appears to guard: `hooks/scope-prompt.sh:121` already clamps each digest body to
160 characters and the digest to five messages, `jq` escapes newlines so line
orientation is length-independent, and `ARG_MAX` binds the argv long before 4096.
What it does do is hard-fail a 5KB handoff, with no stdin path to send one.

**Mail only lands when a human types.** The unread digest is built by
`hooks/scope-prompt.sh`, a `UserPromptSubmit` hook. A session sitting idle learns
about mail on Alex's next keystroke and not before, so an agent-to-agent exchange
cannot advance without a human in the loop.

## Constraints

- `cs` and its tests run on macOS stock `/bin/bash` 3.2 and BSD userland. No
  bash 4 features, no GNU-only `sed`/`awk`/`stat`.
- `.cs/local/` is machine-local and never synced. A thread's two halves live in
  two session directories and may live on two machines. Nothing here may assume
  both halves are reachable.
- Unread counts are computed by counting newline bytes past a cursor, in the
  shell (`_mail_total`) and independently in the Rust TUI
  (`tui/src/session.rs:733`). Both deliberately avoid parsing, so a torn final
  line cannot collapse the count. That invariant stays.
- `jq` is already a hard requirement for `cs -msg`.

## Design

### The mailbox gains an outbox

`_mail_send` writes only to the recipient's `inbox.jsonl`; the sender keeps no
record. A readable thread needs the sender's own half, so a send now also
appends the message to the sender's `.cs/local/mail/sent.jsonl`.

A separate file, not a `dir: out` record inside `inbox.jsonl`. Interleaving
outbound records into the inbox breaks the newline-counting unread math: every
send would inflate the session's own unread badge. The obvious repair — advance
the `seen` cursor by one on each send — is racy, because another session can
append an inbound message between the two operations, and the cursor bump would
then mark that inbound message as read. Silently swallowed mail is the worst
failure this feature could introduce. A separate file has exactly one writer,
which removes the race, leaves both unread implementations untouched, and costs
only a timestamp-ordered merge at render time.

`sent.jsonl` carries the same record shape as `inbox.jsonl` plus a `to` field.
It has no cursor: a session has read everything it wrote.

### Thread identity

Two new fields on every record:

- `thread` — a 6-hex-digit token, e.g. `a3f9c1`. A message that starts a
  conversation generates one; a reply copies its parent's. Generated with
  `printf '%06x' $(( ((RANDOM << 15) | RANDOM) & 0xFFFFFF ))`, which is bash 3.2
  safe and gives 16.7M values. Uniqueness only has to hold within one mailbox
  pair, so this is ample.
- `to` — on `sent.jsonl` records only, the target session name. `inbox.jsonl`
  already records `from`.

Short and typeable is the whole point: an agent has to be able to put a thread id
into a command line without copying a 25-character `1754230000-12345-9876`. The
existing `id` field is unchanged and still uniquely identifies a single message.

### Commands

| Form | Behavior |
|---|---|
| `cs -msg <session> "body"` | Starts a thread. Prints the id: `sent to freya (thread a3f9c1)`. |
| `cs -msg --reply <thread> "body"` | Replies. The target is derived from the thread's records, so no session name is needed. |
| `cs -msg <session> --reply <thread> "body"` | Same, target stated explicitly; errors if it disagrees with the thread. |
| `cs -msg thread <id>` | Prints the merged transcript, oldest first, direction marked. |
| `cs -msg` | Unread, unchanged, each line now carrying its thread id. |
| `cs -msg log` | Full inbox history, each line now carrying its thread id. |

`--reply` resolves the thread by scanning `inbox.jsonl` then `sent.jsonl` for a
matching `thread`, and takes the target from the newest matching record: `from`
if it came from the inbox, `to` if from sent. An unknown thread id is an error,
not a new thread — a typo that silently opens a fresh conversation is worse than
a refusal. Prefix matching is not supported; ids are already short.

`cs -msg thread <id>` merges the two files filtered to that thread and sorts by
`ts`, rendering `-> ` for sent and `<- ` for received. Records with equal `ts`
keep file order, inbox before sent. Reading a thread does not advance the unread
cursor; `cs -msg` remains the only reader that does.

A `cs -msg threads` listing is deliberately out of scope. `cs -msg log` showing
thread ids covers finding a thread, and a grouped listing can be added when
something actually needs it.

### Body limits

`MAIL_BODY_MAX` becomes 65536, with a comment saying what it protects (an inbox
line that the TUI and the digest builder scan on every render) and a test pinning
the number.

The body may come from stdin: `cs -msg <session> -` and
`cs -msg --reply <thread> -` read the body from standard input. This is what
makes the larger cap usable, since argv is the wrong channel for a multi-KB
handoff. Over-cap bodies still error rather than truncate; a silently clipped
handoff is worse than a refused one.

### Waking a session on new mail

An unread-mail check folds into `hooks/narrative-reminder.sh`, the existing
`Stop` hook, rather than becoming a new hook file — a new file costs five
registration sites.

On `Stop`, if the inbox has unread mail, the hook blocks the stop with a reason
naming the count and telling the session to run `cs -msg`. The session then reads
its mail and acts on it without waiting for a keystroke.

The loop guard is a `.cs/local/mail/woke` cursor holding the inbox total at which
the hook last woke the session. The hook blocks only when the current total
exceeds `woke`, and writes the new total immediately. A session that reads its
mail and decides to do nothing therefore stops normally on the next turn; only
genuinely new arrivals wake it again. `task`-kind mail never wakes a session,
because it is already in the walk-away queue and the drain owns it.

### Existing records

Inboxes on disk today have no `thread` and no `to`. The read paths treat a
missing `thread` as the record's own `id`, which renders every pre-threads
message as a one-message thread. This is a real backward-compatibility
allowance and needs explicit sign-off before implementation.

## Testing

Extends `tests/test_msg.sh`, TDD, one failing test at a time:

1. A new send stamps a `thread` and echoes to `sent.jsonl`; the sender's own
   unread count does not move.
2. `--reply` derives the target from the thread and reuses its id.
3. `--reply` to an unknown thread errors.
4. `cs -msg thread <id>` renders both halves in timestamp order with direction.
5. Reading a thread does not advance the `seen` cursor.
6. A body over the cap errors; a body at the cap sends; stdin carries a body
   larger than a comfortable argv.
7. The Stop hook wakes once per new arrival and not twice (`woke` cursor).
8. A record with no `thread` field renders as its own thread.

Surfaces to update alongside: `README.md`, `docs/session-layout.md` (the new
`sent.jsonl` and `woke` files), `completions/_cs` and `completions/cs.bash`
(`--reply`, `thread`), `lib/10-help.sh`, and `CHANGELOG.md`.

## Rejected

**Thread id = first message id.** Free, but 25 characters of digits and dashes is
not something an agent should have to retype, and the value would then mean two
things at once.

**Reply routing without a transcript.** Cheaper by one file, but an agent could
reply into a conversation it cannot read, which is most of the value gone.

**Mid-turn wake on `PostToolUse`.** Most responsive, but it runs on every tool
call and can interrupt an agent mid-thought. End-of-turn is where the session is
already between units of work.
