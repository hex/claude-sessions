#!/usr/bin/env bash
# ABOUTME: Stop hook that blocks turn-end when prose written this session has AI-slop tells
# ABOUTME: Lints summary.md + memory/*.md via `cs -lint`, scoped to this session's writes

set -euo pipefail

INPUT=$(cat 2>/dev/null || echo '{}')

approve() { echo '{"decision": "approve"}'; exit 0; }

# Skip inside subagents (Stop auto-converts to SubagentStop, but guard anyway)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && approve

# Only run in cs sessions
[ -z "${CLAUDE_SESSION_NAME:-}" ] && approve
SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
{ [ -z "$SESSION_DIR" ] || [ ! -d "$META_DIR" ]; } && approve

# Locate the cs binary (tests override via CS_BIN); skip gracefully if absent
CS_CMD="${CS_BIN:-$(command -v cs 2>/dev/null || true)}"
{ [ -z "$CS_CMD" ] || [ ! -x "$CS_CMD" ]; } && approve

# Cross-platform mtime in epoch seconds
_mtime() {
    if [[ "$OSTYPE" == darwin* ]]; then
        stat -f %m "$1" 2>/dev/null || echo 0
    else
        stat -c %Y "$1" 2>/dev/null || echo 0
    fi
}

# Session-start cutoff: session.lock is stamped when the session starts, so only
# prose modified at/after it was written this session. Without it, lint nothing
# (cannot tell this session's writes from the historical backlog).
LOCK="$META_DIR/session.lock"
[ ! -f "$LOCK" ] && approve
CUTOFF=$(_mtime "$LOCK")

# Candidate prose surfaces with no cross-session in-file backlog:
#   summary.md   — regenerated wholesale by /summary and /wrap
#   memory/*.md  — individual durable-fact entries (the prose bodies)
# Every narrative notebook (narrative.md and the per-actor narrative.<actor>.md)
# is intentionally excluded (append-heavy lab notebooks; need line-level diffing,
# not whole-file lint). MEMORY.md is excluded: it is the index, whose prescribed
# format uses em-dash separators by convention, not prose.
CANDIDATES=()
[ -f "$META_DIR/summary.md" ] && CANDIDATES+=("$META_DIR/summary.md")
if [ -d "$META_DIR/memory" ]; then
    while IFS= read -r m; do
        [ -n "$m" ] && CANDIDATES+=("$m")
    done < <(find "$META_DIR/memory" -type f -name '*.md' ! -name 'MEMORY.md' ! -name 'narrative*.md' 2>/dev/null)
fi
[ ${#CANDIDATES[@]} -eq 0 ] && approve

# Keep only files modified at/after the session-start cutoff
TARGETS=()
for f in "${CANDIDATES[@]}"; do
    [ "$(_mtime "$f")" -ge "$CUTOFF" ] && TARGETS+=("$f")
done
[ ${#TARGETS[@]} -eq 0 ] && approve

# Lint this session's prose
LINT_OUT=$("$CS_CMD" -lint "${TARGETS[@]}" 2>/dev/null) && LINT_RC=0 || LINT_RC=$?

ATTEMPTS_FILE="$META_DIR/.prose-lint-attempts"

# rc 0 = clean, rc 2 = unreadable/usage; only rc 1 (violations) blocks
if [ "${LINT_RC:-0}" -ne 1 ]; then
    rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
    approve
fi

# Loop guard: after 3 consecutive blocks on unresolved violations, allow the stop
# with a logged warning rather than trapping the session.
ATTEMPTS=0
[ -f "$ATTEMPTS_FILE" ] && ATTEMPTS=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
ATTEMPTS=$((ATTEMPTS + 1))
echo "$ATTEMPTS" > "$ATTEMPTS_FILE"
if [ "$ATTEMPTS" -gt 3 ]; then
    rm -f "$ATTEMPTS_FILE" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - prose-lint: ${ATTEMPTS} attempts with unresolved issues; allowing stop" \
        >> "$META_DIR/logs/session.log" 2>/dev/null || true
    approve
fi

REASON="prose-lint: AI-slop tells in prose written this session. Fix each line, then stop again:

$LINT_OUT

Replace em-dashes with a comma or period; reword flagged phrases in plain language. Recheck with: cs -lint <file>"

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
