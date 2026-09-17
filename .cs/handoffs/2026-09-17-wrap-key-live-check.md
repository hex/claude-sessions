---
parent: 9915c942-9c0c-483e-98d9-f6bc79937607
created: 2026-09-17T17:59:23Z
purpose: measure live that the wrap key stays hidden after /wrap across a Stop-hook continuation, then pick up #640 (v2026.9.16 minors)
status: consumed
consumed_by: be426d62-7e0d-44ae-a03a-98d36f355787
---

## 1. Next Step

Measure live, in a real Claude Code 2.1.274 cs session, the one claim the
wrap-key change rests on that nothing has measured: **a Stop hook's blocking
feedback continues the turn as `turn.start` with `text === ""`**, so the
cs-rotate band keeps the wrap key hidden after a finished `/wrap`.

Everything is merged to main (`2d7b3aa`) and installed (`cs -version`
2026.9.17 build, `cs -doctor` deploy drift OK), not pushed, unreleased.

How to measure (suggested, not yet tried):
1. In a throwaway cs session with context past 40% (or
   `CS_ROTATE_BUTTON_CTX=1` in the launching shell so the band draws), run
   `/wrap`.
2. After it finishes, `cat .cs/local/wrapped` should hold the conversation's
   id, and the band should show `1: rotate this conversation` with **no**
   `2: wrap up this session`.
3. The narrative-reminder Stop hook fires after most turns in a cs session.
   Watch whether the key stays hidden through that feedback continuation.
   If it reappears with no prompt typed, the continuation is not
   `text: ""`. That failure is benign (the key comes back, the old
   behaviour), but then the design needs rethinking. Debug with
   `claude --debug` (see memory `project_prompthint_rewrite_draws_nothing`).
4. Type any prompt: the marker should empty (`.cs/local/wrapped` is `""`)
   and the key return.

Do not run test suites on this dev box beyond single files unless Alex okays
it. Ghost rejected the ssh key all day (below), and the full local runs
today happened with Alex's awareness.

Then: #640 (four Minors from the v2026.9.16 release review), pending.

## 2. Settled and rejected

- **Wrap key: summary.md mtime rule, REJECTED.** First design hid the key
  while `.cs/summary.md` mtime > the last `prompt.submit` time. Codex (medium,
  reproduced against the render hook with engine fixtures) showed a
  standalone `/summary` writes the same file and hid the key. A teammate
  write, a future-dated or lagging mtime and a reload also misclassified. A
  file's timestamp is not a record that an action finished.
- **Marker from state's `claude_session_id`, REJECTED.** Pass 4 first copied
  the lead id out of `.cs/local/state` with awk. Codex: a teammate's `/wrap`
  then marks the LEAD finished and hides the lead's key. Replaced by
  `$CLAUDE_CODE_SESSION_ID` (measured below).
- **`prompt.submit` + `turnId` inference (`promptSinceWrap`), REJECTED.**
  Codex closure pass 2 reproduced two failures. (a) A failed second wrap
  re-hid the key from the FIRST wrap's marker, because `command.run{wrap}`
  cleared the flag, not the marker. (b) `turnId` is also set on peer/plugin
  deliveries and on mid-turn requests already consumed, so a Skill-run wrap
  after a mid-turn request stayed visible. Three rounds of inferring "was
  there work after the wrap" from prompt events each leaked.
- **Kept: `turn.start` boundary.** Contract (read in
  `~/.claude/plugins/marketplaces/claude-code-plugins/mods/types/claude-code.d.ts`,
  `TurnStartInput`): `text` is `""` "for a turn started without a typed
  prompt, e.g. a continuation". A `turn.start` with non-empty text empties a
  marker naming this conversation.
- **#652 minor 2 was a class, fixed everywhere.** Fable flagged two bun-absent
  `return 0` sites; the sweep found 27 SKIP-then-pass sites in 14 suites. All
  now `return 77`, with a guard in `tests/test_docs.sh`. Alex's standing
  preference is fix-everywhere (memory
  `feedback_eradicate_shared_failure_class`).
- **Dead non-tmux arm in `_sl_theme_from_client_cache`: left in place**, only
  its comment fixed. `tty` is always empty under Claude Code's piped stdin
  (reproduced: `printf '{}' | bash -c tty` → `not a tty`, rc=1). Removal was
  not asked for.
- **Rotation timing:** at 65% context Alex chose "Finish here first" (merge
  the branch, then rotate).

## 3. Conversation-only facts

- **`CLAUDE_CODE_SESSION_ID` is the live conversation id (measured).** In
  this conversation's Bash tool, compared without printing:
  `CLAUDE_CODE_SESSION_ID == state's claude_session_id == 9915c942…` (this
  conversation, itself born of a `/clear` rotation).
  `CS_CLAUDE_SESSION_ID != state lead`, so it is stale, as memory
  `project_cs_claude_session_id_is_launch_id` says. `CLAUDE_SESSION_ID` is
  unset. Probe run by name only via `${!n:+set}` in a bash script; never
  dump the env.
- **Ghost unreachable all day:** `ssh ghost` → `Permission denied
  (publickey,password,keyboard-interactive)`. `remote-tests.sh` has no host
  store (`remote-hosts.json` missing). Full gates ran locally and in CI
  instead, named to Alex each time.
- **Full local runs today:** 67/67 before the release (v2026.9.17), 66/67 on
  the branch (the one red was a stale `claude plugin validate` inventory pin,
  not a regression), then 67/67 on `2d7b3aa`'s predecessor with the three
  touched suites (`test_mod_rotate` 6/6, `test_docs` 6/6, `test_commands`
  47/47) rerun after the final edit. Shellcheck lane clean each time.
- **Codex review counts, this branch:** round 1 (`needs-attention`, 1 medium:
  mtime) → marker; closure 1 (2 mediums: queued prompt, teammate) → own id +
  turnId; closure 2 (2 mediums: failed second wrap, consumed mid-turn/peer
  turnId) → `turn.start`. No Codex pass has run on the final `turn.start`
  version; Alex chose merge over a third closure pass.
- **Codex measurements worth keeping:** the state awk line gave correct
  UUIDs from all 58 state files on this machine. The skip guard fired once
  across tests (its own regex in `test_docs.sh`, which is excluded from the
  scanned set) with 0 real misses, and caught all 3 canaries.
- **`/codex:adversarial-review` on a dirty tree spends the run asking a scope
  question**, which the companion reports as a JSON parse error. Pin scope
  in the focus text. Recorded in memory `project_codex_readonly_no_probes`.
- **Shell trap:** a zsh-tool chain `sed -i '' … && (cd … && bun test | grep)`
  reported a mutation count, then left the file unmutated (a green run would
  have been vacuous). Use `perl -0pi` and show `git diff --numstat` before
  running tests.
- **Release v2026.9.17 shipped earlier this conversation:** GitHub release
  on `4a44aff`, CI 6/6 (run 35242297100), 12 signed assets, Codex + Fable
  SHIP. Details are in `.cs/summary.md` and the narrative; task #651.
- **`/wrap` ran twice this conversation.** The second came from the band's
  `2` dialog right after the first. That duplicate is what Alex asked about
  ("why du still have to conform the wrap?") and what started this branch.

## Completeness (pass one)

Written from live context at ~75%, no compaction. Pass two appends the
recoverable sections.

## 4. Primary Request and Intent

The conversation started from `.cs/handoffs/2026-09-17-release-2026-9-17.md`
to run `/release`. Alex's decisions at the gates: push 66 commits ("Push
now"), approve notes ("Approve"), hold the tag for Fable ("Hold for Fable
review"), then "Run /wrap".

After the wrap Alex asked "why du still have to conform the wrap?". I
explained the two sources (my wrap-cue question, then the band's `2` dialog)
and offered to file the band gap beside #652. Alex answered **"do them both
now"**: #652's five minors plus the wrap-key fix. At the merge gate he picked
"Codex review first", later "Finish here first" at the 65% nudge, and finally
"Merge + install, then rotate".

## 5. Key Technical Concepts

- cs-rotate is a Claude Code function-hooks mod (TypeScript in the engine).
  Its unit tests use a fake engine (`mods/cs-rotate/test/register.test.ts`);
  only `claude plugin validate` computes the real hook/call inventory, which
  `tests/test_mod_rotate.sh` pins by string.
- `run_test` (`tests/test_lib.sh`) counts status 77 as skipped. Any other 0
  is a pass, so a SKIP that returns 0 is a silent pass.
- `$.fs` has no delete: the mod "clears" the marker by writing `''`.
- The band draws only for the lead conversation (`ownsRotation` compares
  `$.session.id()` with state's `claude_session_id`).

## 6. Files and Code Sections

On main, `git log --oneline 4a44aff..2d7b3aa` (release onward):
- `mods/cs-rotate/hooks/register.tsx`: `WRAPPED = '.cs/local/wrapped'`;
  `on('turn.start')` → `if (e.text !== '') await clearWrapped($)`;
  `wrapFinished` (marker === session id) gates the `2` key; `openPreview`
  closes a pane that lands after its count ended.
- `commands/wrap.md`: `## Pass 4 — Mark the wrap finished` runs
  `[ -z "$CLAUDE_CODE_SESSION_ID" ] || printf '%s\n' "$CLAUDE_CODE_SESSION_ID" > .cs/local/wrapped`.
  `tests/test_commands.sh` `test_wrap_marks_the_wrapped_conversation` runs
  that exact block with and without the var.
- `tests/test_docs.sh`: `_skips_that_pass` + `test_no_skip_counts_as_a_pass`.
- `tests/test_lib.sh`: `report_results` prints `, N skipped` only when N > 0
  (tests in `tests/test_harness.sh`).
- `tests/test_statusline.sh`: prune test covers `tty/`.
- `bin/cs-statusline`: `_sl_own_tty` comment.
- Docs: `docs/hooks.md`, `docs/session-layout.md` (`wrapped` row), README,
  CHANGELOG `## Unreleased`.

## 7. Pending Tasks

Native list (session-keyed, inherited):
- **#640 pending**: v2026.9.16 release-review Minors (four).
- **#554 pending (PARKED)**, **#606 pending (POSTPONED)**.
- #651 (release 2026.9.17) and #652 (minors + wrap key) completed.
- Not in the list: the live measurement in Next Step.

## 8. Current Work

Branch `fix/release-minors-wrap-key` fast-forwarded into main at `2d7b3aa`
and deleted. `./build.sh`, `./install.sh` exit 0, installed `cs` byte-matches
`bin/cs`, `wrap.md` and the mod byte-match their deployed copies, doctor
drift OK. Main is ahead of origin by the post-release commits: nothing pushed
since the v2026.9.17 release. Summary `.cs/summary.md` was written at the
earlier wrap and does not cover this branch; the narrative does.

## Completeness (pass two)

Nothing cut.
