# ABOUTME: The deploy manifests (hooks, commands, skills, mods, and what past versions
# ABOUTME: left behind) and the settings-strip filter; build.sh folds this into bin/cs
# ABOUTME: and splices it into install.sh, so the installer and the tool read one list.

# Files a past version deployed into the hooks directory and this one does not:
# retired hooks, and any support file that went with them. Removed on install
# and on uninstall, wherever an older cs left them.
# install.sh and run_uninstall both clean these up.
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
    cs-logo.png               # retired: the icon source for the finished-turn notification, which the iTerm2 sidebar owns now (not a hook; a file the hooks directory carried)
    files-scan.sh             # retired: workspace file indexer for .cs/files.md (assumption that the agent can't introspect file sizes has expired)
    files-context.sh          # retired: PreToolUse:Read context injector that surfaced files.md token estimates
    changes-tracker.sh        # retired: PostToolUse change log re-narrating git history into .cs/changes.md; git log/diff/status is authoritative
    artifact-tracker.sh       # retired: PreToolUse:Write redirect was inert (updatedInput path rewrite is not honored by the harness); tracking removed entirely
    prose-lint.sh             # retired with the `cs -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
)

# Hook scripts cs ships; deployed to ~/.claude/hooks/cs/ and registered in
# settings.json.
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
CS_HOOK_LIBS=(
    cs-resolve.sh
    cs-shared.sh
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
)

# Slash commands cs ships; deployed to ~/.claude/commands/.
CS_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as ~/.claude/skills/<name>/SKILL.md.
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    finish
    feature
    write-as-me
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and run_uninstall both delete these directories.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
#
# Do not add a doctor row for a leftover directory; it cannot report one. The
# only cs that could still hold it is one older than the retirement, and that cs
# has no entry here to check against; the upgrade that gives it the entry is the
# same install that deletes the directory. So the row would warn about a state
# it can never observe.
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
    merge   # replaced by finish: integrate and report, never remove
    cs-hint # a mod (deployed under skills/ like every mod): the hint line under the prompt, retired
)

# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
    finish/scripts/finish.sh
)

# Mods cs ships: Claude Code function-hooks plugins, deployed file by file as
# ~/.claude/skills/<mod>/<path> (the mod's bun tests stay in the checkout).
CS_MOD_FILES=(
    cs-rotate/.claude-plugin/plugin.json
    cs-rotate/hooks/hooks.json
    cs-rotate/hooks/register.tsx
    cs-update/.claude-plugin/plugin.json
    cs-update/hooks/hooks.json
    cs-update/hooks/register.tsx
)

# Remove a hook registration from any event in a settings JSON string,
# matching either path spelling; drops wrappers that empty out. Prints the
# updated JSON.
_strip_hook_registration() {
    local settings="$1" p="$2" t="$3"
    echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
        else . end
    '
}
