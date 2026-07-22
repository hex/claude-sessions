# Windows manual smoke test

cs targets Windows two ways. Automated CI covers what it reliably can; the rest
is a short manual checklist, run once per release on a real Windows machine.

## What CI covers

- **Rust TUI (`rust` job, `windows-latest`):** `cargo test` for `cs-tui` on
  Windows — exercises the platform-gated `kill`→`tasklist` and macOS-only
  `security` paths (Task 13). Required, expected green.
- **Git Bash / MSYS2 bash suite (`test-windows-msys` job):** runs
  `tests/run_all.sh` under Git Bash. Session-management and secrets suites run;
  launch/tmux/spawn tests skip via `_skip_on_msys`. **Required, expected green**
  — see "Triaging an MSYS-only failure" below.

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

## Triaging an MSYS-only failure

The lane is required and green. When a test fails only here, classify it:

- **Skip** (`_skip_on_msys && return 0`) if it genuinely needs launch/tmux/spawn.
- **Pin** (`SUITE_PIN_NONMSYS=1`, or `CS_PLATFORM_OVERRIDE=linux` per test) if it
  exercises a non-msys path that merely relied on the dev box's default platform
  (see the two controls in `tests/test_windows_gating.sh`). Pin to `linux`, not
  `macos`: the macOS paths reach for `security`/`osascript`.
- **Fix** if it surfaces a real portability bug. Reach for this first — most of
  the calibration failures were product bugs, not test artifacts.

Reading a still-running lane's log: `gh run view --log` only works once the whole
run finishes; use `gh api repos/hex/claude-sessions/actions/jobs/<jobId>/logs`
and grep with `rg -a` (the logs carry CR bytes).

### Confirmed Git Bash behaviours

Established against the real runner; reproduce them locally rather than
re-deriving them, and prefer a shim in `tests/test_lib.sh` so the behaviour is
provable on any platform.

- `jq.exe` writes stdout in text mode and emits **CRLF**. MSYS bash strips the
  trailing `\r\n` of a command substitution along with the newline, so every
  line but the **last** arrives carrying a CR — which is why CR corruption
  presents as "all but one item works". `_install_msys_jq` reproduces this;
  `_install_crlf_jq` reproduces the simpler every-line-CRLF form.
- `USER` is **unset** (Git Bash exports `USERNAME`), so a bare `${USER}` under
  `set -u` aborts the whole expansion before the command runs.
- `hostname` may emit a trailing CR.
- `ln -s` produces a **copy**, and Unix mode bits are not enforced. A sandbox
  PATH rebuilt from `ln -s` copies cannot start `#!/usr/bin/env bash` at all
  (bare exit 127 with no output) — prepend the sandbox dir to `PATH` instead.
- MSYS rewrites a leading-slash argument into a Windows path before a native
  binary sees it; pass such values on stdin.
- `git rev-parse --git-path` returns a drive-letter absolute path in a worktree,
  and git prints `C:/...` where `pwd -P` yields `/c/...`. Compare git output
  against git output, never against `pwd`.
- `core.autocrlf` defaults **on**; cs pins it off in repos it creates.
