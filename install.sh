#!/usr/bin/env bash
# ABOUTME: Installation script for cs (Claude Code session manager)
# ABOUTME: Downloads and installs cs to ~/.local/bin and hooks to ~/.claude/hooks

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHT_BLUE='\033[1;36m'
PINK='\033[0;35m'
GREY='\033[0;90m'
DIM='\033[2m'
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
COMMANDS_DIR="${HOME}/.claude/commands"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SESSIONS_DIR="${HOME}/.claude-sessions"
REPO_URL="https://raw.githubusercontent.com/hex/claude-sessions/main"
CS_URL="${REPO_URL}/bin/cs"
CS_SECRETS_URL="${REPO_URL}/bin/cs-secrets"

# Hook URLs for web install
HOOK_SESSION_START_URL="${REPO_URL}/hooks/session-start.sh"
HOOK_ARTIFACT_TRACKER_URL="${REPO_URL}/hooks/artifact-tracker.sh"
HOOK_CHANGES_TRACKER_URL="${REPO_URL}/hooks/changes-tracker.sh"
HOOK_DISCOVERIES_REMINDER_URL="${REPO_URL}/hooks/discoveries-reminder.sh"
HOOK_SESSION_END_URL="${REPO_URL}/hooks/session-end.sh"

# Command URLs for web install
COMMAND_SUMMARY_URL="${REPO_URL}/commands/summary.md"

# Skill URLs for web install
SKILL_STORE_SECRET_URL="${REPO_URL}/skills/store-secret/SKILL.md"

# Detect if running from cloned repo or web install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/bin/cs" ]; then
    # Running from cloned repo
    CS_SOURCE="$SCRIPT_DIR/bin/cs"
    HOOKS_SOURCE="$SCRIPT_DIR/hooks"
    COMMANDS_SOURCE="$SCRIPT_DIR/commands"
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

# Install cs-secrets utility
info "Installing cs-secrets to $INSTALL_DIR/cs-secrets"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SCRIPT_DIR/bin/cs-secrets" "$INSTALL_DIR/cs-secrets"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$CS_SECRETS_URL" -o "$INSTALL_DIR/cs-secrets" || error "Failed to download cs-secrets"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$CS_SECRETS_URL" -O "$INSTALL_DIR/cs-secrets" || error "Failed to download cs-secrets"
    fi
fi

chmod +x "$INSTALL_DIR/cs-secrets"

# Install hooks
info "Installing hooks to $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    cp "$HOOKS_SOURCE/session-start.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/artifact-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/changes-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discoveries-reminder.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/session-end.sh" "$HOOKS_DIR/"
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$HOOK_SESSION_START_URL" -o "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        curl -fsSL "$HOOK_ARTIFACT_TRACKER_URL" -o "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        curl -fsSL "$HOOK_CHANGES_TRACKER_URL" -o "$HOOKS_DIR/changes-tracker.sh" || error "Failed to download changes-tracker.sh"
        curl -fsSL "$HOOK_DISCOVERIES_REMINDER_URL" -o "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        curl -fsSL "$HOOK_SESSION_END_URL" -o "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$HOOK_SESSION_START_URL" -O "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        wget -q "$HOOK_ARTIFACT_TRACKER_URL" -O "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        wget -q "$HOOK_CHANGES_TRACKER_URL" -O "$HOOKS_DIR/changes-tracker.sh" || error "Failed to download changes-tracker.sh"
        wget -q "$HOOK_DISCOVERIES_REMINDER_URL" -O "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        wget -q "$HOOK_SESSION_END_URL" -O "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    fi
fi

chmod +x "$HOOKS_DIR"/*.sh

# Install commands
info "Installing commands to $COMMANDS_DIR"
mkdir -p "$COMMANDS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$COMMANDS_SOURCE/summary.md" "$COMMANDS_DIR/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMMAND_SUMMARY_URL" -o "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$COMMAND_SUMMARY_URL" -O "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
    fi
fi

# Install skills
SKILLS_DIR="$HOME/.claude/skills"
SKILLS_SOURCE="$SCRIPT_DIR/skills"
info "Installing skills to $SKILLS_DIR"
mkdir -p "$SKILLS_DIR/store-secret"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SKILLS_SOURCE/store-secret/SKILL.md" "$SKILLS_DIR/store-secret/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SKILL_STORE_SECRET_URL" -o "$SKILLS_DIR/store-secret/SKILL.md" || error "Failed to download store-secret skill"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$SKILL_STORE_SECRET_URL" -O "$SKILLS_DIR/store-secret/SKILL.md" || error "Failed to download store-secret skill"
    fi
fi

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
    CHANGES_TRACKER_PATH="$HOME/.claude/hooks/changes-tracker.sh"
    DISCOVERIES_REMINDER_PATH="$HOME/.claude/hooks/discoveries-reminder.sh"
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

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$CHANGES_TRACKER_PATH" '
        .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(
            select(.hooks | all(.command != $path))
        )) + [{
            "matcher": "",
            "hooks": [{
                "type": "command",
                "command": $path,
                "timeout": 10
            }]
        }]
    ')

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$DISCOVERIES_REMINDER_PATH" '
        .hooks.Stop = ((.hooks.Stop // []) | map(
            select(.hooks | all(.command != $path))
        )) + [{
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
    case "$OSTYPE" in
        msys*|cygwin*|mingw*)
            warn "For Git Bash on Windows, add to ~/.bashrc:"
            warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
        *)
            warn "Add this line to your ~/.bashrc, ~/.zshrc, or equivalent:"
            warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac
    warn ""
fi

info ""
info "Installation complete!"
echo ""
echo -e "${DIM}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}Installed:${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - cs command to $INSTALL_DIR/cs${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - cs-secrets command to $INSTALL_DIR/cs-secrets${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - Session hooks to $HOOKS_DIR/${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - Slash commands to $COMMANDS_DIR/${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - Skills to $SKILLS_DIR/${NC}"
echo -e "${DIM}│${NC} ${LIGHT_BLUE}  - Hook configuration in $CLAUDE_SETTINGS${NC}"
echo -e "${DIM}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${PINK}Usage: cs <session-name>${NC}"
echo ""
echo -e "${GREY}Examples:${NC}"
echo -e "${GREY}  cs debug-api    # Create or resume 'debug-api' session${NC}"
echo -e "${GREY}  cs server-fix   # Create or resume 'server-fix' session${NC}"
echo ""
