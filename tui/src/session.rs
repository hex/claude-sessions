// ABOUTME: Session data model populated by reading the filesystem under SESSIONS_ROOT
// ABOUTME: Scans session directories for metadata files (logs, configs, locks, secrets)

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

pub struct Session {
    pub name: String,
    pub is_adopted: bool,
    pub created: Option<String>,
    pub modified: Option<String>,
    pub location: Option<String>,
    pub is_locked: bool,
    pub secrets_count: u32,
    pub has_git: bool,
    pub git_repo: Option<String>,
    pub sync_auto: Option<bool>,
}

pub fn sessions_root() -> PathBuf {
    std::env::var("CS_SESSIONS_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").expect("HOME not set");
            PathBuf::from(home).join(".claude-sessions")
        })
}

pub fn scan_sessions() -> Vec<Session> {
    let root = sessions_root();
    if !root.is_dir() {
        return Vec::new();
    }

    let secret_counts = count_secrets_from_keychain();

    let mut sessions: Vec<Session> = match fs::read_dir(&root) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                let ft = e.file_type().ok();
                ft.map(|t| t.is_dir() || t.is_symlink()).unwrap_or(false)
            })
            .map(|e| read_session(&e.path(), &secret_counts))
            .collect(),
        Err(_) => Vec::new(),
    };

    sessions.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    sessions
}

fn read_session(path: &Path, secret_counts: &HashMap<String, u32>) -> Session {
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();

    let is_adopted = path.symlink_metadata().map(|m| m.is_symlink()).unwrap_or(false);

    let meta_dir = path.join(".cs");
    let log_file = find_log_file(path);

    let created = log_file.as_ref().and_then(|f| parse_created(f));
    let modified = log_file.as_ref().and_then(|f| parse_modified(f));
    let location = parse_remote_conf(&meta_dir);
    let is_locked = check_lock(&meta_dir);
    let secrets_count = secret_counts.get(&name).copied().unwrap_or(0);
    let has_git = path.join(".git").is_dir();
    let git_repo = if has_git {
        parse_git_remote(path)
    } else {
        None
    };
    let sync_auto = parse_sync_conf(&meta_dir);

    Session {
        name,
        is_adopted,
        created,
        modified,
        location,
        is_locked,
        secrets_count,
        has_git,
        git_repo,
        sync_auto,
    }
}

fn find_log_file(session_dir: &Path) -> Option<PathBuf> {
    let primary = session_dir.join(".cs/logs/session.log");
    if primary.is_file() {
        return Some(primary);
    }
    let fallback = session_dir.join("logs/session.log");
    if fallback.is_file() {
        return Some(fallback);
    }
    None
}

fn parse_created(log_file: &Path) -> Option<String> {
    let content = fs::read_to_string(log_file).ok()?;
    let mut lines = content.lines();

    // Read up to 4 lines looking for "Started: YYYY-MM-DD HH:MM:SS"
    for _ in 0..4 {
        if let Some(line) = lines.next() {
            if let Some(timestamp) = line.strip_prefix("Started: ") {
                return trim_timestamp(timestamp);
            }
        }
    }

    // Fallback: parse "YYYY-MM-DD HH:MM:SS" from first line
    let first_line = content.lines().next()?;
    if first_line.len() >= 19 {
        let candidate = &first_line[..19];
        if is_timestamp_format(candidate) {
            return trim_timestamp(candidate);
        }
    }

    None
}

fn trim_timestamp(ts: &str) -> Option<String> {
    let trimmed = ts.trim();
    if trimmed.len() >= 16 {
        Some(trimmed[..16].to_string())
    } else {
        Some(trimmed.to_string())
    }
}

fn is_timestamp_format(s: &str) -> bool {
    // Match YYYY-MM-DD HH:MM:SS
    let bytes = s.as_bytes();
    bytes.len() >= 19
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b' '
        && bytes[13] == b':'
        && bytes[16] == b':'
}

fn parse_modified(log_file: &Path) -> Option<String> {
    let metadata = fs::metadata(log_file).ok()?;
    let mtime = metadata.modified().ok()?;
    let duration = mtime.duration_since(std::time::UNIX_EPOCH).ok()?;
    let secs = duration.as_secs() as i64;

    // Format as YYYY-MM-DD HH:MM without external crates
    let (year, month, day, hour, minute) = unix_to_datetime(secs);
    Some(format!("{:04}-{:02}-{:02} {:02}:{:02}", year, month, day, hour, minute))
}

fn unix_to_datetime(timestamp: i64) -> (i64, u32, u32, u32, u32) {
    // Account for local timezone offset
    let offset = local_utc_offset_secs();
    let ts = timestamp + offset;

    let secs_per_day: i64 = 86400;
    let days = ts.div_euclid(secs_per_day);
    let day_secs = ts.rem_euclid(secs_per_day) as u32;

    let hour = day_secs / 3600;
    let minute = (day_secs % 3600) / 60;

    // Days since 1970-01-01 to Y-M-D (civil calendar)
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    (y, m, d, hour, minute)
}

fn local_utc_offset_secs() -> i64 {
    // Use the C localtime to get the UTC offset
    // This avoids depending on chrono just for timezone
    #[cfg(unix)]
    {
        extern "C" {
            fn time(t: *mut i64) -> i64;
            fn localtime_r(timep: *const i64, result: *mut Tm) -> *mut Tm;
        }

        #[repr(C)]
        struct Tm {
            tm_sec: i32,
            tm_min: i32,
            tm_hour: i32,
            tm_mday: i32,
            tm_mon: i32,
            tm_year: i32,
            tm_wday: i32,
            tm_yday: i32,
            tm_isdst: i32,
            tm_gmtoff: i64,
            _tm_zone: *const u8,
        }

        unsafe {
            let mut now: i64 = 0;
            time(&mut now);
            let mut tm = std::mem::zeroed::<Tm>();
            localtime_r(&now, &mut tm);
            tm.tm_gmtoff
        }
    }
    #[cfg(not(unix))]
    {
        0
    }
}

fn parse_remote_conf(meta_dir: &Path) -> Option<String> {
    let conf = meta_dir.join("remote.conf");
    let content = fs::read_to_string(conf).ok()?;
    for line in content.lines() {
        if let Some(host) = line.strip_prefix("host=") {
            let host = host.trim();
            if !host.is_empty() {
                return Some(host.to_string());
            }
        }
    }
    None
}

fn check_lock(meta_dir: &Path) -> bool {
    let lock_file = meta_dir.join("session.lock");
    if let Ok(content) = fs::read_to_string(&lock_file) {
        if let Ok(pid) = content.trim().parse::<u32>() {
            return is_pid_alive(pid);
        }
    }
    false
}

fn is_pid_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn parse_sync_conf(meta_dir: &Path) -> Option<bool> {
    let conf = meta_dir.join("sync.conf");
    let content = fs::read_to_string(conf).ok()?;
    for line in content.lines() {
        if let Some(val) = line.strip_prefix("auto_sync=") {
            return Some(val.trim() == "on");
        }
    }
    None
}

fn parse_git_remote(session_dir: &Path) -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["-C", &session_dir.to_string_lossy(), "remote", "get-url", "origin"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
    extract_user_repo(&url)
}

fn extract_user_repo(url: &str) -> Option<String> {
    // Handle: git@github.com:user/repo.git
    if let Some(rest) = url.strip_prefix("git@") {
        if let Some(path) = rest.split(':').nth(1) {
            let path = path.strip_suffix(".git").unwrap_or(path);
            return Some(path.to_string());
        }
    }
    // Handle: https://github.com/user/repo.git
    if let Some(idx) = url.find("github.com/") {
        let path = &url[idx + "github.com/".len()..];
        let path = path.strip_suffix(".git").unwrap_or(path);
        let path = path.strip_suffix('/').unwrap_or(path);
        return Some(path.to_string());
    }
    // Other URLs: return as-is, truncated
    if !url.is_empty() {
        Some(url.to_string())
    } else {
        None
    }
}

fn count_secrets_from_keychain() -> HashMap<String, u32> {
    let mut counts = HashMap::new();

    let output = std::process::Command::new("security")
        .args(["dump-keychain"])
        .stderr(std::process::Stdio::null())
        .output();

    if let Ok(output) = output {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            // Match: "svce"<blob>="cs:session_name:secret_name"
            if let Some(rest) = line.strip_prefix("    \"svce\"<blob>=\"cs:") {
                if let Some(session) = rest.split(':').next() {
                    *counts.entry(session.to_string()).or_insert(0) += 1;
                }
            }
        }
    }

    counts
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn setup_session(root: &Path, name: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(dir.join(".cs/logs")).unwrap();
        fs::write(
            dir.join(".cs/logs/session.log"),
            "Claude Code Session Log\nSession: test\nStarted: 2026-01-15 10:30:00\n",
        )
        .unwrap();
        dir
    }

    #[test]
    fn parse_created_from_started_line() {
        let dir = std::env::temp_dir().join(format!("cs-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("session.log");
        fs::write(
            &log,
            "Claude Code Session Log\nSession: test\nStarted: 2026-01-15 10:30:00\n",
        )
        .unwrap();

        let result = parse_created(&log);
        assert_eq!(result, Some("2026-01-15 10:30".to_string()));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_created_from_timestamp_first_line() {
        let dir = std::env::temp_dir().join(format!("cs-test-ts-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("session.log");
        fs::write(&log, "2026-02-01 14:22:33 - Session started\n").unwrap();

        let result = parse_created(&log);
        assert_eq!(result, Some("2026-02-01 14:22".to_string()));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_created_returns_none_for_empty_file() {
        let dir = std::env::temp_dir().join(format!("cs-test-empty-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("session.log");
        fs::write(&log, "").unwrap();

        let result = parse_created(&log);
        assert_eq!(result, None);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_remote_conf_extracts_host() {
        let dir = std::env::temp_dir().join(format!("cs-test-remote-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("remote.conf"), "host=hex@mac-mini.local\n").unwrap();

        let result = parse_remote_conf(&dir);
        assert_eq!(result, Some("hex@mac-mini.local".to_string()));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_remote_conf_returns_none_when_missing() {
        let dir = std::env::temp_dir().join(format!("cs-test-noremote-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        let result = parse_remote_conf(&dir);
        assert_eq!(result, None);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_sync_conf_reads_auto_setting() {
        let dir = std::env::temp_dir().join(format!("cs-test-sync-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("sync.conf"), "auto_sync=on\n").unwrap();

        assert_eq!(parse_sync_conf(&dir), Some(true));

        fs::write(dir.join("sync.conf"), "auto_sync=off\n").unwrap();
        assert_eq!(parse_sync_conf(&dir), Some(false));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn check_lock_returns_false_for_missing_file() {
        let dir = std::env::temp_dir().join(format!("cs-test-nolock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        assert!(!check_lock(&dir));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn check_lock_returns_false_for_stale_pid() {
        let dir = std::env::temp_dir().join(format!("cs-test-stalelock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        // PID 99999999 almost certainly doesn't exist
        fs::write(dir.join("session.lock"), "99999999").unwrap();

        assert!(!check_lock(&dir));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn check_lock_returns_true_for_own_pid() {
        let dir = std::env::temp_dir().join(format!("cs-test-livelock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("session.lock"),
            std::process::id().to_string(),
        )
        .unwrap();

        assert!(check_lock(&dir));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn scan_sessions_discovers_directories() {
        let root = std::env::temp_dir().join(format!("cs-test-scan-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();

        setup_session(&root, "alpha");
        setup_session(&root, "beta");

        std::env::set_var("CS_SESSIONS_ROOT", &root);
        let sessions = scan_sessions();
        std::env::remove_var("CS_SESSIONS_ROOT");

        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].name, "alpha");
        assert_eq!(sessions[1].name, "beta");
        assert_eq!(sessions[0].created, Some("2026-01-15 10:30".to_string()));

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn scan_sessions_returns_empty_for_missing_root() {
        std::env::set_var("CS_SESSIONS_ROOT", "/tmp/cs-nonexistent-dir-12345");
        let sessions = scan_sessions();
        std::env::remove_var("CS_SESSIONS_ROOT");

        assert!(sessions.is_empty());
    }

    #[test]
    fn is_timestamp_format_validates_correctly() {
        assert!(is_timestamp_format("2026-01-15 10:30:00"));
        assert!(!is_timestamp_format("not a timestamp"));
        assert!(!is_timestamp_format("short"));
    }

    #[test]
    fn trim_timestamp_trims_to_minutes() {
        assert_eq!(
            trim_timestamp("2026-01-15 10:30:00"),
            Some("2026-01-15 10:30".to_string())
        );
        assert_eq!(
            trim_timestamp("2026-01-15 10:30"),
            Some("2026-01-15 10:30".to_string())
        );
    }

    #[test]
    fn extract_user_repo_from_ssh_url() {
        assert_eq!(
            extract_user_repo("git@github.com:hex/claude-sessions.git"),
            Some("hex/claude-sessions".to_string())
        );
    }

    #[test]
    fn extract_user_repo_from_https_url() {
        assert_eq!(
            extract_user_repo("https://github.com/hex/claude-sessions.git"),
            Some("hex/claude-sessions".to_string())
        );
        assert_eq!(
            extract_user_repo("https://github.com/hex/claude-sessions"),
            Some("hex/claude-sessions".to_string())
        );
    }

    #[test]
    fn extract_user_repo_from_non_github_url() {
        assert_eq!(
            extract_user_repo("https://gitlab.com/user/repo.git"),
            Some("https://gitlab.com/user/repo.git".to_string())
        );
    }

    #[test]
    fn extract_user_repo_empty_returns_none() {
        assert_eq!(extract_user_repo(""), None);
    }
}
