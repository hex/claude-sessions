---
parent: 4af1b056-f98e-45a9-b6c7-ccbb98d68352
created: 2026-09-25T06:44:06Z
purpose: Build real-successor answer keys for the handoff eval and rescore the existing control, A and held-out handoffs against them
status: consumed
consumed_by: 465be02e-d61d-4eea-9e06-1ebe62bd5ef4
---

# 1. Next Step

Goal (Alex's pick, verbatim option: "Rescore with real keys (Recommended)"): replace the goldsmith-written quiz keys with keys built from what the REAL successor conversation of each source actually had to look up, re-derive or got wrong after reading its handoff, then rescore the EXISTING handoffs (no new writers) and report per source: candidate A vs control.

**Contamination rule, unchanged:** this conversation must never read anything under `~/.cache/handoff-eval/` (keys, heldout, runs, grades). Build the new keys with a subagent that writes them and returns COUNTS ONLY (never briefs or golds in its final message). Read harness results only from the summary lines of stdout (`grep -E "^# |^REJECT_BELOW|^METRIC|^rc="`); an error path can still print other text, so filter to those lines even on failure.

Steps:
1. Check nothing is running first: `pgrep -fl harness.py` (a live process = a round in flight, do not start another) and `ls -t /private/tmp/claude-501/handoff-eval/ | head -3`.
2. Harness change (`.cs/research/handoff-eval/harness.py`, gitignored, this machine only): add a `--keys DIR` option (default the existing `KEYS = EVAL_HOME / "keys"`, line ~37; keys are loaded at line ~161 `json.loads((KEYS / name / "briefs.json").read_text())`) to `rescore` (cmd_rescore, line ~333) and `verify --resume`, so a rescore can grade against `~/.cache/handoff-eval/keys-real/<src>/briefs.json`. Same brief schema as the old keys (id, kind, brief, gold, why_hard; kinds control/once/trap, Q1-Q2 control). Keep grader fable.
3. Dispatch ONE key-building subagent per source (or one for all three), each told: read the source's handoff (the real one the successor got) and the real successor transcript; list every fact the successor had to look up, re-derive, got wrong, or asked the user for, within its first ~30 turns, plus its `## Successor report` if the handoff has one; turn each into a brief with a gold taken from the parent transcript/core (the fact as it was true at the cut); add 2 control briefs (facts plainly in every handoff); write `~/.cache/handoff-eval/keys-real/<src>/briefs.json`; final message = counts per kind only. The mapping (read from handoff frontmatter via git, measured 2026-09-25):
   - tab-title: parent 524ba3e7 -> handoff `.cs/handoffs/2026-09-23-finish-tab-title-panes.md` -> real successor `0924fa25-2e31-489a-a100-b8df76b380f7` (6514854 B)
   - first-paint: parent be426d62 -> `.cs/handoffs/2026-09-18-statusline-first-paint.md` -> successor `601bd3d4-a5e2-4f9a-a65e-1587ba90a07e` (4543233 B)
   - test-races (held-out): parent 655bde7e -> `.cs/handoffs/2026-09-17-merge-parallel-test-races.md` -> successor `7cc98cc6-b428-41cd-b399-a06757e3d319` (4087475 B)
   Transcripts: `~/.claude/projects/-Users-alex-geana--claude-sessions-claude-sessions/<uuid>.jsonl`. The handoffs may be pruned from the tree; read them with `git log --all -- <path>` + `git show <sha>:<path>`.
4. Rescore, one run at a time, each in the background with output to its own file in `/private/tmp/claude-501/`: (a) `python3 harness.py rescore 20260924T150723 --keys ~/.cache/handoff-eval/keys-real` (baseline: round 0's 5 current-spec + 10 control handoffs per loop source), (b) `rescore 20260924T161024 --keys ...` (A's 10 per loop source; that run's control arm is reused from the baseline), (c) `rescore 20260924T204930 --sources test-races --keys ...` (held-out A vs its own 10 control). Before launching, confirm how `rescore` copies a verify run's reused control (it copies handoffs/writes/mapping; check that A's run folder holds the control handoffs or points at them) — read in source, do not assume.
5. Report to Alex per source: A vs control delta, REJECT_BELOW, and whether the real-key ranking agrees with the quiz-key ranking (A +20.25 loop, +9.00 held-out). State the bias below plainly.

Known bias to say out loud: the real successors read OLD-spec handoffs, so the keys cover what those handoffs missed; a spec that carries other facts gets no credit for them. It measures "does A carry what real successors needed", not overall quality.

# 2. Settled and rejected

- Next eval = rescore with real-successor keys | Alex picked "Rescore with real keys (Recommended)" 2026-09-25 | cheap (no new writers), tests whether A's +20 holds on real needs
- Full rig (forked live-context writers via `claude --resume <uuid> --fork-session`, real keys, ~25 sources incl. Skill(rotate) cuts, 5 held out) | offered, not chosen now | a few days of harness work + ~one usage window per round; revisit only if the rescore says A's gain is real
- Field data only | offered, not chosen as the next step | still running in parallel as task #679 (review after 5 ledger rotations or 2026-10-15)
- Rotate before building the rescore | Alex: "yes" | this conversation read held-out grader text (below) and is at ~57% context
- Candidate A (verbatim fact ledger) merged to main 2bfd619 + installed | Alex: "Merge A with the caveat" | loop +20.25 (REJECT_BELOW 5.58), held-out +9.00 < 10.90 (pre-registered rule NOT met); CHANGELOG says held-out inside noise
- Candidates B (fill-in template, 842b994, +8.75) and C (main + 20-question self-test, e2a3d29, +8.00) | discarded by the pre-registered keep rule | both below best kept 20.25
- Alex's mis-click "Stop at A" | Alex: "i choose by mistake stop at A, ask me again" -> "Score C, then held-out" | C was scored
- Grader stays fable | inherited ruling | keep grades comparable
- `/autoresearch` plugin | never used as driver | 2-3 hand-written candidates made a manual loop simpler; Alex asked "what did the autosearch provide?" and was told: nothing directly
- SessionEnd index fix = one awk pass | Alex: "One awk pass (Recommended)" over background/both/drop | same output, 26.92 s -> 0.15 s
- Rotate prune gains a tracked-by-git condition before the release | Alex: "Fix the prune gap first" | an untracked gitignored handoff would have been deleted as the only copy
- v2026.9.22 release | not done yet | Alex chose the prune fix first; release is still open

# 3. Conversation-only facts

IDS
- measured: eval runs: baseline 20260924T150723; A 20260924T161024; B 20260924T165615; C first try 20260924T182113 (abandoned, writer phase died), C 20260924T201123; held-out 20260924T204930. Run outputs: /private/tmp/claude-501/{cand-a,cand-a-resume,cand-b,cand-b-resume,cand-c,cand-c2,heldout-a,heldout-a-resume}.out
- measured: commits today on main: 2bfd619 (merge A), 9124596 (A changelog), 16c7acd + bafed28 (prune fix + red test, merged), 98e9a14 (index awk fix, merged), 5acfa02, bbce419 (narrative), 184009a (successor report on the bold-candidates handoff), 121f066, 59d7083 (memory), d521ae6 (summary). main head at handoff time bbce419.
- measured: `git rev-list --count origin/main..main` = 59 at 06:44Z; nothing pushed; v2026.9.22 unreleased.
- measured: native tasks: #679 field check (pending), #680 this Next Step (pending), #554 parked, #606 postponed.
- measured: field-check log `.cs/research/handoff-field-log.md` (gitignored): baseline wrong 1, lookup 4, friction 2 over 3 pre-ledger rotations; decision rule set before data.
- measured: throwaway session `~/.claude-sessions/measure-wake` still on disk; used today for SessionEnd timing (`/private/tmp/claude-501/se-time.sh` times each SessionEnd hook with a fake event from it).

READINGS
- measured: A loop: tab-title cand .688 sd .041 (26.9 KB) vs ctrl .465; first-paint cand .750 sd .042 (27.4 KB) vs ctrl .568; METRIC 20.25, REJECT_BELOW 5.58.
- measured: B: METRIC 8.75, REJECT_BELOW 6.86. C: tab-title +.110, first-paint +.050, METRIC 8.00, REJECT_BELOW 8.35.
- measured: held-out test-races A .613 sd .124 (24.8 KB) vs ctrl .522 sd .120 (19.6 KB), METRIC 9.00, REJECT_BELOW 10.90, 0 voids; per-handoff scores on the 0.025 grid (so the held-out key is ~20 scored briefs, not thin).
- measured: control re-grades drift between rounds (.465 -> .445 tab-title; .568 -> .547 first-paint).
- measured: SessionEnd per-hook times (fake event, measure-wake, before fix): claude-status 1.68 s, cs 6.93 s, codex 0.23 s, design-and-refine 0.04 s, skillopt 0.11 s. Index loop alone: 26.92 s old vs 0.15 s new on 138 sessions under load. After install cs hook 0.78-2.69 s (load avg 14.88/35.00/25.97); traced run total 1.02 s with no line > 0.15 s.
- measured: ghost gates: test_rotation 115/115 (prune fix), test_hooks 151/151 (index fix), full run_all 68/68 on main after each merge.
- measured: `cs -usage` 5h window hit ("You've hit your session limit · resets 8:10pm") during C's first round; Fable ran out of credits twice mid-grading (Alex topped up).

ERRORS
- measured: `harness.py verify` round 161024 and 165615: fable grader `"result":"You're out of usage credits. Switch to another model, or manage usage credits at claude.ai/settings/usage..."`; fixed by `verify --resume <run>` once Alex said Fable was back.
- measured: round 182113 writer: `"result":"You've hit your session limit · resets 8:10pm (Europe/Bucharest)"` after 6/20 writers; `verify --resume` only re-scores (cmd_verify -> score_run), so the run was abandoned and C re-run fresh.
- measured: held-out round: `RuntimeError: grader output malformed for test-races/h4` — the harness then printed 300 chars of grader text. Resume graded it cleanly. The error path now prints only counts and the grader.json path (harness.py, grader check).

USER
- user: "the results are not that great though. no? let's rotate then use /autoresearch:autoresearch until we have the best results" (earlier conversation, inherited).
- user: "fable is on now" / "try now, fable is back" (resume triggers).
- user: "i choose by mistake stop at A, ask me again".
- user: "so what did the research provide?" then "let's do it" (field check), "so? what next?" -> "Fix the prune gap first", image of "running SessionEnd hooks… 5/6 · 10s" + "is this from us?" -> "One awk pass (Recommended)".
- user: "what did the autosearch provide?" then "how can we do a more relevant run? with actual results?" -> "Rescore with real keys (Recommended)", then "yes" to rotating.

UNVERIFIED
- assumed: real-successor keys will separate A from control at all; the successors read OLD handoffs, so keys may favour facts A also lacks.
- assumed: the three successor conversations each looked things up within their first ~30 turns in a way a subagent can recover from the JSONL; not checked.
- assumed: `rescore` works on a verify run whose control arm was reused from the baseline (not read in source this conversation).
- CONTAMINATION (measured, recorded in PREREG.md): this conversation read held-out grader "why" text for test-races Q1-Q2 via the malformed-grader error. The successor has not seen it.

STATE
- Nothing running: no harness process; all rounds finished; ghost gates done.
- Uncommitted: none beyond this handoff at write time (narrative committed in bbce419; step 8 commits the rest).
- Promised, not done: v2026.9.22 release (Alex deferred behind the prune fix, then SessionEnd fix, then this eval); `cs -rm measure-wake` never answered.

# 4. Primary Request and Intent

- Alex wants handoff quality measured by results that matter, not a quiz: "how can we do a more relevant run? with actual results?". The rescore with real-successor keys is the cheap first answer; the full forked-writer rig is the follow-up only if it says A's gain is real.
- Durable (inherited): spec changes are measured, not argued; the honest outcome may be "no winner".

# 5. Key Technical Concepts

- Harness scoring (read in source, harness.py): CORRECT 1 / PARTIAL .5 / MUST_LOOKUP 0 / WRONG -1 over non-control briefs; a missed control voids a handoff to -1; METRIC = 100 x mean over sources of (cand - ctrl); REJECT_BELOW = 100 x mean of 2 SE. Keys and runs live in `~/.cache/handoff-eval/` (never read from the scoring conversation).
- PREREG: `.cs/research/handoff-eval/PREREG.md` (gitignored) has the design, Amendment 1, the contamination event and today's results.
- Field check: `.cs/research/handoff-field-log.md` (gitignored), task #679.

# 6. Files and Code Sections

- `skills/rotate/SKILL.md`: step 3 is now the fact ledger (A), plus the 5th prune condition `git ls-files --error-unmatch -- <file>`.
- `hooks/session-end.sh`: index.md built by one awk getline loop over names passed via `ENVIRON["CS_INDEX_NAMES"]`; `tests/test_hooks.sh` `test_index_dashes_unfilled_columns`; equivalence artifacts in this conversation's scratchpad `index-equiv/` (dies with /private/tmp).
- `tests/test_rotation.sh`: `test_rotate_skill_prunes_only_tracked_handoffs`.
- `.cs/research/handoff-eval/harness.py`: needs the `--keys DIR` option (Next Step 2).

# 7. Problem Solving

- Fable credit exhaustion and the 5h limit interrupted rounds three times; grading resumes, writing does not.
- The slow `/clear` came from cs's own SessionEnd index loop (~6 forks x 138 sessions); traced with timestamped xtrace (xtrace inside `{ } 2>/dev/null` is hidden, so the gap appears on the next visible line).

# 8. Pending Tasks

- #680 [pending] Real-successor keys + rescore (this Next Step).
- #679 [pending] Field check of 5 ledger rotations or 2026-10-15.
- #554 [pending] PARKED: SessionStart notice for tool calls left pending.
- #606 [pending] POSTPONED: cs --remote via Remote Control.
- Not in the native list: release v2026.9.22 (59 commits ahead of origin; tag only after CI green on the release commit); `cs -rm measure-wake` unanswered; doctor warning about the missing shadow ref for da093a8c not investigated.

# 9. Current Work

- Nothing running. main bbce419 installed (rotate skill with the ledger + prune fix, session-end index fix), doctor drift OK at last check.

**Completeness:** written from live context, no compaction. Not carried: per-handoff score tables (in the run .out files under /private/tmp/claude-501/, which a reboot clears) and any gold text (deliberately).

## Successor report

- Re-derived (the handoff flagged it UNVERIFIED): whether `rescore` of A's run 161024 includes the control arm. Read in source: `cmd_round --control-from` copies the baseline's `ctrl*.md` into the run's own `handoffs/` and lists them in `writes.json`/`mapping.json`, and `cmd_rescore` copies the whole tree, so one rescore grades A and control together.
- Not in the handoff: `harness.py serialise` cuts before the LAST `/rotate`, which is the wrong cut for a successor transcript. The key builders ran `serialise.jq` directly on the successor JSONL instead.
- Not in the handoff: the line numbers it gave (KEYS ~37, load ~161, cmd_rescore ~333) were right. `cs -usage` printed no limit lines when I checked the budget before launching, so the Fable budget was unknown.
- Found wrong: none in the handoff. The held-out key built from it has defective control briefs (7/20 handoffs voided), which is a key-building problem, not a handoff one.
