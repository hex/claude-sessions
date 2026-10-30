# Changelog

All notable changes to cs are documented here. Release notes are also available on [GitHub Releases](https://github.com/hex/claude-sessions/releases).

<!-- New entries group changes under Keep-a-Changelog headings (Added / Changed / Removed / Fixes / Docs), or Features / Performance where those fit the release. -->

## Unreleased

### Added
- `/cs-panel` opens a pane that lists the machine's cs sessions, one row each: the name (a feature under its base), `live` or `idle`, the last context reading, unread mail and the feature count. Tab or an arrow selects a row, and a strip above the rows offers what that row admits: `o` opens an idle session in the cs tmux window (`cs -spawn`), `m` sends it mail (the body typed into one dialog, delivered on stdin), `r` retires an idle feature: `/finish <task>` in this conversation when it is the base's lead, task mail `/finish <task>` to the base otherwise, which its user accepts. A live session has no `o`, this session has no `o`, `m` or `r`, a locked vault has no `m`. The pane sits inline above the prompt under tmux and docks beside the chat in fullscreen; it opens only when asked, and while open it reads `cs -list --porcelain` every minute while no turn runs, after each turn and after each press. Shipped as the `cs-panel` mod in `~/.claude/skills/`.
- `cs -list --porcelain` prints one tab-separated record per unarchived session cs can address: `name`, `live` (`1` or `0`, cs's own rule: a running lock pid or a context heartbeat within 15 minutes), `context` (`0`..`100` or `-`), `unread` (a count, or `-` behind a locked vault or in a session with no `.cs`) and `features` (the base's git-verified features). stdout carries records only; it refuses `--tag` and `--archived` beside it.

### Changed
- `cs -list` prints the cs-tui hint from the listing itself, so `cs -list --bogus` prints only the error.

## 2026.10.11

### Features
- A launch on a terminal that finds a newer cs asks once before the session opens: `cs X.Y.Z is available (you have A.B.C). Update now? [y/N]`. `y` runs `cs -update` and starts the same launch again on the new cs; any other key declines that version: the launch does not ask again until a newer release is out, and in the session the update mod says in one line that it is available and to run `cs -update`, instead of opening its pane (`/cs-update` still opens the notes). The banner line still names it. The launch asks nothing off a terminal, in a window `cs -spawn` or `cs <name> --remote` opened in tmux, or before the release's `SHA256SUMS.sig` downloads.
- `/finish` retires in one pass. While the feature conversation still holds its worktree, `cs <base> -retire-feature` stages the retire in the base (`.cs/local/retire-staged/<task>`, the captured commit and the `--force` decision) and answers `staged <task> <sha>: ...` instead of refusing. When that conversation ends, it mails the base, and the base's Stop hook starts the entry detached from the hook's own budget, every refusal intact, and reports `retired <task> <sha>` or the refusal in the turn that finds it ended. The entry re-reads the feature's lock under its openers' mutex right before removing anything, so a conversation reopened in between is staged again, never lost. `cs <base> -features` reads `staged` for such a worktree. The user closes the feature conversation when they are done there and types nothing else.
- A feature's brief carries `## Context` (the base commit and what this work builds on, what was tried here) and `## Review` (the test command and the independent review expected before the result) beside Goal, Done when, Constraints and Report back; `cs -spawn <base>@<task> --brief` refuses a brief missing any of the six, naming it, so the `/feature` skill's shape and the spawner hold one rule.
- `cs -update` and the web installer require an SSH-signed `SHA256SUMS` manifest to verify installer and picker downloads. They use `ssh-keygen` instead of minisign. The `cs-release-vX.Y.Z` namespace binds the signature to its release tag, and `cs -update` refuses a release older than the installed cs or an installer pinned to another tag.
- `memory-index-guard.sh refs` lists the memory entries that name a repo path, a `cs` verb or a `_cs_` identifier that no longer exists, one `dead:` line per reference, and `/wrap`'s memory pass runs it: at most five lines per sweep, the rest reported as a count. A file that lives outside the checkout is rewritten as an absolute path, not called gone. A worktree copy under `.claude/worktrees/` never keeps a reference alive.
- `refs` skips a reference followed on the same line by ` (gone YYYY-MM-DD)`, as in `` `hooks/old.sh` (gone 2026-10-22) ``, and leaves it out of its count: the sweep writes that marker, with today's date, for a thing that no longer exists anywhere, and deletes a marker whose reference resolves again. Any other text between the reference and the marker, or a date in another form, does not suppress.
- The status line has a new default layout, quiet: the items as text on the terminal's own background. The Claude mark, always coral, and the session name sit in one chip tinted with the band colour, the name bold in a dark shade of it on a light terminal and a light shade on a dark one. After it the labels and joiners fade toward the background run by run, a run being a group or an item a dot joins, from 35% to 55% of the way. The readings are bold in the terminal's own foreground and the branch is the terminal's green, its path before the last `/` faint, so both read on either theme. A reading past its warn threshold is bold amber, and a reading at crit and its label are a red chip of their own. The model's `✦` takes the colour of the effort word after it. At 256 and basic colours there is no fade and the chip is a gray; plain mode prints the plain line as before. `CS_STATUSLINE_LAYOUT=band` and `CS_STATUSLINE_LAYOUT=capsules` choose the other two layouts, and the capsules draw as before.
- The status line has a second new layout, the band, chosen with `CS_STATUSLINE_LAYOUT=band`: it draws the same items on one row as wide as the prompt, its fill fading cell by cell from the band colour to the terminal background, with a hot reading in amber ink and a group at crit as one red island. The band colour is `CS_STATUSLINE_BAND` (a palette name, `brand`, `periwinkle`, an `r;g;b` triplet, `session` or `none`), else the session's own colour, else the background lifted a step. The band desaturates a colour halfway and pulls it 78% toward the background, so it reads as a tint of the terminal; the lifted background stays unchanged. On a light theme the text is dark shades of the band colour, at regular weight. The width is `CS_STATUSLINE_COLS` as given, else the payload's `.columns`, the tmux pane's width or the terminal's, less `CS_STATUSLINE_FRAME` (default 4) for the frame Claude Code draws around the line. At 256 and basic colours the band is a flat fill; plain mode prints the plain line as before.
- In iTerm2 the status line follows a switch between light and dark mode while a session is open. It reads the pane's profile from iTerm2's preferences: a profile with separate light and dark colours follows the macOS appearance, and any other is light or dark by its background. The quiet chip and the band blend with that profile's background. It reads the profile at most once a minute and the appearance every five seconds, never over ssh, and inside tmux only while the attached client is iTerm2; `CS_NO_ITERM2=1` turns it off.
- A ctrl+g rewrite that drops a string the agent must find or run exactly as written still lands, followed by one line, `Kept from the original: …`, naming each dropped string in the order the prompt gave them: a code span, URL, path, `--flag` or `-verb`, `snake_case` or `SCREAMING_CASE` name, `@mention`, file name or quoted phrase. The check is literal and case-sensitive. A code span or quoted phrase counts as kept when the rewrite carries its text, with or without the backticks or quotes, and the line names a file name or path whole, up to its extension.
- The installer names cs's tips file, `~/.claude/skills/cs/tips.json`, in `spinnerTipsOverride.tipsFile` of Claude Code's `settings.json`, so a spinner tip says how to turn on the band's prompt bars. A `tipsFile` you named stays, and cs leaves its tip out. The installer records the choice in `~/.config/cs/tips-file`: `named` once cs names the file, `declined` once you take the pointer out, after which `cs -update` never names it again; delete that file and run `cs -update` to have it back. cs never touches your own tips, `label` or `excludeDefault`. `cs -uninstall` takes out the pointer only while it names cs's file and that file no longer exists, and deletes the record. `cs -doctor`'s mod drift scan reads `tips.json` too, and reports an edited or missing one.
- In a base session with feature worktrees, the `cs` band names them: `1 feature · fix-auth ready`, `3 features · 2 ready` or `2 features · none ready`, and a single feature that is not ready shows its state, as in `1 feature · fix-auth locked`. It reads `cs <base> -features --porcelain` when the session starts, after each turn and every 30 seconds while idle. While a feature is ready and no turn runs, the word is a button: a press runs `/finish <task>`, or bare `/finish` when more than one is ready. The band also counts the messages from other sessions waiting unread in this session's mailbox, as `mail 2`.

### Changed
- The `cs` band above the prompt is one thin line, two columns in: `rotate` (or `/clear now` and its `in Ns` countdown once a handoff is armed), `wrap`, the queue's start button and, while a `/finish` gate runs, `finishing <task> · gate <elapsed>`, each only when it applies; chords that share a prefix spell it once, bold in gray, and each key's own word in the session colour beside its label (`ctrl+x 1 rotate   2 wrap`). With `cs.bandPrompts` on in `/config` (off by default) the band ends in a bar per prompt on the transcript's live branch, after the name of one prompt: the newest, or with `cs.bandPrompt` set to `read` the one being read. That prompt's bar is thick, and a prompt the engine refused to scroll to has a dashed one. A press on a bar, or `/cs next|prev|first|last|N`, scrolls the transcript to that prompt. `cs.bandBars` (default 10) caps the bars: older prompts fold into one `…N` run and newer ones into one `M…` run. The `cs` chip, the rounded caps and the capsule fill are gone, and so is the Handoff pane: when the countdown starts, the handoff's next step is one toast, `cs: next step: <first line>`, cut to 160 characters, once per armed handoff. The `/finish` gate line joins the same band instead of drawing a second one.
- The diagram instruction the `cs-mermaid` mod gave the model moved from the mod's system prompt section into every session's `CLAUDE.local.md`, as the `cs:mermaid-diagrams` section (added to existing sessions on their next open after an update). Claude Code 2.1.308 ships a built-in security plugin that, on an organization account or a managed machine, skips a user plugin's `prompt.compose` hook, so the section never reached the model there; the engine reads `CLAUDE.local.md` itself. The mod now only draws, and the `cs-mermaid.drawDiagrams` option in `/config` turns off the drawing alone; to stop the instruction, delete the prose under the sentinel. `cs -doctor`'s `diagrams` row reads the section's state. The mod needs no Claude Code floor beyond function hooks.
- The session colour survives `/clear`, a rotation, an in-app `/resume` and a context-limit fork: the cs mod queues `/color <name>` from the session's state whenever a conversation begins inside the running Claude Code. Claude Code keeps `/color` in the conversation's transcript, so only a conversation born in the running process lost it; cs re-applied it at launch alone.
- Without a measured terminal background, the status line's capsules are a 10% shade of an assumed background in the theme's family (a dark grey on a dark theme, an off-white on a light one) instead of a fixed warm taupe, so they read as a translucent layer on any terminal. A measured background still wins.
- `cs -doctor` treats a status line command whose file runs `cs-statusline` (the agents-sidebar bridge) as cs's own: an OK row and the `Statusline caps` row instead of the hedged warning. The installer asks the one-time capsule caps question for such a command and never offers to replace it with `cs-statusline`.
- On a dark terminal the warning colour is a deeper amber, `251;191;36`, in place of the pale `253;230;138`, which read as yellow, and cell 214 in place of 221 on a 256-colour terminal. It marks a reading past its warn threshold in every status line layout and the agent rows, and the `cs` band's countdown and queue `▤`.
- The release workflow refuses to build a tag whose commit has no green Test run: a first job looks up the Test workflow's push run on `main` for exactly the tagged commit and fails unless it completed with `success`, naming the commit and the status and conclusion it found (a pull request's run on the same commit does not count: it tested the merge commit). A tag pushed by hand, on a commit that never reached `main` or whose run is still going, publishes nothing. Reported in #15. A release also stays a draft until every asset has uploaded, and an asset that is missing fails the release instead of publishing it without that file.
- The `cs` band's queue reads plainer. Its start button says `▤ run 2 queued tasks` (`▤ run 1 queued task` for one) instead of `▤ queue 2 · start`. The queue count, shown while that button is not, stands at the left where the button would, and says `▤ queue 2 running` while the queue runs. Both draw their `▤` in the amber the status line gives its queue count. A dim `·` parts the band's keys from the buttons and words after them. On a narrow line the start button keeps its count whole, `▤ run 12…`, or cuts to `▤…`.
- From inside a feature session, `cs -secrets set` adds a secret its base does not hold yet while a sibling feature is running. Every other write to the base's secrets still waits for the sibling, as does a `set` of a name the base holds, or of one that exports as the same `CS_SECRET_<NAME>` variable (`api-key` beside `api_key`); that refusal names the stored secret and its variable. A `set` also waits when cs-secrets cannot read the base's stored names. Another session still waits for the base and each of its features, whatever the name.
- ctrl+g leaves a prompt that is already precise as you typed it. The rewriter replies `=` alone for such a prompt and the buffer is not rewritten, so a clean prompt no longer waits for the model to repeat it.
- `/wrap`'s memory pass writes `measured on Claude Code <version>, <YYYY-MM-DD>` into an entry whose fact came from running something, the version from `claude --version` and the date from `date`, so a later session knows to measure again once the version moves. Before writing, it looks for the existing entry the new fact contradicts or extends and updates that one instead of adding a second. `/wrap`'s report ends each memory path with `supersedes: <file>`, `supersedes: none` or `updated in place`.

### Fixes
- cs refuses to create a feature from a detached base up front, naming the fix, instead of succeeding and failing at `/finish`. Reusing an existing `cs/<task>` branch says so, with how many commits behind the base its tip sits.
- A background you set in `CS_TERM_BG_RGB` before launching a session stays yours when the terminal's theme changes mid-session. The launch marked the theme it detected as automatic, and the status line read that marker as covering your background too, so it dropped it as stale. The launch now marks your background with `CS_TERM_BG_RGB_PINNED`.
- The installer binds Ctrl+X R and Ctrl+X W in the `Chat` context of `keybindings.json`, where Claude Code wants a `command:` binding. It put all four keys in `Global`. They still worked, but Claude Code 2.1.310 logs a warning for each command binding it finds there. The two band chords stay in `Global`, where the `cs` mod reads them. An install or `cs -update` over a file an earlier cs wrote moves the two command keys into the file's `Chat` block, or adds one, and says so. A key you bind to something else is still left alone, and a key a `Chat` block already holds under another spelling is not added again. `cs -doctor` names a key outside its context whatever you answered the installer. Unless you answered yes, its advice is the move to make by hand. `cs -uninstall` drops any block it leaves empty, a `Chat` block included.
- The `cs` band stays one line when it has more to say than the terminal is wide. With every word on at 80 columns it overran by 34 cells, and Claude Code, which never shrinks a button, squeezed its words and separators to one cell each and wrapped them down six rows. It now leaves words out until the line fits, first `mail N`, then the queue count, a features word you cannot press, the `/finish` gate word and the shared `ctrl+x` prefix, and each comes back when there is room. The countdown, the keys and the buttons stay while they fit. When they alone overrun, the features word and then the queue's start word shorten to end in `…`, the queue's never past `▤…`, then the keys drop their words right to left (`2 wrap` becomes `2`). Narrower still, the countdown, the features button and the queue button leave in that order, and only then the keys, right to left, so every key the band shows still presses its button; a button with no key bound cuts its word to `…` before it leaves. A cut that lands after a space drops the space before the `…`, in the band's words and in the rail's prompt label and its hover cards.
- The `cs-update` release-notes pane draws its version headings in the session colour. It handed Claude Code the colour's name (`red`, `blue`), which Claude Code reads as neither a colour nor a theme key and drops, so every heading came out in the default ink; it now passes the same rgb the status line uses, and a colour outside the palette keeps the default ink.
- The `cs` and `cs-update` mods no longer name themselves twice. Claude Code leads every toast, transcript notice and command reply a mod sends with the mod's name, and both mods began their own lines with it too, so they read `cs: cs: the rail has no prompts` and `cs-update: cs-update: could not record the finished update`. Their lines now start with what happened; one that starts `cs -queue` or `cs <base> -features` names a cs command.
- The installer refuses a `settings.json` that holds valid JSON other than one object before it places anything, with one line naming what the file holds (`holds a JSON array, not an object`, or `holds more than one JSON value, not one object`) and ending `nothing was installed`. cs accepted any file jq could parse, so the install deployed every file and then ended on a raw jq error such as `Cannot index array with string "hooks"`. `cs -statusline` refuses such a file with the same line, and `cs -uninstall` leaves it unchanged and prints the line as a warning.
- The notice cs prints once per machine about forced rotation says to press Ctrl+X 1 to go now. It said `press 1`, which the band does not answer to.

### Removed
- The mods design lab (`docs/mods-design-lab.html`, its layout engine and the bundled mod surfaces under `docs/surfaces/`) leaves cs. It now lives in its own project, outside this repository. The mods keep the exported draw functions and line tables it reads (`drawBand`, `drawPane`, `Drawing`, `drawFence`, and `TOASTS`, `ASKS`, `LOGS`, `REPLIES`, `COMMANDS` in cs and cs-update, cs-feed's `words.ts`), and `tests/test_mod_tables.sh` keeps every line the mods hand Claude Code in those tables.
- The iTerm2/WezTerm tab tint. A launch no longer colours its tab from the session name; the tab keeps its `cs: <name>` title, and the session colour stays inside the terminal, on the band's keys, the status line and the session pill. The twelve-colour name hash, the escape passthrough and the reset at exit go with it; `cs -doctor`'s iTerm2 row now reads only the attention bounce.

## 2026.10.10

### Features
- The `cs-mermaid` mod ships a `show-me` skill (`/cs-mermaid:show-me`). Ask "show me", "draw it" or "how does X work" about a flow or a layout and the model answers with a picture beside a few lines of prose: a `graph TD` flowchart first, since the mod draws those, else a pseudocode, call-tree, file-tree or diff sketch. The description makes the model pick it unasked when an answer fits.

### Fixes
- The feature retire's record walk is sorted, so the record it names when it refuses an unreadable inherited copy is the same on every filesystem.

### Docs
- The README opens with `cs <name>` as the one command. The picker is a line after the first run, not a step of it.

## 2026.10.9

### Added
- The `cs-mermaid` mod draws mermaid flowcharts in replies inline in the transcript: nodes as blocks coloured by their role in the flow (a decision amber, a start green, an end grey, a step lavender; a `style` fill wins), edges as lines with arrowheads and labels beside them (a `yes`/`pass` label green, a `no`/`fail` one red), in the light or dark palette of your `theme`. A chart it cannot draw (a subgraph, another diagram type, or one too wide for the terminal) stays a code block with the reason under it. The mod also tells the model, in a short system prompt section, that flowcharts draw here and to add one only for a flow that branches, loops or has four or more stages. `/config` → `cs-mermaid.drawDiagrams` turns both off; `cs -doctor` lists the section among its authority rows. Needs Claude Code 2.1.300 or later.

### Changed
- `tests/run_all.sh` hands suites to its lanes from one queue, longest file first, so a lane that finishes takes the next suite. `CS_TEST_SHARD=N/M` balances its shards by line count, and CI runs the bash suites as two shards per OS. A suite that runs long for its length carries `# run_all-weight: N` and counts as N times its lines; `test_install.sh` does, with 2, so it no longer shares a macOS shard with `test_worktrees.sh`. A suite file the gate cannot read stops it with `cannot read <path>`.
- `tests/lint_shell.sh` runs one shellcheck pass, one file per run across every processor, instead of two passes over every file in one process: about 3 minutes to under 20 seconds on a 14-core Mac. A file shellcheck cannot run on stops it with exit 2 and the file's name, where it used to read as `found errors`.
- CI cancels a pull request's older test run when a newer push lands (never on `main`), and skips the tests for a push that touches only `docs/superpowers/` or `docs/upstream/`, which no suite reads.
- When an open or `cs -adopt` changes a file for you, cs lists it under one `✳ cs updated these files` header, a row per change with the file in a column and the change beside it, and under the `.gitignore` row the one thing to do: commit it with your next change. These were separate sentences in green or amber, and amber also meant cs could not do something; that is all amber means now.
- Tests that wait on a background writer or a released stand-in wait on the event itself, through `wait_until` in `tests/test_lib.sh` (a command retried under a 120 s hang guard), not on a count of polls a loaded machine outran. That covers 17 suites, among them the iTerm tab-helper tests that went red in the full bash 3.2 run on `main`.
- Five tests that went red under load wait on the event they check: the status line's walker tests, uninstall's mount and live-session rechecks, the concurrent `cs -queue accept` race (a loser may print either honest refusal), the nested-child lead claim, and the rewriter's withheld elapsed time. `tests/test_lib.sh` gains `wait_for_file_or_exit`.

### Fixes
- The prompt rewriter retries with your Console API key whenever the first attempt answers "Not logged in", however long that took. It retried only a failure that took under five seconds, so on a loaded machine a key-only user's rewrite failed outright. Any other failure is still retried only when it was that fast.
- cs reads the terminal's theme before it migrates a session, so what the migration prints uses the light palette on a light terminal. It read the theme only at launch, after the migration had printed in the dark palette.
- The `.gitignore` cs writes for a new session names `.cs/session.lock` and `.cs/session.mutex.lock`, so a session created from this version gets no `.gitignore` row on a later migration. A session created before still gets the two lines, and the row asking you to commit them, once.
- The status line's background tmux walker kills a `ps` that has not answered after five seconds of wall time. It counted fifty short sleeps before, each of which ran long by its fork on a loaded machine, so the wait could outlast the ten-second walk mark and the next render started a second walker beside the first.

### Docs
- The README reads in one screen: install first, a 60-second first run, the status line, a feature table that links each feature to the guide with its detail, uninstall, and the documentation index. The command reference and the operational detail (sessions and locks, adoption, worktrees, the queue and mail, rotation, remote control, completion) moved to `docs/commands.md`; installer and settings detail to `docs/configuration.md`. Every claim was checked against `cs -h`, the source, the guides or a test; thirteen that nothing confirmed were dropped, and the Windows section with them (native Windows left in 2026.8.10).
- Six animated SVGs, each traced from a capture of the real program: the status line in five states, a first run (the launch and the picker), a reply gaining an inline Mermaid chart, the `cs updated these files` rows, and the queue count reaching the status line. They replace the status line screenshot.

## 2026.10.8

### Added
- `cs <name> --remote` serves a session through `claude remote-control`. It opens the session as `cs <name>` does, with the lock, migration and every variable a launch exports, then runs remote-control in its directory in place of claude. Sessions started from the Claude app or claude.ai/code get cs's hooks, memory, task list and secrets. `--permission-mode <mode>` sets the mode of those sessions (default: the mode `CLAUDE_CODE_BIN` sets, else `default`). Inside tmux it runs in its own window, `remote:<name>`, in the cs tmux session, with the sessions root and the claude of the shell that started it; elsewhere it runs in the terminal. It needs Claude Code 2.1.299 or later, and cs unsets `ANTHROPIC_API_KEY` for it. It refuses an older claude, `--force`, `-finish`, and a session that is open. When `CLAUDE_CODE_BIN` carries options after the command, cs runs remote-control with the command alone. It carries the permission mode `CLAUDE_CODE_BIN` sets, from `--permission-mode <mode>` or as `bypassPermissions` from `--dangerously-skip-permissions`, as remote-control's own `--permission-mode`, unless `cs <name> --remote --permission-mode <mode>` names one, which wins. It drops `--allow-dangerously-skip-permissions`, which remote-control does not take, and prints one line saying what it carried or dropped; the command's `--version` must then say Claude Code. It refuses any other option by name before it opens anything, a restrictive one such as `--disallowedTools` or `--settings` too, since the sessions remote-control starts would run without it, and a wrapper such as `op run -- claude` by its own words. cs runs remote-control with `--spawn=same-dir`, so a first run in a git directory never stops at the spawn-mode question in a tmux window where nobody can answer it, and the sessions it starts run in the session directory. While it serves, `cs <name>` refuses that session, `cs -live` and the session manager show it as `remote` with the server's pid, and `cs -doctor` reports it. `cs -rm` refuses to remove it, with `--force` too, before it removes any name on the command line, and the picker's delete refuses it whatever `[F]` would grant, inside a session or outside: `d` and `D` keep the confirm closed, and the removal reads `.cs/local/remote.pid` again at `y`, so it also refuses a session whose server started after the confirm opened, and a batch keeps that session while it deletes the rest. Outside any session, or from the served session itself, both say `Session <name> is served by cs <name> --remote (remote-control PID <pid>)` and how to stop it. The first conversation the server starts is the session's lead, as a local open's conversation is: it takes the queue, mail wake-ups, rotation and the attention flag. A conversation started while the lead's claude runs is a guest for its whole life, and the next one started after the lead's claude exits is the lead. The lead's end leaves `.cs/session.lock` to the server, and while the server runs no conversation it starts sets a tmux pane, window or tab title, so the window keeps its `remote:<name>` name and the tab its `cs: <name> (remote)` title. Ctrl-C or closing the window stops it, and cs then releases the session. cs records the server's pid in `.cs/local/remote.pid` and counts the session as served only while that pid runs `remote-control --name <name>`; `cs -doctor` removes a file whose pid no longer does, as after a restart. A seed `cs -spawn` staged for the session stays staged for the next `cs <name>`, and cs says so.
- `/rotate` and `/wrap` move the completed rows of the session's native task list out of Claude Code's task store into `.cs/task-archive/<date>/<actor>/<list>/`: each row byte for byte under `json/`, and a readable snapshot of the list in `tasks.md`. Each actor and each task list gets its own directory, so a feature's archive and its base's never meet, and `/finish` carries the feature's archive into the base. They ask the session once and keep its answer in `.cs/local/task-archive`, written through the same link check as cs's other writes there, so a `.cs/local` that links out of the session takes nothing. A rotation the cs mod forced, or ran from its one-key rotate button, never stops to ask: until the session has answered, it skips the archive that time. A `/rotate` typed later asks, unless the mod forced a rotation earlier in that conversation. The highest-numbered row always stays in the live list, so Claude Code never gives a new task an archived number. An encrypted session keeps the archive in its vault.
- cs leaves the task store untouched and says why when the store is a link, holds anything but task rows and Claude Code's lock and high-water files, or holds a row Claude Code's own schema rejects. It writes nothing while a link anywhere under the archive leads out of the session.
- A task archive run that stops part way loses no row: it copies every row before it removes any from the store, and the next run finishes the move without a second snapshot. An archived copy of a row that is still live refuses the run, naming the row and what to do.
- `cs -vet-session <dir>` exits 0 when git tracks no file in the session's `.cs/local` or `.cs/private`, and otherwise names the file and the command that untracks it. The `cs` mod, `/rotate` and `/wrap` ask it before they write there. `cs -help` lists it, it answers `--help`, and the bash and zsh completions offer it.

### Changed
- `cs -secrets` signs the age sync files it exports, and `import-file` takes an age file only when a key you pinned signed it. age only decides who can read a file. `.cs/age-recipients/` is in git, so anyone who could push to a session's repository could encrypt a file to your public key, and the next import merged it: a merge added their secrets without saying where they came from, and `--replace` let their file overwrite yours. An export now writes `secrets.<machine-id>.age.sig` beside the file, and the signature names the session. An import skips a file with no signature, a file signed by a key you did not pin (it prints the `age add` to run) and a file whose signature does not match, and names each one. `--allow-unsigned` also takes the files with no signature, which is every file written before this. An import refuses a file you name on the command line instead of skipping it. Password files (`.enc`) stay unsigned. Signatures do not expire, so an older signed file put back by someone who can push is still taken.
- Each machine's key for secrets sync is an ssh-ed25519 pair, `~/.cs-secrets/id_ed25519`, in place of the age key pair. age encrypts to it and `ssh-keygen` signs with it, so sync with age needs `ssh-keygen` from OpenSSH 8.0 or later. `age add` takes an `ssh-ed25519` key as well as an `age1...` one. A machine switches on its first export after the upgrade: it makes the key, rewrites its recipient file, pins it, encrypts again and signs. Each other machine's next export then refuses until you run the `age add` it prints. Every machine in a session needs this cs, because an older one does not accept an ssh key. cs keeps `age.key` and still decrypts with it.
- An export adds this machine's key to `.cs/age-recipients/` in a session that already has recipients. It did that only for a session with none, so a machine that joined later encrypted to the others and could not read its own file. When `<machine-id>.pub` already holds another key, the export stops and names the file. With age installed and no `ssh-keygen`, an export stops and says so; it used to write a password file.
- The bash and zsh completions offer the `cs -secrets` options (`--replace`, `--allow-unsigned`, `--session` and the rest) once the word starts with a dash.
- `/rotate`, `/wrap` and `cs -narrative rotate` make no commit. `/rotate` leaves the handoff, the superseded and pruned handoffs and the task archive on disk. `/wrap` leaves the memory entries, `.cs/summary.md`, the narrative cut and the task archive. `cs -narrative rotate` leaves the trimmed narrative and its archive chunk. They stay uncommitted until you commit them. `/rotate` used to commit the handoff, and `cs -narrative rotate` committed its cut under a `cs: rotate narrative` subject. cs still makes its one commit when it creates a session; `cs -adopt` and the flat-layout migration commit nothing.
- The session protocol in `CLAUDE.local.md` and the narrative reminder tell the model to commit files under `.cs/` only when you ask. The protocol, `/wrap` and the `rotate` skill name the only commits cs itself makes under `.cs/`: the one that creates a new session, and the merge `/finish` makes to integrate a feature. Existing sessions gain the protocol section on their first open after the update; delete its text and keep the `cs:session-commits` comment to opt out.
- The narrative budget is 128 KiB with a 64 KiB tail (`CS_NARRATIVE_MAX_BYTES`, `CS_NARRATIVE_KEEP_BYTES`), down from 224 KiB and 112 KiB. Every resume reads the whole live narrative, and the average read falls from about 168 KiB to about 96 KiB. A narrative already over the new budget gets the over-budget notice until `cs -narrative rotate` trims it.
- `cs -adopt` commits nothing. In a folder with no repo it runs `git init` on `main` and leaves every file for your first commit. In an existing repo it leaves the index alone, so work you had staged stays staged. It prints one line naming what it left for you to commit, such as `.cs/`, `.gitignore` and `.gitattributes`.
- Opening a flat-layout session moves its files into `.cs/` and commits nothing: the moves stay in the working tree, and in a git repo one line names them.
- An adopted session records in `.cs/local/state` how its features carry `.cs/`, and so does a flat-layout session in a git repo once an open moves it into `.cs/`. The record is `cs_mode: tracked`, or `cs_mode: ignored` when the project's own rules already ignore the `.cs/` directory. While git tracks nothing under the base's `.cs/`, cs refuses a feature of a `tracked` session with a line saying to commit `.cs/` or set `cs_mode: ignored`. Once git tracks `.cs/`, git carries it into every feature whatever the line says. A session with no recorded mode keeps its features' mode inferred from git, as before. While git tracks nothing under `.cs/`, a `cs_mode` that is neither `tracked` nor `ignored` refuses a feature and names the line to fix.
- The wrap-up cue in `CLAUDE.local.md` offers two answers, `Run /wrap` and `Not yet`, and the session protocol stops pointing at `/summary` and `/sweep`. On its first open after the update, a session whose cue block or protocol text is the text cs wrote gets the new text. That covers the line naming `/summary` alone that sessions from before June 2026 carry, their `## Summary Command` heading, which becomes `## Wrap-up Command`, and their Best Practices bullet, which now says to run `/wrap`. A block or line you edited stays unchanged, and so does a tombstone.
- Sessions created before v2026.5.5 keep some of that protocol text in `CLAUDE.md`, and the same open rewrites it there, line for line, leaving the change for you to commit. It does so only in a `CLAUDE.md` that cs wrote, one that opens with the `# Session Documentation Protocol` heading. A `CLAUDE.md` of your own stays unchanged, even where it repeats a line cs wrote, and so does the `CLAUDE.md` of a checkout cs keeps out of git. When cs cannot read or rewrite `CLAUDE.md`, the open warns and goes on, and the next open tries again.

### Removed
- The bash-logger hook. It ran before every Bash call to append the command to `session.log` as a `BASH:` line, which cost each call a hook process (about 1.4 s), and nothing in cs read those lines. The next install or `cs -uninstall` deletes the copy cs wrote and its `PreToolUse` entry in `settings.json`. A `bash-logger.sh` you wrote yourself stays, and so does its entry. The file goes only after `settings.json` stops listing it, so an install that stops early or runs without jq leaves the two together. A `session.log` still opens with its header and still records lifecycle events and tool failures; lines already written stay where they are. If a dotfile tool manages `settings.json`, remove the entry from its source too, or the next apply puts it back.
- The `/sweep` and `/summary` commands. `/wrap` runs both passes, and nobody typed the other two. The passes ship as `wrap-sweep.md` and `wrap-summary.md` in `~/.claude/hooks/cs/`, where no slash menu lists them, and `/wrap` reads them there. The next install or `cs -uninstall` deletes the `sweep.md` and `summary.md` that cs wrote into `~/.claude/commands/`; a file of yours under either name stays, and the install names it. The prose critic that only `/summary` ran went with it.

### Fixes
- A session removed with `cs -rm --force` while its claude was still ending, or while a hook or the status line was writing, no longer comes back as an empty shell. cs makes a session's directories one level at a time and only inside a `.cs` that exists, so no hook, status line render or cs writer builds a removed session again; a state write for a removed session stops with `could not create` naming the directory.
- A resumed conversation whose claude ended within three seconds because `cs -rm` removed its session no longer starts a fresh claude there. cs exits with claude's status instead of rebuilding the session's state.
- A feature opened in tracked mode on a checkout that has no `.cs` opens again: a `cs/<feature>` branch older than the base's `.cs`, or a new branch cut from a commit without the `.cs` the user has staged. Creating the feature makes its `.cs`.
- `/finish` retires a feature whose branch landed through a squash or rebase PR even when the PR's head is not the worktree's captured commit, or when there is no PR at all, as long as every file the branch changed is identical on the base, submodule pointers included whatever `.gitmodules` or `diff.ignoreSubmodules` says. When some file differs it still stops, and now names up to ten of the files that differ.
- When cs adds its ignore rules to a `.gitignore` that git tracks, the open now prints one line naming the rules and saying to commit the change, so a team's `.gitignore` no longer changes without a word.
- `/finish` report prints an error line naming the worktree when git cannot read the worktree's `HEAD`, instead of stopping without a word.
- The retire refuses, before it removes the worktree, a feature record whose path needs a new directory named `.cs`, and names it. It used to remove the worktree and then fail to fuse the record.
- A state write, the retire's base `.claude`, the status line and SessionEnd no longer fail when another writer made the same directory a moment before.
- `cs -status` and `cs -queue` refuse a session that `cs -rm` removed while its claude still runs, with `No such session` and nothing else, and cs delivers mail sent from such a session without making the sender's mailbox again.
- `cs` refuses to open a session when git tracks a file in `.cs/private`, as it already did for `.cs/local`. Once `.cs/private` exists, cs reads the task queue, the mailbox and the rotation marker from it. A repository could commit that directory with a queue marked as started, and the first finished turn after a clone handed the committed task to Claude as an unattended run. The check follows a `.cs/private` link to the directory it points at, so cs refuses a committed link beside a tracked directory too. For a `.cs/local` or `.cs/private` link that leads to the session's `.cs`, or to a directory above it, cs names the link with no untrack command, in whatever case the link spells the session's name, since that command would untrack the project. A feature worktree and `cs -adopt` run the same check. The error names the file and the `git rm --cached` command. A session's `.gitignore` now lists `.cs/private/`; an existing session gains the line at its first open after the upgrade.
- An open session no longer acts on a queue, mail or a rotation marker that git tracks. The refusal above runs when a session opens, so a `git pull` into a session that was already open could deliver a started queue, and the next finished turn handed its task out. That worked for `.cs/local` as well as `.cs/private`. Each hook now asks git once per run whether it tracks a file in that directory. While it does, the hooks hand out no task and show no mail, a `/clear` loads no handoff, and each finished turn shows a message with the file and the command that untracks it, in place of the narrative reminder. A `GIT_LITERAL_PATHSPECS` or another of git's pathspec settings in the environment no longer makes this check, or the one at open, miss a tracked file, and neither does configuration handed in through `GIT_CONFIG_COUNT` or `GIT_CONFIG_PARAMETERS`. cs asks with `core.fsmonitor` off, so a repository's config cannot make the question run a command. When git cannot answer at all, say for a bad value in the repository's configuration or an index it cannot read, cs refuses and shows git's message; only "not a git repository" still counts as nothing tracked. Named verbs such as `cs <name> -queue` now refuse the same way; they read a git that could not answer as nothing tracked. The lines `GIT_TRACE` or a trace2 setting print ahead of git's message no longer count as a failure, and a file git tracks there still counts after you delete its directory.
- Before cs asks git whether it tracks a file in `.cs/local` or `.cs/private`, it looks for a directory git would take for a repository. git, asked about a directory, takes the nearest one at or above it that holds `.git`, or one that holds `HEAD`, and runs the commands that directory's config names; a clone can commit such a layout anywhere in the session, or a link that leads into one. cs walks up from the directory as git's own search does, to the first directory that holds `.git`, and a directory on the way that holds `HEAD`, a link that leads nowhere included, counts as a tracked file: the open, a named verb, `cs -vet-session` and `cs -queue` refuse, and the hooks stand down. The walk compares directories by the filesystem and never by the spelling of their paths, so it also catches a committed `.cs/private` link into a layout in another directory a clone made, or one that spells the session's name in another case. The refusal names a directory inside the session relative to it, with the `HEAD` to delete. It names one outside it, such as a bare repository or a checkout's `.git` that holds the session, or a bare repository that is the session directory itself, by its whole path and ends `Run cs -rm to remove the session.`, since that directory can be your own repository.
- `cs -narrative rotate` hashes the archived text with `--no-filters`, so a repository laid out where it runs cannot make git run the clean filter its config names.
- `cs -adopt --worktrees` skips, by name, an entry under `.claude/worktrees` where git's own search would find a repository layout: the entry, or a directory above it before the first that holds `.git`, holds `HEAD`. It does this before it asks git anything about the entry, so a layout a clone commits there is never read as a repository. It asks git about each entry with an inherited `GIT_DIR` and the other variables that point git elsewhere ignored, and with `core.fsmonitor` off. It prints each entry's name with every character a plain path lacks replaced by `_`, so a name the repository chose cannot put a terminal escape on the screen.
- A refusal that names a link a repository committed prints the link's name and the path it points at with each character a plain path lacks replaced by `_`, cut at 160 characters, so a raw escape or bell byte, or backslash text, in a cloned session cannot reach the terminal. This covers the open's link checks, an unmounted vault link, a locked `.cs/private`, `cs -rm`, re-adopt, a write refused for a link out of the session, `cs -narrative rotate` refusing a narrative or an archive linked out of the session, `cs-secrets import-file`, and the auto-approve hook's decline.
- cs prints the file names a cloned session supplies through the same plain-name rule, cut at 160 characters, so an escape byte in one never reaches the terminal or Claude. That covers `cs-secrets`' import, export, key switch, `age list` and `age add`, `cs -search`, `cs -doctor`, `cs -tag list`, `cs -checkpoint list`, `memory-index-guard.sh check`, a refused write (the part of the path below the session, whether the write leads out of the session or git could not say whether it tracks a file there), a link under `.cs/task-archive` that leads out of the session, and the Stop and SessionStart hooks (narratives and commit author names in the resume digest). Text a clone supplies loses its control bytes: the line `cs -search` matched, a checkpoint's label in `cs -checkpoint list` and its whole file in `cs -checkpoint show`, and what a recipient file holds in `cs-secrets age list` and in `age add`'s refusal. `age list` previews only a recipient file's first line, so a newline cannot add a row. A character outside letters, digits and `._/@-` prints as `_`, so `Jane Doe` in the digest reads `Jane_Doe`. (#1009)
- cs offers and loads only a rotation handoff whose file name is plain: one name, with no `/`, of letters, digits and `._@-`, at most 160 characters. Every name the `rotate` skill writes is one, since its slug takes only lowercase ASCII letters, digits and hyphens, at most 60. The launch passes over any other and says in one line which directory holds it and to check who wrote it before renaming it. SessionStart removes a pending marker that names such a file, the launch ignores it, and the `cs` mod does not offer to continue from it. The mod reads the marker as the hook does in the C locale, dropping only ASCII whitespace. The resume digest names only a teammate narrative that is a regular file, not a link, with a plain name directly below `.cs/memory`. The recent commits list only the plain file names among the first five files the commits touched. A name with a shell metacharacter never reaches Claude as a path. `cs-secrets age add` suggests `age remove` only for a recipient name that is plain. (#1009)
- The `cs` mod starts no rotation while git tracks a file in `.cs/local` or `.cs/private`. A pull that brought in a committed pending-handoff marker and an unconsumed handoff started the 20 s countdown, and the `/clear` landed in an empty conversation, because SessionStart refuses to load a handoff git tracks. The mod now asks `cs -vet-session` before it acts: when a countdown starts and when it reaches zero, before a forced `/rotate`, when you press either button on the band, before it writes its heartbeat and before it clears the wrap marker. The rotate skill asks too before it arms the marker, so `/rotate` typed by hand still writes the handoff but arms nothing, and says why. It never asks while the band draws. A refusal shows once as a toast, and the next prompt asks again. With an encrypted session's vault locked, the skill arms nothing; it used to write the marker into `.cs/local`. A press on the band while the mod's own `/clear` is still running does nothing, so the conversation that `/clear` opened is not cleared a second time.
- While git tracks a file in `.cs/local` or `.cs/private`, nothing cs runs writes there except one line. SessionStart used to record the conversation id in `state`, stamp the context date, take the state lock and remove the attention flag. The prompt hook stamped its date and removed the attention flag, the status line wrote `context-pct` and `limits` with their `.at` files, the cs-update mod wrote its heartbeat and its finished-update marker, SessionEnd's vault waiter wrote its pid files, `/wrap`'s last pass wrote `wrapped`, and `cs -status` set or removed `presence`; `cs -status` now refuses those two. The waiter still detaches the vault. The ctrl+g rewriter wrote its `rewrite.trace` there, and `memory-index-guard.sh`, which `/wrap`'s memory pass runs, took its snapshot there and could `restore` a committed `memory-index.snapshot` over `MEMORY.md`; the rewriter now writes no trace, and the guard refuses `snapshot`, `check` and `restore` and names the file. Each of those showed up in `git status` as a change to the repository's files. The status line cannot ask git on every render, so it reads a mark the hooks keep at `~/.cache/cs/tracked/<session name>`, and it misses a pull until the next hook runs. It reads the mark only for a session name the hooks would mark, so a name that is empty or holds `/` cannot match a stray path under `~/.cache/cs/tracked` and stop the context and limits stamps. The one write left is the prompt hook's launch line in `scope-prompt.trace`, which it makes before anything that can stall.
- `cs -adopt` refuses a project before it writes into it when `.gitignore`, `.gitattributes` or `CLAUDE.local.md` is a symlink to a file outside the project. Adopt appends to all three, and the check for such links ran only at the first open, after the appends. A cloned project that committed those links got cs's lines added to whatever files they pointed at, and adopt reported success.
- The permission hook approves fewer writes under `.cs/`. At the root of `.cs/` it now approves only a Markdown file. It used to approve files cs reads later: the Stop hook's cooldown stamp, `session.mutex.lock`, `archived`, `timeline.jsonl`, and a file named like a control directory cs had not made yet (`private`, `claude-config`). A write to `CLAUDE.md` or `CLAUDE.local.md` prompts anywhere under `.cs/`, and so does a write inside a git directory kept there, a bare clone or a worktree's included. The hook takes a directory for a git directory by the rule cs refuses a session's state by: the write's directory, or one above it before the first that holds `.git`, holds `HEAD`, a link that leads nowhere included. A write of a file named `HEAD`, `commondir`, `gitdir`, `config` or `config.worktree`, in any case, prompts too, since writing those in the right order would build a git directory there one approved write at a time. A hook deployed without `cs-shared.sh`, or with one that lacks the rule, approves nothing and says why on stderr. A name with a character outside ASCII prompts too. The Mac filesystem reads a long s as `s`, so `.cs/` held other spellings of `session.lock` and `age-recipients/` that the hook's string checks did not see.
- A claude started as a direct child of the lead claude no longer passes for the lead, and a claude that cs starts through a `CLAUDE_CODE_BIN` that forks it (`op run --`, a wrapper script without `exec`) is now the session's lead conversation on a resume where cs stays as claude's parent, as it already was where claude replaces cs. The hooks know the lead by the pid cs hands on, and also accepted a claude whose parent has that pid, for the one resume that runs claude as cs's child. On every other launch that pid is the lead claude's own, so its child (a mod's process run, a hook that `exec`s `claude -p`) could take the armed rotation and remove the lead's lock when it ended. Behind a forking `CLAUDE_CODE_BIN` on that resume, claude sits below cs's child, so its hooks took the lead for a guest: the recorded conversation was not rebound, a `/clear` did not load the rotation, and the mail wake and the tmux title stayed off. The lead now claims its launch at every SessionStart in `.cs/local/lead-pid` (launch pid, claude pid, conversation id), and two claudes that start at the same moment take turns, so the lead holds the claim. A launch clears a claim an earlier launch left, removes a link in its place, and refuses to open over a directory there, which it names. When the session's conversation ends (not at a `/clear` or `/resume`), the lead marks its claim ended and leaves it in place, so a `claude -p` that another SessionEnd hook starts is a guest whether it starts before the lead exits or after: it leaves the recorded conversation, an armed rotation, the queue digest and the attention flag alone. A claim naming pid 0 or -1, or with anything after the conversation id other than `ended`, counts for nothing, and a claim without the end mark whose claude has exited holds nothing. A `CLAUDE_CODE_BIN` wrapper must `exec` claude or start exactly one claude: the hooks take a claude the wrapper runs before the real one for the lead. A session opened before this update has no claim, and until you open it again only the claude carrying cs's pid is its lead and every other claude under that launch is a guest. A `claude -p` started there cannot rebind the recorded conversation or remove the lock, and takes neither an armed rotation nor the queue digest nor the attention flag. Where cs runs claude as its child, or a `CLAUDE_CODE_BIN` forks it, the lead of such a session is a guest too. Its `/clear` loads no armed rotation, which the next open offers; its mail wake, queue drain and tab title stay off; and behind a forking wrapper where claude replaces cs, an encrypted session's vault stays attached until the next open.
- The Stop hook reads its cooldown stamp as a plain number. It went into shell arithmetic with only the whitespace stripped, and bash runs a command substitution it finds in an array subscript there. The permission hook approved a write to the cooldown stamp, so text written to it ran at the next Stop.
- The first write into `.cs/handoffs/`, `checkpoints/`, `narrative-archive/`, `memory/`, `plans/` or `research/` no longer prompts when the directory does not exist yet. The hook needed the parent directory to exist, so a session's first handoff asked for permission. Any other missing directory still prompts, and one of these prompts in an encrypted session, which keeps them in its vault.
- A `claude -p` started from inside a session no longer takes the lead's armed rotation or its queue digest, and neither does a tmux teammate. Their SessionStart consumed the handoff `/rotate` had armed, so the `/clear` that followed loaded nothing, and it spent the digest cs shows once. The `claude -p` also no longer raises the attention flag when it ends.
- Running the tests from inside a cs session no longer writes into that session. No suite cleared `CLAUDE_SESSION_NAME`, `CLAUDE_SESSION_DIR` or `CLAUDE_SESSION_META_DIR`, so `tests/test_dispatch.sh` put a sent copy of its `hello` mail in the live session's mailbox on every run, signed with that session's name. `tests/test_lib.sh` now drops all three when a suite loads it. It also drops `CS_SECRETS_SESSION`, which a feature worktree exports and `cs-secrets` reads ahead of the session name, and `XDG_CONFIG_HOME`, through which the uninstall tests could delete your status line and key preferences. `CS_CLAUDE_DIR` and `CLAUDE_ENV_FILE` go too: with the first set, the install tests rewrote the status line in your own `settings.json`, and with the second, a test that runs the SessionStart hook appended its fixture session to your environment file.
- `cs -secrets import-file` checks every secret name before it stores any. An import took a sync file holding `api-key` beside `api_key`, or beside an `api_key` already stored, and `cs -secrets export` then refused the whole store until you deleted one by hand, because both names become `CS_SECRET_API_KEY`. The import now refuses and names both. An invalid name stopped the import after the names sorted before it were already stored. For a name ending in a carriage return the import reported one secret imported and stored an empty value under the name without it. `import-file` also refuses a session the sessions root does not have; it printed "No sync file found" and exited 0.
- `/finish` no longer writes through a link the feature committed under `.cs/`. The feature's commits land in the base before cs records the landing and fuses the worktree's records, and nothing had checked the base for links since it opened. A link at `.cs/timeline.jsonl` took the landing's timeline entry and the fused records, and `MEMORY.md` committed as a link took the feature's memory pointers. Every write `/finish` makes into the base now goes through the same link check as the hooks, and cs names the link and writes nothing outside. A linked `MEMORY.md` stops the landing with the base untouched. A linked timeline lets the landing through without its entry, and the retire then keeps the worktree's records in a staging directory and says where. The base keeps what the fuse wrote before it stopped, so that copy can repeat records the base already has. Every timeline entry the cs commands write (rotation, checkpoint, narrative rotation, the queue gate) goes through that check too.
- The link check that keeps cs from writing through a committed link now covers every write a hook makes into a session, and the session files `cs -secrets` writes. It used to find the session from `CLAUDE_SESSION_DIR`, so a write made with the variable unset, or `cs -secrets --session` writing into another session, went unchecked. It now finds the session from the path it writes to. The check also covers appends and new directories, a new directory at its nearest existing level, so `mkdir -p` under a linked folder no longer gets through. A link anywhere between the path and the session counts, and so does a chain of more than 16 links. The Stop hook leaves a task queue alone when a link carries it out of the session, and `cs -secrets export-file` checks the sync file it writes, the default one or one you name inside a session. A path or link target with a name that ends in a newline is refused too: the shell drops that newline when it reads the path, so a committed link to `t` plus a newline, beside a decoy file `t`, passed as inside. A link under `.cs/claude-config` leads out only in a session with a vault: one with a `.cs/local/pre-open`, which `cs -encrypt` writes. A clone can commit the vault's layout but not that file. A hook skips such a write and names the link on stderr, and `cs -secrets` refuses it and exits 1. Writes made by cs's own verbs are not covered yet.
- The Handoff pane now closes before the forced rotation's `/clear` runs, whether you press the band, let the countdown reach zero, or type `/clear`. `/clear` does not close a plugin's pane, and the `cs` mod closed it only when its own countdown said one was open, without waiting for the close. An install while the pane was open reloads the mod, which then held no countdown, so the pane stayed open beside the new conversation. A prompt you send while the pane is closing still stops the countdown's `/clear`, and if another plugin's hook keeps the pane open, a toast says so.
- The narrative reminder now says never to push a commit that holds narrative appends unless the user asks. A session whose own notes said to push after each commit was pushing every narrative commit to a deploy branch, and each push started a redeploy.
- When a walk-away run's context or five-hour breaker trips, the drain now records the queue as idle before it takes the finished task off the queue. If cs could not write `queue.state` (an immutable file, for example), the task was already off, the state stayed `draining`, and the next Stop logged the following task done without handing it out. A failed write now ends the turn with nothing taken, and the next Stop logs the right task.
- A task the agent reports as not completed (`cs-task-failed`) now stays that way when cs cannot record the queue as idle. The report lived only in that Stop's message, so the next Stop saw nothing wrong, took the task off the queue and logged it done. cs now writes the report to `queue.failed` first, and each later Stop parks on it until cs can write `queue.state`.
- `/finish` no longer brings back a memory topic the base deleted while the feature was open, in a session whose `.gitignore` lists `.cs`. The feature starts with a copy of the base's topics, and the retire copied back every topic the base lacked, its `MEMORY.md` pointer too. The feature now records what it inherited. A deleted topic the feature never touched stays deleted. One the feature edited comes back with the feature's text, and the retire names it. A feature created before this version has no record, so a topic the base also edited stops its retire. Also, a file under `.cs` whose name holds a newline no longer makes `/finish` refuse the retire as if it were your own untracked file.
- `cs -secrets age add`, `age remove` and `export-file` refuse a session the sessions root does not have. They used to create it: an `age add` after a `cs -rm`, or with a mistyped `--session`, left a directory holding only recipients, and a pin list under `~/.cs-secrets/sessions/<name>/` that a later session of that name inherited.
- `tests/run_all.sh` stops a suite after 1200 seconds, up from 600. `test_install.sh` now takes about 600 seconds when the whole gate runs, so it hit the old cap and had to be rerun on its own.
- `cs -adopt <name> --yes` (or `-y`) re-adopts a directory whose `.cs/` records outlived their session link without asking, so a script or an agent with no terminal can do it. With no terminal and no `--yes`, adopt refuses and names the flag. `cs -adopt` also refuses an option it does not know.
- Re-adopting an encrypted session while its vault is locked now refuses before it changes anything and names the link that leads nowhere. It used to stop partway, after replacing the conversation the session's state named, and leave no session link.
- The `cs` mod (rotation band, forced rotation, heartbeat) treats a directory as a cs session only when the sessions root has an entry for it, under the directory's own name or the `session_name` its state records, that resolves to that directory. A cloned repo that carried `.cs/local` used to be enough. The hooks already check this.
- `cs -rm` and the picker's delete now drop the age state of a base session they remove, `~/.cs-secrets/sessions/<name>/`. It held the recipient pins and outlived the session, so a new session of the same name trusted the old keys. A feature (`base@task`), an adopted link and an old dotted name keep it. When the drop cannot run, the message names the path and the other names are still removed, then `cs -rm` exits 1. That covers a failed `rm`, a `~/.cs-secrets` or `sessions` folder that is a symlink, and one cs cannot search.
- `cs -rm` and the picker no longer list cs's own old root files (`notes.md`, `changes.md`, `discoveries.md`, `logs/`, `artifacts/`) as files cs does not own, so removing an old session no longer asks for `--delete-files`.
- A feature of a session whose `.gitignore` lists `.cs` now starts with the base's memory topics, `MEMORY.md`, `plans/` and `summary.md`. Git cannot carry them there, so the feature used to start with none. `plans/` comes over file by file, regular files only, so a link inside it stays behind.
- `/finish` keeps the `MEMORY.md` pointers a feature added. The base copy wins the merge, which used to drop them. `/finish` appends each pointer once, after the base's own lines, and only when its topic file is in the base after the merge. A pointer the base's memory archive names counts as indexed, so a feature's older `MEMORY.md` does not bring back a pointer the base moved there. In a session whose `.gitignore` lists `.cs`, the retire merges the archive the same way: the base keeps its own lines and gains each feature pointer it does not name, or takes the feature's archive whole when it has none. A feature that never changed the archive it inherited brings nothing back, so a line or a whole archive the base deleted stays deleted.
- `/wrap`'s memory pass can move a pointer line, unchanged, from `MEMORY.md` to the end of `.cs/memory/reference_memory_archive.md`, a reference entry that `MEMORY.md` points to, when the entry's subject no longer exists or a test, hook or CI lane now enforces its rule. When the index is over budget it does this first, before it rewords any pointer, and over the line budget nothing else helps: with nothing to move, the pass asks. A rule that has to fire before a proposal and a narrative pointer stay in `MEMORY.md`. Entry files never move and are never deleted. The first move writes the archive with a fixed frontmatter, so two clones that each make one write the same header. After that a pass changes the archive only by appending a pointer, updating one when its entry changes, or deleting one copy on `duplicate:`.
- `memory-index-guard.sh check` fails past 196 lines of `MEMORY.md` as well as past 24400 bytes, and prints both counts against their budgets. Claude Code stops reading the file at 200 lines or 25,000 bytes. The guard counts lines as Claude Code does, never fewer: blank and heading lines, a last line with no newline, and a lone CR, U+2028 or U+2029 as a line break.
- `check` reads the archive as a second source of pointers. It names a pointer moved there from `MEMORY.md` `demoted:` and passes it. One in both files fails as `duplicate:`, and the sweep deletes one copy, the archive's when the entry is a rule that has to fire before a proposal and the `MEMORY.md` one otherwise, and keeps the other as it stands. A pointer in either file whose entry file is not in `.cs/memory/` fails as `dangling:`, and the sweep stops to ask; a pointer to a URL or to a section of a file (`file.md#section`) is not checked. `snapshot` copies the archive too, so a pointer dropped from both files fails as `removed:`. The archive needs its own pointer in `MEMORY.md`, or `check` names it `unindexed:`. In an encrypted session the archive's snapshot sits behind `.cs/private` beside the index's: `cs -encrypt` moves both into the vault, and an open refuses a plaintext copy of either left in `.cs/local`.
- A session's `.gitattributes`, and the clone-local attributes `/finish`'s merge reads, mark the memory archive `merge=union`, so pointers a base and its feature each moved there all land instead of conflicting. The first open after upgrading adds the line to the `.gitattributes` of every session in a git repo but an adopted Claude Code worktree, and leaves it uncommitted. cs counts each of its four merge lines (`MEMORY.md`, the timeline, the narratives and the archive) as present only as a whole line, and starts each line it appends on a line of its own when the file ends without a newline, so where an earlier append glued one onto the line before, cs appends it again where git can read it.
- A bare `ctrl+x` in `~/.claude/keybindings.json` now gets one installer warning, naming the four chords cs leaves unbound and the action your key runs. It used to get one warning per chord. The same goes for a file that already holds cs's chords beside the bare key.
- `cs -spawn` stages a spawn as one file. A `--brief` now rides inside the seed after a `--- cs-spawn-brief ---` line, and `cs -spawn` writes the seed under its own name and publishes it with one `ln`, which refuses an existing name. Two spawns of one name started together could both pass the pending-seed check, and a task-only spawn could launch with the other spawn's brief, past the consent check that guards the seed. A spawn killed halfway left a `<name>.brief.md` that made every later `--brief` spawn of the name fail. Now one spawn wins and the other stops with "A pending spawn exists". The launch ignores a `<name>.brief.md` beside the seed. A spawn killed before it published leaves a `.<name>.seed.XXXXXX` file that no launch reads; `cs -rm` and the picker's delete remove it, and `cs -doctor` names it. An open that asks about a seed renames it to `.<name>.seed.claim.<pid>` before reading it, so a seed published while it asks stays staged for its own open, and an open that stops before taking it puts it back (or sets it aside as `.stale` when a newer seed already holds the name). `cs -doctor` names a claim a killed open left behind, and `cs -rm` and the picker's delete remove it.
- Reopening a `claude --worktree` session whose conversation has ended now runs claude in place of cs, as any other resume does. When `claude --worktree` exits, Claude Code moves the transcript into the parent repo's project dir, so cs did not find it and stayed as claude's parent. cs now looks there too and takes the file only when it belongs to this worktree: it carries the worktree record and its first prompt ran in the worktree, so a parent conversation that stepped into the worktree does not count. cs checks only the conversation it resumes, so an older conversation of the worktree resumes the same way and the parent's other transcripts are never read.
- The scope block no longer drops when `rg` fails. The classifier read any nonzero exit as "no match", so an `rg` that errored (exit 2) or could not start (a failed fork under load) silently skipped the block. Only exit 1 means no match now; any other failure falls back to `grep` for the classifier and the scan.
- `cs -doctor` no longer warns that `context-pct` is never written when a status line bridge chains to `cs-statusline`. Inside a session it reports OK with the reading's age when `context-pct` holds a number written in the last 15 minutes. Otherwise the warning stays, and it now says "unless it chains to cs-statusline".
- `cs -doctor` warns, from any folder, when the installed `cs-tui` is not the current build of the checkout it came from. `install.sh` records where it got the picker, `checkout <path>` or `release`, in `~/.claude/hooks/cs/.tui-origin`, and doctor holds a checkout's picker to the build `install.sh` would ship from it. When a `.rs` file under `tui/src`, `Cargo.toml`, `Cargo.lock`, `build.rs` or `.cargo/config.toml` changed after the build, it names the cargo build and that checkout's `install.sh`; when the installed picker differs from the build, it names `install.sh`. A release picker, a picker that is a link and a checkout with no build get no row. With no record, as after every install made before this change, with a record it cannot read, or with a recorded checkout that no longer holds `tui/Cargo.toml`, it prints one line that is not a warning, saying the picker was not checked and what fixes that. An install that places no picker, or keeps your own link at `~/.local/bin/cs-tui`, leaves the record unchanged, and `cs -uninstall` removes it. The rows print each control, direction-flipping or zero-width character in the checkout path as one `?`. `install.sh` still builds nothing.
- A torn update cache no longer mutes the update check for an hour. A line cut after its timestamp, with no version, used to count as fresh. A fresh cache now needs both fields, and cs writes it atomically.
- A `/finish` integrate killed with `TERM` or `INT` during its gate no longer leaves its `cs-gate.*` log in `TMPDIR`. A log the cleanup cannot remove no longer stops it before it releases the integrate lock either.
- An open now rewrites old resume wording in the narrative and prunes a retired `commands.md` every time, not only when the migration stamp is stale. A merge or a restore that brought either back used to keep it. Both checks read a few lines, so opens stay fast. `cs -doctor` no longer reports "stale (no stamp)" for a worktree whose state names its `task_branch` but predates the `cs_base` key.
- Two cs processes no longer hold one of cs's locks at once. The locks on the state file, the vault holder list, `settings.json`, a tmux window's title, `cs -queue accept` and the session open were directories holding a pid, and a waiter took over a holder it judged dead; a stale read, a reused pid or a killed waiter let two in. Each lock is now flock(2) on a `*.mutex.lock` file, which the kernel releases when its holder exits or dies, so nothing judges a holder dead. cs ignores the lock directories an earlier version left on disk, so update cs while no session is opening: a cs from before this change takes the old lock and doesn't wait on the new one. The lock needs perl. Without it an open now says perl is missing instead of blaming another cs, and the installer stops before writing anything.
- `cs -secrets` keeps every secret off its children's command lines, where `ps` showed them to any user on the machine. The Keychain backend hands the value to `security -i` on stdin as hex. The encrypted store and the sync files give openssl their key through a one-command environment variable instead of `-pass pass:`. jq reads each value from the environment or stdin instead of `--arg`, and the import merge sends both stores on stdin instead of `--argjson`, which had every decrypted secret on the command line on each import. A sync file holding more than one JSON document now fails the import instead of merging the wrong pair. The environment channel is still readable by the owner and root; the two stdin paths are private.
- `cs -secrets export-file` encrypts only to age recipients you pinned on this machine. The recipients folder is tracked in git, so anyone with push access could add their own key and receive every secret on the next export. `age add` now records the key in `~/.cs-secrets/sessions/<session>/age-trusted`, outside the checkout, and `age remove` drops it. A `.pub` that reached the folder without a local `age add` makes the export refuse, name the file and print the command that pins it. Nothing is pinned without an `age add` on this machine, except your own key, which is pinned by its content. A machine that exported before this change refuses its next export and lists each recipient with the command that pins it; one `age add` per recipient and it exports again. An earlier draft pinned every recipient once when the machine's own sync file already existed, but that file is tracked under a predictable name, so a push adding a key beside an empty one would have pinned the pusher on a fresh clone.
- `cs -secrets age remove` now revokes. The export skipped an unchanged store, so the removed key kept decrypting it. The export records the recipient set per sync file in `~/.cs-secrets/sessions/<session>/age-exported-to` and re-encrypts when it changes. Each machine re-encrypts its own file on its next export, and copies in git history stay readable. The export, `age add` and `age remove` hold one per-session lock on every backend, from the recipient snapshot through the encrypt, the rename and the digest record, so a slow export cannot rename a ciphertext that still admits a removed key over the re-encrypted one while the newer digest stays recorded.
- `CS_NARRATIVE_ROTATE_MIDPOINT` no longer runs its value as shell code. It names a fixture file that replaces the narrative mid-rotation, for the tests; a value naming no file is an error.
- A session path holding a quote, a double quote, `$(` or a space no longer breaks the launch. The env file Claude Code sources quotes every value, the exit trap reads the lock path from a variable instead of spliced text, and the update cache's time must be digits before arithmetic.
- A session name cannot start with a dot. `cs .spawn` used to open cs's own staging folder as a session. The same rule applies to the feature half of a worktree name. `cs -rm` still accepts an old dotted name so you can remove it.
- A `CS_ROTATE_FORCE_CTX` outside 1 to 100 falls back to the default of 80, like unset, instead of arming forced rotation at a threshold no turn reaches. `off` and `0` still turn it off.
- `cs -conversations` strips control characters from every line it prints, the C1 controls (U+0080 to U+009F, which some terminals obey as an escape) among them and a tab kept, so a recorded field cannot write the clipboard or move the cursor, and a wrong-typed record is skipped with a warning naming its line instead of ending the listing.
- `cs -uninstall` runs the keychain purge before it removes `cs-secrets`, which the purge needs, and refuses to delete session data while any session is live, naming them, whether or not a volume is mounted inside the sessions root; a session whose name starts with a dot counts too.
- The prompt rewriter's `agy` and `codex` arms hand the prompt to the vendor CLI on stdin instead of the command line, where `ps` and the shell log showed it.
- A spawn seed no longer arms a session on its next open without asking. Anything that could write into `.spawn/` could stage tasks and a brief for a session name, and the next `cs <name>` within the hour queued them, armed the queue, delivered the brief and told Claude to begin. Now `cs -spawn` writes a random token as the seed's first line and starts the tmux window with the same token in `CS_SPAWN_TOKEN`, so only that window takes the seed unasked. Any other open prints the seed as data (its path, who the spawner claims to be, whether a brief sits beside it, every task line with control characters stripped) and asks `[Y/n]`: Enter or `y` takes it, `n` or Escape sets it aside as `.stale`, and an open with no terminal leaves it staged and goes on without it. The launch drops the token from the environment before it takes the session lock, so neither Claude nor a launch the collision menu redirects to carries it. In an encrypted session the tasks now land behind `.cs/private`, where the drain reads them, instead of in plaintext under `.cs/local`. `cs -spawn` refuses a `CLAUDE_SESSION_NAME` that is not a session name, since that string becomes the worker's reply address. An open that takes a seed holds the spawner line it carries to the same rules, a feature's `<base>@<task>` included, and refuses a seed that breaks them, naming the seed, and the line as a plain name, before it writes or queues anything; the seed stays staged. The open shows and handles a seed it leaves staged or sets aside as before.
- `cs -msg --kind task` no longer puts the body in the recipient's queue. Any process on the machine could name itself as a session and have an unattended drain run whatever it sent, and the send cleared the gate the user had declined. The message now waits in the mailbox like any other kind: it wakes the recipient, the prompt shows it inside `<cs_mail kind="task">` with the sender and its accept command, and `cs -queue accept <id>` is what queues it, once per id, under a lock, with the receipt written before the queue file so an interrupted accept cannot replay a task the drain already ran. A preview the prompt cuts says so and withholds the accept command until the whole message is read. `cs -msg` prints the same note above its listing and keeps a forged sender name on one line. The drain hands every task over inside `<cs_task id="…">` tags and says the text inside is the work to do and changes none of the instructions around it. From another session, `cs <session> -queue add` now sends task mail the same way, and `cs <session> -queue start` and `accept` refuse, since arming that queue and accepting into it belong to its own user. A terminal outside any session still adds straight to the queue. Another session's `-queue rm` and `clear` refuse too, and `cs -spawn` no longer hands another session's tasks or brief to a session that already exists. A spawn from that session's base, or from a sibling feature, still does. The block SessionStart adds to list other sessions says the same: a `task` waits in that session's mailbox until its user accepts it with `cs -queue accept <id>`. It used to say a task lands in the recipient's walk-away queue.
- The permission hook no longer approves writes to the files cs itself acts on. It used to approve any Write or Edit under `.cs/`, which covered `.cs/local/pre-open` (run at the next open), `.cs/claude-config/` in an encrypted session, the queue, the mailbox, the state and identity files and the secret-sync keys. Those now get the normal permission prompt, as does an Edit of any executable file under `.cs/` and any write while `.cs` or `.cs/local` is a symlink. The content files stay prompt-free: README, summary, memory, narratives, plans, handoffs, checkpoints, notes, and the `pending-handoff` marker the rotate skill arms. The check reads where the write really lands, compared without regard to case, so a committed link from a shared directory into `.cs/local` counts as `.cs/local`, `LOCAL/state` is `local/state`, a `claude-config` linked into `memory/` keeps its protection, and a link planted beneath `.cs/local` or `.cs/claude-config` that points back into the session makes every write prompt until you remove it, and a write to a content file that the project's `.claude/` or `.mcp.json` reaches through a link prompts too. See [docs/hooks.md](docs/hooks.md#session-auto-approvesh-permissionrequest-on-writeedit).
- `cs <name>` refuses to open a session whose `.cs` or `.cs/local` is a symlink. A clone could commit `.cs` as a link to a tracked folder holding a `pre-open`; git lists nothing under `.cs/local` for a link, so the tracked-files check passed and the script ran at open. The error names the link and its target; replace it with the directory and reopen.
- The auto-memory migration no longer deletes memory it never copied. On the first open of a fresh clone, cs moves `~/.claude/projects/<path>/memory/` into `.cs/memory/`. It used `cp -n` for the top level and then `rm -rf` on the whole source, so a file the session already had under the same name was lost, and so was every subdirectory. The migration now copies every file, subdirectories included, keeps a colliding name beside the session's as `<name>.claude-projects`, and deletes a source file only once a byte-identical copy exists. A failed copy, a destination reached through a symlink, or a `.cs/memory` that links back into the default dir leaves the default dir whole with a warning. A `.cs/memory` linked elsewhere, as in an encrypted session, works as before.
- `cs -adopt` keeps what the project already has. It used to overwrite `CLAUDE.local.md` and `.gitignore` and commit everything. It now appends the session protocol below an existing `CLAUDE.local.md` (one that already carries cs's sentinel is left alone), merges its entries into an existing `.gitignore` instead of replacing it, keeps a last line with no newline whole, and refuses `$HOME` and `/`. The flat-layout migration used to run on any directory holding `logs/`; it now runs only when `logs/session.log` opens with cs's `Claude Code Session Log` header.
- Re-adopting a session keeps its command log. The "preserve records" answer kept the records, but `.cs/local/session.log` was truncated on the way. cs now writes it only when absent.
- `install.sh`, `cs -update` and `cs -uninstall` replace or remove a file under `~/.claude` only when cs wrote it. They used to act by file name, so your own `~/.claude/hooks/cs/<name>`, a skill or a command sharing a cs name was overwritten on install and deleted on uninstall. Ownership is by content: the sha256 in the install record (`~/.claude/hooks/cs/.installed`, written on every install), the payload being deployed, or any content cs ever shipped. A file of yours under a cs name is kept, named in a warning, and listed at the end of the install; move it aside and install again to get cs's copy. `cs -doctor`'s drift row separates the two by the same test: a deployed hook, command, skill or mod file cs wrote still gets `(run ./install.sh)`, and one kept as yours gets `move it aside, then run ./install.sh to get cs's copy`, since `./install.sh` alone does not replace it. The installer also loads its helpers from the payload it deploys, never from the deployed copy.
- `cs -update` verifies what it installs, not only the installer. The web install downloads every payload file into a staging dir, checks each against the sha256 that `build.sh` embedded in `install.sh`, and places nothing until every file passes; a file is written through a temp file and a rename, so a dropped transfer leaves the installed cs whole. The published installer pins its payload to its own release tag. The `install.sh.minisig` fetch is optional (a release without one no longer ends the update with a silent exit 22), and the temp dir goes on every exit.
- Every rewrite of `~/.claude/settings.json` (install, `cs -uninstall`, `cs -statusline enable` and `disable`) holds one lock beside the file across read, change and write, writes a backup `settings.json.cs-bak.<UTC stamp>` before any change, and lands through a temp file and a rename. A file jq cannot parse is refused with jq's reason and left byte for byte, where the old code reset it to `{}`; the installer refuses it before it places anything and says it installed nothing. The lock's timeout removes an old lock only when no process holds it any more. cs keeps the five newest backups and removes older ones.
- The TUI delete refuses a live session, naming its pid, after re-reading `.cs/session.lock` instead of trusting the last scan. When `git worktree remove --force` refuses, it shows git's error and deletes nothing, as `cs -rm` does; it used to fall back to removing the directory.
- The TUI delete drops a session's staged and stale spawn briefs with its seeds. A later `cs -spawn` under the same name used to pick up the old brief. The staging suffixes are one list, in bash and in the TUI.
- A hook that finds its session by walking up from the directory (Claude desktop, an IDE, any front end that is not the terminal CLI) accepts a `.cs/` only when the sessions root knows it: an entry under `~/.claude-sessions` that is the directory or a link to it. It used to take any `.cs/` it found, so a cloned repository with a committed `.cs/` turned the conversation into a cs session, with its auto-approve, its autosave, its Stop blocks and its README, narrative and handoff text injected as instructions. A `.cs/` cs never made now declines, inside a real session too, and the hooks stay silent. A session under a `CS_SESSIONS_ROOT` other than the default used to resolve through the walk; the hook cannot read that setting in a desktop or IDE conversation, so such a session now declines there.
- Two `cs <name>` started together no longer both open the session on one conversation. Both used to see no lock, both wrote their pid, and both launched Claude. The lock is now taken by creating the file, which only one open can do, and taking over a stale lock happens under the openers' mutex, flock(2) on `.cs/session.mutex.lock`, so an open that read a dead pid cannot delete the lock another open just took. An open that waits five seconds for that lock while its holder is still alive refuses and asks you to try again. SessionEnd clears a dead holder's lock under the same lock.
- An open refuses anything in the place of `.cs/session.lock` that is not a regular file (a link, a directory or a fifo), with `<lock> is a link, where cs keeps the session lock; remove it and open the session again` (`is a directory`, `is not a regular file`), before it takes the openers' mutex and again right before a forced write, so an open never writes its pid through a link or waits on a fifo, and the exit's release of the lock never follows or removes a link there.
- The `Removing stale session lock (PID ...)` line prints the lock's text as a plain name: each character other than a letter, a digit or one of `._/@-` shows as `_`, cut at 40 characters, and `unknown` stands for an empty lock. A lock holding more than one line or an escape sequence reached the terminal raw.
- A `claude -p` you run from inside a session no longer removes the session's lock when it exits, and no longer gets the narrative reminder. It inherited the session's environment and passed for the conversation cs launched, so its exit stripped the lock and the next `cs <name>` opened a duplicate with no collision menu. cs now compares its Claude pid with the launch pid and treats it as a guest when they differ.
- The walk-away drain no longer marks a task done just because its turn ended. A final message holding a `cs-task-failed` line, bare or as a code span, parks the run and keeps that task first in the queue; `cs -queue rm 1` drops it. The breakers now run for the last task too. A context or five-hour limit trip on the last task still logs it done and ends the drain, since those measure the session and not the task.
- The permission hook prompts for every write while any symlink sits under `.cs/local`, `.cs/private`, `.cs/claude-config` or the project's `.claude/`, except the vault and shared-config links cs places, which it checks by identity. It also prompts for a write to an existing file with more than one hard link, which can share its contents with a file outside `.cs`, and for one whose link count it cannot read. It asks the link count after every other check, so when that is the one reason a write prompts, stderr says so: `cs auto-approve: not approving, <path> has <n> names`, or `cs auto-approve: not approving, could not read the link count of <path>`, with the path printed plain. The scan skips only the project's own `.claude/worktrees`. A project that links into `.claude/` (a `skills` folder, say) now gets the normal prompt for `.cs` writes.
- `cs -uninstall` refuses a live session before it removes anything, where it used to remove the binaries and then refuse at the data step. It checks again after you confirm, and again right before it deletes the session data, so a session or vault opened while a question waited keeps its data. When it refuses before it removes anything, it says it uninstalled nothing and to run `cs -uninstall` again once you close the sessions; when it refuses at the data step, after it has removed cs, it says to delete the sessions root once you close them.
- `cs -usage` and `cs -search` see sessions whose names start with a dot.
- Retiring a worktree counts ignored files as work the removal would destroy, except cs's own bookkeeping and `.DS_Store`. A locked base vault refuses the retire before cs moves or removes anything. A write that fails while cs fuses the records into the base keeps the staged copy and names it, instead of counting the fuse done and deleting the only copy.
- `cs -adopt` and the migrations leave a project's `.gitignore` alone: a commented or negated mention of a cs rule no longer counts as the rule, and the flat-layout migration merges cs's rules instead of overwriting the file. `cs <name>` refuses to open an existing folder under the sessions root that is not a session, where it used to turn it into one. `cs -adopt` refuses the sessions root and every folder above it.
- Re-adopting an encrypted session no longer writes a plaintext `.cs/local/session.log` that the next open refuses; cs seeds the log behind `.cs/private`.
- The install keeps a symlink where it would place a file, or a symlinked mod folder, unless it points at cs's own content, and names it with the kept files. The install replaces a link to cs's own content with the file, and one line names the link and where it pointed. It records each file as soon as it lands, so an install that stops partway leaves a record that matches the files. It names a kept file under a retired cs name once instead of on every install. Install and `cs -uninstall` keep the settings registration of a flat `~/.claude/hooks/<name>` left in place as yours. The install also keeps and names a directory where it would place a file; the file used to land inside it.
- The TUI delete refuses a live session, and one holding files cs did not create, unless you grant it in the confirm. It checks a row's lock pid when you ask, so a session that closed after the last scan is no longer refused until the next one.
- `cs -statusline disable` on a `settings.json` jq cannot parse reports jq's reason and leaves the file alone, where it used to call the status line foreign.
- A link committed inside a session no longer carries cs's writes outside it. A clone could commit, say, `.cs/README.md` as a link to a file elsewhere on the machine, and cs wrote through it. `cs <name>` now refuses to open a session that holds a link from inside it to a path outside, and names the link. The check also covers the legacy files a flat-layout session keeps at its root, and it refuses a directory whose name holds a newline. The named forms of `cs -queue`, `cs -narrative` and `cs -secrets` and every `cs -msg` target run the same check, and `cs -secrets` in a worktree checks the base session too. `cs -narrative rotate` refuses a timeline linked out of the session and writes its snapshot under an unpredictable name. cs trusts a vault link you made by hand only while a real, untracked `.cs/local/pre-open` exists outside any nested or submodule `.cs`.
- `cs -secrets` refuses a session name that is a path (`.`, `..`, or any name with `/` or `\`) for every command. `purge` ends in an `rm -rf` of `~/.cs-secrets/sessions/<name>`, so `--session ../../x purge` deleted a directory beside `~/.cs-secrets`, and `--session ../id_ed25519 purge` deleted this machine's key. Both exited 0.
- `cs -secrets import-file` no longer reads a sync file through a link. It skips a sync file that is a link and refuses one you name, refuses a session whose `.cs` is a link, and refuses a file you name inside the session when its directory leads out of it. That check holds for any spelling of the session: a doubled slash, a `.` segment, another letter case, a link to the session or the sessions root, or a relative name from a directory you reached through a link. It holds for every other session too, so a link in one session's `.cs` cannot lead into another. cs also refuses a file you name in `~/.cs-secrets`, whatever path leads there. cs reports a sync file it cannot read as unreadable, where the import used to blame the password. cs copies each file from inside the directory it checked, so a checkout that swaps `.cs` for a link during the import cannot send the read somewhere else. A pushed `.cs/secrets.<x>.enc` link, or a `.cs` link, to another session's local store in `~/.cs-secrets` got imported, because the shared password opens that store too, and the next export put those secrets in this session's tracked sync file.
- An import no longer loses every stored secret when one value is larger than the kernel lets a process carry in its environment (1 MiB on macOS, 128 KiB per string on Linux). On the encrypted backend jq could not start, cs wrote an empty store over the real one, printed `Imported N secret(s)` and exited 0. Values now reach jq as a file the shell writes, and cs refuses to write a store that is not exactly one JSON object. A keychain `export-file` stopped on such a value for the same reason; it now carries it.
- A tmux teammate no longer raises the lead's attention flag or bounces the dock in iTerm2 when its turn ends. Only the lead's own turn end does that.
- The prompt rewriter reads `CS_REWRITE_TIMEOUT` once, as a positive whole number of up to seven digits, and the countdown and both rewriters use that one value. Anything else, zero included, means 25 seconds. The value used to reach shell arithmetic, where it could run a command, and a zero stopped the rewrite screen with a division error and left the rewrite with no time limit. A rewriter script you run by hand no longer reads `CS_REWRITE_TIMEOUT`.
- On bash 3.2 the prompt hook reads `$EPOCHREALTIME` from the environment only when its seconds and its fraction are both digits. Otherwise it works as a shell without the variable. A value there could run a command.
- The Stop hook's narrative reminder works on a Mac where GNU coreutils' `stat` comes first on `PATH`. The hook picked BSD `stat` by the OS name, and GNU `stat -f` prints the file system's details instead of a time, so the reminder never fired there.
- When the first conversation ends after another terminal force-opened the session, cs keeps the session lock the second launch took. The first conversation's SessionEnd used to remove it while the second claude was still running, so `cs -rm`, `cs -archive` and `cs -spawn` treated the live session as closed. A conversation's end now removes the lock only when it names that conversation's own launch or a process that is no longer running. Under `cs <name> --remote` the launch is the server, so the lead's end leaves the lock while `.cs/local/remote.pid` names a process running `remote-control --name <name>`, and the server's exit releases it.
- A forced open (`--force`, or force start in the collision menu) writes its lock while it holds the openers' mutex. It used to let the mutex go to ask you, then write its pid without it, so the other conversation's SessionEnd could read its own pid and remove the file just after the forced open wrote it, and the forced session ran with no lock.
- A cancelled or interrupted open no longer removes the lock a forced open took in the meantime. Its cleanup reads and removes its own lock under the openers' mutex, and leaves the lock alone when another cs still holds that mutex after the wait.
- `cs -encrypt` takes the session lock the way an open does, under the openers' mutex. An open that started while `cs -encrypt` checked the session used to have its lock overwritten; now the open keeps it and `cs -encrypt` refuses with "the session is running; close it, then encrypt." While another cs holds the mutex, `cs -encrypt` refuses and writes nothing.
- An open no longer moves a worktree session to another conversation because its transcript moved. Once a `claude --worktree` conversation exits, Claude Code moves its transcript into the parent repository's project directory, and cs called the bound conversation an orphan; when a newer transcript sat in the worktree's own directory, cs switched the session to it. cs now finds the moved transcript and keeps the bound conversation, also when the first prompt mentions `teammate-message`.
- cs reads file times correctly when GNU `stat` comes before BSD `stat` on a Mac's `PATH`, as Homebrew's gnubin sets it up. `cs -live` stopped with `File: unbound variable`, an open with a staged spawn seed stopped the same way, `cs -list` printed filesystem text in its `MODIFIED` column, and a README with frontmatter could get that text as its `created` date. cs now asks GNU `stat` first and BSD `stat` second on every system.
- The walk-away drain logs done only the task it handed out. A task removed mid-run is logged nothing, and a task accepted in its place is handed out instead of being marked done unrun. A queue that an older cs left draining has no record of the task it handed out, so it parks with a message and logs nothing done; `cs -queue start` runs it again from the first task.
- The mail wake cuts each sender name to 40 characters, replaces anything outside letters, digits and `. _ @ : -` with `_`, and quotes it. `cs -msg` refuses to send from a `CLAUDE_SESSION_NAME` that is not a session name. A feature session (`base@task`) and a send from outside any session still work.
- `cs -queue accept` prints the accepted task without control bytes.
- `cs -queue accept` is offered and accepted only for a message id of at most 40 letters, digits, dots, underscores or hyphens. It refuses an id two mails share, and a mail kind that only trims to `task`.
- `cs -queue add` fails loudly when the task cannot be written. A spawn seed whose tasks cannot all be queued takes back the ones that open already queued before it stops, so the retry queues each task once. If any cannot be taken back, the error names each file left behind. An open that cannot record its spawner queues nothing.
- A queue with tasks waiting no longer stops the turn to ask whether to start. The cs mod's band shows a `▤ queue N · start` key instead, which asks the same two questions when pressed, and `cs -queue defer` is removed.
- On jq 1.7.1, a line of non-ASCII text longer than 4 KB could lose a character to a replacement mark when cs read it with `jq -R`. The read is now done whole, so it is no longer lost: the body `cs -msg` stores and shows, `cs -queue log`, the prompt's mail digest, the prompt and rewrite the agy rewriter passes, the Objective adopt seeds from a conversation's first prompt, and the write-as-me voice corpus.
- A Homebrew bash linked against libintl no longer crashes with a segmentation fault now and then while cs reads presence, queued tasks or mail, cleans git's error text, scrubs a hook's text, sorts the memory index, digests age recipients or counts the subagent status bar's width. cs never changes the shell's own locale inside a forked shell now. Commands that need the C locale get it through `env`, the mail size check counts bytes in any locale, and the width count strips UTF-8 continuation bytes. What cs prints stays the same. `cs -doctor`'s integrate-lock check runs `kill -0` the same way, and a pid `kill` cannot parse is still reported as unknown, now with `kill`'s own reason.
- The subagent status bar no longer runs text from an inherited `_SL_WALK_DEADLINE` variable as a command. cs-statusline resets the value when it starts and reads the walk deadline only as a whole number of seconds.
- The test suites stop inheriting the caller's `CLAUDE_PID` and `CS_LEAD_PID`, so they pass when run from a tmux teammate.
- Renaming a session in the picker moves its secrets with it. `cs -secrets --session <old> rename <new>` moves the Keychain entries, the encrypted store and the age pins to the new name, and refuses a new name that already has any of them. On a Mac it reads the Keychain on either backend and refuses when it cannot read it. If the move fails or a signal stops it, it puts back what it moved and the picker restores the directory and staged spawn files, so the session keeps its old name with every secret readable. If it cannot put the move back, `~/.cs-secrets/.rename.<old>` records it, the picker shows the command that finishes it, and `rename` refuses to move that session to any other name. When the picker cannot move a staged spawn file back, the status line names the file.
- `cs -secrets` `set`, `rm`, `purge` and `rename` share one write lock per session, `<sessions root>/.secrets-lock.<name>`, so a write during a rename moves with the session or waits. A stopped command holds the lock until the `security` or `openssl` call in flight has finished, and an interrupted purge on the encrypted backend holds it until it has removed the session's age pins. `set`, `rm`, `import-file` and `migrate-backend` refuse a session name the sessions root does not have; `purge` still accepts one.
- A signal that reaches `cs -secrets rename` once every value is under the new name no longer ends it with an error, so the picker keeps the session with its secrets; a signal that lands as the move begins leaves no marker behind. A rename that has moved every value but cannot remove one of its lock files names that file on stderr and still exits 0. A rename refused before it started no longer removes the new name's empty age directory.
- An `age add`, `age remove` or `export-file` that waits on a session's age lock while a rename of that session runs no longer times out: once the rename finishes it refuses with "No session named '<old name>'". It used to run on under the old name, so an export to a path wrote a sync file of the values it had read, and an age add could pin this machine's key under a name no session has.
- `cs -secrets` `list`, `export`, `purge` and `rename` match a session name exactly in the Keychain, so a session named `a.b` no longer lists or moves the secrets of `a-b`.
- `/finish` no longer deletes session records it cannot carry into the base. In a session whose `.gitignore` lists `.cs`, the retire carried back only the timeline, the log, memory topics and pointers, and deleted the feature's plans, `summary.md`, handoffs, brief, artifacts, archived narrative sections and nested notes. Every file the base lacks now goes back to it. A copy the feature inherited and edited, while the base left its own unchanged, replaces the base's, and the retire names it. A file the base also changed, a link, or a repository inside `.cs` stops the retire before it removes anything, and the retire names each one to merge or delete by hand. The feature's own `README.md` and `summary.md` are the exception: once the feature changed them, the retire carries them to `.cs/features/<task>/` in the base and never over the base's own, so the base keeps the objective the feature filled in and its `/wrap` summary beside its own, and `cs <base> -features` and the picker's merge screen do not count them as at risk. A later feature of the same name keeps the earlier one's files there and takes the next free name, `README.2.md` or `summary.2.md`, and the retire names where each went. When the base blocks `.cs/features/<task>/` with a file, a dangling link or a link out of the session on the way to it, the retire refuses before it removes anything, names that path for the README and summary, and says to move what blocks it; `-features` then counts them as at risk. A feature created before this version has no record of the README it started with, so its README goes to `.cs/features/<task>/` even if nobody edited it; delete it there if it holds nothing you need.
- The retire refuses, before it removes anything, a timeline, log, narrative or memory index it cannot merge into the base: one that is a link or not a regular file in the feature, or one whose place in the base holds a file, a link or a link out of the session. `cs <base> -features` counts each as at risk. The retire used to remove the worktree first and leave the records in a staging directory. A narrative linked into the feature's own `.cs/local` no longer loses its notes, and a base `.cs/memory` that is a file no longer strands the feature's records when the feature has nothing to put there.
- The retire fuses both of a feature's logs into the base's log, the one at `.cs/logs` first, so a worktree with a log at both places no longer loses the older one. It refuses either log that is a link or not a regular file, and a feature `.cs/local` or `.cs/logs` that is itself a link, naming it, so it never copies a log from wherever a link leads.
- In a session that tracks `.cs`, `/finish` refuses to retire a feature holding untracked files under `.cs` and names them, since git does not carry them. It used to delete them.
- `/finish` refuses to retire a feature whose `.cs/local/state` names no `cs_mode`, instead of deleting its records.
- `/finish` refuses to retire a feature with an edit hidden by `skip-worktree` or `assume-unchanged`, including one on a symlink, on a file that became a symlink, or on a file inside an initialised submodule, and a feature with untracked or ignored files inside an initialised submodule. `cs <base> -features` reports such a worktree as dirty.
- `/finish` refuses to retire a feature whose root `CLAUDE.local.md` is your own file, not the one cs wrote. A file that still carries cs's block counts as cs's, so notes you append below that block stay with the worktree and go when the retire removes it.
- `/finish` keeps the permission rules you set inside a feature. Claude Code writes them to the feature's `.claude/settings.local.json`, which git does not carry, and the retire deleted them with the worktree. The retire now adds each `permissions.allow`, `permissions.deny` and `permissions.ask` entry the base's list lacks to the base's `.claude/settings.local.json`, after the base's own, and creates that file when the base has none. A feature that allows `Bash(git:*)` but denies `Bash(git push:*)` leaves the base with both. The feature's other settings stay with the worktree. When a file it uses is not exactly one JSON object, or a `permissions`, `allow`, `deny` or `ask` in it has the wrong type, the retire stops before it removes anything and names the file.
- The retire leaves `.claude/settings.local.json` to git when either checkout tracks it, in any letter case, so a base that began tracking the file after you made the feature keeps it as git has it. It refuses with git's own error when git cannot say whether a checkout tracks the file. It reads a settings file only when it uses it, so a tracked or linked file it leaves alone never blocks the retire.
- The retire writes no permission rules through a link. For a link at the base's `.claude/settings.local.json`, or a base `.claude` directory that is a link inside the session, it lists on stdout each rule the base lacks, naming the link, for you to add by hand. It writes nothing through a base `.claude` that leads out of the session, and refuses when it would have to. It refuses a link at the feature's own settings file and a feature `.claude` link it cannot follow to a directory inside the worktree, so it never adds rules from outside the session. Where a feature `.claude` link stays inside the worktree, git keeps a settings file it tracks there, and the retire reads one git does not track as the feature's own.
- The retire names a locked base vault, any of its links dangling, and says to mount it before it lists any record. It no longer lists records to merge or delete when only the lock keeps them out. `cs <base> -features` and the picker's merge screen read `vault-locked` for it.
- cs refuses a Keychain secret too long for one `security -i` command line, about 2000 bytes depending on the user, session and secret name, before it sends anything, and names the limit and the encrypted backend. cs used to send a line that `security` cut in two, which could store a truncated value, and at one exact length reported a failed write as stored.
- `cs -secrets age add` with no age binary fails at once and says to run `cs -secrets age init`. It no longer reaches a download prompt whose text it threw away, which left it waiting on an invisible question.
- `cs -secrets age add` refuses a key file whose name is already a recipient holding a different key, and names the file and both keys. A second `laptop.pub` used to replace the first, so the first collaborator could no longer decrypt. Adding the same key again still succeeds.
- `cs -secrets age add` refuses a key that age cannot encrypt to, an `age1...` key with a bad checksum or an `ssh-ed25519` key with a malformed body, before it writes or pins it.
- `cs -secrets age add` with a raw key gives it a recipient name that is free, so two raw keys added within one second no longer collide. Adding a raw key that is already a recipient reports that recipient and writes no second file.
- `cs -secrets export-file` fails with age's own error when age cannot encrypt. It used to fall back to password encryption and exit 0, and a later import then restored the stale values in the old `.age` file.
- `cs -secrets migrate-backend` shows why a secret did not reach the target, such as the Keychain value limit, on the line before `Failed: <name>`. A rename that cannot put a Keychain value back shows the same reason.
- `cs -secrets age add`, `age remove` and `export-file` no longer fail with "could not acquire the age recipients lock" when a rename of the session removes its age directory at the moment the waiting command is making it. The command makes the directory again, takes the lock and then refuses the old session name as before.
- `CS_SECRETS_LOCK_TIMEOUT` set to anything but a positive whole number uses the default of 10 seconds. A word or fraction used to stop the command with an arithmetic error, and 0 gave up without waiting.
- The installer and `cs -uninstall` keep a hook entry in `settings.json` that has no `hooks` array, or whose `hooks` is `false`, an object or a string. The installer stopped on one with a jq error after it had copied the hooks, and uninstall left cs's registrations in place.
- An installer piped into bash is always the web install. Run from inside another project that has a `bin/cs`, it took that directory for a cs checkout and installed the project's file as `cs`.
- The installer and `cs -uninstall` remove the slash commands cs no longer ships (`/compact-discoveries`, `/skillify`, `/learn`, `/store-secret`) when cs wrote the file. cs keeps a file of yours under one of those names and names it.
- `cs -adopt` adds `.cs/session.lock` and `.cs/session.mutex.lock` to a project's own `.gitignore`, and adds them again at the end when a later line such as `!*.lock` overrides them. They showed as untracked after every open, and a re-adopt committed them. Existing sessions get the rules at their next open after an update.
- The installer keeps a skill directory under `~/.claude/skills` that is a symlink, writes nothing through it, and lists it as kept. It used to copy the skill through the link and change the file the link pointed at. It keeps a link at a skill's `scripts/` directory the same way.
- `cs -uninstall` removes `~/.claude/settings.json.mutex.lock`; a cs settings write running at the same moment takes a fresh lock and still goes through. It keeps `~/.cs-secrets/sessions/<session>/` when you keep the secrets, as before.
- The installer and `cs -uninstall` check cs's three lists of retired hooks, commands and skills before they change anything, and stop, naming the list and the entry, when one is not a plain name. An entry with a path in it could have removed files cs wrote outside `~/.claude/hooks/cs`, `~/.claude/commands` or `~/.claude/skills`.
- The installer and `cs -uninstall` keep a hook entry, or an item in an entry's `hooks` list, that is not an object (a string, a number, a list, `false`). Either used to stop the settings update: the installer exited after copying its files, and `cs -uninstall` reported success and left every cs hook registered.
- The installer and `cs -uninstall` leave alone a hook event in `settings.json` whose value is not a list. They rewrote it into a list and lost its keys. When cs adds a hook to that event, the installer stops before it installs anything and names the event. `cs -doctor` reads past such an event, and past an entry or a hook in an event's list that is not an object, where it used to stop part way with no message or report cs's hooks missing. When jq fails on the hook events of a file that parses, the row that ran it says so.
- `cs -rm`, its `--force` refusal, the retire refusal and the picker's delete confirm list the files git does not track the same readable way. A line gives the total number of files, then one entry per line. A whole untracked or ignored directory shows as one line with its file count (`apps/web/node_modules/  (58,993 files)`). The listing shows at most 20 entries, then how many more. A control character in a name, such as a newline, an escape, a tab or a C1 control (U+0080 to U+009F, which some terminals obey as an escape), prints as `?`, so a file name cannot recolour or overwrite the terminal, and so does each character that flips the direction of the text after it or takes no room, so a name cannot read as another file's. Each leaves out Finder's `.DS_Store` files at any depth. The picker lists fewer entries on a short terminal and gives every line of its delete confirms one row, shortening a long session name, warning or path in the middle with `…`, so `[D] Delete those files too` and `[y] Confirm` stay on screen on an 80x24 terminal.
- Retiring a worktree refuses only over untracked files git does not ignore. Ignored files under a directory a build or install recreates (node_modules, .svelte-kit, .next, target, .venv, __pycache__, .dart_tool and similar) go with the worktree. Retire moves every other ignored file, such as `.env`, a local database or test screenshots, to the system trash first and names each file it moved by its full path, and a directory it moved whole by its path and the number of files inside, including when a later step fails. It hands the trash command its paths over more than one call, so thousands of loose ignored files no longer hit `Argument list too long`; if a later call fails, the refusal lists what is still in the worktree and what already moved. With no trash command (`trash` on macOS, `gio trash` on Linux), or when the first call fails, retire refuses and removes nothing. Retire moves and deletes nothing inside a submodule: untracked or ignored files there still refuse it, and so do files written into a submodule directory the worktree never populated. The trash never takes a submodule's directory or a directory above one. The `-features` readiness screen counts the same untracked files.
- `cs -rm` and the picker's delete confirm list the same files retire refuses over: what you keep under a worktree's `.claude/` (agents, commands), a `CLAUDE.local.md` you wrote yourself, the files inside a submodule, and, in a worktree whose repo tracks `.cs`, the untracked files under `.cs/`. They leave out only `.claude/settings.local.json`, which cs writes, so `cs -rm --force` on such a worktree needs `--delete-files`.
- Retiring an ignored-mode worktree in a GBK, Shift-JIS or Big5 locale no longer stops partway when its memory index or narrative holds a character that locale cannot decode.
- After you delete `~/.claude/hooks/cs` by hand, and the install record in it, an install still replaces the hooks, commands, skills and mod files an earlier release wrote. Each release now adds the content of those files to the list cs checks when there is no record. A file installed from a checkout between releases is still kept in that case.
- The picker no longer renames or rotates a session whose claude is running, including one that started while the rename box or the rotate confirm was open: it reads the session's lock when it acts, as delete does, and refuses with the pid instead of moving the lock and transcripts from under it.
- The picker refuses a new or renamed session name that starts with a dot or a hyphen, in cs's own words, such as "Session name cannot start with a dot". A session renamed to `.work` used to drop out of every listing, and one created as `-uninstall` opened a cs verb.
- The picker lists and deletes a worktree session whose base session no longer exists as a plain directory, as `cs -rm` does, instead of failing with "not a git repository" and leaving it.
- The picker reads a worktree's `cs_mode` from its state file's bytes, so a non-UTF-8 byte elsewhere in the file no longer makes the delete confirm list cs's own `.cs` in an ignored-mode worktree.
- `cs -rm` and the picker's delete confirm list the files cs did not create in a session one name per row, at most twenty and then how many more, so `[D]` says which files it deletes on any terminal. The confirm for one session no longer keeps an empty row under its key hint.
- The batch delete confirm keeps `[D] Delete those files too` and `[y] Confirm` on screen whatever the number of marked sessions with a warning. On a terminal that leaves no row for the warnings, their count takes the blank row above `[D]`, so they are never hidden.
- `/finish` names a base `.cs/private` that is a regular file as not a directory and says to move it, instead of calling it a locked vault to mount.
- `cs -rm --force` names the files cs did not create with each control character, a C1 control (U+0080 to U+009F) among them, and each character that flips the direction of text or takes no room, shown as `?`, as the confirm does. A newline in a file name broke its one-line refusal, and an escape sequence reached the terminal. The picker's refusal for a session holding such files names them the same way.
- `/finish` shows each control character as `?` in the file names it prints, a C1 control (U+0080 to U+009F, which some terminals obey as an escape) among them: the tracked files with edits git diff does not show (a submodule's path too), the session records the fuse cannot carry, the records it brings back or replaces, and a file whose inherited record it cannot read. Each character that flips the direction of the text after it (U+202A to U+202E, U+2066 to U+2069, U+200E, U+200F, U+061C) or takes no room (U+200B to U+200D, U+2060, U+FEFF) also shows as one `?`, so a name cannot read as another file's. Accents, other scripts, emoji and spaces print as themselves. Some of these lists replaced only a newline and others nothing, so a committed name holding an escape sequence could recolour or rewrite the terminal.
- In a session with a vault set up by hand, while git cannot answer (a broken `~/.gitconfig`, an unreadable index), a write through a vault link and `cs -narrative rotate` refuse with git's error. They said the link led outside the session.
- The command cs prints to untrack a control file spells a directory or repository whose name starts with `=` or `~`, and a repository whose name starts with `-`, as `./name`, so it pastes into zsh and bash as the same path. zsh read `=git` as the path of the git command.
- The Stop hook ignores a tracked-files notice inherited from the environment when `cs-shared.sh` is missing beside it. It showed the inherited notice as this session's.
- When no git can run, cs still refuses to open a session or run a named verb, and now says `git is not installed or not on PATH` or `git was found on PATH but could not be run` instead of repeating the shell's error.
- When one of git's two answers fails for a repository whose name holds a newline, the refusal carries git's own error and not "git failed".
- Every `cd` in cs, its hooks, `cs-secrets`, `install.sh` and `build.sh` puts `--` before a path it takes from a variable, so a relative path whose first name starts with a dash is a path and not one of cd's options. A name such as `-P` sent the `cd` to the home directory, and others failed. `cs -vet-session -name` passed a session whose control files git tracks: the check took the failed `cd` for nothing tracked. The check that refuses a write leaving its session resolved a directory named `-P` to the home directory and did not see a link out of a session given as `-s`; it now resolves both. The session manager hands git a worktree's path after `--` when it deletes a worktree session, so a path starting with a dash no longer makes git refuse and keep the worktree.
- `cs` and `cs-secrets` read a relative `CS_SESSIONS_ROOT` from the directory they start in, and cs hands claude, its hooks and its status line that absolute path. Before, cs could not open a session under a relative root, because it moved into the session and then looked for the root from there. A root starting with a dash failed at cs's first `mkdir`, and under one cs-secrets left its write lock behind, so the next write to that session timed out.
- `cs -narrative rotate` no longer writes outside the session in three cases: when `CLAUDE_SESSION_META_DIR` names the session's `.cs` by a different spelling (relative, through a linked parent, or with `./`), when a `.cs/private` link leads out of the session and the archive directory does not exist yet, or when `.cs/memory` leads out of the session while the narrative in it links back in. A `CLAUDE_SESSION_META_DIR` that is not the session's own `.cs` is now refused. When the final rewrite fails, the rotation removes its snapshot and the archive chunk it wrote.
- From inside a cs session, `cs -rm`, `cs -archive`, `cs <name> -narrative rotate` and every `cs -secrets` command that writes (set, rm, purge, rename, import-file, migrate, migrate-backend, export-file, age add and age remove, by `cs <name> -secrets`, `cs -secrets --session` or `cs-secrets -s`) no longer act on another session whose claude is running, even with `--force`. They stop with an error that names both sessions, and `cs -rm` and `cs -archive` act on none of the names on the command line. `cs -rm` and `cs -archive` also leave a base alone while one of its features is running unless they run in that base itself, and a secrets write to a base waits for its running features except when it comes from the base or from that feature. They tell a base's features by their directory, not by the spelling of the name, so a base typed in another letter case or Unicode normalization, on a Mac volume that ignores the difference, still counts. `rename` checks the new name as well as the old one. An idle or closed session, the caller's own session and, from a base, its own features (for secrets, also a feature writing its base's while the base runs), and a terminal outside any session behave as before. The picker's delete, opened with bare `cs` from a shell inside a session, refuses what `cs -rm` refuses from there: another session whose claude is running, whatever `[F]` would grant, and a base while one of its features is live, unless the picker runs inside that base. It refuses when you press `d` or `D`, before the confirm opens, and says why in `cs -rm`'s words; a batch holding such a session does not open. At `y` the removal asks again, and refuses a session that went live after the confirm opened. Outside every session the picker deletes as before, except a session a `cs <name> --remote` server serves, which it refuses everywhere, as `cs -rm --force` does.
- cs, cs-secrets, the session picker and the cs hooks read a session lock the same way: its text, surrounding whitespace removed, must be a process id from 1 to 2147483647 that is running. A lock reading `0`, `-1` or `+<pid>` no longer counts as a running session. Opening a session over such a lock reclaims it instead of refusing. `/finish` (`-retire-feature`, `-integrate-feature`) and `cs <base> -features` no longer report the session as open elsewhere. Such a lock no longer keeps an encrypted session's vault mounted after an open that stops or a conversation that ends, and SessionEnd clears it. An open reads the lock before the session's `.cs/local/pre-open` runs and hands the result to it in `CS_LIVE_LOCK_PID` (the running pid, or empty). The pre-open `cs -encrypt` writes reads no lock itself and joins a mounted vault without asking for the password only when that variable names a running process, so a lock of `0` over a mounted vault no longer lets an open join it without the password, and a hand run with a dead pid or `0` asks. Sessions encrypted before this release keep their old pre-open. The `is live` refusals of `cs -rm` and `cs -archive` name the pid without the lock's whitespace.
- A session launched with `cs` no longer inherits another session's secrets target (`CS_SECRETS_SESSION`) or caller (`CS_SECRETS_CALLER`) from the shell that started it.
- `cs -uninstall` names each session whose secrets it kept and why, instead of hiding a purge that cs-secrets refused.
- `/finish`'s `-retire-feature` and `-integrate-feature` name the missing commit when the base session does not have it. The refusal printed `Commit not found in <base>: ` with nothing after the colon.
- cs refuses `cs <base>@<feature>` on a base whose repo has no commit yet, such as a folder just adopted, and says so. git used to make the feature an orphan branch, which `/finish` then failed to land with `fatal: ambiguous argument 'HEAD'`. Integrate and retire refuse such a base the same way.
- `cs -secrets migrate --redact` replaces each migrated value in the file as plain text, longest value first, and puts the markers in only once it has replaced every value. It used to give the value to `sed` as a pattern on its command line, where `ps` showed it to every local user. A value holding `(` or `{` stopped the migration with the plaintext still in the file, and one with balanced parentheses reported the file as redacted and left the plaintext in place. A value that held a shorter one (`hunter22` beside `hunter2`) kept its tail in the file under a marker naming the other key, and a short value such as `as` rewrote an earlier marker. The replacement reaches every place the file holds a value, a short one included: it replaces a value `as` inside `password` and in prose on other lines too. The migration stops, storing nothing from it, at a file that holds every control byte the replacement could mark a value's place with.
- `cs -secrets age remove` refuses a link at the session's `.cs`, at `.cs/age-recipients` or at the recipient file, names it, and removes nothing. A clone could commit `.cs/age-recipients` as a link, and the remove deleted the `.pub` file wherever it led and dropped that key's pin.
- `cs -secrets age remove` refuses a recipient name that holds a `/` or a control character or starts with a `.`. A path given as the name deleted another session's recipient file. `cs -secrets age add` refuses a key file whose name without `.pub` starts with a `.`: `age list`, every export and `age remove` skip such a recipient, so `age add` pinned it and nothing showed it again.
- Every `cs -secrets` write addressed to a feature session with `--session <base>@<task>` or `-s <base>@<task>` refuses, names the base to use, and writes, locks or creates nothing. The writes are `set`, `rm`, `rename`, `import-file`, `migrate`, `migrate-backend`, `export-file`, `age add` and `age remove`. A feature uses its base's secrets and age recipients, so a store, Keychain entry, sync file, recipients folder or pin list made under the feature's name was one no launch of the feature read. `purge` of a feature still runs: it removes what an earlier cs stored under the feature's name and creates nothing. `cs <base>@<task> -secrets` writes to the base, as before.
- `cs -secrets` refuses an option it does not take, such as `--session=other`, names it and runs nothing. cs-secrets read such a word as a secret name or value, so the command acted on the current session: `cs -secrets --session=other purge` purged the current session's secrets, `age remove` removed its recipient, and `migrate` migrated its files. `age list --session <name>` after the subcommand now lists that session. A value given on the command line cannot start with `--`; give it on stdin.
- Install, `cs -update`, `cs -uninstall` and `cs -doctor` never open a fifo, a device or a link to one at a path they judge, so none of them hangs there. Where install deploys a file under `~/.claude`, or inside a skill directory that `cs -uninstall` removes, they keep such a path unread, name it in a `Kept` line, and finish the run. Install reads the version it reports and stamps from the payload's `cs`, never from the `cs` in the install directory, which may be a link it kept, and writes the hooks' `.version` stamp by a rename, which replaces a fifo there; a link there it keeps and names. A `settings.json` that is not a regular file (a fifo, a device, a directory, or a link to one) is never opened: install refuses it before it places anything, as it refuses one jq cannot parse, `cs -uninstall` leaves it unchanged with a warning, and `cs -doctor` reports it as a failure. A `keybindings.json` of that kind gets the warning an unparsable one gets, and cs leaves it unchanged.
- Install and `cs -uninstall` judge each file under a skill directory by its whole name. A name holding a newline used to split into a second path, possibly outside `~/.claude`, and uninstall removed that file when it held content cs once shipped. cs now judges such a name by its content alone: it never looks the name up in the install record or writes it there, so the name cannot make the record claim another file for cs.
- The picker's rename and new-session prompt count a name as taken when a link at the sessions root holds it, one that leads nowhere included, such as an adopted session on a disk that is not mounted. A rename no longer replaces that link.
- The cs-update mod acts only in a directory the sessions root names, by the rule the cs mod uses. A cloned repository that carries `.cs/local` and passes `cs -vet-session` gets no release-notes pane, at launch or redrawn after a plugin reload, `/cs-update` opens nothing there, and the mod writes no heartbeat or finished-update marker in it.
- The prompt hook's unread-mail digest, `cs -msg`, `cs -msg log` and `cs -msg thread` skip a mail document that is valid JSON but not an object (an array, a number, a string), as they skip one that does not parse. The messages beside it still show, the digest counts it in the total and the overflow line, and `cs -msg` moves the batch to `cur/`. The digest used to go blank, and `cs -msg` exited with a jq error and left the mailbox stuck.
- The queue digest at prompt and at session start skips a line in `notifications.jsonl` that is valid JSON but not an object. Such a line hid every notification beside it, and the seen cursor still moved past them, so they were never shown.
- `cs -queue accept` refuses, naming the link, when its receipt file `queue.accepted` or the mailbox's `new/` or `cur/` is a link leading out of the session. It writes nothing outside the session, queues nothing and leaves the message unread. It used to append the receipt through such a link, queue a task read through a `new/` link, and move the accepted message out of the session through a `cur/` link.
- `cs -secrets migrate` called a key sensitive when its lower-cased name held `key`, `token`, `auth` or another secret word anywhere, so it stored `author`, `isKey`, `KEY_NUM`, `tokenizers` and `DEFAULT_MAX_TOKENS` as secrets, and with `--redact` it replaced a value such as the author's name everywhere the file held it. It now splits the name into segments, on `_`, at each lower-to-upper case change, before the last capital of an upper-case run that a lower-case letter follows (`AWSSecretKey` is `AWS`, `Secret`, `Key`) and where a letter and a digit meet, and reads each segment lower-cased. `secret`, `password`, `passwd`, `token`, `credential`, `credentials`, `apikey`, `passphrase` and `authorization` mark a secret as a segment or at a segment's end (`DB_PASSWORD`, `PGPASSWORD`, `NGROK_AUTHTOKEN`); `pat`, `cred` and `creds` only as a whole segment (`GITHUB_PAT`, not `pattern`); `auth`, `pass` and `pwd` only as the last segment (`BASIC_AUTH`, `OAuth`, `DB_PASS`, `MYSQL_PWD`; never the whole name `PWD`); `key` right after `api`, `access` or `private`, or as the last segment or its end (`APP_KEY`, `encryptionKey`, `TS_AUTHKEY`). A trailing number or version segment does not count as the last segment, so `APP_KEY2`, `SSH_KEY_1`, `MASTER_KEY_V2` and `BASIC_AUTH_2` are secrets and `KEY_FILE` and `AUTH_HEADER` are not. A blank value, bare or inside one pair of matching quotes, is never stored. A name sensitive only through plain `key` with a value that is `true`, `false`, `null` or digits alone, once trimmed and unquoted (`isKey=true`, `FILE_KEY=9001`, `rowKey: '1'`), stays untouched; `PASSWORD=123456` and `SECRETKEY=123456` are still stored and redacted. Over 4,688 real artifact files the detector fired on 116 values in 61 files and now fires on 79 in 34.
- `cs -doctor` no longer calls an integrate lock stale, or held, when its recorded pid is past the pid range: on Linux the external `kill` truncated such a number to a `pid_t` and answered for another process. The number is reported as one cs cannot check, with no removal advice.
- The session-auto-approve hook prompts for a write into a directory spelled as another case of a control name (`.cs/AGE-RECIPIENTS`, `.cs/PRIVATE`, `.cs/CLAUDE-CONFIG`) on a case-sensitive filesystem, whether the control directory is missing, a plain directory, or a link into an encrypted session's vault.
- A cs lock waits five seconds by the monotonic clock for a live holder. The wait was a count of fifty-millisecond polls, which a loaded machine stretched to twelve seconds, and a wall-clock step no longer shortens or stretches it.

## 2026.10.7

### Changed
- The band above the prompt looks like the status bar now. A `cs` chip in the session's colour leads it, coral once a handoff is armed. The keys are bold in the session's colour, and the bar's rounded caps close the band where you said yes to them.

### Fixes
- The Option+1 and Option+2 keys from 2026.10.6 did nothing in iTerm2, which uses Option+number to switch panes. The installer now offers Ctrl+X R for `/rotate` and Ctrl+X W for `/wrap`, and they need no terminal setting. If you said yes before, the next `cs -update` swaps cs's `alt+1` and `alt+2` for the two chords, with or without a terminal. An `alt+1` or `alt+2` you bound to something else stays. If you bound a bare `ctrl+x`, cs binds neither chord and keeps the Option keys, because Claude Code would wait for the second key and never run yours. `cs -uninstall` removes both sets, and `cs -doctor` names the conflict. See [docs/configuration.md](docs/configuration.md#rotate-and-wrap-keys).
- The `cs` band's keys were a bare `1` and `2`, and those fire from an empty prompt, so a `1` typed to answer a numbered question ran `/rotate`. The band now takes Ctrl+X 1 (rotate, or the `/clear` once a handoff is armed) and Ctrl+X 2 (wrap). The installer binds them beside Ctrl+X R and Ctrl+X W, and a machine that said yes gets them on its next `cs -update`, with or without a terminal. The band shows the chord your `keybindings.json` binds to each key, and none when nothing does; a click or Ctrl+X Tab still reaches it. `cs -doctor` warns until `keybindings.json` holds the chords. See [docs/configuration.md](docs/configuration.md#rotate-and-wrap-keys).

## 2026.10.6

### Added
- The walk-away queue can run each task in a subagent or as a workflow. When the Stop hook or `/queue` offers to start the queue, it also asks how the tasks run: in this conversation, in subagents, or as workflows. `cs -queue start subagents` and `cs -queue start workflow` record the choice, and each task handed out then says to run it that way and to check the result before marking it done. Picking workflows is your go-ahead for Claude Code's Workflow tool. The choice lasts until the run finishes or the next `cs -queue start`, and `cs -queue clear` drops it. In an encrypted session the choice lives in the vault, and `cs -encrypt` moves it there.
- `/finish` shows its progress. A toast says `cs: finishing <task>` when it starts, and another gives the outcome: `cs: landed <task> <sha> -> <base sha>`, `cs: /finish <task> refused: <reason>` or `cs: retired <task>`. While the project's gate runs, the band above the prompt reads `finishing <task> · gate <elapsed>`, also mid-turn. cs writes each step to `finish-progress.json` in `.cs/local` (`.cs/private` in an encrypted session) with its process id, so a cs killed by a signal leaves no band behind. A failed write costs one warning and never changes the landing. An integrate run from a shell, outside `/finish`, shows no toast.
- Option+1 runs `/rotate` and Option+2 runs `/wrap` anywhere in Claude Code, if you want them. The installer asks once per machine, in a terminal. On a yes it adds `"alt+1": "command:rotate"` and `"alt+2": "command:wrap"` to a `Global` block in `keybindings.json`, under `CLAUDE_CONFIG_DIR` when you set it, and in the shell's file when it runs inside an encrypted session. It keeps a key you already bound and names it, refuses a file it can't parse, and writes through a symlinked file. `cs -uninstall` removes only those two values, and `cs -doctor` shows the state. Your terminal has to send Option as Meta (in iTerm2, set the Option key to Esc+). To change the answer, see [docs/configuration.md](docs/configuration.md#rotate-and-wrap-keys).

### Changed
- `/finish` no longer runs your tests before it lands a feature. It merges, fast-forwards the base and retires the worktree without a gate. `/finish <feature> --gate` runs the repo's gates on the merged commit first, as before. This applies to plain feature branches too.
- `/queue <task>` confirms the add with a toast under the prompt, `cs: queued: <task>` (cut at 60 characters). The command's own line goes to the transcript, where a running turn scrolls it out of view.

### Performance
- Reopening a session is faster. A migration whose writes all succeed writes `.cs/local/migrated`, and the next open skips the one-time checks: the `.gitignore` and `.gitattributes` backfills and the `CLAUDE.md`, `CLAUDE.local.md` and README phases. The stamp holds while the cs version, the actor and the encryption stay the same, every file it lists still exists, none of `.gitignore`, `.gitattributes`, `CLAUDE.local.md`, `CLAUDE.md` or `.cs/README.md` changed after it, and `merge.ours.driver` is still set. When only `MEMORY.md` is newer, the open re-runs the narrative check alone. On a loaded Mac a reopen went from 1.27 s to 0.56 s (median of 8) and from 54 external commands to 14. cs also reads `.cs/local/state` with shell builtins instead of one `awk` per key. `cs -doctor` shows the stamp, and `rm .cs/local/migrated` forces the full migration on the next open.

### Fixes
- `cs -statusline enable` and `disable` rewrote `settings.json` through a temp file in `$TMPDIR`. The file came back readable only by you (0600), and a symlinked `settings.json`, like one a dotfiles manager links, became a plain file. Both now rewrite it in place and keep its permissions and the link.
- Leaving an encrypted session's vault could drop the line of another `cs` that joined the vault at the same moment. Joining and leaving now take turns.
- A temp file left by a cs killed mid-write could end up in an autosave snapshot, because its name (`.<file>.XXXXXX`) matched no ignore rule. cs temp files now start with `.cs-tmp.`, and the `.gitignore` cs writes, and the project `.gitignore` that `cs -adopt` appends to, ignore `.cs-tmp.*`. Older sessions get the entry on their next open.
- Every launch asked GitHub for the latest cs version, about 0.4 s and up to 4 s on a slow network. cs used its hourly cache only when it named a newer version, so when you were up to date, the usual case, it asked again every time. A fresh cache now answers either way.
- `/finish` ran the project's gate in a temporary checkout inside the base's `.git` directory (`.git/cs/finish/`), and some tools refuse files under a `.git` directory. Vite's default `server.fs.deny` holds `**/.git/**`, so a vitest browser suite never connected and the gate failed every time. The checkout now lives under `$TMPDIR` (`cs-finish-<task>.XXXXXX`), and cs removes it the same way when the gate ends.
- The Claude icon from 2026.10.5 only showed on a brand-new launch with the default `CLAUDE_CODE_BIN`. On a resume cs ran `claude` as its own child, so tmux named the pane after cs's bash. A resume now runs `claude` in place of cs when the transcript cs reads holds a message, `CLAUDE_CONFIG_DIR` isn't set, and the session isn't encrypted. Otherwise `claude` still runs as a child, a quick failure still starts a fresh conversation, and an encrypted session's vault still detaches after it. A resumed session that runs in place no longer resets the tab colour when it ends, the same as a fresh launch. A `CLAUDE_CODE_BIN` you set, like a path with `--permission-mode` after it, never got the link, and on macOS tmux names the pane after the file a symlink points to, which is the version number. cs now links the first word of `CLAUDE_CODE_BIN` when it resolves to a file directly in the native installer's `versions` directory, named by a version number, and keeps the words after it. Any other binary runs as given. The dependency check splits `CLAUDE_CODE_BIN` on tabs as well as spaces, like the launch does, and cs refuses a value that doesn't start with a command and names it.

## 2026.10.5

### Added
- A cs session in tmux under iTerm2 now gets the same tab as a claude that iTerm2 runs directly. The tab shows Claude Code's progress line along the top while a turn runs, and the Claude icon next to the title. Claude Code only sends the progress escape when `TERM_PROGRAM` is iTerm2 3.6.6 or later, and tmux sets it to `tmux`, so cs starts `claude` with `TERM_PROGRAM=iTerm.app` and the version from `LC_TERMINAL_VERSION`. It does this under iTerm2's tmux integration (`tmux -CC`), or in plain tmux when `TERM` starts with `screen` or `tmux`. With any other `TERM`, Claude Code would take the pair for `tmux -CC`. Claude Code also sends its notifications through iTerm2 once it has that name. Under `tmux -CC` Claude Code now knows it's in iTerm2's tmux integration and uses its classic renderer there unless `CLAUDE_CODE_NO_FLICKER=1` or `/tui fullscreen` says otherwise. iTerm2 picks the icon from the process name, and under tmux that name is the file name of the executable. For the native installer that file name is the version number. cs runs `claude` through a hard link named `claude` in `~/.local/share/cs/claude/<version>/`, one per version, and drops a link once Claude Code removes that version. A `HOME` with a space in it gets no link. `cs -uninstall` removes `~/.local/share/cs/claude/`. cs only links the native installer's `versions/<version>` file, since an npm install's `cli.js` needs the files next to it. `CS_NO_ITERM2=1` turns off both. A `CLAUDE_CODE_BIN` you set runs as is, and if cs can't make the link, `claude` starts the old way.

## 2026.10.4

### Fixes
- cs no longer clobbers a file named `<file>.tmp` next to the session files it rewrites, and those files keep their mode. `settings.local.json`, `CLAUDE.md`, `CLAUDE.local.md`, `.gitattributes` and `.cs/local/state` were each rewritten through a fixed `<file>.tmp` name, so a file of yours with that name was overwritten, and the result came back with the umask's mode instead of its own. The temp file now has a unique name in the same folder and takes the destination's permission bits before the rename. The state file is also rewritten by the SessionStart hook, so the two writers now take turns on a lock beside it. The same holds for `.cs/README.md`, `.cs/memory/MEMORY.md`, the narrative and a rotation handoff. When one of these is a symlink, cs writes to the link's target and the link stays a link. The queue state, the presence line and the update-notes cache moved to a unique temp name too. A tracked `<file>.tmp` is no longer a reason for `cs -adopt --worktrees` to skip a worktree, or for an open to refuse one.
- A walk-away queue no longer stops when `cs -queue start` runs at the moment a turn ends. Both wrote `queue.state` through the same `queue.state.tmp`, so the state could come out as a mix of two words the drain did not know, and it handed out no more tasks. Each write now has its own temp file.
- `cs -adopt --worktrees` finds the conversation of a worktree whose session has exited. Claude Code keeps a running `claude --worktree` session's transcript under the worktree's own folder and moves it into the parent repo's folder when the session ends, next to the parent's own conversations. cs read only the worktree's folder, so it skipped every finished worktree as "no conversation", which is the case the command exists for. When the worktree's own folder holds no conversation, it now reads the parent's folder and takes the newest conversation that began in that worktree and whose worktree record names it. The parent's last conversation never gets bound to it, and neither does a parent conversation that stepped into the worktree with EnterWorktree. The Objective comes from the file cs binds.

## 2026.10.3

### Added
- `cs -adopt --worktrees` registers the worktrees Claude Code creates with `claude --worktree` as sessions. Run inside the repo, it names each `.claude/worktrees/<name>/` that holds a conversation `<repo>.<name>`, binds it to that conversation, and seeds the Objective from its first prompt. The checkout is a live branch, so cs hides its files (`.cs/`, `.claude/settings.local.json`, `CLAUDE.local.md`) through the repo's `.git/info/exclude`, commits nothing, and leaves the tracked `CLAUDE.md` alone; an open of such a session skips the `.gitignore` and `.gitattributes` backfill other sessions get. cs skips a worktree with no conversation, one whose branch tracks a file cs rewrites at every open (`CLAUDE.local.md`, `.claude/settings.local.json`) or whose `.claude` is a symlink, and anything under `.claude/worktrees/` that is not a worktree of this repo. A re-run adopts only what is new, finishes an adoption that stopped part-way, and prunes the links of worktrees Claude Code has since deleted. `--dry-run` prints the plan and writes nothing. An open of such a session refuses, before it writes anything, if the branch has since started tracking one of those files. The separator is `.` because `@` names a feature worktree of a base session, which these are not.
- `cs -adopt` seeds the session Objective from the project's newest conversation. It reads the first prompt somebody typed into the transcript Claude Code already keeps for the folder, with the rules the prompt hook applies to a live session: a slash command, a tool result, injected text and anything under 8 characters do not count, and the line clips at 100 characters. The picker and the status fallbacks read the Objective, so an adopted project shows its subject from the first open. A project with no conversation keeps the placeholder, and the first prompt typed after the open fills it as before.
- The picker's `/` search reaches the objective. A session whose name misses the query stays in the list when the `## Objective` line of its `.cs/README.md` matches, after the name matches and without highlighting, since the highlight addresses the name. An adopted project named by its folder, or a worktree named by a tool, turns up when you search for the work instead of the folder name.

### Fixes
- cs finds Claude Code's conversations for a session whose path has an underscore, a space or any other character outside letters, digits and `/` and `.`. Claude Code names the transcript folder by turning every such character into `-`; cs turned only `/` and `.`, so for a path like `~/.claude-sessions/my_project` it looked in a folder that does not exist, found no conversation, and the first open started a new one. The picker's rename moves the transcript folder under the same rule.

## 2026.10.2

### Fixes
- The first `cs <name>` after `cs -adopt` no longer asks "Continue previous conversation?" in a project with no Claude Code conversation to resume. `cs -adopt` recorded an id for a conversation that did not exist yet, so the first open offered to resume it, the resume failed, and cs started fresh with "No previous conversation found". That open now starts a new conversation without asking, records it, and the launch card says `new`. A project Claude Code already ran in still offers to resume its newest conversation. A pending rotation handoff is still offered on such an open, with `r` (from the handoff), `n` (fresh, the default) and `d` (discard); a spawned open starts fresh and leaves the handoff for an attended one. A feature worktree opened without its recorded id binds the folder's newest conversation instead of starting over it. (#12)
- Re-adopting the records a removed session left behind keeps the conversation and the colour they name. `cs -adopt` replaced both with fresh values, so the next open no longer resumed the conversation.
- cs hands `claude` a recorded conversation id only when it's a UUID, and a recorded colour only when it's one of the eight `/color` accepts. On the first open of a cloned session or an adopted project, the first open copied the `claude_session_id:` and `claude_session_color:` lines from the committed `.cs/README.md` into machine-local state without a check; the resume prompt passed the id to `claude` word by word, and the colour became the launch's first prompt, so the repo could put options such as `--dangerously-skip-permissions`, or any first prompt, on the launch command. The README import, re-adopt's kept values and the launch now take only a UUID and only a known colour; cs drops anything else with a line naming the file, and a dropped id counts as no conversation, so the open starts a new one.
- A `cs <name>` with no recorded conversation id still refuses to open while a `claude --name <name>` is running; the check used to need the id.
- A `.cs/local/state` write that fails (permissions, a full disk) ends cs with `Error: could not write <path>` instead of a bare shell error.

## 2026.10.1

### Added
- `cs -encrypt <name>` encrypts an existing, closed session on macOS. It creates an `hdiutil` encrypted sparse bundle outside the session directory, moves the session's private files into it, links the four vault names, and writes a `pre-open` that asks for the password in the terminal at every open. The SessionEnd hook unmounts the volume once the lead conversation's Claude Code exits, unless the session reopened. An open that stops before Claude Code starts unmounts the volume it mounted. See [docs/session-layout.md](docs/session-layout.md#encrypting-a-session-with-cs--encrypt).
- The `encrypted` tag marks a session that keeps its notes in an encrypted volume. The picker draws a lock after its name and adds a `vault` line to the preview, `locked` or `unlocked` by whether `.cs/memory` resolves; the status line draws the same lock after the session name. The lock is a Nerd Font glyph behind the same font answer as the capsule ends (`cs -statusline caps`), with `enc` until the machine has answered yes. Set it with `cs <name> -tag add encrypted`.
- Encrypted sessions keep their private files on the encrypted volume. Four names under `.cs/` link into the mount, each one opt-in: `memory`, `plans`, `claude-config` and `private`. With `.cs/claude-config`, cs launches Claude Code with `CLAUDE_CONFIG_DIR` set there, so transcripts, prompt history, `.claude.json` and its backups stay in the vault. Claude Code keeps the shell's login, cs links in the shell's settings, skills, plugins and hooks, and `.claude.json` starts as the shell's copy with every project's record dropped. With `.cs/private`, cs keeps its own content files there instead of `.cs/local/`: the command log, prompt trace, `MEMORY.md` snapshot, mailbox, walk-away queue, queue inbox, failure counter, rewrite trace, the rotation handoffs with their pending marker, and checkpoints. A narrative behind the `.cs/memory` link rotates into `.cs/private/narrative-archive/`, or through a `.cs/narrative-archive` link, and the autosave snapshot leaves the mounted volume out. See [docs/session-layout.md](docs/session-layout.md#encrypted-sessions).
- While an encrypted session's volume is not mounted, cs writes nothing in its place. `cs <name>` refuses to open it and names the link, now for `.cs/claude-config` and `.cs/private` as well as `.cs/memory` and `.cs/plans`; the hooks log nothing and wake nothing, `cs -msg` refuses to send to it, and `cs -queue` in it refuses. Opening one also refuses while a plaintext copy stays outside the vault (`session.log`, `scope-prompt.trace`, `memory-index.snapshot`, `mail`, any queue file, `notifications.jsonl`, `notifications.seen`, `failures`, `rewrite.trace`, `pending-handoff` in `.cs/local/`, a `.cs/handoffs/` or `.cs/checkpoints/` folder, or a plain `.cs/narrative-archive/` beside a linked `.cs/memory`) and names the file. A regular file where a link belongs refuses the open too. Creating or opening a feature worktree of an encrypted session refuses, mounted or not, because worktrees of an encrypted session are not supported yet. While any volume is mounted inside the session, read from the mount table, `cs -rm` and the picker's delete refuse to remove it, even with `--force`, and even when a `cs -encrypt` stopped before it linked the volume. `/finish` does not retire a feature worktree with a volume mounted inside it, and `cs -uninstall` keeps your session data, without asking, while a volume is mounted anywhere inside it. The picker does not rename an encrypted session, since its vault links and transcripts name its path.
- In an encrypted session the objective, environment and outcome live at the top of the narrative. The prompt hook no longer copies the first prompt into `.cs/README.md`, and `CLAUDE.local.md` gains a `cs:encrypted-protocol` section that says so. The launch prompt after `r` and the `rotated` event in `timeline.jsonl` leave out the handoff's file name, and a `checkpoint` event leaves out its label, since all three are plaintext and the name is the topic.
- `/sweep` asks whether a check could carry a rule. When it writes a `feedback` or `project` entry that states a rule, it looks for a test, a lint or grep guard, a hook, a type or a script that could enforce it. A check counts only when compliance needs no judgment, it would match no legitimate code in the tree today, and nothing enforces the rule yet. `/sweep` then adds a task to build the check and keeps the entry as written. Most of these entries carry the incident or measurement behind the rule, and a failing check would not show it. On the 137 entries in this repo's memory, the first wording matched 63.5% of them (a check existed or was possible) and proposed 82 new checks, of which 39 (47.6%) survived an independent pass that tried to refute each one. The wording that ships matches 34.3% and proposes 40, of which 23 (57.5%) survive.

### Changed
- The rotation nudge at 65% context no longer names `.cs/handoffs/`, since an encrypted session keeps its handoffs elsewhere.
- `cs -rm` names the files and folders in a session that cs did not create (anything beside `.cs/`, `.claude/`, the git files and the two `CLAUDE` files) before it asks to remove the session. `--force` refuses such a session and lists them; add `--delete-files` to remove it anyway. A worktree session (`base@task`) gets the same check for the files git does not track there, untracked or ignored, since those have no copy on the branch. An adopted session still loses only its link. The picker's delete confirm lists the same files, for one session or a marked batch, and does not open when the list cannot be read. A batch delete names why each session it could not remove failed. Tab completion offers `--force` and `--delete-files` after `cs -rm`.
- The Claude mark holds its darker coral while Claude waits for you, and a red capsule's text stays white. Both used to blink once a second. An idle bar now repaints once a minute, so a blink would stick on whichever colour it drew last. In a 16-colour terminal the waiting mark now turns red. Both of its shades used to be the same yellow there, so it never changed.

### Fixes
- `cs -statusline enable` and the installer set `statusLine.refreshInterval` to 60 instead of 1. At 1, Claude Code 2.1.286 stopped any render still running when the next one was due and ran `ps -A` twice to stop it. On a loaded machine a render can take longer than a second, and then Claude Code stopped every one: the bar stayed blank, each session ran about two `ps -A` a second, and a dozen sessions together hit the per-user process limit. The installer's refresh rewrites an existing registration. An idle bar still repaints once a minute, so a conversation opened outside cs stays live in `cs -live` and the picker.
- A `/clear` or `/resume` removed `.cs/session.lock` while the same Claude Code kept running, so a second `cs <name>` skipped the collision check and opened the session twice. The SessionEnd hook now keeps the lock for both.
- Inside tmux under iTerm, a tab whose panes run two cs sessions shows both names, `cs: claude-sessions | fignity`. iTerm's tmux integration keeps the tab's title itself and never takes the tmux window name, so the window name alone did not reach the tab. Each title claim now also starts a small helper in the background that sets the tab's title through iTerm's Python API. It needs the API turned on in iTerm's settings and the `iterm2` Python module on the first `python3` in `PATH`; without them the tab keeps its title and nothing else changes. Each pane's own title still names its session alone.

## 2026.9.23

### Added
- The dialog bare `/queue` opens has a third answer, Compact: it compacts the conversation, then starts the queue as Start does. When the compaction does not happen (a hook vetoes it, or a turn is running), the queue stays unarmed and a notice says why.
- `/sweep` snapshots `MEMORY.md` before it edits the index, then runs `memory-index-guard.sh check`. The check fails when a pointer lost its link, when a memory entry has no pointer, or when the file is over the 24400-byte budget that keeps it under the size Claude Code loads in full. `restore` puts the snapshot back. A session with no `MEMORY.md` yet snapshots an empty index, so its first sweep can pass.
- An executable `.cs/local/pre-open` in a session runs before `cs <name>` opens it, from the session directory on your terminal, and a non-zero exit aborts the open. A session that keeps `.cs/memory` and `.cs/plans` on an encrypted volume can mount it there, password prompt included. The file lives in `.cs/local/`, which is never committed, so a cloned session cannot make `cs` run code.

### Changed
- CI's shellcheck lane holds warnings to the count in `.shellcheck-warnings` (129). A change that adds a warning fails, and so does one that removes a warning without lowering the number. `bash tests/lint_shell.sh` runs the same check locally.
- `tests/run_all.sh` stops a suite that runs past 600 seconds, together with its child processes, and counts it as failed. Before, a hung suite held the gate until someone killed it. `CS_TEST_SUITE_TIMEOUT` sets the cap.
- cs no longer force-adds anything into a `.cs/` the repo ignores. `cs -narrative rotate` with a narrative that git tracks under an ignored `.cs/` still rotates, but commits nothing and says to run `git rm -r --cached .cs`. The rotate skill checks each path with `git check-ignore` before staging it and skips the commit for an ignored handoff instead of running `git add -f`. Both force-adds put session notes into public repos that meant to keep `.cs/` private. This reverses the 2026.9.22 fix that committed such a narrative.

### Fixes
- `cs -secrets set` echoed a value typed at the terminal, leaving it on screen and in the scrollback. It now reads the value hidden. It also refuses a value that is a placeholder (`[REDACTED: ...]`, asterisks, `<redacted>`, `YOUR_API_KEY`), which would otherwise replace a working secret.
- The unread-mail digest put each message body inside plain quotes, so a body could close the quote and read as the hook's own text. Each body now sits between `<cs_mail>` tags that share a random id, with a note that mail from other sessions may carry instructions you did not write and is followed only where your own message asks.
- The `/write-as-me` corpus kept the prompts cs types when it opens a session: the rotation handoff pointer and the `cs -spawn` kick. Claude Code records them as typed messages, so the voice profile learned them as your writing. The corpus build now drops them and counts them as machine-authored.
- The session log and the timeline recorded every conversation end as `user_exit`. The SessionEnd hook read a `source` field that Claude Code never sends there; it now reads `reason`, so a `/clear`, a `/resume`, a logout and a normal exit are told apart.
- Opening a session whose `.cs/memory` or `.cs/plans` is a symlink into an unmounted encrypted volume failed with two bare `mkdir: ... No such file or directory` lines. `cs` now names the link and its missing target and says to mount it. It still creates nothing in their place.

### Upgrade note for clones of this repo
- `.cs/` and `.skillopt-sleep/` are no longer tracked. A pull on another clone of this repository removes them from its worktree, so copy them aside first. `git archive abd27bb3 .cs | tar -x` restores `.cs`.

## 2026.9.22

### Added
- `/queue <task>` in a cs session adds a task to the walk-away queue, even while Claude is mid-turn; `/queue` alone lists the queue. It comes from the `cs` mod and runs `cs -queue add` through `CS_BIN`.

### Changed
- When a rotation handoff is pending, the launch lists its four answers one per row, key first, in the layout of the already-open menu: `y` resume (the default), `r` fresh conversation from the handoff, `n` fresh conversation with the handoff left pending, `d` discard. The keys are the same letters as before.
- Before it writes a handoff, the rotate skill copies out every fact the conversation produced, word for word and in order: ids, readings, errors, what the user said, decisions, claims nobody checked, and what is still running. These go into Settled and rejected and Conversation-only facts, and sections 4 to 9 are now short pointers. In an eval where a new conversation answered, from the handoff alone, the questions real successors had to look up again, this scored 0.2 points over the old spec, which is inside the noise. Handoffs are about 40% longer.
- Rotation handoffs label each claim, not each bullet. A cause inferred beside a measured symptom is `assumed`, and a claim that something fails carries the command that failed and what it printed. Across 40 handoffs "measured" appeared in 38 and "assumed" in one, and the two wrong claims a review found were both unlabelled conclusions.
- The handoff body has a `Conversation-only facts` section in its first pass, for exact readings, run ids, counts, event order and the user's own words. The writer checks each such fact off before the first commit. The skill no longer says exact readings live in the second pass, which contradicted the two-pass rule.
- A handoff's Next Step carries every fact its first action needs (command, path, host, branch), even when the fact is also written down elsewhere. A pointer to a script says in one clause what the script does. An action in Next Step that starts work first says how to tell whether it is already done or still running.
- The conversation that picks up a rotation appends a `## Successor report` to the handoff once its next step is done: what it had to look up again, re-derive, or found wrong, or `none`. The next rotation commits the report, and the rotate skill's prune never deletes a handoff with uncommitted changes.
- A handoff whose next step needs a clean worktree (a branch switch, a merge, a rebase) now includes a step to commit the handoff first. Session start marks the handoff consumed, which leaves it uncommitted, so git refused the branch switch the next step asked for.
- The rotate mod is now `cs`, deployed to `~/.claude/skills/cs/`; the installer and `cs -uninstall` remove the old `~/.claude/skills/cs-rotate`. Its machine-local markers are renamed with it: `.cs/local/cs.heartbeat` and `.cs/local/cs.forced` replace `cs-rotate.heartbeat` and `cs-rotate.forced`. Old marker files are left in place and nothing reads them.
- Every launch exports `CS_BIN`, the path of the running cs, in place of `CS_UPDATE_BIN`, which was exported only when an update was pending. The cs-update mod runs `cs -update` through it.

### Fixes
- `cs -narrative rotate` now commits in a repo that ignores `.cs/` but tracks the narrative with `git add -f`. `git add` exits with an error for any path under an ignored directory, the tracked narrative included, so cs wrote the rotation but never committed it. The archive now goes into git with a tracked narrative even when the repo ignores `.cs/narrative-archive/`. A narrative git does not track is still left out of the commit. When the repo is mid-merge, the warning now says the two files sit in the index and go into the merge commit.
- `cs -doctor` no longer warns "autosave may be broken" after a `/clear`. It looked for the snapshot ref of the conversation that started the session, which the `/clear` had already deleted, instead of the current conversation's. It now checks the ref of the conversation running it, so a teammate is no longer judged by the lead's. It reports a missing ref as "no snapshot for this conversation yet": autosave runs only on Edit and Write, so a conversation that has only used Bash has none. It does warn when `settings.json` does not register the autosave hook, which no other doctor row caught.
- The prompt hook that adds the scope block now gets 10 seconds instead of 5. On a loaded machine a `/wrap` lost its scope block to a timeout error, and the hook had not yet written its first trace line when Claude Code killed it: the other prompt hooks on that same prompt took 2.3 seconds to answer. The hook now also writes a `launch` line to `.cs/local/scope-prompt.trace` before loading its library, so the next such kill shows whether the hook stalled in its first steps or never started.
- The "(from another checkout)" label on a pending handoff prints in dim text, not as a raw `\033[...m` escape sequence.
- `/clear` and exit no longer wait about 8 seconds for cs. On every session end cs rebuilds `~/.claude-sessions/index.md`, and it ran about six small processes for each session to read its README, so 138 sessions took 8 to 27 seconds. One awk process now reads them all, in 0.15 seconds, and writes the same index.
- The rotate skill's prune no longer deletes a handoff that git does not track. Where `.cs/` is gitignored, `git status --porcelain` prints nothing for such a file, so it passed the uncommitted-changes check, and deleting it would have deleted the only copy.
- `cs -queue add` refuses a multi-line task, as `cs -msg --kind task` and `cs -spawn --task` already did: the queue's done log and listing are line-oriented. The three share one check.
- A rotation starts on its own after `/clear` even when the machine is busy. The kick that wakes the new conversation was written twice, 2 and 4 seconds after session start launched its writer, but Claude Code only watches for it once session start has finished, which took 21 seconds under a parallel test suite. Both writes were missed and the conversation sat waiting under a notice saying it would continue by itself. The kick is now rewritten every 2 seconds until the wake lands, up to 30 times. A teammate's `/clear` also no longer cancels the lead's pending kick.
- `/wrap` reads its sweep and summary instructions with the Read tool. It had been reading them through the Bash tool, whose shell is zsh on macOS, and a separator line like `echo ======` is a failed command lookup in zsh that stops the rest of the command, so the summary instructions were never read.

### Docs
- README, docs/hooks.md, docs/session-layout.md and docs/statusline.md corrected against the code: the rotation wake after `/clear`, session liveness (lock or statusline heartbeat), `/queue` and `/cs-update` in the slash-command list, scope-prompt's five responsibilities and trace stages, the Fable window's 50% threshold and 5h reveal, colour-depth order inside tmux, and missing timeline events and layout rows.

## 2026.9.21

### Changed
- Inside tmux, a window whose panes run more than one cs session is named after all of them, `cs: claude-sessions | fignity`, in pane order. Under iTerm's tmux integration that name is the tab's title, so a second session no longer takes the tab from the first. A session that ends leaves the name; with none left the window names itself again. Claims from several panes at once are serialised by a per-window lock that never waits more than five seconds.
- The Handoff pane shows the whole next step, drawn as markdown the way Claude Code draws a reply: lists, bold, code and links come out styled rather than as their markers. It used to stop at twelve lines without saying so.
- The forced rotation's countdown is coloured: the session's own colour while there is time, amber from ten seconds, red under five, on the band's `/clear in Ns` and in the Handoff pane. The pane opens on a header in the session colour and counts down on a twenty-block bar.
- Bare `cs` always opens the session manager, including from a session's own directory. `cs .` opens the session you are standing in (an adopted project under its cs name); outside a session it refuses and names `cs -adopt`.

## 2026.9.20

### Fixes
- A feature worktree session no longer opens on the base session's task list. `CLAUDE_CODE_TASK_LIST_ID` was the base name for every `base@task` launch, so a new feature showed, and could edit, the tasks of the session it was cut from. It is now the feature's own name, so each feature starts with an empty list of its own; the base's list is untouched. Secrets still key to the base. Adopted sessions take the same path. Feature sessions already open keep the list they launched with.

## 2026.9.19

### Added
- Release notes in the session. When a launch finds a newer cs, the new `cs-update` mod opens one pane with the full changelog for every version above the installed one, once per load of the mod (a launch, or a plugin reload), in the conversation cs launched. `1` runs `cs -update` in place through the engine's process runner (no shell; the path and the version come from the launch, never from the mod's own check) and the pane keeps the outcome until closed, since the new files take effect on the next launch. Installing the update rewrites the mod's own file and Claude Code reloads it mid-conversation, so the outcome is written to `.cs/local/cs-update.done` and the reloaded module reads it back from its next render or from `/cs-update`, instead of offering the install a second time. `Esc` closes it; `/cs-update` reopens it; `/config` → `cs-update.showReleaseNotes` turns the launch pane off. The launch banner's summary card now prints only when function hooks are off, so the notes appear once. The notify check caches the changelog span beside the summaries (`~/.cache/cs/update-notes-full-<version>`), and a launch with an update pending exports `CS_UPDATE_AVAILABLE` and `CS_UPDATE_BIN`.

### Performance
- The session picker no longer freezes on the arrow keys. Its ten-second rescan forks `git remote get-url` for every checkout session (91 of 139 here), and on a busy machine those forks took longer than the ten seconds, so the picker was inside the rescan almost continuously and every key press waited for it. The rescan now runs on a worker thread and the loop swaps the result between two frames, with the highlight pinned to the same session by name; a rescan the user triggers (delete, rename, archive) still runs before the next frame and discards any worker read that predates it, so a deleted row never comes back. A result that finishes while a delete or rename dialog is open waits until the dialog closes, so the row the dialog acts on cannot change underneath it. Measured with thirty Down presses on the same machine: the slowest press fell from 936 ms to 145 ms and the mean from 128 ms to 65 ms.

### Docs
- `README.md`, `docs/hooks.md` and `docs/session-layout.md` describe the cs-update mod, its `/config` row, the two launch exports, the done marker's readers, and when the launch card still prints.

## 2026.9.18

### Added
- `/write-as-me` keeps writing that no transcript holds. Put a Markdown file under `~/.claude-sessions/.voice/sources/` (an exported chat, sent mail) and every corpus build appends it under `## Supplementary source: <file name>`, in name order, after the short-ack appendix. The corpus is rebuilt whole each time, so a section added to `corpus.md` by hand did not survive the next build. Source lines go through the same credential redactor as the transcripts, the stats header counts the files, and a build with no `sources/` directory writes the same corpus as before. When you distill the profile, a source outranks extrapolation for the register it covers. The corpus file itself is now written owner-only (600), as the sources are, rather than at the shell's umask inside the private directory.

### Changed
- A conversation rotates itself at 80% context. `CS_ROTATE_FORCE_CTX` used to be off unless set; it is now on at 80, above the 65% nudge and below where Claude Code's own auto-compact lands, so the handoff is written while the conversation is still whole rather than after a summariser has thrown half of it away. `CS_ROTATE_FORCE_CTX=off` (or `0`) turns it off and a percentage moves it, while a value that is neither reads as the default rather than as off: a typo must not quietly disable a rotation you are relying on. The grace is unchanged — 20 seconds in the band, `1` to go now, any prompt to stop it — and the first launch on a machine prints one notice naming the threshold and the way out, recorded in `${XDG_CONFIG_HOME:-~/.config}/cs/rotate-force-notice`.
- The rotation band stops offering a wrap that already finished. `/wrap` gains a last pass that writes `.cs/local/wrapped` with the id of the conversation it ran in once memory, summary and narrative rotation are done, and `2: wrap up this session` hides while that marker names the conversation, however the wrap was started; the next turn that starts from a prompt (not a Stop-hook continuation) empties it and brings the key back. A standalone `/summary` and a teammate's wrap hide nothing, and a wrap that fails a pass writes no marker, so a failed second wrap brings the key back too.

### Performance
- A conversation's first status line no longer waits on the tmux ancestry walk. The walk (a `ps` and an `awk`, asking whether this process is really inside the tmux server `TMUX` names) is the one cost a render pays exactly once: it appears in a conversation's first render and in none after, and that first render is the one Claude Code kills for running too long, which starts the retry loop that leaves the bar blank for seconds. The first render now answers real — what every pane cs launches is — and spawns a detached child to walk the tree and write the verdict under the same parent identity, so the render a second later reads a settled answer. Measured against a `ps` that takes two seconds: the first render fell from 2386 ms to 167 ms. The cost, accepted: an environment that only inherited `TMUX` draws its own terminal's palette for one render and is corrected on the next. Renders after the first are untouched, and still fork nothing but the interpreter and `jq`. Only one walk runs at a time: a `ps` that stalls would otherwise have a walker spawned against it every render, once a second, per conversation, so the render that spawns one marks the walk in flight for ten seconds and the renders inside that window draw without spawning another. Measured with a `ps` that never returns, five renders a second apart: five stalled walkers before the mark, one after. Past the ten seconds one render tries again, so a child that died before clearing its mark wedges nothing, and the mark costs one file write on a cache miss and no fork at all. The walker itself is bounded too: it gives its `ps` five seconds, shorter than the mark, and kills it by the pid it recorded, so a stalled walker is gone before its replacement can be spawned and nothing accumulates across windows. The detached usage refresher no longer settles the terminal at all (no ancestry walk, no theme, no tmux client lookup): it paints no bar, and a walk there ran with no deadline ahead of the refresher's lock.

### Fixes
- The forced-rotation notice stays quiet when function hooks are off. The rotate mod is a function-hooks plugin, so with `CS_NO_FUNCTION_HOOKS=1`, or a `0` the shell set, nothing rotates; the launch still announced that cs would, and spent the once-per-machine marker on it, so a machine that turned hooks on later was never told. The launch now reads `CS_ROTATE_FORCE_CTX` the way the mod does, trimming only the ends: `1 5` is a typo and the default, where the shell used to read fifteen.
- A skipped test is counted as skipped. Twenty-seven sites across fourteen suites printed `SKIP` and returned 0, which `run_test` counts as a pass, so a runner without bun passed every mod and layout unit test, and a host that cannot deny a write or build a stub PATH passed the tests that needed one. Each now returns 77 (skipped, and named in the tally), and `tests/test_docs.sh` fails on the shapes that returned 0: a `SKIP` message followed by `return 0`, `_deny_writes ... || return 0`, and a helper's cannot-build-here status turned into `return 0`, with a canary assembled at runtime so a sweep cannot empty the search. The results line names a skip count only when a test was skipped.
- A narrative budget or threshold too long for the shell's arithmetic falls back to its default. `CS_NARRATIVE_MAX_BYTES=99999999999999999999` wrapped past 64 bits to a positive 7766279631452241919, a budget no narrative ever reaches, so rotation never fired and the over-budget warning never showed; the same wrap through `_num_or` silenced the rotate nudge, the context warning and the queue's own ceilings. Sixteen digits or more now take the default: a bound on length, as the scope hook's budget already had, though each validator's own ceiling differs (the scope budget stops at eight digits, the status line's thresholds at three).
- `/finish` no longer treats a landing commit whose checks were all skipped as green. Every check skipped is nothing having run, and it classified as `pr_checks: success`, so the skill passed `--ci-green` and the local gate was skipped on a tree CI never tested. `success` now needs at least one real success beside the skipped and neutral ones; all-skipped is `none`, which runs the gate.
- The scope hook keeps its scan on a shell whose clock ticks in whole seconds. On a bash without `$EPOCHREALTIME` the elapsed reading jumps a full 1000 ms at the first tick however little was spent, and the deadline is `-ge`, so any `CS_SCOPE_BUDGET_MS` at or under a tick dropped the grounded scan on that boundary alone. A positive budget of one tick or less now takes the 1500 ms default, the only value above a tick; zero still skips every prompt, and the stage trace names the budget the run settled on.
- A `Retry-After` header can no longer end usage polling. Twenty digits wrapped past 64 bits to a positive number centuries away and the refresher would have waited there for good; fifteen digits survived the arithmetic and still named a horizon 31 million years out. A header of more than fifteen digits now takes the 600 s floor, like one that is not a number, and any accepted value is capped at an hour — a server may name any horizon, and the next render reads the header again anyway. `CS_STATUSLINE_NOW` is bounded the same way.
- `cs -spawn` stages nothing when the seed cannot be written. The seed write was an AND list, which `set -e` does not judge, so a failed write still opened the window, and the brief it had already staged stayed behind for the next spawn of that name to inherit although that spawn asked for no brief. Staging now writes the seed's content first, stages the brief second and publishes the seed last, so a failure at any step leaves nothing behind and never removes what another spawn of the same name published. The seed is written by a single `printf`, because a brace group reports only its last command's status: a failed spawner-line write with a succeeding task line published a seed missing its first line.
- The forced rotation's `Handoff` pane closes when its count ends while the pane is still opening. The count set the pane's contents before the open's round trip, so a prompt landing in between asked for a close the engine could apply first, and the pane that opened afterwards had nothing left to close it.

### Docs
- The README's rotation tiers name the 80% forced rotation, and `docs/hooks.md`, `docs/configuration.md`, `docs/session-layout.md` and `docs/statusline.md` match the code on the default, the one-tick scope budget, the trace's `budget=` line, the four swept cache buckets and the `Retry-After` cap.

## 2026.9.17

### Changed
- The rotation band leaves the percentage to the status bar and asks before a wrap. The band is a bare line with a blank line above it on the status bar's own capsule fill (a shade of `CS_TERM_BG_RGB` a tenth away from itself, and no fill at all where cs measured no background), and it no longer repeats the context percentage the bar already carries. The wrap key asks through Claude Code's own AskUserQuestion dialog: `2` opened a five-second window and put the confirmation on `3`, and now opens `Run /wrap for this session?` on the press, so one key reaches the question; a dismissal, and a `-p` run with nobody to ask, run nothing.
- The first forced rotation of a session shows its handoff while the grace runs. A `Handoff` pane beside the band carries the handoff's `Next Step` (up to twelve lines) and the count, opens once per session, carries no keys (the count still stops from the band) and closes wherever the count ends. Claude Code draws a pane a mod opens on its own only from 144 columns, so a narrower terminal keeps to the band.

### Docs
- The mods design lab opens on a band canvas. `docs/mods-design-lab.html` showed one element at a time; its new first panel builds a whole tree out of nested Box, Text and Button, with an outline to move and delete nodes, an inspector per node, the strip as the terminal would draw it, and the JSX to paste into a mod. `docs/mods-layout.js` holds the layout pass (flex in both directions, gaps, alignment, `flexGrow`, padding, margins, the eight borders, wrapping, hidden overflow), loaded by the page as a plain script and covered by `tests/test_mods_layout.sh` through bun, with the shipped rotate band as its oracle.

### Removed
- The cs-hint mod. `mods/cs-hint/` drew the hint line under the prompt (unread mail, an armed handoff, the queue, a resumed handoff's purpose, else a cs tip); the mod, its doctor row, `CS_NO_HINTS`, the `hints: off` state line and `.cs/local/cs-hint.*` leave with it. The installer and `cs -uninstall` remove a deployed copy from `~/.claude/skills/cs-hint/` (now a retired skill directory), so an upgrade takes the line away rather than leaving a mod that nothing ships or checks for drift. cs-rotate stays.

### Performance
- A warm status-line render starts three processes instead of six (five instead of eight on stock macOS bash 3.2), measured by pid gap on a quiet machine, 25 runs, controls calibrated. The bar repaints once a second in every open session, and a command substitution and each side of a pipeline are processes of their own, so three of the six were bookkeeping: the payload reached `jq` through a `printf` pipe (two), the caps-consent path came back from a substitution (one, now a variable read once at load), and `tty` ran every render outside tmux (now cached per conversation under `~/.cache/cs/tty/`, beside the other parent-keyed caches, and pruned with them). A render through a status-line bridge, which starts its own processes before this script runs, goes from twelve per tick to nine.

### Fixes
- `cs -doctor` no longer tells you to delete an integrate lock it cannot judge. A lock with no recorded holder pid was reported as stale with an `rm -r`, but the autosave hook takes that same directory and records no pid, for as long as a snapshot takes (its registration allows ten seconds) — and removing it would not stop that worker, it would let an integrate take the directory while autosave keeps committing, which is the interleaving the lock exists to prevent. Such a lock is now named as one cs cannot judge, with no removal command. A recorded pid this process cannot see is reported as exactly that (`ESRCH` is absence only in the caller's pid namespace, and pids are recycled) and its removal is conditioned on the person confirming nothing is using the checkout. A holder cs may not signal says so in its own words.
- The test harness counts a skipped test separately. `run_test` read every zero return as OK, so a test whose fixture the machine cannot produce passed without proving anything: the pid-1 case for doctor's permission-denied branch went green as root, where `kill -0 1` succeeds and the branch never runs. A test returning 77 is now reported as skipped and listed by name, and that case checks its fixture before asserting.
- The status line's `~/.cache/cs/tmux-client/` and `~/.cache/cs/tmux-real/` get pruned. Both take the Claude Code pid as their key, so each conversation could leave entries behind and nothing removed them (about 4,000 each after a month). The Fable usage refresher, which already runs detached and under its own lock, now deletes entries older than an hour, so a machine that runs Fable sessions keeps them small; the once-a-second render still forks nothing for it.
- `cs -doctor` judges an integrate lock by the pid the integrate now records inside it, not by whether any `-integrate-feature` is running anywhere on the machine: doctor reported a lock left by a killed `/finish` as held whenever an unrelated integrate happened to be running. The command doctor gives to clear a stale lock is `rm -r`, since the lock is no longer an empty directory.
- Two suites stop dying of their own assertions on a loaded runner. `tests/test_run_all.sh` and `tests/test_scope_prompt.sh` checked output with `printf '%s' "$out" | grep -q`, and under `pipefail` a `grep -q` that matches early kills the `printf` with SIGPIPE (measured `PIPESTATUS=141 0` on a loaded macOS runner, 3 of 40 runs), so a passing run reported "wrong failure tally" or "expected a scope block" while dumping the text it wanted. Every such site now reads the text from a herestring, the form the harness's own helpers already use, and the three corpus loops dump the hook's output when they fail.
- Two tui test races. The session-menu Enter test forked cs for the Archive and Secrets rows with no `CS_BIN` of its own, so under a parallel run it forked whichever recording stub a concurrent test had set and wrote into that test's argv log and sessions root (or, with no stub set, the real `cs -archive alpha` against the developer's sessions); it now holds the env lock and points `CS_BIN` at an unspawnable path. The in-flight preview test raced the worker on a loaded machine (24/30 and 1/25 red before, 0/30 and 0/25 after): it now hands the stale result to the drain on a channel it owns.
- A headless run beside a session is not a conversation to resume. An Agent SDK call or a `claude -p` with the session as its working directory writes a transcript into the same folder as the session's own, and the launch card named it as `A newer conversation was opened here outside cs`; the orphan repair could bind a session to one. Discovery now skips a transcript that opens with an `sdk-` entrypoint and carries no other kind, while a run someone later continued with `claude --resume` stays a conversation, as does any transcript with no entrypoint or one cs does not know.
- No writer pipes into `grep -q`. A `grep -q` exits at its first match, so a writer piping into it is left writing into a closed pipe: it dies of SIGPIPE, `pipefail` promotes 141 to the pipeline's status, and a pattern that matched reads as a failure. Two suites had already gone red on a loaded runner; the other 96 sites across 12 suites were the same shape waiting for the same load, and each now reads from a here-string, which is a file with no reader to close. `tests/test_docs.sh` closes the class: it fails on any writer piped into `grep -q` under `tests`, `hooks`, `lib`, `bin` and `mods`, and carries a canary built from halves so a later sweep cannot rewrite the search into one that matches nothing. The two probes inside `sh -c` are exempt and say why.

## 2026.9.16

### Changed
- One list of what cs deploys. `install.sh` and `bin/cs` each carried the manifest arrays (hooks, their libraries, commands, skills, mods, and what past versions left behind) and the settings-strip filter behind KEEP IN SYNC comments; they now come from `lib/01-manifests.sh`, which `./build.sh` folds into `bin/cs` and splices into `install.sh` from `install.sh.in`, so `install.sh` is a built file like `bin/cs` and CI fails when the committed copy differs from the build. A web install works as before: the file it runs still carries everything inline.
- The hooks run cs's own actor and narrative-budget code instead of a copy. `./build.sh` folds `lib/02-shared.sh` into `bin/cs` and writes it to `hooks/cs-shared.sh`, a library deployed beside the hooks like `cs-resolve.sh`; CI fails when the committed copy differs from the build. The two hooks that carried their own versions of the actor precedence and the budget validation now source it, so `CS_NARRATIVE_MAX_BYTES=0` reads as the default in the Stop hook too, as it already did everywhere else, and a zero in any spelling (`00`) is the default rather than a zero-byte budget that rotated on every run. A hook deployed without the library names the actor `unknown`, says which library is missing and that `./install.sh` or `cs -update` redeploys the hooks, and skips the over-budget warning rather than guess a budget.

### Features
- A second key on the rotation band wraps the session. Where the band draws `1: rotate this conversation` it now draws `2: wrap up this session` beside it; the key runs `/wrap` (memory distillation, the session summary, the narrative rotation). Since a wrap replaces `.cs/summary.md` and runs two Opus passes before the narrative rotation, `2` only arms the key: for five seconds `3: yes, run /wrap` appears beside it, and `3` runs it (a different key, so a held `2` can never confirm itself; while armed `2` only restarts the window, and types nothing); a prompt, a `/clear` or a conversation switch meanwhile disarms it, and a run the engine refuses shows a toast. Once a handoff is armed the band draws the `/clear` key alone.
- One key rotates a conversation. `mods/cs-rotate/` is a Claude Code mod (function hooks, TypeScript inside Claude Code's process): once context reaches the status bar's warn band (`CS_STATUSLINE_CTX_WARN`, 40 by default; `CS_ROTATE_BUTTON_CTX` in the launching shell moves the band alone) the band above the prompt draws one rounded capsule, the Claude mark, `1: rotate this conversation` and a ten-cell context meter with the percentage, border and meter in the bar's own truecolor inks (amber past warn, red past crit, read from the same `CS_STATUSLINE_CTX_WARN` and `_CRIT` the bar reads, light or dark per `CS_TERM_THEME`), coral under the mouse pointer, and pressing `1` runs `/rotate`; the rotate skill takes the purpose from the conversation instead of asking. Once the handoff is armed the same key reads `1: /clear and continue from the handoff`, whatever the context, and runs the `/clear` that starts the next conversation; a marker naming a handoff the SessionStart hook would reject (consumed, gone, or not a bare basename) does not arm it. Without the force knob below, nothing else is sent or run on its own; the button hides while a turn runs, and only the lead conversation of a cs session gets one (a teammate claude or a plain conversation draws nothing). `cs -doctor` reports the mod by the heartbeat it writes at session start, not by its directory. `install.sh` deploys it beside the skills and every cs launch exports `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, the early-access flag Claude Code loads such plugins behind, for that session only; `CS_NO_FUNCTION_HOOKS=1` launches without it even when the shell carries it, a preset value such as `0` is kept, and `cs -uninstall` removes the mod. The deploy-drift check covers `mods/`. With `CS_ROTATE_FORCE_CTX=<percent>` in the launching shell the mod presses the button itself: a turn that ends with an answer at or past that percentage runs `/rotate` (once per conversation, recorded in `.cs/local/cs-rotate.forced` before the run so a failed one is not retried every turn; a subagent's, an interrupted or an errored turn starts nothing), and once the handoff is armed the capsule adds `/clear in 20s`, counts down once a second, and at zero runs the `/clear` where the button would draw (band idle, handoff still armed, still the lead). Pressing `1` clears at once; a prompt entering the session, or a `/clear` from anywhere else, stops the count, and the next turn's end restarts it. Off unless set. A conversation born of a `/clear` that already sits past the threshold when its first turn ends is never forced (a toast says so once), so a threshold below a fresh conversation's own footprint cannot rotate it in a loop; one met at launch or through `/resume` is forced as asked. The mod's handoff check now follows the SessionStart hook's rule exactly: unclosed frontmatter does not arm.
- The hint line under the prompt says what a session is waiting on. `mods/cs-hint/` is a second Claude Code mod, deployed, enabled and reported like cs-rotate (installer, the function-hooks flag, its own heartbeat at `.cs/local/cs-hint.heartbeat` for `cs -doctor`, removed by `cs -uninstall`). In the lead conversation of a cs session, while the composer is empty and idle, one dim line under the prompt (beneath the permission-mode notice, which stays) says, in priority order and at most two at once: unread mail (`2 messages from <session> · cs -msg`, the `.json` files under `.cs/local/mail/new/`, the sender with the latest timestamp), an armed handoff (`handoff armed · /clear continues it`, by the SessionStart hook's own rule, so it shows below cs-rotate's context threshold too), queued tasks with the gate's state (`3 queued · gate waiting`, `deferred` inside the hook's ten-minute cooldown, `draining` while a drain runs, the bare count under a state word the hook does not act on; an empty queue says nothing), and the purpose of the handoff this conversation continues (`continuing: <purpose>`, until your first prompt, recorded in `.cs/local/cs-hint.spoken` so a reload does not bring it back; the rotation's own wake does not end it). With nothing waiting it shows one tip from a fixed list of cs surfaces: the first fits the session (`/finish` in a worktree session, `/feature` elsewhere), the rest step once per finished turn of the conversation and never on a timer. Once drawn the line refreshes every five seconds, since mail, the queue and the marker change from outside the process. While you type, while a turn runs, in a teammate claude, outside a cs session, with `CS_NO_HINTS=1` in the launching shell or `hints: off` in `.cs/local/state`, nothing is drawn. The doctor row for a mod is one function now, run once per mod.
- A session can start a feature itself. The `feature` skill (`/feature fix-auth`) writes a brief from the conversation, with the goal, what done looks like, the constraints the new session cannot otherwise know and how to report back, and spawns `<base>@fix-auth` as a parallel worktree session in the cs tmux session. The new session reads the brief at `.cs/brief.md` before its first turn; the result comes back as `cs -msg` mail, and `/finish fix-auth` lands it. Underneath, `cs -spawn` takes `--brief <file>`: cs stages the brief beside the seed, moves it into the session at launch, sets it aside with a stale seed, deletes it with the session on `cs -rm`, and `cs -doctor` counts a stale one. The spawn keeps its permission prompt.

### Fixes
- The status bar keeps the branch from a subdirectory of the checkout. The workspace directory Claude Code reports follows the Bash tool's working directory, and the git segment looked for `.git` in that directory alone, so a `cd` into a subdirectory blanked the branch capsule until the next command left it. The segment now climbs to the nearest directory holding a `.git` (a directory, or the file a worktree keeps), in-process, and caches under that checkout, so every subdirectory shares its entry.
- A slow machine loses the scope block, not the digests. The UserPromptSubmit hook (`scope-prompt.sh`) used to be killed whole when its 3 s registration ran out under load, and the queue digest, the mail digest, the date note and the clarify guideline died with the scan that overran. The hook now checks its own clock once, after the classifier and before the scan stages: past `CS_SCOPE_BUDGET_MS` (1500 ms by default) it skips the scan, puts `Scope: skipped, slow machine (...)` where the block would go, writes a `skip` stage to the trace and delivers the rest, which a run killed inside the scan never could. The registration is 5 s now, the backstop for a scan that is itself slow. The digest cursor and the date stamp are spent only by an emission that was written, on every exit path.
- The status line renders under load. Its cost is its fork count, and a lead Fable render forked fourteen external commands (three `jq`, two `tmux`, `ps` and `awk` for the tmux ancestry walk, `find` for the terminal-theme cache's age, two `mkdir`, two `mv`, `git status` under `timeout`, `date`); at load 25 a fork costs 0.3 s, so the render ran past the limit Claude Code gives a status line and the tick was killed — an open session kept its last line, a new one never landed a first and showed nothing. A warm render now forks two: the interpreter and the `jq` pass over stdin. The tmux client is asked once for its theme and tty; the terminal-theme entry carries its write epoch so its age is arithmetic; the tmux ancestry verdict (five minutes, keyed on the parent pid and the `TMUX` claim), the client's answer (five seconds), the git line (five seconds) and the account id (five minutes) are kept under `~/.cache/cs`, each entry carrying the value it was made from so two paths that sanitise alike never answer for each other, and taken only when complete; a wrapper that runs the script in Claude Code's place names its own parent in `CS_STATUSLINE_PARENT` so the parent-keyed caches still hit; the refresher writes the Fable usage record's fields beside it in a line file with the reset already an epoch, and always reads the account id itself; the `context-pct` and `limits` stamps are rewritten at once when the value changes and once a minute otherwise, within what their readers allow; `mkdir` runs only when the directory is missing. The line drawn is the same; a branch switch or a theme toggle shows within five seconds, an account swap within five minutes. A bash without a builtin clock (macOS's stock 3.2) forks one `date` besides. `~/.cache/cs/term/` entries written by an older cs lack the epoch and are refused until the next launch rewrites them.
- Teammate panes render the status bar in truecolor. A pane claude splits off for an agent-team teammate starts with the tmux session's environment, not the lead's, so the `CLAUDE_CODE_TMUX_TRUECOLOR` override cs exports at launch never reached it and its bar fell back to the muted 256-colour palette. A launch inside tmux now publishes the value into that tmux session as well, so panes opened from it inherit it, and publishes a value you set yourself as given.
- A stale Bash-tool child no longer blocks a relaunch. The live-duplicate guard refused `cs <name>` when any process on the machine carried the session's UUID in its argv, and a command Claude runs through the Bash tool carries it in the shell snapshot it starts from (a plugin exports it there), so a probe left running in the background, orphaned after the conversation closed, reported the session as already running elsewhere while `cs -live` showed nothing. The guard now counts the UUID only after a flag claude takes it with (`--session-id`, `--resume`, `-r`, and `--parent-session-id`, the flag a teammate carries, so one that outlived its lead still holds the session); the `--name` test stays as it was.
- `/finish` no longer re-runs the gate on a merged PR whose landing commit's checks passed. `prepare` reads the check runs and commit statuses origin recorded on the PR's merge commit itself, not on the PR head (a merge commit that took newer base changes is a tree the head's checks never ran on), and reports them as one word (`pr_checks: success|failure|pending|none|unknown`, a `startup_failure` counting as failure and a failed `gh` call as unknown with its reason); the skill passes `--ci-green` to the integrate entry only on `success`, and with that flag, when the base has nothing origin lacks so the temp merge is a fast-forward onto that commit, cs skips the gate and the report says `gate skipped`. Without the flag, or with a base that carries its own commits, the gate runs as before. A red gate also says what the temp is: a clean checkout of the merged commit, without the project's gitignored dependencies, `.env` or build output, so a gate that needs them must create them first (`-- sh -c 'npm ci && npm test'`), and the skill asks once about that install step when a project has a lockfile or `.env.example` and no instructions.
- A narrative always fits one Read call. The Read tool refuses a file over 256 KiB, and the narrative budget was 512 KiB with a 256 KiB tail, so a notebook between the two was unreadable in full while nothing warned, and the first append after a rotation crossed the ceiling again. The budget is 224 KiB and the kept tail 112 KiB (`CS_NARRATIVE_MAX_BYTES`, `CS_NARRATIVE_KEEP_BYTES`), and every conversation start now warns about any narrative over budget, naming the file and its size: for the actor's own it says run `cs -narrative rotate` before the full read, for a teammate's it says read only from the line the digest names. Rotation stays the manual verb; nothing commits on its own. A budget override with a leading zero (`CS_NARRATIVE_MAX_BYTES=08`) no longer aborts `cs -doctor`, the Stop hook or SessionStart: every validator reads it as decimal.
- A spawn whose brief destination is a directory stops before delivering. `mv` would have put the brief inside `<session>/.cs/brief.md/` and reported success, the launch would have consumed the seed and told Claude to read a directory; now the launch stops with the seed and brief still staged, naming the directory to remove.
- A best-effort write that fails no longer prints to the terminal. Fifty-one sites across the hooks and the library wrote `cmd > file 2>/dev/null`, and bash applies redirections left to right, so a target directory that was missing or read-only reported `No such file or directory` before stderr moved. Every one is now `{ cmd > file; } 2>/dev/null`, which silences the redirection itself. Only the last command of a pipeline is braced, so no earlier stage is newly silenced; a command substitution inside the braced command is, which reaches the `$(date)` in the timeline appends and nothing else.
- Every conversation start re-asserts the session's tab title. cs set `cs: <name>` once at launch and its reset never ran, because cs execs into claude; a second session launched on the same terminal (`cs other` from Claude Code's `!` prefix) left `cs: other` on the first session's tab for good. The SessionStart hook now sets the title again on startup, resume, `/clear` and compaction: through the tmux server inside tmux, and as the title escape to the terminal device outside it; a front end with no terminal skips it.

## 2026.9.15

### Features
- The context gauge's icon is a pie that fills as context does: `○` below 13%, `◔` up to the warn threshold, `◑` through the amber band, `◕` at crit, `●` from 88%. The steps sit on `CS_STATUSLINE_CTX_WARN` and `_CRIT`, so the shape changes where the ink does. Agent rows in the subagent panel carry the same pie. The weekly icon moves to `◶` so a hot week beside a mid context is not two half pies.
- The rounded capsule caps are drawn only once a machine has said its font has them. They are the bar's one private-use glyph, and a font without them showed a box at every capsule edge. The installer shows a sample capsule and asks once whether its ends look rounded, recording the answer in `~/.config/cs/statusline-caps`; until then the capsules have square ends. `cs -statusline caps on|off|ask` rewrites the answer, `cs -doctor` reports it, and `CS_STATUSLINE_CAPS=1`/`0` overrides.
- The 5-hour rate limit is always on the bar. The weekly window joins it at 50% instead of 70%, in one quota capsule after a vertical ellipsis; on a Fable session the model window gets its own capsule from 50%. The order is fixed, 5h then wk then fable, so capsules never swap places. Reveal and colour are separate: every window is neutral below 70, amber from 70, red from 90, and one hot window inverts the shared capsule whole. The reset countdown still joins 5h at 70 and the coarse windows at 80.
- The effort word after the model name takes Claude Code's own `/effort` colours: low gold, medium green, high blue, xhigh violet, max a blue-to-pink gradient across its letters. Regular weight; lifted toward white on a dark terminal.

### Docs
- The README opens with an animated terminal banner: the cs launch card, Claude's prompt and the capsule bar, hand-written SVG animation with no external resources.

## 2026.9.14

### Features
- `/finish <feature>` lands a feature worktree and retires it. It captures the feature commit, merges base and feature in a temporary detached worktree under the repo's git directory, runs the repo's gates there, and fast-forwards the base onto the result: a red gate, a conflict, or a base that moved during the gates leaves the base exactly as it was. It reports GitHub PR state for the branch (none, open, merged, closed, or unknown with the reason; a `gh` failure is never read as "no PR") and lands a merged PR by its merge commit, so local integrates and remote PRs mix freely. Then it retires the worktree: fuses its session records into the base, removes the worktree and deletes the branch, through a hidden `-retire-feature` entry that never merges and refuses over an open conversation, uncommitted work, or a branch the base lacks. A directory cannot be removed from under a running Claude, so while the feature conversation is still open `/finish` lands the work and says so in plain words: close that session yourself, then run `/finish <feature>` again. A squash-merged PR retires on GitHub's evidence. `cs <base> --merge <feature>` is gone, with no alias: its merge half was ungated and merged a squash-landed branch a second time. Abandoning a feature stays `cs -rm <base>@<feature>`.
- The status bar is one line of rounded capsules on the terminal's own background. Identity (the Claude mark, session, branch, model) shares one neutral capsule in plain bold ink; the context gauge has its own; rate-limit capsules appear only when a window reaches 70%, the two hottest at most, highest first, with Fable's model-scoped window folded into the same rule. Colour is state: bold amber ink on a number past its warn threshold, a red capsule at crit with white text that pulses to pink each second. The default `CS_STATUSLINE_SEGMENTS` is `logo,session,notes,mail,git,model,ctx,limits`; `pane` (now `◫ 7`, without the `%`) and `fable` still render when named. `CS_STATUSLINE_CAPS=0` draws square ends for a font without the Powerline cap glyphs.
- The context gauge reads in three states instead of four: neutral below 40%, amber from 40% to 64%, red from 65%. The rotation nudge moves to 65% so its reading and the colour that asks for it agree.
- `cs -doctor` names a stale integrate lock left behind by an interrupted `/finish`, with the command that removes it.

### Changed
- `/merge` is retired; `/finish` replaces it. `cs <base> -finish <feature>` and the TUI's Enter on the readiness screen arm `/finish`, which lands and then retires the worktree. The TUI's ON FINISH plan describes the new shape.
- Amber is an ink, never a fill: `180;83;9` on a light terminal, `253;230;138` on a dark one, chosen by the measured background's brightness at the same point primary ink flips to white, and by the theme flag only when nothing was measured. The agent-panel rows' hot colours move with the bar: the same amber, crit `215;0;21` / `255;69;58`.
- The session name, branch and model paint in plain ink; the session colour stays on the terminal tab and `/color`. Capsules carry no inner padding and sit one cell apart.

### Removed
- `CS_STATUSLINE_CTX_NOTICE`, with the yellow notice band it configured.
- The status bar's full-width tail (gradient, coverage wash and dots). The line ends at the last capsule.
- `cs <base> --merge <feature>` and the `/merge` skill.

### Fixes
- The autosave hook labels each snapshot with the HEAD it started from, read before the tree is written. A HEAD that moved mid-snapshot was labelled onto the old tree, which is the exact case the label exists to expose at crash recovery. The hook also skips (never waits) while an integrate holds the repo's integrate mutex, and holds that mutex itself for the tree write.

## 2026.9.13

### Features
- The narrative reminder carries a commit cadence. In a session whose `.cs/` is tracked, appends were landing one commit each — 328 such commits in one repo, 74 in a single day, over half that day's history. The reminder now asks for them batched at a handoff or wrap, and says outright that uncommitted appends are safe because the autosave shadow ref already holds every edit. It rides the reminder rather than the session protocol because the protocol is read once at startup and is stale by the time a commit happens, while the reminder fires at the append itself — and because the reason string is rebuilt every run, every existing session picks it up on upgrade with no migration.
- `/sweep` keeps the memory index under its load budget. `MEMORY.md` loads in full at every session start against a hard size limit, and nothing checked it, so the index grew until it silently truncated and the entries past the cut stopped being read. The pass now checks the size after writing any pointer and names every over-long one, printing length with text so the long ones can be found. It rewrites rather than truncates: a mechanical 200-character cut had turned "push the release commit, tag only after CI is green" into "push the release commit", and left a consent rule as a dangling list of examples — both of which pass every shape check. Entries and pointers are never deleted or merged to save space.

### Changed
- The Stop hook's second-opinion note names whichever review channels you have, not the council alone. With the codex plugin present it offers `/codex:review` before Claude calls built work done and names `/codex:rescue` for a stalled run. With both plugins it still emits one note against one cooldown stamp. The note offers `/codex:review` and never runs it: that command carries `disable-model-invocation`, so only you can type it.

### Removed
- The migration phase that stripped the retired external-delegation block from `CLAUDE.local.md`. It removed the block through to the next cs sentinel or end of file, and because that block was always appended last there was never a following sentinel — so anything you had written below it was deleted, silently, while the phase reported a clean removal. No release ever wrote the block and no session carried it, so the phase only ever risked loss without doing work.

### Fixes
- The `CLAUDE.local.md` migration strip is judged by awk's exit status rather than by the size of what it wrote, keeps a following sentinel intact, and recognises a CRLF checkout.

## 2026.9.12

### Features
- The context gauge reads in four states instead of three. Below 40% it stays neutral, from 40% it turns yellow, from 50% amber, and from 70% red — the reading at which cs asks for a rotation, so the colour and the instruction now agree. `CS_STATUSLINE_CTX_NOTICE` sets the new band; `CS_STATUSLINE_CTX_WARN` and `CS_STATUSLINE_CTX_CRIT` keep their meaning.
- The wind-down tiers move earlier. The one-time heads-up arrives at 40% context and the rotation nudge at 70%, so a conversation is offered a stopping point while it still has room to write a handoff. Both stay tunable through `CS_CTX_WARN_CTX` and `CS_ROTATE_NUDGE_CTX`.
- `cs -usage` counts oversized Read results per session and shows what they cost.

### Fixes
- The context warning named a threshold it no longer had, telling a conversation the nudge would follow at 80% when it now follows at 70%.
- Agent-panel rows turned red at a different reading than the bar, so an agent at 75% context read amber in the panel and red in the bar.
- The reads column counted only one of the two shapes a Read result arrives in, missing 36% of large reads corpus-wide and 76% of those inside subagent transcripts.
- The reads column called a read targeted whenever it was truncated, so a read the model never sliced counted as deliberate; targeting now comes from the call itself.
- One malformed transcript entry ended the usage scan for every file after it, silently.
- A non-numeric threshold override disabled the gauge's notice band instead of falling back to its default.

## 2026.9.11

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
