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

**Encrypted session.** When `.cs/private` exists, the session keeps its
handoffs in its vault: every `.cs/handoffs/` below means
`.cs/private/handoffs/`, step 9 arms `.cs/private/pending-handoff`, and the
session log is `.cs/private/session.log`. Git never tracks the vault, so
the prune's "git tracks it" rule keeps every handoff there. If `.cs/private` is a link to a missing directory, the
vault is locked: tell the user to mount it and stop.

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
   The slug is ASCII: lowercase letters, digits and hyphens only, at most 60
   characters. cs offers and loads only a handoff whose file name is plain and
   passes over any other.
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

   The body has nine sections, in this order, each under its numbered
   heading: 1. Next Step; 2. Settled and rejected; 3. Conversation-only
   facts; 4. Primary Request and Intent; 5. Key Technical Concepts; 6. Files
   and Code Sections (with the snippets that matter); 7. Problem Solving;
   8. Pending Tasks; 9. Current Work. Write for a successor with zero
   conversation memory. A section with nothing in it says `none` rather
   than disappearing: an empty section stated is a claim, a missing one is
   indistinguishable from a section the writer ran out of context to fill.
   Under cs the native task list is keyed to the session, not to this
   conversation (`CLAUDE_CODE_TASK_LIST_ID` is the session name), so it
   survives the `/clear` and the successor inherits it. Pending Tasks still
   lists every open native item with its status: the handoff has to read
   whole on its own, and the successor reconciles the list it inherited
   against what you wrote rather than mirroring the handoff into it.

   **Build the ledger before you write any prose.** A handoff is only as
   good as the facts that survive into it, and a writer who summarises from
   memory keeps whichever facts happen to be vivid. So the first thing you
   do is not writing: go back over the conversation from its first message
   to its last, in order, and at every user message and every tool result
   copy out each item below that it contains, except detail the Redact rule
   below names, which enters the ledger as a pointer. Copy, do not paraphrase: the
   successor will quote your ledger back as an answer, and a number
   rounded or an error reworded is a wrong answer.

   - **IDs**: run, job, task, PR, commit and conversation identifiers;
     branch, host, pid, port, tmux target; every path the conversation
     created or depended on.
   - **READINGS**: every number observed: counts, scores, sizes, timings,
     percentages, versions, exit codes, and the moment it was read at.
   - **ERRORS**: every failure, as the command that failed plus the text it
     printed, verbatim, trimmed to the line that matters.
   - **USER**: every request, ruling, correction, preference and answer the
     user gave, quoted in their own words, with what it answered. Keep them
     close to their own words; a correction paraphrased is a correction
     drifted, and the successor has no way back to the original.
   - **DECISIONS**: every choice made, every alternative
     rejected with the reason they lost, every approach tried that
     failed and the symptom it failed on.
   - **UNVERIFIED**: every claim the conversation relied on but never
     checked, every inference from a symptom, every "should" and "probably".
   - **STATE**: what is running, where, and how to tell whether it finished;
     what is uncommitted; what was promised and not done.

   Then check each one off as it lands in the body: DECISIONS go to Settled
   and rejected; IDS, READINGS, ERRORS, USER and UNVERIFIED go to
   Conversation-only facts; STATE feeds Next Step and Current Work. Nothing
   in the ledger may be dropped for length. The ledger is the part of the
   handoff that nothing else can recover; spend length on it and
   keep everything else concise.

   **1. Next Step opens the body.** The successor is told to execute it, and
   retrieval degrades over a long document, so the thing it needs first must
   not be the thing it finds last. It carries every fact its first action
   needs, inline: the exact command, path, host, branch or flag, even when
   the same fact is in a committed file, an older handoff or memory, because
   the successor acts on it without looking anything up. When the first
   action cannot start until the user answers, decides or supplies
   something, the blocker opens Next Step: the question to ask and the
   options already on the table, ahead of the steps it gates, and those
   steps written as branches on the answer, not a list to run through. A
   blocker listed after those steps reads as one more step. An action that
   starts work (a test run, a build, a merge, a deploy) first says how to
   tell whether it is already done or still running, and what to do in each
   case. An action that needs a clean worktree (a branch switch, a merge, a
   rebase) says the successor starts with this handoff uncommitted, like
   the other session files: nothing commits them, and session start
   flips its `status:` to `consumed`. It says to ask the user before
   committing or setting them aside.

   **2. Settled and rejected** is the DECISIONS ledger, one line each:
   `<decision or rejected alternative> | <who decided, with the user's words
   when it was the user> | <reason, or the symptom it failed on>`. A commit
   carries what was done and never what was rejected, so a successor without
   this re-opens settled questions. Write `none` when there is nothing.

   **3. Conversation-only facts** is the rest of the ledger, grouped under
   the category names above (IDS, READINGS, ERRORS, USER, UNVERIFIED), one
   fact per line, each line starting with its provenance label:

   - `measured:` you ran it and saw the result; give the command and the
     reading.
   - `read in source:` give the path (and line) you read it from.
   - `inherited:` from a prior handoff, memory or a reviewer; name which.
   - `user:` the user said it; quote them.
   - `assumed:` everything else, including every UNVERIFIED line and every
     cause inferred from a measured symptom.

   Say how each claim was established: a claim read off a README and a claim
   measured live look identical to a successor, and it will build on both
   equally. The label goes on the claim, not on the bullet or heading it
   sits under. A claim that something fails, is unavailable or does not work
   carries the command that failed and what it printed; without them it is
   `assumed`. When you cannot recall which label fits, `assumed` is the
   honest answer and costs nothing. Write `none` for an empty category.

   Four rules govern the body, all following from where it goes: it stays
   in `.cs/handoffs/`, which the user may commit, and the next conversation
   reads it as its opening prompt.

   - **Redact.** API keys, tokens, passwords, personally identifying
     information, anything the session deliberately left untracked for
     privacy, and other sensitive personal detail (such as health, medical,
     body measurements or finances) stay out of the file, including out of
     the verbatim ledger. Redaction outranks every rule that pulls detail
     in: the verbatim ledger, the USER bullet and Next Step's inline rule.
     Quote the user's ruling and replace the sensitive part with a pointer
     to where it lives ("pain history: in the untracked `.cs/plan.md`"). A
     first action that needs the redacted detail says to read it from that
     path first, and if the file is absent on this machine, to ask the user
     before proceeding as if there were no constraint.
     `.cs/handoffs/` is often tracked, so the user's next commit of it
     publishes what you write here; credentials live in `cs -secrets`. Name the secret's purpose instead:
     "the deploy token, in `cs -secrets get DEPLOY_TOKEN`".
     Re-read the finished body before step 9 arms it, for secrets and
     for the detail this rule names: an exact reading is where a secret
     hides, and a verbatim quote is where personal detail does.
   - **Reference committed work; restate what a successor cannot recover.**
     Work captured in a commit, spec, plan, diff or narrative gets a path and
     a one-line pointer in sections 4-9, never a re-summary. The ledger is
     the opposite case: it holds only what has no path to point at. A
     pointer to a script or command says in one clause what it does when
     run, read from the script itself rather than remembered.
   - **Sections 4-9 are short.** Each is a handful of lines of pointers and
     conclusions. Your own explanations and reasoning condense to what they
     concluded; the user's words do not condense.
   - **Say what you could not carry.** If you are working from compacted
     context, or you cut anything short, say so in the handoff: a thin
     handoff that admits it is thin beats one the successor trusts.

   Write the body in TWO passes, and make the first one durable. Rotation
   runs when context is already hot, and a compaction can land before you
   finish. The first Write carries the frontmatter, Next Step, Settled and
   rejected, and Conversation-only facts: the ledger, which dies with the
   conversation. The second pass then APPENDS sections 4-9 (step 5),
   recoverable from the repo if this rotation never finishes. Append, never
   a second Write: a Write replaces the whole file and re-emits pass one
   from whatever context you have by then, and the file pass one wrote is
   the only faithful copy of it.

   Pass one is durable once the Write returns: it is on disk, and the
   autosave hook (`autosave-commits.sh`, which snapshots the working tree
   into this conversation's shadow ref on every Write and Edit) keeps a copy
   wherever git does not ignore `.cs/`. No step of the rotation commits it.
4. Re-read pass one for secrets (the Redact rule above). The same re-read
   runs again in step 6, because pass two quotes files and code, and a
   secret can sit in either.
5. Append the second pass with Edit or `cat >>`, never Write.
6. Re-read the appended body for secrets and the detail the Redact rule
   names.
7. Retire this machine's leftovers: for every OTHER file in `.cs/handoffs/`
   whose frontmatter still says `status: unconsumed`, flip that one
   frontmatter line to `status: superseded` — but only when its `parent:`
   UUID appears in `.cs/local/session.log` (`.cs/private/session.log` when
   `.cs/private` exists: an encrypted session), which records every
   conversation this checkout has run (`Session started (... ID: <uuid>)`).

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
   nothing is lost by dropping it. Delete one only when all five hold:

   - its `status:` is one of those three — never `status: unconsumed`, which
     may be a co-worker's armed rotation and is not yours to drop;
   - its `created:` date is more than 30 days before today;
   - it is not among the 10 newest handoffs in the directory by `created:`,
     counting every handoff whatever its status, so a week of heavy rotation
     never empties the store;
   - it has no uncommitted changes (`git status --porcelain -- <file>`
     prints nothing). The conversation that consumed a handoff appends its
     `## Successor report` to it, and git history keeps only what was
     committed;
   - git tracks it (`git ls-files --error-unmatch -- <file>` exits 0).
     Where `.cs/` is gitignored, `git status --porcelain` prints nothing
     for a handoff git never saw, so the uncommitted-changes check passes
     it, and deleting it deletes the only copy.

   Take the age from `created:` in the frontmatter, never the file's mtime.
   `.cs/handoffs/` is shared, and a clone stamps every file with its checkout
   time: mtime would read as "all new" on a fresh machine and prune nothing,
   while saying nothing about when the handoff was written. The deletions
   stay uncommitted, like everything else the rotation writes.
8. Archive completed task rows. Run
   `cs -archive-tasks plan` once; its `answer:` line is the session's
   standing answer, given once and kept in `.cs/local/task-archive`, and
   its `forced:` line says whether the `cs` mod ran this `/rotate` for the
   user, on its own or from its one-key rotate button (cs reads
   `.cs/local/cs.forced` and `.cs/local/cs.pressed`, which the mod writes
   with this conversation's id before it runs either):

   - `answer: unasked`, with an `archive:` line naming rows:
     With `forced: yes`, do not ask: skip the archive this time.
     With `forced: no`, ask once with AskUserQuestion whether this session
     moves completed task rows out of the live list at each `/rotate` and
     `/wrap` (they land in `.cs/task-archive/<date>/<actor>/<list>/` with
     a readable `tasks.md`), record the reply with
     `cs -archive-tasks answer yes` or `cs -archive-tasks answer no`, and on
     yes run as below.
   - `answer: yes`, with rows to archive: run `cs -archive-tasks run` and
     keep its one line for your reply.
   - `answer: no`, or `archive: nothing`: skip it.

   An `Error:` from either command moved nothing (cs refuses a task store
   it does not recognise); put its line in your reply and go on with the
   rotation. The highest-numbered row always stays in the live list, so
   Claude Code never hands an archived number to a new task.

   The rotation makes no commit. The handoff, the supersedings, step 7's
   prune deletions and the task archive stay on disk, uncommitted: cs
   commits files under `.cs/` only in the commit that creates a session
   and the merge `/finish` makes, and you
   commit them only when the user asks.

   With pass two appended and re-read, the handoff's CONTENT is complete:
   nothing left to lose. It is not yet armed — that is deliberate, see
   step 9.
9. Arm it, LAST: write its basename (no path) to `.cs/local/pending-handoff`
   (`.cs/private/pending-handoff` in an encrypted session).
   Machine-local state — never commit it. Run this once from the session
   root, with `HANDOFF` set to the basename:

   ```sh
   marker=.cs/local/pending-handoff
   if [ -L .cs/private ] || [ -e .cs/private ]; then marker=.cs/private/pending-handoff; fi
   cs -vet-session . && printf '%s\n' "$HANDOFF" > "$marker"
   ```

   The command asks cs first: while git tracks a file in `.cs/local` or
   `.cs/private`, a pull can rewrite the marker, and the SessionStart hook
   refuses the rotation it names. Then the command prints why and arms
   nothing. Tell the user that line and that the handoff stays in the store:
   once they untrack the files as it says, `cs <session-name>`'s launch
   prompt offers the handoff with `r`. Skip steps 10 and 11.

   Arming is the final step because an armed marker is fragile in a way the
   handoff file on disk is not. If Claude Code exits before the ritual finishes and
   the user relaunches, `cs <name>`'s prompt disarms the marker on `Y`, `n`,
   Enter or any key the prompt does not offer (lib/75-launch.sh). The one
   exception is critical context with this conversation's own handoff
   pending and no merge armed. There Enter and every key the menu does not
   offer (`x`, a space, `q`, `1`) take the default, which starts a fresh
   conversation from the handoff and arms the marker for it. Nothing
   re-arms a disarmed marker, so a later `/clear` then opens
   a bare conversation with this handoff left `unconsumed`. The
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

   **Run `/clear` now** (or press the capsule above the prompt, or Ctrl+X 1 if you bound it) — this conversation is ready to rotate.

   This is the one step you cannot take for the user. A hook cannot submit
   to Claude Code's command queue (it accepts the TUI's own input only); the
   `cs` mod's button can, and once the marker is armed it reads
   `/clear and continue from the handoff`. The keystroke is theirs unless
   they launched with `CS_ROTATE_FORCE_CTX`, when the mod counts twenty
   seconds down and runs the `/clear` itself — which is why the line must not
   end up buried under a summary of what you just wrote.
