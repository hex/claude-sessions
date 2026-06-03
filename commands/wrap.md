Wrap up this session: distill durable memory entries, then write a comprehensive summary. Run both passes back-to-back.

You are working in a cs session. The user has signaled they're winding down. Do both distillation passes in order — memory first (so durable facts land in the right place before the narrative absorbs them), summary second (so the narrative reflects the final state including any memory entries just written).

## Pass 1 — Memory distillation (strict bar, default write nothing)

Review the conversation in your context. For each of the four auto-memory categories (`user`, `feedback`, `project`, `reference`), ask: is there a durable fact that meets ALL three bars?

- **Durable** — still true or still relevant in three months. Not "I'm tired today." Not "we tried approach X for this one PR."
- **Surprising or non-obvious** — not derivable from the code, the README, or what a future session would already know from CLAUDE.md.
- **Future-relevant** — a future session would change a decision because of it. If you can't picture that concretely, skip.

Most sessions yield nothing here. Default no. Don't reach.

For each memory entry you do write:

- Read the matching `.cs/memory/<bucket>_*.md` first to check for duplicates. Any form — paraphrase, near-duplicate, superset — counts as a hit; skip those.
- INTERPRET, don't transcribe. Distill in your own paraphrase, capturing the essence and (where useful) the why.
- Follow the standard auto-memory format (frontmatter with `name` / `description` / `type`, then concise prose body).
- One entry per durable fact. If a fact plausibly fits two buckets, pick the more specific.

The session's `CLAUDE.md` has the bucket-guidance signal-phrase table — apply it. See `commands/sweep.md` for the full discipline if needed.

## Pass 2 — Session summary (comprehensive narrative)

Read these files end to end:

- `.cs/README.md` (objective, environment, outcome)
- `.cs/discoveries.md` (findings and observations)
- `.cs/discoveries.compact.md` (if exists — condensed older findings)
- `.cs/changes.md` (auto-logged file modifications)
- `.cs/artifacts/MANIFEST.json` (created files)

Synthesize them into a cohesive narrative at `.cs/summary.md`. Use this structure:

```markdown
# Session Summary: [SESSION_NAME]

**Date:** [Session date]
**Duration:** [Approximate duration if determinable]

## Objective

[What was the goal of this session?]

## Environment

[System/server/context]

## Key Discoveries

[Important findings with brief explanations]

## Changes

[Files modified / fixes applied]

## Artifacts

[Notable scripts/configs in .cs/artifacts/]

## Outcome

[What was accomplished, what's open]
```

If `.cs/summary.md` already exists, this run **replaces** it — `/wrap` writes the canonical end-of-session narrative.

## Pass 3 — Prose-quality gate (run before the report)

Before reporting, gate the prose written in passes 1 and 2:

1. **Lexical (deterministic):** run `cs -lint .cs/summary.md .cs/memory/*.md` and fix every em-dash and flagged phrase. The prose-lint Stop hook enforces this on turn-end; clearing it now avoids the block.
2. **Structural (independent judge):** use the Task tool to spawn a subagent as an impartial prose critic of `.cs/summary.md`. The subagent MUST read `~/.claude/skills/prose-hygiene/SKILL.md` and apply EVERY rule in it (the full taxonomy of phrases, structures, voice rules, and the scoring rubric). It only judges, never edits. It returns a 1-10 score for each of the five dimensions (Directness, Rhythm, Trust, Authenticity, Density; total out of 50) and, for every violation, the quoted text, the rule it breaks, and a concrete rewrite. Apply the rewrites whenever the total is below 35/50 or any rule is violated, then continue.

## Report

Output a brief two-line report. No long prose; the summary IS the prose.

1. **Memory:** list the file paths you wrote in pass 1, one per line. Or write `nothing to add` if the session didn't warrant memory entries.
2. **Summary:** confirm `.cs/summary.md` was created.

That's it. Don't recap the conversation; the summary file does that already.
