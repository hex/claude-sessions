---
name: full-gate-runs-on-ghost
description: EVERY test suite for cs runs on the ghost machine through the claude-tmux remote-tests script, never on the dev box; a mods-only change is not an exemption and neither is running a SINGLE suite locally
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

Repeated a third time 2026-09-16 ("why do we run tests here? it hogs the machine") when ONE suite
(`tests/test_hooks.sh`, twice: a mutation pass and the real pass) ran locally at load 32. A single
suite is not an exemption either. What IS fine locally: `bun test` for a mod, `tests/test_mod_rotate.sh`
(seconds), and a one-second in-process check that sources test_lib and runs one test function against
a mutated helper. Anything that runs `tests/test_*.sh` end to end goes to ghost.

**Caveat (2026-09-16, the v2026.9.16 release):** ghost runs bash 5.3, so eight green ghost runs
never reached a line that only stock bash 3.2 rejects (`"$EPOCHREALTIME"` inside a double-quoted
string under `set -u`; CI's macos-latest lane went red). The gate's only bash-3.2 judge is CI. A
3.2-specific defect is reproduced with a one-line `/bin/bash -u -c` probe and the ONE suite it
lives in run under `/bin/bash` with `/bin` first on PATH; that is a targeted verification, not the
full run, and the push to CI is still the verdict. See [[release-gate-skips-ci]].
