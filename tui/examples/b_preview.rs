// ABOUTME: Throwaway spike that renders redesign direction B' on a real terminal
// ABOUTME: Run `cargo run --example b_preview` to view; `-- --dump` prints the layout without a TTY

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::layout::Position;
use ratatui::style::{Color, Modifier, Style};
use ratatui::widgets::Block;
use ratatui::{Frame, Terminal};

type Rgb = (u8, u8, u8);

// Cream / light palette, council-tuned.
const PAPER: Rgb = (250, 247, 242);
const INK: Rgb = (43, 33, 24);
const MUT: Rgb = (122, 106, 88);
const FAINT: Rgb = (168, 151, 130);
const SOFT: Rgb = (226, 213, 196);
const STRONG: Rgb = (201, 180, 155);
const RUST: Rgb = (183, 71, 34);
const EMBER: Rgb = (216, 90, 36);
const AMBER: Rgb = (242, 167, 53);
const GOLD: Rgb = (176, 132, 40);
const WASH: Rgb = (255, 240, 218);
const TEAL: Rgb = (15, 118, 110);
const HERO: [Rgb; 4] = [(143, 50, 28), (216, 90, 36), (242, 167, 53), (214, 162, 30)];
const RAIL: [Rgb; 3] = [(193, 58, 29), (228, 91, 34), (232, 167, 46)];

fn c(t: Rgb) -> Color {
    Color::Rgb(t.0, t.1, t.2)
}
fn lerp(a: Rgb, b: Rgb, t: f32) -> Rgb {
    let f = |x: u8, y: u8| (x as f32 + t * (y as f32 - x as f32)).round() as u8;
    (f(a.0, b.0), f(a.1, b.1), f(a.2, b.2))
}
fn ramp(stops: &[Rgb], n: u16, i: u16) -> Rgb {
    if n <= 1 {
        return stops[0];
    }
    let t = i as f32 / (n - 1) as f32;
    let p = t * (stops.len() - 1) as f32;
    let a = p.floor() as usize;
    let b = (a + 1).min(stops.len() - 1);
    lerp(stops[a], stops[b], p - a as f32)
}
fn put(buf: &mut Buffer, x: u16, y: u16, ch: char, fg: Rgb, bold: bool) {
    if let Some(cell) = buf.cell_mut(Position::new(x, y)) {
        cell.set_char(ch).set_fg(c(fg));
        if bold {
            cell.modifier |= Modifier::BOLD;
        }
    }
}
fn puts(buf: &mut Buffer, x: u16, y: u16, s: &str, fg: Rgb, bold: bool) {
    for (i, ch) in s.chars().enumerate() {
        put(buf, x + i as u16, y, ch, fg, bold);
    }
}
fn set_bg(buf: &mut Buffer, x: u16, y: u16, w: u16, bg: Rgb) {
    for i in 0..w {
        if let Some(cell) = buf.cell_mut(Position::new(x + i, y)) {
            cell.set_bg(c(bg));
        }
    }
}
fn grad(buf: &mut Buffer, x: u16, y: u16, ch: char, n: u16, stops: &[Rgb]) {
    for i in 0..n {
        put(buf, x + i, y, ch, ramp(stops, n, i), false);
    }
}

/// Rounded card with a gradient top border and the title set into the frame.
fn card(buf: &mut Buffer, x: u16, y: u16, w: u16, h: u16, title: &str, side: Rgb) {
    if w < 4 || h < 2 {
        return;
    }
    let mut top: Vec<char> = vec!['╭'];
    for ch in format!(" {} ", title).chars() {
        top.push(ch);
    }
    while (top.len() as u16) < w - 1 {
        top.push('─');
    }
    top.push('╮');
    for (i, ch) in top.iter().enumerate() {
        put(buf, x + i as u16, y, *ch, ramp(&HERO, w, i as u16), false);
    }
    for yy in (y + 1)..(y + h - 1) {
        put(buf, x, yy, '│', side, false);
        put(buf, x + w - 1, yy, '│', side, false);
    }
    put(buf, x, y + h - 1, '╰', side, false);
    for i in 1..(w - 1) {
        put(buf, x + i, y + h - 1, '─', side, false);
    }
    put(buf, x + w - 1, y + h - 1, '╯', side, false);
}

struct Sess {
    group: &'static str,
    name: &'static str,
    cr: &'static str,
    age: &'static str,
    heat: Rgb,
    sec: u32,
    q: u32,
    repo: &'static str,
    locked: bool,
    sel: bool,
}

fn sessions() -> Vec<Sess> {
    let s = |group, name, cr, age, heat, sec, q, repo, locked, sel| Sess {
        group, name, cr, age, heat, sec, q, repo, locked, sel,
    };
    vec![
        s("Today", "claude-sessions", "Jul 09", "2m", TEAL, 3, 4, "hex/claude-sessions", true, true),
        s("Today", "sym", "—", "now", TEAL, 4, 0, "—", true, false),
        s("Today", "fignity", "—", "2m", TEAL, 2, 1, "erp/fignity", true, false),
        s("Today", "claude-council", "—", "17m", GOLD, 1, 0, "hex/claude-council", false, false),
        s("This Week", "empire", "Feb 23", "2d", EMBER, 1, 0, "erp/empire", false, false),
        s("This Week", "comfy-nodes", "Feb 09", "2d", EMBER, 28, 3, "comfy/nodes", false, false),
        s("This Week", "teamcity", "Dec 16", "2d", EMBER, 7, 0, "—", false, false),
        s("This Week", "claude-guard", "Feb 11", "3d", EMBER, 10, 2, "hex/claude-guard", false, false),
        s("This Week", "erpk-ai-costs", "Feb 16", "3d", EMBER, 33, 0, "erp/ai-costs", false, false),
        s("This Week", "comfy", "Dec 17", "4d", EMBER, 1, 0, "comfy/comfy", false, false),
        s("This Week", "slacky", "—", "4d", EMBER, 11, 1, "hex/slacky", false, false),
        s("This Month", "wap", "Jul 01", "1w", FAINT, 0, 0, "erp/wap", false, false),
        s("This Month", "debug", "Jun 05", "1w", FAINT, 0, 0, "—", false, false),
        s("This Month", "firstborn-server", "Jun 22", "2w", FAINT, 0, 0, "erp/firstborn-server", false, false),
        s("This Month", "symbiotica-hub", "Jun 15", "2w", FAINT, 11, 0, "erp/symbiotica-hub", false, false),
    ]
}

fn qbar(n: u32) -> String {
    let f = if n == 0 { 0 } else if n <= 1 { 1 } else if n <= 3 { 2 } else if n <= 5 { 3 } else { 4 };
    (0..4).map(|i| if i < f { '▰' } else { '▱' }).collect()
}

/// Repo-first truncation: prefer owner/repo, else the repo alone, else a
/// middle-elided repo. Never tail-clips (the repo name is what matters).
fn truncate_repo(repo: &str, w: usize) -> String {
    if repo == "—" {
        return "—".into();
    }
    if repo.chars().count() <= w {
        return repo.into();
    }
    let name = repo.split('/').next_back().unwrap_or(repo);
    if name.chars().count() <= w {
        return name.into();
    }
    if w <= 1 {
        return "…".into();
    }
    let ch: Vec<char> = name.chars().collect();
    let keep = w - 1;
    let head = keep / 2;
    let tail = keep - head;
    let mut out: String = ch[..head].iter().collect();
    out.push('…');
    out.extend(ch[ch.len() - tail..].iter());
    out
}

fn draw_b(f: &mut Frame) {
    let area = f.area();
    f.render_widget(Block::default().style(Style::default().bg(c(PAPER))), area);
    let buf = f.buffer_mut();
    let (w, h) = (area.width, area.height);
    if w < 70 || h < 16 {
        puts(buf, 1, 1, "terminal too small — widen to ~110x30", RUST, true);
        return;
    }

    // ---- masthead: prominent count + explicit sort ----
    put(buf, 0, 0, '▌', RAIL[0], false);
    puts(buf, 2, 0, "cs-tui", RUST, true);
    let mut mx = 9u16;
    for (txt, col, bold) in [
        ("106 sessions", INK, true),
        ("  ·  3 live", TEAL, false),
        ("  ·  sorted by age", MUT, false),
    ] {
        puts(buf, mx, 0, txt, col, bold);
        mx += txt.chars().count() as u16;
    }
    grad(buf, 0, 1, '━', w, &HERO);

    // ---- body split ----
    let tw = (w as u32 * 62 / 100) as u16;
    let rx = tw + 2;
    let rw = w.saturating_sub(rx);
    let top = 3u16;

    // columns: [rail][dot] name … created age secrets queue github
    let x_dot = 1u16;
    let x_name = 3u16;
    let meta0 = x_name + (tw.saturating_sub(x_name)) * 30 / 100;
    let step = tw.saturating_sub(meta0) / 5;
    let x_cr = meta0;
    let x_age = meta0 + step;
    let x_sec = meta0 + step * 2;
    let x_q = meta0 + step * 3;
    let x_gh = meta0 + step * 4;

    puts(buf, x_name, top, "SESSION", MUT, true);
    for (x, lbl) in [(x_cr, "CREATED"), (x_sec, "SECRETS"), (x_q, "QUEUE"), (x_gh, "GITHUB")] {
        puts(buf, x, top, lbl, MUT, true);
    }
    puts(buf, x_age, top, "AGE", MUT, true);
    puts(buf, x_age + 4, top, "▼", RUST, false); // active sort marker

    let sess = sessions();
    let mut cur = "";
    let mut y = top + 2;
    for s in &sess {
        if y >= h - 1 {
            break;
        }
        // group divider row
        if s.group != cur {
            if !cur.is_empty() {
                y += 1; // one blank row before a new section
            }
            let n = sess.iter().filter(|z| z.group == s.group).count();
            let label = format!("── {} · {} ", s.group, n);
            puts(buf, 1, y, &label, MUT, true);
            let start = 1 + label.chars().count() as u16;
            if tw > start {
                for x in start..tw {
                    put(buf, x, y, '─', SOFT, false);
                }
            }
            cur = s.group;
            y += 1;
            if y >= h - 1 {
                break;
            }
        }

        if s.sel {
            set_bg(buf, 0, y, tw, WASH);
            put(buf, 0, y, '▌', RAIL[1], false);
        }
        // leading status: recency dot, or a filled square when locked
        if s.locked {
            put(buf, x_dot, y, '▪', EMBER, false);
        } else {
            put(buf, x_dot, y, '●', s.heat, false);
        }
        let name_fg = if s.sel { (28, 20, 15) } else { INK };
        puts(buf, x_name, y, s.name, name_fg, s.sel);
        puts(buf, x_cr, y, s.cr, MUT, false);
        puts(buf, x_age, y, s.age, s.heat, false); // colored text, no wick
        if s.sec > 0 {
            puts(buf, x_sec, y, &s.sec.to_string(), INK, s.sel);
        } else {
            put(buf, x_sec, y, '·', FAINT, false);
        }
        let qcol = if s.q > 3 { RUST } else if s.q > 0 { AMBER } else { FAINT };
        puts(buf, x_q, y, &qbar(s.q), qcol, false);
        if s.q > 0 {
            puts(buf, x_q + 5, y, &s.q.to_string(), MUT, false);
        }
        let ghw = tw.saturating_sub(x_gh) as usize;
        puts(buf, x_gh, y, &truncate_repo(s.repo, ghw), if s.sel { RUST } else { FAINT }, false);
        y += 1;
    }

    // ---- right column: preview (compact labeled meta) + notes ----
    if rw >= 18 {
        card(buf, rx, top, rw, 9, "preview", STRONG);
        let lx = rx + 2;
        let vx = rx + 12;
        puts(buf, lx, top + 1, "claude-sessions", INK, true);
        for (i, (k, v)) in [
            ("created", "2026-07-09 11:01"),
            ("modified", "2m ago"),
            ("state", "● live · locked 86976"),
            ("repo", "hex/claude-sessions"),
        ]
        .iter()
        .enumerate()
        {
            let yy = top + 2 + i as u16;
            puts(buf, lx, yy, k, FAINT, false);
            let vcol = if *k == "state" { TEAL } else { INK };
            puts(buf, vx, yy, v, vcol, false);
        }
        puts(buf, lx, top + 6, "objective", FAINT, false);
        puts(buf, vx, top + 6, "redesign the picker", INK, false);
        puts(buf, lx, top + 7, "narrative", FAINT, false);
        puts(buf, vx, top + 7, "council: cut braille, group", MUT, false);

        let ny = top + 10;
        if ny + 5 < h {
            card(buf, rx, ny, rw, 5, "notes", SOFT);
            puts(buf, rx + 2, ny + 1, "[ ] tune gold on cream", MUT, false);
            puts(buf, rx + 2, ny + 2, "[x] cut the braille wick", FAINT, false);
            puts(buf, rx + 2, ny + 3, "[x] time grouping + density", FAINT, false);
        }
    }

    // ---- footer ----
    let fy = h - 1;
    let mut fx = 1u16;
    for (key, label) in [("↑↓", "move"), ("↵", "open"), ("space", "mark"), ("/", "search"), ("q", "quit")] {
        puts(buf, fx, fy, key, RUST, true);
        fx += key.chars().count() as u16 + 1;
        puts(buf, fx, fy, label, MUT, false);
        fx += label.chars().count() as u16 + 3;
    }
}

fn dump() {
    let (w, h) = (110u16, 30u16);
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| draw_b(f)).unwrap();
    let buf = term.backend().buffer().clone();
    let mut out = String::new();
    for y in 0..h {
        for x in 0..w {
            if let Some(cell) = buf.cell(Position::new(x, y)) {
                out.push_str(cell.symbol());
            }
        }
        out.push('\n');
    }
    print!("{}", out);
}

fn run() -> std::io::Result<()> {
    let mut terminal = ratatui::init();
    let res = (|| -> std::io::Result<()> {
        loop {
            terminal.draw(|f| draw_b(f))?;
            if let Event::Key(k) = event::read()? {
                let ctrl_c = k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL);
                if matches!(k.code, KeyCode::Char('q') | KeyCode::Esc) || ctrl_c {
                    break;
                }
            }
        }
        Ok(())
    })();
    ratatui::restore();
    res
}

fn main() {
    if std::env::args().any(|a| a == "--dump") {
        dump();
        return;
    }
    if let Err(e) = run() {
        eprintln!("error: {e}");
    }
}
