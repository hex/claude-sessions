---
name: full-gate-runs-on-ghost
description: EVERY full test gate for cs runs on the ghost machine through the claude-tmux remote-tests script, never on the dev box; a mods-only or tests-only change is not an exemption
metadata:
  type: feedback
---

Alex, 2026-09-05, when a full `tests/run_all.sh` started locally: "why didnt you run it on ghost?"
The remote-tests script in the claude-tmux plugin (`--host ghost@ghost --repo <path>`) rsyncs the
checkout, runs the suite detached, and leaves `suite.status` with the exit code; poll that file
from a background loop and read the verdict, never `grep -c "not ok"`.

**Why:** the local gate loads the dev box and its statusline for minutes, and ghost exists for
exactly this. Both machines are macOS, so a BSD-only construct still passes on both; CI's ubuntu
and windows lanes are the only GNU check. See [[mktemp-template-form]], [[gate-one-at-a-time]].

**How to apply:** `--changed` locally for the edit loop; any FULL run goes to ghost, one suite at
a time on that box; chain a second repo's suite behind the first with a wait on `suite.status`.

Repeated 2026-09-16 ("why don't we run them on ghost?") after a full run for a mods/ + tests/ +
docs/ branch ran locally at 7 jobs: load 22-28 for 40 minutes, the SessionStart hook under the
inherited TMUX renamed Alex's live window `cs: test-session` (task #630), and the 3 s
scope-prompt hook was killed on one of his prompts (task #631). "Only mods changed" was the
rationalisation; the cost is the same whatever the diff touches.
