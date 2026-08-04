#!/usr/bin/env bash
# ABOUTME: Stop hook for the narrative reminder, walk-away queue drain, rotation
# ABOUTME: nudge and mail wake; also serves FileChanged for the idle mail wake

set -euo pipefail

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# This script serves two events. Stop carries no name on legacy input, so an
# absent value means Stop.
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo Stop)

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
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
_mail_is_lead() {
    [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ] || return 1
    [ "$CLAUDE_PID" = "$CS_LEAD_PID" ] && return 0
    local parent
    parent=$(ps -o ppid= -p "$CLAUDE_PID" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$parent" ] && [ "$parent" = "$CS_LEAD_PID" ]
}

# Populate the MAIL_* globals. The re-wake guard is a snapshot of the filenames
# already discharged, not a count and not a high-water mark: unread drops to
# zero whenever cs -msg moves files to cur/, and filenames are not ordered by
# arrival (same-second order is by unpadded pid). Set membership needs neither
# property.
_mail_scan() {
    local f name kind
    for f in "$MAILDIR"/new/*.json; do
        [ -f "$f" ] || continue
        MAIL_UNREAD=$((MAIL_UNREAD + 1))
        name=${f##*/}
        MAIL_NAMES="$MAIL_NAMES$name
"
        # Reads a file, never a pipe, so the -q early exit cannot raise SIGPIPE;
        # and a missing snapshot yields 1, not grep's error status 2.
        if ! grep -qxF "$name" "$MAIL_WOKE" 2>/dev/null; then
            # A task is already an imperative in the queue, so waking on it
            # would race the drain — but it is discharged all the same, and
            # recording it is what stops every later turn from re-reading it. An
            # unreadable or forged document reads as text: over-waking is the
            # safe direction.
            kind=$(jq -r '.kind // "text"' "$f" 2>/dev/null || echo text)
            if [ "$kind" = "task" ]; then
                MAIL_DISCHARGED=1
            else
                MAIL_FRESH=1
            fi
        fi
    done
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
    [ -z "${CS_NO_MAIL_WAKE:-}" ] || { MAIL_FRESH=0; return 0; }
    local max seen
    max=$(_num_or "${CS_MAIL_WAKE_MAX:-}" 5)
    seen=$(_num_or "$(cat "$MAILDIR/wakes" 2>/dev/null | tr -d '[:space:]')" 0)
    if [ "$MAIL_FRESH" = 1 ] && [ "$seen" -ge "$max" ]; then
        MAIL_FRESH=0
    fi
    MAIL_WAKES="$seen"
}

_mail_count_wake() {
    printf '%s\n' "$((${MAIL_WAKES:-0} + 1))" > "$MAILDIR/wakes.tmp.$$" 2>/dev/null \
        && mv "$MAILDIR/wakes.tmp.$$" "$MAILDIR/wakes" 2>/dev/null || true
}

MAIL_REASON_TAIL="Run cs -msg to read it. Reply only if the message needs an answer; never reply merely to acknowledge."

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
if [ "$HOOK_EVENT" = "FileChanged" ]; then
    _fc_path=$(echo "$INPUT" | jq -r '.file_path // empty' 2>/dev/null || true)
    _fc_event=$(echo "$INPUT" | jq -r '.event // empty' 2>/dev/null || true)
    # A matcher-less entry is match-all over the union of every watch path in
    # the session, other plugins' included, so the hook filters its own.
    case "$_fc_path" in
        "$MAILDIR"/new/*.json) : ;;
        *) exit 0 ;;
    esac
    [ "$_fc_event" != "unlink" ] || exit 0
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
    # Delivery IS the exit here, so it has to come last and the record precedes
    # it — the reverse of the Stop path's order. The window is microseconds.
    _mail_count_wake
    _mail_record
    printf '%s\n' "Unread cross-session mail ($MAIL_UNREAD). $MAIL_REASON_TAIL" >&2
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

# _qlen is defined above, hoisted so the FileChanged branch can ask the same
# question before the drain's own section is reached.

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
# Best-effort: inbox failure must never break the drain.
_inbox_append() {  # jq --arg/--argjson pairs..., then the jq object program
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

# _num_or is defined above, hoisted alongside _qlen.

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

QLEN=$(_qlen "$QUEUE")
if [ "$QLEN" -gt 0 ]; then
    QSTATE=$(cat "$QSTATE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$QSTATE" ] || QSTATE="idle"

    if [ "$QSTATE" = "armed" ]; then
        TASK=""
        _first=$(_qfirst "$QUEUE") || _first=""
        [ -n "$_first" ] && TASK=$(cat "$_first" 2>/dev/null || true)
        printf 'draining\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        rm -f "$QDIR/failures"
        _inbox_append --arg ts "$(date +%s)" --arg q "$QLEN" \
            '{ts: ($ts|tonumber), event: "drain_started", queued: ($q|tonumber)}'
        REASON="cs task queue: starting a walk-away run. Work through the queued tasks one at a time; I will hand you the next after each finishes. Mirror the whole queue into your native task list now: run \`cs -queue list\` to see every queued item (this message shows only the first), create one task each, and mark each completed as you finish it. When a task is done, mark it completed and simply end your turn; the next task is delivered automatically on the next turn. Do not read or edit the queue yourself.

First task: $TASK"
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

Task: $NEXT"
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
    jq -nc --arg r "Unread cross-session mail ($MAIL_UNREAD). $MAIL_REASON_TAIL" \
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
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] && [ "$NUDGE_PCT" -ge "$NUDGE_CTX" ]; then
    NUDGED=$(cat "$QDIR/rotate-nudged" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$NUDGED" != "$NUDGE_UUID" ]; then
        printf '%s\n' "$NUDGE_UUID" > "$QDIR/rotate-nudged.tmp" \
            && mv "$QDIR/rotate-nudged.tmp" "$QDIR/rotate-nudged"
        REASON="Context is at ${NUDGE_PCT}% — consider rotating this conversation. Invoke the rotate skill to distill a handoff into .cs/handoffs/ and arm it; the user then runs /clear to continue in a fresh conversation, without leaving Claude Code. One-time notice for this conversation; if now is a bad time, simply continue."
        jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
        exit 0
    fi
fi

# --- Context warning ----------------------------------------------------------
# One-time heads-up when context crosses the wind-down band [warn, nudge).
# At or above the nudge threshold the rotation nudge above owns the turn;
# this tier never fires there. Cursor: conversation UUID last warned.
WARN_CTX=$(_num_or "${CS_CTX_WARN_CTX:-}" 60)
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] \
    && [ "$NUDGE_PCT" -ge "$WARN_CTX" ] && [ "$NUDGE_PCT" -lt "$NUDGE_CTX" ]; then
    WARNED=$(cat "$QDIR/ctx-warned" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$WARNED" != "$NUDGE_UUID" ]; then
        printf '%s\n' "$NUDGE_UUID" > "$QDIR/ctx-warned.tmp" \
            && mv "$QDIR/ctx-warned.tmp" "$QDIR/ctx-warned"
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

# Per-actor narratives: track the most recently modified narrative.*.md.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
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

# Update cooldown marker and remind
echo "$CURRENT_TIME" > "$COOLDOWN_FILE"

REASON="Narrative check. Update only your own narrative (run \`cs -whoami\` if unsure which actor you are; never edit a teammate's narrative). Newest on disk is $NARRATIVE_FILE. (1) If any of your own entries were disproven or superseded by your recent work, correct or remove them now. (2) Append any new findings as plain dated notes. If nothing needs changing, say so in one line and stop."

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'

exit 0
