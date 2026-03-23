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
2. Determine a skill name: lowercase, hyphens only, max 64 chars. Prefer gerund form (e.g., `building-project`, `testing-api`, `deploying-staging`)
3. Write a description in **third person** that says what the skill does AND when to use it (max 1024 chars)
4. Check if `.claude/skills/<name>/SKILL.md` already exists — if so, ask before overwriting
5. Create the skill file following the format below
6. Confirm creation and tell the user they can invoke it with `/<skill-name>`

## Skill File Format

The file MUST have YAML frontmatter with `name` and `description`:

```markdown
---
name: <skill-name>
description: <Third-person description of what it does and when to use it. Include key terms for discovery.>
---

# <Human-Readable Title>

<One sentence: what this does.>

## Commands

```bash
<the command(s)>
```

## Notes

- <Prerequisites, caveats, or environment requirements — only if needed>
```

## Rules

- `name`: lowercase letters, numbers, hyphens only. No "anthropic" or "claude" in the name.
- `description`: third person ("Runs the build pipeline" not "I run the build"). Include trigger terms.
- Keep SKILL.md concise — only include what Claude doesn't already know. No verbose explanations.
- If the command is a multi-step workflow (contains && or |), break into numbered steps.
- If the command references secrets or env-specific values, note them in Notes section.
- Do NOT use `PROACTIVE:` keyword — use the `description` field for triggering.
