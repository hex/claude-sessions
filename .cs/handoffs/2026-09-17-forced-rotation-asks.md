---
parent: 78081cbe-36e2-4d13-9ae7-d1349ed1fb69
created: 2026-09-17T13:25:00Z
purpose: Replace the forced rotation's 20-second countdown with a $.ui.ask dialog, then gate the whole cs/mods branch
status: consumed
consumed_by: 5e78fa59-b25a-4cee-ab89-c0960aa06052
---

# Next Step

Build the approved change to `mods/cs-rotate/hooks/register.tsx`: at the
**forced** threshold only (`CS_ROTATE_FORCE_CTX`), replace the 20-second
countdown to `/clear` with the engine's own question. TDD, red first, in
`mods/cs-rotate/test/register.test.ts` (63 green now, `cd mods/cs-rotate &&
bun test`).

Approved shape, from the contract (read in source, see Key Technical
Concepts):

- When `forceRotation($)` finds a handoff already armed, do **not** start a
  ticker. Instead ask once per conversation:
  `$.ui.ask('The handoff is written. Clear now and continue from it?',
  { header: 'Rotate', options: ['Clear and continue', 'Not yet'] })`.
- Fire it from `$.clock.after(0, ...)`, never awaited inline in the hook: a
  hook the turn waits on cannot run a command, and awaiting a dialog inside
  `turn.complete` would hold the turn open until the person answers.
- `Clear and continue` → `clearAndContinue($)`. `Not yet`, a dismissal, or a
  rejection (a `-p` run has nobody to ask) → leave the band's button alone
  and do not ask again this conversation. Reset that flag wherever `left`,
  `ticker`, `clearSeen` and `birth` are reset (the `// A (re)load has no
  countdown` block, register.tsx:95-96).
- Deletions this authorises: `GRACE_SECONDS`, `left`, `ticker`,
  `startCountdown`, `stopCountdown`, their two call sites in `prompt.submit`
  and `command.run{clear}`, and the band's `/clear in Ns` Text. Alex chose
  this explicitly ("replace the 20-second countdown at CS_ROTATE_FORCE_CTX
  with the dialog"), so removing that shipped, tested code is authorised —
  but only that. The band and its hotkeys at the ordinary 40% threshold stay
  exactly as they are.

**This must be measured live before it counts as done.** Whether
`$.ui.ask` from a 0 ms timer in `turn.complete` actually draws, and whether
the answer then runs `/clear`, is unverified — assumed from the type
contract, nothing more. The fake engine will stay green either way; that is
exactly how the last claim in this area died (see Problem Solving).

# Settled and rejected

- **Alex picked "Question only at the forced threshold"** from three options.
  Rejected: (a) replacing the band's hotkeys with a question everywhere —
  I pushed back that a dialog seizes the composer while the band never
  demands anything, and the forced path is the one place the mod already
  acts without asking; (b) deleting the band entirely.
- **Hand-drawn hotkeys: rejected by measurement, not taste.** See Problem
  Solving. Do not retry `label=""`.
- **The designer's export is band JSX only**, not a runnable mod — Alex's
  call when asked ("band").
- **The canvas lives inside the lab** as a Compose panel, not a separate
  page — Alex's call against my recommendation of a separate file.
- **The layout engine got bun tests**, not the lab's Chrome-only precedent —
  Alex's call.
- **`docs/mods-layout.js` approximates Yoga**: children measure against the
  full room and an over-wide row overflows, where Yoga would shrink a Text.
  A first attempt allocated row room sequentially and starved later
  children; that is rejected, and the canvas clips + names the overrun
  instead of pretending to shrink.
- **Installing this checkout mid-session was Alex's explicit choice** when
  offered a gated spike plugin instead.

# Conversation-only facts

- **Ghost is unreachable from this session.** `ssh ghost` →
  `Permission denied (publickey,password,keyboard-interactive)`; `ssh -G ghost`
  resolves to `alex.geana@ghost` with five default identity files and
  `identitiesonly no`; `remote-tests.sh --host ghost` fails earlier still —
  there is no host store at
  `~/.claude/plugins/cache/hex-plugins/claude-tmux/2026.9.1/remote-hosts.json`.
  So the full gate ran LOCALLY, against the ghost-only rule, and Alex was
  told rather than it being substituted quietly. Measured.
- **Local full suite: 65/67**, `bash tests/run_all.sh` (the runner is
  `run_all.sh`; `run_tests.sh` does not exist). The two failures are
  `test_cs_secrets.sh` and `test_cs_secrets_concurrency.sh`. They fail
  **solo** as well, and `git log -3 -- lib/ bin/` shows the last touch
  predates this conversation's commits, which only add `docs/` and one test
  file. Symptom, measured: after `cs -secrets set`, the store file
  `<tmp>/home/.cs-secrets/test-session.enc` never appears; also
  "salt-A must decrypt after concurrent first-use salt write" and
  "export must not rename a stale snapshot over a newer sync backup (F1)".
  Unexplained. NOT triaged — the next conversation should decide whether
  this is a real defect or this machine.
- **The live band, measured twice in a throwaway cs session** (tmux, one
  real turn, `CS_ROTATE_BUTTON_CTX=1`): before the fix
  `1 rotate this conversation1:   ·  2 wrap up this session2:   ·  ○ ctx 8%`;
  after `1: rotate this conversation  ·  2: wrap up this session  ·  ○ ctx 8%`.
  Pressing `1` ran `/rotate` end to end.
- **Killing a tmux session leaves the cs session lock behind**: the relaunch
  refused with `Error: Session spike-band is already running elsewhere
  (UUID 2872e5a4-…). Use --force to override.` Worked around with a second
  session name, not `--force`. Both throwaway sessions (`spike-band`,
  `spike-band2`) have been removed.
- **`$.ui.ask` exists and a mod can originate the dialog** — it is not
  merely a restyle hook for a question the model asked. Read in source:
  `~/.claude/plugins/marketplaces/claude-code-plugins/mods/types/claude-code.d.ts:1900-1915`,
  plus `AskOptions` at :344 (2-4 labels, `header` ≤12 chars, `multiSelect`).
- **Alex's screenshot** was the lab's "Bare line" preset with `mark` off.
  That preset's pie gauge is why the band's ten-cell meter became
  `◑ ctx 47%`.
- Context stood at 44% when this rotation was written; nothing was compacted.

# Primary Request and Intent

Alex opened `docs/mods-design-lab.html`, asked "where is the designer?",
and then: "create a visual designer as well". His words on scope: the
export hands you **"band"** JSX, not a runnable mod. Later, from a
screenshot of the lab's rotate panel: "I think I prefer this style, but
without the claude star". Then, from a screenshot of the AskUserQuestion
render-site snippet: "should we use this instead?" — which on asking meant
the band's own hotkeys becoming a real question, narrowed by his next
answer to the forced threshold alone.

# Key Technical Concepts

- **The mods contract is the authority**, not docs:
  `~/.claude/plugins/marketplaces/claude-code-plugins/mods/types/claude-code.d.ts`.
- **`$.ui.ask(question, options)`** opens the engine's own AskUserQuestion
  dialog from a mod and resolves to the chosen label (or free text typed
  under Other). Rejects when dismissed and in a `-p` run. Drawn by
  `ui.render` on `AskUserQuestion`; raises a `tool.call` through every hook
  but the calling one.
- **A hook the turn waits on cannot run a command; a 0 ms timer scheduled
  inside it can.** Measured in #616, and the existing `forceRotation` already
  relies on it (register.tsx:283).
- **A `plain` Button always draws `N: `**, empty label included (measured,
  2.1.273).
- **The band is `ui.render` on `AbovePrompt`**, lead-only, yielding to a
  survey and to a running turn.

# Files and Code Sections

- `docs/mods-layout.js` (new, commit 4936f8d) — `layout(node, width)` →
  grid of styled cells; `toText`, `validate`, `toJsx`, `BORDERS`.
  `PROP_ORDER` spells props in the order `register.tsx` does. Exported
  through a CommonJS guard, so the page loads it with a plain `<script src>`
  (a module script is blocked over `file://`).
- `docs/test/layout.test.ts` — 16 tests. The oracle is the shipped rotate
  band, hand-worked from `register.tsx`, asserting the exact 3-line strip.
- `tests/test_mods_layout.sh` — bash wrapper: pins the plain-script seam,
  the two export lines, and runs `cd docs && bun test`.
- `docs/mods-design-lab.html` — the Compose panel (`#p-compose`, first in
  `NAV`, the landing panel), `CP_SCHEMA`, `cpToEngine`, `cpPaint`,
  `composeRender`, `composeUI`; `cpRotatePreset` is the "load the rotate
  band" button. Commit 65e43ff, corrected in 6ba8bd1.
- `mods/cs-rotate/hooks/register.tsx` — the band at :160; `forceRotation`
  at :258; `startCountdown`/`stopCountdown` at :292-317; `pie(percent,
  bands)` replaced `meter()` and is pinned against `bin/cs-statusline`'s
  `_ctx_pie` (:1605).
- `.cs/memory/narrative.hex-users-noreply-github-com.md` — three dated
  entries today, including a correction that names the claim it overturns.

# Problem Solving

- **The lab was a tool nobody could see.** Every panel was already live
  knobs plus preview plus emitted JSX; Alex still read it as a reference.
  Fixed by making the canvas the landing panel — a findability defect, not
  a capability one.
- **`boxRender` could not be reused**: one flat level of flex over fixed
  strings. Hence a real recursive engine.
- **Two of my own tests were wrong and the code was right**: a row at width
  2 starved its second child (my sequential allocation), and my prop order
  put padding before border where `register.tsx` puts border first. Both
  corrected toward the shipped convention.
- **The lab asserted something false** and the fake engine agreed with it.
  Only the live run caught it. The lab now prints what the engine really
  does with that tree.

# Pending Tasks

Native list (survives the `/clear`; reconcile, do not mirror):
#640 pending — four release-review Minors from v2026.9.16, none blocking.
#644 pending — integrate-lock follow-ups (Minor).
#554 pending — PARKED, SessionStart notice for pending tool calls.
#606 pending — POSTPONED, cs --remote.
No task was opened for this conversation's work; open one for the ask.

Not in the list, and owed:
1. The `$.ui.ask` change above, with its live measurement.
2. The two secrets suites: triage or hand back with a reason.
3. A full gate on the whole `cs/mods` branch — on ghost if its ssh is
   fixed, and say plainly if it runs locally again.
4. `/codex:review` before any of this is called done. Alex runs it; you
   cannot. Offer it.
5. `docs/hooks.md` and `CHANGELOG.md` already describe the canvas; the band
   restyle and the ask are NOT in the changelog yet.

# Current Work

Four commits on `cs/mods`, all local, nothing pushed: `4936f8d` (engine),
`65e43ff` (canvas), `eec2465` (bare line), `6ba8bd1` (engine draws the
hotkey; lab correction). Working tree clean but for the narrative. This
checkout is **installed** — Alex's live band is the new bare line.
`mods/cs-rotate` is 63/63 under bun; `docs` is 16/16.
