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
