#!/usr/bin/env bash
# ABOUTME: Tests for conversation rotation: the rotated timeline event, the
# ABOUTME: handoff handshake (prompt, consumption), the context nudge, and cs -conversations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

UUID_A="11111111-1111-4111-8111-111111111111"
UUID_B="22222222-2222-4222-8222-222222222222"

# Args-echoing claude stub; exits 1 on --resume when $1 = fail-resume.
_stub_claude() {  # [fail-resume]
    local mode="${1:-}"
    if [ "$mode" = "fail-resume" ]; then
        cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
case "$*" in *--resume*) exit 1;; esac
echo "STUB_ARGS: $*"
exit 0
SCRIPT
    else
        cat > "$TEST_TMPDIR/claude-stub" << 'SCRIPT'
#!/bin/bash
echo "STUB_ARGS: $*"
exit 0
SCRIPT
    fi
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

# Create a real session via cs itself (is_new=true launches without a prompt;
# the stub exits immediately). Returns nothing; the dir is $CS_SESSIONS_ROOT/$1.
_rot_session() {  # name
    _stub_claude
    "$CS_BIN" "$1" </dev/null >/dev/null 2>&1 || true
}

# Ambient env + session dir for driving hooks directly (no cs launch).
_rot_hook_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
}

_timeline() { cat "$CLAUDE_SESSION_META_DIR/timeline.jsonl" 2>/dev/null; }

# ============================================================================
# Cycle 1: rotated event emission
# ============================================================================

test_hook_mismatch_emits_rebind_event() {
    _rot_hook_session "rot-hook"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    echo "{\"session_id\":\"$UUID_B\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"resume\"}" \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null)
    [ -n "$ev" ] || { echo "  FAIL: no rotated event emitted"; return 1; }
    assert_output_contains "$ev" "\"from\":\"$UUID_A\"" "event carries the old UUID" || return 1
    assert_output_contains "$ev" "\"to\":\"$UUID_B\"" "event carries the new UUID" || return 1
    assert_output_contains "$ev" '"reason":"rebind"' "hook-discovered change is a rebind" || return 1
}

test_hook_matching_uuid_emits_nothing() {
    _rot_hook_session "rot-hook-same"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    echo "{\"session_id\":\"$UUID_A\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"resume\"}" \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    local n
    n=$(_timeline | grep -c '"event":"rotated"' 2>/dev/null || true)
    assert_eq "0" "$n" "matching UUIDs must not emit a rotated event" || return 1
}

test_decline_resume_emits_declined_event() {
    _rot_session "rot-decline"
    local dir="$CS_SESSIONS_ROOT/rot-decline"
    local old
    old=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    "$CS_BIN" rot-decline <<< "n" >/dev/null 2>&1 || true
    local new
    new=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    [ "$new" != "$old" ] || { echo "  FAIL: decline did not rebind"; return 1; }
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"declined-resume"' "decline reason recorded" || return 1
    assert_output_contains "$ev" "\"from\":\"$old\"" "old UUID recorded" || return 1
    assert_output_contains "$ev" "\"to\":\"$new\"" "new UUID recorded" || return 1
}

test_resume_failure_emits_resume_failed_event() {
    _rot_session "rot-fail"
    local dir="$CS_SESSIONS_ROOT/rot-fail"
    _stub_claude fail-resume
    "$CS_BIN" rot-fail <<< "" >/dev/null 2>&1 || true
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"resume-failed"' "fast resume failure recorded" || return 1
}

run_test test_hook_mismatch_emits_rebind_event
run_test test_hook_matching_uuid_emits_nothing
run_test test_decline_resume_emits_declined_event
run_test test_resume_failure_emits_resume_failed_event

# ============================================================================
# Cycle 2: the rotate skill ships and is registered
# ============================================================================

test_rotate_skill_exists_with_frontmatter() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    [ -f "$skill" ] || { echo "  FAIL: skills/rotate/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$skill")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$skill" "name: rotate" "frontmatter names the skill" || return 1
    assert_file_contains "$skill" "description:" "frontmatter has a description" || return 1
    assert_file_contains "$skill" "status: unconsumed" "skill teaches the frontmatter contract" || return 1
    assert_file_contains "$skill" ".cs/handoffs/" "skill targets the tracked handoff store" || return 1
}

test_rotate_skill_registered_in_both_manifests() {
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../lib/00-header.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from lib/00-header.sh CS_SKILLS"; return 1; }
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../install.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from install.sh CS_SKILLS"; return 1; }
}

run_test test_rotate_skill_exists_with_frontmatter
run_test test_rotate_skill_registered_in_both_manifests

# ============================================================================
# Cycle 3: three-way launch prompt
# ============================================================================

_seed_handoff() {  # session_dir, basename, status
    mkdir -p "$1/.cs/handoffs"
    cat > "$1/.cs/handoffs/$2" << EOF
---
parent: $UUID_A
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: $3
---

## 7. Next Step
Continue the test.
EOF
}

test_prompt_unchanged_without_handoff() {
    _rot_session "rot-plain"
    local output
    output=$("$CS_BIN" rot-plain <<< "n" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "prompt present" || return 1
    printf '%s' "$output" | grep -q '\[Y/n\] ' \
        || { echo "  FAIL: two-way prompt suffix must stay byte-identical"; return 1; }
    if printf '%s' "$output" | grep -q '\[Y/n/r\]'; then
        echo "  FAIL: three-way prompt must not appear without a pending handoff"
        return 1
    fi
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: pending notice must not appear without a pending handoff"
        return 1
    fi
}

test_rotate_answer_consumes_pending_handoff() {
    _rot_session "rot-r"
    local dir="$CS_SESSIONS_ROOT/rot-r"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    local old
    old=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    local output
    output=$("$CS_BIN" rot-r <<< "r" 2>&1) || true
    assert_output_contains "$output" "Rotation handoff pending" "notice names the pending handoff" || return 1
    assert_output_contains "$output" "2026-07-16-test.md" "notice carries the basename" || return 1
    assert_output_contains "$output" "[Y/n/r]" "prompt is three-way" || return 1
    local new
    new=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    [ "$new" != "$old" ] || { echo "  FAIL: r must rebind to a fresh UUID"; return 1; }
    assert_eq "2026-07-16-test.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "marker names the handoff for the SessionStart hook" || return 1
    assert_output_contains "$output" "STUB_ARGS: " "stub launched" || return 1
    assert_output_contains "$output" "--session-id $new" "fresh conversation via --session-id" || return 1
    local ev
    ev=$(jq -c 'select(.event == "rotated")' "$dir/.cs/timeline.jsonl" 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"handoff"' "deliberate rotation reason" || return 1
    assert_output_contains "$ev" '"handoff":"2026-07-16-test.md"' "event names the handoff" || return 1
}

test_continue_and_no_leave_handoff_unconsumed() {
    _rot_session "rot-yn"
    local dir="$CS_SESSIONS_ROOT/rot-yn"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    "$CS_BIN" rot-yn <<< "n" >/dev/null 2>&1 || true
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: unconsumed" \
        "n leaves the handoff pending" || return 1
    [ ! -f "$dir/.cs/local/pending-handoff" ] || { echo "  FAIL: n must not set the marker"; return 1; }
}

test_consumed_handoffs_do_not_trigger_prompt() {
    _rot_session "rot-consumed"
    local dir="$CS_SESSIONS_ROOT/rot-consumed"
    _seed_handoff "$dir" "2026-07-16-done.md" "consumed"
    local output
    output=$("$CS_BIN" rot-consumed <<< "n" 2>&1) || true
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: consumed handoff must not resurface"
        return 1
    fi
}

test_newest_of_multiple_handoffs_wins() {
    _rot_session "rot-multi"
    local dir="$CS_SESSIONS_ROOT/rot-multi"
    _seed_handoff "$dir" "2026-07-14-old.md" "unconsumed"
    _seed_handoff "$dir" "2026-07-16-new.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-multi <<< "r" 2>&1) || true
    assert_eq "2026-07-16-new.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "lexicographically last basename wins" || return 1
    assert_file_contains "$dir/.cs/handoffs/2026-07-14-old.md" "status: unconsumed" \
        "older handoff untouched" || return 1
}

run_test test_prompt_unchanged_without_handoff
run_test test_rotate_answer_consumes_pending_handoff
run_test test_continue_and_no_leave_handoff_unconsumed
run_test test_consumed_handoffs_do_not_trigger_prompt
run_test test_newest_of_multiple_handoffs_wins

report_results
