# oh-my-claudecode: source analysis and borrowable patterns for cs

Date: 2026-06-10
Source: https://github.com/Yeachan-Heo/oh-my-claudecode (shallow clone read at `/tmp/oh-my-claudecode`, ephemeral)
Method: six-agent workflow; five readers over OMC subsystems (architecture, MCP tools, skills/commands, hooks/HUD, agents) plus one capability inventory of cs. Roughly 770K tokens of source read, distilled to structured findings.

## 1. What OMC is

A TypeScript multi-agent orchestration plugin for Claude Code: autonomous keep-working loops (ralph, autopilot, ultrawork), magic-keyword activation, agent teams with git-worktree isolation, a statusline HUD, chat-platform notifications with reply injection, and an MCP server exposing tiered memory, state, wiki, and trace tools. Distributed three ways at once: marketplace plugin, npm global package, and local checkout. All runtime entry points are esbuild bundles committed to git under `bridge/` (3.3MB `cli.cjs`) because the plugin cache has no build toolchain.

Where the code mass lives (hand-written `src/`, lines):

| Package | LOC | What it is |
|---|---|---|
| `src/hooks/` | ~78K | keyword detection, persistent-mode Stop loops, context guards |
| `src/__tests__/` | ~57K | test suite |
| `src/team/` | ~41K | file-based worker coordination, worktree merging |
| `src/cli/` | ~17K | the `omc` CLI |
| `src/tools/` | ~16K | MCP tools (notepad, state, wiki, session_search) |
| `src/notifications/` | ~15K | Discord/Telegram/Slack dispatch + reply daemon |
| `src/hud/` | ~11K | statusline element pipeline |
| `src/installer/` | ~8.5K | setup, managed CLAUDE.md blocks |

The ~40 skills are rigidly structured prompt documents (Purpose / Use_When / Execution_Policy / Steps / Escalation / Final_Checklist); the 28 commands are mostly 600-byte aliases that say "read skills/X/SKILL.md and follow it". The real machinery is hook-driven, communicating through JSON state files under `.omc/state/sessions/{sessionId}/`.

## 2. The philosophy finding

A measurable fraction of OMC exists purely to keep Node alive inside Claude Code's hook environment: `run.cjs` (fail-open wrapper that scans sibling plugin-cache version directories when an update deletes the live `CLAUDE_PLUGIN_ROOT`), `find-node.sh` (interpreter discovery for non-interactive shells), `repair-plugin-cache.mjs` (symlinks old cache paths to new ones), a post-install `npm install --omit=dev` inside the plugin cache, and committed megabyte bundles. None of these problems exist for cs's bash hooks. OMC is the strongest independent validation of the no-runtime choice available: both tools converged on the same substrate (plain markdown/JSON/JSONL under a dot-directory, hooks as the integration surface, version stamps, drift checks), and the one that brought a runtime spent tens of thousands of lines defending it.

The borrowable ideas below all live in the substrate (file formats, hook events, retention policies, prompt text), which is why they port to bash at all.

## 3. Build candidates, ranked

### 3.1 Transcript search in `cs -search`

The biggest capability gap. OMC's `session_search` (src/tools/) proves cross-session conversation recall needs no index and no embeddings: it streams Claude Code's own transcripts from `~/.claude/projects/<encoded-cwd>/*.jsonl`, sorted by mtime newest-first, extracts text/thinking/tool string leaves per line, substring-matches case-insensitively, and early-exits at a result limit. Filters parse `since: 7d` / `24h` durations. cs's `-search` today greps discoveries/README/memory, meaning it finds only what someone remembered to write down, never the conversations themselves. cs already records `claude_session_id` per session, so it can map session to transcript exactly instead of guessing by path encoding. Implementation: rg/jq over the transcript dirs of each session's recorded UUID, mtime-sorted, capped. An afternoon.

### 3.2 PreCompact hook

cs's `/checkpoint` exists but requires Claude to think of invoking it. OMC registers PreCompact hooks that flush durable state to disk at exactly the moment context becomes lossy, and re-injects critical directives as a system message so they survive compaction. For cs: a ~15-line PreCompact bash hook that appends a checkpoint event to `.cs/timeline.jsonl` and injects "update .cs/discoveries.md and the README outcome now; context is about to be compacted". This fits the documentation-discipline mission exactly: the lab notebook is most at risk precisely when compaction fires.

### 3.3 Priority memory tier with age-based expiry

OMC's notepad is one markdown file with three sections and three retention policies: Priority Context (hard-capped ~500 chars, regex-extracted and injected at every SessionStart), Working Memory (timestamped entries, deleted after 7 days; working notes rot, so delete rather than summarize), MANUAL (never pruned). cs's discoveries compaction is size-triggered only. The two missing axes, age-expiry and a tiny always-injected tier, are orthogonal to the size budget. `session-start.sh` already injects resume context, so a priority block read from `.cs/` is an extension of existing machinery, not new machinery.

### 3.4 Upgrade-over-existing-install E2E test

OMC's CI (`.github/workflows/upgrade-test.yml`) installs the previous published release into a clean environment, runs the current updater over it, then asserts the version changed AND the SessionStart hook is still wired and its script exists. cs tests fresh installs only, and the two ugliest recent bugs (zombie hooks firing for three days after retirement; `cs -uninstall` never stripping registrations because of path-spelling mismatch) are both upgrade-over-existing-state failures. Implementation: temp HOME, install the previous release tarball, run working-tree `install.sh` over it, run `cs -doctor`, assert clean. Slots straight into the `tests/test_install.sh` discipline.

### 3.5 Context-guard Stop hook

The hook-enforced version of cs's prose wrap-up cues: above ~75% context usage, block the stop once or twice with "run /wrap or /handoff now". The part worth copying verbatim is the safety triad that keeps a blocking Stop hook from becoming a trap: never block context-limit stops (would deadlock compaction), never block user aborts (match abort/cancel/interrupt stop reasons), and bound the block count with a TTL'd counter file that fails open on missing or malformed state. cs's `prose-lint.sh` already uses a 3-strike guard, so the idiom is in-house; this adds the context-percentage trigger.

### 3.6 Guarded ff-only sync ladder

OMC's self-update (`src/features/auto-update.ts`) refuses to touch a git clone unless every precondition passes, with a distinct skip message per condition: branch is actually main, `status --porcelain` is empty ("commit, stash, or clean it first"), `rev-list --left-right --count` shows no local commits ("manual reconciliation required"), and only then `merge --ff-only`. Worth a one-time audit of cs's `-sync` pull path against this checklist; pure git plumbing.

## 4. Prompt-text upgrades (no code, just better words)

### 4.1 Three-question quality gate for /sweep

OMC's learner/skillify skill enforces a gate before saving any lesson: "Could someone Google this in 5 minutes?" must be NO; "Is this specific to THIS codebase?" must be YES; "Did this take real debugging effort?" must be YES; plus an anti-pattern list (generic patterns, library usage, boilerplate). cs's /sweep already has a strict bar in spirit; this articulation is sharper and is pure prompt text. The expertise-vs-workflow split (updatable vs frozen sections) is also a useful distinction for memory entries.

### 4.2 Version markers inside managed CLAUDE.md blocks

OMC stamps `<!-- OMC:VERSION:x.y.z -->` inside its managed CLAUDE.md region and the doctor compares it against the installed version, reporting drift. cs stamps deployed hooks (`.version`) but not its managed markdown blocks (`cs:memory-note`, `cs:wrap-cues`). One line per block plus a grep in `cs -doctor` closes the "edited managed prose silently goes stale" gap.

### 4.3 The honest-handoff prose pattern

OMC's `/compact` command explicitly states that a plugin command cannot invoke native compaction, refuses to pretend otherwise, and prints exact handoff text for the user to act on ("must not claim that OMC triggers compaction itself"). The same honesty engineering applies anywhere cs prints model-facing instructions for things the shell cannot do itself; cs's ultragoal-equivalent surfaces (wrap-cues, doctor advice) already lean this way, and it is worth keeping as an explicit rule when writing new skill/command prose.

### 4.4 Doctor as a runbook skill

OMC ships diagnostics twice on purpose: deterministic code for scripting, and a SKILL.md runbook where each numbered check is a copy-pasteable one-liner followed by explicit Diagnosis rules (OK/WARN/CRITICAL) and a fix. cs's bash doctor detects; a thin `/cs-doctor` skill wrapping the same checks would let Claude repair interactively (re-run installer sections, clean legacy files) without duplicating logic.

## 5. Idiom and discipline borrows

- **SubagentStop advisory deliverable check**: verify a subagent's declared artifact exists with minimum content, warn via additionalContext, never block. Matches the recorded "subagent placeholder deliverable" pain point (which fired again during this very analysis: the discoveries-append agent did the work but returned a nonsense final message).
- **Fail-open hook contract audit**: every hook exits 0 on any internal failure; stdin reads are timeout-protected (`read -t`; OMC has issue numbers proving hooks hang on stdin on Linux/Windows); a `CS_SKIP_HOOKS` env escape hatch for debugging.
- **Background dispatch in hooks**: anything slow (git push, curl) goes `>/dev/null 2>&1 & disown`, with a `kill -0` PID guard plus timestamp throttle against process pileup.
- **Statusline fact**: Claude Code's statusline stdin already provides `context_window.used_percentage`, rate limits, and model as JSON. A ~30-line bash+jq statusline showing `session | ctx 62% | discoveries 48K/60K` would surface cs's own budgets with zero runtime.
- **Append-never-replace memory merges**: OMC's wiki merge unions tags, appends sources, keeps higher confidence, and appends content as timestamped sections, never replacing. Prevents an LLM from clobbering accumulated knowledge; a good convention for `.cs/memory/` updates.
- **Count-capped retention**: keep last N / top N by frequency, complementary to size budgets and age expiry. Three retention axes now known: size (cs has it), age, count.
- **rg-based architectural invariants in tests**: OMC runs an AST-grep CI gate banning raw state-path construction outside canonical resolvers, with a deliberately minimal whitelist ("broad whitelists make the gate cosmetic"). The bash equivalent: rg assertions in cs's test suite, e.g. no literal `$HOME/.claude-sessions` outside the path-resolution function, no secret writes outside the keychain helper.
- **Derived counts and --verify modes**: displayed agent/skill counts in OMC docs are computed by listing the filesystem, never hand-written, and every sync script has a `--verify` mode so the same code is both fixer and CI gate. cs's sync-test already points this direction; the increments are cheap.
- **Append-only JSONL with dual-cap rotation**: per-file size cap plus keep-newest-N rotation (OMC's trace logs). Cleaner than a single growing file for anything log-shaped cs grows later.

## 6. Cautionary tales

- **The `team` keyword incident**: bare-word "team" in any prompt activated team mode; spawned workers received prompts containing "team" and recursed into infinite spawning. The fix is a permanently disabled never-match regex (`/(?!x)x/`) plus explicit-slash-only activation. Rule: prompt-triggered automation that spawns agents must never trigger on bare words. Directly relevant to any future evolution of cs's scope-prompt or wrap-cue detection.
- **The cost of bare-word triggers generally**: ~700 of the keyword detector's ~1000 lines are false-positive defense (strip code fences, URLs, file paths, blockquotes, tables, git diffs, pasted transcript echoes; intent-window suppression for "what is ralph?"). Claude Code's native skill descriptions give trigger-by-intent for free; that is the YAGNI-correct mechanism and cs already uses it.
- **The cost of blocking Stop hooks**: persistent-mode is a 50KB bundled hook of iteration ledgers, session-isolation rules, staleness TTLs, cancel-signal files, and env-capped hard maxima. That is the safety scaffolding autonomous re-prompting drags in. Read before ever adding a blocking Stop hook to cs; the context-guard safety triad (3.5) is the minimal subset that makes one survivable.

## 7. Skipped by design

The orchestration empire: persistent-mode loops, the session-scoped mode registry, multilingual magic keywords, ralplan consensus gates, deep-interview ambiguity scoring, self-improve tournament evolution in worktrees, file-based worker teams with heartbeats and merge orchestration, the Discord/Telegram reply-injection daemon, and the HUD element pipeline. All of it serves autonomous multi-agent execution, a problem cs does not have. cs is session bookkeeping; OMC is an agent operating system. The convergence on file-based substrate is the interesting part, not the superstructure.

## Appendix: where to look in the source

- Tiered notepad: `src/tools/` notepad implementation, injection at `scripts/session-start.mjs`
- Transcript search: `src/tools/` session_search
- PreCompact: `hooks/hooks.json` PreCompact entries, `scripts/pre-compact.mjs`
- Context guard: `scripts/context-guard-stop.mjs`
- Upgrade test: `.github/workflows/upgrade-test.yml`
- ff-only ladder: `src/features/auto-update.ts`
- Learner quality gate: `skills/learner/` SKILL.md
- Managed-block version markers: `scripts/setup-claude-md.sh`, `skills/omc-doctor/SKILL.md`
- Keyword false-positive defense and the team incident: `src/hooks/keyword-detector/index.ts`
- Worker coordination vocabulary (sentinels, heartbeats, mkdir locks): `src/team/state-paths.ts`
