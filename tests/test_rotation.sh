#!/usr/bin/env bash
# ABOUTME: Tests for conversation rotation: the rotated timeline event, the
# ABOUTME: handoff handshake (prompt, consumption), the context nudge, and cs -conversations.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Launch-gated suite: on a real MSYS runner the Claude launch short-circuits
# (Tier 2 = session management only), so pin a supported platform there. See
# _apply_suite_platform_pin in test_lib.sh (no-op on macOS/Linux lanes).
SUITE_PIN_NONMSYS=1

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
    if printf '%s' "$output" | grep -q '\[Y/n/r/d\]'; then
        echo "  FAIL: handoff prompt must not appear without a pending handoff"
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
    assert_output_contains "$output" "\[Y/n/r/d\]" "prompt offers the handoff answers" || return 1
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

# The r launch auto-starts the handoff: its positional prompt is the handoff
# continuation (displacing the /color re-apply for this one launch), so the fresh
# conversation reads the handoff and continues without the user typing first.
test_rotate_answer_auto_starts_handoff() {
    _rot_session "rot-autostart"
    local dir="$CS_SESSIONS_ROOT/rot-autostart"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-autostart <<< "r" 2>&1) || true
    assert_output_contains "$output" ".cs/handoffs/2026-07-16-test.md" \
        "the launch prompt points claude at the pending handoff" || return 1
    if printf '%s' "$output" | grep -q -- '/color'; then
        echo "  FAIL: the handoff prompt must displace /color for this launch"
        return 1
    fi
    return 0
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

test_discard_answer_dismisses_pending_handoff() {
    _rot_session "rot-d"
    local dir="$CS_SESSIONS_ROOT/rot-d"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-d <<< "d" 2>&1) || true
    printf '%s' "$output" | grep -q "d = discard handoff" \
        || { echo "  FAIL: prompt must offer the d answer"; return 1; }
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: discarded" \
        "d flips the handoff to discarded" || return 1
    assert_file_not_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: unconsumed" \
        "unconsumed line replaced" || return 1
    [ ! -f "$dir/.cs/local/pending-handoff" ] || { echo "  FAIL: d must not set the r marker"; return 1; }
    assert_output_contains "$output" "STUB_ARGS: " "launch continues" || return 1
    printf '%s' "$output" | grep -q -- '--resume' \
        || { echo "  FAIL: d proceeds with the default resume"; return 1; }
    output=$("$CS_BIN" rot-d <<< "n" 2>&1) || true
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: discarded handoff must not re-prompt"
        return 1
    fi
}

test_discard_flip_spares_a_body_quote() {
    _rot_session "rot-dq"
    local dir="$CS_SESSIONS_ROOT/rot-dq"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    printf 'status: unconsumed\n' >> "$dir/.cs/handoffs/2026-07-16-test.md"
    "$CS_BIN" rot-dq <<< "d" >/dev/null 2>&1 || true
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: discarded" \
        "frontmatter status flipped" || return 1
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-test.md" "status: unconsumed" \
        "flush-left body quote untouched" || return 1
}

run_test test_prompt_unchanged_without_handoff
run_test test_rotate_answer_consumes_pending_handoff
run_test test_rotate_answer_auto_starts_handoff
run_test test_continue_and_no_leave_handoff_unconsumed
run_test test_consumed_handoffs_do_not_trigger_prompt
run_test test_newest_of_multiple_handoffs_wins
run_test test_discard_answer_dismisses_pending_handoff
run_test test_discard_flip_spares_a_body_quote

# ============================================================================
# Cycle 4: SessionStart consumes the pending handoff
# ============================================================================

_start_hook() {  # session_id [extra env pre-exported by caller]
    echo "{\"session_id\":\"$1\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"startup\"}" \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}

test_pending_handoff_is_consumed_and_injected() {
    _rot_hook_session "rot-consume"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    assert_output_contains "$out" "Conversation Rotation" "rotation preamble injected" || return 1
    assert_output_contains "$out" ".cs/handoffs/2026-07-16-test.md" "preamble names the handoff path" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: consumed" \
        "frontmatter flipped" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "consumed_by: $UUID_B" \
        "consumer recorded" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] || { echo "  FAIL: marker must be removed"; return 1; }
    assert_output_contains "$out" "managed Claude Code session" "existing context spliced, not replaced" || return 1
}

test_rotation_preamble_wins_over_fresh_rebind_block() {
    _rot_hook_session "rot-precedence"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B") || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    assert_output_contains "$out" "Conversation Rotation" "rotation preamble present" || return 1
    if printf '%s' "$out" | grep -q "Fresh Conversation"; then
        echo "  FAIL: fresh-rebind block must yield to the rotation preamble"
        return 1
    fi
}

test_fresh_rebind_block_survives_without_handoff() {
    _rot_hook_session "rot-fresh-only"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B") || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    assert_output_contains "$out" "Fresh Conversation" "fresh block still fires alone" || return 1
}

test_stale_marker_is_removed_silently() {
    _rot_hook_session "rot-stale"
    printf '%s\n' "2026-01-01-gone.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] || { echo "  FAIL: stale marker must be removed"; return 1; }
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: stale marker must not inject a preamble"
        return 1
    fi
}

test_handoff_with_hostile_purpose_survives_flip() {
    _rot_hook_session "rot-hostile"
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/handoffs"
    cat > "$CLAUDE_SESSION_DIR/.cs/handoffs/2026-07-16-hostile.md" << 'EOF'
---
parent: 11111111-1111-4111-8111-111111111111
created: 2026-07-16T10:00:00Z
purpose: continue "phase 2" of $(dangerous) `work`
status: unconsumed
---

Body with $(subshell) and "quotes".
EOF
    printf '%s\n' "2026-07-16-hostile.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" >/dev/null || return 1
    local f="$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-hostile.md"
    assert_file_contains "$f" "status: consumed" "flip succeeded despite hostile content" || return 1
    assert_file_contains "$f" 'continue "phase 2" of .(dangerous)' "purpose intact (quotes, subshell)" || return 1
    assert_file_contains "$f" 'Body with .(subshell) and "quotes".' "body intact" || return 1
}

run_test test_pending_handoff_is_consumed_and_injected
run_test test_rotation_preamble_wins_over_fresh_rebind_block
run_test test_fresh_rebind_block_survives_without_handoff
run_test test_stale_marker_is_removed_silently
run_test test_handoff_with_hostile_purpose_survives_flip

# ============================================================================
# Cycle 5: context nudge (Stop hook)
# ============================================================================

_stop_with_ctx() {  # ctx-pct-or-empty, session_id
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$CLAUDE_SESSION_META_DIR/local/context-pct"
    else
        rm -f "$CLAUDE_SESSION_META_DIR/local/context-pct"
    fi
    echo "{\"session_id\":\"$2\"}" | bash "$HOOKS_DIR/narrative-reminder.sh"
}

test_nudge_fires_once_at_threshold() {
    _rot_hook_session "rot-nudge"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" '"decision":"block"' "nudge delivered as a block" || return 1
    assert_output_contains "$out" "rotate" "nudge names the rotate skill" || return 1
    assert_output_contains "$out" "80%" "nudge names the reading" || return 1
    assert_eq "$UUID_A" "$(cat "$CLAUDE_SESSION_META_DIR/local/rotate-nudged" | tr -d '[:space:]')" \
        "cursor records the nudged conversation" || return 1
    out=$(_stop_with_ctx 85 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: same conversation must not be nudged twice"
        return 1
    fi
}

test_nudge_rearms_for_new_conversation() {
    _rot_hook_session "rot-nudge-rearm"
    _stop_with_ctx 80 "$UUID_A" >/dev/null || return 1
    local out
    out=$(_stop_with_ctx 80 "$UUID_B") || return 1
    assert_output_contains "$out" "rotate" "new conversation UUID re-arms the nudge" || return 1
}

test_nudge_silent_below_threshold_and_without_signal() {
    _rot_hook_session "rot-nudge-quiet"
    local out
    out=$(_stop_with_ctx 79 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: 79 must not nudge at default threshold"
        return 1
    fi
    out=$(_stop_with_ctx "" "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: missing context-pct must never nudge"
        return 1
    fi
    out=$(_stop_with_ctx "hot" "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: non-numeric context-pct must never nudge"
        return 1
    fi
}

test_nudge_threshold_override() {
    _rot_hook_session "rot-nudge-env"
    export CS_ROTATE_NUDGE_CTX=90
    local out
    out=$(_stop_with_ctx 85 "$UUID_A") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    if printf '%s' "$out" | grep -q "rotate skill"; then
        unset CS_ROTATE_NUDGE_CTX
        echo "  FAIL: 85 under a 90 override must not nudge"
        return 1
    fi
    out=$(_stop_with_ctx 90 "$UUID_A") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    unset CS_ROTATE_NUDGE_CTX
    assert_output_contains "$out" "rotate" "90 at a 90 override nudges" || return 1
    _rot_hook_session "rot-nudge-env2"
    export CS_ROTATE_NUDGE_CTX=banana
    out=$(_stop_with_ctx 80 "$UUID_B") || { unset CS_ROTATE_NUDGE_CTX; return 1; }
    unset CS_ROTATE_NUDGE_CTX
    assert_output_contains "$out" "rotate" "non-numeric override falls back to 80" || return 1
}

test_nudge_yields_to_queue_drain() {
    _rot_hook_session "rot-nudge-queue"
    printf 'task one\n' > "$CLAUDE_SESSION_META_DIR/local/queue"
    printf 'armed\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" "cs task queue" "queue owns the turn loop" || return 1
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: nudge must yield to an armed queue"
        return 1
    fi
}

run_test test_nudge_fires_once_at_threshold
run_test test_nudge_rearms_for_new_conversation
run_test test_nudge_silent_below_threshold_and_without_signal
run_test test_nudge_threshold_override
run_test test_nudge_yields_to_queue_drain

# ============================================================================
# Cycle 6: cs -conversations
# ============================================================================

test_conversations_renders_chain() {
    _rot_hook_session "rot-view"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    cat > "$CLAUDE_SESSION_META_DIR/timeline.jsonl" << EOF
{"ts":"2026-07-14T09:00:00Z","event":"started","source":"startup","session_id":"$UUID_A","branch":"main"}
{"ts":"2026-07-14T12:00:00Z","event":"started","source":"resume","session_id":"$UUID_A","branch":"main"}
{"ts":"2026-07-15T08:00:00Z","event":"checkpoint","label":"x","file":"y","branch":"main"}
{"ts":"2026-07-16T10:00:00Z","event":"rotated","from":"$UUID_A","to":"$UUID_B","reason":"handoff","handoff":"2026-07-16-test.md"}
{"ts":"2026-07-16T10:00:05Z","event":"started","source":"startup","session_id":"$UUID_B","branch":"main"}
EOF
    local out
    out=$("$CS_BIN" -conversations 2>&1) || return 1
    assert_output_contains "$out" "11111111  started (startup, resumed 1x)" "first conversation folds resumes" || return 1
    assert_output_contains "$out" "11111111 > 22222222  rotated (handoff: 2026-07-16-test.md)" "rotation arrow with handoff" || return 1
    assert_output_contains "$out" "[current]" "live conversation marked" || return 1
    if printf '%s' "$out" | grep -q "checkpoint"; then
        echo "  FAIL: non-conversation events must not render"
        return 1
    fi
}

test_conversations_empty_timeline() {
    _rot_hook_session "rot-view-empty"
    rm -f "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    local out
    out=$("$CS_BIN" -conversations 2>&1) || return 1
    assert_output_contains "$out" "No conversation history recorded." "empty message" || return 1
}

test_conversations_requires_session_context() {
    local out rc=0
    out=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR "$CS_BIN" -conversations 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: must error outside a session"; return 1; }
    assert_output_contains "$out" "inside a cs session" "error names the requirement" || return 1
}

test_conversations_session_scoped_form() {
    _rot_hook_session "rot-view-scoped"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    printf '{"ts":"2026-07-14T09:00:00Z","event":"started","source":"startup","session_id":"%s","branch":"main"}\n' "$UUID_A" \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    local out
    out=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR \
        "$CS_BIN" rot-view-scoped -conversations 2>&1) || return 1
    assert_output_contains "$out" "11111111  started (startup)" "scoped form renders" || return 1
}

run_test test_conversations_renders_chain
run_test test_conversations_empty_timeline
run_test test_conversations_requires_session_context
run_test test_conversations_session_scoped_form

# ============================================================================
# Cycle 7: final-review fixes — rebind ordering (I1), frontmatter scoping (M-new)
# ============================================================================

test_rebind_orders_rotated_before_started() {
    _rot_hook_session "rot-order"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    echo "{\"session_id\":\"$UUID_B\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"resume\"}" \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    local rotated_line started_line
    rotated_line=$(grep -n '"event":"rotated"' "$CLAUDE_SESSION_META_DIR/timeline.jsonl" | head -1 | cut -d: -f1)
    started_line=$(grep -n "\"event\":\"started\".*\"session_id\":\"$UUID_B\"" "$CLAUDE_SESSION_META_DIR/timeline.jsonl" | head -1 | cut -d: -f1)
    [ -n "$rotated_line" ] || { echo "  FAIL: no rotated line found in timeline.jsonl"; return 1; }
    [ -n "$started_line" ] || { echo "  FAIL: no started line for $UUID_B found in timeline.jsonl"; return 1; }
    if [ "$rotated_line" -ge "$started_line" ]; then
        echo "  FAIL: rotated event (line $rotated_line) must precede the new conversation's started event (line $started_line)"
        return 1
    fi

    local out
    out=$("$CS_BIN" -conversations 2>&1) || return 1
    local arrow_line started_out_line
    arrow_line=$(printf '%s\n' "$out" | awk '/ > /{print NR; exit}')
    started_out_line=$(printf '%s\n' "$out" | awk '/22222222  started/{print NR; exit}')
    [ -n "$arrow_line" ] || { echo "  FAIL: no rotated arrow line in cs -conversations output"; return 1; }
    [ -n "$started_out_line" ] || { echo "  FAIL: no '22222222  started' line in cs -conversations output"; return 1; }
    if [ "$arrow_line" -ge "$started_out_line" ]; then
        echo "  FAIL: rendered rotated arrow (line $arrow_line) must precede the started line (line $started_out_line)"
        return 1
    fi
}

run_test test_rebind_orders_rotated_before_started

# A handoff's body may legitimately quote the frontmatter contract (the
# rotate skill's own doc does). The launch-side scan must only look at the
# frontmatter block, not the whole file.
_seed_handoff_body_echoes_contract() {  # session_dir, basename, frontmatter_status
    mkdir -p "$1/.cs/handoffs"
    cat > "$1/.cs/handoffs/$2" << EOF
---
parent: $UUID_A
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: $3
---

## 3. Contract
The handoff frontmatter must contain a line reading exactly:
status: unconsumed

## 7. Next Step
Continue the test.
EOF
}

test_launch_grep_ignores_body_status_line() {
    _rot_session "rot-body-consumed"
    local dir="$CS_SESSIONS_ROOT/rot-body-consumed"
    _seed_handoff_body_echoes_contract "$dir" "2026-07-16-consumed.md" "consumed"
    local output
    output=$("$CS_BIN" rot-body-consumed <<< "n" 2>&1) || true
    if printf '%s' "$output" | grep -q "Rotation handoff pending"; then
        echo "  FAIL: consumed handoff must not resurface because its body echoes the contract line"
        return 1
    fi
}

test_launch_grep_scoped_to_frontmatter_and_body_survives_consumption() {
    _rot_session "rot-body-unconsumed"
    local dir="$CS_SESSIONS_ROOT/rot-body-unconsumed"
    _seed_handoff_body_echoes_contract "$dir" "2026-07-16-active.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-body-unconsumed <<< "r" 2>&1) || true
    assert_output_contains "$output" "Rotation handoff pending" "genuinely unconsumed handoff is still offered" || return 1
    assert_output_contains "$output" "2026-07-16-active.md" "notice names the handoff" || return 1

    local new
    new=$(awk '/^claude_session_id:/ { print $2; exit }' "$dir/.cs/local/state")
    _rot_hook_session "rot-body-unconsumed"
    _start_hook "$new" >/dev/null || return 1

    local f="$dir/.cs/handoffs/2026-07-16-active.md"
    assert_file_contains "$f" "status: consumed" "frontmatter flipped" || return 1
    assert_file_contains "$f" "consumed_by: $new" "consumer recorded" || return 1
    local n
    n=$(grep -c '^status: unconsumed$' "$f" 2>/dev/null || true)
    assert_eq "1" "$n" "only the body's quoted contract line remains; frontmatter's own line was flipped" || return 1
    [ ! -f "$dir/.cs/local/pending-handoff" ] || { echo "  FAIL: marker must be removed"; return 1; }
}

run_test test_launch_grep_ignores_body_status_line
run_test test_launch_grep_scoped_to_frontmatter_and_body_survives_consumption

# ============================================================================
# Cycle 8: context warning (Stop hook, [warn, nudge) band)
# ============================================================================

test_ctx_warning_fires_once_in_band() {
    _rot_hook_session "rot-warn"
    local out
    out=$(_stop_with_ctx 60 "$UUID_A") || return 1
    assert_output_contains "$out" '"decision":"block"' "warning delivered as a block" || return 1
    assert_output_contains "$out" "Context is at 60%" "warning names the reading" || return 1
    assert_output_contains "$out" "natural stopping point" "warning carries the frozen copy" || return 1
    assert_eq "$UUID_A" "$(cat "$CLAUDE_SESSION_META_DIR/local/ctx-warned" | tr -d '[:space:]')" \
        "cursor records the warned conversation" || return 1
    out=$(_stop_with_ctx 60 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: same conversation must not be warned twice"
        return 1
    fi
}

test_ctx_warning_rearms_for_new_conversation() {
    _rot_hook_session "rot-warn-rearm"
    _stop_with_ctx 60 "$UUID_A" >/dev/null || return 1
    local out
    out=$(_stop_with_ctx 60 "$UUID_B") || return 1
    assert_output_contains "$out" "stopping point" "new conversation UUID re-arms the warning" || return 1
}

test_ctx_warning_silent_below_band() {
    _rot_hook_session "rot-warn-low"
    local out
    out=$(_stop_with_ctx 59 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: 59 must not warn at default threshold"
        return 1
    fi
}

test_ctx_warning_yields_to_nudge_at_high_ctx() {
    _rot_hook_session "rot-warn-high"
    local out
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" "rotate skill" "nudge owns readings at its threshold" || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: warning must not fire at or above the nudge threshold"
        return 1
    fi
    out=$(_stop_with_ctx 85 "$UUID_A") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: after the nudge, the warning may not fire"
        return 1
    fi
    if printf '%s' "$out" | grep -q "rotate skill"; then
        echo "  FAIL: after the nudge, the nudge may not fire again"
        return 1
    fi
}

test_ctx_warning_threshold_override() {
    _rot_hook_session "rot-warn-env"
    export CS_CTX_WARN_CTX=70
    local out
    out=$(_stop_with_ctx 65 "$UUID_A") || { unset CS_CTX_WARN_CTX; return 1; }
    if printf '%s' "$out" | grep -q "stopping point"; then
        unset CS_CTX_WARN_CTX
        echo "  FAIL: 65 under a 70 override must not warn"
        return 1
    fi
    out=$(_stop_with_ctx 70 "$UUID_A") || { unset CS_CTX_WARN_CTX; return 1; }
    unset CS_CTX_WARN_CTX
    assert_output_contains "$out" "stopping point" "70 at a 70 override warns" || return 1
    _rot_hook_session "rot-warn-env2"
    export CS_CTX_WARN_CTX=banana
    out=$(_stop_with_ctx 60 "$UUID_B") || { unset CS_CTX_WARN_CTX; return 1; }
    unset CS_CTX_WARN_CTX
    assert_output_contains "$out" "stopping point" "non-numeric override falls back to 60" || return 1
}

test_ctx_warning_escalates_to_nudge_same_conversation() {
    _rot_hook_session "rot-warn-escalate"
    local out
    out=$(_stop_with_ctx 60 "$UUID_A") || return 1
    assert_output_contains "$out" "stopping point" "warning fires first at 60" || return 1
    out=$(_stop_with_ctx 80 "$UUID_A") || return 1
    assert_output_contains "$out" "rotate skill" "nudge still escalates after the warning" || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: the 80 reading belongs to the nudge alone"
        return 1
    fi
}

test_ctx_warning_band_edges() {
    _rot_hook_session "rot-warn-edges"
    local out
    out=$(_stop_with_ctx 79 "$UUID_A") || return 1
    assert_output_contains "$out" "stopping point" "79 is inside the band" || return 1
    _rot_hook_session "rot-warn-edge80"
    _stop_with_ctx 80 "$UUID_B" >/dev/null || return 1
    out=$(_stop_with_ctx 80 "$UUID_B") || return 1
    if printf '%s' "$out" | grep -q "stopping point"; then
        echo "  FAIL: exactly the nudge threshold is outside the band even when the nudge is spent"
        return 1
    fi
}

run_test test_ctx_warning_fires_once_in_band
run_test test_ctx_warning_rearms_for_new_conversation
run_test test_ctx_warning_silent_below_band
run_test test_ctx_warning_yields_to_nudge_at_high_ctx
run_test test_ctx_warning_threshold_override
run_test test_ctx_warning_escalates_to_nudge_same_conversation
run_test test_ctx_warning_band_edges

report_results
