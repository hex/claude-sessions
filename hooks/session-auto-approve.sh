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

# Only auto-approve files inside the session's .cs/ directory
case "$FILE_PATH" in
    "$META_DIR"/*|"$SESSION_DIR/.cs"/*)
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
