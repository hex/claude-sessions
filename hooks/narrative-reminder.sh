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

QLEN=$(_qlen "$QUEUE")
if [ "$QLEN" -gt 0 ]; then
    QSTATE=$(cat "$QSTATE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$QSTATE" ] || QSTATE="idle"

    if [ "$QSTATE" = "armed" ]; then
        TASK=$(awk 'NF{print; exit}' "$QUEUE")
        printf 'draining\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
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
            NEWLEN=$(_qlen "$QUEUE")
            if [ "$NEWLEN" -le 0 ]; then
                printf 'idle\n' > "$QSTATE_FILE.tmp" && mv "$QSTATE_FILE.tmp" "$QSTATE_FILE"
                jq -nc '{decision:"block", reason:"cs task queue: all tasks complete. Mark the final native task completed, then give the user a brief summary of what the walk-away run accomplished and anything that needs their attention."}'
                exit 0
            fi
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
