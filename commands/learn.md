---
allowed_tools:
  - Bash
---

Record a cross-session learning — a project-wide insight that future sessions should know about.

## Usage

```
/learn <insight>
```

Examples:
- `/learn sed -i on macOS requires empty '' argument`
- `/learn pytest fixture scope=session shares state across all tests`
- `/learn the staging API requires X-Forwarded-Host header for CORS`

## When to use

Trigger this when you (or Claude) discover something **persistent about the project** that isn't obvious from the code — a gotcha, a platform quirk, a pattern that wasn't intuitive, a workaround for a broken tool. These are the kinds of things that would make a future session say "oh, right, I've seen this before."

Don't use it for:
- Short-lived session state (that's what `.cs/discoveries.md` is for)
- Information derivable from reading the code
- One-off observations that don't generalize

## What it does

Runs `cs -learn "<insight>"` via the Bash tool. This appends an entry to `$CS_SESSIONS_ROOT/learnings.jsonl` — an append-only JSONL file shared across all sessions on this machine. Each entry records:
- ISO 8601 timestamp
- Current session name
- The insight text verbatim
- Tags array (empty by default)
- Confidence score

## How learnings get surfaced

On session resume, the session-start hook automatically injects up to 3 relevant learnings into Claude's context:
1. First preference: entries where `session` matches the current session name
2. Fallback: the 3 most recent entries across all sessions

You can also manually list them:
- `cs -learnings` — show all
- `cs -learnings <session-name>` — filter by session

## Steps

1. Take the full insight from `$ARGUMENTS`.
2. If it's empty, ask the user what insight they want to record.
3. Run `cs -learn "<insight>"` via Bash.
4. Confirm it was saved — include the session name that was recorded.

Keep the confirmation short. The user typed `/learn` because they wanted to capture something quickly, not because they wanted a conversation about it.
