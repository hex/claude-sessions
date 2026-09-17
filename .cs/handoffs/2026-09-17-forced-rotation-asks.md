---
parent: 78081cbe-36e2-4d13-9ae7-d1349ed1fb69
created: 2026-09-17T13:25:00Z
purpose: Replace the forced rotation's 20-second countdown with a $.ui.ask dialog, then gate the whole cs/mods branch
status: unconsumed
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
