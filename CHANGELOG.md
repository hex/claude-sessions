# Changelog

All notable changes to cs are documented here. Release notes are also available on [GitHub Releases](https://github.com/hex/claude-sessions/releases).

<!-- New entries group changes under Keep-a-Changelog headings (Added / Changed / Removed / Fixes / Docs), or Features / Performance where those fit the release. -->

## Unreleased

### Fixes
- A tmux teammate no longer warns about the lead's context. `.cs/local/context-pct` holds the launched conversation's reading alone, and the 60% warning and 80% rotate nudge read it for every conversation in the directory, so a teammate at 4% told its user "context is at 60%". Both tiers now see no reading unless the firing claude is the lead. The 2026.9.8 fix kept each conversation's notice separate; this keeps the reading with the conversation it describes.

## 2026.9.10

### Features
- The prompt hook names the day when it changes. The session context states the date once at startup, so a conversation that lives across midnight kept believing yesterday's date and worked out "today" from it. On every prompt the hook compares the calendar day against the one this conversation was last told, kept per conversation under `.cs/local/context-date/`, and adds one line naming both dates when they differ; on the same day it adds nothing. A lead and a tmux teammate sharing the directory each keep their own day. Off switch: `CS_DATE_REMINDER_DISABLE=1`.
- `cs -doctor` gains an Authority section: one row per hook that injects into the model's context, with the switch that turns it off and whether that switch is on right now. A status line needs opt-in, a context injection did not, and nothing listed them in one place.
- `cs -doctor` warns when the clone it runs in lacks the `merge=ours` driver. The driver is per-clone git config, installed by every `cs <name>` launch, so a pull on a brand-new clone before the first launch text-merges `MEMORY.md`. The warning names the one-line fix.
- CI runs shellcheck at error severity over every shell file, with an rc that knows `lib/` fragments carry no shebang by design.

### Fixes
- `cs -usage` counts subagent tokens again. Claude Code moved subagent transcripts from `<conversation>/` to `<conversation>/subagents/`, and workflow agents sit one level deeper still, so both the session table and the per-conversation view had been reading the main transcript alone. One conversation on this machine went from 3.6M to 13.5M lifetime input tokens once the count included its agents. The walk now covers the whole conversation directory, and the model column comes from the conversation's own transcript rather than from the last subagent the scan happened to reach.
- The Authority section reads a switch exported as `0` as on. Every hook tests its switch with `= "1"`, and the section tested for a non-empty value, so `CS_SCOPE_DISABLE=0` read as off while the hook kept injecting.

### Docs
- The README states that the merge driver stays per-clone and that `cs -doctor` names a clone without it.

## 2026.9.9

### Features
- The Stop reminder names `/claude-council:advise` when you have the [claude-council](https://github.com/hex/claude-council) plugin, so a second opinion is one command away at a decision point. It suggests and never sends, and asks Claude to check with you first, because the digest goes to third-party providers. Detection reads `installPath` from the plugin record and then requires the command file on disk, so an uninstall that leaves its record behind produces silence rather than a command you cannot run. Only the launched conversation nudges, at most once every 30 minutes.

### Fixes
- The test gate no longer reports success when a suite's output goes missing. A lane that died printed a header with an empty body and the run still ended `OK`, so a lost suite read as a quiet one. It now names the suite and fails.
- Pin the lane count in the gate runner's own output test. It read the host's core count, so it ran eight lanes on a many-core machine and three on a laptop, and only the wide one lost a log.

### Docs
- Document the advisor note in `docs/hooks.md` and the README feature list.

## 2026.9.8

`/rotate` answered "You're out of usage credits" and did nothing. Fable is the one model that needs credits, so pinning a skill to it means the command dies exactly when context is nearly full and the handoff is most expensive to lose.

### Fixes

**`/rotate` runs on the opus family.** It no longer depends on a credit-gated model, so running out of credits cannot take the command away. The pin still exists for the reason it always did: a handoff is selection under judgment, and who writes it moves what a successor can recover as much as its length does, so the artifact should not depend on whichever model the session happens to be on. Opus is the tier `/wrap`, `/sweep` and `/summary` already run on for the same work.

**A narrative nobody has committed goes unmentioned.** The resume digest measures a teammate narrative against the watermark commit. One with no commit behind it had nothing to measure against, so the hook named it from line 1 with its whole section count, and no state existed that could stop it repeating. In a shared team, where nothing commits `.cs/memory`, every resume then said to read the file from its first line, which is the instruction this digest exists to replace. It now says nothing about such a file, the way a resume did before the digest existed.

## 2026.9.7

A resume used to tell Claude to read every narrative in the session. One of them is 801 KB, so nobody did, and the instruction was a fiction. It now says where each teammate notebook grew and nothing more. Separately, the test gate stops taking the machine down with it.

### Features

**The resume digest names where each teammate narrative grew.** It compares your `.cs/local/watermark` against the working tree and reports, per teammate notebook, how many sections it gained and the line the new content starts on. A notebook nobody has committed yet counts from line 1, and the digest names still-uncommitted growth again on each resume until a commit carries it. Read your own narrative in full; read a teammate's only from the line the digest names.

**Every surface says the same thing.** The `CLAUDE.local.md` template, the narrative frontmatter and its `MEMORY.md` pointer, the three session-start context blocks, `/summary`, `/wrap`, the README and the docs. Resuming an older session rewrites the previous wording in place, the way it rewrote the wording before that.

**The test gate leaves the machine usable.** `tests/run_all.sh` prints one line per suite as it finishes and ranks the ten slowest, takes half the cores above four, runs every suite under `nice`, and refuses a second gate on the same checkout instead of stacking. `--changed` runs only the suites a change can reach; a full gate that took 1413 s while stacked now takes 279 s.

### Fixes

- **`run_all.sh --changed` no longer swallows a single suite's output.** The capture and the replay disagreed about what counts as parallel, so a one-suite selection on a multi-lane box ran the suite and discarded everything it printed, including the failure text. That is the exact shape of the edit loop.
- **A Rust-only change runs no bash suite.** `tui/` was missing from the ignore list, so editing the crate ran all 63 suites for code none of them reads.
- **The migration rewrites your own narrative, not your teammates'.** It looped over every notebook in `.cs/memory`, and a committed edit to a teammate's head shows up in their teammates' digests as growth that is not a tail.
- **A current `CLAUDE.local.md` stays untouched.** The rewrite gate matched the current template's own text, so every resume of every session rewrote the file: identical content, a new mtime, and a symlinked file replaced by a regular one.
- **The digest survives a session inside a larger repository.** `git diff --numstat` prints repo-root paths, so a session in a subdirectory never matched its own `.cs/memory` files.
- **A head edit no longer drags the reader to the top of the file.** The start line comes from the last hunk that adds lines, so rewriting a description line reports no growth rather than pointing at line 3 of an 801 KB notebook.

### Other

- A test parses every hook under bash 3.2: an apostrophe inside a heredoc inside a command substitution parses under bash 5 and fails on the floor shell, and every local gate had missed it.
- One `git diff` per teammate notebook instead of three, and the gate drops roughly 250 forks per run.
- `test_worktrees.sh` no longer asserts the developer's environment: cs exports the variable the opt-out test expects to be unset.

## 2026.9.6

Every cs session gets the native task list back. A tmux teammate no longer speaks for the lead: it cannot drain the queue, overwrite the context reading, or re-arm a one-time notice.

### Features

**Every cs session opts into the Task tools.** Claude Code 2.1.233+ leaves `TaskCreate`, `TaskList`, `TaskUpdate` and `TaskGet` out on Opus 4.8, Sonnet 5 and Fable 5 unless the session asks for them. The rotation wake, the walk-away drain and the rotate skill all address that list, so a cs launch now exports `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` next to the task-list id. Before this, a rotation on those models told the successor to reconcile a list it did not have. `CS_NO_TASK_TOOLS=1` hands the choice back to Claude Code for anyone who wants the context those tool definitions cost.

**`/wrap`, `/sweep` and `/summary` pin the `opus` family.** The three passes named a point release, which keeps them on an older Opus once a newer one ships. They now pin the family alias, the way the rotate skill pins `fable`.

### Fixes

A tmux-backed agent-team teammate is a full claude in the same session directory, with its own Stop hook and its own statusline. Three per-session slots assumed one claude per directory:

- **Only the lead's Stop drains the task queue.** An idle reviewer teammate popped every queued task in succession, declined each, and the lead's queue read "all tasks complete" with nothing done. The drain now runs under the same lead check as the mail wake; a teammate's Stop falls through to the narrative reminder.
- **Only the launched conversation writes `context-pct`.** A teammate's statusline overwrote the lead's context reading, so each reported the other's number to every gate that reads the file. The statusline writes the value only when the payload's session id matches the id recorded at launch; other conversations still touch the file, which keeps the liveness heartbeat alive.
- **A teammate's Stop no longer re-arms the lead's context notice.** The rotation nudge and the context warning kept a single-slot cursor, so a teammate's turn reset it and the lead's one-time notice fired again, five times in one afternoon. Both cursors are append-only lists of conversation ids; every conversation gets its own notice once.

**The prose critic scores; `/summary` decides.** The critic subagent returns per-dimension scores and rewrites, no pass-or-revise verdict, and the command compares the total with the threshold itself, so the pass criterion never reaches the critic's prompt.

### Docs

- `docs/hooks.md`, `docs/statusline.md` and `docs/session-layout.md` describe the lead-only drain, the lead-only `context-pct` value and the append-only notice cursors.
- `docs/configuration.md` and the README cover `CS_NO_TASK_TOOLS`.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.9.5...v2026.9.6

## 2026.9.5

A handoff keeps your words and trims its own. Each walk-away task now carries its scope. A rotation reconciles the task list it inherits.

### Features

**Handoffs keep the user's words and condense the writer's.** Two rules join the rotate skill's body rules. What you said, asked for or corrected stays close to your own words: a paraphrased correction has drifted, and the successor cannot get the original back. The writer's own reasoning compresses to what it concluded. Length goes to the facts a successor cannot recover and nowhere else, so a body that runs long everywhere no longer buries the facts it exists to carry. No byte cap, still.

**Every drained task carries a scope block.** Nobody watches a walk-away run, so the handed task is the only scope guidance the agent gets. The drain now appends one to every task, the first included: do every behavior the task asks for, leave a pre-existing bug or unmentioned behavior as a follow-up in the narrative unless the task cannot work without it, take the most direct reading of an ambiguous task and say so.

**A rotation reconciles the native task list instead of rebuilding it.** cs launches claude with the task list keyed to the session name, so the list survives `/clear` and the fresh conversation already holds it. The rotate skill says so and still lists every open item under Pending Tasks, so the handoff reads whole on its own. The rotation preamble and the wake that follows `/clear` ask the successor to reconcile the inherited list with the handoff (close what it marks finished, add the next-step steps that are missing) rather than mirror the handoff into it and split progress across duplicates.

### Docs

- README and `docs/hooks.md` cover the new handoff rules, the scope block, and the task-list mirror.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.9.4...v2026.9.5

## 2026.9.4

The installer stops re-asking about the status line, and shows you the bar before it asks at all. The rotation handoff gets a home for rejected work, a provenance on every claim, and a safer ritual. And the subagent rows name the model that is actually running.

### Features

**`cs -update` remembers a declined status line.** Anyone who keeps their own bar has been re-answering the same prompt on every release. A decline is recorded in `~/.config/cs/statusline-declined` (under `$XDG_CONFIG_HOME` when set) and the installer prints one line instead of asking; `cs -statusline enable` reverses it, `cs -statusline disable` sets it without waiting for a prompt, and `cs -uninstall` removes it. Contributed by @nkonin.

**The installer shows the bar before asking to install it.** A sample renders above the question, from a fixed payload pinned to the segments that need no live session, so a stranger's branch name and inbox never appear in their own installer. Best-effort: no `jq`, no binary yet, or a failed render all fall through to the question.

**Handoffs have a home for rejected work, and every claim says how it was learned.** The rotate skill's body sections were Claude Code's own compaction template with the errors-and-feedback section removed — and that was where "a rejected alternative and the reason it lost" belonged. Across ten real handoffs that fact class landed in five different sections. `Settled and rejected` is now a section of its own, `none` required when empty. Behavioural claims carry a provenance (measured, read in source, inherited, assumed): the one measured silent failure in the store was a handoff asserting a tool did something it did not. Next Step opens the body, the body is written in two passes so a mid-rotation compaction cannot lose the part that matters, and arming is the last step, because the launch prompt disarms an armed marker and nothing re-arms it. The handoff is written on the `fable` family alias.

### Fixes

- A failed decline memo no longer aborts the install. Under errexit the marker write could exit before `settings.json` was written, leaving hooks copied but never registered.
- Declining says plainly that it is remembered, on its own line, and enter declines the same as `n`.
- Subagent rows derive the model name from the id instead of a lookup table: Fable 5.1 no longer renders as "Fable 5", Opus 5 no longer shows its raw id, and a family nobody has listed still resolves. Vertex `@date` ids and `-preview` tags are handled; an id that does not fit the shape renders verbatim.
- The launch card puts the secret count and the context figure on one row, with a literal middle dot: `echo -e` escapes print as six characters under `/bin/bash` 3.2.
- Three tests wrote into the developer's real `~/.config` and `~/.cs-secrets`. The test harness now scopes `HOME` and `PATH` for every suite at source time, carrying the git identity across so a bare runner still passes.

## 2026.9.3

A rotation now continues by itself. After `/clear` on an armed handoff, the fresh conversation reads the handoff and starts its next step about two seconds later, with nothing typed.

### Features

**`/clear` on an armed handoff starts the work itself.** A hook cannot start a turn, but it can arm one: session-start watches `.cs/local/rotation-kick/` and leaves a detached child to drop a file there once Claude Code's file watch is up. That change wakes the model with a reason carrying the instruction your "go" used to carry. The wake yields to you — a message you send inside that window wins, and the notice says so. `CS_NO_ROTATION_WAKE=1` restores the old behaviour; `CS_ROTATION_KICK_DELAY` tunes the wait.

Two decisions worth knowing. The kick is deliberately off the mail budget: `CS_MAIL_WAKE_MAX` bounds a volley of arrivals nobody asked for, while a kick is one file the session wrote for itself, so spending mail's allowance on it would silence real messages. And it does not yield to the queue, which is the opposite of the mail wake — nothing resets `queue.state` on a `/clear`, so an interrupted drain leaves a stale `draining` behind, and yielding there swallowed the only event the kick will ever produce, stranding the rotation *and* the queue.

**The narrative budget is 512 KiB, with a 256 KiB tail.** Sections run about 2 KB and an active day produces sixty-odd of them, so the old 128 KiB held roughly one day — a resume read today's findings and nothing before them. The cap only sets how often rotation runs; the tail is the recurring cost, and a few percent of a 1M context is cheap for the file carrying a session's results.

**The rotate skill ends on the one step nothing can take for you.** `/rotate` now closes with the `/clear` instruction and nothing after it. A hook cannot submit to Claude Code's command queue, so that keystroke is always yours — it should not be buried under a summary.

### Fixes

- The rotation notice and preamble now describe the path you are actually on. A wake arrives as a system-reminder, so "the first message comes from the user" is false when a kick is armed, and "send any message" would make you race a wake already coming.
- The rewake label no longer claims every wake is mail. One `FileChanged` registration carries both cross-session mail and the rotation kick, so the label names neither and the reason says which.
- A cancel test in the prompt-rewriter suite waited for any child process to appear, treating that as proof the shim's TERM trap was armed. It is not — the shim forks a command substitution to build its progress label *before* arming the trap, so under gate load the signal could land in the unprotected window and surface as a raw exit 143. It now waits for the shim's own `rewriter-forked` signal, which is written after the trap.

### Tests

- The six cs-secrets concurrency tests moved to their own suite. They hold a writer inside its critical section with deliberate sleeps — those sleeps are the assertion, not padding — and isolating them cut the parent suite from 89s to 56s, more than the tests themselves cost, because they were loading the box for every neighbour.

## 2026.9.2

A patch release: one visual tweak, and a test-harness leak that reached the developer's own terminal.

### Fixes

**The test suite no longer renames your tmux windows.** Tests that run cs under a pty — to exercise the paths gated on `[ -t 1 ]` — made that check true, so cs's terminal side effects fired for real. With `TMUX` exported, `set_tab_title` renamed the developer's *live* window to a test fixture's session name and ran `allow-rename off` to lock it there. cs undoes that in an EXIT trap it never reaches, because it `exec`s into claude, so the fixture name stuck until it was cleared by hand. Fixed in `_pty_run` rather than per-test: the leak is a property of running cs under a pty, not of any one test, so no future pty test can reach the real terminal either.

**Two more gaps in the same helper.** Its BSD arm had no `timeout`, unlike the util-linux arm whose own comment explains exactly why one is needed — so a command that stops to ask something waited forever on a pty that never reaches EOF. It is bounded now, and a test that needs to *answer* a prompt sets `PTY_INPUT`. A guard on one platform arm was not a guard on the helper, and the input is an explicit opt-in rather than a sniff of what the caller's stdin happens to be — that varies by environment (a terminal locally, a file on a CI runner, a socket under an agent harness), which is how the first attempt at this passed here and took all eight pty tests down on macOS CI.

### Changes

- The resume card carries a context row — `◱ 44% context used` — beside the session's other facts, instead of a loose line above the prompt with nothing separating it from the question. It inherits the card's gradient bar, and appears only on a resume, where there is a conversation for the figure to describe.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.9.1...v2026.9.2

## 2026.9.1

A picker release: the session menu becomes a real menu, narratives rotate from it, and the resume prompt stops asking blind.

### Features

**Session action menu** — `Enter` now opens a popup over the list, one action per row with its shortcut key, instead of a one-line bar wedged between the panes and the footer. It is sized to its content rather than to a share of the screen; `j`/`k` moves, `Enter` runs the highlighted action, `Esc` closes. Every letter shortcut (`d`, `r`, `s`, `a`, `R`) still works straight from the list without opening the menu.

**Rotate a narrative from the picker** — `R` on any row (confirmation required) archives that session's oldest narrative sections and shows what cs printed. A narrative under its byte budget rotates nothing and says so, which is the answer as often as a rotation is. No countdown like the delete confirm: the archive chunk is a verbatim copy of what left, so the answer is recoverable.

**`cs <name> -narrative rotate`** — rotation is reachable by session name from any terminal, not only from inside the session (this is what the picker shells out to). A worktree session rotates its own narrative, unlike `-secrets`, which routes a worktree to the base session's namespace.

**The resume prompt says how full the conversation is** — `Previous conversation used 64% of its context.` above the `[Y/n]` prompt, so the choice between resuming and rotating is not made blind. It reads the figure cs-statusline already stamps to `.cs/local/context-pct`, so it appears wherever the status line is installed and costs nothing where it is not.

### Fixes

- **Rotation and adoption no longer commit your staged work.** Both ran a pathspec-less `git commit` inside a checkout cs does not own — an adopted session *is* your project repo — so anything you had staged was swept into a commit titled `cs: rotate narrative` or `Adopt as cs session`. Both now name their own paths, and adoption's "is there anything to commit" check is scoped the same way.
- The picker's preview pane lists narrative headings and its cache never expired, so after a rotation it kept quoting headings that had just been archived, for the life of the picker. Preview reads are now keyed by request generation rather than by session name: the render that follows any keypress re-requests the selected session, so a read invalidated mid-flight and the fresh one queued right after it were indistinguishable, and the stale one landed first.
- `R` refuses a session with a live conversation, the way `d` already did. It was the one mutating action with no liveness guard, and it rewrites a narrative and commits inside a checkout that conversation is still appending to.
- The rotate confirmation said "Rotate *X*'s narrative", but rotation resolves the *caller's* actor — on a session whose narrative belongs to someone else that is a promise cs cannot keep. It now says "Rotate your narrative in *X*?".
- Naming a pathspec makes the commit a partial commit, which git refuses inside a repository mid-merge — a state the old bare commit committed straight through. The refusal is the safer half of that trade, but the reason is no longer swallowed.
- `cs <name> -narrative rotate` refuses a dangling adopted symlink or a directory with no `.cs`, rather than reporting them as a wrong invocation form.
- `cs -narrative`'s usage line named only the global form, so a user who correctly named a session was told to run it from inside one — which, followed literally, would have rotated a different session.
- Neither shell completion offered `rotate` after `-narrative`; the session-option list was re-offered in its place.
- `cs.bash`'s session-name guard regains a term `_cs` already had (latent, but the parallel-flag shape is what hides that class).

### Internal

- Menu dispatch is carried in the table as an action, not implied by array position and matched on display strings. Reordering the menu would have run the wrong action for the highlighted row with every test still green; a swap now fails five.
- The completion drift guard was scoped to each file's session-option list. Every session verb also names a global flag, so the file-wide grep it replaced went green on a verb no session context offered — which is how `-narrative` reached the dispatch uncompleted.
- Five vacuous tests fixed, each confirmed by mutation. Deleting the rotation budget guard left all 47 narrative tests green (both under-budget tests pinned a message a *different* guard also prints). The preview test's wait loop broke on the negation of its own assertion, so it passed when its worker delivered nothing and always burned a full second. The menu's Enter test asserted `MENU_ITEMS[i] == MENU_ITEMS[i]` without ever pressing Enter. And both new commit-scoping tests passed when the commit never happened at all — their fixtures commit before the user's file exists, so "HEAD does not contain it" was true either way; an assertion of an absence needs a positive anchor beside it.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.8.23...v2026.9.1

## 2026.8.23

A rotation release: session lab notebooks stop growing forever, and an adopted project can always find its way back.

### Features

**Narrative rotation** — per-actor narratives no longer grow without bound. When `.cs/memory/narrative.<actor>.md` passes `CS_NARRATIVE_MAX_BYTES` (128 KiB), `cs -narrative rotate` moves the oldest `## ` sections verbatim into an immutable, content-addressed chunk under `.cs/narrative-archive/<actor>/`, keeping a `CS_NARRATIVE_KEEP_BYTES` (64 KiB) live tail byte-identical — the one rewrite shape that merges cleanly under `merge=union` against a peer's concurrent append (measured, and pinned by two-clone regression tests).

- `/wrap` runs the rotation as its third pass; the Stop hook flags an over-budget narrative; `cs -doctor` warns.
- `cs -search` covers archived chunks.
- The resume protocol now reads the **live** narratives only; a migration rewrites the old "read all narrative.*.md" wording cs previously wrote (both protocol-block vintages, CRLF-tolerant) — measured against all 31 real sessions on this machine: fires on exactly the 17 that carry the old wording, rewrites all 17, touches nothing else.
- The narrative contract is now append-only: corrections are new dated notes, never edits — that is what keeps rotation merge-safe.

### Fixes

- **Adopt no longer strands a project**: `cs -adopt` on a directory whose session link was removed (TUI `d` / `cs -rm`) now offers to re-adopt the existing `.cs/` records under the new name, preserving narrative and timeline byte-for-byte; if the directory is still linked, the error names the existing session. Previously the only way out was deleting `.cs/` by hand.
- **`cs -rm` fails loudly without a terminal** instead of exiting silently, and `--force` now actually skips the confirmation prompts (the nested branch-deletion question defaults to keeping the branch).
- Rotation-adjacent hardening, each found by review and measured on the BSD/bash-3.2 floor: `head -c 0` aborting after the chunk was committed; an early-closing `head -1` pipeline dying at exit 141 past ~1700 sections; BSD `cmp -n` misreporting unequal-length files; `wc -c` under `pipefail` killing the Stop hook and `cs -doctor` on an unreadable narrative; unreadable input and unwritable archive dirs now refused cleanly.

### Docs

- README, `docs/hooks.md`, `docs/session-layout.md`, `docs/configuration.md` updated for rotation, the append-only contract, the archive layout, and the new budgets; design spec and implementation plan shipped under `docs/superpowers/`.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.8.22...v2026.8.23

## 2026.8.22

A statusline release. On Fable, the bar was quietly showing you the wrong limit — this adds the right one.

### Features

- **A `fable` chip, on Fable sessions only.** Fable draws on its own model-scoped weekly bucket, and Claude Code puts only the two plan-wide windows on the statusline's stdin — so a Fable session showed `5h` and `wk` for a limit that was not the one about to bite. Verified live during development: `wk` read 49% while Fable's own window was at 97%. The new block reads `✧ fable 86% · 1d20h`, escalating amber at 70% and red at 90% like its neighbours, and appending the reset countdown at 80% and up as the weekly block does. It renders only when the active model is Fable; every other model returns at the gate having touched nothing.

- **That one figure is fetched, because it cannot be read.** `GET /api/oauth/usage` is the same endpoint Claude Code polls, reached with Claude Code's own OAuth token — from the Keychain on macOS, from `<config_home>/.credentials.json` on Linux and WSL2. cs reads that credential and never refreshes or writes it: Claude Code owns the rotation, so an expired token is a 401 to back off from. The bearer travels to `curl` on stdin, never on a command line where `ps` would expose it.

- **The render still performs no network I/O.** It reads a cache and, when that cache is due, detaches a refresh — a mode of the statusline script itself, so nothing new lands on the install manifest. The cache is machine-global at `$CS_SESSIONS_ROOT/.usage/`, not per-session, because the endpoint admits roughly 28–30 requests per account per rolling hour and capacity returns only as old requests age out; a 600-second floor holds cs to about six an hour however many sessions are open, leaving room for Claude Code and anything else on the machine.

### Fixes

Every one of these was found by adversarial review of this release's own work, and every one passed a green suite first.

- **One account's usage could be shown as another's.** Several routes led there, and the fix was structural rather than another comparison: a cached reading is now addressed by the account it belongs to, so it can never be found under a different one. A refresh that cannot identify the account it fetched for stores no reading at all, and a swap detected mid-request discards the result rather than filing it under whoever is signed in now.

- **Two accounts defeated the request budget entirely.** With one cache record for the machine, whichever account was not in it had to override the poll interval to replace it — so two sessions on different accounts each bypassed the other's backoff and fetched on every render. Measured at twelve requests inside a single ten-minute window, against a budget of roughly thirty an hour. Per-account records let the interval and the account stop competing; the same sequence now costs two requests, one each.

- **The refresher ignored its own schedule.** It had no interval check, so any condition that marked the cache due — a corrupt record, an unreadable config — spent a request the cadence had already booked. It now declines under the lock, and holds the cadence even when the account cannot be named at all.

- **A response that was not this API's could erase a good reading.** A captive portal or proxy answering 200 with an HTML interstitial parsed to no Fable window, which is indistinguishable from an account that genuinely has none — so it discarded the last good number and stamped the replacement fresh. Such a response is now treated as a failure, and failures keep the previous reading.

- **A stale lock could be reclaimed twice.** Two refreshers both finding a lock abandoned could both proceed, the second deleting the first's fresh lock. Reclaim is now a rename, which is atomic, so exactly one contender wins.

- **A corrupt cache never healed.** The parse failure returned before marking the cache due, so no refresh was ever kicked and the chip stayed dead until the file was deleted by hand.

- **The Keychain call had no bound on the platform that needs one.** A locked login keychain can put `security` behind a prompt that never gets answered while the refresher holds the machine-wide lock. The existing helper falls through to unbounded execution when neither `timeout` nor `gtimeout` exists — which is stock macOS, the only platform where that prompt exists. It now falls back to `perl`'s `alarm`.

- **A non-UTC reset stamp was read as UTC**, putting the countdown hours out. Any offset that is not `+00:00` is now refused: no countdown beats a confidently wrong one.

- **A machine without `curl` forked a doomed refresher every render** — once a second, per Fable session — because the cache it could never write was perpetually due.

### Docs

- `docs/statusline.md` gains a Fable usage section covering the endpoint, the credential sources, the budget the cadence is shaped by, and every condition under which the chip does not render.
- `docs/session-layout.md` documents `.usage/`; `docs/configuration.md` gains `CS_USAGE_DIR` and `CS_USAGE_NO_REFRESH`.

## 2026.8.21

A statusline release. The bar reads the terminal instead of guessing at it, and it now draws a tail on terminals cs never measured — which is most of them.

### Features

- **The bar reaches the edge on terminals cs never measured.** The full-width gradient needs the terminal's real background, and only cs's own OSC 11 query at launch ever learns it — so on every session cs did not launch, the bar simply stopped after the last pill. The tail now falls back: where a background is known it still fades exactly onto it, and where none is, it draws a coverage wash of `░` as foreground on the terminal's default background, so the uncovered part of every cell is the terminal itself and no colour is ever named.

- **A pane cs did not launch can still find the measurement.** An agent-teams teammate is spawned straight off the tmux server and inherits none of cs's environment, so it fell to the dark default and drew a dark bar on a light terminal. Launch now also writes its measurement to `~/.cache/cs/term/<key>`, keyed by the tmux client tty, and a render with no `CS_TERM_*` asks tmux which client its pane is on and reads it back. The key is the terminal's identity, so re-attaching from another terminal misses rather than returning a stale answer — and because tty names are recycled, entries also expire after twelve hours.

- **A dotted tail where the bar cannot ramp.** Inside tmux the host mutes a truecolor status line unless `CLAUDE_CODE_TMUX_TRUECOLOR` is set, which cs exports at launch — so a pane cs did not launch had its 24-bit output snapped to the 256 palette, and a warm off-white's nearest neighbour there is a pink. cs now detects that case and drops to the palette deliberately; such a bar cannot ramp, so its tail is evenly spaced `·` at one dim grey.

### Fixes

- **The palette followed macOS, not the terminal.** The status line read the system appearance on every render, which says nothing about a terminal with a fixed scheme or one embedded in an app — exactly where it was reliably wrong. It now asks the terminal: the attached tmux client's own reported theme inside tmux, `COLORFGBG` outside it, and dark when nothing answers, the same assumption cs makes everywhere else with nothing to go on.

- **The tmux claim is checked, not believed.** `TMUX` is ordinary environment and is inherited wholesale, so a program launched from a pane passes it to a window it opens in a terminal of its own. Every rung keyed off it then read the wrong terminal. cs now walks its ancestry for the tmux server named in `TMUX`; when it is absent the whole inherited terminal description is treated as describing somewhere else, and the pane id is hidden rather than printed from another session.

- **An unknown theme means dark.** It previously meant "no palette", which rendered a bar with no theme applied at all.

- **A local install shipped whatever picker was lying in `bin/`.** `bin/cs-tui` is a gitignored build artifact that nothing regenerates, so `./install.sh` copied whatever binary happened to be there — observed deploying a picker seventeen days older than the release being installed, while reporting success. No version check catches it: the picker carries no version of its own.

- **Seven defects caught by review before shipping.** All seven were in this release's own work and all passed a green suite: a 16-colour terminal sent 256-colour escapes it cannot render; an inherited `TMUX` costing a real truecolor terminal its colour; the tmux-mute workaround gated on a `TERM` substring that does not track whether the host quantises, so it silently skipped `screen`; a malformed `CS_TERM_BG_RGB` leaving the bar stopped dead; a missing or restricted `ps` read as proof of a foreign environment, so a genuine pane rendered dark; recycled tty names letting the background cache return a confidently stale answer, which a comment and the docs both claimed was impossible; and a cache entry written under a plain tty that no render could read.

### Docs

- The theme ladder, the background cache, and both tail mechanisms are documented in `docs/statusline.md`, including how to pin `CS_TERM_BG_RGB` for a terminal cs cannot measure.
- `docs/upstream/statusline-theme-request.md` writes up the upstream ask: Claude Code already resolves the terminal theme and tracks it live, and does not pass it to the status line. Every rung above exists because that field does not.

### Internal

- The attach probe was built and reverted. Four adversarial reviews found four distinct defect classes, and the last two were the design rather than the code; `tmux set-environment` is session-scoped while the identity it needed is per-window. The commit message records what not to try again.
- `tests/test_subagent_statusline.sh` read `TMUX` from the developer's shell. Harmless until the colour ladder started consulting it, at which point three assertions passed outside tmux and failed inside it.

## 2026.8.20

### Features

- **The already-open menu can hand you the session manager.** Running `cs <name>` on a session that is already open offered three ways forward, all of them about that session: force a second launch, start a feature worktree, or give up. There is now a fourth — open the picker and choose a different session. The row appears only when a picker binary actually resolves, so it can never name a command that answers "cs-tui is not installed".

- **The picker archives a session with `a`.** It could already see the archived marker — those rows render dimmed, and `A` decides whether they show at all — but archiving one still meant leaving the picker for `cs -archive`. `a` toggles it, on the bare key or from the action bar, which names the direction the key will take rather than offering "archive" on a row that is already archived. The marker itself is written by `cs -archive` / `cs -unarchive` and not by the picker, so its date-and-actor stamp and its refusal to archive a live session keep a single owner; cs's refusal reaches the status line in its own words.

- **Rewriting with Grok.** `CS_REWRITE_PROVIDER=grok` (or `xai`) routes the prompt rewrite to xAI's OpenAI-compatible endpoint, reading `XAI_API_KEY` or `GROK_API_KEY`. There is no `grok-api` spelling because xAI ships no rewriter CLI: nothing to prefer, so nothing for a suffix to reach past.

  The default model is `grok-4.3`, and it was measured rather than picked by recency. Across 8 prompts run twice against every candidate, `grok-4.3` kept every unspecified thing as an explicit open item. The much faster `grok-4.20-0309-non-reasoning` did not: on 7 of 10 vague runs it decided for you — answering `Use jq.` to "should i use jq or awk here?", choosing a database unprompted, inventing requirements like "accessible" and "polished" from "make the picker better", and once handing back the input unchanged. Since the rewritten text becomes your next message to the agent, an invented requirement becomes work you never asked for.

  Worth saying plainly: Grok is not an upgrade to the default. `gemini-flash-lite-latest` was both the fastest model measured and tied for the best fidelity, so it remains the recommendation.

### Fixes

- **`cs` no longer passes the resolver's marker into what it launches.** Hooks infer "this is the launch" from the absence of `CS_RESOLVED_FROM`, and a teammate's shell carries `walk` deliberately — so an inherited value rode through `cs -spawn` into the new session, which then read itself as somebody else's front end and declined to clear its own lock at exit. The next open reclaimed the lock as stale, so the visible cost was a spurious collision menu, but the invariant the hooks depend on is now enforced rather than assumed.

### Docs

- `CS_REWRITE_PROVIDER`'s reference entry listed only three of its six values; the `-api` variants that reach a vendor API past an installed CLI were documented in the hooks guide but missing from the configuration reference.

### Internal

- The collision menu reads a single keypress, so it can address at most nine options. The feature-worktree list is capped to five to leave room for the fixed rows — past that, a row would render and never answer its own number.

- Four independent reviews of this range found defects a green suite did not. Two of its own new tests asserted the developer's machine rather than the code: both needed a `cs-tui` on PATH, which CI never builds, so both would have gone red on every runner. A mutation review found four more paths deletable with the suite entirely green — the whole action-bar route to archiving, and the picker probe that finds a binary beside `cs`. A fourth found the Grok provider's own entry point unpinned, and the launch-marker bug above. Every test added here was checked by mutating the line it claims to protect.

- `test_lock_cleaned_on_session_end` no longer reads its verdict from the shell that runs it, and the vendor-rewriter suite no longer inherits real xAI credentials from the developer's environment.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.8.19...v2026.8.20

## 2026.8.19

### Fixes

- **A rotation handoff now carries the facts a successor cannot look up.** Measured blind on a real 1.08 MB conversation, a shipped handoff answered none of 60 questions about things that existed only in the conversation it replaced — a rejected alternative and why it lost, an exact reading taken while debugging, a run identifier, the order two events happened in.

  One rule was the cause. "Reference, do not restate" is right for work a commit, spec, plan or narrative already holds, and it silently drops everything else, because a fact that lives nowhere else has no path to point at. The rule now says which half is which. On the same measurement, a handoff carrying those facts answered 12 of 12 where one without them answered 0 of 12, with control facts scoring equally on both.

  It states no target length. Three sizes were measured and the smallest was a different artifact by a different author, so the curve says as much about format as about size; length is described as what it buys rather than as a number to hit.

  Rotation also runs when context is already hot, and a compaction can land before the handoff is finished, leaving it distilled from a summary with the exact facts already gone. So those facts and the next step get written first, and a handoff written from compacted context says so rather than reading as complete.

  Because the rule asks for exact readings written down as they were, and an exact reading is where a secret hides, redaction is now re-checked after the body is written.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.8.18...v2026.8.19

## 2026.8.18

### Fixes

- **Your `CLAUDE.md` no longer reaches the prompt rewriter.** The rewrite ran from a directory under `$HOME`, and Claude Code collects `CLAUDE.md` by walking up from the working directory — so `~/.claude/CLAUDE.md` arrived labelled as project instructions that override default behavior. Its "stop and ask the user for clarification" rules are the inverse of the rewriter's contract, so on a vague or question-shaped prompt the model answered you instead, and that answer replaced what you had typed. It also sent your private global instructions to the model every time. The call now runs from a private `mktemp` directory and arms no tools.

- **The resume prompt says when a handoff came from another checkout.** `.cs/handoffs/` is shared and nothing retires a handoff this machine never wrote, so one can keep being offered indefinitely. Answering `r` consumes it under your UUID — taking a colleague's pending rotation. The offer now names its origin, and a marker you armed outranks the directory scan.

- **`cs -doctor` warns when context gating is inert.** `cs-statusline` is the only writer of `.cs/local/context-pct`; without it the rotation nudge and the queue's context breaker both go silently quiet. Doctor reported OK for that.

### Features

- **Spent handoffs are pruned.** The `rotate` skill deletes `consumed`, `discarded` and `superseded` handoffs older than 30 days, keeping the 10 newest. Git history keeps whatever it removes.

### Internal

- Parallel test suites no longer collide over the machine's process table, and five defects an adversarial review found in the above were fixed before release — including a world-writable rewrite directory that would have let a local user choose the text replacing your prompt.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.8.17...v2026.8.18

## 2026.8.17

### Features

- **Bare `cs` in a session's own directory opens that session.** The picker exists to choose a session; standing in one, the directory has already chosen. A subdirectory, an unrelated directory, and a shell inside an already-launched session all still get the picker — inside a session, opening a second copy is never the intent.

### Fixes

- **A `claude` you start yourself no longer joins the session you are standing in.** Hooks find a session either from the contract `cs` exports before `exec`, or — for front ends that can publish no environment into a session — by walking up from the opened directory for its `.cs/`. A bare `claude` typed in a session folder was indistinguishable from those: same missing contract, same `.cs/` on disk. So cs hooks activated, and `CLAUDE_SESSION_NAME`/`DIR`/`META_DIR` were published into a conversation cs never launched.

  A terminal is where that inference is wrong, because a session is entered there by running `cs`. The walk now declines for terminal front ends — `cli`, and `sdk-cli` for `claude -p` — while Claude Code desktop, IDEs, plugins and any entrypoint cs does not recognise keep theirs.

  Agent-team teammates are the exception that keeps this from being a test on the front end alone. Claude Code respawns a teammate in a tmux pane, which inherits the tmux *server's* environment rather than the lead's, so it derives plain `cli` and reads exactly like a bare `claude` — but it is in the session, having been spawned to work there. The launch decides: cs reads the argv of the claude the hook is firing for and recognises a teammate by the `--agent-id`, `--agent-name` and `--team-name` trio Claude Code always passes together. A teammate keeps the session in its own environment, so `cs -secrets`, `cs -msg`, `cs -queue` and its status line work as before, while still being marked as not the launch — its exit never strips the lead's session lock.

- **`cs` accepts the `--` end-of-options separator.** A launcher composing `<binary> -- <operands>` handed cs a bare `--`, which the unknown-verb arm rejected as a command nobody could have typed, and cs exited 1.

- **An adopted project resolves by the name it was adopted under.** `hooks/cs-resolve.sh` read `session_name:` from machine-local state, but nothing wrote it, so the lookup always fell through to the directory basename — wrong for exactly the session shape it exists to serve. `cs -adopt` now records it, and opening an adopted session backfills it for sessions adopted before this.

- **A session name can no longer start with a hyphen.** Bare `cs` in a session directory re-enters as `cs <name>`, where a leading hyphen reads as a verb: a session named `-uninstall` reached that verb instead of opening, and `-rm` reached `remove_session`. Such names are refused at creation.

### Docs

- README regrouped, with the configuration gaps closed.
- Five documentation claims a four-angle audit confirmed false are corrected.
- `docs/hooks.md` documents how a hook finds its session — which front ends the walk serves, which it declines, and where teammates fit.

## 2026.8.16

### Added

- **The prompt hook now asks before it guesses.** A short clarify guideline rides every non-empty prompt, telling Claude to question a request it genuinely cannot pin down rather than pick an interpretation and act on it. Skip one turn with a leading `~`; silence it for a session with `CS_CLARIFY_DISABLE=1`, which is deliberately separate from `CS_SCOPE_DISABLE` because silencing grounding should not silence the questions.

  Ungated on purpose. The hook's work-verb classifier exists to guard expensive git work, which is what earns its false-positive risk; a clarify gate would guard a few hundred bytes of text, so it would buy nothing and pay for itself in misclassification. It would also miss its own audience: `make` is absent from that regex, so `make it better` — the canonical vague prompt — never reaches the grounding path at all.

  Consequence worth knowing: the hook no longer stays silent on a chitchat prompt.

- **Prompt rewriting: type a rough prompt, press `ctrl+g`, get a precise one.** The composer is replaced in place with a rewritten engineering request that you review, edit and send yourself — nothing is submitted on your behalf. Opt out with `CS_REWRITE_DISABLE=1`, which also leaves your `$EDITOR` untouched; swap the rewriter with `CS_REWRITE_CMD` (stdin to stdout).

  This looked impossible. No hook output field can replace prompt text, a blocking hook kills the turn before the model is called, and `additionalContext` only ever appends. The route is Claude Code's own `chat:externalEditor`: it writes the composer buffer to a temp file, runs `$EDITOR` on it, and replaces the composer with whatever comes back. cs points `$EDITOR` at a shim, so a supported round-trip does the substitution.

  The shim hands every non-composer file to your real editor, so `/memory` still works, and it passes the buffer through untouched when it is empty, starts with `/`, `!` or `#`, or carries a paste or image placeholder — the buffer holds placeholders, not the pasted bodies, so rewriting one would destroy the attachment. Every failure path leaves your text exactly as typed.

  The rewriter runs hermetically: its own config directory, a neutral working directory, and the session's context variables stripped. Without that, a nested `claude` inherits the project's `CLAUDE.md` and cs's own memory, and a request to add a flag came back demanding TDD, bash 3.2 compatibility and a README update that nobody asked for. Four assertions moved from "emitted nothing" to "emitted no scope block", which is the property they were always protecting.

- **`-api` provider names reach a vendor's API past its installed CLI.** `CS_REWRITE_PROVIDER=gemini-api` or `openai-api` skips the CLI preference, and `claude-api` posts to Anthropic's Messages endpoint instead of driving the Claude Code agent. Each needs that vendor's key and declines without one, leaving the prompt as typed.

  The reason is Gemini's lite tier. agy's catalogue is eleven models and carries no lite variant — `gemini-3.5-flash-lite` and every spelling of it are rejected as unrecognised — while lite is the fastest option measured anywhere. Without a way to say "the API, even though a CLI is installed", that tier was unreachable for anyone who had agy.

  Measured on one machine with agy and codex both present: `gemini` 7281ms against `gemini-api` 939ms, `openai` 12826ms against `openai-api` 1963ms. The bare names keep preferring the CLI, so nothing changes for anyone who has not asked for this.

  `claude-api` exists because the default rewriter drives the whole agent: `claude -p` ships Claude Code's system prompt and tool schemas on every call, measured at 35,255 tokens for a ten-token prompt, of which 99% of the internal time is the API round trip. That is the ~13s, not the model. There is deliberately no suffix-free API form for Claude — the bare name *is* the default rewriter, and it authenticates through your claude.ai login rather than a key.

- **The rewrite header names the engine and the model, and one knob sets that model everywhere.** `ctrl+g` now shows `agy · gemini-3.6-flash-low` or `api · gemini-flash-lite-latest` rather than a bare provider name, so which of the two arms is answering is never a guess. A vendor CLI that resolves its own model still shows a bare `codex`: cs cannot read that tool's configuration, and a guessed model in the header is worse than none.

  Both halves come from the vendor rewriter's own `--label`, called by the shim before it paints. Repeating the CLI-or-API test inside the shim would have been a second copy of it, free to drift into a header that said `api` while `agy` answered. `--label` is answered before the prompt is read from stdin, since the shim calls it without writing anything.

  `CS_REWRITE_MODEL` now reaches every arm — the API request, `agy --model`, `codex -m` — where it previously reached the API arms only. On a machine with `agy` or `codex` installed the CLI always wins, so the variable was silently inert exactly where most people would set it. Left unset it is still omitted entirely, so each CLI keeps the model configured in that tool.

  The id belongs to whichever engine answers, and cs does not translate between the namespaces. `agy models` lists agy's, and they embed the reasoning effort — `gemini-3.6-flash-low` works where the bare family name `gemini-3.6-flash` is rejected with `requires --effort`. The API arms take the vendor's own API ids.

- **Rewrite with OpenAI or Gemini instead of Claude.** `CS_REWRITE_PROVIDER=openai` or `=gemini` routes `ctrl+g` to that vendor. Each prefers the vendor's CLI when its binary is on PATH — `codex` and `agy` — and falls back to the vendor's API, reading `OPENAI_API_KEY` or `GEMINI_API_KEY`, when it is not. This mirrors the claude-council's `prefer_cli_over_api` policy and for the same reason: the CLI carries your subscription and spends no API credit. `CS_REWRITE_CMD` still outranks the knob, being the older and wider contract.

  The trade is measured, not assumed: the CLI arms take about ten seconds against about one for the API arms, and the interface is frozen for the whole run. The council can prefer CLIs freely because it is asynchronous on a twenty-minute budget; here that policy costs ten times as much in the one currency this feature spends.

  Three failure modes are not the ones the "non-zero to decline" contract anticipates, so the gate judges the output rather than the status alone. `agy` prints `CLI error: …` on stdout and still exits 0 — that string would otherwise have become your next message. A reasoning model can return a rewrite truncated at the token cap, which is non-empty and so passes an emptiness check while being unusable: `gemini-2.5-flash` was observed spending 1963 reasoning tokens against a 2048 cap and stopping mid-sentence, while completing normally on other calls — intermittent, which is worse than consistent. A `finishReason` other than `STOP` now declines. And Gemini's endpoint has answered with a bare HTTP 404 and a zero-byte body, transiently, so an empty response declines too.

  A cancelled rewrite used to leave the API key on disk. The temp file holding it was removed only on the way out of the normal path, and the shim's cancel handler signals the rewriter's whole process group as a matter of routine — so every cancellation left a readable credential in the system temp directory. Cleanup now runs from a trap, and the files are created in the main shell because a command substitution's assignments never reach one.

  The vendor CLI runs from the same neutral directory the default uses, because `codex` reads `AGENTS.md` from its working directory and `agy` takes that directory as its workspace. Its stdin is closed, since Claude Code hands the shim the real tty and an agentic CLI that decides it is interactive would paint over the progress screen. On the API arms the key travels in a mode-600 `curl --config` file and the prompt in a payload file, so neither reaches `argv`; both assertions are mutation-verified.

### Fixes

- **`ctrl+g` did nothing at all on a machine without `timeout(1)`, which is stock macOS.** bash 3.2 — the floor here, and the macOS system shell — treats `"${a[@]}"` on an EMPTY array as an unbound variable under `set -u` and aborts. The timeout prefix array is empty exactly when no `timeout(1)` exists, so the default rewriter died before reaching the model for precisely the users the best-effort bound was written for. Every expansion now uses the guarded `${a[@]+"${a[@]}"}` form.

  This shipped green from a developer machine because Homebrew's coreutils puts `timeout` on PATH. The release gate's CI step is what caught it, on both bash lanes.

- **The progress header could name an engine that never ran.** With `CS_REWRITE_CMD` set it showed the vendor's engine and a counting-down deadline, while a user script produced the buffer and nothing bounded it. The label and the countdown are now resolved once from the command actually dispatched: an arbitrary `CS_REWRITE_CMD` is named by its own basename and gets a plain elapsed clock, because the shim does not wrap it in any timeout and a deadline nothing enforces is a lie drawn on screen.

- **The manifest sync test did not police `CS_HOOK_LIBS`** — the one array this release adds to. Deleting a rewriter from `bin/cs`'s copy left all 30 tests green; that drift gives every install a standing `cs -doctor` failure and leaves the file behind on uninstall.

- **The rewrite screen spawned a subprocess ten times a second** to reprint a label that cannot change — roughly 250 process launches over a long rewrite, inside the window where the interface is frozen. The label, the terminal width and the timeout decision are resolved once; measured 6.7 to 9.4 frames per second on the vendor path.

## 2026.8.15

Idle mail arrives again. Two mechanisms meant to bound runaway behaviour turn out never to have worked, and a hook now says what it hung on.

### Fixes

- **A directory change no longer kills the idle mail wake.** Claude Code hands its file watcher a list of paths, and a cwd change **replaces** that list with whatever the session's `CwdChanged` hooks return rather than merging into it. cs answered nothing, so every `cd` wiped the maildir watch and mail stopped waking an idle session for the rest of its life — nothing later could restore it, since `watchPaths` rides on only three events, `SessionStart` has already happened, and `FileChanged` cannot fire once the watch it depends on is gone. Worse, the wipe only ran at all because cs registers a `FileChanged` hook: the guard reaching that path is satisfied by any `FileChanged` or `CwdChanged` registration, so the mailbox armed the event that disarmed it.

  `narrative-reminder.sh` now answers `CwdChanged` with the maildir, turning the event that wiped the watch into the one that restores it. The branch exits before the walk-away drain deliberately — an unhandled event falls through into it and pops a queued task, so without that exit a directory change would silently consume work.

  Measured on a session with a live wake: six deliveries in 46 minutes, the last 80 seconds before a `cd`, then silence through a two-minute probe. After the fix, the same session and the same `cd` deliver in 1.8 seconds against a 1.4-second control.

- **The mail wake ceiling counts wakes again, rather than turns.** `CS_MAIL_WAKE_MAX` caps "wakes since the last user prompt", but the budget was cleared on every `UserPromptSubmit` — and a wake reaches the model as a turn of its own, so each wake spent the budget and immediately reset it. The counter could never exceed one and the ceiling has never been able to stop anything, which is the volley between two unattended sessions it exists to prevent. The attention marker still drops on any prompt; the budget now clears only for a prompt somebody typed. A wake turn is distinguishable because it carries no prompt.

- **A prompt hook killed at its timeout no longer swallows the queue digest.** `_build_digest` advanced the `.cs/local/notifications.seen` cursor before either injection hook did any of its expensive work, while the digest itself reached stdout last of all. `scope-prompt.sh` runs under a 3-second wall clock and Claude Code kills it where it stands when it overruns, so a killed run had already spent the surface-once budget for notifications it never printed — and nothing ever surfaces them again. The two halves are now split: `_build_digest` records the pending cursor in `DIGEST_PENDING`, and `_commit_digest` spends it at each hook's emission point, after the write. Failing that way round can at worst repeat a digest. Both hooks carry verbatim-identical copies of both functions under the standalone-hook law, and the sync test now covers both — a hook that built with one copy and retired with a stale other would lose exactly what the split prevents.

### Added

- **`scope-prompt.sh` traces its own stages.** Every run appends `pid`, milliseconds and stage name to `.cs/local/scope-prompt.trace` as each stage finishes, so a run that overruns the hook's timeout leaves a trail naming whatever it hung on. That trail is the only evidence such a run ever produces: it never reaches an exit where it could write a summary, which is why the trace writes as it goes rather than at the end. The clock comes from shell builtins alone (`$EPOCHREALTIME`, or `$SECONDS` on bash 3.2), so tracing adds no forks to a hook already under suspicion for running slow — measured at or below the noise floor on a 157k-file repository. The `start` mark also names the directory the run stood in: the scan's cost depends on how much of the tree git has to walk, and a kill from deep inside one and a kill at its root are not the same event. Machine-local, since which machine was slow is half the finding; one run in 64 trims the file to its last 2000 lines. Opt out per-session with `CS_SCOPE_TRACE_DISABLE=1`.

- **The mail wake names who the mail is from.** The reason now reads `Unread cross-session mail (2), new from alice` rather than a bare count, so a session woken with nobody at the keyboard knows its correspondent before it opens the mailbox — the difference between a wake worth spending a turn on and one worth deferring. Each sender comes out of the same `jq` call that already read the document's kind, so naming costs no extra pass over the maildir, and repeat senders collapse to one name: two messages from one session is one correspondent.

  The clause says **new from** because the count and the names describe different sets. The count covers every unread document; the names come only from the ones this wake is announcing, because the discharge skip runs ahead of the read that would learn a sender. Naming every unread sender instead would cost one `jq` per unread document on every turn end — the expense the scan is built to avoid, and one the wake ceiling turns from rare into ordinary, since past it mail piles up in `new/` while turns keep ending. A sender is read as the document's `from`, falling back to its `actor` when `from` is empty: `cs -msg` records `from` as the sending session's name, which is empty for any send from a plain terminal, so without that fallback the clause would vanish for the most common human-initiated send.

### Docs

- The hook reference describes `narrative-reminder.sh` as the three-event hook it became. `CwdChanged` had reached the settings.json block but not the heading, not the "registered for two events" sentence, and not the paragraph explaining the watch's lifetime — which is where the root cause belongs. The registration test stayed green throughout, because it compares `install.sh` against the config block alone.
- The stage-trace example lists every stage a run emits. It showed eight; `objective` and `tokens` are unconditional in the code, so a reader matching a real trace against the doc would have found two lines that were not supposed to exist.
- The mailbox layout's `woke` entry reads as a sentence again. The README's mail-wake bullet says the wake names who the new mail is from, and its scope-grounding bullet now documents the stage trace and `CS_SCOPE_TRACE_DISABLE` beside the opt-out it already carried — a per-prompt file written on every run belongs where a reader looks for what the hook does.

## 2026.8.14

A name collision with Claude Code, the mechanism that makes fixing one safe, and two changes to how cs asks before acting.

### Changed

- **The `/voice` skill is now `/write-as-me`.** Claude Code 2.1.227 ships its own `/voice`, a local command that toggles voice mode. Two commands answering the same name is one too many, so the drafting skill takes a name of its own. Everything else about it is unchanged, including the profile and corpus at `~/.claude-sessions/.voice/`, which keep their location so an existing profile survives the rename.

  Upgrading deletes the old skill directory. That matters more than it sounds: a skill left on disk keeps answering its slash command forever, and nothing ever removed one. `RETIRED_SKILLS` now does for skills what `RETIRED_HOOKS` already did for hooks, consumed by both install and uninstall so a rename cleans up after itself and no cs files survive an uninstall.

- **The sibling-session block asks instead of suggesting.** When a request substantially matches another session's stated goal rather than merely sharing its vocabulary, cs now asks whether to hand it over before the work starts, and offers both paths. Two other places in the same hook family already handed a decision the user owns to a question — crash recovery, and the wrap-up cue — and this was the one left as advice with no obligation. The bar sits high on purpose: a routing prompt that fires on every overlap becomes a block nobody reads.

### Release process

- **The release gate now measures a rule rather than reading it.** Any release range touching something whose correctness is a claim about a population — a redaction rule, a regex, a filter, a matcher, a classifier — requires one reviewer to run it against the real population and report how often it fires and how often that firing is correct, in both directions.

  This is the step's own history rather than a hypothetical. The corpus redactor merged and was tagged 80 minutes later, one day before the gate existed, then survived 29 releases because every review after it was scoped to the range that release touched. It was caught only when a reviewer measured it over 2384 real transcripts: two firings, both false positives, zero credentials caught. Scope a review to a diff and it sees a rule once; measure a rule against its population and the defect has nowhere to sit.

### Tests

- `tests/test_retired_skills.sh` guards the cleanup path: the array present and identical in both manifest copies, a retired skill no longer shipping, and install and uninstall each deleting the old directory while leaving a skill cs does not own untouched.
- 55 suites and 324 TUI tests, green on both platforms.

## 2026.8.13

Two changes to what the tool reads and writes on your behalf: a linter comes out, and the voice corpus stops learning from text you never typed.

### Removed

- **`cs -lint` and the `prose-lint` Stop hook are gone.** The linter matched em-dashes and a banned-phrase list in prose written during a session, and the hook blocked turn-end until they were cleared. Neither survives. The `prose-hygiene` skill still carries the full taxonomy, and `/summary` still applies it with a subagent judge, which reads meaning rather than matching patterns; a regex only ever enforced the lexical fraction of it.

  Upgrading deletes the deployed hook and strips its `settings.json` registration, so nothing is left calling a verb that no longer exists. `cs -lint` now reports an unknown command.

  `/wrap` got faster as a direct result. Its prose gate spawned a judge subagent and re-ran it on a revise verdict, which was most of what a wrap cost; it now stops once the summary is written.

### Fixed

- **The `/voice` corpus was learning from text you never typed.** The builder decided authorship from the record type alone and never read `promptSource`, the field Claude Code stamps on every user turn. Anything the SDK or the system put through the user channel was distilled as your writing voice. On the machine this was found on, 1,717 `sdk` and 779 `system` records were passing that gate against 2,398 genuinely typed ones, and rebuilding the corpus now drops 2,504 records and shrinks it by a third. Records with no `promptSource` are still kept, so older transcripts are unaffected.

- **The corpus redactor kept real credentials and destroyed real prose.** Its catch-all matched any run of 40 or more characters from a class that included `/`, so a git SHA and a long absolute path were replaced with `[redacted line]`, while the rules missed most real tokens: a separator inside a token breaks the run, and the keyword rule wanted a colon or equals sign immediately after the keyword. GitHub PATs, AWS key ids, Slack tokens, JWTs, Stripe and Anthropic keys, `DATABASE_URL=postgres://user:pass@host` and `Authorization: Bearer <token>` all survived into a plaintext file the skill reads on every rebuild.

  The rules are now anchored on the issuers that actually appear, plus a pattern for credentials embedded in a URL and one for `Bearer` followed by a space. Anthropic keys needed their own rule: an `api03-` segment breaks any pattern wanting unbroken alphanumerics, and matching a bare `sk-` would have eaten every `task-`, `risk-` and `disk-` in your prose.

- **The first cut of that fix was still wrong, and the release gate caught it.** Measured against the real transcript set rather than fixtures: 2,384 files, exactly two redactions, both false positives, zero credentials caught. A deep path stays one unbroken run because `/` is in the class, so any digit in it (`IL2CPP` in a Unity tree) satisfied the new mixed-case-and-digits test; and the `Bearer` rule matched the keyword plus any twelve-character word, so `bearer authentication` was replaced too. The catch-all now counts slashes, since an encoded blob carries at most an incidental one while a path is mostly slashes, and rejects pure lowercase hex to keep git SHAs out. The bearer rule now requires the value to contain a non-letter.

  A deny-list cannot enumerate every secret, so this stays best-effort by design. The skill is now also told never to copy anything credential-shaped into the profile, not only into a draft: the profile persists and is reloaded every time you use it.

### Known follow-up

- A message whose entire content is one redacted line becomes fifteen characters, falls under the short-ack threshold, and is then excluded from the appendix, so it lands in no drop bucket and the stats header can report zero dropped while content was lost. Not fixed here.

### Tests

- `tests/test_no_lint.sh` guards the removal, including the membership that makes an upgrade clean up after itself rather than leaving a registered hook calling a deleted verb.
- The voice corpus suite grew from 16 tests to 25, pinning false-positive cases beside the leak cases. The path fixture now carries a digit: the previous one was the single shape where the code's own assumption held, so it could never have failed, which is how the redactor shipped inverted twice.
- 54 suites and 324 TUI tests, green on both platforms.

## 2026.8.12

Two readers answer "what is this session doing" — one in shell for `cs -live`, one in Rust for the TUI. They agreed on healthy records and disagreed on four kinds of damaged one, in both directions.

### Fixed

- **A session could show a state in `cs -live` that the TUI never showed for it.** A record whose pid is written as a JSON string — `"pid":"4242"` rather than `"pid":4242` — was accepted by the shell reader, because `.pid != null` is true for a string and the digits then passed the shell's own numeric guard. The Rust reader refused it outright. The shell now requires the pid to be a number, so the two surfaces cannot disagree about whether a record names a session.

- **A malformed record could write a control byte to your terminal.** The TUI's reader scans for fields rather than parsing JSON, so a raw control character — the range that includes `ESC` — was copied out of the file and rendered. Such a document is not legal JSON, which is why the shell reader's `jq` had always refused it; the Rust reader now refuses it too. This needs a file Claude Code did not write, but the file lives in a directory cs does not own, so the reader no longer trusts its bytes.

  The escaped form of the same thing was wrong the other way. A backslash-u-0001 escape is perfectly legal JSON: the shell decodes it and strips the byte, while the TUI printed the six literal characters. Both now arrive at the same text.

- **An empty name or status earned a state in the TUI.** A record naming no session was admitted with an empty key, and a blank status rendered as blank. Both are refused now, as the shell reader always did.

### Tests

- The two readers had drifted three times and the Rust side had no hermetic test at all — its only directory-level test is skipped by default, so nothing exercised it in CI. It has nine now, built around a record naming the test process itself: alive by definition, and `ps` confirms its start time, so the liveness half of the contract runs without spawning anything. Five matching cases on the shell side assert the reader directly rather than through the rendered line, because the render collapses distinctions the contract turns on.
- The release runbook now waits for CI on the content being released before the tag is cut. 2026.8.10 and 2026.8.11 were both tagged on commits whose CI then went red, and both were repaired by the very next commit — so the branch recovered while the tags kept pointing at red. Both failures were Linux-only and neither could reproduce on a macOS dev box.
- 55 suites, 1292 assertions, plus 324 TUI tests.

## 2026.8.11

Four items filed as cleanup, which turned out to be hiding five defects.

Nothing here was reported by a user. Three of the five were found by writing a test for code that had none, and the other two by an independent review of that new code — including one where the test gate itself would report every suite passing having run none of them.

### Fixed

- **A rejected `CS_PLATFORM_OVERRIDE` was announced and then ignored.** `detect_backend` read the platform as a `case "$(cs_platform)"` word, and a command substitution in that position discards the exit status. The value was refused on stderr, matched no branch, and fell through to the encrypted file — so on macOS a typo in that variable quietly moved secrets off the keychain and into a different store, while `docs/configuration.md` promised the value was rejected. It now is.

  The previous tests could not have caught it. They called `cs_platform` directly and asserted it returns non-zero; nothing asserted that a caller acts on that. Rewritten to drive the function through `cs -secrets`, the only thing that calls it, they fail without the fix.

- **One malformed session record cost every record after it.** The agent-state reader hands the whole `~/.claude/sessions/` set to a single `jq`, and `jq` abandons the run at the first parse error. A document left half-written by a session that crashed therefore took down every record sorting after it: healthy sessions silently lost their state in `cs -live` because an unrelated session died badly. The one-`jq` path still costs one `jq`; on failure each file is asked separately, so a corrupt document costs only itself.

- **An out-of-range pid read as a live process.** `pid_t` is a signed 32-bit integer, so a value past its maximum is not a process id at all — macOS refuses it, while Linux wraps `4294967295` onto `-1`, which means "every process the caller may signal" and succeeds. Pid `0` meant the caller's own process group on both. A lock file or session record holding either value made a dormant session read as running. Ruled out before `kill` is asked, so the answer no longer depends on how a platform parses its argument.

### Changed

- **The test gate runs suites concurrently.** A full local run took 502 seconds because 53 suites ran one after another; four at a time is 193 seconds on the same machine, both green over every suite. Nothing had been stopping them: the harness has always given each test its own temporary directory and scoped `CS_SESSIONS_ROOT`, `HOME`, `CS_CLAUDE_DIR` and the rest inside it, so suites cannot collide. The capability existed for a CI lane that was deleted with Windows support and simply lost its only consumer.

  The concurrency is invisible in the output — each suite's log is replayed in the order a serial run would have printed it — and `CS_TEST_JOBS=1` restores the serial path, which streams output live for debugging a single suite. The default caps at four rather than at the core count, because wall time is bounded by the slowest single suite; more shards past that point only oversubscribe a shared runner.

### Internal

- **`cs_platform` had three definitions and one caller.** Every other caller was an `= "msys"` comparison and went with Windows support. The copies in `cs` and `cs-statusline` were never invoked — `cs-statusline` branches on `$OSTYPE` and never used its own — so both are gone along with the drift test that existed only because copies existed. `CS_PLATFORM_OVERRIDE` is unchanged and still accepts `macos`, `wsl` and `linux`; the docs now say what it actually steers, which is secrets-backend selection.

- **The CR handling in `cs -secrets` states a reason that outlives Windows.** Its comments justified the base64 detour and the CR strips by a `jq` that opens stdout in text mode, which was a `jq.exe` behaviour; the previous release deleted the equivalent strips elsewhere as Windows-only. Each site now carries the reason that survives — a secret value may contain a CR deliberately, and the raw path cannot tell that from one added in transit — and the hostname strip feeding the password derivation is marked not refactorable, because changing which bytes reach the digest orphans every store already encrypted on that machine.

### Tests & CI

- **The gate reported success when it had run nothing.** `mktemp -d` was unchecked, and an empty log directory makes every suite's output redirection fail — bash abandons a command whose redirection fails, so no suite ran, the missing logs were swallowed and the absent failure markers read as success. Found by review before it shipped, reproduced with a stubbed `mktemp`: three suites that all fail, reported green, zero executed.
- **The gate's own suite failed under the feature it tests**, inheriting `CS_TEST_SHARD` and handing it to the runner it spawns, so a sharded lane sharded its fixtures.
- **The two registry readers are held to one document.** The shell and Rust readers implement the same contract in two languages and had drifted three times. They now share `tests/fixtures/claude-session-record.json` — templated by the shell suite, `include_str!`d by the Rust one — verified load-bearing by renaming a field in it and watching both suites go red.
- `run_all.sh` had no tests of its own; it has nine now. 54 suites, 1283 assertions, plus 315 TUI tests.

## 2026.8.10

cs drops Windows and Git Bash, and learns to say what each session is actually doing.

The previous release spent itself fixing three defects that only fired on Git Bash. This one removes the platform those defects lived on: 2025 lines of it, along with the workarounds, the permanently-red CI lane, and the release target still publishing a binary for it.

### Added

- **`cs -live` and the TUI say what each session is doing.** Claude Code publishes a record per running session under `~/.claude/sessions/`, and it carries the live agent state. `cs -live` gains a column reading `busy`, `waiting` or `idle`, and the TUI's `state` row appends it beside the pid (`■ live · locked 4242 · waiting`). Until now cs could tell you a session was alive but nothing about what it was doing, so three live sessions rendered as three identical rows and the objective text was the only way to tell them apart.

  A record outlives a crash, so neither reader trusts one on sight: the pid must still be alive *and* still report the process start time the record holds, or a pid the kernel has handed to something else would keep a dead session looking busy. A host that publishes no records, or a shell without `jq`, simply shows no state.

### Removed

- **Windows and Git Bash are no longer targets.** Windows was a second-class tier: session bookkeeping and secrets ran under Git Bash, but the Claude launch and the tmux spawner did not, so what shipped there was a session directory and a message telling you to use WSL. Holding that tier cost a CI lane, per-test skip guards, and a set of workarounds for behaviours only MSYS exhibits. Windows is now reached through WSL2, like any other Linux.

  Gone with it: the Windows Credential Manager secrets backend and its embedded PowerShell CredMan helper, the `test-windows-msys` lane that had been red since 2026-08-04 and shipped red through three releases, the release target still building and publishing a `cs-tui.exe`, 23 per-test skip guards and 9 suite pins, the TUI's `tasklist` liveness probe, and the mail path-remap that existed only because MSYS rewrote `/foo` into `C:/foo`. `CS_SECRETS_BACKEND` now accepts `keychain` and `encrypted`; `CS_PLATFORM_OVERRIDE` accepts `macos`, `wsl` and `linux`, and refuses `msys` rather than quietly honouring it.

  bash 3.2 remains the floor — macOS still ships it — so this drops a platform, not the shell constraint.

### Fixed

- **A failed migration to the Keychain ended with no diagnostic at all.** `keychain_store` exited where the other backends returned, so the migration loop's per-key failure counting was unreachable, and because that loop suppresses the function's stderr the run simply stopped. It now returns, which is what all four call sites already assumed. This surfaced only because removing the Credential Manager backend left three tests — asserting properties that were never Windows-specific — passing while testing nothing.

### Performance

- **Reading every session's state costs a flat two forks.** The state lookup ran a `jq` and a `ps` per live session; it now reads the whole set in one pass. Measured over eight live sessions: one `jq` and one `ps`, down from sixteen, and flat from there however many sessions are running.

### Tests & CI

- The Rust CI matrix ran macOS and Windows, so the TUI had never been built for Linux — a supported target. It now runs macOS and Ubuntu.
- 53 suites, 1270 assertions, plus 315 TUI tests.

## 2026.8.9

Three defects that only fired on Git Bash, found by fixing the Windows CI lane.
It is green for the first time since 2026-08-03, so these were shipping unseen.

### Fixes

- **Replying to a thread you started worked everywhere except Windows.** The thread reader asks `jq` for `input_filename`, and `jq` echoes each path exactly as it received it. MSYS rewrites a leading-slash argument into `C:/...` before a native `jq.exe` sees it, so the returned paths stopped matching the `out/` pattern the reply keys direction on. Every copy this session had sent then read as received, the correspondent resolved to the message's author, which is you, and the send was refused as mail to the current session. The paths handed back are now the caller's own, and a spelling that cannot be correlated falls back to reading the documents one at a time rather than returning an empty thread.

- **Mail arriving at an idle Windows session never woke it.** The `FileChanged` arm compared the reported path against this session's maildir as strings. The watcher reports the platform's own spelling, which need not be the one the maildir path was built from: `C:/Users/...` beside an MSYS `/tmp/...`, or `/private/var` beside `/var`. A real arrival in the session's own `new/` was dropped for being described differently. It now asks whether the document is in this session's `new/` rather than whether two strings agree, which keeps the precision the check exists for.

- **`cs -msg <target> -` could not send a large body on Windows.** The body was read from stdin and then handed to `jq` as an `--arg`, putting it straight back onto a command line, which Windows caps at about 32K. A body approaching the documented 65536-byte maximum failed to compose, so the stdin channel, which exists precisely so a multi-KB handoff need not travel through argv, did not deliver what it was for. The body now rides on `jq`'s stdin and nothing size-dependent reaches a command line.

### Tests

- The Git Bash lane is green again. Two of the suites were failing on fixtures the platform cannot produce rather than on the code: `chmod 500` does not deny the owner writes on Windows, so three tests modelling a failed write were silently modelling a successful one, and a stub PATH cannot be built there at all because MSYS binaries link against `msys-2.0.dll`, which Windows resolves beside the executable, so a relocated copy will not start. Both now probe the condition they need and skip, naming the reason, where it cannot be established. A `watchPaths` assertion that compared path spellings now writes a file through the maildir and looks for it through the emitted path, so it pins which directory the watch lands on.

## 2026.8.8

A follow-up to 2026.8.7, fixing what that release's own gate could not see. Its
test gate runs the suite locally and never reads CI, and the local shell here is
bash 5 while the floor and `macos-latest` are 3.2, so four suites went red on
required lanes that no local run exercised.

### Fixes

- **Four suites 2026.8.7 turned red on lanes its gate never ran.** Under bash 3.2, `command -v` answers from the command hash table and a one-command `PATH=` assignment does not invalidate it, so the doctor test that validates its fixture by *running* `jq` then found that same jq on a PATH scrubbed of it, and refused to run rather than pass vacuously. `cs -doctor` itself was never affected: it runs in a fresh process with no hash. Separately, three suites built a "tool X is absent" PATH by copying a whitelist of tools into a scratch directory, which cannot work on Git Bash: its coreutils link against `msys-2.0.dll`, which Windows resolves beside the executable, so a relocated copy will not start. Deleting the PATH entries holding the suppressed tool is no better there, because `rg`, `jq` and `grep` share `/usr/bin`. Those tests now probe the stub they built and skip when it cannot run, naming the reason, rather than reporting the fallback they were checking as broken; the assertions still run on every lane that can host the harness. The theme test likewise confirms `cksum` runs through the stub before judging a colour, since a host without one produces that test's exact symptom for a reason that is not the code's fault. The CRLF migration test no longer carries a carriage return through a shell variable, which is the one value Git Bash mangles, in a test that exists for Git Bash.

- **`cs -doctor` stops reporting drift against a checkout that never produced the install.** The deploy-drift check decides it is in a cs checkout from three relative names (`hooks/`, `install.sh`, `bin/cs`), then compares that directory's hooks with the deployed ones. Any directory holding those three passes, and a scratch copy of the repo is an ordinary thing to be standing in: running `cs -doctor` from one reported five hooks as drifted while the deployed copies were byte-identical to the real source, and advised `./install.sh`, which from there installs something else entirely. Running it again changed nothing, because nothing was wrong. `install.sh` already stamps the deploy directory with the version it shipped, so the check now reads that stamp and stays silent unless the checkout's own version matches. It compares the install against the tree that produced it, or not at all. The fixture had encoded the same looseness, writing an empty `bin/cs` so the existing drift tests passed on a checkout that could not have installed anything.

### Known issues

- `v2026.8.7` was published during a critical GitHub Actions incident and carries no release assets: the signing job never got a runner. Use this release instead.
- Three suites (`test_hooks.sh`, `test_msg.sh`, `test_queue.sh`) have been failing on Git Bash since 2026-08-04 and are not addressed here.

## 2026.8.7

A correctness release, almost all of it fixes, found by reviewing the shipped
behaviour of surfaces that report status — and repeatedly finding that a
check which could not run reported the same thing as a check that passed.

### Changed

- **`/wrap`, `/sweep`, and `/summary` run on Opus 5.** Distilling a session's documentation into what is worth keeping is judgment work, and the summary is the artifact the session is remembered by. The trade-off is cost: these three passes previously ran on a cheaper model precisely so that wrapping up never spent the heavyweight one.

- **`/summary` sizes each section to the session rather than filling the template.** The eight-section structure reads as a form to complete, so a session with nothing to say about a heading still got a paragraph under it — across 36 sessions the generated summaries clustered at 1,455-1,785 words almost regardless of what the session contained. The instruction to write a "comprehensive" summary is dropped, and a section with little to report is now expected to get a line rather than a paragraph.

- **The `merge` skill is user-invoked only.** It runs the repo's gates, merges, and deletes the branch; that is not something to begin on its own initiative. The description already said "invoke when the user asks", which a model can read past — the frontmatter flag cannot be.

- **The `rotate` skill redacts what it writes.** A handoff is a model's summary of a whole conversation, committed to `.cs/handoffs/`, and read back as the next conversation's opening prompt. It now keeps credentials and personal data out of that file — naming the key rather than the value — and references committed work by path instead of re-summarising it.

- **The always-loaded session protocol stops re-deriving the actor it already names.** Session start resolves the current actor and states it, then told the agent to run `cs -whoami` to find out who it was — three times, across two surfaces loaded on every turn.

### Fixes

#### Session data privacy

- **Session directories are created private.** cs made every directory with a bare `mkdir`, which takes the caller's umask — so under the common `umask 022` a session, its `.cs/` data directory, and everything cs writes there (narrative, plans, logs, timeline, machine-local state) were world-readable. On this machine that was masked by `~/.claude-sessions` happening to be `0700`, which is incidental: a custom `CS_SESSIONS_ROOT`, a shared box, or a root created under a laxer umask exposed all of it. `.cs/` is now `0700` on create and on every open, which also covers older sessions and fresh clones — git records no directory modes, so a clone recreates `.cs/` under whatever umask the cloning machine has.

  An adopted session's root is deliberately left alone. `cs -adopt` turns a directory the user already had into a session, and that directory's mode is theirs to choose — a shared checkout or a served directory may be world-readable on purpose. Only the `.cs/` tree cs creates inside it is cs's to lock down; the session root is tightened only where cs created it.

- **Feature worktrees keep their session data private too.** A `base@task` worktree is a full cs session holding the same narrative, plans and machine-local state as its base, but the worktree open path deliberately skips the migration that applies the mode — so its data sat world-readable next to a base locked at `0700`. Both create and reopen now harden it. Unlike an adopted session, cs creates the worktree directory itself, so its root is cs's to set.

- **The permissions backfill fires where it was silently doing nothing.** Its "did cs create this?" test compared the session path against the unresolved sessions root, so anywhere the root itself sits behind a symlink — macOS's `/var` → `/private/var` is the everyday case — it never matched. Both sides are now resolved, and a session reached through a symlink in the root is excluded explicitly, which is the adopted case the rule always meant to protect.

- **A symlink inside `.cs/` no longer redirects an auto-approved write out of the session.** The permission hook that silently approves writes to session metadata canonicalized the target's *parent* directory but never checked the final component, so a symlink at `.cs/notes.md` pointing anywhere on disk had a parent resolving inside `.cs/` and was approved — the write then followed the link. Session directories are shared through git by design, which made a pulled symlink enough to turn every auto-approved metadata write into a write outside the session. The target itself is now checked, and a symlinked one falls through to the normal permission prompt rather than being blocked. Adopted sessions, which are reached through a symlink at the session root rather than at the file, are unaffected.

- **`cs -msg` and `cs -archive` refuse a session name that points out of the sessions root.** Both build a path by joining the name onto the sessions root, and both had grown their own guard rather than sharing one: the mail guard admitted a backslash, which MSYS resolves as a separator, and the archive verbs checked only that the name was non-empty — so `../name` wrote and removed the archived marker outside the root entirely. They now share one check. It is deliberately looser than the validator used for names cs *creates*: worktree sessions are named `base@task`, and that validator admits no `@`, so borrowing it here would have refused every worktree session.

#### Writes that destroyed the file they were editing

- **A `settings.local.json` cs cannot parse is left alone instead of emptied.** Merging cs's memory settings redirected `jq`'s output straight onto the file, and the shell truncates a redirect target before the command runs — so a single trailing comma in a hand-edited `.claude/settings.local.json` cost the user every setting in it. The damage did not stop there: the merge runs under `set -euo pipefail`, so the failure aborted the launch, and every later attempt fed `jq` an empty file, which succeeds and writes nothing, leaving it empty for good. Migration could not repair it either, since its retry is gated on the file being *absent*. The merge now writes through a temp file and keeps the original when `jq` cannot read it — the same outcome as when `jq` is not installed at all — and says so on stderr.

- **A session README with no frontmatter is reframed through a temp file.** The rewrite redirected onto the README, which truncates it before a byte is written back, so a write that did not complete left the user's file empty. Every neighbouring write in that code already used a temp file; this one now does too, and a failed write leaves the original untouched.

- **Migration no longer deletes a line of the session README because it looks like a field.** Four machine-local keys are moved out of the README's frontmatter and into per-machine state, but the match ran over the whole file. `claude_session_id`, `claude_session_color`, `last_resumed` and `updated` are ordinary English, and the README carries hand-written prose sections — so a line in the Outcome section beginning `updated:` was silently removed, under a message announcing that machine-local fields had been moved. The match is now bounded to the frontmatter block.

- **Migration leaves an unterminated frontmatter block entirely alone.** The machine-local field strip is bounded by the fences, but only the opening one was guaranteed. With no closing fence the scan ran to the end of the file and deleted a body line that merely began with one of the four key names. Without a terminator there is no way to tell frontmatter from prose, so the block is now skipped rather than guessed at.

- **A CRLF session README no longer ends up with two frontmatter blocks.** A repo cloned on Git for Windows with default `autocrlf` has `---\r` on its first line, which the "does this file have frontmatter?" test did not match — so migration decided there was none and prepended a second block, leaving the original orphaned in the body where every reader of `tags`, `status` and `aliases` stops before it. The machine-local fields stranded there were then correctly skipped by the later strip, which is how this surfaced. Both the detection and the field strip now compare a CR-stripped copy of each line; the file itself is written back untouched.

- **Tagging a session repeatedly stops leaving a trail of dead `tags:` lines.** On a README whose frontmatter has a `status:` line but no closing fence, each `cs -tag` mutation inserted a fresh line without consuming the one it wrote last time. Readers stop at the first line so the reported tags were always right, which is exactly why nobody would notice the file growing by a line per edit. Only the run of lines cs itself writes — the ones immediately after `status:` — is consumed; a line further down that happens to read `tags: [...]` is the user's prose and is left alone.

- **A timeline record no longer takes the next one down with it.** Every writer that appends to `.cs/timeline.jsonl` did so with a bare `>>`. A process killed mid-write leaves a last line with no newline, so the next append splices two records onto one line — and because the reader parses per line and skips what will not parse, it drops the spliced line whole. One interrupted write therefore cost two records: the torn one and the intact one appended after it. `cs -conversations` lost the lineage arrow it exists to render. Every writer now repairs the tail first: session start, session end, the rotation emitters, `cs -checkpoint`, and the worktree merge. A partial record is still unrecoverable — it was never complete — but the damage stops at one.

- **The queue's own inbox survives an interrupted write too.** The tail repair above went to every `timeline.jsonl` writer, but `.cs/local/notifications.jsonl` — the per-machine inbox behind `cs -queue log` and the "while you were away" digest — is appended to by two writers that did not get it: `cs -queue defer` and the drain's five lifecycle events. Both readers parse per line through `fromjson? // empty`, so the same splice cost the same two records, and because the digest surfaces each entry at most once and still advances its cursor, a drain result was lost for good rather than re-shown. Both writers now repair the tail first, and the hook carries its own fallback copy of the repair, so an install whose hooks were not redeployed alongside a newer `bin/cs` still repairs rather than silently splicing.

- **The TUI refuses to delete a session a conversation is still holding.** `cs -rm` has always required `--force` for a lock-held session, but the TUI's own delete reached the same removal — `rm -rf`, or `git worktree remove --force` — without consulting liveness at all, taking the directory out from under a running Claude process. Both the single delete and the marked-set batch now check the lock, and the batch reports which rows it skipped rather than folding them into an anonymous failure count. The confirmation no longer opens on a locked row either, so there is no countdown that was always going to refuse. The predicate is the lock, not the statusline heartbeat, matching what the shell means by live.

#### Gates that passed because they could not check

- **The installer's checksum gate stops passing when it cannot check.** Verifying `cs-tui` was described in the code as a hard gate, but an unfetchable `.sha256` skipped the whole check and kept the binary, and a digest tool that produced nothing left the comparison unreached. Worse, because the installer runs under `set -euo pipefail`, a digest tool that *failed* aborted the entire install partway through, stranding both the unverified binary and its checksum file. All three paths now remove the binary and say why. The rule is the one already written into `cs -update`'s own helper: a gate that cannot verify must not pass.

- **`cs -doctor` stops reporting healthy on the states it exists to catch.** A `settings.json` it could not parse produced a screen of passes — no hooks missing, no broken hook paths, "0 hooks, 0 MCPs", statusline "not registered" — because every check read the file through a parser whose failure was indistinguishable from an empty result. There is now an explicit validity check that fails, and the checks downstream of it say the file is unreadable rather than reporting zero. Separately, the hook registration check matched the whole settings file as text, so a hook path lingering in an unrelated permission rule counted as registered while the hook never fired; and the shadow-ref check tested only tracked changes, though the autosave snapshots untracked files too, so a session whose entire body of work was untracked was reported as having nothing to snapshot.

- **`cs -doctor` stops blaming a settings file when the problem is a missing `jq`.** Two of the four checks that read `settings.json` lacked the `command -v jq` guard their siblings have, so on a machine without jq the exit-127 read as a parse failure and doctor announced that a perfectly valid file was not valid JSON — the same false-confidence failure that check family exists to remove. Both now say jq is missing instead.

- **`cs -doctor` no longer reports a hook library as an unregistered hook.** The registration check listed every `*.sh` in the hooks deploy directory and required each to be named in `settings.json`. Files in `CS_HOOK_LIBS` are sourced by the hooks rather than invoked by Claude Code, so they are deployed alongside them and correctly never registered — which meant a healthy install carried a standing `[FAIL] Hooks: missing in settings.json: cs-resolve.sh`. Libraries are now skipped; a genuine hook left in the deploy directory without a registration is still reported.

- **`cs -tag add` no longer reports success having written nothing.** The insert has two places it can anchor: after a `status:` line, or before the frontmatter's closing fence. A README offering neither sent every line through unchanged, the rewrite produced a byte-identical file, and the command exited 0. It now refuses and says what is missing. Relatedly, `cs -tag rm` could rewrite a line of *prose* that happened to read `tags: [...]`, because with no closing fence the frontmatter scan never ended — the scan is now bounded to a terminated block.

- **`cs -search` distinguishes a pattern it cannot compile from a search that found nothing.** `grep` exits 2 on a bad pattern and 1 on a clean miss, and both were treated the same, so a typo'd bracket made every file miss and the command answered "No results" — a false negative presented as an authoritative answer. It now reports the bad pattern and exits non-zero.

- **`cs -queue rm` reports a task number that is not there instead of exiting quietly.** An index past the end matched nothing, exited 0, and still cleared the deferral marker — re-arming the gate, so a later drain ran the task the user believed they had removed.

- **The installer stops blaming the release signature for a checksum-gate removal.** Once the checksum gate removes a `cs-tui` it could not verify, the signature block below it still ran `minisign` against that removed path — and minisign fails on a file that is not there. So an install with no `sha256sum`/`shasum` printed the correct "could not be verified — removed", immediately followed by a second, false "signature verification failed — removed", sending the reader after release-key tampering that never happened. Two diagnostics, two different causes, only one of them real. The verification is now skipped when there is nothing left to verify; the signature file is still requested, so the artifact names the installer fetches continue to match what the release publishes.

#### Surfaces that reported something other than what was true

- **`cs -usage` no longer prints a dead 5-hour figure as though it were current.** The 5h and week percentages were printed under one condition covering both anchor flags, so any stamp between 5 hours and 7 days old — 5h window reset, week window still running — showed a stale 5h number, while the table beneath it was computed on the rolling window either way. Header and rows measured different windows. Each figure now reads its own anchor flag, and an expired window reads `?` rather than a stale number.

- **Terminal theme detection falls back to OS appearance outside tmux too.** The tmux path ended in the OS-appearance probe; the non-tmux path stopped at `COLORFGBG`. A terminal that answers no OSC 11 query and exports no `COLORFGBG` — Terminal.app — therefore paid the 1-second query timeout and then stayed `unknown`, and unknown leaves both consumers on their dark default: the wrong-way failure on a light terminal. Both paths now share the last rung, which is also the order `tui/src/theme.rs` documents.

- **The TUI no longer claims a secret was deleted when the helper refused.** The delete matched a successful *spawn* without reading the helper's exit status, so a denied keychain prompt still removed the row from the list while the key sat in the store. It now requires the helper to have run and exited zero, and the list mirrors only what actually changed.

- **The TUI says so when a To-Do cannot be queued.** Adding a task to a session whose queue predates the current layout silently did nothing: no file written, no message, and the pane read "(no queued tasks)" while `cs -queue` listed them. Both ends failed the same way, so nothing anywhere revealed it. The failure is now reported, with the fix — open the session with `cs` once.

- **`cs <base> -features` agrees with the merge it is describing.** Readiness counted untracked files without the filter the merge gate applies, so a worktree created before cs excluded its own bookkeeping was reported as blocked on a merge that would have gone straight through, sending the user hunting for work to commit that was never theirs.

- **A feature worktree gets its resume briefing.** The block that reports last activity, recent commits, the objective and what teammates changed is added when a session is resumed inside a git repo — but the repo test was for a `.git` *directory*, and in a worktree `.git` is a file. Every worktree session therefore resumed with none of it, on every resume. The test now matches the probe used everywhere else in cs, which is true for both shapes.

- **A long pasted prompt gets scope grounding again.** The classifier that decides whether a prompt is code work piped the prompt into a matcher that exits at the first hit. Past the 64KB pipe buffer the write outlives the match, the writer takes `SIGPIPE`, and `pipefail` promotes that to the pipeline's status — which the classifier read as "no match". So a prompt with a pasted log in it was classified as chitchat and got no grounding at all, which is the case that most wants it. The prompt is no longer piped.

#### Text reaching the terminal

- **Session context no longer manufactures escape sequences out of plain text.** The resume briefing was rendered with `printf '%b'`, which interprets backslash escapes in whatever is substituted into it — so a session objective containing the five literal characters `\033` was turned into a real escape byte by cs itself, on its way to the terminal. The text was inert on disk; cs made it dangerous. The block is now built with real newlines and rendered with `%s`, and the assembled text is stripped of control characters once at the boundary, which also covers a sibling session's README carrying a genuine control byte.

- **Text another session wrote reaches the terminal without its control bytes.** cs is multi-session by design, and `cs -msg <target> -k task` writes a task straight into another session's queue, so the reader does not trust the writer. Mail already stripped control characters when rendering; presence and the queue did not, so an `ESC` or `BEL` written elsewhere reached the terminal raw through `cs -status`, `cs -live`, `cs -queue list` and `cs -queue log`. The strip is now shared, applied at render on all of them.

- **Error and status messages stop eating their own text.** They were rendered in a way that interprets backslash escapes in whatever was substituted into them, so a message quoting something containing `\c` truncated itself and swallowed its own newline, and `\t` became a literal tab. Backslashes are ordinary in the regexes and paths these messages quote. Search *results* were affected the same way: a matched line containing `\c` lost everything after it.

- **The terminal tab colour survives a machine with no `shasum`.** The colour is a digest of the session name, so the same session always gets the same tab colour. With no digest tool the digest was empty, every session collapsed onto a single colour, and the missing command wrote to stderr at every tab change — coreutils-only Linux and WSL ship `sha256sum` but no `shasum`, so this was a real host rather than a hypothetical. `shasum` is still tried first, so no machine that works today sees a colour change.

#### Command surface

- **`cs <verb> --help` answers instead of misdirecting.** Asking a subcommand for help sent the flag into that subcommand's own argument parser, which read it as data: `cs -msg --help` reported `No such session: --help`, pointing the reader at a session problem when they had asked for documentation. `-queue` and `-tag` printed their usage but framed it as an error and exited non-zero. Every verb now answers `-h`/`--help` with its own usage and exit 0, intercepted before any argument parsing or session resolution happens. The text is derived from `cs -help`'s own lines rather than written a second time, so the two surfaces cannot drift apart, and a check over the dispatch fails if any verb stops answering.

- **`cs -secrets --help` still reaches the secrets reference.** Answering `--help` uniformly for every verb was right for the ones cs implements itself, but `-secrets` is a delegation: `cs-secrets` is a separate binary holding the reference for its own eleven subcommands. The interception sits ahead of the arm that forwards to it, so `cs -secrets --help` began answering with four derived usage lines naming none of them — including the `wcm` backend line this same release added. `-secrets` is now exempt and forwards as before, which also makes true again the always-loaded session instruction that tells every conversation `cs -secrets --help` lists the rest of the verbs.

- **`cs <name> -msg` is offered where the other session verbs are.** The bash and zsh completions both omitted `-features` and `-finish`, and the error shown for an unrecognised session command omitted `-msg` — three copies of one vocabulary, each missing something different. A drift check now derives the verb list from the dispatch itself and fails if any completion or the error text falls behind, so this cannot recur silently. It reads the dispatch from its source fragment rather than the built binary, because the build concatenates every fragment and the other verbs' own argument parsers would otherwise be mistaken for session verbs.

- **Uninstall removes the two things install created that it was leaving behind.** `install.sh` reads the user's `fpath` line and places `_cs` in `~/.zsh/completion` when `.zshrc` spells it singular, defaulting to the plural otherwise; uninstall hardcoded the plural, so the completion survived for exactly the users the install-side detection was written to serve. It now sweeps both spellings — a superset that cannot drift with the detection, since `~/.zsh/completions?` can only ever yield those two. Separately `~/.cache/cs` was never removed, so update-check stamps and cached release notes outlived a full uninstall and made the next install look up to date; it is now removed and named in the pre-confirmation list, so the prompt still describes everything the run will delete.

### Docs

- **The secrets guidance says which stdin form is safe.** Feeding a value on stdin is not sufficient on its own: a pipe or a heredoc puts the whole command, secret included, into the session's command log. The guidance now names the file-redirect form specifically, and says where a scratch file must live — outside the session directory, because a write inside it is captured in the autosave ref and survives deletion. The `cs-secrets` help example showed the pipe as *the* stdin example; it now shows the redirect.

- **The subagent briefing names the safe stdin form.** It told subagents to pass a secret "on stdin", which a pipe or a heredoc satisfies — and the bash-logger records their commands verbatim, so either form writes the plaintext into the session log. It now specifies the file redirect, matching what the session briefing and `cs-secrets` help already say.

- **Three reference claims now match the shipped behaviour.** `hooks.md` closed by saying hooks activate only inside a `cs`-launched session, contradicting the same page's resolution section — `cs-resolve.sh` has a second arm that walks up from the directory the front end opened, so a conversation cs did not launch still activates them; the closer now states both arms plus the `.cs/local/disabled` opt-out. `configuration.md` called itself "every environment variable cs reads" while omitting `CS_MAIL_WAKE_MAX`, `CS_NO_MAIL_WAKE` and `CS_PLATFORM_OVERRIDE`. And the `wcm` backend was missing from all three places that enumerate backends — `secrets.md`, `configuration.md`, and `cs-secrets`' own help — though the code has accepted it since Windows support shipped. `tests/test_docs.sh` now derives these expectations from the code rather than pinning another list that drifts.

## 2026.8.6

### Added

- **Mail wakes: an exchange between two sessions no longer waits for a keystroke.** Unread cross-session mail now takes a turn. A session that has just finished work is woken at that boundary; a session already parked at the prompt is woken by Claude Code's own file watcher noticing the delivery, so agent-to-agent work advances with nobody at the keyboard. The idle wake arrives as a system-reminder rather than as synthesised typing — the objection that ruled out driving the recipient's terminal. It fires once per arrival, never for `task` kind (the walk-away queue already owns those), never while a drain is running, and only in the launched conversation, since teammates share one mailbox and would otherwise race to consume the same message. `CS_MAIL_WAKE_MAX` (default 5) bounds wakes between prompts so two corresponding sessions cannot volley indefinitely, and `CS_NO_MAIL_WAKE=1` silences the wake without swallowing the message — a silenced arrival is still announced once the silence lifts.

- **Mail threads.** Every message now carries a thread id, and the sender keeps its own copy of what it sent, so an exchange can be re-read from either end — including after a rotation, where an agent previously had no way to find out what it had already said. `cs -msg --reply <thread> "body"` answers without naming the peer: the target comes from the thread, and naming a different one is an error rather than an override, because accepting it would misroute the reply on a typo and poison every later derivation. `cs -msg thread <id>` prints the conversation ordered by what answers what — timestamps cannot order it, since a question and its reply normally land inside the same whole second — with anything the walk cannot reach shown separately as living on another machine.

### Performance

- **The mail wake no longer forks a grep per unread message on every turn end.** The snapshot of already-announced messages is read once and matched in-shell; with 30 unread that is 272.8ms down to 167.8ms per turn end. It also mattered more than the average suggests, because the wake ceiling deliberately leaves mail sitting in `new/` while turns keep ending, and each idle-wake arrival re-scanned the whole directory — so a burst of N deliveries cost N(N+1)/2 forks. A watched-file event the hook does not own — including the one fired per message as `cs -msg` moves mail to `cur/` — is now rejected on the path's shape before the session is resolved at all.

### Fixes

- **A single unreadable message could hide every thread in the mailbox.** `jq` treats a JSON parse error as fatal to the whole invocation and never opens the files after it, so reading the thread index in one pass meant one torn document silently dropped every later one across `new/`, `cur/` and `out/`. The visible effects were worse than a missing line: a reply stamped the wrong parent, and the guard that refuses to answer a thread naming two correspondents could be defeated into delivering to the wrong session. Thread reads fall back to reading documents individually, as every other reader in the mailbox already did.

## 2026.8.5

### Fixes

- **Concurrent mail and queue delivery could interleave into garbage — or into the drain.** Both `cs -msg` and the walk-away queue delivered by appending a line to a shared file, but bash's `printf` flushes large bodies in ~1KB chunks, so simultaneous senders (a spawn fan-out finishing together is the normal case) spliced each other's lines: measured, four concurrent senders left only 112 of 200 lines intact. Torn mail was silently discarded by the tolerant readers; a torn queue line was worse — the drain executes what it reads. Delivery is now atomic by construction: mail is a per-message maildir (`mail/tmp/` → rename into `mail/new/`; `cs -msg` moves what it prints to `mail/cur/`), and the queue is one file per task staged the same way, popped by moving the lexically first entry aside (atomic against a second drain). Unread mail is simply the count of `new/*.json` — the same basis in `cs -msg`, the prompt digest, the status line, and the TUI — and the old `seen` cursor arithmetic is gone.

- **Upgrading could destroy queued tasks and leave the session unopenable.** The pre-directory layout used `.cs/local/queue.tmp` as a temp *file*, so a killed `cs -queue rm` or drain pop left a regular file exactly where the new staging *directory* goes. `mkdir -p` failed over it, aborting every entry point that converts — including session open — and the converter then deleted the legacy file anyway, taking the tasks with it. A non-directory at that path is now cleared, and neither converter drops its legacy file until every record has actually landed.

- **An interrupted mailbox migration duplicated mail on the next open.** Converted filenames depended on the migration's own clock, so a retry no longer recognised what it had already delivered and wrote a second copy beside it; a message read in between came back as unread. Names now derive only from the legacy content, and a record already present in `new/` or `cur/` is skipped.

- **A stranded conversion file could splice two queued tasks into one.** An interrupted run can leave a file whose last line has no newline; folding a fresh queue onto it concatenated the two, and the drain executes what it reads. Requeuing after such a failure also no longer re-runs a task the drain already completed.

- **The TUI could edit or delete a different task than the one shown.** The Notes panel skipped entries it could not decode while the editor and delete key addressed tasks by position in the unfiltered list, so a stray file sorting first shifted every index: `d` on the first row removed the stray and left the real task, and editing overwrote the stray instead. Both paths now read the same list.

- **The unread-mail digest could go silent, or grow without bound.** A window of documents that failed to parse suppressed the digest entirely while the status line still counted them, so a session was never told it had mail. The five-message bound also counted files rather than messages, letting a single crafted document inline unbounded text into every prompt. The header now always reports, the bound applies to rendered messages, and the overflow count matches what was shown.

- **A failed `task`-kind send could queue the same task twice.** Mail carrying a task queues the work first and records attribution second. If that second step failed, the sender saw an outright failure and retried, queuing the work again. Those paths now warn and keep the delivered task.

- **A blank line in a spawn seed aborted the session launch.** A whitespace-only task line reached the queue's empty-body check and failed the whole launch; it is now skipped.

### Changed

- **Mail bodies may now be 64KB, and `cs -msg <session> -` reads the body from stdin.** The 4096-byte cap guarded the corruption window above; with delivery atomic it only bounds render cost, so it rises to 65536. Over-cap bodies still error rather than truncate. The stdin form is what makes the larger cap practical — a multi-KB handoff does not belong in argv.

### Docs

- `docs/hooks.md` described the mail digest in terms of the `inbox.jsonl` file and its `seen` cursor, neither of which exists any more.

## 2026.8.4

### Fixes

- **`cs <base> --merge <feature>` refused over the files cs itself wrote.** In ignored mode cs bootstraps a `.cs/` skeleton into the worktree and writes `.claude/settings.local.json`, but only `CLAUDE.local.md` was excluded from git. Any project whose `.gitignore` never named `.cs/` therefore got a worktree full of untracked cs bookkeeping, and the merge preflight refused with a list the user could neither commit nor safely delete — the ignored-mode fusion needs those records, and they carry the feature session's timeline, narrative and memory.

  The preflight now skips cs's own bookkeeping, which unblocks worktrees that already exist. The removal step already passed `--force` for exactly these files, and its comment already described the preflight as ignoring them; the two halves of the function now agree. New ignored-mode worktrees also exclude the skeleton at creation, so `git status` stays clean while you work in them.

  Untracked work the user would actually lose still refuses, and the refusal still names the file.

## 2026.8.3

### Fixes

- **`/rotate` recorded the wrong parent on a second rotation.** The skill took the conversation UUID from `$CS_CLAUDE_SESSION_ID` and fell back to `.cs/local/state` only when that was unset. The two agree until the first `/clear` and diverge after it: cs exports the env var once per process and never refreshes it, while the SessionStart hook rebinds `claude_session_id` on every fresh conversation. A second rotation therefore wrote the grandparent as `parent:`, which also weakened the check that supersedes stale handoffs by matching `parent:` against the session log. The skill now reads the state file first and says why the env var is only a fallback.

The env var's staleness is deliberate and unchanged: `session-start.sh` keys its ref-rename guard on `CS_CLAUDE_SESSION_ID` still naming the current process's predecessor, which is what stops one conversation stripping a live sibling's crash-recovery snapshot.

## 2026.8.2

Layout fixes for the merge readiness screen shipped in v2026.8.1, found by looking at it on a real terminal and by reviewing that fix before tagging.

### Fixes

- **The merge screen fills its terminal.** Both panes were fixed heights, so a tall terminal left everything below the two cards unused. The list stays sized to its features and the detail pane takes the remainder. The same change covers the short end: the pane holding the finish plan cannot scroll and its last line is the destructive step, where the list does scroll, so the plan can no longer truncate.
- **The header hairline stays inside the list card.** It was drawn one row below the card's interior top without checking that the row was still inside the card. On terminals between 8 and 19 rows the list shrinks past that point and the rule painted across the detail pane's text, leaving a line like `branch cs/light-theme` with a rule running off its right.
- **A list too short to show any feature names the count.** Below a six-row list no feature row fits, so the card rendered empty while features were pending. The title now reads `<base> · features (N hidden)`, which costs no rows and so does not compete with the plan for space.

## 2026.8.1

Closing out a feature worktree used to mean remembering what each `base@feature` session was for and guessing whether it was safe to merge. The picker now answers that, and hands the merge itself to the ritual that can diagnose a failing gate.

### Features

- **Merge readiness screen** in the picker, on `m`. Replaces the panes with a base's feature worktrees and why each can or cannot merge: commits ahead, a dirty tree, untracked files, a live lock, already merged. The detail pane names what finishing will do, down to whether the merge fast-forwards or writes a merge commit, and which side holds a lock. Enter leaves the picker and runs `cs <base> -finish <feature>`; the picker never merges anything itself.
- **`cs <base> -features [--porcelain]`** lists a base's feature worktrees with that same readiness. Readiness is computed by the shell functions the real merge gates call, so the screen cannot disagree with the refusal a merge would produce. `--porcelain` emits one tab-separated record per feature.
- **`cs <base> -finish <feature>`** opens the base session with `/merge <feature>` armed. `--merge` remains the mechanical git step; `-finish` runs the ritual around it, so a failing gate gets diagnosed instead of just stopping.
- **`/merge` gained a third context**: invoked in a base session with a feature name, it runs the preflight gates inside the worktree, merges from the base, and runs the post-merge gates there.

### Fixes

- A linked worktree's `.git` is a file holding a `gitdir:` pointer, not a directory. Two independent probes tested only for a directory, so every `base@feature` row showed no repo and no contributors: exactly the rows a merge screen is about.
- The picker forks cs for its own subcommands and hardcoded a bare `cs`, which a cs installed outside PATH could never reach. cs now exports its own path.
- The masthead painted its live count in the liveness teal even at zero live sessions.
- The session-start sibling block named `cs -msg <session>` without its syntax, which announced a capability without supplying it and cost a `cs --help` call on every send. It now carries the full send form and the `--kind` values, and only when a sibling exists to send to.
- Feature discovery and the `-finish` existence check anchored their match on one side, so `myproj@wip` verified against a registered `myproj@wip-2`.
- The finish plan branched on a readiness flag that excludes the case `merge_worktree_session` treats as already merged, so a branch sitting at base HEAD was promised a fast-forward while cs removed the worktree instead. It now branches on the verb's own condition, keeps both gate passes in every plan, and puts removal in the merge step where cs actually does it.

### Docs

- README documents the merge screen, `-features`, and `-finish`.
- `docs/hooks.md` records the send form in the session-start context block.
- Design spec and implementation plan under `docs/superpowers/`.

## 2026.7.29

A regression fix for v2026.7.28, and the resume safety it exposed.

### Fixes

- **Only the conversation `cs` launched may rebind the session's recorded UUID.** Since v2026.7.28 made hooks resolve a session by walking up from the opened directory, every claude in the tree could take that single slot — including agent-team teammates, which are full claude processes with their own top-level SessionStart (the existing guard catches in-process subagents only). A teammate working in a session subdirectory took it, leaving `cs <name>` resuming a reviewer's conversation and `.cs/timeline.jsonl` recording a lineage that never happened. Identity is now the process: `cs` exports the pid it hands to claude and the hook matches it against Claude Code's `CLAUDE_PID`. Both launch shapes count — the fresh-spawn arms `exec`, so claude carries cs's pid, while the resume arm runs claude as a child and cs is its parent. Environment cannot answer this on its own: children inherit exports, so a teammate carries the value while owning a different pid.

- **A conversation newer than the recorded one is reported instead of silently skipped.** Because only the launched conversation is recorded, one started another way on the folder — a `/desktop` handoff, a `claude` opened on the directory — leaves the recorded UUID naming an older conversation. That UUID still resolves, so `--resume` succeeded and the quick-failure fallback never fired: the launch continued a superseded prefix with nothing said. The launch now names the newer conversation and the command to reach it, without switching to it, and checks the clock rather than assuming.

- **A teammate's conversation is never offered as the session's own.** A teammate started with the session as its working directory writes a top-level transcript into the same project dir as the lead, indistinguishable by filename and routinely the newest. Discovery now skips them for every caller, so neither the notice nor the session's recorded UUID can land on a reviewer's conversation. A lead that merely *received* teammate reports is not mistaken for one: the frame appears mid-file there, and only a teammate's own brief is its first user turn.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.7.28...v2026.7.29

## 2026.7.28

cs hooks now work in front ends other than the `cs` launcher, Claude Code desktop among them.

### Features

- **A session is any directory containing `.cs/`.** Hooks used to identify their session purely from environment variables that only the `cs` wrapper can export, so under any other front end every hook silently did nothing. They now fall back to walking up from the opened directory for the `.cs/` that marks a session root. The environment is still tried first, so a `cs`-launched session behaves exactly as before and never reaches the walk. Measured against Claude Code desktop: hooks fire, project and user settings are both read, the filesystem is real and unsandboxed, and `autoMemoryDirectory` already pointed memory into the session — but `CLAUDE_ENV_FILE`, though offered and writable, propagates to nothing, so no hook can publish the contract to the rest of the session. Hence resolution from the directory rather than the environment.

  This also ends a quieter gap: a session started outside `cs` at all — an IDE, a plugin, plain `claude` in a session folder — was cs-blind. It no longer is. The nearest `.cs/` wins, so a session cloned inside another belongs to itself; the walk stops at `$HOME` so a stray `~/.cs` cannot adopt everything beneath it; and there is no `$PWD` fallback, because a hook's working directory is wherever the front end left it rather than a statement about which session is open.

- **`.cs/local/disabled` opts a directory out.** Present, the hooks decline as though it were not a session, whichever front end opened it.

### Fixes

- **A second front end no longer removes a live session's lock.** Because hooks now resolve from the directory, SessionEnd is reached for sessions this launch did not start; it removed `.cs/session.lock` unconditionally. Closing a desktop conversation on a directory a CLI session was live in stripped that session's lock, letting `cs <name>` open a duplicate with no collision menu and leaving prose-lint inert mid-session, since the cutoff file it tests for was gone. Only `cs` writes a lock, so only a `cs` launch clears one unconditionally; a walked-in hook clears it only when the recorded process is gone, so a crashed session is still never left locked out.
- **The sessions index is written only where sessions live.** `CS_SESSIONS_ROOT` is never exported into a session, so SessionEnd fell back to the session's parent directory — right for a session under the sessions root, wrong for an adopted one, whose directory is an unrelated project path and whose parent then received a stray `index.md`. Both sides of the containment test are now compared physically, so a `$HOME` reached through a symlink still matches its own root.
- **A missing, unreadable, corrupt, empty, or runtime-failing resolver library degrades to the old behaviour instead of killing the hook.** The library is parse-checked before sourcing and `errexit` is suspended across it, because a failure inside a sourced file fires before any outer `||` can catch it. An exit of 2 from a `PreToolUse` hook is Claude Code's blocking code, so a partial install had to degrade to "cs is inactive", not "tool calls are blocked".
- **Hook tests no longer resolve a real session.** No suite cleared `CLAUDE_PROJECT_DIR`; with one ambient, hooks under test bound to a live session. Some assertions false-failed, and `tool-failure-logger`'s silence assertion passed while the hook appended to that session's log.

### Docs

- `README.md` documents working outside the launcher; `docs/hooks.md` gains a section on how a hook finds its session, plus the lock-ownership and index rules; `docs/session-layout.md` documents `.cs/local/disabled`.

## 2026.7.27

A durable memory entry can no longer tell Claude it is talking to the wrong person.

### Fixes

- **Session start names the current actor.** `.cs/memory/` is a single durable store shared by every actor on a git-synced session, while only `narrative.<actor>.md` files are partitioned per actor. A `type: user` entry written by one actor as an unconditional claim ("the user is X, not Y") therefore loads for every other actor and reads as settled fact — in one case out-arguing four contradicting live signals for a whole session, including a global instruction naming the right person. The hook now states the current actor and its narrative file up front, and adds the rule that an entry naming someone else was written by or for another actor. A bare identity line would not have been enough: the instruction that lost was already ambient in context, so the anchor carries its conflict-resolution rule with it.
- **Identity facts must be keyed to a person.** `/sweep` now requires facts about a person to be written keyed (`actor <slug> is …`) rather than asserted about whoever is present. A keyed fact stays true on every machine and cannot be misapplied, because it never claims anyone is present. The rule covers `MEMORY.md` pointer lines as well as entry bodies: pointers load at startup while the entries they name are read lazily, so a poisoned pointer reaches context on its own even if nothing opens the file.
- **The hook's actor resolution matches `cs`.** It tested emptiness where `cs_actor_slug()` uses `if/elif/else`, so a pinned `.cs/local/identity` that exists but is blank fell through to git config while `cs` stopped at the file existing and resolved `unknown`. The hook then named `narrative.<git-identity>.md`, a file `cs` never writes. Found by review before release.

### Docs

- `docs/hooks.md` documents the identity anchor and why the actor precedence is duplicated rather than sourced or shelled out.
- `docs/session-layout.md` states that the durable buckets are shared across actors while the narratives beside them are not, which is the confusion behind the defect.

## 2026.7.26

### Fixes

- **A disarmed rotation marker no longer points at a handoff that is gone.** v2026.7.25 stopped the `d` answer claiming the handoff it had just discarded was still pending, but keyed the notice on which answer was given rather than on whether a handoff actually survives it. The wrong wording therefore remained on the `r` fallthrough (reached precisely because no handoff was offered) and on `n`, `Y`, and the unattended default whenever the marker was orphaned, meaning its handoff had already been consumed elsewhere. In each of those the notice offered `r` for something that no longer exists. The notice is now chosen by the handoff that is still pending after the answer, which is the condition it was always describing.

## 2026.7.25

Rotating a heavy conversation into a fresh one no longer means leaving Claude Code.

### Features

- **Rotation happens in-process.** The `rotate` skill now arms the handoff it writes (naming it in `.cs/local/pending-handoff`), so rotating is `rotate` then `/clear` — no exit, no relaunch, no keypress at the resume prompt. The old exit → relaunch → `r` route still works and is documented as the alternative for when you are stopping anyway; both converge on the same marker. A `/clear` rotation records `reason: handoff` with the handoff name in `cs -conversations`, where it previously appeared as a bare `rebind`.
- **A second rotation retires the first.** The skill flips its own still-pending handoffs to `superseded`, so a stale one can no longer keep the launch prompt offering `[Y/n/r/d]` for context that is out of date. Superseding is scoped to the current checkout, so a co-developer's pending handoff is never touched.

### Fixes

- **A compacted conversation is no longer told it is a clean break.** `CS_FRESH_REBIND=1` is exported before `exec` and so outlives the launch for the whole process, while the notice consuming it had no source gate. Any session launched via `n`, `r`, or a resume failure and then `/compact`-ed was instructed that its transcript was not loaded and not to assume continuity — inside a conversation that had continued uninterrupted. The notice now fires only where the conversation genuinely starts clean: a `/clear`, or a `startup` that rebound to a fresh UUID.
- **Handoff consumption checks the handoff's status.** It previously gated only on the marker naming a file that exists. With the marker now armed a turn or more before it is used, a handoff already consumed elsewhere would have re-injected its preamble while the status flip silently did nothing. Consumption additionally requires SessionStart source `startup` or `clear`; on any other source the marker is left untouched, so a compaction or a context-limit fork between arming and rotating cannot eat a pending rotation.
- **A declined rotation is disarmed, and says so.** Answering `Y`, `n`, or `d` at the resume prompt — or the unattended `cs -spawn` default — drops the marker with a one-line notice. Left armed it would have been consumed by an unrelated `/clear` hours later.
- **The already-running guard survives a `/clear`.** It matched only the recorded UUID against `ps` argv, which an in-app `/clear` rebinds while the live process's argv still names its launch UUID — so a second `cs <name>` could attach to a live conversation. The session name is matched too, delimited so a name that prefixes another cannot collide.
- **Discarding a handoff no longer says it stays pending.** Answering `d` retires the handoff, but the disarm notice went on to offer rotating into it later — guidance that holds for every decline which leaves the handoff file untouched, and contradicted the discard notice printed on the very next line.
- **A marker naming a path is rejected.** A `pending-handoff` containing a basename with `/` or `\` is refused rather than resolved, so a marker cannot direct the hook to rewrite a file outside `.cs/handoffs/`.

### Docs

- `README.md`, `docs/hooks.md`, and `docs/session-layout.md` document the in-process route, the consumption predicate, and the `pending-handoff` marker.
- The design rationale is recorded in `docs/superpowers/specs/2026-07-27-in-process-rotation-design.md`, including why the `initialUserMessage` phase was dropped: the SessionStart hook output field is stored in a module global whose only reader runs once at REPL bootstrap, so a value emitted on source `clear` is never read. The post-`/clear` conversation therefore waits for your first message rather than acting on its own.

## 2026.7.24

### Added

- **`mail` status-line segment.** The status bar now shows unread cross-session mail for the current session as `✉ N`, right after the notes queue, matching the TUI's badge. Unread is the count of newline-terminated `inbox.jsonl` lines past the `seen` cursor that `cs -msg` advances on read (a half-written final line is not counted). Hidden when nothing is unread. Amber, like the notes badge.

### Changed

- **A session stays aware of unread mail until it reads it.** The prompt hook now inlines the bodies of unread cross-session mail on *every* prompt (bounded to 5 messages, sender and body truncated) until `cs -msg` reads them — replacing the old surface-once digest that announced each message a single time and then went silent while it was still unread. Keyed on the `mail/seen` cursor, so the awareness clears exactly when the mail is read. A `task`-kind message shows a count-only label (it is already queued; inlining the body would double-execute), and the session-start hook no longer duplicates the digest. The `mail/notified` cursor is retired.
- **The status line's trailing gradient no longer floods with the limit color.** The full-width tail fade now anchors on the neutral surface tone instead of the last segment's own color, so an amber/red rate-limit block near a limit no longer paints the whole empty end of the bar. (Surfaced after `cost` was dropped from the default order, which had left the escalating `wk` block as the last segment.)
- **Rate-limit reset countdowns are gated on usage.** The `· 2h14m`-style time-until-reset suffix now appears only as a window fills: the 5-hour block shows its countdown at 50% usage and up, and the weekly block gains a countdown of its own, shown at 80% and up. Below those thresholds the blocks read `5h 30%` / `wk 41%` with no suffix, so the bar stays quiet while there's headroom. Countdowns past a day read in days+hours (`5d16h`) instead of raw hours (`136h14m`).
- **`cost` is off by default.** The default segment order drops `cost` (now `logo,session,notes,mail,pane,git,model,ctx,limits`). The segment still exists — add `cost` to `CS_STATUSLINE_SEGMENTS` to show session cost again.

### Docs

- Updated README and the statusline, hooks, session-layout, and configuration docs for the mail segment, persistent mail awareness, reset gating, and gradient behavior.

## 2026.7.23

A crash-recovery correctness and data-safety pass, plus an in-session worktree merge, a snappier resume prompt, and faster Windows CI.

### Fixes

Crash recovery is now per-conversation and refuses unsafe restores:

- **Autosave is keyed per conversation.** The single shared autosave ref (`refs/worktree/cs/auto`) is replaced by one ref per conversation (`refs/worktree/cs/session/<uuid>`). Two sessions open on the same checkout — or parallel worktree sessions — no longer read, write, or delete each other's snapshot chain. This removes a false "CRASH RECOVERY: previous session ended without saving" prompt that fired when a second concurrent session started, and the near-miss it set up: a blanket whole-tree restore over another session's divergent history.
- **A whole-tree restore is refused when HEAD has moved.** Each snapshot records the HEAD it sits on (a `cs-base` commit trailer). Recovery offers the `checkout <ref> -- .` restore only when that base still matches the current HEAD; if HEAD moved (a commit or rebase) or the snapshot predates base recording, it warns and points at per-file inspection instead of overwriting committed work. The offered command self-guards, so it stays safe even if HEAD moves between the prompt and the run.
- Each conversation recovers and deletes only its own ref; session-end deletes only the ending conversation's ref; a live sibling's in-flight ref is never misread as a crash. Foreign conversation refs older than 14 days are garbage-collected, the rebind across a context-fork UUID change is gated on process identity, and every ref mutation is a compare-and-swap so a concurrent session can't be clobbered.
- De-flaked the worktree env-capture test (it could capture empty output under runner load).

### Features

- **In-session worktree merge.** `cs <base> --merge <task>` now runs from the owning base session instead of forcing a close-session → free-terminal → reopen hand-off. A live lock is exempted only when it is the invoker's own — the session name matches *and* the lock PID is in the caller's process ancestry — so a foreign session's lock, or a stale PID reused by an unrelated process, still refuses. A live feature worktree can never be exempted, so removing a worktree out from under a running session stays impossible. Merging from *inside* the feature session still hands off (it cannot delete its own working directory). The `--merge` task argument is now validated like the launch path.
- **Single-keypress resume prompt.** The "Continue previous conversation? [Y/n/r/d]" prompt responds to one keypress with no Enter, and ESC cancels the launch.

### Performance

- **Windows CI test lane sharded four ways** (~18 min → ~8 min), and dead `sleep`s removed from the shadow-ref tests.

### Docs

- `README` documents the in-session merge; the `/merge` skill leads with it and hands off only from inside the feature session.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.7.22...v2026.7.23

## 2026.7.22

Windows support, and a security and data-integrity pass over `cs -secrets` that matters on every platform.

### Breaking

- **`cs -secrets export` namespaces every variable.** A secret named `api_key` now exports as `CS_SECRET_API_KEY`, not `API_KEY`. Update anything that evals the output and reads the bare name.

  This closes a code-execution hole rather than tidying the format. A secret name became a shell variable name directly, so a name like `path`, `prompt_command`, `editor` or `ld_preload` landed on the real `PATH`, `PROMPT_COMMAND`, `EDITOR` or `LD_PRELOAD` when the documented `eval "$(cs -secrets export)"` ran. Sync files are meant to be committed and shared, so a name could come from anyone who could write one. Refusing dangerous names was tried first and does not hold: they are ordinary words, and enumerating them leaked repeatedly. The namespace removes the collision entirely.

### Security

- Secret names are validated. A name must be an identifier, so it cannot carry shell metacharacters that break out of the assignment and execute when the export is eval'd. Enforced when storing, when importing a sync file, and when migrating between backends, and again at export so a store written before this release cannot execute either.
- Two names that would export as the same variable (`api_key` and `api-key`) are refused instead of both emitted, since eval takes the last and a sync file could otherwise shadow a real secret with an attacker's value.
- `cs -secrets export` emits nothing at all when it refuses. It previously printed assignments as it went, and `eval "$(...)"` applies whatever reached stdout regardless of exit status, so a refusal could still have applied the value it was refusing.

### Features

- **Windows support, in two tiers.** WSL2 is the recommended, full experience: session launch, the tmux spawner, secrets and the TUI all work. Git Bash / MSYS2 runs session management, secrets and the TUI, but refuses the Claude launch and the tmux spawner with a "use WSL" message rather than half-starting them. A `cs_platform()` seam detects `macos|wsl|msys|linux`, overridable with `CS_PLATFORM_OVERRIDE`.
- **Windows Credential Manager backend for secrets.** Selected automatically on native Windows when `powershell.exe` is available, else the encrypted-file backend. Secrets and metadata travel by environment and stdin, never argv, so they stay out of the process list.
- **`cs-tui.exe` on Windows.** The installer fetches it on Git Bash / MSYS2, and it ships as a signed, checksummed release asset alongside the macOS and Linux binaries. Installing on one platform removes a stale binary for the other, so PATH cannot resolve the wrong one.
- **`cs -h` marks WSL-only commands** when running under MSYS, instead of listing commands that will refuse.

### Fixes

Secrets durability, on macOS and Linux too:

- Concurrent stores no longer lose updates. Store, delete, purge and export serialize on a per-session mutex; previously two writers could read the same state and the later commit silently discarded the earlier one.
- The encrypted store, the sync export and the first-use salt are written atomically. A failed encrypt, a full disk or an interrupt can no longer truncate an existing store or backup.
- A store or delete whose write fails now aborts instead of reporting success.
- A merge import aborts rather than overwriting a secret it merely failed to read.
- `migrate --delete-source` removes only the keys it migrated, never a blanket purge that could drop a concurrently added secret.
- Backend read failures are surfaced rather than swallowed or read as an empty store, across every backend.

Windows correctness:

- Multi-line secrets (PEM keys, JSON blobs) round-trip byte-exactly. Values are read through base64 rather than jq's text output, which emits CRLF on Windows and previously added a carriage return at every interior newline.
- Secret names survive a read on Git Bash. jq emits CRLF and the shell strips only the trailing pair, so every name but the last carried an invisible carriage return into the backend.
- The machine identifier no longer collapses when `USER` is unset (Git Bash exports `USERNAME`), which had made every machine share one sync file.
- `cs -doctor` classifies worktrees correctly on Windows, where git prints drive-letter paths that never matched the shell's.
- Repos cs creates pin `core.autocrlf` off, so a CRLF `.gitignore` cannot silently match nothing.
- The status line and doctor strip CRLF from jq output.

### CI

- The Git Bash / MSYS2 suite is a required gate, running all suites on `windows-latest`. `cargo test` for the TUI runs on Windows too.
- Hyphenated tags publish as pre-releases, so a release candidate never becomes the version installers resolve.

## 2026.7.21

### Features
- Open an existing feature from the already-open menu. Typing `cs <base>` while that session is already open now lists the base's existing feature worktrees as numbered options (pick one to resume it), alongside force / new feature / cancel.
- Session-color header pill. The menu header renders the session name as its `/color` pill with the Claude mark, and the whole flow (menu, feature-name prompt with a result preview, and the uncommitted-changes warning) shares one indented frame.

### Changed
- Worktree terminology is now "feature," not "task," across every user-facing surface: the launch menu, `cs -h`, the SessionStart/SubagentStart contracts, the generated worktree README, validation errors, `--merge` usage, the README, docs, and the TUI base-preview label. The walk-away `-queue` task, the `cs -msg` task kind, and `cs -spawn --task` keep "task" (distinct concepts).

## 2026.7.20

### Features
- Handoff launches auto-start. Answering `r` at the resume prompt (a fresh conversation continuing from a rotation handoff) now reads the handoff and continues on its first turn, no first message needed. It rides the same launch-prompt rail the `/color` re-apply already uses.

### Performance
- Lighter statusline hot path. Each per-render invocation now shares one clock across the limits stamp, countdown, and attention pulse (down from up to three `date` forks), and counts the task queue with a fork-free bash loop instead of an `awk` fork, taking roughly 9 to 10 external forks per render down toward 6 to 7.

### Fixes
- Statusline clock hardened: sanitized against inherited environment state and normalized to base-10, so a leading-zero pin cannot trip bash octal arithmetic.
- Removed a dead `force` variable in `cs -update`.

## 2026.7.19

### Fixes
- The statusline follows a mid-session terminal theme switch on macOS (system auto dark mode). It reads the live OS appearance each render instead of a value frozen at launch, so the palette no longer stays light on a terminal that has gone dark. Setting `CS_TERM_THEME=light\|dark` yourself still pins the theme and wins everywhere, including against live detection; launch marks its auto-detected value (a `CS_TERM_THEME_AUTO` presence marker) so the two are distinguished, and off macOS the launch value still applies. The stale launch background RGB is dropped after a live switch so the gauges and gradient fall back to theme-based colors instead of tinting toward the old background; a session already open on a non-macOS terminal keeps its launch palette until relaunched.

## 2026.7.18

### Features
- **Discard a pending rotation handoff** — the resume prompt gains a `d` answer (`[Y/n/r/d]`) that flips a pending handoff to `status: discarded` and resumes normally, so a handoff you no longer want stops being offered.
- **`cs -live` and `cs -usage` show heartbeat-live sessions** — conversations opened outside cs (a fresh statusline heartbeat within the 900s window) now register as live on these display surfaces, matching the TUI. The destructive guards (`cs -rm`/`-archive`/`-spawn`) stay on the strict PID lock, so a session whose process is gone is still removable without `--force`.
- **TUI unread-mail badge** — a session with unread cross-session mail (`cs -msg`) shows an amber `✉` and the count in its row, cleared as the recipient reads with `cs -msg`.
- **`cs -doctor` spawn hygiene** — new checks warn on accumulated `.spawn/*.seed.stale` files (nothing prunes them), a pending seed with no session (blocks re-spawning the name), a `spawned-by` pointer at a deleted session, and a tmux session named `cs` that cs did not create.
- **Completions** — `cs -msg`/`cs -spawn` complete a target session as the first argument; `-rm`/`-archive`/`-unarchive` complete session names at every position, not just the first.
- **switch-client attach hint** — `cs -spawn` from inside tmux suggests `tmux switch-client -t cs` (attach refuses to nest); plain `tmux attach -t cs` otherwise. The SessionStart sibling block points at `cs -msg` for reaching another session.

### Fixes
- `cs -rm` refuses a live (PID-locked) session unless `--force`, matching `cs -archive`.
- Session deletion (`cs -rm` and the TUI) discards the session's pending spawn seeds, so a re-created same-name session no longer inherits dead armed tasks and `cs -spawn` stops refusing the name.
- `cs <name> -msg log` and a bare `cs <name> -msg` now error with a read hint instead of sending the literal body `log` (the session-scoped alias is send-only).
- `cs -doctor` no longer aborts before its later checks and summary when a spawn check warns (a `set -e` return-value bug).
- The TUI unread-mail count reads raw newline bytes, so an invalid-UTF-8 torn inbox line no longer collapses the count and hides unread mail.

### Internal
- Removed the unused `--ref` flag and `ref` field from cross-session mail; the spawner correlates via `spawned-by` and `ref` had no producer or consumer.
- TUI session liveness is modeled as a `Locked`/`Heartbeat`/`Dormant` enum, making the illegal "locked but not live" state unrepresentable.
- Retired the benign spawner-hardening backlog (seed check-then-write race, `.stale` clobber, seed-format split, duplicate-window check) with in-code notes so no future review re-fixes a non-bug.
- Liveness loops read the clock once (threaded `now`), and the `@cs_managed` ownership check is shared between the spawner and the doctor.

### Docs
- README lists `cs -msg`/`cs -spawn`, `-rm --force`, the heartbeat-aware `cs -live`, and the unread-mail badge; the rotate skill and session-layout doc describe the `d` discard answer and the `status: discarded` handoff state.

## 2026.7.17

### Features
- **Cross-session mail** — `cs -msg <session> "body"` drops a typed message (`--kind notify|task|text|result`) into another session's machine-local mailbox; `task` also lands in its walk-away queue. Recipients see a short digest at their next turn and read with `cs -msg` / `cs -msg log`.
- **tmux spawner** — `cs -spawn <name> [--task "..."]...` opens a session in a cs-owned tmux session (`tmux attach -t cs`); `--task` seeds and arms its walk-away queue so it works unattended, and the spawner hears back over cross-session mail when the queue drains. Completes the machine-local comms roadmap: presence → mail → spawner.
- **Multi-name session verbs** — `cs -rm`, `cs -archive`, `cs -unarchive` accept several names; each removal keeps its own confirmation.
- **/release correctness gate** — the release ritual gains a code-review step between /simplify and the test run.

### Fixes
- tmux targets are anchored to the exact `cs` session on resolver commands, with plain targets on `set-option`/`show-option` — tmux 3.6a rejects `=` anchors there (found by live smoke test).
- Empty session names are rejected before any multi-name verb acts (release-gate catch: `cs -rm name ""` previously resolved the empty name to the sessions root itself).
- Queue digest reads are bounded to a pre-counted newline total, so a torn final notification line can no longer be silently skipped.

### Docs
- Mailbox and spawner coverage across README, session layout, and hooks; `CS_TMUX_BIN` override documented.

## 2026.7.16

### Features
- **TUI pane-first layouts** — the stacked view gives the list 25% and the panes the rest; the side-by-side view gives the panes column 55%
- **Header symbol legend** — `● activity  ■ live  * marked  archived` sits beside SESSION in the header's free width (auto-hidden when narrow); the `?` overlay reworded to match, with the archived entry self-demonstrating its dimming
- **Liveness** — the lock square is teal on every surface and breathes between two teal phases while the picker is active; a statusline heartbeat (`context-pct` mtime, 15-minute window) marks conversations opened outside cs as `■ live · unlocked` in the gutter, masthead count, and preview
- **Worktree nesting** — `base@task` sessions attach under their base with `├─`/`└─` connectors as indented `@task` rows, inherit the base's time section, and the preview names the lineage both ways (`worktree @task · off base` on the task, a `tasks` list on the base)
- **Voice** — every `/voice` draft gets a built-in anti-slop pass before delivery

### Fixes
- Both TUI panes carry two clear columns and title headroom (the to-do separator rule stays full-bleed)
- Full-size teal lock square replaces the tiny `▪`, which now uniquely means stored secrets; the preview state line uses the same square, and `dormant` shows a heat-colored dot with the word in grey, never teal
- Deleting a worktree session in the TUI (single or batch) unregisters it from the base repo's git instead of leaving a stale registration; the task branch is preserved
- Heartbeat probes the path production actually writes (`.cs/local/context-pct`)

### Docs
- README documents liveness, worktree nesting, and the header legend; heat-dot wording untangled from "live"; the session-locking bullet notes the heartbeat fallback
- session-layout records `context-pct`'s liveness-heartbeat role

### Other
- Simplify pass over the release stretch: shared session-removal path, single-sourced `base@task` parsing, borrowed attach-pass collections, typed state-row dot, one wall-clock read per frame, deduplicated test render boilerplate

## 2026.7.15

A maintenance release: a five-area redundancy audit executed end to end — drifted facts fixed, dead code removed, and five new drift tests so the fixed facts stay fixed.

### Fixes

- **Installer registers the full status line.** The install-time consent prompt registered only the main bar while `cs -statusline enable` also registered the agent-panel rows; consent now applies the same registration as the enable command, and the two recipes are marked KEEP-IN-SYNC.
- **`cs <name> -usage` forwards flags** like its sibling per-session verbs, so unknown options error instead of being silently swallowed.
- Help text names the `pane` segment in the statusline default.
- Stale doc facts corrected: the theme-detection cascade is stated once (statusline.md), README's queue verb list gains `log`, CONTRIBUTING drops a stale test census, configuration.md now lists every env var it claims to (queue breakers, context tiers, the iTerm2 kill switch, and more), and session-layout.md gains the `limits` and `failures` rows.

### Removed

- Dead code swept: an unused hostname helper, the statusline's leftover `_filesize` from the retired disc segment, two dead TUI items plus a no-op conditional, and the `b_preview` design spike whose frozen palette drifted from the shipped theme. The TUI build is warning-free again.

### Added

- Five sync tests turn accepted duplication into machine-checked duplication: the statusline segment default across its four sites, queue verbs vs both shell completions, the `_build_digest` hook twins, a state-writer/statusline-reader round trip, and hooks.md's registration JSON vs install.sh.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.7.14...v2026.7.15

## 2026.7.14

Nineteen features across three arcs: the council batch (five capabilities picked by a four-provider AI council), a post-batch arc of five, and a nine-task walk-away queue drain — the queue supervision built in this release running its own first production drain.

### Features

- **`cs -usage`** — per-session token attribution over rate-limit windows: fleet table with sorting and live markers, `cs -usage <name>` scoped view, windows anchored at rate-limit resets via the statusline's limits stamp.
- **Session tags** — `cs -tag` verbs on the README frontmatter, `cs -list --tag` filtering, TUI `#tag` search and preview tags row.
- **Session archive** — `cs -archive`/`-unarchive` with a tracked marker; archived sessions hide from lists, search, and the TUI (`A` toggles), and auto-unarchive on open.
- **Walk-away queue supervision** — circuit breakers (tool failures, context, rate-limit) park a bad drain; a notification inbox with a surface-once digest; `cs -queue log`.
- **Conversation rotation** — the `rotate` skill writes lineage-stamped handoffs to `.cs/handoffs/`, the launch prompt gains a third `[Y/n/r]` answer, SessionStart consumes the handoff, an 80% context nudge fires once per conversation, and `cs -conversations` shows the chain.
- **cs-tui B-prime redesign** — borderless table with wash/rail selection, masthead with hero rule, gradient-top cards, section dividers, palette tokens.
- **`/voice` skill** — distills your typed messages from Claude Code transcripts into an editable two-layer voice profile and drafts messages, replies, PR text, or docs as you; skills can now ship support files (`CS_SKILL_FILES`).
- **`/merge` skill** — the gated merge ritual: repo-discovered gates before, `--no-ff`, gates again on the merged result, cleanup only when green.
- **Session protocol moves to `CLAUDE.local.md`** — machine-local and gitignored, with lazy migration that never touches user-owned `CLAUDE.md` content.
- **TUI batch** — to-do input wraps to multiple rows and tasks display untruncated; preview pane padding; update badge with a `C` changelog overlay; `?` legend for gutter glyphs; 10-second auto-refresh with the selection pinned by name; the in-flight queue task carries a teal marker.
- **Statusline pane segment** — `◫ %7` tmux pane id from inherited environment, zero forks, usable verbatim as a tmux target.
- **iTerm2 awareness** — a finished turn bounces the dock until your next prompt (`CS_NO_ITERM2=1` disables); `cs -doctor` reports the surface.
- **Release notes on update surfaces** — the launch banner shows a summary card for a pending update, `cs -update --check` renders the full span.
- **`cs -secrets` session picker** — no session name on a TTY lists sessions and asks, with a CWD default.
- **60% context warning** — a one-time heads-up a tier below the rotation nudge.

### Fixes

- Usage: live-marker escapes, stale window anchors, torn transcript lines; doctor token sums deduped by requestId.
- Launch: terminal theme detected before the collision menu; the menu's force choice carries through the UUID guard.
- Worktrees: the merge verb hands off across the session lock instead of deadlocking.
- TUI: footer clipping, divider paint, input-lag loop; flaky `CS_VERSION` env tests serialized.
- Migration hardening: SIGPIPE-safe head probe, adopt pathspec, old-template heads migrate wholesale.

### Docs

Specs and plans for every feature under `docs/superpowers/`; `hooks.md`, `session-layout.md`, `statusline.md`, `configuration.md`, and the README refreshed to match.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.7.13...v2026.7.14

## 2026.7.13

One fix: the subagent statusline is now readable on light terminals.

### Fixes

- **Subagent statusline: readable on light terminals.** The agent-panel rows (`cs-subagent-statusline`) painted the agent name and meta with tokens meant for the main bar's dark pills (`chiptext` near-white, `hairline` light taupe), so on a light/cream terminal the name was near-invisible and the rest was faint. The row's foreground now adapts to the terminal theme — dark ink on a light terminal, unchanged light ink on dark.

## 2026.7.12

One change: the "session already open" prompt is now a single-keypress menu and looks the part.

### Changed

- **Locked-session menu: single-keypress `1`/`2`/`3`, restyled.** Opening a session that's already running now shows a prompt that reacts to one keypress with no Enter — `1` force start · `2` new worktree · `3` cancel (worktree sessions show just `1` force / `2` cancel) — restyled with the warm palette: a lock-icon header, colored option digits, and an aligned consequence column. Cancel stays the default, so a stray key never force-launches. Replaces the previous `f`/`n`/`c` letter keys.

## 2026.7.11

One fix: the interactive session picker (`cs-tui`) no longer feels laggy. Fast key-repeat, mouse-motion, and an unattended window all now behave.

### Fixes

- **cs-tui: killed the input lag and idle CPU churn.** The picker now drains the whole input queue before repainting — so fast key-repeat and mouse-motion no longer back up behind one-draw-per-event — redraws only when something actually changed, and blocks until the next event once the selection shimmer pauses after ~30s idle (an unattended picker now sits at 0% CPU). No key or behavior changes; it just feels responsive. Full renders were already sub-millisecond, so the fix is the loop architecture, not the render cost.

## 2026.7.10

One feature: a companion status line for Claude Code's agent panel. When you run subagents, the tree under your prompt now shows the model driving each one, its own context-window usage, and how long it's been running — the columns Claude Code's default `name · description · token count` row lacks. A recon agent at ctx 12% and a synthesizer dying at ctx 84% stop looking identical.

### Features

- **Styled subagent rows.** `cs-subagent-statusline` renders each running subagent with its model chip (in the bar's periwinkle), name, description, its own ctx% (escalating amber/red on the same thresholds the bar uses), and elapsed time. `cs -statusline enable` now registers both the bar and the rows; `cs -doctor` reports both. The rows keep rendering while you view an agent's transcript. Claude Code reads the registration at startup, so restart it to see them. Disable with `CS_SUBAGENT_STATUSLINE_DISABLE=1`.

### Internal

- `cs-subagent-statusline` sources `cs-statusline` in library mode (`CS_STATUSLINE_LIB=1`) for the shared palette and width helpers, rather than a third hand-synced copy.

## 2026.7.9

Two features and a batch of TUI fixes. `cs -live` and `cs -status` add the first phase of cross-session presence: see which cs sessions are running on this machine and what each is doing, all machine-local with no networked coordination. The interactive session manager gains in-place To-Do editing and full-width date dividers, plus fixes to mouse hit-testing, narrow-window layout, narrative reading, and preview loading.

### Features

- **See and share what your sessions are doing.** `cs -live` lists the cs sessions running right now on this machine, each with its actor, uptime, and a short status. `cs -status "…"` sets that status (`cs -status` reads it, `--clear` resets); when unset it falls back to the session's README objective. Machine-local by design: liveness is a local process fact, with no networked or cross-machine presence. This is Phase 1 of a planned cross-session communication feature.
- **Edit To-Do tasks in place.** The To-Do input is padded, long tasks render on one line with an ellipsis instead of wrapping, and editing a long task happens on its own row with a scrolling cursor and italic text so you can see where you are in the line.

### Fixes

- **Clicking the To-Do or detail pane no longer selects the wrong session.** The mouse hit-test checked only the session table's top-left corner, so right-pane clicks fell through and mis-selected a session by row. It now uses full rectangle containment.
- **Date separators in the session list span the full width.** The Today / Yesterday / Older group dividers render as full-width rules, and each session's date and age moved onto its own line, which also fixed a misalignment where a session's date sat on the divider above it.
- **Detail panes stack on narrow landscape windows,** with a height floor, instead of being squeezed beside the list.
- **The TUI reads every co-developer's narrative,** not just a single `narrative.md`, so shared-session activity from all actors shows in the preview.

### Performance

- **Session previews load off the render path** on a worker thread, so moving through the list stays responsive instead of stalling while a preview is read from disk.

### Docs

- Documented `cs -live` and `cs -status` in the README and the `.cs/local/` layout.

## 2026.7.8

Tab-completion now finds every session. Sessions adopted by symlink from a repo elsewhere on disk never used to tab-complete, because both completion scripts enumerated sessions themselves and neither followed symlinks. They now delegate to one internal enumerator, so completion can never disagree with `cs -list` about what a session is. The rest of the release cleans up completion edge cases, corrects a few documentation errors, and reshapes the README so newcomers meet the pitch before the glossary.

### Features

- **Symlinked sessions complete.** `find -type d` (bash) and `*(N/)` (zsh) both reject a symlink to a directory, so a session created with `cs -adopt` from a repo elsewhere on disk was invisible to the Tab key. Both scripts now call a new internal `cs -complete sessions` enumerator that follows symlinks and defines a session the same way `cs -list` does (a `.cs/` directory or a root `CLAUDE.md`).
- **Bare `cs <TAB>` offers sessions and flags together**, so the available commands are discoverable without knowing to type a leading `-` first.

### Fixes

- **Completion no longer mangles unusual session names.** An unquoted `compgen -W` word-split a name containing a space and glob-expanded one containing a `*` against the working directory; names are now matched as data.
- **Corrected TUI keybindings in the README.** Expand a row with `p` (the README said `Tab`); queue a task by focusing the To-Do input with `Tab` and pressing `Enter` (there was no `a` binding, and the badge is `▤ N`, not `[Nq]`).
- **Corrected the `CS_STATUSLINE_SEGMENTS` default** printed by `cs -help` (it omitted the `logo` and `notes` segments).

### Docs

- **README restructured for readability.** Resequenced so the pitch and quickstart come before the concepts glossary; advanced features (worktrees, task queue, machine-sharing) grouped under one heading; and the full environment-variable reference moved to a new [docs/configuration.md](docs/configuration.md).
- Added a CI status badge.

## 2026.7.7

The interactive session manager (TUI) now adapts to the terminal's shape. When the window is taller than it is wide, the preview and To-Do panes stack vertically below the session list — list on top, details in the middle, notes at the bottom — instead of sitting beside it. Wide terminals keep the side-by-side layout, and small windows still show the list alone.

### Features

- **Responsive TUI layout** — the session list, details/preview, and To-Do panes now arrange themselves by the terminal's aspect ratio (accounting for the ~2:1 terminal-cell shape): stacked top-to-bottom on portrait windows, side-by-side on landscape ones. The `p` key still toggles the detail panes.

## 2026.7.6

A CI-reliability release. The first run of the Test workflow on `main` surfaced environment gaps in the **test suite itself** — not product bugs. This release makes the suite portable across the CI runners and removes a parallel-test flake. **No user-facing behavior changes**; there is nothing to do on upgrade.

### Fixes

- **Bash suites run cleanly on bare CI runners.** Configure a git identity in the Test workflow (bare runners auto-detect an empty ident name, so `cs`'s internal commits failed); source `verify_checksum` from a temp file (macOS stock bash 3.2 can't define a function via `source <(…)`); a portable `timeout` shim (stock macOS ships none); compute the countdown `now` via `date +%s` (bash 3.2 lacks the `%(%s)T` builtin); feed hooks via a herestring to avoid a `pipefail`-surfaced SIGPIPE; jq `--rawfile` for large payloads (a ~250 KB `--arg` exceeds Linux's per-argument limit); and a `stat` helper that selects the GNU/BSD implementation up front.
- **TUI tests no longer flake under parallel execution.** Env-mutating tests raced the many parallel tests reading `sessions_root()`. The shared process-global `CS_SESSIONS_ROOT`/`HOME` (in tests) is replaced with `#[cfg(test)]`-gated thread-local overrides, so each test's sessions root is isolated per thread. Production code paths are unchanged.

## 2026.7.5

A full improvement audit (#1–#268) plus a two-pass Fable-model prompt-engineering review of every slash-command, skill, and hook-injected prompt.

### Removed

- **Automatic artifact tracking** — the `artifact-tracker` hook, `.cs/artifacts/` auto-saving, the artifact merge driver, and the TUI artifact preview are gone.

### Changed

- **`session.log` is machine-local** — the command audit trail now lives at `.cs/local/session.log` (gitignored), no longer git-tracked or `merge=union`. `.cs/timeline.jsonl` is the shared structured record.
- **`bin/cs` is assembled from `lib/*.sh`** by `build.sh` (byte-identical output); edit the fragments and rebuild. CI fails if `bin/cs` drifts from `lib/`.

### Fixes

- **Security:** the generated session `CLAUDE.md` no longer demonstrates a secret pattern that lands the value in the command log; secret values are read from stdin; the `-update` payload is pinned and verified against the release tag.
- **Prompt quality (Fable review, 74 findings):** session-context injection now teaches the per-actor narrative and stdin-secrets, and tells a subagent its final message is the deliverable; the auto-grounded scope block reads as orientation (not a task boundary) and never truncates silently; the task-queue walk-away run enumerates every task via `cs -queue list`; `/sweep` routes constraints discovered through work; `checkpoint` routes its `list`/`show` subcommands instead of saving them as labels; prose-hygiene separates drafting from review with a technical-prose carve-out; the `/release` runbook runs in numbered order with a branch/sync preflight.
- **Robustness:** hardened session-name validation (rejects `.`/`..`/path traversal), the Rust TUI (panic restore, multibyte safety), hook contract boundaries, and shell portability.

### Docs

- Broad accuracy + completeness pass: `session.log` paths, per-actor narratives, timeline event names (`started`/`ended`/`checkpoint`), undocumented hook behaviors, a new `.cs/` session-layout schema doc, and the contributor + release guides.

## 2026.7.4

### Features

- **Task queue** — `cs -queue add "<task>"` queues prompts for a walk-away
  run; the Stop hook asks once (context % shown, with a compact nudge at
  60% or above) then drains the queue in order at each stop boundary until
  it's empty, with no further prompts, mirroring progress into the native
  task list. Manage with `cs -queue list`/`rm`/`clear`, or target any
  session from another terminal with `cs <session> -queue …`.
- **TUI To-Do panel and column** — the session picker's right pane has a
  To-Do panel for the highlighted session: `Tab` focuses the input, `Enter`
  queues a task, `Down` enters the list where `d` deletes and `e` edits a
  task in place, `Esc` returns to the session list. Sessions with queued
  tasks get a sortable `▤ N` To-Do column, and the status line shows `▤ N`
  after the session name.
- **Worktree sessions are self-aware** — a task worktree session's Claude is
  told at launch (and after /clear or compaction) that it runs in a worktree
  of its base session, that `cs <base> --merge <task>` integrates it, and
  that merging the task branch by hand bypasses the record fuse. Subagents
  inherit the same contract.

### Performance

- **Faster session picker** — the TUI scans sessions across a bounded worker
  pool instead of forking `git` serially per repo; on ~56 git sessions,
  picker startup dropped from ~1.1s to ~0.27s.

### Fixes

- TUI mouse clicks now select the correct session across variable-height
  rows (time-group headers and expanded previews).
- The queue's decline cooldown and the To-Do column stay consistent across
  the CLI, the Stop hook, and the TUI panel.

### Docs

- README, `docs/statusline.md`, and `docs/hooks.md` updated for the queue,
  the To-Do panel and column, and the status line notes segment.

## 2026.7.3

### Features

- **Parallel task worktrees** — `cs <base>@<task>` opens an isolated worktree
  session on branch `cs/<task>`; `cs <base> --merge <task>` merges it back,
  fuses session records, and removes the worktree; `cs -rm <base>@<task>`
  abandons one. Autosave crash-recovery moved to per-worktree
  `refs/worktree/cs/auto` (legacy `refs/cs/auto` migrates on resume). The
  artifact tracker no longer redirects writes targeting paths outside the
  session checkout. Doctor gains worktree health checks.
- **Lock-collision menu** — typing `cs <name>` while that session is open
  now offers to start a parallel task worktree, force a second launch, or
  cancel, instead of a hard refusal. Creating a task from a dirty base asks
  for consent interactively (branches from the last commit) and still
  refuses in scripts. The non-interactive refusal's --force hint now names
  the registered session (adopted sessions previously showed the project
  folder's name).
- **Conflict-free session sharing** — machine-local state (conversation
  UUID, session color, resume timestamps) lives in gitignored
  `.cs/local/state`; the append-only session log and timeline union-merge;
  narratives, the artifact manifest, and the created date merge without
  conflicts; per-machine age-encrypted secrets sync files; the sharing
  model is documented in the README.
- **Statusline attention mark** — the Claude mark pulses while a finished
  turn is waiting for you (driven by `statusLine.refreshInterval`), raised
  when Claude stops and cleared when you interact.
- **Wrap-up passes on Sonnet 5** — `/wrap`, `/sweep`, and `/summary` now
  run on `claude-sonnet-5`.

### Other

- Simplify pass over the release: shared helpers for the interactive gate,
  dirty-tree check, and session-dir resolution; one shared manifest-merge
  filter for the git driver and the explicit fuse; fewer subprocess forks
  in the Write/Edit hook hot paths; autosave's legacy-ref cleanup now runs
  exactly once.
- Docs refreshed (`hooks.md`, `secrets.md`) for the new ref names, artifact
  scoping, and `CS_SECRETS_SESSION`; 525+ tests green across 34 suites.

## 2026.7.2

### Features

- **Background-derived gauge surface** — the quiet statusline gauges (`ctx`, `5h`/`wk` limits, `$` cost) now take their background from a shade of the terminal's own background instead of a fixed grey, so they harmonize with the terminal: darker on a light terminal, lighter on a dark one. Their text is picked for contrast against that surface (a soft warm-dark tone, not harsh near-black), and the separators ink in a faint shade of the surface — a discreet tonal step rather than a foreign grey line. Falls back to the warm neutral grey when the terminal background is unknown or outside truecolor.

### Other

- Test-harness isolation: the shared test setup now clears the terminal-theme env vars a real cs session exports at launch, fixing an intermittent failure.

## 2026.7.1

### Features

- **Full-width statusline gradient** — in truecolor terminals the bar stretches to full width, fading its trailing edge into the terminal's real background color so it reads as floating rather than stopping short of a blank terminal.
- **Logo divider** — the coral logo badge is now set off from the session name by a thin darker-coral divider.

### Fixes

- **Terminal background detection under tmux** — cs reads the real outer-terminal background via OSC 11 (a plain query when tmux proxies it, DCS passthrough otherwise), which is what enables the gradient. Fixes a guard that silently blocked the query whenever detection output was captured, so the background was never actually learned in a real session.
- **Symmetric session-name padding** — the name no longer sits one column off-center after the logo divider.

### Docs

- Statusline docs and README updated for the full-width gradient and the tmux background-detection behavior.

## 2026.6.13

### Features

- **Statusline logo badge** — the bar now opens with a Claude mark (`✳`) on a Claude-coral square (color modes only).
- **Exact Claude Code `/color` palette** — the session-name pill and the terminal tab color now use Claude Code's own `/color` RGB values (its default dark/light agent-color palette), so cs's accents match what Claude Code shows for the same color name. The quiet gauge sections (ctx/5h/wk/cost) use a lighter warm grey.
- **Truecolor in tmux** — cs sets `CLAUDE_CODE_TMUX_TRUECOLOR=1` in Claude Code's environment at launch (respecting a value you've set yourself), so Claude Code's branding and any truecolor status line render at full saturation inside tmux instead of the muted fallback.

### Fixes

- **prose-lint hook** — per-actor narrative notebooks (`narrative.<actor>.md`) are now excluded from prose linting, the same as `narrative.md` always was. Previously the stop hook would loop on the lab notebook's accumulated em-dashes.

### Docs

- Statusline docs and README updated for the logo badge, the exact `/color` palette match, and the tmux truecolor behavior.

## 2026.6.12

A session-picker (TUI) glow-up plus a light-terminal contrast fix.

### Features

- **Session list redesign** — a relative `Age` column (`2h`, `3d`, `1mo`), recency **heat dots** (green = live → grey = dormant), and **recency as the default sort** so live sessions surface first.
- **Refined chrome** — rounded panel, a warm rust→orange→amber **gradient header band** with a hairline header rule, a softened selection (accent bar + subtle tint instead of full reverse-video), a vivid 3-stop gradient title, a **shimmering** selection bar, and branch glyphs on Github repos.

### Fixes

- **Column alignment** — table dividers no longer slice through headers/cells (`M│dified`, `hex/ba│ger`); geometry now comes from ratatui's own layout solver, which also fixes mouse click-to-sort drift.
- **Default sort actually applies** — the picker sorts by recency on open (it was previously declared but never applied to the initial list).
- **Hidden dirs excluded** — `.obsidian`/`.git` and friends are no longer listed as sessions.
- **Light-terminal contrast** — the `cs` resume banner uses a theme-aware palette (readable ink/greys on a light background) instead of dark-tuned colours that washed out.

## 2026.6.11

### Fixes

- **Migration:** resuming an older session now backfills the `.cs/local/` ignore rule into its `.gitignore`. Before this, a pre-existing `.cs/` session never gained that rule, so its per-actor state (watermark, lock) could be committed, which then tripped the v2026.6.10 leak guard and blocked the next resume. The `.gitignore` update is idempotent and never clobbers a project's existing entries.

## 2026.6.10

cs gains multi-person co-development awareness: when a project's `.cs/` is committed to git, multiple people can collaborate with attributed, conflict-free, and visible contributions, all derived from git history with no servers or coordination.

### Features

- **Per-actor identity** (`cs -whoami`): each contributor is identified from git identity (with a `.cs/local/identity` override), normalized to a filesystem-safe slug.
- **Per-actor narratives**: the session lab notebook splits into `narrative.<actor>.md` files so co-developers never conflict; everyone reads all on resume. Legacy `narrative.md` migrates automatically.
- **On-resume digest**: cs reports shared memory/narrative activity since you last looked ("Since your last session, Bob (2)"), tracked by a per-actor `.cs/local/watermark`.
- **`cs -who`**: on-demand contributor feed from git history over `.cs/memory`.
- **TUI contributors**: the session preview pane lists who contributed.
- **Conflict-free memory index**: a `merge=ours` gitattribute keeps the hand-maintained `MEMORY.md` from blocking merges.
- **Leak guard**: a gitignored `.cs/local/` holds per-machine state (lock, watermark, logs); cs refuses to resume a session whose `.cs/local/` was committed.

### Fixes

- Shell completions were stale (missing `-adopt`, `-whoami`, `-who`, `-lint`, `-statusline`, `-doctor`/`-diag`, `-detect-theme`); all added, plus a drift test that asserts completions match the command dispatch.
- Autosave log entries no longer show raw `##` heading markers on macOS (BSD `sed` `\+` fix).

### Docs

- README, hooks docs, and the session template updated for per-actor narratives and the new commands.

## 2026.6.9

cs is now a local-only tool: the cross-machine sync and remote-session subsystems have been removed.

### Removed

- **Git cross-machine sync** — `cs -sync` (push/pull/status/clone/remote) and the `auto_sync` setting. Sessions are no longer auto-committed or pushed at session end (this stops cs from writing "Session update" commits into an adopted project's real branch).
- **SSH remote sessions** — `cs -remote`, `cs <name> --on <host>`, `cs <name> --move-to <host>`, the `user@host:name` connect form, and the remote-host registry. The TUI's Move-to-remote (`m`), async push/pull/status (`P`/`L`/`S`), and the Remote column are removed.

### Kept

- **Crash recovery** via the shadow autosave ref (`refs/cs/auto`) — unchanged.
- **Secrets** — `cs-secrets export-file` / `import-file` (age-encrypted) remain as a manual backup/transfer mechanism.
- **Software updates** — `cs -update` is unaffected.

### Migration

- Inert `.cs/sync.conf` / `.cs/remote.conf` files are removed automatically on next session resume.

## 2026.6.8

bash 3.2 (macOS system bash) compatibility.

### Fixed

- **Statusline reset countdown on bash 3.2.** The `5h 23% · 2h14m` countdown relied on the bash 4.2+ `printf '%(%s)T'` clock and rendered blank on bash 3.2 — the statusline runs under whatever `bash` is first on Claude Code's (often minimal) PATH, frequently `/bin/bash` 3.2 even when Homebrew bash is installed. `_fmt_rest` now falls back to `date +%s` when the builtin is unavailable; the bash 4.2+ path stays fork-free.
- **`cs -list` aborted on bash 3.2.** `list_sessions` used associative arrays (`local -A`), which abort under stock `/bin/bash` 3.2 with `local: -A: invalid option`. Reworked to drop them (inline secret count, shared remote-config helpers) — output is unchanged.
- **`cs -help` printed a spurious `allow-passthrough: command not found`.** The help text is an unquoted `cat << EOF` heredoc and a backtick-quoted phrase was being executed as a command (on every bash version); fixed to plain text.

### Changed

- **Minimum bash is now 3.2** (was documented as 4.0+) — macOS system bash is supported.
- Statusline default-segment docs corrected and the `<1m` reset countdown covered by tests.

## 2026.6.7

A focused round of `cs-statusline` refinements.

### Added

- **5-hour window reset countdown.** The `5h` block now appends the time until the rolling window resets, e.g. `5h 23% · 2h14m` (`<1m` / `45m` / `2h14m` forms). Derived from the statusline schema's `rate_limits.five_hour.resets_at` (Unix epoch seconds) using a fork-free `printf` clock; absent when the field is missing or the window already reset.

### Changed

- **Squared pills replace the powerline look.** Segments now render as square, abutting blocks — the background-color change is the divider between differing neighbors, and same-colored neighbors get a faint `▏` (U+258F) bar. The powerline arrow and its `CS_NERD_FONTS` statusline path are retired (the variable still controls cs banner/listing icons). No Nerd Font or private-use glyphs are used.
- **Warmer neutral.** The quiet segment background shifts from steel grey to a warm taupe (`rgb(96,90,82)` light / `rgb(108,101,92)` dark).
- **Branch moves ahead of the model and becomes a bold accent.** Default order is now `session,git,model,ctx,limits,cost`, and the branch renders bold in slate-blue `rgb(79,91,140)` — a hue in the model periwinkle's family so the three identity accents read as one cool gradient.
- **Session pill drops its icon.** The session name now sits on its `claude_session_color` background with no leading glyph — the color is identity enough.

## 2026.6.6

### Added

- **Session-picker TUI adapts to light terminals.** The warm rust/gold palette now has a light variant tuned for paper backgrounds, with the foreground accents desaturated so they read on a light canvas. The TUI picks light or dark from the terminal background `cs` already detects at launch (`CS_TERM_THEME` — OSC 11 with tmux DCS passthrough, macOS appearance, then `COLORFGBG`) and exports before the picker runs, rather than re-detecting itself. Dark terminals are unchanged — the canvas uses `Color::Reset`, preserving the terminal's native background, transparency, and images. Force it with `CS_TERM_THEME=light|dark`; `cs-tui --print-theme` shows what the binary resolved.
- **Session Objective is auto-captured from your first prompt.** The first substantive prompt of a session is recorded as `## Objective` in `.cs/README.md`, folded into the `scope-prompt.sh` UserPromptSubmit hook (no new hook). It writes once while the Objective is still a bracketed placeholder, never overwrites a real or hand-written objective, is scoped to the Objective section (the Outcome placeholder is left untouched), skips slash-commands / `!`-passthrough / trivially short prompts, and writes prompt text strictly as data (never executed). Opt out per-session with `CS_OBJECTIVE_CAPTURE_DISABLE=1`.

### Changed

- **Statusline model background deepened** from `rgb(153,152,255)` to `rgb(138,134,236)` to match Claude Code's current usage-chip color (pixel-sampled).

### Fixed

- **The TUI no longer shows the unfilled Objective template placeholder.** An unedited `[Describe what you're trying to accomplish in this session]` is suppressed in the preview (any whole-line `[...]` under `## Objective`), matching the session-start hook, so an empty Objective renders as nothing instead of boilerplate.
- **Fixed a flaky test.** The `scan_sessions` tests mutated the process-global `CS_SESSIONS_ROOT`, racing each other under parallel `cargo test` and intermittently reading the real sessions directory; they now inject the path via a `scan_sessions_in(root)` helper instead of touching global env.

### Docs

- Updated `README.md` and `docs/hooks.md` for the adaptive TUI palette, the auto-captured Objective, and the `CS_TERM_THEME` / `CS_OBJECTIVE_CAPTURE_DISABLE` env vars.

## 2026.6.5

### Changed

- **Statusline renders without a Nerd Font by default.** Segment icons are now standard Unicode glyphs (hexagon `⬣` session, star `✦` model, `◔` context, `⎇` git, `◷` 5h, `◑` weekly) from the Geometric Shapes and dingbat ranges, so they render in any monospace font instead of as missing-glyph (tofu) boxes. The separator defaults to a minimal style: differing-background blocks abut so the color change is the divider, and same-background neighbors join with a thin bar `│`. `CS_NERD_FONTS=1` still upgrades the separator to the powerline arrow (U+E0B0) and same-background chevron (U+E0B1); it no longer gates the icons.
- **Re-picked the 8-color session palette for white-text contrast.** The session-color shades (statusline blocks and the tab color) were re-tuned so white text reads cleanly on every one — the muddy olive `yellow` became a darker gold, and the black-text special case for `yellow` is removed.
- **Terminal tab color is synced to the session color.** The tab color now derives from `claude_session_color` using the exact RGB the statusline block uses (`_session_color_rgb` in `bin/cs`), instead of a hash of the session name. The session block, the tab color, and Claude Code's `/color` now all reflect one color; `test_tab_color_palette_matches_statusline` guards the two palettes against drift.

### Fixed

- **Statusline no longer renders tofu boxes in terminals without a Nerd Font.** Icons and the default separator are standard Unicode; only the `CS_NERD_FONTS=1` powerline arrow needs a patched font. (Under tmux the outer terminal is undetectable — every client reports `xterm-256color` — so the Nerd Font arrow stays an explicit opt-in via `CS_NERD_FONTS`.)
- **Yellow sessions showed unreadable black-on-olive text** in the statusline; they now use white text on a darker gold.

### CI

- **Release workflow bumped to Node 24 action majors** (`actions/checkout@v5`, `actions/upload-artifact@v6`, `actions/download-artifact@v7`, `softprops/action-gh-release@v3`) ahead of GitHub's Node-24 migration; v5 of the artifact actions still run Node 20, so v6/v7 were required.

### Docs

- Updated `docs/statusline.md` and `README.md` for the standard-Unicode icons, the re-picked palette, the tab-color sync, and the minimal separator.

## 2026.6.4

### Fixed

- **Retired the PreCompact hook (`narrative-precompact.sh`), shipped in 2026.6.3.** It emitted `hookSpecificOutput`/`additionalContext`, which Claude Code's PreCompact event does not accept — the hook output schema offers `hookSpecificOutput` variants only for `PreToolUse`, `UserPromptSubmit`, `PostToolUse`, `PostToolBatch`, and `Stop`/`SubagentStop`, with no context-injection path for `PreCompact`. The hook therefore failed JSON-output validation ("(root): Invalid input") on every `/compact` in every cs session. The premise was also unsupported in principle: PreCompact gives the model no turn before compaction, so it cannot prompt a flush. The Stop reminder (`narrative-reminder.sh`) already covers mid-session narrative capture, so the PreCompact hook is removed and added to `RETIRED_HOOKS` (both `install.sh` and `bin/cs`) so deployed copies are stripped on next install/uninstall.

## 2026.6.3

### Added

- **Session lab notebook relocated into native memory.** `.cs/discoveries.md` (and its `discoveries.compact.md` companion) becomes `.cs/memory/narrative.md`, a `type: narrative` Claude Code memory topic file. It inherits the native handling the bespoke notebook had reimplemented by hand: the `MEMORY.md` index pointer loads at startup while the body is read on demand (so the 60KB size budget and compaction are gone), it appears in `/memory`, and it syncs across machines like the other memory files. `ensure_narrative_file` creates the stub and re-adds the index pointer idempotently on every resume; `migrate_discoveries_to_narrative` folds a legacy `discoveries.md` (+ compact) forward once and consumes the originals. The two-bar design is preserved — narrative is the looser bar, the `user/feedback/project/reference` buckets stay strict — and the resume read list, `/sweep`, `/summary`, `/wrap`, `/checkpoint`, `cs -search`, and the TUI all repoint to the new location.
- **`narrative-reminder.sh` (Stop) and `narrative-precompact.sh` (PreCompact) hooks.** Two complementary capture triggers replace the single retired discoveries timer-nag: a cooldown-gated Stop reminder (no size-budget logic) that nudges when the narrative goes stale, and an event-based PreCompact reminder that injects an `additionalContext` prompt to flush findings into the narrative before the conversation is compacted.

### Changed

- **Retired the bespoke discoveries machinery superseded by native memory handling.** `discoveries-reminder.sh`, the `/compact-discoveries` command, the `CS_DISCOVERIES_*` size budget and compaction, the `_doctor_check_discoveries_size` health check, and the statusline `disc` segment are all removed; deployed copies of the retired hook are cleaned up via `RETIRED_HOOKS` on next install/uninstall.
- **Renamed `discovery-commits.sh` → `autosave-commits.sh`.** The hook was always general all-file shadow-ref crash recovery, not discoveries-specific; the old name is listed in `RETIRED_HOOKS` so deployed copies are cleaned up.
- **Statusline icons.** The model segment uses a brain glyph and context uses a database glyph. Icon-to-text spacing is tuned per glyph (Nerd Font advance widths vary per glyph, not per icon family), so the wider brain glyph gets a second trailing space and every icon's gap lines up.
- **`cs -lint` synced against stop-slop upstream and hardened.** A source-level comparison against github.com/hardikpandya/stop-slop found the prose-hygiene skill already current with upstream HEAD `8da1f03` (2026-03-18, including the false-agency rule; the upstream changelog stops in January, so currency checks must read `git log`). Three improvements landed on our side: 18 upstream phrases joined `PROSE_SLOP_PHRASES` after passing the zero-hits-across-the-real-corpus admission rule ("it turns out", "the truth is", "think about it:", "full stop.", "game-changer", "circle back", "deep dive", "when it comes to", and ten more; "a feature, not a bug" and "on the same page" had corpus hits and stay judge-only); inline backtick spans are now stripped before matching, so a flagged character or phrase can be mentioned as quoted material (previously only fenced blocks were exempt); and the skill's `metadata.source` records the upstream commit it was synced against, making the next currency check a one-line diff. Tests: an 18-phrase loop, inline-code exemption coverage for both check types, a mixed-line case, and a provenance assertion.

### Fixed

- **Statusline theme detection under tmux.** `detect_term_theme` now sends the OSC 11 background query through tmux DCS passthrough (`_tmux_passthrough`) so it reaches the real outer terminal, instead of falling back to the macOS OS appearance. The fallback mis-classified a light-themed terminal as dark whenever the OS was in Dark Mode (an independent signal from the terminal's own background), freezing the wrong `CS_TERM_THEME` at launch. Passthrough requires `allow-passthrough on` in tmux; when it is off or the reply does not round-trip, detection still falls back to the OS appearance as before.
- **Narrative fold preserves compact content.** `migrate_discoveries_to_narrative` now folds `discoveries.compact.md` even when the active `discoveries.md` is header-only; previously the empty-active short-circuit could delete the compact file without folding its content.

### Docs

- **README, `docs/hooks.md`, `docs/sync.md`, `docs/statusline.md`** updated for the narrative relocation and the tmux theme passthrough, and the README gained a status-line screenshot.

## 2026.6.2

### Added

- **Terminal theme detection (`CS_TERM_THEME`).** At session launch, while cs still owns the tty, `detect_term_theme` classifies the terminal as light or dark: an OSC 11 background-color query parsed into BT.709 luminance first, then `COLORFGBG` by background index (including Konsole's three-part form) as fallback. The query outranks the variable deliberately — `COLORFGBG` goes stale across theme changes (observed `15;0`, a dark classification, under a light terminal); OSC 11 asks the live terminal. Under `$TMUX` both tty signals lie — tmux 3.6a answers the OSC query itself with its default black background instead of the outer terminal's color, and `COLORFGBG` is the server's start-time snapshot (a passthrough-wrapped query got no reply either) — so detection reads the OS appearance instead: `defaults read -g AppleInterfaceStyle` on macOS (the key is absent in light mode, including auto-while-light), `unknown` elsewhere. The result exports as `CS_TERM_THEME` for the statusline and hooks; a preset value is a manual override, and `cs -detect-theme` prints what detection yields. Detection deliberately does not run from hooks: an OSC query fired mid-session would race its reply into claude's input stream. `cs-statusline` consumes it with a dark variant (lifted neutral grey, softened white text); everything else in the bar is self-backgrounded and theme-independent.

- **`cs-statusline` Claude Code status line.** A bash+jq `statusLine.command` that renders one powerline line: session name (background tinted with the session's `claude_session_color` read from `.cs/README.md` frontmatter), context % from stdin's `used_percentage` (yellow 50% / red 80%, `CS_STATUSLINE_CTX_WARN`/`_CRIT` tunable), model + effort level, git branch with ahead/behind arrows and `+staged`/`!modified` counts from a single `GIT_OPTIONAL_LOCKS=0 timeout 2 git status --porcelain=v1 -b` call, 5-hour/weekly rate limits (colored by the higher of the two), `discoveries.md` size against its 60K budget, and session cost. The hot path is one `jq` pass over stdin plus at most one git fork and two small `.cs/` reads, all gated per segment (`CS_STATUSLINE_SEGMENTS` controls order and selection; a disabled segment's I/O never runs); no transcript parsing, no network, no writes, fail-open to a plain dir-name line on any error. Color ladder: `FORCE_COLOR=0`/`NO_COLOR`/`TERM=dumb` plain, truecolor for `COLORTERM`/iTerm2/WezTerm, 256-color by `TERM`, basic otherwise; powerline arrow glyph behind `CS_NERD_FONTS=1` with `>` fallback; `CS_STATUSLINE_DISABLE=1` prints nothing. `install.sh` deploys the binary but claims the status bar only with consent: interactive installs ask before registering (default yes; replacing an existing status line always asks), non-interactive installs skip registration and print the enable command. `cs -statusline enable|disable` turns the registration on or off any time (enable overwrites as explicit consent; disable strips only a cs-statusline entry); `cs -uninstall` strips the registration only when it points at cs-statusline; `cs -doctor` gained a Statusline check (FAIL only for a registered-but-missing binary). Shipped TDD: 24-test `tests/test_statusline.sh` suite (fixtures from the official status-line docs schema, fake-git sentinel proving the I/O gating, threshold and color-level coverage) plus 5 installer/uninstaller and 3 doctor tests. Design informed by a source study of claude-powerline (git query shape, color-support ladder, per-segment I/O gating) and oh-my-claudecode's HUD as the counterexample (per-render transcript parsing, unconditional state reads, multi-line sprawl). The limits segment renders as two adjacent grey blocks with per-block amber/red escalation, and `CS_NERD_FONTS=1` adds per-segment icons (home/gauge/microchip/branch/clock/calendar/book) alongside the powerline arrow separator. Palette principle: two accents, then state — the healthy bar colors exactly the session name (its `claude_session_color`) and the model (periwinkle `rgb(153,152,255)`, matching claude's own usage chip), both in bold white text; every other healthy segment rests on grey, and warn/crit colors appear only past thresholds (warn is cs's warm amber `rgb(255,183,77)`, not terminal yellow; light warn backgrounds carry dark text). disc warns at 85% of budget and crits at 95% (discoveries fill slowly and idle high, so earlier thresholds kept the block permanently colored). Same-background neighbors join with a thin chevron (U+E0B1 / `›`) so boundaries stay visible inside grey runs. See `docs/statusline.md`.

### Changed

- **Release-review cleanups (reuse / simplification / efficiency / altitude pass over the statusline cycle).** The render hot path drops five forks per render: the stdin slurp, session-color lookup (pure bash now, no awk), file-size read, and git wrapper return via globals instead of command substitutions, and `GIT_OPTIONAL_LOCKS=0` is exported once instead of spending an `env` exec. The disc segment's budget default now matches the rest of the codebase (60000 bytes, decimal K display) so its 85/95% thresholds agree with the reminder hook's over-budget trigger. `cs -statusline disable` and `cs -uninstall` share one `_strip_statusline_registration` helper (the two copies had already diverged in error reporting), and both resolve settings.json via `CS_CLAUDE_DIR` exactly like doctor, so enable/doctor can no longer disagree about which file they mean. install.sh's three-way statusline consent case now decides only consent, with a single jq registration site after it. Theme detection's OS check reads `$OSTYPE` instead of forking uname, and `_thresh_color`'s dead `green` default is the `grey` every caller actually uses.

- **Commands and skills pass an optimization audit; doctrine is now single-sourced.** A workflow audit (per-file Opus analyzers, cross-cutting duplication and delegation reviewers, adversarial verification of high-severity claims) drove a restructuring of the in-Claude prompt surface. `sweep.md` now owns the memory discipline outright: the bucket routing table (retired from CLAUDE.md in v2026.5.5 but still referenced by two commands — a verified dangling pointer) is inlined, and writers must match existing entry frontmatter and index every new entry in `MEMORY.md` (an unindexed entry is never lazily loaded). `wrap.md` shrank from 83 lines to 30 by becoming a true orchestrator — Pass 1 executes the deployed `~/.claude/commands/sweep.md` end to end (so `/wrap` now includes the discoveries sweep it previously dropped), Pass 2 and 3 execute `summary.md`'s steps and prose gate — eliminating four near-verbatim copy-pairs that had already drifted (summary skeleton headings, lint targets, the three-bar wording, the scoring threshold). `summary.md` reads `discoveries.compact.md` (post-compaction sessions no longer lose their early history), pins the prose critic to `model: opus` with a final-message deliverable contract, and defers the revise threshold to the prose-hygiene skill that owns it. `checkpoint.md` fixes the silently-ignored `allowed_tools` frontmatter key (`allowed-tools`). `compact-discoveries.md` gates the subagent spawn on a parent-side `wc -c` budget check and re-reads before its overwrite (background discovery appends no longer get clobbered). `store-secret` gained real YAML frontmatter (its 280-char first line was acting as the activation trigger) and backend-neutral wording. `discoveries-reminder.sh`'s over-budget nudge defers to `/compact-discoveries` instead of respecifying the procedure inline. The CLAUDE.md scaffold names `/wrap` as the canonical wrap-up (with `/summary` and `/sweep` as the narrative-only and memory-only subsets), resolving the two-canonical-commands conflict. New 14-test `tests/test_commands.sh` guards the single-source invariants (threshold owned by the skill, table owned by sweep, deployed-path references, frontmatter keys).

## 2026.6.1

### Changed

- **Release-review cleanups (reuse / simplification / efficiency / altitude pass over the full release range).** `session-start.sh` gained a single `frontmatter_set` helper (atomic tmp+mv awk) replacing two divergent sed idioms; `scope-prompt.sh` dropped one classifier spawn, a redundant whole-token stoplist pass, and three no-op pipeline stages on the per-prompt hot path; `install.sh`'s `_merge_cs_hook` now derives paths from the hook filename and builds its settings block with `jq -n`, deleting 22 single-use variables and 11 hand-written JSON strings; `bin/cs` mirrors install.sh's named `_strip_hook_registration` (filter bodies diff-tested), hoists the deployed-hooks dir default to one place, keys skill-layout detection on path shape instead of the warning label, and drops the dead `UTILITY_HOOKS` scaffolding.
- **Hooks deploy to `~/.claude/hooks/cs/` instead of flat `~/.claude/hooks/`.** The subdirectory makes cs's footprint atomic: `ls` shows exactly what cs owns, uninstall removes the whole directory, and drift between repo source and deployed copies is a one-line `diff -r`. `install.sh` migrates existing installs — parent-level binaries (current and retired) are removed and parent-level settings.json registrations are stripped before re-registering under the subdirectory, so hooks never double-fire. `bin/cs -uninstall` cleans both layouts. The hook name list is now a shared `CS_HOOKS` array in both `install.sh` and `bin/cs` (KEEP IN SYNC comments on both), replacing eleven hand-written cp/curl/wget lines per transport and ten per-event jq strip blocks in uninstall.
- **`cs -doctor` gained a deploy-drift check.** When run from a cs source checkout (detected by `hooks/` + `install.sh` + `bin/cs` in cwd), it compares each `hooks/*.sh`, `commands/*.md`, and `skills/*/SKILL.md` against the deployed copy and warns `deployed copy differs from source` / `not deployed` with a `run ./install.sh` pointer. Catches the failure mode where repo-side artifact edits (or deletions) silently never reach the running install — observed live when three hooks deleted in the harness audit kept firing for three days from their deployed copies. Silent outside a checkout.
- **`cs -doctor` gained a deployed-version check.** `install.sh` stamps the installed version into `~/.claude/hooks/cs/.version`; doctor warns when the stamp differs from the running binary's `VERSION`. Unlike the drift check this works for installs without a source checkout — it catches `cs -update` runs that updated the binary without re-deploying artifacts. Skips silently when no stamp exists (installs predating the stamp).
- **Manifest arrays are sync-tested.** The artifact name lists (`CS_HOOKS`, `RETIRED_HOOKS`, and the `CS_COMMANDS` / `CS_SKILLS` arrays that now replace per-file install/uninstall lines for commands and skills) are duplicated between `install.sh` and `bin/cs` behind KEEP IN SYNC comments. `tests/test_install.sh` now parses both files and fails when any array differs between them, or when `CS_HOOKS`/`CS_COMMANDS`/`CS_SKILLS` disagree with the actual repo contents of `hooks/`, `commands/`, `skills/` — adding a file without listing it (or vice versa) fails the suite instead of silently not deploying.

### Fixed

- **`cs -uninstall` left all hook registrations behind in settings.json.** The per-event strip blocks matched only `$HOME`-form command paths, but `install.sh` registers hooks in tilde form (`~/.claude/hooks/...`), so no entry ever matched and every cs registration survived uninstall. The consolidated strip now matches both spellings in both deployment layouts; a regression test seeds a tilde-form registration plus a non-cs sibling hook and asserts cs entries vanish while the sibling survives.

- **`cs` could resume an older conversation after a context-limit continuation.** Claude Code forks a new session UUID when a conversation runs out of context and is continued; the old transcript stays on disk, so the `claude_session_id` recorded in `.cs/README.md` kept naming the pre-fork conversation while looking healthy to the launcher's orphan check (`bin/cs` Phase 8 fast path: "recorded UUID present, transcript exists → skip discovery"). The next `cs <name>` resume then ran `claude --resume <stale-uuid>` and reopened stale history. `session-start.sh` now rebinds the README's `claude_session_id` to the live conversation UUID from the hook input on every SessionStart (all sources) — by the time the user is talking, the binding names the conversation they are actually in. Non-UUID session ids (harness stubs, jq null fallback) never clobber a valid recorded binding; each rebind is logged to `session.log`. Three new tests in `tests/test_hooks.sh` (rebind on resume, rebind on startup, invalid-id guard).

### Added

- **`/scope` auto-grounded UserPromptSubmit hook (`hooks/scope-prompt.sh`).** Classifies each user prompt; on a positive (code-work) classification injects a bounded `Scope (auto-grounded)` block as `additionalContext` — relevant tracked files, recent commits, working-tree diff — so the agent grounds its plan in the actual codebase rather than inventing structure. Hybrid token matcher: path-like tokens (`src/api.ts`) use ordered substring (preserves the order the token's structure naturally encodes); bare-word tokens (`api`, `db`) use component-equality with camelCase + `_-` splitting via a hand-rolled `splitcamel()` awk char-loop portable across BSD and GNU awk. Excludes `node_modules/`, `target/`, `dist/`, `build/`, `.next/`, `coverage/`, `.cs/`, `.git/`. Capped at 8000 bytes. Opt out per-session via `CS_SCOPE_DISABLE=1`. Pinned tombstone marker `Scope: no tracked files matched` when no tracked files surface. No caching by design — a grounding hook must reflect the current tree, so the scan runs on every fire (~50-150ms bounded). Hook count eleven (was ten). Shipped via TDD with a 22-test suite over five Builder/Adversary review rounds; final commit `6b432ee`. Settings.json entry under `UserPromptSubmit` with `timeout: 3`.

### Removed

- **`files.md` workspace indexer + PreToolUse:Read context hook.** `hooks/files-scan.sh` (the utility that walked the workspace and emitted `.cs/files.md` with per-file `~N tokens -- updated YYYY-MM-DD` lines) and `hooks/files-context.sh` (the PreToolUse:Read hook that injected the indexed entry as `additionalContext` before every Read) are gone, along with `.cs/files.md` itself. The indexer encoded an assumption that the agent couldn't introspect file sizes before reading; that assumption has expired now that `wc -l` / `fd` / `rg` are reliable. The injected entries carried only a token estimate and a date (no semantic description), and observation of a live session showed the hook firing repeatedly with notices dated *27 days before today* — pure context tax with no signal. README's "Files index" concept entry and "Pre-read file context" feature entry are dropped. Hook count: thirteen → eleven.

- **`changes-tracker.sh` PostToolUse re-narration log.** `hooks/changes-tracker.sh` appended `[timestamp] path` lines to `.cs/changes.md` on every Edit/Write, plus surgically updated `files.md` token estimates when a target was indexed. `git status` / `git log -p` / `git diff` already give the same view, authoritatively, and the re-narration drifted (sessions accumulated 125KB+ of `changes.md` that disagreed with git history on file scope). The `.cs/changes.md` path is removed from the session-start CONTEXT block, the fresh-rebind notice, the subagent context, the search corpus, the checkpoint snapshot, the adopt/migrate paths, and the `/summary`, `/wrap`, `/checkpoint` command prompts. Hook count: eleven → ten.

### Changed

- **`RETIRED_HOOKS` in `install.sh` and `bin/cs` grew by three.** `files-scan.sh`, `files-context.sh`, and `changes-tracker.sh` are now listed alongside earlier retirements (`discoveries-archiver.sh`, `aboutme-prereader.sh`, etc.) so existing installs strip the stale `settings.json` registrations and delete the deployed hook binaries on next `install.sh` or `cs -uninstall`. Without this, the deployed hooks at `~/.claude/hooks/files-context.sh` keep firing against deleted source until users manually clean up.

### Tests

- Dropped `tests/test_files_scan.sh`, `tests/test_files_context.sh`, `tests/test_changes_tracker.sh` and the three files.md scan-trigger tests + three files-context registration tests inside `tests/test_hooks.sh` (the features they covered no longer exist).
- `test_checkpoint_snapshots_changes` removed from `tests/test_checkpoint.sh` — it asserted that `cs -checkpoint` snapshots `.cs/changes.md` content; with `changes.md` gone, both the fixture and the snapshot block are gone too.
- Retired-hooks-strip tests in `test_hooks.sh` swap the "current PostToolUse hook" example from `changes-tracker.sh` (now retired) to `discovery-commits.sh`, keeping the assertion meaningful.
- Fixture cleanups across `test_adopt.sh`, `test_memory_rules.sh`, `test_uuid.sh`, `test_wrap_cues.sh`, `test_checkpoint.sh` (drop no-op `echo "# Changes" > .cs/changes.md` seed lines and the `assert_exists changes.md` line in adopt).
- Full 24-file suite green.

## 2026.5.7

### Added

- **Per-session random color via `/color` slash-command pass-through.** Each cs session gets a random color (red, blue, green, yellow, purple, orange, pink, cyan) allocated at creation and stored in `.cs/README.md` frontmatter as `claude_session_color`. Every claude launch appends `/color $color` as a trailing positional prompt arg so the prompt-bar accent is applied without dirtying the transcript. Symmetric with the `--name` pass-through shipped in v2026.5.6 — cs owns the visual identity, claude renders it. Legacy sessions without a color get one backfilled on next launch via `migrate_session` Phase 11 (audible warn: `Backfilled claude_session_color in .cs/README.md (X)`). Mechanism verified: slash commands at launch produce zero transcript-jsonl entries; the valid color list is the 8 the claude binary itself prints in its error message (earlier agent answers inflating this to 16 were hallucinated).

- **`cs -lint` deterministic prose linter.** Flags AI-slop lexical tells in markdown files — em-dashes and a curated 33-phrase blocklist of multi-word zero-false-positive phrases — while skipping fenced code blocks. Exit codes: 0 clean, 1 violations found, 2 usage/unreadable. Single-word adverbs and lazy extremes (verys, alwayss) are excluded by design since they occur in nearly all legitimate prose; the structural judge (see below) catches those instead.

- **`prose-lint` Stop hook.** Runs `cs -lint` against prose written this session (`.cs/summary.md`, `.cs/memory/*.md`) and blocks turn-end with `file:line` violations until fixed. Scope gated by `session.lock` mtime so a resumed session never re-flags the historical backlog (`.cs/discoveries.md` and the rest stay untouched).

- **`prose-hygiene` skill.** Captures the full stop-slop taxonomy: 8 core rules, 8 phrase categories, 11 structural patterns, a 5-dimension rubric, plus before/after examples. `/summary` and `/wrap` now spawn an independent structural-quality judge subagent that reads the skill and applies all of it — catching the slop a regex can't, like cadence, meta-commentary, false symmetry, and stacked qualifiers. Installs to `~/.claude/skills/prose-hygiene/SKILL.md`.

### Fixed

- **`cs -doctor` no longer mis-reports inline shell snippets as missing hook files.** `_doctor_check_settings_hooks_resolve` walks every `hooks[*].command` entry in `~/.claude/settings.json` and warns when the path doesn't exist on disk — but the check ran indiscriminately against entries like `if [ -z "$TMUX" ]; then echo ... fi`, which are valid inline-shell hooks, not file paths. Added a guard that only validates commands starting with an absolute path (`/...`); inline shell and `bash ...` wrappers are skipped.

- **Session-start tests leaked `CS_FRESH_REBIND` from the ambient cs environment.** When the test suite ran from inside a freshly-rebound cs session, the env var leaked into the hook subprocess and the negative-assertion test failed. `session_start_setup` now `unset CS_FRESH_REBIND` at the top; the positive test re-supplies it inline. Same family as v2026.5.6's vacuous-pass fix — tests passing/failing for ambient-environment reasons.

### Tests

- 7 new tests in `tests/test_uuid.sh` Cycle 8 cover color allocation, frontmatter persistence, all three launch paths emitting `/color`, color stability across resumes, and legacy-session Phase 11 backfill idempotence.
- New `tests/test_prose_lint.sh` (12 tests) covers the linter's fenced-code skipping, em-dash detection, blocklist phrase detection, and exit-code contract.
- New `tests/test_prose_lint_hook.sh` (10 tests) covers the Stop hook's scope-by-lock-mtime behavior, fixture isolation, and the block-decision JSON output shape.
- `tests/test_doctor.sh` gains 22 lines covering the inline-shell-skip fix.
- Full 26-file suite green.

## 2026.5.6

### Added

- **`--name $session_name` passed to every claude launch.** Surfaces cs's session name in claude's native display surfaces — the TUI prompt box, `/resume` interactive picker, and terminal title — instead of leaving them showing the bare UUID. Symmetry between cs's primary identifier (the session-name directory) and claude's display label. Touches all 4 exec sites in `bin/cs`: new-session (`--session-id <uuid>` path), resume Y (`--resume <uuid>` path), fresh-rebind helper (`_exec_fresh_rebind`, used by both the N-to-resume path and the resume-failure fallback), and the defensive naked-exec branch. The `--name` flag was discovered in `claude --help` and works on Claude Code 2.x+.

### Fixed

- **`install.sh` silently exited when `.zshrc` lacked an `fpath` line** ([#1](https://github.com/hex/claude-sessions/issues/1)). With `set -euo pipefail` at the top of the script, the `grep -oE 'fpath.*~/\.zsh/completions?'` pipeline at line 64 returned exit code 1 when no fpath line matched, `pipefail` surfaced that through the command substitution, `set -e` killed the script immediately — silent exit, no banner, nothing installed. Affected any user running a fresh install whose `.zshrc` doesn't pre-configure `fpath`. One-line fix per the bug report: append `|| true` to the pipeline. Reported by @pgardella-ml.

- **Vacuous-pass test bug in `test_decline_resume_rebinds_to_fresh_uuid`** (Cycle 6 of `test_uuid.sh`). The assertion `assert_output_contains "$output" -- "--session-id $recorded" "msg"` passed a literal `--` as the pattern arg (the test helper takes 3 positional args, not GNU-style flag separation), so the test silently matched on any output containing two consecutive dashes — trivially true for any flag-bearing argv. Fixed to `assert_output_contains "$output" "--session-id $recorded" "msg"`. The real behavior was already correct (fresh-rebind has emitted `--session-id` since v2026.5.3); this just makes the assertion actually verify it. Same family of vacuous-pass anti-pattern noted in the v2026.5.1 discoveries entry — added to the recurring "tests-that-pass-for-the-wrong-reason" list.

### Tests

- 3 new tests in `tests/test_uuid.sh` Cycle 7 cover the `--name` pass-through across all three user-facing launch paths: new session, resume (Y), declined resume (N → fresh rebind).
- New `tests/test_install.sh` with 2 tests covering install.sh end-to-end behavior with isolated `HOME`: silent-exit regression (issue #1) and fpath-detection happy path. First test runs the full installer in a tmpdir so future regressions in the installer's early-exit paths get caught immediately.
- Full 24-file suite green.

## 2026.5.5

### Removed

- **Auto-memory bucket guidance block (`cs:memory-rules`) retired.** The v2026.5.2 block — a ~75-line markdown section in each session's CLAUDE.md instructing claude on how to write durable user facts into per-bucket memory files — has been empirically shown not to drive the behavior it claimed. An 8-day measurement window (2026-05-18 to 2026-05-26) found 4 memory files written across all active sessions; 3 of those were written in a session whose CLAUDE.md has **no cs:memory-rules block at all** (its CLAUDE.md is project-owned and never carried the block). All 4 files carry the frontmatter fingerprint of claude's built-in auto-memory harness (`node_type: memory`, `originSessionId: <uuid>`) — fields the cs template never specified, evidence that claude's harness writes the files regardless of cs's prose. The block claimed behavioral ownership of a mechanism the harness actually drives. A council of four AI advisors independently converged on retirement.

### Added

- **`cs:memory-note` disclosure breadcrumb** replaces the rules block. One factual sentence stating what cs actually owns — the path-redirect via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` and the `MEMORY.md` index — and nothing about how claude should write. ~50 tokens per session vs the prior ~940. Block content lives in `_emit_memory_note_block` (single source of truth for both `write_session_claude_md` and Phase 9).

### Changed

- **Smart Phase 9 now retires the legacy rules block.** Four states distinguished on existing sessions: (1) `cs:memory-note` already present → skip; (2) `cs:memory-rules` sentinel + `## Auto-memory bucket guidance` header (any variant — v1 from 5.2 or v2 from 5.3–5.4 with the "scoop mode" suffix) → strip the entire rules section, insert the note in its place; adjacent `cs:wrap-cues` block keeps its order via an awk `stripping` flag that resets on the next `<!--` marker; (3) `cs:memory-rules` sentinel only (no header, user tombstone opt-out) → preserve as-is, do NOT add the replacement note (the opt-out signal carries over); (4) neither sentinel → append note fresh. Every existing non-opted-out session auto-converges to the note on next launch with one `Retired auto-memory bucket guidance; replaced with cs:memory-note` warn message.

### Tests

`tests/test_memory_rules.sh` rewritten — 10 tests covering: new-session note insertion, absence of legacy rules content in new sessions, legacy-session note append, idempotence, legacy tombstone opt-out preservation, retirement of v1 and v2 rules blocks with `cs:wrap-cues` adjacency preserved, idempotence on already-noted sessions, single-source-of-truth in `bin/cs`, and absence of behavioral instruction phrases ("Never pause to ask", "Writing is eager", "non-negotiable", "Signals it's time to Read") in the new note. Full 23-file suite green.

### Background

The retirement is documented in `.cs/discoveries.md` with the 8-day measurement timeline, the empire-as-accidental-control finding, the harness-fingerprint analysis, and the council consensus. The structural lesson: cs should claim ownership only of behavior it actually controls (path redirect, session lifecycle, hooks). Instruction prose in CLAUDE.md that duplicates harness behavior is documentation overhead with no measurable lift — and creates "false ownership" cost beyond the token bill (source-of-truth conflicts when the harness evolves, maintenance liability that lags behind upstream).

## 2026.5.4

### Fixes

- **`install.sh` no longer clobbers co-shipped user hooks.** The 12 jq merge filters that register cs's hooks in `~/.claude/settings.json` operated at the wrapper level — `select(.hooks | all(.command != $cs_path))` — which dropped the entire `{hooks: [...]}` wrapper whenever it contained cs's command, even if the wrapper also held an unrelated user hook (eg. `~/bin/claude-status` co-located inside cs's SessionStart wrapper after the user hand-edited settings.json). On every install/reinstall, the user's hook silently vanished. The new filter dives into the wrapper's nested `.hooks` array, strips only cs's command, drops wrappers that emptied out, and leaves flat-shape entries (no `.hooks` field) untouched. The 12 inline jq calls also collapse onto a single `_merge_cs_hook` shell helper — one source of truth for the merge shape.

### Tests

- 3 new install-merge spec tests in `tests/test_hooks.sh`: `preserves_coshipped_hook_in_wrapper`, `drops_emptied_wrapper_when_only_cs_hook_present`, `leaves_flat_entries_alone`. The filter shape is centralized in a `_install_merge_filter` test helper so the spec stays in sync with the production helper in `install.sh`.

## 2026.5.3

### Fixes

- **Phase 8 UUID backfill no longer mints orphans.** The v2026.5.2 backfill allocated a fresh UUID for every legacy session and wrote it as `claude_session_id:` — but that UUID was never bound to a real claude transcript, so `claude --resume <uuid>` failed and cs fell through to a fresh conversation on every resume. Phase 8 now reads the session's per-cwd transcript directory (`~/.claude/projects/<encoded-cwd>/`), binds the recorded UUID to the most-recent existing transcript, and self-heals already-orphaned READMEs from v2026.5.2 on next launch. Three new helpers — `_claude_project_dir`, `_discover_session_uuid_in`, `_set_session_uuid` — share `_claude_encode_path` and `CS_TRANSCRIPTS_DIR` with the existing doctor token-cost check, no parallel APIs.

### Features

- **Declining the resume prompt rebinds instead of orphaning.** Answering `N` to "Continue previous conversation?" used to exec `claude` naked, meaning claude picked its own UUID for the fresh conversation while cs's README kept pointing at the old one — next launch resumed the wrong conversation. Now the N branch (and the `--resume` failure fallback) allocate a fresh UUID, rewrite `claude_session_id:` in README, and exec `claude --session-id <new>`. cs's tracking always follows the conversation claude is actually running.

- **`CS_FRESH_REBIND=1` signal to SessionStart hooks.** When the rebind path fires, cs exports `CS_FRESH_REBIND=1` before exec. `session-start.sh` detects it and appends a "Fresh Conversation" block to its `additionalContext`: tells claude not to assume continuity with prior turns and points at `.cs/discoveries.md` / `README.md` / `changes.md` for lazy-read prior context. Without the signal, the hook's behavior is unchanged.

### Tests

- 4 new tests in `tests/test_uuid.sh`: bind-to-existing-transcript, self-heal-orphan-UUID, preserve-when-transcript-matches, decline-resume-rebinds-and-exports-CS_FRESH_REBIND.
- 2 new tests in `tests/test_hooks.sh`: fresh-rebind injects clean-break notice when env is set; omits it when env is unset.
- `tests/test_lib.sh` now exports `CS_TRANSCRIPTS_DIR` per-test to isolate discovery from the developer's real `~/.claude/projects/`.

## 2026.5.2

### Features

- **Deterministic Claude-session resume via pre-allocated UUIDs.** `create_session_structure()` now allocates a v4 UUID at session creation and writes it to `.cs/README.md` frontmatter as `claude_session_id`. `launch_claude_code()` reads it once and uses it for two things: spawning fresh sessions via `claude --session-id <uuid>` (so the conversation jsonl lands at a deterministic path under `~/.claude/projects/`), and resuming existing sessions via `claude --resume <uuid>` instead of `--continue`. `--continue` resolves to "the most recent claude conversation," which can be a sibling session the user ran in a different terminal between cs launches; `--resume <uuid>` names the exact conversation.

- **`CS_CLAUDE_SESSION_ID` exported to hooks.** Hook scripts can reverse-look-up the bound cs session without depending on `$CLAUDE_CODE_SESSION_ID` (which Claude Code sets in-session, not in pre-spawn hooks).

- **Lazy migration via `migrate_session()` Phase 8.** Sessions created before this feature lack `claude_session_id` in frontmatter. Phase 8 allocates a UUID, inserts it after the `created:` line, and is idempotent on subsequent resumes. Phase 6 (frontmatter creation) is the precondition. No flag day — every legacy session migrates transparently the next time it's opened, same pattern as the Phase 7 commands.md retirement in v2026.5.1.

- **Live-duplicate guard at spawn.** `launch_claude_code()` scans `ps` for the session's UUID before exec'ing claude. If a process already exists with the UUID in its argv (a duplicate tab), spawn is refused with a clear message. `--force` overrides. Tests stub `ps` via the `CS_PS_BIN` env var without touching `PATH`.

- **`cs -doctor` Session UUID cross-check.** New `_doctor_check_session_id_match` compares the recorded `claude_session_id` against the live `$CLAUDE_CODE_SESSION_ID` (set by Claude Code inside its own session). Mismatches WARN — they indicate either claude was launched outside cs in this directory, or that Phase 8 backfilled a UUID after Claude Code had already resolved its own session ID. The recorded UUID is cs's source of truth; the check surfaces drift.

- **Auto-memory bucket guidance in session CLAUDE.md.** `write_session_claude_md()` now includes an "Auto-memory bucket guidance" section with a per-bucket signal-phrase decision table (`user_*.md` / `feedback_*.md` / `project_*.md` / `reference_*.md`) plus dedup, lazy-load, and "never invent" discipline. cs's auto-memory taxonomy is fixed by the harness, but the guidance fills the "when user says X, write to Y" gap that the harness prompt leaves open. The block is wrapped in a `<!-- cs:memory-rules -->` HTML comment so the user can opt out by deleting the content and keeping the sentinel as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."

- **Lazy migration via `migrate_session()` Phase 9.** Existing sessions whose CLAUDE.md predates the bucket-guidance feature get the block appended on next launch. Idempotent (sentinel-presence skips), and respects user opt-out via the tombstone pattern. Same lazy-on-resume mechanism as Phase 7 (commands.md retirement) and Phase 8 (UUID backfill).

- **`/sweep` slash command for manual memory distillation.** New `commands/sweep.md` prompts the active Claude session to review the conversation in its context and write durable facts to `.cs/memory/*.md` (strict bar — default write nothing) plus substantive findings to `.cs/discoveries.md` (looser bar). Companion to the Feature 3 bucket-guidance block — the block tells Claude *where* to write durable facts continuously; `/sweep` asks Claude to look back over the whole session and do a focused distillation pass. No headless spawn, no auto-trigger, no consent gate — user invokes manually when they think a session surfaced something worth saving. Two-bar mental model: `memory` forever (strict bar), `discoveries` session-local (looser bar).

- **Session wrap-up cues in CLAUDE.md.** `write_session_claude_md()` now includes a `<!-- cs:wrap-cues -->` block listing strong wrap-up triggers ("shipped", "PR merged", "deployed", "let's call it") and soft triggers ("that works", "looks good" with corroboration). Claude is instructed to fire an `AskUserQuestion` with four options — Run `/wrap`, Run `/sweep` only, Run `/summary` only, or Not yet — at those moments. Detection runs in-context; no hook, no auto-fire. Tombstone opt-out via the sentinel pattern.

- **Lazy migration via `migrate_session()` Phase 10.** Existing sessions whose CLAUDE.md predates the wrap-cues block get it appended on next launch. Idempotent via sentinel-presence skip; same shape as Phase 9.

- **`/wrap` slash command for end-of-session distillation.** New `commands/wrap.md` runs both passes back-to-back: memory distillation first (strict bar, default write nothing), then a comprehensive session summary at `.cs/summary.md`. Companion to the wrap-cues block — the block suggests Claude offer `/wrap` at natural stopping points; `/wrap` is what to invoke when that prompt fires. Reduces the "which one of /sweep, /summary do I need?" friction down to one button.

### Fixes

- **`grep`-finds-itself in the live-duplicate guard.** The Feature 2 spawn guard was `ps -Ao args= | grep -F -- "$UUID"`, which puts `$UUID` in grep's own argv; `ps` captured grep's argv and grep matched itself, falsely blocking every non-stubbed spawn. Surfaced when the Feature 3 tests exercised multi-spawn lifecycles harder than Feature 2's own tests did (which used a stub `ps` that bypassed the bug). Replaced with a bash builtin substring match (`[[ "$ps_out" == *"$uuid"* ]]`) that runs entirely in-process and never exposes the UUID as a subprocess argv.

### Tests

- New `tests/test_uuid.sh` with 8 tests covering: new-session UUID allocation and `--session-id` spawn, resume via `--resume <uuid>`, lazy migration with idempotence and exactly-once frontmatter, `CS_CLAUDE_SESSION_ID` env export, doctor match + mismatch, live-duplicate refusal + `--force` override.

- New `tests/test_memory_rules.sh` with 4 tests covering: new-session block insertion, lazy migration append, idempotence (HTML-comment-specific count to avoid false-matching the prose mention of the sentinel name), and user opt-out via tombstone sentinel.

- New `tests/test_wrap_cues.sh` with 4 tests covering: new-session wrap-cues block, Phase 10 lazy migration, idempotence, and tombstone opt-out.

- Full suite (23 files) clean.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.5.1...v2026.5.2

## 2026.5.1

### Removed

- **CLI command capture (`command-tracker.sh`, `commands.md`, `/skillify`).** An empirical audit across 35 sessions and 3,918 logged commands showed 95.1% one-shot reuse — the `@.cs/commands.md` import in the session CLAUDE.md was injecting non-trivial context (~125K tokens for the largest session) without measurable model-behaviour effect, and the skill-promotion path almost never fired (2.2% of entries crossed the 3-uses-across-2-dates threshold). Retired: the `command-tracker.sh` PostToolUse hook, the `@.cs/commands.md` import block in the session-template CLAUDE.md, the `_doctor_check_command_leaks` audit (its data source no longer exists), the `/skillify` slash command, and the three data files (`commands.md`, `command-dates.txt`, `promoted-commands.txt`). Net diff: -757 lines across 14 files.

### Features

- **`cs -doctor` settings-hook resolve check.** New `_doctor_check_settings_hooks_resolve` walks every hook command in `~/.claude/settings.json` and warns when its `command` path doesn't exist on disk. Catches the class of orphan that `aboutme-validator.sh` exemplified — a feature-branch experiment registered in settings.json whose file was never shipped. Symmetric to `_doctor_check_command_leaks`: pairs a write-time guard (RETIRED_HOOKS) with an audit-time guard that requires no discipline.

- **Lazy migration via Phase 7 of `migrate_session()`.** `prune_commands_artifacts()` runs on every session open: deletes the four legacy data files and strips the `## Discovered Commands` block + `@.cs/commands.md` import from the session's CLAUDE.md. Idempotent; silent on already-clean sessions. No flag day, no central migration script — every existing session migrates transparently the next time it's opened.

### Fixes

- **`aboutme-validator.sh` retired from settings.json registrations.** A `wip/aboutme-validator` branch registered the hook in `~/.claude/settings.json` during dev installation but the file was never shipped; branch deletion left the entry orphaned, causing `/bin/sh: ~/.claude/hooks/aboutme-validator.sh: No such file or directory` errors on every PostToolUse-on-Write event. Adding it to the RETIRED_HOOKS arrays in both `bin/cs` and `install.sh` strips the orphan on next install.

- **Pre-existing executable-bit bug** on `tests/test_download_prompt.sh`, `tests/test_session_lock.sh`, and `tests/test_shadow_ref.sh` — these were silently reported as failed because the test runner conflated exit-126 (permission denied) with real test failures.

### Tests

- New `tests/test_prune_commands.sh` (5 tests) exercising the Phase 7 migration: legacy-data-file removal, CLAUDE.md @-include stripping, preservation of unrelated session data, idempotence, no-op on already-clean sessions.
- Removed `tests/test_command_tracker.sh` (366 lines) and 5 obsolete `_doctor_check_command_leaks` tests in `test_doctor.sh`.
- Five new tests for `_doctor_check_settings_hooks_resolve`.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.13...v2026.5.1

## 2026.4.13

### Fixes

- **Auto-memory redirect now actually works.** cs has been exporting `CLAUDE_CODE_AUTO_MEMORY_PATH` to redirect Claude Code's auto-memory writes into `<session>/.cs/memory/`. Verified across three independent methods (binary `strings`-grep, black-box `claude --print` introspection, and a community-maintained env-var index): Claude Code 2.1.x ignores that name entirely — the resolver reads `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`. cs now exports both names defensively, so memory writes from new sessions land in the cs-controlled path *during* the session instead of relying on the post-launch `cp+rm` migration to move them on the next session start.

- Side note for users: orphan memory files at `~/.claude/projects/<encoded-cwd>/memory/` from past sessions get migrated automatically on next launch by the existing `setup_auto_memory()` cleanup — no manual action required.

### Improvements

- `/simplify` review caught a recurrence of writing temporal/historical context into source comments (a CLAUDE.md violation). The auto-memory comment was rewritten to evergreen form and the duplicated `"$session_dir/.cs/memory"` literal was extracted into a local variable.
- README paragraph on auto-memory tightened to user-facing behavior; internal helper names and migration mechanics moved out of the public surface.

### Tests

- All 20 test files pass (97 tests across command-tracker, doctor, hooks, sync, secrets, etc.).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.12...v2026.4.13

## 2026.4.12

### Features

- **`cs -doctor` adds command-leak audit** -- New `_doctor_check_command_leaks` scans every session's `.cs/commands.md` under `$SESSIONS_ROOT` for two leak shapes: glued `-p<value>` on db CLIs (mysql/mysqldump/psql) and positional values to `cs -secrets set <name> <value>`. Reports file:line only, never the matched value. Flagged a real-world leak during testing where a dev MySQL admin password had survived three captures across 905 entries in a sibling project's commands.md.

### Fixes

- **Redactor blind spots in `hooks/command-tracker.sh`**:
  - **Glued short-flag** like `mysql -u admin -pSECRET` (POSIX `-p<value>` form, no separator). New rule scoped to `mysql|mysqldump|psql` only -- `docker run -p`, `ssh -p`, `cp -p` stay intact.
  - **Positional value of `cs -secrets set <name> <value>`** -- the call meant to keep the secret out of shell history was logging it in the runbook. New rule stops at shell separators so chained commands survive.

- **Trivial-filter dropped any `cd dir && <real-cmd>`** -- BASE_CMD looked at the literal first word, so `cd /tmp && cargo test` was filtered as trivial cd and silently skipped. Fixed by extracting BASE_CMD from the prefix-stripped command.

### Improvements

- **Categorizer matches leading verb instead of full-line substring** -- The `*build*` / `*test*` glob over the full command was misclassifying by *arguments*: `mysql ... LIKE '%build%'` landed in Build, `rg "testLoginParameter"` landed in Test, `fd "building_model"` landed in Build. Replaced with explicit leading-verb lookup table plus sub-rules for npm/yarn/pnpm/bun/cargo. New categories: **Search** (rg/fd/grep/find), **DB** (mysql/psql/sqlite3), **Remote** (ssh/scp/rsync/curl), **Git** (git/gh/hg). Existing Build/Test/Lint/Deploy/Dev/Other still work.

- **`strip_leading_prefixes` helper** -- Iterative fixed-point stripper for `cd path &&`, `export VAR=val;`, and inline `FOO=bar ` env-prefix forms. Used by both the trivial filter and the categorizer.

- **`/simplify` cleanup**: 5 `sed -E` invocations in the scrubber collapsed into one `sed -E -e ... -e ...` (saves 4 fork+pipe round-trips per Bash hook); 3 sed calls inside `strip_leading_prefixes` collapsed to 1 (saves 2 forks per loop iteration); `categorize_command` no longer re-strips since the caller already computed STRIPPED. Hot-path fork count drops from ~14 to ~4 per Bash command.

### Tests

- 5 new tests for redactor blind spots (glued mysql/mysqldump/psql, `cs -secrets set` positional, plus a guard that `docker run -p 8080:8080` stays unredacted).
- 11 new tests for categorizer rewrite (Search/DB/Remote/Git classifications, false-positive guards, env/cd prefix stripping).
- 5 new tests for `cs -doctor` leak scan, including a contract test that the doctor never echoes the matched secret value.
- `send_bash_command` test helper now uses `jq -n --arg` for JSON-safe escaping; the prior shell-interpolation form silently broke on commands with literal double-quotes.

### Docs

- README, `docs/hooks.md`, `docs/secrets.md` updated to reflect the new redactor patterns, categorizer scheme, and doctor check.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.11...v2026.4.12

## 2026.4.11

### Features

- **`cs -doctor` now audits Claude Code settings and tracks per-project token cost** -- Two new checks fold into the existing doctor flow (no new subcommands):
  - **Audit**: counts hook commands across all events, MCP servers, permission rules (allow + deny), and env vars in `~/.claude/settings.json`. One-line summary for security review and config-drift detection. Override the settings dir via `CS_CLAUDE_DIR` for testing.
  - **Tokens**: parses Claude Code transcript jsonl files in `~/.claude/projects/<encoded-cwd>/`, sums input + output tokens across all assistant messages in every session for the current project, and reports a K/M-suffixed total (e.g. `1.2M input, 340K output`). Override the transcripts dir via `CS_TRANSCRIPTS_DIR`.

### Fixes

- **`_doctor_check_hooks_registered` falsely flagged utility hooks** -- The check assumed every `.sh` in `~/.claude/hooks/` had to be registered in settings.json, which broke for `files-scan.sh` (a utility invoked by other hooks, deliberately absent from settings). Added a `UTILITY_HOOKS` array (currently just `files-scan.sh`) and skips utilities in the registration check.

### Improvements

- **Single-jq audit query and pure-bash path encoding** (post-`/simplify` cleanup):
  - `_doctor_check_claude_audit` now collapses 4 separate `jq` invocations of settings.json into 1.
  - `_doctor_check_token_cost` lets `jq` read transcript files directly instead of going through `cat`.
  - Extracted `_claude_encode_path` helper used by `setup_auto_memory` and `_doctor_check_token_cost`. Pure-bash form (no fork) replaces the prior `echo … | sed`.

### Tests

- 7 new tests in `test_doctor.sh`: audit-runs, audit-counts-correctly, audit-handles-missing-settings, tokens-runs, tokens-sums-jsonl, tokens-handles-no-transcripts, utility-hooks-not-flagged.

## 2026.4.10

### Features

- **`.cs/files.md` workspace index with pre-read context injection** -- New index at `.cs/files.md` carries one `## <path>` entry per workspace file with an optional hand-written description and a rough token estimate (`bytes / 3.75`). A new `PreToolUse`-on-`Read` hook (`files-context.sh`) looks up the target of each `Read` and injects the description + token line as `additionalContext`, so Claude can skip full file reads when the description suffices. The index is seeded on startup/resume by `session-start.sh` (background, non-blocking) via the new `files-scan.sh` utility, and `changes-tracker.sh` refreshes entries surgically on every Write/Edit while preserving descriptions. Hardcoded excludes for `.cs/`, `.git/`, `node_modules/`, `dist/`, `build/`, `.DS_Store`.

### Fixes

- **Latent `set -u` trap in `tests/test_lib.sh` asserts** -- The pattern `local path="$1" msg="${2:-$path should be a file}"` in ten assert helpers aborted the shell under `set -u` when the second argument was absent, because `path` was declared-but-unset while `msg`'s default expanded. Split into two `local` statements in all ten helpers (`assert_exists`, `assert_not_exists`, `assert_dir`, `assert_symlink`, `assert_file_exists`, `assert_file_not_exists`, `assert_file_contains`, `assert_file_not_contains`, `assert_output_contains`, `assert_output_not_contains`). No existing test triggered it; the new `test_files_scan.sh` was the first caller to rely on the default.
- **Install/uninstall parity for the new hooks** -- `run_uninstall()` in `bin/cs` was missing `files-scan.sh` and `files-context.sh` from its hook removal list, and the settings.json cleanup block had no `PreToolUse:Read` strip for `files-context.sh`. Added both.
- **Retired `aboutme-prereader.sh` and `gotcha-prewriter.sh`** -- Both shipped briefly in an earlier experiment, were removed from the source tree, but were never added to `RETIRED_HOOKS` -- so their settings.json entries persisted on installed machines pointing at files that no longer exist on disk. Added to the retired list so reinstalling strips them.

### Improvements

- **Single-jq hot-path in `files-context.sh` and `changes-tracker.sh`** -- Both hooks now extract `tool_name` and `file_path` in a single `jq` call via `@tsv`, halving the jq fork overhead on every Read/Write. `files-context.sh` also runs a `grep -Fxq` existence check before the awk lookup, so unindexed paths exit cheaply without scanning `files.md`.

### Tests

- 24 new tests across 4 files: `test_files_scan.sh` (6), `test_files_context.sh` (7), `test_changes_tracker.sh` (5), plus 6 in `test_hooks.sh` covering install.sh jq registration for `PreToolUse:Read` and `session-start.sh`'s initial-scan trigger.

## 2026.4.9

### Features

- **`cs -doctor` / `-diag`** -- Runs a set of health checks and reports PASS/WARN/FAIL status with colored output. Checks Keychain backend reachable, hooks registered in settings.json, hook files executable, git sync state (ahead/behind upstream), shadow-ref freshness, `discoveries.md` size vs budget, and auto-memory dir writable. Global checks always run; session-scoped checks only when inside a session. Non-zero exit on FAIL so scripts can chain on it.

### Improvements

- **`/release` now runs `/simplify` as Step 4** -- fans out three parallel review agents (reuse, quality, efficiency) over the pending release diff to catch duplication, hacky patterns, and inefficiencies before they ship. Validated by the subsequent test run.

### Fixes

- **Discoveries reminder no longer triggers metric-echo behavior** -- Added explicit guidance in the Stop-hook reminder message telling Claude not to prepend status metadata (e.g., "N chars -- under budget") to new discovery entries. The LLM would echo mentioned metrics as "helpful context" when the hook message included a file-size reference, creating ephemeral noise that was stale by the next session.

### Tests

- 7 new tests for `cs -doctor`: subcommand existence, default check set, healthy-session OK output, oversized discoveries WARN, non-executable hook FAIL, non-zero exit propagation, global-context fallback.
- 288 tests passing across 18 test suites (was 281).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.8...v2026.4.9

## 2026.4.8

### Improvements

- **Raise discoveries size budget from 20KB to 60KB** -- The 20KB default introduced in v2026.4.7 was too aggressive for sessions used as Claude's working memory. New 60KB default (~12-15K tokens) gives substantial headroom for long-running sessions while still staying well under 1% of a 200K context window.

- **`CS_DISCOVERIES_MAX_SIZE` env var** -- Override the default 60KB budget by setting this env var (in bytes) in your shell rc. Useful for sessions that are particularly knowledge-dense, or for users who want to be more/less aggressive about compaction.

### Renamed

- Internal var `MAX_CHARS` -> `MAX_SIZE` and "character budget" -> "size budget" in docs/messages, since `wc -c` measures bytes (not characters) and `MAX_SIZE` matches Unix tool conventions (`ls -l`, `du -b`, `wc -c`, `find -size`).

### Tests

- Added `test_reminder_env_var_overrides_default` -- verifies that `CS_DISCOVERIES_MAX_SIZE` overrides the default threshold.
- Refactored existing budget tests to use the env var with small thresholds for fast, reliable testing (instead of generating large test files).
- 281 tests passing across 17 test suites (was 280).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.7...v2026.4.8

## 2026.4.7

### Improvements

- **Character-budget discoveries management** -- Replaced the line-count archiver with a 20KB character budget. The old system used a PreCompact hook (`discoveries-archiver.sh`) that mechanically moved entries to an archive file at 200 lines -- a threshold borrowed from MEMORY.md's hard truncation limit, which was the wrong basis since discoveries loads fully through the CLAUDE.md protocol. The new system checks character count in the Stop hook and instructs Claude to summarize old entries directly into `discoveries.compact.md`. No intermediate archive file, one fewer hook, and a principled threshold based on context cost (~4-5K tokens).

### Removed

- `discoveries-archiver.sh` PreCompact hook -- replaced by character budget check in `discoveries-reminder.sh`
- `discoveries.archive.md` intermediate file concept -- old entries now summarize directly into `discoveries.compact.md`

### Other

- Updated `/compact-discoveries` command to work directly with `discoveries.md` instead of the archive
- Fixed `/release` command to cross-check against CHANGELOG.md to prevent listing already-released features
- 280 tests passing across 17 test suites (was 283 -- 6 archiver tests removed, 3 budget tests added)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.6...v2026.4.7

## 2026.4.6

### Features
- **Subagent detection in hooks** -- hooks now check for `agent_id` in the JSON input and skip side-effects (command tracking, discoveries reminder, session lifecycle events) when running inside a Task-spawned subagent. Prevents subagents from polluting parent session state.
- **Structured timeline log** (`.cs/timeline.jsonl`) -- session-start and session-end hooks append JSONL events with timestamp, source, session ID, and branch. Checkpoints also write timeline events.
- **`cs -checkpoint` + `/checkpoint` slash command** -- save labelled narrative snapshots mid-session. Captures discoveries, changes, git HEAD, and uncommitted files. List with `cs -checkpoint list`, view with `cs -checkpoint show <name>`.

### Fixes
- **Fix stdout leak in session-end hook** -- `cs-secrets export-file` printed to stdout inside the hook, causing Claude Code to report "Hook cancelled" on every session exit for sessions with age keys. Redirected to `/dev/null`.
- **Fix checkpoint error message** -- guard now says "must be run from inside a cs session" instead of misleading "CLAUDE_SESSION_NAME not set" when the real issue is a nonexistent directory.

### DX Improvements (10 items, built by 3 parallel agent teams)
- **Non-TTY help** -- `cs` with no args in a non-TTY context now shows a compact 5-line help instead of "cs-tui requires interactive terminal"
- **Post-install message** -- installer now shows "Getting started: cs my-first-session" after completion
- **Shell completions** -- added `-checkpoint` and `-search` to both zsh and bash completions with subcommand support
- **Checkpoint guard** -- `cs -checkpoint` verifies `CLAUDE_SESSION_META_DIR` exists as a directory, not just that the env var is set
- **Concepts section in README** -- explains sessions, discoveries, artifacts, checkpoints, timeline, auto-memory
- **Slash Commands section in README** -- documents /summary, /compact-discoveries, /checkpoint, /skillify
- **Timeline documented** -- in README session structure and docs/hooks.md
- **CHANGELOG.md** -- 683 lines covering all 43 releases
- **Release notes on update** -- `cs -update` now shows what changed after installing
- **CONTRIBUTING.md** -- dev setup, test workflow, hook/command addition checklists

### Other
- `/release` command now maintains CHANGELOG.md on each release
- Removed `cs -learn` / `cs -learnings` / `/learn` (YAGNI -- discoveries + auto-memory + search already cover cross-session knowledge)

283/283 tests passing.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.5...v2026.4.6

## 2026.4.5


### Fixes (silent hook failures)
All three fixes are the same root cause: `head -N` closes its input early, causing SIGPIPE upstream. Combined with `set -o pipefail` + `set -e`, this killed hooks silently mid-execution. Symptoms varied by hook:

- **session-end.sh**: when 6+ files were uncommitted, the FILE_LIST pipeline (`xargs basename | head -5 | paste`) crashed before reaching the `index.md` generation block. Sessions ended cleanly, the log recorded `Session ended (source: user_exit)`, but `index.md` was never created. This is why Obsidian users on v2026.4.3/v2026.4.4 saw no auto-generated index.
- **artifact-tracker.sh**: 3 separate `echo $content | grep | head -1 | sed` pipelines in `extract_and_store_secrets` could SIGPIPE on files larger than ~64KB with multi-line secret matches. **Most consequential**: when this hook crashes, the JSON allow decision is never printed and the entire Write tool call is silently blocked.
- **tool-failure-logger.sh**: `echo $ERROR | head -1 | cut` could SIGPIPE on tool errors >64KB (long stack traces), silently dropping the error from the session log.

### Tests
- Add regression test for session-end with 8 uncommitted files
- Add regression test for tool-failure-logger with 250KB multi-line error
- Total: 262 tests passing (was 261)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.4...v2026.4.5


## 2026.4.4


### Features
- **Migrate old sessions to YAML frontmatter** — existing sessions without frontmatter get `status`, `created`, `tags`, and `aliases` auto-added on next open. Derives `created` date from the README's Started line rather than using today's date. Preserves all existing content.

### Fixes
- Fetch remote tags before generating release notes (gh creates tags on GitHub, not locally).

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.3...v2026.4.4


## 2026.4.3


### Features
- **YAML frontmatter in session README.md** — new sessions get `status`, `created`, `tags`, and `aliases` fields. Enables Obsidian Dataview queries and Properties editor display.
- **`aliases` in frontmatter** — contains session name so Obsidian's quick switcher works (all files are named README.md without it).
- **`last_resumed` timestamp** — set by session-start hook on resume. Enables stale session detection via Dataview.
- **`updated` timestamp** — set by session-end hook. Enables sorting by last modification.
- **Auto-generated `index.md`** — markdown table at sessions root listing all sessions with status, objective, and created date. Regenerated on session end.
- **`.obsidian/` in session gitignore** — prevents Obsidian vault config from being committed.

### Docs
- Add Obsidian integration section to README with vault setup, recommended plugins (Dataview, Projects, Juggl), example Dataview queries, and graph view filter tips.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.2...v2026.4.3


## 2026.4.2


### Features
- **Cross-session context on resume** — when resuming a session, the session-start hook now injects a compact summary of up to 5 most recently active sibling sessions with their objectives. Gives Claude peripheral awareness of ongoing work without the user needing to mention it.

### Fixes
- Fix `grep` pattern parsing in `assert_output_contains` / `assert_output_not_contains` — patterns starting with `-` were interpreted as grep flags. Added `--` to terminate option parsing. (10/10 in test_auto_update now).
- Sort sibling sessions by `session.log` mtime (most recent first) instead of alphabetical glob order.
- Remove `install.ps1` references from `/release` command.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.4.1...v2026.4.2


## 2026.4.1


### Security
- Drop Windows support entirely — removes PowerShell injection vulnerability in credential backend, install.ps1, and cs.ps1 completions. Windows users should use WSL.
- Fix `grep -P` portability — invisible unicode detection in memory scanning was silently failing on macOS (BSD grep lacks PCRE). Now uses `perl` for cross-platform support.

### Testing
- Add 102 new tests (132 → 234 total, 15 test suites)
- **artifact-tracker.sh** (31 tests): path rewriting, secret detection, content redaction, MANIFEST updates
- **cs-secrets** (28 tests): encrypted backend store/get/delete/purge/export, session isolation, file permissions
- **sync functions** (19 tests): push/pull with local bare repos, config, auto-toggle, clone, memory scan blocking
- **session hooks** (24 tests): discoveries archiver/reminder, auto-approve, subagent context, failure logger
- Extract shared `test_lib.sh` from 11 test files (-573 lines of duplicated boilerplate)

### Code Quality
- Deduplicate CLAUDE.md session template into `write_session_claude_md()` (was copy-pasted in 2 functions)
- Deduplicate script-finder logic (`run_secrets()` now delegates to `find_secrets_script()`)

### Other
- Add staleness warning to commands.md import in CLAUDE.md
- TUI: hide Remote and Github columns when preview pane is open

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.13...v2026.4.1


## 2026.3.13


### Fixes

- **TUI crash fix**: UTF-8 safe string truncation in preview pane. Slicing at a byte index could land mid-character (e.g. en dash `–`), causing a panic when scrolling to sessions with multi-byte characters in memory entries. Added `truncate_str()` using `char_indices()` for safe boundaries.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.12...v2026.3.13


## 2026.3.12


### Features

- **Dynamic session context on resume**: SessionStart hook now injects session state (last activity, recent commits with changed files, objective) alongside static context
- **Bash command audit trail**: New `bash-logger.sh` PreToolUse hook logs every Bash command to `.cs/logs/session.log` with timestamps before execution
- **TUI: search filters while typing**: `/` search now filters results immediately as you type; Up/Down arrow keys navigate filtered results

### Fixes

- **Shadow ref crash recovery**: Autosave now fires on ALL Write/Edit (not just discovery files), preventing data loss for non-discovery files modified after the last discovery edit
- **Crash recovery asks before restoring**: Instead of auto-restoring from shadow ref, injects diff summary into context so Claude can present details and ask the user whether to restore or discard

### Docs

- Updated README with all new features, session structure, and `-search` in Usage
- Added `command-tracker.sh` and `bash-logger.sh` to docs/hooks.md
- Fixed stale hook timeouts in docs/hooks.md JSON config example
- Added install.ps1 parity verification to `/release` command

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.11...v2026.3.12


## 2026.3.11


### Fixes

- **SessionStart hook stdout fix**: Background auto-pull subshell and git checkout could leak stdout after the JSON output, corrupting it and causing "SessionStart:resume hook error". Redirected entire background subshell and crash recovery to `/dev/null`.
- **install.ps1 parity**: PowerShell installer was missing 5 hooks, 1 command, 5 hook events, async flags, and 30s timeouts. Now fully in sync with install.sh.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.10...v2026.3.11


## 2026.3.10


### Fixes

- **SessionEnd hook timeout**: Increased from 10s to 30s — `git push` to remote can exceed 10s on large repos, causing "Hook cancelled" and silent auto-sync failure
- **SessionStart hook timeout**: Increased from 10s to 30s — `git fetch` + `git pull` on resume can exceed 10s, causing "hook error" on session start

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.9...v2026.3.10


## 2026.3.9


### Features

- **CLI command capture**: New `command-tracker.sh` hook (PostToolUse on Bash, async) captures interesting commands to `.cs/commands.md` with filtering, secret scrubbing, categorization (Build/Test/Dev/Deploy/Lint/Other), and dedup with use count tracking. Loaded via `@` import in CLAUDE.md.
- **Skill promotion**: Commands used 3+ times across 2+ sessions trigger a suggestion to create a reusable skill via `/skillify`
- **`/skillify` command**: Creates Claude Code skills with proper YAML frontmatter (`name` + `description`), following official skill authoring best practices
- **Cross-session search**: `cs -search <query>` greps across all sessions' discoveries, memory, README, and changes
- **TUI memory preview**: Preview pane now shows first 5 lines of auto memory MEMORY.md
- **Memory security scanning**: Scans `.cs/memory/` for prompt injection and credential exfiltration patterns before sync push

### Fixes

- Plain text help output (removed colors from `cs -help`)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.8...v2026.3.9


## 2026.3.8


### Features

- **Plans redirect**: Claude Code plans now stored in `.cs/plans/` via `plansDirectory` setting, synced and cleaned up with session data
- **Auto memory env var**: Use `CLAUDE_CODE_AUTO_MEMORY_PATH` env var (set at launch) as primary mechanism for auto memory redirect, more reliable than settings file alone

### Fixes

- **Absolute path for autoMemoryDirectory**: `autoMemoryDirectory` only accepts `~/`-expanded absolute paths, not relative — fixed settings.local.json to use absolute path
- **Merge settings instead of overwrite**: `setup_auto_memory()` now merges into existing `.claude/settings.local.json` via jq instead of clobbering user's other settings

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.7...v2026.3.8


## 2026.3.7


### Features

- **Auto memory migration**: Existing sessions that have Claude Code auto memory at the default `~/.claude/projects/` location now get it automatically migrated into `.cs/memory/` on first open. No manual action needed.

### Fixes

- **Version regression fix**: Restored uninstall parity (3 hooks, 3 settings entries, cs-tui binary) that was accidentally reverted in a prior commit due to context compaction

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.6...v2026.3.7


## 2026.3.6


### Fixes

- **Uninstall parity**: `cs -uninstall` now removes all 10 hooks (was missing `subagent-context.sh`, `tool-failure-logger.sh`, `session-auto-approve.sh`), cleans up all settings.json entries (`SubagentStart`, `PostToolUseFailure`, `PermissionRequest`), and removes the `cs-tui` binary

### Process

- **Install/uninstall parity check** added as Step 2 in the `/release` workflow to prevent future drift between install.sh and run_uninstall()

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.5...v2026.3.6


## 2026.3.5


### Features

- **Auto memory redirect**: Claude Code's auto memory is now stored inside the session directory at `.cs/memory/` instead of the default `~/.claude/projects/` location. This means auto memory is synced across machines with `cs -sync`, cleaned up with `cs -rm`, and contained within the session. The redirect is configured via `.claude/settings.local.json` (gitignored, recreated by cs on each machine).

### Docs

- Updated session structure diagram in README with `.cs/memory/` and `.claude/settings.local.json`
- Updated sync docs to list auto memory in "What Gets Synced"

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.4...v2026.3.5


## 2026.3.4


### Features

**TUI overhaul** — 15 new features for the interactive session manager:

- Fuzzy search with per-character highlighting and scoring
- Time-based section headers (Today, Yesterday, This Week, etc.)
- Preview pane for wide terminals (>120 cols), toggle with `p`
- Row expand/collapse with Tab shows session preview inline
- Inline action bar replaces popup session menu
- Batch operations: Space to mark, D to batch delete
- Async sync operations with spinner (Esc to cancel)
- Peek mode for secrets with 5-second timed reveal
- Selection momentum accelerates on key repeat
- Quick create dialog with `n` key
- 2-second safety countdown on delete confirmation
- Row flash feedback after actions
- Gutter indicators as colored prefix spans
- Recency fading, status messages, stable sort selection
- Auto-hide empty columns

### Fixes

- Fix tab color: use printf `%b` to interpret `` as BEL in escape sequences
- Lock tmux window/pane title so Claude Code cannot overwrite it

### Docs

- Updated TUI section in README with all new features
- Updated secrets sync docs to document age encryption

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.3...v2026.3.4


## 2026.3.3


### Features

- **Session-based tab colors** — Each session gets a unique, deterministic tab color derived from its name hash. Same session name always maps to the same color across launches, making it easy to distinguish multiple sessions at a glance. 12-color curated palette ensures every color looks good as a tab.

### Fixes

- **Tab color works inside tmux** — Detect the outer terminal (iTerm2, WezTerm) via `$LC_TERMINAL`/`$ITERM_SESSION_ID` even when `$TERM_PROGRAM` is overwritten by tmux. Use tmux DCS passthrough (`ESC P tmux;`) to forward proprietary escape sequences to the outer terminal.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.2...v2026.3.3


## 2026.3.2


### Features

- **Generic terminal tab title and color** — `set_tab_title()` and `reset_tab_title()` functions set the terminal tab title (`cs: session-name`) and optional tab color when launching a session. Works across all xterm-compatible terminals (iTerm2, Terminal.app, Ghostty, Alacritty, WezTerm, Kitty, etc.). Also sets tmux window names when running inside tmux. Tab color support for iTerm2 and WezTerm via escape sequences — orange for local sessions, blue for remote. Title and color reset on session exit via EXIT/INT/TERM traps.

- Replaced iTerm-specific `it2check`/`it2setcolor` calls with generic `$TERM_PROGRAM` detection and standard escape sequences — no external binary dependencies.

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.3.1...v2026.3.2


## 2026.3.1


### Features
- **SubagentStart context injection**: New `subagent-context.sh` hook injects cs session context into spawned subagents so they know about session directory, artifacts, and secrets rules
- **Permission auto-approve for session metadata**: New `session-auto-approve.sh` hook auto-approves Write/Edit to `.cs/` files, reducing permission prompts for session bookkeeping
- **Tool failure logging**: New `tool-failure-logger.sh` hook logs failed tool calls to `.cs/logs/session.log` for post-session debugging
- **Async hooks**: `discovery-commits.sh` and `tool-failure-logger.sh` run with `async: true` for non-blocking execution
- **Custom spinner messages**: SessionStart and SubagentStart hooks return `statusMessage` for meaningful spinner text

### Fixes
- **SessionStart source filtering**: Skip auto-pull and crash recovery on `/clear` and compaction (session already running)
- **SessionEnd source filtering**: Skip artifact archiving on `sigint` for faster exit; log exit reason

### Docs
- Updated hook count from 7 to 10 across README and docs
- Added documentation for 3 new hooks and 3 new lifecycle events
- Fixed auto-sync commit message format in sync.md (removed wrong emoji)
- Fixed discovery autosave trigger scope in sync.md

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.16...v2026.3.1


## 2026.2.16


### Features

- **SHA-256 checksum verification** — `cs -update` now verifies downloads with SHA-256 checksums (zero external dependencies). minisign signature verification is preserved as an optional enhancement when minisign is already installed.

### Removed

- **minisign auto-download prompt** — `minisign_ensure_binary()` (~85 lines) removed. Users are no longer prompted to download minisign during updates. SHA-256 provides the baseline integrity check.

### CI

- Release workflow now generates `.sha256` checksum files for all release assets alongside `.minisig` signatures

### Other

- `install.sh` adds SHA-256 as primary verification for cs-tui binary downloads
- Updated tests for new verification model (82/82 passing)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.15...v2026.2.16


## 2026.2.15


### Features

- **TUI cursor navigation** — All text inputs (search, rename, move-to-remote) now support Left/Right arrow keys, Home/End, and Delete key for cursor movement. Previously, editing required deleting back to the mistake and retyping.

### Fixes

- **Update command shows "Reinstalling"** when version matches instead of misleading "Updating from X → X" message
- **Session-end commit messages** use plain text (`Session update:`) instead of emoji prefix

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.14...v2026.2.15


## 2026.2.14


### Features
- **Shadow ref autosave** — Discovery edits now autosave to an invisible `refs/cs/auto` shadow ref using git plumbing commands instead of committing to main. One clean commit is created at session end. Crash recovery restores autosaved changes on next session start.
- **Download consent prompts** — `minisign` and `age` binaries now prompt before downloading, with TTY detection for non-interactive shells and manual install suggestions.
- **Move-to is a true move** — `cs <session> --move-to <host>` now cleans up local session files after rsync, keeping only a `.cs/remote.conf` stub. Adopted (symlinked) sessions preserve project files.
- **Move-to progress** — Shows step-by-step progress messages during `--move-to` operations.

### Removed
- **Auto-update on session open** — Removed `cs -update auto`, `CS_AUTO_UPDATE` env var, and `.cs.conf` global config. Manual `cs -update` and update notifications remain.

### Docs
- Updated `docs/sync.md` to reflect shadow ref autosave behavior
- Updated `docs/hooks.md` with shadow ref descriptions and secrets export clarification
- Updated `README.md` to remove auto-update references

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.13...v2026.2.14


## 2026.2.13


### Security
- **Signed updates** — `cs -update` now downloads `install.sh` from immutable GitHub Release assets and verifies its [minisign](https://jedisct1.github.io/minisign/) signature before execution. Tampered installers are rejected.
- **Release pinning** — Updates are fetched from tagged releases instead of the `main` branch, eliminating the `curl | bash` from raw GitHub content
- **Binary verification** — `install.sh` performs best-effort minisign verification of `cs-tui` binaries when minisign is available
- **Auto-download minisign** — If minisign isn't installed, `cs` automatically downloads it to `~/.local/bin/` (macOS and Linux)

### CI
- Release workflow now signs all release assets (`install.sh`, `cs-tui-*`) with minisign
- `install.sh` is included as a release asset (no longer fetched from `main` during updates)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.12...v2026.2.13


## 2026.2.12


### Features
- **Session action menu** — pressing Enter on a session now shows a context menu with all available actions (Open, Delete, Rename, Move to Remote, Secrets, Push, Pull, Status). Navigate with j/k, select with Enter, or use shortcut keys directly. All existing shortcuts still work from Normal mode for power users.

### Fixes
- **Secrets list parsing** — fixed `parse_secrets_list()` not stripping the `  - ` bullet prefix from secret names, causing "Secret not found" errors when viewing or removing secrets from the TUI
- **Nerd Font lock icon** — corrected the codepoint for the lock icon in the TUI when using Nerd Fonts
- **CI runner** — switched macOS x86_64 build from retired `macos-13` to `macos-15-large`

### Docs
- Updated TUI section in README to document the actions menu and correct sort column range (1-6, not 1-4)

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.11...v2026.2.12


## 2026.2.11


### Features
- **Auto-update setting** — Opt-in auto-update (`cs -update auto on`) that updates cs automatically when a new version is detected on session open. Also available via `CS_AUTO_UPDATE=1` env var for CI/remote machines
- **Global config** — First global config file at `~/.claude-sessions/.cs.conf` with `get_global_config`/`set_global_config` helpers (same key=value pattern as sync.conf)
- **Hostname in session banner** — Session banner now shows the machine hostname with a host icon
- **TUI gradient title** — Interactive session manager shows a gradient title with version number

### Fixes
- **Hook path consistency** — Hooks in settings.json now use tilde paths (`~/.claude/hooks/...`) instead of absolute paths, preventing duplicate entries across machines

### Internal
- Tab completions updated for `-update auto` subcommand (bash and zsh)
- 9 new tests for auto-update feature, all existing tests passing

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.10...v2026.2.11

## 2026.2.10


### Remote Sessions (new feature)
Run cs sessions on remote machines while keeping `cs SESSION_NAME` as your single entry point. Remote machines need cs and Claude Code installed independently.

- `cs -remote add/list/remove` — host registry for named remotes
- `cs SESSION --on HOST` / `cs user@host:session` — create or connect to remote sessions
- `cs SESSION --move-to HOST` — migrate local sessions to remote (with remote `CS_SESSIONS_ROOT` detection via ssh)
- `cs -ls` shows a LOCATION column when remote sessions exist
- Transport: prefers Eternal Terminal (`et`), falls back to `ssh`, wraps in `tmux`
- `-sync` and `-secrets` blocked on remote sessions (connect first, then run from within)

### Fixes
- Fix `et` transport using `-t` (tunnel) instead of `-c` (command)
- Fix zsh completion exact-match greediness preventing ambiguous session names from showing menu
- Fix `docs/sync.md` behavior differences table inaccuracies

### Docs
- Add remote sessions section to README with examples
- Document session-level flags (`--on`, `--move-to`, `--force`, `-s`) in Usage section
- Add See also section linking iTerm2-dimmer

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.9...v2026.2.10

## 2026.2.9


### Bug Fixes
- Fix zsh completion not working when user's fpath uses `~/.zsh/completion` (singular) — installer now detects existing fpath config and installs to the correct directory
- Fix sync completion listing `init` instead of `remote` in both bash and zsh completions

### Documentation
- Fix incorrect auto-commit emoji in sync docs (was `🤖`, actual is `🔄`/`📝`/`📦`/`📋`)
- Fix incorrect commit message format examples in sync docs
- Fix discovery-commits.sh description to reflect heading-first priority
- Fix `sync remote` behavior table (not a no-op for local-only sessions)
- Add `[name]` parameter to `clone` command docs
- Fix hook count and session-end secret export precondition in hooks docs

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.2.8...v2026.2.9

## 2026.2.8


### Fixes
- Fix sync error messages referencing nonexistent `init` command (correct command is `remote`)
- Clarify sync remote example in README to show URL parameter

### Cleanup
- Remove unused global `INDEX.md` session index (nothing read it)
- Update session-end hook docs to reflect secrets export and descriptive commit features

### Internal
- Descriptive auto-sync commit messages
- Delegate `/compact-discoveries` to sonnet background subagent

## 2026.2.7

### Improvements

- **Descriptive auto-sync commits** - Session-end commits now list changed files (e.g. `🔄 3 files: discoveries.md, script.py, config.yaml`) instead of generic timestamps
- **Background discoveries compaction** - Stop hook triggers compaction as a background sonnet subagent instead of blocking the conversation

## 2026.2.6

### Improvements

- **Background discoveries compaction** - The stop hook now triggers compaction as a background task instead of blocking the conversation
- **Sonnet model for compaction** - `/compact-discoveries` delegates to a sonnet subagent via the Task tool, reducing cost for summarization work

## 2026.2.5

### New Features

- **Discoveries archive & compaction system** - Keeps `discoveries.md` lean for context loading while preserving all historical findings
  - New PreCompact hook (`discoveries-archiver.sh`) automatically rotates old entries to `discoveries.archive.md` when discoveries exceed 200 lines
  - New `/compact-discoveries` slash command condenses the archive into a compact LLM summary (`discoveries.compact.md`)
  - Stop hook now suggests running compaction when the archive grows large
  - `discovery-commits.sh` handles all three discovery files with distinct commit prefixes
  - `changes-tracker.sh` skips archive and compact files to reduce noise

- **Session locking** - PID-based lock prevents concurrent access to the same session from multiple terminals; use `--force` to override

### Improvements

- Discoveries reminder now reviews entries inline and appends new ones in background (split workflow)

### Bug Fixes

- Fixed `discovery-commits.sh` missing from uninstall hook cleanup

## 2026.2.4

### Bug Fixes

- **Fix `cs -list` silently stopping early** - `set -e` + `pipefail` caused the script to abort when a session log used the newer timestamp format (missing `Started:` line). Sessions after the first affected one alphabetically were silently dropped.
- **Fix unguarded `grep` pipeline in config reader** - Same `set -e` + `pipefail` issue could crash config lookups when a key wasn't found.

### Improvements

- **6x faster `cs -list`** (4.86s → 0.78s for 58 sessions)
  - Dump macOS Keychain once instead of invoking `cs-secrets` per session
  - Parse keychain dump and log files with bash builtins instead of forking subprocesses
- **Support new log format** - Sessions using the `YYYY-MM-DD HH:MM:SS - Session started` format now correctly show their created date.

## 2026.2.3


### Improvements
- Auto-commit messages are now descriptive instead of generic timestamps
  - Discovery commits use the discovery entry text as the message
  - Session-end commits summarize changed filenames (e.g., `Update session.log, discoveries.md (+1 more)`)
- All auto-commits are prefixed with a robot emoji (🤖) for easy filtering with `git log --grep='🤖'`

## 2026.2.2


### Fixes
- Allow dots in session names (e.g., `cs -adopt hexul.com`)

## 2026.2.1


### Features
- **Adopt existing projects** - New `cs -adopt <name>` command converts any project directory into a cs session in place, using symlinks to preserve conversation continuity

### Improvements
- Improved migration message visibility

## 2026.2.0


### Features
- **`.cs/` metadata directory** - Session metadata now lives in a hidden `.cs/` directory, giving users a clean workspace root for project files. Existing sessions are automatically migrated on first launch.
- **Age encryption for secrets sync** - Modern public-key encryption for syncing secrets across machines using [age](https://github.com/FiloSottile/age). Auto-downloads and configures on first use.
- **Nerd Font icons** - Set `CS_NERD_FONTS=1` for richer terminal icons (requires a Nerd Font)
- **NO_COLOR support** - Respects the `NO_COLOR` environment variable per [no-color.org](https://no-color.org)
- **Task list persistence** - Sets `CLAUDE_CODE_TASK_LIST_ID` so Claude Code task lists persist across sessions
- **Secret count in session list** - `cs -ls` now shows how many secrets each session has

### Fixes
- Fix `set -e` crash on session launch
- Fall back to fresh session when `--continue` finds no conversation

### Improvements
- Warm color palette for help, list, and session banner
- Session banner with gradient bar
- Keychain migration: prompt once, then show notification only
- Remove Bitwarden Secrets Manager backend (simplify to keychain/credential/encrypted)
- Document `-help`, `-version` flags and environment variables
- Document command aliases in README

## 2026.1.83


### Features
- **Age encryption for secrets sync** - Public-key encryption via [age](https://github.com/FiloSottile/age) replaces password-based secrets sync. Auto-downloads the age binary, generates keypairs, and encrypts to per-session recipients. No shared password needed across machines.
- **Resume fallback** - Selecting "continue" on a session with no previous conversation now falls back to a fresh session instead of exiting.
- **Task list persistence** - `CLAUDE_CODE_TASK_LIST_ID` environment variable enables task list persistence across session restarts.
- **NO_COLOR support** - Respects the [no-color.org](https://no-color.org) convention to disable all terminal colors.
- **Nerd Font icons** - Set `CS_NERD_FONTS=1` for richer icons (lock, sync, home) in session banners and listings.
- **Secret count in session list** - `cs -list` now shows how many secrets each session has.

### Fixes
- **set -e crash on session launch** - Fixed a crash caused by strict error handling during session startup.

### Improvements
- Warm color palette (rust/orange/gold) for help output, session list, and banner with gradient bar.
- Removed Bitwarden Secrets Manager backend (simplifying to OS keychain + age).
- Keychain migration notice shows once then becomes a banner notification.
- Documentation updates for environment variables, command aliases, and age encryption.

## 2026.1.82


### Features
- Add CLAUDE_CODE_TASK_LIST_ID environment variable for task list persistence across sessions

### Fixes
- Fix set -e crash on session launch (post-increment arithmetic expression returned falsy exit code)

### Documentation
- Document CS_SECRETS_BACKEND environment variable in README
- Expand session environment variables documentation

## 2026.1.81


### Features
- **Age encryption for secrets sync** - Modern public-key encryption replaces password-based sync; auto-configures on first export
- **Nerd Font icon support** - Set `CS_NERD_FONTS=1` for enhanced icons (mdi-lock, mdi-sync, mdi-home)
- **Secret count in session list** - `cs -list` now shows lock icon and count for sessions with secrets
- **NO_COLOR support** - Disable colors with `NO_COLOR=1` or automatically when piping (follows no-color.org standard)

### Improvements
- **Claude warm color palette** - Updated from Tokyo Night to warm rust/orange/gold theme matching Claude branding
- **Colorized help output** - `cs -help` now uses consistent warm color styling
- **Colorized list output** - `cs -list` matches help style with RUST headers and GOLD session names

### Other
- Removed Bitwarden Secrets Manager backend
- Documentation improvements for command aliases and environment variables

## 2026.1.80


### Improvements
- **Session banner redesign** - Gradient left bar (purple→cyan) matching install banner style
- **Consistent color scheme** - Blue labels, green version, cyan paths, gray status text

## 2026.1.78


### Features
- **Age encryption for secrets sync** - Modern public-key encryption using [age](https://github.com/FiloSottile/age). No shared password needed - just share public keys
- **Auto-setup on first export** - Age keypair and recipients auto-configure when you first export secrets
- **Keychain migration notice** - Notifies users about migrating to OS keychain on session start

### Improvements
- **export-file/import-file** now prefer age encryption when recipients are configured
- **sync_pull** automatically imports from `secrets.age` (with fallback to legacy `secrets.enc`)
- Improved documentation for environment variables and CLI flags

### Changes
- Removed Bitwarden Secrets Manager backend (simplifies codebase, age provides better UX)
- `CS_SECRETS_PASSWORD` is now marked as legacy option (age preferred)

## 2026.1.74


### Breaking Changes
- **Removed Bitwarden Secrets Manager backend** - Secrets storage now uses OS keychain (macOS/Windows) or encrypted files only. This simplifies the codebase and removes the `bws` dependency.

### Features
- Added keychain migration notice to session banner when secrets need migration

### Improvements
- Keychain migration now prompts once, then shows notification only on subsequent sessions
- Documentation now covers `-help`, `-version` flags and `CLAUDE_CODE_BIN`, `CLAUDE_SESSION_NAME` environment variables

## 2026.1.73


- Keychain migration now prompts once with default No, then shows notification only on subsequent session starts
- Tracks prompted sessions in `~/.cs-secrets/.migration-prompted`

**Full Changelog**: https://github.com/hex/claude-sessions/compare/v2026.1.72...v2026.1.73

## 2026.1.72


### Features
- Add visible keychain migration notice when starting sessions (displays in terminal banner when Bitwarden is configured but keychain secrets exist)

### Fixes  
- Fix `migrate-backend` command when Bitwarden is already active - add `--from` option to specify source backend
- Update migration notice to use correct command syntax

### Documentation
- Document `export-file`, `import-file`, and `migrate-backend` commands in secrets.md
- Add "Syncing Secrets Across Machines" and "Migrating Between Backends" sections

This is the first tagged release. Previous versions were distributed without tags.
