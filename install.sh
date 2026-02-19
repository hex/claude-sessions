#!/usr/bin/env bash
# ABOUTME: Installation script for cs (Claude Code session manager)
# ABOUTME: Installs binaries, hooks, commands, skills, and shell completions

set -euo pipefail

# Colors - Claude warm palette (rust → orange → gold)
# Disable colors if NO_COLOR is set (https://no-color.org) or not a TTY
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    ORANGE=''
    GOLD=''
    RUST=''
    COMMENT=''
    NC=''
else
    RED='\033[38;2;239;83;80m'        # #ef5350 - warm red
    GREEN='\033[38;2;139;195;74m'     # #8bc34a - vibrant green
    YELLOW='\033[38;2;255;183;77m'    # #ffb74d - warm amber
    ORANGE='\033[38;2;255;138;101m'   # #ff8a65 - coral orange
    GOLD='\033[38;2;255;193;7m'       # #ffc107 - golden
    RUST='\033[38;2;230;74;25m'       # #e64a19 - terracotta
    COMMENT='\033[38;2;161;136;127m'  # #a1887f - warm taupe
    NC='\033[0m'
fi

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

installed() {
    echo -e "   ${COMMENT}Installed${NC} $1 ${COMMENT}→${NC} ${GOLD}$2${NC}"
}

show_banner() {
    # Smooth gradient: rust (#e64a19) → gold (#ffc107)
    local GT='\033[38;2;230;74;25mc\033[38;2;232;83;24ml\033[38;2;234;91;22ma\033[38;2;235;100;21mu\033[38;2;237;108;20md\033[38;2;239;117;19me\033[38;2;241;125;17m-\033[38;2;243;134;16ms\033[38;2;245;142;15me\033[38;2;246;151;14ms\033[38;2;248;159;12ms\033[38;2;250;168;11mi\033[38;2;252;176;10mo\033[38;2;254;185;9mn\033[38;2;255;193;7ms'
    echo ""
    echo -e "   ${RUST}╭───────────────────────╮${NC}"
    echo -e "   ${RUST}│${NC}    ${GT}${NC}    ${GOLD}│${NC}"
    echo -e "   ${GOLD}╰───────────────────────╯${NC}"
    echo ""
}

# Configuration
INSTALL_DIR="${HOME}/.local/bin"
HOOKS_DIR="${HOME}/.claude/hooks"
COMMANDS_DIR="${HOME}/.claude/commands"
BASH_COMPLETION_DIR="${HOME}/.bash_completion.d"
ZSH_COMPLETION_DIR="${HOME}/.zsh/completions"
# Detect existing zsh completion dir from user's fpath config
if [ -f "$HOME/.zshrc" ]; then
    _detected_dir=$(grep -oE 'fpath.*~/\.zsh/completions?' "$HOME/.zshrc" 2>/dev/null | grep -oE '~/\.zsh/completions?' | head -1 | sed "s|~|$HOME|")
    if [ -n "$_detected_dir" ]; then
        ZSH_COMPLETION_DIR="$_detected_dir"
    fi
fi
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SESSIONS_DIR="${HOME}/.claude-sessions"
REPO_URL="https://raw.githubusercontent.com/hex/claude-sessions/main"
CS_URL="${REPO_URL}/bin/cs"
CS_SECRETS_URL="${REPO_URL}/bin/cs-secrets"

# Hook URLs for web install
HOOK_SESSION_START_URL="${REPO_URL}/hooks/session-start.sh"
HOOK_ARTIFACT_TRACKER_URL="${REPO_URL}/hooks/artifact-tracker.sh"
HOOK_CHANGES_TRACKER_URL="${REPO_URL}/hooks/changes-tracker.sh"
HOOK_DISCOVERY_COMMITS_URL="${REPO_URL}/hooks/discovery-commits.sh"
HOOK_DISCOVERIES_REMINDER_URL="${REPO_URL}/hooks/discoveries-reminder.sh"
HOOK_DISCOVERIES_ARCHIVER_URL="${REPO_URL}/hooks/discoveries-archiver.sh"
HOOK_SESSION_END_URL="${REPO_URL}/hooks/session-end.sh"

# Command URLs for web install
COMMAND_SUMMARY_URL="${REPO_URL}/commands/summary.md"
COMMAND_COMPACT_DISCOVERIES_URL="${REPO_URL}/commands/compact-discoveries.md"

# Skill URLs for web install
SKILL_STORE_SECRET_URL="${REPO_URL}/skills/store-secret/SKILL.md"

# Completion URLs for web install
COMPLETION_BASH_URL="${REPO_URL}/completions/cs.bash"
COMPLETION_ZSH_URL="${REPO_URL}/completions/_cs"

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

# Show banner
show_banner

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Install cs script
installed "cs" "$INSTALL_DIR/cs"

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
installed "cs-secrets" "$INSTALL_DIR/cs-secrets"

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
installed "7 hooks" "$HOOKS_DIR/"
mkdir -p "$HOOKS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    cp "$HOOKS_SOURCE/session-start.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/artifact-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/changes-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discovery-commits.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discoveries-reminder.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discoveries-archiver.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/session-end.sh" "$HOOKS_DIR/"
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$HOOK_SESSION_START_URL" -o "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        curl -fsSL "$HOOK_ARTIFACT_TRACKER_URL" -o "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        curl -fsSL "$HOOK_CHANGES_TRACKER_URL" -o "$HOOKS_DIR/changes-tracker.sh" || error "Failed to download changes-tracker.sh"
        curl -fsSL "$HOOK_DISCOVERY_COMMITS_URL" -o "$HOOKS_DIR/discovery-commits.sh" || error "Failed to download discovery-commits.sh"
        curl -fsSL "$HOOK_DISCOVERIES_REMINDER_URL" -o "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        curl -fsSL "$HOOK_DISCOVERIES_ARCHIVER_URL" -o "$HOOKS_DIR/discoveries-archiver.sh" || error "Failed to download discoveries-archiver.sh"
        curl -fsSL "$HOOK_SESSION_END_URL" -o "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$HOOK_SESSION_START_URL" -O "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        wget -q "$HOOK_ARTIFACT_TRACKER_URL" -O "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        wget -q "$HOOK_CHANGES_TRACKER_URL" -O "$HOOKS_DIR/changes-tracker.sh" || error "Failed to download changes-tracker.sh"
        wget -q "$HOOK_DISCOVERY_COMMITS_URL" -O "$HOOKS_DIR/discovery-commits.sh" || error "Failed to download discovery-commits.sh"
        wget -q "$HOOK_DISCOVERIES_REMINDER_URL" -O "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        wget -q "$HOOK_DISCOVERIES_ARCHIVER_URL" -O "$HOOKS_DIR/discoveries-archiver.sh" || error "Failed to download discoveries-archiver.sh"
        wget -q "$HOOK_SESSION_END_URL" -O "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
    fi
fi

chmod +x "$HOOKS_DIR"/*.sh

# Install commands
installed "commands" "$COMMANDS_DIR/"
mkdir -p "$COMMANDS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$COMMANDS_SOURCE/summary.md" "$COMMANDS_DIR/"
    cp "$COMMANDS_SOURCE/compact-discoveries.md" "$COMMANDS_DIR/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMMAND_SUMMARY_URL" -o "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
        curl -fsSL "$COMMAND_COMPACT_DISCOVERIES_URL" -o "$COMMANDS_DIR/compact-discoveries.md" || error "Failed to download compact-discoveries.md"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$COMMAND_SUMMARY_URL" -O "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
        wget -q "$COMMAND_COMPACT_DISCOVERIES_URL" -O "$COMMANDS_DIR/compact-discoveries.md" || error "Failed to download compact-discoveries.md"
    fi
fi

# Install skills
SKILLS_DIR="$HOME/.claude/skills"
SKILLS_SOURCE="$SCRIPT_DIR/skills"
installed "skills" "$SKILLS_DIR/"
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

# Install shell completions
COMPLETIONS_SOURCE="$SCRIPT_DIR/completions"
COMPLETION_SETUP_NEEDED=""

# Bash completion
installed "completions" "bash, zsh"
mkdir -p "$BASH_COMPLETION_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$COMPLETIONS_SOURCE/cs.bash" "$BASH_COMPLETION_DIR/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMPLETION_BASH_URL" -o "$BASH_COMPLETION_DIR/cs.bash" || warn "Failed to download bash completion"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$COMPLETION_BASH_URL" -O "$BASH_COMPLETION_DIR/cs.bash" || warn "Failed to download bash completion"
    fi
fi

# Zsh completion
mkdir -p "$ZSH_COMPLETION_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$COMPLETIONS_SOURCE/_cs" "$ZSH_COMPLETION_DIR/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMPLETION_ZSH_URL" -o "$ZSH_COMPLETION_DIR/_cs" || warn "Failed to download zsh completion"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$COMPLETION_ZSH_URL" -O "$ZSH_COMPLETION_DIR/_cs" || warn "Failed to download zsh completion"
    fi
fi

# Configure Claude Code settings
installed "hook config" "~/.claude/settings.json"

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
    DISCOVERY_COMMITS_PATH="$HOME/.claude/hooks/discovery-commits.sh"
    DISCOVERIES_REMINDER_PATH="$HOME/.claude/hooks/discoveries-reminder.sh"
    DISCOVERIES_ARCHIVER_PATH="$HOME/.claude/hooks/discoveries-archiver.sh"
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

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$DISCOVERY_COMMITS_PATH" '
        .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(
            select(.hooks | all(.command != $path))
        )) + [{
            "matcher": "Write|Edit",
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

    SETTINGS=$(echo "$SETTINGS" | jq --arg path "$DISCOVERIES_ARCHIVER_PATH" '
        .hooks.PreCompact = ((.hooks.PreCompact // []) | map(
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
    echo ""
    warn "   WARNING: $INSTALL_DIR is not in your PATH"
    echo ""
    case "$OSTYPE" in
        msys*|cygwin*|mingw*)
            warn "   For Git Bash on Windows, add to ~/.bashrc:"
            warn "     export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
        *)
            warn "   Add this line to your ~/.bashrc, ~/.zshrc, or equivalent:"
            warn "     export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac
    echo ""
fi

# Get version for completion message
CS_VERSION=$(grep -m1 "^VERSION=" "$INSTALL_DIR/cs" 2>/dev/null | cut -d'"' -f2 || echo "unknown")

echo ""
echo -e "   ${GREEN}✓${NC} ${ORANGE}Installation complete${NC} ${COMMENT}(${CS_VERSION})${NC}"
echo ""

# Check if completion setup is needed
SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    bash)
        if ! grep -q 'bash_completion.d/cs.bash' "$HOME/.bashrc" 2>/dev/null; then
            warn "   To enable tab completion, add to ~/.bashrc:"
            warn "     [[ -f ~/.bash_completion.d/cs.bash ]] && source ~/.bash_completion.d/cs.bash"
            echo ""
        fi
        ;;
    zsh)
        if ! grep -qE 'fpath.*zsh/completions?' "$HOME/.zshrc" 2>/dev/null; then
            warn "   To enable tab completion, add to ~/.zshrc (before compinit):"
            warn "     fpath=(~/.zsh/completions \$fpath)"
            warn "     autoload -Uz compinit && compinit"
            echo ""
        fi
        ;;
esac

echo -e "   ${RUST}Usage:${NC} cs ${GOLD}<session-name>${NC}"
echo ""
echo -e "   ${COMMENT}Examples:${NC}"
echo -e "     ${COMMENT}cs${NC} ${GOLD}debug-api${NC}    ${COMMENT}# Create or resume session${NC}"
echo -e "     ${COMMENT}cs${NC} ${GOLD}server-fix${NC}   ${COMMENT}# Work on server issues${NC}"
echo ""
