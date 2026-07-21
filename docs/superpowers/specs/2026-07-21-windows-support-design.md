# Windows Support (Tier 1 + Tier 2) — Design

**Status:** draft for review
**Date:** 2026-07-21
**Goal:** Run cs on Windows via two supported environments — WSL2 (full experience) and Git Bash/MSYS2 (core session management, no Claude launch) — without a native PowerShell rewrite.

## Scope decisions (locked with Alex)

1. **Tier 2 = WSL-first, MSYS core-only.** Under MSYS/Git Bash, cs supports the commands that don't exec into Claude Code or need tmux. Launching/resuming a Claude session, `cs -spawn`, and terminal tab colors are **WSL-only on Windows**; on MSYS they print a clear "use WSL for this" message. This deliberately avoids Unix↔Windows path translation for the Claude-Code handoff (the riskiest surface), which is out of scope.
2. **Windows Credential Manager backend.** Implement a real WCM secrets backend (the `cs-secrets` ABOUTME already advertises it but it is not implemented). Fix the misleading header regardless.
3. **Windows CI lane now.** Add a `windows-latest` job running the bash suite under Git Bash, with platform guards on tmux/launch tests.

## Non-goals

- Native path translation so `cs <name>` can launch a **native-Windows** Claude Code from MSYS. Deferred; WSL is the supported launch path on Windows.
- A native PowerShell/Go port (~8,500 lines of bash). Not happening.
- Changing the bash 3.2 floor. Git Bash ships bash 5 and WSL ships bash 5; the floor stays 3.2 (macOS CI still enforces it).

## Architecture

### Phase 0 — the platform seam

A single detector, sourced early, is the seam everything keys off. All other phases consume it; nothing else calls `uname` for OS branching.

```sh
# Returns one of: macos | wsl | msys | linux   (cached after first call)
cs_platform() {
    [ -n "${_CS_PLATFORM:-}" ] && { printf '%s' "$_CS_PLATFORM"; return; }
    local p
    case "$(uname -s 2>/dev/null)" in
        Darwin) p=macos ;;
        MINGW*|MSYS*|CYGWIN*) p=msys ;;
        Linux)
            # WSL reports Linux; distinguish via /proc/version or the WSL env var.
            if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                p=wsl
            else
                p=linux
            fi
            ;;
        *) p=linux ;;
    esac
    _CS_PLATFORM="$p"; printf '%s' "$p"
}
```

- Overridable for tests via `CS_PLATFORM_OVERRIDE` (mirrors the existing `CS_TMUX_BIN`/`CS_TERM_THEME` test-seam convention).
- Lives in an early lib fragment (near `05-term.sh`); `bin/cs-secrets` and `bin/cs-statusline` get their own small copy (they are standalone, KEEP IN SYNC comment — same pattern as `CS_SIGN_PUBKEY`).

### Phase 1 — Tier 1 (WSL) to green

WSL is Linux; the maintained Linux path already carries most of it. Work is verification + a few guards:

- **Secrets on WSL:** default to the existing **encrypted/age** backend (no macOS keychain). WCM-via-interop (`cmdkey.exe`/`powershell.exe` through WSL interop) is an **opt-in** via `CS_SECRETS_BACKEND=wcm`, not the default (interop can be disabled in `wsl.conf`; the default must not depend on it).
- **Theme detection:** `defaults read -g AppleInterfaceStyle` already fails gracefully; confirm WSL lands on the light/dark default cleanly.
- **Installer/TUI:** `uname -s` = Linux under WSL, so `install.sh` already fetches the working Linux `cs-tui` ELF. No change needed; add a WSL smoke test.
- **Docs:** a "Windows: use WSL" section as the recommended path.

### Phase 2 — Tier 2 (MSYS) core-only

- **Gate the unsupported features** behind `cs_platform` = `msys`:
  - Launching/resuming a Claude session (`cs <name>` exec into claude) → refuse with: "On Windows, launch sessions from WSL. Git Bash supports session management only."
  - `cs -spawn`, live-spawn, tmux tab colors (all via the `_tmux` wrapper, `bin/cs:2718`) → same class of message.
- **Supported on MSYS:** session create/list/rename/archive/delete, notes/narrative, memory, `-search`, `-tag`, `-status`, `-doctor`, `-usage`, secrets, statusline. These touch only the filesystem + git + openssl, all present in Git Bash.
- **Help/UX:** annotate WSL-only commands in `-h` output when running under msys.

### Phase 3 — Windows Credential Manager backend

- New backend `wcm` in `cs-secrets`, selected by `detect_backend()` when `cs_platform` = `msys` (and available via opt-in on WSL).
- WCM has no CLI that prints a stored secret back (`cmdkey` stores but won't reveal), so retrieval needs the Win32 Credential API. Implement a **small PowerShell helper** invoked from bash:
  - store: `CredWrite` (generic credential, target `cs:<session>:<name>`)
  - get: `CredRead` → print secret to stdout
  - list: enumerate targets matching `cs:<session>:*`
  - delete: `CredDelete`
  - via `powershell.exe -NoProfile -Command` with an `Add-Type` P/Invoke shim, kept in one function.
- Secret passing stays stdin-only (never argv) to preserve the no-secrets-in-logs guarantee; the PowerShell shim reads the value from stdin.
- **Fix** `bin/cs-secrets:3` ABOUTME to match reality once implemented.

### Phase 4 — CI

- Add a `windows-latest` job to the test workflow, default shell `bash` (Git Bash).
- Add a skip guard (`_skip_on_msys` helper) to tmux/launch tests; they assert the "use WSL" message instead of the behavior on that platform.
- Tier 1 (WSL semantics) is already exercised by the existing `ubuntu` job (WSL == Linux for cs's purposes); no separate WSL runner needed initially.
- The WCM backend gets a real round-trip test on the Windows lane (store → get → delete against live Credential Manager).

### Phase 5 — Distribution

- `release.yml`: add `x86_64-pc-windows-msvc` `cs-tui` build (crossterm already supports Windows consoles — no app-logic change), signed with `.minisig` + `.sha256` like the other targets.
- `install.sh`: add an MSYS branch to the `uname`-based TUI fetch (`install.sh:246`) to pull `cs-tui.exe`.
- Docs: install instructions for WSL (recommended) and Git Bash (core-only).

## Testing strategy (TDD, vertical slices)

- `cs_platform()` unit tests with fixtures mocking `uname`/`/proc/version`/`WSL_DISTRO_NAME` via `CS_PLATFORM_OVERRIDE` and shimmed inputs.
- Feature-gate tests: under `CS_PLATFORM_OVERRIDE=msys`, the launch/spawn/tab-color paths assert the refusal message; under `wsl`/`macos`/`linux` they behave normally.
- WCM backend: mock the PowerShell helper for cross-platform CI; real round-trip on the Windows lane.
- All existing suites stay green on macOS bash 3.2 (unchanged floor).

## Rollout

Phase 0 → 1 can ship first (WSL supported, documented) while 2–5 land incrementally. Each phase is an independently testable slice.

## Open sub-decisions for review

- **WSL secrets default:** encrypted/age (proposed) vs. WCM-via-interop by default. Proposal favors encrypted/age so the default never depends on WSL interop being enabled.
- **PowerShell dependency for WCM:** acceptable to require `powershell.exe` on PATH for the WCM backend? (It is present by default on Windows; the fallback is encrypted/age.)
- **Installer PowerShell bootstrap:** ship a `iwr | iex` PowerShell one-liner too, or Git-Bash `curl | bash` only for v1? Proposal: Git Bash only for v1, PowerShell bootstrap as a follow-up.
