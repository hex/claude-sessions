#!/usr/bin/env bash
# ABOUTME: Claude Code session manager with git-synced isolated workspaces
# ABOUTME: Creates isolated session workspaces with automatic documentation and file organization

set -euo pipefail

# Configuration
VERSION="2026.7.12"
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

# Hooks retired in past versions but possibly still installed from older cs versions.
# install.sh and run_uninstall both clean these up. KEEP IN SYNC WITH install.sh's RETIRED_HOOKS.
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
)

# Hook scripts cs ships; deployed to ~/.claude/hooks/cs/ and registered in
# settings.json. KEEP THIS LIST IN SYNC WITH install.sh's CS_HOOKS.
CS_HOOKS=(
    session-start.sh
    autosave-commits.sh
    narrative-reminder.sh
    prose-lint.sh
    session-end.sh
    subagent-context.sh
    tool-failure-logger.sh
    session-auto-approve.sh
    bash-logger.sh
    scope-prompt.sh
)

# Slash commands cs ships; deployed to ~/.claude/commands/.
# KEEP THIS LIST IN SYNC WITH install.sh's CS_COMMANDS.
CS_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as ~/.claude/skills/<name>/SKILL.md.
# KEEP THIS LIST IN SYNC WITH install.sh's CS_SKILLS.
CS_SKILLS=(
    store-secret
    prose-hygiene
)

# Deployed-hooks directory; CS_HOOKS_DIR overrides it for tests.
HOOKS_DEPLOY_DIR="${CS_HOOKS_DIR:-$HOME/.claude/hooks/cs}"

# Encode an absolute filesystem path the way Claude Code does for project
# directory names under ~/.claude/projects/ (each `/` and `.` becomes `-`).
# Used by setup_auto_memory and _doctor_check_token_cost to locate the
# transcript directory for a given workspace.
