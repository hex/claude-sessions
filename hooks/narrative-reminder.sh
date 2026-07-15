#!/usr/bin/env bash
# ABOUTME: Stop hook that reminds Claude to update the session narrative periodically
# ABOUTME: Cooldown-gated (at most once per 5 minutes); tracks the newest .cs/memory/narrative.*.md

set -euo pipefail

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi

# Claude just finished a turn: raise the machine-local attention flag the
# statusline blinks until the user next interacts. Cleared by scope-prompt.sh
# on the next prompt and by session-start.sh at launch. Lives in .cs/local/
# (per-machine state, never git-synced). Raised before the cooldown gates so
# every turn end signals, not just the ones that remind.
mkdir -p "$META_DIR/local" 2>/dev/null || true
touch "$META_DIR/local/attention" 2>/dev/null || true

# --- Task queue drain (walk-away mode) ---------------------------------------
# Hands the agent its next queued task when armed; asks once when idle. Wins
# over the narrative nag (returns early). Queue text is arbitrary -> jq emit.
QDIR="$META_DIR/local"
QUEUE="$QDIR/queue"
QSTATE_FILE="$QDIR/queue.state"

_qlen() {
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

_num_or() {  # value, default -> prints value if a plain integer, else default
    case "${1:-}" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac
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
        now=$(date +%s)
        case "$fiveh$stamped" in *[!0-9]*|'') : ;; *)
            if [ $((now - stamped)) -le 1800 ] && [ "$fiveh" -ge "$max_5h" ]; then
                echo "five_hour $fiveh $max_5h"
                return 0
            fi ;;
        esac
    fi
    return 1
}

QLEN=$(_qlen "$QUEUE")
if [ "$QLEN" -gt 0 ]; then
    QSTATE=$(cat "$QSTATE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$QSTATE" ] || QSTATE="idle"

    if [ "$QSTATE" = "armed" ]; then
        TASK=$(awk 'NF{print; exit}' "$QUEUE")
        printf 'draining\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
        rm -f "$QDIR/failures"
        _inbox_append --arg ts "$(date +%s)" --arg q "$QLEN" \
            '{ts: ($ts|tonumber), event: "drain_started", queued: ($q|tonumber)}'
        REASON="cs task queue: starting a walk-away run. Work through the queued tasks one at a time; I will hand you the next after each finishes. Mirror the whole queue into your native task list now: run \`cs -queue list\` to see every queued item (this message shows only the first), create one task each, and mark each completed as you finish it. When a task is done, mark it completed and simply end your turn; the next task is delivered automatically on the next turn. Do not read or edit the queue file yourself.

First task: $TASK"
        jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
        exit 0
    fi

    if [ "$QSTATE" = "draining" ]; then
        DONE_TASK=$(awk 'NF{print; exit}' "$QUEUE")
        if awk 'popped==0 && NF { popped=1; next } { print }' "$QUEUE" \
                > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"; then
            printf '%s\n' "$DONE_TASK" >> "$QDIR/queue.done"
            _inbox_append --arg ts "$(date +%s)" --arg task "$DONE_TASK" \
                '{ts: ($ts|tonumber), event: "task_done", task: $task}'
            NEWLEN=$(_qlen "$QUEUE")
            if [ "$NEWLEN" -le 0 ]; then
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                DONE_COUNT=$(_qlen "$QDIR/queue.done")
                _inbox_append --arg ts "$(date +%s)" --arg d "$DONE_COUNT" \
                    '{ts: ($ts|tonumber), event: "drain_finished", done: ($d|tonumber)}'
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
                rm -f "$QDIR/failures"
                REASON="cs task queue: circuit breaker tripped — $REASON_KIND at $READING (threshold $LIMIT). The queue is parked with $NEWLEN task(s) remaining; nothing was lost. Summarize the walk-away run so far and anything that needs the user's attention. They can re-arm with: cs -queue start."
                jq -nc --arg r "$REASON" '{decision:"block", reason:$r}'
                exit 0
            fi
            rm -f "$QDIR/failures"
            NEXT=$(awk 'NF{print; exit}' "$QUEUE")
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
