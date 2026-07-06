#!/usr/bin/env bash
# ABOUTME: Tests for Claude session UUID pre-allocation and frontmatter binding
# ABOUTME: Validates new-session UUID write, resume reads, env export, lazy migration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset cs session env vars (matches test_auto_memory.sh pattern)
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_CLAUDE_SESSION_ID 2>/dev/null || true
}

# UUID v4 regex: 8-4-4-4-12 hex, version nibble = 4, variant nibble in 8-b.
# Used both to validate generated UUIDs and to anchor regex assertions in tests.
UUID_V4_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# Extract claude_session_id value from a session's .cs/local/state file.
# Prints empty string if absent. Mirrors _read_local_state in bin/cs so the
# test can introspect the state without sourcing bin/cs.
_extract_session_uuid() {
    local state="$1"
    grep -E '^claude_session_id:' "$state" 2>/dev/null \
        | head -1 \
        | sed -E 's/^claude_session_id:[[:space:]]*//; s/^"//; s/"$//' \
        || true
}

# ============================================================================
# Cycle 1: new-session writes UUID to frontmatter AND passes --session-id
# ============================================================================

test_new_session_allocates_and_records_uuid() {
    # Capture spawn output. CLAUDE_CODE_BIN=echo (set by setup) means cs's
    # `exec $CLAUDE_CODE_BIN <args>` prints the args to stdout — that's how
    # we inspect what claude would have been invoked with.
    local output
    output=$("$CS_BIN" test-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"

    assert_file_exists "$session_dir/.cs/README.md" \
        "session README should exist after first cs launch" || return 1

    assert_file_contains "$session_dir/.cs/local/state" "^claude_session_id:" \
        "local state should record claude_session_id" || return 1

    local recorded_uuid
    recorded_uuid=$(_extract_session_uuid "$session_dir/.cs/local/state")

    if [[ ! "$recorded_uuid" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: recorded claude_session_id is not a valid v4 UUID"
        echo "    recorded: '$recorded_uuid'"
        return 1
    fi

    assert_output_contains "$output" "--session-id $recorded_uuid" \
        "claude spawn should pass --session-id <recorded-uuid>" || return 1
}

# ============================================================================
# Cycle 2: resume reads the recorded UUID and passes --resume
# ============================================================================

test_resume_uses_recorded_uuid() {
    # First run creates the session and records the UUID.
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    local recorded_uuid
    recorded_uuid=$(_extract_session_uuid "$session_dir/.cs/local/state")

    if [[ ! "$recorded_uuid" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: precondition - first launch did not record a v4 UUID"
        return 1
    fi

    # Second run resumes. Empty stdin -> default 'Y' to "Continue previous conversation?"
    local output
    output=$("$CS_BIN" test-session <<< "" 2>&1) || true

    assert_output_contains "$output" "--resume $recorded_uuid" \
        "claude spawn on resume should pass --resume <recorded-uuid>" || return 1

    # Resume must not rewrite the UUID.
    local recorded_after
    recorded_after=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$recorded_uuid" "$recorded_after" \
        "frontmatter UUID should remain stable across resumes" || return 1
}

# ============================================================================
# Cycle 3: lazy migration backfills claude_session_id on legacy sessions
# ============================================================================

test_lazy_migration_backfills_uuid() {
    # Build a "legacy" session — has .cs/README.md with frontmatter but no
    # claude_session_id (created on a cs version before this feature).
    local session_dir="$CS_SESSIONS_ROOT/legacy-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-01-01
tags: []
aliases: ["legacy-session"]
---
# Session: legacy-session

**Started:** 2026-01-01 09:00:00
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    # Precondition.
    assert_file_not_contains "$session_dir/.cs/local/state" "^claude_session_id:" \
        "precondition: legacy session must lack claude_session_id" || return 1

    # First resume backfills.
    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/.cs/local/state" "^claude_session_id:" \
        "lazy migration should backfill claude_session_id" || return 1

    local backfilled
    backfilled=$(_extract_session_uuid "$session_dir/.cs/local/state")

    if [[ ! "$backfilled" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: backfilled value is not a valid v4 UUID: '$backfilled'"
        return 1
    fi

    # Second resume must be idempotent: same value, no duplication.
    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    local after
    after=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$backfilled" "$after" \
        "second resume must not rewrite the backfilled UUID" || return 1

    local count
    count=$(grep -cE '^claude_session_id:' "$session_dir/.cs/local/state")
    assert_eq "1" "$count" \
        "claude_session_id must appear exactly once in local state" || return 1
}

# ============================================================================
# Cycle 3b: lazy migration binds to an existing claude transcript when one
# exists for the session cwd, instead of allocating a fresh orphan UUID.
# ============================================================================

# Mirrors claude's per-project transcript dir encoding (see _claude_project_dir
# in bin/cs): replace each '/' and '.' in the realpath'd cwd with '-'. Tests
# seed transcripts at this path so the discovery helper finds them.
_encode_cwd_for_claude_test() {
    local resolved
    resolved=$(cd "$1" && pwd -P)
    printf '%s' "$resolved" | tr '/.' '--'
}

# Drop a fake claude transcript file at the location bin/cs's discovery helper
# will look. Tests use this to simulate "claude has run here before".
_seed_claude_transcript() {
    local cwd="$1"
    local uuid="$2"
    local encoded proj
    encoded=$(_encode_cwd_for_claude_test "$cwd")
    proj="$CS_TRANSCRIPTS_DIR/$encoded"
    mkdir -p "$proj"
    echo '{}' > "$proj/$uuid.jsonl"
}

# Build a minimal session with optional claude_session_id in frontmatter.
# Returns the session_dir path. Centralizes the layout (mkdir +
# README frontmatter + narrative + git init) so tests don't reimplement it.
_seed_legacy_session() {
    local name="$1"
    local uuid="${2:-}"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    {
        echo "---"
        echo "status: active"
        echo "created: 2026-01-01"
        [ -n "$uuid" ] && echo "claude_session_id: $uuid"
        echo "tags: []"
        echo "aliases: [\"$name\"]"
        echo "---"
        echo "# Session: $name"
    } > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

test_lazy_migration_binds_to_existing_transcript() {
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-session")

    local existing_uuid="abcd1234-5678-4abc-9def-fedcba987654"
    _seed_claude_transcript "$session_dir" "$existing_uuid"

    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$existing_uuid" "$recorded" \
        "backfill should bind to the existing transcript UUID, not allocate fresh" || return 1
}

# ============================================================================
# Cycle 3c: lazy migration self-heals a recorded UUID with no matching
# transcript by rewriting it to the most-recent real transcript.
# ============================================================================

test_lazy_migration_self_heals_orphan_uuid() {
    local orphan_uuid="00000000-0000-4000-8000-000000000000"
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-session" "$orphan_uuid")

    local real_uuid="abcd1234-5678-4abc-9def-fedcba987654"
    _seed_claude_transcript "$session_dir" "$real_uuid"

    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$real_uuid" "$recorded" \
        "self-heal should rewrite orphan claude_session_id to the existing transcript UUID" || return 1

    # Idempotent: a second resume must not flip the value back.
    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true
    local after
    after=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$real_uuid" "$after" \
        "second resume must keep the healed UUID stable" || return 1
}

test_lazy_migration_preserves_uuid_when_transcript_matches() {
    # Guards against accidental rewrites that would invalidate a valid binding.
    local good_uuid="abcd1234-5678-4abc-9def-fedcba987654"
    local session_dir
    session_dir=$(_seed_legacy_session "bound-session" "$good_uuid")

    _seed_claude_transcript "$session_dir" "$good_uuid"
    # A NEWER transcript with a different UUID must not be chased — the
    # recorded UUID is already valid.
    local newer_uuid="11111111-2222-4333-8444-555555555555"
    _seed_claude_transcript "$session_dir" "$newer_uuid"
    local encoded
    encoded=$(_encode_cwd_for_claude_test "$session_dir")
    touch "$CS_TRANSCRIPTS_DIR/$encoded/$newer_uuid.jsonl"

    "$CS_BIN" bound-session <<< "" >/dev/null 2>&1 || true

    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/local/state")
    assert_eq "$good_uuid" "$recorded" \
        "recorded UUID with a matching transcript must not be rewritten" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_uuid.sh"
echo ""
run_test test_new_session_allocates_and_records_uuid
run_test test_resume_uses_recorded_uuid
run_test test_lazy_migration_backfills_uuid
run_test test_lazy_migration_binds_to_existing_transcript
run_test test_lazy_migration_self_heals_orphan_uuid
run_test test_lazy_migration_preserves_uuid_when_transcript_matches

# ============================================================================
# Cycle 7: declining resume rebinds the session UUID to a fresh one and
# launches claude with --session-id <new>. Prevents the "user said N then
# next launch resumes the OLD conversation" footgun.
# ============================================================================

test_decline_resume_rebinds_to_fresh_uuid() {
    local old_uuid="abcd1234-5678-4abc-9def-fedcba987654"
    local session_dir
    session_dir=$(_seed_legacy_session "test-session" "$old_uuid")
    _seed_claude_transcript "$session_dir" "$old_uuid"

    # Answer N to "Continue previous conversation?".
    local output
    output=$("$CS_BIN" test-session <<< "n" 2>&1) || true

    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/local/state")

    if [ "$recorded" = "$old_uuid" ]; then
        echo "  FAIL: declining resume should rewrite claude_session_id"
        echo "    recorded still: $recorded"
        return 1
    fi
    if [[ ! "$recorded" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: rewritten UUID is not a valid v4 UUID: '$recorded'"
        return 1
    fi
    assert_output_contains "$output" "--session-id $recorded" \
        "claude spawn after N should pass --session-id <new-uuid>" || return 1
}

run_test test_decline_resume_rebinds_to_fresh_uuid

test_decline_resume_exports_fresh_rebind_signal() {
    # The CS_FRESH_REBIND=1 env signals to hooks (session-start.sh) that the
    # user declined to resume — used to tailor SessionStart additionalContext.
    export CLAUDE_CODE_BIN="$(_make_env_stub)"

    local old_uuid="abcd1234-5678-4abc-9def-fedcba987654"
    local session_dir
    session_dir=$(_seed_legacy_session "test-session" "$old_uuid")
    _seed_claude_transcript "$session_dir" "$old_uuid"

    local output
    output=$("$CS_BIN" test-session <<< "n" 2>&1) || true

    assert_output_contains "$output" "CS_FRESH_REBIND=1" \
        "CS_FRESH_REBIND=1 should be exported when user declines resume" || return 1
}

run_test test_decline_resume_exports_fresh_rebind_signal

# ============================================================================
# Cycle 4: CS_CLAUDE_SESSION_ID is exported to the claude process environment
# ============================================================================

test_env_var_exported_with_uuid() {
    # Override CLAUDE_CODE_BIN with a stub that prints `env`. This captures
    # what variables are exported into claude's process environment — echo
    # (the default test stub) doesn't show env at all.
    export CLAUDE_CODE_BIN="$(_make_env_stub)"

    local output
    output=$("$CS_BIN" test-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/local/state")

    if [[ ! "$recorded" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: precondition - cs did not record a v4 UUID"
        return 1
    fi

    assert_output_contains "$output" "CS_CLAUDE_SESSION_ID=$recorded" \
        "CS_CLAUDE_SESSION_ID env var should be exported with the recorded UUID" || return 1
}

run_test test_env_var_exported_with_uuid

# ============================================================================
# Cycle 5: doctor check verifies recorded UUID against $CLAUDE_CODE_SESSION_ID
# ============================================================================

# Build a session with a fixed UUID in local state and the minimal layout
# needed for `cs -doctor` to run its in-session checks. Returns the path.
_seed_doctor_session() {
    local name="$1"
    local uuid="$2"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{memory,local}
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-04-21
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q -b main && git config user.email t@t \
        && git config user.name T && git add -A && git commit -q -m init)
    # Seed after the commit — .cs/local/ must never be tracked in git
    # (cs refuses to launch when it is).
    echo "claude_session_id: $uuid" > "$session_dir/.cs/local/state"
    echo "$session_dir"
}

test_doctor_session_id_match_reports_ok() {
    local uuid="11111111-2222-4333-8444-555555555555"
    local session_dir
    session_dir=$(_seed_doctor_session "test-session" "$uuid")

    local output
    output=$(CLAUDE_SESSION_DIR="$session_dir" \
             CLAUDE_SESSION_META_DIR="$session_dir/.cs" \
             CLAUDE_SESSION_NAME="test-session" \
             CLAUDE_CODE_SESSION_ID="$uuid" \
             "$CS_BIN" -doctor 2>&1) || true

    assert_output_contains "$output" "Session UUID" \
        "doctor should print a Session UUID check line" || return 1
    assert_output_contains "$output" "$uuid" \
        "doctor output should include the matching UUID for context" || return 1
}

test_doctor_session_id_mismatch_warns() {
    local recorded="11111111-2222-4333-8444-555555555555"
    local current="99999999-aaaa-4bbb-8ccc-dddddddddddd"
    local session_dir
    session_dir=$(_seed_doctor_session "test-session" "$recorded")

    local output
    output=$(CLAUDE_SESSION_DIR="$session_dir" \
             CLAUDE_SESSION_META_DIR="$session_dir/.cs" \
             CLAUDE_SESSION_NAME="test-session" \
             CLAUDE_CODE_SESSION_ID="$current" \
             "$CS_BIN" -doctor 2>&1) || true

    assert_output_contains "$output" "WARN" \
        "doctor should WARN when CLAUDE_CODE_SESSION_ID does not match frontmatter" || return 1
    assert_output_contains "$output" "$recorded" \
        "warning text should reference the recorded UUID" || return 1
}

run_test test_doctor_session_id_match_reports_ok
run_test test_doctor_session_id_mismatch_warns

# ============================================================================
# Cycle 6: live-duplicate guard refuses second spawn; --force overrides
# ============================================================================

# Build a ps stub that emits a fake process line containing the given UUID.
# bin/cs reads CS_PS_BIN in place of `ps` so we can inject canned output
# without PATH manipulation.
_seed_ps_stub_with_uuid() {
    local uuid="$1"
    local stub="$TEST_TMPDIR/ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
echo "  47533 ??       0:00.42 claude --resume $uuid"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_live_duplicate_refuses_without_force() {
    local uuid="11111111-2222-4333-8444-555555555555"
    local session_dir
    session_dir=$(_seed_doctor_session "test-session" "$uuid")

    local stub
    stub=$(_seed_ps_stub_with_uuid "$uuid")

    local output rc=0
    output=$(CS_PS_BIN="$stub" "$CS_BIN" test-session <<< "" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: cs should have refused with non-zero exit (got 0)"
        echo "    output: $(echo "$output" | tail -5)"
        return 1
    fi

    assert_output_contains "$output" "already running" \
        "error should call out the live duplicate" || return 1
    assert_output_contains "$output" "$uuid" \
        "error should mention the UUID for traceability" || return 1
}

test_live_duplicate_force_overrides() {
    local uuid="11111111-2222-4333-8444-555555555555"
    local session_dir
    session_dir=$(_seed_doctor_session "test-session" "$uuid")

    local stub
    stub=$(_seed_ps_stub_with_uuid "$uuid")

    local output
    output=$(CS_PS_BIN="$stub" "$CS_BIN" test-session --force <<< "" 2>&1) || true

    assert_output_contains "$output" "--resume $uuid" \
        "with --force the spawn should proceed and use --resume <uuid>" || return 1
    assert_output_not_contains "$output" "already running" \
        "with --force the live-duplicate refusal must not fire" || return 1
}

run_test test_live_duplicate_refuses_without_force
run_test test_live_duplicate_force_overrides

# ============================================================================
# Cycle 7: --name <session-name> passed to claude on every launch path.
# Surfaces the cs session name in claude's /resume picker, terminal title,
# and prompt-box display — symmetry between cs's primary identifier and
# claude's native display label.
# ============================================================================

test_new_session_launch_passes_name() {
    local output
    output=$("$CS_BIN" my-test-session <<< "" 2>&1) || true
    assert_output_contains "$output" "--name my-test-session" \
        "new-session launch must pass --name <session>" || return 1
}

test_resume_launch_passes_name() {
    # First run creates the session.
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    # Second run resumes (default 'Y').
    local output
    output=$("$CS_BIN" my-test-session <<< "" 2>&1) || true
    assert_output_contains "$output" "--name my-test-session" \
        "resume launch must pass --name <session>" || return 1
}

test_decline_resume_launch_passes_name() {
    # First run creates the session.
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    # Second run, user says N -> fresh-rebind path.
    local output
    output=$("$CS_BIN" my-test-session <<< "n" 2>&1) || true
    assert_output_contains "$output" "--name my-test-session" \
        "fresh-rebind (N path) must pass --name <session>" || return 1
}

run_test test_new_session_launch_passes_name
run_test test_resume_launch_passes_name
run_test test_decline_resume_launch_passes_name

# ============================================================================
# Cycle 8: random color picked at session creation, stored in frontmatter,
# and passed to claude as a /color slash-command on every launch path.
# Symmetric in spirit with --name pass-through — claude doesn't have a
# --color CLI flag, so the slash command is the only mechanism.
# ============================================================================

# The 8 colors claude accepts via /color (the binary errors on anything else).
# Verified against claude 2.1.162's own error message; the prior agent answer
# inflated this list with teal/magenta/etc — those are NOT valid.
VALID_COLORS_RE='^(red|blue|green|yellow|purple|orange|pink|cyan)$'

_extract_session_color() {
    local state="$1"
    grep -E '^claude_session_color:' "$state" 2>/dev/null \
        | head -1 \
        | sed -E 's/^claude_session_color:[[:space:]]*//; s/^"//; s/"$//' \
        || true
}

test_new_session_records_random_color_in_local_state() {
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    local state="$CS_SESSIONS_ROOT/my-test-session/.cs/local/state"

    assert_file_contains "$state" '^claude_session_color:' \
        "local state should record claude_session_color" || return 1

    local color
    color=$(_extract_session_color "$state")

    if [[ ! "$color" =~ $VALID_COLORS_RE ]]; then
        echo "  FAIL: recorded color is not in the valid 8-color set"
        echo "    recorded: '$color'"
        return 1
    fi
}

test_new_session_launch_passes_color_slash_command() {
    local output
    output=$("$CS_BIN" my-test-session <<< "" 2>&1) || true

    local state="$CS_SESSIONS_ROOT/my-test-session/.cs/local/state"
    local color
    color=$(_extract_session_color "$state")

    assert_output_contains "$output" "/color $color" \
        "new-session launch must pass /color <color> as a positional prompt" || return 1
}

test_resume_launch_passes_color_slash_command() {
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    local state="$CS_SESSIONS_ROOT/my-test-session/.cs/local/state"
    local color
    color=$(_extract_session_color "$state")

    local output
    output=$("$CS_BIN" my-test-session <<< "" 2>&1) || true

    assert_output_contains "$output" "/color $color" \
        "resume launch must pass /color <color>" || return 1
}

test_decline_resume_launch_passes_color_slash_command() {
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    local state="$CS_SESSIONS_ROOT/my-test-session/.cs/local/state"
    local color
    color=$(_extract_session_color "$state")

    local output
    output=$("$CS_BIN" my-test-session <<< "n" 2>&1) || true

    assert_output_contains "$output" "/color $color" \
        "fresh-rebind (N path) must pass /color <color>" || return 1
}

test_color_persists_across_resumes() {
    # The color is allocated ONCE at session creation and must stay stable
    # across subsequent resumes — never re-randomized.
    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true

    local state="$CS_SESSIONS_ROOT/my-test-session/.cs/local/state"
    local first_color
    first_color=$(_extract_session_color "$state")

    "$CS_BIN" my-test-session <<< "" >/dev/null 2>&1 || true
    local second_color
    second_color=$(_extract_session_color "$state")

    assert_eq "$first_color" "$second_color" \
        "color must remain stable across resumes (never re-randomized)" || return 1
}

test_legacy_session_backfills_color_on_next_launch() {
    # Build a "legacy" session with claude_session_id but no
    # claude_session_color in frontmatter — simulates a session created
    # before v2026.5.7 shipped. Phase 11 should allocate + persist a color
    # on first launch under v5.7.
    local session_dir="$CS_SESSIONS_ROOT/legacy-no-color"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-01-01
claude_session_id: abcd1234-5678-4abc-9def-fedcba987654
tags: []
aliases: ["legacy-no-color"]
---
# Session: legacy-no-color
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    assert_file_not_contains "$session_dir/.cs/local/state" '^claude_session_color:' \
        "precondition: legacy session must lack claude_session_color" || return 1

    "$CS_BIN" legacy-no-color <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/.cs/local/state" '^claude_session_color:' \
        "Phase 11 should backfill claude_session_color on legacy session" || return 1

    local color
    color=$(_extract_session_color "$session_dir/.cs/local/state")
    if [[ ! "$color" =~ $VALID_COLORS_RE ]]; then
        echo "  FAIL: backfilled color is not in the valid 8-color set: '$color'"
        return 1
    fi

    # Idempotent: second launch must NOT re-randomize.
    "$CS_BIN" legacy-no-color <<< "" >/dev/null 2>&1 || true
    local color_after
    color_after=$(_extract_session_color "$session_dir/.cs/local/state")
    assert_eq "$color" "$color_after" \
        "second migration must not change the backfilled color" || return 1

    local count
    count=$(grep -cE '^claude_session_color:' "$session_dir/.cs/local/state")
    assert_eq "1" "$count" \
        "claude_session_color must appear exactly once in local state" || return 1
}

run_test test_new_session_records_random_color_in_local_state
run_test test_new_session_launch_passes_color_slash_command
run_test test_resume_launch_passes_color_slash_command
run_test test_decline_resume_launch_passes_color_slash_command
run_test test_color_persists_across_resumes
run_test test_legacy_session_backfills_color_on_next_launch
report_results
