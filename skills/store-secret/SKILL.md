---
name: store-secret
description: Store secrets shared in chat into the cs session secret store. PROACTIVE - invoke immediately when the user shares API keys, passwords, tokens, or other credentials in their message; do not wait to be asked.
---

The user's message may contain sensitive credentials. Your task is to store any real ones in the session secret store — but this skill fires proactively and can misfire on a docs snippet, a redacted example, or a key-shaped string that is not a secret, so confirm there is a real secret before storing anything.

## Prerequisites

This skill only works in a `cs` session. Check if `$CLAUDE_SESSION_NAME` environment variable exists:

```bash
echo $CLAUDE_SESSION_NAME
```

If empty, inform the user that secrets storage requires a cs session and skip storage. Then warn that the credential is now sitting in the conversation history, suggest they store it themselves in a secure secret store (a password manager or the OS credential store) and rotate it if it is sensitive. NEVER write the value to a project file as a fallback.

## Process

1. **Identify secrets** in the message that triggered this skill, or in the earlier message the user is pointing at ("store that key I pasted"). Look for:
   - API keys (patterns like `sk-...`, `AKIA...`, `ghp_...`, `xox...`)
   - Passwords or passphrases
   - Tokens (JWT, Bearer tokens, access tokens)
   - Database credentials or connection strings
   - Any key=value pairs where the key contains: key, secret, password, token, auth, credential

2. **Skip placeholders** - Do NOT store obvious placeholders like:
   - `YOUR_API_KEY`, `<token>`, `xxx`, `***`, `[redacted]`
   - Example values from documentation

   If nothing survives this filter — every candidate is a placeholder or an example — tell the user nothing was stored and stop. Do not strain to store a non-secret just because the skill fired.

3. **Determine key names** - Use descriptive names:
   - If the user named it: use their name (e.g., "my OpenAI key" → `OPENAI_KEY`)
   - If from key=value: use the key name
   - Otherwise: infer from context (e.g., "GitHub token" → `GITHUB_TOKEN`)

4. **Store each secret** — feed the value on **stdin**, never on the command
   line. A value passed as an argument is visible via `ps`.
   The Bash command itself must not contain the secret:
   - Run `cs -secrets list` first. `set` replaces an existing value silently
     (no diff, no prompt), so if the name you chose already exists, pick a more
     specific name or confirm with the user before overwriting.
   - Remove scratch files an interrupted earlier run left behind. Only files
     older than 60 minutes go: every cs session shares `$TMPDIR`, so a newer
     file may be another session's store in progress, and a store takes
     seconds. The trailing slash makes `find` enter macOS's `/tmp`, a
     symlink to `/private/tmp`:
     ```bash
     find "${TMPDIR:-/tmp}/" -maxdepth 1 -type f -name 'cs-secret.*' -user "$(id -u)" -mmin +60 -delete
     ```
   - Then, for each secret in turn, three calls:
     1. Create a fresh scratch file. It prints a new path each time:
        ```bash
        mktemp "${TMPDIR:-/tmp}/cs-secret.XXXXXX"
        ```
        The scratch file MUST live OUTSIDE the session workspace, as this one
        does: any Write inside the session directory is immediately snapshotted
        into the `refs/worktree/cs/session/<uuid>` autosave ref by the
        autosave-commits hook, and that snapshot survives the later `rm`.
     2. Write the raw value to exactly the path it printed with the **Write**
        tool, never a Bash heredoc, which puts it in the Bash command.
     3. Store and delete in **a single** Bash command, so the `rm` runs whatever
        the store does and the command still exits with the store's status.
        Put the printed path in `f`:
        ```bash
        f='<path mktemp printed>'; cs -secrets set KEY_NAME < "$f"; rc=$?; rm -f "$f"; exit $rc
        ```
     Never reuse a path for a second secret. If the Write failed or you
     skipped it, the file is empty and `set` refuses it rather than storing a
     stale value.

5. **Confirm storage** - Only confirm after the `set` command's output reports
   success (it prints `Stored secret: NAME`). If it errored (missing backend,
   session mismatch), report the failure and claim nothing stored — the scratch
   file is still deleted per step 4, but do not tell the user a secret was saved.
   On success, tell the user:
   - Which secrets were stored and under what names
   - How to retrieve: `cs -secrets get KEY_NAME`
   - How to list all: `cs -secrets list`
   - How to delete if unwanted: `cs -secrets delete KEY_NAME`

## Important

- Never echo or display the secret values in your response
- Store the exact value the user provided (preserve case, spacing, etc.)
- If multiple secrets are shared, store each one separately
- If you're unsure whether something is a real secret or an example, ask the user
