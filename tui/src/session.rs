// ABOUTME: Session data model populated by reading the filesystem under SESSIONS_ROOT
// ABOUTME: Scans session directories for metadata files (logs, configs, locks, secrets)

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::untracked;

/// Whether a session is running, and whether cs owns the lock. Collapsing the
/// old `lock_pid`/`is_locked`/`is_live` trio into one value keeps the illegal
/// "locked but not live" combination unrepresentable.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Liveness {
    /// cs holds the process lock; the PID is the running conversation.
    Locked(u32),
    /// `cs <name> --remote` serves the session through a `claude
    /// remote-control` server: `lock` is the pid in the session lock, `server`
    /// the pid in `.cs/local/remote.pid`. cs execs the server, so both name
    /// the same process; each is read from its own file.
    Served { lock: u32, server: u32 },
    /// No lock, but the statusline touched `.cs/local/context-pct` within the
    /// heartbeat window — a conversation opened outside cs.
    Heartbeat,
    /// Neither locked nor breathing.
    Dormant,
}

impl Liveness {
    /// True on any live surface (locked or breathing).
    pub fn is_live(self) -> bool {
        !matches!(self, Liveness::Dormant)
    }
    /// True only when cs holds the process lock (not merely heartbeat-live).
    pub fn is_locked(self) -> bool {
        matches!(self, Liveness::Locked(_) | Liveness::Served { .. })
    }
    /// The locking process's PID, if cs holds the lock.
    pub fn lock_pid(self) -> Option<u32> {
        match self {
            Liveness::Locked(pid) | Liveness::Served { lock: pid, .. } => Some(pid),
            Liveness::Heartbeat | Liveness::Dormant => None,
        }
    }
}

#[derive(Clone)]
pub struct Session {
    pub name: String,
    pub is_adopted: bool,
    pub created: Option<String>,
    pub modified: Option<String>,
    pub modified_ts: Option<std::time::SystemTime>,
    /// Locked (cs owns the process), breathing via the statusline heartbeat (a
    /// conversation opened outside cs touches context-pct while active), or
    /// dormant.
    pub liveness: Liveness,
    /// What Claude Code says the session is doing right now ("busy", "waiting"),
    /// absent when it publishes no record for this name.
    pub agent_status: Option<String>,
    pub secrets_count: u32,
    pub queue_depth: u32,
    /// Unread cross-session mail: documents sitting in the maildir's `new/`.
    pub unread_mail: u32,
    pub git_repo: Option<String>,
    pub tags: Vec<String>,
    pub archived: bool,
    /// Present only for a session tagged `encrypted`: whether its vault is
    /// mounted right now.
    pub vault: Option<Vault>,
    /// The README's Objective line, so `/` search reaches what a session is
    /// about when its name does not say (an adopted project named by its
    /// folder, a harness-named worktree). None while the placeholder stands.
    pub objective: Option<String>,
}

/// The tag a session carries in its README frontmatter to declare that it
/// keeps its notes in an encrypted volume.
pub const ENCRYPTED_TAG: &str = "encrypted";

/// The marker drawn beside an encrypted session: a Nerd Font lock once this
/// machine has confirmed its font draws private-use glyphs (the statusline's
/// caps consent, `CS_STATUSLINE_CAPS` overriding the answer file), else a word.
/// KEEP IN SYNC with `_caps_wanted` and ICON_LOCK in bin/cs-statusline.
pub fn lock_marker() -> &'static str {
    let env = std::env::var("CS_STATUSLINE_CAPS").ok();
    let config = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")));
    let answer = config
        .ok()
        .and_then(|dir| fs::read_to_string(dir.join("cs/statusline-caps")).ok());
    lock_marker_for(env.as_deref(), answer.as_deref())
}

fn lock_marker_for(env: Option<&str>, caps_file: Option<&str>) -> &'static str {
    let wanted = match env {
        Some("1") => true,
        Some("0") => false,
        _ => caps_file.and_then(|f| f.lines().next()) == Some("on"),
    };
    if wanted { "\u{f023}" } else { "enc" }
}

/// Whether an encrypted session's volume is mounted. Read from `.cs/memory`,
/// which such a session links into the volume: a link that resolves means
/// mounted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vault {
    Locked,
    Unlocked,
}

/// A pending cs update: the newer version and its release-note summaries as
/// (version, summary) pairs parsed from cs's notes cache. `notes` is empty
/// when the cache is missing or holds a failed-fetch tombstone; the overflow
/// line arrives as a pair whose version field is "+".
pub struct UpdateNotice {
    pub version: String,
    pub notes: Vec<(String, String)>,
}

/// True when dotted calver `a` is newer than `b` (year.month.patch compared
/// numerically fieldwise, mirroring cs's version_greater).
fn version_newer(a: &str, b: &str) -> bool {
    let parse = |v: &str| -> Vec<u64> {
        v.split('.').map(|part| part.parse().unwrap_or(0)).collect()
    };
    let (a, b) = (parse(a), parse(b));
    for i in 0..3 {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

/// Read cs's update caches from `cache_dir`: Some when `update-check` (one
/// line, `<epoch> <version>`) names a version newer than `installed`.
pub fn update_notice_in(cache_dir: &Path, installed: &str) -> Option<UpdateNotice> {
    let line = fs::read_to_string(cache_dir.join("update-check")).ok()?;
    let latest = line.split_whitespace().nth(1)?.to_string();
    if installed.is_empty() || !version_newer(&latest, installed) {
        return None;
    }
    let notes = fs::read_to_string(cache_dir.join(format!("update-notes-{latest}")))
        .map(|text| {
            text.lines()
                .filter_map(|l| l.split_once('\t').map(|(v, s)| (v.to_string(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();
    Some(UpdateNotice { version: latest, notes })
}

/// The user's home directory. None when HOME is unset.
pub(crate) fn home_dir() -> Option<String> {
    std::env::var("HOME").ok()
}

/// The pending-update notice for this process: cs exports CS_VERSION at
/// launch and its own update check maintains ~/.cache/cs.
pub fn update_notice() -> Option<UpdateNotice> {
    let installed = std::env::var("CS_VERSION").ok()?;
    let home = home_dir()?;
    update_notice_in(&PathBuf::from(home).join(".cache").join("cs"), &installed)
}

pub struct SessionPreview {
    pub objective: Option<String>,
    pub last_discovery: Option<String>,
    /// Last N discovery headings (most recent first) for preview pane.
    pub discoveries: Vec<String>,
    /// First few lines from auto memory MEMORY.md.
    pub memory_entries: Vec<String>,
    /// "<author> (<n>)" lines from git history over .cs/memory, most active first.
    pub contributors: Vec<String>,
}

/// The first non-empty line under `## Objective` in a session README. Both the
/// preview pane and the row's searchable objective read it, so the two can
/// never disagree.
pub fn read_objective(readme: &str) -> Option<String> {
    let mut after_objective = false;
    for line in readme.lines() {
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
}

/// Load preview info for a session by reading .cs/ metadata files.
pub fn load_preview(session_dir: &Path) -> SessionPreview {
    let cs_dir = session_dir.join(".cs");

    let objective = fs::read_to_string(cs_dir.join("README.md"))
        .ok()
        .and_then(|content| read_objective(&content));

    // Narrative headings from every actor's lab notebook (all ## headings, most
    // recent last within each file)
    let headings = narrative_headings(&cs_dir.join("memory"));
    let last_discovery = headings.last().cloned();
    // Last 4 discoveries, most recent first
    let discoveries: Vec<String> = headings.into_iter().rev().take(4).collect();

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
        discoveries,
        memory_entries,
        contributors,
    }
}

/// Every "## " heading across the session's narratives, in filename order.
///
/// Narratives are per-actor (`narrative.<actor>.md`), so a shared session holds
/// one notebook per co-developer. Sorting by filename keeps the preview stable
/// no matter what order the directory enumerates in. Sibling files in the memory
/// directory — the `MEMORY.md` index and the individual entries — carry their
/// own headings and are not discoveries.
fn narrative_headings(memory_dir: &Path) -> Vec<String> {
    let mut files: Vec<PathBuf> = match fs::read_dir(memory_dir) {
        Ok(entries) => entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("narrative") && n.ends_with(".md"))
            })
            .collect(),
        Err(_) => return Vec::new(),
    };
    files.sort();

    files
        .iter()
        .filter_map(|path| fs::read_to_string(path).ok())
        .flat_map(|content| {
            content
                .lines()
                .filter(|line| line.starts_with("## "))
                .map(|line| line.trim_start_matches("## ").to_string())
                .collect::<Vec<_>>()
        })
        .collect()
}

/// One record from the set Claude Code publishes while a session runs, holding
/// only the fields cs reads back.
pub struct AgentRecord {
    pub name: String,
    pub status: String,
    pub pid: u32,
    pub proc_start: String,
}

/// Read a top-level string value out of a flat JSON object. The documents this
/// serves are machine-written, one object per file, and none of these keys
/// nests or carries an escape, so scanning beats taking a parser dependency.
/// A value that did carry one yields nothing, and the session shows no state.
/// True when the document holds a byte JSON forbids: a control character below
/// 0x20 that is not one of the three legal whitespace bytes. Such a document is
/// not JSON, `jq` refuses it outright, and the shell reader therefore shows no
/// state for that session — so scanning for fields must refuse it too rather
/// than reading a record its counterpart threw away.
fn has_illegal_raw_control(text: &str) -> bool {
    text.bytes()
        .any(|b| b < 0x20 && b != b'\t' && b != b'\n' && b != b'\r')
}

/// Drop what the shell reader's `tr -d` drops, in both forms a record can carry
/// it. A control character escaped as `\u00XX` is legal JSON: `jq` decodes it to
/// a byte and the shell strips that byte, so the text must lose the escape here
/// to arrive at the same answer. A raw DEL is legal JSON too and is stripped the
/// same way. Everything else is left exactly as written.
fn scrub_controls(value: &str) -> String {
    let v: Vec<char> = value.chars().collect();
    let mut out = String::with_capacity(value.len());
    let mut i = 0;
    while i < v.len() {
        if v[i] == '\\' && i + 5 < v.len() && (v[i + 1] == 'u' || v[i + 1] == 'U') {
            let hex: String = v[i + 2..i + 6].iter().collect();
            if let Ok(cp) = u32::from_str_radix(&hex, 16) {
                if cp < 0x20 || cp == 0x7f {
                    i += 6;
                    continue;
                }
            }
        }
        let cp = v[i] as u32;
        if cp < 0x20 || cp == 0x7f {
            i += 1;
            continue;
        }
        out.push(v[i]);
        i += 1;
    }
    out
}

fn json_string_field(text: &str, key: &str) -> Option<String> {
    let rest = text.split(&format!("\"{key}\":")).nth(1)?;
    let rest = rest.trim_start().strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(scrub_controls(&rest[..end]))
}

fn json_u32_field(text: &str, key: &str) -> Option<u32> {
    let rest = text.split(&format!("\"{key}\":")).nth(1)?;
    let rest = rest.trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

/// The contract this shares with `agent_states` in lib/56-presence.sh, which
/// answers the same question for `cs -live`. The two have drifted three times,
/// so the rules are stated once here and pinned on both sides: a record earns a
/// state only with a non-empty name, a non-empty status, a numeric pid and a
/// start time, out of a document that is legal JSON.
pub fn parse_agent_record(text: &str) -> Option<AgentRecord> {
    if has_illegal_raw_control(text) {
        return None;
    }
    let name = json_string_field(text, "name")?;
    let status = json_string_field(text, "status")?;
    // Empty is refused rather than rendered: a nameless record can match no
    // session, and a blank status says nothing a missing one does not.
    if name.is_empty() || status.is_empty() {
        return None;
    }
    Some(AgentRecord {
        name,
        status,
        pid: json_u32_field(text, "pid")?,
        proc_start: json_string_field(text, "procStart")?,
    })
}

/// Where Claude Code publishes its session records. Under test it is
/// [`UNSCOPED_CLAUDE_SESSIONS`], a path that cannot exist, as the sessions
/// root is: no test reads the real `~/.claude` of whoever runs the suite,
/// where a record or a FIFO could change or stall the run.
fn claude_sessions_dir() -> PathBuf {
    #[cfg(test)]
    return PathBuf::from(UNSCOPED_CLAUDE_SESSIONS);
    #[cfg(not(test))]
    live_claude_sessions_dir()
}

/// The directory Claude Code publishes its session records in on this
/// machine: `$CS_CLAUDE_DIR/sessions`, else `~/.claude/sessions`.
fn live_claude_sessions_dir() -> PathBuf {
    let base = std::env::var_os("CS_CLAUDE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(home_dir().expect("HOME not set")).join(".claude"));
    base.join("sessions")
}

/// The records directory a test build reads; under `/nonexistent`, which
/// only root can create.
#[cfg(test)]
const UNSCOPED_CLAUDE_SESSIONS: &str = "/nonexistent/cs-tui-test-claude-dir/sessions";

/// Map each session name to the state Claude Code advertises for it.
///
/// A record is unlinked on a clean exit but survives a crash, so a name only
/// earns its state once the recorded pid is still alive AND still reports the
/// process start time in the record — otherwise a pid the kernel has handed to
/// something else would keep a dead session looking busy. One `ps` answers for
/// every candidate; it prints the start time in the caller's zone while the
/// record holds UTC, so the comparison is made in UTC.
pub fn agent_statuses_in(dir: &Path) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    let records: Vec<AgentRecord> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
        .filter_map(|e| fs::read_to_string(e.path()).ok())
        .filter_map(|text| parse_agent_record(&text))
        .collect();
    if records.is_empty() {
        return out;
    }

    let pids: Vec<String> = records.iter().map(|r| r.pid.to_string()).collect();
    // One ps answers for every candidate, but `ps -p` fails the WHOLE invocation
    // when any id in the list is past the kernel's maximum ("process id too
    // large"), which would blank every session's state over one stale record.
    // Fall back to asking per pid so a single bad id costs only itself.
    let ask = |list: String| -> Option<String> {
        let o = std::process::Command::new("ps")
            .env("TZ", "UTC")
            .args(["-o", "pid=,lstart=", "-p", &list])
            .output()
            .ok()?;
        o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
    };
    let output = match ask(pids.join(",")) {
        Some(o) => o,
        None => pids.iter().filter_map(|p| ask(p.clone())).collect::<Vec<_>>().join("\n"),
    };

    let mut started: HashMap<u32, String> = HashMap::new();
    for line in output.lines() {
        let line = line.trim();
        let (pid, rest) = match line.split_once(char::is_whitespace) {
            Some(parts) => parts,
            None => continue,
        };
        if let Ok(pid) = pid.parse::<u32>() {
            started.insert(pid, rest.trim().to_string());
        }
    }

    for r in records {
        if started.get(&r.pid).map(|s| *s == r.proc_start).unwrap_or(false) {
            out.insert(r.name, r.status);
        }
    }
    out
}

/// The sessions root: `$CS_SESSIONS_ROOT`, else `~/.claude-sessions`. Under
/// test it is only ever the [`test_root`] override; with none scoped it is
/// [`test_root::UNSCOPED`], a path that cannot exist, so no test run can
/// delete, rename or scan the real sessions of whoever runs the suite.
pub fn sessions_root() -> PathBuf {
    #[cfg(test)]
    return test_root::current().unwrap_or_else(|| PathBuf::from(test_root::UNSCOPED));
    #[cfg(not(test))]
    std::env::var("CS_SESSIONS_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = home_dir().expect("HOME not set");
            PathBuf::from(home).join(".claude-sessions")
        })
}

/// Test-only sessions-root override. A test build never reads
/// `CS_SESSIONS_ROOT`, and setting it would be a process-global mutation
/// racing the many parallel tests (a logical data race on shared state). Cargo runs
/// each test on its own thread, so a thread-local root is naturally isolated per
/// test: `scoped(root)` sets it for the life of the returned guard and clears it
/// on drop (panic-safe, so a reused test thread never leaks it).
#[cfg(test)]
pub mod test_root {
    use std::cell::RefCell;
    use std::path::PathBuf;

    /// The root a test sees when it scoped none. Under `/nonexistent`, which
    /// only root can create, so a write fails and a delete finds nothing.
    pub const UNSCOPED: &str = "/nonexistent/cs-tui-test-sessions-root";

    thread_local! {
        static ROOT: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    }

    pub(super) fn current() -> Option<PathBuf> {
        ROOT.with(|c| c.borrow().clone())
    }

    #[must_use]
    pub fn scoped(root: PathBuf) -> Guard {
        ROOT.with(|c| *c.borrow_mut() = Some(root));
        Guard
    }

    pub struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            ROOT.with(|c| *c.borrow_mut() = None);
        }
    }
}

/// Test-only stand-in for `CLAUDE_SESSION_NAME`, the session the picker runs
/// inside. A test build never reads the variable (the suite may itself run
/// inside a session), and setting it would race the parallel tests, so each
/// test thread scopes its own: none scoped is a picker outside every session.
#[cfg(test)]
pub mod test_caller {
    use std::cell::RefCell;

    thread_local! {
        static CALLER: RefCell<Option<String>> = const { RefCell::new(None) };
    }

    pub(super) fn current() -> Option<String> {
        CALLER.with(|c| c.borrow().clone())
    }

    #[must_use]
    pub fn scoped(name: &str) -> Guard {
        CALLER.with(|c| *c.borrow_mut() = Some(name.to_string()));
        Guard
    }

    pub struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            CALLER.with(|c| *c.borrow_mut() = None);
        }
    }
}

/// Directory holding a session's cs content files (queue, mailbox): `.cs/private`
/// in an encrypted session, a link into its vault that reads as empty while it
/// dangles (the vault locked), else `.cs/local`. cs_private_dir's rule.
fn cs_files_dir(meta_dir: &Path) -> PathBuf {
    let private = meta_dir.join("private");
    if private.symlink_metadata().is_ok() { private } else { meta_dir.join("local") }
}

/// Directory holding a session's queue files.
pub fn queue_dir(name: &str) -> PathBuf {
    cs_files_dir(&sessions_root().join(name).join(".cs"))
}

/// True while the session's queue drain is live: cs's Stop hook writes
/// `draining` to queue.state when it hands tasks to the agent. The task being
/// worked is the one queue.current names, which is the first queued file unless
/// that task was removed or a file that sorts ahead of it was queued since.
pub fn queue_active(name: &str) -> bool {
    fs::read_to_string(queue_dir(name).join("queue.state"))
        .map(|s| s.trim() == "draining")
        .unwrap_or(false)
}

/// Task files in a queue directory (one file per task), in lexical filename
/// order — the queue's arrival order. Takes the directory rather than a
/// session name so a scan rooted anywhere but `sessions_root()` shares this
/// one definition of what counts as a queued task.
pub fn queue_task_files_in(queue: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = match fs::read_dir(queue) {
        Ok(rd) => rd
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.path())
            .collect(),
        Err(_) => return Vec::new(),
    };
    files.sort();
    files
}

/// Task files in the named session's queue directory.
pub fn queue_task_files(name: &str) -> Vec<PathBuf> {
    queue_task_files_in(&queue_dir(name).join("queue"))
}

/// The highlighted session's queued tasks, one entry per task file, in order.
/// Read fresh from disk so callers always see the latest queue.
///
/// Exactly one entry per task file, and never fewer: the editor and the delete
/// key address a task by its position in this list, so dropping an entry here
/// would shift every later index and mutate a different file than the one the
/// user is looking at. A file that is not valid UTF-8 is read lossily rather
/// than skipped for the same reason (`read_to_string` would fail the whole
/// read), and an empty file stays an empty row. This matches the shell's
/// `_queue_list`, which likewise numbers every regular file in the directory.
pub fn read_queue_in(queue: &Path) -> Vec<String> {
    queue_task_files_in(queue)
        .iter()
        .map(|p| {
            let bytes = fs::read(p).unwrap_or_default();
            String::from_utf8_lossy(&bytes)
                .trim_end_matches('\n')
                .to_string()
        })
        .collect()
}

pub fn read_queue(name: &str) -> Vec<String> {
    read_queue_in(&queue_dir(name).join("queue"))
}

pub fn scan_sessions() -> Vec<Session> {
    scan_sessions_in(&sessions_root())
}

/// Scan a specific sessions root. Tests call this directly so they never have to
/// mutate the process-global `CS_SESSIONS_ROOT` (which races across parallel tests).
pub(crate) fn scan_sessions_in(root: &Path) -> Vec<Session> {
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

    // One read of the published records covers the whole scan; a per-session
    // lookup would rescan the directory and re-fork ps for every row.
    let agent_statuses = agent_statuses_in(&claude_sessions_dir());
    for s in &mut sessions {
        s.agent_status = agent_statuses.get(&s.name).cloned();
    }

    sessions.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    sessions
}

/// Tags from the README's leading frontmatter block: the inline-array form
/// only (`tags: [a, b]`, spacing and double quotes tolerated). Block-style
/// lists and absent frontmatter read as empty, mirroring the bash reader.
pub fn parse_frontmatter_tags(readme: &str) -> Vec<String> {
    let mut lines = readme.lines();
    if lines.next().map(str::trim_end) != Some("---") {
        return Vec::new();
    }
    for line in lines {
        if line.trim_end() == "---" {
            break;
        }
        if let Some(rest) = line.strip_prefix("tags:") {
            let rest = rest.trim();
            if !(rest.starts_with('[') && rest.ends_with(']')) {
                return Vec::new();
            }
            return rest[1..rest.len() - 1]
                .split(',')
                .map(|t| t.trim().trim_matches('"').to_string())
                .filter(|t| !t.is_empty())
                .collect();
        }
    }
    Vec::new()
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
    let liveness = match read_lock_pid(&meta_dir) {
        Some(lock) => match read_remote_pid(&meta_dir, &name) {
            Some(server) => Liveness::Served { lock, server },
            None => Liveness::Locked(lock),
        },
        None if heartbeat_alive(&meta_dir, std::time::SystemTime::now()) => Liveness::Heartbeat,
        None => Liveness::Dormant,
    };
    let secrets_count = secret_counts.get(&name).copied().unwrap_or(0);
    let queue_depth = queue_task_files_in(&cs_files_dir(&meta_dir).join("queue")).len() as u32;
    let unread_mail = unread_mail_count(&meta_dir);
    let has_git = is_git_checkout(path);
    let git_repo = if has_git {
        parse_git_remote(path)
    } else {
        None
    };
    let readme = fs::read_to_string(meta_dir.join("README.md")).ok();
    let tags = readme
        .as_deref()
        .map(parse_frontmatter_tags)
        .unwrap_or_default();
    let objective = readme.as_deref().and_then(read_objective);
    let archived = meta_dir.join("archived").is_file();
    let vault = tags.iter().any(|t| t == ENCRYPTED_TAG).then(|| {
        if meta_dir.join("memory").exists() {
            Vault::Unlocked
        } else {
            Vault::Locked
        }
    });

    Session {
        name,
        is_adopted,
        created,
        modified,
        modified_ts,
        liveness,
        agent_status: None,
        secrets_count,
        queue_depth,
        unread_mail,
        git_repo,
        tags,
        archived,
        vault,
        objective,
    }
}

fn find_log_file(session_dir: &Path) -> Option<PathBuf> {
    // An encrypted session keeps its log behind .cs/private (a link into its
    // vault, unreadable while locked); machine-local is every other session's
    // home; the older .cs/logs/ and flat logs/ locations are kept as fallbacks
    // for sessions not yet migrated.
    for candidate in [
        ".cs/private/session.log",
        ".cs/local/session.log",
        ".cs/logs/session.log",
        "logs/session.log",
    ] {
        let path = session_dir.join(candidate);
        if path.is_file() {
            return Some(path);
        }
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
    if first_line.len() >= 19 && first_line.is_char_boundary(19) {
        let candidate = &first_line[..19];
        if is_timestamp_format(candidate) {
            return trim_timestamp(candidate);
        }
    }

    None
}

fn trim_timestamp(ts: &str) -> Option<String> {
    let trimmed = ts.trim();
    if trimmed.len() >= 16 && trimmed.is_char_boundary(16) {
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

/// Repo-first truncation: prefer owner/repo, else the repo alone, else a
/// middle-elided repo. Never tail-clips (the repo name is what matters).
pub fn truncate_repo(repo: &str, w: usize) -> String {
    if repo.is_empty() {
        return String::new();
    }
    if repo.chars().count() <= w {
        return repo.into();
    }
    let name = repo.split('/').next_back().unwrap_or(repo);
    if name.chars().count() <= w {
        return name.into();
    }
    if w <= 1 {
        return "\u{2026}".into();
    }
    let ch: Vec<char> = name.chars().collect();
    let keep = w - 1;
    let head = keep / 2;
    let tail = keep - head;
    let mut out: String = ch[..head].iter().collect();
    out.push('\u{2026}');
    out.extend(ch[ch.len() - tail..].iter());
    out
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

/// How long after the last statusline write a lockless conversation still
/// counts as live. Ticks are bursty: seconds apart while the conversation
/// works, minutes apart while it idles open (fignity showed 5m+ gaps), so
/// a wide window prevents live/dormant flapping; the cost is a closed
/// outside-conversation lingering live for at most this long.
const HEARTBEAT_WINDOW_SECS: u64 = 900;

/// True when .cs/local/context-pct was written within the heartbeat window
/// of `now`. Detects conversations opened outside cs (no session.lock).
/// A future mtime counts as live, matching the recency math's clamping.
fn heartbeat_alive(meta_dir: &Path, now: std::time::SystemTime) -> bool {
    let Ok(md) = fs::metadata(meta_dir.join("local/context-pct")) else {
        return false;
    };
    let Ok(mtime) = md.modified() else {
        return false;
    };
    now.duration_since(mtime)
        .map(|d| d.as_secs() <= HEARTBEAT_WINDOW_SECS)
        .unwrap_or(true)
}

/// Split a worktree session name (`base@task`) into base and task. This is
/// the single home of the naming convention; every consumer goes through it.
pub fn worktree_parts(name: &str) -> Option<(&str, &str)> {
    name.split_once('@')
}

/// What deleting a session would take beyond cs's own files, in the two
/// shapes `cs -rm` names them: top-level entries cs did not create in a
/// session root, or paths git does not track in a worktree session (the
/// only files there with no copy on the branch).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnownedEntries {
    NotCreatedByCs(Vec<String>),
    NotTrackedByGit(Vec<untracked::Entry>),
}

/// The delete confirm's account of one thing a removal would take: a line of
/// text, and under it the entries it lists one per row, the files git does
/// not track or the names cs did not create (empty for any other warning).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeleteWarning {
    pub text: String,
    pub entries: Vec<untracked::Entry>,
}

impl DeleteWarning {
    pub fn line(text: String) -> Self {
        DeleteWarning { text, entries: Vec::new() }
    }
}

impl UnownedEntries {
    /// The confirm's warning, in `cs -rm`'s words, its names or paths listed
    /// one per row under it; None when nothing is at risk.
    pub fn warning(&self) -> Option<DeleteWarning> {
        match self {
            // Each name is one entry without a trailing '/', so the listing
            // draws it alone, with no file count.
            UnownedEntries::NotCreatedByCs(p) if !p.is_empty() => Some(DeleteWarning {
                text: "Also deletes files cs did not create:".to_string(),
                entries: p.iter().map(|name| untracked::Entry { path: name.clone(), files: 1 }).collect(),
            }),
            UnownedEntries::NotTrackedByGit(e) if !e.is_empty() => Some(DeleteWarning {
                text: format!("Also deletes {} git does not track:", untracked::count_phrase(e)),
                entries: e.clone(),
            }),
            _ => None,
        }
    }

    /// Why a removal not granted these files refuses session `name`, as
    /// `cs -rm --force` refuses without --delete-files, on one line for the
    /// status bar, each name as the listing prints it (`untracked::printed`);
    /// None when there are none.
    pub fn refusal(&self, name: &str) -> Option<String> {
        match self {
            UnownedEntries::NotCreatedByCs(p) if !p.is_empty() => {
                let listed: Vec<String> = p.iter().map(|entry| untracked::printed(entry)).collect();
                Some(format!("{name} holds files cs did not create: {}", listed.join(", ")))
            }
            UnownedEntries::NotTrackedByGit(e) if !e.is_empty() => {
                let lines = untracked::entry_lines(e, untracked::SHOWN_ENTRIES);
                let listed: Vec<&str> = lines.iter().map(|l| l.trim()).collect();
                Some(format!("{name} holds {} git does not track: {}", untracked::count_phrase(e), listed.join(", ")))
            }
            _ => None,
        }
    }
}

/// Names cs, Claude Code and Finder put in a session root, plus the root
/// files legacy cs layouts kept there; everything else belongs to the user.
/// Kept in step with `_session_foreign_entries`.
const SESSION_ROOT_OWNED: &[&str] = &[
    ".cs", ".claude", ".git", ".gitignore", ".gitattributes", "CLAUDE.md", "CLAUDE.local.md", ".DS_Store",
    "notes.md", "changes.md", "discoveries.md", "logs", "artifacts",
];

/// The one path under a worktree's `.claude/` that is cs's: the settings
/// file it writes. Anything else there is the user's.
const WORKTREE_OWNED_SETTINGS: &str = ".claude/settings.local.json";

/// The paths under a tracked-mode worktree's `.cs/` that are cs's own
/// machine-local files; git carries the rest of `.cs/` there.
const TRACKED_MODE_CS_OWNED: [&str; 3] = [".cs/session.lock", ".cs/session.mutex.lock", ".cs/.narrative-reminder-cooldown"];

/// The line cs writes into the root CLAUDE.local.md it owns.
const SESSION_PROTOCOL_SENTINEL: &[u8] = b"<!-- cs:session-protocol -->";

/// What removing the session at `path` would delete that cs did not put
/// there. An adopted session (a symlink) loses only its link, so nothing.
/// Errors when the listing itself fails: a delete must not proceed on a
/// list it could not read.
pub fn unowned_entries(name: &str, path: &Path) -> Result<UnownedEntries, String> {
    if path.symlink_metadata().map(|m| m.file_type().is_symlink()).unwrap_or(false) {
        return Ok(UnownedEntries::NotCreatedByCs(Vec::new()));
    }
    if is_worktree_beside_its_base(name, path) {
        return worktree_untracked(path).map(UnownedEntries::NotTrackedByGit);
    }
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        // A row whose directory is already gone holds nothing to lose.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(UnownedEntries::NotCreatedByCs(Vec::new()))
        }
        Err(e) => return Err(format!("cannot list {}: {e}", path.display())),
    };
    let mut names = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("cannot list {}: {e}", path.display()))?;
        let entry_name = entry.file_name().to_string_lossy().into_owned();
        if !SESSION_ROOT_OWNED.contains(&entry_name.as_str()) {
            names.push(entry_name);
        }
    }
    names.sort();
    Ok(UnownedEntries::NotCreatedByCs(names))
}

/// Whether session `name` at `path` is a worktree git can list: a
/// `<base>@<task>` checkout with its `.git` file, beside a base directory (a
/// link to one followed). `cs -rm` asks the same before it lists with git
/// (lib/65-sessions.sh `_remove_one_session`); a worktree whose base is gone
/// has no repository to ask, so both list it as a plain directory.
fn is_worktree_beside_its_base(name: &str, path: &Path) -> bool {
    let Some((base, _)) = worktree_parts(name) else { return false };
    path.join(".git").is_file() && path.parent().is_some_and(|root| root.join(base).is_dir())
}

/// The NUL-separated paths `git ls-files <args>` prints in `path`.
fn git_ls_files(path: &Path, args: &[&str]) -> Result<Vec<String>, String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["ls-files", "-z"])
        .args(args)
        .output()
        .map_err(|e| format!("cannot run git ls-files in {}: {e}", path.display()))?;
    if !out.status.success() {
        return Err(format!(
            "git ls-files failed in {}: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).split('\0').filter(|p| !p.is_empty()).map(str::to_string).collect())
}

/// Files and links under `dir`, not following links: what removing it deletes.
fn files_under(dir: &Path) -> Result<u64, String> {
    let mut files = 0;
    for entry in fs::read_dir(dir).map_err(|e| format!("cannot list {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("cannot list {}: {e}", dir.display()))?;
        let kind = entry.file_type().map_err(|e| format!("cannot read {}: {e}", entry.path().display()))?;
        files += if kind.is_dir() { files_under(&entry.path())? } else { 1 };
    }
    Ok(files)
}

/// The `cs_mode` a worktree's `.cs/local/state` names, read as
/// `_read_local_state` reads it: line by line as bytes, so a byte that is
/// not UTF-8 elsewhere in the file leaves the line readable; `None` when the
/// file or the key is absent.
fn worktree_cs_mode(path: &Path) -> Option<String> {
    let state = fs::read(path.join(".cs/local/state")).ok()?;
    state
        .split(|&byte| byte == b'\n')
        .find_map(|line| line.strip_prefix(b"cs_mode:"))
        .map(|value| String::from_utf8_lossy(value).trim_start().replace('"', ""))
}

/// The test of whether a path in the worktree at `path` is cs's own
/// bookkeeping, as lib/30-worktree.sh `_without_cs_bookkeeping` draws the
/// line, the mode and the protocol file read once: all of `.cs/`
/// in ignored mode, only its machine-local files otherwise (git carries the
/// rest); the root CLAUDE.local.md only while it carries cs's sentinel; the
/// settings file; and Finder's .DS_Store at any depth.
fn cs_bookkeeping_in(path: &Path) -> impl Fn(&str) -> bool {
    let ignored_mode = worktree_cs_mode(path).as_deref() == Some("ignored");
    let protocol_file_is_cs = fs::read(path.join("CLAUDE.local.md"))
        .map(|text| text.windows(SESSION_PROTOCOL_SENTINEL.len()).any(|w| w == SESSION_PROTOCOL_SENTINEL))
        .unwrap_or(false);
    move |p: &str| {
        let cs_own = if ignored_mode {
            p.starts_with(".cs/")
        } else {
            p.starts_with(".cs/local/") || TRACKED_MODE_CS_OWNED.contains(&p)
        };
        cs_own
            || (protocol_file_is_cs && p == "CLAUDE.local.md")
            || p == WORKTREE_OWNED_SETTINGS
            || p.rsplit('/').next() == Some(".DS_Store")
    }
}

/// The gitlink paths in the index of the checkout at `dir`.
fn gitlinks(dir: &Path) -> Result<Vec<String>, String> {
    // Each entry reads "<mode> <oid> <stage>\t<path>".
    Ok(git_ls_files(dir, &["-s"])?
        .into_iter()
        .filter(|entry| entry.starts_with("160000 "))
        .filter_map(|entry| entry.split_once('\t').map(|(_, path)| path.to_string()))
        .collect())
}

/// The files and links under `dir`, not following links, each as its path
/// from `dir`.
fn paths_under(dir: &Path) -> Result<Vec<String>, String> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(dir).map_err(|e| format!("cannot list {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("cannot list {}: {e}", dir.display()))?;
        let kind = entry.file_type().map_err(|e| format!("cannot read {}: {e}", entry.path().display()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if kind.is_dir() {
            paths.extend(paths_under(&entry.path())?.into_iter().map(|p| format!("{name}/{p}")));
        } else {
            paths.push(name);
        }
    }
    Ok(paths)
}

/// The untracked and ignored files inside every initialised submodule of the
/// checkout at `dir`, at any depth, each path prefixed with `prefix` and its
/// submodule's path (lib/30-worktree.sh `_submodule_others`): git ls-files
/// never lists inside a submodule, and removing the worktree removes them. A
/// submodule the checkout never populated is an empty directory to git,
/// which lists nothing inside it either, so every file there is listed.
fn submodule_others(dir: &Path, prefix: &str) -> Result<Vec<String>, String> {
    let mut others = Vec::new();
    for sub in gitlinks(dir)? {
        let checkout = dir.join(&sub);
        let inner = format!("{prefix}{sub}/");
        if !checkout.join(".git").exists() {
            if checkout.symlink_metadata().map(|m| m.is_dir()).unwrap_or(false) {
                others.extend(paths_under(&checkout)?.into_iter().map(|p| format!("{inner}{p}")));
            }
            continue;
        }
        let mut listed = git_ls_files(&checkout, &["--others", "--exclude-standard"])?;
        listed.extend(git_ls_files(&checkout, &["--others", "--ignored", "--exclude-standard"])?);
        others.extend(listed.into_iter().map(|p| format!("{inner}{p}")));
        others.extend(submodule_others(&checkout, &inner)?);
    }
    Ok(others)
}

/// The path of every submodule of the checkout at `dir`, at any depth,
/// populated or not, with '/' after it and `prefix` before it
/// (lib/30-worktree.sh `_submodule_dirs`): `git ls-files
/// --recurse-submodules` leaves out one that holds no file, and a listing
/// must never collapse it or a directory above it.
fn submodule_dirs(dir: &Path, prefix: &str) -> Result<Vec<String>, String> {
    let mut dirs = Vec::new();
    for sub in gitlinks(dir)? {
        let inner = format!("{prefix}{sub}/");
        dirs.push(inner.clone());
        let checkout = dir.join(&sub);
        if checkout.join(".git").exists() {
            dirs.extend(submodule_dirs(&checkout, &inner)?);
        }
    }
    Ok(dirs)
}

/// The entries of what git does not track in the worktree at `path`, as
/// `cs -rm` lists them (lib/65-sessions.sh `_worktree_untracked_paths`): the
/// worktree's own untracked and ignored files and every file inside a
/// submodule, without cs's own bookkeeping.
fn worktree_untracked(path: &Path) -> Result<Vec<untracked::Entry>, String> {
    let mut at_risk = git_ls_files(path, &["--others", "--exclude-standard"])?;
    at_risk.extend(git_ls_files(path, &["--others", "--ignored", "--exclude-standard"])?);
    at_risk.extend(submodule_others(path, "")?);
    let is_cs_own = cs_bookkeeping_in(path);
    at_risk.retain(|p| !is_cs_own(p));
    if at_risk.is_empty() {
        return Ok(Vec::new());
    }
    let mut tracked = git_ls_files(path, &["--recurse-submodules"])?;
    tracked.extend(submodule_dirs(path, "")?);
    let mut inside = HashMap::new();
    for repo in at_risk.iter().filter(|p| p.ends_with('/')) {
        inside.insert(repo.clone(), files_under(&path.join(repo))?);
    }
    untracked::entries(&tracked, &inside, &at_risk)
}

/// The links an encrypted session keeps into its vault, under `.cs/`.
pub const VAULT_LINKS: [&str; 4] = ["memory", "plans", "claude-config", "private"];

/// Whether `.cs/<sub>` in `dir` is a symlink, resolving or not: a locked
/// vault leaves it dangling.
pub fn is_vault_link(dir: &Path, sub: &str) -> bool {
    dir.join(".cs")
        .join(sub)
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

/// The first vault link that resolves inside `dir`, with its target as
/// written: the vault is mounted in the session directory itself.
fn mounted_vault_link(dir: &Path) -> Option<(&'static str, PathBuf)> {
    let real_dir = fs::canonicalize(dir).ok()?;
    VAULT_LINKS.iter().find_map(|sub| {
        if !is_vault_link(dir, sub) {
            return None;
        }
        let link = dir.join(".cs").join(sub);
        let real = fs::canonicalize(&link).ok()?;
        real.starts_with(&real_dir)
            .then(|| fs::read_link(&link).ok())
            .flatten()
            .map(|target| (*sub, target))
    })
}

/// The first mount point at or under `dir` in `table`, the output of
/// `mount`: macOS lists "<dev> on <path> (<opts>)", Linux
/// "<dev> on <path> type <fs> (<opts>)", and neither escapes its fields: a
/// source may hold " on " and a path " on ", " type " or " (". So each line
/// is read the Linux way (cut at its last " type ") and then the macOS way,
/// and in each every absolute path that follows an " on " is a candidate, as
/// cs -rm reads it. Matches may overlap: a source ending in " on" shares its
/// last space with the separator. Each candidate's ancestors are compared by
/// device and inode, which see through letter case and symlinks where a path
/// prefix would not.
fn mount_under(dir: &Path, table: &str) -> Option<PathBuf> {
    use std::os::unix::fs::MetadataExt;
    let target = fs::metadata(dir).ok()?;
    let same_as_dir = |p: &Path| {
        fs::metadata(p)
            .map(|m| m.dev() == target.dev() && m.ino() == target.ino())
            .unwrap_or(false)
    };
    table.lines().find_map(|line| {
        let body = line.rsplit_once(" (").map_or(line, |(head, _)| head);
        let linux = body.rsplit_once(" type ").map(|(head, _)| head);
        linux.into_iter().chain(std::iter::once(body)).find_map(|text| {
            text.char_indices()
                .filter_map(|(at, _)| text[at..].strip_prefix(" on "))
                .find_map(|rest| {
                    let mnt = Path::new(rest);
                    (mnt.is_absolute() && mnt.ancestors().any(same_as_dir)).then(|| mnt.to_path_buf())
                })
        })
    })
}

/// The mount table as `mount` prints it.
fn read_mount_table() -> std::io::Result<String> {
    let out = std::process::Command::new("mount").output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!("mount exited with {}", out.status)));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// What a delete may take beyond a dormant session that holds only cs's own
/// files: `cs -rm`'s two escalations. Each is refused unless granted.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RemoveGrants {
    /// Remove a session whose lock a live process holds (`cs -rm --force`).
    pub past_live_lock: bool,
    /// Delete the files cs did not create in a session root, or that git
    /// does not track in a worktree session (`cs -rm --delete-files`).
    pub unowned_files: bool,
}

/// The session the picker runs inside, as cs reads it: `CLAUDE_SESSION_NAME`,
/// where unset or empty is a terminal outside every session. Under test it is
/// only ever the [`test_caller`] override.
fn caller_session_name() -> Option<String> {
    #[cfg(test)]
    return test_caller::current();
    #[cfg(not(test))]
    std::env::var_os("CLAUDE_SESSION_NAME")
        .filter(|name| !name.is_empty())
        .map(|name| name.to_string_lossy().into_owned())
}

/// Why `cs -rm`, run inside session `caller`, refuses to remove session
/// `name` at `path` whatever it is granted, when it does; read now. First
/// `_refuse_live_other_session`: a live session that is not the caller's
/// own. A session owns itself, matched byte for byte as cs compares names,
/// and a base (a caller with no '@') owns each `<caller>@<task>`. Then
/// `_refuse_base_with_live_feature`: from any session but the base itself, a
/// base (a name with no '@') while one of its features is live. Twin of
/// those two guards in lib/15-lock.sh; the messages are theirs. Errors when
/// the sessions root cannot be listed, so a feature it holds is never missed.
fn cross_session_refusal(root: &Path, name: &str, path: &Path, caller: &str) -> std::io::Result<Option<String>> {
    if caller == name {
        return Ok(None);
    }
    let owned_feature = !caller.contains('@') && name.strip_prefix(caller).is_some_and(|rest| rest.starts_with('@'));
    if !owned_feature {
        if let Some(pid) = read_lock_pid(&path.join(".cs")) {
            return Ok(Some(format!(
                "session {caller} cannot remove session {name} while it is live (pid {pid}); --force does not override that from another session. Close {name} first."
            )));
        }
    }
    if name.contains('@') {
        return Ok(None);
    }
    Ok(live_feature_of(root, name)?.map(|(feature, pid)| {
        format!(
            "session {caller} cannot remove session {name} while its feature {feature} is live (pid {pid}); --force does not override that from another session. Close {feature} first."
        )
    }))
}

/// Why `cs -rm`, run inside the session the picker runs in, refuses to
/// remove session `name` at `path` whatever it is granted
/// ([`cross_session_refusal`]); `None` outside every session. The delete
/// confirm asks this before it opens, and the removal asks it again.
pub fn caller_refusal(root: &Path, name: &str, path: &Path) -> std::io::Result<Option<String>> {
    match caller_session_name() {
        Some(caller) => cross_session_refusal(root, name, path, &caller),
        None => Ok(None),
    }
}

/// The first live feature of base `name` in `root`, by entry name, with its
/// lock's pid. As cs's `"$SESSIONS_ROOT"/*@*` glob reads them, an entry is a
/// candidate when its name holds an '@' and does not start with '.'; it is
/// `name`'s when `<root>/<name>@<its task>` is the same file (device and
/// inode, through links, as `-ef` compares), not when the names match as
/// strings, since a volume that ignores letter case finds one directory
/// under several spellings. Its `.cs` must be a directory and its lock live.
fn live_feature_of(root: &Path, name: &str) -> std::io::Result<Option<(String, u32)>> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    let mut entries: Vec<std::ffi::OsString> = fs::read_dir(root)
        .and_then(|listing| listing.map(|entry| entry.map(|e| e.file_name())).collect())
        .map_err(|e| {
            std::io::Error::other(format!(
                "could not list {} ({e}), so cannot tell whether a feature of {name} is live; refusing to remove it",
                root.display()
            ))
        })?;
    entries.sort();
    let same_file = |a: &Path, b: &Path| match (fs::metadata(a), fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    };
    for entry in entries {
        let bytes = entry.as_bytes();
        if bytes.starts_with(b".") {
            continue;
        }
        let Some(at) = bytes.iter().position(|&b| b == b'@') else { continue };
        let mut own = std::ffi::OsString::from(format!("{name}@"));
        own.push(std::ffi::OsStr::from_bytes(&bytes[at + 1..]));
        let feature = root.join(&entry);
        if !same_file(&root.join(own), &feature) || !feature.join(".cs").is_dir() {
            continue;
        }
        if let Some(pid) = read_lock_pid(&feature.join(".cs")) {
            return Ok(Some((entry.to_string_lossy().into_owned(), pid)));
        }
    }
    Ok(None)
}

/// Remove a session at `path` by whatever means its kind requires: symlinks
/// are unlinked, worktree sessions are unregistered through git, and plain
/// directories are removed outright. Inside a session, what `cs -rm` refuses
/// from there is refused whatever `grants` allows ([`caller_refusal`]), and
/// so, anywhere, is a session a `cs <name> --remote` server serves
/// ([`served_refusal`]). A live session and one holding files beyond cs's
/// own are refused unless `grants` allows them; a mounted vault or volume is
/// refused always.
pub fn remove_session_path(root: &Path, name: &str, path: &Path, grants: RemoveGrants) -> std::io::Result<()> {
    if let Some(refusal) = caller_refusal(root, name, path)? {
        return Err(std::io::Error::other(refusal));
    }
    if let Some(refusal) = served_refusal(name, path) {
        return Err(std::io::Error::other(refusal));
    }
    // Read the lock now, as `cs -rm`'s session_is_live does: the picker's row
    // was scanned earlier and the session may have opened since.
    if !grants.past_live_lock {
        if let Some(pid) = read_lock_pid(&path.join(".cs")) {
            return Err(std::io::Error::other(live_refusal(name, pid)));
        }
    }
    let is_link = path.symlink_metadata().map(|m| m.file_type().is_symlink()).unwrap_or(false);
    // remove_dir_all recurses into a mount, so a vault mounted inside the
    // session would lose its contents. An adopted session loses only its link.
    if !is_link {
        if let Some((sub, target)) = mounted_vault_link(path) {
            return Err(std::io::Error::other(format!(
                "{name} has encrypted storage mounted inside it: .cs/{sub} points at {}; unmount it, then retry",
                target.display()
            )));
        }
        // A cs -encrypt that stopped partway leaves its volume mounted with
        // no link yet, so the links cannot see it; the mount table can.
        let table = read_mount_table().map_err(|e| {
            std::io::Error::other(format!(
                "could not read the mount table ({e}), so cannot tell whether a volume is mounted inside {name}; refusing to remove it"
            ))
        })?;
        if let Some(mnt) = mount_under(path, &table) {
            return Err(std::io::Error::other(format!(
                "{name} has a volume mounted inside it at {}; unmount it, then retry",
                mnt.display()
            )));
        }
    }
    // Listed now, not when the confirm opened: a file added since is one the
    // user was never shown.
    if !grants.unowned_files {
        if let Some(refusal) = unowned_entries(name, path).map_err(std::io::Error::other)?.refusal(name) {
            return Err(std::io::Error::other(refusal));
        }
    }
    if is_link {
        fs::remove_file(path)?;
    } else if worktree_parts(name).is_some() && path.join(".git").is_file() {
        remove_worktree_session(root, name, path)?;
    } else {
        fs::remove_dir_all(path)?;
    }
    discard_spawn_seeds(root, name);
    Ok(())
}

/// What `cs -spawn` stages under `$SESSIONS_ROOT/.spawn/` for a session name,
/// and what the launch sets aside when the seed ages out. Twin of
/// `_spawn_staging_suffixes` in lib/52-spawn.sh; the two lists change together.
const SPAWN_STAGING_SUFFIXES: [&str; 4] = [".seed", ".seed.stale", ".brief.md", ".brief.md.stale"];

/// Delete any staged or stale spawn seed and brief for `name`, the
/// `.<name>.seed.XXXXXX` staging file a `cs -spawn` killed before it published
/// leaves, and the `.<name>.seed.claim.<pid>` seed an open killed outright
/// leaves. A deleted session must not leave either behind: a seed would block
/// re-spawning the name and arm a future same-name session with dead tasks,
/// and a brief would reach it as a first prompt nobody wrote for it. Exactly
/// six characters follow the staging prefix, so the staging file of a session
/// named `<name>.seed` is never matched; a digit starts the claim's pid, so
/// the claim of a session named `<name>.seed.claim` is never matched. Twin of
/// the staging match in `_spawn_discard_seeds` (lib/52-spawn.sh).
/// Best-effort by design.
fn discard_spawn_seeds(root: &Path, name: &str) {
    let spawn = root.join(".spawn");
    for suffix in SPAWN_STAGING_SUFFIXES {
        let _ = fs::remove_file(spawn.join(format!("{name}{suffix}")));
    }
    let prefix = format!(".{name}.seed.");
    let Ok(entries) = fs::read_dir(&spawn) else { return };
    for entry in entries.flatten() {
        let file = entry.file_name();
        let Some(file) = file.to_str() else { continue };
        let Some(rest) = file.strip_prefix(&prefix) else { continue };
        let claimed = rest
            .strip_prefix("claim.")
            .is_some_and(|pid| pid.starts_with(|c: char| c.is_ascii_digit()));
        if rest.chars().count() == 6 || claimed {
            let _ = fs::remove_file(entry.path());
        }
    }
}

/// The staged spawn files `cs -spawn` keeps for `name` that exist: one path
/// per [`SPAWN_STAGING_SUFFIXES`] entry.
pub fn staged_spawn_files(root: &Path, name: &str) -> Vec<PathBuf> {
    SPAWN_STAGING_SUFFIXES
        .iter()
        .map(|suffix| root.join(".spawn").join(format!("{name}{suffix}")))
        .filter(|p| p.symlink_metadata().is_ok())
        .collect()
}

/// Move the staged spawn files of session `old` to session `new`, so a seed
/// and brief go with a renamed session instead of arming the next session
/// given the old name. Each move links the file under the new name and then
/// unlinks the old one, so a file already staged under the new name is never
/// replaced. On a failure the moves made so far are undone and the error,
/// naming the file, is returned. The `(from, to)` pairs moved, for
/// [`undo_spawn_moves`].
pub fn move_spawn_files(root: &Path, old: &str, new: &str) -> Result<Vec<(PathBuf, PathBuf)>, String> {
    let mut moved = Vec::new();
    for from in staged_spawn_files(root, old) {
        let file = from.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let to = root.join(".spawn").join(format!("{new}{}", &file[old.len()..]));
        let result = fs::hard_link(&from, &to).and_then(|_| {
            fs::remove_file(&from).inspect_err(|_| {
                let _ = fs::remove_file(&to);
            })
        });
        if let Err(e) = result {
            let failed = format!("could not move spawn file {}: {e}", from.display());
            return Err(match undo_spawn_moves(&moved) {
                Ok(()) => failed,
                Err(left) => format!("{failed}; {left}"),
            });
        }
        moved.push((from, to));
    }
    Ok(moved)
}

/// Put back spawn files [`move_spawn_files`] moved, newest first. Every move
/// is tried; the error names each file left under the new name.
pub fn undo_spawn_moves(moved: &[(PathBuf, PathBuf)]) -> Result<(), String> {
    let mut left = Vec::new();
    for (from, to) in moved.iter().rev() {
        let back = fs::hard_link(to, from).and_then(|_| fs::remove_file(to));
        if let Err(e) = back {
            left.push(format!("could not move spawn file {} back to {}: {e}", to.display(), from.display()));
        }
    }
    if left.is_empty() { Ok(()) } else { Err(left.join("; ")) }
}

/// Remove a worktree session (`base@task`) through git so the base repo's
/// worktree registration goes with it; the task branch is left alone,
/// matching `cs -rm` when its branch prompt is declined. Falls back to
/// plain directory removal when the base session is gone. When git refuses,
/// its error is returned and nothing is deleted, as `cs -rm` stops there.
fn remove_worktree_session(root: &Path, name: &str, path: &Path) -> std::io::Result<()> {
    let base = worktree_parts(name).map(|(b, _)| b).unwrap_or(name);
    let base_dir = root.join(base);
    if !base_dir.is_dir() {
        return fs::remove_dir_all(path);
    }
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(&base_dir)
        .args(["worktree", "remove", "--force", "--"])
        .arg(path)
        .output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!(
            "git worktree remove failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(())
}

/// Unread cross-session mail: the documents in `mail/new/` (`cs -msg` moves
/// what it prints into `cur/`), matching the shell reader and the statusline.
/// Only `*.json` files count — a `.DS_Store`, a staging leftover or a
/// subdirectory would otherwise badge a phantom unread that never clears.
/// A locked vault's read fails and counts 0.
fn unread_mail_count(meta_dir: &Path) -> u32 {
    fs::read_dir(cs_files_dir(meta_dir).join("mail/new"))
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| e.path().extension().is_some_and(|ext| ext == "json"))
                .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                .count() as u32
        })
        .unwrap_or(0)
}

/// The pid a session's lock names when that process is running, by the rule
/// cs and cs-secrets read a lock with (live_lock_pid): the text, surrounding
/// whitespace removed, is decimal digits only (no sign), and is_pid_alive
/// holds for it, which rules out 0 and anything past 2147483647. Read at the
/// moment of asking.
pub fn read_lock_pid(meta_dir: &Path) -> Option<u32> {
    let lock_file = meta_dir.join("session.lock");
    let content = fs::read_to_string(&lock_file).ok()?;
    let text = content.trim();
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let pid = text.parse::<u32>().ok()?;
    if is_pid_alive(pid) { Some(pid) } else { None }
}

/// The pid in `.cs/local/remote.pid`, which `cs <name> --remote` writes for
/// the `claude remote-control` server it runs, while that pid runs
/// `remote-control --name <name>`. A file a server's release never removed
/// can name a pid another program has taken since, so a live pid alone is not
/// enough. The twin of `_remote_server_pid` in lib/02-shared.sh.
fn read_remote_pid(meta_dir: &Path, name: &str) -> Option<u32> {
    let content = fs::read_to_string(meta_dir.join("local/remote.pid")).ok()?;
    let pid = content.trim().parse::<u32>().ok()?;
    if pid == 0 || pid > i32::MAX as u32 {
        return None;
    }
    let o = std::process::Command::new("ps")
        .args(["-ww", "-o", "args=", "-p", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !o.status.success() {
        return None;
    }
    // Padded on both sides, so demo does not match demo-2.
    let args = format!(" {} ", String::from_utf8_lossy(&o.stdout).trim_end());
    args.contains(&format!(" remote-control --name {name} ")).then_some(pid)
}

/// Why `cs -rm` refuses to remove session `name` at `path`, with or without
/// --force and from any caller, while a `cs <name> --remote` server serves it
/// ([`read_remote_pid`], read now); `None` when none does. Twin of
/// `_remote_refuse_live` in lib/76-remote.sh; the message is its.
pub fn served_refusal(name: &str, path: &Path) -> Option<String> {
    read_remote_pid(&path.join(".cs"), name).map(|pid| {
        format!(
            "Session {name} is served by cs {name} --remote (remote-control PID {pid}); stop it first with Ctrl-C in its window, or close the window."
        )
    })
}

/// Why a picker action refuses session `name`, whose claude runs as `pid`.
pub fn live_refusal(name: &str, pid: u32) -> String {
    format!("{name} is live (pid {pid}) — close it first")
}

/// True when a process with `pid` is alive on this machine, via `kill -0`.
/// A missing tool or a spawn error is treated as "not alive" (the caller then
/// falls back to the statusline heartbeat), never a crash.
pub fn is_pid_alive(pid: u32) -> bool {
    // A pid_t is a SIGNED 32-bit int, so anything past i32::MAX is not a process
    // id at all and each platform mishandles it differently: macOS `kill` refuses
    // it ("illegal process id"), while on Linux it wraps — 4294967295 lands on
    // -1, which means "every process the caller may signal" and SUCCEEDS, so an
    // absurd id in a lock file or a session record would read as alive. Rule the
    // range out here rather than depending on how `kill` parses it.
    if pid == 0 || pid > i32::MAX as u32 {
        return false;
    }
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// True when a path is a git checkout. A linked worktree's `.git` is a file
/// holding a `gitdir:` pointer, so both shapes count.
fn is_git_checkout(dir: &Path) -> bool {
    let g = dir.join(".git");
    g.is_dir() || g.is_file()
}

fn load_contributors(session_dir: &Path) -> Vec<String> {
    if !is_git_checkout(session_dir) {
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

/// Count cs secrets per session by scanning the macOS login keychain.
///
/// Only macOS ships the `security` tool and a keychain; on Linux the TUI's
/// keychain panel is empty by design (secrets there live in the encrypted-file
/// backend, which this view does not enumerate). Gated to macOS so non-macOS
/// builds don't spawn a missing binary on every refresh. A test build counts
/// none and runs no `security`: no test reads the Keychain of whoever runs
/// the suite.
#[cfg(target_os = "macos")]
fn count_secrets_from_keychain() -> HashMap<String, u32> {
    #[cfg(test)]
    return HashMap::new();
    #[cfg(not(test))]
    count_secrets_in_live_keychain()
}

/// Secret counts per session from the login Keychain's `security dump-keychain`.
#[cfg(all(target_os = "macos", not(test)))]
fn count_secrets_in_live_keychain() -> HashMap<String, u32> {
    let output = std::process::Command::new("security")
        .args(["dump-keychain"])
        .stderr(std::process::Stdio::null())
        .output();

    match output {
        Ok(output) => secret_counts_in_keychain_dump(&String::from_utf8_lossy(&output.stdout)),
        Err(_) => HashMap::new(),
    }
}

/// Secret counts per session in the text of a `security dump-keychain`: one
/// per item whose service attribute is `cs:<session>:<name>`.
#[cfg(any(test, target_os = "macos"))]
fn secret_counts_in_keychain_dump(dump: &str) -> HashMap<String, u32> {
    let mut counts = HashMap::new();
    for line in dump.lines() {
        // Match: "svce"<blob>="cs:session_name:secret_name"
        if let Some(rest) = line.strip_prefix("    \"svce\"<blob>=\"cs:") {
            if let Some(session) = rest.split(':').next() {
                *counts.entry(session.to_string()).or_insert(0) += 1;
            }
        }
    }
    counts
}

/// Non-macOS: no keychain to scan, so the panel shows no keychain-backed
/// secret counts. See the macOS variant for why.
#[cfg(not(target_os = "macos"))]
fn count_secrets_from_keychain() -> HashMap<String, u32> {
    HashMap::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;

    fn git_in(dir: &Path, args: &[&str]) {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.email=t@example.com", "-c", "user.name=t"])
            .args(args)
            .output()
            .expect("git runs");
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    }

    fn encrypted_session(root: &Path, name: &str, tags: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::write(dir.join(".cs/README.md"), format!("---\ntags: [{tags}]\n---\n# {name}\n")).unwrap();
        dir
    }

    #[test]
    fn lock_marker_follows_the_caps_consent_with_the_env_overriding_the_file() {
        assert_eq!(lock_marker_for(None, None), "enc", "unanswered draws the word");
        assert_eq!(lock_marker_for(None, Some("on\n")), "\u{f023}");
        assert_eq!(lock_marker_for(None, Some("off\n")), "enc");
        assert_eq!(lock_marker_for(Some("0"), Some("on\n")), "enc", "env 0 beats the file");
        assert_eq!(lock_marker_for(Some("1"), None), "\u{f023}", "env 1 beats a missing file");
    }

    #[test]
    fn a_session_tagged_encrypted_reads_locked_while_its_memory_link_dangles() {
        let root = std::env::temp_dir().join(format!("cs-vault-locked-{}", std::process::id()));
        let dir = encrypted_session(&root, "rel", "home, encrypted");
        std::os::unix::fs::symlink(dir.join(".cs/vault-mnt/memory"), dir.join(".cs/memory")).unwrap();

        let session = read_session(&dir, &HashMap::new());

        assert_eq!(session.vault, Some(Vault::Locked));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_session_tagged_encrypted_reads_unlocked_once_its_memory_resolves() {
        let root = std::env::temp_dir().join(format!("cs-vault-open-{}", std::process::id()));
        let dir = encrypted_session(&root, "rel", "encrypted");
        fs::create_dir_all(dir.join(".cs/vault-mnt/memory")).unwrap();
        std::os::unix::fs::symlink(dir.join(".cs/vault-mnt/memory"), dir.join(".cs/memory")).unwrap();

        let session = read_session(&dir, &HashMap::new());

        assert_eq!(session.vault, Some(Vault::Unlocked));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_untagged_session_has_no_vault_even_with_a_dangling_memory_link() {
        let root = std::env::temp_dir().join(format!("cs-vault-none-{}", std::process::id()));
        let dir = encrypted_session(&root, "synced", "home");
        std::os::unix::fs::symlink(dir.join("gone"), dir.join(".cs/memory")).unwrap();

        let session = read_session(&dir, &HashMap::new());

        assert_eq!(session.vault, None);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unowned_entries_lists_top_level_files_cs_did_not_create() {
        let root = std::env::temp_dir().join(format!("cs-unowned-plain-{}", std::process::id()));
        let dir = root.join("rel");
        for d in [".cs/local", ".claude", ".git", "logs", "artifacts", "journal.sparsebundle"] {
            fs::create_dir_all(dir.join(d)).unwrap();
        }
        let owned = [".gitignore", ".gitattributes", "CLAUDE.md", "CLAUDE.local.md", ".DS_Store"];
        let legacy = ["notes.md", "changes.md", "discoveries.md"];
        for f in owned.iter().chain(legacy.iter()).chain(["start"].iter()) {
            fs::write(dir.join(f), "x").unwrap();
        }

        let got = unowned_entries("rel", &dir).unwrap();

        assert_eq!(got, UnownedEntries::NotCreatedByCs(vec!["journal.sparsebundle".into(), "start".into()]));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unowned_entries_is_empty_for_an_adopted_link() {
        let root = std::env::temp_dir().join(format!("cs-unowned-link-{}", std::process::id()));
        let project = root.join("project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("main.rs"), "x").unwrap();
        std::os::unix::fs::symlink(&project, root.join("adopted")).unwrap();

        let got = unowned_entries("adopted", &root.join("adopted")).unwrap();

        assert_eq!(got, UnownedEntries::NotCreatedByCs(vec![]));
        let _ = fs::remove_dir_all(&root);
    }

    // git lists a repository nested in the worktree as one path ending in
    // '/'; its entry counts every file under it, its .git included, as
    // `cs -rm` does.
    #[test]
    fn unowned_entries_counts_the_files_in_a_nested_repository() {
        let root = std::env::temp_dir().join(format!("cs-unowned-nested-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("tracked.txt"), "x").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", "tracked.txt"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        let other = root.join("other");
        fs::create_dir_all(&other).unwrap();
        git_in(&other, &["init", "-q"]);
        fs::create_dir_all(wt.join("dep")).unwrap();
        fs::write(wt.join("dep/.git"), format!("gitdir: {}\n", other.join(".git").display())).unwrap();
        fs::write(wt.join("dep/a"), "").unwrap();
        fs::write(wt.join("dep/b"), "").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![untracked::Entry { path: "dep/".into(), files: 3 }]));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unowned_entries_lists_untracked_and_ignored_files_in_a_worktree() {
        let root = std::env::temp_dir().join(format!("cs-unowned-wt-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("tracked.txt"), "x").unwrap();
        fs::write(base.join(".gitignore"), "*.img\n.cs/local/\n").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", "tracked.txt", ".gitignore"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        fs::create_dir_all(wt.join(".cs/local")).unwrap();
        fs::write(wt.join("notes.txt"), "draft").unwrap();
        fs::write(wt.join("journal.img"), "secret").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        let file = |path: &str| untracked::Entry { path: path.into(), files: 1 };
        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![file("journal.img"), file("notes.txt")]));
        let _ = fs::remove_dir_all(&root);
    }

    // A worktree's .claude/ holds the settings file cs writes beside what the
    // user keeps there. Only the settings file is cs's: the rest is listed
    // like any other file git does not track, as `cs -rm` lists it.
    #[test]
    fn unowned_entries_lists_the_users_files_under_dot_claude_in_a_worktree() {
        let root = std::env::temp_dir().join(format!("cs-unowned-claude-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(base.join(".claude/commands")).unwrap();
        fs::write(base.join(".claude/commands/ship.md"), "ship").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", ".claude/commands/ship.md"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        fs::create_dir_all(wt.join(".claude/agents")).unwrap();
        fs::write(wt.join(".claude/settings.local.json"), "{}").unwrap();
        fs::write(wt.join(".claude/agents/reviewer.md"), "review").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(
            got,
            UnownedEntries::NotTrackedByGit(vec![untracked::Entry { path: ".claude/agents/".into(), files: 1 }])
        );
        let _ = fs::remove_dir_all(&root);
    }

    // Finder's .DS_Store is no one's work at any depth, as retire and
    // `cs -rm` treat it: a directory holding one beside the user's file
    // counts the user's file only.
    #[test]
    fn unowned_entries_leaves_out_ds_store_at_any_depth_in_a_worktree() {
        let root = std::env::temp_dir().join(format!("cs-unowned-ds-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("tracked.txt"), "x").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", "tracked.txt"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        fs::create_dir_all(wt.join("docs/deep")).unwrap();
        fs::write(wt.join("docs/deep/notes.md"), "draft").unwrap();
        fs::write(wt.join("docs/deep/.DS_Store"), "").unwrap();
        fs::write(wt.join("docs/.DS_Store"), "").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![untracked::Entry { path: "docs/".into(), files: 1 }]));
        fs::remove_file(wt.join("docs/deep/notes.md")).unwrap();
        assert_eq!(unowned_entries("proj@task", &wt).unwrap(), UnownedEntries::NotTrackedByGit(Vec::new()));
        let _ = fs::remove_dir_all(&root);
    }

    /// A worktree session `proj@task` under `root`, beside its base, whose
    /// repo tracks `tracked.txt` and ignores `.cs/local/` and what cs's
    /// exclude names, with an empty `.cs/local/`.
    fn worktree_beside_base(root: &Path) -> PathBuf {
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("tracked.txt"), "x").unwrap();
        fs::write(base.join(".gitignore"), ".cs/local/\n").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", "tracked.txt", ".gitignore"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        fs::write(base.join(".git/info/exclude"), "CLAUDE.local.md\n.claude/settings.local.json\n").unwrap();
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        fs::create_dir_all(wt.join(".cs/local")).unwrap();
        wt
    }

    // cs writes the root CLAUDE.local.md with its protocol sentinel; one
    // without it is the user's own, which retire refuses over and `cs -rm`
    // lists.
    #[test]
    fn unowned_entries_lists_a_user_authored_claude_local_md_in_a_worktree() {
        let root = std::env::temp_dir().join(format!("cs-unowned-local-md-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        fs::write(wt.join("CLAUDE.local.md"), "my own notes for this checkout\n").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![untracked::Entry { path: "CLAUDE.local.md".into(), files: 1 }]));
        fs::write(wt.join("CLAUDE.local.md"), "<!-- cs:session-protocol -->\n# Session protocol\n").unwrap();
        assert_eq!(unowned_entries("proj@task", &wt).unwrap(), UnownedEntries::NotTrackedByGit(Vec::new()));
        let _ = fs::remove_dir_all(&root);
    }

    // An initialised submodule is a checkout of its own: git ls-files in the
    // worktree does not list the files inside it, and removal destroys them.
    // Each is an entry of its own, as `cs -rm` lists it.
    #[test]
    fn unowned_entries_lists_files_inside_an_initialised_submodule() {
        let root = std::env::temp_dir().join(format!("cs-unowned-submodule-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        let lib = root.join("sublib");
        fs::create_dir_all(&lib).unwrap();
        fs::write(lib.join("lib.txt"), "lib").unwrap();
        fs::write(lib.join(".gitignore"), "*.env\n").unwrap();
        git_in(&lib, &["init", "-q"]);
        git_in(&lib, &["add", "-A"]);
        git_in(&lib, &["commit", "-qm", "lib"]);
        git_in(&wt, &["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.to_str().unwrap(), "sub"]);
        git_in(&wt, &["commit", "-qm", "add submodule"]);
        fs::write(wt.join("sub/secret.env"), "secret").unwrap();
        fs::write(wt.join("sub/notes.txt"), "notes").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        let file = |path: &str| untracked::Entry { path: path.into(), files: 1 };
        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![file("sub/notes.txt"), file("sub/secret.env")]));
        let _ = fs::remove_dir_all(&root);
    }

    // git lists nothing inside a directory its index holds as a submodule,
    // so files written into one the worktree never populated are listed
    // under the submodule's path, and an ignored file beside it is an entry
    // of its own: the directory holding the submodule is not collapsed.
    #[test]
    fn unowned_entries_lists_files_in_a_submodule_directory_never_populated() {
        let root = std::env::temp_dir().join(format!("cs-unowned-unpopulated-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        let lib = root.join("sublib");
        fs::create_dir_all(&lib).unwrap();
        fs::write(lib.join("lib.txt"), "lib").unwrap();
        git_in(&lib, &["init", "-q"]);
        git_in(&lib, &["add", "-A"]);
        git_in(&lib, &["commit", "-qm", "lib"]);
        git_in(&wt, &["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.to_str().unwrap(), "vendor/sub"]);
        git_in(&wt, &["commit", "-qm", "add submodule"]);
        git_in(&wt, &["submodule", "deinit", "-q", "-f", "vendor/sub"]);
        assert_eq!(fs::read_dir(wt.join("vendor/sub")).unwrap().count(), 0, "fixture: the submodule directory is empty");
        fs::write(wt.join("vendor/trace.log"), "trace").unwrap();
        fs::write(root.join("proj/.git/info/exclude"), "CLAUDE.local.md\n.claude/settings.local.json\n*.log\n").unwrap();
        fs::create_dir_all(wt.join("vendor/sub/build")).unwrap();
        fs::write(wt.join("vendor/sub/build/notes.txt"), "notes").unwrap();
        fs::write(wt.join("vendor/sub/local.env"), "KEY=value").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        let entry = |path: &str| untracked::Entry { path: path.into(), files: 1 };
        assert_eq!(
            got,
            UnownedEntries::NotTrackedByGit(vec![
                entry("vendor/sub/build/"),
                entry("vendor/sub/local.env"),
                entry("vendor/trace.log"),
            ])
        );
        let _ = fs::remove_dir_all(&root);
    }

    // A repo that tracks .cs carries it through git (tracked mode), so an
    // untracked file under .cs is the user's work like one anywhere else;
    // only cs's machine-local files are left out. In ignored mode the whole
    // .cs is cs's.
    #[test]
    fn unowned_entries_lists_untracked_session_records_in_a_tracked_mode_worktree() {
        let root = std::env::temp_dir().join(format!("cs-unowned-tracked-cs-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        fs::write(wt.join(".cs/README.md"), "# records").unwrap();
        git_in(&wt, &["add", ".cs/README.md"]);
        git_in(&wt, &["commit", "-qm", "session records"]);
        fs::write(wt.join(".cs/local/state"), "cs_mode: tracked\n").unwrap();
        fs::create_dir_all(wt.join(".cs/memory")).unwrap();
        fs::write(wt.join(".cs/memory/new-topic.md"), "topic").unwrap();
        fs::write(wt.join(".cs/session.lock"), "").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(got, UnownedEntries::NotTrackedByGit(vec![untracked::Entry { path: ".cs/memory/".into(), files: 1 }]));
        fs::write(wt.join(".cs/local/state"), "cs_mode: ignored\n").unwrap();
        assert_eq!(unowned_entries("proj@task", &wt).unwrap(), UnownedEntries::NotTrackedByGit(Vec::new()));
        let _ = fs::remove_dir_all(&root);
    }

    // The mode is read from the state file's bytes, as `_read_local_state`
    // reads them: a byte that is not UTF-8 on another line leaves the
    // `cs_mode` line readable, so an ignored-mode worktree's .cs stays cs's.
    #[test]
    fn unowned_entries_reads_the_mode_from_a_state_file_holding_a_non_utf8_byte() {
        let root = std::env::temp_dir().join(format!("cs-unowned-state-bytes-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        fs::create_dir_all(wt.join(".cs/memory")).unwrap();
        fs::write(wt.join(".cs/memory/topic.md"), "topic").unwrap();
        fs::write(wt.join(".cs/local/state"), b"task_branch: cs/t\xff\ncs_mode: ignored\n").unwrap();

        let got = unowned_entries("proj@task", &wt).unwrap();

        assert_eq!(got, UnownedEntries::NotTrackedByGit(Vec::new()));
        let _ = fs::remove_dir_all(&root);
    }

    // The mode is the value `_read_local_state` reads (lib/40-state.sh): the
    // first line that starts `cs_mode:` wins, whitespace after the colon and
    // every double quote go, a CR before the newline stays (so a CRLF file
    // names no mode cs knows), and a last line without a newline counts.
    #[test]
    fn worktree_cs_mode_reads_the_value_cs_reads() {
        let dir = std::env::temp_dir().join(format!("cs-mode-read-{}", std::process::id()));
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        for (state, mode) in [
            (&b"cs_mode: ignored\r\n"[..], Some("ignored\r")),
            (b"cs_mode: tracked\ncs_mode: ignored\n", Some("tracked")),
            (b"cs_mode: \"ignored\"\n", Some("ignored")),
            (b"cs_mode:\t  ignored", Some("ignored")),
            (b" cs_mode: ignored\n", None),
            (b"task_branch: cs/t\n", None),
        ] {
            fs::write(dir.join(".cs/local/state"), state).unwrap();

            assert_eq!(worktree_cs_mode(&dir).as_deref(), mode, "{:?}", String::from_utf8_lossy(state));
        }
        let _ = fs::remove_dir_all(&dir);
    }

    // A `<base>@<task>` directory whose .git is a directory, not a worktree's
    // .git file, is no worktree of the base, so it is listed and removed as a
    // plain directory, as `cs -rm` does (it asks `[ -f .git ]`).
    #[test]
    fn a_worktree_name_whose_git_is_a_directory_is_listed_and_removed_as_a_plain_directory() {
        let root = std::env::temp_dir().join(format!("cs-unowned-git-dir-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("proj/.cs/local")).unwrap();
        let wt = root.join("proj@task");
        fs::create_dir_all(wt.join(".cs/local")).unwrap();
        git_in(&wt, &["init", "-q"]);
        fs::write(wt.join("notes.txt"), "draft").unwrap();
        assert!(wt.join(".git").is_dir(), "fixture: .git is a directory");

        let got = unowned_entries("proj@task", &wt);

        assert_eq!(got, Ok(UnownedEntries::NotCreatedByCs(vec!["notes.txt".into()])));
        let refused = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).map_err(|e| e.to_string());
        assert_eq!(refused, Err("proj@task holds files cs did not create: notes.txt".to_string()));
        let granted = RemoveGrants { unowned_files: true, ..RemoveGrants::default() };
        assert_eq!(remove_session_path(&root, "proj@task", &wt, granted).map_err(|e| e.to_string()), Ok(()));
        assert!(!wt.exists(), "the directory is removed");
        assert!(root.join("proj").is_dir(), "the base is left alone");
        let _ = fs::remove_dir_all(&root);
    }

    // A worktree session whose base is gone has no repository for git to ask,
    // so it is listed and removed as a plain directory, as `cs -rm` does:
    // every top-level entry cs did not create, tracked or not, then the
    // directory itself once those are granted.
    #[test]
    fn a_worktree_whose_base_is_gone_is_listed_and_removed_as_a_plain_directory() {
        let root = std::env::temp_dir().join(format!("cs-unowned-orphan-wt-{}", std::process::id()));
        let wt = worktree_beside_base(&root);
        fs::write(wt.join("notes.txt"), "draft").unwrap();
        fs::remove_dir_all(root.join("proj")).unwrap();
        assert!(wt.join(".git").is_file(), "fixture: the worktree still has its .git file");

        let got = unowned_entries("proj@task", &wt);

        assert_eq!(got, Ok(UnownedEntries::NotCreatedByCs(vec!["notes.txt".into(), "tracked.txt".into()])));
        let refused = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).map_err(|e| e.to_string());
        assert_eq!(refused, Err("proj@task holds files cs did not create: notes.txt, tracked.txt".to_string()));
        assert!(wt.join("notes.txt").exists(), "a refused removal keeps the files");
        let granted = RemoveGrants { unowned_files: true, ..RemoveGrants::default() };
        assert_eq!(remove_session_path(&root, "proj@task", &wt, granted).map_err(|e| e.to_string()), Ok(()));
        assert!(!wt.exists(), "the worktree directory is removed");
        let _ = fs::remove_dir_all(&root);
    }

    fn setup_session(root: &Path, name: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::write(
            dir.join(".cs/local/session.log"),
            "Claude Code Session Log\nSession: test\nStarted: 2026-01-15 10:30:00\n",
        )
        .unwrap();
        dir
    }

    /// A verbatim Claude Code session record, taken off disk with the paths and
    /// identifiers replaced. Pinning the real document shape here is the point:
    /// a fixture the parser itself generated could not catch a field cs reads
    /// under the wrong name or in the wrong format.
    ///
    /// Shared with tests/test_live.sh, which templates the same bytes for the
    /// bash reader. The two readers implement one contract in two languages and
    /// have drifted apart twice; a single document is what keeps them agreeing
    /// on field names, value types, and above all the procStart string format,
    /// which is the text both of them compare against `ps`.
    const REGISTRY_DOCUMENT: &str =
        include_str!("../../tests/fixtures/claude-session-record.json");

    #[test]
    fn agent_record_parses_a_real_session_document() {
        let r = parse_agent_record(REGISTRY_DOCUMENT).expect("record parses");
        assert_eq!(r.name, "demo");
        assert_eq!(r.status, "busy");
        assert_eq!(r.pid, 70260);
        assert_eq!(r.proc_start, "Sat Aug  8 07:11:34 2026");
    }

    /// This process is alive by definition and `ps` will confirm its start
    /// time, so a record naming it is the only hermetic way to exercise the
    /// liveness half of the contract without spawning anything.
    fn own_proc_start() -> String {
        let o = std::process::Command::new("ps")
            .env("TZ", "UTC")
            .args(["-o", "lstart=", "-p", &std::process::id().to_string()])
            .output()
            .expect("ps runs");
        String::from_utf8_lossy(&o.stdout).trim().to_string()
    }

    /// A registry directory holding exactly one record, so each contract case
    /// varies one field and nothing else. The label keeps concurrent tests in
    /// separate directories.
    fn registry_with(label: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cs-registry-{}-{}", label, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(format!("{}.json", std::process::id())), body).unwrap();
        dir
    }

    fn record(name: &str, status: &str) -> String {
        format!(
            r#"{{"pid":{},"name":"{}","status":"{}","procStart":"{}"}}"#,
            std::process::id(),
            name,
            status,
            own_proc_start()
        )
    }

    // ---- the contract shared with agent_states in lib/56-presence.sh ----
    //
    // These two readers answer the same question in two languages and have
    // drifted three times. Each case below is pinned on BOTH sides; when one
    // changes, the other has to change with it.

    #[test]
    fn agent_statuses_reads_a_live_record() {
        let dir = registry_with("live", &record("demo", "busy"));
        assert_eq!(
            agent_statuses_in(&dir).get("demo").map(String::as_str),
            Some("busy")
        );
    }

    #[test]
    fn agent_statuses_refuses_an_empty_name() {
        let dir = registry_with("emptyname", &record("", "busy"));
        assert!(
            agent_statuses_in(&dir).is_empty(),
            "an empty name earns no state: it can match no session, and admitting \
             it puts an empty key in the map"
        );
    }

    #[test]
    fn agent_statuses_refuses_an_empty_status() {
        let dir = registry_with("emptystatus", &record("demo", ""));
        assert!(
            agent_statuses_in(&dir).is_empty(),
            "an empty status carries no information and must not be rendered"
        );
    }

    #[test]
    fn agent_statuses_refuses_a_pid_that_is_not_a_number() {
        let body = format!(
            r#"{{"pid":"{}","name":"demo","status":"busy","procStart":"{}"}}"#,
            std::process::id(),
            own_proc_start()
        );
        let dir = registry_with("strpid", &body);
        assert!(
            agent_statuses_in(&dir).is_empty(),
            "a quoted pid is a malformed record, not a session"
        );
    }

    #[test]
    fn agent_statuses_refuses_a_record_with_no_start_time() {
        let body = format!(
            r#"{{"pid":{},"name":"demo","status":"busy"}}"#,
            std::process::id()
        );
        let dir = registry_with("nostart", &body);
        assert!(
            agent_statuses_in(&dir).is_empty(),
            "with no start time a record cannot be told from one a recycled pid left behind"
        );
    }

    #[test]
    fn agent_statuses_refuses_a_start_time_that_does_not_match() {
        let body = format!(
            r#"{{"pid":{},"name":"demo","status":"busy","procStart":"Mon Jan  1 00:00:00 2001"}}"#,
            std::process::id()
        );
        let dir = registry_with("badstart", &body);
        assert!(agent_statuses_in(&dir).is_empty(), "the pid was recycled");
    }

    #[test]
    fn agent_statuses_refuses_a_raw_control_byte() {
        let body = format!(
            "{{\"pid\":{},\"name\":\"demo\",\"status\":\"bu\u{1}sy\",\"procStart\":\"{}\"}}",
            std::process::id(),
            own_proc_start()
        );
        let dir = registry_with("rawctrl", &body);
        assert!(
            agent_statuses_in(&dir).is_empty(),
            "a raw control byte is not legal JSON, so the shell reader's jq rejects \
             the whole document; scanning for fields must not accept what jq refuses"
        );
    }

    #[test]
    fn agent_statuses_strips_an_escaped_control_character() {
        // Six characters -- backslash u 0 0 0 1 -- which is what valid JSON
        // carrying a control character looks like on disk. Assembled here so
        // nothing can quietly collapse it into a raw byte.
        let esc = format!("{}u0001", '\\');
        let body = format!(
            r#"{{"pid":{},"name":"demo","status":"bu{}sy","procStart":"{}"}}"#,
            std::process::id(),
            esc,
            own_proc_start()
        );
        let dir = registry_with("escctrl", &body);
        assert_eq!(
            agent_statuses_in(&dir).get("demo").map(String::as_str),
            Some("busy"),
            "an escaped control character is legal JSON; the shell reader decodes it \
             and scrubs the byte, so this reader must arrive at the same text"
        );
    }

    #[test]
    fn agent_statuses_is_empty_for_a_directory_that_does_not_exist() {
        let dir = std::env::temp_dir().join(format!("cs-registry-absent-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        assert!(agent_statuses_in(&dir).is_empty());
    }

    /// Manual smoke check: read the records Claude Code has actually published
    /// on this machine. A fixture cannot stand in for it, because the fixture
    /// and the reader would agree on a start-time format that Claude Code does
    /// not use. Ignored by default so no CI run depends on a live session.
    /// Run with: cargo test -- --ignored live_registry
    #[test]
    #[ignore]
    fn agent_statuses_read_the_live_registry() {
        let dir = live_claude_sessions_dir();
        let published = fs::read_dir(&dir).map(|e| e.count()).unwrap_or(0);
        let statuses = agent_statuses_in(&dir);
        eprintln!("{} document(s) in {:?} -> {:?}", published, dir, statuses);
        assert!(
            published == 0 || !statuses.is_empty(),
            "records exist but none survived the liveness cross-check"
        );
    }

    #[test]
    fn agent_record_rejects_a_document_missing_the_fields_cs_reads() {
        assert!(parse_agent_record("{\"pid\":1,\"name\":\"demo\"}").is_none());
        assert!(parse_agent_record("not json").is_none());
    }

    #[test]
    fn unread_mail_counts_new_json_documents() {
        let dir = std::env::temp_dir().join(format!("cs-unread-{}", std::process::id()));
        let new = dir.join("local/mail/new");
        let cur = dir.join("local/mail/cur");
        fs::create_dir_all(&new).unwrap();
        fs::create_dir_all(&cur).unwrap();
        fs::write(new.join("0000000001-a.json"), "{\"a\":1}\n").unwrap();
        fs::write(new.join("0000000002-b.json"), "{\"a\":2}\n").unwrap();
        // read mail lives in cur/ and is not unread
        fs::write(cur.join("0000000000-read.json"), "{\"a\":0}\n").unwrap();
        assert_eq!(unread_mail_count(&dir), 2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn unread_mail_ignores_non_json_entries() {
        let dir = std::env::temp_dir().join(format!("cs-unread-stray-{}", std::process::id()));
        let new = dir.join("local/mail/new");
        fs::create_dir_all(new.join("subdir")).unwrap();
        fs::write(new.join("0000000001-a.json"), "{\"a\":1}\n").unwrap();
        // Strays a scan must not count: a Finder droplet, a staging leftover,
        // and a subdirectory. A phantom unread here would badge forever,
        // because cs -msg only clears new/*.json.
        fs::write(new.join(".DS_Store"), "stray").unwrap();
        fs::write(new.join("0000000002-b.json.partial"), "{\"a\":2").unwrap();
        assert_eq!(
            unread_mail_count(&dir),
            1,
            "only new/*.json files count as unread"
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    // An encrypted session keeps its queue behind .cs/private: the scan's
    // depth, the notes panel and the editor all read it there, and a locked
    // vault reads as an empty queue.
    #[test]
    fn queue_reads_the_private_dir() {
        let dir = std::env::temp_dir().join(format!("cs-queue-private-{}", std::process::id()));
        let vault = dir.join("vault/private");
        fs::create_dir_all(vault.join("queue")).unwrap();
        fs::create_dir_all(dir.join("root/vt/.cs/local")).unwrap();
        std::os::unix::fs::symlink(&vault, dir.join("root/vt/.cs/private")).unwrap();
        fs::write(vault.join("queue/0000000001-a"), "sealed task\n").unwrap();
        fs::write(vault.join("queue.state"), "draining\n").unwrap();
        let _root = test_root::scoped(dir.join("root"));
        assert_eq!(queue_dir("vt"), dir.join("root/vt/.cs/private"));
        assert_eq!(read_queue("vt"), vec!["sealed task".to_string()]);
        assert!(queue_active("vt"));
        let scanned = scan_sessions_in(&dir.join("root"));
        assert_eq!(scanned.iter().find(|s| s.name == "vt").map(|s| s.queue_depth), Some(1));
        fs::rename(dir.join("vault"), dir.join("unmounted")).unwrap();
        assert!(read_queue("vt").is_empty());
        fs::remove_dir_all(&dir).unwrap();
    }

    // An encrypted session keeps its mailbox behind .cs/private, a link into
    // its vault; while that link dangles (the vault locked) nothing counts.
    #[test]
    fn unread_mail_counts_the_private_mailbox() {
        let dir = std::env::temp_dir().join(format!("cs-unread-private-{}", std::process::id()));
        let vault = dir.join("vault/private");
        let new = vault.join("mail/new");
        fs::create_dir_all(&new).unwrap();
        fs::create_dir_all(dir.join("meta")).unwrap();
        std::os::unix::fs::symlink(&vault, dir.join("meta/private")).unwrap();
        fs::write(new.join("0000000001-a.json"), "{\"a\":1}\n").unwrap();
        fs::write(new.join("0000000002-b.json"), "{\"a\":2}\n").unwrap();
        assert_eq!(unread_mail_count(&dir.join("meta")), 2);
        fs::rename(dir.join("vault"), dir.join("unmounted")).unwrap();
        assert_eq!(unread_mail_count(&dir.join("meta")), 0);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn unread_mail_is_zero_without_maildir() {
        let dir = std::env::temp_dir().join(format!("cs-unread-none-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(unread_mail_count(&dir), 0);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn liveness_helpers_map_each_variant() {
        assert!(Liveness::Locked(42).is_live());
        assert!(Liveness::Locked(42).is_locked());
        assert_eq!(Liveness::Locked(42).lock_pid(), Some(42));

        assert!(Liveness::Heartbeat.is_live());
        assert!(!Liveness::Heartbeat.is_locked());
        assert_eq!(Liveness::Heartbeat.lock_pid(), None);

        assert!(!Liveness::Dormant.is_live());
        assert!(!Liveness::Dormant.is_locked());
        assert_eq!(Liveness::Dormant.lock_pid(), None);

        let served = Liveness::Served { lock: 42, server: 77 };
        assert!(served.is_live());
        assert!(served.is_locked());
        assert_eq!(served.lock_pid(), Some(42), "lock_pid reads the lock, not remote.pid");
    }

    /// A session `cs <name> --remote` serves: a live session lock, and
    /// .cs/local/remote.pid naming the server.
    fn served_session(tag: &str, remote_pid: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cs-served-{tag}-{}", std::process::id()));
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::write(dir.join(".cs/session.lock"), format!("{}\n", std::process::id())).unwrap();
        fs::write(dir.join(".cs/local/remote.pid"), remote_pid).unwrap();
        dir
    }

    /// A process whose argv carries `remote-control --name <name>`, as the
    /// server of session <name> does.
    fn fake_server_process(name: &str) -> std::process::Child {
        std::process::Command::new("perl")
            .args(["-e", "sleep 30", "remote-control", "--name", name, "--permission-mode", "default"])
            .spawn()
            .unwrap()
    }

    fn dir_name(dir: &Path) -> String {
        dir.file_name().unwrap().to_string_lossy().to_string()
    }

    #[test]
    fn a_session_with_a_running_server_reads_as_served_with_both_pids() {
        let dir = served_session("live", "");
        let mut server = fake_server_process(&dir_name(&dir));
        fs::write(dir.join(".cs/local/remote.pid"), format!("{}\n", server.id())).unwrap();

        let session = read_session(&dir, &HashMap::new());

        let _ = server.kill();
        let _ = server.wait();
        assert_eq!(
            session.liveness,
            Liveness::Served { lock: std::process::id(), server: server.id() }
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// A server whose release never ran leaves remote.pid naming its pid; once
    /// another program has that pid, the session is not served.
    #[test]
    fn a_session_whose_server_pid_runs_another_program_reads_as_locked() {
        let mut other = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let dir = served_session("reused", &format!("{}\n", other.id()));

        let session = read_session(&dir, &HashMap::new());

        let _ = other.kill();
        let _ = other.wait();
        assert_eq!(session.liveness, Liveness::Locked(std::process::id()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_session_whose_server_pid_is_not_running_reads_as_locked() {
        let dir = served_session("stale", "99999999\n");

        let session = read_session(&dir, &HashMap::new());

        assert_eq!(session.liveness, Liveness::Locked(std::process::id()));
        let _ = fs::remove_dir_all(&dir);
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

    // An encrypted session keeps its log behind .cs/private, a link into its
    // vault; the picker's created date comes from there.
    #[test]
    fn find_log_file_reads_the_private_log() {
        let dir = std::env::temp_dir().join(format!("cs-test-private-log-{}", std::process::id()));
        let vault = dir.join("vault/private");
        fs::create_dir_all(&vault).unwrap();
        fs::create_dir_all(dir.join("vt/.cs")).unwrap();
        std::os::unix::fs::symlink(&vault, dir.join("vt/.cs/private")).unwrap();
        fs::write(vault.join("session.log"), "Claude Code Session Log\nSession: vt\nStarted: 2026-03-04 05:06:00\n").unwrap();

        let log = find_log_file(&dir.join("vt"));

        assert_eq!(log, Some(dir.join("vt/.cs/private/session.log")));
        assert_eq!(parse_created(&log.unwrap()), Some("2026-03-04 05:06".to_string()));
        fs::remove_dir_all(&dir).unwrap();
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
    fn remove_worktree_session_unregisters_from_the_base_repo() {
        let git = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(["-c", "user.email=t@t", "-c", "user.name=t"])
                .args(args)
                .output()
                .expect("git runs");
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        let root = std::env::temp_dir().join(format!("cs-wt-rm-{}", std::process::id()));
        let base = root.join("proj");
        std::fs::create_dir_all(&base).unwrap();
        git(&base, &["init", "-q"]);
        std::fs::write(base.join("f"), "x").unwrap();
        git(&base, &["add", "f"]);
        git(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        assert!(wt.join(".git").is_file(), "worktree marker file expected");

        remove_worktree_session(&root, "proj@task", &wt).unwrap();

        assert!(!wt.exists(), "worktree directory should be gone");
        let list = std::process::Command::new("git")
            .arg("-C")
            .arg(&base)
            .args(["worktree", "list"])
            .output()
            .unwrap();
        assert!(
            !String::from_utf8_lossy(&list.stdout).contains("proj@task"),
            "base repo must not keep a stale worktree registration"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    // git reads the worktree path after --, so a path starting with a dash is
    // a path and not an option. A relative one is taken from the base repo,
    // the directory git runs in (-C).
    #[test]
    fn remove_worktree_session_removes_a_worktree_whose_path_starts_with_a_dash() {
        let root = std::env::temp_dir().join(format!("cs-wt-dash-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        git_in(&base, &["init", "-q"]);
        fs::write(base.join("f"), "x").unwrap();
        git_in(&base, &["add", "f"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = base.join("-rtask");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        assert!(wt.join(".git").is_file(), "worktree marker file expected");

        remove_worktree_session(&root, "proj@task", Path::new("-rtask")).unwrap();

        assert!(!wt.exists(), "worktree directory should be gone");
        let list = std::process::Command::new("git")
            .arg("-C")
            .arg(&base)
            .args(["worktree", "list"])
            .output()
            .unwrap();
        assert!(
            !String::from_utf8_lossy(&list.stdout).contains("-rtask"),
            "base repo must not keep a stale worktree registration"
        );
        let _ = fs::remove_dir_all(&root);
    }

    // `cs -rm` stops when git refuses to remove a worktree; deleting the
    // directory anyway would leave the base repo registering a worktree that
    // is gone. A locked worktree is one git refuses under a single --force.
    #[test]
    fn remove_session_path_returns_the_git_error_and_keeps_a_worktree_git_refuses() {
        let root = std::env::temp_dir().join(format!("cs-wt-refused-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        git_in(&base, &["init", "-q"]);
        fs::write(base.join("f"), "x").unwrap();
        git_in(&base, &["add", "f"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        git_in(&base, &["worktree", "lock", wt.to_str().unwrap()]);
        fs::create_dir_all(root.join(".spawn")).unwrap();
        fs::write(root.join(".spawn/proj@task.seed"), "spawner\n").unwrap();

        let err = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).unwrap_err();

        let text = err.to_string();
        assert!(
            text.starts_with(&format!("git worktree remove failed for {}: ", wt.display())),
            "error should name the failed git step, got: {text}"
        );
        assert!(text.contains("locked"), "error should carry git's reason, got: {text}");
        assert!(wt.join("f").exists(), "the refused worktree keeps its files");
        let list = std::process::Command::new("git")
            .arg("-C")
            .arg(&base)
            .args(["worktree", "list"])
            .output()
            .unwrap();
        assert!(
            String::from_utf8_lossy(&list.stdout).contains("proj@task"),
            "the registration stays consistent with the directory"
        );
        assert!(root.join(".spawn/proj@task.seed").exists(), "a refused delete discards nothing");
        let _ = fs::remove_dir_all(&root);
    }

    // `cs -rm` re-reads the lock when it runs (session_is_live); the picker's
    // row can be minutes old, so the removal itself must refuse a session that
    // took the lock since the last scan.
    #[test]
    fn remove_session_path_refuses_a_session_whose_lock_is_live_now() {
        let root = std::env::temp_dir().join(format!("cs-rm-live-{}", std::process::id()));
        let dir = root.join("busy");
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        let pid = std::process::id();
        fs::write(dir.join(".cs/session.lock"), format!("{pid}\n")).unwrap();

        let err = remove_session_path(&root, "busy", &dir, RemoveGrants::default()).unwrap_err();

        assert_eq!(err.to_string(), format!("busy is live (pid {pid}) — close it first"));
        assert!(dir.join(".cs/session.lock").exists(), "a live session is left whole");

        // Past the live lock, as `cs -rm --force` goes.
        let grants = RemoveGrants { past_live_lock: true, ..RemoveGrants::default() };
        remove_session_path(&root, "busy", &dir, grants).unwrap();
        assert!(!dir.exists(), "granted the live lock, the removal goes ahead");
        let _ = fs::remove_dir_all(&root);
    }

    /// A fresh sessions root under the temp dir holding `live` as sessions
    /// whose lock this test process holds and `dormant` as sessions with no
    /// lock, each with only cs's own files.
    fn caller_fixture(tag: &str, live: &[&str], dormant: &[&str]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("cs-rm-caller-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for name in live.iter().chain(dormant) {
            fs::create_dir_all(root.join(name).join(".cs/local")).unwrap();
        }
        for name in live {
            fs::write(root.join(name).join(".cs/session.lock"), format!("{}\n", std::process::id())).unwrap();
        }
        root
    }

    // From inside another session, `cs -rm` refuses a live session before its
    // own lock check (_refuse_live_other_session, lib/15-lock.sh), in its own
    // words, so the picker's removal does too.
    #[test]
    fn remove_session_path_refuses_another_sessions_live_session() {
        let root = caller_fixture("other", &["busy"], &["caller"]);
        let _caller = test_caller::scoped("caller");
        let pid = std::process::id();

        let err = remove_session_path(&root, "busy", &root.join("busy"), RemoveGrants::default()).unwrap_err();

        assert_eq!(
            err.to_string(),
            format!("session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "a refused session is left whole");
        let _ = fs::remove_dir_all(&root);
    }

    // `cs -rm --force` does not override that refusal from another session,
    // and neither does the picker's [F] grant.
    #[test]
    fn remove_session_path_refuses_another_sessions_live_session_past_the_live_grant() {
        let root = caller_fixture("other-forced", &["busy"], &["caller"]);
        let _caller = test_caller::scoped("caller");
        let pid = std::process::id();
        let grants = RemoveGrants { past_live_lock: true, unowned_files: true };

        let err = remove_session_path(&root, "busy", &root.join("busy"), grants).unwrap_err();

        assert_eq!(
            err.to_string(),
            format!("session caller cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
        );
        assert!(root.join("busy/.cs/session.lock").exists(), "a refused session is left whole");
        let _ = fs::remove_dir_all(&root);
    }

    // A session deleting itself is not another session: the plain live check
    // refuses it and the [F] grant takes it past, as `cs -rm --force` does.
    // The name is matched byte for byte, as cs compares it: `Busy` is
    // another session.
    #[test]
    fn remove_session_path_leaves_the_callers_own_session_to_the_live_check() {
        let root = caller_fixture("own", &["busy"], &[]);
        let pid = std::process::id();
        {
            let _caller = test_caller::scoped("Busy");
            let err = remove_session_path(&root, "busy", &root.join("busy"), RemoveGrants::default()).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("session Busy cannot remove session busy while it is live (pid {pid}); --force does not override that from another session. Close busy first.")
            );
        }
        let _caller = test_caller::scoped("busy");

        let err = remove_session_path(&root, "busy", &root.join("busy"), RemoveGrants::default()).unwrap_err();

        assert_eq!(err.to_string(), format!("busy is live (pid {pid}) — close it first"));
        let grants = RemoveGrants { past_live_lock: true, ..RemoveGrants::default() };
        remove_session_path(&root, "busy", &root.join("busy"), grants).unwrap();
        assert!(!root.join("busy").exists(), "the caller's own session goes past the live grant");
        let _ = fs::remove_dir_all(&root);
    }

    // A base owns its features (<base>@<task>): from the base, a live feature
    // is left to the plain live check, as `cs -rm` exempts it. A feature owns
    // no sibling: from proj@other, proj@task is another session.
    #[test]
    fn remove_session_path_leaves_a_bases_own_feature_to_the_live_check() {
        let root = caller_fixture("own-feature", &["proj@task"], &["proj", "proj@other"]);
        let pid = std::process::id();
        let wt = root.join("proj@task");
        {
            let _caller = test_caller::scoped("proj@other");
            let err = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).unwrap_err();
            assert_eq!(
                err.to_string(),
                format!("session proj@other cannot remove session proj@task while it is live (pid {pid}); --force does not override that from another session. Close proj@task first.")
            );
        }
        let _caller = test_caller::scoped("proj");

        let err = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).unwrap_err();

        assert_eq!(err.to_string(), format!("proj@task is live (pid {pid}) — close it first"));
        let grants = RemoveGrants { past_live_lock: true, ..RemoveGrants::default() };
        remove_session_path(&root, "proj@task", &wt, grants).unwrap();
        assert!(!wt.exists(), "the base removes its own feature past the live grant");
        let _ = fs::remove_dir_all(&root);
    }

    // A feature's worktree points into its base's repository, so from any
    // session but the base, `cs -rm` refuses a base while one of its features
    // is live (_refuse_base_with_live_feature, lib/15-lock.sh), --force or
    // not, the live feature itself included. A feature of another base whose
    // name starts with this one's is not this base's.
    #[test]
    fn remove_session_path_refuses_a_base_with_a_live_feature_from_another_session() {
        let root = caller_fixture("base", &["proj@task", "projx@task"], &["proj", "other"]);
        let pid = std::process::id();
        let all = RemoveGrants { past_live_lock: true, unowned_files: true };
        for caller in ["other", "proj@task"] {
            let _caller = test_caller::scoped(caller);
            for grants in [RemoveGrants::default(), all] {
                let err = remove_session_path(&root, "proj", &root.join("proj"), grants).unwrap_err();
                assert_eq!(
                    err.to_string(),
                    format!("session {caller} cannot remove session proj while its feature proj@task is live (pid {pid}); --force does not override that from another session. Close proj@task first."),
                    "caller {caller}, grants {grants:?}"
                );
            }
        }
        assert!(root.join("proj/.cs").is_dir(), "a refused base is left whole");

        fs::write(root.join("proj@task/.cs/session.lock"), "99999999\n").unwrap();
        let _caller = test_caller::scoped("other");
        remove_session_path(&root, "proj", &root.join("proj"), RemoveGrants::default()).unwrap();
        assert!(!root.join("proj").exists(), "with only another base's feature live, the base goes");
        let _ = fs::remove_dir_all(&root);
    }

    // A feature is the base's when `<base>@<its task>` is the same directory
    // (`-ef` in _refuse_base_with_live_feature), not when the names match:
    // an entry that links to proj@task is proj's feature too, and as the
    // first in sorted order it is the one the refusal names, as cs's glob
    // names it.
    #[test]
    fn remove_session_path_names_a_bases_live_feature_reached_through_a_link() {
        let root = caller_fixture("base-link", &["proj@task"], &["proj", "other"]);
        std::os::unix::fs::symlink(root.join("proj@task"), root.join("alias@task")).unwrap();
        let _caller = test_caller::scoped("other");
        let pid = std::process::id();

        let err = remove_session_path(&root, "proj", &root.join("proj"), RemoveGrants::default()).unwrap_err();

        assert_eq!(
            err.to_string(),
            format!("session other cannot remove session proj while its feature alias@task is live (pid {pid}); --force does not override that from another session. Close alias@task first.")
        );
        assert!(root.join("proj/.cs").is_dir(), "a refused base is left whole");
        let _ = fs::remove_dir_all(&root);
    }

    // cs's `"$SESSIONS_ROOT"/*@*` glob never reads a dot entry, so a
    // `.proj@task` that is the same directory as proj@task is not the
    // feature the refusal names.
    #[test]
    fn remove_session_path_never_names_a_dot_entry_as_a_bases_live_feature() {
        let root = caller_fixture("base-dot", &["proj@task"], &["proj", "other"]);
        std::os::unix::fs::symlink(root.join("proj@task"), root.join(".proj@task")).unwrap();
        let _caller = test_caller::scoped("other");
        let pid = std::process::id();

        let err = remove_session_path(&root, "proj", &root.join("proj"), RemoveGrants::default()).unwrap_err();

        assert_eq!(
            err.to_string(),
            format!("session other cannot remove session proj while its feature proj@task is live (pid {pid}); --force does not override that from another session. Close proj@task first.")
        );
        let _ = fs::remove_dir_all(&root);
    }

    // A base owns only `<base>@<task>`: from proj, projx is another session
    // whose name merely starts with proj's, and so is projx@task, so a live
    // one is refused in _refuse_live_other_session's words, past the [F]
    // grant too.
    #[test]
    fn remove_session_path_refuses_a_live_session_whose_name_only_starts_with_the_callers() {
        let root = caller_fixture("prefix", &["projx", "projx@task"], &["proj"]);
        let _caller = test_caller::scoped("proj");
        let pid = std::process::id();
        let all = RemoveGrants { past_live_lock: true, unowned_files: true };
        for name in ["projx", "projx@task"] {
            for grants in [RemoveGrants::default(), all] {
                let err = remove_session_path(&root, name, &root.join(name), grants).unwrap_err();
                assert_eq!(
                    err.to_string(),
                    format!("session proj cannot remove session {name} while it is live (pid {pid}); --force does not override that from another session. Close {name} first."),
                    "grants {grants:?}"
                );
            }
            assert!(root.join(name).join(".cs/session.lock").exists(), "a refused {name} is left whole");
        }
        let _ = fs::remove_dir_all(&root);
    }

    // The base itself may remove itself while its feature runs, as `cs -rm`
    // lets it.
    #[test]
    fn remove_session_path_lets_a_base_remove_itself_with_a_live_feature() {
        let root = caller_fixture("base-self", &["proj@task"], &["proj"]);
        let _caller = test_caller::scoped("proj");

        remove_session_path(&root, "proj", &root.join("proj"), RemoveGrants::default()).unwrap();

        assert!(!root.join("proj").exists(), "the base removes itself");
        assert!(root.join("proj@task/.cs/session.lock").exists(), "its feature is left alone");
        let _ = fs::remove_dir_all(&root);
    }

    // Outside every session nothing is another session's: a live session goes
    // past the [F] grant, and a base goes while its feature runs, as `cs -rm`
    // from a plain terminal does.
    #[test]
    fn remove_session_path_outside_every_session_refuses_neither() {
        let root = caller_fixture("no-caller", &["busy", "proj@task"], &["proj"]);
        let grants = RemoveGrants { past_live_lock: true, ..RemoveGrants::default() };

        remove_session_path(&root, "busy", &root.join("busy"), grants).unwrap();
        remove_session_path(&root, "proj", &root.join("proj"), RemoveGrants::default()).unwrap();

        assert!(!root.join("busy").exists(), "a live session goes past the live grant");
        assert!(!root.join("proj").exists(), "a base goes while its feature runs");
        let _ = fs::remove_dir_all(&root);
    }

    // A session root is also the user's workspace. As `cs -rm --force` does
    // without --delete-files, the removal refuses one that holds files cs did
    // not create, naming them, and deletes nothing. It names them as the
    // listing prints them: each control character, and each character that
    // flips the direction of the text after it or takes no room, as one '?',
    // an accent and a space as written.
    #[test]
    fn remove_session_path_refuses_a_root_holding_files_cs_did_not_create() {
        let root = std::env::temp_dir().join(format!("cs-rm-foreign-{}", std::process::id()));
        let dir = root.join("rel");
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::create_dir_all(dir.join("journal.sparsebundle")).unwrap();
        fs::write(dir.join("start"), "x").unwrap();
        fs::write(dir.join("caf\u{e9} \u{202e}txt.exe\u{200b}.md"), "x").unwrap();
        fs::write(dir.join("esc\u{1b}[1m.txt"), "x").unwrap();

        let err = remove_session_path(&root, "rel", &dir, RemoveGrants::default()).unwrap_err();

        assert_eq!(
            err.to_string(),
            "rel holds files cs did not create: caf\u{e9} ?txt.exe?.md, esc?[1m.txt, journal.sparsebundle, start"
        );
        assert!(dir.join("start").exists(), "the user's files survive");

        let grants = RemoveGrants { unowned_files: true, ..RemoveGrants::default() };
        remove_session_path(&root, "rel", &dir, grants).unwrap();
        assert!(!dir.exists(), "granted the files, the removal takes them");
        let _ = fs::remove_dir_all(&root);
    }

    // A worktree session's untracked and ignored files have no copy on the
    // branch; as `cs -rm --force` does without --delete-files, the removal
    // refuses, naming them, and leaves the worktree registered.
    #[test]
    fn remove_session_path_refuses_a_worktree_holding_files_git_does_not_track() {
        let root = std::env::temp_dir().join(format!("cs-rm-untracked-{}", std::process::id()));
        let base = root.join("proj");
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("tracked.txt"), "x").unwrap();
        git_in(&base, &["init", "-q"]);
        git_in(&base, &["add", "tracked.txt"]);
        git_in(&base, &["commit", "-qm", "seed"]);
        let wt = root.join("proj@task");
        git_in(&base, &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "cs/task"]);
        fs::write(wt.join("notes.txt"), "draft").unwrap();

        let err = remove_session_path(&root, "proj@task", &wt, RemoveGrants::default()).unwrap_err();

        assert_eq!(err.to_string(), "proj@task holds 1 file git does not track: notes.txt");
        assert!(wt.join("notes.txt").exists(), "the untracked file survives");

        let grants = RemoveGrants { unowned_files: true, ..RemoveGrants::default() };
        remove_session_path(&root, "proj@task", &wt, grants).unwrap();
        assert!(!wt.exists(), "granted the files, the removal takes the worktree");
        let _ = fs::remove_dir_all(&root);
    }

    // An encrypted session mounts its vault inside the session directory by
    // convention, and remove_dir_all recurses into a mount: deleting the
    // session would delete what the vault holds. Unmounted, the link dangles
    // and the delete goes ahead.
    #[test]
    fn remove_session_path_refuses_while_the_vault_is_mounted_inside() {
        let root = std::env::temp_dir().join(format!("cs-rm-vault-{}", std::process::id()));
        let dir = root.join("vt");
        let vault = dir.join(".cs/vault-mnt/memory");
        fs::create_dir_all(&vault).unwrap();
        fs::write(vault.join("narrative.md"), "sealed\n").unwrap();
        std::os::unix::fs::symlink(&vault, dir.join(".cs/memory")).unwrap();

        let err = remove_session_path(&root, "vt", &dir, RemoveGrants::default()).unwrap_err();

        assert_eq!(
            err.to_string(),
            format!(
                "vt has encrypted storage mounted inside it: .cs/memory points at {}; unmount it, then retry",
                vault.display()
            )
        );
        assert!(vault.join("narrative.md").exists(), "the vault's contents survive");

        fs::remove_dir_all(&vault).unwrap();
        remove_session_path(&root, "vt", &dir, RemoveGrants::default()).unwrap();
        assert!(!dir.exists(), "an unmounted encrypted session is removed");
        let _ = fs::remove_dir_all(&root);
    }

    // A cs -encrypt that stops partway leaves its volume mounted at
    // .cs/vault-mnt with no vault link yet, so only the mount table shows it.
    #[test]
    fn mount_under_finds_a_volume_mounted_inside_the_session() {
        let root = std::env::temp_dir().join(format!("cs-mount-under-{}", std::process::id()));
        let dir = root.join("h1");
        let mnt = dir.join(".cs/vault-mnt");
        fs::create_dir_all(&mnt).unwrap();
        let macos = format!(
            "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)\n\
             /dev/disk9s1 on {} (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)\n",
            mnt.display()
        );
        let linux = format!(
            "/dev/sda1 on / type ext4 (rw,relatime)\n/dev/loop9 on {} type ext4 (rw,relatime)\n",
            mnt.display()
        );

        assert_eq!(mount_under(&dir, &macos), Some(mnt.clone()), "macOS table");
        assert_eq!(mount_under(&dir, &linux), Some(mnt.clone()), "Linux table, type dropped");
        let _ = fs::remove_dir_all(&root);
    }

    // "h1x" beside "h1": a string-prefix match would refuse the wrong session.
    #[test]
    fn mount_under_ignores_a_volume_in_another_session() {
        let root = std::env::temp_dir().join(format!("cs-mount-other-{}", std::process::id()));
        let dir = root.join("h1");
        let other = root.join("h1x/.cs/vault-mnt");
        fs::create_dir_all(&dir).unwrap();
        fs::create_dir_all(&other).unwrap();
        let table = format!("/dev/r on / (apfs, local)\n/dev/disk9s1 on {} (apfs, local)\n", other.display());

        assert_eq!(mount_under(&dir, &table), None);
        let _ = fs::remove_dir_all(&root);
    }

    // A mount source may itself hold " on " (an NFS export, an SMB share), or
    // end in " on", so that its " on" and the separator share one space.
    #[test]
    fn mount_under_reads_a_mount_whose_source_holds_on() {
        let root = std::env::temp_dir().join(format!("cs-mount-src-on-{}", std::process::id()));
        let dir = root.join("h1");
        let mnt = dir.join(".cs/vault-mnt");
        fs::create_dir_all(&mnt).unwrap();

        for source in ["host:/export on disk", "host:/export on"] {
            let macos = format!("{source} on {} (nfs)\n", mnt.display());
            let linux = format!("{source} on {} type nfs (rw)\n", mnt.display());
            assert_eq!(mount_under(&dir, &macos), Some(mnt.clone()), "{macos}");
            assert_eq!(mount_under(&dir, &linux), Some(mnt.clone()), "{linux}");
        }
        let _ = fs::remove_dir_all(&root);
    }

    // A mount point is always absolute: text after an " on " inside a source
    // must not resolve against the working directory (the package root under
    // cargo test, where src/ exists).
    #[test]
    fn mount_under_never_reads_a_relative_path() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");

        assert_eq!(mount_under(&src, "map on src (autofs, nobrowse)\n"), None);
    }

    // macOS never prints " type <fs>", so a path holding " type " is still the
    // mount point, not a Linux line to cut short.
    #[test]
    fn mount_under_reads_a_macos_mount_point_holding_type() {
        let root = std::env::temp_dir().join(format!("cs-mount-type-{}/project type archive", std::process::id()));
        let dir = root.join("h1");
        let mnt = dir.join(".cs/vault-mnt");
        fs::create_dir_all(&mnt).unwrap();
        let table = format!("/dev/disk9s1 on {} (apfs, local, nodev, nosuid, journaled)\n", mnt.display());

        assert_eq!(mount_under(&dir, &table), Some(mnt.clone()));
        let _ = fs::remove_dir_all(root.parent().unwrap());
    }

    // A brief left behind would reach a later same-name spawn as a first
    // prompt nobody wrote for it, so it goes with the seed.
    #[test]
    fn remove_session_path_discards_every_spawn_staging_file() {
        let root = std::env::temp_dir().join(format!("cs-seed-rm-{}", std::process::id()));
        let dir = root.join("seeded");
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::create_dir_all(root.join(".spawn")).unwrap();
        fs::write(root.join(".spawn/seeded.seed"), "spawner\ntask\n").unwrap();
        fs::write(root.join(".spawn/seeded.seed.stale"), "old\n").unwrap();
        fs::write(root.join(".spawn/seeded.brief.md"), "do this\n").unwrap();
        fs::write(root.join(".spawn/seeded.brief.md.stale"), "old brief\n").unwrap();
        fs::write(root.join(".spawn/other.seed"), "other\n").unwrap();
        fs::write(root.join(".spawn/other.brief.md"), "theirs\n").unwrap();
        // An interrupted `cs -spawn` leaves its staging file; the one for a
        // session named `seeded.seed` must not be mistaken for it.
        fs::write(root.join(".spawn/.seeded.seed.Ab12Cd"), "killed\n").unwrap();
        fs::write(root.join(".spawn/.seeded.seed.seed.Ef34Gh"), "theirs\n").unwrap();
        // An open killed outright leaves the seed it claimed; session
        // `seeded.seed.claim`'s claim starts the same way.
        fs::write(root.join(".spawn/.seeded.seed.claim.4242"), "claimed\n").unwrap();
        fs::write(root.join(".spawn/.seeded.seed.claim.seed.claim.77"), "theirs\n").unwrap();

        remove_session_path(&root, "seeded", &dir, RemoveGrants::default()).unwrap();

        assert!(!dir.exists(), "session directory should be gone");
        assert!(!root.join(".spawn/seeded.seed").exists(), "seed must go with the session");
        assert!(!root.join(".spawn/seeded.seed.stale").exists(), "stale seed must go too");
        assert!(!root.join(".spawn/seeded.brief.md").exists(), "brief must go with the session");
        assert!(!root.join(".spawn/seeded.brief.md.stale").exists(), "stale brief must go too");
        assert!(root.join(".spawn/other.seed").exists(), "other sessions' seeds stay");
        assert!(root.join(".spawn/other.brief.md").exists(), "other sessions' briefs stay");
        assert!(!root.join(".spawn/.seeded.seed.Ab12Cd").exists(), "an interrupted spawn's staging file must go too");
        assert!(root.join(".spawn/.seeded.seed.seed.Ef34Gh").exists(), "another session's staging file stays");
        assert!(!root.join(".spawn/.seeded.seed.claim.4242").exists(), "a killed open's claimed seed must go too");
        assert!(root.join(".spawn/.seeded.seed.claim.seed.claim.77").exists(), "another session's claim stays");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn heartbeat_alive_tracks_context_pct_freshness() {
        let tmp = std::env::temp_dir().join(format!("cs-hb-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();

        // No context-pct at all: not live.
        assert!(!heartbeat_alive(&tmp, std::time::SystemTime::now()));

        // Production layout: the heartbeat lives under .cs/local/, one level
        // below the lock's meta dir.
        std::fs::create_dir_all(tmp.join("local")).unwrap();
        std::fs::write(tmp.join("local/context-pct"), "42").unwrap();
        let mtime =
            std::fs::metadata(tmp.join("local/context-pct")).unwrap().modified().unwrap();

        // Written within the window: live.
        let soon = mtime + std::time::Duration::from_secs(30);
        assert!(heartbeat_alive(&tmp, soon));
        // Window edge passed: dormant again.
        let late = mtime + std::time::Duration::from_secs(HEARTBEAT_WINDOW_SECS + 1);
        assert!(!heartbeat_alive(&tmp, late));
        // A future mtime clamps to live, like the recency math.
        let before = mtime - std::time::Duration::from_secs(60);
        assert!(heartbeat_alive(&tmp, before));

        let _ = std::fs::remove_dir_all(&tmp);
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

    // The lock rule cs and cs-secrets read by: the text, surrounding whitespace
    // removed, is decimal digits naming a running process; a sign is not part
    // of a pid, so "+<pid>" names none even when <pid> is running.
    #[test]
    fn read_lock_pid_reads_the_lock_by_the_one_lock_rule() {
        let dir = std::env::temp_dir().join(format!("cs-test-lockrule-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let own_pid = std::process::id();

        fs::write(dir.join("session.lock"), format!("+{own_pid}")).unwrap();
        assert_eq!(read_lock_pid(&dir), None, "a signed pid is not a pid");

        fs::write(dir.join("session.lock"), format!(" \t00{own_pid}\n\n")).unwrap();
        assert_eq!(read_lock_pid(&dir), Some(own_pid), "whitespace and leading zeros are read past");

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
        let qdir = root.join("beta").join(".cs/local/queue");
        std::fs::create_dir_all(qdir.join("subdir")).unwrap();
        std::fs::write(qdir.join("0000000001-a"), "t1\n").unwrap();
        std::fs::write(qdir.join("0000000002-b"), "t2\n").unwrap();
        std::fs::write(qdir.join("0000000003-c"), "t3\n").unwrap();
        let sessions = scan_sessions_in(root);
        let beta = sessions.iter().find(|s| s.name == "beta").unwrap();
        assert_eq!(beta.queue_depth, 3);
        std::fs::remove_dir_all(&tmp).ok();
    }

    // The editor and the delete key address a task by its position in
    // read_queue, then mutate queue_task_files at that index. If read_queue
    // drops an entry the two lists shift apart and the TUI edits a file the
    // user cannot see: a non-UTF-8 .DS_Store sorts before every task name, so
    // "delete task 1" would have removed .DS_Store and left the real task.
    // Every other fixture seeds clean UTF-8 files, which is why the divergence
    // stayed invisible.
    #[test]
    fn read_queue_keeps_one_entry_per_task_file() {
        let tmp = std::env::temp_dir().join(format!("cs-rq-{}", std::process::id()));
        let root = tmp.as_path();
        fs::create_dir_all(root).unwrap();
        let qdir = root.join("queue");
        fs::create_dir_all(&qdir).unwrap();
        // Sorts first, is not valid UTF-8, and is not a task the user sees.
        fs::write(qdir.join(".DS_Store"), [0x00, 0xF0, 0x9F, 0xFF]).unwrap();
        fs::write(qdir.join("0000000001-a"), "real task\n").unwrap();
        fs::write(qdir.join("0000000002-b"), "   \n").unwrap();

        let files = queue_task_files_in(&qdir);
        let rows = read_queue_in(&qdir);
        assert_eq!(
            files.len(),
            rows.len(),
            "display list and mutation list must have equal length"
        );
        assert_eq!(rows.len(), 3, "no entry is dropped");
        assert_eq!(
            files[1].file_name().unwrap(),
            "0000000001-a",
            "the real task keeps index 1 in both lists"
        );
        assert_eq!(rows[1], "real task");
        fs::remove_dir_all(&tmp).ok();
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
    fn load_preview_reads_per_actor_narrative() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-actor-{}", std::process::id()));
        let cs = dir.join(".cs/memory");
        fs::create_dir_all(&cs).unwrap();
        fs::write(
            cs.join("narrative.alex-example-com.md"),
            "# Session narrative\n\n## Found the leak\nSome text\n\n## Shipped the fix\nMore text\n",
        )
        .unwrap();

        let preview = load_preview(&dir);
        assert_eq!(preview.last_discovery.as_deref(), Some("Shipped the fix"));
        assert_eq!(preview.discoveries, vec!["Shipped the fix", "Found the leak"]);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_merges_narratives_from_every_actor() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-actors-{}", std::process::id()));
        let cs = dir.join(".cs/memory");
        fs::create_dir_all(&cs).unwrap();
        // Read in filename order so two co-developers always produce the same
        // preview, whatever order the directory happens to enumerate in.
        fs::write(cs.join("narrative.bea-example-com.md"), "## Bea one\ntext\n").unwrap();
        fs::write(cs.join("narrative.abe-example-com.md"), "## Abe one\ntext\n").unwrap();

        let preview = load_preview(&dir);
        assert_eq!(preview.last_discovery.as_deref(), Some("Bea one"));
        assert_eq!(preview.discoveries, vec!["Bea one", "Abe one"]);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_ignores_non_narrative_memory_files() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-nonnarr-{}", std::process::id()));
        let cs = dir.join(".cs/memory");
        fs::create_dir_all(&cs).unwrap();
        fs::write(cs.join("narrative.abe-example-com.md"), "## Real heading\ntext\n").unwrap();
        // Memory entries and the index live alongside the narratives and carry
        // their own "## " headings; neither is a discovery.
        fs::write(cs.join("MEMORY.md"), "## Not a discovery\n").unwrap();
        fs::write(cs.join("project_something.md"), "## Also not one\n").unwrap();

        let preview = load_preview(&dir);
        assert_eq!(preview.discoveries, vec!["Real heading"]);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn load_preview_handles_missing_files() {
        let dir = std::env::temp_dir().join(format!("cs-test-preview-empty-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();

        let preview = load_preview(&dir);
        assert!(preview.objective.is_none());
        assert!(preview.last_discovery.is_none());
        assert!(preview.discoveries.is_empty());

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

    #[test]
    fn frontmatter_tags_worked_examples() {
        let doc = |line: &str| format!("---\nstatus: active\n{line}\n---\nbody");
        assert!(parse_frontmatter_tags(&doc("tags: []")).is_empty());
        assert_eq!(parse_frontmatter_tags(&doc("tags: [api]")), vec!["api"]);
        assert_eq!(
            parse_frontmatter_tags(&doc("tags: [api, infra-migration]")),
            vec!["api", "infra-migration"]
        );
        assert_eq!(parse_frontmatter_tags(&doc("tags: [ \"api\" ,  infra ]")), vec!["api", "infra"]);
        // Block-style reads as empty (unsupported, mirrors bash)
        assert!(parse_frontmatter_tags("---\ntags:\n  - api\n---\n").is_empty());
        // Missing line / no frontmatter
        assert!(parse_frontmatter_tags(&doc("status: x")).is_empty());
        assert!(parse_frontmatter_tags("no frontmatter here").is_empty());
    }

    #[test]
    fn read_session_populates_tags() {
        let root = std::env::temp_dir().join(format!("cs-test-tags-{}", std::process::id()));
        let _guard = test_root::scoped(root.clone());
        let dir = root.join("tagged");
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::write(
            dir.join(".cs/README.md"),
            "---\nstatus: active\ntags: [api, infra]\n---\n## Objective\nx\n",
        )
        .unwrap();
        let sessions = scan_sessions_in(&root);
        let s = sessions.iter().find(|s| s.name == "tagged").unwrap();
        assert_eq!(s.tags, vec!["api", "infra"]);

        fs::remove_dir_all(&root).unwrap();
    }

    // The searched objective and the previewed one come from the same reader,
    // and the scan has to call it, or a correct read_objective searches nothing.
    #[test]
    fn scan_populates_the_objective_the_preview_shows() {
        let root = std::env::temp_dir().join(format!("cs-test-objective-{}", std::process::id()));
        let _guard = test_root::scoped(root.clone());
        let dir = root.join("brave-jang-0f6265");
        fs::create_dir_all(dir.join(".cs/local")).unwrap();
        fs::write(
            dir.join(".cs/README.md"),
            "---\nstatus: active\n---\n# Session\n\n## Objective\n\nRewrite the electron UI shell\n\n## Outcome\n",
        )
        .unwrap();
        let placeholder = root.join("fresh");
        fs::create_dir_all(placeholder.join(".cs/local")).unwrap();
        fs::write(
            placeholder.join(".cs/README.md"),
            "---\nstatus: active\n---\n## Objective\n\n[Describe what you're trying to accomplish in this session]\n\n## Outcome\n",
        )
        .unwrap();

        let sessions = scan_sessions_in(&root);
        let s = sessions.iter().find(|s| s.name == "brave-jang-0f6265").unwrap();
        assert_eq!(s.objective.as_deref(), Some("Rewrite the electron UI shell"));
        assert_eq!(s.objective, load_preview(&dir).objective);
        let f = sessions.iter().find(|s| s.name == "fresh").unwrap();
        assert!(f.objective.is_none(), "the template placeholder is not an objective");

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn version_newer_compares_numerically_not_lexically() {
        assert!(version_newer("2026.8.0", "2026.7.13"));
        assert!(!version_newer("2026.7.13", "2026.7.13"));
        // Lexically "9" > "13"; numerically 9 < 13 — the compare must be numeric.
        assert!(!version_newer("2026.7.9", "2026.7.13"));
        assert!(version_newer("2027.1.0", "2026.12.9"));
    }

    #[test]
    fn update_notice_reads_cache_and_notes() {
        let dir = std::env::temp_dir().join(format!("cs-test-notice-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("update-check"), "1784287083 2026.8.0\n").unwrap();
        fs::write(
            dir.join("update-notes-2026.8.0"),
            "2026.8.0\tvoice skill and queue fixes\n2026.7.14\tpreview padding\n+\t\u{2026} and 3 earlier versions\n",
        )
        .unwrap();

        let n = update_notice_in(&dir, "2026.7.13").expect("newer version should notify");
        assert_eq!(n.version, "2026.8.0");
        assert_eq!(n.notes.len(), 3);
        assert_eq!(n.notes[0], ("2026.8.0".to_string(), "voice skill and queue fixes".to_string()));
        assert_eq!(n.notes[2].0, "+");

        // Same or older installed version: no notice.
        assert!(update_notice_in(&dir, "2026.8.0").is_none());
        assert!(update_notice_in(&dir, "2026.9.0").is_none());
        // Empty installed version (env missing at launch): no notice.
        assert!(update_notice_in(&dir, "").is_none());

        // Tombstone: notes file empty — notice still fires, notes empty.
        fs::write(dir.join("update-notes-2026.8.0"), "").unwrap();
        let n = update_notice_in(&dir, "2026.7.13").unwrap();
        assert!(n.notes.is_empty());

        // Missing cache entirely: no notice.
        fs::remove_dir_all(&dir).unwrap();
        assert!(update_notice_in(&dir, "2026.7.13").is_none());
    }

    #[test]
    fn read_session_detects_archived_marker() {
        let dir = std::env::temp_dir().join(format!("cs-test-arch-{}", std::process::id()));
        fs::create_dir_all(dir.join(".cs")).unwrap();
        let counts = HashMap::new();

        let s = read_session(&dir, &counts);
        assert!(!s.archived);

        fs::write(dir.join(".cs/archived"), "archived: 2026-07-15 by test\n").unwrap();
        let s = read_session(&dir, &counts);
        assert!(s.archived);

        fs::remove_dir_all(&dir).unwrap();
    }

    // The current process is always alive; a max-u32 PID is never a real one.
    // Covers is_pid_alive without a fixture process.
    #[test]
    fn is_pid_alive_reports_self_alive_and_bogus_dead() {
        assert!(is_pid_alive(std::process::id()));
        // Past i32::MAX is not a process id. Each platform mishandles it its own
        // way — macOS `kill` refuses it, Linux wraps u32::MAX onto -1 and reports
        // success, meaning "every process the caller may signal" — so pin the
        // whole out-of-range band here rather than the one value that happened
        // to fail on the platform this was written on.
        assert!(!is_pid_alive(u32::MAX));
        assert!(!is_pid_alive(i32::MAX as u32 + 1));
        assert!(!is_pid_alive(0));
    }

    // A test build never reads the real ~/.claude: Claude Code's session
    // records are read from a path that cannot exist, as the sessions root is
    // when a test scoped none, so a record, a FIFO or a lock there cannot
    // reach or stall the suite.
    #[test]
    fn a_test_build_reads_no_claude_sessions_dir_that_exists() {
        let dir = claude_sessions_dir();
        assert!(dir.starts_with("/nonexistent"), "a test build reads {}", dir.display());
        assert!(!dir.exists(), "a test build reads {}, which exists", dir.display());
    }

    // A test build counts no Keychain secrets on any platform: off macOS
    // there is no Keychain, and on macOS a test build runs no `security`.
    #[test]
    fn a_test_build_counts_no_keychain_secrets() {
        assert!(count_secrets_from_keychain().is_empty());
    }

    // A test build runs no `security` on any machine, whatever its Keychain
    // holds: the counting test above runs again in a child whose PATH starts
    // with a stand-in `security` that records that it ran and lists one cs
    // entry. A build that reached for the Keychain would count that entry and
    // leave the record, and would read the stand-in, never the real Keychain.
    #[cfg(unix)]
    #[test]
    fn a_test_build_runs_no_security() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = std::env::temp_dir().join(format!("cs-test-no-security-{}", std::process::id()));
        std::fs::remove_dir_all(&tmp).ok();
        std::fs::create_dir_all(&tmp).unwrap();
        let ran = tmp.join("security-ran");
        std::fs::write(
            tmp.join("security"),
            format!("#!/bin/sh\n: > '{}'\nprintf '    \"svce\"<blob>=\"cs:demo:K1\"\\n'\n", ran.display()),
        )
        .unwrap();
        std::fs::set_permissions(tmp.join("security"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:{}", tmp.display(), std::env::var("PATH").unwrap_or_default());

        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["session::tests::a_test_build_counts_no_keychain_secrets", "--exact", "--test-threads=1"])
            .env("PATH", path)
            .output()
            .unwrap();

        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains("test result: ok. 1 passed;"), "the counting test ran once and passed:\n{stdout}");
        assert!(!ran.exists(), "a test build ran security");
        std::fs::remove_dir_all(&tmp).ok();
    }

    // The Keychain panel counts one secret per generic password whose
    // service is cs:<session>:<name>, by session. A label or an account that
    // reads cs:..., and a service that is not cs's, count for nothing.
    #[test]
    fn a_keychain_dump_counts_cs_secrets_per_session() {
        let dump = r#"keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
attributes:
    0x00000007 <blob>="cs:alpha:API_KEY"
    "acct"<blob>="example"
    "labl"<blob>="cs:alpha:API_KEY"
    "svce"<blob>="cs:alpha:API_KEY"
keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
attributes:
    "acct"<blob>="example"
    "svce"<blob>="cs:alpha:TOKEN"
keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
attributes:
    "acct"<blob>="example"
    "svce"<blob>="cs:a.b:K1"
keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
attributes:
    "acct"<blob>="cs:gamma:K1"
    "svce"<blob>="cs:beta:DB_URL"
keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
attributes:
    "acct"<blob>="example"
    "labl"<blob>="cs:delta:K1"
    "svce"<blob>="com.example.app"
keychain: "/Users/example/Library/Keychains/login.keychain-db"
version: 512
class: "inet"
attributes:
    "acct"<blob>="example"
    "srvr"<blob>="example.com"
    "svce"<blob>="cs-other:alpha:K1"
"#;
        let mut counts: Vec<(String, u32)> = secret_counts_in_keychain_dump(dump).into_iter().collect();
        counts.sort();
        assert_eq!(
            counts,
            vec![("a.b".to_string(), 1), ("alpha".to_string(), 2), ("beta".to_string(), 1)]
        );
        assert!(secret_counts_in_keychain_dump("").is_empty(), "an empty dump counts nothing");
    }

    #[test]
    fn a_linked_worktree_is_recognised_as_a_git_checkout() {
        // A linked worktree's .git is a FILE containing a gitdir: pointer, not
        // a directory. Probing only for a directory makes every base@feature
        // session read as having no repo at all.
        let tmp = std::env::temp_dir().join(format!("cs-wt-probe-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join(".git"), "gitdir: /elsewhere/.git/worktrees/probe\n").unwrap();

        assert!(
            is_git_checkout(&tmp),
            "a .git file must count as a checkout, not only a .git directory"
        );

        std::fs::remove_dir_all(&tmp).ok();
    }

    // A test that builds an App without scoping a root deletes, renames and
    // scans through sessions_root(), so an unscoped test build must resolve
    // to a path that cannot exist, never CS_SESSIONS_ROOT or ~/.claude-sessions
    // of whoever runs the suite.
    #[test]
    fn an_unscoped_test_build_never_resolves_the_real_sessions_root() {
        let root = sessions_root();
        assert_eq!(root, PathBuf::from("/nonexistent/cs-tui-test-sessions-root"));
        assert!(root.symlink_metadata().is_err(), "the unscoped test root must not exist");
    }
}
