// ABOUTME: Renders the session table, header, footer, and modal dialogs using Ratatui widgets
// ABOUTME: Handles layout splitting, column sizing, sort indicators, and search input display

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Borders, Cell, Clear, HighlightSpacing, Paragraph, Row, Table, Wrap,
};
use ratatui::Frame;
use unicode_width::UnicodeWidthStr;

use ratatui::layout::Alignment;

use crate::app::{App, FlashKind, Focus, Mode, NotesFocus, SortColumn, SortDirection, StatusLevel};
use crate::theme::{self, Palette};

const PREVIEW_MIN_WIDTH: u16 = 120;

/// Minimum width for the stacked layout: below this the three full-width panes
/// and the table's columns are too cramped, so a narrow window falls back to the
/// table alone.
const STACK_MIN_WIDTH: u16 = 40;

/// Minimum height for the stacked layout. The three panes take 50/30/20 of the
/// area, and the To-Do pane needs 5 rows (two borders, the input, its rule, and
/// one task). 20% of 25 is the first height that clears that floor.
const STACK_MIN_HEIGHT: u16 = 25;

/// How the main content area is divided among the session table and the
/// preview/notes detail panes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PaneLayout {
    /// Just the session table, full width — the detail panes are hidden.
    TableOnly,
    /// Table on the left, preview stacked over notes on the right (landscape).
    SideBySide,
    /// Table, preview, then notes stacked top-to-bottom (portrait).
    Stacked,
}

/// Pick the pane layout for `area`. When the detail panes are on, a wide window
/// that reads as wider than tall sets them beside the table; otherwise they
/// stack above one another as long as the area clears both floors; anything
/// smaller shows the table alone.
///
/// Terminal cells are roughly twice as tall as they are wide, so "visually
/// taller than wide" is `2 * height > width`, not a raw row-vs-column compare.
/// A portrait window never sits the panes beside the table even when it is wide
/// enough to: vertical space is the more useful axis for them.
fn choose_layout(area: Rect, show_preview: bool) -> PaneLayout {
    if !show_preview {
        return PaneLayout::TableOnly;
    }
    let portrait = 2 * area.height as u32 > area.width as u32;
    if !portrait && area.width >= PREVIEW_MIN_WIDTH {
        PaneLayout::SideBySide
    } else if area.width >= STACK_MIN_WIDTH && area.height >= STACK_MIN_HEIGHT {
        PaneLayout::Stacked
    } else {
        PaneLayout::TableOnly
    }
}

/// Blank cells between table columns. Structure is carried by alignment, zebra
/// striping, and the header rule — not by vertical divider glyphs.
pub const COL_SPACING: u16 = 2;
/// Width reserved at the left of each row for the selection accent bar ("▌ ").
pub const SELECT_WIDTH: u16 = 2;
/// The selection accent-bar glyph. Set as the row highlight symbol and located
/// again post-render to shimmer it — kept here so the two sites can't drift.
const SELECT_BAR: &str = "\u{258c}";

/// Truncate a string to fit within max_width, respecting UTF-8 char boundaries.
fn truncate_str(s: &str, max_width: usize) -> String {
    if s.len() <= max_width {
        return s.to_string();
    }
    // Find the last char boundary at or before max_width - 3 (room for "...")
    let end = s
        .char_indices()
        .map(|(i, _)| i)
        .take_while(|&i| i <= max_width.saturating_sub(3))
        .last()
        .unwrap_or(0);
    format!("{}...", &s[..end])
}

/// Clip `s` to at most `max_cols` display columns, appending `…` when clipped.
/// Display-width aware — never splits a wide char.
fn truncate_cols(s: &str, max_cols: usize) -> String {
    use unicode_width::UnicodeWidthChar;
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

pub fn render(app: &mut App, frame: &mut Frame) {
    let p = app.theme;

    // Paint the canvas so light themes composite over paper instead of the
    // terminal's own background. Dark uses Color::Reset — a deliberate no-op that
    // keeps the terminal's native background, transparency, and images intact.
    frame.render_widget(
        Block::default().style(Style::default().bg(p.base_bg)),
        frame.area(),
    );

    // When in SessionMenu mode, allocate an extra line for the inline action bar
    let action_bar_height = if app.mode == Mode::SessionMenu { 1u16 } else { 0 };

    let chunks = Layout::vertical([
        Constraint::Min(5),
        Constraint::Length(action_bar_height),
        Constraint::Length(1),
    ])
    .split(frame.area());

    match choose_layout(chunks[0], app.show_preview) {
        PaneLayout::SideBySide => {
            app.request_preview();
            let cols = Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)])
                .split(chunks[0]);
            render_table(app, frame, cols[0], true);
            let right_rows =
                Layout::vertical([Constraint::Percentage(55), Constraint::Percentage(45)])
                    .split(cols[1]);
            render_preview_pane(app, frame, right_rows[0]);
            render_notes_pane(app, frame, right_rows[1]);
        }
        PaneLayout::Stacked => {
            app.request_preview();
            let rows = Layout::vertical([
                Constraint::Percentage(50),
                Constraint::Percentage(30),
                Constraint::Percentage(20),
            ])
            .split(chunks[0]);
            render_table(app, frame, rows[0], true);
            render_preview_pane(app, frame, rows[1]);
            render_notes_pane(app, frame, rows[2]);
        }
        PaneLayout::TableOnly => {
            render_table(app, frame, chunks[0], false);
        }
    }

    if app.mode == Mode::SessionMenu {
        render_action_bar(app, frame, chunks[1]);
    }

    match &app.mode {
        Mode::Search => render_search_bar(app, frame, chunks[2]),
        _ => render_footer(app, frame, chunks[2]),
    }

    // Overlay dialogs on top
    match &app.mode {
        Mode::ConfirmDelete => render_confirm_delete(app, frame),
        Mode::ConfirmBatchDelete => render_confirm_batch_delete(app, frame),
        Mode::ConfirmForceOpen => render_confirm_force_open(app, frame),
        Mode::Rename => render_rename_dialog(app, frame),
        Mode::CreateSession => render_create_dialog(app, frame),
        Mode::Secrets => render_secrets_popup(app, frame),
        Mode::CommandOutput(text) => render_command_output(text, p, frame),
        _ => {}
    }
}

fn render_table(app: &mut App, frame: &mut Frame, area: Rect, preview_open: bool) {
    let p = app.theme;
    let icons = theme::icons();

    app.table_area = area;

    let show_secrets = app.has_secrets();
    let show_todos = app.has_todos();
    // Hide Github column when preview pane is open (it's shown in the preview)
    let show_github = app.has_git_sessions() && !preview_open;

    // Track which sort columns are visible (for mouse click-to-sort)
    let mut visible_cols = vec![SortColumn::Name, SortColumn::Created, SortColumn::Modified];
    if show_secrets { visible_cols.push(SortColumn::Secrets); }
    if show_todos { visible_cols.push(SortColumn::Todo); }
    if show_github { visible_cols.push(SortColumn::Github); }
    app.visible_sort_columns = visible_cols;

    let sort_indicator = |col: SortColumn| -> &'static str {
        if app.sort_col != col {
            return "";
        }
        match app.sort_dir {
            SortDirection::Asc => " \u{25b2}",
            SortDirection::Desc => " \u{25bc}",
        }
    };

    let mut header_cells = vec![
        Cell::from(format!("Session{}", sort_indicator(SortColumn::Name))),
        Cell::from(format!("Created{}", sort_indicator(SortColumn::Created))),
        Cell::from(format!("Age{}", sort_indicator(SortColumn::Modified))),
    ];
    if show_secrets {
        header_cells.push(Cell::from(format!("Secrets{}", sort_indicator(SortColumn::Secrets))));
    }
    if show_todos {
        header_cells.push(Cell::from(format!("To-Do{}", sort_indicator(SortColumn::Todo))));
    }
    if show_github {
        header_cells.push(Cell::from(format!("Github{}", sort_indicator(SortColumn::Github))));
    }

    let header = Row::new(header_cells)
        .style(Style::default().fg(p.header_fg).add_modifier(Modifier::BOLD))
        .bottom_margin(1);

    let is_searching = app.mode == Mode::Search && !app.search_input.text().is_empty();

    // One wall-clock read per frame, shared by every row's recency math.
    let now = std::time::SystemTime::now();

    // Total drawn height of each row, parallel to `app.filtered`. Captured here —
    // the one place the `1 + extra_height` math lives — so mouse hit-testing can
    // reconstruct exact row spans without duplicating the geometry.
    let mut row_heights: Vec<u16> = Vec::with_capacity(app.filtered.len());

    let rows: Vec<Row> = app
        .filtered
        .iter()
        .enumerate()
        .map(|(row_idx, &i)| {
            let s = &app.sessions[i];
            // During search typing, dim rows that don't match
            let dimmed = is_searching && !app.fuzzy_indices.contains_key(&i);

            // Recency heat: green when live, fading to grey when dormant. Computed
            // once and reused for the dot and the Age column.
            let heat = if dimmed { p.comment } else { p.heat_color(s.modified_ts) };

            // Build gutter indicators as colored prefix spans
            let mut name_spans: Vec<Span> = Vec::new();
            name_spans.push(Span::styled("\u{25cf} ", Style::default().fg(heat)));
            if app.marked_sessions.contains(&s.name) {
                let mark_color = if dimmed { p.comment } else { p.gold };
                name_spans.push(Span::styled(
                    "* ",
                    Style::default().fg(mark_color).add_modifier(Modifier::BOLD),
                ));
            }
            if s.is_locked {
                let lock_color = if dimmed { p.comment } else { p.red };
                name_spans.push(Span::styled(
                    format!("{} ", icons.lock),
                    Style::default().fg(lock_color),
                ));
            }
            if s.secrets_count > 0 && !show_secrets {
                // Show secrets indicator in gutter only when secrets column is hidden
                let secrets_color = if dimmed { p.comment } else { p.gold };
                name_spans.push(Span::styled(
                    format!("{} ", icons.lock),
                    Style::default().fg(secrets_color),
                ));
            }

            let name_color = if dimmed {
                p.comment
            } else {
                p.gold
            };

            // Highlight matched characters from fuzzy search
            if let Some(indices) = app.fuzzy_indices.get(&i) {
                let matched_set: std::collections::HashSet<usize> =
                    indices.iter().copied().collect();
                let mut run_start = 0;
                let name = &s.name;
                for (byte_idx, ch) in name.char_indices() {
                    if matched_set.contains(&byte_idx) {
                        // Flush any unmatched run before this char
                        if run_start < byte_idx {
                            name_spans.push(Span::styled(
                                name[run_start..byte_idx].to_string(),
                                Style::default().fg(name_color),
                            ));
                        }
                        name_spans.push(Span::styled(
                            ch.to_string(),
                            Style::default()
                                .fg(name_color)
                                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
                        ));
                        run_start = byte_idx + ch.len_utf8();
                    }
                }
                // Flush remaining unmatched chars
                if run_start < name.len() {
                    name_spans.push(Span::styled(
                        name[run_start..].to_string(),
                        Style::default().fg(name_color),
                    ));
                }
            } else {
                name_spans.push(Span::styled(s.name.clone(), Style::default().fg(name_color)));
            }

            let meta_color = if dimmed {
                p.comment
            } else {
                p.recency_color(s.modified_ts)
            };

            // Build the name cell — may include section header and/or preview lines
            let section_label = app.section_labels.get(row_idx).copied().flatten();
            let is_expanded = app.expanded_session.as_deref() == Some(&s.name);

            let mut name_lines: Vec<Line> = Vec::new();

            if let Some(label) = section_label {
                name_lines.push(Line::from(Span::styled(
                    format!("── {} ──", label),
                    Style::default().fg(p.comment).add_modifier(Modifier::DIM),
                )));
            }

            name_lines.push(Line::from(name_spans));

            // Add preview lines when expanded
            let mut preview_lines: u16 = 0;
            if is_expanded {
                if let Some(preview) = app.preview_cache.get(&s.name) {
                    if let Some(ref obj) = preview.objective {
                        let truncated = truncate_str(obj, 60);
                        name_lines.push(Line::from(vec![
                            Span::styled("  goal: ", Style::default().fg(p.comment)),
                            Span::styled(truncated, Style::default().fg(p.fg)),
                        ]));
                        preview_lines += 1;
                    }
                    if let Some(ref disc) = preview.last_discovery {
                        let truncated = truncate_str(disc, 58);
                        name_lines.push(Line::from(vec![
                            Span::styled("  last: ", Style::default().fg(p.comment)),
                            Span::styled(truncated, Style::default().fg(p.yellow)),
                        ]));
                        preview_lines += 1;
                    }
                    // Show at least a "no metadata" line if everything is empty
                    if preview_lines == 0 {
                        name_lines.push(Line::from(Span::styled(
                            "  (no metadata)",
                            Style::default().fg(p.comment).add_modifier(Modifier::DIM),
                        )));
                        preview_lines += 1;
                    }
                }
            }

            let name_cell = Cell::from(ratatui::text::Text::from(name_lines));

            // Created is reference context — show the date only (the preview
            // pane carries the full timestamp). Modified is the hot column —
            // show a compact age that pairs with the recency colour.
            let created_date = s
                .created
                .as_deref()
                .map(|c| c.get(..10).unwrap_or(c).to_string())
                .unwrap_or_else(|| "-".into());
            let modified_rel = match s.modified_ts {
                Some(ts) => crate::session::relative_age(ts, now),
                None => "-".into(),
            };

            // Age rides the heat ramp and goes bold while the session is recent
            // (any heat tone other than the dormant grey), so live work pops out
            // of a list that is mostly dormant.
            let mut age_style = Style::default().fg(heat);
            if heat != p.comment {
                age_style = age_style.add_modifier(Modifier::BOLD);
            }

            let mut cells = vec![
                name_cell,
                Cell::from(created_date).style(Style::default().fg(meta_color)),
                Cell::from(modified_rel).style(age_style),
            ];

            if show_secrets {
                let secrets = if s.secrets_count > 0 {
                    format!("{} {}", icons.lock, s.secrets_count)
                } else {
                    String::new()
                };
                let secrets_line = Line::from(secrets).alignment(Alignment::Center);
                cells.push(Cell::from(secrets_line).style(Style::default().fg(meta_color)));
            }

            if show_todos {
                let todo = if s.queue_depth > 0 {
                    format!("{} {}", '\u{25a4}', s.queue_depth)
                } else {
                    String::new()
                };
                cells.push(Cell::from(todo).style(Style::default().fg(p.yellow)));
            }

            if show_github {
                let github = s.git_repo.clone().unwrap_or_default();
                let github_color = if dimmed { p.comment } else { p.green };
                if github.is_empty() {
                    cells.push(Cell::from(String::new()));
                } else {
                    let repo = Line::from(vec![
                        Span::styled(
                            format!("{} ", icons.branch),
                            Style::default().fg(github_color).add_modifier(Modifier::DIM),
                        ),
                        Span::styled(github, Style::default().fg(github_color)),
                    ]);
                    cells.push(Cell::from(repo));
                }
            }

            let extra_height = if section_label.is_some() { 1u16 } else { 0 } + preview_lines;
            let height = 1 + extra_height;
            row_heights.push(height);
            let row = Row::new(cells).height(height);

            // Flash background takes priority, then zebra striping
            if let Some(flash) = app.active_flash(&s.name) {
                let bg = match flash {
                    FlashKind::Success => p.flash_success,
                    FlashKind::Error => p.flash_error,
                };
                row.style(Style::default().bg(bg))
            } else if row_idx % 2 == 1 {
                row.style(Style::default().bg(p.zebra))
            } else {
                row
            }
        })
        .collect();

    let mut widths: Vec<Constraint> = vec![
        Constraint::Min(20),    // Session
        Constraint::Length(10), // Created (date)
        Constraint::Length(6),  // Age (relative)
    ];
    if show_secrets { widths.push(Constraint::Length(9)); }
    if show_todos { widths.push(Constraint::Length(7)); }
    if show_github { widths.push(Constraint::Min(15)); }

    let session_count = app.filtered.len();
    let version = std::env::var("CS_VERSION").unwrap_or_default();
    let title = gradient_title(p, &version, session_count);

    // Resolve column geometry with ratatui's own solver so mouse hit-testing
    // never drifts from where the Table actually draws. (Drift between a
    // hand-rolled approximation and the real layout is what made the old
    // dividers slice through cells.) The Table reserves SELECT_WIDTH at the left
    // for the selection symbol, then lays the columns out across the remainder.
    let inner = Rect {
        x: area.x + 1,
        y: area.y + 1,
        width: area.width.saturating_sub(2),
        height: area.height.saturating_sub(2),
    };
    let cols_area = Rect {
        x: inner.x + SELECT_WIDTH,
        width: inner.width.saturating_sub(SELECT_WIDTH),
        ..inner
    };
    let col_rects = Layout::horizontal(widths.clone())
        .spacing(COL_SPACING)
        .split(cols_area);
    app.column_widths = col_rects.iter().map(|r| r.width).collect();

    // Dim the border when focus has moved to the Notes input, mirroring how
    // the Notes panel itself brightens its border when it gains focus.
    let list_border = if app.focus == Focus::Notes { p.comment } else { p.rust };

    let table = Table::new(rows, widths)
        .header(header)
        .column_spacing(COL_SPACING)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(list_border))
                .title(title),
        )
        .row_highlight_style(Style::default().bg(p.sel_bg).add_modifier(Modifier::BOLD))
        .highlight_symbol(format!("{SELECT_BAR} "))
        .highlight_spacing(HighlightSpacing::Always);

    frame.render_stateful_widget(table, area, &mut app.table_state);

    // Publish the row hit-map now that ratatui has finalized the scroll offset.
    // Data rows begin at relative y = 4 (border, title, header, header rule) and
    // stack by their true heights, so clicks below a group header or an expanded
    // row still resolve to the right session. Only on-screen rows are recorded.
    app.row_hit_spans.clear();
    let bottom = area.height.saturating_sub(1); // relative y of the bottom border
    let mut y = 4u16;
    for (idx, &h) in row_heights
        .iter()
        .enumerate()
        .skip(app.table_state.offset())
    {
        if y >= bottom {
            break;
        }
        app.row_hit_spans.push((y, h, idx));
        y = y.saturating_add(h);
    }

    // Warm rust→orange→amber gradient band behind the header labels. Painted
    // per-cell because a terminal background can only be a flat color per cell;
    // the ramp across cells is the band. The same vivid stops are used on both
    // themes (sampled from the live render); the near-white label stays bold.
    let buf = frame.buffer_mut();
    let lo = theme::rgb_of(p.header_bg_lo);
    let mid = theme::rgb_of(p.header_bg_mid);
    let hi = theme::rgb_of(p.header_bg_hi);
    let band_span = (inner.width.max(2) - 1) as f32;
    for x in inner.x..inner.x.saturating_add(inner.width) {
        let t = (x - inner.x) as f32 / band_span;
        let (r, g, b) = warm_ramp(lo, mid, hi, t);
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, inner.y)) {
            cell.set_bg(ratatui::style::Color::Rgb(r, g, b));
        }
    }

    // A single hairline rule beneath the header, drawn into the header's blank
    // bottom-margin row. Structure stays quiet — no vertical dividers; alignment
    // and zebra striping carry the columns.
    let rule_y = inner.y + 1;
    for x in inner.x..inner.x.saturating_add(inner.width) {
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, rule_y)) {
            cell.set_char('\u{2500}');
            cell.set_fg(p.sep);
        }
    }
    // Tee the rule into the side borders so it reads as frame, not a stray line.
    for (x, glyph) in [(area.x, '\u{251c}'), (area.x + area.width.saturating_sub(1), '\u{2524}')] {
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, rule_y)) {
            cell.set_char(glyph);
            cell.set_fg(p.rust);
        }
    }

    // Shimmer the selection accent bar along a rust↔gold triangle wave. We locate
    // the bar by its glyph in the selection column rather than recomputing the
    // selected row's y (rows have variable height), which keeps this robust.
    let phase = {
        const PERIOD_MS: u128 = 1400;
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        (ms % PERIOD_MS) as f32 / PERIOD_MS as f32
    };
    let shimmer = p.shimmer_color(phase);
    for y in (inner.y + 2)..inner.y.saturating_add(inner.height) {
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(inner.x, y)) {
            if cell.symbol() == SELECT_BAR {
                cell.set_fg(shimmer);
                break;
            }
        }
    }
}

/// Three-stop warm ramp (a → b → c) sampled at `t` in [0, 1]. Arcing through a
/// midpoint keeps the sweep vivid instead of fading through a muddy blend.
fn warm_ramp(a: (u8, u8, u8), b: (u8, u8, u8), c: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    if t < 0.5 {
        theme::lerp_rgb(a, b, t * 2.0)
    } else {
        theme::lerp_rgb(b, c, (t - 0.5) * 2.0)
    }
}

fn gradient_title<'a>(p: Palette, version: &str, session_count: usize) -> Line<'a> {
    // Vivid rust → orange → gold sweep across the whole title — name, version,
    // and count all ride the same ramp so the header reads as one warm band.
    let rust = theme::rgb_of(p.rust);
    let orange = theme::rgb_of(p.orange);
    let gold = theme::rgb_of(p.gold);

    let title = format!("claude-sessions v{} [{} sessions] ", version, session_count);
    let total = title.chars().count().max(2) as f32;

    let mut spans: Vec<Span<'a>> = Vec::with_capacity(title.chars().count() + 1);
    spans.push(Span::styled(" ", Style::default()));

    for (i, ch) in title.chars().enumerate() {
        let t = i as f32 / (total - 1.0);
        let (r, g, b) = warm_ramp(rust, orange, gold, t);
        spans.push(Span::styled(
            ch.to_string(),
            Style::default()
                .fg(ratatui::style::Color::Rgb(r, g, b))
                .add_modifier(Modifier::BOLD),
        ));
    }

    Line::from(spans)
}

fn render_footer(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    // Status message takes priority in Normal mode
    if app.mode == Mode::Normal {
        if let Some(msg) = &app.status_message {
            let color = match msg.level {
                StatusLevel::Success => p.green,
                StatusLevel::Error => p.red,
                StatusLevel::Info => p.yellow,
            };
            let footer = Paragraph::new(Line::from(vec![Span::styled(
                &msg.text,
                Style::default().fg(color),
            )]));
            frame.render_widget(footer, area);
            return;
        }
    }

    let keys = if app.mode == Mode::Normal && app.focus == Focus::Notes {
        if app.notes_focus == NotesFocus::Editing {
            "editing   Enter:save   Esc:cancel"
        } else if app.notes_focus == NotesFocus::List {
            "\u{2191}\u{2193}:select   d:delete   e:edit   Esc:back"
        } else {
            "type a task   \u{2193}:list   Enter:add   Esc:back"
        }
    } else {
        match app.mode {
            Mode::Normal if !app.marked_sessions.is_empty() => {
                "Space:mark  D:delete marked  Esc:clear marks  q:quit  Enter:open  /:search"
            }
            Mode::Normal => {
                "q:quit  Enter:open  n:new  d:delete  r:rename  Tab:to-do  Space:mark  /:search  1-6:sort"
            }
            Mode::SessionMenu => "j/k:navigate  Enter:select  Esc:cancel",
            Mode::ConfirmDelete | Mode::ConfirmBatchDelete => "y:confirm  n:cancel",
            Mode::ConfirmForceOpen => "y:force open  n:cancel",
            Mode::Rename | Mode::CreateSession => "Enter:confirm  Esc:cancel",
            Mode::Secrets => "j/k:navigate  v/Enter:view  d:remove  Esc:close",
            Mode::CommandOutput(_) => "Press any key to dismiss",
            Mode::Search => unreachable!(),
        }
    };
    let mut footer_spans = Vec::new();
    if !app.marked_sessions.is_empty() && matches!(app.mode, Mode::Normal) {
        footer_spans.push(Span::styled(
            format!("{} marked  ", app.marked_sessions.len()),
            Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
        ));
    }
    footer_spans.push(Span::styled(keys, Style::default().fg(p.comment)));
    let footer = Paragraph::new(Line::from(footer_spans));
    frame.render_widget(footer, area);
}

fn render_search_bar(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let line = Line::from(vec![
        Span::styled("/ ", Style::default().fg(p.gold)),
        Span::styled(app.search_input.before_cursor(), Style::default().fg(p.fg)),
        Span::styled("\u{2588}", Style::default().fg(p.fg)),
        Span::styled(app.search_input.after_cursor(), Style::default().fg(p.fg)),
    ]);
    let paragraph = Paragraph::new(line);
    frame.render_widget(paragraph, area);
}

fn render_action_bar(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let session = app.selected_session();
    let has_secrets = session.as_ref().map(|s| s.secrets_count > 0).unwrap_or(false);

    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::styled(" ", Style::default()));

    // Each action: [key]label with availability-based coloring
    let actions: &[(&str, &str, bool)] = &[
        ("Enter", "open", true),
        ("d", "delete", true),
        ("r", "rename", true),
        ("s", "secrets", has_secrets),
    ];

    for (i, (key, label, available)) in actions.iter().enumerate() {
        let is_selected = i == app.menu_selected;

        if i > 0 {
            spans.push(Span::styled("  ", Style::default()));
        }

        let (key_color, label_color) = if !available {
            (p.comment, p.comment)
        } else if is_selected {
            (p.gold, p.fg)
        } else {
            (p.gold, p.comment)
        };

        let key_style = Style::default().fg(key_color).add_modifier(Modifier::BOLD);
        let label_style = if is_selected {
            Style::default().fg(label_color).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(label_color)
        };

        spans.push(Span::styled("[", Style::default().fg(key_color)));
        spans.push(Span::styled(*key, key_style));
        spans.push(Span::styled("]", Style::default().fg(key_color)));
        spans.push(Span::styled(*label, label_style));
    }

    spans.push(Span::styled("  Esc:close", Style::default().fg(p.comment)));

    let bar = Paragraph::new(Line::from(spans))
        .style(Style::default().bg(p.zebra));
    frame.render_widget(bar, area);
}

fn render_confirm_delete(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let session = match app.selected_session() {
        Some(s) => s,
        None => return,
    };

    let remaining = app.delete_countdown_remaining();

    let action_msg = if session.is_adopted {
        format!(
            "Remove adopted session '{}'?\n(removes symlink only, project preserved)",
            session.name
        )
    } else {
        format!("Delete session '{}'?\nThis cannot be undone.", session.name)
    };

    let hint = if remaining > 0 {
        format!("[y] Confirm ({}...)  [n/Esc] Cancel", remaining)
    } else {
        "[y] Confirm  [n/Esc] Cancel".to_string()
    };
    let hint_color = if remaining > 0 { p.comment } else { p.fg };

    let popup_area = centered_rect(50, 7, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.red))
        .title(" Confirm Delete ")
        .title_style(Style::default().fg(p.red).add_modifier(Modifier::BOLD));

    let lines = vec![
        Line::from(Span::styled(action_msg, Style::default().fg(p.fg))),
        Line::from(""),
        Line::from(Span::styled(hint, Style::default().fg(hint_color))),
    ];
    let text = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(text, popup_area);
}

fn render_confirm_batch_delete(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let count = app.marked_sessions.len();
    let remaining = app.delete_countdown_remaining();

    let mut names: Vec<&str> = app.marked_sessions.iter().map(|s| s.as_str()).collect();
    names.sort();

    let list = if names.len() <= 5 {
        names.join(", ")
    } else {
        format!("{}, ... and {} more", names[..4].join(", "), names.len() - 4)
    };

    let hint = if remaining > 0 {
        format!("[y] Confirm ({}...)  [n/Esc] Cancel", remaining)
    } else {
        "[y] Confirm  [n/Esc] Cancel".to_string()
    };
    let hint_color = if remaining > 0 { p.comment } else { p.fg };

    let height = if names.len() <= 5 { 7 } else { 7 };
    let popup_area = centered_rect(55, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.red))
        .title(format!(" Delete {} sessions ", count))
        .title_style(Style::default().fg(p.red).add_modifier(Modifier::BOLD));

    let lines = vec![
        Line::from(Span::styled(
            format!("Delete {} sessions?", count),
            Style::default().fg(p.fg),
        )),
        Line::from(Span::styled(list, Style::default().fg(p.comment))),
        Line::from(""),
        Line::from(Span::styled("This cannot be undone.", Style::default().fg(p.red))),
        Line::from(Span::styled(hint, Style::default().fg(hint_color))),
    ];
    let text = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(text, popup_area);
}

fn render_confirm_force_open(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let session = match app.selected_session() {
        Some(s) => s,
        None => return,
    };

    let pid_text = session
        .lock_pid
        .map(|pid| format!(" (PID {})", pid))
        .unwrap_or_default();

    let msg = format!(
        "Session '{}' is in use{}.\nForce open?",
        session.name, pid_text
    );

    let popup_area = centered_rect(50, 6, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.yellow))
        .title(" Locked Session ")
        .title_style(Style::default().fg(p.yellow).add_modifier(Modifier::BOLD));
    let text = Paragraph::new(msg)
        .style(Style::default().fg(p.fg))
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(text, popup_area);
}

fn render_rename_dialog(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.gold))
        .title(" Rename Session ")
        .title_style(Style::default().fg(p.gold).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(app.rename_input.before_cursor(), Style::default().fg(p.fg)),
        Span::styled("\u{2588}", Style::default().fg(p.fg)),
        Span::styled(app.rename_input.after_cursor(), Style::default().fg(p.fg)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(p.fg))
        .block(block);
    frame.render_widget(text, popup_area);
}

fn render_create_dialog(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.green))
        .title(" New Session ")
        .title_style(Style::default().fg(p.green).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(app.create_input.before_cursor(), Style::default().fg(p.fg)),
        Span::styled("\u{2588}", Style::default().fg(p.fg)),
        Span::styled(app.create_input.after_cursor(), Style::default().fg(p.fg)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(p.fg))
        .block(block);
    frame.render_widget(text, popup_area);
}

fn render_secrets_popup(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let session_name = app
        .selected_session()
        .map(|s| s.name.as_str())
        .unwrap_or("?");

    let height = (app.secrets_names.len() as u16 + 3).max(5).min(20);
    let popup_area = centered_rect(50, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.orange))
        .title(format!(" Secrets - {} ", session_name))
        .title_style(Style::default().fg(p.orange).add_modifier(Modifier::BOLD));

    if app.secrets_names.is_empty() {
        let paragraph = Paragraph::new("No secrets stored")
            .style(Style::default().fg(p.comment))
            .block(block);
        frame.render_widget(paragraph, popup_area);
        return;
    }

    let lines: Vec<Line> = app
        .secrets_names
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let is_selected = i == app.secrets_selected;
            let is_revealed = app
                .revealed_secret
                .as_ref()
                .map(|(k, _, _)| k == name)
                .unwrap_or(false);

            let mut spans = Vec::new();
            if is_selected {
                spans.push(Span::styled(
                    ">> ",
                    Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(
                    name.as_str(),
                    Style::default().fg(p.fg).add_modifier(Modifier::BOLD),
                ));
            } else {
                spans.push(Span::styled("   ", Style::default()));
                spans.push(Span::styled(name.as_str(), Style::default().fg(p.comment)));
            }

            if is_revealed {
                if let Some((_, ref value, _)) = app.revealed_secret {
                    let remaining = app.peek_remaining();
                    let display_val = truncate_str(value, 30);
                    spans.push(Span::styled("  ", Style::default()));
                    spans.push(Span::styled(
                        display_val,
                        Style::default().fg(p.yellow),
                    ));
                    spans.push(Span::styled(
                        format!(" ({}s)", remaining),
                        Style::default().fg(p.comment),
                    ));
                }
            }

            Line::from(spans)
        })
        .collect();

    let paragraph = Paragraph::new(lines).block(block);
    frame.render_widget(paragraph, popup_area);
}

fn render_command_output(text: &str, p: Palette, frame: &mut Frame) {
    let popup_area = centered_rect(80, 20, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.orange))
        .title(" Output ")
        .title_style(Style::default().fg(p.orange).add_modifier(Modifier::BOLD));
    let paragraph = Paragraph::new(text.to_string())
        .style(Style::default().fg(p.fg))
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
}

/// A body-section header for the preview pane: a muted rust accent bar, then
/// the label in bold gold. Shared by every section so the accent stays uniform.
fn section_header(label: impl Into<String>, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled("\u{258f} ", Style::default().fg(p.rust)),
        Span::styled(
            label.into(),
            Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
        ),
    ])
}

fn render_preview_pane(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let session = match app.selected_session() {
        Some(s) => s,
        None => {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(p.rust))
                .title(" Preview ")
                .title_style(Style::default().fg(p.rust));
            let p = Paragraph::new("No session selected")
                .style(Style::default().fg(p.comment))
                .block(block);
            frame.render_widget(p, area);
            return;
        }
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.rust))
        .title(format!(" {} ", session.name))
        .title_style(Style::default().fg(p.gold).add_modifier(Modifier::BOLD));

    let mut lines: Vec<Line> = Vec::new();

    // Session metadata
    if let Some(ref created) = session.created {
        lines.push(Line::from(vec![
            Span::styled("Created:  ", Style::default().fg(p.comment)),
            Span::styled(created.as_str(), Style::default().fg(p.fg)),
        ]));
    }
    if let Some(ref modified) = session.modified {
        lines.push(Line::from(vec![
            Span::styled("Modified: ", Style::default().fg(p.comment)),
            Span::styled(modified.as_str(), Style::default().fg(p.fg)),
        ]));
    }
    if let Some(ref repo) = session.git_repo {
        lines.push(Line::from(vec![
            Span::styled("Github:   ", Style::default().fg(p.comment)),
            Span::styled(repo.as_str(), Style::default().fg(p.green)),
        ]));
    }
    if session.secrets_count > 0 {
        lines.push(Line::from(vec![
            Span::styled("Secrets:  ", Style::default().fg(p.comment)),
            Span::styled(
                format!("{}", session.secrets_count),
                Style::default().fg(p.yellow),
            ),
        ]));
    }
    if session.is_locked {
        let lock = theme::icons().lock;
        let pid_text = session
            .lock_pid
            .map(|pid| format!("{} Locked (PID {})", lock, pid))
            .unwrap_or_else(|| format!("{} Locked", lock));
        lines.push(Line::from(Span::styled(
            pid_text,
            Style::default().fg(p.red),
        )));
    }

    // Thin rule separating front-matter (metadata) from body (content).
    let inner_width = (area.width as usize).saturating_sub(2);
    lines.push(Line::from(Span::styled(
        "\u{2500}".repeat(inner_width),
        Style::default().fg(p.comment),
    )));

    // Preview content from .cs/ files, once the worker has read them.
    if let Some(preview) = app.preview_cache.get(&session.name) {
        if let Some(ref obj) = preview.objective {
            lines.push(section_header("Objective", p));
            lines.push(Line::from(Span::styled(
                obj.as_str(),
                Style::default().fg(p.fg),
            )));
            lines.push(Line::from(""));
        }

        if !preview.discoveries.is_empty() {
            lines.push(section_header("Narrative", p));
            for disc in &preview.discoveries {
                let truncated = truncate_str(disc, (area.width as usize).saturating_sub(6));
                lines.push(Line::from(vec![
                    Span::styled("  - ", Style::default().fg(p.comment)),
                    Span::styled(truncated, Style::default().fg(p.yellow)),
                ]));
            }
            lines.push(Line::from(""));
        }

        if !preview.memory_entries.is_empty() {
            lines.push(section_header("Memory", p));
            for entry in &preview.memory_entries {
                let truncated = truncate_str(entry, (area.width as usize).saturating_sub(6));
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default()),
                    Span::styled(truncated, Style::default().fg(p.comment)),
                ]));
            }
            lines.push(Line::from(""));
        }

        if !preview.contributors.is_empty() {
            lines.push(section_header("Contributors", p));
            for c in &preview.contributors {
                let truncated = truncate_str(c, (area.width as usize).saturating_sub(6));
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default()),
                    Span::styled(truncated, Style::default().fg(p.comment)),
                ]));
            }
            lines.push(Line::from(""));
        }

        if preview.objective.is_none() && preview.discoveries.is_empty() && preview.memory_entries.is_empty() && preview.contributors.is_empty() {
            lines.push(Line::from(Span::styled(
                "No .cs/ metadata",
                Style::default().fg(p.comment).add_modifier(Modifier::DIM),
            )));
        }
    } else {
        // The worker holds this session and has not answered yet.
        lines.push(Line::from(Span::styled(
            "Loading\u{2026}",
            Style::default().fg(p.comment).add_modifier(Modifier::DIM),
        )));
    }

    let paragraph = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(paragraph, area);
}

fn render_notes_pane(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let focused = app.focus == Focus::Notes;
    let input_focused = focused && app.notes_focus == NotesFocus::Input;
    let list_focused = focused && app.notes_focus == NotesFocus::List;

    let border_color = if focused { p.gold } else { p.rust };
    let mut title_style = Style::default().fg(p.gold);
    if focused {
        title_style = title_style.add_modifier(Modifier::BOLD);
    }

    let title = match app.selected_session() {
        Some(s) => format!(" To-Do · {} ", s.name),
        None => " To-Do ".to_string(),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(border_color))
        .title(title)
        .title_style(title_style);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Input line on top, a full-width separator rule, then the task list.
    let rows = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .split(inner);

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

    // Separator between the input and the list, matching the panel border.
    let rule = "\u{2500}".repeat(rows[1].width as usize);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(rule, Style::default().fg(border_color)))),
        rows[1],
    );

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
}

fn centered_rect(percent_x: u16, height: u16, area: Rect) -> Rect {
    let popup_layout = Layout::vertical([
        Constraint::Fill(1),
        Constraint::Length(height),
        Constraint::Fill(1),
    ])
    .split(area);
    Layout::horizontal([
        Constraint::Percentage((100 - percent_x) / 2),
        Constraint::Percentage(percent_x),
        Constraint::Percentage((100 - percent_x) / 2),
    ])
    .split(popup_layout[1])[1]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_str_multibyte_boundary_does_not_panic() {
        // A 3-byte em-dash straddling the byte cutoff must not panic (naive
        // &s[..n] slicing would). truncate_str respects char boundaries.
        let s = format!("{}—tail", "a".repeat(56));
        let out = truncate_str(&s, 60);
        assert!(out.ends_with("..."));
        // Longer all-multibyte input, cut mid-run.
        let emo = "🚀".repeat(40);
        let _ = truncate_str(&emo, 30);
    }

    use crate::app::App;
    use crate::session::Session;
    use crate::theme::Palette;
    use crate::app::Focus;
    use crossterm::event::{KeyCode, KeyEvent};
    use ratatui::backend::TestBackend;
    use ratatui::style::Color;
    use ratatui::Terminal;

    fn one_session() -> Vec<Session> {
        vec![Session {
            name: "alpha".into(),
            is_adopted: false,
            created: Some("2026-01-01 10:00".into()),
            modified: Some("2026-02-20 14:00".into()),
            modified_ts: None,
            lock_pid: None,
            is_locked: false,
            secrets_count: 0,
            queue_depth: 0,
            git_repo: None,
        }]
    }

    /// Render to an in-memory buffer with the given palette and return whether
    /// any cell is painted with the light paper background.
    fn renders_with_paper_bg(palette: Palette) -> bool {
        let mut app = App::new(one_session());
        app.theme = palette;
        // Width < PREVIEW_MIN_WIDTH so the preview pane (which reads files) stays closed.
        let backend = TestBackend::new(100, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let paper = Color::Rgb(250, 247, 242);
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .any(|cell| cell.bg == paper)
    }

    #[test]
    fn light_theme_paints_paper_canvas() {
        assert!(renders_with_paper_bg(Palette::light()));
    }

    #[test]
    fn dark_theme_leaves_canvas_unpainted() {
        // Dark uses Color::Reset for the canvas, so no paper-colored cells appear.
        assert!(!renders_with_paper_bg(Palette::dark()));
    }

    /// Render and return each buffer row as a string.
    fn render_rows() -> Vec<String> {
        use std::time::{Duration, SystemTime};
        let mut sessions = one_session();
        sessions[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(3 * 86400));
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let backend = TestBackend::new(100, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .filter_map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()))
                    .collect::<String>()
            })
            .collect()
    }

    #[test]
    fn no_interior_vertical_dividers() {
        // The rounded panel contributes exactly two '│' per row (its left and
        // right edges). Any third means a column divider has leaked back in —
        // the regression that sliced cells like "M│dified".
        for (y, row) in render_rows().iter().enumerate() {
            let bars = row.matches('\u{2502}').count();
            assert!(bars <= 2, "row {y} has {bars} vertical bars: {row:?}");
        }
    }

    /// Render into a buffer of the given size and return it as newline-joined rows.
    fn render_at(app: &mut App, width: u16, height: u16) -> String {
        let backend = TestBackend::new(width, height);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .filter_map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()))
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Render on a wide terminal (preview + Notes pane both visible) and
    /// return the buffer as newline-joined rows.
    fn render_wide(app: &mut App) -> String {
        render_at(app, 140, 30)
    }

    #[test]
    fn portrait_terminal_stacks_list_details_and_notes() {
        // 80×50 reads as portrait, so the panes stack. At width 80 — below
        // PREVIEW_MIN_WIDTH — the side-by-side layout can't fire, so the To-Do
        // panel and the preview's "Created:" label appearing at all proves the
        // vertical split engaged. A probe name no other test seeds on disk keeps
        // the empty-queue assertion from racing the queue tests.
        let mut sessions = one_session();
        sessions[0].name = "cs-tui-stack-probe".into();
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let joined = render_at(&mut app, 80, 50);
        assert!(joined.contains("To-Do"), "notes panel title should render: {joined}");
        assert!(
            joined.contains("no queued tasks"),
            "empty queue placeholder should render: {joined}"
        );
        assert!(
            joined.contains("Created:"),
            "preview pane metadata should render: {joined}"
        );
    }

    #[test]
    fn wide_terminal_renders_notes_pane() {
        // The To-Do panel reads the selected session's queue live from
        // CS_SESSIONS_ROOT. Use a session name no other test seeds on disk so the
        // "no queued tasks" assertion can't race the ENV_LOCK'd queue tests (which
        // transiently point the root at temp dirs holding an "alpha" queue).
        let mut sessions = one_session();
        sessions[0].name = "cs-tui-render-probe".into();
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let joined = render_wide(&mut app);
        assert!(joined.contains("To-Do"), "To-Do panel title should render: {joined}");
        assert!(
            joined.contains("no queued tasks"),
            "empty queue should show placeholder: {joined}"
        );
    }

    #[test]
    fn tab_focused_notes_pane_shows_input_footer_hint() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.handle_key(KeyEvent::from(KeyCode::Tab));
        assert_eq!(app.focus, Focus::Notes);
        let joined = render_wide(&mut app);
        assert!(
            joined.contains("Enter:add"),
            "footer should show the Notes-focused hint: {joined}"
        );
    }

    #[test]
    fn header_uses_age_and_created_is_date_only() {
        let rows = render_rows();
        let joined = rows.join("\n");
        assert!(joined.contains("Age"), "header should label the column 'Age'");
        assert!(joined.contains("Created"), "header keeps 'Created'");
        assert!(
            joined.contains("2026-01-01"),
            "created date should render: {joined}"
        );
        assert!(
            !joined.contains("2026-01-01 10:00"),
            "created cell must drop the time component"
        );
        assert!(joined.contains("3d"), "modified should render as relative age");
    }

    #[test]
    fn todo_column_renders_when_a_session_has_queued_tasks() {
        use std::time::{Duration, SystemTime};
        let mut sessions = one_session();
        sessions[0].queue_depth = 3;
        sessions[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(3 * 86400));
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        // Width 100 < PREVIEW_MIN_WIDTH keeps the To-Do panel closed, so the only
        // "To-Do" text in the buffer comes from the table column under test.
        let backend = TestBackend::new(100, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let joined: String = (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .filter_map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()))
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(joined.contains("To-Do"), "To-Do column header should render: {joined}");
        assert!(
            joined.contains("\u{25a4} 3"),
            "todo cell should show the glyph and count: {joined}"
        );
    }

    #[test]
    fn todo_column_hidden_when_no_session_has_queued_tasks() {
        // render_rows() uses one_session() (queue_depth 0) at width 100 (no panel),
        // so "To-Do" must not appear anywhere.
        let joined = render_rows().join("\n");
        assert!(
            !joined.contains("To-Do"),
            "To-Do column is hidden when no session has queued tasks: {joined}"
        );
    }

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
        // Truncation puts the ellipsis on the task's own row; the old wrap never did.
        let task_row = rows
            .iter()
            .find(|r| r.contains("Refactor"))
            .expect("the long task's row should render");
        assert!(
            task_row.contains('\u{2026}'),
            "the task row must end with an ellipsis when truncated: {task_row}"
        );
        // The clipped tail must not survive anywhere on that row.
        assert!(
            !task_row.contains("window"),
            "the tail past the width must be clipped, not wrapped: {task_row}"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

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
        for c in "the quick brown fox jumps over the lazy dog and then keeps on running far past the visible right edge of this narrow input field and onward zzz".chars() {
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
        assert!(joined.contains("zzz"), "the tail nearest the cursor is shown");
        assert!(!joined.contains("the quick brown"), "the head scrolled out of the field");
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

        // The other half of the contract: the To-Do separator rule stays
        // full-bleed. It is the row directly below the input line, and its first
        // cell inside the border must be the rule glyph, not a padding space — so
        // a regression that padded every row (e.g. moving the inset into the
        // shared layout) would flip this to a space and fail here.
        let mut rule_full_bleed = false;
        for y in 0..buf.area.height {
            let line: String = (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect();
            if line.contains("Tab to add a task") {
                let ry = y + 1;
                let rule: String = (0..buf.area.width).map(|x| buf[(x, ry)].symbol()).collect();
                if let Some(bpos) = rule.find("│") {
                    let inner_x = bpos + "│".len();
                    rule_full_bleed = rule[inner_x..].starts_with('─');
                }
            }
        }
        assert!(rule_full_bleed, "the To-Do separator rule should touch the border with no padding column");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn portrait_area_chooses_stacked_layout() {
        // 80×50 reads as taller than wide once the ~2:1 cell shape is accounted
        // for (2*50 = 100 > 80), and clears the min-size floors, so the panes
        // stack vertically.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 80, 50), true),
            PaneLayout::Stacked
        );
    }

    #[test]
    fn wide_landscape_area_chooses_side_by_side() {
        // 200×50 is clearly wider than tall (2*50 = 100 < 200) and past the
        // side-by-side width floor.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 200, 50), true),
            PaneLayout::SideBySide
        );
    }

    #[test]
    fn wide_and_tall_area_still_stacks() {
        // Even a roomy window stacks when it reads as portrait: 150×90 clears the
        // side-by-side width but 2*90 = 180 > 150, so vertical space wins.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 150, 90), true),
            PaneLayout::Stacked
        );
    }

    #[test]
    fn short_narrow_area_falls_back_to_table_only() {
        // 80×24 is neither tall enough to stack nor wide enough for side-by-side.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 80, 24), true),
            PaneLayout::TableOnly
        );
    }

    #[test]
    fn landscape_area_too_narrow_for_side_by_side_stacks() {
        // 100×29 reads as landscape (2*29 = 58 < 100) so it cannot sit the panes
        // beside a table at this width, but 29 rows is ample to stack all three.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 100, 29), true),
            PaneLayout::Stacked
        );
    }

    #[test]
    fn landscape_area_wide_enough_to_stack_but_too_short_is_table_only() {
        // 100×20 clears the stack width floor but not the height floor: three
        // panes in 20 rows leaves the To-Do pane below its border+input+rule+row
        // minimum, so the table takes the whole area instead.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 100, 20), true),
            PaneLayout::TableOnly
        );
    }

    #[test]
    fn narrow_tall_area_is_rejected_by_the_width_floor() {
        // 30×50 reads as portrait (2*50 > 30) but is too narrow for three usable
        // panes, so the width floor sends it to the table alone rather than a
        // cramped stack.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 30, 50), true),
            PaneLayout::TableOnly
        );
    }

    #[test]
    fn preview_disabled_forces_table_only_regardless_of_shape() {
        // A portrait window that would otherwise stack shows the table alone when
        // the detail panes are toggled off.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 80, 50), false),
            PaneLayout::TableOnly
        );
    }
}
