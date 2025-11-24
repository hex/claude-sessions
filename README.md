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
2. Make it executable
3. Check if `~/.local/bin` is in your PATH

If `~/.local/bin` is not in your PATH, add this to your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Requirements

- [Claude Code](https://github.com/anthropics/claude-code) - Must be available as `claude` command
- Bash 4.0+

## Usage

Run `cs` from anywhere on your system - it creates isolated session workspaces independent of your current directory:

```bash
cs <session-name>
```

Sessions are stored in `~/.claude-sessions/` and are completely independent. You don't need to be in a git repo or special folder to use `cs`.

### Examples

```bash
# Create or resume a debugging session (from any directory)
cs debug-api

# Create or resume a server troubleshooting session
cs server-fix

# Create or resume a feature development session
cs add-auth
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
