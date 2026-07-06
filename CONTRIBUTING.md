# Contributing to cs

Practical guide for adding hooks, commands, and other contributions to cs.

## Development Setup

```bash
git clone https://github.com/hex/claude-sessions.git
cd claude-sessions
```

The `cs` command is **assembled** from ordered fragments in `lib/*.sh` into the
single `bin/cs` that ships. **Edit the `lib/` fragments, never `bin/cs` directly**,
then rebuild and commit the regenerated `bin/cs`:

```bash
./build.sh   # concatenates lib/*.sh (in numeric-prefix order) into bin/cs
```

CI rebuilds and fails if the committed `bin/cs` is out of sync with `lib/`. Each
fragment has a numeric prefix (`00`, `05`, …, `99`) that fixes its position; the
`bin/cs` blob stays byte-identical whether you edit a fragment or the assembled
file, so a build is transparent. Hooks live in `hooks/`, commands in `commands/`,
and tests in `tests/`.

## Running Tests

Tests use a shared library (`tests/test_lib.sh`) that provides assertions, temporary directories, and test isolation.

```bash
# Run all tests (aggregates per-suite results and exits non-zero on any failure)
bash tests/run_all.sh

# Run a single test file
bash tests/test_hooks.sh

# Run a specific test function
bash tests/test_hooks.sh test_session_start_creates_log

# Run the Rust TUI tests
cargo test --manifest-path tui/Cargo.toml
```

There are 530+ tests across 34 bash suites plus the Rust TUI tests. All must
pass before submitting changes; CI (`.github/workflows/test.yml`) runs them on
every push and pull request. Do not use a bare `for f in tests/*; do bash "$f";
done` loop — its exit status reflects only the last suite, so failures are
masked; `run_all.sh` reports every failing suite.

## Adding a Hook

1. **Create the hook script** in `hooks/your-hook.sh`. Copy an existing hook (e.g., `hooks/bash-logger.sh`) as a starting template.

2. **Register in `install.sh`**:
   - Add the filename to the `CS_HOOKS` array (deploy, flat-layout cleanup, and registration stripping all derive from it)
   - Add a path variable: `YOUR_HOOK_PATH="$HOOKS_DIR/your-hook.sh"`
   - Add a tilde variant: `YOUR_HOOK_TILDE="$HOOKS_TILDE_DIR/your-hook.sh"`
   - Add a `_merge_cs_hook` call to register the hook in `settings.json` under the appropriate event (`SessionStart`, `PreToolUse`, `PostToolUse`, etc.)

3. **Add to `CS_HOOKS` in `lib/00-header.sh`** (assembled into `bin/cs`) — uninstall and doctor derive from it. `tests/test_install.sh` fails if the two arrays disagree with each other or with the actual contents of `hooks/`.

4. **Document in `docs/hooks.md`** — add a section following the existing format: hook name, event type, description, and behavior.

5. **Write tests** in `tests/` — create a test file or add to an existing one. Use `test_lib.sh` for setup/teardown.

## Adding a Command

1. **Create `commands/name.md`** with YAML frontmatter specifying `allowed_tools`.

2. **Register in `install.sh`**:
   - Add a URL variable: `CMD_NAME_URL="${REPO_URL}/commands/name.md"`
   - Add the download step (uses `curl` with `wget` fallback)
   - Add the `cp` line for the command file

3. **Add to `run_uninstall()`** in `lib/85-adopt-uninstall.sh` (assembled into `bin/cs`) — include the command file in the cleanup.

## Code Style

- Match the style of surrounding code.
- Every code file starts with a 2-line `ABOUTME:` comment explaining what the file does:
  ```bash
  # ABOUTME: Logs every Bash tool call to .cs/logs/session.log with timestamp.
  # ABOUTME: Truncates long commands at 200 chars; never blocks on errors.
  ```
- No emojis in code or documentation (unless part of a functional emoji set).
- No temporal names (`NewAPI`, `LegacyHandler`, `ImprovedParser`). Name things for what they do, not their history.
- Test output must be clean. If a test intentionally triggers errors, capture and validate them.

## Releasing

Releases are managed via the `/release` slash command. See `.claude/commands/release.md` for the full checklist, which covers version bumps, changelog, signing, and GitHub Release creation.
