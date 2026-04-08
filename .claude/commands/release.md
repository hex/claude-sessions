---
allowed_tools:
  - Read
  - Edit
  - Grep
  - Glob
  - Bash
  - Task
  - AskUserQuestion
---

Release a new version of cs (claude-sessions).

## Version Format

The version format is `YYYY.MM.BUILD` where:
- `YYYY` = current year (4 digits)
- `MM` = current month (1-2 digits, no leading zero)
- `BUILD` = incrementing build counter that resets each month

Examples: `2026.1.42`, `2026.12.1`

## Release Steps

### 1. Bump Version Number

Read `bin/cs` and find the VERSION line (near the top). Calculate the new version:

```bash
# Get current date
YEAR=$(date +%Y)
MONTH=$(date +%-m)  # No leading zero
```

- If current version's YYYY.MM matches today's YYYY.M: increment BUILD by 1
- If current version's YYYY.MM is older: reset to YYYY.M.1

Update the VERSION line in `bin/cs`.

### 2. Verify Install/Uninstall Parity

Check that `install.sh` and `run_uninstall()` in `bin/cs` are in sync. The source of truth is `hooks/*.sh`.

```bash
# Verify all three match:
REPO=$(ls hooks/*.sh | xargs -I{} basename {} | sort)
INSTALL_SH=$(rg -o 'cp "\$HOOKS_SOURCE/[^"]+' install.sh | sed 's/.*\///' | sort)
UNINSTALL=$(rg "for hook in" bin/cs | grep -oE '[a-z-]+\.sh' | tr ' ' '\n' | sort)
diff <(echo "$REPO") <(echo "$INSTALL_SH") && echo "install.sh: OK"
diff <(echo "$REPO") <(echo "$UNINSTALL") && echo "uninstall: OK"
```

**Check these specifically:**
- Every hook file in `hooks/` is installed by `install.sh` AND removed by `run_uninstall()`
- Every binary installed (`cs`, `cs-secrets`, `cs-tui`) is removed by `run_uninstall()`
- Every settings.json hook event configured by `install.sh` is cleaned up by `run_uninstall()`
- Commands and skills installed by `install.sh` are removed by `run_uninstall()`

**Fix any drift immediately** — update all three locations (install.sh, run_uninstall, docs/hooks.md) before proceeding.

### 3. Review Documentation

Check these files for accuracy against the current code:

**Required checks:**
- `README.md` - Verify features list matches actual functionality
- `docs/hooks.md` - Verify hook descriptions match actual hook files
- `docs/secrets.md` - Verify backend descriptions and commands
- `docs/sync.md` - Verify sync commands and workflow

**What to look for:**
- Commands or flags mentioned in docs that don't exist in code
- Features in code not documented
- Incorrect examples or outdated syntax
- Missing new features added since last release

**Fix any issues found** - update the documentation to match current code.

### 4. Update Changelog (if present)

If a CHANGELOG.md exists, add an entry for this version.

### 5. Run Tests

Run the full test suite to verify nothing is broken before releasing:

```bash
bash tests/test_*.sh
```

Stop immediately if any tests fail. Do not proceed with the release until all tests pass.

### 6. Generate Release Notes and Get Approval

Generate release notes by looking at commits since the last release tag:

```bash
# Fetch tags from remote (gh release create makes tags on GitHub, not locally)
git fetch --tags origin 2>/dev/null

# Find the previous release tag
PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)

# View commits since last tag
git log "$PREV_TAG"..HEAD --oneline --no-merges
```

- Group the commits into categories: **Features**, **Fixes**, **Docs**, **Other**
- Draft release notes in markdown format with a `## What's Changed` heading
- Include a `**Full Changelog**` link: `https://github.com/hex/claude-sessions/compare/vPREVIOUS...vNEW`

Show the draft to the user via **AskUserQuestion** with options:
- **Approve** - proceed with commit and release
- **Edit** - let the user provide revised release notes

Do NOT proceed to commit until the user approves.

### 7. Commit and Push

```bash
# Run git status first to verify what's being included
git status

# Stage all changes
git add -A

# Commit with version
git commit -m "Release vX.Y.Z"

# Push to remote
git push
```

### 8. Create GitHub Release

Create a GitHub release with the approved release notes using the `gh` CLI:

```bash
gh release create vX.Y.Z --title "vX.Y.Z" --notes "$(cat <<'EOF'
<approved release notes here>
EOF
)"
```

## Signed Releases

The CI release workflow automatically:
- Signs `install.sh` and all `cs-tui-*` binaries with minisign
- Uploads `.minisig` signature files alongside the binaries
- Includes `install.sh` as a release asset (updates download from releases, not main)

The minisign private key is stored as GitHub Secret `MINISIGN_KEY`. The public key is embedded in `bin/cs` and `install.sh` as `CS_SIGN_PUBKEY`.

No manual signing is needed — CI handles everything on tag push.

## Important

- Do NOT skip the documentation review - it's the most important part
- If you find significant documentation issues, list them before fixing
- The version bump should be a single Edit to bin/cs
- Run `git status` before committing to verify what's being included
- Always create the GitHub release after pushing
- Do NOT commit or push until release notes are approved
