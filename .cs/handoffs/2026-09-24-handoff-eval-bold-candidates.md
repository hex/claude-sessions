---
parent: bbc43868-d259-4b9e-9b18-87d9a69f2e9c
created: 2026-09-24T12:54:46Z
purpose: Run the handoff-eval loop: write 2-3 bold rewrites of skills/rotate/SKILL.md step 3 and score each at 10 writers/source against the stored baseline
status: unconsumed
---

# 1. Next Step

**Contamination rule first (Alex's four-condition design, PREREG.md):** this conversation must NEVER read anything under `~/.cache/handoff-eval/` (answer keys, held-out source, runs, grades). The previous conversation saw the golds; you are the clean one. Read results only from the harness's stdout, captured to your own file in `/private/tmp/claude-501/` (it prints one score per handoff and the METRIC, never per-question grades). `runs/<id>/SUMMARY.txt` holds the same lines but sits under `~/.cache/handoff-eval/`, so do not open it.

Then:

1. Read `.cs/research/handoff-eval/PREREG.md` whole (design, scoring, rejection region, Amendment 1) and `skills/rotate/SKILL.md` step 3 (lines ~38-169, the handoff BODY rules: 9 sections, two passes, provenance labels, Next Step first, Conversation-only facts). Writers only follow the frontmatter + BODY rules; steps 1-2 and 4-11 (commits, prune, arming, final message) are skipped by the harness writer prompt, so edits there cannot change the score.
2. Cut the loop branch from main: `git checkout -b feat/rotate-autoresearch main` (main is `5c49a75` at 12:54Z; check `git log --oneline -1`). Never edit on main. The installed copy `~/.claude/skills/rotate/` must not change until a winner is merged.
3. Write 2-3 SUBSTANTIALLY different rewrites of step 3 (not wording tweaks; Alex's ruling, reason in section 2). Each is one commit on the branch. Ideas are yours; the measured data so far says the per-writer spread (sd 0.03-0.15) dominates and the current spec does not beat the old one, so target what makes different writers converge (e.g. a mandatory fact checklist, a fixed skeleton with slots, a different Next Step contract), not more prose rules.
4. For each candidate, with that commit checked out in the main checkout (the harness reads `skills/rotate/SKILL.md` from the checkout at writer start, `harness.py` line ~29 `CANDIDATE_SPEC`; do not switch branch while a round runs):
   `cd .cs/research/handoff-eval && python3 harness.py verify > /private/tmp/claude-501/<cand-name>.out 2>&1; echo "rc=$?" >> /private/tmp/claude-501/<cand-name>.out`
   Run it with Bash `run_in_background: true` (~25-35 min: 20 opus writers at concurrency 4, then 20+20 successor/grader calls plus re-grading the 20 stored control handoffs). `verify` reads `~/.cache/handoff-eval/baseline` (= `20260924T150723`) and reuses that run's 10 control handoffs per source; it writes 10 candidate handoffs per source.
   **Already running or done?** Before launching, `ls -t /private/tmp/claude-501/handoff-eval/ | head -3` (sandbox dirs named by run id, UTC-ish `YYYYMMDDTHHMMSS` local time) and `pgrep -fl "harness.py"`: a live harness process means a round is in flight, do not start another (two rounds share the usage window and can 429). If the `.out` file has an `rc=` line the round finished; read its last lines.
   **A round that dies at grading** (Fable 429 "You're out of usage credits", seen once this day): the handoffs and answers are saved; finish it with `python3 harness.py verify --resume <run_id>` (run id is the first stdout line `run <id>:`).
5. Keep/discard rule (PREREG, pre-registered): keep a candidate only if its `METRIC` beats the best kept METRIC (start: baseline's +3.00) by more than that round's `REJECT_BELOW`, AND `tests/test_rotation.sh` passes on ghost (it pins SKILL.md phrases; a rewrite that drops a pinned phrase fails it). Ghost command, from the repo root on a real checkout (NOT a worktree: a worktree's `.git` file breaks git-using suites on ghost): `~/.claude/plugins/cache/temp_git_1790170091228_30i6zh/scripts/remote-tests.sh --host ghost@ghost --repo . --cmd "bash tests/test_rotation.sh" --exclude scratchpad` then poll `ssh ghost@ghost 'cat ci/claude-sessions/suite.status; tail -20 ci/claude-sessions/suite.log'` with a bounded background loop (never foreground sleep). If a winning rewrite drops a pinned phrase, the test needs Alex's call, not a silent edit.
6. After the candidates: score the best kept one ONCE on the held-out source: `python3 harness.py round --writers 10 --control-writers 10 --sources test-races` (writes fresh control too; held-out was never baselined). PREREG: the edits helped only if held-out METRIC > its own REJECT_BELOW. Then report to Alex; merging a winner to main + install is his call.

# 2. Settled and rejected

- **Alex's four eval conditions: ADOPTED** (AskUserQuestion, 2026-09-24): >1 source with one held out; >=5 writers/arm; length recorded; old spec as control with a pre-set rejection region.
- **Control arm: baseline once, reuse** (Alex picked "Baseline once, reuse (Recommended)" over "Fresh control every round"). Control handoffs are written once; successors and grader re-run on them each round, which measures grader drift.
- **First-loop budget was "5 iterations"** (Alex), then SUPERSEDED: after round 0 Alex asked "but did we ran sufficient iterations?"; I showed the power table (sd .17: 5v10 -> 18 pts, 10v10 -> 15, ~23v23 -> 10) and recommended widening the key + few bold candidates; Alex: "proceed". So: NOT many small autoresearch iterations; 2-3 bold rewrites at 10 writers/source. Rejected: 5 small-edit iterations at n=5 (only an 18-point effect could be kept; most edits are smaller).
- **Grader: fable** (Alex: "try fable now" when Fable's window hit 429; rejected opus-as-grader and sonnet). Keep fable for every round so grades stay comparable.
- **`/autoresearch` plugin as the driver: not used for the loop** (assumed fit): its Verify expects one command printing one metric and a Min-Delta; `harness.py verify` provides that, but with 2-3 hand-written bold candidates a manual loop is simpler. Using the plugin is still allowed if you want its logging.
- Mod rename `cs-rotate` -> `cs` and `/queue`: DONE and merged (section 3), not open work.
- From earlier handoffs (inherited): no handoff size target; 8->9-section body kept; two-pass commit rule stays; "fix 2" (relay errors verbatim) rejected; fix 1 (Next Step says how to tell done/running) taken.
- `cs -rm measure-wake`: never answered by Alex; the throwaway session `~/.claude-sessions/measure-wake` still exists (used again today for the /queue live test). Do not delete without asking.

# 3. Conversation-only facts

- measured: dry run `20260924T140903` (1 writer/arm, tab-title, 10 briefs): cand 0.562 vs ctrl 0.312, METRIC +25 (n=1, noise). Isolation measured: writers read only core.txt/spec.md/handoff.md, successors only handoff.md/questions.md, 0 permission denials.
- measured: harness calls run on the Claude Code subscription: init event `apiKeySource: "none"` (ANTHROPIC_API_KEY scrubbed). `total_cost_usd` is an API-price equivalent, not a charge: writer ~$4.3 / ~200 s on the 475 KB source; successor ~$0.16 / 30 s; grader ~$0.33 / 35 s. Real cost = 5h/weekly/Fable usage windows. At ~12:10Z limits: 5h 7%, weekly 75%.
- measured: round 0 `20260924T141823` (5 cand + 10 ctrl per source, 10-brief keys): 22/30 fable grader calls failed `api_error 429 "You're out of usage credits. Switch to another model, or manage usage credits at claude.ai/settings/usage..."`; `verify --resume` later graded them all with fable. Result: tab-title cand .487 sd .204 vs ctrl .550 sd .128 (-.063); first-paint cand .575 sd .135 vs ctrl .625 sd .164 (-.050); METRIC -5.63, REJECT_BELOW 17.97. Handoff sizes equal across arms (~18.5-20 KB).
- measured: new baseline `20260924T150723` = round 0's 30 handoffs re-answered and re-graded against 22-brief keys (`rescore --baseline`): tab-title cand .500 sd .145 vs ctrl .440 sd .077 (+.060); first-paint cand .575 sd .031 vs ctrl .575 sd .105 (0). **METRIC +3.00, REJECT_BELOW 10.50.** 0 voided handoffs. Widening the key cut the threshold 18 -> 10.5 with no new writers.
- measured conclusion: the spec edits shipped 2026-09-24 (8474134, 36920c4, f77dc82) show no measurable gain over the pre-8474134 spec (-5.6, then +3.0, both inside noise).
- Alex, verbatim, this conversation: "the results are not that great though. no? let's rotate then use /autoresearch:autoresearch until we have the best results" (prior conversation); "does it use api or claude code subscription?"; "but did we ran sufficient iterations?"; "proceed"; "using the new mods can we do a new /queue task queue to queue comands in our todolist system from cs? while claude is busy?"; on the mod home: "maybe we should change the mod name?"; "yes" (to name `cs` + order).
- measured, /queue live on 2.1.281 (throwaway measure-wake, isolated `tmux -L csqueue`): with `Bash(sleep 45)` in flight, typing `/queue live test task one` printed `⎿ cs: Queued: live test task one`; `cs -queue list` -> `Pending: 1. live test task one`; status bar `▤ 1`; at turn end the Stop hook offered the drain (Start / Not yet). Cleaned up (queue cleared, tmux server killed).
- measured: ghost full gate 68/68 on main `f21a097` (rename) and on `5c49a75` (/queue). A ghost run from a git WORKTREE fails `test_narrative_rotate.sh` 18/50 with `fatal: not a git repository: .../.git/worktrees/wt-mod-rename` (the worktree's .git file points at a Mac path): run gates from the real checkout.
- measured: `test_finish_script.sh` flaked once on ghost: `FAIL: the lookup must give up at the ceiling; it took 18s` (24/24 rerun alone).
- measured: main is 29 commits ahead of origin at 12:54Z; nothing pushed; v2026.9.22 unreleased (CHANGELOG `## Unreleased` holds the handoff-spec edits, /wrap fix, rotation-kick fix, mod rename, /queue, CS_BIN).
- measured: doctor after install: "cs mod: installed but has not run in this session" WARN, expected until the next `cs` launch (heartbeat file renamed to `.cs/local/cs.heartbeat`).
- read in source (agent report): an old cs-rotate module still loaded in a running claude keeps writing `.cs/local/cs-rotate.heartbeat` / `cs-rotate.forced` until restart; one already-forced conversation could be force-rotated once more after upgrade. Unverified: whether deleting `~/.claude/skills/cs-rotate` unloads an already-loaded module.
- measured (agent, throwaway session dir): `cs -queue add` prints nothing on success (exit 0); empty/whitespace -> exit 1 `Error: cs -queue add needs a non-empty task`; multi-line now -> exit 1 `task bodies must be a single line (the queue's done log and listing are line-oriented)`.
- Contamination record: this conversation (bbc43868) saw the full golds of tab-title Q1-Q10 and first-paint Q1-Q10 (goldsmith returned them). Q11-Q22 of all keys and all held-out golds were never shown to any conversation.
- Leftover on ghost: dir `ci/wt-queue` (agent's worktree runs); harmless.

# 4. Primary Request and Intent

- Alex wants handoff quality driven up by measurement, "until we have the best results", with the old spec as a control and a rejection region set before data. After seeing the noise he accepted that the honest outcome may be "no winner".
- Side request this conversation, now shipped: `/queue` to queue tasks while Claude is busy, via the mods API; Alex asked to rename the mod rather than fold into `cs-rotate`.
- Durable intent (inherited): handoffs should carry facts correctly, not merely more of them; spec changes are measured, not argued.

# 5. Key Technical Concepts

- **Eval pipeline** (`.cs/research/handoff-eval/harness.py`, gitignored, machine-local): writers (opus, `claude -p --restricted --tools Read,Write --permission-mode acceptEdits`) distil `sources/<src>/core.txt` under a spec into `handoff.md`; successors (opus, Read only) answer the key's briefs from the handoff alone; a blind grader (fable, Read only) grades each answer CORRECT 1 / PARTIAL .5 / MUST_LOOKUP 0 / WRONG -1. Handoff score = mean over non-control briefs; a missed control voids it to -1. METRIC = 100 x mean over sources of (cand mean - ctrl mean); REJECT_BELOW = 100 x mean of 2 x sqrt(sd_c^2/n_c + sd_b^2/n_b).
- Every call runs in a sandbox under `/private/tmp/claude-501/handoff-eval/<run>/` (outside any repo) with `--strict-mcp-config --no-session-persistence --output-format json` and the cs env scrubbed (`SCRUBBED_ENV` in harness.py). Canary probe (`harness.py probe`) showed no repo/branch/project visible.
- **Out-of-tree state** (`~/.cache/handoff-eval/`, DO NOT READ from the loop conversation): `keys/<src>/briefs.json` (22 briefs each: Q1-2 control, Q3-8 + Q11-19 once, Q9-10 + Q20-22 trap), `heldout/test-races/{core.txt,source.json}`, `runs/<id>/` (handoffs, mapping.json, writes.json, scores.json, SUMMARY.txt), `baseline` (run id marker).
- Sources: `tab-title` (parent 524ba3e7, cut before line 5049, 475 KB, byte-identical to the old A/B core.txt), `first-paint` (be426d62, cut 2930, 270 KB), held-out `test-races` (655bde7e, cut 2206, 200 KB). Cut = last user `<command-name>/rotate</command-name>` line; only these 4 parents had one (others rotated by forced rotation).
- harness subcommands (read in source): `serialise <uuid> <dir>` cuts a parent transcript; `round [--writers N] [--control-writers N] [--sources a,b] [--control-from RUN] [--grader M]`; `verify` = the loop's Verify (first call makes a baseline, later calls 10 cand/source reusing the baseline's control); `verify --resume RUN` finishes a run whose grading died, reusing saved answers/grades; `rescore RUN [--baseline]` re-answers and re-grades a run's handoffs against current keys in a new run; `probe`.
- Power (measured sd ~.15): 10 cand vs 10 ctrl per source should give REJECT_BELOW ~9 on 20-brief keys (assumed from the formula, not yet measured).

# 6. Files and Code Sections

- `.cs/research/handoff-eval/harness.py`, `serialise.jq` (reproduces the old core.txt byte-for-byte), `specs/control.md` (= main's SKILL.md before 8474134), `sources/`, `PREREG.md` (design + Amendment 1). Gitignored; this machine only.
- `.cs/research/handoff-ab-2026-09-24/` (morning A/B assets; `succ/` now holds the 6 recovered successor sandboxes).
- `skills/rotate/SKILL.md`: the loop target (step 3). `tests/test_rotation.sh` pins its phrases.
- Shipped today on main (not pushed): `mods/cs/` (renamed from `mods/cs-rotate/`, `/queue` in `hooks/register.tsx`), `lib/75-launch.sh` (`export CS_BIN` every launch, ~line 310), `lib/55-queue.sh` (`_queue_require_single_line` ~line 79, shared by add/spawn/mail), `lib/01-manifests.sh` (`cs-rotate` in RETIRED_SKILLS), CHANGELOG Unreleased.

# 7. Problem Solving

- Handoff errors found and reported in the previous handoff's Successor report (appended to `2026-09-24-handoff-eval-autoresearch.md`): succ/ was not lost; prompts were recoverable from the parent transcript.
- Fable 429 mid-grading: made grading resumable instead of re-running writers.
- Noise too high for small edits: widened keys 10 -> 22 briefs; threshold 18 -> 10.5 at no writer cost.
- /queue agent correctly stopped when `CS_UPDATE_BIN` turned out to exist only with a pending update; Alex ruled CS_BIN always + retire CS_UPDATE_BIN + refuse multi-line tasks everywhere.

# 8. Pending Tasks

Native list (session-keyed, inherited):
- #671 [in_progress] Handoff eval harness + loop on skills/rotate/SKILL.md (this handoff's Next Step).
- #672 [completed] mod rename; #673 [completed] /queue.
- #554 [pending] PARKED: SessionStart notice for tool calls left pending.
- #606 [pending] POSTPONED: cs --remote via Remote Control.
Not in the native list:
- Release v2026.9.22 via `/release` (tag only after CI green on the release commit); main 29 ahead of origin.
- `cs -rm measure-wake` (asked yesterday, unanswered).
- Doctor warning "no shadow ref refs/worktree/cs/session/da093a8c-..." (not investigated).
- ghost leftover dir `ci/wt-queue` (harmless).

# 9. Current Work

- Nothing running: round 0, rescore, both gates, all agents finished; tmux `-L csqueue` killed; worktrees `wt-mod-rename` and `wt-queue` removed with their branches.
- main `5c49a75` installed, doctor drift OK.
- Uncommitted before this rotation: the narrative and the previous handoff's successor report; step 8 of this rotation commits them.

**Completeness:** written from live context, no compaction. Not carried: the per-brief golds (deliberately; contamination rule) and the verbatim agent reports (summarised in section 3).
