---
parent: c29bfd1e-9c09-4f7c-abaf-87f97e976ed9
created: 2026-09-16T10:13:56Z
purpose: build the git-segment project pointer (task #633, the firstborn `main !2` bar); #622 the held release and the stray X-Fake edit in hooks/prompt-rewriter-vendor.sh carry over
status: unconsumed
---

## 1. Next Step

Nothing is in flight. Main is at `d98c755` (#632 merged as `edbedd3`,
built, installed, doctor drift OK), **81 commits ahead of origin, nothing
pushed**. Alex's words at the gate, picking from the menu: *"/rotate and
build the git-segment follow-up"*.

Build **task #633** (its description carries the full diagnosis and the
shape to design). Alex has NOT chosen a design yet — only the direction
(*a project pointer the git segment follows*, over hiding the segment). So:

1. Brainstorm first (`superpowers:brainstorming`, prose + ELI5 per
   `feedback_design_discussion_style`): where the pointer lives (a `project`
   key in `.cs/local/state` read by the existing fork-free `_read_state_key`,
   or a tracked `.cs/project` file — classify the write path per
   `project_cs_multi_user_safety`), who writes it (`cs -spawn`/adopt when a
   session wraps a checkout, or the user by hand), and whether `cs -live`/the
   TUI should agree. Put the choice to Alex with AskUserQuestion — concrete
   either/or is fine there.
2. Own branch off main. TDD, one test → one implementation. The git cache
   key MUST be the resolved pointer path (`_git_text "$dir"` already keys on
   its argument, so passing the resolved dir is enough).
3. Gate as #632 was gated: ghost full suite (`bash <claude-tmux
   plugin>/scripts/remote-tests.sh --host ghost@ghost </dev/null`, remove
   `ci/claude-sessions/suite.status` on ghost FIRST, poll from a background
   loop), one or two Codex read-only rounds with closures measured,
   polish-first at the merge gate (Alex picks it 5/5 now). Nothing pushed.

Carry-overs, in Alex's priority after #633: **#622 the held release
v2026.9.16** (81 commits go to origin; Alex's release shape is in memory
`project_release_gate_skips_ci`; hold for an independent review per
`feedback_hold_for_adversarial_review`), and the **stray edit** below.

## 2. Settled and rejected

- **The `main !2` bar is not a defect of #632** (measured: the installed
  binary was the pre-branch build when the screenshot was taken). The git
  segment reads `workspace.current_dir`, which for a cs session is the
  session directory — itself a one-commit git repo on `main`; the `!2` were
  the two dirty `.cs` memory files. Alex: *"isn't this weird? the branch"*.
- **Rejected for #633: hiding the segment on a bare cs session.** Offered
  beside the pointer; Alex picked the pointer.
- **#632 design decisions, do not reopen** (all measured, see the task and
  `docs/statusline.md` "Data sources and performance"): the render's cost is
  fork count × load, NOT git (git was ~15%); caches live under
  `~/.cache/cs/<kind>/` as two-line `epoch<TAB>identity` + text entries and
  a read requires both lines complete and the identity to match; TTLs git 5 s,
  tmux-real 300 s, tmux-client 5 s, org 300 s; stamps rewritten on change or
  every 60 s via `<stamp>.at`; the refresher honours the JSON's schedule and
  repairs the sidecar from it; the render never writes the sidecar; an empty
  org is never cached; the clock memo is reset once at the top of the script,
  never in `main()`; `refreshInterval: 1` STAYS (warm render is interpreter +
  jq; +1 date on bash 3.2). Both recipe copies untouched.
- **Rejected in #632: keying the parent caches on TMUX_PANE** (inherited env,
  an impostor process would share it). PPID or `CS_STATUSLINE_PARENT` (set
  per run by a bridge) only.
- **Rejected: the render writing the fable `.fields` sidecar** (Codex round 2:
  a slow parse of an old record overwrote a refresher's newer sidecar).
- **Rejected: taking the refresher's schedule from the sidecar** (Codex round
  3: a stale sidecar skipped a 429 backoff the JSON recorded).
- **Stray working-tree edit, NOT mine, unresolved:** `hooks/prompt-rewriter-vendor.sh`
  has `-H "X-Fake: 1"` added to its curl call, mtime 2026-09-16 12:32:12 EEST.
  Codex round 1 ran 12:30–12:33 in `-s read-only` and its log never names
  the file; the ghost sync goes local→remote only. Left unstaged and
  untouched on Alex's behalf; doctor's shadow-ref WARN is about it. Alex has
  not ruled on it. Ask, or `git checkout -- hooks/prompt-rewriter-vendor.sh`
  only on his word.
- **The sidebar bridge does not set `CS_STATUSLINE_PARENT` yet** — that is
  the iterm-agents-sidebar repo's change; told them over `cs -msg` (thread
  e110e4), no reply as of rotation. Under the bridge the parent-keyed caches
  miss each tick (ps, awk, tmux per render); the bridge caches its own line,
  so nothing is broken, only slower. Do not edit the bridge or
  `settings.json` from this session (standing agreement).

## 3. Conversation-only facts

- **MEASURED:** minimal-payload render 8 forks / 0.22 s; realistic lead
  Fable render 14 forks / 0.94 s at load ~12 (jq×3, tmux×2, ps+awk, find,
  mkdir×2, mv×2, timeout+git, date); after the diet, warm render in this real
  pane: jq + tmux → 0.255 s at load 19; in the test fixture: bash + jq = 2.
- **MEASURED:** ghost 67/67 on bf5eb6f was 66/67 (account-swap test red =
  Codex's Blocker), then 67/67 on 76b00f9, 64dd9b0, 71f9dc6. Codex rounds:
  1 (Blocker + 5 Important + 1 Minor), 2 (0 Blockers, 4 Important, 3 Minor),
  3 (HOLD: 2 Important, 1 Minor), 4 (no blockers, nothing new). Round 3
  first paused on the stray vendor edit per its AGENTS.md; pre-answer that in
  the prompt from the start (`err3b.log` shape).
- **MEASURED:** ~35 mutations killed; `TTL=0` is NOT a disabling mutation
  (same-second renders still hit), use -1; a mutation of one of two paired
  sites can survive (the teammate `.heartbeat.at` case needed both).
- **MEASURED harness traps:** xtrace cannot count forks (`2>/dev/null` hides
  the trace line; BASH_XTRACEFD is bash 4.1+) → PATH shims; a fixture that
  `export`s cannot run in `$(...)`; a PPID-keyed cache never hits when the
  render runs in a pipeline or a `$(...)` → stdin and stdout via files; the
  statusline suite needs a per-TEST HOME (shared fake TMUX pid + shared PPID
  let one test's verdict answer the next).
- **Alex's words this conversation:** *"also check with @iterm-agents-sidebar
  about this, he is working on statusline as well"*; *"isn't this weird? the
  branch"* (screenshot, firstborn); *"validate the fix with codex"*;
  picks: "#632 statusline render cost" over the release, "Polish first, then
  merge", "Not yet — keep working", "/rotate and build the git-segment
  follow-up".
- Scratchpad of this conversation (`c29bfd1e…/scratchpad/`): `run-some.sh`
  runs named statusline tests in-process in ~1 s each (`SL_OVERRIDE` for a
  mutated copy; `bash32/bash → /bin/bash` on PATH for 3.2); `codex/err*.log`
  hold the four reports (Codex writes its report to STDERR; `out*.md` are
  empty); `ghost*.result` the verdicts. Readable after rotation.

## 4. What this handoff could not carry

Written from live, uncompacted context at ~50%. Nothing cut.
