---
parent: b8e266c9-e804-4e3a-b38f-6afbff6170d3
created: 2026-09-15T14:52:07Z
purpose: build the owl macOS notification (task #629), then forced rotation with grace (#628), then resume the held v2026.9.16 release (#622)
status: unconsumed
---

## 1. Next Step

Build task #629, the owl notification. Alex chose it with the words "1 and 3"
when offered three places to use the new logo (1 = GitHub social preview, his
own manual upload; 3 = terminal notifications). Full design is in the task
description; the shape agreed in conversation:

- **Where**: `hooks/narrative-reminder.sh` (the Stop hook) at the site that
  already starts the iTerm dock bounce, around line 435, and
  `hooks/scope-prompt.sh` at the site that stops it, around line 107. Both
  sites are quoted in section 5. `hooks/session-start.sh` around line 497 also
  stops the bounce; decide whether it should also clear a notification.
- **When**: a turn ended AND the terminal is not the frontmost app. Frontmost
  by `lsappinfo front` then `lsappinfo info -only bundleid <asn>`; compare
  against the bundle id for `$TERM_PROGRAM` (iTerm.app →
  `com.googlecode.iterm2`, Apple_Terminal → `com.apple.Terminal`). If the
  probe fails, post nothing rather than guess.
- **What**: `terminal-notifier -group "cs:$CLAUDE_SESSION_NAME" -title
  "cs: $CLAUDE_SESSION_NAME" -message "finished a turn" -appIcon
  <hooks dir>/cs-logo.png -activate <bundle id>`. The group id makes a repeat
  replace rather than stack; `-remove "cs:$CLAUDE_SESSION_NAME"` clears it at
  the next prompt.
- **Opt-out**: `CS_NO_NOTIFY=1`, beside the existing `CS_NO_ITERM2`. Silent
  wherever `terminal-notifier` is not on PATH.
- **Icon deploy**: `hooks/cs-logo.png`, added to `CS_HOOK_LIBS` in
  `lib/01-manifests.sh` so install, uninstall and doctor drift all cover it.
  It is a copy of `assets/logo.png` (committed on main as 6b8d488). Decide
  whether `./build.sh` copies it or it is committed twice; the manifest arrays
  are the shared source both `bin/cs` and `install.sh` are built from, so the
  file has to exist under `hooks/` at install time either way.
- **Tests**: fake `terminal-notifier` and `lsappinfo` on PATH (the suites
  already do this for `tmux`), so they run on Linux CI. Red-first, then a
  mutation per arm. Pin the argv in the bracketed form the tab-title tests use.
- **Docs**: `docs/hooks.md`, `docs/configuration.md` (the knob),
  `README.md`, `CHANGELOG.md` Unreleased.

Alex's standing bar for this repo: red-first tests, a Codex read-only pass
(`env -u ANTHROPIC_API_KEY codex exec --sandbox read-only -C "$PWD" -o <out>
"$(cat prompt.md)" </dev/null` in the background — the `</dev/null` is
mandatory, without it Codex blocks forever on stdin), the full suite locally
(10-12 min), then he gates the merge. He picks polish-first at merge gates.

After #629: task #628 (forced rotation with grace), then #622 (the release).

## 2. Settled and rejected

- **The hotkey glyph is the engine's, not ours.** Alex pasted JSX from the
  design lab that drew `1` by hand beside a `<Button label="">`. MEASURED in a
  throwaway mod (evidence below): a Button always draws its own `1: ` prefix
  even with an empty label, so the band read `1 rotate this conversation1:`.
  He approved building "as adjusted" — the engine's `1: label` kept, the rest
  of his pick built. Do not re-attempt a hand-drawn hotkey.
- **Raw colours work.** MEASURED: `rgb(87,105,247)` and `#D97757` in a Box or
  Text prop reach the terminal as 24-bit SGR (`38;2;…`). The contract's words
  are "Colors are a theme key or a raw color" (claude-code.d.ts:7794). The mod
  now paints the bar's own ink triplets instead of theme keys.
- **Hover is real and free.** MEASURED live: with the pointer over the band the
  capture showed the coral border and an inverse button (SGR `0;7`). A keyed
  Box with `hover={{...}}` restyles with no hook run.
- **No keystroke event reaches a band.** Read in source: `surface.onKey`
  (claude-code.d.ts:1103) belongs to a `Client`, not to a render hook. So the
  grace countdown in #628 cannot cancel on "any keypress"; it cancels on the
  hotkey press or on a `prompt.submit`.
- **`gpt-image-2.5` does not exist as a model id.** Alex asked for it; the API
  returned `The model 'gpt-image-2.5' does not exist`. The key lists
  `gpt-image-2.5-flare` and `gpt-image-2.5-sunburst` (both dated 2026-09-08),
  plus `gpt-image-2`, `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini`,
  `chatgpt-image-latest`. The 2.5 models REJECT `--input-fidelity`
  (`does not support the 'input_fidelity' parameter`).
- **Logo: Alex picked C1b.** Of six candidates he said "C1 i LIke" (the Gemini
  owl, coral + cream on charcoal), then of the two refinements "c1 b is nicer"
  — the `gpt-image-2.5-flare` edit, fully flat, tighter crop. It is
  `assets/logo.png` on main (6b8d488). The rejected five and both refinements
  are in this conversation's scratchpad, listed in section 5.
- **GitHub's social preview has no API.** Read in source of the plugin scripts
  and the GitHub docs: it is a manual upload under repo Settings → General →
  Social preview. The card is rendered and waiting for Alex; do not try to
  automate it.
- **The status bar and the TUI cannot show the logo.** They are text cells. The
  notification path is the only place a bitmap fits.
- **A `mv`-over-a-directory guard was declined** with an in-code note in an
  earlier conversation; do not re-raise it (memory `feedback_retire_benign_hardening`).
- Everything the previous handoff settled still holds: the press must EXECUTE
  via `$.command.run`, `$.prompt.fill`/`submit` are banned by
  `tests/test_mod_rotate.sh`, only one hotkey button, wait 2 s after a label
  appears before pressing in a driver, a bare `claude` in a dir with prior
  sessions opens FleetView (use a positional prompt), the statusline session
  name stays plain ink.

## Conversation-only facts

- **Unpushed**: main is at `f77b728`, 20 commits ahead of origin, tree clean
  apart from the consumed handoff's frontmatter. Nothing tagged. The last
  CI-green push was `ee985d4` (run 34949654089, 6/6).
- **Suite timings this conversation**: the full suite ran 66/66 (exit 0) on
  `61898e3` in roughly 25 minutes under a load average of 23-33 (another
  session was busy). test_rotation 428 s, test_doctor 235 s, test_cs_secrets
  208 s, test_prompt_rewriter 127 s.
- **The mod suite is 6/6** on bash 5 and `/bin/bash` 3.2 after the Codex fold.
  The bun suite is 27/27.
- **Mutations proven this conversation**: changing the mod's amber light ink to
  `rgb(180,83,10)` turned `test_mod_inks_match_the_statusline_inks` red;
  changing the bar's LUMINANCE-branch amber to `180;83;8` turned the same test
  red only AFTER the Codex fold (it was green before, which is what Codex
  caught); dropping the `hover` prop turned the bun test
  "the capsule is a keyed box that turns coral under the pointer" red.
- **Codex's Minor, accepted as documented**: the bar picks amber from the
  measured terminal background (`CS_TERM_BG_RGB` luminance) when it has one;
  the mod has only `CS_TERM_THEME`. On a terminal whose background contradicts
  the theme flag the two ambers differ. Now stated in `docs/hooks.md` rather
  than fixed.
- **`git rebase -i --autosquash` refused** with "cannot rebase: You have
  unstaged changes" because the consumed handoff's frontmatter was modified by
  the SessionStart hook. `--autostash` fixed it and the autostash reapplied
  cleanly (`Created autostash: 7265286`).
- **The merge is a merge commit, not a fast-forward**, because the logo commit
  had landed on main while the branch was being built: `f77b728` merges
  `264bf50`.
- **The logo was committed from a temporary worktree** (`git worktree add`
  under the scratchpad, commit, `git worktree remove`) so the running full
  suite's checkout was never touched. That is the pattern to reuse for a
  commit while a suite runs.
- **Two removed sessions came back once.** After `cs -rm --force` removed five
  `mod-feel-*` sessions, `ls ~/.claude-sessions` still listed
  `mod-feel-inks` and `mod-feel-inks-crit` a moment later, each holding only
  an empty `.cs/`, and `cs -live` showed them with an age of `0s`. Cause is
  almost certainly the killed claude's SessionEnd hook writing `.cs/local`
  after the removal. A second `cs -rm --force` cleared them; the count is 0
  now. Worth remembering when scripting throwaway sessions: remove AFTER the
  pane is dead, and verify.
- **The three standing doctor WARNs** (unchanged, all expected): a non-cs
  statusline bridge is registered on this machine; the shadow ref for this
  conversation is missing; the cs-rotate mod has not run in THIS conversation
  because it launched before the flag existed.
- **Load and hardware**: this Mac was at load average 23-33 for most of the
  conversation with `mds_stores`, a JumpCloud agent and Chrome at the top. Any
  live measurement that waits on a turn needs a poll budget of hundreds of
  iterations, not tens.
- **Artifact**: the design lab is published at
  `https://claude.ai/code/artifact/5d5fcda4-3402-4782-90b0-896b09737db6`
  (source `scratchpad/capsule-lab.html` in this conversation's scratchpad).
  Eight presets, knobs for every dimension the runtime allows, and each state
  prints the JSX it maps to. Alex picked from it by pasting the JSX back.
- **Alex's design words this conversation**: on the band, "what kind of design
  are we able to do here? what are our constraints?" then "let's do some
  variants in an html editor" then "open the static html please". On forcing a
  rotation: "can we force /rotation when context is critical?", then "diff
  between force with grace and force rotate only", then "with grace". On the
  logo: "let's generate an icon for our tool", "go", "use gpt-image-2.5",
  "C1 i LIke", "c1 b is nicer", "commit", "can we use it somewhere?",
  "1 and 3". On the branch: "merge".
