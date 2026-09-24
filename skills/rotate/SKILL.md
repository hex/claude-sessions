---
model: opus
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
should do. If the user did not give one, take it from the conversation: the
work in flight and its next step. Do not stop to ask; the `cs` mod's
button runs `/rotate` with no argument, and a question there would defeat the
one-key rotation it exists for.

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

   The body is the template below, copied and filled in. Keep every
   heading and every slot label, in this order; replace each `<...>` with
   what it asks for, and write `none` in a slot that has nothing rather
   than dropping it: an empty slot stated is a claim, a missing one is
   indistinguishable from a slot the writer ran out of context to fill.
   Write for a successor with zero conversation memory, who acts on
   1. Next Step without looking anything up and trusts every line equally
   unless the line tells it not to.

   ```
   # 1. Next Step
   Goal: <one line: what finishing this step achieves>
   Where: <host, checkout path, branch, and the commit it should be at>
   Check first: <command that shows whether this is already done or
     still running> -> done if <what it prints>; running if <what it prints>
   If done: <what to do instead>
   If running: <what to do instead; never start a second copy>
   Then run: <the exact command(s), with every flag and path inline>
   Expect: <what success prints and roughly how long it takes>
   If it fails: <the known failure modes, and the recovery for each>
   After: <the step that follows, one line>
   Ask the user before: <anything in this step that is theirs to decide>

   # 2. Settled and rejected
   - DECIDED: <decision> | by: <user, quoted; or you, with why> | <date>
   - REJECTED: <alternative> | lost because: <reason> | by: <who>
   - FAILED: <approach tried> | symptom: <command -> what it printed>

   # 3. Conversation-only facts
   ## User's words
   - "<verbatim quote>" -- <what it answered or ruled on>
   ## Identifiers
   - <label>: <run/job/commit/PR/pid/branch/host/path> = <value> -- <what it is>
   ## Readings
   - <label>: <what was measured> = <exact value> (<when, and by what command>)
   ## Errors
   - <label>: `<command>` printed `<verbatim line>` -- <what it meant>
   ## Not verified
   - assumed: <claim the work relies on that nobody checked> -- <how to check>
   ## Traps
   - <thing a successor would naturally believe or do that is wrong here>
     -- <why, and what to do instead>

   # 4. Primary Request and Intent
   # 5. Key Technical Concepts
   # 6. Files and Code Sections
   # 7. Problem Solving
   # 8. Pending Tasks
   # 9. Current Work
   Completeness: <from live context or from a compacted summary; what you
     could not carry>
   ```

   Slot rules:

   - **1. Next Step opens the body** because retrieval degrades over a long
     document and the successor executes it first. Every slot is filled
     inline, even when the same fact is in a committed file, an older
     handoff or memory: the successor acts without looking anything up.
     "Check first" exists because an action that starts work (a test run,
     a build, a merge, a deploy) must say how to tell whether it is
     already done or still running, and what to do in each case; "rerun the suite"
     with no check starts a second run beside one that may still be going.
   - **Settled and rejected** has one line per decision, every alternative
     rejected with the reason they lost, and every approach that failed
     with the symptom it failed on. A commit carries what was done and
     never what was rejected.
   - **3. Conversation-only facts** holds everything that dies with this
     conversation. Before step 4 commits pass one, list from memory every
     exact reading, identifier, error, user statement and unchecked claim
     the conversation produced, and check each one off against a slot;
     add what is missing. One fact per line; length spent here is how many
     facts survive, so keep everything else concise.
   - **The label says how each claim was established**, and it goes
     on the claim, not on the bullet or heading above it: `measured` (you
     ran it; the command and reading are on the line), `read in source` (path), `inherited`
     (from a prior handoff, memory or a reviewer), `user` (quoted), or
     `assumed`. A cause inferred from a measured symptom is `assumed`. A
     claim that something fails, is unavailable or does not work carries
     the command that failed and what it printed, or it is `assumed`.
     When you cannot recall which, `assumed` is the honest answer.
   - **User's words** stay close to their own words: a correction
     paraphrased is a correction drifted. Your own reasoning condenses to
     what it concluded.
   - **Traps** is for the mistakes a capable newcomer would make here: a
     plausible command that targets the wrong host, a file that looks
     stale but is load-bearing, a result that looks final but was noise.
   - **Sections 4-9** are short pointers. Under cs the
     native task list is keyed to the session, not to this conversation
     (`CLAUDE_CODE_TASK_LIST_ID` is the session name), so it survives the
     `/clear` and the successor inherits it; 8. Pending Tasks still lists
     every open native item with its status, since the handoff must read
     whole on its own.
   - **Redact.** API keys, tokens, passwords and personally identifying
     information stay out of every slot. `.cs/handoffs/` is tracked, so
     writing one here publishes it; credentials live in `cs -secrets`.
     Name the secret's purpose instead: "the deploy token, in
     `cs -secrets get DEPLOY_TOKEN`".
     Re-read the finished body before step 4 commits it: an exact
     reading is where a secret hides.
   - **Reference committed work; restate what a successor cannot recover.**
     Work captured in a commit, spec, plan, diff or narrative gets a path
     and a one-line pointer. A pointer to a script or command
     says in one clause what it does when run, read from the script
     itself rather than remembered.
   - **Completeness**: when you worked from compacted context or cut
     anything short, say so in the handoff: a thin handoff that admits
     it is thin beats one the successor trusts.

   Write the body in TWO passes, and make the first one durable, because
   rotation runs when context is hot and a compaction can land before you
   finish. The first Write carries the frontmatter and sections 1-3, the
   material that dies with the conversation; commit that (step 4). The
   second pass then APPENDS sections 4-9 (step 5) and lands as a
   second commit. Append, never a second Write: a Write replaces the
   whole file and re-emits pass one from whatever context you have by then. Never
   rewrite the first commit either; it is the only faithful copy of pass
   one.
4. Commit the first pass. Stage the handoff by name. Re-read the body for
   secrets first (the Redact rule above) — the same re-read runs again before
   step 6, because pass two quotes files and code, and a secret can sit in
   either.
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
   nothing is lost by dropping it. Delete one only when all four hold:

   - its `status:` is one of those three — never `status: unconsumed`, which
     may be a co-worker's armed rotation and is not yours to drop;
   - its `created:` date is more than 30 days before today;
   - it is not among the 10 newest handoffs in the directory by `created:`,
     counting every handoff whatever its status, so a week of heavy rotation
     never empties the store;
   - it has no uncommitted changes (`git status --porcelain -- <file>`
     prints nothing). The conversation that consumed a handoff appends its
     `## Successor report` to it, and git history keeps only what was
     committed.

   Take the age from `created:` in the frontmatter, never the file's mtime.
   `.cs/handoffs/` is shared, and a clone stamps every file with its checkout
   time: mtime would read as "all new" on a fresh machine and prune nothing,
   while saying nothing about when the handoff was written. Stage the
   deletions with step 8's commit.
8. Commit the supersedings, every consumed handoff whose uncommitted change
   is a `## Successor report` appended by the conversation that took it
   over, and any tracked session state, like narratives. Stage those paths
   by name.
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

   **Run `/clear` now** (or press `1` on the capsule above the prompt) — this conversation is ready to rotate.

   This is the one step you cannot take for the user. A hook cannot submit
   to Claude Code's command queue (it accepts the TUI's own input only); the
   `cs` mod's button can, and once the marker is armed it reads
   `1: /clear and continue from the handoff`. The keystroke is theirs unless
   they launched with `CS_ROTATE_FORCE_CTX`, when the mod counts twenty
   seconds down and runs the `/clear` itself — which is why the line must not
   end up buried under a summary of what you just wrote.
