// ABOUTME: Renders the session table, header, footer, and modal dialogs using Ratatui widgets
// ABOUTME: Handles layout splitting, column sizing, sort indicators, and search input display

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Clear, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::app::{App, Mode, SortColumn, SortDirection};
use crate::theme::{self, COMMENT, GOLD, ORANGE, RED, RUST, WHITE};

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
        Mode::ConfirmDelete => render_confirm_delete(app, frame),
        Mode::Rename => render_rename_dialog(app, frame),
        Mode::SyncOutput(text) => render_sync_output(text, frame),
        _ => {}
    }
}

fn render_table(app: &mut App, frame: &mut Frame, area: Rect) {
    let icons = theme::icons();
    let has_remote = app.has_remote_sessions();

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
        Cell::from(format!("SESSION{}", sort_indicator(SortColumn::Name))),
        Cell::from(format!("CREATED{}", sort_indicator(SortColumn::Created))),
        Cell::from(format!("MODIFIED{}", sort_indicator(SortColumn::Modified))),
    ];
    if has_remote {
        header_cells.push(Cell::from(format!(
            "LOCATION{}",
            sort_indicator(SortColumn::Location)
        )));
    }
    let header = Row::new(header_cells)
        .style(Style::default().fg(RUST).add_modifier(Modifier::BOLD))
        .height(1);

    let rows: Vec<Row> = app
        .filtered
        .iter()
        .map(|&i| {
            let s = &app.sessions[i];
            let mut name_text = s.name.clone();
            if s.is_locked {
                name_text.push_str(&format!(" {}", icons.lock));
            }
            if s.secrets_count > 0 {
                name_text.push_str(&format!(" ({} {})", icons.lock, s.secrets_count));
            }

            let mut cells = vec![
                Cell::from(name_text).style(Style::default().fg(GOLD)),
                Cell::from(s.created.clone().unwrap_or_else(|| "-".into()))
                    .style(Style::default().fg(COMMENT)),
                Cell::from(s.modified.clone().unwrap_or_else(|| "-".into()))
                    .style(Style::default().fg(COMMENT)),
            ];
            if has_remote {
                let loc = s
                    .location
                    .as_ref()
                    .map(|l| format!("{} {}", icons.remote, l))
                    .unwrap_or_default();
                cells.push(Cell::from(loc).style(Style::default().fg(ORANGE)));
            }
            Row::new(cells)
        })
        .collect();

    let mut widths = vec![
        Constraint::Min(20),
        Constraint::Length(16),
        Constraint::Length(16),
    ];
    if has_remote {
        widths.push(Constraint::Min(10));
    }

    let session_count = app.filtered.len();
    let title = format!(" cs - Session Manager  [{} sessions] ", session_count);

    let table = Table::new(rows, widths)
        .header(header)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(RUST))
                .title(title)
                .title_style(Style::default().fg(WHITE).add_modifier(Modifier::BOLD)),
        )
        .row_highlight_style(
            Style::default()
                .fg(WHITE)
                .add_modifier(Modifier::REVERSED),
        )
        .highlight_symbol(">> ");

    frame.render_stateful_widget(table, area, &mut app.table_state);
}

fn render_footer(app: &App, frame: &mut Frame, area: Rect) {
    let keys = match app.mode {
        Mode::Normal => {
            if let Some(msg) = &app.status_message {
                msg.as_str().to_string()
            } else {
                "q:quit  Enter:open  d:delete  r:rename  /:search  P:push  L:pull  S:status  1-4:sort".to_string()
            }
        }
        Mode::ConfirmDelete => "y:confirm  n:cancel".to_string(),
        Mode::Rename => "Enter:confirm  Esc:cancel".to_string(),
        Mode::SyncOutput(_) => "Press any key to dismiss".to_string(),
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
        Span::styled(&app.search_query, Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)), // block cursor
    ]);
    let paragraph = Paragraph::new(line);
    frame.render_widget(paragraph, area);
}

fn render_confirm_delete(app: &App, frame: &mut Frame) {
    let session = match app.selected_session() {
        Some(s) => s,
        None => return,
    };

    let msg = if session.is_adopted {
        format!(
            "Remove adopted session '{}'?\n(removes symlink only, project preserved)",
            session.name
        )
    } else {
        format!("Delete session '{}'?\nThis cannot be undone.", session.name)
    };

    let popup_area = centered_rect(50, 6, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(RED))
        .title(" Confirm Delete ")
        .title_style(Style::default().fg(RED).add_modifier(Modifier::BOLD));
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
        Span::styled(&app.rename_input, Style::default().fg(WHITE)),
        Span::styled("\u{2588}", Style::default().fg(WHITE)),
    ]);
    let text = Paragraph::new(line)
        .style(Style::default().fg(WHITE))
        .block(block);
    frame.render_widget(text, popup_area);
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
    let popup_layout =
        Layout::vertical([
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
