---
parent: be426d62-7e0d-44ae-a03a-98d36f355787
created: 2026-09-18T08:05:50Z
purpose: find why the status line takes seconds to appear at session open, and decide whether cs should pre-accept the folder-trust dialog for directories it creates
status: unconsumed
---

## 1. Next Step

Measure the one thing this conversation could not: **when Claude Code first
paints the status line in a session that is NOT showing the folder-trust
dialog**, and why it is not at the first render.

The probe that failed and how: a throwaway `cs slprobe` in a tmux window, a
driver polling `tmux capture-pane` for the bar and `~/.claude/agents-sidebar-status/`
for a new `<pid>.json`. It reported **"launch -> first bridge publish: 1.7s"**
and **"no bar seen in 120s"** — because the session sat on the trust dialog the
whole time (a brand-new directory). Re-run it against a session whose directory
is already trusted (any existing cs session, or set the flag first — see below),
and instrument what sits between the first publish and the first paint.

Two candidate causes, neither confirmed:
- Claude Code withholds the first paint until its UI settles.
- The first render is killed for overrunning. The sidebar bridge's own header
  asserts this: *"Claude Code runs this every tick in every session, kills a
  render that overruns, and a new session shows nothing until one render
  completes"* (`~/.claude-sessions/iterm-agents-sidebar/plugin/statusline-bridge.sh`,
  ABOUTME block). That is the bridge author's claim, NOT something this
  conversation measured — treat it as a hypothesis to test, not a fact.

Then, if Alex still wants it, the folder-trust bypass (section 2 has the
finding and the two open questions). Nothing is committed for it yet.

## 2. Settled and rejected

- **The delay is NOT cs-statusline's render cost. Measured** on this machine,
  Claude Code 2.1.276, with a hand-built payload file:
  - warm: **0.16 s, 0.21 s** (`~/.local/bin/cs-statusline < payload`)
  - warm, earlier batch of 3: **0.89 / 0.74 / 0.82 s**
  - through the sidebar bridge: **1.51 / 0.82 / 0.53 s** (first is the cold fork)
  - cold cache (`HOME` pointed at an empty dir, `~/.cache/cs` absent):
    **0.69 / 0.26 / 0.30 s**
  All inside the 1 s `refreshInterval`. So "the render is slow" is rejected as
  the explanation for a multi-second wait.
- **Where a warm render spends its time. Measured** by xtrace with
  `PS4='+ $EPOCHREALTIME '`, 920 traced lines, 0.434 s total (xtrace inflates
  the absolute number; the ranking is the point). Top gaps:
  `jq` on the stdin payload **133.5 ms**, `mv` publishing
  `.cs/local/context-pct` **81.4 ms**, `ps -ax -o pid=,ppid=` **78.7 ms**,
  the ancestry `awk` **58.7 ms**, `tmux display-message` **57.7 ms**. Everything
  else was ≤1.3 ms. That is the per-tick floor if anyone wants to cut it.
- **The usage refresher does not block a render.** Read in source:
  `bin/cs-statusline:1733` forks it —
  `( "${BASH:-bash}" "$_SL_SELF" --refresh-usage >/dev/null 2>&1 & )`.
- **Folder trust is one per-project boolean.** Read in source
  (`~/.claude.json`, parsed with python): `projects["<dir>"].hasTrustDialogAccepted:
  true`. It is the ONLY trust key across all **222** recorded projects on this
  machine; `/Users/alex.geana/.claude-sessions/claude-sessions` carries
  `{'hasTrustDialogAccepted': True}`. The bundle's readers are
  `checkHasTrustDialogAccepted` and `getHomeTrustDialogAccepted`
  (strings in `~/.local/share/claude/versions/2.1.276`). **No CLI flag or
  setting disables the dialog** — `--dangerously-skip-permissions` is the
  permission mode and is unrelated; do not reach for it.
  - REJECTED as an approach until Alex decides: pre-trusting an **adopted**
    session's directory. cs creates a new session's directory itself and can
    vouch for it; an adopted repo is someone else's tree and silently answering
    a security prompt there is a different act.
  - OPEN RISK, not yet measured: `~/.claude.json` is rewritten constantly by
    every live claude. A read-modify-write from cs can land between two of
    theirs. Losing our own flag is harmless (the dialog returns); clobbering
    their concurrent write is not.
- **Auto-compact facts, read in the 2.1.276 bundle** (strings on the binary,
  not docs), from the question that opened the conversation:
  - Two paths: proactive at a threshold, and reactive — *"The summary was
    generated in the background at the autocompact threshold and swapped in
    when prompt-too-long fired"*. So the real backstop is the API rejecting an
    oversized prompt.
  - Knobs: `/autocompact`, `--autocompact <auto|tokens>`,
    `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `autoCompactWindow`. `/context` shows an
    "Autocompact buffer" row. There is a circuit breaker
    (`autocompact: circuit breaker tripped after `) and `autocompact_thrashing`.
  - **`CLAUDE_CODE_DISABLE_1M_CONTEXT` is not a ceiling**, verbatim: *"the …K
    limit isn't enforced for …, so this session can grow past it. To enforce
    it, set CLAUDE_CODE_AUTO_COMPACT_WINDOW="*.
- **iTerm tab title across panes: handed to another session, not built here.**
  Alex asked whether a tab holding several cs panes could read
  `cs: erpk-ai-costs | claude-sessions | empire`. Findings: cs writes OSC 0
  (`lib/05-term.sh:222`), which in iTerm names the PANE, and the tab shows the
  active pane's — panes cannot compose a shared string through escapes at all.
  `iterm2.Tab.async_set_title()` exists in the installed API (checked by
  importing `iterm2` and listing `dir(iterm2.Tab)`); `iterm2.Session` has
  `async_set_name`. Alex chose to route it to the **iterm-agents-sidebar**
  session, which already holds a resident connection, a `LayoutChangeMonitor`
  (sidebar.py:2364) and a per-tab pane map (`panes_in_tab`, sidebar.py:478-486).
  Sent with `cs -msg iterm-agents-sidebar` (thread **a61d7d**). cs needs no
  change; do not build it here.
- **`cs -msg --kind task` rejects a multi-line body** — "task bodies must be a
  single line (the queue's done log and listing are line-oriented)". Measured
  by hitting it. The handoff above went as a plain text message instead, so it
  surfaces at that session's next turn rather than entering its queue.

## 3. Conversation-only facts

- **The trap that cost the most: a "cold cache" probe that ran
  `cp -R ~/.claude-sessions` into a temp HOME wrote 30 GB before I killed it**
  (`du -sh` read 30G; killed by pid, tree removed, disk fine afterwards). The
  sessions root is enormous. To simulate a cold cache, point `HOME` at an
  EMPTY directory — that took under a second and gave the numbers above.
- The `/codex:review` run this conversation launched returned **"no actionable
  defects ... a memory entry and untracked scratchpad artifacts, with no staged
  changes"** — it reviewed the WORKING TREE only, which at that moment held just
  an uncommitted narrative edit. It did **not** review the forced-rotation
  branch, which was already committed. `/codex:review` is native-review only;
  for a branch, `/codex:adversarial-review` with the scope pinned is the one to
  use. Do not read that clean verdict as a pass on #654.
- Alex's decisions this conversation, in his words:
  - "You run all" — run the live wrap-key check myself and take #640 in the
    same pass, rather than handing him the steps.
  - "it should be on by default" (forced rotation). Asked two either/ors; he
    took both recommendations: **80%** threshold, **announced once per machine**.
  - "merge" twice — for #640 and for the forced-rotation branch.
  - On the tab title: "Hand to iterm-agents-sidebar".
- The wrap-key live measurement (#653), **measured on 2.1.274**: a Stop hook
  that wrote the marker and blocked once; after the continuation turn the
  marker still equalled the session id and the band read ` 1: rotate this
  conversation` ALONE; a typed control prompt then emptied the marker and
  ` 2: wrap up this session` came back. Evidence under `scratchpad/wk-live/`
  (untracked): drive2.sh, drive.log, cap-*.txt, stop-once.sh, settings.json.
- Two traps from that probe, both worth keeping: **the cs-rotate band does not
  draw before a conversation's first turn** (`context.percent` is undefined and
  the mod returns early), so a driver must take a turn before waiting for the
  band; and **editing a driver script while bash is still reading it** corrupted
  the run — the first driver was killed by pid and re-run from a copy.
- Codex's review of the #640 branch produced **7 findings in two groups** (it
  restarts numbering at 1 for the second group, which is why asking for "5, 6,
  7" returned the first four twice). All seven were folded. The one that
  matters most: **my own first fix for minor 4 was a worse regression than the
  bug** — the cleanup deleted `$sdir/$name.brief.md`, which a CONCURRENT spawn
  of the same name may have published, so that spawn launches without its
  brief. Fixed by ordering, not a guard. That lesson is now a durable memory,
  `project_abort_never_deletes_published.md`.
- **The vacuous-test class hit three times in one day** and each time the suite
  was green: the scope-budget test (twice — a second-resolution clock reads
  elapsed 0, so the branch was never reached) and both Retry-After tests (a
  credential failure writes the same 600 s fallback the test asserted). Each
  fix was verified by mutation. The `_deny_file_write` helper now in
  `tests/test_lib.sh` exists because a `chmod 400` fixture denies nothing as
  root or on a permissive filesystem.
- `tests/test_mod_rotate.sh` gained a cross-language pin only after **three
  attempts**: the first failed for the wrong reason (a brittle sed pattern
  reported "not found", which looks like a pass for a different cause), the
  second scraped `return 0` into the number with `tr -dc '0-9'` and produced
  `800`, and only the third — `grep -F` the line, `sed` the echoed number —
  goes red on a real mismatch. Verified by mutating both defaults.
- Context was ~40% when the rotation band's notice fired; this handoff is being
  written from live context, no compaction, so the facts above are first-hand.

## Completeness (pass one)

Written from live context at roughly 45%, no compaction. Pass two appends the
recoverable sections (request history, concepts, file map, pending tasks,
current state).
