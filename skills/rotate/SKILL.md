---
model: fable
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
   that is writing this handoff — step 7 supersedes by matching it against
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
   live conversation: 1. Next Step; 2. Settled and rejected; 3. Primary
   Request and Intent; 4. Key Technical Concepts; 5. Files and Code Sections
   (with the snippets that matter); 6. Problem Solving; 7. Pending Tasks;
   8. Current Work. Write for a successor with zero conversation memory.
   Under cs the native task list is keyed to the session, not to this
   conversation (`CLAUDE_CODE_TASK_LIST_ID` is the session name), so it
   survives the `/clear` and the successor inherits it. Pending Tasks still
   lists every open native item with its status: the handoff has to read
   whole on its own, and the successor reconciles the list it inherited
   against what you wrote rather than mirroring the handoff into it.

   **Next Step opens the body.** The successor is told to execute it, and
   retrieval degrades over a long document — so the thing it needs first must
   not be the thing it finds last.

   **Settled and rejected** holds decisions already made, alternatives
   rejected with the reason they lost, and approaches tried that failed with
   the symptom they failed on. Write `none` when there is nothing, rather
   than dropping the heading: an empty section stated is a claim, a missing
   one is indistinguishable from a section the writer ran out of context to
   fill. This section exists because these facts have no other home — a
   commit carries what was done and never what was rejected, so a successor
   without them re-opens settled questions and retries dead ends with less
   information than the person who first decided.

   Two rules govern the body, both following from where it goes — step 4
   commits it, and the next conversation reads it as its opening prompt:

   - **Redact.** API keys, tokens, passwords and personally identifying
     information that surfaced in the conversation stay out of the file.
     `.cs/handoffs/` is tracked, so writing one here publishes it, and cs's
     own protocol is that credentials live in `cs -secrets`, never in a
     file. Name the secret's purpose instead: "the deploy token, in
     `cs -secrets get DEPLOY_TOKEN`". Re-read the finished body before step 4
     commits it: the rule below asks for exact readings written down as they
     were, and an exact reading is where a secret hides.
   - **Reference committed work; restate what a successor cannot recover.**
     Work captured in a commit, spec, plan, diff or narrative gets a path and
     a one-line pointer: re-summarising it spends the successor's opening
     context on what it can read for itself, and a summary drifts from the
     file while the path does not. But a fact that exists nowhere else has no
     path to point at — a rejected alternative and the reason it lost, an
     exact reading taken while debugging, a run identifier, a count observed
     at one moment, the order two events actually happened in. Write those
     down as they were, or they are gone with the conversation. Length spent
     on them is not padding; it is how many of them survive. Be complete on
     these even at the cost of length, and keep everything else concise: a
     body that is long everywhere buries the facts it was written to carry.
   - **Keep the user's words; condense your own.** The body carries two
     voices, and they do not compress equally. What the user said, asked
     for, shared or established stays careful and close to their own words:
     a correction paraphrased is a correction drifted, and the successor has
     no way back to the original. Your own explanations and reasoning can be
     condensed much further, to what they concluded or produced.
   - **Say how each behavioural claim was established.** A claim read off a
     README and a claim measured live look identical to a successor with zero
     memory of how either was learned, and it will build on both equally.
     Mark each: measured (with the reading), read in source (with the path),
     inherited from a prior handoff or a reviewer, or assumed. When you cannot
     recall which, `assumed` is the honest answer and costs nothing. This is
     not hypothetical — a handoff in this store asserted that a tool rewrote
     its input, and its successor recorded: "It does not. I built an entire
     investigation on that unchecked characterisation."
   - **Say what you could not carry.** Rotation runs when context is already
     hot, and a compaction can land before you finish writing — in which case
     you are distilling a summary, not the conversation, and the exact facts
     above are already lost.

     So write the body in TWO passes, and make the first one durable. The
     first Write carries the frontmatter, Next Step, Settled and rejected,
     and every conversation-only fact — the material that dies with the
     conversation. Commit that (step 4) before continuing. The second pass
     then APPENDS the remaining sections (step 5) — recoverable from the
     repo if this rotation never finishes — and lands as a second commit.

     Append, never a second Write: a Write replaces the whole file, so it
     re-emits pass one from whatever context you have by then, and a
     compaction between the two passes is exactly the case this guards
     against. And never amend: the first commit is the only faithful copy of
     pass one, and an amend replaces it.

     Ordering the sections in your head does nothing: a Write lands whole or
     not at all, so a compaction between distilling and writing takes
     everything. Only a committed first pass survives it.

     If you end up working from compacted context, or you cut the body short,
     say so in the handoff: a thin handoff that admits it is thin beats one
     the successor trusts.
4. Commit the first pass. Stage the handoff by name. Re-read the body for
   secrets first (the Redact rule above) — the same re-read runs again before
   step 6, because pass two is where exact readings live.
5. Append the second pass with Edit or `cat >>`, never Write.
6. Second commit for the appended body. Re-read it for secrets first.

   The handoff's CONTENT is now safe: two commits, nothing left to lose. It
   is not yet armed — that is deliberate, see step 9.
7. Retire this machine's leftovers: for every OTHER file in `.cs/handoffs/`
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
   step 9 arms is the exception — it names one handoff explicitly and the
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
   deletions with step 8's commit.
8. Commit the supersedings and any tracked session state, like narratives.
   Stage those paths by name.
9. Arm it, LAST: write its basename (no path) to `.cs/local/pending-handoff`.
   Machine-local state — never commit it.

   Arming is the final step because an armed marker is fragile in a way a
   committed file is not. If Claude Code exits before the ritual finishes and
   the user relaunches, `cs <name>`'s prompt disarms the marker on `Y`, `n`
   or Enter (lib/75-launch.sh), and nothing re-arms it; a later `/clear`
   then opens a bare conversation with this handoff left `unconsumed`. The
   launch prompt recovers either state — it scans the store and offers an
   unconsumed handoff with `r` whether or not it was armed — but only the
   marker makes `/clear` continue, and only an interrupted ritual leaves a
   disarmed one behind. So arm once nothing remains that could be
   interrupted.
10. Tell the user what the rotation now does on its own: the fresh
   conversation picks up this handoff and begins its next step by itself, a
   couple of seconds after the `/clear` — they do not need to type anything
   to start it, and a message they do send takes precedence over the handoff.

   If they would rather stop for the day, exiting and answering `r` at the
   next `cs <session-name>` launch does the same thing. Answering `Y` or `n`
   there disarms the marker (the handoff itself stays pending, so a later
   rotate can re-arm it), and `d` discards the handoff outright.

11. End your response with the instruction and nothing after it, on its own
   final line, exactly:

   **Run `/clear` now** — this conversation is ready to rotate.

   This is the one step nothing can take for the user. A hook cannot submit
   to Claude Code's command queue (it accepts the TUI's own input only), so
   the keystroke is always theirs — which is why it must not end up buried
   under a summary of what you just wrote.
