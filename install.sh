#!/usr/bin/env bash
# ABOUTME: Installation script for cs (Claude Code session manager)
# ABOUTME: Downloads and installs cs to ~/.local/bin and hooks to ~/.claude/hooks

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Configuration
INSTALL_DIR="${HOME}/.local/bin"
HOOKS_DIR="${HOME}/.claude/hooks"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SESSIONS_DIR="${HOME}/.claude-sessions"
REPO_URL="https://raw.githubusercontent.com/hex/claude-sessions/main"
CS_URL="${REPO_URL}/bin/cs"

# Hook URLs for web install
HOOK_SESSION_START_URL="${REPO_URL}/hooks/session-start.sh"
HOOK_ARTIFACT_TRACKER_URL="${REPO_URL}/hooks/artifact-tracker.sh"
HOOK_SESSION_END_URL="${REPO_URL}/hooks/session-end.sh"

# Uninstall function
uninstall() {
    info "Uninstalling cs..."

    # Remove cs script
    if [ -f "$INSTALL_DIR/cs" ]; then
        rm "$INSTALL_DIR/cs"
        info "Removed $INSTALL_DIR/cs"
    fi

    # Remove hooks
    for hook in session-start.sh artifact-tracker.sh session-end.sh; do
        if [ -f "$HOOKS_DIR/$hook" ]; then
            rm "$HOOKS_DIR/$hook"
            info "Removed $HOOKS_DIR/$hook"
        fi
    done

    # Remove cs hooks from settings.json (preserve other hooks)
    if [ -f "$CLAUDE_SETTINGS" ] && command -v jq >/dev/null 2>&1; then
        SESSION_START_PATH="$HOME/.claude/hooks/session-start.sh"
        ARTIFACT_TRACKER_PATH="$HOME/.claude/hooks/artifact-tracker.sh"
        SESSION_END_PATH="$HOME/.claude/hooks/session-end.sh"

        SETTINGS=$(cat "$CLAUDE_SETTINGS")

        # Remove our SessionStart hook
        SETTINGS=$(echo "$SETTINGS" | jq --arg path "$SESSION_START_PATH" '
            if .hooks.SessionStart then
                .hooks.SessionStart = [.hooks.SessionStart[] | select(.hooks | all(.command != $path))]
            else . end
        ')

        # Remove our PreToolUse Write hook
        SETTINGS=$(echo "$SETTINGS" | jq --arg path "$ARTIFACT_TRACKER_PATH" '
            if .hooks.PreToolUse then
                .hooks.PreToolUse = [.hooks.PreToolUse[] | select(
                    (.matcher == "Write" and (.hooks | any(.command == $path))) | not
                )]
            else . end
        ')

        # Remove our SessionEnd hook
        SETTINGS=$(echo "$SETTINGS" | jq --arg path "$SESSION_END_PATH" '
            if .hooks.SessionEnd then
                .hooks.SessionEnd = [.hooks.SessionEnd[] | select(.hooks | all(.command != $path))]
            else . end
        ')

        # Clean up empty hook arrays
        SETTINGS=$(echo "$SETTINGS" | jq '
            if .hooks then
                .hooks |= with_entries(select(.value | length > 0))
                | if .hooks == {} then del(.hooks) else . end
            else . end
        ')

        echo "$SETTINGS" > "$CLAUDE_SETTINGS"
        info "Modified $CLAUDE_SETTINGS (removed cs hooks)"

        # Remove settings.json if empty
        if [ "$(jq 'keys | length' "$CLAUDE_SETTINGS")" -eq 0 ]; then
            rm "$CLAUDE_SETTINGS"
            info "Removed empty $CLAUDE_SETTINGS"
        fi
    fi

    # Ask about session data
    if [ -d "$SESSIONS_DIR" ]; then
        echo ""
        warn "Session data exists at $SESSIONS_DIR"
        read -p "Delete session data? This cannot be undone. [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$SESSIONS_DIR"
            info "Removed $SESSIONS_DIR"
        else
            info "Kept $SESSIONS_DIR"
        fi
    fi

    info ""
    info "Uninstall complete!"
    exit 0
}

# Check for --uninstall flag
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    uninstall
fi

# Detect if running from cloned repo or web install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/bin/cs" ]; then
    # Running from cloned repo
    CS_SOURCE="$SCRIPT_DIR/bin/cs"
    HOOKS_SOURCE="$SCRIPT_DIR/hooks"
    INSTALL_METHOD="local"
else
    # Running from web (curl | bash)
    INSTALL_METHOD="web"
fi

# Check for Claude Code
if ! command -v claude >/dev/null 2>&1; then
    warn "Claude Code (claude) not found in PATH"
    warn "Please install Claude Code before using cs"
    warn "Visit: https://github.com/anthropics/claude-code"
    echo ""
fi

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Install cs script
info "Installing cs to $INSTALL_DIR/cs"

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    cp "$CS_SOURCE" "$INSTALL_DIR/cs"
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$CS_URL" -o "$INSTALL_DIR/cs" || error "Failed to download cs script"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$CS_URL" -O "$INSTALL_DIR/cs" || error "Failed to download cs script"
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
fi

chmod +x "$INSTALL_DIR/cs"

# Install hooks
info "Installing hooks to $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    cp "$HOOKS_SOURCE/session-start.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/artifact-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/session-end.sh" "$HOOKS_DIR/"
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$HOOK_SESSION_START_URL" -o "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        curl -fsSL "$HOOK_ARTIFACT_TRACKER_URL" -o "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        curl -fsSL "$HOOK_SESSION_END_URL" -o "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$HOOK_SESSION_START_URL" -O "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        wget -q "$HOOK_ARTIFACT_TRACKER_URL" -O "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        wget -q "$HOOK_SESSION_END_URL" -O "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    fi
fi

chmod +x "$HOOKS_DIR"/*.sh

# Configure Claude Code settings
info "Configuring Claude Code hooks"

# Create or merge settings.json
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found - cannot configure hooks automatically."
    warn "See README for manual hook configuration."
else
    # Start with existing settings or empty object
    if [ -f "$CLAUDE_SETTINGS" ]; then
        SETTINGS=$(cat "$CLAUDE_SETTINGS")
    else
        SETTINGS='{}'
    fi

    # Our hook script paths (for detecting existing cs hooks)
    SESSION_START_PATH="$HOME/.claude/hooks/session-start.sh"
    ARTIFACT_TRACKER_PATH="$HOME/.claude/hooks/artifact-tracker.sh"
    SESSION_END_PATH="$HOME/.claude/hooks/session-end.sh"

    # Merge hooks: remove existing cs hooks, then add ours
    # This prevents duplicates on reinstall while preserving other hooks
    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$SESSION_START_PATH" '
        .hooks.SessionStart = ((.hooks.SessionStart // []) | map(
            select(.hooks | all(.command != $path))
        )) + [{
            "hooks": [{
                "type": "command",
                "command": $path,
                "timeout": 10
            }]
        }]
    ')

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$ARTIFACT_TRACKER_PATH" '
        .hooks.PreToolUse = ((.hooks.PreToolUse // []) | map(
            select((.matcher == "Write" and (.hooks | any(.command == $path))) | not)
        )) + [{
            "matcher": "Write",
            "hooks": [{
                "type": "command",
                "command": $path,
                "timeout": 10
            }]
        }]
    ')

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$SESSION_END_PATH" '
        .hooks.SessionEnd = ((.hooks.SessionEnd // []) | map(
            select(.hooks | all(.command != $path))
        )) + [{
            "hooks": [{
                "type": "command",
                "command": $path,
                "timeout": 10
            }]
        }]
    ')

    echo "$SETTINGS" > "$CLAUDE_SETTINGS"
fi

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn ""
    warn "WARNING: $INSTALL_DIR is not in your PATH"
    warn ""
    warn "Add this line to your ~/.bashrc, ~/.zshrc, or equivalent:"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    warn ""
fi

info ""
info "Installation complete!"
info ""
info "Installed:"
info "  - cs command to $INSTALL_DIR/cs"
info "  - Session hooks to $HOOKS_DIR/"
info "  - Hook configuration in $CLAUDE_SETTINGS"
info ""
info "Usage: cs <session-name>"
info ""
info "Examples:"
info "  cs debug-api    # Create or resume 'debug-api' session"
info "  cs server-fix   # Create or resume 'server-fix' session"
info ""
