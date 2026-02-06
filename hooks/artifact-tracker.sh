#!/usr/bin/env bash
# ABOUTME: PreToolUse hook for automatic artifact tracking in cs sessions
# ABOUTME: Redirects script/config writes to artifacts, stores sensitive data in Keychain

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool information
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only process Write tool
if [ "$TOOL_NAME" != "Write" ]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Check if we're in a cs session
if [ -z "${CLAUDE_SESSION_NAME:-}" ]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
ARTIFACT_DIR="${CLAUDE_ARTIFACT_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

# Verify session directory exists
if [ ! -d "$SESSION_DIR" ] || [ ! -d "$ARTIFACT_DIR" ]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Extract file path and content from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')
FILE_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content')

# Get file extension and name
FILENAME=$(basename "$FILE_PATH")
EXTENSION="${FILENAME##*.}"
FILENAME_LOWER=$(echo "$FILENAME" | tr '[:upper:]' '[:lower:]')

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

# Sensitive file detection patterns
SENSITIVE_EXTENSIONS=("env")
SENSITIVE_NAME_PATTERNS=("key" "secret" "password" "token" "credential" "auth" "apikey" "api_key")

# Check if file is sensitive by extension
is_sensitive_extension() {
    for ext in "${SENSITIVE_EXTENSIONS[@]}"; do
        if [ "$EXTENSION" = "$ext" ]; then
            return 0
        fi
    done
    return 1
}

# Check if file is sensitive by name
is_sensitive_name() {
    for pattern in "${SENSITIVE_NAME_PATTERNS[@]}"; do
        if [[ "$FILENAME_LOWER" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Detect sensitive patterns in content
# Returns patterns like: API_KEY, SECRET_TOKEN, password, etc.
detect_sensitive_keys() {
    local content="$1"
    local keys=()

    # Match KEY=value patterns where KEY contains sensitive words
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Extract key from key=value or key: value patterns
        local key=""
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[=:] ]]; then
            key="${BASH_REMATCH[1]}"
        fi

        [ -z "$key" ] && continue

        local key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')

        # Check if key name suggests sensitive data
        for pattern in "${SENSITIVE_NAME_PATTERNS[@]}"; do
            if [[ "$key_lower" == *"$pattern"* ]]; then
                keys+=("$key")
                break
            fi
        done
    done <<< "$content"

    printf '%s\n' "${keys[@]}" | sort -u
}

# Store a secret using cs -secrets (cross-platform)
store_secret() {
    local name="$1"
    local value="$2"

    # Use cs -secrets for cross-platform secret storage
    if command -v cs >/dev/null 2>&1; then
        cs -secrets set "$name" "$value" >/dev/null 2>&1 || true
    elif command -v cs-secrets >/dev/null 2>&1; then
        # Fallback to standalone cs-secrets if cs not in PATH
        cs-secrets set "$name" "$value" >/dev/null 2>&1 || true
    else
        # Fallback to direct keychain access on macOS
        if [[ "$OSTYPE" == darwin* ]] && command -v security >/dev/null 2>&1; then
            local service="cs:${CLAUDE_SESSION_NAME}:${name}"
            security add-generic-password -a "$USER" -s "$service" -w "$value" -U 2>/dev/null || true
        fi
    fi
}

# Redact sensitive values in content
redact_content() {
    local content="$1"
    local redacted="$content"

    while IFS= read -r key; do
        [ -z "$key" ] && continue

        # Match various formats: KEY=value, KEY="value", KEY='value', KEY: value
        # Replace value with redaction notice

        # Handle KEY=value (unquoted)
        redacted=$(echo "$redacted" | sed -E "s/^([[:space:]]*)($key[[:space:]]*=[[:space:]]*)([^\"'][^[:space:]]*)/\1\2[REDACTED: stored in keychain as $key]/")

        # Handle KEY="value" (double quoted)
        redacted=$(echo "$redacted" | sed -E "s/^([[:space:]]*)($key[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\2\"[REDACTED: stored in keychain as $key]\"/")

        # Handle KEY='value' (single quoted)
        redacted=$(echo "$redacted" | sed -E "s/^([[:space:]]*)($key[[:space:]]*=[[:space:]]*)\'[^\']*\'/\1\2'[REDACTED: stored in keychain as $key]'/")

        # Handle YAML-style KEY: value
        redacted=$(echo "$redacted" | sed -E "s/^([[:space:]]*)($key[[:space:]]*:[[:space:]]+)(.+)/\1\2[REDACTED: stored in keychain as $key]/")

    done <<< "$(detect_sensitive_keys "$content")"

    echo "$redacted"
}

# Extract and store secrets from content
extract_and_store_secrets() {
    local content="$1"
    local stored_keys=()

    while IFS= read -r key; do
        [ -z "$key" ] && continue

        # Extract value for this key
        local value=""

        # Try KEY=value (unquoted)
        value=$(echo "$content" | grep -E "^[[:space:]]*$key[[:space:]]*=" | head -1 | sed -E "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//" | sed -E 's/^"([^"]*)".*/\1/' | sed -E "s/^'([^']*)'.*/\1/")

        # If still has quotes, it was unquoted value
        if [[ "$value" =~ ^[^\"\'[:space:]] ]]; then
            value=$(echo "$content" | grep -E "^[[:space:]]*$key[[:space:]]*=" | head -1 | sed -E "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//" | awk '{print $1}')
        fi

        # Try YAML-style KEY: value
        if [ -z "$value" ]; then
            value=$(echo "$content" | grep -E "^[[:space:]]*$key[[:space:]]*:" | head -1 | sed -E "s/^[[:space:]]*$key[[:space:]]*:[[:space:]]*//" | sed 's/[[:space:]]*$//')
        fi

        if [ -n "$value" ] && [ "$value" != "" ]; then
            store_secret "$key" "$value"
            stored_keys+=("$key")
        fi
    done <<< "$(detect_sensitive_keys "$content")"

    printf '%s\n' "${stored_keys[@]}"
}

# Determine if file should be treated as sensitive
IS_SENSITIVE=0
if is_sensitive_extension || is_sensitive_name; then
    IS_SENSITIVE=1
fi

# Check content for sensitive patterns even if filename doesn't suggest it
SENSITIVE_KEYS=$(detect_sensitive_keys "$FILE_CONTENT")
if [ -n "$SENSITIVE_KEYS" ]; then
    IS_SENSITIVE=1
fi

# Process content - extract secrets and redact if sensitive
FINAL_CONTENT="$FILE_CONTENT"
STORED_SECRETS=""
if [ $IS_SENSITIVE -eq 1 ] && [ -n "$SENSITIVE_KEYS" ]; then
    STORED_SECRETS=$(extract_and_store_secrets "$FILE_CONTENT")
    FINAL_CONTENT=$(redact_content "$FILE_CONTENT")
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

# Build secrets array for manifest
SECRETS_JSON="[]"
if [ -n "$STORED_SECRETS" ]; then
    SECRETS_JSON=$(echo "$STORED_SECRETS" | jq -R -s 'split("\n") | map(select(length > 0))')
fi

# Create manifest entry
MANIFEST_ENTRY=$(jq -n \
    --arg filename "$FILENAME" \
    --arg original_path "$FILE_PATH" \
    --arg timestamp "$TIMESTAMP" \
    --argjson secrets "$SECRETS_JSON" \
    --argjson is_sensitive "$IS_SENSITIVE" \
    '{
        filename: $filename,
        original_path: $original_path,
        timestamp: $timestamp,
        contains_secrets: $is_sensitive,
        secrets: (if ($secrets | length) > 0 then $secrets else null end)
    } | with_entries(select(.value != null))')

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
if [ $IS_SENSITIVE -eq 1 ] && [ -n "$STORED_SECRETS" ]; then
    SECRET_COUNT=$(echo "$STORED_SECRETS" | grep -c . || echo 0)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Artifact captured: $FILENAME (from $FILE_PATH) - $SECRET_COUNT secrets stored in Keychain" >> "$META_DIR/logs/session.log"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Artifact captured: $FILENAME (from $FILE_PATH)" >> "$META_DIR/logs/session.log"
fi

# Return decision with updated path and redacted content
jq -n \
    --arg decision "allow" \
    --arg path "$ARTIFACT_PATH" \
    --arg content "$FINAL_CONTENT" \
    '{
        permissionDecision: $decision,
        updatedInput: {
            file_path: $path,
            content: $content
        }
    }'

exit 0
