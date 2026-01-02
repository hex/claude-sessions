# cs - Claude Code Session Manager

A session manager for [Claude Code](https://github.com/anthropics/claude-code) that creates isolated workspaces with automatic documentation and artifact tracking.

![cs session demo](assets/screenshot.png)

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

Or clone and run `./install.sh`.

The installer adds `cs` to `~/.local/bin/` and configures Claude Code hooks.

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
