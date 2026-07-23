#!/usr/bin/env bash
# ABOUTME: Tests for shadow ref autosave in autosave-commits, session-end, and session-start hooks
# ABOUTME: Validates shadow ref creation, main branch isolation, crash recovery, and push protection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# Override setup for shadow ref testing (git repo with specific config)
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CS_TEST_SYNC=1  # Run hook git operations in foreground for testing
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"  # for create_test_session_with_git

    mkdir -p "$CLAUDE_SESSION_DIR/.cs/local"
    mkdir -p "$CS_SESSIONS_ROOT"

    (
        cd "$CLAUDE_SESSION_DIR"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        mkdir -p .cs/memory
        echo "# Session narrative" > .cs/memory/narrative.md
        echo "initial" > README.md
        git add -A
        git commit -q -m "Initial commit"
    )
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_TEST_SYNC CS_SESSIONS_ROOT 2>/dev/null || true
}

# ============================================================================
# autosave-commits.sh: shadow ref autosave
# ============================================================================

test_autosave_creates_shadow_ref() {
    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"

    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/worktree/cs/auto should exist after autosave"
        return 1
    fi
}

test_autosave_does_not_touch_main() {
    local head_before head_after
    head_before=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"

    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    head_after=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    if [[ "$head_before" != "$head_after" ]]; then
        echo "  FAIL: HEAD should not change after autosave"
        echo "    before: $head_before"
        echo "    after:  $head_after"
        return 1
    fi
}

test_autosave_chains_multiple_saves() {
    echo "## First" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    local ref_after_first
    ref_after_first=$(git -C "$CLAUDE_SESSION_DIR" rev-parse refs/worktree/cs/auto 2>/dev/null || echo "none")

    echo "## Second" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    local ref_after_second
    ref_after_second=$(git -C "$CLAUDE_SESSION_DIR" rev-parse refs/worktree/cs/auto 2>/dev/null || echo "none")

    if [[ "$ref_after_first" = "$ref_after_second" ]]; then
        echo "  FAIL: shadow ref should advance after second autosave"
        return 1
    fi

    local parent
    parent=$(git -C "$CLAUDE_SESSION_DIR" log --format=%P -1 refs/worktree/cs/auto 2>/dev/null || echo "")
    if [[ "$parent" != "$ref_after_first" ]]; then
        echo "  FAIL: second autosave should chain onto first"
        echo "    expected parent: $ref_after_first"
        echo "    actual parent:   $parent"
        return 1
    fi
}

test_autosave_stamps_base_head() {
    local head
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    echo "## New Finding" >> "$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"
    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$CLAUDE_SESSION_DIR/.cs/memory/narrative.md"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    local msg
    msg=$(git -C "$CLAUDE_SESSION_DIR" log -1 --format=%B refs/worktree/cs/auto 2>/dev/null || true)
    case "$msg" in
        *"cs-base: $head"*) return 0 ;;
        *) echo "  FAIL: autosave commit should record the base HEAD as 'cs-base: $head'"
           echo "    message: $msg"
           return 1 ;;
    esac
}

# ============================================================================
# session-end.sh: clean commit + shadow ref cleanup
# ============================================================================

# Uses the pre-namespaced ref name deliberately: session-end must still clean
# up a shadow ref left behind by a pre-migration cs version.
test_session_end_deletes_shadow_ref() {
    (
        cd "$CLAUDE_SESSION_DIR"
        tree=$(git write-tree)
        commit=$(echo "autosave" | git commit-tree "$tree")
        git update-ref refs/cs/auto "$commit"
    )

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    if git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/cs/auto should be deleted after session end"
        return 1
    fi
}

# ============================================================================
# session-start.sh: crash recovery + push protection
# ============================================================================

# Uses the pre-namespaced ref name deliberately: crash recovery must still
# fall back to a shadow ref left behind by a pre-migration cs version.
test_recovery_detects_crash_and_injects_context() {
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "recovered content" > recovered.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add recovered.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(echo "autosave" | git commit-tree "$tree")
        git update-ref refs/cs/auto "$commit"
        rm recovered.txt
    )

    if [[ -f "$CLAUDE_SESSION_DIR/recovered.txt" ]]; then
        echo "  FAIL: recovered.txt should not exist before recovery"
        return 1
    fi

    local output
    output=$(echo '{"session_id":"test-789","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if [[ -f "$CLAUDE_SESSION_DIR/recovered.txt" ]]; then
        echo "  FAIL: recovered.txt should NOT be auto-restored (ask user first)"
        return 1
    fi

    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: refs/cs/auto should still exist until user decides"
        return 1
    fi

    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: hook output should contain CRASH RECOVERY context"
        echo "  Output: $(echo "$output" | head -5)"
        return 1
    fi

    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/cs/auto 2>/dev/null || true
}

# The data-safety guard: when HEAD has moved off the snapshot's recorded base
# (the commit/rebase-in-the-meantime case), the blanket `checkout <ref> -- .`
# would splice a stale snapshot over diverged history. Recovery must refuse it.
test_recovery_refuses_blanket_restore_when_head_moved() {
    local base_head
    base_head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    # Snapshot stamped against the current (soon-to-be-old) HEAD.
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "in-flight work" > wip.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add wip.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(printf 'autosave\n\ncs-base: %s\n' "$base_head" | git commit-tree "$tree")
        git update-ref refs/worktree/cs/auto "$commit"
        rm -f wip.txt
    )

    # HEAD moves forward in the meantime (the commit/rebase this guard protects against).
    (cd "$CLAUDE_SESSION_DIR" && echo "moved" >> README.md && git commit -aqm "meantime commit")

    local output
    output=$(echo '{"session_id":"t-moved","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: should still surface CRASH RECOVERY context"; return 1
    fi
    if echo "$output" | grep -qF "checkout refs/worktree/cs/auto -- ."; then
        echo "  FAIL: must NOT offer the blanket checkout restore once HEAD moved off the recorded base"; return 1
    fi
    if ! echo "$output" | grep -q "HEAD has moved"; then
        echo "  FAIL: should warn that HEAD has moved since the snapshot"; return 1
    fi
    if ! git -C "$CLAUDE_SESSION_DIR" rev-parse -q --verify refs/worktree/cs/auto >/dev/null 2>&1; then
        echo "  FAIL: ref should be preserved for manual inspection, not deleted"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
}

# The other half of the guard: when the snapshot still sits on the current HEAD
# (the ordinary crash case, no meantime commit), the blanket restore is safe and
# must still be offered — otherwise the guard is vacuous.
test_recovery_offers_restore_when_base_matches() {
    local head
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    (
        cd "$CLAUDE_SESSION_DIR"
        echo "in-flight work" > wip.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add wip.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(printf 'autosave\n\ncs-base: %s\n' "$head" | git commit-tree "$tree")
        git update-ref refs/worktree/cs/auto "$commit"
        rm -f wip.txt
    )

    local output
    output=$(echo '{"session_id":"t-match","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: should surface CRASH RECOVERY context"; return 1
    fi
    if ! echo "$output" | grep -qF "checkout refs/worktree/cs/auto -- ."; then
        echo "  FAIL: should offer the blanket restore when the snapshot sits on current HEAD"; return 1
    fi
    if echo "$output" | grep -q "HEAD has moved"; then
        echo "  FAIL: should not warn about a moved HEAD when base matches"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
}

# TOCTOU: the blanket restore is offered as a copy-paste command run later. If
# HEAD moves between the scan and the user answering "restore", the command must
# refuse itself rather than splice the now-stale snapshot over moved history.
test_recovery_offered_restore_refuses_when_head_moves_after_scan() {
    local head
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)

    # Snapshot sits on the current HEAD at scan time => match branch offers the blanket.
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "snapshot-only" > toctou_wip.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add toctou_wip.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(printf 'autosave\n\ncs-base: %s\n' "$head" | git commit-tree "$tree")
        git update-ref refs/worktree/cs/auto "$commit"
        rm -f toctou_wip.txt
    )

    local output context cmd
    output=$(echo '{"session_id":"t-toctou","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    cmd=$(printf '%s\n' "$context" | sed -n 's/.*To restore, run: //p' | head -1)
    if [ -z "$cmd" ]; then echo "  FAIL: no restore command was offered in the match branch"; return 1; fi

    # HEAD moves after the scan — the TOCTOU window this guard must close.
    (cd "$CLAUDE_SESSION_DIR" && echo moved >> README.md && git commit -aqm "meantime commit")

    # Running the offered command now must REFUSE, not restore the stale snapshot.
    local run_out
    run_out=$(cd "$CLAUDE_SESSION_DIR" && eval "$cmd" 2>&1)
    if [ -f "$CLAUDE_SESSION_DIR/toctou_wip.txt" ]; then
        echo "  FAIL: offered restore clobbered the tree after HEAD moved (TOCTOU)"; return 1
    fi
    case "$run_out" in
        *REFUSED*) : ;;
        *) echo "  FAIL: offered restore should refuse (print REFUSED) once HEAD moved; got: $run_out"; return 1 ;;
    esac
    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
}

# A pre-upgrade snapshot carries no cs-base trailer. Recovery must still refuse
# the blanket restore (base unverifiable), but must NOT claim "HEAD has moved" —
# that is a false factual assertion when HEAD is in fact unchanged.
test_recovery_legacy_ref_warns_unverifiable_not_moved() {
    (
        cd "$CLAUDE_SESSION_DIR"
        echo "legacy work" > legacy.txt
        TEMP_INDEX=$(mktemp)
        cp .git/index "$TEMP_INDEX"
        GIT_INDEX_FILE="$TEMP_INDEX" git add legacy.txt
        tree=$(GIT_INDEX_FILE="$TEMP_INDEX" git write-tree)
        rm -f "$TEMP_INDEX"
        commit=$(echo "autosave" | git commit-tree "$tree")   # no cs-base trailer
        git update-ref refs/worktree/cs/auto "$commit"
        rm -f legacy.txt
    )

    local output
    output=$(echo '{"session_id":"t-legacy","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    if ! echo "$output" | grep -q "CRASH RECOVERY"; then
        echo "  FAIL: should surface CRASH RECOVERY context"; return 1
    fi
    if echo "$output" | grep -qF "checkout refs/worktree/cs/auto -- ."; then
        echo "  FAIL: must NOT offer the blanket restore for an unverifiable (no-base) snapshot"; return 1
    fi
    if echo "$output" | grep -q "HEAD has moved"; then
        echo "  FAIL: must NOT assert HEAD has moved when the base is merely unrecorded"; return 1
    fi
    if ! echo "$output" | grep -q "no recorded base"; then
        echo "  FAIL: should explain the base is unrecorded (pre-upgrade autosave)"; return 1
    fi
    git -C "$CLAUDE_SESSION_DIR" update-ref -d refs/worktree/cs/auto 2>/dev/null || true
}

test_shadow_ref_not_pushed() {
    echo '{"session_id":"test-abc","cwd":"'"$CLAUDE_SESSION_DIR"'"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null

    local hide_refs
    hide_refs=$(git -C "$CLAUDE_SESSION_DIR" config --get-all transfer.hideRefs 2>/dev/null || true)

    if [[ "$hide_refs" != *"refs/cs"* ]]; then
        echo "  FAIL: transfer.hideRefs should include refs/cs"
        echo "    actual: '$hide_refs'"
        return 1
    fi
}

test_autosave_logs_per_actor_narrative_edit() {
    local nf="$CLAUDE_SESSION_DIR/.cs/memory/narrative.alex.md"
    printf '%s\n' '# Session narrative (alex)' '' '## A New Finding' 'detail' > "$nf"

    echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$nf"'"}}' \
        | bash "$HOOKS_DIR/autosave-commits.sh"
    sleep 1

    assert_file_contains "$CLAUDE_SESSION_DIR/.cs/local/session.log" "Autosave: A New Finding" \
        "autosave should log the per-actor narrative heading" || return 1
}

# ============================================================================
# per-worktree ref isolation
# ============================================================================

test_autosave_refs_isolated_per_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "s1")
    git -C "$base_dir" worktree add -b cs/t1 "$CS_SESSIONS_ROOT/s1@t1" -q
    # Autosave in the base
    (cd "$base_dir" && echo x > f.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1 CLAUDE_SESSION_DIR="$base_dir" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"f.txt"}}')
    # Autosave in the worktree
    (cd "$CS_SESSIONS_ROOT/s1@t1" && echo y > g.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1@t1 CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/s1@t1" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"g.txt"}}')
    local base_sha wt_sha
    base_sha=$(git -C "$base_dir" rev-parse refs/worktree/cs/auto)
    wt_sha=$(git -C "$CS_SESSIONS_ROOT/s1@t1" rev-parse refs/worktree/cs/auto)
    [ "$base_sha" != "$wt_sha" ] || { echo "  FAIL: refs must be per-checkout"; return 1; }
}

test_autosave_works_in_linked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "s1")
    git -C "$base_dir" worktree add -b cs/t1 "$CS_SESSIONS_ROOT/s1@t1" -q
    (cd "$CS_SESSIONS_ROOT/s1@t1" && echo y > g.txt && \
        CS_TEST_SYNC=1 CLAUDE_SESSION_NAME=s1@t1 CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/s1@t1" \
        bash "$SCRIPT_DIR/../hooks/autosave-commits.sh" \
        <<< '{"tool_name":"Write","tool_input":{"file_path":"g.txt"}}')
    git -C "$CS_SESSIONS_ROOT/s1@t1" rev-parse -q --verify refs/worktree/cs/auto > /dev/null \
        || { echo "  FAIL: autosave must fire in a linked worktree (.git is a file)"; return 1; }
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs shadow ref autosave tests"
echo "============================="
echo ""

run_test test_autosave_creates_shadow_ref
run_test test_autosave_does_not_touch_main
run_test test_autosave_chains_multiple_saves
run_test test_autosave_stamps_base_head
run_test test_session_end_deletes_shadow_ref
run_test test_recovery_detects_crash_and_injects_context
run_test test_recovery_refuses_blanket_restore_when_head_moved
run_test test_recovery_offers_restore_when_base_matches
run_test test_recovery_offered_restore_refuses_when_head_moves_after_scan
run_test test_recovery_legacy_ref_warns_unverifiable_not_moved
run_test test_shadow_ref_not_pushed
run_test test_autosave_logs_per_actor_narrative_edit
run_test test_autosave_refs_isolated_per_worktree
run_test test_autosave_works_in_linked_worktree

report_results
