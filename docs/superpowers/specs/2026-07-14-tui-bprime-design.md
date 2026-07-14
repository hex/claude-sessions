# cs-tui B′ visual redesign — design

Date: 2026-07-14
Status: pending spec review
Decision trail: two-round council process (2026-07-11 three-direction mockups,
transcript `.claude/council-cache/council-1783717237.md`; 2026-07-13 unanimous
round 2 vs current, `.claude/council-cache/council-1783929513.md`), a real
ratatui spike iterated on Alex's cream terminal (`tui/examples/b_preview.rs`,
recovered from a shadow-ref autosave), and Alex's approvals: direction B
2026-07-11, B′ spike 2026-07-14 with all three gradients kept and the queue
▰▱ bar retained.

## Context and goal

The picker's current look is "btop instincts executed flat": a saturated
gradient header band, square boxed panes, zebra striping, and plain-number
columns. Direction B′ commits to the expressive pole — gradient-crafted
chrome adapted for a cream (light) terminal — without changing a single
behavior. **B′ is functionally identical to the current TUI**: same columns,
same data sources, same keys, same mouse targets, same responsive
arrangements. Purely look.

The spike proved the make-or-break elements on Alex's real terminal: rounded
gradient-top cards read as crafted (not dated boxes), the warm wash + rust
rail selection reads premium, and the masthead holds. Council round 2
(unanimous, all four providers) then cut the braille age wick, added
time-section grouping as navigation, demanded 20-30 row density, moved status
to a leading dot, and structured the preview pane.

## Decisions (approved by Alex)

1. **B′ as rendered by the spike is the design.** `tui/examples/b_preview.rs`
   is the visual source of truth for the light theme.
2. **All three gradients stay**: masthead rule, selection rail, card top
   borders. (Perplexity's one-hero-gradient position was considered and
   rejected by Alex on his own terminal.)
3. **Queue column keeps the 4-segment ▰▱ bar + digit** — the one micro-meter
   in the table. Secrets stays a plain number.
4. **Council round-2 unanimous items are binding**: no braille age wick
   (colored text only), grouped sections with `── Label · N ──` divider rows,
   single-line rows at current density, leading status dot (▪ ember when
   locked), structured labeled preview meta, repo-first middle-ellipsis
   github truncation, masthead with prominent count + live count + explicit
   sort, safe glyphs only.
5. **Glyph safety rule** (verified on Alex's font): box-drawing, block
   elements, geometric shapes, and braille render; Miscellaneous Symbols do
   not (tofu). No ☐☑⚿⎇ anywhere; notes checkboxes are ASCII `[ ]`/`[x]`;
   lock is `▪`.
6. **One animated element**: the existing selection-gutter shimmer machinery
   is retained and drives the rail; nothing else animates. The idle-block
   render loop (zero CPU when idle) is untouched.

## Non-goals

- No behavior changes: no new keys, no new columns, no new data sources, no
  changes to sorting, filtering, search, marking, secrets, queue, rename,
  delete, create, or the two-line stdout protocol with cs.
- No dark-theme redesign beyond token mapping (see Palette): the dark
  palette gets B′ chrome with dark-tuned stops, flagged for visual tuning in
  a follow-up pass on a real dark terminal.
- No changes to `bin/cs`, hooks, or install surfaces (the TUI binary is
  self-contained; release packaging unchanged).
- The spike file itself stays a throwaway example — it is not shipped, not
  installed, and may be deleted after the production render matches it.

## Palette (theme.rs)

Light (cream) — council-tuned, verbatim from the spike:

    PAPER  (250,247,242)   INK   (43,33,24)     MUT   (122,106,88)
    FAINT  (168,151,130)   SOFT  (226,213,196)  STRONG(201,180,155)
    RUST   (183,71,34)     EMBER (216,90,36)    AMBER (242,167,53)
    GOLD   (176,132,40)    WASH  (255,240,218)  TEAL  (15,118,110)
    HERO ramp: (143,50,28) → (216,90,36) → (242,167,53) → (214,162,30)
    RAIL ramp: (193,58,29) → (228,91,34) → (232,167,46)

Dark — derived from the existing dark palette's warm family; same structure,
stops chosen to glow on a dark canvas (these are the current dark header
band's hues re-purposed):

    WASH  = a low-luminance warm tint (existing dark sel_bg family)
    HERO ramp: (221,80,20) → (237,128,0) → (246,154,0) → (214,162,30)
    RAIL ramp: (221,80,20) → (246,154,0) → (250,180,60)
    TEAL  = (45,212,191) (dark-legible live accent)
    Other tokens map to existing dark palette equivalents.

New `Palette` fields carry these as data (per-theme), so `ui.rs` never
branches on theme — it reads tokens, matching how heat colors work today
(`Palette::heat_color`, theme.rs:135-155).

`lerp`/`ramp` (gradient interpolation over N cells) move from the spike into
`theme.rs` as tested pure functions.

## Design

### Masthead (replaces the saturated header band)

Row 0: `▌` in RAIL[0] + `cs-tui` bold RUST + `N sessions` bold INK +
`· M live` TEAL + `· sorted by <col>` MUT. Row 1: full-width `━` rule
colored by the HERO ramp. `N` = total sessions, `M` = count of sessions
whose lock is held by a running process (existing `is_locked` liveness),
`<col>` = active sort column's lowercase label. Wherever the version string
renders today, it moves to the footer's right edge in FAINT.

### Table (borderless, restyled in place)

The ratatui `Table` widget, Layout-solved column widths, published
`column_widths`/`visible_sort_columns` mouse hit-testing, scrolling, marked
rows, and fuzzy-highlight spans are all KEPT — only styles and cell content
change:

- Zebra striping removed. Row separation comes from grouping dividers and
  spacing; no per-row alternating background.
- Header row: MUT bold labels; the active sort column carries a trailing
  `▼`/`▲` marker in RUST (both directions exist today via `cycle_sort`).
- Leading status cell: `●` colored by the existing heat ramp; `▪` EMBER when
  the session is locked; `*` marked indicator unchanged.
- AGE: colored text riding the heat color (already implemented), no meter.
- SECRETS: plain number INK (bold when selected); `·` FAINT when zero.
- QUEUE (was To-Do `▤ n`): `qbar(n)` — 4-segment `▰▱` fill (0→0, 1→1,
  2-3→2, 4-5→3, 6+→4 segments), colored FAINT/AMBER/RUST by depth
  (0 / 1-3 / >3), digit in MUT beside it when non-zero. Column header
  becomes `QUEUE`.
- GITHUB: `truncate_repo` — full `owner/repo` when it fits, else repo alone,
  else middle-ellipsis on the repo; never tail-clipped. FAINT normally, RUST
  on the selected row.
- Selection: WASH background across the row + `▌` rail glyph in the gutter
  (RAIL ramp; driven by the existing shimmer phase) + bold name. The
  REVERSED/solid `sel_bg` treatment is removed.
- Group dividers (existing `section_labels` machinery, restyled): a blank
  row before each new section (except the first), then
  `── <Label> · <count> ` in MUT bold with the rule extended to the table's
  right edge in SOFT. Rendered only when date-sorted, exactly as today.

### Right column cards (preview + notes)

The square `Block` borders are replaced by a hand-painted card frame (the
spike's `card()` technique, promoted to a ui.rs helper): rounded corners,
top border colored per-cell by the HERO ramp with the lowercase title set
into the frame (`╭ preview ───╮`), side/bottom borders in a single tone
(STRONG for preview, SOFT for the second card). Painted via direct buffer
access after the pane content renders — ratatui has no per-cell gradient
border, so this is a custom painter, kept as one small pure-ish function
taking (`buf`, rect, title, side tone). Card titles stay truthful to the
panes they frame: `preview` and `to-do` (the spike's mockup said "notes";
the real pane holds the walk-away queue and keeps its name).

Preview content becomes the structured compact block: session name bold,
then labeled key-value rows (`created`, `modified`, `state` — value TEAL
with `● live · locked <pid>` when applicable — `repo`, `objective`,
`narrative`) with FAINT labels and INK/MUT values, followed by whatever the
pane shows today (discoveries, memory, contributors) restyled to the same
tokens. Notes pane keeps its content; checkbox lines render `[ ]`/`[x]`
ASCII.

Both responsive arrangements (side-by-side ≥120 cols, stacked ≥40x25) keep
their geometry; only the frames and inner styling change.

### Footer

Key hints restyled: key glyph in bold RUST, label in MUT, three-space
separation (`↑↓ move   ↵ open   …`). Content and keys unchanged. Version
string right-aligned in FAINT.

### Everything else

Dialogs (create, delete confirm, rename, secrets, batch), the search bar,
and the To-Do pane input keep their current structure with colors mapped to
the new tokens (no WASH/rail treatment). They are explicitly in scope only
for token mapping, not redesign.

## Structural notes (Kernighan/Gall)

- New pure helpers, all unit-testable without a terminal: `lerp`, `ramp`
  (theme.rs); `qbar`, `truncate_repo` (session.rs or ui.rs beside their
  use); `card` painter (ui.rs, takes a `&mut Buffer`).
- No new state on `App` except what the masthead needs (live count is
  computed per render from existing session data — no cache).
- The render loop, event handling, worker threads, and preview cache are
  untouched.

## Testing

- Existing 203 tests: render-assertion tests that check symbols/colors of
  the old look (band, zebra, `▤`, square borders) are updated to assert the
  B′ equivalents — each updated assertion must still discriminate (assert
  the new property, not merely delete the old assertion).
- New unit tests: `ramp`/`lerp` endpoints and midpoints; `qbar` all five
  fill levels; `truncate_repo` fits/repo-only/middle-ellipsis/1-char/`—`
  cases; masthead live-count; divider row content `── Today · N `; card
  top-border title placement and rounded corners via `TestBackend`;
  selection row wash+rail+bold via `TestBackend` cell inspection; locked ▪
  vs heat ● choice.
- Both themes: token-mapping tests assert the light palette constants
  verbatim (they are the council-approved values — a regression here is a
  design regression) and that dark tokens exist and differ from light.
- `RUST_TEST_THREADS=1` constraint holds (tests mutate process-global env).
- Visual gate: after the production render matches, a `--dump`-style
  comparison against the spike is a manual step (Alex's terminal), not CI.

## Risks

- **Card painter is the least forgiving element** (council + spike both):
  half-executed it reverts to "framed panels". The spike's exact technique
  (per-cell HERO ramp over the top row, title inside the frame) is the
  reference; the plan should port it verbatim, then adapt.
- **Test churn**: many `ui.rs` tests assert the old chrome; the plan must
  treat each as a deliberate re-assertion, not bulk deletion.
- **Dark theme is unproven**: B′ was designed on cream. Dark stops above are
  an informed mapping; a real dark-terminal pass may retune them (follow-up,
  not blocking).
- **Width edge cases**: the masthead's counts and the divider rules must
  truncate gracefully below ~70 cols; the existing small-terminal
  arrangements define the floor.
- **Hyrum**: the two-line stdout protocol, stderr rendering, and
  `CS_TERM_THEME` handoff are observable contracts — untouched by design.
