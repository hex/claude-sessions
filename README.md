# cs - Claude Code Session Manager

A session manager for [Claude Code](https://github.com/anthropics/claude-code) that creates isolated workspaces with automatic documentation and artifact tracking.

![cs session demo](assets/screenshot.png)

## Why cs?

Claude Code doesn't require a project. You can spin up an instance to debug an API, troubleshoot home automation, research a hardware problem, or explore any idea that comes to mind.

But conversations get lost. You discover key insights, create useful scripts, figure out a tricky configuration - then the session ends and it's gone.

**cs gives every task a home:**

```bash
cs debug-api          # Investigate that flaky endpoint
cs homeassistant      # Fix your smart home setup
cs router-config      # Document your network settings
cs research-llms      # Explore a topic, keep your notes
```

Each session is a persistent workspace - documentation, artifacts, and secrets that survive across conversations and sync across machines.

No git repo required. No project structure needed. Just a name for what you're working on.

## Features

- **Isolated session workspaces** - Each session has its own directory with structured documentation
- **Automatic artifact tracking** - Scripts and configs are auto-saved to `artifacts/`
- **Secure secrets handling** - Sensitive data auto-detected and stored in OS keychain
- **Documentation templates** - Pre-configured markdown files for discoveries and changes
- **Git-based sync** - Sync sessions across machines with encrypted secrets
- **Update notifications** - Checks for updates and notifies when new versions are available

## Installation

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hex/claude-sessions/main/install.sh)"
```

> :warning: Always [review scripts](install.sh) before running them from the internet. Use [VirusTotal](https://www.virustotal.com/) to scan unfamiliar scripts for malware.

Or clone and run `./install.sh`.

The installer:
- Adds `cs` and `cs-secrets` to `~/.local/bin/`
- Installs five [hooks](docs/hooks.md) to `~/.claude/hooks/` for session tracking
- Adds a `/summary` command and `store-secret` skill to `~/.claude/`
- Configures hook entries in `~/.claude/settings.json`

## Usage

```bash
cs <session-name>           # Create or resume a session
cs -list                    # List all sessions
cs -remove <name>           # Remove a session
cs -update                  # Update to latest version
cs -uninstall               # Uninstall cs
```

### Session Commands

```bash
cs <session> -sync <cmd>    # Sync with git remote
cs <session> -secrets <cmd> # Manage secrets
```

### Examples

```bash
cs debug-api                # Create/resume 'debug-api' session
cs fix-auth -sync init      # Initialize sync for session
cs my-project -secrets list # List secrets for session
```

## Session Structure

```
~/.claude-sessions/<session-name>/
├── README.md           # Objective, environment, outcome
├── discoveries.md      # Findings and observations
├── changes.md          # Auto-logged file modifications
├── CLAUDE.md           # Session instructions for Claude
├── artifacts/          # Auto-tracked scripts and configs
└── logs/session.log    # Session command log
```

## Configuration

Add to `~/.bashrc` or `~/.zshrc`:

```bash
# Sessions directory (default: ~/.claude-sessions)
export CS_SESSIONS_ROOT="/path/to/sessions"

# Git sync prefix for shorter commands
export CS_SYNC_PREFIX="git@github.com:youruser/"

# Master password for cross-machine secrets sync
export CS_SECRETS_PASSWORD="your-secure-password"
```

## Documentation

- **[Hooks](docs/hooks.md)** - How the five Claude Code hooks work
- **[Secrets](docs/secrets.md)** - Secure secrets handling and storage backends
- **[Sync](docs/sync.md)** - Git-based session sync across machines

## Requirements

- [Claude Code](https://github.com/anthropics/claude-code)
- Bash 4.0+
- `jq` for hook configuration
- `git` for session sync

## Uninstalling

```bash
cs -uninstall
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue or PR.
