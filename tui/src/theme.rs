// ABOUTME: Color palette definitions matching the cs bash script theme
// ABOUTME: Provides light/dark B′ token palettes keyed off CS_TERM_THEME

use std::time::SystemTime;

use ratatui::style::Color;

/// Whether the terminal background is light or dark.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Theme {
    Dark,
    Light,
}

/// Full set of colors the UI draws with, resolved once for the detected theme.
#[derive(Clone, Copy)]
pub struct Palette {
    /// Canvas fill. `Reset` on dark leaves the terminal's own background untouched.
    pub base_bg: Color,
    /// Primary text.
    pub fg: Color,
    /// Muted/secondary text.
    pub comment: Color,
    pub red: Color,
    pub green: Color,
    pub yellow: Color,
    pub orange: Color,
    pub gold: Color,
    pub rust: Color,
    pub flash_success: Color,
    pub flash_error: Color,
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
}

impl Palette {
    pub fn dark() -> Self {
        Palette {
            base_bg: Color::Reset,
            fg: Color::Rgb(245, 230, 211),
            comment: Color::Rgb(161, 136, 127),
            red: Color::Rgb(239, 83, 80),
            green: Color::Rgb(139, 195, 74),
            yellow: Color::Rgb(255, 183, 77),
            orange: Color::Rgb(255, 138, 101),
            gold: Color::Rgb(255, 193, 7),
            rust: Color::Rgb(230, 74, 25),
            flash_success: Color::Rgb(30, 50, 30),
            flash_error: Color::Rgb(55, 25, 25),
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
        }
    }

    pub fn light() -> Self {
        // Muted warm palette on paper: chroma kept low (softer than fully
        // saturated accents) while luminance stays dark enough to read.
        Palette {
            base_bg: Color::Rgb(250, 247, 242),
            fg: Color::Rgb(48, 42, 36),
            comment: Color::Rgb(128, 116, 106),
            red: Color::Rgb(188, 74, 66),
            green: Color::Rgb(92, 140, 84),
            yellow: Color::Rgb(162, 122, 58),
            orange: Color::Rgb(190, 110, 74),
            gold: Color::Rgb(176, 132, 40),
            rust: Color::Rgb(183, 71, 34),
            flash_success: Color::Rgb(214, 236, 206),
            flash_error: Color::Rgb(246, 214, 210),
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
        }
    }

    pub fn for_theme(theme: Theme) -> Self {
        match theme {
            Theme::Dark => Self::dark(),
            Theme::Light => Self::light(),
        }
    }

    /// Color for metadata columns based on how recently the session was modified.
    /// Blends from `fg` (today) through intermediate tones to `comment` (old).
    pub fn recency_color(&self, modified_ts: Option<SystemTime>) -> Color {
        let ts = match modified_ts {
            Some(t) => t,
            None => return self.comment,
        };
        let age = match SystemTime::now().duration_since(ts) {
            Ok(d) => d,
            Err(_) => return self.fg, // future timestamp — treat as fresh
        };
        let secs = age.as_secs();
        const HOUR: u64 = 3600;
        const DAY: u64 = 86400;
        // Buckets: <1h → fg, <24h → 75%, <7d → 50%, <30d → 25%, older → comment
        let t = if secs < HOUR {
            0.0
        } else if secs < DAY {
            0.25
        } else if secs < 7 * DAY {
            0.50
        } else if secs < 30 * DAY {
            0.75
        } else {
            1.0
        };
        let (r, g, b) = lerp_rgb(rgb_of(self.fg), rgb_of(self.comment), t);
        Color::Rgb(r, g, b)
    }

    /// Categorical "aliveness" hue for a session's last activity: green when live,
    /// warming down through gold and orange, then settling to muted grey once
    /// dormant. Drives the recency heat dot and the Age column.
    pub fn heat_color(&self, modified_ts: Option<SystemTime>) -> Color {
        let ts = match modified_ts {
            Some(t) => t,
            None => return self.comment,
        };
        let secs = match SystemTime::now().duration_since(ts) {
            Ok(d) => d.as_secs(),
            Err(_) => return self.green, // future timestamp — treat as live
        };
        const HOUR: u64 = 3600;
        const DAY: u64 = 86400;
        if secs < HOUR {
            self.green
        } else if secs < DAY {
            self.gold
        } else if secs < 30 * DAY {
            self.orange
        } else {
            self.comment
        }
    }
}

/// Extract RGB components from a `Color::Rgb`, falling back to a neutral grey.
pub fn rgb_of(c: Color) -> (u8, u8, u8) {
    match c {
        Color::Rgb(r, g, b) => (r, g, b),
        _ => (128, 128, 128),
    }
}

/// Linearly blend two RGB triples by `t` in [0, 1] (truncating to u8).
pub fn lerp_rgb(a: (u8, u8, u8), b: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    let lerp = |x: u8, y: u8| -> u8 { (x as f32 + t * (y as f32 - x as f32)) as u8 };
    (lerp(a.0, b.0), lerp(a.1, b.1), lerp(a.2, b.2))
}

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

/// Parse a `light`/`dark` string (case-insensitive).
fn theme_from_str(s: &str) -> Option<Theme> {
    match s.trim().to_ascii_lowercase().as_str() {
        "light" => Some(Theme::Light),
        "dark" => Some(Theme::Dark),
        _ => None,
    }
}

/// Resolve the terminal theme from `CS_TERM_THEME`. The `cs` wrapper detects the
/// background (OSC 11 with tmux DCS passthrough, macOS appearance, then
/// `COLORFGBG`) while it still owns the tty and exports the result before
/// launching the picker. Falls back to dark when unset or unrecognized.
pub fn detect_theme() -> Theme {
    std::env::var("CS_TERM_THEME")
        .ok()
        .and_then(|v| theme_from_str(&v))
        .unwrap_or(Theme::Dark)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn none_returns_comment() {
        let p = Palette::dark();
        assert_eq!(p.recency_color(None), p.comment);
    }

    #[test]
    fn just_now_returns_fg() {
        let p = Palette::dark();
        assert_eq!(p.recency_color(Some(SystemTime::now())), p.fg);
    }

    #[test]
    fn future_timestamp_returns_fg() {
        let p = Palette::dark();
        let future = SystemTime::now() + Duration::from_secs(3600);
        assert_eq!(p.recency_color(Some(future)), p.fg);
    }

    #[test]
    fn two_hours_ago_is_between_fg_and_comment() {
        let p = Palette::dark();
        let ts = SystemTime::now() - Duration::from_secs(2 * 3600);
        let color = p.recency_color(Some(ts));
        // t=0.25 → lerp(245,161)=224, lerp(230,136)=206, lerp(211,127)=190
        assert_eq!(color, Color::Rgb(224, 206, 190));
    }

    #[test]
    fn three_days_ago() {
        let p = Palette::dark();
        let ts = SystemTime::now() - Duration::from_secs(3 * 86400);
        let color = p.recency_color(Some(ts));
        // t=0.50 → lerp(245,161)=203, lerp(230,136)=183, lerp(211,127)=169
        assert_eq!(color, Color::Rgb(203, 183, 169));
    }

    #[test]
    fn two_weeks_ago() {
        let p = Palette::dark();
        let ts = SystemTime::now() - Duration::from_secs(14 * 86400);
        let color = p.recency_color(Some(ts));
        // t=0.75 → lerp(245,161)=182, lerp(230,136)=159, lerp(211,127)=148
        assert_eq!(color, Color::Rgb(182, 159, 148));
    }

    #[test]
    fn sixty_days_ago_returns_comment() {
        let p = Palette::dark();
        let ts = SystemTime::now() - Duration::from_secs(60 * 86400);
        assert_eq!(p.recency_color(Some(ts)), p.comment);
    }

    #[test]
    fn light_recency_lerps_light_endpoints() {
        let p = Palette::light();
        // fresh → fg (ink), old → comment
        assert_eq!(p.recency_color(Some(SystemTime::now())), p.fg);
        let old = SystemTime::now() - Duration::from_secs(60 * 86400);
        assert_eq!(p.recency_color(Some(old)), p.comment);
    }

    #[test]
    fn heat_color_buckets() {
        let p = Palette::dark();
        let ago = |s: u64| SystemTime::now() - Duration::from_secs(s);
        assert_eq!(p.heat_color(None), p.comment);
        assert_eq!(p.heat_color(Some(ago(60))), p.green); // < 1h → live
        assert_eq!(p.heat_color(Some(ago(5 * 3600))), p.gold); // < 1d
        assert_eq!(p.heat_color(Some(ago(5 * 86400))), p.orange); // < 30d
        assert_eq!(p.heat_color(Some(ago(60 * 86400))), p.comment); // dormant
    }

    #[test]
    fn theme_override_parsing() {
        assert_eq!(theme_from_str("light"), Some(Theme::Light));
        assert_eq!(theme_from_str("DARK"), Some(Theme::Dark));
        assert_eq!(theme_from_str(" Light "), Some(Theme::Light));
        assert_eq!(theme_from_str("auto"), None);
    }

    #[test]
    fn bprime_light_tokens_are_council_values() {
        let p = Palette::light();
        assert_eq!(p.ink, Color::Rgb(43, 33, 24));
        assert_eq!(p.wash, Color::Rgb(255, 240, 218));
        assert_eq!(p.teal, Color::Rgb(15, 118, 110));
        assert_eq!(p.ember, Color::Rgb(216, 90, 36));
        assert_eq!(p.rust, Color::Rgb(183, 71, 34));
        assert_eq!(p.gold, Color::Rgb(176, 132, 40));
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
}
