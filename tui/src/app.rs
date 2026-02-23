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
    SessionMenu,
    ConfirmDelete,
    ConfirmForceOpen,
    Rename,
    MoveToRemote,
    Secrets,
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

pub struct App {
    pub sessions: Vec<Session>,
    pub filtered: Vec<usize>,
    pub table_state: TableState,
    pub mode: Mode,
    pub sort_col: SortColumn,
    pub sort_dir: SortDirection,
    pub search_query: String,
    pub rename_input: String,
    pub move_to_input: String,
    pub secrets_names: Vec<String>,
    pub secrets_selected: usize,
    pub return_to_secrets: bool,
    pub menu_selected: usize,
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
            move_to_input: String::new(),
            secrets_names: Vec::new(),
            secrets_selected: 0,
            return_to_secrets: false,
            menu_selected: 0,
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
            Mode::SessionMenu => self.handle_session_menu(key),
            Mode::ConfirmDelete => self.handle_confirm_delete(key),
            Mode::ConfirmForceOpen => self.handle_confirm_force_open(key),
            Mode::Rename => self.handle_rename(key),
            Mode::MoveToRemote => self.handle_move_to_remote(key),
            Mode::Secrets => self.handle_secrets(key),
            Mode::SyncOutput(_) => {
                if self.return_to_secrets {
                    self.return_to_secrets = false;
                    if self.secrets_names.is_empty() {
                        self.mode = Mode::Normal;
                        self.status_message = Some("No secrets remaining".to_string());
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
            KeyCode::Char('m') => {
                if let Some(session) = self.selected_session() {
                    if session.location.is_some() {
                        self.status_message = Some("Session is already remote".to_string());
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
                }
                Action::None
            }
            2 => {
                // Rename
                if let Some(name) = self.selected_session_name() {
                    self.rename_input = name;
                    self.mode = Mode::Rename;
                }
                Action::None
            }
            3 => {
                // Move to Remote
                if let Some(session) = self.selected_session() {
                    if session.location.is_some() {
                        self.status_message = Some("Session is already remote".to_string());
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
                self.run_sync_command("push");
                Action::None
            }
            6 => {
                // Pull
                self.run_sync_command("pull");
                Action::None
            }
            7 => {
                // Status
                self.run_sync_command("status");
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

    fn handle_move_to_remote(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            KeyCode::Enter => {
                return self.execute_move_to();
            }
            KeyCode::Backspace => {
                self.move_to_input.pop();
            }
            KeyCode::Char(c) => {
                self.move_to_input.push(c);
            }
            _ => {}
        }
        Action::None
    }

    fn handle_secrets(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => {
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
                    self.run_secrets_subcommand("get", &key_name);
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

    fn execute_move_to(&mut self) -> Action {
        let host = self.move_to_input.trim().to_string();
        if host.is_empty() {
            self.status_message = Some("Host cannot be empty".to_string());
            self.mode = Mode::Normal;
            return Action::None;
        }
        if host.contains(char::is_whitespace) {
            self.status_message = Some("Host cannot contain spaces".to_string());
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
                    self.status_message = Some(format!("Secrets failed: {}", e));
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
                    self.status_message = Some(format!("Secrets failed: {}", e));
                    self.mode = Mode::Normal;
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
            if x >= offset && x < offset + width + 3 {
                return SORT_COLUMNS.get(i).copied();
            }
            offset += width + 3; // +3 for column_spacing(3)
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
        assert_eq!(app.move_to_input, "");
    }

    #[test]
    fn m_on_remote_session_shows_status() {
        let mut app = App::new(sample_sessions());
        // beta (index 1) is remote (location=Some)
        app.table_state.select(Some(1));
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().contains("already remote"));
    }

    #[test]
    fn move_to_remote_esc_cancels() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input = "somehost".into();
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
        assert_eq!(app.move_to_input, "mini");
    }

    #[test]
    fn move_to_remote_backspace_removes() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input = "min".into();
        app.handle_key(KeyEvent::from(KeyCode::Backspace));
        assert_eq!(app.move_to_input, "mi");
    }

    #[test]
    fn move_to_remote_enter_returns_move_to_action() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is selected
        app.mode = Mode::MoveToRemote;
        app.move_to_input = "mini".into();
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::MoveTo(name, host) if name == "alpha" && host == "mini"));
    }

    #[test]
    fn move_to_remote_empty_input_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input = "".into();
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().contains("empty"));
    }

    #[test]
    fn move_to_remote_whitespace_input_shows_error() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::MoveToRemote;
        app.move_to_input = "bad host".into();
        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(action, Action::None));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.status_message.as_ref().unwrap().contains("spaces"));
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
        assert_eq!(app.rename_input, "alpha");
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
        assert_eq!(app.rename_input, "alpha");
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
        assert!(app.status_message.as_ref().unwrap().contains("already remote"));
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
}
