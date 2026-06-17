// ABOUTME: Renders the session table, header, footer, and modal dialogs using Ratatui widgets
// ABOUTME: Handles layout splitting, column sizing, sort indicators, and search input display

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Clear, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use ratatui::layout::Alignment;

use crate::app::{App, FlashKind, Mode, SortColumn, SortDirection, StatusLevel};
use crate::theme::{self, Palette};

const PREVIEW_MIN_WIDTH: u16 = 120;

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

    let show_preview = app.show_preview && chunks[0].width >= PREVIEW_MIN_WIDTH;

    if show_preview {
        app.ensure_preview_loaded();
        let cols = Layout::horizontal([Constraint::Percentage(60), Constraint::Percentage(40)])
            .split(chunks[0]);
        render_table(app, frame, cols[0], true);
        render_preview_pane(app, frame, cols[1]);
    } else {
        render_table(app, frame, chunks[0], false);
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
        Mode::MoveToRemote => render_move_to_dialog(app, frame),
        Mode::Secrets => render_secrets_popup(app, frame),
        Mode::SyncOutput(text) => render_sync_output(text, p, frame),
        _ => {}
    }
}

fn render_table(app: &mut App, frame: &mut Frame, area: Rect, preview_open: bool) {
    let p = app.theme;
    let icons = theme::icons();

    app.table_area = area;

    let show_secrets = app.has_secrets();
    // Hide Remote and Github columns when preview pane is open (they're shown in the preview)
    let show_remote = app.has_remote_sessions() && !preview_open;
    let show_github = app.has_git_sessions() && !preview_open;

    // Track which sort columns are visible (for mouse click-to-sort)
    let mut visible_cols = vec![SortColumn::Name, SortColumn::Created, SortColumn::Modified];
    if show_secrets { visible_cols.push(SortColumn::Secrets); }
    if show_remote { visible_cols.push(SortColumn::Remote); }
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
        Cell::from(format!("Modified{}", sort_indicator(SortColumn::Modified))),
    ];
    if show_secrets {
        header_cells.push(Cell::from(format!("Secrets{}", sort_indicator(SortColumn::Secrets))));
    }
    if show_remote {
        header_cells.push(Cell::from(format!("Remote{}", sort_indicator(SortColumn::Remote))));
    }
    if show_github {
        header_cells.push(Cell::from(format!("Github{}", sort_indicator(SortColumn::Github))));
    }

    let header = Row::new(header_cells)
        .style(Style::default().fg(p.rust).add_modifier(Modifier::BOLD))
        .bottom_margin(1);

    let is_searching = app.mode == Mode::Search && !app.search_input.text().is_empty();

    let rows: Vec<Row> = app
        .filtered
        .iter()
        .enumerate()
        .map(|(row_idx, &i)| {
            let s = &app.sessions[i];
            // During search typing, dim rows that don't match
            let dimmed = is_searching && !app.fuzzy_indices.contains_key(&i);

            // Build gutter indicators as colored prefix spans
            let mut name_spans: Vec<Span> = Vec::new();
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
            if s.location.is_some() {
                let remote_icon_color = if dimmed { p.comment } else { p.orange };
                name_spans.push(Span::styled(
                    format!("{} ", icons.remote),
                    Style::default().fg(remote_icon_color),
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
            } else if s.location.is_some() {
                p.remote
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
                        let truncated = if obj.len() > 60 {
                            format!("{}...", &obj[..57])
                        } else {
                            obj.clone()
                        };
                        name_lines.push(Line::from(vec![
                            Span::styled("  goal: ", Style::default().fg(p.comment)),
                            Span::styled(truncated, Style::default().fg(p.fg)),
                        ]));
                        preview_lines += 1;
                    }
                    if let Some(ref disc) = preview.last_discovery {
                        let truncated = if disc.len() > 58 {
                            format!("{}...", &disc[..55])
                        } else {
                            disc.clone()
                        };
                        name_lines.push(Line::from(vec![
                            Span::styled("  last: ", Style::default().fg(p.comment)),
                            Span::styled(truncated, Style::default().fg(p.yellow)),
                        ]));
                        preview_lines += 1;
                    }
                    if preview.artifact_count > 0 {
                        name_lines.push(Line::from(Span::styled(
                            format!("  {} artifacts", preview.artifact_count),
                            Style::default().fg(p.comment),
                        )));
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

            let mut cells = vec![
                name_cell,
                Cell::from(s.created.clone().unwrap_or_else(|| "-".into()))
                    .style(Style::default().fg(meta_color)),
                Cell::from(s.modified.clone().unwrap_or_else(|| "-".into()))
                    .style(Style::default().fg(meta_color)),
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

            if show_remote {
                let remote = s
                    .location
                    .as_ref()
                    .map(|l| format!("{} {}", icons.remote, l))
                    .unwrap_or_default();
                let remote_color = if dimmed { p.comment } else { p.orange };
                cells.push(Cell::from(remote).style(Style::default().fg(remote_color)));
            }

            if show_github {
                let github = s.git_repo.clone().unwrap_or_default();
                let github_color = if dimmed { p.comment } else { p.green };
                cells.push(Cell::from(github).style(Style::default().fg(github_color)));
            }

            let extra_height = if section_label.is_some() { 1u16 } else { 0 } + preview_lines;
            let row = if extra_height > 0 {
                Row::new(cells).height(1 + extra_height)
            } else {
                Row::new(cells)
            };

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
        Constraint::Min(20),
        Constraint::Length(16),
        Constraint::Length(16),
    ];
    if show_secrets { widths.push(Constraint::Length(9)); }
    if show_remote { widths.push(Constraint::Length(20)); }
    if show_github { widths.push(Constraint::Min(15)); }

    // Store resolved column widths for mouse click-to-sort
    let inner_width = area.width.saturating_sub(2); // borders
    let col_spacing = 7u16;
    let spacing_total = col_spacing * (widths.len() as u16 - 1);
    let resolved = resolve_widths(&widths, inner_width.saturating_sub(3).saturating_sub(spacing_total));
    app.column_widths = resolved;

    let session_count = app.filtered.len();
    let version = std::env::var("CS_VERSION").unwrap_or_default();

    let title = gradient_title(p, &version, session_count);

    let table = Table::new(rows, widths)
        .header(header)
        .column_spacing(col_spacing)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(p.rust))
                .title(title),
        )
        .row_highlight_style(
            Style::default()
                .fg(p.fg)
                .add_modifier(Modifier::REVERSED),
        )
        .highlight_symbol(">> ");

    frame.render_stateful_widget(table, area, &mut app.table_state);

    // Draw discrete column separators in the middle of each column gap
    let y_start = area.y + 1;
    let y_end = area.y + area.height.saturating_sub(1);
    let mut x = area.x + 1 + 3; // border + highlight symbol width
    let buf = frame.buffer_mut();
    for (i, &w) in app.column_widths.iter().enumerate() {
        x += w;
        if i < app.column_widths.len() - 1 {
            let sep_x = x + col_spacing / 2; // center of gap
            if sep_x < area.x + area.width.saturating_sub(1) {
                for y in y_start..y_end {
                    if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(sep_x, y)) {
                        cell.set_char('\u{2502}');
                        cell.set_fg(p.sep);
                    }
                }
            }
            x += col_spacing;
        }
    }
}

fn resolve_widths(constraints: &[Constraint], available: u16) -> Vec<u16> {
    // Approximate constraint resolution for mouse hit-testing
    let mut fixed_total: u16 = 0;
    let mut min_total: u16 = 0;
    let mut flex_count: u16 = 0;

    for c in constraints {
        match c {
            Constraint::Length(l) => fixed_total += l,
            Constraint::Min(m) => {
                min_total += m;
                flex_count += 1;
            }
            _ => flex_count += 1,
        }
    }

    let remaining = available.saturating_sub(fixed_total).saturating_sub(min_total);
    let flex_extra = if flex_count > 0 {
        remaining / flex_count
    } else {
        0
    };

    constraints
        .iter()
        .map(|c| match c {
            Constraint::Length(l) => *l,
            Constraint::Min(m) => m + flex_extra,
            _ => flex_extra,
        })
        .collect()
}

fn gradient_title<'a>(p: Palette, version: &str, session_count: usize) -> Line<'a> {
    // Rust → Gold gradient matching install.sh banner, themed for the background
    let start = theme::rgb_of(p.rust);
    let end = theme::rgb_of(p.gold);
    let text = "claude-sessions";
    let len = text.len() as f32 - 1.0;

    let mut spans: Vec<Span<'a>> = Vec::with_capacity(text.len() + 4);
    spans.push(Span::styled(" ", Style::default()));

    for (i, ch) in text.chars().enumerate() {
        let t = if len > 0.0 { i as f32 / len } else { 0.0 };
        let r = start.0 as f32 + t * (end.0 as f32 - start.0 as f32);
        let g = start.1 as f32 + t * (end.1 as f32 - start.1 as f32);
        let b = start.2 as f32 + t * (end.2 as f32 - start.2 as f32);
        spans.push(Span::styled(
            ch.to_string(),
            Style::default()
                .fg(ratatui::style::Color::Rgb(r as u8, g as u8, b as u8))
                .add_modifier(Modifier::BOLD),
        ));
    }

    spans.push(Span::styled(
        format!(" v{} ", version),
        Style::default().fg(p.comment),
    ));
    spans.push(Span::styled(
        format!("[{} sessions] ", session_count),
        Style::default().fg(p.fg).add_modifier(Modifier::BOLD),
    ));

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

    // Syncing mode renders its own spinner footer
    if app.mode == Mode::Syncing {
        let spinner = app.spinner_frame();
        let subcmd = app
            .sync_job
            .as_ref()
            .map(|j| j.subcommand.as_str())
            .unwrap_or("sync");
        let session = app
            .sync_job
            .as_ref()
            .map(|j| j.session_name.as_str())
            .unwrap_or("?");
        let footer = Paragraph::new(Line::from(vec![
            Span::styled(format!("{} ", spinner), Style::default().fg(p.gold)),
            Span::styled(
                format!("{}ing {}...", subcmd, session),
                Style::default().fg(p.fg),
            ),
            Span::styled("  Esc:cancel", Style::default().fg(p.comment)),
        ]));
        frame.render_widget(footer, area);
        return;
    }

    let keys = match app.mode {
        Mode::Normal if !app.marked_sessions.is_empty() => {
            "Space:mark  D:delete marked  Esc:clear marks  q:quit  Enter:open  /:search"
        }
        Mode::Normal => {
            "q:quit  Enter:open  n:new  d:delete  r:rename  Tab:preview  Space:mark  /:search  1-6:sort"
        }
        Mode::SessionMenu => "j/k:navigate  Enter:select  Esc:cancel",
        Mode::ConfirmDelete | Mode::ConfirmBatchDelete => "y:confirm  n:cancel",
        Mode::ConfirmForceOpen => "y:force open  n:cancel",
        Mode::Rename | Mode::MoveToRemote | Mode::CreateSession => "Enter:confirm  Esc:cancel",
        Mode::Secrets => "j/k:navigate  v/Enter:view  d:remove  Esc:close",
        Mode::SyncOutput(_) => "Press any key to dismiss",
        Mode::Syncing => unreachable!(), // handled above
        Mode::Search => unreachable!(),
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
    let is_remote = session.as_ref().map(|s| s.location.is_some()).unwrap_or(false);
    let has_git = session.as_ref().map(|s| s.has_git).unwrap_or(false);
    let has_secrets = session.as_ref().map(|s| s.secrets_count > 0).unwrap_or(false);

    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::styled(" ", Style::default()));

    // Each action: [key]label with availability-based coloring
    let actions: &[(&str, &str, bool)] = &[
        ("Enter", "open", true),
        ("d", "delete", true),
        ("r", "rename", true),
        ("m", "move", !is_remote),
        ("s", "secrets", has_secrets),
        ("P", "push", has_git),
        ("L", "pull", has_git),
        ("S", "status", has_git),
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

fn render_move_to_dialog(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let session = match app.selected_session() {
        Some(s) => s,
        None => return,
    };

    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.orange))
        .title(" Move to Remote ")
        .title_style(Style::default().fg(p.orange).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(
            format!("Move '{}' to: ", session.name),
            Style::default().fg(p.comment),
        ),
        Span::styled(app.move_to_input.before_cursor(), Style::default().fg(p.fg)),
        Span::styled("\u{2588}", Style::default().fg(p.fg)),
        Span::styled(app.move_to_input.after_cursor(), Style::default().fg(p.fg)),
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
                    let display_val = if value.len() > 30 {
                        format!("{}...", &value[..27])
                    } else {
                        value.clone()
                    };
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

fn render_sync_output(text: &str, p: Palette, frame: &mut Frame) {
    let popup_area = centered_rect(80, 20, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.orange))
        .title(" Sync Output ")
        .title_style(Style::default().fg(p.orange).add_modifier(Modifier::BOLD));
    let paragraph = Paragraph::new(text.to_string())
        .style(Style::default().fg(p.fg))
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
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
    if let Some(ref loc) = session.location {
        lines.push(Line::from(vec![
            Span::styled("Remote:   ", Style::default().fg(p.comment)),
            Span::styled(loc.as_str(), Style::default().fg(p.orange)),
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
        let pid_text = session
            .lock_pid
            .map(|pid| format!("Locked (PID {})", pid))
            .unwrap_or_else(|| "Locked".to_string());
        lines.push(Line::from(Span::styled(
            pid_text,
            Style::default().fg(p.red),
        )));
    }

    // Preview content from .cs/ files
    if let Some(preview) = app.preview_cache.get(&session.name) {
        lines.push(Line::from(""));

        if let Some(ref obj) = preview.objective {
            lines.push(Line::from(Span::styled(
                "Objective",
                Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
            )));
            lines.push(Line::from(Span::styled(
                obj.as_str(),
                Style::default().fg(p.fg),
            )));
            lines.push(Line::from(""));
        }

        if !preview.discoveries.is_empty() {
            lines.push(Line::from(Span::styled(
                "Narrative",
                Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
            )));
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
            lines.push(Line::from(Span::styled(
                "Memory",
                Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
            )));
            for entry in &preview.memory_entries {
                let truncated = truncate_str(entry, (area.width as usize).saturating_sub(6));
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default()),
                    Span::styled(truncated, Style::default().fg(p.comment)),
                ]));
            }
            lines.push(Line::from(""));
        }

        if preview.artifact_count > 0 {
            lines.push(Line::from(Span::styled(
                format!("Artifacts ({})", preview.artifact_count),
                Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
            )));
            let max_names = (area.height as usize).saturating_sub(lines.len() + 3);
            for name in preview.artifact_names.iter().take(max_names) {
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default()),
                    Span::styled(name.as_str(), Style::default().fg(p.comment)),
                ]));
            }
            if preview.artifact_names.len() > max_names {
                lines.push(Line::from(Span::styled(
                    format!("  ... and {} more", preview.artifact_names.len() - max_names),
                    Style::default().fg(p.comment).add_modifier(Modifier::DIM),
                )));
            }
        }

        if preview.objective.is_none() && preview.discoveries.is_empty() && preview.memory_entries.is_empty() && preview.artifact_count == 0 {
            lines.push(Line::from(Span::styled(
                "No .cs/ metadata",
                Style::default().fg(p.comment).add_modifier(Modifier::DIM),
            )));
        }
    }

    let paragraph = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(paragraph, area);
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
    use crate::app::App;
    use crate::session::Session;
    use crate::theme::Palette;
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
            location: None,
            lock_pid: None,
            is_locked: false,
            secrets_count: 0,
            has_git: false,
            git_repo: None,
            sync_auto: None,
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
}
