#!/usr/bin/env bash
# ABOUTME: PreCompact hook that prompts a narrative flush before context is compacted
# ABOUTME: Injects a reminder to capture uncaptured findings into .cs/memory/narrative.md

set -euo pipefail

# Read hook input (PreCompact payload); tolerate empty
INPUT=$(cat 2>/dev/null || echo '{}')

# Only act in cs sessions; fail open otherwise
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$META_DIR" ]; then
    exit 0
fi

NARRATIVE_FILE="$META_DIR/memory/narrative.md"

CONTEXT="Context is about to be compacted. Before it is, capture any uncaptured session findings, decisions, or in-progress state into ${NARRATIVE_FILE} (the session lab notebook) so they survive the context loss. Append as regular content; skip if nothing new."

jq -nc --arg c "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "PreCompact", additionalContext: $c}}' 2>/dev/null \
    || true

exit 0
