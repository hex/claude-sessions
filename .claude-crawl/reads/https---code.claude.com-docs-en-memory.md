# How Claude remembers your project - Claude Code Docs

[Skip to main content](https://code.claude.com/docs/en/memory#content-area)

[Claude Code Docs home page![Image 1: light logo](https://mintcdn.com/claude-code/c5r9_6tjPMzFdDDT/logo/light.svg?fit=max&auto=format&n=c5r9_6tjPMzFdDDT&q=85&s=78fd01ff4f4340295a4f66e2ea54903c)![Image 2: dark logo](https://mintcdn.com/claude-code/c5r9_6tjPMzFdDDT/logo/dark.svg?fit=max&auto=format&n=c5r9_6tjPMzFdDDT&q=85&s=1298a0c3b3a1da603b190d0de0e31712)](https://code.claude.com/docs/en/overview)

![Image 3: US](https://d3gk2c5xim1je2.cloudfront.net/flags/US.svg)

English

Search...

Ctrl K Ask AI

*   [Claude Developer Platform](https://platform.claude.com/)
*   [Claude Code on the Web](https://claude.ai/code)
*   [Claude Code on the Web](https://claude.ai/code)

Search...

Navigation

Core concepts

How Claude remembers your project

[Getting started](https://code.claude.com/docs/en/overview)[Build with Claude Code](https://code.claude.com/docs/en/sub-agents)[Deployment](https://code.claude.com/docs/en/third-party-integrations)[Administration](https://code.claude.com/docs/en/setup)[Configuration](https://code.claude.com/docs/en/settings)[Reference](https://code.claude.com/docs/en/cli-reference)[Resources](https://code.claude.com/docs/en/legal-and-compliance)

##### Getting started

*   [Overview](https://code.claude.com/docs/en/overview)
*   [Quickstart](https://code.claude.com/docs/en/quickstart)
*   [Changelog](https://code.claude.com/docs/en/changelog)

##### Core concepts

*   [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works)
*   [Extend Claude Code](https://code.claude.com/docs/en/features-overview)
*   [Store instructions and memories](https://code.claude.com/docs/en/memory)
*   [Common workflows](https://code.claude.com/docs/en/common-workflows)
*   [Best practices](https://code.claude.com/docs/en/best-practices)

##### Platforms and integrations

*   [Remote Control](https://code.claude.com/docs/en/remote-control)
*   [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
*   Claude Code on desktop 
*   [Chrome extension (beta)](https://code.claude.com/docs/en/chrome)
*   [Visual Studio Code](https://code.claude.com/docs/en/vs-code)
*   [JetBrains IDEs](https://code.claude.com/docs/en/jetbrains)
*   Code review & CI/CD 
*   [Claude Code in Slack](https://code.claude.com/docs/en/slack)

On this page

*   [CLAUDE.md vs auto memory](https://code.claude.com/docs/en/memory#claude-md-vs-auto-memory)
*   [CLAUDE.md files](https://code.claude.com/docs/en/memory#claude-md-files)
*   [Choose where to put CLAUDE.md files](https://code.claude.com/docs/en/memory#choose-where-to-put-claude-md-files)
*   [Set up a project CLAUDE.md](https://code.claude.com/docs/en/memory#set-up-a-project-claude-md)
*   [Write effective instructions](https://code.claude.com/docs/en/memory#write-effective-instructions)
*   [Import additional files](https://code.claude.com/docs/en/memory#import-additional-files)
*   [How CLAUDE.md files load](https://code.claude.com/docs/en/memory#how-claude-md-files-load)
*   [Load from additional directories](https://code.claude.com/docs/en/memory#load-from-additional-directories)
*   [Organize rules with .claude/rules/](https://code.claude.com/docs/en/memory#organize-rules-with-claude%2Frules%2F)
*   [Set up rules](https://code.claude.com/docs/en/memory#set-up-rules)
*   [Path-specific rules](https://code.claude.com/docs/en/memory#path-specific-rules)
*   [Share rules across projects with symlinks](https://code.claude.com/docs/en/memory#share-rules-across-projects-with-symlinks)
*   [User-level rules](https://code.claude.com/docs/en/memory#user-level-rules)
*   [Manage CLAUDE.md for large teams](https://code.claude.com/docs/en/memory#manage-claude-md-for-large-teams)
*   [Deploy organization-wide CLAUDE.md](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)
*   [Exclude specific CLAUDE.md files](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files)
*   [Auto memory](https://code.claude.com/docs/en/memory#auto-memory)
*   [Enable or disable auto memory](https://code.claude.com/docs/en/memory#enable-or-disable-auto-memory)
*   [Storage location](https://code.claude.com/docs/en/memory#storage-location)
*   [How it works](https://code.claude.com/docs/en/memory#how-it-works)
*   [Audit and edit your memory](https://code.claude.com/docs/en/memory#audit-and-edit-your-memory)
*   [View and edit with /memory](https://code.claude.com/docs/en/memory#view-and-edit-with-%2Fmemory)
*   [Troubleshoot memory issues](https://code.claude.com/docs/en/memory#troubleshoot-memory-issues)
*   [Claude isn’t following my CLAUDE.md](https://code.claude.com/docs/en/memory#claude-isn%E2%80%99t-following-my-claude-md)
*   [I don’t know what auto memory saved](https://code.claude.com/docs/en/memory#i-don%E2%80%99t-know-what-auto-memory-saved)
*   [My CLAUDE.md is too large](https://code.claude.com/docs/en/memory#my-claude-md-is-too-large)
*   [Instructions seem lost after /compact](https://code.claude.com/docs/en/memory#instructions-seem-lost-after-%2Fcompact)
*   [Related resources](https://code.claude.com/docs/en/memory#related-resources)

Core concepts

# How Claude remembers your project

Copy page

Give Claude persistent instructions with CLAUDE.md files, and let Claude accumulate learnings automatically with auto memory.

Copy page

Each Claude Code session begins with a fresh context window. Two mechanisms carry knowledge across sessions:
*   **CLAUDE.md files**: instructions you write to give Claude persistent context
*   **Auto memory**: notes Claude writes itself based on your corrections and preferences

This page covers how to:
*   [Write and organize CLAUDE.md files](https://code.claude.com/docs/en/memory#claude-md-files)
*   [Scope rules to specific file types](https://code.claude.com/docs/en/memory#organize-rules-with-clauderules) with `.claude/rules/`
*   [Configure auto memory](https://code.claude.com/docs/en/memory#auto-memory) so Claude takes notes automatically
*   [Troubleshoot](https://code.claude.com/docs/en/memory#troubleshoot-memory-issues) when instructions aren’t being followed

## [​](https://code.claude.com/docs/en/memory#claude-md-vs-auto-memory)

CLAUDE.md vs auto memory

Claude Code has two complementary memory systems. Both are loaded at the start of every conversation. Claude treats them as context, not enforced configuration. The more specific and concise your instructions, the more consistently Claude follows them.

|  | CLAUDE.md files | Auto memory |
| --- | --- | --- |
| **Who writes it** | You | Claude |
| **What it contains** | Instructions and rules | Learnings and patterns |
| **Scope** | Project, user, or org | Per working tree |
| **Loaded into** | Every session | Every session (first 200 lines) |
| **Use for** | Coding standards, workflows, project architecture | Build commands, debugging insights, preferences Claude discovers |

Use CLAUDE.md files when you want to guide Claude’s behavior. Auto memory lets Claude learn from your corrections without manual effort.Subagents can also maintain their own auto memory. See [subagent configuration](https://code.claude.com/docs/en/sub-agents#enable-persistent-memory) for details.
## [​](https://code.claude.com/docs/en/memory#claude-md-files)

CLAUDE.md files

CLAUDE.md files are markdown files that give Claude persistent instructions for a project, your personal workflow, or your entire organization. You write these files in plain text; Claude reads them at the start of every session.
### [​](https://code.claude.com/docs/en/memory#choose-where-to-put-claude-md-files)

Choose where to put CLAUDE.md files

CLAUDE.md files can live in several locations, each with a different scope. More specific locations take precedence over broader ones.

| Scope | Location | Purpose | Use case examples | Shared with |
| --- | --- | --- | --- | --- |
| **Managed policy** | • macOS: `/Library/Application Support/ClaudeCode/CLAUDE.md` • Linux and WSL: `/etc/claude-code/CLAUDE.md` • Windows: `C:\Program Files\ClaudeCode\CLAUDE.md` | Organization-wide instructions managed by IT/DevOps | Company coding standards, security policies, compliance requirements | All users in organization |
| **Project instructions** | `./CLAUDE.md` or `./.claude/CLAUDE.md` | Team-shared instructions for the project | Project architecture, coding standards, common workflows | Team members via source control |
| **User instructions** | `~/.claude/CLAUDE.md` | Personal preferences for all projects | Code styling preferences, personal tooling shortcuts | Just you (all projects) |

CLAUDE.md files in the directory hierarchy above the working directory are loaded in full at launch. CLAUDE.md files in subdirectories load on demand when Claude reads files in those directories. See [How CLAUDE.md files load](https://code.claude.com/docs/en/memory#how-claude-md-files-load) for the full resolution order.For large projects, you can break instructions into topic-specific files using [project rules](https://code.claude.com/docs/en/memory#organize-rules-with-clauderules). Rules let you scope instructions to specific file types or subdirectories.
### [​](https://code.claude.com/docs/en/memory#set-up-a-project-claude-md)

Set up a project CLAUDE.md

A project CLAUDE.md can be stored in either `./CLAUDE.md` or `./.claude/CLAUDE.md`. Create this file and add instructions that apply to anyone working on the project: build and test commands, coding standards, architectural decisions, naming conventions, and common workflows. These instructions are shared with your team through version control, so focus on project-level standards rather than personal preferences.

Run `/init` to generate a starting CLAUDE.md automatically. Claude analyzes your codebase and creates a file with build commands, test instructions, and project conventions it discovers. If a CLAUDE.md already exists, `/init` suggests improvements rather than overwriting it. Refine from there with instructions Claude wouldn’t discover on its own.Set `CLAUDE_CODE_NEW_INIT=true` to enable an interactive multi-phase flow. `/init` asks which artifacts to set up: CLAUDE.md files, skills, and hooks. It then explores your codebase with a subagent, fills in gaps via follow-up questions, and presents a reviewable proposal before writing any files.

### [​](https://code.claude.com/docs/en/memory#write-effective-instructions)

Write effective instructions

CLAUDE.md files are loaded into the context window at the start of every session, consuming tokens alongside your conversation. Because they’re context rather than enforced configuration, how you write instructions affects how reliably Claude follows them. Specific, concise, well-structured instructions work best.**Size**: target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence. If your instructions are growing large, split them using [imports](https://code.claude.com/docs/en/memory#import-additional-files) or [`.claude/rules/`](https://code.claude.com/docs/en/memory#organize-rules-with-clauderules) files.**Structure**: use markdown headers and bullets to group related instructions. Claude scans structure the same way readers do: organized sections are easier to follow than dense paragraphs.**Specificity**: write instructions that are concrete enough to verify. For example:
*   “Use 2-space indentation” instead of “Format code properly”
*   “Run `npm test` before committing” instead of “Test your changes”
*   “API handlers live in `src/api/handlers/`” instead of “Keep files organized”

**Consistency**: if two rules contradict each other, Claude may pick one arbitrarily. Review your CLAUDE.md files, nested CLAUDE.md files in subdirectories, and [`.claude/rules/`](https://code.claude.com/docs/en/memory#organize-rules-with-clauderules) periodically to remove outdated or conflicting instructions. In monorepos, use [`claudeMdExcludes`](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files) to skip CLAUDE.md files from other teams that aren’t relevant to your work.
### [​](https://code.claude.com/docs/en/memory#import-additional-files)

Import additional files

CLAUDE.md files can import additional files using `@path/to/import` syntax. Imported files are expanded and loaded into context at launch alongside the CLAUDE.md that references them.Both relative and absolute paths are allowed. Relative paths resolve relative to the file containing the import, not the working directory. Imported files can recursively import other files, with a maximum depth of five hops.To pull in a README, package.json, and a workflow guide, reference them with `@` syntax anywhere in your CLAUDE.md:

Report incorrect code

Copy

Ask AI

```
See @README for project overview and @package.json for available npm commands for this project.

# Additional Instructions
- git workflow @docs/git-instructions.md
```

For personal preferences you don’t want to check in, import a file from your home directory. The import goes in the shared CLAUDE.md, but the file it points to stays on your machine:

Report incorrect code

Copy

Ask AI

```
# Individual Preferences
- @~/.claude/my-project-instructions.md
```

The first time Claude Code encounters external imports in a project, it shows an approval dialog listing the files. If you decline, the imports stay disabled and the dialog does not appear again.

For a more structured approach to organizing instructions, see [`.claude/rules/`](https://code.claude.com/docs/en/memory#organize-rules-with-clauderules).
### [​](https://code.claude.com/docs/en/memory#how-claude-md-files-load)

How CLAUDE.md files load

Claude Code reads CLAUDE.md files by walking up the directory tree from your current working directory, checking each directory along the way. This means if you run Claude Code in `foo/bar/`, it loads instructions from both `foo/bar/CLAUDE.md` and `foo/CLAUDE.md`.Claude also discovers CLAUDE.md files in subdirectories under your current working directory. Instead of loading them at launch, they are included when Claude reads files in those subdirectories.If you work in a large monorepo where other teams’ CLAUDE.md files get picked up, use [`claudeMdExcludes`](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files) to skip them.
#### [​](https://code.claude.com/docs/en/memory#load-from-additional-directories)

Load from additional directories

The `--add-dir` flag gives Claude access to additional directories outside your main working directory. By default, CLAUDE.md files from these directories are not loaded.To also load CLAUDE.md files from additional directories, including `CLAUDE.md`, `.claude/CLAUDE.md`, and `.claude/rules/*.md`, set the `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` environment variable:

Report incorrect code

Copy

Ask AI

```
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir ../shared-config
```

### [​](https://code.claude.com/docs/en/memory#organize-rules-with-claude/rules/)

Organize rules with `.claude/rules/`

For larger projects, you can organize instructions into multiple files using the `.claude/rules/` directory. This keeps instructions modular and easier for teams to maintain. Rules can also be [scoped to specific file paths](https://code.claude.com/docs/en/memory#path-specific-rules), so they only load into context when Claude works with matching files, reducing noise and saving context space.

Rules load into context every session or when matching files are opened. For task-specific instructions that don’t need to be in context all the time, use [skills](https://code.claude.com/docs/en/skills) instead, which only load when you invoke them or when Claude determines they’re relevant to your prompt.

#### [​](https://code.claude.com/docs/en/memory#set-up-rules)

Set up rules

Place markdown files in your project’s `.claude/rules/` directory. Each file should cover one topic, with a descriptive filename like `testing.md` or `api-design.md`. All `.md` files are discovered recursively, so you can organize rules into subdirectories like `frontend/` or `backend/`:

Report incorrect code

Copy

Ask AI

```
your-project/
├── .claude/
│   ├── CLAUDE.md           # Main project instructions
│   └── rules/
│       ├── code-style.md   # Code style guidelines
│       ├── testing.md      # Testing conventions
│       └── security.md     # Security requirements
```

Rules without [`paths` frontmatter](https://code.claude.com/docs/en/memory#path-specific-rules) are loaded at launch with the same priority as `.claude/CLAUDE.md`.
#### [​](https://code.claude.com/docs/en/memory#path-specific-rules)

Path-specific rules

Rules can be scoped to specific files using YAML frontmatter with the `paths` field. These conditional rules only apply when Claude is working with files matching the specified patterns.

Report incorrect code

Copy

Ask AI

```
---
paths:
  - "src/api/**/*.ts"
---

# API Development Rules

- All API endpoints must include input validation
- Use the standard error response format
- Include OpenAPI documentation comments
```

Rules without a `paths` field are loaded unconditionally and apply to all files. Path-scoped rules trigger when Claude reads files matching the pattern, not on every tool use.Use glob patterns in the `paths` field to match files by extension, directory, or any combination:

| Pattern | Matches |
| --- | --- |
| `**/*.ts` | All TypeScript files in any directory |
| `src/**/*` | All files under `src/` directory |
| `*.md` | Markdown files in the project root |
| `src/components/*.tsx` | React components in a specific directory |

You can specify multiple patterns and use brace expansion to match multiple extensions in one pattern:

Report incorrect code

Copy

Ask AI

```
---
paths:
  - "src/**/*.{ts,tsx}"
  - "lib/**/*.ts"
  - "tests/**/*.test.ts"
---
```

#### [​](https://code.claude.com/docs/en/memory#share-rules-across-projects-with-symlinks)

Share rules across projects with symlinks

The `.claude/rules/` directory supports symlinks, so you can maintain a shared set of rules and link them into multiple projects. Symlinks are resolved and loaded normally, and circular symlinks are detected and handled gracefully.This example links both a shared directory and an individual file:

Report incorrect code

Copy

Ask AI

```
ln -s ~/shared-claude-rules .claude/rules/shared
ln -s ~/company-standards/security.md .claude/rules/security.md
```

#### [​](https://code.claude.com/docs/en/memory#user-level-rules)

User-level rules

Personal rules in `~/.claude/rules/` apply to every project on your machine. Use them for preferences that aren’t project-specific:

Report incorrect code

Copy

Ask AI

```
~/.claude/rules/
├── preferences.md    # Your personal coding preferences
└── workflows.md      # Your preferred workflows
```

User-level rules are loaded before project rules, giving project rules higher priority.
### [​](https://code.claude.com/docs/en/memory#manage-claude-md-for-large-teams)

Manage CLAUDE.md for large teams

For organizations deploying Claude Code across teams, you can centralize instructions and control which CLAUDE.md files are loaded.
#### [​](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)

Deploy organization-wide CLAUDE.md

Organizations can deploy a centrally managed CLAUDE.md that applies to all users on a machine. This file cannot be excluded by individual settings.

1

[](https://code.claude.com/docs/en/memory#)

Create the file at the managed policy location

*   macOS: `/Library/Application Support/ClaudeCode/CLAUDE.md`
*   Linux and WSL: `/etc/claude-code/CLAUDE.md`
*   Windows: `C:\Program Files\ClaudeCode\CLAUDE.md`

2

[](https://code.claude.com/docs/en/memory#)

Deploy with your configuration management system

Use MDM, Group Policy, Ansible, or similar tools to distribute the file across developer machines. See [managed settings](https://code.claude.com/docs/en/permissions#managed-settings) for other organization-wide configuration options.

A managed CLAUDE.md and [managed settings](https://code.claude.com/docs/en/settings#settings-files) serve different purposes. Use settings for technical enforcement and CLAUDE.md for behavioral guidance:

| Concern | Configure in |
| --- | --- |
| Block specific tools, commands, or file paths | Managed settings: `permissions.deny` |
| Enforce sandbox isolation | Managed settings: `sandbox.enabled` |
| Environment variables and API provider routing | Managed settings: `env` |
| Authentication method and organization lock | Managed settings: `forceLoginMethod`, `forceLoginOrgUUID` |
| Code style and quality guidelines | Managed CLAUDE.md |
| Data handling and compliance reminders | Managed CLAUDE.md |
| Behavioral instructions for Claude | Managed CLAUDE.md |

Settings rules are enforced by the client regardless of what Claude decides to do. CLAUDE.md instructions shape Claude’s behavior but are not a hard enforcement layer.
#### [​](https://code.claude.com/docs/en/memory#exclude-specific-claude-md-files)

Exclude specific CLAUDE.md files

In large monorepos, ancestor CLAUDE.md files may contain instructions that aren’t relevant to your work. The `claudeMdExcludes` setting lets you skip specific files by path or glob pattern.This example excludes a top-level CLAUDE.md and a rules directory from a parent folder. Add it to `.claude/settings.local.json` so the exclusion stays local to your machine:

Report incorrect code

Copy

Ask AI

```
{
  "claudeMdExcludes": [
    "**/monorepo/CLAUDE.md",
    "/home/user/monorepo/other-team/.claude/rules/**"
  ]
}
```

Patterns are matched against absolute file paths using glob syntax. You can configure `claudeMdExcludes` at any [settings layer](https://code.claude.com/docs/en/settings#settings-files): user, project, local, or managed policy. Arrays merge across layers.Managed policy CLAUDE.md files cannot be excluded. This ensures organization-wide instructions always apply regardless of individual settings.
## [​](https://code.claude.com/docs/en/memory#auto-memory)

Auto memory

Auto memory lets Claude accumulate knowledge across sessions without you writing anything. Claude saves notes for itself as it works: build commands, debugging insights, architecture notes, code style preferences, and workflow habits. Claude doesn’t save something every session. It decides what’s worth remembering based on whether the information would be useful in a future conversation.

Auto memory requires Claude Code v2.1.59 or later. Check your version with `claude --version`.

### [​](https://code.claude.com/docs/en/memory#enable-or-disable-auto-memory)

Enable or disable auto memory

Auto memory is on by default. To toggle it, open `/memory` in a session and use the auto memory toggle, or set `autoMemoryEnabled` in your project settings:

Report incorrect code

Copy

Ask AI

```
{
  "autoMemoryEnabled": false
}
```

To disable auto memory via environment variable, set `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`.
### [​](https://code.claude.com/docs/en/memory#storage-location)

Storage location

Each project gets its own memory directory at `~/.claude/projects/<project>/memory/`. The `<project>` path is derived from the git repository, so all worktrees and subdirectories within the same repo share one auto memory directory. Outside a git repo, the project root is used instead.To store auto memory in a different location, set `autoMemoryDirectory` in your user or local settings:

Report incorrect code

Copy

Ask AI

```
{
  "autoMemoryDirectory": "~/my-custom-memory-dir"
}
```

This setting is accepted from policy, local, and user settings. It is not accepted from project settings (`.claude/settings.json`) to prevent a shared project from redirecting auto memory writes to sensitive locations.The directory contains a `MEMORY.md` entrypoint and optional topic files:

Report incorrect code

Copy

Ask AI

```
~/.claude/projects/<project>/memory/
├── MEMORY.md          # Concise index, loaded into every session
├── debugging.md       # Detailed notes on debugging patterns
├── api-conventions.md # API design decisions
└── ...                # Any other topic files Claude creates
```

`MEMORY.md` acts as an index of the memory directory. Claude reads and writes files in this directory throughout your session, using `MEMORY.md` to keep track of what’s stored where.Auto memory is machine-local. All worktrees and subdirectories within the same git repository share one auto memory directory. Files are not shared across machines or cloud environments.
### [​](https://code.claude.com/docs/en/memory#how-it-works)

How it works

The first 200 lines of `MEMORY.md` are loaded at the start of every conversation. Content beyond line 200 is not loaded at session start. Claude keeps `MEMORY.md` concise by moving detailed notes into separate topic files.This 200-line limit applies only to `MEMORY.md`. CLAUDE.md files are loaded in full regardless of length, though shorter files produce better adherence.Topic files like `debugging.md` or `patterns.md` are not loaded at startup. Claude reads them on demand using its standard file tools when it needs the information.Claude reads and writes memory files during your session. When you see “Writing memory” or “Recalled memory” in the Claude Code interface, Claude is actively updating or reading from `~/.claude/projects/<project>/memory/`.
### [​](https://code.claude.com/docs/en/memory#audit-and-edit-your-memory)

Audit and edit your memory

Auto memory files are plain markdown you can edit or delete at any time. Run [`/memory`](https://code.claude.com/docs/en/memory#view-and-edit-with-memory) to browse and open memory files from within a session.
## [​](https://code.claude.com/docs/en/memory#view-and-edit-with-/memory)

View and edit with `/memory`

The `/memory` command lists all CLAUDE.md and rules files loaded in your current session, lets you toggle auto memory on or off, and provides a link to open the auto memory folder. Select any file to open it in your editor.When you ask Claude to remember something, like “always use pnpm, not npm” or “remember that the API tests require a local Redis instance,” Claude saves it to auto memory. To add instructions to CLAUDE.md instead, ask Claude directly, like “add this to CLAUDE.md,” or edit the file yourself via `/memory`.
## [​](https://code.claude.com/docs/en/memory#troubleshoot-memory-issues)

Troubleshoot memory issues

These are the most common issues with CLAUDE.md and auto memory, along with steps to debug them.
### [​](https://code.claude.com/docs/en/memory#claude-isn%E2%80%99t-following-my-claude-md)

Claude isn’t following my CLAUDE.md

CLAUDE.md content is delivered as a user message after the system prompt, not as part of the system prompt itself. Claude reads it and tries to follow it, but there’s no guarantee of strict compliance, especially for vague or conflicting instructions.To debug:
*   Run `/memory` to verify your CLAUDE.md files are being loaded. If a file isn’t listed, Claude can’t see it.
*   Check that the relevant CLAUDE.md is in a location that gets loaded for your session (see [Choose where to put CLAUDE.md files](https://code.claude.com/docs/en/memory#choose-where-to-put-claude-md-files)).
*   Make instructions more specific. “Use 2-space indentation” works better than “format code nicely.”
*   Look for conflicting instructions across CLAUDE.md files. If two files give different guidance for the same behavior, Claude may pick one arbitrarily.

For instructions you want at the system prompt level, use [`--append-system-prompt`](https://code.claude.com/docs/en/cli-reference#system-prompt-flags). This must be passed every invocation, so it’s better suited to scripts and automation than interactive use.

Use the [`InstructionsLoaded` hook](https://code.claude.com/docs/en/hooks#instructionsloaded) to log exactly which instruction files are loaded, when they load, and why. This is useful for debugging path-specific rules or lazy-loaded files in subdirectories.

### [​](https://code.claude.com/docs/en/memory#i-don%E2%80%99t-know-what-auto-memory-saved)

I don’t know what auto memory saved

Run `/memory` and select the auto memory folder to browse what Claude has saved. Everything is plain markdown you can read, edit, or delete.
### [​](https://code.claude.com/docs/en/memory#my-claude-md-is-too-large)

My CLAUDE.md is too large

Files over 200 lines consume more context and may reduce adherence. Move detailed content into separate files referenced with `@path` imports (see [Import additional files](https://code.claude.com/docs/en/memory#import-additional-files)), or split your instructions across `.claude/rules/` files.
### [​](https://code.claude.com/docs/en/memory#instructions-seem-lost-after-/compact)

Instructions seem lost after `/compact`

CLAUDE.md fully survives compaction. After `/compact`, Claude re-reads your CLAUDE.md from disk and re-injects it fresh into the session. If an instruction disappeared after compaction, it was given only in conversation, not written to CLAUDE.md. Add it to CLAUDE.md to make it persist across sessions.See [Write effective instructions](https://code.claude.com/docs/en/memory#write-effective-instructions) for guidance on size, structure, and specificity.
## [​](https://code.claude.com/docs/en/memory#related-resources)

Related resources

*   [Skills](https://code.claude.com/docs/en/skills): package repeatable workflows that load on demand
*   [Settings](https://code.claude.com/docs/en/settings): configure Claude Code behavior with settings files
*   [Manage sessions](https://code.claude.com/docs/en/sessions): manage context, resume conversations, and run parallel sessions
*   [Subagent memory](https://code.claude.com/docs/en/sub-agents#enable-persistent-memory): let subagents maintain their own auto memory

Was this page helpful?

Yes No

[Extend Claude Code](https://code.claude.com/docs/en/features-overview)[Common workflows](https://code.claude.com/docs/en/common-workflows)

Ctrl+I

[Claude Code Docs home page![Image 4: light logo](https://mintcdn.com/claude-code/c5r9_6tjPMzFdDDT/logo/light.svg?fit=max&auto=format&n=c5r9_6tjPMzFdDDT&q=85&s=78fd01ff4f4340295a4f66e2ea54903c)![Image 5: dark logo](https://mintcdn.com/claude-code/c5r9_6tjPMzFdDDT/logo/dark.svg?fit=max&auto=format&n=c5r9_6tjPMzFdDDT&q=85&s=1298a0c3b3a1da603b190d0de0e31712)](https://code.claude.com/docs/en/overview)

[x](https://x.com/AnthropicAI)[linkedin](https://www.linkedin.com/company/anthropicresearch)

Company

[Anthropic](https://www.anthropic.com/company)[Careers](https://www.anthropic.com/careers)[Economic Futures](https://www.anthropic.com/economic-futures)[Research](https://www.anthropic.com/research)[News](https://www.anthropic.com/news)[Trust center](https://trust.anthropic.com/)[Transparency](https://www.anthropic.com/transparency)

Help and security

[Availability](https://www.anthropic.com/supported-countries)[Status](https://status.anthropic.com/)[Support center](https://support.claude.com/)

Learn

[Courses](https://www.anthropic.com/learn)[MCP connectors](https://claude.com/partners/mcp)[Customer stories](https://www.claude.com/customers)[Engineering blog](https://www.anthropic.com/engineering)[Events](https://www.anthropic.com/events)[Powered by Claude](https://claude.com/partners/powered-by-claude)[Service partners](https://claude.com/partners/services)[Startups program](https://claude.com/programs/startups)

Terms and policies

[Privacy choices](https://code.claude.com/docs/en/memory#)[Privacy policy](https://www.anthropic.com/legal/privacy)[Disclosure policy](https://www.anthropic.com/responsible-disclosure-policy)[Usage policy](https://www.anthropic.com/legal/aup)[Commercial terms](https://www.anthropic.com/legal/commercial-terms)[Consumer terms](https://www.anthropic.com/legal/consumer-terms)

Assistant

Responses are generated using AI and may contain mistakes.
