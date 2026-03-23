---
allowed_tools:
  - Read
  - Write
  - Bash
  - Glob
---

Create a reusable Claude Code skill from a CLI command or workflow.

## Arguments

The user provides a command string (e.g., `/skillify npm run build && npm test`).

## Steps

1. Parse the command from the arguments
2. Determine a short, descriptive skill name from the command (e.g., `build-and-test`, `deploy-staging`, `run-migrations`)
3. Create a skill file at `.claude/skills/<name>/SKILL.md` with:
   - A clear description of what the command does
   - When to use it
   - The exact command(s) to run
   - Prerequisites or caveats (if any)
4. Confirm creation to the user

## Skill File Format

```markdown
PROACTIVE: Invoke when the user asks to <description of when>.

# <Skill Name>

<Brief description of what this workflow does.>

## When to Use

- <Situation where this skill applies>

## Commands

Run these commands in sequence:

```bash
<the command(s)>
```

## Notes

- <Any prerequisites, caveats, or environment requirements>
```

## Guidelines

- Keep the skill name lowercase with hyphens (e.g., `build-project`, `test-api`)
- If the command contains secrets or environment-specific values, note them as prerequisites
- If the command is a multi-step workflow (contains && or |), break it into numbered steps
- Check if a skill with the same name already exists before creating
- After creating, tell the user they can invoke it with `/<skill-name>`
