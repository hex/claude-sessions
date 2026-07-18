// ABOUTME: Renders the session table, header, footer, and modal dialogs using Ratatui widgets
// ABOUTME: Handles layout splitting, column sizing, sort indicators, and search input display

use ratatui::buffer::Buffer;
use ratatui::layout::{Constraint, Layout, Margin, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, Borders, Cell, Clear, HighlightSpacing, Paragraph, Row, Table, Wrap,
};
use ratatui::Frame;
use unicode_width::UnicodeWidthStr;

use ratatui::layout::Alignment;

use crate::app::{
    parse_tag_query, App, FlashKind, Focus, Mode, NotesFocus, SortColumn, SortDirection,
    StatusLevel,
};
use crate::theme::{self, Palette};

const PREVIEW_MIN_WIDTH: u16 = 120;

/// Minimum width for the stacked layout: below this the three full-width panes
/// and the table's columns are too cramped, so a narrow window falls back to the
/// table alone.
const STACK_MIN_WIDTH: u16 = 40;

/// Minimum height for the stacked layout, measured against the content pane —
/// the terminal height minus the masthead's 2 rows and the footer's 1 row.
/// The three panes take 50/30/20 of that pane, and the To-Do pane needs 5 rows
/// (two borders, the input, its rule, and one task). 20% of 23 is the first
/// height that clears that floor.
const STACK_MIN_HEIGHT: u16 = 23;

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

/// Blank cells between table columns. Structure is carried by alignment,
/// section dividers, and the header rule — not by vertical divider glyphs.
pub const COL_SPACING: u16 = 2;
/// Width reserved at the left of each row for the selection accent bar ("▌ ").
pub const SELECT_WIDTH: u16 = 2;
/// The selection accent-bar glyph. Set as the row highlight symbol and located
/// again post-render to shimmer it — kept here so the two sites can't drift.
const SELECT_BAR: &str = "\u{258c}";

/// Two-phase liveness blink for the gutter lock square: base teal on the
/// first half of the period, a lightened teal on the second. `blinking`
/// follows the animation heartbeat, so an idle picker freezes on steady
/// teal instead of pulsing unattended.
fn lock_square_color(p: theme::Palette, blinking: bool, now_ms: u128) -> Color {
    const PERIOD_MS: u128 = 2400;
    if blinking && (now_ms % PERIOD_MS) >= PERIOD_MS / 2 {
        let (r, g, b) = theme::lerp_rgb(theme::rgb_of(p.teal), (255, 255, 255), 0.45);
        Color::Rgb(r, g, b)
    } else {
        p.teal
    }
}

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

/// Most rows the to-do input (or an in-place edit) may grow to before it
/// scrolls vertically to follow the cursor.
const MAX_INPUT_ROWS: usize = 4;

/// Display-width-aware word wrap: byte ranges of `s` split into lines no wider
/// than `width` columns. Breaks at the last space on the line when one exists
/// (the space itself is swallowed), hard-breaks runs longer than a line, and
/// never splits a char. Always returns at least one (possibly empty) range.
fn wrap_cols_ranges(s: &str, width: usize) -> Vec<(usize, usize)> {
    use unicode_width::UnicodeWidthChar;
    if width == 0 {
        return vec![(0, s.len())];
    }
    let mut lines = Vec::new();
    let mut start = 0usize;
    let mut used = 0usize;
    let mut last_space: Option<usize> = None;
    for (i, ch) in s.char_indices() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > width && used > 0 {
            if let Some(sp) = last_space {
                lines.push((start, sp));
                start = sp + 1; // the break swallows the space
                used = s[start..i].width();
            } else {
                lines.push((start, i));
                start = i;
                used = 0;
            }
            last_space = None;
        }
        if ch == ' ' {
            last_space = Some(i);
        }
        used += cw;
    }
    lines.push((start, s.len()));
    lines
}

/// Wrapped rows for an editable field: character wrap at `width` columns with
/// the block cursor placed at `cursor` (a byte offset on a char boundary). At
/// most `max_rows` rows come back, scrolled so the cursor's row is included.
fn cursor_wrap_spans(
    text: &str,
    cursor: usize,
    width: usize,
    max_rows: usize,
    text_style: Style,
    cursor_style: Style,
) -> Vec<Vec<Span<'static>>> {
    let ranges = wrap_cols_ranges(text, width);
    // First row whose range covers the cursor inclusively; a cursor sitting on
    // a swallowed break-space renders at that row's end.
    let cursor_row = ranges
        .iter()
        .position(|&(s, e)| cursor >= s && cursor <= e)
        .unwrap_or(ranges.len() - 1);
    let first = (cursor_row + 1).saturating_sub(max_rows);
    ranges
        .iter()
        .enumerate()
        .skip(first)
        .take(max_rows)
        .map(|(row, &(s, e))| {
            if row == cursor_row {
                let cur = cursor.clamp(s, e);
                vec![
                    Span::styled(text[s..cur].to_string(), text_style),
                    Span::styled("\u{2588}".to_string(), cursor_style),
                    Span::styled(text[cur..e].to_string(), text_style),
                ]
            } else {
                vec![Span::styled(text[s..e].to_string(), text_style)]
            }
        })
        .collect()
}

/// 4-segment queue-depth meter: 0→empty, 1→1, 2-3→2, 4-5→3, 6+→4 filled.
fn qbar(n: u32) -> String {
    let f = match n {
        0 => 0,
        1 => 1,
        2..=3 => 2,
        4..=5 => 3,
        _ => 4,
    };
    (0..4).map(|i| if i < f { '\u{25b0}' } else { '\u{25b1}' }).collect()
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
        Constraint::Length(2), // masthead: brand row + gradient rule
        Constraint::Min(5),
        Constraint::Length(action_bar_height),
        Constraint::Length(1),
    ])
    .split(frame.area());

    render_masthead(app, frame, chunks[0]);

    match choose_layout(chunks[1], app.show_preview) {
        PaneLayout::SideBySide => {
            app.request_preview();
            let cols = Layout::horizontal([Constraint::Percentage(45), Constraint::Percentage(55)])
                .split(chunks[1]);
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
                Constraint::Percentage(25),
                Constraint::Percentage(45),
                Constraint::Percentage(30),
            ])
            .split(chunks[1]);
            render_table(app, frame, rows[0], true);
            render_preview_pane(app, frame, rows[1]);
            render_notes_pane(app, frame, rows[2]);
        }
        PaneLayout::TableOnly => {
            render_table(app, frame, chunks[1], false);
        }
    }

    if app.mode == Mode::SessionMenu {
        render_action_bar(app, frame, chunks[2]);
    }

    match &app.mode {
        Mode::Search => render_search_bar(app, frame, chunks[3]),
        _ => render_footer(app, frame, chunks[3]),
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
        Mode::Changelog => render_changelog(app, frame),
        Mode::Legend => render_legend(app, frame),
        _ => {}
    }
}

/// B′ masthead: brand, prominent counts, explicit sort readout, and a
/// full-width HERO gradient rule beneath.
fn render_masthead(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    if area.height < 2 {
        return;
    }
    let live = app.sessions.iter().filter(|s| s.is_locked).count();
    let archived = app.sessions.iter().filter(|s| s.archived).count();
    let dir = match app.sort_dir {
        SortDirection::Asc => "\u{25b2}",
        SortDirection::Desc => "\u{25bc}",
    };
    let mut spans = vec![
        Span::styled("\u{258c} ", Style::default().fg(p.rail[0])),
        Span::styled("cs-tui", Style::default().fg(p.rust).add_modifier(Modifier::BOLD)),
        Span::styled(
            format!("  {} sessions", app.sessions.len()),
            Style::default().fg(p.ink).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("  \u{b7}  {} live", live), Style::default().fg(p.teal)),
    ];
    if archived > 0 {
        spans.push(Span::styled(
            format!("  \u{b7}  {} archived", archived),
            Style::default().fg(p.faint),
        ));
    }
    spans.push(Span::styled(
        format!("  \u{b7}  sorted by {} {}", sort_label(app.sort_col), dir),
        Style::default().fg(p.mut_),
    ));
    let line = Line::from(spans);
    frame.render_widget(Paragraph::new(line), Rect { height: 1, ..area });

    let stops: Vec<(u8, u8, u8)> = p.hero.iter().map(|c| theme::rgb_of(*c)).collect();
    let buf = frame.buffer_mut();
    for i in 0..area.width {
        let (r, g, b) = theme::ramp(&stops, area.width, i);
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(area.x + i, area.y + 1)) {
            cell.set_char('\u{2501}');
            cell.set_fg(ratatui::style::Color::Rgb(r, g, b));
        }
    }
}

fn sort_label(col: SortColumn) -> &'static str {
    match col {
        SortColumn::Name => "session",
        SortColumn::Created => "created",
        SortColumn::Modified => "age",
        SortColumn::Secrets => "secrets",
        SortColumn::Todo => "queue",
        SortColumn::Github => "github",
    }
}

fn render_table(app: &mut App, frame: &mut Frame, area: Rect, preview_open: bool) {
    let p = app.theme;

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

    let mut widths: Vec<Constraint> = vec![
        Constraint::Min(20),    // Session
        Constraint::Length(10), // Created (date)
        Constraint::Length(6),  // Age (relative)
    ];
    if show_secrets { widths.push(Constraint::Length(9)); }
    if show_todos { widths.push(Constraint::Length(7)); }
    if show_github { widths.push(Constraint::Min(15)); }

    // Resolve column geometry with ratatui's own solver so mouse hit-testing
    // never drifts from where the Table actually draws. (Drift between a
    // hand-rolled approximation and the real layout is what made the old
    // dividers slice through cells.) The Table reserves SELECT_WIDTH at the left
    // for the selection symbol, then lays the columns out across the remainder.
    let inner = area; // no border insets — the table is borderless
    let cols_area = Rect {
        x: inner.x + SELECT_WIDTH,
        width: inner.width.saturating_sub(SELECT_WIDTH),
        ..inner
    };
    let col_rects = Layout::horizontal(widths.clone())
        .spacing(COL_SPACING)
        .split(cols_area);
    app.column_widths = col_rects.iter().map(|r| r.width).collect();

    let sort_indicator = |col: SortColumn| -> &'static str {
        if app.sort_col != col {
            return "";
        }
        match app.sort_dir {
            SortDirection::Asc => " \u{25b2}",
            SortDirection::Desc => " \u{25bc}",
        }
    };

    // Label span styled MUT bold; sort indicator (when this is the active
    // sort column) styled RUST as its own span, so only the arrow picks up
    // the accent color.
    let header_cell = |label: &str, col: SortColumn| -> Cell<'static> {
        let mut spans = vec![Span::styled(
            label.to_string(),
            Style::default().fg(p.mut_).add_modifier(Modifier::BOLD),
        )];
        let indicator = sort_indicator(col);
        if !indicator.is_empty() {
            spans.push(Span::styled(indicator, Style::default().fg(p.rust)));
        }
        Cell::from(Line::from(spans))
    };

    // Inline symbol legend in the SESSION column's free width (wide headers
    // only): the glyphs the rows actually use, keyed where the symbols live.
    // A fixed gap after the label keeps it beside SESSION, reading as
    // annotation rather than a column of its own.
    let session_cell = || -> Cell<'static> {
        let mut spans = vec![Span::styled(
            "SESSION".to_string(),
            Style::default().fg(p.mut_).add_modifier(Modifier::BOLD),
        )];
        let indicator = sort_indicator(SortColumn::Name);
        if !indicator.is_empty() {
            spans.push(Span::styled(indicator, Style::default().fg(p.rust)));
        }
        // Compact labels: the SESSION column is ~50 cols once the preview
        // pane takes its 55% share, so every character here is rationed.
        // The `?` overlay carries the long-form wording.
        // Archived rows have no gutter glyph — they just dim — so its legend
        // entry is the word itself in the dim colour, demonstrating the
        // treatment instead of advertising a glyph that never renders.
        let legend: [(&str, Color, &str, Color); 4] = [
            ("\u{25cf}", p.green, "activity", p.faint),
            ("\u{25a0}", p.teal, "live", p.faint),
            ("*", p.gold, "marked", p.faint),
            ("", p.comment, "archived", p.comment),
        ];
        let legend_w: usize = legend
            .iter()
            .map(|(g, _, l, _)| {
                if g.is_empty() {
                    l.len()
                } else {
                    g.chars().count() + 1 + l.len()
                }
            })
            .sum::<usize>()
            + 2 * (legend.len() - 1);
        let used = "SESSION".len() + indicator.chars().count();
        let name_col_w = app.column_widths.first().copied().unwrap_or(0) as usize;
        // Render only when the legend keeps clear air on both sides.
        if name_col_w >= used + 3 + legend_w + 1 {
            spans.push(Span::raw("   "));
            for (i, (glyph, color, label, label_color)) in legend.iter().enumerate() {
                if i > 0 {
                    spans.push(Span::raw("  "));
                }
                if !glyph.is_empty() {
                    let mut style = Style::default().fg(*color);
                    if *glyph == "*" {
                        style = style.add_modifier(Modifier::BOLD);
                    }
                    spans.push(Span::styled(glyph.to_string(), style));
                    spans.push(Span::raw(" "));
                }
                spans.push(Span::styled(label.to_string(), Style::default().fg(*label_color)));
            }
        }
        Cell::from(Line::from(spans))
    };

    let mut header_cells = vec![
        session_cell(),
        header_cell("CREATED", SortColumn::Created),
        header_cell("AGE", SortColumn::Modified),
    ];
    if show_secrets {
        header_cells.push(header_cell("SECRETS", SortColumn::Secrets));
    }
    if show_todos {
        header_cells.push(header_cell("QUEUE", SortColumn::Todo));
    }
    if show_github {
        header_cells.push(header_cell("GITHUB", SortColumn::Github));
    }

    let header = Row::new(header_cells).bottom_margin(1);

    // Dimming keys on the fuzzy remainder, not the raw search text: a
    // tag-only query like "#api" has already narrowed `filtered` via the tag
    // predicate and leaves no fuzzy match to dim against.
    let (_, fuzzy_remainder) = parse_tag_query(app.search_input.text());
    let is_searching = app.mode == Mode::Search && !fuzzy_remainder.is_empty();

    // One wall-clock read per frame, shared by every row's recency math and
    // the lock-square blink phase.
    let now = std::time::SystemTime::now();
    let blinking = app.is_animating(app.idle_elapsed());
    let now_ms = now
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);

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
            let dimmed = (is_searching && !app.fuzzy_indices.contains_key(&i)) || s.archived;

            // Recency heat: green when live, fading to grey when dormant. Computed
            // once and reused for the dot and the Age column.
            let heat = if dimmed { p.comment } else { p.heat_color(s.modified_ts) };

            // Build gutter indicators as colored prefix spans. A locked session
            // shows a filled square in place of the recency dot — the square
            // itself is the lock signal, so no separate lock glyph follows it.
            let mut name_spans: Vec<Span> = Vec::new();
            if s.is_locked {
                let sq = if dimmed {
                    p.comment
                } else {
                    lock_square_color(p, blinking, now_ms)
                };
                name_spans.push(Span::styled("\u{25a0} ", Style::default().fg(sq)));
            } else {
                name_spans.push(Span::styled("\u{25cf} ", Style::default().fg(heat)));
            }
            if app.marked_sessions.contains(&s.name) {
                let mark_color = if dimmed { p.comment } else { p.gold };
                name_spans.push(Span::styled(
                    "* ",
                    Style::default().fg(mark_color).add_modifier(Modifier::BOLD),
                ));
            }
            if s.secrets_count > 0 && !show_secrets {
                // Show secrets indicator in gutter only when secrets column is hidden.
                let secrets_color = if dimmed { p.comment } else { p.gold };
                name_spans.push(Span::styled(
                    "\u{25aa} ",
                    Style::default().fg(secrets_color),
                ));
            }

            let name_color = if dimmed {
                p.comment
            } else {
                p.ink
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

            // Number of lead lines a section-start row prepends before its own
            // content: 0 for a plain row, 1 for the divider on the first
            // section (flush with the header rule), 2 for the blank spacer plus
            // divider on every later section.
            let section_lead_count: u16 = match section_label {
                Some(_) if row_idx != 0 => 2,
                Some(_) => 1,
                None => 0,
            };

            let mut name_lines: Vec<Line> = Vec::new();

            if let Some(label) = section_label {
                // Section size: rows from this divider up to (not including) the
                // next section's divider, or the end of the filtered list.
                let count = app
                    .section_labels
                    .iter()
                    .enumerate()
                    .skip(row_idx + 1)
                    .find(|(_, l)| l.is_some())
                    .map(|(next, _)| next - row_idx)
                    .unwrap_or(app.section_labels.len() - row_idx);
                if row_idx != 0 {
                    name_lines.push(Line::from(""));
                }
                // Full-width divider: "── <label> · <count> " then dashes to fill
                // the Session column. The line is clipped to the column width by
                // the table, so a generous fixed run reaches the right edge at any
                // terminal size without needing the (not-yet-computed) width here.
                name_lines.push(Line::from(vec![
                    Span::styled(
                        format!("── {} \u{b7} {} ", label, count),
                        Style::default().fg(p.mut_).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled("─".repeat(200), Style::default().fg(p.soft)),
                ]));
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

            // On a section-start row, every non-name column leads with the same
            // number of blank lines as the name column's spacer + divider, so
            // the real values drop into alignment with the session name below.
            let with_lead = |line: Line<'static>| -> ratatui::text::Text<'static> {
                if section_lead_count > 0 {
                    let mut lines = vec![Line::from(""); section_lead_count as usize];
                    lines.push(line);
                    ratatui::text::Text::from(lines)
                } else {
                    ratatui::text::Text::from(line)
                }
            };

            let mut cells = vec![
                name_cell,
                Cell::from(with_lead(Line::from(created_date))).style(Style::default().fg(meta_color)),
                Cell::from(with_lead(Line::from(modified_rel))).style(age_style),
            ];

            if show_secrets {
                let (secrets, secrets_color) = if s.secrets_count > 0 {
                    (s.secrets_count.to_string(), p.ink)
                } else if dimmed {
                    ("\u{b7}".to_string(), p.comment)
                } else {
                    ("\u{b7}".to_string(), p.faint)
                };
                let secrets_line = Line::from(secrets).alignment(Alignment::Center);
                cells.push(Cell::from(with_lead(secrets_line)).style(Style::default().fg(secrets_color)));
            }

            if show_todos {
                let qcolor = if dimmed {
                    p.comment
                } else if s.queue_depth > 3 {
                    p.rust
                } else if s.queue_depth > 0 {
                    p.amber
                } else {
                    p.faint
                };
                // The digit is a count, not part of the meter — it stays MUT
                // rather than riding the bar's depth-driven accent color.
                let todo_line = if s.queue_depth > 0 {
                    let digit_color = if dimmed { p.comment } else { p.mut_ };
                    Line::from(vec![
                        Span::styled(qbar(s.queue_depth), Style::default().fg(qcolor)),
                        Span::raw(" "),
                        Span::styled(s.queue_depth.to_string(), Style::default().fg(digit_color)),
                    ])
                } else {
                    Line::from(Span::styled(qbar(0), Style::default().fg(qcolor)))
                };
                cells.push(Cell::from(with_lead(todo_line)));
            }

            if show_github {
                let github = s.git_repo.clone().unwrap_or_default();
                let github_color = if dimmed {
                    p.comment
                } else if app.table_state.selected() == Some(row_idx) {
                    p.rust
                } else {
                    p.faint
                };
                if github.is_empty() {
                    cells.push(Cell::from(with_lead(Line::from(String::new()))));
                } else {
                    // Width comes from the previous frame's solved layout —
                    // widths are stable frame-to-frame — so skip truncation
                    // when it isn't known yet (first frame, or an empty table).
                    let text = match app.column_widths.last() {
                        Some(&w) if w > 0 => crate::session::truncate_repo(&github, w as usize),
                        _ => github,
                    };
                    cells.push(Cell::from(with_lead(Line::from(Span::styled(
                        text,
                        Style::default().fg(github_color),
                    )))));
                }
            }

            let extra_height = section_lead_count + preview_lines;
            let height = 1 + extra_height;
            row_heights.push(height);
            let row = Row::new(cells).height(height);

            // Flash background takes priority; otherwise the row is unstyled —
            // B′ carries row structure through the wash selection and the
            // header rule, not zebra striping.
            if let Some(flash) = app.active_flash(&s.name) {
                let bg = match flash {
                    FlashKind::Success => p.flash_success,
                    FlashKind::Error => p.flash_error,
                };
                row.style(Style::default().bg(bg))
            } else {
                row
            }
        })
        .collect();

    let table = Table::new(rows, widths)
        .header(header)
        .column_spacing(COL_SPACING)
        .row_highlight_style(Style::default().bg(p.wash).add_modifier(Modifier::BOLD))
        .highlight_symbol(format!("{SELECT_BAR} "))
        .highlight_spacing(HighlightSpacing::Always);

    frame.render_stateful_widget(table, area, &mut app.table_state);

    // Publish the row hit-map now that ratatui has finalized the scroll offset.
    // Data rows begin at relative y = 2 (header, header rule) and stack by
    // their true heights, so clicks below a group header or an expanded row
    // still resolve to the right session. Only on-screen rows are recorded.
    app.row_hit_spans.clear();
    let buf = frame.buffer_mut();
    let bottom = area.height; // no border to reserve a bottom row for
    let session_col_right = col_rects[0].x + col_rects[0].width;
    let mut y = 2u16;
    for (idx, &h) in row_heights
        .iter()
        .enumerate()
        .skip(app.table_state.offset())
    {
        if y >= bottom {
            break;
        }
        app.row_hit_spans.push((y, h, idx));

        // The in-cell dash run (name_lines, above) only ever fills the Session
        // column — the Table clips each cell's Text to that column's width.
        // Paint the rest of a divider row's width, from the Session column's
        // right edge to the table's right edge, directly into the buffer so
        // the rule reaches across the meta columns too. A section-start row
        // carries its divider as the first line of the row, one line lower
        // when it also has the blank spacer above it (every section but the
        // first — see section_lead_count above). The Table clips a partially
        // visible row's lines at the table's bottom edge; this paint must
        // clip the same way, or a divider whose row tops the last visible
        // line would land one row past the table (in the footer).
        if app.section_labels.get(idx).copied().flatten().is_some() {
            let divider_offset = if idx == 0 { 0 } else { 1 };
            if y + divider_offset < bottom {
                let divider_y = inner.y + y + divider_offset;
                for x in session_col_right..inner.x.saturating_add(inner.width) {
                    if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, divider_y)) {
                        cell.set_char('\u{2500}');
                        cell.set_fg(p.soft);
                    }
                }
            }
        }

        y = y.saturating_add(h);
    }

    // A single hairline rule beneath the header, drawn into the header's blank
    // bottom-margin row. Structure stays quiet — no vertical dividers or table
    // border; alignment and the wash selection carry the columns.
    let rule_y = inner.y + 1;
    for x in inner.x..inner.x.saturating_add(inner.width) {
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, rule_y)) {
            cell.set_char('\u{2500}');
            cell.set_fg(p.soft);
        }
    }

    // Recolor the selection accent bar along the rail gradient, sampled by a
    // sawtooth phase (rises linearly across PERIOD_MS, then resets to 0). We
    // locate the bar by its glyph in the selection column rather than
    // recomputing the selected row's y (rows have variable height), which
    // keeps this robust.
    let phase = {
        const PERIOD_MS: u128 = 1400;
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        (ms % PERIOD_MS) as f32 / PERIOD_MS as f32
    };
    for y in (inner.y + 2)..inner.y.saturating_add(inner.height) {
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(inner.x, y)) {
            if cell.symbol() == SELECT_BAR {
                let stops: Vec<(u8, u8, u8)> = p.rail.iter().map(|c| theme::rgb_of(*c)).collect();
                let idx = (phase * (stops.len() as f32 - 1.0)).round() as u16;
                let (r, g, b) = theme::ramp(&stops, stops.len() as u16, idx.min(stops.len() as u16 - 1));
                cell.set_fg(ratatui::style::Color::Rgb(r, g, b));
                break;
            }
        }
    }
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
                "q:quit  Enter:open  n:new  d:delete  r:rename  Tab:to-do  Space:mark  /:search  1-6:sort  A:archived  ?:legend"
            }
            Mode::SessionMenu => "j/k:navigate  Enter:select  Esc:cancel",
            Mode::ConfirmDelete | Mode::ConfirmBatchDelete => "y:confirm  n:cancel",
            Mode::ConfirmForceOpen => "y:force open  n:cancel",
            Mode::Rename | Mode::CreateSession => "Enter:confirm  Esc:cancel",
            Mode::Secrets => "j/k:navigate  v/Enter:view  d:remove  Esc:close",
            Mode::CommandOutput(_) => "Press any key to dismiss",
            Mode::Changelog => "Esc:close",
            Mode::Legend => "Esc:close",
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
    // Parts are trimmed before rejoining: the Notes-focus hint strings above
    // use 3-space separators, which split("  ") leaves a stray leading space
    // on (e.g. "editing" then " Enter:save") — trimming normalizes every
    // part so the loop below can rejoin them with one standard 3-space gap.
    for (i, part) in keys.split("  ").map(str::trim).filter(|s| !s.is_empty()).enumerate() {
        if i > 0 {
            footer_spans.push(Span::raw("   "));
        }
        match part.split_once(':') {
            Some((k, label)) => {
                footer_spans.push(Span::styled(
                    k.to_string(),
                    Style::default().fg(p.rust).add_modifier(Modifier::BOLD),
                ));
                footer_spans.push(Span::styled(
                    format!(" {label}"),
                    Style::default().fg(p.mut_),
                ));
            }
            None => footer_spans.push(Span::styled(part.to_string(), Style::default().fg(p.mut_))),
        }
    }

    // The version corner doubles as the update badge: amber and actionable
    // when cs's caches say a newer version exists, faint otherwise.
    let version = std::env::var("CS_VERSION").unwrap_or_default();
    let (vtext, vstyle) = match &app.update_notice {
        Some(notice) => (
            format!("\u{2191} v{} available \u{b7} C:changelog", notice.version),
            Style::default().fg(p.amber).add_modifier(Modifier::BOLD),
        ),
        None if version.is_empty() => (String::new(), Style::default().fg(p.faint)),
        None => (format!("v{version}"), Style::default().fg(p.faint)),
    };
    let vw = vtext.chars().count() as u16;
    let show_version = !vtext.is_empty() && area.width > vw + 2;

    // When the version will be painted, clip the hints to leave its column
    // range (plus a 3-col gap) untouched, so the version can never land on
    // top of hint text — it used to be painted over whatever the hints
    // Paragraph had already drawn there.
    let hints_area = if show_version {
        Rect { width: area.width.saturating_sub(vw + 3), ..area }
    } else {
        area
    };
    let footer = Paragraph::new(Line::from(footer_spans));
    frame.render_widget(footer, hints_area);

    if show_version {
        let vrect = Rect { x: area.x + area.width - vw, width: vw, ..area };
        frame.render_widget(Paragraph::new(Span::styled(vtext, vstyle)), vrect);
    }
}

fn render_search_bar(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let mut spans = vec![
        Span::styled("/ ", Style::default().fg(p.gold)),
        Span::styled(app.search_input.before_cursor(), Style::default().fg(p.fg)),
        Span::styled("\u{2588}", Style::default().fg(p.fg)),
        Span::styled(app.search_input.after_cursor(), Style::default().fg(p.fg)),
    ];
    // Only hinted while the input is empty, so it never crowds a real query.
    if app.search_input.text().is_empty() {
        spans.push(Span::styled(
            "  #tag filters",
            Style::default().fg(p.faint).add_modifier(Modifier::DIM),
        ));
    }
    let paragraph = Paragraph::new(Line::from(spans));
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
        .style(Style::default().bg(p.soft));
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

    let popup_area = centered_rect(55, 7, frame.area());
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

/// Centered overlay listing the pending update's release-note summaries from
/// cs's notes cache; a tombstoned or missing cache gets a pointer to the CLI.
fn render_changelog(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let notice = match &app.update_notice {
        Some(n) => n,
        None => return,
    };

    let mut lines: Vec<Line> = vec![Line::default()];
    if notice.notes.is_empty() {
        lines.push(Line::from(Span::styled(
            "  release notes unavailable \u{2014} run cs -update --check",
            Style::default().fg(p.faint),
        )));
    } else {
        for (ver, summary) in &notice.notes {
            if ver == "+" {
                lines.push(Line::from(Span::styled(
                    format!("       {summary}"),
                    Style::default().fg(p.faint).add_modifier(Modifier::DIM),
                )));
            } else {
                lines.push(Line::from(vec![
                    Span::styled(
                        format!("  {ver:>9}  "),
                        Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(summary.clone(), Style::default().fg(p.ink)),
                ]));
            }
        }
    }
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        "  update with: cs -update",
        Style::default().fg(p.faint).add_modifier(Modifier::DIM),
    )));

    let height = (lines.len() as u16 + 2).min(frame.area().height.saturating_sub(2));
    let popup_area = centered_rect(70, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.amber))
        .title(format!(" update available \u{2014} v{} ", notice.version))
        .title_style(Style::default().fg(p.amber).add_modifier(Modifier::BOLD));
    let paragraph = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
}

/// Centered overlay explaining the gutter glyphs and row colors of the
/// session table. Swatches use the same palette colors the rows use, so the
/// legend stays true in both themes.
fn render_legend(app: &App, frame: &mut Frame) {
    let p = app.theme;
    let entry = |glyph: &str, color: Color, bold: bool, label: &str| -> Line<'static> {
        let mut style = Style::default().fg(color);
        if bold {
            style = style.add_modifier(Modifier::BOLD);
        }
        Line::from(vec![
            Span::styled(format!("  {glyph:^3} "), style),
            Span::styled(label.to_string(), Style::default().fg(p.ink)),
        ])
    };
    let lines: Vec<Line> = vec![
        Line::default(),
        entry("\u{25cf}", p.green, false, "recency dot \u{2014} green when recently active, fading to grey as the session goes dormant"),
        entry("\u{25a0}", p.teal, false, "locked \u{2014} a conversation is live in this session right now (shown in place of the recency dot)"),
        entry("*", p.gold, true, "marked with Space for batch actions (D deletes the marked set)"),
        entry("\u{25aa}", p.gold, false, "has stored secrets (shown here when the SECRETS column is hidden)"),
        entry("\u{2500}", p.comment, false, "dim grey row \u{2014} archived session, or not matching the current search"),
        entry("\u{25b6}", p.teal, false, "to-do pane: the queue task Claude is actively working right now"),
        Line::default(),
    ];

    let height = (lines.len() as u16 + 2).min(frame.area().height.saturating_sub(2));
    let popup_area = centered_rect(80, height, frame.area());
    frame.render_widget(Clear, popup_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(p.strong))
        .title(" legend ")
        .title_style(Style::default().fg(p.ink).add_modifier(Modifier::BOLD));
    let paragraph = Paragraph::new(lines).block(block).wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
}

/// A body-section header for the preview pane: a muted accent bar, then the
/// label in bold. Shared by every section so the accent stays uniform.
fn section_header(label: impl Into<String>, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled("\u{258f} ", Style::default().fg(p.ember)),
        Span::styled(
            label.into(),
            Style::default().fg(p.mut_).add_modifier(Modifier::BOLD),
        ),
    ])
}

/// Rounded card with a HERO-ramp top border and the title set into the frame.
/// Paints over the edge cells of `area`; callers render content in the inset
/// interior first.
fn card_frame(buf: &mut Buffer, area: Rect, title: &str, side: Color, p: Palette) {
    if area.width < 4 || area.height < 2 {
        return;
    }
    let stops: Vec<(u8, u8, u8)> = p.hero.iter().map(|c| theme::rgb_of(*c)).collect();
    let mut top: Vec<char> = vec!['\u{256d}'];
    top.extend(format!(" {} ", title).chars());
    while (top.len() as u16) < area.width - 1 {
        top.push('\u{2500}');
    }
    top.truncate(area.width as usize - 1);
    top.push('\u{256e}');
    for (i, ch) in top.iter().enumerate() {
        let (r, g, b) = theme::ramp(&stops, area.width, i as u16);
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(area.x + i as u16, area.y))
        {
            cell.set_char(*ch).set_fg(Color::Rgb(r, g, b));
        }
    }
    for y in (area.y + 1)..(area.y + area.height - 1) {
        for x in [area.x, area.x + area.width - 1] {
            if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, y)) {
                cell.set_char('\u{2502}').set_fg(side);
            }
        }
    }
    let by = area.y + area.height - 1;
    for x in area.x..area.x + area.width {
        let ch = if x == area.x {
            '\u{2570}'
        } else if x == area.x + area.width - 1 {
            '\u{256f}'
        } else {
            '\u{2500}'
        };
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(x, by)) {
            cell.set_char(ch).set_fg(side);
        }
    }
}

fn render_preview_pane(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    // Two clear columns inside each border so the content never touches the
    // frame; the blank lead line below gives the title row headroom.
    let inner = area.inner(Margin::new(3, 1));

    let session = match app.selected_session() {
        Some(s) => s,
        None => {
            let paragraph =
                Paragraph::new("No session selected").style(Style::default().fg(p.faint));
            frame.render_widget(paragraph, inner);
            card_frame(frame.buffer_mut(), area, "preview", p.strong, p);
            return;
        }
    };

    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        session.name.as_str(),
        Style::default().fg(p.ink).add_modifier(Modifier::BOLD),
    )));

    // Labeled meta rows: label FAINT at the pane's left edge, value at a fixed
    // column so the block reads as a table even without rules between rows.
    let (state_value, state_color) = if session.is_locked {
        (
            match session.lock_pid {
                Some(pid) => format!("\u{25a0} live \u{b7} locked {}", pid),
                None => "\u{25a0} live \u{b7} locked".to_string(),
            },
            p.teal,
        )
    } else if session.archived {
        ("archived".to_string(), p.faint)
    } else {
        // Dormant borrows the dormant heat grey, never teal: teal is liveness.
        ("dormant".to_string(), p.comment)
    };
    let mut meta: Vec<(&str, String, Color)> = vec![
        ("created", session.created.clone().unwrap_or_else(|| "\u{2014}".into()), p.ink),
        ("modified", session.modified.clone().unwrap_or_else(|| "\u{2014}".into()), p.ink),
        ("state", state_value, state_color),
        ("repo", session.git_repo.clone().unwrap_or_else(|| "\u{2014}".into()), p.ink),
    ];
    if !session.tags.is_empty() {
        meta.push(("tags", session.tags.join(", "), p.mut_));
    }
    let cached_preview = app.preview_cache.get(&session.name);
    if let Some(preview) = cached_preview {
        meta.push((
            "objective",
            preview.objective.clone().unwrap_or_else(|| "\u{2014}".into()),
            p.ink,
        ));
        meta.push((
            "narrative",
            preview.last_discovery.clone().unwrap_or_else(|| "\u{2014}".into()),
            p.mut_,
        ));
    }
    const VALUE_COL: usize = 11;
    let value_width = (inner.width as usize).saturating_sub(VALUE_COL);
    for (label, value, color) in &meta {
        let pad = VALUE_COL.saturating_sub(label.len());
        lines.push(Line::from(vec![
            Span::styled(*label, Style::default().fg(p.faint)),
            Span::raw(" ".repeat(pad)),
            Span::styled(truncate_str(value, value_width), Style::default().fg(*color)),
        ]));
    }
    lines.push(Line::from(""));

    // Body sections from .cs/ files, once the worker has read them.
    match cached_preview {
        Some(preview) => {
            if !preview.discoveries.is_empty() {
                lines.push(section_header("Discoveries", p));
                for disc in &preview.discoveries {
                    let truncated = truncate_str(disc, (inner.width as usize).saturating_sub(4));
                    lines.push(Line::from(vec![
                        Span::styled("  - ", Style::default().fg(p.faint)),
                        Span::styled(truncated, Style::default().fg(p.mut_)),
                    ]));
                }
                lines.push(Line::from(""));
            }

            if !preview.memory_entries.is_empty() {
                lines.push(section_header("Memory", p));
                for entry in &preview.memory_entries {
                    let truncated = truncate_str(entry, (inner.width as usize).saturating_sub(4));
                    lines.push(Line::from(vec![
                        Span::raw("  "),
                        Span::styled(truncated, Style::default().fg(p.faint)),
                    ]));
                }
                lines.push(Line::from(""));
            }

            if !preview.contributors.is_empty() {
                lines.push(section_header("Contributors", p));
                for c in &preview.contributors {
                    let truncated = truncate_str(c, (inner.width as usize).saturating_sub(4));
                    lines.push(Line::from(vec![
                        Span::raw("  "),
                        Span::styled(truncated, Style::default().fg(p.faint)),
                    ]));
                }
            }

            if preview.discoveries.is_empty()
                && preview.memory_entries.is_empty()
                && preview.contributors.is_empty()
            {
                lines.push(Line::from(Span::styled(
                    "no additional metadata",
                    Style::default().fg(p.faint).add_modifier(Modifier::DIM),
                )));
            }
        }
        None => {
            // The worker holds this session and has not answered yet.
            lines.push(Line::from(Span::styled(
                "loading\u{2026}",
                Style::default().fg(p.faint).add_modifier(Modifier::DIM),
            )));
        }
    }

    let paragraph = Paragraph::new(lines).wrap(Wrap { trim: true });
    frame.render_widget(paragraph, inner);
    card_frame(frame.buffer_mut(), area, "preview", p.strong, p);
}

fn render_notes_pane(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    let focused = app.focus == Focus::Notes;
    let input_focused = focused && app.notes_focus == NotesFocus::Input;
    let list_focused = focused && app.notes_focus == NotesFocus::List;

    // Focus brightens the card's side/bottom border from soft to strong; the
    // top border always carries the HERO ramp regardless of focus.
    let side = if focused { p.strong } else { p.soft };
    let inner = area.inner(Margin::new(1, 1));
    // Input and list rows sit one clear column inside the frame on each side
    // (their own leading-space spans add the second); the separator rule keeps
    // full bleed to the border.
    let pad_h = |r: Rect| Rect {
        x: r.x + 1,
        width: r.width.saturating_sub(2),
        ..r
    };

    // Input block on top (grows with wrapped text, capped), a full-width
    // separator rule, then the task list. The input's height must be known
    // before the layout splits, so its lines are built first.
    let input_inner = inner.width.saturating_sub(4) as usize; // rect inset + pad column each side
    let input_lines: Vec<Line> = if app.notes_focus == NotesFocus::Editing {
        vec![Line::from(Span::styled(
            format!(" editing {} \u{b7} Enter saves \u{b7} Esc cancels", app.notes_selected + 1),
            Style::default().fg(p.faint).add_modifier(Modifier::DIM),
        ))]
    } else if input_focused {
        cursor_wrap_spans(
            app.queue_input.text(),
            app.queue_input.before_cursor().len(),
            input_inner,
            MAX_INPUT_ROWS,
            Style::default().fg(p.ink),
            Style::default().fg(p.amber),
        )
        .into_iter()
        .map(|mut spans| {
            let mut cells = vec![Span::raw(" ")];
            cells.append(&mut spans);
            Line::from(cells)
        })
        .collect()
    } else if app.queue_input.text().is_empty() {
        vec![Line::from(Span::styled(
            " Tab to add a task\u{2026}",
            Style::default().fg(p.faint).add_modifier(Modifier::DIM),
        ))]
    } else {
        wrap_cols_ranges(app.queue_input.text(), input_inner)
            .into_iter()
            .take(MAX_INPUT_ROWS)
            .map(|(s, e)| {
                Line::from(vec![
                    Span::raw(" "),
                    Span::styled(
                        app.queue_input.text()[s..e].to_string(),
                        Style::default().fg(p.ink),
                    ),
                ])
            })
            .collect()
    };
    let input_height = input_lines.len().max(1) as u16;

    let rows = Layout::vertical([
        Constraint::Length(1), // headroom under the title
        Constraint::Length(input_height),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .split(inner);

    frame.render_widget(Paragraph::new(input_lines), pad_h(rows[1]));

    // Separator between the input and the list, matching the panel border.
    let rule = "\u{2500}".repeat(rows[2].width as usize);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(rule, Style::default().fg(side)))),
        rows[2],
    );

    // Numbered list of queued tasks, each shown in full: long tasks wrap onto
    // continuation rows indented under the text column. The highlighted row
    // shows an amber marker; the row being edited becomes an italic text field
    // whose block cursor wraps with the text.
    let tasks = app
        .selected_session()
        .map(|s| crate::session::read_queue(&s.name))
        .unwrap_or_default();
    // While the drain is live, the first queued line is the task Claude is
    // working right now; it gets the teal working marker below.
    let drain_active = !tasks.is_empty()
        && app
            .selected_session()
            .map(|s| crate::session::queue_active(&s.name))
            .unwrap_or(false);

    let inner_cols = pad_h(rows[3]).width as usize;
    let list_lines: Vec<Line> = if tasks.is_empty() {
        vec![Line::from(Span::styled(
            " (no queued tasks)",
            Style::default().fg(p.faint).add_modifier(Modifier::DIM),
        ))]
    } else {
        tasks
            .iter()
            .enumerate()
            .flat_map(|(i, task)| {
                let editing = app.notes_focus == NotesFocus::Editing && i == app.notes_selected;
                let highlighted =
                    editing || (list_focused && i == app.notes_selected);
                let working = drain_active && i == 0;
                let (marker, marker_color) = if highlighted {
                    ("\u{25b8} ", p.amber)
                } else if working {
                    ("\u{25b6} ", p.teal)
                } else {
                    ("  ", p.faint)
                };
                let num_color = if working { p.teal } else { marker_color };
                let num = format!("{}. ", i + 1);
                // Columns available for the task text: left pad(1) + marker(2) +
                // number, plus a matching 1-column right margin so wrapped text
                // and the edit cursor stay off the border.
                let prefix_cols = 1 + 2 + num.chars().count();
                let avail = inner_cols.saturating_sub(prefix_cols + 1);
                let prefix = vec![
                    Span::raw(" "), // left padding
                    Span::styled(marker, Style::default().fg(marker_color)),
                    Span::styled(num, Style::default().fg(num_color)),
                ];
                let indent = " ".repeat(prefix_cols);
                let body: Vec<Vec<Span>> = if editing {
                    let italic = Style::default().fg(p.ink).add_modifier(Modifier::ITALIC);
                    cursor_wrap_spans(
                        app.queue_input.text(),
                        app.queue_input.before_cursor().len(),
                        avail,
                        MAX_INPUT_ROWS,
                        italic,
                        Style::default().fg(p.amber),
                    )
                } else {
                    let mut text_style = Style::default().fg(p.ink);
                    if highlighted {
                        text_style = text_style.add_modifier(Modifier::BOLD);
                    }
                    wrap_cols_ranges(task, avail)
                        .into_iter()
                        .map(|(s, e)| vec![Span::styled(task[s..e].to_string(), text_style)])
                        .collect()
                };
                body.into_iter()
                    .enumerate()
                    .map(|(row, mut spans)| {
                        let mut cells = if row == 0 {
                            prefix.clone()
                        } else {
                            vec![Span::raw(indent.clone())]
                        };
                        cells.append(&mut spans);
                        Line::from(cells)
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    };
    let list = Paragraph::new(list_lines);
    frame.render_widget(list, pad_h(rows[3]));

    card_frame(frame.buffer_mut(), area, "to-do", side, p);
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
            tags: Vec::new(),
            archived: false,
        }]
    }

    /// Two sessions — one locked, one not — for gutter-glyph assertions. Names
    /// sort "locked" before "recent" under Name/Asc, which keeps the fixture
    /// free of the time-section divider that Created/Modified sort injects.
    fn locked_and_recent_sessions() -> Vec<Session> {
        vec![
            Session {
                name: "locked".into(),
                is_adopted: false,
                created: Some("2026-01-01 10:00".into()),
                modified: Some("2026-02-20 14:00".into()),
                modified_ts: Some(std::time::SystemTime::now()),
                lock_pid: Some(123),
                is_locked: true,
                secrets_count: 0,
                queue_depth: 0,
                git_repo: None,
                tags: Vec::new(),
                archived: false,
            },
            Session {
                name: "recent".into(),
                is_adopted: false,
                created: Some("2026-01-01 10:00".into()),
                modified: Some("2026-02-20 14:00".into()),
                modified_ts: Some(std::time::SystemTime::now()),
                lock_pid: None,
                is_locked: false,
                secrets_count: 0,
                queue_depth: 0,
                git_repo: None,
                tags: Vec::new(),
                archived: false,
            },
        ]
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

    /// A session with a pre-populated preview cache, so the preview pane's
    /// labeled meta block renders fully without waiting on the background
    /// preview worker.
    fn preview_test_app() -> App {
        let mut sessions = one_session();
        sessions[0].name = "cs-tui-preview-meta-probe".into();
        sessions[0].git_repo = Some("hex/claude-sessions".into());
        sessions[0].is_locked = true;
        sessions[0].lock_pid = Some(4242);
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = true;
        app.preview_cache.insert(
            "cs-tui-preview-meta-probe".into(),
            crate::session::SessionPreview {
                objective: Some("redesign the picker".into()),
                last_discovery: Some("council: cut braille, group".into()),
                discoveries: Vec::new(),
                memory_entries: Vec::new(),
                contributors: Vec::new(),
            },
        );
        app
    }

    /// Like `preview_test_app`, but with the given tags on the session, for
    /// asserting the preview pane's tags meta row.
    fn preview_test_app_with_tags(tags: Vec<String>) -> App {
        let mut app = preview_test_app();
        app.sessions[0].tags = tags;
        app
    }

    /// Two sessions in "Today", one in "Older", default-sorted by Modified —
    /// the section-divider fixture for label/count and spacer-row assertions.
    fn sectioned_test_app() -> App {
        use std::time::{Duration, SystemTime};
        let mut today_one = one_session();
        today_one[0].name = "today-one".into();
        today_one[0].modified_ts = Some(SystemTime::now());
        let mut today_two = one_session();
        today_two[0].name = "today-two".into();
        today_two[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(3600));
        let mut older = one_session();
        older[0].name = "older-one".into();
        older[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(400 * 86400));
        let sessions = vec![
            today_one.into_iter().next().unwrap(),
            today_two.into_iter().next().unwrap(),
            older.into_iter().next().unwrap(),
        ];
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app
    }

    #[test]
    fn section_divider_shows_label_and_count() {
        // Fixture: sessions spanning two time sections while date-sorted
        // (reuse the existing section-label test fixture in this module).
        let mut app = sectioned_test_app();
        let text = render_wide(&mut app);
        assert!(
            text.contains("── Today \u{b7} 2 "),
            "divider must carry '── Today · 2 ':\n{text}"
        );
    }

    #[test]
    fn section_divider_fills_the_session_column() {
        use std::time::{Duration, SystemTime};
        let mut sessions = one_session();
        sessions[0].name = "recent-session".into();
        sessions[0].modified_ts = Some(SystemTime::now());
        let mut old = one_session();
        old[0].name = "legacy-session".into();
        old[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(400 * 86400));
        sessions.push(old.into_iter().next().unwrap());
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let out = render_at(&mut app, 140, 24);

        let today_row = out
            .lines()
            .find(|l| l.contains("Today"))
            .expect("a Today section divider should render");
        // The divider is now a long run of dashes filling the Session column,
        // not the old stubby "── Today ──" whose dash runs were length 2.
        let longest_dash_run = today_row
            .chars()
            .fold((0usize, 0usize), |(cur, max), c| {
                if c == '\u{2500}' {
                    (cur + 1, max.max(cur + 1))
                } else {
                    (0, max)
                }
            })
            .1;
        assert!(
            longest_dash_run >= 30,
            "section divider should fill the column with dashes (run={longest_dash_run}): {today_row:?}"
        );
        // The divider line is a pure rule — the session's date/age moved off it.
        // Scope the check to the table's own columns: at this width the table
        // sits beside the preview pane, and borderless the table's rows now
        // land on the same absolute terminal row as unrelated preview-pane
        // text (e.g. the "modified" meta row), which would otherwise
        // false-positive a "2026" match that has nothing to do with the divider.
        let table_width = app.table_area.width as usize;
        let today_table_slice: String = today_row.chars().take(table_width).collect();
        assert!(
            !today_table_slice.contains("2026"),
            "the divider line must carry no date/age: {today_table_slice:?}"
        );
        // ...and now sit on the session's own name line instead. Match the table
        // row by its "●" marker so we don't hit the preview pane's title, which
        // shares the same visual line in the side-by-side layout.
        let session_row = out
            .lines()
            .find(|l| l.contains("\u{25cf} recent-session"))
            .expect("the recent-session table row should render");
        assert!(
            session_row.contains("2026-01-01") && session_row.contains("now"),
            "date/age should sit on the session's own line, not the divider: {session_row:?}"
        );
    }

    #[test]
    fn section_divider_reaches_the_table_right_edge_past_meta_columns() {
        // The in-cell dash run (previous test) only ever fills the Session
        // column, because the Table clips each cell's Text to that column's
        // width. With a Queue meta column visible, the divider rule must
        // still reach past it to the table's own right edge.
        use std::time::{Duration, SystemTime};
        let mut recent = one_session();
        recent[0].name = "recent-session".into();
        recent[0].modified_ts = Some(SystemTime::now());
        recent[0].queue_depth = 2; // pulls the Queue meta column into view
        let mut old = one_session();
        old[0].name = "legacy-session".into();
        old[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(400 * 86400));
        let sessions = vec![recent.into_iter().next().unwrap(), old.into_iter().next().unwrap()];
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = false; // TableOnly: the table spans the full width
        let p = app.theme;

        let backend = TestBackend::new(100, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let cell_at = |x: u16, y: u16| buf.cell(ratatui::layout::Position::new(x, y)).unwrap();
        let row_text = |y: u16| -> String {
            (0..100u16).map(|x| cell_at(x, y).symbol()).collect()
        };

        let header_row = (0..24u16)
            .map(row_text)
            .find(|r| r.contains("QUEUE"))
            .expect("QUEUE column header should render when a session has a queued task");
        // Char count, not byte offset: the header's inline legend carries
        // multibyte glyphs before QUEUE, so bytes overshoot the column.
        let queue_byte = header_row.find("QUEUE").unwrap();
        let queue_x = header_row[..queue_byte].chars().count() as u16;

        let divider_y = (0..24u16)
            .find(|&y| row_text(y).contains("── Today \u{b7}"))
            .expect("a Today section divider should render") as u16;

        // Probe well inside the Queue column's span, past where the old
        // in-cell dash run was clipped.
        let probe_x = queue_x + 2;
        let cell = cell_at(probe_x, divider_y);
        assert_eq!(
            cell.symbol(),
            "\u{2500}",
            "divider rule should reach past the Age/Queue columns at x={probe_x}, row={:?}",
            row_text(divider_y)
        );
        assert_eq!(
            cell.fg, p.soft,
            "divider rule beyond the Session column should be painted SOFT"
        );
    }

    #[test]
    fn section_divider_paint_never_escapes_the_table_bottom() {
        // A later section whose row top lands on the table's last visible
        // line carries its divider one line below that top (spacer, then
        // divider) — the Table clips that divider line, but the direct
        // buffer paint must too, or the rule lands in the footer.
        //
        // Geometry at 100×12, TableOnly: masthead rows 0-1, content pane
        // y=2 height 9, footer row 11. Data walk starts at relative y=2;
        // the "Today" section-start row (height 2) puts four plain rows at
        // relative 4-7, so the "Older" section-start row (spacer+divider+
        // name, height 3) tops at relative y=8 — the last table line. Its
        // divider's relative y=9 == bottom, one row past the table.
        use std::time::{Duration, SystemTime};
        let mut sessions = Vec::new();
        for i in 0..5u64 {
            let mut s = one_session();
            s[0].name = format!("today-{i}");
            s[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(i * 60));
            sessions.push(s.into_iter().next().unwrap());
        }
        let mut old = one_session();
        old[0].name = "older-one".into();
        old[0].modified_ts = Some(SystemTime::now() - Duration::from_secs(400 * 86400));
        sessions.push(old.into_iter().next().unwrap());
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = false;
        let p = app.theme;

        let backend = TestBackend::new(100, 12);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let footer_y = 11u16;
        let stray: Vec<u16> = (0..100u16)
            .filter(|&x| {
                let cell = buf.cell(ratatui::layout::Position::new(x, footer_y)).unwrap();
                cell.symbol() == "\u{2500}" && cell.fg == p.soft
            })
            .collect();
        assert!(
            stray.is_empty(),
            "divider rule must not be painted into the footer (soft \u{2500} at x={stray:?}): {:?}",
            (0..100u16)
                .map(|x| buf.cell(ratatui::layout::Position::new(x, footer_y)).unwrap().symbol())
                .collect::<String>()
        );
    }

    #[test]
    fn portrait_terminal_stacks_list_details_and_notes() {
        // 80×50 reads as portrait, so the panes stack. At width 80 — below
        // PREVIEW_MIN_WIDTH — the side-by-side layout can't fire, so the to-do
        // card and the preview's "created" label appearing at all proves the
        // vertical split engaged. A probe name no other test seeds on disk keeps
        // the empty-queue assertion from racing the queue tests.
        let mut sessions = one_session();
        sessions[0].name = "cs-tui-stack-probe".into();
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let joined = render_at(&mut app, 80, 50);
        assert!(joined.contains("to-do"), "notes card title should render: {joined}");
        assert!(
            joined.contains('\u{256d}'),
            "card corners should render once the panes open: {joined}"
        );
        assert!(
            joined.contains("no queued tasks"),
            "empty queue placeholder should render: {joined}"
        );
        assert!(
            joined.contains("created"),
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
        assert!(joined.contains("to-do"), "to-do card title should render: {joined}");
        assert!(
            joined.contains('\u{256d}'),
            "card corners should render once the panes open: {joined}"
        );
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
            joined.contains("Enter add"),
            "footer should show the Notes-focused hint: {joined}"
        );
    }

    #[test]
    fn todo_card_side_border_brightens_when_notes_pane_focused() {
        let p = Palette::dark();

        // Renders at render_wide's dimensions, but returns the raw buffer
        // (not the joined string) so side-border cell fg can be inspected.
        let render_and_find_todo_side = |app: &mut App| -> (Color, Color) {
            let backend = TestBackend::new(140, 30);
            let mut terminal = Terminal::new(backend).unwrap();
            terminal.draw(|frame| render(app, frame)).unwrap();
            let buf = terminal.backend().buffer().clone();
            let mut coords = None;
            for y in 0..buf.area.height {
                let cells: Vec<String> = (0..buf.area.width)
                    .map(|x| {
                        buf.cell(ratatui::layout::Position::new(x, y))
                            .unwrap()
                            .symbol()
                            .to_string()
                    })
                    .collect();
                if cells.concat().contains("to-do") {
                    let left = cells.iter().position(|s| s == "\u{256d}").unwrap() as u16;
                    let right = cells.iter().rposition(|s| s == "\u{256e}").unwrap() as u16;
                    coords = Some((left, right, y + 1));
                    break;
                }
            }
            let (left_x, right_x, side_y) =
                coords.expect("to-do card top border should render");
            let left_fg = buf
                .cell(ratatui::layout::Position::new(left_x, side_y))
                .unwrap()
                .fg;
            let right_fg = buf
                .cell(ratatui::layout::Position::new(right_x, side_y))
                .unwrap()
                .fg;
            (left_fg, right_fg)
        };

        let mut app = App::new(one_session());
        app.theme = p;
        let (left, right) = render_and_find_todo_side(&mut app);
        assert_eq!(left, p.soft, "unfocused to-do card side border should be SOFT");
        assert_eq!(right, p.soft, "unfocused to-do card side border should be SOFT");

        app.focus = Focus::Notes;
        let (left, right) = render_and_find_todo_side(&mut app);
        assert_eq!(left, p.strong, "focused to-do card side border should brighten to STRONG");
        assert_eq!(right, p.strong, "focused to-do card side border should brighten to STRONG");
    }

    #[test]
    fn header_uses_age_and_created_is_date_only() {
        let rows = render_rows();
        let joined = rows.join("\n");
        assert!(joined.contains("AGE"), "header should label the column 'AGE'");
        assert!(joined.contains("CREATED"), "header keeps 'CREATED'");
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
        // "QUEUE" text in the buffer comes from the table column under test.
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
        assert!(joined.contains("QUEUE"), "QUEUE column header should render: {joined}");
        assert!(
            joined.contains("\u{25b0}\u{25b0}\u{25b1}\u{25b1} 3"),
            "queue cell should show the qbar meter and count: {joined}"
        );
    }

    #[test]
    fn todo_column_hidden_when_no_session_has_queued_tasks() {
        // render_rows() uses one_session() (queue_depth 0) at width 100 (no panel),
        // so "QUEUE" must not appear anywhere.
        let joined = render_rows().join("\n");
        assert!(
            !joined.contains("QUEUE"),
            "QUEUE column is hidden when no session has queued tasks: {joined}"
        );
    }

    fn notice() -> crate::session::UpdateNotice {
        crate::session::UpdateNotice {
            version: "2026.8.0".to_string(),
            notes: vec![
                ("2026.8.0".to_string(), "voice skill and queue fixes".to_string()),
                ("+".to_string(), "\u{2026} and 3 earlier versions".to_string()),
            ],
        }
    }

    #[test]
    fn update_badge_renders_only_when_a_newer_version_is_cached() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        let joined = render_wide(&mut app);
        assert!(!joined.contains("C:changelog"), "no badge without a notice");

        app.update_notice = Some(notice());
        let joined = render_wide(&mut app);
        assert!(
            joined.contains("v2026.8.0 available") && joined.contains("C:changelog"),
            "badge should name the version and the key: {joined}"
        );
    }

    #[test]
    fn changelog_overlay_opens_on_key_and_closes_on_esc() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.update_notice = Some(notice());

        // 'C' opens the overlay; the notes and the update hint render.
        app.handle_key(KeyEvent::from(KeyCode::Char('C')));
        assert_eq!(app.mode, Mode::Changelog);
        let joined = render_wide(&mut app);
        assert!(
            joined.contains("voice skill and queue fixes"),
            "note summary should render: {joined}"
        );
        assert!(joined.contains("and 3 earlier versions"), "overflow line renders dim");
        assert!(joined.contains("cs -update"), "update instruction renders");

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn changelog_key_is_inert_without_a_notice() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.handle_key(KeyEvent::from(KeyCode::Char('C')));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn legend_overlay_opens_on_question_mark_and_explains_the_gutter() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();

        let joined = render_wide(&mut app);
        assert!(joined.contains("?"), "footer should advertise the legend key");
        assert!(!joined.contains("recency dot"), "legend hidden until asked for");

        app.handle_key(KeyEvent::from(KeyCode::Char('?')));
        assert_eq!(app.mode, Mode::Legend);
        let joined = render_wide(&mut app);
        for label in ["recency dot", "locked", "marked with Space", "stored secrets", "archived", "in place of the recency dot"] {
            assert!(joined.contains(label), "legend should explain {label}: {joined}");
        }

        app.handle_key(KeyEvent::from(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
    }

    #[test]
    fn draining_queue_marks_only_the_first_task_as_working() {
        use crate::session::test_root;
        let tmp = std::env::temp_dir().join(format!("cs-ui-working-{}", std::process::id()));
        let name = "solo-working";
        let local = tmp.join(name).join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        std::fs::write(local.join("queue"), "first queued task\nsecond queued task\n").unwrap();
        let _guard = test_root::scoped(tmp.clone());

        let mut sessions = one_session();
        sessions[0].name = name.to_string();
        sessions[0].queue_depth = 2;
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = true;

        // Idle queue: no working marker anywhere.
        let backend = TestBackend::new(90, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let joined: String = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect::<String>() + "\n")
            .collect();
        assert!(
            !joined.contains('\u{25b6}'),
            "no working marker while the queue is idle: {joined}"
        );

        // Draining: the first task's row carries the marker, the second does not.
        std::fs::write(local.join("queue.state"), "draining\n").unwrap();
        let backend = TestBackend::new(90, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();
        let first_row = rows.iter().find(|r| r.contains("first queued task")).unwrap();
        assert!(
            first_row.contains('\u{25b6}'),
            "the in-flight task should carry the working marker: {first_row}"
        );
        let second_row = rows.iter().find(|r| r.contains("second queued task")).unwrap();
        assert!(
            !second_row.contains('\u{25b6}'),
            "waiting tasks must not carry the marker: {second_row}"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn preview_pane_content_is_padded_from_the_border() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(90, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        // Horizontal padding: the "created" meta label sits one clear column
        // inside the card's left border instead of touching it.
        let created_row = rows
            .iter()
            .find(|r| r.contains("created"))
            .expect("preview meta rows should render");
        let border_x = created_row
            .chars()
            .position(|c| c == '\u{2502}')
            .expect("the meta row should start at the card border");
        let after_border: String = created_row.chars().skip(border_x + 1).take(2).collect();
        assert_eq!(
            after_border, "  ",
            "content should sit two clear columns inside the left border: {created_row:?}"
        );

        // Vertical headroom: the first row under the card's title border is
        // blank, so the session name does not press against the frame.
        let title_y = rows
            .iter()
            .position(|r| r.contains("preview"))
            .expect("preview card title should render");
        let headroom: String = rows[title_y + 1]
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect();
        assert!(
            headroom.is_empty(),
            "row under the preview title should be blank, got: {:?}",
            rows[title_y + 1]
        );
    }

    #[test]
    fn wide_header_carries_the_symbol_legend_between_session_and_created() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(200, 50);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        let header = rows
            .iter()
            .find(|r| r.contains("SESSION"))
            .expect("table header should render");
        for label in ["activity", "marked", "archived"] {
            assert!(header.contains(label), "header legend should name {label}: {header:?}");
        }
        assert!(
            header.contains("\u{25a0} live"),
            "the lock square should be keyed as live: {header:?}"
        );
        assert!(
            !header.contains("\u{2500} archived"),
            "archived must not advertise a dash glyph rows never render: {header:?}"
        );
        let s = header.find("SESSION").unwrap();
        let l = header.find("activity").unwrap();
        let c = header.find("CREATED").unwrap();
        assert!(
            s < l && l < c,
            "the legend should sit between SESSION and CREATED: {header:?}"
        );
        // Left-aligned: the legend starts a fixed gap after the SESSION
        // label instead of being pushed toward CREATED.
        let s_col = header[..s].chars().count();
        let l_col = header[..l].chars().count();
        assert!(
            l_col - s_col <= "SESSION".len() + 8,
            "the legend should hug SESSION (label col {s_col}, legend col {l_col}): {header:?}"
        );
    }

    #[test]
    fn preview_state_uses_the_lock_square_and_grey_dormant() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;
        let p = app.theme;

        let backend = TestBackend::new(90, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        // An unlocked session's state reads "dormant" in the dormant grey,
        // never teal — teal is reserved for liveness.
        let y = rows
            .iter()
            .position(|r| r.contains("dormant"))
            .expect("preview state row should render") as u16;
        let x = rows[y as usize]
            .chars()
            .collect::<Vec<_>>()
            .windows(7)
            .position(|w| w.iter().collect::<String>() == "dormant")
            .unwrap() as u16;
        let fg = buf[(x, y)].fg;
        assert_ne!(fg, p.teal, "dormant must not borrow the liveness teal");
        assert_eq!(fg, p.comment, "dormant should match the dormant heat grey");
    }

    #[test]
    fn narrow_header_omits_the_inline_legend() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(60, 50);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        let header = rows
            .iter()
            .find(|r| r.contains("SESSION"))
            .expect("table header should render");
        assert!(
            !header.contains("activity"),
            "a narrow header has no room for the legend: {header:?}"
        );
    }

    #[test]
    fn todo_pane_content_is_padded_from_the_border() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(90, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        // Horizontal padding: the input placeholder sits two clear columns
        // inside the card's left border, matching the preview pane.
        let input_row = rows
            .iter()
            .find(|r| r.contains("Tab to add"))
            .expect("to-do input placeholder should render");
        let border_x = input_row
            .chars()
            .position(|c| c == '\u{2502}')
            .expect("the input row should start at the card border");
        let after_border: String = input_row.chars().skip(border_x + 1).take(2).collect();
        assert_eq!(
            after_border, "  ",
            "to-do content should sit two clear columns inside the left border: {input_row:?}"
        );

        // Vertical headroom: the row under the to-do title is blank.
        let title_y = rows
            .iter()
            .position(|r| r.contains("to-do"))
            .expect("to-do card title should render");
        let headroom: String = rows[title_y + 1]
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect();
        assert!(
            headroom.is_empty(),
            "row under the to-do title should be blank, got: {:?}",
            rows[title_y + 1]
        );
    }

    #[test]
    fn stacked_list_is_shorter_than_the_preview_pane() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(80, 50);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        let y_preview = rows
            .iter()
            .position(|r| r.contains("preview"))
            .expect("preview card should render in stacked layout");
        let y_todo = rows
            .iter()
            .position(|r| r.contains("to-do"))
            .expect("to-do card should render in stacked layout");
        let list_rows = y_preview.saturating_sub(2); // content starts under the 2-row masthead
        let preview_rows = y_todo - y_preview;
        assert!(
            list_rows < preview_rows,
            "the listing ({list_rows} rows) should give up height to the preview pane ({preview_rows} rows)"
        );
    }

    #[test]
    fn side_by_side_gives_the_panes_more_width_than_the_table() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.show_preview = true;

        let backend = TestBackend::new(200, 50);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        let title_row = rows
            .iter()
            .find(|r| r.contains("preview"))
            .expect("preview card should render in side-by-side layout");
        let byte = title_row.find("preview").unwrap();
        let col = title_row[..byte].chars().count();
        assert!(
            col < 100,
            "the panes column should start left of the midline (preview title at col {col})"
        );
    }

    #[test]
    fn long_task_wraps_to_show_its_full_text() {
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
        // The task wraps: its head renders on one row, its tail on a later row,
        // and no ellipsis truncates it.
        let head_y = rows
            .iter()
            .position(|r| r.contains("Refactor"))
            .expect("the long task's first row should render");
        assert!(
            !rows[head_y].contains('\u{2026}'),
            "a wrapped task row must not carry a truncation ellipsis: {}",
            rows[head_y]
        );
        let tail_y = rows
            .iter()
            .position(|r| r.contains("window"))
            .expect("the task's tail must render somewhere (full text shown)");
        assert!(
            tail_y > head_y,
            "the tail continues on a later row (wrap), head at {head_y}, tail at {tail_y}"
        );
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn top_input_wraps_overflowing_text_and_keeps_cursor_visible() {
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
        // The input wraps instead of windowing: the block cursor is on screen,
        // the tail nearest the cursor is shown, AND the head is still visible
        // on an earlier wrapped row.
        assert!(joined.contains('\u{2588}'), "block cursor must be visible");
        assert!(joined.contains("zzz"), "the tail nearest the cursor is shown");
        assert!(
            joined.contains("the quick brown"),
            "the head stays visible on a wrapped row instead of scrolling off"
        );
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
        // 80×22 is one row below STACK_MIN_HEIGHT and nowhere near wide
        // enough for side-by-side.
        assert_eq!(
            choose_layout(Rect::new(0, 0, 80, 22), true),
            PaneLayout::TableOnly
        );
    }

    #[test]
    fn stacked_layout_floor_accounts_for_masthead_and_footer_rows() {
        // choose_layout sees the content pane after the 2-row masthead and
        // 1-row footer are already carved off the terminal — not the raw
        // terminal height. STACK_MIN_HEIGHT is sized against that content
        // pane, so the terminal-height floor for entering Stacked layout is
        // 3 rows higher than STACK_MIN_HEIGHT itself: 26 total rows.
        let has_card_corner = |text: &str| text.contains('\u{256d}');

        let probe_session = |name: &str| {
            let mut s = one_session();
            s[0].name = name.into();
            s
        };

        let mut app = App::new(probe_session("cs-tui-floor-probe-26"));
        app.theme = Palette::dark();
        let stacked = render_at(&mut app, 80, 26);
        assert!(
            has_card_corner(&stacked),
            "26 terminal rows should clear the stacked-layout floor: {stacked}"
        );

        let mut app = App::new(probe_session("cs-tui-floor-probe-25"));
        app.theme = Palette::dark();
        let not_stacked = render_at(&mut app, 80, 25);
        assert!(
            !has_card_corner(&not_stacked),
            "25 terminal rows should stay below the stacked-layout floor: {not_stacked}"
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

    #[test]
    fn masthead_shows_brand_counts_and_sort() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        let text = render_wide(&mut app);
        assert!(text.contains("cs-tui"), "masthead brand missing:\n{text}");
        assert!(text.contains("sessions"), "session count missing:\n{text}");
        assert!(text.contains("live"), "live count missing:\n{text}");
        assert!(text.contains("sorted by"), "sort readout missing:\n{text}");
    }

    #[test]
    fn masthead_count_uses_all_sessions_not_the_filtered_set() {
        // A narrowing search should not shrink the masthead's session count —
        // it reads app.sessions (the full roster), not app.filtered.
        let mut sessions = one_session();
        for name in ["beta-session", "gamma-session"] {
            sessions.push(Session {
                name: name.into(),
                is_adopted: false,
                created: Some("2026-01-01 10:00".into()),
                modified: Some("2026-02-20 14:00".into()),
                modified_ts: None,
                lock_pid: None,
                is_locked: false,
                secrets_count: 0,
                queue_depth: 0,
                git_repo: None,
                tags: Vec::new(),
                archived: false,
            });
        }
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.search_input.set("alpha");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1, "search should narrow the visible rows");
        assert_eq!(app.sessions.len(), 3);
        let text = render_wide(&mut app);
        assert!(
            text.contains("3 sessions"),
            "masthead should show the all-sessions count, not the filtered count: {text}"
        );
    }

    #[test]
    fn masthead_rule_spans_width_with_hero_ramp() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        // Render into a TestBackend and inspect row 1 directly.
        let backend = TestBackend::new(80, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();
        let first = buf.cell(ratatui::layout::Position::new(0, 1)).unwrap();
        let last = buf.cell(ratatui::layout::Position::new(79, 1)).unwrap();
        assert_eq!(first.symbol(), "\u{2501}");
        assert_eq!(last.symbol(), "\u{2501}");
        assert_ne!(first.fg, last.fg, "rule must be a ramp, not one color");
    }

    #[test]
    fn footer_styles_keys_and_right_aligns_version() {
        let _env = VERSION_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("CS_VERSION", "9.9.9");
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        let text = render_wide(&mut app);
        std::env::remove_var("CS_VERSION");
        assert!(text.contains("q quit"), "key hints missing:\n{text}");
        assert!(text.contains("9.9.9"), "version missing from footer:\n{text}");
        // 140 cols is wide enough for the full hint line plus the version
        // with room to spare, so the version should sit flush against the
        // row's right edge, not just somewhere in the row.
        let footer_row = text.lines().last().unwrap();
        assert!(
            footer_row.ends_with("v9.9.9"),
            "version should be right-aligned to the footer's last column: {footer_row:?}"
        );
        assert!(
            footer_row.contains("1-6 sort"),
            "full hint line should render intact at 140 cols: {footer_row:?}"
        );
    }

    #[test]
    fn qbar_fill_levels() {
        assert_eq!(qbar(0), "\u{25b1}\u{25b1}\u{25b1}\u{25b1}");
        assert_eq!(qbar(1), "\u{25b0}\u{25b1}\u{25b1}\u{25b1}");
        assert_eq!(qbar(3), "\u{25b0}\u{25b0}\u{25b1}\u{25b1}");
        assert_eq!(qbar(5), "\u{25b0}\u{25b0}\u{25b0}\u{25b1}");
        assert_eq!(qbar(9), "\u{25b0}\u{25b0}\u{25b0}\u{25b0}");
    }

    #[test]
    fn queue_digit_uses_mut_not_the_bar_color() {
        // The queue-depth number is a count, not the meter itself — it should
        // read as MUT text beside the depth-colored ▰▱ bar, not ride the same
        // accent color the bar uses.
        let mut sessions = one_session();
        sessions[0].name = "queue-probe".into();
        sessions[0].queue_depth = 5; // > 3 => bar color is RUST
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = false;
        let p = app.theme;
        let backend = TestBackend::new(100, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let row_text = |y: u16| -> String {
            (0..100u16)
                .map(|x| buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol())
                .collect()
        };
        let session_y = (0..24u16)
            .find(|&y| row_text(y).contains("queue-probe"))
            .expect("the session row should render");
        let bar_x = (0..100u16)
            .find(|&x| {
                buf.cell(ratatui::layout::Position::new(x, session_y)).unwrap().symbol() == "\u{25b0}"
            })
            .expect("the queue bar should render on the session's row");
        let digit_x = (0..100u16)
            .find(|&x| buf.cell(ratatui::layout::Position::new(x, session_y)).unwrap().symbol() == "5")
            .expect("the queue depth digit should render on the session's row");
        let bar_fg = buf.cell(ratatui::layout::Position::new(bar_x, session_y)).unwrap().fg;
        let digit_fg = buf.cell(ratatui::layout::Position::new(digit_x, session_y)).unwrap().fg;
        assert_eq!(bar_fg, p.rust, "bar should stay depth-colored (depth 5 > 3 => RUST)");
        assert_eq!(digit_fg, p.mut_, "digit should use MUT, not ride the bar color");
    }

    #[test]
    fn tag_only_search_query_does_not_dim_matches() {
        // A tag-only query like "#api" leaves no fuzzy remainder, so
        // fuzzy_indices stays empty even though the tag filter already
        // narrowed the rows. Dimming must key on the fuzzy remainder, not on
        // whether a fuzzy match was recorded, or every row renders grey
        // while search is focused.
        let mut sessions = one_session();
        sessions[0].name = "svc-api".into();
        sessions[0].tags = vec!["api".into()];
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.show_preview = false;
        let p = app.theme;
        app.mode = Mode::Search;
        app.search_input.set("#api");
        app.apply_filter_and_sort();
        assert_eq!(app.filtered.len(), 1, "the tag filter should keep the matching session");

        let backend = TestBackend::new(100, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let row_text = |y: u16| -> String {
            (0..100u16)
                .map(|x| buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol())
                .collect()
        };
        let session_y = (0..24u16)
            .find(|&y| row_text(y).contains("svc-api"))
            .expect("the session row should render");
        let name_x = (0..100u16)
            .find(|&x| buf.cell(ratatui::layout::Position::new(x, session_y)).unwrap().symbol() == "s")
            .expect("the session name should render");
        let name_fg = buf.cell(ratatui::layout::Position::new(name_x, session_y)).unwrap().fg;
        assert_ne!(
            name_fg, p.comment,
            "a tag-only query should not dim rows that already passed the tag filter"
        );
    }

    #[test]
    fn search_bar_hints_tag_syntax_when_input_is_empty() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.mode = Mode::Search;
        let text = render_wide(&mut app);
        assert!(
            text.contains("#tag filters"),
            "empty search input should hint the #tag syntax: {text}"
        );
    }

    #[test]
    fn search_bar_hides_tag_hint_once_typing_starts() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.mode = Mode::Search;
        app.search_input.set("alpha");
        let text = render_wide(&mut app);
        assert!(
            !text.contains("#tag filters"),
            "a real query should not be crowded by the hint: {text}"
        );
    }

    #[test]
    fn table_is_borderless_and_zebra_free() {
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        let backend = TestBackend::new(80, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();
        let mut corners = 0;
        for y in 0..24u16 {
            for x in 0..80u16 {
                let sym = buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol();
                // Table corners are gone; card corners (Task 5) render only when
                // the preview pane is open, which test_app() does not open.
                if sym == "\u{256d}" || sym == "\u{2570}" {
                    corners += 1;
                }
            }
        }
        assert_eq!(corners, 0, "table must render without a bordered Block");

        // "zebra free" is a claim about row backgrounds, not just borders —
        // assert it directly: two adjacent, unselected, non-flashed rows
        // must share the same background instead of alternating.
        let mut sessions = vec![one_session().into_iter().next().unwrap()];
        sessions[0].name = "alpha".into();
        let mut bravo = one_session();
        bravo[0].name = "bravo".into();
        let mut charlie = one_session();
        charlie[0].name = "charlie".into();
        sessions.push(bravo.into_iter().next().unwrap());
        sessions.push(charlie.into_iter().next().unwrap());
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        app.sort_col = SortColumn::Name;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        app.table_state.select(Some(0)); // leaves "bravo" and "charlie" unselected
        let backend = TestBackend::new(80, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();
        let row_text = |y: u16| -> String {
            (0..80u16)
                .map(|x| buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol())
                .collect()
        };
        let bravo_y = (0..24u16)
            .find(|&y| row_text(y).contains("bravo"))
            .expect("bravo row should render");
        let charlie_y = (0..24u16)
            .find(|&y| row_text(y).contains("charlie"))
            .expect("charlie row should render");
        let probe_x = app.table_area.x + SELECT_WIDTH;
        let bravo_bg = buf.cell(ratatui::layout::Position::new(probe_x, bravo_y)).unwrap().bg;
        let charlie_bg = buf.cell(ratatui::layout::Position::new(probe_x, charlie_y)).unwrap().bg;
        assert_eq!(
            bravo_bg, charlie_bg,
            "adjacent unselected rows must share the same background, not alternate"
        );
    }

    #[test]
    fn selected_row_gets_wash_and_locked_row_gets_square() {
        let mut app = App::new(locked_and_recent_sessions());
        app.theme = Palette::dark();
        // Sort by Name so the fixture's two sessions render as plain rows —
        // Created/Modified sort (the default) would inject a time-section
        // divider above row 0 and complicate the gutter-x math below.
        app.sort_col = SortColumn::Name;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        // Ensure a deterministic selection on the first row.
        app.table_state.select(Some(0));
        let backend = TestBackend::new(80, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();
        let p = app.theme;
        // Find the selected row by scanning for a cell whose bg == p.wash;
        // the wash must exist somewhere in the table region.
        let mut wash_found = false;
        let mut dot_found = false;
        for y in 0..24u16 {
            for x in 0..80u16 {
                let cell = buf.cell(ratatui::layout::Position::new(x, y)).unwrap();
                if cell.bg == p.wash {
                    wash_found = true;
                }
                if cell.symbol() == "\u{25cf}" || cell.symbol() == "\u{25a0}" {
                    dot_found = true;
                }
            }
        }
        assert!(wash_found, "selected row must carry the wash background");
        assert!(dot_found, "gutter must carry a status dot or locked square");

        // Strengthen: the fixture offers a locked and an unlocked session, so
        // assert the exact gutter glyph on each row at the exact gutter x.
        let rows: Vec<String> = (0..24u16)
            .map(|y| {
                (0..80u16)
                    .map(|x| buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol())
                    .collect::<String>()
            })
            .collect();
        // Exclude the header row: its inline legend also says "recent"/"live".
        let locked_y = rows
            .iter()
            .position(|r| r.contains("locked") && !r.contains("SESSION"))
            .expect("the locked session row should render") as u16;
        let recent_y = rows
            .iter()
            .position(|r| r.contains("recent") && !r.contains("SESSION"))
            .expect("the recent session row should render") as u16;
        let gutter_x = app.table_area.x + SELECT_WIDTH;
        let locked_gutter = buf
            .cell(ratatui::layout::Position::new(gutter_x, locked_y))
            .unwrap()
            .symbol();
        let recent_gutter = buf
            .cell(ratatui::layout::Position::new(gutter_x, recent_y))
            .unwrap()
            .symbol();
        assert_eq!(locked_gutter, "\u{25a0}", "locked row shows the locked square at the gutter x");
        // Live = teal everywhere: the square matches the masthead live count,
        // the preview state line, and the working-task marker. While the
        // animation heartbeat runs it may sit on the lightened blink phase.
        let locked_fg = buf
            .cell(ratatui::layout::Position::new(gutter_x, locked_y))
            .unwrap()
            .fg;
        let light_teal = Color::Rgb(139, 231, 219); // dark-theme teal lifted 45% toward white
        assert!(
            locked_fg == p.teal || locked_fg == light_teal,
            "the lock square carries a liveness teal phase, got {locked_fg:?}"
        );
        assert_eq!(recent_gutter, "\u{25cf}", "unlocked row shows the recency dot at the gutter x");
    }

    #[test]
    fn lock_square_blinks_between_teal_phases_only_while_animating() {
        let p = Palette::dark();
        // First half of the 2.4s period: base teal.
        assert_eq!(lock_square_color(p, true, 0), p.teal);
        assert_eq!(lock_square_color(p, true, 1100), p.teal);
        // Second half: the lightened phase (dark teal 45,212,191 lifted 45%
        // toward white — known-good literal, not recomputed).
        assert_eq!(lock_square_color(p, true, 1300), Color::Rgb(139, 231, 219));
        // Idle (heartbeat paused): steady teal in any phase.
        assert_eq!(lock_square_color(p, false, 1300), p.teal);
    }

    #[test]
    fn selected_row_rail_bar_uses_a_rail_stop_color() {
        // The selection accent bar is recolored post-render by sampling the
        // 3-stop rail gradient at a time-driven phase, so the exact color
        // varies frame to frame — but ramp() lands exactly on a stop at each
        // of the 3 phase indices (0/1/2), so the bar's fg must always be a
        // member of the rail set, never an in-between blend or an unrelated
        // color.
        let mut app = App::new(locked_and_recent_sessions());
        app.theme = Palette::dark();
        app.sort_col = SortColumn::Name;
        app.sort_dir = SortDirection::Asc;
        app.apply_filter_and_sort();
        app.table_state.select(Some(0));
        let p = app.theme;
        let backend = TestBackend::new(80, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let bar_fg = (0..24u16)
            .find_map(|y| {
                let cell = buf.cell(ratatui::layout::Position::new(app.table_area.x, y))?;
                (cell.symbol() == SELECT_BAR).then_some(cell.fg)
            })
            .expect("selected row should render the rail accent bar glyph");
        assert!(
            p.rail.contains(&bar_fg),
            "rail bar color {bar_fg:?} should be one of the 3 rail stops {:?}",
            p.rail
        );
    }

    #[test]
    fn secrets_count_uses_ink_not_recency_color() {
        // The Secrets column's digit is a count, not a metadata timestamp —
        // it should read as primary INK, not ride the recency-driven meta
        // color the Created column uses. Age the session so recency_color
        // diverges from ink, or the assertion couldn't tell the two apart.
        use std::time::{Duration, SystemTime};
        let ts = SystemTime::now() - Duration::from_secs(3 * 86400);
        let mut sessions = one_session();
        sessions[0].name = "secrets-probe".into();
        sessions[0].secrets_count = 9;
        sessions[0].modified_ts = Some(ts);
        let mut app = App::new(sessions);
        app.theme = Palette::dark();
        let p = app.theme;
        assert_ne!(
            p.recency_color(Some(ts)),
            p.ink,
            "fixture sanity: recency and ink must differ at this age for the assertion to discriminate"
        );

        let backend = TestBackend::new(100, 24);
        let mut term = Terminal::new(backend).unwrap();
        term.draw(|f| render(&mut app, f)).unwrap();
        let buf = term.backend().buffer();

        let row_text = |y: u16| -> String {
            (0..100u16)
                .map(|x| buf.cell(ratatui::layout::Position::new(x, y)).unwrap().symbol())
                .collect()
        };
        let session_y = (0..24u16)
            .find(|&y| row_text(y).contains("secrets-probe"))
            .expect("the session row should render");
        let secrets_x = (0..100u16)
            .find(|&x| {
                buf.cell(ratatui::layout::Position::new(x, session_y))
                    .unwrap()
                    .symbol()
                    == "9"
            })
            .expect("the secrets count should render on the session's row");
        let cell = buf.cell(ratatui::layout::Position::new(secrets_x, session_y)).unwrap();
        assert_eq!(
            cell.fg, p.ink,
            "secrets count should use INK, not the recency-driven meta color"
        );
    }

    #[test]
    fn card_frame_top_border_carries_title_and_ramp() {
        let p = Palette::light();
        let backend = ratatui::backend::TestBackend::new(40, 8);
        let mut term = ratatui::Terminal::new(backend).unwrap();
        term.draw(|f| {
            let area = ratatui::layout::Rect::new(0, 0, 40, 8);
            card_frame(f.buffer_mut(), area, "preview", p.strong, p);
        })
        .unwrap();
        let buf = term.backend().buffer();
        let cell = |x: u16, y: u16| buf.cell(ratatui::layout::Position::new(x, y)).unwrap();
        assert_eq!(cell(0, 0).symbol(), "\u{256d}");
        assert_eq!(cell(39, 0).symbol(), "\u{256e}");
        assert_eq!(cell(0, 7).symbol(), "\u{2570}");
        assert_eq!(cell(39, 7).symbol(), "\u{256f}");
        // title chars sit in the top border starting at x=1: " preview "
        assert_eq!(cell(2, 0).symbol(), "p");
        // ramp: fg differs across the top row
        assert_ne!(cell(1, 0).fg, cell(38, 0).fg);
    }

    #[test]
    fn preview_pane_shows_labeled_meta() {
        let mut app = preview_test_app();
        let text = render_wide(&mut app);
        for label in ["created", "modified", "state", "repo", "objective"] {
            assert!(text.contains(label), "missing meta label {label}:\n{text}");
        }
    }

    #[test]
    fn preview_shows_tags_row_when_tagged() {
        let mut app = preview_test_app_with_tags(vec!["api".into(), "infra".into()]);
        let text = render_wide(&mut app);
        assert!(text.contains("tags"), "tags label missing:\n{text}");
        assert!(text.contains("api, infra"), "joined tag values missing:\n{text}");
    }

    #[test]
    fn preview_omits_tags_row_when_untagged() {
        let mut app = preview_test_app();
        let text = render_wide(&mut app);
        assert!(!text.contains("\ntags"), "tags row must be absent for untagged sessions:\n{text}");
    }

    #[test]
    fn footer_version_never_overwrites_hints_at_80_cols() {
        // At 80 cols the full hint line doesn't fit even without a version —
        // the bug was that the version Paragraph painted over whatever hint
        // text landed at the row's right edge instead of that space being
        // reserved for it. With the fix, the hints Paragraph is clipped to
        // leave a gap (3 cols) plus the version's own width before it's
        // drawn, so the two can never share a cell.
        let _env = VERSION_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("CS_VERSION", "9.9.9");
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        let text = render_at(&mut app, 80, 24);
        std::env::remove_var("CS_VERSION");
        let footer_row = text.lines().last().unwrap();
        assert_eq!(footer_row.chars().count(), 80);

        let version_width = 6; // "v9.9.9"
        let gap_start = 80 - version_width - 3; // 71
        let gap_end = 80 - version_width; // 74
        let hints_part = &footer_row[..gap_start];
        let gap_part = &footer_row[gap_start..gap_end];
        let version_part = &footer_row[gap_end..];

        assert!(
            hints_part.contains("q quit"),
            "key hints should still render: {footer_row:?}"
        );
        assert!(
            !hints_part.contains("9.9.9"),
            "version must not bleed into the hints region: {footer_row:?}"
        );
        assert_eq!(
            gap_part, "   ",
            "the reserved gap between hints and version must be blank, not clipped hint text: {footer_row:?}"
        );
        assert_eq!(
            version_part, "v9.9.9",
            "version should be painted whole in its own reserved region: {footer_row:?}"
        );
    }

    #[test]
    fn notes_editing_footer_hints_have_uniform_spacing() {
        // The Notes-focus hint strings use 3-space separators internally,
        // which used to leave a stray leading space on every part after the
        // first once split on 2-space boundaries (e.g. "editing" then
        // " Enter:save", rendering as a 4-space gap). Parts are trimmed
        // before rejoining so every gap is the same 3 spaces.
        let mut app = App::new(one_session());
        app.theme = Palette::dark();
        app.focus = Focus::Notes;
        app.notes_focus = NotesFocus::Editing;
        let text = render_wide(&mut app);
        let footer_row = text.lines().last().unwrap();
        assert!(
            footer_row.contains("editing   Enter save   Esc cancel"),
            "hint parts should be joined by a uniform 3-space gap: {footer_row:?}"
        );
    }

    fn sessions_with_one_archived() -> Vec<Session> {
        let mut v = locked_and_recent_sessions();
        v.push(Session {
            name: "shelved".into(),
            is_adopted: false,
            created: Some("2026-01-01 10:00".into()),
            modified: Some("2026-02-20 14:00".into()),
            modified_ts: Some(std::time::SystemTime::now()),
            lock_pid: None,
            is_locked: false,
            secrets_count: 0,
            queue_depth: 0,
            git_repo: None,
            tags: Vec::new(),
            archived: true,
        });
        v
    }

    /// Render the given app and return (buffer, rows-as-strings). 115 cols —
    /// wide enough that the Normal-mode footer hint (with its "k label"
    /// expansion and 3-space gaps) doesn't clip, but still short of
    /// PREVIEW_MIN_WIDTH (120) so the layout stays table-only.
    /// Serializes every test that sets, removes, or asserts on the absence of
    /// the process-global CS_VERSION env var. Cargo runs tests on parallel
    /// threads, so an unguarded set_var races every concurrent footer render.
    static VERSION_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn render_app(app: &mut App) -> (ratatui::buffer::Buffer, Vec<String>) {
        let backend = TestBackend::new(115, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .filter_map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()))
                    .collect::<String>()
            })
            .collect();
        (buf, rows)
    }

    #[test]
    fn masthead_counts_archived_when_present() {
        let mut app = App::new(sessions_with_one_archived());
        app.theme = Palette::light();
        let (_, rows) = render_app(&mut app);
        assert!(rows[0].contains("1 archived"), "masthead row: {}", rows[0]);

        let mut app = App::new(locked_and_recent_sessions());
        app.theme = Palette::light();
        let (_, rows) = render_app(&mut app);
        assert!(!rows[0].contains("archived"), "no archived count when none exist");
    }

    #[test]
    fn archived_row_hidden_until_toggled_then_dimmed() {
        let mut app = App::new(sessions_with_one_archived());
        app.theme = Palette::light();
        let (_, rows) = render_app(&mut app);
        assert!(!rows.iter().any(|r| r.contains("shelved")), "hidden by default");

        app.handle_key(KeyEvent::from(KeyCode::Char('A')));
        let (buf, rows) = render_app(&mut app);
        let y = rows
            .iter()
            .position(|r| r.contains("shelved"))
            .expect("archived row visible after toggle") as u16;
        // The name is not the selected row (selection restores to the previous
        // top session), so its ink must be the dimmed comment tone, not INK.
        let row_cells: Vec<String> = (0..buf.area.width)
            .map(|cx| buf.cell((cx, y)).unwrap().symbol().to_string())
            .collect();
        let x = (0..row_cells.len())
            .find(|&i| row_cells[i..].concat().starts_with("shelved"))
            .expect("shelved cell run") as u16;
        let cell = buf.cell((x, y)).unwrap();
        assert_eq!(cell.fg, Palette::light().comment);
    }

    #[test]
    fn footer_normal_hint_names_archived_toggle() {
        // The hint line barely fits render_app's 115 cols; a version corner
        // (leaked CS_VERSION) would clip "archived", so render without one.
        let _env = VERSION_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("CS_VERSION");
        let mut app = App::new(locked_and_recent_sessions());
        app.theme = Palette::light();
        let (_, rows) = render_app(&mut app);
        let footer = rows.last().unwrap();
        assert!(footer.contains("archived"), "footer: {}", footer);
    }

    #[test]
    fn preview_state_reads_archived() {
        let mut app = App::new(sessions_with_one_archived());
        app.theme = Palette::light();
        app.show_archived = true;
        app.apply_filter_and_sort();
        // Select the archived session by finding it in filtered order.
        let pos = app
            .filtered
            .iter()
            .position(|&i| app.sessions[i].name == "shelved")
            .unwrap();
        app.table_state.select(Some(pos));
        let backend = TestBackend::new(160, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(&mut app, frame)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .filter_map(|x| buf.cell((x, y)).map(|c| c.symbol().to_string()))
                    .collect::<String>()
            })
            .collect();
        assert!(
            rows.iter().any(|r| r.contains("state") && r.contains("archived")),
            "preview should label state archived"
        );
    }
}
