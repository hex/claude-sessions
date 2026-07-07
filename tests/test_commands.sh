#!/usr/bin/env bash
# ABOUTME: Content invariants for commands/*.md and skills/*/SKILL.md
# ABOUTME: Guards single-source doctrine, deployed-path references, and frontmatter correctness

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

COMMANDS_DIR="$SCRIPT_DIR/../commands"
SKILLS_DIR="$SCRIPT_DIR/../skills"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

# ============================================================================
# Frontmatter correctness
# ============================================================================

test_checkpoint_allowed_tools_hyphenated() {
    assert_file_contains "$COMMANDS_DIR/checkpoint.md" "allowed-tools:" \
        "checkpoint.md must use the hyphenated allowed-tools key" || return 1
    assert_file_not_contains "$COMMANDS_DIR/checkpoint.md" "allowed_tools" \
        "the underscore form is silently ignored by Claude Code" || return 1
}

test_store_secret_has_frontmatter() {
    local first_line
    first_line=$(head -1 "$SKILLS_DIR/store-secret/SKILL.md")
    assert_eq "---" "$first_line" \
        "store-secret SKILL.md must open with a YAML frontmatter block" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "name: store-secret" \
        "frontmatter must declare the skill name" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "description:" \
        "frontmatter must declare a description (the activation trigger)" || return 1
}

test_store_secret_backend_neutral() {
    assert_file_not_contains "$SKILLS_DIR/store-secret/SKILL.md" "keychain" \
        "storage backend may be the encrypted-file fallback, not a keychain" || return 1
}

# ============================================================================
# Single-source doctrine: sweep owns the memory bar, summary owns the
# skeleton and prose gate, the prose-hygiene skill owns the scoring rubric
# ============================================================================

test_no_dangling_bucket_guidance_reference() {
    # The CLAUDE.md bucket-guidance table was retired in v2026.5.5 (bin/cs
    # Phase 9 strips it); no command may still point at it.
    local hits
    hits=$(grep -l "bucket-guidance" "$COMMANDS_DIR"/*.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command may reference the retired CLAUDE.md bucket-guidance table" || return 1
}

test_sweep_owns_bucket_routing_table() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" 'user_\*.md' \
        "sweep.md must carry the bucket routing table (user row)" || return 1
    assert_file_contains "$COMMANDS_DIR/sweep.md" 'reference_\*.md' \
        "sweep.md must carry the bucket routing table (reference row)" || return 1
}

test_sweep_routes_discovered_constraints() {
    # The project_* bucket is dominated by constraints found through work, not user
    # utterances. sweep must route them and must NOT blanket-drop them as "just a discovery".
    assert_file_not_contains "$COMMANDS_DIR/sweep.md" "that's a discovery, not a memory" \
        "the blanket 'discovery is not a memory' exclusion drops the project_* class" || return 1
    assert_file_contains "$COMMANDS_DIR/sweep.md" "discover while working" \
        "sweep must carry a routing path for constraints discovered through work" || return 1
}

test_sweep_updates_memory_index() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" "MEMORY.md" \
        "sweep.md must instruct updating the MEMORY.md index after writing an entry" || return 1
}

test_wrap_family_pinned_to_sonnet() {
    # The wrap/sweep/summary passes are distillation work, not development;
    # they run on Sonnet so a wrap never burns the heavyweight model.
    local cmd
    for cmd in wrap.md sweep.md summary.md; do
        assert_file_contains "$COMMANDS_DIR/$cmd" "^model: claude-sonnet-5" \
            "$cmd must pin model: claude-sonnet-5 in frontmatter" || return 1
        if [ "$(head -1 "$COMMANDS_DIR/$cmd")" != "---" ]; then
            echo "  FAIL: $cmd must open with a YAML frontmatter block"
            return 1
        fi
    done
}

test_wrap_references_deployed_commands() {
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/commands/sweep.md" \
        "wrap.md must reference the deployed sweep.md path" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/commands/summary.md" \
        "wrap.md must reference the deployed summary.md path" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" '`commands/sweep.md`' \
        "repo-relative paths are dead pointers at runtime" || return 1
}

test_wrap_does_not_duplicate_memory_bars() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" "three months" \
        "sweep.md owns the three-bar discipline" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "three months" \
        "wrap.md must reference the bars, not restate them" || return 1
}

test_wrap_does_not_duplicate_summary_skeleton() {
    assert_file_contains "$COMMANDS_DIR/summary.md" "# Session Summary:" \
        "summary.md owns the summary skeleton" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "# Session Summary:" \
        "wrap.md must reference the skeleton, not embed a second copy" || return 1
}

test_scoring_threshold_owned_by_skill() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "35/50" \
        "the prose-hygiene skill owns the revise threshold" || return 1
    local hits
    hits=$(grep -l "35/50" "$COMMANDS_DIR"/*.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command may restate the skill's 35/50 threshold" || return 1
}

# ============================================================================
# Correctness strays
# ============================================================================

test_summary_reads_narrative() {
    assert_file_contains "$COMMANDS_DIR/summary.md" 'memory/narrative\.\*\.md' \
        "summary must read the per-actor session narratives" || return 1
}

test_prose_critic_pinned_and_contracted() {
    assert_file_contains "$COMMANDS_DIR/summary.md" "model: opus" \
        "the prose critic is a quality-judge task and must pin a capable tier" || return 1
    assert_file_contains "$COMMANDS_DIR/summary.md" "final message" \
        "the critic's deliverable must be demanded in its final message" || return 1
}

test_prose_hygiene_records_upstream_sync() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "synced at upstream" \
        "the skill must record which stop-slop commit it was synced against" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_commands.sh"
echo ""
run_test test_checkpoint_allowed_tools_hyphenated
run_test test_store_secret_has_frontmatter
run_test test_store_secret_backend_neutral
run_test test_no_dangling_bucket_guidance_reference
run_test test_sweep_owns_bucket_routing_table
run_test test_sweep_routes_discovered_constraints
run_test test_sweep_updates_memory_index
run_test test_wrap_family_pinned_to_sonnet
run_test test_wrap_references_deployed_commands
run_test test_wrap_does_not_duplicate_memory_bars
run_test test_wrap_does_not_duplicate_summary_skeleton
run_test test_scoring_threshold_owned_by_skill
run_test test_summary_reads_narrative
run_test test_prose_critic_pinned_and_contracted
run_test test_prose_hygiene_records_upstream_sync
report_results
