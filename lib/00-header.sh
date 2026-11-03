#!/usr/bin/env bash
# ABOUTME: Claude Code session manager with git-synced isolated workspaces
# ABOUTME: Creates isolated session workspaces with automatic documentation and file organization

set -euo pipefail

# Configuration
VERSION="2026.11.2"
# A relative CS_SESSIONS_ROOT names a directory under the one cs started in.
# cs moves into a session before it launches claude, and claude's hooks, the
# status line and cs-secrets read the variable from wherever they run, so it is
# made absolute here, once, in the environment cs hands on. $PWD rather than
# cd, because the root may not exist yet. Unset or empty keeps the default.
# A ./x or ../x root keeps its dots, which _cs_session_root_of's string stop
# never matches, so its link walk runs past that root: accepted, not re-fixed.
case "${CS_SESSIONS_ROOT:-/}" in
    /*) ;;
    *) export CS_SESSIONS_ROOT="${PWD%/}/$CS_SESSIONS_ROOT" ;;
esac
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
