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

1. Determine the parent conversation UUID: the `claude_session_id` line of
   `.cs/local/state`, or if that is missing, `$CS_CLAUDE_SESSION_ID`.

   Take the state file first. `CS_CLAUDE_SESSION_ID` is the *launch* UUID —
   cs exports it once per process and never refreshes it, because the
   SessionStart hook keys its ref-rename guard on that value still naming
   this process's predecessor. The hook rebinds `claude_session_id` on every
   fresh conversation, so the two agree only until the first `/clear`. After
   that the env var names an ancestor, and `parent:` must be the conversation
   that is writing this handoff — step 4 supersedes by matching it against
   the session log.
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

   Two rules govern the body, both following from where it goes — step 5
   commits it, and the next conversation reads it as its opening prompt:

   - **Redact.** API keys, tokens, passwords and personally identifying
     information that surfaced in the conversation stay out of the file.
     `.cs/handoffs/` is tracked, so writing one here publishes it, and cs's
     own protocol is that credentials live in `cs -secrets`, never in a
     file. Name the secret's purpose instead: "the deploy token, in
     `cs -secrets get DEPLOY_TOKEN`".
   - **Reference committed work; restate what a successor cannot recover.**
     Work captured in a commit, spec, plan, diff or narrative gets a path and
     a one-line pointer: re-summarising it spends the successor's opening
     context on what it can read for itself, and a summary drifts from the
     file while the path does not. But a fact that exists nowhere else has no
     path to point at — a rejected alternative and the reason it lost, an
     exact reading taken while debugging, a run identifier, a count observed
     at one moment, the order two events actually happened in. Write those
     down as they were, or they are gone with the conversation. Length spent
     on them is not padding; it is how many of them survive.
   - **Say what you could not carry.** Rotation runs when context is already
     hot, and a compaction can land before you finish writing — in which case
     you are distilling a summary, not the conversation, and the exact facts
     above are already lost. Write the next step and the conversation-only
     facts first, while fidelity is highest. If you end up working from
     compacted context, or you cut the body short, say so in the handoff:
     a thin handoff that admits it is thin beats one the successor trusts.
4. Retire this machine's leftovers: for every OTHER file in `.cs/handoffs/`
   whose frontmatter still says `status: unconsumed`, flip that one
   frontmatter line to `status: superseded` — but only when its `parent:`
   UUID appears in `.cs/local/session.log`, which records every conversation
   this checkout has run (`Session started (... ID: <uuid>)`).

   That file is machine-local, which is the whole point of using it.
   `.cs/handoffs/` is shared, so a handoff whose parent is absent from the log
   belongs to a co-worker's checkout, may be armed right now, and must be left
   alone — superseding it would silently drop their rotation.

   Without this step an abandoned handoff stays pending forever, and the
   launch prompt keeps offering `[Y/n/r/d]` for context that is out of date.
   Do not assume a newer handoff simply outranks it: among files the launcher
   has to choose between, it picks the lexicographically last basename, so
   among same-day files the slug decides and a stale one can win. The marker
   step 6 arms is the exception — it names one handoff explicitly and the
   launcher honors it over that scan — but it covers only the file this
   rotation is arming, not the leftovers this step retires.

   Then prune what is spent. A `consumed`, `discarded` or `superseded` handoff
   has done its job, and git history keeps it after the file is gone, so
   nothing is lost by dropping it. Delete one only when all three hold:

   - its `status:` is one of those three — never `status: unconsumed`, which
     may be a co-worker's armed rotation and is not yours to drop;
   - its `created:` date is more than 30 days before today;
   - it is not among the 10 newest handoffs in the directory by `created:`,
     counting every handoff whatever its status, so a week of heavy rotation
     never empties the store.

   Take the age from `created:` in the frontmatter, never the file's mtime.
   `.cs/handoffs/` is shared, and a clone stamps every file with its checkout
   time: mtime would read as "all new" on a fresh machine and prune nothing,
   while saying nothing about when the handoff was written. Stage the
   deletions with step 5's commit.
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
