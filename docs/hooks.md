# Hooks

The installer configures Claude Code hooks that enable session management features.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start (including source: `startup`, `resume`, `clear`, `compact`) to `.cs/logs/session.log` and appends a `session_start` event to `.cs/timeline.jsonl`
- On `startup`/`resume` only: configures `transfer.hideRefs`, recovers autosaved changes from crashed sessions, auto-pulls from remote
- On `startup`/`resume` only: seeds `.cs/files.md` via `files-scan.sh` if it doesn't exist yet (background, non-blocking)
- On `resume` only: injects dynamic context (last activity, recent commits, objective, up to 5 most recently active sibling sessions with their objectives)
- On all sources: exports session environment variables, injects session context into Claude's system prompt

## artifact-tracker.sh (PreToolUse on Write)

Runs before any file write operation:
- Detects script and config files by extension
- Redirects tracked files to `.cs/artifacts/` directory
- Updates `.cs/artifacts/MANIFEST.json` with metadata
- Handles duplicate filenames automatically
- **Detects and secures sensitive data** (see [Secrets](secrets.md))

**Tracked extensions:**
- Scripts: `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.ts`, `.rb`, `.pl`
- Configs: `.conf`, `.config`, `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.env`

## changes-tracker.sh (PostToolUse)

Runs after any file modification (Edit, Write, MultiEdit):
- Logs file path and timestamp to `.cs/changes.md`
- Skips session documentation files and artifacts (tracked separately)
- When `.cs/files.md` exists and the target is already indexed, surgically refreshes that entry's token estimate (`bytes / 3.75`) and "updated" date — preserves any hand-written description. Does not create `files.md` or add new entries (session-start seeds the index; out-of-band files wait for the next full scan).

## discovery-commits.sh (PostToolUse on Write/Edit)

Runs after any file modification (Write or Edit), providing crash recovery for all session files:
- Autosaves entire working tree to `refs/cs/auto` shadow ref using git plumbing commands
- Does not create commits on `main` or touch the working tree index
- Each autosave chains onto the previous one (linked list of snapshots)
- For discovery file edits, also logs the latest heading/bullet to `session.log`
- Runs in background to avoid blocking the session

## discoveries-reminder.sh (Stop)

Runs when Claude pauses for user input:
- Reminds to review existing entries and update `.cs/discoveries.md` if not recently modified
- Uses 5-minute cooldown to avoid excessive reminders
- When discoveries.md exceeds its size budget (default 60KB, override via `CS_DISCOVERIES_MAX_SIZE` env var), instructs Claude to summarize old entries into `.cs/discoveries.compact.md` and trim the active file

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time and exit reason (`user_exit`, `sigint`, `error`, `timeout`) and appends a `session_end` event to `.cs/timeline.jsonl`
- Creates `.cs/archives/artifacts-YYYYMMDD-HHMMSS.tar.gz` archive (skipped on `sigint` for faster exit)
- Exports secrets to encrypted file if `CS_SECRETS_PASSWORD` is set
- Auto-commits all accumulated changes with one clean commit and pushes to remote if sync is enabled
- Deletes the shadow autosave ref (`refs/cs/auto`)
- Cleans up lock files

## subagent-context.sh (SubagentStart)

Runs when Claude Code spawns a subagent (via the Agent tool):
- Injects session context into subagents so they know about the cs session
- Provides session directory, artifacts directory, and key rules (secrets handling, documentation protocol)
- Uses `additionalContext` in the same format as SessionStart

## tool-failure-logger.sh (PostToolUseFailure)

Runs when a tool call fails (async, non-blocking):
- Logs tool name and truncated error message to `.cs/logs/session.log`
- Helps debug build failures, test errors, and other tool issues after the fact

## session-auto-approve.sh (PermissionRequest on Write/Edit)

Runs when Claude Code would show a permission dialog for Write or Edit:
- Auto-approves writes to files inside the session's `.cs/` metadata directory
- Falls through to the normal permission prompt for all other files
- Scoped narrowly to session metadata only — project files always require explicit approval

## command-tracker.sh (PostToolUse on Bash)

Runs after Bash tool calls (async, non-blocking):
- Captures interesting CLI commands to `.cs/commands.md`
- Filters trivial commands (cd, ls, pwd, echo, cat, etc.) and bare interpreters (vim, python, node without flags)
- Scrubs secrets: `KEY=value` env vars, Bearer tokens, `--password`/`--token` flags
- Categorizes commands: Build, Test, Dev, Deploy, Lint, Other
- Deduplicates exact matches, bumps use count and last-used date
- Detects skill-worthy commands (3+ uses across 2+ sessions) and suggests `/skillify`

## bash-logger.sh (PreToolUse on Bash)

Runs before every Bash tool call (sync, fast):
- Logs `[timestamp] BASH: command` to `.cs/logs/session.log`
- Creates a complete audit trail of all commands Claude runs
- Truncates long commands at 200 chars
- Never blocks — uses `set -uo pipefail` without `set -e`

## files-context.sh (PreToolUse on Read)

Runs before any `Read` tool call:
- Strips `CLAUDE_SESSION_DIR` from the incoming absolute `file_path` to get the key used in `.cs/files.md`
- Looks up the matching `## <relative-path>` entry via a single awk pass
- Emits `additionalContext` with the description (if any) and token estimate, so Claude sees the file's summary and rough size before deciding how much to read
- Exits 0 cleanly when the file isn't indexed, `files.md` doesn't exist, the tool is not `Read`, or the session isn't a cs session — warns, never blocks

## files-scan.sh (utility — not a Claude Code hook)

Invoked internally by `session-start.sh` (initial seed) and available for manual re-scans. Not registered in `settings.json`:
- Walks `CLAUDE_SESSION_DIR` and writes `.cs/files.md` with one `## <path>` section per file, optional description line, and a `~N tokens -- updated YYYY-MM-DD` metadata line
- Token estimate is `bytes / 3.75` rounded (no per-extension differentiation)
- Hardcoded excludes: `.cs/`, `.git/`, `node_modules/`, `dist/`, `build/`, `.DS_Store`
- Preserves any hand-written descriptions across re-runs by parsing the existing file into a path→description map before re-emitting
- Accepts an explicit workspace directory as `$1` and uses it as the source of truth for `.cs/` — the env-var fallback (`CLAUDE_SESSION_META_DIR`) only applies when no argument is given, so invoking the script from a developer shell (where the env var points elsewhere) can't misroute output

## Hook Configuration

The hooks are configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 30 }] }
    ],
    "PreToolUse": [
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "~/.claude/hooks/artifact-tracker.sh", "timeout": 10 }] },
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/bash-logger.sh", "timeout": 5 }] },
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "~/.claude/hooks/files-context.sh", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/changes-tracker.sh", "timeout": 10 }] },
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/discovery-commits.sh", "timeout": 10, "async": true }] },
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/command-tracker.sh", "timeout": 10, "async": true }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/discoveries-reminder.sh", "timeout": 10 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-end.sh", "timeout": 30 }] }
    ],
    "SubagentStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/subagent-context.sh", "timeout": 10 }] }
    ],
    "PostToolUseFailure": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/tool-failure-logger.sh", "timeout": 10, "async": true }] }
    ],
    "PermissionRequest": [
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-auto-approve.sh", "timeout": 5 }] }
    ]
  }
}
```

Hooks only activate when running inside a `cs` session (detected via `CLAUDE_SESSION_NAME` environment variable). Outside of `cs` sessions, they pass through without effect.
