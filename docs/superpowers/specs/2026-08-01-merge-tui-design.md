# Merge TUI design

Date: 2026-08-01
Status: approved by Alex — scope, handoff, and readiness settled by three
explicit choices; revised after adversarial review

## Problem

Closing out a feature worktree requires knowing five things the picker cannot
show: how far the branch has moved, whether either side is dirty, whether
untracked files are in the way, whether a session still holds a lock, and
whether the branch is already merged. All five live in git, and the TUI reads
no git working state at all. So the decision to merge is made blind, in a
terminal, from memory of what each `base@feature` session was for.

Worse, the rows a merge concerns are the ones the TUI knows least about.
`Session::has_git` tests whether `.git` is a directory (`tui/src/session.rs:424`),
but a linked worktree's `.git` is a *file* holding a `gitdir:` pointer. Every
`base@feature` row therefore gets `git_repo: None`, and `load_contributors`
repeats the same `is_dir` test independently (`tui/src/session.rs:782`), so the
preview pane renders an em-dash repo row and an empty contributor list for
precisely the sessions this feature is about.

## The scope law, and why this does not break it

Six specs decline a TUI surface for a state-changing verb. The archive design
states it most sharply: "the picker only toggles visibility; state changes go
through the CLI verbs or open-to-unarchive"
(`docs/superpowers/specs/2026-07-15-archive-design.md:47-48`). Tags says "The
TUI only reads" (`2026-07-15-tags-design.md:126`); queue supervision
(`2026-07-15-queue-supervision-design.md:44`) and conversation rotation
(`2026-07-16-conversation-rotation-design.md:65`) each say "No TUI surface".

This design does not merge from the TUI. The screen is read-only: it runs a
query and renders the answer. Pressing enter exits the picker and opens the
base session with the merge ritual armed. No git state is mutated by the TUI
process, and no merge output is ever rendered inside it.

That also answers merge-skill-design.md:30 — "a shell verb can only stop, a
skill instructs Claude to root-cause". The failure mode of merging is a failing
gate, and a gate failure needs diagnosis, not a red line in a modal. The ritual
therefore runs where diagnosis is possible: in a conversation.

## Three pieces

### `cs <base> -features`

A read-only query listing a base session's feature worktrees with the state
that decides whether each can merge.

Discovery follows doctor's recipe exactly (`lib/60-doctor.sh:271-289`): glob
`$SESSIONS_ROOT/<base>@*`, then *verify* each candidate against `git worktree
list --porcelain` in the base checkout. The direction matters. Enumerating
from git instead would list the main checkout, and for an adopted base — a
session symlinked into a real project checkout, resolved by
`_resolve_session_dir` — it would also list that project's own worktrees, which
are not cs sessions at all and would render as garbage rows. Doctor asks git
about a path it already holds, which is also why it survives the Git-for-Windows
drive-letter and MSYS path-form mismatch. The verification must compare
realpaths on both sides, as doctor does.

Per feature the query reports: the task branch read from `.cs/local/state`
(`lib/30-worktree.sh:182`, authoritative), the commit count on the task branch
not reachable from the base's HEAD, whether the branch is already fully merged,
whether either tree is dirty, the untracked-file count in the worktree, and any
live lock on either side.

Each is computed by the function the real gate calls — `_tree_is_dirty`
(`lib/30-worktree.sh:56`), the `ls-files --others --exclude-standard` check
(`:230-235`), the lock loop (`:209-225`). This is the whole reason the query
lives in shell. `_tree_is_dirty` deliberately excludes untracked files, so a
plain "`status --porcelain` is non-empty" test disagrees with cs's own gate: a
worktree with only untracked files is *not* dirty by `_tree_is_dirty` but is
still refused, by a different gate, with a different message. Reimplementing
that distinction in Rust is how the screen starts lying.

**Already-merged requires the tip to be strictly behind the base HEAD**, not
merely an ancestor of it. A freshly created worktree's branch sits *at* base
HEAD, where `merge-base --is-ancestor` is also true — doctor says exactly this
at `lib/60-doctor.sh:296-297` and guards with a `rev-parse` inequality. Getting
this wrong is not cosmetic: `merge_worktree_session` treats is-ancestor as
"already merged; cleaning up" (`lib/30-worktree.sh:245`) and proceeds to remove
the worktree and delete the branch. A brand-new feature would be labelled inert
and then destroyed.

Locks are reported as two distinct facts, because the two consumers differ. A
live *feature* lock blocks the merge outright. A live *base* lock does not:
the ritual runs from inside the base, where `session_lock_owned_by_invoker`
(`lib/15-lock.sh:190`) exempts the invoker's own lock (`lib/30-worktree.sh:219`).
What a live base lock actually obstructs is the *handoff* — the live-duplicate
guard in launch (`lib/75-launch.sh:92-106`) — which is a different refusal with
a different remedy. The query reports the lock; the screen labels it for the
flow it feeds.

Blockers are otherwise reported in the order `merge_worktree_session` evaluates
them (`lib/30-worktree.sh:209-238`: locks, worktree dirty, untracked, base
dirty), so the first blocker named is the first the merge would hit.

Machine output is `--porcelain`: one tab-separated record per feature,
terminated by newline. **Not JSON** — the crate depends only on ratatui,
crossterm and unicode-width (`tui/Cargo.toml`), and neither adding a JSON
dependency nor hand-rolling a parser is worth it when the consumer needs a flat
record. `--porcelain` is also the convention this codebase already reads from
git. The human default is an aligned table.

The command exits 0 when nothing is mergeable, and 0 with no records when the
base has no feature worktrees or no git repository at all: it is a query, not a
gate.

Both `-features` and `-finish` take a single dash, per the flag convention that
reserves double-dash for POSIX modifiers such as `--porcelain`.

### The merge screen

A new `Mode` variant reached with `m` — from a base row, or from a feature row,
which opens its base with that feature selected. `m` is currently unbound in
normal mode. It is live only when `Focus` is the session list; the notes pane
routes keys to its input first (`tui/src/app.rs:859-861`). A base with no
verified feature worktrees produces a status-line message and no mode change.

Mode is a bare tag and state lives in `App` fields, following the
delete/rename/secrets pattern (`tui/src/app.rs:346-362`). This is a style
choice, not a compiler constraint: `Mode::CommandOutput(String)` shows a
payload variant compiles fine when its arm discards the payload with `_`
(`tui/src/app.rs:841`). Only an arm that *binds* the payload by reference
conflicts with the `&mut self` handlers, and keeping merge state in `App` keeps
it reachable from the render path and the tests.

The screen replaces the two content panes; the masthead and footer stay. It is
not an overlay, for two reasons. `centered_rect` is percentage-only with no
max-width clamp (`tui/src/ui.rs:1811`), so an 80% dialog on a wide terminal is
200 columns, and long paths are exactly the content that would expose it. More
decisively, overlays render `Clear` and never set a background
(`tui/src/ui.rs:1094-1095`), so on a light terminal their interior shows the raw
terminal background rather than the painted paper. A surface this large would
read as a hole in the page. `card_frame` paints paper.

The feature list is a `Table`, the only scrollable widget in the crate, with a
viewport — a base can hold more features than fit, and the changelog and legend
panes clip rather than scroll, which is not acceptable here.

The footer's mode match is exhaustive with no `_` arm (`tui/src/ui.rs:919-934`),
so adding the variant is a compile error until its key hints are written. That
is desirable. Mouse events in the new mode are inert; only keys act.

Keys: `j`/`k` and arrows to move, `r` to re-probe, enter to hand off, `Esc`/`q`
to return to the picker. The 10-second rescan runs only in `Mode::Normal`
(`tui/src/main.rs:150-152`), so this mode gets no free refresh — hence `r`, and
hence the screen presents itself as a snapshot rather than a live view.

**Enter always hands off, including on a blocked feature.** The screen is
advisory and cs is the authority, and a hard refusal here would contradict
that with data staler than the liveness it distrusts. It would also be actively
unhelpful: the ritual can *resolve* most blockers — `skills/merge/SKILL.md:13-15`
offers to commit an uncommitted tree — where the screen can only refuse. The
blockers are information about what the ritual will have to deal with.

The probe is a blocking `Command::output()` on screen entry and on `r`, the
same mechanism as every other side effect in the crate. It is one fork
regardless of feature count; the per-feature git work happens inside cs. If it
exceeds roughly half a second in practice, the existing background-worker
triplet (`tui/src/app.rs:420, 645-672`) is the escape hatch, but building it up
front is speculative. A probe that fails or times out sets a status-line
message and leaves the list empty — never a nonzero exit.

### `cs <base> -finish <feature>`

Opens the base session with `/merge <feature>` in the launch prompt. It does
not merge anything itself.

`--merge` is the mechanical git step; `-finish` runs the ritual around it. The
word is already the repo's: doctor says "fully merged; finish with:"
(`lib/60-doctor.sh:301`).

Argument validation matches `--merge` exactly, reusing
`cs_split_worktree_name "$session_name@$1"` (`lib/99-main.sh:293`) so a task
name carrying path separators is rejected before any filesystem lookup. The
feature must also be a verified worktree of the base.

**`-finish` must fall through to the launch, not `return 0`.** Every other
session subcommand returns (`lib/99-main.sh:225-305`); only `--force` falls
through. So `-finish` is structurally unlike its neighbours: it validates, sets
a variable, and lets `main()` continue into `launch_claude_code`, which
currently takes fixed positional arguments and computes `launch_prompt` from
locals. Transporting the feature name into it is part of this work. An
implementer who copies the adjacent `--merge` arm produces a verb that never
opens anything.

There are **two** prompt-slot chains, not one, and both need the entry:

    lib/75-launch.sh:178   launch_prompt="${spawn_kick:-$color_arg}"
    lib/40-state.sh:184    launch_prompt="${spawn_kick:-${handoff_arg:-$color_arg}}"

The second belongs to `_exec_fresh_rebind`, reached when the user answers `n`
to "Continue previous conversation?" (`lib/75-launch.sh:413`), when a resume
fails (`:396`), and on the `r` handoff answer (`:326`). Answering `n` is
routine. Missing that chain means the user presses enter on a ready feature,
answers `n`, and gets a fresh conversation with no `/merge` and no message —
the intent evaporating silently. The merge kick becomes a fifth parameter to
`_exec_fresh_rebind` and enters both chains ahead of the handoff and colour
arguments.

Where the merge kick displaces a spawn kick, cs warns. It must not claim the
queue will run "after the merge": the drain is the Stop hook, which fires at
the first turn end with an armed non-empty queue
(`hooks/narrative-reminder.sh:149-165`), so it will interleave with a
multi-turn ritual. The warning states that a walk-away queue is armed and will
begin at the first turn end, and leaves the sequencing to the user.

On MSYS, `main()` returns before launch (`lib/99-main.sh:368-372`) — Git Bash
prepares sessions but cannot exec Claude Code. `-finish` there prints the same
hand-off guidance the launch path prints, naming the exact command to run from
WSL, so the intent is reported rather than silently dropped.

## The handoff needs no new picker plumbing

`lib/99-main.sh:40-43` reads line 1 of the TUI's stdout as a session name and
word-splits the remaining lines into argv, then `exec`s. Printing

    snip
    -finish merge-tui

runs `cs snip -finish merge-tui`. The `Action` enum gains one variant carrying
a session and its argv words, mirroring that protocol exactly. Argv words must
not contain spaces, which session and feature names cannot.

A skill slash command works in the launch-prompt slot: a probe skill invoked as
`claude -p "/probeskill merge-tui"` loaded and reported its argument verbatim.
The in-tree precedent (`lib/75-launch.sh:68-73`) covers only `/color`, a
built-in, so this was worth establishing. The probe ran headless; the launch
path is interactive, which shares the prompt entry but was not exercised
directly. The implementation confirms it on the first real handoff.

The TUI paints to stderr and writes only the exit payload to stdout
(`tui/src/main.rs:59-66,79`), so the probe fork must not inherit stdout.
`Command::output()` pipes stdout and stderr, which is correct, but it leaves
stdin on the raw-mode tty (`tui/src/app.rs:1734`) — harmless for a read-only
query that never prompts.

A nonzero TUI exit kills cs outright (`tui_output=$(...) || exit $?`,
`lib/99-main.sh:38`), so a failed probe is a status-line message, never an
exit code.

The merge intent is not durable. If the user presses Esc at the resume prompt
(`lib/75-launch.sh:312-314`) or cancels a collision menu, it is gone with no
record — unlike a spawn seed, which self-heals on the session's next open
(`:144-147`). That is acceptable: the intent is one keystroke to re-express
from the screen, where a spawn seed represents work staged by someone else.

## What the screen must not claim

`lib/30-worktree.sh:256` runs `git merge --no-edit` with **no `--no-ff`**, so a
feature whose base has not moved fast-forwards and leaves no merge commit,
while `skills/merge/SKILL.md:54-56` mandates `--no-ff` for ordinary branches.
One affordance hiding two behaviors is the trap. The screen names which one
will happen, computed from whether the base actually moved.

`git branch -d` at `lib/30-worktree.sh:270` is best-effort with stderr
discarded, and the timeline event at `:273-277` ends in `|| true`. The screen
describes these as intended steps, never as completed facts.

The screen shows no diff and browses no commits. That is a separate feature and
`git merge-tree` conflict prediction is unmeasured work.

## Visual contract

Every colour is a token from `tui/src/theme.rs`; no literal RGB. The light
palette is council-approved verbatim and test-pinned (`theme.rs:320`), and
`detect_theme()` reads only `CS_TERM_THEME` (`theme.rs:226-227`), exported by
the bash wrapper before launch (`lib/99-main.sh:36`) — light is not inferable
from Rust, so the screen must be designed against paper, not assumed dark.

Colour is nearly absent: plain ink for a ready feature, `amber` for a blocker,
`faint` for already-merged. Teal is not used — it is reserved exclusively for
liveness and a test pins that (`tui/src/ui.rs:2666`). No new diff green or red;
the existing red and green are status-text colours and were never tuned as
surfaces.

Structure comes from alignment and hairline rules: an uppercase column header,
no zebra striping, no vertical dividers, no table border. Glyphs are limited to
box-drawing, block elements, geometric shapes and braille; the B′ spec's tofu
list names `⎇` explicitly ("No ☐☑⚿⎇ anywhere",
`docs/superpowers/specs/2026-07-14-tui-bprime-design.md:47`).

Nothing animates. "One animated element … nothing else animates" (same spec,
`:49-50`), and the only meter in the product is `qbar`'s four-segment `▰▱`
(`tui/src/ui.rs:189-198`). The step list on the detail pane is a *plan* — what
will happen, in order — not progress. Nothing runs in this screen, so there is
nothing to animate.

## Prerequisites

Four changes are not the feature but block it.

1. Both `.git`-is-a-directory tests must accept a file: `has_git`
   (`tui/src/session.rs:424`) and `load_contributors` (`:782`), which repeats
   the test independently. The correct probe already exists in the delete path
   (`:688`) and is used nowhere else. Fixing only the first leaves the
   contributor list empty.
2. `skills/merge/SKILL.md` needs a third context: invoked in a base session,
   closing out a named feature given as an argument. It detects only
   worktree-I-am-standing-in and ordinary-branch today (`:19-30`), so a
   `/merge <feature>` arriving in the base would find no context.
3. cs must export its own path to the TUI, alongside the `CS_VERSION` it
   already exports (`lib/99-main.sh:38`), and the TUI must use it. Today
   `Command::new("cs")` is hardcoded with no seam (`tui/src/app.rs:1695`) while
   cs itself probes for a sibling binary when the TUI is not on PATH; the
   reverse case makes every fork fail at spawn. This also supplies the test
   injection seam the three existing shell-outs lack.
4. `sample_sessions()` has no `base@task` row (`tui/src/app.rs:1986-2031`). The
   Rust tests need one.

Both verbs are user-facing, so each needs a line in `lib/10-help.sh` beside the
existing `--merge` entry (`:24`) and an entry in the README's command list,
which documents `cs <base> --merge <feature>` at `:100`.

## Rejected

**Running the merge inside the TUI.** Every side effect in the crate is a
blocking `Command::output()` on the main thread inside `handle_key`
(`tui/src/app.rs:1695,1734,1755`); there is no `Stdio::piped`, no `.spawn()`,
and no way to wake the event loop from another thread — `event::poll` is the
only wake source (`tui/src/main.rs:111`). A merge would freeze every frame for
its full duration, and gates on this repo take minutes. Doing it properly means
a net-new thread, channel, drain and animation flag, with inherited stdin on
top. The scope law and merge-skill-design.md:30 both point the other way.

**Computing readiness in Rust.** Named above: `_tree_is_dirty`'s deliberate
exclusion of untracked files is easy to get subtly wrong, and a screen that
disagrees with the gate is worse than no screen.

**JSON output.** The crate has no JSON parser and adding a dependency to carry
six flat fields is not justified. Scraping the human table — the pattern
`parse_secrets_list` already embodies — is the alternative and is worse.

**Deferred cleanup — merge now, remove the worktree later.** Already rejected
at `docs/superpowers/specs/2026-07-23-in-session-worktree-merge-design.md:61-68`,
because a retry after fusion double-appends timeline, log and narrative.
Nothing here revisits it.

**A "commit and merge" affordance.** A policy reversal, not a UI detail. cs
"refuses rather than committing on the user's behalf"
(`lib/30-worktree.sh:193`), and "No automatic commits of session or project
state, ever" (`docs/superpowers/specs/2026-07-02-worktrees-design.md:54`). The
ritual may offer to commit; the screen may not.

**Gating enter on readiness.** Covered above: stale data, and it would block
the case the ritual handles best.

## Tests

Shell, in `tests/test_worktrees.sh`'s real-temporary-git style:

- `-features` reports a clean feature worktree as ready.
- A worktree containing only untracked files is reported with an untracked
  count and *not* as dirty — the `_tree_is_dirty` distinction, asserted against
  the gate's own behavior rather than recomputed.
- A freshly created feature whose branch sits at base HEAD is **not** reported
  as already-merged, and a branch strictly behind base HEAD is.
- A worktree directory that exists under `$SESSIONS_ROOT` but is not a
  registered worktree is excluded.
- For an adopted base, an unrelated worktree of the underlying project is
  excluded.
- Blockers appear in `merge_worktree_session`'s gate order, and a live base
  lock is reported distinctly from a live feature lock.
- `--porcelain` emits one tab-separated record per feature and nothing else.
- `-finish` refuses an unknown feature and a directory that is not a verified
  worktree.
- `-finish` arms the ritual and merges nothing: the branch is still unmerged
  afterwards.
- `-finish` survives answering `n` at the resume prompt — the fresh
  conversation still carries the merge kick. This is the `_exec_fresh_rebind`
  chain, and the existing suite already pipes `n` (`tests/test_worktrees.sh:156`).
- A merge kick displaces a spawn kick and warns without promising sequencing.
- On MSYS, `-finish` reports the WSL hand-off rather than silently returning.

Rust, in the `handle_key` idiom:

- `m` on a base with features enters the mode; on a base without, it sets a
  status and stays; in the notes focus it does not fire.
- Enter on a blocked feature still yields the handoff payload.
- Enter yields the exit payload naming the base and `-finish <feature>`.
- `Esc` returns to `Mode::Normal`.
- A feature list longer than the viewport scrolls.
- `has_git` and `load_contributors` are both true for a `.git` file.

The shell suite must run on bash 3.2 with BSD userland, and the
`test-windows-msys` lane is required. Added git forks are proportionally more
expensive on Windows, where liveness already forks `tasklist` per locked
session (`tui/src/session.rs:771`).
