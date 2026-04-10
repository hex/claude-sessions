# Contributing to cs

Practical guide for adding hooks, commands, and other contributions to cs.

## Development Setup

```bash
git clone https://github.com/hex/claude-sessions.git
cd claude-sessions
```

The main script is `bin/cs`. Hooks live in `hooks/`, commands in `commands/`, and tests in `tests/`.

## Running Tests

Tests use a shared library (`tests/test_lib.sh`) that provides assertions, temporary directories, and test isolation.

```bash
# Run all tests
for f in tests/test_*.sh; do bash "$f"; done

# Run a single test file
bash tests/test_hooks.sh

# Run a specific test function
bash tests/test_hooks.sh test_session_start_creates_log
```

There are 283+ tests across 17 test suites. All tests must pass before submitting changes.

## Adding a Hook

1. **Create the hook script** in `hooks/your-hook.sh`. Copy an existing hook (e.g., `hooks/bash-logger.sh`) as a starting template.

2. **Register in `install.sh`**:
   - Add a URL variable at the top: `HOOK_YOUR_HOOK_URL="${REPO_URL}/hooks/your-hook.sh"`
   - Add a path variable: `YOUR_HOOK_PATH="$HOME/.claude/hooks/your-hook.sh"`
   - Add a tilde variant: `YOUR_HOOK_TILDE="~/.claude/hooks/your-hook.sh"`
   - Add a `jq` block to merge the hook into `settings.json` under the appropriate event (`SessionStart`, `PreToolUse`, `PostToolUse`, etc.)

3. **Add to `run_uninstall()`** in `bin/cs` — add your hook filename to the cleanup loop so it gets removed on `cs -uninstall`.

4. **Document in `docs/hooks.md`** — add a section following the existing format: hook name, event type, description, and behavior.

5. **Write tests** in `tests/` — create a test file or add to an existing one. Use `test_lib.sh` for setup/teardown.

## Adding a Command

1. **Create `commands/name.md`** with YAML frontmatter specifying `allowed_tools`.

2. **Register in `install.sh`**:
   - Add a URL variable: `CMD_NAME_URL="${REPO_URL}/commands/name.md"`
   - Add the download step (uses `curl` with `wget` fallback)
   - Add the `cp` line for the command file

3. **Add to `run_uninstall()`** in `bin/cs` — include the command file in the cleanup.

## Code Style

- Match the style of surrounding code.
- Every code file starts with a 2-line `ABOUTME:` comment explaining what the file does:
  ```bash
  # ABOUTME: Tracks bash commands executed during a session.
  # ABOUTME: Logs interesting commands to .cs/commands.md with categorization.
  ```
- No emojis in code or documentation (unless part of a functional emoji set).
- No temporal names (`NewAPI`, `LegacyHandler`, `ImprovedParser`). Name things for what they do, not their history.
- Test output must be clean. If a test intentionally triggers errors, capture and validate them.

## Releasing

Releases are managed via the `/release` slash command. See `.claude/commands/release.md` for the full checklist, which covers version bumps, changelog, signing, and GitHub Release creation.
