#!/usr/bin/env bash
# ABOUTME: Async Stop hook for the turn-end notices: rotation nudge, context warning and
# ABOUTME: narrative reminder with its advisor note, handed to the model with the next prompt

set -euo pipefail

# Registered with "async": true. A synchronous Stop hook that hands the model
# text, as a block's reason or as additionalContext, always draws Claude Code's
# "Ran N stop hooks" row in the chat, and nothing a hook prints can hide it. An
# async hook that exits 0 with additionalContext draws no row, and its text
# reaches the model as context at the start of the user's next prompt. The
# price is that it forces no turn: the model acts on a notice at the next
# prompt, not at the end of the turn that raised it. Every notice here can wait
# for that; whatever must continue the turn (the queue drain, the staged
# retire, the mail wake) stays a block in narrative-reminder.sh.
#
# At most one JSON object per run, and nothing when there is nothing to say.
# The tiers below decide in order and the first that applies takes the slot,
# which is what keeps the rotation nudge and the context warning from both
# firing on one Stop; three scripts running side by side could not see each
# other's decision.

# Read hook input (may be empty for legacy Stop events)
INPUT=$(cat 2>/dev/null || echo '{}')

# Stop carries no name on legacy input, so an absent value means Stop.
# Unit separator, not tab: tab is IFS whitespace, so bash collapses runs of it
# and an absent field (agent_id is empty on every top-level event) would shift
# the next field one place left.
HOOK_EVENT=Stop; AGENT_ID=""
IFS=$'\037' read -r HOOK_EVENT AGENT_ID <<EOF
$(printf '%s' "$INPUT" | jq -r '[.hook_event_name // "Stop", .agent_id // ""] | join("\u001f")' 2>/dev/null || printf 'Stop')
EOF
[ -n "$HOOK_EVENT" ] || HOOK_EVENT=Stop
[ "$HOOK_EVENT" = "Stop" ] || exit 0

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
[ -z "$AGENT_ID" ] || exit 0

# The library source follows narrative-reminder.sh, which carries the reasons:
# test before sourcing (bash 3.2 kills the shell on a `.` of a missing file),
# parse-check first (a truncated library aborts at its syntax error), and
# errexit suspended across the source (a library that parses clean can still
# fail when run). A missing or broken library leaves the fallbacks below.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
_cs_shared="$(dirname "$0")/cs-shared.sh"
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
unset CS_TRACKED_FILES_NOTICE CS_TRACKED_FILES_META
set +e
# shellcheck source=cs-resolve.sh
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
# shellcheck source=cs-shared.sh
[ -r "$_cs_shared" ] && "${BASH:-/bin/bash}" -n "$_cs_shared" 2>/dev/null && . "$_cs_shared"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Without the library no claude is shown to be the lead, so the notices that
# are the lead's stay silent.
if ! command -v cs_is_lead >/dev/null 2>&1; then
    cs_is_lead() { return 1; }
fi
# Without the library the hook cannot tell whether the session keeps its
# queue in a vault, so it reads no queue at all.
if ! command -v cs_private_dir >/dev/null 2>&1; then
    cs_private_dir() { return 1; }
fi
if ! command -v cs_write_atomic >/dev/null 2>&1; then
    cs_write_atomic() { return 1; }
fi
# A write this hook cannot make is skipped without a word (cs-shared.sh).
CS_WRITE_QUIET=1
# The link check on appends lives in the library too; without it they are
# made unchecked, as they were before the check existed.
if ! command -v cs_append_inside >/dev/null 2>&1; then
    cs_append_inside() { local f="$1"; shift; { "$@" >> "$f"; } 2>/dev/null; }
fi
# A name a clone chose is printed through the library's _cs_plain_name;
# without it the hook prints no such name, only "?".
if ! command -v _cs_plain_name >/dev/null 2>&1; then
    _cs_plain_name() { printf '?'; }
fi

# Printed as decimal: a leading zero would reach the callers' arithmetic as
# an octal literal, and `08` aborts it. Sixteen digits or more take the default:
# bash arithmetic wraps past 64 bits, so such a value would arrive silently wrong.
# narrative-reminder.sh carries the same helper, and tests/test_hooks.sh holds
# the two to one text: a hook runs on a partial install without cs-shared.sh,
# so a library copy would still need one here.
_num_or() {  # value, default -> prints value if a plain integer, else default
    case "${1:-}" in ''|*[!0-9]*|????????????????*) echo "$2";; *) echo "$((10#$1))";; esac
}

# The key narrative-reminder.sh and this hook share for one Stop, from
# cs-shared.sh, which says why it is built as it is; the copy serves a partial
# install without the library, and tests/test_hooks.sh holds the three to one
# text.
if ! command -v cs_stop_key >/dev/null 2>&1; then
cs_stop_key() {  # stop input
    local c t s=""
    c=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
    t=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null) || t=""
    if [ -n "$t" ] && [ -f "$t" ] && [ -r "$t" ]; then s=$(wc -c < "$t" 2>/dev/null | tr -d ' ') || s=""; fi
    case "$s" in ''|*[!0-9]*) printf '%s' "$c" ;; *) printf '%s.%s' "$c" "$s" ;; esac
}
fi
# Read as soon as the library is in: the key carries the transcript's size,
# and the later it is read the more a slow start lets the two hooks' readings
# drift apart.
STOP_KEY=$(cs_stop_key "$INPUT")

# Claude Code registers this hook with a 10 s timeout, past which it kills the
# process and drops whatever it printed. Everything below runs inside this
# budget, counted from the process start ($SECONDS): the verdict wait ends at
# it, the lock below waits only for what is left of it, and the scan and the
# plugin probes run before the wait, so that the wait is the last thing
# before the print.
BUDGET=8

# Prints the one notice.
_emit_notice() {  # text
    jq -nc --arg c "$1" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
}

# Only run in cs sessions
cs_resolve_session "" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi
LOCAL="$META_DIR/local"

# Files git tracks where this session keeps its queue and mailbox were written
# by a repository, not by this session (cs_resolve_session). narrative-reminder.sh
# says so on this Stop and runs nothing else; the notices stand down with it.
[ -z "${CS_TRACKED_FILES_NOTICE:-}" ] || exit 0

# --- Queue gate ---------------------------------------------------------------
# A walk-away run owns the turn loop: the drain in narrative-reminder.sh hands
# out the next task as a block, and its context breaker owns hot-context
# handling, so an armed or draining queue gets no notices. The test is the
# drain's own: the lead's Stop, a queue holding a task, and a queue.state of
# armed or draining. An empty queue never gates, whatever queue.state records;
# a teammate's Stop never drains, so it is not gated either. A queue a link
# carries out of the session, or one in a locked vault, is not drained and
# gates nothing.
_qdir=""
if _cs_files=$(cs_private_dir "$META_DIR"); then _qdir="$_cs_files"; fi
if [ -n "$_qdir" ] && command -v _cs_refuses_write >/dev/null 2>&1 \
    && _cs_refuses_write cs-queue "$_qdir/queue" 2>/dev/null; then
    _qdir=""
fi
if [ -n "$_qdir" ] && cs_is_lead; then
    for _task in "$_qdir"/queue/*; do
        [ -f "$_task" ] || continue
        _qstate=$(cat "$_qdir/queue.state" 2>/dev/null | tr -d '[:space:]' || true)
        case "$_qstate" in armed|draining) exit 0 ;; esac
        break
    done
fi

# --- What the transcript records ----------------------------------------------
# A notice reaches the model as context with the user's next prompt, and
# Claude Code records what it delivered in the conversation's transcript, one
# JSON object per line, as {"type":"attachment","attachment":{"type":
# "async_hook_response",...,"response":{"hookSpecificOutput":{"additionalContext":
# "<the notice>"}}}}. Only that attachment counts as a delivery: the phrase
# alone also sits in a user message that quotes it, or in a tool result that
# holds this file, so the lines holding the attachment's type are read as JSON
# and the phrase is looked for in the notice they carry. A transcript that
# cannot be read, or a line of it that is not JSON, records no delivery.
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
_delivered() {  # text the transcript records when the notice was delivered
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 1
    grep -F -- '"async_hook_response"' "$TRANSCRIPT" 2>/dev/null | jq -n -e --arg p "$1" \
        '[inputs | select(.type == "attachment" and .attachment.type == "async_hook_response")
          | (.attachment.response.hookSpecificOutput.additionalContext // "") | contains($p)] | any' \
        >/dev/null 2>&1
}
# The cursor files are append-only lists, one conversation UUID per line, with
# "<uuid> again" for a conversation whose notice went out a second time. A tmux
# teammate shares this directory and runs the same Stop, so a single-slot
# cursor let each teammate's stop cancel the lead's notice and re-arm it every
# turn. Prints never, once or twice.
_cursor() {  # file, uuid
    if grep -qx "$2 again" "$1" 2>/dev/null; then printf 'twice'
    elif grep -qx "$2" "$1" 2>/dev/null; then printf 'once'
    else printf 'never'
    fi
}

# --- The context tiers --------------------------------------------------------
# Decided here, printed below once the sync hook's verdict is in. The tiers
# run in order and the first that applies takes the slot, which is what keeps
# the rotation nudge and the context warning from both firing on one Stop;
# three scripts running side by side could not see each other's decision.
# CTX_TEXT is the notice, CTX_CURSOR its cursor file, CTX_MARK the text the
# transcript records when it was delivered.
CTX_TEXT=""; CTX_CURSOR=""; CTX_MARK=""
NUDGE_CTX=$(_num_or "${CS_ROTATE_NUDGE_CTX:-}" 65)
NUDGE_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
NUDGE_PCT=$(cat "$LOCAL/context-pct" 2>/dev/null | tr -d '[:space:]' || true)
case "$NUDGE_PCT" in ''|*[!0-9]*) NUDGE_PCT="";; esac
# The file holds the LEAD's reading only: the status line writes it for the
# launched conversation alone. A teammate's Stop acting on it announces
# someone else's context as its own, so for any other claude both tiers
# below see no reading at all.
cs_is_lead || NUDGE_PCT=""
# The notices arrive with the user's next prompt, not at the end of the turn
# that raised them, and their wording says so: the reading is the one the
# previous turn ended on, and the request below is answered.
#
# Rotation nudge: suggestion to rotate when context runs hot, once per
# conversation (twice when the transcript does not record the first). The
# queue gate above stands down for an armed or draining queue, so the drain's
# context breaker owns hot-context handling during walk-away runs. Cursor:
# .cs/local/rotate-nudged.
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] && [ "$NUDGE_PCT" -ge "$NUDGE_CTX" ]; then
    CTX_CURSOR="$LOCAL/rotate-nudged"
    CTX_MARK="consider rotating this conversation"
    CTX_TEXT="Context was at ${NUDGE_PCT}% when your previous turn ended, so consider rotating this conversation; this note is carried over with the request below. Tell the user in one line, then answer the request. Once it is answered, or before it if it is large enough to need the headroom, invoke the rotate skill to distill a handoff and arm it; the user then runs /clear to continue in a fresh conversation, without leaving Claude Code. Sent once for this conversation; if now is a bad time, simply continue."
fi
# Context warning: heads-up when context crosses the wind-down band [warn,
# nudge), once per conversation (twice when the transcript does not record
# the first). At or above the nudge threshold the rotation nudge owns the
# notice; this tier never fires there. Cursor: .cs/local/ctx-warned.
WARN_CTX=$(_num_or "${CS_CTX_WARN_CTX:-}" 40)
if [ -n "$NUDGE_PCT" ] && [ -n "$NUDGE_UUID" ] \
    && [ "$NUDGE_PCT" -ge "$WARN_CTX" ] && [ "$NUDGE_PCT" -lt "$NUDGE_CTX" ]; then
    CTX_CURSOR="$LOCAL/ctx-warned"
    CTX_MARK="past the comfortable-headroom mark"
    CTX_TEXT="Context was at ${NUDGE_PCT}% when your previous turn ended, past the comfortable-headroom mark; this note is carried over with the request below. Tell the user in one line, so they can steer toward a natural stopping point or plan a rotation, then answer the request; the rotate nudge follows at ${NUDGE_CTX}%. Sent once for this conversation; no other action is needed."
fi

# --- The narrative reminder ---------------------------------------------------
# Decided here too: REMINDER_DUE is 1 when this actor's own narrative is stale
# and no reminder went out within the cooldown, read unlocked here as the cheap
# answer for the common case and again under the lock before the stamp.
COOLDOWN_FILE="$META_DIR/.narrative-reminder-cooldown"
COOLDOWN_SECONDS=300  # 5 minutes
CURRENT_TIME=$(date +%s)
REMINDER_DUE=0

# A claude started from inside the session (a `claude -p` the lead's Bash
# tool ran) inherits the contract and would be told to update the narrative,
# which is the lead's job; it would also spend the lead's cooldown. A front
# end that walked in carries no launch pid and is not a nested child.
_nested=0
if command -v cs_is_nested_child >/dev/null 2>&1 && cs_is_nested_child; then
    _nested=1
fi

# Cooldown: don't nag if we reminded recently. Returns 0 while the last
# reminder is within the cooldown.
_within_cooldown() {
    local last
    [ -f "$COOLDOWN_FILE" ] || return 1
    # The stamp is data whatever wrote it: the Bash tool reaches the .cs root
    # without the permission hook, and arithmetic runs a command substitution
    # held in an operand. Anything but a plain number reads as 0, a reminder
    # long past.
    last=$(_num_or "$(cat "$COOLDOWN_FILE" 2>/dev/null | tr -d '[:space:]')" 0)
    [ $((CURRENT_TIME - last)) -lt "$COOLDOWN_SECONDS" ]
}

# Per-actor narratives. Freshness is read from this actor's own narrative
# alone: a teammate's write says nothing about whether this claude kept its
# notes, and it shares the directory. The actor is named by the rules
# session-start.sh names it by (cs_actor_raw in cs-shared.sh); without the
# library the own narrative is unknown and counts as stale, as a missing one
# does. The byte budget is still checked over every narrative*.md, since the
# budget line names a teammate's file too.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
if command -v cs_actor_raw >/dev/null 2>&1 && command -v _slugify >/dev/null 2>&1; then
    NARRATIVE_FILE="$META_DIR/memory/narrative.$(_slugify "$(cs_actor_raw "$SESSION_DIR" "$META_DIR")").md"
fi
# The budget and its validation come from cs-shared.sh; without the library
# the budget is unknown and the size check is skipped (SessionStart names the
# missing library; a Stop hook has no channel for it). The mtime pass still runs.
NARRATIVE_MAX=""
if command -v _narrative_budget >/dev/null 2>&1; then
    NARRATIVE_MAX=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
fi
NARRATIVE_OVER=""
if [ "$_nested" = 0 ] && ! _within_cooldown; then
    for _nf in "$META_DIR"/memory/narrative*.md; do
        [ -f "$_nf" ] || continue
        # GNU stat is asked first and BSD second, by which one answers rather than
        # by OSTYPE: Homebrew's coreutils can put GNU stat ahead of the system's on
        # a Mac, and GNU `stat -f` prints the file system's details, not the mtime.
        if [ "$_nf" = "$NARRATIVE_FILE" ]; then
            NARRATIVE_MTIME=$(_num_or "$(stat -c %Y "$_nf" 2>/dev/null || stat -f %m "$_nf" 2>/dev/null)" 0)
        fi
        _sz=$(wc -c < "$_nf" 2>/dev/null | tr -d ' ' || echo 0)
        case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
        if [ -n "$NARRATIVE_MAX" ] && [ "$_sz" -gt "$NARRATIVE_MAX" ]; then
            NARRATIVE_OVER="${NARRATIVE_OVER} $(_cs_plain_name "$(basename "$_nf")" 160) is $((_sz / 1024)) KB, over the $((NARRATIVE_MAX / 1024)) KB budget — if it is yours, run \`cs -narrative rotate\` before appending."
        fi
    done
    # None while the own narrative was updated within the cooldown; a missing
    # one reads as never updated.
    if [ $((CURRENT_TIME - NARRATIVE_MTIME)) -ge "$COOLDOWN_SECONDS" ]; then
        REMINDER_DUE=1
    fi
fi

# The council advisor nudge rides the narrative reminder rather than speaking
# on its own: this hook hands the model one notice per run, so a note of its
# own would displace the reminder instead of composing with it.
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

# $1 is the installed_plugins.json key prefix, $2 a command file the plugin
# must still carry on disk.
_plugin_is_installed() {
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
        [ -f "$path/$2" ] && return 0
    done <<EOF
$(jq -r --arg k "$1" '(.plugins // {}) | to_entries[]
         | select(.key | startswith($k))
         | .value[]?.installPath // empty' "$record" 2>/dev/null | tr -d '\r')
EOF
    return 1
}

# Lead only. A tmux teammate is a full claude in the same directory with its
# own Stop, and the cooldown is one stamp for the session: an ungated nudge
# lets a teammate consume the lead's slot, and in a walk-away run the lead can
# stop seeing the suggestion altogether. The plugin probe runs before the
# verdict wait and the lock below: it reads only.
_has_council=0; _has_codex=0
if [ "$REMINDER_DUE" = 1 ] && cs_is_lead; then
    _plugin_is_installed "claude-council@" "commands/advise.md" && _has_council=1
    _plugin_is_installed "codex@" "commands/review.md" && _has_codex=1
fi

# Nothing to say: no verdict is waited for and no lock taken.
[ -n "$CTX_TEXT" ] || [ "$REMINDER_DUE" = 1 ] || exit 0

# --- The sync hook's verdict --------------------------------------------------
# The queue gate above reads the state the drain leaves behind, and a drain
# that trips a breaker or hands out its last task leaves idle behind and
# blocks; the staged retire and the mail wake block without touching the
# queue at all. A notice beside any such block is noise, so this hook waits
# for the verdict narrative-reminder.sh posts to .cs/local/stop-verdict:
# "<key> <word> <epoch>", the key cs_stop_key's for the Stop input both hooks
# receive, the word pending while that hook runs and approve or block at its
# exit. Claude Code starts the two hooks together and neither runs first by
# contract, so the wait has two bounds. No line for this Stop within the first
# two seconds of this process means no verdict is coming (a partial install
# without the sync hook, or one that predates the verdict), and the notices go
# ahead as they did before the verdict existed; a pending line extends the
# wait to CS_STOP_VERDICT_WAIT seconds from the process start (default 7, at
# most the budget), and a verdict that is still pending then is treated as
# approve, since a notice that waits longer risks the 10 s registration
# timeout. The staged retire can block later than that (its settle waits up
# to six seconds twice), and a notice then lands beside its block, as every
# notice did before the verdict existed. The key is one per Stop, so an
# earlier Stop's line is never this one's; its epoch is for a reader. Lead
# only: every block the sync hook answers with is the lead's, and only the
# lead's sync hook writes the file.
_verdict() {  # prints pending, approve or block for this Stop; nothing otherwise
    local k w t
    [ -f "$LOCAL/stop-verdict" ] || return 0
    IFS=' ' read -r k w t < "$LOCAL/stop-verdict" 2>/dev/null || true
    [ "$k" = "$STOP_KEY" ] || return 0
    case "$w" in pending|approve|block) printf '%s' "$w" ;; esac
}
if cs_is_lead; then
    _wait=$(_num_or "${CS_STOP_VERDICT_WAIT:-}" 7)
    [ "$_wait" -le "$BUDGET" ] || _wait=$BUDGET
    _grace=2
    [ "$_grace" -le "$_wait" ] || _grace="$_wait"
    while :; do
        _word=$(_verdict)
        case "$_word" in
            block) exit 0 ;;
            approve) break ;;
            pending) [ "$SECONDS" -lt "$_wait" ] || break ;;
            *) [ "$SECONDS" -lt "$_grace" ] || break ;;
        esac
        sleep 0.1
    done
fi

# --- The print, under the lock ------------------------------------------------
# The cursors and the cooldown stamps are read and written under one lock,
# the library's (cs-shared.sh, _cs_lock), taken here and held across the
# print: this hook is async, so two of its runs overlap when turns end close
# together, and without the lock both read a cursor at once, or a stamp older
# than the cooldown, and both print. The run that takes the lock second finds
# the first's line and prints nothing. The lock waits only for what is left of
# the budget, nothing at all once the budget is spent; without the library,
# without perl, when the lock file cannot be made (the local directory is
# unwritable) or when a holder keeps it past the budget, the files are read
# and written unlocked, as they were before the lock existed, and a stamp that
# cannot be written costs no reminder: the hook fails open. The lock is taken
# in this process, not a $(...), as its contract asks. Its file sits in
# .cs/local/, per-machine state.
_lock=""
_left=$((BUDGET - SECONDS))
[ "$_left" -ge 0 ] || _left=0
if command -v _cs_lock >/dev/null 2>&1 && _cs_lock "$LOCAL/stop-notices.mutex.lock" "$_left" 2>/dev/null; then
    _lock="$LOCAL/stop-notices.mutex.lock"
fi
if ! command -v _cs_unlock >/dev/null 2>&1; then _cs_unlock() { :; }; fi
_done() {  # exit status
    _cs_unlock "$_lock"
    exit "$1"
}

# A context notice goes out at most twice for a conversation: once, and once
# more on a later Stop where it still applies and the transcript does not
# record the first (lost at exit, or still to be read: nothing here can tell
# the two apart). The first print is followed by its cursor line, so a notice
# lost at exit is one the cursor does not count as sent, and a cursor that
# cannot be written costs no notice. The repeat is preceded by its "again"
# line, and goes out only once that line is written: a repeat the cursor
# cannot record would come back on every Stop, and a lost repeat costs less
# than an unbounded one.
if [ -n "$CTX_TEXT" ]; then
    case "$(_cursor "$CTX_CURSOR" "$NUDGE_UUID")" in
        never)
            _emit_notice "$CTX_TEXT"
            cs_append_inside "$CTX_CURSOR" printf '%s\n' "$NUDGE_UUID" || true
            _done 0
            ;;
        once)
            if ! _delivered "$CTX_MARK"; then
                cs_append_inside "$CTX_CURSOR" printf '%s again\n' "$NUDGE_UUID" || _done 0
                _emit_notice "$CTX_TEXT"
                _done 0
            fi
            ;;
    esac
fi

[ "$REMINDER_DUE" = 1 ] || _done 0
if _within_cooldown; then
    _done 0
fi
cs_write_atomic "$COOLDOWN_FILE" echo "$CURRENT_TIME" || true
if [ "$((_has_council + _has_codex))" -gt 0 ]; then
    _adv_last=0
    if [ -f "$ADVISOR_COOLDOWN_FILE" ]; then
        _adv_last=$(_num_or "$(cat "$ADVISOR_COOLDOWN_FILE" 2>/dev/null | tr -d '[:space:]')" 0)
        _adv_last=$((10#$_adv_last))
    fi
    if [ "$((CURRENT_TIME - _adv_last))" -ge "$ADVISOR_COOLDOWN_SECONDS" ]; then
        cs_write_atomic "$ADVISOR_COOLDOWN_FILE" echo "$CURRENT_TIME" || true
        # One note and one cooldown slot however many channels are present:
        # two independent nudges would double the appended text and race
        # the same stamp.
        ADVISOR_NUDGE=" Standing note: at a real decision point — about to commit to an approach, stuck after repeated attempts, or about to call the work done — a second opinion is available."
        if [ "$_has_council" -eq 1 ]; then
            ADVISOR_NUDGE="$ADVISOR_NUDGE \`/claude-council:advise\` puts this conversation to external models; it sends a digest to third-party providers, so ask the user before running it and show them what would go."
        fi
        if [ "$_has_codex" -eq 1 ]; then
            # review and adversarial-review carry disable-model-invocation,
            # so they are the user's to type; offer them, never run them.
            ADVISOR_NUDGE="$ADVISOR_NUDGE Offer \`/codex:review\` before calling built work done — the user runs it, you cannot. \`/codex:rescue\` is yours to invoke when genuinely stuck."
        fi
        ADVISOR_NUDGE="$ADVISOR_NUDGE You judge whether the moment qualifies; most turns do not."
    fi
fi

# Sessions whose .cs/ is tracked were committing once per narrative append —
# 328 such commits in one repo, 74 in a single day, burying the project's own
# history. The session protocol's cs:session-commits section states the rule
# (nothing commits files under .cs/ unless the user asks), and it rides on
# THIS string as well, because the protocol is read
# once at startup and is a hundred turns stale by the time an append happens;
# the reminder fires at the append itself. It is
# unconditional on purpose: testing whether .cs/ is tracked would be cheap here,
# but the advice is inert rather than wrong where it is gitignored, and a
# condition the model must evaluate is one it will not.
COMMIT_CADENCE=" Never commit narrative appends or anything else under .cs/ on your own, not even beside a project change: cs commits files under .cs/ only in the commit that creates a session and the merge /finish makes, and you commit them only when the user asks. Never push a commit that holds narrative appends unless the user asks. Uncommitted appends are safe — autosave snapshots every edit to a shadow ref."

# The actor slug comes from a git identity a clone can choose: it is printed
# as a plain name. Without the library the actor is unknown, and the reminder
# names the file by its pattern; it already says to run cs -whoami.
if [ -n "$NARRATIVE_FILE" ]; then
    NARRATIVE_SHOWN="$META_DIR/memory/$(_cs_plain_name "${NARRATIVE_FILE##*/}" 160)"
else
    NARRATIVE_SHOWN="$META_DIR/memory/narrative.<actor>.md"
fi
# Worded for where it lands: beside the user's next request, about the turn
# that ended before it. The cooldown stamp above is this notice's cursor, and
# it is written before the print on purpose: the lock holds it, and a reminder
# lost at exit comes back after the cooldown rather than twice in a row.
_emit_notice "Narrative check. This note is carried over from your previous turn, which ended without a narrative note. Before answering the request below, record what that turn found, in your own narrative only (run \`cs -whoami\` if unsure which actor you are; never edit a teammate's narrative). Yours is $NARRATIVE_SHOWN. (1) If that turn disproved or superseded one of your entries, append a dated correction that names it; never rewrite or delete earlier sections. (2) Append what that turn found as plain dated notes: a decision and its reason, a measured fact, a failed approach, a preference the user stated. A line that only restates routine work, such as \"appended X to Y\" or \"ran the tests\", is not a finding and must not be written. If that turn found nothing worth keeping, say so in one line and answer the request.${COMMIT_CADENCE}${NARRATIVE_OVER}${ADVISOR_NUDGE}"
_done 0
