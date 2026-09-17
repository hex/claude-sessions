---
name: path-shim-exec-absolute
description: "A PATH shim that counts execs must exec an absolute path; `exec find \"$@\"` or `exec \"$(command -v find)\"` recurses forever under the zsh Bash tool"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7cc98cc6-b428-41cd-b399-a06757e3d319
  modified: 2026-09-17T09:55:19.141Z
---

Two sessions on 2026-09-17 built an exec-counting PATH shim (`shim/find` first on PATH) whose last line was `exec find "$@"` or `exec "$real"` with `real=$(command -v find)`. Under the zsh Bash tool `command -v find` prints the bare name, so the exec resolved to the shim again and looped: 121,549 log lines, orphans at ppid 1 for 44 minutes, and a "find ~150/s fork storm" (task #642) that was the instrumentation measuring itself.

**Why:** the loop looks exactly like the defect under investigation, and the pre-shim logs (Falcon, `log stream`) were the only thing that disproved it.

**How to apply:** resolve the real binary with `/usr/bin/find` (or `type -P` under `/bin/bash`, never zsh `command -v`), exec that absolute path, and before trusting any shim count check that the log carries more than one distinct command. See [[bash-tool-is-zsh]] and [[measure-before-you-poll]].
