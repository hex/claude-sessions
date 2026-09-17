---
parent: 0643d4f0-a682-4b71-8a0c-c5bb24791f09
created: 2026-09-17T07:46:10Z
purpose: fix the parallel-run test races — #603 (doctor's integrate-lock vs the finish suite), #609 (tui CS_BIN stub argv), #638 (two recurring ghost flakes) — in one branch
status: unconsumed
---

## 1. Next Step

Build the fix for the three test-race tasks in ONE branch, as Alex asked for
twice: **#603, #609 and #638**. His words, inherited from the previous
handoff and unchanged since: #603 and #609 "would go well in one branch", and
#638 (filed 2026-09-16) "belongs with them (same class: load-induced ghost
flakes)".

Start with **#609**, because it is the only one with fresh evidence, measured
in this conversation (see section 6). Then #603, then #638.

Nothing is in flight. Main is at `2ce9b0f`, clean apart from machine-local
`.cs/` files, **5 commits ahead of `origin/main`, unpushed and unreleased**
(the last release, v2026.9.16, is tagged on `89a6406`, which is behind those
5). Alex has NOT asked for a release; do not start one.

Standing gates for any branch here, all inherited and still true:

- Every `tests/test_*.sh` run goes to ghost, never the dev box:
  `ssh ghost@ghost 'rm -f ci/claude-sessions/suite.status' </dev/null` then
  `bash ~/.claude/plugins/cache/hex-plugins/claude-tmux/2026.9.1/scripts/remote-tests.sh --host ghost@ghost </dev/null`,
  polled from a background loop. The suite is 67. Ghost keeps ONE `suite.log`.
- Ghost runs bash 5.3 and CANNOT see a bash-3.2 defect (measured yesterday,
  section 6). For a 3.2-specific question use a `/bin/bash -u -c` probe or run
  the one suite with `PATH=/bin:/usr/bin:... /bin/bash tests/test_x.sh`.
- `./build.sh` last, before committing, whenever `lib/` changed.
- Alex gates the merge. Offer polish-first at that gate.

## 2. Settled and rejected

**Settled this conversation (the headless-discovery fix, now merged):**

- The rule for "is this transcript a conversation of this session" is: skip it
  when it opens with an `sdk-` entrypoint AND no later user line carries a
  different value. Both halves were forced by evidence:
  - The `sdk-` prefix alone came from the measurement (section 6).
  - The "no other kind anywhere" half came from finding one cs session
    (`hexul.com`) bound to a transcript an SDK run started and Alex then
    continued by hand — 802 `cli` lines after an `sdk-py` first line. A
    first-line-only rule would have hidden a conversation he works in.
- **Rejected: judging by the first user line alone.** See above. A mutation
  that removes the second read turns the adopted-run test red; that is the
  test's whole purpose.
- **Rejected: skipping a transcript with no `entrypoint` at all, or an unknown
  value.** A wrongly skipped conversation leaves a session resuming nothing,
  which is worse than a wrongly named one. Exception, added after review: an
  unknown value that itself begins `sdk-` is treated as headless.
- **Rejected: a `[^s"]|s[^d"]|…` negated-prefix regex.** Codex found it, and it
  was real: every alternative requires one more character before the closing
  quote, so the values the prefix swallows whole (`""`, `s`, `sd`, `sdk`) never
  match. **The general rule, worth keeping: a "does not start with P" regex
  needs an explicit alternative for every proper prefix of P ending at the
  delimiter.** Fixed by adding `|"|s"|sd"|sdk"`.
- **Not fixed, deliberately:** `hexul.com`'s binding to `0b7dd256`. It is a
  conversation Alex continued; rebinding it would be wrong.

**Rejected earlier, still load-bearing:** `.cs/handoffs/2026-09-16-release-v2026-9-16.md`
section 2 carries the wrap-key guard decisions and the git-segment reasoning.

## 3. Conversation-only facts

These exist nowhere else. Everything else here is recoverable from git, the
narrative, or memory.

- **MEASURED, the population behind the whole fix.** First user line of every
  transcript under `~/.claude/projects/`, 5522 files: `sdk-py` 3050,
  `sdk-cli` 1620, `cli` 842 (457 of those teammates), `claude-desktop` 6,
  no user line 4. Every headless entrypoint value seen begins `sdk-`.
- **MEASURED, the rule over the cs sessions' own project dirs (3146 files):**
  2467 headless SKIPPED, 391 teammates SKIPPED, 287 `cli` kept, 2 no-user-line
  kept, 1 opens-headless kept (the adopted `hexul.com` run). Zero wrong in
  either direction.
- **MEASURED, the cost Codex asked about:** the largest purely headless
  transcript on this machine is 4.4 MB and the second grep reads it to EOF in
  **61 ms**. That closed the "those are short" objection.
- **MEASURED, the bash-3.2 trap that cost a red CI lane on the release:**
  `echo "... has no $EPOCHREALTIME; ..."` inside double quotes under `set -u`
  is `unbound variable` on stock bash 3.2 and kills the suite. Ghost (bash 5.3)
  ran that suite green eight times without reaching the line. Fixed by escaping
  the dollar. **Reproduce a 3.2 question with `/bin/bash -u -c '<line>'`.**
- **MEASURED on this machine's Codex install, three separate failures in one
  review round, all new:**
  1. Pointing `codex exec` at a prior report file (`scratchpad/codex/out-*.md`)
     made it read that file and end its answer on the earlier report's text —
     including "the checkout has 2 commits over main" when the branch had 4.
     **Never reference a prior report file in a Codex prompt; inline the
     findings instead.**
  2. `ERROR: Selected model is at capacity` mid-run, twice, leaving a report
     with no verdict.
  3. `-m gpt-5.4` is refused: "not supported when using Codex with a ChatGPT
     account". The configured model is `gpt-6-astra` in `~/.codex/config.toml`;
     an override is not available on this account.
  A plain retry on the default model then succeeded. When Codex is unreliable,
  a Fable review agent with the same prompt is a working substitute — both
  returned MERGE here, independently.
- **MEASURED, #609's fresh evidence (this is the reason to start there).** The
  tui suite is unchanged since v2026.9.15 and rust CI is green on both
  platforms, but three consecutive full local `cargo test` runs each failed a
  DIFFERENT test, one per run:
  1. `archive_key_archives_the_selected_session` — the stub's argv file read
     `alpha\n-secrets\nlist\n-archive\nalpha\n-archive\nalpha\n` where the test
     expects `-archive\nalpha\n`. A secrets-list call and a SECOND archive call
     leaked into it.
  2. `a_preview_in_flight_when_rotate_runs_never_reaches_the_cache`
     (`tui/src/app.rs:5218`) — under `--test-threads=1`, so **serial execution
     does not cure it**.
  3. `archive_key_unarchives_a_row_that_is_already_archived`.
  Each passes alone, 3/3. The shape: a background preview or secrets thread
  outlives its test and writes to the NEXT test's `CS_BIN` stub after
  `CS_BIN_ENV_LOCK` (`tui/src/app.rs:2567`) has been released. The lock guards
  the env var, not the threads. The machine was loaded (two review agents) for
  runs 1 and 3.
- **`gh release create --target` needs a FULL sha**; a short one fails with
  `target_commitish is invalid`. Relevant only if a release comes up.
- **A stray `git checkout <sha> -- .` in this repo rewinds the tracked `.cs/`
  files and silently discards uncommitted narrative appends.** It happened once
  yesterday and cost a paragraph. Use `git commit -- <path>` for tracked `.cs/`
  files; a plain `git add` refuses them (the directory is gitignored).
- **Alex's exact words this conversation, in order:** `[screenshot of the
  iterm-agents-sidebar launch card]` *"what is this?"*; then *"yes we need to
  fix this"*; then, at the merge gate, he picked **"Wait for Codex round 2"**
  rather than merging on the Fable verdict alone — consistent with
  `feedback_hold_for_adversarial_review`. He merged once Codex returned MERGE.
- **Counts:** ghost ran twice today, 67/67 both times. Codex: one round-1
  review (FIX), three attempts at round 2 (two failed as above, the third
  MERGE). One Fable closure review (MERGE). Reports under `scratchpad/codex/`
  and `scratchpad/review/` — untracked, they go with the working tree.

## Completeness (pass one)

Written from live context at ~48%, no compaction. Pass one carries everything
that dies with the conversation. Pass two appends the recoverable sections.
