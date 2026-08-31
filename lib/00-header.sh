#!/usr/bin/env bash
# ABOUTME: Claude Code session manager with git-synced isolated workspaces
# ABOUTME: Creates isolated session workspaces with automatic documentation and file organization

set -euo pipefail

# Configuration
VERSION="2026.8.23"
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
    prose-lint.sh             # retired with the `cs -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
)

# Hook scripts cs ships; deployed to ~/.claude/hooks/cs/ and registered in
# settings.json. KEEP THIS LIST IN SYNC WITH install.sh's CS_HOOKS.
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

# Files under hooks/ that the hooks source, or that cs points other tools at,
# rather than files Claude Code invokes as hooks. Deployed and removed alongside
# the hooks, never registered against an event. The prompt-rewriter scripts are
# reached through $EDITOR, not through any hook event.
# KEEP THIS LIST IN SYNC WITH install.sh's CS_HOOK_LIBS.
CS_HOOK_LIBS=(
    cs-resolve.sh
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
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
    rotate
    merge
    write-as-me
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and run_uninstall both delete these directories.
# KEEP THIS LIST IN SYNC WITH install.sh's RETIRED_SKILLS.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
)

# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
# KEEP THIS LIST IN SYNC WITH install.sh's CS_SKILL_FILES.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
)

# Deployed-hooks directory; CS_HOOKS_DIR overrides it for tests.
HOOKS_DEPLOY_DIR="${CS_HOOKS_DIR:-$HOME/.claude/hooks/cs}"

# Encode an absolute filesystem path the way Claude Code does for project
# directory names under ~/.claude/projects/ (each `/` and `.` becomes `-`).
# Used by setup_auto_memory and _doctor_check_token_cost to locate the
# transcript directory for a given workspace.
