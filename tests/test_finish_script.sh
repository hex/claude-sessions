#!/usr/bin/env bash
# ABOUTME: Tests for skills/finish/scripts/finish.sh, the read-only half of /finish
# ABOUTME: Context detection, capture, GitHub PR state via a stubbed gh, and the report

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
# prepare asks cs for the feature's readiness and finds it through CS_BIN, as a
# conversation cs launched does. Exported, so no test asks a cs installed on
# this machine.
export CS_BIN

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

# prepare reads the feature's record from cs's features screen, so the skill
# knows before it lands anything whether the integrate or the retire will
# refuse. Without a cs to ask it says so and never reads as ready.
test_prepare_predicts_the_retire_from_the_features_record() {
    local out wt="$CS_SESSIONS_ROOT/myproj@fix-auth" dir clean=""
    finish_fixture myproj fix-auth > /dev/null
    stub_gh '[]'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "0" "$(key "$out" base_dirty)" "a clean base: $out" || return 1
    assert_eq "0" "$(key "$out" feature_dirty)" "a clean feature: $out" || return 1
    assert_eq "0" "$(key "$out" feature_untracked)" "nothing untracked: $out" || return 1
    assert_eq "ready" "$(key "$out" feature_state)" "the feature is ready: $out" || return 1

    echo "uncommitted" > "$wt/scratch.txt"
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "untracked" "$(key "$out" feature_state)" "an untracked file is named by the state: $out" || return 1
    assert_eq "1" "$(key "$out" feature_untracked)" "and counted: $out" || return 1

    # A live conversation in the feature comes first in the state word, and
    # the counts still say what its retire will refuse over.
    echo "$$" > "$wt/.cs/session.lock"
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    rm -f "$wt/.cs/session.lock"
    assert_eq "locked" "$(key "$out" feature_state)" "a live feature conversation is named by the state: $out" || return 1
    assert_eq "1" "$(key "$out" feature_untracked)" "the untracked file is still counted: $out" || return 1

    while IFS= read -r -d : dir; do
        [ -x "$dir/cs" ] || clean="$clean${clean:+:}$dir"
    done <<< "$PATH:"
    out=$(env -u CS_BIN PATH="$clean" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" feature_state)" "no cs to ask: $out" || return 1
    assert_eq "no cs found (CS_BIN, PATH, ~/.local/bin/cs), so the feature's readiness was not read" "$(key "$out" feature_state_reason)" "and the reason: $out" || return 1
    assert_eq "" "$(key "$out" base_dirty)" "no field is guessed: $out" || return 1
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

# A gh on PATH that answers by route: the PR list for `pr list`, and the
# landing commit's check runs and statuses for `api .../check-runs` and
# `api .../status`. A route file named `<route>.fail` makes that call exit 1.
stub_gh_routes() {  # prlist-json checkruns-json status-json
    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/gh-routes"
    printf '%s\n' "$1" > "$TEST_TMPDIR/gh-routes/prlist"
    printf '%s\n' "$2" > "$TEST_TMPDIR/gh-routes/check-runs"
    printf '%s\n' "$3" > "$TEST_TMPDIR/gh-routes/status"
    cat > "$TEST_TMPDIR/bin/gh" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMPDIR/gh.argv"
case "\$*" in
    *check-runs*) route=check-runs ;;
    */status*) route=status ;;
    *) route=prlist ;;
esac
# A route's .fail file holds the exit code (1 when empty; 143 plays a gh_timed kill, which says nothing on stderr).
if [ -f "$TEST_TMPDIR/gh-routes/\$route.fail" ]; then code=\$(cat "$TEST_TMPDIR/gh-routes/\$route.fail"); [ "\$code" = 143 ] || echo "gh \$route failed" >&2; exit "\${code:-1}"; fi
# gh applies --jq itself; the stub does the same so the script sees lines, not JSON.
expr=""; while [ \$# -gt 0 ]; do [ "\$1" = "--jq" ] && { expr="\$2"; break; }; shift; done
if [ -n "\$expr" ]; then jq -r "\$expr" "$TEST_TMPDIR/gh-routes/\$route"; else cat "$TEST_TMPDIR/gh-routes/\$route"; fi
STUB
    chmod +x "$TEST_TMPDIR/bin/gh"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

# pr_checks folds the LANDING commit's checks into one word the skill can act
# on: success (at least one green and no red, with skipped and neutral allowed
# beside it), failure (any red), pending (some still running), none (nothing
# ran: no checks at all, or every one of them skipped), unknown (gh failed).
# The PR's own rollup describes its head, which the landing commit may not be
# (a merge with newer base changes is a tree the head's checks never saw), so
# the fold reads the check runs and statuses of pr_merge_commit itself.
test_prepare_reports_the_landing_commits_checks() {
    local pr='[{"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"a1a1","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]'
    local out
    finish_fixture myproj fix-auth > /dev/null
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"success"},{"conclusion":"skipped"},{"conclusion":"neutral"}]}' '{"statuses":[{"state":"success"}]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "success" "$(key "$out" pr_checks)" "all green, skipped or neutral" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "api --paginate repos/example-org/example-repo/commits/abc123/check-runs" "the landing commit's check runs are read, every page" || return 1
    assert_file_contains "$TEST_TMPDIR/gh.argv" "api --paginate repos/example-org/example-repo/commits/abc123/status" "and its statuses, every page" || return 1
    ! grep -q 'a1a1' "$TEST_TMPDIR/gh.argv" || { echo "  the head commit was queried instead of the landing commit"; return 1; }
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"success"},{"conclusion":"failure"}]}' '{"statuses":[]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "failure" "$(key "$out" pr_checks)" "one red check run is failure" || return 1
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"success"}]}' '{"statuses":[{"state":"error"}]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "failure" "$(key "$out" pr_checks)" "one errored status is failure" || return 1
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"startup_failure"}]}' '{"statuses":[]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "failure" "$(key "$out" pr_checks)" "a startup failure is a failure, not pending" || return 1
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"success"},{"status":"in_progress","conclusion":null}]}' '{"statuses":[]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "pending" "$(key "$out" pr_checks)" "an unfinished check run is pending" || return 1
    stub_gh_routes "$pr" '{"check_runs":[]}' '{"statuses":[{"state":"pending"}]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "pending" "$(key "$out" pr_checks)" "a pending status is pending" || return 1
    stub_gh_routes "$pr" '{"check_runs":[]}' '{"statuses":[]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "none" "$(key "$out" pr_checks)" "no checks at all is none, never success" || return 1
    # Every check skipped is nothing having run, which reads exactly like a
    # green landing commit unless success demands at least one SUCCESS.
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"skipped"},{"conclusion":"neutral"}]}' '{"statuses":[]}'
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "none" "$(key "$out" pr_checks)" "all skipped is none: nothing ran" || return 1
    stub_gh_routes "$pr" '{"check_runs":[{"conclusion":"success"}]}' '{"statuses":[]}'
    touch "$TEST_TMPDIR/gh-routes/status.fail"
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_checks)" "a failed gh call is unknown, never success" || return 1
    assert_output_contains "$out" "pr_checks_reason: gh api failed reading the checks of abc123: gh status failed" "with gh's own words" || return 1
    assert_eq "MERGED" "$(key "$out" pr_state)" "the PR state itself still reports" || return 1
    echo 143 > "$TEST_TMPDIR/gh-routes/check-runs.fail"
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    assert_eq "unknown" "$(key "$out" pr_checks)" "a killed gh is unknown" || return 1
    assert_output_contains "$out" "pr_checks_reason: gh timed out after 10 s" "and names the ceiling, since a killed child says nothing" || return 1
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
    assert_output_not_contains "$out" "retire: ready" "and retirement is not offered yet" || return 1
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
    assert_eq "ready" "$(key "$out" retire)" "retire line" || return 1
}

test_report_is_ready_to_retire_over_uncommitted_bookkeeping() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    "$CS_BIN" myproj -integrate-feature fix-auth "$sha" -- true > /dev/null 2>&1 || { echo "  FAIL: integrate failed"; return 1; }
    out=$(CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME="myproj" \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    # The retire entry tolerates the base's own .cs/ dirt, so the tracked-mode
    # timeline event the integrate just wrote is no reason to wait.
    assert_eq "ready" "$(key "$out" retire)" "ready despite the uncommitted bookkeeping" || return 1
}

# Squash-shaped landing: the branch's content arrives on the base as one
# unrelated commit, so the captured commit is never an ancestor.
squash_land() {  # base task
    (cd "$CS_SESSIONS_ROOT/$1" && git merge -q --squash "cs/$2" >/dev/null && git commit -q -m "$2 (#7)")
}

report_for() {  # base task sha
    CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/$1" CLAUDE_SESSION_NAME="$1" bash "$FINISH" report "$1" "$2" "$3" 2>&1
}

# A MERGED PR for cs/fix-auth whose head is <head-oid>, with no checks.
stub_merged_pr() {  # head-oid
    stub_gh_routes '[{"number":7,"state":"MERGED","url":"https://github.com/example-org/example-repo/pull/7","mergeCommit":{"oid":"abc123"},"mergedAt":"2026-09-12T09:00:00Z","baseRefName":"main","headRefOid":"'"$1"'","headRepositoryOwner":{"login":"example-org"},"isCrossRepository":false}]' \
        '{"check_runs":[]}' '{"statuses":[]}'
}

# The tree is the evidence: a branch whose every changed path is byte for
# byte on the base loses nothing but history when it goes, so no PR at all
# (a local squash, a cherry-pick) is no reason to keep it. The retire entry
# then takes it under --force.
test_report_after_a_squash_landing_with_no_pr_is_content_landed() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    squash_land myproj fix-auth
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "no" "$(key "$out" landed)" "F is not an ancestor after a squash" || return 1
    assert_eq "none" "$(key "$out" pr_state)" "there is no PR" || return 1
    assert_eq "content-landed" "$(key "$out" retire)" "every changed path is on the base" || return 1
    assert_eq "1" "$(key "$out" retire_paths_checked)" "the one path the branch changed was checked" || return 1
    assert_output_contains "$out" "retire_note: cs/fix-auth is not an ancestor of base, but every path it changed is identical on base HEAD; retire with --force" \
        "the note says why force is safe" || return 1
    out=$("$CS_BIN" myproj -retire-feature fix-auth "$sha" --force 2>&1) || { echo "  FAIL: retire refused: $out"; return 1; }
    assert_eq "retired fix-auth $sha" "$out" "the entry retires it under --force" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "the worktree is gone" || return 1
}

# Today's PR evidence (MERGED, head == captured sha) and the content check
# agree on a clean squash landing.
test_report_content_landed_with_a_pr_head_equal_to_the_capture() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_merged_pr "$sha"
    squash_land myproj fix-auth
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "MERGED" "$(key "$out" pr_state)" "the PR merged" || return 1
    assert_eq "$sha" "$(key "$out" pr_head_oid)" "its head is the capture" || return 1
    assert_eq "content-landed" "$(key "$out" retire)" "and the content is on the base" || return 1
}

# The PR's head is not the capture (the PR landed through other commits), but
# every path the branch changed is on the base: the PR head says nothing the
# tree does not settle.
test_report_content_landed_whatever_the_pr_head_says() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_merged_pr a1a1
    squash_land myproj fix-auth
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "a1a1" "$(key "$out" pr_head_oid)" "the PR head differs from the capture" || return 1
    assert_eq "content-landed" "$(key "$out" retire)" "the content check decides" || return 1
    assert_eq "1" "$(key "$out" retire_paths_checked)" "one path checked" || return 1
}

# One path the base holds differently keeps the refusal, and the refusal
# names it. The base carries the other path exactly as the branch has it.
test_report_refuses_a_branch_with_one_path_not_on_the_base() {
    local sha out wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    finish_fixture myproj fix-auth > /dev/null
    echo "second" > "$wt/second.txt"
    (cd "$wt" && git add second.txt && git commit -q -m "second")
    sha=$(git -C "$wt" rev-parse HEAD)
    stub_gh '[]'
    (cd "$CS_SESSIONS_ROOT/myproj" && echo "feature work" > feature.txt && echo "not the branch's" > second.txt \
        && git add feature.txt second.txt && git commit -q -m "partial landing")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "a path that differs is not landed" || return 1
    assert_output_contains "$out" "retire_note: cs/fix-auth is not an ancestor of base (a squash or rebase landing); retire with --force only on a MERGED pr_state" \
        "the note says when force is legitimate" || return 1
    assert_eq "1 of 2" "$(key "$out" retire_paths_differing)" "one of the two changed paths differs" || return 1
    assert_eq "second.txt" "$(printf '%s\n' "$out" | sed -n 's/^retire_differs: //p')" "and only it is named" || return 1
}

# The base edited the landed path again after the squash: the branch's
# version is no longer what the base holds, so the check refuses. The PR
# evidence (MERGED, head == capture) stays for the skill's own --force arm.
test_report_refuses_a_path_the_base_edited_after_the_landing() {
    local sha out
    sha=$(finish_fixture myproj fix-auth)
    stub_merged_pr "$sha"
    squash_land myproj fix-auth
    (cd "$CS_SESSIONS_ROOT/myproj" && echo "edited on the base" >> feature.txt && git commit -q -am "edit")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the base's later edit means the content differs" || return 1
    assert_eq "1 of 1" "$(key "$out" retire_paths_differing)" "the one path differs" || return 1
    assert_eq "feature.txt" "$(key "$out" retire_differs)" "and is named" || return 1
    assert_eq "MERGED" "$(key "$out" pr_state)" "the PR state still reports" || return 1
    assert_eq "$sha" "$(key "$out" pr_head_oid)" "with the head the skill compares" || return 1
}

# A deletion lands when the path is absent on the base too; a rename is a
# deletion and an addition, both checked.
test_report_content_landed_counts_a_deleted_and_a_renamed_path() {
    local sha out base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    create_test_session_with_git myproj > /dev/null
    git -C "$base" remote add origin "git@github.com:example-org/example-repo.git"
    (cd "$base" && echo gone > gone.txt && echo moved > old-name.txt && git add gone.txt old-name.txt && git commit -q -m "base files")
    cs_launch "myproj@fix-auth"
    (cd "$wt" && git rm -q gone.txt && git mv old-name.txt new-name.txt && git commit -q -m "delete and rename")
    sha=$(git -C "$wt" rev-parse HEAD)
    stub_gh '[]'
    squash_land myproj fix-auth
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "content-landed" "$(key "$out" retire)" "the deletion and the rename landed" || return 1
    assert_eq "3" "$(key "$out" retire_paths_checked)" "gone.txt, old-name.txt and new-name.txt" || return 1
    # The same branch against a base that kept the deleted file.
    (cd "$base" && echo gone > gone.txt && git add gone.txt && git commit -q -m "restore")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "a deleted path the base still holds differs" || return 1
    assert_eq "gone.txt" "$(key "$out" retire_differs)" "and is named" || return 1
}

# The same bytes with another mode are not the branch's content.
test_report_refuses_a_mode_change_the_base_lacks() {
    local sha out base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    create_test_session_with_git myproj > /dev/null
    git -C "$base" remote add origin "git@github.com:example-org/example-repo.git"
    (cd "$base" && printf '#!/bin/sh\n' > run.sh && git add run.sh && git commit -q -m "script")
    cs_launch "myproj@fix-auth"
    (cd "$wt" && chmod +x run.sh && git commit -q -am "make it executable")
    sha=$(git -C "$wt" rev-parse HEAD)
    stub_gh '[]'
    (cd "$base" && git commit -q --allow-empty -m "unrelated")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the mode change is not on the base" || return 1
    assert_eq "run.sh" "$(key "$out" retire_differs)" "and is named" || return 1
}

# The refusal names ten paths at most and counts the rest.
test_report_names_at_most_ten_differing_paths() {
    local sha out i wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    finish_fixture myproj fix-auth > /dev/null
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "$i" > "$wt/p$i.txt"; done
    (cd "$wt" && git add p*.txt && git commit -q -m "twelve")
    sha=$(git -C "$wt" rev-parse HEAD)
    stub_gh '[]'
    (cd "$CS_SESSIONS_ROOT/myproj" && git commit -q --allow-empty -m "unrelated")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "13 of 13" "$(key "$out" retire_paths_differing)" "every changed path differs" || return 1
    assert_eq "feature.txt p01.txt p02.txt p03.txt p04.txt p05.txt p06.txt p07.txt p08.txt p09.txt" \
        "$(printf '%s\n' "$out" | sed -n 's/^retire_differs: //p' | tr '\n' ' ' | sed 's/ $//')" "the first ten are named" || return 1
    assert_eq "3" "$(key "$out" retire_differs_more)" "the rest are counted" || return 1
}

# A tip past the captured commit holds work no landing carried; the entry
# refuses it under --force, so the report says what to do instead.
test_report_content_landed_waits_for_commits_after_the_capture() {
    local sha out wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    sha=$(finish_fixture myproj fix-auth)
    stub_gh '[]'
    squash_land myproj fix-auth
    (cd "$wt" && git commit -q --allow-empty -m "after capture")
    out=$(report_for myproj fix-auth "$sha")
    assert_output_contains "$out" "retire: 1 commit(s) on cs/fix-auth after the captured commit are not integrated; run /finish fix-auth again before retiring" \
        "the later commit is named before any retire" || return 1
    assert_output_not_contains "$out" "content-landed" "content-landed is not claimed" || return 1
}

# The base records submodule `mod` at one commit, with .gitmodules giving it
# <ignore> (none when empty). The branch bumps the pointer and adds feat.txt;
# only feat.txt lands on the base, so the branch is the one ref holding the
# bump. No cs launch: the report reads only the two git trees. Prints the
# captured sha.
gitlink_bump_fixture() {  # ignore
    local base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth" sub="$TEST_TMPDIR/sub" c1 c2
    create_test_session_with_git myproj > /dev/null
    git init -q "$sub"
    (cd "$sub" && echo 1 > f && git add f && git commit -q -m one)
    c1=$(git -C "$sub" rev-parse HEAD)
    (cd "$sub" && echo 2 > f && git commit -q -am two)
    c2=$(git -C "$sub" rev-parse HEAD)
    printf '[submodule "mod"]\n\tpath = mod\n\turl = %s\n' "$sub" > "$base/.gitmodules"
    [ -z "$1" ] || printf '\tignore = %s\n' "$1" >> "$base/.gitmodules"
    (cd "$base" && git add .gitmodules && git update-index --add --cacheinfo "160000,$c1,mod" && git commit -q -m "submodule")
    git -C "$base" worktree add -q -b cs/fix-auth "$wt"
    (cd "$wt" && git update-index --cacheinfo "160000,$c2,mod" && echo feat > feat.txt && git add feat.txt \
        && git commit -q -m "bump mod")
    (cd "$base" && echo feat > feat.txt && git add feat.txt && git commit -q -m "feat only")
    git -C "$wt" rev-parse HEAD
}

# A submodule the project tells diff to ignore still has a pointer: a bump
# the base never got is content the retire would lose.
test_report_refuses_a_submodule_bump_gitmodules_ignores() {
    local sha out
    sha=$(gitlink_bump_fixture all)
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the bump is not on the base" || return 1
    assert_eq "1 of 2" "$(key "$out" retire_paths_differing)" "feat.txt landed, mod did not" || return 1
    assert_eq "mod" "$(key "$out" retire_differs)" "and the submodule is named" || return 1
}

# The same through the user's git config instead of .gitmodules.
test_report_refuses_a_submodule_bump_diff_config_ignores() {
    local sha out
    sha=$(gitlink_bump_fixture "")
    git -C "$CS_SESSIONS_ROOT/myproj" config diff.ignoreSubmodules all
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the bump is not on the base" || return 1
    assert_eq "1 of 2" "$(key "$out" retire_paths_differing)" "feat.txt landed, mod did not" || return 1
    assert_eq "mod" "$(key "$out" retire_differs)" "and the submodule is named" || return 1
}

# A base session and its worktree on cs/fix-auth, both plain git: the report
# reads only their trees, so no cs launch.
plain_fixture() {
    create_test_session_with_git myproj > /dev/null
    git -C "$CS_SESSIONS_ROOT/myproj" worktree add -q -b cs/fix-auth "$CS_SESSIONS_ROOT/myproj@fix-auth"
}

# The branch adds one file named <name>; the base adds the same name with
# other content. Prints the captured sha.
one_name_differs_fixture() {  # name
    local base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && printf 'branch\n' > "$1" && git add -A && git commit -q -m "branch")
    (cd "$base" && printf 'base\n' > "$1" && git add -A && git commit -q -m "base")
    git -C "$wt" rev-parse HEAD
}

# A path name is a name, never a pathspec: `:(glob)zz` names a file, and the
# base holding that file differently is a refusal.
test_report_refuses_a_pathspec_magic_name_the_base_holds_differently() {
    local sha out
    sha=$(one_name_differs_fixture ':(glob)zz')
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the file differs on the base" || return 1
    assert_eq "1 of 1" "$(key "$out" retire_paths_differing)" "the one path differs" || return 1
    assert_eq ":(glob)zz" "$(key "$out" retire_differs)" "and is named as it is" || return 1
}

# A newline inside a name is one path, never two: the refusal names it once,
# in git's quoted form.
test_report_refuses_a_newline_name_the_base_holds_differently() {
    local sha out
    sha=$(one_name_differs_fixture $'nl\nname')
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the file differs on the base" || return 1
    assert_eq "1 of 1" "$(key "$out" retire_paths_differing)" "the one path differs" || return 1
    assert_eq '"nl\nname"' "$(printf '%s\n' "$out" | sed -n 's/^retire_differs: //p')" "and is named once, quoted" || return 1
}

# A capture that shares no history with the base has no "what the branch
# changed" to compare, so nothing vouches for it.
test_report_refuses_a_capture_with_no_merge_base() {
    local sha tree out wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && echo orphan > orphan.txt && git add orphan.txt)
    tree=$(git -C "$wt" write-tree)
    sha=$(git -C "$wt" commit-tree -m orphan "$tree")
    git -C "$wt" reset -q --hard "$sha"
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "no" "$(key "$out" landed)" "the capture is not an ancestor" || return 1
    assert_eq "not-landed" "$(key "$out" retire)" "no merge base is not landed" || return 1
    assert_output_not_contains "$out" "retire_paths" "no path counts" || return 1
    assert_output_not_contains "$out" "retire_differs" "and no path names" || return 1
}

# The branch renames a to b and edits a line of it, and renames x to y as it
# is; the base renames a to c and x to z, both as they were. The branch's edit
# is in b and nowhere on the base, however alike b and c are, and y is a path
# the base does not have, even with z's bytes.
test_report_refuses_paths_the_branch_renamed_and_the_base_renamed_elsewhere() {
    local sha out base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && printf 'line1\nline2\nline3\nline4\nline5\n' > a && echo "content of x" > x && git add a x \
        && git commit -q -m "a and x")
    git -C "$base" merge -q --ff-only cs/fix-auth
    (cd "$wt" && git mv a b && printf 'line1\nline2\nbranch edit\nline4\nline5\n' > b && git mv x y \
        && git commit -q -am "a to b, edited; x to y")
    sha=$(git -C "$wt" rev-parse HEAD)
    (cd "$base" && git mv a c && git mv x z && git commit -q -m "a to c; x to z")
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "not-landed" "$(key "$out" retire)" "the edit in b is not on the base" || return 1
    assert_eq "2 of 4" "$(key "$out" retire_paths_differing)" "a and x are gone on both sides, b and y are not on the base" || return 1
    assert_eq "b y" "$(printf '%s\n' "$out" | sed -n 's/^retire_differs: //p' | tr '\n' ' ' | sed 's/ $//')" \
        "and only b and y are named" || return 1
}

# A worktree path that holds a plain directory has no HEAD to read: the
# report says so on an error line and stops. The ceiling keeps git from
# finding a repository above the sessions root.
test_report_says_error_when_the_worktree_is_not_a_git_checkout() {
    local sha out status=0 wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    create_test_session_with_git myproj > /dev/null
    sha=$(git -C "$CS_SESSIONS_ROOT/myproj" rev-parse HEAD)
    mkdir -p "$wt"
    out=$(GIT_CEILING_DIRECTORIES="$CS_SESSIONS_ROOT" report_for myproj fix-auth "$sha") || status=$?
    assert_eq "1" "$status" "the report fails" || return 1
    assert_eq "error: git rev-parse HEAD failed in the worktree $wt" "$(printf '%s\n' "$out" | tail -1)" \
        "and says so last" || return 1
    assert_output_not_contains "$out" "retire:" "with no retire line" || return 1
}

# A branch whose changed path names add up to more bytes than one command
# line holds (ARG_MAX, measured here) is checked like any other. The paths
# are about 490 bytes each and live only in the index and the commits, never
# on disk; both sides get the same ones, so the content landed.
test_report_checks_more_path_bytes_than_a_command_line_holds() {
    local sha out n blob dir base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    n=$(( $(getconf ARG_MAX) / 400 ))
    blob=$(printf 'same\n' | git -C "$wt" hash-object -w --stdin)
    dir="$(printf '%0240d' 0 | tr 0 d)/$(printf '%0240d' 0 | tr 0 e)"
    awk -v n="$n" -v b="$blob" -v d="$dir" \
        'BEGIN { for (i = 1; i <= n; i++) printf "100644 %s\t%s/f%06d\n", b, d, i }' > "$TEST_TMPDIR/index-info"
    git -C "$wt" update-index --index-info < "$TEST_TMPDIR/index-info"
    git -C "$wt" commit -q -m "many paths"
    sha=$(git -C "$wt" rev-parse HEAD)
    git -C "$base" update-index --index-info < "$TEST_TMPDIR/index-info"
    git -C "$base" commit -q -m "the same paths"
    out=$(report_for myproj fix-auth "$sha")
    assert_eq "content-landed" "$(key "$out" retire)" "every path is on the base" || return 1
    assert_eq "$n" "$(key "$out" retire_paths_checked)" "and every one was checked" || return 1
}

# A name that is not UTF-8, printed raw (core.quotePath false) under a UTF-8
# locale, is reported like any other name. It has no ASCII byte at all, which
# is what a UTF-8 grep or sed trips on. It goes in through the index, as some
# filesystems refuse it on disk, so the worktree shows it deleted. The output
# holds those bytes, so it is read in the C locale here too.
test_report_names_a_non_utf8_path_under_a_utf8_locale() {
    local sha out blob name=$'\xff\xfe' base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    git -C "$base" config core.quotePath false
    (cd "$wt" && echo ok > good.txt && git add good.txt)
    blob=$(printf 'branch\n' | git -C "$wt" hash-object -w --stdin)
    git -C "$wt" update-index --add --cacheinfo "100644,$blob,$name"
    git -C "$wt" commit -q -m "two files"
    sha=$(git -C "$wt" rev-parse HEAD)
    (cd "$base" && echo ok > good.txt && git add good.txt)
    blob=$(printf 'base\n' | git -C "$base" hash-object -w --stdin)
    git -C "$base" update-index --add --cacheinfo "100644,$blob,$name"
    git -C "$base" commit -q -m "the same name, other content"
    out=$(LC_ALL=C.UTF-8 CLAUDE_SESSION_DIR="$base" CLAUDE_SESSION_NAME=myproj \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1)
    assert_eq "dirt:  D $name" "$(printf '%s\n' "$out" | LC_ALL=C sed -n '/^dirt: /p')" "the worktree's missing file is named" || return 1
    assert_eq "not-landed" "$(printf '%s\n' "$out" | LC_ALL=C sed -n 's/^retire: //p')" "the name differs on the base" || return 1
    assert_eq "1 of 2" "$(printf '%s\n' "$out" | LC_ALL=C sed -n 's/^retire_paths_differing: //p')" "good.txt landed" || return 1
    assert_eq "$name" "$(printf '%s\n' "$out" | LC_ALL=C sed -n 's/^retire_differs: //p')" "and the name is printed as git has it" || return 1
}

# Whatever stops the content check, the report ends on an error line, never
# in silence: here perl, which matches the paths, fails without a word.
test_report_says_error_when_the_content_check_stops_without_one() {
    local sha out status=0 wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && echo work > work.txt && git add work.txt && git commit -q -m "work")
    sha=$(git -C "$wt" rev-parse HEAD)
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 3\n' > "$TEST_TMPDIR/bin/perl"
    chmod +x "$TEST_TMPDIR/bin/perl"
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME=myproj \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the report fails" || return 1
    assert_eq "error: comparing the paths cs/fix-auth changed with base HEAD failed (exit 3)" \
        "$(printf '%s\n' "$out" | tail -1)" "and says so last" || return 1
    assert_output_not_contains "$out" "retire:" "with no retire line" || return 1
}

# The content check compares the capture with the base_head the report
# prints, whatever the base commits while it runs. The branch has a=1 b=1,
# the base a=1 b=2, so b differs. A git stand-in commits a=9 b=1 on the base
# just before git lists the differing names as it quotes them; that later
# commit must not make the report name a.
test_report_checks_the_base_head_it_prints_while_the_base_moves() {
    local sha head out realgit base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && echo 1 > a && echo 1 > b && git add a b && git commit -q -m "a and b")
    sha=$(git -C "$wt" rev-parse HEAD)
    (cd "$base" && echo 1 > a && echo 2 > b && git add a b && git commit -q -m "a, and b otherwise")
    head=$(git -C "$base" rev-parse HEAD)
    realgit=$(command -v git)
    mkdir -p "$TEST_TMPDIR/racebin"
    cat > "$TEST_TMPDIR/racebin/git" << SHIM
#!/bin/sh
case " \$* " in
    *" -z "*) ;;
    *" diff "*" --name-only $sha "*)
        if [ ! -e "$TEST_TMPDIR/raced" ]; then
            : > "$TEST_TMPDIR/raced"
            (cd "$base" && echo 9 > a && echo 1 > b && "$realgit" commit -q -am "race") || exit 99
        fi ;;
esac
exec "$realgit" "\$@"
SHIM
    chmod +x "$TEST_TMPDIR/racebin/git"
    out=$(PATH="$TEST_TMPDIR/racebin:$PATH" report_for myproj fix-auth "$sha")
    assert_eq "9" "$(git -C "$base" show HEAD:a)" "the base committed during the check" || return 1
    assert_eq "$head" "$(key "$out" base_head)" "the report prints the base_head from before it" || return 1
    assert_eq "not-landed" "$(key "$out" retire)" "b differs on that base_head" || return 1
    assert_eq "1 of 2" "$(key "$out" retire_paths_differing)" "one of a and b differs" || return 1
    assert_eq "b" "$(printf '%s\n' "$out" | sed -n 's/^retire_differs: //p')" "and it is b, not a" || return 1
}

# A base whose HEAD git cannot read has no base_head to check against: the
# report says so on an error line and stops. The ceiling keeps git from
# finding a repository above the sessions root.
test_report_says_error_when_the_base_is_not_a_git_checkout() {
    local sha out status=0 base="$CS_SESSIONS_ROOT/myproj" wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    mkdir -p "$base"
    git init -q "$wt"
    (cd "$wt" && echo work > work.txt && git add work.txt && git commit -q -m "work")
    sha=$(git -C "$wt" rev-parse HEAD)
    out=$(GIT_CEILING_DIRECTORIES="$CS_SESSIONS_ROOT" report_for myproj fix-auth "$sha") || status=$?
    assert_eq "1" "$status" "the report fails" || return 1
    assert_eq "error: git rev-parse HEAD failed in the base $base" "$(printf '%s\n' "$out" | tail -1)" \
        "and says so last" || return 1
    assert_output_not_contains "$out" "retire:" "with no retire line" || return 1
}

# A content check that succeeds without counting the paths it checked has
# vouched for nothing: here perl exits 0 and prints nothing.
test_report_says_error_when_the_content_check_counts_no_paths() {
    local sha out status=0 wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    plain_fixture
    (cd "$wt" && echo work > work.txt && git add work.txt && git commit -q -m "work")
    sha=$(git -C "$wt" rev-parse HEAD)
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/bin/perl"
    chmod +x "$TEST_TMPDIR/bin/perl"
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" CLAUDE_SESSION_NAME=myproj \
        bash "$FINISH" report myproj fix-auth "$sha" 2>&1) || status=$?
    assert_eq "1" "$status" "the report fails" || return 1
    assert_eq "error: comparing the paths cs/fix-auth changed with base HEAD gave '' as the path count, not none or a number" \
        "$(printf '%s\n' "$out" | tail -1)" "and says so last" || return 1
    assert_output_not_contains "$out" "retire:" "with no retire line" || return 1
}

run_test test_prepare_in_feature_session_hands_off
run_test test_prepare_in_base_captures_sha_branch_and_dirt
run_test test_prepare_predicts_the_retire_from_the_features_record
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
run_test test_prepare_reports_the_landing_commits_checks
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
# A gh that hangs (a stalled network call, an auth prompt) must not hold the
# whole ritual open. The ceiling is enforced by killing the child, not by
# waiting for it.
test_prepare_gives_up_on_a_gh_that_hangs() {
    finish_fixture myproj fix-auth > /dev/null
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nexec sleep 12\n' > "$TEST_TMPDIR/bin/gh"
    chmod +x "$TEST_TMPDIR/bin/gh"
    local started ended out
    started=$(date +%s)
    out=$(PATH="$TEST_TMPDIR/bin:$PATH" CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/myproj" \
        CLAUDE_SESSION_NAME="myproj" bash "$FINISH" prepare fix-auth 2>&1)
    ended=$(date +%s)
    assert_eq "unknown" "$(key "$out" pr_state)" "a hung gh is unknown, never none" || return 1
    assert_output_contains "$out" "pr_reason: gh timed out after 10 s" "names the timeout" || return 1
    [ "$((ended - started))" -lt 15 ] \
        || { echo "  FAIL: the lookup must give up at the ceiling; it took $((ended - started))s"; return 1; }
}

run_test test_prepare_never_reads_a_gh_failure_as_no_pr
run_test test_prepare_gives_up_on_a_gh_that_hangs
run_test test_prepare_treats_a_vanished_head_repo_as_unknown
run_test test_prepare_skips_the_lookup_for_a_non_github_origin
run_test test_report_after_a_local_integrate_gives_the_retire_line
run_test test_report_with_an_integrated_tip_gives_the_plain_retire_line
run_test test_report_is_ready_to_retire_over_uncommitted_bookkeeping
run_test test_report_after_a_squash_landing_with_no_pr_is_content_landed
run_test test_report_content_landed_with_a_pr_head_equal_to_the_capture
run_test test_report_content_landed_whatever_the_pr_head_says
run_test test_report_refuses_a_branch_with_one_path_not_on_the_base
run_test test_report_refuses_a_path_the_base_edited_after_the_landing
run_test test_report_content_landed_counts_a_deleted_and_a_renamed_path
run_test test_report_refuses_a_mode_change_the_base_lacks
run_test test_report_names_at_most_ten_differing_paths
run_test test_report_content_landed_waits_for_commits_after_the_capture
run_test test_report_refuses_a_submodule_bump_gitmodules_ignores
run_test test_report_refuses_a_submodule_bump_diff_config_ignores
run_test test_report_refuses_a_pathspec_magic_name_the_base_holds_differently
run_test test_report_refuses_a_newline_name_the_base_holds_differently
run_test test_report_refuses_a_capture_with_no_merge_base
run_test test_report_refuses_paths_the_branch_renamed_and_the_base_renamed_elsewhere
run_test test_report_says_error_when_the_worktree_is_not_a_git_checkout
run_test test_report_checks_more_path_bytes_than_a_command_line_holds
run_test test_report_names_a_non_utf8_path_under_a_utf8_locale
run_test test_report_says_error_when_the_content_check_stops_without_one
run_test test_report_checks_the_base_head_it_prints_while_the_base_moves
run_test test_report_says_error_when_the_base_is_not_a_git_checkout
run_test test_report_says_error_when_the_content_check_counts_no_paths

report_results
