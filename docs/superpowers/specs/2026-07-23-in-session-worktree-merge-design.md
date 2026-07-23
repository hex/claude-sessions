# In-session worktree merge ownership design

Date: 2026-07-23
Status: approved by the task's explicit no-pause implementation instruction

## Problem

`cs <base> --merge <feature>` refuses when either the base or feature
worktree has a live PID lock. A `cs` launch writes its shell PID to that lock,
exports its session identity, and replaces the shell with Claude Code, so the
lock PID remains the live Claude process. A Bash tool call made inside that
conversation is a descendant of the lock owner and inherits the session name.
The current unconditional live-lock refusal therefore makes a merge impossible
from the base conversation even when the feature conversation is closed.

Removing the feature worktree from inside its own conversation is different.
On macOS, `git worktree remove --force` can unlink a worktree while another
process still has its current directory there. The live process survives with
an unusable, deleted working directory. That path must remain blocked.

## Ownership signal

The guard will identify its one permitted live lock with two checks:

1. `CLAUDE_SESSION_NAME` exactly equals the session whose lock is being
   examined.
2. The lock PID is the current `cs` process or one of its ancestors, found with
   BSD/POSIX-compatible `ps -o ppid= -p`.

Both checks are required. A name-only exemption can be inherited or spoofed.
An ancestor-only exemption would treat a foreign session alias that resolves to
the same checkout as the target base. The ancestor check also prevents a stale
lock whose PID was reused by an unrelated live process from being mistaken for
the caller's lock.

`CS_CLAUDE_SESSION_ID` is supporting evidence, not the ownership key. The
SessionStart hook can update `claude_session_id` after a context-limit fork
without changing the launch process's inherited `CS_CLAUDE_SESSION_ID`.
Further, two names resolving to one checkout read the same
`.cs/local/state`. Requiring exact UUID equality would therefore create false
refusals after rotation without solving the shared-checkout alias case.

If `ps` fails or produces a malformed parent PID, ownership is not established
and the existing hard refusal remains. This is fail-closed.

## Merge behavior

The feature session `base@feature` is always refused when it invokes its own
merge. The error gives the exact hand-off command and says to run it from the
base session or a free terminal after closing the feature session.

For every live lock in the base/feature pair:

- the exact invoking base session's ancestor-owned lock is ignored;
- every other live lock remains a hard blocker;
- dead or absent locks retain the existing non-blocking behavior.

The merge, ignored-mode record fusion, worktree removal, branch deletion, and
timeline event remain in their existing order.

## Rejected deferred-cleanup design

Merging and fusing immediately while leaving worktree removal for a future
launch would require durable pending state under `.cs/local/`, idempotent
ignored-mode fusion, launch and doctor reconciliation, and collision-menu
filtering. A failure or retry after fusion can otherwise append the same
timeline, log, and narrative records twice. The narrowed hand-off fixes the
common base-session case without introducing a partial lifecycle state.

## Concurrency and memory

Ignored-mode fusion still requires the feature lock to be closed, so its source
records are stable. When the base lock is exempted, the merge command is a
descendant of that exact lock owner; the conversation is synchronously waiting
for its Bash tool call. Foreign base locks and aliases remain blocked.

Tracked mode keeps the existing `MEMORY.md merge=ours` setup and warning. The
ownership change occurs before merge-driver setup and does not change which
memory index wins. Ignored mode likewise keeps the base `MEMORY.md` and reports
the skipped feature index.

## Tests

Extend `tests/test_worktrees.sh` with real temporary git/worktree flows:

- merge from the base session succeeds, including ignored-mode record fusion;
- merge from the feature session refuses with the narrowed hand-off;
- a live lock owned by a foreign session name still refuses even when it is an
  ancestor and shares the base UUID/state;
- a matching name and UUID do not exempt a live sibling PID, simulating PID
  reuse by an unrelated process.

Update `skills/merge/SKILL.md` and its contract test so the documented ritual
allows merge from the base session and requires hand-off only from the feature.

