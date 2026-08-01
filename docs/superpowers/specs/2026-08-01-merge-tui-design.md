# Merge TUI design

Date: 2026-08-01
Status: approved by Alex — scope, handoff, and readiness settled by three
explicit choices; pending adversarial review

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
`base@feature` row therefore gets `git_repo: None` and an empty contributor
list, and the preview pane renders an em-dash repo row for precisely the
sessions this feature is about.

## The scope law, and why this does not break it

Six specs decline a TUI surface for a state-changing verb. The archive design
states it most sharply: "the picker only toggles visibility; state changes go
through the CLI verbs or open-to-unarchive"
(`docs/superpowers/specs/2026-07-15-archive-design.md:47-48`). Tags says "The
TUI only reads"; queue supervision and conversation rotation each say "No TUI
surface".

This design does not merge from the TUI. The screen is read-only: it runs a
probe and renders the answer. Pressing enter exits the picker and opens the
base session with the merge ritual armed. No git state is mutated by the TUI
process, and no merge output is ever rendered inside it.

That also answers merge-skill-design.md:30 — "a shell verb can only stop, a
skill instructs Claude to root-cause". The failure mode of merging is a failing
gate, and a gate failure needs diagnosis, not a red line in a modal. The ritual
therefore runs where diagnosis is possible: in a conversation.

## Three pieces

### `cs <base> -features`

A read-only query listing a base session's registered feature worktrees with
the state that decides whether each can merge.

Feature discovery uses `git worktree list --porcelain` in the base checkout —
doctor's recipe (`lib/60-doctor.sh:285-289`) — not a name split. The TUI's
`worktree_parts` (`tui/src/session.rs:678`) never touches the filesystem and
cannot distinguish a registered worktree from a hand-made or pruned `foo@bar`
directory.

Per feature the query reports: the task branch read from `.cs/local/state`
(written at `lib/30-worktree.sh:182-184`, authoritative), the commit count on
the task branch not reachable from the base's HEAD, whether the branch is
already fully merged, whether either tree is dirty, the untracked-file count in
the worktree, and any live lock on either side.

Both `-features` and `-finish` are session subcommands, so each is wired at two
places: its `case` arm in the session-command loop and the "Unknown session
command" list (`lib/99-main.sh:302`). Both take a single dash, per the flag
convention that reserves double-dash for POSIX modifiers such as `--json`.

Every one of these is computed by the function the real gate calls —
`_tree_is_dirty` (`lib/30-worktree.sh:56`), the `ls-files --others
--exclude-standard` check, the lock check in `lib/15-lock.sh`. This is the
whole reason the query lives in shell. `_tree_is_dirty` deliberately excludes
untracked files, so a plain "`status --porcelain` is non-empty" test disagrees
with cs's own gate: a worktree with only untracked files is *not* dirty by
`_tree_is_dirty` but is still refused, by a different gate, with a different
message. Reimplementing that distinction in Rust is how the screen starts
lying.

Blockers are reported in the order `merge_worktree_session` evaluates them, so
the first blocker named is the refusal the user will actually hit.

Output is an aligned table by default and one JSON object per line under
`--json`, matching the `timeline.jsonl` idiom already in the tree. The command
exits 0 when nothing is mergeable: it is a query, not a gate.

### The merge screen

A new `Mode` variant reached with `m` — from a base row, or from a feature row,
which opens its base with that feature selected. A base with no registered
feature worktrees produces a status-line message and no mode change.

Mode is a bare tag. `Mode::Merge(State)` will not compile: `handle_key` matches
`&self.mode` and every arm calls a `&mut self` handler (`tui/src/app.rs:829`),
which is why `CommandOutput(_)` discards its own payload. State lives in `App`
fields, following the delete/rename/secrets pattern at `tui/src/app.rs:345`.

The screen replaces the two content panes; the masthead and footer stay. It is
not an overlay, for two reasons. `centered_rect` is percentage-only with no
max-width clamp (`tui/src/ui.rs:1811`), so an 80% dialog on a wide terminal is
200 columns, and long paths and untracked-file lists are exactly the content
that would expose it. More decisively, overlays render `Clear` and never set a
background (`tui/src/ui.rs:1094-1095`), so on a light terminal their interior
shows the raw terminal background rather than the painted paper. A surface this
large would read as a hole in the page. `card_frame` paints paper.

The footer's mode match is exhaustive with no `_` arm
(`tui/src/ui.rs:919-934`), so adding the variant is a compile error until its
key hints are written. That is desirable.

Keys: `j`/`k` and arrows to move, `r` to re-probe, enter to finish, `Esc`/`q`
to return to the picker. The 10-second rescan runs only in `Mode::Normal`
(`tui/src/main.rs:150`), so this mode gets no free refresh — hence `r`, and
hence the screen presents itself as a snapshot rather than a live view.

Enter on a blocked feature refuses in the status line, naming the blocker, and
does not exit. The screen is advisory; cs remains the authority.

### `cs <base> -finish <feature>`

Opens the base session with `/merge <feature>` in the launch prompt. It does
not merge anything itself.

`--merge` is the mechanical git step; `-finish` runs the ritual around it. The
word is already the repo's: doctor says "fully merged; finish with:"
(`lib/60-doctor.sh:301`).

Argument validation matches `--merge` exactly, reusing
`cs_split_worktree_name "$session_name@$1"` (`lib/99-main.sh:293`) so a task
name carrying path separators is rejected before any filesystem lookup. The
feature must also be a registered worktree of the base.

The launch prompt is a single slot — `launch_prompt="${spawn_kick:-$color_arg}"`
(`lib/75-launch.sh:178`) — because Claude has no `--color` flag and a positional
prompt is the only mechanism. This adds one entry to that chain rather than a
parallel path:

    launch_prompt="${merge_kick:-${spawn_kick:-$color_arg}}"

The merge kick wins because it comes from an explicit action the user took
seconds ago, where a spawn seed was staged earlier. When it displaces a spawn
kick, cs warns that the walk-away queue is armed and will be picked up after
the merge — the queue state is already written by then, so nothing is lost, but
the displacement must not be silent.

## The handoff needs no new picker plumbing

`lib/99-main.sh:41-43` reads line 1 of the TUI's stdout as a session name and
word-splits the remaining lines into argv, then `exec`s. Printing

    snip
    -finish merge-tui

runs `cs snip -finish merge-tui`. The `Action` enum gains one variant carrying
a session and its argv words, mirroring that protocol exactly. Argv words must
not contain spaces, which session and feature names cannot.

The TUI paints to stderr and writes only the exit payload to stdout
(`tui/src/main.rs:59-66,79`), so the probe fork must not inherit stdout.
`Command::output()` pipes stdout and stderr, which is correct, but it leaves
stdin on the raw-mode tty (`tui/src/app.rs:1734`) — harmless for a read-only
query that never prompts.

A nonzero TUI exit kills cs outright (`tui_output=$(...) || exit $?`,
`lib/99-main.sh:38`), so a failed probe is a status-line message, never an
exit code.

## What the screen must not claim

`lib/30-worktree.sh:256` runs `git merge --no-edit` with **no `--no-ff`**, so a
feature whose base has not moved fast-forwards and leaves no merge commit,
while `skills/merge/SKILL.md:54` mandates `--no-ff` for ordinary branches. One
affordance hiding two behaviors is the trap. The screen names which one will
happen, computed from whether the base actually moved.

`git branch -d` at `lib/30-worktree.sh:270` is best-effort with stderr
discarded, and the timeline event at `:273` is `|| true`. The screen describes
these as intended steps, never as completed facts.

The screen shows no diff and browses no commits. That is a separate feature and
`git merge-tree` conflict prediction is unmeasured work.

## Visual contract

Every colour is a token from `tui/src/theme.rs`; no literal RGB. The light
palette is council-approved verbatim and test-pinned (`theme.rs:320`), and
`detect_theme()` reads only `CS_TERM_THEME`, exported by the bash wrapper
before launch (`lib/99-main.sh:36`) — light is not inferable from Rust, so the
screen must be designed against paper, not assumed dark.

Colour is nearly absent: plain ink for a ready feature, `amber` for a blocker,
`faint` for already-merged. Teal is not used — it is reserved exclusively for
liveness and a test pins that (`tui/src/ui.rs:2666`). No new diff green or red;
the existing red and green are status-text colours and were never tuned as
surfaces.

Structure comes from alignment and hairline rules: an uppercase column header,
no zebra striping, no vertical dividers, no table border. Glyphs are limited to
box-drawing, block elements, geometric shapes and braille; the B′ spec's tofu
list names `⎇` explicitly (`docs/superpowers/specs/2026-07-14-tui-bprime-design.md:45-48`).

Nothing animates. "One animated element … nothing else animates" (same spec,
:49-51), and the only meter in the product is `qbar`'s four-segment `▰▱`
(`tui/src/ui.rs:189`). The step list on the detail pane is a *plan* — what will
happen, in order — not progress. Nothing runs in this screen, so there is
nothing to animate.

## Prerequisites

Four changes are not the feature but block it.

1. `has_git` must accept `.git` as a file (`tui/src/session.rs:424`). The
   correct probe already exists in the delete path (`:688`) and is used nowhere
   else. Without this every feature row stays git-blind.
2. `skills/merge/SKILL.md` needs a third context: invoked in a base session,
   closing out a named feature given as an argument. It detects only
   worktree-I-am-standing-in and ordinary-branch today, so a `/merge <feature>`
   arriving in the base would find no context.
3. cs must export its own path to the TUI, alongside the `CS_VERSION` it
   already exports at `lib/99-main.sh:38`, and the TUI must use it. Today
   `Command::new("cs")` is hardcoded with no seam (`tui/src/app.rs:1695`) while
   cs itself probes for a sibling binary when the TUI is not on PATH; the
   reverse case makes every fork fail at spawn. This also supplies the test
   injection seam the three existing shell-outs lack.
4. `sample_sessions()` has no `base@task` row. The Rust tests need one.

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

**Deferred cleanup — merge now, remove the worktree later.** Already rejected
at `docs/superpowers/specs/2026-07-23-in-session-worktree-merge-design.md:61-68`,
because a retry after fusion double-appends timeline, log and narrative.
Nothing here revisits it.

**A "commit and merge" affordance.** A policy reversal, not a UI detail. cs
"refuses rather than committing on the user's behalf"
(`lib/30-worktree.sh:192-193`), and "No automatic commits of session or project
state, ever" (`docs/superpowers/specs/2026-07-02-worktrees-design.md`).

**Enabling the affordance only for fully-clean rows.** Liveness in the picker
is up to 10 seconds stale and a heartbeat window is 900 seconds
(`tui/src/session.rs:659`), so a hard enable/disable would lie in both
directions. The screen shows the blocker and lets cs deliver the actual
refusal.

## Tests

Shell, in `tests/test_worktrees.sh`'s real-temporary-git style:

- `-features` reports a clean feature worktree as ready.
- A worktree containing only untracked files is reported with an untracked
  count and *not* as dirty — the `_tree_is_dirty` distinction, asserted
  against the gate's own behavior rather than recomputed.
- A branch whose tip is an ancestor of the base head reports already-merged.
- Blockers appear in `merge_worktree_session`'s gate order.
- `--json` emits one parseable object per line.
- `-finish` refuses an unknown feature and a directory that is not a registered
  worktree.
- `-finish` arms the ritual and merges nothing: the branch is still unmerged
  afterwards.
- A merge kick displaces a spawn kick and warns.

Rust, in the `handle_key` idiom:

- `m` on a base with features enters the mode; on a base without, it sets a
  status and stays.
- Enter on a blocked feature does not exit.
- Enter on a ready feature yields the exit payload naming the base and
  `-finish <feature>`.
- `Esc` returns to `Mode::Normal`.
- `has_git` is true for a `.git` file.

The shell suite must run on bash 3.2 with BSD userland, and the
`test-windows-msys` lane is required. Added git forks are proportionally more
expensive on Windows, where liveness already forks `tasklist` per locked
session (`tui/src/session.rs:771`).
