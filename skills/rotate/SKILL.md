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

   The body is a continuation plan with these sections, distilled from the
   live conversation: 1. Next Step; 2. Settled and rejected;
   3. Conversation-only facts; 4. Primary Request and Intent; 5. Key Technical
   Concepts; 6. Files and Code Sections (with the snippets that matter);
   7. Problem Solving; 8. Pending Tasks; 9. Current Work. Write for a
   successor with zero conversation memory.
   Under cs the native task list is keyed to the session, not to this
   conversation (`CLAUDE_CODE_TASK_LIST_ID` is the session name), so it
   survives the `/clear` and the successor inherits it. Pending Tasks still
   lists every open native item with its status: the handoff has to read
   whole on its own, and the successor reconciles the list it inherited
   against what you wrote rather than mirroring the handoff into it.

   **Next Step opens the body.** The successor is told to execute it, and
   retrieval degrades over a long document — so the thing it needs first must
   not be the thing it finds last. It carries every fact its first action
   needs, inline: the exact command, path, host, branch or flag. Include them
   even when the same fact is in a committed file, an older handoff or
   memory: the successor acts on Next Step before reading anything else,
   without looking anything up. A handoff that said "rerun the suite" sent
   it to the local machine while the working host sat in memory the
   successor never read. An action that starts work (a test run, a build,
   a merge, a deploy) first says how to tell whether it is already done or still running,
   and what to do in each case: "rerun the suite if its result file has no
   `rc=` line" starts a second full run beside one that may still be going.

   **Settled and rejected** holds decisions already made, alternatives
   rejected with the reason they lost, and approaches tried that failed with
   the symptom they failed on. Write `none` when there is nothing, rather
   than dropping the heading: an empty section stated is a claim, a missing
   one is indistinguishable from a section the writer ran out of context to
   fill. This section exists because these facts have no other home — a
   commit carries what was done and never what was rejected, so a successor
   without them re-opens settled questions and retries dead ends with less
   information than the person who first decided.

   **Conversation-only facts** holds everything else that dies with this
   conversation: exact readings and error text, run and job identifiers,
   counts observed at one moment, the order events happened in, and what the
   user said that no file records. One fact per line, each with its
   provenance label (below). Before step 4 commits pass one, list from memory
   every such fact the conversation produced, and check each one off against
   this section or Settled and rejected; add what is missing. Write `none`
   when there is nothing, as for Settled and rejected.

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
     down as they were, or they are gone with the conversation. A pointer to
     a script or command says in one clause what it does when run, read
     from the script itself rather than remembered: "use `drive.sh`" sent a
     successor to a script that launched bare `claude` where it expected a
     cs session. Length spent
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

     The label goes on the claim, not on the bullet or heading it sits
     under: a cause you inferred from a measured symptom is `assumed`, even
     inside a bullet headed MEASURED. A claim that something fails, is
     unavailable or does not work carries the command that failed and what
     it printed; without them it is `assumed`. Across 40 handoffs "measured"
     appeared in 38 and "assumed" in one, and the two wrong claims found
     were both unlabelled conclusions.
   - **Say what you could not carry.** Rotation runs when context is already
     hot, and a compaction can land before you finish writing — in which case
     you are distilling a summary, not the conversation, and the exact facts
     above are already lost.

     So write the body in TWO passes, and make the first one durable. The
     first Write carries the frontmatter, Next Step, Settled and rejected,
     and Conversation-only facts — the material that dies with the
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

   - **Cold-read test before each commit.** You cannot see your own gaps
     by re-reading: you fill them from memory without noticing. So test
     the draft the way the successor will use it. After pass one is
     written, and before step 4 commits it:

     1. Write down, from the conversation (not from the draft), 20 short
        questions a successor would have to get right to continue without
        a mistake. Make them specific and hard, one fact each: the exact
        value of a reading; which run, commit, host or branch; what the
        user ruled on something, in their words; which option was rejected
        and why; what failed and what it printed; which belief was never
        checked; whether something is finished, running or not started,
        and how to tell. Cover every stretch of the conversation, not only
        its end.
     2. Answer each question using ONLY the handoff text, as a stranger
        would: no memory, no inference beyond what the words say.
     3. Every question the text cannot answer, answers vaguely, or answers
        differently from what actually happened is a defect. Fix each one
        in the draft (add the fact, the provenance label, the verbatim
        quote, the "not verified" mark) before committing.

     Keep the questions out of the handoff; they are your test, not its
     content. Run the same test on pass two before the second commit,
     with questions about files, concepts and pending work.
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
