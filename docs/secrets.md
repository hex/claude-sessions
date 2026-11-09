# Secrets Handling

Store sensitive data (API keys, tokens, passwords) in a secure backend instead of writing it into project files in plaintext. Pipe the value on stdin (the recommended path) so it never appears in argv; a value passed on the command line is honoured but warned against, since it is visible via `ps`.

A value taken on stdin stays off argv inside `cs -secrets` as well: the Keychain backend hands it to `security -i` on stdin, and the encrypted backend and sync files give values, the store key and `CS_SECRETS_PASSWORD` to `openssl` and `jq` through stdin or an environment variable set for that one command. Another user's `ps` cannot read either channel; processes running as your own user (and root) can read a process's environment.

## Storage Backends

The `cs -secrets` command auto-detects the best available backend for the platform:

| Backend | Platform | Storage Location | Cross-Machine Sync |
|---------|----------|------------------|-------------------|
| macOS Keychain | macOS | Login keychain | Via export-file |
| Encrypted file | Linux, WSL, and the fallback wherever no keychain is available | `~/.cs-secrets/<session>.enc` | Manual / age |

Override the choice with `CS_SECRETS_BACKEND=keychain|encrypted`.

The Keychain backend has a value limit. cs hands a value to `security` on one command line, so it refuses a value over about 2000 bytes (the exact number depends on the user, session and secret name) and names the limit. Store larger values with the encrypted backend.

**Encrypted File Backend:**

The encrypted file backend uses AES-256-CBC with PBKDF2 key derivation (100,000 iterations). The default key is derived from `USER@hostname` plus a random salt stored in `~/.cs-secrets/.salt`, beside the ciphertext. This provides protection against:
- Casual snooping
- Accidental git commits of the secrets directory
- Backup/sync services copying plaintext credentials

It does not protect against someone who holds a copy of `~/.cs-secrets` (a backup, a synced home directory): the salt is in the copy and the user and host names are guessable, so the default key is recoverable from the copy alone. Set `CS_SECRETS_PASSWORD` to use an explicit master password instead of the derived key, or use the Keychain backend on macOS.

Check which backend is active: `cs -secrets backend`

## Conversational capture

When you share a secret in chat, Claude invokes the `store-secret` skill to
capture it:
- "Here's my OpenAI key: sk-abc123..."
- "The password is hunter2"
- "Use this token: ghp_xxxx"

Claude picks an appropriate key name and writes the value to a fresh scratch file
outside the session directory. One command then redirects that file into
`cs -secrets set <name>` on stdin (never on argv) and removes it, so an interrupted
store leaves no scratch file behind. Claude then confirms what it stored.

## Using cs -secrets

The `cs -secrets` command manages session secrets:

```bash
# Check which storage backend is being used
cs -secrets backend

# List all secrets for current session
cs -secrets list

# Get a specific secret value
cs -secrets get API_KEY

# Store a secret manually (value read from stdin, never argv)
printf '%s' "secret-value" | cs -secrets set my_secret

# At a terminal, set prompts for the value without echoing it
cs -secrets set my_secret

# Delete a secret
cs -secrets rm API_KEY

# Delete ALL secrets for a session
cs -secrets purge

# Export all secrets as environment variables. Each is namespaced as
# CS_SECRET_<NAME> (api_key becomes CS_SECRET_API_KEY), so a secret can never
# land on PATH, PROMPT_COMMAND or another variable the shell acts on.
eval "$(cs -secrets export)"

# Use with a specific session
cs -secrets --session my-session list
```

`set` refuses a value that is a placeholder rather than a secret: anything starting with `[REDACTED:`, a run of asterisks, `<redacted>`, or `YOUR_API_KEY`. Storing one would replace a working secret with junk that breaks whatever reads it later.

`set`, `rm`, `import-file` and `migrate-backend` refuse a session name the sessions root does not have (`No session named '<name>' in <root>`), on both backends: a value stored under a removed session's name, or under the old name of a renamed one, is a value no session reads. `purge` takes such a name: purging is how you remove the secrets a removed session left. Every command that takes a session, `purge` included, refuses a name that is a path (`.`, `..`, or a name holding `/` or `\`) with the same message.

From inside a cs session, a command that writes another session's secrets (`set`, `rm`, `purge`, `rename`, `import-file`, `migrate`, `migrate-backend`, `export-file`, `age add` and `age remove`) stops with an error while that session's claude is running: `session <caller> cannot change the secrets of session <target> while it is live (pid <pid>); --force does not override that from another session. Close <target> first.` `rename` writes both names' secrets, so it stops when either the old or the new name is live. This holds for `cs <target> -secrets`, `cs -secrets --session <target>` and `cs-secrets -s <target>` alike. The same holds while one of the target's features (`<target>@<task>`) is running, since a base's secrets are its features' too: `session <caller> cannot change the secrets of session <target> while its feature <target>@<task> is live (pid <pid>); ...`. Liveness is the pid in a session's `.cs/session.lock`: its text, surrounding whitespace removed, is a decimal number from 1 to 2147483647 that names a running process. A feature session writes its base's secrets, since they are its own, while the base or the feature itself is running. While a sibling feature (`<target>@<other-task>`) is running, the feature's `set` still adds a name the base does not hold yet, and every other write waits for the sibling. A name counts as held when a stored one exports as the same `CS_SECRET_<NAME>` variable, so `api-key` beside a stored `api_key` waits too, and the refusal ends `A feature adds only a name <target> does not hold yet while another feature runs; <target> already stores <name>, exported as CS_SECRET_<NAME>.` A `set` waits as well when cs-secrets cannot read the base's stored names. Only the base writes them whatever its features are doing. Reads (`get`, `list`, `export`), an idle or closed session, and a terminal outside every session are not affected.

cs-secrets refuses a write addressed to a feature session itself (`--session <base>@<task>` or `-s <base>@<task>`) before it writes, locks or creates anything, with `<base>@<task> is a feature of session <base>, and a feature uses its base's secrets and age recipients. Run it with --session <base>.` The one exception is `purge`. It only removes, so it clears a store, Keychain entries or a pin list kept under the feature's own name, and it creates nothing. `cs <base>@<task> -secrets` names the base, so its writes are not affected. Reads addressed to a feature (`get`, `list`, `export`, `age list`) change nothing and find only what the stores hold under the feature's own name.

cs-secrets refuses a word starting with `--` that is none of its options, such as `--session=other`, before any command runs: `unknown option: <word>`, with the word printed plain (`--session_other`). Give an option's value after a space (`--session other`). It takes the value after `-s`, `--session` or `--from`, and `rename`'s new name, as written. A secret value given on the command line cannot start with `--`; give it on stdin.

`set`, `rm`, `purge` and the stores `import-file`, `migrate` and `migrate-backend` make hold one lock per session while they write, `<sessions root>/.secrets-lock.<session>`. It lives in the sessions root so that a Keychain write never creates `~/.cs-secrets`. A write that cannot take it within `CS_SECRETS_LOCK_TIMEOUT` seconds fails and names the file. On Ctrl-C or `kill`, the command lets the `security` or `openssl` call in flight finish before it releases the lock and exits, so the Keychain may already hold the value when the command exits with an error.

### Renaming a session

cs-secrets keys every store by the session's name: the Keychain entries `cs:<session>:<name>`, the encrypted store `~/.cs-secrets/<session>.enc`, and the age pins and digest record under `~/.cs-secrets/sessions/<session>/`. The picker's rename moves them with the session by running `rename` after it moves the directory. If `rename` refuses, fails, or gets a Ctrl-C or `kill`, it first puts back every value it moved, and the picker moves the directory and any staged spawn files back: the session keeps its old name and every secret reads under it. If `rename` cannot put a value back, or `kill -9` ends it, it keeps its marker; the session then keeps the new name and the picker shows ``Rename incomplete: run `cs -secrets --session <old> rename <new>` ``; that command finishes the move.

```bash
# After the session directory old-name was renamed to new-name
cs -secrets --session old-name rename new-name
```

`rename` reads the new name, its last argument, literally, so a session named `purge` or `--redact` is a name here, not a command or an option. Options such as `--session` go before `rename`; `rename` refuses a word after the new name (`rename takes one session name; unexpected: <words>`).

`rename` refuses while the sessions root still has the old name, when it does not have the new one, when either name is a feature session (`<base>@<task>`), which keeps its base's secrets, and when the new name already has Keychain secrets, an encrypted store or age state. It never merges or overwrites. It takes the same per-session locks as `set`, `rm`, `purge`, `export-file`, `age add` and `age remove`, for both names, so a write that lands during a rename moves with the session or waits for the move. An `age add`, `age remove` or `export-file` for the old name that waited then refuses it, since that session no longer exists. On a Mac it reads and moves Keychain entries on either backend, since the Keychain keeps what a session stored there after you switch to the encrypted backend, and it refuses when it cannot read the Keychain. Elsewhere it reads the Keychain only on the Keychain backend.

A move that fails, or gets a Ctrl-C or `kill`, puts back what it moved and exits with an error. Once every value is under the new name, neither Ctrl-C, `kill` nor a lock file it cannot remove stops it: it finishes and exits 0, names any such lock file on stderr for you to remove, and the picker never moves the directory back away from its secrets. A move that `kill -9` ends, or that cannot put a value back, still loses no secret. `rename` stores every Keychain entry under the new name and reads it back before it deletes any old entry, and links each file under the new name before it unlinks the old one. `~/.cs-secrets/.rename.<old>` records the move until it finishes, so running the same command again completes it. While that file exists, `rename` refuses to move the old name to any other name and prints the command that finishes the first move. `rename` reads the file only once it holds both names' write locks, so a second `rename` that waited on the first finds it.

### No session name?

Run interactively with no session name and `cs -secrets` lists your
sessions and asks which one to use — plain Enter accepts the default when
you are standing inside a session directory (a worktree directory defaults
to its base session). Archived sessions stay out of the list; reach them
with `--session` or by running from inside their directory. Worktree
sessions never appear — they have no secrets of their own; their secrets
live in the base session's store. Scripts and hooks are unaffected: without
a TTY the command still fails with `No session specified`.

## Syncing Secrets Across Machines

There are two ways to sync secrets: **age encryption** (recommended) or **password-based encryption** (legacy).

### Age Encryption (Recommended)

[age](https://github.com/FiloSottile/age) provides modern public-key encryption - no shared password needed:

```bash
# Create this machine's key (downloads age if needed; needs ssh-keygen)
cs -secrets age init

# Show your public key (share this with collaborators)
cs -secrets age pubkey

# Export secrets (auto-configures age on first use)
cs -secrets export-file

# Import on another machine. It takes the files signed by keys you pinned
# there with `age add`
cs -secrets import-file
```

**Adding collaborators:**

```bash
# Add a collaborator's public key
cs -secrets age add colleague.pub

# Or add a raw key directly (quote an ssh key: it has a space in it)
cs -secrets age add "ssh-ed25519 AAAAC3..."
cs -secrets age add age1abc123...

# List who can decrypt
cs -secrets age list

# Revoke access (the next export re-encrypts without them)
cs -secrets age remove colleague
cs -secrets export-file
```

**How it works:**
- Each machine has one ssh-ed25519 key pair, `~/.cs-secrets/id_ed25519` and
  `id_ed25519.pub`. cs makes it with `ssh-keygen` on the first `age init` or
  export, with no passphrase (exports run unattended) and mode 600. cs never
  uses one of your `~/.ssh` keys. age encrypts to it and decrypts with it,
  and `ssh-keygen` signs with it, so making the key and signing need
  `ssh-keygen` from OpenSSH 8.0 or later
- Session recipients are stored in `<session>/.cs/age-recipients/*.pub`. A
  recipient is an `ssh-ed25519` key or an `age1...` key. cs stores an ssh key
  as its type and key, without the comment, so a copy with another comment is
  the same recipient
- An export puts this machine's key in `age-recipients/<machine-id>.pub` when no
  recipient file holds it yet, in a new session and in one that already has
  recipients. Other machines encrypt to that file and check this machine's
  signatures against it. When `<machine-id>.pub` already holds a different key
  (two machines with one user and host name, or a key pair you made again),
  the export stops and names the file
- Each machine encrypts only to the recipients it has pinned in
  `~/.cs-secrets/sessions/<session>/age-trusted`; `age add` pins a key, `age remove`
  unpins it. A pin means two things: encrypt to this key, and accept sync
  files this key signed. The pin list, the per-file recipient digests (`age-exported-to`)
  and their lock (`.age.lock`) live under `~/.cs-secrets`, outside the checkout:
  `.cs/local` is gitignored, but `git add -f` is not, and a pushed pin list must
  never be read
- Removing a base session (`cs -rm <name>`, or the picker's delete, single or
  batch) removes `~/.cs-secrets/sessions/<name>/` with it and prints the path, so
  a later session under the same name starts with no pins. Removing a feature
  session (`base@task`) or an adopted session's link leaves that state alone:
  a feature session uses its base's secrets. Neither touches the stored secrets
  in the Keychain or the encrypted store; `cs -secrets purge` removes those
- `age add` needs the age binary and never downloads one; without it, it says to run
  `cs -secrets age init`. It asks age whether it can encrypt to the key before it writes or
  pins it, and refuses a key file whose name already belongs to a recipient with a different
  key. A raw key gets the name `recipient-<seconds>`, with `-2`, `-3` added while another
  recipient has that name; a raw key some recipient file already holds is that recipient.
  It refuses a key file whose name without `.pub` starts with a `.`, a recipient that
  `age list`, every export and `age remove` would skip
- `age remove` refuses a recipient name with a `/`, a control character or a leading
  `.`, and refuses a link at `.cs`, `.cs/age-recipients` or the recipient file, naming
  it; either way it removes nothing
- `age add`, `age remove`, `export-file` and `import-file` refuse a session name the sessions
  root does not have (`No session named '<name>' in <root>`), so a removed or
  mistyped name never gets a directory or a pin list. A command already past
  that check when `cs -rm` removes the session can still write its files back
- A `.pub` that arrives some other way, such as a `git pull` of someone's push,
  makes `export-file` refuse and print the `age add` command that pins it; pin it
  only if you trust the key, otherwise delete the file
- Nothing is pinned without an `age add` on this machine, except this
  machine's own key, which is pinned by its content whenever it is a
  recipient. A machine that exported before pinning existed and a fresh clone
  both start with no pin list: the export refuses and lists each `.pub` with
  the `age add` command that pins it
- `export-file`, `age add` and `age remove` hold one per-session lock on every
  backend, from the recipient snapshot through the encrypt, the rename and the
  digest record
- Each machine writes its own sync file (see [Per-machine sync files](#per-machine-sync-files) below)
- Anyone with their private key + being in recipients can decrypt

### Signed sync files

age decides who can read a sync file. It says nothing about who wrote it:
`.cs/age-recipients/` is in git, so anyone who can push to the session's
repository can encrypt a file to your public key and push it. That is why
each machine signs what it exports, and an import checks the signature.

- `export-file` signs the encrypted file with this machine's key and writes
  the signature beside it, `.cs/secrets.<machine-id>.age.sig`. Commit both.
  An export to a path you name writes `<path>.sig`
- The signature names the session, so a file signed for one session is not
  accepted in another
- `import-file` takes an age file only when the key that signed it is in a
  file under `.cs/age-recipients/` and you pinned that key on this machine.
  The file's name counts for nothing, a file under this machine's own name
  included
- It skips every file it does not take, with a line that names the file and
  says why: it has no signature, its signer is in `.cs/age-recipients/` but
  not pinned (the line gives the `age add` to run), or the signature does not
  match (the file changed after signing, the signature is for another
  session, or its signer has no key in the session)
- It reads neither the file nor its signature through a symbolic link, and
  skips a file that has a link at either path
- `import-file --allow-unsigned` also takes age files that have no signature.
  Sync files written before cs signed them have none, and that is what the
  flag is for. It does not cover a file whose signature does not match: the
  import skips that one too
- `import-file <file>` checks the named file the same way and refuses it
  (exit 1) instead of skipping it
- Password files (`.enc`) are not signed. Whoever has the password can write
  one, and that is that format's trust
- Without `ssh-keygen` an import cannot check signatures: it skips each signed
  age file by name and still imports password files
- A signature does not expire. Someone who can push can put back an older
  file that one of your machines signed, and the import takes it. A merge
  import only adds the secrets you do not have; `--replace` would bring the
  old values back

### Upgrading from age keys

Before this, each machine had an age key pair (`~/.cs-secrets/age.key`) and
sync files were not signed. A machine moves to its ssh key on its first
export after the upgrade:

1. `cs -secrets export-file` makes `~/.cs-secrets/id_ed25519`, rewrites this
   machine's recipient file to the ssh key, pins it, encrypts again and
   signs. It prints the `age add` line the other machines need
2. Commit and push `.cs/age-recipients/`, the sync file and its `.sig`
3. On each other machine, pull. Its next export refuses, because the changed
   `.pub` is a key it has not pinned, and prints the same `age add` line. Run
   it once you know the change is yours

Every machine in the session needs the upgrade: an older cs does not accept
an ssh key in `age add`. cs keeps `age.key` and still decrypts with it, so
files other machines encrypted to the old key stay readable. Until a machine
has exported with the new cs its sync file has no signature, and the others
import it only with `--allow-unsigned`.

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

- `.cs/secrets.<machine-id>.age` - age-encrypted, what a machine with age writes
- `.cs/secrets.<machine-id>.age.sig` - this machine's signature over that file
- `.cs/secrets.<machine-id>.enc` - password-encrypted (requires `CS_SECRETS_PASSWORD`),
  what a machine without age writes. An export that age cannot encrypt fails with age's
  error; it never falls back to this file

The `<machine-id>` is `${USER}@<short-hostname>` (the same id used to name age
recipients under `.cs/age-recipients/`).

Because every machine exports to a distinct file, concurrent exports produce
*added* files rather than competing edits to one shared file — git merges
additions of different paths without conflict, and no machine's secrets get
silently dropped.

`export-file` also **skips the write when nothing changed**: it decrypts the
existing file and compares the plaintext, so re-exporting an unchanged store
does not churn the file's bytes (each encryption pass would otherwise emit fresh
ciphertext from a random salt / ephemeral key). For an age file, "nothing
changed" also covers the recipients: the machine records the recipient set it
encrypted each file to (`~/.cs-secrets/sessions/<session>/age-exported-to`), and any add or removal
makes the next export re-encrypt even when no secret changed. A signature
that is missing or no longer matches the file does the same. A removed
recipient keeps reading other machines' sync files until those machines
export, and every copy already in git history.

`import-file` (with no path argument) **merges every sync file it trusts and
can decrypt**: all `.cs/secrets.*.age` / `.cs/secrets.*.enc` from every
machine, plus the legacy unsuffixed `.cs/secrets.age` / `.cs/secrets.enc` (a
one-shot migration for sessions created before per-machine naming). An age
file has to pass the signature check in [Signed sync files](#signed-sync-files).
Files it cannot decrypt (another machine's key, a different password) are
skipped, not fatal. Per-machine files win key collisions over the legacy
files; local secrets are preserved unless you pass `--replace`.

Passing an explicit path (`cs -secrets import-file <file>`) imports just that
one file.

`import-file` reads no sync file through a symbolic link: it skips a sync file
that is a link, whatever its format, and refuses one you name. It refuses a
session whose `.cs` leads outside the session, a file you name whose path
passes through a session when its directory leads out of that session, and a
file whose directory is the local store, `~/.cs-secrets`.

The names of sync files and recipient files come from the session's
repository, so cs-secrets prints each one with every character other than
letters, digits and `._/@-` replaced by `_`, cut at 160 characters: in the
import's skip lines, the export's list of unpinned keys, `age list` and
`age add`. The key preview `age list` shows, and the key `age add` reports
when it refuses to replace a recipient, have their control characters removed.

An import checks every name before it stores any. It stores nothing and
exits 1 when a name is not a valid secret name (a carriage return or another
control character in it counts), or when two names would become one variable
in `cs -secrets export`: `api-key` beside `api_key`, whether both come from
the sync files or one is already stored. The message names both. `import-file`
also refuses a session name the sessions root does not have.

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

A secret that does not reach the target prints the store's reason, such as the Keychain value limit, then `Failed: <name>`. `--delete-source` deletes from the source only when every secret migrated.

## Migrating Existing Secrets

Sessions created before the secrets feature may hold plaintext secrets in the retired `.cs/artifacts/` directory (cs no longer creates it, but old sessions still have it). Use the migrate command to move them to secure storage:

```bash
# Scan the legacy .cs/artifacts/ files and migrate secrets (keeps originals)
cs -secrets migrate

# Migrate and redact plaintext values in place
cs -secrets migrate --redact
```

The migrate command:
1. Scans the legacy `.cs/artifacts/` files in the session
2. Detects KEY=value patterns with sensitive key names
3. Stores values in the active backend
4. Optionally replaces plaintext with `[REDACTED: stored in keychain as KEY]`

A key name is sensitive when one of its name segments says so. migrate reads only a name made of letters, digits and `_`, and leaves a `KEY=value` or `KEY: value` line whose name holds `-` alone. It splits the name on `_`, where a lower-case letter meets an upper-case one, before the last capital of an upper-case run that a lower-case letter follows, and where a letter meets a digit or a digit meets a letter, so `dbPassword` is `db` and `password`, `AWSSecretKey` is `aws`, `secret` and `key`, `API_KEY2` is `api`, `key` and `2`, and `S3SECRET` is `s`, `3` and `secret`, and it compares each segment lower-cased. `secret`, `password`, `passwd`, `token`, `credential`, `credentials`, `apikey`, `passphrase` and `authorization` mark a secret as a segment or at a segment's end (`DB_PASSWORD`, `PGPASSWORD`, `NGROK_AUTHTOKEN`); `pat`, `cred` and `creds` only as a whole segment (`GITHUB_PAT`, `AWS_CREDS`; not `pattern`); `auth`, `pass` and `pwd` only as the whole last segment (`BASIC_AUTH`, `OAuth`, `DB_PASS`, `MYSQL_PWD`; not `SSH_AUTH_SOCK`, `OAUTH`, `PASS_RATE` or `passThrough`), and the whole name `PWD`, the shell's working directory, never; `key` right after `api`, `access` or `private` (`OPENAI_API_KEY`, `AWS_ACCESS_KEY_ID`, `PRIVATE_KEY`) or as the last segment or its end (`APP_KEY`, `encryptionKey`, `TS_AUTHKEY`, `KEY`). Trailing segments that are digits alone or `v` and digits do not count when migrate finds the last segment, so `APP_KEY2`, `SSH_KEY_1`, `MASTER_KEY_V2` and `BASIC_AUTH_2` mark a secret and `KEY_FILE`, `SSH_KEY_PATH` and `AUTH_HEADER` do not. A secret word at the start of or inside a longer segment (`author`, `passwordless`, `tokenizers`, `KEYTIMEOUT`), a plural (`keys`, `MAX_TOKENS`, `CS_SECRETS_BACKEND`) and `key` before another segment (`KEY_NUM`, `key_index`) mark none. A value that is only whitespace, bare or inside one pair of matching quotes (`KEY: " "`, `PASSWORD: ' '`, an empty `""`), is never stored or redacted, whatever the name; a lone quote or a mismatched pair (`"1'`) is a value. A name that is sensitive only through plain `key` names a lookup key, not a credential, when its value, with surrounding whitespace, a trailing CR and one pair of matching quotes stripped, is `true`, `false`, `null` (in any case) or digits alone: migrate leaves `isKey=true`, `FILE_KEY=9001` and `rowKey: '1'` alone and stores and redacts `PASSWORD=123456` and `SECRETKEY=123456` (a last segment that is or ends in `secretkey`, `accesskey`, `privatekey` or `authkey` counts as a strong word), each as written.

`--redact` replaces each value as text, in the shell, so no value reaches another process's command line. It replaces the longest value first and puts the markers in only after it has replaced every value, so a value that holds a shorter one leaves no tail and no value can match inside a marker. The replacement reaches every place the file holds a value, a short one included: it replaces a value `as` inside `password` and in prose on other lines too. To mark each value's place while it works, `--redact` uses two control bytes the file does not hold; a file that holds every control byte from `\002` to `\037` but tab, line feed, vertical tab, form feed and carriage return stops the migration before it stores anything from that file.

## Age Commands Reference

```bash
# Create this machine's ssh-ed25519 key (downloads the age binary if
# needed; needs ssh-keygen)
cs -secrets age init

# Print your public key for sharing
cs -secrets age pubkey

# Add recipient to current session and pin it
cs -secrets age add <file.pub|"ssh-ed25519 ..."|age1...>

# List recipients who can decrypt session secrets
cs -secrets age list

# Remove a recipient (re-export to apply)
cs -secrets age remove <name>
```

## Environment Variables

- `CLAUDE_SESSION_NAME` - Current session (set automatically by `cs`)
- `CS_SECRETS_SESSION` - Overrides the session namespace; worktree feature sessions export it so their secrets land in the base session's store, and `cs <name> -secrets` sets it so an explicit target outranks ambient env. A base session's launch unsets it, so its claude never inherits another session's target from the shell that ran `cs`
- `CS_SECRETS_CALLER` - The session the `cs -secrets` arms ran in, empty outside every session; set by `cs` because `cs <name> -secrets` puts the target in `CLAUDE_SESSION_NAME`. cs-secrets reads it to refuse writes to another live session's secrets, and falls back to `CLAUDE_SESSION_NAME` when cs did not set it. Every launch unsets it
- `CS_SECRETS_BACKEND` - Force a specific backend (`keychain` or `encrypted`)
- `CS_SECRETS_PASSWORD` - Master password for legacy sync (only needed if not using age)
- `CS_SECRETS_LOCK_TIMEOUT` - Seconds to wait for a secrets lock (the write lock, the encrypted store's lock, the age lock) before giving up (default 10; a value that is not a positive whole number uses the default)
