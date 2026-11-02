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
# cs-shared.sh is build.sh's copy of lib/02-shared.sh: the actor rules and the
# narrative budget, one source for cs and its hooks. Same guard, same reasons.
_cs_shared="$(dirname "$0")/cs-shared.sh"
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
# shellcheck source=cs-shared.sh
[ -r "$_cs_shared" ] && "${BASH:-/bin/bash}" -n "$_cs_shared" 2>/dev/null && . "$_cs_shared"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
# Without the library there is no telling whether the session keeps its log in
# a vault, so nothing is logged rather than risk writing it in plaintext.
if ! command -v cs_private_dir >/dev/null 2>&1; then
    cs_private_dir() { return 1; }
fi
# Nor whether git tracks the session's control files, so nothing is written
# into .cs/local either.
if ! command -v cs_local_dir >/dev/null 2>&1; then
    cs_local_dir() { return 1; }
    _cs_local_dir_unknown=1
fi
# A write this hook cannot make is skipped without a word, and the link check
# on appends and new directories lives in cs-shared.sh; without the library
# they are made unchecked, as they were before the check existed.
CS_WRITE_QUIET=1
if ! command -v cs_append_inside >/dev/null 2>&1; then
    cs_append_inside() { local f="$1"; shift; { "$@" >> "$f"; } 2>/dev/null; }
    cs_mkdir_inside() { mkdir -p "$1" 2>/dev/null; }
fi
# Nor whether its handoffs sit in a vault, so no rotation is offered or consumed.
if ! command -v cs_handoff_dir >/dev/null 2>&1; then
    cs_handoff_dir() { return 1; }
fi
# Nor can the state file be rewritten under its lock, and an unlocked rewrite
# could lose cs's own update, so the state is left as it is, said so, and
# reported as not written (an outdated cs-shared.sh lacks the writer too).
if ! command -v cs_local_state_set >/dev/null 2>&1; then
    cs_local_state_set() {
        echo "session-start: cs-shared.sh is missing or outdated, so $2 was not recorded in $1" >&2
        return 1
    }
fi
# Nor is a file replaced whole without the library's writer: the digest cursor
# stays where it was and the digest repeats, and a consumed handoff keeps its
# unconsumed status line.
if ! command -v cs_write_atomic >/dev/null 2>&1; then
    cs_write_atomic() { return 1; }
fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
if ! command -v _cs_terminate_jsonl >/dev/null 2>&1; then
    _cs_terminate_jsonl() {
        [ -s "$1" ] || return 0
        [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
        cs_append_inside "$1" printf '\n' || true
    }
fi
# A name a clone chose is printed through the library's _cs_plain_name;
# without it the hook prints no such name, only "?".
if ! command -v _cs_plain_name >/dev/null 2>&1; then
    _cs_plain_name() { printf '?'; }
fi
# A rotation loads only a handoff whose name is plain; without the library's
# _cs_is_plain_name no name is, so no handoff loads.
if ! command -v _cs_is_plain_name >/dev/null 2>&1; then
    _cs_is_plain_name() { return 1; }
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
    # A line that does not parse, or parses to something other than an object,
    # is skipped: reading .event from one would fail the whole jq program, and
    # the cursor would then be spent on notifications nobody was shown.
    DIGEST=$(awk -v a=$((seen + 1)) -v b="$total" 'NR>=a && NR<=b' "$inbox" 2>/dev/null | jq -rRs '
        [split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")] as $e |
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
    cs_write_atomic "$1/notifications.seen" printf '%s\n' "$DIGEST_PENDING" 2>/dev/null || true
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
# An encrypted session logs into its vault; while the vault is locked the log
# goes nowhere, never into .cs/local.
# Every write into .cs/local goes through LOCAL_DIR, which is empty while git
# tracks a file in the session's control directories (cs_local_dir).
LOCAL_DIR=$(cs_local_dir "$META_DIR") || LOCAL_DIR=""
[ -z "$LOCAL_DIR" ] || cs_mkdir_inside "$LOCAL_DIR" || true
if _log_dir=$(cs_private_dir "$META_DIR"); then SESSION_LOG="$_log_dir/session.log"; else SESSION_LOG=/dev/null; fi
cs_append_inside "$SESSION_LOG" printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') - Session started (source: $SOURCE, ID: $SESSION_ID)" \
    "  Working directory: $CWD" "" || true

# The lead claims its launch before anything below asks which claude is the
# lead (cs_lead_claim, cs-resolve.sh). On every source: a /clear or a
# compaction renews the claim under the conversation now running.
if [ -n "$LOCAL_DIR" ] && command -v cs_lead_claim >/dev/null 2>&1; then
    cs_lead_claim "$LOCAL_DIR" "$SESSION_ID" || true
fi


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
            cs_append_inside "$SESSION_LOG" \
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Crash recovery: found ${CRASH_FILE_COUNT} unsaved file(s), awaiting user decision" || true
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
# Claude Code sources the file as shell, so each value goes in single quotes
# with every ' written as '\'' : a path holding " or $( stays data. The quote
# and its escape sit in variables because bash 3.2 mangles them as literals
# inside a double-quoted ${v//pattern/replacement}.
_cs_env_export() {  # name value
    local v="$2" sq="'" esc="'\\''"
    printf "export %s='%s'\n" "$1" "${v//$sq/$esc}"
}
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$_cs_publish_to" ]; then
    {
        _cs_env_export CLAUDE_SESSION_NAME "$CLAUDE_SESSION_NAME"
        _cs_env_export CLAUDE_SESSION_DIR "$SESSION_DIR"
        _cs_env_export CLAUDE_SESSION_META_DIR "$META_DIR"
        if [ "$_cs_publish_to" = "teammate" ]; then
            _cs_env_export CS_RESOLVED_FROM "${CS_RESOLVED_FROM:-walk}"
        fi
    } >> "$CLAUDE_ENV_FILE"
fi

# Resolve who is driving this session, for the identity anchor below, with the
# rules cs itself runs (cs_actor_raw in cs-shared.sh; shelling out to cs would
# make the hook depend on cs being on PATH). Naming an actor cs would not
# resolve is the whole defect this anchor exists to prevent, so without the
# library the hook guesses nothing: it names the gap and what closes it.
ACTOR_NOTE=""
if command -v cs_actor_raw >/dev/null 2>&1; then
    ACTOR_RAW=$(cs_actor_raw "$SESSION_DIR" "$META_DIR")
    ACTOR_SLUG=$(_slugify "$ACTOR_RAW")
else
    ACTOR_RAW="unresolved"
    ACTOR_SLUG="unknown"
    ACTOR_NOTE="
Actor unresolved: cs-shared.sh is missing or broken beside this hook, so the actor rules could not run. Run ./install.sh from the cs checkout (or cs -update) to redeploy the hooks, then cs -whoami."
fi

# Provide context to Claude about the session
# Sampled once: the day the context block names below is the day the stamp at
# the end records, so a startup that straddles midnight cannot tell the model
# one date and file another.
CONTEXT_LOADED=$(date '+%Y-%m-%d %H:%M:%S %Z')
CONTEXT_DAY=${CONTEXT_LOADED%% *}
# A feature session has two addresses (cs_claude_name): named here so the
# model never hands a peer the spelling SendMessage refuses.
NAME_NOTE=""
[[ "$CLAUDE_SESSION_NAME" != *@* ]] || NAME_NOTE="
Claude Code's own tools (ListAgents, SendMessage) know this session as $(cs_claude_name "$CLAUDE_SESSION_NAME"); cs (cs -msg, cs -rm, the directory) takes $CLAUDE_SESSION_NAME."
CONTEXT=$(cat << EOF
You are working in a managed Claude Code session: $CLAUDE_SESSION_NAME$NAME_NOTE
Context loaded: $CONTEXT_LOADED ($(date -u +%Y-%m-%dT%H:%M:%SZ))

Session directory: $CLAUDE_SESSION_DIR

Session metadata is in the .cs/ directory. The session root is your workspace.

Current actor: $ACTOR_SLUG ($ACTOR_RAW). Your narrative is .cs/memory/narrative.$ACTOR_SLUG.md.${ACTOR_NOTE}
.cs/memory/ is shared by multiple actors, but only narratives are partitioned: a durable memory entry naming someone else as the user was written by or for another actor and does not describe who you are talking to. Identity comes from this line and the live environment, never from a memory entry.

Key files to maintain:
- .cs/README.md: Update objective and outcome
- .cs/memory/narrative.$ACTOR_SLUG.md: append findings as you go; on resume read it in full; of a teammate narrative only the lines the resume digest names (older sections: .cs/narrative-archive/<actor>/, grep on demand)

Secrets: never write credentials to project files — feed the value to 'cs -secrets set <name>' on stdin via a file redirect (argv, pipes and heredocs are all logged verbatim); retrieve with 'cs -secrets get <name>'. See CLAUDE.local.md, Secure Secrets Handling.

See CLAUDE.local.md in the session directory for complete documentation protocol.
EOF
)

# Set a key in the machine-local state file (.cs/local/state, gitignored —
# these values differ per machine, so they must never reach the git-synced
# README). Replaces any existing line for the key, collapses duplicates.
# Atomic and serialised against cs's own writer through cs_local_state_set.
STATE_FILE="$META_DIR/local/state"
local_state_set() {
    if [ -z "$LOCAL_DIR" ]; then
        # A tracked control directory is reported by the Stop hook; a missing
        # library is said here, because nothing else names what it cost.
        [ -z "${_cs_local_dir_unknown:-}" ] \
            || echo "session-start: cs-shared.sh is missing or outdated, so $1 was not recorded in $STATE_FILE" >&2
        return 1
    fi
    cs_mkdir_inside "$LOCAL_DIR" || return 1
    cs_local_state_set "$STATE_FILE" "$1" "$2"
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
# An encrypted session keeps both the marker and its handoffs in the vault; a
# locked one has neither to offer.
ROTATION_HANDOFF=""
ROTATION_HANDOFF_SHOWN=""
PENDING_MARKER=""
HANDOFF_DIR=""
if _marker_dir=$(cs_private_dir "$META_DIR") && HANDOFF_DIR=$(cs_handoff_dir "$META_DIR"); then
    PENDING_MARKER="$_marker_dir/pending-handoff"
fi
HANDOFF_REL=".cs/${HANDOFF_DIR#"$META_DIR"/}"
# A claude started from inside the session (a `claude -p` the lead's Bash tool
# ran) fires this hook with the lead's contract in its environment, and a tmux
# teammate fires it as a full claude of its own. The armed rotation and the
# queue's once-only digest belong to the lead: such a guest is neither handed
# them nor clears them. A front end that walked in is no guest: it is the
# conversation the user is in, and its /clear loads the rotation. A claude
# shown to be the lead is asked nothing further: the teammate check reads the
# command line, and a launch prompt can hold the flags it looks for.
IS_GUEST=0
if command -v cs_is_lead >/dev/null 2>&1 && cs_is_lead; then
    :
elif command -v cs_is_shown_nested_child >/dev/null 2>&1 && cs_is_shown_nested_child; then
    IS_GUEST=1
elif command -v _cs_is_teammate >/dev/null 2>&1 && _cs_is_teammate; then
    IS_GUEST=1
fi
case "$SOURCE" in
    startup|clear)
        if [ "$IS_GUEST" != 1 ] && [ -n "$PENDING_MARKER" ] && [ -f "$PENDING_MARKER" ]; then
            HANDOFF_BASENAME=$(cat "$PENDING_MARKER" 2>/dev/null | tr -d '[:space:]' || true)
            # The marker names a basename. Anything with a separator would
            # resolve outside the handoff store, and the file it landed on
            # would be rewritten and then named to Claude as the handoff.
            # Backslash counts too: nothing cs writes here contains one, so
            # rejecting it costs nothing and closes a spelling of the same idea.
            case "$HANDOFF_BASENAME" in
                */*|*\\*) HANDOFF_BASENAME="" ;;
            esac
            # .cs/handoffs/ is tracked, so a clone chooses the file name. Only
            # a plain one loads, so the name Claude is told is the file itself.
            _cs_is_plain_name "$HANDOFF_BASENAME" || HANDOFF_BASENAME=""
            HANDOFF_FILE="$HANDOFF_DIR/$HANDOFF_BASENAME"
            if [ -n "$HANDOFF_BASENAME" ] && [ -f "$HANDOFF_FILE" ] \
                && _handoff_is_unconsumed "$HANDOFF_FILE"; then
                ROTATION_HANDOFF="$HANDOFF_BASENAME"
                # .cs/handoffs/ is tracked, so a clone chooses the file name:
                # it is printed as a plain name.
                ROTATION_HANDOFF_SHOWN=$(_cs_plain_name "$ROTATION_HANDOFF" 160)
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
# cs_is_lead (cs-resolve.sh) says which claude is the launch: the one carrying
# the launch pid, or the one the claim made above names (the resume arm's
# claude is cs's child because it needs the exit status to fall through to a
# fresh rebind when there is nothing to resume). Without the library nothing is
# the lead: declining the slot is the safe side.
IS_LEAD=0
if command -v cs_is_lead >/dev/null 2>&1 && cs_is_lead; then
    IS_LEAD=1
fi
if [ "$IS_LEAD" = 1 ] && [[ "$SESSION_ID" =~ $UUID_RE ]]; then
    RECORDED_UUID=$(awk '/^claude_session_id:/ { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)
    if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then
        local_state_set claude_session_id "$SESSION_ID" \
            && { cs_append_inside "$SESSION_LOG" echo "$(date '+%Y-%m-%d %H:%M:%S') - Rebound claude_session_id: ${RECORDED_UUID:-none} -> $SESSION_ID" || true; }
        # Named literally: TIMELINE_FILE is not assigned until further down.
        _cs_terminate_jsonl "$META_DIR/timeline.jsonl" 2>/dev/null || true
        # Durable lineage: a UUID change the launch path did not pre-record.
        # With a marker resolved above it is a deliberate in-process rotation
        # (/clear) and carries the handoff name; otherwise it is one cs
        # discovered — CC's context-limit fork, or a manual resume of a
        # different conversation. Shape shared with bin/cs's _timeline_rotated.
        # An encrypted session's handoff name is its topic: the plaintext
        # timeline records that a handoff rotated, never which.
        _public_handoff="$ROTATION_HANDOFF"
        [ "$HANDOFF_REL" = ".cs/handoffs" ] || _public_handoff=""
        cs_append_inside "$META_DIR/timeline.jsonl" jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --arg from "${RECORDED_UUID:-}" \
               --arg to "$SESSION_ID" \
               --arg handoff "$ROTATION_HANDOFF" \
               --arg name "$_public_handoff" \
               '{ts: $ts, event: "rotated", from: $from, to: $to,
                 reason: (if $handoff == "" then "rebind" else "handoff" end)}
                + (if $name == "" then {} else {handoff: $name} end)' \
            || true
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
cs_append_inside "$TIMELINE_FILE" jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg event "started" \
       --arg source "$SOURCE" \
       --arg session_id "$SESSION_ID" \
       --arg branch "$TIMELINE_BRANCH" \
       '{ts: $ts, event: $event, source: $source, session_id: $session_id, branch: $branch}' \
    || true

# Update last_resumed in local state on resume
if [ "$SOURCE" = "resume" ]; then
    local_state_set last_resumed "$(date '+%Y-%m-%d')" || true
fi

# A fresh session is attended by definition: drop any stale attention
# marker left by the previous conversation's final Stop.
[ -z "$LOCAL_DIR" ] || rm -f "$LOCAL_DIR/attention" 2>/dev/null || true

# iTerm2: also cancel any dock bounce the previous conversation left running.
# Mirrors the guard in narrative-reminder.sh (hooks are standalone).
if [ -z "${CS_NO_ITERM2:-}" ] && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    _it2="${CS_IT2_DIR:-$HOME/.iterm2}/it2attention"
    { [ -x "$_it2" ] && "$_it2" stop > "${CS_IT2_TTY:-/dev/tty}"; } 2>/dev/null || true
fi

# Re-assert this session's tab title. cs sets it once at launch and the reset
# in its EXIT trap never runs, because cs execs into claude; a nested launch on
# the same tty (`cs other` from the `!` prefix) leaves "cs: other" on this
# session's tab for the rest of the conversation. Inside tmux the title goes
# through the server, which needs no tty, and select-pane -T is not subject to
# the allow-set-title lock the launch applied. Outside tmux the OSC 0 escape
# has to reach the terminal itself, and a hook's stdout is Claude's, so it is
# written to the terminal device; a front end without one (the desktop app)
# skips it. Same value the launch set, so no new consent is asked. Lead only:
# Claude Code titles a teammate's pane with the agent's name, and the tab this
# repairs is the launched conversation's. Under `cs <name> --remote` the lead
# is a conversation the server started from the phone, and the window and tab
# are the server's, named remote:<name> (tmux) or `cs: <name> (remote)` by its
# launch: while .cs/local/remote.pid names a server running remote-control for
# this session (_remote_server_pid, cs-shared.sh) no title is set, inside tmux
# or out, so that name stays.
_title="cs: $CLAUDE_SESSION_NAME"
if [ "$IS_LEAD" != 1 ]; then
    :
elif command -v _remote_server_pid >/dev/null 2>&1 \
    && _remote_server_pid "$META_DIR" "$CLAUDE_SESSION_NAME" >/dev/null; then
    :
elif [ -n "${TMUX:-}" ]; then
    # An empty array is unbound under bash 3.2's set -u, hence the expansion.
    _pane="${TMUX_PANE:-}"
    tmux select-pane ${_pane:+-t "$_pane"} -T "$_title" 2>/dev/null || true
    # The window, which is the tab, is shared with any other pane's session.
    if command -v cs_tmux_title_window >/dev/null 2>&1 && [ -n "$_pane" ]; then
        cs_tmux_title_window "$_pane" "$CLAUDE_SESSION_NAME"
    else
        tmux rename-window ${_pane:+-t "$_pane"} "$_title" 2>/dev/null || true
    fi
else
    # Braced so the redirection failure itself is silenced: a trailing
    # 2>/dev/null applies after the `>` has already reported.
    { printf '\033]0;%s\007' "$_title" > "${CS_TITLE_TTY:-/dev/tty}"; } 2>/dev/null || true
fi

# A narrative over its budget. The protocol above says to read your own in
# full, and the Read tool refuses a file over 256 KiB; the budget sits under
# that ceiling so the file is still readable once, but every append moves it
# closer, and nothing rotates it but the user's own verb (rotation commits, and
# cs never commits on its own). So the same payload that says "read it" says
# "rotate first" for that file. Every source and every actor, not the lead
# alone: a teammate's SessionStart reads the same files. The budget and its
# validation come from cs-shared.sh; without the library the budget is unknown,
# and a warning built on a guessed number is worse than none, so the check
# is skipped (the actor line above already says the library is missing).
NARRATIVE_MAX=""
if command -v _narrative_budget >/dev/null 2>&1; then
    NARRATIVE_MAX=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
fi
NARRATIVE_OVER=""
for _nf in "$META_DIR"/memory/narrative.*.md; do
    [ -n "$NARRATIVE_MAX" ] || break
    [ -f "$_nf" ] || continue
    _sz=$(wc -c < "$_nf" 2>/dev/null | tr -d ' ' || echo 0)
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    [ "$_sz" -gt "$NARRATIVE_MAX" ] || continue
    _nb=$(basename "$_nf")
    if [ "$_nb" = "narrative.$ACTOR_SLUG.md" ]; then
        _whose="yours: run \`cs -narrative rotate\` BEFORE reading it in full (the Read tool refuses a file over 256 KiB)"
    else
        _whose="not yours: read it only from the line the digest names, never whole"
    fi
    NARRATIVE_OVER="${NARRATIVE_OVER}- $(_cs_plain_name "$_nb" 160) is $((_sz / 1024)) KB, over the $((NARRATIVE_MAX / 1024)) KB budget; $_whose
"
done
if [ -n "$NARRATIVE_OVER" ]; then
    CONTEXT="${CONTEXT}

--- NARRATIVE OVER BUDGET ---
${NARRATIVE_OVER}"
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
    LAST_LOG_TIME=$(tail -1 "$SESSION_LOG" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1 || true)
    if [ -n "$LAST_LOG_TIME" ]; then
        DYNAMIC="${DYNAMIC}Last activity: ${LAST_LOG_TIME}${_NL}"
    fi

    # Recent commits since last session
    COMMIT_COUNT=$(git -C "$SESSION_DIR" rev-list --count --since="7 days ago" HEAD 2>/dev/null || echo "0")
    if [ "$COMMIT_COUNT" -gt 0 ]; then
        # The session's repo chooses the file names, and git quotes a control
        # byte in one but not a shell metacharacter, so only a plain name is
        # listed. Each check forks, so only the first five files are checked,
        # however many the commits touched.
        RECENT_FILES=$(git -C "$SESSION_DIR" diff --name-only "HEAD~${COMMIT_COUNT}" HEAD 2>/dev/null \
            | head -5 | while IFS= read -r _recent; do
                _cs_is_plain_name "${_recent##*/}" && printf '%s\n' "${_recent##*/}"
            done | paste -sd', ' - 2>/dev/null || true)
        DYNAMIC="${DYNAMIC}Recent commits: ${COMMIT_COUNT} in last 7 days"
        if [ -n "$RECENT_FILES" ]; then
            DYNAMIC="${DYNAMIC} (${RECENT_FILES})"
        fi
        DYNAMIC="${DYNAMIC}${_NL}"
    fi

    # Per-actor digest: shared memory/narrative activity since this actor last looked.
    [ -z "$LOCAL_DIR" ] || cs_mkdir_inside "$LOCAL_DIR" || true
    WATERMARK_FILE="$META_DIR/local/watermark"
    LAST_SEEN=""
    [ -f "$WATERMARK_FILE" ] && LAST_SEEN=$(cat "$WATERMARK_FILE" 2>/dev/null || true)
    HEAD_SHA=$(git -C "$SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
    if [ -n "$LAST_SEEN" ] && [ -n "$HEAD_SHA" ] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "$LAST_SEEN" >/dev/null 2>&1; then
        # The clone's history chooses its author names, and git keeps a control
        # byte in one: each is printed as a plain name.
        DIGEST=$(git -C "$SESSION_DIR" log --no-merges --format='%an' "$LAST_SEEN..HEAD" -- .cs/memory 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | while read -r _count _author; do
                printf '%s (%s)\n' "$(_cs_plain_name "$_author" 160)" "$_count"
            done \
            | paste -sd', ' - 2>/dev/null || true)
        # Reading a whole teammate narrative is not an option (one dormant
        # file measured 801 KB); the digest names where each one grew
        # instead. The watermark commit is compared against the WORKING TREE,
        # not HEAD: in a shared-directory tmux team nobody commits .cs/memory,
        # so committed-only growth would leave every teammate notebook unread.
        # Uncommitted growth is therefore named again on each resume until it
        # is committed. The first line of new content is the start of the
        # LAST hunk that adds lines, read from the diff's own headers: growth
        # is appended, so it is the final hunk, while a head edit (the
        # migration rewriting a description line, a dated correction) or a
        # head-truncating rotation cannot move it. The actor's own file is
        # read in full and is not a delta. A narrative nobody has committed
        # has nothing to measure against, so it goes unmentioned rather than
        # named whole on every resume.
        NARRATIVE_DELTA=""
        # Append one teammate narrative's growth to NARRATIVE_DELTA as the
        # sentence the model reads; the actor's own narrative is skipped.
        _add_delta() {  # path sections start
            [ "$1" = ".cs/memory/narrative.$ACTOR_SLUG.md" ] && return 0
            NARRATIVE_DELTA="${NARRATIVE_DELTA}${NARRATIVE_DELTA:+; }$1: $2 new section(s) from line $3"
        }
        while IFS=$'\t' read -r _added _deleted _path; do
            case "$_path" in .cs/memory/narrative.*.md) ;; *) continue ;; esac
            # A clone chooses the file name and Claude is told the path to
            # read. git quotes a control byte in it but not a shell
            # metacharacter, so only a plain name is named, as only a plain
            # rotation handoff loads. The case pattern's * matches "/", so the
            # whole path below .cs/memory is checked: a narrative is one file
            # there, never one in a subdirectory.
            _cs_is_plain_name "${_path#.cs/memory/}" || continue
            # A link named like a narrative leads where the clone chose, so
            # only a regular file is named for Claude to read.
            [ -f "$SESSION_DIR/$_path" ] && [ ! -L "$SESSION_DIR/$_path" ] || continue
            case "$_added" in ''|-|0) continue ;; esac
            # One pass for both numbers: the diff of a rotated narrative is
            # the size of the file, and piping it twice costs two copies of it.
            # Only @@ lines are read, so a mnemonic-prefix diff config cannot
            # change what this parses.
            _delta=$(git -C "$SESSION_DIR" diff -U0 "$LAST_SEEN" -- "$_path" 2>/dev/null \
                | awk '/^@@/ { split($3, p, ","); n = (p[2] == "" ? 1 : p[2]); if (n > 0) s = substr(p[1], 2); next }
                       /^\+## / { sec++ }
                       END { if (s != "") printf "%s %s", sec + 0, s }' || true)
            [ -n "$_delta" ] || continue
            _add_delta "$_path" ${_delta}
        done <<NUMSTAT
$(git -C "$SESSION_DIR" diff --numstat --relative "$LAST_SEEN" -- .cs/memory 2>/dev/null || true)
NUMSTAT
        DELTA_TAIL=""
        if [ -n "$NARRATIVE_DELTA" ]; then
            DELTA_TAIL="teammate narratives grew: ${NARRATIVE_DELTA}. Read your own narrative.$ACTOR_SLUG.md in full, and of theirs only those added lines (sed -n 'N,\$p'), never the whole file."
        elif [ -n "$DIGEST" ]; then
            DELTA_TAIL="no teammate narrative grew; read your own narrative.$ACTOR_SLUG.md in full and none of theirs."
        fi
        DELTA_LINE=""
        if [ -n "$DIGEST" ]; then
            DELTA_LINE="Since your last session, teammates committed to shared memory/narrative (author: commits): ${DIGEST}; ${DELTA_TAIL}"
        elif [ -n "$DELTA_TAIL" ]; then
            DELTA_LINE="Since your last session, ${DELTA_TAIL}"
        fi
        [ -n "$DELTA_LINE" ] && DYNAMIC="${DYNAMIC}${DELTA_LINE}${_NL}"
    fi
    # Advance the watermark to current HEAD (also seeds it on first resume).
    [ -z "$HEAD_SHA" ] || [ -z "$LOCAL_DIR" ] || cs_write_atomic "$WATERMARK_FILE" echo "$HEAD_SHA" || true

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
        # Sort sibling sessions by session.log mtime (most recent first). An
        # encrypted session logs into .cs/private and so is never listed: its
        # objective must not reach another session's conversation.
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
            DYNAMIC="${DYNAMIC}Other Sessions — when a request substantially matches one of these objectives, not merely its vocabulary, ask via AskUserQuestion whether to hand it over before starting the work here. Offer both: do it here, or send it there. Be picky, the way the wrap-up cue is: a request that only brushes a sibling's subject belongs here, and a prompt that fires on every overlap becomes the block nobody reads.${_NL}${SIBLINGS}To hand one a task or note: cs -msg <session> \"<body>\"${_NL}Add --kind notify|task|text|result (default text; a task waits in that session's mailbox until its user accepts it with cs -queue accept <id>).${_NL}"
        fi
    fi

    # Unconditional, so it also prints when nothing above had anything to report.
    DYNAMIC="${DYNAMIC}The conversation before this one may have finished actions its summary does not show; check git log, cs -msg log and the remote before repeating a push, a merge, an install or a message.${_NL}"

    if [ -n "$DYNAMIC" ]; then
        # %s, not %b: escapes in interpolated content are data. Scrubbed once
        # here because DYNAMIC carries text cs did not write — a sibling
        # session's README objective, git author names, commit subjects — and
        # the range keeps tab and newline, so the block's own breaks survive.
        CONTEXT="${CONTEXT}

--- Session State ---
$(printf '%s' "$DYNAMIC" | env LC_ALL=C tr -d '\000-\010\013-\037\177')"
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

To integrate this feature, ask the user to run /finish $TASK_NAME in session $CS_BASE: it merges a captured commit into the base after the gates pass there, then retires this worktree — fuses the session records (timeline, narrative) into the base and removes the worktree and branch. That removal needs this conversation closed first: a directory cannot be removed from under a running Claude, so while this conversation is live /finish stages the retire in the base, and the base runs it by itself once the user closes this session; nothing else is asked of them. Say that plainly when the user asks; never try to close, exit or remove anything from here.
Do NOT merge $TASK_BRANCH into the base branch manually and do not delete the branch — that bypasses the record fuse and the cleanup. To abandon the feature instead, ask the user to run: cs -rm $CLAUDE_SESSION_NAME — never run this yourself; it deletes this worktree and its session records."
fi

# Consume the rotation resolved above: flip the handoff's frontmatter to
# consumed, record the consumer, and drop the marker. Only the first status
# line (the frontmatter's) flips; a body quoting it flush-left stays intact.
if [ -n "$ROTATION_HANDOFF" ]; then
    HANDOFF_FILE="$HANDOFF_DIR/$ROTATION_HANDOFF"
    cs_write_atomic "$HANDOFF_FILE" awk -v uuid="$SESSION_ID" '
        !flipped && $0 == "status: unconsumed" {
            print "status: consumed"
            print "consumed_by: " uuid
            flipped = 1
            next
        }
        { print }
    ' "$HANDOFF_FILE" 2>/dev/null || true
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
# the default delay has room without being a visible pause. But the child's clock
# starts at its spawn, not at the arm: the arm waits for the REST of this hook,
# which took 4.4 s on an idle machine and 21 s under a parallel test suite
# (transcript durationMs), and a write landing before the arm is an event nobody
# hears. So the child re-writes every delay until the wake records `delivered`,
# bounded well past the hook's 30 s registration timeout, after which no watch
# can arm at all.
#
# Scoped like the notice below: only a /clear that loaded a rotation. The startup
# path is the r-answer, where _exec_fresh_rebind has already handed claude a
# positional prompt — a wake there would arrive on top of a running turn.
# Lead-only for the same reason the mail watch is: every claude resolving this
# session runs this hook, and N kicks means N sessions racing on one rotation.
ROTATION_KICK=""
if [ -n "$ROTATION_HANDOFF" ] && [ "$SOURCE" = "clear" ] && [ "$IS_LEAD" = 1 ] \
    && [ -z "${CS_NO_ROTATION_WAKE:-}" ]; then
    _kick_dir="$LOCAL_DIR/rotation-kick"
    # The watcher is handed the path with no existence check, and a watch armed
    # on a missing directory never fires again for the process's lifetime.
    if [ -n "$LOCAL_DIR" ] && cs_mkdir_inside "$_kick_dir"; then
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
                cs_write_atomic "$_kick_dir/rotation.kick" date +%s
            }
            # Every write lost before the arm leaves the session idle under a
            # notice promising it would continue on its own, so keep writing: a
            # rename-over re-enters the wake branch (the triage filters only
            # unlink), and the delivered marker — set by the wake, or by a later
            # /clear that arms nothing — ends the loop. 30 writes at the default
            # 2 s delay cover a minute.
            #
            # A child from an earlier rotation still looping when a later /clear
            # removes `delivered` writes into the same directory: benign, since
            # that rotation wants a kick too and the wake reads no generation.
            # Do not add a per-rotation token for this.
            # A zero delay waits for no arm, so retrying buys nothing: it writes
            # once. Thirty back-to-back writes would also race whatever removes
            # the directory next.
            _kick_max=30
            [ "$_kick_delay" != 0 ] || _kick_max=1
            _kick_tries=0
            while [ "$_kick_tries" -lt "$_kick_max" ] && [ ! -f "$_kick_dir/delivered" ]; do
                [ "$_kick_delay" = 0 ] || sleep "$_kick_delay"
                [ -f "$_kick_dir/delivered" ] || _write_kick || true
                _kick_tries=$((_kick_tries + 1))
            done
        ) </dev/null >/dev/null 2>&1 &
    fi
elif [ "$SOURCE" = "clear" ] && [ "$IS_LEAD" = 1 ]; then
    # A lead /clear that arms nothing must SPEND any kick still in flight from a
    # previous one. Otherwise: /clear #1 arms and its child sleeps; the user
    # runs /clear #2 inside that window wanting a genuinely clean break (the
    # handoff is consumed now, so the fresh-conversation notice fires instead);
    # the child's write lands before Claude Code has replaced the watch list,
    # and the wake tells a conversation explicitly told "clean break, not a
    # continuation" to go execute a handoff it was never given.
    #
    # Lead-only: a teammate's /clear would otherwise stop the lead's retries
    # and make the lead's own wake decline.
    _stale_kick="$LOCAL_DIR/rotation-kick"
    if [ -n "$LOCAL_DIR" ] && [ -d "$_stale_kick" ]; then
        cs_write_atomic "$_stale_kick/delivered" : || true
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
This fresh conversation continues rotated work. Read $HANDOFF_REL/$ROTATION_HANDOFF_SHOWN FIRST — it is the previous conversation's handoff; the prior transcript is not loaded, and the handoff plus your own .cs/memory/narrative.$ACTOR_SLUG.md carry the context.

Nothing has run yet. $ROTATION_START A BARE NUDGE — \"go\", \"continue\", \"ok\" — means begin: reconcile your native task list, which carried over from the previous conversation, with the handoff (mark what it says is done, add any next-step step that is missing, one task per step), then execute the next step and report what you did, without re-summarising it or asking which part to start with. A first message carrying its own content takes precedence over the handoff; answer that instead. Ask first only where you normally would: the handoff is missing, unreadable, or genuinely ambiguous, or its next step is destructive or irreversible.

Once that next step is done, append a \`## Successor report\` section to the end of $HANDOFF_REL/$ROTATION_HANDOFF_SHOWN: each thing you had to look up again, re-derive, or found wrong in the handoff, with how you found out, or \`none\`. Append only; never rewrite what the previous conversation wrote."
elif [ -n "$FRESH_NOTICE" ]; then
    CONTEXT="${CONTEXT}

--- Fresh Conversation ---
The user explicitly started a fresh conversation in this cs session — the prior conversation's transcript is not loaded. Treat this as a clean break, not a continuation.

For prior context, lazily consult as needed:
- .cs/memory/narrative.$ACTOR_SLUG.md — your findings and decisions from earlier work (append only here; a teammate's narrative only from the line the resume digest names; older sections under .cs/narrative-archive/<actor>/)
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
# The inbox sits behind .cs/private in an encrypted session; a locked vault has
# nothing readable, and DIGEST_DIR stays empty so no cursor is written.
DIGEST_DIR=""
if [ "$IS_GUEST" != 1 ] && DIGEST_DIR=$(cs_private_dir "$META_DIR"); then _build_digest "$DIGEST_DIR"; else DIGEST_DIR=""; fi
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
#
# The maildir sits with the session's other cs files (behind .cs/private in an
# encrypted session); a locked vault arms no watch rather than a plaintext one.
MAIL_WATCH=""
if [ "$IS_LEAD" = 1 ] && _mail_base=$(cs_private_dir "$META_DIR") \
    && cs_mkdir_inside "$_mail_base/mail/tmp" && cs_mkdir_inside "$_mail_base/mail/new" \
    && cs_mkdir_inside "$_mail_base/mail/cur"; then
    MAIL_WATCH="$_mail_base/mail/new"
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
        SYSTEM_MESSAGE="Rotation loaded from $ROTATION_HANDOFF_SHOWN — continuing automatically in a moment. Type to take over instead, or if nothing happens in a few seconds, send any message to start it."
    else
        SYSTEM_MESSAGE="Rotation loaded from $ROTATION_HANDOFF_SHOWN — send any message (\"go\") to continue where the previous conversation left off."
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

_commit_digest "$DIGEST_DIR"

# The context block above told the conversation today's date. Record which day
# this conversation heard, one file per conversation, so scope-prompt.sh can say
# when the day has moved on. Written after the emit, so a hook killed before
# delivery leaves no stamp claiming the date was heard. The id becomes a
# filename: anything outside the uuid alphabet, or dot-led like the temp files
# beside it, is not stamped.
case "$SESSION_ID" in
    ''|.*|*[!A-Za-z0-9._-]*) ;;
    *)
        [ -z "$LOCAL_DIR" ] || { cs_mkdir_inside "$LOCAL_DIR/context-date" \
            && cs_write_atomic "$LOCAL_DIR/context-date/$SESSION_ID" printf '%s\n' "$CONTEXT_DAY"; } || true
        ;;
esac

exit 0
