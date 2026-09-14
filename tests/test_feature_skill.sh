#!/usr/bin/env bash
# ABOUTME: Tests that the feature skill ships, is registered, and teaches spawning a feature worktree with a brief
# ABOUTME: Contract pins for skills/feature/SKILL.md and the CS_SKILLS manifests

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/feature/SKILL.md"
REPO="$SCRIPT_DIR/.."

# Same extractor test_install.sh uses: the array body, comments stripped.
skill_array() {  # file name
    awk -v name="$2" '
        $0 ~ "^" name "=\\(" { f = 1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$1"
}

test_feature_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/feature/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "^name: feature$" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "^description:" "frontmatter has a description" || return 1
}

# Starting a feature is what a session does on its own initiative when the
# user asks for parallel work, so the model may invoke it; the permission
# prompt on cs -spawn is the human gate, and the skill must not teach around it.
test_feature_skill_is_model_invocable_and_keeps_the_prompt() {
    assert_file_not_contains "$SKILL" "disable-model-invocation" \
        "a session may start a feature itself" || return 1
    assert_file_not_contains "$SKILL" "dangerouslyDisableSandbox\|auto-approve\|--dangerously" \
        "the skill never teaches around the spawn prompt" || return 1
}

test_feature_registered_in_all_manifests() {
    local f
    for f in "$REPO/lib/00-header.sh" "$REPO/install.sh" "$CS_BIN"; do
        skill_array "$f" CS_SKILLS | grep -qx feature \
            || { echo "  FAIL: feature missing from CS_SKILLS in $f"; return 1; }
    done
}

test_feature_skill_teaches_the_spawn_with_a_brief() {
    assert_file_contains "$SKILL" "cs -spawn" "the skill runs the spawner" || return 1
    assert_file_contains "$SKILL" "\-\-brief" "the brief travels as --brief" || return 1
    assert_file_contains "$SKILL" "CLAUDE_SESSION_NAME" "the base defaults to the current session" || return 1
    assert_file_contains "$SKILL" "<base>@<feature>" "a full worktree name is accepted" || return 1
    assert_file_contains "$SKILL" "\.cs/brief\.md" "the skill says where the brief lands" || return 1
    assert_file_contains "$SKILL" "cs -msg <spawner>" "the report-back goes to the spawning session" || return 1
    assert_file_contains "$SKILL" "the two differ when" \
        "the spawner and the base are kept separate" || return 1
    assert_file_contains "$SKILL" "/finish" "the skill points at the landing ritual" || return 1
}

# The brief is written to a scratch file the skill removes: the spawner copies
# it into staging, so nothing of the skill's own lingers in the session.
test_feature_skill_brief_is_a_temporary_file() {
    assert_file_contains "$SKILL" "mktemp" "the brief is written to a temp file" || return 1
    assert_file_contains "$SKILL" "rm -f" "the temp file is removed afterwards" || return 1
}

run_test test_feature_skill_exists_with_frontmatter
run_test test_feature_skill_is_model_invocable_and_keeps_the_prompt
run_test test_feature_registered_in_all_manifests
run_test test_feature_skill_teaches_the_spawn_with_a_brief
run_test test_feature_skill_brief_is_a_temporary_file

report_results
