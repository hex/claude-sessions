// ABOUTME: Application state machine that processes keyboard input and manages UI modes
// ABOUTME: Tracks table selection, sort order, search filter, and modal dialog state

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use ratatui::widgets::TableState;

use crate::session::{self, Session};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortColumn {
    Name,
    Created,
    Modified,
    Secrets,
    Remote,
    Github,
}

pub const SORT_COLUMNS: &[SortColumn] = &[
    SortColumn::Name,
    SortColumn::Created,
    SortColumn::Modified,
    SortColumn::Secrets,
    SortColumn::Remote,
    SortColumn::Github,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortDirection {
    Asc,
    Desc,
}

#[derive(Debug, PartialEq)]
pub enum Mode {
    Normal,
    Search,
    ConfirmDelete,
    Rename,
    SyncOutput(String),
}

pub enum Action {
    None,
    Quit,
    Open(String),
}

pub struct App {
    pub sessions: Vec<Session>,
    pub filtered: Vec<usize>,
    pub table_state: TableState,
    pub mode: Mode,
    pub sort_col: SortColumn,
    pub sort_dir: SortDirection,
    pub search_query: String,
    pub rename_input: String,
    pub status_message: Option<String>,
    pub table_area: ratatui::layout::Rect,
    pub column_widths: Vec<u16>,
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
            search_query: String::new(),
            rename_input: String::new(),
            status_message: None,
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

    pub fn apply_filter_and_sort(&mut self) {
        let query = self.search_query.to_lowercase();
        self.filtered = self
            .sessions
            .iter()
            .enumerate()
            .filter(|(_, s)| query.is_empty() || s.name.to_lowercase().contains(&query))
            .map(|(i, _)| i)
            .collect();

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

        // Clamp selection
        if self.filtered.is_empty() {
            self.table_state.select(None);
        } else if let Some(sel) = self.table_state.selected() {
            if sel >= self.filtered.len() {
                self.table_state.select(Some(self.filtered.len() - 1));
            }
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
            Mode::ConfirmDelete => self.handle_confirm_delete(key),
            Mode::Rename => self.handle_rename(key),
            Mode::SyncOutput(_) => {
                self.mode = Mode::Normal;
                Action::None
            }
        }
    }

    fn handle_normal(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => Action::Quit,
            KeyCode::Enter => {
                if let Some(name) = self.selected_session_name() {
                    Action::Open(name)
                } else {
                    Action::None
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.table_state.select_next();
                self.clamp_selection();
                Action::None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.table_state.select_previous();
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
                self.search_query.clear();
                Action::None
            }
            KeyCode::Char('d') => {
                if self.selected_session().is_some() {
                    self.mode = Mode::ConfirmDelete;
                }
                Action::None
            }
            KeyCode::Char('r') => {
                if let Some(name) = self.selected_session_name() {
                    self.rename_input = name;
                    self.mode = Mode::Rename;
                }
                Action::None
            }
            KeyCode::Char('P') => {
                self.run_sync_command("push");
                Action::None
            }
            KeyCode::Char('L') => {
                self.run_sync_command("pull");
                Action::None
            }
            KeyCode::Char('S') => {
                self.run_sync_command("status");
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
            _ => Action::None,
        }
    }

    fn handle_search(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.search_query.clear();
                self.apply_filter_and_sort();
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                self.mode = Mode::Normal;
            }
            KeyCode::Backspace => {
                self.search_query.pop();
                self.apply_filter_and_sort();
            }
            KeyCode::Char(c) => {
                self.search_query.push(c);
                self.apply_filter_and_sort();
            }
            _ => {}
        }
        Action::None
    }

    fn handle_confirm_delete(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => {
                self.execute_delete();
            }
            _ => {
                self.mode = Mode::Normal;
            }
        }
        Action::None
    }

    fn handle_rename(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                self.execute_rename();
            }
            KeyCode::Backspace => {
                self.rename_input.pop();
            }
            KeyCode::Char(c) => {
                self.rename_input.push(c);
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
                    self.status_message = Some(format!("Deleted: {}", session.name));
                    self.sessions = session::scan_sessions();
                    self.apply_filter_and_sort();
                }
                Err(e) => {
                    self.status_message = Some(format!("Delete failed: {}", e));
                }
            }
        }
        self.mode = Mode::Normal;
    }

    fn execute_rename(&mut self) {
        let new_name = self.rename_input.trim().to_string();
        if new_name.is_empty() {
            self.status_message = Some("Name cannot be empty".to_string());
            self.mode = Mode::Normal;
            return;
        }
        if !new_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_' || c == '.' || c == ' ')
        {
            self.status_message = Some("Invalid characters in name".to_string());
            self.mode = Mode::Normal;
            return;
        }

        if let Some(session) = self.selected_session() {
            let root = session::sessions_root();
            let old = root.join(&session.name);
            let new = root.join(&new_name);
            if new.exists() {
                self.status_message = Some("Name already taken".to_string());
            } else {
                match std::fs::rename(&old, &new) {
                    Ok(()) => {
                        self.status_message = Some(format!("Renamed to: {}", new_name));
                        self.sessions = session::scan_sessions();
                        self.apply_filter_and_sort();
                    }
                    Err(e) => {
                        self.status_message = Some(format!("Rename failed: {}", e));
                    }
                }
            }
        }
        self.mode = Mode::Normal;
    }

    fn run_sync_command(&mut self, subcommand: &str) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new("cs")
                .args([&name, "-sync", subcommand])
                .output();
            match output {
                Ok(out) => {
                    let text = String::from_utf8_lossy(&out.stdout).to_string()
                        + &String::from_utf8_lossy(&out.stderr).to_string();
                    self.mode = Mode::SyncOutput(text);
                }
                Err(e) => {
                    self.status_message = Some(format!("Sync failed: {}", e));
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
            if x >= offset && x < offset + width + 1 {
                return SORT_COLUMNS.get(i).copied();
            }
            offset += width + 1; // +1 for column spacing
        }
        None
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
                location: None,
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
                location: Some("hex@mini".into()),
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
                location: None,
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
        app.search_query = "bet".into();
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1);
        assert_eq!(app.sessions[app.filtered[0]].name, "beta");
    }

    #[test]
    fn filter_is_case_insensitive() {
        let mut app = App::new(sample_sessions());
        app.search_query = "ALPHA".into();
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1);
        assert_eq!(app.sessions[app.filtered[0]].name, "alpha");
    }

    #[test]
    fn empty_filter_shows_all() {
        let mut app = App::new(sample_sessions());
        app.search_query = "".into();
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
    fn enter_returns_open_action() {
        let mut app = App::new(sample_sessions());
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::Open(name) if name == "alpha"));
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
    fn search_typing_filters() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('b')));
        app.handle_key(KeyEvent::from(KeyCode::Char('e')));
        assert_eq!(app.search_query, "be");
        assert_eq!(app.filtered.len(), 1);
    }

    #[test]
    fn search_esc_clears_and_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('/')));
        app.handle_key(KeyEvent::from(KeyCode::Char('x')));
        assert_eq!(app.filtered.len(), 0);

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(app.search_query, "");
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
        assert_eq!(app.rename_input, "alpha");
    }

    #[test]
    fn rename_validates_empty_name() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Rename;
        app.rename_input = "".into();
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().contains("empty"));
    }

    #[test]
    fn rename_validates_invalid_chars() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Rename;
        app.rename_input = "bad/name".into();
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().contains("Invalid"));
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
        app.search_query = "alph".into();
        app.apply_filter_and_sort();
        // Only 1 result, so selection should clamp to 0
        assert_eq!(app.table_state.selected(), Some(0));
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
}
