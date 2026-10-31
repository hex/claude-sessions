# Session layout (`.cs/`)

Every cs session is a directory under `~/.claude-sessions/` (override with
`CS_SESSIONS_ROOT`). The directory itself is the workspace — Claude works on
project files there. All session *metadata* lives in a single `.cs/`
subdirectory, and the whole session directory is its own local git repo.

`.cs/` is kept at mode `0700` — set when the session is created and re-applied on
every open, which covers sessions predating the rule and fresh clones (git records
no directory modes, so a clone recreates `.cs/` under the local umask). Reaching a
file inside needs execute on the directory, so one private `.cs/` covers everything
under it. A session root cs created is `0700` too; an **adopted** session's root is
not, because that directory is the user's own project and its mode is theirs to
choose.

`.spawn/` at the sessions root stages `<name>.seed` files written by
`cs -spawn`: line 1 is a random token, line 2 the spawner, then one line
per `--task` item. A `--brief <file>` rides in the same file: a line
`--- cs-spawn-brief ---` ends the tasks and the brief follows it verbatim.
A brief alone still writes a seed, since the seed carries the spawner.
`cs -spawn` writes the seed under its own `.<name>.seed.XXXXXX` name and
publishes it with one `ln`, which refuses an existing name, so two spawns
of one name never both publish. A spawn killed before that leaves only its
staging file, which no launch reads; `cs -rm`, the picker's delete and
`cs -doctor` see it. The tmux window `cs -spawn` opens carries the same
token in `CS_SPAWN_TOKEN`, and that window is the only open that consumes
a fresh seed unasked (tasks queued and armed behind `.cs/private` in an
encrypted session, `.cs/local` otherwise; the brief written to the
session's `.cs/brief.md`; kick prompt). Any other open of the name shows
the seed as data, the brief by its size, and asks `[Y/n]`: `n` or Escape
sets it aside, no terminal leaves it staged. An open renames the seed to
`.<name>.seed.claim.<pid>` before reading it, so a seed published while it
asks is never the one it reads, sets aside or deletes; an open that stops
before consuming it puts it back under `<name>.seed` (or sets it aside as
`.stale` when a newer seed holds that name). An open killed outright leaves
its claim, which `cs -doctor` names once the pid is gone and `cs -rm` and
the picker's delete remove. The launch sets a seed older than an hour aside
whole as `<name>.seed.stale` and never applies it silently.

`.usage/` at the sessions root holds `fable.<account>.json`, its `fable.<account>.json.fields` file (the fields the status line reads, one per line, written by the refresher), the machine-global cache
behind the statusline's [fable segment](statusline.md#fable-usage), plus the
`.lock` directory that serialises refreshers. It sits at the root rather than in
any one session because the rate-limit budget it draws on belongs to the
account, not the session: every cs session on the host must poll through one
file. Machine-local and disposable — deleting it costs one refresh.

The one distinction that governs everything below is **shared vs machine-local**:

- **Shared** — committed to the session's git repo. When a session is cloned or
  synced to another machine (or shared with a co-developer), these travel with
  it. Append-heavy shared files use a git merge policy (see below) so concurrent
  writers don't conflict.
- **Machine-local** — everything under `.cs/local/`, which is gitignored. This is
  per-checkout state that must *not* sync: another machine has its own copy and
  merging them would be wrong.

## Markdown notes

- The sessions root contains Markdown notes for tools such as [Obsidian](https://obsidian.md).
- Session README frontmatter contains `status`, `created`, `tags`, and `aliases`. Conversation identifiers and activity belong to [machine-local files](#machine-local-files-cslocal-gitignored).
- The [SessionEnd hook](hooks.md#session-endsh-sessionend) regenerates the sessions root's `index.md` when a session ends.

## Shared files

| Path | Purpose | Merge |
|------|---------|-------|
| `.cs/README.md` | Session objective (captured from the first prompt) and outcome. Human-edited. An [encrypted session](#encrypted-sessions) keeps only the frontmatter here. | default |
| `.cs/summary.md` | Distilled session summary, written by `/wrap`. | default |
| `.cs/features/<task>/` | A retired feature's own `README.md` and `summary.md`, carried from its worktree by `/finish` in a session whose `.gitignore` lists `.cs`, when the feature changed them. A later feature of the same name keeps what an earlier one left and takes the next free name (`README.2.md`, `summary.2.md`). | default |
| `.cs/timeline.jsonl` | Structured event log — `started`, `ended`, `checkpoint`, `rotated`, and `narrative_rotated` events as newline-delimited JSON. A base session also records `worktree-retired` (with the feature's `task`) when a feature worktree is retired, and `feature-integrated` (with `task`, the integrated `sha` and a `result`) when `/finish` integrates one. | `union` |
| `.cs/memory/MEMORY.md` | Index of Claude Code's native auto-memory (one line per fact). | `ours` |
| `.cs/memory/reference_memory_archive.md` | Pointer lines `/wrap`'s memory pass moved out of `MEMORY.md`, in its shape, under a fixed frontmatter; a `reference_` entry `MEMORY.md` points to. The entries stay in `.cs/memory/`. | `union` |
| `.cs/memory/<bucket>_*.md` | Native auto-memory fact files (user, feedback, project, reference). Written by the harness. Shared by every actor on the session, unlike the narratives below, so a `user`/`feedback` entry may describe someone other than the person present — write facts about a person keyed to that person, never as a claim about whoever is here. | default |
| `.cs/memory/narrative.<actor>.md` | Per-actor lab notebook. Each co-developer writes their own file, reads it in full on resume, and reads a teammate's file only from the line the resume digest names; append-only. | `union` |
| `.cs/narrative-archive/<actor>/<through-date>-<blob8>.md` | Sections `cs -narrative rotate` moved out of the live narrative, verbatim. Immutable once written; the name is derived from the content, so two machines archiving the same sections produce the same file. | default |
| `.cs/task-archive/<date>/<actor>/<list>/` | Completed native task rows moved out of Claude Code's task store (`~/.claude/tasks/<list>/`) by `cs -archive-tasks run`, which `/rotate` and `/wrap` drive once the session has agreed: `json/<id>.json` holds each row byte for byte, and `tasks.md` gains a readable snapshot of the whole list per run. One directory per actor (the slug narratives use), since every machine numbers its copy of a list from 1, and under it one per task list, named as Claude Code names the store (a feature's `base@task` list is `base-task`), since every list numbers from 1 too: a feature and its base on one machine never write the same paths, so `/finish` carries the feature's archive into the base beside the base's own. The highest-numbered row always stays in the store: Claude Code numbers a new task one past the larger of the highest id in the store and its `.highwatermark`, which it raises only when it deletes a row, resets the list, writes a row under a given id or skips an id, never when a row file leaves the store another way. A run copies every row before it removes any, so one that stops part way has moved nothing, and the next run finishes it without a second snapshot. An archived row is never overwritten, and the archive never keeps a copy of a row that is still live: such a copy refuses the run, naming the row and what to do. cs leaves a task store untouched and says why when it is a link, holds anything but `<id>.json` rows, `.lock` and `.highwatermark`, or holds a row Claude Code's own task schema rejects, and it writes nothing while a link anywhere under the archive leads out of the session. An [encrypted session](#encrypted-sessions) keeps the archive in `.cs/private/task-archive/` instead. | default |
| `.cs/checkpoints/` | Labelled state snapshots from `/checkpoint` (narrative + changes + git HEAD). | default |
| `.cs/archived` | Archive marker written by `cs -archive` (date + actor). Tracked so the archived state syncs; removed on open or `cs -unarchive`. | default |
| `.cs/handoffs/` | Lineage-stamped conversation handoffs written by the `rotate` skill (parent UUID, purpose, continuation plan). Each carries a `status:` field — `unconsumed` while pending, flipped to `consumed` by the SessionStart that rotates into it, to `discarded` by the resume prompt's `d` answer, or to `superseded` when a later rotation retires it. The `rotate` skill also prunes as it goes, deleting `consumed`, `discarded` and `superseded` files older than 30 days by `created:` unless they are among the 10 newest — instructions the skill follows, not a cs command; nothing in cs itself deletes a handoff. Git history retains the removed files. An [encrypted session](#encrypted-sessions) keeps them in `.cs/private/handoffs/` instead. | default |
| `.cs/plans/` | Design plans and specs kept with the session. | default |
| `.cs/brief.md` | The brief a `cs -spawn --brief` (or the `feature` skill) handed this session, written at launch from the seed; the wake-up line sends the session to it first. Written once per spawn, replacing an earlier one. A feature's brief carries the six sections `cs -spawn` requires (Goal, Done when, Constraints, Context, Review, Report back). | default |
| `.cs/age-recipients/*.pub` | Public keys (`ssh-ed25519`, or `age1...` from before the ssh keys) of the machines allowed to decrypt the session's synced secrets, and whose signed sync files an import takes. A machine encrypts only to the keys it pinned in `~/.cs-secrets/sessions/<session>/age-trusted`, outside the checkout (see [docs/secrets.md](secrets.md)). | default |
| `.cs/secrets.<machine-id>.age` | Per-machine encrypted secret sync file ([age](https://github.com/FiloSottile/age); preferred). Each machine writes its own so exports never collide. | default |
| `.cs/secrets.<machine-id>.age.sig` | That machine's signature over its age sync file. An import takes an age file only when a key you pinned signed it. | default |
| `.cs/secrets.<machine-id>.enc` | Per-machine encrypted secret sync file (OpenSSL + password; legacy). | default |

`<machine-id>` is `${USER}@<short-hostname>` — the same id that names age
recipients. See [secrets.md](secrets.md) for the sync model.

`.cs/session.lock` is a PID-based lock written at the session root (not under
`local/`). It is ephemeral and machine-specific; it exists only while a session
is open and is cleaned up on exit. cs keeps it a regular file: an open refuses a
link, a directory or anything else in its place, naming it, and the exit never
follows or removes a link there. Opens take turns on `.cs/session.mutex.lock`,
an empty file, while they check and write that lock. They hold it through
flock(2), so the kernel releases it when its holder dies. The file stays on
disk, like the other `*.mutex.lock` files beside the files cs rewrites
(`.cs/local/state`, `.cs/local/vault-holders`, `.cs/local/lead-pid`,
`~/.claude/settings.json`) and the one `cs -queue accept` takes beside the queue;
`cs -uninstall` removes the `settings.json` one. The `*.lock` rule in a
session's own `.gitignore` hides both lock files, and `cs -adopt` adds
`.cs/session.lock` and `.cs/session.mutex.lock` by name to a project's
`.gitignore`. An open appends any of cs's rules a session's existing
`.gitignore` lacks; when git tracks that file (an adopted project's own
`.gitignore`, or one a cs session committed), the open prints one line naming the rules it added, which
are then an uncommitted change to commit with the next one. `cs -adopt` and
the migration of a flat-layout session commit nothing either: each prints one
line naming what it left for you to commit (of `.cs/`, `.gitignore` and
`.gitattributes`, and the root files the migration moved into `.cs/`, those
git shows as changed or untracked). `.cs/.narrative-reminder-cooldown` is a
similar gitignored transient at the `.cs/` root — the narrative reminder's
5-minute cooldown stamp.

`CLAUDE.local.md`, also at the session root, carries the cs session protocol:
it is machine-local and gitignored, cs regenerates it on each machine, and a
user-owned `CLAUDE.md` is never touched. Its `cs:session-commits` section says
that cs, its skills and its commands commit files under `.cs/` only in the
commit that creates a new session and the merge `/finish` makes to integrate
a feature, and the model commits them only when the user asks: `/rotate` leaves the handoff, its
supersedings and prunes and the task archive on disk, `/wrap` leaves the memory
entries, the summary and the task archive, and `cs -narrative rotate` leaves
the trimmed narrative and its archive chunk, all uncommitted. An open adds the
section to a session that lacks it; delete its text but keep the comment to
opt out.

## Machine-local files (`.cs/local/`, gitignored)

An [encrypted session](#encrypted-sessions) keeps the content files among these
in `.cs/private/` instead.

Git must track no file in either directory. A session's `.gitignore` lists
`.cs/local/` and `.cs/private/` (the directory; git still takes the link an encrypted
session keeps at `.cs/private`), but `git add -f` gets past that and a clone checks
the files out. For that reason `cs` refuses to open a session, `cs -adopt` refuses a project, and
`cs <base>@<task>` refuses a feature checkout while git tracks a file under
`.cs/local` or in the directory `.cs/private` resolves to. The error names the file
and the command that untracks it. The hooks cover a session that is already open:
see [How a hook finds its session](hooks.md#how-a-hook-finds-its-session-cs-resolvesh).
While git tracks a file there, none of the writers in the table below adds, changes or
removes anything, except the prompt hook's launch mark in `scope-prompt.trace`.

| File | Purpose |
|------|---------|
| `session.log` | Human-readable audit trail — session lifecycle, tool failures, autosave notes, UUID rebinds. Per-checkout by nature; the shared structured record is `timeline.jsonl`. |
| `state` | Session state bound to this checkout: `claude_session_id` (the conversation UUID to resume), `claude_session_color` (the `/color` palette entry), `last_resumed` (last resume date), `session_name` for adopted sessions only (their name lives in the sessions-root symlink, which a hook resolving the directory has no way to read; an ordinary session takes its name from its directory), and, for feature worktrees, `task_branch`, `cs_base` and `cs_mode` (`tracked` when the base repo tracks `.cs/`, `ignored` when it does not; it decides how the worktree's records reach the base when the feature is integrated and retired). An adopted session records `cs_mode` too, the mode its features take, and so does a flat-layout session in a git repo once the open moves it into `.cs/`. Neither `cs -adopt` nor that open commits anything, so each writes `ignored` when the project's own rules already ignore the `.cs/` directory, and `tracked` otherwise (you may commit `.cs/` later); a `cs_mode` already in the file stays. With `tracked`, cs refuses a feature while git tracks nothing under the base's `.cs/`, until you commit it or change the line to `cs_mode: ignored`, which keeps `.cs/` out of git and has each feature hide it through `.git/info/exclude`. Once git tracks `.cs/` a feature is `tracked` whatever the line says, and a base with no `cs_mode` (one cs created, or one adopted or moved into `.cs/` before cs wrote the line) has the mode inferred from whether git tracks `.cs/`. While git tracks nothing under `.cs/`, a `cs_mode` that is neither `tracked` nor `ignored` refuses a feature, naming the line to fix. Each machine binds its own conversation, so this must not sync. Writers take turns on `state.mutex.lock` beside it. `claude_session_id` is one slot, written only by the conversation `cs` launched — see [hooks.md](hooks.md) for how a teammate or walked-in claude is kept out of it. |
| `identity` | Overrides the actor name for shared memory/narrative attribution (precedence: `$CS_ACTOR` > `local/identity` > git `user.email` > git `user.name`). |
| `config` | This session's settings, `KEY=value` lines that outrank this machine's `~/.config/cs/config` here and that your environment outranks in turn. `cs <name> -config set` and `unset` write it, taking turns on `config.mutex.lock` beside it. See [Settings file](configuration.md#settings-file). |
| `migrated` | The migration stamp, written when every write an open's migration made succeeded. Line 1: the cs version, the actor and `1` or `0` for an encrypted session, tab separated. Line 2: the files it checked that existed then. See [Migration](#migration). |
| `attention` | Status-line attention marker — raised by the `Stop` hook when Claude finishes, cleared on the next prompt. |
| `remote.pid` | The pid of the `claude remote-control` server `cs <name> --remote` runs for this session. `cs` writes its own pid here and then becomes the server, so the session lock names the same pid; a background process `cs` starts first removes this file and releases the lock once the server exits. `cs -live`, `cs -doctor`, `cs -rm`, the session manager and the hooks count the session as served only while this pid runs `remote-control --name <name>`. While it does, `cs -rm` and the picker's delete refuse the session even with `--force` or `[F]`, the end of the lead conversation the server started leaves `.cs/session.lock` to the server, and that lead sets no tmux or tab title. `cs -doctor` removes with a warning a file whose pid no longer does: one that background process never got to, as after a restart, where the pid may belong to another program by now. While the server runs, `cs` refuses every other open of the session. Stop the server with Ctrl-C or by closing its window, never with SIGKILL: the session it started keeps running then. |
| `lead-pid` | The lead's claim on its launch: `<launch pid> <claude pid> <conversation id>`, written by the SessionStart hook of the claude `cs` launched, on every source. The hooks read it to tell that claude from a `claude -p` or a mod process it started when the two pids differ (the resume arm, a `CLAUDE_CODE_BIN` that forks claude). Every launch removes it before claude starts. The lead's SessionEnd, other than at a `/clear` or `/resume`, marks it ended (`<launch pid> <claude pid> <conversation id> ended`) and leaves it, so a claude that another SessionEnd hook starts stays a guest, while the lead still runs and after it exits. Claimers take turns on `lead-pid.mutex.lock` beside it. See [hooks.md](hooks.md#how-a-hook-finds-its-session-cs-resolvesh). |
| `presence` | This session's advertised status (`cs -status`): a single line read by `cs -live`. Falls back to the README objective when unset. |
| `pending-handoff` | Basename of the `.cs/handoffs/` file to rotate into — armed by the `rotate` skill (for `/clear`) or by the `r` answer at the resume prompt. Consumed and cleared by the next SessionStart whose source is `startup` or `clear`; left armed on any other source; disarmed by any other resume-prompt answer. |
| `rotate-nudged` | Conversation UUID last nudged to rotate by the narrative reminder — keeps the 65%-context nudge to once per conversation. |
| `cs.heartbeat` | UTC timestamp of the last session start at which the cs mod ran — `cs -doctor` reports the mod from this file, never from the plugin directory being present. |
| `cs-update.heartbeat` | UTC timestamp of the last session start at which the cs-update mod ran, written by the mod's `session.start` when Claude Code loads it — `cs -doctor` reads it the same way it reads `cs.heartbeat`, never the plugin directory being present. |
| `cs-update.done` | Version and outcome line of the last `cs -update` the pane finished, written by the mod on a clean exit and read back by the reloaded module (from the pane's own render, `/cs-update`, or the next `session.start`): installing the update rewrites the mod's own deployed file, Claude Code reloads it mid-conversation without firing `session.start`, and the reload drops the module state the pane was drawing from. Cleared (written empty) by the first of those reads that finds nothing pending for that version. |
| `cs.forced` | The conversation `CS_ROTATE_FORCE_CTX` already rotated, written before the `/rotate` runs so a failed one is not retried every turn. `cs -archive-tasks plan` prints `forced: yes` while it names the conversation `state` names, and the rotate skill then skips the task-archive question. |
| `cs.pressed` | The conversation whose cs-mod rotate button was pressed, written just before the press runs `/rotate` and emptied at the end of the main loop's next turn, or at once when the engine refuses the run. `cs -archive-tasks plan` prints `forced: yes` while it names the conversation `state` names, as it does for `cs.forced`, so the one-key rotation skips the task-archive question and a `/rotate` typed later in the conversation asks. |
| `task-archive` | The session's answer to the task-archive question `/rotate` and `/wrap` ask once: `yes` or `no`, written by `cs -archive-tasks answer`. `cs -archive-tasks run` moves nothing without `yes`. |
| `wrapped` | The conversation a `/wrap` finished in (its `CLAUDE_CODE_SESSION_ID`), written by its last pass; the cs mod's band hides the wrap key while it names the conversation, and the next prompt empties it. |
| `disabled` | Opts the directory out of cs's hooks entirely. Present, the hooks decline as if it were not a session, whichever front end opened it. Before hooks resolved a session from the directory, a `claude` started outside `cs` in a session folder was inert; this restores that on request instead of by accident. |
| `pre-open` | An executable `cs <name>` runs before it opens an existing session, from the session directory on your terminal, so it can prompt (mounting the encrypted volume that `.cs/memory` and `.cs/plans` link into, for example). `cs` runs it with `CS_LIVE_LOCK_PID` set to the pid in `.cs/session.lock` when that pid is a running process (the lock's text, surrounding whitespace removed, is a decimal number from 1 to 2147483647 that names a running process), and to an empty value otherwise. The open has not taken the lock yet, so the pid is the conversation already running in the session, if any. A pre-open that needs to know whether the session is running reads this variable rather than the lock; run by hand, it runs with the variable unset. A non-zero exit aborts the open, and `cs` refuses a file that is not executable rather than skipping it. It lives here because this directory is never committed, so a cloned session cannot make `cs` run code: `cs` refuses to open when git tracks anything under `.cs/local`, and when `.cs` or `.cs/local` is a symlink, since git tracks a link as one path and a link to a tracked folder would hide its files from that check. A session copied by a file sync (rsync, iCloud, Dropbox) carries it along, and `cs` runs it. Afterwards, if `.cs/memory` or `.cs/plans` is still a symlink to something missing, `cs` refuses to open the session and names the link, instead of creating plaintext directories in their place. |
| `vault` | The path of the container `cs -encrypt` built, written only by `cs -encrypt`. The SessionEnd hook unmounts the vault only when this file exists. |
| `vault-holders` | Process ids of every `cs` run that mounted or joined this session's vault. The volume unmounts only when none of them and no session lock is alive. A `cs` that adds or drops its line takes turns with the others through `vault-holders.mutex.lock`. |
| `vault-waiter.pid` | The background waiter the SessionEnd hook leaves to unmount the vault once the lead conversation's Claude Code exits. An open that finds the vault mounted with nothing alive behind it stops this waiter first. |
| `vault-detach.pid` | The `hdiutil detach` that waiter started, so a reopen can stop an unmount in flight. |
| `queue/` | The walk-away task queue (`cs -queue`): one file per task, staged in `queue.tmp/` and renamed into place so the drain never reads a torn entry. The drain pops the lexically first file by moving it aside — atomic against a second drain. |
| `queue.state` | Drain state machine for the queue: `idle`, `armed`, or `draining`. |
| `queue.mode` | How a started run hands over its tasks: `subagents` or `workflow`; absent runs them in the conversation. Written by `cs -queue start`, removed when the run finishes or the queue is cleared. A run the failures breaker stops keeps it until the next `cs -queue start`. |
| `queue.done` | Log of completed queued tasks, appended as each is drained. |
| `queue.current` | Name of the queue file the drain last handed out. Only that task is logged done when its turn ends, and a draining queue with no such record parks instead of guessing. Removed when the run finishes, parks, or the queue is cleared. |
| `queue.failed` | A task the agent reported as not completed (`cs-task-failed`), kept until the drain parks on it. The report otherwise lives only in one Stop's message, so a Stop that cannot record `idle` would lose it. The file goes when the run parks, when a run starts and on `cs -queue clear`. |
| `queue.accepted` | Message ids of task-kind mail already moved into the queue by `cs -queue accept`, one per line. The receipt lands before the queue file, which is named `<epoch>-accept-<id>`, and accepts run under `queue.accept.mutex.lock`, so a repeated or racing accept refuses, and a retry after a kill between the two writes refuses too (the error says to `cs -queue add` the task by hand) rather than replay a task the drain may already have run. |
| `notifications.jsonl` | Per-machine queue inbox — drain lifecycle events (`drain_started`, `task_done`, `breaker_tripped`, `drain_finished`), read by `cs -queue log` and the surface-once digest. |
| `notifications.seen` | Cursor for that digest, so unseen inbox entries surface at most once. |
| `finish-progress.json` | The progress of the last `/finish` run, one JSON object that `cs <base> -integrate-feature` and `-retire-feature` replace whole at each step: `id` (one per run), `pid` (the cs process), `task`, `sha` (the captured commit), `step` and `ts` (epoch seconds of the write). `step` runs `started`, `merging`, `gate` (only for a real gate, not `-- true` or a `--ci-green` skip; it adds `gate_started`, kept on later steps), `fast-forward`, then ends at an outcome: `landed` (with `result`, the commit the base landed on), `refused` (with `reason`, the first line of the error) or `retired`. The cs mod reads it to toast `/finish`'s start and outcome and to draw the gate band. A step whose `pid` no longer runs belongs to a run a signal ended, and the mod treats it as over. Advisory: a write that fails costs one warning on stderr and nothing else. |
| `.advisor-nudge-cooldown` | The narrative reminder's cooldown stamp for its council-advisor nudge: at most one nudge per 30 minutes. |
| `memory-index.snapshot` | Copy of `.cs/memory/MEMORY.md` that `/wrap`'s memory pass takes before it edits the index; `memory-index-guard.sh check` compares against it and `restore` copies it back. Overwritten by the next sweep. |
| `memory-archive.snapshot` | Copy of `.cs/memory/reference_memory_archive.md` taken beside `memory-index.snapshot` (empty when there is no archive yet); `check` compares against it, so it names a pointer dropped from both files. `restore` leaves the archive alone. Overwritten by the next sweep. |
| `ctx-warned` | Conversation UUID already given the one-time 40% context warning (the tier below the rotation nudge). |
| `context-date/` | One file per conversation, named by its id, holding the `YYYY-MM-DD` that conversation was last told; written at session start and advanced by `scope-prompt` when it emits the date note. Per conversation because a lead and a tmux teammate share this directory and each hears the date on its own. |
| `scope-prompt.trace` | One line per stage of each `scope-prompt` run, appended as that stage finishes — so a run its timeout killed still names the stage it hung on, a `launch` line written before the hook loads its library (a run killed that early leaves only this line), plus a `budget=<N>` line naming the budget the run settled on. A run that passed `CS_SCOPE_BUDGET_MS` before its scan records a `skip` stage and still exits normally. Opt out with `CS_SCOPE_TRACE_DISABLE=1`. |
| `rewrite.trace` | A `start` line for each `ctrl+g` invocation, then one line per step it reaches, the last naming the path it took. The rewriter shim draws onto a screen that is torn down and leaves the buffer unchanged on every one of its several do-nothing paths, so without this a rewrite that declined is indistinguishable from one that was never asked for. |
| `watermark` | Per-actor high-water mark for the "shared memory/narrative activity since you were last here" digest injected on resume. |
| `context-pct` | Latest context-window percentage of the launched conversation, stamped by the status line (a tmux teammate sharing the directory only touches the file, so its reading never replaces the lead's); the narrative reminder reads it to suggest compaction, the launch card reads it to say how full the conversation you are resuming already is, and cs-tui uses its mtime as the liveness heartbeat for conversations opened outside cs. A `<file>.at` beside it holds `epoch value` of the last write, so an unchanged reading is rewritten once a minute rather than every render. A teammate's touch keeps its own cadence record in `context-pct.heartbeat.at`, so neither side reads the other's write as a change. |
| `limits` | Latest 5-hour/weekly rate-limit readings, stamped by the status line; read by `cs -usage` window anchoring and the queue's rate-limit breaker. A `<file>.at` beside it holds `epoch value` of the last write, so an unchanged reading is rewritten once a minute rather than every render. |
| `failures` | Per-task tool-failure counter written by `tool-failure-logger.sh`; feeds the queue's failures circuit breaker, reset at each drain advance. |
| `mail/` | Cross-session mailbox, one JSON document per message: senders (`cs -msg`) write to the recipient's `tmp/` and rename into `new/` (atomic — a message is either entirely present or absent); `cs -msg` prints `new/*.json` and moves them to `cur/`. Unread is simply the count of `new/*.json`, the same basis for the prompt hook's digest, the status line, and the TUI. Filenames are `<zero-padded epoch>-<id>.json` — not a monotonic clock; nothing may treat name order as arrival order. `corrupt.jsonl` holds any legacy inbox lines that failed to parse during migration. (A legacy `inbox.jsonl` plus its `seen` cursor is converted on the next session open.) `out/` holds this session's own sent copies, so a thread can be re-read from either end. `woke` lists the filenames both mail wakes have already discharged, meaning announced by a wake. Discharged means announced, never read: the message stays in `new/` until `cs -msg` prints it, so a spent announcement costs a wake and never a message. Anything that runs the hook against a live session's mailbox, a hand-run preview included, announces whatever it finds and leaves that mail silent but intact. The list is written tmp-then-rename under a per-process name because both wakes write it and the idle one overlaps itself. `wakes` counts wakes since the last user prompt, which clears it; `CS_MAIL_WAKE_MAX` (default 5) caps it. The directory is created at session start so Claude Code's file watcher has something to arm on: a watch given a path missing two levels never fires again for that process's lifetime. |
| `rotation-kick/` | Arms the `/clear` auto-start. session-start.sh creates it (a watch given a missing path never fires again for that process's lifetime), hands it over as `watchPaths`, and leaves a detached child to write `rotation.kick` into it once Claude Code's watch is up; that `FileChanged` wakes the session into the handoff's next step. `delivered` marks the kick spent, so the unlink that cleanup fires cannot wake the session on its own tail. Cleared at the start of each rotation, since a stale marker would make the new kick look already spent. |
| `retire-staged/<task>` | In a base: a retire `/finish` recorded while the feature's conversation still held its worktree (`sha:` the captured commit, `force:` 0 or 1). The base's Stop hook starts the entry detached once that worktree's `session.lock` names no live process, keeps the run's pid in `retire-runs/<task>.run` and its output in `retire-runs/<task>.out`, and drops all three when it reports the outcome (the entry leaves the stage in place under `--staged` for that reason); a feature's SessionEnd mails the base so an idle lead wakes to it. |
| `spawned-by` | Spawner session name for a `cs -spawn`ed worker; deleted after the drain-finished notify (one-shot). A brief-only spawn writes it with no queue to drain, so it stays until a later queue in that session drains, and that drain reports to the spawner. |
| `inherited-topics/` | In a feature of a session whose `.gitignore` lists `.cs`: one file per memory topic the feature copied from its base, named like the topic and holding the copy's `<checksum> <bytes>`. `/finish` reads it to tell a topic the base deleted from one the feature wrote, and stops when it cannot read a file here. |
| `inherited/` | In the same features: one file per other record the feature copied from its base (the README, plans, the summary and the rest), at `inherited/<path>` and holding the copy's `<checksum> <bytes>`. `/finish` reads it to tell a copy the feature edited from one it left alone. |

## Encrypted sessions

A session can keep its private files on an encrypted volume. Four names under
`.cs/` become symlinks into the volume's mountpoint (by convention
`.cs/vault-mnt`), and each one is opt-in: cs only checks whether the link is
there.

| Link | What lives behind it |
|------|----------------------|
| `.cs/memory` | Auto-memory and the narratives. |
| `.cs/plans` | Plans and specs. |
| `.cs/claude-config` | Claude Code's config dir for this session. cs launches Claude Code with `CLAUDE_CONFIG_DIR` pointing here, so transcripts, prompt history, `.claude.json` and its backups never reach `~/.claude`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps the shell's login (empty selects the default keychain entry). On every launch cs links the shell's `settings.json`, `settings.local.json`, `CLAUDE.md`, `AGENTS.md`, `rules/`, `skills/`, `commands/`, `agents/`, `hooks/`, `plugins/`, `output-styles/`, `keybindings.json` and `vale/` into it, skipping any name the session already has. A setting you change inside the session (`/model`, `/config`) writes through the link into the shell's `settings.json`. The first launch seeds `.claude.json` from the shell's copy with `projects` emptied, since each project entry keeps that project's last prompt. cs reads the session's transcripts from `projects/` here, and the picker does not rename such a session, because its links and transcripts name its path. |
| `.cs/private` | cs's own content files, which a plain session keeps in `.cs/local/`: `session.log`, `scope-prompt.trace`, `memory-index.snapshot`, `memory-archive.snapshot`, `mail/`, the queue files (`queue/`, `queue.tmp/`, `queue.state`, `queue.mode`, `queue.done`, `queue.current`, `queue.accepted`, `queue.failed`, `queue.migrating`), `notifications.jsonl`, `notifications.seen`, `failures`, `rewrite.trace`, `finish-progress.json`, the rotation handoffs (`handoffs/`), `pending-handoff`, checkpoints (`checkpoints/`), the task archive (`task-archive/`) and, when `.cs/memory` is a link, the rotated narrative sections (`narrative-archive/`). Numbers the status line writes (`context-pct`, `limits`) and ids (`state`, `spawned-by`, `rotate-nudged`, `ctx-warned`) stay in `.cs/local/`. |

### Encrypting a session with `cs -encrypt`

On macOS, `cs -encrypt <name>` sets this up for an existing session. Run it
from a terminal, with the session closed. It:

1. Creates an AES-256 encrypted sparse bundle at
   `~/.local/share/cs/vaults/<name>.sparsebundle` with `hdiutil`, which asks
   for a new password. The bundle grows as it fills, up to 50 GB. It lives
   outside the session directory, so `cs -rm` never deletes it.
2. Mounts it at `.cs/vault-mnt` (`hdiutil` asks for the password again) and
   turns Spotlight indexing off for it.
3. Moves `.cs/memory`, `.cs/plans`, the `.cs/local/` files listed under
   `.cs/private` above, and `.cs/handoffs`, `.cs/checkpoints` and
   `.cs/narrative-archive` into the volume, then links the four names into it.
4. Writes `.cs/local/pre-open` and `.cs/local/vault` (the bundle's path), tags
   the session `encrypted`, and unmounts the volume.

From then on every open asks for the password in the terminal. `pre-open`
refuses to open the session without a terminal, because without one `hdiutil`
shows a dialog that offers to save the password in the keychain. When the lead
conversation ends (not on `/clear` or `/resume`), the SessionEnd hook waits for
Claude Code to exit and unmounts the volume, unless the session reopened in
the meantime. The unmount is never forced: if something still holds the
volume, it stays mounted, and the next open unmounts it and asks for the
password. A second conversation opened while the session runs joins the
mounted volume without asking. `pre-open` learns that the session runs from
`CS_LIVE_LOCK_PID` (see the table above) or from `.cs/local/vault-holders`;
it never reads the lock itself. Run by hand, without the variable or with
one that names no running process (a pid that has ended, `0`), it joins
only a volume a listed holder keeps, and otherwise unmounts the volume and
asks for the password. An open that stops before Claude Code starts
(a refusal, or a cancelled prompt) unmounts the volume it mounted.

Every open that mounts or joins the volume adds its process id to
`.cs/local/vault-holders`. A process that replaces itself with Claude Code
keeps its id, so the entry stays valid while that conversation runs. cs
unmounts the volume only when no listed process and no session lock is
still alive, so a second conversation keeps it mounted after the first one
ends. An open that finds the volume mounted with nothing alive behind it
stops the old SessionEnd unmount first, then unmounts the volume and asks
for the password.

`cs -encrypt` refuses, before it writes anything, when:

- the machine is not a Mac, or stdin is not a terminal
- the session is running, adopted, or a feature worktree (`base@task`)
- any of the four names is already a link, or `.cs/claude-config` or
  `.cs/private` already exists as a folder or file
- `.cs/local/pre-open` already exists
- the bundle already exists
- `.cs/README.md` has no frontmatter for the tag

If a move fails partway, it stops, lists what moved and what did not, and
leaves the volume mounted so you can finish by hand; until you unmount it,
`cs -rm` and the picker's delete refuse to remove the session. When it finishes, it lists
the copies it cannot reach: the session's transcripts in `~/.claude/projects/`,
its lines in `~/.claude/history.jsonl`, its entries in `~/.claude.json` and that
file's backups, `.cs/summary.md` and `.cs/brief.md`, git history, and backups.

### Setting it up by hand

Mount the volume from `.cs/local/pre-open` (see the table above). While a link
points at a missing directory, the vault is locked, and cs writes nothing in
its place:

- `cs <name>` refuses to open the session and names the link.
- The hooks log nothing, deliver no mail wake and drain no queue.
- `cs -msg` to the session refuses the send. `cs -queue` in it refuses too.
- cs offers and consumes no rotation handoff.
- Opening a feature worktree (`base@task`) of the session refuses the same way.

A regular file at any of the four names also refuses the open. cs cannot tell
it from a locked vault, so the error names it.

Feature worktrees of an encrypted session are not supported yet. Creating or
opening one refuses even while the vault is mounted: a checkout of the links
`cs -encrypt` writes (`vault-mnt/<name>`, relative) points inside the worktree,
where nothing is mounted, and a base whose `.cs/` is ignored would give the
worktree plaintext files of its own.

Opening an encrypted session also refuses when a plaintext copy of a vault
file is still outside it: any of the `.cs/private` files above left in
`.cs/local/`, or a `.cs/handoffs/` or `.cs/checkpoints/` folder, or a plain
`.cs/narrative-archive/` beside a linked `.cs/memory`. The error names the file. Move it
into the vault or delete it. cs does not move it for you, because backups and
snapshots already hold the old copy.

With `.cs/private` present, the session protocol changes too:

- The objective, environment and outcome go at the top of the narrative. The
  prompt hook does not copy the first prompt into `.cs/README.md`, which keeps
  only its frontmatter. The first open adds a `cs:encrypted-protocol` section
  to `CLAUDE.local.md` that says so. Delete its text but keep the comment to
  opt out.
- The rotate skill writes the handoff into `.cs/private/handoffs/`; like
  every rotation, it commits nothing.
- The launch prompt after answering `r` does not name the handoff file, and
  the `rotated` event in `timeline.jsonl` records the rotation without the
  file name. A handoff's name is its topic, and both of those are plaintext.
- `/checkpoint` saves into `.cs/private/checkpoints/`, and its `timeline.jsonl`
  event carries no label or file name.

A narrative behind a `.cs/memory` link rotates into the vault. `cs -narrative
rotate` writes through a `.cs/narrative-archive` link when there is one, and
into `.cs/private/narrative-archive/` otherwise. With neither, it refuses
rather than write plaintext. `/checkpoint` refuses in that case too, since a
checkpoint copies the narrative.

The mounted volume stays out of git and out of the session's removal:

- The autosave snapshot skips `.cs/vault-mnt` and every link target inside the
  session directory. New `.gitignore` files ignore `.cs/vault-mnt/`.
- `cs -rm` and the picker's delete refuse while a link resolves inside the
  session directory, or while the mount table shows any volume mounted inside
  it (a `cs -encrypt` that stopped before linking leaves one), even with
  `--force`, because removing it would delete what the volume holds. Unmount
  first. `/finish` does not retire a feature worktree with a volume mounted
  inside it, and `cs -uninstall` keeps the sessions root, without asking,
  while one is mounted anywhere inside it. All three also refuse when `mount`
  cannot list the table.
- Unmounted, the session removes like any other, `.cs/` included. Keep the
  volume's container (a disk image, a cipher directory) outside the session
  directory, or at its root where `cs -rm --force` names it and asks for
  `--delete-files`.

Link all four names. With only some of them, the rest leaks: `.cs/private`
without `.cs/claude-config`, for example, keeps the handoffs in the vault, but
Claude Code's transcript in `~/.claude/projects` records the start-of-session
context that names the handoff file and quotes the conversation.

Not covered: copies that backups and filesystem snapshots already made,
third-party hooks that write under `~/.claude` directly, `.cs/summary.md`
unless you link it into the vault yourself, the brief `cs -spawn --brief`
delivers (`.cs/brief.md`, staged in the sessions root's `.spawn/`).

## Merge policy

The session repo ships a `.gitattributes` that keeps append-heavy shared files
conflict-free:

- `merge=union` — `timeline.jsonl`, `narrative.*.md`,
  `reference_memory_archive.md`: concurrent additions from different writers
  are both kept.
- `merge=ours` — `MEMORY.md`: the index is regenerated, so a machine keeps its
  own version rather than conflicting. `/finish` then appends each feature
  pointer whose target neither the base index nor its memory archive names,
  once per target.

cs counts each of these lines as present only as a whole line, so where an
earlier append glued one onto the line before, cs appends it again on a line
of its own.

In a session whose `.gitignore` lists `.cs`, git merges none of these, and
`/finish` fuses them the same way: the memory archive keeps the base's lines
and gains each feature pointer whose target it does not name, and a base with
no archive takes the feature's whole. A feature that never changed the
archive it inherited brings nothing back, so the base's deletions stand.

Human-authored prose (`README.md`, `summary.md`) uses the default merge — a
genuine divergence there is a real conflict a person should reconcile. In a
session whose `.gitignore` lists `.cs`, the record fuse never merges them:
once a feature changed its README or summary, `/finish` puts the feature's
copy in `.cs/features/<task>/` and leaves the base's own untouched.

Each clone has its own memory merge driver configuration:

- Launching the session with cs sets `merge.ours.driver` to `true` for that clone.
- A pull before that first launch uses ordinary text merging for `MEMORY.md`.
- `cs -doctor` warns when the clone lacks the driver.

Signed, per-machine secrets exports use a separate [secrets sync policy](secrets.md#syncing-secrets-across-machines).

## Migration

Legacy layouts are migrated in place on the next `cs <name>` open, via the
numbered phases in `migrate_session()`: a flat pre-`.cs/` layout is moved under
`.cs/`, a legacy `discoveries.md` is folded into the narrative, retired
command-tracker files are pruned, and machine-local fields are moved out of
shared files into `.cs/local/`. Migration is idempotent — a modern session is
left untouched.

![Migration notice header, gitignore lock rules and commit instruction, then README frontmatter added](https://raw.githubusercontent.com/hex/claude-sessions/main/assets/notice.svg)

A migration whose writes all succeed writes `.cs/local/migrated`, and
the next open skips the one-time phases while that stamp still holds: same cs
version, same actor, same encrypted state, every file it listed still there,
and none of `.gitignore`, `.gitattributes`, `CLAUDE.local.md`, `CLAUDE.md` or
`.cs/README.md` modified after it, and `merge.ours.driver` still set in a
checkout cs keeps merge attributes in, every one but an adopted Claude Code
worktree (cs reads the value: git rewrites `.git/config` on
every `git config` write). When only `.cs/memory/MEMORY.md` changed,
the open re-checks the narrative pointer and nothing else. The refusals (a
tracked `.cs/local/`, an unmounted vault), the transcript binding and the checks
that only look for a leftover from an old layout run on every open. `cs -doctor` reports the
stamp; `rm .cs/local/migrated` forces a full migration on the next open, for
an edit the stamp cannot see (a file restored with its old modification time,
or saved within the same second as the stamp).
