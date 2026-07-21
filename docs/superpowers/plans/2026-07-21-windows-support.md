# Windows Support (Tier 1 WSL + Tier 2 MSYS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run cs on Windows via WSL2 (full experience) and Git Bash/MSYS2 (session management only, no Claude launch), plus a native Windows Credential Manager secrets backend, Windows CI, and a Windows `cs-tui` binary.

**Architecture:** A single `cs_platform()` detector (`macos|wsl|msys|linux`) is the seam every platform branch keys off. MSYS gates the Claude-launch and tmux paths (prepare-then-skip), keeps filesystem/git/openssl commands. Secrets gain a `wcm` backend via a fixed PowerShell helper. CI adds a Git Bash lane, a WSL smoke lane, and a Windows Rust lane. The TUI's two Unix-only calls (`kill`, `security`) get gated before shipping a `.exe`.

**Tech Stack:** bash (lib fragments → `bin/cs` via `build.sh`), standalone bash binaries (`bin/cs-secrets`, `bin/cs-statusline`), PowerShell (WCM helper), Rust/crossterm (`cs-tui`), GitHub Actions.

## Global Constraints

- **Shell floor is bash 3.2 + BSD userland** — macOS CI runs the whole suite under stock `/bin/bash` 3.2. No bash 4+ (`local -A`, `printf %(...)T`, `source <()`), no GNU-only `sed`/`awk`/`stat`/`date`. New code branches BSD/GNU the way the tree already does.
- **`bin/cs` is GENERATED** from `lib/*.sh` by `./build.sh` — never hand-edit `bin/cs`; edit `lib/`, run `./build.sh`, commit both together. `bin/cs-secrets` / `bin/cs-statusline` are edited directly.
- **Secrets never touch argv or the command log** — values move on stdin only; the WCM path uses base64 over stdin/stdout, never `-Command` interpolation.
- **Platform values are exactly `macos | wsl | msys | linux`** — validated in the detector; nothing else calls `uname` for OS branching.
- **KEEP IN SYNC copies:** `cs_platform()` is duplicated into `bin/cs-secrets` and `bin/cs-statusline` (they are standalone), each behind a `# KEEP IN SYNC with lib/02-platform.sh` comment, mirroring the existing `CS_SIGN_PUBKEY` pattern. A test asserts the copies match.
- **TDD, vertical slices** — one failing test → minimal impl → green → commit. Never bulk-write tests.

---

## File Structure

- **Create `lib/02-platform.sh`** — the `cs_platform()` seam (sourced right after `00-header.sh`, before everything that branches on OS).
- **Create `tests/test_platform.sh`** — detector + override + KEEP-IN-SYNC tests.
- **Create `tests/test_windows_gating.sh`** — MSYS launch/spawn gating + help annotation.
- **Modify `lib/99-main.sh:334`** — MSYS launch guard (after prepare, before `launch_claude_code`).
- **Modify `lib/52-spawn.sh`** and the tab-color emitters in `lib/05-term.sh` — MSYS refuse.
- **Modify `lib/10-help.sh`** — annotate WSL-only commands under msys.
- **Modify `bin/cs-secrets`** — `wcm` backend (functions + `detect_backend` + dispatch), embedded PowerShell helper, ABOUTME fix; extend `tests/test_cs_secrets.sh`.
- **Modify `tui/src/session.rs`** (`:745` `kill`, `:818` `security`) — gate/impl for Windows; Rust unit tests alongside.
- **Modify `.github/workflows/`** — Git Bash lane, WSL smoke lane, Windows Rust lane.
- **Modify `.github/workflows/release.yml`** — `x86_64-pc-windows-msvc` `cs-tui.exe`.
- **Modify `install.sh:246`** — MSYS TUI-fetch branch.
- **Modify `README.md`, `docs/`** — WSL-recommended + Git-Bash-core-only.

---

## Phase 0 — The platform seam

### Task 1: `cs_platform()` detector

**Files:**
- Create: `lib/02-platform.sh`
- Test: `tests/test_platform.sh`
- After edit: `./build.sh` regenerates `bin/cs`

**Interfaces:**
- Produces: `cs_platform()` → prints one of `macos|wsl|msys|linux`; honors `CS_PLATFORM_OVERRIDE` (validated); caches in `_CS_PLATFORM`. Exit 1 on invalid override.

- [ ] **Step 1: Write the failing test** in `tests/test_platform.sh` (follow the suite's `run_test`/`assert_eq` conventions; every assert ends `|| return 1`):

```bash
test_platform_override_is_honored_and_validated() {
    ( export CS_PLATFORM_OVERRIDE=msys; [ "$(cs_platform)" = "msys" ] ) || return 1
    ( export CS_PLATFORM_OVERRIDE=wsl;  [ "$(cs_platform)" = "wsl" ]  ) || return 1
    # invalid override -> nonzero, error to stderr, nothing on stdout
    local out; out=$( CS_PLATFORM_OVERRIDE=bogus cs_platform 2>/dev/null ); local rc=$?
    [ "$rc" -ne 0 ] || return 1
    [ -z "$out" ] || return 1
}
test_platform_detects_macos_and_msys_from_uname() {
    ( _CS_PLATFORM=""; uname() { echo Darwin; }; [ "$(cs_platform)" = "macos" ] ) || return 1
    ( _CS_PLATFORM=""; uname() { echo MINGW64_NT-10.0; }; [ "$(cs_platform)" = "msys" ] ) || return 1
}
```

- [ ] **Step 2: Run it, confirm it fails** — `bash tests/test_platform.sh` → FAIL (`cs_platform: command not found`).

- [ ] **Step 3: Implement `lib/02-platform.sh`:**

```bash
# ABOUTME: cs_platform() — the single OS/environment seam (macos|wsl|msys|linux).
# ABOUTME: Everything that branches on platform keys off this; nothing else calls uname.

# Returns one of: macos | wsl | msys | linux   (cached after first detect)
cs_platform() {
    # Test/override seam: FIRST branch, validated, cache-bypassing.
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
            if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                p=wsl
            else
                p=linux
            fi ;;
        *) p=linux ;;
    esac
    _CS_PLATFORM="$p"; printf '%s' "$p"
}
```

- [ ] **Step 4: Run, confirm green** — `bash tests/test_platform.sh` → PASS.

- [ ] **Step 5: Wire into build + commit** — add `tests/test_platform.sh` to `tests/run_all.sh` if it does not auto-glob; run `./build.sh`; then:

```bash
git add lib/02-platform.sh bin/cs tests/test_platform.sh tests/run_all.sh
git commit -m "feat(platform): cs_platform() detector seam (macos|wsl|msys|linux)"
```

### Task 2: KEEP-IN-SYNC copies in the standalone binaries

**Files:**
- Modify: `bin/cs-secrets`, `bin/cs-statusline` (add the same `cs_platform()` behind `# KEEP IN SYNC with lib/02-platform.sh`)
- Test: `tests/test_platform.sh` (add a sync assertion)

**Interfaces:**
- Consumes: `cs_platform()` from Task 1 (identical body).

- [ ] **Step 1: Write the failing sync test** — extract each copy's function body and compare to `lib/02-platform.sh`'s:

```bash
test_cs_platform_copies_match_lib() {
    local ref; ref=$(sed -n '/^cs_platform() {/,/^}/p' lib/02-platform.sh)
    for f in bin/cs-secrets bin/cs-statusline; do
        local copy; copy=$(sed -n '/^cs_platform() {/,/^}/p' "$f")
        [ "$copy" = "$ref" ] || { echo "drift in $f"; return 1; }
    done
}
```

- [ ] **Step 2: Run, confirm fail** (copies absent) → FAIL.
- [ ] **Step 3: Paste the identical `cs_platform()` body** into both binaries near their other shared constants, each with the KEEP IN SYNC comment.
- [ ] **Step 4: Run, confirm green.**
- [ ] **Step 5: Commit** — `git add bin/cs-secrets bin/cs-statusline tests/test_platform.sh && git commit -m "feat(platform): sync cs_platform() into standalone binaries"`

---

## Phase 1 — Tier 1 (WSL) to green

### Task 3: WSL secrets default to encrypted (WCM opt-in only)

**Files:**
- Modify: `bin/cs-secrets` `detect_backend()` (`:148`)
- Test: `tests/test_cs_secrets.sh`

**Interfaces:**
- Consumes: `cs_platform()`.
- Produces: on `wsl`, `detect_backend` returns `encrypted` unless `CS_SECRETS_BACKEND` is set; on `msys` it also returns `encrypted` **until Task 9 flips it to `wcm`** alongside the handlers (selecting `wcm` before its dispatch arms exist would make MSYS secrets a silent no-op); `macos` unchanged (`keychain`).

- [ ] **Step 1: Failing test:**

```bash
test_backend_wsl_defaults_encrypted_not_keychain() {
    ( export CS_PLATFORM_OVERRIDE=wsl; unset CS_SECRETS_BACKEND
      [ "$(detect_backend)" = "encrypted" ] ) || return 1
}
```

- [ ] **Step 2: Run, confirm fail** (today `detect_backend` tries keychain first regardless).
- [ ] **Step 3: Implement** — make `detect_backend` consult `cs_platform` before the keychain probe:

```bash
detect_backend() {
    if [[ -n "${CS_SECRETS_BACKEND:-}" ]]; then echo "$CS_SECRETS_BACKEND"; return; fi
    case "$(cs_platform)" in
        macos) command -v security >/dev/null 2>&1 && { echo keychain; return; } ;;
        # msys -> wcm is deferred to Task 9 (selected with the WCM handlers +
        # unknown-backend guards); until then MSYS falls through to encrypted
        # below, so a real Git Bash box is never a silent no-op.
        # wsl/linux: no OS keystore by default -> encrypted below
    esac
    command -v openssl >/dev/null 2>&1 && { echo encrypted; return; }
    error "No supported secret storage backend found. Install OpenSSL for encrypted file support."
}
```

- [ ] **Step 4: Run, confirm green** (also re-run the existing macOS keychain test to confirm no regression).
- [ ] **Step 5: Commit.**

### Task 4: WSL guard unit coverage + graceful degradation

**Files:**
- Test: `tests/test_platform.sh` (add), plus targeted fixes if any macOS-only call is unguarded on `wsl`.

- [ ] **Step 1: Failing test** — theme detection returns a valid value under `wsl` (no `defaults` binary):

```bash
test_theme_detection_degrades_off_macos() {
    ( export CS_PLATFORM_OVERRIDE=wsl
      defaults() { return 127; }   # simulate absent
      local t; t=$(sl_detect_theme 2>/dev/null || echo light)
      case "$t" in light|dark) : ;; *) return 1 ;; esac )
}
```

- [ ] **Step 2: Run** — passes if already guarded (the `defaults read` call at `cs-statusline:25` is already conditional); if it errors under `set -u`/`set -e`, that is the bug to fix. Confirm behavior.
- [ ] **Step 3: Fix only if red** — wrap the offending call in `command -v defaults` / `2>/dev/null || fallback`.
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit.**

---

## Phase 2 — Tier 2 (MSYS) gating

### Task 5: MSYS launch guard — prepare, then skip the Claude exec

**Files:**
- Modify: `lib/99-main.sh:334` (immediately before `launch_claude_code`)
- Test: `tests/test_windows_gating.sh`
- After edit: `./build.sh`

**Interfaces:**
- Consumes: `cs_platform()`; the already-computed `$session_name`, `$session_dir`, `$is_new`.
- Produces: on `msys`, prints "Session ready … launch from WSL" and returns 0 **without** calling `launch_claude_code`; all create/migrate side effects at `:311-330` have already run.

- [ ] **Step 1: Failing test** — drive the dispatch with `CS_PLATFORM_OVERRIDE=msys` against a temp sessions root and assert (a) the session dir exists, (b) `launch_claude_code` was NOT invoked, (c) the WSL message printed. Stub `launch_claude_code` to write a sentinel:

```bash
test_msys_prepares_but_does_not_launch() {
    ( export CS_PLATFORM_OVERRIDE=msys
      export CS_SESSIONS_ROOT="$TEST_ROOT/s"
      launch_claude_code() { echo LAUNCHED > "$TEST_ROOT/launched"; }
      run_cs_dispatch winsess >"$TEST_ROOT/out" 2>&1
      [ -d "$CS_SESSIONS_ROOT/winsess" ] || return 1          # prepared
      [ ! -f "$TEST_ROOT/launched" ] || return 1               # not launched
      grep -q "launch it from WSL" "$TEST_ROOT/out" || return 1 )
}
```

- [ ] **Step 2: Run, confirm fail** (today it launches).
- [ ] **Step 3: Implement the guard** at `lib/99-main.sh:334`:

```bash
    if [ "$(cs_platform)" = "msys" ]; then
        info "Session ready at $session_dir."
        info "On Windows, launch it from WSL (Git Bash supports session management only)."
        return 0
    fi
    launch_claude_code "$session_name" "$session_dir" "$is_new" "$force_flag"
```

- [ ] **Step 4: Green** (also confirm a non-msys override still reaches the stub).
- [ ] **Step 5: `./build.sh`; commit** `lib/99-main.sh bin/cs tests/test_windows_gating.sh`.

### Task 6: MSYS refuses tmux features before side effects

**Files:**
- Modify: `lib/52-spawn.sh` (spawn entry), `lib/05-term.sh` (`set_tab_title` color path)
- Test: `tests/test_windows_gating.sh`
- After edit: `./build.sh`

- [ ] **Step 1: Failing test** — `cs -spawn` under msys exits nonzero with the WSL message and does not call `_tmux`:

```bash
test_msys_refuses_spawn() {
    ( export CS_PLATFORM_OVERRIDE=msys
      _tmux() { echo TMUX_CALLED > "$TEST_ROOT/tmux"; }
      run_cs -spawn foo >"$TEST_ROOT/out" 2>&1; local rc=$?
      [ "$rc" -ne 0 ] || return 1
      [ ! -f "$TEST_ROOT/tmux" ] || return 1
      grep -q "WSL" "$TEST_ROOT/out" || return 1 )
}
```

- [ ] **Step 2: Fail.**
- [ ] **Step 3: Implement** — at the top of the spawn command handler:

```bash
    if [ "$(cs_platform)" = "msys" ]; then
        error "cs -spawn needs tmux; on Windows run it from WSL."
    fi
```

  and make `set_tab_title`'s color emission a no-op under msys (guard the iTerm2/tmux escape block: `[ "$(cs_platform)" = "msys" ] && return 0` before the color escapes, leaving the plain OSC-0 title alone).
- [ ] **Step 4: Green.**
- [ ] **Step 5: `./build.sh`; commit.**

### Task 7: Help annotates WSL-only commands under msys

**Files:**
- Modify: `lib/10-help.sh`
- Test: `tests/test_windows_gating.sh`
- After edit: `./build.sh`

- [ ] **Step 1: Failing test** — under msys, `cs -h` marks `-spawn` and session-launch as WSL-only:

```bash
test_help_marks_wsl_only_under_msys() {
    ( export CS_PLATFORM_OVERRIDE=msys
      run_cs -h 2>&1 | grep -q "WSL only" ) || return 1
}
```

- [ ] **Step 2: Fail.**
- [ ] **Step 3: Implement** — append `" (WSL only on Windows)"` to the `-spawn` line and the session-launch summary when `cs_platform` = msys (compute a suffix var once, interpolate).
- [ ] **Step 4: Green.**
- [ ] **Step 5: `./build.sh`; commit.**

---

## Phase 3 — Windows Credential Manager backend

### Task 8: The PowerShell WCM helper (binary-safe, no interpolation)

**Files:**
- Modify: `bin/cs-secrets` (embed the helper as a heredoc written to a temp `.ps1`, invoked with `-File`)
- Test: `tests/test_cs_secrets.sh` (helper-contract test, mocked on non-Windows; real round-trip runs only on the Windows CI lane)

**Interfaces:**
- Produces: `_wcm_run <verb>` where verb ∈ `store|get|delete|list`; reads `CS_WCM_SESSION`/`CS_WCM_NAME` from env; `store` reads base64 secret on stdin; `get` writes base64 on stdout; nonzero + empty stdout when a credential is missing.

- [ ] **Step 1: Failing contract test** (mock `powershell.exe` with a fake that echoes a known base64 for `get`, records env for `store`) asserting `_wcm_run` passes metadata via env only, never argv:

```bash
test_wcm_never_puts_secret_or_meta_in_argv() {
    ( export CS_PLATFORM_OVERRIDE=msys
      powershell.exe() { echo "ARGS:$*" >>"$TEST_ROOT/psargs"; cat; }  # echo stdin back
      printf 'c2VjcmV0' | CS_WCM_SESSION=s CS_WCM_NAME=n _wcm_run store
      # secret bytes and metadata must not appear in argv
      ! grep -Eq 'secret|s:n|CS_WCM' "$TEST_ROOT/psargs" || return 1
      grep -q -- '-File' "$TEST_ROOT/psargs" || return 1 )
}
```

- [ ] **Step 2: Fail.**
- [ ] **Step 3: Implement** — a `_wcm_run` bash function that writes the embedded helper to `"$(mktemp).ps1"` (once per process, cached), then:

```bash
_wcm_run() {  # verb on $1; store reads base64 stdin; get writes base64 stdout
    local verb="$1"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(_wcm_helper_path)" "$verb"
}
```

  The `.ps1` (fixed program; reads `$env:CS_WCM_SESSION`/`$env:CS_WCM_NAME`; target `cs:<session>:<name>`) uses `Add-Type` P/Invoke for `CredWrite`/`CredRead`/`CredDelete`:
  - store: read all stdin, `[Convert]::FromBase64String`, `CredWrite` with `CredentialBlob`/`CredentialBlobSize`, `CRED_PERSIST_LOCAL_MACHINE`; reject blobs > 2560 bytes (`CRED_MAX_CREDENTIAL_BLOB_SIZE`) with exit 2.
  - get: `CredRead`; on `ERROR_NOT_FOUND` exit 3 with empty stdout; else copy `CredentialBlobSize` bytes, `[Convert]::ToBase64String`, print; `CredFree` in `finally`.
  - delete/list: `CredDelete` / `CredEnumerate` on filter `cs:<session>:*`.

- [ ] **Step 4: Green** (mocked). Mark the real round-trip test `_skip_unless_windows`.
- [ ] **Step 5: Commit** `bin/cs-secrets tests/test_cs_secrets.sh`.

### Task 9: `wcm` backend functions, dispatch, ABOUTME fix

**Files:**
- Modify: `bin/cs-secrets` (`wcm_store/get/list/delete`, `detect_backend` msys branch already added in Task 3, dispatch cases at `:742+`, ABOUTME `:3`)
- Test: `tests/test_cs_secrets.sh`

**Interfaces:**
- Consumes: `_wcm_run` (Task 8).
- Produces: `wcm_store`/`wcm_get`/`wcm_list`/`wcm_delete` matching the `keychain_*` signatures so the dispatch `case "$BACKEND"` blocks add a one-line `wcm)` arm each.

- [ ] **Step 1: Failing test** — end-to-end through the dispatch with a mocked `_wcm_run`, asserting stdin-base64 in / base64-decoded out, and a missing key returns nonzero:

```bash
test_wcm_roundtrip_via_dispatch_mocked() {
    ( export CS_PLATFORM_OVERRIDE=msys CS_SECRETS_BACKEND=wcm
      _wcm_run() { case "$1" in
          store) cat >"$TEST_ROOT/store.b64" ;;
          get)   [ -f "$TEST_ROOT/store.b64" ] && cat "$TEST_ROOT/store.b64" || return 3 ;;
      esac }
      printf 'hunter2' | backend_store sess API_KEY
      [ "$(backend_get sess API_KEY)" = "hunter2" ] || return 1
      backend_get sess MISSING >/dev/null 2>&1 && return 1 || true )
}
```

- [ ] **Step 2: Fail.**
- [ ] **Step 3: Implement** `wcm_*` (base64-encode stdin before `_wcm_run store`; base64-decode after `_wcm_run get`), add `wcm)` arms to every `backend_*` dispatch `case`, **flip `detect_backend`'s msys arm to select `wcm`** when `powershell.exe` is present (deferred from Task 3), **add an explicit `*)` unknown-backend error arm to every `backend_*` dispatcher** so an unimplemented/unknown backend fails loudly instead of silently no-op'ing, and **fix `bin/cs-secrets:3`** ABOUTME to: `# ABOUTME: Supports macOS Keychain, Windows Credential Manager (PowerShell), and encrypted-file/age fallback`.
- [ ] **Step 4: Green** + edge-case tests (unicode, multiline, empty, over-size rejected) with the mock.
- [ ] **Step 5: Commit.**

---

## Phase 4 — CI

### Task 10: Git Bash (MSYS) lane + `_skip_on_msys`

**Files:**
- Modify: `.github/workflows/test.yml` (add `windows-latest` job, shell `bash`), `tests/run_all.sh` or a shared helper (add `_skip_on_msys`)
- Test: the suite itself, guarded.

- [ ] **Step 1:** Add `_skip_on_msys` to the test harness (returns early with a SKIP line when `cs_platform` = msys). Apply it to tmux/launch tests so they instead assert the WSL message.
- [ ] **Step 2:** Add the job:

```yaml
  test-windows-msys:
    runs-on: windows-latest
    defaults: { run: { shell: bash } }
    steps:
      - uses: actions/checkout@v4
      - run: git config --global user.email ci@example.com && git config --global user.name CI
      - run: bash tests/run_all.sh
```

- [ ] **Step 3:** Push, confirm the lane is green (tmux/launch tests SKIP, core green). Iterate on any real MSYS breakage surfaced.
- [ ] **Step 4: Commit.**

### Task 11: WSL integration smoke lane

**Files:** Modify `.github/workflows/test.yml`.

- [ ] **Step 1:** Add a `windows-latest` job using a `setup-wsl` action (or `wsl --install`) that runs, inside WSL: `install.sh` (or a local install), one `cs <name>` prepare, and a `cs -secrets` encrypted round-trip.
- [ ] **Step 2:** If the WSL lane proves flaky, downgrade to a committed `docs/windows-manual-smoke.md` checklist and record that WSL integration is manual for v1 (do not claim ubuntu covers it).
- [ ] **Step 3: Commit.**

### Task 12: Windows Rust lane

**Files:** Modify the Rust CI workflow.

- [ ] **Step 1:** Add `cargo test --manifest-path tui/Cargo.toml` on `windows-latest` (today Rust CI is macOS-only). Expect failures from the Unix-only calls — those drive Task 13.
- [ ] **Step 2: Commit** (lane may be red until Task 13 lands; keep it required only after).

---

## Phase 5 — Distribution

### Task 13: TUI Windows audit — gate `kill` and `security`

**Files:**
- Modify: `tui/src/session.rs` (`:745` `kill`, `:818` `security`)
- Test: Rust unit tests in `tui/src/session.rs`

**Interfaces:**
- Produces: process-existence and secrets-presence checks that compile and behave on Windows (crossterm handles the terminal; these two shell-outs do not).

- [ ] **Step 1: Failing/red on Windows** — the `windows-latest` cargo lane (Task 12) fails or misbehaves on the `kill`/`security` paths.
- [ ] **Step 2: Implement** with `#[cfg(...)]` or a small runtime branch:
  - `kill -0 <pid>` liveness (`:745`) → on Windows use `tasklist`/`OpenProcess` (or gate the live-session heartbeat feature off with a clear "unsupported on native Windows" state).
  - `security` keychain probe (`:818`) → on Windows return "no keychain" (secrets in the TUI degrade to the cs-secrets backend, or the feature hides).
- [ ] **Step 3:** Add `#[cfg(windows)]`/`#[cfg(unix)]` unit tests covering both branches; `cargo test` green on macOS AND the Windows lane.
- [ ] **Step 4: Commit.**

### Task 14: Windows `cs-tui.exe` in release

**Files:** Modify `.github/workflows/release.yml`.

- [ ] **Step 1:** Add an `x86_64-pc-windows-msvc` build+`cargo test` step producing `cs-tui.exe`, signed with `.minisig` + `.sha256` like the other targets. **Gate publish on the Windows behavioral smoke (Task 13) passing.**
- [ ] **Step 2:** Dry-run the workflow on a pre-release tag; confirm `cs-tui.exe` + `.minisig` + `.sha256` attach.
- [ ] **Step 3: Commit.**

### Task 15: `install.sh` MSYS branch

**Files:** Modify `install.sh:246`.

- [ ] **Step 1:** In the `uname`-based TUI fetch, add a `MINGW*|MSYS*` case that downloads `cs-tui.exe` to `${HOME}/.local/bin`.
- [ ] **Step 2:** Verify checksum/signature the same way as the other platforms.
- [ ] **Step 3: Commit.**

### Task 16: Docs

**Files:** Modify `README.md`, `docs/` (secrets/session-layout/statusline as touched).

- [ ] **Step 1:** Add a "Windows" section: WSL2 recommended (full), Git Bash core-only (no session launch / spawn), WCM secrets backend, `cs-tui.exe`. Update `docs/secrets.md` backend table with `wcm`.
- [ ] **Step 2:** Grep-verify every command/flag named in the new docs exists (`/release` step-3 discipline).
- [ ] **Step 3: Commit.**

---

## Self-Review

**Spec coverage:** Phase 0 → Tasks 1-2 (detector seam + sync). Tier 1 WSL → Tasks 3-4 (secrets default, degradation). Tier 2 MSYS → Tasks 5-7 (launch guard, tmux refuse, help). WCM → Tasks 8-9 (helper + backend + ABOUTME). CI → Tasks 10-12 (MSYS, WSL, Rust). Distribution → Tasks 13-16 (TUI audit, release, installer, docs). All five codex findings map to tasks: create-vs-launch → Task 5 (guard after prepare); override wiring → Task 1; WSL-not-covered → Tasks 4+11; TUI not neutral → Tasks 12-13; WCM protocol → Task 8. No spec section is unassigned.

**Placeholder scan:** every code step carries real code or exact YAML/commands; investigation-only steps (Task 4, Task 12) name the exact call sites and the concrete fix.

**Type consistency:** `cs_platform()` signature identical across Tasks 1-2 and every consumer; `wcm_*` mirror `keychain_*` so the dispatch arms are one-liners; `_wcm_run` verbs (`store|get|delete|list`) consistent between Tasks 8-9.

---

## Execution Handoff

Recommended: **subagent-driven-development** — fresh implementer per task, task review (spec + quality) between tasks, broad review at the end. Phases 0→1 are shippable before 2-5 land. Alternative: inline **executing-plans** with checkpoints.
