#!/usr/bin/env bash
# ABOUTME: UserPromptSubmit hook: records the first prompt as the session Objective, then
# ABOUTME: grounds code-work prompts in a bounded "Scope (auto-grounded)" block

# No `set -e`: this hook must NEVER block the prompt. Every error path exits 0.
set -uo pipefail

# --- Defensive early exits (silent pass-through) ---

# Only run inside a cs session.
[ -n "${CLAUDE_SESSION_NAME:-}" ] || exit 0

# The user is back: drop the statusline's finished-blink marker before any
# other gate (slash commands and short prompts clear it too).
[ -n "${CLAUDE_SESSION_META_DIR:-}" ] \
    && rm -f "$CLAUDE_SESSION_META_DIR/local/attention" 2>/dev/null

# Read the prompt purely as DATA: jq decodes it, and it is only ever fed to other
# commands as quoted stdin or written to a file via awk ENVIRON — never eval'd or
# expanded into a shell context.
INPUT=$(cat 2>/dev/null) || exit 0
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || exit 0

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

# --- Scope grounding (code-work prompts only) ---

# Per-session opt-out.
[ "${CS_SCOPE_DISABLE:-}" = "1" ] && exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || exit 0

[ -n "$PROMPT" ] || exit 0

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
    if ! printf '%s' "$PROMPT" | rg -q "(?i:$VERB_RE)|$EXT_RE" 2>/dev/null; then
        exit 0   # negative classification: silent pass-through
    fi
else
    _scan() { grep -E "$@"; }
    if ! { printf '%s' "$PROMPT" | grep -qiE "$VERB_RE" 2>/dev/null \
        || printf '%s' "$PROMPT" | grep -qE "$EXT_RE" 2>/dev/null; }; then
        exit 0   # negative classification: silent pass-through
    fi
fi

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
    [ -n "$RECENT_COMMITS" ] && BLOCK="$BLOCK

### Recent commits
$RECENT_COMMITS"

    # `tail -10` bounds the diff, but silently dropping leading stat lines would let Claude
    # read a file absent from the list as unmodified. Flag the truncation in the header so an
    # absent file reads as "maybe cut", not "clean".
    _full_diff=$(git -C "$SESSION_DIR" diff --stat HEAD 2>/dev/null)
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

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
