#!/usr/bin/env bash
# ABOUTME: Tests for `cs -adopt --worktrees`, which registers Claude Code's own .claude/worktrees/* as sessions.
# ABOUTME: Covers naming, conversation binding, the clean PR branch, idempotent re-runs, pruning and --dry-run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
}

UUID_A="aaaa1111-2222-4333-8444-555566667777"
UUID_B="bbbb1111-2222-4333-8444-555566667777"

# A repo with a tracked CLAUDE.md and one Claude Code worktree per name under
# .claude/worktrees/, the layout `claude --worktree` leaves behind.
_make_repo() {  # repo_dir, worktree...
    local repo="$1"; shift
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "john.doe@example.com"
    git -C "$repo" config user.name "John Doe"
    git -C "$repo" config core.autocrlf false
    printf '# Project rules\n' > "$repo/CLAUDE.md"
    git -C "$repo" add CLAUDE.md
    git -C "$repo" commit -q -m "init"
    mkdir -p "$repo/.claude/worktrees"
    local wt
    for wt in "$@"; do
        git -C "$repo" worktree add -q -b "$wt" ".claude/worktrees/$wt" >/dev/null 2>&1
    done
}

# Claude's transcript dir for a worktree, as the lib encodes it.
_wt_project_dir() {  # wt_dir
    printf '%s' "$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$1")"
}

_seed_conversation() {  # wt_dir, uuid, first_prompt
    local proj
    proj=$(_wt_project_dir "$1")
    mkdir -p "$proj"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$3" > "$proj/$2.jsonl"
}

# The transcript Claude Code leaves for a worktree session once it has
# exited: moved into the PARENT repo's project dir, first line a non-user
# record, every user line stamped with the worktree as cwd, plus the
# `worktree-state` record naming the worktree (2.1.289, measured on a real
# `claude --worktree` run).
_seed_relocated_conversation() {  # repo_dir, wt_dir, uuid, first_prompt
    local proj wt_real
    proj=$(_wt_project_dir "$1")
    # Paths go through the JSON string escaping Claude Code's writer applies.
    local wt_real repo_real
    wt_real=$(cd "$2" && pwd -P | sed 's/\\/\\\\/g; s/"/\\"/g')
    repo_real=$(cd "$1" && pwd -P | sed 's/\\/\\\\/g; s/"/\\"/g')
    mkdir -p "$proj"
    {
        printf '{"type":"last-prompt","leafUuid":"00000000-0000-4000-8000-000000000000","sessionId":"%s"}\n' "$3"
        printf '{"type":"worktree-state","worktreeSession":{"originalCwd":"%s","worktreePath":"%s","worktreeName":"%s","sessionId":"%s"},"sessionId":"%s"}\n' \
            "$repo_real" "$wt_real" "$(basename "$2")" "$3" "$3"
        printf '{"type":"user","cwd":"%s","sessionId":"%s","entrypoint":"cli","message":{"role":"user","content":"%s"}}\n' "$wt_real" "$3" "$4"
        printf '{"type":"relocated","sessionId":"%s","relocatedCwd":"%s"}\n' "$3" "$repo_real"
    } > "$proj/$3.jsonl"
}

# A conversation that began on the parent repo and stepped into a worktree with
# the EnterWorktree tool: the file is the parent's own, its first prompt is
# stamped with the parent as cwd, and the `worktree-state` record it gained
# names the worktree all the same.
_seed_entered_conversation() {  # repo_dir, wt_dir, uuid, first_prompt
    local proj wt_real repo_real
    proj=$(_wt_project_dir "$1")
    wt_real=$(cd "$2" && pwd -P | sed 's/\\/\\\\/g; s/"/\\"/g')
    repo_real=$(cd "$1" && pwd -P | sed 's/\\/\\\\/g; s/"/\\"/g')
    mkdir -p "$proj"
    {
        printf '{"type":"user","cwd":"%s","sessionId":"%s","entrypoint":"cli","message":{"role":"user","content":"%s"}}\n' "$repo_real" "$3" "$4"
        printf '{"type":"worktree-state","worktreeSession":{"originalCwd":"%s","worktreePath":"%s","worktreeName":"%s","sessionId":"%s","enteredExisting":true},"sessionId":"%s"}\n' \
            "$repo_real" "$wt_real" "$(basename "$2")" "$3" "$3"
        printf '{"type":"user","cwd":"%s","sessionId":"%s","entrypoint":"cli","message":{"role":"user","content":"carry on inside the worktree"}}\n' "$wt_real" "$3"
    } > "$proj/$3.jsonl"
}

_readme_objective() {  # session_dir
    sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$1/.cs/README.md" | head -1
}

test_refuses_outside_a_git_repo() {
    local plain="$TEST_TMPDIR/plain"
    mkdir -p "$plain"
    local output rc=0
    output=$(cd "$plain" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_eq "1" "$rc" "adopt --worktrees outside a repo exits 1" || return 1
    assert_output_contains "$output" "not inside a git repository" "the refusal says why" || return 1
}

test_refuses_a_repo_without_claude_worktrees() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo"
    rmdir "$repo/.claude/worktrees"
    local output rc=0
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_eq "1" "$rc" "a repo with no .claude/worktrees exits 1" || return 1
    assert_output_contains "$output" "$repo/.claude/worktrees" "the refusal names the directory it looked for" || return 1
}

test_adopts_a_worktree_with_a_conversation() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" brave-jang-0f6265
    local wt="$repo/.claude/worktrees/brave-jang-0f6265"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    local claude_md_before
    claude_md_before=$(cat "$wt/CLAUDE.md")

    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) \
        || { echo "  FAIL: adopt --worktrees should succeed"; return 1; }

    local link="$CS_SESSIONS_ROOT/repo.brave-jang-0f6265"
    [ -L "$link" ] || { echo "  FAIL: no session link at $link"; return 1; }
    assert_eq "$(cd "$wt" && pwd -P)" "$(cd "$link" && pwd -P)" "the link resolves to the worktree" || return 1
    assert_dir "$wt/.cs/local" "the worktree carries session records" || return 1
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state binds the worktree's conversation" || return 1
    assert_eq "repo.brave-jang-0f6265" "$(awk '/^session_name:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state records the session name the hooks resolve" || return 1
    if grep -q '^cs_base:' "$wt/.cs/local/state"; then
        echo "  FAIL: an adopted worktree is a peer, not a task of a base: cs_base must be absent"
        return 1
    fi
    assert_eq "Rewrite the electron UI shell for the desktop app" "$(_readme_objective "$wt")" \
        "the Objective is the conversation's first prompt" || return 1
    assert_eq "$claude_md_before" "$(cat "$wt/CLAUDE.md")" "the tracked CLAUDE.md is untouched" || return 1
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the worktree's PR branch stays clean" || return 1
}

# Claude Code moves a worktree session's transcript into the parent repo's
# project dir when the session exits, so a closed worktree has nothing under
# its own project dir. The parent dir also holds the parent's own
# conversations; the worktree's is the one whose worktree-state names it.
test_adopts_a_worktree_whose_transcript_moved_to_the_parent() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" moved-wt
    local wt="$repo/.claude/worktrees/moved-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    sleep 1
    _seed_conversation "$repo" "$UUID_B" "The parent repo's own newer conversation"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: adopt --worktrees should succeed: $output"; return 1; }

    [ -L "$CS_SESSIONS_ROOT/repo.moved-wt" ] || { echo "  FAIL: no session link; output: $output"; return 1; }
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state binds the worktree's relocated conversation, not the parent's newer one" || return 1
    assert_eq "Port the sync engine to the worktree branch" "$(_readme_objective "$wt")" \
        "the Objective is read from the relocated transcript" || return 1
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the worktree's PR branch stays clean" || return 1
}

# A `"` in the repo's path is `\"` in the transcript's JSON; the match has to
# compare like with like or such a repo's worktrees are never adopted. The
# quote sits in a parent folder: the repo's own name becomes the session name.
test_adopts_a_relocated_conversation_when_the_repo_path_needs_json_escaping() {
    local repo="$TEST_TMPDIR/q\"uoted/repo"
    _make_repo "$repo" quoted-wt
    local wt="$repo/.claude/worktrees/quoted-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Quote the path and still find the conversation"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: adopt --worktrees should succeed: $output"; return 1; }
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state" 2>/dev/null)" \
        "the relocated conversation is found through the JSON-escaped path; output: $output" || return 1
}

test_skips_a_worktree_without_a_conversation() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" quiet-wt
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: should succeed with nothing to adopt"; return 1; }
    assert_not_exists "$repo/.claude/worktrees/quiet-wt/.cs" "no records for a worktree nobody talked in" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.quiet-wt" ] && { echo "  FAIL: no session link for a skipped worktree"; return 1; }
    assert_output_contains "$output" "skip quiet-wt: no conversation" "the skip names the worktree and the reason" || return 1
}

test_binds_the_newest_of_two_conversations() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" busy-wt
    local wt="$repo/.claude/worktrees/busy-wt"
    _seed_conversation "$wt" "$UUID_A" "The older conversation about the shell"
    sleep 1
    _seed_conversation "$wt" "$UUID_B" "The newer conversation about the menu"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "$UUID_B" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the newest transcript is the one a resume would continue" || return 1
    assert_eq "The newer conversation about the menu" "$(_readme_objective "$wt")" \
        "the Objective comes from the bound conversation" || return 1
}

test_rerun_adopts_nothing_twice_and_keeps_the_exclude_file() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-one
    local wt="$repo/.claude/worktrees/wt-one"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    local exclude="$repo/.git/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    printf 'my-own-rule.tmp\n' > "$exclude"

    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: first run should succeed"; return 1; }
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: re-run should succeed"; return 1; }
    assert_output_contains "$output" "skip wt-one: already carries .cs/" "the re-run reports the skip" || return 1
    assert_eq "1" "$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name 'repo.wt-one' | wc -l | tr -d ' ')" "one link, not two" || return 1
    assert_eq "my-own-rule.tmp
.cs/
.claude/settings.local.json
CLAUDE.local.md" "$(cat "$exclude")" "the user's rule stays and cs's three lines appear once" || return 1
}

test_dry_run_writes_nothing() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-one
    local wt="$repo/.claude/worktrees/wt-one"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    # git init seeds info/exclude from its template; the dry run must leave it as found.
    local exclude_before
    exclude_before=$(cat "$repo/.git/info/exclude" 2>/dev/null || echo "<absent>")
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees --dry-run 2>&1) || { echo "  FAIL: dry run should succeed"; return 1; }
    assert_output_contains "$output" "would adopt wt-one as 'repo.wt-one'" "the dry run names what it would do" || return 1
    assert_not_exists "$wt/.cs" "no records written" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.wt-one" ] && { echo "  FAIL: no link written on a dry run"; return 1; }
    assert_eq "$exclude_before" "$(cat "$repo/.git/info/exclude" 2>/dev/null || echo "<absent>")" "the exclude file is as git left it" || return 1
}

test_rerun_prunes_a_link_whose_worktree_is_gone() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-gone
    local wt="$repo/.claude/worktrees/wt-gone"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: first run should succeed"; return 1; }
    # Claude Code removes the worktree once its branch lands.
    git -C "$repo" worktree remove --force .claude/worktrees/wt-gone
    [ -L "$CS_SESSIONS_ROOT/repo.wt-gone" ] || { echo "  FAIL: fixture: the link should dangle now"; return 1; }
    # A hand-made link that merely resembles ours must survive.
    ln -s "$TEST_TMPDIR/elsewhere" "$CS_SESSIONS_ROOT/repo.hand-made"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: re-run should succeed"; return 1; }
    assert_output_contains "$output" "Pruned repo.wt-gone" "the prune is reported" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.wt-gone" ] && { echo "  FAIL: the dangling link should be gone"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/repo.hand-made" ] || { echo "  FAIL: a link not pointing into .claude/worktrees is not ours to prune"; return 1; }
}

test_same_worktree_name_under_two_repos_opens_the_right_one() {
    local repo_a="$TEST_TMPDIR/alpha" repo_b="$TEST_TMPDIR/beta"
    _make_repo "$repo_a" agent-a018e313
    _make_repo "$repo_b" agent-a018e313
    _seed_conversation "$repo_a/.claude/worktrees/agent-a018e313" "$UUID_A" "Alpha work on the shell"
    _seed_conversation "$repo_b/.claude/worktrees/agent-a018e313" "$UUID_B" "Beta work on the menu"
    (cd "$repo_a" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: alpha adopt should succeed"; return 1; }
    (cd "$repo_b" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: beta adopt should succeed"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/alpha.agent-a018e313" ] && [ -L "$CS_SESSIONS_ROOT/beta.agent-a018e313" ] \
        || { echo "  FAIL: both sessions should exist"; return 1; }

    # The stub records claude's argv; a bound session asks to resume and `y` resumes it.
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
printf '<%s>' "\$@" >> "$TEST_TMPDIR/claude-args"; echo >> "$TEST_TMPDIR/claude-args"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    local output
    output=$("$CS_BIN" beta.agent-a018e313 <<< "y" 2>&1) || true
    assert_output_not_contains "$output" "Base session not found" "a dotted name never enters the base@task path" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)" "<--resume><$UUID_B>" \
        "opening beta's worktree resumes beta's conversation" || return 1
    assert_eq "" "$(git -C "$repo_b/.claude/worktrees/agent-a018e313" status --porcelain)" \
        "the open's own files (settings.local.json, CLAUDE.local.md) stay out of git status" || return 1
}

# A claude stub that records its argv and the command line of its parent: cs
# when the resume runs claude as its child, the caller when cs execs claude.
_launch_recording_stub() {
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
{ printf 'args=%s\n' "\$*"; printf 'parent=%s\n' "\$(ps -o args= -p \$PPID)"; } > "$TEST_TMPDIR/claude-launch"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

# A closed `claude --worktree` conversation sits in the parent repo's project
# dir, and `claude --resume <id>` from inside the worktree still finds it. The
# resume is sure to land, so claude runs in place of cs, as it does for a
# transcript in the worktree's own project dir.
test_resume_of_a_relocated_conversation_runs_claude_in_place_of_cs() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" moved-wt
    _seed_relocated_conversation "$repo" "$repo/.claude/worktrees/moved-wt" "$UUID_A" "Port the sync engine to the worktree branch"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    _launch_recording_stub
    (unset CLAUDE_CONFIG_DIR; "$CS_BIN" repo.moved-wt <<< "y" >/dev/null 2>&1) || true
    assert_output_contains "$(sed -n 's/^args=//p' "$TEST_TMPDIR/claude-launch")" "--resume $UUID_A" \
        "the open resumes the relocated conversation" || return 1
    assert_output_not_contains "$(sed -n 's/^parent=//p' "$TEST_TMPDIR/claude-launch")" "repo.moved-wt" \
        "claude replaces cs" || return 1
}

# The launch card reads the context figure of the conversation the resume
# continues, found where the resume finds it: once `claude --worktree` has
# exited, in the parent repo's project dir. At 70% the ask is at crit.
test_card_shows_the_reading_of_a_relocated_conversation() {
    local repo="$TEST_TMPDIR/repo" wt out
    _make_repo "$repo" moved-wt
    wt="$repo/.claude/worktrees/moved-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    # The conversation replied, which is what makes the reading its own.
    printf '{"type":"assistant","sessionId":"%s","message":{"role":"assistant","content":"On it."}}\n' "$UUID_A" \
        >> "$(_wt_project_dir "$repo")/$UUID_A.jsonl"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    printf '70\n' > "$wt/.cs/local/context-pct"
    _launch_recording_stub
    out=$( (unset CLAUDE_CONFIG_DIR; CS_NERD_FONTS=0 CS_STATUSLINE_CTX_WARN='' CS_STATUSLINE_CTX_CRIT='' \
        "$CS_BIN" repo.moved-wt <<< "y") 2>&1) || true
    assert_eq "◱ 70% context used" "$(grep -F 'context used' <<< "$out" | sed 's/.*▌ //')" \
        "the card shows the relocated conversation's reading" || return 1
    assert_eq "1" "$(grep -cxF 'Continue previous conversation? [y/N] ' <<< "$out")" "the ask is at crit" || return 1
    assert_output_contains "$(sed -n 's/^args=//p' "$TEST_TMPDIR/claude-launch")" "--resume $UUID_A" \
        "y resumes the relocated conversation" || return 1
}

# The parent's project dir also holds the parent's own conversations. One that
# stepped into the worktree carries the worktree's record but began on the
# parent, so it is not the worktree's conversation: cs stays claude's parent.
test_resume_of_a_parent_conversation_under_the_worktree_id_keeps_cs_as_the_parent() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" moved-wt
    local wt="$repo/.claude/worktrees/moved-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    _seed_entered_conversation "$repo" "$wt" "$UUID_A" "Start on the parent, then enter the worktree"
    _launch_recording_stub
    (unset CLAUDE_CONFIG_DIR; "$CS_BIN" repo.moved-wt <<< "y" >/dev/null 2>&1) || true
    assert_output_contains "$(sed -n 's/^args=//p' "$TEST_TMPDIR/claude-launch")" "--resume $UUID_A" \
        "the open still resumes the recorded conversation" || return 1
    assert_output_contains "$(sed -n 's/^parent=//p' "$TEST_TMPDIR/claude-launch")" "repo.moved-wt" \
        "cs stays claude's parent" || return 1
}

# The bound conversation's transcript sits in the parent's project dir, and a
# plain claude run in the worktree outside cs leaves another transcript in the
# worktree's own project dir. The bound one still exists, so the open keeps it
# and resumes it; the other conversation is not taken for its replacement.
# The bound conversation's first prompt is rewritten after the adoption bound
# it, as the caller says.
_assert_open_keeps_the_relocated_conversation() {  # first prompt of the bound conversation
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" moved-wt
    local wt="$repo/.claude/worktrees/moved-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the adoption bound the relocated conversation" || return 1
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "$1"
    _seed_conversation "$wt" "$UUID_B" "a quick unrelated question asked outside cs"
    _launch_recording_stub
    local output
    output=$(unset CLAUDE_CONFIG_DIR; "$CS_BIN" repo.moved-wt <<< "y" 2>&1) || true
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state still binds the relocated conversation" || return 1
    assert_output_not_contains "$output" "repaired orphan claude_session_id" \
        "a bound conversation whose transcript was relocated is no orphan" || return 1
    assert_output_contains "$(sed -n 's/^args=//p' "$TEST_TMPDIR/claude-launch")" "--resume $UUID_A" \
        "the open resumes the bound, relocated conversation" || return 1
}

test_open_keeps_a_relocated_conversation_beside_a_newer_local_one() {
    _assert_open_keeps_the_relocated_conversation "Port the sync engine to the worktree branch"
}

# A bound conversation is kept by what it is, the worktree's record and a first
# prompt stamped with the worktree as cwd. The teammate test that discovery
# applies reads the first prompt's whole line, so a prompt that only mentions
# the teammate frame by name must not unbind a conversation already bound.
test_open_keeps_a_relocated_conversation_whose_prompt_names_the_teammate_frame() {
    _assert_open_keeps_the_relocated_conversation "Explain how teammate-message is handled"
}

# A worktree that held two `claude --worktree` conversations has both in the
# parent's project dir. Resuming the older one lands as surely as the newer:
# the bound conversation is checked by its own file, not by being the newest.
test_resume_of_an_older_relocated_conversation_runs_claude_in_place_of_cs() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" moved-wt
    local wt="$repo/.claude/worktrees/moved-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    _seed_relocated_conversation "$repo" "$wt" "$UUID_B" "Write the migration notes for the sync engine"
    touch -t 200001010000 "$(_wt_project_dir "$repo")/$UUID_A.jsonl"
    _launch_recording_stub
    (unset CLAUDE_CONFIG_DIR; "$CS_BIN" repo.moved-wt <<< "y" >/dev/null 2>&1) || true
    assert_output_contains "$(sed -n 's/^args=//p' "$TEST_TMPDIR/claude-launch")" "--resume $UUID_A" \
        "the open resumes the bound, older conversation" || return 1
    assert_output_not_contains "$(sed -n 's/^parent=//p' "$TEST_TMPDIR/claude-launch")" "repo.moved-wt" \
        "claude replaces cs" || return 1
}

test_a_symlink_to_another_project_is_not_adopted() {
    local repo="$TEST_TMPDIR/repo" other="$TEST_TMPDIR/other-project"
    _make_repo "$repo"
    mkdir -p "$other"
    ln -s "$other" "$repo/.claude/worktrees/sneaky"
    _seed_conversation "$other" "$UUID_A" "Work that belongs to another project"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_not_exists "$other/.cs" "a directory outside the repo gets no .cs/" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/repo.sneaky" "no session is registered for it" || return 1
    assert_output_contains "$output" "skip sneaky: not a worktree of" "the skip says why" || return 1
}

# A clone can commit, with git add -f, a directory laid out like a git
# repository (HEAD, objects/, refs/, a config naming a worktree and a
# core.fsmonitor) where Claude Code keeps its worktrees. git asked about that
# entry takes it for the repository and reads that config, so the entry is
# skipped by name before git is asked anything, and a real worktree beside it
# is still adopted.
_commit_git_dir_layout_in_repo() {  # repo_dir, directory under the repo
    local g="$1/$2"
    mkdir -p "$g/objects" "$g/refs"
    : > "$g/objects/.keep"
    : > "$g/refs/.keep"
    printf 'ref: refs/heads/main\n' > "$g/HEAD"
    printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = .\n\tfsmonitor = touch %s; false\n' \
        "$TEST_TMPDIR/fsmonitor-ran" > "$g/config"
    git -C "$1" add -f "$2"
    git -C "$1" commit -q -m "ship a repository layout"
}

test_a_committed_git_repository_layout_is_skipped_by_name() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" real-wt
    _commit_git_dir_layout_in_repo "$repo" .claude/worktrees/planted
    _seed_conversation "$repo/.claude/worktrees/planted" "$UUID_A" "Work in the planted layout"
    _seed_conversation "$repo/.claude/worktrees/real-wt" "$UUID_B" "Work in the real worktree"
    local output rc=0
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_file_not_exists "$TEST_TMPDIR/fsmonitor-ran" "git must not run the layout's core.fsmonitor" || return 1
    assert_eq "0" "$rc" "adopt --worktrees goes on past the layout: $output" || return 1
    assert_eq "skip planted: .claude/worktrees/planted holds HEAD, so git takes it for a repository and would run commands its config names" \
        "$(printf '%s\n' "$output" | grep '^skip planted')" "the skip names the layout" || return 1
    assert_not_exists "$repo/.claude/worktrees/planted/.cs" "the layout gets no .cs/" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/repo.planted" "no session is registered for it" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.real-wt" ] || { echo "  FAIL: the real worktree beside it is adopted: $output"; return 1; }
}

# git asked about a plain entry walks up to the nearest directory holding
# HEAD, so the layout committed at .claude/worktrees itself is named for it.
test_a_committed_git_repository_layout_above_an_entry_is_skipped_by_name() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo"
    mkdir -p "$repo/.claude/worktrees/plain"
    _seed_conversation "$repo/.claude/worktrees/plain" "$UUID_A" "Work in a plain folder"
    _commit_git_dir_layout_in_repo "$repo" .claude/worktrees
    local output rc=0
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_file_not_exists "$TEST_TMPDIR/fsmonitor-ran" "git must not run the layout's core.fsmonitor" || return 1
    assert_eq "0" "$rc" "adopt --worktrees goes on past the layout: $output" || return 1
    assert_eq "skip plain: .claude/worktrees holds HEAD, so git takes it for a repository and would run commands its config names" \
        "$(printf '%s\n' "$output" | grep '^skip plain')" "the skip names the layout above the entry" || return 1
    assert_not_exists "$repo/.claude/worktrees/plain/.cs" "the entry gets no .cs/" || return 1
}

# A clone chooses the names under .claude/worktrees, and a name can carry a
# terminal escape: raw (ESC [2J clears the screen) or as backslash text that
# echo -e would turn into one (\033]0;...\007 retitles the window). Every
# line that names an entry prints it with each character a plain path does
# not have replaced by _, so no escape reaches the terminal.
test_a_worktree_name_is_printed_as_a_plain_path() {
    local repo="$TEST_TMPDIR/repo" raw text output rc=0 real
    _make_repo "$repo"
    text='a\033]0;TITLE\007b'
    raw=$(printf 'c\033[2Jd')
    mkdir -p "$repo/.claude/worktrees/$text" "$repo/.claude/worktrees/$raw"
    : > "$repo/.claude/worktrees/$text/f"
    : > "$repo/.claude/worktrees/$raw/f"
    git -C "$repo" add -f .claude/worktrees
    git -C "$repo" commit -q -m "ship two folders"
    real=$(cd -P "$repo" && pwd -P)
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_eq "0" "$rc" "adopt --worktrees goes on past both: $output" || return 1
    assert_eq "0" "$(printf '%s' "$output" | LC_ALL=C tr -dc '\033\007' | wc -c | tr -d ' ')" \
        "no ESC or BEL byte reaches the terminal" || return 1
    assert_eq "$(printf 'skip a_033_0_TITLE_007b: not a worktree of %s\nskip c__2Jd: not a worktree of %s\n0 adopted; open one with: cs repo.<worktree>' "$real" "$real")" \
        "$output" "each name is printed as a plain path" || return 1
}

test_open_leaves_a_tracked_claude_md_with_cs_markers_alone() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" marked
    local wt="$repo/.claude/worktrees/marked"
    printf '# Project rules\n\n## Discovered Commands\n\n- make test\n\n<!-- cs:session-protocol -->\nold protocol text\n' > "$wt/CLAUDE.md"
    git -C "$wt" commit -q -am "rules with old cs markers"
    _seed_conversation "$wt" "$UUID_A" "Tidy the release notes"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/claude-stub"
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    "$CS_BIN" repo.marked <<< "y" >/dev/null 2>&1 || true
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the open changes no tracked file" || return 1
    assert_eq "- make test" "$(sed -n 5p "$wt/CLAUDE.md")" "the Discovered Commands section survives" || return 1
}

test_an_exclude_file_without_a_final_newline_keeps_its_last_rule() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" tidy
    _seed_conversation "$repo/.claude/worktrees/tidy" "$UUID_A" "Tidy the release notes"
    printf 'my-own-rule.tmp' > "$repo/.git/info/exclude"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "my-own-rule.tmp" "$(sed -n 1p "$repo/.git/info/exclude")" "the existing rule is unchanged" || return 1
    assert_eq ".cs/" "$(sed -n 2p "$repo/.git/info/exclude")" "the .cs/ rule sits on its own line" || return 1
}

test_rerun_finishes_an_adoption_that_lost_its_link() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" halfway
    local wt="$repo/.claude/worktrees/halfway"
    _seed_conversation "$wt" "$UUID_A" "Finish the half done adoption"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    # The state a run leaves when it dies after writing .cs/ and before linking.
    rm "$CS_SESSIONS_ROOT/repo.halfway"
    sed -i.bak '/^adopted:/d' "$wt/.cs/local/state" && rm -f "$wt/.cs/local/state.bak"
    printf 'my note\n' >> "$wt/.cs/README.md"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: the re-run should succeed"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/repo.halfway" ] || { echo "  FAIL: the re-run should register the session"; return 1; }
    assert_eq "my note" "$(tail -1 "$wt/.cs/README.md")" "the re-run keeps the README it found" || return 1
}

test_a_removed_session_is_not_adopted_again() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" retired
    _seed_conversation "$repo/.claude/worktrees/retired" "$UUID_A" "Retire this one later"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    # cs -rm removes the link and keeps .cs/ by design.
    rm "$CS_SESSIONS_ROOT/repo.retired"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_not_exists "$CS_SESSIONS_ROOT/repo.retired" "a removed session stays removed" || return 1
    assert_output_contains "$output" "skip retired: removed with cs -rm (delete its .cs/ to adopt it again)" "the skip says how to get it back" || return 1
}

test_plain_adopt_inside_a_linked_worktree_refuses_and_commits_nothing() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" linked
    local wt="$repo/.claude/worktrees/linked"
    printf 'scratch\n' > "$wt/unrelated.txt"
    local before output rc=0
    before=$(git -C "$wt" rev-parse HEAD)
    output=$(cd "$wt" && "$CS_BIN" -adopt linked-by-hand 2>&1) || rc=$?
    assert_eq "1" "$rc" "plain adopt inside a linked worktree exits 1" || return 1
    assert_output_contains "$output" "cs -adopt --worktrees" "the refusal names the verb for worktrees" || return 1
    assert_eq "$before" "$(git -C "$wt" rev-parse HEAD)" "no commit was made on the branch" || return 1
    assert_eq "?? unrelated.txt" "$(git -C "$wt" status --porcelain)" "the unrelated file stays unstaged" || return 1
    assert_not_exists "$wt/.cs" "nothing was written" || return 1
}

test_rerun_repairs_a_linked_adoption_that_lost_its_marker() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" marked
    local wt="$repo/.claude/worktrees/marked"
    _seed_conversation "$wt" "$UUID_A" "Mark me again please"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    # The state a run leaves when it dies between ln -s and the marker write.
    sed -i.bak '/^adopted:/d' "$wt/.cs/local/state" && rm -f "$wt/.cs/local/state.bak"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: the re-run should succeed"; return 1; }
    grep -q '^adopted:' "$wt/.cs/local/state" || { echo "  FAIL: the re-run should write the missing marker"; return 1; }
    rm "$CS_SESSIONS_ROOT/repo.marked"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || true
    assert_not_exists "$CS_SESSIONS_ROOT/repo.marked" "after that, a removed session stays removed" || return 1
}

test_open_leaves_a_tracked_gitattributes_alone_when_a_legacy_log_exists() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" legacy
    local wt="$repo/.claude/worktrees/legacy"
    printf '.cs/logs/session.log merge=union\n' > "$wt/.gitattributes"
    git -C "$wt" add .gitattributes && git -C "$wt" commit -q -m "attrs"
    _seed_conversation "$wt" "$UUID_A" "Legacy log in the tree"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    mkdir -p "$wt/.cs/logs" && printf 'old log\n' > "$wt/.cs/logs/session.log"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/claude-stub"
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    "$CS_BIN" repo.legacy <<< "y" >/dev/null 2>&1 || true
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the open changes no tracked file" || return 1
    assert_exists "$wt/.cs/local/session.log" "the legacy log still moves" || return 1
}

test_a_worktree_that_tracks_a_file_cs_must_own_is_skipped() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" tracked
    local wt="$repo/.claude/worktrees/tracked"
    printf 'committed local rules\n' > "$wt/CLAUDE.local.md"
    git -C "$wt" add CLAUDE.local.md && git -C "$wt" commit -q -m "track the local file"
    _seed_conversation "$wt" "$UUID_A" "A repo that tracks its local file"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_not_exists "$wt/.cs" "nothing is written into it" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/repo.tracked" "no session is registered" || return 1
    assert_output_contains "$output" "skip tracked: CLAUDE.local.md is tracked" "the skip names the tracked file" || return 1
    # A tracked <file>.tmp sibling is the user's own file: cs's temp names are
    # unique, so it is neither a reason to skip nor touched by the adoption.
    git -C "$wt" rm -q --cached CLAUDE.local.md && rm "$wt/CLAUDE.local.md"
    mkdir -p "$wt/.claude" && printf '{}\n' > "$wt/.claude/settings.local.json.tmp"
    git -C "$wt" add .claude/settings.local.json.tmp && git -C "$wt" commit -q -m "track a tmp sibling"
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_exists "$wt/.cs" "the worktree is adopted" || return 1
    assert_output_not_contains "$output" "skip tracked" "a tracked tmp sibling is no reason to skip" || return 1
    assert_eq "{}" "$(cat "$wt/.claude/settings.local.json.tmp")" "the tracked tmp sibling is untouched" || return 1
    assert_eq "" "$(git -C "$wt" status --porcelain -- .claude/settings.local.json.tmp)" "and stays clean" || return 1
}

test_open_refuses_once_the_branch_tracks_a_file_cs_rewrites() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" later
    local wt="$repo/.claude/worktrees/later"
    _seed_conversation "$wt" "$UUID_A" "The branch grows a local file later"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    printf 'committed later\n' > "$wt/CLAUDE.local.md"
    # Adoption excluded it, so tracking it now takes -f, as a user would.
    git -C "$wt" add -f CLAUDE.local.md && git -C "$wt" commit -q -m "track the local file"
    printf '#!/bin/bash\nprintf launched > "%s/launched"\nexit 0\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/claude-stub"
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    local output rc=0
    output=$("$CS_BIN" repo.later <<< "y" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open exits 1" || return 1
    assert_output_contains "$output" "CLAUDE.local.md is tracked" "the refusal names the tracked file" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude is not launched" || return 1
    assert_eq "" "$(git -C "$wt" status --porcelain)" "nothing tracked changed" || return 1
    assert_eq "committed later" "$(cat "$wt/CLAUDE.local.md")" "the tracked file is byte for byte as committed" || return 1
}

test_a_worktree_whose_claude_dir_is_a_symlink_is_skipped() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" linkedclaude
    local wt="$repo/.claude/worktrees/linkedclaude"
    mkdir -p "$wt/config/claude"
    printf '{}\n' > "$wt/config/claude/settings.local.json"
    ln -s config/claude "$wt/.claude"
    git -C "$wt" add config .claude && git -C "$wt" commit -q -m "settings behind a symlink"
    _seed_conversation "$wt" "$UUID_A" "A symlinked .claude directory"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_not_exists "$wt/.cs" "nothing is written into it" || return 1
    assert_output_contains "$output" "skip linkedclaude: .claude is a symlink" "the skip says why" || return 1
}

test_open_refuses_a_claude_local_symlink_to_a_tracked_file() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" sneakylink
    local wt="$repo/.claude/worktrees/sneakylink"
    printf 'tracked prose\n' > "$wt/README.md"
    git -C "$wt" add README.md && git -C "$wt" commit -q -m readme
    _seed_conversation "$wt" "$UUID_A" "A local file that is really a link"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    ln -s README.md "$wt/CLAUDE.local.md"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/claude-stub"
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    local output rc=0
    output=$("$CS_BIN" repo.sneakylink <<< "y" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the open exits 1" || return 1
    assert_output_contains "$output" "CLAUDE.local.md is a symlink" "the refusal names the link" || return 1
    assert_eq "tracked prose" "$(cat "$wt/README.md")" "the tracked target is untouched" || return 1
}

# A parent conversation that entered the worktree carries the same
# worktree-state record as the worktree's own conversation. It began on the
# parent, so it stays the parent's: the worktree binds the conversation that
# was started in it, even when the parent's is the newer file.
test_binds_the_worktrees_own_conversation_over_a_parent_one_that_entered_it() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" entered-wt
    local wt="$repo/.claude/worktrees/entered-wt"
    _seed_relocated_conversation "$repo" "$wt" "$UUID_A" "Port the sync engine to the worktree branch"
    sleep 1
    _seed_entered_conversation "$repo" "$wt" "$UUID_B" "Review the parent repo and step into the worktree"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: adopt --worktrees should succeed: $output"; return 1; }

    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state binds the conversation started in the worktree, not the parent's that entered it" || return 1
    assert_eq "Port the sync engine to the worktree branch" "$(_readme_objective "$wt")" \
        "the Objective is the worktree conversation's first prompt" || return 1
}

# A worktree nobody ever started a conversation in has none to bind, even when
# a parent conversation entered it: that conversation is the parent's.
test_skips_a_worktree_only_a_parent_conversation_entered() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" visited-wt
    local wt="$repo/.claude/worktrees/visited-wt"
    _seed_entered_conversation "$repo" "$wt" "$UUID_B" "Review the parent repo and step into the worktree"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: adopt --worktrees should succeed: $output"; return 1; }

    assert_output_contains "$output" "skip visited-wt: no conversation" "the skip names the worktree and the reason" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/repo.visited-wt" ] || { echo "  FAIL: a session link was made for a worktree with no conversation of its own"; return 1; }
    [ ! -e "$wt/.cs" ] || { echo "  FAIL: the worktree was given session records"; return 1; }
}

# One worktree's path can be the start of another's (`wt` and `wt2`). The
# conversation belongs to the worktree whose whole path it names.
test_a_worktree_does_not_claim_a_longer_named_siblings_conversation() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt wt2
    _seed_relocated_conversation "$repo" "$repo/.claude/worktrees/wt2" "$UUID_A" "Work that happened in the second worktree"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: adopt --worktrees should succeed: $output"; return 1; }

    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$repo/.claude/worktrees/wt2/.cs/local/state")" \
        "wt2 binds its own conversation" || return 1
    assert_output_contains "$output" "skip wt: no conversation" "wt has none and is skipped" || return 1
    [ ! -e "$CS_SESSIONS_ROOT/repo.wt" ] || { echo "  FAIL: wt was adopted with its sibling's conversation"; return 1; }
}

run_test test_refuses_outside_a_git_repo
run_test test_refuses_a_repo_without_claude_worktrees
run_test test_adopts_a_worktree_with_a_conversation
run_test test_adopts_a_worktree_whose_transcript_moved_to_the_parent
run_test test_adopts_a_relocated_conversation_when_the_repo_path_needs_json_escaping
run_test test_binds_the_worktrees_own_conversation_over_a_parent_one_that_entered_it
run_test test_skips_a_worktree_only_a_parent_conversation_entered
run_test test_a_worktree_does_not_claim_a_longer_named_siblings_conversation
run_test test_skips_a_worktree_without_a_conversation
run_test test_binds_the_newest_of_two_conversations
run_test test_rerun_adopts_nothing_twice_and_keeps_the_exclude_file
run_test test_dry_run_writes_nothing
run_test test_rerun_prunes_a_link_whose_worktree_is_gone
run_test test_same_worktree_name_under_two_repos_opens_the_right_one
run_test test_resume_of_a_relocated_conversation_runs_claude_in_place_of_cs
run_test test_card_shows_the_reading_of_a_relocated_conversation
run_test test_resume_of_a_parent_conversation_under_the_worktree_id_keeps_cs_as_the_parent
run_test test_resume_of_an_older_relocated_conversation_runs_claude_in_place_of_cs
run_test test_open_keeps_a_relocated_conversation_beside_a_newer_local_one
run_test test_open_keeps_a_relocated_conversation_whose_prompt_names_the_teammate_frame
run_test test_a_symlink_to_another_project_is_not_adopted
run_test test_a_committed_git_repository_layout_is_skipped_by_name
run_test test_a_committed_git_repository_layout_above_an_entry_is_skipped_by_name
run_test test_a_worktree_name_is_printed_as_a_plain_path
run_test test_open_leaves_a_tracked_claude_md_with_cs_markers_alone
run_test test_an_exclude_file_without_a_final_newline_keeps_its_last_rule
run_test test_rerun_finishes_an_adoption_that_lost_its_link
run_test test_a_removed_session_is_not_adopted_again
run_test test_plain_adopt_inside_a_linked_worktree_refuses_and_commits_nothing
run_test test_rerun_repairs_a_linked_adoption_that_lost_its_marker
run_test test_open_leaves_a_tracked_gitattributes_alone_when_a_legacy_log_exists
run_test test_a_worktree_that_tracks_a_file_cs_must_own_is_skipped
run_test test_open_refuses_once_the_branch_tracks_a_file_cs_rewrites
run_test test_a_worktree_whose_claude_dir_is_a_symlink_is_skipped
run_test test_open_refuses_a_claude_local_symlink_to_a_tracked_file

report_results
