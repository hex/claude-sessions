# cs - Claude Code Session Manager

[![Test](https://github.com/hex/claude-sessions/actions/workflows/test.yml/badge.svg)](https://github.com/hex/claude-sessions/actions/workflows/test.yml)

A session manager for [Claude Code](https://github.com/anthropics/claude-code) that creates isolated workspaces with automatic documentation.

![cs session demo](assets/screenshot.png)

## Why cs?

Claude Code doesn't require a project. You can spin up an instance to debug an API, troubleshoot home automation, research a hardware problem, or explore any idea that comes to mind.

But conversations get lost. You discover key insights, create useful scripts, figure out a tricky configuration - then the session ends and it's gone.

**cs gives every task a home:**

```bash
cs debug-api          # Investigate that flaky endpoint
cs homeassistant      # Fix your smart home setup
cs router-config      # Document your network settings
cs research-llms      # Explore a topic, keep your notes
```

Each session is a persistent workspace - documentation and secrets that survive across conversations.

No git repo required. No project structure needed. Just a name for what you're working on.

## Features

- **Isolated session workspaces** - Each session has its own directory with structured documentation
- **Secure secrets handling** - Store sensitive data in the OS keychain (value read from stdin, never written to a file); exportable as [age](https://github.com/FiloSottile/age)-encrypted files for backup
- **Documentation templates** - Pre-configured markdown files for the session narrative and outcome
- **Automatic git version control** - Every session gets a local git repo; in-session edits are autosaved to a shadow ref for crash recovery
- **Session locking** - PID-based lock prevents the same session from being opened in two terminals simultaneously; use `--force` to override
- **Deterministic Claude-session resume** - Each session pre-allocates a conversation UUID in the gitignored `.cs/local/state`, so `cs <name>` resumes the *exact* conversation via `claude --resume <uuid>`, not the most-recent one `--continue` might pick from a sibling. A `ps`-based guard refuses to launch a second claude for the same conversation (`--force` overrides), and every launch passes `--name` plus a per-session `/color` so parallel sessions stay visually distinct.
- **Per-session memory path redirect** - cs points Claude Code's built-in auto-memory writer at `<session>/.cs/memory/` (via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`) so durable facts land in the session instead of the global project store. The harness owns how memory files are written (naming, frontmatter, `MEMORY.md` index); cs owns only the storage path.
- **Cross-session search** - `cs -search <query>` greps across all sessions' narrative, memory, and README
- **Prose hygiene enforcement** - `cs -lint <file>` flags AI-slop tells (em-dashes, a curated banned-phrase list) outside code fences; the `prose-lint` Stop hook blocks turn-end when prose written this session carries them. `/summary` and `/wrap` add a subagent judge that applies the full `prose-hygiene` taxonomy a regex can't catch. See [docs/hooks.md](docs/hooks.md)
- **Auto-grounded scope** - On each code-work prompt, the `scope-prompt` hook injects a bounded context block — matching tracked files, recent commits, and a working-tree diff — grounding Claude in the current codebase before it acts. Capped at 8000 bytes; opt out per-session with `CS_SCOPE_DISABLE=1`. See [docs/hooks.md](docs/hooks.md)
- **Status line** - `cs-statusline` renders Claude Code's status bar as one line of squared pills: a Claude logo badge (pulsing until your next prompt), the session name in its `/color`, a queued-task count, git branch with ahead/behind and dirty counts, model + effort, context %, 5-hour/weekly rate limits, and session cost — all from the status-line JSON plus one bounded git call, with no transcript parsing, network, or writes. Enable or remove it any time with `cs -statusline enable|disable`; choose and order segments with `CS_STATUSLINE_SEGMENTS`. cs auto-detects the terminal's light/dark theme (override with `CS_TERM_THEME`; `cs -detect-theme` shows the result). See [docs/statusline.md](docs/statusline.md)

  ![cs-statusline: session and model accents, amber rate-limit warnings, standard-Unicode segment icons](assets/screenshot2.png)
- **Health checks** - `cs -doctor` reports status of Keychain backend, hook registration, shadow-ref freshness, auto-memory writability, status line registration, Claude Code settings audit (hooks/MCPs/permissions/env vars counts), and cumulative token usage for the current project
- **Bash command audit trail** - Every Bash command Claude runs is logged to `.cs/local/session.log` (machine-local, never git-synced) with timestamps
- **Update notifications** - Checks for updates and notifies when new versions are available
- **Verified updates** - Updates are downloaded from GitHub Releases and verified with SHA-256 checksums; additionally verified with [minisign](https://jedisct1.github.io/minisign/) signatures when available

## Installation

### Bash (macOS/Linux)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hex/claude-sessions/main/install.sh)"
```

Or clone and run `./install.sh`.

> :warning: Always review [install.sh](install.sh) before running scripts from the internet.

The installer:
- Adds `cs`, `cs-secrets`, `cs-statusline`, and `cs-tui` to `~/.local/bin/`
- Installs the cs [hooks](docs/hooks.md) to `~/.claude/hooks/cs/` for session tracking (including the `scope-prompt` auto-grounding hook on UserPromptSubmit)
- Adds `/summary`, `/checkpoint`, `/sweep`, and `/wrap` commands, and the `store-secret` and `prose-hygiene` skills to `~/.claude/`
- Installs shell completions for bash and zsh
- Configures hook entries in `~/.claude/settings.json`

## Usage

```bash
cs                          # Interactive session manager (TUI)
cs <session-name>           # Create or resume a session
cs <session-name> --force   # Override active session lock
cs <base>@<task>            # Create/resume a parallel task worktree off <base>
cs <base> --merge <task>    # Merge a task worktree back into <base>
cs -adopt <name>            # Adopt current directory as a session
cs -whoami                  # Show the current actor (for shared, multi-person sessions)
cs -who                     # Show who contributed to shared memory/narrative (git history)
cs -search <query>          # Search across all sessions
cs -checkpoint "<label>"    # Snapshot git state + narrative (also: list, show <name>)
cs -queue add "<task>"      # Walk-away task queue (also: list, rm <n>, clear)
cs -doctor, -diag           # Run health checks (Keychain, hooks, memory, audit, tokens)
cs -lint <file>...          # Flag AI-slop prose tells (em-dashes, banned phrases); 0 clean 1 issues 2 error
cs -statusline enable|disable  # Enable or remove the cs status line
cs -detect-theme            # Show the detected terminal light/dark theme
cs -list, -ls               # List all sessions
cs -remove, -rm <name>      # Remove a session
cs -update [--check|--force]   # Update to latest (--check: check only; --force: reinstall)
cs -uninstall               # Uninstall cs
cs -help, -h                # Show help message
cs -version, -v             # Show version
```

### Interactive Session Manager

Running `cs` with no arguments launches an interactive TUI for browsing and managing sessions:

- **Navigate** with `j`/`k` or arrow keys; `g`/`G` for first/last; mouse scroll and click supported
- **Sort** by column with `1`-`6` (toggles ascending/descending); opens sorted by recency — most-recently-modified first
- **Recency at a glance** — a heat dot beside each session (green when live, fading to grey when dormant) and a relative `Age` column (`2h`, `3d`, `1mo`) so active work stands out; the exact timestamp stays in the preview pane
- **Fuzzy search** with `/` — matches characters in order with highlighting; Enter commits the filter
- **Time-based sections** — sessions grouped under Today, Yesterday, This Week, This Month, Older when sorted by date (the default view)
- **Action bar** with `Enter` — inline bar shows available actions with shortcut keys
- **Preview & To-Do panes** — appear beside the list on wide terminals (>120 cols), or stacked below it (list, then details, then notes) when the window is taller than it is wide; toggle with `p`
- **Expand row** with `p` — shows session objective (auto-captured from your first prompt) and narrative inline
- **Create session** with `n` — opens inline dialog to create a new session
- **Delete** with `d` (confirmation required)
- **Batch operations** — mark sessions with `Space`, then `D` to batch delete
- **Rename** with `r`
- **Manage secrets** with `s` (view values with `v`, auto-redacts after 5 seconds)
- **Queue a task** — focus the To-Do input with `Tab`, type a prompt, and press `Enter` to add it to the highlighted session's queue for a walk-away run; a `▤ N` badge appears in the To-Do column while that session's queue is non-empty
- **Quit** with `q` or `Esc`
- **Light/dark palette** — the warm palette adapts to the terminal background detected at launch (`CS_TERM_THEME`); set the env var to force `light` or `dark`

The TUI requires `cs-tui` (a small standalone Rust binary). Build from source: `cd tui && cargo build --release`.

### Session Commands

```bash
cs <session> -secrets <cmd>   # Manage secrets for a session by name
cs <session> --force          # Override active session lock
```

From inside a running session, `cs -secrets <cmd>` acts on the current session directly (it reads `CLAUDE_SESSION_NAME`), so you can drop the session name.

### Examples

```bash
cs debug-api                # Create/resume 'debug-api' session
cs my-project -secrets list # List secrets for session
```

### Adopting Existing Projects

Already working in a project directory with Claude Code? Use `-adopt` to add cs session management without moving anything:

```bash
cd ~/my-project
cs -adopt my-project
```

This converts the current directory into a cs session in place:
- Creates the `.cs/` metadata structure in the current directory
- Symlinks `~/.claude-sessions/<name>` to the current directory
- Merges session protocol into existing `CLAUDE.md` if one exists
- Initializes a git repo if one doesn't exist (preserves existing repos)
- Since the working directory doesn't change, `claude --continue` picks up previous conversations

## Concepts

- **Sessions** — Isolated workspaces, each with their own git repo and documentation. `cs debug-api` creates one; running it again resumes it.
- **Narrative** (`.cs/memory/narrative.<actor>.md`) — A per-actor lab notebook for findings, observations, and ideas during a session. Each co-developer writes their own file (so shared sessions never conflict) and everyone reads all of them on resume. Stored as native Claude Code memory files; see [docs/session-layout.md](docs/session-layout.md) for how that works.
- **Checkpoints** (`.cs/checkpoints/`) — Labelled narrative snapshots you can save mid-session with `/checkpoint`, capturing the narrative, changes, and the current git HEAD.
- **Timeline** (`.cs/timeline.jsonl`) — A structured event log recording session starts, ends, and checkpoints as newline-delimited JSON.
- **Auto-memory** (`.cs/memory/`) — Claude Code's persistent operational notes, redirected into the session and cleaned up with `cs -rm`.

## Session Structure

```
~/.claude-sessions/<session-name>/
├── .cs/                    # Session metadata
│   ├── README.md           # Objective, environment, outcome
│   ├── memory/             # Claude Code auto memory + per-actor narrative.<actor>.md lab notebooks
│   ├── plans/              # Claude Code plans
│   ├── timeline.jsonl      # Session event log (starts, ends, checkpoints)
│   ├── checkpoints/        # Labelled narrative snapshots (/checkpoint)
│   └── local/              # Machine-local state + session.log audit trail (gitignored)
├── .claude/
│   └── settings.local.json # Redirects auto memory into .cs/memory
├── CLAUDE.md               # Session instructions for Claude
└── [your project files]    # Clean workspace
```

Claude Code's [auto memory](https://code.claude.com/docs/en/memory) is redirected into `.cs/memory/` via the `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` env var (set at launch). This means auto memory is cleaned up with `cs -rm`.

## Advanced

### Sharing a session between machines

Sessions are designed to be shared through git (push/pull the whole session directory). Everything cs writes automatically is partitioned so independent work on two clones merges cleanly:

- **Machine-local state never syncs.** The Claude conversation UUID, session color, and resume timestamps (in `.cs/local/state`) and the `session.log` command audit trail live under gitignored `.cs/local/` — each machine binds its own conversation and keeps its own log. A launch guard refuses to run if `.cs/local/` ever becomes tracked.
- **Append-only files union-merge.** `timeline.jsonl` and the per-actor `narrative.*.md` notebooks carry `merge=union` in the session `.gitattributes`, so divergent appends interleave instead of conflicting.
- **`MEMORY.md` resolves to the local copy** (`merge=ours`); each actor's pointer line is re-added idempotently on the next launch.
- **Secrets sync per machine.** `cs -secrets export-file` writes `.cs/secrets.<machine-id>.age/.enc` — distinct files per machine instead of one shared encrypted blob whose bytes change every export — and `import-file` merges every sync file it can decrypt. See [docs/secrets.md](docs/secrets.md).
- **What can still conflict is real content**: the README objective/outcome, memory entries, and your project files — places where two humans genuinely disagree and should reconcile by hand.

One caveat: the custom `merge=ours` driver is per-clone git config, installed by every `cs <name>` launch. If you pull on a brand-new clone *before* ever launching the session through cs, `MEMORY.md` falls back to an ordinary text merge.

### Parallel task worktrees

Work two tasks on one session at the same time, each in its own Claude
conversation:

    cs myproj@fix-auth     # creates a git worktree of myproj on branch cs/fix-auth
    cs myproj@perf         # a second, independent working copy

You don't have to remember the syntax: typing `cs myproj` while that session
is already open offers to start a parallel task from right there (or force a
second launch, or cancel). A worktree session also knows what it is: Claude
is told at launch that it runs in a task worktree and that
`cs myproj --merge <task>` is the way back, so it won't merge the branch by
hand.

Each worktree is a full cs session (own conversation, color, crash
recovery) that shares the base session's task list and secrets. Session
records fork with the branch and re-fuse at merge:

    cs myproj --merge fix-auth   # merge cs/fix-auth, fuse records, remove worktree

cs never commits for you: merge refuses dirty checkouts and tells you what
to commit, and creating a task from a base with uncommitted changes asks
before branching from the last commit (interactive sessions) or refuses
(scripts). Abandon a task with `cs -rm myproj@fix-auth`. Repos that
gitignore `.cs/` get a per-worktree `.cs/` whose records are fused explicitly
at merge. Requires git >= 2.20.

### Task queue

Queue up prompts and step away — cs drains them on its own at turn
boundaries, once you've confirmed:

```bash
cs -queue add "refactor the parser"   # add a task (or: cs <session> -queue add "..." from another terminal)
cs -queue                             # or `cs -queue list` — show pending + completed tasks
cs -queue rm 2                        # remove pending task 2
cs -queue clear                       # empty the queue and stop draining
```

When you finish a turn with tasks queued, the Stop hook asks once (via
`AskUserQuestion`) whether to work through them — showing the current
context % and, at 60% or above, offering to compact first. Choosing "Start"
drains every task in order (FIFO, top to bottom) at each stop boundary with
no further prompts until the queue is empty; "Not yet" waits and re-asks
after about 10 minutes, or as soon as the queue changes. There's no
mid-drain pause — once started it runs to the end, trusting Claude Code's
own auto-compact. As it drains, cs instructs Claude to mirror the queue
into the native task list so progress stays visible. (The gate itself
runs `cs -queue start` / `cs -queue defer` on your behalf — you don't
need to run those directly.)

In the session picker (`cs` with no argument), the right pane shows a
**To-Do** panel for the highlighted session: press `Tab` to focus its
input, type a task and press `Enter` to queue it; `Down` moves into the
list where `d` deletes and `e` edits a task in place, and `Esc` returns
to the session list. Sessions with queued tasks get a sortable **To-Do**
column (`▤ N`) in the table, and the status line shows `▤ N` after the
session name.

## Slash Commands

- `/wrap` — The canonical end-of-session command: runs the `/sweep` memory pass, then the `/summary` narrative, then the prose gate
- `/sweep` — Distill the session into durable auto-memory entries (strict bar) and sweep findings into the narrative
- `/summary` — Generate a narrative summary of the current session
- `/checkpoint <label>` — Save a labelled state snapshot (narrative, changes, git HEAD)

## Shell Completion

Tab completion for session names and commands is installed automatically. To enable it:

**Bash** - Add to `~/.bashrc`:
```bash
[[ -f ~/.bash_completion.d/cs.bash ]] && source ~/.bash_completion.d/cs.bash
```

**Zsh** - Add to `~/.zshrc` (before `compinit`):
```bash
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Then restart your shell or run `source ~/.bashrc` / `source ~/.zshrc`.

Completions support:
- Everything at once: `cs <TAB>` → every session name plus the global flags
- Session names: `cs home<TAB>` → `cs homeassistant`, including sessions adopted by symlink from elsewhere on disk
- Global flags: `cs -<TAB>` → `-list`, `-secrets`, etc.
- Secrets commands: `cs session -secrets <TAB>` → `set`, `get`, `list`, etc.

Session names come from `cs` itself, so tab completion always matches what `cs -list` shows.

## Configuration

cs runs with sensible defaults and needs no configuration. The one you're most likely to set is the sessions directory:

```bash
export CS_SESSIONS_ROOT="/path/to/sessions"   # default: ~/.claude-sessions
```

For the full list — secrets backend, theme detection, status-line segments, Nerd Font icons, and the variables cs sets for you at launch — see [docs/configuration.md](docs/configuration.md).

## Documentation

- **[Configuration](docs/configuration.md)** - Every environment variable cs reads and the ones it sets for you
- **[Session layout](docs/session-layout.md)** - The `.cs/` directory schema: shared vs machine-local files and merge policy
- **[Hooks](docs/hooks.md)** - How the Claude Code hooks work
- **[Secrets](docs/secrets.md)** - Secure secrets handling and storage backends
- **[Statusline](docs/statusline.md)** - The cs status line: segments, colors, configuration

## Obsidian Integration

Open `~/.claude-sessions/` (or your `CS_SESSIONS_ROOT`) as an [Obsidian](https://obsidian.md) vault for a visual dashboard over all sessions.

**What works out of the box:**
- Full-text search across all sessions
- Graph view showing session connections via standard markdown links
- `index.md` at the vault root listing all sessions (auto-generated on session end)
- YAML frontmatter in each session's `.cs/README.md` with `status`, `created`, `tags`, and `aliases` (machine-local values like the Claude session UUID live in gitignored `.cs/local/state`, so shared sessions never merge-conflict on automated writes)

**Recommended plugins:**
- **[Dataview](https://github.com/blacksmithgu/obsidian-dataview)** - Query sessions by frontmatter (status, tags, dates)
- **[Projects](https://github.com/marcusolsson/obsidian-projects)** - Kanban/calendar views over session frontmatter
- **[Juggl](https://github.com/HEmile/juggl)** - Graph views from YAML relationships (no wikilinks needed)

**Example Dataview queries** (paste into any note):

Active sessions sorted by last activity (file mtime — activity dates are no
longer stored in frontmatter, they are machine-local):
````markdown
```dataview
TABLE status, tags, file.mtime AS "last activity"
FROM "."
WHERE file.name = "README" AND status = "active"
SORT file.mtime DESC
```
````

Stale sessions (not touched in 7+ days):
````markdown
```dataview
LIST
FROM "."
WHERE file.name = "README" AND status = "active"
  AND file.mtime <= date(today) - dur(7 days)
```
````

**Graph view tip:** In Obsidian's graph settings, add `.cs/local` to the folder exclusion filter to reduce clutter.

## Requirements

- [Claude Code](https://github.com/anthropics/claude-code)
- Bash 3.2+ (macOS system bash supported)
- `jq` for hook configuration
- `git` for local session history and crash recovery

## Uninstalling

```bash
cs -uninstall
```

## See also

- [iTerm2-dimmer](https://github.com/hex/iTerm2-dimmer) -- dims noisy hook output (TASKMASTER, prose-lint) in iTerm2 so it doesn't clutter the screen

## License

MIT

## Contributing

Contributions welcome! Please open an issue or PR.
