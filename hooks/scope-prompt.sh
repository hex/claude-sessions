#!/usr/bin/env bash
# ABOUTME: UserPromptSubmit hook that grounds code-work prompts in the real codebase
# ABOUTME: Injects a bounded "Scope (auto-grounded)" block: relevant files, recent commits, diff

# No `set -e`: this hook must NEVER block the prompt. Every error path exits 0.
set -uo pipefail

# --- Defensive early exits (silent pass-through) ---

# Only run inside a cs session.
[ -n "${CLAUDE_SESSION_NAME:-}" ] || exit 0
# Per-session opt-out.
[ "${CS_SCOPE_DISABLE:-}" = "1" ] && exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || exit 0

# Read the prompt purely as DATA: jq decodes it, and it is only ever fed to other
# commands as quoted stdin — never eval'd or expanded into a shell context.
INPUT=$(cat 2>/dev/null) || exit 0
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$PROMPT" ] || exit 0

# --- Classifier: positive iff a base-form work verb OR a source-file extension appears ---

VERB_RE='\b(implement|add|fix|refactor|debug|edit|modify|rename|remove|delete|write|build|create|update|change|extract|inline|split|merge|migrate|port|wire|hook up|optimize)\b'
EXT_RE='\.(ts|tsx|js|jsx|py|sh|bash|md|json|yaml|yml|toml|rs|go|swift|java|c|cpp|h|hpp)\b'

# One rg spawn: verbs match case-insensitively via the inline (?i:) group,
# extensions stay case-sensitive (.TS is not a TypeScript file).
if ! printf '%s' "$PROMPT" | rg -q "(?i:$VERB_RE)|$EXT_RE" 2>/dev/null; then
    exit 0   # negative classification: silent pass-through
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
    | rg -v '^.{0,1}$' 2>/dev/null \
    | rg '[a-zA-Z]' 2>/dev/null \
    | sort -u)

# Hybrid matching. Path-like tokens (containing / or .) are explicit paths/filenames and match
# as ordered SUBSTRINGS — this keeps "src/api.ts" from also matching "api/src/x.ts". Bare words
# match by path-COMPONENT equality, so "api" grounds api/handler.ts and apiHandler.ts but "me"
# does NOT ground README.md. Bare words are first split on camelCase + _ - into parts, refiltered.
PATH_TOKENS=$(printf '%s' "$TOKENS" | rg '[/.]' 2>/dev/null || true)
WORD_PARTS=$(printf '%s' "$TOKENS" | rg -v '[/.]' 2>/dev/null \
    | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g' \
    | tr '_-' '  ' | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' \
    | rg -v '^.{0,1}$' 2>/dev/null | rg '[a-z]' 2>/dev/null \
    | rg -vi "$STOP_RE" 2>/dev/null | sort -u || true)

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
        | rg -v "$EXCLUDE_RE" 2>/dev/null \
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

TOMBSTONE='Scope: no tracked files matched (grounding from prompt only).'

if [ -n "$RELEVANT_FILES" ]; then
    BLOCK="## Scope (auto-grounded)

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

    LATEST_DIFF=$(git -C "$SESSION_DIR" diff --stat HEAD 2>/dev/null | tail -10)
    [ -n "$LATEST_DIFF" ] && BLOCK="$BLOCK

### Working tree
$LATEST_DIFF"
else
    BLOCK="## Scope (auto-grounded)

$TOMBSTONE"
fi

# Token cap: keep the injected context bounded (better thin signal than none).
# head -c is the identity on shorter input, so no size pre-check is needed.
BLOCK=$(printf '%s' "$BLOCK" | head -c 8000)

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
