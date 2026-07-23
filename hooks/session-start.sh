#!/usr/bin/env bash
# ABOUTME: SessionStart hook for cs session management
# ABOUTME: Initializes session environment and provides context to Claude

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Skip entirely if running inside a subagent call — the parent session
# handles its own lifecycle events; subagents shouldn't add noise
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# Extract session information
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

# Check if we're in a cs session
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    # Not in a cs session, do nothing
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Build the surface-once digest from unseen inbox lines. Sets DIGEST (may be
# empty) and, when there were unseen lines, advances the cursor — surfacing is
# at-most-once even when the digest itself is empty (decline-only content).
_build_digest() {  # meta_local_dir
    local qdir="$1" inbox seen total
    DIGEST=""
    inbox="$qdir/notifications.jsonl"
    [ -s "$inbox" ] || return 0
    total=$(wc -l < "$inbox" 2>/dev/null | tr -d '[:space:]') || return 0
    case "$total" in ''|*[!0-9]*) return 0;; esac
    seen=$(cat "$qdir/notifications.seen" 2>/dev/null | tr -d '[:space:]') || true
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    [ "$total" -gt "$seen" ] || return 0
    DIGEST=$(awk -v a=$((seen + 1)) -v b="$total" 'NR>=a && NR<=b' "$inbox" 2>/dev/null | jq -rRs '
        [split("\n")[] | select(length > 0) | (fromjson? // empty)] as $e |
        ($e | map(select(.event == "task_done")) | length) as $done |
        ($e | map(select(.event == "breaker_tripped")) | .[-1]) as $trip |
        ($e | map(select(.event == "drain_finished")) | length) as $fin |
        if ($done + $fin) == 0 and $trip == null then "" else
            "cs queue while you were away: \($done) task(s) done" +
            (if $trip != null then "; breaker tripped: \($trip.reason) (\($trip.reading) >= \($trip.limit)), \($trip.remaining) remaining" else "" end) +
            (if $fin > 0 then "; drain finished" else "" end) +
            ". Run cs -queue log for detail."
        end' 2>/dev/null) || DIGEST=""
    printf '%s\n' "$total" > "$qdir/notifications.seen.tmp" 2>/dev/null \
        && mv "$qdir/notifications.seen.tmp" "$qdir/notifications.seen" 2>/dev/null || true
}

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

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ]; then
    # Session directory doesn't exist, something is wrong
    exit 0
fi

# Log session start. Ensure the machine-local dir exists first: it is gitignored,
# so a freshly-cloned session has none until cs creates it, and an unguarded
# append into a missing dir would abort this hook under set -e.
mkdir -p "$META_DIR/local" 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started (source: $SOURCE, ID: $SESSION_ID)" >> "$META_DIR/local/session.log"
echo "  Working directory: $CWD" >> "$META_DIR/local/session.log"
echo "" >> "$META_DIR/local/session.log"

# Auto-pull and crash recovery only on fresh start or resume
# Skip on clear/compact since the session is already running
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "resume" ]; then

# Shadow ref: crash recovery and push protection (worktree-tolerant)
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # Ensure legacy shadow refs are never pushed (refs/worktree/* never are)
    git -C "$SESSION_DIR" config transfer.hideRefs refs/cs 2>/dev/null || true

    # Detect an orphaned shadow ref (this conversation crashed last run). A
    # conversation only ever recovers its OWN per-conversation ref, so a live
    # sibling's in-flight ref is never misread as a crash.
    SHADOW_REF=""
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$SESSION_ID" >/dev/null 2>&1; then
        SHADOW_REF="refs/worktree/cs/session/$SESSION_ID"
    fi
    if [ -n "$SHADOW_REF" ]; then
        # Generate a summary of what would be restored
        CRASH_DIFF=$(git -C "$SESSION_DIR" diff --stat HEAD "$SHADOW_REF" -- . 2>/dev/null || true)
        # Count from the full diff, then cap the list — a head -10 before
        # counting would understate the scope (report 10 when 30 changed).
        CRASH_ALL_FILES=$(git -C "$SESSION_DIR" diff --name-only HEAD "$SHADOW_REF" -- . 2>/dev/null || true)
        CRASH_FILE_COUNT=$(printf '%s\n' "$CRASH_ALL_FILES" | grep -c . 2>/dev/null || echo "0")
        CRASH_FILES=$(printf '%s\n' "$CRASH_ALL_FILES" | head -10 || true)

        if [ -n "$CRASH_FILES" ] && [ "$CRASH_FILE_COUNT" -gt 0 ]; then
            # Don't auto-restore — inject into context so Claude can ask the user
            CRASH_LIST_NOTE=""
            if [ "$CRASH_FILE_COUNT" -gt 10 ]; then
                CRASH_LIST_NOTE=" (first 10 listed)"
            fi

            # The blanket `checkout $SHADOW_REF -- .` is only safe when the
            # snapshot sits on the current HEAD. The autosave records the HEAD it
            # was taken against (cs-base trailer); if HEAD has since moved
            # (commit/rebase in another session) or the base is unknown (a
            # pre-stamp legacy ref), a blanket restore would splice a stale
            # snapshot over diverged history and revert committed work. Refuse it
            # in that case and point at per-file inspection instead.
            CURRENT_HEAD=$(git -C "$SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
            AUTO_MSG=$(git -C "$SESSION_DIR" log -1 --format=%B "$SHADOW_REF" 2>/dev/null || true)
            RECORDED_BASE=$(printf '%s\n' "$AUTO_MSG" | sed -n 's/^cs-base:[[:space:]]*//p')

            CRASH_HEAD="CRASH RECOVERY: The previous session ended without saving (crash or timeout). Autosaved changes were found in ${CRASH_FILE_COUNT} file(s)${CRASH_LIST_NOTE}:\n\n${CRASH_FILES}\n\nDiff summary:\n${CRASH_DIFF}\n\nIMPORTANT: Before starting any other work, ask the user (use AskUserQuestion) whether to restore or discard these changes."
            if [ -n "$RECORDED_BASE" ] && [ -n "$CURRENT_HEAD" ] && [ "$RECORDED_BASE" = "$CURRENT_HEAD" ]; then
                # The restore runs later (after the user answers), by which time
                # HEAD may have moved. Bake the base check into the command so it
                # re-verifies at execution and refuses rather than splicing a
                # stale snapshot over moved history.
                CRASH_CONTEXT="${CRASH_HEAD} Warning: restoring overwrites any current uncommitted changes to the listed files. To restore, run: git -C \"$SESSION_DIR\" rev-parse HEAD | grep -qx $RECORDED_BASE && git -C \"$SESSION_DIR\" checkout $SHADOW_REF -- . && git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF || echo \"REFUSED: HEAD moved since the snapshot; restore per file with: git -C $SESSION_DIR checkout $SHADOW_REF -- <file>\"\nTo discard, run: git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF"
            else
                # Distinguish a genuinely moved HEAD from a snapshot whose base
                # is simply unrecorded (a pre-upgrade autosave): claiming "HEAD
                # has moved" in the latter case is a false assertion.
                if [ -z "$RECORDED_BASE" ]; then
                    CRASH_WHY="The snapshot has no recorded base (a pre-upgrade autosave), so it cannot be verified to sit on the current HEAD."
                else
                    CRASH_WHY="HEAD has moved since this snapshot was taken (recorded base ${RECORDED_BASE}, current HEAD ${CURRENT_HEAD:-unknown})."
                fi
                CRASH_CONTEXT="${CRASH_HEAD} WARNING: ${CRASH_WHY} A blanket restore would overwrite committed work with a divergent snapshot, so it is NOT offered. Inspect and restore per file, e.g.: git -C \"$SESSION_DIR\" diff HEAD $SHADOW_REF -- <file> then git -C \"$SESSION_DIR\" checkout $SHADOW_REF -- <file>\nTo discard the snapshot once reviewed, run: git -C \"$SESSION_DIR\" update-ref -d $SHADOW_REF"
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Crash recovery: found ${CRASH_FILE_COUNT} unsaved file(s), awaiting user decision" \
                >> "$META_DIR/local/session.log"
        else
            # No actual changes — just clean up the orphaned ref
            git -C "$SESSION_DIR" update-ref -d "$SHADOW_REF" 2>/dev/null || true
        fi
    fi
fi

fi # end startup/resume guard

# Export environment variables for the session via CLAUDE_ENV_FILE
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    cat >> "$CLAUDE_ENV_FILE" << EOF
export CLAUDE_SESSION_NAME="$CLAUDE_SESSION_NAME"
export CLAUDE_SESSION_DIR="$SESSION_DIR"
export CLAUDE_SESSION_META_DIR="$META_DIR"
EOF
fi

# Provide context to Claude about the session
CONTEXT=$(cat << EOF
You are working in a managed Claude Code session: $CLAUDE_SESSION_NAME
Context loaded: $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u +%Y-%m-%dT%H:%M:%SZ))

Session directory: $CLAUDE_SESSION_DIR

Session metadata is in the .cs/ directory. The session root is your workspace.

Key files to maintain:
- .cs/README.md: Update objective and outcome
- .cs/memory/narrative.<actor>.md: append findings as you go (run 'cs -whoami' for your actor; read all narrative.*.md on resume)

Secrets: never write credentials to files — pipe the value to 'cs -secrets set <name>' on stdin (argv/heredocs are logged verbatim); retrieve with 'cs -secrets get <name>'. See CLAUDE.local.md, Secure Secrets Handling.

See CLAUDE.local.md in the session directory for complete documentation protocol.
EOF
)

# Set a key in the machine-local state file (.cs/local/state, gitignored —
# these values differ per machine, so they must never reach the git-synced
# README). Replaces any existing line for the key, collapses duplicates.
# Atomic (tmp+mv). KEEP THE FORMAT IN SYNC WITH bin/cs's _set_local_state.
STATE_FILE="$META_DIR/local/state"
local_state_set() {
    local key="$1" value="$2"
    mkdir -p "$META_DIR/local"
    local tmp="$STATE_FILE.tmp"
    {
        if [ -f "$STATE_FILE" ]; then
            awk -v key="$key" 'index($0, key ":") != 1' "$STATE_FILE"
        fi
        printf '%s: %s\n' "$key" "$value"
    } > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Bind claude_session_id in local state to the live conversation.
# Claude Code forks a new UUID when a conversation is continued past the
# context limit; the old transcript stays on disk, so the recorded UUID
# looks healthy while naming the pre-fork conversation and `cs` resumes
# stale history. The hook input names the conversation actually running,
# so it is authoritative on every source.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ "$SESSION_ID" =~ $UUID_RE ]]; then
    RECORDED_UUID=$(awk '/^claude_session_id:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
    if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then
        local_state_set claude_session_id "$SESSION_ID"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Rebound claude_session_id: ${RECORDED_UUID:-none} -> $SESSION_ID" >> "$META_DIR/local/session.log"
        # Durable lineage: a UUID change the launch path did not pre-record is
        # a rotation cs discovered (CC's context-limit fork, or a manual
        # resume of a different conversation). Shape shared with bin/cs's
        # _timeline_rotated.
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --arg from "${RECORDED_UUID:-}" \
               --arg to "$SESSION_ID" \
               '{ts: $ts, event: "rotated", from: $from, to: $to, reason: "rebind"}' \
            >> "$META_DIR/timeline.jsonl" 2>/dev/null || true
        # Follow the autosave ref to the new UUID so a future crash of this
        # (continued) conversation is recoverable under its live identity. A
        # rebind is a clean continuation, so there is no crash to recover here.
        if [[ "${RECORDED_UUID:-}" =~ $UUID_RE ]] \
            && git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
            _old_sha=$(git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$RECORDED_UUID" 2>/dev/null || true)
            if [ -n "$_old_sha" ]; then
                git -C "$SESSION_DIR" update-ref "refs/worktree/cs/session/$SESSION_ID" "$_old_sha" 2>/dev/null \
                    && git -C "$SESSION_DIR" update-ref -d "refs/worktree/cs/session/$RECORDED_UUID" "$_old_sha" 2>/dev/null || true
            fi
        fi
    fi
fi

# Append structured event to timeline.jsonl (machine-readable narrative log).
# Runs after the rebind block above so a rebind's rotated event lands before
# this conversation's started event — cs -conversations renders file order.
TIMELINE_FILE="$META_DIR/timeline.jsonl"
TIMELINE_BRANCH=$(git -C "$SESSION_DIR" branch --show-current 2>/dev/null || echo "")
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "started" \
       --arg source "$SOURCE" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    >> "$TIMELINE_FILE" 2>/dev/null || true

# Update last_resumed in local state on resume
if [ "$SOURCE" = "resume" ]; then
    local_state_set last_resumed "$(date '+%Y-%m-%d')"
fi

# A fresh session is attended by definition: drop any stale finished-blink
# marker left by the previous conversation's final Stop.
rm -f "$META_DIR/local/attention" 2>/dev/null || true

# iTerm2: also cancel any dock bounce the previous conversation left running.
# Mirrors the guard in narrative-reminder.sh (hooks are standalone).
if [ -z "${CS_NO_ITERM2:-}" ] && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    _it2="${CS_IT2_DIR:-$HOME/.iterm2}/it2attention"
    { [ -x "$_it2" ] && "$_it2" stop > "${CS_IT2_TTY:-/dev/tty}"; } 2>/dev/null || true
fi

# Dynamic context: add session state info on resume
if [ "$SOURCE" = "resume" ] && [ -d "$SESSION_DIR/.git" ]; then
    DYNAMIC=""

    # Time since last session activity
    LAST_LOG_TIME=$(tail -1 "$META_DIR/local/session.log" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1 || true)
    if [ -n "$LAST_LOG_TIME" ]; then
        DYNAMIC="${DYNAMIC}Last activity: ${LAST_LOG_TIME}\n"
    fi

    # Recent commits since last session
    COMMIT_COUNT=$(git -C "$SESSION_DIR" rev-list --count --since="7 days ago" HEAD 2>/dev/null || echo "0")
    if [ "$COMMIT_COUNT" -gt 0 ]; then
        RECENT_FILES=$(git -C "$SESSION_DIR" diff --name-only "HEAD~${COMMIT_COUNT}" HEAD 2>/dev/null | head -5 | xargs -n1 basename 2>/dev/null | paste -sd', ' - 2>/dev/null || true)
        DYNAMIC="${DYNAMIC}Recent commits: ${COMMIT_COUNT} in last 7 days"
        if [ -n "$RECENT_FILES" ]; then
            DYNAMIC="${DYNAMIC} (${RECENT_FILES})"
        fi
        DYNAMIC="${DYNAMIC}\n"
    fi

    # Per-actor digest: shared memory/narrative activity since this actor last looked.
    mkdir -p "$META_DIR/local" 2>/dev/null || true
    WATERMARK_FILE="$META_DIR/local/watermark"
    LAST_SEEN=""
    [ -f "$WATERMARK_FILE" ] && LAST_SEEN=$(cat "$WATERMARK_FILE" 2>/dev/null || true)
    HEAD_SHA=$(git -C "$SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
    if [ -n "$LAST_SEEN" ] && [ -n "$HEAD_SHA" ] && [ "$LAST_SEEN" != "$HEAD_SHA" ] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "$LAST_SEEN" >/dev/null 2>&1; then
        DIGEST=$(git -C "$SESSION_DIR" log --no-merges --format='%an' "$LAST_SEEN..HEAD" -- .cs/memory 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(.*\)$/\2 (\1)/' \
            | paste -sd', ' - 2>/dev/null || true)
        if [ -n "$DIGEST" ]; then
            DYNAMIC="${DYNAMIC}Since your last session, teammates committed to shared memory/narrative (author: commits): ${DIGEST}. Skim their narrative.*.md before working in overlapping areas.\n"
        fi
    fi
    # Advance the watermark to current HEAD (also seeds it on first resume).
    [ -n "$HEAD_SHA" ] && echo "$HEAD_SHA" > "$WATERMARK_FILE"

    # Objective from README.md
    OBJECTIVE=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$META_DIR/README.md" 2>/dev/null | head -1 | sed 's/^\[.*\]$//' || true)
    if [ -n "$OBJECTIVE" ] && [ "$OBJECTIVE" != "[Describe what you're trying to accomplish in this session]" ]; then
        DYNAMIC="${DYNAMIC}Objective: ${OBJECTIVE}\n"
    fi

    # Cross-session awareness: show most recently active sibling sessions
    SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
    if [ -d "$SESSIONS_ROOT" ]; then
        SIBLINGS=""
        SIBLING_COUNT=0
        seen_siblings=""
        # Sort sibling sessions by session.log mtime (most recent first)
        while IFS= read -r log_file; do
            sibling_dir=$(dirname "$(dirname "$(dirname "$log_file")")")
            [ -d "$sibling_dir/.cs" ] || continue
            sibling_name=$(basename "$sibling_dir")
            [ "$sibling_name" = "$CLAUDE_SESSION_NAME" ] && continue
            # The glob lists both .cs/local/ and .cs/logs/ logs, so a session
            # mid-migration (both present) surfaces twice — skip repeats.
            case " $seen_siblings " in *" $sibling_name "*) continue ;; esac
            seen_siblings="$seen_siblings $sibling_name"
            sibling_obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$sibling_dir/.cs/README.md" 2>/dev/null | head -1 || true)
            [ -z "$sibling_obj" ] && continue
            [[ "$sibling_obj" == "["*"]" ]] && continue
            SIBLINGS="${SIBLINGS}  ${sibling_name}: ${sibling_obj}\n"
            SIBLING_COUNT=$((SIBLING_COUNT + 1))
            [ "$SIBLING_COUNT" -ge 5 ] && break
        done < <(ls -t "$SESSIONS_ROOT"/*/.cs/local/session.log "$SESSIONS_ROOT"/*/.cs/logs/session.log 2>/dev/null || true)
        if [ -n "$SIBLINGS" ]; then
            DYNAMIC="${DYNAMIC}Other Sessions (awareness only — if a request belongs to one of these, say so rather than duplicating work here; to hand one a task or note, run cs -msg <session>):\n${SIBLINGS}"
        fi
    fi

    if [ -n "$DYNAMIC" ]; then
        CONTEXT="${CONTEXT}

--- Session State ---
$(printf '%b' "$DYNAMIC")"
    fi
fi

# Feature worktree sessions: tell Claude what this checkout is and how it
# integrates back. task_branch lands in machine-local state at creation,
# so this fires in both tracked- and ignored-.cs modes, on every source
# (the awareness must survive /clear and compaction).
TASK_BRANCH=$(awk '/^task_branch:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
# The commands below embed the session name; without its <base>@<task>
# shape they would misfire (cs -rm on a bare name deletes a whole session),
# so an unparseable name gets no block at all.
if [ -n "$TASK_BRANCH" ] && [[ "$CLAUDE_SESSION_NAME" == *@* ]]; then
    CS_BASE=$(awk '/^cs_base:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
    CS_BASE="${CS_BASE:-${CLAUDE_SESSION_NAME%%@*}}"
    TASK_NAME="${CLAUDE_SESSION_NAME#*@}"
    CONTEXT="${CONTEXT}

--- Feature Worktree ---
This session is a feature worktree of session '$CS_BASE' on branch $TASK_BRANCH. Work and commit here as normal; the checkout is disposable once the feature is integrated.

When the feature is complete, ask the user to run: cs $CS_BASE --merge $TASK_NAME
That command merges the branch into the base session, fuses the session records (timeline, narrative), and removes this worktree. It refuses while either session is open, so it runs from a free terminal after this session closes.

Do NOT merge $TASK_BRANCH into the base branch manually and do not delete the branch — that bypasses the record fuse and the cleanup. To abandon the feature instead, ask the user to run: cs -rm $CLAUDE_SESSION_NAME — never run this yourself; it deletes this worktree and its session records."
fi

# Deliberate rotation: the launch's r answer left a pending-handoff marker.
# Consume it — flip the handoff's frontmatter to consumed, record the
# consumer, remove the marker — and inject a preamble pointing Claude at the
# handoff file. A stale marker (file gone) is removed silently.
ROTATION_HANDOFF=""
PENDING_MARKER="$META_DIR/local/pending-handoff"
if [ -f "$PENDING_MARKER" ]; then
    HANDOFF_BASENAME=$(cat "$PENDING_MARKER" 2>/dev/null | tr -d '[:space:]' || true)
    HANDOFF_FILE="$META_DIR/handoffs/$HANDOFF_BASENAME"
    if [ -n "$HANDOFF_BASENAME" ] && [ -f "$HANDOFF_FILE" ]; then
        ROTATION_HANDOFF="$HANDOFF_BASENAME"
        awk -v uuid="$SESSION_ID" '
            !flipped && $0 == "status: unconsumed" {
                print "status: consumed"
                print "consumed_by: " uuid
                flipped = 1
                next
            }
            { print }
        ' "$HANDOFF_FILE" > "$HANDOFF_FILE.tmp" 2>/dev/null \
            && mv "$HANDOFF_FILE.tmp" "$HANDOFF_FILE" 2>/dev/null \
            || rm -f "$HANDOFF_FILE.tmp" 2>/dev/null || true
    fi
    rm -f "$PENDING_MARKER" 2>/dev/null || true
fi

# The rotation preamble and the fresh-rebind notice are mutually exclusive:
# the rotate path also exports CS_FRESH_REBIND, and "clean break" plus
# "continue per the handoff" would contradict each other.
if [ -n "$ROTATION_HANDOFF" ]; then
    CONTEXT="${CONTEXT}

--- Conversation Rotation ---
This fresh conversation continues rotated work. Read .cs/handoffs/$ROTATION_HANDOFF FIRST — it is the previous conversation's handoff; continue per its next-step section. The prior transcript is not loaded; the handoff plus .cs/memory/narrative.*.md carry the context."
elif [ "${CS_FRESH_REBIND:-}" = "1" ]; then
    CONTEXT="${CONTEXT}

--- Fresh Conversation ---
The user explicitly started a fresh conversation in this cs session — the prior conversation's transcript is not loaded. Treat this as a clean break, not a continuation.

For prior context, lazily consult as needed:
- .cs/memory/narrative.*.md — findings and decisions from earlier work (append only to your own actor's file)
- .cs/README.md            — session objective

Do not assume continuity with previous turns."
fi

# Append crash recovery info if present
if [ -n "${CRASH_CONTEXT:-}" ]; then
    CONTEXT="${CONTEXT}

--- $(printf '%b' "$CRASH_CONTEXT")"
fi

# Queue inbox digest (surface-once; same recipe as scope-prompt.sh).
DIGEST=""
_build_digest "$META_DIR/local"
if [ -n "$DIGEST" ]; then
    CONTEXT="${CONTEXT}

--- $DIGEST"
fi

# Mail digest (surface-once; same recipe).
MAIL_DIGEST=""
_build_mail_digest "$META_DIR/local"
if [ -n "$MAIL_DIGEST" ]; then
    CONTEXT="${CONTEXT}

--- $MAIL_DIGEST"
fi

# Return additional context as JSON
jq -n --arg context "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $context,
        statusMessage: "Loading session..."
    }
}'

exit 0
