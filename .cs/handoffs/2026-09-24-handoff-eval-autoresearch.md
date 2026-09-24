---
parent: 8692f800-a0f0-4c5d-babe-c5d06b336ff8
created: 2026-09-24T10:58:14Z
purpose: Build a scriptable eval harness for handoff quality, then run /autoresearch on skills/rotate/SKILL.md against it
status: unconsumed
---

# 1. Next Step

Alex's words: "the results are not that great though. no? let's rotate then use /autoresearch:autoresearch until we have the best results". I agreed the results are weak and warned that looping against the current eval would chase noise (see section 2). Alex has not answered that warning yet, so **open by stating the four eval conditions below in two lines and asking Alex (AskUserQuestion) whether to build the harness with them or run the loop as-is.** Then:

1. **Build the harness first.** `/autoresearch` (plugin 1.8.2, `~/.claude/plugins/cache/autoresearch/autoresearch/1.8.2/skills/autoresearch/SKILL.md`, read in source) refuses to loop without five inputs: Goal, Scope, Metric, Direction, Verify. If any is missing it must ask via AskUserQuestion first. Verify has to be one runnable command that prints the metric. No such command exists: the previous A/B was run by hand across subagents. Check whether it already exists before building: `ls .cs/research/handoff-eval/` (the name I suggest; it does not exist at 10:58Z).
2. **Assets to build from** (copied from reboot-volatile scratch into the gitignored, machine-local `.cs/research/handoff-ab-2026-09-24/`, 664 KB):
   - `core.txt`: 475 KB text transcript of the 09-23 conversation, cut just before `/rotate`. It is the source a writer distils.
   - `briefs.json`: a list of 10 questions `{id, kind, brief, gold}`. Q1 and one other are `kind: control`, which every competent handoff must answer.
   - `spec-A.md` (old SKILL.md, 12,958 B) and `spec-B.md` (new SKILL.md **without** fix 1 `f77dc82`, 14,754 B).
   - `writer-prompt.md`: the writer brief. **Its paths are hard-coded to the old scratch dir** `/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/da093a8c-e4e0-40f6-97dd-dc13e6fc09a8/scratchpad/`; rewrite them to the new location.
   - `PREREG.md` (metrics M1-M5 and the rejection region), `RESULTS.md`, `mapping.json`, `handoffs/raw-{A,B}{1,2,3}.md`.
   - **Missing:** `succ/` is empty, and there are no successor-prompt or grader-prompt files. The successor and Codex-grader prompts must be rebuilt from PREREG.md and RESULTS.md.
3. **The four eval conditions I proposed** (Alex has not ruled on them):
   1. more than one source conversation, including one held out that the loop never scores against;
   2. 5 or more writers per variant;
   3. handoff length recorded as a covariate;
   4. the old spec (spec-A) kept as a control arm in every round, with a rejection region set before the run.
   Only one source conversation exists today (core.txt). Candidate extra sources are other rotation handoffs whose parent transcripts still exist under `~/.claude/projects/-Users-alex-geana--claude-sessions-claude-sessions/<parent-uuid>.jsonl`. A text cut needs a serialiser: memory `project_transcript_core_ratio` says a JSONL is 98% machinery.
4. **Loop target and branch.** The file autoresearch modifies is `skills/rotate/SKILL.md`, on a new branch (for example `feat/rotate-autoresearch`), never main. The installed copy at `~/.claude/skills/rotate/` must not change until a winner is merged.

Cost warning to give Alex before the first run: one round with 2 variants, 5 writers each and 10 briefs is about 10 writer agents plus 10 successor agents plus grading. The previous 3+3 run took most of a conversation.

# 2. Settled and rejected

- **Rotation wake fix: done and measured**, not open work. Merged to main as `1361785`, installed, doctor drift OK. Live old-vs-new from fresh launches: old 0/2 wakes, new 2/2 (table in section 3).
- **Warning (mine) on autoresearch as-is:** with one source conversation, n=3 per arm and one grader, the writer draw is as large as the arm effect. Looping "until best" would overfit core.txt's 10 briefs and the writer draw. This is why section 1 opens with a question.
- From the previous conversation (inherited from the 2026-09-24-after-handoff-spec handoff): no handoff size target or floor; the 8-section body was not collapsed; the two-pass commit rule stays; "fix 2" (relay errors verbatim) was rejected; only fix 1 (Next Step says how to tell if work is done or running) was taken.
- The Codex review of the wake fix raised two points I declined, each with an in-code "do not re-fix" note: an overlapping-consumer double wake, and a stale child from rotation N writing into N+1. Fable upheld both.
- `cs -rm measure-wake` was offered; Alex did not answer. The throwaway session `~/.claude-sessions/measure-wake` still exists. Do not delete it without asking.

# 3. Conversation-only facts

- measured (A/B, `.cs/research/handoff-ab-2026-09-24/RESULTS.md`), old A vs new B (without fix 1), 3 writers per arm, graded blind by Codex:

  | | Old (A) | New (B) |
  |---|---|---|
  | Correct | 12 | 13 |
  | Partial | 7 | 5 |
  | Must look up | 10 | 10 |
  | Wrong | 1 | 2 |
  | Once-only facts correct (of 18) | 5 | 8 |
  | Unsupported "fails" claims | 32 | 21 |
  | Mean size | 19.5 KB | 24.9 KB |

  - Pre-registered M1 (B wrong ≤ A) failed. Both B wrongs came from writer B3.
  - Writer variation equals the arm effect.
  - Mapping: h1=B1, h2=B3, h3=A3, h4=A2, h5=B2, h6=A1.
- measured (live wake, throwaway `measure-wake`, isolated `tmux -L cswake`, Claude Code 2.1.281, test-only `sleep 8` before session-start's emit, each arm from a fresh launch). Times are relative to the cs hook's return:
  - old #1: hook 11.5 s, last kick write −4.3 s, no `delivered`, no wake.
  - old #2: hook 12.5 s, last kick write −4.1 s, no wake.
  - new #1: hook 17.2 s, kick +2.9 s, `delivered` +3.9 s, woke.
  - new #2: hook 11.3 s, kick +2.0 s, `delivered` +2.9 s, woke and replied `WOKE-new`.
- measured: the kick watch survives `/clear`. With the old code, when the previous conversation was itself a rotation, the wake landed 4.1 s *before* the hook returned. So only the first rotation after a startup or resume is exposed; 09-23 was one of those.
- measured: `sleep 15` pushed the cs hook to 29.1 s, next to the 30 s SessionStart timeout, so that run is void. One further run was void because a killed claude kept the cs session lock ("Session measure-wake is already running elsewhere ... Use --force"). The fix: `/exit` first.
- measured: a tmux server started from the Bash tool inherits `CLAUDE_CODE_CHILD_SESSION`. The throwaway then showed "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker". Launch with `env -i HOME PATH USER LOGNAME SHELL LANG TERM TMPDIR`.
- measured: the 09-23 SessionStart for 0924fa25 took 21,054 ms under a 7-job local run_all. Today's took 4,385 ms.
- The wake-measurement scripts (`arm.sh`, `fresh.sh`, `result-*.txt`) are in this conversation's scratchpad: `/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/8692f800-a0f0-4c5d-babe-c5d06b336ff8/scratchpad/wake/`. They die on reboot.
- The user's words this conversation, in order:
  - picked "Investigate missing wake (Recommended)"
  - picked "Hold for Fable review (Recommended)"
  - "what else did we commit?"
  - "so is the rotation better than before? measured?"
  - "yes" (run the old-vs-new wake check)
  - "how about the handoff quality now vs before?"
  - "the results are not that great though. no? let's rotate then use /autoresearch:autoresearch until we have the best results"
- measured at 10:58Z: main is 16 commits ahead of origin. v2026.9.22 is not released. The CHANGELOG `## Unreleased` section holds the handoff spec edits, the /wrap fix and the rotation-kick fix.
