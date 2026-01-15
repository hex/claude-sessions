# Session Sync

Sync sessions across machines using git.

## Setup

1. Set environment variables (same on all machines):
   ```bash
   export CS_SECRETS_PASSWORD="your-secure-password"
   export CS_SYNC_PREFIX="git@github.com:you/"  # Optional: enables short syntax
   # Add to ~/.bashrc or ~/.zshrc for persistence
   ```

2. Initialize sync for a session:
   ```bash
   cs my-session -sync init                      # Uses CS_SYNC_PREFIX
   cs my-session -sync push

   # Or with explicit URL:
   cs my-session -sync init git@github.com:you/my-session.git
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

## Commands

| Command | Description |
|---------|-------------|
| `cs <session> -sync init` | Initialize git repo (uses CS_SYNC_PREFIX) |
| `cs <session> -sync init <url>` | Initialize git repo with explicit URL |
| `cs <session> -sync push` | Commit and push (exports secrets) |
| `cs <session> -sync pull` | Pull and import secrets |
| `cs <session> -sync status` | Show sync state |
| `cs <session> -sync auto on` | Enable auto-sync on session start/end |
| `cs -sync clone <session>` | Clone session (uses CS_SYNC_PREFIX) |
| `cs -sync clone <url>` | Clone session from explicit URL |
| `cs <session> -s` | Alias for `-sync` |

## Auto-Sync

Enable automatic sync on session start/end:

```bash
cs my-session -sync auto on
```

When enabled:
- **Session start:** Pulls latest changes from remote
- **Session end:** Commits and pushes all changes

## Secrets Sync

Secrets are exported to `secrets.enc` (AES-256-CBC encrypted) and included in git.

**Important:** You must set `CS_SECRETS_PASSWORD` to the same value on all machines for secrets to sync correctly. Machine-derived passwords are not portable.

## What Gets Synced

- All markdown files (README.md, discoveries.md, changes.md, CLAUDE.md)
- Artifacts directory (scripts, configs, MANIFEST.json)
- Session log (logs/session.log)
- Encrypted secrets (secrets.enc)

**Excluded from sync:** archives/, lock files, OS/editor files

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
