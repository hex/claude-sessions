---
parent: bd55ba81-293a-49f2-a154-e0666426e611
created: 2026-09-02T10:55:07Z
purpose: Apply the three Fable 5.1 prompting-page changes: two-voices and asymmetric-length rules in the rotate skill, scope block in the queue drain prompt
status: consumed
consumed_by: 1e2d2b00-99bd-407d-a484-1613dc9525f4
---

## 1. Next Step

Three small changes, each TDD (failing test first), then the full gate, then commit. `main` is clean at the v2026.9.4 release commit `e3dd2de`; nothing is in flight.

**A. Two rules into `skills/rotate/SKILL.md`**, under the body rules (the bulleted block that starts with "Redact"; the same place "Say how each behavioural claim was established" was added yesterday):

1. Two voices. Source, quoted from Anthropic's Fable 5.1 prompting page (measured: fetched 2026-09-02, https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1, section "Tell the model what to preserve in compaction summaries"):
   > Weight the two voices differently: keep what the user said, asked for, shared, or established carefully and close to their own words; your own explanations and reasoning can be condensed much further, to what they concluded or produced
   The skill has NO rule about the user's own words today (grep for `own words|verbatim|user said` returns nothing). A Fable review yesterday observed the best handoffs quote Alex's corrections verbatim in the request section; that is emergent behaviour, make it an instruction.
2. Asymmetric length. Same source:
   > Be complete on these even at the cost of length; keep everything else concise.
   Today the skill's only length instruction points at more ("Length spent on them is not padding; it is how many of them survive", line ~86). This sentence is its counterweight, and it is the "asymmetric budget" the council recommended yesterday, stated without a number. Alex has settled that there is NO byte cap on handoffs (see Settled below); this rule is the shape that fits.

   Pin each in `tests/test_rotation.sh` next to `test_rotate_skill_requires_provenance_on_claims` (search that name; the pattern is `assert_file_contains "$skill" "<phrase on one line>"`). Pin a phrase that exists only in the new text, on ONE line — `assert_file_contains` is a BRE matcher and a phrase wrapped across lines never matches (bitten twice yesterday: a `.` standing in for `**`, and a quote-within-quote).

**B. Scope block into the walk-away queue drain prompt.** `hooks/narrative-reminder.sh` around line 578 emits the next task as `Task: $NEXT` inside a Stop `block` reason with no scope guidance. Add, after the task text, the substance of the page's "Keep changes and tests to what the task asks for" instruction — measured source text:
   > If, while working or testing, you find a pre-existing bug, a performance concern, or behavior the task doesn't mention, don't fix, optimize or extend it in this change unless the requested behavior cannot work without it; report it as a follow-up in your summary. Where the task is ambiguous, implement the reading its wording and the surrounding code most directly support, state that assumption in your summary, and don't build for the other readings as well. ... Commit tests only where the task asks for them or this repository already keeps tests for this kind of change ... This is about extras only: implement every behavior the task asks for, completely.
   Keep it to two or three sentences; the reason is a hook payload. Pin it in `tests/test_queue.sh` (find the test that asserts the `Task:` reason shape). A queue runs with nobody watching, which is exactly the case the page wrote this for.

**C. Gate and commit.** `/bin/bash tests/run_all.sh` (63 suites; run under `HOME=<empty dir>` with `GIT_AUTHOR_*` unset for the full bare-runner check, see Key Technical Concepts), then `./build.sh` LAST before staging (bin/cs is assembled; CI's build-sync fails on drift), one commit per change or one combined, push, and confirm the 5 CI jobs on the pushed SHA. Then `./install.sh` so the live skill and hook match.

## 2. Settled and rejected

- DECIDED: no byte cap on handoffs, ever. Alex, yesterday, after Fable + an 8-provider council both said no. Reason: the narrative's 512 KiB budget works because rotation archives the overflow; a handoff has no overflow destination, so a cap drops facts the skill cannot rank. Do not re-open. The asymmetric-length rule in Next Step A is the accepted shape.
- DECIDED: the rotate skill pins `model: fable` (the family alias), not `claude-fable-5`. A point-release pin downgraded a 5.1 session; test pins `^model: fable$`. Same question is open for `commands/{wrap,sweep,summary}.md`, which pin `claude-opus-5` — not decided, not in scope.
- DECIDED: arming the rotation marker is the LAST step of the ritual (lib/75-launch.sh disarms it on Y/n/Enter and nothing re-arms). A Fable review recommended arming early; a second review reversed it after reading the launch prompt. Settled, tested by `test_rotate_skill_arms_last`.
- DECIDED: pass two of the handoff APPENDS and lands as a second commit, never a Write and never an amend. Fable 5.1 rewrites whole files more than Fable 5 (page section "Prefer targeted edits"), which is a second reason for the rule.
- REJECTED: moving cs's commands and skills under a `cs/` subdirectory like the hooks. Measured on 2.1.258: a commands subdir becomes a namespace (`/cs:wrap`), a skills subdir hides the skill entirely.
- REJECTED: naming which model reviewed anything in outward text (PR comments, release notes). Alex: "Don't say anything about fable". Memory entry `feedback_outward_prose_bar.md`.
- NOT APPLICABLE from the same page, checked: effort sweeps, thinking display, append-only history binding, search triggering, vision crop tools, subagent non-blocking — all API-caller concerns; Claude Code is the caller, cs is not. The batching nudge and the progress-update line are already injected by the Claude Code harness (seen in this session's own system turns).

## Conversation-only facts

- The page's six-item preservation list maps onto the rotate skill's sections almost one to one: (1) problems and resolutions = Problem Solving, (2) options tried/set aside = Settled and rejected, (3) decisions "stated exactly" and (6) exact details = the restate-what-cannot-be-recovered rule, (4) where things stand = Current Work, (5) open items = Pending Tasks. The two-voices rule and the asymmetric-length sentence are the only two items with no counterpart. Inherited from my own read of both texts, not measured.
- Fable 5.1 page also says compacting early "may no longer be the right cost-intelligence tradeoff" because cache reads are cheaper. Not actionable for cs (the 80% nudge threshold is about Claude Code's context, not API cost), noted so nobody proposes raising `CS_ROTATE_NUDGE_CTX` on that basis without measuring.
- Context at handoff time: 81%. Written from live context, not compacted; nothing cut short.

## 3. Primary Request and Intent

Alex asked, verbatim: "anything valubale for our project here: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1 ?" I answered three things apply (the two skill rules and the queue scope block) and asked whether to apply them; the 81% context nudge fired and Alex chose "Rotate, purpose: apply the three changes". So the intent is: make those three edits, nothing wider. The page is mostly API-caller guidance; do not go looking for more to apply.

## 4. Key Technical Concepts

- **`assert_file_contains` is a BRE matcher** (memory `project_assert_file_contains_regex.md`): pin literal phrases on one line; escape `*`, `[`, `.` or they silently never match.
- **bin/cs is assembled from lib/*.sh by `./build.sh`**; the hook files under `hooks/` are standalone (not assembled). `narrative-reminder.sh` is a hook, so edit it directly; the skill is a plain markdown file. Only `lib/` edits need a rebuild — none planned here, but run build.sh anyway before staging (memory `project_lib_bin_build_drift.md`).
- **Test isolation lives at `tests/test_lib.sh` source time** (memory `project_test_lib_source_time_isolation.md`): HOME, PATH to bin/, git identity. Bare-runner check: `env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL HOME=$(mktemp -d)/home /bin/bash tests/run_all.sh` — measured 63/63 yesterday.
- **Floor is /bin/bash 3.2 + BSD userland**; run suites with `/bin/bash tests/<suite>.sh`, not bare `bash` (5.x here). `echo -e '\uXXXX'` prints literally under 3.2; use literal glyphs.
- **The queue drain** is the Stop path in `hooks/narrative-reminder.sh`: `_qlen`, `queue.state` armed|draining, and the `block` reason carrying `Task: $NEXT`. Its tests are `tests/test_queue.sh` and `tests/test_queue_supervision.sh`.
- **Skill frontmatter `model:`** accepts family aliases (`fable`, `opus`, `sonnet`, `haiku`); measured in bundle 2.1.258 yesterday.

## 5. Files and Code Sections

- `skills/rotate/SKILL.md` — body rules block, lines ~67-111 (bullets: Redact; Reference committed work; Say how each behavioural claim was established; Say what you could not carry). Add the two new bullets there. Cross-references use step numbers 1-11; do not renumber steps.
- `tests/test_rotation.sh` — skill pins live near line ~140-200 (`test_rotate_skill_has_a_home_for_rejected_alternatives`, `..._requires_provenance_on_claims`, `..._puts_the_next_step_first`, `..._arms_last`, `..._pins_the_strongest_model`); register new tests in the `run_test` list right after `run_test test_rotate_skill_pins_the_strongest_model`. Suite was 98/98.
- `hooks/narrative-reminder.sh` — the drain block reason, `grep -n 'Task: \$NEXT'` (~line 578). Every command in FileChanged/Stop branches is guarded for errexit; keep the edit inside the existing jq string.
- `tests/test_queue.sh` — find the test asserting the reason contains `Task:`; add the scope assertion beside it.
- `.cs/memory/narrative.hex-users-noreply-github-com.md` — lab notebook, ~110 KB, machine-local (gitignored). Yesterday's entries cover every decision above in more depth.

## 6. Problem Solving

Nothing debugged for this task yet. Context inherited from the last two days that will bite if forgotten: a test written to reproduce a defect must be seen RED before its pass means anything (two green-on-first-run tests yesterday were vacuous); and a review claim about "every suite" is a population claim — count the consumers (`grep -l '^setup()' tests/*.sh` → 22 override setup()).

## 7. Pending Tasks

1. The three changes in Next Step (A1, A2, B), then C.
2. Not this task, noted: decide whether `commands/{wrap,sweep,summary}.md` should pin `opus` (alias) instead of `claude-opus-5`, by the same argument as the rotate pin.
3. Not this task, noted: the test gate's job cap (`tests/run_all.sh` `detect_jobs`, cap 10 on a 14-core box) was never measured on an idle machine; the serial timing table showed no long pole (top suite 218 s of 2711 s).

## 8. Current Work

`main` == `origin/main` at `e3dd2de` (Release v2026.9.4) plus this handoff's commits on top. v2026.9.4 is released with all 12 signed assets (the release workflow needed one rerun after a runner DNS failure on the arm64 leg). PR #11 merged. Working tree clean apart from this handoff. Local install is on 2026.9.4. Session model was switched to Fable 5.1 so `/code-review` runs on it; that command inherits the session model and has no model parameter.
