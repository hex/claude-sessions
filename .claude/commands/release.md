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

### 0. Preflight: Confirm Branch and Sync

Before touching anything, verify you are releasing from the right point:

```bash
git fetch origin 2>/dev/null
git status -sb   # shows current branch and ahead/behind vs origin
```

If you are not on `main`, or `main` is behind `origin/main`, STOP and ask the user
via **AskUserQuestion** before proceeding — bumping, committing, and tagging from a
feature branch or a stale `main` puts the tag on the wrong commit (and Step 8's bare
`git push` may fail). Only continue once you are on `main` and up to date with origin.

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

**Fix any drift immediately** — update install.sh, the `run_uninstall()` source in `lib/85-adopt-uninstall.sh` (then re-run `./build.sh` to regenerate bin/cs), and docs/hooks.md before proceeding. Never hand-edit bin/cs; it is assembled from lib/.

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

**How to verify (do not skim):** for each doc, extract the commands, flags, and paths
it names and grep them against the source to confirm each still exists — e.g.
`grep -n -- '-secrets' bin/cs lib/*.sh`, or check a flag with `rg` across `bin/` and
`lib/`. Then cross-check what changed since the previous release
(`git log <PREV_TAG>..HEAD --oneline`, where PREV_TAG is
`git tag --list 'v*' --sort=-version:refname | head -1`) against `README.md` so newly
added features are documented. This turns "docs look accurate" into a checked claim.

**Report before proceeding:** one line per doc — `checked / issues found / fixed` — so
the review is auditable rather than a skim.

**Fix any issues found** - update the documentation to match current code.

### 4. Simplify Code

Invoke the `/simplify` skill via the Skill tool to review all pending changes for reuse, quality, and efficiency. This catches duplicated logic, hacky patterns, and inefficiencies before they ship.

The skill fans out three parallel review agents (reuse, quality, efficiency) over the diff and auto-applies fixes it finds. The subsequent test run (Step 5) validates that nothing was broken.

An empty working-tree diff is expected, not an anomaly, when the release's changes were
already committed in earlier sessions (the normal case) — `/simplify` reviews only the
uncommitted diff, not the release's shipped content. Confirm the release content exists
via `git log <PREV_TAG>..HEAD --oneline` (PREV_TAG =
`git tag --list 'v*' --sort=-version:refname | head -1`) and move on. Only if BOTH the
working-tree diff and that commit range are empty, stop and confirm with the user via
**AskUserQuestion** whether a zero-change release is intended.

### 5. Run Tests

Run the full test suite to verify nothing is broken before releasing:

```bash
bash tests/run_all.sh                        # aggregates every suite; fails if any suite fails
cargo test --manifest-path tui/Cargo.toml    # cs-tui binaries ship in the release
```

(Do not use `bash tests/test_*.sh` — bash runs only the first glob match and
passes the rest as ignored arguments, so all but one suite silently never run.)

Stop immediately if any tests fail. Do not proceed with the release until all tests pass.

### 6. Generate Release Notes and Get Approval

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

If `PREV_TAG` is empty (first release, or the tag fetch failed), treat this as the
first release: use the full `git log` and omit the Full Changelog compare link below —
do not run `git log ""..HEAD`, which errors.

**Cross-check against CHANGELOG.md** to avoid duplicating already-released features. Read the previous release entry in CHANGELOG.md and verify that nothing in your draft was already shipped. This is critical when working tree changes accumulate across multiple sessions — features from earlier sessions may already be released even though the files show as modified in `git diff`.

- Group the commits into categories: **Features**, **Fixes**, **Docs**, **Other**
- Draft release notes in markdown format with a `## What's Changed` heading
- Include a `**Full Changelog**` link: `https://github.com/hex/claude-sessions/compare/vPREVIOUS...vNEW`

Show the draft to the user via **AskUserQuestion** with options:
- **Approve** - proceed with commit and release
- **Edit** - let the user provide revised release notes
- **Cancel release** - abort; make no commit, push, tag, or GitHub release

Do NOT proceed to commit until the user explicitly approves. **Edit** does not count as
approval: after the user provides edits, show the revised notes and ask again via
**AskUserQuestion**, looping until you get an explicit **Approve**. Only that unlocks
Step 8.

### 7. Update Changelog

CHANGELOG.md exists at the repo root. Now that the release notes are approved (Step 6), insert them as a new `## X.Y.Z` section at the top of the file (after the header, before the previous version's section). Use the version number WITHOUT the `v` prefix to match existing entries. Include all the same content as the GitHub Release notes. If a `## Unreleased` section exists, fold its entries into this new version section rather than leaving a duplicate.

The CHANGELOG entry is committed as part of the release commit in Step 8.

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

**Inspect the `git status` output before `git add -A`.** If it shows files unrelated to
the release — scratch scripts, test artifacts, `.DS_Store`, stray build output — do NOT
use `-A`: stage the release files explicitly (`git add lib/00-header.sh bin/cs
CHANGELOG.md <docs you touched>`) and ask the user about the strays before committing.
`-A` is only safe when status shows exactly the release's own changes.

### 9. Create GitHub Release

Create a GitHub release with the approved release notes using the `gh` CLI:

```bash
gh release create vX.Y.Z --title "vX.Y.Z" --notes "$(cat <<'EOF'
<approved release notes here>
EOF
)"
```

### 10. Verify the Release Workflow Succeeded

`gh release create` returning is NOT the finish line — the tag push kicks off the CI
release workflow that signs and attaches the assets, and it can still fail (signing,
asset upload). Watch it to completion:

```bash
gh run list --workflow=release.yml --limit 1   # or: gh run watch
gh release view vX.Y.Z --json assets --jq '.assets[].name'
```

The release is not done until the `.minisig` signature files and `install.sh` appear as
release assets. If the workflow fails, report it to the user before stopping — a green
`gh release create` with a red workflow ships a release that installers cannot verify.

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
