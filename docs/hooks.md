# Hooks

The installer configures Claude Code hooks that enable session management features.

## How a hook finds its session (`cs-resolve.sh`)

Every hook opens by sourcing `cs-resolve.sh`, a library shipped alongside them and
never registered against an event, and calling `cs_resolve_session`. The library
also carries `_cs_terminate_jsonl`, which repairs a JSONL tail left unterminated by
an interrupted write so the next append cannot splice two records onto one line —
hooks cannot source `bin/cs`, so the shape is shared rather than the code. Each hook
that appends to a JSONL journal — the shared `timeline.jsonl` or the machine-local
`notifications.jsonl` queue inbox — defines its own fallback copy beside the
`cs_resolve_session` one, so an install whose hooks were not redeployed alongside a
newer `bin/cs` still repairs rather than silently splicing.

The code that must give the same answer in cs and in a hook is not copied: `./build.sh`
folds `lib/02-shared.sh` into `bin/cs` and writes it verbatim, under a shebang, to
`hooks/cs-shared.sh`, which ships and goes with the hooks (`CS_HOOK_LIBS`) and is
never registered against an event. It carries the actor rules (`cs_actor_raw`,
`cs_actor_slug`, `_slugify`) and the narrative budget (`CS_NARRATIVE_MAX_DEFAULT`,
`CS_NARRATIVE_KEEP_DEFAULT`, `_narrative_budget`). Edit the `lib/` file and rebuild; CI's
build-sync job fails on a `hooks/cs-shared.sh` that differs from the build. A hook sources
it under the same guard as `cs-resolve.sh`, and carries no copy of its own: without it,
session-start.sh names the actor `unknown` and says the library is missing and that
`./install.sh` (or `cs -update`) redeploys the hooks, and neither hook measures narratives
against a budget it does not have.

`cs_resolve_session` resolves in
two ways and declines when neither applies, leaving each hook to take its own decline
path (a silent exit, or the approval payload the blocking hooks owe Claude Code):

1. **The environment**, when `CLAUDE_SESSION_NAME` and `CLAUDE_SESSION_DIR` are set.
   `cs` exports them before `exec`, so a CLI session resolves here and never reaches
   the walk. This path is what it always was.
2. **The directory**, otherwise: walk up from `CLAUDE_PROJECT_DIR` (or the hook
   input's `cwd`) looking for the `.cs/` that marks a session root. The nearest one
   wins, so a session cloned inside another belongs to itself, and the walk stops at
   `$HOME` so a stray `~/.cs` cannot adopt everything beneath it. There is no `$PWD`
   fallback: a hook's working directory is wherever the front end left it, not a
   statement about which session is open.

The walk is what lets cs work in front ends that fire hooks but cannot export
environment into a session — Claude Code desktop among them, where `CLAUDE_ENV_FILE`
is offered and writable yet propagates to nothing. An IDE or a plugin reaches its
session the same way.

A terminal is the exception: there a session is entered by running `cs`, which has
already exported the contract, so a CLI conversation arriving at the walk was started
some other way. `claude` typed inside a session folder is therefore cs-blind — the
`.cs/` it is standing in belongs to a session, not to that conversation. Claude Code
names its own front end in `CLAUDE_CODE_ENTRYPOINT`: an interactive terminal is `cli`
and `claude -p` is `sdk-cli`. The test lists the terminal rather than excluding it, so
an unset or unfamiliar entrypoint still walks rather than losing its session to a value
cs has never heard of.

An agent-team teammate is why that cannot be a test on the entrypoint alone. Claude Code
respawns a teammate in a tmux pane, and a pane inherits the tmux server's environment
rather than the lead's — neither the contract nor an entrypoint reaches it, so it derives
plain `cli` and reads exactly like a bare `claude`. It is in the session, having been
spawned to work there, so the launch flag decides: `cs_resolve_session` reads the argv of
the claude named by `CLAUDE_PID` and lets the walk proceed for `--agent-id`. A process
whose argv cannot be read is not a teammate, so it declines.

`.cs/local/disabled` opts a directory out of every path, including cs's own.

Session identity is not the only thing that differs by path: only `cs` writes
`.cs/session.lock`, so a hook that resolved by walking does not own it (see
`session-end.sh` below). A launch is recognised by the *absence* of the
resolver's marker, and cs drops any inherited one at entry — otherwise a
`cs -spawn` issued from a teammate's shell, which carries that marker
deliberately, would hand the new launch a claim that the lock belongs to
someone else.

Resolving a session is also not the same as *being* it. Every claude that resolves a
session fires its hooks — agent-team teammates (full claude processes with their own
top-level `SessionStart`, not in-process subagents), headless `claude -p` children,
desktop conversations, a bare `claude` started in a session folder. The session's
recorded conversation (`claude_session_id`) is a single slot, so exactly one of them
may write it: the one `cs` launched. `cs` exports `CS_LEAD_PID` with the pid it hands
to claude and Claude Code stamps every hook env with `CLAUDE_PID`, which the hook
matches two ways, because `cs` launches two ways. The fresh-spawn arms `exec`, so
claude carries `cs`'s own pid; the resume arm runs claude as a child — it needs the
exit status to fall through to a fresh rebind when there is nothing to resume — so
there `cs` is claude's parent. A context-limit fork and an in-process `/clear` keep
the process either way. Environment cannot answer this on its own: children inherit
exports, so a teammate carries `CS_LEAD_PID` while owning a different pid.

The parent arm is the looser of the two, and its limit is worth stating. After an
`exec` launch `CS_LEAD_PID` is the lead claude's own pid, so a claude that is a
*direct* child of the lead claude is admitted. Nothing in cs spawns one, and the
route that would otherwise reach it — a `claude -p` run through the Bash tool —
does not, because that command runs under an intermediate shell and the nested
claude is a grandchild. A user hook or wrapper that `exec`-chains straight into
`claude -p` inside a session would take the slot.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start (including source: `startup`, `resume`, `clear`, `compact`) to `.cs/local/session.log` and appends a `started` event to `.cs/timeline.jsonl`
- On all sources: clears the statusline's attention marker (`.cs/local/attention`) — a fresh session is attended by definition — and, inside iTerm2 with shell integration installed, cancels any dock bounce the previous conversation left running (`CS_NO_ITERM2=1` disables)
- On all sources, **for the launched conversation only** (`CLAUDE_PID` = `CS_LEAD_PID`, see above): rebinds `claude_session_id` in the machine-local `.cs/local/state` to the live conversation UUID from the hook input. Claude Code forks a new UUID when a conversation is continued past the context limit (the old transcript stays on disk), so the recorded binding can silently go stale and `cs` would resume the pre-fork conversation. Non-UUID session ids are ignored; each rebind is logged to `session.log`. Any other claude resolving the same session — teammate, `claude -p` child, desktop, walked-in — leaves the slot alone, so `cs <name>` always resumes the conversation that was opened and the `rotated` timeline lineage stays true
- On `startup`/`resume` only: configures `transfer.hideRefs`, and recovers autosaved changes from a crash of **this conversation only** — it reads just the current conversation's own ref (`refs/worktree/cs/session/<conversation-uuid>`), so a live sibling session's in-flight ref is never misread as a crash. It also renames its ref across a context-fork UUID rebind (a clean continuation), claims any pre-upgrade shared ref once via a compare-and-swap delete, and garbage-collects other conversations' refs older than 14 days. The whole-tree restore (`checkout <shadow ref> -- .`) is offered only when the snapshot's recorded base HEAD still matches the current HEAD; if HEAD has moved since the snapshot (a commit or rebase) or the snapshot predates base recording, it instead warns and points at per-file inspection — a blanket restore over diverged history would overwrite committed work
- On `resume` only: injects dynamic context (last activity, recent commits, objective, up to 5 most recently active sibling sessions with their objectives, followed by the full `cs -msg <session> "<body>"` send form and its `--kind` values, which appear only when a sibling exists to send to; scope-prompt.sh's digest already carries inbound mail, so this block is the only place cs states the outbound form. The block asks Claude to raise an AskUserQuestion before starting work that belongs to a sibling's stated goal rather than merely sharing its vocabulary, and to offer both paths rather than push one; the bar sits high on purpose, since a routing prompt that fires on every overlap becomes a block nobody reads), and a per-actor digest of shared memory/narrative activity since this actor's `.cs/local/watermark` (grouped by git author; and, for each teammate narrative that grew since that watermark, committed or not, the added-section count and the line the new content starts on, taken from the first added hunk of a diff against the working tree, so the actor reads its own file in full and only those lines of the others; a narrative nobody has committed goes unmentioned, since nothing exists to measure it against, and the hook names uncommitted growth again on every resume until a commit carries it), then advances the watermark and stamps the day's date into `last_resumed`
- In a feature worktree (when `task_branch` is in machine-local state): injects a Feature Worktree contract instructing Claude that integration and retirement both go through `/finish <feature>` in the base session, that retirement waits for this conversation to close, and never to merge the branch manually
- Where the conversation genuinely starts clean — source `clear`, or source `startup` with `CS_FRESH_REBIND=1` — injects a Fresh Conversation notice so Claude treats the turn as a clean break. The source is part of the test because `CS_FRESH_REBIND` is exported before `exec` and outlives the launch: on its own it would tell a later `/compact` of a rebound session that its transcript is not loaded while it still is
- When a `.cs/local/pending-handoff` marker is armed (by the `rotate` skill, or by the launch prompt's `r` answer): consumes it — flips the named `.cs/handoffs/` file's frontmatter to `consumed` (recording the new conversation UUID), removes the marker, and injects a Conversation Rotation preamble pointing Claude at the handoff to read first and asking it to reconcile its native task list with the handoff before executing: cs launches claude with `CLAUDE_CODE_TASK_LIST_ID` set to the session name, so the list survives `/clear` and the successor inherits it; a mirror into it would duplicate every carried item (mutually exclusive with the Fresh Conversation notice above, since a rotation is also a fresh start). Consumption requires source `startup` or `clear` **and** a handoff whose frontmatter still says `unconsumed`; a marker naming a spent or missing handoff is stale and is removed silently. On any other source the marker is left untouched, so a compaction or a context-limit fork between the rotate skill and `/clear` cannot eat a pending rotation. The same resolution decides the rebind's timeline label — `handoff` with the name, or `rebind`
- On all sources: surfaces the same queue-inbox digest as scope-prompt.sh — unseen entries in `.cs/local/notifications.jsonl` (task counts, the last breaker trip if any), gated by the `.cs/local/notifications.seen` cursor so it's shown at most once. Whichever of the two injection points runs first (this hook fires once at session start/resume; scope-prompt.sh fires on every prompt) claims the surfacing and advances the cursor for the other. Shares the `_build_digest` jq recipe verbatim with scope-prompt.sh ; the recipe has not moved into `cs-shared.sh`, so an edit to one copy goes into the other as well
- Does NOT surface the cross-session mail digest: that lives only in scope-prompt.sh now (it fires on every prompt), so duplicating it here would double-inject the same unread bodies on every startup and resume
- On all sources: names the current actor and its narrative file in the injected context, and states that the durable memory buckets are shared while only narratives are per-actor, so an entry naming someone else as the user was written by or for another actor. `.cs/memory/` is one store for every actor on a git-synced session, so a `type: user` entry written as an unconditional claim loads for all of them and reads as settled fact; a bare identity line is not enough, because a global instruction naming the right person was already in context and lost to such an entry. The actor precedence (`$CS_ACTOR`, then `.cs/local/identity`, then git `user.email`/`user.name`) is `cs_actor_raw` from `cs-shared.sh`, the same function `cs -whoami` runs; shelling out to `cs` instead would make the hook depend on `cs` being on `PATH`
- On all sources, every actor: measures each `.cs/memory/narrative.*.md` against `CS_NARRATIVE_MAX_BYTES` (default 229376, from `cs-shared.sh`, the same value `cs -narrative rotate` uses) and, for any over budget, adds a `NARRATIVE OVER BUDGET` block naming the file and its size. For the actor's own file it says run `cs -narrative rotate` before the full read; a teammate's is theirs to rotate, so it says read only from the line the digest names. The Read tool refuses a file over 256 KiB, and the protocol's "read it in full" would otherwise send the model straight into that refusal. The hook rotates nothing: rotation commits, and cs never commits on its own
- On all sources, for the launched conversation only: sets the tab title back to `cs: <name>`. cs sets it once at launch and cannot reset it, since cs execs into claude, so a second `cs other` on the same terminal would otherwise leave its name on this tab. Inside tmux it goes through the server (`select-pane -T`, `rename-window`); outside it the hook writes the OSC 0 escape to the terminal device, and a front end with no terminal skips it
- On all sources: exports session environment variables, injects session context into Claude's system prompt

## autosave-commits.sh (PostToolUse on Write/Edit)

Runs after any file modification (Write or Edit), providing crash recovery for all session files:
- Autosaves the entire working tree to the conversation's own shadow ref `refs/worktree/cs/session/<conversation-uuid>` (keyed on the hook input's `session_id`) using git plumbing commands. Each conversation writes, recovers, and deletes only its own ref, so concurrent sessions on one checkout — and parallel worktree sessions — never share or clobber each other's snapshot chain
- Does not create commits on `main` or touch the working tree index
- Chains each snapshot onto that conversation's previous one (a linked list per conversation)
- Records the HEAD the snapshot sits on as a `cs-base` commit trailer, read before the tree is written so a HEAD that moves mid-snapshot is never mislabelled; crash recovery uses it to tell whether HEAD has since moved and refuse an unsafe whole-tree restore
- Skips the snapshot (never waits) while `<git-dir>/cs/integrate.lock` exists — the per-checkout mutex `cs <base> -integrate-feature` holds while it fast-forwards the base, so only the checkout being landed on pauses — and holds that same directory itself for the duration of the tree write
- For narrative file edits, also logs the latest heading/bullet to `session.log`
- Runs in background to avoid blocking the session

## narrative-reminder.sh (Stop, FileChanged, CwdChanged)

Registered for three events. On `CwdChanged` it only re-arms the maildir watch and exits; on `FileChanged` it runs the rotation kick or the idle mail wake and exits before everything below; on `Stop` it runs the rest.

**Rotation auto-start.** After a `/clear` on an armed handoff, the rotation begins on its own — no keystroke. session-start.sh cannot start a turn (a hook runs inside an already-started process), but it can arm one: it watches `.cs/local/rotation-kick/` and leaves a detached child to drop `rotation.kick` there a couple of seconds later, once Claude Code's watch is up. That `FileChanged` lands here and exits 2, waking the model with a reason that carries the instruction the user's "go" would have carried. Deliberately off the mail budget: `CS_MAIL_WAKE_MAX` bounds a volley of arrivals nobody asked for, while a kick is one file the session wrote for itself, once per `/clear`.
- Armed only on `source=clear` with a handoff loaded, and only in the launched conversation — the `startup` path is the launch prompt's `r` answer, where cs has already handed claude a positional prompt, so a wake there would land on top of a running turn
- `.cs/local/rotation-kick/delivered` makes it one kick, one wake: Claude Code fires `FileChanged` on unlink as well as add, so a session that cleaned up after itself would otherwise wake on its own tail
- Yields to an armed or draining queue for the reason the mail wake does — a rewake between drain turns shifts the pop one turn late and mis-attributes a tool failure to the current task's breaker
- The reason yields to the user: the notice invites them to type instead and the kick is written either way, so a message sent inside the arm window lands first and the wake arrives behind it. The preamble's content-takes-precedence rule covers a *first* message, not a system-reminder after one — so the reason says outright that a user message already sent wins and the wake is spent
- `CS_ROTATION_KICK_DELAY` (default 2) is how long the child waits for the watch to arm. Measured latency is about a second on an idle machine, from one sample with a bespoke hook; the real path runs the full session-start first, so a cold or loaded machine can arm the watch after the write. That failure is silent and benign — no event, no wake, and the rotation waits for a word as it did before — which is also why it will not surface as a bug report. `CS_NO_ROTATION_WAKE=1` opts out, and both the preamble and the user-facing notice change wording to match which path is live

**Mail wake.** Unread cross-session mail (`cs -msg`) takes a turn, so an agent-to-agent exchange advances without waiting for a keystroke. Two events cover two moments: `Stop` reaches a session that has just finished work, `FileChanged` reaches one already parked at the prompt, because Claude Code's file watcher runs on its own event loop. The watched path is the session's `mail/new/`, handed over as `watchPaths` from session-start.sh, which also creates the maildir first — a watch armed on a path missing two levels never fires again for the process's lifetime. A cwd change then *replaces* that dynamic watch list with whatever the session's `CwdChanged` hooks collectively return rather than merging into it, so a session that answers nothing loses the maildir watch for the rest of its life, and nothing later restores it: `watchPaths` rides on only three events, of which `SessionStart` has already happened and `FileChanged` cannot fire once the watch it depends on is gone. Registering a `FileChanged` hook is itself what makes cwd changes replace the list, so the mailbox arms the event that disarms it. The `CwdChanged` branch answers with the maildir — creating it first, for the same reason — which turns the event that wiped the watch into the one that re-arms it, and exits before the drain: an unhandled event falls through into the walk-away run and pops a queued task, so a directory change would silently consume work. The `FileChanged` entry carries no matcher (for that event the matcher doubles as a dispatch query tested against the changed file's *basename*, which is unpredictable for a maildir), so the hook filters `file_path` to its own mailbox and ignores `unlink`, which fires once per message as `cs -msg` moves mail to `cur/`.
- Delivery differs by event: `Stop` emits a `block`; `FileChanged` writes the reason to stderr and exits 2 (`asyncRewake`), which Claude Code wraps in a system-reminder and enqueues at `priority: "next"` — so it arrives as trusted context rather than as fabricated keyboard input
- The reason names the count and the senders — `Unread cross-session mail (2), new from alice` — so a woken session knows who is writing before it opens the mailbox. Each sender comes out of the same `jq` call that already reads the document's `.kind`, so naming costs no extra pass, and repeat senders collapse to one name. The clause says **new from** because the two halves describe different sets: the count covers every unread document, while the names come only from the ones this wake announces, since the discharge skip runs ahead of the read that would learn a sender. Naming every unread sender instead would cost one `jq` per unread document per turn end — what the scan is built to avoid, and what the wake ceiling makes ordinary rather than rare. A sender is the document's `.from`, falling back to `.actor` when `.from` is empty: `cs -msg` records `.from` as the sending session's name, which is empty for a send from a plain terminal, and jq's `//` fires on null but not on `""`
- Fires once per arrival. `.cs/local/mail/woke` holds the filenames already discharged — announced by a wake, or owned by the queue (`task` kind) — written tmp-then-rename under a per-process name because both events write it and the idle one overlaps itself. Neither a count nor a newest-filename mark would work: unread drops to zero whenever `cs -msg` moves files to `cur/`, and filenames are not ordered by arrival
- A run silenced by `CS_NO_MAIL_WAKE=1` or by an armed/draining queue records nothing, so the message still wakes once the gate lifts. An empty queue never gates, whatever `queue.state` records
- Only the launched conversation wakes (the same `CS_LEAD_PID`/`CLAUDE_PID` test session-start.sh uses): a tmux teammate is a full claude with its own `Stop`, and N wakers on one maildir race to read it where the first `mv` wins
- Bounded by `CS_MAIL_WAKE_MAX` (default 5) wakes, counted in `.cs/local/mail/wakes` and cleared by the next user prompt — nothing else caps two sessions volleying at each other

On `Stop`, also:
- Raises the statusline's attention marker (`.cs/local/attention`, machine-local) so the Claude mark's color pulses until the user next interacts; skipped inside subagents
- Inside iTerm2 with shell integration installed (`~/.iterm2/it2attention`), also starts a dock bounce so the finished turn reaches a user working in another app; escapes go to `/dev/tty` because hook stdout is captured. `CS_NO_ITERM2=1` disables; silent everywhere else
- Drains the task queue (`.cs/local/queue`) at each stop boundary when armed, on the lead's Stop only (a tmux teammate shares the directory and fires its own top-level Stop; ungated, each of its idle turns would pop a task) — pops and injects one task at a time and instructs Claude to mirror progress into the native task list; every injected task, the first included, carries a scope block (do every behavior the task asks for, leave pre-existing bugs and unmentioned behavior as follow-ups in the narrative, implement the most direct reading of an ambiguous task and state the assumption) because a walk-away run has nobody watching to say so — taking priority over the narrative reminder below while a drain is armed or running (returns early); each transition also appends an event to the per-machine inbox (`.cs/local/notifications.jsonl`): `drain_started` on armed→draining, `task_done` per advance, `drain_finished` when the queue empties
- While draining, three circuit breakers evaluate after each task pops and before the next is injected: tool failures in the current task at/above `CS_QUEUE_MAX_FAILURES` (default 5, from `.cs/local/failures`), context at/above `CS_QUEUE_MAX_CTX` (default 85, from the statusline's `context-pct`), and the 5-hour rate-limit window at/above `CS_QUEUE_MAX_5H` (default 85, from the statusline's `limits`, skipped when its `stamped_at` is stale past 1800s); a non-numeric env override falls back to the default. A trip parks the queue (`queue.state` back to `idle`, the queue file left intact so `cs -queue start` re-arms), appends a `breaker_tripped` event to the inbox with the reason and reading, and emits a `block` debrief naming what tripped and how many tasks remain. The per-task failure count (`.cs/local/failures`) resets to zero on the armed→draining transition and again after every drain advance, so each task starts the breaker fresh
- Spawned workers report back: when `.cs/local/spawned-by` exists, drain completion sends the spawner a mailbox notify and deletes the marker (one-shot); a breaker trip notifies but keeps the marker so the eventual drain still reports.
- When idle with tasks queued, gates a one-time `AskUserQuestion` (Start/Not yet), reading the statusline's stamped `.cs/local/context-pct` (see [Status line](statusline.md)) to suggest compacting above 60% context; a decline cools down 10 minutes via `.cs/local/queue.declined`, cleared as soon as the queue changes. Task text is arbitrary, so the injected `block` reason is emitted via `jq -nc --arg` rather than string interpolation, keeping the JSON valid regardless of quotes or newlines in the task
- Rotation nudge: when context is at or above `CS_ROTATE_NUDGE_CTX` (default 65, non-numeric override falls back to the default) per the statusline's `context-pct`, and this conversation hasn't already been nudged (`.cs/local/rotate-nudged`, an append-only list of conversation UUIDs, so a tmux teammate sharing the directory cannot re-arm the lead's notice), emits a one-time `block` suggesting the `rotate` skill to write a handoff into `.cs/handoffs/` and arm it, after which the user runs `/clear` to continue in a fresh conversation. Only reached when the queue isn't gating or draining above — an armed/draining queue owns the turn loop
- Both context tiers below read `.cs/local/context-pct`, which the status line writes for the launched conversation alone, so both stay silent in a tmux teammate: the reading is the lead's, and a teammate acting on it would announce the lead's context as its own.
- Context warning: one tier below the nudge — when context is in the `[CS_CTX_WARN_CTX, CS_ROTATE_NUDGE_CTX)` band (defaults 40 to 65; a non-numeric override falls back to its default) and this conversation hasn't been warned (`.cs/local/ctx-warned`, an append-only list of conversation UUIDs, so a tmux teammate sharing the directory cannot re-arm the lead's notice), emits a one-time `block` telling Claude to let the user know context crossed into wind-down territory. At or above the nudge threshold only the rotation nudge fires — never both in one Stop
- Reminds Claude to review and append to its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on the most recently modified `narrative.*.md`, when it has not been touched recently. The contract is append-only: a disproven entry gets a dated correction that names it; earlier sections are never rewritten or deleted (that is what keeps `cs -narrative rotate`'s head-truncation safe under `merge=union`)
- Carries a commit cadence: batch narrative appends into one commit at a handoff or wrap rather than one commit per append, and says uncommitted appends are safe because `autosave-commits.sh` already snapshots every edit to the shadow ref. It rides this reminder rather than the generated session protocol because the protocol is read once at startup and is stale by the time a commit happens, while this fires at the append itself — and because the reason string is rebuilt every run, so every existing session picks it up on upgrade with no migration phase. Unconditional rather than gated on whether `.cs/` is tracked: the check is cheap, but the advice is inert rather than wrong where `.cs/` is gitignored, and a condition the model has to evaluate is one it will not
- Cooldown-gated via `.cs/.narrative-reminder-cooldown` (at most once per 5 minutes). The same stat pass measures every narrative against `CS_NARRATIVE_MAX_BYTES` (default 229376) and appends one line per file over budget naming it and pointing at `cs -narrative rotate`; nothing is rotated from the hook
- Appends a second-opinion note to that same reminder when `claude-council` or the codex plugin is present, naming what each offers: `/claude-council:advise` to put the conversation to external models, and `/codex:review` before Claude calls built work done, with `/codex:rescue` when a run stalls. It rides the narrative reminder rather than taking a second `Stop` entry, because the event has one emit slot and a second registration would compete instead of compose. For the same reason there is one note and one cooldown stamp whatever the plugin count: two independent notes would double the appended text and race the same stamp. Detection reads `installPath` from `~/.claude/plugins/installed_plugins.json` and then requires the plugin's own command file on disk (`commands/advise.md`, `commands/review.md`), because the install record outlives an uninstall, so the file decides. The council half suggests and never sends, and asks Claude to check with the user first, because a digest of the conversation goes to third-party providers and nothing a hook can read says whose words it holds (inside a subagent the ambient session id names the parent). The codex half offers `/codex:review` rather than promising to run it: that command carries `disable-model-invocation`, so only the user can type it, while `/codex:rescue` does not and Claude may invoke it. Cooldown-gated via `.cs/local/.advisor-nudge-cooldown` (per-machine state, never git-synced) at most once per 30 minutes, and silent when no plugin is present. Only the launched conversation nudges: a tmux teammate shares the directory and the single cooldown stamp, so an ungated note would let a teammate consume the lead's slot
- Approves silently inside subagents and outside cs sessions, and when the narrative was modified within the cooldown window

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time and the exit source reported by Claude Code (defaulting to `user_exit` when none is given) and appends an `ended` event to `.cs/timeline.jsonl`
- Deletes only the ending conversation's own shadow ref (`refs/worktree/cs/session/<conversation-uuid>`); a concurrent sibling's ref is left untouched
- Cleans up `.cs/session.lock`, but only one this launch owns. Only `cs` writes a lock, so a hook that resolved by walking the directory belongs to another front end: closing a desktop conversation on a directory a CLI session is live in would otherwise strip that session's lock, letting `cs <name>` open a duplicate with no collision menu. A walked-in hook still clears a lock whose process is gone, so a crashed session is never left locked out
- Regenerates the sessions index (`<sessions-root>/index.md`) — a table of every session's status, objective, and created date. Written only where sessions actually live: the session's own directory must sit under the sessions root, compared physically on both sides so a `$HOME` reached through a symlink still matches. An adopted session, whose directory is an unrelated project path, writes no index beside that project
- Skipped entirely inside subagents (guarded on the hook input's `agent_id`)

## subagent-context.sh (SubagentStart)

Runs when Claude Code spawns a subagent (via the Agent tool):
- Injects session context into subagents so they know about the cs session
- Provides the session directory and key rules (secrets handling, documentation protocol)
- Uses `additionalContext` in the same format as SessionStart

## tool-failure-logger.sh (PostToolUseFailure)

Runs when a tool call fails (async, non-blocking):
- Logs tool name and truncated error message to `.cs/local/session.log`
- Helps debug build failures, test errors, and other tool issues after the fact
- Increments the per-task failure counter (`.cs/local/failures`, atomic tmp+mv) that feeds the queue's failures circuit breaker (see narrative-reminder.sh); absent or non-numeric reads as zero. A lost increment under exact concurrency with the Stop hook's reset degrades the breaker by one count but never corrupts state, and the increment stays silent and non-blocking like the rest of the hook

## session-auto-approve.sh (PermissionRequest on Write/Edit)

Runs when Claude Code would show a permission dialog for Write or Edit:
- Auto-approves writes to files inside the session's `.cs/` metadata directory
- Falls through to the normal permission prompt for all other files
- Scoped narrowly to session metadata only — project files always require explicit approval

## bash-logger.sh (PreToolUse on Bash)

Runs before every Bash tool call (sync, fast):
- Logs `[timestamp] BASH: command` to `.cs/local/session.log`
- Creates a complete audit trail of all commands Claude runs
- Truncates long commands at 200 chars
- Never blocks — uses `set -uo pipefail` without `set -e`

## scope-prompt.sh (UserPromptSubmit)

Runs before each user prompt is sent to Claude. First it clears the statusline's attention marker (`.cs/local/attention`) — any prompt, including slash commands, means the user is back — and, inside iTerm2 with shell integration installed, stops the dock bounce the Stop hook started (`CS_NO_ITERM2=1` disables). Then three responsibilities:

**Queue digest.** Surfaces unseen entries from the per-machine inbox (`.cs/local/notifications.jsonl`) at most once: counts by event plus the last breaker reason, if any, e.g. `cs queue while you were away: 4 task(s) done; breaker tripped: context (91 >= 85), 2 remaining. Run cs -queue log for detail.` The `.cs/local/notifications.seen` cursor advances only after the hook writes the digest to stdout, even when the digest text itself is empty, so surfacing stays at-most-once regardless of what else this prompt does. The order is load-bearing: this hook runs under a wall-clock timeout, and Claude Code kills it where it stands when it overruns — a cursor spent before the write retires notifications nobody ever saw, with no second chance at them. Advancing afterwards can at worst repeat a digest. When scope grounding below also has content, the digest is spliced above the `## Scope (auto-grounded)` block rather than replacing it — every exit path in this hook still delivers a pending digest. **Mail digest.** scope-prompt.sh (only) surfaces unread cross-session mail on **every** prompt until it is read — persistent, not surface-once. It inlines the bodies of the documents sitting in `mail/new/`, which only `cs -msg` empties by moving what it prints to `mail/cur/`, bounded to the first 5 with sender and body truncated inside jq (codepoint-safe) plus an "N more" overflow line. A `task`-kind message is a count-only label, never its body — the body is already an imperative in the recipient's queue, so inlining it would double-execute. No cursor is written by the hook (persistence is anchored on `new/` itself), keeping it a read-only view of the mailbox and leaving no cursor for two hooks to race over. Only `new/*.json` counts: an unfiltered scan would pick up a `.DS_Store` or a subdirectory and nag about phantom mail that `cs -msg` cannot clear. The header count is the file count, so an unparseable document among the first 5 counts toward N while rendering nothing — the same basis the status line and the TUI use, which is what keeps the three agreeing. A message can never appear half-written: delivery renames a complete document into `new/`.

**Objective capture.** Records the first substantive prompt of a session as the `## Objective` in `.cs/README.md`, but only while it still holds the unedited template placeholder — so the first real prompt wins, nothing afterwards churns it, and a hand-written objective is never overwritten. Skips slash commands, `!` shell passthrough, and trivially short prompts; collapses to one line and truncates to ~100 chars. The prompt is written via `awk` `ENVIRON` (no escape/replacement processing of arbitrary text), atomically via tmp+rename. Opt-out per-session: `export CS_OBJECTIVE_CAPTURE_DISABLE=1`.

**Date reminder.** The session context names the date once, at SessionStart, and a conversation that lives across midnight keeps believing it. On every prompt, empty ones included (a mail wake can land on a new day), the hook compares today against `.cs/local/context-date/<conversation id>`, which holds the `YYYY-MM-DD` this conversation was last told, written by session-start.sh at startup and by this hook whenever it changes. One file per conversation: a lead and a tmux teammate share the directory, and a single slot would let either one's new day silence the other's. A different day yields one `## Date` note naming both dates and asking Claude to treat any earlier "today" as stale; the same day yields nothing. A missing or unreadable stamp also yields nothing and just sets the baseline. A conversation id outside the uuid alphabet skips the feature rather than becoming a path. The stamp is written only after the note has gone out, like the inbox cursor, and not at all when the output object could not be built, so a hook killed mid-run can repeat a note but never lose one; session-start.sh likewise stamps after its context has been emitted. Opt out per-session: `export CS_DATE_REMINDER_DISABLE=1`.

**Clarify.** Injects a short guideline asking Claude to question an ambiguous request rather than guess at it. Deliberately ungated: the work-verb classifier exists to guard expensive git work, which is what earns its false-positive risk, whereas this guards a few hundred bytes of text — so a code-level vagueness check would buy nothing and pay for itself in misclassification. It also has to sit above that classifier, because a vague prompt (`make it better`) carries no work verb and would be dropped before the check ran. The guideline sets a high bar for asking ("genuinely cannot determine"), caps it at one batched question, and makes proceeding the default. Skips empty prompts — a mail wake carries none, and injecting there would put the guideline on every unattended turn — plus slash commands and `!` shell passthrough, which carry their own instructions. Opt out for one turn with a leading `~`; opt out per-session: `export CS_CLARIFY_DISABLE=1`. The switch is deliberately separate from `CS_SCOPE_DISABLE`: silencing grounding should not silence the questions.

The guideline is spliced above the `## Scope (auto-grounded)` block, never below it. A truncated scope block has to end with its truncation marker so nothing severed can read as a complete path, and its bytes come out of the same 8000-byte budget — the scan output is the elastic part and absorbs the cost, because emitting half an instruction is worse than a shorter file list.

## prompt-rewriter.sh (not a hook — an `$EDITOR` shim)

Ships in `hooks/` and deploys alongside the hooks, but Claude Code never invokes it as one and it is never registered against an event. It is reached through `$EDITOR`.

Claude Code binds `chat:externalEditor` to `ctrl+g` (also `ctrl+e` and `ctrl+x ctrl+e`). Pressing it writes the composer buffer to `<tmpdir>/claude-prompt-<uuid>.md`, runs `$EDITOR` on that file, reads it back, and replaces the composer with the result when it differs. cs points `EDITOR`/`VISUAL` at `prompt-rewriter.sh` when it launches a session, so the round-trip becomes a rewrite: type a rough prompt, press `ctrl+g`, and the composer holds a precise engineering request you can review, edit and send. Nothing is sent on your behalf.

The shim hands every file that is **not** named `claude-prompt-*.md` to your real editor (captured as `CS_REAL_EDITOR` before cs overrides `EDITOR`), so `/memory` and opening a transcript still work normally. It passes the buffer through untouched when it is empty, starts with `/`, `!` or `#`, or carries a `[Pasted text …]` or `[Image …]` placeholder — the buffer holds those placeholders rather than the pasted bodies, so rewriting one would destroy the attachment. Every failure path leaves the buffer exactly as typed: a rewriter that errors, times out, or returns empty loses nothing.

The default rewriter, `prompt-rewriter-model.sh`, calls a fast model with the prompt as untrusted data. It runs hermetically — its own config directory, a neutral working directory, and the session's context variables stripped from its environment — because a nested `claude` otherwise inherits the project's `CLAUDE.md` and cs's own memory, and those leak into the rewrite: a request to add a flag came back demanding TDD, bash 3.2 compatibility and a README update that the user never asked for. It authenticates as **you**, through your claude.ai login, and never through an ambient `ANTHROPIC_API_KEY`. Claude Code prefers such a key over the login, so a stale or rotated one takes every rewrite down — and not quickly, because a rejected key sends the call into retries until the timeout, which reads as `ctrl+g` silently doing nothing. So `ANTHROPIC_API_KEY` is dropped from the child's environment — and only it. `ANTHROPIC_AUTH_TOKEN` is checked identically in both modes, so a dead one breaks the parent's own session and the user already knows; stripping it would also strand proxy users, whose `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS` remain and would receive a keychain bearer token. The rule is to scrub exactly the credentials whose precedence differs between the parent and the child. Isolating the config directory does not come with credentials: Claude Code derives the keychain service name from that directory (`` `Claude Code…-credentials${o}` `` where `` o = r ? "" : `-${sha256(configDir).digest("hex").substring(0,8)}` ``), so an isolated dir asks for an item that was never created and reports `Not logged in`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` overrides which directory that hash is taken from, so the shim mirrors whatever the parent resolved — empty when the parent has no config directory of its own, which is the value that drops the suffix, and the parent's own directory otherwise, since that user's login lives under its hash. Config stays isolated while the call reaches the real login.

**Forcing the API arm.** Appending `-api` to a provider name — `gemini-api`, `openai-api` — reaches that vendor's API even when its CLI is on PATH. It exists because agy's catalogue carries no lite models (eleven entries, and `gemini-3.5-flash-lite` and every variant of it are rejected as unrecognised), while the lite tier is the fastest option measured anywhere. On a machine with both CLIs installed: `gemini` 7.3s against `gemini-api` 0.9s, `openai` 12.8s against `openai-api` 2.0s. `claude-api` is the third: it posts to Anthropic's Messages endpoint rather than driving the Claude Code agent, which is what makes the bare `claude` default take roughly thirteen seconds — that call ships Claude Code's system prompt and tool schemas every time, measured at 35k tokens for a ten-token prompt. Each `-api` arm needs that vendor's key (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) and declines without one, leaving the prompt as typed. Bare `claude` has no suffix-free API form on purpose: it *is* the default rewriter, and it authenticates through your claude.ai login rather than a key.

**Rewriting with OpenAI or Gemini.** `CS_REWRITE_PROVIDER=openai` or `=gemini` routes the rewrite to `prompt-rewriter-vendor.sh` instead. Each provider prefers that vendor's CLI when its binary is on PATH — `codex` and `agy` respectively — and falls back to the vendor's API, reading `OPENAI_API_KEY` or `GEMINI_API_KEY` from the environment, when it is not. This mirrors the claude-council's `prefer_cli_over_api` policy and for the same reason: the CLI carries your subscription and spends no API credit. It costs about ten seconds against about one for the API arm, and the interface is frozen throughout, so the trade is real in both directions. With neither a CLI nor a key the rewrite declines and your prompt stays as typed, which is also what an unknown provider name does.

**Rewriting with Grok.** `CS_REWRITE_PROVIDER=grok` (or `xai`) routes to xAI's OpenAI-compatible endpoint, reading `XAI_API_KEY` or `GROK_API_KEY`. There is no `grok-api` spelling because xAI ships no rewriter CLI: there is nothing to prefer and so nothing for a suffix to reach past. The default model is `grok-4.3`, chosen by measurement rather than by recency. Over 8 prompts run twice against every candidate, `grok-4.3` preserved every unspecified thing as an open item; the much faster `grok-4.20-0309-non-reasoning` resolved them by fiat in 7 of 10 vague prompts — answering `Use jq.` to "should i use jq or awk here?", picking a database unprompted, and once returning the input verbatim. A rewriter that decides for you is worse than no rewriter. Note that Grok is not faster than what already ships: `gemini-flash-lite-latest` was the quickest model measured and matched `grok-4.3` on fidelity.

The vendor rewriter runs the CLI from the same neutral directory the default uses, because `codex` reads `AGENTS.md` from its working directory and `agy` takes that directory as its workspace — launched from your checkout, the rewrite would inherit that project's instructions. It closes the CLI's stdin, since Claude Code hands the shim the real tty and an agentic CLI that decides it is interactive would paint over the progress screen. On the API arms the key travels in a mode-600 `curl --config` file and the prompt in a payload file, so neither reaches `argv`, where `ps` shows it to every user on the machine; the CLI arms are the exception, as `agy` and `codex` both take the prompt as an argument and offer no stdin path.

Three failure modes here are not the ones the contract anticipates. `agy` prints `CLI error: …` on **stdout and still exits 0**, so a status check alone would hand that string back as your next message; the gate judges the output as well as the status. A reasoning model can return a rewrite truncated at the token cap, which is non-empty and so passes an emptiness check while being unusable — `gemini-2.5-flash` was observed spending 1963 reasoning tokens against a 2048 cap and stopping mid-sentence, though it also completes normally on other calls — so a `finishReason` other than `STOP` declines. And Gemini's endpoint has been observed answering with a bare HTTP 404 and a zero-byte body, transiently, so an empty response declines rather than being treated as an answer. Only `/v1/chat/completions` is used for OpenAI: reasoning models are the wrong tool for a rewrite that blocks the interface, and an `o3`/`o4` model set through `CS_REWRITE_MODEL` gets a 400 and declines.

`CS_REWRITE_MODEL` reaches every arm — the API request, `agy --model`, `codex -m` — and is left off entirely when unset, so each vendor CLI keeps the model configured in that tool. The id belongs to whichever engine answers and the namespaces differ: `agy models` lists agy's, whose ids embed the reasoning effort (`gemini-3.6-flash-low`; the bare `gemini-3.6-flash` is rejected as a family name needing `--effort`), while the API arms take the vendor's own API ids. cs does not translate between them, so an id the engine rejects declines the rewrite and leaves the prompt as typed.

The progress screen names the engine and the model — `agy · gemini-3.6-flash-low`, `api · gemini-flash-lite-latest`, or a bare `codex` when the CLI resolves its own model and cs cannot know it. Both come from the vendor rewriter's own `--label`, which the shim calls before painting: repeating the CLI-or-API test in the shim would be a second copy of it, free to drift into a header that says `api` while `agy` is answering. `--label` is answered before the prompt is read, because the shim calls it without writing anything and a script that read stdin first would hang the interface on a pipe nobody fills.

Override the whole thing with `CS_REWRITE_CMD` (stdin to stdout, non-zero to decline). It outranks `CS_REWRITE_PROVIDER`: it is the older and wider contract, and a user who set it has already said exactly what they want run. Opt out per-session: `export CS_REWRITE_DISABLE=1`, which also leaves your `$EDITOR` untouched.

Claude Code runs the editor with `spawnSync` and `stdio:"inherit"`. The shim's basename matches none of its known GUI editors, so it takes the `enterAlternateScreen()` branch and blanks the interface for the length of the rewrite, roughly ten to twenty seconds on the default model. The shim owns that screen and fills it, in one of three styles set by `CS_REWRITE_PROGRESS`. `screen`, the default, shows a header with the model, a rule, and the prompt being rewritten (folded, capped at eight lines with a `… prompt clipped` marker) above a spinner and Claude Code's own `Working…` label, which gains the elapsed in parentheses after five seconds. It draws in the cs palette from `lib/05-term.sh`, inlined because a deployed hook cannot source that file and keyed on the `CS_TERM_THEME` cs exports: `cs` in the brand accent, the prompt in primary ink, chrome muted, and nothing at all under `NO_COLOR`. `native` is one line anchored where the composer was, written in Claude Code's own idiom — a sentence-case gerund with the elapsed in parentheses, and no elapsed at all under five seconds, matching `m = f >= 5 ? ${d} (${f}s) : d` in its CLI progress renderer. `line` is a single centred line with a spinner and a clock. Neither echoes the prompt, so a pasted secret never reaches the screen. `static` prints one line and never repaints, which costs the only liveness signal there is: a wedged rewrite then looks exactly like a working one. An unrecognized value falls back to `screen` rather than restoring the blank screen the feature exists to remove. Tearing down the alternate screen discards it, so nothing reaches the scrollback.

You cannot interrupt a rewrite from the keyboard, and the screen does not pretend otherwise. The terminal delivers `ctrl+c` to the whole foreground process group, which contains Claude Code itself, so the keystroke ends the session rather than the rewrite. No handler in a spawned shim can intercept a signal the tty sends to its parent as well. `CS_REWRITE_TIMEOUT` is the only bound, which is why the screen shows elapsed time against it.

The shim still handles `INT` and `TERM`, for the case where it receives one anyway. The handler exists to reap, not to cancel: it signals the rewriter's whole process group, restores nothing because it has written nothing, and exits 0. Without it, a shim dying alongside its session would orphan the `claude -p` it started — detached, invisible, and still billed until it finished. That matters most in exactly the situation nothing can prevent.

Every invocation appends one line to `.cs/local/rewrite.trace` naming the path it took — `exit passthrough-prefix`, `exit real-editor`, `rewriter-forked`, `exit rewritten`, and so on. This shim is driven by a keypress and draws onto a screen that is torn down, and each of its do-nothing paths leaves the buffer byte-identical, so without the trace a rewrite that declined, one that was disabled, and one that was never a composer buffer at all are indistinguishable after the fact. The trace is machine-local and written only when `CLAUDE_SESSION_META_DIR` resolves to a real session.

Every drawing path checks `[ -t 2 ]` first, so a piped or scripted run emits nothing.

Known multi-machine limitation: if a session is cloned to a second machine while the Objective is still the placeholder and both machines then submit their first prompt before syncing, each captures its own objective and the merge conflicts. This is left as a real conflict on purpose — two people declared different objectives for the same session, and a human should reconcile them.

**Scope grounding.** Grounds code-work prompts in the current codebase by injecting a bounded "Scope (auto-grounded)" block as `additionalContext`:

- Classifies the prompt: positive iff a work verb (`implement`, `add`, `fix`, `refactor`, …) OR a source-file extension is mentioned. Negative classifications pass through silently with no output.
- On a positive classification, tokenizes the prompt and uses a **hybrid matcher**: path-like tokens (`src/api.ts`) get ordered-substring matching against `git ls-files`; bare-word tokens (`api`, `db`) get component-equality with camelCase + `_-` splitting via a hand-rolled `splitcamel()` awk char-loop (portable across BSD and GNU awk). Excludes `node_modules/`, `target/`, `dist/`, `build/`, `.next/`, `coverage/`, `.cs/`, `.git/`.
- Adds recent commits touching the matched files (`git log --oneline -5`) and a working-tree diff summary.
- Caps total `additionalContext` at 8000 bytes (rough 2K-token proxy).
- Emits a pinned tombstone block (`Scope: no tracked files matched`) when the classifier fires but no tracked files match, so the agent knows scope ran but found no ground.
- Opt-out per-session: `export CS_SCOPE_DISABLE=1`.
- NO caching by design: a grounding hook must reflect the current tree; a prompt-only cache key would silently serve stale ground after commits/edits.
- Never blocks the prompt path — every error path exits 0.

**Stage trace.** Every run appends one line per stage to `.cs/local/scope-prompt.trace` as that stage finishes — `pid`, milliseconds, stage name, with each mark after `start` carrying the elapsed time since it. The `start` value itself is epoch milliseconds wherever the shell offers `$EPOCHREALTIME`, and shell-relative on the bash 3.2 fallback, so treat it as an origin to subtract from rather than a wall clock. The `start` mark also names the directory the run stood in — the rest of the line, never a field, since paths hold spaces:

```
21204 1786532215708 start /Users/you/projects/big-repo
21204 21 input
21204 53 digest
21204 61 objective
21204 68 classify
21204 94 tokens
21204 152 scan
21204 198 gitlog
21204 229 gitdiff
21204 272 emit
```

**Own deadline.** The hook checks its own clock once, after the classifier and before the scan stages (`tokens`, `scan`, `gitlog`, `gitdiff`), through the same builtins the trace reads. Past `CS_SCOPE_BUDGET_MS` (1500 by default; a value that is not a number is the default) it gives up the scope block, puts one line in its place (`Scope: skipped, slow machine (...)`, so the model knows to locate the files itself), writes a `skip` stage to the trace and exits through the digest path: the queue and mail digests, the date note and the clarify guideline still arrive. Measured: the front half takes under 300 ms idle and about 1.7 s at a load of 25 (a full test suite on the same box), and it was the scan running on from there that the 3 s registration killed, taking the digests with it. The registered timeout is 5 s now and stays the backstop for a scan that is itself slow.

A run that overruns the hook's timeout leaves a trail that stops mid-run, which names the stage it hung on — the only evidence such a run ever produces, since it never reaches an exit where it could write a summary. A trail ending anywhere but `exit` or `emit` marks a killed run. The trace reads the clock through shell builtins only (`$EPOCHREALTIME`, or `$SECONDS` on bash 3.2), so it adds no forks to a hook already under suspicion for running slow. The file is machine-local — which machine was slow is half the finding — and one run in 64 trims it to its last 2000 lines. Opt-out per-session: `export CS_SCOPE_TRACE_DISABLE=1`.

## cs-rotate (not a hook script — a Claude Code mod)

`mods/cs-rotate/` is a Claude Code function-hooks plugin: TypeScript that runs
inside Claude Code's own process rather than a shell script it spawns. It adds
one key to conversation rotation. Once the context window reaches 40% (the
status bar's warn band, where the Stop hook gives its headroom notice), the band
directly above the prompt draws `1: rotate this conversation`.
`CS_ROTATE_BUTTON_CTX=<percent>` in the shell that launches cs moves it; unset
or not a number, the band follows the bar's own warn band
(`CS_STATUSLINE_CTX_WARN`, 40 by default). The band is one rounded capsule in
the status bar's idiom: the Claude mark in coral, the button, and a ten-cell
context meter with the percentage (`█████░░░░░ 47%`). The border and the meter
take the bar's own truecolor inks, not the theme's nearest keys, so the capsule
reads as one more capsule of the bar: amber past warn, red past crit, read from
the same `CS_STATUSLINE_CTX_WARN` and `CS_STATUSLINE_CTX_CRIT` the bar reads (40
and 65 by default), in the light or dark value for the theme cs detected at
launch (`CS_TERM_THEME`; unset reads as dark, as cs's hooks read it). The bar
itself picks its amber from the measured terminal background when it has one;
the mod has only the theme, so on a terminal whose background contradicts the
theme flag the two ambers can differ. Under the mouse pointer the border turns
coral. Pressing `1` from an
empty composer runs `/rotate`, as if typed: the `rotate` skill draws the
purpose from the conversation. Beside it the band draws `2: wrap up this
session`. That key runs `/wrap`, which distills memory, replaces
`.cs/summary.md` and rotates the narrative: two Opus passes and a shell
helper, minutes and real tokens, so it takes two keys: `2` runs nothing and
draws `3: yes, run /wrap` beside it for five seconds, and `3` within that
window runs it. The confirmation is a different key on purpose: a held key
repeats, and no timing tells a repeat from a second press. `2` keeps its
button while armed (`2: wrap up this session?`) and only restarts the window,
since a digit with no button lands in the composer and a non-empty composer
takes every hotkey with it. A prompt entering the session, a `/clear`, or a
switch to another conversation disarms it. Below the band the mod draws nothing, and it draws nothing while a
turn runs or while a survey holds the band. It never submits a prompt of its
own.

The same button has a second state. Once the `rotate` skill has armed a
handoff (`.cs/local/pending-handoff` names one), the band draws
`1: /clear and continue from the handoff` whatever the context reads, alone
(the wrap key hides: with a handoff armed the conversation has nothing left to
do but the `/clear`), and
pressing `1` runs `/clear` itself: the conversation ends, and cs's SessionStart
hook starts the handoff's next step in the new one, as it does after a typed
`/clear`. The mod does not touch the marker; the hook consumes it. The button
appears only for a marker the hook accepts: a bare basename, a file in
`.cs/handoffs/`, frontmatter still `status: unconsumed`. An empty marker, or one
an aborted rotation left naming a handoff since consumed or gone, leaves the
rotate button in place.

The mod can also press the button for you. With `CS_ROTATE_FORCE_CTX=<percent>`
in the shell that launches cs (off unless set, and off for a value that is not
a number), the end of a turn whose context reads at or past that percentage
runs `/rotate` as if you had pressed `1`, once per conversation: the mod
records the conversation id in `.cs/local/cs-rotate.forced` before it schedules
the run, so a `/rotate` that fails is not tried again at the end of every turn. A run
the engine refuses shows as a toast; a run that starts but whose turn ends
without arming a handoff (the skill refused, or was interrupted) is not seen
by the mod, and the rotate button simply stays for you: the forced rotation
is one attempt per conversation, never a retry loop. Only a turn that ended
with an answer counts, on the main loop, in the lead conversation, with no
handoff already armed: an interrupted or errored turn, or a subagent's, starts
nothing. The run is scheduled from a timer rather than from the turn's own
hook, which the plugin contract refuses a command from. Once the rotate skill
has armed its handoff, the next turn's end starts a 20-second grace: the
capsule reads `1: /clear and continue from the handoff  ·  /clear in 20s`,
redrawn once a second, and at zero the mod runs the `/clear` itself, only if
the band is idle at that moment (no turn running, no survey), the handoff still
armed and this still the lead; otherwise the count stops and the button waits
for you. Pressing `1` during the count clears at once. Sending a prompt, from
the composer or anywhere else a prompt enters the session, stops the count;
the next turn's end starts it again from 20. A `/clear` from anywhere else
(typed, or another plugin's) ends it too. The count is module state: it does
not survive a reload of the mod, and every path that ends it cancels its
timer, because a timer started before a `/clear` keeps firing after one
(measured). At zero the mod re-reads the handoff with the SessionStart hook's
own rule (frontmatter opened and closed by `---`, `status: unconsumed`
inside), so a truncated handoff is never cleared into.

Pick the percentage above a fresh conversation's own footprint. The wake turn
after the `/clear` is an ordinary turn, and the once-per-conversation record
belongs to the conversation that ended, so a threshold a fresh conversation
already sits past (a session that loads a large CLAUDE.md and memory, say,
with the knob at 5) would rotate again as soon as it woke, and again after
that (measured at 1). The mod refuses that loop: a conversation born of a
`/clear` it saw run (its own at zero, or one typed) is judged by the context its
first turn ended with, and one that already sat past the threshold is never
forced; a toast says so once
(`CS_ROTATE_FORCE_CTX=5 is below this conversation's starting context (8%)`),
and the button stays. The conversation the mod meets at launch, after a reload,
or through a `/resume` is not judged: a session resumed at 72% with the knob at
70 is exactly the one the person asked to have rotated. A handoff the person
arms by hand in a judged conversation still gets the countdown. The bar's crit
band, 65, is the intended neighbourhood.

The button is for the lead conversation of a cs session only: past the threshold
the mod also checks that the cwd has `.cs/local`, that `.cs/local/disabled` is
absent, and that its own conversation id is the `claude_session_id` in
`.cs/local/state`. A teammate claude in the same directory, or a plain Claude
conversation, gets no button, because the handoff the skill writes carries that
id and arms the marker cs launched the lead with. The plugin's own id follows
`/clear` (measured: after a `/clear` the band returned only once
`.cs/local/state` named the new transcript), and cs's SessionStart hook rebinds
`state` on every fresh conversation, so the lead keeps its button across
rotations. Every render costs one `cwd` and one `exists` for the marker; with
a marker there it reads it and the handoff it names; past the threshold or with
a handoff armed it adds one `cwd`, two `exists`, one `read` and one `id` call.
The band renders a handful of times per turn, not per keystroke.


`install.sh` deploys the mod's three files under `~/.claude/skills/cs-rotate/`
beside the skills (the installer replaces a symlink an earlier opt-in left there
with a real directory), and `cs -uninstall` removes the directory. Claude Code
loads function-hooks plugins only behind `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`,
an early-access flag, so every `cs <name>` launch exports it for that session. A
`claude` started outside cs has the flag only if its shell carries one (a shell
inside a cs session does), and without the flag there is no button. The flag is
not scoped to cs's own mod: any other function-hooks plugin on the machine loads
in cs sessions too. cs keeps a value the shell already set (0 keeps function
hooks off), and `CS_NO_FUNCTION_HOOKS=1` leaves the session without the flag
even when the shell carried one. cs writes no settings file.


When Claude Code loads the plugin, at process start or on a plugin reload but
not on `/clear`, the mod writes `.cs/local/cs-rotate.heartbeat` (one UTC
timestamp) when the cwd has `.cs/local`, and `cs -doctor` reports the mod by
that file inside a session: `last ran <stamp> in this session` as OK, or a WARN
when the directory is there and no heartbeat is, naming the ways that happens
(no cs launch since the install, function hooks withheld by
`CS_NO_FUNCTION_HOOKS` or a preset `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0`, or
a Claude Code that no longer loads mods behind the flag). Doctor reads the
heartbeat rather than the directory because a machine's policy can load a mod
and never run it. Doctor says nothing when the mod is not installed, or outside
a session. The deploy-drift check compares the deployed files against `mods/`
in the checkout the way it does hooks, commands and skills.

Two facts about the plugin runtime shape the code. A module reads the
environment through `$.env.get` with a literal name, which `claude plugin
validate` lists, so the threshold and the bands are three variable reads per
render, the theme a fourth; the defaults and the five ink triplets are literals
in `register.tsx` that `tests/test_mod_rotate.sh` pins to the status line's. The
module state the forced mode keeps (the countdown, the conversation it is
judging) is reset by a hot reload, which drops a running countdown and adopts
the conversation it meets next unjudged.

Design lab: `docs/mods-design-lab.html` (open it in a browser) shows every element, prop, render site and rule a mod can use, and the
rotate capsule's presets and knobs, each state printing the
JSX it maps to, in the status line's inks; the shipped capsule is its "Inked" preset.

Tests: `tests/test_mod_rotate.sh` runs the bun unit tests under
`mods/cs-rotate/test/` (a fake engine drives the band, the press and the
heartbeat) and `claude plugin validate` when each binary is on PATH, and
always checks the manifest, the threshold pin, and that the installer and
the launch name the mod and the flag.

## cs-hint (not a hook script — a Claude Code mod)

`mods/cs-hint/` is a second function-hooks plugin, deployed, enabled, observed
and removed the same way as cs-rotate (installer, `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`,
a heartbeat at `.cs/local/cs-hint.heartbeat`, `cs -doctor`, `cs -uninstall`, the
deploy-drift check). It hooks the `PromptHint` site, the dim line under the
prompt, and draws one dim line of its own beneath the engine's, so a cs
session says what is waiting for it. (A rewrite of the site's `hint` would be
the lighter touch, but measured on 2.1.273 it draws nothing while the
permission-mode notice, `auto mode on`, owns the engine's line, which in a cs
session it always does; the notice stays, the mod's line sits under it.) The
line is the lead conversation's only (the UUID in `.cs/local/state`), and
only while the composer is empty and idle: while you type, and while a turn
runs, nothing is added, since that is where the shortcuts and the interrupt
key are. Outside a cs session, in a teammate claude, with `CS_NO_HINTS=1` in
the launching shell, or with a `hints: off` line in `.cs/local/state`,
nothing is drawn.

What it says, in priority order, at most two joined by ` · `:

- `2 messages from <session> · cs -msg`: the `.json` files under
  `.cs/local/mail/new/`, as `cs -msg` reads them, and the sender of the one
  with the latest `ts` (file names carry the epoch too, but cs itself warns
  that their order is not arrival order); a sender outside a cs session
  writes `""` and is not named.
- `handoff armed · /clear continues it`: `.cs/local/pending-handoff` names a
  handoff the SessionStart hook would accept (a bare basename, present,
  frontmatter still `status: unconsumed`, the marker read with every
  whitespace character dropped as the hook reads it; the frontmatter rule is
  cs-rotate's, which `tests/test_mod_hint.sh` pins equal).
- `3 queued · gate waiting`, `· deferred` or `· draining`: the files under
  `.cs/local/queue/` (not dotfiles, which the hook's glob skips); the word
  follows the narrative-reminder hook's rule (`queue.state` `armed` or
  `draining` is draining; `idle` or no word, with `queue.declined` younger
  than ten minutes, is deferred, without one the gate will ask at the next
  turn's end; any other word the hook does not act on, so the count stands
  alone). An empty queue says nothing, whatever the state file records.
- `continuing: <purpose>`: the handoff whose frontmatter says
  `consumed_by: <this conversation's id>`, its `purpose:` line (its name when
  there is none), shown until your first prompt in the conversation (typed,
  or through Remote Control; recorded in `.cs/local/cs-hint.spoken`, so a
  prompt sent before the line was drawn, or a reload of the mod, does not
  bring it back); the rotation's own wake, a peer's message or a plugin's
  prompt does not end it.
- Otherwise one tip from a fixed list in `register.tsx`, never generated. The
  first fits the session: `/finish` in a worktree session (`task_branch` in the
  state file), `/feature` elsewhere; the rest step once per finished turn of
  the conversation (a subagent's, an interrupted or an errored turn does not
  count; a new conversation starts over), never on a timer, so the line holds
  still while it is read.

The facts change from outside the process (another session's `cs -msg`, the
queue drain, the rotate skill), so once the lead has drawn the line it is
redrawn every five seconds; a redraw costs one directory listing per fact
source, a read of each unread message, and a read of the marker and the state
file. Module state (the tip index, the resumed handoff, the ticker) survives
`/clear` and is reset by a plugin reload.

Tests: `tests/test_mod_hint.sh` runs the bun unit tests under
`mods/cs-hint/test/` and `claude plugin validate` when each binary is on
PATH, and always checks the manifest, the handoff-rule pin, and that the
installer and the launch name the mod and the flag.

## Hook Configuration

The hooks are configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/session-start.sh", "timeout": 30 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/bash-logger.sh", "timeout": 5 }] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/autosave-commits.sh", "timeout": 10, "async": true }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/narrative-reminder.sh", "timeout": 10 }] }
    ],
    "FileChanged": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/narrative-reminder.sh", "timeout": 10, "asyncRewake": true, "rewakeMessage": "cs woke this session:", "rewakeSummary": "cs" }] }
    ],
    "CwdChanged": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/narrative-reminder.sh", "timeout": 5 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/session-end.sh", "timeout": 30 }] }
    ],
    "SubagentStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/subagent-context.sh", "timeout": 10 }] }
    ],
    "PostToolUseFailure": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/tool-failure-logger.sh", "timeout": 10, "async": true }] }
    ],
    "PermissionRequest": [
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/session-auto-approve.sh", "timeout": 5 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/scope-prompt.sh", "timeout": 5 }] }
    ]
  }
}
```

Hooks activate wherever `cs_resolve_session` finds a session: from the exported `CLAUDE_SESSION_NAME`/`CLAUDE_SESSION_DIR` when `cs` launched the conversation, and otherwise by walking up from the directory the front end opened — except in a terminal, where only a `cs` launch resolves (see "How a hook finds its session" above). Outside a session root, and in a session carrying `.cs/local/disabled`, they pass through without effect.
