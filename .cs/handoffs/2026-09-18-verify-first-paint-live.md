---
parent: 93a26e53-349e-497f-b923-e180dbeaedf4
created: 2026-09-18T12:57:31Z
purpose: watch the merged ancestry deferral paint a real fresh conversation's first status line, since every measurement so far used a rigged ps
status: unconsumed
---

## 1. Next Step

**Watch #659 work in a live conversation.** Everything merged (main at
**09a4dd8**, installed, drift OK) was measured against `ps` fakes — a `sleep 2`
and a `sleep 60` in a PATH shim. Nobody has yet opened a real fresh cs session
and looked at whether the bar paints on the first render.

That is the honest gap, and it is cheap to close:

1. Open a throwaway cs session in a tmux window (`cs -spawn` or plain
   `cs <name>` in a new window), on a directory Claude Code already trusts.
2. Watch the status line. The claim to falsify: the bar appears at the FIRST
   render Claude Code asks for, instead of after 3-9 retries.
3. Check the caches afterwards: `~/.cache/cs/tmux-real/<parent>,<TMUX>` should
   hold `real`, and `~/.cache/cs/tmux-walking/` should be empty (the child
   clears its own mark).

A timing harness that measures this properly already exists as prior art —
`scratchpad/slcold.sh` and friends from the previous conversation (see section
6). The trap those scripts were built to avoid: **anything inserted between
Claude Code and the render must export `CS_STATUSLINE_PARENT` naming the real
parent**, or every per-conversation cache misses forever and the measurement is
an artifact. That bug was hit twice in the previous conversation.

**If the bar still does not paint on render 1**, the remaining suspect is not
cs: the sidebar bridge at `~/.claude-sessions/iterm-agents-sidebar/plugin/statusline-bridge.sh`
owns ~6 s of the ~7 s (measured, previous conversation), and Claude Code's own
2-4 s startup floor before it asks for a status line at all is nobody's.

## 2. Settled and rejected

- **Assume REAL on a cache miss, not foreign, and not "omit the segments".**
  Decided this conversation. The handoff that framed it offered "omit the
  tmux-dependent segments or guess one answer", but there is no omit option:
  `SL_ENV_FOREIGN` drives the THEME (`bin/cs-statusline:380`, foreign forces
  dark over an inherited `CS_TERM_THEME`), the COLOUR LEVEL (`:638`, real tmux
  without `CLAUDE_CODE_TMUX_TRUECOLOR` drops to 256) and
  `_sl_invalidate_stale_bg` (`:417`). `_seg_pane` is the only segment and it is
  off the default order anyway. So the palette must pick something, and real is
  what every pane cs launches is. Cost accepted: a process that merely inherited
  `TMUX` draws its own terminal's palette for one render.
- **The detached child walks from `$_PARENT`, never from the render's `$$`.**
  `( ... & )` orphans the child, the render exits at once, and a walk from a
  departed pid finds no ancestor-table entry — indistinguishable from foreign,
  so it would cache `foreign` for 300 s on a real pane. Related bash-3.2 detail:
  inside `( ... & )`, `$$` is the INVOKING shell's pid (`$BASHPID` would be the
  child's, and is bash 4+).
- **A forked subshell, not the `--refresh-usage` re-exec idiom.** `:1733`
  re-execs the whole 95 KB script (260-320 ms of bash load) and needs
  `CS_STATUSLINE_PARENT` forwarded by hand — the exact omission that broke two
  earlier attempts. A plain forked subshell already holds every function and
  carries `_PARENT` as a shell variable, so that class of bug cannot recur.
- **Stale-first rendering: BUILT, REVIEWED, DROPPED** (branch
  `feat/statusline-stale-first` at **d51ed4d**, unmerged, on disk). Do not
  revive. The frame is keyed on Claude Code's pid — new every fresh
  conversation — and written only at the END of a surviving render, so no frame
  exists at the first request. It only ever served ticks 2+, which were never
  the complaint.
- **Raising `refreshInterval`: REJECTED, verified in source.** The attention
  pulse is second-parity at `bin/cs-statusline:1571` and `:1923`
  (`[ $(( ${_NOW:-0} % 2 )) -eq 1 ]`). An even interval samples one parity
  forever. `tests/test_install.sh:909` pins the value at 1.
- **Pre-accepting the folder-trust dialog: DROPPED by Alex** ("drop it the
  pre-accept trust"), previous conversation. Do not re-propose.
- **Codex round two's "detachment worsens the accumulation": WRONG, and I
  measured it.** See section 6. Alex chose to close the leak anyway.

## 3. Conversation-only facts

Everything below happened in this conversation and exists nowhere else.

**What shipped.** `fix/statusline-defer-ancestry`, four commits, merged
`--no-ff` into main as **09a4dd8**, branch deleted:

| sha | what |
|---|---|
| d9ee490 | the walk is off the first render; assume real, detached child from the parent pid |
| f893bc3 | one walk in flight at a time (`tmux-walking` mark, `TMUX_WALK_MARK_TTL=10`) |
| d9f9628 | the walker kills a `ps` that stalls (`TMUX_WALK_DEADLINE=5`, `_sl_ps_table_by_deadline`) |
| 25ea708 | `--refresh-usage` settles no terminal at all |

**Measured, first render, rigged `ps` that takes 2 s** (real script, two HOMEs,
`scratchpad/coldprobe`):

| | render 1 | render 2 |
|---|---|---|
| main (before) | 2386 ms, pane hidden | 175 ms |
| branch (after) | **167 ms**, pane SHOWN | 153 ms, pane hidden (corrected) |

**Measured, stalled `ps` that never returns**, 5 renders a second apart, each
render killed at 1 s the way Claude Code does (`scratchpad/stall/probe.sh`):

| | stalled walkers alive | bar |
|---|---|---|
| main | 5 | blank |
| d9ee490 | 5 | painted |
| f893bc3 (mark) | 1 | painted |

So the accumulation Codex round two called a regression was **pre-existing and
identical** — a killed render orphans its own `ps` at the same rate. Alex chose
to close it regardless.

**Measured, real clock, 24 renders 1 s apart, `ps` never returns**
(`scratchpad/stall/windows.sh`, after d9f9628): 4 walkers spawned across the
mark windows, **alive never above 1**.

**Gates on the landing sha.** `tests/run_all.sh` **67/67 exit 0** on 25ea708,
and separately 67/67 on d9ee490. `tests/test_statusline.sh` 239/239.
`tests/test_docs.sh` 6/6. CI's shellcheck line clean. **All local** — see the
ghost note below. After the merge: `./build.sh` left the tree clean,
`./install.sh` ran, the installed `cs-statusline` byte-matches the repo, and
`cs -doctor` reports deploy drift OK, artifacts stamped 2026.9.17.

**Four Codex adversarial rounds, in order:**
1. `"on <branch>"` as focus text — silently reviewed the WORKING TREE and said
   so itself ("The statusline fix is already committed at d9ee490 and absent
   from this diff"). Wasted.
2. `--base main`: medium, unbounded detached walkers. Folded (f893bc3) after
   measuring that it was pre-existing.
3. `--base main`: medium, expired marks spawn replacements beside walkers that
   never exit (~327 chains/hour). Folded (d9f9628).
4. `--base main`: **high**, the `--refresh-usage` re-exec walks synchronously
   with no deadline ahead of its own lock. Folded (25ea708).
5. `--base main`: **approve, no material findings.**

**Tooling fact, cost me a round:** `/codex:review` in companion **1.0.6**
rejects ANY argument text, including a bare branch name — `review "on x"` and
even `review --help` exit 1 with "does not support custom focus text". And
`/codex:adversarial-review "on <branch>"` accepts the text but **ignores it and
reviews the working tree**. Branch review needs `--base main`, full stop.

**Test-writing details worth keeping:**
- The fake `ps` must `exec sleep`, or the kill takes the `sh` wrapper and
  orphans the sleep, so the "alive" count reads the wrong pid.
- `tests/test_statusline.sh` has no single-test filter and costs ~5 min whole.
  `scratchpad/one.sh <test-name>...` builds a filtered copy with awk, runs it,
  deletes it.
- `settle_tmux_verdict <parent> <tmux>` (new helper in the suite) waits on the
  cache entry; it mirrors `_cache_key`'s two substitutions by hand.

**Alex's words this conversation:** "go" (twice, to proceed on a Codex
finding), "mail it, yes" (the base64 finding), "merge". On the stalled-`ps`
question he picked "Add an in-flight marker" from three options, having been
told it was pre-existing.

**Mail sent** to `iterm-agents-sidebar`, thread **162c73**, on Alex's say: the
base64 wall in his screenshot is THEIR `emit()`
(`plugin/hooks-handlers/emit-state.py` ~line 662), which base64s the whole
session state into one `OSC 1337 SetUserVar=claudeState` sequence (DCS tmux
passthrough when `TMUX` is set) and writes it to the tty on every hook event. A
sample decoded to `{"name": "verify:refute", "bodyKind": "agent",
"phaseIndex": 1, "phaseTitle": "Verify"}` — a workflow agent row. cs has no
base64-to-terminal emitter anywhere. Cause NOT measured: presumably a 9-reader
workflow grows the payload past what one sequence carries. No reply expected.

**Mail received** from `iterm-agents-sidebar` (thread 2b793f), THEIR
measurements not mine: Claude Code SIGKILLs a statusline run **1.76-1.99 s**
into the tick, **process group and all**; they could not reproduce the 5-9 s
first paint (2.15 s there). Their fix a247aa9 runs the render under `set -m` in
its own process group with the bridge waiting; 56/56 renders landed after.
Their ask — start the walk from `CS_STATUSLINE_PARENT` — is what 09a4dd8 now
does on every render path.

**Ghost is unreachable from this machine.** `remote-hosts.json` is absent from
the claude-tmux **2026.9.1** plugin cache, and `ssh ghost` gives
`Permission denied (publickey,password,keyboard-interactive)` for
`alex.geana`. So every suite run this conversation was local, against the
standing rule that every `tests/test_*.sh` run goes to ghost. CI macOS remains
the only bash 3.2 judge. Flagged to Alex, not worked around.

**Three things left unmeasured, and they should be said out loud rather than
discovered:**
1. **Never watched live.** Only rigged-`ps` probes. This is the Next Step.
2. **The walker shares its render's process group** (`( ... & )`, no `setsid`),
   so a render Claude Code group-KILLs takes its walker with it. The mark then
   holds the verdict for the rest of its 10 s while the bar draws as real.
   Benign under the assume-real choice, but unmeasured — and the sidebar's
   group-KILL finding above is exactly what makes it reachable.
3. **The refresher test asserts "never calls `ps`"** with a `ps` that answers
   instantly. It does NOT reproduce the pile-up Codex described.

## Completeness (pass one)

Written from live context at ~42%, no compaction. Every fact above is
first-hand from this conversation. Pass two appends the recoverable sections.

## 4. Primary Request and Intent

This conversation woke on `.cs/handoffs/2026-09-18-defer-ancestry-check.md` and
ran its next step: build **#659**, deferring the tmux ancestry check off the
cold render path. The handoff left one design question open (what the bar draws
while the verdict is unknown), which section 2 records as decided.

Alex's role through it: he ran each `/codex:adversarial-review` himself (the
command is his, not mine), chose to close the stalled-`ps` leak after being
told it was pre-existing, said "mail it, yes" to handing the base64 finding to
the sidebar, and said "merge" once the suite came back green and Codex
approved.

The through-line from the ORIGINAL complaint (the bar takes seconds to appear):
it decomposed into three owners — the sidebar bridge (~6 s, handed away, they
have since fixed their half), cs-statusline's cold render (1-3 s, this work),
and Claude Code's own 2-4 s startup floor (nobody's).

## 5. Key Technical Concepts

- **`bin/cs-statusline`** is standalone, NOT assembled by `build.sh` (unlike
  `bin/cs`). ~1750 lines, bash 3.2 + BSD compatible. `CS_STATUSLINE_LIB=1`
  sources it as a library without running `main` — how the suite reaches
  internal helpers.
- **The cache layer**: `_cache_read <kind> <identity> <max-age>`,
  `_cache_write <kind> <identity> <text>`, and now `_cache_forget <kind>
  <identity>` (which forks `rm`, so no render path calls it). Entries live at
  `~/.cache/cs/<kind>/<key>` as `epoch<TAB>identity\ntext`. Identity-guarded
  and torn-read-safe: a half-written entry, a missing file or a foreign
  identity is a miss, never a wrong answer.
- **The fork diet** (#632, #648) is a tested property: a warm render forks 2
  (bash + jq), 3 on bash 3.2 where a `date` fills the shared clock memo. Any
  change that raises this is wrong unless argued explicitly. #659 did not
  touch it — `test_warm_render_forks_only_the_interpreter_and_jq` stayed green
  untouched throughout.
- **The kill is not a fixed budget** (inherited from the previous handoff,
  measured there): renders spanning 618-1058 ms died; one at 755 ms lived and
  one at 322 ms died. Treat "under ~500 ms" as the only safe target. The
  sidebar's independent measurement (~1.76-1.99 s, group-KILL) is in section 3
  and does not obviously agree — worth reconciling if it ever matters.

## 6. Files and Code Sections

- `bin/cs-statusline` `_sl_defer_tmux_verdict` — the render-path entry. Reads
  the `tmux-real` cache; on a miss checks the `tmux-walking` mark, writes it,
  and spawns:
  ```bash
  ( { _SL_WALK_DEADLINE="$deadline"
      _sl_tmux_cached_walk "$_PARENT" "$_SRV" "$ident"
      _cache_forget tmux-walking "$ident"; } >/dev/null 2>&1 & ) >/dev/null 2>&1
  ```
  The `>/dev/null 2>&1` inside the subshell is load-bearing: an inherited
  stdout holds the render's output open and Claude Code waits for the walk
  anyway.
- `bin/cs-statusline` `_sl_ps_table_by_deadline` — backgrounds `ps` to a file
  under `tmux-walking/`, polls with `sleep 0.1`, `kill -9` by the recorded pid,
  empty table = rc 2 = no verdict cached. Child-only, because the poll forks.
- `bin/cs-statusline` `_sl_tmux_cached_walk` / `_sl_tmux_server` — extracted
  from `_sl_tmux_is_real` so the child and the synchronous path share one body.
- `bin/cs-statusline`, the load-time block (~:534): `_SL_DEFER_TMUX_REAL` is
  set unless `CS_STATUSLINE_LIB=1`, and the three settle calls
  (`_sl_mark_foreign_env`, `_sl_detect_theme`, `_sl_invalidate_stale_bg`) are
  skipped entirely when `$1 = --refresh-usage`. **This block sits OUTSIDE the
  `CS_STATUSLINE_LIB` guard, which only covers `main`** — that is why library
  mode and the re-exec both reached it, and how Codex round four's finding
  existed at all.
- `bin/cs-statusline` the sweeper (~:1275) — `for bucket in tmux-client
  tmux-real tmux-walking tty` now includes the new kind.
- `bin/cs-statusline:1571` and `:1923` — the two second-parity pulse sites.
- `tests/test_statusline.sh` — 239 tests. New: `test_first_render_defers_the_ancestry_walk`,
  `test_a_stalled_walk_is_not_respawned_every_render`,
  `test_a_stalled_walker_is_killed_before_its_mark_expires`,
  `test_usage_refresher_never_walks_the_process_tree`. Changed:
  `test_pane_segment_hidden_when_tmux_is_foreign` now renders once to kick the
  walk, waits via `settle_tmux_verdict`, then asserts on the render after.
- `docs/statusline.md` — the cache table row and the "foreign tmux" section
  both updated; `CHANGELOG.md` has the Unreleased Performance entry.
- **Probe scripts**, untracked, in this conversation's scratchpad
  (`/private/tmp/claude-501/.../93a26e53-.../scratchpad/`): `coldprobe/`,
  `stall/probe.sh`, `stall/windows.sh`, `one.sh`, and the `runall*.log` gate
  logs. Throwaway, but the only record of how each number was taken.
- `~/.claude-sessions/iterm-agents-sidebar/plugin/hooks-handlers/emit-state.py`
  — `emit()` ~line 662, the base64 source. Not ours to edit.

## 7. Pending Tasks

The native list is keyed to the session and survives the `/clear`; reconcile
against it rather than mirroring this.

- **#659 COMPLETED** this conversation — merged 09a4dd8, installed, drift OK.
- **#554 pending (PARKED)** — SessionStart notice for tool calls left pending
  at the end of the previous conversation.
- **#606 pending (POSTPONED)** — `cs --remote` via Claude Remote Control.
- Everything else in the list is already closed.

**Not a native task, but queued and deferred four times this conversation:** a
`cs -queue` task from `firstborn-server` — make `write-as-me`'s
`build-corpus.sh` append `.voice/sources/*.md` so supplementary voice sources
survive a corpus rebuild. Full brief at
`~/.claude-sessions/.voice/builder-sources-request.md`. It is a walk-away-run
task; Alex declined to start it each time while #659 was open. It is now
unblocked.

## 8. Current Work

Nothing in flight. main is at 09a4dd8 plus this handoff's commits; the only
uncommitted paths are the narrative (committed by step 8 of the rotation) and
untracked `scratchpad/`. No branches from this conversation survive —
`fix/statusline-defer-ancestry` was deleted after the merge. Nothing is pushed;
cs is still ~45 commits ahead of origin and unreleased at 2026.9.17.

## Completeness (pass two)

Nothing cut. Written from the same live context as pass one, no compaction
between the two passes.
