# cs - Claude Code Session Manager

A session manager for [Claude Code](https://github.com/anthropics/claude-code) that creates isolated workspaces with automatic documentation and artifact tracking.

## Features

- **Isolated session workspaces** - Each session has its own directory with structured documentation
- **Automatic artifact tracking** - Scripts and configs are auto-saved to `artifacts/`
- **Documentation templates** - Pre-configured markdown files for tracking discoveries, changes, and notes
- **Smart resume** - Automatically resumes existing sessions or creates new ones
- **Session-specific context** - Custom CLAUDE.md instructions for each session

## Installation

**Quick install (recommended):**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hex/claude-sessions/main/install.sh)"
```

**Or clone and install:**

```bash
git clone https://github.com/hex/claude-sessions.git
cd claude-sessions
./install.sh
```

The installer will:
1. Download (or copy) `cs` to `~/.local/bin/cs`
2. Install Claude Code hooks to `~/.claude/hooks/`
3. Configure hooks in `~/.claude/settings.json`
4. Check if `~/.local/bin` is in your PATH

If `~/.local/bin` is not in your PATH, add this to your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Uninstalling

```bash
./install.sh --uninstall
```

This removes:
- `~/.local/bin/cs`
- Hooks from `~/.claude/hooks/`
- Hook configuration from `~/.claude/settings.json`

You'll be prompted whether to delete session data at `~/.claude-sessions/`.

## Requirements

- [Claude Code](https://github.com/anthropics/claude-code) - Must be available as `claude` command
- Bash 4.0+
- `jq` - For hook configuration (install via `brew install jq` or `apt install jq`)

## Hooks

The installer configures three Claude Code hooks that enable session management features:

### session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start to `logs/session.log`
- Exports session environment variables
- Injects session context into Claude's system prompt

### artifact-tracker.sh (PreToolUse on Write)

Runs before any file write operation:
- Detects script and config files by extension
- Redirects tracked files to `artifacts/` directory
- Updates `artifacts/MANIFEST.json` with metadata
- Handles duplicate filenames automatically

**Tracked extensions:**
- Scripts: `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.ts`, `.rb`, `.pl`
- Configs: `.conf`, `.config`, `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.env`

### session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time
- Creates `artifacts-YYYYMMDD-HHMMSS.tar.gz` archive
- Updates global `~/.claude-sessions/INDEX.md`
- Cleans up lock files

### Hook Configuration

The hooks are configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/.claude/hooks/session-start.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/.claude/hooks/artifact-tracker.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/.claude/hooks/session-end.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Hooks only activate when running inside a `cs` session (detected via `CLAUDE_SESSION_NAME` environment variable). Outside of `cs` sessions, they pass through without effect.

## How It Works

**`cs` is completely independent:**

1. **Creates its own workspace** - Sessions are stored in `~/.claude-sessions/<session-name>/` by default
2. **Can be run from anywhere** - Just type `cs my-session` from any directory
3. **Not tied to git repos** - Each session is its own isolated environment

**Each session directory is independent:**
- Has its own documentation (README.md, discoveries.md, etc.)
- Has its own artifacts/ folder
- Can optionally be a git repo itself if you want to track changes
- But doesn't need to be

The session workspace is where Claude Code runs, but you can SSH to servers, work on remote systems, or do anything else from within that session. The documentation and artifacts stay in the session directory.

## Usage

```bash
cs <session-name>
```

### Examples

```bash
# From anywhere on your system:
cd ~
cs debug-task
# Creates ~/.claude-sessions/debug-task/ and launches Claude there

cd /some/project
cs fix-bug
# Creates ~/.claude-sessions/fix-bug/ and launches Claude there

# Each session is independent and can be resumed anytime
cs debug-task  # Resume the debug-task session
```

## Session Structure

Each session creates a directory at `~/.claude-sessions/<session-name>/` with:

```
<session-name>/
├── README.md           # Session overview, objective, environment, outcome
├── discoveries.md      # Document findings about the system/environment
├── changes.md          # Log all modifications and fixes made
├── notes.md            # Miscellaneous observations and ideas
├── CLAUDE.md           # Session-specific instructions for Claude
├── artifacts/          # Auto-tracked scripts and configuration files
│   └── MANIFEST.json   # Artifact metadata
└── logs/
    └── session.log     # Complete session command log
```

## Documentation Files

### README.md
Session overview with three key sections:
- **Objective** - What you're trying to accomplish
- **Environment** - System/server/context description
- **Outcome** - Summary of what was accomplished (filled at end)

### discoveries.md
Document what you learn about:
- System architecture and configuration
- Existing patterns and conventions
- Dependencies and relationships
- Unexpected behaviors or gotchas
- Useful commands or procedures

### changes.md
Track all modifications:
- Files modified
- Configuration changes
- Bug fixes
- Scripts created

### notes.md
Scratchpad for:
- Temporary thoughts and ideas
- Observations that don't fit elsewhere
- Quick notes during work

## Artifact Auto-Tracking

When Claude creates files with these extensions, they're automatically saved to `artifacts/`:

**Scripts:**
- `.sh`, `.bash`, `.zsh`
- `.py`, `.js`, `.ts`
- `.rb`, `.pl`

**Configs:**
- `.conf`, `.config`
- `.json`, `.yaml`, `.yml`
- `.toml`, `.ini`, `.env`

## Workflow

1. **Start session:**
   ```bash
   cs my-task
   ```

2. **Work with Claude:**
   - Claude Code launches in the session directory
   - All session files are in context via CLAUDE.md
   - Artifacts are automatically tracked

3. **Document as you go:**
   - Update discoveries.md with findings
   - Update changes.md with modifications
   - Use notes.md for quick thoughts

4. **Resume later:**
   ```bash
   cs my-task  # Same command resumes the session
   ```

## Environment Variables

When Claude Code launches, these environment variables are set:

- `CLAUDE_SESSION_NAME` - The session name
- `CLAUDE_SESSION_DIR` - Full path to session directory
- `CLAUDE_ARTIFACT_DIR` - Full path to artifacts directory

## Tmux Integration (Optional)

The `cs` tool does not use tmux by default. For advanced terminal multiplexing capabilities, you can install the [tmux skill](https://github.com/mitsuhiko/agent-commands/tree/main/skills/tmux) which allows Claude to remote control tmux sessions for interactive CLIs.

**Installation:**
```bash
# Install the tmux skill to ~/.claude/skills/
git clone https://github.com/mitsuhiko/agent-commands.git /tmp/agent-commands
cp -r /tmp/agent-commands/skills/tmux ~/.claude/skills/
```

Once installed, Claude can use the tmux skill to work with interactive tools like Python REPL, gdb, and other TTY applications.

## Configuration

By default, sessions are stored in `~/.claude-sessions/`.

To change this, set the `SESSIONS_ROOT` variable in the `cs` script:

```bash
SESSIONS_ROOT="/path/to/your/sessions"
```

To use a different Claude Code binary, set `CLAUDE_CODE_BIN`:

```bash
export CLAUDE_CODE_BIN="path/to/claude"
```

## SSH Workflow

The session manager works well for remote server work:

1. Launch a session locally: `cs server-debug`
2. SSH to remote server from within Claude Code
3. Run commands on remote system
4. Documentation and artifacts remain local
5. Session preserves all context when you resume

## Tips

- Use descriptive session names that indicate the task
- Update documentation throughout the session, not just at the end
- Review artifacts/ before ending a session to ensure useful scripts are saved
- Use `discoveries.md` as a knowledge base for the system you're working on

## License

MIT

## Contributing

Contributions welcome! Please open an issue or PR.
