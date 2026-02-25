# Hooks

The installer configures Claude Code hooks that enable session management features.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start to `.cs/logs/session.log`
- Configures `transfer.hideRefs` to prevent shadow refs from being pushed
- Recovers autosaved changes from a crashed previous session (restores from `refs/cs/auto`)
- Exports session environment variables
- Injects session context into Claude's system prompt
- Auto-pulls from remote if sync is enabled

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

## discovery-commits.sh (PostToolUse on Write/Edit)

Runs after modifications to discovery files (`.cs/discoveries.md`, `.cs/discoveries.archive.md`, `.cs/discoveries.compact.md`):
- Parses the latest `##` heading (falls back to last bullet point if no heading)
- Autosaves to `refs/cs/auto` shadow ref using git plumbing commands
- Does not create commits on `main` or touch the working tree index
- Each autosave chains onto the previous one (linked list of snapshots)
- Runs in background to avoid blocking the session

## discoveries-reminder.sh (Stop)

Runs when Claude pauses for user input:
- Reminds to review existing entries and update `.cs/discoveries.md` if not recently modified
- Uses 5-minute cooldown to avoid excessive reminders
- Instructs Claude to run discoveries compaction in the background when the archive has grown significantly

## discoveries-archiver.sh (PreCompact)

Runs before Claude Code compresses conversation history:
- Checks if `.cs/discoveries.md` exceeds 200 lines
- Moves oldest entries to `.cs/discoveries.archive.md` (append-only), keeping the newest ~100 lines
- Splits on `##` heading boundaries to avoid breaking entries mid-section
- Logs the rotation to `.cs/logs/session.log`

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time
- Creates `.cs/archives/artifacts-YYYYMMDD-HHMMSS.tar.gz` archive
- Exports secrets to encrypted file if `CS_SECRETS_PASSWORD` is set
- Auto-commits all accumulated changes with one clean commit and pushes to remote if sync is enabled
- Deletes the shadow autosave ref (`refs/cs/auto`)
- Cleans up lock files

## Hook Configuration

The hooks are configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "~/.claude/hooks/artifact-tracker.sh", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/changes-tracker.sh", "timeout": 10 }] },
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/discovery-commits.sh", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/discoveries-reminder.sh", "timeout": 10 }] }
    ],
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/discoveries-archiver.sh", "timeout": 10 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-end.sh", "timeout": 10 }] }
    ]
  }
}
```

Hooks only activate when running inside a `cs` session (detected via `CLAUDE_SESSION_NAME` environment variable). Outside of `cs` sessions, they pass through without effect.
