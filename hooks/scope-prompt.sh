#!/usr/bin/env bash
# ABOUTME: UserPromptSubmit hook: records the first prompt as the session Objective, then
# ABOUTME: grounds code-work prompts in a bounded "Scope (auto-grounded)" block

# No `set -e`: this hook must NEVER block the prompt. Every error path exits 0.
set -uo pipefail

# --- Defensive early exits (silent pass-through) ---

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
# Only run inside a cs session. No input yet at this point (it is read further
# down), so resolution relies on the env or CLAUDE_PROJECT_DIR.
cs_resolve_session "" || exit 0

# --- Stage trace ---

# One line per stage, appended as that stage finishes, so a run killed at the
# UserPromptSubmit wall clock still leaves the trail naming whatever it hung on.
# A summary written at exit would say nothing about exactly the runs worth
# diagnosing, since those never reach the exit. Machine-local: which machine was
# slow is half the finding, and a shared file would average four of them
# together. Columns are pid, milliseconds, stage.
_TRACE=""
_TRACE_T0=0
_MS=0

# The clock, through builtins only ($EPOCHREALTIME where the shell has it,
# $SECONDS on bash 3.2). A trace that forked twice per stage would be measuring
# its own overhead in a hook under suspicion for being slow. Sets _MS rather
# than printing, because capturing a print costs the subshell this avoids.
_now_ms() {
    local t="${EPOCHREALTIME:-}" s f
    case "$t" in
        *[.,]*)
            s="${t%%[.,]*}"
            f="${t#*[.,]}"
            # 10# forces base 10: a fractional part like 004512 is not octal.
            _MS=$(( 10#$s * 1000 + 10#${f:0:3} ))
            ;;
        *) _MS=$(( SECONDS * 1000 )) ;;
    esac
}

_trace_open() {  # meta_local_dir
    [ "${CS_SCOPE_TRACE_DISABLE:-}" = "1" ] && return 0
    [ -n "$1" ] || return 0
    [ -d "$1" ] || mkdir -p "$1" 2>/dev/null || return 0
    _TRACE="$1/scope-prompt.trace"
    _now_ms
    _TRACE_T0=$_MS
    # Bound the file without buying a size check on every prompt: one run in 64
    # trims it, often enough that it cannot run away and rare enough that the
    # fork stays out of the common path.
    if [ $(( $$ % 64 )) -eq 0 ] && [ -f "$_TRACE" ]; then
        tail -n 2000 "$_TRACE" > "$_TRACE.tmp" 2>/dev/null \
            && mv "$_TRACE.tmp" "$_TRACE" 2>/dev/null || true
    fi
    # The start mark carries the origin every later mark is relative to, so one
    # run reads as elapsed time and the file as a history. It also names the
    # directory the run stood in: the scan's cost depends on what git is asked
    # to walk, and a kill from deep inside a tree and one at its root are not
    # the same event. The directory is the rest of the line, never a field —
    # paths hold spaces. A newline in one would split the mark in two, so it
    # collapses to a space (a shell substitution: still no fork).
    printf '%s %s start %s\n' "$$" "$_TRACE_T0" "${PWD//$'\n'/ }" \
        >> "$_TRACE" 2>/dev/null || true
}

_trace() {  # stage
    [ -n "$_TRACE" ] || return 0
    _now_ms
    printf '%s %s %s\n' "$$" "$(( _MS - _TRACE_T0 ))" "$1" >> "$_TRACE" 2>/dev/null || true
}

_trace_open "${CLAUDE_SESSION_META_DIR:-}/local"

# The user is back: drop the statusline's finished-blink marker before any
# other gate (slash commands and short prompts clear it too).
[ -n "${CLAUDE_SESSION_META_DIR:-}" ] \
    && rm -f "$CLAUDE_SESSION_META_DIR/local/attention" 2>/dev/null

# iTerm2: the bounce raised at turn end stops the moment the user prompts.
# Mirrors the guard in narrative-reminder.sh (hooks are standalone).
if [ -z "${CS_NO_ITERM2:-}" ] && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    _it2="${CS_IT2_DIR:-$HOME/.iterm2}/it2attention"
    { [ -x "$_it2" ] && "$_it2" stop > "${CS_IT2_TTY:-/dev/tty}"; } 2>/dev/null || true
fi

# Read the prompt purely as DATA: jq decodes it, and it is only ever fed to other
# commands as quoted stdin or written to a file via awk ENVIRON — never eval'd or
# expanded into a shell context.
INPUT=$(cat 2>/dev/null) || exit 0
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || exit 0
_trace input

# Clear the mail wake's budget, but only for a prompt somebody typed. The
# ceiling exists to stop two unattended sessions volleying at each other, and a
# human typing is the proof that nobody is stuck in one — which is why it counts
# wakes since the last USER prompt. A wake reaches the model as a turn of its
# own, carrying no prompt, so treating that turn as proof would let every wake
# reset the budget it just spent, and the ceiling would cap nothing.
if [ -n "$PROMPT" ] && [ -n "${CLAUDE_SESSION_META_DIR:-}" ]; then
    rm -f "$CLAUDE_SESSION_META_DIR/local/mail/wakes" 2>/dev/null || true
fi

# --- Queue inbox digest (surface-once) ---

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

# Build the persistent unread-mail digest: on every prompt, inline the bodies of
# the messages sitting in mail/new/ (which only `cs -msg` empties, by moving what
# it prints to cur/), so the session stays aware of new mail until it actually
# reads it — not surface-once. Bounded to keep context cheap: at most the first 5
# documents are opened, sender and body truncated inside jq (codepoint-safe, so a
# torn multibyte char can never reach the shell and poison the
# additionalContext), plus an "N more" overflow line. A task-kind message is
# surfaced as a count-only label, never its body: the body is already an
# imperative in the recipient's queue, so inlining it would double-execute.
# Nothing is written here — persistence is anchored on new/ itself — so this
# stays a read-only view of the mailbox (a multi-user-safety win: no
# hook-vs-hook race on a mail cursor). Only new/*.json counts: an unfiltered
# scan would pick up a .DS_Store or a subdirectory and nag about phantom mail
# that cs -msg cannot clear. Best-effort throughout: never breaks the hook.
_build_mail_digest() {  # meta_local_dir
    local mdir="$1/mail" f total=0
    MAIL_DIGEST=""
    [ -d "$mdir/new" ] || return 0
    local files=()
    for f in "$mdir"/new/*.json; do
        [ -f "$f" ] || continue
        files+=("$f")
        total=$((total + 1))
    done
    [ "$total" -gt 0 ] || return 0
    # tostr coerces any non-string field (a forged/hand-written document could
    # carry a number or object) to a string so a single bad document can't error
    # the whole jq program and suppress every valid message beside it.
    MAIL_DIGEST=$(cat "${files[@]:0:5}" 2>/dev/null | jq -rRs --argjson total "$total" '
        def tostr: if type == "string" then . else tostring end;
        # Bound the RENDERED MESSAGES, not the files opened: one document is
        # normally one message, but a hand-written file can hold many lines,
        # and rendering all of them would inject unbounded context every
        # prompt (this digest is prepended after the scope cap, so nothing
        # downstream would trim it).
        [split("\n")[] | select(length > 0) | (fromjson? // empty)][0:5] as $m |
        # The header shows even when nothing in the window parsed: staying
        # silent while the badge counts N unread is the one outcome this
        # persistent digest exists to prevent.
        if ($m | length) == 0 then
          "Unread mail (\($total)) - nothing legible in the first documents; run cs -msg to read and clear."
        else
        ( [ $m[] |
              ((((if (.from // "") == "" then .actor else .from end) // "") | tostr)[0:40]) as $who |
              if .kind == "task" then "  queued task from \($who) (runs via cs -queue)"
              else "  mail from \($who): \"\((((.body // "") | tostr) | gsub("[\n\r]"; " "))[0:160])\"" end ]
          # Count the overflow against what was actually RENDERED, not against
          # the file total: the two differ whenever the opened files hold more
          # or fewer messages than one apiece, and an overflow line derived
          # from files would then contradict the bodies above it.
          + (if $total > ($m | length) then ["  ... and \($total - ($m | length)) more (cs -msg to read)"] else [] end)
        ) as $lines |
        "Unread mail (\($total)) - still unread, run cs -msg to clear:\n" + ($lines | join("\n"))
        end
    ' 2>/dev/null) || MAIL_DIGEST=""
    MAIL_DIGEST=$(printf '%s' "$MAIL_DIGEST" | LC_ALL=C tr -d '\000-\010\013-\037\177')
}

DIGEST=""
DIGEST_PENDING=""
MAIL_DIGEST=""
if [ -n "${CLAUDE_SESSION_META_DIR:-}" ]; then
    _build_digest "$CLAUDE_SESSION_META_DIR/local"
    _build_mail_digest "$CLAUDE_SESSION_META_DIR/local"
fi
if [ -n "$MAIL_DIGEST" ]; then
    DIGEST="${DIGEST:+$DIGEST
}$MAIL_DIGEST"
fi
_trace digest

# Every pass-through exit below this point must still deliver a pending
# digest; a digest-only prompt turn emits just the digest as context.
_digest_exit() {
    if [ -n "$DIGEST" ]; then
        jq -n --arg c "$DIGEST" \
            '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    fi
    _commit_digest "${CLAUDE_SESSION_META_DIR:-}/local"
    _trace exit
    exit 0
}

# --- Objective capture (independent of the scope grounding below) ---
# Record the first substantive prompt as the session Objective, but only while
# the Objective is still a template placeholder — a whole line wrapped in [...].
# Matching the bracket SHAPE (not the exact template wording) stays robust if the
# template text changes; scoping to the Objective section leaves the Outcome
# placeholder untouched. First real prompt wins; a hand-written objective (not
# bracketed) is never overwritten.
_obj_readme="${CLAUDE_SESSION_META_DIR:-}/README.md"
if [ "${CS_OBJECTIVE_CAPTURE_DISABLE:-}" != "1" ] \
    && [ -n "${CLAUDE_SESSION_META_DIR:-}" ] \
    && [ -f "$_obj_readme" ] \
    && awk '
        /^## / { in_obj = ($0 ~ /^## Objective/) }
        in_obj && /^\[.*\]$/ { found = 1 }
        END { exit !found }
       ' "$_obj_readme" 2>/dev/null; then
    # Collapse whitespace; skip slash commands, shell passthrough, trivially short.
    _obj=$(printf '%s' "$PROMPT" | tr '\n\r\t' '   ' | tr -s ' ' | sed -E 's/^ +//; s/ +$//')
    case "$_obj" in /*|!*) _obj="" ;; esac
    if [ -n "$_obj" ] && [ "${#_obj}" -ge 8 ]; then
        [ "${#_obj}" -gt 100 ] && _obj="${_obj:0:100}…"
        # ENVIRON sidesteps awk -v escape processing of arbitrary prompt text;
        # only the Objective-section placeholder line is replaced, all others
        # pass through verbatim; tmp+mv keeps the write atomic.
        _obj_tmp=$(mktemp 2>/dev/null) || _obj_tmp=""
        if [ -n "$_obj_tmp" ] && OBJ="$_obj" awk '
                /^## / { in_obj = ($0 ~ /^## Objective/) }
                in_obj && /^\[.*\]$/ { print ENVIRON["OBJ"]; next }
                { print }
            ' "$_obj_readme" > "$_obj_tmp" 2>/dev/null; then
            mv "$_obj_tmp" "$_obj_readme" 2>/dev/null || rm -f "$_obj_tmp" 2>/dev/null
        else
            [ -n "$_obj_tmp" ] && rm -f "$_obj_tmp" 2>/dev/null
        fi
    fi
fi
_trace objective

# --- Scope grounding (code-work prompts only) ---

# Per-session opt-out.
[ "${CS_SCOPE_DISABLE:-}" = "1" ] && _digest_exit

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || _digest_exit

[ -n "$PROMPT" ] || _digest_exit

# --- Classifier: positive iff a base-form work verb OR a source-file extension appears ---

VERB_RE='\b(implement|add|fix|refactor|debug|edit|modify|rename|remove|delete|write|build|create|update|change|extract|inline|split|merge|migrate|port|wire|hook up|optimize)\b'
EXT_RE='\.(ts|tsx|js|jsx|py|sh|bash|md|json|yaml|yml|toml|rs|go|swift|java|c|cpp|h|hpp)\b'

# Prefer ripgrep, but fall back to grep -E so scope grounding still works on a
# stock macOS/BSD box without ripgrep installed (rather than silently classifying
# every prompt negative). Both accept the -q/-v/-i flags used below; the
# classifier's inline (?i:) group becomes two grep passes in the fallback.
if command -v rg >/dev/null 2>&1; then
    _scan() { rg "$@"; }
    # Verbs match case-insensitively via (?i:); extensions stay case-sensitive.
    # Herestring, not a pipe: -q exits at the first match, which leaves the
    # writer holding a closed fd, and `set -o pipefail` promotes that SIGPIPE
    # (141) to the pipeline's status — read by the leading `!` as "no match".
    # A prompt bigger than the 64KB pipe buffer outlives the match, so pasted
    # logs classified negative and got no grounding at all.
    if ! rg -q "(?i:$VERB_RE)|$EXT_RE" <<< "$PROMPT" 2>/dev/null; then
        _digest_exit   # negative classification: silent pass-through
    fi
else
    _scan() { grep -E "$@"; }
    if ! { grep -qiE "$VERB_RE" <<< "$PROMPT" 2>/dev/null \
        || grep -qE "$EXT_RE" <<< "$PROMPT" 2>/dev/null; }; then
        _digest_exit   # negative classification: silent pass-through
    fi
fi
_trace classify

# No cache: a grounding hook must reflect the CURRENT tree. A prompt-only cache key served
# stale ground after commits/edits, and a repo-state-aware key would almost never hit in an
# active session — so the scan (bounded, read-only) just runs every time.

# --- Grounded scan (all bounded; all read-only git) ---

# Stoplist of common function words (anchored, case-insensitive). Applied to the camelCase/
# snake sub-parts of bare-word tokens; path-like tokens are explicit and never stoplisted
# (a stopword cannot contain an interior . or /, so none ever takes the path route).
STOP_RE='^(the|this|that|with|from|into|when|then|than|will|just|some|like|need|want|have|been|and|but|for|not|all|any|its|use|via|new|old|fix|add|set|get|to|of|in|on|by|is|as|it|or|if|so|do)$'

# Tokens: word-ish fragments of the prompt. Strip leading/trailing . / _ - so a sentence-final
# period ("...the api.") doesn't fake an explicit-path token and silently kill recall — only an
# INTERIOR . or / marks a path. Keep tokens >= 2 chars that contain a letter (the letter rule
# defuses the lone-'.'/'/' scan bomb — punctuation has no letter).
TOKENS=$(printf '%s' "$PROMPT" \
    | tr -cs '[:alnum:]_/.-' '\n' \
    | sed -E 's#^[./_-]+##; s#[./_-]+$##' \
    | _scan -v '^.{0,1}$' 2>/dev/null \
    | _scan '[a-zA-Z]' 2>/dev/null \
    | sort -u)

# Hybrid matching. Path-like tokens (containing / or .) are explicit paths/filenames and match
# as ordered SUBSTRINGS — this keeps "src/api.ts" from also matching "api/src/x.ts". Bare words
# match by path-COMPONENT equality, so "api" grounds api/handler.ts and apiHandler.ts but "me"
# does NOT ground README.md. Bare words are first split on camelCase + _ - into parts, refiltered.
PATH_TOKENS=$(printf '%s' "$TOKENS" | _scan '[/.]' 2>/dev/null || true)
WORD_PARTS=$(printf '%s' "$TOKENS" | _scan -v '[/.]' 2>/dev/null \
    | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g' \
    | tr '_-' '  ' | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' \
    | _scan -v '^.{0,1}$' 2>/dev/null | _scan '[a-z]' 2>/dev/null \
    | _scan -vi "$STOP_RE" 2>/dev/null | sort -u || true)
_trace tokens

# Build/vendor/meta dirs that must never be injected. The \.cs/ entry is load-bearing:
# without it /scope would surface the session's own metadata (memory, narrative, ...).
EXCLUDE_RE='(^|/)(node_modules|target|dist|build|\.next|coverage|\.cs)/|(^|/)\.git/'

# Known, deliberately-accepted limitations of this matcher (not bugs):
#  - Multi-part bare tokens OR-match each part, so "getUserData" (parts user, data) surfaces
#    *Data.ts neighbours alongside userData.ts. Accepted recall/precision trade — stoplisting
#    "data" would hurt prompts that legitimately want data-handling code. Revisit if noisy.
#  - Non-English tokens are mangled: `tr -cs '[:alnum:]'` splits at non-ASCII letters in the C
#    locale, so "münchen" won't match "café/münchen.ts". Known gap; non-English was never a goal.
#  - The awk pass is ~255ms on a 10k-file tree (vs ~137ms for the old rg -iF) — bounded and well
#    under the hook's 3s timeout.
RELEVANT_FILES=""
if [ -n "$PATH_TOKENS" ] || [ -n "$WORD_PARTS" ]; then
    # splitcamel() is a hand-rolled char loop ON PURPOSE: BSD awk (macOS) has no gensub /
    # backreferences, so the GNU `gsub(/.../, "\\1 \\2")` trick is non-portable. Do not simplify.
    RELEVANT_FILES=$(git -C "$SESSION_DIR" ls-files 2>/dev/null \
        | _scan -v "$EXCLUDE_RE" 2>/dev/null \
        | awk -v ptoks="${PATH_TOKENS//$'\n'/ }" \
              -v wtoks="${WORD_PARTS//$'\n'/ }" '
            function splitcamel(s,   out, i, c, p, n) {
                out = ""; p = "";
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1);
                    n = (i < length(s)) ? substr(s, i + 1, 1) : "";
                    if (p ~ /[a-z0-9]/ && c ~ /[A-Z]/) out = out " ";                   # word -> Word
                    else if (p ~ /[A-Z]/ && c ~ /[A-Z]/ && n ~ /[a-z]/) out = out " ";  # ACRONYM -> Word (APIClient -> API Client)
                    out = out c; p = c;
                }
                return out;
            }
            BEGIN {
                np = split(ptoks, pa, " "); for (i = 1; i <= np; i++) PT[i] = tolower(pa[i]);
                nw = split(wtoks, wa, " "); for (i = 1; i <= nw; i++) WT[wa[i]] = 1;
            }
            {
                lp = tolower($0);
                for (i = 1; i <= np; i++) if (PT[i] != "" && index(lp, PT[i]) > 0) { print; if (++matched >= 30) exit; next }
                comp = splitcamel($0); gsub(/[\/._-]/, " ", comp);
                m = split(tolower(comp), parts, " ");
                for (i = 1; i <= m; i++) if (parts[i] in WT) { print; if (++matched >= 30) exit; next }
            }')
fi
_trace scan

# --- Build the scope block ---

TOMBSTONE='Scope: no tracked files matched — locate the relevant files yourself before editing.'

if [ -n "$RELEVANT_FILES" ]; then
    BLOCK="## Scope (auto-grounded)
Keyword matches from your prompt — orientation, not a task boundary or a complete list. Ignore anything off-target.

### Relevant files
$RELEVANT_FILES"

    # Pass paths as quoted argv (an array), so a tracked filename with a space or glob char
    # can't split into bogus pathspecs. The count guard keeps "${arr[@]}" safe under set -u
    # on bash 3.2 (macOS) when the array is empty.
    RECENT_COMMITS=""
    REL_PATHS=()
    while IFS= read -r _f; do [ -n "$_f" ] && REL_PATHS+=("$_f"); done <<< "$RELEVANT_FILES"
    [ "${#REL_PATHS[@]}" -gt 0 ] && RECENT_COMMITS=$(git -C "$SESSION_DIR" log --oneline -5 --no-merges -- "${REL_PATHS[@]}" 2>/dev/null)
    _trace gitlog
    [ -n "$RECENT_COMMITS" ] && BLOCK="$BLOCK

### Recent commits
$RECENT_COMMITS"

    # `tail -10` bounds the diff, but silently dropping leading stat lines would let Claude
    # read a file absent from the list as unmodified. Flag the truncation in the header so an
    # absent file reads as "maybe cut", not "clean".
    _full_diff=$(git -C "$SESSION_DIR" diff --stat HEAD 2>/dev/null)
    _trace gitdiff
    if [ -n "$_full_diff" ]; then
        LATEST_DIFF=$(printf '%s\n' "$_full_diff" | tail -10)
        _wt_header="### Working tree"
        [ "$(printf '%s\n' "$_full_diff" | awk 'END{print NR}')" -gt 10 ] \
            && _wt_header="$_wt_header (truncated to last 10 lines)"
        BLOCK="$BLOCK

$_wt_header
$LATEST_DIFF"
    fi
else
    BLOCK="## Scope (auto-grounded)

$TOMBSTONE"
fi

# Token cap: keep the injected context bounded (better thin signal than none). When the block
# overflows, cut back to the last whole line (so no path/commit is severed mid-token) and append
# an explicit marker — a truncated tail must never read as a real, complete list. Reserve headroom
# for the marker so the result still fits the 8000-byte cap.
if [ "$(printf '%s' "$BLOCK" | wc -c | tr -d ' ')" -gt 8000 ]; then
    BLOCK=$(printf '%s' "$BLOCK" | head -c 7900)
    BLOCK="${BLOCK%$'\n'*}
[scope block truncated]"
fi

if [ -n "$DIGEST" ]; then
    BLOCK="$DIGEST

$BLOCK"
fi

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
_commit_digest "${CLAUDE_SESSION_META_DIR:-}/local"
_trace emit
exit 0
