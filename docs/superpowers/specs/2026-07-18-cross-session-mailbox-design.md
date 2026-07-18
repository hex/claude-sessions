# Cross-Session Mailbox (`cs -msg`) — Design

Phase 2 of the cross-session comms roadmap (Phase 1 presence shipped 2026-07-10;
see `2026-07-10-cross-session-comms-phase1-presence-design.md`). One cs session
sends a typed message to another; the recipient sees it at its next hook
boundary. Machine-local, file-based, no daemon — the transport decisions were
locked in Phase 1 and are not revisited here.

Design adversarially reviewed by codex (gpt-5.6-sol), 12 findings; 8 adopted,
2 adjudicated down with recorded reasons, 2 folded into others. See "Review
record" at the end.

## Goal

`cs -msg other-session "heads up, touching lib/15-lock.sh"` from session A
lands as a one-line digest in session B's next turn; B reads the body with
`cs -msg`. A `task` message additionally lands in B's walk-away queue as real
work. Delivery works whether or not B is currently live.

## Message format

One message = one JSON line, appended to the recipient's inbox:

```json
{"id":"1752849000-4711-18342","ts":1752849000,"from":"claude-sessions","actor":"alex-geana-erepubliklabs-com","kind":"text","body":"...","ref":null}
```

- `id`: `<epoch>-<pid>-<RANDOM>` (bash 3.2 built-ins only).
- `ts`: send epoch seconds.
- `from`: sender session name (`CLAUDE_SESSION_NAME`); empty string when the
  sender is not inside a cs session.
- `actor`: `cs_actor_slug` of the sender (always present).
- `kind`: one of `notify|task|text|result`.
- `body`: the message text, max 4096 bytes (validated at send).
- `ref`: a message id, only valid with `kind=result` (stored for Phase 3
  correlation; nothing consumes it in Phase 2). `null` otherwise.

Attribution is unauthenticated by design: any same-user process can write any
`from`/`actor`. The trust boundary is the OS user account, same as every other
file under `~/.claude-sessions`.

## Storage

- Inbox: `<session>/.cs/local/mail/inbox.jsonl` — append-only, never rotated
  (same policy as `notifications.jsonl`).
- Digest cursor: `<session>/.cs/local/mail/notified` — line count already
  announced in a hook digest.
- Read cursor: `<session>/.cs/local/mail/seen` — line count already printed by
  `cs -msg`.

All three live under `.cs/local/` (machine-local, never synced) per the
multi-user safety classification. Cross-session writes touch only the inbox
file; both cursors are written exclusively by the owning session.

## CLI

Single verb `-msg`, wired at both dispatch sites in `lib/99-main.sh` (global
and session-scoped arms), implemented in a new `lib/53-mail.sh` fragment.

| Form | Meaning |
|---|---|
| `cs -msg <session> [--kind\|-k KIND] [--ref ID] "body"` | send |
| `cs <session> -msg [--kind\|-k KIND] [--ref ID] "body"` | send (session-scoped alias, same semantics) |
| `cs -msg` | print unread messages, advance the read cursor |
| `cs -msg log` | print the full inbox, cursors untouched |

Reading (`cs -msg`, `cs -msg log`) requires being inside a session
(`CLAUDE_SESSION_META_DIR` set), like `cs -queue`. Sending works from anywhere.
The session-scoped arm is send-only: `cs <session> -msg` without a body is an
error, never a read of the other session's inbox — a session's mail is read
only by that session.

## Sending semantics

Validation, in order, each failure a hard `error`:

1. Target must be a plain session name — no `/` — and
   `SESSIONS_ROOT/<name>` must pass `is_session_dir` (no path traversal, no
   writes outside the sessions root).
2. Target ≠ own session (`CLAUDE_SESSION_NAME`); self-send is an error.
3. `--kind` ∈ `notify|task|text|result` (default `text`).
4. `--ref` only allowed with `--kind result`.
5. Body non-empty after trim, ≤ 4096 bytes. A ≤4KB single `printf '%s\n'`
   append is one `write(2)` on APFS — concurrent senders do not tear lines.
6. `kind=task`: body must not contain newlines (the queue file is
   line-oriented; a multiline body would silently become several queue
   entries).

Write order for `kind=task`: queue first (`_queue_add` against the recipient's
`.cs/local`), inbox line second. If the queue write fails, nothing is sent; if
the inbox write fails after the queue write, the sender gets a warning that
the task was queued but attribution was lost. Work-without-attribution beats
attribution-without-work.

The JSON line is composed with `jq --arg` (bodies with quotes, backslashes,
unicode stay valid JSON). `mkdir -p` creates `mail/` on first send.

Send confirmation is unconditional: `sent to <name>; surfaces at their next
turn`. No liveness check — delivery does not depend on it, and the check would
only add a raced, cosmetic claim.

## Receiving

### Digest (hook side)

`hooks/scope-prompt.sh` and `hooks/session-start.sh` gain a `_build_mail_digest`
sibling to the existing `_build_digest`, same discipline: best-effort, never
breaks the hook, cursor write via tmp+mv.

Bounded-read protocol (fixes the announce/skip race and torn-line loss):

1. `total=$(wc -l < inbox.jsonl)` — `wc -l` counts newline bytes, so an
   in-flight unterminated final line is excluded and can never be skipped past.
2. Process exactly lines `notified+1 .. total` via
   `awk -v a="$((notified+1))" -v b="$total" 'NR>=a && NR<=b'` (no `head`; an
   early-exiting pipe consumer is the known SIGPIPE/pipefail failure class).
3. Advance the cursor to exactly `total`.

Lines are parsed tolerantly (`fromjson? // empty`); corrupt lines are skipped
but still counted (the cursor is a line count, not a message count).

Digest rendering from the unseen slice:

- Each `notify`: its own line, `mail from <from|actor>: <body>` — at most 3
  shown, then `… and N more notifies`. A notify is its own digest; that is the
  kind's purpose.
- Everything else: one summary line,
  `mail: N message(s) from <distinct senders> — run cs -msg to read`.
  Bodies of `text|task|result` never enter hook context.

Two conversations sharing one session directory (one opened outside cs) can
race the digest cursor; the bounded-read ordering makes the worst case a
duplicate announcement, never a loss. Accepted as benign, matching the shipped
queue digest.

### Reading (`cs -msg`)

Prints lines `seen+1 .. total` (same bounded-read protocol, `mail/seen`
cursor): one message per line, `HH:MM  <from|actor>  [kind]  body`, then
advances `seen` to `total`. `cs -msg log` prints all lines, advancing nothing.

All rendered bodies — digest and CLI — pass through control-character
stripping (`LC_ALL=C tr -d` of C0 controls except `\t`, plus DEL) so a body
cannot smuggle ANSI/OSC sequences into the terminal or a transcript.

### Task delivery

Already in the recipient's queue from send time (see write order above). The
existing queue arming/drain gates are untouched: a pushed task never runs
without the recipient's queue being started. The digest's summary line is the
attribution surface.

## Trust model

Same-OS-user, single machine. Anyone who can append to an inbox can already
edit any file in the session, so the mailbox adds no new capability to an
attacker — this is why inline notify bodies are acceptable and why attribution
is not authenticated. The mitigations that ARE in place (4KB cap,
control-character stripping, bodies-out-of-hook-context for text/task/result,
digest line caps) bound the blast radius of a *mistake*, not of a hostile
same-user process.

## Files touched

| File | Change |
|---|---|
| `lib/53-mail.sh` | new: send/read/log, validation, shared bounded-read helper |
| `lib/99-main.sh` | `-msg` in both dispatch arms |
| `lib/10-help.sh` | help lines |
| `hooks/scope-prompt.sh` | `_build_mail_digest` + emit alongside queue digest |
| `hooks/session-start.sh` | same |
| `bin/cs` | regenerated by `./build.sh` |
| `tests/test_msg.sh` | new suite |
| `README.md`, `docs/session-layout.md`, `docs/hooks.md` | docs |

Drive-by, same defect class, same files: the queue digest builders'
`total=$(grep -c '')` counts an unterminated final line and can advance past
it; align them to the `wc -l` newline count.

## Testing

TDD throughout; bash 3.2 + BSD userland; every assert `|| return 1`; suite
registered in `tests/run_all.sh`. Coverage:

- send: line lands in target inbox with all seven fields; `from` empty when
  `CLAUDE_SESSION_NAME` unset; id/ts present.
- validation: unknown target, name with `/`, self-send, bad kind, `--ref`
  without `result`, empty body, >4096-byte body, newline in task body — each
  errors, inbox untouched.
- task: queue gains the line, inbox gains the attribution, declined flag
  cleared (via `_queue_add`).
- digest: surface-once; notified cursor independent of seen cursor; 3-notify
  cap with overflow line; text bodies absent from digest output; torn final
  line (no trailing `\n`) neither announced nor skipped — announced after
  completion.
- read: `cs -msg` prints unread and advances seen; second call prints nothing;
  `log` reprints all without moving cursors.
- rendering: control characters stripped from printed bodies.
- scale: >64KB inbox processed without SIGPIPE/141 (the standing probe).

## Non-goals

- No TUI unread-mail indicator (follow-up candidate).
- No cross-machine transport (standing no-networked-presence law).
- No automatic consumption of `result`/`ref` (Phase 3).
- No deletion, expiry, or rotation.
- No delivery interruption — messages surface only at hook boundaries.

## Review record (codex gpt-5.6-sol, 2026-07-18)

Adopted: bounded-read cursor protocol (#2), torn-line exclusion via newline
count (#5), queue-first ordered dual write (#3), 4KB body cap + single-write
append (#4), newline ban in task bodies (#8), plain-name target resolution
(#7), control-character stripping (#10), liveness check dropped from send
(#12), unauthenticated-attribution documentation (#11), digest line caps (#9
partial; no rotation, matching house policy).

Adjudicated down: #1 (inline notify as Critical injection) — same-user trust
boundary means no new capability; notify without an inline body has no reason
to exist; mitigated by cap + stripping. #6 (concurrent cursor writers) —
worst case is a duplicate announcement, not loss, and only when a second
conversation shares the session dir; matches the shipped queue digest's
accepted behavior.
