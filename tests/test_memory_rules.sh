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

# ============================================================================
# Cycle 4: imperative-action-sequence prose markers — guards against silent
# regression to the decision-table-only shape (v2026.5.2 through v2026.5.4)
# ============================================================================

test_block_uses_imperative_prose_markers() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    # These phrases are the load-bearing markers of the imperative
    # action-sequence prose. Their absence means the block reverted to the
    # passive decision-table shape that empirically didn't move claude's
    # memory-write behavior (see .cs/discoveries.md, Phase 9 audit entry).
    assert_file_contains "$claude_md" "Never pause to ask" \
        "block should include the 'never pause to ask' instruction" || return 1
    assert_file_contains "$claude_md" "Writing is eager" \
        "block should include the writing-eager/reading-lazy distinction" || return 1
    assert_file_contains "$claude_md" "non-negotiable" \
        "block should mark guardrails as non-negotiable" || return 1
    assert_file_contains "$claude_md" "Signals it's time to Read" \
        "block should include lazy-load read signals section" || return 1
}

# ============================================================================
# Cycle 5: single source of truth — the literal cs:memory-rules HTML comment
# appears in exactly ONE place in bin/cs (inside _emit_memory_rules_block).
# Guards against future drift if someone re-introduces an inline HEREDOC.
# ============================================================================

test_block_single_source_of_truth_in_bin_cs() {
    # Pick a unique phrase from the new prose content that wouldn't appear
    # in detection logic or comments — the section header for the buckets
    # table is unique to the helper's HEREDOC. Catches a regression where
    # someone re-inlines the block content at a third call site.
    local cs_bin="$SCRIPT_DIR/../bin/cs"
    local content_count
    content_count=$(grep -cF '### The four buckets' "$cs_bin")
    assert_eq "1" "$content_count" \
        "unique block-content phrase should appear exactly once in bin/cs (inside _emit_memory_rules_block helper)" || return 1
}

run_test test_block_uses_imperative_prose_markers
run_test test_block_single_source_of_truth_in_bin_cs

# ============================================================================
# Cycle 6: smart Phase 9 — upgrade-in-place when the old (v2026.5.2 — 5.4)
# decision-table block is detected. Tombstone opt-out preserved; user
# customizations of the block are intentionally clobbered (documented).
# ============================================================================

# Seed a session with the OLD prose (decision-table-only, no imperative
# action sequence). The minimum viable shape is the bare header line
# without the new "(scoop mode" suffix — that's what smart Phase 9
# detects as "v1 prose, upgrade needed."
_seed_session_with_v1_block() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
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
    # CLAUDE.md with the OLD v1 block — bare header line, no imperative
    # action sequence, no "scoop mode" suffix.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
## Auto-memory bucket guidance

When the user shares a durable fact worth saving, listen for signals and pick a bucket.

Discipline:
- Read before writing.
- One bucket per fact.
- Never invent.

<!-- cs:wrap-cues -->
## Session wrap-up cues

(wrap-cues content here)
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)
    echo "$session_dir"
}

test_smart_phase9_upgrades_v1_block_to_v2_prose() {
    local session_dir
    session_dir=$(_seed_session_with_v1_block "v1-session")

    # Precondition: v1 block present, no v2 markers.
    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:memory-rules -->' \
        "precondition: v1 sentinel must be present" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Never pause to ask" \
        "precondition: v2 imperative prose must be absent" || return 1

    "$CS_BIN" v1-session <<< "" >/dev/null 2>&1 || true

    # Post: v2 prose markers present.
    assert_file_contains "$session_dir/CLAUDE.md" "Never pause to ask" \
        "smart Phase 9 should upgrade v1 prose to v2 imperative prose" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" "Writing is eager" \
        "upgraded block should include writing-eager/reading-lazy section" || return 1

    # Sentinel still appears exactly once (no duplicate).
    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-rules -->' "$session_dir/CLAUDE.md")
    assert_eq "1" "$sentinel_count" \
        "sentinel must appear exactly once after upgrade" || return 1

    # The wrap-cues sentinel (which followed the v1 block) must still be present.
    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:wrap-cues -->' \
        "smart Phase 9 must not eat the adjacent cs:wrap-cues block" || return 1
}

test_smart_phase9_preserves_tombstone_on_upgrade_pass() {
    # User opted out: sentinel present without the block header.
    # Smart Phase 9 must NOT re-add the block (would defeat opt-out).
    local name="tombstone-during-upgrade"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
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
    # Mention .cs/ in the CLAUDE.md prelude so Phase 5 (which rewrites
    # CLAUDE.md from scratch when it lacks .cs/ references) doesn't fire
    # before Phase 9 sees the tombstone.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)

    "$CS_BIN" tombstone-during-upgrade <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/CLAUDE.md" "Never pause to ask" \
        "smart Phase 9 must not re-add the block when tombstone-only" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Auto-memory bucket guidance" \
        "smart Phase 9 must preserve tombstone opt-out (no block content)" || return 1
}

test_smart_phase9_skips_when_already_on_v2_prose() {
    # Session already on the new prose — second launch must be a no-op.
    "$CS_BIN" already-current <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/already-current/CLAUDE.md"
    local before_size after_size
    before_size=$(wc -c < "$claude_md" | tr -d ' ')

    "$CS_BIN" already-current <<< "" >/dev/null 2>&1 || true
    after_size=$(wc -c < "$claude_md" | tr -d ' ')

    assert_eq "$before_size" "$after_size" \
        "second launch on session already on v2 prose must not change CLAUDE.md size" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-rules -->' "$claude_md")
    assert_eq "1" "$sentinel_count" \
        "sentinel must appear exactly once after re-launch on already-current session" || return 1
}

run_test test_smart_phase9_upgrades_v1_block_to_v2_prose
run_test test_smart_phase9_preserves_tombstone_on_upgrade_pass
run_test test_smart_phase9_skips_when_already_on_v2_prose
report_results
