#!/usr/bin/env bash
# ABOUTME: Tests for skills/finish/scripts/finish.sh, the read-only half of /finish
# ABOUTME: Context detection, capture, GitHub PR state via a stubbed gh, and the report

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

FINISH="$SCRIPT_DIR/../skills/finish/scripts/finish.sh"

cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Base + feature with one feature commit and a GitHub-shaped origin URL (never
# contacted: gh is stubbed). Prints the feature SHA.
finish_fixture() {  # base task
    local base_dir wt
    base_dir=$(create_test_session_with_git "$1")
    git -C "$base_dir" remote add origin "git@github.com:example-org/example-repo.git"
    cs_launch "$1@$2"
    wt="$CS_SESSIONS_ROOT/$1@$2"
    echo "feature work" > "$wt/feature.txt"
    (cd "$wt" && git add feature.txt && git commit -q -m "feature work")
    git -C "$wt" rev-parse HEAD
}

# A gh on PATH that prints $1 as its JSON (or exits $2 with $3 on stderr).
stub_gh() {  # json [exit-code stderr-text]
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMPDIR/gh.argv"
if [ "${2:-0}" != 0 ]; then echo "${3:-gh failed}" >&2; exit ${2:-0}; fi
cat << 'JSON'
$1
JSON
STUB
    chmod +x "$TEST_TMPDIR/bin/gh"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

key() {  # output key
    printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1
}

test_prepare_in_feature_session_hands_off() {
    finish_fixture myproj fix-auth > /dev/null
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj@fix-auth" CLAUDE_SESSION_NAME="myproj@fix-auth" \
        bash "$FINISH" prepare 2>&1)
    assert_eq "feature" "$(key "$out" role)" "feature role detected" || return 1
    assert_eq "myproj" "$(key "$out" base)" "base named" || return 1
    assert_eq "fix-auth" "$(key "$out" task)" "task named" || return 1
    assert_output_contains "$out" "handoff: run /finish fix-auth in session myproj" "hand-off line" || return 1
    assert_output_not_contains "$out" "sha:" "a feature session captures nothing" || return 1
}

test_prepare_in_base_captures_sha_branch_and_dirt() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    echo "uncommitted" > "$CS_SESSIONS_ROOT/myproj@fix-auth/scratch.txt"
    # Tracked-mode session records are the user's work too: never filtered.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/plans"
    echo "# plan" > "$CS_SESSIONS_ROOT/myproj@fix-auth/.cs/plans/next.md"
    stub_gh '[]'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "base" "$(key "$out" role)" "base role" || return 1
    assert_eq "yes" "$(key "$out" cs_session)" "a cs base is recognised" || return 1
    assert_eq "$sha" "$(key "$out" sha)" "captured sha is the feature HEAD" || return 1
    assert_eq "cs/fix-auth" "$(key "$out" branch)" "feature is on its branch" || return 1
    assert_eq "2" "$(key "$out" dirt_count)" "both dirty paths counted, .cs/ included" || return 1
    assert_output_contains "$out" "dirt: ?? scratch.txt" "dirt is listed as porcelain" || return 1
    assert_output_contains "$out" "dirt: ?? .cs/plans/" "session records under .cs/ are reported" || return 1
    assert_eq "none" "$(key "$out" pr_state)" "no PR" || return 1
}

test_prepare_in_a_plain_checkout_says_so() {
    local dir="$TEST_TMPDIR/plain"
    mkdir -p "$dir"
    (cd "$dir" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b topic)
    local out
    out=$(CLAUDE_SESSION_DIR="$dir" CLAUDE_SESSION_NAME="plain" bash "$FINISH" prepare 2>&1)
    assert_eq "no" "$(key "$out" cs_session)" "an ordinary checkout is not a cs session" || return 1
    assert_eq "topic" "$(key "$out" base_branch)" "branch reported" || return 1
}

test_prepare_calls_two_open_prs_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":3,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/3","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":5,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/5","mergeCommit":null,"mergedAt":null,"baseRefName":"release","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "two open PRs are ambiguous" || return 1
    assert_output_contains "$out" "pr_reason: ambiguous — #3 OPEN, #5 OPEN" "both are named" || return 1
}

test_prepare_calls_a_reused_branch_unknown() {
    # An old MERGED PR beside a newer OPEN one on the same head: the branch
    # was reused after a landing; neither state describes this capture.
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-01T09:00:00Z","baseRefName":"main","headRefOid":"old","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":9,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/9","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"new","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "merged beside open is ambiguous" || return 1
    assert_output_contains "$out" "#7 MERGED, #9 OPEN" "both are named" || return 1
}

test_prepare_refuses_a_worktree_off_its_branch() {
    finish_fixture myproj fix-auth > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" checkout -q --detach
    local out status=0
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1) || status=$?
    assert_eq "1" "$status" "refuses" || return 1
    assert_output_contains "$out" "error: worktree is on detached, not cs/fix-auth" "names the state" || return 1
}

test_prepare_reports_a_merged_pr() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[
      {"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false},
      {"number":8,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/8","mergeCommit":{"oid":"def456"},"mergedAt":"2026-09-12T10:00:00Z","baseRefName":"main","headRefOid":"b2b2","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}
    ]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "MERGED" "$(key "$out" pr_state)" "merged state" || return 1
    assert_eq "8" "$(key "$out" pr_number)" "newest mergedAt wins among this repo's PRs" || return 1
    assert_eq "def456" "$(key "$out" pr_merge_commit)" "merge commit oid" || return 1
    assert_eq "main" "$(key "$out" pr_base_ref)" "base ref" || return 1
    assert_eq "b2b2" "$(key "$out" pr_head_oid)" "head oid passed through for the skill to compare with the capture" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "pr list --repo example-org/example-repo --head cs/fix-auth --state all --limit 100" \
        "gh is asked for every state, scoped to origin's repo" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "headRefOid,headRepositoryOwner,isCrossRepository" "the spec's fields are requested" || return 1
}

test_prepare_reports_an_open_pr() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":3,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/3","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "OPEN" "$(key "$out" pr_state)" "open state" || return 1
    assert_eq "3" "$(key "$out" pr_number)" "number" || return 1
}

test_prepare_reports_closed_unmerged_as_closed() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":4,"state":"CLOSED","url":"https://github.com/example-org/example-repo/pull/4","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "CLOSED" "$(key "$out" pr_state)" "closed state" || return 1
    assert_eq "4" "$(key "$out" pr_number)" "number" || return 1
}

test_prepare_never_reads_a_gh_failure_as_no_pr() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '' 4 'gh: To get started with GitHub CLI, please run: gh auth login'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a gh failure is unknown, never none" || return 1
    assert_output_contains "$out" "pr_reason: gh pr list failed: gh: To get started" "reason carries gh's message" || return 1
}

test_prepare_treats_a_vanished_head_repo_as_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":5,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/5","mergeCommit":{"oid":"aaa"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"aaa","headRepositoryOwner":null,"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a PR whose head repository is gone cannot be attributed" || return 1
    assert_output_contains "$out" "pr_reason: " "reason given" || return 1
}

test_prepare_skips_the_lookup_for_a_non_github_origin() {
    finish_fixture myproj fix-auth > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj" remote set-url origin "https://git.example.com/example-org/example-repo.git"
    stub_gh '[]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "skipped" "$(key "$out" pr_state)" "non-GitHub origin skips" || return 1
    assert_output_contains "$out" "pr_reason: origin is not a GitHub remote" "says why" || return 1
    assert_file_not_exists "$TEST_TMPDIR/gh.argv" "gh was never invoked" || return 1
}

test_report_after_a_local_integrate_gives_the_retire_line() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true > /dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    # One more feature commit after capture: it must be counted as not integrated.
    (cd "$CS_SESSIONS_ROOT/myproj@fix-auth" && git commit -q --allow-empty -m "after capture")
    # The integrate leaves .cs/timeline.jsonl untracked in this tracked-mode
    # base fixture; commit the session bookkeeping so report sees a clean .cs
    # and gives the plain retire line (the uncommitted-bookkeeping variant is
    # covered separately below).
    (cd "$CS_SESSIONS_ROOT/myproj" && git add .cs && git commit -q -m "bookkeeping")
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "yes" "$(key "$out" landed)" "captured sha is an ancestor of base" || return 1
    assert_eq "$(git -C "$CS_SESSIONS_ROOT/myproj" rev-parse HEAD)" "$(key "$out" base_head)" "base head reported" || return 1
    assert_eq "1" "$(key "$out" not_integrated)" "one commit after capture" || return 1
    assert_output_contains "$out" "retire: 1 commit(s) on cs/fix-auth after the captured commit are not integrated; run /finish fix-auth again before retiring" \
        "a tip past the landing is not ready to retire" || return 1
    assert_output_not_contains "$out" "cs myproj --merge fix-auth" "and the retire verb is not offered yet" || return 1
}

# The tip IS the commit that landed: retiring now fuses exactly what the base
# already has, so the plain retire line is the right advice.
test_report_with_an_integrated_tip_gives_the_plain_retire_line() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true > /dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    (cd "$CS_SESSIONS_ROOT/myproj" && git add .cs && git commit -q -m "bookkeeping")
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "0" "$(key "$out" not_integrated)" "nothing after the capture" || return 1
    assert_output_contains "$out" "retire: close the feature session, then: cs myproj --merge fix-auth" "retire line" || return 1
}

test_report_names_uncommitted_bookkeeping_before_retire() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true > /dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_output_contains "$out" "retire: commit the session bookkeeping in myproj" "names the uncommitted bookkeeping" || return 1
    assert_output_contains "$out" "then: cs myproj --merge fix-auth$" "still carries the retire verb" || return 1
}

test_report_after_a_squash_landing_gives_the_squash_notice() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    # Squash-shaped landing: the content arrives as an unrelated commit, F is not an ancestor.
    (cd "$CS_SESSIONS_ROOT/myproj" && git merge -q --squash cs/fix-auth >/dev/null && git commit -q -m "feature (#7)")
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "no" "$(key "$out" landed)" "F is not an ancestor after a squash" || return 1
    assert_output_contains "$out" "retire: do NOT run cs myproj --merge fix-auth" "squash notice leads the retire line" || return 1
    assert_output_contains "$out" "will try to merge the branch again" "names what the verb would do" || return 1
}

run_test test_prepare_in_feature_session_hands_off
run_test test_prepare_in_base_captures_sha_branch_and_dirt
run_test test_prepare_in_a_plain_checkout_says_so
run_test test_prepare_refuses_a_worktree_off_its_branch
# A PR opened from a fork carries the fork's own branch of the same name.
# Two independent signals mark one, and each alone must be enough.
test_prepare_filters_a_cross_repository_pr_from_the_same_owner_login() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":9,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/9","mergeCommit":{"oid":"ffff"},"mergedAt":"2026-09-13T09:00:00Z","baseRefName":"main","headRefOid":"f0f0","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":true}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "none" "$(key "$out" pr_state)" "a cross-repository PR is not this branch's PR" || return 1
}

test_prepare_filters_a_pr_whose_head_owner_is_another_account() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":9,"state":"MERGED","url":"https://github.com/other-org/example-repo/pull/9","mergeCommit":{"oid":"ffff"},"mergedAt":"2026-09-13T09:00:00Z","baseRefName":"main","headRefOid":"f0f0","headRepositoryOwner":{"login":"other-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "none" "$(key "$out" pr_state)" "another account's head repository is not this branch's PR" || return 1
}

# GitHub logins are case-insensitive; origin's URL case is whatever the user
# typed when they cloned.
test_prepare_matches_the_owner_login_case_insensitively() {
    finish_fixture myproj fix-auth > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj" remote set-url origin "git@github.com:Example-Org/example-repo.git"
    stub_gh '[{"number":7,"state":"MERGED","url":"https://github.com/Example-Org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "MERGED" "$(key "$out" pr_state)" "owner logins compare case-insensitively" || return 1
    assert_eq "7" "$(key "$out" pr_number)" "number" || return 1
}

# Every field the filter and the selection read is required. A record missing
# one would otherwise be silently dropped by the filter and reported as "none".
test_prepare_calls_a_record_missing_a_field_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":7,"state":"OPEN","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"}}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a record with no isCrossRepository cannot be classified" || return 1
    assert_output_contains "$out" "pr_reason: gh returned a PR record with missing or malformed fields (#7)" "names the record" || return 1
}

test_prepare_calls_an_unrecognised_state_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":7,"state":"DRAFT","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":null,"mergedAt":null,"baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a state outside OPEN/MERGED/CLOSED is not guessed at" || return 1
    assert_output_contains "$out" "pr_reason: gh returned a PR record with missing or malformed fields (#7)" "names the record" || return 1
}

# MERGED is the PR path's trigger and pr_merge_commit is its input: a MERGED
# PR with no merge commit would send the skill to cs with an empty sha.
test_prepare_calls_a_merged_pr_without_a_merge_commit_unknown() {
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[{"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":null,"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_state)" "a MERGED PR with no merge commit cannot drive the PR path" || return 1
    assert_output_contains "$out" "pr_reason: " "reason given" || return 1
}

run_test test_prepare_reports_a_merged_pr
run_test test_prepare_filters_a_cross_repository_pr_from_the_same_owner_login
run_test test_prepare_filters_a_pr_whose_head_owner_is_another_account
run_test test_prepare_matches_the_owner_login_case_insensitively
run_test test_prepare_calls_a_record_missing_a_field_unknown
run_test test_prepare_calls_an_unrecognised_state_unknown
run_test test_prepare_calls_a_merged_pr_without_a_merge_commit_unknown
run_test test_prepare_reports_an_open_pr
run_test test_prepare_calls_two_open_prs_unknown
run_test test_prepare_calls_a_reused_branch_unknown
run_test test_prepare_reports_closed_unmerged_as_closed
run_test test_prepare_never_reads_a_gh_failure_as_no_pr
run_test test_prepare_treats_a_vanished_head_repo_as_unknown
run_test test_prepare_skips_the_lookup_for_a_non_github_origin
run_test test_report_after_a_local_integrate_gives_the_retire_line
run_test test_report_with_an_integrated_tip_gives_the_plain_retire_line
run_test test_report_names_uncommitted_bookkeeping_before_retire
run_test test_report_after_a_squash_landing_gives_the_squash_notice

report_results
