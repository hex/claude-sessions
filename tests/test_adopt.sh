#!/usr/bin/env bash
# ABOUTME: Tests for the cs -adopt command that converts existing projects to cs sessions
# ABOUTME: Validates symlink creation, .cs/ structure, CLAUDE.local.md protocol placement, and edge cases

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# Tests
# ============================================================================

test_adopt_creates_cs_structure() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.cs" ".cs/ directory should exist" || return 1
    assert_dir "$project_dir/.cs/local" ".cs/local/ should exist" || return 1
    assert_exists "$project_dir/.cs/local/session.log" "session.log should exist" || return 1
    assert_exists "$project_dir/.cs/README.md" ".cs/README.md should exist" || return 1
    local nf
    nf=$(ls "$project_dir"/.cs/memory/narrative.*.md 2>/dev/null | head -1)
    assert_exists "$nf" "a per-actor narrative file should exist" || return 1
    assert_not_exists "$project_dir/.cs/sync.conf" "sync.conf must not be created (sync subsystem removed)" || return 1
}

test_adopt_creates_symlink() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_symlink "$CS_SESSIONS_ROOT/my-session" "Session symlink should exist" || return 1

    local target
    target="$(readlink -f "$CS_SESSIONS_ROOT/my-session")"
    local real_project
    real_project="$(cd "$project_dir" && pwd -P)"
    assert_eq "$real_project" "$target" "Symlink should point to project directory" || return 1
}

test_adopt_creates_claude_local_md_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_exists "$project_dir/CLAUDE.local.md" "CLAUDE.local.md should be created" || return 1
    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_not_exists "$project_dir/CLAUDE.md" "CLAUDE.md should not be created when none existed" || return 1
}

test_adopt_leaves_existing_claude_md_untouched() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    cat > "$project_dir/CLAUDE.md" << 'EOF'
# My Project Rules

- Use TypeScript for all files
- Follow strict ESLint config
EOF

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_file_contains "$project_dir/CLAUDE.local.md" "Session Documentation Protocol" \
        "CLAUDE.local.md should contain session protocol" || return 1
    assert_file_contains "$project_dir/CLAUDE.md" "Use TypeScript for all files" \
        "CLAUDE.md should preserve original content" || return 1
    assert_file_not_contains "$project_dir/CLAUDE.md" "Session Documentation Protocol" \
        "CLAUDE.md must not gain the protocol" || return 1
}

test_adopt_refuses_a_directory_already_linked() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt first-name >/dev/null 2>&1)

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt second-name 2>&1); then
        echo "  FAIL: Should have failed for a directory already linked under another name"
        return 1
    fi
    if ! grep -q "first-name" <<< "$output"; then
        echo "  FAIL: Error message should name the existing session 'first-name': $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/second-name" "no symlink should be created for the refused name" || return 1
}

test_adopt_relinks_orphaned_records_interactively() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    printf '\nmarker: orphaned-records-survive\n' >> "$narrative"
    local before
    before=$(cat "$narrative")

    local output rc=0
    output=$(cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: re-adopt should exit 0: $output"; return 1; }

    assert_symlink "$CS_SESSIONS_ROOT/new-name" "new symlink should exist" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/old-name" "old symlink name should stay gone" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file should be byte-identical after re-adopt" || return 1
}

test_adopt_orphaned_records_noninteractive_hints() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local narrative
    narrative=$(ls "$project_dir"/.cs/memory/narrative.*.md | head -1)
    local before
    before=$(cat "$narrative")

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt new-name </dev/null 2>&1); then
        echo "  FAIL: non-interactive re-adopt should fail without a terminal"
        return 1
    fi
    if ! grep -qi "re-run interactively" <<< "$output"; then
        echo "  FAIL: error should hint at re-running interactively: $output"
        return 1
    fi
    assert_dir "$project_dir/.cs" ".cs/ should be untouched" || return 1
    local after
    after=$(cat "$narrative")
    assert_eq "$before" "$after" "narrative file must not change on a refused re-adopt" || return 1
}

test_adopt_orphaned_records_decline_cancels() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"

    local output rc=0
    output=$(cd "$project_dir" && printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: declining re-adopt should exit 0: $output"; return 1; }
    if ! grep -qi "cancelled" <<< "$output"; then
        echo "  FAIL: output should say Cancelled: $output"
        return 1
    fi
    assert_not_exists "$CS_SESSIONS_ROOT/new-name" "no symlink should be created on decline" || return 1
}

test_adopt_fails_if_session_name_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    mkdir -p "$CS_SESSIONS_ROOT/my-session"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt my-session 2>&1); then
        echo "  FAIL: Should have failed for existing session name"
        return 1
    fi

    if ! grep -qi "already exists" <<< "$output"; then
        echo "  FAIL: Error message should mention 'already exists': $output"
        return 1
    fi
}

test_adopt_validates_session_name() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    local output
    if output=$(cd "$project_dir" && "$CS_BIN" -adopt "bad name!" 2>&1); then
        echo "  FAIL: Should have failed for invalid session name"
        return 1
    fi
}

test_list_shows_adopted_sessions() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local output
    output=$("$CS_BIN" -list 2>&1)

    if ! grep -q "my-session" <<< "$output"; then
        echo "  FAIL: cs -list should show adopted session 'my-session'"
        echo "  Output: $output"
        return 1
    fi
}

test_remove_adopted_session_removes_symlink_only() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    echo "y" | CS_ASSUME_TTY=1 "$CS_BIN" -remove my-session 2>&1

    assert_not_exists "$CS_SESSIONS_ROOT/my-session" "Symlink should be removed" || return 1
    assert_dir "$project_dir" "Original project should still exist" || return 1
    assert_dir "$project_dir/.cs" ".cs/ should still exist in original project" || return 1
}

test_adopt_preserves_existing_git_repo() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local log_output
    log_output=$(cd "$project_dir" && git log --oneline --format="%s")
    if ! grep -q "initial" <<< "$log_output"; then
        echo "  FAIL: Original git commit 'initial' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

test_adopt_inits_git_when_none_exists() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    assert_dir "$project_dir/.git" "Git repo should be initialized" || return 1
}

test_adopt_into_git_repo_without_claude_md_stages_bookkeeping() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)

    (cd "$project_dir" && "$CS_BIN" -adopt my-session)

    local tracked
    tracked=$(git -C "$project_dir" ls-files .cs/README.md)
    if [[ -z "$tracked" ]]; then
        echo "  FAIL: .cs/README.md should be tracked by git after adopting a repo with no CLAUDE.md"
        return 1
    fi

    local log_output
    log_output=$(git -C "$project_dir" log --oneline --format="%s")
    if ! grep -q "^Adopt as cs session: my-session$" <<< "$log_output"; then
        echo "  FAIL: Adopt commit 'Adopt as cs session: my-session' not found in history"
        echo "  History: $log_output"
        return 1
    fi
}

# Adoption commits inside the user's own project repo. A bare `git commit`
# there commits the whole index, so work they had staged is swept into a commit
# titled "Adopt as cs session" — the same defect the narrative rotation commit
# carried, at the other site where cs commits into a checkout it does not own.
test_adopt_commits_only_its_own_bookkeeping() {
    local project_dir="$TEST_TMPDIR/staged-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A && git commit --allow-empty -m "initial" -q)
    printf 'work in progress\n' > "$project_dir/user-file.txt"
    git -C "$project_dir" add -- user-file.txt

    (cd "$project_dir" && "$CS_BIN" -adopt staged-session)

    local subject swept staged
    # HEAD must BE the adopt commit first: the fixture's initial commit predates
    # user-file.txt, so "HEAD does not contain it" holds even when no adopt
    # commit was made at all.
    subject=$(git -C "$project_dir" log -1 --format=%s)
    assert_eq "Adopt as cs session: staged-session" "$subject" "HEAD must be the adopt commit" || return 1
    swept=$(git -C "$project_dir" show --name-only --format= HEAD | grep -c 'user-file.txt' || true)
    assert_eq "0" "$swept" "the user's staged file must not ride along in the adopt commit" || return 1
    staged=$(git -C "$project_dir" diff --cached --name-only -- user-file.txt)
    assert_eq "user-file.txt" "$staged" "and it must still be staged afterwards" || return 1
}

# ============================================================================
# README.md frontmatter
# ============================================================================

test_readme_has_yaml_frontmatter() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    local first_line
    first_line=$(head -1 "$readme")
    assert_eq "---" "$first_line" "README should start with YAML frontmatter delimiter" || return 1
}

test_readme_frontmatter_has_status() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "status:" "Frontmatter should have status field" || return 1
}

test_readme_frontmatter_has_created_date() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "created: 20" "Frontmatter should have created date" || return 1
}

test_readme_frontmatter_has_tags() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" "tags:" "Frontmatter should have tags field" || return 1
}

test_readme_frontmatter_has_aliases() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    assert_file_contains "$readme" 'aliases:' "Frontmatter should have aliases field" || return 1
    assert_file_contains "$readme" 'test-session' "Aliases should contain session name" || return 1
}

test_readme_objective_still_extractable() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local readme="$CS_SESSIONS_ROOT/test-session/.cs/README.md"
    # The sed pattern used by session-start.sh should still work
    local obj
    obj=$(sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$readme" | head -1)
    assert_eq "[Describe what you're trying to accomplish in this session]" "$obj" \
        "Objective should still be extractable with existing sed pattern" || return 1
}

test_adopt_sets_memory_merge_driver() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name A)
    (cd "$project_dir" && "$CS_BIN" -adopt my-session >/dev/null 2>&1)

    assert_file_contains "$project_dir/.gitattributes" "MEMORY.md merge=ours" \
        ".gitattributes should mark MEMORY.md merge=ours" || return 1
    local drv
    drv=$(git -C "$project_dir" config merge.ours.driver 2>/dev/null || echo "")
    assert_eq "true" "$drv" "merge.ours.driver should be configured" || return 1
}

test_adopt_gitignores_cs_local() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt my-session)
    assert_file_contains "$project_dir/.gitignore" ".cs/local/" \
        ".gitignore should ignore .cs/local/" || return 1
}

# An encrypted session mounts its volume at .cs/vault-mnt by convention; git
# must ignore it both in the .gitignore cs writes and in a project's own
# .gitignore that adopt appends to.
test_adopt_gitignores_the_vault_mount() {
    local fresh="$TEST_TMPDIR/fresh" owned="$TEST_TMPDIR/owned"
    mkdir -p "$fresh" "$owned"
    (cd "$fresh" && git init -q && "$CS_BIN" -adopt fresh-session >/dev/null 2>&1)
    (cd "$owned" && git init -q && printf 'node_modules/\n' > .gitignore \
        && "$CS_BIN" -adopt owned-session >/dev/null 2>&1)
    git -C "$fresh" check-ignore -q .cs/vault-mnt/memory/narrative.md \
        || { echo "  FAIL: cs's own .gitignore must ignore .cs/vault-mnt/"; return 1; }
    git -C "$owned" check-ignore -q .cs/vault-mnt/memory/narrative.md \
        || { echo "  FAIL: adopt must append .cs/vault-mnt/ to a project .gitignore"; return 1; }
    assert_file_contains "$owned/.gitignore" "node_modules/" "the project's own entry stays" || return 1
}

# ============================================================================
# First launch after adopt
# ============================================================================

UUID_PRIOR="33333333-3333-4333-8333-333333333333"

# A claude stub that records each launch's argv, one line per launch, and fails
# a --resume at once, as claude does for an id that names no conversation.
_adopt_claude_stub() {
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_TMPDIR/claude-args"
case "\$*" in *--resume*) exit 1 ;; esac
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

_adopt_state_id() {  # project_dir
    awk '/^claude_session_id:/ { print $2; exit }' "$1/.cs/local/state" 2>/dev/null
}

# An adopted directory already exists, so its first open is a reopen. It used to
# ask "Continue previous conversation?" for a conversation that never existed;
# the default answer's --resume then failed and a fallback started fresh.
test_first_launch_after_adopt_starts_fresh_without_asking() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "" 2>&1) || true

    if grep -q "Continue previous conversation" <<< "$output"; then
        echo "  FAIL: the first launch must not offer to resume: $output"; return 1
    fi
    if grep -q "No previous conversation found" <<< "$output"; then
        echo "  FAIL: the first launch must not go through the resume-failed fallback: $output"; return 1
    fi
    assert_output_contains "$output" "(+ new)" "the card calls the first launch new" || return 1

    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_eq "1" "$(printf '%s\n' "$launches" | grep -c .)" "claude launches exactly once" || return 1
    recorded=$(_adopt_state_id "$project_dir")
    [ -n "$recorded" ] || { echo "  FAIL: the launch must record the conversation it starts"; return 1; }
    assert_output_contains "$launches" "--session-id $recorded" "claude starts the recorded conversation" || return 1
    assert_output_contains "$launches" "--name probe" "the conversation is named after the session" || return 1
    if grep -qE -- '--resume|--continue' <<< "$launches"; then
        echo "  FAIL: nothing to resume, so no --resume or --continue: $launches"; return 1
    fi
    if grep -q '"event":"rotated"' "$project_dir/.cs/timeline.jsonl" 2>/dev/null; then
        echo "  FAIL: the first conversation rotates from nothing"; return 1
    fi
}

# A project Claude Code already ran in has a conversation to resume: the first
# open binds the newest one and asks, as before.
test_first_launch_after_adopt_offers_the_projects_newest_conversation() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(cd "$project_dir" && pwd -P | tr '/.' '--')"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$UUID_PRIOR" > "$proj/$UUID_PRIOR.jsonl"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "an existing conversation is offered" || return 1
    assert_output_contains "$(head -1 "$TEST_TMPDIR/claude-args")" "--resume $UUID_PRIOR" \
        "the answer resumes the project's conversation" || return 1
}

# The conversation the first launch recorded is the one the second resumes.
test_second_launch_after_adopt_asks_and_resumes() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt probe >/dev/null 2>&1)
    _adopt_claude_stub
    "$CS_BIN" probe <<< "" >/dev/null 2>&1 || true
    local first
    first=$(_adopt_state_id "$project_dir")
    # Claude writes the transcript once the conversation talks; without it
    # migrate would treat the id as an orphan.
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(cd "$project_dir" && pwd -P | tr '/.' '--')"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$first" > "$proj/$first.jsonl"
    : > "$TEST_TMPDIR/claude-args"

    local output
    output=$("$CS_BIN" probe <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "a bound session still asks" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args")" "--resume $first" \
        "the answer resumes the conversation the first launch recorded" || return 1
}

# Re-adopting orphaned records keeps the conversation they name; it used to be
# replaced with a fresh id, losing the binding (the transcript stayed on disk).
test_readopt_keeps_the_prior_conversation_binding() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    printf 'claude_session_id: %s\n' "$UUID_PRIOR" >> "$project_dir/.cs/local/state"
    rm "$CS_SESSIONS_ROOT/old-name"

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    assert_eq "$UUID_PRIOR" "$(_adopt_state_id "$project_dir")" \
        "re-adopt keeps the recorded conversation" || return 1

    _adopt_claude_stub
    local output
    output=$("$CS_BIN" new-name <<< "y" 2>&1) || true
    assert_output_contains "$output" "Continue previous conversation?" "the kept binding still asks" || return 1
    assert_output_contains "$(head -1 "$TEST_TMPDIR/claude-args")" "--resume $UUID_PRIOR" \
        "the answer resumes the kept conversation" || return 1
}

# Records whose machine-local state did not travel (a clone of a project that
# tracks .cs/) name no conversation, so they open the way a first adoption does.
test_readopt_without_local_state_starts_fresh_without_asking() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    rm "$CS_SESSIONS_ROOT/old-name"
    rm -f "$project_dir/.cs/local/state"

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    _adopt_claude_stub
    local output
    output=$("$CS_BIN" new-name <<< "" 2>&1) || true
    if grep -q "Continue previous conversation" <<< "$output"; then
        echo "  FAIL: records with no binding must not offer to resume: $output"; return 1
    fi
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args")" "--session-id $(_adopt_state_id "$project_dir")" \
        "claude starts the recorded conversation" || return 1
}

# A project that commits .cs/ brings its README frontmatter along. Adopt leaves
# the conversation slot empty, so the first open's migration imported the
# README's claude_session_id and the resume prompt passed it to claude unquoted:
# whoever wrote the project chose words on claude's command line.
test_adopt_ignores_a_committed_readme_id_that_is_not_a_uuid() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir/.cs"
    printf -- '---\nstatus: active\nclaude_session_id: --dangerously-skip-permissions --model x\n---\n# Session\n' \
        > "$project_dir/.cs/README.md"
    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt probe >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    _adopt_claude_stub

    local output
    output=$("$CS_BIN" probe <<< "" 2>&1) || true

    if grep -q "Continue previous conversation" <<< "$output"; then
        echo "  FAIL: an id that is not a UUID must not be offered for resume: $output"; return 1
    fi
    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_eq "1" "$(printf '%s\n' "$launches" | grep -c .)" "claude launches exactly once" || return 1
    if grep -q -- '--dangerously-skip-permissions' <<< "$launches"; then
        echo "  FAIL: the README's words reached claude's argv: $launches"; return 1
    fi
    recorded=$(_adopt_state_id "$project_dir")
    [[ "$recorded" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { echo "  FAIL: the open must record a real conversation id: '$recorded'"; return 1; }
    assert_output_contains "$launches" "--session-id $recorded" "claude starts the recorded conversation" || return 1
}

# Re-adopt puts back the conversation the records name, and only a conversation
# id: words in the slot name nothing to resume.
test_readopt_drops_a_prior_binding_that_is_not_a_uuid() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt old-name >/dev/null 2>&1)
    printf 'claude_session_id: --dangerously-skip-permissions\n' >> "$project_dir/.cs/local/state"
    rm "$CS_SESSIONS_ROOT/old-name"

    (cd "$project_dir" && printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -adopt new-name >/dev/null 2>&1) \
        || { echo "  FAIL: re-adopt should succeed"; return 1; }
    assert_eq "" "$(_adopt_state_id "$project_dir")" \
        "re-adopt keeps no id when the prior one is not a UUID" || return 1
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs -adopt tests"
echo "==============="
echo ""

run_test test_adopt_gitignores_cs_local
run_test test_adopt_gitignores_the_vault_mount
run_test test_adopt_sets_memory_merge_driver

run_test test_adopt_creates_cs_structure
run_test test_adopt_creates_symlink
run_test test_adopt_creates_claude_local_md_when_none_exists
run_test test_adopt_leaves_existing_claude_md_untouched
run_test test_adopt_refuses_a_directory_already_linked
run_test test_adopt_relinks_orphaned_records_interactively
run_test test_adopt_orphaned_records_noninteractive_hints
run_test test_adopt_orphaned_records_decline_cancels
run_test test_adopt_fails_if_session_name_exists
run_test test_adopt_validates_session_name
run_test test_list_shows_adopted_sessions
run_test test_remove_adopted_session_removes_symlink_only
run_test test_adopt_preserves_existing_git_repo
run_test test_adopt_inits_git_when_none_exists
run_test test_adopt_into_git_repo_without_claude_md_stages_bookkeeping
run_test test_adopt_commits_only_its_own_bookkeeping

# First launch after adopt
run_test test_first_launch_after_adopt_starts_fresh_without_asking
run_test test_first_launch_after_adopt_offers_the_projects_newest_conversation
run_test test_second_launch_after_adopt_asks_and_resumes
run_test test_readopt_keeps_the_prior_conversation_binding
run_test test_readopt_without_local_state_starts_fresh_without_asking
run_test test_adopt_ignores_a_committed_readme_id_that_is_not_a_uuid
run_test test_readopt_drops_a_prior_binding_that_is_not_a_uuid

# README frontmatter
run_test test_readme_has_yaml_frontmatter
run_test test_readme_frontmatter_has_status
run_test test_readme_frontmatter_has_created_date
run_test test_readme_frontmatter_has_tags
run_test test_readme_frontmatter_has_aliases
run_test test_readme_objective_still_extractable

report_results
