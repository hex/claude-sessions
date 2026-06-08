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
    _detected_dir=$(grep -oE 'fpath.*~/\.zsh/completions?' "$HOME/.zshrc" 2>/dev/null | grep -oE '~/\.zsh/completions?' | head -1 | sed "s|~|$HOME|") || true
    if [ -n "$_detected_dir" ]; then
        ZSH_COMPLETION_DIR="$_detected_dir"
    fi
fi
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
SESSIONS_DIR="${HOME}/.claude-sessions"
REPO_URL="https://raw.githubusercontent.com/hex/claude-sessions/main"
RELEASES_URL="https://github.com/hex/claude-sessions/releases/download"
CS_URL="${REPO_URL}/bin/cs"
CS_SECRETS_URL="${REPO_URL}/bin/cs-secrets"

# Hook URLs for web install
HOOK_SESSION_START_URL="${REPO_URL}/hooks/session-start.sh"
HOOK_ARTIFACT_TRACKER_URL="${REPO_URL}/hooks/artifact-tracker.sh"
HOOK_DISCOVERY_COMMITS_URL="${REPO_URL}/hooks/discovery-commits.sh"
HOOK_DISCOVERIES_REMINDER_URL="${REPO_URL}/hooks/discoveries-reminder.sh"
HOOK_PROSE_LINT_URL="${REPO_URL}/hooks/prose-lint.sh"
HOOK_SESSION_END_URL="${REPO_URL}/hooks/session-end.sh"
HOOK_SUBAGENT_CONTEXT_URL="${REPO_URL}/hooks/subagent-context.sh"
HOOK_TOOL_FAILURE_LOGGER_URL="${REPO_URL}/hooks/tool-failure-logger.sh"
HOOK_SESSION_AUTO_APPROVE_URL="${REPO_URL}/hooks/session-auto-approve.sh"
HOOK_BASH_LOGGER_URL="${REPO_URL}/hooks/bash-logger.sh"

# Hooks retired in past versions but possibly still installed from older cs versions.
# install.sh and bin/cs run_uninstall both clean these up. KEEP THIS LIST IN SYNC WITH bin/cs.
# When retiring a hook in a release, add its filename here.
RETIRED_HOOKS=(
    discoveries-archiver.sh   # retired in v2026.4.7 (archive flow replaced by size-budget compaction)
    aboutme-prereader.sh      # retired: source-file ABOUTME-header nudge experiment
    gotcha-prewriter.sh       # retired: brief pre-write gotcha-surfacing experiment; approach was rethought
    aboutme-validator.sh      # retired: never-shipped PostToolUse-on-Write experiment from a feature branch that registered the hook in settings.json without the file ever landing in source
    command-tracker.sh        # retired: CLI command capture; @-included payload did not influence model behaviour at a rate justifying its context cost
    files-scan.sh             # retired: workspace file indexer for .cs/files.md (assumption that the agent can't introspect file sizes has expired)
    files-context.sh          # retired: PreToolUse:Read context injector that surfaced files.md token estimates
    changes-tracker.sh        # retired: PostToolUse change log re-narrating git history into .cs/changes.md; git log/diff/status is authoritative
)

# Command URLs for web install
COMMAND_SUMMARY_URL="${REPO_URL}/commands/summary.md"
COMMAND_COMPACT_DISCOVERIES_URL="${REPO_URL}/commands/compact-discoveries.md"
COMMAND_CHECKPOINT_URL="${REPO_URL}/commands/checkpoint.md"
COMMAND_SWEEP_URL="${REPO_URL}/commands/sweep.md"
COMMAND_WRAP_URL="${REPO_URL}/commands/wrap.md"

# Skill URLs for web install
SKILL_STORE_SECRET_URL="${REPO_URL}/skills/store-secret/SKILL.md"
SKILL_PROSE_HYGIENE_URL="${REPO_URL}/skills/prose-hygiene/SKILL.md"

# Completion URLs for web install
COMPLETION_BASH_URL="${REPO_URL}/completions/cs.bash"
COMPLETION_ZSH_URL="${REPO_URL}/completions/_cs"

# Minisign public key for verifying signed releases
CS_SIGN_PUBKEY="RWQvs3IVdvrS8PJs0V0gwdJGPw/x5waQ6z6iqPQm90JfpxfcsSy9b9Vo"

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

# Install cs-tui (interactive session manager)
if [ "$INSTALL_METHOD" = "local" ] && [ -f "$SCRIPT_DIR/bin/cs-tui" ]; then
    installed "cs-tui" "$INSTALL_DIR/cs-tui"
    cp "$SCRIPT_DIR/bin/cs-tui" "$INSTALL_DIR/cs-tui"
    chmod +x "$INSTALL_DIR/cs-tui"
elif [ "$INSTALL_METHOD" = "web" ]; then
    _cs_version=$(grep -m1 "^VERSION=" "$INSTALL_DIR/cs" 2>/dev/null | cut -d'"' -f2 || echo "")
    _os=$(uname -s | tr '[:upper:]' '[:lower:]')
    _arch=$(uname -m)
    [ "$_arch" = "x86_64" ] && _arch="amd64"
    _tui_url="${RELEASES_URL}/v${_cs_version}/cs-tui-${_os}-${_arch}"
    if [ -n "$_cs_version" ] && curl -fsSL --head "$_tui_url" >/dev/null 2>&1; then
        installed "cs-tui" "$INSTALL_DIR/cs-tui"
        curl -fsSL "$_tui_url" -o "$INSTALL_DIR/cs-tui" || warn "Failed to download cs-tui — skipping"
        chmod +x "$INSTALL_DIR/cs-tui"

        # Verify cs-tui checksum (hard gate)
        _checksum_url="${RELEASES_URL}/v${_cs_version}/cs-tui-${_os}-${_arch}.sha256"
        if curl -fsSL "$_checksum_url" -o "$INSTALL_DIR/cs-tui.sha256" 2>/dev/null; then
            _expected=$(awk '{print $1}' "$INSTALL_DIR/cs-tui.sha256")
            _actual=""
            if command -v sha256sum >/dev/null 2>&1; then
                _actual=$(sha256sum "$INSTALL_DIR/cs-tui" | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                _actual=$(shasum -a 256 "$INSTALL_DIR/cs-tui" | awk '{print $1}')
            fi
            if [ -n "$_actual" ] && [ "$_expected" != "$_actual" ]; then
                rm -f "$INSTALL_DIR/cs-tui" "$INSTALL_DIR/cs-tui.sha256"
                warn "cs-tui checksum verification failed -- removed"
            fi
            rm -f "$INSTALL_DIR/cs-tui.sha256"
        fi

        # Verify cs-tui signature (best-effort: minisign may not be installed)
        _sig_url="${RELEASES_URL}/v${_cs_version}/cs-tui-${_os}-${_arch}.minisig"
        if curl -fsSL "$_sig_url" -o "$INSTALL_DIR/cs-tui.minisig" 2>/dev/null; then
            _ms_bin=""
            if command -v minisign >/dev/null 2>&1; then
                _ms_bin=$(command -v minisign)
            elif [ -x "$HOME/.local/bin/minisign" ]; then
                _ms_bin="$HOME/.local/bin/minisign"
            fi
            if [ -n "$_ms_bin" ]; then
                if ! "$_ms_bin" -Vm "$INSTALL_DIR/cs-tui" -P "$CS_SIGN_PUBKEY" -x "$INSTALL_DIR/cs-tui.minisig" >/dev/null 2>&1; then
                    rm -f "$INSTALL_DIR/cs-tui" "$INSTALL_DIR/cs-tui.minisig"
                    warn "cs-tui signature verification failed -- removed"
                fi
            fi
            rm -f "$INSTALL_DIR/cs-tui.minisig"
        fi
    else
        info "cs-tui not available for ${_os}-${_arch} — run 'cs' for help, or build from source: cd tui && cargo build --release"
    fi
fi

# Install hooks
installed "13 hooks" "$HOOKS_DIR/"
mkdir -p "$HOOKS_DIR"

# Remove any retired hook files that earlier cs versions installed but no longer ship.
# Settings.json entries are stripped further below.
for retired in "${RETIRED_HOOKS[@]}"; do
    if [ -f "$HOOKS_DIR/$retired" ]; then
        rm "$HOOKS_DIR/$retired"
        info "  Removed retired hook: $HOOKS_DIR/$retired"
    fi
done

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    cp "$HOOKS_SOURCE/session-start.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/artifact-tracker.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discovery-commits.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/discoveries-reminder.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/prose-lint.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/session-end.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/subagent-context.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/tool-failure-logger.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/session-auto-approve.sh" "$HOOKS_DIR/"
    cp "$HOOKS_SOURCE/bash-logger.sh" "$HOOKS_DIR/"
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$HOOK_SESSION_START_URL" -o "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        curl -fsSL "$HOOK_ARTIFACT_TRACKER_URL" -o "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        curl -fsSL "$HOOK_DISCOVERY_COMMITS_URL" -o "$HOOKS_DIR/discovery-commits.sh" || error "Failed to download discovery-commits.sh"
        curl -fsSL "$HOOK_DISCOVERIES_REMINDER_URL" -o "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        curl -fsSL "$HOOK_PROSE_LINT_URL" -o "$HOOKS_DIR/prose-lint.sh" || error "Failed to download prose-lint.sh"
        curl -fsSL "$HOOK_SESSION_END_URL" -o "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
        curl -fsSL "$HOOK_SUBAGENT_CONTEXT_URL" -o "$HOOKS_DIR/subagent-context.sh" || error "Failed to download subagent-context.sh"
        curl -fsSL "$HOOK_TOOL_FAILURE_LOGGER_URL" -o "$HOOKS_DIR/tool-failure-logger.sh" || error "Failed to download tool-failure-logger.sh"
        curl -fsSL "$HOOK_SESSION_AUTO_APPROVE_URL" -o "$HOOKS_DIR/session-auto-approve.sh" || error "Failed to download session-auto-approve.sh"
        curl -fsSL "$HOOK_BASH_LOGGER_URL" -o "$HOOKS_DIR/bash-logger.sh" || error "Failed to download bash-logger.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$HOOK_SESSION_START_URL" -O "$HOOKS_DIR/session-start.sh" || error "Failed to download session-start.sh"
        wget -q "$HOOK_ARTIFACT_TRACKER_URL" -O "$HOOKS_DIR/artifact-tracker.sh" || error "Failed to download artifact-tracker.sh"
        wget -q "$HOOK_DISCOVERY_COMMITS_URL" -O "$HOOKS_DIR/discovery-commits.sh" || error "Failed to download discovery-commits.sh"
        wget -q "$HOOK_DISCOVERIES_REMINDER_URL" -O "$HOOKS_DIR/discoveries-reminder.sh" || error "Failed to download discoveries-reminder.sh"
        wget -q "$HOOK_PROSE_LINT_URL" -O "$HOOKS_DIR/prose-lint.sh" || error "Failed to download prose-lint.sh"
        wget -q "$HOOK_SESSION_END_URL" -O "$HOOKS_DIR/session-end.sh" || error "Failed to download session-end.sh"
        wget -q "$HOOK_SUBAGENT_CONTEXT_URL" -O "$HOOKS_DIR/subagent-context.sh" || error "Failed to download subagent-context.sh"
        wget -q "$HOOK_TOOL_FAILURE_LOGGER_URL" -O "$HOOKS_DIR/tool-failure-logger.sh" || error "Failed to download tool-failure-logger.sh"
        wget -q "$HOOK_SESSION_AUTO_APPROVE_URL" -O "$HOOKS_DIR/session-auto-approve.sh" || error "Failed to download session-auto-approve.sh"
        wget -q "$HOOK_BASH_LOGGER_URL" -O "$HOOKS_DIR/bash-logger.sh" || error "Failed to download bash-logger.sh"
    fi
fi

chmod +x "$HOOKS_DIR"/*.sh

# Install commands
installed "commands" "$COMMANDS_DIR/"
mkdir -p "$COMMANDS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$COMMANDS_SOURCE/summary.md" "$COMMANDS_DIR/"
    cp "$COMMANDS_SOURCE/compact-discoveries.md" "$COMMANDS_DIR/"
    cp "$COMMANDS_SOURCE/checkpoint.md" "$COMMANDS_DIR/"
    cp "$COMMANDS_SOURCE/sweep.md" "$COMMANDS_DIR/"
    cp "$COMMANDS_SOURCE/wrap.md" "$COMMANDS_DIR/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMMAND_SUMMARY_URL" -o "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
        curl -fsSL "$COMMAND_COMPACT_DISCOVERIES_URL" -o "$COMMANDS_DIR/compact-discoveries.md" || error "Failed to download compact-discoveries.md"
        curl -fsSL "$COMMAND_CHECKPOINT_URL" -o "$COMMANDS_DIR/checkpoint.md" || error "Failed to download checkpoint.md"
        curl -fsSL "$COMMAND_SWEEP_URL" -o "$COMMANDS_DIR/sweep.md" || error "Failed to download sweep.md"
        curl -fsSL "$COMMAND_WRAP_URL" -o "$COMMANDS_DIR/wrap.md" || error "Failed to download wrap.md"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$COMMAND_SUMMARY_URL" -O "$COMMANDS_DIR/summary.md" || error "Failed to download summary.md"
        wget -q "$COMMAND_COMPACT_DISCOVERIES_URL" -O "$COMMANDS_DIR/compact-discoveries.md" || error "Failed to download compact-discoveries.md"
        wget -q "$COMMAND_CHECKPOINT_URL" -O "$COMMANDS_DIR/checkpoint.md" || error "Failed to download checkpoint.md"
        wget -q "$COMMAND_SWEEP_URL" -O "$COMMANDS_DIR/sweep.md" || error "Failed to download sweep.md"
        wget -q "$COMMAND_WRAP_URL" -O "$COMMANDS_DIR/wrap.md" || error "Failed to download wrap.md"
    fi
fi

# Install skills
SKILLS_DIR="$HOME/.claude/skills"
SKILLS_SOURCE="$SCRIPT_DIR/skills"
installed "skills" "$SKILLS_DIR/"
mkdir -p "$SKILLS_DIR/store-secret"
mkdir -p "$SKILLS_DIR/prose-hygiene"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SKILLS_SOURCE/store-secret/SKILL.md" "$SKILLS_DIR/store-secret/"
    cp "$SKILLS_SOURCE/prose-hygiene/SKILL.md" "$SKILLS_DIR/prose-hygiene/"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SKILL_STORE_SECRET_URL" -o "$SKILLS_DIR/store-secret/SKILL.md" || error "Failed to download store-secret skill"
        curl -fsSL "$SKILL_PROSE_HYGIENE_URL" -o "$SKILLS_DIR/prose-hygiene/SKILL.md" || error "Failed to download prose-hygiene skill"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$SKILL_STORE_SECRET_URL" -O "$SKILLS_DIR/store-secret/SKILL.md" || error "Failed to download store-secret skill"
        wget -q "$SKILL_PROSE_HYGIENE_URL" -O "$SKILLS_DIR/prose-hygiene/SKILL.md" || error "Failed to download prose-hygiene skill"
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
    DISCOVERY_COMMITS_PATH="$HOME/.claude/hooks/discovery-commits.sh"
    DISCOVERIES_REMINDER_PATH="$HOME/.claude/hooks/discoveries-reminder.sh"
    PROSE_LINT_PATH="$HOME/.claude/hooks/prose-lint.sh"
    SESSION_END_PATH="$HOME/.claude/hooks/session-end.sh"
    SUBAGENT_CONTEXT_PATH="$HOME/.claude/hooks/subagent-context.sh"
    TOOL_FAILURE_LOGGER_PATH="$HOME/.claude/hooks/tool-failure-logger.sh"
    SESSION_AUTO_APPROVE_PATH="$HOME/.claude/hooks/session-auto-approve.sh"
    BASH_LOGGER_PATH="$HOME/.claude/hooks/bash-logger.sh"

    # Tilde-path variants for dedup (handles entries added with ~ instead of $HOME)
    SESSION_START_TILDE="~/.claude/hooks/session-start.sh"
    ARTIFACT_TRACKER_TILDE="~/.claude/hooks/artifact-tracker.sh"
    DISCOVERY_COMMITS_TILDE="~/.claude/hooks/discovery-commits.sh"
    DISCOVERIES_REMINDER_TILDE="~/.claude/hooks/discoveries-reminder.sh"
    PROSE_LINT_TILDE="~/.claude/hooks/prose-lint.sh"
    SESSION_END_TILDE="~/.claude/hooks/session-end.sh"
    SUBAGENT_CONTEXT_TILDE="~/.claude/hooks/subagent-context.sh"
    TOOL_FAILURE_LOGGER_TILDE="~/.claude/hooks/tool-failure-logger.sh"
    SESSION_AUTO_APPROVE_TILDE="~/.claude/hooks/session-auto-approve.sh"
    BASH_LOGGER_TILDE="~/.claude/hooks/bash-logger.sh"

    # Strip retired hooks from any event in settings.json (event-agnostic since
    # we don't know which event the old version registered them under).
    for retired in "${RETIRED_HOOKS[@]}"; do
        retired_path="$HOME/.claude/hooks/$retired"
        retired_tilde="~/.claude/hooks/$retired"
        SETTINGS=$(echo "$SETTINGS" | jq --arg p "$retired_path" --arg t "$retired_tilde" '
            if .hooks then
                .hooks |= with_entries(
                    .value |= (
                        map(.hooks |= map(select(.command != $p and .command != $t)))
                        | map(select(.hooks | length > 0))
                    )
                )
                | .hooks |= with_entries(select(.value | length > 0))
                | if .hooks == {} then del(.hooks) else . end
            else . end
        ')
    done

    # Merge hooks: strip cs's command from any wrapper's nested .hooks array,
    # drop wrappers that emptied out, then append a fresh standalone wrapper
    # for cs's hook. This preserves non-cs entries that the user co-shipped
    # inside the same wrapper (eg. `~/bin/claude-status` alongside cs's
    # session-end.sh) — the prior shape dropped the entire wrapper whenever
    # it contained cs's command, taking sibling user hooks with it.
    #
    # Flat-shape entries (no `.hooks` field, command at top level) pass
    # through untouched because the `if .hooks then ... else . end` branch
    # skips them. The spec tests in tests/test_hooks.sh embed this same
    # filter shape via _install_merge_filter — keep them aligned.
    _merge_cs_hook() {
        local event="$1" path="$2" tilde="$3" timeout="$4" append_block="$5"
        SETTINGS=$(echo "$SETTINGS" | jq \
            --arg event "$event" \
            --arg path "$path" \
            --arg tilde "$tilde" \
            --argjson append "$append_block" '
            .hooks[$event] = (
                ((.hooks[$event] // []) | map(
                    if .hooks then
                        .hooks |= map(select(.command != $path and .command != $tilde))
                    else . end
                ) | map(select(.hooks == null or (.hooks | length > 0))))
                + [$append]
            )
        ')
    }

    _merge_cs_hook SessionStart "$SESSION_START_PATH" "$SESSION_START_TILDE" 30 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$SESSION_START_TILDE\",\"timeout\":30}]}"

    _merge_cs_hook PreToolUse "$ARTIFACT_TRACKER_PATH" "$ARTIFACT_TRACKER_TILDE" 10 \
        "{\"matcher\":\"Write\",\"hooks\":[{\"type\":\"command\",\"command\":\"$ARTIFACT_TRACKER_TILDE\",\"timeout\":10}]}"

    _merge_cs_hook PostToolUse "$DISCOVERY_COMMITS_PATH" "$DISCOVERY_COMMITS_TILDE" 10 \
        "{\"matcher\":\"Write|Edit\",\"hooks\":[{\"type\":\"command\",\"command\":\"$DISCOVERY_COMMITS_TILDE\",\"timeout\":10,\"async\":true}]}"

    _merge_cs_hook Stop "$DISCOVERIES_REMINDER_PATH" "$DISCOVERIES_REMINDER_TILDE" 10 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$DISCOVERIES_REMINDER_TILDE\",\"timeout\":10}]}"

    _merge_cs_hook Stop "$PROSE_LINT_PATH" "$PROSE_LINT_TILDE" 15 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$PROSE_LINT_TILDE\",\"timeout\":15}]}"

    _merge_cs_hook SessionEnd "$SESSION_END_PATH" "$SESSION_END_TILDE" 30 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$SESSION_END_TILDE\",\"timeout\":30}]}"

    _merge_cs_hook SubagentStart "$SUBAGENT_CONTEXT_PATH" "$SUBAGENT_CONTEXT_TILDE" 10 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$SUBAGENT_CONTEXT_TILDE\",\"timeout\":10}]}"

    _merge_cs_hook PostToolUseFailure "$TOOL_FAILURE_LOGGER_PATH" "$TOOL_FAILURE_LOGGER_TILDE" 10 \
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"$TOOL_FAILURE_LOGGER_TILDE\",\"timeout\":10,\"async\":true}]}"

    _merge_cs_hook PermissionRequest "$SESSION_AUTO_APPROVE_PATH" "$SESSION_AUTO_APPROVE_TILDE" 5 \
        "{\"matcher\":\"Write|Edit\",\"hooks\":[{\"type\":\"command\",\"command\":\"$SESSION_AUTO_APPROVE_TILDE\",\"timeout\":5}]}"

    _merge_cs_hook PreToolUse "$BASH_LOGGER_PATH" "$BASH_LOGGER_TILDE" 5 \
        "{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$BASH_LOGGER_TILDE\",\"timeout\":5}]}"

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

echo ""
echo "Getting started:"
echo "  cs my-first-session    # Create your first session"
echo "  cs -help               # See all commands"
echo "  cs -version            # Verify installation"
