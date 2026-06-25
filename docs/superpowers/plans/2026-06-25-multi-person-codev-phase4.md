# Multi-Person Co-Development — Phase 4 Implementation Plan

> Optional polish. REQUIRED SUB-SKILL: superpowers:executing-plans.

**Goal:** Surface per-session contributors in the TUI preview pane, reusing `cs -who`'s data (`git log -- .cs/memory`). Minimal and disposable: one new `SessionPreview` field + one render section. No new Mode, keybind, panel, or theme change.

**Architecture:** `load_preview` already reads `.cs/` metadata and the TUI already shells to `git`. Add `load_contributors(session_dir)` running `git log --format=%an -- .cs/memory`, counted by author, formatted `Name (n)` descending. Render it as a "Contributors" section in the existing preview pane, mirroring the "Memory" section.

**Tech Stack:** Rust/ratatui, `std::process::Command` git, `cargo test`.

## Global Constraints
- Reuse existing patterns (`parse_git_remote` for the git-shell shape, the `memory_entries` block for render). No new dependencies.
- Activity/attribution only — label "Contributors", never presence.
- Easy to delete (tef): isolated to `load_contributors` + one render block + one struct field.

## Task 1: Contributors in the TUI preview

**Files:**
- Modify: `tui/src/session.rs` (`SessionPreview` field + `load_contributors` + populate in `load_preview`)
- Modify: `tui/src/ui.rs` (render section + empty-state condition)
- Test: `tui/src/session.rs` (`#[cfg(test)]`)

**Interfaces:**
- Produces: `SessionPreview.contributors: Vec<String>` — `"<author> (<count>)"`, count-desc then name-asc; empty when no `.git` or no `.cs/memory` history.

- [ ] **Step 1: Failing test** (add in the `session.rs` tests module)

```rust
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
```

- [ ] **Step 2: Run — fails to compile (`contributors` field absent)**

Run: `cd tui && cargo test load_preview_reads_contributors`
Expected: compile error (no field `contributors`).

- [ ] **Step 3: Add the field** to `SessionPreview` (after `memory_entries`):

```rust
    /// "<author> (<n>)" lines from git history over .cs/memory, most active first.
    pub contributors: Vec<String>,
```

- [ ] **Step 4: Add `load_contributors`** (near `parse_git_remote` in `session.rs`):

```rust
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
```

- [ ] **Step 5: Populate in `load_preview`** — add before the struct literal and include the field:

```rust
    let contributors = load_contributors(session_dir);
```
and add `contributors,` to the returned `SessionPreview { ... }`.

- [ ] **Step 6: Run — passes**

Run: `cd tui && cargo test load_preview_reads_contributors`
Expected: PASS.

- [ ] **Step 7: Render** in `ui.rs`, after the `memory_entries` block (ui.rs:925), before the Artifacts block:

```rust
        if !preview.contributors.is_empty() {
            lines.push(Line::from(Span::styled(
                "Contributors",
                Style::default().fg(p.gold).add_modifier(Modifier::BOLD),
            )));
            for c in &preview.contributors {
                let truncated = truncate_str(c, (area.width as usize).saturating_sub(6));
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default()),
                    Span::styled(truncated, Style::default().fg(p.comment)),
                ]));
            }
            lines.push(Line::from(""));
        }
```

Extend the empty-state condition (ui.rs:947) to include `&& preview.contributors.is_empty()`.

- [ ] **Step 8: Build + full TUI tests**

Run: `cd tui && cargo build --release && cargo test`
Expected: clean build, all tests pass. Also fix any other `SessionPreview { ... }` constructors (e.g. test fixtures) that now need the `contributors` field — search `SessionPreview {`.

- [ ] **Step 9: Commit**

```bash
git add tui/src/session.rs tui/src/ui.rs
git commit -m "feat: show per-session contributors in the TUI preview"
```

## Self-Review
- [ ] `contributors` empty when no git / no `.cs/memory` history (graceful).
- [ ] Sort deterministic (count desc, name asc).
- [ ] No new Mode/keybind/panel/theme; render mirrors the Memory section.
- [ ] All `SessionPreview { ... }` literals updated; `cargo test` green.
