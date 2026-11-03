---
model: opus
---

Wrap up this session: distill durable memory entries, write a comprehensive summary, then rotate the narrative and archive completed task rows. Run the passes back-to-back and report.

You are working in a cs session. The user has signaled they're winding down. Do the passes in order — memory first (so durable facts land in the right place before the narrative absorbs them), summary second (so the narrative reflects the final state including any memory entries just written), rotation third (so the summary was written from the whole live narrative before its oldest sections leave it).

The first two passes are owned by their own files, which cs installs beside its hooks. Read each with the Read tool, one call per file (not `cat` through Bash, whose zsh can stop a command list part-way), and apply it — do not work from a remembered paraphrase. This command adds only the ordering and the combined report.

## Pass 1 — Memory distillation

Read `~/.claude/hooks/cs/wrap-sweep.md` and execute it end to end: the retro that lists where the session struggled and files one task per fix, the strict bar with its bucket routing table, the dedup and `MEMORY.md` index rules, and the looser-bar narrative sweep. Skip its final report; the combined report below replaces it.

## Pass 2 — Session summary

Read `~/.claude/hooks/cs/wrap-summary.md` and execute it end to end: read the session documentation it lists (your own `.cs/memory/narrative.<actor>.md` in full; a teammate's only from the line the resume digest named, never whole) and synthesize the narrative at `.cs/summary.md` using its structure. If `.cs/summary.md` already exists, this run **replaces** it — `/wrap` writes the canonical end-of-session narrative.

The pass has no review step, so write the summary well the first time rather than planning to revise it.

## Pass 3 — Narrative rotation

Run `cs -narrative rotate` once and keep its single output line. It archives the oldest `## ` sections of your narrative verbatim into `.cs/narrative-archive/<actor>/` (in an encrypted session, into the vault) when the live file is over its byte budget, and prints `nothing to rotate` otherwise. Do not read or edit the narrative yourself for this pass; the helper does the byte-exact cut and commits nothing.

## Pass 4 — Task archive

Archive the native task list's completed rows, exactly as the rotate skill's step 8 does: read `~/.claude/skills/rotate/SKILL.md` step 8 with the Read tool and follow its first part, the `cs -archive-tasks plan` answer and the one question it may ask (`/wrap` is never a forced rotation: ask as step 8 does for `forced: no`, whatever the plan's `forced:` line says). A refusal moved nothing and does not fail the wrap; report its line.

The wrap makes no commit. The memory entries, `.cs/summary.md`, the narrative cut and the task archive stay on disk, uncommitted: cs commits files under `.cs/` only in the commit that creates a session and the merge `/finish` makes, and you commit them only when the user asks.

## Pass 5 — Mark the wrap finished

Run this once, from the session root, only after the four passes above completed:

```sh
if [ -n "$CLAUDE_CODE_SESSION_ID" ] && cs -vet-session . >/dev/null; then
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID" > .cs/local/wrapped
fi
```

It names the conversation this wrap finished in (its own id, so a teammate's wrap never marks the lead), so the cs mod's band stops offering `wrap` until the next prompt. Skip it if any pass failed: a wrap that did not finish should stay one key away. While git tracks the session's control files, cs says so and the pass writes nothing; the wrap still finished.

## Report

Output a brief report with the five labeled items below. No long prose; the summary IS the prose.

1. **Memory:** list the file paths you wrote in Pass 1, one per line, each ending as the sweep's step 7 says: `supersedes: <file>`, `supersedes: none`, or `updated in place`. Or write `nothing to add` if the session didn't warrant memory entries.
2. **Retro:** one line per task the sweep's retro filed, its fix and the moment behind it, or `nothing to fix` when the session listed no struggle.
3. **Summary:** confirm `.cs/summary.md` was created.
4. **Narrative:** the line `cs -narrative rotate` printed.
5. **Tasks:** the line `cs -archive-tasks run` printed, or why the archive was skipped (the session answered no, nothing to archive, or the `Error:` line).

That's it. Don't recap the conversation; the summary file does that already.
