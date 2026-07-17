#!/usr/bin/env bash
# ABOUTME: Tests for session wrap-up cues block in the session protocol file
# ABOUTME: Validates new-session insertion, lazy migration, and tombstone opt-out

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# A1: new-session CLAUDE.md includes the wrap-cues block
# ============================================================================

test_new_session_has_wrap_cues_block() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.local.md"

    assert_file_exists "$claude_md" "session CLAUDE.local.md should exist" || return 1
    assert_file_contains "$claude_md" "cs:wrap-cues" \
        "CLAUDE.local.md should contain the cs:wrap-cues sentinel" || return 1
    assert_file_contains "$claude_md" "Session wrap-up cues" \
        "CLAUDE.local.md should contain the section header" || return 1
    assert_file_contains "$claude_md" "AskUserQuestion" \
        "block should instruct Claude to use AskUserQuestion" || return 1
    assert_file_contains "$claude_md" "/wrap" \
        "block should reference the /wrap combo command" || return 1
}

# Build a "legacy" session whose CLAUDE.md predates the wrap-cues block.
_seed_legacy_session_wrap() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    # Legacy CLAUDE.md: a .cs/-referencing head with no sentinel of its own,
    # followed by a cs:memory-rules sentinel with header but no cs:wrap-cues.
    # Phase 5 extracts everything from the first sentinel onward into
    # CLAUDE.local.md, leaving the head in CLAUDE.md; Phase 9 then retires
    # the memory-rules block there into a memory-note, and Phase 10 appends
    # wrap-cues there since none exists yet.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
## Auto-memory bucket guidance

Stub — pretend the full bucket table lives here. The sentinel is what matters for migration short-circuits.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

# ============================================================================
# A2: lazy migration appends wrap-cues to legacy CLAUDE.md (idempotent)
# ============================================================================

test_lazy_migration_appends_wrap_cues() {
    local session_dir
    session_dir=$(_seed_legacy_session_wrap "legacy-wrap")

    assert_file_not_contains "$session_dir/CLAUDE.md" "cs:wrap-cues" \
        "precondition: legacy CLAUDE.md should lack cs:wrap-cues sentinel" || return 1

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "Session Documentation Protocol" \
        "the head above the sentinel stays in CLAUDE.md" || return 1
    assert_file_contains "$session_dir/CLAUDE.local.md" "cs:wrap-cues" \
        "Phase 10 migration should append the sentinel" || return 1
    assert_file_contains "$session_dir/CLAUDE.local.md" "Session wrap-up cues" \
        "appended block should include the section header" || return 1
}

test_lazy_migration_wrap_cues_idempotent() {
    local session_dir
    session_dir=$(_seed_legacy_session_wrap "legacy-wrap")

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true
    local first_size
    first_size=$(wc -c < "$session_dir/CLAUDE.local.md" | tr -d ' ')

    "$CS_BIN" legacy-wrap <<< "" >/dev/null 2>&1 || true
    local second_size
    second_size=$(wc -c < "$session_dir/CLAUDE.local.md" | tr -d ' ')

    assert_eq "$first_size" "$second_size" \
        "second migration should not change CLAUDE.local.md size" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:wrap-cues -->' "$session_dir/CLAUDE.local.md")
    assert_eq "1" "$sentinel_count" \
        "HTML sentinel must appear exactly once after repeated migrations" || return 1
}

# ============================================================================
# Tombstone opt-out — sentinel present without block content prevents re-add
# ============================================================================

test_wrap_cues_opt_out_respected() {
    local name="opted-out-wrap"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    # User deleted the wrap-cues content but kept the tombstone sentinel.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
Memory-rules content stub.

<!-- cs:wrap-cues -->
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)

    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:wrap-cues -->' \
        "precondition: tombstone sentinel must be present" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Session wrap-up cues" \
        "precondition: opted-out CLAUDE.md must lack the section header" || return 1

    "$CS_BIN" opted-out-wrap <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "Session Documentation Protocol" \
        "the head above the sentinel stays in CLAUDE.md" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.local.md" "Session wrap-up cues" \
        "tombstone sentinel must prevent re-addition of the block" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:wrap-cues -->' "$session_dir/CLAUDE.local.md")
    assert_eq "1" "$sentinel_count" \
        "tombstone sentinel must not duplicate" || return 1
}

# ============================================================================
# Runner
# ============================================================================
test_wrap_cues_wording_parity_between_emit_and_migrate() {
    # The wrap-cues block is duplicated in the new-session template (35-claudemd.sh)
    # and the legacy-session migration heredoc (45-migrate.sh). They must not drift —
    # otherwise new and migrated sessions get different wrap-up guidance.
    local emit="$SCRIPT_DIR/../lib/35-claudemd.sh"
    local migrate="$SCRIPT_DIR/../lib/45-migrate.sh"
    assert_file_contains "$emit" "Strong signals (sufficient on their own" \
        "the template must carry the recast strong-signal wording" || return 1
    assert_file_contains "$migrate" "Strong signals (sufficient on their own" \
        "the migration heredoc must carry the same wording (no drift with the template)" || return 1
    assert_file_not_contains "$migrate" "Strong triggers (fire on any single occurrence)" \
        "the migration must not keep the old literal-match wording" || return 1
}

echo "Running test_wrap_cues.sh"
echo ""
run_test test_new_session_has_wrap_cues_block
run_test test_lazy_migration_appends_wrap_cues
run_test test_lazy_migration_wrap_cues_idempotent
run_test test_wrap_cues_opt_out_respected
run_test test_wrap_cues_wording_parity_between_emit_and_migrate
report_results
