---
name: rotate
description: Rotate the current cs conversation - write a lineage-stamped handoff to .cs/handoffs/ so the user can continue in a fresh conversation with context. Invoke when the user asks to rotate, or accepts a context-heavy rotation suggestion.
---

Rotation ends this conversation's useful life deliberately: you distill the
work into a handoff file, and the next `cs` launch offers the user a fresh
conversation seeded with it. This skill only WRITES the handoff — it never
ends the conversation, never edits .cs/local/state, and never launches
anything.

## Prerequisites

Only works in a cs session: check that `$CLAUDE_SESSION_NAME` is set. If
empty, tell the user rotation needs a cs session and stop.

A rotation needs a purpose — one line describing what the next conversation
should do. If the user did not give one, ask before writing anything.

## Process

1. Determine the parent conversation UUID: `$CS_CLAUDE_SESSION_ID`, or if
   unset, the `claude_session_id` line of `.cs/local/state`.
2. Pick a short kebab-case slug from the purpose (e.g. `continue-f5-plan`).
3. Write `.cs/handoffs/YYYY-MM-DD-<slug>.md` (today's date; create the
   directory if missing) with EXACTLY this frontmatter, then the body:

   ```
   ---
   parent: <parent-uuid>
   created: <ISO-8601 UTC timestamp>
   purpose: <the one-line purpose>
   status: unconsumed
   ---
   ```

   The body is a continuation plan with these sections, distilled from the
   live conversation: 1. Primary Request and Intent; 2. Key Technical
   Concepts; 3. Files and Code Sections (with the snippets that matter);
   4. Problem Solving; 5. Pending Tasks; 6. Current Work; 7. Next Step.
   Write for a successor with zero conversation memory.
4. Commit the handoff (it is tracked session state, like narratives).
5. Tell the user: exit this conversation, run `cs <session-name>`, and
   answer `r` at the "Continue previous conversation?" prompt to start
   fresh from this handoff. Until then the handoff stays pending; answering
   `Y` keeps this conversation resumable and the handoff waits.
