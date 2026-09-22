#!/usr/bin/env bash
# ABOUTME: Claude Code session manager with git-synced isolated workspaces
# ABOUTME: Creates isolated session workspaces with automatic documentation and file organization

set -euo pipefail

# Configuration
VERSION="2026.9.19"
SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
CLAUDE_CODE_BIN="${CLAUDE_CODE_BIN:-claude}"

# Claude Code downgrades its branding (logo, "thinking" animation) and statusline
# truecolor to a muted palette when it detects tmux, regardless of actual color
# support (anthropics/claude-code#35148). cs owns the environment before it execs
# claude, so it restores the documented override here for every launch path,
# unless the user has already set the variable themselves. (`if`, not `[ ] &&`,
# so the false branch does not trip `set -e` at top level.)
if [ -z "${CLAUDE_CODE_TMUX_TRUECOLOR+x}" ]; then
    export CLAUDE_CODE_TMUX_TRUECOLOR=1
fi

REPO_URL="https://github.com/hex/claude-sessions"
RELEASES_BASE="https://github.com/hex/claude-sessions/releases"
CHANGELOG_RAW_URL="https://raw.githubusercontent.com/hex/claude-sessions/main/CHANGELOG.md"

# Deployed-hooks directory; CS_HOOKS_DIR overrides it for tests.
HOOKS_DEPLOY_DIR="${CS_HOOKS_DIR:-$HOME/.claude/hooks/cs}"

# Encode an absolute filesystem path the way Claude Code does for project
# directory names under ~/.claude/projects/ (each `/` and `.` becomes `-`).
# Used by setup_auto_memory and _doctor_check_token_cost to locate the
# transcript directory for a given workspace.
