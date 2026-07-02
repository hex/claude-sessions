# Secrets Handling

Sensitive data is automatically detected and stored securely instead of being written to artifact files in plaintext.

## Storage Backends

The `cs -secrets` command auto-detects the best available backend (in priority order):

| Priority | Backend | Storage Location | Cross-Machine Sync |
|----------|---------|------------------|-------------------|
| 1 | macOS Keychain | Login keychain | Via export-file |
| 2 | Encrypted file | `~/.cs-secrets/<session>.enc` | Manual |

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
- Session recipients are stored in `<session>/.cs/age-recipients/*.pub`
- Secrets are encrypted to all recipients' public keys
- Each machine writes its own sync file (see [Per-machine sync files](#per-machine-sync-files) below)
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

### Per-machine sync files

Sessions are shared between machines via git, so the sync files live under `.cs/`
and are committed. To keep two machines from clobbering each other, **each machine
writes its own sync file**, named after its hostname-derived machine id:

- `.cs/secrets.<machine-id>.age` - age-encrypted (preferred when recipients configured)
- `.cs/secrets.<machine-id>.enc` - password-encrypted (requires `CS_SECRETS_PASSWORD`)

The `<machine-id>` is `${USER}@<short-hostname>` (the same id used to name age
recipients under `.cs/age-recipients/`).

Because every machine exports to a distinct file, concurrent exports produce
*added* files rather than competing edits to one shared file — git merges
additions of different paths without conflict, and no machine's secrets get
silently dropped.

`export-file` also **skips the write when nothing changed**: it decrypts the
existing file and compares the plaintext, so re-exporting an unchanged store
does not churn the file's bytes (each encryption pass would otherwise emit fresh
ciphertext from a random salt / ephemeral key).

`import-file` (with no path argument) **merges every sync file it can decrypt** —
all `.cs/secrets.*.age` / `.cs/secrets.*.enc` from every machine, plus the legacy
unsuffixed `.cs/secrets.age` / `.cs/secrets.enc` (a one-shot migration for
sessions created before per-machine naming). Files it cannot decrypt (another
machine's age key, a different password) are skipped, not fatal. Per-machine
files win key collisions over the legacy files; local secrets are preserved
unless you pass `--replace`.

Passing an explicit path (`cs -secrets import-file <file>`) imports just that
one file, as before.

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
- `CS_SECRETS_SESSION` - Overrides the session namespace; worktree task sessions export it so their secrets land in the base session's store, and `cs <name> -secrets` sets it so an explicit target outranks ambient env
- `CS_SECRETS_BACKEND` - Force a specific backend (`keychain` or `encrypted`)
- `CS_SECRETS_PASSWORD` - Master password for legacy sync (only needed if not using age)
