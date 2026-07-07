# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

At the start of every conversation in this session, read the following files to restore context (any conversation after the first is a resume; on a true first run they are stubs). Skip any that don't exist yet — they are created as the session progresses.

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates'): findings, in-progress state, observations

Note: narratives are per-actor (narrative.<actor>.md) so co-developers never
conflict. Append only to your own (run `cs -whoami` for your actor); read all
narrative.*.md on resume to restore your working narrative and see teammates'
in-progress findings.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Once the objective is clear** (from the first substantive request): fill in the .cs/README.md objective and environment — don't block the user's first answer on this; on resume, update the existing text rather than overwriting it
2. **As you work:** Update your narrative (.cs/memory/narrative.<actor>.md) with findings
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Wrap-up Command

When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone. Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative — e.g. before a risky refactor or destructive operation, and after reaching a green milestone (tests passing, a feature working) — saved under .cs/checkpoints/.

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

Never print or echo a retrieved secret, and don't paste `cs -secrets export` output into a file — consume the value inline, e.g. `some-command --token "$(cs -secrets get API_KEY)"`, so the plaintext stays out of the tool result and the session transcript.

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), invoke the `store-secret` skill and replace the literal
with a reference appropriate to the file — an env-var placeholder like
`${API_KEY}` in configs, or `$(cs -secrets get API_KEY)` in shell scripts —
noting that the value now lives in `cs -secrets`. The skill writes the value to
a scratch file with the Write tool (which the bash-logger does not capture),
feeds it in via a stdin redirect so the plaintext never reaches argv or the
command log (`cs -secrets set <name> < scratch-file`), and deletes the scratch
file afterward. If the skill is unavailable and you do this by hand, you MUST
delete the scratch file immediately after, and never `echo`/`printf` a secret
into a pipe — the bash-logger records the whole Bash command (secret and all)
in `.cs/local/session.log`.

<!-- cs:memory-note -->
## Where memory lives

Claude's built-in memory writes durable facts to `.cs/memory/` (cs redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`); the `MEMORY.md` index lists entries and individual `<bucket>_*.md` files are loaded lazily.
<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong signals (sufficient on their own — but only when the phrase describes work that actually completed; never fire when it reports a problem, is negated, or is part of a plan for later):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft signals (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
