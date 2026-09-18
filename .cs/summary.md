# Session Summary: claude-sessions

**Date:** 2026-09-18
**Duration:** one conversation, about 16:00 to 18:35 EEST (the session itself has run since 2026-02-07; this summary covers today's conversation, which started from the `verify-first-paint-live` handoff after a `/clear`)

## Objective

Three things, in the order they arrived. First, the handoff's next step: watch the tmux-ancestry deferral shipped in #659 paint a real fresh conversation's first status line, since every number so far came from a rigged `ps`. Second, a queued walk-away task from the firstborn-server session: make `/write-as-me`'s corpus builder append `.voice/sources/*.md` so hand-kept voice sources survive a rebuild. Third, on Alex's `/release`, ship cs v2026.9.18, with `/wrap` once it landed.

## Environment

macOS on the dev Mac, inside a cs-managed tmux pane; the session directory is cs's own source checkout with origin at github.com/hex/claude-sessions. Claude Code 2.1.27x. Ghost (the remote test host) was unreachable all day, so every suite run was local and CI's macOS lane was the only bash 3.2 judge. Codex companion 1.0.6 for the two adversarial passes; three Claude subagents for the release range review.

## Key Discoveries

- **#659 holds live, with a thin margin.** Untraced, across seven valid fresh launches, the status line filled 0.49 to 0.84 s after Claude Code drew its footer (one outlier at 2.51 s), and the per-conversation `tmux-real` cache held `real` with `tmux-walking` empty in 9 of 9 traced runs. With the sidebar bridge's trace on, the first tick took 1.13 to 1.43 s, printed a complete line, and Claude Code never drew it; the bar came from tick 2 or 3, three to four seconds in. The cut-off sits between 0.84 s and 1.13 s and is bracketed, not measured. A printed tick is not a painted bar, and a traced arm must never be compared to an untraced one.
- **A timing test that sleeps a fixed interval measures the runner, not the property.** `test_a_stalled_walker_is_killed_before_its_mark_expires` passed every local Mac (bash 5 and `/bin/bash` 3.2) and failed on the GitHub macOS runner on both pushes of the release content, because ten `sleep 0.1` polls plus forks take longer than the test's 1.6 s pause there. The claim is "killed before the 10 s mark expires", so the test now polls for the kill with an 8 s bound, and it still goes red when the `kill -9` is removed.
- **The forced-rotation notice announced a rotation the mod could not run.** With function hooks withheld (`CS_NO_FUNCTION_HOOKS=1`, or a `0` from the shell) the cs-rotate mod never loads, yet the launch printed "cs now rotates a conversation on its own" and spent the once-per-machine marker, so a machine that turned hooks on later would never be told. Found by the release range review, verified in source, fixed red-first including a test through `cs` itself.
- **The bash and TypeScript readers of `CS_ROTATE_FORCE_CTX` disagreed on inner whitespace.** `tr -d '[:space:]'` read `"1 5"` as fifteen; the mod's `.trim()` reads it as a typo and the default. The shell now trims only the ends.
- **No render-path test let the deferred walker cache `real`.** Both existing deferral tests used a foreign-only `ps` table, so swapping the walk's start pid from `$_PARENT` to the render's own `$$` survived the suite. A new test with the parent placed under the tmux server catches that mutation (applied and watched fail).
- **A named subagent's idle notification truncates its report at about 16 KB**, cutting a findings list mid-item. Asking for a specific section by SendMessage ("resend findings 6 and 7 and the tally") works; asking for the whole report truncates again.
- **Keying a CI poll on "completed" matches the wrong run.** A narrative commit pushed after the release commit became the newest run on main, and a `case` on the word `completed` reported its verdict as the release's. Select the run whose `headSha` equals the pushed sha.

## Changes Made

**#660, live first paint (measurement only, no code).** Probes `livepaint{,3,4,5}.sh` in the scratchpad: fresh `cs spike-band` launches on an isolated tmux socket, watched by `capture-pane`, timed by the bridge's own trace or by the pane alone. The spike-band session's stale project `statusLine` override (pointing at a dead probe script) was moved aside into the scratchpad, on purpose, and not restored. Findings saved as the `statusline-first-tick-budget` memory.

**#661, supplementary voice sources (merged `bcafcf1`, then `e8572d9`).** `skills/write-as-me/scripts/build-corpus.sh` appends every `$VOICE_DIR/sources/*.md` after the short-ack appendix, in name order, each under `## Supplementary source: <file>` with a leading `# ` title dropped; the header gains `Supplementary sources: N file(s)` only when N > 0; source lines pass the same credential redactor (`looks_secret` hoisted into a shared `LOOKS_SECRET_DEF`); the corpus file is written 600 on Alex's "tighten it to 600". `SKILL.md` names the sources directory and says a source outranks extrapolation for the register it covers. Four TDD slices, 29/29 corpus tests, 4/4 skill pins, a real build over 5452 transcripts appending two sources (22673 and 246 lines, 0 redactions), Codex review and adversarial review both approve. The live `corpus.md` was rebuilt on Alex's "you run it and check".

**Release v2026.9.18 (tag on `9ce826a`).** The range review's fixes on `fix/release-review-2026-9-18` (merged `35be897`): the notice gating and whitespace parity in `lib/75-launch.sh` with five new rotation tests; the real-verdict deferral test, a deterministic no-mark assert in the refresher test, `tmux-walking` in the sweep test, and a staged umask in the corpus permission test; eight doc corrections (README rotation tiers, hooks.md's stale "crit band 65" advice, two "sub-second"/"under 1000" wordings against the code's `-le 1000`, session-layout's `budget=` trace line, statusline's two-versus-four swept buckets and the Retry-After hour cap, configuration.md's "off unless set"). Then the version bump to 2026.9.18, the approved notes folded into CHANGELOG, and, after the macOS red, the stalled-walker test fix (`57feb0b`, merged `9ce826a`).

## Key Files & Outputs

- `skills/write-as-me/scripts/build-corpus.sh`, `skills/write-as-me/SKILL.md`, `tests/test_write_as_me_corpus.sh`, `tests/test_write_as_me_skill.sh` — supplementary sources, redaction, mode 600, pins.
- `lib/75-launch.sh` (and the assembled `bin/cs`), `tests/test_rotation.sh` — notice gated on `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`, end-trimmed threshold, three new tests including one through a launch.
- `tests/test_statusline.sh` — real-verdict deferral test, deterministic refresher assert, sweep coverage, poll-for-the-kill in the stalled-walker test.
- `README.md`, `docs/hooks.md`, `docs/configuration.md`, `docs/session-layout.md`, `docs/statusline.md`, `CHANGELOG.md` — doc corrections and the 2026.9.18 entry.
- `lib/00-header.sh` — VERSION 2026.9.18.
- `.cs/memory/project_statusline_first_tick_budget.md`, `.cs/memory/project_ci_macos_runner_timing.md` — new memory entries; `feedback_background_the_ci_poll.md` and `feedback_subagent_final_message_deliverable.md` extended.
- Scratchpad (throwaway): `livepaint*.sh`, `out*/` probe runs, `release-notes.md`, `corpus.before.md` (the pre-rebuild corpus with Alex's hand-added section), `spike-band.settings.json.moved-aside`.

## Outcome

All three objectives met. cs v2026.9.18 is released on `9ce826a` with CI 6/6 green on that sha (the first release commit `ab60b01` was red on the macOS lane and is not tagged), the release workflow green with twelve signed assets, and the build installed locally: `cs -version` 2026.9.18, doctor deploy drift OK. #660, #661 and #662 are closed in the native task list. Alex's rulings during the day: Start the queue, merge, tighten to 600, run and check, Approve the notes, wrap when finished.

Left as follow-ups, none blocking: six finder-a Minors on the ancestry walker (a permanently stalled `ps` respawns a walker every ~6 s because the walker clears its own mark after a deadline kill; `wait` after `kill -9` is unbounded; an unwritable `~/.cache/cs` means a walker per render and foreign never detected; `CS_STATUSLINE_WALK_DEADLINE` is an undocumented test knob; the mod parity test checks only the default and `off`; `register.test.ts:368` folds two cases into one). Also: a build with zero typed transcripts still exits "nothing to learn from" even when sources exist; an unused `wrap` variable at `tests/test_write_as_me_corpus.sh:329`; the real corpus build takes over five minutes on this machine.

## Notes for Future Reference

- Judge first paint from the pane, footer-seen to row-filled, never from a `cold-printed` trace event, and keep the cold path under about 0.8 s including the bridge.
- Consecutive probe launches of one session need about 10 s apart or the live-duplicate guard voids the run; `kill-server` on the probe socket does not end the claude process at once.
- `/codex:review` in companion 1.0.6 rejects any text after the flags; `--base main` alone reviews HEAD's branch. Its sandbox cannot create fixtures, so its "no findings" is weaker than a suite run.
- When ghost is down, push the release content before the release commit and let the macOS lane judge it; tag with `--target <full sha>` on the green commit.
- `.cs/memory/` is gitignored wholesale in this checkout: new memory files are machine-local, and only the already-tracked narrative, `MEMORY.md` and handoffs commit by explicit path.
