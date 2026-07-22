# Windows manual smoke test

cs targets Windows two ways. Automated CI covers what it reliably can; the rest
is a short manual checklist, run once per release on a real Windows machine.

## What CI covers

- **Rust TUI (`rust` job, `windows-latest`):** `cargo test` for `cs-tui` on
  Windows — exercises the platform-gated `kill`→`tasklist` and macOS-only
  `security` paths (Task 13). Required, expected green.
- **Git Bash / MSYS2 bash suite (`test-windows-msys` job):** runs
  `tests/run_all.sh` under Git Bash. Session-management and secrets suites run;
  launch/tmux/spawn tests skip via `_skip_on_msys`. **Currently informational
  (`continue-on-error`)** until the full per-test skip-set is calibrated against
  the runner — see "Calibrating the MSYS lane" below.

WSL2 is *not* driven in CI: a `wsl --install` lane is slow and flaky, and
claiming the Linux (`ubuntu-latest`) lane covers WSL would be false (WSL detection
is a distinct code path). WSL is covered by the manual checklist instead.

## Tier 1 — WSL2 (full support)

Inside a WSL2 distro (Ubuntu recommended):

1. `bash install.sh` — installs `cs`, `cs-secrets`, `cs-statusline`, `cs-tui`, hooks.
2. `cs -version` — prints the version; `cs -doctor` — no drift/errors.
3. `cs -secrets backend` — reports **encrypted** (WSL default, no macOS keychain).
4. `printf 'v1' | cs -secrets set SMOKE_KEY && cs -secrets get SMOKE_KEY` → `v1`
   (encrypted round-trip), then `cs -secrets delete SMOKE_KEY`.
5. `cs winsmoke` — a session **launches** Claude Code (WSL is full support), the
   session dir appears under `~/.claude-sessions/`, and the lock is taken.
6. `cs -spawn` / tmux spawner works (tmux present in WSL).

## Tier 2 — Git Bash / MSYS2 (session management only)

In Git Bash (native Windows, `powershell.exe` on PATH):

1. `bash install.sh` — installs the bash tools and fetches **`cs-tui.exe`**.
2. `cs -secrets backend` — reports **wcm** (Windows Credential Manager) when
   `powershell.exe` is available, else **encrypted**.
3. `printf 'v1' | cs -secrets set SMOKE_KEY && cs -secrets get SMOKE_KEY` → `v1`
   (WCM round-trip via the PowerShell helper), then `cs -secrets delete SMOKE_KEY`.
4. `cs winsmoke` — session **prepares** but does **not** launch; prints the
   "launch it from WSL" message (Tier 2 has no POSIX launch).
5. `cs -spawn foo` — **refused** with a WSL-only message (no tmux).
6. `cs-tui.exe` (or `cs-tui` from Git Bash) — the TUI opens; the keychain-secret
   panel is empty (no macOS keychain), PID liveness uses `tasklist`.

## Calibrating the MSYS lane

The `test-windows-msys` lane starts informational because the exact set of tests
that must `_skip_on_msys` (or pin `CS_PLATFORM_OVERRIDE`) can only be found by
running on a real Windows runner. To promote it to required:

1. Read the lane's failures. For each failing test, decide:
   - **Skip** (`_skip_on_msys && return 0`) if it genuinely needs launch/tmux/spawn.
   - **Pin** (`CS_PLATFORM_OVERRIDE=macos|linux …`) if it tests a non-msys path
     that merely relied on the dev box's default platform (see the two controls
     in `tests/test_windows_gating.sh`).
   - **Fix** if it surfaces a real MSYS portability bug (BSD-vs-GNU, path, etc.).
2. Once the lane is green, remove `continue-on-error: true` from `test.yml`.
