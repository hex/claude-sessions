// ABOUTME: Renders the session table, header, footer, and modal dialogs using Ratatui widgets
// ABOUTME: Handles layout splitting, column sizing, sort indicators, and search input display

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Clear, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use ratatui::layout::Alignment;

use crate::app::{App, FlashKind, Mode, SortColumn, SortDirection, StatusLevel, MENU_ITEMS};
use crate::theme::{self, COMMENT, FLASH_ERROR, FLASH_SUCCESS, GOLD, GREEN, ORANGE, RED, RUST, WHITE, YELLOW};

const ZEBRA_DIM: ratatui::style::Color = ratatui::style::Color::Rgb(32, 29, 28);

pub fn render(app: &mut App, frame: &mut Frame) {
    let chunks = Layout::vertical([Constraint::Min(5), Constraint::Length(1)])
        .split(frame.area());

    render_table(app, frame, chunks[0]);

    match &app.mode {
        Mode::Search => render_search_bar(app, frame, chunks[1]),
        _ => render_footer(app, frame, chunks[1]),
    }

    // Overlay dialogs on top
    match &app.mode {
        Mode::SessionMenu => render_session_menu(app, frame),
        Mode::ConfirmDelete => render_confirm_delete(app, frame),
        Mode::ConfirmForceOpen => render_confirm_force_open(app, frame),
        Mode::Rename => render_rename_dialog(app, frame),
        Mode::CreateSession => render_create_dialog(app, frame),
        Mode::MoveToRemote => render_move_to_dialog(app, frame),
        Mode::Secrets => render_secrets_popup(app, frame),
        Mode::SyncOutput(text) => render_sync_output(text, frame),
        _ => {}
    }
}

fn render_table(app: &mut App, frame: &mut Frame, area: Rect) {
    let icons = theme::icons();

    app.table_area = area;

    let show_secrets = app.has_secrets();
    let show_remote = app.has_remote_sessions();
    let show_github = app.has_git_sessions();

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
        .style(Style::default().fg(RUST).add_modifier(Modifier::BOLD))
        .bottom_margin(1);

    let rows: Vec<Row> = app
        .filtered
        .iter()
        .enumerate()
        .map(|(row_idx, &i)| {
            let s = &app.sessions[i];
            // Build gutter indicators as colored prefix spans
            let mut name_spans: Vec<Span> = Vec::new();
            if s.is_locked {
                name_spans.push(Span::styled(
                    format!("{} ", icons.lock),
                    Style::default().fg(RED),
                ));
            }
            if s.location.is_some() {
                name_spans.push(Span::styled(
                    format!("{} ", icons.remote),
                    Style::default().fg(ORANGE),
                ));
            }
            if s.secrets_count > 0 && !show_secrets {
                // Show secrets indicator in gutter only when secrets column is hidden
                name_spans.push(Span::styled(
                    format!("{} ", icons.lock),
                    Style::default().fg(GOLD),
                ));
            }

            let name_color = if s.location.is_some() {
                ratatui::style::Color::Cyan
            } else {
                GOLD
            };
            name_spans.push(Span::styled(s.name.clone(), Style::default().fg(name_color)));

            let meta_color = theme::recency_color(s.modified_ts);

            let mut cells = vec![
                Cell::from(Line::from(name_spans)),
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
                cells.push(Cell::from(remote).style(Style::default().fg(ORANGE)));
            }

            if show_github {
                let github = s.git_repo.clone().unwrap_or_default();
                cells.push(Cell::from(github).style(Style::default().fg(GREEN)));
            }

            let row = Row::new(cells);

            // Flash background takes priority, then zebra striping
            if let Some(flash) = app.active_flash(&s.name) {
                let bg = match flash {
                    FlashKind::Success => FLASH_SUCCESS,
                    FlashKind::Error => FLASH_ERROR,
                };
                row.style(Style::default().bg(bg))
            } else if row_idx % 2 == 1 {
                row.style(Style::default().bg(ZEBRA_DIM))
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

    let title = gradient_title(&version, session_count);

    let table = Table::new(rows, widths)
        .header(header)
        .column_spacing(col_spacing)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(RUST))
                .title(title),
        )
        .row_highlight_style(
            Style::default()
                .fg(WHITE)
                .add_modifier(Modifier::REVERSED),
        )
        .highlight_symbol(">> ");

    frame.render_stateful_widget(table, area, &mut app.table_state);

    // Draw discrete column separators in the middle of each column gap
    const SEP: ratatui::style::Color = ratatui::style::Color::Rgb(50, 45, 42);
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
                        cell.set_fg(SEP);
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

fn gradient_title<'a>(version: &str, session_count: usize) -> Line<'a> {
    // Rust (#e64a19) → Gold (#ffc107) gradient matching install.sh banner
    const START: (u8, u8, u8) = (230, 74, 25);
    const END: (u8, u8, u8) = (255, 193, 7);
    let text = "claude-sessions";
    let len = text.len() as f32 - 1.0;

    let mut spans: Vec<Span<'a>> = Vec::with_capacity(text.len() + 4);
    spans.push(Span::styled(" ", Style::default()));

    for (i, ch) in text.chars().enumerate() {
        let t = if len > 0.0 { i as f32 / len } else { 0.0 };
        let r = START.0 as f32 + t * (END.0 as f32 - START.0 as f32);
        let g = START.1 as f32 + t * (END.1 as f32 - START.1 as f32);
        let b = START.2 as f32 + t * (END.2 as f32 - START.2 as f32);
        spans.push(Span::styled(
            ch.to_string(),
            Style::default()
                .fg(ratatui::style::Color::Rgb(r as u8, g as u8, b as u8))
                .add_modifier(Modifier::BOLD),
        ));
    }

    spans.push(Span::styled(
        format!(" v{} ", version),
        Style::default().fg(COMMENT),
    ));
    spans.push(Span::styled(
        format!("[{} sessions] ", session_count),
        Style::default().fg(WHITE).add_modifier(Modifier::BOLD),
    ));

    Line::from(spans)
}

fn render_footer(app: &App, frame: &mut Frame, area: Rect) {
    // Status message takes priority in Normal mode
    if app.mode == Mode::Normal {
        if let Some(msg) = &app.status_message {
            let color = match msg.level {
                StatusLevel::Success => GREEN,
                StatusLevel::Error => RED,
                StatusLevel::Info => YELLOW,
            };
            let footer = Paragraph::new(Line::from(vec![Span::styled(
                &msg.text,
                Style::default().fg(color),
            )]));
            frame.render_widget(footer, area);
            return;
        }
    }

    let keys = match app.mode {
        Mode::Normal => {
            "q:quit  Enter:open  n:new  d:delete  r:rename  m:move  s:secrets  /:search  P:push  L:pull  S:status  1-6:sort"
        }
        Mode::SessionMenu => "j/k:navigate  Enter:select  Esc:cancel",
        Mode::ConfirmDelete => "y:confirm  n:cancel",
        Mode::ConfirmForceOpen => "y:force open  n:cancel",
        Mode::Rename | Mode::MoveToRemote | Mode::CreateSession => "Enter:confirm  Esc:cancel",
        Mode::Secrets => "j/k:navigate  v/Enter:view  d:remove  Esc:close",
        Mode::SyncOutput(_) => "Press any key to dismiss",
        Mode::Search => unreachable!(),
    };
    let footer = Paragraph::new(Line::from(vec![Span::styled(
        keys,
        Style::default().fg(COMMENT),
    )]));
    frame.render_widget(footer, area);
}

fn render_search_bar(app: &App, frame: &mut Frame, area: Rect) {
    let line = Line::from(vec![
        Span::styled("/ ", Style::default().fg(GOLD)),
        Span::styled(app.search_input.before_cursor(), Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)),
        Span::styled(app.search_input.after_cursor(), Style::default().fg(WHITE)),
    ]);
    let paragraph = Paragraph::new(line);
    frame.render_widget(paragraph, area);
}

fn render_session_menu(app: &App, frame: &mut Frame) {
    let session_name = app
        .selected_session()
        .map(|s| s.name.as_str())
        .unwrap_or("?");

    let height = MENU_ITEMS.len() as u16 + 3;
    let popup_area = centered_rect(40, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(GOLD))
        .title(format!(" Actions - {} ", session_name))
        .title_style(Style::default().fg(GOLD).add_modifier(Modifier::BOLD));

    let lines: Vec<Line> = MENU_ITEMS
        .iter()
        .enumerate()
        .map(|(i, (label, shortcut))| {
            let shortcut_text = format!("[{}]", shortcut);
            if i == app.menu_selected {
                Line::from(vec![
                    Span::styled(">> ", Style::default().fg(GOLD).add_modifier(Modifier::BOLD)),
                    Span::styled(
                        format!("{:<18}", label),
                        Style::default().fg(WHITE).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(shortcut_text, Style::default().fg(COMMENT)),
                ])
            } else {
                Line::from(vec![
                    Span::styled("   ", Style::default()),
                    Span::styled(format!("{:<18}", label), Style::default().fg(COMMENT)),
                    Span::styled(shortcut_text, Style::default().fg(COMMENT)),
                ])
            }
        })
        .collect();

    let paragraph = Paragraph::new(lines).block(block);
    frame.render_widget(paragraph, popup_area);
}

fn render_confirm_delete(app: &App, frame: &mut Frame) {
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
    let hint_color = if remaining > 0 { COMMENT } else { WHITE };

    let popup_area = centered_rect(50, 7, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(RED))
        .title(" Confirm Delete ")
        .title_style(Style::default().fg(RED).add_modifier(Modifier::BOLD));

    let lines = vec![
        Line::from(Span::styled(action_msg, Style::default().fg(WHITE))),
        Line::from(""),
        Line::from(Span::styled(hint, Style::default().fg(hint_color))),
    ];
    let text = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(text, popup_area);
}

fn render_confirm_force_open(app: &App, frame: &mut Frame) {
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
        .border_style(Style::default().fg(YELLOW))
        .title(" Locked Session ")
        .title_style(Style::default().fg(YELLOW).add_modifier(Modifier::BOLD));
    let text = Paragraph::new(msg)
        .style(Style::default().fg(WHITE))
        .block(block)
        .wrap(Wrap { trim: true });
    frame.render_widget(text, popup_area);
}

fn render_rename_dialog(app: &App, frame: &mut Frame) {
    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(GOLD))
        .title(" Rename Session ")
        .title_style(Style::default().fg(GOLD).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(app.rename_input.before_cursor(), Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)),
        Span::styled(app.rename_input.after_cursor(), Style::default().fg(WHITE)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(WHITE))
        .block(block);
    frame.render_widget(text, popup_area);
}

fn render_create_dialog(app: &App, frame: &mut Frame) {
    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(GREEN))
        .title(" New Session ")
        .title_style(Style::default().fg(GREEN).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(app.create_input.before_cursor(), Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)),
        Span::styled(app.create_input.after_cursor(), Style::default().fg(WHITE)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(WHITE))
        .block(block);
    frame.render_widget(text, popup_area);
}

fn render_move_to_dialog(app: &App, frame: &mut Frame) {
    let session = match app.selected_session() {
        Some(s) => s,
        None => return,
    };

    let popup_area = centered_rect(50, 5, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ORANGE))
        .title(" Move to Remote ")
        .title_style(Style::default().fg(ORANGE).add_modifier(Modifier::BOLD));

    let line = Line::from(vec![
        Span::styled(
            format!("Move '{}' to: ", session.name),
            Style::default().fg(COMMENT),
        ),
        Span::styled(app.move_to_input.before_cursor(), Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)),
        Span::styled(app.move_to_input.after_cursor(), Style::default().fg(WHITE)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(WHITE))
        .block(block);
    frame.render_widget(text, popup_area);
}

fn render_secrets_popup(app: &App, frame: &mut Frame) {
    let session_name = app
        .selected_session()
        .map(|s| s.name.as_str())
        .unwrap_or("?");

    let height = (app.secrets_names.len() as u16 + 3).max(5).min(20);
    let popup_area = centered_rect(50, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ORANGE))
        .title(format!(" Secrets - {} ", session_name))
        .title_style(Style::default().fg(ORANGE).add_modifier(Modifier::BOLD));

    if app.secrets_names.is_empty() {
        let paragraph = Paragraph::new("No secrets stored")
            .style(Style::default().fg(COMMENT))
            .block(block);
        frame.render_widget(paragraph, popup_area);
        return;
    }

    let lines: Vec<Line> = app
        .secrets_names
        .iter()
        .enumerate()
        .map(|(i, name)| {
            if i == app.secrets_selected {
                Line::from(vec![
                    Span::styled(">> ", Style::default().fg(GOLD).add_modifier(Modifier::BOLD)),
                    Span::styled(
                        name.as_str(),
                        Style::default().fg(WHITE).add_modifier(Modifier::BOLD),
                    ),
                ])
            } else {
                Line::from(vec![
                    Span::styled("   ", Style::default()),
                    Span::styled(name.as_str(), Style::default().fg(COMMENT)),
                ])
            }
        })
        .collect();

    let paragraph = Paragraph::new(lines).block(block);
    frame.render_widget(paragraph, popup_area);
}

fn render_sync_output(text: &str, frame: &mut Frame) {
    let popup_area = centered_rect(80, 20, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ORANGE))
        .title(" Sync Output ")
        .title_style(Style::default().fg(ORANGE).add_modifier(Modifier::BOLD));
    let paragraph = Paragraph::new(text.to_string())
        .style(Style::default().fg(WHITE))
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
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
