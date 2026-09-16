---
parent: 1654089a-200d-4ea6-a7c5-c6891366149a
created: 2026-09-16T07:40:00Z
purpose: finish the #628 gate (live run 2, Codex round 3, ghost re-run), take the merge decision to Alex, then the held release #622
status: unconsumed
---

## 1. Next Step

Two measurements were still running when this conversation rotated. Collect
them first, in this order, before anything else:

1. **Live run 2** — a throwaway cs session `grace-live2` in a tmux window,
   driven by `<scratchpad>/grace-live2/drive.sh`, knob `CS_ROTATE_FORCE_CTX=10`.
   Its pane id is in `<scratchpad>/grace-live2/pane.txt`, captures in
   `<scratchpad>/grace-live2/*.txt`, a change-log in `timeline.txt`.
   `<scratchpad>` is the CONVERSATION-scoped directory of the parent UUID
   above: `/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/1654089a-200d-4ea6-a7c5-c6891366149a/scratchpad`.
   **A rotation does not give you a new scratchpad — it is keyed on the
   session, and the path above stays readable.** (MEASURED this conversation:
   the previous rotation's scratchpad was gone, which is why the spike driver
   had to be rewritten; so verify the path exists and, if it does not, the
   run is lost and must be re-driven.)

   What it is measuring, and what "pass" looks like: turn 1 ("reply with the
   single word ok") ended at **7%**, below the knob at 10 → **no force**, band
   read `1: rotate this conversation · █░░░░░░░░░ 7%` (MEASURED, captured).
   Turn 2 reads `tests/test_hooks.sh` and `tests/test_install.sh` in full to
   push context past 10. Expected, in order: `❯ /rotate` appears by itself →
   the rotate skill writes, commits and arms a handoff → its turn ends → the
   capsule reads `1: /clear and continue from the handoff · /clear in 20s`
   counting down → at zero `❯ /clear` → SessionStart kicks the wake turn →
   **the wake turn ends and does NOT force a second rotation** (that last one
   is the loop guard, and it is the only part no earlier run has measured).
   Kill the pane by the captured id, `cs -rm grace-live2 --force </dev/null`,
   copy the captures to `.cs/research/spike-rotate/grace-evidence/live2/`.

2. **Codex round 3** — running read-only against the final tree, output at
   `<scratchpad>/codex/out3.md` (prompt at `prompt3.md`, log at `run3.log`).
   It was asked to measure closure of its round-2 leftovers and to attack the
   new adoption guard, plus check `tests/test_lib.sh`'s new source-time block
   against every suite that runs `hooks/session-start.sh`. Triage its
   findings; one fix round if material, then re-run it.

3. **Ghost re-run** — the last ghost run was on `ae3f557` and reported 66/67;
   the one red was `test_mod_rotate.sh`'s validate pin, fixed in `9ff59cb`.
   Re-run on the final sha:
   `bash /Users/alex.geana/.claude/plugins/cache/hex-plugins/claude-tmux/2026.9.1/scripts/remote-tests.sh --host ghost@ghost`
   from the repo root, then poll
   `ssh ghost@ghost 'test -s ci/claude-sessions/suite.status'` from a Monitor
   until it exists and read `suite.status` (the exit code IS the verdict).
   `--host ghost` alone FAILS: there is no host store on this machine
   (MEASURED: "no host store at .../remote-hosts.json"), the literal
   `ghost@ghost` works.

Then take the merge to Alex with **AskUserQuestion**, polish-first as the
first option (his pick 3/3 at recent gates). Name in the question the
decisions he has not yet seen, all of them mine, not his:

- `GRACE_SECONDS = 20`, a constant with no env knob.
- The knob is a percentage; a non-numeric value means off.
- ANY prompt entering the session cancels the countdown, whatever its origin
  (composer, peer, task-notification, bridge, plugin).
- A countdown reaching zero while a turn runs or a survey holds the band
  stops and leaves the button rather than waiting for idle.
- The adoption guard: the conversation the mod meets at load is forced
  whatever context it starts at (a resume at 72% with the knob at 70 IS the
  case he asked for); only a conversation born of a `/clear` in that process
  is judged by its first turn and refused if it already starts past the line.
- #630 (the test-harness tmux leak) landed on THIS branch rather than its own.

Merge authority ends at a local merge: **nothing is ever pushed**. After the
merge: `./build.sh`, install, `cs -doctor` drift, then re-install the mod
properly (see Settled — the deployed copy is currently hand-copied branch
code). Then **#622, the held release v2026.9.16**.

## 2. Settled and rejected

- **The forced rotation is opt-in and stays opt-in.** `CS_ROTATE_FORCE_CTX`
  unset means the mod behaves exactly as it does on main. Alex asked for it
  with "can we force /rotation when context is critical?", then chose "with
  grace" over "force rotate only" when offered the diff.
- **`$.command.run` from a timer, not from the hook.** The contract refuses a
  command inside a hook the turn is waiting on (claude-code.d.ts:2338-2346,
  read in source). MEASURED in the spike: a `$.clock.after(0, ...)` callback
  scheduled inside `turn.complete` runs the command successfully — 0 ms is
  enough, no delay needed.
- **"Type to stop" is exactly the hotkey press or a `prompt.submit`.** There
  is no keystroke event for a render band: `surface.onKey` belongs to a
  `Client`, not to a render hook (claude-code.d.ts:1103, read in source).
- **Module state and timers SURVIVE `/clear`** (MEASURED in the spike: a
  ticker started at session.start kept firing after a `/clear`, and
  `$.session.id()` inside it returned the NEW transcript uuid). `session.start`
  does NOT fire on `/clear` (MEASURED, inherited from the previous handoff and
  re-confirmed). This is what makes the adoption guard possible and why every
  path that ends the countdown must cancel its timer explicitly.
- **The once-per-conversation record is a file, not module state**
  (`.cs/local/cs-rotate.forced`, holding the conversation id), written BEFORE
  the timer is scheduled so a `/rotate` that fails is not retried at the end
  of every turn.
- **REJECTED: judging every conversation by its first turn.** That was
  `0b6b76a` and it was wrong — the advisor caught it before the gate. A
  session resumed at 72% with the knob at 70 would have toasted "below this
  conversation's starting context" and never forced, silencing the feature in
  exactly the situation it exists for. Replaced in `9ff59cb` by adoption:
  `adopted` holds the first id the module sees after `register()`, and only a
  LATER id (a `/clear`-born conversation) is judged. A reload re-runs
  `register()` and therefore re-adopts, which can only withhold the guard,
  never add a rotation.
- **REJECTED: documentation as the loop guard.** Round 2 of Codex said plainly
  that prose cannot prevent repeated rotation; it was right.
- **REJECTED: making the scope-prompt scan cheaper** (task #631). It is 100 ms
  on an idle box; the failure was a 10x slowdown from my own local suite.
- **MEASURED and load-bearing: the wake turn after a `/clear` is an ordinary
  `turn.complete` with `reason: 'answer'`,** gated only by the threshold. That
  is why a knob below a fresh conversation's own footprint looped (live run 1,
  knob at 1: it forced, cleared, woke, and forced again immediately).
- **Ghost runs Claude Code 2.1.72** (MEASURED via `ssh ghost@ghost claude
  --version`), which predates function hooks and prints no hooks inventory.
  `9ff59cb` makes the validate pins SKIP in that case rather than fail. Ghost
  also has no `bun` (MEASURED), so the 46 unit tests SKIP there too: the ghost
  verdict covers the harness and the shell suites, and the bun tests plus the
  inventory pins are proven LOCALLY only, on bash 5 and `/bin/bash` 3.2.
  Say that split plainly at the gate rather than "67/67 on ghost".
- **The mod deployed at `~/.claude/skills/cs-rotate/hooks/register.tsx` is
  branch code I copied by hand** three times this conversation, so the live
  runs would exercise the branch. It is harmless while the knob is unset, but
  it means `cs -doctor`'s deploy-drift row will differ from main until the
  merge. Re-install via `install.sh` after merging.
- Alex, twice this conversation: **run the full gate on ghost, not locally.**
  "why don't we run them on ghost?" — a mods-only diff is NOT an exemption.
  The local run cost: load 22-28 for 40 minutes, his tmux window renamed
  (#630), and a killed hook on one of his prompts (#631). Memory
  `feedback_full_gate_runs_on_ghost` was sharpened to say so.

## 3. Conversation-only facts

Things with no other home. Each marked by how it was established.

- **MEASURED (spike, scratchpad/spike-grace, evidence copied to
  `.cs/research/spike-rotate/grace-evidence/`):**
  (1) `$.command.run` from a `$.clock.after(0)` callback scheduled inside
  `turn.complete` resolves. The probe command had no `command.run` hook so the
  engine answered with a hint string, but the run went through.
  (2) `$.clock.every(1000)` + `$.ui.invalidate('ui.render')` redraws the band
  each second — `/clear in 6s` then `5s` on consecutive captures.
  (3) `prompt.submit` sees the typed prompt with `origin: {kind:'composer'}`,
  `wait: false`, no `turnId`, and cancelling a ticker held in module state
  from it works; the countdown restarted at the next turn's end.
  (4) At zero, `command.run({command:'clear'})` from the ticker resolved
  `{"text":""}` and the screen cleared.
  (5) Claude Code's own ghost-text suggestion sat in the composer when the
  countdown hit zero; the `/clear` ran regardless (a suggestion is not typed
  text, and does not raise `prompt.submit`).
- **MEASURED (live run 1, `cs grace-live`, knob at 1, evidence at
  `.cs/research/spike-rotate/grace-evidence/live/`):** turn 1 "ok" ended →
  `❯ /rotate` appeared by itself → the real rotate skill wrote, committed and
  armed its handoff (71 s) → its turn ended → the capsule read `1: /clear and
  continue from the handoff · /clear in 19s · █░░░░░░░░░ 8%` and stepped every
  second → at zero `❯ /clear` ran → SessionStart consumed the marker and
  kicked the wake turn (new uuid) → the wake turn ended and forced a SECOND
  rotation. A fresh conversation in that session read **7-8%**, which is the
  number the knob must sit above.
- **MEASURED (this conversation, the cause of #630):** 14 test suites run
  `hooks/session-start.sh` while inheriting the developer's `TMUX`/`TMUX_PANE`;
  its tab-title re-assert (#611) takes the tmux branch and renames the live
  window to the fixture's name. Only `tests/test_hooks.sh` guarded it, per
  test. Alex saw his window become `cs: test-session`. Fixed at source time in
  `tests/test_lib.sh` (`ae3f557`).
- **MEASURED (this conversation, the cause of #631):** `scope-prompt.sh` has a
  3 s registered timeout. Its trace (`.cs/local/scope-prompt.trace`) shows a
  normal run at ~270 ms total (`tokens` 94, `scan` 152, `gitlog` 198,
  `gitdiff` 229, `emit` 272 — the numbers are ms offsets). The killed run
  reached `objective` at **1.7 s** under load 22-28 and died in the scan.
- **Alex's own words, kept:** "with grace"; "why don't we run them on ghost?";
  "who modified this sessions tab title to test-session?"; "what does that do?
  the scope-prompt?"; "how should we fix it?" then "yes" (which is what
  authorised filing #631, not building it).
- **The advisor's three blocks before the gate,** two now closed: the guard
  false-negative (closed by `9ff59cb`), the stale live measurement (live run 2,
  in flight), and the ghost/bun/claude coverage split (to be stated at the
  gate, not fixed).
- **Not investigated, noted only:** the `getcwd` error Alex screenshotted at a
  `cs claude-sessions` launch is the launching shell's cwd having been deleted
  under it (the wiped scratchpad), not a cs fault. A note sits in
  `~/.claude/journal.md` suggesting cs could `cd /` before its shell-init.

## 4. What this handoff could not carry

Written from live, uncompacted context at 40%. Nothing was cut for length.
The two in-flight measurements (live run 2, Codex round 3) had not landed when
this was written — their results are on disk at the paths in Next Step, not in
this file.

## 5. Primary Request and Intent

This conversation woke on `2026-09-16-build-forced-rotation-grace.md` to build
task **#628, forced rotation with grace**, which Alex asked for as "can we
force /rotation when context is critical?" and then, offered the diff between
force-with-grace and force-rotate-only, chose "with grace".

It was built and is complete on branch `feat/rotate-force-grace`, 10 commits,
not merged. Two side quests came out of Alex noticing damage from my own local
test run and were filed as tasks: **#630** (built on this branch) and **#631**
(filed, not built — he said "yes" to filing, not to building).

## 6. Key Technical Concepts

- **cs-rotate mod** — `mods/cs-rotate/hooks/register.tsx`, TypeScript running
  inside Claude Code's process behind `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`,
  which every cs launch exports. The type contract is
  `.cs/research/spike-rotate/claude-code.d.ts` (10,736 lines) — READ IT rather
  than guess; every contract claim in this handoff came from it.
- **Five hooks now** (was two): `session.start` (heartbeat), `turn.complete`
  (the forced rotation and the countdown's start), `prompt.submit` (cancels
  the countdown), `command.run{command=clear}` (cancels it), and
  `ui.render{component=AbovePrompt}` (the capsule).
- **New exports:** `FORCED = '.cs/local/cs-rotate.forced'`,
  `GRACE_SECONDS = 20`. New module state: `left`, `ticker`, `bandIdle`,
  `adopted`, `started` — all reset in `register()`, which is the reload hook.
- **`claude plugin validate`** inventories a module's hooks, its `$` calls and
  the literal env names it reads, with the function-hooks flag OFF. That is
  what `tests/test_mod_rotate.sh` pins. Copy new pins FROM the real output,
  never write them by hand.

## 7. Files and Code Sections

The branch: `git log --oneline main..HEAD` on `feat/rotate-force-grace`
(10 commits, `e2328ad` through `9ff59cb` plus two handoff commits).

The two guards Codex and the advisor drove, both in `forceRotation`:

```tsx
  if (!(await ownsRotation($))) return
  const id = await $.session.id()
  const { context } = await $.session.usage()
  if (adopted === undefined) adopted = id
  if (id !== adopted && started?.id !== id) {
    started = { id, percent: context.percent }
    if (started.percent !== undefined && started.percent >= force) {
      $.ui.toast(`cs-rotate: CS_ROTATE_FORCE_CTX=${force} is below this conversation's starting context (${started.percent}%); not forcing a rotation`)
    }
  }
  if (started?.id === id && started.percent !== undefined && started.percent >= force) return
```

and the zero tick, whose ordering is the round-2 blocker's fix:

```tsx
    if (left === undefined || left <= 0) return
    left -= 1
    $.ui.invalidate('ui.render')
    if (left > 0) return
    const idle = bandIdle && (await handoffArmed($)) && (await ownsRotation($))
    if (left !== 0) return
    stopCountdown($)
    if (idle) await clearAndContinue($).catch(err => $.ui.toast(...))
```

`left` is held at 0 across the reads so a prompt or press landing in that
window wins; the tick then does nothing.

Tests: `mods/cs-rotate/test/register.test.ts`, 46 of them, `bun test` from
`mods/cs-rotate`. The fake `$` now carries `clock.after`/`clock.every`
recording `(ms, fn)` and returning `{cancel}`, `ui.invalidate`, `ui.toast`, and
a coherent fs (writes are visible to reads). Helpers at the bottom:
`turnComplete()`, `fireAfter()`, `ticker()`, `tick(n)`, `promptSubmit()`.

Docs: `docs/hooks.md` (the cs-rotate section), `docs/configuration.md` (beside
`CS_ROTATE_BUTTON_CTX`), `README.md` line 36, `CHANGELOG.md` line 15 (the
one-key entry, extended), `skills/rotate/SKILL.md` step 11 (the keystroke is
theirs *unless* the knob is set).

The harness fix (#630) is `tests/test_lib.sh`, the source-time block beside
the `XDG_DATA_HOME` unset, pinned by
`test_test_lib_drops_an_inherited_tmux_and_routes_the_title_to_a_file` in
`tests/test_hooks.sh`.

## 8. Problem Solving

- The advisor caught the guard false-negative; two Codex rounds did not. Both
  matter: Codex found the zero-tick race and the frontmatter mismatch that the
  advisor did not.
- Ten mutations, one per arm, were run against the unit tests and all ten came
  back red. Two more for the later guards, also red. That is the evidence the
  tests bite; a green suite alone would not have been.
- `test_mod_rotate.sh`'s validate pins are version-sensitive: ghost's 2.1.72
  prints no inventory at all. The skip added in `9ff59cb` keys on the absence
  of a `hooks:` line, the same shape as the existing bun skip.
- Live driver traps, inherited and re-confirmed: count `done` lines rather
  than matching one; kill panes by the id captured at creation, never by a
  predicate; `cs -rm <name> --force </dev/null`.
- A `sed`-built driver for live run 2 did not send its second prompt (the
  edited `send-keys` line lost its `Enter`). I sent it by hand to the captured
  pane id. If the successor writes another driver, verify the composer
  actually submitted rather than trusting the script.

## 9. Pending Tasks

The native task list is keyed to the session and survives the `/clear`.
Reconcile against this list; do not mirror it.

- **#628 in_progress** — this handoff's work. Built, 10 commits, unmerged.
- **#630 in_progress** — the tmux harness leak. Code is committed (`ae3f557`)
  and green; it is in_progress only because it rides #628's branch. Close it
  when that merges.
- **#631 pending** — scope-prompt's own deadline. Filed with a full design in
  its description. Alex approved filing, NOT building. Its own branch, after
  #628.
- **#622 pending** — the HELD release v2026.9.16. Content re-push needed (the
  count has grown again), CI wait (background it), notes regenerated from
  CHANGELOG Unreleased, version bump in `lib/00-header.sh`, `./build.sh`,
  Alex's approval, tag only after CI is green.
- **#554, #603, #609 pending; #606 postponed** — the standing backlog.
- Not requested, noted only: the tmux dock-bounce gap; the doctor's `-x` cannot
  tell an unrunnable bundle from a working one; two KEEP IN SYNC sites
  (statusline declined-marker, ZSH_COMPLETION_DIR).

## 10. Current Work

Branch `feat/rotate-force-grace` at `9ff59cb` plus two handoff commits, tree
otherwise clean, 46 unit tests green, `tests/test_mod_rotate.sh` 6/6 on bash 5
and on `/bin/bash` 3.2, the full local suite 67/67 (on `f0f6e05`), ghost 66/67
(on `ae3f557`, the one red since fixed).

**Two measurements were in flight at rotation and are NOT results yet:**

- **Live run 2** — pane `%242`, session `grace-live2`. Turn 1 measured 7%, no
  force, correct. The heavy turn was sent by hand moments before this handoff
  and was still running. Read the pane, or its captures, per Next Step.
- **Codex round 3** — FAILED at the provider, not a clean report: the log ends
  `ERROR: Selected model is at capacity` after 39,659 tokens
  (`<scratchpad>/codex/run3.log`), and `out3.md` was never written. **Re-run
  it**; the prompt is saved at `<scratchpad>/codex/prompt3.md`. Round 3 is
  required before the gate: Alex holds for an adversarial pass on every
  release-bound change, and rounds 1 and 2 predate the last three commits.

## Completeness of this handoff

Written from live, uncompacted context at 40%, in two passes as the skill
asks. Nothing was cut for length.

## Addendum, written minutes after pass two

**Live run 2, corrected.** The heavy turn in the driver named its files
RELATIVE (`tests/test_hooks.sh`), and a cs session's cwd is its own session
directory, not this repo — so the reads resolved to
`~/.claude-sessions/grace-live2/tests/...` and failed. Context stayed at 8%,
under the knob at 10, and nothing forced. That is the mod behaving correctly
on a turn that read nothing, not a measurement.

I re-sent the prompt with ABSOLUTE paths
(`/Users/alex.geana/.claude-sessions/claude-sessions/tests/test_hooks.sh`,
`tests/test_install.sh`, `lib/75-launch.sh`) and the reads started. Pane
`%242` is mid-turn as this is written. When that turn ends, context should
pass 10 and the forced sequence should run. If it still has not crossed,
send another read of
`/Users/alex.geana/.claude-sessions/claude-sessions/.cs/research/spike-rotate/claude-code.d.ts`
(10,736 lines), which will certainly cross it.

Any driver written for a cs session must use absolute paths for repo files.
