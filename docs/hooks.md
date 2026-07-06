# Hooks

The installer configures Claude Code hooks that enable session management features.

## session-start.sh (SessionStart)

Runs when Claude Code starts a session:
- Logs session start (including source: `startup`, `resume`, `clear`, `compact`) to `.cs/logs/session.log` and appends a `session_start` event to `.cs/timeline.jsonl`
- On all sources: clears the statusline's attention marker (`.cs/local/attention`) — a fresh session is attended by definition
- On all sources: rebinds `claude_session_id` in the machine-local `.cs/local/state` to the live conversation UUID from the hook input. Claude Code forks a new UUID when a conversation is continued past the context limit (the old transcript stays on disk), so the recorded binding can silently go stale and `cs` would resume the pre-fork conversation. Non-UUID session ids are ignored; each rebind is logged to `session.log`
- On `startup`/`resume` only: configures `transfer.hideRefs`, recovers autosaved changes from crashed sessions
- On `resume` only: injects dynamic context (last activity, recent commits, objective, up to 5 most recently active sibling sessions with their objectives), and a per-actor digest of shared memory/narrative activity since this actor's `.cs/local/watermark` (grouped by git author), then advances the watermark
- On all sources: exports session environment variables, injects session context into Claude's system prompt

## autosave-commits.sh (PostToolUse on Write/Edit)

Runs after any file modification (Write or Edit), providing crash recovery for all session files:
- Autosaves entire working tree to the `refs/worktree/cs/auto` shadow ref using git plumbing commands (per-checkout, so parallel worktree sessions never clobber each other; a legacy `refs/cs/auto` is cleaned up after the first successful write)
- Does not create commits on `main` or touch the working tree index
- Each autosave chains onto the previous one (linked list of snapshots)
- For narrative file edits, also logs the latest heading/bullet to `session.log`
- Runs in background to avoid blocking the session

## narrative-reminder.sh (Stop)

Runs when Claude pauses for user input:
- Raises the statusline's attention marker (`.cs/local/attention`, machine-local) so the Claude mark's color pulses until the user next interacts; skipped inside subagents
- Drains the task queue (`.cs/local/queue`) at each stop boundary when armed — pops and injects one task at a time and instructs Claude to mirror progress into the native task list — taking priority over the narrative reminder below while a drain is armed or running (returns early)
- When idle with tasks queued, gates a one-time `AskUserQuestion` (Start/Not yet), reading the statusline's stamped `.cs/local/context-pct` (see [Status line](statusline.md)) to suggest compacting above 60% context; a decline cools down 10 minutes via `.cs/local/queue.declined`, cleared as soon as the queue changes. Task text is arbitrary, so the injected `block` reason is emitted via `jq -nc --arg` rather than string interpolation, keeping the JSON valid regardless of quotes or newlines in the task
- Reminds Claude to review and update its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on the most recently modified `narrative.*.md`, when it has not been touched recently
- Cooldown-gated via `.cs/.narrative-reminder-cooldown` (at most once per 5 minutes); no size budget — narratives are native memory topic files that lazy-load
- Approves silently inside subagents and outside cs sessions, and when the narrative was modified within the cooldown window

## prose-lint.sh (Stop)

Runs when Claude pauses for user input:
- Lints prose written this session via `cs -lint` and blocks turn-end (`decision: block`) when AI-slop tells are found, feeding the file:line violations back so Claude fixes them before stopping
- Scope is `.cs/summary.md` and `.cs/memory/*.md` (surfaces with no cross-session in-file backlog); the append-heavy `narrative.md` and the `MEMORY.md` index are excluded
- Only files modified at/after `session.lock` mtime are checked, so a resumed session never re-flags prose written in earlier sessions
- After 3 consecutive unresolved blocks, allows the stop with a `session.log` warning rather than trapping the session

## session-end.sh (SessionEnd)

Runs when Claude Code session ends:
- Logs session end time and exit reason (`user_exit`, `sigint`, `error`, `timeout`) and appends a `session_end` event to `.cs/timeline.jsonl`
- Deletes the shadow autosave refs (`refs/worktree/cs/auto` for this checkout, plus any legacy `refs/cs/auto`)
- Cleans up lock files

## subagent-context.sh (SubagentStart)

Runs when Claude Code spawns a subagent (via the Agent tool):
- Injects session context into subagents so they know about the cs session
- Provides the session directory and key rules (secrets handling, documentation protocol)
- Uses `additionalContext` in the same format as SessionStart

## tool-failure-logger.sh (PostToolUseFailure)

Runs when a tool call fails (async, non-blocking):
- Logs tool name and truncated error message to `.cs/logs/session.log`
- Helps debug build failures, test errors, and other tool issues after the fact

## session-auto-approve.sh (PermissionRequest on Write/Edit)

Runs when Claude Code would show a permission dialog for Write or Edit:
- Auto-approves writes to files inside the session's `.cs/` metadata directory
- Falls through to the normal permission prompt for all other files
- Scoped narrowly to session metadata only — project files always require explicit approval

## bash-logger.sh (PreToolUse on Bash)

Runs before every Bash tool call (sync, fast):
- Logs `[timestamp] BASH: command` to `.cs/logs/session.log`
- Creates a complete audit trail of all commands Claude runs
- Truncates long commands at 200 chars
- Never blocks — uses `set -uo pipefail` without `set -e`

## scope-prompt.sh (UserPromptSubmit)

Runs before each user prompt is sent to Claude. First it clears the statusline's attention marker (`.cs/local/attention`) — any prompt, including slash commands, means the user is back. Then two independent responsibilities:

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
