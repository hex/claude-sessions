#!/usr/bin/env bash
# ABOUTME: PostToolUse hook that captures interesting CLI commands to commands.md
# ABOUTME: Filters trivial commands, scrubs secrets, deduplicates, and categorizes

set -euo pipefail

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

# Read hook input
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
    exit 0
fi

# --- Filter: skip trivial commands ---
BASE_CMD=$(echo "$COMMAND" | sed 's/^[A-Z_]*=[^ ]* *//' | awk '{print $1}')
BASE_CMD=$(basename "$BASE_CMD" 2>/dev/null || echo "$BASE_CMD")

TRIVIAL="cd ls pwd echo cat head tail clear mkdir rm rmdir mv cp touch which whoami date true false wc"
for t in $TRIVIAL; do
    if [ "$BASE_CMD" = "$t" ]; then
        exit 0
    fi
done

# --- Filter: skip bare interactive interpreters ---
INTERACTIVE="vim vi nano emacs python python3 node ruby irb bash zsh sh less more"
for i in $INTERACTIVE; do
    if [ "$BASE_CMD" = "$i" ]; then
        # Allow if run with -c, -e, -m, or --command flags
        if echo "$COMMAND" | grep -qE " -[cem] | --command "; then
            break
        fi
        exit 0
    fi
done

# --- Filter: skip git read-only commands ---
if echo "$COMMAND" | grep -qE '^git (status|log|diff|show|blame|branch)(\s|$)'; then
    exit 0
fi

# --- Secret scrubbing ---
SAFE_COMMAND="$COMMAND"
# Redact KEY=value patterns with sensitive names
SAFE_COMMAND=$(echo "$SAFE_COMMAND" | sed -E 's/([A-Z_]*(KEY|TOKEN|SECRET|PASSWORD|PASS|AUTH|CREDENTIAL)[A-Z_]*)=[^ ]*/\1=[REDACTED]/gI')
# Redact Bearer tokens
SAFE_COMMAND=$(echo "$SAFE_COMMAND" | sed -E 's/Bearer [A-Za-z0-9._-]+/Bearer [REDACTED]/g')
# Redact --token/--password/--secret flag values
SAFE_COMMAND=$(echo "$SAFE_COMMAND" | sed -E 's/(--?(token|password|secret|api[_-]?key))[= ][^ ]*/\1=[REDACTED]/gI')

# --- Categorize ---
categorize_command() {
    local cmd="$1"
    local base
    base=$(echo "$cmd" | awk '{print $1}')
    case "$cmd" in
        *build*|make\ *|gradle\ *|mvn\ *)
            echo "Build" ;;
        *test*|pytest*|jest*|vitest*|playwright*|cypress*)
            echo "Test" ;;
        *lint*|eslint*|prettier*|*clippy*|*fmt*|black\ *|ruff\ *|mypy\ *|tsc\ *)
            echo "Lint" ;;
        *deploy*|kubectl*|terraform*|helm*|aws\ *|gcloud\ *|az\ *)
            echo "Deploy" ;;
        docker\ compose\ up*|docker\ run*|*dev*|*start*|*serve*|uvicorn*|flask\ *)
            echo "Dev" ;;
        *)
            echo "Other" ;;
    esac
}

CATEGORY=$(categorize_command "$SAFE_COMMAND")
DATE_TODAY=$(date '+%Y-%m-%d')
COMMANDS_FILE="$META_DIR/commands.md"

# --- File locking ---
LOCKDIR="$COMMANDS_FILE.lock"
_cleanup_lock() { rmdir "$LOCKDIR" 2>/dev/null || true; }
LOCK_ATTEMPTS=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
    LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
    if [ "$LOCK_ATTEMPTS" -gt 20 ]; then
        exit 0
    fi
    sleep 0.1
done
trap '_cleanup_lock' EXIT

# Create the file if it doesn't exist
if [ ! -f "$COMMANDS_FILE" ]; then
    cat > "$COMMANDS_FILE" << 'HEADER'
# Project Commands
Auto-discovered CLI commands from prior sessions.

HEADER
fi

# --- Deduplicate or append ---
if grep -qF "\`$SAFE_COMMAND\`" "$COMMANDS_FILE" 2>/dev/null; then
    # Update count and date for existing entry
    CURRENT_COUNT=$(grep -F "\`$SAFE_COMMAND\`" "$COMMANDS_FILE" | head -1 | grep -oE '\[([0-9]+)x' | grep -oE '[0-9]+' || echo "1")
    NEW_COUNT=$((CURRENT_COUNT + 1))
    # Build escaped pattern for sed
    ESCAPED_CMD=$(printf '%s\n' "$SAFE_COMMAND" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    sed -i.bak "s|\(\`${ESCAPED_CMD}\`\) -- \[[0-9]*x, last: [0-9-]*\]|\1 -- [${NEW_COUNT}x, last: ${DATE_TODAY}]|" "$COMMANDS_FILE"
    rm -f "$COMMANDS_FILE.bak"
else
    # Ensure category header exists
    if ! grep -q "^## $CATEGORY" "$COMMANDS_FILE" 2>/dev/null; then
        printf '\n## %s\n' "$CATEGORY" >> "$COMMANDS_FILE"
    fi

    # Append under category using awk (more reliable than sed for appending)
    awk -v cat="## $CATEGORY" -v entry="- \`$SAFE_COMMAND\` -- [1x, last: $DATE_TODAY]" '
        $0 == cat { print; print entry; found=1; next }
        { print }
    ' "$COMMANDS_FILE" > "$COMMANDS_FILE.tmp" && mv "$COMMANDS_FILE.tmp" "$COMMANDS_FILE"
fi

_cleanup_lock
trap - EXIT

exit 0
