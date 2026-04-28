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

# Skip subagent commands — they're exploratory, not part of the user's workflow
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
    exit 0
fi

# Strip leading env/cd/export prefixes so trivial-filter and categorizer see
# the actual verb. `cd dir && cargo test` should not be filtered as trivial cd.
strip_leading_prefixes() {
    local cmd="$1"
    local prev=""
    while [ "$cmd" != "$prev" ]; do
        prev="$cmd"
        cmd=$(echo "$cmd" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^;&]+[;&]+[[:space:]]*//')
        cmd=$(echo "$cmd" | sed -E 's/^[[:space:]]*export[[:space:]]+[^;&]+[;&]+[[:space:]]*//')
        cmd=$(echo "$cmd" | sed -E 's/^[[:space:]]*[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+//')
    done
    printf '%s\n' "$cmd"
}

# --- Filter: skip trivial commands ---
STRIPPED=$(strip_leading_prefixes "$COMMAND")
BASE_CMD=$(echo "$STRIPPED" | awk '{print $1}')
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
# Redact glued short-flag passwords for db CLIs (mysql/mysqldump/psql -pSECRET).
# Scoped to those tools to avoid eating -p in docker run, ssh -p, etc.
SAFE_COMMAND=$(echo "$SAFE_COMMAND" | sed -E 's/((^|[ 	])(mysql|mysqldump|psql)[^|;&]* -p)[^ ]+/\1[REDACTED]/g')
# Redact the positional value of `cs -secrets set <name> <value>` — the call
# itself logs the secret if not scrubbed here.
SAFE_COMMAND=$(echo "$SAFE_COMMAND" | sed -E 's/(cs -secrets set [^ ]+ )[^|;&]+/\1[REDACTED]/g')

# --- Categorize ---
categorize_command() {
    local stripped verb arg1
    stripped=$(strip_leading_prefixes "$1")
    verb=$(echo "$stripped" | awk '{print $1}')
    arg1=$(echo "$stripped" | awk '{print $2}')

    case "$verb" in
        npm|yarn|pnpm|bun)
            case "$arg1" in
                test|t) echo "Test" ;;
                lint) echo "Lint" ;;
                build|run) echo "Build" ;;
                *) echo "Dev" ;;
            esac ;;
        cargo)
            case "$arg1" in
                test|bench) echo "Test" ;;
                clippy|fmt) echo "Lint" ;;
                run) echo "Dev" ;;
                *) echo "Build" ;;
            esac ;;
        make|gradle|mvn|cmake|bazel|tsc|webpack|rollup|vite|esbuild|sbt|swift)
            echo "Build" ;;
        pytest|jest|vitest|playwright|cypress|mocha|tape|ava)
            echo "Test" ;;
        eslint|prettier|clippy|black|ruff|mypy|flake8|rubocop|gofmt|stylelint|biome)
            echo "Lint" ;;
        kubectl|terraform|helm|aws|gcloud|az|fly|vercel|heroku|ansible)
            echo "Deploy" ;;
        docker|docker-compose|uvicorn|flask|gunicorn|node|deno|rails|hugo|jekyll)
            echo "Dev" ;;
        rg|fd|grep|find|ag|ack|fzf|ast-grep|locate)
            echo "Search" ;;
        mysql|mysqldump|psql|sqlite3|mongo|mongosh|redis-cli|pg_dump|pg_restore)
            echo "DB" ;;
        ssh|scp|rsync|sftp|curl|wget)
            echo "Remote" ;;
        git|gh|hg)
            echo "Git" ;;
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

# --- Skill promotion detection ---
DATES_FILE="$META_DIR/command-dates.txt"
PROMOTED_FILE="$META_DIR/promoted-commands.txt"

# Record this command + date (for cross-session detection)
echo "${SAFE_COMMAND}|${DATE_TODAY}" >> "$DATES_FILE" 2>/dev/null || true

# Check promotion threshold: 3+ uses AND 2+ distinct dates
if [ -f "$DATES_FILE" ] && [ ! -f "$PROMOTED_FILE" ] || ! grep -qF "$SAFE_COMMAND" "$PROMOTED_FILE" 2>/dev/null; then
    USE_COUNT=$(grep -cF "${SAFE_COMMAND}|" "$DATES_FILE" 2>/dev/null || echo "0")
    DISTINCT_DATES=$(grep -F "${SAFE_COMMAND}|" "$DATES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')

    if [ "$USE_COUNT" -ge 3 ] && [ "$DISTINCT_DATES" -ge 2 ]; then
        # Mark as promoted so we don't suggest again
        echo "$SAFE_COMMAND" >> "$PROMOTED_FILE" 2>/dev/null || true

        # Output suggestion via additionalContext (shown to Claude)
        echo '{"additionalContext": "A frequently used command was detected: `'"$SAFE_COMMAND"'` (used '"$USE_COUNT"' times across '"$DISTINCT_DATES"' sessions). Consider creating a reusable skill with: /skillify '"$SAFE_COMMAND"'"}'
    fi
fi

_cleanup_lock
trap - EXIT

exit 0
