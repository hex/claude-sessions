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
# Not in a cs session, do nothing. Resolves from the env under the CLI and
# from the opened directory under front ends that cannot export one.
cs_resolve_session "$INPUT" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Build the surface-once digest from unseen inbox lines. Sets DIGEST (may be
# empty) and DIGEST_PENDING, the cursor value that _commit_digest spends once
# the digest has actually been printed — surfacing is at-most-once even when
# the digest itself is empty (decline-only content).
_build_digest() {  # meta_local_dir
    local qdir="$1" inbox seen total
    DIGEST=""
    DIGEST_PENDING=""
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
    DIGEST_PENDING="$total"
}

# Spend the digest's surface-once budget, and only after it has been written to
# stdout. This hook runs under a wall-clock timeout and is killed where it
# stands when it overruns; a cursor advanced up front retires notifications
# nobody ever saw, and there is no second chance at them. Advancing afterwards
# can at worst repeat a digest, which is the harmless direction to fail in.
_commit_digest() {  # meta_local_dir
    [ -n "${DIGEST_PENDING:-}" ] || return 0
    printf '%s\n' "$DIGEST_PENDING" > "$1/notifications.seen.tmp" 2>/dev/null \
        && mv "$1/notifications.seen.tmp" "$1/notifications.seen" 2>/dev/null || true
    DIGEST_PENDING=""
}

# True when a handoff file's YAML frontmatter (line 1 "---" through the next
# "---") carries status: unconsumed. Scoped to the frontmatter so a body that
# quotes the contract line flush-left cannot match. Same scan as the launch
# path's pending-handoff detection (hooks cannot source bin/cs).
_handoff_is_unconsumed() {  # handoff_file
    awk '
        NR==1 {
            if ($0 != "---") { rc=1; closed=1; exit }
            next
        }
        !closed && $0 == "---" { rc = (matched ? 0 : 1); closed=1; exit }
        !closed && $0 == "status: unconsumed" { matched=1 }
        END { if (!closed) rc=1; exit rc }
    ' "$1" 2>/dev/null
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

    # Claim a pre-upgrade shared ref once into this conversation's ref. The CAS
    # delete (update-ref -d <ref> <old-sha>) succeeds for exactly one racing
    # conversation — the second's delete fails because the expected old value is
    # gone — and only that winner creates its own session ref from the sha.
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        for _legacy in refs/worktree/cs/auto refs/cs/auto; do
            _lsha=$(git -C "$SESSION_DIR" rev-parse -q --verify "$_legacy" 2>/dev/null || true)
            [ -n "$_lsha" ] || continue
            if git -C "$SESSION_DIR" update-ref -d "$_legacy" "$_lsha" 2>/dev/null; then
                # Create only when this conversation has no ref yet, so a second
                # legacy ref (or a pre-existing own crashed ref) is never
                # overwritten. Restore the legacy ref if the create fails, so a
                # claimed snapshot is never lost to ref-lock contention.
                if ! git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$SESSION_ID" >/dev/null 2>&1; then
                    # Re-stamp the claimed tree under a fresh commit so the ref's
                    # tip date reflects claim time (liveness), not the stale
                    # legacy commit date — otherwise a peer's 14-day GC would
                    # prune this live, just-claimed ref. No cs-base trailer, so
                    # recovery treats a legacy snapshot as unverifiable-base
                    # (per-file guidance), which is correct for pre-upgrade work.
                    _ltree=$(git -C "$SESSION_DIR" rev-parse -q --verify "$_lsha^{tree}" 2>/dev/null || true)
                    _claimed=""
                    [ -n "$_ltree" ] && _claimed=$(printf 'autosave: claimed legacy snapshot\n' | git -C "$SESSION_DIR" commit-tree "$_ltree" 2>/dev/null || true)
                    if [ -n "$_claimed" ]; then
                        git -C "$SESSION_DIR" update-ref "refs/worktree/cs/session/$SESSION_ID" "$_claimed" 2>/dev/null \
                            || git -C "$SESSION_DIR" update-ref "$_legacy" "$_lsha" 2>/dev/null || true
                    else
                        git -C "$SESSION_DIR" update-ref "$_legacy" "$_lsha" 2>/dev/null || true
                    fi
                fi
            fi
        done
    fi

    # GC: prune foreign conversation refs whose tip is older than 14 days, so a
    # conversation that crashed and was never reopened can't accumulate refs
    # forever. Never touches the current conversation's own ref, nor this
    # process's launch-UUID predecessor ref — the rebind rename below still needs
    # that one to carry a context-fork's snapshot to the new UUID. The delete is
    # a compare-and-swap on the tip whose age justified it, so a foreign ref its
    # owner advances between the age read and the delete is not destroyed.
    _gc_now=$(date +%s)
    while IFS= read -r _ref; do
        [ -n "$_ref" ] || continue
        case "$_ref" in
            "refs/worktree/cs/session/$SESSION_ID") continue ;;
            "refs/worktree/cs/session/${CS_CLAUDE_SESSION_ID:-}") continue ;;
        esac
        _gc_meta=$(git -C "$SESSION_DIR" log -1 --format='%ct %H' "$_ref" 2>/dev/null || true)
        _gc_ct=${_gc_meta%% *}
        _gc_sha=${_gc_meta#* }
        case "$_gc_ct" in ''|*[!0-9]*) _gc_ct=0 ;; esac
        if [ -n "$_gc_sha" ] && [ "$(( _gc_now - _gc_ct ))" -gt "$(( 14*86400 ))" ]; then
            git -C "$SESSION_DIR" update-ref -d "$_ref" "$_gc_sha" 2>/dev/null || true
        fi
    done < <(git -C "$SESSION_DIR" for-each-ref --format='%(refname)' 'refs/worktree/cs/session/' 2>/dev/null || true)

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

# Export environment variables for the session via CLAUDE_ENV_FILE, for the
# launch cs made and for a teammate. A teammate reaches the session by walking
# the directory it was spawned into, and needs the contract in its own
# environment: `cs -secrets`, `cs -msg`, `cs -queue` and the status line all
# read the session from there. It is still not the launch, so it carries the
# marker out with it -- session-end.sh reads that to decide whether the lock is
# this conversation's to remove, and a teammate's exit must not strip the
# lead's. Any other walked-in front end gets nothing: publishing the contract
# would make every hook it fires afterwards read as the launch that owns them.
_cs_publish_to=""
if [ "${CS_RESOLVED_FROM:-env}" = "env" ]; then
    _cs_publish_to="launch"
elif command -v _cs_is_teammate >/dev/null 2>&1 && _cs_is_teammate; then
    _cs_publish_to="teammate"
fi
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$_cs_publish_to" ]; then
    cat >> "$CLAUDE_ENV_FILE" << EOF
export CLAUDE_SESSION_NAME="$CLAUDE_SESSION_NAME"
export CLAUDE_SESSION_DIR="$SESSION_DIR"
export CLAUDE_SESSION_META_DIR="$META_DIR"
EOF
    if [ "$_cs_publish_to" = "teammate" ]; then
        printf 'export CS_RESOLVED_FROM="%s"\n' "${CS_RESOLVED_FROM:-walk}" >> "$CLAUDE_ENV_FILE"
    fi
fi

# Resolve who is driving this session, for the identity anchor below.
# KEEP IN SYNC with cs_actor_slug()/_slugify() in lib/40-state.sh — hooks cannot
# source lib/, and shelling out to cs would make the hook depend on cs being on
# PATH. Same precedence: $CS_ACTOR, then the pinned identity, then git.
# if/elif/else, not three independent tests: a pinned identity file ends the
# search by EXISTING, so a blank pin resolves to "unknown" rather than falling
# through to git. Naming an actor cs would not resolve is the whole defect this
# anchor exists to prevent.
ACTOR_RAW=""
if [ -n "${CS_ACTOR:-}" ]; then
    ACTOR_RAW="$CS_ACTOR"
elif [ -f "$META_DIR/local/identity" ]; then
    IFS= read -r ACTOR_RAW < "$META_DIR/local/identity" || true
else
    ACTOR_RAW=$(git -C "$SESSION_DIR" config user.email 2>/dev/null || true)
    [ -n "$ACTOR_RAW" ] || ACTOR_RAW=$(git -C "$SESSION_DIR" config user.name 2>/dev/null || true)
fi
[ -n "$ACTOR_RAW" ] || ACTOR_RAW="unknown"
ACTOR_SLUG=$(printf '%s' "$ACTOR_RAW" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-*$//')

# Provide context to Claude about the session
CONTEXT=$(cat << EOF
You are working in a managed Claude Code session: $CLAUDE_SESSION_NAME
Context loaded: $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u +%Y-%m-%dT%H:%M:%SZ))

Session directory: $CLAUDE_SESSION_DIR

Session metadata is in the .cs/ directory. The session root is your workspace.

Current actor: $ACTOR_SLUG ($ACTOR_RAW). Your narrative is .cs/memory/narrative.$ACTOR_SLUG.md.
.cs/memory/ is shared by multiple actors, but only narratives are partitioned: a durable memory entry naming someone else as the user was written by or for another actor and does not describe who you are talking to. Identity comes from this line and the live environment, never from a memory entry.

Key files to maintain:
- .cs/README.md: Update objective and outcome
- .cs/memory/narrative.$ACTOR_SLUG.md: append findings as you go; on resume read the live narrative.*.md (older sections: .cs/narrative-archive/<actor>/, grep on demand)

Secrets: never write credentials to project files — feed the value to 'cs -secrets set <name>' on stdin via a file redirect (argv, pipes and heredocs are all logged verbatim); retrieve with 'cs -secrets get <name>'. See CLAUDE.local.md, Secure Secrets Handling.

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
# Resolve the pending rotation marker's fate once: the rebind block's timeline
# label and the consumption block far below both read ROTATION_HANDOFF, so the
# two cannot drift apart.
#
# Source is tested first. On a source that continues an existing conversation
# the marker is neither inspected nor changed, so a compaction or a
# context-limit fork between the rotate skill and /clear cannot eat a pending
# rotation. Only where a genuinely fresh conversation begins does a spent or
# missing handoff make the marker stale and worth dropping.
ROTATION_HANDOFF=""
PENDING_MARKER="$META_DIR/local/pending-handoff"
case "$SOURCE" in
    startup|clear)
        if [ -f "$PENDING_MARKER" ]; then
            HANDOFF_BASENAME=$(cat "$PENDING_MARKER" 2>/dev/null | tr -d '[:space:]' || true)
            # The marker names a basename. Anything with a separator would
            # resolve outside the handoff store, and the file it landed on
            # would be rewritten and then named to Claude as the handoff.
            # Backslash counts too: nothing cs writes here contains one, so
            # rejecting it costs nothing and closes a spelling of the same idea.
            case "$HANDOFF_BASENAME" in
                */*|*\\*) HANDOFF_BASENAME="" ;;
            esac
            HANDOFF_FILE="$META_DIR/handoffs/$HANDOFF_BASENAME"
            if [ -n "$HANDOFF_BASENAME" ] && [ -f "$HANDOFF_FILE" ] \
                && _handoff_is_unconsumed "$HANDOFF_FILE"; then
                ROTATION_HANDOFF="$HANDOFF_BASENAME"
            else
                rm -f "$PENDING_MARKER" 2>/dev/null || true
            fi
        fi
        ;;
esac

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Only the launched conversation may rebind: the slot is one per checkout, and
# every claude that resolves this session fires this hook. A teammate is a full
# claude process with its own top-level SessionStart (the agent_id check above
# catches in-process subagents, not tmux-backed ones), and a front end that
# walked in from the directory is not a cs launch at all — either taking the
# slot leaves `cs <name>` resuming a conversation nobody opened, and stamps the
# timeline with a lineage that never happened.
#
# Two shapes count as the launch, because cs starts claude two ways. The exec
# arms replace cs's own process, so claude carries cs's pid; the resume arm runs
# claude as a child, since it needs the exit status to fall through to a fresh
# rebind when there is nothing to resume, and there claude's parent is cs. A
# teammate is neither: tmux starts it, so cs is not its process and not its
# parent, and CS_LEAD_PID is absent from its environment entirely.
#
# Both variables must be non-empty, not merely equal: unset on both sides
# compares equal, which would hand the slot to precisely the callers this
# excludes.
IS_LEAD=0
if [ -n "${CS_LEAD_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ]; then
    if [ "$CLAUDE_PID" = "$CS_LEAD_PID" ]; then
        IS_LEAD=1
    else
        _CS_LAUNCH_PARENT=$(ps -o ppid= -p "$CLAUDE_PID" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$_CS_LAUNCH_PARENT" ] && [ "$_CS_LAUNCH_PARENT" = "$CS_LEAD_PID" ]; then
            IS_LEAD=1
        fi
    fi
fi
if [ "$IS_LEAD" = 1 ] && [[ "$SESSION_ID" =~ $UUID_RE ]]; then
    RECORDED_UUID=$(awk '/^claude_session_id:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
    if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then
        local_state_set claude_session_id "$SESSION_ID"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Rebound claude_session_id: ${RECORDED_UUID:-none} -> $SESSION_ID" >> "$META_DIR/local/session.log"
        # Named literally: TIMELINE_FILE is not assigned until further down.
        _cs_terminate_jsonl "$META_DIR/timeline.jsonl" 2>/dev/null || true
        # Durable lineage: a UUID change the launch path did not pre-record.
        # With a marker resolved above it is a deliberate in-process rotation
        # (/clear) and carries the handoff name; otherwise it is one cs
        # discovered — CC's context-limit fork, or a manual resume of a
        # different conversation. Shape shared with bin/cs's _timeline_rotated.
        jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --arg from "${RECORDED_UUID:-}" \
               --arg to "$SESSION_ID" \
               --arg handoff "$ROTATION_HANDOFF" \
               '{ts: $ts, event: "rotated", from: $from, to: $to,
                 reason: (if $handoff == "" then "rebind" else "handoff" end)}
                + (if $handoff == "" then {} else {handoff: $handoff} end)' \
            >> "$META_DIR/timeline.jsonl" 2>/dev/null || true
        # Follow the autosave ref to the new UUID so a future crash of this
        # (continued) conversation is recoverable under its live identity. A
        # rebind is a clean continuation, so there is no crash to recover here.
        #
        # Gate on process identity: claude_session_id in state is a single shared
        # slot per checkout, so "recorded != mine" is also true when a sibling
        # conversation ran after me. A genuine context-fork keeps this process's
        # launch UUID (CS_CLAUDE_SESSION_ID) equal to the recorded predecessor
        # while the hook's session_id changes; a sibling's launch UUID is its own.
        # Only rename when the recorded id is this process's own predecessor,
        # never a sibling's — otherwise this would strip a live sibling's ref.
        if [ "${CS_CLAUDE_SESSION_ID:-}" = "${RECORDED_UUID:-}" ] \
            && [[ "${RECORDED_UUID:-}" =~ $UUID_RE ]] \
            && git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
            _old_sha=$(git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$RECORDED_UUID" 2>/dev/null || true)
            if [ -n "$_old_sha" ]; then
                # Create-only CAS: the empty old-value requires the destination
                # not to exist. A genuine fork's new UUID has no ref yet; an
                # in-app /resume to a pre-existing (possibly crashed) conversation
                # already owns its ref, so the create fails and the whole rename
                # is skipped — never clobbering the resumed conversation's snapshot.
                git -C "$SESSION_DIR" update-ref "refs/worktree/cs/session/$SESSION_ID" "$_old_sha" "" 2>/dev/null \
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
_cs_terminate_jsonl "$TIMELINE_FILE" 2>/dev/null || true
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

# Dynamic context: add session state info on resume. The repo test is
# rev-parse, not `-d .git`: in a feature worktree .git is a FILE, and a
# directory test there skipped this whole block on every resume.
if [ "$SOURCE" = "resume" ] && git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # Real newline, not the two characters backslash-n. The block used to be
    # emitted through `printf '%b'`, which interprets escapes in whatever was
    # interpolated — so a README objective containing the literal characters
    # backslash-0-3-3 was turned into a real ESC byte by cs itself. Building the
    # text with actual newlines lets it render with %s, where content is content.
    _NL=$'\n'
    DYNAMIC=""

    # Time since last session activity
    LAST_LOG_TIME=$(tail -1 "$META_DIR/local/session.log" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1 || true)
    if [ -n "$LAST_LOG_TIME" ]; then
        DYNAMIC="${DYNAMIC}Last activity: ${LAST_LOG_TIME}${_NL}"
    fi

    # Recent commits since last session
    COMMIT_COUNT=$(git -C "$SESSION_DIR" rev-list --count --since="7 days ago" HEAD 2>/dev/null || echo "0")
    if [ "$COMMIT_COUNT" -gt 0 ]; then
        RECENT_FILES=$(git -C "$SESSION_DIR" diff --name-only "HEAD~${COMMIT_COUNT}" HEAD 2>/dev/null | head -5 | xargs -n1 basename 2>/dev/null | paste -sd', ' - 2>/dev/null || true)
        DYNAMIC="${DYNAMIC}Recent commits: ${COMMIT_COUNT} in last 7 days"
        if [ -n "$RECENT_FILES" ]; then
            DYNAMIC="${DYNAMIC} (${RECENT_FILES})"
        fi
        DYNAMIC="${DYNAMIC}${_NL}"
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
            DYNAMIC="${DYNAMIC}Since your last session, teammates committed to shared memory/narrative (author: commits): ${DIGEST}. Skim their narrative.*.md before working in overlapping areas.${_NL}"
        fi
    fi
    # Advance the watermark to current HEAD (also seeds it on first resume).
    [ -n "$HEAD_SHA" ] && echo "$HEAD_SHA" > "$WATERMARK_FILE"

    # Objective from README.md
    OBJECTIVE=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$META_DIR/README.md" 2>/dev/null | head -1 | sed 's/^\[.*\]$//' || true)
    if [ -n "$OBJECTIVE" ] && [ "$OBJECTIVE" != "[Describe what you're trying to accomplish in this session]" ]; then
        DYNAMIC="${DYNAMIC}Objective: ${OBJECTIVE}${_NL}"
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
            SIBLINGS="${SIBLINGS}  ${sibling_name}: ${sibling_obj}${_NL}"
            SIBLING_COUNT=$((SIBLING_COUNT + 1))
            [ "$SIBLING_COUNT" -ge 5 ] && break
        done < <(ls -t "$SESSIONS_ROOT"/*/.cs/local/session.log "$SESSIONS_ROOT"/*/.cs/logs/session.log 2>/dev/null || true)
        if [ -n "$SIBLINGS" ]; then
            # The send form is spelled out rather than named. Inbound mail is
            # already pushed here on every prompt by scope-prompt.sh's digest;
            # outbound has no such channel, and the syntax lives only in
            # `cs --help`. Naming the verb alone announces a capability without
            # supplying it, which costs a help call every time it is used. This
            # block is already conditional on siblings existing, so it appears
            # exactly when there is somewhere to send to.
            DYNAMIC="${DYNAMIC}Other Sessions — when a request substantially matches one of these objectives, not merely its vocabulary, ask via AskUserQuestion whether to hand it over before starting the work here. Offer both: do it here, or send it there. Be picky, the way the wrap-up cue is: a request that only brushes a sibling's subject belongs here, and a prompt that fires on every overlap becomes the block nobody reads.${_NL}${SIBLINGS}To hand one a task or note: cs -msg <session> \"<body>\"${_NL}Add --kind notify|task|text|result (default text; a task kind lands in that session's walk-away queue).${_NL}"
        fi
    fi

    if [ -n "$DYNAMIC" ]; then
        # %s, not %b: escapes in interpolated content are data. Scrubbed once
        # here because DYNAMIC carries text cs did not write — a sibling
        # session's README objective, git author names, commit subjects — and
        # the range keeps tab and newline, so the block's own breaks survive.
        CONTEXT="${CONTEXT}

--- Session State ---
$(printf '%s' "$DYNAMIC" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
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

# Consume the rotation resolved above: flip the handoff's frontmatter to
# consumed, record the consumer, and drop the marker. Only the first status
# line (the frontmatter's) flips; a body quoting it flush-left stays intact.
if [ -n "$ROTATION_HANDOFF" ]; then
    HANDOFF_FILE="$META_DIR/handoffs/$ROTATION_HANDOFF"
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
    rm -f "$PENDING_MARKER" 2>/dev/null || true
fi

# The clean-break notice belongs only where the conversation genuinely starts
# clean: a /clear, or a launch that rebound to a fresh UUID. CS_FRESH_REBIND is
# exported before exec and so outlives the launch, which is why the source
# matters too — on its own it would tell a later /compact of a rebound session
# that its transcript is not loaded while it still is.
#
# An explicit if inside the case arm: `[ ... ] && VAR=1` as an arm's last
# command returns 1 under set -e.
FRESH_NOTICE=""
case "$SOURCE" in
    clear)
        FRESH_NOTICE=1
        ;;
    startup)
        if [ "${CS_FRESH_REBIND:-}" = "1" ]; then
            FRESH_NOTICE=1
        fi
        ;;
esac

# Arm the /clear auto-start. A hook cannot start a turn, but it can arm one:
# a file appearing under a watched path fires FileChanged, and that hook exiting
# 2 (asyncRewake) wakes the model in an idle interactive session. Measured on
# 2.1.252 against a real /clear, in a conversation with zero turns — the wake is
# not conditional on the conversation having history.
#
# The kick therefore needs a directory to be watched and a file to arrive in it
# AFTER the watch arms, which is only once this hook's output has been
# processed. Hence a detached child: it outlives the hook, sleeps, and writes.
# All three fds are redirected — a child holding this hook's stdout keeps Claude
# Code waiting on the pipe, which would stall the very launch it is accelerating.
#
# Measured arm latency is ~1s (write at T+1.05s produced an event at T+1.75s), so
# the default delay has room without being a visible pause. One sample, so the
# fallback matters more than the margin: if the write lands early the event is
# lost and the user is exactly where 06fbb44 left them, one word from starting.
#
# Scoped like the notice below: only a /clear that loaded a rotation. The startup
# path is the r-answer, where _exec_fresh_rebind has already handed claude a
# positional prompt — a wake there would arrive on top of a running turn.
# Lead-only for the same reason the mail watch is: every claude resolving this
# session runs this hook, and N kicks means N sessions racing on one rotation.
ROTATION_KICK=""
if [ -n "$ROTATION_HANDOFF" ] && [ "$SOURCE" = "clear" ] && [ "$IS_LEAD" = 1 ] \
    && [ -z "${CS_NO_ROTATION_WAKE:-}" ]; then
    _kick_dir="$META_DIR/local/rotation-kick"
    # The watcher is handed the path with no existence check, and a watch armed
    # on a missing directory never fires again for the process's lifetime.
    if mkdir -p "$_kick_dir" 2>/dev/null; then
        ROTATION_KICK="$_kick_dir"
        # A stale marker from a previous rotation would make the FileChanged
        # hook treat this kick as already delivered and exit silently.
        rm -f "$_kick_dir/delivered" "$_kick_dir"/*.kick 2>/dev/null || true
        # A non-integer override must not reach sleep: under errexit a failed
        # sleep would kill the child before the write, arming a watch nothing
        # ever fires. Same validation shape as narrative-reminder's _num_or,
        # inlined because this hook sources no shared library.
        _kick_delay="${CS_ROTATION_KICK_DELAY:-2}"
        case "$_kick_delay" in ''|*[!0-9]*) _kick_delay=2 ;; esac
        (
            # tmp+rename, as every other watched-dir write in cs does: writing
            # in place is create-then-write, two filesystem operations, and a
            # watcher reporting both would race two hook instances through the
            # compose-before-record window and could wake twice. The temp name
            # deliberately does not end in .kick, so it does not match the
            # hook's triage.
            _write_kick() {
                date +%s > "$_kick_dir/rotation.tmp.$$" 2>/dev/null \
                    && mv "$_kick_dir/rotation.tmp.$$" "$_kick_dir/rotation.kick" 2>/dev/null
            }
            [ "$_kick_delay" = 0 ] || sleep "$_kick_delay"
            _write_kick || true
            # Written twice on purpose. The delay is one measurement on an idle
            # machine, and if the watch arms after the first write that event is
            # lost with no retry anywhere — the session then sits idle under a
            # notice promising it would continue on its own, which is worse than
            # the old "send any message" it replaced. A second write re-enters
            # the branch (the triage filters only unlink), and the delivered
            # marker makes it a no-op when the first write already woke.
            [ "$_kick_delay" = 0 ] || sleep "$_kick_delay"
            [ -f "$_kick_dir/delivered" ] || _write_kick || true
        ) </dev/null >/dev/null 2>&1 &
    fi
elif [ "$SOURCE" = "clear" ]; then
    # A /clear that arms nothing must SPEND any kick still in flight from a
    # previous one. Otherwise: /clear #1 arms and its child sleeps; the user
    # runs /clear #2 inside that window wanting a genuinely clean break (the
    # handoff is consumed now, so the fresh-conversation notice fires instead);
    # the child's write lands before Claude Code has replaced the watch list,
    # and the wake tells a conversation explicitly told "clean break, not a
    # continuation" to go execute a handoff it was never given.
    _stale_kick="$META_DIR/local/rotation-kick"
    if [ -d "$_stale_kick" ]; then
        : > "$_stale_kick/delivered" 2>/dev/null || true
    fi
fi

# How this turn actually begins differs by path, and the preamble has to say the
# true one. With a kick armed the turn starts on a system-reminder that no human
# sent; telling the model to wait for a user message there invites it to read
# its own wake as background noise. Without one — the opt-out, or a teammate —
# the old wording is the accurate one.
#
# Both branches keep the typed-nudge sentence that follows: the kick can lose
# the arm race, and then a word from the user is all that is left.
if [ -n "$ROTATION_KICK" ]; then
    ROTATION_START="This conversation will be woken shortly by a system-reminder rather than by a user message; that wake is the signal to begin, and no keystroke is coming."
else
    ROTATION_START="A hook can inject context but cannot start a turn, so the first message comes from the user."
fi

# The rotation preamble and the fresh-conversation notice are mutually
# exclusive: the rotate path is also a fresh start, and "clean break" plus
# "continue per the handoff" would contradict each other.
if [ -n "$ROTATION_HANDOFF" ]; then
    CONTEXT="${CONTEXT}

--- Conversation Rotation ---
This fresh conversation continues rotated work. Read .cs/handoffs/$ROTATION_HANDOFF FIRST — it is the previous conversation's handoff; the prior transcript is not loaded, and the handoff plus .cs/memory/narrative.*.md carry the context.

Nothing has run yet. $ROTATION_START A BARE NUDGE — \"go\", \"continue\", \"ok\" — means begin: execute the handoff's next-step section and report what you did, without re-summarising it or asking which part to start with. A first message carrying its own content takes precedence over the handoff; answer that instead. Ask first only where you normally would: the handoff is missing, unreadable, or genuinely ambiguous, or its next step is destructive or irreversible."
elif [ -n "$FRESH_NOTICE" ]; then
    CONTEXT="${CONTEXT}

--- Fresh Conversation ---
The user explicitly started a fresh conversation in this cs session — the prior conversation's transcript is not loaded. Treat this as a clean break, not a continuation.

For prior context, lazily consult as needed:
- .cs/memory/narrative.*.md — findings and decisions from earlier work (append only to your own actor's file; older sections under .cs/narrative-archive/<actor>/)
- .cs/README.md            — session objective

Do not assume continuity with previous turns."
fi

# Append crash recovery info if present
if [ -n "${CRASH_CONTEXT:-}" ]; then
    # %b here is safe and deliberate, unlike the Session State block above: this
    # skeleton is built with \n escapes throughout, and every value interpolated
    # into it is either a count, a validated session name, or git output — and
    # git quotes a backslash in a path as \\ (core.quotePath), which %b renders
    # back to one literal backslash rather than an escape. Measured, not assumed:
    # a file named a\033[31mred.txt reaches this block as "a\\033[31mred.txt".
    # Do not add a scrub here without first demonstrating a reachable input.
    CONTEXT="${CONTEXT}

--- $(printf '%b' "$CRASH_CONTEXT")"
fi

# Queue inbox digest (surface-once; same recipe as scope-prompt.sh).
DIGEST=""
DIGEST_PENDING=""
_build_digest "$META_DIR/local"
if [ -n "$DIGEST" ]; then
    CONTEXT="${CONTEXT}

--- $DIGEST"
fi

# Mail is surfaced by scope-prompt.sh on every prompt (persistent, anchored on
# the maildir's new/),
# so session-start no longer emits a mail digest — doing both would double-inject
# the same unread bodies on every startup and resume.

# Arm the idle mail wake: hand Claude Code the maildir to watch, so mail
# arriving while this session sits at the prompt still reaches it.
#
# The directory must exist before the path is emitted. Claude Code passes
# watchPaths to its file watcher with no existence check, and a watch armed on a
# path missing two levels — both mail/ and new/ — never fires again for the
# process's lifetime, even once the directories appear and a message is renamed
# in. The maildir is created lazily on first send or read, so a session that has
# never exchanged mail is exactly that case: every fresh spawn worker, which is
# the population the wake exists for.
#
# Only the lead arms it. Every claude resolving this session runs this hook,
# teammates included, and N watchers on one maildir means one arrival wakes N
# processes that then race to read it, where the first mv wins.
MAIL_WATCH=""
if [ "$IS_LEAD" = 1 ] \
    && mkdir -p "$META_DIR/local/mail/tmp" "$META_DIR/local/mail/new" \
                "$META_DIR/local/mail/cur" 2>/dev/null; then
    MAIL_WATCH="$META_DIR/local/mail/new"
fi

# A /clear on an armed handoff consumes it and injects the preamble above, but
# the user still has to say "go". That is a real gap and this hook CANNOT close
# it. SessionStart accepts an `initialUserMessage` field that looks like the
# answer — it is parsed, stored, and its only consumer calls prependUserMessage
# on the stdin line-reader, which exists solely for --input-format stream-json.
# An interactive TUI has no such stream, so the field is silently dropped.
# Measured end to end (2.1.252, logged in, real terminal): the handoff flipped
# to consumed and no turn began. Do not re-add it.
#
# What DOES auto-start a turn interactively is claude's positional prompt
# argument, which cs already uses for spawn kicks and for the `r` answer at the
# launch prompt (lib/40-state.sh's _exec_fresh_rebind). That is a launch-path
# mechanism: cs must exec claude to use it, which a hook running inside an
# already-started conversation cannot do. Closing the /clear gap therefore
# belongs on the launch side, not here.

# Tell the USER what the injected context cannot tell them: the rotation is
# armed and loaded, and one word starts it. systemMessage is a top-level hook
# field rendered to the person, not to the model — the only channel a hook has
# to them. Without it the fresh conversation looks idle for no stated reason,
# and the handoff it is holding is invisible.
# Only on clear. ROTATION_HANDOFF also resolves on `startup`, but that is the
# r-answer path, where _exec_fresh_rebind has already handed claude a positional
# prompt — the turn is starting as the user reads this, so "send any message"
# would be false. A /clear is the one route with no kick behind it.
# Two states, two true sentences. With a kick armed the work starts on its own,
# and telling the user to type would make them race a wake that is already
# coming. Without one nothing will happen until they speak, so the instruction
# matters more, not less.
SYSTEM_MESSAGE=""
if [ -n "$ROTATION_HANDOFF" ] && [ "$SOURCE" = "clear" ]; then
    if [ -n "$ROTATION_KICK" ]; then
        SYSTEM_MESSAGE="Rotation loaded from $ROTATION_HANDOFF — continuing automatically in a moment. Type to take over instead, or if nothing happens in a few seconds, send any message to start it."
    else
        SYSTEM_MESSAGE="Rotation loaded from $ROTATION_HANDOFF — send any message (\"go\") to continue where the previous conversation left off."
    fi
fi

# Return additional context as JSON
# watchPaths is a REPLACE, not a merge, so both paths ride one array — emitting
# the kick alone would silently disarm the mailbox for the rest of the session.
jq -n --arg context "$CONTEXT" --arg watch "$MAIL_WATCH" --arg kick "$ROTATION_KICK" \
      --arg sysmsg "$SYSTEM_MESSAGE" '
[$watch, $kick] | map(select(. != "")) as $paths |
{
    hookSpecificOutput: ({
        hookEventName: "SessionStart",
        additionalContext: $context,
        statusMessage: "Loading session..."
    } + (if ($paths | length) == 0 then {} else {watchPaths: $paths} end))
}
+ (if $sysmsg == "" then {} else {systemMessage: $sysmsg} end)'

_commit_digest "$META_DIR/local"

exit 0
