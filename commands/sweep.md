---
model: claude-sonnet-5
---

Distill the current session into durable auto-memory entries with a strict bar.

You are working in a cs session. Your task is to review the conversation in your current context and write durable facts into the four auto-memory bucket files at `.cs/memory/`.

## Mental model

Two write surfaces, deliberately DIFFERENT bars:

- **The strict buckets (`.cs/memory/{user,feedback,project,reference}_*.md`) are forever** — they sit in Claude's persistent memory and inform every future session. **Bar: very strict. Default: write nothing.**
- **`.cs/memory/narrative.<actor>.md` is your session-local lab notebook** (per-actor — run `cs -whoami` for your actor) — a native memory topic file, looser bar. Substantive observations welcome. Default: write if the session surfaced a non-obvious finding worth keeping.

Both are written in parallel from the conversation — narrative is not the upstream of the strict buckets.

## Steps

1. **Review the conversation in your context.** Look at what the user has said and what was decided or learned across this whole session — not just the most recent turn.

2. **For each of the four memory categories** (`user`, `feedback`, `project`, `reference`), ask: is there a durable fact in this conversation that meets ALL three bars?

   a. **Durable** — still true / still relevant in three months. Not "I'm tired today." Not "we tried approach X for this one PR."
   b. **Surprising or non-obvious** — not derivable from the code, the README, or what a future session would already know from CLAUDE.md.
   c. **Future-relevant** — a future session would change a decision because of it. If you can't picture that concretely, skip.

   Most sessions produce nothing here. The expected answer for most files on most sessions is "no." Don't reach.

   Route each fact that passes by what the user actually said:

   | User says... | Goes to |
   |---|---|
   | "I'm the / my role is / I prefer / I always / I hate / I never" | `user_*.md` |
   | "don't do X / stop doing Y / not like that" — corrections | `feedback_*.md` |
   | "yes exactly / keep that approach / that worked" — validated choices | `feedback_*.md` |
   | "we're shipping / deadline is / X is driving this / freeze on..." | `project_*.md` |
   | "Linear project X / Grafana board at Y / the #channel for Z / docs at URL" | `reference_*.md` |

3. **Writing memory entries — INTERPRET, don't transcribe.**
   - Read the matching `.cs/memory/<bucket>_*.md` file first to check for duplicates in any form — paraphrase, near-duplicate, superset. If something similar exists, skip; do not append.
   - For new entries, match the frontmatter shape of the existing entries in that bucket (the dedup read above shows you the current format), then a concise paraphrase capturing the essence in your own words.
   - One entry per durable fact. If a fact plausibly fits two buckets, pick the more specific one — do not cross-post.
   - After writing an entry, add a one-line pointer for it to `.cs/memory/MEMORY.md`. The index is what future sessions load; an unindexed entry is never read again.

4. **Narrative sweep — looser bar.** If a substantive finding from this session is not yet in your narrative (`.cs/memory/narrative.<actor>.md`), append it as a dated section. Substantive = something a future session resuming this work would want to know.

5. **Write quietly.** No chat summary. List the files you wrote (one line each) or say "nothing to add" if the session didn't warrant entries. Empty output is a successful sweep when the conversation didn't surface durable facts.

## When NOT to write

- Routine debugging that produced a fix — the fix is in the code; the commit message has the context.
- Boilerplate code or simple CRUD work.
- Restatements of existing memory entries.
- Anything you'd document as "we did X" — that's a discovery, not a memory.
- Anything inferring beyond what was literally said or clearly implied.

The default for most sessions is "nothing to add." Resist the urge to manufacture entries.
