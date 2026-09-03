#!/usr/bin/env bash
# ABOUTME: Tests for session lifecycle hooks not covered by other test files
# ABOUTME: Covers session-auto-approve, subagent-context, tool-failure-logger

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# Override setup for hook testing
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # CS_ACTOR is the top-precedence actor override, so an exported one on the
    # developer's machine would decide the identity these tests pin.
    unset CS_ACTOR
    # Hooks now resolve a session from the directory, so an ambient
    # CLAUDE_PROJECT_DIR would bind them to a REAL session: tests that assert
    # "declines outside a session" fail, and worse, ones that assert silence
    # stay green while the hook writes into that live session.
    unset CLAUDE_PROJECT_DIR
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{local,memory}
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# narrative-reminder.sh
# ============================================================================

_backdate() {
    # backdate a file ~10 minutes so the staleness check fires
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$1" 2>/dev/null || true
}

test_narrative_reminder_approves_outside_session() {
    local output
    output=$(echo '{}' | CLAUDE_SESSION_NAME= bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve outside a cs session" || return 1
}

test_narrative_reminder_approves_when_recently_modified() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve when narrative recently modified" || return 1
}

test_narrative_reminder_blocks_when_stale() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "Should block when narrative is stale" || return 1
    assert_output_contains "$output" "narrative.md" "Reminder should point at narrative.md" || return 1
}

test_narrative_reminder_tracks_per_actor() {
    rm -f "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    echo "# Session narrative (alex)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alex.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alex.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "Should block on stale per-actor narrative" || return 1
    assert_output_contains "$output" "narrative.alex.md" "Reminder should point at the per-actor narrative" || return 1
}

test_narrative_reminder_asks_for_appended_corrections_not_rewrites() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "append a dated correction" "corrections are appended" || return 1
    assert_output_contains "$output" "never rewrite or delete earlier sections" "earlier sections are immutable" || return 1
    assert_output_not_contains "$output" "correct or remove them" "the in-place instruction is gone" || return 1
}

test_narrative_reminder_flags_a_narrative_over_budget() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.alice.md is 2 KB, over the 2 KB budget" "names the file and the budget" || return 1
    assert_output_contains "$output" "cs -narrative rotate" "points at the rotation" || return 1
}

test_narrative_reminder_is_silent_about_budget_when_under() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "the reminder itself still fires" || return 1
    assert_output_not_contains "$output" "over the" "no budget line under budget" || return 1
}

test_narrative_reminder_survives_an_unreadable_narrative() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    _backdate "$nf"
    chmod 000 "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    chmod 644 "$nf"
    assert_output_contains "$output" "decision" "the hook still answers with JSON when a narrative cannot be read" || return 1
}

test_narrative_reminder_budget_line_covers_a_teammates_file() {
    # The line names whichever file is over; the "if it is yours" clause leaves
    # the decision to the reader, since the hook does not resolve the actor.
    { echo "# Session narrative (bob)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.bob.md is 2 KB" "names bob's file" || return 1
    assert_output_contains "$output" "if it is yours" "leaves ownership to the reader" || return 1
}

test_stop_raises_attention_marker() {
    # Turn end raises the machine-local attention flag the statusline blinks
    # until the user next interacts. Lives in .cs/local/ (never git-synced).
    rm -rf "$CLAUDE_SESSION_META_DIR/local"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "Stop hook should raise the attention marker" || return 1
}

test_stop_no_attention_marker_for_subagents() {
    rm -rf "$CLAUDE_SESSION_META_DIR/local"
    echo '{"agent_id":"sub-1"}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "subagent stops must not raise the attention marker" || return 1
}

test_narrative_reminder_respects_cooldown() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    date +%s > "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Fresh cooldown should suppress the reminder" || return 1
}

test_narrative_reminder_approves_for_subagent() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{"agent_id":"sub-1"}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Subagent should always approve" || return 1
    assert_output_not_contains "$output" "block" "Subagent should never be blocked" || return 1
}

# ============================================================================
# session-auto-approve.sh
# ============================================================================

test_auto_approve_allows_cs_metadata_write() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve writes to .cs/ files" || return 1
}

test_auto_approve_allows_cs_edit() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/summary.md" \
        '{tool_name: "Edit", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve edits to .cs/ files" || return 1
}

test_auto_approve_ignores_non_cs_path() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_DIR/src/main.py" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    # Should produce no output (falls through to normal permission prompt)
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-.cs/ paths, got: $output"
        return 1
    fi
}

test_auto_approve_ignores_non_write_tools() {
    local input='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-Write/Edit tools, got: $output"
        return 1
    fi
}

# A ../ traversal spelling that resolves outside .cs/ must NOT be auto-approved.
test_auto_approve_rejects_traversal() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/../../../etc/evil.conf" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: traversal path must fall through to the prompt, got: $output"
        return 1
    fi
}

# A symlink AT the write target resolves inside .cs/ by its parent, so only an
# lstat of the final component catches it. Session directories are git-shared by
# design, so a pulled symlink would otherwise turn every auto-approved metadata
# write into a write outside the session.
test_auto_approve_rejects_leaf_symlink() {
    # A filesystem where `ln -s` produces a regular-file COPY makes the -L guard
    # cannot fire and its approval is correct there (same reason as
    # tests/test_adopt.sh's symlink cases).
    local outside="$TEST_TMPDIR/outside-the-session.conf"
    echo "original" > "$outside"
    ln -s "$outside" "$CLAUDE_SESSION_META_DIR/notes.md"

    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/notes.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: a symlinked target must fall through to the prompt, got: $output"
        return 1
    fi
}

test_auto_approve_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Write","tool_input":{"file_path":"/tmp/anything.md"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# subagent-context.sh
# ============================================================================

test_subagent_context_deliverable_is_final_message() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_not_contains "$output" "Document findings in .cs/memory/narrative.md" \
        "a subagent's deliverable is its final message, not a shared narrative file" || return 1
    assert_output_contains "$output" "final message" \
        "subagent context must tell the subagent its final message is the deliverable" || return 1
}

test_subagent_context_points_to_secret_store() {
    # The secrets rule must give the subagent the right action (store it), not
    # just ban the wrong one — otherwise a subagent that meets a credential
    # improvises instead of using the session secret store.
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "cs -secrets set" \
        "the secrets rule must point the subagent at the session secret store" || return 1
}

test_subagent_injects_session_name() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_NAME" \
        "Should include session name" || return 1
}

test_subagent_injects_session_dir() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_DIR" \
        "Should include session directory" || return 1
}

test_subagent_returns_valid_json() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null 2>&1; then
        echo "  FAIL: Output should have hookSpecificOutput.additionalContext"
        echo "  Output: $output"
        return 1
    fi
}

test_subagent_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# tool-failure-logger.sh
# ============================================================================

test_failure_logged_to_session_log() {
    local input='{"tool_name":"Bash","error":"Command failed with exit code 1"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" \
        "Should log tool name" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Command failed" \
        "Should log error message" || return 1
}

test_failure_log_has_timestamp() {
    local input='{"tool_name":"Write","error":"Permission denied"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$CLAUDE_SESSION_META_DIR/local/session.log" || {
        echo "  FAIL: Log should have timestamp"
        return 1
    }
}

test_failure_truncates_long_errors() {
    local long_error
    long_error=$(python3 -c "print('x' * 500)")
    local input
    input=$(jq -n --arg err "$long_error" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    local log_line
    log_line=$(grep "Tool failure" "$CLAUDE_SESSION_META_DIR/local/session.log" | head -1)
    local line_len=${#log_line}
    if [[ "$line_len" -gt 280 ]]; then
        echo "  FAIL: Log line should be truncated ($line_len chars)"
        return 1
    fi
}

test_failure_handles_huge_multiline_error() {
    # A large multi-line error (long stack trace) must be logged without crashing
    # the hook: its `echo "$err" | head -1 | cut` truncation SIGPIPEs on >64KB and
    # is guarded by `|| true`. Feed jq via --rawfile, NOT --arg — a ~250KB value on
    # jq's command line exceeds Linux's per-arg limit (MAX_ARG_STRLEN, 128KB) and
    # dies with "Argument list too long" before the hook ever runs.
    local errfile="$TEST_TMPDIR/huge_err.txt"
    python3 -c "print('\n'.join(['x' * 500 for _ in range(500)]))" > "$errfile"
    local input
    input=$(jq -n --rawfile err "$errfile" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" \
        "Should log huge multi-line error without crashing" || return 1
}

test_failure_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Bash","error":"fail"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    # Should exit cleanly without writing anything
    if [[ -s "$CLAUDE_SESSION_META_DIR/local/session.log" ]]; then
        local content
        content=$(cat "$CLAUDE_SESSION_META_DIR/local/session.log")
        if [[ -n "$content" ]]; then
            echo "  FAIL: Should not log outside session"
            return 1
        fi
    fi
}

test_failure_handles_missing_error() {
    local input='{"tool_name":"Read"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Read" \
        "Should handle missing error field" || return 1
}

# ============================================================================
# session-start.sh: cross-session context
# ============================================================================

# Setup for session-start tests needs CS_SESSIONS_ROOT with sibling sessions
session_start_setup() {
    setup
    # Isolate from an ambient CS_FRESH_REBIND (set when the suite runs from inside
    # a freshly-rebound cs session); the positive test re-supplies it inline.
    unset CS_FRESH_REBIND 2>/dev/null || true
    # Model a cs-launched lead: the hook rebinds the recorded conversation only
    # when the claude firing it is the process cs exec'd into. Tests that model
    # a child claude or a walked-in front end override CLAUDE_PID inline.
    export CS_LEAD_PID=$$
    export CLAUDE_PID=$$
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session lives inside SESSIONS_ROOT
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{local,memory}
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"

    # Initialize git so the dynamic context block runs
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > README.md && git add -A && git commit -q -m init)

    # Create README with frontmatter and placeholder objective
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: []
aliases: ["current-session"]
---
# Session: current-session

## Objective

Current session objective
EOF
}

session_start_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

# Helper: create a sibling session with an objective
create_sibling_session() {
    local name="$1"
    local objective="$2"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs/local"
    cat > "$dir/.cs/README.md" << EOF
## Objective

$objective
EOF
    # Touch log to set modification time
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started" > "$dir/.cs/local/session.log"
}


# The resume-only Session State block is gated on the session being a git repo.
# This is the baseline: an ordinary session, where .git is a directory.
test_session_start_emits_session_state_on_resume() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "an ordinary session gets the resume state block" || return 1
}

# In a feature worktree .git is a FILE, not a directory, so a `-d` test on it is
# false and the whole block was skipped — for every worktree session, on every
# resume. The rest of the codebase probes with `git rev-parse --git-dir`, which
# is true for both shapes.
test_session_start_emits_session_state_in_a_worktree() {
    session_start_setup
    local base="$CLAUDE_SESSION_DIR"
    local wt="$CS_SESSIONS_ROOT/current-session@feat"
    git -C "$base" worktree add -q -b cs/feat "$wt" >/dev/null 2>&1 || {
        echo "  FAIL: could not create the worktree fixture"
        return 1
    }
    [ -f "$wt/.git" ] || { echo "  FAIL: fixture .git is not a file — the bug is unreachable"; return 1; }
    mkdir -p "$wt/.cs"/{local,memory}
    cp "$CLAUDE_SESSION_META_DIR/README.md" "$wt/.cs/README.md"
    export CLAUDE_SESSION_DIR="$wt"
    export CLAUDE_SESSION_META_DIR="$wt/.cs"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$wt"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "a worktree session must get the resume state block too" || return 1
}

test_session_start_announces_worktree_task() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    local output context
    output=$(echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "feature worktree of session 'myproj'" \
        "worktree sessions must be told what they are (on every source)" || return 1
    assert_output_contains "$context" "cs myproj --merge fix-auth" \
        "the integration command must be spelled out" || return 1
    assert_output_contains "$context" "Do NOT merge" \
        "manual merges must be warned against" || return 1
}


test_session_start_worktree_block_needs_at_shaped_name() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    # task_branch present but the session name lost its @ (corrupted state
    # or env set outside the launcher): emitting commands would misfire —
    # cs -rm on a plain name rm -rf's the BASE session. No block at all.
    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "cs -rm" \
        "no destructive command suggestions without a parseable name" || return 1
    assert_output_not_contains "$output" "feature worktree" \
        "no worktree block when the name shape does not parse" || return 1
}

test_session_start_no_worktree_block_for_plain_sessions() {
    session_start_setup

    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "feature worktree" \
        "plain sessions must not get the worktree block" || return 1
}

test_session_start_worktree_abandon_is_user_gated() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    # The abandon command rm -rf's the whole worktree session. Like the merge
    # command, it must be routed through the user — never left looking self-serve.
    local output context
    output=$(echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "ask the user to run: cs -rm" \
        "the destructive abandon command must be gated behind the user, like the merge command" || return 1
    assert_output_contains "$context" "never run this yourself" \
        "the abandon command must warn Claude not to self-serve the worktree deletion" || return 1
}

# Helper: build a refs/worktree/cs/auto shadow ref whose tree differs from HEAD
# in $1 files (simulates the unsaved crash state the recovery path detects).
_seed_crash_shadow() {
    local n="$1" i base
    # Stage only the crash files — git add -A would also sweep in the untracked
    # .cs/README.md session_start_setup leaves behind, inflating the file count.
    # Record the base HEAD in a cs-base trailer, as a real autosave does, so the
    # snapshot reads as sitting on the current HEAD (the ordinary crash case
    # where recovery's whole-tree restore is safe to offer).
    ( cd "$CLAUDE_SESSION_DIR" \
        && base=$(git rev-parse HEAD) \
        && for i in $(seq 1 "$n"); do echo "autosave $i" > "crash_$i.txt"; done \
        && git add crash_*.txt \
        && git commit -q -m "$(printf 'autosaved crash state\n\ncs-base: %s' "$base")" \
        && git update-ref refs/worktree/cs/session/40000000-0000-0000-0000-000000000001 HEAD \
        && git reset -q --hard HEAD~1 )
}

test_session_start_crash_recovery_warns_before_overwrite() {
    session_start_setup
    _seed_crash_shadow 2

    local output context
    output=$(echo '{"session_id":"40000000-0000-0000-0000-000000000001","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "CRASH RECOVERY" \
        "crash recovery context must be injected when a shadow ref has changes" || return 1
    assert_output_contains "$context" "Before starting any other work" \
        "crash recovery must anchor the ask BEFORE Claude starts the first task" || return 1
    assert_output_contains "$context" "overwrites any current uncommitted changes" \
        "crash recovery must warn that restoring clobbers uncommitted work" || return 1
}

test_session_start_crash_count_reflects_all_files() {
    session_start_setup
    # 12 changed files: the count must report 12, not the 10 the list is capped at.
    _seed_crash_shadow 12

    local output context
    output=$(echo '{"session_id":"40000000-0000-0000-0000-000000000001","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "12 file(s)" \
        "the crash file count must reflect all changed files, not the capped list length" || return 1
    assert_output_contains "$context" "first 10 listed" \
        "when the list is capped the context must say so" || return 1
}

test_subagent_context_announces_worktree_task() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    local output
    output=$(echo '{}' | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/subagent-context.sh" 2>/dev/null)
    assert_output_contains "$output" "feature worktree" \
        "subagents must inherit worktree awareness" || return 1
    assert_output_contains "$output" "cs --merge" \
        "subagents must know integration goes through cs --merge" || return 1
}

test_resume_digest_reports_memory_activity() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    ( cd "$CLAUDE_SESSION_DIR" && mkdir -p .cs/memory && echo "fact" > .cs/memory/new-fact.md \
        && git add -A && git commit -q -m "add memory" --author="Bob <bob@x.io>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Since your last session" "resume should inject the activity digest" || return 1
    assert_output_contains "$context" "Bob" "digest should name the contributing author" || return 1

    local head wm
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)
    wm=$(cat "$CLAUDE_SESSION_META_DIR/local/watermark")
    assert_eq "$head" "$wm" "watermark should advance to HEAD after resume" || return 1
}

# Nobody can read a teammate's whole narrative on resume (one dormant file
# measured 801 KB). Narratives are append-only, so everything committed since
# this actor's watermark is a tail: the digest names each teammate file that
# grew, how many sections were added, and the line the new content starts on.
# The actor's own file is read in full and never listed here.
test_resume_digest_names_where_a_teammates_narrative_grew() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    local mine="$CLAUDE_SESSION_DIR/.cs/memory/narrative.t-t.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    printf -- '---\nname: session-narrative-t-t\ntype: narrative\n---\n## mine\nown line\n' > "$mine"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    # bob's file is 12 lines; the appended section starts on line 13.
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"
    printf -- '\n## mine again\nown new line\n' >> "$mine"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append" --author="Bob <bob@example.com>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 13" \
        "digest must name the teammate file, the section count and the first new line" || return 1
    assert_output_contains "$context" "narrative.t-t.md in full" \
        "digest must tell the actor to read its own narrative in full" || return 1
    assert_output_not_contains "$context" "narrative\.t-t\.md: [0-9][0-9]* new section" \
        "the actor's own narrative is never listed as a teammate delta" || return 1
    assert_output_not_contains "$context" "Skim their narrative" \
        "the whole-file skim instruction is gone" || return 1
}

# Rotation head-truncates a narrative (oldest sections move to the archive), so
# the file can shrink at the top while it grows at the tail. The start line is
# still (lines now - lines added + 1), and the count is of added sections only.
test_resume_digest_delta_survives_a_rotated_teammate_narrative() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    # Rotate away the first section (3 lines gone from the head), then append one.
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-02 second\nanother old finding\n\n## 2026-01-03 third\nnew finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "rotate and append" --author="Bob <bob@example.com>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    # 11 lines now, 3 added: the new section starts on line 9.
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 9" \
        "after a head-truncating rotation the delta is still the tail" || return 1
}

# The start line must come from the committed delta itself, not from the
# working-tree length: a teammate's uncommitted tail appends would otherwise
# push the named line past the committed sections. Two commits after the
# watermark also pin the range to the watermark rather than to HEAD~1.
test_resume_digest_start_line_ignores_uncommitted_tail() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append 1" --author="Bob <bob@example.com>" )
    printf -- '\n## 2026-01-04 fourth\nnewer finding\n' >> "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append 2" --author="Bob <bob@example.com>" )
    # Uncommitted growth on top: must not move the committed start line (13).
    printf -- '\n## 2026-01-05 uncommitted\nnot yet committed\n' >> "$bob"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 2 new section(s) from line 13" \
        "two commits since the watermark count, and uncommitted tail lines do not shift the start" || return 1
}

# The hooks must parse under the floor shell. An apostrophe inside a heredoc
# that sits inside $(...) is accepted by bash 5 and rejected by bash 3.2, so
# a suite that runs the hooks under whichever bash leads PATH cannot see it.
test_hooks_parse_under_bin_bash() {
    local f
    for f in "$HOOKS_DIR"/*.sh; do
        /bin/bash -n "$f" 2>/dev/null || { echo "  FAIL: /bin/bash -n rejects $(basename "$f")"; return 1; }
    done
}

test_resume_digest_silent_without_watermark() {
    session_start_setup
    rm -f "$CLAUDE_SESSION_META_DIR/local/watermark"

    local output
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "Since your last session" "no digest on first resume (no watermark)" || return 1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/watermark" "watermark should be seeded on first resume" || return 1
}

test_session_start_includes_sibling_sessions() {
    session_start_setup

    create_sibling_session "api-refactor" "Refactor REST API to use GraphQL"
    create_sibling_session "auth-migration" "Migrate auth from JWT to Clerk"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "api-refactor"; then
        echo "  FAIL: Should include sibling session api-refactor"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q "auth-migration"; then
        echo "  FAIL: Should include sibling session auth-migration"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q "cs -msg"; then
        echo "  FAIL: sibling block should name cs -msg as the way to reach another session"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_excludes_current_session() {
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Current session should NOT appear in the sibling list
    # (it's already the session being started)
    if echo "$context" | grep -q "Other Sessions" && echo "$context" | grep -q "current-session:"; then
        echo "  FAIL: Should not include current session in sibling list"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

# Two other places in this hook family mandate AskUserQuestion for a decision the
# user owns: crash recovery, and the wrap-up cue in the CLAUDE.local.md block.
# Routing a request to the session that owns it is the same kind of decision and
# was the one left as passive prose.
test_session_start_sibling_block_mandates_asking() {
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "AskUserQuestion"; then
        echo "  FAIL: sibling block must name AskUserQuestion, not just 'say so'"
        session_start_teardown
        return 1
    fi
    # Picky, not trigger-happy: the wrap-up cue text warns that false positives
    # erode the signal, and a routing prompt that fires on vocabulary overlap
    # becomes the next ignored block.
    if ! echo "$context" | grep -qi "substantially"; then
        echo "  FAIL: sibling block must set a high bar, not fire on any overlap"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_sibling_line_carries_the_send_syntax() {
    # Naming the verb without its syntax is worse than saying nothing: it tells
    # the reader a capability exists and forces a `cs --help` call to use it.
    # Inbound mail is already pushed on every prompt by scope-prompt.sh; this is
    # the only place the outbound form is delivered where sending is possible.
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q 'cs -msg <session> "<body>"'; then
        echo "  FAIL: the sibling line must carry the full send form, not just the verb"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q 'notify|task|text|result'; then
        echo "  FAIL: the sibling line must name the --kind values"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_narrative_is_per_actor() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    assert_output_not_contains "$context" "narrative.md: Document" \
        "session-start must not steer findings to the shared narrative.md" || { session_start_teardown; return 1; }
    # The block resolves the actor, so the key-files line can name the real file
    # instead of a placeholder the agent would have to resolve for itself. Read
    # the slug back out of the context and require the two lines to agree —
    # a drifting pair is what would send findings to a file nobody reads.
    local actor
    actor=$(printf '%s\n' "$context" | sed -n 's/^Current actor: \([^ ]*\) .*/\1/p' | head -1)
    [ -n "$actor" ] || {
        echo "  FAIL: the injected context never states the resolved actor"
        session_start_teardown; return 1
    }
    assert_output_contains "$context" "narrative.$actor.md: append findings" \
        "the key-files line must name the same resolved narrative the actor line does" \
        || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_secrets_guidance_is_stdin_and_backend_neutral() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    assert_output_not_contains "$context" "stored securely in the OS keychain" \
        "secrets backend may be the encrypted-file fallback, not a keychain" || { session_start_teardown; return 1; }
    assert_output_contains "$context" "on stdin" \
        "secrets guidance must direct the value to stdin (argv/heredoc leak to the log)" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_shows_objectives() {
    session_start_setup

    create_sibling_session "my-project" "Build the analytics dashboard"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "analytics dashboard"; then
        echo "  FAIL: Should include sibling objective text"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_limits_sibling_count() {
    session_start_setup

    # Create 10 sibling sessions
    for i in $(seq 1 10); do
        create_sibling_session "session-$i" "Objective for session $i"
    done

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Should show at most 5 siblings
    local sibling_count
    sibling_count=$(echo "$context" | grep -c "^  [a-z]" || echo "0")
    if [[ "$sibling_count" -gt 5 ]]; then
        echo "  FAIL: Should limit to 5 siblings (got $sibling_count)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_updates_last_resumed() {
    session_start_setup

    # Verify no last_resumed yet
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed:" \
        "Should not have last_resumed before resume" || { session_start_teardown; return 1; }

    # Trigger resume
    echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed: 20" \
        "Should set last_resumed in local state after resume" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_last_resumed_not_set_on_startup() {
    session_start_setup

    # source=startup should NOT set last_resumed
    echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed:" \
        "Should not set last_resumed on startup" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_skips_siblings_on_startup() {
    session_start_setup

    create_sibling_session "other" "Some work"

    # source=startup (fresh session, not resume)
    local output
    output=$(echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # On startup, no dynamic context is injected (including siblings)
    if echo "$context" | grep -q "Other Sessions"; then
        echo "  FAIL: Should not inject siblings on startup (only on resume)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

# Helper: seed local state with a recorded claude_session_id
seed_recorded_uuid() {
    local uuid="$1"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    echo "claude_session_id: $uuid" > "$CLAUDE_SESSION_META_DIR/local/state"
}

test_session_start_clears_attention_marker() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"

    echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "session start should clear a stale attention marker" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_uuid_to_live_session() {
    session_start_setup

    # Local state records an old conversation; the hook reports a different
    # live one (claude forks a new UUID on context-limit continuation, leaving
    # the old transcript on disk — the recorded binding goes stale)
    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind claude_session_id to the live session UUID" || { session_start_teardown; return 1; }
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "aaaaaaaa-1111-2222-3333-444444444444" \
        "Stale UUID should be gone after rebind" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_uuid_on_startup() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind on startup too (live UUID is authoritative on every source)" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_ignores_invalid_session_id() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # Non-UUID session_id (eg. jq null fallback or harness stub) must not
    # clobber a valid recorded binding
    echo '{"session_id":"not-a-uuid","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "Recorded UUID should survive an invalid live session_id" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_for_a_claude_cs_spawned() {
    # Needs a real `ps -o ppid=`. A ps that accepts
    # only [-aefls] [-u UID] [-p PID] and errors on -o, which would fail this
    # test for a reason that has nothing to do with the property. Nothing is
    # declining is the right answer when no lead process can be identified.
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # cs's resume arm runs claude as a child rather than exec'ing into it — it
    # needs the exit status to fall through to a fresh rebind when there is no
    # conversation to resume — so on the commonest launch of all the recorded
    # conversation's pid is cs's CHILD, not cs itself. A real background job
    # stands in for claude: its parent is this shell, the same relation that
    # launch creates. Recognising only the exec'd shape would silence the
    # rebind on every resume.
    sleep 30 &
    local launched=$!

    CLAUDE_PID="$launched" \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"resume\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    kill "$launched" 2>/dev/null || true
    wait "$launched" 2>/dev/null || true

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "a claude cs spawned as its child must still rebind" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_for_child_claude() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # A child claude — an agent-team teammate, or a headless `claude -p` the
    # lead spawned — runs its own SessionStart against the same checkout. It
    # may carry the lead's exported CS_LEAD_PID, but Claude Code stamps each
    # hook env with the pid of the claude that fired it, so CLAUDE_PID is the
    # child's own. Only the launched conversation owns the single recorded slot.
    CLAUDE_PID=999999 \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a child claude must not take the recorded slot" || { session_start_teardown; return 1; }
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "bbbbbbbb-5555-6666-7777-888888888888" \
        "the child's own UUID must never be recorded" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_for_a_live_foreign_parent() {
    # Needs a real `ps -o ppid=` — see the skip note above.
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # The teammate's actual shape: a LIVE claude whose parent is real but is not
    # cs — tmux started it. The sibling decline test uses a dead pid, so it pins
    # only the case where ps finds nothing; an implementation that asked whether
    # a parent EXISTS rather than whether it MATCHES would satisfy that test and
    # re-open this bug. Here ps succeeds and reports this shell, while
    # CS_LEAD_PID names a process that is not it.
    sleep 30 &
    local live=$!

    CLAUDE_PID="$live" CS_LEAD_PID=999999 \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a live claude whose parent is not cs must not take the slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_without_lead_pid() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # A front end that resolved the session by walking the directory — desktop,
    # or a bare `claude` started inside a session checkout. Nothing exported
    # CS_LEAD_PID, so there is no launch to match and the slot is not this
    # conversation's to claim. Asserted separately from the child case because
    # the two fail the gate for different reasons, and an implementation that
    # compares the two variables without requiring both to be set would let
    # this one through on the empty string.
    CLAUDE_PID=999999 CS_LEAD_PID= \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a walked-in front end must not take the recorded slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_when_neither_pid_is_set() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # Both unset is the trap a bare `[ "$CLAUDE_PID" = "$CS_LEAD_PID" ]` falls
    # into: empty equals empty, so every unknown caller would be treated as the
    # lead. The gate must require a launch pid to exist, not merely agree.
    CLAUDE_PID= CS_LEAD_PID= \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "an unidentifiable caller must not take the recorded slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

# ============================================================================
# session-end.sh: index.md generation
# ============================================================================

# Setup for index tests: need SESSIONS_ROOT with sessions that have frontmatter
index_setup() {
    setup
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: [testing, hooks]
---
# Session: current-session

## Objective

Test the index generation feature

## Environment

Local dev
EOF
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && git add -A && git commit -q -m init)
}

index_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

# Helper: create a session with frontmatter
create_indexed_session() {
    local name="$1"
    local status="$2"
    local objective="$3"
    local tags="${4:-}"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    cat > "$dir/.cs/README.md" << EOF
---
status: $status
created: 2026-04-01
tags: [$tags]
---
# Session: $name

## Objective

$objective

## Outcome

[pending]
EOF
}

test_session_end_generates_index() {
    index_setup

    create_indexed_session "api-work" "active" "Build the API" "api, backend"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" "index.md should be generated" || { index_teardown; return 1; }

    index_teardown
}

test_index_lists_all_sessions() {
    index_setup

    create_indexed_session "alpha" "active" "Alpha objective"
    create_indexed_session "beta" "completed" "Beta objective"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "alpha" "Should list alpha" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "beta" "Should list beta" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "current-session" "Should list current session" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_objectives() {
    index_setup

    create_indexed_session "my-project" "active" "Build the dashboard"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Build the dashboard" \
        "Should include objective text" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_status() {
    index_setup

    create_indexed_session "done-project" "completed" "Old work"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "completed" \
        "Should show status" || { index_teardown; return 1; }

    index_teardown
}

test_index_has_auto_generated_notice() {
    index_setup

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Auto-generated" \
        "Should have auto-generated notice" || { index_teardown; return 1; }

    index_teardown
}


# ============================================================================
# timeline.jsonl
# ============================================================================

test_session_start_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Need README with frontmatter for full context
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-09
tags: []
aliases: ["test-session"]
---
# Session: test-session
EOF

    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && git add -A && git commit -q -m init) 2>/dev/null || true

    echo '{"session_id":"abc","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1

    assert_exists "$timeline" "timeline.jsonl should be created" || return 1
    # Should contain a started event
    if ! jq -e '. | select(.event == "started")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain a started event"
        echo "  Content: $(cat "$timeline")"
        return 1
    fi
}

test_session_end_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    echo '{"session_id":"abc","source":"user_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$timeline" "timeline.jsonl should be created on end" || return 1
    if ! jq -e '. | select(.event == "ended")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain an ended event"
        return 1
    fi
}

test_timeline_events_are_valid_jsonl() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Write a fake event
    echo '{"ts":"2026-04-09T20:00:00Z","event":"started","source":"resume"}' >> "$timeline"
    echo '{"ts":"2026-04-09T20:30:00Z","event":"ended","source":"user_exit"}' >> "$timeline"

    # Each line must be valid JSON
    while IFS= read -r line; do
        if ! echo "$line" | jq -e . > /dev/null 2>&1; then
            echo "  FAIL: Invalid JSON line: $line"
            return 1
        fi
    done < "$timeline"
}

test_timeline_subagent_skipped() {
    # Subagents shouldn't write to parent's timeline
    # (test indirectly: session-start with agent_id should not append)
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"
    echo '{}' > "$CLAUDE_SESSION_META_DIR/README.md"

    # SubagentStart doesn't fire session-start, but if a subagent somehow invokes it
    # with agent_id in payload, the hook should skip the timeline append.
    # (This test documents the expectation even though in practice SubagentStart
    # is a different hook event.)
    echo '{"session_id":"abc","source":"startup","agent_id":"sub-123"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1 || true

    # Timeline should not exist or should not have a started event from this
    if [[ -f "$timeline" ]] && jq -e '. | select(.event == "started" and .subagent == true)' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: subagent invocation should not add timeline entry"
        return 1
    fi
}

# ============================================================================
# session-end.sh: the git-synced README must never receive machine-local
# timestamps — divergent per-machine writes made merge conflicts inevitable
# when a session is shared through git
# ============================================================================

test_session_end_never_stamps_readme() {
    index_setup

    local before
    before=$(cat "$CLAUDE_SESSION_META_DIR/README.md")

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_eq "$before" "$(cat "$CLAUDE_SESSION_META_DIR/README.md")" \
        "session end must leave README byte-identical" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_generates_index_with_many_changes() {
    # Regression: when git has 6+ uncommitted files, the FILE_LIST pipeline
    # used to trip SIGPIPE + pipefail, killing the script before index.md
    # was generated.
    index_setup

    # Create more than 5 uncommitted files in the session repo
    for i in 1 2 3 4 5 6 7 8; do
        echo "content $i" > "$CLAUDE_SESSION_DIR/file_$i.txt"
    done

    echo '{"session_id":"test-123","source":"user_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" \
        "index.md should be generated even with 6+ uncommitted files" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_leaves_legacy_updated_line_alone() {
    index_setup

    # A legacy 'updated:' line (pre-dating the .cs/local/state split) is
    # migrate_session's to remove — the hook must not touch it either way
    sed -i.bak '/^tags:/a\
updated: 2026-01-01' "$CLAUDE_SESSION_META_DIR/README.md" && rm -f "$CLAUDE_SESSION_META_DIR/README.md.bak"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated: 2026-01-01" \
        "Hook must not rewrite a legacy updated line" || { index_teardown; return 1; }

    index_teardown
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs session hook tests"
echo "====================="
echo ""

# Discoveries archiver

# Session auto-approve
run_test test_narrative_reminder_approves_outside_session
run_test test_narrative_reminder_approves_when_recently_modified
run_test test_narrative_reminder_blocks_when_stale
run_test test_narrative_reminder_tracks_per_actor
run_test test_narrative_reminder_asks_for_appended_corrections_not_rewrites
run_test test_narrative_reminder_flags_a_narrative_over_budget
run_test test_narrative_reminder_is_silent_about_budget_when_under
run_test test_narrative_reminder_survives_an_unreadable_narrative
run_test test_narrative_reminder_budget_line_covers_a_teammates_file
run_test test_narrative_reminder_respects_cooldown
run_test test_stop_raises_attention_marker
run_test test_stop_no_attention_marker_for_subagents
run_test test_narrative_reminder_approves_for_subagent
run_test test_auto_approve_allows_cs_metadata_write
run_test test_auto_approve_allows_cs_edit
run_test test_auto_approve_ignores_non_cs_path
run_test test_auto_approve_ignores_non_write_tools
run_test test_auto_approve_rejects_traversal
run_test test_auto_approve_rejects_leaf_symlink
run_test test_auto_approve_skips_outside_session

# Subagent context
run_test test_subagent_injects_session_name
run_test test_subagent_injects_session_dir
run_test test_subagent_returns_valid_json
run_test test_subagent_skips_outside_session
run_test test_subagent_context_points_to_secret_store

# Tool failure logger
run_test test_failure_logged_to_session_log
run_test test_failure_log_has_timestamp
run_test test_failure_truncates_long_errors
run_test test_failure_handles_huge_multiline_error
run_test test_failure_skips_outside_session
run_test test_failure_handles_missing_error

# Session start: cross-session context
run_test test_session_start_emits_session_state_on_resume
run_test test_session_start_emits_session_state_in_a_worktree
run_test test_session_start_announces_worktree_task
run_test test_session_start_worktree_block_needs_at_shaped_name
run_test test_session_start_no_worktree_block_for_plain_sessions
run_test test_session_start_worktree_abandon_is_user_gated
run_test test_session_start_crash_recovery_warns_before_overwrite
run_test test_session_start_crash_count_reflects_all_files
run_test test_subagent_context_announces_worktree_task
run_test test_subagent_context_deliverable_is_final_message
run_test test_session_start_narrative_is_per_actor
run_test test_session_start_secrets_guidance_is_stdin_and_backend_neutral
run_test test_resume_digest_reports_memory_activity
run_test test_resume_digest_silent_without_watermark
run_test test_resume_digest_names_where_a_teammates_narrative_grew
run_test test_resume_digest_delta_survives_a_rotated_teammate_narrative
run_test test_resume_digest_start_line_ignores_uncommitted_tail
run_test test_hooks_parse_under_bin_bash
run_test test_session_start_includes_sibling_sessions
run_test test_session_start_excludes_current_session
run_test test_session_start_sibling_block_mandates_asking
run_test test_session_start_sibling_line_carries_the_send_syntax
run_test test_session_start_shows_objectives
run_test test_session_start_limits_sibling_count
run_test test_session_start_updates_last_resumed
run_test test_session_start_last_resumed_not_set_on_startup
run_test test_session_start_skips_siblings_on_startup
run_test test_session_start_clears_attention_marker
run_test test_session_start_rebinds_uuid_to_live_session
run_test test_session_start_rebinds_uuid_on_startup
run_test test_session_start_rebind_ignores_invalid_session_id
run_test test_session_start_rebinds_for_a_claude_cs_spawned
run_test test_session_start_rebind_declines_for_child_claude
run_test test_session_start_rebind_declines_for_a_live_foreign_parent
run_test test_session_start_rebind_declines_without_lead_pid
run_test test_session_start_rebind_declines_when_neither_pid_is_set

# Session end: index.md generation
run_test test_session_end_generates_index
run_test test_index_lists_all_sessions
run_test test_index_shows_objectives
run_test test_index_shows_status
run_test test_index_has_auto_generated_notice

# Timeline
run_test test_session_start_appends_to_timeline

# ============================================================================
# session-start.sh: CS_FRESH_REBIND signal — tailored additionalContext when
# the user declined to resume the prior conversation
# ============================================================================

test_session_start_fresh_rebind_injects_clean_break_notice() {
    session_start_setup

    local output context
    output=$(CS_FRESH_REBIND=1 \
        echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_FRESH_REBIND=1 bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! echo "$context" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind context block missing"
        echo "  Context tail: $(echo "$context" | tail -8)"
        session_start_teardown
        return 1
    fi
    if ! echo "$context" | grep -q "clean break"; then
        echo "  FAIL: fresh-rebind block should mention the clean break"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_without_fresh_rebind_omits_clean_break_notice() {
    session_start_setup

    # No CS_FRESH_REBIND env — context must NOT include the block.
    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if echo "$context" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind block must not appear when CS_FRESH_REBIND is unset"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

run_test test_session_start_fresh_rebind_injects_clean_break_notice
run_test test_session_start_without_fresh_rebind_omits_clean_break_notice
run_test test_session_end_appends_to_timeline
run_test test_timeline_events_are_valid_jsonl
run_test test_timeline_subagent_skipped

# Session end: updated timestamp
run_test test_session_end_never_stamps_readme
run_test test_session_end_generates_index_with_many_changes
run_test test_session_end_leaves_legacy_updated_line_alone

# ============================================================================
# Retired-hooks cleanup (install.sh + run_uninstall)
# ============================================================================

test_retired_hooks_strip_settings_json() {
    # Settings.json with one retired hook (PreCompact only) and one current hook (PostToolUse)
    local settings='{"hooks":{"PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local p="$HOME/.claude/hooks/discoveries-archiver.sh"
    local t="~/.claude/hooks/discoveries-archiver.sh"
    local stripped
    stripped=$(echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
            | .hooks |= with_entries(select(.value | length > 0))
            | if .hooks == {} then del(.hooks) else . end
        else . end
    ')
    if echo "$stripped" | jq -e '.hooks.PreCompact' >/dev/null 2>&1; then
        echo "  FAIL: PreCompact event should be empty/gone after stripping its only (retired) hook"
        echo "  got: $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[0].command' >/dev/null 2>&1; then
        echo "  FAIL: PostToolUse should still have its (current) hook after stripping unrelated retired"
        return 1
    fi
}

test_retired_hooks_strip_preserves_coexisting_hook() {
    # Two hooks under SAME event — one retired, one current. Only the retired should be stripped.
    local settings='{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10},{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local p="$HOME/.claude/hooks/discoveries-archiver.sh"
    local t="~/.claude/hooks/discoveries-archiver.sh"
    local stripped
    stripped=$(echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
        else . end
    ')
    local remaining_count
    remaining_count=$(echo "$stripped" | jq '.hooks.PostToolUse[0].hooks | length')
    if [ "$remaining_count" != "1" ]; then
        echo "  FAIL: expected 1 hook to remain in PostToolUse[0], got $remaining_count"
        echo "  $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[] | select(.command | contains("discovery-commits"))' >/dev/null 2>&1; then
        echo "  FAIL: discovery-commits entry should remain"
        return 1
    fi
}

run_test test_retired_hooks_strip_settings_json
run_test test_retired_hooks_strip_preserves_coexisting_hook

# ============================================================================
# install.sh: cs-hook merge must preserve co-shipped non-cs entries inside
# the same {hooks: [...]} wrapper. Spec tests — embed the exact jq filter
# install.sh must use.
# ============================================================================

# Filter shape documented here as the source of truth. install.sh's 12
# event-specific filters must follow the same pattern: dive into nested
# .hooks, strip only the matching command, drop wrappers that emptied out,
# leave flat or unrelated wrappers untouched, then append the cs entry.
_install_merge_filter() {
    cat << 'JQ'
.hooks[$event] = (
    ((.hooks[$event] // []) | map(
        if .hooks then
            .hooks |= map(select(.command != $path and .command != $tilde))
        else . end
    ) | map(select(.hooks == null or (.hooks | length > 0))))
    + [{ "hooks": [{ "type": "command", "command": $tilde, "timeout": $timeout }] }]
)
JQ
}

test_install_preserves_coshipped_hook_in_wrapper() {
    # User has a non-cs hook co-located inside the same wrapper as cs's hook.
    # Common pattern when the user hand-edited settings.json to add another
    # hook next to cs's. The merge must NOT drop the user's hook.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings
    settings=$(cat << EOF
{"hooks":{"SessionStart":[{"hooks":[
  {"type":"command","command":"~/bin/claude-status","timeout":5},
  {"type":"command","command":"$tilde","timeout":30}
]}]}}
EOF
)
    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local user_hook_count
    user_hook_count=$(echo "$result" | jq '[.. | objects | select(.command == "~/bin/claude-status")] | length')
    if [ "$user_hook_count" != "1" ]; then
        echo "  FAIL: claude-status should survive merge exactly once, got $user_hook_count"
        echo "  Result: $result"
        return 1
    fi

    local cs_hook_count
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')
    if [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: cs hook should appear exactly once, got $cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_drops_emptied_wrapper_when_only_cs_hook_present() {
    # Pre-existing standalone wrapper containing only cs's hook. After merge,
    # we want exactly one wrapper containing one cs entry — not two.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local wrapper_count cs_hook_count
    wrapper_count=$(echo "$result" | jq '.hooks.SessionStart | length')
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')

    if [ "$wrapper_count" != "1" ] || [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: expected 1 wrapper + 1 cs entry; got wrappers=$wrapper_count cs_entries=$cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_leaves_flat_entries_alone() {
    # Old-shape flat entries (no .hooks nesting) must pass through untouched.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"type":"command","command":"~/bin/claude-status","timeout":5}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    if ! echo "$result" | jq -e '.hooks.SessionStart[] | select(.command == "~/bin/claude-status")' >/dev/null; then
        echo "  FAIL: flat-shape claude-status entry was dropped"
        echo "  Result: $result"
        return 1
    fi
}

run_test test_install_preserves_coshipped_hook_in_wrapper
run_test test_install_drops_emptied_wrapper_when_only_cs_hook_present
run_test test_install_leaves_flat_entries_alone

# ============================================================================
# session-start.sh: the actor identity anchor
#
# .cs/memory/ is one shared store for every actor on a git-synced session, but
# only narratives are partitioned. A `type: user` memory written by one actor
# ("the user is X, not Y") loads for all of them and reads as settled fact.
# Naming the current actor up front is what keeps identity a question the live
# signals answer, instead of one a stale memory has already closed.
# ============================================================================

_identity_hook() {  # [source]
    echo "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"${1:-startup}\"}" \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}

_seed_identity_git() {  # email
    git -C "$CLAUDE_SESSION_DIR" init -q 2>/dev/null || mkdir -p "$CLAUDE_SESSION_DIR"
    git -C "$CLAUDE_SESSION_DIR" config user.email "$1" 2>/dev/null
}

test_session_start_names_the_current_actor() {
    _seed_identity_git "john.doe@example.com"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "john.doe@example.com" \
        "the actor's identity is stated, not left to be looked up" || return 1
    assert_output_contains "$out" "narrative.john-doe-example-com.md" \
        "the actor's own narrative file is named" || return 1
}

test_session_start_warns_that_memory_is_shared() {
    _seed_identity_git "john.doe@example.com"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "shared by multiple actors" \
        "the store's multi-actor nature is disclosed" || return 1
    assert_output_contains "$out" "was written by or for another actor" \
        "a conflicting identity memory has an explicit resolution rule" || return 1
}

# A pinned .cs/local/identity outranks git config, matching cs_actor_slug's
# precedence. Without this the anchor would name the wrong person on a machine
# whose git identity differs from the session's pinned one.
test_session_start_actor_honours_pinned_identity() {
    _seed_identity_git "john.doe@example.com"
    printf 'jane.roe@example.com\n' > "$CLAUDE_SESSION_META_DIR/local/identity"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "jane.roe@example.com" \
        "pinned identity outranks git config" || return 1
    assert_output_not_contains "$out" "john.doe@example.com" \
        "the overridden git identity is not also announced" || return 1
}

# cs_actor_slug() ends its search on the identity file EXISTING, not on it
# yielding a value, so a blank pin resolves to "unknown" with no git fallback.
# The hook must stop at the same place: naming an actor cs never resolves would
# point Claude at a narrative file cs does not write.
test_session_start_actor_matches_cs_on_a_blank_pin() {
    _seed_identity_git "john.doe@example.com"
    printf '' > "$CLAUDE_SESSION_META_DIR/local/identity"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "Current actor: unknown" \
        "a blank pin resolves to unknown, as cs_actor_slug does" || return 1
    assert_output_not_contains "$out" "john-doe-example-com" \
        "a blank pin must not fall through to git config" || return 1
}

run_test test_session_start_names_the_current_actor
test_session_start_arms_the_mail_watcher() {
    session_start_setup
    # A session that has never exchanged mail has no maildir, and the watcher is
    # handed its path with no existence check: armed on a path missing two
    # levels it never fires again for the process's lifetime. So the fixture
    # must start without one, which is the state of every fresh spawn worker.
    [ ! -d "$CLAUDE_SESSION_META_DIR/local/mail" ] \
        || { echo "  fixture already had a maildir; the test would prove nothing"; session_start_teardown; return 1; }

    local output rc=0
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    assert_dir "$CLAUDE_SESSION_META_DIR/local/mail/new" \
        "session start creates the maildir before asking for it to be watched" || rc=1
    local wp
    wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths[0] // ""')
    # Assert which directory the watch lands on, not how it is spelled. Under
    # a path can reach jq through argv translation and come back spelled as a
    # different absolute form for the same directory
    # there. A string compare fails on the spelling while the watch is armed on
    # exactly the right place, so prove identity with a file instead.
    if [ -z "$wp" ]; then
        echo "  FAIL: watchPaths is empty; the maildir was never armed"; rc=1
    else
        local token="watch-probe-$$"
        : > "$CLAUDE_SESSION_META_DIR/local/mail/new/$token"
        [ -f "$wp/$token" ] \
            || { echo "  FAIL: watchPaths does not name the maildir session start created"
                 echo "    watchPaths: $wp"
                 echo "    maildir   : $CLAUDE_SESSION_META_DIR/local/mail/new"; rc=1; }
        rm -f "$CLAUDE_SESSION_META_DIR/local/mail/new/$token"
    fi
    session_start_teardown
    return $rc
}

test_session_start_does_not_arm_the_watcher_for_a_teammate() {
    session_start_setup
    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | env -u CS_LEAD_PID -u CLAUDE_PID bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    local wp; wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths // "none"')
    session_start_teardown
    assert_eq "none" "$wp" \
        "a teammate arms no watcher: one arrival must not wake every claude on the session" || return 1
}

run_test test_session_start_arms_the_mail_watcher
run_test test_session_start_does_not_arm_the_watcher_for_a_teammate
run_test test_session_start_warns_that_memory_is_shared
run_test test_session_start_actor_honours_pinned_identity
run_test test_session_start_actor_matches_cs_on_a_blank_pin

# CS_SESSIONS_ROOT is read by session-end.sh but never exported into a session,
# so `dirname "$SESSION_DIR"` always decides. That is right for a session under
# the sessions root and wrong for an adopted one, whose real directory lives at
# an unrelated project path: the index then lands in that project's parent.
test_session_end_does_not_write_index_beside_an_adopted_session() {
    local proj="$TEST_TMPDIR/code/my-project"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    printf 'session_name: adopted-one\n' > "$proj/.cs/local/state"
    printf -- '---\nstatus: active\ncreated: 2026-07-30\n---\n# Session: adopted-one\n' > "$proj/.cs/README.md"

    unset CS_SESSIONS_ROOT
    export CLAUDE_SESSION_NAME="adopted-one"
    export CLAUDE_SESSION_DIR="$proj"
    export CLAUDE_SESSION_META_DIR="$proj/.cs"

    echo "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    [ ! -f "$TEST_TMPDIR/code/index.md" ] \
        || { echo "  FAIL: index.md written into the adopted project's parent"; return 1; }
}

run_test test_session_end_does_not_write_index_beside_an_adopted_session

# The containment check compares SESSION_DIR against the sessions root. The
# resolver reports physical paths but the CLI exports a logical SESSION_DIR
# built from $HOME, so normalizing only one side stops the index being written
# for any home reached through a symlink (/home -> /var/home, and every
# /tmp-based test environment).
test_session_end_writes_index_when_home_traverses_a_symlink() {
    local fh="$TEST_TMPDIR/symhome" phys
    mkdir -p "$fh/.claude-sessions/sess/.cs/local"
    printf -- '---\nstatus: active\ncreated: 2026-07-30\n---\n# Session: sess\n' \
        > "$fh/.claude-sessions/sess/.cs/README.md"
    phys=$(cd "$fh" && pwd -P)

    env -i HOME="$fh" PATH="$PATH" \
        CLAUDE_SESSION_NAME=sess CLAUDE_SESSION_DIR="$fh/.claude-sessions/sess" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$fh\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ -f "$phys/.claude-sessions/index.md" ] \
        || { echo "  FAIL: index not written when \$HOME traverses a symlink"; return 1; }
}

run_test test_session_end_writes_index_when_home_traverses_a_symlink

# The sessions-root default reads $HOME, which main never did, so under set -u an
# unset HOME turns a step that should skip into an abort. cs-resolve.sh already
# guards HOME; this must match it.
test_session_end_survives_an_unset_home() {
    local proj="$TEST_TMPDIR/nohome/sess"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    env -i PATH="$PATH" CLAUDE_SESSION_NAME=sess CLAUDE_SESSION_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: session-end exited $rc with HOME unset"; return 1; }
}

run_test test_session_end_survives_an_unset_home

# Before hooks resolved a session from the directory, a second front end never
# reached SessionEnd for a session it did not launch. Now closing a desktop
# conversation on a directory a CLI session is live in would remove that
# session's lock, so `cs <name>` opens a duplicate with no collision menu.
test_session_end_spares_a_live_sessions_lock() {
    local proj="$TEST_TMPDIR/lockheld"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    # $$ is this test runner: a PID that is definitely alive.
    printf '%s\n' "$$" > "$proj/.cs/session.lock"

    # The real scenario: another front end resolves by WALKING the directory,
    # so no session env is set. A cs launch (env path) still clears its own lock.
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ -f "$proj/.cs/session.lock" ] \
        || { echo "  FAIL: a live session's lock was removed by another front end"; return 1; }
}

# A lock left by a process that is gone is exactly what SessionEnd should clear.
test_session_end_clears_a_stale_lock() {
    local proj="$TEST_TMPDIR/lockstale"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    # A PID that cannot be running: start a shell and let it exit.
    local dead
    dead=$( ( exec /bin/bash -c 'echo $$' ) )
    printf '%s\n' "$dead" > "$proj/.cs/session.lock"

    env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ ! -f "$proj/.cs/session.lock" ] \
        || { echo "  FAIL: a stale lock was left behind"; return 1; }
}

run_test test_session_end_spares_a_live_sessions_lock
run_test test_session_end_clears_a_stale_lock


# --- A torn JSONL tail must not take the next record down with it ---
# A process killed mid-append leaves a last line with no newline. The next `>>`
# then splices two records onto one line, and cs's tolerant per-line reader drops
# the spliced line whole — losing the torn record AND the intact one after it.

test_session_end_does_not_splice_onto_a_torn_timeline() {
    session_start_setup
    printf '{"ts":"2026-01-01T00:00:00Z","event":"started","session_id":"1111"}\n' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    printf '{"ts":"2026-01-02T00:00:00Z","event":"checkpoint","label":"torn"}' \
        >> "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated; the splice cannot happen"; session_start_teardown; return 1; }

    echo '{"session_id":"3333","source":"user_exit"}' \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "checkpoint" "the torn record survives" \
        || { session_start_teardown; return 1; }
    assert_output_contains "$events" "ended" "and so does the record appended after it" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_session_start_does_not_splice_onto_a_torn_timeline() {
    session_start_setup
    printf '{"ts":"2026-01-02T00:00:00Z","event":"checkpoint","label":"torn"}' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated; the splice cannot happen"; session_start_teardown; return 1; }

    echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "checkpoint" "the torn record survives" \
        || { session_start_teardown; return 1; }
    assert_output_contains "$events" "started" "and so does the record appended after it" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_torn_partial_record_costs_only_itself() {
    # The realistic crash leaves a PARTIAL record, not a whole one missing its
    # newline. That record is unrecoverable by design — it was never complete —
    # but the guard still bounds the damage to one record instead of two.
    session_start_setup
    printf '{"ts":"2026-01-01T00:00:00Z","event":"sta' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated"; session_start_teardown; return 1; }

    echo '{"session_id":"3333","source":"user_exit"}' \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "ended" "the new record parses on its own line" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_hook_terminator_survives_a_missing_resolver_library() {
    # An install whose hooks were not redeployed pairs a NEW bin/cs with OLD
    # hooks. Each hook therefore defines its own fallback beside the existing
    # cs_resolve_session one, so the two hottest writers cannot go back to
    # splicing silently when the shared library is absent.
    assert_file_contains "$HOOKS_DIR/session-start.sh" "command -v _cs_terminate_jsonl" \
        "session-start defines a fallback terminator" || return 1
    assert_file_contains "$HOOKS_DIR/session-end.sh" "command -v _cs_terminate_jsonl" \
        "session-end defines a fallback terminator" || return 1
    assert_file_contains "$HOOKS_DIR/cs-resolve.sh" "_cs_terminate_jsonl" \
        "the shared library carries the canonical definition" || return 1
}

run_test test_session_end_does_not_splice_onto_a_torn_timeline
run_test test_session_start_does_not_splice_onto_a_torn_timeline
run_test test_torn_partial_record_costs_only_itself
run_test test_hook_terminator_survives_a_missing_resolver_library


# --- Session State must not manufacture escape sequences out of plain text ---

test_session_state_does_not_interpret_backslash_escapes_in_content() {
    # The block was emitted through `printf '%b'`, which INTERPRETS backslash
    # escapes — so a README objective containing the five literal characters
    # backslash-0-3-3 was converted by cs itself into a real ESC byte. The text
    # was inert on disk; cs made it dangerous. That is worse than the raw-byte
    # case, where a writer has to smuggle a control character in.
    session_start_setup
    printf '# test-session\n\n## Objective\n\nship \\033[31mred\\033[0m thing\n' \
        > "$CLAUDE_SESSION_META_DIR/README.md"
    # Fixture sanity: the file holds NO control byte, only printable characters.
    local on_disk
    on_disk=$(LC_ALL=C tr -dc "$(printf '\033\007')" < "$CLAUDE_SESSION_META_DIR/README.md" | wc -c | tr -d '[:space:]')
    [ "$on_disk" = "0" ] || {
        echo "  FAIL: fixture already contains a control byte; the test would pass for the wrong reason"
        session_start_teardown; return 1
    }

    local output context esc
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "the block must be reached, or nothing is being tested" || { session_start_teardown; return 1; }
    esc=$(printf '%s' "$context" | LC_ALL=C tr -dc "$(printf '\033\007')" | wc -c | tr -d '[:space:]')
    assert_eq "0" "$esc" \
        "cs must not convert literal backslash-033 in content into a real escape byte" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_session_state_scrubs_a_real_control_byte_in_content() {
    # The other half: a README that really does carry a raw ESC — written by
    # another session, or pasted — must not reach the terminal with it.
    session_start_setup
    printf '# test-session\n\n## Objective\n\nship \033[31mred\033[0m thing\n' \
        > "$CLAUDE_SESSION_META_DIR/README.md"
    local on_disk
    on_disk=$(LC_ALL=C tr -dc "$(printf '\033')" < "$CLAUDE_SESSION_META_DIR/README.md" | wc -c | tr -d '[:space:]')
    [ "$on_disk" != "0" ] || {
        echo "  FAIL: fixture carries no raw ESC; the scrub is not being exercised"
        session_start_teardown; return 1
    }

    local output context esc
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "the block must be reached" || { session_start_teardown; return 1; }
    esc=$(printf '%s' "$context" | LC_ALL=C tr -dc "$(printf '\033')" | wc -c | tr -d '[:space:]')
    assert_eq "0" "$esc" "a raw control byte in content must be scrubbed" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_session_state_still_renders_its_own_line_breaks() {
    # The fix removes %b, so cs's OWN newlines must survive the change — the
    # block is multi-line and a regression would fuse it into one line.
    session_start_setup
    local output context lines
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" "the block renders" \
        || { session_start_teardown; return 1; }
    assert_output_not_contains "$context" 'Objective:.*\\n' \
        "a literal backslash-n must never survive into the rendered block" \
        || { session_start_teardown; return 1; }
    lines=$(printf '%s' "$context" | sed -n '/--- Session State ---/,$p' | grep -c .)
    [ "${lines:-0}" -ge 2 ] \
        || { echo "  FAIL: Session State collapsed to $lines line(s); cs's own newlines were lost"
             session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_state_does_not_interpret_backslash_escapes_in_content
run_test test_session_state_scrubs_a_real_control_byte_in_content
run_test test_session_state_still_renders_its_own_line_breaks

# ============================================================================
# session-start.sh: publishing the session contract to the conversation
# ============================================================================

# CLAUDE_ENV_FILE is how a SessionStart hook hands variables to the rest of the
# session. `cs` has already exported the contract before exec, so the write is
# what carries it where the launch could not reach.
test_session_start_publishes_the_contract_for_a_cs_launch() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile"
    : > "$envfile"

    CLAUDE_ENV_FILE="$envfile" bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1

    assert_file_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a cs launch publishes its own contract" || { session_start_teardown; return 1; }
    session_start_teardown
}

# A front end that reached the session by walking the directory it opened is
# not the one cs launched, and the lock, the recorded conversation and the
# index all key off that difference. Publishing the contract into such a
# session would erase the distinction for every hook that fires after it.
test_session_start_withholds_the_contract_from_a_walked_in_front_end() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile" dir="$CLAUDE_SESSION_DIR"
    : > "$envfile"

    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CLAUDE_CODE_ENTRYPOINT="claude-desktop" CLAUDE_PROJECT_DIR="$dir" \
        CLAUDE_ENV_FILE="$envfile" \
        bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$dir"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1

    assert_file_not_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a walked-in front end must not publish the contract" || { session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_start_publishes_the_contract_for_a_cs_launch
run_test test_session_start_withholds_the_contract_from_a_walked_in_front_end

# A teammate resolves by walking, and is the one walked-in front end that needs
# the contract: its own `cs -secrets`, `cs -msg` and status line read the
# session out of the environment. What must survive is that it is not the
# launch, which session-end.sh reads to decide whether it owns the lock.
test_session_start_publishes_the_contract_to_a_teammate() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile" dir="$CLAUDE_SESSION_DIR" script="$TEST_TMPDIR/fake-claude.sh"
    : > "$envfile"
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$script"; chmod +x "$script"
    "$script" --agent-id a1 --agent-name mate --team-name t >/dev/null 2>&1 &
    local pid=$! i=0
    while [ "$i" -lt 50 ]; do
        ps -o args= -p "$pid" 2>/dev/null | grep -q fake-claude && break
        i=$((i + 1)); sleep 0.1
    done

    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CLAUDE_CODE_ENTRYPOINT="cli" CLAUDE_PID="$pid" CLAUDE_PROJECT_DIR="$dir" \
        CLAUDE_ENV_FILE="$envfile" \
        bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$dir"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1
    kill "$pid" 2>/dev/null

    assert_file_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a teammate needs the session in its own environment" || { session_start_teardown; return 1; }
    assert_file_contains "$envfile" "CS_RESOLVED_FROM=\"walk\"" \
        "and must stay marked as not being the launch" || { session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_start_publishes_the_contract_to_a_teammate

report_results
