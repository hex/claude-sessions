# Hooks

The installer configures five Claude Code hooks that enable session management features.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start to `logs/session.log`
- Exports session environment variables
- Injects session context into Claude's system prompt
- Auto-pulls from remote if sync is enabled

## artifact-tracker.sh (PreToolUse on Write)

Runs before any file write operation:
- Detects script and config files by extension
- Redirects tracked files to `artifacts/` directory
- Updates `artifacts/MANIFEST.json` with metadata
- Handles duplicate filenames automatically
- **Detects and secures sensitive data** (see [Secrets](secrets.md))

**Tracked extensions:**
- Scripts: `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.ts`, `.rb`, `.pl`
- Configs: `.conf`, `.config`, `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.env`

## changes-tracker.sh (PostToolUse)

Runs after any file modification (Edit, Write, MultiEdit):
- Logs file path and timestamp to `changes.md`
- Skips session documentation files and artifacts (tracked separately)

## discoveries-reminder.sh (Stop)

Runs when Claude pauses for user input:
- Reminds to update `discoveries.md` if not recently modified
- Uses 5-minute cooldown to avoid excessive reminders

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time
- Creates `archives/artifacts-YYYYMMDD-HHMMSS.tar.gz` archive
- Updates global `~/.claude-sessions/INDEX.md`
- Auto-pushes to remote if sync is enabled
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
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/changes-tracker.sh", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/discoveries-reminder.sh", "timeout": 10 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-end.sh", "timeout": 10 }] }
    ]
  }
}
```

Hooks only activate when running inside a `cs` session (detected via `CLAUDE_SESSION_NAME` environment variable). Outside of `cs` sessions, they pass through without effect.
