# Changelog

All notable changes to cs are documented here. Release notes are also available on [GitHub Releases](https://github.com/hex/claude-sessions/releases).

## 2026.4.10

### Features

- **`.cs/files.md` workspace index with pre-read context injection** -- New index at `.cs/files.md` carries one `## <path>` entry per workspace file with an optional hand-written description and a rough token estimate (`bytes / 3.75`). A new `PreToolUse`-on-`Read` hook (`files-context.sh`) looks up the target of each `Read` and injects the description + token line as `additionalContext`, so Claude can skip full file reads when the description suffices. The index is seeded on startup/resume by `session-start.sh` (background, non-blocking) via the new `files-scan.sh` utility, and `changes-tracker.sh` refreshes entries surgically on every Write/Edit while preserving descriptions. Hardcoded excludes for `.cs/`, `.git/`, `node_modules/`, `dist/`, `build/`, `.DS_Store`.

### Fixes

- **Latent `set -u` trap in `tests/test_lib.sh` asserts** -- The pattern `local path="$1" msg="${2:-$path should be a file}"` in ten assert helpers aborted the shell under `set -u` when the second argument was absent, because `path` was declared-but-unset while `msg`'s default expanded. Split into two `local` statements in all ten helpers (`assert_exists`, `assert_not_exists`, `assert_dir`, `assert_symlink`, `assert_file_exists`, `assert_file_not_exists`, `assert_file_contains`, `assert_file_not_contains`, `assert_output_contains`, `assert_output_not_contains`). No existing test triggered it; the new `test_files_scan.sh` was the first caller to rely on the default.
- **Install/uninstall parity for the new hooks** -- `run_uninstall()` in `bin/cs` was missing `files-scan.sh` and `files-context.sh` from its hook removal list, and the settings.json cleanup block had no `PreToolUse:Read` strip for `files-context.sh`. Added both.
- **Retired `aboutme-prereader.sh` and `gotcha-prewriter.sh`** -- Both shipped briefly in an earlier experiment, were removed from the source tree, but were never added to `RETIRED_HOOKS` -- so their settings.json entries persisted on installed machines pointing at files that no longer exist on disk. Added to the retired list so reinstalling strips them.

### Improvements

- **Single-jq hot-path in `files-context.sh` and `changes-tracker.sh`** -- Both hooks now extract `tool_name` and `file_path` in a single `jq` call via `@tsv`, halving the jq fork overhead on every Read/Write. `files-context.sh` also runs a `grep -Fxq` existence check before the awk lookup, so unindexed paths exit cheaply without scanning `files.md`.

### Tests

- 24 new tests across 4 files: `test_files_scan.sh` (6), `test_files_context.sh` (7), `test_changes_tracker.sh` (5), plus 6 in `test_hooks.sh` covering install.sh jq registration for `PreToolUse:Read` and `session-start.sh`'s initial-scan trigger.

## 2026.4.9

### Features

- **`cs -doctor` / `-diag`** -- Runs a set of health checks and reports PASS/WARN/FAIL status with colored output. Checks Keychain backend reachable, hooks registered in settings.json, hook files executable, git sync state (ahead/behind upstream), shadow-ref freshness, `discoveries.md` size vs budget, and auto-memory dir writable. Global checks always run; session-scoped checks only when inside a session. Non-zero exit on FAIL so scripts can chain on it.

### Improvements

- **`/release` now runs `/simplify` as Step 4** -- fans out three parallel review agents (reuse, quality, efficiency) over the pending release diff to catch duplication, hacky patterns, and inefficiencies before they ship. Validated by the subsequent test run.

### Fixes

- **Discoveries reminder no longer triggers metric-echo behavior** -- Added explicit guidance in the Stop-hook reminder message telling Claude not to prepend status metadata (e.g., "N chars -- under budget") to new discovery entries. The LLM would echo mentioned metrics as "helpful context" when the hook message included a file-size reference, creating ephemeral noise that was stale by the next session.

### Tests

- 7 new tests for `cs -doctor`: subcommand existence, default check set, healthy-session OK output, oversized discoveries WARN, non-executable hook FAIL, non-zero exit propagation, global-context fallback.
- 288 tests passing across 18 test suites (was 281).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.8...v2026.4.9

## 2026.4.8

### Improvements

- **Raise discoveries size budget from 20KB to 60KB** -- The 20KB default introduced in v2026.4.7 was too aggressive for sessions used as Claude's working memory. New 60KB default (~12-15K tokens) gives substantial headroom for long-running sessions while still staying well under 1% of a 200K context window.

- **`CS_DISCOVERIES_MAX_SIZE` env var** -- Override the default 60KB budget by setting this env var (in bytes) in your shell rc. Useful for sessions that are particularly knowledge-dense, or for users who want to be more/less aggressive about compaction.

### Renamed

- Internal var `MAX_CHARS` -> `MAX_SIZE` and "character budget" -> "size budget" in docs/messages, since `wc -c` measures bytes (not characters) and `MAX_SIZE` matches Unix tool conventions (`ls -l`, `du -b`, `wc -c`, `find -size`).

### Tests

- Added `test_reminder_env_var_overrides_default` -- verifies that `CS_DISCOVERIES_MAX_SIZE` overrides the default threshold.
- Refactored existing budget tests to use the env var with small thresholds for fast, reliable testing (instead of generating large test files).
- 281 tests passing across 17 test suites (was 280).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.7...v2026.4.8

## 2026.4.7

### Improvements

- **Character-budget discoveries management** -- Replaced the line-count archiver with a 20KB character budget. The old system used a PreCompact hook (`discoveries-archiver.sh`) that mechanically moved entries to an archive file at 200 lines -- a threshold borrowed from MEMORY.md's hard truncation limit, which was the wrong basis since discoveries loads fully through the CLAUDE.md protocol. The new system checks character count in the Stop hook and instructs Claude to summarize old entries directly into `discoveries.compact.md`. No intermediate archive file, one fewer hook, and a principled threshold based on context cost (~4-5K tokens).

### Removed

- `discoveries-archiver.sh` PreCompact hook -- replaced by character budget check in `discoveries-reminder.sh`
- `discoveries.archive.md` intermediate file concept -- old entries now summarize directly into `discoveries.compact.md`

### Other

- Updated `/compact-discoveries` command to work directly with `discoveries.md` instead of the archive
- Fixed `/release` command to cross-check against CHANGELOG.md to prevent listing already-released features
- 280 tests passing across 17 test suites (was 283 -- 6 archiver tests removed, 3 budget tests added)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.6...v2026.4.7

## 2026.4.6

### Features
- **Subagent detection in hooks** -- hooks now check for `agent_id` in the JSON input and skip side-effects (command tracking, discoveries reminder, session lifecycle events) when running inside a Task-spawned subagent. Prevents subagents from polluting parent session state.
- **Structured timeline log** (`.cs/timeline.jsonl`) -- session-start and session-end hooks append JSONL events with timestamp, source, session ID, and branch. Checkpoints also write timeline events.
- **`cs -checkpoint` + `/checkpoint` slash command** -- save labelled narrative snapshots mid-session. Captures discoveries, changes, git HEAD, and uncommitted files. List with `cs -checkpoint list`, view with `cs -checkpoint show <name>`.

### Fixes
- **Fix stdout leak in session-end hook** -- `cs-secrets export-file` printed to stdout inside the hook, causing Claude Code to report "Hook cancelled" on every session exit for sessions with age keys. Redirected to `/dev/null`.
- **Fix checkpoint error message** -- guard now says "must be run from inside a cs session" instead of misleading "CLAUDE_SESSION_NAME not set" when the real issue is a nonexistent directory.

### DX Improvements (10 items, built by 3 parallel agent teams)
- **Non-TTY help** -- `cs` with no args in a non-TTY context now shows a compact 5-line help instead of "cs-tui requires interactive terminal"
- **Post-install message** -- installer now shows "Getting started: cs my-first-session" after completion
- **Shell completions** -- added `-checkpoint` and `-search` to both zsh and bash completions with subcommand support
- **Checkpoint guard** -- `cs -checkpoint` verifies `CLAUDE_SESSION_META_DIR` exists as a directory, not just that the env var is set
- **Concepts section in README** -- explains sessions, discoveries, artifacts, checkpoints, timeline, auto-memory
- **Slash Commands section in README** -- documents /summary, /compact-discoveries, /checkpoint, /skillify
- **Timeline documented** -- in README session structure and docs/hooks.md
- **CHANGELOG.md** -- 683 lines covering all 43 releases
- **Release notes on update** -- `cs -update` now shows what changed after installing
- **CONTRIBUTING.md** -- dev setup, test workflow, hook/command addition checklists

### Other
- `/release` command now maintains CHANGELOG.md on each release
- Removed `cs -learn` / `cs -learnings` / `/learn` (YAGNI -- discoveries + auto-memory + search already cover cross-session knowledge)

283/283 tests passing.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.5...v2026.4.6

## 2026.4.5


### Fixes (silent hook failures)
All three fixes are the same root cause: `head -N` closes its input early, causing SIGPIPE upstream. Combined with `set -o pipefail` + `set -e`, this killed hooks silently mid-execution. Symptoms varied by hook:

- **session-end.sh**: when 6+ files were uncommitted, the FILE_LIST pipeline (`xargs basename | head -5 | paste`) crashed before reaching the `index.md` generation block. Sessions ended cleanly, the log recorded `Session ended (source: user_exit)`, but `index.md` was never created. This is why Obsidian users on v2026.4.3/v2026.4.4 saw no auto-generated index.
- **artifact-tracker.sh**: 3 separate `echo $content | grep | head -1 | sed` pipelines in `extract_and_store_secrets` could SIGPIPE on files larger than ~64KB with multi-line secret matches. **Most consequential**: when this hook crashes, the JSON allow decision is never printed and the entire Write tool call is silently blocked.
- **tool-failure-logger.sh**: `echo $ERROR | head -1 | cut` could SIGPIPE on tool errors >64KB (long stack traces), silently dropping the error from the session log.

### Tests
- Add regression test for session-end with 8 uncommitted files
- Add regression test for tool-failure-logger with 250KB multi-line error
- Total: 262 tests passing (was 261)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.4...v2026.4.5


## 2026.4.4


### Features
- **Migrate old sessions to YAML frontmatter** — existing sessions without frontmatter get `status`, `created`, `tags`, and `aliases` auto-added on next open. Derives `created` date from the README's Started line rather than using today's date. Preserves all existing content.

### Fixes
- Fetch remote tags before generating release notes (gh creates tags on GitHub, not locally).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.3...v2026.4.4


## 2026.4.3


### Features
- **YAML frontmatter in session README.md** — new sessions get `status`, `created`, `tags`, and `aliases` fields. Enables Obsidian Dataview queries and Properties editor display.
- **`aliases` in frontmatter** — contains session name so Obsidian's quick switcher works (all files are named README.md without it).
- **`last_resumed` timestamp** — set by session-start hook on resume. Enables stale session detection via Dataview.
- **`updated` timestamp** — set by session-end hook. Enables sorting by last modification.
- **Auto-generated `index.md`** — markdown table at sessions root listing all sessions with status, objective, and created date. Regenerated on session end.
- **`.obsidian/` in session gitignore** — prevents Obsidian vault config from being committed.

### Docs
- Add Obsidian integration section to README with vault setup, recommended plugins (Dataview, Projects, Juggl), example Dataview queries, and graph view filter tips.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.2...v2026.4.3


## 2026.4.2


### Features
- **Cross-session context on resume** — when resuming a session, the session-start hook now injects a compact summary of up to 5 most recently active sibling sessions with their objectives. Gives Claude peripheral awareness of ongoing work without the user needing to mention it.

### Fixes
- Fix `grep` pattern parsing in `assert_output_contains` / `assert_output_not_contains` — patterns starting with `-` were interpreted as grep flags. Added `--` to terminate option parsing. (10/10 in test_auto_update now).
- Sort sibling sessions by `session.log` mtime (most recent first) instead of alphabetical glob order.
- Remove `install.ps1` references from `/release` command.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.1...v2026.4.2


## 2026.4.1


### Security
- Drop Windows support entirely — removes PowerShell injection vulnerability in credential backend, install.ps1, and cs.ps1 completions. Windows users should use WSL.
- Fix `grep -P` portability — invisible unicode detection in memory scanning was silently failing on macOS (BSD grep lacks PCRE). Now uses `perl` for cross-platform support.

### Testing
- Add 102 new tests (132 → 234 total, 15 test suites)
- **artifact-tracker.sh** (31 tests): path rewriting, secret detection, content redaction, MANIFEST updates
- **cs-secrets** (28 tests): encrypted backend store/get/delete/purge/export, session isolation, file permissions
- **sync functions** (19 tests): push/pull with local bare repos, config, auto-toggle, clone, memory scan blocking
- **session hooks** (24 tests): discoveries archiver/reminder, auto-approve, subagent context, failure logger
- Extract shared `test_lib.sh` from 11 test files (-573 lines of duplicated boilerplate)

### Code Quality
- Deduplicate CLAUDE.md session template into `write_session_claude_md()` (was copy-pasted in 2 functions)
- Deduplicate script-finder logic (`run_secrets()` now delegates to `find_secrets_script()`)

### Other
- Add staleness warning to commands.md import in CLAUDE.md
- TUI: hide Remote and Github columns when preview pane is open

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.13...v2026.4.1


## 2026.3.13


### Fixes

- **TUI crash fix**: UTF-8 safe string truncation in preview pane. Slicing at a byte index could land mid-character (e.g. en dash `–`), causing a panic when scrolling to sessions with multi-byte characters in memory entries. Added `truncate_str()` using `char_indices()` for safe boundaries.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.12...v2026.3.13


## 2026.3.12


### Features

- **Dynamic session context on resume**: SessionStart hook now injects session state (last activity, recent commits with changed files, objective) alongside static context
- **Bash command audit trail**: New `bash-logger.sh` PreToolUse hook logs every Bash command to `.cs/logs/session.log` with timestamps before execution
- **TUI: search filters while typing**: `/` search now filters results immediately as you type; Up/Down arrow keys navigate filtered results

### Fixes

- **Shadow ref crash recovery**: Autosave now fires on ALL Write/Edit (not just discovery files), preventing data loss for non-discovery files modified after the last discovery edit
- **Crash recovery asks before restoring**: Instead of auto-restoring from shadow ref, injects diff summary into context so Claude can present details and ask the user whether to restore or discard

### Docs

- Updated README with all new features, session structure, and `-search` in Usage
- Added `command-tracker.sh` and `bash-logger.sh` to docs/hooks.md
- Fixed stale hook timeouts in docs/hooks.md JSON config example
- Added install.ps1 parity verification to `/release` command

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.11...v2026.3.12


## 2026.3.11


### Fixes

- **SessionStart hook stdout fix**: Background auto-pull subshell and git checkout could leak stdout after the JSON output, corrupting it and causing "SessionStart:resume hook error". Redirected entire background subshell and crash recovery to `/dev/null`.
- **install.ps1 parity**: PowerShell installer was missing 5 hooks, 1 command, 5 hook events, async flags, and 30s timeouts. Now fully in sync with install.sh.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.10...v2026.3.11


## 2026.3.10


### Fixes

- **SessionEnd hook timeout**: Increased from 10s to 30s — `git push` to remote can exceed 10s on large repos, causing "Hook cancelled" and silent auto-sync failure
- **SessionStart hook timeout**: Increased from 10s to 30s — `git fetch` + `git pull` on resume can exceed 10s, causing "hook error" on session start

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.9...v2026.3.10


## 2026.3.9


### Features

- **CLI command capture**: New `command-tracker.sh` hook (PostToolUse on Bash, async) captures interesting commands to `.cs/commands.md` with filtering, secret scrubbing, categorization (Build/Test/Dev/Deploy/Lint/Other), and dedup with use count tracking. Loaded via `@` import in CLAUDE.md.
- **Skill promotion**: Commands used 3+ times across 2+ sessions trigger a suggestion to create a reusable skill via `/skillify`
- **`/skillify` command**: Creates Claude Code skills with proper YAML frontmatter (`name` + `description`), following official skill authoring best practices
- **Cross-session search**: `cs -search <query>` greps across all sessions' discoveries, memory, README, and changes
- **TUI memory preview**: Preview pane now shows first 5 lines of auto memory MEMORY.md
- **Memory security scanning**: Scans `.cs/memory/` for prompt injection and credential exfiltration patterns before sync push

### Fixes

- Plain text help output (removed colors from `cs -help`)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.8...v2026.3.9


## 2026.3.8


### Features

- **Plans redirect**: Claude Code plans now stored in `.cs/plans/` via `plansDirectory` setting, synced and cleaned up with session data
- **Auto memory env var**: Use `CLAUDE_CODE_AUTO_MEMORY_PATH` env var (set at launch) as primary mechanism for auto memory redirect, more reliable than settings file alone

### Fixes

- **Absolute path for autoMemoryDirectory**: `autoMemoryDirectory` only accepts `~/`-expanded absolute paths, not relative — fixed settings.local.json to use absolute path
- **Merge settings instead of overwrite**: `setup_auto_memory()` now merges into existing `.claude/settings.local.json` via jq instead of clobbering user's other settings

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.7...v2026.3.8


## 2026.3.7


### Features

- **Auto memory migration**: Existing sessions that have Claude Code auto memory at the default `~/.claude/projects/` location now get it automatically migrated into `.cs/memory/` on first open. No manual action needed.

### Fixes

- **Version regression fix**: Restored uninstall parity (3 hooks, 3 settings entries, cs-tui binary) that was accidentally reverted in a prior commit due to context compaction

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.6...v2026.3.7


## 2026.3.6


### Fixes

- **Uninstall parity**: `cs -uninstall` now removes all 10 hooks (was missing `subagent-context.sh`, `tool-failure-logger.sh`, `session-auto-approve.sh`), cleans up all settings.json entries (`SubagentStart`, `PostToolUseFailure`, `PermissionRequest`), and removes the `cs-tui` binary

### Process

- **Install/uninstall parity check** added as Step 2 in the `/release` workflow to prevent future drift between install.sh and run_uninstall()

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.5...v2026.3.6


## 2026.3.5


### Features

- **Auto memory redirect**: Claude Code's auto memory is now stored inside the session directory at `.cs/memory/` instead of the default `~/.claude/projects/` location. This means auto memory is synced across machines with `cs -sync`, cleaned up with `cs -rm`, and contained within the session. The redirect is configured via `.claude/settings.local.json` (gitignored, recreated by cs on each machine).

### Docs

- Updated session structure diagram in README with `.cs/memory/` and `.claude/settings.local.json`
- Updated sync docs to list auto memory in "What Gets Synced"

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.4...v2026.3.5


## 2026.3.4


### Features

**TUI overhaul** — 15 new features for the interactive session manager:

- Fuzzy search with per-character highlighting and scoring
- Time-based section headers (Today, Yesterday, This Week, etc.)
- Preview pane for wide terminals (>120 cols), toggle with `p`
- Row expand/collapse with Tab shows session preview inline
- Inline action bar replaces popup session menu
- Batch operations: Space to mark, D to batch delete
- Async sync operations with spinner (Esc to cancel)
- Peek mode for secrets with 5-second timed reveal
- Selection momentum accelerates on key repeat
- Quick create dialog with `n` key
- 2-second safety countdown on delete confirmation
- Row flash feedback after actions
- Gutter indicators as colored prefix spans
- Recency fading, status messages, stable sort selection
- Auto-hide empty columns

### Fixes

- Fix tab color: use printf `%b` to interpret `` as BEL in escape sequences
- Lock tmux window/pane title so Claude Code cannot overwrite it

### Docs

- Updated TUI section in README with all new features
- Updated secrets sync docs to document age encryption

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.3...v2026.3.4


## 2026.3.3


### Features

- **Session-based tab colors** — Each session gets a unique, deterministic tab color derived from its name hash. Same session name always maps to the same color across launches, making it easy to distinguish multiple sessions at a glance. 12-color curated palette ensures every color looks good as a tab.

### Fixes

- **Tab color works inside tmux** — Detect the outer terminal (iTerm2, WezTerm) via `$LC_TERMINAL`/`$ITERM_SESSION_ID` even when `$TERM_PROGRAM` is overwritten by tmux. Use tmux DCS passthrough (`ESC P tmux;`) to forward proprietary escape sequences to the outer terminal.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.2...v2026.3.3


## 2026.3.2


### Features

- **Generic terminal tab title and color** — `set_tab_title()` and `reset_tab_title()` functions set the terminal tab title (`cs: session-name`) and optional tab color when launching a session. Works across all xterm-compatible terminals (iTerm2, Terminal.app, Ghostty, Alacritty, WezTerm, Kitty, etc.). Also sets tmux window names when running inside tmux. Tab color support for iTerm2 and WezTerm via escape sequences — orange for local sessions, blue for remote. Title and color reset on session exit via EXIT/INT/TERM traps.

- Replaced iTerm-specific `it2check`/`it2setcolor` calls with generic `$TERM_PROGRAM` detection and standard escape sequences — no external binary dependencies.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.1...v2026.3.2


## 2026.3.1


### Features
- **SubagentStart context injection**: New `subagent-context.sh` hook injects cs session context into spawned subagents so they know about session directory, artifacts, and secrets rules
- **Permission auto-approve for session metadata**: New `session-auto-approve.sh` hook auto-approves Write/Edit to `.cs/` files, reducing permission prompts for session bookkeeping
- **Tool failure logging**: New `tool-failure-logger.sh` hook logs failed tool calls to `.cs/logs/session.log` for post-session debugging
- **Async hooks**: `discovery-commits.sh` and `tool-failure-logger.sh` run with `async: true` for non-blocking execution
- **Custom spinner messages**: SessionStart and SubagentStart hooks return `statusMessage` for meaningful spinner text

### Fixes
- **SessionStart source filtering**: Skip auto-pull and crash recovery on `/clear` and compaction (session already running)
- **SessionEnd source filtering**: Skip artifact archiving on `sigint` for faster exit; log exit reason

### Docs
- Updated hook count from 7 to 10 across README and docs
- Added documentation for 3 new hooks and 3 new lifecycle events
- Fixed auto-sync commit message format in sync.md (removed wrong emoji)
- Fixed discovery autosave trigger scope in sync.md

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.16...v2026.3.1


## 2026.2.16


### Features

- **SHA-256 checksum verification** — `cs -update` now verifies downloads with SHA-256 checksums (zero external dependencies). minisign signature verification is preserved as an optional enhancement when minisign is already installed.

### Removed

- **minisign auto-download prompt** — `minisign_ensure_binary()` (~85 lines) removed. Users are no longer prompted to download minisign during updates. SHA-256 provides the baseline integrity check.

### CI

- Release workflow now generates `.sha256` checksum files for all release assets alongside `.minisig` signatures

### Other

- `install.sh` adds SHA-256 as primary verification for cs-tui binary downloads
- Updated tests for new verification model (82/82 passing)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.15...v2026.2.16


## 2026.2.15


### Features

- **TUI cursor navigation** — All text inputs (search, rename, move-to-remote) now support Left/Right arrow keys, Home/End, and Delete key for cursor movement. Previously, editing required deleting back to the mistake and retyping.

### Fixes

- **Update command shows "Reinstalling"** when version matches instead of misleading "Updating from X → X" message
- **Session-end commit messages** use plain text (`Session update:`) instead of emoji prefix

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.14...v2026.2.15


## 2026.2.14


### Features
- **Shadow ref autosave** — Discovery edits now autosave to an invisible `refs/cs/auto` shadow ref using git plumbing commands instead of committing to main. One clean commit is created at session end. Crash recovery restores autosaved changes on next session start.
- **Download consent prompts** — `minisign` and `age` binaries now prompt before downloading, with TTY detection for non-interactive shells and manual install suggestions.
- **Move-to is a true move** — `cs <session> --move-to <host>` now cleans up local session files after rsync, keeping only a `.cs/remote.conf` stub. Adopted (symlinked) sessions preserve project files.
- **Move-to progress** — Shows step-by-step progress messages during `--move-to` operations.

### Removed
- **Auto-update on session open** — Removed `cs -update auto`, `CS_AUTO_UPDATE` env var, and `.cs.conf` global config. Manual `cs -update` and update notifications remain.

### Docs
- Updated `docs/sync.md` to reflect shadow ref autosave behavior
- Updated `docs/hooks.md` with shadow ref descriptions and secrets export clarification
- Updated `README.md` to remove auto-update references

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.13...v2026.2.14


## 2026.2.13


### Security
- **Signed updates** — `cs -update` now downloads `install.sh` from immutable GitHub Release assets and verifies its [minisign](https://jedisct1.github.io/minisign/) signature before execution. Tampered installers are rejected.
- **Release pinning** — Updates are fetched from tagged releases instead of the `main` branch, eliminating the `curl | bash` from raw GitHub content
- **Binary verification** — `install.sh` performs best-effort minisign verification of `cs-tui` binaries when minisign is available
- **Auto-download minisign** — If minisign isn't installed, `cs` automatically downloads it to `~/.local/bin/` (macOS and Linux)

### CI
- Release workflow now signs all release assets (`install.sh`, `cs-tui-*`) with minisign
- `install.sh` is included as a release asset (no longer fetched from `main` during updates)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.12...v2026.2.13


## 2026.2.12


### Features
- **Session action menu** — pressing Enter on a session now shows a context menu with all available actions (Open, Delete, Rename, Move to Remote, Secrets, Push, Pull, Status). Navigate with j/k, select with Enter, or use shortcut keys directly. All existing shortcuts still work from Normal mode for power users.

### Fixes
- **Secrets list parsing** — fixed `parse_secrets_list()` not stripping the `  - ` bullet prefix from secret names, causing "Secret not found" errors when viewing or removing secrets from the TUI
- **Nerd Font lock icon** — corrected the codepoint for the lock icon in the TUI when using Nerd Fonts
- **CI runner** — switched macOS x86_64 build from retired `macos-13` to `macos-15-large`

### Docs
- Updated TUI section in README to document the actions menu and correct sort column range (1-6, not 1-4)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.11...v2026.2.12


## 2026.2.11


### Features
- **Auto-update setting** — Opt-in auto-update (`cs -update auto on`) that updates cs automatically when a new version is detected on session open. Also available via `CS_AUTO_UPDATE=1` env var for CI/remote machines
- **Global config** — First global config file at `~/.claude-sessions/.cs.conf` with `get_global_config`/`set_global_config` helpers (same key=value pattern as sync.conf)
- **Hostname in session banner** — Session banner now shows the machine hostname with a host icon
- **TUI gradient title** — Interactive session manager shows a gradient title with version number

### Fixes
- **Hook path consistency** — Hooks in settings.json now use tilde paths (`~/.claude/hooks/...`) instead of absolute paths, preventing duplicate entries across machines

### Internal
- Tab completions updated for `-update auto` subcommand (bash and zsh)
- 9 new tests for auto-update feature, all existing tests passing

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.10...v2026.2.11

## 2026.2.10


### Remote Sessions (new feature)
Run cs sessions on remote machines while keeping `cs SESSION_NAME` as your single entry point. Remote machines need cs and Claude Code installed independently.

- `cs -remote add/list/remove` — host registry for named remotes
- `cs SESSION --on HOST` / `cs user@host:session` — create or connect to remote sessions
- `cs SESSION --move-to HOST` — migrate local sessions to remote (with remote `CS_SESSIONS_ROOT` detection via ssh)
- `cs -ls` shows a LOCATION column when remote sessions exist
- Transport: prefers Eternal Terminal (`et`), falls back to `ssh`, wraps in `tmux`
- `-sync` and `-secrets` blocked on remote sessions (connect first, then run from within)

### Fixes
- Fix `et` transport using `-t` (tunnel) instead of `-c` (command)
- Fix zsh completion exact-match greediness preventing ambiguous session names from showing menu
- Fix `docs/sync.md` behavior differences table inaccuracies

### Docs
- Add remote sessions section to README with examples
- Document session-level flags (`--on`, `--move-to`, `--force`, `-s`) in Usage section
- Add See also section linking iTerm2-dimmer

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.9...v2026.2.10

## 2026.2.9


### Bug Fixes
- Fix zsh completion not working when user's fpath uses `~/.zsh/completion` (singular) — installer now detects existing fpath config and installs to the correct directory
- Fix sync completion listing `init` instead of `remote` in both bash and zsh completions

### Documentation
- Fix incorrect auto-commit emoji in sync docs (was `🤖`, actual is `🔄`/`📝`/`📦`/`📋`)
- Fix incorrect commit message format examples in sync docs
- Fix discovery-commits.sh description to reflect heading-first priority
- Fix `sync remote` behavior table (not a no-op for local-only sessions)
- Add `[name]` parameter to `clone` command docs
- Fix hook count and session-end secret export precondition in hooks docs

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.8...v2026.2.9

## 2026.2.8


### Fixes
- Fix sync error messages referencing nonexistent `init` command (correct command is `remote`)
- Clarify sync remote example in README to show URL parameter

### Cleanup
- Remove unused global `INDEX.md` session index (nothing read it)
- Update session-end hook docs to reflect secrets export and descriptive commit features

### Internal
- Descriptive auto-sync commit messages
- Delegate `/compact-discoveries` to sonnet background subagent

## 2026.2.7

### Improvements

- **Descriptive auto-sync commits** - Session-end commits now list changed files (e.g. `🔄 3 files: discoveries.md, script.py, config.yaml`) instead of generic timestamps
- **Background discoveries compaction** - Stop hook triggers compaction as a background sonnet subagent instead of blocking the conversation

## 2026.2.6

### Improvements

- **Background discoveries compaction** - The stop hook now triggers compaction as a background task instead of blocking the conversation
- **Sonnet model for compaction** - `/compact-discoveries` delegates to a sonnet subagent via the Task tool, reducing cost for summarization work

## 2026.2.5

### New Features

- **Discoveries archive & compaction system** - Keeps `discoveries.md` lean for context loading while preserving all historical findings
  - New PreCompact hook (`discoveries-archiver.sh`) automatically rotates old entries to `discoveries.archive.md` when discoveries exceed 200 lines
  - New `/compact-discoveries` slash command condenses the archive into a compact LLM summary (`discoveries.compact.md`)
  - Stop hook now suggests running compaction when the archive grows large
  - `discovery-commits.sh` handles all three discovery files with distinct commit prefixes
  - `changes-tracker.sh` skips archive and compact files to reduce noise

- **Session locking** - PID-based lock prevents concurrent access to the same session from multiple terminals; use `--force` to override

### Improvements

- Discoveries reminder now reviews entries inline and appends new ones in background (split workflow)

### Bug Fixes

- Fixed `discovery-commits.sh` missing from uninstall hook cleanup

## 2026.2.4

### Bug Fixes

- **Fix `cs -list` silently stopping early** - `set -e` + `pipefail` caused the script to abort when a session log used the newer timestamp format (missing `Started:` line). Sessions after the first affected one alphabetically were silently dropped.
- **Fix unguarded `grep` pipeline in config reader** - Same `set -e` + `pipefail` issue could crash config lookups when a key wasn't found.

### Improvements

- **6x faster `cs -list`** (4.86s → 0.78s for 58 sessions)
  - Dump macOS Keychain once instead of invoking `cs-secrets` per session
  - Parse keychain dump and log files with bash builtins instead of forking subprocesses
- **Support new log format** - Sessions using the `YYYY-MM-DD HH:MM:SS - Session started` format now correctly show their created date.

## 2026.2.3


### Improvements
- Auto-commit messages are now descriptive instead of generic timestamps
  - Discovery commits use the discovery entry text as the message
  - Session-end commits summarize changed filenames (e.g., `Update session.log, discoveries.md (+1 more)`)
- All auto-commits are prefixed with a robot emoji (🤖) for easy filtering with `git log --grep='🤖'`

## 2026.2.2


### Fixes
- Allow dots in session names (e.g., `cs -adopt hexul.com`)

## 2026.2.1


### Features
- **Adopt existing projects** - New `cs -adopt <name>` command converts any project directory into a cs session in place, using symlinks to preserve conversation continuity

### Improvements
- Improved migration message visibility

## 2026.2.0


### Features
- **`.cs/` metadata directory** - Session metadata now lives in a hidden `.cs/` directory, giving users a clean workspace root for project files. Existing sessions are automatically migrated on first launch.
- **Age encryption for secrets sync** - Modern public-key encryption for syncing secrets across machines using [age](https://github.com/FiloSottile/age). Auto-downloads and configures on first use.
- **Nerd Font icons** - Set `CS_NERD_FONTS=1` for richer terminal icons (requires a Nerd Font)
- **NO_COLOR support** - Respects the `NO_COLOR` environment variable per [no-color.org](https://no-color.org)
- **Task list persistence** - Sets `CLAUDE_CODE_TASK_LIST_ID` so Claude Code task lists persist across sessions
- **Secret count in session list** - `cs -ls` now shows how many secrets each session has

### Fixes
- Fix `set -e` crash on session launch
- Fall back to fresh session when `--continue` finds no conversation

### Improvements
- Warm color palette for help, list, and session banner
- Session banner with gradient bar
- Keychain migration: prompt once, then show notification only
- Remove Bitwarden Secrets Manager backend (simplify to keychain/credential/encrypted)
- Document `-help`, `-version` flags and environment variables
- Document command aliases in README

## 2026.1.83


### Features
- **Age encryption for secrets sync** - Public-key encryption via [age](https://github.com/FiloSottile/age) replaces password-based secrets sync. Auto-downloads the age binary, generates keypairs, and encrypts to per-session recipients. No shared password needed across machines.
- **Resume fallback** - Selecting "continue" on a session with no previous conversation now falls back to a fresh session instead of exiting.
- **Task list persistence** - `CLAUDE_CODE_TASK_LIST_ID` environment variable enables task list persistence across session restarts.
- **NO_COLOR support** - Respects the [no-color.org](https://no-color.org) convention to disable all terminal colors.
- **Nerd Font icons** - Set `CS_NERD_FONTS=1` for richer icons (lock, sync, home) in session banners and listings.
- **Secret count in session list** - `cs -list` now shows how many secrets each session has.

### Fixes
- **set -e crash on session launch** - Fixed a crash caused by strict error handling during session startup.

### Improvements
- Warm color palette (rust/orange/gold) for help output, session list, and banner with gradient bar.
- Removed Bitwarden Secrets Manager backend (simplifying to OS keychain + age).
- Keychain migration notice shows once then becomes a banner notification.
- Documentation updates for environment variables, command aliases, and age encryption.

## 2026.1.82


### Features
- Add CLAUDE_CODE_TASK_LIST_ID environment variable for task list persistence across sessions

### Fixes
- Fix set -e crash on session launch (post-increment arithmetic expression returned falsy exit code)

### Documentation
- Document CS_SECRETS_BACKEND environment variable in README
- Expand session environment variables documentation

## 2026.1.81


### Features
- **Age encryption for secrets sync** - Modern public-key encryption replaces password-based sync; auto-configures on first export
- **Nerd Font icon support** - Set `CS_NERD_FONTS=1` for enhanced icons (mdi-lock, mdi-sync, mdi-home)
- **Secret count in session list** - `cs -list` now shows lock icon and count for sessions with secrets
- **NO_COLOR support** - Disable colors with `NO_COLOR=1` or automatically when piping (follows no-color.org standard)

### Improvements
- **Claude warm color palette** - Updated from Tokyo Night to warm rust/orange/gold theme matching Claude branding
- **Colorized help output** - `cs -help` now uses consistent warm color styling
- **Colorized list output** - `cs -list` matches help style with RUST headers and GOLD session names

### Other
- Removed Bitwarden Secrets Manager backend
- Documentation improvements for command aliases and environment variables

## 2026.1.80


### Improvements
- **Session banner redesign** - Gradient left bar (purple→cyan) matching install banner style
- **Consistent color scheme** - Blue labels, green version, cyan paths, gray status text

## 2026.1.78


### Features
- **Age encryption for secrets sync** - Modern public-key encryption using [age](https://github.com/FiloSottile/age). No shared password needed - just share public keys
- **Auto-setup on first export** - Age keypair and recipients auto-configure when you first export secrets
- **Keychain migration notice** - Notifies users about migrating to OS keychain on session start

### Improvements
- **export-file/import-file** now prefer age encryption when recipients are configured
- **sync_pull** automatically imports from `secrets.age` (with fallback to legacy `secrets.enc`)
- Improved documentation for environment variables and CLI flags

### Changes
- Removed Bitwarden Secrets Manager backend (simplifies codebase, age provides better UX)
- `CS_SECRETS_PASSWORD` is now marked as legacy option (age preferred)

## 2026.1.74


### Breaking Changes
- **Removed Bitwarden Secrets Manager backend** - Secrets storage now uses OS keychain (macOS/Windows) or encrypted files only. This simplifies the codebase and removes the `bws` dependency.

### Features
- Added keychain migration notice to session banner when secrets need migration

### Improvements
- Keychain migration now prompts once, then shows notification only on subsequent sessions
- Documentation now covers `-help`, `-version` flags and `CLAUDE_CODE_BIN`, `CLAUDE_SESSION_NAME` environment variables

## 2026.1.73


- Keychain migration now prompts once with default No, then shows notification only on subsequent session starts
- Tracks prompted sessions in `~/.cs-secrets/.migration-prompted`

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.1.72...v2026.1.73

## 2026.1.72


### Features
- Add visible keychain migration notice when starting sessions (displays in terminal banner when Bitwarden is configured but keychain secrets exist)

### Fixes  
- Fix `migrate-backend` command when Bitwarden is already active - add `--from` option to specify source backend
- Update migration notice to use correct command syntax

### Documentation
- Document `export-file`, `import-file`, and `migrate-backend` commands in secrets.md
- Add "Syncing Secrets Across Machines" and "Migrating Between Backends" sections

This is the first tagged release. Previous versions were distributed without tags.
