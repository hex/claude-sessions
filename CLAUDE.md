# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

When resuming this session, read the following files to restore context:

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/discoveries.md** - Findings, observations, and ideas
4. **.cs/discoveries.compact.md** - If exists, condensed older findings
5. **.cs/changes.md** - Modifications and fixes made
6. **.cs/artifacts/MANIFEST.json** - List of tracked artifacts

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
2. **As you work:** Update .cs/discoveries.md with findings and .cs/changes.md with modifications
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
- .cs/changes.md is updated automatically when files are modified
- Run `/summary` at the end to create a cohesive record
- Never write raw API keys or passwords to artifact files - use cs -secrets

<!-- cs:memory-rules -->
## Auto-memory bucket guidance (scoop mode — passive, continuous)

This is a **passive** workflow that runs alongside every conversation, without the user asking for it. When you hear a durable fact worth saving across sessions, append it to the matching `.cs/memory/` bucket on the fly — no permission needed.

### The four buckets

| File pattern | Holds |
|---|---|
| `user_*.md` | Durable facts about the user — role, preferences, working style, constraints, availability |
| `feedback_*.md` | Corrections AND validated choices — guidance about how to approach work in this codebase |
| `project_*.md` | Ongoing work, goals, deadlines, drivers, incidents — state of THIS project that's not derivable from git/code |
| `reference_*.md` | Pointers to external systems — Linear projects, Grafana boards, Slack channels, docs URLs |

### How to decide which bucket

| User says something like… | Goes to |
|---|---|
| "I'm the / my role is / I prefer / I always / I hate / I never" | `user_*.md` |
| "don't do X / stop doing Y / not like that" (corrections) | `feedback_*.md` |
| "yes exactly / keep that approach / that worked" (validated choices) | `feedback_*.md` |
| "we're shipping / deadline is / X is driving this / freeze on…" | `project_*.md` |
| "Linear project X / Grafana board at Y / the #channel for Z / docs at URL" | `reference_*.md` |

### The action sequence — eager, never pause to ask

When you hear a durable fact, do these in order. Do not skip steps. Never pause to ask the user "should I record this?" — the bar is the guardrails below, not your hesitation.

1. Skim existing `<bucket>_*.md` files in `.cs/memory/` (and check `MEMORY.md` for the index) to see whether this fact is already captured.
2. If it's new, Write a file at `.cs/memory/<bucket>_<short-slug>.md` with YAML frontmatter:
   ```
   ---
   name: <short title — kebab-case>
   description: <one-line summary used to decide relevance in future conversations>
   metadata:
     type: <user|feedback|project|reference>
   ---

   <the actual fact, in your own words, with the why if it's non-obvious>
   ```
3. Add a one-line pointer to `MEMORY.md`: `- [Title](file.md) — one-line hook`.
4. Announce quietly in one line: `noted in <bucket>_<slug>.md: "<short paraphrase>"`.

### Writing is eager. Reading is lazy.

The action sequence above is for **writing** — when you hear a fact, capture it immediately. The opposite discipline applies to **reading** existing memory files: never preload all four buckets eagerly. Load on demand when the current question actually needs that category of fact.

**Signals it's time to Read a specific bucket file:**

- User mentions a person, tool, customer, or external resource you don't recognize → look for it in `reference_*.md`.
- User references a previous decision or correction ("like we discussed", "the rule we have") → look for it in `feedback_*.md`.
- User asks about project status, a deadline, an ongoing initiative → look for it in `project_*.md`.
- You're reasoning about who the user is or how they prefer to work (e.g. composing an explanation, choosing communication style) → look for it in `user_*.md`.
- `MEMORY.md` references a file you haven't read yet AND it's clearly relevant to the current turn → load that one file.

**Signals it's NOT time to read:**

- The current task is mechanical and self-contained ("run the tests", "fix this typo").
- You already read the relevant file earlier this turn and nothing new has been written since.
- You just wrote a new entry — the write is the source of truth; no need to re-read.

Read at most the specific file you need, not all four. Load on demand, one file at a time.

### Guardrails (non-negotiable)

1. **Only durable facts.** "I'm tired today" is not durable. "I prefer async communication" is. When in doubt, don't record.
2. **Deduplicate.** Skim the matching bucket's files first. If the same fact (even paraphrased) is already captured, don't write a new file.
3. **Never invent.** Only record what the user literally said or clearly implied. Do not embellish, extrapolate, or guess.
4. **One bucket per fact.** If a fact plausibly fits two categories, pick the more specific one. Do not cross-post.
5. **Keep the index in sync.** Every new file gets a one-liner in `MEMORY.md` so future conversations can locate it without reading the whole directory.

To opt out of this guidance, delete the prose above but keep the `cs:memory-rules` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
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
