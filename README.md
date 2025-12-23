# cs - Claude Code Session Manager

A session manager for [Claude Code](https://github.com/anthropics/claude-code) that creates isolated workspaces with automatic documentation and artifact tracking.

## Features

- **Isolated session workspaces** - Each session has its own directory with structured documentation
- **Automatic artifact tracking** - Scripts and configs are auto-saved to `artifacts/`
- **Secure secrets handling** - Sensitive data auto-detected and stored in OS keychain (cross-platform)
- **Documentation templates** - Pre-configured markdown files for discoveries and auto-logged changes
- **Smart resume** - Automatically resumes existing sessions or creates new ones
- **Session-specific context** - Custom CLAUDE.md instructions for each session
- **Update notifications** - Checks for updates daily and notifies when a new version is available

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
3. Install slash commands to `~/.claude/commands/`
4. Configure hooks in `~/.claude/settings.json`
5. Check if `~/.local/bin` is in your PATH

If `~/.local/bin` is not in your PATH, add this to your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Uninstalling

```bash
./install.sh --uninstall
```

Or manually:

```bash
# Remove cs script
rm ~/.local/bin/cs

# Remove hooks
rm ~/.claude/hooks/session-start.sh
rm ~/.claude/hooks/artifact-tracker.sh
rm ~/.claude/hooks/session-end.sh

# Remove commands
rm ~/.claude/commands/summary.md

# Remove hook configuration from settings.json
# Edit ~/.claude/settings.json and remove the SessionStart, PreToolUse (Write matcher),
# and SessionEnd entries that reference the above hook scripts

# Optionally remove session data
rm -rf ~/.claude-sessions/
```

The uninstaller preserves:
- Other hooks you've configured in `~/.claude/settings.json`
- Other settings like `statusLine`, `alwaysThinkingEnabled`, etc.

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
- **Detects and secures sensitive data** (see Secrets Handling below)

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

## Slash Commands

### /summary

Generates an intelligent summary of the current session by reading all documentation files and synthesizing them into a cohesive narrative.

```
/summary
```

This command:
1. Reads all session files (README.md, discoveries.md, changes.md, artifacts/MANIFEST.json)
2. Synthesizes findings into a narrative summary
3. Writes the result to `summary.md` in the session directory

The summary includes: objective, environment, key discoveries, changes made, artifacts created, and outcome.

## Session Migration

When resuming an existing session, `cs` automatically migrates older session formats to the latest structure. This ensures CLAUDE.md always has the current instructions for context loading.

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
cs <session-name>           # Create or resume a session
cs -list                    # List all sessions (alias: cs -ls)
cs -remove <session-name>   # Remove a session (alias: cs -rm)
cs -secrets <cmd>           # Manage session secrets
cs -update                  # Update cs to latest version
cs -update --check          # Check for updates without installing
cs -update --force          # Force reinstall even if up to date
cs -help                    # Show help (alias: cs -h)
cs -version                 # Show version (alias: cs -v)
```

### Updates

cs checks for updates hourly and displays a notification in the session banner when a new version is available. Update checks use cache busting to bypass GitHub's CDN cache.

- **Check interval**: 1 hour (cached in `~/.cache/cs/update-check`)
- **Manual check**: `cs -update --check`
- **Install update**: `cs -update`
- **Force reinstall**: `cs -update --force`

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
├── discoveries.md      # Findings, observations, and ideas
├── changes.md          # Auto-logged file modifications
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
Document what you learn and observe:
- System architecture and configuration
- Existing patterns and conventions
- Dependencies and relationships
- Unexpected behaviors or gotchas
- Ideas and potential improvements
- Questions to investigate

### changes.md
Automatically logs all file modifications with timestamps:
```
- [2025-12-19 17:59:42] Edit: /path/to/file.js
```

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

## Automatic Changes Logging

All file modifications (Edit, Write, MultiEdit) outside the session directory are automatically logged to `changes.md` with timestamps:

```
- [2025-12-19 17:59:42] Edit: /path/to/project/src/app.js
- [2025-12-19 17:59:45] Write: /path/to/project/config.yaml
```

This provides a complete audit trail of every file touched during the session without requiring manual documentation.

**Excluded from logging:**
- Session documentation files (changes.md, discoveries.md, etc.)
- Files in the artifacts directory (tracked separately)

## Secrets Handling

Sensitive data is automatically detected and stored securely instead of being written to artifact files in plaintext.

### Storage Backends

The `cs -secrets` command auto-detects the best available backend:

| Platform | Backend | Storage Location |
|----------|---------|------------------|
| macOS | Keychain | Login keychain |
| Windows | Credential Manager | Windows Credential Store (requires PowerShell SecretManagement) |
| Linux/Other | Encrypted file | `~/.cs-secrets/<session>.enc` |

**Windows Setup:**

To use the Windows Credential Manager backend, install the PowerShell SecretManagement modules:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.SecretStore -Scope CurrentUser
```

If these modules are not installed, `cs -secrets` automatically falls back to the encrypted file backend.

**Encrypted File Backend:**

The encrypted file backend uses AES-256-CBC with PBKDF2 key derivation (100,000 iterations). The encryption key is derived from a machine-specific salt stored in `~/.cs-secrets/.salt`. This provides protection against:
- Casual snooping
- Accidental git commits of the secrets directory
- Backup/sync services copying plaintext credentials

For additional security, set `CS_SECRETS_PASSWORD` to use an explicit master password instead of the auto-derived key.

Check which backend is active: `cs -secrets backend`

### Auto-Detection

Secrets are detected and stored automatically in two ways:

**1. File-based detection** (via `artifact-tracker.sh` hook):

When writing files, secrets are detected by:
- File type: `.env` files
- Filename patterns: Files containing `key`, `secret`, `password`, `token`, `credential`, `auth`, `apikey`, `api_key`
- Content patterns: Variables like `API_KEY=`, `SECRET_TOKEN=`, `PASSWORD=`, etc.

**2. Conversational detection** (via `store-secret` skill):

When you share secrets in chat, Claude automatically invokes the `/store-secret` skill to capture them:
- "Here's my OpenAI key: sk-abc123..."
- "The password is hunter2"
- "Use this token: ghp_xxxx"

Claude identifies appropriate key names and stores secrets securely, then confirms what was stored.

### What Happens

When sensitive data is detected:
1. The actual values are extracted and stored securely
2. The artifact file is written with redacted placeholders:
   ```
   API_KEY=[REDACTED: stored in keychain as API_KEY]
   ```
3. MANIFEST.json records which secrets exist (not the values)

### Using cs -secrets

The `cs -secrets` command manages session secrets:

```bash
# Check which storage backend is being used
cs -secrets backend

# List all secrets for current session
cs -secrets list

# Get a specific secret value
cs -secrets get API_KEY

# Store a secret manually
cs -secrets set my_secret "secret-value"

# Delete a secret
cs -secrets rm API_KEY

# Export all secrets as environment variables
eval "$(cs -secrets export)"

# Use with a specific session
cs -secrets --session my-session list
```

### Migrating Existing Secrets

If you have sessions created before the secrets feature was added, plaintext secrets may exist in artifact files. Use the migrate command to move them to secure storage:

```bash
# Scan artifacts and migrate secrets to keychain (keeps original files)
cs -secrets migrate

# Migrate and redact plaintext values in artifact files
cs -secrets migrate --redact
```

The migrate command:
1. Scans all artifact files in the session
2. Detects KEY=value patterns with sensitive key names
3. Stores values securely in the keychain
4. Optionally replaces plaintext with `[REDACTED: stored in keychain as KEY]`

### Environment Variables

- `CLAUDE_SESSION_NAME` - Current session (set automatically by `cs`)
- `CS_SECRETS_PASSWORD` - Optional master password for encrypted backend (overrides auto-derived key)

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
   - Update discoveries.md with findings and observations
   - changes.md is updated automatically when files are modified

4. **Resume later:**
   ```bash
   cs my-task  # Same command resumes the session
   ```

## Session Banner

When starting a session, cs displays a status banner:

```
▌ cs 2025.12.23
▌ my-session (+ new)
▌ /Users/you/.claude-sessions/my-session
▌ ⚿ 3 secrets
```

- **Version** - Current cs version
- **Session name** - With status indicator (`+` new, `↻` resuming)
- **Path** - Full path to session directory
- **Secrets** - Number of secrets stored for this session (if any)

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

Configuration is done via environment variables. Add these to your `~/.bashrc` or `~/.zshrc`:

```bash
# Override sessions directory (default: ~/.claude-sessions)
export CS_SESSIONS_ROOT="/path/to/your/sessions"

# Override Claude Code binary (default: claude)
# Can include arguments - use $HOME instead of ~ in paths
export CLAUDE_CODE_BIN="$HOME/.local/bin/claude --dangerously-skip-permissions"
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
