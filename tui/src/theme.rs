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
    /// Remote session names.
    pub remote: Color,
    /// Alternating row background.
    pub zebra: Color,
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
            remote: Color::Cyan,
            zebra: Color::Rgb(32, 29, 28),
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
            remote: Color::Rgb(64, 124, 130),
            zebra: Color::Rgb(238, 232, 224),
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
        let (fr, fg_, fb) = rgb_of(self.fg);
        let (cr, cg, cb) = rgb_of(self.comment);
        let lerp = |a: u8, b: u8| -> u8 { (a as f32 + t * (b as f32 - a as f32)) as u8 };
        Color::Rgb(lerp(fr, cr), lerp(fg_, cg), lerp(fb, cb))
    }
}

/// Extract RGB components from a `Color::Rgb`, falling back to a neutral grey.
pub fn rgb_of(c: Color) -> (u8, u8, u8) {
    match c {
        Color::Rgb(r, g, b) => (r, g, b),
        _ => (128, 128, 128),
    }
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
    fn theme_override_parsing() {
        assert_eq!(theme_from_str("light"), Some(Theme::Light));
        assert_eq!(theme_from_str("DARK"), Some(Theme::Dark));
        assert_eq!(theme_from_str(" Light "), Some(Theme::Light));
        assert_eq!(theme_from_str("auto"), None);
    }
}

pub struct Icons {
    pub lock: &'static str,
    pub remote: &'static str,
}

pub fn icons() -> Icons {
    if std::env::var("CS_NERD_FONTS").as_deref() == Ok("1") {
        Icons {
            lock: "\u{f033e}",
            remote: "\u{f0318}",
        }
    } else {
        Icons {
            lock: "\u{26bf}",
            remote: "\u{21dd}",
        }
    }
}
