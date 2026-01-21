# Secrets Handling

Sensitive data is automatically detected and stored securely instead of being written to artifact files in plaintext.

## Storage Backends

The `cs -secrets` command auto-detects the best available backend (in priority order):

| Priority | Backend | Storage Location | Cross-Machine Sync |
|----------|---------|------------------|-------------------|
| 1 | Bitwarden Secrets Manager | Bitwarden cloud (project per session) | Yes |
| 2 | macOS Keychain | Login keychain | No |
| 3 | Windows Credential Manager | Windows Credential Store | No |
| 4 | Encrypted file | `~/.cs-secrets/<session>.enc` | Manual |

**Bitwarden Secrets Manager Setup:**

Bitwarden Secrets Manager provides cross-machine synchronization via Bitwarden's cloud. Each cs session gets its own Bitwarden project (e.g., session `aws-api` maps to project `cs-aws-api`).

Prerequisites:
- `bws` CLI installed: https://bitwarden.com/help/secrets-manager-cli/
- `jq` installed for JSON parsing
- Access token configured via `bws config`

```bash
# Install bws (macOS)
brew install bitwarden/tap/bws

# Configure your access token
bws config
```

Once configured, Bitwarden becomes the default backend automatically. Override with `CS_SECRETS_BACKEND=keychain` if needed.

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

## Auto-Detection

Secrets are detected and stored automatically in two ways:

**1. File-based detection** (via `artifact-tracker.sh` hook):

When writing files, secrets are detected by:
- File type: `.env` files
- Filename patterns: Files containing `key`, `secret`, `password`, `token`, `credential`, `auth`, `apikey`, `api_key`
- Content patterns: Variables like `API_KEY=`, `SECRET_TOKEN=`, `PASSWORD=`, etc.

**2. Conversational detection** (via `store-secret` skill):

When you share secrets in chat, Claude automatically invokes the `store-secret` skill to capture them:
- "Here's my OpenAI key: sk-abc123..."
- "The password is hunter2"
- "Use this token: ghp_xxxx"

Claude identifies appropriate key names and stores secrets securely, then confirms what was stored.

## What Happens

When sensitive data is detected:
1. The actual values are extracted and stored securely
2. The artifact file is written with redacted placeholders:
   ```
   API_KEY=[REDACTED: stored in keychain as API_KEY]
   ```
3. MANIFEST.json records which secrets exist (not the values)

## Using cs -secrets

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

# Delete ALL secrets for a session
cs -secrets purge

# Export all secrets as environment variables
eval "$(cs -secrets export)"

# Use with a specific session
cs -secrets --session my-session list
```

## Syncing Secrets Across Machines

Secrets can be exported to an encrypted file for git sync:

```bash
# Export secrets to encrypted file (requires CS_SECRETS_PASSWORD)
cs -secrets export-file

# Import secrets from encrypted file
cs -secrets import-file

# Import and overwrite existing secrets
cs -secrets import-file --replace
```

The encrypted file (`secrets.enc`) is automatically included in git sync. See [Sync](sync.md) for details.

## Migrating Between Backends

Move secrets from one storage backend to another:

```bash
# Migrate from current backend to bitwarden
cs -secrets migrate-backend bitwarden

# Migrate from keychain to bitwarden (when bitwarden is already active)
cs -secrets migrate-backend bitwarden --from keychain

# Migrate and delete from source after successful migration
cs -secrets migrate-backend bitwarden --from keychain --delete-source
```

## Migrating Existing Secrets

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

## Environment Variables

- `CLAUDE_SESSION_NAME` - Current session (set automatically by `cs`)
- `CS_SECRETS_BACKEND` - Force a specific backend (`bitwarden`, `keychain`, `credential`, `encrypted`)
- `CS_SECRETS_PASSWORD` - Optional master password for encrypted backend (overrides auto-derived key)
