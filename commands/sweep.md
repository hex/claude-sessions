Distill the current session into durable auto-memory entries with a strict bar.

You are working in a cs session. Your task is to review the conversation in your current context and write durable facts into the four auto-memory bucket files at `.cs/memory/`. The session's `CLAUDE.md` contains the bucket-guidance signal-phrase table — apply it strictly here.

## Mental model

Two write surfaces, deliberately DIFFERENT bars:

- **`.cs/memory/*.md` entries are forever** — they sit in Claude's persistent memory and inform every future session. **Bar: very strict. Default: write nothing.**
- **`.cs/discoveries.md` is the session-local lab notebook** — substantive observations welcome. Bar: looser. Default: write if the session surfaced a non-obvious finding worth keeping.

## Steps

1. **Review the conversation in your context.** Look at what the user has said and what was decided or learned across this whole session — not just the most recent turn.

2. **For each of the four memory categories** (`user`, `feedback`, `project`, `reference`), ask: is there a durable fact in this conversation that meets ALL three bars?

   a. **Durable** — still true / still relevant in three months. Not "I'm tired today." Not "we tried approach X for this one PR."
   b. **Surprising or non-obvious** — not derivable from the code, the README, or what a future session would already know from CLAUDE.md.
   c. **Future-relevant** — a future session would change a decision because of it. If you can't picture that concretely, skip.

   Most sessions produce nothing here. The expected answer for most files on most sessions is "no." Don't reach.

3. **Writing memory entries — INTERPRET, don't transcribe.**
   - Read the matching `.cs/memory/<bucket>_*.md` file first to check for duplicates in any form — paraphrase, near-duplicate, superset. If something similar exists, skip; do not append.
   - For new entries, follow the standard auto-memory format (frontmatter with `name` / `description` / `type`, then concise paraphrase capturing the essence in your own words).
   - One entry per durable fact. If a fact plausibly fits two buckets, pick the more specific one — do not cross-post.

4. **Discoveries sweep — looser bar.** If a substantive finding from this session is not yet in `.cs/discoveries.md`, append it as a dated section. Substantive = something a future session resuming this work would want to know.

5. **Write quietly.** No chat summary. List the files you wrote (one line each) or say "nothing to add" if the session didn't warrant entries. Empty output is a successful sweep when the conversation didn't surface durable facts.

## When NOT to write

- Routine debugging that produced a fix — the fix is in the code; the commit message has the context.
- Boilerplate code or simple CRUD work.
- Restatements of existing memory entries.
- Anything you'd document as "we did X" — that's a discovery, not a memory.
- Anything inferring beyond what was literally said or clearly implied.

The default for most sessions is "nothing to add." Resist the urge to manufacture entries.
