---
parent: 4a1fde55-8afe-4076-aa94-eae817d4624a
created: 2026-09-15T13:49:05Z
purpose: test the visual and the feeling of the cs-rotate mod live (capsule band, the 1-key press, the armed /clear state) and build what that turns up; the v2026.9.16 release (#622) stays held until after that
status: unconsumed
---

## 1. Next Step

Alex's words at the rotation gate: "/rotate but we need to do some more tests/features like testing the visual and the feeling of the mods". So:

1. Launch a throwaway cs session in a tmux window with the installed main (`e779dc0`) and the cs-rotate mod (the launch exports `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` itself). Use the driver from the last measurement pass: `scratchpad/live/drive.sh` in this conversation's scratchpad (`/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/4a1fde55-8afe-4076-aa94-eae817d4624a/scratchpad/live/`) — positional prompt bypasses FleetView, trust dialog is Down+Enter in a fresh dir, bind `.cs/local/state` to the newest transcript uuid, wait 2 s after the label appears before pressing, `NO_PRESS=1` to only look, `MOD_ENV=...` to pass env. Evidence from the last pass sits in `.cs/research/spike-rotate/mod-evidence/` (captures 13–20).
2. Capture the three states with `tmux capture-pane -e` and show Alex screenshots/renders: (a) band below the warn threshold (nothing drawn), (b) the capsule at ≥40% ctx (`CS_ROTATE_BUTTON_CTX=0` in the launching shell forces it at once), (c) the armed state after `/rotate` (label `1: /clear and continue from the handoff`, coral border). Then press `1` in each of (b) and (c) and record what runs.
3. Ask Alex what feels wrong; his design bar for this is "sexier, cs style" and "match claude's own UI chrome" (memory: user_visual_design_direction). Build what he names, on a branch, red-first, Codex pass, full suite, merge on his say.
4. Only after that: resume `/release` for v2026.9.16 (#622). See Pending Tasks.

## 2. Settled and rejected

- Capsule design: Alex chose **"Keep it"** at the gate after the redesign (round box, Claude mark, plain `1: label`, gauge in the bar's own pie/inks). Do not redesign unprompted; wait for what the live test turns up.
- The press must **execute** `/rotate`, not type it: `$.command.run({command:'rotate',args:''})` is measured to run it (mod-evidence captures). `$.prompt.fill`/`$.prompt.submit` are banned by `tests/test_mod_rotate.sh` (validate output must not list them).
- Hotkey `"2"` typed a literal `2` when measured — one button only; do not add a second hotkey.
- Two mods drawing hotkey-1 buttons collide; a press right after the label appears typed `1` — wait 2 s after the label before pressing (measured).
- Bare `claude` in a dir with prior sessions opens FleetView (Escape quits claude); always launch with a positional prompt.
- Statusline session name: Alex, this conversation: "why do we have the session name colored in the status line? it shouldn't be, only /color should be applied" → #615 reverted (`c004bdd`, merged `abf4422`). Do not colour the name again.
- `cs erpk-ai-costs` "already running elsewhere" while `cs -live` showed nothing: the guard matched the bare UUID in an orphaned Bash-tool zsh's argv (shell snapshot exports `CODEX_COMPANION_SESSION_ID`); fixed in `dd55642` (merged `f777470`). A bare UUID in `ps` is not a running claude.
- `CS_NARRATIVE_MAX_BYTES=00` was a zero-byte budget in every reader (validator matched a lone `0` before normalising); fixed in `3b6dccb`. Pre-existing, found by a Fable review.
- Release shape (memory, unchanged): push content first, tag only after CI is green; never push/tag/commit the release without Alex's explicit approval.
- Ghost (remote test host) still denies ssh publickey in BatchMode; full suites run locally (10–12 min each, half the cores).
- Fable review declined items on #624: naming `narrative.unknown.md` when the actor is unresolved (partial-install path; the note beside it says unresolved) and `test_strip_filters_in_sync` now mechanism-only (kept, harmless). Two KEEP IN SYNC sites deliberately untouched: statusline declined-marker (install.sh↔lib/70) and ZSH_COMPLETION_DIR (install.sh↔lib/85).
- Attribution: from mid-conversation the harness said no `Claude-Session:` trailer on commits any more; commits from `3259d97` on carry none.

## Conversation-only facts

- Unpushed: main `e779dc0` is 17 commits ahead of origin (`git log origin/main..main`), tree clean, nothing tagged. The last CI-green push was `ee985d4` (run 34949654089, 6/6).
- Measurement for #602 (teammate truecolor): in this lead's shell `CLAUDE_CODE_TMUX_TRUECOLOR=1`, but `tmux show-environment` (session and `-g`) said `unknown variable`. On an isolated server started with `env -u CLAUDE_CODE_TMUX_TRUECOLOR tmux -L …`, a pane split before `set-environment` printed `before=unset`, one split after printed `after=1`. A first attempt without `env -u` printed `before=1` (server inherited the shell) — invalid, discarded.
- Codex on #602 (read the installed 2.1.272 bundle): Claude Code's inside-tmux teammate path splits the LEAD's current window (so session-scoped `set-environment` reaches it); its EXTERNAL teammate path uses a separate tmux session, which this fix does not cover.
- The old cs on a pinned identity without a trailing newline resolved fine (measured with main's `bin/cs`: `actor: carol-team-io`); a reviewer's inferred failure did not reproduce. Test kept as a pin only.
- The stale orphan pid 40334 (`zsh -c … port-forward …`, ppid 1, started 11:08) may still be alive on this machine; harmless now.
- Suite timings observed: test_rotation 370 s, test_finish_script 280 s, test_hooks 187 s, test_uuid 100 s, test_session_lock 78 s.
- Reviewer agents `review-624` and `review-626` (Fable, read-only) reported and are idle; review-626 admitted one stray write to `/tmp/a`.
