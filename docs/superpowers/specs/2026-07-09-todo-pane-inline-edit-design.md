# To-Do pane: padding, no-wrap, in-place task editing — design

Status: approved by Alex 2026-07-09. Scope: `tui/src/app.rs`, `tui/src/ui.rs`.
No bash, no CLI, no file-format change. The `.cs/local/queue` contract is unchanged.

## Context and goal

The To-Do pane (`render_notes_pane`, `tui/src/ui.rs`) shows a single-line input
on top, a full-bleed rule, then a numbered list of the selected session's queued
tasks read live from `.cs/local/queue`. Alex reported four rough edges while
using it:

1. The input field and task rows hug the pane's left border — no padding.
2. A task longer than the pane wraps onto extra lines, shoving later tasks down.
3. Editing a task (`e` / `Enter` on a row) hoists its text into the *top* input
   line. For a long task the block cursor scrolls off the pane edge and you edit
   blind.
4. In edit mode there is no visual signal on the row itself showing which task is
   live or where the cursor sits.

Goal: pad the pane, render each task on exactly one line, and edit a task *on its
own row* with an italic slant and a visible block cursor, however long the text.

## Decisions (approved by Alex 2026-07-09)

- **Input row during edit:** a dimmed hint naming the task — `editing 2 · Enter
  saves · Esc cancels`. The footer already renders the same keys (`ui.rs:621`);
  the input row's job is to name *what* is being edited, not repeat *how*.
- **Overflow when not editing:** truncate to the row width with a trailing `…`,
  so a clipped task is distinguishable from a short one.
- **Separator rule:** stays full-bleed (border to border). Only the input row and
  the task rows are inset; the rule still reads as a header divider.
- **Italic scope:** only the task *text* slants in edit mode. The `▸ ` marker and
  the `N. ` number stay upright so the row keeps vertical alignment with its
  neighbours. The block cursor stays solid (not italic).
- **State model:** collapse the two-field edit state into one. Delete
  `editing: Option<usize>`; add `NotesFocus::Editing`. The edited row is always
  `notes_selected`, so the selection and the edit target cannot drift.
- **Up/Down while editing:** ignored. This is a single-line field; moving the
  list selection mid-edit would let the typed row and the commit target diverge.
- **Mouse session-switch while editing:** any mouse event that changes the
  selected session (left-click on another row, scroll wheel) first cancels the
  in-progress edit — buffer discarded, `notes_focus = List` — then switches. The
  keyboard cannot switch sessions while the Notes pane is focused, but the mouse
  handler gates only on `mode`, not focus (`app.rs:1628`), so this guard is
  required to keep `notes_selected` a valid edit target.

## Non-goals

- No vertical scrolling of the task list. More tasks than rows still clips at the
  bottom, exactly as today.
- No change to `truncate_str` (byte-vs-column, wrong for multibyte) or the
  preview pane. Task-row truncation gets its own width-aware helper.
- No multi-line tasks. A task is one line; `\n` is not enterable (matches today).
- No new dependency. `unicode-width` is already in `Cargo.toml`.

## Design

### State: one focus enum, no `editing` field

`Focus::Notes` has a sub-focus `NotesFocus`. Today: `Input | List`, plus a
separate `editing: Option<usize>` that must agree with `notes_focus == Input`.

New: `NotesFocus { Input, List, Editing }`, and `editing` is deleted. Invariants:

| notes_focus | meaning | edited row |
|-------------|---------|------------|
| `Input`     | typing a new task in the top line | — |
| `List`      | a task is highlighted (`notes_selected`) | — |
| `Editing`   | `notes_selected`'s row is being edited in place | `notes_selected` |

Because the list can't move while `Editing` (Up/Down ignored), `notes_selected`
alone names the edit target. `submit_notes_input` keys off `notes_focus` instead
of `editing`: `Editing` → `replace_notes_task(name, notes_selected, text)`,
otherwise `append_notes_task`.

### The viewport helper — the load-bearing piece

Both the top input line and the in-place editor need to show a window over text
wider than the field, scrolled to keep the cursor cell visible. One method on
`TextInput` serves both:

```rust
/// The visible slice of the field for a box `width` columns wide, scrolled so
/// the cursor cell is always shown, plus the cursor's column within that slice.
/// `before`/`after` are split at the cursor; render as
/// `before` + block-cursor + `after`. Display-width aware (cursor is a byte
/// index; CJK/wide chars count as 2 columns).
pub fn window(&self, width: usize) -> TextWindow
struct TextWindow { before: String, after: String, cursor_col: usize }
```

Offset is *derived*, never stored:

```
before_w = display_width(text[..cursor])
offset_w = before_w.saturating_sub(width.saturating_sub(1))  // cursor in last col
```

`width.saturating_sub(1)`, not `width - 1`: `width` can be 0 in a narrow stacked
pane once padding, marker, and number columns are subtracted, and a bare
`width - 1` panics in debug at 0.

Then walk chars accumulating display width, **dropping every char whose left
edge is `< offset_w`** (so a wide char straddling the left boundary is dropped
whole, never rendered half-scrolled — keeping it would push visible content one
column past the box, the exact overflow the helper exists to prevent), and taking
chars until the box is full. No scroll state to hold or reset; recomputed each
frame from the cursor. `width` is the field's inner columns after padding and any
marker/number prefix. At `width == 0` the result is empty (cursor col 0), no
panic.

The top input line switches to `window()` too — it has silently clipped its
cursor past the pane edge all along.

### Rendering (`render_notes_pane`)

Layout is unchanged in shape: `block.inner(area)` split into input row (len 1),
rule row (len 1), list (min 0). Padding is applied per-region, not to the whole
block:

- **Input row / task rows:** inset one column each side. Concretely, render into
  a sub-rect with left/right margin 1 (or prefix a `" "` span and cap width to
  `inner - 2`). Column 0 and the last column stay blank on these rows.
- **Rule row:** unchanged, full inner width, so it touches both borders.

Each task renders on exactly one line:

```
<marker><N>. <body>
```

- `marker` = `▸ ` (gold) when highlighted/editing, else `  `.
- `N. ` number, upright, `p.comment` (or gold when active).
- `body`:
  - **not editing:** `truncate_cols(task, avail)` where `avail` is the row width
    minus padding, marker, and number; append `…` when truncated. `avail` uses
    display width.
  - **editing this row:** `window(avail)` → `before` + `█` (solid, `p.gold`) +
    `after`, with `before`/`after` styled `italic` `p.fg`. Marker and number are
    NOT italic.

`.wrap(...)` is removed from the list Paragraph; each `Line` is pre-fitted so the
backend clips nothing visible.

Input row content by state:

| state | input row |
|-------|-----------|
| `Input`, empty | `Tab to add a task…` (dim) |
| `Input`, typing | `window()` of `queue_input` + block cursor |
| `Editing` | `editing {N} · Enter saves · Esc cancels` (dim), N = `notes_selected + 1` |
| not focused | plain text or placeholder, as today |

### Keys

`handle_notes_list` (`app.rs`): `e` | `Enter` on a row →
`queue_input.set(task); notes_focus = Editing`. (`notes_selected` already points
at the row; no `editing` assignment.)

New `handle_notes_editing`:
- text editing keys (`Char`, `Backspace`, `Delete`, `Left`, `Right`, `Home`,
  `End`) → `queue_input`.
- `Enter` → commit. `submit_notes_input()` returns whether the write committed;
  **only on success** do we `notes_focus = List; queue_input.clear()`. On a write
  error the status message is set (as today) and we stay in `Editing` with the
  typed text intact — matching today's behaviour, where a failed
  `replace_notes_task` leaves the user in edit mode (`app.rs:1318-1321`). This
  requires `submit_notes_input` (and the `replace_notes_task`/`append_notes_task`
  it calls) to signal success up to the caller instead of returning bare
  `Action::None`.
- `Esc` → cancel: `queue_input.clear(); notes_focus = List`. Queue file untouched.
- `Up` | `Down` → ignored (single-line field).

`handle_notes_input` dispatch gains the `Editing` arm.
`handle_notes_input_field` loses its two `editing`-special-cases (the `Esc`
branch that checked `editing.is_some()`, and the `Down` guard) — it only ever
appends now.

`handle_mouse` (`app.rs:1628`): before any session switch (`ScrollUp`/`ScrollDown`
at `1634-1641`, left-click at `1665-1669`), if `notes_focus == Editing` cancel the
edit (`queue_input.clear(); notes_focus = List`). The click path already resets
`notes_selected = 0` on switch; the scroll path currently does not — it must, now
that a stale index could be a live edit target. Fold both into a single
"switch to session N" helper so the two paths cannot diverge again.

Footer (`ui.rs:620`): the `app.editing.is_some()` check becomes
`app.notes_focus == NotesFocus::Editing`. Text unchanged.

## Edge cases

- **Empty edit committed:** `submit_notes_input` already trims and no-ops on
  empty. An emptied edit + Enter leaves the task unchanged and exits edit mode.
  (Consistent with today; not a delete path.)
- **Cursor at end of a string longer than the field:** `offset_w` scrolls so the
  cursor sits in the last column; `before` is the tail, `after` empty.
- **Cursor at home on a long string:** `offset_w == 0`; `before` empty, `after`
  is the head truncated to fill the box.
- **Wide (CJK) characters straddling the box edge:** width accounting is by
  column, so a 2-column char that would half-cross the boundary is dropped whole,
  never split.
- **Very narrow pane** (`avail` 0 or 1): `window` returns at most the cursor
  cell; truncation returns `…` or empty. No panic — the offset uses
  `width.saturating_sub(1)` (see the viewport section; a bare `width - 1` would
  panic here in debug).
- **Keyboard selection under an edit:** entering `Editing` requires a highlighted
  task; keyboard keys all route to the notes handlers while the pane is focused
  (`app.rs:740-741`) and Up/Down are ignored, so no keyboard path moves
  `notes_selected` mid-edit. Mouse session-switch is handled by the cancel guard
  above.
- **External queue mutation mid-edit:** the Stop-hook drain or a `cs -queue` in
  another process can shorten `.cs/local/queue` while an edit is open. Committing
  then targets a line index that may no longer exist; `rewrite_queue_line`
  no-ops and returns `Ok` when the target is past the end (`app.rs:1717-1731`),
  so the UI reports success for a write that landed nowhere. This is pre-existing
  (today's `editing` index has the identical exposure) and out of scope here —
  noted so the "valid for the edit's lifetime" wording is not read as a guarantee.

## Testing (TDD, Rust)

Unit — `TextInput::window`:
- short text (fits): `before`+`after` == text, no scroll.
- cursor at end of long text: cursor in last column, tail visible.
- cursor at home of long text: head visible from column 0.
- CJK wide char at the boundary: dropped whole, visible width never exceeds
  `width`.
- `width == 0` and `width == 1`: no panic; ≤ 1 visible column. (Guards the
  formula's `saturating_sub` claim at the value where a bare `width - 1` would
  panic.)

State machine — `handle_notes_*`:
- `e` on row 2 → `notes_focus == Editing`, `queue_input` holds the task,
  `notes_selected == 1`.
- Enter commits: queue file line 2 replaced in place, `notes_focus == List`.
- Esc cancels: queue file unchanged, `notes_focus == List`.
- Up/Down while `Editing`: `notes_selected` unchanged, still `Editing`.
- mouse scroll / left-click on another session while `Editing`: edit cancelled
  (`notes_focus == List`), `notes_selected` valid for the new session, the queue
  file of the original session untouched.
- commit on a write error: `notes_focus` stays `Editing`, buffer intact, status
  set (drive by pointing the queue dir at a read-only path or a missing parent).
- (Rewrite the 3 existing edit tests' field assertions `editing == …` →
  `notes_focus == …`; behavioural assertions unchanged.)

Render — `TestBackend` buffer (read cell modifiers as the existing tests read
`cell.bg`, `ui.rs:1291`; follow the unique-session-name / env-isolation discipline
the current queue render-tests document, `ui.rs:1362-1390`, or they flake against
the `app.rs` queue tests):
- a task longer than the pane occupies one row and ends in `…`.
- while editing, the edited row's text cells carry `Modifier::ITALIC` and its
  number cells do not.
- column 0 is blank on a task row and non-blank on the rule row (padding proof).
- the top input line, given text wider than the pane with the cursor at the end,
  shows the tail with the block cursor on screen (covers build-order step 4 — the
  clipped-cursor bug that motivated the feature).

## Compatibility and constraints

- bash 3.2 / BSD userland: N/A (Rust only).
- `.cs/local/queue` format unchanged; `read_queue`, `rewrite_queue_line`, and the
  queue file contract are unchanged.
- `replace_notes_task` / `append_notes_task` change signature only: they now
  return whether the write committed (was implicit `Action::None`), so the
  `Editing` Enter arm can stay in edit mode on failure. Their queue-file effect is
  unchanged.
- Every writer of the deleted `editing` field must go — the field is removed:
  `app.rs:834` (Tab; provably `None` when reachable, harmless delete),
  `app.rs:889-897` (Esc special-case), `app.rs:966` (the `e`/Enter that set it),
  `app.rs:1306` (inside `replace_notes_task`). The doc comments at
  `app.rs:883-885` and `app.rs:1240-1241` describe `editing` semantics and must be
  reworded for the `NotesFocus::Editing` model.
- `queue_depth` sync path (`refresh_queue_depth`) unchanged.
- No rustfmt run (repo is not rustfmt-clean); match surrounding style.

## Verified assumptions

- List Paragraph uses `Wrap { trim: true }`; `trim` strips leading whitespace, so
  today's unhighlighted rows lose their 2-space marker to the border. Confirmed by
  a real pty render with a 161-char task.
- The top input line has no `.wrap()`/scroll and clips its cursor past the pane
  edge. Confirmed by source.
- Footer already prints `editing   Enter:save   Esc:cancel` (`ui.rs:621`).
- `unicode-width` is already a dependency; `TextInput.cursor` is a byte index and
  char-boundary safe.

## Build order

1. `TextInput::window` + unit tests (no UI change yet).
2. `NotesFocus::Editing`, delete `editing`, rewire key handlers + submit; adapt
   the 3 existing edit tests. (Behaviour identical, in-place still via top line.)
3. Move the editor onto the row in `render_notes_pane`: padding, no-wrap,
   truncation, italic window. Render tests.
4. Point the top input line at `window()` too.

## References

- `tui/src/ui.rs` `render_notes_pane`, footer key hints (~line 620).
- `tui/src/app.rs` `TextInput`, `handle_notes_*`, `submit_notes_input`,
  `NotesFocus`, `Focus`.
- Prior TUI work this session: render-path worker, layout dead band, narrative
  path (commit f11edb4).
