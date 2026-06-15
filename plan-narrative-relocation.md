# Plan: Relocate session narrative into native memory (`discoveries.md` → `.cs/memory/narrative.md`)

Status: SHIPPED on branch wip-narrative-relocation (2026-06-15). All phases complete, full suite green, deployed via install.sh, cs -doctor clean. Commits: Phase 1 bd53371, Phase 2 f044a67, Phase 3 d1c635c, Phase 4 c69a37c, Phase 5 5206a3b (+ plan-shipped 8a0ca1d).

Phase 5 (post-review, per Alex): added narrative-reminder.sh (Stop, lighter — cooldown + stale check, no size budget) AND narrative-precompact.sh (PreCompact — flush findings before context loss) to replace the retired discoveries-reminder with complementary periodic + event-based triggers. Also fixed a code-review bug: migrate_discoveries_to_narrative dropped discoveries.compact.md content when discoveries.md was header-only. Open caveat: PreCompact additionalContext injection is unverified at runtime (well-formed + fail-open; periodic reminder is the backstop).

## Goal
Move the session lab-notebook narrative out of cs's hand-rolled `discoveries.md` (+ `discoveries.compact.md`) and into a native Claude Code memory **topic file** `.cs/memory/narrative.md`. Retire the bespoke size-budget / compaction / reminder machinery; inherit native lazy-load, `/memory` tooling, and persistence. Preserve the two-bar separation (narrative stays looser-bar via `type: narrative`; the strict `user/feedback/project/reference` buckets are untouched) and the resume-narrative role.

## Why this is safe (spike-confirmed 2026-06-15)
The native writer ADOPTS a cs-authored topic file: it preserved `narrative.md`'s body and `MEMORY.md` pointer across an active writing session, normalized the frontmatter to canonical schema, and stamped `originSessionId`. Division of labor: **cs owns the body + the `MEMORY.md` pointer; the harness owns frontmatter + recall.** Lazy-load confirmed (index in context at startup, topic bodies on demand). No programmatic `MEMORY.md` regenerator exists in cs; `/sweep` is append-style.

## Non-goals
- No cs-side size management or compaction (the whole point — native lazy-load handles growth).
- Not touching the strict memory buckets or `/sweep`'s strict pass.
- Not changing crash recovery (`discovery-commits.sh` shadow-ref autosave stays).

---

## Phase 1 — Stand up `narrative.md` alongside discoveries (no removals yet)
Tests first, then code. At the end of this phase both files coexist; nothing is deleted.

1. **Session init creates the stub + pointer (idempotent).** `bin/cs` (~968-972, the discoveries template): also create `.cs/memory/narrative.md` with a minimal frontmatter + `## Session narrative` heading, and ensure a one-line pointer exists in `.cs/memory/MEMORY.md` (append-if-missing — this doubles as the idempotent re-add insurance). Idempotent on resume.
2. **One-time migration.** On resume/adopt (mirror `migrate_if_exists` at bin/cs:1063): if `.cs/discoveries.md` exists and has content, fold it (and `discoveries.compact.md`) into `narrative.md` body, then add the pointer. Decision needed: migrate existing sessions, or new-sessions-only (see Decisions).
3. **prose-lint exclusion (the gotcha).** `hooks/prose-lint.sh:52` — exclude `narrative.md` from the `memory/*.md` lint set (currently excludes only `MEMORY.md`). `narrative.md` is append-heavy like discoveries, which is already excluded. Add a test in `test_prose_lint_hook.sh` mirroring the discoveries-excluded case.
4. **Tests:** new `test_*` asserting (a) `narrative.md` + pointer created at init, (b) pointer idempotently re-added if deleted, (c) migration folds discoveries content, (d) `narrative.md` is prose-lint-excluded.

## Phase 2 — Repoint consumers to `narrative.md`
5. **Resume read list:** `bin/cs:698-704` (CLAUDE.md "READ THESE ON RESUME") + `hooks/session-start.sh:157,274` — replace discoveries refs with `narrative.md`.
6. **`/sweep`:** `commands/sweep.md` — looser-bar write target (step 4) becomes `narrative.md`; fix the "funnel" framing → "two parallel bars on one conversation" (memory + narrative both siphon from the conversation; narrative is not memory's upstream).
7. **`/summary`:** `commands/summary.md:9-10` — read `narrative.md` instead of discoveries + compact.
8. **`/wrap`:** `commands/wrap.md:9,13` — reference updates only (flow unchanged).
9. **Checkpoint:** `bin/cs:1359-1362` / `commands/checkpoint.md` — snapshot `narrative.md`.
10. **Subagents:** `hooks/subagent-context.sh:31` — point at `narrative.md`.
11. **`discovery-commits.sh`:** keep the hook (shared crash recovery). Repoint its `LATEST_ENTRY` extraction (lines 34-54, 85-86) from `discoveries.md` to `narrative.md`. Rename optional (see Decisions).
12. **`cs -search`:** `bin/cs:1981` — drop `discoveries.md`/`discoveries.compact.md` from `search_files`; `narrative.md` is already covered by `search_globs=".cs/memory/*.md"`. Net simplification. Update `test_search.sh`.
13. **TUI (Rust):** `session.rs:28,59-69,113` read `narrative.md` headings; `ui.rs:972-977,1022` render (label "disc"→"notes"); `app.rs:3048,3092` field init; tests `session.rs:686-726`. Recompile + retest.

## Phase 3 — Retire the bespoke machinery
14. **Reminder hook:** add `discoveries-reminder.sh` to `RETIRED_HOOKS` in BOTH `install.sh` and `bin/cs` (per CHANGELOG.md:53 precedent so deployed copies are removed); drop from `CS_HOOKS`, the Stop registration (`install.sh:486`), and `docs/hooks.md:36-41`.
15. **Compaction command:** delete `commands/compact-discoveries.md`; remove from `CS_COMMANDS` (bin/cs:49) + `install.sh:112`.
16. **Size budget:** delete `CS_DISCOVERIES_DEFAULT_MAX` (bin/cs:13, bin/cs-statusline:10) and `CS_DISCOVERIES_MAX_SIZE` handling.
17. **Doctor check:** delete `_doctor_check_discoveries_size` (bin/cs:1804-1818) + call site (bin/cs:1949). Update `test_doctor.sh:29,71-77,479`.
18. **Statusline segment:** remove `_seg_disc` (bin/cs-statusline:347-358) + `ICON_DISC` + `docs/statusline.md:22,29`. Update `test_statusline.sh`. (Default: drop; alt: repoint to a line-count — see Decisions.)
19. **Tests deleted (feature removed, not ported):** `test_hooks.sh:29-103` reminder cases; `test_commands.sh:102-125` compact cases. Scaffolding boilerplate (`test_uuid.sh`, `test_memory_rules.sh`, `test_wrap_cues.sh` `echo "# Discoveries" >`) repointed to `narrative.md`.

## Phase 4 — Remove discoveries, finalize, deploy
20. Stop creating `discoveries.md` at init (remove bin/cs:968-972 discoveries template + the `.discoveries-reminder-cooldown` gitignore lines at bin/cs:2933,3007).
21. **CLAUDE.md scaffold:** rewrite the lab-notebook protocol prose (bin/cs:698-784 + deployed project CLAUDE.md) to describe `narrative.md` and the native-memory framing.
22. **README + docs** feature descriptions.
23. **Deploy:** run `./install.sh` (hooks are not live until install.sh runs — discoveries.md lesson); verify `cs -doctor` drift check is clean and RETIRED_HOOKS removed the deployed reminder hook.

---

## Decisions (LOCKED 2026-06-15)
- **D1 — Migration scope:** AUTO-MIGRATE ON RESUME. When a session is reopened, cs folds its `discoveries.md` (+ compact) into `narrative.md` and adds the pointer. Lazy/per-session.
- **D2 — Filename:** `narrative.md` (matches the `type: narrative` the harness stamped).
- **D3 — Statusline:** DROP the `_seg_disc` segment entirely.
- **D4 — `discovery-commits.sh`:** RENAME to `autosave-commits.sh` (RETIRED_HOOKS the old name + add the new) — it is general all-file crash recovery, not discoveries-specific.

## Risks
- **Native recall surfacing narrative into future sessions** (narrative.md is now `node_type: memory`). Possible bonus (auto-recalled resume context) or mild bar-blur. Observe; no action unless it bites.
- **Large blast radius across tests + Rust TUI.** Mitigated by phased, independently-revertible commits and TDD.
- **Existing-session data loss during migration.** Mitigated by fold (not overwrite) + the shadow-ref autosave covering all files.
