# Update release notes — design

Date: 2026-07-16
Status: pending spec review
Decision trail: Alex, 2026-07-16 (mid-arc addition, slotted before the
/merge skill): "how can we display changelog with the release notes for
the versions above the current installed version when we notify that a cs
update is available? ... it should look professional and cool." Decisions
via AskUserQuestion: build now (feature 3 of what is now a four-feature
arc), launch volume = compact card (a summary line per pending version,
capped) rather than a quiet one-liner or full notes at launch.

## Context and goal

Today the update pipeline knows only version NUMBERS until after an
update: `get_remote_version` reads the GitHub `releases/latest` redirect,
`check_update_notify` caches it hourly, the launch banner prints one
yellow line (`lib/75-launch.sh:139`), `cs -update --check` prints
current/latest, and `do_update` shows a changelog section only AFTER
overwriting the install — and only the single newest version, even when
the update crossed several. Meanwhile `CHANGELOG.md` is authored for
exactly this moment: every `## X.Y.Z` section opens with a one-line
summary sentence. The goal: when cs says "update available", show what
the user would actually get — every version above the installed one — in
the house visual style.

## Decisions

1. **Data source: the repo's raw `CHANGELOG.md`**, fetched with the same
   curl discipline as the version check (`-fsSL --connect-timeout 2
   --max-time 4`). New constant beside `RELEASES_BASE` in
   `lib/00-header.sh`:
   `CHANGELOG_RAW_URL="https://raw.githubusercontent.com/hex/claude-sessions/main/CHANGELOG.md"`.
   Any fetch failure falls back to today's behavior at that surface —
   the feature only ever adds information.
2. **Span extraction**: walk `## X.Y.Z` headings in file order (the file
   is newest-first); collect sections while `version_greater(section,
   installed)`; stop at the first heading that is not greater. A span,
   not one section — updating 2026.7.10 → 2026.7.13 shows .13, .12, .11.
3. **Three surfaces, three volumes** (approved):
   - **Launch banner card** (compact): under the existing yellow update
     line, one line per pending version — the version in green and its
     one-line summary from the changelog, prefix "One fix:"/"One
     change:" style intact as authored, stripped of markdown, truncated
     to the terminal width. Capped at 5 versions; more collapse to
     `… and N earlier versions`. The card continues the banner's `▌`
     left-bar chrome in the update line's yellow.
   - **`cs -update --check`**: the full rendered span after the
     "Update available" line.
   - **`cs -update`** (post-update notes, existing): the single-version
     sed extraction is replaced by the same span renderer over the
     freshly installed LOCAL `CHANGELOG.md`, spanning from the
     pre-update version (captured before overwrite) — no network.
4. **Launch card cache**: the launch path must not add a network call
   per launch. The card body is cached at
   `~/.cache/cs/update-notes-<remote-version>` (beside the existing
   `update-check` cache). When `UPDATE_AVAILABLE` is set and the cache
   file for that version exists, print from cache; when missing, ONE
   synchronous fetch (2s/4s caps) builds it; on fetch failure an empty
   cache file is written so subsequent launches don't retry the network
   (a retry happens only when a newer remote version appears — new cache
   key — or explicitly via `--check`/`-update`), and the banner shows
   just today's one-liner. The cache file's format is display-ready:
   one `version<TAB>summary` line per pending version, and, when the
   span was capped, a final `+<TAB>… and N earlier versions` line —
   `changelog_summaries` emits exactly this, so the launch path never
   re-derives counts.
   Stale `update-notes-*` files for other versions are pruned when a
   new one is written. `CS_NO_UPDATE_CHECK` short-circuits everything,
   unchanged.
5. **The renderer** (`professional and cool`, shared by --check and
   post-update): a bash markdown-subset renderer, palette-aware via the
   existing `setup_palette` variables (light-terminal safe — never
   assume a dark canvas):
   - `## X.Y.Z` → blank line, then `▌ X.Y.Z` with the version bold green
     and the section's one-line summary in normal text on the same line,
     then a dim rule.
   - `### Added|Changed|Removed|Fixes|Docs|Features|Performance` → a
     small colored label line (yellow, matching the update line's
     accent).
   - `- **Title.** body` → two-space-indented bullet `•`, title bold,
     body dimmed, wrapped to the terminal width (fold at spaces; width
     from `tput cols` fallback 80, capped at 100).
   - Inline: `**x**` → bold; `` `x` `` → `${GOLD}` tint; `[text](url)`
     → text only; other markdown passes through as-is.
   - HTML comments and blank-line runs collapse.
6. **No new verbs, no flags.** The three existing surfaces gain content;
   nothing else changes. `bin/cs` is regenerated by `./build.sh` and
   committed in the same commit as the `lib/` fragments (build BEFORE
   tests).

## Behavior

New functions in `lib/20-update.sh`:

```bash
# Print the changelog sections for every version newer than $2 from the
# markdown on stdin's file ($1), newest first. Sections are delimited by
# '## X.Y.Z' headings; emission stops at the first heading not newer.
changelog_span() { ... }         # (file, installed_version) -> markdown

# One-line summary for each version in a span: "version<TAB>summary".
changelog_summaries() { ... }    # (file, installed_version, cap) -> lines

# Render a changelog markdown stream in house style to stdout.
render_changelog() { ... }       # (stdin markdown)

# Fetch the remote changelog to a tmp file; echo the path or fail.
fetch_remote_changelog() { ... } # () -> path (curl caps 2s/4s)
```

`check_update` (in `--check`): after the existing "Update available"
info line, fetch; on success `changelog_span | render_changelog`; on
failure print the `RELEASES_BASE` link line.

`do_update`: capture `local from_version="$VERSION"` before download;
after install, replace the single-version sed block with
`changelog_span "$new_changelog" "$from_version" | render_changelog`
over the newly installed file, falling back to the existing releases
link line when the file is missing.

`check_update_notify`: unchanged logic, plus: when `UPDATE_AVAILABLE`
gets set, ensure `~/.cache/cs/update-notes-$UPDATE_AVAILABLE` exists —
if absent, `fetch_remote_changelog` and write
`changelog_summaries <file> "$VERSION" 5` into it (empty file on fetch
failure), pruning other `update-notes-*` files.

`lib/75-launch.sh` banner block: after the yellow update line, if the
cache file for `$UPDATE_AVAILABLE` exists and is non-empty, print each
`version<TAB>summary` line as
`${YELLOW}▌${NC}   ${GREEN}version${NC} summary` (summary truncated so
the whole line fits the terminal width), and the collapsed
`… and N earlier versions` line when the span was capped.

## Out of scope

- No TUI changes, no statusline changes, no new cache invalidation
  beyond the version-keyed filename, no changelog authoring checks.
- No rendering of arbitrary markdown beyond the subset above; unknown
  constructs pass through as plain text.
- `get_remote_version` and the hourly cache stay exactly as they are.

## Testing

Extend `tests/test_auto_update.sh` (it already owns update stubbing
patterns; the harness exports `CS_NO_UPDATE_CHECK=1` globally, so tests
drive the new functions directly and unset the guard where a launch path
is exercised). Network is stubbed by pointing `CHANGELOG_RAW_URL`-fetch
through a PATH curl stub or by calling the pure functions on fixture
files — the pure functions take file arguments precisely so tests never
need the network. Fixture: a synthetic CHANGELOG with versions 2026.7.13
/ .12 / .11 / .10, each with a summary line and mixed subsections.

1. `changelog_span` from installed 2026.7.10 emits .13/.12/.11 sections
   in order and stops before .10.
2. `changelog_span` from installed 2026.7.13 emits nothing.
3. `changelog_summaries` cap: cap 2 over three pending versions emits
   two `version<TAB>summary` lines plus the final
   `+<TAB>… and 1 earlier versions` collapse line; summaries are the
   first non-empty line after each heading, markdown-stripped. Uncapped
   (cap 5, three pending) emits three lines and no collapse line.
4. `render_changelog` on the fixture: output contains the version and
   summary on one line, the bold-title bullet text, and NO literal
   `##`, `###`, `**`, or backticks.
5. Launch card: with a pre-seeded cache file, the banner block prints
   the card lines; with an empty cache file, only the existing
   one-liner (no card, no crash).
6. Fetch-failure path: a curl stub that exits 22 leaves `--check`
   printing the releases link (current behavior) and writes the empty
   notes cache.
7. `do_update` span: the post-update notes render the full crossed span
   from a fixture changelog (function-level test against the extracted
   block, not a live update).

All bash 3.2 + BSD (no mapfile, no `local -A`; `fold`/parameter
expansion for wrapping). Every assert `|| return 1`; `report_results`
last.

## Files

- `lib/00-header.sh` — `CHANGELOG_RAW_URL` constant.
- `lib/20-update.sh` — the four functions; `check_update`, `do_update`,
  `check_update_notify` surface wiring.
- `lib/75-launch.sh` — the banner card block.
- `tests/test_auto_update.sh` — the seven cases.
- `README.md` — one sentence in the update section (release notes shown
  for pending versions).
- `docs/` — no dedicated page; README suffices.
- `bin/cs` — regenerated by `./build.sh`, committed with the fragments.

Deploy surface: `~/.local/bin/cs`.
