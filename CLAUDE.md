# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

When resuming this session, read the following files to restore context:

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/discoveries.md** - Findings, observations, and ideas
4. **.cs/discoveries.compact.md** - If exists, condensed older findings
5. **.cs/artifacts/MANIFEST.json** - List of tracked artifacts

Note: When discoveries.md exceeds its size budget (default 60KB, override via
CS_DISCOVERIES_MAX_SIZE env var), older entries are summarized into
.cs/discoveries.compact.md to keep context lean.

## Artifact Auto-Tracking

Scripts and configuration files you create are **automatically saved to .cs/artifacts/**:

- Scripts: .sh, .bash, .zsh, .py, .js, .ts, .rb, .pl
- Configs: .conf, .config, .json, .yaml, .yml, .toml, .ini, .env

When you use the Write tool for these file types, they are automatically redirected to the .cs/artifacts/ directory and tracked in MANIFEST.json.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Start of session:** Fill in .cs/README.md objective and environment
2. **As you work:** Update .cs/discoveries.md with findings
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Summary Command

When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a .cs/summary.md file synthesizing all documentation.

## Secure Secrets Handling

Sensitive data is automatically detected and stored securely (macOS Keychain or encrypted file):

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
- Run `/summary` at the end to create a cohesive record
- Never write raw API keys or passwords to artifact files - use cs -secrets

<!-- cs:memory-note -->
Claude's built-in memory writes durable facts to `.cs/memory/` (cs redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`); the `MEMORY.md` index lists entries and individual `<bucket>_*.md` files are loaded lazily.
<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong triggers (fire on any single occurrence):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft triggers (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
