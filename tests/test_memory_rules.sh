#!/usr/bin/env bash
# ABOUTME: Tests for auto-memory bucket guidance block in session CLAUDE.md
# ABOUTME: Validates new-session insertion, lazy migration, and user opt-out

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Sentinel marker injected at the top of the managed block. Presence means
# cs has touched this section — migration treats it as "do not modify."
SENTINEL='<!-- cs:memory-rules -->'

# ============================================================================
# Cycle 1: new session CLAUDE.md contains the memory-rules block
# ============================================================================

test_new_session_has_memory_rules_block() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_exists "$claude_md" "session CLAUDE.md should exist" || return 1
    assert_file_contains "$claude_md" "cs:memory-rules" \
        "CLAUDE.md should contain the cs:memory-rules sentinel" || return 1
    assert_file_contains "$claude_md" "Auto-memory bucket guidance" \
        "CLAUDE.md should contain the section header" || return 1
    assert_file_contains "$claude_md" 'user_\*\.md' \
        "CLAUDE.md should mention user_*.md bucket in the signal-phrase table" || return 1
}

# Build a "legacy" session whose CLAUDE.md predates the memory-rules block.
# Used by the lazy-migration tests.
_seed_legacy_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Discoveries" > "$session_dir/.cs/discoveries.md"
    echo "# Changes" > "$session_dir/.cs/changes.md"
    # Legacy CLAUDE.md: mentions .cs/ paths (so Phase 5 won't rewrite it)
    # but contains no cs:memory-rules sentinel.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

## Documentation

Update .cs/discoveries.md, .cs/changes.md, and .cs/README.md as you work.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

# ============================================================================
# Cycle 2: lazy migration appends the block to legacy CLAUDE.md (idempotent)
# ============================================================================

test_lazy_migration_appends_block() {
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-claude")

    assert_file_not_contains "$session_dir/CLAUDE.md" "cs:memory-rules" \
        "precondition: legacy CLAUDE.md should lack the sentinel" || return 1

    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "cs:memory-rules" \
        "Phase 9 migration should append the sentinel" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" "Auto-memory bucket guidance" \
        "appended block should include the section header" || return 1
}

test_lazy_migration_idempotent() {
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-claude")

    # First migration appends.
    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true

    local first_size
    first_size=$(wc -c < "$session_dir/CLAUDE.md" | tr -d ' ')

    # Second migration must be a no-op.
    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true

    local second_size
    second_size=$(wc -c < "$session_dir/CLAUDE.md" | tr -d ' ')

    assert_eq "$first_size" "$second_size" \
        "second migration should not change CLAUDE.md size" || return 1

    # The token `cs:memory-rules` also appears in the opt-out instruction
    # prose (documenting the sentinel by name). The actual sentinel marker
    # is the HTML comment; that's what must be exactly-once. Production
    # grep at Phase 9 is intentionally loose so opt-out-with-docs is also
    # detected as "managed."
    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-rules -->' "$session_dir/CLAUDE.md")
    assert_eq "1" "$sentinel_count" \
        "HTML comment sentinel must appear exactly once after repeated migrations" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_memory_rules.sh"
echo ""
run_test test_new_session_has_memory_rules_block
run_test test_lazy_migration_appends_block
run_test test_lazy_migration_idempotent

# ============================================================================
# Cycle 3: user opt-out — sentinel as tombstone prevents re-addition
# ============================================================================

test_user_opt_out_respected() {
    local name="opted-out"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    echo "auto_sync=on" > "$session_dir/.cs/sync.conf"
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: 2026-01-01
tags: []
aliases: ["$name"]
---
# Session: $name
EOF
    echo "# Discoveries" > "$session_dir/.cs/discoveries.md"
    echo "# Changes" > "$session_dir/.cs/changes.md"
    # User opted out: kept the sentinel as a tombstone, deleted the block.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)

    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:memory-rules -->' \
        "precondition: tombstone sentinel must be present" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Auto-memory bucket guidance" \
        "precondition: opted-out CLAUDE.md must lack the block content" || return 1

    "$CS_BIN" opted-out <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/CLAUDE.md" "Auto-memory bucket guidance" \
        "tombstone sentinel must prevent re-addition of the block" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-rules -->' "$session_dir/CLAUDE.md")
    assert_eq "1" "$sentinel_count" \
        "tombstone sentinel must not duplicate" || return 1
}

run_test test_user_opt_out_respected
report_results
