---
allowed_tools:
  - Bash
---

Save a labelled checkpoint of the current cs session state.

## Usage

```
/checkpoint <label>
```

The label is free text describing what this moment represents — for example:
- `/checkpoint auth refactor complete`
- `/checkpoint stuck on token expiry bug`
- `/checkpoint before trying migration approach B`

## What it does

Runs `cs -checkpoint "<label>"` via the Bash tool. This captures:
- Current timestamp and git HEAD
- Snapshot of `.cs/discoveries.md`
- Snapshot of `.cs/changes.md`
- List of uncommitted files
- Appends a `checkpoint` event to `.cs/timeline.jsonl`

Checkpoints are saved to `.cs/checkpoints/YYYY-MM-DD-HHMMSS-{slug}.md`.

## Related commands

- `cs -checkpoint list` — list all checkpoints for this session
- `cs -checkpoint show <name>` — print a specific checkpoint file

## Steps

1. Take the full label from `$ARGUMENTS`.
2. If it's empty, ask the user what label they want.
3. Run `cs -checkpoint "<label>"` via Bash.
4. Report the result — include the filename it was saved as.
5. Briefly note what the checkpoint captured (discoveries, changes, git HEAD).

Do NOT restate the entire checkpoint content — just confirm it was saved and what it included.
