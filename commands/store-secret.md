PROACTIVE: Invoke immediately when the user shares API keys, passwords, tokens, credentials, or secrets in their message. Look for patterns like "my API key is...", "password: ...", "TOKEN=...", or any sensitive credential. Do not wait to be asked.

You detected that the user shared sensitive credentials. Your task is to securely store them in the session keychain.

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

4. **Store each secret**:
   ```bash
   cs -secrets set KEY_NAME "the-actual-value"
   ```

5. **Confirm storage** - Tell the user:
   - Which secrets were stored and under what names
   - How to retrieve: `cs -secrets get KEY_NAME`
   - How to list all: `cs -secrets list`
   - How to delete if unwanted: `cs -secrets delete KEY_NAME`

## Example

User says: "Here's my OpenAI API key: sk-abc123def456"

You would:
```bash
cs -secrets set OPENAI_API_KEY "sk-abc123def456"
```

Then confirm: "I've stored your OpenAI API key as `OPENAI_API_KEY` in the session keychain."

## Important

- Never echo or display the secret values in your response
- Store the exact value the user provided (preserve case, spacing, etc.)
- If multiple secrets are shared, store each one separately
- If you're unsure whether something is a real secret or an example, ask the user
