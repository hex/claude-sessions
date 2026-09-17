---
parent: 720d4199-53f6-4f84-b752-a7cd76c222f5
created: 2026-09-17T11:08:41Z
purpose: design task #648 with Alex — a fork-free per-second statusline tick, real render only when something can have changed
status: unconsumed
---

## 1. Next Step

Open the design discussion for **task #648** with Alex. Alex invoked `/rotate`
with the argument "and go": start the design, do not wait for another nudge.

**Design discussion only. No code, no branch, until Alex approves a shape.**
Design talk is prose plus ELI5 iteration, not an AskUserQuestion menu
(`feedback_design_discussion_style`); a concrete either/or may be a menu.

Before writing the opener, READ (do not trust this summary):
- `bin/cs-statusline` `main()` (~1936), `_seg_logo` (~1528), the crit-pulse
  site (~1886, "clock as the attention mark, so a crit reading moves while
  the bar idles"), `_sl_now` (~28), the caches `_cache_read`/`_cache_write`
  (~75/~93).
- `docs/statusline.md` "Data sources and performance" (the fork table, ~39-52).

Then give Alex a short opener: what changes per second, the candidate shapes,
your ranked recommendation, and the measurement you would take first.

**The request, from the peer session `iterm-agents-sidebar` (its message,
close to verbatim), which Alex confirmed:**

> Alex chose the cs-statusline change over interval 5: keep refreshInterval 1
> and make the per-second tick fork-free, with a real render only when
> something can have changed.
>
> Why: with Arq paused, Falcon's OD lookups stayed at ~850/s and
> opendirectoryd at 85-87%; process-birth sampling puts ~65 of ~100 new
> processes/s on the statusline chain across 8 sessions. Each new process
> costs Falcon ~10 opendirectoryd lookups. The bridge is already builtins; the
> render (bash + jq + tmux/ps/stat/mv, ~8 per tick) is what remains.
>
> What changes every second is only _seg_logo's ink (line 1517-1527): brand vs
> brandshade by epoch parity, and only while .cs/local/attention exists.
> Everything else moves per turn or per payload. Suggested shape, yours to
> redesign:
> 1. Full render writes two lines to the cache (parity 0 and parity 1), or one
>    line with a marker the fast path swaps; keyed on the payload hash +
>    attention-file presence + a max age (say 5-10 s for git/clock segments).
> 2. Fast path, on every tick, in builtins only: read the payload from stdin
>    (read -r -d ''), compare hash/mtime, pick the parity line by
>    ${EPOCHSECONDS} (bash 5; the bridge runs /bin/bash 3.2, so the fast path
>    may need to live in cs-statusline itself or the bridge needs
>    /opt/homebrew/bin/bash), print it. Zero forks.
> 3. Only when the key changed or the age expired: today's render.
> Target: a warm tick with attention raised = 0 forks; without attention = 0
> forks; a real render at most every 5-10 s per session. Measure with your
> PATH shim using absolute paths.
>
> Alex said "C" to me; confirm with him directly if you want the task in his
> words before starting. I'm not touching cs-statusline or the bridge.

Alex's own answer when asked (AskUserQuestion, this conversation): "Yes — #645
first, then design the tick with me". #645 is now done, so this is next.

**Things to check against that proposal (my notes, not verified):**
- The peer's "~8 per tick" conflicts with `docs/statusline.md:39`, which says
  a warm render forks exactly two (interpreter + one `jq` over stdin; stock
  macOS bash 3.2 adds a `date`). Measure before designing: which is true
  under the bridge? The interpreter fork itself can never be removed from
  inside the script — Claude Code (or the bridge) spawns it. So "0 forks" can
  only mean "no forks beyond the one process the caller starts", unless the
  fix lives in the bridge. Put this to Alex plainly.
- A second per-second mover exists besides the logo: the crit-reading pulse
  (~1886). The peer's "only _seg_logo" is incomplete.
- Hashing stdin with builtins only is not free in bash 3.2 (no builtin hash);
  keying on the raw payload string, or on selected fields, is the likely shape.
  `jq` is the one fork a warm render keeps today — the fast path must avoid it.
- `EPOCHSECONDS` is bash 5 only; `_sl_now` already handles the clock
  (CS_STATUSLINE_NOW pins it for tests; 3.2 falls back to `date`). The bash
  3.2 + BSD constraint applies (`feedback_bash32_compatibility`).
- Test pins that assert pulsing tokens need an even pinned clock
  (`project_statusline_clock_pin`).

## 2. Settled and rejected

- **refreshInterval stays 1.** Alex said "set back to 1" earlier today; cs
  registers 1 (`lib/70-statusline.sh:95`, pinned by `tests/test_install.sh:891`)
  because the logo pulse animates on it. Raising it to 5 was the rejected
  alternative ("Alex chose the cs-statusline change over interval 5").
- **No sweep or `find` on the render path** (the #632 fork diet constraint).
- **#645 is done:** the detached usage refresher prunes
  `~/.cache/cs/tmux-client` and `tmux-real` entries older than 60 min.
  Merged `1542ac1`, installed, doctor drift OK. Not pushed.
- **#642 closed** earlier: the "find ~150/s" was the peer's self-recursive PATH
  shim. Any new fork measurement must use a shim that execs an absolute path
  (`project_path_shim_exec_absolute`).

## 3. Conversation-only facts

- **Test registration trap (measured):** `tests/test_statusline.sh` runs
  tests only via explicit `run_test <name>` lines. A defined but unregistered
  test made the "red" ghost run come back 66/66 GREEN on `6440f84`. Fixed by
  amending to `ccbdebc`; the true red was
  `FAIL: an old tmux-client entry must be swept`. Any new statusline test must
  get its `run_test` line, and a red run must show the named FAIL.
- **Ghost runs this conversation:** 66/66 on `6440f84` (vacuous, see above);
  FAILED 1/66 on `ccbdebc` (true red); 66/66 on `6d38cac` (fix), with the
  ghost copy grep-verified to contain the new loop. The polish commit
  `0bbc6b1` (comment, docs row, changelog wording only) was NOT re-run on
  ghost; `/bin/bash -n` passed.
- **Codex on #645 (plugin agent):** MERGE. Findings folded: the comment/docs
  claimed an hour-old entry belongs to a finished conversation (false: idle
  conversations age out too; safe because the entry is already past both TTLs)
  and the changelog said "no longer grow without bound" (overstated: pruning
  runs only where the Fable refresher runs). Unfolded, recorded only: a
  `find` can unlink a just-rewritten entry (costs one recompute); pruning runs
  before the 600 s cadence check, so it can run more often than 600 s; BSD
  `-mmin` rounds up, GNU down.
- **Peer addressing:** the sidebar peer is `iterm-agents-sidebar [601f64]`
  (Alex: "cs iterm-agents-sidebar"). Its old uds socket
  `/tmp/cc-socks/69335.sock` is gone (ENOENT). A message was queued to it at
  ~11:07 UTC saying #645 landed and the tick is next; no delivery notice seen.
  A second session `iterm-agents-sidebar-d2 [0c6560]` also exists — not the
  addressee.
- **Local install:** Alex asked "did we install cs locally?"; answer was no
  (the branch was unmerged). Alex said "yes" to installing from the branch,
  then chose polish-first at the gate; main was installed after the merge
  (`~/.local/bin/cs-statusline` byte-matches `bin/cs-statusline` on main).
- **Context notice:** the conversation hit 40% before this rotation.
