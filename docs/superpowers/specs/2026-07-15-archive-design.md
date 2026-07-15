# Session archive: cs -archive, hidden-by-default listings, open-to-unarchive — design

Date: 2026-07-15
Status: pending spec review
Decision trail: ranked #3 in the four-provider council deep-research on cs
capability gaps (a consensus pick: session lifecycle management — today the
only exit from the listing is destructive `cs -rm`). Brainstormed with Alex
2026-07-15 via three gates: mechanism (marker file; the subdir-move variant
was rejected as architecture-fatal — moving a session directory changes its
cwd, which changes Claude Code's project-dir encoding and severs conversation
resume for every conversation in the session), hide scope (everywhere by
default), and open semantics (opening an archived session auto-unarchives).

## Context and goal

Sessions accumulate and never leave: finished work sits in the picker,
`cs -list`, and `cs -search` results forever, because the only lifecycle
verb is `cs -rm`, which destroys the session. The goal is a reversible
"done for now" state — archived sessions vanish from every default listing
but keep their directory, git history, secrets, and conversations intact,
and come back the moment they are opened.

## Decisions (approved by Alex 2026-07-15)

1. **Mechanism = a tracked `.cs/archived` marker file.** Presence is the
   state; content is one advisory line. Git-synced like README status, so
   archiving on one machine archives everywhere.
2. **Hidden everywhere by default**: the TUI (visibility toggle, archived
   rows rendered dimmed), `cs -list` (hidden; `--archived` lists only
   archived; composes with `--tag`), and `cs -search` (skipped;
   `--include-archived` includes).
3. **Opening an archived session auto-unarchives it** at launch, with a
   one-line notice. TUI opens flow through the same cs launch path, so the
   picker gets this for free.
4. **Explicit-name verbs only**: `cs -archive <name>` / `cs -unarchive
   <name>`. No ambient in-session form — archiving the session you are
   inside is the pathological case, and the live guard covers it.
5. **Archiving a live session (lock held by a running process) is refused
   without `--force`** (council guard).
6. **cs never commits for you**: archive and unarchive leave the marker
   change uncommitted, exactly like README objective/status edits; the
   shadow-ref autosave protects it meanwhile.

## Non-goals

- No auto-archive by age or activity (a plausible follow-up, not v1).
- No archive/unarchive action inside the TUI — the picker only toggles
  visibility; state changes go through the CLI verbs or open-to-unarchive.
- No separate storage: archived sessions stay in `$SESSIONS_ROOT`, no move,
  no compression.
- No archived section header in the TUI (v1 dims rows in place; the
  existing time-section machinery is untouched).
- No bulk verbs (`cs -archive --all`, patterns).
- No change to `cs -live` or presence: liveness is a fact, and a
  synced-archived-but-live session still shows there.

## Design

### Marker contract

`$session_dir/.cs/archived`, a TRACKED one-line file:

    archived: 2026-07-15 by alex-geana-erepubliklabs-com

Date from the local clock at the moment of archiving, actor from
`cs_actor_slug` (lib/40-state.sh:129). Presence alone means archived — any
content, including empty or a merge-conflicted body, still reads as
archived, which is what makes concurrent edits from two machines
semantically irrelevant. Unarchive deletes the file. In repos that
gitignore `.cs/` wholesale, the state is machine-local like all `.cs`
state there.

### CLI surface

    cs -archive <name> [--force]     # refuse live sessions without --force
    cs -unarchive <name>
    cs -list [--archived] [--tag <t>]
    cs -search <query> [--include-archived]

- New fragment `lib/59-archive.sh`: `run_archive <name> [--force]` and
  `run_unarchive <name>`. Both resolve the session dir (symlink-resolving
  for adopted sessions, mirroring other verbs), error on an unknown
  session, and are idempotent: archiving an archived session or
  unarchiving a plain one prints an info line and exits 0.
- Live guard: `session_is_live "$dir/.cs"` (lib/15-lock.sh:110). When live
  and `--force` absent, error naming the running pid and `--force`.
- Dispatch: site-A arms `-archive` / `-unarchive` (8-space indent for the
  completions drift guard). These are NOT site-B session subcommands — the
  name is the verb's argument — so the site-B error enumeration is
  untouched. Help lines in `show_help` (unquoted heredoc — no backticks),
  both completion files with session-name completion for both verbs,
  README.
- `list_sessions` (lib/65-sessions.sh:91): the collection loop skips
  sessions whose marker exists; `--archived` inverts the test (only
  archived). Both compose with the existing `--tag` filter. When archived
  sessions were hidden, a trailer line in comment ink follows the table:
  `N archived (cs -list --archived)`.
- `search_sessions` (lib/65-sessions.sh:4): dispatch changes from
  `search_sessions "${2:-}"` to `shift; search_sessions "$@"`; a small
  parse loop takes `--include-archived` in any position, first non-flag
  argument is the query (empty query keeps today's usage error). The
  per-session loop skips marker-bearing sessions unless the flag is set.

### Launch auto-unarchive

In `launch_claude_code` (lib/75-launch.sh), immediately after
`acquire_session_lock` succeeds: if the marker exists, delete it and print
one line — `info "Unarchived <name>"`. Placing it after the lock means a
cancelled collision menu leaves the marker in place; placing it before the
exec means every open path (CLI and TUI, which execs `cs <name>`) inherits
it. The removal is left uncommitted (Decision 6).

### TUI

- `Session` gains `archived: bool`: `read_session` stats
  `meta_dir/archived` alongside the existing lock check
  (tui/src/session.rs:310).
- `App.show_archived: bool`, default false. Key `A` toggles it (verified
  free — bound printables today are `/123456abcdDegGhijklnpqrsvxyYz`) and
  re-runs the filter.
- `apply_filter_and_sort` skips archived sessions unless `show_archived` —
  the single filter choke point, so tag and fuzzy branches both inherit.
- When shown, archived rows render entirely in FAINT (status dot included);
  the selection wash and rail still apply so the selected archived row
  stays readable.
- Masthead appends `· N archived` in FAINT when N > 0 — the discoverability
  cue that hidden state exists. Counts stay computed over all sessions.
- Footer gains an `A archived` key hint (the existing hint clipping
  degrades it gracefully on narrow terminals).
- Preview card: the `state` meta row reads `archived` in FAINT for an
  archived session (live/locked wins if both somehow hold).

### Storage classification (multi-user law)

One new write path: `.cs/archived`, tracked, single line, no merge driver.
Concurrent archive from two machines conflicts only on the advisory
content, and any resolution still reads as archived. Archive-vs-unarchive
races surface as a git delete/modify conflict for a human — rare, and
either resolution is acceptable because presence is the state.

## Testing (TDD, vertical slices)

Bash (`tests/test_archive.sh`, driving `bin/cs` through the harness):

1. Verbs exist (not "Unknown command").
2. Archive writes the marker with the advisory line; unarchive removes it.
   Re-archive / unarchive-a-plain-session exit 0 with an info message.
3. Unknown session errors non-zero for both verbs.
4. `cs -list` hides an archived session and prints the trailer;
   `--archived` shows only it; `--archived --tag <t>` composes (one
   archived+tagged in, one archived-untagged out).
5. `cs -search` finds a string in a plain session but not an archived one;
   `--include-archived` finds both; `cs -search --include-archived` with no
   query still errors with usage.
6. Live refusal: a `sleep`-backed pid in `session.lock` makes `-archive`
   fail mentioning `--force`; `--force` archives anyway.
7. Launch auto-unarchive: stub `CLAUDE_CODE_BIN` (the `test_session_lock.sh`
   recipe), open an archived session, assert the marker is gone and the
   notice printed.
8. Help mentions both verbs; the completions drift guard covers the new
   arms automatically.

Cargo (`tui/src`): marker presence → `Session.archived`; archived session
absent from filtered rows by default; present after the `A` toggle; dimmed
render and masthead `· N archived` via `TestBackend` cell inspection;
preview `state` row reads `archived`. Run from `tui/` so the single-thread
config applies.

Full gates: `bash tests/run_all.sh` + `cargo test`.

## Risks

- **"Where did my session go?"** — hidden state is invisible by design.
  Mitigations: the masthead archived count, the `cs -list` trailer, and
  dimmed-not-removed rows when toggled visible.
- **Marker delete/modify conflicts** in shared sessions are possible but
  benign: presence semantics make either resolution correct.
- **Launch-path coupling**: auto-unarchive sits between lock acquisition
  and exec. A crash in that window leaves the session unarchived and
  visible — the safe direction.
- **`--force` on a live session** leaves a session that is both archived
  and running; `cs -live` and presence still show it (Non-goals), so it
  cannot silently disappear while active.
- **`-search` dispatch change** from one positional to `"$@"` is the only
  touched existing surface with flag parsing; the empty-query usage error
  is pinned by test 5.
