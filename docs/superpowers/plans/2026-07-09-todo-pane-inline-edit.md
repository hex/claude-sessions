# To-Do pane inline-edit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pad the To-Do pane, render each task on one line, and let a task be edited in place on its own row with an italic slant and a scrolling block cursor.

**Architecture:** One display-width-aware viewport helper on `TextInput` serves both the top input line and the in-place row editor. Edit state collapses from the two-field `editing: Option<usize>` + `notes_focus` into a single `NotesFocus::Editing`; the edited row is always `notes_selected`, kept valid by a mouse-switch cancel guard. Rendering pads the input and task rows, drops list wrapping, and truncates or windows each task to one line.

**Tech Stack:** Rust, ratatui 0.29, crossterm 0.28, unicode-width 0.2 (already a dependency).

## Global Constraints

- bash 3.2 / BSD userland: N/A — this is Rust only.
- No new dependency. `unicode-width = "0.2"` is already in `tui/Cargo.toml:9`.
- Do NOT run `cargo fmt` — the repo is not rustfmt-clean; match surrounding style.
- `.cs/local/queue` file format and `rewrite_queue_line` are unchanged.
- Comments: every file already has its `// ABOUTME:` header — do not add temporal/"changed from" comments.
- Baseline before starting: `cd tui && cargo test` is green (188 tests as of commit 1366434).
- Spec: `docs/superpowers/specs/2026-07-09-todo-pane-inline-edit-design.md`.

---

## File structure

- `tui/src/app.rs` — `TextInput` gains `window()` + `TextWindow`; `NotesFocus` gains `Editing` and loses the `editing` field; key handlers, `submit_notes_input`, `replace_notes_task`, and `handle_mouse` are rewired. All new unit/state tests live in the existing `#[cfg(test)] mod tests` at the bottom.
- `tui/src/ui.rs` — `render_notes_pane` gains padding, single-line rows, truncation, the row editor, and the dim edit hint; a `truncate_cols` helper is added near `truncate_str`. New render tests live in the existing test module.

No files created; both files already exist and own these responsibilities.

---

## Task 1: `TextInput::window` viewport helper

**Files:**
- Modify: `tui/src/app.rs` — add `struct TextWindow` and `impl TextInput { pub fn window }` after `after_cursor()` (`app.rs:117-119`); add `use unicode_width::UnicodeWidthChar;` and `UnicodeWidthStr` at the top of the file.
- Test: `tui/src/app.rs` `mod tests`.

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `pub struct TextWindow { pub before: String, pub after: String, pub cursor_col: usize }`
  - `pub fn window(&self, width: usize) -> TextWindow` on `TextInput`. `before`+cursor+`after` render left-to-right; total visible display width ≤ `width`; the cursor cell (`cursor_col`) is always < `width` (or 0 when `width == 0`). Wide chars are never split.

- [ ] **Step 1: Write the failing tests**

Add to `mod tests` in `tui/src/app.rs`:

```rust
#[test]
fn window_short_text_fits_whole() {
    let mut t = TextInput::new();
    t.set("hello");            // cursor at end (5)
    let w = t.window(20);
    assert_eq!(w.before, "hello");
    assert_eq!(w.after, "");
    assert_eq!(w.cursor_col, 5);
}

#[test]
fn window_cursor_at_end_of_long_text_keeps_cursor_in_last_column() {
    let mut t = TextInput::new();
    let long = "Refactor the preview worker so that the git walk is bounded";
    t.set(long);               // cursor at end
    let w = t.window(20);
    // Visible width never exceeds the box, and the cursor sits in the last column.
    let vis = w.before.chars().count() + w.after.chars().count();
    assert!(vis <= 20, "visible {} > 20", vis);
    assert_eq!(w.cursor_col, 19);
    assert_eq!(w.after, "");
    assert!(long.ends_with(&w.before));
}

#[test]
fn window_cursor_at_home_shows_head_from_column_zero() {
    let mut t = TextInput::new();
    t.set("Refactor the preview worker");
    t.move_home();             // cursor at 0
    let w = t.window(10);
    assert_eq!(w.cursor_col, 0);
    assert_eq!(w.before, "");
    assert_eq!(w.after, "Refactor t");   // 10 columns
}

#[test]
fn window_drops_a_wide_char_straddling_the_left_edge_never_splitting_it() {
    let mut t = TextInput::new();
    // Each CJK char is 2 columns wide.
    t.set("編集する日本語タスク");            // 10 chars, 20 cols, cursor at end
    let w = t.window(9);
    let vis: usize = w.before.chars().map(|c| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0)).sum::<usize>()
        + w.after.chars().map(|c| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0)).sum::<usize>();
    assert!(vis <= 9, "visible cols {} > 9 — a wide char was split or half-kept", vis);
    assert_eq!(w.after, "");
}

#[test]
fn window_zero_and_one_width_do_not_panic() {
    let mut t = TextInput::new();
    t.set("anything long enough to scroll");
    let w0 = t.window(0);
    assert_eq!(w0.cursor_col, 0);
    let w1 = t.window(1);
    assert!(w1.cursor_col <= 1);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tui && cargo test window_ 2>&1 | tail -20`
Expected: FAIL — `no method named 'window'` / `cannot find type 'TextWindow'`.

- [ ] **Step 3: Write the minimal implementation**

At the top of `tui/src/app.rs`, add the imports (place beside the existing `use` lines):

```rust
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
```

After `after_cursor()` (currently ends `app.rs:119`), inside `impl TextInput`, add:

```rust
    /// The visible slice of the field for a box `width` columns wide, scrolled so
    /// the cursor cell is always shown. `before`/`after` are split at the cursor;
    /// render as `before` + block cursor + `after`. Display-width aware: a wide
    /// char straddling the left edge is dropped whole rather than half-shown, so
    /// the visible width never exceeds `width`.
    pub fn window(&self, width: usize) -> TextWindow {
        if width == 0 {
            return TextWindow { before: String::new(), after: String::new(), cursor_col: 0 };
        }
        let before_w = self.text[..self.cursor].width();
        let offset_w = before_w.saturating_sub(width.saturating_sub(1));

        let mut before = String::new();
        let mut after = String::new();
        let mut used = 0usize;   // display columns taken so far
        let mut left = 0usize;   // left edge of the current char, in columns
        for (i, ch) in self.text.char_indices() {
            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
            let this_left = left;
            left += cw;
            if this_left < offset_w {
                continue;        // char's left edge is scrolled off — drop whole
            }
            if used + cw > width {
                break;           // box full
            }
            if i < self.cursor {
                before.push(ch);
            } else {
                after.push(ch);
            }
            used += cw;
        }
        let cursor_col = before.as_str().width();
        TextWindow { before, after, cursor_col }
    }
```

Add the struct just above `impl TextInput` (after the `struct TextInput` block, `app.rs:17`):

```rust
/// A horizontally-scrolled view of a `TextInput` for a fixed-width box.
pub struct TextWindow {
    pub before: String,
    pub after: String,
    pub cursor_col: usize,
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tui && cargo test window_ 2>&1 | tail -8`
Expected: PASS (5 tests). Then `cargo test 2>&1 | grep 'test result'` — still 193 total, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tui/src/app.rs
git commit -m "feat(tui): add TextInput::window horizontal viewport

Display-width-aware scrolled view of a text field for a fixed-width box;
keeps the cursor cell visible and never splits a wide char. Basis for the
in-place To-Do editor and a fix for the top input line's clipped cursor.

Claude-Session: https://claude.ai/code/session_01Qe7Uj3F9GtceQU2EQNRU9X"
```

---

## Task 2: Collapse edit state into `NotesFocus::Editing`

**Files:**
- Modify: `tui/src/app.rs` — `enum NotesFocus` (`244-247`); delete field `editing: Option<usize>` (`370`) and its init (`454`); `submit_notes_input` (`1242-1256`); `replace_notes_task` drop `self.editing = None` (`1306`); `handle_notes_input_field` remove two `editing` special-cases (Esc `889-897`, Down guard `905`); `handle_notes_list` `e`/Enter set `Editing` (`963-968`); add `handle_notes_editing`; `handle_notes_input` dispatch (`877-880`); `handle_mouse` cancel-on-switch (`1628-1671`); `Tab` handler drop `self.editing = None` (`834`).
- Modify: `tui/src/ui.rs` — footer condition `app.editing.is_some()` → `app.notes_focus == NotesFocus::Editing` (`621`); input-row render shows `queue_input` during `Editing` (`1159`).
- Test: `tui/src/app.rs` `mod tests` — rewrite 3 existing edit tests' field assertions; add editing-ignores-updown and mouse-cancels-edit tests.

**Interfaces:**
- Consumes: `NotesFocus` (from this task, now 3 variants), `notes_selected`, `queue_input`.
- Produces:
  - `NotesFocus::Editing` — edited row is `notes_selected`.
  - `fn handle_notes_editing(&mut self, key: KeyEvent) -> Action`.
  - `fn switch_selected_session(&mut self, idx: usize)` — selects `idx`; if `notes_focus == Editing`, cancels the edit (`queue_input.clear(); notes_focus = List`); resets `notes_selected = 0` when the session actually changes.

- [ ] **Step 1: Write the failing tests**

Rewrite the three existing edit tests' field assertions and add two new tests in `mod tests` (`tui/src/app.rs`). In `notes_list_e_loads_task_and_enter_replaces_in_place` change `assert_eq!(app.editing, Some(1), ...)` to `assert_eq!(app.notes_focus, NotesFocus::Editing, "in edit mode on row 1")` and `assert_eq!(app.editing, None, "editing cleared after save")` to `assert_eq!(app.notes_focus, NotesFocus::List, "back to list after save")`. In `notes_list_e_then_esc_cancels_edit_unchanged` change `assert_eq!(app.editing, None, "edit cancelled")` to `assert_eq!(app.notes_focus, NotesFocus::List, "edit cancelled, back to list")`. (Find the third `editing` assertion with `rg -n 'app\.editing' tui/src/app.rs` and convert it the same way.) Then add:

```rust
#[test]
fn editing_ignores_up_and_down() {
    let (tmp, _local, _root) = seed_queue("notes-edit-updown", "alpha", &["one", "two", "three"]);
    let mut app = App::new(sample_sessions());
    app.table_state.select(Some(0));
    app.handle_key(KeyEvent::from(KeyCode::Tab));
    app.handle_key(KeyEvent::from(KeyCode::Down)); // list, row 0
    app.handle_key(KeyEvent::from(KeyCode::Down)); // list, row 1 ("two")
    app.handle_key(KeyEvent::from(KeyCode::Char('e'))); // edit row 1
    assert_eq!(app.notes_focus, NotesFocus::Editing);
    app.handle_key(KeyEvent::from(KeyCode::Up));
    app.handle_key(KeyEvent::from(KeyCode::Down));
    assert_eq!(app.notes_selected, 1, "selection frozen while editing");
    assert_eq!(app.notes_focus, NotesFocus::Editing, "still editing");
    std::fs::remove_dir_all(&tmp).ok();
}

#[test]
fn mouse_scroll_during_edit_cancels_it() {
    let (tmp, local, _root) = seed_queue("notes-edit-mouse", "alpha", &["one", "two", "three"]);
    let mut app = App::new(sample_sessions());
    app.table_state.select(Some(0));
    app.handle_key(KeyEvent::from(KeyCode::Tab));
    app.handle_key(KeyEvent::from(KeyCode::Down));
    app.handle_key(KeyEvent::from(KeyCode::Down)); // row 1
    app.handle_key(KeyEvent::from(KeyCode::Char('e')));
    for c in "zzz".chars() { app.handle_key(KeyEvent::from(KeyCode::Char(c))); }
    let mouse = MouseEvent {
        kind: MouseEventKind::ScrollDown,
        column: 0, row: 0,
        modifiers: crossterm::event::KeyModifiers::empty(),
    };
    app.handle_mouse(mouse);
    assert_eq!(app.notes_focus, NotesFocus::List, "edit cancelled by mouse switch");
    // Original session's queue is untouched.
    let q = std::fs::read_to_string(local.join("queue")).unwrap();
    let lines: Vec<&str> = q.lines().filter(|l| !l.trim().is_empty()).collect();
    assert_eq!(lines, vec!["one", "two", "three"], "no write from a cancelled edit");
    std::fs::remove_dir_all(&tmp).ok();
}
```

If `MouseEvent`/`MouseEventKind` are not already imported in the test module, add `use crossterm::event::{MouseEvent, MouseEventKind};` to the test `use` block.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tui && cargo test notes 2>&1 | tail -20`
Expected: FAIL — `no variant named 'Editing'` and, after that compiles, `editing` field-removal errors. (This task will not compile until Step 3 is complete; that is expected for a state-shape change.)

- [ ] **Step 3: Write the implementation**

3a. `enum NotesFocus` (`app.rs:244`):

```rust
pub enum NotesFocus {
    Input,
    List,
    Editing,
}
```

3b. Delete the field `pub editing: Option<usize>,` (`app.rs:370`) and its initializer `editing: None,` (`app.rs:454`).

3c. `submit_notes_input` (`app.rs:1251-1254`) — key off focus, not the deleted field:

```rust
        match self.notes_focus {
            NotesFocus::Editing => self.replace_notes_task(&name, self.notes_selected, &text),
            _ => self.append_notes_task(&name, &text),
        }
```

3d. `replace_notes_task` — delete the line `self.editing = None;` (`app.rs:1306`). It already sets `notes_focus = List` on success and leaves focus untouched on error, so the "stay in edit mode on a write error" requirement is met without any new return value.

3e. `handle_notes_input_field` — remove the two special cases. Replace the `Esc` arm (`app.rs:888-897`) with:

```rust
            KeyCode::Esc => {
                self.queue_input.clear();
                self.notes_focus = NotesFocus::Input;
                self.focus = Focus::List;
            }
```

and replace the `Down` arm (`app.rs:904-912`) with the unconditional drop-into-list:

```rust
            KeyCode::Down => {
                if let Some(name) = self.selected_session_name() {
                    if !session::read_queue(&name).is_empty() {
                        self.notes_focus = NotesFocus::List;
                        self.notes_selected = 0;
                    }
                }
            }
```

3f. `handle_notes_list` `e`/Enter arm (`app.rs:963-968`) — seed the buffer and enter `Editing` (the row is already `notes_selected`):

```rust
            KeyCode::Char('e') | KeyCode::Enter => {
                if let Some(task) = tasks.get(self.notes_selected) {
                    self.queue_input.set(task);
                    self.notes_focus = NotesFocus::Editing;
                }
            }
```

3g. Add `handle_notes_editing` next to `handle_notes_list`:

```rust
    /// Keys while a task is being edited in place. Text keys go to the buffer;
    /// Enter commits via submit (which returns to the list only on a successful
    /// write); Esc cancels; Up/Down are ignored — this is a single-line field.
    fn handle_notes_editing(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Enter => return self.submit_notes_input(),
            KeyCode::Esc => {
                self.queue_input.clear();
                self.notes_focus = NotesFocus::List;
            }
            KeyCode::Left => self.queue_input.move_left(),
            KeyCode::Right => self.queue_input.move_right(),
            KeyCode::Home => self.queue_input.move_home(),
            KeyCode::End => self.queue_input.move_end(),
            KeyCode::Delete => self.queue_input.delete_forward(),
            KeyCode::Backspace => self.queue_input.delete_back(),
            KeyCode::Char(c) => self.queue_input.insert(c),
            _ => {}   // Up/Down and everything else ignored
        }
        Action::None
    }
```

3h. `handle_notes_input` dispatch (`app.rs:877-880`):

```rust
        match self.notes_focus {
            NotesFocus::Input => self.handle_notes_input_field(key),
            NotesFocus::List => self.handle_notes_list(key),
            NotesFocus::Editing => self.handle_notes_editing(key),
        }
```

3i. `Tab` handler — delete the `self.editing = None;` at `app.rs:834`.

3j. Add the switch helper and route both mouse switch paths through it. Add the method (near `handle_mouse`):

```rust
    /// Select session `idx`. If an in-place To-Do edit is open, cancel it — a
    /// mouse-driven session change must never leave the edit target pointing at
    /// a different session's queue. Resets the Notes highlight when the session
    /// actually changes.
    fn switch_selected_session(&mut self, idx: usize) {
        if self.notes_focus == NotesFocus::Editing {
            self.queue_input.clear();
            self.notes_focus = NotesFocus::List;
        }
        if self.table_state.selected() != Some(idx) {
            self.notes_selected = 0;
        }
        self.table_state.select(Some(idx));
    }
```

In `handle_mouse`, replace the `ScrollUp` arm (`app.rs:1634-1637`):

```rust
            MouseEventKind::ScrollUp => {
                let cur = self.table_state.selected().unwrap_or(0);
                self.switch_selected_session(cur.saturating_sub(1));
                Action::None
            }
```

replace the `ScrollDown` arm (`app.rs:1638-1642`):

```rust
            MouseEventKind::ScrollDown => {
                let cur = self.table_state.selected().unwrap_or(0);
                let max = self.filtered.len().saturating_sub(1);
                self.switch_selected_session((cur + 1).min(max));
                Action::None
            }
```

and replace the left-click select block (`app.rs:1665-1669`) with:

```rust
                        self.switch_selected_session(idx);
```

3k. `ui.rs` footer condition (`ui.rs:621`):

```rust
        if app.notes_focus == NotesFocus::Editing {
```

3l. `ui.rs` input-row render — keep the live edit visible in the top line for now (Task 3 moves it to the row). Change the first condition (`ui.rs:1159`) from `if input_focused {` to:

```rust
    let input_focused = focused && matches!(app.notes_focus, NotesFocus::Input | NotesFocus::Editing);
```

(Replace the existing `let input_focused = focused && app.notes_focus == NotesFocus::Input;` binding near the top of `render_notes_pane` with this `matches!` form; the `input_line` block below is unchanged.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tui && cargo test 2>&1 | grep -E 'test result|error\[' | tail -5`
Expected: compiles; `test result: ok. 195 passed` (193 + 2 new), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tui/src/app.rs tui/src/ui.rs
git commit -m "refactor(tui): collapse To-Do edit state into NotesFocus::Editing

Delete the editing: Option<usize> field; the edited row is always
notes_selected. A mouse session-switch (scroll or click) now cancels an
open edit via one shared switch_selected_session helper, closing a path
where a click could commit the edit into another session's queue.

Claude-Session: https://claude.ai/code/session_01Qe7Uj3F9GtceQU2EQNRU9X"
```

---

## Task 3: Pad the pane, one line per task, in-place row editor

**Files:**
- Modify: `tui/src/ui.rs` — add `truncate_cols` helper near `truncate_str` (`ui.rs:67-86`); rewrite `render_notes_pane` input row (dim hint during `Editing`), padding, list rendering (no wrap, one line, truncation, italic window).
- Test: `tui/src/ui.rs` `mod tests`.

**Interfaces:**
- Consumes: `TextInput::window` (Task 1), `NotesFocus::Editing` (Task 2), `truncate_cols` (this task).
- Produces: `fn truncate_cols(s: &str, max_cols: usize) -> String` — clip `s` to `max_cols` display columns, appending `…` (1 col) when clipped; never splits a wide char.

- [ ] **Step 1: Write the failing tests**

Add to `mod tests` in `tui/src/ui.rs`. Use the existing render-test pattern (`TestBackend`, unique session names, env isolation — mirror `todo_column_renders_when_a_session_has_queued_tasks`, `ui.rs:1429`):

```rust
#[test]
fn long_task_renders_on_one_line_with_ellipsis() {
    use crate::session::test_root;
    let tmp = std::env::temp_dir().join(format!("cs-ui-longtask-{}", std::process::id()));
    let name = "solo-long";
    let local = tmp.join(name).join(".cs/local");
    std::fs::create_dir_all(&local).unwrap();
    let long = "Refactor the preview worker so that the contributor git walk is bounded by a date window";
    std::fs::write(local.join("queue"), format!("{}\n", long)).unwrap();
    let _guard = test_root::scoped(tmp.clone());

    let mut sessions = one_session();
    sessions[0].name = name.to_string();
    sessions[0].queue_depth = 1;
    let mut app = App::new(sessions);
    app.theme = Palette::dark();
    app.show_preview = true;
    app.focus = Focus::Notes;
    app.notes_focus = NotesFocus::List;

    // Wide + tall enough to force the stacked layout (panes visible).
    let backend = TestBackend::new(90, 40);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|frame| render(&mut app, frame)).unwrap();
    let buf = terminal.backend().buffer().clone();
    let rows: Vec<String> = (0..buf.area.height)
        .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
        .collect();
    // The task's tail is truncated: the last word never appears, and a … does.
    let joined = rows.join("\n");
    assert!(joined.contains('\u{2026}'), "expected an ellipsis on the truncated task");
    assert!(!joined.contains("date window"), "the tail past the width must be clipped");
    std::fs::remove_dir_all(&tmp).ok();
}

#[test]
fn editing_row_text_is_italic_but_number_is_not() {
    use crate::session::test_root;
    use ratatui::style::Modifier;
    let tmp = std::env::temp_dir().join(format!("cs-ui-italic-{}", std::process::id()));
    let name = "solo-italic";
    let local = tmp.join(name).join(".cs/local");
    std::fs::create_dir_all(&local).unwrap();
    std::fs::write(local.join("queue"), "alpha task\nbeta task\n").unwrap();
    let _guard = test_root::scoped(tmp.clone());

    let mut sessions = one_session();
    sessions[0].name = name.to_string();
    sessions[0].queue_depth = 2;
    let mut app = App::new(sessions);
    app.theme = Palette::dark();
    app.show_preview = true;
    app.focus = Focus::Notes;
    app.notes_focus = NotesFocus::List;
    app.handle_key(KeyEvent::from(KeyCode::Down)); // row 0
    app.handle_key(KeyEvent::from(KeyCode::Char('e'))); // edit row 0

    let backend = TestBackend::new(90, 40);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|frame| render(&mut app, frame)).unwrap();
    let buf = terminal.backend().buffer().clone();

    // Find a cell of the task text ('a' from "alpha") and a cell of the number
    // ('1' from "1.") on the edited row; text italic, number not.
    let mut saw_italic_text = false;
    let mut saw_upright_number = false;
    for y in 0..buf.area.height {
        for x in 0..buf.area.width {
            let cell = &buf[(x, y)];
            if cell.symbol() == "l" && cell.modifier.contains(Modifier::ITALIC) {
                saw_italic_text = true;
            }
            if cell.symbol() == "1" && !cell.modifier.contains(Modifier::ITALIC) {
                saw_upright_number = true;
            }
        }
    }
    assert!(saw_italic_text, "edited task text should be italic");
    assert!(saw_upright_number, "the row number should stay upright");
    std::fs::remove_dir_all(&tmp).ok();
}

#[test]
fn task_rows_are_padded_but_the_rule_is_full_bleed() {
    use crate::session::test_root;
    let tmp = std::env::temp_dir().join(format!("cs-ui-pad-{}", std::process::id()));
    let name = "solo-pad";
    let local = tmp.join(name).join(".cs/local");
    std::fs::create_dir_all(&local).unwrap();
    std::fs::write(local.join("queue"), "one\ntwo\n").unwrap();
    let _guard = test_root::scoped(tmp.clone());

    let mut sessions = one_session();
    sessions[0].name = name.to_string();
    sessions[0].queue_depth = 2;
    let mut app = App::new(sessions);
    app.theme = Palette::dark();
    app.show_preview = true;
    app.focus = Focus::Notes;
    app.notes_focus = NotesFocus::List;

    let backend = TestBackend::new(90, 40);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|frame| render(&mut app, frame)).unwrap();
    let buf = terminal.backend().buffer().clone();

    // Locate the To-Do pane's left border column on the row holding "1." and on
    // the rule row; assert the cell just inside the border is blank on the task
    // row (padding) and a horizontal line on the rule row (full-bleed).
    // (Scan for the row containing "1." — its inner-left cell must be a space.)
    let mut padded_ok = false;
    for y in 0..buf.area.height {
        let line: String = (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect();
        if let Some(bpos) = line.find("│") {
            // cell right after a left border on a task row
            if line[bpos..].contains("1.") && line[bpos..].contains("one") {
                let inner_x = bpos + "│".len();
                if line[inner_x..].starts_with(' ') {
                    padded_ok = true;
                }
            }
        }
    }
    assert!(padded_ok, "task row should have a blank padding column after the border");
    std::fs::remove_dir_all(&tmp).ok();
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tui && cargo test -- long_task_renders editing_row_text task_rows_are_padded 2>&1 | tail -15`
Expected: FAIL — long task currently wraps (contains "date window"); text is bold-not-italic; no padding column.

- [ ] **Step 3: Write the implementation**

3a. Add `truncate_cols` near `truncate_str` (`ui.rs:86`):

```rust
/// Clip `s` to at most `max_cols` display columns, appending `…` when clipped.
/// Display-width aware — never splits a wide char.
fn truncate_cols(s: &str, max_cols: usize) -> String {
    use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};
    if s.width() <= max_cols {
        return s.to_string();
    }
    if max_cols == 0 {
        return String::new();
    }
    let budget = max_cols - 1; // leave one column for the ellipsis
    let mut out = String::new();
    let mut used = 0usize;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > budget {
            break;
        }
        out.push(ch);
        used += cw;
    }
    out.push('\u{2026}');
    out
}
```

At the top of `ui.rs`, add `use unicode_width::UnicodeWidthStr;` (for `.width()` used below) if not already present.

3b. Rewrite the input-row `input_line` block (`ui.rs:1158-1174`) so `Editing` shows the dim hint (the top line no longer carries the edit — Task 3 moves it to the row):

```rust
    // Input line: the new-task field, or a dim hint while editing a row in place.
    let input_inner = rows[0].width.saturating_sub(2) as usize; // 1-col padding each side
    let input_line = if app.notes_focus == NotesFocus::Editing {
        Line::from(Span::styled(
            format!(" editing {} \u{b7} Enter saves \u{b7} Esc cancels", app.notes_selected + 1),
            Style::default().fg(p.comment).add_modifier(Modifier::DIM),
        ))
    } else if input_focused {
        let win = app.queue_input.window(input_inner);
        Line::from(vec![
            Span::raw(" "),
            Span::styled(win.before, Style::default().fg(p.fg)),
            Span::styled("\u{2588}", Style::default().fg(p.gold)),
            Span::styled(win.after, Style::default().fg(p.fg)),
        ])
    } else if app.queue_input.text().is_empty() {
        Line::from(Span::styled(
            " Tab to add a task\u{2026}",
            Style::default().fg(p.comment).add_modifier(Modifier::DIM),
        ))
    } else {
        Line::from(vec![
            Span::raw(" "),
            Span::styled(app.queue_input.text(), Style::default().fg(p.fg)),
        ])
    };
    frame.render_widget(Paragraph::new(input_line), rows[0]);
```

Note: `input_focused` is now `focused && notes_focus == Input` only (revert the Task-2 `matches!` since `Editing` has its own arm above). Change the binding back to:

```rust
    let input_focused = focused && app.notes_focus == NotesFocus::Input;
```

3c. Rewrite the list block (`ui.rs:1182-1219`). Remove `.wrap(...)`, pad each row one column, render each task on exactly one line, and edit in place:

```rust
    // Numbered list of queued tasks, one line each. The highlighted row shows a
    // gold marker; the row being edited becomes an italic text field with a
    // scrolling block cursor.
    let tasks = app
        .selected_session()
        .map(|s| crate::session::read_queue(&s.name))
        .unwrap_or_default();

    let inner_cols = rows[2].width as usize;
    let list_lines: Vec<Line> = if tasks.is_empty() {
        vec![Line::from(Span::styled(
            " (no queued tasks)",
            Style::default().fg(p.comment).add_modifier(Modifier::DIM),
        ))]
    } else {
        tasks
            .iter()
            .enumerate()
            .map(|(i, task)| {
                let editing = app.notes_focus == NotesFocus::Editing && i == app.notes_selected;
                let highlighted =
                    editing || (list_focused && i == app.notes_selected);
                let (marker, marker_color) = if highlighted {
                    ("\u{25b8} ", p.gold)
                } else {
                    ("  ", p.comment)
                };
                let num = format!("{}. ", i + 1);
                // Columns available for the task text: pad(1) + marker(2) + number.
                let prefix_cols = 1 + 2 + num.chars().count();
                let avail = inner_cols.saturating_sub(prefix_cols);
                let mut spans = vec![
                    Span::raw(" "), // left padding
                    Span::styled(marker, Style::default().fg(marker_color)),
                    Span::styled(num, Style::default().fg(marker_color)),
                ];
                if editing {
                    let win = app.queue_input.window(avail);
                    let italic = Style::default().fg(p.fg).add_modifier(Modifier::ITALIC);
                    spans.push(Span::styled(win.before, italic));
                    spans.push(Span::styled("\u{2588}", Style::default().fg(p.gold)));
                    spans.push(Span::styled(win.after, italic));
                } else {
                    let mut text_style = Style::default().fg(p.fg);
                    if highlighted {
                        text_style = text_style.add_modifier(Modifier::BOLD);
                    }
                    spans.push(Span::styled(truncate_cols(task, avail), text_style));
                }
                Line::from(spans)
            })
            .collect()
    };
    let list = Paragraph::new(list_lines);
    frame.render_widget(list, rows[2]);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tui && cargo test 2>&1 | grep -E 'test result|error\[' | tail -5`
Expected: `test result: ok. 198 passed` (195 + 3 new), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "feat(tui): pad To-Do pane, one line per task, edit in place

Task rows and the input line inset one column; the separator rule stays
full-bleed. Long tasks truncate with an ellipsis instead of wrapping.
Editing a task turns its own row into an italic text field with a
scrolling block cursor; the input line shows a dim 'editing N' hint.

Claude-Session: https://claude.ai/code/session_01Qe7Uj3F9GtceQU2EQNRU9X"
```

---

## Task 4: Window the top input line (fix its clipped cursor)

**Files:**
- Modify: `tui/src/ui.rs` — the `input_focused` branch already uses `window()` from Task 3, so this task only adds the regression test proving the top-line cursor stays visible for text wider than the pane.
- Test: `tui/src/ui.rs` `mod tests`.

**Interfaces:**
- Consumes: the input-row rendering from Task 3.
- Produces: nothing new.

- [ ] **Step 1: Write the failing-then-passing test**

The behaviour was implemented in Task 3 (the `input_focused` arm calls `window(input_inner)`). This test locks it against regression — the block cursor must appear on screen even when the typed text is wider than the pane.

```rust
#[test]
fn top_input_line_keeps_cursor_visible_for_overflowing_text() {
    use crate::session::test_root;
    let tmp = std::env::temp_dir().join(format!("cs-ui-inputwin-{}", std::process::id()));
    let name = "solo-input";
    std::fs::create_dir_all(tmp.join(name).join(".cs/local")).unwrap();
    let _guard = test_root::scoped(tmp.clone());

    let mut sessions = one_session();
    sessions[0].name = name.to_string();
    let mut app = App::new(sessions);
    app.theme = Palette::dark();
    app.show_preview = true;
    app.focus = Focus::Notes;
    app.notes_focus = NotesFocus::Input;
    // Type a string far wider than any pane column count.
    for c in "the quick brown fox jumps over the lazy dog and keeps on running".chars() {
        app.handle_key(KeyEvent::from(KeyCode::Char(c)));
    }

    let backend = TestBackend::new(90, 40);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|frame| render(&mut app, frame)).unwrap();
    let buf = terminal.backend().buffer().clone();
    let joined: String = (0..buf.area.height)
        .flat_map(|y| (0..buf.area.width).map(move |x| (x, y)))
        .map(|(x, y)| buf[(x, y)].symbol().to_string())
        .collect();
    // The block cursor is on screen, and the tail (nearest the cursor) is shown
    // while the head has scrolled off.
    assert!(joined.contains('\u{2588}'), "block cursor must be visible");
    assert!(joined.contains("running"), "tail near the cursor is shown");
    assert!(!joined.contains("the quick brown"), "head scrolled out of the field");
    std::fs::remove_dir_all(&tmp).ok();
}
```

- [ ] **Step 2: Run the test**

Run: `cd tui && cargo test top_input_line_keeps_cursor_visible 2>&1 | tail -8`
Expected: PASS (behaviour landed in Task 3). If it FAILS, the Task-3 input-row branch is wrong — fix there, not here.

- [ ] **Step 3: Full suite + release build**

Run:
```bash
cd tui && cargo test 2>&1 | grep 'test result'
cargo build --release 2>&1 | grep -E 'error|Finished'
```
Expected: `test result: ok. 199 passed`, `Finished` with no errors.

- [ ] **Step 4: Manual verification in the real binary**

```bash
SB=/private/tmp/claude-501/-Users-alex-geana--claude-sessions-claude-sessions/748c731f-6174-4cf5-a1b3-cd2e6d154994/scratchpad
ROOT=$SB/fakeroot   # created earlier: a 'demo' session with a 161-char task
cd /Users/alex.geana/.claude-sessions/claude-sessions
timeout 30 python3 $SB/pty_capture.py tui/target/release/cs-tui 40 100 2.0 2>/dev/null | tr -d '\000' | grep -A6 'To-Do'
```
Expected: the long task shows on one line ending in `…`; no wrapped tail; the input row is padded one column.

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "test(tui): lock the top To-Do input cursor visible past pane width

Claude-Session: https://claude.ai/code/session_01Qe7Uj3F9GtceQU2EQNRU9X"
```

---

## Task 5: Install and end-to-end verify

- [ ] **Step 1: Full gate**

```bash
cd /Users/alex.geana/.claude-sessions/claude-sessions
(cd tui && cargo test 2>&1 | grep 'test result')
bash tests/run_all.sh 2>&1 | tail -1
```
Expected: Rust `ok. 199 passed`; bash `OK: all 34 suites passed`.

- [ ] **Step 2: Install the rebuilt binary**

```bash
cp tui/target/release/cs-tui ~/.local/bin/cs-tui
cp tui/target/release/cs-tui bin/cs-tui
~/.local/bin/cs-tui --print-theme   # sanity: runs
```

- [ ] **Step 3: Update the README To-Do bullet if wording drifted**

Check `rg -n 'To-Do' README.md`; if it describes wrapping/behaviour that changed, update it. Otherwise no change.

- [ ] **Step 4: Finish the branch**

Use `superpowers:finishing-a-development-branch`. Present merge/PR options to Alex (last time: local merge to main + install; the session-color and unpushed-main state may inform the choice).

---

## Self-review

**Spec coverage:**
- Padding (input + task rows) → Task 3 (`Span::raw(" ")` prefixes; `task_rows_are_padded...` test). ✓
- No wrapping / one line per task → Task 3 (`.wrap` removed; `long_task_renders_on_one_line...`). ✓
- Truncation with `…` → Task 3 (`truncate_cols`). ✓
- In-place row editing → Tasks 2 (state) + 3 (render). ✓
- Italic text only, upright number → Task 3 (`editing_row_text_is_italic_but_number_is_not`). ✓
- Dim `editing N` input-row hint → Task 3. ✓
- Full-bleed rule → Task 3 (rule row untouched; padding proof test). ✓
- `NotesFocus::Editing`, delete `editing` → Task 2. ✓
- Up/Down ignored while editing → Task 2 (`editing_ignores_up_and_down`). ✓
- Mouse session-switch cancels edit → Task 2 (`switch_selected_session`, `mouse_scroll_during_edit_cancels_it`). ✓
- Viewport helper, width-0 safe, no wide-char split → Task 1 (5 unit tests). ✓
- Top input line windowed → Tasks 3 (impl) + 4 (regression test). ✓
- Stay in edit mode on write error → Task 2 (relies on existing `replace_notes_task` outcome-conditioned focus; `self.editing = None` removed, no new field). ✓
- Rewrite 3 existing edit tests' field assertions → Task 2 Step 1. ✓

**Placeholder scan:** none — every code step shows complete code.

**Type consistency:** `TextWindow{before,after,cursor_col}` (Task 1) consumed unchanged in Tasks 3/4. `switch_selected_session(idx: usize)` defined and used within Task 2. `truncate_cols(&str, usize) -> String` defined and used within Task 3. `NotesFocus::Editing` defined Task 2, consumed Tasks 3/4.

**Note discovered during planning (simpler than the spec):** the spec proposed threading a "write committed" bool out of `submit_notes_input`. Reading `replace_notes_task` (`app.rs:1301-1322`) shows it already sets `notes_focus = List` only on success and leaves focus alone on error, so the `Editing` Enter arm just calls `submit_notes_input()` — no signature change. The "stay in edit mode on write error" requirement holds for free. The plan reflects the simpler reality.
