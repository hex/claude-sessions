# cs as a Claude Code plugin: design

Date: 2026-06-11
Status: draft for review. No code yet.

## Goal

Ship cs's in-Claude surface (hooks, slash commands, skills) as a Claude Code plugin, delivered from this repo, alongside the existing install.sh path. The plugin replaces settings.json hook surgery and deployed-copy drift with declarative registration and versioned delivery. The cs launcher, the four binaries, and the statusline registration stay with install.sh: a plugin runs inside Claude Code and cannot do pre-launch work, install PATH executables, or write the `statusLine` settings field.

## What moves, what stays

| Surface | Today | Plugin mode |
|---|---|---|
| 11 hooks | Copied to `~/.claude/hooks/cs/`, registered by jq surgery in install.sh | Run from the plugin cache, registered by `hooks/hooks.json` |
| 5 commands | Copied to `~/.claude/commands/` | Auto-discovered from `commands/` |
| 2 skills | Copied to `~/.claude/skills/<name>/` | Auto-discovered from `skills/` |
| `cs`, `cs-secrets`, `cs-statusline`, `cs-tui` | install.sh to `~/.local/bin` | Unchanged (plugins cannot install binaries) |
| statusLine registration | Consent flow + `cs -statusline enable\|disable` | Unchanged (not a plugin surface) |
| CLAUDE.md sentinel blocks, session scaffolding, env contract | cs launcher | Unchanged |

The hooks themselves do not change: they are self-contained bash, gate on `CLAUDE_SESSION_NAME`, and read the env contract the launcher exports. Only their location and registration mechanism move.

## Repo layout delta

The repo already matches the plugin convention (components at root, kebab-case). The full delta:

```
claude-sessions/
├── .claude-plugin/
│   ├── plugin.json          # new: manifest
│   └── marketplace.json     # new: repo doubles as its own marketplace
├── hooks/
│   ├── hooks.json           # new: declarative registrations (table below)
│   └── *.sh                 # unchanged
├── commands/*.md            # unchanged, auto-discovered
├── skills/*/SKILL.md        # unchanged, auto-discovered
└── (everything else unchanged)
```

Install for users: `/plugin marketplace add hex/claude-sessions`, then `/plugin install claude-sessions`. The binaries still come from install.sh; the README install section gains the two-step story.

## plugin.json draft

```json
{
  "name": "claude-sessions",
  "version": "2026.6.2",
  "description": "Session hooks, commands, and skills for the cs session manager",
  "repository": "https://github.com/hex/claude-sessions",
  "license": "MIT",
  "keywords": ["sessions", "workspace", "documentation"]
}
```

`version` mirrors `bin/cs` `VERSION` exactly; the /release flow bumps both (sync-tested, see Version skew).

## hooks.json mapping

Direct translation of install.sh's registration table; commands use `${CLAUDE_PLUGIN_ROOT}/hooks/<file>`:

| Event | Hook | Timeout | Matcher | Async |
|---|---|---|---|---|
| SessionStart | session-start.sh | 30 | | |
| PreToolUse | artifact-tracker.sh | 10 | Write | |
| PostToolUse | discovery-commits.sh | 10 | Write\|Edit | yes |
| Stop | discoveries-reminder.sh | 10 | | |
| Stop | prose-lint.sh | 15 | | |
| SessionEnd | session-end.sh | 30 | | |
| SubagentStart | subagent-context.sh | 10 | | |
| PostToolUseFailure | tool-failure-logger.sh | 10 | | yes |
| PermissionRequest | session-auto-approve.sh | 5 | Write\|Edit | |
| PreToolUse | bash-logger.sh | 5 | Bash | |
| UserPromptSubmit | scope-prompt.sh | 3 | | |

JSON shape per the plugin reference:

```json
{
  "SessionStart": [
    { "hooks": [ { "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh", "timeout": 30 } ] }
  ]
}
```

## Coexistence and migration

Two delivery channels, one source, never both active for the same component:

- **install.sh detects plugin mode** (the plugin cache contains a `claude-sessions` plugin) and then skips hook/command/skill deployment and all settings.json hook surgery. It still deploys binaries, runs the statusline consent flow, and installs completions.
- **Adopting the plugin on an existing install**: enabling the plugin must not double-fire hooks. install.sh (run after plugin install) strips the legacy settings.json registrations and removes `~/.claude/hooks/cs/`, `~/.claude/commands/<cs files>`, `~/.claude/skills/<cs dirs>` using the existing manifest arrays and strip machinery. One-way migration with an explicit notice.
- **`cs -uninstall`** keeps both paths: legacy strip (existing code) plus a notice to run `/plugin uninstall claude-sessions` (cs cannot remove plugins itself; verify whether a CLI exists at build time).
- **Doctor**: a plugin-mode check replaces the drift/registration checks when active. Drift checks remain for legacy mode until retirement.

## Version skew

Two update channels (binary via `cs -update`, plugin via the marketplace) sharing one contract. Mitigations, all reusing existing machinery:

- `plugin.json` version is fanned out by the /release flow exactly like the `.version` stamp today; `tests/test_install.sh` gains a sync assertion: `plugin.json` version == `bin/cs` VERSION (same pattern as the manifest-array sync tests).
- `cs -doctor` compares the installed plugin's version against the running binary's VERSION and warns on mismatch with the command to update the lagging side (extends `_doctor_check_deployed_version`).
- The env/file contract between launcher and hooks remains append-only across minor versions (a hook must tolerate a missing new env var; the launcher must keep exporting old ones until a major cut).

## Must-verify before building

1. **Event coverage.** The plugin reference documents these hook events: PreToolUse, PostToolUse, Stop, SubagentStop, SessionStart, SessionEnd, UserPromptSubmit, PreCompact, Notification. cs needs three more: **SubagentStart, PostToolUseFailure, PermissionRequest**. Verify with a scratch plugin whether hooks.json accepts them (the docs list may simply lag the host, as all three fire today via settings.json). If any event is unsupported in plugins, that hook stays on the settings.json path and the migration becomes per-hook rather than all-or-nothing; the design survives, the install.sh strip table gains a keep-list.
2. **Command namespacing.** Plugin commands may surface as `/claude-sessions:summary` when names collide. Verify whether `/summary`, `/wrap`, `/sweep`, `/checkpoint`, `/compact-discoveries` keep their bare names when unique, and whether the CLAUDE.md wrap-cues prose (which names `/wrap` etc.) needs the qualified forms. Related: `wrap.md` executes its passes by reading the deployed `~/.claude/commands/sweep.md` and `~/.claude/commands/summary.md`; in plugin mode those live in the plugin cache, so wrap.md needs `${CLAUDE_PLUGIN_ROOT}`-relative references (verify the variable is expanded in command bodies) or another way to load its siblings.
3. **marketplace.json** location and schema (`.claude-plugin/marketplace.json` assumed, per the official marketplace layout; confirm against docs).
4. **`${CLAUDE_PLUGIN_ROOT}` in hook child processes**: hooks call no intra-plugin paths today (self-contained), so exposure is registration-only; confirm nothing else needs it.
5. **Plugin update cadence**: confirm how marketplace updates are pulled (manual `/plugin update` vs automatic) to write the skew-warning copy accurately.

## Retirement criteria for the legacy path

The settings.json hook-deploy path retires (deleting the strip/merge machinery and the drift doctor checks) when all hold:

1. The event-coverage verification passes for all 11 hooks.
2. The plugin has shipped in two consecutive releases without a registration regression.
3. `cs -doctor` has a migration nudge for legacy installs and it has been in a release for one cycle.

Until then, both paths ship and the sync tests guard their equivalence.

## Build plan (TDD, in order)

1. Scratch-plugin verification spike for the five must-verify items; record results here.
2. `hooks/hooks.json` + `.claude-plugin/plugin.json` + sync tests (version, hook-table-vs-CS_HOOKS equivalence: every CS_HOOKS entry appears in hooks.json exactly once, and the event/matcher/timeout table matches install.sh's `_merge_cs_hook` calls).
3. install.sh plugin-mode detection + skip + migration strip, with tests mirroring the existing install/uninstall suites.
4. Doctor: plugin-mode checks + version-skew warning, with tests.
5. marketplace.json + README/docs install story + CHANGELOG.
6. Live migration on this machine; observe one full release cycle before any retirement work.
