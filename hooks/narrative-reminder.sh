#!/usr/bin/env bash
# ABOUTME: Stop hook for the narrative reminder, walk-away queue drain, rotation
# ABOUTME: nudge and mail wake; FileChanged wakes when idle, CwdChanged re-arms

set -euo pipefail

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# One pass for every field any path needs. This script serves two events, and
# the FileChanged one fires per watched file, so a fork per field is paid on
# every file change in the session. Stop carries no name on legacy input, so an
# absent value means Stop.
# Unit separator, not tab: tab is IFS whitespace, so bash collapses runs of it
# and an absent field (agent_id is empty on every top-level event) would shift
# every later field one place left.
HOOK_EVENT=Stop; AGENT_ID=""; FC_PATH=""; FC_EVENT=""
IFS=$'\037' read -r HOOK_EVENT AGENT_ID FC_PATH FC_EVENT <<EOF
$(printf '%s' "$INPUT" | jq -r '[.hook_event_name // "Stop", .agent_id // "",
    .file_path // "", .event // ""] | join("\u001f")' 2>/dev/null || printf 'Stop')
EOF
[ -n "$HOOK_EVENT" ] || HOOK_EVENT=Stop

# Triage a watched-file event before anything else runs. A matcher-less
# FileChanged entry is match-all over every watch path in the session — other
# plugins' included — and reading mail fires one unlink per message moved to
# cur/, so the common case here is an event this hook does not own. The shape
# test needs no session resolution, which is what lets it sit above the library
# source; the precise per-session path check still happens below.
if [ "$HOOK_EVENT" = "FileChanged" ]; then
    case "$FC_PATH" in
        */.cs/local/mail/new/*.json) [ "$FC_EVENT" != "unlink" ] || exit 0 ;;
        */.cs/local/rotation-kick/*.kick) [ "$FC_EVENT" != "unlink" ] || exit 0 ;;
        *) exit 0 ;;
    esac
fi

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
if [ -n "$AGENT_ID" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# shellcheck source=cs-resolve.sh
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
# errexit is suspended across the source, not just around it: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) fails INSIDE the sourced file, where set -e fires
# before any outer || can catch it. Exit 2 out of a PreToolUse hook is
# Claude Code's blocking code. Whatever the source defined before failing
# still stands; the check below decides whether it is usable.
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
set +e
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
if ! command -v _cs_terminate_jsonl >/dev/null 2>&1; then
    _cs_terminate_jsonl() {
        [ -s "$1" ] || return 0
        [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
        printf '\n' >> "$1" 2>/dev/null || true
    }
fi
# Only run in cs sessions
if ! cs_resolve_session ""; then
    echo '{"decision": "approve"}'
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# --- Mail wake, shared by both events -----------------------------------------
# Unread cross-session mail takes a turn, so an agent-to-agent exchange advances
# without waiting for a keystroke. Stop reaches a session that has just finished
# work; FileChanged reaches one already parked at the prompt, because its
# watcher lives on Claude Code's own event loop and fires independently of turn
# state. Both share this scan, the snapshot, the gate rule and the ceiling —
# they differ only in how they deliver.
MAILDIR="$META_DIR/local/mail"
MAIL_WOKE="$MAILDIR/woke"
MAIL_UNREAD=0
MAIL_FRESH=0
MAIL_DISCHARGED=0
MAIL_NAMES=""
MAIL_FROM=""
# Initialised here rather than inside the silencers: an unset counter would be
# seeded by any same-named variable inherited from the environment.
MAIL_WAKES=0
NL='
'

_num_or() {  # value, default -> prints value if a plain integer, else default
    case "${1:-}" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac
}

# The queue is a directory of one file per task (written via tmp+rename by
# cs -queue add / task-kind mail), so the drain can never read a torn entry.
_qlen() {  # queue dir
    local f n=0
    for f in "$1"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    echo "$n"
}

# Only the launched conversation wakes, by the same two shapes session-start.sh
# calls the lead: claude carrying cs's pid from the exec arm, or claude as cs's
# child from the resume arm. A tmux-backed teammate is a full claude with its
# own top-level Stop — the agent_id guard above catches in-process subagents,
# not tmux ones — and cs is neither its process nor its parent, so CS_LEAD_PID
# is absent from its environment. Ungated, one arrival wakes the lead and every
# idle teammate, each racing to cs -msg where the first mv wins, so a teammate
# can consume mail the lead then never sees. A session opened straight from a
# front end is not a cs launch either and likewise does not wake; it is attended
# by definition, and the prompt digest carries its mail.
# Memoized: the drain gate and the mail wake both ask on one Stop, and the
# resume-arm answer costs a ps fork.
_IS_LEAD=""
_mail_is_lead() {
    if [ -z "$_IS_LEAD" ]; then
        _IS_LEAD=0
        if [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ]; then
            if [ "$CLAUDE_PID" = "$CS_LEAD_PID" ]; then
                _IS_LEAD=1
            else
                local parent
                parent=$(ps -o ppid= -p "$CLAUDE_PID" 2>/dev/null | tr -d '[:space:]' || true)
                [ -n "$parent" ] && [ "$parent" = "$CS_LEAD_PID" ] && _IS_LEAD=1
            fi
        fi
    fi
    [ "$_IS_LEAD" = 1 ]
}

# Populate the MAIL_* globals. The re-wake guard is a snapshot of the filenames
# already discharged, not a count and not a high-water mark: unread drops to
# zero whenever cs -msg moves files to cur/, and filenames are not ordered by
# arrival (same-second order is by unpadded pid). Set membership needs neither
# property.
_mail_scan() {
    local f name kind from woke=""
    # Read the snapshot ONCE and match in-shell. A fork per unread message is
    # paid on every turn end for as long as the mail stays unread, and the idle
    # wake re-scans all of new/ per arrival — so a burst of N deliveries would
    # cost N(N+1)/2 forks. The ceiling makes that state ordinary rather than
    # rare: past it mail piles up in new/ while turns keep ending.
    # || true: an unreadable snapshot must degrade to "nothing discharged"
    # (which over-wakes) rather than abort the hook under errexit.
    [ ! -f "$MAIL_WOKE" ] || woke=$(<"$MAIL_WOKE") || woke=""
    for f in "$MAILDIR"/new/*.json; do
        [ -f "$f" ] || continue
        MAIL_UNREAD=$((MAIL_UNREAD + 1))
        name=${f##*/}
        MAIL_NAMES="$MAIL_NAMES$name
"
        # Newlines on both sides so one name cannot match inside another.
        case "$NL$woke$NL" in
            *"$NL$name$NL"*) continue ;;
        esac
        # A task is already an imperative in the queue, so waking on it would
        # race the drain — but it is discharged all the same, and recording it
        # is what stops every later turn from re-reading it. An unreadable or
        # forged document reads as text: over-waking is the safe direction.
        # One jq per document, reading both fields it needs. The sender rides
        # along free: a count says work arrived but not whose, and the recipient
        # would otherwise spend a turn on `cs -msg` just to learn whether it can
        # wait. Truncated and stripped of separators inside jq so a forged or
        # hand-written document cannot smuggle a newline or a comma into the
        # rendered line, and coerced to a string so a numeric field cannot error
        # the whole read and take .kind down with it.
        IFS=$'\037' read -r kind from <<EOF
$(jq -r '[(.kind // "text"),
          (((if (.from // "") == "" then .actor else .from end) // "") | if type == "string" then . else tostring end
             | gsub("[\n\r,]"; " "))[0:40]] | join("")' "$f" 2>/dev/null || printf 'text')
EOF
        [ -n "$kind" ] || kind=text
        # Distinct senders only: two messages from one session is one name, and
        # repeating it answers nothing the count has not already said.
        case "$from" in
            "") ;;
            *) case "$NL$MAIL_FROM$NL" in
                   *"$NL$from$NL"*) ;;
                   *) MAIL_FROM="${MAIL_FROM:+$MAIL_FROM$NL}$from" ;;
               esac ;;
        esac
        if [ "$kind" = "task" ]; then
            MAIL_DISCHARGED=1
        else
            MAIL_FRESH=1
        fi
    done
}

# Render the distinct senders as a clause, or nothing when no document named
# one. Kept separate from the scan so both wakes compose the same line.
#
# "new from", not "from": the count beside this clause covers every unread
# document, while these names come only from the ones the wake is announcing —
# the discharge skip in _mail_scan runs ahead of the read that would learn a
# sender. Naming the narrower set is the deliberate half of that trade. Naming
# every unread sender instead would cost one jq per unread document on every
# turn end, which is the expense _mail_scan is built to avoid, and which the
# wake ceiling makes an ordinary state rather than a rare one.
_mail_from_clause() {
    [ -n "${MAIL_FROM:-}" ] || { printf ''; return 0; }
    printf ', new from %s' "$(printf '%s' "$MAIL_FROM" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
}

# Record the snapshot as the whole of new/, which is sound only when everything
# in it has been discharged — every caller checks that before calling. The tmp
# name carries the pid because both wakes write this file and the idle one
# overlaps itself: two writers sharing one tmp name splice each other, and the
# rename then publishes the splice.
_mail_record() {
    printf '%s' "$MAIL_NAMES" > "$MAIL_WOKE.tmp.$$" 2>/dev/null \
        && mv "$MAIL_WOKE.tmp.$$" "$MAIL_WOKE" 2>/dev/null || true
}

# Apply the two silencers. A silenced run discharges nothing, so it records
# nothing: recording would mark the arrival considered for every reader of the
# snapshot, not just the wake that was silenced, and the message would then wait
# for a keystroke — the gap this whole change exists to close.
#
# Nothing else bounds a volley: the drain's breakers gate drains, and Claude
# Code's consecutive-Stop-block cap does not count a turn a wake itself started.
# Past the ceiling the digest carries the backlog until a prompt clears the
# counter (scope-prompt.sh).
_mail_apply_silencers() {
    # Nothing below is observable when there is nothing to silence, and this is
    # the majority of turn ends. MAIL_WAKES is only ever read by the counter,
    # which runs only when a wake is about to be delivered.
    [ "$MAIL_FRESH" = 1 ] || return 0
    [ -z "${CS_NO_MAIL_WAKE:-}" ] || { MAIL_FRESH=0; return 0; }
    local max seen=""
    max=$(_num_or "${CS_MAIL_WAKE_MAX:-}" 5)
    [ ! -f "$MAILDIR/wakes" ] || seen=$(<"$MAILDIR/wakes") || seen=""
    seen=$(_num_or "${seen//[[:space:]]/}" 0)
    if [ "$seen" -ge "$max" ]; then
        MAIL_FRESH=0
    fi
    MAIL_WAKES="$seen"
}

_mail_count_wake() {
    printf '%s\n' "$((MAIL_WAKES + 1))" > "$MAILDIR/wakes.tmp.$$" 2>/dev/null \
        && mv "$MAILDIR/wakes.tmp.$$" "$MAILDIR/wakes" 2>/dev/null || true
}

MAIL_REASON_TAIL="Run cs -msg to read it. Reply only if the message needs an answer; never reply merely to acknowledge."

# --- CwdChanged: re-arm the maildir watch -------------------------------------
# A cwd change REPLACES the session's dynamic watch list with whatever the
# CwdChanged hooks collectively return — not merges — so a session that answers
# nothing loses the maildir watch for the rest of its life. Nothing later can
# restore it: watchPaths rides on only three events, and of those SessionStart
# has already happened and FileChanged cannot fire once the watch it depends on
# is gone. Worse, the wipe only runs at all because this session registers a
# FileChanged hook, so the mailbox arms the event that disarms it.
#
# Answering with the maildir turns that event into the repair. The directory
# must exist before the path is handed over: a watch given a path missing two
# levels never fires again for that process's lifetime.
#
# This branch exits before the drain below on purpose. An unhandled event falls
# through into the walk-away run and pops a queued task, so a directory change
# would silently consume work.
if [ "$HOOK_EVENT" = "CwdChanged" ]; then
    _mail_is_lead || exit 0
    mkdir -p "$MAILDIR/new" 2>/dev/null || exit 0
    jq -nc --arg p "$MAILDIR/new" \
        '{hookSpecificOutput: {hookEventName: "CwdChanged", watchPaths: [$p]}}' \
        2>/dev/null || true
    exit 0
fi

# --- FileChanged: the idle wake -----------------------------------------------
# Delivered by writing the reason to stderr and exiting 2 (asyncRewake), which
# Claude Code wraps in a system-reminder and enqueues — so it reaches a session
# with nobody at the keyboard, as data the model trusts rather than as fabricated
# input. This branch sits above the attention flag and the iTerm2 bounce on
# purpose: a watched file changing is not a finished turn, and cs -msg moving
# mail to cur/ fires one event per message.
#
# Every command below is guarded, because under errexit an incidental failure
# exiting 2 — grep and jq both use 2 for errors — would deliver a phantom wake
# carrying whatever noise reached stderr. Exit 2 must be reachable only on
# purpose.
# --- FileChanged: the rotation kick -------------------------------------------
# A /clear on an armed handoff consumes it and injects the preamble, but a hook
# cannot start a turn — so session-start.sh arms a watch on the kick directory
# and a detached child drops a file into it a second later. That event lands
# here, and exiting 2 wakes the model with nobody at the keyboard. Measured on
# 2.1.252 against a real /clear in a zero-turn conversation.
#
# Deliberately NOT on the mail budget. CS_MAIL_WAKE_MAX bounds a volley of
# arrivals nobody asked for; a rotation kick is one file this session wrote for
# itself, exactly once per /clear, and spending mail's allowance on it would let
# a rotation silence the next five real messages.
#
# Sits above the mail branch: the two shapes are disjoint, but the mail branch's
# path check would reject a kick and exit 0, swallowing it.
#
# Every command is guarded, for the reason the mail branch documents: under
# errexit an incidental failure exiting 2 delivers a phantom wake carrying
# whatever noise reached stderr. Exit 2 must be reachable only on purpose.
if [ "$HOOK_EVENT" = "FileChanged" ] && [ "${FC_PATH%/*.kick}" != "$FC_PATH" ]; then
    _kick_dir="$META_DIR/local/rotation-kick"
    _kick_name="${FC_PATH##*/}"
    # The path shape is not proof the document exists, and the watcher reports
    # the platform's own spelling — ask whether the file is in THIS session's
    # kick directory rather than whether the two strings agree.
    [ -f "$_kick_dir/$_kick_name" ] || exit 0
    _mail_is_lead || exit 0
    # One kick, one wake. Claude Code fires FileChanged on unlink as well as
    # add, so clearing the kick would re-enter this branch; the marker makes the
    # second event a no-op even before the unlink triage above catches it, and
    # covers a re-add of the same name too.
    [ ! -f "$_kick_dir/delivered" ] || exit 0
    # No queue gate here, deliberately — the opposite of the mail wake.
    #
    # Nothing resets queue.state on a /clear: only bin/cs writes it, so a drain
    # that was armed or interrupted beforehand leaves a STALE armed/draining
    # state that survives into the fresh conversation. And two seconds after a
    # /clear no drain turn can be in flight, so the reason the mail wake
    # yields — a rewake between drain turns shifts the pop one turn late — does
    # not apply.
    #
    # Yielding cost more than it saved. This add event is the only one this kick
    # will ever produce and there is no Stop-path retry to recover it (the mail
    # wake rescans at every turn end; the kick has no such counterpart), so the
    # rotation was stranded under a notice promising it would continue on its
    # own. The queue was stranded with it: the drain is Stop-driven, so no wake
    # means no turn, and no turn means no Stop. Waking runs the rotation turn,
    # whose Stop then resumes the drain normally.
    # Compose before recording, as the mail path does: a kill between the two
    # costs a duplicate wake, while recording first costs a silent strand — and
    # a strand is unrecoverable for an idle session, which submits no prompt and
    # ends no turn.
    #
    # The wake arrives as a system-reminder, not a user message, so the reason
    # has to carry the instruction the user's "go" would otherwise have carried.
    # It restates rather than referring back: the preamble is in context, but a
    # reason that says only "the rotation is loaded" leaves the model to guess
    # whether a wake is permission to act.
    # The yield clause is not decoration. The notice invites the user to type
    # instead, and the kick is written either way, so a wake can arrive ENQUEUED
    # behind a message they already sent — and the preamble's
    # content-takes-precedence rule covers only a FIRST message, not a
    # system-reminder landing after one. Unconditional wording here would let
    # the auto-start override the person it just told to take over.
    printf '%s\n' "The rotation is loaded and nothing has run yet. First reconcile your native task list, which carried over from the previous conversation, with the handoff, then execute the handoff's next-step section now and report what you did, without re-summarising it or asking which part to start with. If the user has already sent a message of their own, theirs wins — do what they asked and treat this wake as spent. Ask first only where you normally would: the handoff is missing, unreadable, or genuinely ambiguous, or its next step is destructive or irreversible." >&2
    : > "$_kick_dir/delivered" 2>/dev/null || true
    exit 2
fi

if [ "$HOOK_EVENT" = "FileChanged" ]; then
    # Shape and unlink were triaged above, before the library source; this is
    # the precise check that the file belongs to THIS session's mailbox rather
    # than to another session that happens to share the layout.
    # The watcher reports the path in the platform's own spelling, which need
    # not be the one MAILDIR was built from — /private/var beside /var, say.
    # Ask whether the document is in
    # THIS session's new/ rather than whether the two strings agree, so a real
    # arrival is not dropped for being described differently. Still precise:
    # the name must be a .json under a new/, and it must be one of ours.
    _fc_name=""
    case "$FC_PATH" in
        */new/*.json) _fc_name="${FC_PATH##*/}" ;;
        *) exit 0 ;;
    esac
    [ -n "$_fc_name" ] && [ -f "$MAILDIR/new/$_fc_name" ] || exit 0
    _mail_is_lead || exit 0
    # The Stop path gets the queue rule free from its position below the drain,
    # which exits in every armed or draining branch. This one has to ask: a
    # rewake at priority "next" lands between drain turns, shifting the pop one
    # turn late and mis-attributing a tool failure to the current task's
    # breaker. An empty queue is never gating, whatever queue.state records.
    if [ "$(_qlen "$META_DIR/local/queue")" -gt 0 ]; then
        _fc_qstate=$(cat "$META_DIR/local/queue.state" 2>/dev/null | tr -d '[:space:]' || true)
        case "$_fc_qstate" in armed|draining) exit 0 ;; esac
    fi
    _mail_scan
    if [ "$MAIL_FRESH" = 0 ] && [ "$MAIL_DISCHARGED" = 1 ]; then
        _mail_record
    fi
    _mail_apply_silencers
    [ "$MAIL_FRESH" = 1 ] || exit 0
    # Compose before recording, as on the Stop path: a kill between the two
    # costs a duplicate wake, while recording first costs a silent strand — and
    # a strand is unrecoverable for an idle session, which submits no prompt and
    # ends no turn. Only the exit itself has to come last.
    printf '%s\n' "Unread cross-session mail ($MAIL_UNREAD)$(_mail_from_clause). $MAIL_REASON_TAIL" >&2
    _mail_count_wake
    _mail_record
    exit 2
fi

# Claude just finished a turn: raise the machine-local attention flag the
# statusline blinks until the user next interacts. Cleared by scope-prompt.sh
# on the next prompt and by session-start.sh at launch. Lives in .cs/local/
# (per-machine state, never git-synced). Raised before the cooldown gates so
# every turn end signals, not just the ones that remind.
mkdir -p "$META_DIR/local" 2>/dev/null || true
touch "$META_DIR/local/attention" 2>/dev/null || true

# iTerm2: bounce the dock while attention is raised, so a finished turn
# reaches the user in another app. The it2 utilities live in ~/.iterm2 (shell
# aliases, not on PATH); escapes go to the tty directly because hook stdout is
# captured by Claude Code. CS_NO_ITERM2=1 disables; CS_IT2_DIR/CS_IT2_TTY are
# test seams. Silent everywhere it cannot apply.
if [ -z "${CS_NO_ITERM2:-}" ] && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    _it2="${CS_IT2_DIR:-$HOME/.iterm2}/it2attention"
    { [ -x "$_it2" ] && "$_it2" start > "${CS_IT2_TTY:-/dev/tty}"; } 2>/dev/null || true
fi

# --- Task queue drain (walk-away mode) ---------------------------------------
# Hands the agent its next queued task when armed; asks once when idle. Wins
# over the narrative nag (returns early). Queue text is arbitrary -> jq emit.
QDIR="$META_DIR/local"
QUEUE="$QDIR/queue"
QSTATE_FILE="$QDIR/queue.state"

# Lexically first task file (the glob is sorted); rc 1 when none.
_qfirst() {  # queue dir
    local f
    for f in "$1"/*; do
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
        return 0
    done
    return 1
}

# Count of completed tasks in the line-per-task done log.
_qdone_len() {  # done file
    if [ -f "$1" ]; then
        grep -c '[^[:space:]]' "$1" 2>/dev/null || true
    else
        echo 0
    fi
}

# Append one event to the notification inbox. Task text is arbitrary -> jq.
# Repair an unterminated tail first: a drain killed mid-append leaves the last
# line without its newline, and appending onto it joins two records into one
# line that the readers' `fromjson? // empty` drops whole — costing the torn
# record and this one. Best-effort: inbox failure must never break the drain.
_inbox_append() {  # jq --arg/--argjson pairs..., then the jq object program
    _cs_terminate_jsonl "$QDIR/notifications.jsonl" 2>/dev/null || true
    jq -nc "$@" >> "$QDIR/notifications.jsonl" 2>/dev/null || true
}

# Mail a spawned worker's spawner (recorded in spawned-by by the launch).
# Best-effort: a failed send never breaks the drain. Callers decide whether
# spawned-by survives (kept on breaker trips, deleted after the final drain).
_notify_spawner() {  # message
    [ -s "$QDIR/spawned-by" ] || return 0
    local spawner=""
    IFS= read -r spawner < "$QDIR/spawned-by" || true
    if [ -n "$spawner" ] && command -v cs >/dev/null 2>&1; then
        cs -msg "$spawner" -k notify "$1" >/dev/null 2>&1 || true
    fi
}

# Evaluate the circuit breakers. Prints "reason reading limit" and returns 0
# when one trips; returns 1 otherwise. Order: failures, context, five_hour.
_breaker_check() {
    local max_fail max_ctx max_5h fails ctx fiveh stamped now
    max_fail=$(_num_or "${CS_QUEUE_MAX_FAILURES:-}" 5)
    max_ctx=$(_num_or "${CS_QUEUE_MAX_CTX:-}" 85)
    max_5h=$(_num_or "${CS_QUEUE_MAX_5H:-}" 85)

    fails=$(_num_or "$(cat "$QDIR/failures" 2>/dev/null | tr -d '[:space:]')" 0)
    if [ "$fails" -ge "$max_fail" ]; then
        echo "failures $fails $max_fail"
        return 0
    fi

    ctx=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
    case "$ctx" in
        ''|*[!0-9]*) : ;;
        *) if [ "$ctx" -ge "$max_ctx" ]; then
               echo "context $ctx $max_ctx"
               return 0
           fi ;;
    esac

    if [ -f "$QDIR/limits" ]; then
        fiveh=$(awk -F': ' '/^five_hour_used_pct:/ {print $2; exit}' "$QDIR/limits" 2>/dev/null | tr -d '[:space:]')
        stamped=$(awk -F': ' '/^stamped_at:/ {print $2; exit}' "$QDIR/limits" 2>/dev/null | tr -d '[:space:]')
        case "$fiveh" in ''|*[!0-9]*) fiveh="";; esac
        case "$stamped" in ''|*[!0-9]*) stamped="";; esac
        if [ -n "$fiveh" ] && [ -n "$stamped" ]; then
            now=$(date +%s)
            if [ $((now - stamped)) -le 1800 ] && [ "$fiveh" -ge "$max_5h" ]; then
                echo "five_hour $fiveh $max_5h"
                return 0
            fi
        fi
    fi
    return 1
}

# Only the lead's Stop advances or gates the queue. A tmux teammate shares the
# session directory and fires its own top-level Stop, so ungated its every
# idle turn pops a task: an eight-task queue reads "all tasks complete" after
# eight reviewer turns with nothing done. A teammate falls through to the
# narrative reminder like any other Stop.
QLEN=$(_qlen "$QUEUE")
if [ "$QLEN" -gt 0 ] && _mail_is_lead; then
    QSTATE=$(cat "$QSTATE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$QSTATE" ] || QSTATE="idle"

    # A walk-away run has nobody watching, so the handed task is the only
    # scope guidance the agent gets: it says what the task asks for and
    # nothing about what it does not.
    SCOPE="Scope: implement every behavior the task asks for, completely, and nothing beyond it. A pre-existing bug, a performance concern or behavior the task does not mention stays untouched unless the task cannot work without it; report it as a follow-up in your narrative, which outlives this run's compactions. Where the task is ambiguous, implement the reading its wording and the surrounding code most directly support, state that assumption in the narrative as well, and do not build for the other readings."

    if [ "$QSTATE" = "armed" ]; then
        TASK=""
        _first=$(_qfirst "$QUEUE") || _first=""
        [ -n "$_first" ] && TASK=$(cat "$_first" 2>/dev/null || true)
        printf 'draining\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        rm -f "$QDIR/failures"
        _inbox_append --arg ts "$(date +%s)" --arg q "$QLEN" \
            '{ts: ($ts|tonumber), event: "drain_started", queued: ($q|tonumber)}'
        REASON="cs task queue: starting a walk-away run. Work through the queued tasks one at a time; I will hand you the next after each finishes. Mirror the whole queue into your native task list now: run \`cs -queue list\` to see every queued item (this message shows only the first), create one task each, and mark each completed as you finish it. When a task is done, mark it completed and simply end your turn; the next task is delivered automatically on the next turn. Do not read or edit the queue yourself.

First task: $TASK

$SCOPE"
        jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
        exit 0
    fi

    if [ "$QSTATE" = "draining" ]; then
        # Pop = mv the lexically first entry aside BEFORE reading it: a second
        # drain racing this one loses the rename and disarms instead of
        # double-running the task.
        _first=$(_qfirst "$QUEUE") || _first=""
        POPPED="$QDIR/queue.popping.$$"
        if [ -n "$_first" ] && mv "$_first" "$POPPED" 2>/dev/null; then
            DONE_TASK=$(cat "$POPPED" 2>/dev/null || true)
            rm -f "$POPPED"
            printf '%s\n' "$DONE_TASK" >> "$QDIR/queue.done"
            _inbox_append --arg ts "$(date +%s)" --arg task "$DONE_TASK" \
                '{ts: ($ts|tonumber), event: "task_done", task: $task}'
            NEWLEN=$(_qlen "$QUEUE")
            if [ "$NEWLEN" -le 0 ]; then
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                DONE_COUNT=$(_qdone_len "$QDIR/queue.done")
                _inbox_append --arg ts "$(date +%s)" --arg d "$DONE_COUNT" \
                    '{ts: ($ts|tonumber), event: "drain_finished", done: ($d|tonumber)}'
                # Spawned worker: tell the spawner its batch is done. One-shot
                # (spawned-by is deleted) so later unrelated drains stay silent.
                _notify_spawner "queue drained: $DONE_COUNT task(s) done"
                rm -f "$QDIR/spawned-by"
                rm -f "$QDIR/failures"
                jq -nc '{decision:"block", reason:"cs task queue: all tasks complete. Mark the final native task completed, then give the user a brief summary of what the walk-away run accomplished and anything that needs their attention."}'
                exit 0
            fi
            if TRIP=$(_breaker_check); then
                set -- $TRIP
                REASON_KIND="$1"; READING="$2"; LIMIT="$3"
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                _inbox_append --arg ts "$(date +%s)" --arg r "$REASON_KIND" \
                    --arg v "$READING" --arg l "$LIMIT" --arg n "$NEWLEN" \
                    '{ts: ($ts|tonumber), event: "breaker_tripped", reason: $r, reading: ($v|tonumber), limit: ($l|tonumber), remaining: ($n|tonumber)}'
                # Spawned worker: surface the trip to the spawner but KEEP
                # spawned-by, so the eventual real drain still reports.
                _notify_spawner "breaker tripped: $REASON_KIND ($READING >= $LIMIT), $NEWLEN task(s) remaining"
                rm -f "$QDIR/failures"
                REASON="cs task queue: circuit breaker tripped — $REASON_KIND at $READING (threshold $LIMIT). The queue is parked with $NEWLEN task(s) remaining; nothing was lost. Summarize the walk-away run so far and anything that needs the user's attention. They can re-arm with: cs -queue start."
                jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
                exit 0
            fi
            rm -f "$QDIR/failures"
            NEXT=""
            _first=$(_qfirst "$QUEUE") || _first=""
            [ -n "$_first" ] && NEXT=$(cat "$_first" 2>/dev/null || true)
            REASON="cs task queue: next task ($NEWLEN remaining). Mark the previous native task completed and this one in-progress (create it if missing), then do it.

Task: $NEXT

$SCOPE"
            jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
            exit 0
        else
            # pop failed: disarm rather than re-inject the same task (fail-safe)
            printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        fi
    fi

    if [ "$QSTATE" = "idle" ]; then
        DECLINED="$QDIR/queue.declined"
        GATE=1
        if [ -f "$DECLINED" ]; then
            DECL_AT=$(cat "$DECLINED" 2>/dev/null | tr -d '[:space:]')
            NOW=$(date +%s)
            if [ -n "$DECL_AT" ] && [ $((NOW - DECL_AT)) -lt 600 ]; then
                GATE=0            # within cooldown: fall through to narrative
            else
                rm -f "$DECLINED"
            fi
        fi
        if [ "$GATE" = "1" ]; then
            CTX=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
            CTX_LINE=""
            COMPACT=""
            case "$CTX" in
                ''|*[!0-9]*) : ;;
                *) CTX_LINE=" Context is at ${CTX}%."
                   [ "$CTX" -ge 60 ] && COMPACT=" Context is heavy: offer a third option 'Compact first'. If chosen, run no queue command and tell the user to run /compact; you will be asked again afterward." ;;
            esac
            REASON="cs task queue: $QLEN task(s) are queued for a walk-away run.$CTX_LINE$COMPACT Use AskUserQuestion to ask whether to work through them now (options: Start / Not yet). On Start, run: cs -queue start (then stop; I will hand you each task). On Not yet, run: cs -queue defer."
            jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
            exit 0
        fi
    fi
fi
# (falls through to the narrative reminder below when not gating/draining)

# --- Mail wake (Stop) ---------------------------------------------------------
# The turn-end half. Reached only when the queue is not active: every armed or
# draining branch above exits, so an empty queue never gates here whatever
# queue.state records — the rule the FileChanged branch has to ask for outright.
# A non-lead leaves the flags clear, so it neither wakes nor records: the lead's
# wake for the same arrival has to survive a teammate ending its turn first.
if _mail_is_lead; then
    _mail_scan
    if [ "$MAIL_FRESH" = 0 ] && [ "$MAIL_DISCHARGED" = 1 ]; then
        _mail_record
    fi
fi
# The silencers apply after the discharge write above, not before: the snapshot
# is recorded as the whole of new/, which is sound only when everything in it
# has been discharged. A silenced text message sitting beside a fresh task has
# not been, so the live MAIL_FRESH must still suppress that write.
_mail_apply_silencers
if [ "$MAIL_FRESH" = 1 ]; then
    jq -nc --arg r "Unread cross-session mail ($MAIL_UNREAD)$(_mail_from_clause). $MAIL_REASON_TAIL" \
        '{decision: "block", reason: $r}'
    # Emit first, record second: a kill in between costs one duplicate wake,
    # while the reverse costs a silent strand — unrecoverable for an idle
    # session, which submits no prompt and ends no turn.
    _mail_count_wake
    _mail_record
    exit 0
fi

# --- Rotation nudge -----------------------------------------------------------
# One-time suggestion to rotate when context runs hot. Delivered as a block
# (the only Stop-hook surface Claude sees); an armed or draining queue never
# reaches here (its branches exit above), so the drain's context breaker owns
# hot-context handling during walk-away runs. Cursor: the conversation UUID
# last nudged, machine-local.
NUDGE_CTX=$(_num_or "${CS_ROTATE_NUDGE_CTX:-}" 80)
NUDGE_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
NUDGE_PCT=$(cat "$QDIR/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
case "$NUDGE_PCT" in ''|*[!0-9]*) NUDGE_PCT="";; esac
# The file holds the LEAD's reading only: the status line writes it for the
# launched conversation alone. A teammate's Stop acting on it announces
# someone else's context as its own, so for any other claude both tiers
# below see no reading at all.
_mail_is_lead || NUDGE_PCT=""
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] && [ "$NUDGE_PCT" -ge "$NUDGE_CTX" ]; then
    # Append-only list of nudged conversations: a tmux teammate shares this
    # directory and runs the same Stop, so a single-slot cursor let each
    # teammate's stop cancel the lead's notice and re-arm it every turn.
    if ! grep -qx "$NUDGE_UUID" "$QDIR/rotate-nudged" 2>/dev/null; then
        printf '%s\n' "$NUDGE_UUID" >> "$QDIR/rotate-nudged"
        REASON="Context is at ${NUDGE_PCT}% — consider rotating this conversation. Invoke the rotate skill to distill a handoff into .cs/handoffs/ and arm it; the user then runs /clear to continue in a fresh conversation, without leaving Claude Code. One-time notice for this conversation; if now is a bad time, simply continue."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi

# --- Context warning ----------------------------------------------------------
# One-time heads-up when context crosses the wind-down band [warn, nudge).
# At or above the nudge threshold the rotation nudge above owns the turn;
# this tier never fires there. Cursor: append-only list of warned UUIDs.
WARN_CTX=$(_num_or "${CS_CTX_WARN_CTX:-}" 60)
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] \
    && [ "$NUDGE_PCT" -ge "$WARN_CTX" ] && [ "$NUDGE_PCT" -lt "$NUDGE_CTX" ]; then
    if ! grep -qx "$NUDGE_UUID" "$QDIR/ctx-warned" 2>/dev/null; then
        printf '%s\n' "$NUDGE_UUID" >> "$QDIR/ctx-warned"
        REASON="Context is at ${NUDGE_PCT}% — past the comfortable-headroom mark. Briefly let the user know so they can steer toward a natural stopping point or plan a rotation; the rotate nudge follows at 80%. One-time notice for this conversation; no action needed now."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi

COOLDOWN_FILE="$META_DIR/.narrative-reminder-cooldown"
COOLDOWN_SECONDS=300  # 5 minutes

CURRENT_TIME=$(date +%s)

# Cooldown: don't nag if we reminded recently
if [ -f "$COOLDOWN_FILE" ]; then
    LAST_REMINDER=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    ELAPSED=$((CURRENT_TIME - LAST_REMINDER))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        echo '{"decision": "approve"}'
        exit 0
    fi
fi

# Per-actor narratives: track the most recently modified narrative.*.md, and
# note any that has outgrown its byte budget. The same stat pass serves both.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
# KEEP IN SYNC with CS_NARRATIVE_MAX_DEFAULT in lib/51-narrative.sh — hooks
# cannot source lib/, so the default is duplicated here.
NARRATIVE_MAX=$(_num_or "${CS_NARRATIVE_MAX_BYTES:-}" 524288)
NARRATIVE_OVER=""
for _nf in "$META_DIR"/memory/narrative*.md; do
    [ -f "$_nf" ] || continue
    if [[ "$OSTYPE" == "darwin"* ]]; then
        _m=$(stat -f %m "$_nf" 2>/dev/null || echo 0)
    else
        _m=$(stat -c %Y "$_nf" 2>/dev/null || echo 0)
    fi
    if [ "$_m" -ge "$NARRATIVE_MTIME" ]; then
        NARRATIVE_MTIME="$_m"
        NARRATIVE_FILE="$_nf"
    fi
    _sz=$(wc -c < "$_nf" 2>/dev/null | tr -d ' ' || echo 0)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt "$NARRATIVE_MAX" ]; then
        NARRATIVE_OVER="${NARRATIVE_OVER} $(basename "$_nf") is $((_sz / 1024)) KB, over the $((NARRATIVE_MAX / 1024)) KB budget — if it is yours, run \`cs -narrative rotate\` before appending."
    fi
done

# Nothing to nag about until a narrative file exists
if [ -z "$NARRATIVE_FILE" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Recently updated — no reminder needed
NARRATIVE_AGE=$((CURRENT_TIME - NARRATIVE_MTIME))
if [ "$NARRATIVE_AGE" -lt "$COOLDOWN_SECONDS" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# The council advisor nudge rides the narrative reminder rather than taking its
# own Stop entry: the Stop hook has one emit slot, so a second registration
# would compete with this one instead of composing with it.
#
# It suggests and never sends. A digest of the conversation goes to third-party
# providers, and nothing a hook can read tells it whose words it holds — inside
# a subagent the ambient session id names the parent. The consent belongs to a
# turn that can ask a human, so the nudge asks the model to ask.
ADVISOR_NUDGE=""
# .cs/local/, not the session root: this is per-machine state, and every
# session already gitignores that directory. A stamp at the root would ride
# into a git-synced session and conflict between machines.
ADVISOR_COOLDOWN_FILE="$META_DIR/local/.advisor-nudge-cooldown"
ADVISOR_COOLDOWN_SECONDS=1800  # 30 minutes: a standing reminder, not a nag

_council_is_installed() {
    local record path
    # HOME can be unset, and a bare expansion under `set -u` aborts the hook
    # before it emits, losing the reminder entirely.
    record="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}/plugins/installed_plugins.json"
    [ -r "$record" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # Every entry under any marketplace, not just [0] of the hex one: a plugin
    # carries one record per scope in no guaranteed order, and the docs promise
    # "when the plugin is present" rather than "when it came from one source".
    # installPath is read rather than computed — a computed path goes stale on
    # the next update.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        # The record outlives an uninstall, so the command file decides, not
        # the record: naming a command the user cannot run is worse than silence.
        [ -f "$path/commands/advise.md" ] && return 0
    done <<EOF
$(jq -r '(.plugins // {}) | to_entries[]
         | select(.key | startswith("claude-council@"))
         | .value[]?.installPath // empty' "$record" 2>/dev/null | tr -d '\r')
EOF
    return 1
}

# Lead only. A tmux teammate is a full claude in the same directory with its
# own Stop, and the cooldown is one stamp for the session: an ungated nudge
# lets a teammate consume the lead's slot, and in a walk-away run the lead can
# stop seeing the suggestion altogether.
if _mail_is_lead && _council_is_installed; then
    _adv_last=0
    if [ -f "$ADVISOR_COOLDOWN_FILE" ]; then
        _adv_last=$(_num_or "$(cat "$ADVISOR_COOLDOWN_FILE" 2>/dev/null | tr -d '[:space:]')" 0)
        _adv_last=$((10#$_adv_last))
    fi
    if [ "$((CURRENT_TIME - _adv_last))" -ge "$ADVISOR_COOLDOWN_SECONDS" ]; then
        echo "$CURRENT_TIME" > "$ADVISOR_COOLDOWN_FILE" 2>/dev/null || true
        ADVISOR_NUDGE=" Standing note: at a real decision point — about to commit to an approach, stuck after repeated attempts, or about to call the work done — \`/claude-council:advise\` puts this conversation to external models for a second opinion. You judge whether the moment qualifies; most turns do not. It sends a digest of the conversation to third-party providers, so ask the user before running it and show them what would go."
    fi
fi

# Update cooldown marker and remind
echo "$CURRENT_TIME" > "$COOLDOWN_FILE"

REASON="Narrative check. Update only your own narrative (run \`cs -whoami\` if unsure which actor you are; never edit a teammate's narrative). Newest on disk is $NARRATIVE_FILE. (1) If recent work disproved or superseded one of your entries, append a dated correction that names it — never rewrite or delete earlier sections. (2) Append any new findings as plain dated notes. If nothing needs changing, say so in one line and stop.${NARRATIVE_OVER}${ADVISOR_NUDGE}"

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'

exit 0
