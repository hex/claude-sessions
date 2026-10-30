# Commands

Run `cs -h` for help and `cs -v` for the version.
Aliases include `-help`, `-version`, `-ls`, `-diag`, and `-remove`.

## Command reference

| Command | Purpose |
|---|---|
| `cs -- <name>` | Ends option parsing before creating or resuming a session. |
| `cs -tui` | Opens the picker from any directory. |
| `cs -list [--tag <tag>] [--archived]` | Lists sessions, filters a tag, or lists only archived sessions. |
| `cs -search <query> [--include-archived]` | Searches session narratives, memory, and README files. |
| `cs -whoami`, `cs -who` | Shows your actor name or contributors from git history. |
| `cs -checkpoint "<label>"` | Saves narrative, changes, and the current git revision. Use `list` or `show <name>` to inspect snapshots. |
| `cs -narrative rotate` | Archives the oldest narrative sections past the size budget. `cs <name> -narrative rotate` targets a named session. |
| `cs -queue add "<task>"` | Adds a task. Other actions are `accept <id>`, `list`, `start [subagents\|workflow]`, `rm <n>`, `clear`, and `log`. |
| `cs -msg <session> "note"` | Sends mail. Bare `cs -msg` reads unread mail. Use `log`, `thread <id>`, or `--reply <thread> "note"` for history and replies. |
| `cs -spawn <name> [--brief <file>] [--task "..."]` | Opens a cs tmux window with a first-turn brief or an armed task queue. Attach with `tmux attach -t cs`. A feature's brief (`<base>@<task>`) carries `## Goal`, `## Done when`, `## Constraints`, `## Context`, `## Review` and `## Report back`, each heading on its own line; one missing refuses the spawn and is named. |
| `cs -conversations` | Shows the conversation chain. `cs <name> -conversations` targets another session. |
| `cs -tag add\|rm <tag>` | Edits README frontmatter tags. Use `-tag list` or `cs <name> -tag ...` to inspect or target another session. |
| `cs -archive <name>...`, `cs -unarchive <name>...` | Hides or restores sessions. Opening an archived session restores it. |
| `cs -live` | Lists local live sessions with actor, uptime, agent state, and status. |
| `cs -status "<text>"` | Sets advertised status. Bare `-status` reads it. `--clear` restores the `Objective` fallback. |
| `cs -usage [--all] [<name>]` | Reports session token usage over the 5-hour and weekly windows. |
| `cs -doctor` | Checks installation, session state, recovery, settings, and sources of model context. |
| `cs -vet-session <dir>` | Exits 0 if git tracks no `.cs/local` or `.cs/private` files. Otherwise names the files and how to untrack them. |
| `cs -encrypt <name>` | Moves a closed session's private files into a vault on macOS. Asks for a password at each open. |
| `cs -statusline enable\|disable` | Registers or removes the statusline and agent rows. Restart Claude Code after enabling. |
| `cs -statusline caps on\|off\|ask` | Records whether your font displays rounded capsule ends. |
| `cs -detect-theme` | Reports terminal theme detection. |
| `cs -rm <name>...` | Confirms each removal and names user files, including untracked worktree files. |
| `cs -update [--check\|--force]` | Updates cs after SSH verification of `SHA256SUMS` and the installer's digest. `--check` checks without installing, and `--force` reinstalls the latest release with the same verification. |

Updates require `ssh-keygen -Y verify` and refuse missing signatures, missing
manifest entries, digest mismatches, and releases that drop revoked keys.
See [release verification](configuration.md#release-verification-and-notes).

A launch on a terminal that finds a newer release asks once, before the
session opens: `cs X.Y.Z is available (you have A.B.C). Update now? [y/N]`.
`y` runs `cs -update` and then starts the same launch again on the new cs; an
update that does not finish is a warning and the launch goes on. Any other key
records that version in `~/.cache/cs/update-declined`: the launch does not ask
about it again, and in the session the
[update mod](hooks.md#cs-update-not-a-hook-script--a-claude-code-mod) says in
one line that it is available and to run `cs -update`, instead of opening its
pane (`/cs-update` still opens the notes). The launch banner still names it. A
newer release is asked about afresh. Off a terminal nothing is asked.

## Sessions, locks, and safety

### Open and resume

- `cs <name>` creates or resumes a session. Names such as `cs homeassistant`, `cs router-config`, and `cs research-llms` work for home automation, network setup, and research.
- `cs .` requires the exact root of a known session, adopted project, or feature worktree. It refuses subdirectories and unrelated directories with adoption guidance.
- cs resumes the [recorded conversation](session-layout.md#machine-local-files-cslocal-gitignored) with `claude --resume`, rather than `--continue`. Launches pass `--name` and a per-session `/color`.
- The duplicate-conversation guard recognizes identifiers after `--session-id`, `--resume`, `-r`, and `--parent-session-id`. A leftover shell child carrying the identifier does not block a launch. `--force` overrides that guard and the ordinary process lock.
- See [session commit rules](hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) for the initial commit and [autosave](hooks.md#autosave-commitssh-posttooluse-on-writeedit) for later crash recovery.
- See [session resolution](hooks.md#how-a-hook-finds-its-session-cs-resolvesh) for desktop and IDE hooks, their contribution without rebinding the launched conversation, and the plain-terminal `claude` exception.
- A newer conversation opened outside cs produces a launch warning with its identifier and `claude --resume <identifier>`.

### Liveness and removal

- A running lock process or a statusline heartbeat under 900 seconds old makes a session live. Presence is local, includes conversations opened outside cs, and uses no network presence service.
- Destructive guards use the process lock. A heartbeat alone does not block removal.
- From inside a session, `--force` cannot remove or archive another live session, except the base's own features. It also cannot target a base with a live feature unless run from that base.
- Force with user files requires `--delete-files`.
- Removing a base also removes its age pins in `~/.cs-secrets/sessions/<name>/`. Removing a feature or adopted link keeps them.
- [Remote-server protection](session-layout.md#machine-local-files-cslocal-gitignored) blocks opening and removal, including forced removal, until the server stops.
- See [encrypted-session safeguards](session-layout.md#encrypted-sessions) for mounted-vault removal refusal and finish/uninstall protection.
- Archived sessions stay out of normal listing and search. [The archive marker](session-layout.md#shared-files) carries that state through git.
- Named narrative rotation refuses another live session except a base's own features. `--force` does not bypass that guard.
- See [secrets commands and live-session write restrictions](secrets.md) for `cs my-project -secrets list`, backend selection, and the write guards that `--force` cannot bypass.

## Usage and health

### Token usage

| Reading | Meaning |
|---|---|
| Input and output | Sums tokens after deduplicating API requests, excluding cache reads. |
| Nested work | Includes subagent and workflow transcripts at every depth. |
| Model | Describes the parent conversation. |
| Named session | Adds per-conversation and lifetime totals. |
| Windows | Uses the [statusline's reset stamps](statusline.md#data-sources-and-performance) for reset boundaries. |

| `READS>350L` detail | Meaning |
|---|---|
| Count | Untargeted/all Read results over 350 lines. |
| Token estimate | Untargeted characters divided by four. |
| Targeted read | The Read call explicitly supplied an offset or limit. |
| Harness truncation | Does not make a read targeted. |
| Record shapes | Counts both file records and inline subagent results. |
| Shell reads | Does not count `cat` or `head`. |

### Agent state

- `busy`, `waiting`, and `idle` come from `~/.claude/sessions/`.
- cs trusts a state only while its process identifier and start time still match.
- Hosts before Claude Code 2.1.224, or the shell reader without jq, show no state.

### Health checks

| Doctor area | Checks |
|---|---|
| Installation | Secrets backend, hooks, and statusline registration. |
| Session | Shadow refs, memory writability, project tokens, and migration stamp. |
| Claude Code | Settings counts and cs/cs-update runtime markers. |
| Authority | Context-injecting hooks and their opt-outs. |
| Checkout picker | Rust/Cargo input timestamps and installed bytes against the checkout build, from any directory. Release downloads skip this build check. |

- Build the picker with `cd tui && cargo build --release`.
- Installation takes the newer of `tui/target/release/cs-tui` and `bin/cs-tui`.
- See [installation records](configuration.md#installation-updates-and-settings) for the picker's recorded origin.

## Adopt an existing project

| Command | Result |
|---|---|
| `cs -adopt my-project` | Adopts the current project without moving it, adds `.cs/`, and links it into the sessions root. |
| `cs -adopt my-project --yes` | Confirms reuse of orphaned `.cs/` records without asking. `-y` is an alias. |
| `cs -adopt --worktrees` | Registers this repository's `.claude/worktrees/*` with conversations as `<repo>.<worktree>`. |
| `cs -adopt --worktrees --dry-run` | Prints the plan without writing. |

- Adoption preserves an existing git index. Without git, it initializes branch `main`.
- See [session protocol and pending files](session-layout.md#shared-files) for gitignored `CLAUDE.local.md`, the untouched user `CLAUDE.md`, adoption's no-commit rule, and the pending `.cs/`, `.gitignore`, and `.gitattributes` changes.
- Before creating features, check the [recorded tracked/ignored mode](session-layout.md#machine-local-files-cslocal-gitignored), its commit prerequisite, and `.git/info/exclude` handling.
- Before writing, adoption refuses outward symlinks at `.gitignore`, `.gitattributes`, or `CLAUDE.local.md`. It also refuses [tracked control files](session-layout.md#machine-local-files-cslocal-gitignored).
- Orphaned `.cs/` records need confirmation. Without a terminal or `--yes`, adoption refuses them.
- Adoption offers the newest native conversation in the unchanged directory, or starts fresh when none exists.
- It seeds `Objective` from the first eligible prompt, skips slash commands and prompts under eight characters, and clips at 100 characters. Without a conversation it leaves the placeholder.
- Worktree adoption retains each conversation and `Objective`, hides cs files through local exclusions, commits nothing, and leaves tracked `CLAUDE.md` alone.
- It skips missing conversations, tracked `CLAUDE.local.md` or `.claude/settings.local.json`, non-worktrees, and repository layouts with `HEAD` before `.git`.
- Reruns finish partial adoptions, add new worktrees, and prune deleted links.

## Parallel worktrees

| Command | Result |
|---|---|
| `cs myproj@fix-auth` | Creates a feature on branch `cs/fix-auth`, from the base's current commit. An existing `cs/fix-auth` is reused from its own tip, and the launch says how far behind the base that is. A detached base is refused: the feature would have no branch to land on. |
| `cs myproj@perf` | Opens another independent feature. |
| `cs <base> -features` | Lists feature readiness. |
| `cs <base> -finish <feature>` | Opens the base with `/finish <feature>`. |
| `cs -rm myproj@fix-auth` | Abandons the feature. |

- An already-open base offers existing features, a new feature, a forced launch, the picker, or cancellation.
- Each feature has its own conversation, color, task list, and recovery refs, and shares the base's secrets.
- The base needs a commit. See [tracked-mode prerequisites](session-layout.md#machine-local-files-cslocal-gitignored) before creating a feature.
- A dirty base asks before branching from its last commit, or refuses without a terminal.
- With ignored `.cs/`, the feature inherits memory topics, `MEMORY.md`, plans, and summary, but not narratives, local state, or timeline.
- [`/feature <name>`](../skills/feature/SKILL.md) writes a brief and runs `cs -spawn <base>@<name> --brief <file>`. The feature reads `.cs/brief.md` first, while the base keeps working and receives the result by mail. The model may invoke it, and the spawn permission prompt remains.
- Only the user invokes [`/finish <feature>`](../skills/finish/SKILL.md).

### Integration and gates

- Finish captures the feature commit, merges in a detached temporary worktree, fast-forwards the base, and reports any GitHub pull request.
- Ordinary feature branches use a merge with `--no-ff`.
- Finish runs no gate unless requested with `--gate`.
- It reports `gate skipped` only for an already-merged pull request with passing recorded merge checks and no extra base commits.
- A clean gate checkout lacks ignored dependencies, environment files, and build output. A gate needing them must install them, for example `-- sh -c 'npm ci && npm test'`.
- See [merge policy](session-layout.md#merge-policy) for record fusion, preserving the base's memory index, and `.cs/features/<task>/` outcomes.

### Retirement

- Finish can land work while the feature conversation runs. Retirement then waits for it to close: the retire entry writes `.cs/local/retire-staged/<task>` in the base (the captured commit and whether `--force` applied) and answers `staged <task> <sha>: ...`. When that conversation ends, its SessionEnd mails the base, and the base's Stop hook starts the entry detached (`--staged`, the stage standing in for the base's own ancestry), waits up to six seconds for it, and reports `retired` or the refusal in the turn that finds it ended. The entry re-reads the feature's lock under its openers' mutex right before the removal, so a conversation reopened meanwhile stages the retire again instead of losing its directory. `cs <base> -features` reads `staged` for it. No keystroke or signal closes the other session; the user does, when they are done there.
- Retirement commits nothing and refuses dirty or untracked work.
- Recreated build directories such as `node_modules`, `target`, and `.venv` go with the checkout.
- Other ignored files go to system trash, with each file or whole-directory count listed.
- Retirement refuses if neither `trash` on macOS nor `gio trash` on Linux can preserve those files. Special files can also block retirement.

## Task queue and mail

| Action | Command |
|---|---|
| List pending and completed tasks | `cs -queue` or `cs -queue list` |
| Remove a pending task | `cs -queue rm <n>` |
| Empty the queue and stop draining | `cs -queue clear` |
| Add from outside a session | `cs <session> -queue add "..."` |
| Accept task mail from another session | `cs -queue accept <id>` |
| Start without the cs mod | `cs -queue start [subagents\|workflow]` |
| Show the run journal | `cs -queue log` |

- Adding from another session sends task mail requiring acceptance.
- See [queue controls](hooks.md#cs-not-a-hook-script--a-claude-code-mod) for mid-turn `/queue`, Start/Not yet/Compact, and conversation/subagent/workflow execution. Choosing workflows authorizes that tool.
- `/cs next|prev|first|last|<n>` scrolls the transcript along the band's rail of prompts (one tick per prompt the person sent), mid-turn too; see [the rail](hooks.md#cs-not-a-hook-script--a-claude-code-mod).
- See [queue drain and breakers](hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) for listed-order turn boundaries, native-task mirroring, the default five-failure/85%-context/85%-quota limits, rearming, and the return digest.
- Mail uses `--kind notify|task|text|result`. Task mail enters the queue only after acceptance.
- Bodies are at most 65,536 bytes. A lone `-` reads stdin.
- Unread bodies repeat in prompt context until read, at most five and truncated. This is same-machine mail without authenticated sender attribution.
- Each message has a thread and a sender copy. Replies infer the peer and reject a conflicting named target. Thread views order by reply relationships rather than timestamps.
- See [message files and spawn staging](session-layout.md) for atomic delivery, the spawned-window-only seed exception, and confirmation on other opens within an hour.
- See [completion notifications](hooks.md#narrative-remindersh-stop-filechanged-cwdchanged) for mail after a spawned session's queue drains, and [mail wake settings](configuration.md) for wake limits.

## Conversation rotation and wrap

- Invoke `/rotate`, then `/clear` to continue from the handoff.
- See [rotation controls](hooks.md#cs-not-a-hook-script--a-claude-code-mod) for automatic wake, context thresholds, Ctrl+X actions, wrap confirmation, and the forced-rotation countdown.

| Launch answer | Result |
|---|---|
| `y` or Enter | Resumes the recorded conversation. |
| `r` | Starts from the handoff. |
| `n` | Starts fresh. |
| `d` | Discards the handoff, then resumes. |

- Resume and fresh disarm the marker with a notice but leave the handoff pending.
- The launch card and plain resume prompt show recorded context when the statusline supplies it.
- Cross-checkout handoffs carry a label and remain usable. Choosing one consumes it under the successor's identifier.
- Names must contain only letters, digits, `._@-`, and at most 160 characters. cs skips invalid names with a notice.
- A valid armed marker wins. Otherwise, the last unconsumed basename in lexical order wins.
- The rotate skill supersedes its own earlier pending handoffs.
- See [handoff records](session-layout.md#shared-files) for lineage, encrypted storage, and pruning after 30 days while retaining the newest ten. The [SessionStart hook](hooks.md#session-startsh-sessionstart) documents clean/tracked pruning safeguards and marker survival across compaction or a context-limit fork.
- Handoffs redact credentials, identifying data, and sensitive personal detail. They put blockers first, reference committed work by path, and keep the user's words while condensing agent reasoning.
- `cs -conversations` folds starts with resume counts and marks the current conversation. [Rotation events](session-layout.md#shared-files) name old/new identifiers and a reason, `handoff`, `declined-resume`, `resume-failed`, or `rebind`.
- `/wrap` saves durable memory, sweeps findings into the narrative, writes the summary, rotates the narrative, and archives completed tasks with consent. It commits nothing.
- The wrap pass moves pointers for finished subjects or enforced rules to the memory archive before rewording. It keeps entries while adding tasks for checks that could enforce them.
- `/checkpoint <label>` saves a snapshot mid-session.
- See [memory checks](hooks.md#memory-index-guardsh-not-a-hook--run-by-wraps-memory-pass), [summary and task archives](session-layout.md#shared-files), and [narrative budgets](configuration.md).

## Remote control

| Command | Purpose |
|---|---|
| `cs <name> --remote [--permission-mode <mode>]` | Serves the session through `claude remote-control --name <name>` for the Claude app or claude.ai/code. |

- Requires Claude Code 2.1.299+ and a full login. cs clears `ANTHROPIC_API_KEY`.
- App and web children use the session's hooks, memory, tasks, and secrets.
- cs checks that the first word of `CLAUDE_CODE_BIN` identifies Claude Code.
- Explicit permission mode wins. Otherwise, cs carries the configured mode, maps `--dangerously-skip-permissions` to `bypassPermissions`, or uses `default`.
- cs drops `--allow-dangerously-skip-permissions` with a notice. It refuses other options and wrappers such as `op run -- claude` by name.
- Inside tmux, the server gets `remote:<name>` in the cs tmux session and preserves the invoking root and Claude command. Otherwise it uses the current terminal.
- First-run trust questions require a terminal. `--spawn=same-dir` keeps child sessions in this directory. An encrypted session has its own config trust prompt.
- The first child leads, simultaneous children remain guests, and a later child becomes lead after the lead exits.
- Children keep the remote window or `cs: <name> (remote)` tab title. A staged spawn seed waits for the next ordinary open.
- Stop with Ctrl+C or close the window. A forced kill can leave a child running. Restart can reattach the old cloud session with its old title.
- See [remote state](session-layout.md#machine-local-files-cslocal-gitignored) for live listings, doctor reporting and stale-marker cleanup, and protection against opening or removing a served session.

## Shell completion

1. For Bash, add this to `~/.bashrc`:

   ```bash
   [[ -f ~/.bash_completion.d/cs.bash ]] && source ~/.bash_completion.d/cs.bash
   ```

2. For Zsh, add this before `compinit` in `~/.zshrc`:

   ```bash
   fpath=(~/.zsh/completions $fpath)
   autoload -Uz compinit && compinit
   ```

3. Restart the shell or source its configuration.

| Input | Completion |
|---|---|
| `cs <TAB>` | Sessions and global flags. |
| `cs home<TAB>` | A matching session name. |
| `cs -<TAB>` | Global flags. |
| `cs session -secrets <TAB>` | Secrets actions. |

Names come from cs and include adopted symlink sessions, matching `cs -list`.
