#!/usr/bin/env bash
# ABOUTME: PreToolUse hook for automatic artifact tracking in cs sessions
# ABOUTME: Redirects script and config file writes to artifacts directory with manifest tracking

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool information
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only process Write tool
if [ "$TOOL_NAME" != "Write" ]; then
    # Not a Write operation, allow it
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Check if we're in a cs session
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    # Not in a cs session, allow write normally
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
ARTIFACT_DIR="${CLAUDE_ARTIFACT_DIR:-}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ] || [ ! -d "$ARTIFACT_DIR" ]; then
    # Session directory doesn't exist, allow write normally
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')

# Get file extension
FILENAME=$(basename "$FILE_PATH")
EXTENSION="${FILENAME##*.}"

# Define artifact file extensions
ARTIFACT_EXTENSIONS=(
    "sh" "bash" "zsh"
    "py" "js" "ts" "rb" "pl"
    "conf" "config" "json" "yaml" "yml" "toml" "ini" "env"
)

# Check if this file should be tracked as an artifact
SHOULD_TRACK=0
for ext in "${ARTIFACT_EXTENSIONS[@]}"; do
    if [ "$EXTENSION" = "$ext" ]; then
        SHOULD_TRACK=1
        break
    fi
done

# If not an artifact type, allow write normally
if [ $SHOULD_TRACK -eq 0 ]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Redirect to artifacts directory
ARTIFACT_PATH="$ARTIFACT_DIR/$FILENAME"

# Handle duplicate filenames by appending counter
if [ -f "$ARTIFACT_PATH" ]; then
    COUNTER=1
    BASE_NAME="${FILENAME%.*}"
    while [ -f "$ARTIFACT_DIR/${BASE_NAME}_${COUNTER}.$EXTENSION" ]; do
        COUNTER=$((COUNTER + 1))
    done
    ARTIFACT_PATH="$ARTIFACT_DIR/${BASE_NAME}_${COUNTER}.$EXTENSION"
    FILENAME="${BASE_NAME}_${COUNTER}.$EXTENSION"
fi

# Update MANIFEST.json with artifact metadata
MANIFEST="$ARTIFACT_DIR/MANIFEST.json"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Create manifest entry
MANIFEST_ENTRY=$(jq -n \
    --arg filename "$FILENAME" \
    --arg original_path "$FILE_PATH" \
    --arg timestamp "$TIMESTAMP" \
    '{
        filename: $filename,
        original_path: $original_path,
        timestamp: $timestamp
    }')

# Append to manifest (with file locking to prevent race conditions)
LOCKDIR="$MANIFEST.lock"
while ! mkdir "$LOCKDIR" 2>/dev/null; do
    sleep 0.1
done
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

CURRENT_MANIFEST=$(cat "$MANIFEST")
echo "$CURRENT_MANIFEST" | jq --argjson entry "$MANIFEST_ENTRY" '. += [$entry]' > "$MANIFEST"

rmdir "$LOCKDIR" 2>/dev/null
trap - EXIT

# Log the artifact capture
echo "$(date '+%Y-%m-%d %H:%M:%S') - Artifact captured: $FILENAME (from $FILE_PATH)" >> "$SESSION_DIR/logs/session.log"

# Return decision with updated path
jq -n \
    --arg decision "allow" \
    --arg path "$ARTIFACT_PATH" \
    '{
        permissionDecision: $decision,
        updatedInput: {
            file_path: $path
        }
    }'

exit 0
