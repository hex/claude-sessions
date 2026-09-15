#!/usr/bin/env bash
# ABOUTME: Tests that the finish skill ships, is registered, and teaches integrate-and-report
# ABOUTME: Contract pins for skills/finish/SKILL.md, finish.sh shipping, and the CS_SKILLS manifests

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/finish/SKILL.md"
REPO="$SCRIPT_DIR/.."

# Same extractor test_install.sh uses: the array body, comments stripped.
skill_array() {  # file name
    awk -v name="$2" '
        $0 ~ "^" name "=\\(" { f = 1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$1"
}

test_finish_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/finish/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "name: finish" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "description:" "frontmatter has a description" || return 1
}

test_finish_skill_is_user_invoked_only() {
    assert_file_contains "$SKILL" "disable-model-invocation: true" \
        "integrating must never start on the model's own initiative" || return 1
}

test_finish_registered_and_merge_retired_in_both_manifests() {
    local f
    for f in "$REPO/lib/01-manifests.sh" "$REPO/install.sh" "$CS_BIN"; do
        skill_array "$f" CS_SKILLS | grep -qx finish \
            || { echo "  FAIL: finish missing from CS_SKILLS in $f"; return 1; }
        skill_array "$f" CS_SKILLS | grep -qx merge \
            && { echo "  FAIL: merge still listed in CS_SKILLS in $f"; return 1; }
        skill_array "$f" RETIRED_SKILLS | grep -qx merge \
            || { echo "  FAIL: merge missing from RETIRED_SKILLS in $f"; return 1; }
        skill_array "$f" CS_SKILL_FILES | grep -qx 'finish/scripts/finish.sh' \
            || { echo "  FAIL: finish/scripts/finish.sh missing from CS_SKILL_FILES in $f"; return 1; }
    done
    [ ! -d "$REPO/skills/merge" ] || { echo "  FAIL: skills/merge must be removed"; return 1; }
    [ -x "$REPO/skills/finish/scripts/finish.sh" ] || { echo "  FAIL: finish.sh must ship executable"; return 1; }
}

test_finish_skill_teaches_the_ritual() {
    assert_file_contains "$SKILL" "scripts/finish.sh prepare" "runs the capture script" || return 1
    assert_file_contains "$SKILL" "scripts/finish.sh report" "runs the report script" || return 1
    assert_file_contains "$SKILL" "cs <base> -integrate-feature <task> <sha> -- <gate command" "mutates only through the hidden entry" || return 1
    assert_file_contains "$SKILL" "from-remote" "teaches the PR path" || return 1
    assert_file_contains "$SKILL" "temporary detached worktree" "gates run in the temp" || return 1
    assert_file_contains "$SKILL" "pr_state" "reads the PR state keys" || return 1
    assert_file_contains "$SKILL" "unknown" "the unknown PR state exists" || return 1
    assert_file_contains "$SKILL" "Same AskUserQuestion as OPEN" "OPEN/unknown need explicit confirmation" || return 1
    assert_file_contains "$SKILL" "cs <base> -retire-feature <task> <sha>" "retires only through the hidden entry" || return 1
    assert_file_contains "$SKILL" "retire: ready" "reads the report's retire key" || return 1
    assert_file_contains "$SKILL" "retire: not-landed" "the squash case exists" || return 1
    assert_file_contains "$SKILL" "[-]-force" "and takes force only on PR evidence" || return 1
    assert_file_contains "$SKILL" "equals the captured" "force needs the PR head to be the captured commit" || return 1
    assert_file_contains "$SKILL" "conversation is still open" "the open-conversation refusal is the user's to act on" || return 1
    assert_file_not_contains "$SKILL" "[-]-merge" "the retired verb is never named" || return 1
    assert_file_contains "$SKILL" "handoff:" "feature-session hand-off documented" || return 1
    assert_file_contains "$SKILL" "NOT part of this integrate" "dirt is reported" || return 1
}

test_finish_skill_keeps_the_plain_branch_context() {
    assert_file_contains "$SKILL" "git merge --no-ff" "ordinary feature branches still merge --no-ff" || return 1
    assert_file_contains "$SKILL" "gates again on the merged result" "gates run again after a plain-branch merge" || return 1
}

test_finish_skill_never_list() {
    assert_file_contains "$SKILL" "Never push" "publishing rail stated" || return 1
    assert_file_contains "$SKILL" "branch -D" "force delete forbidden" || return 1
    assert_file_contains "$SKILL" "Never treat a gh failure as no PR" "gh failure rail" || return 1
    assert_file_contains "$SKILL" "never runs gates in a live tree" "live-tree rail" || return 1
    assert_file_contains "$SKILL" "cs_session: yes" "a cs base never enters the plain-branch path" || return 1
    assert_file_contains "$SKILL" "Never enter" "plain-branch exclusion stated" || return 1
    assert_file_contains "$SKILL" "Never delete" "deletion rail" || return 1
}

test_finish_kick_arms_the_new_skill() {
    assert_file_contains "$REPO/lib/75-launch.sh" 'merge_kick="/finish \$merge_feature"' "-finish arms /finish" || return 1
    assert_file_not_contains "$REPO/lib/75-launch.sh" '"/merge ' "nothing arms /merge any more" || return 1
}

run_test test_finish_skill_exists_with_frontmatter
run_test test_finish_skill_is_user_invoked_only
run_test test_finish_registered_and_merge_retired_in_both_manifests
run_test test_finish_skill_teaches_the_ritual
run_test test_finish_skill_keeps_the_plain_branch_context
run_test test_finish_skill_never_list
run_test test_finish_kick_arms_the_new_skill

report_results
