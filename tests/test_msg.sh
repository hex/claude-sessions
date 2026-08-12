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
    create_test_session sender >/dev/null
    create_test_session receiver >/dev/null
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

MAILDIR() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/mail"; }
RCV_META() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs"; }

# Run cs as the receiver (to read its own mail, or reply from its side).
# Defined here rather than beside the wake tests because run_test calls are
# interleaved through this file: a helper must exist before the first one runs.
rcv() {
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        "$CS_BIN" "$@"
    )
}

# Count of unread (new/*.json) messages in receiver's maildir.
NEW_COUNT() {
    local f n=0
    for f in "$(MAILDIR)"/new/*.json; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# First delivered message, as a file path (lexical order = delivery order here).
FIRST_MSG() {
    local f
    for f in "$(MAILDIR)"/new/*.json; do
        [ -e "$f" ] || return 1
        printf '%s' "$f"
        return 0
    done
}

# Delivery is atomic by MECHANISM (spec test 1): each send lands as its own
# complete document in the recipient's new/, staged nowhere visible, with no
# append to any shared file. A timing race is deliberately NOT tested here —
# measured, it passes against the broken implementation and flakes on CI.
test_send_delivers_one_whole_document_per_message() {
    "$CS_BIN" -msg receiver "first message" >/dev/null 2>&1 || return 1
    "$CS_BIN" -msg receiver "second message" >/dev/null 2>&1 || return 1
    [ ! -f "$(MAILDIR)/inbox.jsonl" ] || { echo "  send appended to a shared inbox.jsonl"; return 1; }
    local f n=0
    for f in "$(MAILDIR)"/new/*.json; do
        [ -e "$f" ] || { echo "  no documents in new/"; return 1; }
        n=$((n + 1))
        jq -e . "$f" >/dev/null 2>&1 || { echo "  document does not parse whole: $f"; return 1; }
        case "${f##*/}" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.json) : ;;
            *) echo "  filename not <ts10>-<id>.json: ${f##*/}"; return 1 ;;
        esac
    done
    assert_eq "2" "$n" "one document per send" || return 1
    for f in "$(MAILDIR)"/tmp/*; do
        [ -e "$f" ] && { echo "  staging leftover in tmp/: $f"; return 1; }
    done
    return 0
}

test_send_writes_full_record() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || { echo "  no message delivered"; return 1; }
    local line; line=$(cat "$msg")
    assert_eq "sender" "$(printf '%s' "$line" | jq -r .from)" "from is sender session" || return 1
    assert_eq "text" "$(printf '%s' "$line" | jq -r .kind)" "kind defaults to text" || return 1
    assert_eq "hello there" "$(printf '%s' "$line" | jq -r .body)" "body preserved" || return 1
    local id ts actor
    id=$(printf '%s' "$line" | jq -r .id); ts=$(printf '%s' "$line" | jq -r .ts); actor=$(printf '%s' "$line" | jq -r .actor)
    assert_output_contains "$id" "-" "id has epoch-pid-random shape" || return 1
    case "$ts" in ''|*[!0-9]*) echo "  ts not numeric: $ts"; return 1;; esac
    [ -n "$actor" ] || { echo "  actor empty"; return 1; }
}

OUTDIR() { printf '%s' "$CS_SESSIONS_ROOT/sender/.cs/local/mail/out"; }

# Sole sent copy, as a path; rc 1 when none.
FIRST_SENT() {
    local f
    for f in "$(OUTDIR)"/*.json; do
        [ -e "$f" ] || return 1
        printf '%s' "$f"
        return 0
    done
    return 1
}

test_send_stamps_a_thread_and_keeps_a_sent_copy() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || { echo "  nothing delivered"; return 1; }
    local thread; thread=$(jq -r '.thread // ""' "$msg")
    case "$thread" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
        *) echo "  thread is not 6 hex digits: '$thread'"; return 1 ;;
    esac
    assert_eq "receiver" "$(jq -r '.to // ""' "$msg")" \
        "the record names where it went, so an out/ copy can route a reply" || return 1
    assert_eq "null" "$(jq -r '.in_reply_to' "$msg")" "a thread root has no parent" || return 1

    local sent; sent=$(FIRST_SENT) || { echo "  sender kept no out/ copy"; return 1; }
    assert_eq "$thread" "$(jq -r '.thread // ""' "$sent")" \
        "the sent copy shares the thread id" || return 1
    assert_eq "hello there" "$(jq -r '.body // ""' "$sent")" "the sent copy carries the body" || return 1

    local f n=0
    for f in "$CS_SESSIONS_ROOT/sender/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] || continue; n=$((n + 1))
    done
    assert_eq "0" "$n" "a sent copy is not unread mail to its own sender" || return 1
}

SENDER_NEW() {
    local f n=0
    for f in "$CS_SESSIONS_ROOT/sender/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] || continue; n=$((n + 1)); printf '%s' "$f"
    done
    [ "$n" -gt 0 ] || return 1
}

test_reply_derives_its_target_from_the_thread() {
    "$CS_BIN" -msg receiver "question?" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || return 1
    local thread parent
    thread=$(jq -r .thread "$msg"); parent=$(jq -r .id "$msg")

    # The receiver answers naming only the thread — never the peer.
    rcv -msg --reply "$thread" "answer!" >/dev/null 2>&1 || { echo "  reply failed"; return 1; }

    local back; back=$(SENDER_NEW) || { echo "  the reply did not route back to the sender"; return 1; }
    assert_eq "$thread" "$(jq -r .thread "$back")" "the reply reuses the thread id" || return 1
    assert_eq "sender" "$(jq -r .to "$back")" "the target was derived, not stated" || return 1
    assert_eq "$parent" "$(jq -r .in_reply_to "$back")" \
        "in_reply_to points at the message answered, which is what orders the transcript" || return 1
}

test_reply_refuses_an_unknown_thread() {
    local out rc=0
    out=$(rcv -msg --reply ffffff "into the void" 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  an unknown thread should error, never start a new one"; return 1; }
    assert_output_contains "$out" "thread" "the error names the problem" || return 1
}

test_reply_refuses_a_target_that_contradicts_the_thread() {
    "$CS_BIN" -msg receiver "question?" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    create_test_session third >/dev/null 2>&1 || true
    local out rc=0
    out=$(rcv -msg third --reply "$thread" "misrouted" 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  a contradicting target should error"; return 1; }
    local f n=0
    for f in "$CS_SESSIONS_ROOT/third/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] || continue; n=$((n + 1))
    done
    assert_eq "0" "$n" "a typo must not misroute the reply and poison later derivations" || return 1
}

test_thread_survives_an_unparseable_document() {
    # jq treats a JSON parse error as fatal to the whole invocation and never
    # opens the files after it, so a single torn document must not be able to
    # hide every later one. This suite already blesses a corrupt document in
    # new/ as an input reading must survive.
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    printf '%s' '{"id":"x","thread":' > "$(MAILDIR)/new/0000000000-torn.json"
    "$CS_BIN" -msg receiver "second" >/dev/null 2>&1 || return 1
    local out; out=$(rcv -msg thread "$thread" 2>&1) \
        || { echo "  a torn document made the whole thread unreadable"; return 1; }
    assert_output_contains "$out" "first" "the readable messages still render" || return 1
}

test_log_shows_what_this_session_sent() {
    "$CS_BIN" -msg receiver "a question I asked" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    local out; out=$("$CS_BIN" -msg log 2>&1)
    assert_output_contains "$out" "a question I asked" \
        "history without sent mail cannot show what this session said" || return 1
    assert_output_contains "$out" "$thread" \
        "and cannot surface the thread id of a conversation it started" || return 1
}

test_reply_refuses_an_ambiguous_thread() {
    # Six hex digits is short enough to retype and short enough to repeat: a
    # mailbox accumulates roots without bound. If a collision ever lands,
    # guessing a peer would misroute into a stranger's conversation.
    local mine="$CLAUDE_SESSION_META_DIR/local/mail"
    mkdir -p "$mine/cur" "$mine/out"
    printf '%s\n' '{"id":"1","ts":1700000000,"thread":"abc123","in_reply_to":null,"to":"sender","from":"receiver","actor":"a","kind":"text","body":"one"}' \
        > "$mine/cur/0000000001-1.json"
    printf '%s\n' '{"id":"2","ts":1700000001,"thread":"abc123","in_reply_to":null,"to":"third","from":"","actor":"a","kind":"text","body":"two"}' \
        > "$mine/out/0000000002-2.json"
    local out rc=0
    out=$("$CS_BIN" -msg --reply abc123 "which conversation is this?" 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  an ambiguous thread id should refuse, not guess"; return 1; }
    assert_output_contains "$out" "abc123" "the error names the ambiguous id" || return 1
}

test_thread_transcript_orders_a_reply_after_its_question() {
    "$CS_BIN" -msg receiver "question?" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    rcv -msg --reply "$thread" "answer!" >/dev/null 2>&1 || return 1
    # Read it from the SENDER's side on purpose: its question sits in out/ and
    # the answer in new/, so scanning new/ then cur/ then out/ renders the reply
    # above the question. Only the in_reply_to chain gets this right.
    local out; out=$("$CS_BIN" -msg thread "$thread" 2>&1) \
        || { echo "  transcript failed: $out"; return 1; }
    local q a
    q=$(printf '%s\n' "$out" | grep -n 'question?' | head -1 | cut -d: -f1)
    a=$(printf '%s\n' "$out" | grep -n 'answer!'   | head -1 | cut -d: -f1)
    [ -n "$q" ] && [ -n "$a" ] || { echo "  transcript is missing a message:"; printf '%s\n' "$out"; return 1; }
    # Both land in the same whole second, so only in_reply_to can order them —
    # a ts tie-break renders the reply above the question it answers.
    [ "$q" -lt "$a" ] || { echo "  the reply rendered above its question"; printf '%s\n' "$out"; return 1; }
}

test_thread_transcript_marks_direction() {
    "$CS_BIN" -msg receiver "question?" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    rcv -msg --reply "$thread" "answer!" >/dev/null 2>&1 || return 1
    local out; out=$(rcv -msg thread "$thread" 2>&1) || return 1
    assert_output_contains "$out" "<-" "a received message reads as inbound" || return 1
    assert_output_contains "$out" "->" "a sent message reads as outbound" || return 1
}

test_unread_lines_carry_the_thread_id() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local thread; thread=$(jq -r .thread "$(FIRST_MSG)")
    local out; out=$(rcv -msg 2>&1)
    assert_output_contains "$out" "$thread" \
        "an agent cannot reply to a thread whose id it is never shown" || return 1
}

test_record_has_no_ref_field() {
    "$CS_BIN" -msg receiver "hi" >/dev/null 2>&1 || return 1
    assert_eq "false" "$(jq 'has("ref")' "$(FIRST_MSG)")" \
        "the record carries no ref field (removed as speculative storage)" || return 1
}

test_send_from_outside_session_has_empty_from() {
    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR "$CS_BIN" -msg receiver "note" >/dev/null 2>&1 || return 1
    assert_eq "" "$(jq -r .from "$(FIRST_MSG)")" "from empty outside a session" || return 1
}

test_send_session_scoped_alias() {
    "$CS_BIN" receiver -msg "via alias" >/dev/null 2>&1 || return 1
    assert_file_contains "$(FIRST_MSG)" "via alias" "session-scoped arm sends" || return 1
}

test_msg_thread_is_reserved_not_a_target() {
    local out rc=0
    out=$("$CS_BIN" -msg thread abc123 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  an unknown thread id should error"; return 1; }
    assert_output_not_contains "$out" "No such session" \
        "'thread' is a reserved first word, not a session to mail" || return 1
    assert_eq "0" "$(NEW_COUNT)" "nothing was sent" || return 1
}

test_alias_thread_errors_instead_of_mailing_the_words() {
    local out rc=0
    out=$("$CS_BIN" receiver -msg thread abc123 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  the alias should refuse a reserved word"; return 1; }
    assert_eq "0" "$(NEW_COUNT)" \
        "'thread abc123' must not be mailed to receiver as a message body" || return 1
}

test_alias_lone_log_errors_instead_of_sending() {
    local out; out=$("$CS_BIN" receiver -msg log 2>&1) && return 1
    assert_output_contains "$out" "cs -msg log" "hint points at the in-session read form" || return 1
    assert_eq "0" "$(NEW_COUNT)" "'log' was not sent as a message body" || return 1
}

test_alias_empty_body_errors_with_read_hint() {
    local out; out=$("$CS_BIN" receiver -msg 2>&1) && return 1
    assert_output_contains "$out" "inside that session" "hint points at the read surface" || return 1
}

test_send_joins_unquoted_multiword_body() {
    "$CS_BIN" -msg receiver hello there world >/dev/null 2>&1 || return 1
    assert_eq "hello there world" "$(jq -r .body "$(FIRST_MSG)")" "unquoted words joined" || return 1
}

test_send_rejects_unknown_target() {
    ! "$CS_BIN" -msg nosuch "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_slash_in_target() {
    ! "$CS_BIN" -msg "../receiver" "x" >/dev/null 2>&1 || return 1
    ! "$CS_BIN" -msg "a/b" "x" >/dev/null 2>&1 || return 1
}

test_send_rejects_backslash_in_target() {
    # A directory that would otherwise resolve, so only the name guard can
    # refuse it. A backslash is a separator in some spellings, which is how
    # "..\\..\\repo" walks out of the sessions root there; nothing cs creates
    # can contain one, since validate_session_name admits no backslash.
    mkdir -p "$CS_SESSIONS_ROOT/a\\b/.cs/local"
    [ -d "$CS_SESSIONS_ROOT/a\\b/.cs" ] || { echo "  fixture did not create the directory"; return 1; }
    ! "$CS_BIN" -msg 'a\b' "x" >/dev/null 2>&1 || return 1
}

# The worktree form is a real session name and must keep working: the canonical
# validate_session_name rejects @, so a guard borrowed wholesale from there
# would refuse mail to every worktree session.
test_send_accepts_a_worktree_target() {
    mkdir -p "$CS_SESSIONS_ROOT/wtbase@feat/.cs/local"
    "$CS_BIN" -msg "wtbase@feat" "hello" >/dev/null 2>&1 || return 1
}

test_send_rejects_dot_and_dotdot_targets() {
    touch "$TEST_TMPDIR/CLAUDE.md"   # makes ".." session-shaped; only the name guard may reject it
    ! "$CS_BIN" -msg .. "escape" >/dev/null 2>&1 || return 1
    [ ! -d "$TEST_TMPDIR/.cs" ] || { echo "  traversal write escaped the root"; return 1; }
    ! "$CS_BIN" -msg . "escape" >/dev/null 2>&1 || return 1
}

test_send_rejects_self() {
    mkdir -p "$CS_SESSIONS_ROOT/sender/.cs/local"
    ! "$CS_BIN" -msg sender "me to me" >/dev/null 2>&1 || return 1
}

test_send_rejects_bad_kind() {
    ! "$CS_BIN" -msg receiver -k bogus "x" >/dev/null 2>&1 || return 1
}

test_send_trailing_flag_errors_loudly() {
    local out; out=$("$CS_BIN" -msg receiver --kind 2>&1) && return 1
    assert_output_contains "$out" "needs a value" "trailing flag errors with a message" || return 1
}

# The cap (65536) bounds render cost, not corruption: delivery is atomic, so
# an over-cap body errors rather than truncates, and an at-cap body sends.
test_send_rejects_empty_and_oversize_body() {
    ! "$CS_BIN" -msg receiver "   " >/dev/null 2>&1 || return 1
    local big; big=$(printf 'a%.0s' $(seq 1 65537))
    ! "$CS_BIN" -msg receiver "$big" >/dev/null 2>&1 || return 1
    assert_eq "0" "$(NEW_COUNT)" "no message delivered on failed send" || return 1
}

# Sent through stdin, which is the channel documented for a body this size and
# the only one that can carry it everywhere: a command line is capped at
# about 32K, so a cap-sized argv value cannot reach cs there at all. The cap
# belongs to the body, not to the way it arrived, so pin it on the channel that
# exists to carry a large one.
test_send_accepts_body_at_the_cap() {
    printf 'a%.0s' $(seq 1 65536) | "$CS_BIN" -msg receiver - >/dev/null 2>&1 \
        || { echo "  at-cap body rejected"; return 1; }
    assert_eq "1" "$(NEW_COUNT)" "at-cap body delivered" || return 1
    assert_eq "65536" "$(jq -r '.body | length' "$(FIRST_MSG)")" "body stored whole" || return 1
}

# `cs -msg <session> -` reads the body from stdin — the channel that makes the
# larger cap reachable, since a multi-KB handoff does not belong in argv.
test_send_reads_body_from_stdin() {
    printf 'b%.0s' $(seq 1 60000) | "$CS_BIN" -msg receiver - >/dev/null 2>&1 \
        || { echo "  stdin body send failed"; return 1; }
    assert_eq "1" "$(NEW_COUNT)" "stdin body delivered" || return 1
    assert_eq "60000" "$(jq -r '.body | length' "$(FIRST_MSG)")" "stdin body stored whole" || return 1
    local out
    out=$(printf 'over%.0s' $(seq 1 20000) | "$CS_BIN" -msg receiver - 2>&1) && return 1
    assert_output_contains "$out" "exceeds" "over-cap stdin body errors, never truncates" || return 1
}

RQUEUE() { printf '%s' "$CS_SESSIONS_ROOT/receiver/.cs/local/queue"; }

test_task_kind_lands_in_recipient_queue() {
    "$CS_BIN" -msg receiver -k task "review the tui diff" >/dev/null 2>&1 || return 1
    assert_dir "$(RQUEUE)" "queue directory created" || return 1
    grep -q "review the tui diff" "$(RQUEUE)"/* || { echo "  task not queued"; return 1; }
    assert_file_contains "$(FIRST_MSG)" "review the tui diff" "attribution recorded" || return 1
    assert_eq "task" "$(jq -r .kind "$(FIRST_MSG)")" "kind is task" || return 1
}

test_task_kind_clears_declined_flag() {
    touch "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined"
    "$CS_BIN" -msg receiver -k task "another" >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/receiver/.cs/local/queue.declined" ] || { echo "  declined flag survived"; return 1; }
}

test_task_kind_rejects_multiline_body() {
    ! "$CS_BIN" -msg receiver -k task "$(printf 'one\ntwo')" >/dev/null 2>&1 || return 1
    local f
    for f in "$(RQUEUE)"/*; do
        [ -f "$f" ] && { echo "  queue written despite rejection"; return 1; }
    done
    assert_eq "0" "$(NEW_COUNT)" "no message delivered despite rejection" || return 1
}

run_test test_send_delivers_one_whole_document_per_message
run_test test_send_writes_full_record
run_test test_send_stamps_a_thread_and_keeps_a_sent_copy
run_test test_reply_derives_its_target_from_the_thread
run_test test_reply_refuses_an_unknown_thread
run_test test_reply_refuses_a_target_that_contradicts_the_thread
run_test test_thread_survives_an_unparseable_document
run_test test_log_shows_what_this_session_sent
# The direction test decides whether a document is one this session SENT (peer =
# .to) or RECEIVED (peer = .from). "out" is a legal session name, so an
# unanchored */out/* pattern reads every document in THAT session's mailbox —
# new/ included — as sent, and derives the replier itself as the peer.
test_reply_direction_is_anchored_on_the_maildir() {
    create_test_session out >/dev/null || return 1
    "$CS_BIN" -msg out "question?" >/dev/null 2>&1 || return 1
    local msg="" f
    for f in "$CS_SESSIONS_ROOT/out/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] && { msg="$f"; break; }
    done
    [ -n "$msg" ] || { echo "  FAIL: nothing was delivered to the session named out"; return 1; }
    # Reachability: the path must actually contain an "out" component, or the
    # unanchored pattern is never reached and this proves nothing.
    case "$msg" in
        */out/*) : ;;
        *) echo "  FAIL: fixture path has no 'out' component: $msg"; return 1 ;;
    esac
    assert_eq "sender" "$(jq -r .from "$msg")" \
        "the fixture document is RECEIVED mail, so its peer is .from" || return 1
    assert_eq "out" "$(jq -r .to "$msg")" \
        "and .to names the replier itself, which is what an unanchored test picks up" || return 1

    local thread rc=0 out
    thread=$(jq -r .thread "$msg")
    out=$(
        export CLAUDE_SESSION_NAME=out
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/out"
        export CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/out/.cs"
        "$CS_BIN" -msg --reply "$thread" "answer!" 2>&1
    ) || rc=$?
    [ "$rc" = "0" ] || { echo "  FAIL: a session named out could not answer its own mail: $out"; return 1; }
    local back="" n=0
    for f in "$CS_SESSIONS_ROOT/sender/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] || continue; n=$((n + 1)); back="$f"
    done
    assert_eq "1" "$n" "the reply routes to the correspondent, not back to the replier" || return 1
    assert_eq "sender" "$(jq -r .to "$back")" "the peer was read from .from" || return 1
}

# _mail_thread_files' fast path asks jq for input_filename, and jq echoes each
# path exactly as IT received it. The caller keys reply direction on the
# "$maildir"/out/* pattern, so a path spelled any other way makes every sent
# copy read as received and a session replying to a thread it started addresses
# itself. The paths must be the caller's own.
test_thread_files_emit_paths_anchored_on_the_maildir_given() {
    "$CS_BIN" -msg receiver "anchor probe" >/dev/null 2>&1 || return 1
    local maildir="$CS_SESSIONS_ROOT/sender/.cs/local/mail" sent="" f
    for f in "$maildir"/out/*.json; do [ -f "$f" ] && { sent="$f"; break; }; done
    [ -n "$sent" ] || { echo "  FAIL: no sent copy to probe"; return 1; }
    local thread; thread=$(jq -r .thread "$sent")

    local out n=0
    out=$(
        eval "$(sed 's/^main "\$@"$/:/' "$CS_BIN")" 2>/dev/null
        _mail_thread_files "$maildir" "$thread"
    ) || { echo "  FAIL: _mail_thread_files found nothing for thread $thread"; return 1; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        case "$f" in
            "$maildir"/*) : ;;
            *) echo "  FAIL: emitted path is not anchored on the maildir it was given"
               echo "    maildir: $maildir"
               echo "    emitted: $f"
               return 1 ;;
        esac
    done <<EOF
$out
EOF
    [ "$n" -gt 0 ] || { echo "  FAIL: nothing emitted for a thread that exists"; return 1; }
}


# The other arm of the same case statement: a document this session SENT lives in
# out/, and its peer is .to. Deleting the case and always using .from keeps the
# test above green, so the sent direction needs its own pin.
test_reply_reads_the_peer_from_to_on_a_sent_message() {
    "$CS_BIN" -msg receiver "opening question?" >/dev/null 2>&1 || return 1
    local sent="" f
    for f in "$CS_SESSIONS_ROOT/sender/.cs/local/mail/out"/*.json; do
        [ -f "$f" ] && { sent="$f"; break; }
    done
    [ -n "$sent" ] || { echo "  FAIL: the sender kept no copy in out/"; return 1; }
    assert_eq "receiver" "$(jq -r .to "$sent")" "the sent copy names its recipient" || return 1
    assert_eq "sender" "$(jq -r .from "$sent")" \
        "and names this session as author, which is what the wrong arm would return" || return 1

    # Replying from the SENDER, whose only view of the thread is that sent copy.
    local thread rc=0 out
    thread=$(jq -r .thread "$sent")
    out=$("$CS_BIN" -msg --reply "$thread" "following up" 2>&1) || rc=$?
    [ "$rc" = "0" ] || { echo "  FAIL: could not follow up on a thread we started: $out"; return 1; }
    local n=0
    for f in "$(MAILDIR)"/new/*.json; do [ -f "$f" ] || continue; n=$((n + 1)); done
    assert_eq "2" "$n" \
        "the follow-up went to the recipient; reading .from would have addressed ourselves" || return 1
}

# 'from' is empty on mail sent from outside a session, so the peer cannot be
# derived and the caller must name the target. The peer and the parent id cross
# that boundary as one string: a TAB separator is IFS whitespace, so bash
# collapses the empty leading field and the parent id arrives AS the peer,
# turning "cannot tell who" into a confident wrong answer.
test_reply_to_an_anonymous_thread_needs_a_target_and_keeps_the_parent() {
    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_DIR \
        "$CS_BIN" -msg receiver "note from outside" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || { echo "  FAIL: nothing delivered"; return 1; }
    assert_eq "" "$(jq -r .from "$msg")" \
        "the fixture's peer really is underivable, so the empty-peer branch is reached" || return 1
    local thread parent
    thread=$(jq -r .thread "$msg"); parent=$(jq -r .id "$msg")

    local out rc=0
    out=$(rcv -msg --reply "$thread" "who is this?" 2>&1) || rc=$?
    [ "$rc" != "0" ] || { echo "  FAIL: an underivable peer must refuse, not guess"; return 1; }
    assert_output_contains "$out" "cannot tell who thread $thread is with" \
        "the parent id must not be handed back as the peer" || return 1

    rcv -msg sender --reply "$thread" "answering" >/dev/null 2>&1 \
        || { echo "  FAIL: naming the target must let the reply through"; return 1; }
    local back="" f
    for f in "$CS_SESSIONS_ROOT/sender/.cs/local/mail/new"/*.json; do
        [ -f "$f" ] && { back="$f"; break; }
    done
    [ -n "$back" ] || { echo "  FAIL: the reply was not delivered"; return 1; }
    assert_eq "sender" "$(jq -r .to "$back")" "the named target is honoured" || return 1
    assert_eq "$parent" "$(jq -r .in_reply_to "$back")" \
        "the parent id crossed the peer handoff intact" || return 1
}

run_test test_reply_refuses_an_ambiguous_thread
run_test test_reply_direction_is_anchored_on_the_maildir
run_test test_thread_files_emit_paths_anchored_on_the_maildir_given
run_test test_reply_reads_the_peer_from_to_on_a_sent_message
run_test test_reply_to_an_anonymous_thread_needs_a_target_and_keeps_the_parent
run_test test_thread_transcript_orders_a_reply_after_its_question
run_test test_thread_transcript_marks_direction
run_test test_unread_lines_carry_the_thread_id
run_test test_record_has_no_ref_field
run_test test_send_from_outside_session_has_empty_from
run_test test_send_session_scoped_alias
run_test test_msg_thread_is_reserved_not_a_target
run_test test_alias_thread_errors_instead_of_mailing_the_words
run_test test_alias_lone_log_errors_instead_of_sending
run_test test_alias_empty_body_errors_with_read_hint
run_test test_send_joins_unquoted_multiword_body
run_test test_send_rejects_unknown_target
run_test test_send_rejects_slash_in_target
run_test test_send_rejects_backslash_in_target
run_test test_send_accepts_a_worktree_target
run_test test_send_rejects_dot_and_dotdot_targets
run_test test_send_rejects_self
run_test test_send_rejects_bad_kind
run_test test_send_trailing_flag_errors_loudly
run_test test_send_rejects_empty_and_oversize_body
run_test test_send_accepts_body_at_the_cap
run_test test_send_reads_body_from_stdin
run_test test_task_kind_lands_in_recipient_queue
run_test test_task_kind_clears_declined_flag
run_test test_task_kind_rejects_multiline_body

# Run any command with the ambient session env pointed at receiver.
_receiver_env() {
    CLAUDE_SESSION_NAME="receiver" \
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver" \
    CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/receiver/.cs" \
    "$@"
}

# Read receiver's mail through the cs binary.
_as_receiver() {
    _receiver_env "$CS_BIN" "$@"
}

# Reading moves what it printed from new/ to cur/ (spec test 3): a second read
# reports nothing unread, and the read messages survive as history in cur/.
test_read_prints_unread_then_moves_to_cur() {
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1
    "$CS_BIN" -msg receiver "second" >/dev/null 2>&1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "first" "first body shown" || return 1
    assert_output_contains "$out" "second" "second body shown" || return 1
    assert_output_contains "$out" "sender" "sender attributed" || return 1
    assert_output_contains "$out" "\[text\]" "kind tagged" || return 1
    assert_eq "0" "$(NEW_COUNT)" "printed messages left new/" || return 1
    local f n=0
    for f in "$(MAILDIR)"/cur/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    assert_eq "2" "$n" "printed messages landed in cur/" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "No unread mail" "second read is empty" || return 1
}

test_log_reprints_read_mail() {
    "$CS_BIN" -msg receiver "logged" >/dev/null 2>&1
    _as_receiver -msg >/dev/null 2>&1 || return 1
    local out; out=$(_as_receiver -msg log 2>&1) || return 1
    assert_output_contains "$out" "logged" "log shows read mail" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "No unread mail" "log does not resurrect unread state" || return 1
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

# Spec test 4 (reader): only regular new/*.json files are mail. A .DS_Store, a
# stray tmp leftover, a plain subdirectory, and — the case that matters — a
# DIRECTORY whose name ends in .json must neither render nor count as unread.
# That last one is what separates the readers: a glob-and-`-e` reader accepts
# it while the status line and the TUI (`-f` / is_file) do not, so a fixture
# without it lets the four definitions drift while every suite stays green.
test_read_skips_non_json_entries() {
    "$CS_BIN" -msg receiver "real message" >/dev/null 2>&1 || return 1
    printf 'stray bytes\n' > "$(MAILDIR)/new/.DS_Store"
    printf '{"id":"x","ts":1,"from":"sender","actor":"a","kind":"text","body":"halfway"}' \
        > "$(MAILDIR)/new/0000000001-half.json.partial"
    mkdir -p "$(MAILDIR)/new/subdir"
    mkdir -p "$(MAILDIR)/new/0000000002-stray.json"
    assert_eq "1" "$(NEW_COUNT)" "only the real message counts as unread" || return 1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "real message" "real message shown" || return 1
    assert_output_not_contains "$out" "halfway" "non-.json entry hidden" || return 1
    out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "No unread mail" "strays never count as unread" || return 1
    assert_eq "0" "$(NEW_COUNT)" "reading leaves no phantom unread behind" || return 1
    [ -d "$(MAILDIR)/new/0000000002-stray.json" ] || { echo "  stray dir was moved to cur/"; return 1; }
}

test_read_renders_null_ts_and_flattens_multiline_body() {
    mkdir -p "$(MAILDIR)/new"
    # ts:null must fall back to --:-- (not crash strflocaltime); an embedded
    # newline in the body must render on one line, never breaking the display.
    printf '{"id":"n","ts":null,"from":"sender","actor":"a","kind":"text","body":"line one\\nline two","ref":null}\n' \
        > "$(MAILDIR)/new/0000000001-n.json"
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "--:--" "null ts renders as --:--" || return 1
    assert_output_contains "$out" "line one line two" "multiline body flattened to one line" || return 1
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'line one')" "body renders on a single line" || return 1
}

test_read_survives_corrupt_document_and_big_mailbox() {
    mkdir -p "$(MAILDIR)/new"
    printf 'not json at all\n' > "$(MAILDIR)/new/0000000000-corrupt.json"
    local i=0
    while [ "$i" -lt 400 ]; do
        printf '{"id":"b%s","ts":1,"from":"s","actor":"a","kind":"text","body":"filler message %s padding padding padding padding padding padding padding padding padding padding padding padding padding padding","ref":null}\n' "$i" "$i" \
            > "$(MAILDIR)/new/$(printf '0000000001-%04d' "$i")-b.json"
        i=$((i + 1))
    done
    local out rc=0
    out=$(_as_receiver -msg 2>&1) || rc=$?
    assert_eq "0" "$rc" "big mailbox read exits 0 (no SIGPIPE 141)" || return 1
    assert_output_contains "$out" "filler message 399" "last message present" || return 1
}

run_test test_read_prints_unread_then_moves_to_cur
run_test test_log_reprints_read_mail
run_test test_read_outside_session_errors
run_test test_read_strips_control_characters
run_test test_read_skips_non_json_entries
run_test test_read_renders_null_ts_and_flattens_multiline_body
run_test test_read_survives_corrupt_document_and_big_mailbox

_prompt_as_receiver() {  # prompt-text
    printf '{"prompt": "%s"}' "$1" | _receiver_env bash "$HOOKS_DIR/scope-prompt.sh"
}

# Unread mail inlines its bodies on EVERY prompt until read (persistent, keyed
# on the `seen` cursor) — not surface-once. text/notify/result bodies inline.
test_mail_persists_inline_until_read() {
    "$CS_BIN" -msg receiver "review the auth PR please" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "mail from sender" "sender shown" || return 1
    assert_output_contains "$out" "review the auth PR please" "body inlined" || return 1
    # Persistent: a second prompt still shows it (old behavior was surface-once).
    out=$(_prompt_as_receiver "again") || return 1
    assert_output_contains "$out" "review the auth PR please" "body still inlined next prompt" || return 1
}

# Reading with cs -msg advances the `seen` cursor, which clears the digest.
test_mail_read_clears_digest() {
    "$CS_BIN" -msg receiver "transient note" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "transient note" "shown before read" || return 1
    _as_receiver -msg >/dev/null 2>&1 || return 1
    out=$(_prompt_as_receiver "after") || return 1
    assert_output_not_contains "$out" "transient note" "cleared after cs -msg read" || return 1
}

# A task-kind message is already queued (cs -msg -k task enqueues it); the digest
# must NOT inline its body, or Claude would act on it and the queue drain would
# run it a second time. Surfaced as a count-only label instead.
test_task_kind_counted_not_inlined() {
    "$CS_BIN" -msg receiver -k task "delete merged branches" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_not_contains "$out" "delete merged branches" "task body not inlined" || return 1
    assert_output_contains "$out" "queued task" "task surfaced as a queued-task label" || return 1
}

# Bounded: at most 5 bodies inline, with an "N more" overflow line and the total.
# Seeded as files rather than via seven `cs -msg` runs: document names carry the
# sending process's pid unpadded, so same-second sends from different pids sort
# by pid STRING (999 after 1000) and "which five come first" would flake at
# every digit-length boundary. _mail_send's own comment says name order is not
# arrival order, so a test must not depend on it.
test_mail_bounded_at_five() {
    mkdir -p "$(MAILDIR)/new"
    local i=1
    while [ "$i" -le 7 ]; do
        printf '{"id":"m%s","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"message number %s here"}\n' \
            "$i" "$i" > "$(MAILDIR)/new/000000000$i-m$i.json"
        i=$((i + 1))
    done
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "message number 5 here" "fifth body shown" || return 1
    assert_output_not_contains "$out" "message number 6 here" "sixth body capped" || return 1
    assert_output_contains "$out" "2 more" "overflow counted" || return 1
    assert_output_contains "$out" "Unread mail (7)" "total unread count shown" || return 1
}

# The bound is on MESSAGES, not on files opened. One document holding many JSON
# lines must still render at most five, because the digest is prepended after
# the scope cap and nothing downstream would trim it — an unbounded document
# would inject unbounded context on every prompt. The seven-file fixture above
# cannot reach this: the file window alone satisfies it.
test_mail_digest_bounds_messages_not_files() {
    mkdir -p "$(MAILDIR)/new"
    local i=1
    while [ "$i" -le 10 ]; do
        printf '{"id":"b%s","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"crafted line %s"}\n' \
            "$i" "$i"
        i=$((i + 1))
    done > "$(MAILDIR)/new/0000000001-many.json"
    local out; out=$(_prompt_as_receiver "hello") || return 1
    # The hook emits the digest inside a JSON string, so its newlines are
    # escaped and the whole digest is one output line: count occurrences, not
    # matching lines.
    assert_eq "5" "$(printf '%s' "$out" | grep -o 'crafted line' | wc -l | tr -d ' ')" \
        "at most five bodies rendered" || return 1
    assert_output_not_contains "$out" "crafted line 6" "the sixth message is not inlined" || return 1
}

# A window whose documents cannot be parsed must still report. Going silent
# while the badge counts N unread is the one outcome a persistent digest exists
# to prevent: the session would never learn it has mail.
test_mail_digest_reports_when_nothing_parses() {
    mkdir -p "$(MAILDIR)/new"
    local i=1
    while [ "$i" -le 6 ]; do
        printf 'not json at all\n' > "$(MAILDIR)/new/000000000$i-bad.json"
        i=$((i + 1))
    done
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "Unread mail (6)" "the count is still surfaced" || return 1
    assert_output_contains "$out" "cs -msg" "and the way to clear it" || return 1
}

# Long bodies are truncated (codepoint-safe, inside jq) so context stays bounded.
test_mail_body_truncated() {
    local long; long=$(printf 'A%.0s' $(seq 1 300))
    "$CS_BIN" -msg receiver "$long" >/dev/null 2>&1
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "$(printf 'A%.0s' $(seq 1 160))" "160-char prefix present" || return 1
    assert_output_not_contains "$out" "$long" "full over-long body not shown" || return 1
}

# A forged inbox line with a huge sender must be truncated too — attribution is
# unauthenticated (any same-user process can append), so an unbounded `from`
# would otherwise flood context every turn.
test_forged_long_sender_truncated() {
    local big; big=$(printf 'S%.0s' $(seq 1 200))
    mkdir -p "$(MAILDIR)/new"   # no cs -msg sent first, so create the maildir
    printf '{"id":"f","ts":1,"from":"%s","actor":"a","kind":"text","body":"forged hi"}\n' "$big" \
        > "$(MAILDIR)/new/0000000001-f.json"
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_not_contains "$out" "$big" "over-long sender truncated" || return 1
    assert_output_contains "$out" "forged hi" "body still shown" || return 1
}

# A forged line with a non-string body must not error the whole jq program and
# suppress the valid messages beside it — fields are coerced to strings.
test_mail_nonstring_body_does_not_wipe_digest() {
    "$CS_BIN" -msg receiver "valid body here" >/dev/null 2>&1
    printf '{"id":"x","ts":1,"from":"sender","actor":"a","kind":"text","body":12345}\n' \
        > "$(MAILDIR)/new/0000000001-x.json"
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "valid body here" "valid message survives a forged non-string body" || return 1
    assert_output_contains "$out" "12345" "non-string body is coerced, not dropped"
}

# session-start no longer delivers the mail digest: scope-prompt surfaces it on
# every prompt, so keeping it here would double-inject on every startup/resume.
test_session_start_does_not_deliver_mail() {
    # notify was inlined by the old session-start path, so this is a real check.
    "$CS_BIN" -msg receiver -k notify "start body here" >/dev/null 2>&1
    local out
    out=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | \
        _receiver_env bash "$HOOKS_DIR/session-start.sh") || return 1
    assert_output_not_contains "$out" "start body here" "session-start does not surface mail" || return 1
    assert_output_not_contains "$out" "Unread mail" "no mail digest header from session-start" || return 1
}

# Spec test 4 (digest reader): a non-regular or non-.json entry in new/ is
# neither inlined nor counted — no phantom unread the digest nags about but
# cs -msg cannot clear. The DIRECTORY named *.json is the load-bearing case:
# the glob excludes every other stray on its own, so only this one reaches the
# `-f` guard. It is also the worst failure — `cat` on a directory fails, and
# under pipefail that wipes the WHOLE digest, so real unread mail would stop
# surfacing entirely rather than merely miscounting.
test_digest_ignores_non_json_entries() {
    "$CS_BIN" -msg receiver "solid body" >/dev/null 2>&1
    printf '{"id":"t","ts":1,"from":"sender","actor":"a","kind":"text","body":"straybody"}\n' \
        > "$(MAILDIR)/new/0000000001-t.json.partial"
    mkdir -p "$(MAILDIR)/new/0000000002-dir.json"
    local out; out=$(_prompt_as_receiver "hello") || return 1
    assert_output_contains "$out" "solid body" "real message shown" || return 1
    assert_output_not_contains "$out" "straybody" "non-.json entry excluded" || return 1
    assert_output_contains "$out" "Unread mail (1)" "stray not counted as unread" || return 1
}

run_test test_mail_persists_inline_until_read
run_test test_mail_read_clears_digest
run_test test_task_kind_counted_not_inlined
run_test test_mail_bounded_at_five
run_test test_mail_digest_bounds_messages_not_files
run_test test_mail_digest_reports_when_nothing_parses
run_test test_mail_body_truncated
run_test test_forged_long_sender_truncated
run_test test_mail_nonstring_body_does_not_wipe_digest
run_test test_session_start_does_not_deliver_mail
run_test test_digest_ignores_non_json_entries

# --- Legacy inbox migration (session open converts inbox.jsonl to the maildir) ---

CUR_COUNT() {
    local f n=0
    for f in "$(MAILDIR)"/cur/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# Open the receiver session so migrate_session runs; the echo stub stands in
# for claude, so cs exits after setup.
_open_receiver() {
    CLAUDE_CODE_BIN=echo "$CS_BIN" receiver < /dev/null > /dev/null 2>&1 || true
}

_seed_legacy_inbox() {  # jsonl lines...
    mkdir -p "$(MAILDIR)"
    local l
    for l in "$@"; do
        printf '%s\n' "$l"
    done > "$(MAILDIR)/inbox.jsonl"
}

test_migration_converts_legacy_inbox_honoring_seen() {
    _seed_legacy_inbox \
        '{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"read one"}' \
        '{"id":"1700000001-11-2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"unread two"}' \
        '{"id":"1700000002-11-3","ts":1700000002,"from":"sender","actor":"a","kind":"text","body":"unread three"}'
    printf '1\n' > "$(MAILDIR)/seen"
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "lines past seen land in new/" || return 1
    assert_eq "1" "$(CUR_COUNT)" "seen lines land in cur/" || return 1
    [ ! -f "$(MAILDIR)/inbox.jsonl" ] || { echo "  inbox.jsonl survived migration"; return 1; }
    [ ! -f "$(MAILDIR)/inbox.jsonl.migrating" ] || { echo "  migrating file left behind"; return 1; }
    [ ! -f "$(MAILDIR)/seen" ] || { echo "  seen cursor left behind"; return 1; }
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "unread two" "migrated unread readable" || return 1
    assert_output_contains "$out" "unread three" "migrated unread readable" || return 1
    assert_output_not_contains "$out" "read one" "seen mail not re-surfaced as unread" || return 1
}

run_test test_migration_converts_legacy_inbox_honoring_seen

# A conversion killed partway leaves inbox.jsonl.migrating holding lines it has
# ALREADY delivered. Retrying must deliver nothing new. The fixture has to seed
# the delivered files too — a leftover next to an empty new/ never reaches the
# already-converted branch, which is how the duplication below survived a green
# suite. Also covers the nastier variant: a message the recipient read between
# the two runs must not be resurrected as unread.
test_migration_retry_after_interruption_delivers_nothing_twice() {
    local l1 l2
    l1='{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"first"}'
    l2='{"id":"1700000001-11-2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"second"}'
    mkdir -p "$(MAILDIR)"
    printf '%s\n%s\n' "$l1" "$l2" > "$(MAILDIR)/inbox.jsonl"
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "first conversion delivers both" || return 1
    # The recipient reads one of them, so it now lives in cur/.
    _as_receiver -msg >/dev/null 2>&1 || return 1
    assert_eq "0" "$(NEW_COUNT)" "reading empties new/" || return 1
    # Now model the interruption: the same legacy content is stranded again.
    printf '%s\n%s\n' "$l1" "$l2" > "$(MAILDIR)/inbox.jsonl.migrating"
    _open_receiver
    assert_eq "0" "$(NEW_COUNT)" "retry re-delivers nothing, not even as unread" || return 1
    assert_eq "2" "$(CUR_COUNT)" "and creates no duplicate copies" || return 1
    [ ! -f "$(MAILDIR)/inbox.jsonl.migrating" ] || { echo "  migrating file left behind"; return 1; }
}

run_test test_migration_retry_after_interruption_delivers_nothing_twice

# The gate is keyed on inbox.jsonl ALONE: delivery creates the maildir on send,
# so a session that received one new-format message before its next open still
# has legacy mail to convert — requiring new/ to be absent would strand it.
test_migration_merges_when_new_already_exists() {
    _seed_legacy_inbox \
        '{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"legacy unread"}'
    "$CS_BIN" -msg receiver "fresh format message" >/dev/null 2>&1 || return 1
    assert_eq "1" "$(NEW_COUNT)" "new-format message already delivered" || return 1
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "legacy unread merged beside the delivered message" || return 1
    [ ! -f "$(MAILDIR)/inbox.jsonl" ] || { echo "  inbox.jsonl survived migration"; return 1; }
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "legacy unread" "legacy mail readable" || return 1
    assert_output_contains "$out" "fresh format message" "delivered mail readable" || return 1
}

# A conversion killed mid-loop leaves the legacy file intact AND some records
# already delivered. The retry must deliver only what is missing. Filenames
# therefore derive solely from the legacy content, so the same record converts
# to the same name every run and the retry recognises it. Before that, the
# retry saw the name taken, wrote a -NNNN variant beside it, and the recipient
# read the same message twice.
test_migration_retry_after_partial_conversion_delivers_no_duplicates() {
    _seed_legacy_inbox \
        '{"id":"a1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"first legacy"}' \
        '{"id":"a2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"second legacy"}'
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "both records converted on the first run" || return 1
    # Model the crash: the legacy file is back (a stale writer recreated it, or
    # the run died before the unlink) while its records are already delivered.
    _seed_legacy_inbox \
        '{"id":"a1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"first legacy"}' \
        '{"id":"a2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"second legacy"}'
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "the retry delivers nothing already present" || return 1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'first legacy')" "message shown once, not twice" || return 1
}

# A write that fails mid-conversion must not cost the mail. The delivery is
# `printf > tmp && mv`, and a failed printf is the NON-FINAL command of an &&
# list, so errexit never fires and the loop runs to the end looking successful
# — at which point unlinking the legacy file would destroy every record that
# never landed. An unwritable tmp/ is the reproducible stand-in for ENOSPC.
test_migration_keeps_the_legacy_file_when_a_record_cannot_be_written() {
    _seed_legacy_inbox \
        '{"id":"w1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"must survive"}'
    mkdir -p "$(MAILDIR)/tmp"
    _deny_writes "$(MAILDIR)/tmp" || return 0
    _open_receiver
    _allow_writes "$(MAILDIR)/tmp"
    assert_eq "0" "$(NEW_COUNT)" "nothing was delivered" || return 1
    local legacy_present=0
    [ -f "$(MAILDIR)/inbox.jsonl" ] && legacy_present=1
    [ -f "$(MAILDIR)/inbox.jsonl.migrating" ] && legacy_present=1
    assert_eq "1" "$legacy_present" "the undelivered mail is still on disk to retry" || return 1
    # And the retry, once writes work again, delivers it.
    _open_receiver
    assert_eq "1" "$(NEW_COUNT)" "the retry delivers the record" || return 1
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "must survive" "the message survived the failed run" || return 1
}

# A record the recipient already READ must not come back as unread: the retry
# checks both boxes, not just the one it would deliver into.
test_migration_retry_does_not_resurrect_read_mail() {
    _seed_legacy_inbox \
        '{"id":"r1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"already read body"}'
    _open_receiver
    _as_receiver -msg >/dev/null 2>&1 || return 1
    assert_eq "0" "$(NEW_COUNT)" "reading moved it out of new/" || return 1
    _seed_legacy_inbox \
        '{"id":"r1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"already read body"}'
    _open_receiver
    assert_eq "0" "$(NEW_COUNT)" "the retry does not resurrect it as unread" || return 1
}

# Only lines that do not parse at all are quarantined (evidence of the append
# tearing this design removes); a ts:null record is valid legacy content and
# must convert without producing a malformed filename.
test_migration_quarantines_corrupt_and_converts_null_ts() {
    _seed_legacy_inbox \
        '{"id":"x","ts":1,"from":"sender","actor":"a","kind":"te{"id":"y","ts":2,"body":"spliced' \
        '{"id":"n","ts":null,"from":"sender","actor":"a","kind":"text","body":"null ts body"}'
    _open_receiver
    assert_file_exists "$(MAILDIR)/corrupt.jsonl" "unparseable line quarantined" || return 1
    assert_file_contains "$(MAILDIR)/corrupt.jsonl" "spliced" "quarantine holds the torn line" || return 1
    assert_eq "1" "$(NEW_COUNT)" "the parseable record converted" || return 1
    local f
    for f in "$(MAILDIR)"/new/*.json; do
        case "${f##*/}" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.json) : ;;
            *) echo "  malformed filename from null ts: ${f##*/}"; return 1 ;;
        esac
    done
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "null ts body" "null-ts record readable after migration" || return 1
    assert_output_contains "$out" "--:--" "null ts still renders as --:--" || return 1
}

# Spec test 7: a line a stale writer appended after the mv (it keeps the renamed
# inode's descriptor) is still converted. Deterministic stand-in for the race: a
# pre-existing inbox.jsonl.migrating (the state a crash or a mid-migration
# append leaves) is converted first and never clobbered by the next rename.
test_migration_converts_lines_landing_in_migrating_file() {
    mkdir -p "$(MAILDIR)"
    printf '{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"late appended line"}\n' \
        > "$(MAILDIR)/inbox.jsonl.migrating"
    _seed_legacy_inbox \
        '{"id":"1700000001-11-2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"second wave"}'
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "both the stranded and the fresh line converted" || return 1
    [ ! -f "$(MAILDIR)/inbox.jsonl.migrating" ] || { echo "  migrating file left behind"; return 1; }
    local out; out=$(_as_receiver -msg 2>&1) || return 1
    assert_output_contains "$out" "late appended line" "stranded line delivered" || return 1
    assert_output_contains "$out" "second wave" "fresh line delivered" || return 1
}

# A torn final line without a trailing newline is still read (the stale writer
# died mid-append); parseable content converts, unparseable quarantines.
test_migration_reads_unterminated_final_line() {
    mkdir -p "$(MAILDIR)"
    printf '{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"terminated"}\n{"id":"1700000001-11-2","ts":1700000001,"from":"sender","actor":"a","kind":"text","body":"unterminated"}' \
        > "$(MAILDIR)/inbox.jsonl"
    _open_receiver
    assert_eq "2" "$(NEW_COUNT)" "unterminated final line still converted" || return 1
}

# The worktree open path bypasses migrate_session entirely; a worktree checkout
# can still hold a legacy inbox.jsonl from the shipped mailbox, so mail
# migration must run there too.
test_migration_runs_on_worktree_open() {
    create_test_session_with_git "wtbase" >/dev/null
    CLAUDE_CODE_BIN=echo "$CS_BIN" "wtbase@feat" < /dev/null > /dev/null 2>&1 || true
    local wtmail="$CS_SESSIONS_ROOT/wtbase@feat/.cs/local/mail"
    [ -d "$CS_SESSIONS_ROOT/wtbase@feat" ] || { echo "  worktree session not created"; return 1; }
    mkdir -p "$wtmail"
    printf '{"id":"1700000000-11-1","ts":1700000000,"from":"sender","actor":"a","kind":"text","body":"worktree legacy"}\n' \
        > "$wtmail/inbox.jsonl"
    CLAUDE_CODE_BIN=echo "$CS_BIN" "wtbase@feat" < /dev/null > /dev/null 2>&1 || true
    [ ! -f "$wtmail/inbox.jsonl" ] || { echo "  worktree open did not migrate the inbox"; return 1; }
    local f n=0
    for f in "$wtmail"/new/*.json; do
        [ -e "$f" ] || continue
        n=$((n + 1))
    done
    assert_eq "1" "$n" "worktree legacy mail landed in new/" || return 1
}

# --- mail wake -------------------------------------------------------------
# The wakes run as the RECIPIENT, so every wake helper re-points the session env
# at receiver; the suite's own env names sender (it is the one sending).
# RCV_META and rcv are defined near the top, alongside MAILDIR.

# Drive the Stop hook as the receiver's LEAD conversation: cs's exec arm replaces
# its own process, so claude carries cs's pid and the two agree.
wake() {
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        export CS_LEAD_PID=$$ CLAUDE_PID=$$
        echo "${1:-{\}}" | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null
    )
}

# A tmux-backed teammate is a full claude with its own top-level Stop, but tmux
# started it, so cs is neither its process nor its parent and CS_LEAD_PID is
# absent from its environment entirely.
wake_as_teammate() {
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        unset CS_LEAD_PID CLAUDE_PID
        echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null
    )
}

test_stop_wake_only_the_lead_wakes() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local out; out=$(wake_as_teammate)
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "a teammate does not take the wake" || return 1
    assert_file_not_exists "$(RCV_META)/local/mail/woke" \
        "and records nothing, so the lead's wake survives" || return 1
    out=$(wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "the lead still wakes for the same message" || return 1
}

# Drive the FileChanged event as the receiver's lead. Streams pass through
# untouched: the payload rides on stderr and delivery is the exit code.
filechanged() {  # file_path, [event]
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        export CS_LEAD_PID=$$ CLAUDE_PID=$$
        jq -nc --arg p "$1" --arg e "${2:-add}" \
            '{hook_event_name: "FileChanged", file_path: $p, event: $e}' \
            | bash "$HOOKS_DIR/narrative-reminder.sh"
    )
}

# Drive the CwdChanged event as the receiver's lead.
cwdchanged() {  # old_cwd, new_cwd
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        export CS_LEAD_PID=$$ CLAUDE_PID=$$
        jq -nc --arg o "${1:-/tmp}" --arg n "${2:-/}" \
            '{hook_event_name: "CwdChanged", old_cwd: $o, new_cwd: $n}' \
            | bash "$HOOKS_DIR/narrative-reminder.sh"
    )
}

test_cwd_change_rearms_the_maildir_watch() {
    # A cwd change REPLACES the session's dynamic watch list with whatever the
    # CwdChanged hooks return, so a session that answers nothing loses the
    # maildir watch and never wakes again until the next SessionStart. Answering
    # with the maildir turns the event that wiped the watch into the one that
    # restores it.
    local out; out=$(cwdchanged "/tmp" "/")
    local watch; watch=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.watchPaths[0] // empty' 2>/dev/null)
    assert_eq "$(RCV_META)/local/mail/new" "$watch" "the cwd change re-arms the maildir watch" || return 1
    assert_eq "CwdChanged" \
        "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)" \
        "and names the event it is answering" || return 1
}

test_cwd_change_creates_the_maildir_before_arming() {
    # A watch given a path missing two levels never fires again for that
    # process's lifetime, so arming on a maildir that does not exist yet is
    # worse than not arming at all.
    rm -rf "$(RCV_META)/local/mail"
    cwdchanged "/tmp" "/" >/dev/null
    [ -d "$(RCV_META)/local/mail/new" ] \
        || { echo "  FAIL: the maildir must exist before the watch is armed"; return 1; }
}

test_cwd_change_never_reaches_the_drain() {
    # The drain pops a task off the queue. An event that fell through to it
    # would consume queued work on every directory change, silently.
    local qdir; qdir="$(RCV_META)/local/queue"
    mkdir -p "$qdir"
    printf 'only task\n' > "$qdir/0000000001-seed"
    printf 'armed\n' > "$(RCV_META)/local/queue.state"
    local out; out=$(cwdchanged "/tmp" "/")
    assert_output_not_contains "$out" "walk-away" "a cwd change must not start a drain" || return 1
    assert_output_not_contains "$out" "decision" "and must not block the turn" || return 1
    [ -f "$qdir/0000000001-seed" ] \
        || { echo "  FAIL: a cwd change consumed a queued task"; return 1; }
}

test_idle_wake_exits_2_with_the_reason_on_stderr() {
    "$CS_BIN" -msg receiver "wake up" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || return 1
    local err rc=0
    err=$(filechanged "$msg" add 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "asyncRewake delivers by exiting 2" || return 1
    assert_output_contains "$err" "Unread cross-session mail" \
        "the reason rides on stderr, which outranks stdout in the composed payload" || return 1
}

# The watcher reports file_path in the platform's own spelling, which need not
# be the one $MAILDIR was built from — /private/var beside /var, say.
# Matching the strings makes
# the wake depend on which spelling the reporter happened to use, so a real
# arrival in this session's own new/ is dropped and idle mail never wakes it.
test_idle_wake_accepts_another_spelling_of_the_same_path() {
    "$CS_BIN" -msg receiver "wake up" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || return 1
    local other; other=$(cd "$(dirname "$msg")" && pwd -P)/$(basename "$msg")
    [ "$other" != "$msg" ] || { echo "    SKIP (no second spelling of the maildir on this host)"; return 0; }
    [ -f "$other" ] || { echo "  FAIL: the second spelling does not name the same file"; return 1; }
    local rc=0
    filechanged "$other" add >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" \
        "a wake must follow the file, not the spelling of the path reporting it" || return 1
}

test_idle_wake_ignores_files_outside_the_maildir() {
    "$CS_BIN" -msg receiver "wake up" >/dev/null 2>&1 || return 1
    local rc=0
    filechanged "$(RCV_META)/local/queue/some-task" add >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" \
        "a match-all entry sees every watch path in the session; only our own maildir counts" || return 1
}

test_idle_wake_ignores_unlink() {
    "$CS_BIN" -msg receiver "wake up" >/dev/null 2>&1 || return 1
    local msg; msg=$(FIRST_MSG) || return 1
    local rc=0
    filechanged "$msg" unlink >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" \
        "cs -msg moving files to cur/ fires one unlink per message and must not wake" || return 1
}

test_idle_wake_does_not_touch_the_attention_flag() {
    "$CS_BIN" -msg receiver "wake up" >/dev/null 2>&1 || return 1
    rm -f "$(RCV_META)/local/attention"
    local msg; msg=$(FIRST_MSG) || return 1
    filechanged "$msg" add >/dev/null 2>&1 || true
    assert_file_not_exists "$(RCV_META)/local/attention" \
        "a watched-file event is not a finished turn: the statusline must not blink for it" || return 1
}

test_stop_wake_blocks_on_unread_mail() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local out; out=$(wake)
    assert_output_contains "$out" '"block"' "unread mail blocks the stop" || return 1
    assert_output_contains "$out" "cs -msg" "the wake names the reader command" || return 1
}

test_stop_wake_fires_once_per_arrival() {
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1 || return 1
    wake >/dev/null
    local out; out=$(wake)
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "the same unread message does not wake a second time" || return 1
}

# A task-kind send also queue-adds, and the queue gate exits before the mail
# wake is ever reached — so the fixture must empty the queue, or the assertion
# passes without the branch under test running at all.
drain_receiver_queue() {
    rm -f "$(RCV_META)/local/queue"/* 2>/dev/null || true
}

test_stop_wake_silent_for_task_kind() {
    "$CS_BIN" -msg receiver -k task "do the thing" >/dev/null 2>&1 || return 1
    drain_receiver_queue
    local out; out=$(wake)
    assert_output_not_contains "$out" "cs task queue" \
        "fixture reaches the mail wake (the queue gate did not take the turn)" || return 1
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "a task-kind message never wakes: the queue already owns it" || return 1
}

test_stop_wake_fires_again_for_a_later_message() {
    "$CS_BIN" -msg receiver "first" >/dev/null 2>&1 || return 1
    wake >/dev/null
    rcv -msg >/dev/null 2>&1 || return 1
    "$CS_BIN" -msg receiver "second" >/dev/null 2>&1 || return 1
    local out; out=$(wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "a message arriving after a read wakes again" || return 1
}

test_stop_wake_not_blocked_by_a_lingering_task() {
    "$CS_BIN" -msg receiver -k task "queued work" >/dev/null 2>&1 || return 1
    drain_receiver_queue
    wake >/dev/null
    "$CS_BIN" -msg receiver "a real question" >/dev/null 2>&1 || return 1
    local out; out=$(wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "an unread task sitting in new/ does not suppress a later text message" || return 1
}

test_stop_wake_records_a_task_as_discharged() {
    "$CS_BIN" -msg receiver -k task "queued work" >/dev/null 2>&1 || return 1
    drain_receiver_queue
    wake >/dev/null
    local woke="$(RCV_META)/local/mail/woke"
    assert_file_exists "$woke" "a task-only arrival still writes the snapshot" || return 1
    local n; n=$(grep -c '[^[:space:]]' "$woke" 2>/dev/null || echo 0)
    assert_eq "1" "$n" "the task filename is recorded as discharged" || return 1
}

test_stop_wake_disabled_records_nothing() {
    "$CS_BIN" -msg receiver "hello there" >/dev/null 2>&1 || return 1
    local out; out=$(CS_NO_MAIL_WAKE=1 wake)
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "CS_NO_MAIL_WAKE silences the wake" || return 1
    assert_file_not_exists "$(RCV_META)/local/mail/woke" \
        "a silenced run discharges nothing, so it records nothing" || return 1
    out=$(wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "the same message still wakes once the silence is lifted" || return 1
}

test_stop_wake_disabled_does_not_strand_text_beside_a_task() {
    "$CS_BIN" -msg receiver -k task "queued work" >/dev/null 2>&1 || return 1
    drain_receiver_queue
    "$CS_BIN" -msg receiver "a real question" >/dev/null 2>&1 || return 1
    CS_NO_MAIL_WAKE=1 wake >/dev/null
    local out; out=$(wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "the task's discharge write must not swallow a silenced text message beside it" || return 1
}

# Drive the UserPromptSubmit hook as the receiver (a human keystroke).
prompt_as_receiver() {
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        echo '{"prompt":"hi"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    )
}

# Drive the UserPromptSubmit hook the way a WAKE does. A wake reaches the model
# as a turn of its own, and that turn runs this hook with no prompt in it — the
# shape every wake-turn trace in the wild has: input, digest, objective, exit,
# never reaching the classifier.
wake_turn_as_receiver() {
    (
        export CLAUDE_SESSION_NAME=receiver
        export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/receiver"
        export CLAUDE_SESSION_META_DIR="$(RCV_META)"
        echo '{"prompt":""}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    )
}

test_wake_turn_does_not_reset_the_ceiling() {
    # The ceiling counts "wakes since the last USER prompt" (session-layout.md).
    # A wake arrives as its own turn, so if that turn clears the budget the count
    # can never exceed one and the ceiling can never stop anything — which is the
    # runaway it exists to stop, between two sessions with nobody at either end.
    "$CS_BIN" -msg receiver "one" >/dev/null 2>&1 || return 1
    CS_MAIL_WAKE_MAX=2 wake >/dev/null
    wake_turn_as_receiver
    "$CS_BIN" -msg receiver "two" >/dev/null 2>&1 || return 1
    CS_MAIL_WAKE_MAX=2 wake >/dev/null
    wake_turn_as_receiver
    "$CS_BIN" -msg receiver "three" >/dev/null 2>&1 || return 1
    local out; out=$(CS_MAIL_WAKE_MAX=2 wake)
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "wake turns must not spend the budget the ceiling counts" || return 1
    # And the documented reset still works: a real keystroke clears it.
    prompt_as_receiver
    out=$(CS_MAIL_WAKE_MAX=2 wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "a human prompt still resets the ceiling" || return 1
}

test_stop_wake_stops_at_the_ceiling() {
    "$CS_BIN" -msg receiver "one" >/dev/null 2>&1 || return 1
    CS_MAIL_WAKE_MAX=2 wake >/dev/null
    "$CS_BIN" -msg receiver "two" >/dev/null 2>&1 || return 1
    CS_MAIL_WAKE_MAX=2 wake >/dev/null
    "$CS_BIN" -msg receiver "three" >/dev/null 2>&1 || return 1
    local out; out=$(CS_MAIL_WAKE_MAX=2 wake)
    assert_output_not_contains "$out" "Unread cross-session mail" \
        "the ceiling stops an unbounded volley" || return 1
    prompt_as_receiver
    out=$(CS_MAIL_WAKE_MAX=2 wake)
    assert_output_contains "$out" "Unread cross-session mail" \
        "a human prompt resets the ceiling" || return 1
}

run_test test_stop_wake_only_the_lead_wakes
run_test test_wake_turn_does_not_reset_the_ceiling
run_test test_stop_wake_stops_at_the_ceiling
run_test test_cwd_change_rearms_the_maildir_watch
run_test test_cwd_change_creates_the_maildir_before_arming
run_test test_cwd_change_never_reaches_the_drain
run_test test_idle_wake_exits_2_with_the_reason_on_stderr
run_test test_idle_wake_accepts_another_spelling_of_the_same_path
run_test test_idle_wake_ignores_files_outside_the_maildir
run_test test_idle_wake_ignores_unlink
run_test test_idle_wake_does_not_touch_the_attention_flag
run_test test_stop_wake_disabled_records_nothing
run_test test_stop_wake_disabled_does_not_strand_text_beside_a_task
run_test test_stop_wake_blocks_on_unread_mail
run_test test_stop_wake_fires_once_per_arrival
run_test test_stop_wake_silent_for_task_kind
run_test test_stop_wake_records_a_task_as_discharged
run_test test_stop_wake_fires_again_for_a_later_message
run_test test_stop_wake_not_blocked_by_a_lingering_task

run_test test_migration_merges_when_new_already_exists
run_test test_migration_retry_after_partial_conversion_delivers_no_duplicates
run_test test_migration_keeps_the_legacy_file_when_a_record_cannot_be_written
run_test test_migration_retry_does_not_resurrect_read_mail
run_test test_migration_quarantines_corrupt_and_converts_null_ts
run_test test_migration_converts_lines_landing_in_migrating_file
run_test test_migration_reads_unterminated_final_line
run_test test_migration_runs_on_worktree_open

report_results
