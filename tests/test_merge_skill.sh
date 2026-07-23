#!/usr/bin/env bash
# ABOUTME: Tests that the merge skill ships, is registered, and teaches the gated ritual
# ABOUTME: Contract pins for skills/merge/SKILL.md and the CS_SKILLS manifests

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/merge/SKILL.md"

test_merge_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/merge/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "name: merge" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "description:" "frontmatter has a description" || return 1
}

test_merge_skill_registered_in_both_manifests() {
    grep -A 6 '^CS_SKILLS=(' "$SCRIPT_DIR/../lib/00-header.sh" | grep -q 'merge' \
        || { echo "  FAIL: merge missing from lib/00-header.sh CS_SKILLS"; return 1; }
    grep -A 6 '^CS_SKILLS=(' "$SCRIPT_DIR/../install.sh" | grep -q 'merge' \
        || { echo "  FAIL: merge missing from install.sh CS_SKILLS"; return 1; }
}

test_merge_skill_teaches_the_gated_ritual() {
    assert_file_contains "$SKILL" "git merge --no-ff" "teaches --no-ff merges" || return 1
    assert_file_contains "$SKILL" "Preflight gates" "gates run before the merge" || return 1
    assert_file_contains "$SKILL" "merged result" "gates run again after the merge" || return 1
    assert_file_contains "$SKILL" "uncommitted" "clean-tree guard stated" || return 1
    assert_file_contains "$SKILL" "cs <base> --merge <task>" "wraps the worktree merge verb" || return 1
    assert_file_contains "$SKILL" "from the base session" "allows the narrowed in-session merge" || return 1
    assert_file_contains "$SKILL" "inside the feature session" "documents the self-worktree hand-off" || return 1
    assert_file_contains "$SKILL" "Never push" "publishing rail stated" || return 1
    assert_file_contains "$SKILL" "until the post-merge gates are green" "branch-deletion condition stated" || return 1
}

test_merge_skill_in_built_manifest() {
    grep -A 6 '^CS_SKILLS=(' "$SCRIPT_DIR/../bin/cs" | grep -q 'merge' \
        || { echo "  FAIL: built bin/cs CS_SKILLS lacks merge (run ./build.sh)"; return 1; }
}

run_test test_merge_skill_exists_with_frontmatter
run_test test_merge_skill_registered_in_both_manifests
run_test test_merge_skill_teaches_the_gated_ritual
run_test test_merge_skill_in_built_manifest

report_results
