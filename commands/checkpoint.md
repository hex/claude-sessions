---
allowed-tools: Bash
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

Runs `cs -checkpoint "<label>"` via the Bash tool, which captures the current git state, the uncommitted-file list, and a snapshot of the session narrative, and records the checkpoint on the session timeline. The command's own output names the file it saved under `.cs/checkpoints/`.

## Related commands

- `cs -checkpoint list` — list all checkpoints for this session
- `cs -checkpoint show <name>` — print a specific checkpoint file

## Steps

1. Take the full label from `$ARGUMENTS`.
2. If it's empty, propose a label derived from the current state of the work and ask the user to confirm or replace it.
3. Route reserved words to the matching subcommand instead of saving a label: if `$ARGUMENTS` is exactly `list` or `ls`, run `cs -checkpoint list`; if it starts with `show `, run `cs -checkpoint show <name>`. Report that output and skip steps 4-5. If the user actually wants a label that begins with one of these words, rephrase it.
4. Otherwise save it: run `cs -checkpoint '<label>'` via Bash, single-quoting the label and escaping any embedded single quote. If the command fails (for example, run outside a cs session), report its error output verbatim and stop — do not retry with variations.
5. Report the saved filename and one line on what the checkpoint captured. Do NOT restate the full checkpoint content.
