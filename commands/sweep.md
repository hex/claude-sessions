---
model: opus
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

   Route each fact that passes to a bucket. Most are things the user said; a durable
   constraint you discover while working routes by topic:

   | Trigger | Goes to |
   |---|---|
   | "I'm the / my role is / I prefer / I always / I hate / I never" | `user_*.md` |
   | "don't do X / stop doing Y / not like that" — corrections | `feedback_*.md` |
   | "yes exactly / keep that approach / that worked" — validated choices | `feedback_*.md` |
   | "we're shipping / deadline is / X is driving this / freeze on..." | `project_*.md` |
   | A durable constraint you discover while working ("X silently fails on Y", "the harness disables Z") | `project_*.md` |
   | "Linear project X / Grafana board at Y / the #channel for Z / docs at URL" | `reference_*.md` |

3. **Writing memory entries — INTERPRET, don't transcribe.**
   - Read the matching `.cs/memory/<bucket>_*.md` file first to check for duplicates in any form — paraphrase, near-duplicate, superset. If something similar exists, skip; do not append. But if the new fact contradicts or materially extends an existing entry, update that entry in place (and its `MEMORY.md` pointer) rather than skipping or writing a duplicate.
   - For new entries, name the file `<bucket>_<short_slug>.md` and match the frontmatter shape of the existing entries in that bucket (the dedup read above shows you the current format); if the bucket has no existing entries, copy the frontmatter shape from any other bucket's entries. Then write a concise paraphrase capturing the essence in your own words.
   - One entry per durable fact. If a fact plausibly fits two buckets, pick the more specific one — do not cross-post.
   - After writing an entry, add a one-line pointer for it to `.cs/memory/MEMORY.md`, matching the existing `- [title](file.md): one-line summary` lines and appending to the list. The index is what future sessions load; an unindexed entry is never read again.
   - **Facts about a person MUST be keyed to that person, never asserted about whoever is present.** The durable buckets are shared by every actor on this session while only narratives are per-actor, so "the user is Dana, not Kim" is false on every other machine the moment it is written, and it reads as settled fact to the actor who loads it next. Write `actor <slug> is Dana Marsh, machine /Users/dmarsh` instead: keyed facts stay true everywhere and cannot be misapplied, because they do not claim anyone is present. This governs the `MEMORY.md` pointer line as much as the entry body — pointers load at startup while the entries they name are read lazily, so a pointer saying "session user is Dana" reaches context even when nothing opens the file. Never write an unconditional present-tense identity or presence claim in either place.

4. **Narrative sweep — looser bar.** Resolve `<actor>` with `cs -whoami` first, then append only to your own narrative file. If a substantive finding from this session is not yet in your narrative (`.cs/memory/narrative.<actor>.md`), append it as a dated section. Substantive = something a future session resuming this work would want to know.

5. **Keep the index under budget.** `MEMORY.md` loads in full at every session start against a hard
   size limit; past it Claude Code loads only part of the file and the entries beyond the cut are never
   read again. After writing any pointer — and once per sweep even if you wrote none, since another
   actor may have pushed it over — check:

   ```sh
   wc -c < .cs/memory/MEMORY.md                                    # budget ~24400 BYTES
   awk '/^- \[/{print length($0)"\t"$0}' .cs/memory/MEMORY.md \
     | sort -rn | awk -F'\t' '$1>200' | cut -c1-120                # every over-long pointer, with its text
   ```

   The FILE size is the hard constraint — that is what truncates. The 200 figure is only a heuristic
   for finding candidates: a longer pointer is fine if it carries a rule that would be unsafe to drop,
   and the file still fits. Note `awk length` counts characters while the budget is bytes, so a
   200-character line with em dashes or backticks exceeds 200 bytes.

   If over budget, **rewrite** the longest pointers shorter. A pointer is a recall HOOK, not a summary:
   it needs the distinctive noun that makes a future session open the file, plus any negation that
   makes the entry safe to act on. Detail belongs in the topic file, which loads lazily.

   **Rewrite; never truncate.** Do not cut a line at a character limit, by script or by hand — read the
   topic file's `description:` and compose a shorter sentence. A truncation that drops a trailing
   clause silently deletes the operative rule: on 2026-09-08 a mechanical 200-char cut turned "push the
   release commit, tag only after CI is green" into "push the release commit", and left a consent rule
   as a dangling list of examples. Every repaired line must still read as a whole thought and must keep
   its "never"/"only"/"must".

   **Compress; never delete** an entry or its pointer to save space, and never merge two pointers into
   one — an unindexed entry is never read again. If compression alone cannot fit the budget, say so and
   ask; do not resolve it by dropping entries.

   **After rewriting, verify twice.** Re-run `wc -c` to confirm the file still fits, and re-read each
   rewritten pointer against its topic file. Syntactic health is not semantic health: a shortened line
   can be perfectly formed and still have dropped an authorization boundary ("nothing is ever pushed"),
   a precondition ("only after exact existence is established"), or an exception ("not only security
   work"). Those losses pass every shape check — count, links, balanced quotes — and are exactly what
   this step exists to prevent. Ask of each line: would someone acting on this pointer alone do the
   right thing?

6. **Write quietly.** No chat summary. List the files you wrote (one line each) or say "nothing to add" if the session didn't warrant entries.

## When NOT to write a strict-bucket entry

(These exclusions apply to the strict buckets; the narrative keeps its looser bar from step 4.)

- Routine debugging that produced a fix — the fix is in the code; the commit message has the context.
- Boilerplate code or simple CRUD work.
- Restatements of existing memory entries.
- A play-by-play of what you did ("we refactored X", "fixed the bug in Y") — the code and the commit already carry that. A constraint you *discovered* while doing it still qualifies; route it to `project_*.md`.
- Anything inferring beyond what was literally said or clearly implied.
