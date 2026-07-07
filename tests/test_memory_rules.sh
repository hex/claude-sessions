#!/usr/bin/env bash
# ABOUTME: Tests for cs memory disclosure note in session CLAUDE.md
# ABOUTME: Covers new sessions, legacy retirement (v1/v2 rules block → note), tombstone opt-outs

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

# Current sentinel — managed by cs, marks the disclosure note section.
NOTE_SENTINEL='<!-- cs:memory-note -->'
# Legacy sentinel — retired in v2026.5.5 along with the imperative bucket-
# guidance block. Phase 9 still respects its tombstone form (sentinel-only,
# no header) as a user opt-out signal for the entire cs memory-documentation
# surface, which carries over to the replacement note.
LEGACY_SENTINEL='<!-- cs:memory-rules -->'

# ============================================================================
# Cycle 1: new session CLAUDE.md contains the memory-note (not the rules block)
# ============================================================================

test_new_session_has_memory_note() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true

    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_exists "$claude_md" "session CLAUDE.md should exist" || return 1
    assert_file_contains "$claude_md" "cs:memory-note" \
        "CLAUDE.md should contain the cs:memory-note sentinel" || return 1
    assert_file_contains "$claude_md" 'CLAUDE_COWORK_MEMORY_PATH_OVERRIDE' \
        "note should mention the env var cs uses to redirect memory" || return 1
    assert_file_contains "$claude_md" '\.cs/memory/' \
        "note should mention the .cs/memory/ destination" || return 1
}

test_new_session_has_no_legacy_rules_block() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_not_contains "$claude_md" "cs:memory-rules" \
        "new sessions must not ship the retired memory-rules sentinel" || return 1
    assert_file_not_contains "$claude_md" "Auto-memory bucket guidance" \
        "new sessions must not ship the retired imperative prose" || return 1
    assert_file_not_contains "$claude_md" "Never pause to ask" \
        "new sessions must not ship behavioral instruction prose" || return 1
}

# The secrets guidance must not teach piping a value into `cs -secrets set`: the
# bash-logger captures the whole Bash command into .cs/local/session.log, so a
# `printf '%s' secret | cs -secrets set` lands the plaintext in the log. The safe
# form (per the store-secret skill) feeds the value in via a stdin redirect.
test_new_session_secret_guidance_is_log_safe() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_not_contains "$claude_md" "| cs -secrets set" \
        "must not pipe a secret into cs -secrets set (bash-logger logs the command)" || return 1
    assert_file_contains "$claude_md" "store-secret" \
        "should point at the store-secret skill's log-safe procedure" || return 1
}

# Narratives are per-actor (narrative.<actor>.md) so co-developers never conflict;
# the generated CLAUDE.md must not instruct writing to the bare, pre-per-actor
# .cs/memory/narrative.md — that recreates an orphaned notebook hidden from resume.
test_new_session_narrative_guidance_is_per_actor() {
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    assert_file_not_contains "$claude_md" 'narrative\.md with findings' \
        "must not tell agents to write the bare narrative.md" || return 1
    assert_file_not_contains "$claude_md" 'narrative\.md as you go' \
        "must not tell agents to write the bare narrative.md" || return 1
    assert_file_contains "$claude_md" 'narrative\.<actor>\.md' \
        "should direct writes to the per-actor narrative.<actor>.md" || return 1
}

# Build a "legacy" session whose CLAUDE.md predates any cs memory documentation.
_seed_legacy_session() {
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
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

## Documentation

Update .cs/memory/narrative.md and .cs/README.md as you work.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

# ============================================================================
# Cycle 2: lazy migration appends the note to legacy CLAUDE.md (idempotent)
# ============================================================================

test_lazy_migration_appends_note() {
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-claude")

    assert_file_not_contains "$session_dir/CLAUDE.md" "cs:memory-note" \
        "precondition: legacy CLAUDE.md should lack the sentinel" || return 1

    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/CLAUDE.md" "cs:memory-note" \
        "Phase 9 should append the note sentinel" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" 'CLAUDE_COWORK_MEMORY_PATH_OVERRIDE' \
        "appended note should describe the cs path-redirect mechanism" || return 1
}

test_lazy_migration_idempotent() {
    local session_dir
    session_dir=$(_seed_legacy_session "legacy-claude")

    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true
    local first_size
    first_size=$(wc -c < "$session_dir/CLAUDE.md" | tr -d ' ')

    "$CS_BIN" legacy-claude <<< "" >/dev/null 2>&1 || true
    local second_size
    second_size=$(wc -c < "$session_dir/CLAUDE.md" | tr -d ' ')

    assert_eq "$first_size" "$second_size" \
        "second migration should not change CLAUDE.md size" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-note -->' "$session_dir/CLAUDE.md")
    assert_eq "1" "$sentinel_count" \
        "memory-note sentinel must appear exactly once after repeated migrations" || return 1
}

# ============================================================================
# Cycle 3: legacy cs:memory-rules tombstone opt-out is respected
# (user kept the sentinel, deleted the prose — applies to the replacement too)
# ============================================================================

test_legacy_rules_tombstone_prevents_note_addition() {
    local name="opted-out"
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
    # User opted out: kept the legacy sentinel as a tombstone, deleted the block.
    # That intent ("no cs memory documentation in my CLAUDE.md") carries over to
    # the replacement note — Phase 9 must NOT add cs:memory-note here.
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init)

    "$CS_BIN" opted-out <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/CLAUDE.md" "cs:memory-note" \
        "legacy tombstone must prevent addition of the replacement note" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "CLAUDE_COWORK_MEMORY_PATH_OVERRIDE" \
        "legacy tombstone must prevent addition of any cs memory documentation" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-rules -->' "$session_dir/CLAUDE.md")
    assert_eq "1" "$sentinel_count" \
        "legacy tombstone sentinel must not duplicate" || return 1
}

# ============================================================================
# Cycle 4: legacy rules block (v1 or v2) gets stripped + replaced with note
# in place, so adjacent cs:wrap-cues block keeps its order.
# ============================================================================

_seed_session_with_legacy_rules_block() {
    # Args: $1 = session name, $2 = "v1" or "v2" — controls header shape
    local name="$1"
    local variant="$2"
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

    local header
    if [ "$variant" = "v2" ]; then
        header='## Auto-memory bucket guidance (scoop mode — passive, continuous)'
    else
        header='## Auto-memory bucket guidance'
    fi

    cat > "$session_dir/CLAUDE.md" << EOF
# Session Documentation Protocol

This is a Claude Code session managed by cs. Session metadata lives in the .cs/ directory.

<!-- cs:memory-rules -->
$header

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

test_phase9_retires_v1_block_to_note() {
    local session_dir
    session_dir=$(_seed_session_with_legacy_rules_block "v1-session" "v1")

    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:memory-rules -->' \
        "precondition: v1 sentinel present" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" '^## Auto-memory bucket guidance$' \
        "precondition: v1 header (no suffix) present" || return 1

    "$CS_BIN" v1-session <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/CLAUDE.md" 'cs:memory-rules' \
        "v1 sentinel must be gone after retirement" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Auto-memory bucket guidance" \
        "v1 header must be gone after retirement" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" 'cs:memory-note' \
        "memory-note must be added in v1's place" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:wrap-cues -->' \
        "adjacent cs:wrap-cues block must be preserved across retirement" || return 1
}

test_phase9_retires_v2_block_to_note() {
    local session_dir
    session_dir=$(_seed_session_with_legacy_rules_block "v2-session" "v2")

    assert_file_contains "$session_dir/CLAUDE.md" "(scoop mode" \
        "precondition: v2 header (with scoop mode suffix) present" || return 1

    "$CS_BIN" v2-session <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/CLAUDE.md" 'cs:memory-rules' \
        "v2 sentinel must be gone after retirement" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "(scoop mode" \
        "v2 header must be gone after retirement" || return 1
    assert_file_not_contains "$session_dir/CLAUDE.md" "Never pause to ask" \
        "v2 imperative instructions must be gone after retirement" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" 'cs:memory-note' \
        "memory-note must be added in v2's place" || return 1
    assert_file_contains "$session_dir/CLAUDE.md" '<!-- cs:wrap-cues -->' \
        "adjacent cs:wrap-cues block must be preserved across retirement" || return 1
}

test_phase9_idempotent_when_already_on_note() {
    "$CS_BIN" already-on-note <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/already-on-note/CLAUDE.md"
    local before_size after_size
    before_size=$(wc -c < "$claude_md" | tr -d ' ')

    "$CS_BIN" already-on-note <<< "" >/dev/null 2>&1 || true
    after_size=$(wc -c < "$claude_md" | tr -d ' ')

    assert_eq "$before_size" "$after_size" \
        "second launch on session already-on-note must not change CLAUDE.md size" || return 1

    local sentinel_count
    sentinel_count=$(grep -cF '<!-- cs:memory-note -->' "$claude_md")
    assert_eq "1" "$sentinel_count" \
        "memory-note sentinel must appear exactly once after re-launch" || return 1
}

# ============================================================================
# Cycle 5: structural invariants — single source of truth + no behavioral prose
# ============================================================================

test_note_single_source_of_truth_in_bin_cs() {
    # Pick a content-unique phrase that only appears in the helper HEREDOC
    # (NOT in Phase 9 state-detection greps, which legitimately reference
    # the sentinel literal). Catches future drift if someone re-inlines the
    # note's prose at another call site.
    local cs_bin="$SCRIPT_DIR/../bin/cs"
    local content_count
    content_count=$(grep -cF "Claude's built-in memory writes durable facts" "$cs_bin")
    assert_eq "1" "$content_count" \
        "unique note-content phrase must appear exactly once in bin/cs (only inside _emit_memory_note_block)" || return 1
}

test_note_has_no_behavioral_instruction() {
    # The retirement explicitly removes behavioral prose. Catches a regression
    # where someone restores imperative content under the new sentinel name.
    "$CS_BIN" test-session <<< "" >/dev/null 2>&1 || true
    local claude_md="$CS_SESSIONS_ROOT/test-session/CLAUDE.md"

    for forbidden in \
        "Never pause to ask" \
        "Writing is eager" \
        "action sequence" \
        "non-negotiable" \
        "Signals it's time to Read"; do
        assert_file_not_contains "$claude_md" "$forbidden" \
            "note must not contain behavioral instruction phrase '$forbidden'" || return 1
    done
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_memory_rules.sh"
echo ""
run_test test_new_session_has_memory_note
run_test test_new_session_has_no_legacy_rules_block
run_test test_new_session_secret_guidance_is_log_safe
run_test test_new_session_narrative_guidance_is_per_actor
run_test test_lazy_migration_appends_note
run_test test_lazy_migration_idempotent
run_test test_legacy_rules_tombstone_prevents_note_addition
run_test test_phase9_retires_v1_block_to_note
run_test test_phase9_retires_v2_block_to_note
run_test test_phase9_idempotent_when_already_on_note
run_test test_note_single_source_of_truth_in_bin_cs
run_test test_note_has_no_behavioral_instruction
report_results
