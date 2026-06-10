# Changelog

All notable changes to cs are documented here. Release notes are also available on [GitHub Releases](https://github.com/hex/claude-sessions/releases).

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
