---
name: feature
description: Start a feature as its own cs worktree session, running in parallel in a tmux window, with a written brief it begins from. Invoke when the user asks to start, spin up, spawn or open a feature, or to hand a piece of work to a separate session while this one continues.
---

A feature session is a git worktree of this session's repo on its own branch,
opened by cs in a window of the cs-owned tmux session. This skill writes the
brief and spawns it; the new session reads the brief at its first turn and
begins. Landing the work later is `/finish <feature>` from the base session.

## Prerequisites

Only works in a cs session: check that `$CLAUDE_SESSION_NAME` has a value.
If empty, tell the user starting a feature needs a cs session and stop.

The base must be a git repository (`git rev-parse --git-dir` from the
workspace succeeds). A session that is not a repo has no branch to fork; say
so and stop.

## Resolve the name

The user gives a feature name, optionally with a base: `fix-auth` or
`myproj@fix-auth`.

- A name with `@` names both halves outright, `<base>@<feature>`.
- A bare name is the feature; the base is `$CLAUDE_SESSION_NAME`. If this
  session is itself a feature worktree (its name contains `@`), the base is
  the part before the `@`: features fork from the base, never from each
  other.
- No name at all: ask for one (AskUserQuestion is fine) before writing
  anything. Kebab-case, no spaces.

## Write the brief

The brief is what the new session has instead of this conversation. Write
it from what the user said and what you know, in this shape:

```
# <feature>

## Goal
One paragraph: what to build and why.

## Done when
- Observable outcomes, each checkable.

## Constraints
- Rules from this conversation the new session cannot see (design
  decisions already made, things rejected, files to leave alone).

## Report back
When done, send a one-line result to the base session with:
cs -msg <base> -k result "<what landed, what is left>"
Then the base session lands the work with /finish <feature>.
```

Keep it to what the new session needs; it has the repo, CLAUDE.md and the
session's own docs, so do not repeat those. If the user's request is too
thin to write a "Done when", ask one question first rather than inventing
outcomes.

Write it to a temp file outside the workspace:
`brief=$(mktemp "${TMPDIR:-/tmp}/cs-brief.XXXXXX")`. The spawner copies it
into place, so nothing of yours stays in the session tree.

## Spawn

```
cs -spawn <base>@<feature> --brief "$brief"
rm -f "$brief"
```

Add `--task "..."` lines only for work that is a checklist item on its own;
the brief already carries the feature. Let the permission prompt on
`cs -spawn` stand: that prompt is the user's confirmation that a worktree, a
branch and a window are about to exist. Never work around it.

cs refuses when the name is invalid, tmux is missing, the session is already
open, or a pending spawn for the name exists (cs keeps the earlier brief and
refuses the new one). Print the refusal verbatim and stop; do not retry with
a different name on your own.

## Report

Print the spawner's output: the tmux window and the attach hint (`tmux
attach -t cs`, or `tmux switch-client -t cs` from inside tmux). Then tell the
user, in one or two lines, that the feature session reads its brief at
`.cs/brief.md` and begins, that its result arrives here as mail from
`cs -msg`, and that `/finish <feature>` lands it. This session continues with
its own work.
