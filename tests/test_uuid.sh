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
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_CLAUDE_SESSION_ID 2>/dev/null || true
}

# UUID v4 regex: 8-4-4-4-12 hex, version nibble = 4, variant nibble in 8-b.
# Used both to validate generated UUIDs and to anchor regex assertions in tests.
UUID_V4_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# Extract claude_session_id value from a session README. Prints empty string
# if absent. Mirrors _read_session_uuid in bin/cs so the test can introspect
# the frontmatter without sourcing bin/cs.
_extract_session_uuid() {
    local readme="$1"
    grep -E '^claude_session_id:' "$readme" 2>/dev/null \
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

    assert_file_contains "$session_dir/.cs/README.md" "^claude_session_id:" \
        "README frontmatter should record claude_session_id" || return 1

    local recorded_uuid
    recorded_uuid=$(_extract_session_uuid "$session_dir/.cs/README.md")

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
    recorded_uuid=$(_extract_session_uuid "$session_dir/.cs/README.md")

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
    recorded_after=$(_extract_session_uuid "$session_dir/.cs/README.md")
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
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
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
    echo "# Discoveries" > "$session_dir/.cs/discoveries.md"
    echo "# Changes" > "$session_dir/.cs/changes.md"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    # Precondition.
    assert_file_not_contains "$session_dir/.cs/README.md" "^claude_session_id:" \
        "precondition: legacy session must lack claude_session_id" || return 1

    # First resume backfills.
    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/.cs/README.md" "^claude_session_id:" \
        "lazy migration should backfill claude_session_id" || return 1

    local backfilled
    backfilled=$(_extract_session_uuid "$session_dir/.cs/README.md")

    if [[ ! "$backfilled" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: backfilled value is not a valid v4 UUID: '$backfilled'"
        return 1
    fi

    # Second resume must be idempotent: same value, no duplication.
    "$CS_BIN" legacy-session <<< "" >/dev/null 2>&1 || true

    local after
    after=$(_extract_session_uuid "$session_dir/.cs/README.md")
    assert_eq "$backfilled" "$after" \
        "second resume must not rewrite the backfilled UUID" || return 1

    local count
    count=$(grep -cE '^claude_session_id:' "$session_dir/.cs/README.md")
    assert_eq "1" "$count" \
        "claude_session_id must appear exactly once in frontmatter" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_uuid.sh"
echo ""
run_test test_new_session_allocates_and_records_uuid
run_test test_resume_uses_recorded_uuid
run_test test_lazy_migration_backfills_uuid

# ============================================================================
# Cycle 4: CS_CLAUDE_SESSION_ID is exported to the claude process environment
# ============================================================================

test_env_var_exported_with_uuid() {
    # Override CLAUDE_CODE_BIN with a stub that prints `env`. This captures
    # what variables are exported into claude's process environment — echo
    # (the default test stub) doesn't show env at all.
    local stub="$TEST_TMPDIR/claude-stub"
    cat > "$stub" << 'STUB_EOF'
#!/usr/bin/env bash
env
STUB_EOF
    chmod +x "$stub"
    export CLAUDE_CODE_BIN="$stub"

    local output
    output=$("$CS_BIN" test-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    local recorded
    recorded=$(_extract_session_uuid "$session_dir/.cs/README.md")

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

# Build a session with a fixed UUID in frontmatter and the minimal layout
# needed for `cs -doctor` to run its in-session checks. Returns the path.
_seed_doctor_session() {
    local name="$1"
    local uuid="$2"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-04-21
claude_session_id: $uuid
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Discoveries" > "$session_dir/.cs/discoveries.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q -b main && git config user.email t@t \
        && git config user.name T && git add -A && git commit -q -m init)
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
report_results
