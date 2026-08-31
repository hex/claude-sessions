# Narrative rotation

**Status:** implemented on feat/narrative-rotation (plan: docs/superpowers/plans/2026-08-31-narrative-rotation.md)
**Date:** 2026-08-31
**Origin:** mail `ff01ec` from session `sym` (2026-08-30); council run `.claude/council-cache/council-agents-1788149473.md`

## Problem

Per-actor narratives (`.cs/memory/narrative.<actor>.md`) only ever grow. The Stop
hook asks for an append every five minutes and nothing trims. Measured here:
802 KB / 8,062 lines and 776 KB / 13,133 lines; a third session reports 3.7 MB.
The resume protocol says "read all narrative.*.md on resume", which at ~200K
tokens per file no conversation can do, so in practice a resume reads a tail and
the rest is git weight and grep noise. `/wrap` already distils durable facts into
the strict memory buckets and `.cs/summary.md`, so the old body is play-by-play
whose durable content has already left.

## Decisions (approved 2026-08-31)

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Distillation | None. Mechanical, verbatim archival only — `/wrap` owns distillation. |
| 2 | Cut rule | Byte budget at `## ` boundaries. Never by calendar date: 130 of 307 headings in one file are undated, and 74 dated sections (~776 KB) fall in a single month. |
| 3 | Executor | A cs helper, `cs -narrative rotate`. Deterministic bash in `lib/`, tested in `tests/`. Nobody types it; `/wrap`, the Stop hook and `cs -doctor` point at it. |
| 4 | Triggers | `/wrap` runs it; the existing Stop-hook narrative check adds one line when a narrative is over budget; `cs -doctor` warns. |
| 5 | Archive location | `.cs/narrative-archive/<actor>/` — outside `.cs/memory/`, so Claude Code's auto-memory scan and every `memory/narrative*.md` glob (hook, TUI, checkpoint, index) stay untouched. |
| 6 | Archive granularity | One immutable, content-addressed chunk file per rotation. No merge driver needed. |
| 7 | Narrative contract | Append-only. Corrections are new dated notes; earlier sections are never rewritten or deleted. This is what makes head-truncation merge-safe. |
| 8 | Resume wording | "Read the live narrative.*.md; archives are history, grep on demand." |

## Merge safety — measured, not recalled

Three-way merges of a `merge=union` file, reproduced locally with git:

| Case | Result |
|------|--------|
| Remove a leading run of sections, keep the tail byte-identical; peer appends at EOF | Clean. Peer's append lands after the kept tail. |
| Same, but peer edits a line **inside** the removed run | The whole removed run comes back (union keeps both sides of the conflicting hunk). Benign: the next rotation removes it again. Decision 7 makes this a protocol violation rather than a supported path. |
| Two machines rotate at different cut points | Converge on the less aggressive cut. No conflict. |
| `mv` the file aside and recreate it (rollover); peer appends | **Entire old body resurrects.** |
| Truncate down to the header only (the removed hunk reaches EOF); peer appends | **Entire old body resurrects.** |

Rule: a rotation removes exactly one hunk, that hunk ends before a `## ` heading,
and at least one complete section after it is left byte-identical. Never rename
the live file, never let the removed hunk reach EOF.

## Design

### `cs -narrative rotate`

Runs from inside a session (requires `CLAUDE_SESSION_META_DIR`). Rotates the
current actor's narrative only.

Inputs, all optional:

- `CS_NARRATIVE_MAX_BYTES` — rotate when the live file exceeds this. Default 131072 (128 KiB).
- `CS_NARRATIVE_KEEP_BYTES` — target size of the retained tail. Default 65536 (64 KiB, roughly 16K tokens — what a resume actually reads).

Algorithm:

1. `size=$(wc -c < live)`. If `size <= MAX`: print `nothing to rotate (N KB, budget M KB)`, exit 0.
2. Under `LC_ALL=C`, walk the file once with awk and record the byte offset of every `## ` heading. The header block (YAML frontmatter and the `# Session narrative (...)` H1, everything before the first `## `) is never archived.
3. Cut point = the earliest `## ` heading whose distance to EOF is `<= KEEP`. If the final section alone exceeds KEEP, the cut point is the final section's heading (the tail is then that one section, oversized; doctor keeps warning). If the file has fewer than two `## ` headings, print a warning and exit 0 — there is nothing to remove without touching the tail.
4. Archived body = bytes from the end of the header block to the cut point. Name = `<through-date>-<blob8>.md`, where `through-date` is the last `YYYY-MM-DD` found in a `## ` heading of the archived body (`undated` if none) and `blob8` is the first 8 hex digits of `git hash-object --stdin` over the archived body. Two machines archiving the same prefix produce the same file.
5. Write `.cs/narrative-archive/<actor>/<name>.md` via tmp+`mv`: a two-line HTML comment header (`rotated from narrative.<actor>.md`, section count, through-date) followed by the archived body verbatim. If the file already exists: identical content → fine, continue; different content → abort (hash collision or tampering; report it).
6. Re-read the live file. Verify it still begins with the header block plus the archived body, byte for byte (`cmp -n`). Anything else (a concurrent append landed inside the hunk, a peer merge) → remove the chunk written in step 5 if this run created it, print `narrative changed during rotation; run again`, exit 1.
7. Write the new live file via tmp+`mv`: header block, then every byte from the cut point to the *current* EOF — so an append that arrived after step 1 survives.
8. If the session is a git repo and the live file is tracked, `git add` both files and commit `cs: rotate narrative.<actor> (N sections -> narrative-archive)`. If `.cs/` is gitignored (this development repo) or the working tree is not a repo, skip the commit and say so. The autosave shadow ref covers crash recovery either way.
9. Append a `narrative_rotated` event to `.cs/timeline.jsonl` (actor, sections, bytes, archive name), same shape discipline as `checkpoint`.
10. Print one line: `rotated N sections (X KB) -> .cs/narrative-archive/<actor>/<name>.md; live file now Y KB`.

The helper never reads a narrative through Claude: it is `wc`, `awk`, `head -c`,
`tail -c`, `cmp`, `git hash-object`. A 3.7 MB file rotates in one pass.

### Stop hook (`hooks/narrative-reminder.sh`)

Two changes inside the existing narrative-check block, no new tier, no new cooldown:

- Contract wording: *"(1) If recent work disproved or superseded one of your entries, append a dated correction that names it — never rewrite or delete earlier sections."*
- Budget line: while choosing the newest narrative the loop already stats every `memory/narrative*.md`; also take `wc -c`. If any exceeds `CS_NARRATIVE_MAX_BYTES` (same default), append to the reason: *"narrative.X.md is N KB, over the M KB budget — if it is yours, run `cs -narrative rotate` before appending."*

### `cs -doctor`

`_doctor_check_narrative_size`, in the session-gated group: `[WARN] Narrative: narrative.X.md is N KB (budget M KB) — run cs -narrative rotate` per oversized file, one `[ OK ]` line otherwise. Read-only; it never rotates.

### `/wrap`

Pass 3, after the summary: run `cs -narrative rotate` and put its one-line output in the report as item 3, **Narrative**. `commands/summary.md` step 1 loses "read all of them" and gains "the live narrative.*.md; older sections are under .cs/narrative-archive/ — history, skip unless the summary needs a date".

### Consumers

| Consumer | Change |
|----------|--------|
| `cs -search` | `search_globs` gains `.cs/narrative-archive/*/*.md`. |
| Rust TUI heading list | None — live files only, by construction. |
| `cs -checkpoint` | None — snapshots live files; archives are already committed history. |
| Resume digest (commits touching `.cs/memory`) | None; rotation commits touch `.cs/memory/narrative.*` and count as narrative activity, which they are. |
| `.gitattributes` | None — chunks are immutable. |

### Resume wording (every surface)

Old: *read all narrative.*.md on resume.*
New: *read the live narrative.*.md on resume (rotation keeps them small); older sections are under `.cs/narrative-archive/<actor>/` — grep on demand, never preload.*

Surfaces: `lib/35-claudemd.sh` (frontmatter `description`, MEMORY.md pointer line, session-protocol block), `hooks/session-start.sh` (key-files line, fresh-conversation notice), `commands/summary.md`, `README.md`, `docs/session-layout.md`. Plus a `migrate_session` phase that rewrites, in place, the `description:` line of existing `narrative.*.md` frontmatter, the existing MEMORY.md pointer line, and the two-line sentence in the `cs:session-protocol` block of an existing CLAUDE.local.md, matching both protocol-block wordings cs has shipped (the current two-line form and the July-2026 four-line form), tolerant of CRLF (Phase 5 only appends the block when absent; it never refreshes wording) (both are literal strings cs wrote; MEMORY.md is `merge=ours`, so the rewrite stays local until the index next syncs, which is the existing behaviour for every index edit).

### Multi-user classification

| Path | Class | Merge |
|------|-------|-------|
| `.cs/narrative-archive/<actor>/<name>.md` | shared, committed, immutable after creation | default (content-addressed names make concurrent creation identical) |
| live `narrative.<actor>.md` rewrite | shared; single interior hunk, tail untouched | existing `union` |
| tmp files during rotation | same directory as the target, `mv`ed into place | n/a |

No new machine-local state.

### Documentation

`README.md` (narrative bullet, command list, "Merge" section), `docs/session-layout.md` (table row for `.cs/narrative-archive/`), `lib/10-help.sh`, both completion files.

## Testing

TDD, one slice at a time, every suite runnable under `/bin/bash` 3.2 with BSD userland:

- `tests/test_narrative_rotate.sh` — under budget is a no-op; cut lands on a `## ` boundary; header block retained; tail ≤ KEEP; oversized final section retained whole; single-section file is a warned no-op; chunk name is content-addressed and a re-run is a no-op; an append between read and write survives; identical existing chunk is accepted, differing one aborts; commit made in a tracked repo, skipped in an ignoring one; timeline event appended; multibyte content survives byte-exact (fixture with UTF-8 em-dashes, as real headings have).
- Union-merge integration (two clones, `merge=union`): rotate on A, append on B, merge → tail + append, no resurrection. Rotate on both at different cut points → clean.
- `tests/test_doctor.sh` — WARN over budget, OK under.
- `tests/test_hooks.sh` — budget line present over budget, absent under; contract wording pinned.
- `tests/test_commands.sh` / `tests/test_docs.sh` — `/wrap` Pass 3, summary wording, README and session-layout mention the archive dir, no surface still says "read all narrative".
- `tests/test_migrate_claude_md.sh` — existing frontmatter description and MEMORY.md pointer rewritten once, idempotent.
- Search: an archive match is found by `cs -search`.

## Out of scope

- LLM summaries of archived epochs (`/wrap` is the recall layer; add later only if a real resume misses something).
- Rotating a teammate's narrative, or all narratives at once.
- A `status`/`list` subcommand; `ls .cs/narrative-archive/<actor>/` is the listing.
- Changing the merge driver or the reminder cadence.

## Estimates

Helper + its suite: ~3 h. Hook, doctor, search, wrap: ~1.5 h. Wording sweep, migration phase, docs: ~2 h. Adversarial review pass: ~1 h. Roughly one working day.

## Known limitation

The section scan is the same naive `^## ` line match the TUI's heading list uses: a `## ` line inside a fenced code block counts as a boundary, so in the worst case the rotated live file opens mid-fence. Byte-exactness and merge safety are unaffected (the bytes still rebuild). Inherited, not introduced; the real-data probe in the plan's final task is where it would show.
