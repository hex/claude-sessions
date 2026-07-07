---
name: store-secret
description: Store secrets shared in chat into the cs session secret store. PROACTIVE - invoke immediately when the user shares API keys, passwords, tokens, or other credentials in their message; do not wait to be asked.
---

You detected that the user shared sensitive credentials. Your task is to store them in the session secret store.

## Prerequisites

This skill only works in a `cs` session. Check if `$CLAUDE_SESSION_NAME` environment variable exists:

```bash
echo $CLAUDE_SESSION_NAME
```

If empty, inform the user that secrets storage requires a cs session and skip storage.

## Process

1. **Identify secrets** in the user's most recent message. Look for:
   - API keys (patterns like `sk-...`, `AKIA...`, `ghp_...`, `xox...`)
   - Passwords or passphrases
   - Tokens (JWT, Bearer tokens, access tokens)
   - Database credentials or connection strings
   - Any key=value pairs where the key contains: key, secret, password, token, auth, credential

2. **Skip placeholders** - Do NOT store obvious placeholders like:
   - `YOUR_API_KEY`, `<token>`, `xxx`, `***`, `[redacted]`
   - Example values from documentation

3. **Determine key names** - Use descriptive names:
   - If the user named it: use their name (e.g., "my OpenAI key" → `OPENAI_KEY`)
   - If from key=value: use the key name
   - Otherwise: infer from context (e.g., "GitHub token" → `GITHUB_TOKEN`)

4. **Store each secret** — feed the value on **stdin**, never on the command
   line. A value passed as an argument is visible via `ps` and is captured
   verbatim by the bash-logger hook into `.cs/local/session.log`.
   The Bash command itself must not contain the secret:
   - Write the raw value to a scratch file with the **Write** tool (Write is not
     logged by bash-logger; a Bash heredoc would be). The scratch file MUST live
     OUTSIDE the session workspace (the harness scratchpad dir, or `mktemp` under
     `$TMPDIR`), e.g. `<scratchdir>/.secret` — any Write inside the session
     directory is immediately snapshotted into the `refs/worktree/cs/auto` autosave
     ref by the autosave-commits hook, and that snapshot survives the later `rm`
   - Store it by redirecting that file into stdin:
     ```bash
     cs -secrets set KEY_NAME < <scratchdir>/.secret
     ```
   - Delete the scratch file: `rm -f <scratchdir>/.secret`

5. **Confirm storage** - Tell the user:
   - Which secrets were stored and under what names
   - How to retrieve: `cs -secrets get KEY_NAME`
   - How to list all: `cs -secrets list`
   - How to delete if unwanted: `cs -secrets delete KEY_NAME`

## Important

- Never echo or display the secret values in your response
- Store the exact value the user provided (preserve case, spacing, etc.)
- If multiple secrets are shared, store each one separately
- If you're unsure whether something is a real secret or an example, ask the user
