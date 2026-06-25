// ABOUTME: Color palette and icon definitions matching the cs bash script theme
// ABOUTME: Provides light/dark palettes keyed off CS_TERM_THEME and Unicode/Nerd Font icons

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
    /// Alternating row background.
    pub zebra: Color,
    /// Selected-row background — one elevation step warmer/lighter than zebra.
    pub sel_bg: Color,
    /// Header band background gradient stops (left → right): rust → orange → amber.
    pub header_bg_lo: Color,
    pub header_bg_mid: Color,
    pub header_bg_hi: Color,
    /// Header label text — near-white, sits on the saturated band.
    pub header_fg: Color,
    pub flash_success: Color,
    pub flash_error: Color,
    /// Column separator glyphs.
    pub sep: Color,
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
            zebra: Color::Rgb(32, 29, 28),
            sel_bg: Color::Rgb(60, 46, 36),
            header_bg_lo: Color::Rgb(221, 80, 20),
            header_bg_mid: Color::Rgb(237, 128, 0),
            header_bg_hi: Color::Rgb(246, 154, 0),
            header_fg: Color::Rgb(252, 250, 246),
            flash_success: Color::Rgb(30, 50, 30),
            flash_error: Color::Rgb(55, 25, 25),
            sep: Color::Rgb(50, 45, 42),
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
            gold: Color::Rgb(156, 118, 56),
            rust: Color::Rgb(166, 86, 60),
            zebra: Color::Rgb(238, 232, 224),
            sel_bg: Color::Rgb(231, 215, 195),
            header_bg_lo: Color::Rgb(221, 80, 20),
            header_bg_mid: Color::Rgb(237, 128, 0),
            header_bg_hi: Color::Rgb(246, 154, 0),
            header_fg: Color::Rgb(252, 250, 246),
            flash_success: Color::Rgb(214, 236, 206),
            flash_error: Color::Rgb(246, 214, 210),
            sep: Color::Rgb(216, 207, 196),
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

    /// A point on a rust↔gold triangle wave for the selected-row shimmer.
    /// `phase` is expected in [0, 1); the wave peaks at gold around phase 0.5.
    pub fn shimmer_color(&self, phase: f32) -> Color {
        let tri = if phase < 0.5 { phase * 2.0 } else { (1.0 - phase) * 2.0 };
        let (r, g, b) = lerp_rgb(rgb_of(self.rust), rgb_of(self.gold), tri);
        Color::Rgb(r, g, b)
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
    fn shimmer_endpoints_are_rust_and_gold() {
        let p = Palette::dark();
        assert_eq!(p.shimmer_color(0.0), p.rust); // trough → rust
        assert_eq!(p.shimmer_color(0.5), p.gold); // peak → gold
    }

    #[test]
    fn theme_override_parsing() {
        assert_eq!(theme_from_str("light"), Some(Theme::Light));
        assert_eq!(theme_from_str("DARK"), Some(Theme::Dark));
        assert_eq!(theme_from_str(" Light "), Some(Theme::Light));
        assert_eq!(theme_from_str("auto"), None);
    }
}

pub struct Icons {
    pub lock: &'static str,
    /// Glyph shown before a Github repository slug.
    pub branch: &'static str,
}

pub fn icons() -> Icons {
    if std::env::var("CS_NERD_FONTS").as_deref() == Ok("1") {
        Icons {
            lock: "\u{f033e}",
            branch: "\u{e0a0}",
        }
    } else {
        Icons {
            lock: "\u{26bf}",
            branch: "\u{2387}",
        }
    }
}
