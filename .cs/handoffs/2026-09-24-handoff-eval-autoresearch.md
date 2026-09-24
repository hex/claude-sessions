---
parent: 8692f800-a0f0-4c5d-babe-c5d06b336ff8
created: 2026-09-24T10:58:14Z
purpose: Build a scriptable eval harness for handoff quality, then run /autoresearch on skills/rotate/SKILL.md against it
status: consumed
consumed_by: bbc43868-d259-4b9e-9b18-87d9a69f2e9c
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

# 4. Primary Request and Intent

- **This conversation:** resumed from the handoff `2026-09-24-after-handoff-spec.md`. Alex picked the missing-wake investigation, and it was fixed, reviewed, merged and measured live.
- **Now:** Alex wants handoff quality driven up by an automated keep/discard loop (autoresearch) rather than one-off A/B runs, "until we have the best results".
- **Durable intent (inherited):** handoffs should carry facts correctly, not merely more of them, and changes to the rotate spec should be measured against a control, not argued.

# 5. Key Technical Concepts

- **The rotate spec is `skills/rotate/SKILL.md`,** installed at `~/.claude/skills/rotate/`. It defines the 9-section body, the two-pass commits, and the provenance labels on each claim.
- **Eval shape** (from PREREG.md): writers distil `core.txt` under a given spec. Zero-memory successors answer the `briefs.json` questions from the handoff alone. A grader blind to the arm scores each answer CORRECT, PARTIAL, MUST_LOOKUP or WRONG against the gold. A leak check greps successor transcripts for strings that appear only in the live repo.
- **Subagent isolation is a harness claim, not a prompt one** (memory `project_subagent_context_leak`): grep each transcript for a canary, or the run is void.
- **Eval saturation** (memory `project_eval_saturation`): an eval where every arm passes measured nothing. It needs a control arm, a rejection region and single-occurrence golds.
- **Test suites never run locally; they run on ghost.** The wrapper is `~/.claude/plugins/cache/temp_git_1790170091228_30i6zh/scripts/remote-tests.sh --host ghost@ghost --repo . --cmd "bash tests/run_all.sh" --exclude scratchpad`. It rsyncs the checkout and writes its exit code to `ci/claude-sessions/suite.status` on ghost. This matters only if SKILL.md edits touch `tests/test_rotation.sh`, which pins spec phrases; run that suite after each accepted edit.

# 6. Files and Code Sections

- `skills/rotate/SKILL.md`: the loop target.
- `tests/test_rotation.sh`: pins phrases from SKILL.md, e.g. `test_rotate_skill_has_a_home_for_conversation_only_facts` and `test_rotate_skill_keeps_successor_reports`. An autoresearch edit that removes a pinned phrase turns the suite red.
- `hooks/session-start.sh`: the rotation preamble and the kick writer. This conversation changed the kick into a loop that retries until `delivered` exists (up to 30 writes; one write at delay 0), and made the spend branch lead-only.
- `.cs/research/handoff-ab-2026-09-24/`: the eval assets listed in section 1.

# 7. Problem Solving

- **Missing wake (09-23): fixed.** Root cause, from transcript `durationMs`: the SessionStart hook ran 21 s under load, so both of the old fixed writes landed before the watch armed. Fix: retry until delivered. Commits `d535d79`, `bba3d13`, `6e0cc0a`, `1928491`, `7e32b27`, `1e72b5e`; merge `1361785`. Ghost 68/68 on main. Codex and Fable both reviewed; Fable's verdict was MERGE.
- **Two self-inflicted problems, both fixed:**
  - 30 back-to-back writes at delay 0 raced the test teardown's `rm -r`. Delay 0 now writes once.
  - `git commit -qam` swept `.cs` files into a fix commit. It was split out again; never use `-a` in this repo.

# 8. Pending Tasks

Native list (session-keyed; inherited):
- #554 [pending] PARKED: SessionStart notice for tool calls left pending at the end of the previous conversation.
- #606 [pending] POSTPONED: `cs --remote` via Claude Remote Control.
- #670 [completed] Rotation kick fix.

Not in the native list:
- The handoff eval harness and the autoresearch loop (section 1).
- Release v2026.9.22 via `/release`; tag only after CI is green.
- Deleting the throwaway `measure-wake` session (asked, unanswered).
- The doctor warning "no shadow ref refs/worktree/cs/session/da093a8c-..." (not investigated).

# 9. Current Work

- Nothing is running. The ghost suite is idle, and the `cswake` tmux server was killed.
- The installed hooks match main (cmp and doctor drift OK).
- Uncommitted before this rotation: `.cs/handoffs/2026-09-24-after-handoff-spec.md` (its successor report) and my narrative. This rotation's step 8 commits both.

**Completeness:** both passes were written from live context, with no compaction. Not carried: the per-question A/B answers (never saved; `succ/` is empty) and the full Codex and Fable review texts, whose findings are summarised above.

## Successor report

- **Wrong: "succ/ is empty ... successor and Codex-grader prompts must be rebuilt".** The six successor sandboxes (handoff.md, questions.md, answers.md, err.txt, prompt.md) were still at `/private/tmp/claude-501/ab-sbx/h1..h6`, which the handoff never named. The goldsmith, writer and Codex-grader prompts were recoverable verbatim from the parent transcript (`jq` over `da093a8c-....jsonl`, `Agent` tool_use inputs). Found by `ls` of the old scratch dir, then jq. Copied into `.cs/research/handoff-ab-2026-09-24/succ/`.
- **Re-derived: the serialiser.** The handoff said a text cut "needs a serialiser"; the exact jq that produced core.txt was the Bash call at parent-transcript line 1723 (`head -n 5048 524ba3e7....jsonl | jq ...`). Reproduced byte-identical (`cmp`). The scratch `hr/ex.sh` and `turns.sh` are different formats.
- **Re-derived: which parents can be cut.** Of 25 handoffs whose parent JSONL exists, only 3 transcripts contain a user `<command-name>/rotate</command-name>` line (655bde7e, be426d62, 601bd3d4) besides 524ba3e7; the rest rotated without one (forced rotation or skill call). Found by grep over each parent.
- The old scratch dir had not been rebooted away; nothing in it was lost.
