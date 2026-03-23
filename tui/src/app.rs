// ABOUTME: Application state machine that processes keyboard input and manages UI modes
// ABOUTME: Tracks table selection, sort order, search filter, and modal dialog state

use std::collections::HashMap;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use ratatui::widgets::TableState;

use crate::session::{self, Session};

/// Editable text buffer with cursor position tracking.
/// Cursor is stored as a byte offset, always on a char boundary.
pub struct TextInput {
    text: String,
    cursor: usize,
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
    let text_lower: Vec<char> = text.to_lowercase().chars().collect();

    let mut indices = Vec::with_capacity(pattern_lower.len());
    let mut ti = 0;

    for &pc in &pattern_lower {
        let mut found = false;
        while ti < text_lower.len() {
            if text_lower[ti] == pc {
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortColumn {
    Name,
    Created,
    Modified,
    Secrets,
    Remote,
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
    MoveToRemote,
    CreateSession,
    Secrets,
    Syncing,
    SyncOutput(String),
}

pub const MENU_ITEMS: &[(&str, &str)] = &[
    ("Open", "Enter"),
    ("Delete", "d"),
    ("Rename", "r"),
    ("Move to Remote", "m"),
    ("Secrets", "s"),
    ("Push", "P"),
    ("Pull", "L"),
    ("Status", "S"),
];

pub enum Action {
    None,
    Quit,
    Open(String),
    ForceOpen(String),
    MoveTo(String, String),
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

pub struct SyncJob {
    pub session_name: String,
    pub subcommand: String,
    pub receiver: std::sync::mpsc::Receiver<SyncResult>,
    pub started: std::time::Instant,
}

pub struct SyncResult {
    pub success: bool,
    pub output: String,
}

pub const SPINNER_FRAMES: &[char] = &['\u{280b}', '\u{2819}', '\u{2839}', '\u{2838}', '\u{283c}', '\u{2834}', '\u{2826}', '\u{2827}', '\u{2807}', '\u{280f}'];

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
    pub move_to_input: TextInput,
    pub create_input: TextInput,
    pub secrets_names: Vec<String>,
    pub secrets_selected: usize,
    pub return_to_secrets: bool,
    pub menu_selected: usize,
    pub status_message: Option<StatusMessage>,
    pub row_flashes: HashMap<String, (FlashKind, std::time::Instant)>,
    pub table_area: ratatui::layout::Rect,
    pub column_widths: Vec<u16>,
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
    /// Background sync operation in progress.
    pub sync_job: Option<SyncJob>,
    /// Whether to show the preview pane on wide terminals (toggled with `p`).
    pub show_preview: bool,
}

impl App {
    pub fn new(sessions: Vec<Session>) -> Self {
        let filtered: Vec<usize> = (0..sessions.len()).collect();
        let mut table_state = TableState::default();
        if !sessions.is_empty() {
            table_state.select(Some(0));
        }
        App {
            sessions,
            filtered,
            table_state,
            mode: Mode::Normal,
            table_area: ratatui::layout::Rect::default(),
            column_widths: Vec::new(),
            sort_col: SortColumn::Name,
            sort_dir: SortDirection::Asc,
            search_input: TextInput::new(),
            rename_input: TextInput::new(),
            move_to_input: TextInput::new(),
            create_input: TextInput::new(),
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
            sync_job: None,
            show_preview: true,
        }
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

    /// Ensure the selected session's preview is loaded into the cache.
    pub fn ensure_preview_loaded(&mut self) {
        if let Some(name) = self.selected_session_name() {
            if !self.preview_cache.contains_key(&name) {
                let root = session::sessions_root();
                let preview = session::load_preview(&root.join(&name));
                self.preview_cache.insert(name, preview);
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
                    SortColumn::Remote => sa.location.cmp(&sb.location),
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
            Mode::MoveToRemote => self.handle_move_to_remote(key),
            Mode::Secrets => self.handle_secrets(key),
            Mode::Syncing => {
                if key.code == KeyCode::Esc {
                    self.sync_job = None;
                    self.mode = Mode::Normal;
                    self.set_status("Sync cancelled", StatusLevel::Info);
                }
                Action::None
            }
            Mode::SyncOutput(_) => {
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
            KeyCode::Char('P') => {
                self.start_sync("push");
                Action::None
            }
            KeyCode::Char('L') => {
                self.start_sync("pull");
                Action::None
            }
            KeyCode::Char('S') => {
                self.start_sync("status");
                Action::None
            }
            KeyCode::Char('m') => {
                if let Some(session) = self.selected_session() {
                    if session.location.is_some() {
                        self.set_status("Session is already remote", StatusLevel::Info);
                    } else {
                        self.move_to_input.clear();
                        self.mode = Mode::MoveToRemote;
                    }
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
                self.cycle_sort(SortColumn::Remote);
                Action::None
            }
            KeyCode::Char('6') => {
                self.cycle_sort(SortColumn::Github);
                Action::None
            }
            KeyCode::Tab => {
                if let Some(name) = self.selected_session_name() {
                    if self.expanded_session.as_deref() == Some(&name) {
                        self.expanded_session = None;
                    } else {
                        // Load preview if not cached
                        if !self.preview_cache.contains_key(&name) {
                            let root = session::sessions_root();
                            let preview = session::load_preview(&root.join(&name));
                            self.preview_cache.insert(name.clone(), preview);
                        }
                        self.expanded_session = Some(name);
                    }
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
                Action::None
            }
            _ => Action::None,
        }
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
            KeyCode::Char('m') => self.execute_menu_action(3),
            KeyCode::Char('s') => self.execute_menu_action(4),
            KeyCode::Char('P') => self.execute_menu_action(5),
            KeyCode::Char('L') => self.execute_menu_action(6),
            KeyCode::Char('S') => self.execute_menu_action(7),
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
                // Move to Remote
                if let Some(session) = self.selected_session() {
                    if session.location.is_some() {
                        self.set_status("Session is already remote", StatusLevel::Info);
                    } else {
                        self.move_to_input.clear();
                        self.mode = Mode::MoveToRemote;
                    }
                }
                Action::None
            }
            4 => {
                // Secrets
                self.run_secrets_command();
                Action::None
            }
            5 => {
                // Push
                self.start_sync("push");
                Action::None
            }
            6 => {
                // Pull
                self.start_sync("pull");
                Action::None
            }
            7 => {
                // Status
                self.start_sync("status");
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
                // Commit: filter to matches only
                self.apply_filter_and_sort();
                self.mode = Mode::Normal;
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
                self.update_search_highlights();
            }
            KeyCode::Backspace => {
                self.search_input.delete_back();
                self.update_search_highlights();
            }
            KeyCode::Char(c) => {
                self.search_input.insert(c);
                self.update_search_highlights();
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
        if !name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_' || c == '.' || c == ' ')
        {
            self.set_status("Invalid characters in name", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        let root = session::sessions_root();
        if root.join(&name).exists() {
            self.set_status("Session already exists", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        self.mode = Mode::Normal;
        Action::Open(name)
    }

    fn handle_move_to_remote(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                return self.execute_move_to();
            }
            KeyCode::Left => {
                self.move_to_input.move_left();
            }
            KeyCode::Right => {
                self.move_to_input.move_right();
            }
            KeyCode::Home => {
                self.move_to_input.move_home();
            }
            KeyCode::End => {
                self.move_to_input.move_end();
            }
            KeyCode::Delete => {
                self.move_to_input.delete_forward();
            }
            KeyCode::Backspace => {
                self.move_to_input.delete_back();
            }
            KeyCode::Char(c) => {
                self.move_to_input.insert(c);
            }
            _ => {}
        }
        Action::None
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

    fn clamp_selection(&mut self) {
        if let Some(sel) = self.table_state.selected() {
            if sel >= self.filtered.len() && !self.filtered.is_empty() {
                self.table_state.select(Some(self.filtered.len() - 1));
            }
        }
    }

    fn execute_delete(&mut self) {
        if let Some(session) = self.selected_session() {
            let root = session::sessions_root();
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
        let root = session::sessions_root();
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
        if !new_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_' || c == '.' || c == ' ')
        {
            self.set_status("Invalid characters in name", StatusLevel::Error);
            self.mode = Mode::Normal;
            return;
        }

        if let Some(session) = self.selected_session() {
            let root = session::sessions_root();
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

    fn start_sync(&mut self, subcommand: &str) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let subcmd = subcommand.to_string();
            let (tx, rx) = std::sync::mpsc::channel();

            let session_name = name.clone();
            std::thread::spawn(move || {
                let output = std::process::Command::new("cs")
                    .args([&session_name, "-sync", &subcmd])
                    .output();
                let result = match output {
                    Ok(out) => {
                        let text = String::from_utf8_lossy(&out.stdout).to_string()
                            + &String::from_utf8_lossy(&out.stderr).to_string();
                        SyncResult {
                            success: out.status.success(),
                            output: text,
                        }
                    }
                    Err(e) => SyncResult {
                        success: false,
                        output: format!("Sync failed: {}", e),
                    },
                };
                let _ = tx.send(result);
            });

            self.sync_job = Some(SyncJob {
                session_name: name,
                subcommand: subcommand.to_string(),
                receiver: rx,
                started: std::time::Instant::now(),
            });
            self.mode = Mode::Syncing;
        }
    }

    /// Poll the background sync job. Called each event loop tick.
    pub fn check_sync(&mut self) {
        let job = match self.sync_job.take() {
            Some(j) => j,
            None => return,
        };

        match job.receiver.try_recv() {
            Ok(result) => {
                let kind = if result.success {
                    FlashKind::Success
                } else {
                    FlashKind::Error
                };
                self.flash_row(&job.session_name, kind);
                if result.output.trim().is_empty() {
                    let label = if result.success { "completed" } else { "failed" };
                    self.set_status(
                        format!("Sync {} {}", job.subcommand, label),
                        if result.success { StatusLevel::Success } else { StatusLevel::Error },
                    );
                    self.mode = Mode::Normal;
                } else {
                    self.mode = Mode::SyncOutput(result.output);
                }
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => {
                // Still running — put the job back
                self.sync_job = Some(job);
            }
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                // Thread panicked or dropped sender
                self.flash_row(&job.session_name, FlashKind::Error);
                self.set_status("Sync process lost", StatusLevel::Error);
                self.mode = Mode::Normal;
            }
        }
    }

    /// Current spinner frame character for the active sync job.
    pub fn spinner_frame(&self) -> char {
        if let Some(ref job) = self.sync_job {
            let elapsed_ms = job.started.elapsed().as_millis() as usize;
            let idx = (elapsed_ms / 80) % SPINNER_FRAMES.len();
            SPINNER_FRAMES[idx]
        } else {
            SPINNER_FRAMES[0]
        }
    }

    fn execute_move_to(&mut self) -> Action {
        let host = self.move_to_input.text().trim().to_string();
        if host.is_empty() {
            self.set_status("Host cannot be empty", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        if host.contains(char::is_whitespace) {
            self.set_status("Host cannot contain spaces", StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        if let Some(name) = self.selected_session_name() {
            self.mode = Mode::Normal;
            return Action::MoveTo(name, host);
        }
        self.mode = Mode::Normal;
        Action::None
    }

    fn run_secrets_command(&mut self) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new("cs")
                .args([&name, "-secrets", "list"])
                .output();
            match output {
                Ok(out) => {
                    let text = String::from_utf8_lossy(&out.stdout).to_string();
                    self.secrets_names = Self::parse_secrets_list(&text);
                    self.secrets_selected = 0;
                    self.mode = Mode::Secrets;
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
                    self.mode = Mode::SyncOutput(text);
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
                Ok(out) => {
                    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    self.revealed_secret =
                        Some((key_name.to_string(), value, std::time::Instant::now()));
                }
                Err(e) => {
                    self.set_status(format!("Peek failed: {}", e), StatusLevel::Error);
                }
            }
        }
    }

    pub fn has_remote_sessions(&self) -> bool {
        self.sessions.iter().any(|s| s.location.is_some())
    }

    pub fn has_git_sessions(&self) -> bool {
        self.sessions.iter().any(|s| s.git_repo.is_some())
    }

    pub fn has_secrets(&self) -> bool {
        self.sessions.iter().any(|s| s.secrets_count > 0)
    }

    pub fn handle_mouse(&mut self, mouse: MouseEvent) -> Action {
        if self.mode != Mode::Normal {
            return Action::None;
        }

        match mouse.kind {
            MouseEventKind::ScrollUp => {
                self.table_state.select_previous();
                Action::None
            }
            MouseEventKind::ScrollDown => {
                self.table_state.select_next();
                self.clamp_selection();
                Action::None
            }
            MouseEventKind::Down(crossterm::event::MouseButton::Left) => {
                let row = mouse.row;
                let col = mouse.column;

                // Check if click is within the table area
                if row >= self.table_area.y && col >= self.table_area.x {
                    let relative_row = row - self.table_area.y;

                    // Row 0 is the border, row 1 is the title, row 2 is header, row 3 is separator
                    if relative_row == 2 {
                        // Header click — determine which column
                        if let Some(sort_col) = self.column_at_x(col) {
                            self.cycle_sort(sort_col);
                        }
                    } else if relative_row >= 4 {
                        // Data row click
                        let data_row = (relative_row - 4) as usize + self.table_state.offset();
                        if data_row < self.filtered.len() {
                            self.table_state.select(Some(data_row));
                        }
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
        let mut offset = self.table_area.x + 1; // +1 for border
        offset += 3; // highlight_symbol ">> " width
        for (i, &width) in self.column_widths.iter().enumerate() {
            if x >= offset && x < offset + width + 3 {
                return self.visible_sort_columns.get(i).copied();
            }
            offset += width + 3; // +3 for column_spacing(3)
        }
        None
    }
}

/// Rename the Claude Code conversation history directory to match the session rename.
/// Claude stores conversations under ~/.claude/projects/ keyed by encoded absolute path.
/// Path encoding: replace '/' and '.' with '-'.
fn rename_claude_projects_dir(old_session_path: &std::path::Path, new_session_path: &std::path::Path) {
    fn encode_path(p: &std::path::Path) -> String {
        p.to_string_lossy().replace('/', "-").replace('.', "-")
    }

    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return,
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
                location: None,
                lock_pid: None,
                is_locked: false,
                secrets_count: 0,
                has_git: true,
                git_repo: Some("hex/alpha".into()),
                sync_auto: None,
            },
            Session {
                name: "beta".into(),
                is_adopted: false,
                created: Some("2026-02-01 10:00".into()),
                modified: Some("2026-02-15 09:00".into()),
                modified_ts: None,
                location: Some("hex@mini".into()),
                lock_pid: None,
                is_locked: false,
                secrets_count: 2,
                has_git: true,
                git_repo: Some("hex/beta".into()),
                sync_auto: Some(true),
            },
            Session {
                name: "gamma".into(),
                is_adopted: true,
                created: Some("2025-12-01 10:00".into()),
                modified: Some("2026-01-10 08:00".into()),
                modified_ts: None,
                location: None,
                lock_pid: Some(12345),
                is_locked: true,
                secrets_count: 0,
                has_git: false,
                git_repo: None,
                sync_auto: None,
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
        assert_eq!(app.sort_col, SortColumn::Name);
        assert_eq!(app.sort_dir, SortDirection::Asc);

        app.cycle_sort(SortColumn::Name);
        assert_eq!(app.sort_dir, SortDirection::Desc);

        app.cycle_sort(SortColumn::Name);
        assert_eq!(app.sort_dir, SortDirection::Asc);
    }

    #[test]
    fn cycle_sort_switches_column() {
        let mut app = App::new(sample_sessions());
        app.cycle_sort(SortColumn::Created);
        assert_eq!(app.sort_col, SortColumn::Created);
        assert_eq!(app.sort_dir, SortDirection::Asc);
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
    fn search_typing_highlights_but_keeps_all_visible() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('b')));
        app.handle_key(KeyEvent::from(KeyCode::Char('e')));
        assert_eq!(app.search_input.text(), "be");
        // All sessions still visible during typing (highlight-only phase)
        assert_eq!(app.filtered.len(), 3);
        // But fuzzy indices populated for matching session
        assert!(!app.fuzzy_indices.is_empty());
    }

    #[test]
    fn search_esc_clears_and_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('x')));
        // All sessions still visible during typing
        assert_eq!(app.filtered.len(), 3);

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.search_input.text(), "");
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
    fn has_remote_sessions_detects_remotes() {
        let app = App::new(sample_sessions());
        assert!(app.has_remote_sessions());
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
    fn m_on_local_session_enters_move_to_remote() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is local (location=None)
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert_eq!(app.mode, Mode::MoveToRemote);
        assert_eq!(app.move_to_input.text(), "");
    }

    #[test]
    fn m_on_remote_session_shows_status() {
        let mut app = App::new(sample_sessions());
        // beta (index 1) is remote (location=Some)
        app.table_state.select(Some(1));
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("already remote"));
    }

    #[test]
    fn move_to_remote_esc_cancels() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input.set("somehost");
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn move_to_remote_chars_accumulate() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        app.handle_key(KeyEvent::from(KeyCode::Char('i')));
        app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        app.handle_key(KeyEvent::from(KeyCode::Char('i')));
        assert_eq!(app.move_to_input.text(), "mini");
    }

    #[test]
    fn move_to_remote_backspace_removes() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input.set("min");
        app.handle_key(KeyEvent::from(KeyCode::Backspace));
        assert_eq!(app.move_to_input.text(), "mi");
    }

    #[test]
    fn move_to_remote_enter_returns_move_to_action() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is selected
        app.mode = Mode::MoveToRemote;
        app.move_to_input.set("mini");
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::MoveTo(name, host) if name == "alpha" && host == "mini"));
    }

    #[test]
    fn move_to_remote_empty_input_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input.set("");
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("empty"));
    }

    #[test]
    fn move_to_remote_whitespace_input_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input.set("bad host");
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("spaces"));
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
    fn sync_output_returns_to_secrets_when_flagged() {
        let mut app = App::new(sample_sessions());
        app.secrets_names = vec!["KEY1".into(), "KEY2".into()];
        app.secrets_selected = 0;
        app.return_to_secrets = true;
        app.mode = Mode::SyncOutput("value: 123".into());
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert_eq!(app.mode, Mode::Secrets);
        assert!(!app.return_to_secrets);
    }

    #[test]
    fn sync_output_returns_to_normal_when_not_flagged() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SyncOutput("some output".into());
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
    fn menu_shortcut_m_on_local_enters_move() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is local
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert_eq!(app.mode, Mode::MoveToRemote);
    }

    #[test]
    fn menu_shortcut_m_on_remote_shows_status() {
        let mut app = App::new(sample_sessions());
        // beta (index 1) is remote
        app.table_state.select(Some(1));
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().text.contains("already remote"));
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

        // Override HOME so the function finds our fake .claude/projects
        let real_home = std::env::var("HOME").unwrap();
        std::env::set_var("HOME", &tmp);

        rename_claude_projects_dir(&old_session, &new_session);

        std::env::set_var("HOME", &real_home);

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

        let real_home = std::env::var("HOME").unwrap();
        std::env::set_var("HOME", &tmp);

        // Should not panic even if .claude/projects doesn't exist
        rename_claude_projects_dir(
            &std::path::PathBuf::from("/fake/old"),
            &std::path::PathBuf::from("/fake/new"),
        );

        std::env::set_var("HOME", &real_home);
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
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.create_input.set("brand-new-session");
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::Open(name) if name == "brand-new-session"));
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
    fn fuzzy_match_filter_replaces_substring() {
        // Verify fuzzy match handles cases that substring wouldn't
        let result = fuzzy_match("cs", "claude-sessions");
        assert!(result.is_some());
        let (_, indices) = result.unwrap();
        // c=0, s=7 (sessions)
        assert_eq!(indices[0], 0);
    }

    #[test]
    fn search_typing_highlights_without_filtering() {
        let mut app = App::new(sample_sessions());
        // Enter search mode
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        assert_eq!(app.mode, Mode::Search);
        // Type "al" — should match "alpha"
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        app.handle_key(KeyEvent::from(KeyCode::Char('l')));
        // All 3 sessions still visible (not filtered yet)
        assert_eq!(app.filtered.len(), 3);
        // But fuzzy_indices only has the matching session
        assert!(app.fuzzy_indices.values().any(|v| !v.is_empty()));
    }

    #[test]
    fn search_enter_commits_filter() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        app.handle_key(KeyEvent::from(KeyCode::Char('l')));
        // All still visible during typing
        assert_eq!(app.filtered.len(), 3);
        // Commit with Enter
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        // Now filtered to matches only
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

    // --- Row expand/collapse with Tab ---

    #[test]
    fn tab_expands_selected_session() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        assert!(app.expanded_session.is_none());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert_eq!(app.expanded_session, Some("alpha".into()));
    }

    #[test]
    fn tab_collapses_already_expanded() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.expanded_session = Some("alpha".into());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert!(app.expanded_session.is_none());
    }

    #[test]
    fn tab_switches_expansion_to_different_row() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.expanded_session = Some("alpha".into());
        // Move to row 1 and press Tab
        app.table_state.select(Some(1));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
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
    fn tab_caches_preview() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        assert!(app.preview_cache.is_empty());
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        // Preview was loaded (even if empty, the key exists)
        assert!(app.preview_cache.contains_key("alpha"));
    }

    // --- Async sync with spinner ---

    fn make_sync_job(session_name: &str, subcommand: &str) -> (std::sync::mpsc::Sender<SyncResult>, SyncJob) {
        let (tx, rx) = std::sync::mpsc::channel();
        let job = SyncJob {
            session_name: session_name.to_string(),
            subcommand: subcommand.to_string(),
            receiver: rx,
            started: std::time::Instant::now(),
        };
        (tx, job)
    }

    #[test]
    fn check_sync_noop_when_no_job() {
        let mut app = App::new(sample_sessions());
        app.check_sync(); // should not panic
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn check_sync_stays_syncing_while_pending() {
        let mut app = App::new(sample_sessions());
        let (_tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;
        app.check_sync();
        assert_eq!(app.mode, Mode::Syncing);
        assert!(app.sync_job.is_some());
    }

    #[test]
    fn check_sync_transitions_to_output_on_success() {
        let mut app = App::new(sample_sessions());
        let (tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        tx.send(SyncResult {
            success: true,
            output: "Pushed OK".to_string(),
        })
        .unwrap();

        app.check_sync();
        assert!(matches!(app.mode, Mode::SyncOutput(ref s) if s == "Pushed OK"));
        assert!(app.sync_job.is_none());
    }

    #[test]
    fn check_sync_transitions_to_normal_on_empty_output() {
        let mut app = App::new(sample_sessions());
        let (tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        tx.send(SyncResult {
            success: true,
            output: "  ".to_string(),
        })
        .unwrap();

        app.check_sync();
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.is_some());
    }

    #[test]
    fn check_sync_flashes_error_on_failure() {
        let mut app = App::new(sample_sessions());
        let (tx, job) = make_sync_job("alpha", "pull");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        tx.send(SyncResult {
            success: false,
            output: "Error: no remote".to_string(),
        })
        .unwrap();

        app.check_sync();
        assert!(matches!(app.mode, Mode::SyncOutput(ref s) if s == "Error: no remote"));
        assert!(app.row_flashes.contains_key("alpha"));
    }

    #[test]
    fn check_sync_handles_disconnected_sender() {
        let mut app = App::new(sample_sessions());
        let (tx, job) = make_sync_job("alpha", "status");
        drop(tx); // simulate thread panic / drop
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        app.check_sync();
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.is_some());
    }

    #[test]
    fn syncing_mode_esc_cancels() {
        let mut app = App::new(sample_sessions());
        let (_tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.sync_job.is_none());
    }

    #[test]
    fn syncing_mode_ignores_other_keys() {
        let mut app = App::new(sample_sessions());
        let (_tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        app.mode = Mode::Syncing;

        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.mode, Mode::Syncing); // not normal
        assert!(app.sync_job.is_some());
    }

    #[test]
    fn spinner_frame_returns_valid_char() {
        let mut app = App::new(sample_sessions());
        let (_tx, job) = make_sync_job("alpha", "push");
        app.sync_job = Some(job);
        let frame = app.spinner_frame();
        assert!(SPINNER_FRAMES.contains(&frame));
    }

    #[test]
    fn tab_reuses_cached_preview() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        // Pre-populate cache
        app.preview_cache.insert(
            "alpha".into(),
            session::SessionPreview {
                objective: Some("test objective".into()),
                last_discovery: None,
                artifact_count: 3,
                discoveries: Vec::new(),
                artifact_names: Vec::new(),
                memory_entries: Vec::new(),
            },
        );
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        // Should use cached value, not overwrite
        let preview = app.preview_cache.get("alpha").unwrap();
        assert_eq!(preview.objective.as_deref(), Some("test objective"));
        assert_eq!(preview.artifact_count, 3);
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
    fn ensure_preview_loaded_caches_on_first_call() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        assert!(app.preview_cache.is_empty());
        app.ensure_preview_loaded();
        // Preview was loaded for "alpha" (even if empty metadata)
        assert!(app.preview_cache.contains_key("alpha"));
    }

    #[test]
    fn ensure_preview_loaded_skips_if_cached() {
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.preview_cache.insert(
            "alpha".into(),
            session::SessionPreview {
                objective: Some("cached".into()),
                last_discovery: None,
                artifact_count: 0,
                discoveries: Vec::new(),
                artifact_names: Vec::new(),
                memory_entries: Vec::new(),
            },
        );
        app.ensure_preview_loaded();
        // Should not overwrite cached value
        assert_eq!(
            app.preview_cache.get("alpha").unwrap().objective.as_deref(),
            Some("cached")
        );
    }
}
