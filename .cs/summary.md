# Session Summary: claude-sessions

**Date:** 2026-09-24 about 12:30 to 2026-09-25 about 00:30, Bucharest time
**Duration:** three conversations, each started by a rotation: 8692f800 (rotation wake fix), bbc43868 (eval harness, mod rename, `/queue`) and 4af1b056 (the eval loop). This summary covers those three. The session has run since 2026-02-07. The previous summary (conversation da093a8c, up to about 13:00 on 09-24) is in git history, and older days are in `.cs/README.md` and the narrative archive.

## Objective

The day continued one question from the morning: are rotation handoffs good, and can a spec change make them measurably better? Two fixes and one feature were shipped along the way:

1. Find out why one rotation on 09-23 never woke its successor, and fix it.
2. After a small A/B, Alex said "the results are not that great though. no? let's rotate then use /autoresearch:autoresearch until we have the best results". That became a proper eval harness and a loop over rewrites of the rotate skill's handoff rules.
3. Side requests: rename the in-session mod from `cs-rotate` to `cs`, and add `/queue` so tasks can be queued while Claude is busy.

## Environment

- Repo: the cs dev checkout at `~/.claude-sessions/claude-sessions`, main branch, Claude Code 2.1.281.
- Full test gates run on the `ghost` host through `remote-tests.sh`, always from the real checkout: a worktree's `.git` file points at a Mac path and breaks git-using suites there.
- Eval harness: `.cs/research/handoff-eval/` (gitignored, this machine only). Answer keys, held-out source and run outputs live in `~/.cache/handoff-eval/`, out of the loop conversation's reach. All model calls are `claude -p` on the subscription, not the API.

## Key Discoveries

- **Why the 09-23 wake was missed.** The rotation kick wrote its wake file at +2 s and +4 s after spawn, but Claude Code only watches for it once the SessionStart hook returns. Under a parallel test suite that hook took 21 s, so both writes landed before the watch existed. A live A/B from fresh launches reproduced it: the old code woke 0 of 2, the fix 2 of 2. The watch set up by an earlier rotation survives `/clear`, so only the first rotation after a startup or resume is exposed.
- **Why the current handoff spec needed an eval, not an opinion.** Round 0 put the spec shipped that morning against the pre-09-24 spec at METRIC -5.63, with noise of ±18 points. The variation between writers (sd 0.13 to 0.20) outweighed any spec effect. Widening each answer key from 10 to 22 questions cut the noise threshold from 17.97 to 10.50 with no extra writers. Even then the shipped spec still came out even with the old one (+3.00).
- **What moved the score was extraction, not structure.** Three bold rewrites of step 3, 10 writers per source against 10 stored control handoffs:

  | Candidate | Idea | METRIC | Threshold | Verdict |
  |---|---|---|---|---|
  | A | copy every fact out word for word, in order, before any prose | +20.25 | 5.58 | kept |
  | B | fill-in template with fixed slots | +8.75 | 6.86 | discarded |
  | C | existing spec plus a 20-question self-test | +8.00 | 8.35 | discarded |

  A also cut the variation between writers from about 0.15 to 0.04, which is what the loop was designed to target.
- **The held-out source did not confirm it.** On test-races, which no loop round had scored, A came out +9.00 against a threshold of 10.90. The pre-registered rule was not met. Its per-handoff scores sit on the 0.025 grid, so the key there is as wide as the loop keys. Writer variation was 0.124 there: how well A makes writers agree depends on the source conversation.
- **Eval running costs are real limits.** One round needs about 40 Fable grader calls. Fable ran out of credits three times across two days, and once the 5-hour session limit stopped a round partway through its writers. The harness can only resume grading, so a round that dies while writing has to be re-run in full.
- **The contamination guard had a hole on an error path.** A grader reply the harness could not parse was printed to stdout in the error message, grader reasoning included. The loop conversation read held-out grader text for two questions. This happened after all candidates were scored, and the error now prints only counts and a file path.

## Changes Made

All merged locally to main, installed, and passing the full ghost gate (68/68) at each merge. Nothing pushed.

- **Rotation wake** (1361785): the kick is re-written every 2 s until the wake is delivered, up to 30 times. Only the lead's `/clear` spends it. A zero delay writes once. A Fable review returned MERGE, with three minor fixes folded in.
- **Mod rename** (f21a097): `mods/cs-rotate` became `mods/cs`, deployed to `~/.claude/skills/cs/`. The installer retires the old directory.
- **`/queue`** (5c49a75): the `cs` mod registers an immediate `/queue <task>` that runs `cs -queue add` mid-turn. It was measured live on 2.1.281. Every launch now exports `CS_BIN`, and `CS_UPDATE_BIN` is retired. `cs -queue add`, `cs -msg --kind task` and `cs -spawn --task` share one single-line check.
- **Rotate skill step 3** (2bfd619): candidate A, the verbatim fact ledger. Alex chose to merge it despite the held-out miss. The CHANGELOG line says the held-out result was inside the noise.
- **Harness (machine-local)**: `verify`, `verify --resume`, `rescore --baseline`, 22-question keys, and PREREG.md with Amendment 1, the contamination event and the results.

## Key Files & Outputs

- `skills/rotate/SKILL.md`: step 3 rewritten around the fact ledger (7bfc04b, restored as 3e1516e after B and C lost).
- `hooks/session-start.sh`, `docs/hooks.md`, `docs/configuration.md`: kick retry and its documentation.
- `mods/cs/` (renamed), `lib/01-manifests.sh` (`cs-rotate` in RETIRED_SKILLS), `lib/75-launch.sh` (`CS_BIN`), `lib/55-queue.sh` (`_queue_require_single_line`).
- `CHANGELOG.md` Unreleased: the rotation wake, the rename, `/queue`, `CS_BIN`, the multi-line refusal and the handoff spec changes.
- `.cs/research/handoff-eval/{harness.py,PREREG.md}` (gitignored); run ids 20260924T150723 (baseline), 161024 (A), 165615 (B), 201123 (C), 204930 (held-out).
- `.cs/handoffs/2026-09-24-handoff-eval-bold-candidates.md` with its Successor report.

## Outcome

The loop finished as planned: three candidates scored, the best one run once on the held-out source, and the result reported. A beat the old spec on every source and never lost, by a wide margin on two and inside the noise on the held-out one. So the honest status is "best measured candidate, not confirmed". It is on main and installed on that basis, by Alex's decision. The wake bug is fixed and measured. `/queue` works live.

## Notes for Future Reference

- main is 50 commits ahead of origin, and v2026.9.22 is unreleased. The release gate: push the release commit, then tag only after its CI is green.
- Future eval rounds: budget Fable credits per round, run one round at a time, and read only the summary lines of the harness output.
- A's handoffs are about 40% longer. If rotations start to feel slow or successors miss facts in long handoffs, measure it before trimming the ledger.
- Open, from the handoff: the rotate skill's prune needs a "tracked by git" check. `2026-08-24-theme-and-claide-followup.md` is consumed, older than 30 days and untracked, so pruning it would delete the only copy. `cs -rm measure-wake` was never answered. The doctor's missing-shadow-ref warning for da093a8c was not investigated.
