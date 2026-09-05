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
    BOLD=''
    NC=''
else
    RED='\033[38;2;239;83;80m'        # #ef5350 - warm red
    GREEN='\033[38;2;139;195;74m'     # #8bc34a - vibrant green
    YELLOW='\033[38;2;255;183;77m'    # #ffb74d - warm amber
    ORANGE='\033[38;2;255;138;101m'   # #ff8a65 - coral orange
    GOLD='\033[38;2;255;193;7m'       # #ffc107 - golden
    RUST='\033[38;2;230;74;25m'       # #e64a19 - terracotta
    COMMENT='\033[38;2;161;136;127m'  # #a1887f - warm taupe
    BOLD='\033[1m'
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
HOOKS_PARENT_DIR="${HOME}/.claude/hooks"
HOOKS_DIR="${HOOKS_PARENT_DIR}/cs"
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
# Payload ref: `cs -update` pins this to the release tag (v<version>) so the
# downloaded scripts/hooks match the verified installer; a fresh curl|bash
# install defaults to main.
REPO_URL="https://raw.githubusercontent.com/hex/claude-sessions/${CS_INSTALL_REF:-main}"
RELEASES_URL="https://github.com/hex/claude-sessions/releases/download"
CS_URL="${REPO_URL}/bin/cs"
CS_SECRETS_URL="${REPO_URL}/bin/cs-secrets"
CS_STATUSLINE_URL="${REPO_URL}/bin/cs-statusline"
CS_SUBAGENT_STATUSLINE_URL="${REPO_URL}/bin/cs-subagent-statusline"

# Hook scripts cs ships; deployed to HOOKS_DIR and registered in settings.json.
# KEEP THIS LIST IN SYNC WITH bin/cs's CS_HOOKS.
CS_HOOKS=(
    session-start.sh
    autosave-commits.sh
    narrative-reminder.sh
    session-end.sh
    subagent-context.sh
    tool-failure-logger.sh
    session-auto-approve.sh
    bash-logger.sh
    scope-prompt.sh
)

# Files under hooks/ that the hooks SOURCE, or that cs points other tools at,
# rather than files Claude Code invokes as hooks. They ship and are removed
# alongside the hooks, but must never be registered against an event. The
# prompt-rewriter scripts are reached through $EDITOR, not through any hook event.
# KEEP THIS LIST IN SYNC WITH bin/cs.
CS_HOOK_LIBS=(
    cs-resolve.sh
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
)

# Everything that lands in HOOKS_DIR, for the copy and cleanup loops.
CS_HOOK_FILES=("${CS_HOOKS[@]}" "${CS_HOOK_LIBS[@]}")

# Hooks retired in past versions but possibly still installed from older cs versions.
# install.sh and bin/cs run_uninstall both clean these up. KEEP THIS LIST IN SYNC WITH bin/cs.
# When retiring a hook in a release, add its filename here.
RETIRED_HOOKS=(
    narrative-precompact.sh   # retired: PreCompact cannot inject context (no hookSpecificOutput/additionalContext); Stop reminder covers capture
    discovery-commits.sh      # renamed to autosave-commits.sh (general all-file crash recovery, not discoveries-specific)
    discoveries-reminder.sh   # retired: session narrative moved to .cs/memory/narrative.md (native lazy-load, no size budget)
    discoveries-archiver.sh   # retired in v2026.4.7 (archive flow replaced by size-budget compaction)
    aboutme-prereader.sh      # retired: source-file ABOUTME-header nudge experiment
    gotcha-prewriter.sh       # retired: brief pre-write gotcha-surfacing experiment; approach was rethought
    aboutme-validator.sh      # retired: never-shipped PostToolUse-on-Write experiment from a feature branch that registered the hook in settings.json without the file ever landing in source
    command-tracker.sh        # retired: CLI command capture; @-included payload did not influence model behaviour at a rate justifying its context cost
    files-scan.sh             # retired: workspace file indexer for .cs/files.md (assumption that the agent can't introspect file sizes has expired)
    files-context.sh          # retired: PreToolUse:Read context injector that surfaced files.md token estimates
    changes-tracker.sh        # retired: PostToolUse change log re-narrating git history into .cs/changes.md; git log/diff/status is authoritative
    artifact-tracker.sh       # retired: PreToolUse:Write redirect was inert (updatedInput path rewrite is not honored by the harness); tracking removed entirely
    prose-lint.sh             # retired with the `cs -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
)

# Slash commands cs ships; deployed to COMMANDS_DIR.
# KEEP THIS LIST IN SYNC WITH bin/cs's CS_COMMANDS.
CS_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as SKILLS_DIR/<name>/SKILL.md.
# KEEP THIS LIST IN SYNC WITH bin/cs's CS_SKILLS.
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    merge
    write-as-me
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and bin/cs run_uninstall both delete these
# directories. KEEP THIS LIST IN SYNC WITH bin/cs's RETIRED_SKILLS.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
)

# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
# KEEP THIS LIST IN SYNC WITH bin/cs's CS_SKILL_FILES.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
)

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

# Install cs-statusline (Claude Code status line)
installed "cs-statusline" "$INSTALL_DIR/cs-statusline"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SCRIPT_DIR/bin/cs-statusline" "$INSTALL_DIR/cs-statusline"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$CS_STATUSLINE_URL" -o "$INSTALL_DIR/cs-statusline" || error "Failed to download cs-statusline"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$CS_STATUSLINE_URL" -O "$INSTALL_DIR/cs-statusline" || error "Failed to download cs-statusline"
    fi
fi

chmod +x "$INSTALL_DIR/cs-statusline"

# Install cs-subagent-statusline (Claude Code agent-panel rows). It sources
# cs-statusline for the shared palette, so the two must land in the same dir.
installed "cs-subagent-statusline" "$INSTALL_DIR/cs-subagent-statusline"

if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SCRIPT_DIR/bin/cs-subagent-statusline" "$INSTALL_DIR/cs-subagent-statusline"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$CS_SUBAGENT_STATUSLINE_URL" -o "$INSTALL_DIR/cs-subagent-statusline" || error "Failed to download cs-subagent-statusline"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$CS_SUBAGENT_STATUSLINE_URL" -O "$INSTALL_DIR/cs-subagent-statusline" || error "Failed to download cs-subagent-statusline"
    fi
fi

chmod +x "$INSTALL_DIR/cs-subagent-statusline"

# Install cs-tui (interactive session manager).
#
# bin/cs-tui is a gitignored build artifact and nothing regenerates it: build.sh
# assembles bin/cs from lib/ and has no TUI arm, while `cargo build --release`
# writes to tui/target/release/. Installing bin/cs-tui unconditionally therefore
# ships whatever binary happens to be sitting there, which has silently deployed
# a picker weeks older than the release being installed. A version check cannot
# catch it either: the picker carries no version of its own, so `cs -version`
# reads correct while the picker is stale. Prefer whichever of the two is newer.
_cs_tui_src="$SCRIPT_DIR/bin/cs-tui"
_cs_tui_built="$SCRIPT_DIR/tui/target/release/cs-tui"
if [ -f "$_cs_tui_built" ] && { [ ! -f "$_cs_tui_src" ] || [ "$_cs_tui_built" -nt "$_cs_tui_src" ]; }; then
    _cs_tui_src="$_cs_tui_built"
fi
if [ "$INSTALL_METHOD" = "local" ] && [ -f "$_cs_tui_src" ]; then
    installed "cs-tui" "$INSTALL_DIR/cs-tui"
    cp "$_cs_tui_src" "$INSTALL_DIR/cs-tui"
    chmod +x "$INSTALL_DIR/cs-tui"
elif [ "$INSTALL_METHOD" = "web" ]; then
    _cs_version=$(grep -m1 "^VERSION=" "$INSTALL_DIR/cs" 2>/dev/null | cut -d'"' -f2 || echo "")
    _os=$(uname -s | tr '[:upper:]' '[:lower:]')
    _arch=$(uname -m)
    [ "$_arch" = "x86_64" ] && _arch="amd64"
    _tui_base="cs-tui-${_os}-${_arch}"
    _tui_dst="$INSTALL_DIR/cs-tui"
    _tui_url="${RELEASES_URL}/v${_cs_version}/${_tui_base}"
    if [ -n "$_cs_version" ] && curl -fsSL --head "$_tui_url" >/dev/null 2>&1 \
        && curl -fsSL "$_tui_url" -o "$_tui_dst"; then
        installed "cs-tui" "$_tui_dst"
        chmod +x "$_tui_dst"

        # Verify cs-tui checksum (hard gate). The rule is the one stated in
        # lib/20-update.sh's verify_checksum: a gate that cannot verify must not
        # pass. An unfetchable .sha256 and a digest that cannot be computed both
        # leave the binary unverified, so both remove it.
        _checksum_url="${RELEASES_URL}/v${_cs_version}/${_tui_base}.sha256"
        _verified=0
        _mismatch=0
        if curl -fsSL "$_checksum_url" -o "$_tui_dst.sha256" 2>/dev/null; then
            _expected=$(awk '{print $1}' "$_tui_dst.sha256")
            _actual=""
            # `|| _actual=""`: the script runs under `set -euo pipefail`, so a
            # digest tool that exits non-zero would otherwise abort the whole
            # install here — leaving both the unverified binary and its .sha256
            # behind — rather than falling through to the removal below.
            if command -v sha256sum >/dev/null 2>&1; then
                _actual=$(sha256sum "$_tui_dst" 2>/dev/null | awk '{print $1}') || _actual=""
            elif command -v shasum >/dev/null 2>&1; then
                _actual=$(shasum -a 256 "$_tui_dst" 2>/dev/null | awk '{print $1}') || _actual=""
            fi
            if [ -n "$_expected" ] && [ -n "$_actual" ]; then
                if [ "$_expected" = "$_actual" ]; then
                    _verified=1
                else
                    _mismatch=1
                fi
            fi
            rm -f "$_tui_dst.sha256"
        fi
        if [ "$_verified" != 1 ]; then
            rm -f "$_tui_dst"
            if [ "$_mismatch" = 1 ]; then
                warn "cs-tui checksum verification failed -- removed"
            else
                warn "cs-tui could not be verified (no checksum or no digest tool) -- removed"
            fi
        fi

        # Verify cs-tui signature (best-effort: minisign may not be installed)
        _sig_url="${RELEASES_URL}/v${_cs_version}/${_tui_base}.minisig"
        if curl -fsSL "$_sig_url" -o "$_tui_dst.minisig" 2>/dev/null; then
            _ms_bin=""
            if command -v minisign >/dev/null 2>&1; then
                _ms_bin=$(command -v minisign)
            elif [ -x "$HOME/.local/bin/minisign" ]; then
                _ms_bin="$HOME/.local/bin/minisign"
            fi
            # Nothing to verify once the checksum gate above removed the binary:
            # minisign fails on a path that is not there, which would report a
            # signature failure for a removal the gate has already explained,
            # and send the reader after release-key tampering that never was.
            if [ -n "$_ms_bin" ] && [ -f "$_tui_dst" ]; then
                if ! "$_ms_bin" -Vm "$_tui_dst" -P "$CS_SIGN_PUBKEY" -x "$_tui_dst.minisig" >/dev/null 2>&1; then
                    rm -f "$_tui_dst" "$_tui_dst.minisig"
                    warn "cs-tui signature verification failed -- removed"
                fi
            fi
            rm -f "$_tui_dst.minisig"
        fi
    else
        info "cs-tui not available for ${_os}-${_arch} — run 'cs' for help, or build from source: cd tui && cargo build --release"
    fi
fi

# Remove a stale opposite-platform TUI binary so a cross-platform reinstall can
# never leave cs-tui and cs-tui.exe side by side — which would let PATH lookup
# or the sibling probe select the wrong one and fail to launch. Keep only the
# name this platform installs.
rm -f "$INSTALL_DIR/cs-tui.exe"

# Install hooks
installed "${#CS_HOOKS[@]} hooks" "$HOOKS_DIR/"
mkdir -p "$HOOKS_DIR"

# Remove any retired hook files that earlier cs versions installed but no longer ship.
# Settings.json entries are stripped further below. Retired hooks may sit in
# HOOKS_DIR or, for installs that deployed hooks flat, its parent directory.
for retired in "${RETIRED_HOOKS[@]}"; do
    for dir in "$HOOKS_DIR" "$HOOKS_PARENT_DIR"; do
        if [ -f "$dir/$retired" ]; then
            rm "$dir/$retired"
            info "  Removed retired hook: $dir/$retired"
        fi
    done
done

# The subdirectory copy is canonical; remove parent-level copies left by
# installs that deployed hooks flat into ~/.claude/hooks/.
for hook in "${CS_HOOK_FILES[@]}"; do
    if [ -f "$HOOKS_PARENT_DIR/$hook" ]; then
        rm "$HOOKS_PARENT_DIR/$hook"
        info "  Removed $HOOKS_PARENT_DIR/$hook"
    fi
done

if [ "$INSTALL_METHOD" = "local" ]; then
    # Install from local clone
    for hook in "${CS_HOOK_FILES[@]}"; do
        cp "$HOOKS_SOURCE/$hook" "$HOOKS_DIR/"
    done
else
    # Download from GitHub
    if command -v curl >/dev/null 2>&1; then
        for hook in "${CS_HOOK_FILES[@]}"; do
            curl -fsSL "$REPO_URL/hooks/$hook" -o "$HOOKS_DIR/$hook" || error "Failed to download $hook"
        done
    elif command -v wget >/dev/null 2>&1; then
        for hook in "${CS_HOOK_FILES[@]}"; do
            wget -q "$REPO_URL/hooks/$hook" -O "$HOOKS_DIR/$hook" || error "Failed to download $hook"
        done
    fi
fi

chmod +x "$HOOKS_DIR"/*.sh

# Install commands
installed "commands" "$COMMANDS_DIR/"
mkdir -p "$COMMANDS_DIR"

if [ "$INSTALL_METHOD" = "local" ]; then
    for cmd in "${CS_COMMANDS[@]}"; do
        cp "$COMMANDS_SOURCE/$cmd" "$COMMANDS_DIR/"
    done
else
    if command -v curl >/dev/null 2>&1; then
        for cmd in "${CS_COMMANDS[@]}"; do
            curl -fsSL "$REPO_URL/commands/$cmd" -o "$COMMANDS_DIR/$cmd" || error "Failed to download $cmd"
        done
    elif command -v wget >/dev/null 2>&1; then
        for cmd in "${CS_COMMANDS[@]}"; do
            wget -q "$REPO_URL/commands/$cmd" -O "$COMMANDS_DIR/$cmd" || error "Failed to download $cmd"
        done
    fi
fi

# Install skills
SKILLS_DIR="$HOME/.claude/skills"
SKILLS_SOURCE="$SCRIPT_DIR/skills"
installed "skills" "$SKILLS_DIR/"

# Drop skill directories earlier cs versions installed but no longer ship. A
# skill left on disk keeps answering its slash command, so a rename is not
# complete until the old directory is gone.
for retired in "${RETIRED_SKILLS[@]}"; do
    if [ -d "$SKILLS_DIR/$retired" ]; then
        rm -rf "$SKILLS_DIR/$retired"
        info "  Removed retired skill: $SKILLS_DIR/$retired/"
    fi
done

for skill in "${CS_SKILLS[@]}"; do
    mkdir -p "$SKILLS_DIR/$skill"
done

if [ "$INSTALL_METHOD" = "local" ]; then
    for skill in "${CS_SKILLS[@]}"; do
        cp "$SKILLS_SOURCE/$skill/SKILL.md" "$SKILLS_DIR/$skill/"
    done
    for skill_file in "${CS_SKILL_FILES[@]}"; do
        mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
        cp -p "$SKILLS_SOURCE/$skill_file" "$SKILLS_DIR/$skill_file"
    done
else
    if command -v curl >/dev/null 2>&1; then
        for skill in "${CS_SKILLS[@]}"; do
            curl -fsSL "$REPO_URL/skills/$skill/SKILL.md" -o "$SKILLS_DIR/$skill/SKILL.md" || error "Failed to download $skill skill"
        done
        for skill_file in "${CS_SKILL_FILES[@]}"; do
            mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
            curl -fsSL "$REPO_URL/skills/$skill_file" -o "$SKILLS_DIR/$skill_file" || error "Failed to download $skill_file"
            chmod +x "$SKILLS_DIR/$skill_file"
        done
    elif command -v wget >/dev/null 2>&1; then
        for skill in "${CS_SKILLS[@]}"; do
            wget -q "$REPO_URL/skills/$skill/SKILL.md" -O "$SKILLS_DIR/$skill/SKILL.md" || error "Failed to download $skill skill"
        done
        for skill_file in "${CS_SKILL_FILES[@]}"; do
            mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
            wget -q "$REPO_URL/skills/$skill_file" -O "$SKILLS_DIR/$skill_file" || error "Failed to download $skill_file"
            chmod +x "$SKILLS_DIR/$skill_file"
        done
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
        # An empty or invalid-JSON settings.json would make every jq stage below
        # silently produce nothing; back it up and start fresh instead.
        if [ -z "${SETTINGS//[[:space:]]/}" ] || ! printf '%s' "$SETTINGS" | jq -e . >/dev/null 2>&1; then
            cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.cs-bak" 2>/dev/null || true
            warn "settings.json was empty or invalid JSON — backed up to settings.json.cs-bak and starting fresh"
            SETTINGS='{}'
        fi
    else
        SETTINGS='{}'
    fi

    # Tilde spelling of HOOKS_DIR (settings.json entries use ~ instead of $HOME)
    HOOKS_TILDE_DIR="~/.claude/hooks/cs"

    # Remove a hook registration from any event in settings.json, matching
    # either path spelling; drops wrappers that empty out.
    # KEEP THE jq FILTER IN SYNC WITH bin/cs's _strip_hook_registration —
    # tests/test_install.sh diffs the two filter bodies.
    _strip_hook_registration() {
        local p="$1" t="$2"
        SETTINGS=$(echo "$SETTINGS" | jq --arg p "$p" --arg t "$t" '
            if .hooks then
                .hooks |= with_entries(
                    .value |= (
                        map(.hooks |= map(select(.command != $p and .command != $t)))
                        | map(select(.hooks | length > 0))
                    )
                )
            else . end
        ')
    }

    # Strip retired hooks from any event in settings.json (event-agnostic since
    # we don't know which event the old version registered them under). Covers
    # both deployment layouts.
    for retired in "${RETIRED_HOOKS[@]}"; do
        _strip_hook_registration "$HOOKS_PARENT_DIR/$retired" "~/.claude/hooks/$retired"
        _strip_hook_registration "$HOOKS_DIR/$retired" "$HOOKS_TILDE_DIR/$retired"
    done

    # Strip parent-level registrations of current hooks (flat-layout installs);
    # _merge_cs_hook re-registers each one under HOOKS_DIR below.
    for hook in "${CS_HOOKS[@]}"; do
        _strip_hook_registration "$HOOKS_PARENT_DIR/$hook" "~/.claude/hooks/$hook"
    done

    # Drop events that emptied out entirely after the strips
    SETTINGS=$(echo "$SETTINGS" | jq '
        if .hooks then
            .hooks |= with_entries(select(.value | length > 0))
            | if .hooks == {} then del(.hooks) else . end
        else . end
    ')

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
        local event="$1" file="$2" timeout="$3" matcher="${4:-}" async="${5:-}" rewake="${6:-}"
        local path="$HOOKS_DIR/$file" tilde="$HOOKS_TILDE_DIR/$file"
        local append
        # asyncRewake makes a hook's exit 2 wake the model with its stderr,
        # wrapped in a system-reminder under the rewakeMessage prefix. It
        # implies async, so it does not also need the async flag. Without it the
        # hook still runs and its output is discarded — the wake becomes a
        # five-second toast nobody reads.
        #
        # The labels are static in settings.json while the one FileChanged entry
        # now carries two wake kinds — cross-session mail and the /clear
        # rotation kick — so they name neither. The stderr reason says which it
        # is; a label claiming "mail" would tell the user the wrong story about
        # what started the turn, and was doing exactly that until it was caught
        # in a live rotation.
        append=$(jq -n --arg cmd "$tilde" --argjson timeout "$timeout" \
            --arg matcher "$matcher" --arg async "$async" --arg rewake "$rewake" '
            (if $matcher != "" then {matcher: $matcher} else {} end)
            + {hooks: [
                {type: "command", command: $cmd, timeout: $timeout}
                + (if $async == "true" then {async: true} else {} end)
                + (if $rewake == "true" then {
                       asyncRewake: true,
                       rewakeMessage: "cs woke this session:",
                       rewakeSummary: "cs"
                   } else {} end)
              ]}
        ')
        SETTINGS=$(echo "$SETTINGS" | jq \
            --arg event "$event" \
            --arg path "$path" \
            --arg tilde "$tilde" \
            --argjson append "$append" '
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

    # Registration table: event, file, timeout, [matcher], [async], [rewake]
    #
    # FileChanged carries no matcher on purpose: for that event the matcher both
    # seeds the watch path and supplies the dispatch query as the changed file's
    # BASENAME, so a matcher naming the maildir would watch it and then never
    # fire — and maildir filenames are unpredictable, so no basename matcher can
    # be written either. The watch path arrives instead as watchPaths from
    # session-start.sh, and the hook filters file_path to its own mailbox.
    #
    # CwdChanged is registered for one reason: a cwd change REPLACES the
    # session's dynamic watch list with what its CwdChanged hooks return, so
    # answering nothing loses the maildir watch for the rest of the session.
    # Registering FileChanged is itself what opens that path, so the mailbox has
    # to answer the event its own registration enables.
    _merge_cs_hook SessionStart       session-start.sh       30
    _merge_cs_hook PostToolUse        autosave-commits.sh    10 "Write|Edit" true
    _merge_cs_hook Stop               narrative-reminder.sh  10
    _merge_cs_hook SessionEnd         session-end.sh         30
    _merge_cs_hook SubagentStart      subagent-context.sh    10
    _merge_cs_hook PostToolUseFailure tool-failure-logger.sh 10 "" true
    _merge_cs_hook PermissionRequest  session-auto-approve.sh 5 "Write|Edit"
    _merge_cs_hook PreToolUse         bash-logger.sh          5 "Bash"
    _merge_cs_hook UserPromptSubmit   scope-prompt.sh         3
    _merge_cs_hook FileChanged        narrative-reminder.sh  10 "" "" true
    _merge_cs_hook CwdChanged         narrative-reminder.sh   5

    # Register cs-statusline as the Claude Code status line. A status line the
    # user already configured is never replaced silently: prompt when a
    # terminal is attached, otherwise keep it and print how to switch.
    _statusline_cmd="$INSTALL_DIR/cs-statusline"
    _current_statusline=$(echo "$SETTINGS" | jq -r '.statusLine.command // ""')
    # A "no" is remembered here so `cs -update` (which re-runs this installer)
    # stops asking on every release. `cs -statusline enable` clears it,
    # `cs -statusline disable` sets it (KEEP IN SYNC with lib/70-statusline.sh).
    _statusline_declined="${XDG_CONFIG_HOME:-$HOME/.config}/cs/statusline-declined"
    # A preference memo must never take the install down with it. Both writes
    # below run under errexit and `touch` ends the && list, so a failure — an
    # unwritable ~/.config/cs, which an earlier root-run install leaves behind —
    # aborted the run BEFORE settings.json was written: hooks copied but never
    # registered, no version stamp, no completion message. Report and continue.
    # The second message is used when the memo did not land, so the user is not
    # told they will stop being asked when they will.
    # Declining is permanent, so it gets its own line rather than a clause at
    # the end of the outcome. The default answer at the replace prompt is "no",
    # which means a user pressing enter to skip one release opts out for good —
    # a decision they should see stated, not skim past.
    _remember_statusline_decline() {  # outcome_line, undo_hint
        if mkdir -p "$(dirname "$_statusline_declined")" 2>/dev/null \
            && touch "$_statusline_declined" 2>/dev/null; then
            info "$1"
            info "You won't be asked again. $2"
        else
            warn "$1"
            warn "  (could not record the choice in $_statusline_declined, so cs -update will ask again)"
        fi
    }

    # Show what is being offered before asking for it. The payload is fixed and
    # the segments are pinned: the live ones read git state, unread mail and
    # rate limits from whatever session is running, which would put the user's
    # own branch name and inbox into an installer preview. Best-effort — a
    # sample that cannot render must not stop the install, so every failure
    # path here falls through to the question on its own.
    _preview_statusline() {
        command -v jq >/dev/null 2>&1 || return 0
        [ -x "$INSTALL_DIR/cs-statusline" ] || return 0
        local sample
        sample=$(jq -nc '{
            session_name: "my-session",
            context_window: {used_percentage: 34},
            model: {display_name: "Opus 5", id: "claude-opus-5"},
            effort: {level: "high"},
            rate_limits: {five_hour: {used_percentage: 41},
                          seven_day: {used_percentage: 63}}
        }' 2>/dev/null) || return 0
        # Draw it for the terminal it will appear in. The statusline falls back
        # to its dark palette whenever it can measure nothing, and a subprocess
        # inherits no way to measure — so a light terminal saw a dark bar, which
        # is precisely the thing a "what it looks like" sample must not get
        # wrong. install.sh still owns the tty and has just installed the binary
        # that can answer, so it asks; an unknown answer is left unset and the
        # statusline keeps its own fallback.
        # Only signals already in the environment. `cs -detect-theme` would be
        # the accurate answer, but it asks the terminal over OSC 11 and writes
        # that probe straight to /dev/tty — which no capture can intercept, so
        # the escape and its reply paint themselves across the installer's
        # output. A preview is not worth a garbled screen: read what the
        # terminal has already published, and when it has published nothing,
        # leave the statusline its own fallback.
        local _theme="${CS_TERM_THEME:-}"
        if [ -z "$_theme" ] && [ -n "${COLORFGBG:-}" ]; then
            case "${COLORFGBG##*;}" in
                7|9|1[0-5]) _theme="light" ;;
                0|[1-6]|8)  _theme="dark" ;;
            esac
        fi
        case "$_theme" in light|dark) ;; *) _theme="" ;; esac
        # Exported in a subshell rather than as a command prefix: an empty
        # ${_theme:+...} expansion would vanish and leave the binary running as
        # the prefix's own argument list, which renders nothing.
        local rendered
        rendered=$(
            export CS_STATUSLINE_SEGMENTS=logo,session,model,ctx,limits
            [ -z "$_theme" ] || export CS_TERM_THEME="$_theme"
            printf '%s' "$sample" | "$INSTALL_DIR/cs-statusline" 2>/dev/null
        ) || return 0
        [ -n "$rendered" ] || return 0
        # No indent: the statusline opens with a reset that eats leading spaces,
        # so an indented printf produced a bar flush against the margin while
        # every other line sat three spaces in.
        echo ""
        info "   This is what it looks like:"
        printf '%s\n' "$rendered"
        echo ""
    }

    # Each branch only decides consent; the registration itself happens once
    # below. "quiet" re-registers an existing cs-statusline entry (refreshing
    # the path) without announcing it.
    _register_statusline=""
    case "$_current_statusline" in
        */cs-statusline)
            _register_statusline=quiet
            ;;
        *)
            if [ -f "$_statusline_declined" ]; then
                info "Status line not registered (declined earlier). Enable any time with: cs -statusline enable"
            elif [ -z "$_current_statusline" ]; then
                # The status bar is user-visible UI: claim it only with consent.
                # Interactive installs ask (default yes); non-interactive installs
                # leave it off and say how to enable.
                if [ -t 0 ]; then
                    _preview_statusline
                    # read -p prints its argument verbatim, so an escape in it
                    # would show as literal characters. Emit the styled prompt
                    # with echo -e and read with no prompt of its own.
                    echo -en "Register ${BOLD}cs-statusline${NC} as the Claude Code status line? [Y/n] "
                    read -n 1 -r
                    echo ""
                    if [[ $REPLY =~ ^[Nn]$ ]]; then
                        _remember_statusline_decline \
                            "Status line not registered." \
                            "Turn it on any time with: cs -statusline enable"
                    else
                        _register_statusline=1
                    fi
                else
                    info "Status line not registered. Enable any time with: cs -statusline enable"
                fi
            else
                if [ -t 0 ]; then
                    _preview_statusline
                    echo -en "Replace current status line ($_current_statusline) with ${BOLD}cs-statusline${NC}? [y/N] "
                    read -n 1 -r
                    echo ""
                    # Anything but y declines, enter included: the point of the
                    # change is that cs -update stops asking, and a default that
                    # left the question open would re-prompt the people it was
                    # written for. The decline says plainly that it is
                    # remembered, and cs -statusline enable reverses it.
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        _register_statusline=1
                    else
                        _remember_statusline_decline \
                            "Keeping current status line." \
                            "To switch to cs-statusline: cs -statusline enable"
                    fi
                else
                    warn "Keeping current status line. To switch to cs-statusline:"
                    warn "  set statusLine.command to $_statusline_cmd in ~/.claude/settings.json"
                fi
            fi
            ;;
    esac
    if [ -n "$_register_statusline" ]; then
        # refreshInterval keeps the bar repainting once a second while idle;
        # the logo's attention pulse animates on that timer. Registers BOTH
        # settings keys, same as `cs -statusline enable` — the two recipes
        # must stay equivalent (KEEP IN SYNC with lib/70-statusline.sh).
        SETTINGS=$(echo "$SETTINGS" | jq --arg cmd "$_statusline_cmd" \
            --arg subcmd "$INSTALL_DIR/cs-subagent-statusline" \
            '.statusLine = {type: "command", command: $cmd, refreshInterval: 1}
             | .subagentStatusLine = {type: "command", command: $subcmd}')
        if [ "$_register_statusline" = "1" ]; then
            installed "status line" "cs-statusline + cs-subagent-statusline"
        fi
    fi

    echo "$SETTINGS" > "$CLAUDE_SETTINGS"
fi

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    warn "   WARNING: $INSTALL_DIR is not in your PATH"
    echo ""
    warn "   Add this line to your ~/.bashrc, ~/.zshrc, or equivalent:"
    warn "     export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# Get version for completion message
CS_VERSION=$(grep -m1 "^VERSION=" "$INSTALL_DIR/cs" 2>/dev/null | cut -d'"' -f2 || echo "unknown")

# Stamp the deployed-hooks version so cs -doctor can flag installs whose
# deployed artifacts lag behind the running cs binary.
if [ "$CS_VERSION" != "unknown" ]; then
    echo "$CS_VERSION" > "$HOOKS_DIR/.version"
fi

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
