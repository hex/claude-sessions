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
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || exit 0

# Read the prompt purely as DATA: jq decodes it, and it is only ever fed to other
# commands as quoted stdin — never eval'd or expanded into a shell context.
INPUT=$(cat 2>/dev/null) || exit 0
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$PROMPT" ] || exit 0

# --- Classifier: positive iff a base-form work verb OR a source-file extension appears ---

VERB_RE='\b(implement|add|fix|refactor|debug|edit|modify|rename|remove|delete|write|build|create|update|change|extract|inline|split|merge|migrate|port|wire|hook up|optimize)\b'
EXT_RE='\.(ts|tsx|js|jsx|py|sh|bash|md|json|yaml|yml|toml|rs|go|swift|java|c|cpp|h|hpp)\b'

if ! printf '%s' "$PROMPT" | rg -qi "$VERB_RE" 2>/dev/null \
   && ! printf '%s' "$PROMPT" | rg -q "$EXT_RE" 2>/dev/null; then
    exit 0   # negative classification: silent pass-through
fi

# --- Cache (30-minute window) ---

SCOPE_DIR="$META_DIR/scope"
mkdir -p "$SCOPE_DIR" 2>/dev/null || true

# Prune stale entries on every invocation. This also serves as the freshness filter:
# any cache file that survives the prune was modified within the last 30 minutes.
find "$SCOPE_DIR" -name '*.md' -mmin +30 -delete 2>/dev/null || true

HASH=$(printf '%s' "$PROMPT" | shasum -a 256 2>/dev/null | cut -c1-16)
CACHE_FILE="$SCOPE_DIR/$HASH.md"

# Cache hit: reuse a fresh (post-prune) cache file without rescanning.
if [ -n "$HASH" ] && [ -f "$CACHE_FILE" ]; then
    jq -n --arg c "$(cat "$CACHE_FILE")" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    exit 0
fi

# --- Grounded scan (all bounded; all read-only git) ---

# Tokens: word-ish fragments of the prompt. Drop tokens <= 3 chars and any token without a
# letter — the latter defuses the lone-'.' scan bomb (a bare '.' as an rg fixed-string would
# match every path containing a period).
TOKENS=$(printf '%s' "$PROMPT" \
    | tr -cs '[:alnum:]_/.-' '\n' \
    | rg -v '^.{0,3}$' 2>/dev/null \
    | rg '[a-zA-Z]' 2>/dev/null \
    | sort -u)

# Build/vendor/meta dirs that must never be injected. The \.cs/ entry is load-bearing:
# without it /scope would surface the session's own metadata (discoveries.md, memory, ...).
EXCLUDE_RE='(^|/)(node_modules|target|dist|build|\.next|coverage|\.cs)/|(^|/)\.git/'

RELEVANT_FILES=""
if [ -n "$TOKENS" ]; then
    RELEVANT_FILES=$(git -C "$SESSION_DIR" ls-files 2>/dev/null \
        | rg -iF -f <(printf '%s' "$TOKENS") 2>/dev/null \
        | rg -v "$EXCLUDE_RE" 2>/dev/null \
        | head -30)
fi

# --- Build the scope block ---

TOMBSTONE='Scope: no tracked files matched (grounding from prompt only).'

if [ -n "$RELEVANT_FILES" ]; then
    BLOCK="## Scope (auto-grounded)

### Relevant files
$RELEVANT_FILES"

    # shellcheck disable=SC2086
    RECENT_COMMITS=$(git -C "$SESSION_DIR" log --oneline -5 --no-merges -- $RELEVANT_FILES 2>/dev/null | head -5)
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
if [ "$(printf '%s' "$BLOCK" | wc -c)" -gt 8000 ]; then
    BLOCK=$(printf '%s' "$BLOCK" | head -c 8000)
fi

# Cache the block so re-prompts within 30 minutes reuse it without rescanning.
[ -n "$HASH" ] && printf '%s' "$BLOCK" > "$CACHE_FILE" 2>/dev/null || true

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
