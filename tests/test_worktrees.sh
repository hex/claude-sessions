#!/usr/bin/env bash
# ABOUTME: Tests for worktree-backed parallel task sessions
# ABOUTME: Covers name parsing, creation, launch env, merge-back, removal, doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Launch-gated suite: on a real MSYS runner the Claude launch short-circuits
# (Tier 2 = session management only), so pin a supported platform there. See
# _apply_suite_platform_pin in test_lib.sh (no-op on macOS/Linux lanes).
SUITE_PIN_NONMSYS=1

# --- Name parsing (via cs CLI behavior) ---

test_worktree_name_rejected_without_base() {
    local output
    output=$("$CS_BIN" "@fix-auth" 2>&1 || true)
    assert_output_contains "$output" "Session name" "empty base half must be rejected" || return 1
}

test_worktree_name_rejects_bad_task_half() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj@fix/auth" 2>&1 || true)
    assert_output_contains "$output" "feature name" "slash in feature half must be rejected" || return 1
}

test_plain_names_still_work() {
    local output
    output=$("$CS_BIN" "-list" 2>&1)
    assert_output_not_contains "$output" "Unknown" "plain subcommands unaffected" || return 1
}

# Launch cs against a session/worktree with stdin closed; the echo stub
# stands in for claude so cs exits after setup.
cs_launch() {
    "$CS_BIN" "$1" < /dev/null > /dev/null 2>&1 || true
}

# Build a ps seam for the ownership walk. Process inspection may be restricted
# in a test sandbox; production uses BSD ps, while these integration tests
# inject the one parent edge relevant to the scenario.
fixed_parent_ps_stub() {
    local parent="$1" stub="$TEST_TMPDIR/parent-ps-stub"
    cat > "$stub" << STUB
#!/usr/bin/env bash
printf '%s\n' "$parent"
STUB
    chmod +x "$stub"
    echo "$stub"
}

test_worktree_create_tracked_mode() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    assert_dir "$wt" "worktree dir should exist" || return 1
    assert_file_exists "$wt/.git" "linked worktree .git should be a file" || return 1
    assert_eq "cs/fix-auth" "$(git -C "$wt" branch --show-current)" "worktree on task branch" || return 1
    assert_file_exists "$wt/.cs/README.md" "tracked .cs rides the checkout" || return 1
    assert_file_contains "$wt/.cs/local/state" "task_branch: cs/fix-auth" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: tracked" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_base: myproj" || return 1
    # Fresh identity, not the base's
    local base_uuid wt_uuid
    base_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$base_dir/.cs/local/state")
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2}' "$wt/.cs/local/state")
    [ "$base_uuid" != "$wt_uuid" ] || { echo "  FAIL: worktree must get its own UUID"; return 1; }
}

test_worktree_create_refuses_dirty_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "change" >> "$base_dir/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty base must refuse" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@fix-auth" "no worktree on refusal" || return 1
}

test_worktree_create_reuses_existing_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    git -C "$base_dir" branch cs/fix-auth
    cs_launch "myproj@fix-auth"
    assert_eq "cs/fix-auth" "$(git -C "$CS_SESSIONS_ROOT/myproj@fix-auth" branch --show-current)" \
        "existing branch is reused, not errored on" || return 1
}

test_worktree_create_ignored_mode_bootstraps_cs() {
    # A repo whose .gitignore excludes .cs/ entirely (like the cs dev repo)
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project readme" > "$base_dir/README.md"
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # autocrlf is on by default in Git for Windows and would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    local wt="$CS_SESSIONS_ROOT/proj@task1"
    assert_dir "$wt/.cs/memory" "ignored mode bootstraps .cs skeleton" || return 1
    assert_file_contains "$wt/.cs/local/state" "cs_mode: ignored" || return 1
    assert_eq "# Project CLAUDE.md" "$(cat "$wt/CLAUDE.md")" \
        "bootstrap must not overwrite the project's CLAUDE.md" || return 1
}

test_worktree_of_worktree_refused() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj@fix-auth@deeper" 2>&1 || true)
    assert_output_contains "$output" "feature name" "second @ lands in the feature half and is rejected" || return 1
}

test_worktree_create_succeeds_with_untracked_base() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "stray" > "$base_dir/stray.txt"   # untracked, must not corrupt the captured path
    local output status=0
    output=$("$CS_BIN" "myproj@fix-auth" < /dev/null 2>&1) || status=$?
    assert_eq "0" "$status" "cs must exit 0 despite the untracked-files warning" || return 1
    assert_output_not_contains "$output" "No such file" \
        "captured worktree path must not be corrupted by the warning" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@fix-auth" "worktree created" || return 1
}

test_worktree_reopen_preserves_project_claude_md() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# Project CLAUDE.md" > "$base_dir/CLAUDE.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    # autocrlf is on by default in Git for Windows and would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@task1"
    cs_launch "proj@task1"   # reopen — the path that used to run migrate_session
    assert_eq "# Project CLAUDE.md" "$(cat "$CS_SESSIONS_ROOT/proj@task1/CLAUDE.md")" \
        "reopen must not rewrite the project's CLAUDE.md" || return 1
}

test_worktree_launch_exports_base_identity() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create first
    local stub env_out _try
    stub=$(_make_env_stub)
    # The reopen launch execs the stub, which prints its env. On a loaded runner
    # the launch can occasionally race the create launch's lock/PID cleanup and
    # take a cancel path, capturing empty output. Retry until the exported
    # identity appears, so the assertions test the identity, not runner load; a
    # genuine failure to export still fails all attempts.
    for _try in 1 2 3 4 5; do
        env_out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "myproj@fix-auth" <<< "n" 2>/dev/null || true)
        case "$env_out" in *"CLAUDE_SESSION_NAME=myproj@fix-auth"*) break ;; esac
    done
    assert_output_contains "$env_out" "CLAUDE_SESSION_NAME=myproj@fix-auth" "display identity is the task name" || return 1
    assert_output_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj" "task list is shared with the base" || return 1
    assert_output_not_contains "$env_out" "CLAUDE_CODE_TASK_LIST_ID=myproj@" "task list id must be the base, not the worktree name" || return 1
    assert_output_contains "$env_out" "CS_SECRETS_SESSION=myproj" "secrets stay keyed to the base" || return 1
}

test_merge_tracked_worktree_fuses_and_cleans_up() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Simulate task work: code + session records, committed on the branch
    echo "fix" > "$wt/auth.txt"
    echo '{"ts":"2026-07-02T00:00:00Z","event":"task"}' >> "$wt/.cs/timeline.jsonl"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1)
    assert_file_exists "$base_dir/auth.txt" "code merged into base" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" '"event":"task"' "timeline union-merged" || return 1
    assert_not_exists "$wt" "worktree removed after merge" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "branch deleted" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "worktree-merged" "merge recorded" || return 1
}

test_merge_refuses_dirty_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "uncommitted" >> "$wt/CLAUDE.md"
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "uncommitted" "dirty worktree refused" || return 1
    assert_dir "$wt" "worktree preserved on refusal" || return 1
}

test_merge_refuses_live_session() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "session is open" "live lock refused" || return 1
    rm -f "$wt/.cs/session.lock"
}

test_merge_from_live_base_session_succeeds() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="11111111-1111-4111-8111-111111111111"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")

    # The lock owner is this test shell, an ancestor of the cs subprocess just
    # like a cs launcher/Claude process is an ancestor of an in-session Bash tool.
    echo "$$" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "$$")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?

    assert_eq "0" "$status" "the live base session should be allowed to merge: $output" || return 1
    assert_file_exists "$base_dir/auth.txt" "feature code merged into the base" || return 1
    assert_not_exists "$wt" "merged worktree removed" || return 1
    assert_eq "" "$(git -C "$base_dir" branch --list cs/fix-auth)" "merged branch deleted" || return 1
}

test_merge_from_live_worktree_session_requires_handoff() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local wt_uuid
    wt_uuid=$(awk -F': ' '/^claude_session_id/{print $2; exit}' "$wt/.cs/local/state")
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add auth.txt && git commit -q -m "task work")

    echo "$$" > "$wt/.cs/session.lock"
    local output status=0
    output=$(cd "$wt" && CLAUDE_SESSION_NAME="myproj@fix-auth" \
        CS_CLAUDE_SESSION_ID="$wt_uuid" \
        "$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a feature session must not remove its own live worktree"; return 1; }
    assert_output_contains "$output" "Cannot merge 'myproj@fix-auth' from inside that worktree session" \
        "self-merge refusal identifies the dangerous scenario" || return 1
    assert_output_contains "$output" "Close 'myproj@fix-auth'" \
        "self-merge refusal gives the narrowed hand-off" || return 1
    assert_dir "$wt" "self-merge refusal preserves the worktree" || return 1
    assert_file_not_exists "$base_dir/auth.txt" "self-merge refusal leaves the base unchanged" || return 1
}

test_merge_foreign_live_base_lock_still_refuses() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="22222222-2222-4222-8222-222222222222"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$base_dir/.cs/session.lock"

    local output status=0
    output=$(CLAUDE_SESSION_NAME="foreign" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?

    [ "$status" -ne 0 ] || { echo "  FAIL: a foreign live base lock must refuse"; return 1; }
    assert_output_contains "$output" "session is open" "foreign live lock keeps the hard refusal" || return 1
    assert_dir "$wt" "foreign-lock refusal preserves the worktree" || return 1
}

test_merge_reused_live_pid_is_not_treated_as_own_lock() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    local base_uuid="33333333-3333-4333-8333-333333333333"
    mkdir -p "$base_dir/.cs/local"
    printf 'claude_session_id: %s\n' "$base_uuid" > "$base_dir/.cs/local/state"
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"

    # A stale lock can point at a PID later reused by an unrelated live process.
    # The matching name and UUID are insufficient: that PID must own this cs call.
    sleep 30 &
    local reused_pid=$!
    echo "$reused_pid" > "$base_dir/.cs/session.lock"
    local output status=0 ps_stub
    ps_stub=$(fixed_parent_ps_stub "1")
    output=$(CLAUDE_SESSION_NAME="myproj" CS_PS_BIN="$ps_stub" \
        CS_CLAUDE_SESSION_ID="$base_uuid" \
        "$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?
    kill "$reused_pid" 2>/dev/null || true
    wait "$reused_pid" 2>/dev/null || true

    [ "$status" -ne 0 ] || { echo "  FAIL: a reused foreign PID must not be exempted"; return 1; }
    assert_output_contains "$output" "session is open" "reused live PID keeps the hard refusal" || return 1
    assert_dir "$wt" "reused-PID refusal preserves the worktree" || return 1
}

test_merge_conflict_stops_and_preserves() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base file")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "task line" > "$wt/shared.txt"
    (cd "$wt" && git add shared.txt && git commit -q -m "task edit")
    echo "conflicting base line" > "$base_dir/shared.txt"
    (cd "$base_dir" && git add shared.txt && git commit -q -m "base edit")
    local output
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1 || true)
    assert_output_contains "$output" "conflict" "conflict reported" || return 1
    assert_dir "$wt" "worktree preserved on conflict" || return 1
    (cd "$base_dir" && git merge --abort 2>/dev/null || true)
}

test_merge_rejects_traversal_task_name() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    # A task argument with path separators would build an escaping worktree
    # path; --merge must reject it with the feature-name charset error before
    # touching the filesystem, matching the launch path's validation.
    local output status=0
    output=$("$CS_BIN" "myproj" --merge "e/../../x" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a task name with path separators must be rejected"; return 1; }
    assert_output_contains "$output" "alphanumeric" "rejects a traversal task name with the charset error" || return 1
}

# Git for Windows enables core.autocrlf by default. A CRLF-rewritten .gitignore
# carries a trailing \r on every pattern and matches nothing, so files cs means
# to ignore surface as untracked — which then blocks `cs --merge`.
test_session_repo_pins_autocrlf_off() {
    local cfg="$TEST_TMPDIR/gitconfig-autocrlf"
    printf '[core]\n\tautocrlf = true\n' > "$cfg"
    GIT_CONFIG_GLOBAL="$cfg" "$CS_BIN" acrlf <<< "" >/dev/null 2>&1
    local repo="$CS_SESSIONS_ROOT/acrlf"
    [ -d "$repo/.git" ] || { echo "  FAIL: session repo not created"; return 1; }
    # --local, not the effective value: a global autocrlf=false on the dev box
    # would otherwise satisfy this without cs having written anything.
    assert_eq "false" "$(git -C "$repo" config --local --get core.autocrlf 2>/dev/null)" \
        "a session repo must pin core.autocrlf off in its own config" || return 1
}

# cs records the protocol file in the worktree's info/exclude, at whatever path
# git reports for it. A worktree's git-path is absolute, and in drive-letter form
# under Git Bash; mis-reading that as relative sends the entry to a nonsense path,
# leaves CLAUDE.local.md untracked, and blocks `cs <base> --merge`.
test_worktree_excludes_protocol_file() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n' > "$base_dir/.gitignore"
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    [ -f "$wt/CLAUDE.local.md" ] || { echo "  FAIL: protocol file not written to the worktree"; return 1; }
    (cd "$wt" && git check-ignore -q CLAUDE.local.md) \
        || { echo "  FAIL: CLAUDE.local.md is not ignored inside the worktree"
             echo "  status: $( (cd "$wt" && git status --porcelain) | tr '\n' ' ')"; return 1; }
}

run_test test_worktree_name_rejected_without_base
run_test test_worktree_name_rejects_bad_task_half
run_test test_plain_names_still_work
run_test test_worktree_create_tracked_mode
run_test test_worktree_create_refuses_dirty_base
run_test test_worktree_create_reuses_existing_branch
run_test test_worktree_create_ignored_mode_bootstraps_cs
run_test test_worktree_of_worktree_refused
run_test test_worktree_create_succeeds_with_untracked_base
run_test test_worktree_reopen_preserves_project_claude_md
run_test test_worktree_launch_exports_base_identity
run_test test_merge_tracked_worktree_fuses_and_cleans_up
run_test test_merge_refuses_dirty_worktree
run_test test_merge_refuses_live_session
run_test test_merge_from_live_base_session_succeeds
run_test test_merge_from_live_worktree_session_requires_handoff
run_test test_merge_foreign_live_base_lock_still_refuses
run_test test_merge_reused_live_pid_is_not_treated_as_own_lock
run_test test_merge_conflict_stops_and_preserves
run_test test_merge_rejects_traversal_task_name

test_merge_ignored_mode_fuses_records() {
    local base_dir="$CS_SESSIONS_ROOT/proj"
    mkdir -p "$base_dir/.cs"/{memory,local}
    echo "base note" > "$base_dir/.cs/memory/note-base.md"
    printf -- '---\ndescription: seed\n---\n# Session narrative (tester)\n\n## Prior finding\n' \
        > "$base_dir/.cs/memory/narrative.tester.md"
    printf -- '---\ndescription: plain-seed\n---\n# Session narrative (plain)\n' \
        > "$base_dir/.cs/memory/narrative.plain.md"
    echo "# P" > "$base_dir/README.md"
    printf '.cs/\n.claude/settings.local.json\n' > "$base_dir/.gitignore"
    # autocrlf is on by default in Git for Windows and would rewrite the fixture's
    # line endings, so the record fusion compares LF content against CRLF checkouts.
    (cd "$base_dir" && git init -q && git config core.autocrlf false && git add -A && git commit -q -m init)
    cs_launch "proj@t1"
    local wt="$CS_SESSIONS_ROOT/proj@t1"
    # Task work: code (committed) + session records (untracked .cs)
    echo "done" > "$wt/result.txt"
    (cd "$wt" && git add result.txt && git commit -q -m "task")
    echo '{"event":"from-task"}' >> "$wt/.cs/timeline.jsonl"
    echo "task memory" > "$wt/.cs/memory/note-task.md"
    printf -- '---\nname: n\n---\n# Session narrative (tester)\n\n## Task finding\n\n---\n\n## After rule\n' \
        > "$wt/.cs/memory/narrative.tester.md"
    printf -- '---\nname: other-n\n---\n# Session narrative (other)\n\n## Other finding\n' \
        > "$wt/.cs/memory/narrative.other.md"
    printf -- '# Session narrative (plain)\n\n## Plain finding\n' \
        > "$wt/.cs/memory/narrative.plain.md"
    echo "task version" > "$wt/.cs/memory/note-base.md"
    local output merge_status
    output=$("$CS_BIN" "proj" --merge "t1" 2>&1)
    merge_status=$?
    assert_eq "0" "$merge_status" "merge exits 0" \
        || { echo "  merge output: $output"; return 1; }
    assert_output_contains "$output" "memory/note-base.md already exists in the base; skipped" \
        "memory collision warned" || return 1
    assert_eq "base note" "$(cat "$base_dir/.cs/memory/note-base.md")" "memory collision keeps base copy" || return 1
    assert_file_contains "$base_dir/.cs/timeline.jsonl" "from-task" "timeline appended" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-task.md" "memory file copied" || return 1
    assert_file_exists "$base_dir/.cs/memory/note-base.md" "base memory untouched" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "Task finding" "narrative body appended" || return 1
    assert_file_not_contains "$base_dir/.cs/memory/narrative.tester.md" "name: n" "frontmatter not duplicated" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "description: seed" "base frontmatter kept" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.tester.md" "After rule" \
        "body after horizontal rule survives" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "Plain finding" \
        "no-frontmatter body appended" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.plain.md" "description: plain-seed" \
        "plain base frontmatter kept" || return 1
    assert_file_exists "$base_dir/.cs/memory/narrative.other.md" "unseen narrative copied" || return 1
    assert_file_contains "$base_dir/.cs/memory/narrative.other.md" "name: other-n" "first copy keeps frontmatter" || return 1
    assert_not_exists "$wt" "worktree removed" || return 1
    assert_file_exists "$base_dir/result.txt" "code merged" || return 1
}

run_test test_merge_ignored_mode_fuses_records

test_rm_worktree_unregisters_and_prompts_branch() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    # Confirm removal, decline branch deletion
    printf 'y\nn\n' | "$CS_BIN" -rm "myproj@fix-auth" > /dev/null 2>&1
    assert_not_exists "$wt" "worktree dir removed" || return 1
    git -C "$base_dir" worktree list --porcelain | grep -q "myproj@fix-auth" \
        && { echo "  FAIL: worktree still registered"; return 1; }
    assert_eq "  cs/fix-auth" "$(git -C "$base_dir" branch --list cs/fix-auth)" \
        "branch kept when declined" || return 1
}

run_test test_rm_worktree_unregisters_and_prompts_branch

test_doctor_flags_dangling_and_merged_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@done-task"
    # Simulate a completed-but-unmerged-cleanup state: merge manually.
    # --no-ff so the base HEAD moves past the branch tip; a fast-forward
    # would leave tip == HEAD, indistinguishable from a fresh worktree.
    (cd "$CS_SESSIONS_ROOT/myproj@done-task" && echo x > f && git add f && git commit -q -m t)
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/done-task)
    # And a dangling dir that git does not know about
    mkdir -p "$CS_SESSIONS_ROOT/myproj@ghost/.cs/local"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_contains "$output" "ghost" "dangling @-dir flagged" || return 1
    assert_output_contains "$output" "myproj@done-task branch cs/done-task is fully merged" \
        "merged-but-present worktree flagged" || return 1
}

run_test test_doctor_flags_dangling_and_merged_worktrees

test_doctor_fresh_worktree_not_flagged_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fresh-task"
    local output
    output=$(cd "$base_dir" && CLAUDE_SESSION_DIR="$base_dir" CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_not_contains "$output" "fully merged" \
        "fresh worktree (tip == base HEAD) must not read as merged" || return 1
    assert_output_contains "$output" "Worktrees: myproj@fresh-task on cs/fresh-task" \
        "fresh worktree reported OK" || return 1
}

run_test test_doctor_fresh_worktree_not_flagged_merged

# Git for Windows prints drive-letter paths (C:/...) everywhere, while MSYS
# `pwd -P` yields /c/... form -- so a doctor check that compares one against the
# other can never match. A git shim that rewrites both path outputs to
# drive-letter form reproduces that divergence on any platform.
_make_drive_letter_git() {
    local bindir="$TEST_TMPDIR/dl-git"
    local real_git; real_git=$(command -v git)
    mkdir -p "$bindir"
    cat > "$bindir/git" <<GITFAKE
#!/usr/bin/env bash
set -o pipefail
case " \$* " in
    *" worktree list --porcelain "*|*" rev-parse --show-toplevel "*)
        "$real_git" "\$@" | sed -e 's|^worktree /|worktree C:/|' -e 's|^/|C:/|'
        exit
        ;;
esac
exec "$real_git" "\$@"
GITFAKE
    chmod +x "$bindir/git"
    echo "$bindir"
}

test_doctor_classifies_worktrees_when_git_prints_drive_letter_paths() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fresh-task"
    local bindir; bindir=$(_make_drive_letter_git)
    local output
    output=$(cd "$base_dir" && PATH="$bindir:$PATH" CLAUDE_SESSION_DIR="$base_dir" \
        CLAUDE_SESSION_META_DIR="$base_dir/.cs" "$CS_BIN" -doctor 2>&1 || true)
    assert_output_not_contains "$output" "not a registered worktree" \
        "a live worktree must not read as unregistered on git's path form" || return 1
    assert_output_contains "$output" "Worktrees: myproj@fresh-task on cs/fresh-task" \
        "a registered worktree still classifies when git prints drive-letter paths" || return 1
}

run_test test_doctor_classifies_worktrees_when_git_prints_drive_letter_paths

test_merge_refuses_untracked_worktree() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "committed" > "$wt/done.txt"
    (cd "$wt" && git add done.txt && git commit -q -m work)
    echo "precious" > "$wt/never-added.txt"   # untracked user work
    local output status=0
    output=$("$CS_BIN" "myproj" --merge "fix-auth" 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: merge must refuse"; return 1; }
    assert_output_contains "$output" "untracked" "refusal names the problem" || return 1
    assert_output_contains "$output" "never-added.txt" "refusal names the exact path" || return 1
    assert_dir "$wt" "worktree preserved" || return 1
    assert_eq "precious" "$(cat "$wt/never-added.txt")" "untracked work survives" || return 1
}

run_test test_merge_refuses_untracked_worktree

test_worktree_secrets_flag_targets_base_namespace() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"   # create the worktree first
    local output
    output=$("$CS_BIN" "myproj@fix-auth" -secrets list 2>&1)
    assert_output_contains "$output" "session: myproj" \
        "worktree -secrets flag must target the base namespace" || return 1
    assert_output_not_contains "$output" "session: myproj@fix-auth" \
        "must not target the nonexistent worktree namespace" || return 1
}

run_test test_worktree_secrets_flag_targets_base_namespace


test_worktree_create_dirty_base_consent_yes() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "consented creation should launch, got: $output" || return 1
    assert_dir "$CS_SESSIONS_ROOT/myproj@t1" "worktree created after consent" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/myproj@t1/.cs/local/state" "task_branch: cs/t1" \
        "worktree fully initialized" || return 1
}

test_worktree_create_dirty_base_consent_no() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    echo "wip" >> "$base_dir/CLAUDE.md"
    local output status=0
    output=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" "myproj@t1" 2>&1) || status=$?
    assert_eq "0" "$status" "declined consent cancels cleanly, got: $output" || return 1
    assert_output_contains "$output" "Cancelled" "cancel message shown" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/myproj@t1" "no worktree without consent" || return 1
}

run_test test_worktree_create_dirty_base_consent_yes
run_test test_worktree_create_dirty_base_consent_no
run_test test_session_repo_pins_autocrlf_off
run_test test_worktree_excludes_protocol_file

test_features_lists_only_verified_worktrees() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    # A directory that looks like a worktree but was never registered with git.
    mkdir -p "$CS_SESSIONS_ROOT/myproj@hand-made/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "fix-auth" "a registered worktree is listed" || return 1
    assert_output_not_contains "$output" "hand-made" "an unregistered lookalike must be excluded" || return 1
}

run_test test_features_lists_only_verified_worktrees

test_features_is_empty_for_a_base_with_no_worktrees() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_eq "" "$output" "a base with no features prints nothing" || return 1
}

run_test test_features_is_empty_for_a_base_with_no_worktrees

test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one() {
    # The verification compares whole lines. A one-sided anchor would verify
    # "wip" against the registered "wip-2", which is precisely the unregistered
    # directory this function exists to exclude. Prefix-colliding task names are
    # ordinary, so this is a realistic collision, not a contrived one.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    mkdir -p "$CS_SESSIONS_ROOT/myproj@wip/.cs/local"
    local output
    output=$("$CS_BIN" "myproj" -features --porcelain 2>&1)
    assert_output_contains "$output" "wip-2" "the registered worktree is listed" || return 1
    assert_output_not_contains "$output" $'^wip\t' "an unregistered prefix must not verify" || return 1
}

run_test test_features_excludes_a_lookalike_whose_name_prefixes_a_real_one

# Field positions in a -features --porcelain record.
_feat_field() {  # line field_number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

test_features_untracked_is_not_reported_as_dirty() {
    # _tree_is_dirty deliberately excludes untracked files: a worktree holding
    # only untracked files is NOT dirty, but is still refused, by a different
    # gate with a different message. A porcelain-non-empty test would conflate
    # them and the screen would disagree with the gate.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    echo "scratch" > "$CS_SESSIONS_ROOT/myproj@fix-auth/notes.txt"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 6)" "untracked files must not set wt_dirty" || return 1
    assert_eq "1" "$(_feat_field "$line" 7)" "the untracked file must be counted" || return 1
    assert_eq "untracked" "$(_feat_field "$line" 10)" "state must name the untracked gate" || return 1
}

run_test test_features_untracked_is_not_reported_as_dirty

test_features_fresh_worktree_is_not_already_merged() {
    # A fresh worktree's branch sits AT base HEAD, where merge-base
    # --is-ancestor is also true. Reporting that as already-merged is
    # destructive: cs reads is-ancestor as "already merged; cleaning up" and
    # removes the worktree and deletes the branch.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "0" "$(_feat_field "$line" 4)" "a branch AT base HEAD is not already merged" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a fresh clean worktree is ready" || return 1
}

run_test test_features_fresh_worktree_is_not_already_merged

test_features_reports_a_branch_strictly_behind_as_merged() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    (cd "$base_dir" && git merge -q --no-ff --no-edit cs/fix-auth)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "1" "$(_feat_field "$line" 4)" "a tip strictly behind base HEAD is merged" || return 1
    assert_eq "merged" "$(_feat_field "$line" 10)" "state must say merged" || return 1
}

run_test test_features_reports_a_branch_strictly_behind_as_merged

test_features_counts_commits_ahead() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo one > "$wt/a.txt"; (cd "$wt" && git add -A && git commit -q -m one)
    echo two > "$wt/b.txt"; (cd "$wt" && git add -A && git commit -q -m two)
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "2" "$(_feat_field "$line" 3)" "two commits ahead of base HEAD" || return 1
    assert_eq "cs/fix-auth" "$(_feat_field "$line" 2)" "branch comes from the state pin" || return 1
}

run_test test_features_counts_commits_ahead

test_features_reports_a_live_worktree_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "$$" > "$wt/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$wt/.cs/session.lock"
    assert_eq "worktree" "$(_feat_field "$line" 9)" "a live lock on the feature worktree is lock=worktree" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live worktree lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_worktree_lock_distinctly

test_features_reports_a_live_base_lock_distinctly() {
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    echo "$$" > "$base_dir/.cs/session.lock"   # this test process is alive
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    rm -f "$base_dir/.cs/session.lock"
    assert_eq "base" "$(_feat_field "$line" 9)" "a live lock on the base is lock=base" || return 1
    assert_eq "locked" "$(_feat_field "$line" 10)" "a live base lock sets state=locked" || return 1
}

run_test test_features_reports_a_live_base_lock_distinctly

test_features_ignores_a_dead_lock_pid() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    local dead_pid
    dead_pid=$(bash -c 'echo $$')
    if kill -0 "$dead_pid" 2>/dev/null; then
        echo "  SKIP: PID $dead_pid is unexpectedly alive"
        return 0
    fi
    echo "$dead_pid" > "$wt/.cs/session.lock"
    local line
    line=$("$CS_BIN" "myproj" -features --porcelain 2>/dev/null)
    assert_eq "none" "$(_feat_field "$line" 9)" "a dead pid must not be reported as a lock" || return 1
    assert_eq "ready" "$(_feat_field "$line" 10)" "a dead pid must not set state=locked" || return 1
}

run_test test_features_ignores_a_dead_lock_pid

test_features_human_table_names_the_state() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    local output
    output=$("$CS_BIN" "myproj" -features 2>&1)
    assert_output_contains "$output" "FEATURE" "the table carries a header" || return 1
    assert_output_contains "$output" "fix-auth" "the feature is listed" || return 1
    assert_output_contains "$output" "ready" "the state is named" || return 1
}

run_test test_features_human_table_names_the_state

test_finish_arms_the_ritual_without_merging() {
    # -finish opens the base with the ritual armed. It must not merge: the
    # branch is still unmerged and the worktree still exists afterwards.
    # The base session directory already exists (created by
    # create_test_session_with_git below), so this launch is a resume, not a
    # fresh session: it hits the "Continue previous conversation?" prompt, so
    # stdin needs an answer rather than an immediate EOF (< /dev/null exits
    # the launch at that prompt before the exec line is ever reached).
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    local wt="$CS_SESSIONS_ROOT/myproj@fix-auth"
    echo "fix" > "$wt/auth.txt"
    (cd "$wt" && git add -A && git commit -q -m "task work")
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "" 2>&1 || true)
    assert_output_contains "$output" "/merge fix-auth" "the launch prompt must arm the ritual" || return 1
    assert_dir "$wt" "the worktree must survive -finish" || return 1
    assert_file_not_exists "$base_dir/auth.txt" "-finish must not merge" || return 1
}

run_test test_finish_arms_the_ritual_without_merging

test_finish_survives_declining_the_resume() {
    # Answering n takes _exec_fresh_rebind, which builds its OWN prompt chain.
    # Missing it drops the merge intent silently on a routine answer.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    printf 'claude_session_id: 00000000-0000-4000-8000-000000000000\n' \
        > "$CS_SESSIONS_ROOT/myproj/.cs/local/state"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "n" 2>&1 || true)
    assert_output_contains "$output" "/merge fix-auth" "a declined resume must keep the merge kick" || return 1
}

run_test test_finish_survives_declining_the_resume

test_finish_rejects_an_unknown_feature() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "no-such-feature" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "no-such-feature" "the refusal must name the feature" || return 1
}

run_test test_finish_rejects_an_unknown_feature

test_finish_rejects_a_prefix_lookalike() {
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@wip-2"
    local output
    output=$("$CS_BIN" "myproj" -finish "wip" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "No feature worktree 'wip'" \
        "a prefix of a real feature must be refused" || return 1
}

run_test test_finish_rejects_a_prefix_lookalike

test_finish_rejects_a_traversal_feature_name() {
    create_test_session_with_git "myproj" > /dev/null
    local output
    output=$("$CS_BIN" "myproj" -finish "../escape" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "feature name" "a path separator must be rejected" || return 1
}

run_test test_finish_rejects_a_traversal_feature_name

test_finish_warns_when_it_displaces_a_spawn_kick() {
    # Both ride claude's single prompt slot. The merge kick wins because the
    # user took the action seconds ago — but the displacement must not be
    # silent, and the warning must not promise the queue runs after the merge:
    # the drain is the Stop hook, which fires at the first turn end.
    create_test_session_with_git "myproj" > /dev/null
    cs_launch "myproj@fix-auth"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'other-session\nfirst staged task\n' > "$CS_SESSIONS_ROOT/.spawn/myproj.seed"
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" < /dev/null 2>&1 || true)
    assert_output_contains "$output" "/merge fix-auth" "the merge kick takes the slot" || return 1
    assert_output_contains "$output" "walk-away queue is armed" "the displacement must be announced" || return 1
    assert_output_not_contains "$output" "after the merge" "must not promise sequencing it cannot enforce" || return 1
}

run_test test_finish_warns_when_it_displaces_a_spawn_kick

test_finish_yields_to_an_explicit_rotation_choice() {
    # r is the user explicitly choosing the rotation handoff at the prompt;
    # a merge armed moments earlier must not silently override that choice.
    local base_dir
    base_dir=$(create_test_session_with_git "myproj")
    cs_launch "myproj@fix-auth"
    mkdir -p "$base_dir/.cs/handoffs"
    cat > "$base_dir/.cs/handoffs/2026-07-16-test.md" << 'EOF'
---
parent: 00000000-0000-4000-8000-000000000000
created: 2026-07-16T10:00:00Z
purpose: test rotation
status: unconsumed
---

## 7. Next Step
Continue the test.
EOF
    local output
    output=$("$CS_BIN" "myproj" -finish "fix-auth" <<< "r" 2>&1 || true)
    assert_output_contains "$output" "Rotation handoff takes this launch; re-run: cs myproj -finish fix-auth" \
        "the displaced merge must be announced" || return 1
    assert_output_not_contains "$output" "/merge fix-auth" "the explicit r choice must not be overridden" || return 1
    assert_output_contains "$output" ".cs/handoffs/2026-07-16-test.md" "the handoff prompt must run instead" || return 1
}

run_test test_finish_yields_to_an_explicit_rotation_choice

report_results
