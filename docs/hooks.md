# Hooks

The installer configures Claude Code hooks that enable session management features.

## Skills

| Skill | Behavior |
|-------|----------|
| [`prose-hygiene`](../skills/prose-hygiene/SKILL.md) | Judges a draft with a scoring rubric and reports its score. The caller controls revision and repeated scoring. |
| [`/write-as-me`](../skills/write-as-me/SKILL.md) | Drafts in your voice using a writing profile. Its corpus contains typed transcript messages and supplementary writing from `.voice/sources/*.md`, included on each build. |

## How a hook finds its session (`cs-resolve.sh`)

Every hook opens by sourcing `cs-resolve.sh`, a library shipped alongside them and
never registered against an event, and calling `cs_resolve_session`. The library
also carries the lead claim and the tests built on it (`cs_lead_claim`,
`cs_lead_claim_end`, `cs_is_lead`, `cs_is_shown_nested_child`, described below), and
`_cs_terminate_jsonl`, which repairs a JSONL tail left unterminated by
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
`cs_actor_slug`, `_slugify`), the narrative budget (`CS_NARRATIVE_MAX_DEFAULT`,
`CS_NARRATIVE_KEEP_DEFAULT`, `_narrative_budget`), the atomic file rewrite
(`cs_write_atomic`: a uniquely named `.cs-tmp.` temp file in the destination's directory,
which a session's `.gitignore` ignores, the destination's mode kept, renamed into place only when the command succeeded), its append and directory
twins (`cs_append_inside`, `cs_mkdir_inside`), the link check all three run first (the
session is the nearest directory above the destination that holds a `.cs`, unless a link
inside an outer session leads to it, and then the outer session is the one checked; the writer
refuses a write a link would carry out of it and names the link on stderr, and checks a
new directory at its nearest existing level, makes it only inside a `.cs` that exists and never the `.cs` or anything above it, one level at a time, so a writer for a session removed under it fails instead of building it again; a path or link target with a name ending in a newline is refused,
since `$(...)` drops that newline and would check a different path; hooks set `CS_WRITE_QUIET=1`, so any other write
failure stays silent), and the
machine-local state writers (`cs_local_state_set`, `cs_local_state_unset`), which take a
lock beside `.cs/local/state` so cs and session-start.sh take turns, the vault holder list's add and drop (`cs_vault_holder_add`, `cs_vault_holder_drop`), and the lock they and the window title share (`_cs_lock`,
`_cs_unlock`): flock(2) on a `<file>.mutex.lock` file, taken through perl on fd 9, which the kernel releases when its holder exits or dies. A writer that has waited 5 seconds on a live holder writes anyway. The hooks also read a session through it the way cs does: where the content files live
(`cs_local_dir` and `cs_private_dir`, which answer nothing while git tracks a file there, and
`cs_handoff_dir`), whether git tracks one (`cs_files_tracked_notice`, and `_cs_head_on_git_walk`
for a directory git would take for a repository), the pid in `.cs/session.lock` when that
process runs (`live_lock_pid`), the `cs <name> --remote` server's pid (`_remote_server_pid`),
the tmux window title (`cs_tmux_title_window`), and the rule that prints a name a clone
supplies as plain text (`_cs_plain_name`). The library holds more than the functions named
here. Edit the `lib/` file and rebuild; CI's
build-sync job fails on a `hooks/cs-shared.sh` that differs from the build. A hook sources
it under the same guard as `cs-resolve.sh`, and carries no copy of its own: without it,
session-start.sh names the actor `unknown` and says the library is missing and that
`./install.sh` (or `cs -update`) redeploys the hooks, and neither hook measures narratives
against a budget it does not have. The state writers are missing too, so session-start.sh
records no `claude_session_id` or `last_resumed` and says so. An armed queue does not drain.

The same build appends `lib/03-config.sh`, the [settings file](configuration.md#settings-file)
loader, to `hooks/cs-shared.sh`, writes it alone to `hooks/cs-config.sh`, and splices it
into `bin/cs-statusline` between two marker lines; CI's build-sync job diffs all three. At
its source it fills every `CS_*` setting the environment does not pin from the session's
`.cs/local/config`, else `~/.config/cs/config`, in that shell only. `scope-prompt.sh`,
`prompt-rewriter.sh` and its two rewriters read a setting before they source
`cs-shared.sh`, so each sources `cs-config.sh` first; without it they run on the
environment alone.

`cs_resolve_session` resolves in
two ways and declines when neither applies, leaving each hook to take its own decline
path (a silent exit, or the approval payload the blocking hooks owe Claude Code):

1. **The environment**, when `CLAUDE_SESSION_NAME` and `CLAUDE_SESSION_DIR` are set.
   `cs` exports them before `exec`, so a CLI session resolves here and never reaches
   the walk. This path is what it always was.
2. **The directory**, otherwise: walk up from `CLAUDE_PROJECT_DIR` (or the hook
   input's `cwd`) looking for the `.cs/` that marks a session root, and accept it only
   when the sessions root knows it: an entry under `~/.claude-sessions` (or
   `CS_SESSIONS_ROOT`, when the front end passes it on) that is the directory or a
   link to it, compared by inode. cs puts every session it makes there, so a cloned
   repository that ships a `.cs/` of its own is not a session, whatever it carries
   under `.cs/local/`; a hook cannot run the checks `cs` runs at open, so nothing
   inside the directory can stand in for the entry. The nearest `.cs/` decides and an
   unknown one declines, so such a clone inside a real session binds to nothing rather
   than to the session around it. The walk stops at `$HOME` so a stray `~/.cs` cannot
   adopt everything beneath it. There is no `$PWD` fallback: a hook's working
   directory is wherever the front end left it, not a statement about which session
   is open. An agent-team teammate walks in the same way, from a pane the tmux
   server started with its own environment, so a launch inside tmux publishes
   `CS_SESSIONS_ROOT` into that tmux session (as it does the truecolor flag) and a
   session under a non-default root stays recognised by its teammates.

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
the claude named by `CLAUDE_PID` and lets the walk proceed only when that argv carries all
three of `--agent-id`, `--agent-name` and `--team-name`, the set Claude Code requires to
launch a teammate. One flag alone would also match a prompt that merely mentions it. A
process whose argv cannot be read is not a teammate, so it declines.

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
may write it: the one `cs` launched (the lead). `cs` exports `CS_LEAD_PID` with the pid
it hands to claude and Claude Code stamps every hook env with `CLAUDE_PID`. The
fresh-spawn arms `exec`, so there claude carries `cs`'s own pid and the two are
equal. The resume arm runs claude as a child, since it needs the exit status to fall
through to a fresh rebind when there is nothing to resume, and a `CLAUDE_CODE_BIN`
that forks claude rather than `exec`-ing it (`op run --`, a script without `exec`)
puts claude below the launch pid on any arm. What the lead starts (a mod's process
run, a `claude -p` from the Bash tool) sits below the launch pid as well and inherits
every export, so neither the environment nor the process tree tells the lead from
its children.

Instead, the lead claims its launch. Every launch exports `CS_LEAD_CLAIM=1` beside
`CS_LEAD_PID`, and under it, on every `SessionStart` source, session-start.sh
writes `.cs/local/lead-pid` as `<CS_LEAD_PID> <CLAUDE_PID> <session_id>`
(`cs_lead_claim`). The claude carrying the launch pid always claims. Any other claude
claims only when `ps` shows the launch pid among its ancestors, and only while no
live claude holds the claim or the holder is one it started. Reading the holder and
writing the claim are one step under `.cs/local/lead-pid.mutex.lock`, so two claudes
that start at once take turns. The lead's
`SessionStart` runs before the lead can start anything, so the first claude under
the launch to claim is the lead and keeps the claim while it lives; a claude the
lead started before its own `SessionStart` ran (another plugin's `SessionStart` hook
running `claude -p`) claims first and gives way when the lead's turn comes, and gives
way too when the two claim at the same moment. A hook
takes a claude as the lead (`cs_is_lead`) when `CLAUDE_PID` equals `CS_LEAD_PID` or
the claim for this launch names `CLAUDE_PID`. A claim keyed by another launch pid
counts for nothing, and every launch removes the file once it holds the session lock,
before claude starts, so a claim cannot speak for a later launch that drew the same
pid. A claim whose claude pid is not a positive number (`0`, `00`, `-1`), or whose
line goes on past the conversation id with anything but a single `ended`, is no claim
to any hook: it names no lead, shows no claude a guest, and a claude under the launch
claims over it. A claim with no end mark that names no live claude (its claude died
without a `SessionEnd`) holds nothing and shows no one a guest, so the lead claims over
it. Only a regular file is a claim:
a hook never follows a link in its place and writes neither through a link nor over
a directory there, silently. A launch removes a link there; it refuses to open while
a directory sits there, and names it, since cs does not remove a directory it did not
make. The lead's `SessionEnd`, at an end other than `/clear` or `/resume`, marks the
claim ended, `<CS_LEAD_PID> <CLAUDE_PID> <session_id> ended`, under the same lock
(`cs_lead_claim_end`), and leaves it in place. Claude Code runs `SessionEnd` hooks
while the lead still lives, and a claude another `SessionEnd` hook starts then (a
`claude -p` that summarises the session) finds the claim naming a live claude it did
not start and gives way. Claude Code cancels a `SessionEnd` hook that runs past its
timeout, and a claude that hook started may outlive it, so that claude may start, or
stop, after the lead has exited. Under an ended claim every claude that is not the lead shows as
a guest whether the lead still lives or not, so it neither rebinds the recorded
conversation nor takes an armed rotation, the queue digest at its start or the
attention flag. Its prompts do take the queue digest: `scope-prompt.sh` surfaces
it on any claude's prompt.
Once the lead has exited, a claude its hooks left running is no longer under the
launch pid, so it cannot claim either. The fresh conversation the resume arm starts
after a quick failure carries the launch pid and claims over the ended claim; behind a
`CLAUDE_CODE_BIN` that forks claude that conversation runs as the launch pid's child
and claims over it too, since the lead the claim names has exited. The next launch removes the file. A
context-limit fork, an in-process `/clear` and a compaction keep the process, and the
next start renews the claim under the conversation now running; a `/clear` or a
`/resume` leaves the claim unchanged.

Under `cs <name> --remote` the launch pid is the remote-control server's, and the
conversations it starts run as its children with the launch's exports. The first one
to start claims the launch and is the lead. One started while the lead's claude
lives, before or after the lead's conversation ended, is a guest for its whole life,
since a conversation claims only at its `SessionStart`. The next conversation
started after the lead's claude has exited claims over the ended claim and is the
lead.

The hooks take the first claude under the launch to claim for the lead, and that sets
the contract for a `CLAUDE_CODE_BIN` wrapper: it must `exec` claude, or start exactly
one claude. A claude session the wrapper runs before it `exec`s or starts the real one
(a `claude -p` that tests a login, say) reaches its `SessionStart` while no claim stands
and takes it. While that claude lives the launch has two leads: it rebinds
`claude_session_id` to its own conversation, loads an armed rotation and raises the
attention flag, and its end removes the session lock, so the real claude runs with no
lock and the next `cs <name>` opens a duplicate without the collision menu. No hook can
tell that claude from the real one.

A session opened by a `cs` from before the claim carries no `CS_LEAD_CLAIM`, and an
update can install these hooks while the session runs. Its hooks write and read no
claim, so the claude carrying the launch pid is its only lead until the next
`cs <name>`, and every other claude under the launch shows as a guest. On the exec
arm that is every `claude -p` the lead runs: it cannot rebind the recorded
conversation or remove the lock, and it takes neither the armed rotation nor the
attention flag, nor the queue digest at its start (its prompts still take it
through `scope-prompt.sh`). On the resume arm, or behind a
`CLAUDE_CODE_BIN` that forks claude, the lead itself shows as a guest: no claude
rebinds the recorded conversation or removes the lock at its end, a `/clear` loads
no rotation, its start shows no queue digest (its prompts still do), and its
`Stop` raises no attention flag and
bounces no dock. An armed rotation stays armed and unconsumed, so the next
`cs <name>` offers it. Its hooks do none of the lead's other work either: its `Stop`
runs no queue drain, no mail wake and no rotation nudge and gives no narrative
reminder, and no hook arms the mailbox watch that wakes it when mail arrives. Its
`SessionStart` sets no tab title (the tmux window or the terminal tab), and its
`SessionEnd` does not hand the tmux window back. Behind a forking `CLAUDE_CODE_BIN`
on a launch where claude replaces cs, an encrypted session's vault stays attached
when the lead ends, until the next open detaches it; on the resume arm cs, still
claude's parent, detaches it when claude exits.

A claude under the launch that the claim does not name is a guest. A hook *shows*
it to be one (`cs_is_shown_nested_child`) when the claim names another claude that
is still alive, when the claim carries the end mark, or when the launch takes no claim and the
claude does not carry the launch pid. Where no claim stands under a launch that takes claims, because the
lead's `SessionStart` could not write one (git tracks a file under `.cs/local`) or
`ps` could not show the lead was under the launch, no claude shows as a guest: what
a guest must not take from the lead (the armed rotation, the once-only queue
digest, the attention flag) stays with whichever claude asks, and what a guest must
not remove (the lock) stays where it is.

Each hook also asks git one question as it resolves its session: does it track a file
in the directory that holds the queue, the mailbox and the rotation marker (`.cs/local`,
or `.cs/private` once that name exists)? `cs` refuses to open such a session, but a
`git pull`, a merge or a checkout can put committed files there while the session is
open. A repository wrote a tracked file, not this session, so while git tracks one the
hooks read no queue, mail or rotation marker from that directory and write nothing there:
the Stop hook hands out no task, the prompt hook shows no mail, stamps no date and leaves
the attention flag, a `/clear` loads no handoff, SessionStart records no conversation id,
SessionEnd's vault waiter records no pid (it still detaches the vault), and the session log
(`session.log`) stops. The status line, the `cs` and `cs-update` mods, the `rotate` skill's
arming of its marker and `/wrap`'s last pass stand down too. The status line
cannot ask git on every render, so each hook run leaves its answer in
`~/.cache/cs/tracked/<session name>`, and a pull goes unseen there until the next hook
runs. The status line reads the mark only for a name the hooks would write one for, never
an empty name or one holding `/`. The mods, the `rotate` skill and `/wrap` ask `cs -vet-session`. Git's pathspec settings in the
environment (`GIT_LITERAL_PATHSPECS` and its three siblings) are cleared for the question,
since a literal pathspec would match no file and read as nothing tracked, and so are
configuration settings passed through the environment (`GIT_CONFIG_COUNT`,
`GIT_CONFIG_PARAMETERS`), and cs passes `core.fsmonitor` empty, which turns it off, so a
repository's config cannot make the question run a command. Before it asks git anything, cs
walks from that directory up to the first directory that holds `.git`, as git's own search
does, comparing directories by the filesystem rather than by the spelling of their paths. A
directory on the way that holds `HEAD`, a link that leads nowhere included, counts as
tracked, since git would take it for a repository and run the commands its config names; the
walk catches a committed link into such a layout the same way, inside the session or out of
it. The message names one inside the session relative to it, with the `HEAD` to delete. It
names one outside it (a bare repository or a checkout's `.git` that holds the session, or a
bare repository that is the session directory itself) by its whole path and ends `Run cs -rm
to remove the session.` Git that fails to answer for any reason other than "not a git
repository" (a broken `~/.gitconfig`, a bad repository config, an unreadable index, a
`safe.directory` refusal, no git on `PATH` or one that cannot run) counts as tracked: the hooks stand down the same way, `cs` refuses
to open the session, a named verb (`cs <name> -queue` and the rest) refuses, and the message
carries git's first `fatal:` or `error:` line, or says git is not installed or not on `PATH`, or that the git it found there cannot run. Lines that `GIT_TRACE` or a trace2 setting
print ahead of it are not a failure. A file git tracks there still counts after you delete
its directory. One write stays: the prompt hook's launch
mark in `scope-prompt.trace`, made before anything that can stall, including git. `cs -queue` and `cs -msg` run inside the session
refuse on the same question. Each finished turn says why, in a system message that names the file
and the `git rm --cached` command that untracks it, or the directory git would take for a repository. That message is all the two Stop hooks
do until then: they send no narrative reminder and no rotation nudge, and raise no
attention flag. Its other two events do nothing: no mail wake, no rotation kick, no
watch re-armed. The check is one `git ls-files` per
hook run, about 0.05 to 0.09 s. `prompt-rewriter.sh` asks once per run and writes no
`rewrite.trace` while git tracks one; `memory-index-guard.sh` asks before each subcommand
and refuses all four with exit 2, naming the file.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start (including source: `startup`, `resume`, `clear`, `compact`) to `.cs/local/session.log` (`.cs/private/session.log` in an [encrypted session](session-layout.md#encrypted-sessions), and nowhere while its vault is locked) and appends a `started` event to `.cs/timeline.jsonl`
- On all sources: clears the statusline's attention marker (`.cs/local/attention`) — a fresh session is attended by definition — and, inside iTerm2 with shell integration installed, cancels any dock bounce the previous conversation left running (`CS_NO_ITERM2=1` disables)
- On all sources, for a claude `cs` launched under `CS_LEAD_CLAIM`: claims the launch in `.cs/local/lead-pid` (`cs_lead_claim`, see [How a hook finds its session](#how-a-hook-finds-its-session-cs-resolvesh)) before anything else asks which claude is the lead. It writes nothing while git tracks a file under `.cs/local`
- On all sources, **for the launched conversation only** (`cs_is_lead`, after this start's claim): rebinds `claude_session_id` in the machine-local `.cs/local/state` to the live conversation UUID from the hook input. Claude Code forks a new UUID when a conversation is continued past the context limit (the old transcript stays on disk), so the recorded binding can silently go stale and `cs` would resume the pre-fork conversation. Non-UUID session ids are ignored; each rebind is logged to `session.log`. Any other claude resolving the same session — teammate, `claude -p` child, desktop, walked-in — leaves the slot alone, so `cs <name>` always resumes the conversation that was opened and the `rotated` timeline lineage stays true
- On `startup`/`resume` only: configures `transfer.hideRefs`, and recovers autosaved changes from a crash of **this conversation only** — it reads just the current conversation's own ref (`refs/worktree/cs/session/<conversation-uuid>`), so a live sibling session's in-flight ref is never misread as a crash. It also renames its ref across a context-fork UUID rebind (a clean continuation), claims any pre-upgrade shared ref once via a compare-and-swap delete, and garbage-collects other conversations' refs older than 14 days. The whole-tree restore (`checkout <shadow ref> -- .`) is offered only when the snapshot's recorded base HEAD still matches the current HEAD; if HEAD has moved since the snapshot (a commit or rebase) or the snapshot predates base recording, it instead warns and points at per-file inspection — a blanket restore over diverged history would overwrite committed work
- On `resume` only: injects dynamic context (last activity, recent commits with the plain file names among the first five files they touched, objective, up to 5 most recently active sibling sessions with their objectives, followed by the full `cs -msg <session> "<body>"` send form and its `--kind` values, which appear only when a sibling exists to send to; scope-prompt.sh's digest already carries inbound mail, so this block is the only place cs states the outbound form. The block asks Claude to raise an AskUserQuestion before starting work that belongs to a sibling's stated goal rather than merely sharing its vocabulary, and to offer both paths rather than push one; the bar sits high on purpose, since a routing prompt that fires on every overlap becomes a block nobody reads), and a per-actor digest of shared memory/narrative activity since this actor's `.cs/local/watermark` (grouped by git author; and, for each teammate narrative that grew since that watermark, committed or not, and is a regular file with a plain name directly below `.cs/memory`, the added-section count and the line the new content starts on, taken from the last hunk that adds lines in a diff against the working tree, so the actor reads its own file in full and only those lines of the others; a narrative nobody has committed goes unmentioned, since nothing exists to measure it against, and the hook names uncommitted growth again on every resume until a commit carries it), then advances the watermark and stamps the day's date into `last_resumed`. In a git repository the `Session State` block always prints and ends with a line saying the conversation before this one may have finished actions its summary does not show, and to check `git log`, `cs -msg log` and the remote before repeating a push, a merge, an install or a message
- In a feature worktree (when `task_branch` is in machine-local state): injects a Feature Worktree contract instructing Claude that integration and retirement both go through `/finish <feature>` in the base session, that retirement waits for this conversation to close, and never to merge the branch manually
- Where the conversation genuinely starts clean — source `clear`, or source `startup` with `CS_FRESH_REBIND=1` — injects a Fresh Conversation notice so Claude treats the turn as a clean break. The source is part of the test because `CS_FRESH_REBIND` is exported before `exec` and outlives the launch: on its own it would tell a later `/compact` of a rebound session that its transcript is not loaded while it still is
- When a `.cs/local/pending-handoff` marker is armed (by the `rotate` skill, or by the launch prompt's `r` answer): consumes it — flips the named `.cs/handoffs/` file's frontmatter to `consumed` (recording the new conversation UUID), removes the marker, and injects a Conversation Rotation preamble pointing Claude at the handoff to read first and asking it to reconcile its native task list with the handoff before executing: cs launches claude with `CLAUDE_CODE_TASK_LIST_ID` set to the session name, so the list survives `/clear` and the successor inherits it; a mirror into it would duplicate every carried item (mutually exclusive with the Fresh Conversation notice above, since a rotation is also a fresh start). The preamble also asks Claude, once the handoff's next step is done, to append a `## Successor report` to the handoff it consumed: what it had to look up again, re-derive, or found wrong, or `none`. Nothing commits that report (cs commits no session file; the user does, when they ask), and the rotate skill's prune skips a handoff with uncommitted changes or one git does not track, so a report is never deleted before it is recorded. The instruction rides only the `startup` and `clear` injections, so a compaction before the next step finishes drops it. Consumption requires source `startup` or `clear` **and** a handoff whose frontmatter still says `unconsumed`; a marker naming a spent or missing handoff, or a file name that is not plain, is stale and is removed silently. On any other source the marker is left untouched, so a compaction or a context-limit fork between the rotate skill and `/clear` cannot eat a pending rotation. The same resolution decides the rebind's timeline label — `handoff` with the name, or `rebind`. A `claude` started from inside the session (a `claude -p` the lead's Bash tool ran) and a tmux teammate get no rotation and leave the marker and the handoff as they are: the rotation is the lead's. Where no claim stands under a launch that takes claims (the lead's `SessionStart` could not write one, or `ps` could not show the lead was under the launch), a `claude` the hooks cannot show to be a guest keeps the rotation, and a `claude` shown to be the lead is never taken for a teammate, whatever its command line holds. Under a launch that takes no claim (no `CS_LEAD_CLAIM`), only the claude carrying the launch pid gets the rotation: on the resume arm or behind a forking `CLAUDE_CODE_BIN` the lead does not, and the marker and the handoff wait for the next `cs <name>`
- On all sources: surfaces the same queue-inbox digest as scope-prompt.sh — unseen entries in `.cs/local/notifications.jsonl` (task counts, the last breaker trip if any), gated by the `.cs/local/notifications.seen` cursor so it's shown at most once. Whichever of the two injection points runs first (this hook fires once at session start/resume; scope-prompt.sh fires on every prompt) claims the surfacing and advances the cursor for the other. Shares the `_build_digest` jq recipe verbatim with scope-prompt.sh ; the recipe has not moved into `cs-shared.sh`, so an edit to one copy goes into the other as well. A `claude` started from inside the session, or a tmux teammate, is not shown the digest and does not move the cursor
- Does NOT surface the cross-session mail digest: that lives only in scope-prompt.sh now (it fires on every prompt), so duplicating it here would double-inject the same unread bodies on every startup and resume
- On all sources: names the current actor and its narrative file in the injected context, and states that the durable memory buckets are shared while only narratives are per-actor, so an entry naming someone else as the user was written by or for another actor. `.cs/memory/` is one store for every actor on a git-synced session, so a `type: user` entry written as an unconditional claim loads for all of them and reads as settled fact; a bare identity line is not enough, because a global instruction naming the right person was already in context and lost to such an entry. The actor precedence (`$CS_ACTOR`, then `.cs/local/identity`, then git `user.email`/`user.name`) is `cs_actor_raw` from `cs-shared.sh`, the same function `cs -whoami` runs; shelling out to `cs` instead would make the hook depend on `cs` being on `PATH`
- On all sources, every actor: measures each `.cs/memory/narrative.*.md` against `CS_NARRATIVE_MAX_BYTES` (default 131072, from `cs-shared.sh`, the same value `cs -narrative rotate` uses) and, for any over budget, adds a `NARRATIVE OVER BUDGET` block naming the file and its size. For the actor's own file it says run `cs -narrative rotate` before the full read; a teammate's is theirs to rotate, so it says read only from the line the digest names. The Read tool refuses a file over 256 KiB, and the protocol's "read it in full" would otherwise send the model straight into that refusal. The hook rotates nothing: it only names the over-budget files
- On all sources, for the launched conversation only: sets the tab title back to `cs: <name>`. cs sets it once at launch and cannot reset it, since cs execs into claude, so a second `cs other` on the same terminal would otherwise leave its name on this tab. Inside tmux it goes through the server: `select-pane -T` titles the pane with this session alone, and the window is named after every cs session running in its panes, `cs: a | b` in pane order, each pane recording its own in the `@cs_session` pane option. iTerm's tmux integration keeps the tab's title itself and never takes it from a tmux rename, so when `LC_TERMINAL` is `iTerm2` (and `CS_NO_ITERM2` is unset) every claim and release also starts `cs-iterm-tab.py` in the background, which sets the tab showing this window to the same `cs: a | b` through iTerm's Python API (the `iterm2` module, on the first `python3` in `PATH`). A tab counts only when iTerm's attachment answers for the same tmux server (`#{pid}` and `#{socket_path}`), since window numbers repeat across servers; if the last session leaves while the title is being set, the helper hands the window back to `automatic-rename` as the release did. Nothing waits on it and its output is discarded, so without iTerm's API or the module the tab keeps its last title and nothing else changes. Every claim turns `allow-rename` and `allow-set-title` off again, so a window a `/clear` briefly released does not rename itself after the running program. Outside it the hook writes the OSC 0 escape to the terminal device, and a front end with no terminal skips it. While `.cs/local/remote.pid` names a process running `remote-control --name <name>`, the lead is a conversation that `cs <name> --remote`'s server started, and the window and tab are the server's: the hook sets no title, inside tmux or out, so the window keeps its `remote:<name>` name and the tab its `cs: <name> (remote)` title
- On all sources: exports session environment variables, injects session context into Claude's system prompt

## autosave-commits.sh (PostToolUse on Write/Edit)

New sessions begin with one commit of their initial files.

Runs after any file modification (Write or Edit), providing crash recovery for all session files:
- Autosaves the entire working tree to the conversation's own shadow ref `refs/worktree/cs/session/<conversation-uuid>` (keyed on the hook input's `session_id`) using git plumbing commands. Each conversation writes, recovers, and deletes only its own ref, so concurrent sessions on one checkout — and parallel worktree sessions — never share or clobber each other's snapshot chain
- Does not create commits on `main` or touch the working tree index
- Chains each snapshot onto that conversation's previous one (a linked list per conversation)
- Records the HEAD the snapshot sits on as a `cs-base` commit trailer, read before the tree is written so a HEAD that moves mid-snapshot is never mislabelled; crash recovery uses it to tell whether HEAD has since moved and refuse an unsafe whole-tree restore
- Skips the snapshot (never waits) while `<git-dir>/cs/integrate.lock` exists — the per-checkout mutex `cs <base> -integrate-feature` holds while it fast-forwards the base, so only the checkout being landed on pauses — and holds that same directory itself for the duration of the tree write
- For narrative file edits, also logs the latest heading/bullet to `session.log` (behind `.cs/private/` in an encrypted session, and nowhere while its vault is locked)
- Runs in background to avoid blocking the session

## stop-blocks.sh (Stop, FileChanged, CwdChanged)

Registered for three events. On `CwdChanged` it only re-arms the maildir watch and exits; on `FileChanged` it runs the rotation kick or the idle mail wake and exits before everything below; on `Stop` it runs the rest.

This hook and stop-notices.sh parse-check `cs-resolve.sh` and `cs-shared.sh` with `bash -n` before sourcing them, because sourcing a truncated or corrupt library leaves part of it defined. A file that passes leaves a memo under `~/.cache/cs/parsed/`, per file and per bash, and is checked again only once it is no longer older than that memo. A failed check records nothing. A corrupt file given an older modification time than the memo, such as a restored backup, goes unchecked. `cs -uninstall` removes the memos with the rest of that directory.

**Rotation auto-start.** After a `/clear` on an armed handoff, the rotation begins on its own — no keystroke. session-start.sh cannot start a turn (a hook runs inside an already-started process), but it can arm one: it watches `.cs/local/rotation-kick/` and leaves a detached child to drop `rotation.kick` there a couple of seconds later, once Claude Code's watch is up. That `FileChanged` lands here and exits 2, waking the model with a reason that carries the instruction the user's "go" would have carried. Deliberately off the mail budget: `CS_MAIL_WAKE_MAX` bounds a volley of arrivals nobody asked for, while a kick is one file the session wrote for itself, once per `/clear`.
- Armed only on `source=clear` with a handoff loaded, and only in the launched conversation — the `startup` path is the launch prompt's `r` answer, where cs has already handed claude a positional prompt, so a wake there would land on top of a running turn
- `.cs/local/rotation-kick/delivered` makes it one kick, one wake: Claude Code fires `FileChanged` on unlink as well as add, so a session that cleaned up after itself would otherwise wake on its own tail
- Does not yield to the queue, unlike the mail wake: nothing resets `queue.state` on a `/clear`, so a stale armed or draining state would strand the rotation, and two seconds after a `/clear` no drain turn can be in flight. The drain is Stop-driven, so the rotation turn's Stop resumes it
- The reason yields to the user: the notice invites them to type instead and the kick is written either way, so a message sent inside the arm window lands first and the wake arrives behind it. The preamble's content-takes-precedence rule covers a *first* message, not a system-reminder after one — so the reason says outright that a user message already sent wins and the wake is spent
- `CS_ROTATION_KICK_DELAY` (default 2) is the interval between the child's writes. The watch arms only once session-start.sh has returned, and a write before that is an event nobody hears: the hook took 4.4 s on an idle machine and 21 s under a parallel test suite, and a rotation whose writes all landed early sat idle under a notice promising it would continue. So the child re-writes the kick every interval until `delivered` appears, up to 30 attempts. At the default interval that is about a minute of sleeps, past the hook's 30 s timeout, after which no watch can arm. `CS_NO_ROTATION_WAKE=1` opts out, and both the preamble and the user-facing notice change wording to match which path is live

**Mail wake.** Unread cross-session mail (`cs -msg`) takes a turn, so an agent-to-agent exchange advances without waiting for a keystroke. Two events cover two moments: `Stop` reaches a session that has just finished work, `FileChanged` reaches one already parked at the prompt, because Claude Code's file watcher runs on its own event loop. The watched path is the session's `mail/new/` (under `.cs/local/`, or `.cs/private/` in an [encrypted session](session-layout.md#encrypted-sessions), whose wake stands down while the vault is locked), handed over as `watchPaths` from session-start.sh, which also creates the maildir first — a watch armed on a path missing two levels never fires again for the process's lifetime. A cwd change then *replaces* that dynamic watch list with whatever the session's `CwdChanged` hooks collectively return rather than merging into it, so a session that answers nothing loses the maildir watch for the rest of its life, and nothing later restores it: `watchPaths` rides on only three events, of which `SessionStart` has already happened and `FileChanged` cannot fire once the watch it depends on is gone. Registering a `FileChanged` hook is itself what makes cwd changes replace the list, so the mailbox arms the event that disarms it. The `CwdChanged` branch answers with the maildir — creating it first, for the same reason — which turns the event that wiped the watch into the one that re-arms it, and exits before the drain: an unhandled event falls through into the walk-away run and pops a queued task, so a directory change would silently consume work. The `FileChanged` entry carries no matcher (for that event the matcher doubles as a dispatch query tested against the changed file's *basename*, which is unpredictable for a maildir), so the hook filters `file_path` to its own mailbox and ignores `unlink`, which fires once per message as `cs -msg` moves mail to `cur/`.
- Delivery differs by event: `Stop` emits a `block`; `FileChanged` writes the reason to stderr and exits 2 (`asyncRewake`), which Claude Code wraps in a system-reminder and enqueues at `priority: "next"` — so it arrives as trusted context rather than as fabricated keyboard input
- The reason names the count and the senders — `Unread cross-session mail (2), new from "alice"` — so a woken session knows who is writing before it opens the mailbox. Each sender comes out of the same `jq` call that already reads the document's `.kind`, so naming costs no extra pass, and repeat senders collapse to one name. Each name is cut to 40 characters, anything in it outside letters, digits and `. _ @ : -` becomes `_`, and it is quoted, so a name that reads as words cannot run on into the instruction beside it. The clause says **new from** because the two halves describe different sets: the count covers every unread document, while the names come only from the ones this wake announces, since the discharge skip runs ahead of the read that would learn a sender. Naming every unread sender instead would cost one `jq` per unread document per turn end — what the scan is built to avoid, and what the wake ceiling makes ordinary rather than rare. A sender is the document's `.from`, falling back to `.actor` when `.from` is empty: `cs -msg` records `.from` as the sending session's name, which is empty for a send from a plain terminal, and jq's `//` fires on null but not on `""`
- Fires once per arrival. `.cs/local/mail/woke` holds the filenames already discharged, meaning announced by a wake, written tmp-then-rename under a per-process name because both events write it and the idle one overlaps itself. Neither a count nor a newest-filename mark would work: unread drops to zero whenever `cs -msg` moves files to `cur/`, and filenames are not ordered by arrival
- A run silenced by `CS_NO_MAIL_WAKE=1` or by an armed/draining queue records nothing, so the message still wakes once the gate lifts. An empty queue never gates, whatever `queue.state` records
- Only the launched conversation wakes (the same `cs_is_lead` test session-start.sh uses): a tmux teammate is a full claude with its own `Stop`, and N wakers on one maildir race to read it where the first `mv` wins
- Bounded by `CS_MAIL_WAKE_MAX` (default 5) wakes, counted in `.cs/local/mail/wakes` and cleared by the next user prompt — nothing else caps two sessions volleying at each other

On `Stop`, also:
- Raises the statusline's attention marker (`.cs/local/attention`, machine-local) so the Claude mark takes its darker `brandshade` color until the user next interacts; skipped inside subagents, for a `claude` started from inside the session and for a tmux teammate, none of which ends a turn of the lead's
- Inside iTerm2 with shell integration installed (`~/.iterm2/it2attention`), also starts a dock bounce whenever it raises the marker, so the finished turn reaches a user working in another app; escapes go to `/dev/tty` because hook stdout is captured. `CS_NO_ITERM2=1` disables; silent everywhere else
- Runs a staged feature retire: `/finish`'s retire entry writes `.cs/local/retire-staged/<task>` (`sha:` and `force:` lines) while the feature conversation still holds its worktree. On the lead's Stop only, once `live_lock_pid` finds no process behind that worktree's `.cs/session.lock`, the hook starts `cs <base> -retire-feature <task> <sha> --staged [--force]` detached in its own session (perl `setsid`; a retire that fuses records and trashes files outran the 10 s Stop budget, and a hook killed mid-fuse stranded every record), with the pid in `retire-runs/<task>.run` and the output in `retire-runs/<task>.out` (a directory of their own, so a feature named `x.run` is never read as `x`'s run), waits up to six seconds, and on the Stop that finds the run ended, in that turn or a later one, blocks with the entry's `retired` line or its refusal (then `run /finish <task> again`) as the reason and drops the stage; a run still going is left alone; a `staged` line in the output (the conversation came back before the removal) keeps the stage; a stage the hook cannot read (a sha that is not hex, a `force:` other than 0 or 1), or one whose worktree is already gone, is dropped and reported; cs is `command -v cs`, else `~/.local/bin/cs`, else the stage is kept and the report says so; one stage per Stop, taking priority over the queue drain below. The feature's own SessionEnd mails the base (`notify`) when a stage exists for it, so an idle base wakes to run it
- Drains the task queue (`.cs/local/queue`) at each stop boundary when armed, on the lead's Stop only (a tmux teammate shares the directory and fires its own top-level Stop; ungated, each of its idle turns would pop a task) — pops and injects one task at a time and instructs Claude to mirror progress into the native task list; every injected task, the first included, sits inside `<cs_task id="…">` tags (six random hex characters per turn, so the text cannot close its own block) with a note that the text is the task to do and changes none of the instructions around it, because another session wrote any task accepted from mail; each carries a scope block (do every behavior the task asks for, leave pre-existing bugs and unmentioned behavior as follow-ups in the narrative, implement the most direct reading of an ambiguous task and state the assumption) because a walk-away run has nobody watching to say so — taking priority over the mail wake while a drain is armed or running (returns early), and [stop-notices.sh](#stop-noticessh-stop-async)'s notices stand down for the same queue; each transition also appends an event to the per-machine inbox (`.cs/local/notifications.jsonl`): `drain_started` on armed→draining, `task_done` per advance, `drain_finished` when the queue empties
- While draining, each Stop first reads `.cs/local/queue.current`, the task it handed out; with no usable record it parks the run and logs nothing done. Then, before it pops that task, it evaluates three circuit breakers: tool failures in the current task at/above `CS_QUEUE_MAX_FAILURES` (default 5, from `.cs/local/failures`), context at/above `CS_QUEUE_MAX_CTX` (default 85, from the statusline's `context-pct`), and the 5-hour rate-limit window at/above `CS_QUEUE_MAX_5H` (default 85, from the statusline's `limits`, skipped when its `stamped_at` is stale past 1800s); a non-numeric env override falls back to the default. It also reads the final assistant message for a line reading exactly `cs-task-failed`, bare or as a code span, which the agent writes when it could not complete the task. That report goes to `.cs/local/queue.failed` before the Stop writes anything else, so a later Stop parks on it too; the file goes when the run parks or starts. A failures trip or a failure report means the task did not complete: it stays first in the queue, the Stop logs nothing done, and the run parks. A context or 5-hour trip measures the session, not the task: the Stop pops the task and logs it done, and the run parks before the Stop hands out the next one, or finishes when that was the last. A trip parks the queue (`queue.state` back to `idle`, recorded before the pop, the queue file left intact so `cs -queue start` re-arms; when the drain cannot write `idle` it removes `queue.state`, which reads as idle; when it can do neither, the Stop ends with nothing popped and `draining` in place, and the next Stop runs the same checks on the same task), appends a `breaker_tripped` event to the inbox with the reason and reading (`task_failed` for a failure report), and emits a `block` debrief naming what tripped and how many tasks remain. The drain reports any other state it cannot write as `cs task queue: could not write <path>`. The per-task failure count (`.cs/local/failures`) resets to zero on the armed→draining transition and again after every drain advance, so each task starts the breaker fresh
- Spawned workers report back: when `.cs/local/spawned-by` exists, drain completion sends the spawner a mailbox notify and deletes the marker (one-shot); a breaker trip notifies but keeps the marker so the eventual drain still reports.
- When idle with tasks queued, ends the turn without asking and writes nothing: the `cs` mod's band offers the start through its `▤ run N queued tasks` press. Task text is arbitrary, so the `block` reason a drain injects is emitted via `jq -nc --arg` rather than string interpolation, keeping the JSON valid regardless of quotes or newlines in the task
- Approves silently inside subagents and outside cs sessions

## stop-notices.sh (Stop, async)

The turn-end notices: the rotation nudge, the context warning and the narrative reminder with its advisor note. cs registers the hook with `"async": true`, and it hands its text over as `hookSpecificOutput.additionalContext`, so Claude Code draws no `Ran N stop hooks` row in the chat for it, and the text reaches Claude as context at the start of the user's next prompt. A synchronous `Stop` hook that returns text, as a block's reason or as `additionalContext`, always draws that row, and nothing a hook prints hides it. The trade is that a notice never forces a turn: Claude acts on it at the next prompt, not at the end of the turn that raised it. Whatever must continue the turn (the queue drain, the staged retire, the mail wake) stays a `block` in [stop-blocks.sh](#stop-blockssh-stop-filechanged-cwdchanged). The hook prints at most one notice per run, exactly one JSON object or nothing, and exits 0 on every path it owns: Claude Code takes the first object it can parse from the hook's stdout and drops the rest, and a non-zero exit reaches Claude as a hook error carrying the stderr. Its registered timeout is 10 s; past it Claude Code kills the process and drops whatever it printed, so the hook runs inside a budget of 8 s counted from its start: the narrative scan (one `stat` and one `wc` per `narrative*.md`), the work count (one `tail` and one `jq` over at most 4 MB of transcript) and the plugin probe (one `jq` over `installed_plugins.json`) run first, the verdict wait below ends at the budget, and the lock below waits only for what is left of it, so the print is the last thing before exit. A run that is killed costs one notice, never a duplicate. It stands down, printing nothing, while the task queue is armed or draining: on the lead's `Stop`, with a task queued and `queue.state` reading `armed` or `draining`. An empty queue never gates, whatever `queue.state` records, and a tmux teammate's `Stop`, which never drains, is not gated.

The notices also stand down for every block [stop-blocks.sh](#stop-blockssh-stop-filechanged-cwdchanged) answers the same `Stop` with, through a verdict handshake: a drain that trips a breaker or hands out its last task writes `idle` before it blocks, so the queue state alone says nothing, and the staged retire and the mail wake never touch it. On the lead's `Stop`, stop-blocks.sh writes `.cs/local/stop-verdict`, one line `<key> <word> <epoch>`, overwritten per `Stop`: the key is `cs_stop_key`'s (cs-shared.sh, with a copy in each hook for a partial install, held to one text by `tests/test_hooks.sh`), the `cksum` of the Stop input, which Claude Code hands both hooks byte for byte, and after a dot the byte size of the transcript the input names, read by both hooks at their start. The input alone repeats across turns (session_id, transcript_path and last_assistant_message can all be the same on two Stops), and the transcript holds the turn's assistant message before Stop fires and takes the hooks' output only after they exit, so the size tells two Stops apart; a transcript the input does not name, or that cannot be read, leaves the `cksum` alone as the key, and the epoch is for a reader. The word is `pending` from the moment the sync hook knows the `Stop` is the lead's, and `approve` or `block` from its exit, every block routed through one function so the two can never disagree. Claude Code starts the two hooks together, so stop-notices.sh waits, once it has something to say: no line for its key inside two seconds of its start means no verdict is coming (a partial install, or a sync hook that predates the verdict) and the notices go ahead as before; a `pending` line extends the wait to `CS_STOP_VERDICT_WAIT` seconds from the start (default 7, clamped to the 8 s budget), after which a verdict still pending counts as approve, and `block` ends the run silently with no cursor or cooldown spent. The sync hook turns its verdict to `block` only once the block line exists, so a block it could not print (a failed `jq`) leaves `approve` for its exit to post. The staged retire can block later than the bound (its settle waits up to six seconds, twice), and a notice then lands beside that block, as every notice did before the handshake. Measured in `tests/test_hooks.sh`: a lead `Stop` with no verdict costs the two-second grace, one with an approve posted costs nothing, and one with a verdict pending for ever beside a lock a stray process holds ends inside the budget. A teammate's `Stop` neither writes nor reads the verdict: every block the sync hook answers with is the lead's.

The notices are worded for where they land, beside the user's next request and about the turn that ended before it: each says it is carried over, names what the previous turn ended on, and asks Claude to answer the request below. The tiers run in order, and the first that speaks ends the run, so the rotation nudge and the context warning never both fire on one `Stop`, and either one keeps the narrative reminder for a later turn. That ordering is why the three share one script: three hooks running side by side could not see each other's decision.
- Rotation nudge: when context is at or above `CS_ROTATE_NUDGE_CTX` (default 65, non-numeric override falls back to the default) per the statusline's `context-pct`, hands Claude a notice saying context was at that reading when the previous turn ended, to tell the user in one line, answer the request, and then invoke the `rotate` skill to write a handoff and arm it (before the request when it is large enough to need the headroom), after which the user runs `/clear` to continue in a fresh conversation. An armed or draining queue gets no nudge: the drain's context breaker owns hot context during a walk-away run
- Both context tiers read `.cs/local/context-pct`, which the status line writes for the launched conversation alone, so both stay silent in a tmux teammate: the reading is the lead's, and a teammate acting on it would announce the lead's context as its own.
- Context warning: one tier below the nudge — when context is in the `[CS_CTX_WARN_CTX, CS_ROTATE_NUDGE_CTX)` band (defaults 40 to 65; a non-numeric override falls back to its default), hands Claude a notice saying context was at that reading when the previous turn ended, past the comfortable-headroom mark, to tell the user in one line so they can steer toward a stopping point or plan a rotation, then answer the request. At or above the nudge threshold only the rotation nudge fires — never both in one Stop
- Each context tier's cursor is an append-only list of conversation UUIDs (`.cs/local/rotate-nudged`, `.cs/local/ctx-warned`; append-only so a tmux teammate sharing the directory cannot re-arm the lead's notice), read and written under the hook's lock (`.cs/local/stop-notices.mutex.lock`), the same one the cooldown stamps take, so two overlapping runs send one notice. The first send is printed and then recorded: a notice reaches Claude only if Claude Code reads it before the process ends, and a hook killed between the print and the record leaves a notice the cursor does not count as sent, while a cursor that cannot be written costs no notice. The cursor expires once: on a later `Stop` where the notice still applies, the hook sends it a second time unless the conversation's transcript (`transcript_path` in the Stop input) already records the first, which Claude Code writes as an `async_hook_response` attachment carrying the hook's output when it delivers it; only that attachment counts, never the notice's words in a user message or a tool result. The repeat is recorded as `<uuid> again` and then printed, and goes out only once that line is written: a repeat the cursor cannot record would come back on every `Stop`, and a lost repeat costs less than an unbounded one. After that line the conversation is never nudged or warned again. What this promises: the bookkeeping is of attempted sends, a conversation gets each notice at most twice, and a first send the hook recorded but Claude Code never read goes out once more when the transcript records no delivery. What it does not: that an unrecorded first notice was lost (Claude Code may read it after the hook's next run), that a first send recorded and then lost in the same instant is told from a delivered one by anything but the transcript, nor that the second arrives
- Reminds Claude to review and append to its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on that file alone, when it has not been touched recently. The actor is the one SessionStart names (`cs_actor_raw` in `cs-shared.sh`: `CS_ACTOR`, then `.cs/local/identity`, then the git identity), so a teammate writing its own narrative does not hold back the reminder, and a missing narrative counts as never written. The reminder names the file as `Yours is <path>`; without `cs-shared.sh` the actor is unknown and it names `narrative.<actor>.md`. The reminder says it is carried over from the previous turn, which ended without a narrative note, asks Claude to record what that turn found before answering the request below, lists what counts (a decision and its reason, a measured fact, a failed approach, a preference the user stated), says that a line restating routine work is not a finding and must not be written, and names the empty case: say so in one line and answer the request. The contract is append-only: a disproven entry gets a dated correction that names it; earlier sections are never rewritten or deleted (that is what keeps `cs -narrative rotate`'s head-truncation safe under `merge=union`)
- Carries the commit rule: the model never commits narrative appends or anything else under `.cs/` on its own, not even beside a project change, since cs commits files under `.cs/` only in the commit that creates a session and the merge `/finish` makes, and the model commits them only when the user asks; a commit holding narrative appends is pushed only when the user asks; and uncommitted appends are safe because `autosave-commits.sh` already snapshots every edit to the shadow ref. The generated session protocol states the same rule in its `cs:session-commits` section, and it rides this reminder as well because the protocol is read once at startup and is stale by the time a commit happens, while this fires at the append itself — and because the text is rebuilt every run, so every existing session picks it up on upgrade with no migration phase. Unconditional rather than gated on whether `.cs/` is tracked: the check is cheap, but the advice is inert rather than wrong where `.cs/` is gitignored, and a condition the model has to evaluate is one it will not
- Gated on the work the conversation did since its narrative was last written. Each conversation keeps a cursor, `.cs/local/narrative-cursor.<session_id>`, one line `<offset> <epoch>`: a byte offset into its transcript (`transcript_path` in the Stop input) and the time it was set. At each `Stop` the hook reads the transcript from the offset to its end (`tail -c +N`) and counts with `jq` what Claude did there: Edit, Write, MultiEdit and NotebookEdit calls, Bash calls whose command holds `git commit`, and characters of Claude's own text. It reminds when that slice holds an edit, a commit, or 800 or more characters of text, and the actor's own narrative was last written before the cursor's epoch; a reminder never goes out within 60 s of the cursor's stamp, which keeps two `Stop`s close together to one reminder; a conversation with no cursor yet has no stamp, so its first busy turn is reminded however short. After a reminder, and on any `Stop` that finds the narrative written at or after the epoch, the cursor moves to the transcript's end and is stamped with the time, written under the hook's lock before the print, so a reminder lost at exit waits for more work rather than coming back on the next `Stop`. A conversation with no cursor yet counts from the transcript's start and takes its first timestamp as the epoch, so a narrative written during the conversation counts as written. The read is bounded to keep the run inside its budget: a slice over 4 MB counts as work without being read. A `Stop` input that names no transcript, one that is not on disk or cannot be read, a `session_id` outside `[A-Za-z0-9-]`, or a count `jq` cannot make falls back to the clock: at most one reminder per 5 minutes, stamped in `.cs/.narrative-reminder-cooldown`, and only for a narrative older than that. The same stat pass measures every narrative against `CS_NARRATIVE_MAX_BYTES` (default 131072) and appends one line per file over budget naming it and pointing at `cs -narrative rotate`; nothing is rotated from the hook
- Appends a second-opinion note to that same reminder when [claude-council](https://github.com/hex/claude-council) or the codex plugin is present, naming what each offers: `/claude-council:advise` to put the conversation to external models, and `/codex:review` before Claude calls built work done, with `/codex:rescue` when a run stalls. It rides the narrative reminder rather than speaking on its own, because the hook hands the model one notice per run, so a note of its own would displace the reminder instead of joining it. One note and one cooldown stamp serve whatever the plugin count: two independent notes would double the appended text and race the same stamp. Detection reads `installPath` from `~/.claude/plugins/installed_plugins.json` and then requires the plugin's own command file on disk (`commands/advise.md`, `commands/review.md`), because the install record outlives an uninstall, so the file decides. The council half suggests and never sends, and asks Claude to check with the user first, because a digest of the conversation goes to third-party providers and nothing a hook can read says whose words it holds (inside a subagent the ambient session id names the parent). The codex half offers `/codex:review` rather than promising to run it: that command carries `disable-model-invocation`, so only the user can type it, while `/codex:rescue` does not and Claude may invoke it. Cooldown-gated via `.cs/local/.advisor-nudge-cooldown` (per-machine state, never git-synced) at most once per 30 minutes, and silent when no plugin is present. Only the launched conversation nudges: a tmux teammate shares the directory and the single cooldown stamp, so an ungated note would let a teammate consume the lead's slot
- A `claude` started from inside the session (a `claude -p` the lead's Bash tool ran) gets no narrative reminder and spends no cooldown: the narrative is the lead's to update
- Prints nothing inside subagents, outside cs sessions, on any event but `Stop`, when the conversation did too little work since the actor's own narrative was written (or, without a transcript, when it was written within the cooldown window), and in a session whose queue and mailbox files git tracks (stop-blocks.sh says why on that `Stop`)

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time and the end reason Claude Code sends (`clear`, `resume`, `logout`, `prompt_input_exit` or `other`; `missing` when the payload has none) and appends an `ended` event to `.cs/timeline.jsonl`
- Deletes only the ending conversation's own shadow ref (`refs/worktree/cs/session/<conversation-uuid>`); a concurrent sibling's ref is left untouched
- Cleans up `.cs/session.lock`, but only one this launch owns. Only `cs` writes a lock, so a hook that resolved by walking the directory belongs to another front end: closing a desktop conversation on a directory a CLI session is live in would otherwise strip that session's lock, letting `cs <name>` open a duplicate with no collision menu. A walked-in hook still clears a lock whose process is gone, so a crashed session is never left locked out. A `/clear` or `/resume` keeps the lock, because the claude that holds it keeps running. Even the lead removes a live lock only when it names its own launch. Under `cs <name> --remote` the launch is the remote-control server, and the lead's end leaves the lock while `.cs/local/remote.pid` names a process running `remote-control --name <name>`, since the server still holds the session; its own exit releases the lock. A `remote.pid` that names a dead process, another program or another session's server makes no exception. The hook reads and removes the lock under the openers' mutex (`.cs/session.mutex.lock`); a hook that cannot take it leaves the lock, and the next open removes it once its process has exited, with a `Removing stale session lock` warning
- At the launched conversation's end (not a `/clear` or `/resume`, which leave it unchanged), marks the lead's claim (`.cs/local/lead-pid`) ended and leaves it in place: this hook runs while the lead still lives, and the ended claim keeps a claude that another `SessionEnd` hook starts a guest, before the lead exits and after. The next launch removes it
- For a session `cs -encrypt` built (`.cs/local/vault` names its container), an end other than `/clear` or `/resume` in the launched conversation leaves a background waiter (`.cs/local/vault-waiter.pid`). Once that Claude Code exits, the waiter detaches the vault with a plain `hdiutil detach` (`.cs/local/vault-detach.pid` while it runs), unless the session reopened or a pid in `.cs/local/vault-holders` is still alive. See [Encrypting a session with cs -encrypt](session-layout.md#encrypting-a-session-with-cs--encrypt)
- Regenerates the sessions index (`<sessions-root>/index.md`) — a table of every session's status, objective, and created date. Written only where sessions actually live: the session's own directory must sit under the sessions root, compared physically on both sides so a `$HOME` reached through a symlink still matches. An adopted session, whose directory is an unrelated project path, writes no index beside that project
- Inside tmux, for the launched conversation only (`cs_is_lead`): releases this pane's `@cs_session` and renames the window, and the iTerm tab, after the cs sessions still running there; with none left the window names itself again (`automatic-rename on`). A `claude -p` run inside the session inherits `TMUX_PANE`, so without the lead check its end would release the lead's claim. A `/clear` ends here too, and its SessionStart claims the pane back. If cs's launch exits without reaching claude (a cancelled resume prompt), its cleanup trap releases the pane the same way. While `.cs/local/remote.pid` names a process running `remote-control --name <name>`, the lead's end leaves the window alone, since its start never claimed it
- Skipped entirely inside subagents (guarded on the hook input's `agent_id`)

## subagent-context.sh (SubagentStart)

Runs when Claude Code spawns a subagent (via the Agent tool):
- Injects session context into subagents so they know about the cs session
- Provides the session directory and two key rules: secrets go to the session secret store through `cs -secrets set` on stdin from a file, and the subagent returns its findings in its final message, never in the session narrative unless asked
- In a feature worktree (when `task_branch` is in machine-local state), adds that integration and retirement go only through `/finish` in the base session and that the subagent never merges or deletes the branch or the worktree
- Uses `additionalContext` in the same format as SessionStart

## tool-failure-logger.sh (PostToolUseFailure)

Runs when a tool call fails (async, non-blocking):
- Logs tool name and truncated error message to `.cs/local/session.log` (`.cs/private/session.log` in an encrypted session, and nowhere while its vault is locked)
- Helps debug build failures, test errors, and other tool issues after the fact
- Increments the per-task failure counter (`.cs/local/failures`, written through `cs_write_atomic`) that feeds the queue's failures circuit breaker (see stop-blocks.sh); absent or non-numeric reads as zero. A lost increment under exact concurrency with the Stop hook's reset degrades the breaker by one count but never corrupts state, and the increment stays silent and non-blocking like the rest of the hook

## session-auto-approve.sh (PermissionRequest on Write/Edit)

Runs when Claude Code would show a permission dialog for Write or Edit:
- Auto-approves writes to the content files inside the session's `.cs/` directory: README, summary, memory and narratives, plans, handoffs, checkpoints, research notes, and the `pending-handoff` marker the rotate skill arms (session-start.sh rejects any marker with a path separator in it)
- Falls through to the normal permission prompt for everything cs itself acts on: every file under `.cs/local/` (`pre-open` runs at the next open, the queue and the mailbox execute, `state` and `identity` bind the checkout), `.cs/claude-config/`, `.cs/age-recipients/`, every file at the root of `.cs/` that is not Markdown (the `secrets.*` sync files, `session.lock`, `session.mutex.lock`, `archived`, `timeline.jsonl`, the reminder's cooldown stamp, and a file named like a control directory cs has not made yet), and everything in `.cs/private/` except `handoffs/`, `checkpoints/` and `narrative-archive/`
- Falls through for an Edit of any executable file under `.cs/` (Edit keeps the mode bits), for a target that is itself a symlink, and for every write while `.cs` or `.cs/local` is a symlink (cs refuses to open such a session, but a `claude` started in the directory by hand still runs this hook)
- Falls through for `CLAUDE.md` and `CLAUDE.local.md` anywhere under `.cs/` (Claude Code loads the one beside a file it reads) and for a write inside a git directory kept under `.cs/`: a `.git` directory or file, a `.git` that is a link, and a bare clone or a linked worktree's own directory under any name. The hook takes a directory for a git directory by the rule cs refuses a session's state by (`_cs_head_on_git_walk` in `cs-shared.sh`): the write's real parent, or a directory above it before the first that holds `.git`, holds `HEAD`, a link that leads nowhere included. A write of a file named `HEAD`, `commondir`, `gitdir`, `config` or `config.worktree`, in any case, falls through too, since writing those in the right order would build a git directory there one approved write at a time. When the hook cannot load `cs-shared.sh`, or finds no such rule in it, it approves nothing and prints `cs auto-approve: not approving, <path> is missing or outdated` on stderr
- Falls through for any name under `.cs/` that holds a character outside ASCII. The Mac filesystem folds some of them (a long s reads as `s`, the Kelvin sign as `k`), so such a name can be another spelling of a control file, and comparing strings does not show it. Only the part of the path below `.cs/` counts: a session whose own directory has such a character keeps its approvals
- Approves the first write into a directory that does not exist yet only for `handoffs`, `checkpoints`, `narrative-archive`, `memory`, `plans` and `research`, directly at the root of `.cs/` (the Write tool makes the directory). An encrypted session keeps those in its vault, so there a new one at the root prompts. Any other missing parent prompts
- Classifies by where the write really lands, compared lowercased (the Mac filesystem keeps the case you typed, so `LOCAL/` is `local/`): the hook resolves each control directory to its real path, so a committed link from a shared directory into `.cs/local` counts as `.cs/local`, and an encrypted session's links into `vault-mnt/` classify as the names they carry
- Never follows a symlink under a control directory. Any symlink under `.cs/local/`, `.cs/age-recipients/`, `.cs/private/`, `.cs/claude-config/`, the project's own `.claude/` (which Claude Code reads and git shares), or a `CLAUDE_CONFIG_DIR` that sits inside the session, and a `.mcp.json` at the session root that is itself a symlink, makes every write prompt until you remove it, wherever the link points. The hook names the first link it found on stderr (`cs auto-approve: not approving, symlink under a control directory: <path>`); the hook exits 0, so Claude Code acts on the absent decision and shows its normal prompt, and you see the line when you run the hook by hand. The walk (`find -P`) has no depth limit; it skips only `.claude/worktrees/`, where `claude --worktree` keeps whole checkouts. A project whose `.claude/skills` links to `../.agents/skills` prompts for every `.cs/` write as well
- Allows only the links cs itself makes. In an encrypted session `.cs/private` and `.cs/claude-config` are links into the vault mount (`.cs/vault-mnt/`); the hook accepts each one only when the link and the vault's entry of that name are the same directory and `vault-mnt` is a real directory, then scans inside the vault instead. Inside `claude-config`, the hook accepts a link only when it sits directly in the directory, carries one of the names cs shares from your Claude Code config (`settings.json`, `settings.local.json`, `CLAUDE.md`, `AGENTS.md`, `rules`, `skills`, `commands`, `agents`, `hooks`, `plugins`, `output-styles`, `keybindings.json`, `vale`) and is the same file as that name in `~/.claude`, or in the `CLAUDE_CONFIG_DIR` your shell had when cs launched. Any other link there prompts, including the `debug/latest` link Claude Code keeps when it logs to a file, and a shared link left dangling after you remove its source from `~/.claude`. A vault that is not mounted leaves its root links dangling, which prompts as well. A `.cs/claude-config` linked anywhere else, into `memory/` for example, makes every write prompt
- A `CLAUDE_CONFIG_DIR` that sits inside the session counts as a control directory, so writes under it prompt; one outside the session belongs to you and stays out of the scan
- Falls through for an existing target with more than one hard link, which can share its inode with a file anywhere on the volume, and for one whose link count neither `stat -c %h` nor `stat -f %l` can read. This check runs after every other one, of a write the hook would otherwise approve, so its line names the one reason the write prompts: `cs auto-approve: not approving, <path> has <n> names`, or `cs auto-approve: not approving, could not read the link count of <path>`, the path printed plain. A hard-linked target that an earlier check already turns away prompts with that check's line, or with none
- Falls through to the normal permission prompt for all other files. Project files always require explicit approval

## scope-prompt.sh (UserPromptSubmit)

Runs before each user prompt is sent to Claude. First it clears the statusline's attention marker (`.cs/local/attention`) — any prompt, including slash commands, means the user is back — and, inside iTerm2 with shell integration installed, stops the dock bounce the Stop hook started (`CS_NO_ITERM2=1` disables). Then six responsibilities: the queue and mail digests, objective capture, the date reminder, the clarify guideline, the narrative line, and scope grounding.

**Queue digest.** Surfaces unseen entries from the per-machine inbox (`.cs/local/notifications.jsonl`) at most once: counts by event plus the last breaker reason, if any, e.g. `cs queue while you were away: 4 task(s) done; breaker tripped: context (91 >= 85), 2 remaining. Run cs -queue log for detail.` The `.cs/local/notifications.seen` cursor advances only after the hook writes the digest to stdout, even when the digest text itself is empty, so surfacing stays at-most-once regardless of what else this prompt does. The order is load-bearing: this hook runs under a wall-clock timeout, and Claude Code kills it where it stands when it overruns — a cursor spent before the write retires notifications nobody ever saw, with no second chance at them. Advancing afterwards can at worst repeat a digest. When scope grounding below also has content, the digest is spliced above the `## Scope (auto-grounded)` block rather than replacing it — every exit path in this hook still delivers a pending digest. **Mail digest.** scope-prompt.sh (only) surfaces unread cross-session mail on **every** prompt until it is read — persistent, not surface-once. It inlines the bodies of the documents sitting in `mail/new/`, which only `cs -msg` empties by moving what it prints to `mail/cur/`, bounded to the first 5 with sender and body truncated inside jq (codepoint-safe) plus an "N more" overflow line. Each body sits on its own line between `<cs_mail id="…" from="…" kind="…" msg="…">` and `</cs_mail id="…">`, and one fixed note above the blocks says the text inside them is mail from other sessions that may carry instructions the user did not write, to be followed only where the user's own message asks. The id is six random hex characters drawn per block on every prompt, never derived from the message, so a body cannot close its own block early; the sender, kind and message id in the attributes keep only `[A-Za-z0-9._@:-]`, anything else becoming `_`. The tags are a guardrail for the model, not a security boundary. A body longer than the 160-character preview ends in `[cut: N more characters]`. A `task`-kind message is inlined like any other, with `kind="task"` in its tag and, under the block, the command that queues it, or, when the preview is cut, an instruction to read the whole message with `cs -msg` first: the body is an offer from another session, and only `cs -queue accept <id>`, run in the recipient, moves it into the queue (once per id, recorded in `queue.accepted`). `cs -msg` itself, which the wake tells an unattended agent to run, prints the same note above its listing and flattens the sender name into one line. No cursor is written by the hook (persistence is anchored on `new/` itself), keeping it a read-only view of the mailbox and leaving no cursor for two hooks to race over. Only `new/*.json` counts: an unfiltered scan would pick up a `.DS_Store` or a subdirectory and nag about phantom mail that `cs -msg` cannot clear. The header count is the file count, so an unparseable document among the first 5 counts toward N while rendering nothing — the same basis the status line and the TUI use, which is what keeps the three agreeing. A message can never appear half-written: delivery renames a complete document into `new/`.

**Objective capture.** Records the first substantive prompt of a session as the `## Objective` in `.cs/README.md`, but only while it still holds the unedited template placeholder — so the first real prompt wins, nothing afterwards churns it, and a hand-written objective is never overwritten. Skips slash commands, `!` shell passthrough, and trivially short prompts; collapses to one line and truncates to ~100 chars. The prompt is written via `awk` `ENVIRON` (no escape/replacement processing of arbitrary text), atomically via tmp+rename. Opt-out per-session: `export CS_OBJECTIVE_CAPTURE_DISABLE=1`. An encrypted session (`.cs/private` present, mounted or not) skips the capture: its objective goes in the narrative inside the vault, so the plaintext README never holds the prompt.

Known multi-machine limitation: if a session is cloned to a second machine while the Objective is still the placeholder and both machines then submit their first prompt before syncing, each captures its own objective and the merge conflicts. This is left as a real conflict on purpose — two people declared different objectives for the same session, and a human should reconcile them.

**Date reminder.** The session context names the date once, at SessionStart, and a conversation that lives across midnight keeps believing it. On every prompt, empty ones included (a mail wake can land on a new day), the hook compares today against `.cs/local/context-date/<conversation id>`, which holds the `YYYY-MM-DD` this conversation was last told, written by session-start.sh on every SessionStart, whatever its source (`startup`, `resume`, `clear` or `compact`), and by this hook whenever it changes. One file per conversation: a lead and a tmux teammate share the directory, and a single slot would let either one's new day silence the other's. A different day yields one `## Date` note naming both dates and asking Claude to treat any earlier "today" as stale; the same day yields nothing. A missing or unreadable stamp also yields nothing and just sets the baseline. A conversation id outside the uuid alphabet skips the feature rather than becoming a path. The stamp is written only after the note has gone out, like the inbox cursor, and not at all when the output object could not be built, so a hook killed mid-run can repeat a note but never lose one; session-start.sh likewise stamps after its context has been emitted. Opt out per-session: `export CS_DATE_REMINDER_DISABLE=1`.

**Clarify.** Injects a short guideline asking Claude to question an ambiguous request rather than guess at it. Deliberately ungated: the work-verb classifier exists to guard expensive git work, which is what earns its false-positive risk, whereas this guards a few hundred bytes of text — so a code-level vagueness check would buy nothing and pay for itself in misclassification. It also has to sit above that classifier, because a vague prompt (`make it better`) carries no work verb and would be dropped before the check ran. The guideline sets a high bar for asking ("genuinely cannot determine"), caps it at one batched question, and makes proceeding the default. Skips empty prompts — a mail wake carries none, and injecting there would put the guideline on every unattended turn — plus slash commands and `!` shell passthrough, which carry their own instructions. Opt out for one turn with a leading `~`; opt out per-session: `export CS_CLARIFY_DISABLE=1`. The switch is deliberately separate from `CS_SCOPE_DISABLE`: silencing grounding should not silence the questions.

**Narrative line.** Adds one sentence to every prompt of the lead, empty ones and slash commands included: "If this turn produces a finding worth keeping (a decision and its reason, a measured fact, a failed approach, a preference the user states), append it to your own narrative before your final answer; routine work is not a finding." The Stop hooks' narrative reminder can only reach the model with the next prompt (stop-notices.sh runs async), so a finding made on the last turn before the user leaves is lost unless the model writes it during that turn; this line asks for it there. Only the lead gets it: a tmux teammate and a nested `claude -p` (neither is `cs_is_lead`) get nothing. Opt out per-session with `export CS_NARRATIVE_PROMPT_DISABLE=1`; `CS_SCOPE_DISABLE=1` silences it too. Its bytes come out of the same 8000-byte budget as the guideline's.

The guideline and the narrative line are spliced above the `## Scope (auto-grounded)` block, never below it. A truncated scope block has to end with its truncation marker so nothing severed can read as a complete path, and its bytes come out of the same 8000-byte budget — the scan output is the elastic part and absorbs the cost, because emitting half an instruction is worse than a shorter file list.

## prompt-rewriter.sh (not a hook — an `$EDITOR` shim)

Ships in `hooks/` and deploys alongside the hooks, but Claude Code never invokes it as one and it is never registered against an event. It is reached through `$EDITOR`.

Claude Code binds `chat:externalEditor` to `ctrl+g` (also `ctrl+e` and `ctrl+x ctrl+e`). Pressing it writes the composer buffer to `<tmpdir>/claude-prompt-<uuid>.md`, runs `$EDITOR` on that file, reads it back, and replaces the composer with the result when it differs. cs points `EDITOR`/`VISUAL` at `prompt-rewriter.sh` when it launches a session, so the round-trip becomes a rewrite: type a rough prompt, press `ctrl+g`, and the composer holds a precise engineering request you can review, edit and send. Nothing is sent on your behalf.

The shim hands every file that is **not** named `claude-prompt-*.md` to your real editor (captured as `CS_REAL_EDITOR` before cs overrides `EDITOR`), so `/memory` and opening a transcript still work normally. It passes the buffer through untouched when it is empty, starts with `/`, `!` or `#`, or carries a `[Pasted text …]` or `[Image …]` placeholder — the buffer holds those placeholders rather than the pasted bodies, so rewriting one would destroy the attachment. Every failure path leaves the buffer exactly as typed: a rewriter that errors, times out, or returns empty loses nothing. A rewriter that finds the prompt already precise replies `=` alone, and the buffer stays as typed without waiting for the model to repeat it. A rewrite that drops a string the agent must find or run exactly as written (a code span, URL, path, `--flag` or `-verb`, `snake_case` or `SCREAMING_CASE` name, `@mention`, file name or "quoted phrase") still lands, followed by one line, `Kept from the original: …`, naming each dropped string in the order the prompt gave them, so the review before sending sees what went missing. The check is literal and case-sensitive: a name whose case changed counts as dropped. A code span or quoted phrase counts as kept when the rewrite carries its text, with or without the backticks or quotes. The line names a file name or relative path whole, every dot and hyphen up to its extension, and never names part of a dotted name that ends in no extension, like `dtype.float16`.

The default rewriter, `prompt-rewriter-model.sh`, calls a fast model with the prompt as untrusted data. It runs hermetically — its own config directory, a neutral working directory, and the session's context variables stripped from its environment — because a nested `claude` otherwise inherits the project's `CLAUDE.md` and cs's own memory, and those leak into the rewrite: a request to add a flag came back demanding TDD, bash 3.2 compatibility and a README update that the user never asked for. It authenticates as **you**, through your claude.ai login, and tries that first without an ambient `ANTHROPIC_API_KEY`. Claude Code prefers such a key over the login, so a stale or rotated one takes every rewrite down — and not quickly, because a rejected key sends the call into retries until the timeout, which reads as `ctrl+g` silently doing nothing. So the first attempt drops `ANTHROPIC_API_KEY` from the child's environment — and only it. With the key set, a first attempt that fails gets one retry with the key kept: on `Not logged in`, which is what a user whose only credential is a Console API key gets, or on any other failure that came back in under five seconds, since an attempt that spent the timeout leaves nothing for a second one. `ANTHROPIC_AUTH_TOKEN` is checked identically in both modes, so a dead one breaks the parent's own session and the user already knows; stripping it would also strand proxy users, whose `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS` remain and would receive a keychain bearer token. The rule is to scrub exactly the credentials whose precedence differs between the parent and the child. Isolating the config directory does not come with credentials: Claude Code derives the keychain service name from that directory (`` `Claude Code…-credentials${o}` `` where `` o = r ? "" : `-${sha256(configDir).digest("hex").substring(0,8)}` ``), so an isolated dir asks for an item that was never created and reports `Not logged in`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` overrides which directory that hash is taken from, so the shim mirrors whatever the parent resolved — empty when the parent has no config directory of its own, which is the value that drops the suffix, and the parent's own directory otherwise, since that user's login lives under its hash. Config stays isolated while the call reaches the real login.

**Forcing the API arm.** Appending `-api` to a provider name — `gemini-api`, `openai-api` — reaches that vendor's API even when its CLI is on PATH. It exists because agy's catalogue carries no lite models (eleven entries, and `gemini-3.5-flash-lite` and every variant of it are rejected as unrecognised), while the lite tier is the fastest option measured anywhere. On a machine with both CLIs installed: `gemini` 7.3s against `gemini-api` 0.9s, `openai` 12.8s against `openai-api` 2.0s. `claude-api` is the third: it posts to Anthropic's Messages endpoint rather than driving the Claude Code agent, which is what makes the bare `claude` default take roughly thirteen seconds — that call ships Claude Code's system prompt and tool schemas every time, measured at 35k tokens for a ten-token prompt. Each `-api` arm needs that vendor's key (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) and declines without one, leaving the prompt as typed. Bare `claude` has no suffix-free API form on purpose: it *is* the default rewriter, and it authenticates through your claude.ai login, reaching for a key only on the retry above.

**Rewriting with OpenAI or Gemini.** `CS_REWRITE_PROVIDER=openai` or `=gemini` routes the rewrite to `prompt-rewriter-vendor.sh` instead. Each provider prefers that vendor's CLI when its binary is on PATH — `codex` and `agy` respectively — and falls back to the vendor's API, reading `OPENAI_API_KEY` or `GEMINI_API_KEY` from the environment, when it is not. This mirrors the claude-council's `prefer_cli_over_api` policy and for the same reason: the CLI carries your subscription and spends no API credit. It costs about ten seconds against about one for the API arm, and the interface is frozen throughout, so the trade is real in both directions. With neither a CLI nor a key the rewrite declines and your prompt stays as typed. An unknown provider name runs the default rewriter instead, so a typo costs you the choice of model, never your prompt.

**Rewriting with Grok.** `CS_REWRITE_PROVIDER=grok` (or `xai`) routes to xAI's OpenAI-compatible endpoint, reading `XAI_API_KEY` or `GROK_API_KEY`. There is no `grok-api` spelling because xAI ships no rewriter CLI: there is nothing to prefer and so nothing for a suffix to reach past. The default model is `grok-4.3`, chosen by measurement rather than by recency. Over 8 prompts run twice against every candidate, `grok-4.3` preserved every unspecified thing as an open item; the much faster `grok-4.20-0309-non-reasoning` resolved them by fiat in 7 of 10 vague prompts — answering `Use jq.` to "should i use jq or awk here?", picking a database unprompted, and once returning the input verbatim. A rewriter that decides for you is worse than no rewriter. Note that Grok is not faster than what already ships: `gemini-flash-lite-latest` was the quickest model measured and matched `grok-4.3` on fidelity.

The vendor rewriter runs the CLI from the same neutral directory the default uses, because `codex` reads `AGENTS.md` from its working directory and `agy` takes that directory as its workspace — launched from your checkout, the rewrite would inherit that project's instructions. The CLI's stdin is a pipe carrying the prompt, never the inherited terminal, since Claude Code hands the shim the real tty and an agentic CLI that decides it is interactive would paint over the progress screen. No arm puts the prompt in `argv`, where `ps` shows it to every user on the machine: `codex exec` reads it from stdin when given no positional prompt, and `agy` takes it as one stream-json user message on stdin (`--input-format stream-json --output-format stream-json -p=`), the rewrite being the `response` of its `result` event. On the API arms the key travels in a mode-600 `curl --config` file and the prompt in a payload file, so neither reaches `argv`.

Three failure modes here are not the ones the contract anticipates. `agy` prints `CLI error: …` on **stdout and still exits 0**, so a status check alone would hand that string back as your next message; the gate judges the output as well as the status. A reasoning model can return a rewrite truncated at the token cap, which is non-empty and so passes an emptiness check while being unusable — `gemini-2.5-flash` was observed spending 1963 reasoning tokens against a 2048 cap and stopping mid-sentence, though it also completes normally on other calls — so a `finishReason` other than `STOP` declines. And Gemini's endpoint has been observed answering with a bare HTTP 404 and a zero-byte body, transiently, so an empty response declines rather than being treated as an answer. Only `/v1/chat/completions` is used for OpenAI: reasoning models are the wrong tool for a rewrite that blocks the interface, and an `o3`/`o4` model set through `CS_REWRITE_MODEL` gets a 400 and declines.

`CS_REWRITE_MODEL` reaches every arm — the API request, `agy --model`, `codex -m` — and is left off entirely when unset, so each vendor CLI keeps the model configured in that tool. The id belongs to whichever engine answers and the namespaces differ: `agy models` lists agy's, whose ids embed the reasoning effort (`gemini-3.6-flash-low`; the bare `gemini-3.6-flash` is rejected as a family name needing `--effort`), while the API arms take the vendor's own API ids. cs does not translate between them, so an id the engine rejects declines the rewrite and leaves the prompt as typed.

The progress screen names the engine and the model — `agy · gemini-3.6-flash-low`, `api · gemini-flash-lite-latest`, or a bare `codex` when the CLI resolves its own model and cs cannot know it. Both come from the vendor rewriter's own `--label`, which the shim calls before painting: repeating the CLI-or-API test in the shim would be a second copy of it, free to drift into a header that says `api` while `agy` is answering. `--label` is answered before the prompt is read, because the shim calls it without writing anything and a script that read stdin first would hang the interface on a pipe nobody fills.

Override the whole thing with `CS_REWRITE_CMD` (stdin to stdout, non-zero to decline, `=` alone to keep the prompt as typed). It outranks `CS_REWRITE_PROVIDER`: it is the older and wider contract, and a user who set it has already said exactly what they want run. Opt out per-session: `export CS_REWRITE_DISABLE=1`, which also leaves your `$EDITOR` untouched.

Claude Code runs the editor with `spawnSync` and `stdio:"inherit"`. The shim's basename matches none of its known GUI editors, so it takes the `enterAlternateScreen()` branch and blanks the interface for the length of the rewrite, roughly ten to twenty seconds on the default model. The shim owns that screen and fills it, in one of four styles set by `CS_REWRITE_PROGRESS`: `screen`, `native`, `line` and `static`. `screen`, the default, leads with the prompt being rewritten (folded, capped at eight lines with a `… prompt clipped` marker) beside a margin rule that breathes slowly between the muted tone and the accent. Under it a muted `rewriting` line carries the engine and the model at its right, and under that a bar counts down the seconds left against `CS_REWRITE_TIMEOUT`, ending in `Ns left`. A rewriter that does not bound itself (a `CS_REWRITE_CMD`, the default rewriter without `timeout` or `gtimeout`, or a vendor one without `perl`) gets the elapsed seconds instead. It draws in the cs palette from `lib/05-term.sh`, inlined because a deployed hook cannot source that file and keyed on the `CS_TERM_THEME` cs exports: the prompt in primary ink, the bar's remaining part in the accent, chrome muted, and no colour at all under `NO_COLOR`. `native` is one line anchored where the composer was, written in Claude Code's own idiom — a sentence-case gerund with the elapsed in parentheses, and no elapsed at all under five seconds, matching `m = f >= 5 ? ${d} (${f}s) : d` in its CLI progress renderer. `line` is a single centred line with a spinner and a clock. Neither echoes the prompt, so a pasted secret never reaches the screen. `static` prints one line and never repaints, which costs the only liveness signal there is: a wedged rewrite then looks exactly like a working one. An unrecognized value falls back to `screen` rather than restoring the blank screen the feature exists to remove. Tearing down the alternate screen discards it, so nothing reaches the scrollback.

You cannot interrupt a rewrite from the keyboard, and the screen does not pretend otherwise. The terminal delivers `ctrl+c` to the whole foreground process group, which contains Claude Code itself, so the keystroke ends the session rather than the rewrite. No handler in a spawned shim can intercept a signal the tty sends to its parent as well. `CS_REWRITE_TIMEOUT` is the only bound, which is why the screen shows the time against it.

The shim still handles `INT` and `TERM`, for the case where it receives one anyway. The handler exists to reap, not to cancel: it signals the rewriter's whole process group, restores nothing because it has written nothing, and exits 0. Without it, a shim dying alongside its session would orphan the `claude -p` it started — detached, invisible, and still billed until it finished. That matters most in exactly the situation nothing can prevent.

Every invocation appends a `start` line to `.cs/local/rewrite.trace`, naming the provider and the file, then a line for each step it reaches, the last naming the path it took: `exit passthrough-prefix`, `exit real-editor`, or `rewriter-forked` and then `exit rewritten`, and so on. This shim is driven by a keypress and draws onto a screen that is torn down, and each of its do-nothing paths leaves the buffer byte-identical, so without the trace a rewrite that declined, one that was disabled, and one that was never a composer buffer at all are indistinguishable after the fact. The trace is machine-local and written only when `CLAUDE_SESSION_META_DIR` resolves to a real session. It goes through `cs-shared.sh`'s writers, which refuse a link out of the session: the shim loads the library from beside itself at the first trace, after a `bash -n` check, and writes no trace when the library is missing or does not parse. An [encrypted session](session-layout.md#encrypted-sessions) keeps the trace in `.cs/private/`; with its vault locked, the shim writes none. While git tracks a file in `.cs/local` (or `.cs/private`), the shim writes no trace.

Every drawing path checks `[ -t 2 ]` first, so a piped or scripted run emits nothing.

**Scope grounding.** Grounds code-work prompts in the current codebase by injecting a bounded "Scope (auto-grounded)" block as `additionalContext`:

- Classifies the prompt: positive iff a work verb (`implement`, `add`, `fix`, `refactor`, …) OR a source-file extension is mentioned. A negative classification skips the scope block but still exits through the digest path, so the date note, the queue and mail digests and the clarify guideline still arrive; with none of those pending it emits nothing.
- On a positive classification, tokenizes the prompt and uses a **hybrid matcher**: path-like tokens (`src/api.ts`) get ordered-substring matching against `git ls-files`; bare-word tokens (`api`, `db`) get component-equality with camelCase + `_-` splitting via a hand-rolled `splitcamel()` awk char-loop (portable across BSD and GNU awk). Excludes `node_modules/`, `target/`, `dist/`, `build/`, `.next/`, `coverage/`, `.cs/`, `.git/`.
- Adds recent commits touching the matched files (`git log --oneline -5`) and a working-tree diff summary.
- Caps the scope block plus the clarify guideline at 8000 bytes (rough 2K-token proxy). The date note and the queue and mail digests sit outside that budget and are emitted ahead of it, so the full `additionalContext` can run past 8000 bytes.
- Emits a pinned tombstone block (`Scope: no tracked files matched`) when the classifier fires but no tracked files match, so the agent knows scope ran but found no ground.
- Opt-out per-session: `export CS_SCOPE_DISABLE=1`.
- NO caching by design: a grounding hook must reflect the current tree; a prompt-only cache key would silently serve stale ground after commits/edits.
- Never blocks the prompt path — every error path exits 0.

**Stage trace.** Every run appends one line per stage to `.cs/local/scope-prompt.trace` as that stage finishes — `pid`, milliseconds, stage name, with each mark after `start` carrying the elapsed time since it. The `start` value itself is epoch milliseconds wherever the shell offers `$EPOCHREALTIME`, and shell-relative on the bash 3.2 fallback, so treat it as an origin to subtract from rather than a wall clock. The `start` mark also names the directory the run stood in — the rest of the line, never a field, since paths hold spaces. In a cs-launched session a `launch` line in absolute epoch milliseconds comes first; the paragraph after **Own deadline** says why. After `classify`, a `budget=<ms>` line records the budget the run settled on:

```
21204 1786532215690 launch
21204 1786532215708 start /Users/you/projects/big-repo
21204 21 input
21204 24 date
21204 26 clarify
21204 53 digest
21204 61 objective
21204 68 classify
21204 69 budget=1500
21204 94 tokens
21204 152 scan
21204 198 gitlog
21204 229 gitdiff
21204 272 emit
```

A run the deadline below stops early ends `budget=1500`, `skip`, `exit` instead of running the scan stages.

**Own deadline.** The hook checks its own clock once, after the classifier and before the scan stages (`tokens`, `scan`, `gitlog`, `gitdiff`), through the same builtins the trace reads. Past `CS_SCOPE_BUDGET_MS` (1500 by default; a value that is not a number, or runs past seven digits, is the default, as is a value from 1 to 1000, one tick or less, on a shell without `$EPOCHREALTIME`, whose clock ticks in whole seconds; 0 skips the scan on every prompt) it gives up the scope block, puts one line in its place (`Scope: skipped, slow machine (...)`, so the model knows to locate the files itself), writes a `skip` stage to the trace and exits through the digest path: the queue and mail digests, the date note and the clarify guideline still arrive. Measured: the front half takes under 300 ms idle and about 1.7 s at a load of 25 (a full test suite on the same box), and it was the scan running on from there that the 3 s registration killed, taking the digests with it. The registered timeout is 10 s and stays the backstop for a scan that is itself slow. It was 5 s until a run in a loaded session was killed before its clock had even started: its trace held no line at all, while the other UserPromptSubmit hooks on the same prompt took 2.3 s to answer.

A run that overruns the hook's timeout leaves a trail that stops mid-run, which names the stage it hung on — the only evidence such a run ever produces, since it never reaches an exit where it could write a summary. A trail ending anywhere but `exit` or `emit` marks a killed run. Before anything that can stall (the library parse-check, its source, the session resolve), a run in a cs-launched session writes a `launch` line carrying absolute epoch milliseconds, so a run killed before the trace opens still leaves that one line: `launch` with no `start` after it means the process started and stalled in its first forks, and no `launch` at all means it never ran. The line needs an existing `.cs/local/` and creates nothing itself. It reads `$EPOCHREALTIME` without a fork; bash 3.2 has no builtin epoch clock, so there one `date` fork supplies whole seconds, and a `date` that stalls leaves no line. The rest of the trace reads the clock through shell builtins only (`$EPOCHREALTIME`, or `$SECONDS` on bash 3.2), so it adds no forks to a hook already under suspicion for running slow. The file is machine-local — which machine was slow is half the finding — and one run in 64 trims it to its last 2000 lines. Opt-out per-session: `export CS_SCOPE_TRACE_DISABLE=1`.

## memory-index-guard.sh (not a hook — run by `/wrap`'s memory pass)

Ships in `hooks/` and deploys alongside the hooks as a library, never registered against an event. It sources `cs-shared.sh` for the snapshot's location and exits 2 when that file is missing. `/wrap`'s memory pass (`wrap-sweep.md`, deployed beside it) runs it from the session root to check its own rewrites of `.cs/memory/MEMORY.md` and of the memory archive, `.cs/memory/reference_memory_archive.md`: a `reference_` entry that `MEMORY.md` points to, holding the pointer lines the pass moved out of `MEMORY.md`, in the same shape.

- `snapshot` copies `MEMORY.md` to `.cs/local/memory-index.snapshot` and the memory archive to `.cs/local/memory-archive.snapshot` (both in `.cs/private/` in an encrypted session, exit 2 while its vault is locked), before the sweep edits anything. A file that does not exist yet (Claude Code writes `MEMORY.md` with the first memory entry; the first demotion writes the archive) gets an empty snapshot; outside a session root (no `.cs/memory`) it exits 2.
- `check` exits 1 and names each problem: a pointer that was in `MEMORY.md` or the archive at the snapshot and is in neither now (`removed:`); a pointer whose entry file is not in `.cs/memory/` (`dangling:`); a pointer in both `MEMORY.md` and the archive (`duplicate:`); an entry in the four memory buckets (`user_`, `feedback_`, `project_`, `reference_`) with no pointer in either file, or the archive with no pointer in `MEMORY.md` (`unindexed:`); and a `MEMORY.md` over the 24400-byte or the 196-line budget (`over budget:`). It names a pointer that left `MEMORY.md` for the archive `demoted:` and passes it. A pointer is a line opening with `- [title](file)`; a link later on that line is supporting text. A pointer names an entry file only when its target is a bare file name ending in `.md` with no `/` and no `:`, so a URL or a `file.md#section` link is not checked for `dangling:`, in either file. It counts lines as Claude Code does before its 200-line cut, never fewer: every line, blank and heading lines too, a last line with no newline, and a lone CR, U+2028 or U+2029 each as a line break. It always prints the size and the line count against their budgets. With no snapshot of either file, an unreadable one, or no `MEMORY.md` it exits 2, so a skipped snapshot never passes as a clean rewrite. The bucket check covers entries written after the snapshot and a second sweep that snapshotted an index the first had already damaged; the snapshot itself is one per session, so two concurrent sweeps share it.
- `restore` copies the `MEMORY.md` snapshot back byte for byte and leaves the archive alone: a pointer the sweep moved into the archive is then in both files, and `check` names it `duplicate:`.
- `refs` scans entry bodies outside fenced code and closed frontmatter for backticked `_cs_`/`cs_` identifiers, `cs -verb` commands and relative paths matching `^[A-Za-z0-9._/:-]+$`, stripping one trailing `/` and one trailing `:<digits>` or `:<digits>-<digits>` for lookup. It accepts basenames ending in `.sh`, `.md`, `.rs`, `.mjs` or `.json` and paths containing `/`; paths need a lowercase letter and a letter or digit before the last dot, cannot start with `-`, and skip branch prefixes `feat fix perf chore docs ci test refactor release` and host first segments ending in `.com`, `.org`, `.net`, `.io`, `.dev` or `.ai`. It prints sorted `dead: <entry file>: <token>` lines with the original token or `ok: <N> references in <M> entries, none dead`, and exits 0 for either report or 2 when `.cs/memory/` is missing or a search fails without a hit.
- While git tracks a file in `.cs/local` (or `.cs/private`), all four exit 2 and name the file, so the guard never restores a committed snapshot over `MEMORY.md` and writes none beside it.

The scanner strips one leading `./` from exact paths, checks files and directories on disk, and requires each path to resolve inside the session root. Only basenames and identifiers use git's tracked and untracked, non-ignored regular files minus deleted files plus `.cs/` (without entering submodules), or the pruned walk outside git; basenames match the final component, and identifier searches exclude `.cs/`.

Verb lookup uses the installed `cs` found on `PATH`, falls back to `bin/cs`, and skips verbs when neither exists. Each scan resolves and counts a token once, but reports a dead token once in every entry that contains it.

`refs` skips and does not count a reference followed immediately on the same line by ` (gone YYYY-MM-DD)`, such as `` `hooks/old.sh` (gone 2026-10-22) ``.

`check` never restores on its own. A sweep that pushes the file over budget by adding a pointer has to demote or compress other pointers, and an automatic restore would throw the new pointer away, leaving its entry unindexed.

## cs (not a hook script — a Claude Code mod)

`mods/cs/` is a Claude Code function-hooks plugin: TypeScript that runs
inside Claude Code's own process rather than a shell script it spawns. It adds
one key to conversation rotation. Once the context window reaches 40% (the
status bar's warn band, where the Stop hook gives its headroom notice), the band
directly above the prompt draws `rotate`, pressed by Ctrl+X 1.
`CS_ROTATE_BUTTON_CTX=<percent>`, kept with `cs -config set` or exported in the
shell that launches cs, moves it; unset or not a number, the band follows the
bar's own warn band (`CS_STATUSLINE_CTX_WARN`, 40 by default), read the same
way. The band is one thin line above
the prompt, two columns in where Claude Code draws its own footer, with a
blank line above it, in two zones. At the left stand the
actions, what a key or a press does now, and the queue's count; at the line's right edge stand the
words that say what the session is, then the prompt the rail names, then the
rail of prompts, ending in the line's last cell. Items in a zone stand three cells apart; after the
last key (a chord, or the armed handoff's count) a dim `·` stands in the middle of those three cells,
parting the keys from the presses and words after it. The line's free
cells fall between the zones, never fewer than three, so the right edge holds
still while the actions come and go. Where the keys'
chords share a prefix (`ctrl+x 1`, `ctrl+x 2`) the prefix is spelled once,
bold in the theme's `subtle` gray, and each key's own last word stands beside
its label in the session's
colour: `ctrl+x 1 rotate   2 wrap   #4 say four   │││┃` on the narrowest line
that holds it. Chords that differ are spelled whole. In order, and each
only when it applies, the actions are `rotate` (or `/clear now` once a
handoff is armed, then `in Ns`, the armed handoff's count, which leaves the
line before `/clear now` would shrink to its bare key), `wrap`, `filter chat`
and the queue's start press, `▤ run N queued tasks` (`▤ run 1 queued task`
for one), or in its place the queue count below: `ctrl+x 1 rotate   2 wrap · ▤ run 2 queued tasks`.
The queue's `▤` draws in the amber the status line gives its queue count. The right edge carries the features
word, `finishing <task> · gate <elapsed>` while a `/finish` gate runs, and
the mail count below. The band
paints nothing else from the measured background (`CS_TERM_BG_RGB`) and reads no
caps answer; only the amber of the count and of the queue's `▤` still read the
measurement. The percentage itself stays on the status bar: the band does not
repeat it.

The rail draws only when the `/config` row `cs.bandPrompts` is on (it is
off by default; see [configuration.md](configuration.md#band-settings)).
It is one upright bar per prompt the person sent in this conversation: `│` dim, `┃` dim too for the prompt the band
names (its heavier stroke marks it), `┆` dim for a prompt the engine refused to scroll to. The band names
the newest prompt; with the `/config` row `cs.bandPrompt` set to `read` it
names the prompt being read instead (the prompt whose row stands highest on
screen, from the engine's own on-screen reports of the transcript's rows)
and follows the scroll (see
[configuration.md](configuration.md#band-settings)). A press on a bar scrolls the transcript so that
prompt's row is at the top. The band's focus ring never lands on a bar:
the keyboard route is `/cs next` and `/cs prev`, which move one prompt from
the prompt being read, and `/cs first`, `/cs last` and `/cs N`, which go to
that prompt, all mid-turn too, for keybindings. A
refusal is toasted once a session; a prompt no row has drawn since a resume
toasts `cs: that prompt is not on screen yet` once. The prompts come from the
session's transcript (`~/.claude/projects/<slug>/<id>.jsonl`, or
`CS_TRANSCRIPTS_DIR`, or an encrypted session's own `.cs/claude-config/projects`),
read again after each turn and at session start only when its size or
modification time moved, and only its live branch is listed: a `/rewind`
drops the prompts it abandoned, a `/compact` keeps the earlier ones. Tool
results, slash-command echoes, hook feedback, task notifications, a
teammate's message and the interrupt the engine writes when you stop a turn
are not prompts. The rail ends in the line's last cell, so the actions at
the left never move it while the line has room for every bar. At
most `cs.bandBars` bars draw (10 by default), in what the line leaves after
the inset and the words, and the named bar always among them: the bars
reach the newest prompt, or start at the named one when that prompt
predates their reach. The older prompts collapse into one dim `…N` run at the rail's
start, a cell before the first bar, and the newer into one dim `M…` run at
its end, a cell after the last: `#7 step 7   …6 ┃││││ 3…` with the seventh
of fourteen prompts named under `cs.bandPrompt` `read` and `cs.bandBars` at 5. The rail keeps its
least: the named bar alone, the older prompts folded into `…N` before it
and the newer into `M…` after it, and three cells before that. The words fit what that leaves, so the queue count and the right edge's
words drop, a right-edge word shortens, and the keys lose their words before the rail goes:
`1 rotate   2 wrap · ▤ run 2 queued tasks   3 features · fix-auth…   …13 ┃`
on a 75-column line with fourteen prompts, every action, the features word
and `mail 1`: the mail word drops, the shared prefix goes and the features
word shortens. A right-edge word never shortens past its head, the words
before its first `·`, and `…` (`3 features…`): a cut into the head, such as
`1…`, says nothing, so the word leaves instead and the band fits the line
again without it. The queue's start button keeps its count whole when it
shortens: `▤ run 12…` fits, and a cut into the count, such as `▤ run 1…`,
would name another number, so the button cuts to `▤…` instead. The
actions outrank the rail: where one would leave the line whole beside that
least, the words take the whole line, the rail draws in what they leave, and
a line too narrow for any bar draws no rail. Three cells before the bars, and three cells after any
word before it, the band names its prompt, `#N` and its first line (up to 80
characters),
italic in the theme's light `subtle` gray, cut with `…` when the line is narrower, counted in terminal cells
so a wide character takes two; under ten cells left it names none, and the
rail still ends in the line's last cell. The three cells keep a `…N` run from
reading as the end of a cut name. The name
is as wide as the widest prompt it can show, the named one or a drawn bar's,
padded on its left so it ends three cells before the bars, so a swap never
moves the bars or the words before it. On the
terminal a bar under the pointer swaps its own prompt into that place,
in the same light gray as the named one, until the pointer leaves; the swap follows the mouse, so it
needs Claude Code to receive mouse events (`CLAUDE_CODE_DISABLE_MOUSE` turns
them off). Other
surfaces name the band's own prompt only, since the desktop app paints a card
over a line without hiding what is under it. A conversation with
one prompt draws no rail; a `/clear` empties it, and the rail, like the keys,
draws only in the lead conversation of a cs session.

Unless a `/finish` gate runs, the first word at the band's right edge is the
state of the session's features,
read from
`cs <base> -features --porcelain` after each turn and at session start,
without holding either up, and every 30 s while the band is idle once cs has
been asked. cs gets 20 s to answer; a reading that runs past that stops the
30 s clock, and the end of the next turn asks once more. Only the lead
conversation asks cs, and a base asks only while
the sessions root holds a `<base>@<task>` directory: a feature `/feature`
makes shows when that turn ends. In a base, one feature ready reads
`1 feature · fix-auth ready` (or `3 features · fix-auth ready`) and a press
runs `/finish fix-auth`; two or more ready read `3 features · 2 ready` and a
press runs `/finish`, which lists them and asks which; none ready reads
`1 feature · fix-auth uncommitted changes` or `3 features · none ready`, dim,
with no press. A state reads as the sentence `cs <base> -features` and the TUI
print (`_feature_state_sentence` in `lib/30-worktree.sh`); ready with no commit
ahead of the base reads `no commits`. A feature session (`base@task`) draws no
features word and asks cs nothing: `/finish` lands a feature only from its
base, whose word names it. A cs that fails, cannot start,
or prints a record that is not ten fields with a whole `ahead` and `untracked`
and a known lock and state draws no word, and the mod logs it once.

Two counts draw with no press, each only when it has something to count.
`▤ queue N` stands at the left, where the queue's start press would, while
the cs queue holds tasks but its start press is not offered (the queue is
armed or draining, a turn runs, or an armed handoff's clear key stands
alone). It reads `▤ queue N running` while the queue runs (armed or draining),
its `▤` amber and the rest dim. `mail N`, dim, comes after the right edge's
other words: the `.json` files in the session's mailbox `mail/new/` that
`cs -msg` has not read yet. Both are read behind `.cs/private` in an
encrypted session and in `.cs/local` otherwise, each time the band draws.
Every word takes its terminal cells from what the prompt's name is left:
`▤ queue 2 running` at the left, then the line's free cells, then
`mail 1   #4 say four   │││┃` at the right edge.
The task in progress is
Claude Code's own task list's to show, above the band; the band does not
repeat it.

The mod queues `/color` when a conversation begins inside the running Claude Code, including after `/clear`, rotation, in-app `/resume`, or a context-limit fork; the command reapplies the session accent once the session is idle.

The band's keys are chords, never a bare digit: a digit typed to answer a
numbered question belongs to the prompt and to other mods. Each Button answers
an engine action, `strip:jump1` for the rotate (or `/clear`) key and
`strip:jump2` for the wrap key.
The installer binds Ctrl+X 1 and Ctrl+X 2
to them in `keybindings.json` (see
[configuration.md](configuration.md#rotate-and-wrap-keys)). The band spells
whatever chord that file's `Global` block binds to each action, as written
there, a shared prefix bold in `subtle` gray and each key's own part bold in
the session's colour, and nothing where none does; the Buttons still answer a click
and Ctrl+X Tab. Claude Code re-reads `keybindings.json` while it runs, so a
chord bound after launch works at once (measured on 2.1.292). An encrypted
session launched before `keybindings.json` existed gets the file at its next
launch.

The filter chat key draws after wrap when cs-filter-chat advertises
`/filter-chat`, while a turn runs too, with no survey or armed handoff; a band with no
[cs-filter-chat](#cs-filter-chat-not-a-hook-script--a-claude-code-mod) loaded draws no filter chat key. The band reads the command
list without running a status command. The key is a press, as the queue's
start button is: it answers no chord, only a click and Ctrl+X Tab, and its
label draws bare after the keys' dim `·`:
`ctrl+x 1 rotate   2 wrap · filter chat ●`. On a line too narrow for every
entry it never shortens: it leaves whole, after the queue's start button and
before the chords.

The key ends in a switch dot:
`filter chat ●` while on, the dot in green, and `filter chat ○`
while off, the dot in the line's ink. A
press asks `cs -vet-session` before it writes, as the other band writers do.
A refusal leaves the setting alone and draws filter chat as off. The key reads
`filter chat ●` only while the setting `CS_FILTER_CHAT` is `1`, and the band's
last `cs -vet-session` answer in this load was not a
refusal. The band asks at session start in a cs session with `.cs/local`, and
at every step that acts on the control files, such as a press of the clear,
rotate or filter chat key.
A prompt does not clear a refusal. A vet that passes, or a reload, does.
Before the band's first vet in a load, it reads the setting unvetted.
An accepted press
runs `cs <session> -config set CS_FILTER_CHAT 1` or `0`, the value flipped, then
invalidates the band. The setting survives `/clear`, reload and resume. Filter
chat is off by default. The band reads the setting as cs resolves it: the
environment pins it, else the session's `.cs/local/config`, else this machine's
file, the last `1` or `0` line of a file winning. Read errors say nothing of the
setting; the band logs each distinct error except a missing file. Each failed
write attempt toasts cs's last line, and every completed press invalidates the
band, including a failed write.
Duplicate presses wait for the same write and redraw.

The Button's stable element key is `cs-filter-chat`; it carries no action.
cs-filter-chat must hook `ui.press` with `{ plugin: 'cs', element: 'cs-filter-chat' }`, await
`next(e)`, then read the setting the band's handler wrote with `cs <session> -config set
CS_FILTER_CHAT`. The band sends no command. When `/filter-chat` changes the
setting through the same `cs -config set`, the band reads the new value on its
next redraw. Spike 3 measured immediate cross-plugin press hooks with
no transcript rows, while command delivery queued until idle and host state
reset on `/clear` and resume.

The [filter chat key's design and alternatives](superpowers/specs/2026-10-24-band-feed-toggle-design.md)
records those measurements and compares session activation options and layouts for more toggles.

Ctrl+X 1 runs `/rotate`, as if typed: the `rotate` skill draws the purpose from
the conversation. Before it runs, the press writes the conversation id to
`.cs/local/cs.pressed`, so `cs -archive-tasks plan` reports `forced: yes` and
the one-key rotation skips the task-archive question as a forced one does. The
end of the main loop's next turn, whatever ended it, empties the file, and so
does a run the engine refuses, so a `/rotate` typed later in the conversation
asks as a manual one does. Beside it the band draws `wrap`. That key
runs `/wrap`, which distills memory, replaces `.cs/summary.md`, rotates the
narrative and archives completed task rows: five Opus passes, two of them writing
the memory entries and the summary, minutes and real tokens, so the
press asks first. Ctrl+X 2 opens the engine's own AskUserQuestion dialog —
`Run /wrap for this session?`, with `Yes, wrap up` and `Not now` — and only the
yes runs it; a dismissed dialog, and a `-p` run with nobody to ask, run nothing
and say nothing. A wrap that finished leaves the key nothing to do: `/wrap`'s last
pass writes `.cs/local/wrapped` with the id of the conversation it ran in
(`CLAUDE_CODE_SESSION_ID`, so a teammate's wrap never marks the lead), and
while it names this one the band draws the rotate key alone. The next turn
that starts from a prompt empties it and the wrap key comes back: queued work,
a new request, or a second `/wrap` (which, if it fails a pass, leaves no marker
of its own). A continuation turn, one started with no prompt as a Stop hook's
feedback starts one, leaves it in place. A summary written any other way
hides nothing, and a wrap that fails a pass
skips the marker. Below the band the mod draws nothing, and it draws none of
these keys while a turn runs or while a survey holds the band. While a turn
runs, the filter chat key, the `/finish` gate word, the features word (with
no press), the queue and mail counts and the rail still draw; under a survey
only the gate word does. Its rotate, wrap and `/clear` keys run slash
commands and the filter chat key runs `cs -config set`, and none submits a
prompt; a queue start, from `/queue` or the band's press, submits one, and
only while no turn runs.

The same button has a second state. Once the `rotate` skill has armed a
handoff (`.cs/local/pending-handoff` names one, or `.cs/private/pending-handoff`
in an encrypted session), the band draws
`/clear now` whatever the context reads, alone
(the wrap key hides: with a handoff armed the conversation has nothing left to
do but the `/clear`), and
Ctrl+X 1 runs `/clear` itself: the conversation ends, and cs's SessionStart
hook starts the handoff's next step in the new one, as it does after a typed
`/clear`. The mod does not touch the marker; the hook consumes it. The button
appears only for a marker the hook accepts: a bare basename, a file in
that marker's store (`.cs/handoffs/` or `.cs/private/handoffs/`), frontmatter still `status: unconsumed`. An empty marker, or one
an aborted rotation left naming a handoff since consumed or gone, leaves the
rotate button in place.

The mod presses the button for you by default. The forcing is **on at 80%**;
`CS_ROTATE_FORCE_CTX=<percent>` (1 to 100), kept with `cs -config set` or
exported in the shell that launches cs, moves it, `CS_ROTATE_FORCE_CTX=off` (or `0`) turns it off, and a value that is neither —
a typo, or a number past 100 — is the default rather than silence, since a value nobody can read must
not quietly disable a rotation you are relying on. The first launch on a machine
that has not been told prints one notice naming the threshold and the way out,
and records it in `${XDG_CONFIG_HOME:-~/.config}/cs/rotate-force-notice`. The
end of a turn whose context reads at or past that percentage
runs `/rotate` as if you had pressed Ctrl+X 1, once per conversation: the mod
records the conversation id in `.cs/local/cs.forced` before it schedules
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
band reads `ctrl+x 1 /clear now   in 20s`,
redrawn once a second. The count wears the session's own colour while there
is time, the status bar's amber from ten seconds and its crit red under five
(the bar's inks, pinned against `bin/cs-statusline` by `tests/test_mod_rotate.sh`).
At zero the mod runs the `/clear` itself, only if
the band is idle at that moment (no turn running, no survey), the handoff still
armed and this still the lead; otherwise the count stops and the button waits
for you. Ctrl+X 1 during the count clears at once. A press while the mod's own `/clear` is
still running does nothing, so it cannot clear the conversation that `/clear` opened. Sending a prompt, from
the composer or anywhere else a prompt enters the session, stops the count;
the next turn's end starts it again from 20. A `/clear` from anywhere else
(typed, or another plugin's) ends it too. The count is module state: it does
not survive a reload of the mod, and every path that ends it cancels its
timer, because a timer started before a `/clear` keeps firing after one
(measured). At zero the mod re-reads the handoff with the SessionStart hook's
own rule (frontmatter opened and closed by `---`, `status: unconsumed`
inside), so a truncated handoff is never cleared into.

When the count starts, the mod toasts the handoff's next step once:
`cs: next step: <line>`, the first non-empty line of the handoff's `Next Step`
section (a `#` line inside a fenced block is the step's text, not a heading;
a line that opens or closes a fence is skipped), cut to 160 characters with an
ellipsis. One toast per armed handoff: a count the next turn's end restarts for
the same handoff, and the band's redraws, say nothing more; a handoff armed
after the `/clear` in the same process is toasted in its turn. A handoff with
no `Next Step` section toasts nothing, and a count a prompt stops before the
toast's timer fires toasts nothing. The mod opens no pane.

Pick the percentage above a fresh conversation's own footprint. The wake turn
after the `/clear` is an ordinary turn, and the once-per-conversation record
belongs to the conversation that ended, so a threshold a fresh conversation
already sits past (a session that loads a large CLAUDE.md and memory, say,
with the knob at 5) would rotate again as soon as it woke, and again after
that (measured at 1). The mod refuses that loop: a conversation born of a
`/clear` it saw run (its own at zero, or one typed) is judged by the context its
first turn ended with, and one that already sat past the threshold is never
forced; a toast says so once
(`cs: CS_ROTATE_FORCE_CTX=5 is below this conversation's starting context (8%); not forcing a rotation`),
and the button stays. The conversation the mod meets at launch, after a reload,
or through a `/resume` is not judged: a session resumed at 72% with the knob at
70 is exactly the one the person asked to have rotated. A handoff the person
arms by hand in a judged conversation still gets the countdown. The default,
80, sits above the 65% nudge and below Claude Code's own auto-compact, so the
mod writes the handoff while the conversation is still whole.

The button is for the lead conversation of a cs session only: past the threshold
the mod also checks that the cwd has `.cs/local`, that `.cs/local/disabled` is
absent, that the sessions root (`CS_SESSIONS_ROOT`, else `~/.claude-sessions`) has an
entry, under the directory's own name or the `session_name` its state records, that
resolves to the cwd, and that its own conversation id is the `claude_session_id` in
`.cs/local/state`. A teammate claude in the same directory, or a plain Claude
conversation, gets no button, because the handoff the skill writes carries that
id and arms the marker cs launched the lead with. A cloned repository that carries
a `.cs/local` of its own gets none either, since nothing inside a directory can
prove the directory a session. The plugin's own id follows
`/clear` (measured: after a `/clear` the band returned only once
`.cs/local/state` named the new transcript), and cs's SessionStart hook rebinds
`state` on every fresh conversation, so the lead keeps its button across
rotations. Every render asks the engine for the conversation's id and context
usage, reads the handoff marker (and the handoff it names), and lists the queue
and the mailbox; once it has something to draw, the filter chat key included, it also checks
that this is the lead (the sessions root and `.cs/local/state`), lists the
engine's commands for `/filter-chat`, and reads `keybindings.json`, the
session's colour and the filter chat setting's files. The band renders a handful of times per turn, not per keystroke.


`install.sh` deploys the mod's four files (`.claude-plugin/plugin.json`,
`hooks/hooks.json`, `hooks/register.tsx` and the spinner tips file `tips.json`)
under `~/.claude/skills/cs/`
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
not on `/clear`, the mod writes `.cs/local/cs.heartbeat` (one UTC
timestamp) when the cwd has `.cs/local`, the sessions root has an entry for it (as
for the button), and `cs -vet-session` passes, and `cs -doctor` reports the mod by
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
validate` lists, so a render reads each variable it needs by name: the
threshold's `CS_ROTATE_BUTTON_CTX` and `CS_STATUSLINE_CTX_WARN`, the inks'
`CS_TERM_BG_RGB` and `CS_TERM_THEME`, the filter chat key's `CS_FILTER_CHAT`
and `XDG_CONFIG_HOME`, and `CLAUDE_CONFIG_DIR`, `HOME` and `CS_SESSIONS_ROOT`
to find `keybindings.json`, the settings files and the sessions root. For the
thresholds, the theme and the background, a value a settings file gives comes
first unless the shell exports the key. The
defaults and the twelve ink triplets (the eight session colours, and amber and
crit for a light and a dark terminal) are literals in `register.tsx` that
`tests/test_mod_rotate.sh` pins to the status line's. The
module state the forced mode keeps (the countdown, the conversation it is
judging) is reset by a hot reload, which drops a running countdown and adopts
the conversation it meets next unjudged.

The mods hand Claude Code every toast, `$.ui.ask` dialog, `$.ui.log` notice,
slash-command reply and command registration from tables they export: cs in
`register.tsx` (`TOASTS`, `ASKS`, `LOGS`, `REPLIES`, `COMMANDS`), cs-update in
`register.tsx` (`TOASTS`, `REPLIES`, `COMMANDS`),
cs-panel in `register.tsx`, `draw.tsx` (`WORDS`) and `settings.ts`
(`LABELS`), cs-filter-chat in
`words.ts`. `tests/test_mod_tables.sh` fails when a call site writes
such a line inline. Claude Code leads a toast, a notice and a command reply with
the plugin's name, so no line starts with it. Exported functions draw the
band, the cs-update and cs-panel panes and the cs-mermaid fence (`drawBand`,
`drawPane`, `Drawing`, `drawFence`) from a view, so a tool outside cs can draw them from a
fixture.

The mod also registers `/queue`, marked immediate so it runs while a turn is
in flight instead of waiting for it to end. `/queue <task>` runs
`cs -queue add "<task>"` through `$.process.run` by the path the launch
exports in `CS_BIN` (no shell; the claude process's `PATH` is not the
launching shell's), and `/queue` alone runs `cs -queue list` and prints it.
When the list has a `Queued (N)` heading and the queue's state file
(`.cs/private/queue.state` in an encrypted session, `.cs/local/queue.state`
otherwise) is not `armed` or `draining`, the mod then asks through `$.ui.ask` whether to start
them. Start and Compact then ask how the tasks run (In this
conversation, In subagents, As workflows; free text under "Other" is refused
with a toast) before anything runs, and Start runs `cs -queue start` with
`subagents` or `workflow` for those answers, and when the last band render saw no turn
running it also sends one `$.prompt.submit`, since the Stop hook hands over
each task only as a turn ends; Not yet runs nothing; Compact
calls `$.session.compact()` and then does what Start does, and a compaction a
hook vetoes or the engine refuses (it refuses while a turn runs) leaves the
queue unarmed and says why in a toast; a dismissed dialog runs nothing. A
refused start or prompt shows as a toast.
The child inherits the claude process's environment, so the
`CLAUDE_SESSION_META_DIR` the launch exported picks the session's queue. A
refused task (empty, or more than one line) prints cs's exit code and the end
of its stderr as cs wrote them.

![Statusline without queued tasks, two pending tasks, then statusline with two queued tasks](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/queue.svg)

`/finish` gets a toast at each end. While `cs <base> -integrate-feature` and
`-retire-feature` run, cs replaces a progress record at each step
(`finish-progress.json`, see [session layout](session-layout.md#machine-local-files-cslocal-gitignored)).
The `/finish` skill's prompt (the `skill.prompt` event, which fires for a typed
`/finish` and for the conversation `cs <base> -finish` launches) starts a
one-second `$.clock.every` watch that reads the record. A run's first running
step toasts `cs: finishing <task>`, and its outcome toasts
`cs: landed <task> <sha7> -> <base sha7>`, `cs: /finish <task> refused: <reason>`
(the first line of cs's refusal) or `cs: retired <task>`. The toast cuts a task
name past 60 characters, as `/queue`'s toast does. Each toasts once: the mod keeps
which steps of which run (the record's `id`) it has shown, and the record the
watch finds when it starts belongs to an earlier run, so the mod never toasts it.
While a real gate runs (not `-- true`, and not one `--ci-green` skipped), the
band above the prompt carries `finishing <task> · gate <elapsed>` at its right
edge, before the mail count and the rail, dim, redrawn each second, during the turn as well. The gate counts as running only while the
record's `pid` is alive (`kill -0` through `$.process.run`, once a second while
a step runs), so a cs process that a signal ended leaves no band behind. The watch
ends at the first read after the turn that ran `/finish` is over with nothing
running. The rotation keys draw before the gate word on the same line when both show. An
integrate or retire run from a shell, outside `/finish`, starts no watch and
toasts nothing. The mod does not hook `command.run` for this: the contract scopes
it to slash commands and registered ones, and says nothing of skills.

Tests: `tests/test_mod_rotate.sh` runs the bun unit tests under
`mods/cs/test/` (a fake engine drives the band, the press and the
heartbeat) and `claude plugin validate` when each binary is on PATH, and
always checks the manifest, the threshold pin, and that the installer and
the launch name the mod and the flag.

## cs-update (not a hook script — a Claude Code mod)

`mods/cs-update/` is a Claude Code function-hooks plugin, deployed and gated
the same way as the `cs` mod: `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, which every
`cs <name>` launch exports and `CS_NO_FUNCTION_HOOKS=1` withholds even when the
launching shell already carries it.

The mod reads two variables the launch exports, and `HOME` and `CS_SESSIONS_ROOT` to find
the notes cache and the sessions root:
`CS_UPDATE_AVAILABLE`, the pending version, exported only when a launch finds
a newer cs, and `CS_BIN`, the path of the running cs, exported on every
launch. A third, `CS_UPDATE_DECLINED`, names the pending version when the
person answered no to the launch's own question (`~/.cache/cs/update-declined`
keeps that answer): the mod then toasts one line, `cs X.Y.Z is available · run
cs -update to install it, or /cs-update for the notes`, and opens no pane
until `/cs-update` asks for it. Without `CS_UPDATE_AVAILABLE` there is nothing to show, so the mod opens no
pane and toasts nothing.
Present, the mod reads the changelog span the launch's check cached at
`~/.cache/cs/update-notes-full-<version>` (KEEP IN SYNC with
`check_update_notify` in `lib/20-update.sh`), strips its markdown the way
bash's `_md_strip_inline` does, and opens one pane titled `cs <version> is
available`. A version that cached no span, or a span the cache lost, still
opens the pane with a one-line fallback instead of a blank body.

The pane is for the lead conversation of a cs session only. The sessions root
must name the directory, by its own name or by the `session_name` its state
records, as the `cs` mod asks. The mod then checks `.cs/local/state`'s
`claude_session_id` against its own conversation id, as the `cs` mod's button
does. A `.cs/local/disabled` file refuses the pane outright. A teammate
claude in the same directory reads the same state file and does not match, so
it gets no pane of its own. A cloned repository that carries `.cs/local` gets
none either.

The launch pane opens once per load of the mod (a launch, or a plugin
reload) and not after `/clear`, whether or not the update key was pressed. `/cs-update`, which the mod registers at every load, opens the
same pane on demand: after a dismiss, with the `/config` row off, or with
nothing else having shown it. Run from a teammate, or in a directory the
sessions root does not name, it says the pane belongs to the conversation cs
launched; run with nothing pending it says so instead of
opening an empty pane.

Pressing `1` runs `cs -update` through the engine's own process runner
(`$.process.run`, the path from `CS_BIN`; no shell, since the claude
process's `PATH` is not the launching shell's), with a ten-minute timeout for
the download, the checksum and the signature. The pane shows `updating…`
while it runs and hides the key so a second press cannot start a second
installer; a failure keeps the key for another try and says what happened: a
non-zero exit shows `cs -update exited N.` over the last five lines of
stderr, a run that could not start shows `cs -update did not run:` and the
error, and a launch that set no `CS_BIN` says to run `cs -update` from a
shell; a clean exit retires the key
and the pane keeps the outcome ("Update finished. Takes effect on your next
launch.") until it is dismissed, since the new files take effect only on the
next launch for the rest of this claude: the update replaces this mod's own
deployed file, and Claude Code reloads it as soon as the install lands. `Esc`
closes the pane at any point.

That reload resets the mod's module state mid-pane, which would otherwise
blank a pane still showing "Update finished". A clean exit also writes
`.cs/local/cs-update.done` (version plus the outcome line); the engine
re-renders the open pane the instant it reloads the module, which can come
before the reloaded module's `session.start` runs, so the reloaded module reads the marker back and redraws the finished
pane from its own next render. That redraw asks the lead check first,
so a directory the sessions root does not name gets no pane back. A pane dismissed before the install landed
leaves nothing open to redraw, so `/cs-update` after the reload reads the
marker too and shows the finished pane instead of offering the install a
second time. The mod clears the marker (writes it empty, since `$.fs` offers no
delete) once it names a version that is no longer pending: at the next launch,
at the pane's redraw after a reload, or at a `/cs-update` run while another
version is pending. A `/cs-update` with nothing pending says so before it reads
the marker, and leaves it. In a directory the sessions root does not name, or
while `cs -vet-session` refuses the session (git tracks its control files), the
mod writes neither the marker nor its heartbeat and
leaves a stale marker in place.

The `/config` row `cs-update.showReleaseNotes` (on by default) turns off the
launch pane and, for a version declined at the launch's question, the one-line
toast that stands in for it; `/cs-update` still opens the pane with the option off.

`install.sh` deploys the mod's three files (`.claude-plugin/plugin.json`,
`hooks/hooks.json`, `hooks/register.tsx`) under `~/.claude/skills/cs-update/`,
the same layout as the `cs` mod, and `cs -uninstall` removes the directory. When
Claude Code loads the plugin, the mod writes `.cs/local/cs-update.heartbeat`
(one UTC timestamp) when the cwd has `.cs/local`, the sessions root names the directory (as
for the pane) and `cs -vet-session` passes, and `cs -doctor` reports the
mod from that file through the same `_doctor_check_mod` check it runs for
the `cs` mod: OK naming when it last ran in this session, or a WARN naming the
ways it has not (no cs launch since the install, function hooks withheld by
`CS_NO_FUNCTION_HOOKS` or a preset `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0`, or a
Claude Code that no longer loads mods behind the flag).

Tests: `tests/test_mod_update.sh` runs the bun unit tests under
`mods/cs-update/test/` (a fake engine drives the pane, the update key and the
lead gate) and `claude plugin validate` when each binary is on PATH, and always
checks the manifest and its `/config` field, the cache-name pin against
`lib/20-update.sh`, and that the installer and doctor name the mod.

## cs-mermaid (not a hook script — a Claude Code mod)

`mods/cs-mermaid/` is a Claude Code function-hooks plugin, deployed and gated
the same way as the `cs` mod: `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, which every
`cs <name>` launch exports and `CS_NO_FUNCTION_HOOKS=1` withholds. It reads two
environment variables (`CS_TERM_THEME` and `CS_TERM_BG_RGB`, cs's reading of the
terminal), writes no file and runs no process. Unlike the `cs` mod it needs no
cs session: with function hooks on it draws in any directory. The flowchart
instruction lives in a cs session's `CLAUDE.local.md`.

![Reply prose, then the same prose with a drawn Mermaid chart](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/mermaid.svg)

It hooks one event:

- `ui.render` on `AssistantMessage` (terminal surface only). A reply with no
  ` ```mermaid ` fence goes to the engine untouched. A fence indented four or
  more columns (a tab counts to the next multiple of four) is an indented code
  block, as CommonMark reads it, and stays with the engine; one indented up to
  three draws. Inside a list item the columns count from the item's content
  column, past its `-`, `+`, `*`, `1.` or `1)` marker and the blanks after it,
  and a fence may open on the marker's own line: a fence under `1. flow:` at
  four columns draws, and one four columns past the item's content stays
  source. Items end where marked, which Claude Code reads replies with, ends
  them: a line left of the content column stays in the item unless it starts
  a block of its own or follows a blank line in the item, a fence mark, a
  heading, a thematic break or an indented code line. A mermaid fence still
  open when its item ends draws up to there. A mermaid fence closes on a bare
  line of three or more backticks. A mermaid fence inside another code block (a
  ` ```markdown ` or bare ` ``` ` one, four backticks or tildes) is that
  block's text and stays source. A reply with a fence is split
  into prose, which goes back to the engine (so the reply keeps its opening
  bullet, on its first part only), and fences, each parsed (`hooks/parse.ts`) and
  laid out (`hooks/layout.ts`) in character cells; the last 32 layouts are
  kept, since a streaming reply re-renders on every flush. Nodes are solid
  blocks, three rows tall, taller or wider where more than one edge meets them,
  coloured by their role in the flow, in a light or dark palette: the `theme`
  row of `/config` decides for a built-in theme (`dark`, `light` and
  their `-daltonized` and `-ansi` kinds); under `auto` or a `custom:` theme the
  terminal cs read decides, `CS_TERM_THEME` first, else the luminance of
  `CS_TERM_BG_RGB`, else light. Both come from the environment cs launched
  claude with. A claude started outside cs has neither, and a teammate pane,
  whose environment comes from tmux, can lack both: either draws light. A cs
  config change or a terminal theme switch after launch shows from the next
  launch. Every line and label colour reads at 4.5:1,
  with 0.1 to spare, on white, cream (252;247;229), Solarized Light
  (253;246;227) and 251;246;233 under the light palette and on black, #1C1C1E
  and #282C34 under the dark one, and every label on its fill. A decision (`{ }`, `{{ }}`, or any node with two
  or more outgoing edges) amber, an end (a node edges arrive at and none leave, a
  `(( ))` circle included) grey, a start (a node edges leave and none arrive at,
  or any other `(( ))` circle) green, every other step lavender.
  Mermaid itself fills every node the same; the roles are the terminal's
  reading of the chart, and `style`, `classDef`, `class` and `:::` fills win
  over them, as does a shape over the edge count. Edges are box-drawing glyphs
  with `▼▲►◄` heads, a shared cell is always a crossing (`┼`), and each label
  sits beside its edge's first vertical run, so the corner and the head stay; a
  label that answers a decision (`yes`, `pass`, `healthy`; `no`, `fail`,
  `degraded`) is drawn in green or red, any other in the line colour. The mod turns a left-to-right chart wider
  than the terminal top-down. It measures the terminal: beside a docked pane
  the transcript is narrower, and a chart sized to the terminal can wrap
  there. A fence the parser refuses (any statement outside the supported
  subset refuses the whole chart: subgraphs, self-loops, non-flowchart
  diagram types, more than 200 nodes, 400 edges or 60-cell
  labels) or one still too wide stays a code block with `mermaid: <reason>`
  under it.

cs adds a `cs:mermaid-diagrams` section headed `Diagrams` to `CLAUDE.local.md`
when it creates a session, or on migration when the sentinel is absent. The
instruction says flowchart fences draw here: add one only for a flow that
branches, loops or has four or more stages, never for a task list or numbered
steps; one fence, short labels, no subgraphs, `{ }` for a decision, `(( ))` for
a start or end, `[ ]` for a step. Claude Code reads the file into each request's
system prompt without adding it to the transcript each turn. This delivery
does not depend on an organization allowing a user-tier `prompt.compose` hook.
To opt out, delete the section's prose and keep `<!-- cs:mermaid-diagrams -->`;
migration leaves that tombstone alone. Outside a cs session, the mod adds no
diagram instruction; the show-me skill still covers an explicit ask.

`cs -doctor` lists the instruction as `diagrams`, carried by `CLAUDE.local.md`.
The row reads `on` when the managed section has prose, `off` for a tombstone
or an absent section. Its off switch is to delete the prose under
`cs:mermaid-diagrams`. `CS_NO_FUNCTION_HOOKS` does not affect this row.

The `/config` row `cs-mermaid.drawDiagrams` (on by default) controls drawing
only: off, fences show as source. It leaves the `CLAUDE.local.md` instruction
in place, as does `.cs/local/disabled`. The instruction reaches every Claude run
started in the session directory, including headless `claude -p` and subagents,
because the engine loads `CLAUDE.local.md` itself.

The mod also ships a skill, `skills/show-me/SKILL.md`, which the engine lists
as `/cs-mermaid:show-me`. Its description names the asks that call for a
picture ("show me", "draw it", "diagram this", "how does X work" about a flow
or a layout), so the model picks it unasked when one fits; the body puts a
`graph TD` flowchart first, in the subset the mod draws, then text sketches
(pseudocode, a call tree, a component tree, a file tree, a diff) for
structure without a flow. The `/config` row leaves the skill in place: with
drawing off, its flowchart shows as source.

`install.sh` deploys the mod's seven files (`.claude-plugin/plugin.json`,
`hooks/hooks.json`, `hooks/register.tsx`, `hooks/parse.ts`, `hooks/layout.ts`,
`hooks/text.ts`, `skills/show-me/SKILL.md`) under `~/.claude/skills/cs-mermaid/`,
and `cs -uninstall` removes the directory. The mod writes no heartbeat, so `cs -doctor` has no
"last ran" row for it.

Tests: `tests/test_mod_mermaid.sh` runs the tests under `mods/cs-mermaid/test/`
with `claude plugin test` (they use the engine's own `claude-code/testing` kit:
the parser, exact picture fixtures for the layout, the inline drawing, the
fallback to source and the drawing option) and `claude plugin validate` when
`claude` is on `PATH`. The engine tests skip when `plugin test` is unavailable;
the hook inventory check skips when validation cannot list function hooks.
The shell suite always checks the manifest, its `/config` field and that the
installer names the mod. `tests/test_mermaid_section.sh` checks the session
instruction and tombstone, and `tests/test_migrate_claude_md.sh` covers migration.

## cs-panel (not a hook script — a Claude Code mod)

`mods/cs-panel/` is a Claude Code function-hooks plugin, deployed and gated like
the `cs` mod. Bare `/cs` opens its pane, `cs`, and so does `/cs-panel`, which it
registers as a second name; nothing opens it unasked. Both run mid-turn too. The
pane sits inline above the prompt on the main screen (tmux) and docks beside the
transcript, 60 columns wide, in fullscreen from 110 columns.

The rows come from two places. `Mods` lists the `/config` rows of `cs`,
`cs-update`, `cs-mermaid` and `cs-filter-chat` (`$.config.list()`, those four
plugins by name, so another `cs-*` plugin's rows are not drawn). The four mods
title each row `cs: ` and its label, so `/config` marks the row as cs's; under
`Mods` the mark says nothing and the pane draws the label without it. Under
them, cs's own settings come in
cs's groups and order from `cs -config list --porcelain`, run through `CS_BIN`
(the path the launch exported) with no shell. The panel holds no list of
settings and no copy of their checks: labels, choices, defaults, when a change
applies, where each value comes from and a sentence on what the setting does
all arrive in that record, twelve fields with that sentence last. The panel
refuses a whole answer that holds a record of any other length, and says so
above the rows. A row shows its label and its value (cs's name for the default
when nothing sets it). From 72 columns it also shows where the
value comes from (`shell`, `launch`, `session` or `machine`; `mod` or `locked`
for a `/config` row) and when a change applies (`/clear`, `launch` or
`now+launch`). A row at its default leaves the last two empty, and a change
that applies at once (`now`) leaves the last one empty. Below 72 columns, as
in the 58-column dock, the row ends at its value and the footer says the
rest.

The pane draws in the cs TUI's look. Ink, muted, faint, soft, teal and green
are Claude Code's own theme keys: `text`, `inactive`, `subtle` for both faint
and soft, `planMode` and `success`. Claude Code resolves them to your theme at
each redraw, so the pane follows it (auto, dark or light) with no setting, and
`CS_TERM_THEME` changes none of its colours. Only the brand's colours stay the
same on every theme: the amber of `tui/src/theme.rs`, and the rust, the gold
and the wordmark's letters between them of the installer's banner.

The pane opens on the masthead, the installer's banner (`show_banner` in
`install.sh.in`) as wide as the pane: a round box of three lines on the
terminal's own background, its top border and left side in the installer's
rust, `rgb(230,74,25)`, and its right side and bottom border in its gold,
`rgb(255,193,7)`. Inside, a cell in from the left side, come the
`claude-sessions` wordmark in bold, each letter one step of the installer's
gradient from rust to gold, then cs's version after a space, then the number of
rows, `/config` rows included (`49 settings`), the number of settings a file
or the shell overrides (`3 overrides`, `1 override`) and the session name,
each after a `·`. The counts draw in ink, and the version,
the dots and the session name draw muted. Where the pane is too narrow, these
parts drop from the right, down to the wordmark alone, cut short on the
narrowest pane, and at least a cell stays before the right side. A `/config`
row never counts as an override, since the panel cannot see its default. The
version is what `cs -version` prints, asked once each time the mod loads, when
the pane first opens or a reload finds it open; until cs answers, the masthead
goes on without it. A run that fails, or prints anything but `cs <version>`,
writes `cs -version <why>` to the transcript, and the next open asks again.
When the launch found a newer cs (`CS_UPDATE_AVAILABLE`), a second line inside
the box reads `cs <version> available · run cs -update`, the version in amber
and the rest muted, dropped from the right the same way, so the box is four
lines. That line goes once the masthead's version is that version, as when a
reload after an update installed from this conversation reads it again. The
problem lines and the reading words sit right under the masthead.

Under the masthead comes the search box, then the column header and the rows.
The rows sit under a muted bold column header and a soft rule. Below 72
columns the header reads `Setting` and `Value`, and a name takes every cell
the 14-cell value column leaves, 40 in the 58-column dock. From 72 columns
`Source` and `Applies` follow, a name takes up to 26 cells, and `Applies`
takes what a wider pane leaves. Each group's headline is its name in bold
ink, one space and a soft `─` rule to the pane's edge, with an empty line
above every group but the first.

The selected row's lines are the pane's footer: under the last row drawn, and
the `+N below` count when there is one, a soft rule as wide as the pane, then
these lines, each of the first four opening with `▍` in the soft rule colour:

1. `selected · ` muted, then the row's label in bold ink, cut short where the
   pane is too narrow.
2. What the setting does, in ink: cs's sentence from the record, or a
   `/config` row's own description. A row with none has no such line.
3. The whole value as the row draws it, then where the value comes from in
   that source's colour (`default` muted), then a note, muted: when a change
   applies, why cs skipped a file's value, or why Enter changes nothing.
4. The row's key, muted: the `CS_*` name, or a `/config` row's
   `<plugin>.<field>`.
5. Two cells in and muted, the keys: `↑↓ move · Enter change · Esc close`. On
   a row Enter changes at once with no chooser, an on/off setting no file
   holds or a `/config` toggle, the middle part reads `Enter flip`. On
   a row Enter cannot change, the middle part says why: `shell sets it`,
   `shell only`, `managed` or `no session name`. At the line's right end
   sits the reset control, `reset all…`, muted, and the keys give up their
   end to leave a cell before it. The mobile app draws the same line.
6. Under a session name, the scope line, two cells in: `writes to: ● this
   session  ○ this machine`, `writes to: ` muted and then a plain Button for
   each file, `●` in green on the file writes go to and `○` on the other.
   Where the line cannot hold `writes to: `, it leaves it out, and where it
   cannot hold both Buttons, it cuts each one to the same width. With no
   session name the pane draws no scope line.

Lines 2 and 3 wrap by words and take three lines at most between them. The
value line comes first: it takes two of the three where there is a
description, which keeps one or two and ends in `…` where it runs out. A short
pane takes back lines in this order, so the window keeps at least one: the
wrapped lines down to one value line, then the key, then the keys' line, then
the scope line, then the value line, down to the label alone. A pane with no
line left for the label draws no footer.

Every value draws in ink, at its default too. Only the source word says what
overrides a value, in the colour of where the value lives: `session` teal,
`machine` green, `shell` amber (the environment overrides both files), and
`launch` faint. Its applies word is muted. A toggle reads `● on`, the dot
green, or `○ off`. Some flags turn off what their label names when they are
1: cs's `flagoff` and `shelloff` records. cs labels such a row with the
feature (`Scope grounding` for `CS_SCOPE_DISABLE`), so it reads `● on` while
the flag is unset and `○ off` at 1. A percent setting (its label ends in `%`)
draws its number and `%`, `40%`, and a value that is no number, `the warn %`,
unchanged. Faint is for the `+N` counts and the `launch` source only.

Each row is one plain Button, keyed by the row and named by its label: the
name and every column are its text, so the focus inverts the whole row. The
selected row has `▌` in amber outside the Button and its label bold, on no
background. Every row's label is in ink, selected or not, at its default or
set.

The pane opens with the focus ring in the search box: a one-line Input inside
a round border in the soft rule colour, as wide as the pane, that reads
`search settings` while empty. As you type,
the pane shows only the rows whose label, key or group holds the text, in any
case. A group with no row left goes, and `no setting matches <text>` stands in
for an empty list. While the field holds text, the column header's right end
says how many rows show out of the total, `3 of 49`, muted, and the heads
give up their end to leave it room. The masthead keeps its counts, and `+N above` and
`+N below` count the rows shown. An empty field shows every row again, and
closing the pane forgets the text. Enter in the field, labelled `select`,
selects the first row shown and moves the ring there. On the terminal the box
takes three lines: its border above, the field, its border below. The mobile
app draws no Input, so there three empty lines stand in the box's place, and
the pane shows every row. The rows start on the same line on the terminal and
the mobile app.

Tab or a click selects a row (`ui.focus`). The focus ring walks the search
box, the rows drawn with an open chooser's elements after its row, then the
reset control or the confirmation's two Buttons, then the scope line's two, so
Tab from the last row drawn reaches `reset all…`. The arrows, the wheel, the
page keys, Home and End move the selection by the rows they ask for among the
rows shown (`ui.scroll`). The selection stops at the last row and at the
first, where Up moves the ring back to the field. The pane draws its own
window of rows, so the engine's window stays put while the window and the
focus ring follow the selection. The footer says what the selected row is and
does, and when a change takes hold.

Enter or a click on a row opens its chooser under it, in the row list, or
flips an on/off setting no file holds. The chooser is a line of plain Buttons
four cells in, ` · ` between them, wrapped onto more lines by whole choices
where one line cannot hold them, and a choice wider than the line ends in
`…`. A row that takes a typed value puts an Input on a line of its own above
them, holding the value (the default's name while empty), Enter
labelled `set`. A row that takes one of its values puts a picker there
instead: a Select listing every value in its owner's order, with the one the
row holds selected. On the terminal it reads `band ▾`, and with the ring on it
the picker opens to its options under that line, eight at most and `… N more`
for the rest. The window counts the chooser's lines, the open picker's
included, and the selected row stays drawn above it. The ring moves onto the
chooser's first element, the arrows walk its elements while it stays open and
stop at its ends, and Enter picks one. On the picker the arrows move its
highlight instead. `Keep` closes the chooser and writes nothing, and so does
picking the value the row already holds. Esc on the picker closes the pane, as
it does on a row, so `Keep` stays a Button under it. Selecting another row,
editing the filter or closing the pane closes the chooser too. No Button
offers the value the row already has. The mobile app draws no Input and no
Select, so there you cannot type a value, a typed setting's chooser offers
only `Default (<default>)` and `Keep <value>`, a setting with choices offers its other values as
Buttons ahead of those, and an on/off setting a file holds offers `Turn on` or
`Turn off` there.

A change goes where the value lives when this session's file holds it: cs
writes it there. Any other value goes to the file the scope line names, or to
this machine's file with no session name, so a change always moves what the
row shows. cs's own checker judges a typed value.

- An on/off setting no file holds flips at once: no chooser opens, and cs
  writes 1, which turns a flag's feature on and an off flag's feature off. As
  after any write, cs's line is the toast and the pane reads cs again.
- An on/off setting a file holds offers its picker of `on` and `off`, its
  state selected, then `Default (<default>)` and `Keep`, since the default and
  the file matter there. A flag that turns its feature off at 1 lists its
  feature's states: `off` writes 1, `on` writes 0, which cs reads as unset,
  and its default is `on`.
- A setting with choices offers its picker, then `Default (<default>)` while a
  file holds the value, then `Keep`.
- Any other setting offers its Input, then `Default (<default>)` and
  `Keep <value>`.

`Default` is `cs -config unset` in the file that holds the value, so a session
value falls back to the machine's and the machine's to the default. The scope
line's `this session` writes this session's own file, `cs <name> -config set`,
`<name>` being `CLAUDE_SESSION_NAME`, and `this machine` writes
`~/.config/cs/config`. The pane opens on `this session`, keeps the choice
while it stays open and forgets it when it closes.

The toast is cs's own reply: after a new value, the line naming the file and
when the change applies; after `Default`, `<key> removed from <file>` or
`<key> is not in <file>; nothing changed`; after a refusal,
`<key> not changed: exited 1: Error: …`.
A `/config` row changes through `$.config.set`, which runs the owning plugin's
own `config.set` guard: a toggle flips at once, a choice offers a picker of its
options and `Keep`, a number or text row offers its Input and `Keep <value>`,
and the panel refuses a text a number row cannot read before it writes
anything (`<label> takes a number; got <text>`). The owner reloads with the
new value, which for a `cs.*` row starts an armed rotation countdown over; the
footer's note says so. A `/config` row's chooser has no `Default`, since the
panel cannot see a `userConfig` default.

On some rows Enter opens nothing and changes nothing. It toasts the row's
label and the reason, which the footer's note also shows, and its keys' line
names in short. A setting your environment pins reads `CS_X=v in your
environment wins; unset it there to change it here`.
`CS_NO_FUNCTION_HOOKS` takes no change either: you change it from a terminal,
since `cs -config set CS_NO_FUNCTION_HOOKS 1` loads no mod from the next
launch, this panel included. A `/config` row a managed setting owns reads
`a managed setting owns it`. A setting this session's file sets, seen with no
session name, reads `this session's file sets it, and this conversation has no
cs session name to write it with`. While cs still writes a row's change, a
second Enter on that row toasts `<key> is still changing, or no longer listed;
try again`.

Enter or a click on `reset all…` swaps the keys' line for its confirmation and
moves the ring onto `confirm`: `remove 3 overrides from this session's file ·
confirm · keep`. The count is how many settings the scope line's file
overrides, as the rows' sources say (this machine's file with no session
name). `your shell's exports stay` follows while the shell sets a setting, and
`mod rows keep their values` while the pane lists a `/config` row, since a
reset changes neither. The first part ends in `…` where it must leave the two
Buttons room, and the others follow only while they fit, so the 58-column dock shows
none of them. `confirm` runs `cs -config reset --yes`, or `cs <name> -config
reset --yes` for this session's file, and the toast is cs's line:
`N settings removed from <path>`, `nothing to reset in <path>` or `no settings
file at <path>; nothing to reset`. cs can remove more lines than the line
counts, such as a value it skipped or one the other file overrides, and its
line gives the real number. A refusal toasts `cs settings not reset: exited
<code>: <cs's line>`. `keep` brings the keys' line back and runs nothing, and
both put the ring back on `reset all…`. A press before cs first lists its
settings opens no confirmation and toasts `cs has not listed its settings yet,
so nothing was reset`. When the pane draws no footer, as when the filter
matches nothing, or no keys' line on a short pane, it draws no reset control
either.

Bare `/cs` is a cooperative pair with the `cs` mod's rail: the `cs` mod passes
the bare form on with `next(e)`, and this mod passes any argument on, so
`/cs next` and the bare form answer the same whichever plugin's hook runs first.
`claude plugin validate` lists both hooks as gates.

The mod reads both sources when the pane opens, after each change or reset, at the end of
each main-loop turn while the pane is open, and, after a `/config` menu change of
one of those four plugins' rows, reads the `/config` rows again (a pass-through
`config.set` hook whose own failure never refuses the row). It runs no clock. It redraws only when an answer
changed, keeps the last rows over a failed or unreadable answer and names the
reason above them.

The mod writes nothing itself: cs writes the settings files and the `/config`
writer the rows. It has no heartbeat and no doctor row; doctor's drift scan
covers its deployed files. Its words live in exported tables (`COMMANDS`,
`REPLIES`, `TOASTS`, `PROBLEMS`, `LOGS` in `register.tsx`, `WORDS` in
`draw.tsx`, `LABELS` in `settings.ts`), and `drawPane(view, el,
handlers)` is pure over a view. `tests/test_mod_panel.sh` runs the kit test and
pins the manifest, the installer listing and the validate inventory, its
hooks and its calls, with no `$.ui.ask` among them;
`tests/test_config.sh` holds the porcelain to
`tests/fixtures/config-porcelain.txt`, which the kit reads as `test/golden.ts`.

## cs-filter-chat (not a hook script — a Claude Code mod)

`mods/cs-filter-chat/` is a Claude Code function-hooks plugin, deployed and gated
the same way as the `cs` mod: `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, which every
`cs <name>` launch exports and `CS_NO_FUNCTION_HOOKS=1` withholds. While
filter chat is on, the chat shows what you type and what Claude answers, and
nothing of the work between them. Filter chat is off by default: a session turns
it on with the switch below, and it draws only in a session that `cs -vet-session` accepts. While a session is off, every hook
passes Claude Code's own drawing through.

The switch is per session:

- `filter chat`, the cs band's key (see the band above), pressed by
  a click, or by Enter once Ctrl+X Tab has focused the band, never a chord: this session
  on or off. It shows during a turn too, and leaves the row to a survey or
  an armed handoff.
- `/filter-chat` alone flips this session's switch: it reads the setting and
  writes the other value. `/filter-chat on` and `/filter-chat off` set it.
  `/filter-chat` is an immediate command, so it runs mid-turn too.
- `/filter-chat status` reads the setting again and replies `on` or `off`. It
  writes nothing.
- Any other word replies with the usage line.

While filter chat is on, the mode line under the prompt adds
`filter chat · /filter-chat to switch`. A switch redraws in place: no reload, no notice row,
and no other session changes.

The switch is the cs setting `CS_FILTER_CHAT`, so it lists in `cs -config list`
and the `/cs` pane like any other, and survives `/clear`, a rotation, `--resume`
and a relaunch in the session's `.cs/local/config`. `/filter-chat` and cs's band
write it through `cs <session> -config set`, `0` for off as the pane does, so it
outranks a `1` in this machine's file. Both mods read it as cs resolves it, and
neither trims a line:

- `CS_FILTER_CHAT` in the environment pins it: on only at `1`. `/filter-chat`
  says so instead of claiming a flip that did not take.
- Else the session's file answers, else this machine's. A file's last line
  naming the key with `1` or `0` wins.
- Nothing says: off, the default. cs-filter-chat starts no process and logs
  nothing. Outside a directory with `.cs/local` it is off whatever is set.
- A read error other than a missing file says nothing of the setting.
  cs-filter-chat logs the path and the error, and skips a line that repeats
  the one it logged last.

cs-filter-chat keeps the value in a mirror it reads once per load, not at each
draw. `/filter-chat` and the band key update it at once. A change from the `/cs`
pane or a shell reaches the drawing at the next load, or at `/filter-chat status`.

Every write asks cs first. `/filter-chat` runs `$CS_BIN -vet-session <cwd>` (10 s
timeout), the same rule cs's band asks before its own writes:

- In a directory with no `.cs/local`, `/filter-chat` writes nothing, starts no
  process and replies `cs-filter-chat: this directory is not a cs session (no
  .cs/local), so nothing changed.`
- Where cs refuses the session, the launch did not set `CS_BIN` or
  `CLAUDE_SESSION_NAME`, or `cs -config set` fails, it writes
  nothing and replies `cs-filter-chat: no filter chat change in this session:`
  with cs's refusal.
- cs-filter-chat vets the read that turns filter chat on, too. At the first draw of each
  load, a setting that reads on costs one
  `cs -vet-session` process (0.15-0.44 s), and the hooked rows wait for its
  answer before they draw. A session cs refuses reads as off: every row keeps
  Claude Code's own drawing, and the log says `cs-filter-chat: filter chat is off in this session:` with
  the refusal, again only when the refusal changes. A setting that reads off starts no
  process.
- `/filter-chat status` picks up the `/cs` pane, a shell or a second Claude
  process in the directory, and vets a flip to on that neither writer made before it turns
  filter chat on. `/filter-chat status` on an unchanged setting and the usage line
  start no process of their own.
- A band press needs no second vet: cs-filter-chat reads the setting once cs's press
  handler has finished, and cs vetted before it wrote.

What it draws while on:

- Your messages. A message you typed draws a bold `❯` in the you ink at Claude
  Code's 2-column margin, then your text. A slash command draws its name in
  that ink and its arguments dim. Off the terminal, as on desktop, your rows
  keep Claude Code's drawing.
- Claude's replies, at the same margin, with no label. The reply's Markdown
  is Claude Code's drawing (or cs-mermaid's), so diagrams draw whichever mod
  loads first.
- Errors and safeguard stops. A line takes the reply's place, coloured by who
  acts, with its remedies dim under it: violet for a safeguard stop, red when
  you must act, plain text when Claude Code handles it, such as `Connection
  lost` over `check your internet` and `send again to retry`.
- A slash command's answer: a dim `·` and its text, red on error. An empty
  answer draws nothing.

Nothing else draws, while a turn runs or after it. Tool calls, tool groups,
tool results, the progress hint and the turn's timing row draw an empty row
under both renderers (under `tui: "fullscreen"` a lone shell call arrives as a
one-call tool group, under the default renderer as a tool row and a result
row). Messages from other sessions, helpers and teammates, task
notifications and hook feedback draw nothing too. A message Claude Code did
not stamp draws as yours when it names no sender and is not hook feedback (a
channel the engine cannot attest, a message stored before stamps), and
nothing otherwise. A message from a source filter chat has no rule for,
such as a channel or a plugin, keeps Claude Code's drawing. Questions, info
notices, the prompt hint, the working line (`✳ Sauteing… (9s · ↓ 444 tokens)`,
Claude Code's own animated sign that a turn runs) and the row
above the prompt stay Claude Code's. A row that reports itself expanded
(ctrl+o, `--verbose`) draws Claude Code's own, so the detailed view still
shows everything. Each ink is a Claude Code theme key: violet is `merged`,
red is `error` and plain text is `text`. The you ink is the mod's one
`/config` row, `cs-filter-chat.youInk` (`cs: Filter chat: your lines' colour`), listed
under `Mods` in the `/cs` pane too, one setting for every session:
`remember` (blue, the default), `planMode` (teal), `success` (green),
`merged` (violet), `error` (red) or `text` (plain), each at 4.5:1 or more on
the light and dark themes' backgrounds. A change reloads the mod with the new
value, with no restart. A value outside these in `settings.json` reads as
`remember`, and Claude Code logs that it did. Claude Code resolves each key in
your theme on every draw, `auto`, the colour-blind and the ANSI themes
included, and the mod reads no other `/config` row.

Off costs a little, because every hook stays registered: there is no install
switch. A session that is off starts no `cs -vet-session` process, and the
mod keeps no transcript, runs no clock and writes no state.

`install.sh` deploys the mod's eight files (`.claude-plugin/plugin.json`, `hooks/hooks.json`,
`hooks/register.tsx`, `hooks/session.ts`, `hooks/settings.ts`,
`hooks/verdict.ts`, `hooks/words.ts` and `hooks/draw.tsx`) under
`~/.claude/skills/cs-filter-chat/`, `cs -doctor`'s drift scan holds them to the
checkout, and `cs -uninstall` removes the directory. An install also clears
from a copy left under the old name, `~/.claude/skills/cs-chat-only/`, every
file cs knows it wrote; a copy deployed by hand keeps the rest, each named
once in a `Kept <path>: cs did not write it` warning, and the directory stays
for you to delete. The
mod writes no heartbeat, so `cs -doctor` has no "last ran" row for it.

Tests: `tests/test_mod_filter_chat.sh` pins the manifest, which declares no state
types and one `userConfig` field, the you ink, whose options are the theme keys
`hooks/settings.ts` lists, in its order, checks that the installer lists each of the mod's
files, checks that the source never names the events and calls the mod must
not use (`tool.call`, `turn.step`, `classic.*`, `prompt.compose`,
`config.set`, `$.command.run`), runs `claude plugin validate` and pins its
exact hook inventory, type-checks the mod against the engine's contract when `npx` is on `PATH`
and engine-written types are present, and runs the tests under `mods/cs-filter-chat/test/` with `claude plugin test` when
`claude` is on `PATH`.

## Hook Configuration

The hooks are configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/session-start.sh", "timeout": 30 }] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/autosave-commits.sh", "timeout": 10, "async": true }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/stop-blocks.sh", "timeout": 10 }] },
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/stop-notices.sh", "timeout": 10, "async": true }] }
    ],
    "FileChanged": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/stop-blocks.sh", "timeout": 10, "asyncRewake": true, "rewakeMessage": "cs woke this session:", "rewakeSummary": "cs" }] }
    ],
    "CwdChanged": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/stop-blocks.sh", "timeout": 5 }] }
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
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/scope-prompt.sh", "timeout": 10 }] }
    ]
  }
}
```

Hooks activate wherever `cs_resolve_session` finds a session: from the exported `CLAUDE_SESSION_NAME`/`CLAUDE_SESSION_DIR` when `cs` launched the conversation, and otherwise by walking up from the directory the front end opened — except in a terminal, where only a `cs` launch resolves (see "How a hook finds its session" above). Outside a session root, and in a session carrying `.cs/local/disabled`, they pass through without effect.
