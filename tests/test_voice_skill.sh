#!/usr/bin/env bash
# ABOUTME: Tests that the voice skill ships and teaches the profile-driven drafting rules
# ABOUTME: Contract pins for skills/voice/SKILL.md

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/voice/SKILL.md"

test_voice_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/voice/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "name: voice" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "description:" "frontmatter has a description" || return 1
}

test_voice_skill_teaches_the_drafting_rules() {
    assert_file_contains "$SKILL" "scripts/build-corpus.sh" "names the builder script" || return 1
    assert_file_contains "$SKILL" "single source of style truth" "profile governs the voice" || return 1
    assert_file_contains "$SKILL" "Never fabricate" "no invented quotes or commitments" || return 1
    assert_file_contains "$SKILL" "spelled correctly" "typos are described, not reproduced" || return 1
    assert_file_contains "$SKILL" "\[redacted line\]" "redacted content stays redacted" || return 1
    assert_file_contains "$SKILL" "older than 30 days" "staleness policy stated" || return 1
    assert_file_contains "$SKILL" "never send" "drafts are delivered, not sent" || return 1
    assert_file_contains "$SKILL" "nothing to learn from" "empty-corpus outcome handled" || return 1
}

test_voice_skill_defines_the_profile_shape() {
    assert_file_contains "$SKILL" "## Fingerprint" "portable layer present" || return 1
    assert_file_contains "$SKILL" "## Registers" "register layer present" || return 1
    assert_file_contains "$SKILL" "Chat & comms" "chat register named" || return 1
    assert_file_contains "$SKILL" "Dev artifacts" "dev register named" || return 1
    assert_file_contains "$SKILL" "Long-form" "long-form register named" || return 1
    assert_file_contains "$SKILL" "## Phrase bank" "phrase bank present" || return 1
    assert_file_contains "$SKILL" "## Provenance" "provenance stamp present" || return 1
}

run_test test_voice_skill_exists_with_frontmatter
run_test test_voice_skill_teaches_the_drafting_rules
run_test test_voice_skill_defines_the_profile_shape

report_results
