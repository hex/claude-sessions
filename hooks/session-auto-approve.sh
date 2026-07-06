#!/usr/bin/env bash
# ABOUTME: PermissionRequest hook that auto-approves writes to .cs/ metadata files
# ABOUTME: Falls through to normal permission prompt for all other operations

set -euo pipefail

INPUT=$(cat)

# Only run in cs sessions
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Only consider Write and Edit tools
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Never auto-approve a path spelled with a .. component — it could resolve
# outside the session's .cs/ tree and defeat the permission prompt entirely.
case "$FILE_PATH" in
    ..|../*|*/../*|*/..) exit 0 ;;
esac

# Canonicalize the write target's parent directory so that no symlink or
# spelling can smuggle the path outside .cs/. A parent that doesn't resolve
# (e.g. a not-yet-created nested dir) falls through to the normal prompt.
PARENT_DIR="${FILE_PATH%/*}"
[ "$PARENT_DIR" = "$FILE_PATH" ] && PARENT_DIR="."
REAL_PARENT="$(cd "$PARENT_DIR" 2>/dev/null && pwd -P)" || exit 0
REAL_META="$(cd "$META_DIR" 2>/dev/null && pwd -P)" || REAL_META=""
REAL_CS="$(cd "$SESSION_DIR/.cs" 2>/dev/null && pwd -P)" || REAL_CS=""

# Only auto-approve files whose real parent is inside the session's .cs/ tree.
case "$REAL_PARENT/" in
    "${REAL_META:-/cs-no-meta}"/*|"${REAL_META:-/cs-no-meta}"/ \
        |"${REAL_CS:-/cs-no-cs}"/*|"${REAL_CS:-/cs-no-cs}"/)
        jq -n '{
            hookSpecificOutput: {
                hookEventName: "PermissionRequest",
                decision: { behavior: "allow" }
            }
        }'
        ;;
    *)
        # Fall through to normal permission prompt
        exit 0
        ;;
esac
