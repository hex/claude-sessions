---
model: claude-sonnet-5
---

Wrap up this session: distill durable memory entries, then write a comprehensive summary. Run the two passes back-to-back, then a shared prose-quality gate.

You are working in a cs session. The user has signaled they're winding down. Do the passes in order — memory first (so durable facts land in the right place before the narrative absorbs them), summary second (so the narrative reflects the final state including any memory entries just written).

Each pass is owned by its own command file. Read that file and apply it — do not work from a remembered paraphrase. This command adds only the ordering, one gate extension, and the combined report.

## Pass 1 — Memory distillation

Read `~/.claude/commands/sweep.md` and execute it end to end: the strict bar with its bucket routing table, the dedup and `MEMORY.md` index rules, and the looser-bar narrative sweep. Skip its final report; the combined report below replaces it.

## Pass 2 — Session summary

Read `~/.claude/commands/summary.md` and execute its steps 1-4: read all the session documentation it lists (including the per-actor `.cs/memory/narrative.*.md` notebooks) and synthesize the narrative at `.cs/summary.md` using its structure. If `.cs/summary.md` already exists, this run **replaces** it — `/wrap` writes the canonical end-of-session narrative.

## Pass 3 — Prose-quality gate

Apply summary.md's two-layer prose gate (its step 5) with one extension: the lexical lint also covers the memory entries written in Pass 1 — run `cs -lint .cs/summary.md` plus each `.cs/memory/` file you wrote. Never lint `.cs/memory/MEMORY.md` or the narrative notebooks (`narrative*.md`): both are excluded by the prose-lint Stop hook — the index for its prescribed format, the append-heavy notebooks because they need line-level diffing, not whole-file lint.

## Report

Output a brief two-section report (the two labeled items below). No long prose; the summary IS the prose.

1. **Memory:** list the file paths you wrote in Pass 1, one per line. Or write `nothing to add` if the session didn't warrant memory entries.
2. **Summary:** confirm `.cs/summary.md` was created.

That's it. Don't recap the conversation; the summary file does that already.
