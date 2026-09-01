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
    # Model a cs-launched lead: rotation events come from the rebind, which the
    # hook performs only for the claude cs exec'd into, matched by pid.
    export CS_LEAD_PID=$$
    export CLAUDE_PID=$$
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

# Nothing else in cs deletes a handoff, so without a prune rule .cs/handoffs/
# grows without bound in a tracked, shared directory. The rule has to be
# spelled out precisely: which statuses are droppable, the age source, and the
# floor that keeps a burst of rotations from emptying the store.
# The skill's last line is the only manual step left in a rotation, and a hook
# cannot take it: nothing reachable from a tool result or a hook can submit to
# Claude Code's command queue, so /clear is always the user's keystroke. That
# makes it the one thing the skill must not bury in prose.
test_rotate_skill_ends_on_the_one_manual_step() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    # The property is what the skill INSTRUCTS Claude to emit, not where the
    # instruction sits in the file. Pin the three parts that make it
    # unmissable: the final line is the /clear call to action, nothing follows
    # it, and it is set apart rather than folded into prose.
    assert_file_contains "$skill" "End your response with the instruction" \
        "the skill must direct the instruction to the end of the response" || return 1
    assert_file_contains "$skill" "nothing after it" \
        "and forbid a summary trailing it, which is what buried it before" || return 1
    assert_file_contains "$skill" 'Run `/clear` now' \
        "and give the exact line to emit, set apart in bold" || return 1
}

# The auto-start made the old wording false. "It will not act until they send
# their next message" is precisely what the kick removed, and a skill that still
# says it teaches the user to sit and wait for a prompt that never comes.
test_rotate_skill_does_not_promise_the_rotation_waits() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    assert_file_not_contains "$skill" "will not act until" \
        "the rotation now starts itself; the skill must not say otherwise" || return 1
    assert_file_contains "$skill" "on its own" \
        "and must say the fresh conversation begins the work by itself" || return 1
}

test_rotate_skill_teaches_the_prune_rule() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    assert_file_contains "$skill" "30 days" \
        "skill names the age cutoff" || return 1
    assert_file_contains "$skill" "10 newest" \
        "skill names the floor that survives the cutoff" || return 1
    assert_file_contains "$skill" "created:" \
        "skill reads the age from the frontmatter date" || return 1
    grep -q "never the file's mtime" "$skill" \
        || { echo "  FAIL: skill must rule out mtime as the age source"; return 1; }
    grep -q "never .status: unconsumed." "$skill" \
        || { echo "  FAIL: skill must forbid deleting an unconsumed handoff"; return 1; }
}

test_rotate_skill_registered_in_both_manifests() {
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../lib/00-header.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from lib/00-header.sh CS_SKILLS"; return 1; }
    grep -A 5 '^CS_SKILLS=(' "$SCRIPT_DIR/../install.sh" | grep -q 'rotate' \
        || { echo "  FAIL: rotate missing from install.sh CS_SKILLS"; return 1; }
}

test_rotate_skill_documents_the_clear_route() {
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    assert_file_contains "$skill" "pending-handoff" \
        "skill arms the marker itself" || return 1
    assert_file_contains "$skill" "/clear" \
        "skill points the user at the in-process route" || return 1
    assert_file_contains "$skill" "superseded" \
        "skill retires its own stale handoffs" || return 1
    assert_file_contains "$skill" "session.log" \
        "superseding is scoped by this machine's own conversation log" || return 1
    assert_file_not_contains "$skill" "never edits .cs/local/state" \
        "the stale no-state contract is gone" || return 1
}

test_rotate_skill_governs_what_goes_into_the_handoff() {
    # The handoff is written by a model summarising a conversation, committed
    # by step 5 into a store the session .gitignore does not cover, and read
    # back as the next conversation's prompt. Published and re-read: both
    # halves are why the body needs rules.
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    assert_file_contains "$skill" "Redact" \
        "the skill must tell the writer to redact secrets" || return 1
    assert_file_contains "$skill" "tokens" \
        "the redaction rule must name what to look for" || return 1
    assert_file_contains "$skill" "personally identifying" \
        "redaction covers personal data, not just credentials" || return 1
    assert_file_contains "$skill" "Reference committed work" \
        "the skill must stop the handoff re-summarising committed work" || return 1
    # A handoff scored 0 of 60 on facts that existed only in the conversation —
    # rejected alternatives, exact readings, run ids, event order. The reference
    # rule is right for committed work and silently drops everything else,
    # because there is no path to point at.
    assert_file_contains "$skill" "restate what a successor cannot recover" \
        "the skill must require conversation-only facts be written down" || return 1
    # Rotation fires when context is hot, and past ~88% an autocompaction can
    # land first — the handoff would then be distilled from a summary, losing
    # the verbatim facts, with nothing to show it happened.
    assert_file_contains "$skill" "say so in the handoff" \
        "a handoff written without full fidelity must label itself" || return 1
    # The restate rule asks for exact readings written down as they were, and an
    # exact reading is where a secret hides — in a tracked, shared file, judged
    # at hot context. Redaction has to survive that pressure.
    assert_file_contains "$skill" "Re-read the finished body" \
        "redaction must be re-checked after the body is written" || return 1
}

test_rotate_skill_reads_parent_from_state_not_the_launch_env() {
    # CS_CLAUDE_SESSION_ID is the LAUNCH uuid: exported once per cs process
    # (lib/75-launch.sh) and never refreshed, on purpose — session-start.sh
    # keys its ref-rename guard on it still naming this process's predecessor.
    # .cs/local/state is what tracks the current conversation, rebound by the
    # hook on every fresh conversation. The two agree only until the first
    # /clear, so preferring the env var writes the GRANDPARENT as parent: on a
    # second rotation, and step 4 supersedes by matching parent: against the
    # session log.
    local skill="$SCRIPT_DIR/../skills/rotate/SKILL.md"
    local state_line env_line
    state_line=$(grep -n 'claude_session_id' "$skill" | head -1 | cut -d: -f1)
    env_line=$(grep -n 'CS_CLAUDE_SESSION_ID' "$skill" | head -1 | cut -d: -f1)
    [ -n "$state_line" ] || { echo "  FAIL: skill never names .cs/local/state's claude_session_id"; return 1; }
    [ -n "$env_line" ] || { echo "  FAIL: skill never names CS_CLAUDE_SESSION_ID"; return 1; }
    [ "$state_line" -lt "$env_line" ] || {
        echo "  FAIL: skill offers CS_CLAUDE_SESSION_ID (line $env_line) before the state file (line $state_line); the launch uuid is stale after a /clear"
        return 1
    }
    assert_file_contains "$skill" "launch" \
        "the skill says why the env var is only a fallback" || return 1
}

run_test test_rotate_skill_exists_with_frontmatter
run_test test_rotate_skill_ends_on_the_one_manual_step
run_test test_rotate_skill_does_not_promise_the_rotation_waits
run_test test_rotate_skill_teaches_the_prune_rule
run_test test_rotate_skill_registered_in_both_manifests
run_test test_rotate_skill_documents_the_clear_route
run_test test_rotate_skill_governs_what_goes_into_the_handoff
run_test test_rotate_skill_reads_parent_from_state_not_the_launch_env

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

# The launch card asks whether to continue a conversation without saying how
# much room is left. cs-statusline stamps the figure every render, keyed by
# session name — so the card reports the last conversation to render HERE, and
# says exactly that rather than attributing it to the one being resumed.
test_resume_prompt_shows_the_previous_conversations_context() {
    _rot_session "rot-ctx"
    printf '64\n' > "$CS_SESSIONS_ROOT/rot-ctx/.cs/local/context-pct"
    local output
    output=$("$CS_BIN" rot-ctx <<< "n" 2>&1) || true
    # Piped stdout has no colour at all (setup_palette blanks every code when
    # stdout is not a TTY), so the escape belongs in the pty test below; here
    # only the text is assertable.
    assert_output_contains "$output" "64% context used" "the card must carry a context row" || return 1
    assert_output_contains "$output" "Continue previous conversation?" "prompt still present" || return 1
}

# The readout is a row in the launch card, carrying the gradient bar and sitting
# with the other session facts — not a loose line above the prompt with nothing
# separating it from the question. No pty needed: the card renders the same on a
# pipe, and a pty here would stop on the resume prompt with nothing to answer it.
test_context_row_sits_in_the_card_above_the_prompt() {
    _rot_session "rot-card"
    printf '64\n' > "$CS_SESSIONS_ROOT/rot-card/.cs/local/context-pct"
    local output ctx_line prompt_line
    output=$("$CS_BIN" rot-card <<< "n" 2>&1) || true
    ctx_line=$(printf '%s\n' "$output" | grep -n "64% context used" | head -1 | cut -d: -f1)
    prompt_line=$(printf '%s\n' "$output" | grep -n "Continue previous conversation" | head -1 | cut -d: -f1)
    [ -n "$ctx_line" ] || { echo "  FAIL: no context row in the card"; return 1; }
    [ -n "$prompt_line" ] || { echo "  FAIL: no resume prompt"; return 1; }
    [ "$ctx_line" -lt "$prompt_line" ] \
        || { echo "  FAIL: the context row must sit above the prompt (row $ctx_line, prompt $prompt_line)"; return 1; }
    # The card's bar prefixes the row, which is what separates it from the prompt.
    printf '%s\n' "$output" | grep -q "▌.*64% context used" \
        || { echo "  FAIL: the context row must carry the card's bar"; return 1; }
}

# Best-effort: the stamp only exists where cs-statusline is installed, so its
# absence must cost nothing rather than print a blank or a zero.
test_resume_prompt_omits_context_when_never_stamped() {
    _rot_session "rot-noctx"
    rm -f "$CS_SESSIONS_ROOT/rot-noctx/.cs/local/context-pct"
    local output
    output=$("$CS_BIN" rot-noctx <<< "n" 2>&1) || true
    assert_output_not_contains "$output" "context used" "no readout without a stamp" || return 1
    assert_output_contains "$output" "Continue previous conversation?" "prompt still present" || return 1
}

test_resume_prompt_ignores_a_junk_context_stamp() {
    _rot_session "rot-junk"
    printf 'not-a-number\n' > "$CS_SESSIONS_ROOT/rot-junk/.cs/local/context-pct"
    local output
    output=$("$CS_BIN" rot-junk <<< "n" 2>&1) || true
    assert_output_not_contains "$output" "context used" "a junk stamp reads as no stamp" || return 1
}

test_resume_prompt_ignores_an_out_of_range_context_stamp() {
    _rot_session "rot-over"
    printf '150\n' > "$CS_SESSIONS_ROOT/rot-over/.cs/local/context-pct"
    local output
    output=$("$CS_BIN" rot-over <<< "n" 2>&1) || true
    assert_output_not_contains "$output" "context used" "a percentage over 100 is not a percentage" || return 1
}

# A zero-padded stamp must not be read as octal, and 08/09 would be a hard
# arithmetic error rather than a wrong number.
test_resume_prompt_reads_a_zero_padded_context_stamp() {
    _rot_session "rot-pad"
    printf '08\n' > "$CS_SESSIONS_ROOT/rot-pad/.cs/local/context-pct"
    local output
    output=$("$CS_BIN" rot-pad <<< "n" 2>&1) || true
    assert_output_contains "$output" "8% context used" "08 is eight percent, not an octal error" || return 1
}

# ESC at the continue prompt cancels the launch: the stub must not run.
test_esc_at_continue_prompt_cancels_launch() {
    _rot_session "rot-esc"
    local output rc=0
    output=$("$CS_BIN" rot-esc <<< "$(printf '\033')" 2>&1) || rc=$?
    if printf '%s' "$output" | grep -q 'STUB_ARGS:'; then
        echo "  FAIL: ESC must cancel the launch — the stub must not run"; return 1
    fi
    [ "$rc" -ne 0 ] || { echo "  FAIL: ESC cancel should exit non-zero"; return 1; }
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

# The launcher picks by lexicographic basename, but .cs/handoffs/ is shared and
# nothing ever deletes a handoff: a co-worker's file, or one from a checkout that
# no longer exists, keeps status: unconsumed forever because the rotate skill
# refuses to supersede a handoff whose parent is absent from this machine's
# session.log. If it sorts last it shadows the handoff this machine actually
# armed, and r rotates into someone else's plan. The armed marker is an explicit
# choice and outranks the scan.
test_armed_marker_outranks_a_later_sorting_orphan() {
    _rot_session "rot-orphan"
    local dir="$CS_SESSIONS_ROOT/rot-orphan"
    _seed_handoff "$dir" "2026-07-14-mine.md" "unconsumed"
    _seed_handoff "$dir" "2026-07-16-orphan.md" "unconsumed"
    printf '%s\n' "2026-07-14-mine.md" > "$dir/.cs/local/pending-handoff"
    local output
    output=$("$CS_BIN" rot-orphan <<< "r" 2>&1) || true
    assert_output_contains "$output" "2026-07-14-mine.md" \
        "the prompt names the armed handoff, not the orphan" || return 1
    assert_eq "2026-07-14-mine.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "r keeps the armed handoff" || return 1
    assert_file_contains "$dir/.cs/handoffs/2026-07-16-orphan.md" "status: unconsumed" \
        "the orphan is left alone, not retired behind the user's back" || return 1
}

# Fallback must be exact: a marker naming a spent or absent file is stale, and
# the directory scan still owns the answer.
test_stale_marker_falls_back_to_the_scan() {
    _rot_session "rot-stale-marker"
    local dir="$CS_SESSIONS_ROOT/rot-stale-marker"
    _seed_handoff "$dir" "2026-07-16-real.md" "unconsumed"
    _seed_handoff "$dir" "2026-07-15-spent.md" "consumed"
    printf '%s\n' "2026-07-15-spent.md" > "$dir/.cs/local/pending-handoff"
    local output
    output=$("$CS_BIN" rot-stale-marker <<< "r" 2>&1) || true
    assert_eq "2026-07-16-real.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "a marker naming a consumed file falls back to the scan" || return 1
    _rot_session "rot-absent-marker"
    local dir2="$CS_SESSIONS_ROOT/rot-absent-marker"
    _seed_handoff "$dir2" "2026-07-16-real.md" "unconsumed"
    printf '%s\n' "2026-07-01-gone.md" > "$dir2/.cs/local/pending-handoff"
    output=$("$CS_BIN" rot-absent-marker <<< "r" 2>&1) || true
    assert_eq "2026-07-16-real.md" "$(cat "$dir2/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "a marker naming a missing file falls back to the scan" || return 1
}

# The launcher now reads the marker, so it inherits the same traversal guard the
# SessionStart consume path carries: a marker is a basename, never a path.
test_launcher_marker_with_a_path_falls_back_to_the_scan() {
    _rot_session "rot-marker-path"
    local dir="$CS_SESSIONS_ROOT/rot-marker-path"
    _seed_handoff "$dir" "2026-07-16-real.md" "unconsumed"
    printf '%s\n' "../../../etc/passwd" > "$dir/.cs/local/pending-handoff"
    local output
    output=$("$CS_BIN" rot-marker-path <<< "r" 2>&1) || true
    assert_eq "2026-07-16-real.md" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null | tr -d '[:space:]')" \
        "a marker carrying a path is rejected and the scan wins" || return 1
}

# .cs/handoffs/ is shared and nothing retires a handoff written by another
# checkout, so the offer recurs for one indefinitely. Answering it blind is the
# hazard: r arms the marker with that basename and the next SessionStart flips
# a colleague's live rotation to consumed under this machine's UUID. The pick
# stays as it is — filtering on parent would also drop a same-user second-machine
# handoff, which works today — so the offer says whose it is instead.
test_offer_labels_a_handoff_from_another_checkout() {
    _rot_session "rot-foreign"
    local dir="$CS_SESSIONS_ROOT/rot-foreign"
    _seed_handoff "$dir" "2026-07-16-theirs.md" "unconsumed"
    local output
    output=$("$CS_BIN" rot-foreign <<< "n" 2>&1) || true
    assert_output_contains "$output" "another checkout" \
        "a handoff whose parent this checkout never ran is labelled" || return 1
}

# hooks/bash-logger.sh appends every Bash command to the same session.log, so a
# bare substring match reads a logged `claude --resume <uuid>` as proof this
# checkout ran that conversation — silently dropping the one warning shown
# before r mutates a colleague's handoff.
test_a_logged_command_naming_a_uuid_is_not_provenance() {
    _rot_session "rot-logline"
    local dir="$CS_SESSIONS_ROOT/rot-logline"
    _seed_handoff "$dir" "2026-07-16-theirs.md" "unconsumed"
    printf '[2026-07-16 10:00:00] BASH: claude --resume %s\n' "$UUID_A" \
        >> "$dir/.cs/local/session.log"
    local output
    output=$("$CS_BIN" rot-logline <<< "n" 2>&1) || true
    assert_output_contains "$output" "another checkout" \
        "a logged command mentioning the uuid is not a session this checkout ran" || return 1
}

# A handoff written with CRLF, or with a trailing space after the uuid, must
# still be recognised as this checkout's — otherwise the user's own handoff is
# labelled as a colleague's and the label stops meaning anything.
test_a_trailing_carriage_return_still_reads_as_local() {
    _rot_session "rot-crlf"
    local dir="$CS_SESSIONS_ROOT/rot-crlf"
    mkdir -p "$dir/.cs/handoffs"
    printf -- '---\r\nparent: %s \r\ncreated: 2026-07-16T10:00:00Z\r\npurpose: t\r\nstatus: unconsumed\r\n---\r\n' \
        "$UUID_A" > "$dir/.cs/handoffs/2026-07-16-mine.md"
    printf '2026-07-16 10:00:00 - Session started (source: startup, ID: %s)\n' "$UUID_A" \
        >> "$dir/.cs/local/session.log"
    local output
    output=$("$CS_BIN" rot-crlf <<< "n" 2>&1) || true
    assert_output_not_contains "$output" "another checkout" \
        "a trailing CR must not make this checkout's own handoff read as foreign" || return 1
}

test_offer_leaves_a_local_handoff_unlabelled() {
    _rot_session "rot-local"
    local dir="$CS_SESSIONS_ROOT/rot-local"
    _seed_handoff "$dir" "2026-07-16-mine.md" "unconsumed"
    printf '%s - Session started (source: startup, ID: %s)\n' \
        "2026-07-16 10:00:00" "$UUID_A" >> "$dir/.cs/local/session.log"
    local output
    output=$("$CS_BIN" rot-local <<< "n" 2>&1) || true
    assert_output_contains "$output" "Rotation handoff pending" \
        "the offer is still made for a local handoff" || return 1
    assert_output_not_contains "$output" "another checkout" \
        "a handoff this checkout wrote carries no foreign label" || return 1
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

# The allow-list stops a declined marker misfiring immediately (a resumed
# conversation cannot consume). This closes the deferred misfire: left armed,
# the marker would be consumed by an unrelated /clear hours later.
test_declining_resume_disarms_the_marker() {
    local ans
    for ans in "" n d; do
        local name="rot-disarm-${ans:-default}"
        _rot_session "$name"
        local dir="$CS_SESSIONS_ROOT/$name"
        _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
        printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
        local output
        output=$("$CS_BIN" "$name" <<< "$ans" 2>&1) || true
        [ ! -f "$dir/.cs/local/pending-handoff" ] \
            || { echo "  FAIL: answer '${ans:-default}' must disarm the marker"; return 1; }
        assert_output_contains "$output" "Rotation marker disarmed" \
            "answer '${ans:-default}' announces the disarm" || return 1
    done
}

# A marker whose handoff was consumed elsewhere leaves the prompt at [Y/n] —
# the disarm must not be nested inside the pending-handoff arms.
test_marker_without_pending_handoff_is_disarmed() {
    _rot_session "rot-disarm-orphan"
    local dir="$CS_SESSIONS_ROOT/rot-disarm-orphan"
    _seed_handoff "$dir" "2026-07-16-test.md" "consumed"
    printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
    "$CS_BIN" rot-disarm-orphan <<< "n" >/dev/null 2>&1 || true
    [ ! -f "$dir/.cs/local/pending-handoff" ] \
        || { echo "  FAIL: an orphaned marker must be disarmed too"; return 1; }
}

run_test test_prompt_unchanged_without_handoff
run_test test_resume_prompt_shows_the_previous_conversations_context
run_test test_context_row_sits_in_the_card_above_the_prompt
run_test test_resume_prompt_omits_context_when_never_stamped
run_test test_resume_prompt_ignores_a_junk_context_stamp
run_test test_resume_prompt_ignores_an_out_of_range_context_stamp
run_test test_resume_prompt_reads_a_zero_padded_context_stamp
run_test test_esc_at_continue_prompt_cancels_launch
# r is only offered alongside a pending handoff. Pressed without one it falls
# through to the resume default, which is a decline like any other.
test_r_without_a_pending_handoff_disarms_the_marker() {
    _rot_session "rot-disarm-r"
    local dir="$CS_SESSIONS_ROOT/rot-disarm-r"
    _seed_handoff "$dir" "2026-07-16-test.md" "consumed"
    printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
    "$CS_BIN" rot-disarm-r <<< "r" >/dev/null 2>&1 || true
    [ ! -f "$dir/.cs/local/pending-handoff" ] \
        || { echo "  FAIL: r without a pending handoff must disarm like any decline"; return 1; }
}

# d retires the handoff, so the disarm notice must not also offer to rotate
# into it later — that guidance is true for every other decline and false for
# this one.
test_discard_does_not_offer_the_retired_handoff() {
    _rot_session "rot-disarm-discard"
    local dir="$CS_SESSIONS_ROOT/rot-disarm-discard"
    _seed_handoff "$dir" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
    local output
    output=$("$CS_BIN" rot-disarm-discard <<< "d" 2>&1) || true
    assert_output_contains "$output" "Rotation marker disarmed" \
        "d still announces the disarm" || return 1
    assert_output_contains "$output" "Handoff discarded" \
        "d retires the handoff" || return 1
    assert_output_not_contains "$output" "stays pending" \
        "a discarded handoff must not be described as still pending" || return 1
}

run_test test_declining_resume_disarms_the_marker
run_test test_marker_without_pending_handoff_is_disarmed
run_test test_r_without_a_pending_handoff_disarms_the_marker
run_test test_discard_does_not_offer_the_retired_handoff

# An orphaned marker names a handoff that is already spent, so no handoff is
# left to rotate into. Every answer that disarms one must say so, not offer r.
test_orphaned_marker_disarm_does_not_offer_a_spent_handoff() {
    local ans
    for ans in "" n d r; do
        local name="rot-orphan-${ans:-default}"
        _rot_session "$name"
        local dir="$CS_SESSIONS_ROOT/$name"
        _seed_handoff "$dir" "2026-07-16-test.md" "consumed"
        printf '%s\n' "2026-07-16-test.md" > "$dir/.cs/local/pending-handoff"
        local output
        output=$("$CS_BIN" "$name" <<< "$ans" 2>&1) || true
        assert_output_contains "$output" "Rotation marker disarmed" \
            "answer '${ans:-default}' announces the orphaned disarm" || return 1
        assert_output_not_contains "$output" "stays pending" \
            "answer '${ans:-default}' must not offer a handoff that is already spent" || return 1
    done
}

run_test test_orphaned_marker_disarm_does_not_offer_a_spent_handoff
run_test test_rotate_answer_consumes_pending_handoff
run_test test_rotate_answer_auto_starts_handoff
run_test test_continue_and_no_leave_handoff_unconsumed
run_test test_consumed_handoffs_do_not_trigger_prompt
run_test test_newest_of_multiple_handoffs_wins
run_test test_offer_labels_a_handoff_from_another_checkout
run_test test_offer_leaves_a_local_handoff_unlabelled
run_test test_a_logged_command_naming_a_uuid_is_not_provenance
run_test test_a_trailing_carriage_return_still_reads_as_local
run_test test_armed_marker_outranks_a_later_sorting_orphan
run_test test_stale_marker_falls_back_to_the_scan
run_test test_launcher_marker_with_a_path_falls_back_to_the_scan
run_test test_discard_answer_dismisses_pending_handoff
run_test test_discard_flip_spares_a_body_quote

# ============================================================================
# Cycle 4: SessionStart consumes the pending handoff
# ============================================================================

# The kick's detached child outlives the hook by design, so every clear-path
# test would otherwise leave a real sleeper writing into a directory the harness
# is about to tear down. Default it off; the tests that exercise the child set
# CS_ROTATION_KICK_DELAY themselves, and the ones that exercise the opt-out set
# CS_NO_ROTATION_WAKE explicitly — both override this, since a value the caller
# exported wins over the default below.
_start_hook() {  # session_id [source] [extra env pre-exported by caller]
    local no_wake="${CS_NO_ROTATION_WAKE:-}"
    [ -n "$no_wake" ] || [ -n "${CS_ROTATION_KICK_DELAY:-}" ] || no_wake=1
    echo "{\"session_id\":\"$1\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"${2:-startup}\"}" \
        | CS_NO_ROTATION_WAKE="$no_wake" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
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

# The marker is consumable only where a genuinely fresh conversation begins.
test_clear_source_consumes_pending_handoff() {
    _rot_hook_session "rot-clear"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "Conversation Rotation" "clear consumes the marker" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: consumed" \
        "frontmatter flipped on clear" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: marker must be removed after a clear consumption"; return 1; }
}

# additionalContext reaches the MODEL; systemMessage reaches the PERSON. After a
# /clear the conversation is idle holding a loaded handoff, and without a line
# addressed to the user that state is invisible — it reads as cs having done
# nothing. Top-level field, not inside hookSpecificOutput.
test_rotation_tells_the_user_one_message_starts_it() {
    _rot_hook_session "rot-sysmsg"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out msg
    out=$(_start_hook "$UUID_B" clear) || return 1
    msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""')
    [ -n "$msg" ] || { echo "  FAIL: the user must be told the rotation is loaded"; return 1; }
    case "$msg" in
        *2026-07-16-test.md*) ;;
        *) echo "  FAIL: the notice must name the handoff: $msg"; return 1 ;;
    esac
}

# Scoped to a rotation: a plain /clear is a blank slate and has nothing to say.
test_plain_clear_says_nothing_to_the_user() {
    _rot_hook_session "rot-nosysmsg"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out msg
    out=$(_start_hook "$UUID_B" clear) || return 1
    msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""')
    # Positive anchor first: without it this passes when the hook early-exits or
    # never produced output at all, which is true of a feature that was removed.
    assert_output_contains "$out" "managed Claude Code session" "the hook must have run and produced its context" || return 1
    [ -z "$msg" ] || { echo "  FAIL: a plain /clear must not announce anything: $msg"; return 1; }
}

# The r-answer path resolves the same handoff on source=startup, but cs has
# already sent a positional kick there — the turn is starting. Telling the user
# to send a message would be false, and it is the one render Fable caught me
# measuring while believing I had measured /clear.
test_startup_rotation_does_not_tell_the_user_to_send_a_message() {
    _rot_hook_session "rot-startup-sys"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out msg
    out=$(_start_hook "$UUID_B" startup) || return 1
    assert_output_contains "$out" "Conversation Rotation" "startup still consumes and injects" || return 1
    msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""')
    [ -z "$msg" ] || { echo "  FAIL: the r-path already kicked; the notice must not fire: $msg"; return 1; }
}

# A hook cannot start a turn, so the user sends one word. The preamble has to
# make that word mean "begin" — otherwise the fresh conversation spends it
# re-summarising the handoff and asking where to start, and the rotation costs
# two round trips instead of one keystroke.
test_rotation_preamble_makes_the_first_message_mean_begin() {
    _rot_hook_session "rot-preamble"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "BARE NUDGE" "a bare nudge must read as begin" || return 1
    assert_output_contains "$out" "without re-summarising" "and must not spend the turn restating the handoff" || return 1
    # A first message with content is an instruction, not a go signal — the
    # unnarrowed wording told the model to ignore what the user actually said.
    assert_output_contains "$out" "takes precedence over the handoff" "content in the first message wins" || return 1
    # The escape hatch covers missing/ambiguous; destructive needs its own.
    assert_output_contains "$out" "destructive or irreversible" "a destructive next step still gets confirmed" || return 1
    # The quotes were eaten by the enclosing double-quoted assignment: the text
    # written was not the text delivered.
    assert_output_contains "$out" '\\"go\\"' "the quotes around go must survive to the model" || return 1
}

# The hook must NOT emit initialUserMessage. It looks like the auto-start field
# and Claude Code accepts it, but its only consumer feeds the stdin line-reader
# of --input-format stream-json; an interactive TUI drops it. Measured on
# 2.1.252 with a real logged-in terminal: handoff consumed, no turn started.
# Pinned so nobody re-adds a field that reads as a working feature.
test_clear_does_not_emit_a_dead_autostart_field() {
    _rot_hook_session "rot-nodead"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out msg
    out=$(_start_hook "$UUID_B" clear) || return 1
    msg=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.initialUserMessage // ""')
    [ -z "$msg" ] \
        || { echo "  FAIL: initialUserMessage is dropped by the interactive TUI; do not emit it"; return 1; }
    assert_output_contains "$out" "Conversation Rotation" "the preamble is still injected" || return 1
}

# --- the /clear auto-start ----------------------------------------------------
# A hook cannot start a turn, but it can arm one. A file appearing under a
# watched path fires FileChanged, and that hook exiting 2 (asyncRewake) wakes an
# idle interactive session — measured on 2.1.252 against a real /clear, in a
# conversation with zero turns. So the rotation watches its own kick directory
# and drops a file into it a second later.
test_clear_rotation_arms_a_kick_watch() {
    _rot_hook_session "rot-kickwatch"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out watches
    out=$(CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear) || return 1
    watches=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.watchPaths // [] | join(" ")')
    case "$watches" in
        *"/local/rotation-kick"*) ;;
        *) echo "  FAIL: the kick directory must be watched, got: $watches"; return 1 ;;
    esac
    # The watcher is handed the path with no existence check, and a watch armed
    # on a missing directory never fires again for the process's lifetime.
    [ -d "$CLAUDE_SESSION_META_DIR/local/rotation-kick" ] \
        || { echo "  FAIL: the kick directory must exist before it is watched"; return 1; }
    # The mail watch is not displaced by it.
    case "$watches" in
        *"/local/mail/new"*) ;;
        *) echo "  FAIL: arming the kick must not drop the mail watch, got: $watches"; return 1 ;;
    esac
}

# The rm of `delivered` at arm time is the ONLY thing that ever deletes it, and
# every other test starts from a fresh session dir — so deleting that line would
# silently cost every rotation after the first in a session's lifetime its wake,
# with the whole suite still green.
test_a_second_rotation_in_the_same_session_still_wakes() {
    _rot_hook_session "rot-kick-second"
    local d="$CLAUDE_SESSION_META_DIR/local/rotation-kick"
    mkdir -p "$d"
    : > "$d/delivered"                       # a previous rotation's marker
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear >/dev/null || return 1
    [ ! -f "$d/delivered" ] \
        || { echo "  FAIL: a stale delivered marker makes the new kick a no-op"; return 1; }
}

# A /clear that arms NO kick must spend any kick still in flight from a previous
# one. Otherwise: /clear #1 arms and the child sleeps; the user runs /clear #2
# at ~T+1.9 wanting a genuinely clean break (the handoff is consumed now, so the
# fresh-conversation notice fires instead); the child's write lands before the
# watch list is replaced, and the wake tells a conversation explicitly told
# "clean break, not a continuation" to go execute a handoff.
test_a_clear_without_a_rotation_spends_an_in_flight_kick() {
    _rot_hook_session "rot-kick-inflight"
    local d="$CLAUDE_SESSION_META_DIR/local/rotation-kick"
    mkdir -p "$d"
    printf '%s\n' "$(date +%s)" > "$d/rotation.kick"   # a kick already in flight
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear >/dev/null || return 1  # no handoff: arms nothing
    [ -f "$d/delivered" ] \
        || { echo "  FAIL: an in-flight kick must be spent, or it wakes a clean-break conversation"; return 1; }
    # And the wake itself must now decline.
    local rc=0
    _rot_filechanged "$d/rotation.kick" add >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the spent kick must not wake" || return 1
}

# Scoped exactly like the notice. A plain /clear has nothing to continue, and
# the startup path has already been kicked by _exec_fresh_rebind — a wake there
# would arrive on top of a turn that is already running.
test_kick_watch_is_scoped_to_a_clear_rotation() {
    local src
    for src in startup resume compact; do
        _rot_hook_session "rot-kickscope-$src"
        _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
        printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
        printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
        local out watches
        out=$(CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" "$src") || return 1
        watches=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.watchPaths // [] | join(" ")')
        case "$watches" in
            *rotation-kick*) echo "  FAIL: source $src must not arm a kick: $watches"; return 1 ;;
        esac
    done
    # And a /clear with no rotation loaded.
    _rot_hook_session "rot-kickscope-bare"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out watches
    out=$(CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear) || return 1
    watches=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.watchPaths // [] | join(" ")')
    case "$watches" in
        *rotation-kick*) echo "  FAIL: a bare /clear must not arm a kick: $watches"; return 1 ;;
    esac
    assert_output_contains "$out" "managed Claude Code session" "the hook still ran" || return 1
}

# The preamble is written for the path that actually happens. With a kick armed
# the turn starts on a system-reminder, so "the first message comes from the
# user" is simply false — and a model told to wait for a user message may treat
# the wake as background noise rather than as the signal to begin.
test_armed_rotation_preamble_expects_a_wake_not_a_message() {
    _rot_hook_session "rot-preamble-armed"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "system-reminder" "the armed preamble names how the turn starts" || return 1
    if printf '%s' "$out" | grep -q "the first message comes from the user"; then
        echo "  FAIL: an armed rotation does not wait for a user message"
        return 1
    fi
    # The kick can still lose the arm race, so the typed fallback must survive.
    assert_output_contains "$out" "BARE NUDGE" "a typed nudge still means begin" || return 1
    assert_output_contains "$out" "destructive or irreversible" "the confirm valve survives both paths" || return 1
}

# With no kick (the opt-out, or a teammate) the old wording is the true one.
test_unarmed_rotation_preamble_still_expects_a_message() {
    _rot_hook_session "rot-preamble-unarmed"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(CS_NO_ROTATION_WAKE=1 _start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "the first message comes from the user" \
        "without a kick the turn really does wait for the user" || return 1
    if printf '%s' "$out" | grep -q "system-reminder"; then
        echo "  FAIL: no wake is coming, so the preamble must not promise one"
        return 1
    fi
}

# The opt-out has to reach the WATCH too, not just the wording — an armed watch
# with no kick behind it is a watch that never fires.
test_rotation_wake_opt_out_arms_nothing() {
    _rot_hook_session "rot-optout"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out watches
    out=$(CS_NO_ROTATION_WAKE=1 _start_hook "$UUID_B" clear) || return 1
    watches=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.watchPaths // [] | join(" ")')
    case "$watches" in
        *rotation-kick*) echo "  FAIL: the opt-out must arm no kick: $watches"; return 1 ;;
    esac
    # And the user is still told what to do, since nothing will start on its own.
    local msg; msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""')
    [ -n "$msg" ] || { echo "  FAIL: with no wake coming the notice matters more, not less"; return 1; }
}

# The one component with no coverage otherwise. Every other kick test either
# asserts the watchPaths JSON or plants rotation.kick by hand — so the bridge
# between them, the detached child actually producing the file, was untested.
# Break the spawn (a refactor mangles the redirects, the subshell dies under
# errexit) and every other test stays green while the feature is silently dead,
# reverting to "type a word" — which nobody reports as a bug.
test_the_detached_child_actually_writes_the_kick() {
    _rot_hook_session "rot-kickchild"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    CS_ROTATION_KICK_DELAY=0 _start_hook "$UUID_B" clear >/dev/null || return 1
    # The child outlives the hook, so the file need not exist the instant the
    # hook returns even at delay 0. Poll rather than sleep a fixed time.
    local kick="$CLAUDE_SESSION_META_DIR/local/rotation-kick/rotation.kick" i=0
    while [ ! -f "$kick" ] && [ "$i" -lt 50 ]; do
        i=$((i + 1))
        sleep 0.1
    done
    [ -f "$kick" ] \
        || { echo "  FAIL: the detached child never wrote the kick; the wake can never fire"; return 1; }
    [ -s "$kick" ] || { echo "  FAIL: the kick is empty; the child died mid-write"; return 1; }
}

# --- the wake itself ----------------------------------------------------------
# Drives narrative-reminder's FileChanged branch as this session's lead. The
# payload rides on stderr and delivery IS the exit code, so streams pass
# through untouched.
_rot_filechanged() {  # file_path, [event]
    jq -nc --arg p "$1" --arg e "${2:-add}" \
        '{hook_event_name: "FileChanged", file_path: $p, event: $e}' \
        | bash "$HOOKS_DIR/narrative-reminder.sh"
}

_arm_kick() {  # returns the kick file path on stdout
    local d="$CLAUDE_SESSION_META_DIR/local/rotation-kick"
    mkdir -p "$d"
    printf '%s\n' "$(date +%s)" > "$d/rotation.kick"
    printf '%s\n' "$d/rotation.kick"
}

test_rotation_kick_wakes_the_model() {
    _rot_hook_session "rot-wake"
    local kick; kick=$(_arm_kick)
    local err rc=0
    err=$(_rot_filechanged "$kick" add 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "the kick delivers by exiting 2 (asyncRewake)" || return 1
    # The wake arrives as a system-reminder, NOT a user message, so the reason
    # has to carry the instruction the user's "go" would otherwise have carried.
    assert_output_contains "$err" "rotation" "the reason names what woke it" || return 1
    assert_output_contains "$err" "next-step" "and says to execute the handoff" || return 1
    # The notice invites the user to type instead, and the kick is written
    # regardless — so a user who types inside the arm window gets the wake
    # ENQUEUED behind their own message, carrying an unconditional "execute the
    # handoff now". The preamble's content-takes-precedence rule covers the
    # FIRST message, not a system-reminder arriving after one. Without a yield
    # clause the auto-start overrides the person it told to take over.
    assert_output_contains "$err" "already sent a message" "the wake yields to a user who took over" || return 1
}

# One kick, one wake. The watcher fires on unlink as well as add, and the hook
# clears the kick after delivering — so without a delivered-marker the cleanup
# re-fires the event and the session wakes on its own tail forever.
test_rotation_kick_wakes_exactly_once() {
    _rot_hook_session "rot-wake-once"
    local kick; kick=$(_arm_kick)
    local rc=0
    _rot_filechanged "$kick" add >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "first delivery wakes" || return 1
    rc=0
    _rot_filechanged "$kick" add >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a second event on the same kick must not wake again" || return 1
}

# The kick does NOT yield to the queue, and that is the opposite of the mail
# wake on purpose. Nothing resets queue.state on /clear (only bin/cs writes it),
# so a drain that was armed or interrupted before the rotation leaves a STALE
# armed/draining state behind — and 2s after a /clear no drain turn can be in
# flight anyway. Yielding there swallowed the one event this kick will ever
# produce, with no Stop-path retry to recover it (the mail wake has one; the
# kick has none). Both the rotation AND the queue were then stranded: the drain
# is Stop-driven, so with no wake there is no turn, and with no turn there is no
# Stop. Waking runs the rotation turn, whose Stop then resumes the drain.
test_rotation_kick_does_not_yield_to_a_stale_queue_state() {
    _rot_hook_session "rot-wake-queue"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local/queue"
    printf '{"kind":"task"}\n' > "$CLAUDE_SESSION_META_DIR/local/queue/t1.json"
    printf 'draining\n' > "$CLAUDE_SESSION_META_DIR/local/queue.state"
    local kick; kick=$(_arm_kick)
    local rc=0
    _rot_filechanged "$kick" add >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" \
        "a stale drain state must not swallow the only kick event" || return 1
}

# Deleting a watched file fires FileChanged too — measured: rm of the kick
# produced events on the still-armed watch. An unlink must never wake.
test_rotation_kick_ignores_unlink() {
    _rot_hook_session "rot-wake-unlink"
    local kick; kick=$(_arm_kick)
    local rc=0
    _rot_filechanged "$kick" unlink >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "an unlink of the kick must not wake" || return 1
}

# A kick file that is not there is not a rotation. Guards the same class the
# mail path guards: the path shape is not proof the document exists.
test_rotation_kick_requires_the_file_to_exist() {
    _rot_hook_session "rot-wake-ghost"
    local d="$CLAUDE_SESSION_META_DIR/local/rotation-kick"
    mkdir -p "$d"
    local rc=0
    _rot_filechanged "$d/rotation.kick" add >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a missing kick file must not wake" || return 1
}

# compact and fork keep the transcript loaded, so consuming there would inject
# "the prior transcript is not loaded" into a conversation where it is. The
# marker is left ARMED — the pending rotation is still legitimate.
test_compact_and_fork_leave_marker_armed() {
    local src
    for src in compact fork resume; do
        _rot_hook_session "rot-armed-$src"
        _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
        printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
        printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
        local out
        out=$(_start_hook "$UUID_B" "$src") || return 1
        if printf '%s' "$out" | grep -q "Conversation Rotation"; then
            echo "  FAIL: source $src must not consume the marker"; return 1
        fi
        assert_file_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "status: unconsumed" \
            "$src leaves the handoff unconsumed" || return 1
        [ -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
            || { echo "  FAIL: source $src must leave the marker armed"; return 1; }
    done
}

# A handoff consumed elsewhere (another machine, then pulled) must not
# re-inject its preamble, and its status must not be rewritten.
test_spent_handoff_is_not_reconsumed() {
    _rot_hook_session "rot-spent"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "consumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a spent handoff must not inject a preamble"; return 1
    fi
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/handoffs/2026-07-16-test.md" "consumed_by:" \
        "no consumer recorded for a spent handoff" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: a marker naming a spent handoff is stale and must be removed"; return 1; }
}

# The status check is frontmatter-scoped: a body quoting the contract line
# flush-left must not make a discarded handoff look pending.
test_body_quote_does_not_revive_a_discarded_handoff() {
    _rot_hook_session "rot-revive"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "discarded"
    printf 'status: unconsumed\n' >> "$CLAUDE_SESSION_DIR/.cs/handoffs/2026-07-16-test.md"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B") || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a flush-left body quote must not revive a discarded handoff"; return 1
    fi
}

run_test test_pending_handoff_is_consumed_and_injected
run_test test_rotation_preamble_wins_over_fresh_rebind_block
run_test test_fresh_rebind_block_survives_without_handoff
run_test test_stale_marker_is_removed_silently
run_test test_handoff_with_hostile_purpose_survives_flip
# A /clear rotation has no launcher to emit the event, so the hook's rebind
# block is the sole emitter and must not label a deliberate rotation "rebind".
test_clear_rotation_records_handoff_reason() {
    _rot_hook_session "rot-label"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" clear >/dev/null || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"handoff"' "clear rotation is a handoff" || return 1
    assert_output_contains "$ev" '"handoff":"2026-07-16-test.md"' "event names the handoff" || return 1
}

# A fork with an armed marker rebinds but does not rotate: labelling it
# "handoff" would record a rotation that never happened, and the real /clear
# would then emit a second event for the same file.
test_fork_with_armed_marker_records_rebind() {
    _rot_hook_session "rot-label-fork"
    _seed_handoff "$CLAUDE_SESSION_DIR" "2026-07-16-test.md" "unconsumed"
    printf '%s\n' "2026-07-16-test.md" > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_A" > "$CLAUDE_SESSION_META_DIR/local/state"
    _start_hook "$UUID_B" fork >/dev/null || return 1
    local ev
    ev=$(_timeline | jq -c 'select(.event == "rotated")' 2>/dev/null | tail -1)
    assert_output_contains "$ev" '"reason":"rebind"' "a fork is not a handoff rotation" || return 1
    if printf '%s' "$ev" | grep -q '"handoff"'; then
        echo "  FAIL: a fork event must carry no handoff field"; return 1
    fi
}

run_test test_clear_source_consumes_pending_handoff
run_test test_rotation_tells_the_user_one_message_starts_it
run_test test_plain_clear_says_nothing_to_the_user
run_test test_startup_rotation_does_not_tell_the_user_to_send_a_message
run_test test_rotation_preamble_makes_the_first_message_mean_begin
run_test test_clear_does_not_emit_a_dead_autostart_field
run_test test_clear_rotation_arms_a_kick_watch
run_test test_kick_watch_is_scoped_to_a_clear_rotation
run_test test_a_second_rotation_in_the_same_session_still_wakes
run_test test_a_clear_without_a_rotation_spends_an_in_flight_kick
run_test test_the_detached_child_actually_writes_the_kick
run_test test_rotation_kick_wakes_the_model
run_test test_rotation_kick_wakes_exactly_once
run_test test_rotation_kick_does_not_yield_to_a_stale_queue_state
run_test test_rotation_kick_ignores_unlink
run_test test_rotation_kick_requires_the_file_to_exist
run_test test_armed_rotation_preamble_expects_a_wake_not_a_message
run_test test_unarmed_rotation_preamble_still_expects_a_message
run_test test_rotation_wake_opt_out_arms_nothing
run_test test_compact_and_fork_leave_marker_armed
run_test test_spent_handoff_is_not_reconsumed
run_test test_body_quote_does_not_revive_a_discarded_handoff
test_fresh_notice_absent_on_compact() {
    _rot_hook_session "rot-fresh-compact"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    export CS_FRESH_REBIND=1
    local out
    out=$(_start_hook "$UUID_B" compact) || { unset CS_FRESH_REBIND; return 1; }
    unset CS_FRESH_REBIND
    if printf '%s' "$out" | grep -q "Fresh Conversation"; then
        echo "  FAIL: a compaction continues the conversation — no clean-break notice"
        return 1
    fi
}

# A /clear IS a clean break, whether or not the launch was a rebind.
test_fresh_notice_present_on_clear_without_rebind_env() {
    _rot_hook_session "rot-fresh-clear"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    assert_output_contains "$out" "Fresh Conversation" "clear is a clean break" || return 1
}

# The marker names a basename. A path in it must not reach outside the
# handoff store — the file it lands on would be rewritten and named to Claude.
test_marker_with_a_path_is_rejected() {
    _rot_hook_session "rot-traverse"
    local outside="$CLAUDE_SESSION_DIR/outside.md"
    cat > "$outside" << 'EOF'
---
status: unconsumed
---
EOF
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/handoffs"
    printf '../../outside.md\n' > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a marker naming a path must not rotate"; return 1
    fi
    assert_file_not_contains "$outside" "status: consumed" \
        "a file outside the handoff store must not be rewritten" || return 1
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: a marker naming a path is stale and must be removed"; return 1; }
}

run_test test_clear_rotation_records_handoff_reason
run_test test_fork_with_armed_marker_records_rebind
run_test test_fresh_notice_absent_on_compact
run_test test_fresh_notice_present_on_clear_without_rebind_env
# A backslash is a separator in some spellings. Trivial on POSIX; the point is
# the lane where the escape would otherwise work.
test_marker_with_a_backslash_path_is_rejected() {
    _rot_hook_session "rot-traverse-bs"
    mkdir -p "$CLAUDE_SESSION_DIR/.cs/handoffs"
    # Seed a file the marker would resolve to. On POSIX the backslashes are an
    # ordinary filename, which is what makes this assertion able to fail here;
    # elsewhere the same name resolves out of the store, which is the real target.
    printf -- '---\nstatus: unconsumed\n---\n' \
        > "$CLAUDE_SESSION_DIR/.cs/handoffs/..\\..\\outside.md" 2>/dev/null || true
    printf '..\\..\\outside.md\n' > "$CLAUDE_SESSION_META_DIR/local/pending-handoff"
    printf 'claude_session_id: %s\n' "$UUID_B" > "$CLAUDE_SESSION_META_DIR/local/state"
    local out
    out=$(_start_hook "$UUID_B" clear) || return 1
    if printf '%s' "$out" | grep -q "Conversation Rotation"; then
        echo "  FAIL: a marker naming a backslash path must not rotate"; return 1
    fi
    [ ! -f "$CLAUDE_SESSION_META_DIR/local/pending-handoff" ] \
        || { echo "  FAIL: a marker naming a backslash path is stale and must be removed"; return 1; }
}

run_test test_marker_with_a_path_is_rejected
run_test test_marker_with_a_backslash_path_is_rejected

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
    mkdir -p "$CLAUDE_SESSION_META_DIR/local/queue"
    printf 'task one\n' > "$CLAUDE_SESSION_META_DIR/local/queue/0000000001-seed"
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
    # Escaped: assert_output_contains greps a BRE, where [current] is a character
    # class matching any one of c/u/r/e/n/t — which every line of this output
    # already contains, so the unescaped form passed with the marker removed.
    assert_output_contains "$out" '\[current\]' "live conversation marked" || return 1
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
