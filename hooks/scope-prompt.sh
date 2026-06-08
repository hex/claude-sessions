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

# --- Emit the scope block ---

TOMBSTONE='_scope: no matching tracked files; grounding from prompt only_'
BLOCK="## Scope (auto-grounded)

$TOMBSTONE"

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
