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
