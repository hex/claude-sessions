# Cross-Session Mailbox (`cs -msg`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One cs session sends a typed message (`notify|task|text|result`) to another; the recipient sees a digest at its next hook boundary and reads bodies with `cs -msg`.

**Architecture:** A new `lib/53-mail.sh` fragment implements send/read/log against an append-only `inbox.jsonl` in the recipient's `.cs/local/mail/`, with two line-count cursors (`notified` for hook digests, `seen` for CLI reads). The hook digest builders in `scope-prompt.sh` and `session-start.sh` gain a mail sibling using a bounded-read protocol (`wc -l` newline count, `awk` line slice). Spec: `docs/superpowers/specs/2026-07-18-cross-session-mailbox-design.md`.

**Tech Stack:** bash 3.2, BSD userland, jq, existing cs test harness (`tests/test_lib.sh`).

## Global Constraints

- bash 3.2 + BSD userland only: no `local -A`, no `mapfile`, no GNU-only flags (macos CI runs stock /bin/bash 3.2).
- `bin/cs` is generated: after ANY `lib/*.sh` edit, run `./build.sh` BEFORE running tests (tests execute `bin/cs`). Never edit `bin/cs` directly.
- Every test assertion ends with `|| return 1` (the harness disables errexit inside `run_test`).
- No early-exiting pipe consumers (`grep -q`, `head`, `sed q`) on files that can exceed 64KB — the SIGPIPE/pipefail class. Use `awk` NR guards.
- Test gate chains use `set -o pipefail` when piping test output.
- Body size cap: 4096 bytes. Kinds: `notify|task|text|result`, default `text`. Inbox: `.cs/local/mail/inbox.jsonl`. Cursors: `.cs/local/mail/notified`, `.cs/local/mail/seen`.
- Message JSON fields, exactly: `id, ts, from, actor, kind, body, ref`.
- `wc -l` (newline count) is the ONLY total-lines source for cursor math — never `grep -c ''`.
- Digest strings use no em-dashes ("... Run cs -msg to read.").
- Commit after each task; stage files explicitly, never `git add -A`.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/53-mail.sh` (create) | `run_mail` dispatcher, `_mail_send`, `_mail_read`, `_mail_log`, cursor/slice/scrub helpers |
| `lib/99-main.sh` (modify) | `-msg` arm in the global dispatcher and in the session-scoped subcommand loop |
| `lib/10-help.sh` (modify) | three `-msg` help lines after the `-queue` block |
| `hooks/scope-prompt.sh` (modify) | `_build_mail_digest` + emit alongside queue digest; queue digest total via `wc -l` |
| `hooks/session-start.sh` (modify) | same two changes |
| `tests/test_msg.sh` (create) | full suite (auto-discovered by `tests/run_all.sh` glob) |
| `README.md`, `docs/session-layout.md`, `docs/hooks.md` (modify) | docs |

---

### Task 1: Send path (`cs -msg <session> "body"`)

**Files:**
- Create: `lib/53-mail.sh`
- Modify: `lib/99-main.sh` (global arm after the `-queue` arm ~line 115; session-scoped arm after the session-scoped `-queue` arm ~line 205)
- Modify: `lib/10-help.sh` (after the `-queue log` line ~line 26)
- Test: `tests/test_msg.sh`

**Interfaces:**
- Consumes: `error`/`info`/`warn` (lib/05-term.sh, lib/10-help.sh), `is_session_dir` (lib/65-sessions.sh), `cs_actor_slug` (lib/40-state.sh), `SESSIONS_ROOT`, `CLAUDE_SESSION_NAME`, `CLAUDE_SESSION_META_DIR`.
- Produces: `run_mail "$@"` (dispatcher: no args = read, `log` = log, anything else = send target), `_mail_send target [args...]`, `MAIL_BODY_MAX=4096`, `_mail_total file`, `_mail_cursor file`, `_mail_set_cursor file value`, `_mail_slice file from to`, `_mail_scrub` (stdin filter). Tasks 2-4 rely on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_msg.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the cs -msg cross-session mailbox: send validation,
# ABOUTME: task-to-queue delivery, read/log cursors, and the hook mail digest.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_SESSION_NAME="sender"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/sender"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    mkdir -p "$CS_SESSIONS_ROOT/receiver/.cs/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

INBOX() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"; }

test_send_writes_full_record() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    assert_file_exists "$(INBOX)" "inbox created" || return 1
    local line; line=$(head -1 "$(INBOX)")
    assert_eq "sender" "$(printf '%s' "$line" | jq -r .from)" "from is sender session" || return 1
    assert_eq "text" "$(printf '%s' "$line" | jq -r .kind)" "kind defaults to text" || return 1
    assert_eq "hello there" "$(printf '%s' "$line" | jq -r .body)" "body preserved" || return 1
    assert_eq "null" "$(printf '%s' "$line" | jq -r .ref)" "ref null" || return 1
    local id ts actor
    id=$(printf '%s' "$line" | jq -r .id); ts=$(printf '%s' "$line" | jq -r .ts); actor=$(printf '%s' "$line" | jq -r .actor)
    assert_output_contains "$id" "-" "id has epoch-pid-random shape" || return 1
    case "$ts" in ''|*[!0-9]*) echo "  ts not numeric: $ts"; return 1;; esac
    [ -n "$actor" ] || { echo "  actor empty"; return 1; }
}

test_send_from_outside_session_has_empty_from() {
    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR "$CS_BIN" -msg receiver "note" >/dev/null 2>&1 || return 1
    assert_eq "" "$(head -1 "$(INBOX)" | jq -r .from)" "from empty outside a session" || return 1
}

test_send_session_scoped_alias() {
    "$CS_BIN" receiver -msg "via alias" >/dev/null 2>&1 || return 1
    assert_file_contains "$(INBOX)" "via alias" "session-scoped arm sends" || return 1
}

test_send_rejects_unknown_target() {
    ! "$CS_BIN" -msg nosuch "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_slash_in_target() {
    ! "$CS_BIN" -msg "../receiver" "x" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -msg "a/b" "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_self() {
    mkdir -p "$CS_SESSIONS_ROOT/sender/.cs/local"
    ! "$CS_BIN" -msg sender "me to me" >/dev/null 2>&1 || return 1
}

test_send_rejects_bad_kind() {
    ! "$CS_BIN" -msg receiver -k bogus "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_ref_without_result() {
    ! "$CS_BIN" -msg receiver --ref some-id "x" >/dev/null 2>&1 || return 1
    "$CS_BIN" -msg receiver -k result --ref some-id "ok" >/dev/null 2>&1 || return 1
    assert_eq "some-id" "$(head -1 "$(INBOX)" | jq -r .ref)" "ref stored on result" || return 1
}

test_send_rejects_empty_and_oversize_body() {
    ! "$CS_BIN" -msg receiver "   " >/dev/null 2>&1 || return 1
    local big; big=$(printf 'a%.0s' $(seq 1 4097))
    ! "$CS_BIN" -msg receiver "$big" >/dev/null 2>&1 || return 1
    [ ! -f "$(INBOX)" ] || { echo "  inbox written on failed send"; return 1; }
}

run_test test_send_writes_full_record
run_test test_send_from_outside_session_has_empty_from
run_test test_send_session_scoped_alias
run_test test_send_rejects_unknown_target
run_test test_send_rejects_slash_in_target
run_test test_send_rejects_self
run_test test_send_rejects_bad_kind
run_test test_send_rejects_ref_without_result
run_test test_send_rejects_empty_and_oversize_body

report_results
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_msg.sh`
Expected: every test FAILS (`-msg` is an unknown command).

- [ ] **Step 3: Implement `lib/53-mail.sh`**

```bash
# ABOUTME: Backs 'cs -msg', the cross-session mailbox: send a typed message to
# ABOUTME: another session's inbox; read/log the current session's own inbox.

MAIL_BODY_MAX=4096

# Strip C0 control characters (keeping tab and newline) and DEL from stdin,
# so a message body cannot smuggle ANSI/OSC sequences into a terminal.
_mail_scrub() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# Count complete (newline-terminated) lines. wc -l counts newline bytes, so a
# torn final line still being written is excluded from cursor math.
_mail_total() {  # file
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d '[:space:]'
    else
        echo 0
    fi
}

_mail_cursor() {  # cursor_file
    local v=""
    if [ -f "$1" ]; then IFS= read -r v < "$1" || true; fi
    case "$v" in ''|*[!0-9]*) v=0;; esac
    echo "$v"
}

_mail_set_cursor() {  # cursor_file, value
    printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Print inbox lines from..to inclusive. awk bounds both ends without the
# early-exit SIGPIPE risk of head/sed on large files.
_mail_slice() {  # file, from_line, to_line
    awk -v a="$2" -v b="$3" 'NR>=a && NR<=b' "$1"
}

_mail_send() {  # target, [--kind|-k KIND] [--ref ID] body
    local target="$1"; shift
    local kind="text" ref="" body=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kind|-k) shift; kind="${1:-}";;
            --ref)     shift; ref="${1:-}";;
            *)         body="$1";;
        esac
        shift
    done
    case "$target" in ''|*/*) error "cs -msg needs a plain session name as target";; esac
    local target_dir="$SESSIONS_ROOT/$target"
    is_session_dir "$target_dir" || error "No such session: $target"
    if [ "$target" = "${CLAUDE_SESSION_NAME:-}" ]; then
        error "Refusing to send mail to the current session"
    fi
    case "$kind" in notify|task|text|result) : ;; *) error "Unknown kind: $kind (notify|task|text|result)";; esac
    if [ -n "$ref" ] && [ "$kind" != "result" ]; then
        error "--ref is only valid with --kind result"
    fi
    body="${body#"${body%%[![:space:]]*}"}"  # ltrim
    body="${body%"${body##*[![:space:]]}"}"  # rtrim
    [ -n "$body" ] || error "cs -msg needs a non-empty body"
    local bytes
    bytes=$(LC_ALL=C printf '%s' "$body" | wc -c | tr -d '[:space:]')
    if [ "$bytes" -gt "$MAIL_BODY_MAX" ]; then
        error "Message body exceeds ${MAIL_BODY_MAX} bytes"
    fi
    local maildir="$target_dir/.cs/local/mail"
    mkdir -p "$maildir"
    local now line
    now="$(date +%s)"
    line=$(jq -cn --arg id "${now}-$$-${RANDOM}" --argjson ts "$now" \
        --arg from "${CLAUDE_SESSION_NAME:-}" --arg actor "$(cs_actor_slug)" \
        --arg kind "$kind" --arg body "$body" --arg ref "$ref" \
        '{id:$id, ts:$ts, from:$from, actor:$actor, kind:$kind, body:$body,
          ref:(if $ref == "" then null else $ref end)}')
    printf '%s\n' "$line" >> "$maildir/inbox.jsonl" \
        || error "Failed to write to ${target}'s mailbox"
    info "sent to $target; surfaces at their next turn"
}

# Dispatcher. Bare = read own inbox; 'log' = full history; else = send.
run_mail() {
    local first="${1:-}"
    case "$first" in
        "")  error "cs -msg: reading arrives in a later task";;
        log) error "cs -msg log: reading arrives in a later task";;
        *)   shift; _mail_send "$first" "$@";;
    esac
}
```

(The two `error` stubs for read/log are replaced in Task 3; they keep this task's surface honest.)

- [ ] **Step 4: Wire the global dispatch arm**

In `lib/99-main.sh`, directly after the global `-queue` arm (the four lines ending `return 0 ;;` around line 115-119), insert:

```bash
        -msg)
            shift
            run_mail "$@"
            return 0
            ;;
```

- [ ] **Step 5: Wire the session-scoped arm**

In `lib/99-main.sh`, in the session-subcommand `while` loop, directly after the session-scoped `-queue` arm (around line 205-212), insert:

```bash
            -msg)
                shift
                # Send-only: the positional session is the TARGET. The sender's
                # own identity comes from the caller's environment (or none).
                run_mail "$session_name" "$@"
                return 0
                ;;
```

Note this arm deliberately does NOT export `CLAUDE_SESSION_NAME` (unlike its `-queue` neighbor): exporting the target's name would make every alias send look like a self-send.

- [ ] **Step 6: Add help lines**

In `lib/10-help.sh`, after the `-queue log` line, insert:

```
  -msg <session> "<body>"  Send a message to another session (--kind notify|task|text|result)
  -msg                Read this session's unread mail
  -msg log            Show this session's full mail history
```

- [ ] **Step 7: Build and run**

Run: `./build.sh && bash tests/test_msg.sh`
Expected: all 9 tests PASS.

- [ ] **Step 8: Full suites**

Run: `set -o pipefail; bash tests/run_all.sh 2>&1 | tail -15`
Expected: all suites pass (no regression from the dispatch edits).

- [ ] **Step 9: Commit**

```bash
git add lib/53-mail.sh lib/99-main.sh lib/10-help.sh bin/cs tests/test_msg.sh
git commit -m "feat: cs -msg send path for the cross-session mailbox"
```

---

### Task 2: `task` kind delivers into the recipient's queue

**Files:**
- Modify: `lib/53-mail.sh` (`_mail_send`)
- Test: `tests/test_msg.sh`

**Interfaces:**
- Consumes: `_queue_add qdir text` (lib/55-queue.sh — trims, appends to `$qdir/queue`, clears `$qdir/queue.declined`).
- Produces: no new names; `kind=task` behavior only.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_msg.sh` (before the `run_test` block; add the two `run_test` lines in order):

```bash
RQUEUE() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/queue"; }

test_task_kind_lands_in_recipient_queue() {
    "$CS_BIN" -msg receiver -k task "review the tui diff" >/dev/null 2>&1 || return 1
    assert_file_exists "$(RQUEUE)" "queue file created" || return 1
    assert_file_contains "$(RQUEUE)" "review the tui diff" "task queued" || return 1
    assert_file_contains "$(INBOX)" "review the tui diff" "attribution recorded" || return 1
    assert_eq "task" "$(head -1 "$(INBOX)" | jq -r .kind)" "kind is task" || return 1
}

test_task_kind_clears_declined_flag() {
    touch "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined"
    "$CS_BIN" -msg receiver -k task "another" >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined" ] || { echo "  declined flag survived"; return 1; }
}

test_task_kind_rejects_multiline_body() {
    ! "$CS_BIN" -msg receiver -k task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    [ ! -f "$(RQUEUE)" ] || { echo "  queue written despite rejection"; return 1; }
    [ ! -f "$(INBOX)" ] || { echo "  inbox written despite rejection"; return 1; }
}

run_test test_task_kind_lands_in_recipient_queue
run_test test_task_kind_clears_declined_flag
run_test test_task_kind_rejects_multiline_body
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_msg.sh`
Expected: the three new tests FAIL (no queue file; multiline accepted).

- [ ] **Step 3: Implement**

In `lib/53-mail.sh` `_mail_send`, after the byte-size check and before `local maildir=...`, insert:

```bash
    if [ "$kind" = "task" ]; then
        # $(printf '\n') would collapse to "" (command substitution strips
        # trailing newlines); the literal embedded newline below does not.
        local nl='
'
        case "$body" in
            *"$nl"*) error "task bodies must be a single line (the queue file is line-oriented)";;
        esac
        # Queue first, attribution second: if the queue write fails nothing is
        # sent; if the inbox write fails the work is still delivered.
        _queue_add "$target_dir/.cs/local" "$body"
    fi
```

And change the inbox-append failure branch to warn instead of error when the task is already queued:

```bash
    if ! printf '%s\n' "$line" >> "$maildir/inbox.jsonl"; then
        if [ "$kind" = "task" ]; then
            warn "task queued in $target, but recording the mail attribution failed"
            return 0
        fi
        error "Failed to write to ${target}'s mailbox"
    fi
    info "sent to $target; surfaces at their next turn"
```

(Replace the earlier `printf ... || error ...` line with this block.)

- [ ] **Step 4: Build, run, full suites**

Run: `./build.sh && bash tests/test_msg.sh && set -o pipefail && bash tests/run_all.sh 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/53-mail.sh bin/cs tests/test_msg.sh
git commit -m "feat: cs -msg task kind queues work in the recipient session"
```

---

### Task 3: Reading (`cs -msg`, `cs -msg log`)

**Files:**
- Modify: `lib/53-mail.sh` (replace the two `run_mail` stubs; add `_mail_read`, `_mail_log`, `_mail_print`)
- Test: `tests/test_msg.sh`

**Interfaces:**
- Consumes: Task 1 helpers (`_mail_total`, `_mail_cursor`, `_mail_set_cursor`, `_mail_slice`, `_mail_scrub`).
- Produces: `_mail_read` (prints unread, advances `mail/seen`), `_mail_log` (prints all, moves nothing), `_mail_print from to inbox` (shared formatter).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_msg.sh` (again before the `run_test` block, adding the `run_test` lines):

```bash
# Read receiver's mail: point the ambient session env at receiver.
_as_receiver() {
    CLAUDE_SESSION_NAME="receiver" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/receiver/.cs" \
    "$CS_BIN" "$@"
}

test_read_prints_unread_then_advances() {
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1
    "$CS_BIN" -msg receiver "second" >/dev/null 2>&1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "first" "first body shown" || return 1
    assert_output_contains "$out" "second" "second body shown" || return 1
    assert_output_contains "$out" "sender" "sender attributed" || return 1
    assert_output_contains "$out" "[text]" "kind tagged" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "No unread mail" "second read is empty" || return 1
}

test_log_reprints_everything_without_moving_cursors() {
    "$CS_BIN" -msg receiver "logged" >/dev/null 2>&1
    _as_receiver -msg >/dev/null 2>&1 || return 1
    local out; out=$(_as_receiver -msg log 2>&1) || return 1
    assert_output_contains "$out" "logged" "log shows read mail" || return 1
    assert_eq "1" "$(cat "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/seen")" "seen cursor unmoved by log" || return 1
}

test_read_outside_session_errors() {
    ! env -u CLAUDE_SESSION_META_DIR "$CS_BIN" -msg >/dev/null 2>&1 || return 1
}

test_read_strips_control_characters() {
    "$CS_BIN" -msg receiver "$(printf 'evil \033[2J clear')" >/dev/null 2>&1 || return 1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    case "$out" in *"$(printf '\033')"*) echo "  ESC survived rendering"; return 1;; esac
    assert_output_contains "$out" "evil" "body otherwise shown" || return 1
}

test_read_ignores_torn_final_line_until_completed() {
    "$CS_BIN" -msg receiver "whole" >/dev/null 2>&1
    printf '{"id":"x","ts":1,"from":"sender","actor":"a","kind":"text","body":"torn' \
        >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "whole" "complete line shown" || return 1
    assert_output_not_contains "$out" "torn" "torn line hidden" || return 1
    assert_eq "1" "$(cat "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/seen")" "cursor stops before torn line" || return 1
    printf '","ref":null}\n' >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "torn" "completed line delivered" || return 1
}

test_read_survives_corrupt_line_and_big_inbox() {
    printf 'not json at all\n' >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl" 2>/dev/null || {
        mkdir -p "$CS_SESSIONS_ROOT/receiver/.cs/local/mail"
        printf 'not json at all\n' >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    }
    local i=0
    while [ "$i" -lt 400 ]; do
        printf '{"id":"b%s","ts":1,"from":"s","actor":"a","kind":"text","body":"filler message %s padding padding padding padding padding padding padding padding padding padding padding padding padding padding","ref":null}\n' "$i" "$i"
        i=$((i + 1))
    done >> "$CS_SESSIONS_ROOT/receiver/.cs/local/mail/inbox.jsonl"
    local out rc=0
    out=$(_as_receiver -msg 2>&1) || rc=$?
    assert_eq "0" "$rc" "big inbox read exits 0 (no SIGPIPE 141)" || return 1
    assert_output_contains "$out" "filler message 399" "last message present" || return 1
}

run_test test_read_prints_unread_then_advances
run_test test_log_reprints_everything_without_moving_cursors
run_test test_read_outside_session_errors
run_test test_read_strips_control_characters
run_test test_read_ignores_torn_final_line_until_completed
run_test test_read_survives_corrupt_line_and_big_inbox
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_msg.sh`
Expected: the six new tests FAIL (read/log are stubs that error).

- [ ] **Step 3: Implement**

In `lib/53-mail.sh`, add above `run_mail`:

```bash
# Shared formatter: print inbox lines from..to as 'HH:MM  sender  [kind]  body'.
_mail_print() {  # from_line, to_line, inbox
    _mail_slice "$3" "$1" "$2" | jq -rR '
        fromjson? // empty |
        (.ts | strflocaltime("%H:%M")) + "  " +
        (if .from == "" then .actor else .from end) + "  [" + .kind + "]  " + .body
    ' | _mail_scrub
}

_mail_read() {
    local maildir="$CLAUDE_SESSION_META_DIR/local/mail"
    local inbox="$maildir/inbox.jsonl"
    local total seen
    total=$(_mail_total "$inbox")
    seen=$(_mail_cursor "$maildir/seen")
    if [ "$total" -le "$seen" ]; then
        echo "No unread mail."
        return 0
    fi
    _mail_print $((seen + 1)) "$total" "$inbox"
    _mail_set_cursor "$maildir/seen" "$total"
}

_mail_log() {
    local inbox="$CLAUDE_SESSION_META_DIR/local/mail/inbox.jsonl"
    local total
    total=$(_mail_total "$inbox")
    if [ "$total" -eq 0 ]; then
        echo "No mail."
        return 0
    fi
    _mail_print 1 "$total" "$inbox"
}
```

Replace `run_mail`'s two stub arms:

```bash
run_mail() {
    local first="${1:-}"
    case "$first" in
        "")
            [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || error "cs -msg reads the current session's mail; run it inside a session"
            _mail_read;;
        log)
            [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || error "cs -msg reads the current session's mail; run it inside a session"
            _mail_log;;
        *)
            shift; _mail_send "$first" "$@";;
    esac
}
```

- [ ] **Step 4: Build, run, full suites**

Run: `./build.sh && bash tests/test_msg.sh && set -o pipefail && bash tests/run_all.sh 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/53-mail.sh bin/cs tests/test_msg.sh
git commit -m "feat: cs -msg read and log with torn-line-safe cursors"
```

---

### Task 4: Hook mail digest (+ queue-digest total drive-by)

**Files:**
- Modify: `hooks/scope-prompt.sh` (insert `_build_mail_digest` after `_build_digest` ends ~line 57; extend the builder call site ~line 60-61; queue total swap inside `_build_digest` ~line 41)
- Modify: `hooks/session-start.sh` (same function insert after its `_build_digest`; emit block after the queue digest block ~line 373-380; queue total swap ~line 39)
- Test: `tests/test_msg.sh`

**Interfaces:**
- Consumes: hook-local `_build_digest` pattern; `CLAUDE_SESSION_META_DIR` / `META_DIR`; `CONTEXT` accumulation (session-start); `DIGEST` + `_digest_exit` (scope-prompt).
- Produces: `_build_mail_digest meta_local_dir` setting `MAIL_DIGEST` (duplicated in both hooks, matching how `_build_digest` is duplicated — hooks are standalone scripts).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_msg.sh`:

```bash
_prompt_as_receiver() {  # prompt-text
    printf '{"prompt": "%s"}' "$1" | \
    CLAUDE_SESSION_NAME="receiver" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/receiver/.cs" \
    bash "$HOOKS_DIR/scope-prompt.sh"
}

test_digest_notify_inline_and_text_counted() {
    "$CS_BIN" -msg receiver -k notify "build is green" >/dev/null 2>&1
    "$CS_BIN" -msg receiver "long body that must stay out of hook context" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "mail from sender: build is green" "notify body inline" || return 1
    assert_output_contains "$out" "1 message(s) from sender" "text counted" || return 1
    assert_output_contains "$out" "Run cs -msg to read" "read pointer present" || return 1
    assert_output_not_contains "$out" "stay out of hook context" "text body absent" || return 1
}

test_digest_surfaces_once_and_read_cursor_independent() {
    "$CS_BIN" -msg receiver -k notify "ping" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "ping" "first prompt announces" || return 1
    out=$(_prompt_as_receiver "again") || return 1
    assert_output_not_contains "$out" "ping" "second prompt silent" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "ping" "digest did not consume the read cursor" || return 1
}

test_digest_caps_notifies_at_three() {
    local i=1
    while [ "$i" -le 5 ]; do
        "$CS_BIN" -msg receiver -k notify "note $i" >/dev/null 2>&1
        i=$((i + 1))
    done
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "note 3" "third notify shown" || return 1
    assert_output_not_contains "$out" "note 4" "fourth notify capped" || return 1
    assert_output_contains "$out" "2 more" "overflow counted" || return 1
}

test_session_start_hook_also_delivers() {
    "$CS_BIN" -msg receiver -k notify "seen at start" >/dev/null 2>&1
    local out
    out=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | \
        CLAUDE_SESSION_NAME="receiver" \
        CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver" \
        CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/receiver/.cs" \
        CS_SESSIONS_ROOT="$CS_SESSIONS_ROOT" \
        bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_contains "$out" "seen at start" "session-start delivers mail digest" || return 1
}

run_test test_digest_notify_inline_and_text_counted
run_test test_digest_surfaces_once_and_read_cursor_independent
run_test test_digest_caps_notifies_at_three
run_test test_session_start_hook_also_delivers
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_msg.sh`
Expected: the four new tests FAIL (no mail digest emitted).

- [ ] **Step 3: Implement — the digest builder (identical function in BOTH hooks)**

Insert after each hook's `_build_digest` function (scope-prompt.sh ~line 57, session-start.sh ~line 56):

```bash
# Build the surface-once mail digest from unseen inbox lines. Sets MAIL_DIGEST
# (may be empty) and advances the notified cursor to the pre-counted total, so
# a line appended mid-build is never skipped (wc -l also excludes a torn,
# still-unterminated final line). Best-effort throughout: never breaks the hook.
_build_mail_digest() {  # meta_local_dir
    local mdir="$1/mail" inbox total seen
    MAIL_DIGEST=""
    inbox="$mdir/inbox.jsonl"
    [ -s "$inbox" ] || return 0
    total=$(wc -l < "$inbox" 2>/dev/null | tr -d '[:space:]') || return 0
    case "$total" in ''|*[!0-9]*) return 0;; esac
    seen=$(cat "$mdir/notified" 2>/dev/null | tr -d '[:space:]') || true
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    [ "$total" -gt "$seen" ] || return 0
    MAIL_DIGEST=$(awk -v a=$((seen + 1)) -v b="$total" 'NR>=a && NR<=b' "$inbox" 2>/dev/null | jq -rRs '
        [split("\n")[] | select(length > 0) | (fromjson? // empty)] as $m |
        [$m[] | select(.kind == "notify")] as $n |
        [$m[] | select(.kind != "notify")] as $r |
        (( [ ($n[0:3])[] | "mail from " + (if .from == "" then .actor else .from end) + ": "
              + (.body | gsub("[\n\r]"; " ")) ] )
         + (if ($n | length) > 3 then ["... and \(($n | length) - 3) more notifies"] else [] end)
         + (if ($r | length) > 0 then
              ["mail: \($r | length) message(s) from "
               + ([ $r[] | if .from == "" then .actor else .from end ] | unique | join(", "))
               + ". Run cs -msg to read."]
            else [] end)) | join("\n")
    ' 2>/dev/null) || MAIL_DIGEST=""
    MAIL_DIGEST=$(printf '%s' "$MAIL_DIGEST" | LC_ALL=C tr -d '\000-\010\013-\037\177')
    printf '%s\n' "$total" > "$mdir/notified.tmp" 2>/dev/null \
        && mv "$mdir/notified.tmp" "$mdir/notified" 2>/dev/null || true
}
```

- [ ] **Step 4: Implement — scope-prompt.sh call site**

Replace:

```bash
DIGEST=""
[ -n "${CLAUDE_SESSION_META_DIR:-}" ] && _build_digest "$CLAUDE_SESSION_META_DIR/local"
```

with:

```bash
DIGEST=""
MAIL_DIGEST=""
if [ -n "${CLAUDE_SESSION_META_DIR:-}" ]; then
    _build_digest "$CLAUDE_SESSION_META_DIR/local"
    _build_mail_digest "$CLAUDE_SESSION_META_DIR/local"
fi
if [ -n "$MAIL_DIGEST" ]; then
    DIGEST="${DIGEST:+$DIGEST
}$MAIL_DIGEST"
fi
```

(`_digest_exit` and the later splice paths already deliver whatever is in `DIGEST`.)

- [ ] **Step 5: Implement — session-start.sh call site**

After the existing queue digest block (`_build_digest "$META_DIR/local"` ... `fi`), insert:

```bash
# Mail digest (surface-once; same recipe).
MAIL_DIGEST=""
_build_mail_digest "$META_DIR/local"
if [ -n "$MAIL_DIGEST" ]; then
    CONTEXT="${CONTEXT}

--- $MAIL_DIGEST"
fi
```

- [ ] **Step 6: Drive-by — queue digest totals**

In BOTH hooks' `_build_digest`, replace:

```bash
    total=$(grep -c '' "$inbox" 2>/dev/null) || return 0
```

with:

```bash
    total=$(wc -l < "$inbox" 2>/dev/null | tr -d '[:space:]') || return 0
    case "$total" in ''|*[!0-9]*) return 0;; esac
```

(Same defect class the mail digest avoids: `grep -c ''` counts a torn final line and the cursor could advance past it.)

- [ ] **Step 7: Run, full suites**

Run: `bash tests/test_msg.sh && set -o pipefail && bash tests/run_all.sh 2>&1 | tail -5`
Expected: all PASS, including the existing queue-supervision digest tests (the drive-by must not change their behavior on complete files). No `./build.sh` needed — hooks are standalone.

- [ ] **Step 8: Commit**

```bash
git add hooks/scope-prompt.sh hooks/session-start.sh tests/test_msg.sh
git commit -m "feat: hook mail digest with torn-line-safe bounded reads"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` (feature bullet near the queue/presence bullets)
- Modify: `docs/session-layout.md` (three rows in the `.cs/local/` table)
- Modify: `docs/hooks.md` (digest mention where the queue digest is described)

**Interfaces:** none (docs only).

- [ ] **Step 1: README bullet**

Next to the existing `cs -live` / queue bullets, add:

```markdown
- **Cross-session mail** — `cs -msg <session> "note"` drops a message in another
  session's machine-local mailbox (`--kind notify|task|text|result`; `task` also
  lands in its walk-away queue). The recipient sees a one-line digest at its next
  turn and reads bodies with `cs -msg`. Same-machine only; attribution is
  unauthenticated by design.
```

- [ ] **Step 2: docs/session-layout.md rows**

In the `.cs/local/` section, add:

```markdown
| `local/mail/inbox.jsonl` | Cross-session mailbox: one JSON message per line, appended by senders (`cs -msg`) |
| `local/mail/notified` | Digest cursor: inbox line count already announced by a hook digest |
| `local/mail/seen` | Read cursor: inbox line count already printed by `cs -msg` |
```

- [ ] **Step 3: docs/hooks.md note**

Where the queue notification digest is described (scope-prompt / session-start), extend:

```markdown
Both hooks also surface the cross-session mail digest: unseen `mail/inbox.jsonl`
lines become one context line (notify bodies inline, capped at three; other kinds
as per-sender counts pointing at `cs -msg`). Cursors advance to a pre-counted
line total, so torn or mid-write lines are never skipped.
```

- [ ] **Step 4: Verify docs against code**

Run: `rg -n -- '-msg' README.md docs/session-layout.md docs/hooks.md bin/cs | head -20`
Expected: every documented flag/path exists in `bin/cs` output above.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/session-layout.md docs/hooks.md
git commit -m "docs: cross-session mailbox (cs -msg)"
```
