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
    pub modified_ts: Option<std::time::SystemTime>,
    pub lock_pid: Option<u32>,
    pub is_locked: bool,
    pub secrets_count: u32,
    pub queue_depth: u32,
    pub git_repo: Option<String>,
}

pub struct SessionPreview {
    pub objective: Option<String>,
    pub last_discovery: Option<String>,
    pub artifact_count: usize,
    /// Last N discovery headings (most recent first) for preview pane.
    pub discoveries: Vec<String>,
    /// Artifact file names for preview pane.
    pub artifact_names: Vec<String>,
    /// First few lines from auto memory MEMORY.md.
    pub memory_entries: Vec<String>,
    /// "<author> (<n>)" lines from git history over .cs/memory, most active first.
    pub contributors: Vec<String>,
}

/// Load preview info for a session by reading .cs/ metadata files.
pub fn load_preview(session_dir: &Path) -> SessionPreview {
    let cs_dir = session_dir.join(".cs");

    // First non-empty line from README.md after "## Objective" or first content line
    let objective = fs::read_to_string(cs_dir.join("README.md"))
        .ok()
        .and_then(|content| {
            let mut after_objective = false;
            for line in content.lines() {
                if line.starts_with("## Objective") {
                    after_objective = true;
                    continue;
                }
                if after_objective {
                    // End of the Objective section without real content.
                    if line.starts_with("## ") {
                        return None;
                    }
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        // The README template seeds a bracketed placeholder
                        // (`[Describe ...]`); treat any whole-line `[...]` as
                        // "not filled in", matching the session-start hook.
                        if trimmed.starts_with('[') && trimmed.ends_with(']') {
                            return None;
                        }
                        return Some(trimmed.to_string());
                    }
                }
            }
            None
        });

    // Narrative headings from memory/narrative.md (all ## headings, most recent last in file)
    let (last_discovery, discoveries) = fs::read_to_string(cs_dir.join("memory/narrative.md"))
        .ok()
        .map(|content| {
            let headings: Vec<String> = content
                .lines()
                .filter(|line| line.starts_with("## "))
                .map(|line| line.trim_start_matches("## ").to_string())
                .collect();
            let last = headings.last().cloned();
            // Last 4 discoveries, most recent first
            let recent: Vec<String> = headings.into_iter().rev().take(4).collect();
            (last, recent)
        })
        .unwrap_or((None, Vec::new()));

    // Artifacts from MANIFEST.json
    let (artifact_count, artifact_names) = fs::read_to_string(cs_dir.join("artifacts/MANIFEST.json"))
        .ok()
        .map(|content| {
            let count = content.matches("\"path\"").count();
            // Extract path values: naive parse for "path":"<value>"
            let names: Vec<String> = content
                .split("\"path\"")
                .skip(1)
                .filter_map(|chunk| {
                    // Find the next quoted value after the colon
                    let rest = chunk.trim_start().strip_prefix(':')?;
                    let rest = rest.trim_start().strip_prefix('"')?;
                    let end = rest.find('"')?;
                    Some(rest[..end].to_string())
                })
                .collect();
            (count, names)
        })
        .unwrap_or((0, Vec::new()));

    // Memory entries from .cs/memory/MEMORY.md (first few non-empty lines)
    let memory_entries = fs::read_to_string(cs_dir.join("memory/MEMORY.md"))
        .ok()
        .map(|content| {
            content
                .lines()
                .filter(|line| !line.trim().is_empty())
                .take(5)
                .map(|line| line.to_string())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let contributors = load_contributors(session_dir);

    SessionPreview {
        objective,
        last_discovery,
        artifact_count,
        discoveries,
        artifact_names,
        memory_entries,
        contributors,
    }
}

pub fn sessions_root() -> PathBuf {
    std::env::var("CS_SESSIONS_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").expect("HOME not set");
            PathBuf::from(home).join(".claude-sessions")
        })
}

/// Directory holding a session's per-machine queue files (`.cs/local`).
pub fn queue_dir(name: &str) -> PathBuf {
    sessions_root().join(name).join(".cs").join("local")
}

/// The highlighted session's queued tasks, one per non-blank line, in order.
/// Read fresh from disk so callers always see the latest queue.
pub fn read_queue(name: &str) -> Vec<String> {
    let path = queue_dir(name).join("queue");
    fs::read_to_string(path)
        .map(|text| {
            text.lines()
                .filter(|line| !line.trim().is_empty())
                .map(|line| line.to_string())
                .collect()
        })
        .unwrap_or_default()
}

pub fn scan_sessions() -> Vec<Session> {
    scan_sessions_in(&sessions_root())
}

/// Scan a specific sessions root. Tests call this directly so they never have to
/// mutate the process-global `CS_SESSIONS_ROOT` (which races across parallel tests).
fn scan_sessions_in(root: &Path) -> Vec<Session> {
    if !root.is_dir() {
        return Vec::new();
    }

    let secret_counts = count_secrets_from_keychain();

    // Collect candidate session dirs first, then read them in parallel. Each
    // git-repo session forks `git remote get-url origin`; doing ~50 of those
    // serially dominated startup. read_session is pure (its only shared state
    // is the read-only secret_counts), so it parallelizes cleanly across a
    // bounded worker pool.
    let paths: Vec<PathBuf> = match fs::read_dir(root) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                // Skip hidden dirs (.obsidian, .git, …) — never cs sessions.
                if e.file_name().to_string_lossy().starts_with('.') {
                    return false;
                }
                let ft = e.file_type().ok();
                ft.map(|t| t.is_dir() || t.is_symlink()).unwrap_or(false)
            })
            .map(|e| e.path())
            .collect(),
        Err(_) => return Vec::new(),
    };

    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(paths.len().max(1));

    let mut sessions: Vec<Session> = if workers <= 1 {
        paths.iter().map(|p| read_session(p, &secret_counts)).collect()
    } else {
        let secret_counts = &secret_counts;
        let chunk_size = (paths.len() + workers - 1) / workers;
        std::thread::scope(|scope| {
            let handles: Vec<_> = paths
                .chunks(chunk_size)
                .map(|chunk| {
                    scope.spawn(move || {
                        chunk
                            .iter()
                            .map(|p| read_session(p, secret_counts))
                            .collect::<Vec<Session>>()
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap_or_default())
                .collect()
        })
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
    let (modified, modified_ts) = log_file
        .as_ref()
        .map(|f| parse_modified(f))
        .unwrap_or((None, None));
    let lock_pid = read_lock_pid(&meta_dir);
    let is_locked = lock_pid.is_some();
    let secrets_count = secret_counts.get(&name).copied().unwrap_or(0);
    let queue_depth = fs::read_to_string(meta_dir.join("local/queue"))
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count() as u32)
        .unwrap_or(0);
    let has_git = path.join(".git").is_dir();
    let git_repo = if has_git {
        parse_git_remote(path)
    } else {
        None
    };

    Session {
        name,
        is_adopted,
        created,
        modified,
        modified_ts,
        lock_pid,
        is_locked,
        secrets_count,
        queue_depth,
        git_repo,
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

fn parse_modified(log_file: &Path) -> (Option<String>, Option<std::time::SystemTime>) {
    let metadata = match fs::metadata(log_file).ok() {
        Some(m) => m,
        None => return (None, None),
    };
    let mtime = match metadata.modified().ok() {
        Some(t) => t,
        None => return (None, None),
    };
    let duration = match mtime.duration_since(std::time::UNIX_EPOCH).ok() {
        Some(d) => d,
        None => return (None, Some(mtime)),
    };
    let secs = duration.as_secs() as i64;

    // Format as YYYY-MM-DD HH:MM without external crates
    let (year, month, day, hour, minute) = unix_to_datetime(secs);
    let formatted = format!("{:04}-{:02}-{:02} {:02}:{:02}", year, month, day, hour, minute);
    (Some(formatted), Some(mtime))
}

/// Compact human duration since `ts` ("now", "45m", "5h", "6d", "4w", "6mo", "2y").
/// Future timestamps clamp to "now". The list trades exactness for scannability;
/// the preview pane still shows the full `YYYY-MM-DD HH:MM` modified time.
pub fn relative_age(ts: std::time::SystemTime, now: std::time::SystemTime) -> String {
    let secs = match now.duration_since(ts) {
        Ok(d) => d.as_secs(),
        Err(_) => return "now".to_string(),
    };
    const MIN: u64 = 60;
    const HOUR: u64 = 3600;
    const DAY: u64 = 86400;
    const WEEK: u64 = 7 * DAY;
    if secs < MIN {
        "now".to_string()
    } else if secs < HOUR {
        format!("{}m", secs / MIN)
    } else if secs < DAY {
        format!("{}h", secs / HOUR)
    } else if secs < WEEK {
        format!("{}d", secs / DAY)
    } else if secs < 35 * DAY {
        format!("{}w", secs / WEEK)
    } else if secs < 365 * DAY {
        format!("{}mo", secs / (30 * DAY))
    } else {
        format!("{}y", secs / (365 * DAY))
    }
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

fn read_lock_pid(meta_dir: &Path) -> Option<u32> {
    let lock_file = meta_dir.join("session.lock");
    let content = fs::read_to_string(&lock_file).ok()?;
    let pid = content.trim().parse::<u32>().ok()?;
    if is_pid_alive(pid) { Some(pid) } else { None }
}

fn is_pid_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn load_contributors(session_dir: &Path) -> Vec<String> {
    if !session_dir.join(".git").is_dir() {
        return Vec::new();
    }
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(session_dir)
        .args(["log", "--format=%an", "--", ".cs/memory"])
        .output();
    let stdout = match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return Vec::new(),
    };
    let mut counts: HashMap<String, usize> = HashMap::new();
    for line in stdout.lines() {
        let name = line.trim();
        if name.is_empty() {
            continue;
        }
        *counts.entry(name.to_string()).or_insert(0) += 1;
    }
    let mut pairs: Vec<(String, usize)> = counts.into_iter().collect();
    pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    pairs.into_iter().map(|(name, n)| format!("{} ({})", name, n)).collect()
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
    use std::time::Duration;

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
    fn relative_age_buckets() {
        let now = std::time::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        let ago = |secs: u64| now - Duration::from_secs(secs);
        assert_eq!(relative_age(ago(5), now), "now");
        assert_eq!(relative_age(ago(59), now), "now");
        assert_eq!(relative_age(ago(60), now), "1m");
        assert_eq!(relative_age(ago(45 * 60), now), "45m");
        assert_eq!(relative_age(ago(3600), now), "1h");
        assert_eq!(relative_age(ago(5 * 3600), now), "5h");
        assert_eq!(relative_age(ago(86400), now), "1d");
        assert_eq!(relative_age(ago(6 * 86400), now), "6d");
        assert_eq!(relative_age(ago(7 * 86400), now), "1w");
        assert_eq!(relative_age(ago(34 * 86400), now), "4w");
        assert_eq!(relative_age(ago(35 * 86400), now), "1mo");
        assert_eq!(relative_age(ago(200 * 86400), now), "6mo");
        assert_eq!(relative_age(ago(365 * 86400), now), "1y");
        assert_eq!(relative_age(ago(800 * 86400), now), "2y");
        // Future timestamps clamp to "now" rather than underflowing.
        assert_eq!(relative_age(now + Duration::from_secs(3600), now), "now");
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
    fn read_lock_pid_returns_none_for_missing_file() {
        let dir = std::env::temp_dir().join(format!("cs-test-nolock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        assert_eq!(read_lock_pid(&dir), None);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn read_lock_pid_returns_none_for_stale_pid() {
        let dir = std::env::temp_dir().join(format!("cs-test-stalelock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        // PID 99999999 almost certainly doesn't exist
        fs::write(dir.join("session.lock"), "99999999").unwrap();

        assert_eq!(read_lock_pid(&dir), None);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn read_lock_pid_returns_pid_for_live_process() {
        let dir = std::env::temp_dir().join(format!("cs-test-livelock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let own_pid = std::process::id();
        fs::write(
            dir.join("session.lock"),
            own_pid.to_string(),
        )
        .unwrap();

        assert_eq!(read_lock_pid(&dir), Some(own_pid));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn scan_sessions_discovers_directories() {
        let root = std::env::temp_dir().join(format!("cs-test-scan-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();

        setup_session(&root, "alpha");
        setup_session(&root, "beta");

        let sessions = scan_sessions_in(&root);

        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].name, "alpha");
        assert_eq!(sessions[1].name, "beta");
        assert_eq!(sessions[0].created, Some("2026-01-15 10:30".to_string()));

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn scan_sessions_returns_empty_for_missing_root() {
        let sessions = scan_sessions_in(Path::new("/tmp/cs-nonexistent-dir-12345"));
        assert!(sessions.is_empty());
    }

    #[test]
    fn scan_sessions_skips_hidden_dirs() {
        let root = std::env::temp_dir().join(format!("cs-test-hidden-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        setup_session(&root, "real-session");
        // Hidden dirs that are not cs sessions (Obsidian vault, git metadata).
        fs::create_dir_all(root.join(".obsidian")).unwrap();
        fs::create_dir_all(root.join(".git")).unwrap();

        let sessions = scan_sessions_in(&root);

        assert_eq!(sessions.len(), 1, "only the real session should be listed");
        assert_eq!(sessions[0].name, "real-session");

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn scan_counts_queue_depth() {
        let tmp = std::env::temp_dir().join(format!("cs-qd-{}", std::process::id()));
        let root = tmp.as_path();
        setup_session(root, "beta");
        let local = root.join("beta").join(".cs/local");
        std::fs::create_dir_all(&local).unwrap();
        std::fs::write(local.join("queue"), "t1\nt2\nt3\n").unwrap();
        let sessions = scan_sessions_in(root);
        let beta = sessions.iter().find(|s| s.name == "beta").unwrap();
        assert_eq!(beta.queue_depth, 3);
        std::fs::remove_dir_all(&tmp).ok();
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

    // --- load_preview tests ---

    #[test]
    fn load_preview_reads_objective() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-obj-{}", std::process::id()));
        let cs = dir.join(".cs");
        fs::create_dir_all(&cs).unwrap();
        fs::write(
            cs.join("README.md"),
            "# Session\n\n## Objective\n\nBuild a TUI for session management\n\n## Outcome\n",
        )
        .unwrap();

        let preview = load_preview(&dir);
        assert_eq!(
            preview.objective.as_deref(),
            Some("Build a TUI for session management")
        );
        assert!(preview.last_discovery.is_none());
        assert_eq!(preview.artifact_count, 0);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_suppresses_objective_placeholder() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-ph-{}", std::process::id()));
        let cs = dir.join(".cs");
        fs::create_dir_all(&cs).unwrap();
        // The unedited README template — its bracketed placeholder is not a real
        // objective and must not surface in the preview.
        fs::write(
            cs.join("README.md"),
            "# Session\n\n## Objective\n\n[Describe what you're trying to accomplish in this session]\n\n## Outcome\n\n[Describe the result]\n",
        )
        .unwrap();

        let preview = load_preview(&dir);
        assert!(preview.objective.is_none());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_reads_last_discovery() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-disc-{}", std::process::id()));
        let cs = dir.join(".cs/memory");
        fs::create_dir_all(&cs).unwrap();
        fs::write(
            cs.join("narrative.md"),
            "# Session narrative\n\n## First thing\nSome text\n\n## Second thing\nMore text\n",
        )
        .unwrap();

        let preview = load_preview(&dir);
        assert_eq!(preview.last_discovery.as_deref(), Some("Second thing"));
        // discoveries: most recent first
        assert_eq!(preview.discoveries, vec!["Second thing", "First thing"]);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_counts_artifacts() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-art-{}", std::process::id()));
        let cs = dir.join(".cs/artifacts");
        fs::create_dir_all(&cs).unwrap();
        fs::write(
            cs.join("MANIFEST.json"),
            r#"[{"path":"a.sh"},{"path":"b.py"},{"path":"c.json"}]"#,
        )
        .unwrap();

        let preview = load_preview(&dir);
        assert_eq!(preview.artifact_count, 3);
        assert_eq!(preview.artifact_names, vec!["a.sh", "b.py", "c.json"]);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_handles_missing_files() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-empty-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        let preview = load_preview(&dir);
        assert!(preview.objective.is_none());
        assert!(preview.last_discovery.is_none());
        assert_eq!(preview.artifact_count, 0);
        assert!(preview.discoveries.is_empty());
        assert!(preview.artifact_names.is_empty());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_reads_contributors() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-contrib-{}", std::process::id()));
        let cs = dir.join(".cs/memory");
        fs::create_dir_all(&cs).unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git").arg("-C").arg(&dir).args(args).output().unwrap();
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "a@b.c"]);
        run(&["config", "user.name", "Alice"]);
        fs::write(cs.join("m1.md"), "one").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-q", "-m", "m1"]);
        fs::write(cs.join("m2.md"), "two").unwrap();
        run(&["add", "-A"]);
        run(&["commit", "-q", "-m", "m2", "--author=Bob <bob@x.io>"]);

        let preview = load_preview(&dir);
        assert!(preview.contributors.iter().any(|c| c.contains("Alice")));
        assert!(preview.contributors.iter().any(|c| c.contains("Bob")));

        fs::remove_dir_all(&dir).unwrap();
    }
}
