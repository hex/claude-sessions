# Session Sync

Sync sessions across machines using git.

**Note:** All new sessions automatically get local git version control. This section is for setting up **remote sync** across machines.

## Setup

1. Set environment variables (same on all machines):
   ```bash
   export CS_SECRETS_PASSWORD="your-secure-password"
   export CS_SYNC_PREFIX="git@github.com:you/"  # Optional: enables short syntax
   # Add to ~/.bashrc or ~/.zshrc for persistence
   ```

2. Initialize sync for a session:
   ```bash
   cs my-session -sync remote                      # Uses CS_SYNC_PREFIX
   cs my-session -sync push

   # Or with explicit URL:
   cs my-session -sync remote git@github.com:you/my-session.git
   ```

3. On another machine:
   ```bash
   export CS_SECRETS_PASSWORD="your-secure-password"
   export CS_SYNC_PREFIX="git@github.com:you/"

   cs -sync clone my-session                     # Uses CS_SYNC_PREFIX
   cs my-session                                 # Start working

   # Or with explicit URL:
   cs -sync clone git@github.com:you/my-session.git
   ```

## Local-Only Mode

**New sessions automatically get local git version control** - no remote repository required. This provides full version history for your session stored only on your machine.

### Benefits of Local-Only Mode

- **Privacy:** Keep session history completely local
- **Simplicity:** No GitHub/GitLab account needed
- **Offline:** Version control without internet
- **Automatic:** Enabled by default for all new sessions
- **Upgrade path:** Add a remote anytime with `sync init <url>`

### Using Local-Only Mode

Local git is automatically initialized when you create a session, with auto-sync enabled by default:

```bash
# Create new session (git auto-initialized, auto-sync on)
cs my-session
# ... work happens ...
# exit Claude Code → auto-commit happens

# Manual commit if needed during session
cs my-session -sync push

# Check status
cs my-session -sync status

# Disable auto-sync if desired
cs my-session -sync auto off
```

### Upgrading to Remote Sync

Add a remote at any time:

```bash
# Add remote to existing local-only session
cs my-session -sync remote git@github.com:you/my-session.git

# Push commits to remote
cs my-session -sync push
```

### Behavior Differences

| Feature | Local-Only | With Remote |
|---------|------------|-------------|
| `sync remote` | No-op (already local) | Adds remote origin |
| `sync push` | Commits locally | Commits and pushes |
| `sync pull` | No-op (graceful skip) | Pulls from remote |
| `sync status` | Shows local commit count | Shows ahead/behind |
| Auto-sync | Commits on session end | Syncs with remote |

## Commands

| Command | Description |
|---------|-------------|
| `cs <session> -sync remote` | Add remote to git repo (uses CS_SYNC_PREFIX) |
| `cs <session> -sync remote <url>` | Add remote to git repo with explicit URL |
| `cs <session> -sync push` | Commit (and push if remote configured) |
| `cs <session> -sync pull` | Pull and import secrets (if remote configured) |
| `cs <session> -sync status` | Show sync state (local or remote) |
| `cs <session> -sync auto on` | Enable auto-sync on session start/end |
| `cs -sync clone <session>` | Clone session (uses CS_SYNC_PREFIX) |
| `cs -sync clone <url>` | Clone session from explicit URL |
| `cs <session> -s` | Alias for `-sync` |

## Auto-Sync

**Auto-sync is enabled by default for all new sessions.** Changes are automatically committed in two ways:

1. **Discovery commits:** Automatically committed when you write to `discoveries.md`, using the latest entry as the commit message
2. **Session end commits:** All remaining changes committed when the session ends, with a summary of changed filenames

All auto-commits are prefixed with a robot emoji (🤖) to distinguish them from manual commits. You can filter them with `git log --grep='🤖'`.

When enabled:
- **Session start:** Pulls latest changes from remote (if configured)
- **Discovery writes:** Creates commit with latest discovery entry as message (e.g., `🤖 Found auth timeout bug`)
- **Session end:** Commits remaining changes with file summary (e.g., `🤖 Update session.log, discoveries.md (+1 more)`)

To disable for a specific session:
```bash
cs my-session -sync auto off
```

To re-enable:
```bash
cs my-session -sync auto on
```

## Secrets Sync

Secrets are exported to `.cs/secrets.enc` (AES-256-CBC encrypted) and included in git.

**Important:** You must set `CS_SECRETS_PASSWORD` to the same value on all machines for secrets to sync correctly. Machine-derived passwords are not portable.

## What Gets Synced

- CLAUDE.md (at session root)
- .cs/ metadata directory (README.md, discoveries.md, changes.md, sync.conf)
- .cs/artifacts/ directory (scripts, configs, MANIFEST.json)
- .cs/logs/session.log
- Encrypted secrets (.cs/secrets.enc or .cs/secrets.age)

**Excluded from sync:** .cs/archives/, lock files, OS/editor files

## Security

When initializing sync, you'll see a security notice:

```
┌─────────────────────────────────────────────────────────────┐
│ SECURITY NOTICE                                             │
│                                                             │
│ Session data may contain sensitive information.             │
│ Use a PRIVATE repository to protect your data.              │
│ Secrets are encrypted, but session files are not.           │
└─────────────────────────────────────────────────────────────┘
```

Always use private repositories for session sync. While secrets are encrypted, session documentation (discoveries.md, README.md, etc.) may contain sensitive context about your work.

## Troubleshooting

### "No upstream tracking configured" Warning

If `cs <session> -sync status` shows this warning:

```
Warning: No upstream tracking configured for branch 'main'
Run: git branch --set-upstream-to=origin/main main
```

**Cause:** Your local git branch isn't configured to track the remote branch.

**Fix:** Run the suggested command in your session directory:

```bash
cd ~/.claude-sessions/<session-name>
git branch --set-upstream-to=origin/main main
```

Replace `main` with your branch name if different.

**Why it happens:**
- You cloned without using `git clone` (manual git init)
- You pushed without the `-u` flag: `git push origin main` (should be `git push -u origin main`)
- You created a new branch that doesn't track a remote yet

**What it means:** Upstream tracking tells git which remote branch your local branch corresponds to. Without it, git commands like `git pull` and sync status checks don't know where to pull from or compare against.

The `cs -sync push` and `cs -sync pull` commands will still work (they explicitly use `origin/main`), but status checks can't determine if you're ahead or behind the remote.
