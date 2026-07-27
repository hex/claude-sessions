---
name: rotate
description: Rotate the current cs conversation - write a lineage-stamped handoff to .cs/handoffs/, arm it, and tell the user to run /clear so a fresh conversation continues from it. Invoke when the user asks to rotate, or accepts a context-heavy rotation suggestion.
---

Rotation ends this conversation's useful life deliberately: you distill the
work into a handoff file and arm it, and the next fresh conversation — most
easily one the user starts with `/clear`, without leaving Claude Code —
continues from it. This skill writes the handoff and the pending marker. It
never ends the conversation and never launches anything.

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
4. Retire your own leftovers: for every OTHER file in `.cs/handoffs/` whose
   frontmatter still says `status: unconsumed`, flip that one frontmatter
   line to `status: superseded`. An older pending handoff otherwise keeps the
   launch prompt offering `[Y/n/r/d]` for context that is out of date.
5. Commit the handoff and any supersedings (tracked session state, like
   narratives). Stage those paths by name.
6. Arm the handoff: write its basename (no path) to
   `.cs/local/pending-handoff`. This is machine-local state — do not commit
   it, and do not stage it in step 5.
7. Tell the user: run `/clear` to rotate now — the fresh conversation picks
   up this handoff automatically, without leaving Claude Code. It will not
   act until they send their next message, which can simply be what they want
   done next.

   If they would rather stop for the day, exiting and answering `r` at the
   next `cs <session-name>` launch does the same thing. Answering `Y` or `n`
   there disarms the marker (the handoff itself stays pending, so a later
   rotate can re-arm it), and `d` discards the handoff outright.
