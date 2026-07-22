---
parent: d1d07c22-6787-4516-b5c2-03f94321178e
created: 2026-07-22T13:36:43Z
purpose: Apply the last 5 MSYS-lane fixes (all root-caused, patches specified) and drop continue-on-error so test-windows-msys becomes a required gate
status: consumed
consumed_by: 06922490-ebf5-4e61-aba1-23faf26fbfba
---

# MSYS lane calibration — 95 failures down to 5, all root-caused. Finish it.

Successor: you have ZERO memory of the prior conversation. Everything below is
the state. All work is COMMITTED AND PUSHED; `main == origin/main`. All 5
REQUIRED CI lanes are green and have stayed green through every iteration.
The remaining work is small, and every fix is already specified below.

## 1. Primary Request and Intent

Alex asked to **calibrate the `test-windows-msys` CI lane** — it was
`continue-on-error: true` (informational) and failing 19/51 suites. The goal:
work the failures down to zero, then **remove `continue-on-error` from
`.github/workflows/test.yml`** so the lane becomes a required gate.

Working style that held all session: root-cause over symptom patches; Alex
gates pushes (offer, don't auto-do — though he approved the iterate loop, so
subsequent calibration pushes were in scope); cross-lineage review on
security-sensitive slices (he enabled **Fable** for validation mid-session and
it earned its keep twice). Do NOT skip a test to get green unless the behavior
is genuinely impossible on Git Bash.

## 2. Key Technical Concepts

- **Build model:** `bin/cs` is GENERATED from `lib/*.sh` by `./build.sh` — edit
  `lib/`, run `./build.sh`, commit BOTH. `bin/cs-secrets`, `bin/cs-statusline`
  are edited DIRECTLY. Shell floor **bash 3.2 + BSD**. NEVER stage the eternal
  strays `M .gitignore` / `D CLAUDE.md`.
- **Test idiom:** cs/cs-secrets run as SUBPROCESSES. `run_test` disables
  errexit — every assert needs `|| return 1`. Tests are registered explicitly
  via `run_test <name>` at the bottom of each suite; a function that isn't
  registered silently never runs.
- **Reading a still-running lane's log:** `gh run view --log` only works after
  the WHOLE run finishes. Use
  `gh api repos/hex/claude-sessions/actions/jobs/<jobId>/logs`. Grep with
  `rg -a` (logs contain CR bytes).
- **CONFIRMED Windows/Git-Bash facts** (established empirically this session —
  reuse, don't re-derive): native `jq.exe` emits CRLF; `hostname` may emit a
  trailing CR; `USER` is UNSET (Git Bash exports `USERNAME`) so a bare
  `${USER}` under `set -u` ABORTS the whole expansion; MSYS rewrites a
  leading-slash ARGV into a Windows path before a native binary sees it;
  `ln -s` produces a copy; Unix mode bits are not enforced; `git rev-parse
  --git-path` returns a DRIVE-LETTER absolute path (`C:/...`) in a worktree;
  `core.autocrlf` defaults ON; `pwd -P` yields MSYS form (`/c/...`) while
  git.exe prints `C:/...`.
- **zsh gotcha:** the Bash tool runs through zsh, where `status` is a READ-ONLY
  special variable. `status=$(...)` in an inline poll loop dies. Use another name.

## 3. THE REMAINING WORK — 5 failing tests, all root-caused

A Fable agent root-caused all five with macOS repros and scratch-validated
patches. Apply these.

### Shared root cause A — sandbox PATH can't start the interpreter (bare 127)
`_make_fake_security` (tests/test_cs_secrets.sh:74-126) builds a self-contained
bindir via an `ln -sf` whitelist loop, and tests run `PATH="$bindir"
"$CS_SECRETS_BIN" ...`. On Git Bash `ln -s` copies, and a copied bash outside
`/usr/bin` cannot start once `/usr/bin` is off PATH — cs-secrets'
`#!/usr/bin/env bash` never launches. **Signature: rc=127 with ZERO output**
(byte-identical across msys5/6/7).

**FIX:** `PATH="$bindir"` → **`PATH="$bindir:$PATH"`** at the 12 fake-security
call sites: tests/test_cs_secrets.sh **885, 906, 936, 965, 1222, 1235, 1303,
1314, 1322, 1333, 1344, 1674**. The whitelist symlink loop in
`_make_fake_security` then becomes dead weight and can go. Prepending keeps the
fake `security`/`jq`/`sed` shadowing intact. Precedent in-repo: commit 9e0cd84
did exactly this for `_ageless_path`; line 269 already uses `bindir:$PATH`.

Fixes: `test_keychain_export_does_not_require_cs_secrets_dir` (#3) and the
half of #2 below, PLUS two tests that currently fail SILENTLY (they
`return 1` from `out=$(...) || return 1` before printing anything):
`test_keychain_export_file_empty_store_is_clean`,
`test_keychain_list_empty_is_clean`. (So the suite really has 5 reds, not 3.)
NOTE #3 is NOT a skip candidate — a file blocking `mkdir -p` works fine on NTFS.

### #2 `import must succeed when the secret is genuinely absent` — also a REAL cs bug
Second, independent cause, currently masked by (A): `bin/cs-secrets` keychain
functions use a bare `"$USER"` under `set -euo pipefail` at lines **232, 248,
304, 330, 365, 1594**. With USER unset, the `$(security find-generic-password
-a "$USER" ...)` substitution in `keychain_get` (248) aborts before `security`
runs → rc≠44 → the merge-import probe (bin/cs-secrets:1888-1901) reads it as a
read FAILURE → `error "Aborting import ... refusing to overwrite"`.
Commits bf565fa/a728631 fixed this exact class at bin/cs-secrets:424-436 and
1378-1385 but MISSED these six keychain sites.

**FIX:** add a `keychain_user()` helper using the established repo pattern
(see bin/cs-secrets:1378-1385): `u="${USER:-${USERNAME:-}}"; [ -n "$u" ] ||
u=$(id -un 2>/dev/null)`, and replace the six `-a "$USER"`. macOS behavior
unchanged (USER always set → same value).

**macOS RED (verified):**
`env -u USER USERNAME=winuser <run test_import_file_stores_when_secret_genuinely_absent>`
→ "Error: Aborting import ... backend (keychain) failed to read existing secret
'K1' (exit 1); refusing to overwrite".
After the fix, `test_import_file_aborts_on_backend_read_failure_no_overwrite`
must STILL pass — the abort semantics are load-bearing.

### #4 + #5 doctor worktree classification — REAL product bug
`lib/60-doctor.sh:280-282`:
```bash
d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
if ! git -C "$base_dir" worktree list --porcelain 2>/dev/null \
    | grep -qx "worktree $d_real"; then
```
`pwd -P` emits MSYS form; git.exe porcelain prints `C:/...`. The exact-line
`grep -qx` can never match, so EVERY worktree takes the "not a registered
worktree" warn + `continue`, before merged detection. That simultaneously
explains all three observations: "ghost" still flagged (warn text contains the
name → sibling assertion passes), "fully merged" absent (#4), and the OK line
absent (#5). Today any Windows user running `cs -doctor` with worktrees gets
false "pruned or created by hand?" warnings.

**FIX (lib/60-doctor.sh:280 — edit lib, then `./build.sh`):**
```bash
# Compare in git's own path form: Git for Windows porcelain prints C:/-style
# paths that never match MSYS pwd -P output.
d_real=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) \
    || d_real=$(cd "$d" 2>/dev/null && pwd -P || echo "$d")
```
Both strings then come from the same git binary. Verified on macOS that
`rev-parse --show-toplevel` is byte-identical to the porcelain path INCLUDING
symlink resolution (`/var/...` → `/private/var/...`), so macOS stays green; the
ghost dir isn't a repo → rev-parse fails → fallback → still flagged.
**macOS RED recipe:** prepend a `git` shim that rewrites BOTH `worktree list
--porcelain`'s `^worktree /` lines AND `rev-parse --show-toplevel`'s leading
`/` to `C:/` before delegating to real git.

### #1 `should import legacy unsuffixed sync file` — INSUFFICIENT EVIDENCE, do NOT guess
Constraint analysis (solid): `get from_machine_b` passing proves the import loop
completed; `jq -r 'keys[]'` sorts `from_legacy` BEFORE `from_machine_b`, and any
failure on `from_legacy` aborts before machine_b is stored — so `from_legacy`
was never in `merged`, i.e. `$meta/secrets.enc` was missing/rejected in the
candidate/decrypt/validate stage (bin/cs-secrets:1816-1847). Ruled out
empirically: CRLF jq, password/env, the glob, autocrlf, the `_ageless_path` 127.
msys7 is the FIRST run to even reach this assertion. Remaining candidates are
transient (a sharing-violation-style open failure, or a silent seeding failure —
`_seed_enc_sync_file` (tests/test_cs_secrets.sh:61-67) does NOT propagate an
openssl failure and the test never checks the file landed).

**TREATMENT: add a diagnostic seam, not a fix.** (i) assert the seeded files
exist and are non-empty right after seeding; (ii) stop discarding the import
output at tests/test_cs_secrets.sh:855 — capture it and print on failure. The
import's own summary ("Imported N secret(s) from M sync file(s)." / "Skipped X
undecryptable file(s)") discriminates every remaining branch in ONE CI round trip.

### Also worth doing (found by Fable, not blocking)
Every fake-security test that EXPECTS nonzero (readfail/readok/fail modes —
lines 885, 936, 1222, 1303, 1322, 1333, 1344) currently passes on Windows
VACUOUSLY, because a crashed interpreter is also "nonzero + no output". Add
`assert_output_contains` for the specific abort message so a crash can't
impersonate a correct abort.

## 4. Problem Solving — what already shipped (do not redo)

Lane trajectory: **19/51 suites failing → 5 → 2 → 5 individual tests.**
Commits (all pushed, `052c3a2..9e0cd84`):
- `66332b6` statusline jq-CRLF (`fields=${fields//$'\r'/}` in `_parse_stdin`)
- `d07bb8d` launch-gated PIN cluster: `_apply_suite_platform_pin` in
  test_lib.sh + `SUITE_PIN_NONMSYS=1` opt-in on 9 suites. Pin value is
  **linux, not macos** (all 9 pass under `=linux` on mac, proving that path is
  portable; macos would reach for security/osascript on Windows). Conditional
  on REAL platform=msys, so mac/ubuntu lanes keep testing their own platform.
- `4d81a96` doctor jq-CRLF + promoted `_install_crlf_jq` shim to test_lib.sh
- `3bc7520` symlink/mode SKIP cluster + quiet `_is_msys` predicate
- `ca3cd58` tag CRLF fence: `_tags_has_frontmatter` compares in the shell, not
  awk (Windows awk strips `\r`, inverting the check)
- `b130ee8` token-cap assertions made non-vacuous
- `bf565fa` **machine-id**: bare `${USER}` under `set -u` aborted → every
  machine shared `secrets..enc`. USER→USERNAME→`id -un`, + CR strip.
- `73b582d` hooks: build the payload on jq's STDIN (`jq -Rs`), never argv —
  MSYS rewrote `/color red` to `C:/Program Files/Git/color red`
- `34ab911` + `3af847d` **core.autocrlf**: pinned off in repos cs creates
  (session-init + adopt). CRLF `.gitignore` made every pattern match nothing →
  `CLAUDE.local.md` untracked → `cs --merge` refused.
- `8f44e87` **worktree drive-letter git-path** treated as absolute
- `79788b3` resolve worktree exclude path by EXISTENCE (test had reimplemented
  cs's classification; both copies shared the bug so it cancelled out)
- `a728631` password derivation hardening (Fable review): CR strip + `-` not
  `:-` (byte-identical on POSIX incl. the empty-USER edge) + restored exec bits
- `62ab3f4`, `9e0cd84` **CS_AGE_BIN seam**: replaced `_ageless_path`'s PATH
  surgery (which caused the bare-127) with an override seam on
  `age_find_binary`. This is the precedent for fixing shared root cause A.

**Recurring anti-pattern that bit FOUR times — watch for it:** a test that
REIMPLEMENTS the logic it verifies (bug in both copies cancels out, test passes
while product is broken). Instances: `_machine_id`, the worktree exclude path
classification, reading `git config --get` (effective) instead of `--local`
(the layer the code writes), and the vacuous token-cap assertion. Fable notes
`_machine_id` (tests/test_cs_secrets.sh:42-52) has ALREADY drifted from
`get_encryption_password`'s deliberate `-` vs `:-` distinction.

## 5. Pending Tasks

1. Apply the four specified fixes above (shared PATH seam; keychain `$USER`;
   doctor `d_real`; #1 diagnostics). TDD each with the given macOS repro.
2. `./build.sh` after any `lib/` edit; run `bash tests/run_all.sh` (must be
   51/51 on mac) before pushing.
3. Push, read the msys lane, iterate.
4. **When the lane is green: delete `continue-on-error: true` from the
   `test-windows-msys` job in `.github/workflows/test.yml`** (~line 66) and
   update `docs/windows-manual-smoke.md` — its "Calibrating the MSYS lane"
   section says the lane starts informational; record that it is now required.
5. Optional: the vacuous fake-security assertions (§3 "Also worth doing").

## 6. Current Work

Everything committed and pushed; `main == origin/main` at `9e0cd84`. Working
tree clean except the eternal strays. Last CI run 29921329307: all 5 required
lanes green, `test-windows-msys` failure with the 5 (really 7) tests above.
Latest lane log saved at
`<scratchpad>/msys7.log` (earlier: msys.log 19-suite baseline, msys2/3/5/6).
Those scratchpad logs will NOT survive rotation — re-fetch with
`gh api repos/hex/claude-sessions/actions/jobs/88927312535/logs` if needed.

## 7. Next Step

Apply shared root cause A first (`PATH="$bindir:$PATH"` at the 12 sites) — it
alone clears 3-4 reds and unmasks #2's real bug. Then the keychain `$USER`
helper, then the doctor `d_real` fix, then #1's diagnostics. One push should
take the lane to 0-1 failures. Then drop `continue-on-error` and the lane is a
required gate — the objective Alex set.

Do NOT: skip any of the five (none is Windows-impossible); relax the import
probe to treat any nonzero as not-found (reintroduces overwrite-on-read-failure
data loss the sibling abort test guards); weaken the doctor's `grep -qx` to a
substring match or sprinkle `cygpath` (git is the correct canonicalizer); add
`tr -d '\r'` to the import loop for #1 (symptom patch — machine_b's passing
assertion proves keys are clean); extend the sandbox whitelist.
