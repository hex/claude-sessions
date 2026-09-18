---
name: abort-never-deletes-published
description: "An abort must delete only what its own run created; order the staging so failure leaves nothing, instead of guarding a cleanup"
metadata:
  node_type: memory
  type: project
---

Fixing `cs -spawn` on 2026-09-17 (#640 minor 4), the first fix made a failed
seed write remove the brief it had staged — correct for one process, wrong the
moment two spawns of the same name interleave: A's failed `mv` deleted the
brief **B had already published**, and B then launched without it. Codex found
it; no test of mine could have, because the race cannot be staged reliably.

The fix was ordering, not a guard: write the content that can fail to a temp
file first, stage the dependent file second, publish the signal last. A
failure at any step then leaves nothing behind and touches nothing another run
owns, and a failed final rename means a peer consumed the path — its files are
not this run's to remove.

**Why:** cs's staging directories (`$SESSIONS_ROOT/.spawn`, locks, seeds) are
shared by name across concurrent processes, and "last writer wins" is only
benign while nobody deletes.

**How to apply:** before an abort deletes anything, ask whether this run
created that exact file. If it cannot know, do not delete — reorder so the
question never arises. Related: [[commit-before-mutating]],
[[verify-the-mutation-landed]].
