---
name: claude-scratch-disk-pressure
description: /private/tmp/claude-501/<session-dir> scratchpads grow to many GB (fignity 9-12 GB) and the Data volume hit 100% mid-gate on 2026-09-16; Alex authorised deleting the scratch of sessions with NO live claude process, judged by lsof cwd, never by tmux window names
metadata:
  type: project
---

Claude Code's per-session scratch under `/private/tmp/claude-501/` is never pruned. On 2026-09-16 the
Data volume reached 100% (1.1 GB free) in the middle of a gate; tool output could no longer be written
and ghost/Codex could not be relaunched. The bulk of the 874 GB used sits outside `$HOME` (Application
Support 90 GB, .claude-sessions 33 GB, scratch ~19 GB), so the scratch is the piece cs can name, not the
cause.

**Why:** a full disk fails silently in odd places first (a background Bash task's output file); knowing
what is safe to remove without asking twice saves the gate.

**How to apply:** when the disk is full, offer three options and let Alex pick; his pick was "clear
claude scratch of closed sessions". Closed = no live `claude` process whose cwd (lsof -d cwd) is that
session directory; tmux window names are not the authority (a window named after one session held a
pane of another). Delete by explicit path list, never by predicate. bash-edit-diff (0.7 GB) is a
harmless cache. Never touch the scratch of a live session: this conversation's task outputs live under
the PREVIOUS conversation's uuid dir, which is still in use after a rotation. See
[[destructive-commands-explicit-targets]].
