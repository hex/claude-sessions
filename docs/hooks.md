# Hooks

The installer configures Claude Code hooks that enable session management features.

## How a hook finds its session (`cs-resolve.sh`)

Every hook opens by sourcing `cs-resolve.sh`, a library shipped alongside them and
never registered against an event, and calling `cs_resolve_session`. It resolves in
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

This is what lets cs work in front ends that fire hooks but cannot export environment
into a session — Claude Code desktop among them, where `CLAUDE_ENV_FILE` is offered
and writable yet propagates to nothing. It also means a session started outside `cs`
(an IDE, a plugin, `claude` typed in a session folder) is no longer cs-blind;
`.cs/local/disabled` opts a directory out.

Session identity is not the only thing that differs by path: only `cs` writes
`.cs/session.lock`, so a hook that resolved by walking does not own it (see
`session-end.sh` below).

Resolving a session is also not the same as *being* it. Every claude that resolves a
session fires its hooks — agent-team teammates (full claude processes with their own
top-level `SessionStart`, not in-process subagents), headless `claude -p` children,
desktop conversations, a bare `claude` started in a session folder. The session's
recorded conversation (`claude_session_id`) is a single slot, so exactly one of them
may write it: the one `cs` launched. `cs` exports `CS_LEAD_PID` with the pid it
`exec`s into, Claude Code stamps every hook env with `CLAUDE_PID`, and the two match
only for the launched conversation — a context-limit fork and an in-process `/clear`
keep the process, while every other claude has a pid of its own. Environment cannot
answer this: children inherit exports, so a teammate carries `CS_LEAD_PID` while
owning a different pid.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start (including source: `startup`, `resume`, `clear`, `compact`) to `.cs/local/session.log` and appends a `started` event to `.cs/timeline.jsonl`
- On all sources: clears the statusline's attention marker (`.cs/local/attention`) — a fresh session is attended by definition — and, inside iTerm2 with shell integration installed, cancels any dock bounce the previous conversation left running (`CS_NO_ITERM2=1` disables)
- On all sources, **for the launched conversation only** (`CLAUDE_PID` = `CS_LEAD_PID`, see above): rebinds `claude_session_id` in the machine-local `.cs/local/state` to the live conversation UUID from the hook input. Claude Code forks a new UUID when a conversation is continued past the context limit (the old transcript stays on disk), so the recorded binding can silently go stale and `cs` would resume the pre-fork conversation. Non-UUID session ids are ignored; each rebind is logged to `session.log`. Any other claude resolving the same session — teammate, `claude -p` child, desktop, walked-in — leaves the slot alone, so `cs <name>` always resumes the conversation that was opened and the `rotated` timeline lineage stays true
- On `startup`/`resume` only: configures `transfer.hideRefs`, and recovers autosaved changes from a crash of **this conversation only** — it reads just the current conversation's own ref (`refs/worktree/cs/session/<conversation-uuid>`), so a live sibling session's in-flight ref is never misread as a crash. It also renames its ref across a context-fork UUID rebind (a clean continuation), claims any pre-upgrade shared ref once via a compare-and-swap delete, and garbage-collects other conversations' refs older than 14 days. The whole-tree restore (`checkout <shadow ref> -- .`) is offered only when the snapshot's recorded base HEAD still matches the current HEAD; if HEAD has moved since the snapshot (a commit or rebase) or the snapshot predates base recording, it instead warns and points at per-file inspection — a blanket restore over diverged history would overwrite committed work
- On `resume` only: injects dynamic context (last activity, recent commits, objective, up to 5 most recently active sibling sessions with their objectives), and a per-actor digest of shared memory/narrative activity since this actor's `.cs/local/watermark` (grouped by git author), then advances the watermark and stamps the day's date into `last_resumed`
- In a feature worktree (when `task_branch` is in machine-local state): injects a Feature Worktree contract instructing Claude to integrate only via `cs <base> --merge <feature>` and never merge the branch manually
- Where the conversation genuinely starts clean — source `clear`, or source `startup` with `CS_FRESH_REBIND=1` — injects a Fresh Conversation notice so Claude treats the turn as a clean break. The source is part of the test because `CS_FRESH_REBIND` is exported before `exec` and outlives the launch: on its own it would tell a later `/compact` of a rebound session that its transcript is not loaded while it still is
- When a `.cs/local/pending-handoff` marker is armed (by the `rotate` skill, or by the launch prompt's `r` answer): consumes it — flips the named `.cs/handoffs/` file's frontmatter to `consumed` (recording the new conversation UUID), removes the marker, and injects a Conversation Rotation preamble pointing Claude at the handoff to read first (mutually exclusive with the Fresh Conversation notice above, since a rotation is also a fresh start). Consumption requires source `startup` or `clear` **and** a handoff whose frontmatter still says `unconsumed`; a marker naming a spent or missing handoff is stale and is removed silently. On any other source the marker is left untouched, so a compaction or a context-limit fork between the rotate skill and `/clear` cannot eat a pending rotation. The same resolution decides the rebind's timeline label — `handoff` with the name, or `rebind`
- On all sources: surfaces the same queue-inbox digest as scope-prompt.sh — unseen entries in `.cs/local/notifications.jsonl` (task counts, the last breaker trip if any), gated by the `.cs/local/notifications.seen` cursor so it's shown at most once. Whichever of the two injection points runs first (this hook fires once at session start/resume; scope-prompt.sh fires on every prompt) claims the surfacing and advances the cursor for the other. Shares the `_build_digest` jq recipe verbatim with scope-prompt.sh by necessity — hooks are standalone scripts and cannot source a common file
- Does NOT surface the cross-session mail digest: that lives only in scope-prompt.sh now (it fires on every prompt), so duplicating it here would double-inject the same unread bodies on every startup and resume
- On all sources: names the current actor and its narrative file in the injected context, and states that the durable memory buckets are shared while only narratives are per-actor, so an entry naming someone else as the user was written by or for another actor. `.cs/memory/` is one store for every actor on a git-synced session, so a `type: user` entry written as an unconditional claim loads for all of them and reads as settled fact; a bare identity line is not enough, because a global instruction naming the right person was already in context and lost to such an entry. The actor precedence (`$CS_ACTOR`, then `.cs/local/identity`, then git `user.email`/`user.name`) is duplicated from `cs_actor_slug()` in `lib/40-state.sh` behind a KEEP IN SYNC comment — hooks cannot source `lib/`, and shelling out to `cs` would make the hook depend on `cs` being on `PATH`
- On all sources: exports session environment variables, injects session context into Claude's system prompt

## autosave-commits.sh (PostToolUse on Write/Edit)

Runs after any file modification (Write or Edit), providing crash recovery for all session files:
- Autosaves the entire working tree to the conversation's own shadow ref `refs/worktree/cs/session/<conversation-uuid>` (keyed on the hook input's `session_id`) using git plumbing commands. Each conversation writes, recovers, and deletes only its own ref, so concurrent sessions on one checkout — and parallel worktree sessions — never share or clobber each other's snapshot chain
- Does not create commits on `main` or touch the working tree index
- Chains each snapshot onto that conversation's previous one (a linked list per conversation)
- Records the HEAD the snapshot sits on as a `cs-base` commit trailer, so crash recovery can tell whether HEAD has since moved and refuse an unsafe whole-tree restore
- For narrative file edits, also logs the latest heading/bullet to `session.log`
- Runs in background to avoid blocking the session

## narrative-reminder.sh (Stop)

Runs when Claude pauses for user input:
- Raises the statusline's attention marker (`.cs/local/attention`, machine-local) so the Claude mark's color pulses until the user next interacts; skipped inside subagents
- Inside iTerm2 with shell integration installed (`~/.iterm2/it2attention`), also starts a dock bounce so the finished turn reaches a user working in another app; escapes go to `/dev/tty` because hook stdout is captured. `CS_NO_ITERM2=1` disables; silent everywhere else
- Drains the task queue (`.cs/local/queue`) at each stop boundary when armed — pops and injects one task at a time and instructs Claude to mirror progress into the native task list — taking priority over the narrative reminder below while a drain is armed or running (returns early); each transition also appends an event to the per-machine inbox (`.cs/local/notifications.jsonl`): `drain_started` on armed→draining, `task_done` per advance, `drain_finished` when the queue empties
- While draining, three circuit breakers evaluate after each task pops and before the next is injected: tool failures in the current task at/above `CS_QUEUE_MAX_FAILURES` (default 5, from `.cs/local/failures`), context at/above `CS_QUEUE_MAX_CTX` (default 85, from the statusline's `context-pct`), and the 5-hour rate-limit window at/above `CS_QUEUE_MAX_5H` (default 85, from the statusline's `limits`, skipped when its `stamped_at` is stale past 1800s); a non-numeric env override falls back to the default. A trip parks the queue (`queue.state` back to `idle`, the queue file left intact so `cs -queue start` re-arms), appends a `breaker_tripped` event to the inbox with the reason and reading, and emits a `block` debrief naming what tripped and how many tasks remain. The per-task failure count (`.cs/local/failures`) resets to zero on the armed→draining transition and again after every drain advance, so each task starts the breaker fresh
- Spawned workers report back: when `.cs/local/spawned-by` exists, drain completion sends the spawner a mailbox notify and deletes the marker (one-shot); a breaker trip notifies but keeps the marker so the eventual drain still reports.
- When idle with tasks queued, gates a one-time `AskUserQuestion` (Start/Not yet), reading the statusline's stamped `.cs/local/context-pct` (see [Status line](statusline.md)) to suggest compacting above 60% context; a decline cools down 10 minutes via `.cs/local/queue.declined`, cleared as soon as the queue changes. Task text is arbitrary, so the injected `block` reason is emitted via `jq -nc --arg` rather than string interpolation, keeping the JSON valid regardless of quotes or newlines in the task
- Rotation nudge: when context is at or above `CS_ROTATE_NUDGE_CTX` (default 80, non-numeric override falls back to the default) per the statusline's `context-pct`, and this conversation hasn't already been nudged (`.cs/local/rotate-nudged`, keyed on conversation UUID), emits a one-time `block` suggesting the `rotate` skill to write a handoff into `.cs/handoffs/` and arm it, after which the user runs `/clear` to continue in a fresh conversation. Only reached when the queue isn't gating or draining above — an armed/draining queue owns the turn loop
- Context warning: one tier below the nudge — when context is in the `[CS_CTX_WARN_CTX, CS_ROTATE_NUDGE_CTX)` band (defaults 60 to 80; a non-numeric override falls back to its default) and this conversation hasn't been warned (`.cs/local/ctx-warned`, keyed on conversation UUID), emits a one-time `block` telling Claude to let the user know context crossed into wind-down territory. At or above the nudge threshold only the rotation nudge fires — never both in one Stop
- Reminds Claude to review and update its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on the most recently modified `narrative.*.md`, when it has not been touched recently
- Cooldown-gated via `.cs/.narrative-reminder-cooldown` (at most once per 5 minutes); no size budget — narratives are native memory topic files that lazy-load
- Approves silently inside subagents and outside cs sessions, and when the narrative was modified within the cooldown window

## prose-lint.sh (Stop)

Runs when Claude pauses for user input:
- Lints prose written this session via `cs -lint` and blocks turn-end (`decision: block`) when AI-slop tells are found, feeding the file:line violations back so Claude fixes them before stopping
- Scope is `.cs/summary.md` and `.cs/memory/*.md` (surfaces with no cross-session in-file backlog); the append-heavy narrative notebooks (`narrative.md` and the per-actor `narrative.<actor>.md`) and the `MEMORY.md` index are excluded
- Only files modified at/after `session.lock` mtime are checked, so a resumed session never re-flags prose written in earlier sessions
- After 3 consecutive unresolved blocks, allows the stop with a `session.log` warning rather than trapping the session

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time and the exit source reported by Claude Code (defaulting to `user_exit` when none is given) and appends an `ended` event to `.cs/timeline.jsonl`
- Deletes only the ending conversation's own shadow ref (`refs/worktree/cs/session/<conversation-uuid>`); a concurrent sibling's ref is left untouched
- Cleans up `.cs/session.lock`, but only one this launch owns. Only `cs` writes a lock, so a hook that resolved by walking the directory belongs to another front end: closing a desktop conversation on a directory a CLI session is live in would otherwise strip that session's lock, letting `cs <name>` open a duplicate with no collision menu and leaving prose-lint inert mid-session (the cutoff file it tests for is gone). A walked-in hook still clears a lock whose process is gone, so a crashed session is never left locked out
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

**Queue digest.** Surfaces unseen entries from the per-machine inbox (`.cs/local/notifications.jsonl`) at most once: counts by event plus the last breaker reason, if any, e.g. `cs queue while you were away: 4 task(s) done; breaker tripped: context (91 >= 85), 2 remaining. Run cs -queue log for detail.` The `.cs/local/notifications.seen` cursor advances immediately after building the digest, even when the digest text itself is empty, so surfacing stays at-most-once regardless of what else this prompt does. When scope grounding below also has content, the digest is spliced above the `## Scope (auto-grounded)` block rather than replacing it — every exit path in this hook still delivers a pending digest. **Mail digest.** scope-prompt.sh (only) surfaces unread cross-session mail on **every** prompt until it is read — persistent, not surface-once. It inlines the bodies of `mail/inbox.jsonl` lines past the `mail/seen` cursor (which only `cs -msg` advances on read), bounded to 5 messages with sender and body truncated inside jq (codepoint-safe) plus an "N more" overflow line. A `task`-kind message is a count-only label, never its body — the body is already an imperative in the recipient's queue, so inlining it would double-execute. No cursor is written by the hook (persistence rides `seen`), keeping it a read-only view of the inbox. `wc -l` counts newline-terminated lines, so a torn or mid-write final line is excluded until complete.

**Objective capture.** Records the first substantive prompt of a session as the `## Objective` in `.cs/README.md`, but only while it still holds the unedited template placeholder — so the first real prompt wins, nothing afterwards churns it, and a hand-written objective is never overwritten. Skips slash commands, `!` shell passthrough, and trivially short prompts; collapses to one line and truncates to ~100 chars. The prompt is written via `awk` `ENVIRON` (no escape/replacement processing of arbitrary text), atomically via tmp+rename. Opt-out per-session: `export CS_OBJECTIVE_CAPTURE_DISABLE=1`.

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
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/narrative-reminder.sh", "timeout": 10 }] },
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/prose-lint.sh", "timeout": 15 }] }
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
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/cs/scope-prompt.sh", "timeout": 3 }] }
    ]
  }
}
```

Hooks only activate when running inside a `cs` session (detected via `CLAUDE_SESSION_NAME` environment variable). Outside of `cs` sessions, they pass through without effect.
