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
   - Add a `_merge_cs_hook <Event> your-hook.sh <timeout> [matcher] [async]` call alongside the existing ones (see the block around `install.sh`'s `_merge_cs_hook SessionStart ...` calls) to register it in `settings.json` under the appropriate event (`SessionStart`, `PreToolUse`, `PostToolUse`, etc.); it derives the deploy and `~`-relative paths from the filename

3. **Add to `CS_HOOKS` in `lib/00-header.sh`** (assembled into `bin/cs`) — uninstall and doctor derive from it. `tests/test_install.sh` fails if the two arrays disagree with each other or with the actual contents of `hooks/`.

4. **Document in `docs/hooks.md`** — add a section following the existing format: hook name, event type, description, and behavior.

5. **Write tests** in `tests/` — create a test file or add to an existing one. Use `test_lib.sh` for setup/teardown.

## Adding a Command

1. **Create `commands/name.md`** with YAML frontmatter specifying `allowed-tools` (hyphen — Claude Code ignores the `allowed_tools` underscore form).

2. **Add the filename to the `CS_COMMANDS` array** in both `install.sh` and `lib/00-header.sh` (assembled into `bin/cs`) — the two carry KEEP IN SYNC comments. Install (download + copy), `run_uninstall()`, and doctor all loop over the array, so no per-command variable or cleanup edit is needed. `tests/test_install.sh` fails if the arrays disagree with each other or with the actual `commands/` files.

## Adding a Skill

1. **Create `skills/name/SKILL.md`** with the skill's frontmatter (`name`, `description`) and instructions. Copy an existing skill (e.g., `skills/store-secret/`) as a template.

2. **Add the directory name to the `CS_SKILLS` array** in both `install.sh` and `lib/00-header.sh` (KEEP IN SYNC comments) — install, `run_uninstall()`, and doctor all loop over it. `tests/test_install.sh` fails if the array disagrees with the `skills/` directory contents.

## Code Style

- Match the style of surrounding code.
- Every code file starts with a 2-line `ABOUTME:` comment explaining what the file does:
  ```bash
  # ABOUTME: Logs every Bash tool call to .cs/local/session.log with timestamp.
  # ABOUTME: Truncates long commands at 200 chars; never blocks on errors.
  ```
- No emojis in code or documentation (unless part of a functional emoji set).
- No temporal names (`NewAPI`, `LegacyHandler`, `ImprovedParser`). Name things for what they do, not their history.
- Test output must be clean. If a test intentionally triggers errors, capture and validate them.

## Releasing

Releases are managed via the `/release` slash command. See `.claude/commands/release.md` for the full checklist, which covers version bumps, changelog, signing, and GitHub Release creation.
