// ABOUTME: Application state machine that processes keyboard input and manages UI modes
// ABOUTME: Tracks table selection, sort order, search filter, and modal dialog state

use std::collections::HashMap;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use ratatui::widgets::TableState;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::session::{self, Session};
use crate::theme::Palette;

/// Editable text buffer with cursor position tracking.
/// Cursor is stored as a byte offset, always on a char boundary.
pub struct TextInput {
    text: String,
    cursor: usize,
}

/// A horizontally-scrolled view of a `TextInput` for a fixed-width box.
pub struct TextWindow {
    pub before: String,
    pub after: String,
    pub cursor_col: usize,
}

impl TextInput {
    pub fn new() -> Self {
        TextInput {
            text: String::new(),
            cursor: 0,
        }
    }

    /// Replace text contents; cursor moves to end.
    pub fn set(&mut self, s: &str) {
        self.text = s.to_string();
        self.cursor = self.text.len();
    }

    /// Clear text and reset cursor.
    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
    }

    /// Insert a character at the cursor position and advance cursor.
    pub fn insert(&mut self, c: char) {
        self.text.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    /// Delete the character before the cursor (Backspace).
    pub fn delete_back(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = self.text[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        self.text.drain(prev..self.cursor);
        self.cursor = prev;
    }

    /// Delete the character at the cursor (Delete key).
    pub fn delete_forward(&mut self) {
        if self.cursor >= self.text.len() {
            return;
        }
        let next = self.text[self.cursor..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| self.cursor + i)
            .unwrap_or(self.text.len());
        self.text.drain(self.cursor..next);
    }

    /// Move cursor one character left.
    pub fn move_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        self.cursor = self.text[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    /// Move cursor one character right.
    pub fn move_right(&mut self) {
        if self.cursor >= self.text.len() {
            return;
        }
        self.cursor = self.text[self.cursor..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| self.cursor + i)
            .unwrap_or(self.text.len());
    }

    /// Move cursor to the beginning.
    pub fn move_home(&mut self) {
        self.cursor = 0;
    }

    /// Move cursor to the end.
    pub fn move_end(&mut self) {
        self.cursor = self.text.len();
    }

    /// Get the full text.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// Text before the cursor.
    pub fn before_cursor(&self) -> &str {
        &self.text[..self.cursor]
    }

    /// Text after the cursor.
    pub fn after_cursor(&self) -> &str {
        &self.text[self.cursor..]
    }

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
        let mut used = 0usize; // display columns taken so far
        let mut left = 0usize; // left edge of the current char, in columns
        for (i, ch) in self.text.char_indices() {
            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
            let this_left = left;
            left += cw;
            if this_left < offset_w {
                continue; // char's left edge is scrolled off — drop whole
            }
            if used + cw > width {
                break; // box full
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
}

/// Fuzzy-match `pattern` against `text` (case-insensitive).
/// Returns (score, matched_indices) or None if no match.
/// Indices refer to byte positions of matched characters in `text`.
pub fn fuzzy_match(pattern: &str, text: &str) -> Option<(i32, Vec<usize>)> {
    if pattern.is_empty() {
        return Some((0, vec![]));
    }

    let pattern_lower: Vec<char> = pattern.to_lowercase().chars().collect();
    let text_chars: Vec<(usize, char)> = text.char_indices().collect();

    let mut indices = Vec::with_capacity(pattern_lower.len());
    let mut ti = 0;

    for &pc in &pattern_lower {
        let mut found = false;
        // Lowercase each original char inline (first lowercase char) so the
        // index stays aligned with text_chars — a whole-string to_lowercase()
        // can change the char count and desync the two, panicking on index.
        while ti < text_chars.len() {
            let tc = text_chars[ti].1.to_lowercase().next().unwrap_or(text_chars[ti].1);
            if tc == pc {
                indices.push(text_chars[ti].0);
                ti += 1;
                found = true;
                break;
            }
            ti += 1;
        }
        if !found {
            return None;
        }
    }

    // Score the match
    let mut score: i32 = 0;

    // Bonus for matching first character
    if !indices.is_empty() && indices[0] == 0 {
        score += 10;
    }

    for (i, &byte_idx) in indices.iter().enumerate() {
        // Find the char index for this byte position
        let char_idx = text_chars.iter().position(|(bi, _)| *bi == byte_idx).unwrap();

        // Bonus for consecutive matches
        if i > 0 {
            let prev_char_idx = text_chars
                .iter()
                .position(|(bi, _)| *bi == indices[i - 1])
                .unwrap();
            if char_idx == prev_char_idx + 1 {
                score += 3;
            }
        }

        // Bonus for word boundary matches (after -, _, ., space, or start)
        if char_idx == 0
            || matches!(
                text_chars[char_idx - 1].1,
                '-' | '_' | '.' | ' '
            )
        {
            score += 5;
        }
    }

    Some((score, indices))
}

/// Whether a name is one the `cs` CLI would accept, mirroring bash
/// validate_session_name: non-empty, not "."/"..", and only ASCII
/// alphanumerics plus `-` `_` `.`. Keeps TUI-created/renamed sessions openable
/// by `cs` (Unicode letters or spaces would produce a dir cs rejects).
pub fn is_valid_session_name(name: &str) -> bool {
    if name.is_empty() || name == "." || name == ".." {
        return false;
    }
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortColumn {
    Name,
    Created,
    Modified,
    Secrets,
    Todo,
    Github,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortDirection {
    Asc,
    Desc,
}

#[derive(Debug, PartialEq)]
pub enum Mode {
    Normal,
    Search,
    SessionMenu,
    ConfirmDelete,
    ConfirmBatchDelete,
    ConfirmForceOpen,
    Rename,
    CreateSession,
    Secrets,
    CommandOutput(String),
}

/// Which panel receives keyboard input while in `Mode::Normal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    List,
    Notes,
}

/// Sub-focus within the Notes panel: the task input line, the task list, or
/// an in-place task edit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotesFocus {
    Input,
    List,
    Editing,
}

pub const MENU_ITEMS: &[(&str, &str)] = &[
    ("Open", "Enter"),
    ("Delete", "d"),
    ("Rename", "r"),
    ("Secrets", "s"),
];

pub enum Action {
    None,
    Quit,
    Open(String),
    ForceOpen(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusLevel {
    Success,
    Error,
    Info,
}

const STATUS_EXPIRE_SECS: u64 = 4;
const FLASH_DURATION_MS: u64 = 400;
const DELETE_COUNTDOWN_SECS: u64 = 2;
const PEEK_DURATION_SECS: u64 = 5;
/// After this long without input the selection shimmer pauses so the event loop
/// can block until the next key or mouse event, costing no CPU while unattended.
const IDLE_PAUSE_SECS: u64 = 30;

/// Classify a timestamp into a time section for grouping display.
fn time_section(ts: Option<std::time::SystemTime>) -> &'static str {
    let ts = match ts {
        Some(t) => t,
        None => return "Older",
    };
    let age = match std::time::SystemTime::now().duration_since(ts) {
        Ok(d) => d,
        Err(_) => return "Today", // future timestamp
    };
    let secs = age.as_secs();
    const HOUR: u64 = 3600;
    const DAY: u64 = 86400;
    if secs < DAY {
        "Today"
    } else if secs < 2 * DAY {
        "Yesterday"
    } else if secs < 7 * DAY {
        "This Week"
    } else if secs < 30 * DAY {
        "This Month"
    } else {
        "Older"
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlashKind {
    Success,
    Error,
}

pub struct StatusMessage {
    pub text: String,
    pub level: StatusLevel,
    pub set_at: std::time::Instant,
}

pub struct App {
    pub sessions: Vec<Session>,
    pub filtered: Vec<usize>,
    pub table_state: TableState,
    pub mode: Mode,
    pub sort_col: SortColumn,
    pub sort_dir: SortDirection,
    pub search_input: TextInput,
    pub rename_input: TextInput,
    pub create_input: TextInput,
    pub queue_input: TextInput,
    pub secrets_names: Vec<String>,
    pub secrets_selected: usize,
    pub return_to_secrets: bool,
    pub menu_selected: usize,
    pub status_message: Option<StatusMessage>,
    pub row_flashes: HashMap<String, (FlashKind, std::time::Instant)>,
    pub table_area: ratatui::layout::Rect,
    pub column_widths: Vec<u16>,
    /// Click hit-map for the visible table rows, published by the renderer since
    /// rows are variable height. Each entry is `(start_y, height, filtered_idx)`
    /// where `start_y`/`height` are rows relative to `table_area.y`.
    pub row_hit_spans: Vec<(u16, u16, usize)>,
    pub visible_sort_columns: Vec<SortColumn>,
    pub delete_countdown_start: Option<std::time::Instant>,
    /// Fuzzy match indices per session index (for highlighting matched chars in names).
    pub fuzzy_indices: HashMap<usize, Vec<usize>>,
    /// Revealed secret: (key_name, value, reveal_time). Auto-expires after PEEK_DURATION_SECS.
    pub revealed_secret: Option<(String, String, std::time::Instant)>,
    /// Section labels for time-based grouping (parallel to `filtered`).
    /// Each entry is Some("label") if this row starts a new time section, None otherwise.
    pub section_labels: Vec<Option<&'static str>>,
    /// Navigation repeat tracking: (last direction char, repeat count, last press time).
    nav_repeat: (char, usize, std::time::Instant),
    /// Sessions marked for batch operations (by name).
    pub marked_sessions: std::collections::HashSet<String>,
    /// Currently expanded session name (for Tab expand/collapse).
    pub expanded_session: Option<String>,
    /// Cached session previews (by session name).
    pub preview_cache: HashMap<String, session::SessionPreview>,
    /// Session names handed to the preview worker, awaiting a result. Guards
    /// against re-queueing the selected session on every frame.
    preview_pending: std::collections::HashSet<String>,
    /// Session names to load, drained by the preview worker.
    preview_requests: std::sync::mpsc::Sender<String>,
    /// Previews the worker has finished, drained once per event-loop tick.
    preview_results: std::sync::mpsc::Receiver<(String, session::SessionPreview)>,
    /// Whether to show the preview pane on wide terminals (toggled with `p`).
    pub show_preview: bool,
    /// Which panel receives keyboard input: the session list or the Notes input.
    pub focus: Focus,
    /// Sub-focus within the Notes panel (only meaningful while `focus == Notes`).
    pub notes_focus: NotesFocus,
    /// Highlighted task index while `notes_focus == List`.
    pub notes_selected: usize,
    /// Resolved color palette for the detected terminal background.
    pub theme: Palette,
    /// Sessions root captured once at construction. Reading it here instead of
    /// calling session::sessions_root() (a process-global env read) on every
    /// preview/create/delete keeps a test's env mutation from racing the reads.
    pub sessions_root: std::path::PathBuf,
    /// When the user last pressed a key or moved the mouse. The selection
    /// shimmer animates only while this is recent; after `IDLE_PAUSE_SECS` the
    /// event loop stops repainting and blocks until the next event.
    last_input: std::time::Instant,
}

/// Start the thread that reads session previews off the render path.
///
/// Loading a preview walks `.cs/` and shells out to `git log` for the
/// contributor list, which costs seconds on a repository with a long history —
/// far too long to sit inside a draw call, where it would stall the cursor
/// itself. The worker loads one session at a time and posts each result back;
/// the event loop picks them up on its next tick.
///
/// `root` is passed in already resolved: tests override the sessions root
/// through a thread-local, which a spawned thread would not see.
fn spawn_preview_worker(
    root: std::path::PathBuf,
) -> (
    std::sync::mpsc::Sender<String>,
    std::sync::mpsc::Receiver<(String, session::SessionPreview)>,
) {
    let (request_tx, request_rx) = std::sync::mpsc::channel::<String>();
    let (result_tx, result_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // Ends when the App drops its sender.
        for name in request_rx {
            let preview = session::load_preview(&root.join(&name));
            if result_tx.send((name, preview)).is_err() {
                break;
            }
        }
    });
    (request_tx, result_rx)
}

impl App {
    pub fn new(sessions: Vec<Session>) -> Self {
        let mut table_state = TableState::default();
        if !sessions.is_empty() {
            table_state.select(Some(0));
        }
        let sessions_root = session::sessions_root();
        let (preview_requests, preview_results) = spawn_preview_worker(sessions_root.clone());
        let mut app = App {
            sessions_root,
            sessions,
            filtered: Vec::new(),
            table_state,
            mode: Mode::Normal,
            table_area: ratatui::layout::Rect::default(),
            column_widths: Vec::new(),
            row_hit_spans: Vec::new(),
            sort_col: SortColumn::Modified,
            sort_dir: SortDirection::Desc,
            search_input: TextInput::new(),
            rename_input: TextInput::new(),
            create_input: TextInput::new(),
            queue_input: TextInput::new(),
            secrets_names: Vec::new(),
            secrets_selected: 0,
            return_to_secrets: false,
            menu_selected: 0,
            status_message: None,
            row_flashes: HashMap::new(),
            visible_sort_columns: Vec::new(),
            delete_countdown_start: None,
            fuzzy_indices: HashMap::new(),
            revealed_secret: None,
            section_labels: Vec::new(),
            nav_repeat: ('\0', 0, std::time::Instant::now()),
            marked_sessions: std::collections::HashSet::new(),
            expanded_session: None,
            preview_cache: HashMap::new(),
            preview_pending: std::collections::HashSet::new(),
            preview_requests,
            preview_results,
            show_preview: true,
            focus: Focus::List,
            notes_focus: NotesFocus::Input,
            notes_selected: 0,
            theme: Palette::dark(),
            last_input: std::time::Instant::now(),
        };
        // Apply the default sort (recency) so the initial view is ordered, not
        // just scan order. Also seeds section labels for the grouped view.
        app.apply_filter_and_sort();
        app
    }

    pub fn set_status(&mut self, text: impl Into<String>, level: StatusLevel) {
        self.status_message = Some(StatusMessage {
            text: text.into(),
            level,
            set_at: std::time::Instant::now(),
        });
    }

    /// Remove the status message if it has expired. Returns true if it was cleared.
    pub fn expire_status(&mut self) -> bool {
        if let Some(ref msg) = self.status_message {
            if msg.set_at.elapsed().as_secs() >= STATUS_EXPIRE_SECS {
                self.status_message = None;
                return true;
            }
        }
        false
    }

    pub fn flash_row(&mut self, name: impl Into<String>, kind: FlashKind) {
        self.row_flashes
            .insert(name.into(), (kind, std::time::Instant::now()));
    }

    /// Remove expired row flashes. Returns true if any were removed.
    pub fn expire_flashes(&mut self) -> bool {
        let before = self.row_flashes.len();
        self.row_flashes.retain(|_, (_, at)| {
            at.elapsed().as_millis() < FLASH_DURATION_MS as u128
        });
        self.row_flashes.len() < before
    }

    /// Get active flash for a session name, if any.
    pub fn active_flash(&self, name: &str) -> Option<FlashKind> {
        self.row_flashes.get(name).and_then(|(kind, at)| {
            if at.elapsed().as_millis() < FLASH_DURATION_MS as u128 {
                Some(*kind)
            } else {
                None
            }
        })
    }

    /// Seconds remaining on the delete confirmation countdown.
    /// Returns 0 when the countdown has elapsed and `y` should be accepted.
    pub fn delete_countdown_remaining(&self) -> u64 {
        match self.delete_countdown_start {
            Some(start) => {
                let elapsed = start.elapsed().as_secs();
                DELETE_COUNTDOWN_SECS.saturating_sub(elapsed)
            }
            None => 0,
        }
    }

    /// Expire the revealed secret after PEEK_DURATION_SECS.
    pub fn expire_peek(&mut self) -> bool {
        if let Some((_, _, ref at)) = self.revealed_secret {
            if at.elapsed().as_secs() >= PEEK_DURATION_SECS {
                self.revealed_secret = None;
                return true;
            }
        }
        false
    }

    /// Seconds remaining on the peek reveal countdown.
    pub fn peek_remaining(&self) -> u64 {
        match self.revealed_secret {
            Some((_, _, ref at)) => {
                PEEK_DURATION_SECS.saturating_sub(at.elapsed().as_secs())
            }
            None => 0,
        }
    }

    /// Whether any short-lived visual state still needs the animation heartbeat
    /// to advance or expire it: a status message, row flash, revealed secret,
    /// delete countdown, or an in-flight preview request. All are triggered by
    /// user input and clear within seconds, so they never keep the loop awake
    /// once the user walks away.
    pub fn has_timed_state(&self) -> bool {
        self.status_message.is_some()
            || !self.row_flashes.is_empty()
            || self.revealed_secret.is_some()
            || self.delete_countdown_start.is_some()
            || !self.preview_pending.is_empty()
    }

    /// Record that the user just interacted, restarting the idle timer.
    pub fn note_input(&mut self) {
        self.last_input = std::time::Instant::now();
    }

    /// Time since the last key press or mouse event.
    pub fn idle_elapsed(&self) -> std::time::Duration {
        self.last_input.elapsed()
    }

    /// Whether a row is selected, so a selection bar exists to shimmer.
    pub fn has_selection(&self) -> bool {
        self.table_state.selected().is_some()
    }

    /// Whether the event loop should keep ticking at the animation heartbeat.
    /// The selection shimmer animates while the user is recently active; timed
    /// state holds the heartbeat open until it clears. When neither applies the
    /// loop can block until the next event, so an idle TUI costs no CPU. `idle`
    /// is passed in rather than read from the clock so the decision is pure and
    /// unit-testable.
    pub fn is_animating(&self, idle: std::time::Duration) -> bool {
        let shimmer_active =
            self.has_selection() && idle < std::time::Duration::from_secs(IDLE_PAUSE_SECS);
        shimmer_active || self.has_timed_state()
    }

    /// Track a navigation key press and return the step size based on repeat velocity.
    fn nav_step(&mut self, direction: char) -> usize {
        const REPEAT_THRESHOLD_MS: u128 = 200;
        let now = std::time::Instant::now();
        let elapsed = now.duration_since(self.nav_repeat.2).as_millis();
        if self.nav_repeat.0 == direction && elapsed < REPEAT_THRESHOLD_MS {
            self.nav_repeat.1 += 1;
        } else {
            self.nav_repeat.1 = 1;
        }
        self.nav_repeat.0 = direction;
        self.nav_repeat.2 = now;
        match self.nav_repeat.1 {
            1..=3 => 1,
            4..=8 => 2,
            _ => 5,
        }
    }

    pub fn selected_session(&self) -> Option<&Session> {
        let idx = self.table_state.selected()?;
        let session_idx = *self.filtered.get(idx)?;
        self.sessions.get(session_idx)
    }

    pub fn selected_session_name(&self) -> Option<String> {
        self.selected_session().map(|s| s.name.clone())
    }

    /// Ask the worker for the selected session's preview, unless it is already
    /// cached or already queued. Never touches the filesystem on this thread.
    pub fn request_preview(&mut self) {
        let Some(name) = self.selected_session_name() else {
            return;
        };
        if self.preview_cache.contains_key(&name) || self.preview_pending.contains(&name) {
            return;
        }
        if self.preview_requests.send(name.clone()).is_ok() {
            self.preview_pending.insert(name);
        }
    }

    /// Move every preview the worker has finished into the cache.
    pub fn drain_previews(&mut self) {
        while let Ok((name, preview)) = self.preview_results.try_recv() {
            self.preview_pending.remove(&name);
            self.preview_cache.insert(name, preview);
        }
    }

    /// Block until every requested preview has landed in the cache.
    #[cfg(test)]
    fn wait_for_previews(&mut self) {
        while !self.preview_pending.is_empty() {
            match self.preview_results.recv() {
                Ok((name, preview)) => {
                    self.preview_pending.remove(&name);
                    self.preview_cache.insert(name, preview);
                }
                Err(_) => break,
            }
        }
    }

    /// Compute fuzzy match indices for highlighting without filtering the session list.
    /// Used during search typing phase to show all sessions with matches highlighted.
    pub fn update_search_highlights(&mut self) {
        let query = self.search_input.text();
        self.fuzzy_indices.clear();
        if !query.is_empty() {
            for (i, s) in self.sessions.iter().enumerate() {
                if let Some((_score, indices)) = fuzzy_match(query, &s.name) {
                    if !indices.is_empty() {
                        self.fuzzy_indices.insert(i, indices);
                    }
                }
            }
        }
    }

    pub fn apply_filter_and_sort(&mut self) {
        // Remember the selected session name so we can restore it after re-sorting
        let prev_name = self.selected_session().map(|s| s.name.clone());

        let query = self.search_input.text();
        self.fuzzy_indices.clear();

        if query.is_empty() {
            self.filtered = (0..self.sessions.len()).collect();
        } else {
            // Fuzzy match and collect (index, score, matched_indices)
            let mut matches: Vec<(usize, i32, Vec<usize>)> = self
                .sessions
                .iter()
                .enumerate()
                .filter_map(|(i, s)| {
                    fuzzy_match(query, &s.name).map(|(score, indices)| (i, score, indices))
                })
                .collect();

            // Sort by score descending (best matches first)
            matches.sort_by(|a, b| b.1.cmp(&a.1));

            self.filtered = matches.iter().map(|(i, _, _)| *i).collect();
            for (i, _, indices) in matches {
                if !indices.is_empty() {
                    self.fuzzy_indices.insert(i, indices);
                }
            }
        }

        // When not searching, apply column sort
        if query.is_empty() {
            let sessions = &self.sessions;
            let sort_col = self.sort_col;
            let sort_dir = self.sort_dir;
            self.filtered.sort_by(|&a, &b| {
                let sa = &sessions[a];
                let sb = &sessions[b];
                let ord = match sort_col {
                    SortColumn::Name => sa.name.to_lowercase().cmp(&sb.name.to_lowercase()),
                    SortColumn::Created => sa.created.cmp(&sb.created),
                    SortColumn::Modified => sa.modified.cmp(&sb.modified),
                    SortColumn::Secrets => sa.secrets_count.cmp(&sb.secrets_count),
                    SortColumn::Todo => sa.queue_depth.cmp(&sb.queue_depth),
                    SortColumn::Github => sa.git_repo.cmp(&sb.git_repo),
                };
                match sort_dir {
                    SortDirection::Asc => ord,
                    SortDirection::Desc => ord.reverse(),
                }
            });
        }

        // Compute section labels for time-based grouping
        self.section_labels.clear();
        let show_sections = matches!(self.sort_col, SortColumn::Created | SortColumn::Modified);
        if show_sections && !self.filtered.is_empty() {
            let mut prev_section = "";
            for &idx in &self.filtered {
                let ts = self.sessions[idx].modified_ts;
                let section = time_section(ts);
                if section != prev_section {
                    self.section_labels.push(Some(section));
                    prev_section = section;
                } else {
                    self.section_labels.push(None);
                }
            }
        }

        // Restore selection: find the previously selected session in the new order
        if self.filtered.is_empty() {
            self.table_state.select(None);
        } else if let Some(name) = prev_name {
            let new_pos = self
                .filtered
                .iter()
                .position(|&i| self.sessions[i].name == name);
            self.table_state.select(Some(new_pos.unwrap_or(0)));
        } else {
            self.table_state.select(Some(0));
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Action {
        // Ctrl+C always quits
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            return Action::Quit;
        }

        match &self.mode {
            Mode::Normal => self.handle_normal(key),
            Mode::Search => self.handle_search(key),
            Mode::SessionMenu => self.handle_session_menu(key),
            Mode::ConfirmDelete => self.handle_confirm_delete(key),
            Mode::ConfirmBatchDelete => self.handle_confirm_batch_delete(key),
            Mode::ConfirmForceOpen => self.handle_confirm_force_open(key),
            Mode::Rename => self.handle_rename(key),
            Mode::CreateSession => self.handle_create_session(key),
            Mode::Secrets => self.handle_secrets(key),
            Mode::CommandOutput(_) => {
                if self.return_to_secrets {
                    self.return_to_secrets = false;
                    if self.secrets_names.is_empty() {
                        self.mode = Mode::Normal;
                        self.set_status("No secrets remaining", StatusLevel::Info);
                    } else {
                        self.mode = Mode::Secrets;
                    }
                } else {
                    self.mode = Mode::Normal;
                }
                Action::None
            }
        }
    }

    fn handle_normal(&mut self, key: KeyEvent) -> Action {
        if self.focus == Focus::Notes {
            return self.handle_notes_input(key);
        }
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => Action::Quit,
            KeyCode::Enter => {
                if self.selected_session().is_some() {
                    self.menu_selected = 0;
                    self.mode = Mode::SessionMenu;
                }
                Action::None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.expanded_session = None;
                let step = self.nav_step('j');
                let max = self.filtered.len().saturating_sub(1);
                let cur = self.table_state.selected().unwrap_or(0);
                self.table_state.select(Some((cur + step).min(max)));
                Action::None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.expanded_session = None;
                let step = self.nav_step('k');
                let cur = self.table_state.selected().unwrap_or(0);
                self.table_state.select(Some(cur.saturating_sub(step)));
                Action::None
            }
            KeyCode::Home | KeyCode::Char('g') => {
                self.table_state.select_first();
                Action::None
            }
            KeyCode::End | KeyCode::Char('G') => {
                if !self.filtered.is_empty() {
                    self.table_state.select(Some(self.filtered.len() - 1));
                }
                Action::None
            }
            KeyCode::Char('/') => {
                self.mode = Mode::Search;
                self.search_input.clear();
                Action::None
            }
            KeyCode::Char('d') => {
                if self.selected_session().is_some() {
                    self.mode = Mode::ConfirmDelete;
                    self.delete_countdown_start = Some(std::time::Instant::now());
                }
                Action::None
            }
            KeyCode::Char('r') => {
                if let Some(name) = self.selected_session_name() {
                    self.rename_input.set(&name);
                    self.mode = Mode::Rename;
                }
                Action::None
            }
            KeyCode::Char('s') => {
                self.run_secrets_command();
                Action::None
            }
            KeyCode::Char('n') => {
                self.create_input.clear();
                self.mode = Mode::CreateSession;
                Action::None
            }
            KeyCode::Char('1') => {
                self.cycle_sort(SortColumn::Name);
                Action::None
            }
            KeyCode::Char('2') => {
                self.cycle_sort(SortColumn::Created);
                Action::None
            }
            KeyCode::Char('3') => {
                self.cycle_sort(SortColumn::Modified);
                Action::None
            }
            KeyCode::Char('4') => {
                self.cycle_sort(SortColumn::Secrets);
                Action::None
            }
            KeyCode::Char('5') => {
                self.cycle_sort(SortColumn::Github);
                Action::None
            }
            KeyCode::Char('6') => {
                self.cycle_sort(SortColumn::Todo);
                Action::None
            }
            KeyCode::Tab => {
                if self.selected_session().is_some() {
                    self.show_preview = true;
                    self.focus = Focus::Notes;
                    self.notes_focus = NotesFocus::Input;
                }
                Action::None
            }
            KeyCode::Char(' ') => {
                if let Some(name) = self.selected_session_name() {
                    if self.marked_sessions.contains(&name) {
                        self.marked_sessions.remove(&name);
                    } else {
                        self.marked_sessions.insert(name);
                    }
                }
                Action::None
            }
            KeyCode::Char('D') => {
                if self.marked_sessions.is_empty() {
                    self.set_status("No sessions marked", StatusLevel::Info);
                } else {
                    self.delete_countdown_start = Some(std::time::Instant::now());
                    self.mode = Mode::ConfirmBatchDelete;
                }
                Action::None
            }
            KeyCode::Char('p') => {
                self.show_preview = !self.show_preview;
                if let Some(name) = self.selected_session_name() {
                    if self.expanded_session.as_deref() == Some(&name) {
                        self.expanded_session = None;
                    } else {
                        self.request_preview();
                        self.expanded_session = Some(name);
                    }
                }
                Action::None
            }
            _ => Action::None,
        }
    }

    /// Route Notes-panel keys to the input line, the task list, or an
    /// in-place edit depending on the current sub-focus. Navigation keys
    /// never reach the session list here, so the highlighted session stays
    /// put while the panel is active.
    fn handle_notes_input(&mut self, key: KeyEvent) -> Action {
        match self.notes_focus {
            NotesFocus::Input => self.handle_notes_input_field(key),
            NotesFocus::List => self.handle_notes_list(key),
            NotesFocus::Editing => self.handle_notes_editing(key),
        }
    }

    /// Keys while the Notes input line is focused, composing a new task. Enter
    /// appends it. Down drops into the task list. Esc leaves the panel entirely.
    fn handle_notes_input_field(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.queue_input.clear();
                self.notes_focus = NotesFocus::Input;
                self.focus = Focus::List;
            }
            KeyCode::Enter => {
                return self.submit_notes_input();
            }
            KeyCode::Down => {
                // Drop into the task list only when there is something to select.
                if let Some(name) = self.selected_session_name() {
                    if !session::read_queue(&name).is_empty() {
                        self.notes_focus = NotesFocus::List;
                        self.notes_selected = 0;
                    }
                }
            }
            KeyCode::Left => {
                self.queue_input.move_left();
            }
            KeyCode::Right => {
                self.queue_input.move_right();
            }
            KeyCode::Home => {
                self.queue_input.move_home();
            }
            KeyCode::End => {
                self.queue_input.move_end();
            }
            KeyCode::Delete => {
                self.queue_input.delete_forward();
            }
            KeyCode::Backspace => {
                self.queue_input.delete_back();
            }
            KeyCode::Char(c) => {
                self.queue_input.insert(c);
            }
            _ => {}
        }
        Action::None
    }

    /// Keys while a task in the list is highlighted: move the highlight, delete
    /// or edit the task, or leave. Up off the first task returns to the input.
    fn handle_notes_list(&mut self, key: KeyEvent) -> Action {
        let tasks = match self.selected_session_name() {
            Some(name) => session::read_queue(&name),
            None => Vec::new(),
        };
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.notes_selected == 0 {
                    self.notes_focus = NotesFocus::Input;
                } else {
                    self.notes_selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.notes_selected + 1 < tasks.len() {
                    self.notes_selected += 1;
                }
            }
            KeyCode::Char('d') => {
                self.delete_notes_task(self.notes_selected);
            }
            KeyCode::Char('e') | KeyCode::Enter => {
                if let Some(task) = tasks.get(self.notes_selected) {
                    self.queue_input.set(task);
                    self.notes_focus = NotesFocus::Editing;
                }
            }
            KeyCode::Esc => {
                self.notes_focus = NotesFocus::Input;
                self.focus = Focus::List;
            }
            _ => {}
        }
        Action::None
    }

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

    fn handle_session_menu(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => {
                self.mode = Mode::Normal;
                Action::None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.menu_selected < MENU_ITEMS.len() - 1 {
                    self.menu_selected += 1;
                }
                Action::None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.menu_selected > 0 {
                    self.menu_selected -= 1;
                }
                Action::None
            }
            KeyCode::Enter => self.execute_menu_action(self.menu_selected),
            // Direct shortcut keys
            KeyCode::Char('d') => self.execute_menu_action(1),
            KeyCode::Char('r') => self.execute_menu_action(2),
            KeyCode::Char('s') => self.execute_menu_action(3),
            _ => Action::None,
        }
    }

    fn execute_menu_action(&mut self, index: usize) -> Action {
        self.mode = Mode::Normal;
        match index {
            0 => {
                // Open: same as old Enter logic
                if let Some(session) = self.selected_session() {
                    if session.is_locked {
                        self.mode = Mode::ConfirmForceOpen;
                        Action::None
                    } else {
                        Action::Open(session.name.clone())
                    }
                } else {
                    Action::None
                }
            }
            1 => {
                // Delete
                if self.selected_session().is_some() {
                    self.mode = Mode::ConfirmDelete;
                    self.delete_countdown_start = Some(std::time::Instant::now());
                }
                Action::None
            }
            2 => {
                // Rename
                if let Some(name) = self.selected_session_name() {
                    self.rename_input.set(&name);
                    self.mode = Mode::Rename;
                }
                Action::None
            }
            3 => {
                // Secrets
                self.run_secrets_command();
                Action::None
            }
            _ => Action::None,
        }
    }

    fn handle_search(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.search_input.clear();
                self.fuzzy_indices.clear();
                self.apply_filter_and_sort();
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                // Commit search and return to normal mode
                self.mode = Mode::Normal;
            }
            KeyCode::Up => {
                let cur = self.table_state.selected().unwrap_or(0);
                self.table_state.select(Some(cur.saturating_sub(1)));
            }
            KeyCode::Down => {
                let cur = self.table_state.selected().unwrap_or(0);
                let max = self.filtered.len().saturating_sub(1);
                self.table_state.select(Some((cur + 1).min(max)));
            }
            KeyCode::Left => {
                self.search_input.move_left();
            }
            KeyCode::Right => {
                self.search_input.move_right();
            }
            KeyCode::Home => {
                self.search_input.move_home();
            }
            KeyCode::End => {
                self.search_input.move_end();
            }
            KeyCode::Delete => {
                self.search_input.delete_forward();
                self.apply_filter_and_sort();
            }
            KeyCode::Backspace => {
                self.search_input.delete_back();
                self.apply_filter_and_sort();
            }
            KeyCode::Char(c) => {
                self.search_input.insert(c);
                self.apply_filter_and_sort();
            }
            _ => {}
        }
        Action::None
    }

    fn handle_confirm_delete(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => {
                if self.delete_countdown_remaining() == 0 {
                    self.execute_delete();
                } else {
                    self.set_status("Wait...", StatusLevel::Info);
                }
            }
            _ => {
                self.mode = Mode::Normal;
                self.delete_countdown_start = None;
            }
        }
        Action::None
    }

    fn handle_confirm_batch_delete(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => {
                if self.delete_countdown_remaining() == 0 {
                    self.execute_batch_delete();
                } else {
                    self.set_status("Wait...", StatusLevel::Info);
                }
            }
            _ => {
                self.mode = Mode::Normal;
                self.delete_countdown_start = None;
            }
        }
        Action::None
    }

    fn handle_confirm_force_open(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => {
                if let Some(name) = self.selected_session_name() {
                    return Action::ForceOpen(name);
                }
                self.mode = Mode::Normal;
                Action::None
            }
            _ => {
                self.mode = Mode::Normal;
                Action::None
            }
        }
    }

    fn handle_rename(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                self.execute_rename();
            }
            KeyCode::Left => {
                self.rename_input.move_left();
            }
            KeyCode::Right => {
                self.rename_input.move_right();
            }
            KeyCode::Home => {
                self.rename_input.move_home();
            }
            KeyCode::End => {
                self.rename_input.move_end();
            }
            KeyCode::Delete => {
                self.rename_input.delete_forward();
            }
            KeyCode::Backspace => {
                self.rename_input.delete_back();
            }
            KeyCode::Char(c) => {
                self.rename_input.insert(c);
            }
            _ => {}
        }
        Action::None
    }

    fn handle_create_session(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                return self.execute_create();
            }
            KeyCode::Left => {
                self.create_input.move_left();
            }
            KeyCode::Right => {
                self.create_input.move_right();
            }
            KeyCode::Home => {
                self.create_input.move_home();
            }
            KeyCode::End => {
                self.create_input.move_end();
            }
            KeyCode::Delete => {
                self.create_input.delete_forward();
            }
            KeyCode::Backspace => {
                self.create_input.delete_back();
            }
            KeyCode::Char(c) => {
                self.create_input.insert(c);
            }
            _ => {}
        }
        Action::None
    }

    fn execute_create(&mut self) -> Action {
        let name = self.create_input.text().trim().to_string();
        if name.is_empty() {
            self.set_status("Name cannot be empty", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        if !is_valid_session_name(&name) {
            self.set_status(
                "Invalid name: use letters, digits, - _ . only",
                StatusLevel::Error,
            );
            self.mode = Mode::Normal;
            return Action::None;
        }
        let root = self.sessions_root.clone();
        if root.join(&name).exists() {
            self.set_status("Session already exists", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        self.mode = Mode::Normal;
        Action::Open(name)
    }

    /// Commit the Notes input: replace the highlighted task when editing in
    /// place, otherwise append a new task. Ignores empty input.
    fn submit_notes_input(&mut self) -> Action {
        let text = self.queue_input.text().trim().to_string();
        if text.is_empty() {
            return Action::None;
        }
        let name = match self.selected_session() {
            Some(session) => session.name.clone(),
            None => return Action::None,
        };
        match self.notes_focus {
            NotesFocus::Editing => self.replace_notes_task(&name, self.notes_selected, &text),
            _ => self.append_notes_task(&name, &text),
        }
        Action::None
    }

    /// Sync the affected session's in-memory `queue_depth` with the queue file,
    /// then re-sort. `queue_depth` drives the To-Do column's count, sort, and
    /// visibility, and is otherwise only refreshed by a full `scan_sessions()`
    /// (which re-forks every git remote) — so a queue edit must patch it
    /// directly, without a rescan.
    fn refresh_queue_depth(&mut self, name: &str) {
        let depth = session::read_queue(name).len() as u32;
        if let Some(s) = self.sessions.iter_mut().find(|s| s.name == name) {
            s.queue_depth = depth;
        }
        self.apply_filter_and_sort();
    }

    /// Append `text` as a new queued task and clear the input, leaving focus on
    /// the input so several tasks can be queued in a row.
    fn append_notes_task(&mut self, name: &str, text: &str) {
        let dir = session::queue_dir(name);
        if std::fs::create_dir_all(&dir).is_ok() {
            use std::io::Write;
            match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("queue"))
                .and_then(|mut f| writeln!(f, "{}", text))
            {
                Ok(()) => {
                    // Queue changed: let the Stop-hook gate re-ask even if it was
                    // recently declined. Mirrors the CLI's `rm -f queue.declined`
                    // in bin/cs `_queue_add`.
                    let _ = std::fs::remove_file(dir.join("queue.declined"));
                    self.queue_input.clear();
                    self.refresh_queue_depth(name);
                    self.set_status(format!("Queued task for {}", name), StatusLevel::Success);
                }
                Err(e) => {
                    self.set_status(format!("Queue write failed: {}", e), StatusLevel::Error);
                }
            }
        }
    }

    /// Replace the task at `idx` in place, preserving its position, then return
    /// to the list with the edited task still highlighted.
    fn replace_notes_task(&mut self, name: &str, idx: usize, text: &str) {
        match rewrite_queue_line(name, idx, Some(text)) {
            Ok(()) => {
                let _ = std::fs::remove_file(session::queue_dir(name).join("queue.declined"));
                self.queue_input.clear();
                self.notes_focus = NotesFocus::List;
                let len = session::read_queue(name).len();
                if len == 0 {
                    self.notes_focus = NotesFocus::Input;
                    self.notes_selected = 0;
                } else {
                    self.notes_selected = idx.min(len - 1);
                }
                self.refresh_queue_depth(name);
                self.set_status(format!("Updated task for {}", name), StatusLevel::Success);
            }
            Err(e) => {
                self.set_status(format!("Queue update failed: {}", e), StatusLevel::Error);
            }
        }
    }

    /// Remove the highlighted task, clamp the highlight to the shortened list,
    /// and fall back to the input when the list becomes empty.
    fn delete_notes_task(&mut self, idx: usize) {
        let name = match self.selected_session() {
            Some(session) => session.name.clone(),
            None => return,
        };
        match rewrite_queue_line(&name, idx, None) {
            Ok(()) => {
                let _ = std::fs::remove_file(session::queue_dir(&name).join("queue.declined"));
                let len = session::read_queue(&name).len();
                if len == 0 {
                    self.notes_focus = NotesFocus::Input;
                    self.notes_selected = 0;
                } else if self.notes_selected >= len {
                    self.notes_selected = len - 1;
                }
                self.refresh_queue_depth(&name);
                self.set_status(format!("Removed task from {}", name), StatusLevel::Success);
            }
            Err(e) => {
                self.set_status(format!("Queue delete failed: {}", e), StatusLevel::Error);
            }
        }
    }

    fn handle_secrets(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => {
                self.revealed_secret = None;
                self.mode = Mode::Normal;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if !self.secrets_names.is_empty()
                    && self.secrets_selected < self.secrets_names.len() - 1
                {
                    self.secrets_selected += 1;
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.secrets_selected > 0 {
                    self.secrets_selected -= 1;
                }
            }
            KeyCode::Char('v') | KeyCode::Enter => {
                if let Some(key_name) = self.secrets_names.get(self.secrets_selected).cloned() {
                    self.peek_secret(&key_name);
                }
            }
            KeyCode::Char('d') => {
                if let Some(key_name) = self.secrets_names.get(self.secrets_selected).cloned() {
                    self.run_secrets_subcommand("delete", &key_name);
                    self.secrets_names.remove(self.secrets_selected);
                    if self.secrets_selected >= self.secrets_names.len()
                        && !self.secrets_names.is_empty()
                    {
                        self.secrets_selected = self.secrets_names.len() - 1;
                    }
                }
            }
            _ => {}
        }
        Action::None
    }

    fn cycle_sort(&mut self, col: SortColumn) {
        if self.sort_col == col {
            self.sort_dir = match self.sort_dir {
                SortDirection::Asc => SortDirection::Desc,
                SortDirection::Desc => SortDirection::Asc,
            };
        } else {
            self.sort_col = col;
            self.sort_dir = SortDirection::Asc;
        }
        self.apply_filter_and_sort();
    }

    fn execute_delete(&mut self) {
        if let Some(session) = self.selected_session() {
            let root = self.sessions_root.clone();
            let path = root.join(&session.name);
            let result = if path
                .symlink_metadata()
                .map(|m| m.is_symlink())
                .unwrap_or(false)
            {
                std::fs::remove_file(&path)
            } else {
                std::fs::remove_dir_all(&path)
            };
            match result {
                Ok(()) => {
                    self.set_status(format!("Deleted: {}", session.name), StatusLevel::Success);
                    self.sessions = session::scan_sessions();
                    self.apply_filter_and_sort();
                }
                Err(e) => {
                    self.set_status(format!("Delete failed: {}", e), StatusLevel::Error);
                }
            }
        }
        self.mode = Mode::Normal;
        self.delete_countdown_start = None;
    }

    fn execute_batch_delete(&mut self) {
        let root = self.sessions_root.clone();
        let mut deleted = 0;
        let mut errors = 0;
        let names: Vec<String> = self.marked_sessions.iter().cloned().collect();
        for name in &names {
            let path = root.join(name);
            let result = if path
                .symlink_metadata()
                .map(|m| m.is_symlink())
                .unwrap_or(false)
            {
                std::fs::remove_file(&path)
            } else {
                std::fs::remove_dir_all(&path)
            };
            match result {
                Ok(()) => {
                    deleted += 1;
                    self.flash_row(name.clone(), FlashKind::Success);
                }
                Err(_) => {
                    errors += 1;
                    self.flash_row(name.clone(), FlashKind::Error);
                }
            }
        }
        self.marked_sessions.clear();
        self.sessions = session::scan_sessions();
        self.apply_filter_and_sort();
        if errors == 0 {
            self.set_status(format!("Deleted {} sessions", deleted), StatusLevel::Success);
        } else {
            self.set_status(
                format!("Deleted {}, {} failed", deleted, errors),
                StatusLevel::Error,
            );
        }
        self.mode = Mode::Normal;
        self.delete_countdown_start = None;
    }

    fn execute_rename(&mut self) {
        let new_name = self.rename_input.text().trim().to_string();
        if new_name.is_empty() {
            self.set_status("Name cannot be empty", StatusLevel::Error);
            self.mode = Mode::Normal;
            return;
        }
        if !is_valid_session_name(&new_name) {
            self.set_status(
                "Invalid name: use letters, digits, - _ . only",
                StatusLevel::Error,
            );
            self.mode = Mode::Normal;
            return;
        }

        // Renaming a worktree session (<base>@<task>) via fs::rename would
        // desync git's worktree registration; refuse it here.
        if let Some(session) = self.selected_session() {
            if session.name.contains('@') {
                self.set_status(
                    "Can't rename a worktree session from the TUI",
                    StatusLevel::Error,
                );
                self.mode = Mode::Normal;
                return;
            }
        }

        if let Some(session) = self.selected_session() {
            let root = self.sessions_root.clone();
            let old = root.join(&session.name);
            let new = root.join(&new_name);
            if new.exists() {
                self.set_status("Name already taken", StatusLevel::Error);
            } else {
                match std::fs::rename(&old, &new) {
                    Ok(()) => {
                        rename_claude_projects_dir(&old, &new);
                        self.set_status(format!("Renamed to: {}", new_name), StatusLevel::Success);
                        self.flash_row(&new_name, FlashKind::Success);
                        self.sessions = session::scan_sessions();
                        self.apply_filter_and_sort();
                    }
                    Err(e) => {
                        self.set_status(format!("Rename failed: {}", e), StatusLevel::Error);
                    }
                }
            }
        }
        self.mode = Mode::Normal;
    }

    fn run_secrets_command(&mut self) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new("cs")
                .args([&name, "-secrets", "list"])
                .output();
            match output {
                Ok(out) if out.status.success() => {
                    let text = String::from_utf8_lossy(&out.stdout).to_string();
                    self.secrets_names = Self::parse_secrets_list(&text);
                    self.secrets_selected = 0;
                    self.mode = Mode::Secrets;
                }
                Ok(out) => {
                    let err = String::from_utf8_lossy(&out.stderr);
                    self.set_status(
                        format!("Secrets failed: {}", err.trim()),
                        StatusLevel::Error,
                    );
                }
                Err(e) => {
                    self.set_status(format!("Secrets failed: {}", e), StatusLevel::Error);
                }
            }
        }
    }

    fn parse_secrets_list(output: &str) -> Vec<String> {
        output
            .lines()
            .filter(|line| {
                !line.is_empty()
                    && !line.starts_with("Secrets for session:")
                    && !line.starts_with("No secrets stored")
            })
            .map(|line| line.trim_start().strip_prefix("- ").unwrap_or(line).to_string())
            .collect()
    }

    fn run_secrets_subcommand(&mut self, subcommand: &str, key: &str) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new("cs")
                .args([&name, "-secrets", subcommand, key])
                .output();
            match output {
                Ok(out) => {
                    let text = String::from_utf8_lossy(&out.stdout).to_string()
                        + &String::from_utf8_lossy(&out.stderr).to_string();
                    self.return_to_secrets = true;
                    self.mode = Mode::CommandOutput(text);
                }
                Err(e) => {
                    self.set_status(format!("Secrets failed: {}", e), StatusLevel::Error);
                    self.mode = Mode::Normal;
                }
            }
        }
    }

    fn peek_secret(&mut self, key_name: &str) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new("cs")
                .args([&name, "-secrets", "get", key_name])
                .output();
            match output {
                Ok(out) if out.status.success() => {
                    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    self.revealed_secret =
                        Some((key_name.to_string(), value, std::time::Instant::now()));
                }
                Ok(out) => {
                    let err = String::from_utf8_lossy(&out.stderr);
                    self.set_status(format!("Peek failed: {}", err.trim()), StatusLevel::Error);
                }
                Err(e) => {
                    self.set_status(format!("Peek failed: {}", e), StatusLevel::Error);
                }
            }
        }
    }

    pub fn has_git_sessions(&self) -> bool {
        self.sessions.iter().any(|s| s.git_repo.is_some())
    }

    pub fn has_secrets(&self) -> bool {
        self.sessions.iter().any(|s| s.secrets_count > 0)
    }

    pub fn has_todos(&self) -> bool {
        self.sessions.iter().any(|s| s.queue_depth > 0)
    }

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

    pub fn handle_mouse(&mut self, mouse: MouseEvent) -> Action {
        if self.mode != Mode::Normal {
            return Action::None;
        }

        match mouse.kind {
            MouseEventKind::ScrollUp => {
                let cur = self.table_state.selected().unwrap_or(0);
                self.switch_selected_session(cur.saturating_sub(1));
                Action::None
            }
            MouseEventKind::ScrollDown => {
                let cur = self.table_state.selected().unwrap_or(0);
                let max = self.filtered.len().saturating_sub(1);
                self.switch_selected_session((cur + 1).min(max));
                Action::None
            }
            MouseEventKind::Down(crossterm::event::MouseButton::Left) => {
                let row = mouse.row;
                let col = mouse.column;

                // Only hit-test clicks that land inside the session table's
                // rectangle. Checking just the top-left corner let right-pane
                // (To-Do/detail) clicks fall through and mis-select a session.
                if self
                    .table_area
                    .contains(ratatui::layout::Position { x: col, y: row })
                {
                    let relative_row = row - self.table_area.y;

                    // The table is borderless: row 0 is the header, row 1 the rule.
                    if relative_row == 0 {
                        // Header click — determine which column
                        if let Some(sort_col) = self.column_at_x(col) {
                            self.cycle_sort(sort_col);
                        }
                    } else if let Some(&(_, _, idx)) = self.row_hit_spans.iter().find(
                        |(start_y, height, _)| {
                            relative_row >= *start_y && relative_row < start_y + height
                        },
                    ) {
                        // Rows are variable height; consult the renderer's hit-map
                        // so clicks below a group header or expanded row still land
                        // on the right session.
                        self.switch_selected_session(idx);
                    }
                }
                Action::None
            }
            MouseEventKind::Down(crossterm::event::MouseButton::Middle) => {
                // Middle-click opens the selected session
                if let Some(name) = self.selected_session_name() {
                    Action::Open(name)
                } else {
                    Action::None
                }
            }
            _ => Action::None,
        }
    }

    fn column_at_x(&self, x: u16) -> Option<SortColumn> {
        // Mirrors the borderless layout in ui::render_table: the selection
        // symbol, then columns separated by COL_SPACING. Half the gap on each
        // side counts toward the neighbouring column for hit-testing.
        let mut offset = self.table_area.x + crate::ui::SELECT_WIDTH;
        let span = crate::ui::COL_SPACING;
        for (i, &width) in self.column_widths.iter().enumerate() {
            if x >= offset && x < offset + width + span {
                return self.visible_sort_columns.get(i).copied();
            }
            offset += width + span;
        }
        None
    }
}

/// Rewrite a session's queue file, targeting the `target`-th non-blank line
/// (0-based). `Some(text)` replaces that line's content; `None` drops it.
/// Blank lines and every other task keep their position, mirroring the CLI's
/// `_queue_rm` in bin/cs. Writes via a temp file then renames, as the CLI does.
fn rewrite_queue_line(
    name: &str,
    target: usize,
    replacement: Option<&str>,
) -> std::io::Result<()> {
    let dir = session::queue_dir(name);
    let path = dir.join("queue");
    let content = std::fs::read_to_string(&path)?;

    let mut out = String::new();
    let mut idx = 0usize;
    for line in content.lines() {
        if line.trim().is_empty() {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if idx == target {
            if let Some(text) = replacement {
                out.push_str(text);
                out.push('\n');
            }
        } else {
            out.push_str(line);
            out.push('\n');
        }
        idx += 1;
    }

    let tmp = dir.join("queue.tmp");
    std::fs::write(&tmp, out)?;
    std::fs::rename(&tmp, &path)
}

/// Rename the Claude Code conversation history directory to match the session rename.
/// The Claude home dir (`$HOME`), honoring a test-only thread-local override so
/// tests exercise the projects-dir logic without mutating the process-global
/// `HOME` (which races parallel tests' env reads). See [`test_home`].
fn claude_home() -> Option<String> {
    #[cfg(test)]
    if let Some(h) = test_home::current() {
        return Some(h.to_string_lossy().into_owned());
    }
    std::env::var("HOME").ok()
}

/// Test-only override for [`claude_home`]. Same rationale as
/// `session::test_root`: scope the value to the current test thread instead of
/// mutating process-global `HOME`. The returned guard clears it on drop.
#[cfg(test)]
pub mod test_home {
    use std::cell::RefCell;
    use std::path::PathBuf;

    thread_local! {
        static HOME: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    }

    pub(super) fn current() -> Option<PathBuf> {
        HOME.with(|c| c.borrow().clone())
    }

    #[must_use]
    pub fn scoped(home: PathBuf) -> Guard {
        HOME.with(|c| *c.borrow_mut() = Some(home));
        Guard
    }

    pub struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            HOME.with(|c| *c.borrow_mut() = None);
        }
    }
}

/// Claude stores conversations under ~/.claude/projects/ keyed by encoded absolute path.
/// Path encoding: replace '/' and '.' with '-'.
fn rename_claude_projects_dir(old_session_path: &std::path::Path, new_session_path: &std::path::Path) {
    fn encode_path(p: &std::path::Path) -> String {
        p.to_string_lossy().replace('/', "-").replace('.', "-")
    }

    let home = match claude_home() {
        Some(h) => h,
        None => return,
    };
    let projects_dir = std::path::PathBuf::from(&home).join(".claude/projects");
    let old_encoded = encode_path(old_session_path);
    let new_encoded = encode_path(new_session_path);
    let old_proj = projects_dir.join(&old_encoded);
    let new_proj = projects_dir.join(&new_encoded);

    if old_proj.is_dir() && !new_proj.exists() {
        let _ = std::fs::rename(&old_proj, &new_proj);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Session;

    fn sample_sessions() -> Vec<Session> {
        vec![
            Session {
                name: "alpha".into(),
                is_adopted: false,
                created: Some("2026-01-01 10:00".into()),
                modified: Some("2026-02-20 14:00".into()),
                modified_ts: None,
                lock_pid: None,
                is_locked: false,
                secrets_count: 0,
                queue_depth: 0,
                git_repo: Some("hex/alpha".into()),
                tags: Vec::new(),
            },
            Session {
                name: "beta".into(),
                is_adopted: false,
                created: Some("2026-02-01 10:00".into()),
                modified: Some("2026-02-15 09:00".into()),
                modified_ts: None,
                lock_pid: None,
                is_locked: false,
                secrets_count: 2,
                queue_depth: 0,
                git_repo: Some("hex/beta".into()),
                tags: Vec::new(),
            },
            Session {
                name: "gamma".into(),
                is_adopted: true,
                created: Some("2025-12-01 10:00".into()),
                modified: Some("2026-01-10 08:00".into()),
                modified_ts: None,
                lock_pid: Some(12345),
                is_locked: true,
                secrets_count: 0,
                queue_depth: 0,
                git_repo: None,
                tags: Vec::new(),
            },
        ]
    }

    #[test]
    fn new_app_selects_first_row() {
        let app = App::new(sample_sessions());
        assert_eq!(app.table_state.selected(), Some(0));
        assert_eq!(app.filtered.len(), 3);
    }

    #[test]
    fn has_timed_state_tracks_each_transient_state() {
        let mut app = App::new(sample_sessions());
        // Nothing is pending on a freshly built app.
        assert!(!app.has_timed_state());

        // Each transient state, set on its own, holds the heartbeat open.
        app.set_status("saved", StatusLevel::Info);
        assert!(app.has_timed_state());
        app.status_message = None;
        assert!(!app.has_timed_state());

        app.flash_row("alpha", FlashKind::Success);
        assert!(app.has_timed_state());
        app.row_flashes.clear();
        assert!(!app.has_timed_state());

        app.revealed_secret =
            Some(("KEY".into(), "value".into(), std::time::Instant::now()));
        assert!(app.has_timed_state());
        app.revealed_secret = None;
        assert!(!app.has_timed_state());

        app.delete_countdown_start = Some(std::time::Instant::now());
        assert!(app.has_timed_state());
        app.delete_countdown_start = None;
        assert!(!app.has_timed_state());
    }

    #[test]
    fn is_animating_pauses_after_idle_but_holds_for_timed_state() {
        use std::time::Duration;
        let mut app = App::new(sample_sessions());
        let recent = Duration::from_secs(1);
        let idle = Duration::from_secs(IDLE_PAUSE_SECS + 5);

        // A selected row shimmers while the user is recently active.
        assert!(app.is_animating(recent));
        // Once idle past the pause, with nothing pending, the loop can block.
        assert!(!app.is_animating(idle));

        // A pending timed state holds the heartbeat open even when idle.
        app.set_status("saved", StatusLevel::Info);
        assert!(app.is_animating(idle));
        app.status_message = None;

        // With no selection there is no shimmer to animate.
        app.table_state.select(None);
        assert!(!app.is_animating(recent));
    }

    #[test]
    fn filter_narrows_results() {
        let mut app = App::new(sample_sessions());
        app.search_input.set("bet");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1);
        assert_eq!(app.sessions[app.filtered[0]].name, "beta");
    }

    #[test]
    fn filter_is_case_insensitive() {
        let mut app = App::new(sample_sessions());
        app.search_input.set("ALPHA");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1);
        assert_eq!(app.sessions[app.filtered[0]].name, "alpha");
    }

    #[test]
    fn empty_filter_shows_all() {
        let mut app = App::new(sample_sessions());
        app.search_input.set("");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 3);
    }

    #[test]
    fn sort_by_name_ascending() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Name;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        let names: Vec<&str> = app
            .filtered
            .iter()
            .map(|&i| app.sessions[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["alpha", "beta", "gamma"]);
    }

    #[test]
    fn sort_by_name_descending() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Name;
        app.sort_dir = SortDirection::Desc;
        app.apply_filter_and_sort();
        let names: Vec<&str> = app
            .filtered
            .iter()
            .map(|&i| app.sessions[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["gamma", "beta", "alpha"]);
    }

    #[test]
    fn sort_by_created_ascending() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Created;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        let names: Vec<&str> = app
            .filtered
            .iter()
            .map(|&i| app.sessions[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["gamma", "alpha", "beta"]);
    }

    #[test]
    fn sort_by_modified_descending() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Modified;
        app.sort_dir = SortDirection::Desc;
        app.apply_filter_and_sort();
        let names: Vec<&str> = app
            .filtered
            .iter()
            .map(|&i| app.sessions[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["alpha", "beta", "gamma"]);
    }

    #[test]
    fn sort_preserves_selected_session() {
        let mut app = App::new(sample_sessions());
        // Default: sorted by name asc → alpha(0), beta(1), gamma(2)
        // Select "beta" at index 1
        app.table_state.select(Some(1));
        assert_eq!(app.selected_session().unwrap().name, "beta");

        // Reverse sort → gamma(0), beta(1), alpha(2) — beta stays at 1
        app.sort_dir = SortDirection::Desc;
        app.apply_filter_and_sort();
        assert_eq!(app.selected_session().unwrap().name, "beta");

        // Sort by created asc → gamma(0), alpha(1), beta(2)
        app.sort_col = SortColumn::Created;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        // "beta" should now be at index 2
        assert_eq!(app.selected_session().unwrap().name, "beta");
        assert_eq!(app.table_state.selected(), Some(2));
    }

    #[test]
    fn cycle_sort_toggles_direction() {
        let mut app = App::new(sample_sessions());
        // Default sort is recency — most-recently-modified first.
        assert_eq!(app.sort_col, SortColumn::Modified);
        assert_eq!(app.sort_dir, SortDirection::Desc);

        // Re-selecting the active column toggles its direction.
        app.cycle_sort(SortColumn::Modified);
        assert_eq!(app.sort_dir, SortDirection::Asc);

        app.cycle_sort(SortColumn::Modified);
        assert_eq!(app.sort_dir, SortDirection::Desc);
    }

    #[test]
    fn cycle_sort_switches_column() {
        let mut app = App::new(sample_sessions());
        app.cycle_sort(SortColumn::Created);
        assert_eq!(app.sort_col, SortColumn::Created);
        assert_eq!(app.sort_dir, SortDirection::Asc);
    }

    #[test]
    fn default_view_is_sorted_by_recency() {
        let mk = |name: &str, modified: &str| Session {
            name: name.into(),
            is_adopted: false,
            created: Some("2026-01-01 10:00".into()),
            modified: Some(modified.into()),
            modified_ts: None,
            lock_pid: None,
            is_locked: false,
            secrets_count: 0,
            queue_depth: 0,
            git_repo: None,
            tags: Vec::new(),
        };
        // Insertion order deliberately differs from recency order.
        let app = App::new(vec![
            mk("old", "2026-01-01 09:00"),
            mk("newest", "2026-06-20 09:00"),
            mk("mid", "2026-03-15 09:00"),
        ]);
        let order: Vec<&str> = app
            .filtered
            .iter()
            .map(|&i| app.sessions[i].name.as_str())
            .collect();
        assert_eq!(order, vec!["newest", "mid", "old"]);
    }

    #[test]
    fn enter_opens_session_menu() {
        let mut app = App::new(sample_sessions());
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::SessionMenu);
        assert_eq!(app.menu_selected, 0);
    }

    #[test]
    fn q_returns_quit_action() {
        let mut app = App::new(sample_sessions());
        let action = app.handle_key(KeyEvent::from(KeyCode::Char('q')));
        assert!(matches!(action, Action::Quit));
    }

    #[test]
    fn esc_returns_quit_in_normal_mode() {
        let mut app = App::new(sample_sessions());
        let action = app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert!(matches!(action, Action::Quit));
    }

    #[test]
    fn slash_enters_search_mode() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        assert_eq!(app.mode, Mode::Search);
    }

    #[test]
    fn search_typing_filters_while_typing() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('b')));
        app.handle_key(KeyEvent::from(KeyCode::Char('e')));
        assert_eq!(app.search_input.text(), "be");
        // Filtered to matches while typing
        assert!(app.filtered.len() < 3);
        // Fuzzy indices populated for matching session
        assert!(!app.fuzzy_indices.is_empty());
    }

    #[test]
    fn search_esc_clears_and_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('x')));

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.search_input.text(), "");
        // All sessions restored after Esc
        assert_eq!(app.filtered.len(), 3);
    }

    #[test]
    fn d_enters_confirm_delete_mode() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(app.mode, Mode::ConfirmDelete);
    }

    #[test]
    fn confirm_delete_n_cancels() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.sessions.len(), 3); // not deleted
    }

    #[test]
    fn r_enters_rename_mode_with_current_name() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('r')));
        assert_eq!(app.mode, Mode::Rename);
        assert_eq!(app.rename_input.text(), "alpha");
    }

    #[test]
    fn rename_validates_empty_name() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Rename;
        app.rename_input.set("");
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("empty"));
    }

    #[test]
    fn rename_validates_invalid_chars() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Rename;
        app.rename_input.set("bad/name");
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("Invalid"));
    }

    #[test]
    fn selection_clamps_after_filter() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(2)); // select "gamma"
        app.search_input.set("alph");
        app.apply_filter_and_sort();
        // Only 1 result, so selection should clamp to 0
        assert_eq!(app.table_state.selected(), Some(0));
    }

    #[test]
    fn enter_on_locked_session_opens_menu() {
        let mut app = App::new(sample_sessions());
        // Navigate to gamma (index 2), which is locked
        app.table_state.select(Some(2));
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::SessionMenu);
        assert_eq!(app.menu_selected, 0);
    }

    #[test]
    fn confirm_force_open_y_returns_force_open_action() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(2));
        app.mode = Mode::ConfirmForceOpen;
        let action = app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        assert!(matches!(action, Action::ForceOpen(name) if name == "gamma"));
    }

    #[test]
    fn confirm_force_open_n_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(2));
        app.mode = Mode::ConfirmForceOpen;
        let action = app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn enter_on_unlocked_session_opens_menu() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is unlocked — Enter opens menu, not session directly
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::SessionMenu);
    }

    #[test]
    fn navigate_down_and_up() {
        let mut app = App::new(sample_sessions());
        assert_eq!(app.table_state.selected(), Some(0));

        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.table_state.selected(), Some(1));

        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.table_state.selected(), Some(0));
    }

    #[test]
    fn secrets_esc_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Secrets;
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn secrets_q_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Secrets;
        app.handle_key(KeyEvent::from(KeyCode::Char('q')));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn secrets_navigate_down() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Secrets;
        app.secrets_names = vec!["KEY1".into(), "KEY2".into(), "KEY3".into()];
        app.secrets_selected = 0;
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.secrets_selected, 1);
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.secrets_selected, 2);
        // Should not go past the end
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.secrets_selected, 2);
    }

    #[test]
    fn secrets_navigate_up() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Secrets;
        app.secrets_names = vec!["KEY1".into(), "KEY2".into()];
        app.secrets_selected = 1;
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.secrets_selected, 0);
        // Should not go below 0
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.secrets_selected, 0);
    }

    #[test]
    fn command_output_returns_to_secrets_when_flagged() {
        let mut app = App::new(sample_sessions());
        app.secrets_names = vec!["KEY1".into(), "KEY2".into()];
        app.secrets_selected = 0;
        app.return_to_secrets = true;
        app.mode = Mode::CommandOutput("value: 123".into());
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert_eq!(app.mode, Mode::Secrets);
        assert!(!app.return_to_secrets);
    }

    #[test]
    fn command_output_returns_to_normal_when_not_flagged() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CommandOutput("some output".into());
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn parse_secrets_list_extracts_names() {
        let output = "Secrets for session: test\n  - API_KEY\n  - DB_PASSWORD\n";
        let names = App::parse_secrets_list(output);
        assert_eq!(names, vec!["API_KEY", "DB_PASSWORD"]);
    }

    #[test]
    fn parse_secrets_list_empty_session() {
        let output = "No secrets stored for session: test\n";
        let names = App::parse_secrets_list(output);
        assert!(names.is_empty());
    }

    #[test]
    fn parse_secrets_list_empty_output() {
        let names = App::parse_secrets_list("");
        assert!(names.is_empty());
    }

    // --- SessionMenu tests ---

    #[test]
    fn menu_j_increments_selection() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.menu_selected, 1);
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.menu_selected, 2);
    }

    #[test]
    fn menu_k_decrements_selection() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 2;
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.menu_selected, 1);
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.menu_selected, 0);
    }

    #[test]
    fn menu_selection_clamps_at_bounds() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        // Can't go below 0
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.menu_selected, 0);
        // Can't go past last item
        app.menu_selected = MENU_ITEMS.len() - 1;
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.menu_selected, MENU_ITEMS.len() - 1);
    }

    #[test]
    fn menu_enter_on_open_returns_open_for_unlocked() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is unlocked
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::Open(name) if name == "alpha"));
    }

    #[test]
    fn menu_enter_on_open_enters_force_open_for_locked() {
        let mut app = App::new(sample_sessions());
        // gamma (index 2) is locked
        app.table_state.select(Some(2));
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::ConfirmForceOpen);
    }

    #[test]
    fn menu_esc_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 3;
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn menu_q_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('q')));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn menu_shortcut_d_enters_confirm_delete() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(app.mode, Mode::ConfirmDelete);
    }

    #[test]
    fn menu_shortcut_r_enters_rename() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('r')));
        assert_eq!(app.mode, Mode::Rename);
        assert_eq!(app.rename_input.text(), "alpha");
    }

    #[test]
    fn menu_enter_on_delete_enters_confirm_delete() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 1; // Delete
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::ConfirmDelete);
    }

    #[test]
    fn menu_enter_on_rename_enters_rename() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 2; // Rename
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Rename);
        assert_eq!(app.rename_input.text(), "alpha");
    }

    #[test]
    fn menu_down_arrow_increments() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        app.handle_key(KeyEvent::from(KeyCode::Down));
        assert_eq!(app.menu_selected, 1);
    }

    #[test]
    fn menu_up_arrow_decrements() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 1;
        app.handle_key(KeyEvent::from(KeyCode::Up));
        assert_eq!(app.menu_selected, 0);
    }

    // --- TextInput tests ---

    #[test]
    fn text_input_insert_at_cursor() {
        let mut input = TextInput::new();
        input.set("hllo");
        input.move_home();
        input.move_right(); // cursor after 'h'
        input.insert('e');
        assert_eq!(input.text(), "hello");
        assert_eq!(input.before_cursor(), "he");
        assert_eq!(input.after_cursor(), "llo");
    }

    #[test]
    fn text_input_delete_back() {
        let mut input = TextInput::new();
        input.set("hello");
        input.move_home();
        input.move_right();
        input.move_right(); // cursor after 'e'
        input.delete_back();
        assert_eq!(input.text(), "hllo");
        assert_eq!(input.before_cursor(), "h");
    }

    #[test]
    fn text_input_delete_forward() {
        let mut input = TextInput::new();
        input.set("hello");
        input.move_home();
        input.move_right(); // cursor after 'h'
        input.delete_forward(); // deletes 'e'
        assert_eq!(input.text(), "hllo");
        assert_eq!(input.before_cursor(), "h");
    }

    #[test]
    fn text_input_move_left_right() {
        let mut input = TextInput::new();
        input.set("abc");
        assert_eq!(input.before_cursor(), "abc"); // cursor at end
        input.move_left();
        assert_eq!(input.before_cursor(), "ab");
        assert_eq!(input.after_cursor(), "c");
        input.move_right();
        assert_eq!(input.before_cursor(), "abc");
    }

    #[test]
    fn text_input_home_end() {
        let mut input = TextInput::new();
        input.set("hello");
        input.move_home();
        assert_eq!(input.before_cursor(), "");
        assert_eq!(input.after_cursor(), "hello");
        input.move_end();
        assert_eq!(input.before_cursor(), "hello");
        assert_eq!(input.after_cursor(), "");
    }

    #[test]
    fn text_input_set_puts_cursor_at_end() {
        let mut input = TextInput::new();
        input.set("test");
        assert_eq!(input.text(), "test");
        assert_eq!(input.before_cursor(), "test");
        assert_eq!(input.after_cursor(), "");
    }

    #[test]
    fn text_input_empty_edge_cases() {
        let mut input = TextInput::new();
        // Operations on empty input should not panic
        input.delete_back();
        input.delete_forward();
        input.move_left();
        input.move_right();
        assert_eq!(input.text(), "");
        assert_eq!(input.before_cursor(), "");
        assert_eq!(input.after_cursor(), "");
    }

    #[test]
    fn text_input_multibyte_chars() {
        let mut input = TextInput::new();
        input.set("cafe\u{0301}"); // café with combining accent
        input.move_left(); // move before the combining accent
        input.move_left(); // move before 'e'
        assert_eq!(input.before_cursor(), "caf");
    }

    #[test]
    fn text_input_clear_resets_cursor() {
        let mut input = TextInput::new();
        input.set("hello");
        input.move_left();
        input.clear();
        assert_eq!(input.text(), "");
        assert_eq!(input.before_cursor(), "");
    }

    #[test]
    fn window_short_text_fits_whole() {
        let mut t = TextInput::new();
        t.set("hello"); // cursor at end (5)
        let w = t.window(20);
        assert_eq!(w.before, "hello");
        assert_eq!(w.after, "");
        assert_eq!(w.cursor_col, 5);
    }

    #[test]
    fn window_cursor_at_end_of_long_text_keeps_cursor_in_last_column() {
        let mut t = TextInput::new();
        let long = "Refactor the preview worker so that the git walk is bounded";
        t.set(long); // cursor at end
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
        t.move_home(); // cursor at 0
        let w = t.window(10);
        assert_eq!(w.cursor_col, 0);
        assert_eq!(w.before, "");
        assert_eq!(w.after, "Refactor t"); // 10 columns
    }

    #[test]
    fn window_drops_a_wide_char_straddling_the_left_edge_never_splitting_it() {
        let mut t = TextInput::new();
        // Each CJK char is 2 columns wide: 10 chars, 20 cols, cursor at end.
        t.set("編集する日本語タスク");
        // width 8 => offset_w = 20 - 7 = 13, which lands *inside* 語 (cols 12-13).
        // The left-edge drop rule discards 語 whole rather than showing its right
        // half, so exactly タ(14) ス(16) ク(18) remain — 6 visible columns, not 8.
        // A right-edge rule would keep 語 and render "語タスク" at cursor_col 8,
        // overflowing the box; this exact-content assertion fails under that bug.
        let w = t.window(8);
        assert_eq!(w.before, "タスク");
        assert_eq!(w.after, "");
        assert_eq!(w.cursor_col, 6);
    }

    #[test]
    fn window_zero_and_one_width_do_not_panic() {
        let mut t = TextInput::new();
        t.set("anything long enough to scroll");
        let w0 = t.window(0);
        assert_eq!(w0.cursor_col, 0);
        let w1 = t.window(1);
        // The invariant is cursor_col < width, i.e. exactly 0 at width 1 — a
        // looser `<= 1` would not catch an off-by-one that pushed it to width.
        assert_eq!(w1.cursor_col, 0);
    }

    #[test]
    fn rename_claude_projects_dir_moves_matching_dir() {
        let tmp = std::env::temp_dir().join(format!("cs-test-proj-rename-{}", std::process::id()));
        let fake_projects = tmp.join(".claude/projects");
        let sessions = tmp.join("sessions");

        let old_session = sessions.join("old-name");
        let new_session = sessions.join("new-name");

        // Create the fake Claude projects dir with encoded old path
        fn encode_path(p: &std::path::Path) -> String {
            p.to_string_lossy().replace('/', "-").replace('.', "-")
        }
        let old_encoded = encode_path(&old_session);
        let old_proj = fake_projects.join(&old_encoded);
        std::fs::create_dir_all(&old_proj).unwrap();
        // Put a marker file inside to verify it moved
        std::fs::write(old_proj.join("conv.jsonl"), "test").unwrap();

        // Override the Claude home so the function finds our fake .claude/projects
        let _home = test_home::scoped(tmp.clone());

        rename_claude_projects_dir(&old_session, &new_session);

        let new_encoded = encode_path(&new_session);
        let new_proj = fake_projects.join(&new_encoded);
        assert!(new_proj.is_dir(), "projects dir should exist at new path");
        assert!(!old_proj.is_dir(), "projects dir should not exist at old path");
        assert_eq!(
            std::fs::read_to_string(new_proj.join("conv.jsonl")).unwrap(),
            "test"
        );

        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn rename_claude_projects_dir_noop_when_no_projects_dir() {
        let tmp = std::env::temp_dir().join(format!("cs-test-proj-noop-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        let _home = test_home::scoped(tmp.clone());

        // Should not panic even if .claude/projects doesn't exist
        rename_claude_projects_dir(
            &std::path::PathBuf::from("/fake/old"),
            &std::path::PathBuf::from("/fake/new"),
        );

        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn set_status_creates_message() {
        let mut app = App::new(sample_sessions());
        app.set_status("test message", StatusLevel::Success);
        let msg = app.status_message.as_ref().unwrap();
        assert_eq!(msg.text, "test message");
        assert_eq!(msg.level, StatusLevel::Success);
    }

    #[test]
    fn expire_status_clears_after_timeout() {
        let mut app = App::new(sample_sessions());
        // Manually create a message with an old timestamp
        app.status_message = Some(StatusMessage {
            text: "old".into(),
            level: StatusLevel::Info,
            set_at: std::time::Instant::now() - std::time::Duration::from_secs(10),
        });
        assert!(app.expire_status());
        assert!(app.status_message.is_none());
    }

    #[test]
    fn expire_status_keeps_fresh_messages() {
        let mut app = App::new(sample_sessions());
        app.set_status("fresh", StatusLevel::Error);
        assert!(!app.expire_status());
        assert!(app.status_message.is_some());
    }

    #[test]
    fn n_enters_create_session_mode() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        assert_eq!(app.mode, Mode::CreateSession);
    }

    #[test]
    fn create_session_esc_cancels() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn create_session_empty_name_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.create_input.clear();
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("empty"));
    }

    #[test]
    fn create_session_invalid_chars_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.create_input.set("bad/name");
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("Invalid"));
    }

    #[test]
    fn create_session_valid_name_returns_open_action() {
        // execute_create reads sessions_root(); scope it to a temp dir (per test
        // thread, so parallel tests can't collide) and keep the .exists() check
        // off the developer's real sessions root.
        let tmp = std::env::temp_dir().join(format!("cs-tui-create-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).ok();
        let _root = session::test_root::scoped(tmp.clone());
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.create_input.set("brand-new-session");
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::Open(name) if name == "brand-new-session"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn has_secrets_detects_sessions_with_secrets() {
        let app = App::new(sample_sessions());
        // beta has secrets_count=2
        assert!(app.has_secrets());
    }

    #[test]
    fn flash_row_sets_and_active_flash_reads() {
        let mut app = App::new(sample_sessions());
        app.flash_row("alpha", FlashKind::Success);
        assert_eq!(app.active_flash("alpha"), Some(FlashKind::Success));
        assert_eq!(app.active_flash("beta"), None);
    }

    #[test]
    fn expire_flashes_clears_old_entries() {
        let mut app = App::new(sample_sessions());
        app.row_flashes.insert(
            "old".into(),
            (FlashKind::Error, std::time::Instant::now() - std::time::Duration::from_secs(2)),
        );
        assert!(app.expire_flashes());
        assert!(app.row_flashes.is_empty());
    }

    #[test]
    fn expire_flashes_keeps_fresh_entries() {
        let mut app = App::new(sample_sessions());
        app.flash_row("fresh", FlashKind::Success);
        assert!(!app.expire_flashes());
        assert!(!app.row_flashes.is_empty());
    }

    #[test]
    fn has_secrets_false_when_no_secrets() {
        let sessions: Vec<Session> = sample_sessions()
            .into_iter()
            .map(|mut s| { s.secrets_count = 0; s })
            .collect();
        let app = App::new(sessions);
        assert!(!app.has_secrets());
    }

    #[test]
    fn confirm_delete_sets_countdown_start() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(app.mode, Mode::ConfirmDelete);
        assert!(app.delete_countdown_start.is_some());
    }

    #[test]
    fn confirm_delete_y_rejected_during_countdown() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Countdown just started — y should be rejected
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        assert_eq!(app.mode, Mode::ConfirmDelete); // still in confirm mode
        assert_eq!(app.sessions.len(), 3); // not deleted
        // Should show a "Wait..." status message
        assert!(app.status_message.as_ref().unwrap().text.contains("Wait"));
    }

    #[test]
    fn confirm_delete_y_accepted_after_countdown() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Simulate countdown elapsed by backdating the start
        app.delete_countdown_start =
            Some(std::time::Instant::now() - std::time::Duration::from_secs(3));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        // execute_delete runs and returns to Normal
        // (actual filesystem delete fails in tests, but mode change confirms acceptance)
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn confirm_delete_remaining_seconds() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Just started: should show 2
        assert_eq!(app.delete_countdown_remaining(), 2);
        // Backdate by 1 second
        app.delete_countdown_start =
            Some(std::time::Instant::now() - std::time::Duration::from_secs(1));
        assert_eq!(app.delete_countdown_remaining(), 1);
        // Backdate by 2+ seconds
        app.delete_countdown_start =
            Some(std::time::Instant::now() - std::time::Duration::from_secs(3));
        assert_eq!(app.delete_countdown_remaining(), 0);
    }

    #[test]
    fn fuzzy_match_empty_pattern_matches_everything() {
        let result = fuzzy_match("", "anything");
        assert!(result.is_some());
        assert_eq!(result.unwrap(), (0, vec![]));
    }

    #[test]
    fn fuzzy_match_exact_prefix() {
        let result = fuzzy_match("deb", "debug-api");
        assert!(result.is_some());
        let (score, indices) = result.unwrap();
        assert_eq!(indices, vec![0, 1, 2]);
        // first char bonus (10) + word boundary for first char (5) + 2 consecutive (6)
        assert!(score > 0);
    }

    #[test]
    fn fuzzy_match_scattered_chars() {
        let result = fuzzy_match("dba", "debug-api");
        assert!(result.is_some());
        let (_score, indices) = result.unwrap();
        // d=0, b=2, a=6
        assert_eq!(indices, vec![0, 2, 6]);
    }

    #[test]
    fn fuzzy_match_case_insensitive() {
        let result = fuzzy_match("ABC", "a-big-cat");
        assert!(result.is_some());
    }

    #[test]
    fn fuzzy_match_no_match() {
        assert!(fuzzy_match("xyz", "debug-api").is_none());
    }

    #[test]
    fn fuzzy_match_order_matters() {
        // "ba" should not match "ab" (b comes before a)
        assert!(fuzzy_match("ba", "ab").is_none());
    }

    #[test]
    fn fuzzy_match_word_boundary_bonus() {
        // "da" matching "debug-api" should get word boundary bonus for 'a' at position 6
        let result = fuzzy_match("da", "debug-api");
        assert!(result.is_some());
        let (score_boundary, _) = result.unwrap();

        // "de" matching "debug-api" — both consecutive from start, no extra boundary
        let result2 = fuzzy_match("de", "debug-api");
        assert!(result2.is_some());
        let (score_consecutive, _) = result2.unwrap();

        // "da" gets boundary bonus on 'a' (after '-'), "de" gets consecutive bonus
        // Both should have reasonable scores
        assert!(score_boundary > 0);
        assert!(score_consecutive > 0);
    }

    #[test]
    fn fuzzy_match_multibyte_does_not_panic() {
        // to_lowercase() can change the char count (e.g. 'İ' -> two code points),
        // which previously desynced text_lower from text_chars and panicked on
        // an out-of-bounds index. These must complete without panicking.
        let _ = fuzzy_match("s", "İstanbul-café—session");
        let _ = fuzzy_match("x", "İİİ");
        let r = fuzzy_match("ca", "café-app");
        assert!(r.is_some());
    }

    #[test]
    fn is_valid_session_name_matches_cs_rules() {
        // Accepted by bash cs validate_session_name.
        assert!(is_valid_session_name("debug-api"));
        assert!(is_valid_session_name("v2026.7.4"));
        assert!(is_valid_session_name("my_session"));
        // Rejected — these would produce a dir the cs CLI can't open, or traverse.
        assert!(!is_valid_session_name(""));
        assert!(!is_valid_session_name("."));
        assert!(!is_valid_session_name(".."));
        assert!(!is_valid_session_name("has space"));
        assert!(!is_valid_session_name("café")); // non-ASCII letter
        assert!(!is_valid_session_name("base@task")); // worktree separator
        assert!(!is_valid_session_name("a/b"));
    }

    #[test]
    fn fuzzy_match_filter_replaces_substring() {
        // Verify fuzzy match handles cases that substring wouldn't
        let result = fuzzy_match("cs", "claude-sessions");
        assert!(result.is_some());
        let (_, indices) = result.unwrap();
        // c=0, s=7 (sessions)
        assert_eq!(indices[0], 0);
    }

    #[test]
    fn search_filters_while_typing() {
        let mut app = App::new(sample_sessions());
        // Enter search mode
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        assert_eq!(app.mode, Mode::Search);
        // Type "al" — should filter to "alpha" immediately
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        app.handle_key(KeyEvent::from(KeyCode::Char('l')));
        // Filtered to matches while typing
        assert_eq!(app.filtered.len(), 1);
        assert!(app.fuzzy_indices.values().any(|v| !v.is_empty()));
    }

    #[test]
    fn search_enter_commits_and_exits() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        app.handle_key(KeyEvent::from(KeyCode::Char('l')));
        // Already filtered while typing
        assert_eq!(app.filtered.len(), 1);
        // Enter exits search mode, keeps filter
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.filtered.len(), 1);
    }

    #[test]
    fn search_esc_restores_all() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('z')));
        // Esc clears search and restores all
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.filtered.len(), 3);
        assert!(app.fuzzy_indices.is_empty());
    }

    #[test]
    fn peek_remaining_returns_countdown() {
        let mut app = App::new(sample_sessions());
        // No reveal
        assert_eq!(app.peek_remaining(), 0);
        // Fresh reveal
        app.revealed_secret = Some(("KEY".into(), "val".into(), std::time::Instant::now()));
        assert_eq!(app.peek_remaining(), 5);
        // After 3 seconds
        app.revealed_secret = Some((
            "KEY".into(),
            "val".into(),
            std::time::Instant::now() - std::time::Duration::from_secs(3),
        ));
        assert_eq!(app.peek_remaining(), 2);
    }

    #[test]
    fn expire_peek_clears_after_timeout() {
        let mut app = App::new(sample_sessions());
        app.revealed_secret = Some((
            "KEY".into(),
            "val".into(),
            std::time::Instant::now() - std::time::Duration::from_secs(6),
        ));
        assert!(app.expire_peek());
        assert!(app.revealed_secret.is_none());
    }

    #[test]
    fn expire_peek_keeps_fresh_reveal() {
        let mut app = App::new(sample_sessions());
        app.revealed_secret = Some(("KEY".into(), "val".into(), std::time::Instant::now()));
        assert!(!app.expire_peek());
        assert!(app.revealed_secret.is_some());
    }

    #[test]
    fn secrets_esc_clears_revealed_secret() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Secrets;
        app.secrets_names = vec!["API_KEY".into()];
        app.revealed_secret = Some(("API_KEY".into(), "sk-abc".into(), std::time::Instant::now()));
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.revealed_secret.is_none());
    }

    #[test]
    fn time_section_classifies_ages() {
        use std::time::{Duration, SystemTime};
        assert_eq!(time_section(None), "Older");
        assert_eq!(time_section(Some(SystemTime::now())), "Today");
        assert_eq!(
            time_section(Some(SystemTime::now() - Duration::from_secs(3600))),
            "Today"
        );
        assert_eq!(
            time_section(Some(SystemTime::now() - Duration::from_secs(90_000))),
            "Yesterday"
        );
        assert_eq!(
            time_section(Some(SystemTime::now() - Duration::from_secs(4 * 86400))),
            "This Week"
        );
        assert_eq!(
            time_section(Some(SystemTime::now() - Duration::from_secs(15 * 86400))),
            "This Month"
        );
        assert_eq!(
            time_section(Some(SystemTime::now() - Duration::from_secs(60 * 86400))),
            "Older"
        );
    }

    #[test]
    fn section_labels_populated_when_sorted_by_modified() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Modified;
        app.apply_filter_and_sort();
        // All test sessions have modified_ts: None → all "Older"
        // So only the first row should have a section label
        assert_eq!(app.section_labels.len(), app.filtered.len());
        assert_eq!(app.section_labels[0], Some("Older"));
        // Remaining should be None (same section)
        for label in &app.section_labels[1..] {
            assert_eq!(*label, None);
        }
    }

    #[test]
    fn section_labels_empty_when_sorted_by_name() {
        let mut app = App::new(sample_sessions());
        app.sort_col = SortColumn::Name;
        app.apply_filter_and_sort();
        assert!(app.section_labels.is_empty());
    }

    #[test]
    fn nav_step_starts_at_one() {
        let mut app = App::new(sample_sessions());
        assert_eq!(app.nav_step('j'), 1);
    }

    #[test]
    fn nav_step_accelerates_on_rapid_repeat() {
        let mut app = App::new(sample_sessions());
        // First 3 presses: step 1
        assert_eq!(app.nav_step('j'), 1);
        assert_eq!(app.nav_step('j'), 1);
        assert_eq!(app.nav_step('j'), 1);
        // Presses 4-8: step 2
        assert_eq!(app.nav_step('j'), 2);
        assert_eq!(app.nav_step('j'), 2);
    }

    #[test]
    fn nav_step_resets_on_direction_change() {
        let mut app = App::new(sample_sessions());
        app.nav_step('j');
        app.nav_step('j');
        app.nav_step('j');
        app.nav_step('j');
        // Changing direction resets
        assert_eq!(app.nav_step('k'), 1);
    }

    #[test]
    fn space_toggles_mark() {
        let mut app = App::new(sample_sessions());
        assert!(app.marked_sessions.is_empty());
        // Mark first session
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert!(app.marked_sessions.contains("alpha"));
        // Toggle off
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert!(!app.marked_sessions.contains("alpha"));
    }

    #[test]
    fn d_uppercase_enters_batch_delete_when_marked() {
        let mut app = App::new(sample_sessions());
        app.marked_sessions.insert("alpha".into());
        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        assert_eq!(app.mode, Mode::ConfirmBatchDelete);
        assert!(app.delete_countdown_start.is_some());
    }

    #[test]
    fn d_uppercase_shows_status_when_no_marks() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("No sessions marked"));
    }

    #[test]
    fn batch_delete_y_rejected_during_countdown() {
        let mut app = App::new(sample_sessions());
        app.marked_sessions.insert("alpha".into());
        app.mode = Mode::ConfirmBatchDelete;
        app.delete_countdown_start = Some(std::time::Instant::now());
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        assert_eq!(app.mode, Mode::ConfirmBatchDelete); // still confirming
    }

    #[test]
    fn batch_delete_n_cancels() {
        let mut app = App::new(sample_sessions());
        app.marked_sessions.insert("alpha".into());
        app.mode = Mode::ConfirmBatchDelete;
        app.delete_countdown_start = Some(std::time::Instant::now());
        app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        assert_eq!(app.mode, Mode::Normal);
        // Marks preserved after cancel
        assert!(app.marked_sessions.contains("alpha"));
    }

    // --- Row expand/collapse with 'p' ---

    #[test]
    fn p_expands_selected_session() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        assert!(app.expanded_session.is_none());
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        assert_eq!(app.expanded_session, Some("alpha".into()));
    }

    #[test]
    fn p_collapses_already_expanded() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.expanded_session = Some("alpha".into());
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        assert!(app.expanded_session.is_none());
    }

    #[test]
    fn p_switches_expansion_to_different_row() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.expanded_session = Some("alpha".into());
        // Move to row 1 and press 'p'
        app.table_state.select(Some(1));
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        assert_eq!(app.expanded_session, Some("beta".into()));
    }

    #[test]
    fn navigation_collapses_expanded() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.expanded_session = Some("alpha".into());
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert!(app.expanded_session.is_none());
    }

    #[test]
    fn p_caches_preview() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        assert!(app.preview_cache.is_empty());
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        app.wait_for_previews();
        // Preview was loaded (even if empty, the key exists)
        assert!(app.preview_cache.contains_key("alpha"));
    }

    #[test]
    fn p_reuses_cached_preview() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        // Pre-populate cache
        app.preview_cache.insert(
            "alpha".into(),
            session::SessionPreview {
                objective: Some("test objective".into()),
                last_discovery: None,
                discoveries: Vec::new(),
                memory_entries: Vec::new(),
                contributors: Vec::new(),
            },
        );
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        // Should use cached value, not overwrite
        let preview = app.preview_cache.get("alpha").unwrap();
        assert_eq!(preview.objective.as_deref(), Some("test objective"));
    }

    // --- Preview pane ---

    #[test]
    fn p_toggles_show_preview() {
        let mut app = App::new(sample_sessions());
        assert!(app.show_preview); // default on
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        assert!(!app.show_preview);
        app.handle_key(KeyEvent::from(KeyCode::Char('p')));
        assert!(app.show_preview);
    }

    #[test]
    fn request_preview_does_not_load_on_the_calling_thread() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.request_preview();
        // The render path calls this every frame; a preview that appeared here
        // would mean the draw blocked on a filesystem read and a `git log`.
        assert!(
            app.preview_cache.is_empty(),
            "request_preview must hand the load to the worker, not run it here"
        );
    }

    #[test]
    fn a_requested_preview_reaches_the_cache() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.request_preview();
        app.wait_for_previews();
        // Loaded for "alpha" (empty metadata, but the entry exists)
        assert!(app.preview_cache.contains_key("alpha"));
    }

    #[test]
    fn request_preview_skips_a_cached_session() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.preview_cache.insert(
            "alpha".into(),
            session::SessionPreview {
                objective: Some("cached".into()),
                last_discovery: None,
                discoveries: Vec::new(),
                memory_entries: Vec::new(),
                contributors: Vec::new(),
            },
        );
        app.request_preview();
        app.wait_for_previews();
        // The worker never ran, so the cached value stands.
        assert_eq!(
            app.preview_cache.get("alpha").unwrap().objective.as_deref(),
            Some("cached")
        );
    }

    #[test]
    fn request_preview_queues_a_session_only_once() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        // Every frame re-requests the selected session while the worker is busy.
        app.request_preview();
        app.request_preview();
        app.request_preview();
        app.wait_for_previews();
        assert!(app.preview_cache.contains_key("alpha"));
        // A second result for the same session would still be sitting in the
        // channel after the first drained it.
        app.drain_previews();
        assert_eq!(app.preview_cache.len(), 1);
    }

    // --- Notes panel focus ---

    #[test]
    fn tab_focuses_notes_input() {
        let mut app = App::new(sample_sessions());
        assert_eq!(app.focus, Focus::List);
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert_eq!(app.focus, Focus::Notes);
    }

    #[test]
    fn tab_opens_preview_pane_if_collapsed() {
        let mut app = App::new(sample_sessions());
        app.show_preview = false;
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert!(app.show_preview);
    }

    #[test]
    fn notes_focused_typing_accumulates() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Char('h')));
        app.handle_key(KeyEvent::from(KeyCode::Char('i')));
        assert_eq!(app.queue_input.text(), "hi");
    }

    #[test]
    fn notes_focused_navigation_keys_do_not_move_list_selection() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        // 'j' is typed into the Notes input, not treated as a navigation key.
        assert_eq!(app.table_state.selected(), Some(0));
        assert_eq!(app.queue_input.text(), "j");
    }

    #[test]
    fn esc_returns_focus_to_list_from_notes() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert_eq!(app.focus, Focus::Notes);
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.focus, Focus::List);
    }

    #[test]
    fn notes_enter_appends_to_queue_file_and_clears_input() {
        let tmp = std::env::temp_dir().join(format!("cs-tui-notes-{}", std::process::id()));
        let _root = session::test_root::scoped(tmp.clone());
        let name = "alpha"; // matches sample_sessions()[0].name
        std::fs::create_dir_all(tmp.join(name).join(".cs/local")).unwrap();
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        for c in "do X".chars() {
            app.handle_key(KeyEvent::from(KeyCode::Char(c)));
        }
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        let q = std::fs::read_to_string(tmp.join(name).join(".cs/local/queue")).unwrap();
        assert!(q.contains("do X"));
        assert_eq!(app.queue_input.text(), "", "Enter must clear the Notes input");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_enter_clears_declined() {
        let tmp = std::env::temp_dir().join(format!("cs-tui-notes-declined-{}", std::process::id()));
        let _root = session::test_root::scoped(tmp.clone());
        let name = "alpha"; // matches sample_sessions()[0].name
        let local = tmp.join(name).join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        // A prior gate decline left this cooldown marker behind.
        std::fs::write(local.join("queue.declined"), "1234567890\n").unwrap();
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        for c in "do Y".chars() {
            app.handle_key(KeyEvent::from(KeyCode::Char(c)));
        }
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(
            !local.join("queue.declined").exists(),
            "adding a task must clear queue.declined so the gate can re-ask"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    // --- Notes panel: delete + edit ---

    /// Seed a session's queue file with the given tasks and return (tmp root, dir).
    fn seed_queue(
        slug: &str,
        name: &str,
        tasks: &[&str],
    ) -> (std::path::PathBuf, std::path::PathBuf, session::test_root::Guard) {
        let tmp = std::env::temp_dir().join(format!("cs-tui-{}-{}", slug, std::process::id()));
        let root = session::test_root::scoped(tmp.clone());
        let local = tmp.join(name).join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        let mut body = String::new();
        for t in tasks {
            body.push_str(t);
            body.push('\n');
        }
        std::fs::write(local.join("queue"), body).unwrap();
        (tmp, local, root)
    }

    #[test]
    fn down_enters_list_and_up_returns_to_input() {
        let (tmp, _local, _root) = seed_queue("notes-nav", "alpha", &["task one", "task two"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert_eq!(app.notes_focus, NotesFocus::Input);
        app.handle_key(KeyEvent::from(KeyCode::Down));
        assert_eq!(app.notes_focus, NotesFocus::List);
        assert_eq!(app.notes_selected, 0);
        app.handle_key(KeyEvent::from(KeyCode::Up));
        assert_eq!(app.notes_focus, NotesFocus::Input);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_list_d_removes_highlighted_task() {
        let (tmp, local, _root) = seed_queue("notes-del", "alpha", &["one", "two", "three"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Down)); // into list, highlight #1
        app.handle_key(KeyEvent::from(KeyCode::Down)); // highlight #2 ("two")
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        let q = std::fs::read_to_string(local.join("queue")).unwrap();
        let lines: Vec<&str> = q.lines().filter(|l| !l.trim().is_empty()).collect();
        assert_eq!(lines, vec!["one", "three"], "deletes exactly the #2 line, order preserved");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_list_e_loads_task_and_enter_replaces_in_place() {
        let (tmp, local, _root) = seed_queue("notes-edit", "alpha", &["one", "two", "three"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Down)); // highlight #1
        app.handle_key(KeyEvent::from(KeyCode::Down)); // highlight #2 ("two")
        app.handle_key(KeyEvent::from(KeyCode::Char('e')));
        assert_eq!(app.notes_focus, NotesFocus::Editing, "in edit mode on row 1");
        assert_eq!(app.queue_input.text(), "two", "task text loaded into the input");
        for c in " X".chars() {
            app.handle_key(KeyEvent::from(KeyCode::Char(c)));
        }
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        let q = std::fs::read_to_string(local.join("queue")).unwrap();
        let lines: Vec<&str> = q.lines().filter(|l| !l.trim().is_empty()).collect();
        assert_eq!(lines, vec!["one", "two X", "three"], "replaces in place, position preserved");
        assert_eq!(app.notes_focus, NotesFocus::List, "back to list after save");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_list_e_then_esc_cancels_edit_unchanged() {
        let (tmp, local, _root) = seed_queue("notes-edit-cancel", "alpha", &["one", "two", "three"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Down));
        app.handle_key(KeyEvent::from(KeyCode::Down)); // highlight #2
        app.handle_key(KeyEvent::from(KeyCode::Char('e')));
        for c in "zzz".chars() {
            app.handle_key(KeyEvent::from(KeyCode::Char(c)));
        }
        app.handle_key(KeyEvent::from(KeyCode::Esc)); // cancel edit
        assert_eq!(app.notes_focus, NotesFocus::List, "edit cancelled, back to list");
        let q = std::fs::read_to_string(local.join("queue")).unwrap();
        let lines: Vec<&str> = q.lines().filter(|l| !l.trim().is_empty()).collect();
        assert_eq!(lines, vec!["one", "two", "three"], "queue unchanged after cancel");
        std::fs::remove_dir_all(&tmp).ok();
    }

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

    // --- Mouse hit-testing with variable-height rows ---

    /// Render once through the real UI at the given size so the renderer
    /// publishes `row_hit_spans` (and `table_area`), then leave `app` ready for
    /// a synthetic mouse event. Width < PREVIEW_MIN_WIDTH keeps the preview pane
    /// (which reads files) closed.
    fn render_for_hit_map(app: &mut App, w: u16, h: u16) {
        let backend = ratatui::backend::TestBackend::new(w, h);
        let mut terminal = ratatui::Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| crate::ui::render(app, frame))
            .unwrap();
    }

    fn left_click(app: &mut App, relative_row: u16, relative_col: u16) -> Action {
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(crossterm::event::MouseButton::Left),
            column: app.table_area.x + relative_col,
            row: app.table_area.y + relative_row,
            modifiers: KeyModifiers::empty(),
        })
    }

    #[test]
    fn mouse_click_below_group_header_selects_correct_session() {
        // Default sort is Modified, and all sample sessions share the "Older"
        // time section, so row 0 carries the section divider and is 2 lines
        // tall. That pushes the 2nd session's line to relative row 4 (base 2 +
        // row 0's height 2), where a naive fixed-stride (base + idx*1) would
        // mis-predict relative row 3 and mis-select index 0.
        let mut app = App::new(sample_sessions());
        render_for_hit_map(&mut app, 100, 24);
        assert_eq!(
            app.row_hit_spans[0].1, 2,
            "row 0 should be 2 lines tall (section label present)"
        );
        // Second session renders one line below where a naive stride expects it.
        let action = left_click(&mut app, 4, 3);
        assert!(matches!(action, Action::None));
        assert_eq!(
            app.table_state.selected(),
            Some(1),
            "click on the 2nd session's line must select index 1, not 0 or 2"
        );
    }

    #[test]
    fn mouse_click_on_group_label_line_selects_that_row() {
        let mut app = App::new(sample_sessions());
        // Start elsewhere so selecting row 0 is a real change.
        app.table_state.select(Some(2));
        render_for_hit_map(&mut app, 100, 24);
        // Relative row 2 is the section divider line belonging to row 0 (the
        // borderless table's header sits at relative row 0, its rule at
        // relative row 1, so data starts at relative row 2).
        let action = left_click(&mut app, 2, 3);
        assert!(matches!(action, Action::None));
        assert_eq!(
            app.table_state.selected(),
            Some(0),
            "clicking a row's group-label line selects that row's session"
        );
    }

    /// Two sessions in "Today" (rows 0-1), two in "Older" (rows 2-3) — the
    /// second section opens with a blank spacer line ahead of its divider,
    /// unlike the first section which has none.
    fn two_section_sessions() -> Vec<Session> {
        use std::time::{Duration, SystemTime};
        let session = |name: &str, age_secs: u64| Session {
            name: name.into(),
            is_adopted: false,
            created: Some("2026-01-01 10:00".into()),
            modified: Some("2026-02-20 14:00".into()),
            modified_ts: Some(SystemTime::now() - Duration::from_secs(age_secs)),
            lock_pid: None,
            is_locked: false,
            secrets_count: 0,
            queue_depth: 0,
            git_repo: None,
            tags: Vec::new(),
        };
        vec![
            session("today-a", 0),
            session("today-b", 3600),
            session("older-c", 400 * 86400),
            session("older-d", 401 * 86400),
        ]
    }

    #[test]
    fn mouse_click_on_spacer_row_before_later_section_selects_that_row() {
        // Row 2 ("older-c") opens the second section, so it leads with a blank
        // spacer line *and* the divider (height 3), not just the divider (height
        // 2) the first section gets. A hit-map that forgot the spacer would
        // under-count every later row's start, mis-selecting on click.
        let mut app = App::new(two_section_sessions());
        render_for_hit_map(&mut app, 100, 24);
        assert_eq!(
            app.row_hit_spans,
            vec![(2, 2, 0), (4, 1, 1), (5, 3, 2), (8, 1, 3)],
            "row heights/offsets must include the spacer before the second section"
        );
        // Relative row 5 is the blank spacer line ahead of "older-c"'s divider.
        let action = left_click(&mut app, 5, 3);
        assert!(matches!(action, Action::None));
        assert_eq!(
            app.table_state.selected(),
            Some(2),
            "clicking the spacer line above a later section must select that section's first row"
        );
    }

    #[test]
    fn mouse_click_in_right_pane_does_not_select_a_session() {
        // At >= PREVIEW_MIN_WIDTH (120), with the detail panes on, the layout is
        // SideBySide: the session table is the left ~60%, the To-Do/detail views
        // the right ~40%. A left-click in that right region must not hit-test
        // against the left session list.
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(2));
        render_for_hit_map(&mut app, 140, 24);
        assert!(
            app.table_area.width < 140,
            "test needs a side-by-side split (table narrower than the window)"
        );
        // Absolute column just past the table's right edge, inside the right pane,
        // on a row that aligns to a session line.
        let right_col = app.table_area.x + app.table_area.width + 2;
        let action = app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(crossterm::event::MouseButton::Left),
            column: right_col,
            row: app.table_area.y + 4,
            modifiers: KeyModifiers::empty(),
        });
        assert!(matches!(action, Action::None));
        assert_eq!(
            app.table_state.selected(),
            Some(2),
            "a click in the right (To-Do/detail) pane must not change the left session selection"
        );
    }

    #[test]
    fn mouse_click_selecting_a_row_resets_notes_selected() {
        let mut app = App::new(sample_sessions());
        render_for_hit_map(&mut app, 100, 24);
        // A stale Notes list highlight from a prior panel interaction.
        app.notes_selected = 3;
        assert_eq!(app.table_state.selected(), Some(0));
        // Click the 2nd session's line (relative row 4 given row 0's 2-line span).
        let action = left_click(&mut app, 4, 3);
        assert!(matches!(action, Action::None));
        assert_eq!(app.table_state.selected(), Some(1));
        assert_eq!(
            app.notes_selected, 0,
            "switching sessions by click resets the Notes list highlight"
        );
    }

    // --- Queue mutations keep the To-Do column in sync ---

    #[test]
    fn append_notes_task_updates_queue_depth_and_todo_visibility() {
        let (tmp, _local, _root) = seed_queue("depth-append", "alpha", &[]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        // sample_sessions()[0] (alpha) starts with no queued tasks.
        assert_eq!(app.selected_session().unwrap().queue_depth, 0);
        assert!(!app.has_todos());
        app.append_notes_task("alpha", "first task");
        assert_eq!(
            app.selected_session().unwrap().queue_depth,
            1,
            "append must bump the in-memory queue_depth"
        );
        assert!(
            app.has_todos(),
            "queuing the first task makes the To-Do column appear"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn delete_notes_task_decrements_queue_depth() {
        let (tmp, _local, _root) = seed_queue("depth-del", "alpha", &["one", "two"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        // Prime the in-memory depth to match the seeded file (two tasks).
        app.refresh_queue_depth("alpha");
        assert_eq!(app.selected_session().unwrap().queue_depth, 2);
        app.notes_selected = 0;
        app.delete_notes_task(0); // remove "one"
        assert_eq!(
            app.selected_session().unwrap().queue_depth,
            1,
            "delete must decrement the in-memory queue_depth"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn mouse_click_on_header_row_cycles_sort_on_borderless_table() {
        // The table has no Block/border, so the header sits at relative row 0
        // (not the old bordered layout's relative row 2). A click there must
        // still resolve to the clicked column and cycle its sort.
        let mut app = App::new(sample_sessions());
        render_for_hit_map(&mut app, 100, 24);
        assert_eq!(app.sort_col, SortColumn::Modified, "default sort is Modified");
        // Column 3 (just past the highlight gutter) is inside the Session
        // column's header cell.
        let action = left_click(&mut app, 0, 3);
        assert!(matches!(action, Action::None));
        assert_eq!(
            app.sort_col,
            SortColumn::Name,
            "clicking the Session header cell should sort by Name"
        );
    }
}
