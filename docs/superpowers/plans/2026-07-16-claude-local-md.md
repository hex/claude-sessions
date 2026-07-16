# CLAUDE.local.md Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cs writes its Session Documentation Protocol to `CLAUDE.local.md` (machine-local, gitignored) and lazily migrates existing sessions' cs-managed sections out of `CLAUDE.md`, never touching user content again.

**Architecture:** A pure extraction function (`migrate_claude_md_to_local`) plus retargets of the create path and migrate Phases 5/9/10 to a `protocol_file` that prefers `CLAUDE.local.md`; `.gitignore` machinery gains the entry; worktree bootstrap writes the file (never a project `.gitignore`); the session-start hook text follows. Spec: `docs/superpowers/specs/2026-07-16-claude-local-md-design.md`.

**Tech Stack:** bash 3.2 + BSD, existing migrate/test machinery, ./build.sh.

## Global Constraints

- `bin/cs` is GENERATED from `lib/` by `./build.sh`: build BEFORE tests, commit regenerated `bin/cs` in the SAME commit as fragments.
- bash 3.2 + BSD floor; hooks standalone; `set -euo pipefail` inside `bin/cs` — new conditionals use if-form, never a bare `&&` tail ending a function.
- The extraction is a PURE function of file content (no timestamps, no local state) — two clones migrating the same tracked `CLAUDE.md` must produce byte-identical results.
- User content is sacred: nothing outside a cs sentinel line and its trailing content may be modified or lost; a `.cs/`-referencing file with NO sentinel is left entirely alone; `CLAUDE.md` is deleted (via `mv`) only when it contains nothing of the user's.
- Existing tests in `tests/test_migrate_claude_md.sh` are UPDATED to the new contract (their protections carry over), never deleted.
- Worktree bootstrap writes the protocol file only — it must NEVER modify a project repo's `.gitignore` (ignored-mode worktrees check out project repos).
- Template text and managed-section semantics (three sentinels, wrap-cues tombstone) are unchanged — only the target file moves.
- Test discipline: every assert `|| return 1`; `report_results` last; suites run as `/bin/bash tests/<suite>.sh`.

---

### Task 1: Extraction, retargets, gitignore, tests

**Files:**
- Modify: `lib/35-claudemd.sh` (`write_session_claude_md` ~line 246; new `migrate_claude_md_to_local` after it)
- Modify: `lib/45-migrate.sh` (new phase call + Phase 5 replacement ~line 231; `protocol_file` + Phase 9 retarget ~line 365; Phase 10 retarget just below)
- Modify: `lib/85-adopt-uninstall.sh` (`create_session_gitignore` heredoc; `ensure_cs_gitignore_entries` ENTRIES list)
- Modify: `bin/cs` (regenerated)
- Test: `tests/test_migrate_claude_md.sh`

**Interfaces:**
- Consumes: `_emit_session_claude_md` (stdout template, unchanged), `warn`, existing Phase 9/10 blocks, `create_test_session NAME` + `$CS_BIN` launch idiom in the test file.
- Produces: `migrate_claude_md_to_local SESSION_DIR` (moves cs content, cases per spec); `write_session_claude_md SESSION_DIR` now writing `CLAUDE.local.md`; the `protocol_file` convention (Phase 9/10 operate on `CLAUDE.local.md` when present, else legacy `CLAUDE.md`). Task 2 reuses `write_session_claude_md` verbatim.

- [ ] **Step 1: Update the two existing tests and add the new ones**

In `tests/test_migrate_claude_md.sh`, replace the two existing test function bodies with the new-contract versions:

```bash
# A resume (existing dir → migrate_session) must not clobber user content in
# CLAUDE.md that happens not to mention '.cs/'.
test_migrate_preserves_user_claude_md() {
    local dir
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nDO-NOT-DELETE-THIS-LINE\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" "DO-NOT-DELETE-THIS-LINE" \
        "migrate must preserve the user's CLAUDE.md content" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" \
        "the user's CLAUDE.md must no longer gain the protocol" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "the protocol lands in CLAUDE.local.md" || return 1
}

# Idempotent: a second resume must not append the protocol twice.
test_migrate_claude_md_idempotent() {
    local dir count
    dir=$(create_test_session "proj")
    printf '# My Project Rules\n\nkeep-me\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "proj" < /dev/null > /dev/null 2>&1 || true
    count=$(grep -c 'cs:session-protocol' "$dir/CLAUDE.local.md")
    assert_eq "1" "$count" "protocol sentinel must appear exactly once after two resumes" || return 1
    assert_file_contains "$dir/CLAUDE.md" "keep-me" "user file untouched across resumes" || return 1
}
```

Add these new tests after them (registrations after the existing two `run_test` lines, `report_results` last):

```bash
test_create_path_writes_local_md() {
    local dir="$CS_SESSIONS_ROOT/fresh"
    "$CS_BIN" "fresh" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "new session gets CLAUDE.local.md" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "new session gets no CLAUDE.md" || return 1
    assert_file_contains "$dir/.gitignore" "CLAUDE.local.md" \
        "session .gitignore covers the local file" || return 1
}

test_pure_cs_claude_md_moves_wholesale() {
    local dir
    dir=$(create_test_session "pure")
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nSee .cs/ for metadata.\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "pure" < /dev/null > /dev/null 2>&1 || true
    assert_file_not_exists "$dir/CLAUDE.md" "pure cs file is removed after the move" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" \
        "content moved to CLAUDE.local.md" || return 1
}

test_mixed_claude_md_splits_at_first_sentinel() {
    local dir
    dir=$(create_test_session "mixed")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nprotocol body .cs/\n\n<!-- cs:memory-note -->\nnote body\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "mixed" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" "USER-KEEP" "user head stays" || return 1
    assert_file_not_contains "$dir/CLAUDE.md" "cs:session-protocol" "cs sections left CLAUDE.md" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:session-protocol" "protocol in local file" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" "memory note rode along" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "USER-KEEP" "user head did not ride along" || return 1
}

test_pre_sentinel_template_left_alone() {
    local dir
    dir=$(create_test_session "presentinel")
    printf '# Session Documentation Protocol\n\nSession metadata lives in the .cs/ directory.\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "presentinel" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.md" ".cs/ directory" "pre-sentinel file untouched" || return 1
    assert_file_not_exists "$dir/CLAUDE.local.md" "no second protocol file for pre-sentinel sessions" || return 1
}

test_migration_idempotent_byte_for_byte() {
    local dir
    dir=$(create_test_session "idem")
    printf '# User Head\n\nUSER-KEEP\n\n<!-- cs:session-protocol -->\nprotocol .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cp "$dir/CLAUDE.md" "$dir/.first-md" && cp "$dir/CLAUDE.local.md" "$dir/.first-local"
    "$CS_BIN" "idem" < /dev/null > /dev/null 2>&1 || true
    cmp -s "$dir/CLAUDE.md" "$dir/.first-md" || { echo "  FAIL: CLAUDE.md changed on second run"; return 1; }
    cmp -s "$dir/CLAUDE.local.md" "$dir/.first-local" || { echo "  FAIL: CLAUDE.local.md changed on second run"; return 1; }
}

test_memory_note_lands_in_local_md() {
    local dir
    dir=$(create_test_session "note")
    printf '<!-- cs:session-protocol -->\nprotocol only, no note, references .cs/\n' > "$dir/CLAUDE.md"
    "$CS_BIN" "note" < /dev/null > /dev/null 2>&1 || true
    assert_file_contains "$dir/CLAUDE.local.md" "cs:memory-note" \
        "Phase 9 adds the note to the local file" || return 1
    assert_file_not_exists "$dir/CLAUDE.md" "CLAUDE.md not recreated by Phase 9" || return 1
}

test_gitignore_backfill_idempotent() {
    local dir
    dir=$(create_test_session "gi")
    printf '*.tmp\n' > "$dir/.gitignore"
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    "$CS_BIN" "gi" < /dev/null > /dev/null 2>&1 || true
    local n
    n=$(grep -c 'CLAUDE.local.md' "$dir/.gitignore")
    assert_eq "1" "$n" "gitignore entry added exactly once" || return 1
}
```

Registrations to add after the existing two:

```bash
run_test test_create_path_writes_local_md
run_test test_pure_cs_claude_md_moves_wholesale
run_test test_mixed_claude_md_splits_at_first_sentinel
run_test test_pre_sentinel_template_left_alone
run_test test_migration_idempotent_byte_for_byte
run_test test_memory_note_lands_in_local_md
run_test test_gitignore_backfill_idempotent
```

- [ ] **Step 2: Run the suite to verify the RED pattern**

Run: `/bin/bash tests/test_migrate_claude_md.sh`
Expected: ALL nine tests FAIL (the two updated ones now expect the new contract; the seven new ones have no implementation). Confirm and record the exact pattern.

- [ ] **Step 3: Implement**

Edit 1 — `lib/35-claudemd.sh`. Replace:

```bash
# Write the session CLAUDE.md template to the given directory (create path).
write_session_claude_md() {
    local session_dir="$1"
    _emit_session_claude_md > "$session_dir/CLAUDE.md"
}
```

with:

```bash
# Write the session protocol template to the given directory (create path).
# Targets CLAUDE.local.md: machine-local, gitignored, regenerated by cs, so
# a user-owned CLAUDE.md is never touched.
write_session_claude_md() {
    local session_dir="$1"
    _emit_session_claude_md > "$session_dir/CLAUDE.local.md"
}

# Move cs-managed content from a session's CLAUDE.md into CLAUDE.local.md.
# A pure function of the file's content (no timestamps, no local state), so
# two clones migrating the same tracked file produce byte-identical edits.
# Cases:
#   - CLAUDE.md absent, sentinel-free, or CLAUDE.local.md already carries
#     the protocol: no-op.
#   - The first cs sentinel is on line 1, or nothing but whitespace precedes
#     it (nothing of the user's): the whole file moves; CLAUDE.md is removed.
#   - User head above the first sentinel: head stays in CLAUDE.md,
#     sentinel-to-EOF moves; both files kept.
migrate_claude_md_to_local() {
    local session_dir="$1"
    local claude_md="$session_dir/CLAUDE.md"
    local local_md="$session_dir/CLAUDE.local.md"
    if [ ! -f "$claude_md" ] || ! grep -q '<!-- cs:' "$claude_md"; then
        return 0
    fi
    if [ -f "$local_md" ] && grep -q 'cs:session-protocol' "$local_md"; then
        return 0
    fi
    local split_line
    split_line=$(grep -n '<!-- cs:' "$claude_md" | head -1 | cut -d: -f1)
    if [ "$split_line" -le 1 ] \
        || ! sed -n "1,$((split_line - 1))p" "$claude_md" | grep -q '[^[:space:]]'; then
        mv "$claude_md" "$local_md"
        warn "Moved the cs session protocol from CLAUDE.md to CLAUDE.local.md"
        return 0
    fi
    sed -n "${split_line},\$p" "$claude_md" > "$local_md"
    sed -n "1,$((split_line - 1))p" "$claude_md" > "$claude_md.tmp" \
        && mv "$claude_md.tmp" "$claude_md"
    warn "Moved cs-managed sections from CLAUDE.md to CLAUDE.local.md; your own content stays in CLAUDE.md"
    return 0
}
```

Edit 2 — `lib/45-migrate.sh`. Replace the Phase 5 block:

```bash
    # Phase 5: ensure the cs session protocol is present in CLAUDE.md. Append it
    # (never overwrite) so a user-authored or project CLAUDE.md is preserved; the
    # sentinel keeps it idempotent, and a file that already references .cs/ is a
    # prior cs template that needs nothing.
    local claude_md="$session_dir/CLAUDE.md"
    if [ -f "$claude_md" ] \
        && ! grep -q 'cs:session-protocol' "$claude_md" \
        && ! grep -q '\.cs/' "$claude_md"; then
        printf '\n' >> "$claude_md"
        _emit_session_claude_md >> "$claude_md"
        warn "Appended the cs session protocol to your existing CLAUDE.md"
    fi
```

with:

```bash
    # Phase 5: move cs-managed sections out of CLAUDE.md, then ensure the
    # protocol is present in CLAUDE.local.md (machine-local, gitignored). A
    # sentinel-free CLAUDE.md that references .cs/ is a pre-sentinel-era cs
    # template: that session stays entirely on CLAUDE.md — extraction cannot
    # be surgical without sentinels, and a second protocol file would
    # duplicate instructions.
    migrate_claude_md_to_local "$session_dir"
    local claude_md="$session_dir/CLAUDE.md"
    local claude_local="$session_dir/CLAUDE.local.md"
    if ! { [ -f "$claude_local" ] && grep -q 'cs:session-protocol' "$claude_local"; } \
        && ! { [ -f "$claude_md" ] && grep -q '\.cs/' "$claude_md"; }; then
        if [ -f "$claude_local" ]; then
            printf '\n' >> "$claude_local"
            _emit_session_claude_md >> "$claude_local"
            warn "Appended the cs session protocol to your existing CLAUDE.local.md"
        else
            write_session_claude_md "$session_dir"
        fi
    fi
```

Edit 3 — `lib/45-migrate.sh`, directly above the Phase 9 comment block, insert:

```bash
    # Phases 9 and 10 manage sections in the protocol file: CLAUDE.local.md
    # when it exists, else the legacy CLAUDE.md (pre-sentinel-era sessions
    # stay entirely there).
    local protocol_file="$session_dir/CLAUDE.local.md"
    if [ ! -f "$protocol_file" ]; then
        protocol_file="$session_dir/CLAUDE.md"
    fi
```

Then in Phase 9, replace `local claude_md_p9="$session_dir/CLAUDE.md"` with `local claude_md_p9="$protocol_file"`, and its two warn strings `"... to CLAUDE.md"` / mentions of CLAUDE.md become `"... to the session protocol file"`. In Phase 10 (the wrap-cues block that follows), point its CLAUDE.md path variable at `"$protocol_file"` the same way and update its warn text likewise; read the block and keep every other line intact — quote the changed lines in your report.

Edit 4 — `lib/85-adopt-uninstall.sh`. In the `create_session_gitignore` heredoc, after the block:

```
# Claude Code local settings (recreated by cs on each machine)
.claude/settings.local.json
```

insert:

```
# cs session protocol (machine-local; regenerated by cs on each machine)
CLAUDE.local.md
```

And in `ensure_cs_gitignore_entries`, the ENTRIES heredoc gains the line `CLAUDE.local.md` (after `.claude/settings.local.json`).

- [ ] **Step 4: Build and run the suites**

Run: `./build.sh && git status --porcelain` — `bin/cs` modified, plus THIS REPO's own `CLAUDE.md` is NOT yet affected (migration only runs at session launch, not at build) — confirm no unexpected files.
Run: `/bin/bash tests/test_migrate_claude_md.sh` — expected 9/9 PASS.
Run: `/bin/bash tests/test_commands.sh` — expected PASS (launch path exercised).

- [ ] **Step 5: Commit**

```bash
git add lib/35-claudemd.sh lib/45-migrate.sh lib/85-adopt-uninstall.sh bin/cs tests/test_migrate_claude_md.sh
git commit -m "feat: session protocol moves to CLAUDE.local.md with lazy extraction from CLAUDE.md"
```

---

### Task 2: Worktree bootstrap

**Files:**
- Modify: `lib/30-worktree.sh` (`bootstrap_worktree_meta`, ~line 26)
- Modify: `bin/cs` (regenerated)
- Test: `tests/test_migrate_claude_md.sh` (one case) — the worktree machinery's own suite (`tests/test_worktrees.sh`) must stay green.

**Interfaces:**
- Consumes: `write_session_claude_md SESSION_DIR` from Task 1 (writes `CLAUDE.local.md`).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_migrate_claude_md.sh` (register after the Task 1 registrations):

```bash
test_worktree_bootstrap_writes_local_md() {
    local dir
    dir=$(create_test_session "wtbase")
    ( cd "$dir" && git init -q . 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null ) || return 1
    "$CS_BIN" "wtbase@task1" < /dev/null > /dev/null 2>&1 || true
    if [ -d "$CS_SESSIONS_ROOT/wtbase@task1" ]; then
        assert_file_contains "$CS_SESSIONS_ROOT/wtbase@task1/CLAUDE.local.md" "cs:session-protocol" \
            "worktree session gets its own protocol file" || return 1
    else
        echo "  FAIL: worktree session was not created"
        return 1
    fi
}
```

```bash
run_test test_worktree_bootstrap_writes_local_md
```

- [ ] **Step 2: Run to verify it fails**

Run: `/bin/bash tests/test_migrate_claude_md.sh`
Expected: only the new test FAILS (either no `CLAUDE.local.md` in the worktree, or the worktree creation path needs the call). If worktree creation itself fails in the harness for an unrelated reason, report NEEDS_CONTEXT with the output instead of forcing the fixture.

- [ ] **Step 3: Implement**

In `lib/30-worktree.sh`, `bootstrap_worktree_meta()`, after the `ensure_narrative_file "$wt_dir"` line, add:

```bash
    # The protocol file is gitignored, so a fresh worktree never inherits
    # it; write this worktree's own copy. Never touch a project repo's
    # .gitignore here — ignored-mode worktrees check out project repos.
    write_session_claude_md "$wt_dir"
```

If the failing test shows tracked-mode worktrees (repos that track .cs/) skip `bootstrap_worktree_meta`, add the same guarded call to the tracked-mode branch of the worktree create path — quote the exact insertion in your report.

- [ ] **Step 4: Build, run, commit**

Run: `./build.sh` then `/bin/bash tests/test_migrate_claude_md.sh` (10/10) and `/bin/bash tests/test_worktrees.sh` (all green).

```bash
git add lib/30-worktree.sh bin/cs tests/test_migrate_claude_md.sh
git commit -m "feat: worktree bootstrap writes the session protocol file"
```

---

### Task 3: Hook text and docs

**Files:**
- Modify: `hooks/session-start.sh` (~lines 138, 140)
- Modify: `README.md`, `docs/session-layout.md`

**Interfaces:**
- Consumes: the shipped behavior (protocol lives in `CLAUDE.local.md`).
- Produces: nothing downstream.

- [ ] **Step 1: Hook text**

In `hooks/session-start.sh`, both context strings change:
- `See CLAUDE.md, Secure Secrets Handling.` → `See CLAUDE.local.md, Secure Secrets Handling.`
- `See CLAUDE.md in the session directory for complete documentation protocol.` → `See CLAUDE.local.md in the session directory for complete documentation protocol.`

- [ ] **Step 2: Docs**

In `README.md` and `docs/session-layout.md`: find every session-layout reference to the session's `CLAUDE.md` (rg `CLAUDE.md` in both files; project-CLAUDE.md mentions unrelated to the session template stay) and retarget the session-template ones to `CLAUDE.local.md`, adding one sentence where the layout is described: it is machine-local and gitignored; cs regenerates it on each machine; a user-owned `CLAUDE.md` is never touched. Quote every changed line in your report.

- [ ] **Step 3: Verify and commit**

Run: `/bin/bash tests/test_migrate_claude_md.sh` (10/10 — docs only) and `/bin/bash tests/run_all.sh` (all suites).

```bash
git add hooks/session-start.sh README.md docs/session-layout.md
git commit -m "docs: session protocol lives in CLAUDE.local.md"
```
