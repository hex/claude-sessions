# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

When resuming this session, read the following files to restore context:

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/discoveries.md** - Findings, observations, and ideas
4. **.cs/changes.md** - Modifications and fixes made
5. **.cs/artifacts/MANIFEST.json** - List of tracked artifacts

## Artifact Auto-Tracking

Scripts and configuration files you create are **automatically saved to .cs/artifacts/**:

- Scripts: .sh, .bash, .zsh, .py, .js, .ts, .rb, .pl
- Configs: .conf, .config, .json, .yaml, .yml, .toml, .ini, .env

When you use the Write tool for these file types, they are automatically redirected to the .cs/artifacts/ directory and tracked in MANIFEST.json.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Start of session:** Fill in .cs/README.md objective and environment
2. **As you work:** Update .cs/discoveries.md with findings and .cs/changes.md with modifications
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Summary Command

When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a .cs/summary.md file synthesizing all documentation.

## Secure Secrets Handling

Sensitive data is automatically detected and stored securely (macOS Keychain, Windows Credential Manager, or encrypted file):

**Auto-detected patterns:**
- Files: .env, filenames containing key, secret, password, token, credential, auth
- Content: Variables like API_KEY, SECRET_TOKEN, PASSWORD, etc.

**What happens:**
1. Sensitive values are extracted and stored securely
2. The artifact file contains redacted placeholders
3. MANIFEST.json lists which secrets exist (not the values)

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** that wasn't auto-captured (unusual patterns, embedded credentials, etc.), use cs -secrets directly:
```bash
cs -secrets set <name> <value>     # Store manually
```

## Best Practices

- Document discoveries as you find them - don't wait until the end
- Use .cs/artifacts/ for any reusable scripts or configs
- .cs/changes.md is updated automatically when files are modified
- Run `/summary` at the end to create a cohesive record
- Never write raw API keys or passwords to artifact files - use cs -secrets
