# Session Summary: claude-sessions

**Date:** 2026-09-23 afternoon to 2026-09-24 morning
**Duration:** one conversation (da093a8c), about 16:15 on 09-23 to about 13:00 on 09-24 Bucharest time, with the night in between. This summary covers that conversation only. The session has run since 2026-02-07; earlier days are in `.cs/README.md`'s outcome log, the narrative archive, and the previous summaries in git history.

## Objective

Nothing was planned in advance. Alex brought a chain of questions, and each one turned into the next:

1. The claude-council session asked, by cross-session message, whether its Codex "specialists" feature belonged in cs.
2. A screenshot of a `/wrap` run failing with "Exit code 1". Alex asked whether it should be fixed in cs.
3. "How big and detailed is a rotation handoff?" Then: "is it good? optimal? detailed enough? check with Fable and Opus", plus a council run, rerun once he had updated the OpenRouter seats.
4. After an ELI5 page, a yes to five spec edits. Then "run them both, and maybe we can test them, old vs new": two reviews and an A/B experiment.
5. "Why do we still have wrong answers?" That led to a sixth edit, then merge and install.

## Environment

The cs source checkout on Alex's MacBook, on main. The Bash tool runs zsh. Test suites run on ghost (`remote-tests.sh --host ghost@ghost`). The reviewers were Fable, Opus and Codex (through the codex plugin agent), and the council was nine seats. The A/B experiment ran the next-conversation agents as headless `claude -p --restricted` runs in a sandbox outside any repository.

## Key Discoveries

- **zsh reads `echo ======` as a command lookup.** A word starting with `=` asks zsh for a command of that name, and the failed lookup aborts the whole command list with exit 1. That was the `/wrap` failure: it printed `sweep.md` and never read `summary.md`. Reproduced with `zsh -c 'echo A; echo ======; echo B'`. I hit the same trap myself later in the conversation.
- **Handoffs work in practice.** Fable and Opus traced four real handoffs to the conversations that picked them up, using the `consumed_by:` field. All four followed Next Step, none asked Alex again for anything the handoff carried, and each was doing useful work within 1 to 4 minutes. Size is fine: the median handoff is 13 KB, the largest 21.7 KB.
- **The failures were wrong facts, not missing ones.** The 09-23 handoff said `--host ghost` "fails", which sent the next conversation to run the full suite locally until Alex asked about ghost@ghost. It also said SessionEnd on `/clear` reports source `clear`, when the session log shows `user_exit`. Provenance labels went on whole bullets, so an inferred cause could sit under "MEASURED". Across 40 handoffs, "measured" appears in 38 and "assumed" in one.
- **The rotate spec contradicted itself.** It said "pass two is where exact readings live" while the two-pass rule puts those facts in pass one. Three of the four writers checked had invented their own section for them.
- **The council would have added a size floor that measurement rules out.** Three of the four new OpenRouter seats wanted handoffs to be at least about 15 KB, reasoning only from the August experiment. Three of the four handoffs that demonstrably worked were under 15 KB.
- **A/B result: a small improvement, not a proven one.** Blind, Codex-graded, three handoffs per arm:

  | | Old spec | New spec |
  |---|---|---|
  | Correct answers | 12 | 13 |
  | Wrong answers | 1 | 2 |
  | One-off facts carried (of 18) | 5 | 8 |
  | Unsupported "fails" claims | 32 | 21 |

  - The clearest effect was the unverified label: all 3 new-spec agents correctly said nobody had seen the #664 countdown colours live, against 0 of 3 old-spec agents.
  - The rule I wrote down before launch, that the new spec must not produce more wrong answers than the old, failed at 2 vs 1. Both new-spec wrong answers came from one writer.
  - Which writer ran mattered as much as which spec it followed.
- **A transcript replay does not reproduce a live-context failure.** All six replay writers, old spec included, quoted the exact ghost error that the real 09-23 writer dropped. The real writer was working at about 80% context, while the replays read a clean text copy of the conversation.
- **Of the three wrong answers, only one points at a handoff defect.** A Next Step said "rerun the suite if its result has no `rc=` line", which risks a second full run beside one still going. The other two are a next-conversation agent shortening a correct error, and strict grading of a quote shortened with an ellipsis.
- **Specialists stay out of cs.** A feature worktree cannot be created without launching claude. Alex has dropped delegation from cs twice. The pattern worth borrowing is cs's integrate-in-temp, then `--ff-only` landing.

## Changes Made

- **`/wrap` fix**: `commands/wrap.md` reads each pass file with the Read tool, one call per file. Merged as fe5d1e4 and installed.
- **Rotate handoff spec** (`skills/rotate/SKILL.md`):
  - Each claim carries its own label, and a "fails" claim carries the command and what it printed.
  - A new section 3, "Conversation-only facts", goes in the first pass, with a check-off list before the first commit. The body now has 9 sections.
  - Next Step carries every fact its first action needs, and an action that starts work says how to tell whether it is already done or running.
  - A pointer to a script says in one clause what the script does.
- **Successor report**: `hooks/session-start.sh` tells the conversation that takes over to append `## Successor report` to the handoff once its next step is done. The prune step skips handoffs with uncommitted changes, and step 8 commits the report. Both reviewers had flagged that the report could otherwise be deleted before anyone committed it.
- **Docs**: `docs/hooks.md` describes the report, and `CHANGELOG.md` has a new `## Unreleased` section for all of this plus the `/wrap` fix.
- **Memory**: `project_bash_tool_is_zsh` gained the `=` trap. Three entries were extended at wrap: handoff fact carriage (replay vs live), subagent context leak (the `--restricted` isolation recipe), and full gate on ghost (review agents too). `MEMORY.md` was trimmed back to 24,400 bytes.

## Key Files & Outputs

- Commits on main: 108cbd8 and merge fe5d1e4 (the wrap fix); 8474134, 36920c4 and f77dc82, merged as ff77451 (the handoff spec work).
- `skills/rotate/SKILL.md`, `hooks/session-start.sh`, `tests/test_rotation.sh`, `docs/hooks.md`, `CHANGELOG.md`, `commands/wrap.md`.
- Council transcripts: `.claude/council-cache/council-1790237994.md` (nine seats) and `council-1790238632.md` (the four new OpenRouter seats).
- The ELI5 artifact for the five edits: https://claude.ai/artifact/M7zLBAJH1PFSuCxEKe8YbB.
- A/B material, in this conversation's scratchpad under `ab/`: `core.txt`, both specs, `PREREG.md`, `briefs.json`, six handoffs, `mapping.json`, `RESULTS.md`. The blind runs are in `/private/tmp/claude-501/ab-sbx/h1` through `h6`. All of it is scratch and will not survive a reboot.

## Outcome

Everything Alex asked for shipped locally. The wrap fix and the handoff spec work are merged to main and installed. On ghost, the rotation suite passed 112/112 at the branch tip and the full suite 68/68 on main. `cs -doctor` shows no deploy drift. Nothing was pushed or released; the `Unreleased` changelog section waits for the next release. The specialists answer went back to claude-council.

## Notes for Future Reference

- **The first real `/rotate` is the live check.** The handoff should fill section 3, label each claim, and the next conversation should append a `## Successor report`. Read that report the next time handoff quality comes up; it replaces digging through transcripts.
- **Open bug:** after the 09-23 `/clear`, the automatic wake never fired, and Alex typed "continue" 7 minutes later. Other rotations woke within 3 to 8 seconds. Not investigated.
- **Testing rules:**
  - A handoff-quality test has to reproduce the live writing conditions: a replay from a clean transcript produced better handoffs than the real one.
  - Tell reviewer agents in their brief not to run test suites locally; one Fable review did.
- **Council:** the Cursor seat is out of usage, and `xiaomi/mimo-v2.6` was an invalid OpenRouter model ID until Alex changed the seats. The four OpenRouter seats now sit on deepseek-pro-latest, glm-5.3-prime, mimo-v2.6-pro and qwen3.8-max-prime.
