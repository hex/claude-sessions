# Multi-Person Co-Development — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the session narrative a shared, per-actor lab-notebook so teammates see each other's reasoning without merge conflicts, and stop the (Claude-Code-maintained) `MEMORY.md` index from causing merge headaches — while leaving memory attribution to git history.

**Architecture:** The narrative splits from one `narrative.md` into per-actor `narrative.<actor-slug>.md` files (everyone reads all, each appends only to their own → different people never conflict). cs fully owns the narrative (`ensure_narrative_file`), so this is a clean cs change. Memory *files* and the `MEMORY.md` *index* are owned by Claude Code's built-in memory feature (cs only redirects the path), so Phase 2 does **not** stamp `author:` frontmatter or regenerate the index — git history already attributes memories by commit author. The only index touch is a `.gitattributes merge=ours` so the hand-maintained index never blocks a merge.

**Tech Stack:** Bash (macOS stock `/bin/bash` 3.2), git, BSD `sed`/`tr`, `tests/test_lib.sh` harness, hook scripts under `hooks/`.

## What lives where (unchanged from Phase 1, narrative now per-actor)

| Shared — committed | Local — `.cs/local/`, gitignored |
|---|---|
| `memory/*.md` (Claude Code's memory; git-attributed) | `session.lock`, `watermark`, cooldowns |
| `memory/MEMORY.md` (Claude Code's index; `merge=ours`) | `logs/`, `timeline.jsonl` |
| `memory/narrative.<actor-slug>.md` (per-actor lab-notebook) | |
| `CLAUDE.md` | |

## Global Constraints

- **bash 3.2 floor:** no `local -A`, no `printf '%(...)T'`, no `${var^^}`, no `mapfile`. Use `tr`/`sed`. Hooks run under minimal-PATH `/bin/bash`.
- **macOS BSD tooling:** `sed -i ''`; POSIX BRE.
- **NEVER `git add -A` / `git add .cs`** for metadata staging (allowlist only). New-session init and migration commits already in the tree are pre-existing; do not widen them.
- **No auto-commit** at session end (removed v2026.6.9 — keep removed).
- **Do NOT touch memory file frontmatter or regenerate `MEMORY.md`** — owned by Claude Code's built-in memory. Attribution comes from `git log .cs/memory/`.
- **Actor slug:** reuse `_slugify` / `cs_actor_slug` from Phase 1; resolve from an explicit session dir (see Task 1 — `migrate_session` runs before `CLAUDE_SESSION_META_DIR` is exported).
- **Naming/comments:** two `# ABOUTME:` lines per file; evergreen comments; no "new"/"legacy".
- **Hooks have installed copies** under `~/.claude/hooks/cs/`; editing `hooks/*.sh` in the repo is correct — the live copies refresh on `cs -update`/install. Do not edit installed copies directly.

---

## File Structure

- **Modify `bin/cs`:**
  - `cs_actor_slug` (bin/cs:~990): accept optional `session_dir` arg; resolve identity file + `git -C` from it.
  - `ensure_narrative_file` (bin/cs:661): per-actor `narrative.<slug>.md`, migrate legacy `narrative.md`, per-actor index pointer, strip stale legacy pointer.
  - `write_session_claude_md` template (bin/cs:~750): "read all `narrative.*.md`" wording.
  - checkpoint narrative snapshot (bin/cs:1453): loop all `narrative*.md`.
  - Add `setup_memory_merge_driver`; call from adopt (both branches), new-session git-init (bin/cs:~3084), and `migrate_session`.
- **Modify `hooks/narrative-reminder.sh`:** stale-check globs `narrative.*.md` (newest mtime), not a single file.
- **Modify `hooks/autosave-commits.sh`:** narrative log-entry `case` matches `narrative.*.md`.
- **Tests:** extend `tests/test_actor_identity.sh` (per-actor narrative), `tests/test_adopt.sh` (gitattributes), `tests/test_hooks.sh` (reminder glob), `tests/test_shadow_ref.sh` or `tests/test_hooks.sh` (autosave glob), `tests/test_checkpoint.sh` (snapshot of all narratives).

No change needed: **search** already globs `.cs/memory/*.md` (catches `narrative.*.md`).

---

## Task 1+2: Per-actor narrative (resolver dir-arg + ensure_narrative_file)

Implemented together: the dir-arg resolver has no independent observable; the per-actor narrative file observes it. Single first green.

**Files:**
- Modify: `bin/cs` `cs_actor_slug` (~990), `ensure_narrative_file` (661-683)
- Test: `tests/test_actor_identity.sh`

**Interfaces:**
- Consumes: `_slugify` (Phase 1).
- Produces: `cs_actor_slug [session_dir]` — with an arg, resolves `.cs/local/identity` and git config from that dir; without, uses env + cwd (Phase 1 behavior, unchanged). `ensure_narrative_file <session_dir>` creates `memory/narrative.<slug>.md`, migrates a legacy `memory/narrative.md` into it, adds a per-actor `MEMORY.md` pointer, and removes the legacy `(narrative.md)` pointer.

- [ ] **Step 1: Write the failing tests** (add to `tests/test_actor_identity.sh`, before the runner block)

```bash
test_narrative_is_per_actor() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email "alex@example.com" && git config user.name "Alex" )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    assert_exists "$project_dir/.cs/memory/narrative.alex-example-com.md" \
        "per-actor narrative file should exist" || return 1
    assert_not_exists "$project_dir/.cs/memory/narrative.md" \
        "generic narrative.md should not be created for a new session" || return 1
    assert_file_contains "$project_dir/.cs/memory/MEMORY.md" "narrative.alex-example-com.md" \
        "index should point at the per-actor narrative" || return 1
}

test_legacy_narrative_migrates_to_actor() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir/.cs/memory"
    ( cd "$project_dir" && git init -q && git config user.email "bob@team.io" && git config user.name "Bob" )
    # Simulate a pre-Phase-2 session: a single narrative.md with content + legacy pointer.
    printf '%s\n' '# Session narrative' 'OLD ENTRY ABC' > "$project_dir/.cs/memory/narrative.md"
    printf '%s\n' '- [Session narrative (lab notebook)](narrative.md): old' > "$project_dir/.cs/memory/MEMORY.md"

    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )

    assert_exists "$project_dir/.cs/memory/narrative.bob-team-io.md" \
        "legacy narrative.md should migrate to the actor's file" || return 1
    assert_not_exists "$project_dir/.cs/memory/narrative.md" \
        "legacy narrative.md should be gone after migration" || return 1
    assert_file_contains "$project_dir/.cs/memory/narrative.bob-team-io.md" "OLD ENTRY ABC" \
        "migrated narrative should keep its content" || return 1
    assert_file_not_contains "$project_dir/.cs/memory/MEMORY.md" "(narrative.md)" \
        "stale legacy index pointer should be removed" || return 1
}
```

Add to the runner block:

```bash
run_test test_narrative_is_per_actor
run_test test_legacy_narrative_migrates_to_actor
```

> `assert_file_not_contains` exists in `tests/test_lib.sh:148`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — `narrative.alex-example-com.md` absent (a generic `narrative.md` is created instead).

- [ ] **Step 3: Implement the resolver dir-arg**

Replace `cs_actor_slug` (the Phase 1 version) with:

```bash
# Resolve the current actor as a slug. With a session_dir arg, resolve the
# pinned identity and git config from that dir (callers may run before
# CLAUDE_SESSION_META_DIR is exported). Without, use env + cwd.
# Precedence: $CS_ACTOR > <meta>/local/identity > git user.email > git user.name > "unknown"
cs_actor_slug() {
    local sdir="${1:-}"
    local meta=""
    if [ -n "$sdir" ]; then
        meta="$sdir/.cs"
    else
        meta="${CLAUDE_SESSION_META_DIR:-}"
    fi
    local raw=""
    if [ -n "${CS_ACTOR:-}" ]; then
        raw="$CS_ACTOR"
    elif [ -n "$meta" ] && [ -f "$meta/local/identity" ]; then
        IFS= read -r raw < "$meta/local/identity"
    else
        local gitdir="${sdir:-.}"
        raw=$(git -C "$gitdir" config user.email 2>/dev/null || true)
        [ -z "$raw" ] && raw=$(git -C "$gitdir" config user.name 2>/dev/null || true)
    fi
    [ -z "$raw" ] && raw="unknown"
    _slugify "$raw"
}
```

- [ ] **Step 4: Implement per-actor `ensure_narrative_file`**

Replace `ensure_narrative_file` (bin/cs:661-683) with:

```bash
ensure_narrative_file() {
    local session_dir="$1"
    local mem_dir="$session_dir/.cs/memory"
    local index="$mem_dir/MEMORY.md"
    mkdir -p "$mem_dir"

    local actor
    actor=$(cs_actor_slug "$session_dir")
    local narrative="$mem_dir/narrative.$actor.md"

    # One-time migration: a pre-per-actor narrative.md becomes this actor's file.
    if [ -f "$mem_dir/narrative.md" ] && [ ! -f "$narrative" ]; then
        mv "$mem_dir/narrative.md" "$narrative"
    fi

    if [ ! -f "$narrative" ]; then
        cat > "$narrative" << EOF
---
name: session-narrative-$actor
description: Session lab-notebook and work-in-progress narrative for $actor. Looser bar than durable memory. Read all narrative.*.md on resume.
type: narrative
---
# Session narrative ($actor)

EOF
    fi

    # Drop the legacy single-narrative index pointer if a migration left it stale.
    if [ -f "$index" ] && grep -q '(narrative\.md)' "$index" 2>/dev/null; then
        sed -i '' '/(narrative\.md)/d' "$index"
    fi

    if [ ! -f "$index" ] || ! grep -q "(narrative\.$actor\.md)" "$index" 2>/dev/null; then
        printf -- '- [Session narrative — %s (lab notebook)](narrative.%s.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' "$actor" "$actor" >> "$index"
    fi
}
```

> `migrate_discoveries_to_narrative` (bin/cs:706) hardcodes `narrative="$meta/memory/narrative.md"` for its append target. After this change, update that line to resolve the actor file too:
> ```bash
>     local narrative="$meta/memory/narrative.$(cs_actor_slug "$session_dir").md"
> ```
> Place it after the `ensure_narrative_file "$session_dir"` call (bin/cs:705) so the file exists.

- [ ] **Step 5: Run to verify they pass**

Run: `bash tests/test_actor_identity.sh`
Expected: PASS (all prior tests + the two new ones).

- [ ] **Step 6: Commit**

```bash
git add bin/cs tests/test_actor_identity.sh
git commit -m "feat: per-actor narrative files (narrative.<actor>.md)"
```

---

## Task 3: Narrative reminder hook globs per-actor files

**Files:**
- Modify: `hooks/narrative-reminder.sh` (the `NARRATIVE_FILE` resolution + existence/mtime checks)
- Test: `tests/test_hooks.sh`

**Interfaces:**
- Produces: the Stop reminder fires based on the **newest** `memory/narrative.*.md` (any actor), and stays silent when none exist.

- [ ] **Step 1: Write the failing test** (add to `tests/test_hooks.sh`; mirror the file's existing setup for `CLAUDE_SESSION_*`)

```bash
test_narrative_reminder_uses_per_actor_glob() {
    # A stale per-actor narrative (old mtime) should still be found by the reminder.
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/memory"
    echo "# Session narrative (alex)" > "$CLAUDE_SESSION_DIR/.cs/memory/narrative.alex.md"
    # Force an old mtime so the reminder considers it stale.
    touch -t 202001010000 "$CLAUDE_SESSION_DIR/.cs/memory/narrative.alex.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>&1)
    assert_output_contains "$output" "narrative" \
        "reminder should fire for a stale per-actor narrative" || return 1
}
```

> Match the existing `test_hooks.sh` env conventions (`HOOKS_DIR`, `CLAUDE_SESSION_DIR`, `CLAUDE_SESSION_META_DIR`, `CLAUDE_SESSION_NAME`). If the file's reminder assertions key on a specific phrase (e.g. "update the session narrative"), assert that exact phrase instead of "narrative".

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_hooks.sh`
Expected: FAIL — the hook checks a single `narrative.md` that does not exist, so it approves silently.

- [ ] **Step 3: Implement**

In `hooks/narrative-reminder.sh`, replace the single-file resolution:

```bash
NARRATIVE_FILE="$META_DIR/memory/narrative.md"
```

with newest-of-glob resolution:

```bash
# Per-actor narratives: consider the most recently modified narrative.*.md.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
for _nf in "$META_DIR"/memory/narrative*.md; do
    [ -f "$_nf" ] || continue
    if [[ "$OSTYPE" == "darwin"* ]]; then
        _m=$(stat -f %m "$_nf" 2>/dev/null || echo 0)
    else
        _m=$(stat -c %Y "$_nf" 2>/dev/null || echo 0)
    fi
    if [ "$_m" -ge "$NARRATIVE_MTIME" ]; then
        NARRATIVE_MTIME="$_m"
        NARRATIVE_FILE="$_nf"
    fi
done
```

Then delete the later per-file `stat` block that recomputes `NARRATIVE_MTIME` (it is now set above) and keep the existing "Nothing to nag about until the narrative file exists" guard as:

```bash
if [ -z "$NARRATIVE_FILE" ]; then
    echo '{"decision": "approve"}'
    exit 0
fi
```

> Read the current hook end-to-end before editing: preserve the cooldown logic, the `NARRATIVE_AGE` computation (now using the `NARRATIVE_MTIME` set above), and the reminder JSON. Only the file-resolution and the now-redundant second `stat` block change.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_hooks.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/narrative-reminder.sh tests/test_hooks.sh
git commit -m "feat: narrative reminder tracks per-actor narrative files"
```

---

## Task 4: Autosave log-entry recognizes per-actor narratives

**Files:**
- Modify: `hooks/autosave-commits.sh` (the narrative `case` at lines ~36-56)
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Produces: editing any `memory/narrative.*.md` still extracts a human log entry (last heading/bullet) for the autosave commit message.

- [ ] **Step 1: Write the failing test** (add to `tests/test_shadow_ref.sh`)

```bash
test_autosave_logs_per_actor_narrative_edit() {
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/memory"
    local nf="$CLAUDE_SESSION_DIR/.cs/memory/narrative.alex.md"
    printf '%s\n' '# Session narrative (alex)' '' '## A New Finding' 'detail' > "$nf"

    local output
    output=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$nf"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh" 2>&1)
    sleep 1

    # The autosave commit subject should reflect the narrative heading, not a generic message.
    local subj
    subj=$(git -C "$CLAUDE_SESSION_DIR" log --format=%s -1 refs/cs/auto 2>/dev/null || echo "")
    assert_output_contains "$subj" "A New Finding" \
        "autosave should log the per-actor narrative heading" || return 1
}
```

Add `run_test test_autosave_logs_per_actor_narrative_edit` to the runner.

> If the autosave commit-subject format differs (prefix/suffix), assert the substring `A New Finding` only — the point is that a `narrative.alex.md` edit is recognized as a narrative edit.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_shadow_ref.sh`
Expected: FAIL — the `case` only matches the literal `narrative.md`, so a per-actor file is treated as a generic edit.

- [ ] **Step 3: Implement**

In `hooks/autosave-commits.sh`, change the `case` pattern:

```bash
    "$META_DIR/memory/narrative.md")
```

to a glob that matches both legacy and per-actor names:

```bash
    "$META_DIR"/memory/narrative*.md)
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_shadow_ref.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/autosave-commits.sh tests/test_shadow_ref.sh
git commit -m "feat: autosave recognizes per-actor narrative edits"
```

---

## Task 5: Read-paths surface all per-actor narratives

**Files:**
- Modify: `bin/cs` `write_session_claude_md` template (the "READ THESE ON RESUME" list + the trailing Note, bin/cs:~750-757), and the checkpoint narrative snapshot (bin/cs:1453-1458)
- Test: `tests/test_checkpoint.sh`

**Interfaces:**
- Produces: a checkpoint includes a `## Narrative snapshot` section for **every** `memory/narrative*.md`; the session `CLAUDE.md` instructs reading all `narrative.*.md` on resume.

- [ ] **Step 1: Write the failing test** (add to `tests/test_checkpoint.sh`; mirror its session setup)

```bash
test_checkpoint_includes_all_actor_narratives() {
    # Two actors' narratives both appear in the checkpoint snapshot.
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory"
    printf '%s\n' '# narrative (alex)' 'ALEX_MARKER' > "$CLAUDE_SESSION_META_DIR/memory/narrative.alex.md"
    printf '%s\n' '# narrative (bob)'  'BOB_MARKER'  > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"

    "$CS_BIN" -checkpoint "two actors" >/dev/null 2>&1
    local cp
    cp=$(ls -t "$CLAUDE_SESSION_META_DIR/checkpoints/"*.md 2>/dev/null | head -1)
    assert_file_contains "$cp" "ALEX_MARKER" "checkpoint should include alex's narrative" || return 1
    assert_file_contains "$cp" "BOB_MARKER" "checkpoint should include bob's narrative" || return 1
}
```

> Align the invocation with how `test_checkpoint.sh` already drives `-checkpoint` (env vars set, session created). Reuse the file's existing setup helpers rather than re-deriving them.

Add `run_test test_checkpoint_includes_all_actor_narratives` to the runner.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_checkpoint.sh`
Expected: FAIL — only a single `narrative.md` is catted; the per-actor files are missed.

- [ ] **Step 3: Implement the checkpoint snapshot loop**

Replace the checkpoint narrative block (bin/cs:1453-1458):

```bash
        if [ -f "$meta_dir/memory/narrative.md" ]; then
            echo "## Narrative snapshot"
            echo ""
            cat "$meta_dir/memory/narrative.md"
            echo ""
        fi
```

with a loop over all narratives (covers legacy `narrative.md` and per-actor files):

```bash
        local _nf
        for _nf in "$meta_dir"/memory/narrative*.md; do
            [ -f "$_nf" ] || continue
            echo "## Narrative snapshot ($(basename "$_nf"))"
            echo ""
            cat "$_nf"
            echo ""
        done
```

- [ ] **Step 4: Update the session CLAUDE.md template wording**

In `write_session_claude_md` (bin/cs:~750), change the resume list item and Note. Find:

```
3. **.cs/memory/narrative.md** - Session lab notebook: findings, in-progress state, observations
```
Replace with:
```
3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates'): findings, in-progress state, observations
```

Find the Note paragraph mentioning `narrative.md` (bin/cs:755-757) and reword to:

```
Note: narratives are per-actor (narrative.<actor>.md). Append only to your own
(run `cs -whoami` for your actor); read all narrative.*.md on resume to restore
the working narrative and see teammates' in-progress findings.
```

> Also update the prose in the repo's own `CLAUDE.md` (project doc) and `README.md` if they reference a single `narrative.md` resume read — documentation parity per the project rule. These are doc-only and need no test.

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test_checkpoint.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/cs tests/test_checkpoint.sh README.md CLAUDE.md
git commit -m "feat: checkpoint and resume surface all per-actor narratives"
```

---

## Task 6: `.gitattributes merge=ours` for the memory index

**Files:**
- Modify: `bin/cs` — add `setup_memory_merge_driver`; call from `adopt_session` (both git branches), the new-session git-init block (bin/cs:~3084), and `migrate_session`
- Test: `tests/test_adopt.sh`

**Interfaces:**
- Produces: in any session git repo, `.gitattributes` contains `.cs/memory/MEMORY.md merge=ours` and `git config merge.ours.driver` is `true`, so a merge never conflicts on the hand-maintained index.

- [ ] **Step 1: Write the failing test** (add to `tests/test_adopt.sh`)

```bash
test_adopt_sets_memory_merge_driver() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A)
    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitattributes" "MEMORY.md merge=ours" \
        ".gitattributes should mark MEMORY.md merge=ours" || return 1
    local drv
    drv=$(git -C "$project_dir" config merge.ours.driver 2>/dev/null || echo "")
    assert_eq "true" "$drv" "merge.ours.driver should be configured" || return 1
}
```

Add `run_test test_adopt_sets_memory_merge_driver` to the runner.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_adopt.sh`
Expected: FAIL — no `.gitattributes` entry, no driver config.

- [ ] **Step 3: Implement the helper**

Add near `cs_assert_local_untracked` (bin/cs:~990):

```bash
# Configure a conflict-free merge for the Claude-Code-maintained memory index.
# The index is hand-maintained, so two branches editing it would conflict;
# merge=ours keeps the local copy (new entries are re-added by normal use).
setup_memory_merge_driver() {
    local dir="$1"
    [ -d "$dir/.git" ] || return 0
    git -C "$dir" config merge.ours.driver true 2>/dev/null || true
    local ga="$dir/.gitattributes"
    if ! grep -q 'MEMORY\.md merge=ours' "$ga" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$ga"
    fi
}
```

- [ ] **Step 4: Wire the calls**

In `adopt_session`, the existing-repo branch — immediately before its `git add .cs/ CLAUDE.md .gitignore` (after the Phase 1 `cs_assert_local_untracked` call) add:

```bash
            setup_memory_merge_driver "$target_dir"
```

In `adopt_session`, the git-init branch (where it runs `create_session_gitignore` + `git init`) add, before its `git add -A`:

```bash
            setup_memory_merge_driver "$target_dir"
```

In the new-session git-init block (bin/cs:~3084, before `git add -A`):

```bash
            setup_memory_merge_driver "$session_dir"
```

In `migrate_session` (after the Phase 1 `cs_assert_local_untracked "$session_dir"` line), to backfill existing sessions:

```bash
    setup_memory_merge_driver "$session_dir"
```

> `.gitattributes` is staged by the allowlist add in adopt (`git add … .gitignore` → extend to include `.gitattributes`) or by the init-path `git add -A`. For the adopt allowlist, change `git add .cs/ CLAUDE.md .gitignore` to `git add .cs/ CLAUDE.md .gitignore .gitattributes` in both adopt commit sites so the attribute file is committed.

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test_adopt.sh`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

```bash
for t in tests/test_*.sh; do [ "$t" = tests/test_lib.sh ] && continue; [ "$t" = tests/test_install.sh ] && continue; r=$(bash "$t" < /dev/null 2>&1 | grep "Results:" | tail -1); printf '%-28s %s\n' "$(basename "$t")" "$r"; done
```
Expected: every file all-pass. Pay attention to `test_actor_identity`, `test_adopt`, `test_hooks`, `test_shadow_ref`, `test_checkpoint`, `test_search`.

- [ ] **Step 7: Commit**

```bash
git add bin/cs tests/test_adopt.sh
git commit -m "feat: merge=ours for the memory index to avoid index merge conflicts"
```

---

## Self-Review Checklist

- [ ] `cs_actor_slug` with no arg behaves exactly as Phase 1 (cmd_whoami unaffected); with an arg resolves identity + git from that dir.
- [ ] New session → only `narrative.<slug>.md` (no generic `narrative.md`); legacy `narrative.md` migrates content + strips stale `(narrative.md)` index pointer.
- [ ] `migrate_discoveries_to_narrative` appends to the per-actor file, not `narrative.md`.
- [ ] Reminder + autosave hooks both glob `narrative*.md`; reminder still respects cooldown + age; no second `stat` recompute left dangling.
- [ ] Checkpoint snapshots every narrative; resume wording says read all `narrative.*.md`.
- [ ] `.gitattributes` committed (allowlist add extended); `merge.ours.driver true` set on adopt + init + resume.
- [ ] No `author:` frontmatter, no `MEMORY.md` regeneration (Claude Code owns those).
- [ ] bash 3.2: `for`-glob with `[ -f ] || continue`, `sed -i ''`, `git -C`; no arrays / no `${x^^}`.

---

## Out of scope (carried to Phase 3)

- On-resume digest ("Since your last session: …") via per-actor `watermark` + `git log`.
- `cs -who` contribution feed from `git log .cs/memory .cs/memory/narrative.*.md`.
- These read git history — memory attribution needs nothing more than what Phase 2 leaves in place.
