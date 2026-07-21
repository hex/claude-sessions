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
    # Test/override seam: FIRST branch, validated, cache-bypassing so a test can
    # flip platforms within one process.
    if [ -n "${CS_PLATFORM_OVERRIDE:-}" ]; then
        case "$CS_PLATFORM_OVERRIDE" in
            macos|wsl|msys|linux) printf '%s' "$CS_PLATFORM_OVERRIDE"; return 0 ;;
            *) printf 'cs: invalid CS_PLATFORM_OVERRIDE: %s\n' "$CS_PLATFORM_OVERRIDE" >&2; return 1 ;;
        esac
    fi
    [ -n "${_CS_PLATFORM:-}" ] && { printf '%s' "$_CS_PLATFORM"; return 0; }
    local p
    case "$(uname -s 2>/dev/null)" in
        Darwin) p=macos ;;
        MINGW*|MSYS*|CYGWIN*) p=msys ;;
        Linux)
            # WSL reports Linux; distinguish via the WSL env var or /proc/version.
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

- `CS_PLATFORM_OVERRIDE` is read **inside** the function as its first branch (validated against the four values), so the feature-gate tests can drive any branch; `_CS_PLATFORM` is purely the internal cache. Mirrors the `CS_TMUX_BIN`/`CS_TERM_THEME` test-seam convention.
- Lives in an early lib fragment (near `05-term.sh`); `bin/cs-secrets` and `bin/cs-statusline` get their own small copy (they are standalone, KEEP IN SYNC comment — same pattern as `CS_SIGN_PUBKEY`).

### Phase 1 — Tier 1 (WSL) to green

WSL is Linux; the maintained Linux path already carries most of it. Work is verification + a few guards:

- **Secrets on WSL:** default to the existing **encrypted/age** backend (no macOS keychain). WCM-via-interop (`cmdkey.exe`/`powershell.exe` through WSL interop) is an **opt-in** via `CS_SECRETS_BACKEND=wcm`, not the default (interop can be disabled in `wsl.conf`; the default must not depend on it).
- **Theme detection:** `defaults read -g AppleInterfaceStyle` already fails gracefully; confirm WSL lands on the light/dark default cleanly.
- **Installer/TUI:** `uname -s` = Linux under WSL, so `install.sh` already fetches the working Linux `cs-tui` ELF. No change needed; add a WSL smoke test.
- **Docs:** a "Windows: use WSL" section as the recommended path.

### Phase 2 — Tier 2 (MSYS) core-only

**The create-vs-launch contract (resolved).** `cs <name>` both *prepares* a session
(create/migrate the dir, git init, `.cs/` scaffold — idempotent and safe) and then
*launches* Claude. On MSYS we keep the preparation and skip only the launch: `cs
<name>` runs the full setup and then, in place of `launch_claude_code`, prints
"Session ready at `<path>`. On Windows, launch it from WSL (Git Bash supports session
management only)." Creation is therefore fully supported; only the exec-into-Claude
step is gated. **The guard sits immediately before `launch_claude_code`, after all
create/migrate side effects**, so nothing mutates-then-fails and the prepared session
is reported.

- **Gated on MSYS:**
  - the Claude launch/resume step of `cs <name>` (setup runs, launch is replaced by
    the WSL message, above);
  - `cs -spawn`, live-spawn, tmux tab colors — all via the `_tmux` wrapper
    (`bin/cs:2718`); these have no useful non-tmux effect, so they refuse outright
    **before** doing anything.
- **Supported on MSYS:** session prepare (`cs <name>` up to launch),
  list/rename/archive/delete, notes/narrative, memory, `-search`, `-tag`, `-status`,
  `-doctor`, `-usage`, secrets, statusline. These touch only filesystem + git +
  openssl, all present in Git Bash.
- **Audit the "supported" set for hidden launch/tmux/exec dependencies** before
  implementation — any core command that transitively needs a PTY or the Claude exec
  moves to the gated list.
- **Help/UX:** annotate WSL-only commands in `-h` output when running under msys.

### Phase 3 — Windows Credential Manager backend

New backend `wcm` in `cs-secrets`, selected by `detect_backend()` when `cs_platform`
= `msys` (opt-in on WSL via interop). WCM has no CLI that reveals a stored secret
(`cmdkey` stores but never prints), so store/get/list/delete go through the Win32
Credential API (`CredWrite`/`CredRead`/`CredDelete`) in a **fixed PowerShell helper**
— a real `.ps1` shipped with cs, invoked as `powershell.exe -NoProfile
-ExecutionPolicy Bypass -File <helper> <verb>`. **No `-Command` string interpolation
anywhere.**

Protocol (binary-safe; no secret in argv or logs):
- **Non-secret metadata** (`session`, `name`, `verb`) reaches the helper via validated
  environment variables (`CS_WCM_SESSION`, `CS_WCM_NAME`), never argv; target string
  is `cs:<session>:<name>`.
- **Secret in** (store): value arrives on the helper's **stdin as base64**
  (length-implicit, NUL- and Unicode-safe); the helper base64-decodes to a byte
  buffer and `CredWrite`s it as an opaque blob. cs base64-encodes from its own stdin
  read, so plaintext never touches argv or the command log.
- **Secret out** (get): helper base64-encodes the `CredRead` blob to stdout; cs
  decodes. Output contract is base64-only, so multiline/binary values round-trip.
- **Blob semantics:** store the raw bytes as given — do not assume a PowerShell
  string; `CredentialBlob`/`CredentialBlobSize` set and read explicitly.
- **Memory + persistence:** `CredFree` in a `finally`; `CRED_PERSIST_LOCAL_MACHINE`
  (documented; revisit for roaming). Enforce the WCM blob limit (2560 bytes,
  `CRED_MAX_CREDENTIAL_BLOB_SIZE`) with a clear over-size error.
- **Failure modes:** missing credential → distinct non-zero exit (never an empty
  string that reads as success); `powershell.exe` absent → fall back to encrypted/age
  with a warning.
- **Tests:** unicode, multiline, empty, max-size, over-size (rejected), malformed, and
  missing-credential cases; a real store → get → delete round-trip on the Windows CI
  lane; the helper mocked elsewhere.
- **Fix** `bin/cs-secrets:3` ABOUTME to match reality once implemented.

### Phase 4 — CI

- **MSYS lane:** a `windows-latest` job, default shell `bash` (Git Bash), running the
  full bash suite. A `_skip_on_msys` guard turns tmux/launch tests into assertions of
  the "use WSL" message on that platform.
- **WSL branch coverage — two layers, because the ubuntu job does NOT exercise it.**
  The detector classifies a plain ubuntu runner as `linux`, not `wsl`, so that job
  runs none of the WSL guards, secrets default, or installer path. Do not claim
  otherwise.
  - *Unit:* drive every `wsl` branch on the ubuntu job via `CS_PLATFORM_OVERRIDE=wsl`
    (guards, secrets-default = encrypted/age, help text).
  - *Integration:* add a real WSL lane (`windows-latest` + a `setup-wsl` action or
    `wsl --install`) running a smoke subset inside WSL — installer, a session prepare,
    a secrets round-trip. If that proves too flaky for CI v1, downgrade WSL
    *integration* to a documented manual smoke checklist and say so explicitly.
- **Rust/TUI on Windows:** add `cargo test` on `windows-latest` (today the Rust CI
  runs only on macOS) plus a TUI behavioral smoke. The MSVC binary must not ship until
  remove/live-session paths are verified on Windows (see Phase 5).
- **WCM backend:** real store → get → delete round-trip against live Credential
  Manager on the Windows lane.

### Phase 5 — Distribution

- **The TUI is NOT platform-neutral just because crossterm compiles.** It shells out
  to Unix commands (e.g. `kill` in `tui/src/session.rs`) and touches OS-specific
  process/filesystem paths; an MSVC build that compiles does not prove remove or
  live-session behavior on Windows. **Audit every external command and OS-specific
  path in `tui/src/`**, add a Windows implementation or gate the action, and verify
  behaviorally on the Windows Rust lane (Phase 4) **before** shipping.
- `release.yml`: add `x86_64-pc-windows-msvc` `cs-tui.exe` (built AND tested on
  `windows-latest`), signed with `.minisig` + `.sha256` like the other targets. Do not
  publish the `.exe` until the behavioral smoke passes.
- `install.sh`: add an MSYS branch to the `uname`-based TUI fetch (`install.sh:246`)
  to pull `cs-tui.exe`.
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
