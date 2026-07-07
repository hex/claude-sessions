---
model: claude-sonnet-5
---

Generate an intelligent summary of this cs session by synthesizing all documentation files.

You are working in a cs session. Your task is to create a comprehensive summary of the entire session by reading and synthesizing all documentation files.

## Steps

1. **Read all session documentation:**
   - .cs/README.md (objective, environment, outcome)
   - .cs/memory/narrative.*.md (per-actor lab notebooks — read all of them: findings, observations, in-progress state)
   - .cs/timeline.jsonl (structured session events: starts, ends, checkpoints)

2. **Synthesize into a cohesive summary** that tells the story of this session. The summary should:
   - Explain what you were trying to accomplish
   - Describe the environment and context
   - Highlight key discoveries and insights
   - Summarize the changes and modifications made
   - List notable files or outputs produced — bound the git log to this session with the earliest `started` event's timestamp in `.cs/timeline.jsonl` (e.g. `git log --since=<that timestamp> --stat`), so you attribute only this session's work
   - Conclude with the outcome and results

3. **Write the summary to .cs/summary.md** in the session metadata directory. If `.cs/summary.md` already exists, replace it — this command always writes the canonical current summary. Use this structure:

```markdown
# Session Summary: [SESSION_NAME]

**Date:** [Session date]
**Duration:** [Approximate duration if determinable]

## Objective

[What was the goal of this session?]

## Environment

[What system/server/context were you working in?]

## Key Discoveries

[What did you learn? List important findings with brief explanations]

## Changes Made

[What modifications were made? Organize by category if appropriate]

## Key Files & Outputs

[List notable files created or changed during the session — derive from the session-bounded git log and your own record — with brief descriptions]

## Outcome

[What was accomplished? Were objectives met? What's the current state?]

## Notes for Future Reference

[Any important context or gotchas for future work]
```

`[SESSION_NAME]` = the session name from `.cs/README.md`'s title; fall back to the session directory name.

4. **Make the summary narrative and insightful**, not just a concatenation of files. Explain the "why" behind discoveries and changes. Connect related pieces of information.

5. **Gate the prose on quality before finalizing** (two layers):
   - **Lexical (deterministic):** run `cs -lint .cs/summary.md` and fix every em-dash and flagged phrase it reports. The prose-lint Stop hook enforces this on turn-end anyway; clearing it now avoids the block.
   - **Structural (independent judge):** spawn a subagent as an impartial prose critic of `.cs/summary.md`:
     - **Spawn:** Task tool, `model: opus`, `subagent_type: general-purpose`. Put every requirement below verbatim in its prompt — it starts with no context: the absolute paths to both `.cs/summary.md` and the skill, "judge only, never edit", and the exact final-message contract (scores, then the numbered violation list, then the verdict, nothing else).
     - **Reading:** it MUST read `~/.claude/skills/prose-hygiene/SKILL.md` and apply EVERY rule (the full taxonomy of phrases, structures, voice rules, and the scoring rubric).
     - **Judge only, never edit.** Its final message contains only the deliverable: the per-dimension scores and total from the skill's rubric, then a numbered list giving, for every violation, the quoted text, the rule it breaks, and a concrete rewrite, then a final line reading `PASS` or `REVISE` (its total against the skill's revise threshold). No preamble, nothing else.
     - **Apply + re-run:** apply every rewrite it returns to `.cs/summary.md`. If its verdict was `REVISE`, run the critic once more after applying them; after that second run, apply its rewrites and stop regardless of verdict. Whenever you apply rewrites, re-run `cs -lint .cs/summary.md` afterward and fix anything the edits introduced before moving to step 6.

6. **Inform the user** when the summary is complete and where it was saved.

## Important

- Read ALL documentation files completely before writing the summary
- If files are empty or minimal, note what was not documented
- The summary should be understandable by someone who wasn't present in the session
- If the session is still in progress, note that in the summary
