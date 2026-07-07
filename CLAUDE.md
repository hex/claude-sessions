# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

When resuming this session, read the following files to restore context:

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates'): findings, in-progress state, observations

Note: narratives are per-actor (narrative.<actor>.md) so co-developers never
conflict. Append only to your own (run `cs -whoami` for your actor); read all
narrative.*.md on resume to restore your working narrative and see teammates'
in-progress findings.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Start of session:** Fill in .cs/README.md objective and environment
2. **As you work:** Update your narrative (.cs/memory/narrative.<actor>.md) with findings
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Wrap-up Command

When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone.

## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), store it with the `store-secret` skill and replace it
with a reference. The skill writes the value to a scratch file with the Write
tool (which the bash-logger does not capture) and feeds it in via a stdin
redirect, so the plaintext never reaches argv or the command log:
```bash
cs -secrets set <name> < /path/to/scratch-file   # value on stdin, not in argv
```
Never `echo`/`printf` a secret into a pipe — the bash-logger records the whole
Bash command (secret and all) in `.cs/local/session.log`.

## Best Practices

- Document findings in your narrative (.cs/memory/narrative.<actor>.md) as you go - don't wait until the end
- Run `/wrap` at the end to distill memory and create a cohesive record
- Never write raw API keys or passwords to project files - use cs -secrets

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
