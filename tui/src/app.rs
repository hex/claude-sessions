// ABOUTME: Application state machine that processes keyboard input and manages UI modes
// ABOUTME: Tracks table selection, sort order, search filter, and modal dialog state

use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseEvent, MouseEventKind};
use ratatui::widgets::TableState;

use crate::session::{self, Session};
use crate::theme::Palette;

/// The cs binary to fork. cs exports its own path when it launches the picker,
/// so a cs that is not on PATH still reaches itself.
pub fn cs_bin() -> String {
    match std::env::var("CS_BIN") {
        Ok(v) if !v.is_empty() => v,
        _ => "cs".to_string(),
    }
}

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

/// Split `#tag` predicate tokens out of a search query. Tags are lowercased;
/// the remainder rejoins as the fuzzy name query. A bare `#` yields an empty
/// tag, which matches nothing — typing feedback handles it like any
/// non-matching query.
pub(crate) fn parse_tag_query(query: &str) -> (Vec<String>, String) {
    let mut tags = Vec::new();
    let mut rest: Vec<&str> = Vec::new();
    for tok in query.split_whitespace() {
        match tok.strip_prefix('#') {
            Some(t) => tags.push(t.to_ascii_lowercase()),
            None => rest.push(tok),
        }
    }
    (tags, rest.join(" "))
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

/// Why the `cs` CLI would refuse a name, mirroring bash
/// validate_session_name: empty, "."/"..", a leading dot (cs's own staging
/// dirs, .spawn and .usage, sit at the sessions root under dot names), a
/// leading hyphen (`cs -uninstall` runs a verb), or anything but ASCII
/// alphanumerics plus `-` `_` `.`, each in cs's own words. None for a name cs
/// accepts. Keeps TUI-created/renamed sessions openable by `cs` (Unicode
/// letters or spaces would produce a dir cs rejects).
pub fn session_name_refusal(name: &str) -> Option<&'static str> {
    if name.is_empty() {
        Some("Session name cannot be empty")
    } else if name == "." || name == ".." {
        Some("Session name cannot be '.' or '..'")
    } else if name.starts_with('.') {
        Some("Session name cannot start with a dot")
    } else if name.starts_with('-') {
        Some("Session name cannot start with a hyphen")
    } else if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.') {
        Some("Session name must contain only alphanumeric characters, hyphens, underscores, and dots")
    } else {
        None
    }
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
    ConfirmDelete(DeleteConfirm),
    ConfirmForceOpen,
    ConfirmRotate,
    Rename,
    CreateSession,
    /// The secrets popup. A revealed value lives only here, so every way out
    /// of the popup drops it.
    Secrets { list: SecretsList, revealed: Option<Reveal> },
    /// A helper's printed output; dismissing it goes to `then`.
    CommandOutput { text: String, then: ReturnTo },
    Changelog,
    Legend,
    Merge,
}

/// What a delete confirm removes: the session it was opened on, or the
/// sessions marked with Space when D opened it, sorted.
#[derive(Debug, PartialEq)]
pub enum DeleteTargets {
    One(String),
    Marked(Vec<String>),
}

impl DeleteTargets {
    pub fn names(&self) -> &[String] {
        match self {
            DeleteTargets::One(name) => std::slice::from_ref(name),
            DeleteTargets::Marked(names) => names,
        }
    }
}

/// The open delete confirm: the sessions it shows and removes on `y`, and
/// what it shows about them.
#[derive(Debug, PartialEq)]
pub struct DeleteConfirm {
    pub targets: DeleteTargets,
    /// `y` is refused until DELETE_COUNTDOWN_SECS after this.
    pub countdown_start: std::time::Instant,
    /// What the confirm warns of: live sessions and files beyond cs's own
    /// that the removal would take, read when the confirm opens (never in
    /// render).
    pub warnings: Vec<session::DeleteWarning>,
    /// The escalations the confirm offers: the ones the sessions it would
    /// delete need, read when it opens.
    pub offers: session::RemoveGrants,
    /// The escalations granted; none until its key is pressed.
    pub grants: session::RemoveGrants,
}

/// The secrets popup's key names and the highlighted one.
#[derive(Debug, PartialEq)]
pub struct SecretsList {
    pub names: Vec<String>,
    pub selected: usize,
}

/// A secret's value drawn beside `key`; expires PEEK_DURATION_SECS after `at`.
#[derive(Debug, PartialEq)]
pub struct Reveal {
    pub key: String,
    pub value: String,
    pub at: std::time::Instant,
}

/// Where dismissing a command's output goes. Back to the secrets popup
/// carries its list but no reveal: the value is never drawn again without
/// another `v`.
#[derive(Debug, PartialEq)]
pub enum ReturnTo {
    Normal,
    Secrets(SecretsList),
}

/// One feature worktree's merge readiness, as reported by
/// `cs <base> -features --porcelain`. Every field is computed by the shell
/// function the real merge gate calls, so this never disagrees with the gate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeatureRow {
    pub task: String,
    pub branch: String,
    pub ahead: u32,
    pub merged: bool,
    pub ff: bool,
    pub wt_dirty: bool,
    pub untracked: u32,
    pub base_dirty: bool,
    pub lock: String,
    pub state: String,
}

/// Parse `cs <base> -features --porcelain`: one tab-separated record per
/// feature, ten fields. A record of any other width means the verb changed
/// shape — drop it rather than render misaligned fields.
pub fn parse_features(text: &str) -> Vec<FeatureRow> {
    text.lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 10 {
                return None;
            }
            Some(FeatureRow {
                task: f[0].to_string(),
                branch: f[1].to_string(),
                ahead: f[2].parse().unwrap_or(0),
                merged: f[3] == "1",
                ff: f[4] == "1",
                wt_dirty: f[5] == "1",
                untracked: f[6].parse().unwrap_or(0),
                base_dirty: f[7] == "1",
                lock: f[8].to_string(),
                state: f[9].to_string(),
            })
        })
        .collect()
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

/// What a menu entry does. Carried in the table rather than implied by the
/// entry's position, so the dispatch cannot drift from the row that was drawn:
/// reordering MENU_ITEMS used to shift every index below the moved entry
/// silently, with the tests still green because each pressed its own key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuAction {
    Open,
    Delete,
    Rename,
    Secrets,
    Archive,
    RotateNarrative,
}

/// The session menu, in display order: what the entry does, its label, and the
/// key that selects it. The single source for the popup's rows AND the key
/// arms — the menu used to carry a second, hand-kept copy of these labels in
/// the renderer, and the two drifted. State-dependent entries (Archive's
/// direction, Secrets' availability) are overridden in `menu_rows`, matched on
/// the action so a label rename cannot silently drop the override.
pub const MENU_ITEMS: &[(MenuAction, &str, &str)] = &[
    (MenuAction::Open, "Open", "Enter"),
    (MenuAction::Delete, "Delete", "d"),
    (MenuAction::Rename, "Rename", "r"),
    (MenuAction::Secrets, "Secrets", "s"),
    (MenuAction::Archive, "Archive", "a"),
    (MenuAction::RotateNarrative, "Rotate narrative", "R"),
];

/// The action a single-character shortcut selects, for both the menu and the
/// list. Enter is deliberately absent: it opens the menu from the list, so
/// Open is the one entry whose key is not a plain char.
pub fn menu_action_for_key(c: char) -> Option<MenuAction> {
    MENU_ITEMS
        .iter()
        .find(|(_, _, key)| key.len() == 1 && key.starts_with(c))
        .map(|(action, _, _)| *action)
}

#[derive(Debug)]
pub enum Action {
    None,
    Quit,
    Open(String),
    ForceOpen(String),
    /// Exit and hand cs a session plus argv words. `lib/99-main.sh` reads line
    /// 1 as the session and word-splits the rest, so no word may hold a space.
    OpenWith { session: String, args: Vec<String> },
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
    /// Pending cs update read from cs's caches at startup; None when current.
    pub update_notice: Option<session::UpdateNotice>,
    pub sort_col: SortColumn,
    pub sort_dir: SortDirection,
    pub search_input: TextInput,
    pub rename_input: TextInput,
    pub create_input: TextInput,
    pub queue_input: TextInput,
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
    /// Drawn beside a session tagged encrypted; resolved once at start from
    /// the machine's font consent.
    pub lock_marker: &'static str,
    /// Fuzzy match indices per session index (for highlighting matched chars in names).
    pub fuzzy_indices: HashMap<usize, Vec<usize>>,
    /// Worktree rows (`base@task`) currently attached under their base in
    /// `filtered`; the renderer shows these as indented `@task` children.
    pub attached_worktrees: HashSet<usize>,
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
    /// Session name -> the generation of the read currently in flight for it.
    /// A result whose generation is not the one recorded here is stale and is
    /// dropped; invalidating a session simply forgets its entry.
    preview_pending: std::collections::HashMap<String, u64>,
    /// Monotonic request counter. Never reset — a wrapped u64 would need one
    /// read per nanosecond for centuries.
    preview_generation: u64,
    /// Session names to load, drained by the preview worker.
    preview_requests: std::sync::mpsc::Sender<(u64, String)>,
    /// Previews the worker has finished, drained once per event-loop tick.
    preview_results: std::sync::mpsc::Receiver<(u64, String, session::SessionPreview)>,
    /// Generation of the periodic rescan in flight, if any. A result with any
    /// other generation is stale (a user-initiated rescan replaced the table
    /// while it ran) and is dropped; `None` also means no new request is due.
    scan_pending: Option<u64>,
    /// Monotonic rescan request counter; never reset (see `preview_generation`).
    scan_generation: u64,
    /// Rescan requests, drained by the scan worker.
    scan_requests: std::sync::mpsc::Sender<u64>,
    /// Finished rescans, drained once per event-loop tick.
    scan_results: std::sync::mpsc::Receiver<(u64, Vec<Session>)>,
    /// Whether to show the preview pane on wide terminals (toggled with `p`).
    pub show_preview: bool,
    /// Whether archived sessions appear in the table (toggled with `A`).
    pub show_archived: bool,
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
    /// The base session whose features the merge screen is showing.
    pub merge_base: String,
    /// Readiness rows for that base, refreshed on entry and on `r`.
    pub merge_features: Vec<FeatureRow>,
    /// Highlighted row in `merge_features`.
    pub merge_selected: usize,
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
/// Each request carries a generation, and the worker hands it back with the
/// result. Identity by NAME is not enough: the render that follows any keypress
/// re-requests the selected session, so a read invalidated mid-flight and the
/// fresh read queued right after it are indistinguishable by name — the stale
/// one lands first and is cached as if it were current.
fn spawn_preview_worker(
    root: std::path::PathBuf,
) -> (
    std::sync::mpsc::Sender<(u64, String)>,
    std::sync::mpsc::Receiver<(u64, String, session::SessionPreview)>,
) {
    let (request_tx, request_rx) = std::sync::mpsc::channel::<(u64, String)>();
    let (result_tx, result_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // Ends when the App drops its sender.
        for (generation, name) in request_rx {
            let preview = session::load_preview(&root.join(&name));
            if result_tx.send((generation, name, preview)).is_err() {
                break;
            }
        }
    });
    (request_tx, result_rx)
}

/// Worker thread that rescans the sessions root on request. A scan forks one
/// `git remote get-url` per checkout session (seconds of wall time on a busy
/// machine); on the event-loop thread that blocked every key press until the
/// scan returned. Each result carries the generation of the request it answers
/// so a scan that raced a user-initiated rescan can be told apart and dropped.
fn spawn_scan_worker(
    root: std::path::PathBuf,
) -> (
    std::sync::mpsc::Sender<u64>,
    std::sync::mpsc::Receiver<(u64, Vec<Session>)>,
) {
    let (request_tx, request_rx) = std::sync::mpsc::channel::<u64>();
    let (result_tx, result_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // Ends when the App drops its sender.
        for generation in request_rx {
            let sessions = session::scan_sessions_in(&root);
            if result_tx.send((generation, sessions)).is_err() {
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
        let (scan_requests, scan_results) = spawn_scan_worker(sessions_root.clone());
        let mut app = App {
            sessions_root,
            sessions,
            filtered: Vec::new(),
            table_state,
            mode: Mode::Normal,
            update_notice: None,
            table_area: ratatui::layout::Rect::default(),
            column_widths: Vec::new(),
            row_hit_spans: Vec::new(),
            sort_col: SortColumn::Modified,
            sort_dir: SortDirection::Desc,
            search_input: TextInput::new(),
            rename_input: TextInput::new(),
            create_input: TextInput::new(),
            queue_input: TextInput::new(),
            menu_selected: 0,
            status_message: None,
            row_flashes: HashMap::new(),
            visible_sort_columns: Vec::new(),
            lock_marker: session::lock_marker(),
            fuzzy_indices: HashMap::new(),
            attached_worktrees: HashSet::new(),
            section_labels: Vec::new(),
            nav_repeat: ('\0', 0, std::time::Instant::now()),
            marked_sessions: std::collections::HashSet::new(),
            expanded_session: None,
            preview_cache: HashMap::new(),
            preview_pending: std::collections::HashMap::new(),
            preview_generation: 0,
            preview_requests,
            preview_results,
            scan_pending: None,
            scan_generation: 0,
            scan_requests,
            scan_results,
            show_preview: true,
            show_archived: false,
            focus: Focus::List,
            notes_focus: NotesFocus::Input,
            notes_selected: 0,
            theme: Palette::dark(),
            last_input: std::time::Instant::now(),
            merge_base: String::new(),
            merge_features: Vec::new(),
            merge_selected: 0,
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
        match &self.mode {
            Mode::ConfirmDelete(confirm) => {
                let elapsed = confirm.countdown_start.elapsed().as_secs();
                DELETE_COUNTDOWN_SECS.saturating_sub(elapsed)
            }
            _ => 0,
        }
    }

    /// Expire the revealed secret after PEEK_DURATION_SECS.
    pub fn expire_peek(&mut self) -> bool {
        if let Mode::Secrets { revealed, .. } = &mut self.mode {
            if revealed.as_ref().is_some_and(|r| r.at.elapsed().as_secs() >= PEEK_DURATION_SECS) {
                *revealed = None;
                return true;
            }
        }
        false
    }

    /// The secret value the open secrets popup shows, if any.
    pub fn revealed(&self) -> Option<&Reveal> {
        match &self.mode {
            Mode::Secrets { revealed, .. } => revealed.as_ref(),
            _ => None,
        }
    }

    /// Seconds remaining on the peek reveal countdown.
    pub fn peek_remaining(&self) -> u64 {
        match self.revealed() {
            Some(r) => PEEK_DURATION_SECS.saturating_sub(r.at.elapsed().as_secs()),
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
            || self.revealed().is_some()
            || matches!(self.mode, Mode::ConfirmDelete(_))
            || !self.preview_pending.is_empty()
    }

    /// Whether a periodic rescan is running on the worker. The event loop
    /// shortens its poll timeout while one is, so the result lands within a
    /// heartbeat; it is not an animation and never forces a repaint by itself.
    pub fn scan_in_flight(&self) -> bool {
        self.scan_pending.is_some()
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
        if self.preview_cache.contains_key(&name) || self.preview_pending.contains_key(&name) {
            return;
        }
        self.preview_generation += 1;
        let generation = self.preview_generation;
        if self.preview_requests.send((generation, name.clone())).is_ok() {
            self.preview_pending.insert(name, generation);
        }
    }

    /// Move every preview the worker has finished into the cache. A result is
    /// dropped when its name is no longer pending: something invalidated that
    /// session while its read was in flight (rotation does), and caching the
    /// bytes read BEFORE the change would put the stale preview straight back.
    /// Returns how many results were delivered, dropped ones included — the
    /// render loop ignores it; a test waiting on the worker needs it to tell
    /// "nothing arrived yet" from "it arrived and was correctly discarded".
    pub fn drain_previews(&mut self) -> usize {
        let mut delivered = 0;
        while let Ok((generation, name, preview)) = self.preview_results.try_recv() {
            delivered += 1;
            if self.preview_pending.get(&name) == Some(&generation) {
                self.preview_pending.remove(&name);
                self.preview_cache.insert(name, preview);
            }
        }
        delivered
    }

    /// Block until the rescan in flight has replaced the table.
    #[cfg(test)]
    fn wait_for_scan(&mut self) {
        while self.scan_pending.is_some() {
            match self.scan_results.recv() {
                Ok(result) => {
                    self.accept_scan(result);
                }
                Err(_) => break,
            }
        }
    }

    /// Block until every requested preview has landed in the cache.
    #[cfg(test)]
    fn wait_for_previews(&mut self) {
        while !self.preview_pending.is_empty() {
            match self.preview_results.recv() {
                Ok((generation, name, preview)) => {
                    if self.preview_pending.get(&name) == Some(&generation) {
                        self.preview_pending.remove(&name);
                        self.preview_cache.insert(name, preview);
                    }
                }
                Err(_) => break,
            }
        }
    }

    pub fn apply_filter_and_sort(&mut self) {
        // Remember the selected session name so we can restore it after re-sorting
        let prev_name = self.selected_session().map(|s| s.name.clone());

        let raw_query = self.search_input.text().to_string();
        let (tag_filters, query) = parse_tag_query(&raw_query);
        let query = query.as_str();
        let tag_ok = |s: &Session| tag_filters.iter().all(|t| s.tags.iter().any(|st| st == t));
        let show_archived = self.show_archived;
        let visible = |s: &Session| show_archived || !s.archived;
        self.fuzzy_indices.clear();

        if query.is_empty() {
            self.filtered = (0..self.sessions.len())
                .filter(|&i| tag_ok(&self.sessions[i]) && visible(&self.sessions[i]))
                .collect();
        } else {
            // Fuzzy match the name, else the objective, and collect
            // (index, name_hit, score, matched_indices). An objective hit
            // carries no indices: fuzzy_match's indices address the string it
            // matched, and the row draws the name.
            let mut matches: Vec<(usize, bool, i32, Vec<usize>)> = self
                .sessions
                .iter()
                .enumerate()
                .filter_map(|(i, s)| {
                    if !tag_ok(s) || !visible(s) {
                        return None;
                    }
                    if let Some((score, indices)) = fuzzy_match(query, &s.name) {
                        return Some((i, true, score, indices));
                    }
                    let objective = s.objective.as_deref()?;
                    fuzzy_match(query, objective).map(|(score, _)| (i, false, score, Vec::new()))
                })
                .collect();

            // Name hits first, then by score descending (best matches first)
            matches.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.cmp(&a.2)));

            self.filtered = matches.iter().map(|(i, _, _, _)| *i).collect();
            for (i, _, _, indices) in matches {
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

        // Task worktrees (`base@task`) ride under their base session: pull
        // each one out of the flat order and reinsert it directly after its
        // base, preserving the worktrees' own relative order. A worktree
        // whose base is filtered out stays where the sort put it and renders
        // under its full name. Search keeps the flat order so fuzzy scores
        // and highlight indices stay honest.
        self.attached_worktrees.clear();
        if query.is_empty()
            && self
                .filtered
                .iter()
                .any(|&i| crate::session::worktree_parts(&self.sessions[i].name).is_some())
        {
            let sessions = &self.sessions;
            let in_order: HashSet<&str> =
                self.filtered.iter().map(|&i| sessions[i].name.as_str()).collect();
            let mut children: HashMap<&str, Vec<usize>> = HashMap::new();
            for &i in &self.filtered {
                if let Some((base, _)) = crate::session::worktree_parts(&sessions[i].name) {
                    if in_order.contains(base) {
                        children.entry(base).or_default().push(i);
                    }
                }
            }
            if !children.is_empty() {
                let attached: HashSet<usize> = children.values().flatten().copied().collect();
                let mut out = Vec::with_capacity(self.filtered.len());
                for &i in &self.filtered {
                    if attached.contains(&i) {
                        continue;
                    }
                    out.push(i);
                    if let Some(kids) = children.get(sessions[i].name.as_str()) {
                        out.extend(kids);
                    }
                }
                self.filtered = out;
                self.attached_worktrees = attached;
            }
        }

        // Compute section labels for time-based grouping
        self.section_labels.clear();
        let show_sections = matches!(self.sort_col, SortColumn::Created | SortColumn::Modified);
        if show_sections && !self.filtered.is_empty() {
            let mut prev_section = "";
            let mut base_ts: Option<std::time::SystemTime> = None;
            for &idx in &self.filtered {
                // An attached worktree inherits its base's section so the
                // group never splits across a divider.
                let ts = if self.attached_worktrees.contains(&idx) {
                    base_ts
                } else {
                    base_ts = self.sessions[idx].modified_ts;
                    base_ts
                };
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
            Mode::ConfirmDelete(_) => self.handle_confirm_delete(key),
            Mode::ConfirmForceOpen => self.handle_confirm_force_open(key),
            Mode::ConfirmRotate => self.handle_confirm_rotate(key),
            Mode::Rename => self.handle_rename(key),
            Mode::CreateSession => self.handle_create_session(key),
            Mode::Secrets { .. } => self.handle_secrets(key),
            Mode::Changelog => self.handle_changelog(key),
            Mode::Legend => self.handle_legend(key),
            Mode::Merge => self.handle_merge(key),
            Mode::CommandOutput { .. } => {
                if let Mode::CommandOutput { then: ReturnTo::Secrets(list), .. } =
                    std::mem::replace(&mut self.mode, Mode::Normal)
                {
                    if list.names.is_empty() {
                        self.set_status("No secrets remaining", StatusLevel::Info);
                    } else {
                        self.mode = Mode::Secrets { list, revealed: None };
                    }
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
            KeyCode::Char('C') => {
                if self.update_notice.is_some() {
                    self.mode = Mode::Changelog;
                }
                Action::None
            }
            KeyCode::Char('?') => {
                self.mode = Mode::Legend;
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
                    let mut names: Vec<String> = self.marked_sessions.iter().cloned().collect();
                    names.sort();
                    self.open_delete_confirm(DeleteTargets::Marked(names));
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
            KeyCode::Char('A') => {
                self.show_archived = !self.show_archived;
                self.apply_filter_and_sort();
                Action::None
            }
            // Every menu shortcut works from the list too, through the same
            // dispatch the menu uses — these were five verbatim copies of
            // execute_menu_action's arms, and a change to one had to be made
            // twice. Placed after the list's own Char arms so those still win.
            KeyCode::Char(c) if menu_action_for_key(c).is_some() => {
                let action = menu_action_for_key(c).expect("guarded above");
                self.execute_menu_action(action)
            }
            KeyCode::Char('m') => {
                if let Some(session) = self.selected_session() {
                    let name = session.name.clone();
                    // A worktree row opens its base; a base row opens itself.
                    let base = match name.split_once('@') {
                        Some((b, _)) => b.to_string(),
                        None => name,
                    };
                    self.merge_base = base;
                    self.load_merge_features();
                    if self.merge_features.is_empty() {
                        self.set_status(
                            format!("No feature worktrees of {}", self.merge_base),
                            StatusLevel::Info,
                        );
                    } else {
                        self.mode = Mode::Merge;
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

    /// Ask the scan worker for a fresh read of the sessions root, unless one is
    /// already in flight. Never touches the filesystem on this thread; the
    /// result lands through `drain_scans`. Callers gate this on `Mode::Normal`.
    pub fn auto_refresh(&mut self) {
        if self.scan_pending.is_some() {
            return;
        }
        self.scan_generation += 1;
        let generation = self.scan_generation;
        if self.scan_requests.send(generation).is_ok() {
            self.scan_pending = Some(generation);
        }
    }

    /// Swap in every finished rescan the worker has delivered. Returns whether
    /// the table changed, so the event loop knows to repaint. While a modal is
    /// open the result stays in the channel: a rename dialog acts on the
    /// current selection, and a table replaced underneath it could move that
    /// selection to a different session than the one the user confirmed.
    pub fn drain_scans(&mut self) -> bool {
        if self.mode != Mode::Normal {
            return false;
        }
        let mut replaced = false;
        while let Ok(result) = self.scan_results.try_recv() {
            replaced |= self.accept_scan(result);
        }
        replaced
    }

    /// Replace the table with a finished rescan and re-derive the visible list,
    /// keeping the highlight pinned to the same session by name (a new row
    /// appearing above must not shift the selection). A result whose generation
    /// is not the one pending answers a request that `rescan_now` has since
    /// superseded, so it is dropped rather than put an older read back.
    fn accept_scan(&mut self, (generation, sessions): (u64, Vec<Session>)) -> bool {
        if self.scan_pending != Some(generation) {
            return false;
        }
        self.scan_pending = None;
        let selected_name = self.selected_session_name();
        self.sessions = sessions;
        self.apply_filter_and_sort();
        if let Some(name) = selected_name {
            if let Some(pos) = self
                .filtered
                .iter()
                .position(|&i| self.sessions[i].name == name)
            {
                self.table_state.select(Some(pos));
            }
        }
        true
    }

    /// Re-scan on this thread right after an action changed the sessions root
    /// (delete, rename, archive): the user is waiting on that row, so the table
    /// must show the change in the same frame. Forgets any periodic rescan in
    /// flight, whose read predates the change.
    fn rescan_now(&mut self) {
        self.scan_pending = None;
        self.sessions = session::scan_sessions();
        self.apply_filter_and_sort();
    }

    fn handle_changelog(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('C') | KeyCode::Enter => {
                self.mode = Mode::Normal;
            }
            _ => {}
        }
        Action::None
    }

    fn handle_legend(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('?') | KeyCode::Enter => {
                self.mode = Mode::Normal;
            }
            _ => {}
        }
        Action::None
    }

    fn handle_merge(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => {
                self.mode = Mode::Normal;
                Action::None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if !self.merge_features.is_empty()
                    && self.merge_selected + 1 < self.merge_features.len()
                {
                    self.merge_selected += 1;
                }
                Action::None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.merge_selected > 0 {
                    self.merge_selected -= 1;
                }
                Action::None
            }
            KeyCode::Char('r') => {
                self.load_merge_features();
                Action::None
            }
            KeyCode::Enter => {
                // Hand off unconditionally. The ritual can resolve blockers
                // the screen can only report, and cs delivers the real refusal.
                match self.selected_feature() {
                    Some(f) => Action::OpenWith {
                        session: self.merge_base.clone(),
                        args: vec!["-finish".to_string(), f.task.clone()],
                    },
                    None => Action::None,
                }
            }
            _ => Action::None,
        }
    }

    pub fn selected_feature(&self) -> Option<&FeatureRow> {
        self.merge_features.get(self.merge_selected)
    }

    /// Fork cs once for the whole base. The per-feature git work happens inside
    /// cs, which is also where the gate semantics live. A failure is a status
    /// line, never an exit code: a nonzero TUI exit kills cs outright.
    fn load_merge_features(&mut self) {
        let base = self.merge_base.clone();
        if base.is_empty() {
            return;
        }
        let output = std::process::Command::new(cs_bin())
            .args([&base, "-features", "--porcelain"])
            .output();
        match output {
            Ok(out) if out.status.success() => {
                let text = String::from_utf8_lossy(&out.stdout).to_string();
                self.merge_features = parse_features(&text);
                self.merge_selected = 0;
            }
            Ok(out) => {
                let err = String::from_utf8_lossy(&out.stderr);
                self.merge_features = Vec::new();
                self.set_status(format!("Features failed: {}", err.trim()), StatusLevel::Error);
            }
            Err(e) => {
                self.merge_features = Vec::new();
                self.set_status(format!("Features failed: {}", e), StatusLevel::Error);
            }
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
            KeyCode::Enter => {
                let action = MENU_ITEMS[self.menu_selected.min(MENU_ITEMS.len() - 1)].0;
                self.execute_menu_action(action)
            }
            // Direct shortcut keys, resolved through the table: a key that
            // labels a row always runs that row's action.
            KeyCode::Char(c) => match menu_action_for_key(c) {
                Some(action) => self.execute_menu_action(action),
                None => Action::None,
            },
            _ => Action::None,
        }
    }

    fn execute_menu_action(&mut self, action: MenuAction) -> Action {
        self.mode = Mode::Normal;
        match action {
            MenuAction::Open => {
                // Open: same as old Enter logic
                if let Some(session) = self.selected_session() {
                    if session.liveness.is_locked() {
                        self.mode = Mode::ConfirmForceOpen;
                        Action::None
                    } else {
                        Action::Open(session.name.clone())
                    }
                } else {
                    Action::None
                }
            }
            MenuAction::Delete => {
                // A live session opens the confirm too: it says so, and
                // offers removing it anyway as `cs -rm --force` does, unless
                // the picker runs inside another session or a
                // `cs <name> --remote` server serves it, where cs -rm
                // refuses it outright and so does the confirm.
                if let Some(name) = self.selected_session().map(|s| s.name.clone()) {
                    self.open_delete_confirm(DeleteTargets::One(name));
                }
                Action::None
            }
            MenuAction::Rename => {
                // Rename
                if let Some(name) = self.selected_session_name() {
                    self.rename_input.set(&name);
                    self.mode = Mode::Rename;
                }
                Action::None
            }
            MenuAction::Secrets => {
                // Secrets
                self.run_secrets_command();
                Action::None
            }
            MenuAction::Archive => {
                // Archive / unarchive
                self.toggle_archive();
                Action::None
            }
            MenuAction::RotateNarrative => {
                // Rotate the narrative into its archive, after confirming.
                // Same liveness guard as Delete: this rewrites the narrative
                // and commits inside a checkout a live conversation is still
                // appending to, and nothing downstream refuses.
                if let Some(refusal) = self.locked_selection_refusal() {
                    self.set_status(refusal, StatusLevel::Error);
                } else if self.selected_session().is_some() {
                    self.mode = Mode::ConfirmRotate;
                }
                Action::None
            }
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

    /// `y` removes the confirm's targets once its countdown has run out. D
    /// and F switch the escalation it offers on or off (`cs -rm
    /// --delete-files` and `--force`); any other key cancels.
    fn handle_confirm_delete(&mut self, key: KeyEvent) -> Action {
        if matches!(key.code, KeyCode::Char('y') | KeyCode::Char('Y')) {
            if self.delete_countdown_remaining() > 0 {
                self.set_status("Wait...", StatusLevel::Info);
                return Action::None;
            }
            let Mode::ConfirmDelete(confirm) = std::mem::replace(&mut self.mode, Mode::Normal) else {
                unreachable!("handle_confirm_delete dispatched outside Mode::ConfirmDelete");
            };
            match confirm.targets {
                DeleteTargets::One(name) => self.execute_delete(&name, confirm.grants),
                DeleteTargets::Marked(names) => self.execute_batch_delete(&names, confirm.grants),
            }
            return Action::None;
        }
        let Mode::ConfirmDelete(confirm) = &mut self.mode else {
            unreachable!("handle_confirm_delete dispatched outside Mode::ConfirmDelete");
        };
        match key.code {
            KeyCode::Char('D') if confirm.offers.unowned_files => {
                confirm.grants.unowned_files = !confirm.grants.unowned_files;
            }
            KeyCode::Char('F') if confirm.offers.past_live_lock => {
                confirm.grants.past_live_lock = !confirm.grants.past_live_lock;
            }
            _ => self.mode = Mode::Normal,
        }
        Action::None
    }

    /// Open the delete confirm for `targets`, with every escalation off: its
    /// lines name each live session and each one holding files beyond cs's
    /// own, and it offers the escalation each needs. Stays closed, with the
    /// reason in the status line, when `cs -rm` run inside the picker's
    /// session would refuse any of them from there, when a `cs <name>
    /// --remote` server serves any of them, and when a file listing fails.
    fn open_delete_confirm(&mut self, targets: DeleteTargets) {
        match self.delete_confirm_lines(targets.names()) {
            Ok((warnings, offers)) => {
                self.mode = Mode::ConfirmDelete(DeleteConfirm {
                    targets,
                    countdown_start: std::time::Instant::now(),
                    warnings,
                    offers,
                    grants: session::RemoveGrants::default(),
                });
            }
            Err(e) => self.set_status(e, StatusLevel::Error),
        }
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

    /// Rotation rewrites a narrative and commits, and R is one shift away from
    /// r (rename), so it asks first. No countdown like the delete confirm: the
    /// archive chunk is a verbatim copy of what left, so the answer here is
    /// recoverable and a timed gate would only be friction.
    fn handle_confirm_rotate(&mut self, key: KeyEvent) -> Action {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => self.rotate_narrative(),
            _ => self.mode = Mode::Normal,
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
        if let Some(refusal) = session_name_refusal(&name) {
            self.set_status(refusal, StatusLevel::Error);
            self.mode = Mode::Normal;
            return Action::None;
        }
        let root = self.sessions_root.clone();
        // Any entry holds the name, a link that leads nowhere included.
        if std::fs::symlink_metadata(root.join(&name)).is_ok() {
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

    /// Sync the affected session's in-memory `queue_depth` with the on-disk queue,
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

    /// Queue `text` as a new task file and clear the input, leaving focus on
    /// the input so several tasks can be queued in a row. The task is written
    /// whole to the queue.tmp/ staging dir and renamed into the queue
    /// directory, so the drain can never read a torn entry — mirroring the
    /// CLI's `_queue_add` in bin/cs.
    fn append_notes_task(&mut self, name: &str, text: &str) {
        let dir = session::queue_dir(name);
        let qdir = dir.join("queue");
        let staging = dir.join("queue.tmp");
        // A pre-directory queue leaves a regular FILE at one of these paths, and
        // create_dir_all cannot convert it. cs converts on open; the TUI does not
        // duplicate that migration, but it must not swallow the task either —
        // read_queue's read_dir fails on the same shape, so such a session also
        // renders as empty, and a silent drop here is invisible from both ends.
        if let Err(e) =
            std::fs::create_dir_all(&qdir).and_then(|_| std::fs::create_dir_all(&staging))
        {
            self.set_status(
                format!("Queue write failed: {} — open {} with cs once", e, name),
                StatusLevel::Error,
            );
            return;
        }
        let (secs, nanos) = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| (d.as_secs(), d.subsec_nanos()))
            .unwrap_or((0, 0));
        // Zero-padded epoch keeps lexical order aligned with time order;
        // the nanosecond suffix keeps several adds inside one second in
        // submission order.
        let fname = format!("{:010}-{}-{:09}", secs, std::process::id(), nanos);
        let staged = staging.join(&fname);
        match std::fs::write(&staged, format!("{}\n", text))
            .and_then(|_| std::fs::rename(&staged, qdir.join(&fname)))
        {
            Ok(()) => {
                self.queue_input.clear();
                self.refresh_queue_depth(name);
                self.set_status(format!("Queued task for {}", name), StatusLevel::Success);
            }
            Err(e) => {
                self.set_status(format!("Queue write failed: {}", e), StatusLevel::Error);
            }
        }
    }

    /// Replace the task at `idx` in place, preserving its position, then return
    /// to the list with the edited task still highlighted.
    fn replace_notes_task(&mut self, name: &str, idx: usize, text: &str) {
        match rewrite_queue_task(name, idx, Some(text)) {
            Ok(()) => {
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
        match rewrite_queue_task(&name, idx, None) {
            Ok(()) => {
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

    /// Taken out of the mode and put back only while the popup stays open, so
    /// any key that leaves it leaves its reveal behind.
    fn handle_secrets(&mut self, key: KeyEvent) -> Action {
        let Mode::Secrets { mut list, mut revealed } = std::mem::replace(&mut self.mode, Mode::Normal) else {
            unreachable!("handle_secrets dispatched outside Mode::Secrets");
        };
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return Action::None,
            KeyCode::Down | KeyCode::Char('j') => {
                if list.selected + 1 < list.names.len() {
                    list.selected += 1;
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if list.selected > 0 {
                    list.selected -= 1;
                }
            }
            KeyCode::Char('v') | KeyCode::Enter => {
                if let Some(key_name) = list.names.get(list.selected) {
                    if let Some(reveal) = self.peek_secret(key_name) {
                        revealed = Some(reveal);
                    }
                }
            }
            KeyCode::Char('d') => {
                if let Some(key_name) = list.names.get(list.selected).cloned() {
                    match self.run_secrets_subcommand("delete", &key_name) {
                        Some(Ok((deleted, text))) => {
                            // Only mirror a deletion the helper actually made: a denied
                            // keychain prompt exits non-zero, and dropping the row
                            // anyway claims a deletion that did not happen.
                            if deleted {
                                list.names.remove(list.selected);
                                if list.selected >= list.names.len() && !list.names.is_empty() {
                                    list.selected = list.names.len() - 1;
                                }
                            }
                            self.mode = Mode::CommandOutput { text, then: ReturnTo::Secrets(list) };
                            return Action::None;
                        }
                        Some(Err(e)) => {
                            self.set_status(format!("Secrets failed: {}", e), StatusLevel::Error);
                            return Action::None;
                        }
                        None => {}
                    }
                }
            }
            _ => {}
        }
        self.mode = Mode::Secrets { list, revealed };
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

    /// Why the selected session may not be deleted, when it may not be.
    ///
    /// `cs -rm` refuses a lock-held session without `--force`, and the TUI
    /// reaches the same removal. Lock, not heartbeat: the shell's
    /// `session_is_live` reads the lock pid and `kill(0)`s it, and so does
    /// this, now: the row's pid was read at the last scan and its process
    /// may have exited since.
    fn locked_selection_refusal(&self) -> Option<String> {
        let name = &self.selected_session()?.name;
        let pid = self.live_lock_pid(name)?;
        Some(session::live_refusal(name, pid))
    }

    /// The pid holding `name`'s lock as its row was scanned, when that
    /// process is alive now.
    fn live_lock_pid(&self, name: &str) -> Option<u32> {
        self.sessions
            .iter()
            .find(|s| s.name == name)
            .and_then(|s| s.liveness.lock_pid())
            .filter(|&pid| session::is_pid_alive(pid))
    }

    /// `locked_selection_refusal`, then the selected session's lock read
    /// again from disk, as delete's removal reads it: rescans wait while a
    /// modal is open, so the session may have opened since its row was
    /// scanned. Rename and rotate ask this when they act.
    fn live_selection_refusal_now(&self) -> Option<String> {
        self.locked_selection_refusal().or_else(|| {
            let session = self.selected_session()?;
            let pid = session::read_lock_pid(&self.sessions_root.join(&session.name).join(".cs"))?;
            Some(session::live_refusal(&session.name, pid))
        })
    }

    /// The confirm lines for `names` and the escalations they need: a line
    /// per live session (offering the live-lock grant) and a line per session
    /// holding files beyond cs's own (offering the files grant), the latter
    /// prefixed with the session name when more than one is being deleted.
    /// Errors with `cs -rm`'s sentence when, inside a session, it would
    /// refuse any of `names` from there whatever it is granted, and when a
    /// `cs <name> --remote` server serves any of them, so the confirm never
    /// offers a removal it will refuse; errors too when a listing fails, so
    /// the confirm never opens on a list it could not read.
    fn delete_confirm_lines(&self, names: &[String]) -> Result<(Vec<session::DeleteWarning>, session::RemoveGrants), String> {
        let mut lines = Vec::new();
        let mut offers = session::RemoveGrants::default();
        for name in names {
            let path = self.sessions_root.join(name);
            if let Some(refusal) = session::caller_refusal(&self.sessions_root, name, &path).map_err(|e| e.to_string())? {
                return Err(refusal);
            }
            if let Some(refusal) = session::served_refusal(name, &path) {
                return Err(refusal);
            }
            if let Some(pid) = self.live_lock_pid(name) {
                lines.push(session::DeleteWarning::line(format!("{name} is live (pid {pid})")));
                offers.past_live_lock = true;
            }
            let entries = session::unowned_entries(name, &path)?;
            if let Some(mut warning) = entries.warning() {
                if names.len() > 1 {
                    warning.text = format!("{name}: {}", warning.text);
                }
                lines.push(warning);
                offers.unowned_files = true;
            }
        }
        Ok((lines, offers))
    }

    fn execute_delete(&mut self, name: &str, grants: session::RemoveGrants) {
        if !grants.past_live_lock {
            if let Some(pid) = self.live_lock_pid(name) {
                self.set_status(session::live_refusal(name, pid), StatusLevel::Error);
                return;
            }
        }
        let root = self.sessions_root.clone();
        let path = root.join(name);
        // An adopted link loses only the link; the age state is the project's.
        let was_link = is_symlink(&path);
        match session::remove_session_path(&root, name, &path, grants) {
            Ok(()) => {
                match if was_link { Ok(None) } else { drop_age_state(name) } {
                    Ok(None) => self.set_status(format!("Deleted: {}", name), StatusLevel::Success),
                    Ok(Some(dir)) => self.set_status(
                        format!("Deleted: {} · removed age state {}", name, dir.display()),
                        StatusLevel::Success,
                    ),
                    Err(e) => self.set_status(format!("Deleted: {}, but {}", name, e), StatusLevel::Error),
                }
                self.rescan_now();
            }
            Err(e) => {
                self.set_status(format!("Delete failed: {}", e), StatusLevel::Error);
            }
        }
    }

    fn execute_batch_delete(&mut self, names: &[String], grants: session::RemoveGrants) {
        let root = self.sessions_root.clone();
        let mut deleted = 0;
        let mut errors = 0;
        let mut live: Vec<String> = Vec::new();
        let mut reasons: Vec<String> = Vec::new();
        let mut aged: Vec<String> = Vec::new();
        let mut age_failures: Vec<String> = Vec::new();
        for name in names {
            // Resolved per name rather than from the selection: a batch mixes
            // states, and a row can take the lock between marking and confirming.
            let lock_pid = if grants.past_live_lock { None } else { self.live_lock_pid(name) };
            if let Some(pid) = lock_pid {
                live.push(format!("{} (pid {})", name, pid));
                errors += 1;
                self.flash_row(name.clone(), FlashKind::Error);
                continue;
            }
            let path = root.join(name);
            let was_link = is_symlink(&path);
            let result = session::remove_session_path(&root, name, &path, grants);
            match result {
                Ok(()) => {
                    deleted += 1;
                    self.flash_row(name.clone(), FlashKind::Success);
                    match if was_link { Ok(None) } else { drop_age_state(name) } {
                        Ok(None) => {}
                        Ok(Some(dir)) => aged.push(dir.display().to_string()),
                        Err(e) => age_failures.push(format!("{} deleted, but {}", name, e)),
                    }
                }
                Err(e) => {
                    errors += 1;
                    reasons.push(e.to_string());
                    self.flash_row(name.clone(), FlashKind::Error);
                }
            }
        }
        self.marked_sessions.clear();
        self.rescan_now();
        let mut text = if errors == 0 {
            format!("Deleted {} sessions", deleted)
        } else {
            let mut text = format!("Deleted {}, {} failed", deleted, errors);
            if !live.is_empty() {
                text.push_str(&format!(" — live: {}", live.join(", ")));
            }
            if !reasons.is_empty() {
                text.push_str(&format!(" — {}", reasons.join("; ")));
            }
            text
        };
        if !aged.is_empty() {
            aged.sort();
            text.push_str(&format!(" · removed age state {}", aged.join(", ")));
        }
        if !age_failures.is_empty() {
            text.push_str(&format!(" — {}", age_failures.join("; ")));
        }
        let level = if errors == 0 && age_failures.is_empty() { StatusLevel::Success } else { StatusLevel::Error };
        self.set_status(text, level);
    }

    fn execute_rename(&mut self) {
        let new_name = self.rename_input.text().trim().to_string();
        if let Some(refusal) = session_name_refusal(&new_name) {
            self.set_status(refusal, StatusLevel::Error);
            self.mode = Mode::Normal;
            return;
        }
        // Same liveness guard as Delete and Rotate: a live claude keeps
        // writing under the old path, and the move takes its lock and
        // transcripts from under it.
        if let Some(refusal) = self.live_selection_refusal_now() {
            self.set_status(refusal, StatusLevel::Error);
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
            // An encrypted session reaches its vault through absolute links and
            // keeps its transcripts under the current path's name; a rename
            // strands both. symlink_metadata sees a link whose vault is locked.
            let dir = self.sessions_root.join(&session.name);
            let encrypted = std::fs::symlink_metadata(dir.join(".cs/claude-config")).is_ok()
                || session::VAULT_LINKS.iter().any(|sub| session::is_vault_link(&dir, sub));
            if encrypted {
                self.set_status(
                    "Can't rename an encrypted session: its vault links name this path",
                    StatusLevel::Error,
                );
                self.mode = Mode::Normal;
                return;
            }
        }

        if let Some(session) = self.selected_session() {
            let old_name = session.name.clone();
            let root = self.sessions_root.clone();
            let old = root.join(&old_name);
            let new = root.join(&new_name);
            // Any entry holds the name: rename(2) would replace a link that
            // leads nowhere (an adopted session on a disk not mounted).
            if std::fs::symlink_metadata(&new).is_ok() {
                self.set_status("Name already taken", StatusLevel::Error);
            } else if let Some(taken) = session::staged_spawn_files(&root, &new_name).first() {
                self.set_status(
                    format!("Can't rename: a spawn is staged for {}: {}", new_name, taken.display()),
                    StatusLevel::Error,
                );
            } else {
                match self.rename_session(&root, &old_name, &new_name) {
                    Ok(RenameOutcome::Done) => {
                        rename_claude_projects_dir(&old, &new);
                        self.set_status(format!("Renamed to: {}", new_name), StatusLevel::Success);
                        self.flash_row(&new_name, FlashKind::Success);
                        self.rescan_now();
                    }
                    Ok(RenameOutcome::SecretsUnfinished) => {
                        rename_claude_projects_dir(&old, &new);
                        self.set_status(
                            format!("Rename incomplete: run `cs -secrets --session {} rename {}`", old_name, new_name),
                            StatusLevel::Error,
                        );
                        self.rescan_now();
                    }
                    Err(e) => {
                        self.set_status(format!("Rename failed: {}", e), StatusLevel::Error);
                    }
                }
            }
        }
        self.mode = Mode::Normal;
    }

    /// Move session `old` to `new`: its directory, its staged spawn files,
    /// then its secrets through `cs -secrets --session <old> rename <new>`,
    /// which moves every store keyed by the name (the Keychain entries, the
    /// encrypted store and the age state) and needs the directory already
    /// moved. A failure at any step undoes the steps before it, so the session
    /// keeps its old name whole; the error says what failed. cs-secrets puts
    /// back what a failed move moved before it exits. The one exception is a
    /// move it could not put back, or that was killed: its marker is left,
    /// values are under `new` already, so the session keeps `new` and the
    /// outcome says the move is unfinished.
    fn rename_session(&self, root: &Path, old: &str, new: &str) -> Result<RenameOutcome, String> {
        let (old_dir, new_dir) = (root.join(old), root.join(new));
        std::fs::rename(&old_dir, &new_dir).map_err(|e| e.to_string())?;
        let undo_dir = |reason: String| -> String {
            match std::fs::rename(&new_dir, &old_dir) {
                Ok(()) => reason,
                Err(e) => format!("{reason}; and the session could not be moved back to {}: {e}", old_dir.display()),
            }
        };
        let moved = session::move_spawn_files(root, old, new).map_err(undo_dir)?;
        if let Err(reason) = move_secrets(old, new) {
            if secrets_move_unfinished(old, new) {
                return Ok(RenameOutcome::SecretsUnfinished);
            }
            let reason = match session::undo_spawn_moves(&moved) {
                Ok(()) => reason,
                Err(left) => format!("{reason}; {left}"),
            };
            return Err(undo_dir(reason));
        }
        Ok(RenameOutcome::Done)
    }

    /// Archive the selected session, or unarchive one that already is. The
    /// `.cs/archived` marker is written by `cs -archive` / `cs -unarchive`
    /// rather than here: the marker's date-and-actor stamp and the refusal to
    /// archive a live session belong to that verb, and a second writer would
    /// have to agree with it forever. cs's refusal — including the one naming
    /// `--force`, a flag the picker deliberately does not offer — is passed
    /// through to the status line as it was written.
    fn toggle_archive(&mut self) {
        let selected = self
            .selected_session()
            .map(|s| (s.name.clone(), s.archived));
        let (name, was_archived) = match selected {
            Some(pair) => pair,
            None => return,
        };
        let verb = if was_archived { "-unarchive" } else { "-archive" };
        let done = if was_archived { "Unarchived" } else { "Archived" };
        match std::process::Command::new(cs_bin())
            .args([verb, &name])
            .output()
        {
            Ok(out) if out.status.success() => {
                self.set_status(format!("{}: {}", done, name), StatusLevel::Success);
                self.flash_row(name, FlashKind::Success);
                // An archived row leaves the table unless `A` is showing them;
                // the re-filter inside is what keeps the selection in the list.
                self.rescan_now();
            }
            Ok(out) => {
                let err = String::from_utf8_lossy(&out.stderr);
                let reason = err.trim().lines().last().unwrap_or("").trim().to_string();
                let reason = if reason.is_empty() {
                    format!("cs {} refused", verb)
                } else {
                    reason
                };
                self.set_status(reason, StatusLevel::Error);
                self.flash_row(name, FlashKind::Error);
            }
            Err(e) => {
                self.set_status(format!("Archive failed: {}", e), StatusLevel::Error);
            }
        }
    }

    fn run_secrets_command(&mut self) {
        if let Some(session) = self.selected_session() {
            let name = session.name.clone();
            let output = std::process::Command::new(cs_bin())
                .args([&name, "-secrets", "list"])
                .output();
            match output {
                Ok(out) if out.status.success() => {
                    let text = String::from_utf8_lossy(&out.stdout).to_string();
                    self.mode = Mode::Secrets {
                        list: SecretsList { names: Self::parse_secrets_list(&text), selected: 0 },
                        revealed: None,
                    };
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

    /// Run `cs <session> -secrets <subcommand> <key>` for the selected session:
    /// None without one, else whether the helper ran AND exited zero, so a
    /// caller mirroring the store in memory mirrors only the changes the helper
    /// actually made, and what it printed on both streams.
    fn run_secrets_subcommand(&self, subcommand: &str, key: &str) -> Option<std::io::Result<(bool, String)>> {
        let name = self.selected_session()?.name.clone();
        let output = std::process::Command::new(cs_bin())
            .args([&name, "-secrets", subcommand, key])
            .output();
        Some(output.map(|out| {
            let text = String::from_utf8_lossy(&out.stdout).to_string()
                + &String::from_utf8_lossy(&out.stderr).to_string();
            (out.status.success(), text)
        }))
    }

    /// Archive the selected session's oldest narrative sections through
    /// `cs <name> -narrative rotate`. Both streams land in the output popup:
    /// a narrative under budget rotates nothing and says so, and that sentence
    /// is the whole answer as often as a rotation is. Unlike a secrets
    /// delete's output this one goes to `ReturnTo::Normal`, so dismissing it
    /// returns to the list.
    fn rotate_narrative(&mut self) {
        let name = match self.selected_session_name() {
            Some(n) => n,
            None => {
                self.mode = Mode::Normal;
                return;
            }
        };
        // The menu's liveness guard, asked again now the answer is in.
        if let Some(refusal) = self.live_selection_refusal_now() {
            self.set_status(refusal, StatusLevel::Error);
            self.mode = Mode::Normal;
            return;
        }
        match std::process::Command::new(cs_bin())
            .args([name.as_str(), "-narrative", "rotate"])
            .output()
        {
            Ok(out) => {
                // The preview pane lists narrative headings and its cache never
                // expires, so a rotation that moved the oldest of them into the
                // archive would leave the pane quoting them for the life of the
                // picker. Dropped whatever cs did: a stale pane is a bug, one
                // extra read is not.
                // Both maps: dropping only the cache would let a read already
                // in flight land afterwards and restore the pre-rotation copy.
                // Forgetting the pending generation is what makes that read
                // stale — the next render immediately re-requests this session,
                // so it cannot be recognised by name.
                self.preview_cache.remove(&name);
                self.preview_pending.remove(&name);
                let text = String::from_utf8_lossy(&out.stdout).to_string()
                    + &String::from_utf8_lossy(&out.stderr);
                self.mode = Mode::CommandOutput { text, then: ReturnTo::Normal };
            }
            Err(e) => {
                self.set_status(format!("Rotate failed: {}", e), StatusLevel::Error);
                self.mode = Mode::Normal;
            }
        }
    }

    fn peek_secret(&mut self, key_name: &str) -> Option<Reveal> {
        let name = self.selected_session()?.name.clone();
        let output = std::process::Command::new(cs_bin())
            .args([&name, "-secrets", "get", key_name])
            .output();
        match output {
            Ok(out) if out.status.success() => {
                let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
                return Some(Reveal { key: key_name.to_string(), value, at: std::time::Instant::now() });
            }
            Ok(out) => {
                let err = String::from_utf8_lossy(&out.stderr);
                self.set_status(format!("Peek failed: {}", err.trim()), StatusLevel::Error);
            }
            Err(e) => {
                self.set_status(format!("Peek failed: {}", e), StatusLevel::Error);
            }
        }
        None
    }

    /// The session menu as it should be drawn for the selected row: MENU_ITEMS
    /// with its two state-dependent overrides applied — Archive names the
    /// direction its key will actually take, and Secrets reads unavailable on
    /// a row that has none, so the menu never advertises an empty popup.
    /// Returned rather than duplicated in the renderer: those labels lived in
    /// two places once, and the copies drifted. Matched on the action, so
    /// renaming a label cannot silently drop its override.
    pub fn menu_rows(&self) -> Vec<(&'static str, &'static str, bool)> {
        let session = self.selected_session();
        let archived = session.map(|s| s.archived).unwrap_or(false);
        let has_secrets = session.map(|s| s.secrets_count > 0).unwrap_or(false);
        MENU_ITEMS
            .iter()
            .map(|(action, label, key)| match action {
                MenuAction::Archive if archived => (*key, "Unarchive", true),
                MenuAction::Secrets => (*key, *label, has_secrets),
                _ => (*key, *label, true),
            })
            .collect()
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

/// Rewrite the `target`-th queued task (0-based, lexical file order).
/// `Some(text)` replaces the task's content in place — the filename is kept,
/// so the task keeps its queue position; `None` removes the task file,
/// mirroring the CLI's `_queue_rm` in bin/cs. Replacement stages in
/// queue.tmp/ and renames, so the drain can never read a torn entry.
fn rewrite_queue_task(
    name: &str,
    target: usize,
    replacement: Option<&str>,
) -> std::io::Result<()> {
    let files = session::queue_task_files(name);
    let path = files.get(target).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "no queued task at that position")
    })?;
    match replacement {
        Some(text) => {
            let staging = session::queue_dir(name).join("queue.tmp");
            std::fs::create_dir_all(&staging)?;
            let staged = staging.join(path.file_name().unwrap_or_default());
            std::fs::write(&staged, format!("{}\n", text))?;
            std::fs::rename(&staged, path)
        }
        None => std::fs::remove_file(path),
    }
}

/// Rename the Claude Code conversation history directory to match the session rename.
/// The Claude home dir (`$HOME`), honoring a test-only thread-local override so
/// tests exercise the projects-dir logic without mutating the process-global
/// `HOME` (which races parallel tests' env reads). See [`test_home`]. Under
/// test it is only ever that override: with none scoped it is None, so no
/// test rename can move transcripts under the real `~/.claude`.
fn claude_home() -> Option<String> {
    #[cfg(test)]
    return test_home::current().map(|h| h.to_string_lossy().into_owned());
    #[cfg(not(test))]
    session::home_dir()
}

/// The home dir that holds `~/.cs-secrets`. Under test it is only ever the
/// [`test_home`] override: with none scoped it is None, so no test run can
/// reach the real `~/.cs-secrets` of whoever runs the suite.
fn secrets_home() -> Option<PathBuf> {
    #[cfg(test)]
    return test_home::current();
    #[cfg(not(test))]
    session::home_dir().map(PathBuf::from)
}

/// Where cs-secrets keeps a base session's age state (recipient pins and
/// digests): `~/.cs-secrets/sessions/<name>/`. Twin of `age_state_dir` in
/// bin/cs-secrets and `_drop_session_age_state` in lib/65-sessions.sh; the
/// three change together. None for a feature (`base@task`) name, whose
/// secrets are its base's, and for any name that is not one plain path
/// component, so an empty name never resolves to the sessions dir itself.
fn age_state_dir(name: &str) -> Option<PathBuf> {
    let mut parts = Path::new(name).components();
    let one_plain_component = matches!((parts.next(), parts.next()), (Some(Component::Normal(_)), None));
    // components() drops a trailing '/', so the slash is refused by hand.
    if !one_plain_component || name.starts_with('.') || name.contains('/') || name.contains('@') {
        return None;
    }
    Some(secrets_home()?.join(".cs-secrets/sessions").join(name))
}

/// True when cs-secrets began moving session `old`'s secrets to `new` and
/// did not finish: its marker `~/.cs-secrets/.rename.<old>` holds the line
/// `<new>`. It writes the marker before its first change and removes it
/// last, or once it has put a failed move back, so a refusal or a failure
/// leaves none, or one naming another unfinished move; a move it could not
/// put back, or that was killed, leaves it.
/// Twin of `marker` in rename_session_secrets in bin/cs-secrets; the two
/// change together.
fn secrets_move_unfinished(old: &str, new: &str) -> bool {
    let Some(home) = secrets_home() else {
        return false;
    };
    match std::fs::read(home.join(".cs-secrets").join(format!(".rename.{old}"))) {
        Ok(bytes) => bytes == format!("{new}\n").as_bytes(),
        Err(_) => false,
    }
}

/// Remove the age state of a base session that was just deleted. The path
/// when something was removed, None when there was nothing to remove.
fn drop_age_state(name: &str) -> Result<Option<PathBuf>, String> {
    let Some(dir) = age_state_dir(name) else {
        return Ok(None);
    };
    // `~/.cs-secrets/sessions` and `~/.cs-secrets` must be real directories:
    // through a link the removal would land on a same-name directory
    // elsewhere. Reading through the link is harmless, so only a state that is
    // there is named as left behind. An unsearchable parent fails the read
    // below with a permission error, never NotFound. cs-secrets refuses an age
    // command for a session the sessions root does not have, so only one that
    // passed that check before the delete can recreate the state after it (its
    // lock lives inside the dir removed here); that window is accepted.
    for parent in dir.ancestors().skip(1).take(2) {
        match parent.symlink_metadata() {
            Ok(meta) if meta.file_type().is_symlink() => {
                return match dir.symlink_metadata() {
                    Ok(_) => Err(format!("left age state behind a linked ~/.cs-secrets: {}", dir.display())),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                    Err(e) => Err(format!("could not read age state {}: {e}", dir.display())),
                };
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            _ => {}
        }
    }
    let meta = match dir.symlink_metadata() {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("could not read age state {}: {e}", dir.display())),
    };
    let removed = if meta.file_type().is_dir() {
        std::fs::remove_dir_all(&dir)
    } else {
        std::fs::remove_file(&dir)
    };
    match removed {
        Ok(()) => Ok(Some(dir)),
        Err(e) => Err(format!("could not remove age state {}: {e}", dir.display())),
    }
}

/// How a picker rename that kept the new name ended: everything moved, or the
/// directory moved and the secrets move began but did not finish.
enum RenameOutcome {
    Done,
    SecretsUnfinished,
}

/// Move session `old`'s secrets to `new` with `cs -secrets --session <old>
/// rename <new>`. The error is the last line cs printed on stderr, or how it
/// ended when it printed none.
fn move_secrets(old: &str, new: &str) -> Result<(), String> {
    let out = std::process::Command::new(cs_bin())
        .args(["-secrets", "--session", old, "rename", new])
        .output()
        .map_err(|e| format!("could not run cs -secrets rename: {e}"))?;
    if out.status.success() {
        return Ok(());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    match err.lines().rev().map(str::trim).find(|l| !l.is_empty()) {
        Some(line) => Err(line.to_string()),
        None => Err(format!("cs -secrets rename {}", out.status)),
    }
}

fn is_symlink(path: &Path) -> bool {
    path.symlink_metadata().map(|m| m.file_type().is_symlink()).unwrap_or(false)
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
/// Path encoding: every character outside [A-Za-z0-9] becomes '-' (Claude Code
/// 2.1.289: `.replace(/[^a-zA-Z0-9]/g,"-")`), so '_' and ' ' collapse too.
fn rename_claude_projects_dir(old_session_path: &std::path::Path, new_session_path: &std::path::Path) {
    fn encode_path(p: &std::path::Path) -> String {
        p.to_string_lossy()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect()
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
    use crate::session::{Liveness, Session};

    fn sample_sessions() -> Vec<Session> {
        vec![
            Session {
                name: "alpha".into(),
                is_adopted: false,
                created: Some("2026-01-01 10:00".into()),
                modified: Some("2026-02-20 14:00".into()),
                modified_ts: None,
                liveness: Liveness::Dormant,
                agent_status: None,
                secrets_count: 0,
                queue_depth: 0,
                unread_mail: 0,
                git_repo: Some("hex/alpha".into()),
                tags: Vec::new(),
                archived: false,
                vault: None,
                objective: None,
            },
            Session {
                name: "beta".into(),
                is_adopted: false,
                created: Some("2026-02-01 10:00".into()),
                modified: Some("2026-02-15 09:00".into()),
                modified_ts: None,
                liveness: Liveness::Dormant,
                agent_status: None,
                secrets_count: 2,
                queue_depth: 0,
                unread_mail: 0,
                git_repo: Some("hex/beta".into()),
                tags: Vec::new(),
                archived: false,
                vault: None,
                objective: None,
            },
            Session {
                name: "gamma".into(),
                is_adopted: true,
                created: Some("2025-12-01 10:00".into()),
                modified: Some("2026-01-10 08:00".into()),
                modified_ts: None,
                liveness: Liveness::Locked(12345),
                agent_status: None,
                secrets_count: 0,
                queue_depth: 0,
                unread_mail: 0,
                git_repo: None,
                tags: Vec::new(),
                archived: false,
                vault: None,
                objective: None,
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
    fn open_with_carries_a_session_and_its_argv_words() {
        let a = Action::OpenWith {
            session: "myproj".into(),
            args: vec!["-finish".into(), "fix-auth".into()],
        };
        match a {
            Action::OpenWith { session, args } => {
                assert_eq!(session, "myproj");
                assert_eq!(args, vec!["-finish".to_string(), "fix-auth".to_string()]);
                for w in &args {
                    assert!(!w.contains(' '), "argv words are word-split by the shell wrapper");
                }
            }
            _ => panic!("expected OpenWith"),
        }
    }

    #[test]
    fn parse_features_reads_a_porcelain_record() {
        let text = "fix-auth\tcs/fix-auth\t7\t0\t1\t0\t0\t0\tnone\tready\n\
                    flaky\tcs/flaky\t1\t0\t0\t0\t3\t0\tnone\tuntracked\n";
        let rows = parse_features(text);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].task, "fix-auth");
        assert_eq!(rows[0].ahead, 7);
        assert!(rows[0].ff, "ff is field 5");
        assert_eq!(rows[0].state, "ready");
        assert_eq!(rows[1].untracked, 3, "untracked is field 7");
        assert_eq!(rows[1].state, "untracked");
    }

    #[test]
    fn parse_features_ignores_malformed_lines() {
        // A short record means the verb changed shape; drop it rather than
        // render a row built from misaligned fields.
        let rows = parse_features("broken\tcs/broken\n\nfix-auth\tcs/fix-auth\t2\t0\t1\t0\t0\t0\tnone\tready\n");
        assert_eq!(rows.len(), 1, "only the well-formed record survives");
        assert_eq!(rows[0].task, "fix-auth");
    }

    fn feature_row(task: &str, state: &str) -> FeatureRow {
        FeatureRow {
            task: task.into(),
            branch: format!("cs/{task}"),
            ahead: 3,
            merged: false,
            ff: true,
            wt_dirty: false,
            untracked: 0,
            base_dirty: false,
            lock: "none".into(),
            state: state.into(),
        }
    }

    #[test]
    fn merge_mode_moves_selection_and_leaves_on_escape() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Merge;
        app.merge_base = "myproj".into();
        app.merge_features = vec![feature_row("fix-auth", "ready"), feature_row("flaky", "dirty")];
        app.merge_selected = 0;

        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.merge_selected, 1, "j moves down the feature list");
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(app.merge_selected, 1, "selection clamps at the last row");
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(app.merge_selected, 0, "k moves up");

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal, "Esc returns to the picker");
    }

    #[test]
    fn enter_hands_off_even_when_the_feature_is_blocked() {
        // The screen is advisory; cs is the authority. The ritual can resolve
        // most blockers — it offers to commit an uncommitted tree — where the
        // screen could only refuse.
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Merge;
        app.merge_base = "myproj".into();
        app.merge_features = vec![feature_row("flaky", "dirty")];
        app.merge_selected = 0;

        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
        match action {
            Action::OpenWith { session, args } => {
                assert_eq!(session, "myproj");
                assert_eq!(args, vec!["-finish".to_string(), "flaky".to_string()]);
            }
            other => panic!("a blocked feature must still hand off, got {other:?}"),
        }
    }

    #[test]
    fn enter_with_no_features_does_not_exit() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::Merge;
        app.merge_base = "myproj".into();
        app.merge_features = Vec::new();
        assert!(matches!(app.handle_key(KeyEvent::from(KeyCode::Enter)), Action::None));
        assert_eq!(app.mode, Mode::Merge, "an empty list stays put");
    }

    /// Serializes every test that sets, removes, or asserts on the
    /// process-global CS_BIN env var. Cargo runs tests on parallel threads, so
    /// an unguarded set_var races every concurrent reader of cs_bin().
    static CS_BIN_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// `sample_sessions()` has no `base@task` row. A dedicated fixture rather
    /// than a fourth entry in the shared one, so no existing test that counts
    /// or orders sessions changes behaviour.
    fn sessions_with_a_worktree() -> Vec<Session> {
        let mut v = sample_sessions();
        let base = v[0].clone();
        v.push(Session {
            name: format!("{}@fix-auth", base.name),
            ..base
        });
        v
    }

    #[test]
    fn m_on_a_worktree_row_opens_its_base() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // Point the probe at a path that cannot exist, so the fork fails the
        // same way on every machine. Without this the test forks the real cs
        // against the developer's real sessions root and its result depends on
        // whether cs happens to be on PATH.
        std::env::set_var("CS_BIN", "/nonexistent/cs");
        let mut app = App::new(sessions_with_a_worktree());
        app.apply_filter_and_sort();
        let i = app
            .filtered
            .iter()
            .position(|&i| app.sessions[i].name.contains('@'))
            .expect("the fixture must contain a worktree row");
        app.table_state.select(Some(i));
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        std::env::remove_var("CS_BIN");
        assert_eq!(app.merge_base, "alpha", "a worktree row opens its base");
        assert!(
            app.merge_features.is_empty(),
            "a failed probe must leave the list empty, not stale"
        );
        assert_ne!(app.mode, Mode::Merge, "a failed probe must not open an empty screen");
    }

    #[test]
    fn m_does_not_fire_while_the_notes_pane_has_focus() {
        // handle_normal routes to the notes input first, so `m` must type a
        // letter there rather than opening the merge screen.
        let mut app = App::new(sessions_with_a_worktree());
        app.focus = Focus::Notes;
        app.notes_focus = NotesFocus::Input;
        app.handle_key(KeyEvent::from(KeyCode::Char('m')));
        assert!(app.merge_base.is_empty(), "m must not open the screen from the notes input");
        assert_ne!(app.mode, Mode::Merge);
    }

    #[test]
    fn cs_bin_prefers_the_exported_path_over_bare_cs() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // cs exports its own path when it launches the picker. Without the
        // seam the TUI forks a bare "cs" that may not be on PATH at all.
        std::env::set_var("CS_BIN", "/opt/example/bin/cs");
        assert_eq!(cs_bin(), "/opt/example/bin/cs");
        std::env::set_var("CS_BIN", "");
        assert_eq!(cs_bin(), "cs", "an empty value must fall back, not fork nothing");
        std::env::remove_var("CS_BIN");
        assert_eq!(cs_bin(), "cs");
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

        app.mode = revealed_popup("KEY", "value", 0);
        assert!(app.has_timed_state());
        app.mode = secrets_mode(&["KEY"], 0);
        assert!(!app.has_timed_state());
        app.mode = Mode::Normal;

        app.mode = delete_confirm_on(DeleteTargets::One("alpha".into()));
        assert!(app.has_timed_state());
        app.mode = Mode::Normal;
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

    fn session_about(name: &str, objective: &str) -> Session {
        let mut s = session_with_tags(name, &[]);
        s.objective = Some(objective.into());
        s
    }

    // An adopted project or a harness-named worktree carries a name that says
    // nothing about the work; the objective is the one field that does.
    #[test]
    fn filter_reaches_the_objective_when_the_name_misses() {
        let mut app = App::new(vec![
            session_about("brave-jang-0f6265", "Rewrite the electron UI shell"),
            session_about("agent-a018e313", "Fix the login redirect"),
        ]);
        app.search_input.set("electron");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1);
        assert_eq!(app.sessions[app.filtered[0]].name, "brave-jang-0f6265");
    }

    // fuzzy_match's indices address the name string, so an objective hit must
    // not highlight anything or the row would bold the wrong characters.
    #[test]
    fn objective_hit_highlights_nothing() {
        let mut app = App::new(vec![session_about("brave-jang-0f6265", "Rewrite the electron UI shell")]);
        app.search_input.set("electron");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered, vec![0]);
        assert!(!app.fuzzy_indices.contains_key(&0), "an objective match carries no highlight indices");
    }

    #[test]
    fn name_hits_rank_before_objective_hits() {
        let mut app = App::new(vec![
            session_about("zzz-notes", "electron research"),
            session_about("electron-app", "Ship v2"),
        ]);
        app.search_input.set("electron");
        app.apply_filter_and_sort();
        let names: Vec<&str> = app.filtered.iter().map(|&i| app.sessions[i].name.as_str()).collect();
        assert_eq!(names, vec!["electron-app", "zzz-notes"]);
        assert!(app.fuzzy_indices.contains_key(&1), "the name hit keeps its highlight");
    }

    #[test]
    fn parse_tag_query_worked_examples() {
        assert_eq!(parse_tag_query("#api"), (vec!["api".into()], String::new()));
        assert_eq!(parse_tag_query("#api auth"), (vec!["api".into()], "auth".into()));
        assert_eq!(
            parse_tag_query("#api #infra srv"),
            (vec!["api".into(), "infra".into()], "srv".into())
        );
        assert_eq!(parse_tag_query("plain"), (vec![], "plain".into()));
        // A bare '#' produces an empty tag predicate that matches nothing
        assert_eq!(parse_tag_query("#"), (vec![String::new()], String::new()));
        assert_eq!(parse_tag_query("#API"), (vec!["api".into()], String::new()));
    }

    fn session_with_tags(name: &str, tags: &[&str]) -> Session {
        Session {
            name: name.into(),
            is_adopted: false,
            created: None,
            modified: None,
            modified_ts: None,
            liveness: Liveness::Dormant,
            agent_status: None,
            secrets_count: 0,
            queue_depth: 0,
            unread_mail: 0,
            git_repo: None,
            tags: tags.iter().map(|t| t.to_string()).collect(),
            archived: false,
            vault: None,
            objective: None,
        }
    }

    fn archived_session(name: &str) -> Session {
        Session {
            name: name.into(),
            is_adopted: false,
            created: Some("2026-01-01 10:00".into()),
            modified: Some("2026-02-20 14:00".into()),
            modified_ts: None,
            liveness: Liveness::Dormant,
            agent_status: None,
            secrets_count: 0,
            queue_depth: 0,
            unread_mail: 0,
            git_repo: None,
            tags: Vec::new(),
            archived: true,
            vault: None,
            objective: None,
        }
    }

    #[test]
    fn archived_sessions_hidden_by_default() {
        let mut sessions = sample_sessions();
        sessions.push(archived_session("olddone"));
        let app = App::new(sessions);
        assert_eq!(app.filtered.len(), 3);
        assert!(!app
            .filtered
            .iter()
            .any(|&i| app.sessions[i].name == "olddone"));
    }

    #[test]
    fn capital_a_toggles_archived_visibility() {
        let mut sessions = sample_sessions();
        sessions.push(archived_session("olddone"));
        let mut app = App::new(sessions);
        app.handle_key(KeyEvent::from(KeyCode::Char('A')));
        assert!(app.show_archived);
        assert_eq!(app.filtered.len(), 4);
        app.handle_key(KeyEvent::from(KeyCode::Char('A')));
        assert!(!app.show_archived);
        assert_eq!(app.filtered.len(), 3);
    }

    #[test]
    fn archived_hidden_from_fuzzy_search_too() {
        let mut sessions = sample_sessions();
        sessions.push(archived_session("alphadone"));
        let mut app = App::new(sessions);
        app.search_input.set("alpha");
        app.apply_filter_and_sort();
        assert!(app
            .filtered
            .iter()
            .all(|&i| app.sessions[i].name != "alphadone"));
    }

    fn filtered_names(app: &App) -> Vec<String> {
        app.filtered.iter().map(|&i| app.sessions[i].name.clone()).collect()
    }

    #[test]
    fn tag_filter_ands_and_composes_with_fuzzy() {
        // Three sessions: a(tags api,infra), b(tags api), c(no tags).
        // "#api" -> a and b; "#api #infra" -> a only; "#api b" -> b only.
        let mut app = App::new(vec![
            session_with_tags("a", &["api", "infra"]),
            session_with_tags("b", &["api"]),
            session_with_tags("c", &[]),
        ]);
        app.search_input.set("#api");
        app.apply_filter_and_sort();
        assert_eq!(filtered_names(&app), vec!["a", "b"]);
        app.search_input.set("#api #infra");
        app.apply_filter_and_sort();
        assert_eq!(filtered_names(&app), vec!["a"]);
        app.search_input.set("#api b");
        app.apply_filter_and_sort();
        assert_eq!(filtered_names(&app), vec!["b"]);
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
            liveness: Liveness::Dormant,
            agent_status: None,
            secrets_count: 0,
            queue_depth: 0,
            unread_mail: 0,
            git_repo: None,
            tags: Vec::new(),
            archived: false,
            vault: None,
            objective: None,
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
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
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
        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Session name must contain only alphanumeric characters, hyphens, underscores, and dots", StatusLevel::Error))
        );
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

    /// The secrets popup open on `names`, `selected` highlighted, nothing revealed.
    fn secrets_mode(names: &[&str], selected: usize) -> Mode {
        let names = names.iter().map(|n| n.to_string()).collect();
        Mode::Secrets { list: SecretsList { names, selected }, revealed: None }
    }

    /// The open secrets popup's list; panics when the popup is not open.
    fn secrets_list(app: &App) -> &SecretsList {
        match &app.mode {
            Mode::Secrets { list, .. } => list,
            other => panic!("expected the secrets popup, got {other:?}"),
        }
    }

    #[test]
    fn secrets_esc_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&[], 0);
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn secrets_q_returns_to_normal() {
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&[], 0);
        app.handle_key(KeyEvent::from(KeyCode::Char('q')));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn secrets_navigate_down() {
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&["KEY1", "KEY2", "KEY3"], 0);
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(secrets_list(&app).selected, 1);
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(secrets_list(&app).selected, 2);
        // Should not go past the end
        app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        assert_eq!(secrets_list(&app).selected, 2);
    }

    #[test]
    fn secrets_navigate_up() {
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&["KEY1", "KEY2"], 1);
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(secrets_list(&app).selected, 0);
        // Should not go below 0
        app.handle_key(KeyEvent::from(KeyCode::Char('k')));
        assert_eq!(secrets_list(&app).selected, 0);
    }

    #[test]
    fn command_output_returns_to_secrets_when_flagged() {
        let mut app = App::new(sample_sessions());
        let list = SecretsList { names: vec!["KEY1".into(), "KEY2".into()], selected: 0 };
        app.mode = Mode::CommandOutput { text: "value: 123".into(), then: ReturnTo::Secrets(list) };
        app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
        assert_eq!(app.mode, secrets_mode(&["KEY1", "KEY2"], 0));
    }

    #[test]
    fn command_output_returns_to_normal_when_not_flagged() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CommandOutput { text: "some output".into(), then: ReturnTo::Normal };
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

    /// The menu's Delete on a lock-held session opens the confirm the way
    /// the `d` key does: it says the session is live and offers removing it
    /// anyway (F, `cs -rm --force`), off until pressed.
    #[test]
    fn menu_delete_on_locked_session_opens_the_confirm_offering_force() {
        let mut app = App::new(sample_sessions());
        let pid = hold_gamma_lock(&mut app);
        // gamma (index 2) is locked.
        app.table_state.select(Some(2));
        app.mode = Mode::SessionMenu;
        app.menu_selected = 1;
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        let confirm = open_confirm(&mut app);
        assert_eq!(confirm.warnings, vec![session::DeleteWarning::line(format!("gamma is live (pid {pid})"))]);
        assert_eq!(
            confirm.offers,
            session::RemoveGrants { past_live_lock: true, unowned_files: false }
        );
        assert_eq!(confirm.grants, session::RemoveGrants::default(), "nothing is granted until F");
    }

    #[test]
    fn menu_delete_on_unlocked_session_opens_the_countdown() {
        let mut app = App::new(sample_sessions());
        // alpha (index 0) is not locked — the guard must not refuse everything.
        app.table_state.select(Some(0));
        app.mode = Mode::SessionMenu;
        app.menu_selected = 1;
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
        assert!(app.delete_countdown_remaining() > 0);
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
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
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
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
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
    fn auto_refresh_rescans_and_keeps_selection_by_name() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-refresh-{}", std::process::id()));
        for name in ["alpha", "bravo"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());

        let mut app = App::new(crate::session::scan_sessions());
        assert_eq!(app.sessions.len(), 2);
        let pos = app
            .filtered
            .iter()
            .position(|&i| app.sessions[i].name == "bravo")
            .unwrap();
        app.table_state.select(Some(pos));

        std::fs::create_dir_all(root.join("charlie").join(".cs/local")).unwrap();
        app.auto_refresh();
        // The event loop calls this between frames; a table that already grew
        // here would mean the rescan (one `git remote` per checkout session)
        // ran on the render thread and blocked every key press meanwhile.
        assert_eq!(
            app.sessions.len(),
            2,
            "auto_refresh must hand the scan to the worker, not run it here"
        );

        app.wait_for_scan();
        assert_eq!(app.sessions.len(), 3, "new session should appear after refresh");
        assert_eq!(app.selected_session_name().as_deref(), Some("bravo"));

        std::fs::remove_dir_all(&root).ok();
    }

    fn app_on(root: &std::path::Path, select: &str) -> App {
        let mut app = App::new(crate::session::scan_sessions());
        let pos = app.filtered.iter().position(|&i| app.sessions[i].name == select).unwrap();
        app.table_state.select(Some(pos));
        app
    }

    #[test]
    fn delete_confirm_names_files_cs_did_not_create() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-warn-{}", std::process::id()));
        std::fs::create_dir_all(root.join("rel/.cs/local")).unwrap();
        std::fs::create_dir_all(root.join("rel/journal.sparsebundle")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "rel");

        app.execute_menu_action(MenuAction::Delete);

        assert_eq!(
            open_confirm(&mut app).warnings,
            vec![session::DeleteWarning {
                text: "Also deletes files cs did not create:".to_string(),
                entries: vec![crate::untracked::Entry { path: "journal.sparsebundle".to_string(), files: 1 }],
            }]
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// A plain confirm deletes nothing the user put beside cs's files: y on a
    /// session holding one refuses, naming it, and the session survives.
    #[test]
    fn delete_confirm_y_refuses_a_session_holding_files_cs_did_not_create() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-refuse-{}", std::process::id()));
        std::fs::create_dir_all(root.join("rel/.cs/local")).unwrap();
        std::fs::create_dir_all(root.join("rel/journal.sparsebundle")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "rel");
        app.execute_menu_action(MenuAction::Delete);
        run_out_countdown(&mut app);

        app.handle_key(KeyEvent::from(KeyCode::Char('y')));

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert!(
            status.contains("rel holds files cs did not create: journal.sparsebundle"),
            "the refusal names the files, got: {status}"
        );
        assert!(root.join("rel/journal.sparsebundle").exists(), "the user's files survive");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn delete_confirm_stays_closed_when_the_file_list_cannot_be_read() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-broken-{}", std::process::id()));
        // The base is there, so the worktree is listed through git, which
        // cannot read the gitdir its .git file names.
        std::fs::create_dir_all(root.join("proj")).unwrap();
        std::fs::create_dir_all(root.join("proj@t/.cs/local")).unwrap();
        std::fs::write(root.join("proj@t/.git"), "gitdir: /nonexistent/worktree\n").unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "proj@t");

        app.execute_menu_action(MenuAction::Delete);

        assert!(matches!(app.mode, Mode::Normal), "confirm must not open on an unreadable list");
        assert!(root.join("proj@t").exists());
        std::fs::remove_dir_all(&root).ok();
    }

    // An encrypted session keeps Claude Code's config in its vault through
    // absolute links, and its transcripts under the old path's name; a rename
    // would strand both. A locked vault leaves the link dangling, so the
    // refusal has to hold for a link that resolves to nothing.
    #[test]
    fn rename_refuses_a_session_with_its_own_claude_config() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-rename-vault-{}", std::process::id()));
        std::fs::create_dir_all(root.join("vt/.cs/local")).unwrap();
        std::os::unix::fs::symlink(root.join("vt/.cs/vault-mnt/claude-config"), root.join("vt/.cs/claude-config"))
            .unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "vt");
        app.mode = Mode::Rename;
        app.rename_input.set("vt2");

        app.execute_rename();

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.as_str()),
            Some("Can't rename an encrypted session: its vault links name this path")
        );
        assert!(root.join("vt").is_dir(), "the session must stay where it is");
        assert!(!root.join("vt2").exists());
        std::fs::remove_dir_all(&root).ok();
    }

    // .cs/memory, .cs/plans and .cs/private are vault links too, each naming
    // the session's current path.
    #[test]
    fn rename_refuses_a_session_with_any_vault_link() {
        use crate::session::test_root;
        for sub in ["memory", "plans", "private"] {
            let root = std::env::temp_dir()
                .join(format!("cs-test-rename-{}-{}", sub, std::process::id()));
            std::fs::create_dir_all(root.join("vt/.cs/local")).unwrap();
            std::os::unix::fs::symlink(
                root.join(format!("vt/.cs/vault-mnt/{sub}")),
                root.join(format!("vt/.cs/{sub}")),
            )
            .unwrap();
            let _guard = test_root::scoped(root.clone());
            let mut app = app_on(&root, "vt");
            app.mode = Mode::Rename;
            app.rename_input.set("vt2");

            app.execute_rename();

            assert_eq!(
                app.status_message.as_ref().map(|m| m.text.as_str()),
                Some("Can't rename an encrypted session: its vault links name this path"),
                "a .cs/{sub} link must refuse"
            );
            assert!(root.join("vt").is_dir(), "the session must stay where it is");
            assert!(!root.join("vt2").exists());
            std::fs::remove_dir_all(&root).ok();
        }
    }

    /// A sessions root holding session `proj`, a home beside it, and a cs
    /// stand-in that logs its argv and hands `-secrets ...` to this checkout's
    /// bin/cs-secrets with HOME and the sessions root pointed at them, so the
    /// picker's rename runs the real secrets move against scratch state. A
    /// tool a test puts in `<tmp>/shim` shadows the real one for cs-secrets.
    /// The shim starts with a `security` that reports an empty Keychain:
    /// rename reads the Keychain on a Mac whatever the backend, and a test
    /// must never read the real one.
    /// With `fail` set the stand-in prints a refusal and exits 1 instead.
    #[cfg(unix)]
    fn rename_fixture(tag: &str, fail: bool) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let tmp = std::env::temp_dir().join(format!("cs-test-rename-{}-{}", tag, std::process::id()));
        std::fs::remove_dir_all(&tmp).ok();
        let root = tmp.join("root");
        let home = tmp.join("home");
        std::fs::create_dir_all(root.join("proj/.cs/local")).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(tmp.join("shim")).unwrap();
        std::fs::write(tmp.join("shim/security"), "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(tmp.join("shim/security"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let secrets = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../bin/cs-secrets");
        let body = if fail {
            "echo 'Error: refused by the stand-in' >&2\nexit 1\n".to_string()
        } else {
            format!(
                "[ \"$1\" = -secrets ] || exit 9\nshift\n\
                 HOME='{home}' CS_SESSIONS_ROOT='{root}' CS_SECRETS_BACKEND=encrypted PATH='{shim}':\"$PATH\" exec '{secrets}' \"$@\"\n",
                home = home.display(),
                root = root.display(),
                shim = tmp.join("shim").display(),
                secrets = secrets.display()
            )
        };
        let stub = tmp.join("cs-stub");
        std::fs::write(
            &stub,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" >> '{}'\n{}", tmp.join("argv").display(), body),
        )
        .unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        (tmp, root, home)
    }

    // The age pins under ~/.cs-secrets/sessions/<name>/ are keyed by the
    // session's name. After a picker rename no pin list may be left under a
    // name the sessions root no longer has: a later session given that name
    // would export to every key pinned there without an `age add`. The pins
    // follow the session to its new name.
    #[cfg(unix)]
    #[test]
    fn a_rename_leaves_no_age_state_under_a_name_without_a_session() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("age", false);
        let pins = home.join(".cs-secrets/sessions/proj");
        std::fs::create_dir_all(&pins).unwrap();
        std::fs::write(pins.join("age-trusted"), "0000000000000000000000000000000000000000000000000000000000000000\n")
            .unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.as_str()),
            Some("Renamed to: proj-old")
        );
        assert_eq!(
            std::fs::read_to_string(tmp.join("argv")).unwrap_or_default(),
            "-secrets\n--session\nproj\nrename\nproj-old\n",
            "the picker asks cs-secrets to move proj's secrets to proj-old"
        );
        let mut stranded: Vec<String> = std::fs::read_dir(home.join(".cs-secrets/sessions"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| !root.join(name).exists())
            .collect();
        stranded.sort();
        assert_eq!(stranded, Vec::<String>::new(), "age state left under a name with no session");
        assert_eq!(
            std::fs::read_to_string(home.join(".cs-secrets/sessions/proj-old/age-trusted")).unwrap_or_default(),
            "0000000000000000000000000000000000000000000000000000000000000000\n",
            "the pins are proj-old's now"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A live session is not renamed, as it is not deleted or rotated: its
    // claude keeps writing under the old path, and the lock and transcripts
    // would move from under it. The refusal is the one delete and rotate give.
    #[cfg(unix)]
    #[test]
    fn rename_refuses_a_live_session() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("live", false);
        let pid = std::process::id();
        std::fs::write(root.join("proj/.cs/session.lock"), format!("{pid}\n")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.handle_key(KeyEvent::from(KeyCode::Char('r')));
        app.rename_input.set("calm");

        app.handle_key(KeyEvent::from(KeyCode::Enter));
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.clone(), m.level)),
            Some((format!("proj is live (pid {pid}) — close it first"), StatusLevel::Error))
        );
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(
            std::fs::read_to_string(root.join("proj/.cs/session.lock")).unwrap_or_default(),
            format!("{pid}\n"),
            "the session and its lock stay where its claude has them"
        );
        assert!(!root.join("calm").exists(), "nothing is moved to the new name");
        assert!(!tmp.join("argv").exists(), "cs-secrets is never asked to move anything");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A session that opens while the rename modal is up is refused too, as
    // delete refuses it: the picker holds its rescans while a modal is open,
    // so the row still reads dormant and only the lock file says otherwise.
    #[cfg(unix)]
    #[test]
    fn rename_refuses_a_session_that_went_live_after_the_scan() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("live-later", false);
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.handle_key(KeyEvent::from(KeyCode::Char('r')));
        let pid = std::process::id();
        std::fs::write(root.join("proj/.cs/session.lock"), format!("{pid}\n")).unwrap();
        app.rename_input.set("calm");

        app.handle_key(KeyEvent::from(KeyCode::Enter));
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.clone(), m.level)),
            Some((format!("proj is live (pid {pid}) — close it first"), StatusLevel::Error))
        );
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(
            std::fs::read_to_string(root.join("proj/.cs/session.lock")).unwrap_or_default(),
            format!("{pid}\n"),
            "the session and its lock stay where its claude has them"
        );
        assert!(!root.join("calm").exists(), "nothing is moved to the new name");
        assert!(!tmp.join("argv").exists(), "cs-secrets is never asked to move anything");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A rename to a name cs refuses, one with a leading dot or hyphen, is
    // refused by the rule's name in cs's words: a session renamed to `.work`
    // drops out of every listing, and one named `-rm` reads as a cs verb.
    #[cfg(unix)]
    #[test]
    fn rename_refuses_a_name_cs_refuses_in_cs_words() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("lead", true);
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        for (name, refusal) in [
            (".work", "Session name cannot start with a dot"),
            ("-rm", "Session name cannot start with a hyphen"),
            ("..", "Session name cannot be '.' or '..'"),
            ("  ", "Session name cannot be empty"),
        ] {
            let mut app = app_on(&root, "proj");
            app.handle_key(KeyEvent::from(KeyCode::Char('r')));
            app.rename_input.set(name);

            app.handle_key(KeyEvent::from(KeyCode::Enter));

            assert_eq!(
                app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
                Some((refusal, StatusLevel::Error)),
                "{name}"
            );
            assert!(root.join("proj/.cs").is_dir(), "{name}: the session keeps its name");
            let listed: Vec<String> =
                std::fs::read_dir(&root).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
            assert_eq!(listed, ["proj"], "{name}: nothing is moved to the refused name");
        }
        std::env::remove_var("CS_BIN");
        assert!(!tmp.join("argv").exists(), "cs-secrets is never asked to move anything");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A spawn file the undo cannot move back is named in the status: the
    // refused rename otherwise reads as undone whole while the seed sits
    // under the new name. Here a seed staged under the old name while the
    // secrets move ran blocks the move back.
    #[cfg(unix)]
    #[test]
    fn a_rename_undo_names_a_spawn_file_it_cannot_move_back() {
        use crate::session::test_root;
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("spawn-undo", true);
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        std::fs::write(root.join(".spawn/proj.seed"), "task\n").unwrap();
        std::fs::write(
            tmp.join("cs-stub"),
            format!(
                "#!/bin/sh\nprintf 'other\\n' > '{}'\necho 'Error: refused by the stand-in' >&2\nexit 1\n",
                root.join(".spawn/proj.seed").display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(tmp.join("cs-stub"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.clone()),
            Some(format!(
                "Rename failed: Error: refused by the stand-in; could not move spawn file {} back to {}: File exists (os error 17)",
                root.join(".spawn/proj-old.seed").display(),
                root.join(".spawn/proj.seed").display()
            ))
        );
        assert!(root.join("proj/.cs").is_dir(), "the session keeps its name");
        assert_eq!(std::fs::read_to_string(root.join(".spawn/proj-old.seed")).unwrap_or_default(), "task\n", "the moved seed is still there");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A move cs-secrets refuses or fails undoes the rename: the session keeps
    // its name, and its transcripts and spawn seed stay where they were.
    #[cfg(unix)]
    #[test]
    fn a_rename_whose_secrets_move_fails_keeps_the_old_name() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("fail", true);
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        std::fs::write(root.join(".spawn/proj.seed"), "task\n").unwrap();
        let encode = |p: &std::path::Path| -> String {
            p.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
        };
        let transcripts = home.join(".claude/projects").join(encode(&root.join("proj")));
        std::fs::create_dir_all(&transcripts).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.as_str()),
            Some("Rename failed: Error: refused by the stand-in")
        );
        assert!(root.join("proj/.cs").is_dir(), "the session keeps its name");
        assert!(!root.join("proj-old").exists(), "no session under the new name");
        assert!(root.join(".spawn/proj.seed").is_file(), "the seed stays proj's");
        assert!(!root.join(".spawn/proj-old.seed").exists());
        assert!(transcripts.is_dir(), "the transcripts stay under the old path's name");
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// Store `value` as secret `name` of session `session` through the cs
    /// stand-in `rename_fixture` writes, on the encrypted backend.
    #[cfg(unix)]
    fn fixture_secret_set(tmp: &std::path::Path, session: &str, name: &str, value: &str) {
        let file = tmp.join("value");
        std::fs::write(&file, value).unwrap();
        let out = std::process::Command::new(tmp.join("cs-stub"))
            .args(["-secrets", "--session", session, "set", name])
            .env("CS_SECRETS_PASSWORD", "fixture-password")
            .stdin(std::fs::File::open(&file).unwrap())
            .output()
            .unwrap();
        assert!(out.status.success(), "fixture set: {}", String::from_utf8_lossy(&out.stderr));
    }

    /// Secret `name` of session `session` read through the cs stand-in, or
    /// what cs-secrets printed on stderr when it could not read it.
    #[cfg(unix)]
    fn fixture_secret_get(tmp: &std::path::Path, session: &str, name: &str) -> Result<String, String> {
        let out = std::process::Command::new(tmp.join("cs-stub"))
            .args(["-secrets", "--session", session, "get", name])
            .env("CS_SECRETS_PASSWORD", "fixture-password")
            .output()
            .unwrap();
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).trim_end().to_string())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        }
    }

    /// An `ln` in the fixture's shim that refuses every link whose target
    /// matches `pattern`, a sh case pattern, and hands the rest to /bin/ln.
    #[cfg(unix)]
    fn fixture_failing_ln(tmp: &std::path::Path, pattern: &str) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(
            tmp.join("shim/ln"),
            format!("#!/bin/sh\ncase \"$2\" in\n    {pattern}) exit 1 ;;\nesac\nexec /bin/ln \"$@\"\n"),
        )
        .unwrap();
        std::fs::set_permissions(tmp.join("shim/ln"), std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    // A move that fails after cs-secrets moved some of the secrets is put
    // back whole: cs-secrets returns every value to the old name, and the
    // picker moves the directory and the staged spawn seed back. The
    // encrypted store moves and linking the pin list then fails.
    #[cfg(unix)]
    #[test]
    fn a_rename_whose_secrets_move_fails_partway_keeps_the_old_name_whole() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("partial", false);
        let pins = home.join(".cs-secrets/sessions/proj");
        std::fs::create_dir_all(&pins).unwrap();
        std::fs::write(pins.join("age-trusted"), "0000000000000000000000000000000000000000000000000000000000000000\n")
            .unwrap();
        fixture_secret_set(&tmp, "proj", "E1", "value-enc");
        fixture_failing_ln(&tmp, "*/sessions/proj-old/*");
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        std::fs::write(root.join(".spawn/proj.seed"), "task\n").unwrap();
        let encode = |p: &std::path::Path| -> String {
            p.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
        };
        let transcripts = home.join(".claude/projects");
        std::fs::create_dir_all(transcripts.join(encode(&root.join("proj")))).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        let secrets = home.join(".cs-secrets");
        let status = app.status_message.as_ref().map(|m| (m.text.clone(), m.level));
        assert_eq!(
            status,
            Some((
                format!(
                    "Rename failed: Error: Refusing to move the secrets of session 'proj' to 'proj-old': could not move {} to {}",
                    secrets.join("sessions/proj/age-trusted").display(),
                    secrets.join("sessions/proj-old/age-trusted").display()
                ),
                StatusLevel::Error
            ))
        );
        assert!(root.join("proj/.cs").is_dir(), "the session keeps its name");
        assert!(!root.join("proj-old").exists(), "no session under the new name");
        assert!(root.join(".spawn/proj.seed").is_file(), "the seed is proj's");
        assert!(!root.join(".spawn/proj-old.seed").exists());
        assert!(transcripts.join(encode(&root.join("proj"))).is_dir(), "the transcripts stay under the old path's name");
        assert!(!transcripts.join(encode(&root.join("proj-old"))).exists());
        assert_eq!(fixture_secret_get(&tmp, "proj", "E1"), Ok("value-enc".to_string()), "E1 reads under proj");
        assert!(!secrets.join("proj-old.enc").exists(), "no encrypted store under proj-old");
        assert_eq!(
            std::fs::read_to_string(pins.join("age-trusted")).unwrap_or_default(),
            "0000000000000000000000000000000000000000000000000000000000000000\n",
            "the pins are proj's"
        );
        assert!(!secrets.join("sessions/proj-old").exists(), "no age state under proj-old");
        assert!(!secrets.join(".rename.proj").exists(), "no marker is left");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A TERM that reaches cs-secrets after it moved every value, while it
    // removes the old name's empty age directory, does not undo the rename:
    // the session and its secrets stay together under the new name.
    #[cfg(unix)]
    #[test]
    fn a_term_after_the_secrets_moved_keeps_the_rename() {
        use crate::session::test_root;
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("term-tail", false);
        let pins = home.join(".cs-secrets/sessions/proj");
        std::fs::create_dir_all(&pins).unwrap();
        std::fs::write(pins.join("age-trusted"), "0000000000000000000000000000000000000000000000000000000000000000\n")
            .unwrap();
        fixture_secret_set(&tmp, "proj", "E1", "value-enc");
        // The rmdir of proj's age directory runs once every value is under
        // proj-old; it sends TERM to cs-secrets, its parent, first.
        std::fs::write(
            tmp.join("shim/rmdir"),
            "#!/bin/sh\ncase \"$1\" in */sessions/proj) kill -TERM $PPID ;; esac\nexec /bin/rmdir \"$@\"\n",
        )
        .unwrap();
        std::fs::set_permissions(tmp.join("shim/rmdir"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Renamed to: proj-old", StatusLevel::Success))
        );
        assert!(root.join("proj-old/.cs").is_dir(), "the session has the new name");
        assert!(!root.join("proj").exists(), "no session under the old name");
        assert_eq!(fixture_secret_get(&tmp, "proj-old", "E1"), Ok("value-enc".to_string()), "E1 reads under proj-old");
        assert_eq!(
            std::fs::read_to_string(home.join(".cs-secrets/sessions/proj-old/age-trusted")).unwrap_or_default(),
            "0000000000000000000000000000000000000000000000000000000000000000\n",
            "the pins are proj-old's"
        );
        assert!(!home.join(".cs-secrets/.rename.proj").exists(), "no marker is left");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A lock cs-secrets cannot release once it has moved every value does
    // not undo the rename: the session and its secrets stay together under
    // the new name.
    #[cfg(unix)]
    #[test]
    fn a_lock_left_after_the_secrets_moved_keeps_the_rename() {
        use crate::session::test_root;
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("lock-tail", false);
        let pins = home.join(".cs-secrets/sessions/proj");
        std::fs::create_dir_all(&pins).unwrap();
        std::fs::write(pins.join("age-trusted"), "0000000000000000000000000000000000000000000000000000000000000000\n")
            .unwrap();
        fixture_secret_set(&tmp, "proj", "E1", "value-enc");
        // Written after the fixture's set, which releases the same lock: the
        // rename's release of proj's write lock fails.
        std::fs::write(
            tmp.join("shim/rm"),
            "#!/bin/sh\ncase \"$2\" in */.secrets-lock.proj) echo 'rm: simulated failure' >&2; exit 1 ;; esac\nexec /bin/rm \"$@\"\n",
        )
        .unwrap();
        std::fs::set_permissions(tmp.join("shim/rm"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Renamed to: proj-old", StatusLevel::Success))
        );
        assert!(root.join("proj-old/.cs").is_dir(), "the session has the new name");
        assert!(!root.join("proj").exists(), "no session under the old name");
        assert_eq!(fixture_secret_get(&tmp, "proj-old", "E1"), Ok("value-enc".to_string()), "E1 reads under proj-old");
        assert_eq!(
            std::fs::read_to_string(home.join(".cs-secrets/sessions/proj-old/age-trusted")).unwrap_or_default(),
            "0000000000000000000000000000000000000000000000000000000000000000\n",
            "the pins are proj-old's"
        );
        assert!(!home.join(".cs-secrets/.rename.proj").exists(), "no marker is left");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A move cs-secrets could not put back keeps its marker, which names the
    // new name, with values under both names. Moving the directory back
    // would leave those under a name the sessions root does not have, so the
    // session keeps the new name and the status gives the command that
    // finishes the move.
    #[cfg(unix)]
    #[test]
    fn a_rename_whose_secrets_move_cannot_be_put_back_keeps_the_new_name() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("unrestorable", false);
        let pins = home.join(".cs-secrets/sessions/proj");
        std::fs::create_dir_all(&pins).unwrap();
        std::fs::write(pins.join("age-trusted"), "0000000000000000000000000000000000000000000000000000000000000000\n")
            .unwrap();
        fixture_secret_set(&tmp, "proj", "E1", "value-enc");
        fixture_failing_ln(&tmp, "*/sessions/proj-old/*|*/proj.enc");
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        std::fs::write(root.join(".spawn/proj.seed"), "task\n").unwrap();
        let encode = |p: &std::path::Path| -> String {
            p.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
        };
        let transcripts = home.join(".claude/projects");
        std::fs::create_dir_all(transcripts.join(encode(&root.join("proj")))).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        let status = app.status_message.as_ref().map(|m| (m.text.as_str(), m.level));
        assert_eq!(
            status,
            Some(("Rename incomplete: run `cs -secrets --session proj rename proj-old`", StatusLevel::Error))
        );
        assert!(root.join("proj-old/.cs").is_dir(), "the session keeps the new name");
        assert!(!root.join("proj").exists(), "no session under the old name");
        assert!(root.join(".spawn/proj-old.seed").is_file(), "the seed is proj-old's");
        assert!(!root.join(".spawn/proj.seed").exists());
        assert!(transcripts.join(encode(&root.join("proj-old"))).is_dir(), "the transcripts follow the session");
        assert_eq!(
            std::fs::read_to_string(home.join(".cs-secrets/.rename.proj")).unwrap_or_default(),
            "proj-old\n",
            "the marker names the move to finish"
        );
        assert!(pins.join("age-trusted").is_file(), "the move stopped before the pins moved");

        // The command the status gives finishes the move.
        std::fs::remove_file(tmp.join("shim/ln")).unwrap();
        let out = std::process::Command::new(tmp.join("cs-stub"))
            .args(["-secrets", "--session", "proj", "rename", "proj-old"])
            .output()
            .unwrap();
        assert!(out.status.success(), "rerun: {}", String::from_utf8_lossy(&out.stderr));
        assert_eq!(fixture_secret_get(&tmp, "proj-old", "E1"), Ok("value-enc".to_string()), "E1 reads under proj-old");
        assert_eq!(
            std::fs::read_to_string(home.join(".cs-secrets/sessions/proj-old/age-trusted")).unwrap_or_default(),
            "0000000000000000000000000000000000000000000000000000000000000000\n",
            "the pins are proj-old's now"
        );
        assert!(!home.join(".cs-secrets/.rename.proj").exists(), "the finished move removes its marker");
        assert!(!pins.exists(), "nothing is left under proj");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A refusal made before cs-secrets changed anything leaves a marker only
    // when an earlier move of the session to another name did not finish: the
    // marker names that other name, the refusal changed nothing, and the
    // session keeps its old name.
    #[cfg(unix)]
    #[test]
    fn a_rename_refused_over_an_earlier_unfinished_move_keeps_the_old_name() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("stale-marker", false);
        std::fs::create_dir_all(home.join(".cs-secrets")).unwrap();
        std::fs::write(home.join(".cs-secrets/.rename.proj"), "elsewhere\n").unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.as_str()),
            Some(
                "Rename failed: Error: Refusing to move the secrets of session 'proj' to 'proj-old': an earlier \
                 move of 'proj' to 'elsewhere' did not finish; rerun: cs -secrets --session proj rename elsewhere"
            )
        );
        assert!(root.join("proj/.cs").is_dir(), "the session keeps its name");
        assert!(!root.join("proj-old").exists(), "no session under the new name");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A staged spawn seed and brief are keyed by the session's name: they go
    // with the session, or the next open of the old name would launch the
    // renamed session's tasks.
    #[cfg(unix)]
    #[test]
    fn a_rename_carries_the_staged_spawn_seed_and_brief() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("seed", false);
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        for suffix in [".seed", ".seed.stale", ".brief.md", ".brief.md.stale"] {
            std::fs::write(root.join(format!(".spawn/proj{suffix}")), format!("staged{suffix}\n")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.as_str()),
            Some("Renamed to: proj-old")
        );
        let mut staged: Vec<String> = std::fs::read_dir(root.join(".spawn"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        staged.sort();
        assert_eq!(
            staged,
            vec!["proj-old.brief.md", "proj-old.brief.md.stale", "proj-old.seed", "proj-old.seed.stale"]
        );
        assert_eq!(
            std::fs::read_to_string(root.join(".spawn/proj-old.seed")).unwrap(),
            "staged.seed\n",
            "the seed moved whole"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A seed already staged for the new name belongs to a spawn of that name;
    // the rename refuses rather than overwrite it, and changes nothing.
    #[cfg(unix)]
    #[test]
    fn a_rename_refuses_a_new_name_with_a_staged_spawn_seed() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("seed-taken", false);
        std::fs::create_dir_all(root.join(".spawn")).unwrap();
        std::fs::write(root.join(".spawn/proj.seed"), "mine\n").unwrap();
        std::fs::write(root.join(".spawn/proj-old.brief.md"), "theirs\n").unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        let taken = root.join(".spawn/proj-old.brief.md");
        assert_eq!(
            app.status_message.as_ref().map(|m| m.text.clone()),
            Some(format!("Can't rename: a spawn is staged for proj-old: {}", taken.display()))
        );
        assert!(root.join("proj/.cs").is_dir(), "the session keeps its name");
        assert!(!root.join("proj-old").exists());
        assert_eq!(std::fs::read_to_string(root.join(".spawn/proj.seed")).unwrap(), "mine\n");
        assert_eq!(std::fs::read_to_string(&taken).unwrap(), "theirs\n");
        assert!(!tmp.join("argv").exists(), "cs-secrets is never asked to move anything");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // An adopted session whose disk is not mounted is a link at the sessions
    // root that leads nowhere. Its name is taken all the same: renaming
    // another adopted session (a link too, which rename(2) would move over
    // it) refuses rather than replace the link, and changes nothing.
    #[cfg(unix)]
    #[test]
    fn a_rename_refuses_a_new_name_held_by_a_dangling_link() {
        use crate::session::test_root;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (tmp, root, home) = rename_fixture("dangling", false);
        let adopted = tmp.join("code/proj");
        std::fs::create_dir_all(tmp.join("code")).unwrap();
        std::fs::rename(root.join("proj"), &adopted).unwrap();
        std::os::unix::fs::symlink(&adopted, root.join("proj")).unwrap();
        let unmounted = tmp.join("unmounted/proj-old");
        std::os::unix::fs::symlink(&unmounted, root.join("proj-old")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        std::env::set_var("CS_BIN", tmp.join("cs-stub"));
        let mut app = app_on(&root, "proj");
        app.mode = Mode::Rename;
        app.rename_input.set("proj-old");

        app.execute_rename();
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Name already taken", StatusLevel::Error))
        );
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(std::fs::read_link(root.join("proj")).unwrap(), adopted, "the session keeps its name");
        assert_eq!(std::fs::read_link(root.join("proj-old")).unwrap(), unmounted, "the link stays as it was");
        assert!(!tmp.join("argv").exists(), "cs-secrets is never asked to move anything");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn a_rescan_finishing_under_a_modal_waits_for_normal_mode() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-modal-scan-{}", std::process::id()));
        for name in ["alpha", "bravo"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());
        let mut app = App::new(crate::session::scan_sessions());
        let pos = app
            .filtered
            .iter()
            .position(|&i| app.sessions[i].name == "bravo")
            .unwrap();
        app.table_state.select(Some(pos));

        // A periodic rescan starts, then the user opens the delete dialog on
        // bravo while another process removes bravo from disk.
        app.auto_refresh();
        app.mode = delete_confirm_on(DeleteTargets::One("bravo".into()));
        std::fs::remove_dir_all(root.join("bravo")).unwrap();
        // Make the worker's read see the removal: wait for its answer, then
        // request one more so the applied read is post-removal.
        while app.scan_results.try_recv().is_err() {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        app.scan_pending = None;
        app.auto_refresh();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !app.drain_scans() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // The dialog is still open: the table under it must be untouched, or
        // a modal acting on the selection would act on whichever row it fell
        // back to.
        assert_eq!(app.sessions.len(), 2, "a scan must not land under a modal");
        assert_eq!(app.selected_session_name().as_deref(), Some("bravo"));

        app.mode = Mode::Normal;
        assert!(app.drain_scans(), "the deferred scan lands once the modal closes");
        assert_eq!(app.sessions.len(), 1);

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_rescan_superseded_by_rescan_now_is_dropped() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-stale-scan-{}", std::process::id()));
        for name in ["alpha", "bravo"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());
        let mut app = App::new(crate::session::scan_sessions());
        assert_eq!(app.sessions.len(), 2);

        // The worker starts reading two sessions; before it answers, the user
        // deletes one and the table is rescanned on the spot.
        app.auto_refresh();
        std::fs::remove_dir_all(root.join("bravo")).unwrap();
        app.rescan_now();
        assert_eq!(app.sessions.len(), 1);

        // The worker's read may still hold bravo. Whatever it delivers must
        // not put the deleted row back.
        let (generation, stale) = app.scan_results.recv().unwrap();
        assert!(
            !app.accept_scan((generation, stale)),
            "a scan requested before rescan_now must be dropped, not applied"
        );
        assert_eq!(app.sessions.len(), 1);

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn rename_claude_projects_dir_moves_matching_dir() {
        let tmp = std::env::temp_dir().join(format!("cs-test-proj-rename-{}", std::process::id()));
        let fake_projects = tmp.join(".claude/projects");
        let sessions = tmp.join("sessions");

        let old_session = sessions.join("old_name");
        let new_session = sessions.join("new_name");

        // Claude Code names the projects dir by replacing every character
        // outside [A-Za-z0-9] with '-' (measured on 2.1.289: 'enc_probe dir'
        // became 'enc-probe-dir'), so the fixture is seeded under that name.
        fn encode_path(p: &std::path::Path) -> String {
            p.to_string_lossy()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect()
        }
        let old_encoded = encode_path(&old_session);
        assert!(
            old_encoded.ends_with("-sessions-old-name"),
            "fixture encoding drifted from claude's: {old_encoded}"
        );
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

    // A rename moves the transcripts under the Claude home, so a test that
    // renames without scoping a home must reach no ~/.claude at all.
    #[test]
    fn an_unscoped_test_build_has_no_claude_home() {
        assert_eq!(claude_home(), None);
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
        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Session name must contain only alphanumeric characters, hyphens, underscores, and dots", StatusLevel::Error))
        );
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

    // A link at the sessions root that leads nowhere (an adopted session on
    // a disk that is not mounted) holds its name: the picker opens nothing
    // under it and leaves the link as it was.
    #[cfg(unix)]
    #[test]
    fn create_session_refuses_a_name_held_by_a_dangling_link() {
        let tmp = std::env::temp_dir().join(format!("cs-tui-create-dangling-{}", std::process::id()));
        std::fs::remove_dir_all(&tmp).ok();
        std::fs::create_dir_all(&tmp).unwrap();
        let unmounted = tmp.join("unmounted/held");
        std::os::unix::fs::symlink(&unmounted, tmp.join("held")).unwrap();
        let _root = session::test_root::scoped(tmp.clone());
        let mut app = App::new(sample_sessions());
        app.mode = Mode::CreateSession;
        app.create_input.set("held");

        let action = app.handle_key(KeyEvent::from(KeyCode::Enter));

        assert!(matches!(action, Action::None), "nothing is opened, got {action:?}");
        assert_eq!(app.mode, Mode::Normal);
        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
            Some(("Session already exists", StatusLevel::Error))
        );
        assert_eq!(std::fs::read_link(tmp.join("held")).unwrap(), unmounted, "the link stays as it was");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // cs refuses a name with a leading dot (its own staging dirs, .spawn and
    // .usage, sit at the sessions root under dot names) or a leading hyphen
    // (`cs -uninstall` runs a verb), so the picker creates neither, and says
    // which rule the name breaks in cs's words, as it does for an empty name.
    #[test]
    fn create_session_refuses_a_name_cs_refuses_in_cs_words() {
        let tmp = std::env::temp_dir().join(format!("cs-tui-create-lead-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).ok();
        let _root = session::test_root::scoped(tmp.clone());
        for (name, refusal) in [
            ("-uninstall", "Session name cannot start with a hyphen"),
            (".spawn", "Session name cannot start with a dot"),
            ("..", "Session name cannot be '.' or '..'"),
            ("  ", "Session name cannot be empty"),
        ] {
            let mut app = App::new(sample_sessions());
            app.mode = Mode::CreateSession;
            app.create_input.set(name);
            let action = app.handle_key(KeyEvent::from(KeyCode::Enter));
            assert!(matches!(action, Action::None), "{name}: nothing is opened, got {action:?}");
            assert_eq!(app.mode, Mode::Normal);
            assert_eq!(
                app.status_message.as_ref().map(|m| (m.text.as_str(), m.level)),
                Some((refusal, StatusLevel::Error)),
                "{name}"
            );
        }
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
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
        assert!(app.delete_countdown_remaining() > 0);
    }

    #[test]
    fn confirm_delete_y_rejected_during_countdown() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Countdown just started — y should be rejected
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        assert!(matches!(app.mode, Mode::ConfirmDelete(_))); // still in confirm mode
        assert_eq!(app.sessions.len(), 3); // not deleted
        // Should show a "Wait..." status message
        assert!(app.status_message.as_ref().unwrap().text.contains("Wait"));
    }

    #[test]
    fn confirm_delete_y_accepted_after_countdown() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Simulate countdown elapsed by backdating the start
        open_confirm(&mut app).countdown_start =
            std::time::Instant::now() - std::time::Duration::from_secs(3);
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        // execute_delete runs and returns to Normal
        // (actual filesystem delete fails in tests, but mode change confirms acceptance)
        assert_eq!(app.mode, Mode::Normal);
    }

    /// Select the row whose session has `name`, whatever the current sort.
    fn select_named(app: &mut App, name: &str) {
        let idx = app
            .filtered
            .iter()
            .position(|&i| app.sessions[i].name == name)
            .expect("session should be in the filtered set");
        app.table_state.select(Some(idx));
    }

    /// The open delete confirm; panics when none is open.
    fn open_confirm(app: &mut App) -> &mut DeleteConfirm {
        match &mut app.mode {
            Mode::ConfirmDelete(confirm) => confirm,
            other => panic!("expected the delete confirm, got {other:?}"),
        }
    }

    /// Runs the open confirm's countdown out, so `y` is taken.
    fn run_out_countdown(app: &mut App) {
        open_confirm(app).countdown_start = std::time::Instant::now() - std::time::Duration::from_secs(60);
    }

    /// A delete confirm on `targets` that warns of and offers nothing, its
    /// countdown just started.
    fn delete_confirm_on(targets: DeleteTargets) -> Mode {
        Mode::ConfirmDelete(DeleteConfirm {
            targets,
            countdown_start: std::time::Instant::now(),
            warnings: Vec::new(),
            offers: session::RemoveGrants::default(),
            grants: session::RemoveGrants::default(),
        })
    }

    /// Gives gamma's lock to this test process, which is alive for as long as
    /// the test runs, and returns the pid as the status prints it.
    fn hold_gamma_lock(app: &mut App) -> String {
        let pid = std::process::id();
        app.sessions.iter_mut().find(|s| s.name == "gamma").unwrap().liveness = Liveness::Locked(pid);
        pid.to_string()
    }

    /// `cs -rm` refuses a lock-held session without --force (lib/15-lock.sh's
    /// session_is_live is lock-based, so Locked and not merely Heartbeat is the
    /// matching predicate). The TUI reaches the same filesystem removal and must
    /// refuse it too. Asserting on the pid in the status is what separates a
    /// refusal from a delete that merely failed for some other reason.
    #[test]
    fn delete_refuses_a_locked_session() {
        let mut app = App::new(sample_sessions());
        let pid = hold_gamma_lock(&mut app);
        select_named(&mut app, "gamma");

        // Called directly rather than through `d`+`y`: this is the guard that
        // has to hold even when the row takes the lock after the confirmation
        // was opened, so the key path must not be what proves it.
        app.execute_delete("gamma", session::RemoveGrants::default());

        assert_eq!(app.mode, Mode::Normal);
        let status = app
            .status_message
            .as_ref()
            .expect("refusing should explain itself");
        assert!(
            status.text.contains(&pid),
            "status should name the locking pid, got: {}",
            status.text
        );
        assert!(
            !status.text.contains("Deleted"),
            "a refusal must not report a deletion, got: {}",
            status.text
        );
    }

    /// A plain confirm on a locked row refuses, as `cs -rm` does without
    /// --force: y names the locking pid and deletes nothing.
    #[test]
    fn confirm_delete_y_refuses_a_locked_session() {
        let mut app = App::new(sample_sessions());
        let pid = hold_gamma_lock(&mut app);
        select_named(&mut app, "gamma");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)));
        run_out_countdown(&mut app);
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));

        assert_eq!(app.mode, Mode::Normal);
        assert!(app
            .status_message
            .as_ref()
            .is_some_and(|s| s.text.contains(&format!("gamma is live (pid {pid})"))));
    }

    /// F grants the live lock (`cs -rm --force`): the confirm then removes
    /// a session whose lock a live process holds.
    #[test]
    fn confirm_delete_f_then_y_removes_a_live_session() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-force-{}", std::process::id()));
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{}\n", std::process::id())).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "busy");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert!(open_confirm(&mut app).offers.past_live_lock, "a live session is offered F");
        app.handle_key(KeyEvent::from(KeyCode::Char('F')));
        assert!(open_confirm(&mut app).grants.past_live_lock);
        run_out_countdown(&mut app);
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));

        assert!(!root.join("busy").exists(), "status: {:?}", app.status_message.as_ref().map(|m| &m.text));
        assert_eq!(app.mode, Mode::Normal, "a closed confirm keeps no grant");
        std::fs::remove_dir_all(&root).ok();
    }

    /// From inside another session, a session that opens after its delete
    /// confirm did is refused at y, in cs's words: the removal reads the
    /// lock again whatever the confirm saw.
    #[test]
    fn confirm_delete_y_refuses_a_session_that_went_live_from_another_session() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-del-force-other-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        let pid = std::process::id();
        let _guard = test_root::scoped(root.clone());
        let _caller = test_caller::scoped("caller");
        let mut app = app_on(&root, "busy");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert!(matches!(app.mode, Mode::ConfirmDelete(_)), "a dormant session opens the confirm");
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{pid}\n")).unwrap();
        run_out_countdown(&mut app);
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("Delete failed: session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "the live session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// From inside another session, d on a live session refuses at once in
    /// `cs -rm`'s words: no confirm opens, so no [F] is offered that the
    /// removal would refuse.
    #[test]
    fn delete_from_another_session_refuses_a_live_session_before_the_confirm() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-del-open-other-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        let pid = std::process::id();
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{pid}\n")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _caller = test_caller::scoped("caller");
        let mut app = app_on(&root, "busy");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));

        assert_eq!(app.mode, Mode::Normal, "the confirm stays closed");
        assert!(!matches!(app.mode, Mode::ConfirmDelete(_)), "nothing is offered");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "the live session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// From inside another session, d on a base while one of its features
    /// is live refuses at once, naming the feature in `cs -rm`'s words.
    #[test]
    fn delete_from_another_session_refuses_a_base_with_a_live_feature_before_the_confirm() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-del-open-base-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for name in ["proj", "proj@task"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let pid = std::process::id();
        std::fs::write(root.join("proj@task/.cs/session.lock"), format!("{pid}\n")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _caller = test_caller::scoped("other");
        let mut app = app_on(&root, "proj");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));

        assert_eq!(app.mode, Mode::Normal, "the confirm stays closed");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("session other cannot remove session proj while its feature proj@task is live (pid {pid}); --force does not override that from another session. Close proj@task first.")
        );
        assert!(root.join("proj/.cs").is_dir(), "the base is left whole");
        std::fs::remove_dir_all(&root).ok();
    }

    /// From inside another session, D refuses the whole batch at once when
    /// any marked session is one `cs -rm` would refuse from there, whichever
    /// place it holds in the batch; the marks stay for the user to change.
    #[test]
    fn batch_delete_from_another_session_refuses_before_the_confirm() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-batch-open-other-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for name in ["a-idle", "busy"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let pid = std::process::id();
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{pid}\n")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _caller = test_caller::scoped("caller");
        let mut app = app_on(&root, "busy");
        for name in ["a-idle", "busy"] {
            app.marked_sessions.insert(name.to_string());
        }

        app.handle_key(KeyEvent::from(KeyCode::Char('D')));

        assert_eq!(app.mode, Mode::Normal, "the confirm stays closed");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert_eq!(app.marked_sessions.len(), 2, "the marks stay");
        assert!(root.join("a-idle/.cs").is_dir(), "nothing in the batch is removed");
        assert!(root.join("busy/.cs/session.lock").exists(), "the live session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// Where `cs -rm` would not refuse, d opens the confirm as before and
    /// offers [F] on a live row: the caller's own session, a base with a
    /// live feature from inside that base, and any session from a picker
    /// outside every session.
    #[test]
    fn delete_confirm_opens_where_cs_rm_would_not_refuse_from_the_caller() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-del-open-own-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for name in ["busy", "proj", "proj@task"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let pid = std::process::id();
        for name in ["busy", "proj@task"] {
            std::fs::write(root.join(name).join(".cs/session.lock"), format!("{pid}\n")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());
        for (caller, target, offers_f) in [(Some("busy"), "busy", true), (Some("proj"), "proj", false), (None, "busy", true), (None, "proj", false)] {
            let _caller = caller.map(test_caller::scoped);
            let mut app = app_on(&root, target);

            app.handle_key(KeyEvent::from(KeyCode::Char('d')));

            assert!(matches!(app.mode, Mode::ConfirmDelete(_)), "caller {caller:?}, target {target}");
            assert_eq!(open_confirm(&mut app).offers.past_live_lock, offers_f, "caller {caller:?}, target {target}");
        }
        std::fs::remove_dir_all(&root).ok();
    }

    /// A batch granted F from inside another session refuses the live
    /// session in cs's words and still deletes the dormant one beside it.
    #[test]
    fn batch_delete_past_the_live_grant_refuses_a_live_session_from_another_session() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-batch-force-other-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        std::fs::create_dir_all(root.join("idle/.cs/local")).unwrap();
        let pid = std::process::id();
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{pid}\n")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let _caller = test_caller::scoped("caller");
        let mut app = app_on(&root, "busy");
        let grants = session::RemoveGrants { past_live_lock: true, unowned_files: false };

        app.execute_batch_delete(&["busy".to_string(), "idle".to_string()], grants);

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("Deleted 1, 1 failed — session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "the live session survives");
        assert!(!root.join("idle").exists(), "the dormant session goes");
        std::fs::remove_dir_all(&root).ok();
    }

    /// A process whose argv carries `remote-control --name <name>`, as the
    /// `claude remote-control` server `cs <name> --remote` runs does.
    fn fake_remote_server(name: &str) -> std::process::Child {
        std::process::Command::new("perl")
            .args(["-e", "sleep 30", "remote-control", "--name", name, "--permission-mode", "default"])
            .spawn()
            .unwrap()
    }

    /// Serve session `name` under `root` as `cs <name> --remote` does: the
    /// session lock and `.cs/local/remote.pid` name `server`.
    fn serve(root: &std::path::Path, name: &str, server: &std::process::Child) {
        let meta = root.join(name).join(".cs");
        std::fs::write(meta.join("session.lock"), format!("{}\n", server.id())).unwrap();
        std::fs::write(meta.join("local/remote.pid"), format!("{}\n", server.id())).unwrap();
    }

    fn stop(mut child: std::process::Child) {
        let _ = child.kill();
        let _ = child.wait();
    }

    /// d on a session a `cs <name> --remote` server serves refuses at once
    /// in `cs -rm`'s words, inside its own session or outside every
    /// session: no confirm opens, so no [F] is offered past it.
    #[test]
    fn delete_refuses_a_served_session_before_the_confirm() {
        use crate::session::{test_caller, test_root};
        let root = std::env::temp_dir().join(format!("cs-test-del-served-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        let server = fake_remote_server("busy");
        let spid = server.id();
        serve(&root, "busy", &server);
        let _guard = test_root::scoped(root.clone());
        let mut seen = Vec::new();
        for caller in [None, Some("busy")] {
            let _caller = caller.map(test_caller::scoped);
            let mut app = app_on(&root, "busy");

            app.handle_key(KeyEvent::from(KeyCode::Char('d')));

            let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
            seen.push((caller, app.mode == Mode::Normal, matches!(app.mode, Mode::ConfirmDelete(_)), status));
        }
        stop(server);
        for (caller, closed, offered, status) in seen {
            assert!(closed, "caller {caller:?}: the confirm stays closed");
            assert!(!offered, "caller {caller:?}: nothing is offered");
            assert_eq!(
                status,
                format!("Session busy is served by cs busy --remote (remote-control PID {spid}); stop it first with Ctrl-C in its window, or close the window."),
                "caller {caller:?}"
            );
        }
        assert!(root.join("busy/.cs/local/remote.pid").exists(), "the served session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// A server that starts after the delete confirm opened is refused at y
    /// in `cs -rm`'s words, with [F] granted or not: the removal reads
    /// remote.pid again whatever the confirm saw. Without [F] the row was
    /// dormant when the confirm opened; with it the row was live, so [F]
    /// was offered.
    #[test]
    fn confirm_delete_y_refuses_a_session_served_after_the_confirm_opened() {
        use crate::session::test_root;
        for force in [false, true] {
            let root = std::env::temp_dir().join(format!("cs-test-del-served-late-{force}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
            if force {
                std::fs::write(root.join("busy/.cs/session.lock"), format!("{}\n", std::process::id())).unwrap();
            }
            let _guard = test_root::scoped(root.clone());
            let mut app = app_on(&root, "busy");

            app.handle_key(KeyEvent::from(KeyCode::Char('d')));
            assert!(matches!(app.mode, Mode::ConfirmDelete(_)), "force {force}: an unserved session opens the confirm");
            if force {
                app.handle_key(KeyEvent::from(KeyCode::Char('F')));
                assert!(open_confirm(&mut app).grants.past_live_lock, "a live session is granted F");
            }
            let server = fake_remote_server("busy");
            let spid = server.id();
            serve(&root, "busy", &server);
            run_out_countdown(&mut app);
            app.handle_key(KeyEvent::from(KeyCode::Char('y')));
            stop(server);

            let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
            assert_eq!(
                status,
                format!("Delete failed: Session busy is served by cs busy --remote (remote-control PID {spid}); stop it first with Ctrl-C in its window, or close the window."),
                "force {force}"
            );
            assert!(root.join("busy/.cs/local/remote.pid").exists(), "force {force}: the served session survives");
            std::fs::remove_dir_all(&root).ok();
        }
    }

    /// D refuses the whole batch at once when any marked session is served,
    /// whichever place it holds in the batch; the marks stay.
    #[test]
    fn batch_delete_refuses_before_the_confirm_when_a_marked_session_is_served() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-batch-served-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for name in ["a-idle", "busy"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let server = fake_remote_server("busy");
        let spid = server.id();
        serve(&root, "busy", &server);
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "busy");
        for name in ["a-idle", "busy"] {
            app.marked_sessions.insert(name.to_string());
        }

        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        stop(server);

        assert_eq!(app.mode, Mode::Normal, "the confirm stays closed");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("Session busy is served by cs busy --remote (remote-control PID {spid}); stop it first with Ctrl-C in its window, or close the window.")
        );
        assert_eq!(app.marked_sessions.len(), 2, "the marks stay");
        assert!(root.join("a-idle/.cs").is_dir(), "nothing in the batch is removed");
        assert!(root.join("busy/.cs/local/remote.pid").exists(), "the served session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// A batch granted F whose session became served after the confirm
    /// opened refuses that session in cs's words and still deletes the
    /// dormant one beside it.
    #[test]
    fn batch_delete_past_the_live_grant_refuses_a_session_served_after_the_confirm_opened() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-batch-served-late-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for name in ["busy", "idle"] {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "busy");
        let grants = session::RemoveGrants { past_live_lock: true, unowned_files: false };
        let server = fake_remote_server("busy");
        let spid = server.id();
        serve(&root, "busy", &server);

        app.execute_batch_delete(&["busy".to_string(), "idle".to_string()], grants);
        stop(server);

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(
            status,
            format!("Deleted 1, 1 failed — Session busy is served by cs busy --remote (remote-control PID {spid}); stop it first with Ctrl-C in its window, or close the window.")
        );
        assert!(root.join("busy/.cs/local/remote.pid").exists(), "the served session survives");
        assert!(!root.join("idle").exists(), "the dormant session goes");
        std::fs::remove_dir_all(&root).ok();
    }

    /// A remote.pid that serves nothing leaves a live session to the plain
    /// live check, as `cs -rm` leaves it: its pid not running, running
    /// another program, or running the server of another session. d opens
    /// the confirm with [F] offered, and F then y removes the session.
    #[test]
    fn delete_confirm_offers_f_on_a_live_session_whose_remote_pid_serves_nothing() {
        use crate::session::test_root;
        for (tag, holder) in [("dead", None), ("program", Some(false)), ("other", Some(true))] {
            let root = std::env::temp_dir().join(format!("cs-test-del-unserved-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
            std::fs::write(root.join("busy/.cs/session.lock"), format!("{}\n", std::process::id())).unwrap();
            let process = holder.map(|server| {
                if server {
                    fake_remote_server("other")
                } else {
                    std::process::Command::new("sleep").arg("30").spawn().unwrap()
                }
            });
            let remote_pid = process.as_ref().map_or("99999999".to_string(), |p| p.id().to_string());
            std::fs::write(root.join("busy/.cs/local/remote.pid"), format!("{remote_pid}\n")).unwrap();
            let _guard = test_root::scoped(root.clone());
            let mut app = app_on(&root, "busy");

            app.handle_key(KeyEvent::from(KeyCode::Char('d')));
            let opened = matches!(app.mode, Mode::ConfirmDelete(_));
            let offers = match &app.mode {
                Mode::ConfirmDelete(confirm) => confirm.offers,
                _ => session::RemoveGrants::default(),
            };
            app.handle_key(KeyEvent::from(KeyCode::Char('F')));
            if let Mode::ConfirmDelete(confirm) = &mut app.mode {
                confirm.countdown_start = std::time::Instant::now() - std::time::Duration::from_secs(60);
            }
            app.handle_key(KeyEvent::from(KeyCode::Char('y')));
            if let Some(p) = process {
                stop(p);
            }

            let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
            assert!(opened, "{tag}: the confirm opens; status: {status}");
            assert_eq!(
                offers,
                session::RemoveGrants { past_live_lock: true, unowned_files: false },
                "{tag}: F is offered"
            );
            assert_eq!(status, "Deleted: busy", "{tag}");
            assert!(!root.join("busy").exists(), "{tag}: the session goes");
            std::fs::remove_dir_all(&root).ok();
        }
    }

    /// D grants the files cs did not create (`cs -rm --delete-files`): the
    /// confirm then removes the session with them. Pressed twice it is off
    /// again, and y refuses.
    #[test]
    fn confirm_delete_d_then_y_removes_a_session_with_files_cs_did_not_create() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-files-{}", std::process::id()));
        std::fs::create_dir_all(root.join("rel/.cs/local")).unwrap();
        std::fs::create_dir_all(root.join("rel/journal.sparsebundle")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "rel");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(
            open_confirm(&mut app).offers,
            session::RemoveGrants { past_live_lock: false, unowned_files: true }
        );
        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        assert!(!open_confirm(&mut app).grants.unowned_files, "a second D takes the grant back");
        app.handle_key(KeyEvent::from(KeyCode::Char('D')));
        run_out_countdown(&mut app);
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));

        assert!(!root.join("rel").exists(), "status: {:?}", app.status_message.as_ref().map(|m| &m.text));
        std::fs::remove_dir_all(&root).ok();
    }

    /// An escalation the confirm does not offer is not a grant: its key
    /// cancels like any other.
    #[test]
    fn confirm_delete_f_cancels_when_the_session_is_not_live() {
        let mut app = App::new(sample_sessions());
        select_named(&mut app, "alpha");

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        app.handle_key(KeyEvent::from(KeyCode::Char('F')));

        assert_eq!(app.mode, Mode::Normal);
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(open_confirm(&mut app).grants, session::RemoveGrants::default());
    }

    /// A batch mixes states: the dormant rows go, the locked one stays and is
    /// counted against the run rather than silently skipped.
    #[test]
    fn batch_delete_skips_a_locked_session() {
        let mut app = App::new(sample_sessions());
        let pid = hold_gamma_lock(&mut app);

        app.execute_batch_delete(&["gamma".to_string()], session::RemoveGrants::default());

        let status = app
            .status_message
            .as_ref()
            .expect("a batch that skipped something should say so");
        assert!(
            status.text.contains(&pid),
            "status should name the locking pid, got: {}",
            status.text
        );
    }

    /// The row was scanned dormant, then the session opened before Enter on
    /// Delete: the lock on disk, not the cached row, decides, as `cs -rm`'s
    /// session_is_live re-reads it.
    #[test]
    fn delete_refuses_a_session_that_took_the_lock_after_the_scan() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-del-late-lock-{}", std::process::id()));
        std::fs::create_dir_all(root.join("busy/.cs/local")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "busy");
        let pid = std::process::id();
        std::fs::write(root.join("busy/.cs/session.lock"), format!("{pid}\n")).unwrap();

        app.execute_delete("busy", session::RemoveGrants::default());

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert!(
            status.contains(&format!("busy is live (pid {pid})")),
            "status should name the locking pid, got: {status}"
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "the live session survives");
        std::fs::remove_dir_all(&root).ok();
    }

    /// The row was scanned locked, then its process exited before `d`: the
    /// pid is checked when the delete is asked for, as `cs -rm`'s
    /// session_is_live checks it, so the dead lock does not refuse until the
    /// next scan.
    #[test]
    fn delete_opens_on_a_row_whose_locking_process_has_exited() {
        let mut app = App::new(sample_sessions());
        select_named(&mut app, "gamma");
        let gamma = app.sessions.iter_mut().find(|s| s.name == "gamma").unwrap();
        // Below i32::MAX, so a real pid value, and no process holds it.
        gamma.liveness = Liveness::Locked(99_999_999);

        app.handle_key(KeyEvent::from(KeyCode::Char('d')));

        assert!(matches!(app.mode, Mode::ConfirmDelete(_)), "status: {:?}", app.status_message.as_ref().map(|m| &m.text));
        assert!(app.delete_countdown_remaining() > 0);
    }

    /// A sessions root and a home dir under the temp dir, both scoped to this
    /// thread, with `names` as dormant sessions and `aged` holding age state
    /// at `<home>/.cs-secrets/sessions/<name>/age-trusted`.
    fn age_fixture(tag: &str, names: &[&str], aged: &[&str]) -> (std::path::PathBuf, std::path::PathBuf) {
        let base = std::env::temp_dir().join(format!("cs-test-age-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let root = base.join("sessions");
        let home = base.join("home");
        for name in names {
            std::fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        for name in aged {
            let dir = home.join(".cs-secrets/sessions").join(name);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("age-trusted"), "age1pin\n").unwrap();
        }
        (root, home)
    }

    /// Deleting a base session drops the age state cs-secrets keeps for it
    /// outside the session dir, and the status names the path.
    #[test]
    fn delete_of_a_base_session_drops_its_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("single", &["agebase"], &["agebase"]);
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agebase");

        app.execute_delete("agebase", session::RemoveGrants::default());

        let age_dir = home.join(".cs-secrets/sessions/agebase");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert!(!age_dir.exists(), "age state survived; status: {status}");
        assert_eq!(status, format!("Deleted: agebase · removed age state {}", age_dir.display()));
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A batch drops the age state of every base session it deletes, and its
    /// one status line names each path removed, sorted.
    #[test]
    fn batch_delete_drops_each_base_sessions_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("batch", &["agea", "ageb", "agec"], &["agea", "ageb"]);
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agea");
        let names: Vec<String> = ["agea", "ageb", "agec"].map(String::from).to_vec();

        app.execute_batch_delete(&names, session::RemoveGrants::default());

        let sessions = home.join(".cs-secrets/sessions");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert!(!sessions.join("agea").exists(), "agea's age state survived; status: {status}");
        assert!(!sessions.join("ageb").exists(), "ageb's age state survived; status: {status}");
        assert_eq!(
            status,
            format!(
                "Deleted 3 sessions · removed age state {}, {}",
                sessions.join("agea").display(),
                sessions.join("ageb").display()
            )
        );
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A batch of a worktree row and an adopted link keeps every age state.
    #[test]
    fn batch_delete_of_worktree_and_adopted_rows_keeps_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("batch-keep", &["agebk", "agebk@t"], &["agebk", "agebk@t", "agebl"]);
        let project = root.parent().unwrap().join("project");
        std::fs::create_dir_all(project.join(".cs/local")).unwrap();
        std::os::unix::fs::symlink(&project, root.join("agebl")).unwrap();
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agebk@t");
        let names: Vec<String> = ["agebk@t", "agebl"].map(String::from).to_vec();

        app.execute_batch_delete(&names, session::RemoveGrants::default());

        let sessions = home.join(".cs-secrets/sessions");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(status, "Deleted 2 sessions");
        for name in ["agebk", "agebk@t", "agebl"] {
            assert!(sessions.join(name).join("age-trusted").is_file(), "{name}'s age state survives");
        }
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A base@task row uses its base's secrets: deleting it leaves the base's
    /// age state, and a feature name never reaches an age state path.
    #[test]
    fn delete_of_a_worktree_row_keeps_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("worktree", &["agewt", "agewt@t"], &["agewt", "agewt@t"]);
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agewt@t");

        app.execute_delete("agewt@t", session::RemoveGrants::default());

        let sessions = home.join(".cs-secrets/sessions");
        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(status, "Deleted: agewt@t");
        assert!(!root.join("agewt@t").exists(), "the worktree row is deleted");
        assert!(sessions.join("agewt/age-trusted").is_file(), "the base's age state survives");
        assert!(sessions.join("agewt@t/age-trusted").is_file(), "a feature name reaches no age state");
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// An adopted session loses only its link; the age state stays.
    #[test]
    fn delete_of_an_adopted_link_keeps_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("adopted", &[], &["ageln"]);
        let project = root.parent().unwrap().join("project");
        std::fs::create_dir_all(project.join(".cs/local")).unwrap();
        std::fs::create_dir_all(&root).unwrap();
        std::os::unix::fs::symlink(&project, root.join("ageln")).unwrap();
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "ageln");

        app.execute_delete("ageln", session::RemoveGrants::default());

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(status, "Deleted: ageln");
        assert!(root.join("ageln").symlink_metadata().is_err(), "the link is removed");
        assert!(project.join(".cs").is_dir(), "the project survives");
        assert!(home.join(".cs-secrets/sessions/ageln/age-trusted").is_file(), "the age state survives");
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// Only one plain path component names an age state dir, and the path is
    /// exact: no name reaches `~/.cs-secrets/sessions/` itself or above it.
    #[test]
    fn age_state_dir_takes_only_a_plain_base_name() {
        let home = std::env::temp_dir().join(format!("cs-test-age-names-{}", std::process::id()));
        let _home = test_home::scoped(home.clone());
        for name in ["", ".", "..", ".hidden", "a/", "a/b", "../x", "/abs", "a@t"] {
            assert_eq!(age_state_dir(name), None, "name {name:?} must not resolve");
        }
        assert_eq!(age_state_dir("*"), Some(home.join(".cs-secrets/sessions/*")));
        assert_eq!(age_state_dir("base"), Some(home.join(".cs-secrets/sessions/base")));
    }

    /// A linked `~/.cs-secrets` deletes nothing through the link: the session
    /// goes, the age state behind the link stays, and the status names it as
    /// left behind, as an error.
    #[test]
    fn delete_leaves_age_state_behind_a_linked_secrets_dir() {
        use crate::session::test_root;
        let (root, home) = age_fixture("linked-top", &["agelk"], &[]);
        let elsewhere = root.parent().unwrap().join("elsewhere");
        let real_state = elsewhere.join("sessions/agelk");
        std::fs::create_dir_all(&real_state).unwrap();
        std::fs::write(real_state.join("age-trusted"), "age1pin\n").unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join(".cs-secrets")).unwrap();
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agelk");

        app.execute_delete("agelk", session::RemoveGrants::default());

        let msg = app.status_message.as_ref().unwrap();
        assert!(!root.join("agelk").exists(), "the session is removed; status: {}", msg.text);
        assert!(real_state.join("age-trusted").is_file(), "the state behind the link survives");
        assert_eq!(
            msg.text,
            format!(
                "Deleted: agelk, but left age state behind a linked ~/.cs-secrets: {}",
                home.join(".cs-secrets/sessions/agelk").display()
            )
        );
        assert_eq!(msg.level, StatusLevel::Error);
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A batch under a linked `~/.cs-secrets/sessions` keeps going: every
    /// session is removed, nothing behind the link is, and only a name with
    /// state there is named as left behind.
    #[test]
    fn batch_delete_leaves_age_state_behind_a_linked_sessions_dir() {
        use crate::session::test_root;
        let (root, home) = age_fixture("linked-sessions", &["agelk", "agelknext"], &[]);
        let elsewhere = root.parent().unwrap().join("elsewhere");
        std::fs::create_dir_all(elsewhere.join("agelk")).unwrap();
        std::fs::write(elsewhere.join("agelk/age-trusted"), "age1pin\n").unwrap();
        std::fs::create_dir_all(home.join(".cs-secrets")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join(".cs-secrets/sessions")).unwrap();
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agelk");
        let names: Vec<String> = ["agelk", "agelknext"].map(String::from).to_vec();

        app.execute_batch_delete(&names, session::RemoveGrants::default());

        let msg = app.status_message.as_ref().unwrap();
        assert!(!root.join("agelk").exists(), "agelk is removed; status: {}", msg.text);
        assert!(!root.join("agelknext").exists(), "agelknext is removed; status: {}", msg.text);
        assert!(elsewhere.join("agelk/age-trusted").is_file(), "the state behind the link survives");
        assert_eq!(
            msg.text,
            format!(
                "Deleted 2 sessions — agelk deleted, but left age state behind a linked ~/.cs-secrets: {}",
                home.join(".cs-secrets/sessions/agelk").display()
            )
        );
        assert_eq!(msg.level, StatusLevel::Error);
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A linked `~/.cs-secrets/sessions` whose target cannot be searched is a
    /// failure, never "no state": the delete goes ahead and the status is an
    /// error naming the path.
    #[test]
    fn delete_reports_an_unsearchable_linked_sessions_dir() {
        use crate::session::test_root;
        use std::os::unix::fs::PermissionsExt;
        let (root, home) = age_fixture("linked-hidden", &["agelkhid"], &[]);
        let elsewhere = root.parent().unwrap().join("elsewhere");
        std::fs::create_dir_all(elsewhere.join("agelkhid")).unwrap();
        std::fs::write(elsewhere.join("agelkhid/age-trusted"), "age1pin\n").unwrap();
        std::fs::create_dir_all(home.join(".cs-secrets")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join(".cs-secrets/sessions")).unwrap();
        std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o000)).unwrap();
        let _root = test_root::scoped(root.clone());
        let _home = test_home::scoped(home.clone());
        let mut app = app_on(&root, "agelkhid");

        app.execute_delete("agelkhid", session::RemoveGrants::default());

        std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o700)).unwrap();
        let msg = app.status_message.as_ref().unwrap();
        assert!(!root.join("agelkhid").exists(), "the session is removed; status: {}", msg.text);
        assert!(elsewhere.join("agelkhid/age-trusted").is_file(), "the state behind the link survives");
        let age_dir = home.join(".cs-secrets/sessions/agelkhid");
        assert!(
            msg.text.starts_with(&format!("Deleted: agelkhid, but could not read age state {}: ", age_dir.display())),
            "status: {}",
            msg.text
        );
        assert_eq!(msg.level, StatusLevel::Error);
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// With no test home scoped, a test resolves no age state at all, so the
    /// delete tests that predate the age state (and any written later without
    /// a scope) cannot reach the real `~/.cs-secrets` of whoever runs them.
    /// A sentinel under a scoped home survives an unscoped delete of the same
    /// name, proving the unscoped delete went nowhere.
    #[test]
    fn delete_without_a_test_home_touches_no_age_state() {
        use crate::session::test_root;
        let (root, home) = age_fixture("unscoped", &["agesent"], &["agesent"]);
        let _root = test_root::scoped(root.clone());
        assert_eq!(secrets_home(), None);
        assert_eq!(age_state_dir("agesent"), None);
        let mut app = app_on(&root, "agesent");

        app.execute_delete("agesent", session::RemoveGrants::default());

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert_eq!(status, "Deleted: agesent");
        assert!(home.join(".cs-secrets/sessions/agesent/age-trusted").is_file(), "the sentinel survives");
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    // A batch keeps the reason a delete failed: a mounted vault says to
    // unmount it, and "1 failed" alone does not.
    #[test]
    fn batch_delete_names_a_mounted_vault() {
        use crate::session::test_root;
        let root = std::env::temp_dir().join(format!("cs-test-batch-vault-{}", std::process::id()));
        let vault = root.join("vt/.cs/vault-mnt/memory");
        std::fs::create_dir_all(&vault).unwrap();
        std::os::unix::fs::symlink(&vault, root.join("vt/.cs/memory")).unwrap();
        let _guard = test_root::scoped(root.clone());
        let mut app = app_on(&root, "vt");

        app.execute_batch_delete(&["vt".to_string()], session::RemoveGrants::default());

        let status = app.status_message.as_ref().map(|m| m.text.clone()).unwrap_or_default();
        assert!(
            status.contains("vt has encrypted storage mounted inside it") && status.contains("unmount it"),
            "status should carry the refusal, got: {status}"
        );
        assert!(vault.is_dir(), "the vault survives");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn confirm_delete_remaining_seconds() {
        let mut app = App::new(sample_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        // Just started: should show 2
        assert_eq!(app.delete_countdown_remaining(), 2);
        // Backdate by 1 second
        open_confirm(&mut app).countdown_start =
            std::time::Instant::now() - std::time::Duration::from_secs(1);
        assert_eq!(app.delete_countdown_remaining(), 1);
        // Backdate by 2+ seconds
        open_confirm(&mut app).countdown_start =
            std::time::Instant::now() - std::time::Duration::from_secs(3);
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
    fn session_name_refusal_matches_cs_rules() {
        // Accepted by bash cs validate_session_name.
        assert_eq!(session_name_refusal("debug-api"), None);
        assert_eq!(session_name_refusal("v2026.7.4"), None);
        assert_eq!(session_name_refusal("my_session"), None);
        // Rejected — these would produce a dir the cs CLI can't open, or traverse.
        // Each refusal is cs's own text, word for word.
        let dots = Some("Session name cannot be '.' or '..'");
        let chars = Some("Session name must contain only alphanumeric characters, hyphens, underscores, and dots");
        assert_eq!(session_name_refusal(""), Some("Session name cannot be empty"));
        assert_eq!(session_name_refusal("."), dots);
        assert_eq!(session_name_refusal(".."), dots);
        assert_eq!(session_name_refusal(".spawn"), Some("Session name cannot start with a dot"));
        assert_eq!(session_name_refusal("-rm"), Some("Session name cannot start with a hyphen"));
        assert_eq!(session_name_refusal("has space"), chars);
        assert_eq!(session_name_refusal("café"), chars); // non-ASCII letter
        assert_eq!(session_name_refusal("base@task"), chars); // worktree separator
        assert_eq!(session_name_refusal("a/b"), chars);
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

    /// The secrets popup listing only `key`, its `value` revealed `age_secs` ago.
    fn revealed_popup(key: &str, value: &str, age_secs: u64) -> Mode {
        Mode::Secrets {
            list: SecretsList { names: vec![key.into()], selected: 0 },
            revealed: Some(Reveal {
                key: key.into(),
                value: value.into(),
                at: std::time::Instant::now() - std::time::Duration::from_secs(age_secs),
            }),
        }
    }

    #[test]
    fn peek_remaining_returns_countdown() {
        let mut app = App::new(sample_sessions());
        // No reveal
        assert_eq!(app.peek_remaining(), 0);
        // Fresh reveal
        app.mode = revealed_popup("KEY", "val", 0);
        assert_eq!(app.peek_remaining(), 5);
        // After 3 seconds
        app.mode = revealed_popup("KEY", "val", 3);
        assert_eq!(app.peek_remaining(), 2);
    }

    #[test]
    fn expire_peek_clears_after_timeout() {
        let mut app = App::new(sample_sessions());
        app.mode = revealed_popup("KEY", "val", 6);
        assert!(app.expire_peek());
        assert!(app.revealed().is_none());
    }

    #[test]
    fn expire_peek_keeps_fresh_reveal() {
        let mut app = App::new(sample_sessions());
        app.mode = revealed_popup("KEY", "val", 0);
        assert!(!app.expire_peek());
        assert!(app.revealed().is_some());
    }

    #[test]
    fn secrets_esc_clears_revealed_secret() {
        let mut app = App::new(sample_sessions());
        app.mode = revealed_popup("API_KEY", "sk-abc", 0);
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.revealed().is_none());
    }

    /// A delete the helper never performed must leave the list alone: dropping
    /// the row claims a deletion that did not happen while the key is still in
    /// the store. An unspawnable helper stands in for every refusal — a denied
    /// keychain prompt exits non-zero the same way — and fails identically on
    /// every platform.
    #[test]
    fn secrets_delete_keeps_the_key_when_the_helper_fails() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("CS_BIN", "/nonexistent/cs");
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&["API_KEY", "DB_PASSWORD"], 0);
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        std::env::remove_var("CS_BIN");
        assert_eq!(
            app.mode,
            Mode::Normal,
            "the failed spawn must have been reached and reported"
        );
    }

    /// The refusal that motivates this: the helper runs and exits non-zero, as a
    /// denied keychain prompt does. Unix-only because it needs a program that
    /// fails for any argv.
    #[cfg(unix)]
    #[test]
    fn secrets_delete_keeps_the_key_when_the_helper_exits_nonzero() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let failing = ["/usr/bin/false", "/bin/false"]
            .into_iter()
            .find(|p| std::path::Path::new(p).exists())
            .expect("a POSIX host has false(1)");
        std::env::set_var("CS_BIN", failing);
        let mut app = App::new(sample_sessions());
        app.mode = secrets_mode(&["API_KEY", "DB_PASSWORD"], 0);
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        std::env::remove_var("CS_BIN");
        let Mode::CommandOutput { text, then: ReturnTo::Secrets(list) } = &app.mode else {
            panic!("the helper must have run and its output shown, returning to the popup: {:?}", app.mode);
        };
        assert_eq!(text, "", "the helper must have run and its (empty) output shown");
        assert_eq!(
            list.names,
            vec!["API_KEY", "DB_PASSWORD"],
            "a refused delete must not remove the key from the list"
        );
    }

    /// A revealed value belongs to the popup that revealed it. Two exits from
    /// the popup are not Esc or q: a delete whose helper cannot be spawned,
    /// and dismissing the output of a delete that emptied the list. After
    /// either, opening the popup again inside the five-second reveal must not
    /// draw the value. The stand-in `cs` keeps no state, so it lists the key
    /// again on the second open.
    #[cfg(unix)]
    #[test]
    fn a_revealed_secret_is_not_drawn_when_the_popup_opens_again() {
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = std::env::temp_dir().join(format!("cs-tui-reveal-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let stub = tmp.join("cs-stub");
        std::fs::write(
            &stub,
            "#!/bin/sh\ncase \"$3\" in\n    list) printf 'Secrets for session: beta\\n  - API_KEY\\n' ;;\n    get) printf 'sk-peeked-42\\n' ;;\n    delete) printf 'Removed API_KEY\\n' ;;\nesac\n",
        )
        .unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        let rows = |app: &mut App| -> String {
            let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
            terminal.draw(|frame| crate::ui::render(app, frame)).unwrap();
            let buf = terminal.backend().buffer().clone();
            (0..buf.area.height)
                .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect::<String>() + "\n")
                .collect()
        };
        for exit in ["unspawnable delete", "last key deleted"] {
            std::env::set_var("CS_BIN", &stub);
            let mut app = App::new(sample_sessions());
            app.mode = Mode::SessionMenu;
            app.handle_key(KeyEvent::from(KeyCode::Char('s')));
            app.handle_key(KeyEvent::from(KeyCode::Char('v')));
            assert!(rows(&mut app).contains("sk-peeked-42"), "{exit}: the reveal is drawn while the popup is open");

            if exit == "unspawnable delete" {
                std::env::set_var("CS_BIN", "/nonexistent/cs");
                app.handle_key(KeyEvent::from(KeyCode::Char('d')));
                std::env::set_var("CS_BIN", &stub);
            } else {
                app.handle_key(KeyEvent::from(KeyCode::Char('d')));
                app.handle_key(KeyEvent::from(KeyCode::Char(' ')));
            }
            assert_eq!(app.mode, Mode::Normal, "{exit}: the popup closed");

            app.mode = Mode::SessionMenu;
            app.handle_key(KeyEvent::from(KeyCode::Char('s')));
            let screen = rows(&mut app);
            assert!(screen.contains("API_KEY"), "{exit}: the popup opened again:\n{screen}");
            assert!(!screen.contains("sk-peeked-42"), "{exit}: the value from the closed popup is drawn:\n{screen}");
            assert_eq!(app.peek_remaining(), 0, "{exit}: no reveal is counting down");
        }
        std::env::remove_var("CS_BIN");
        std::fs::remove_dir_all(&tmp).ok();
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
        assert_eq!(open_confirm(&mut app).targets, DeleteTargets::Marked(vec!["alpha".into()]));
        assert!(app.delete_countdown_remaining() > 0);
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
        app.mode = delete_confirm_on(DeleteTargets::Marked(vec!["alpha".into()]));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        assert_eq!(open_confirm(&mut app).targets, DeleteTargets::Marked(vec!["alpha".into()])); // still confirming
    }

    #[test]
    fn batch_delete_n_cancels() {
        let mut app = App::new(sample_sessions());
        app.marked_sessions.insert("alpha".into());
        app.mode = delete_confirm_on(DeleteTargets::Marked(vec!["alpha".into()]));
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
        let queued = session::read_queue(name);
        assert!(queued.iter().any(|t| t.contains("do X")));
        assert_eq!(app.queue_input.text(), "", "Enter must clear the Notes input");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_enter_writes_only_the_queued_task() {
        let tmp = std::env::temp_dir().join(format!("cs-tui-notes-only-task-{}", std::process::id()));
        let _root = session::test_root::scoped(tmp.clone());
        let name = "alpha"; // matches sample_sessions()[0].name
        let local = tmp.join(name).join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        // Another file of the session's, beside the queue: adding a task
        // leaves it as it is.
        std::fs::write(local.join("queue.declined"), "1234567890\n").unwrap();
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        for c in "do Y".chars() {
            app.handle_key(KeyEvent::from(KeyCode::Char(c)));
        }
        app.handle_key(KeyEvent::from(KeyCode::Enter));
        assert!(session::read_queue(name).iter().any(|t| t.contains("do Y")), "the task is queued");
        assert_eq!(
            std::fs::read_to_string(local.join("queue.declined")).ok().as_deref(),
            Some("1234567890\n"),
            "adding a task writes nothing beside the queue"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    // --- Notes panel: delete + edit ---

    /// Seed a session's queue with the given tasks and return (tmp root, dir).
    fn seed_queue(
        slug: &str,
        name: &str,
        tasks: &[&str],
    ) -> (std::path::PathBuf, std::path::PathBuf, session::test_root::Guard) {
        let tmp = std::env::temp_dir().join(format!("cs-tui-{}-{}", slug, std::process::id()));
        let root = session::test_root::scoped(tmp.clone());
        let local = tmp.join(name).join(".cs/local");
        let qdir = local.join("queue");
        std::fs::create_dir_all(&qdir).unwrap();
        for (i, t) in tasks.iter().enumerate() {
            std::fs::write(qdir.join(format!("{:010}-seed", i + 1)), format!("{t}\n")).unwrap();
        }
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
        let (tmp, _local, _root) = seed_queue("notes-del", "alpha", &["one", "two", "three"]);
        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        app.handle_key(KeyEvent::from(KeyCode::Down)); // into list, highlight #1
        app.handle_key(KeyEvent::from(KeyCode::Down)); // highlight #2 ("two")
        app.handle_key(KeyEvent::from(KeyCode::Char('d')));
        let lines = session::read_queue("alpha");
        assert_eq!(lines, vec!["one", "three"], "deletes exactly task #2, order preserved");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_list_e_loads_task_and_enter_replaces_in_place() {
        let (tmp, _local, _root) = seed_queue("notes-edit", "alpha", &["one", "two", "three"]);
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
        let lines = session::read_queue("alpha");
        assert_eq!(lines, vec!["one", "two X", "three"], "replaces in place, position preserved");
        assert_eq!(app.notes_focus, NotesFocus::List, "back to list after save");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn notes_list_e_then_esc_cancels_edit_unchanged() {
        let (tmp, _local, _root) = seed_queue("notes-edit-cancel", "alpha", &["one", "two", "three"]);
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
        let lines = session::read_queue("alpha");
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
        let (tmp, _local, _root) = seed_queue("notes-edit-mouse", "alpha", &["one", "two", "three"]);
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
        let lines = session::read_queue("alpha");
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
            liveness: Liveness::Dormant,
            agent_status: None,
            secrets_count: 0,
            queue_depth: 0,
            unread_mail: 0,
            git_repo: None,
            tags: Vec::new(),
            archived: false,
            vault: None,
            objective: None,
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
    fn append_notes_task_reports_a_legacy_queue_rather_than_dropping_the_task() {
        // Pre-directory layout: `queue` is one FILE holding a task per line, so
        // create_dir_all over it fails. cs converts on open; the TUI cannot, and
        // the read side already shows this session as empty, so a silent drop
        // here is invisible from both ends.
        let tmp = std::env::temp_dir().join(format!("cs-tui-legacy-q-{}", std::process::id()));
        let _root = session::test_root::scoped(tmp.clone());
        let local = tmp.join("alpha").join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        std::fs::write(local.join("queue"), "already queued\n").unwrap();
        assert!(
            local.join("queue").is_file(),
            "fixture must be the legacy single-file queue, or the bug is unreachable"
        );

        let mut app = App::new(sample_sessions());
        app.table_state.select(Some(0));
        app.queue_input.set("new task");
        app.append_notes_task("alpha", "new task");

        let msg = app
            .status_message
            .as_ref()
            .expect("a queue add that wrote nothing must say so");
        assert_eq!(msg.level, StatusLevel::Error);
        assert!(
            msg.text.contains("cs"),
            "the message must point at the fix (open the session with cs once), got: {}",
            msg.text
        );
        assert_eq!(
            app.queue_input.text(),
            "new task",
            "a failed add keeps the text so it is not lost"
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

    // ---------------------------------------------------------------
    // Archiving. The `.cs/archived` marker is written by `cs -archive`,
    // never here: its format, its date and actor stamp, and its refusal to
    // archive a live session all belong to the shell verb, and a second
    // writer would have to agree with it forever. These tests stand a
    // recording stub in for cs and read back the argv it was handed.
    // ---------------------------------------------------------------

    /// A stub cs that logs its argv and performs the marker write the real
    /// verb would, so the rescan afterwards has something true to find.
    #[cfg(unix)]
    fn archive_stub(dir: &std::path::Path) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let stub = dir.join("cs-stub");
        let script = format!(
            "#!/bin/sh\n\
             printf '%s\\n' \"$@\" >> {log}\n\
             case \"$1\" in\n\
             -archive) mkdir -p \"{root}/$2/.cs\" && echo archived > \"{root}/$2/.cs/archived\" ;;\n\
             -unarchive) rm -f \"{root}/$2/.cs/archived\" ;;\n\
             esac\n",
            log = dir.join("argv").display(),
            root = dir.display()
        );
        std::fs::write(&stub, script).unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        stub
    }

    /// A sessions root holding one session directory, named per test so
    /// parallel threads never share one.
    #[cfg(unix)]
    fn archive_root(tag: &str) -> std::path::PathBuf {
        let tmp = std::env::temp_dir().join(format!("cs-tui-{}-{}", tag, std::process::id()));
        std::fs::remove_dir_all(&tmp).ok();
        std::fs::create_dir_all(tmp.join("alpha/.cs")).unwrap();
        tmp
    }

    #[cfg(unix)]
    #[test]
    fn archive_key_archives_the_selected_session() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("archive");
        let stub = archive_stub(&tmp);
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        let argv = std::fs::read_to_string(tmp.join("argv")).unwrap_or_default();
        assert_eq!(
            argv, "-archive\nalpha\n",
            "the picker must ask cs to archive the selected session, not write the marker itself"
        );
        assert!(
            app.sessions.iter().any(|s| s.name == "alpha" && s.archived),
            "the rescan after the verb must pick up the marker it wrote"
        );
        assert!(
            app.filtered.is_empty(),
            "a freshly archived row is hidden until A shows it, and the selection must survive that"
        );
        assert_eq!(app.table_state.selected(), None, "nothing left to select");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[cfg(unix)]
    #[test]
    fn archive_key_unarchives_a_row_that_is_already_archived() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("unarchive");
        std::fs::write(tmp.join("alpha/.cs/archived"), "archived: 2026-08-23 by test\n").unwrap();
        let stub = archive_stub(&tmp);
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        // Archived rows are hidden by default, so A is how one is reachable.
        app.handle_key(KeyEvent::from(KeyCode::Char('A')));
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        let argv = std::fs::read_to_string(tmp.join("argv")).unwrap_or_default();
        assert_eq!(
            argv, "-unarchive\nalpha\n",
            "the key is a toggle: an archived row must take the opposite verb"
        );
        assert!(
            app.sessions.iter().any(|s| s.name == "alpha" && !s.archived),
            "the marker is gone, so the rescan must show the row unarchived"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// The session menu is a second, independent route to the same action: its
    /// own key arm, its own dispatch index, and its own MENU_ITEMS entry. All
    /// three are deletable while the Normal-mode tests stay green, so the
    /// menu route needs a test that actually drives it.
    #[cfg(unix)]
    #[test]
    fn session_menu_archive_entry_reaches_the_same_verb() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("archive-menu");
        let stub = archive_stub(&tmp);
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        let argv = std::fs::read_to_string(tmp.join("argv")).unwrap_or_default();
        assert_eq!(
            argv, "-archive\nalpha\n",
            "the menu entry must run the same verb the bare key does"
        );
        assert!(
            MENU_ITEMS
                .iter()
                .any(|(action, _, key)| *action == MenuAction::Archive && *key == "a"),
            "the menu must carry an Archive entry for the key to select"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// Rotation rewrites the narrative and commits inside a checkout a live
    /// conversation is appending to. Delete refuses a locked row for the same
    /// reason; rotate was the only mutating action that did not.
    #[cfg(unix)]
    #[test]
    fn r_refuses_a_locked_session() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-locked");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        for s in app.sessions.iter_mut() {
            s.liveness = session::Liveness::Locked(std::process::id());
        }
        app.apply_filter_and_sort();
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        std::env::remove_var("CS_BIN");

        assert_ne!(app.mode, Mode::ConfirmRotate, "a locked row must not be offered the confirm");
        assert!(!rotate_was_invoked(&tmp), "cs must not have rotated");
        assert!(
            app.status_message.as_ref().is_some_and(|s| s.level == StatusLevel::Error),
            "the refusal must say why"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// Rotation rewrites a narrative and makes a commit, and R sits one shift
    /// away from r (rename) — so it asks first. The archive chunk is verbatim,
    /// so the answer is recoverable and this needs no delete-style countdown.
    #[cfg(unix)]
    #[test]
    fn r_asks_before_it_rotates_anything() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-confirm");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        std::env::remove_var("CS_BIN");

        assert_eq!(app.mode, Mode::ConfirmRotate, "R must ask, not rotate");
        assert!(
            !rotate_was_invoked(&tmp),
            "cs must not have rotated before the answer"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    // A session that opens while the rotate confirm is up is refused too, as
    // rename and delete refuse it: the picker holds its rescans while a modal
    // is open, so the row still reads dormant and only the lock file says
    // otherwise.
    #[cfg(unix)]
    #[test]
    fn rotate_refuses_a_session_that_went_live_after_the_scan() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-live-later");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        assert_eq!(app.mode, Mode::ConfirmRotate, "a dormant row is offered the confirm");
        let pid = std::process::id();
        std::fs::write(tmp.join("alpha/.cs/session.lock"), format!("{pid}\n")).unwrap();
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        assert_eq!(
            app.status_message.as_ref().map(|m| (m.text.clone(), m.level)),
            Some((format!("alpha is live (pid {pid}) — close it first"), StatusLevel::Error))
        );
        assert_eq!(app.mode, Mode::Normal);
        assert!(!rotate_was_invoked(&tmp), "cs must not have rotated");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[cfg(unix)]
    #[test]
    fn declining_the_rotate_confirm_runs_nothing() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-declined");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('n')));
        std::env::remove_var("CS_BIN");

        assert_eq!(app.mode, Mode::Normal, "declining returns to the list");
        assert!(!rotate_was_invoked(&tmp), "declining must rotate nothing");
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// True when the stub recorded a `-narrative rotate` call. `CS_BIN` is
    /// process-global while the temp root is per-test, so a concurrent test
    /// that spawns cs during this test's window lands in the same argv log —
    /// asserting the file is absent makes a passing test depend on what else
    /// happens to be running. The invocation is what these tests mean.
    #[cfg(unix)]
    fn rotate_was_invoked(dir: &std::path::Path) -> bool {
        std::fs::read_to_string(dir.join("argv"))
            .unwrap_or_default()
            .contains("-narrative")
    }

    /// A cs stub for the session-scoped form `cs <name> -narrative rotate`,
    /// whose verb is $2 — unlike the global `-archive <name>` form, where it
    /// is $1. `body` is the shell run for that arm.
    #[cfg(unix)]
    fn rotate_stub(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let stub = dir.join("cs-rotate-stub");
        let script = format!(
            "#!/bin/sh\n\
             printf '%s\\n' \"$@\" >> {log}\n\
             case \"$2\" in\n\
             -narrative) {body} ;;\n\
             esac\n",
            log = dir.join("argv").display(),
            body = body
        );
        std::fs::write(&stub, script).unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        stub
    }

    /// Rotation is reached by session name, so the argv is the session-scoped
    /// shape `cs <name> -narrative rotate` — not the global `cs -narrative`
    /// form, which would rotate whichever session the picker's own shell is
    /// standing in.
    #[cfg(unix)]
    #[test]
    fn session_menu_rotate_entry_runs_the_narrative_verb() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-menu");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        let argv = std::fs::read_to_string(tmp.join("argv")).unwrap_or_default();
        assert_eq!(
            argv, "alpha\n-narrative\nrotate\n",
            "the menu entry must name the session it rotates"
        );
        assert!(
            MENU_ITEMS.iter().any(
                |(action, label, key)| *action == MenuAction::RotateNarrative
                    && *label == "Rotate narrative"
                    && *key == "R"
            ),
            "the menu must carry a Rotate narrative entry for the key to select"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// What cs printed IS the answer here: a narrative under budget rotates
    /// nothing and says so, and that sentence is the only feedback the picker
    /// can give. Dropping it would leave the entry looking like a no-op.
    #[cfg(unix)]
    #[test]
    fn rotate_shows_what_cs_printed_and_dismisses_back_to_the_list() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-output");
        let stub = rotate_stub(&tmp, "echo 'nothing to rotate: 3 KB (budget 128 KB)'");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        match &app.mode {
            Mode::CommandOutput { text, .. } => {
                assert!(text.contains("nothing to rotate"), "output: {}", text)
            }
            other => panic!("expected the output popup, got {:?}", other),
        }
        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal, "dismissing returns to the list");
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// cs refusing is not cs failing to start, and rotate refuses on stderr —
    /// an unwritable archive dir, a changed narrative, a chunk that already
    /// exists with different bytes. Swallowing that stream would report those
    /// as silence.
    #[cfg(unix)]
    #[test]
    fn rotate_passes_a_refusal_through_to_the_output_popup() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-refused");
        let stub = rotate_stub(&tmp, "echo 'Error: Cannot write to archive' >&2; exit 1");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.mode = Mode::SessionMenu;
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        match &app.mode {
            Mode::CommandOutput { text, .. } => {
                assert!(text.contains("Cannot write to archive"), "output: {}", text)
            }
            other => panic!("expected the refusal in the output popup, got {:?}", other),
        }
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// Every menu entry's shortcut also works straight from the list — that
    /// invariant is what makes the key column in the menu truthful.
    #[cfg(unix)]
    #[test]
    fn capital_r_rotates_from_the_list_too() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-normal");
        let stub = rotate_stub(&tmp, "echo rotated");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        let argv = std::fs::read_to_string(tmp.join("argv")).unwrap_or_default();
        assert_eq!(argv, "alpha\n-narrative\nrotate\n", "R from the list rotates too");
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// The preview pane lists narrative headings, so a rotation that just moved
    /// the oldest of them into .cs/narrative-archive/ makes the cached preview a
    /// lie — and the cache never expires on its own, so it would keep showing
    /// archived headings for the life of the picker.
    #[cfg(unix)]
    #[test]
    fn rotate_drops_the_stale_preview_so_it_is_read_again() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-preview");
        let stub = rotate_stub(&tmp, "echo 'rotated 1 sections'");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.preview_cache.insert(
            "alpha".into(),
            session::SessionPreview {
                objective: None,
                last_discovery: Some("archived heading".into()),
                discoveries: vec!["archived heading".into()],
                memory_entries: Vec::new(),
                contributors: Vec::new(),
            },
        );
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        assert!(
            !app.preview_cache.contains_key("alpha"),
            "the rotated session's preview must be dropped, not left showing archived headings"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// A preview read already in flight when R is pressed carries pre-rotation
    /// bytes, so letting it land would restore exactly the stale headings the
    /// invalidation just dropped.
    #[cfg(unix)]
    #[test]
    fn a_preview_in_flight_when_rotate_runs_never_reaches_the_cache() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("rotate-inflight");
        let stub = rotate_stub(&tmp, "echo 'rotated 1 sections'");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.request_preview();
        let stale = *app.preview_pending.get("alpha").expect("the read must be in flight");
        app.handle_key(KeyEvent::from(KeyCode::Char('R')));
        app.handle_key(KeyEvent::from(KeyCode::Char('y')));
        std::env::remove_var("CS_BIN");

        // The render that follows any keypress calls request_preview(), which
        // re-arms pending for this very session — so name identity alone cannot
        // tell the stale in-flight read from the fresh one it queues.
        app.request_preview();
        assert_ne!(app.preview_pending.get("alpha"), Some(&stale), "rotation must re-arm");

        // Deliver the stale read by hand, on a channel the test owns. The real
        // worker serves both requests in order, and on a loaded machine it
        // finishes the fresh one too before this thread drains; that fresh
        // read landing is correct, and it would overwrite a stale one that
        // landed first — the very bug this test exists to catch.
        let (deliver, results) = std::sync::mpsc::channel();
        app.preview_results = results;
        deliver
            .send((
                stale,
                "alpha".to_string(),
                session::SessionPreview {
                    objective: None,
                    last_discovery: Some("archived heading".into()),
                    discoveries: vec!["archived heading".into()],
                    memory_entries: Vec::new(),
                    contributors: Vec::new(),
                },
            ))
            .unwrap();
        assert_eq!(app.drain_previews(), 1, "the stale read must be delivered, then dropped");
        assert!(
            !app.preview_cache.contains_key("alpha"),
            "an in-flight read must not restore the pre-rotation preview"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// The row the cursor is on and the action Enter runs must be the same
    /// entry. They were tied by array position once, so reordering MENU_ITEMS
    /// shifted every dispatch index below the moved entry with no compile
    /// error and every key-driven test still green.
    #[test]
    fn enter_runs_the_action_belonging_to_the_highlighted_row() {
        // Enter on the Archive and Secrets rows forks cs. Unguarded, that fork
        // reads whatever CS_BIN a concurrent stub test has set and lands
        // "-archive alpha" in that test's argv log and an archived marker in
        // its root; with nothing set it forks the real cs against the
        // developer's sessions. Neither arm's outcome is asserted here.
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("CS_BIN", "/nonexistent/cs");
        for (i, (action, label, _)) in MENU_ITEMS.iter().enumerate() {
            let mut app = App::new(sample_sessions());
            app.mode = Mode::SessionMenu;
            app.menu_selected = i;
            let rows = app.menu_rows();
            assert_eq!(
                rows[i].1,
                if *action == MenuAction::Archive && app.selected_session().unwrap().archived {
                    "Unarchive"
                } else {
                    *label
                },
                "row {} must render the entry the cursor is on",
                i
            );
            // Drive the real dispatch: asserting MENU_ITEMS[selected] == action
            // is MENU_ITEMS[i] == MENU_ITEMS[i], true however Enter is wired.
            // Rename is the cheapest observable — it leaves a distinctive mode
            // and prefills the input with the selected session's name.
            app.menu_selected = i;
            app.handle_key(KeyEvent::from(KeyCode::Enter));
            if *action == MenuAction::Rename {
                assert_eq!(
                    app.mode,
                    Mode::Rename,
                    "Enter at row {} ({}) must reach the rename dialog",
                    i,
                    label
                );
            } else {
                assert_ne!(
                    app.mode,
                    Mode::Rename,
                    "Enter at row {} ({}) must not reach Rename's dialog",
                    i,
                    label
                );
            }
        }
        std::env::remove_var("CS_BIN");
    }

    /// Each entry's key selects its own action — the property the key column
    /// in the popup asserts to the reader.
    #[test]
    fn every_shortcut_key_resolves_to_its_own_entry() {
        for (action, label, key) in MENU_ITEMS {
            if *key == "Enter" {
                // Open's key is not a char: from the list Enter opens the menu.
                assert_eq!(*action, MenuAction::Open, "only Open may lack a char key");
                continue;
            }
            let c = key.chars().next().expect("a key is never empty");
            assert_eq!(
                menu_action_for_key(c),
                Some(*action),
                "{} ({}) must resolve to its own action",
                label,
                key
            );
        }
    }

    /// The menu is one row per entry, so navigation has to reach the last one.
    #[test]
    fn menu_navigation_reaches_every_entry() {
        let mut app = App::new(sample_sessions());
        app.mode = Mode::SessionMenu;
        app.menu_selected = 0;
        for _ in 0..MENU_ITEMS.len() {
            app.handle_key(KeyEvent::from(KeyCode::Char('j')));
        }
        assert_eq!(
            app.menu_selected,
            MENU_ITEMS.len() - 1,
            "j must reach the last entry and stop there"
        );
    }

    /// cs refusing is not cs failing to start: a live session exits non-zero
    /// with its reason on stderr, and that reason is the whole point of
    /// shelling out rather than writing the marker here. The spawn-failure
    /// test below cannot reach this arm.
    #[cfg(unix)]
    #[test]
    fn archive_passes_cs_refusal_through_to_the_status_line() {
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("archive-refused");
        let stub = tmp.join("cs-refuses");
        std::fs::write(
            &stub,
            "#!/bin/sh\necho \"Session 'alpha' is live (pid 4242); use --force to archive anyway\" >&2\nexit 1\n",
        )
        .unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        let status = app.status_message.as_ref().expect("the refusal must be reported");
        assert_eq!(status.level, StatusLevel::Error, "a refusal is not a success");
        assert!(
            status.text.contains("is live") && status.text.contains("--force"),
            "cs's own words must survive to the status line, got: {}",
            status.text
        );
        assert!(
            app.sessions.iter().any(|s| s.name == "alpha" && !s.archived),
            "a refused archive must leave the row as it was"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// A refusal with nothing on stderr still has to say something: the status
    /// line is the only place the user learns the archive did not happen.
    #[cfg(unix)]
    #[test]
    fn archive_refusal_with_silent_stderr_still_reports() {
        use std::os::unix::fs::PermissionsExt;
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("archive-silent");
        let stub = tmp.join("cs-silent");
        std::fs::write(&stub, "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", &stub);

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        let status = app.status_message.as_ref().expect("a silent refusal is still a refusal");
        assert_eq!(status.level, StatusLevel::Error);
        assert!(
            status.text.contains("-archive"),
            "the fallback must name the verb that refused, got: {}",
            status.text
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// An archive that never happened must not be reported as one — the row
    /// keeps its state and the failure reaches the status line. An unspawnable
    /// helper stands in for every refusal, cs's own live-session refusal
    /// included, and fails identically on every platform.
    #[cfg(unix)]
    #[test]
    fn archive_failure_leaves_the_row_unchanged() {
        let _env = CS_BIN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = archive_root("archive-fail");
        let _root = session::test_root::scoped(tmp.clone());
        std::env::set_var("CS_BIN", "/nonexistent/cs");

        let mut app = App::new(session::scan_sessions());
        app.handle_key(KeyEvent::from(KeyCode::Char('a')));
        std::env::remove_var("CS_BIN");

        assert!(
            app.sessions.iter().any(|s| s.name == "alpha" && !s.archived),
            "a refused archive must leave the row as it was"
        );
        let status = app.status_message.as_ref().expect("the refusal must be reported");
        assert_eq!(status.level, StatusLevel::Error, "a refusal is not a success");
        std::fs::remove_dir_all(&tmp).ok();
    }
}
