---
parent: 7cc98cc6-b428-41cd-b399-a06757e3d319
created: 2026-09-17T10:45:00Z
purpose: build task #645 — prune the never-swept ~/.cache/cs/tmux-client and tmux-real cache directories
status: unconsumed
---

## 1. Next Step

Build **task #645**: `~/.cache/cs/tmux-client/` and `~/.cache/cs/tmux-real/`
grow without bound. Nothing ever removes an entry.

**MEASURED on this machine, 2026-09-17 ~10:44 UTC:** 3,986 files / 16 MB in
`tmux-client`, 4,029 files / 16 MB in `tmux-real`.

Alex asked for this to be filed, then chose it as the next piece of work. He
has NOT approved a design — open with one, briefly, and let him pick. Design
discussion is prose plus ELI5 iteration, not an AskUserQuestion menu
(`feedback_design_discussion_style`); a concrete either/or is fine as a menu.

The shape of the problem, **read in source** (`bin/cs-statusline`):

- `_cache_write` (line 93) writes `$HOME/.cache/cs/<bucket>/<key>`, two lines:
  `<epoch>\t<ident>` then the value. It never sweeps the directory.
- `_cache_read` (line 75) is TTL-checked on read, so a stale file is a miss —
  correctness is fine, only the file count grows.
- `tmux-client` is keyed `"$_PARENT,${TMUX:-}"` with `TMUX_CLIENT_CACHE_TTL=5`
  (line 152); `tmux-real` on the server ident with `TMUX_REAL_CACHE_TTL=300`
  (line 205). Every new Claude Code pid mints new keys, so the count tracks
  conversations-ever, not sessions-live.
- The other buckets under `~/.cache/cs/` (`git`, `org`, `term`,
  `rewrite-config`) are keyed on paths or idents that repeat, so they stay
  small — **measured**: 17, 3, 10, 11 entries. Only the two pid-keyed buckets
  run away. Fix those two; do not generalise the sweep to every bucket without
  a reason.

**The constraint that decides the design:** the render's cost is its fork
count. A warm render forks exactly two (`docs/statusline.md:39`), and #632
spent a whole branch getting it there. A sweep must not put a `find` on the
render path. The usage refresher's pattern is the precedent worth copying —
it sweeps inside the already-detached, already-locked `--refresh-usage`
worker (`bin/cs-statusline:1161-1165`, three `find -maxdepth 1 -mmin +5`),
which no render waits on.

Options worth putting to Alex (my ranking, for him to overturn):

1. **Sweep in the detached refresher**, beside the existing three finds. Zero
   render cost, but it only runs on a Fable session with `curl` and at most
   once per 600 s, so a machine that never refreshes never prunes.
2. **Sweep on write, past a count.** `_cache_write` already knows the
   directory; a cheap guard (every Nth write, or when a stamp file is older
   than N hours) then one `find -mmin +N -delete`. Runs everywhere, but it is
   a fork on a path that currently has none — needs a measurement, not an
   argument, before it lands.
3. **`cs -doctor` row + a verb**, sweep only when the user asks. Cheapest to
   get right, does nothing on its own.

Whatever lands: red-first test, `./build.sh` before committing (lib/ feeds
`bin/cs`, and `bin/cs-statusline` is its own file — check which the change
touches), ghost for the suite, then Alex's merge gate.

## 2. Settled and rejected

- **#642 CLOSED as not a cs defect.** A peer session measured
  `cs-statusline --refresh-usage` forking `find` at ~150/s and filed it. It
  was that session's own instrumentation: its `scratchpad/shim/find` was
  `exec find "$@"` with the shim dir first on PATH, so it re-exec'd itself
  forever (121,549 log lines; two orphans at ppid 1 for 44 min, ~6:18 CPU
  each). Its pre-shim Falcon and `log stream` captures (11:26–11:36) contain
  **zero** find execs. I reproduced the same loop in my own probe:
  under the zsh Bash tool `command -v find` prints the bare name, so
  `exec "$real"` recursed. Alex had me kill the two orphans (pids 42886,
  54280, verified by pid first); the peer confirmed, deleted its shim and
  withdrew the finding. Memory written: `project_path_shim_exec_absolute`.
  **Rule: a PATH shim must exec an absolute path (`/usr/bin/find`).**
  `_refresh_usage` really does fork three `find -maxdepth 1` per refresh,
  under a mkdir lock — that is the whole story, and it is fine.
- **Rejected for #645: a sweep on the render path.** See the fork-count
  constraint above. Not litigated with Alex, but #632's measurements make it
  the wrong direction to open with.
- **cs-hint: deleted from cs, not switched off.** Alex was offered "turn it
  off on this machine only" (`hints: off` / `CS_NO_HINTS`) and chose deletion.
- **Rejected for the cs-hint removal: dropping the changelog entry.** My first
  read was that cs-hint had never shipped. Wrong — it is in the 2026.9.16
  Features list, so it needed a `### Removed` entry and a real upgrade path.
- **The upgrade path chosen: `RETIRED_SKILLS`.** Mods deploy under
  `~/.claude/skills/<mod>/`, and both `install.sh.in` and
  `lib/85-adopt-uninstall.sh` already `rm -rf "$SKILLS_DIR/$retired"` for
  every entry. Codex checked the alternative reading and found no consumer
  that requires a retired entry to contain `SKILL.md`.
- **Alex's merge-gate choices today:** polish-first on
  `fix/parallel-test-races`, merge-as-is on `feat/remove-hint-mod`. Do not
  assume either is the standing answer; ask each time, polish-first listed
  first (`feedback_polish_before_merge`).
- **Statusline `refreshInterval` is 1, and that is deliberate.** It was 5 in
  `~/.claude/settings.json` under the sidebar bridge; Alex said "set back to
  1". cs itself registers 1 (`lib/70-statusline.sh:95`, pinned by
  `tests/test_install.sh:891`) because the logo's attention pulse animates on
  that timer. The peer session that owns the sidebar has been told to stop
  writing 5 from its `install.sh --statusline` and confirmed.

## 3. Conversation-only facts

Everything here exists nowhere else.

- **Ghost runs today:** 67/67 on `bd216c2`, 67/67 on `540d7ea`, **66/66** on
  `8a1f1eb`. The count dropped 67→66 when `tests/test_mod_hint.sh` was
  deleted; `tests/run_all.sh:84` discovers suites by glob and no count is
  pinned in CI, README or docs (Codex checked).
- **Codex round 4 on the integrate lock (via the `/codex:` plugin) raised
  three Minors; two were folded and one was filed.** Folded: `LC_ALL=C` as a
  command prefix does not reach a builtin's locale on bash 3.2 —
  **measured under `fr_FR.UTF-8` on 3.2.57:** `$(LC_ALL=C printf "%.1f" 1)`
  → `1,0` while `$( LC_ALL=C; printf "%.1f" 1 )` → `1.0`. The `kill -0`
  message stayed English in **both** forms, because macOS `strerror` is not
  localised and bash 3.2 exists only on macOS — so `bd216c2` makes the
  comment's claim true rather than changing an observed verdict.
- **The Fable closure review found two real defects I had not:** `kill -0 0`
  signals the caller's own process group and always succeeds, so a pid file
  reading `0` reported a holder that could never exit; and under `set -e` a
  failed `rm -r` as the last command of an AND-list aborted
  `_integrate_cleanup` before it forgot the path, re-opening the successor's-
  lock race. **Both red-first, measured with standalone `/bin/bash` probes,
  not the suite:** doctor said `held by a running integrate (pid 0)`, and the
  `set -e` subshell exited 1 inside the handler with nothing printed after the
  first pass. Fixed in `540d7ea`.
- **Left open from those reviews, filed as #644:** an empty pid is classified
  `stale` and gets `rm -r` advice although `hooks/autosave-commits.sh:110-117`
  holds that same lock with no pid recorded (a design tradeoff, pinned by
  `tests/test_doctor.sh`); Codex's PID-namespace ESRCH argument; **93
  surviving `printf|grep -q` sites** in other suites (test_hooks ~15,
  test_doctor 236/270/342, test_auto_update 265-293, test_statusline 689/720,
  test_mod_rotate 108), the same SIGPIPE class as #638; and the pid-1 EPERM
  test passing without reaching the EPERM branch when run as root.
- **Filed as #647, from Codex's one Minor on the cs-hint removal:**
  `lib/60-doctor.sh:198`'s drift scan enumerates **source** files only, so a
  retired directory left on disk from an older install reads as
  "match checkout source" until `install.sh` runs. Applies to `voice` and
  `merge` too, not just cs-hint. Warn on **known retired names only**, never
  on arbitrary extra skills.
- **Alex's words this conversation, close to verbatim:** "kill them" (the two
  orphan shims); "also notify @claude"; "notify @claude" (a second time, when
  no delivery notice had come back); "what statusline refresh do we have
  now?"; "set back to 1 and notify @claude"; "what claude mods do we currently
  have?"; "let's remove cs-hint"; "yes, also check the code for bar repaint"
  (filing #645 plus verifying the repaint cadence in source); and at the two
  gates, polish-first then merge-as-is. He declined a wrap twice: "Not yet —
  keep working."
- **Peer session `claude [6f5a71]`** is the counterpart on the sidebar work.
  It withdrew the `--refresh-usage` finding and said it told
  `iterm-agents-sidebar` to stop writing `refreshInterval: 5` from
  `install.sh --statusline` and "to treat the interval as cs's to set." That
  is its claim, unverified here.
- **A cross-session send reports delivery, not reading.** Two `SendMessage`
  calls to that peer returned "queued there" and no `[Cross-session delivery
  notice]` ever arrived; the reply came only after Alex asked me to send
  again. An idle subscription on it warned that idle notices were not vouched
  for — one did arrive, at 13:00 local.
- **Doctor's two standing WARNs on this machine are not defects:** the
  non-cs status line (the sidebar bridge owns it) and a missing shadow ref for
  session id `0643d4f0-...` (the sidebar's own session). Both predate today.
- **`git checkout` refuses to switch branches while the narrative is
  modified** — `.cs/memory/narrative.*.md` is TRACKED in this checkout even
  though `.cs/` is broadly gitignored. Commit it by path first
  (`project_cs_dev_repo_ignores_cs`).
- **`rg -c` prints nothing and exits 1 on zero matches**, which kills an `&&`
  chain mid-verification. It cost me one confusing "1" while checking the doc
  edits; re-verify with `rg -n`.

## Completeness (pass one)

Written from live context at ~45%, no compaction. Pass one carries everything
that dies with the conversation; pass two appends the recoverable sections.
