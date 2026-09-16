---
parent: c9bd309e-6a80-4ae2-bc3c-67e2d83a68b9
created: 2026-09-16T06:15:52Z
purpose: build forced rotation with grace (task #628), then resume the held v2026.9.16 release (#622)
status: unconsumed
---

## 1. Next Step

Build task #628, forced rotation with grace, in `mods/cs-rotate/hooks/register.tsx`.
Alex chose it with the words "can we force /rotation when context is
critical?", then "diff between force with grace and force rotate only", then
"with grace". Alex typed `628` to start it, then picked "Rotate first" when
offered, so this handoff exists instead of a half-built branch.

The design as the task description records it (read `TaskGet 628`):

- **Off unless `CS_ROTATE_FORCE_CTX` is set** in the launching shell (read via
  `$.env.get("CS_ROTATE_FORCE_CTX")`, a literal name, because `claude plugin
  validate` lists what a module reads and refuses a name it does not spell).
- **Trigger**: a `turn.complete` hook (lead only via the existing
  `ownsRotation`; not already armed via `handoffArmed`; context percent at or
  past the threshold; once per conversation via a `.cs/local` marker keyed on
  `$.session.id()`). It must NOT call `$.command.run` directly: the contract
  says `run` "rejects ... inside a hook the turn is waiting on"
  (claude-code.d.ts:2338-2346, read in source). So: `$.clock.after(ms, () =>
  $.command.run({ command: 'rotate', args: '' }))`. A timer callback "is the
  plugin's own function, kept in its environment and run there when the wait
  resolves" (2510-2515, read in source). UNMEASURED: whether `command.run`
  works from that callback. The previous spike (task #616) measured
  `prompt.submit` working from a timer and `command.run` working from a button
  press, never `command.run` from a timer. Measure that first.
- **Grace**: once the handoff is armed (the existing `handoffArmed` check),
  the capsule shows a countdown ("`/clear` in 20s" or similar), redrawn with
  `$.ui.invalidate('ui.render')` from a `$.clock.every(1000, ...)`; the
  contract's own example for invalidate is a countdown (1838-1845, read in
  source) and it folds calls past ten a second. Cancel the countdown on the
  hotkey press (the existing `clearAndContinue` runs at once) or on a
  `prompt.submit` hook firing (the user typed something). At zero, run
  `$.command.run({ command: 'clear', args: '' })` from the timer, only when the
  band would draw: `!isWorking && !hasSurvey` is a render-time fact, so keep
  the last render's props in module state.
- **No keystroke event reaches a band**: `surface.onKey` (claude-code.d.ts:1103)
  belongs to a `Client`, not to a render hook (read in source, previous
  handoff). So "type to stop" is exactly: hotkey press or prompt.submit.
- **Failure of `/rotate` must not retry every turn**: the once-per-conversation
  marker is written BEFORE the timer is scheduled.
- `turn.complete` carries `reason: 'answer' | 'aborted' | 'refusal' | 'error'`
  (8391-8420, read in source); trigger on `answer` only, an aborted or errored
  turn is not a place to start a rotation.

**Measure first, in a spike mod, before touching the real one** (the previous
spikes lived in a bare directory under the scratchpad with a `drive.sh` that
launched a real `cs <name>` in a tmux window, ran two turns with positional
prompts, captured with `tmux capture-pane -p -e`, and pressed keys; that
scratchpad is gone, so write the driver again): (1) `command.run` from a
`clock.after` callback scheduled inside `turn.complete`; (2) an
`invalidate('ui.render')`-driven countdown redraws the band; (3) a
`prompt.submit` hook sees a typed prompt and can cancel a timer held in module
state; (4) what `turn.complete` sees on the wake turn of a rotation (the
SessionStart kick), so the trigger does not fire on a fresh conversation's
first turn.

Then: red-first bun tests in `mods/cs-rotate/test/register.test.ts` (the fake
`$` there needs `clock.after`/`clock.every` returning a cancel, `ui.invalidate`,
and a way to fire `turn.complete` and `prompt.submit` hooks), a mutation per
arm, `tests/test_mod_rotate.sh` still 6/6 on bash 5 and `/bin/bash` 3.2 (it
runs `claude plugin validate` and bans `$.prompt.fill`/`$.prompt.submit`), the
knob in `docs/configuration.md` beside `CS_ROTATE_BUTTON_CTX`, `docs/hooks.md`
(the mod's section), README's rotate-mod line, CHANGELOG Unreleased under
Features (extend the "One key rotates a conversation" entry or add one), then
Codex read-only (`env -u ANTHROPIC_API_KEY codex exec --sandbox read-only -C
"$PWD" -o <out> "$(cat prompt.md)" </dev/null`, the `</dev/null` mandatory), the
full suite in the background (25-30 min under this Mac's load), a live
measurement in a real cs session, and Alex gates the merge with
AskUserQuestion (he picks "merge, build, install" when the review is clean;
polish-first when something is left).

After #628: #622, the held release.

## 2. Settled and rejected

- **The owl icon cannot be passed by the poster.** MEASURED on this macOS
  with terminal-notifier 2.0.0: `-appIcon` ignored (Alex's screenshot showed
  the Terminal icon), `-contentImage` ignored ("No owl anywhere"), `-sender
  com.googlecode.iterm2` HANGS (killed after 120 s). What works: a copy of
  terminal-notifier.app rebranded (owl icns, bundle id `com.hex.cs.notifier`,
  name `cs`, `codesign --force --deep -s -`, `lsregister -f`). Alex's
  screenshot of the installed bundle's post showed the owl, no second
  permission prompt after the re-signature. Keep that bundle id: the grant
  is keyed on it.
- **Terminal identity is `__CFBundleIdentifier`, not a TERM_PROGRAM table.**
  MEASURED: inside tmux `TERM_PROGRAM=tmux`; `__CFBundleIdentifier=
  com.googlecode.iterm2` is in the pane env and in `tmux show-environment -g`.
- **terminal-notifier reads piped stdin as message data.** MEASURED: the
  prompt hook called it before `INPUT=$(cat)` and every prompt was swallowed
  (test_msg's wake-ceiling tests went red). Every call now has `</dev/null`;
  memory entry `project_hook_subprocess_eats_stdin`.
- **Homebrew's `bin/terminal-notifier` is a 124-byte wrapper script**, not the
  app binary (MEASURED). `cs_notifier_source_bin` resolves the keg's app
  binary; the doctor hashes that. Ad-hoc signing rewrites the Mach-O, so
  staleness is a recorded sha256 of the source, never a byte compare.
- **The iconset directory must be named `*.iconset`** or `iconutil` refuses
  (MEASURED; cost one red run).
- **Hotkey glyph is the engine's** (`1: label`), never hand-drawn (MEASURED,
  previous handoff). **Raw `rgb()` colours reach the terminal as 24-bit SGR**
  (MEASURED). **Hover is a keyed Box prop with no hook run** (MEASURED).
- **`$.command.run` rejects inside a hook the turn is waiting on** (read in
  source, claude-code.d.ts:2338-2346). Hence the timer hop for #628.
- **The it2 dock bounce never fires inside tmux** (all three hook sites and
  `lib/60-doctor.sh:209` gate on `TERM_PROGRAM = iTerm.app`; MEASURED that
  tmux sets `TERM_PROGRAM=tmux`). Pre-existing; reported to Alex, not fixed,
  not asked for.
- **The lead-only gate now has four copies** (narrative-reminder's
  `_mail_is_lead`, session-start's `IS_LEAD`, scope-prompt's inline copy for
  the notification remove, the statusline). A fold into `cs-shared.sh` is a
  polish item Alex has not asked for.
- **`-appIcon` is gone** from the hook argv; the test pins the argv without
  it.
- A `mv`-over-a-directory guard was declined with an in-code note in an
  earlier conversation; do not re-raise it.
- Everything the previous handoff settled still holds: the press must
  EXECUTE via `$.command.run`, `$.prompt.fill`/`submit` are banned by
  `tests/test_mod_rotate.sh`, only one hotkey button, wait 2 s after a label
  appears before pressing in a driver, a bare `claude` in a dir with prior
  sessions opens FleetView (use a positional prompt), the statusline session
  name stays plain ink.

## Conversation-only facts

- **Unpushed**: main is at `07a1f4c`, 34 commits ahead of origin, tree clean.
  Nothing tagged. The last CI-green push was `ee985d4`.
- **Suite runs this conversation**: full suite four times, 67/67 each (66
  suites plus the new `tests/test_notify.sh`), on `2c4551e`, `c62f6a6`,
  `1ea6c4f`, `7061584`. The first run on `8b3f051` was 66/67 with test_msg red
  (the stdin defect). Wall time 25-30 min at load average 20-33. One
  background waiter was killed by the harness "because the system is running
  low on memory"; the suite itself survived.
- **Codex rounds**: four. Round 1 (8b3f051): no Important, 2 Minor. Round 2:
  closures measured, 1 Minor left. Round 3 (1ea6c4f): 3 Important (staged
  bundle promoted BEFORE its `-help` smoke; unguarded `mkdir -p` of the XDG
  dest aborting the installer under `set -e`; tests inheriting `XDG_DATA_HOME`
  so they could clobber the real bundle) + 3 Minor. Round 4 (7061584): no
  Important; one nit (nothing pinned the XDG scrub) folded as `6568999`.
  Codex never ran anything; its findings were all reproduced by red tests.
- **Codex took about four minutes per round**, `</dev/null` mandatory.
- **Mutations proven**: 9 on the first branch, 5 + 2 + 1 on the second, each
  named in the narrative. One survived legitimately (an `asn=x` mutation is
  caught by the second `lsappinfo` call, same property).
- **Live measurements**: `lsappinfo front` → `ASN:0x0-0xae0ae:`;
  `lsappinfo info -only bundleid <asn>` → `"CFBundleIdentifier"="company.thebrowser.Browser"`
  (Arc was frontmost). `terminal-notifier -help` exits 0 for both the stock
  binary and the bundle. The scratchpad probe bundle was `lsregister -u`'d
  after the real install.
- **Doctor on this machine now**: `[ OK ] Notification: cs.app bundle active
  (owl icon)`, deploy drift OK, the two standing WARNs (non-cs statusline
  bridge; the rotate mod has not run in THIS conversation because it launched
  before the flag existed).
- **Context**: `.cs/local/context-pct` read 39 before the last two turns; the
  previous conversation rotated at 46.
- **Alex's words this conversation**: "1 and 3" (from the handoff), a
  screenshot with the Terminal icon (no words), "send it again" twice (the
  probes), "send again" once, a screenshot with the owl (no words), "628",
  "Rotate first". At the two merge gates: "Merge, build, install".
- **The two removed-then-returning sessions** from the previous handoff did
  not recur; no throwaway sessions were created this conversation.
- **This conversation's scratchpad** (`/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/c9bd309e-6a80-4ae2-bc3c-67e2d83a68b9/scratchpad/`
  is the nominal path; the files actually landed under `$TMPDIR/owl/`, i.e.
  `/var/folders/jw/.../T/owl/`): `codex-prompt{,2,3,4}.md`, `codex{,2,3,4}.out`,
  `full-suite{,2,3,4}.log`, `install{2,3,4}.log`, `app/` (the probe bundle and
  its 1.4 MB icns, superseded by the installer's). Nothing there is needed.
