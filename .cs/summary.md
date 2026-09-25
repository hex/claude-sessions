# Session Summary: claude-sessions

**Date:** 2026-09-25, about 09:15 to 13:05 Bucharest time
**Duration:** about four hours over four conversations, each started by a rotation: the one that merged the fact ledger and wrote the previous summary, 465be02e (real-key rescore), c5408bd8 (two merges and a rotate-skill fix) and d03d1e48 (this one). The session itself has run since 2026-02-07. The previous summary, covering 09-24 up to the fact-ledger merge, is in git history at d521ae6c; older days are in `.cs/README.md` and the narrative archive.

## Objective

The morning had two threads. The first was to test the claim behind the fact-ledger handoff spec merged overnight: does it help a real successor, or only a quiz? The second was a run of small fixes that surfaced while working: the rotate prune, a slow `/clear`, a scope-prompt timeout, the pending-handoff prompt, a false doctor warning, and a CHANGELOG line that overstated a result.

## Environment

- Repo: the cs dev checkout at `~/.claude-sessions/claude-sessions`, main branch, Claude Code 2.1.281 and 2.1.282.
- Test suites run on the `ghost` host through `remote-tests.sh`; CI macOS is the only bash 3.2 judge.
- Eval harness: `.cs/research/handoff-eval/` (gitignored). Answer keys live in `~/.cache/handoff-eval/`, out of the scoring conversation's reach. All model calls run on the subscription.
- A peer Claude session named `claude` exchanged messages about the rotate skill. Alex asked for the second exchange.

## Key Discoveries

- **The fact ledger's +20 does not survive real questions.** For each eval source, the conversation that actually picked up the handoff served as ground truth: every fact it had to look up, re-derive or got wrong became a question. Rescoring the stored handoffs against those keys gave candidate A +0.21 points over the old spec, with a noise threshold of 6.62. The +20.25 came from quiz keys a goldsmith wrote. The held-out source's real-key controls turned out defective (3 to 4 of 10 handoffs voided), so that number measures nothing until they are rebuilt. A stays in the skill: it costs about 8 KB per handoff and does no measured harm.
- **Do not rerun the eval loop now.** Real-key noise is 6 to 10 points on three sources, and the successor reports so far name operational slips (a dirty worktree, a grep that hid an error) rather than missing facts. The plan is field data: code the next five successor reports by failure kind (#679).
- **Slow `/clear` was cs, not Claude Code.** SessionEnd rebuilt `~/.claude-sessions/index.md` with about six forks per session, 138 sessions, 8 to 27 s. One awk pass does it in 0.15 s with byte-identical output.
- **The scope-prompt timeout died before the hook's own clock started.** A killed run left no trace line at all, so the time went to library load or process start on a loaded machine (opendirectoryd at 80% CPU). The hook now writes a launch mark with builtins before loading anything, and its registration went from 5 s to 10 s.
- **The doctor's "autosave may be broken" warning was a false positive since 2026-07-23.** Doctor looked for the snapshot ref of the launch conversation (`CS_CLAUDE_SESSION_ID`, stale after the first `/clear`), while the autosave hook writes under the live id, and SessionEnd deletes the old ref on `/clear`. As a result, every session that had rotated warned whenever its tree was dirty. Two Codex rounds widened the fix:
  - `.cs/local/state` holds only the lead's id, so doctor would have judged a teammate by the lead's ref. The caller's own id is `$CLAUDE_CODE_SESSION_ID`, which Claude Code sets in the Bash tool.
  - With the warning gone, nothing checked that settings.json registers the hook at all. A registration now counts only if its matcher covers both Write and Edit and the command is the hook itself.
- **The peer's rotate-skill section had no failure behind it.** The request for a "long-running operation" section came from reading another project's template, not from a rotation that went wrong. Alex and the peer agreed to hold it. #679 gained two codes to watch for:
  - a successor acting on a newer commit than its operation started from
  - goal drift across chained rotations, where scope Alex dropped reads as current a few handoffs later

## Changes Made

All merged locally to main and installed, each behind a full ghost gate (68/68). Nothing pushed.

- **Rotate prune** (16c7acd, merged 334edd6): deletes only a handoff git tracks. A gitignored, untracked handoff was the only copy of itself.
- **SessionEnd index** (98e9a14, merged ca20677): one awk pass, 26.9 s to 0.15 s measured under load.
- **Scope-prompt launch mark** (be8b0ca, 17f11be, merged e7aafe4): trace line before the library load; 10 s registration.
- **Pending-handoff prompt** (3f98ffc, 7896ce2, merged 854b1f9): one answer per row, keys first. The "(from another checkout)" label printed its escape code as text and now prints dim.
- **Rotate skill** (c2d273c, merged 6f5a1b7): a Next Step that needs a clean worktree says to commit the consumed handoff first, since session start dirties it.
- **CHANGELOG** (0a31a5e): the fact-ledger line reports the real-key result instead of "20 points".
- **Doctor autosave row** (5857a0e, 8e2f10d, 44e1427, merged 0cdf38a): checks the caller's own ref, reports "no snapshot for this conversation yet" when there is none, and warns when `settings.json` does not register the hook for Write and Edit.
- **Housekeeping:** Alex approved removing the throwaway `measure-wake` session. Task #680 closed and #679 widened.

## Key Files and Outputs

- `lib/60-doctor.sh` (`_doctor_check_shadow_ref`), `tests/test_doctor.sh`: five shadow-ref tests, each seen red first.
- `hooks/session-end.sh` (index rebuild), `hooks/scope-prompt.sh` (launch mark), `install.sh.in` (10 s registration).
- `lib/75-launch.sh` (`_resume_menu_row`), `skills/rotate/SKILL.md` (prune rule, clean-worktree sentence), `tests/test_rotation.sh`.
- `CHANGELOG.md` `## Unreleased`: every change above plus the fact-ledger line.
- `.cs/handoffs/2026-09-25-*.md`: three handoffs with successor reports.
- Machine-local, gitignored: `harness.py --keys`, `~/.cache/handoff-eval/keys-real/`, runs 20260925T101240, 102548 and 103600, and `.cs/research/handoff-field-log.md` with the #679 decision rule.

## Outcome

Everything Alex asked for is on main and installed: six fixes plus the CHANGELOG correction. The eval question has an honest answer: the fact ledger is not worse, and nothing has shown it to be better. The next evidence comes from real rotations rather than another loop. The only doctor warning left is the non-cs status line from the iterm-agents-sidebar bridge, which predates this work.

## Notes for Future Reference

- main is 91 commits ahead of origin. v2026.9.22 waits on Alex's go to push. The release pattern: push the release commit, then tag only after its CI is green, with `--target <full sha>`.
- #679 is due after five fact-ledger rotations or on 2026-10-15. It codes each successor report by kind: phase, stop condition, failure policy, moving-ref state and goal drift. Check the claude-council chain for goal drift. If a kind shows up, the fix is one line in the rotate skill, not a new section.
- `$CLAUDE_CODE_SESSION_ID` is the caller's id in the main conversation. Nobody has verified the same holds for teammates and subagents; if it differs, doctor says "no snapshot yet" there rather than warning falsely.
- A `codex:codex-rescue` job that outlives the agent's 120 s window comes back as an early return. Fetch the verdict with `codex-companion.mjs status` then `result task-<id>` (memory `project_codex_readonly_no_probes`).
- Slips this morning, all caught: suites run locally against the ghost-only rule (three times), and a `git switch | tail` that hid a refusal and launched a gate on the wrong branch.
