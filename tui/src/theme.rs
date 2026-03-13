// ABOUTME: Color palette and icon definitions matching the cs bash script theme
// ABOUTME: Provides RGB constants for warm rust/gold/orange palette and Unicode/Nerd Font icons

use ratatui::style::Color;

pub const RED: Color = Color::Rgb(239, 83, 80);
pub const GREEN: Color = Color::Rgb(139, 195, 74);
pub const YELLOW: Color = Color::Rgb(255, 183, 77);
pub const ORANGE: Color = Color::Rgb(255, 138, 101);
pub const GOLD: Color = Color::Rgb(255, 193, 7);
pub const RUST: Color = Color::Rgb(230, 74, 25);
pub const COMMENT: Color = Color::Rgb(161, 136, 127);
pub const WHITE: Color = Color::Rgb(245, 230, 211);

/// Color for metadata columns based on how recently the session was modified.
/// Blends from WHITE (today) through intermediate tones to COMMENT (old).
pub fn recency_color(modified_ts: Option<std::time::SystemTime>) -> Color {
    let ts = match modified_ts {
        Some(t) => t,
        None => return COMMENT,
    };
    let age = match std::time::SystemTime::now().duration_since(ts) {
        Ok(d) => d,
        Err(_) => return WHITE, // future timestamp — treat as fresh
    };
    let secs = age.as_secs();
    const HOUR: u64 = 3600;
    const DAY: u64 = 86400;
    // Buckets: <1h → WHITE, <24h → 75%, <7d → 50%, <30d → 25%, older → COMMENT
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
    // Lerp WHITE → COMMENT
    let lerp = |a: u8, b: u8| -> u8 {
        (a as f32 + t * (b as f32 - a as f32)) as u8
    };
    // WHITE = (245, 230, 211), COMMENT = (161, 136, 127)
    Color::Rgb(lerp(245, 161), lerp(230, 136), lerp(211, 127))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};

    #[test]
    fn none_returns_comment() {
        assert_eq!(recency_color(None), COMMENT);
    }

    #[test]
    fn just_now_returns_white() {
        assert_eq!(recency_color(Some(SystemTime::now())), WHITE);
    }

    #[test]
    fn future_timestamp_returns_white() {
        let future = SystemTime::now() + Duration::from_secs(3600);
        assert_eq!(recency_color(Some(future)), WHITE);
    }

    #[test]
    fn two_hours_ago_is_between_white_and_comment() {
        let ts = SystemTime::now() - Duration::from_secs(2 * 3600);
        let color = recency_color(Some(ts));
        // t=0.25 → lerp(245,161)=224, lerp(230,136)=206, lerp(211,127)=190
        assert_eq!(color, Color::Rgb(224, 206, 190));
    }

    #[test]
    fn three_days_ago() {
        let ts = SystemTime::now() - Duration::from_secs(3 * 86400);
        let color = recency_color(Some(ts));
        // t=0.50 → lerp(245,161)=203, lerp(230,136)=183, lerp(211,127)=169
        assert_eq!(color, Color::Rgb(203, 183, 169));
    }

    #[test]
    fn two_weeks_ago() {
        let ts = SystemTime::now() - Duration::from_secs(14 * 86400);
        let color = recency_color(Some(ts));
        // t=0.75 → lerp(245,161)=182, lerp(230,136)=159, lerp(211,127)=148
        assert_eq!(color, Color::Rgb(182, 159, 148));
    }

    #[test]
    fn sixty_days_ago_returns_comment() {
        let ts = SystemTime::now() - Duration::from_secs(60 * 86400);
        assert_eq!(recency_color(Some(ts)), COMMENT);
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
