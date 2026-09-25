---
parent: 465be02e-d61d-4eea-9e06-1ebe62bd5ef4
created: 2026-09-25T07:59:54Z
purpose: Read the ghost gate for fix/handoff-prompt-rows, then merge both fix branches on Alex's say and install; report the real-key eval result and the peer's rotate-skill request
status: consumed
consumed_by: c5408bd8-9b38-4cdc-9c83-5583291b9f0e
---

# 1. Next Step

Two unmerged branches off main, both committed. Alex has NOT said "merge" yet; ask before merging (memory: plain branch = hand merge on Alex's "merge").

1. Check the ghost full gate for `fix/handoff-prompt-rows` (launched ~07:57Z via remote-tests.sh, detached on ghost@ghost):
   `ssh ghost@ghost 'tail -6 ci/claude-sessions/suite.log; echo "exit=$(cat ci/claude-sessions/suite.status 2>/dev/null)"'`
   - `exit=0` and "OK: all 68 suites passed" (count may differ) = green. Empty `exit=` = still running; poll in a background loop, never foreground sleep.
   - Non-zero: `ssh ghost@ghost 'grep -E "FAIL|failed" ci/claude-sessions/suite.log | head'`. Note: the ghost checkout is shared by both branches; a later sync overwrites it, so this reading is for fix/handoff-prompt-rows at 3f98ffc.
2. Ask Alex (one binary question is fine in prose): merge both branches?
   - `fix/scope-prompt-launch-mark`: be8b0ca (launch mark + red test) + 17f11be (10 s registration, docs, changelog). Ghost full gate 68/68 green (measured).
   - `fix/handoff-prompt-rows`: 18b5db9 (red test) + 3f98ffc (rows + %b origin fix + README/CHANGELOG).
3. On "merge": `git switch main && git merge --no-ff fix/scope-prompt-launch-mark && git merge --no-ff fix/handoff-prompt-rows` (both touch CHANGELOG.md Unreleased; resolve by keeping both entries), then `./build.sh`, full gate on ghost again for main: `bash /Users/alex.geana/.claude/plugins/cache/temp_git_1790252113609_dol317/scripts/remote-tests.sh --host ghost@ghost --repo . --cmd 'bash tests/run_all.sh'`, then `./install.sh`, `cs -doctor` drift check. Never push (memory: authority ends at a local merge).
4. Then raise the two open items below (peer request, eval next step) with Alex.

# 2. Settled and rejected

- Scope-prompt timeout: "Mark + raise to 10 s" | Alex picked "Mark + raise to 10 s (Recommended)" over "Early trace mark only", "Raise timeout only", "Leave it" | the killed run died before the hook's own clock started, so no in-hook tuning helps
- Launch mark only for env-launched sessions, builtins only, no mkdir | Claude decided | a fork before the trace would be the thing that stalls; walk-resolved sessions don't know their dir yet
- Handoff prompt keys stay letters y/r/n/d, not the collision menu's numbers | Claude decided, flagged to Alex (not yet answered) | muscle memory and piped-answer tests use the letters
- Handoff prompt without a pending handoff (`[Y/n]`) unchanged | Claude decided | Hyrum guard in test_prompt_unchanged_without_handoff
- Removed the `[Y/n/r/d]` pin from test_rotate_answer_consumes_pending_handoff | Claude decided, told Alex | display coverage moved to test_handoff_prompt_lists_one_answer_per_row
- Real-key rescore order b, c, a | advisor + Claude | b answers the question; a re-grades the same control
- keys-real built by 3 subagents (one per source), counts-only final message | handoff plan | contamination rule
- Peer request (long-running-operation section in rotate skill + release) NOT started | Claude | rotate spec changes are measured, not argued; real-key eval just showed A's gain doesn't hold
- claude-council missing capsule = stale process, no code fix | Claude, told Alex | pid launched 4 min before the cs-rotate->cs rename install

# 3. Conversation-only facts

IDS
- measured: branches `fix/scope-prompt-launch-mark` (be8b0ca, 17f11be) and `fix/handoff-prompt-rows` (18b5db9, 3f98ffc), both off main; main head before rotation 62a5284 (narrative commits 20430ae c60abda 43071e3 62a5284 all landed).
- measured: rescore runs: (b) 20260925T101240 = A's 161024 handoffs; (c) 20260925T102548 = held-out 204930; (a) 20260925T103600 = baseline 150723. Outputs /private/tmp/claude-501/real-{b,c,a}.out.
- measured: keys at ~/.cache/handoff-eval/keys-real/{tab-title,first-paint,test-races}/briefs.json, provenance in each work/provenance.md (this conversation never read them).
- measured: harness.py (gitignored, .cs/research/handoff-eval/) gained `--keys DIR` on rescore+verify; original at scratchpad/harness.py.orig (this conversation's scratchpad, dies with /private/tmp).
- measured: peer session that sent the rotate-skill request: uds:/tmp/cc-socks/49247.sock (claude session "claude", pid 49247).
- measured: claude-council claude pid 53826, launched Thu Sep 24 15:07:18; its /clear kill run: claude-release session transcript 5010fc30-f0e6-4f13-95bc-006198c24763.
- measured: remote-tests script: /Users/alex.geana/.claude/plugins/cache/temp_git_1790252113609_dol317/scripts/remote-tests.sh (--host ghost@ghost --repo . --cmd ...); result in ghost:ci/claude-sessions/suite.status.

READINGS
- measured: rescore (b) keys-real: tab-title cand .567 (sd .097, 26943 B) ctrl .529 (sd .062, 18822 B) +.037; first-paint cand .690 (sd .057, 27393 B) ctrl .723 (sd .075, 18632 B) -.033; REJECT_BELOW 6.62; METRIC 0.21. Quiz keys had METRIC 20.25.
- measured: rescore (c) held-out: cand -.005 (sd .857) ctrl .105 (sd .765) delta -.109; REJECT_BELOW 72.65; METRIC -10.91; voids cand 4/10, ctrl 3/10.
- measured: rescore (a) baseline: tab-title +.075 (cand .575 sd .119 vs ctrl .500); first-paint -.363 (cand .333 sd .746, 1 void of 5); REJECT_BELOW 39.06; METRIC -14.42.
- measured: keys-real counts: tab-title 14 (2 control/10 once/2 trap, 13 dropped); first-paint 17 (2/11/4, 14 dropped); test-races 13 (2/8/3, 7 dropped). No source handoff had a Successor report.
- measured: scope-prompt standalone at load 35: /wrap 676-915 ms wall, code prompt 1551-1769 ms (scratchpad/sp-time.sh vs ~/.claude-sessions/measure-wake).
- measured: exec latency at load 19: /usr/bin/true median 57 ms, max 109; bash -n parse median 73, max 204; 0 over 1 s.
- measured: top CPU at ~10:27: opendirectoryd 80%, Unity 74%, STExtractionService 62%, WindowServer 46%, JumpCloud EndpointSecurity 30%, Arq 29%; 14 cores.
- measured: plugin UserPromptSubmit hooks on the killed /wrap answered at 07:22:07.417 (2.27 s after the 07:22:05.149 prompt).
- measured: ghost full gate on fix/scope-prompt-launch-mark: "OK: all 68 suites passed", exit 0.
- measured: test_rotation on ghost with red test only: 115/116, failing test_handoff_prompt_lists_one_answer_per_row.
- measured: local (rule slip) test_scope_prompt 53/53, test_install 55/55, test_docs 6/6 on fix/scope-prompt-launch-mark; shellcheck -S error clean.

ERRORS
- measured: claude-release /wrap: attachment `{"type":"hook_cancelled",...,"command":"~/.claude/hooks/cs/scope-prompt.sh","durationMs":5122,"timedOut":true,"timeoutMs":5000}`; that session's scope-prompt.trace has no line after 09:59 local.
- measured: first harness edit: `SyntaxError: name 'KEYS' is used prior to global declaration` (fixed by moving `global KEYS` to top of main()).
- measured: git briefly printed only "You have not agreed to the Xcode license agreements..." then worked again minutes later (transient).
- measured: render of the old prompt showed `\033[38;2;120;108;98m(from another checkout)\033[0m` literally (fixed %s->%b in 3f98ffc).

USER
- user: "[Image #3] this still happens when the cpu usage is high" (scope-prompt 5s timeout on /wrap).
- user: picked "Mark + raise to 10 s (Recommended)".
- user: "[Image #4] did we break something? I don't see the capsule anymore" (claude-council).
- user: "[Image #5] we need to improve this section for the visiblity of the options maybe one on each row, similar to what we do when an existing session is already running".
- inherited (peer, not Alex): add an optional "long-running operation" section to the rotate skill (goal, immutable state, surfaces, phase, failure policy, stop conditions), borrowed from openclaw release-handoff-template (MIT), "test it, and release through your normal flow".

UNVERIFIED
- assumed: what stalled the killed scope-prompt run before its clock (exec gating by EndpointSecurity/opendirectoryd load); the new launch mark will tell next time.
- assumed: claude-council's capsule vanished now because something ~09:39 made the process re-read mods; not measured.
- assumed: ESC via `printf '\033' | script -q` did not cancel in my render because of pty input handling; not investigated (existing pty test covers ESC).
- CONTAMINATION (measured): the test-races key builder's final message named the topic of one gold (Q11 uses the parent's task #642 text, core.txt line 1836).

STATE
- Running: ghost full gate for fix/handoff-prompt-rows (see Next Step 1). Nothing else running.
- Uncommitted: none after this rotation's commits. Worktree on main.
- Promised, not done: merge + install both branches (awaiting Alex); decision on the peer's rotate-skill request; CHANGELOG line claiming A's "20 points" not reworded (Alex's call); held-out keys-real control briefs need rebuilding before that number means anything; v2026.9.22 release still open; `cs -rm measure-wake` unanswered.

# 4. Primary Request and Intent

- Inherited: measure handoff quality by what real successors needed (real-key rescore) — done; result: A's quiz gain does not hold.
- Alex (this conversation): stop the scope-prompt 5 s timeout under load; make the pending-handoff launch prompt show one answer per row like the already-open menu.

# 5. Key Technical Concepts

- scope-prompt's in-hook budget clock starts after the library parse/source/resolve; the registered timeout counts everything including spawn. New `launch` trace line (absolute epoch ms) is written before that; `launch` with no `start` = stalled in first forks, no `launch` = never ran.
- Eval scoring: harness.py, METRIC = 100 x mean(cand - ctrl), REJECT_BELOW = 2 SE; a missed control brief voids a handoff to -1.

# 6. Files and Code Sections

- hooks/scope-prompt.sh top: launch mark block (case on EPOCHREALTIME, `_launch_local`, printf to scope-prompt.trace); tests/test_scope_prompt.sh `test_stage_trace_marks_a_run_killed_before_the_trace_opens` (blocking dirname stub).
- install.sh.in:596 `_merge_cs_hook UserPromptSubmit scope-prompt.sh 10`; docs/hooks.md, docs/session-layout.md, CHANGELOG Fixes.
- lib/75-launch.sh `_resume_menu_row` + the pending-handoff branch (y resume / r from handoff / n fresh / d discard, `    ›` prompt); tests/test_rotation.sh `test_handoff_prompt_lists_one_answer_per_row`; README example; CHANGELOG Changed + Fixes.
- .cs/research/handoff-eval/harness.py `--keys` (gitignored).

# 7. Problem Solving

- Timeout: traces across all sessions showed killed runs stopping at random stages with <=2.5 s in-hook; the real /wrap kill left no trace line at all -> pre-clock stall; machine load (opendirectoryd, EndpointSecurity) not cs.
- Held-out real-key number unusable: 7/20 voids -> the key's control briefs are not plainly in every handoff.

# 8. Pending Tasks

- #680 [in_progress] Real-successor keys + rescore: rescores done; report delivered; close after Alex reads it.
- #684 [pending] Report + successor report + commit handoff: successor report appended to 2026-09-25-handoff-eval-real-keys.md (committed with this rotation).
- #685 [pending] scope-prompt launch mark + 10 s (fix/scope-prompt-launch-mark): ghost green, awaiting merge.
- #686 [pending] Pending-handoff prompt rows (fix/handoff-prompt-rows): ghost gate running, awaiting merge.
- #679 [pending] Field check of 5 ledger rotations or 2026-10-15.
- #554 [pending] PARKED. #606 [pending] POSTPONED.

# 9. Current Work

- On main, both fix branches unmerged; ghost gate for fix/handoff-prompt-rows in flight; no local processes running.

**Completeness:** written from live context at ~77%, no compaction.

# Addendum (after rotation armed)

- measured: the ghost full gate for fix/handoff-prompt-rows at 3f98ffc FAILED 1/68: test_rotation 114/116. `test_discard_answer_dismisses_pending_handoff` pinned the old text "d = discard handoff"; `test_discard_does_not_offer_the_retired_handoff` matched "stays pending" in the new n row.
- Fix 7896ce2 on fix/handoff-prompt-rows: n row now reads "fresh conversation; the handoff waits for later" (lib, test, README); the d pin now matches the row `    d  discard         retire the handoff, then resume`. Ghost test_rotation 116/116 (measured).
- So Next Step 1 changes: the branch has NOT had a green FULL gate at 7896ce2. Run the full gate on ghost for fix/handoff-prompt-rows first (check out the branch locally; remote-tests.sh syncs the working tree), then ask Alex about merging.
