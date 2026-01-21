# Secrets Handling

Sensitive data is automatically detected and stored securely instead of being written to artifact files in plaintext.

## Storage Backends

The `cs -secrets` command auto-detects the best available backend (in priority order):

| Priority | Backend | Storage Location | Cross-Machine Sync |
|----------|---------|------------------|-------------------|
| 1 | macOS Keychain | Login keychain | Via export-file |
| 2 | Windows Credential Manager | Windows Credential Store | Via export-file |
| 3 | Encrypted file | `~/.cs-secrets/<session>.enc` | Manual |

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

There are two ways to sync secrets: **age encryption** (recommended) or **password-based encryption** (legacy).

### Age Encryption (Recommended)

[age](https://github.com/FiloSottile/age) provides modern public-key encryption - no shared password needed:

```bash
# Initialize age (auto-downloads if needed)
cs -secrets age init

# Show your public key (share this with collaborators)
cs -secrets age pubkey

# Export secrets (auto-configures age on first use)
cs -secrets export-file

# Import on another machine (after adding your pubkey as recipient)
cs -secrets import-file
```

**Adding collaborators:**

```bash
# Add a collaborator's public key
cs -secrets age add colleague.pub

# Or add a raw key directly
cs -secrets age add age1abc123...

# List who can decrypt
cs -secrets age list

# Revoke access (re-export to re-encrypt without them)
cs -secrets age remove colleague
```

**How it works:**
- Each machine has a keypair stored in `~/.cs-secrets/age.key`
- Session recipients are stored in `<session>/age-recipients/*.pub`
- Secrets are encrypted to all recipients' public keys
- Anyone with their private key + being in recipients can decrypt

### Password-Based Encryption (Legacy)

For simpler setups or when age isn't available:

```bash
# Set the same password on all machines
export CS_SECRETS_PASSWORD="your-secure-password"

# Export secrets to encrypted file
cs -secrets export-file

# Import secrets from encrypted file
cs -secrets import-file

# Import and overwrite existing secrets
cs -secrets import-file --replace
```

**Sync files:**
- `secrets.age` - age-encrypted (preferred when recipients configured)
- `secrets.enc` - password-encrypted (legacy, requires `CS_SECRETS_PASSWORD`)

Both files are automatically included in git sync. See [Sync](sync.md) for details.

## Migrating Between Backends

Move secrets from one storage backend to another:

```bash
# Migrate from current backend to encrypted file
cs -secrets migrate-backend encrypted

# Migrate from keychain to encrypted file
cs -secrets migrate-backend encrypted --from keychain

# Migrate and delete from source after successful migration
cs -secrets migrate-backend encrypted --from keychain --delete-source
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

## Age Commands Reference

```bash
# Initialize keypair (auto-downloads age binary if needed)
cs -secrets age init

# Print your public key for sharing
cs -secrets age pubkey

# Add recipient to current session
cs -secrets age add <file.pub|age1...>

# List recipients who can decrypt session secrets
cs -secrets age list

# Remove a recipient (re-export to apply)
cs -secrets age remove <name>
```

## Environment Variables

- `CLAUDE_SESSION_NAME` - Current session (set automatically by `cs`)
- `CS_SECRETS_BACKEND` - Force a specific backend (`keychain`, `credential`, `encrypted`)
- `CS_SECRETS_PASSWORD` - Master password for legacy sync (only needed if not using age)
