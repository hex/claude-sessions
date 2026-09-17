---
name: cs-dev-repo-ignores-cs
description: "This repo (the cs dev repo) gitignores .cs/ wholesale (.gitignore:18): narrative and memory are machine-local and never committed; worktree sessions of this repo run in ignored mode"
metadata:
  node_type: memory
  type: project
  originSessionId: 8e694ff5-5bac-4952-a02b-4429adf622fb
---

Discovered 2026-07-02 when a narrative commit was refused: the cs dev repo's own .gitignore excludes `.cs/` entirely (line 18), unlike normal cs sessions where `.cs/` is tracked and merges via drivers. Consequences: the narrative and memory files here exist only on this machine and never sync through git; "commit your journal entries" is structurally impossible in this repo; and any worktree task session of this repo takes the ignored-.cs path (bootstrapped per-worktree `.cs/`, records fused explicitly by `cs --merge` rather than by merge drivers).

**Why:** the tracked-.cs assumption holds for most sessions but not for this one, and this repo is the primary dogfooding target. It also means ambient session env can leak into tests run here: a doctor test passed only because CLAUDE_SESSION_META_DIR was inherited from the live session, exposed by `env -u`.

**How to apply:** never design cs features assuming `.cs/` is tracked; both modes exist and this repo exercises the ignored one. When writing tests in this repo, isolate env explicitly (export the session vars the code under test reads; verify with `env -u`). Attribution via `git log .cs/memory` does not work here. The handoffs under `.cs/handoffs/` are force-tracked inside the ignored tree: a plain `git add` on one refuses ("paths are ignored") with a non-zero exit, which breaks any `&&` chain around it and silently skips the push behind it (measured 2026-09-02); use `git add -f` for those files. Related: [[cs-multi-user-safety]].

**Extension (2026-09-16):** for the already-tracked `.cs/` files (handoffs, this actor's
narrative) `git commit -m ... -- <path>` commits them without any `add`, which is simpler than
`git add -f`. Never run `git checkout <sha> -- .` in this repo: it rewinds those tracked `.cs/`
files to that commit and silently discards uncommitted narrative appends (it did, once, during the
v2026.9.16 install; the lost paragraph had to be re-typed from context).
