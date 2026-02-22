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

pub struct Icons {
    pub lock: &'static str,
    pub remote: &'static str,
}

pub fn icons() -> Icons {
    if std::env::var("CS_NERD_FONTS").as_deref() == Ok("1") {
        Icons {
            lock: "\u{f0192}",
            remote: "\u{f0318}",
        }
    } else {
        Icons {
            lock: "\u{26bf}",
            remote: "\u{21dd}",
        }
    }
}
