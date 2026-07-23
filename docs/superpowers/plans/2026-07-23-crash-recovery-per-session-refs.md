# Per-conversation autosave refs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single shared `refs/worktree/cs/auto` autosave ref with per-conversation `refs/worktree/cs/session/<uuid>` refs, so concurrent conversations never read, write, or delete each other's autosave state.

**Architecture:** Three hooks change. `autosave-commits.sh` writes to the current conversation's own ref (keyed on the hook input's `session_id`). `session-start.sh` recovers only the current conversation's ref, renames it across a context-fork UUID rebind, claims any legacy shared ref once via a compare-and-swap delete, and garbage-collects foreign refs older than 14 days. `session-end.sh` deletes only the current conversation's ref. The PR #5 base-HEAD restore guard is preserved verbatim on the per-conversation ref.

**Tech Stack:** POSIX-ish bash (floor: macOS `/bin/bash` 3.2 + BSD userland), git plumbing (`update-ref`, `commit-tree`, `log`), `jq`. Hooks are standalone scripts; `bin/cs` is generated from `lib/` and is NOT touched here.

## Global Constraints

- Shell floor: bash 3.2 + BSD userland. No bash-4 features (`local -A`, `${var,,}`, `printf '%(...)T'`), no GNU-only `sed`/`awk`/`stat`/`date` flags.
- Hooks run under `set -euo pipefail`. Every command that may fail benignly must be guarded (`|| true`, `2>/dev/null`, or an `if`).
- The autosave ref namespace is `refs/worktree/cs/session/<uuid>` (per-worktree, per-conversation). Never reuse `refs/worktree/cs/auto/<uuid>` — git's directory/file conflict with the legacy `refs/worktree/cs/auto` ref forbids it.
- `<uuid>` is the conversation UUID from the hook input's `.session_id`, validated against `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$` before use as a ref path component.
- The PR #5 `cs-base:` commit trailer and its restore guard stay intact; this plan changes only which ref name is read/written.
- Tests run via `bash tests/test_shadow_ref.sh` (and the aggregate `bash tests/run_all.sh`). The `run_test` harness disables errexit, so every assert needs `|| return 1`.
- GC window: 14 days, measured from the ref tip's committer date (`git log -1 --format=%ct`).

---

## File Structure

- `hooks/autosave-commits.sh` — MODIFY: key the ref on `session_id`.
- `hooks/session-start.sh` — MODIFY: recover own ref; rebind rename; legacy CAS-claim; GC.
- `hooks/session-end.sh` — MODIFY: delete own ref only.
- `tests/test_shadow_ref.sh` — MODIFY: per-conversation ref tests (incl. the incident regression).
- `docs/hooks.md` — MODIFY: document the per-conversation ref model.

---

## Task 1: Autosave writes to the conversation's own ref

**Files:**
- Modify: `hooks/autosave-commits.sh`
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Produces: autosave commits at `refs/worktree/cs/session/<uuid>` carrying the `cs-base: <HEAD>` trailer, where `<uuid>` is the hook input's `.session_id`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_shadow_ref.sh` (before the `# session-end.sh` divider), and register it with a `run_test` line after `test_autosave_stamps_base_head`:

```bash
test_autosave_writes_per_conversation_ref() {
    local uuid="11111111-1111-1111-1111-111111111111"
    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"session_id":"'"$uuid"'","tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$uuid" >/dev/null 2>&1; then
        echo "  FAIL: autosave should write refs/worktree/cs/session/<uuid>"; return 1
    fi
    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: autosave must no longer write the shared refs/worktree/cs/auto"; return 1
    fi
    local msg
    msg=$(git -C "$CLAUDE_SESSION_DIR" log -1 --format=%B "refs/worktree/cs/session/$uuid" 2>/dev/null || true)
    case "$msg" in *"cs-base: "*) : ;; *) echo "  FAIL: per-conversation autosave must keep the cs-base trailer"; return 1 ;; esac
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 per_conversation_ref`
Expected: FAIL — the ref `refs/worktree/cs/session/<uuid>` does not exist (autosave still writes `refs/worktree/cs/auto`).

- [ ] **Step 3: Write minimal implementation**

In `hooks/autosave-commits.sh`, after the existing `FILE_PATH=$(...)` line, add the session id read and a UUID guard:

```bash
SESSION_UUID=$(echo "$INPUT" | jq -r '.session_id // empty')
_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[[ "$SESSION_UUID" =~ $_UUID_RE ]] || exit 0
SESSION_REF="refs/worktree/cs/session/$SESSION_UUID"
```

Then, inside `autosave_to_shadow_ref()`, replace every `refs/worktree/cs/auto` with `$SESSION_REF`, and delete the legacy `refs/cs/auto` cleanup block (migration now owns legacy refs). The parent read and both `update-ref` become:

```bash
    parent=$(git rev-parse -q --verify "$SESSION_REF" 2>/dev/null || true)
    if [ -n "$parent" ]; then
        commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" -p "$parent" 2>/dev/null) || return 0
    else
        commit=$(printf '%s\n' "$msg" | git commit-tree "$tree" 2>/dev/null) || return 0
    fi

    git update-ref "$SESSION_REF" "$commit" 2>/dev/null || return 0
```

(Remove the `if [ -z "$parent" ]; then git update-ref -d refs/cs/auto ...` block entirely.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: the new test passes. Note: the pre-existing `test_autosave_*` tests that assert on `refs/worktree/cs/auto` will now FAIL — that is expected and fixed in Step 5.

- [ ] **Step 5: Update the pre-existing autosave tests to the new ref name**

In `tests/test_shadow_ref.sh`, the helpers `test_autosave_creates_shadow_ref`, `test_autosave_chains_multiple_saves`, `test_autosave_stamps_base_head`, `test_autosave_refs_isolated_per_worktree`, `test_autosave_works_in_linked_worktree`, and `test_autosave_logs_per_actor_narrative_edit` pipe autosave events without a `session_id` and assert on `refs/worktree/cs/auto`. For each: add `"session_id":"<a fixed valid uuid>",` to the JSON, and replace `refs/worktree/cs/auto` with `refs/worktree/cs/session/<that uuid>`. Use uuid `22222222-2222-2222-2222-222222222222` for the base-checkout tests and `33333333-3333-3333-3333-333333333333` for the worktree test.

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add hooks/autosave-commits.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): autosave to per-conversation session ref

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 2: Recovery reads only the current conversation's ref

**Files:**
- Modify: `hooks/session-start.sh:109-145` (the shadow-ref block)
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Consumes: `refs/worktree/cs/session/<uuid>` from Task 1.
- Produces: crash-recovery context injected only when the CURRENT conversation's own ref exists and differs from HEAD; other conversations' refs are never read.

- [ ] **Step 1: Write the failing test** (the incident regression)

Add to `tests/test_shadow_ref.sh` and register after `test_recovery_detects_crash_and_injects_context`:

```bash
# The 2026-07-22 incident, reproduced: a conversation must NOT read a SIBLING
# conversation's autosave ref as its own crash.
test_recovery_ignores_sibling_conversation_ref() {
    local sib="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local me="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    local head
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "sibling wip" > sib.txt
        TEMP_INDEX=$(mktemp); cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add sib.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree); rm -f "$TEMP_INDEX"
        commit=$(printf 'autosave\n\ncs-base: %s\n' "$head" | git commit-tree "$tree")
        git update-ref "refs/worktree/cs/session/$sib" "$commit"
        rm -f sib.txt
    )

    local output
    output=$(echo '{"session_id":"'"$me"'","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: must NOT surface a crash for a sibling conversation's ref"; return 1
    fi
    # The sibling's ref must be left untouched (not deleted, not restored).
    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$sib" >/dev/null 2>&1; then
        echo "  FAIL: a sibling's ref must not be deleted"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$sib" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 ignores_sibling`
Expected: FAIL — current recovery reads `refs/worktree/cs/auto`/`refs/cs/auto`, finds none, so today it would actually PASS by accident. To force a real RED, the recovery must be looking at a *shared* location; since Task 1 already moved writes to session refs, recovery currently finds nothing and the test passes vacuously. **Therefore this test is paired with a positive test (Step 3) that MUST fail first.** Add the positive test and run both:

```bash
test_recovery_detects_own_conversation_crash() {
    local me="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local head
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "my wip" > mine.txt
        TEMP_INDEX=$(mktemp); cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add mine.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree); rm -f "$TEMP_INDEX"
        commit=$(printf 'autosave\n\ncs-base: %s\n' "$head" | git commit-tree "$tree")
        git update-ref "refs/worktree/cs/session/$me" "$commit"
        rm -f mine.txt
    )
    local output
    output=$(echo '{"session_id":"'"$me"'","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: must surface a crash for the conversation's OWN ref"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$me" 2>/dev/null || true
}
```

Register both with `run_test` lines. Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -E 'own_conversation|ignores_sibling'`
Expected: `test_recovery_detects_own_conversation_crash` FAILS (recovery still reads the old shared ref, not the session ref); `test_recovery_ignores_sibling_conversation_ref` passes.

- [ ] **Step 3: Write minimal implementation**

In `hooks/session-start.sh`, replace the `SHADOW_REF` selection block (currently choosing `refs/worktree/cs/auto` then `refs/cs/auto`) with the current conversation's ref, guarded by a valid UUID:

```bash
    SHADOW_REF=""
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$SESSION_ID" >/dev/null 2>&1; then
        SHADOW_REF="refs/worktree/cs/session/$SESSION_ID"
    fi
```

Leave the rest of the block (the `CRASH_DIFF`/`CRASH_FILE_COUNT` computation and the PR #5 base-guard match/mismatch branches) unchanged — it already operates on `$SHADOW_REF`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: both new tests pass; all others still pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): recover only the current conversation's ref

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 3: session-end deletes only the current conversation's ref

**Files:**
- Modify: `hooks/session-end.sh:51-56`
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Consumes: `refs/worktree/cs/session/<uuid>`.
- Produces: on clean exit, only the ending conversation's ref is removed; siblings' refs survive.

- [ ] **Step 1: Write the failing test**

Add and register (after `test_session_end_deletes_shadow_ref`):

```bash
test_session_end_deletes_only_own_conversation_ref() {
    local me="dddddddd-dddd-dddd-dddd-dddddddddddd"
    local sib="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    (
        cd "$CLAUDE_SESSION_DIR"
        tree=$(git write-tree)
        for u in "$me" "$sib"; do
            c=$(echo "autosave" | git commit-tree "$tree")
            git update-ref "refs/worktree/cs/session/$u" "$c"
        done
    )
    echo '{"session_id":"'"$me"'"}' | bash "$HOOKS_DIR/session-end.sh"

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$me" >/dev/null 2>&1; then
        echo "  FAIL: session-end must delete the ending conversation's own ref"; return 1
    fi
    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$sib" >/dev/null 2>&1; then
        echo "  FAIL: session-end must NOT delete a sibling conversation's ref"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$sib" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 only_own_conversation`
Expected: FAIL — current session-end deletes `refs/worktree/cs/auto`/`refs/cs/auto`, so `me`'s session ref survives.

- [ ] **Step 3: Write minimal implementation**

In `hooks/session-end.sh`, replace the two `update-ref -d refs/worktree/cs/auto` / `refs/cs/auto` lines with a delete of the ending conversation's own ref:

```bash
if git -C "$SESSION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        git -C "$SESSION_DIR" update-ref -d "refs/worktree/cs/session/$SESSION_ID" 2>/dev/null || true
    fi
fi
```

Note the existing test `test_session_end_deletes_shadow_ref` seeds a legacy `refs/cs/auto` and expects it gone. That legacy path is now owned by migration (Task 5), not session-end. Update that test: replace its `refs/cs/auto` seed+assert with a `refs/worktree/cs/session/<uuid>` seed keyed to the `session_id` it passes (`test-123` is not a UUID — change the event to `{"session_id":"ffffffff-ffff-ffff-ffff-ffffffffffff"}` and seed/assert that ref).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-end.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): session-end deletes only the conversation's own ref

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 4: Rename the ref across a context-fork UUID rebind

**Files:**
- Modify: `hooks/session-start.sh` (the rebind block, ~line 201-216)
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Consumes: `RECORDED_UUID` (old) and `SESSION_ID` (new) already computed in the rebind block.
- Produces: on a rebind, the snapshot moves from `refs/worktree/cs/session/<old>` to `<new>`; the old ref is removed.

- [ ] **Step 1: Write the failing test**

```bash
test_rebind_renames_conversation_ref() {
    local old="00000000-0000-0000-0000-0000000000aa"
    local new="00000000-0000-0000-0000-0000000000bb"
    # Record old uuid as the bound one, then start as new (a context-fork rebind).
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'claude_session_id: %s\n' "$old" > "$CLAUDE_SESSION_META_DIR/local/state"
    local sha
    sha=$( cd "$CLAUDE_SESSION_DIR" && tree=$(git write-tree) && echo autosave | git commit-tree "$tree" )
    git -C "$CLAUDE_SESSION_DIR" update-ref "refs/worktree/cs/session/$old" "$sha"

    echo '{"session_id":"'"$new"'","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$old" >/dev/null 2>&1; then
        echo "  FAIL: old-uuid ref must be removed after rebind"; return 1
    fi
    local moved
    moved=$(git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$new" 2>/dev/null || true)
    if [ "$moved" != "$sha" ]; then
        echo "  FAIL: snapshot must be preserved under the new uuid (got '$moved', want '$sha')"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$new" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 rebind_renames`
Expected: FAIL — the old ref survives; `<new>` ref does not exist.

- [ ] **Step 3: Write minimal implementation**

In `hooks/session-start.sh`, inside the existing rebind `if [ "$RECORDED_UUID" != "$SESSION_ID" ]; then` block (after `local_state_set claude_session_id "$SESSION_ID"`), add the ref rename. `RECORDED_UUID` and `SESSION_ID` are already in scope there. Guard so both are UUIDs and the old ref exists:

```bash
        _RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        if [[ "${RECORDED_UUID:-}" =~ $_RE ]] && [[ "$SESSION_ID" =~ $_RE ]]; then
            _old_sha=$(git -C "$SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$RECORDED_UUID" 2>/dev/null || true)
            if [ -n "$_old_sha" ]; then
                git -C "$SESSION_DIR" update-ref "refs/worktree/cs/session/$SESSION_ID" "$_old_sha" 2>/dev/null \
                    && git -C "$SESSION_DIR" update-ref -d "refs/worktree/cs/session/$RECORDED_UUID" "$_old_sha" 2>/dev/null || true
            fi
        fi
```

Keep the rename in the rebind block's natural location (after the recovery block). This is correct: a UUID rebind is a context-fork — a clean continuation, not a crash — so at rebind time there is no crash to recover and recovery correctly finds nothing under the new UUID. The rename only preserves the ref identity so a *future* crash of the new conversation is recoverable. No reordering relative to recovery is needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): rename autosave ref across a UUID rebind

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 5: Claim any legacy shared ref once via CAS-delete

**Files:**
- Modify: `hooks/session-start.sh` (add before the recovery block)
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Consumes: legacy `refs/worktree/cs/auto` and/or `refs/cs/auto`.
- Produces: the legacy ref's snapshot moved into the current conversation's `refs/worktree/cs/session/<uuid>`; the legacy ref removed. Race-safe: at most one concurrent conversation claims it.

- [ ] **Step 1: Write the failing test**

```bash
test_legacy_shared_ref_claimed_into_conversation_ref() {
    local me="00000000-0000-0000-0000-0000000000cc"
    local sha
    sha=$( cd "$CLAUDE_SESSION_DIR" && tree=$(git write-tree) && echo autosave | git commit-tree "$tree" )
    git -C "$CLAUDE_SESSION_DIR" update-ref refs/worktree/cs/auto "$sha"

    echo '{"session_id":"'"$me"'","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: legacy refs/worktree/cs/auto must be claimed (deleted)"; return 1
    fi
    local claimed
    claimed=$(git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$me" 2>/dev/null || true)
    if [ "$claimed" != "$sha" ]; then
        echo "  FAIL: legacy snapshot must be claimed into the conversation's ref"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$me" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 legacy_shared_ref_claimed`
Expected: FAIL — legacy ref survives; conversation ref not created.

- [ ] **Step 3: Write minimal implementation**

In `hooks/session-start.sh`, inside the `if git ... rev-parse --git-dir` block and BEFORE the shadow-ref recovery block, add the claim (guarded on a valid `SESSION_ID`):

```bash
    # Claim a pre-upgrade shared ref once into this conversation's ref. The
    # CAS delete (update-ref -d <ref> <old-sha>) succeeds for exactly one racing
    # conversation; only that winner creates its own session ref from the sha.
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        for _legacy in refs/worktree/cs/auto refs/cs/auto; do
            _lsha=$(git -C "$SESSION_DIR" rev-parse -q --verify "$_legacy" 2>/dev/null || true)
            [ -n "$_lsha" ] || continue
            if git -C "$SESSION_DIR" update-ref -d "$_legacy" "$_lsha" 2>/dev/null; then
                git -C "$SESSION_DIR" update-ref "refs/worktree/cs/session/$SESSION_ID" "$_lsha" 2>/dev/null || true
            fi
        done
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): claim a legacy shared ref via CAS-delete

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 6: Garbage-collect foreign refs older than 14 days

**Files:**
- Modify: `hooks/session-start.sh` (add near the recovery block)
- Test: `tests/test_shadow_ref.sh`

**Interfaces:**
- Consumes: all `refs/worktree/cs/session/*`.
- Produces: refs whose UUID is not the current conversation's and whose tip commit is older than 14 days are deleted; fresh foreign refs and the current conversation's ref are preserved.

- [ ] **Step 1: Write the failing test**

```bash
test_gc_prunes_stale_foreign_refs_only() {
    local me="00000000-0000-0000-0000-0000000000dd"
    local stale="00000000-0000-0000-0000-00000000ee00"
    local fresh="00000000-0000-0000-0000-00000000ff00"
    local tree stale_c fresh_c mine_c
    tree=$(cd "$CLAUDE_SESSION_DIR" && git write-tree)
    # A tip commit ~20 days old (stale) via committer date; fresh = now.
    stale_c=$(cd "$CLAUDE_SESSION_DIR" && GIT_COMMITTER_DATE="@$(( $(date +%s) - 20*86400 ))" sh -c 'echo old | git commit-tree '"$tree")
    fresh_c=$(cd "$CLAUDE_SESSION_DIR" && echo new | git commit-tree "$tree")
    mine_c=$(cd "$CLAUDE_SESSION_DIR" && GIT_COMMITTER_DATE="@$(( $(date +%s) - 20*86400 ))" sh -c 'echo mine | git commit-tree '"$tree")
    git -C "$CLAUDE_SESSION_DIR" update-ref "refs/worktree/cs/session/$stale" "$stale_c"
    git -C "$CLAUDE_SESSION_DIR" update-ref "refs/worktree/cs/session/$fresh" "$fresh_c"
    git -C "$CLAUDE_SESSION_DIR" update-ref "refs/worktree/cs/session/$me" "$mine_c"

    echo '{"session_id":"'"$me"'","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$stale" >/dev/null 2>&1; then
        echo "  FAIL: a stale (>14d) foreign ref must be GC'd"; return 1
    fi
    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$fresh" >/dev/null 2>&1; then
        echo "  FAIL: a fresh foreign ref must be preserved"; return 1
    fi
    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify "refs/worktree/cs/session/$me" >/dev/null 2>&1; then
        echo "  FAIL: the current conversation's own ref (even if old) must be preserved"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$fresh" 2>/dev/null || true
    git -C "$CLAUDE_SESSION_DIR" update-ref -d "refs/worktree/cs/session/$me" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_shadow_ref.sh 2>&1 | grep -A2 gc_prunes_stale`
Expected: FAIL — the stale foreign ref is not deleted (no GC yet).

- [ ] **Step 3: Write minimal implementation**

In `hooks/session-start.sh`, inside the git-dir block (after the claim, before or after recovery — GC never touches the current ref, so order is not load-bearing), add:

```bash
    # GC: prune foreign conversation refs whose tip is older than 14 days.
    _now=$(date +%s)
    while IFS= read -r _ref; do
        [ -n "$_ref" ] || continue
        case "$_ref" in "refs/worktree/cs/session/$SESSION_ID") continue ;; esac
        _ct=$(git -C "$SESSION_DIR" log -1 --format=%ct "$_ref" 2>/dev/null || echo 0)
        case "$_ct" in ''|*[!0-9]*) _ct=0 ;; esac
        if [ "$(( _now - _ct ))" -gt "$(( 14*86400 ))" ]; then
            git -C "$SESSION_DIR" update-ref -d "$_ref" 2>/dev/null || true
        fi
    done < <(git -C "$SESSION_DIR" for-each-ref --format='%(refname)' 'refs/worktree/cs/session/' 2>/dev/null || true)
```

Note: `< <(...)` process substitution is bash (not POSIX sh) — the hooks already use it (`session-start.sh` sibling-sessions loop), so it is within the established floor.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_shadow_ref.sh 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_shadow_ref.sh
git commit -m "feat(crash-recovery): GC foreign session refs older than 14 days

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Task 7: Documentation and full-suite gate

**Files:**
- Modify: `docs/hooks.md`
- Test: `bash tests/run_all.sh`

- [ ] **Step 1: Update docs**

In `docs/hooks.md`, in the `autosave-commits.sh` section, replace the description of the shared `refs/worktree/cs/auto` ref with the per-conversation model: "Autosaves the working tree to the conversation's own shadow ref `refs/worktree/cs/session/<conversation-uuid>` — each conversation writes, recovers, and deletes only its own ref, so concurrent sessions on one checkout never read or clobber each other's autosave state." In the `session-start.sh` section, note: recovers only the current conversation's ref; renames it across a context-fork UUID rebind; claims a pre-upgrade shared ref once; garbage-collects foreign refs older than 14 days. In the `session-end.sh` section, change "Deletes the shadow autosave refs" to "Deletes only the ending conversation's own shadow ref".

- [ ] **Step 2: Run the full suite**

Run: `bash tests/run_all.sh 2>&1 | tail -4`
Expected: `OK: all NN suites passed`.

- [ ] **Step 3: Commit**

```bash
git add docs/hooks.md
git commit -m "docs(crash-recovery): document per-conversation autosave refs

Claude-Session: https://claude.ai/code/session_01DQsVGtbmqg6zembvRevy6U"
```

---

## Post-implementation

- Adversarial cross-model (Fable) review of the full diff before merge — this is data-safety-adjacent; hold for it per project practice.
- Once PR #5 merges, rebase this branch onto `main`.
- The ownership-blind `session-end.sh` `rm -f session.lock` remains a documented, decoupled follow-up (no longer causes a false crash under this model).
