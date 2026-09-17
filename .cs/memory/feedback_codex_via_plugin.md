---
name: codex-via-plugin
description: "Alex (2026-09-17) wants Codex used through the /codex: plugin (codex:rescue skill, codex:codex-rescue agent), never a raw `codex exec` from Bash"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 655bde7e-d351-4345-a86e-24ba3c1e59b2
  modified: 2026-09-17T09:25:02.431Z
---

Run Codex reviews and rescues through the `/codex:` plugin (`codex:rescue` skill or the `codex:codex-rescue` agent), not a hand-rolled `codex exec --sandbox read-only ... > report.md` from the Bash tool.

**Why:** Alex said so mid-review on 2026-09-17 ("when we use codex we should use it with the plugin /codex:"). The plugin owns the runtime, the result handling and the sandbox choice; the raw form also stalled once waiting on stdin until the call closed it, and reads prior report files as instructions when pointed at them.

**How to apply:** for a falsification round, invoke the skill with the brief inline (never a path to a prior report), and let the plugin's result handling deliver the verdict. Related: [[foreign-model-pass-on-research]], [[codex-prompts-with-shell-operators]].
