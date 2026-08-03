# Atomic delivery for the mailbox and the walk-away queue

Date: 2026-08-03
Status: proposed

This is a bug fix and stands alone. The threads design
(`2026-08-03-mailbox-threads-design.md`) depends on it and must not ship first.

## Problem

Delivery appends a line to a shared file:

- mail — `printf '%s\n' "$line" >> "$maildir/inbox.jsonl"` (`lib/53-mail.sh:84`)
- walk-away queue — the same idiom in `_queue_add` (`lib/55-queue.sh`), reached
  by `task`-kind mail (`lib/53-mail.sh:74`)

bash's `printf` flushes in roughly 1KB stdio chunks, so one append is many
`write()` calls, and `O_APPEND` orders chunks rather than lines. Measured on
stock bash 3.2, four concurrent senders writing 4096-byte bodies left **112 of
200 lines intact**; the rest interleaved into text that `fromjson? // empty`
(`lib/53-mail.sh:97`, `hooks/scope-prompt.sh:115`) silently discards.

Concurrent delivery is designed in, not exotic: every spawned worker mails its
spawner from its own Stop hook (`hooks/narrative-reminder.sh:102`), so a fan-out
finishing together is the normal case.

Mail loss is the visible half. The queue is the dangerous half: a spliced queue
line is not dropped, it is **executed** by the drain.

## Constraints

- macOS stock `/bin/bash` 3.2 and BSD userland. No bash 4 features, no GNU-only
  `sed`/`awk`/`stat`/`timeout`.
- `bin/cs` is built from `lib/*.sh` by `build.sh`, and the tests run against
  `bin/cs`. Every lib edit needs a rebuild before the tests mean anything.
- `.cs/local/` is machine-local and never synced.
- Early-exiting pipe consumers (`grep -q`, `head`, `sed q`) kill `cs` at exit 141
  under `pipefail` on large payloads. Existing mail paths avoid them
  deliberately; new paths must too.

## Design

### Mail: one file per message

`.cs/local/mail/` becomes a maildir:

```
mail/
  tmp/    messages being written
  new/    received, unread
  cur/    received, read
```

A send writes the complete document to **the recipient's** `tmp/`, then `mv`s it
into the recipient's `new/`. Both live in one tree, so the rename is always
same-filesystem and therefore atomic: a message is either entirely present or
entirely absent.

Sender-side `tmp/` would be wrong twice over. Adopted sessions are symlinks to
arbitrary directories (`lib/85-adopt-uninstall.sh:95`), so a cross-volume `mv`
degrades to copy-then-unlink and exposes a partially copied file inside `new/`.
And a sender running outside any session has no maildir of its own, which is a
supported flow (`tests/test_msg.sh:46`). The sender creates the recipient's
`tmp/`, `new/` and `cur/` when absent, as `_mail_send` already does for
`maildir` (`lib/53-mail.sh:76`).

Filenames are `<ts>-<id>.json`, `ts` a zero-padded 10-digit epoch second and
`id` the existing message id (`<epoch>-<pid>-<random>`). The pid keeps two
workers replying inside one second from colliding; a bare 15-bit `RANDOM` suffix
collides at roughly 1 in 32768 per pair and `mv` clobbers silently, which would
reintroduce silent loss through a different door. **These names are not a
monotonic clock** — same-second order is by unpadded pid, and the wall clock can
go backwards — so nothing may treat filename order as arrival order. The
threads spec's transcript ordering and wake marker both depend on that caveat.

### Queue: one file per task

`_queue_add`'s append has the same defect and gets the same fix. The queue
becomes a directory of one file per task, named `<ts>-<pid>-<random>`, staged in
a sibling `queue.tmp/` and renamed into place. The drain pops by taking the
lexically first entry and `mv`ing it aside before running it, which also makes
the pop atomic against a second drain — something the current
read-first-line-then-rewrite cannot promise. `queue.state` and `queue.declined`
remain sibling files.

**The queue has more writers than the mailbox, and they are not all shell.**
`bin/cs-statusline` `_seg_notes` line-counts the queue (~line 523);
`tui/src/session.rs` reads it in `read_queue` and `queue_depth` (lines 292, 421);
and `tui/src/app.rs` does full CRUD, where `append_notes_task` is the same
append defect and replace/delete address tasks by line index. All convert to the
directory layout. Addressing becomes "the nth entry of the sorted listing", and
that ordering rule is stated once and used by every reader, so the shell, the
status bar and the TUI cannot disagree about which task is nth. Listings filter
to task files, so `queue.tmp/` is never a task.

**Legacy queue migration.** Every existing session has a regular file at
`.cs/local/queue`, so `mkdir` there fails and an upgrade would break
`cs -queue add`, the TUI Notes panel and the drain together while stranding
queued work. Migration is keyed on "`queue` is a regular file" — not on the
directory being absent, which the first write would destroy — and runs lazily
from the queue accessors, needing no session-open hook. Order mirrors the mail
migration: `mv queue queue.migrating`, convert each non-blank line to one task
file preserving order, delete `queue.migrating`. A stale writer holding an open
descriptor keeps writing into the renamed inode and its lines are still
converted.

Both mail and the queue therefore stop appending to shared files, which is the
whole point: locking was the alternative, and it serializes delivery, lets a
killed sender's stale lock block work, and still leaves readers parsing a file
that a crash can tear.

### Unread becomes a file count

`new/` holds exactly the unread messages; `cs -msg` moves what it prints into
`cur/`. The `seen` cursor and all the newline arithmetic built on it are deleted:

| Site | Now | Becomes |
|---|---|---|
| `lib/53-mail.sh` `_mail_total`/`_mail_cursor`/`_mail_set_cursor` | `wc -l` past a cursor | count `new/*.json` |
| `bin/cs-statusline:544` `_seg_mail` | `while read` line count minus cursor | count `new/*.json` |
| `tui/src/session.rs:733` `unread_mail_count` | count `\n` bytes, minus cursor | `read_dir(new)` filtered to `*.json` |
| `hooks/scope-prompt.sh:99` `_build_mail_digest` | `awk` line slice past the cursor | bounded scan of `new/*.json` |

All four filter to `*.json`, and that is load-bearing: an unfiltered count picks
up a `.DS_Store`, a `tmp/` leftover, or a subdirectory, and a phantom unread that
`cs -msg` cannot clear is a badge that never goes out in both the TUI and the
status bar. The shell counters need the bash 3.2 `[ -e ]` guard, since there is
no `nullglob` and an unmatched glob comes back literal.

The digest is a redesign, not a retarget: its five-message bound, 160-character
clamp and task-kind labeling operate on a line slice
(`hooks/scope-prompt.sh:113-124`) and become a bounded, sorted scan of `new/`.
Its contract — a message stays in the digest until `cs -msg` reads it — survives
unchanged, because `new/` is exactly that set.

The torn-line defenses in all of them (and the test at `tui/src/session.rs:923`)
become unnecessary rather than being weakened: an incomplete message never
appears in `new/` at all.

### Body size

`MAIL_BODY_MAX` becomes 65536 **only once both appends are gone**. Raising it
first would widen the interleave window on the queue path, which is the one that
executes what it reads. The current 4096 is not undocumented —
`tests/test_msg.sh:104` pins the rejection and the 2026-07-18 mailbox spec
records it — so both move together with the new number, which now bounds render
cost rather than corruption.

The body may be read from stdin with `cs -msg <session> -`, which is what makes
the larger cap reachable; argv is the wrong channel for a multi-KB handoff.
Over-cap bodies still error rather than truncate.

### Migrating existing mailboxes

Keyed on one thing: `mail/inbox.jsonl` exists. It must **not** also require
`mail/new` to be absent — delivery creates the recipient's maildir on send while
migration runs at session open, so a session receiving one new-format message
before its next open would have `new/` already present, the gate would read
false forever, and its legacy unread mail would be stranded invisibly. Keyed on
the file alone, the step is idempotent and merges rather than initializes.

The step runs from `migrate_session` (`lib/45-migrate.sh:138`) **and** from the
worktree open path, which bypasses `migrate_session` entirely
(`lib/99-main.sh:354`). Worktree sessions can already hold a legacy
`inbox.jsonl` from the shipped mailbox, so mail migration is factored as its own
function callable from both, without dragging the unrelated CLAUDE.md phases
into a worktree open.

Order matters, because a stale `cs` from an old checkout can still be appending:

1. `mv inbox.jsonl inbox.jsonl.migrating` — atomic. A writer holding an open
   descriptor keeps writing into the renamed inode, and its lines are still
   converted. A writer that opens the path afterward creates a fresh
   `inbox.jsonl`, which the next open converts. Deleting first would lose both.
2. Convert each parseable line to a document: past the old `seen` cursor into
   `new/`, the rest into `cur/`.
3. Delete `inbox.jsonl.migrating` and `seen`.

Records whose `ts` is null are accepted today and pinned by test
(`tests/test_msg.sh:206`), and a record can lack a usable `id`, so neither can be
assumed present in the filename. Missing `ts` becomes the migration's own epoch
second and missing `id` a migration-local sequence, preserving order within the
legacy file. Only lines that do not parse at all go to `mail/corrupt.jsonl` —
they are evidence of the tearing this design removes, not garbage.

This is data migration and needs sign-off before implementation.

## Testing

Extends `tests/test_msg.sh` and `tests/test_queue.sh`, TDD, one failing test at a
time; `build.sh` runs before each run because the suite exercises `bin/cs`.

1. Delivery is atomic **by mechanism**: the send path performs no append to a
   shared file, and every document appearing in `new/` parses whole. A timing
   test — N backgrounded `cs -msg` calls racing — does not work as the RED step
   and must not be written: measured, 8 concurrent one-shot 64KB appends over 30
   rounds produced zero tearing, because a single send's writes are microseconds
   inside a multi-millisecond process and real `cs` startup adds ~100ms of skew.
   It would pass against the broken implementation most runs and flake on CI.
   Any soak-style reproduction stays out of the default suite.
2. The same, for `_queue_add`; and the drain's pop is atomic against a second
   drain.
2b. A legacy queue file migrates with order preserved and blank lines skipped;
   the migration is idempotent on a second call; a line appended to
   `queue.migrating` after the rename is still converted; `cs -queue add`, the
   drain and the TUI paths all work on a session upgraded from the file layout;
   and the statusline notes count, `queue_depth` and `cs -queue list` agree on
   the same directory.
3. `cs -msg` moves what it printed from `new/` to `cur/`; a second run reports
   nothing unread.
4. A non-`.json` file in `new/` is counted as unread by none of the four readers.
5. A body over the cap errors; a body at the cap sends; stdin carries a body
   larger than a comfortable argv.
6. Migration honors the old `seen` cursor, still runs when `new/` already exists,
   runs for a worktree session, quarantines an unparseable line, and converts a
   `ts:null` record without producing a malformed filename.
7. A line appended to `inbox.jsonl.migrating` after the rename is still
   converted.

Rust-side: `tui/src/session.rs` unread tests are rewritten against `new/`,
including the non-`.json` case.

Surfaces: `README.md`, `docs/session-layout.md`, `docs/statusline.md` (documents
the line-count basis for both mail and notes), `hooks/scope-prompt.sh`,
`bin/cs-statusline` (`_seg_mail` and `_seg_notes`), `tui/src/session.rs` and
`tui/src/app.rs`, `tests/test_spawn.sh`, `tests/test_statusline.sh` and
`tests/test_queue.sh`, and `CHANGELOG.md`.

## Rejected

**Locking the appends.** Keeps every reader and cursor untouched, but serializes
delivery, lets a killed sender's stale lock block mail and work, and still
leaves readers parsing a file a crash can tear.

**Fixing mail only.** The queue reaches the same append through `task`-kind mail
and executes what it reads, so leaving it is strictly worse than leaving the
mailbox.

**Raising the cap first.** Widens the corruption window on the unfixed path.
