---
allowed-tools:
  - Read
  - Edit
  - Grep
  - Glob
  - Bash
  - Task
  - AskUserQuestion
  - Skill
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

Read `lib/00-header.sh` and find the VERSION line (near the top). Calculate the new version:

```bash
# Get current date
YEAR=$(date +%Y)
MONTH=$(date +%-m)  # No leading zero
```

- If current version's YYYY.MM matches today's YYYY.M: increment BUILD by 1
- If current version's YYYY.MM is older: reset to YYYY.M.1

Update the VERSION line in `lib/00-header.sh`, then run `./build.sh` to regenerate
`bin/cs` from the `lib/` fragments. `bin/cs` is assembled — never edit it directly.

### 2. Verify Install/Uninstall Parity

Check that `install.sh` and `run_uninstall()` in `bin/cs` are in sync. Both derive from shared manifest arrays (`CS_HOOKS`, `RETIRED_HOOKS`, `CS_COMMANDS`, `CS_SKILLS`, duplicated between the two files behind KEEP IN SYNC comments), and the sync is machine-checked:

```bash
# The manifest sync tests are the authoritative parity check: they compare
# the arrays between install.sh and bin/cs AND against the actual repo
# contents of hooks/, commands/, skills/, plus the settings-strip jq filter.
bash tests/test_install.sh
```

**Check these specifically (not covered by the sync tests):**
- Every binary installed (`cs`, `cs-secrets`, `cs-statusline`, `cs-tui`) is removed by `run_uninstall()`
- Every settings.json hook event configured by `install.sh` is cleaned up by `run_uninstall()`

**Fix any drift immediately** — update all three locations (install.sh, run_uninstall, docs/hooks.md) before proceeding.

### 3. Review Documentation

Check these files for accuracy against the current code:

**Required checks:**
- `README.md` - Verify features list matches actual functionality
- `docs/hooks.md` - Verify hook descriptions match actual hook files
- `docs/secrets.md` - Verify backend descriptions and commands
- `docs/session-layout.md` - Verify the .cs/ layout and paths (.cs/local/, timeline.jsonl)
- `docs/statusline.md` - Verify status line segments, flags, and behavior

**What to look for:**
- Commands or flags mentioned in docs that don't exist in code
- Features in code not documented
- Incorrect examples or outdated syntax
- Missing new features added since last release

**Fix any issues found** - update the documentation to match current code.

### 4. Simplify Code

Invoke the `/simplify` skill via the Skill tool to review all pending changes for reuse, quality, and efficiency. This catches duplicated logic, hacky patterns, and inefficiencies before they ship.

The skill fans out three parallel review agents (reuse, quality, efficiency) over the diff and auto-applies fixes it finds. The subsequent test run (Step 6) validates that nothing was broken.

If `/simplify` reports an empty diff, verify this is intentional — a release with zero code changes is unusual unless it's a pure docs/changelog release.

### 5. Update Changelog

CHANGELOG.md exists at the repo root. After generating release notes (Step 7) and getting approval, insert the approved notes as a new `## X.Y.Z` section at the top of the file (after the header, before the previous version's section). Use the version number WITHOUT the `v` prefix to match existing entries. Include all the same content as the GitHub Release notes.

The CHANGELOG entry is committed as part of the release commit in Step 8.

### 6. Run Tests

Run the full test suite to verify nothing is broken before releasing:

```bash
bash tests/run_all.sh                        # aggregates every suite; fails if any suite fails
cargo test --manifest-path tui/Cargo.toml    # cs-tui binaries ship in the release
```

(Do not use `bash tests/test_*.sh` — bash runs only the first glob match and
passes the rest as ignored arguments, so all but one suite silently never run.)

Stop immediately if any tests fail. Do not proceed with the release until all tests pass.

### 7. Generate Release Notes and Get Approval

Generate release notes by looking at what changed since the last release:

```bash
# Fetch tags from remote (gh release create makes tags on GitHub, not locally)
git fetch --tags origin 2>/dev/null

# Find the previous release tag
PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)

# View commits since last tag
git log "$PREV_TAG"..HEAD --oneline --no-merges

# IMPORTANT: Also check uncommitted changes (git diff --stat) since
# some releases may have only working tree changes with no intermediate commits
```

**Cross-check against CHANGELOG.md** to avoid duplicating already-released features. Read the previous release entry in CHANGELOG.md and verify that nothing in your draft was already shipped. This is critical when working tree changes accumulate across multiple sessions — features from earlier sessions may already be released even though the files show as modified in `git diff`.

- Group the commits into categories: **Features**, **Fixes**, **Docs**, **Other**
- Draft release notes in markdown format with a `## What's Changed` heading
- Include a `**Full Changelog**` link: `https://github.com/hex/claude-sessions/compare/vPREVIOUS...vNEW`

Show the draft to the user via **AskUserQuestion** with options:
- **Approve** - proceed with commit and release
- **Edit** - let the user provide revised release notes

Do NOT proceed to commit until the user approves.

### 8. Commit and Push

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

### 9. Create GitHub Release

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
- The version bump is a single Edit to the VERSION line in `lib/00-header.sh`, followed by `./build.sh` — never edit `bin/cs` directly (it is assembled, and CI fails if it drifts from `lib/`)
- Run `git status` before committing to verify what's being included
- Always create the GitHub release after pushing
- Do NOT commit or push until release notes are approved
