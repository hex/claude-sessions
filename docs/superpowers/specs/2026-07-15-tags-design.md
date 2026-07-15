# Session tags: cs -tag verbs, -list filter, TUI #tag search — design

Date: 2026-07-15
Status: pending spec review
Decision trail: ranked #2 in the four-provider council deep-research on cs
capability gaps (the strongest cross-vendor consensus: three seats
independently named tag surfacing, and grok correctly observed the data
model already exists — the gap is only that cs cannot read, write, or
filter by it). Brainstormed with Alex 2026-07-15: v1 = CLI + TUI filter;
tags display in the preview pane only, keeping the just-shipped B′ table
chrome untouched. Claude Code's native session `tag` (single string,
SDK-only setter, per-conversation) was evaluated via bundle research and
rejected as the store — wrong shape for a multi-tag, git-synced workspace.

## Context and goal

Past roughly 30-50 sessions, name-based navigation stops scaling. Sessions
already carry a `tags: []` YAML frontmatter field in `.cs/README.md`
(written at creation for the Obsidian integration), but nothing in cs reads
or writes it: tagging means hand-editing frontmatter, and no filter exists
in the CLI or the picker. The goal is to make that existing field
first-class: editable from the CLI, filterable everywhere sessions are
listed.

## Decisions (approved by Alex 2026-07-15)

1. **Store = README frontmatter `tags`**, inline-array form (`tags: [api,
   infra]`). Git-synced, human-editable, already indexed by Obsidian.
2. **v1 scope = CLI verbs + `cs -list --tag` + TUI `#tag` filter.**
3. **Tags display in the preview card only** (a `tags` meta row); the B′
   table's column set and row chrome stay untouched.
4. **Verb grammar mirrors `-queue`/`-status`**: ambient in-session form and
   explicit `cs <name> -tag ...` site-B form.
5. **Multi-machine posture: no new merge machinery.** README already sits
   in the sharing model's "real content conflicts are for humans" tier;
   concurrent tag edits from two machines surface as a normal README
   conflict.

## Non-goals

- No tag column, chips, or table chrome in the TUI.
- No tag-based sort, no tag counts in `cs -list` output rows.
- No hierarchy, namespaces, or tag renaming across sessions (`cs -tag
  rename` is a plausible follow-up, not v1).
- No sync with Claude Code's native per-conversation `tag` field.
- No `cs -search` integration (search greps content already; `#tag` lives
  in the TUI query and `-list --tag` in the CLI).

## Design

### Frontmatter contract

The `tags:` line inside the leading `---` frontmatter block of
`.cs/README.md` is the single source of truth. cs reads and writes ONLY the
inline-array form on one line:

    tags: []
    tags: [api]
    tags: [api, infra-migration]

Reading tolerates arbitrary spacing and quoted entries (`"api"`); writing
always emits the canonical unquoted, comma-space form. A missing `tags:`
line (pre-cs sessions, hand-edited files) is treated as empty; `-tag add`
inserts the line into the existing frontmatter block (after `status:` when
present, else as the block's last line). A file with no frontmatter block
at all gets one only if the session was created by cs (it always has one);
otherwise `-tag add` errors cleanly rather than restructuring a foreign
README (adopted sessions keep their own README shape — their frontmatter
was merged in at adoption).

Block-style YAML lists (`tags:\n  - api`) are read as UNSUPPORTED: the
reader returns empty and `-tag add` refuses with a message naming the file
and the expected inline form, rather than corrupting a hand-authored
structure it does not parse.

Tag names: `[a-z0-9._-]+`, max 32 chars, lowercased on write; anything else
is rejected with the allowed charset in the error. Duplicates are
deduplicated on write; tag order is preserved (append at the end).

### CLI surface

    cs -tag add <tag>...          # ambient session (in-session, like -status)
    cs -tag rm <tag>...           # ambient session
    cs -tag list                  # all distinct tags across sessions, with counts
    cs -tag list <session>        # one session's tags
    cs <name> -tag add|rm|list ...  # site-B explicit-target form
    cs -list --tag <tag>          # filter the session listing (also -ls)

- New fragment `lib/58-tags.sh`: `run_tag()` dispatcher plus
  `_tags_read <readme>` (prints one tag per line), `_tags_write <readme>
  <space-separated-tags>` (atomic tmp+mv, rewrites only the tags line),
  `_tag_validate <tag>`.
- `run_tag` add/rm require a target session: ambient
  `CLAUDE_SESSION_META_DIR` when set, else error `In-session only; use
  'cs <name> -tag ...' from outside` (the `run_status` precedent).
  `-tag list` works anywhere (bare form scans all sessions).
- `cs -list --tag <t>`: `list_sessions` gains an optional tag filter —
  sessions whose tag set lacks `<t>` are skipped. `--tag` with no value
  errors with usage. The flag composes with nothing else (`-list` takes no
  other options today).
- Site A arm `-tag`, site B arm mirroring `-queue` (exports ambient env,
  calls `run_tag`), site-B error enumeration updated, help lines,
  both completion files (global flags, session_opts, and a `tag_cmds="add
  rm list"` context), README.

### TUI

- `Session` gains `tags: Vec<String>`; `read_session` parses the
  frontmatter `tags:` line with the same tolerant inline-array rules
  (hand-rolled line scan of the first frontmatter block — no YAML
  dependency, matching the crate's no-serde ethos). Unsupported block-style
  lists read as empty, mirroring bash.
- Query grammar: tokens starting with `#` in the search input are tag
  predicates; the remainder is the existing fuzzy name query. Parsed at the
  top of `apply_filter_and_sort` (the single filter/sort choke point):
  sessions must carry ALL `#`-tags (AND semantics), then fuzzy runs on the
  rest. `#` alone (no tag text yet) matches nothing while typing — the
  dimming behavior handles it gracefully like any non-matching query.
- Preview card: a `tags` meta row (label FAINT, values MUT, comma-space
  joined) after `repo`, omitted when the session has no tags.
- Footer/search hint and README document the `#tag` syntax.

### Storage classification (multi-user law)

No new files. The README frontmatter is already git-synced content with
human-conflict semantics (Decision 5). The TUI only reads.

## Testing (TDD, vertical slices)

Bash (`tests/test_tag.sh`, driving `bin/cs` through the harness):

1. Verb exists (not "Unknown command").
2. `_tags_read`/`_tags_write` round-trip through the CLI: add to a fresh
   session (`tags: []` → `tags: [api]`), add a second, rm one, list.
3. Add inserts the line when missing; preserves every other frontmatter
   line byte-for-byte (assert the full block).
4. Validation: uppercase is lowercased; `bad/tag` rejected non-zero with
   the charset in stderr; duplicate add is a no-op.
5. Block-style list refused with the naming error; file untouched.
6. Ambient vs site-B: in-session add works; out-of-session bare add errors;
   `cs <name> -tag add` works.
7. `cs -tag list` bare: counts across two sessions; `cs -list --tag`
   filters (one in, one out).
8. Completions drift guard covers `-tag` automatically; help test.

Cargo (`tui/src`): frontmatter parse worked examples (empty, one, many,
quoted, spaced, block-style→empty, missing line, no frontmatter); `#tag`
query parse (pure fn: query → (tags, fuzzy_rest) worked examples); filter
semantics (AND of two tags; #tag + name remainder); preview `tags` row
renders; a session without tags omits the row.

Full gates: `bash tests/run_all.sh` + `cargo test` (run from `tui/` so the
single-thread config applies — see the CI-flake follow-up).

## Risks

- **Frontmatter edit robustness is the whole game.** The writer touches
  one line inside a fenced block in a file humans also edit. Mitigations:
  inline-form-only contract, refuse-don't-guess on block-style, atomic
  write, byte-preservation test (item 3), and the reader/writer pair lives
  in one fragment.
- **bash/TUI parser drift**: two implementations of the tolerant read (bash
  awk + Rust). Both pin the same worked examples in their tests; the spec's
  examples above are the shared source of truth.
- **Adopted sessions**: their README carries merged-in frontmatter from
  adoption; the no-frontmatter error path covers hand-rolled outliers
  without corrupting them.
- **`#` in real session names** would collide with the query grammar;
  `validate_session_name` already rejects `#`, so the token space is clean.
- Obsidian/Dataview users see the same tags — a feature, not a risk, but
  the canonical write format must stay Dataview-parseable (inline arrays
  are).
