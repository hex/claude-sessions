# cs-tui B′ Visual Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the cs-tui picker to the approved B′ design (masthead + gradient rule, borderless grouped table, wash/rail selection, gradient-top cards) with zero behavior change.

**Architecture:** All changes live in `tui/src/theme.rs` (new B′ tokens + ramp helpers) and `tui/src/ui.rs` (render restyle). `app.rs` state, event handling, data model (`session.rs`), and the cs⇄TUI protocol are untouched. The committed spike `tui/examples/b_preview.rs` is the visual source of truth; the spec is `docs/superpowers/specs/2026-07-14-tui-bprime-design.md`.

**Tech Stack:** Rust, ratatui 0.29, crossterm 0.28. Tests: inline `mod tests` with `TestBackend`, `cargo test --manifest-path tui/Cargo.toml` (currently 203 passing; `RUST_TEST_THREADS=1` is set by `tui/.cargo/config.toml`).

## Global Constraints

- **Zero behavior change**: same columns, keys, mouse targets, sorting, search, marking, two-line stdout protocol, stderr rendering, `CS_TERM_THEME` handoff.
- **Glyph safety**: box-drawing, block elements, geometric shapes, braille only. Never Miscellaneous Symbols (`☐☑⚿⎇` are tofu on Alex's font). ASCII `[ ]`/`[x]` for checkboxes; lock is `▪`.
- **Light palette constants are council-approved values — verbatim, no adjustment**: PAPER(250,247,242) INK(43,33,24) MUT(122,106,88) FAINT(168,151,130) SOFT(226,213,196) STRONG(201,180,155) RUST(183,71,34) EMBER(216,90,36) AMBER(242,167,53) GOLD(176,132,40) WASH(255,240,218) TEAL(15,118,110); HERO ramp (143,50,28)→(216,90,36)→(242,167,53)→(214,162,30); RAIL ramp (193,58,29)→(228,91,34)→(232,167,46).
- **Dark tokens**: WASH(60,46,36) TEAL(45,212,191); HERO (221,80,20)→(237,128,0)→(246,154,0)→(214,162,30); RAIL (221,80,20)→(246,154,0)→(250,180,60). Structural mapping only; visual tuning is a stated follow-up.
- **One animated element**: the existing shimmer phase machinery drives the selection rail; nothing else animates; the idle-block loop (`is_animating`) is untouched.
- **Test re-assertion rule**: every existing test that asserts old chrome (band, zebra, `▤`, `Borders::ALL`, title) is rewritten to assert the B′ equivalent property — never deleted, never weakened to trivial.
- Run tests via `cargo test --manifest-path tui/Cargo.toml`; run a focused test with `-- <name>`. No bash-side changes; `./build.sh` not needed.

---

### Task 1: theme.rs — B′ tokens and ramp helpers

**Files:**
- Modify: `tui/src/theme.rs` (Palette struct :17-44, dark() :47-68, light() :70-93, tests :200-292)

**Interfaces:**
- Produces: new `Palette` fields `ink, mut_, faint, soft, strong, ember, amber, wash, teal: Color` and `hero: [Color; 4], rail: [Color; 3]` (names avoid the `mut` keyword via `mut_`); `pub fn ramp(stops: &[(u8,u8,u8)], n: u16, i: u16) -> (u8,u8,u8)` beside `lerp_rgb`; helper `pub fn rgbs_of(cs: &[Color]) -> Vec<(u8,u8,u8)>` is NOT added (callers map `rgb_of` inline — YAGNI).
- Existing fields (`fg`, `comment`, `rust`, `gold`, heat/recency/shimmer fns) keep their values and semantics; `zebra`, `sel_bg`, `header_*` fields REMAIN until Tasks 2-3 retire their uses (deleted in Task 6 cleanup).

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `tui/src/theme.rs`:

```rust
    #[test]
    fn bprime_light_tokens_are_council_values() {
        let p = Palette::light();
        assert_eq!(p.ink, Color::Rgb(43, 33, 24));
        assert_eq!(p.wash, Color::Rgb(255, 240, 218));
        assert_eq!(p.teal, Color::Rgb(15, 118, 110));
        assert_eq!(p.ember, Color::Rgb(216, 90, 36));
        assert_eq!(p.hero[0], Color::Rgb(143, 50, 28));
        assert_eq!(p.hero[3], Color::Rgb(214, 162, 30));
        assert_eq!(p.rail[1], Color::Rgb(228, 91, 34));
    }

    #[test]
    fn bprime_dark_tokens_exist_and_differ() {
        let l = Palette::light();
        let d = Palette::dark();
        assert_ne!(d.wash, l.wash);
        assert_ne!(d.teal, l.teal);
        assert_eq!(d.hero[1], Color::Rgb(237, 128, 0));
        assert_eq!(d.rail[2], Color::Rgb(250, 180, 60));
    }

    #[test]
    fn ramp_hits_endpoints_and_interpolates() {
        let stops = [(0u8, 0u8, 0u8), (100, 100, 100)];
        assert_eq!(ramp(&stops, 5, 0), (0, 0, 0));
        assert_eq!(ramp(&stops, 5, 4), (100, 100, 100));
        assert_eq!(ramp(&stops, 5, 2), (50, 50, 50));
        // n <= 1 degenerates to the first stop
        assert_eq!(ramp(&stops, 1, 0), (0, 0, 0));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path tui/Cargo.toml -- bprime ramp_hits`
Expected: compile FAILURE — no such fields/function (that is the RED for added API).

- [ ] **Step 3: Implement**

Add fields to `Palette` (after `sep` at :43):

```rust
    /// B′ tokens (spec: docs/superpowers/specs/2026-07-14-tui-bprime-design.md).
    pub ink: Color,
    pub mut_: Color,
    pub faint: Color,
    pub soft: Color,
    pub strong: Color,
    pub ember: Color,
    pub amber: Color,
    pub wash: Color,
    pub teal: Color,
    /// Masthead-rule / card-border gradient stops.
    pub hero: [Color; 4],
    /// Selection-rail gradient stops.
    pub rail: [Color; 3],
```

In `dark()` append to the struct literal:

```rust
            ink: Color::Rgb(245, 230, 211),
            mut_: Color::Rgb(161, 136, 127),
            faint: Color::Rgb(120, 104, 96),
            soft: Color::Rgb(56, 50, 46),
            strong: Color::Rgb(90, 78, 66),
            ember: Color::Rgb(230, 100, 40),
            amber: Color::Rgb(246, 154, 0),
            wash: Color::Rgb(60, 46, 36),
            teal: Color::Rgb(45, 212, 191),
            hero: [
                Color::Rgb(221, 80, 20),
                Color::Rgb(237, 128, 0),
                Color::Rgb(246, 154, 0),
                Color::Rgb(214, 162, 30),
            ],
            rail: [
                Color::Rgb(221, 80, 20),
                Color::Rgb(246, 154, 0),
                Color::Rgb(250, 180, 60),
            ],
```

In `light()` append (council values, verbatim):

```rust
            ink: Color::Rgb(43, 33, 24),
            mut_: Color::Rgb(122, 106, 88),
            faint: Color::Rgb(168, 151, 130),
            soft: Color::Rgb(226, 213, 196),
            strong: Color::Rgb(201, 180, 155),
            ember: Color::Rgb(216, 90, 36),
            amber: Color::Rgb(242, 167, 53),
            wash: Color::Rgb(255, 240, 218),
            teal: Color::Rgb(15, 118, 110),
            hero: [
                Color::Rgb(143, 50, 28),
                Color::Rgb(216, 90, 36),
                Color::Rgb(242, 167, 53),
                Color::Rgb(214, 162, 30),
            ],
            rail: [
                Color::Rgb(193, 58, 29),
                Color::Rgb(228, 91, 34),
                Color::Rgb(232, 167, 46),
            ],
```

Add `ramp` beside `lerp_rgb` (:175):

```rust
/// Sample a multi-stop gradient at cell `i` of `n`. Piecewise-linear across
/// the stops; `n <= 1` returns the first stop.
pub fn ramp(stops: &[(u8, u8, u8)], n: u16, i: u16) -> (u8, u8, u8) {
    if n <= 1 || stops.len() == 1 {
        return stops[0];
    }
    let t = i as f32 / (n - 1) as f32;
    let pos = t * (stops.len() - 1) as f32;
    let a = pos.floor() as usize;
    let b = (a + 1).min(stops.len() - 1);
    lerp_rgb(stops[a], stops[b], pos - a as f32)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path tui/Cargo.toml`
Expected: 203 + 3 = 206 passing (no existing test touches the new fields).

- [ ] **Step 5: Commit**

```bash
git add tui/src/theme.rs
git commit -m "feat(tui): B-prime palette tokens and multi-stop ramp helper

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

### Task 2: Masthead + gradient rule + footer restyle

**Files:**
- Modify: `tui/src/ui.rs` — `render()` layout (:114-184), new `render_masthead`, `render_footer` (:642-696); `gradient_title` (:615-640) DELETED; table `Block` title dropped (interacts with Task 3 — this task only removes the *title*, Task 3 removes the borders)

**Interfaces:**
- Consumes: Task 1 tokens (`p.hero`, `p.rail`, `p.ink`, `p.mut_`, `p.teal`, `p.faint`), `theme::{ramp, rgb_of}`, `App::filtered`, `Session::is_locked`, `app.sort_col`/`sort_dir`.
- Produces: `fn render_masthead(app: &App, frame: &mut Frame, area: Rect)` — row 0 `▌ cs-tui  N sessions · M live · sorted by <col> <dir>`, row 1 full-width `━` HERO rule. `fn sort_label(col: SortColumn) -> &'static str` (lowercase: "session", "created", "age", "secrets", "queue", "github"). Layout gains a `Constraint::Length(2)` first chunk; all later `chunks[i]` indices shift by one.

- [ ] **Step 1: Write the failing tests**

Append to `mod tests` in ui.rs (using the existing `render_at`/`render_wide` harness at :1409/:1426 as reference for constructing an App with `one_session()`):

```rust
    #[test]
    fn masthead_shows_brand_counts_and_sort() {
        let mut app = test_app(); // existing helper pattern; construct as other ui tests do
        let text = render_wide(&mut app);
        assert!(text.contains("cs-tui"), "masthead brand missing:\n{text}");
        assert!(text.contains("sessions"), "session count missing:\n{text}");
        assert!(text.contains("live"), "live count missing:\n{text}");
        assert!(text.contains("sorted by"), "sort readout missing:\n{text}");
    }

    #[test]
    fn masthead_rule_spans_width_with_hero_ramp() {
        let mut app = test_app();
        // Render into a TestBackend and inspect row 1 directly.
        let backend = ratatui::backend::TestBackend::new(80, 24);
        let mut term = ratatui::Terminal::new(backend).unwrap();
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
        std::env::set_var("CS_VERSION", "9.9.9");
        let mut app = test_app();
        let text = render_wide(&mut app);
        assert!(text.contains("q:quit"), "key hints missing:\n{text}");
        assert!(text.contains("9.9.9"), "version missing from footer:\n{text}");
        std::env::remove_var("CS_VERSION");
    }
```

(Adapt `test_app()` to whatever the file's existing App-construction helper is — read the test module first; do not invent a parallel harness.)

- [ ] **Step 2: Run to verify failure**

Run: `cargo test --manifest-path tui/Cargo.toml -- masthead footer_styles`
Expected: FAIL — no masthead rows exist; version renders in the table title today.

- [ ] **Step 3: Implement**

In `render()` (:128), the vertical layout becomes:

```rust
    let chunks = Layout::vertical([
        Constraint::Length(2), // masthead: brand row + gradient rule
        Constraint::Min(5),
        Constraint::Length(action_bar_height),
        Constraint::Length(1),
    ])
    .split(frame.area());

    render_masthead(app, frame, chunks[0]);
```

then replace every `chunks[0]`→`chunks[1]`, `chunks[1]`→`chunks[2]`, `chunks[2]`→`chunks[3]` in the remainder of `render()`.

New function (place above `render_table`):

```rust
/// B′ masthead: brand, prominent counts, explicit sort readout, and a
/// full-width HERO gradient rule beneath.
fn render_masthead(app: &App, frame: &mut Frame, area: Rect) {
    let p = app.theme;
    if area.height < 2 {
        return;
    }
    let live = app.sessions.iter().filter(|s| s.is_locked).count();
    let dir = match app.sort_dir {
        SortDirection::Asc => "\u{25b2}",
        SortDirection::Desc => "\u{25bc}",
    };
    let line = Line::from(vec![
        Span::styled("\u{258c} ", Style::default().fg(p.rail[0])),
        Span::styled("cs-tui", Style::default().fg(p.rust).add_modifier(Modifier::BOLD)),
        Span::styled(
            format!("  {} sessions", app.filtered.len()),
            Style::default().fg(p.ink).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("  \u{b7}  {} live", live), Style::default().fg(p.teal)),
        Span::styled(
            format!("  \u{b7}  sorted by {} {}", sort_label(app.sort_col), dir),
            Style::default().fg(p.mut_),
        ),
    ]);
    frame.render_widget(Paragraph::new(line), Rect { height: 1, ..area });

    let stops: Vec<(u8, u8, u8)> = p.hero.iter().map(|c| theme::rgb_of(*c)).collect();
    let buf = frame.buffer_mut();
    for i in 0..area.width {
        let (r, g, b) = theme::ramp(&stops, area.width, i);
        if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(area.x + i, area.y + 1)) {
            cell.set_char('\u{2501}');
            cell.set_fg(Color::Rgb(r, g, b));
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
```

(Match `SortColumn`'s actual variant names from app.rs before writing — if they differ, keep the real names and the lowercase labels above.)

Footer (:686-695): key hints become styled pairs and the version right-aligns. Replace the final block of `render_footer` with:

```rust
    let mut footer_spans = Vec::new();
    if !app.marked_sessions.is_empty() && matches!(app.mode, Mode::Normal) {
        footer_spans.push(Span::styled(
            format!("{} marked  ", app.marked_sessions.len()),
            Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
        ));
    }
    for (i, part) in keys.split("  ").filter(|s| !s.is_empty()).enumerate() {
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
    let version = std::env::var("CS_VERSION").unwrap_or_default();
    let footer = Paragraph::new(Line::from(footer_spans));
    frame.render_widget(footer, area);
    if !version.is_empty() {
        let vtext = format!("v{version}");
        let w = vtext.chars().count() as u16;
        if area.width > w + 2 {
            let vrect = Rect { x: area.x + area.width - w, width: w, ..area };
            frame.render_widget(
                Paragraph::new(Span::styled(vtext, Style::default().fg(p.faint))),
                vrect,
            );
        }
    }
```

Delete `gradient_title` (:615-640) and its call site: in `render_table`, remove lines :484-486 (`session_count`, `version`, `title`) and drop `.title(title)` from the table's Block (:521). (The Block itself — borders — is Task 3's job; here it keeps `Borders::ALL` minus the title.)

- [ ] **Step 4: Run the suite; update displaced assertions**

Run: `cargo test --manifest-path tui/Cargo.toml`
Expected: the three new tests pass. Any existing test asserting the title text (`claude-sessions v`, `[N sessions]`) fails — re-assert those on the masthead per the re-assertion rule (the brand/count/version properties still exist, in new homes: masthead + footer). Fix `row_hit_spans`-adjacent tests only if the masthead shifted absolute y coordinates they assert (the table area itself is unchanged this task — chunks[1] has the same height as the old chunks[0] minus 2 rows; hit-span tests that hardcode absolute screen y must add 2).

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "feat(tui): B-prime masthead with hero rule; footer key styling and version

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

### Task 3: Table restyle — borderless, wash/rail selection, dot gutter, QUEUE bar, GITHUB truncation

**Files:**
- Modify: `tui/src/ui.rs` — `render_table` (:186-603 region as shifted by Task 2)
- Modify: `tui/src/session.rs` — add `truncate_repo` + tests (beside `relative_age`)

**Interfaces:**
- Consumes: tokens from Task 1; `SELECT_BAR`/`SELECT_WIDTH`/`COL_SPACING` constants (ui.rs :65-71 region); shimmer phase block (:586-593).
- Produces: `fn qbar(n: u32) -> String` (ui.rs, near the top helpers); `pub fn truncate_repo(repo: &str, w: usize) -> String` (session.rs); header cells styled `p.mut_` bold with RUST `▲/▼`; the To-Do column header renamed `Queue`; borderless table (no `Block`), geometry constants updated.

- [ ] **Step 1: Write the failing tests**

session.rs tests (worked examples, independent of implementation):

```rust
    #[test]
    fn truncate_repo_fits_owner_repo() {
        assert_eq!(truncate_repo("hex/claude-sessions", 25), "hex/claude-sessions");
    }
    #[test]
    fn truncate_repo_falls_back_to_repo_name() {
        assert_eq!(truncate_repo("hex/claude-sessions", 15), "claude-sessions");
    }
    #[test]
    fn truncate_repo_middle_elides_long_repo() {
        assert_eq!(truncate_repo("erp/firstborn-server", 10), "firs\u{2026}erver");
    }
    #[test]
    fn truncate_repo_one_char_is_ellipsis() {
        assert_eq!(truncate_repo("erp/firstborn-server", 1), "\u{2026}");
    }
```

ui.rs tests:

```rust
    #[test]
    fn qbar_fill_levels() {
        assert_eq!(qbar(0), "\u{25b1}\u{25b1}\u{25b1}\u{25b1}");
        assert_eq!(qbar(1), "\u{25b0}\u{25b1}\u{25b1}\u{25b1}");
        assert_eq!(qbar(3), "\u{25b0}\u{25b0}\u{25b1}\u{25b1}");
        assert_eq!(qbar(5), "\u{25b0}\u{25b0}\u{25b0}\u{25b1}");
        assert_eq!(qbar(9), "\u{25b0}\u{25b0}\u{25b0}\u{25b0}");
    }

    #[test]
    fn table_is_borderless_and_zebra_free() {
        let mut app = test_app();
        let backend = ratatui::backend::TestBackend::new(80, 24);
        let mut term = ratatui::Terminal::new(backend).unwrap();
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
    }

    #[test]
    fn selected_row_gets_wash_and_locked_row_gets_square() {
        let mut app = test_app(); // adapt construction to the module's fixture helpers
        // Ensure a deterministic selection on the first row.
        app.table_state.select(Some(0));
        let backend = ratatui::backend::TestBackend::new(80, 24);
        let mut term = ratatui::Terminal::new(backend).unwrap();
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
                if cell.symbol() == "\u{25cf}" || cell.symbol() == "\u{25aa}" {
                    dot_found = true;
                }
            }
        }
        assert!(wash_found, "selected row must carry the wash background");
        assert!(dot_found, "gutter must carry a status dot or locked square");
    }
```

Adapt `test_app()` construction to the module's real fixture helpers (they exist for the sort/section tests); if the fixture offers a locked session, additionally assert its gutter cell shows `▪` and an unlocked recent session's shows `●` at the exact gutter x — strengthen, never weaken, these assertions at write time.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test --manifest-path tui/Cargo.toml -- truncate_repo qbar table_is_borderless selected_row`
Expected: compile failure for missing fns, then assertion failures for borders/zebra.

- [ ] **Step 3: Implement — the restyle, piece by piece**

(a) `qbar` in ui.rs (near `truncate_str`):

```rust
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
```

(b) `truncate_repo` in session.rs (public, beside `relative_age`) — port the spike function verbatim (spike :143-165), with `pub fn` and `&str`-in/`String`-out signature as written there (the `"—"` arm becomes an `is_empty()` arm: cs stores `None` for repo-less sessions, so the sentinel is unnecessary — return the input when `repo.chars().count() <= w`, else repo-name, else middle-ellipsis, else `…`).

(c) Header row (:214-231): label case stays as-is (`Session`, `Created`, `Age`, `Secrets`, `Github`) except `To-Do` → `Queue`; style changes from `p.header_fg` to `p.mut_` bold; the sort indicator span is styled RUST by making header cells `Line`s of two spans (label span MUT bold + indicator span RUST). Delete the band paint block (:548-563) and the `header_bg_*`/`warm_ramp` uses (keep `warm_ramp` only if still referenced; otherwise delete it too). The hairline rule under the header (:565-581) is KEPT but recolored `p.soft`, and its border-tee block (:575-581) is DELETED (no borders to tee into).

(d) Gutter (:256-280): the heat dot span stays; the lock rendering changes — when `s.is_locked`, the dot itself is replaced by `▪` EMBER (not appended):

```rust
            let mut name_spans: Vec<Span> = Vec::new();
            if s.is_locked {
                let sq = if dimmed { p.comment } else { p.ember };
                name_spans.push(Span::styled("\u{25aa} ", Style::default().fg(sq)));
            } else {
                name_spans.push(Span::styled("\u{25cf} ", Style::default().fg(heat)));
            }
```

The `icons.lock` gutter span for `is_locked` (:266-272) is deleted (the ▪ IS the lock signal); the hidden-secrets-column fallback (:273-280) keeps `icons.lock` (nerd-font-gated glyph acceptable there? NO — glyph safety: replace with a `▪` in GOLD). Name color: `p.gold` → `p.ink` normally, bold handled by the selection style (drop nothing else).

(e) Secrets cell (:419-427): number only, no icon: `format!("{}", s.secrets_count)` when >0 else `"\u{b7}"` FAINT, alignment kept. Queue cell (:429-436): `format!("{} {}", qbar(s.queue_depth), s.queue_depth)` when >0 else `qbar(0)`, colored FAINT/AMBER/RUST by `0 / 1-3 / >3`. Github cell (:438-453): drop the `icons.branch` span; render `truncate_repo(&github, col_width)` — column width comes from `app.column_widths.last()` of the PREVIOUS frame (acceptable: widths are stable between frames; fall back to no truncation when unknown) — styled FAINT (RUST when the row is selected; selection is known via `app.table_state.selected() == Some(row_idx)`).

(f) Zebra (:460-471): delete the `row_idx % 2` arm entirely — flash stays, otherwise unstyled row.

(g) Selection (:523): `row_highlight_style` becomes `Style::default().bg(p.wash).add_modifier(Modifier::BOLD)`; highlight symbol stays `SELECT_BAR`.

(h) Borderless: delete the `.block(...)` call and the `list_border` binding (:509-522). Geometry updates — with no Block, the table renders at `area` directly:

```rust
    let inner = area; // no border insets
```

The row-hit base changes from `y = 4` to `y = 2` (header + margin rule only) at :535; the comment updates accordingly. `rule_y` becomes `inner.y + 1` (unchanged expression, new meaning — verify against a dump). The shimmer scan range (:595) starts at `inner.y + 2`.

(i) Rail gradient: after the shimmer loop finds the `SELECT_BAR` cell (:597-600), instead of a single shimmer color, paint the bar cell with `p.rail` sampled by the shimmer phase — replace `cell.set_fg(shimmer)` with:

```rust
                let stops: Vec<(u8, u8, u8)> = p.rail.iter().map(|c| theme::rgb_of(*c)).collect();
                let idx = (phase * (stops.len() as f32 - 1.0)).round() as u16;
                let (r, g, b) = theme::ramp(&stops, stops.len() as u16, idx.min(stops.len() as u16 - 1));
                cell.set_fg(Color::Rgb(r, g, b));
```

(the existing phase drive and idle-block behavior are untouched — this only changes which colors the phase indexes).

- [ ] **Step 4: Run the suite; re-assert displaced tests**

Run: `cargo test --manifest-path tui/Cargo.toml`
Expected: new tests green. Existing failures to re-assert (not delete): `no_interior_vertical_dividers` (should still pass), any test asserting zebra bg, `▤`, `Borders`, lock icon glyph, gold name color, `To-Do` header, row-hit y-offsets (4→2, plus masthead +2 from Task 2), band bg colors. Every rewrite asserts the B′ property (e.g. zebra test becomes "adjacent unselected rows have identical bg").

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs tui/src/session.rs
git commit -m "feat(tui): borderless B-prime table — wash/rail selection, status gutter, queue bar, repo truncation

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

### Task 4: Group divider restyle

**Files:**
- Modify: `tui/src/ui.rs` — the section-label block inside `render_table` (:330-344 pre-shift) and the divider format

**Interfaces:**
- Consumes: `app.section_labels` (Option<&'static str> per row, set at section starts by `apply_filter_and_sort`).
- Produces: divider line `── <Label> · <count> ` in `p.mut_` bold + SOFT dash fill; a blank spacer line before every section except the first; `with_lead` and `extra_height` math extended for the spacer.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn section_divider_shows_label_and_count() {
        // Fixture: sessions spanning two time sections while date-sorted
        // (reuse the existing section-label test fixture in this module).
        let mut app = sectioned_test_app();
        let text = render_wide(&mut app);
        assert!(
            text.contains("\u{2500}\u{2500} Today \u{b7} "),
            "divider must carry '── Today · <n>':\n{text}"
        );
    }
```

(Count value: assert the exact `· N` for the fixture's Today-section size — a worked example from the fixture, e.g. `── Today · 2 `.)

- [ ] **Step 2: Run to verify failure** — the current divider is `── Today ────…` with no count.

- [ ] **Step 3: Implement**

Where the divider is built (:335-344), compute the section size by scanning forward in `app.filtered`/`app.section_labels` (rows until the next `Some(_)`), then:

```rust
            if let Some(label) = section_label {
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
                name_lines.push(Line::from(vec![
                    Span::styled(
                        format!("\u{2500}\u{2500} {} \u{b7} {} ", label, count),
                        Style::default().fg(p.mut_).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled("\u{2500}".repeat(200), Style::default().fg(p.soft)),
                ]));
            }
```

and extend `with_lead`/`extra_height` for the extra spacer line when `section_label.is_some() && row_idx != 0` (the lead-blank count becomes 2 for non-first sections: spacer + divider; the `with_lead` closure takes the count instead of a bool). Update the row-height math (`extra_height`) to match — the hit-map stays correct automatically because it reads `row_heights`.

- [ ] **Step 4: Run suite; re-assert** — existing section tests asserting the old `── Today ───` format are rewritten to the new label·count form; hit-span tests over sectioned fixtures gain the spacer row.

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "feat(tui): section dividers with counts and breathing row

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

### Task 5: Gradient-top cards for preview and to-do panes + structured preview meta

**Files:**
- Modify: `tui/src/ui.rs` — new `fn card_frame`, `render_preview_pane` (:1026-1165), `render_notes_pane` (:1166-1292)

**Interfaces:**
- Consumes: `p.hero`, `p.strong`, `p.soft`, `p.faint`, `p.ink`, `p.mut_`, `p.teal`, `theme::ramp`; `SessionPreview` fields; `Session` (created/modified/is_locked/lock_pid/git_repo).
- Produces: `fn card_frame(buf: &mut Buffer, area: Rect, title: &str, side: Color, p: Palette)` painting `╭ title ──╮` with per-cell HERO ramp on the top row, `│` sides and `╰──╯` bottom in `side`. Panes render their content inside `area` inset by 1, then paint the frame over the edge cells. Preview content: bold session name, labeled rows (`created`, `modified`, `state`, `repo`, `objective`, `narrative`) with FAINT labels at a fixed label column, then the pane's existing sections restyled to tokens. The to-do card keeps ALL current behavior (input, list focus, editing) — frame + tokens only, title `to-do`.

- [ ] **Step 1: Write the failing tests**

```rust
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
        let mut app = preview_test_app(); // fixture that opens the preview pane
        let text = render_wide(&mut app);
        for label in ["created", "modified", "state", "repo", "objective"] {
            assert!(text.contains(label), "missing meta label {label}:\n{text}");
        }
    }
```

- [ ] **Step 2: Run to verify failure** — `card_frame` doesn't exist; preview shows its old section layout.

- [ ] **Step 3: Implement**

`card_frame` (port of spike `card()` :74-98, adapted to `Color` + `Palette`):

```rust
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
        if let Some(cell) = buf.cell_mut(Position::new(area.x + i as u16, area.y)) {
            cell.set_char(*ch).set_fg(Color::Rgb(r, g, b));
        }
    }
    for y in (area.y + 1)..(area.y + area.height - 1) {
        for x in [area.x, area.x + area.width - 1] {
            if let Some(cell) = buf.cell_mut(Position::new(x, y)) {
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
        if let Some(cell) = buf.cell_mut(Position::new(x, by)) {
            cell.set_char(ch).set_fg(side);
        }
    }
}
```

Pane rework: in both pane functions, replace the current `Block::bordered()` construction with (1) computing `inner = area inset by 1`, (2) rendering existing content into `inner` (preview gets the new labeled-meta block first: name bold INK, then rows with label at `inner.x` FAINT and value at `inner.x + 11`, `state` value TEAL rendering `● live · locked <pid>` / `● live` / `dormant` from `is_locked`+`lock_pid`, `repo` from `git_repo`, then objective/narrative lines, then the existing discoveries/memory/contributors sections restyled: `section_header` (:1016) keeps its shape with `p.mut_`), (3) calling `card_frame(frame.buffer_mut(), area, "preview", p.strong, p)` (and `"to-do"`, `p.soft` for the notes pane — preserving its focus-brightened border behavior by passing `p.strong` when focused, `p.soft` when not). Checkbox rendering in the to-do list: if any `☐/☑` glyphs exist in that pane today, replace with `[ ]`/`[x]` — verify by reading the pane body; queue items are plain text lines, so likely no change.

- [ ] **Step 4: Run suite; re-assert** — pane tests asserting `Borders::ALL`/titles ("Preview", "To-Do") re-assert on the in-frame lowercase titles and rounded corners; focus-brightening tests re-assert on the side color change.

- [ ] **Step 5: Commit**

```bash
git add tui/src/ui.rs
git commit -m "feat(tui): gradient-top cards for preview and to-do panes with labeled meta

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

### Task 6: Token sweep, dead-token removal, dialogs, full gate

**Files:**
- Modify: `tui/src/ui.rs` (dialogs :761-1015, search/action bars), `tui/src/theme.rs` (retire dead fields)

**Interfaces:**
- Consumes: everything prior.
- Produces: `zebra`, `sel_bg`, `header_bg_lo/mid/hi`, `header_fg` fields removed from `Palette` (with their initializers in both themes) once `rg 'zebra|sel_bg|header_bg|header_fg' tui/src` shows no remaining consumers; dialogs/search bar/action bar mapped to tokens (fg→ink where it was header-band-dependent, comment→mut_ where B′ specifies) with NO structural change; `warm_ramp` deleted if unreferenced.

- [ ] **Step 1: Sweep** — `rg -n 'zebra|sel_bg|header_bg|header_fg|warm_ramp|icons.lock|icons.branch|\u{25a4}' tui/src/` and resolve every hit: either it was restyled in Tasks 2-5, or it is a dialog/bar token mapping to apply now, or it is dead and gets deleted (fields + initializers + any test asserting them, re-asserted per the rule).

- [ ] **Step 2: Full gate**

Run: `cargo test --manifest-path tui/Cargo.toml`
Expected: all tests pass (count will exceed 203 with the new tests).

Run: `cargo run --example b_preview --manifest-path tui/Cargo.toml -- --dump > /dev/null && echo spike-ok`
Expected: the spike still compiles (it shares theme.rs? it does not — it is self-contained; this is a cheap regression check that examples build).

Run: `bash tests/run_all.sh`
Expected: all bash suites pass (nothing bash-side changed; this guards the repo gate).

- [ ] **Step 3: Manual visual gate (Alex)** — run `cs` on the real terminal; compare against `cargo run --example b_preview --manifest-path tui/Cargo.toml`. Alex judges: masthead, table, selection, cards, both light and (if available) dark.

- [ ] **Step 4: Commit**

```bash
git add tui/src/ui.rs tui/src/theme.rs
git commit -m "refactor(tui): retire pre-B-prime palette fields; token-map dialogs

Claude-Session: https://claude.ai/code/session_014dwKbdYN8zpNdfKz6nmRVK"
```

---

## Plan Self-Review Notes

- Spec coverage: palette (T1), masthead/rule/footer (T2), borderless table + selection + gutter + QUEUE + GITHUB + zebra removal + rail (T3), dividers (T4), cards + preview meta + to-do frame (T5), token sweep + dead-field removal + gates (T6). Non-goals respected: no app.rs behavior edits (T2 touches render() layout only; T3 reads `table_state.selected()` — read-only).
- Two deliberate in-situ steps: Task 3's third test body and Task 5's checkbox check depend on fixture/helper names only discoverable in the test module — the steps say exactly what to assert and mark the discovery explicitly rather than inventing names that don't compile.
- Type consistency: `ramp(&[(u8,u8,u8)], u16, u16)` used identically in T2 masthead, T3 rail, T5 card; `qbar(u32)`; `truncate_repo(&str, usize) -> String`; `card_frame(&mut Buffer, Rect, &str, Color, Palette)`.
- Known churn: row-hit y base 4→2 (T3) plus masthead +2 (T2) — both called out with their tests.
