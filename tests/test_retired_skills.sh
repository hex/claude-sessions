#!/usr/bin/env bash
# ABOUTME: Guards the RETIRED_SKILLS cleanup path for skills cs no longer ships
# ABOUTME: A renamed skill keeps answering its old slash command until it is deleted

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

REPO_ROOT="$SCRIPT_DIR/.."
INSTALL_SH="$REPO_ROOT/install.sh"

# Print the entries of a bash array literal from a script file, one per line.
rs_extract_array() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 ~ "^"name"=\\(" { f=1; next }
        f && /^\)/ { exit }
        f { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }
    ' "$file"
}

test_retired_skills_array_exists_in_both_copies() {
    local f
    for f in "$INSTALL_SH" "$CS_BIN"; do
        if [ -z "$(rs_extract_array "$f" RETIRED_SKILLS)" ]; then
            echo "  FAIL: RETIRED_SKILLS not found in $f"
            return 1
        fi
    done
}

test_retired_skills_in_sync() {
    local a b
    a=$(rs_extract_array "$INSTALL_SH" RETIRED_SKILLS | sort)
    b=$(rs_extract_array "$CS_BIN" RETIRED_SKILLS | sort)
    if [ "$a" != "$b" ]; then
        echo "  FAIL: RETIRED_SKILLS differs between install.sh and bin/cs"
        diff <(echo "$a") <(echo "$b") | head -10
        return 1
    fi
}

# The reason the array exists. Claude Code 2.1.227 ships its own /voice
# (Toggle voice mode), so the skill was renamed; without this entry the old
# directory stays deployed and keeps answering that command.
test_voice_is_listed_as_retired() {
    local f
    for f in "$INSTALL_SH" "$CS_BIN"; do
        if ! rs_extract_array "$f" RETIRED_SKILLS | grep -qx "voice"; then
            echo "  FAIL: 'voice' must be listed in RETIRED_SKILLS in $f"
            return 1
        fi
        if rs_extract_array "$f" CS_SKILLS | grep -qx "voice"; then
            echo "  FAIL: 'voice' must not still be listed in CS_SKILLS in $f"
            return 1
        fi
    done
}

# A retired skill must not also ship, or install would recreate what it deletes.
test_retired_skills_are_not_in_the_repo() {
    local skill
    for skill in $(rs_extract_array "$INSTALL_SH" RETIRED_SKILLS); do
        if [ -d "$REPO_ROOT/skills/$skill" ]; then
            echo "  FAIL: retired skill '$skill' still exists at skills/$skill"
            return 1
        fi
    done
}

test_install_removes_a_retired_skill_directory() {
    local fake_home="$TEST_TMPDIR/retired-skill-home"
    mkdir -p "$fake_home/.claude/skills/voice/scripts"
    echo 'stale skill' > "$fake_home/.claude/skills/voice/SKILL.md"
    echo 'stale script' > "$fake_home/.claude/skills/voice/scripts/build-corpus.sh"
    # A skill cs never shipped must survive untouched.
    mkdir -p "$fake_home/.claude/skills/not-ours"
    echo 'keep me' > "$fake_home/.claude/skills/not-ours/SKILL.md"

    HOME="$fake_home" bash "$INSTALL_SH" > /dev/null 2>&1 || {
        echo "  FAIL: install.sh exited non-zero"; return 1; }

    assert_file_not_exists "$fake_home/.claude/skills/voice/SKILL.md" \
        "install must delete the retired skill" || return 1
    if [ -d "$fake_home/.claude/skills/voice" ]; then
        echo "  FAIL: retired skill directory survived install"; return 1
    fi
    assert_file_exists "$fake_home/.claude/skills/not-ours/SKILL.md" \
        "a skill cs does not own must survive" || return 1
    assert_file_exists "$fake_home/.claude/skills/write-as-me/SKILL.md" \
        "the renamed skill must be installed" || return 1
}

test_uninstall_removes_a_retired_skill_directory() {
    local fake_home="$TEST_TMPDIR/retired-skill-uninstall"
    mkdir -p "$fake_home/.claude/skills/voice"
    echo 'stale skill' > "$fake_home/.claude/skills/voice/SKILL.md"
    mkdir -p "$fake_home/.claude/skills/not-ours"
    echo 'keep me' > "$fake_home/.claude/skills/not-ours/SKILL.md"

    printf 'y\n' | HOME="$fake_home" "$CS_BIN" -uninstall > /dev/null 2>&1 || {
        echo "  FAIL: cs -uninstall exited non-zero"; return 1; }

    if [ -d "$fake_home/.claude/skills/voice" ]; then
        echo "  FAIL: uninstall left the retired skill directory behind"; return 1
    fi
    assert_file_exists "$fake_home/.claude/skills/not-ours/SKILL.md" \
        "uninstall must not remove a skill cs does not own" || return 1
}

# The rename itself: nothing shipped may still point at the old name.
test_no_shipped_file_references_the_old_skill_name() {
    local hits
    hits=$(grep -rl 'skills/voice' "$REPO_ROOT/skills" "$REPO_ROOT/commands" \
        "$REPO_ROOT/hooks" "$REPO_ROOT/README.md" 2>/dev/null || true)
    assert_eq "" "$hits" "no shipped file may reference the old skills/voice path" || return 1
}

echo ""
echo "cs retired-skill cleanup"
echo "========================"
echo ""

run_test test_retired_skills_array_exists_in_both_copies
run_test test_retired_skills_in_sync
run_test test_voice_is_listed_as_retired
run_test test_retired_skills_are_not_in_the_repo
run_test test_install_removes_a_retired_skill_directory
run_test test_uninstall_removes_a_retired_skill_directory
run_test test_no_shipped_file_references_the_old_skill_name

report_results
