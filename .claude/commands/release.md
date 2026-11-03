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
feature branch or a stale `main` puts the tag on the wrong commit (and Step 8c's bare
`git push` may fail). Only continue once you are on `main` and up to date with origin.

### 0b. Preflight: The Release Content Must Be Green on CI First

The ghost gate (Step 8b) runs the suite on one machine and one shell (bash
5.3). Every job in `.github/workflows/test.yml` must have judged the content
being released **before** the tag is cut, or the tag lands on a commit CI has
never seen. Step 8c gates the tag on the release commit's own run; this step
catches a red lane before the bump and the notes are written.

Push anything unpushed, then wait for the Test workflow on `HEAD` and read every
job:

```bash
git push                       # the release content, not the release commit
gh run list --workflow=test.yml --branch main --limit 1 \
  --json status,conclusion,headSha --jq '.[0]'
# once completed, read the per-job results — an overall "success" is not enough
gh run list --workflow=test.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId' \
  | xargs -I{} gh run view {} --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
```

Confirm the run's `headSha` is the commit you are about to release from — a
green run on an older commit proves nothing about this one. If any job failed,
STOP: fix it and re-verify before bumping.

**Why this step exists.** 2026.8.10 and 2026.8.11 were both tagged on commits
whose CI then went red, and both were repaired by the very next commit — so
`main` recovered while the *tags* kept pointing at red. Both failures were
Linux-only (a signed-`pid_t` split in `kill`, then a SIGPIPE race that only lost
on a 2-core runner), and neither could reproduce on a macOS dev box. Local green
is one platform's opinion.

### 1. Bump Version Number

Read `lib/00-header.sh` and find the VERSION line (near the top). Calculate the new version:

```bash
# Get current date
YEAR=$(date +%Y)
MONTH=$(date +%-m)  # No leading zero
```

- If current version's YYYY.MM matches today's YYYY.M: increment BUILD by 1
- If current version's YYYY.MM is older: reset to YYYY.M.1

Update the VERSION line in `lib/00-header.sh`, then run `./build.sh --add-release-hashes`
to regenerate `bin/cs` from the `lib/` fragments. `bin/cs` is assembled — never edit it directly.

The flag adds the sha256 of every file this release deploys under `~/.claude` to
`CS_KNOWN_SHA256` in `lib/01-manifests.sh` before building, so a later install still
knows those files as cs's and replaces them after someone deletes `~/.claude/hooks/cs`,
install record included, by hand.

### 2. Verify Install/Uninstall Parity

Check that `install.sh` and `run_uninstall()` in `bin/cs` are in sync. Both read the manifest arrays (`CS_HOOKS`, `CS_HOOK_LIBS`, `RETIRED_HOOKS`, `CS_COMMANDS`, `CS_SKILLS`, `RETIRED_SKILLS`, `CS_SKILL_FILES`, `CS_MOD_FILES`) and the settings-strip filter from one file, `lib/01-manifests.sh`: `./build.sh` folds it into `bin/cs` and splices it into `install.sh` from `install.sh.in`. Edit the lib file or the template, never `install.sh`. The sync is machine-checked:

```bash
# The manifest tests are the authoritative parity check: they rebuild
# install.sh and hooks/cs-shared.sh from source and diff them against the
# committed files, and compare the arrays against the actual repo contents
# of hooks/, commands/, skills/ and mods/.
bash tests/test_install.sh
```

**Check these specifically (not covered by the sync tests):**
- Every binary installed (`cs`, `cs-secrets`, `cs-statusline`, `cs-tui`) is removed by `run_uninstall()`
- Every settings.json hook event configured by `install.sh` is cleaned up by `run_uninstall()`

**Fix any drift immediately** — update `install.sh.in`, `lib/01-manifests.sh` or the `run_uninstall()` source in `lib/85-adopt-uninstall.sh` (then re-run `./build.sh` to regenerate bin/cs and install.sh), and docs/hooks.md before proceeding. Never hand-edit bin/cs or install.sh; both come out of `./build.sh`.

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

**Spinner tips** (`mods/cs/tips.json`, the file the installer names in Claude
Code's `spinnerTipsOverride.tipsFile`): the tips are documentation the user
reads in the spinner, so review them in the same pass. For each tip, run the
command or path it names and confirm it still exists and still does what the
tip says; drop a tip for a feature this release removes, reword one whose
command or wording changed, and add one for each user-facing feature in
`git log <PREV_TAG>..HEAD` that a tip could lead the user to (a slash command,
a `/config` row, a cs verb). Keep the shape `tests/test_install.sh` enforces:
an `id` of letters, digits, `.`, `_` or `-`, a `text` under 500 characters.
Report it on the same one line per file as the docs. Changing the file
changes the hash `install.sh` carries for it, so `./build.sh` runs in Step 2's
spirit and the rebuilt `install.sh` goes into the release commit.

### 4. Simplify Code

Invoke the `/simplify` skill via the Skill tool to review all pending changes for reuse, quality, and efficiency. This catches duplicated logic, hacky patterns, and inefficiencies before they ship.

The skill fans out three parallel review agents (reuse, quality, efficiency) over the diff and auto-applies fixes it finds. The ghost gate on the release commit (Step 8b) and its CI run (Step 8c) validate that nothing was broken.

An empty working-tree diff is expected, not an anomaly, when the release's changes were
already committed in earlier sessions (the normal case) — `/simplify` reviews only the
uncommitted diff, not the release's shipped content. Confirm the release content exists
via `git log <PREV_TAG>..HEAD --oneline` (PREV_TAG =
`git tag --list 'v*' --sort=-version:refname | head -1`) and move on. Only if BOTH the
working-tree diff and that commit range are empty, stop and confirm with the user via
**AskUserQuestion** whether a zero-change release is intended.

### 4b. Code-Review the Release Range

`/simplify` hunts quality problems and explicitly not correctness bugs; this
step is the correctness gate. Skip it only when the release range
touches documentation alone.

Review everything the release ships — the committed range plus any
working-tree changes:

```bash
PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)
git log "$PREV_TAG"..HEAD --oneline
```

Invoke the `/code-review` skill via the Skill tool over that range when the
skill is available. When it is not, run an equivalent adversarial review:
parallel finder agents over the range diff with a correctness lens (wrong
paths, inverted conditions, test fixtures that diverge from production
layouts), then an independent skeptic per finding that tries to refute it —
only skeptic-confirmed findings count. A green test suite does not catch a
test whose fixture builds the same wrong path the code probes; that
fixture-reaches-branch class is what this step exists to catch.

Do not proceed until the Critical and Important findings are fixed (or
dismissed as false positives, each with a stated reason). Minor findings may
ship as follow-ups noted in the release notes or the narrative. For an
unusually large or risky range, suggest the user run `/code-review ultra` —
it is user-triggered and billed; never attempt to launch it yourself.

**Rule-shaped changes need a measurement, not a reading.** If the range touches
anything whose correctness is a claim about a population — a redaction or
validation rule, a regex, a filter, a matcher, a classifier — one reviewer MUST
run it against the real population and report two numbers: how often it fires,
and how often that firing is correct. Reading the diff is not enough and neither
is a green suite.

The author cannot supply that measurement, because the failure is not a wrong
answer, it is a fixture chosen where the author's own assumption holds. Test
both directions explicitly: what the rule wrongly lets through, and what it
wrongly destroys. A rule that fires twice on real input and is wrong both times
is data loss, not a filter, and a suite can be entirely green while that is true.

This is the step's own history, not a hypothetical. The corpus redactor merged
in `fa8856b` and was tagged 80 minutes later in `v2026.7.14`, one day before
this gate existed. It then survived 29 releases unseen, because every review
after it was scoped to the range that release touched. It was caught only when
`dcf8eec` re-touched the code and a reviewer measured it over 2384 real
transcripts: two firings, both false positives, zero credentials caught. Scope a
review to a diff and it sees a defect once; measure a rule against its
population and the defect has nowhere to sit.

### 5. Run Tests

The bash suites do not run on this machine. They run twice on the release
commit itself, once it exists: on ghost (Step 8b), then in CI (Step 8c). A
local full run loads the dev box for minutes and judges nothing the ghost run
does not. Here, run only the Rust tests:

```bash
cargo test --manifest-path tui/Cargo.toml    # cs-tui binaries ship in the release
```

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

### 8. Commit

```bash
# Steps 2-7 may have changed a hook, command, skill or mod file, and the table
# must hold the payload this commit ships; a run with nothing to add changes
# nothing
./build.sh --add-release-hashes

# Run git status first to verify what's being included
git status

# Stage all changes
git add -A

# Commit with version; do not push yet
git commit -m "Release vX.Y.Z"

# The full sha every later step names
SHA=$(git rev-parse HEAD)
```

**Inspect the `git status` output before `git add -A`.** If it shows files unrelated to
the release — scratch scripts, test artifacts, `.DS_Store`, stray build output — do NOT
use `-A`: stage the release files explicitly (`git add lib/00-header.sh
lib/01-manifests.sh bin/cs install.sh hooks/cs-shared.sh CHANGELOG.md <docs you touched>`,
plus every file under `hooks/`, `commands/`, `skills/` and `mods/` that Steps 2-7
changed) and ask the user about the strays before committing.
`-A` is only safe when status shows exactly the release's own changes.

### 8b. Ghost Gate on the Release Commit

Run the full bash suite on ghost against exactly `$SHA`, with the claude-tmux
plugin's `remote-tests` script (`scripts/remote-tests.sh`):

```bash
GATE=<scratchpad>/release-gate-$SHA
git clone --quiet . "$GATE" \
  && git -C "$GATE" checkout --quiet --detach "$SHA" \
  && [ "$(git -C "$GATE" rev-parse HEAD)" = "$SHA" ] \
  && bash <claude-tmux>/scripts/remote-tests.sh --host ghost@ghost --repo "$GATE" \
       --cmd 'bash tests/run_all.sh'
```

The clone checks out `$SHA` itself, never `main`'s tip: a commit that lands on
`main` after Step 8 would otherwise be the one judged. If the clone, the
checkout or the sha check fails, nothing launches; stop and find out why.

- Gate from a clone, never a git worktree: a worktree's `.git` points at a path
  that exists only on this machine, and every git-using suite fails on ghost.
- Use the literal `--host ghost@ghost`; the bare name needs `/remote`'s host
  store. A remote-tests failure is a reason to try the literal form, never to
  fall back to a local run.
- One suite command per launch. `tests/run_all.sh` is the multi-suite command;
  a `;`-chained `--cmd` keeps only the last suite's output. Never glob
  (`bash tests/test_*.sh`): bash runs the first match and passes the rest as
  ignored arguments, so all but one suite silently never run.
- The script returns once the run starts. Remove any stale `suite.status` in
  the remote directory before launching, then wait for it from a background
  shell (never a foreground `sleep`) and read the exit code it holds, not a
  count of failures.
- ghost runs bash 5.3, so it never judges a bash 3.2 defect; only CI's
  macos-latest lane does (Step 8c). Before reading a mod-suite failure or skip
  there, compare `claude --version` on both machines; a stale ghost Claude Code
  refuses newer plugin manifest keys.

Stop if the exit code is not 0. Fix the failure in a new commit, then repeat
Step 8 and this step on the new sha.

### 8c. Push and Wait for That Commit's CI

```bash
git push
gh run list --workflow=test.yml --commit "$SHA" --limit 1 \
  --json databaseId,status,conclusion --jq '.[0]'
# once completed, read every job; an overall "success" is not enough
gh run view <databaseId> --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
```

Poll from a background shell; the lanes take about 15 minutes. Judge by the
per-job conclusions of the run whose commit is `$SHA`, never by
`gh run watch`'s exit status, which can return 1 while a job is still running.
A job `cancelled` with zero steps is infrastructure, not code: check
`https://www.githubstatus.com/api/v2/incidents/unresolved.json`, then
`gh run rerun <databaseId> --failed`. A code failure gets a fix in a new
commit; repeat Step 8 from its `./build.sh --add-release-hashes` line (the fix
may touch a hook, command, skill or mod file), then Steps 8b and 8c on the new
sha. Do not tag until every job is `success`.

### 9. Create GitHub Release

Create a GitHub release with the approved release notes using the `gh` CLI, on
the commit Steps 8b and 8c judged:

```bash
gh release create vX.Y.Z --target "$SHA" --title "vX.Y.Z" --notes "$(cat <<'EOF'
<approved release notes here>
EOF
)"
```

`--target` takes the FULL sha; a short one fails with "target_commitish is
invalid". It pins the tag to the release commit even when another commit (a
session-state commit, say) has landed on `main` since. Hold the tag while
GitHub reports Actions runners delayed: `release.yml` builds the assets after
the tag, and a cancelled build leaves the release public with none.

### 10. Verify the Release Workflow Succeeded

Wait for the release workflow for this tag to succeed before signing its assets.

```bash
gh run list --workflow=release.yml --branch vX.Y.Z --limit 1 \
  --json databaseId,status,conclusion,headSha
gh run view <databaseId> --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
```

Confirm that the run's `headSha` is `$SHA` and every job succeeded. If any job
failed, stop and report the failure before signing.

Download the assets, verify every manifest digest, and compare the installer
with the tagged commit. The only permitted difference is `CS_DEFAULT_REF=main`
replaced by the release tag. Run the following in one shell so a failed check
stops before signing:

```bash
set -euo pipefail
tag=vX.Y.Z
git fetch origin "refs/tags/${tag}:refs/tags/${tag}"
test "$(git rev-parse "$tag^{commit}")" = "$SHA"
test "$(git show "${tag}:lib/00-header.sh" | grep -m1 '^VERSION=' | cut -d'"' -f2)" = "${tag#v}"
release_dir=$(mktemp -d)
gh release download "$tag" -p SHA256SUMS -p install.sh -p 'cs-tui-*' -D "$release_dir"
(
  cd "$release_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
)
git show "${tag}:install.sh" > "$release_dir/committed-install.sh"
awk -v tag="$tag" '$0 == "CS_DEFAULT_REF=main" {$0="CS_DEFAULT_REF=" tag} {print}' \
  "$release_dir/committed-install.sh" > "$release_dir/expected-install.sh"
diff -u "$release_dir/expected-install.sh" "$release_dir/install.sh"
(
  cd "$release_dir"
  SSH_AUTH_SOCK="${RELEASE_SIGNING_AGENT:-$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock}" \
    ssh-keygen -Y sign -f "${RELEASE_SIGNING_KEY:-$HOME/.ssh/release-signing.pub}" -n "cs-release-$tag" SHA256SUMS
)
gh release upload "$tag" "$release_dir/SHA256SUMS.sig"
gh release view "$tag" --json assets --jq '.assets[].name' | grep -qxF SHA256SUMS.sig
```

The release is not done until `SHA256SUMS.sig` is a release asset.
The signature's namespace is the tag, and the verifiers derive it from the
release's own `VERSION`, so a tag that does not match the tagged commit's
`VERSION` is never signed. Investigate a checksum failure or installer diff
before signing.
An installer changed by CI must never receive a local signature.

## Signed Releases

CI publishes `install.sh`, the `cs-tui-*` binaries, and their `SHA256SUMS`
manifest. It also publishes `install.sh.sha256` and each binary's `.sha256`
file for installed copies that read those assets.

Step 10 signs the manifest locally with the agent-held SSH key named by
`~/.ssh/release-signing.pub`. Bitwarden's ssh-agent holds the private key.
`RELEASE_SIGNING_KEY` overrides that path. CI holds no signing key.

The private key is reachable only through Bitwarden's own agent socket,
`~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock`
(`RELEASE_SIGNING_AGENT` overrides it). Every shell here, the Bash tool's
and the user's, has `SSH_AUTH_SOCK` on the macOS launchd agent, which holds
only the login keys, so a sign without that override fails with
`No private key found for public key`. The socket exists only while
Bitwarden desktop is open and unlocked with its SSH agent on; the sign
runs from the Bash tool and needs no hand-off to the user. The step's
tag expansions are braced (`${tag}:...`) because the Bash tool runs zsh,
where `$tag:lib` reads `:l` as a modifier and corrupts the ref.

`cs -update` and the installer's picker download require
`ssh-keygen -Y verify` to authenticate `SHA256SUMS.sig` in the release's own
namespace, `cs-release-vX.Y.Z`, then compare the downloaded file with its
manifest digest. A signature made for one tag never verifies another, and
`cs -update` refuses a release older than the installed cs.
`CS_RELEASE_SIGNERS` contains the allowed signers and `CS_RELEASE_REVOKED`
contains revoked public keys. An update refuses a release that drops any
revoked key.

## Important

- Do NOT skip the documentation review - it's the most important part
- If you find significant documentation issues, list them before fixing
- The version bump is a single Edit to the VERSION line in `lib/00-header.sh`, followed by `./build.sh --add-release-hashes` — never edit `bin/cs` directly (it is assembled, and CI fails if it drifts from `lib/`)
- Run `git status` before committing to verify what's being included
- Create the GitHub release only after the release commit passed the ghost gate and every CI job, with `--target <full sha>`
- Do NOT commit or push until release notes are approved
