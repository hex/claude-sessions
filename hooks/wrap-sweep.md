Distill the current session into durable auto-memory entries with a strict bar.

You are working in a cs session. Your task is to review the conversation in your current context and write durable facts into the four auto-memory bucket files at `.cs/memory/`.

## Mental model

Two write surfaces, deliberately DIFFERENT bars:

- **The strict buckets (`.cs/memory/{user,feedback,project,reference}_*.md`) are forever** — they sit in Claude's persistent memory and inform every future session. **Bar: very strict. Default: write nothing.**
- **`.cs/memory/narrative.<actor>.md` is your session-local lab notebook** (per-actor — run `cs -whoami` for your actor) — a native memory topic file, looser bar. Substantive observations welcome. Default: write if the session surfaced a non-obvious finding worth keeping.

Both are written in parallel from the conversation — narrative is not the upstream of the strict buckets.

## Steps

Before anything else, from the session root, snapshot the index and the archive (step 6) so step 6
can check this sweep's rewrites against them:

```sh
bash ~/.claude/hooks/cs/memory-index-guard.sh snapshot
```

1. **Review the conversation in your context.** Look at what the user has said and what was decided or learned across this whole session — not just the most recent turn.

2. **Retro: where did this session struggle?** Before weighing facts, list the moments the work went
   badly: a file or fact that took several tool calls to find, a mistake a tool could have caught
   before you did, a reviewer or gate that missed a judgment call, a tool call that cost far more than
   it returned, a steering line in `CLAUDE.md` or a skill that changed nothing, a step that stalled for
   want of access to a log or a value, a skill that would have helped and never fired, and what did not
   happen but should have: a verification skipped or self-reported, a caller or sibling consumer the
   fix never reached. Each candidate names the moment it comes from: the turn, the command, the error
   line. **Discard any candidate you cannot trace to one moment**: late in a long
   session the categories invite generic advice, and an untraceable candidate is that. A smooth
   session lists nothing, and says so.

   Rank what survives, most costly first, and route each to the fix that stops the repeat:

   | Struggle | Fix |
   |---|---|
   | Slow to find a file or fact | A navigation pointer in a file every session already reads (`CLAUDE.md`, a README) |
   | A mistake a tool could have caught | A check: a test, lint, hook or CI lane (step 4's check rule decides which) |
   | A gate or review missed a judgment call | A rule in the reviewing skill or standards doc, not in `CLAUDE.md` |
   | A tool call that cost far more than it returned | Streamline or replace the tool |
   | A steering line that changed nothing | Delete it |
   | A skill that would have helped and never fired | Tune that skill's description, not its body |
   | Stalled for want of a log or a value | Widen access: tee the log to a file, expose the value |

   A fix lands in a file this session read or a skill it ran, never in one it only could have used.
   Before proposing a rule, read where it would go: if the guidance is already there, the fix is its
   wording or placement so it fires, never a second copy, and if it is there and clear, the session's
   problem was execution, and there is no fix to file.

   **Propose, never apply.** This pass edits nothing outside `.cs/memory/`: add one task per surviving
   candidate, named for its fix and carrying its moment, the way step 4 adds a task for a check.
   The user picks what to build. A candidate that is also a durable fact still goes through step 4's
   bars; the task does not replace the entry, and the entry does not replace the task.

3. **For each of the four memory categories** (`user`, `feedback`, `project`, `reference`), ask: is there a durable fact in this conversation that meets ALL three bars?

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

4. **Writing memory entries — INTERPRET, don't transcribe.**
   - Read the matching `.cs/memory/<bucket>_*.md` file first to check for duplicates in any form — paraphrase, near-duplicate, superset. If something similar exists, skip; do not append. But if the new fact contradicts or materially extends an existing entry, update that entry in place (and its pointer, in `MEMORY.md` or in step 6's archive) rather than skipping or writing a duplicate.
   - For new entries, name the file `<bucket>_<short_slug>.md` and match the frontmatter shape of the existing entries in that bucket (the dedup read above shows you the current format); if the bucket has no existing entries, copy the frontmatter shape from any other bucket's entries. Then write a concise paraphrase capturing the essence in your own words.
   - One entry per durable fact. If a fact plausibly fits two buckets, pick the more specific one — do not cross-post.
   - **A measured claim names what it was measured on.** A fact that holds because you ran something (a Claude Code build, a cs version, an app, a flag) writes that in the body, as `measured on Claude Code <version>, <YYYY-MM-DD>`, the version from `claude --version` and the date from `date`, never from memory. Without it the entry reads as timeless, and a later session trusts it after the thing it measured has changed. With it, that session knows to re-measure once the version has moved. A discovered constraint ("X silently fails on Y") is measured and gets the line; a fact the user stated does not.
   - **Name the entry it supersedes.** Before writing, find the existing entry the new fact contradicts or materially extends, in `MEMORY.md` or the archive, and update that entry and its pointer instead of adding a second. The dedup read finds the same fact in other words; this looks for an older fact the new one overturns. Decide it for every entry, and write the answer in step 7's report: a new entry ends in `supersedes: <file>` or `supersedes: none`; an entry updated in place ends in `updated in place`.
   - After writing an entry, add a one-line pointer for it to `.cs/memory/MEMORY.md`, matching the existing `- [title](file.md): one-line summary` lines and appending to the list. The index is what future sessions load; an unindexed entry is never read again.
   - **Facts about a person MUST be keyed to that person, never asserted about whoever is present.** The durable buckets are shared by every actor on this session while only narratives are per-actor, so "the user is Dana, not Kim" is false on every other machine the moment it is written, and it reads as settled fact to the actor who loads it next. Write `actor <slug> is Dana Marsh, machine /Users/dmarsh` instead: keyed facts stay true everywhere and cannot be misapplied, because they do not claim anyone is present. This governs the `MEMORY.md` pointer line as much as the entry body — pointers load at startup while the entries they name are read lazily, so a pointer saying "session user is Dana" reaches context even when nothing opens the file. Never write an unconditional present-tense identity or presence claim in either place.
   - **Could a check carry it instead?** For a `feedback` or `project` fact that states a rule (do X, never Y, X silently fails on Y), ask whether a mechanical check could enforce it: a test, a lint or grep guard that fails CI, a hook that refuses the action, a type or schema, or a script that replaces the manual step. It counts only when all three hold: deciding compliance needs no judgment about who, when or which; the check, run against the current tree today, would match no legitimate code, so it needs no allowlist; and nothing already enforces it (search the tests, hooks and CI first). A rule that needs judgment to apply (taste, timing, what to ask the user) has no check. An entry that only describes how something behaves (a measurement, what a tool does) is not a rule, even when a defensive check could be built around it; when it also prescribes what to do, judge the prescription. When a check counts, add a task to build it and keep the memory entry as written.

5. **Narrative sweep — looser bar.** Resolve `<actor>` with `cs -whoami` first, then append only to your own narrative file. If a substantive finding from this session is not yet in your narrative (`.cs/memory/narrative.<actor>.md`), append it as a dated section. Substantive = something a future session resuming this work would want to know.

6. **Keep the index under budget.** `MEMORY.md` loads in full at every session start against two hard
   limits, bytes and lines; past either, Claude Code loads only part of the file and the entries beyond
   the cut are never read again. After writing any pointer — and once per sweep even if you wrote none,
   since another actor may have pushed it over — check:

   ```sh
   bash ~/.claude/hooks/cs/memory-index-guard.sh check             # size against the byte and line budgets
   awk '/^- \[/{print length($0)"\t"$0}' .cs/memory/MEMORY.md \
     | sort -rn | awk -F'\t' '$1>200' | cut -c1-120                # every over-long pointer, with its text
   ```

   `check` exits 1 when the file is over either budget, when a pointer that was in `MEMORY.md` or
   the archive at the snapshot is in neither now, when a pointer names an entry file that is not in
   `.cs/memory/`, when a pointer is in both `MEMORY.md` and the archive, or when a bucket entry has
   no pointer in either file, and names each one. A pointer names an entry file when its target is
   a bare file name ending in `.md`, with no `/` and no `:`; a URL or a `file.md#section` link names
   none and is not checked, in `MEMORY.md` and the archive alike. Both budgets live in the script,
   and every line counts toward the line budget, blank and heading lines too.

   The FILE size and line count are the hard constraints — they are what truncates. The 200 figure
   above is only a heuristic for finding long pointers: a longer pointer is fine if it carries a rule
   that would be unsafe to drop, and the file still fits. Note `awk length` counts characters while
   the budget is bytes, so a 200-character line with em dashes or backticks exceeds 200 bytes.

   **The archive.** `.cs/memory/reference_memory_archive.md` is an ordinary `reference_` entry, with
   frontmatter like its siblings, whose body lists pointer lines in `MEMORY.md`'s own shape,
   `- [title](file.md): hook`. `MEMORY.md` holds one pointer to it. Entry files never move out of
   `.cs/memory/` and are never deleted; only pointer lines move.

   **Demote.** You may move a pointer line from `MEMORY.md` to the end of the archive when its entry
   is either of these, and if over budget, **demote first**, before rewording anything:
   - about a subject that no longer exists: a finished project, a closed study; or
   - a rule a test, hook or CI lane now enforces. Find the check in the tree before you move the
     pointer; a rule you only believe a check enforces stays.

   A rule that has to fire before a proposal stays in `MEMORY.md`, whatever else is true of its entry:
   "never re-add X", "declined, never re-propose", "rejected". A future session needs it before it
   suggests the thing, and it has no reason to open the archive first.
   A `narrative.*.md` pointer is never demoted either: cs adds the opening actor's narrative pointer
   back to `MEMORY.md` whenever `MEMORY.md` lacks it, and the pointer would then be in both files.

   Move the line byte for byte: delete it from `MEMORY.md` and append the identical line to the
   archive. Never reword a pointer on its way into the archive. The first demotion creates the
   archive with exactly these lines, byte for byte, followed by one blank line, so that two clones
   that each make a first demotion write the same header and their merge keeps one copy of it:

   ```markdown
   ---
   name: memory-archive
   description: "Pointers moved out of MEMORY.md; each entry still applies when its subject comes up"
   metadata:
     type: reference
   ---
   ```

   It also appends the archive's own pointer to `MEMORY.md`, for example
   `- [Memory archive](reference_memory_archive.md): pointers moved out of this index; open it when a subject is not listed here`.
   Never edit the archive's frontmatter after that: a pass changes the archive only by appending
   a pointer line, updating one in step 4, or deleting one on `duplicate:`. `check` names each pointer this sweep moved as
   `demoted:` and passes it.

   Rewording shortens a line's bytes, never the number of lines: over the line budget, demotion is the
   only remedy, and when no pointer meets either criterion, say so and ask. Over the byte budget alone,
   go on to rewrite.

   If still over the byte budget, **rewrite** the longest pointers shorter. A pointer is a recall HOOK, not a summary:
   it needs the distinctive noun that makes a future session open the file, plus any negation that
   makes the entry safe to act on. Detail belongs in the topic file, which loads lazily.

   **Rewrite; never truncate.** Do not cut a line at a character limit, by script or by hand — read the
   topic file's `description:` and compose a shorter sentence. A truncation that drops a trailing
   clause silently deletes the operative rule: on 2026-09-08 a mechanical 200-char cut turned "push the
   release commit, tag only after CI is green" into "push the release commit", and left a consent rule
   as a dangling list of examples. Every repaired line must still read as a whole thought and must keep
   its "never"/"only"/"must".

   **Compress; never delete** an entry or its pointer to save space, and never merge two pointers into
   one — an unindexed entry is never read again. A pointer moved into the archive is not deleted; one
   dropped from both files is. If demotion and compression together cannot fit the budget, say so and
   ask; do not resolve it by dropping entries.

   Put a removed pointer back by rewriting it. `duplicate:` is a move stopped half done, by `restore`
   or by a merge that brought another actor's demotion in beside your index; keep one copy. When
   the entry is a rule that has to fire before a proposal, its demotion broke the rule
   above: delete the archive's copy. Otherwise delete the `MEMORY.md` copy. Delete that one line and
   keep the other copy as it stands, even when the two differ: an entry whose meaning changed gets its
   pointer updated in step 4, never here. On `dangling:`, stop and ask: entries are
   never deleted, so a pointer whose file is gone means a rename or a lost file only the user can
   account for. If the index is past repair, run
   `bash ~/.claude/hooks/cs/memory-index-guard.sh restore` to return it to the snapshot, then redo this
   sweep's pointer edits. `restore` puts back `MEMORY.md` alone, so redo a demotion by deleting the
   `MEMORY.md` line `check` then names `duplicate:`. Never finish a sweep with `check` failing.

   Run `bash ~/.claude/hooks/cs/memory-index-guard.sh refs` once per sweep. Take at most five `dead:` lines
   in order; report the remaining count. Open each named entry and update the reference to its
   current name. A file outside this checkout (another repository, `~/.claude`) is not dead:
   use an absolute or `~/` path, which the check does not resolve. If the thing no longer exists
   anywhere, append ` (gone YYYY-MM-DD)` immediately after its backticked reference, using today's
   date; `refs` skips it. Delete a marker if its reference resolves again. Never delete the entry
   or its pointer because a reference is dead.

   **After rewriting, verify twice.** Re-run `check` to confirm the file still fits and every link survived, and re-read each
   rewritten pointer against its topic file. Syntactic health is not semantic health: a shortened line
   can be perfectly formed and still have dropped an authorization boundary ("nothing is ever pushed"),
   a precondition ("only after exact existence is established"), or an exception ("not only security
   work"). Those losses pass every shape check — count, links, balanced quotes — and are exactly what
   this step exists to prevent. Ask of each line: would someone acting on this pointer alone do the
   right thing?

7. **Write quietly.** No chat summary. List the files you wrote (one line each; a new entry ends in `supersedes: <file>` or `supersedes: none`, an entry updated in place ends in `updated in place`) or say "nothing to add" if the session didn't warrant entries.

## When NOT to write a strict-bucket entry

(These exclusions apply to the strict buckets; the narrative keeps its looser bar from step 5.)

- Routine debugging that produced a fix — the fix is in the code; the commit message has the context.
- Boilerplate code or simple CRUD work.
- Restatements of existing memory entries, including one whose pointer is in the archive
  (`.cs/memory/reference_memory_archive.md`): its entry file is still in `.cs/memory/`, and the
  dedup read in step 4 finds it.
- A play-by-play of what you did ("we refactored X", "fixed the bug in Y") — the code and the commit already carry that. A constraint you *discovered* while doing it still qualifies; route it to `project_*.md`.
- Anything inferring beyond what was literally said or clearly implied.
