---
parent: da093a8c-e4e0-40f6-97dd-dc13e6fc09a8
created: 2026-09-24T09:26:49Z
purpose: Nothing is in flight. Record whether this wake fired, report the state, and ask Alex which open item comes next (wake bug, release, or parked tasks)
status: unconsumed
---

# 1. Next Step

Nothing is running and nothing is half-done. The rotation happened because context reached 67%, not in the middle of a task. So the next step is to report and ask, not to build anything.

1. **First, record one data point about the wake itself.** Did this conversation start from cs's automatic wake (a system-reminder saying the session was woken), or from a message Alex typed? Note which, and roughly how many seconds after the `/clear` (read `.cs/local/session.log`, whose tail has the `Session started (... ID: <uuid>)` line for this conversation). This feeds open bug (a) below. Nothing to check first: this is a read.
2. **Then send Alex one short status message plus one AskUserQuestion**, header "Next", with these options:
   - **(a) Investigate the missing wake after `/clear`** (Recommended; it is a live bug). On 2026-09-23 the rotation into conversation 0924fa25 got no wake: the `/clear` was at 08:55:50 and Alex typed "continue" at 09:03:11. Three other rotations were woken within 3 to 8 seconds. Nothing has been investigated yet. Your step-1 data point is the first new reading.
   - **(b) Release v2026.9.22.** Before offering it, check whether it has already happened: `git -C /Users/alex.geana/.claude-sessions/claude-sessions tag --sort=-creatordate | head -1` should print `v2026.9.21`, and `git log --oneline origin/main..main` should be non-empty (7 commits at 09:26Z). `CHANGELOG.md` has a `## Unreleased` section holding the handoff spec edits and the `/wrap` fix. The release flow is `/release` (repo `.claude/commands/release.md`). Push the release commit and tag only after its CI is green (memory `project_release_gate_skips_ci`).
   - **(c) Parked native tasks:** #554 (a SessionStart notice for tool calls left pending at the end of the previous conversation) and #606 (`cs --remote` via Claude Remote Control, postponed).
3. After Alex answers, append the `## Successor report` the rotation preamble asks for. This handoff is the first live run of the new spec (see section 2), so what you had to look up, re-derive, or found wrong is the measurement.

Test suites never run locally. Use ghost, in the background:
`bash /Users/alex.geana/.claude/plugins/cache/temp_git_1790170091228_30i6zh/scripts/remote-tests.sh --host ghost@ghost --repo . --cmd "bash tests/run_all.sh" --exclude scratchpad`
It rsyncs the checkout to `ghost@ghost:ci/claude-sessions`, runs detached, and writes the exit code to `ci/claude-sessions/suite.status`. The plugin cache path may change on a plugin update: if it is gone, run `ls -t ~/.claude/plugins/cache/*/scripts/remote-tests.sh | head -1`. Before starting a run, check that none is in flight: `ssh ghost@ghost 'cat ci/claude-sessions/suite.status 2>/dev/null; pgrep -f run_all.sh'`. A running suite shows a pid and an empty or stale status.

# 2. Settled and rejected

- **Handoff size: no target and no floor.** Three of the four new OpenRouter seats wanted a floor of about 15 KB; Fable and Opus said no size change. Rejected because four real handoffs that demonstrably worked were 10.5 to 21.7 KB, and three of them were under 15 KB. The failures were wrong facts, not missing ones (measured in the successors' transcripts by Fable and Opus).
- **The 8-section body was not collapsed into 4 or 5**, although Codex, Grok and deepseek suggested it. No measured harm. What was added instead is section 3, "Conversation-only facts".
- **The two-pass commit rule stays.** Fable and Gemini suggested cutting it. No compaction mid-write was ever observed, but there is also no evidence the rule costs anything.
- **Fix 2 was rejected:** a preamble line telling the next conversation to relay errors verbatim. Alex took only fix 1 (the Next Step "already done or still running" rule). Reason: low value, since any summary can lose detail.
- **Moving step 7's bookkeeping (supersede and prune) into code** was proposed by three council seats. Not done; no decision taken.
- **Specialists stay in claude-council, not cs.** Reasons I gave the claude-council session: cs has no create-only feature worktree (`cs <base>@<f>` and `cs -spawn` both launch claude); Alex dropped delegation from cs twice (2026-09-08); and it would couple claude-council to cs. Suggested they borrow cs's integrate-in-temp then `--ff-only` landing instead of `git merge --no-ff` into the live checkout.
- **The `/wrap` zsh fix was not released on its own.** Alex asked "should we push a new release?". I recommended waiting, since v2026.9.21 was 3 hours old and the fix is one sentence. He moved on without answering, so it rides the next release.

# 3. Conversation-only facts

- measured: the `/wrap` failure was zsh reading `echo ======` as a command lookup. `zsh -c 'echo A; echo ======; echo B'` prints `A`, then `zsh:1: ===== not found`, and exits 1. Under bash the same line exits 0. I hit it again myself later with `echo ====GEMINI`.
- measured: handoff sizes over the 30 newest of 40: lines 77 / 233 / 388 (min / median / max), bytes 7.7 / 13.1 / 21.7 KB. Fable measured all 40: median 11.8 KB, min 5.6 KB.
- inherited from Opus's review (it read the transcripts): the 09-23 handoff said `--host ghost` fails. The real cause was the short name `ghost` with no host store; `--host ghost@ghost` works.
- inherited from Opus's review: after the 09-23 `/clear` at 08:55:50, no wake fired, and Alex typed "continue" at 09:03:11. Other successors were woken within 3 to 8 seconds.
- inherited from Opus's review: the 09-23 handoff said SessionEnd on `/clear` has source `clear`, while `session.log:109481` shows `user_exit`.
- measured by the council runs: Cursor seat "You've hit your usage limit"; OpenRouter `xiaomi/mimo-v2.6 is not a valid model ID` (first run); grok-cli fell back to the grok-4.6 API. Alex then set the OpenRouter seats to 4: `~deepseek/deepseek-pro-latest`, `z-ai/glm-5.3-prime`, `xiaomi/mimo-v2.6-pro`, `qwen/qwen3.8-max-prime`. All 4 answered on the rerun.
- measured, A/B experiment (Codex graded blind; unblinded mapping h1=B1 h2=B3 h3=A3 h4=A2 h5=B2 h6=A1; A = old spec, B = new):
  - Correct 12 (old) vs 13 (new); wrong 1 vs 2; one-off facts 5/18 vs 8/18; unsupported "fails" claims 32 vs 21.
  - Question on the unverified #664 colours: new 3/3 correct, old 0/3.
  - Ghost question: 6/6 handoffs quoted the real error.
  - Handoff sizes: old 20.2 / 18.2 / 19.9 KB, new 26.4 / 24.5 / 23.7 KB.
- measured: the one real handoff defect behind a wrong answer was writer B3's Next Step, "if there is no `rc=` line … rerun it in the background". That instruction became the new "already done or still running" rule.
- assumed: the replay did not reproduce the ghost failure because the real writer was at about 80% context while the replay writers read a clean text core. Not tested.
- measured: the headless isolation recipe. `claude -p --restricted --tools Read --no-session-persistence`, run from `/private/tmp/claude-501/ab-sbx/probe` with the cs env unset, reported no repo, branch or commit in context. The A/B answers had 0 hits for repo-only strings.
- measured: a Fable review agent ran `tests/test_rotation.sh` locally (111/111) because its brief did not forbid it. Earlier, on 09-23, I ran `tests/test_commands.sh` locally, which breaks the ghost rule. Both were told to Alex.
- Alex's words, in order:
  - "this should be fixed in cs project, no?"
  - "yes" (merge the wrap fix)
  - "should we push a new release?"
  - "is it good?optimal?detailed enough? check with fable and opus"
  - "maybe also do a council run"
  - "I updated the openrouter models from the router, let's run them again, now they are 4"
  - "first /eli5 them for me"
  - "show me the static html"
  - "yes" (the 5 edits)
  - "run them both, and maybe we can test them, old vs new"
  - picked "n=3 per arm (Recommended)"
  - "hmm, why do we still have wrong answers?"
  - "ok" (fix 1, then the ghost run, merge and install)
  - picked "Run /wrap"
- measured at 09:26Z: main is 7 commits ahead of origin/main; the working tree has only the untracked `scratchpad/`.
- Scratch that dies on reboot: the A/B harness is under this conversation's scratchpad `/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/da093a8c-e4e0-40f6-97dd-dc13e6fc09a8/scratchpad/ab/` (RESULTS.md, briefs.json, PREREG.md, six handoffs, mapping.json). The blind runs are in `/private/tmp/claude-501/ab-sbx/h1`..`h6`.

# 4. Primary Request and Intent

The conversation was a chain of Alex's questions, each leading to the next (his words are in section 3). The durable intent: rotation handoffs should carry facts correctly, not merely more of them, and changes to the handoff rules should be tested rather than argued. Alex values blind comparisons that run the old spec as a control arm, and asks "why" when a result is imperfect.

# 5. Key Technical Concepts

- **Rotation:** the rotate skill (`skills/rotate/SKILL.md`, installed at `~/.claude/skills/rotate/`) writes a handoff to `.cs/handoffs/`, commits it in two passes and arms `.cs/local/pending-handoff`. On `/clear`, `hooks/session-start.sh` marks the handoff consumed (`consumed_by:`) and injects the "Conversation Rotation" preamble.
- **The preamble now asks for a successor report** (session-start.sh, around line 868): once its next step is done, the new conversation appends `## Successor report` to the handoff. The next rotation commits that report (step 8), and the prune (step 7) skips handoffs with uncommitted changes.
- **The handoff body is now 9 sections.** New section 3, "Conversation-only facts", sits in pass one. Each claim carries its own provenance label, and a "fails" claim carries its command and output. Next Step carries every fact its first action needs, plus how to tell whether that action is already done or running. Script pointers say what the script does.
- The dev repo gitignores `.cs/` wholesale, so a NEW handoff needs `git add -f`, while tracked `.cs` files commit with `git commit -- <path>`.

# 6. Files and Code Sections

- `skills/rotate/SKILL.md`: the spec. Read it whole before the next spec change; the diff is `git show 8474134 36920c4 f77dc82 -- skills/rotate/SKILL.md`.
- `hooks/session-start.sh`: the rotation preamble with the successor-report sentence (search for `Successor report`).
- `tests/test_rotation.sh`: new pins in `test_rotate_skill_has_a_home_for_conversation_only_facts` and `test_rotate_skill_keeps_successor_reports`, plus extended assertions in the provenance, next-step and content tests and in the preamble test.
- `docs/hooks.md`: the pending-handoff bullet describes the report.
- `CHANGELOG.md`: the `## Unreleased` section.
- `commands/wrap.md`: pass files are read with the Read tool.
- `.cs/summary.md`: this conversation's full summary (commit 94cfa70).

# 7. Problem Solving

- The Codex and Fable reviews both found that the successor report had no commit path, and that the prune could delete it. Fixed in 36920c4.
- The A/B test's written-down rule failed on wrong answers (2 vs 1). The breakdown showed one real writer defect, which led to the fix-1 rule (f77dc82). The other two wrongs came from answer compression and strict grading.
- The `MEMORY.md` index hit its 24,400-byte budget at wrap. Pointers were rewritten shorter, not deleted; the "CI alone judges bash 3.2" clause was dropped once and restored.

# 8. Pending Tasks

Native list (session-keyed; you inherit it):
- #554 [pending] PARKED: SessionStart notice for tool calls left pending at the end of the previous conversation.
- #606 [pending] POSTPONED: `cs --remote` via Claude Remote Control (Mac Mini host).

Not in the native list:
- The missing-wake bug from 09-23.
- The next release (the `## Unreleased` section).
- The first live check of the new handoff rules (this handoff is it).

# 9. Current Work

Done and shipped locally:
- The wrap fix (fe5d1e4).
- The handoff spec edits (ff77451): ghost 112/112 on the rotation suite and 68/68 on the full suite, installed, doctor drift OK.
- The session wrap (94cfa70).

Not pushed. No branches are left open from this conversation.

**Completeness:** both passes were written from live context; no compaction happened in this conversation. Not carried: the full council transcripts (in `.claude/council-cache/`) and the per-question A/B answers (in the scratch paths in section 3).
