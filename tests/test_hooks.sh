#!/usr/bin/env bash
# ABOUTME: Tests for session lifecycle hooks not covered by other test files
# ABOUTME: Covers session-auto-approve, subagent-context, tool-failure-logger

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# Override setup for hook testing
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # CS_ACTOR is the top-precedence actor override, so an exported one on the
    # developer's machine would decide the identity these tests pin.
    unset CS_ACTOR
    # Hooks now resolve a session from the directory, so an ambient
    # CLAUDE_PROJECT_DIR would bind them to a REAL session: tests that assert
    # "declines outside a session" fail, and worse, ones that assert silence
    # stay green while the hook writes into that live session.
    unset CLAUDE_PROJECT_DIR
    # The hook treats an in-session CLAUDE_CONFIG_DIR as a control directory;
    # the developer's own (outside any fixture) must not reach the tests.
    unset CLAUDE_CONFIG_DIR
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{local,memory}
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# narrative-reminder.sh
# ============================================================================

_backdate() {
    # backdate a file ~10 minutes so the staleness check fires
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$1" 2>/dev/null || true
}

test_narrative_reminder_approves_outside_session() {
    local output
    output=$(echo '{}' | CLAUDE_SESSION_NAME= bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve outside a cs session" || return 1
}

test_narrative_reminder_approves_when_recently_modified() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Should approve when narrative recently modified" || return 1
}

test_narrative_reminder_blocks_when_stale() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "Should block when narrative is stale" || return 1
    assert_output_contains "$output" "narrative.md" "Reminder should point at narrative.md" || return 1
}

test_narrative_reminder_tracks_per_actor() {
    rm -f "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    echo "# Session narrative (alex)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alex.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alex.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "Should block on stale per-actor narrative" || return 1
    assert_output_contains "$output" "narrative.alex.md" "Reminder should point at the per-actor narrative" || return 1
}

# Homebrew's coreutils can put GNU stat ahead of the system's on a Mac, and GNU
# `stat -f` reports the file system rather than the file's mtime. The hook reads
# the mtime by what the stat on PATH answers, so a fresh narrative is left alone
# and a stale one is found. Both are asserted: an mtime misread as 0 makes every
# narrative stale, which the stale arm alone would pass. bash takes OSTYPE from
# the environment, so a Mac's value here puts the same question to the hook on a
# Linux runner.
test_narrative_reminder_reads_mtimes_with_gnu_stat_on_a_mac() {
    local gnu shim="$TEST_TMPDIR/gnubin" output
    if gstat --version 2>/dev/null | grep -q GNU; then
        gnu=$(command -v gstat)
    elif stat --version 2>/dev/null | grep -q GNU; then
        gnu=$(command -v stat)
    else
        echo "  SKIP: no GNU stat on this machine"
        return 77
    fi
    mkdir -p "$shim"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$gnu" > "$shim/stat"
    chmod +x "$shim/stat"
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    output=$(echo '{}' | PATH="$shim:$PATH" OSTYPE=darwin24 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_eq '{"decision": "approve"}' "$output" "a fresh narrative is left alone with GNU stat first on a Mac" || return 1
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    output=$(echo '{}' | PATH="$shim:$PATH" OSTYPE=darwin24 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" '"decision":"block"' "a stale narrative is found with GNU stat first on a Mac" || return 1
    assert_output_contains "$output" "narrative.md" "the reminder points at the narrative" || return 1
}

test_narrative_reminder_asks_for_appended_corrections_not_rewrites() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "append a dated correction" "corrections are appended" || return 1
    assert_output_contains "$output" "never rewrite or delete earlier sections" "earlier sections are immutable" || return 1
    assert_output_not_contains "$output" "correct or remove them" "the in-place instruction is gone" || return 1
}

test_narrative_reminder_flags_a_narrative_over_budget() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.alice.md is 2 KB, over the 2 KB budget" "names the file and the budget" || return 1
    assert_output_contains "$output" "cs -narrative rotate" "points at the rotation" || return 1
}

# .cs/memory is tracked, so a clone chooses a narrative's file name, and the
# name can carry a terminal escape: a raw ESC or BEL byte, or backslash text
# echo -e would turn into one. The Stop hook's reason names the newest
# narrative and the one over budget as plain names, each character a plain
# name lacks replaced by _. Without the shared library it names neither.
test_narrative_reminder_names_a_narrative_as_a_plain_name() {
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.a$bad.md" partial="$TEST_TMPDIR/partial-hooks"
    { echo "# Session narrative"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local reason newest
    reason=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh" | jq -r '.reason')
    newest=$(sed -n 's/.*Newest on disk is \([^ ]*\) .*/\1/p' <<< "$reason")
    assert_eq "narrative.a$shown.md." "${newest##*/}" "the reason names the newest narrative as a plain name" || return 1
    assert_output_contains "$reason" " narrative\.a$shown\.md is 2 KB, over the 2 KB budget" \
        "the reason names the narrative over budget as a plain name" || return 1
    assert_no_escape_bytes "$reason" "no escape byte reaches Claude" || return 1
    mkdir -p "$partial"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    rm "$partial/cs-shared.sh"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    reason=$(echo '{}' | bash "$partial/narrative-reminder.sh" | jq -r '.reason')
    newest=$(sed -n 's/.*Newest on disk is \([^ ]*\) .*/\1/p' <<< "$reason")
    assert_eq "?." "${newest##*/}" "without the library the reason withholds the name" || return 1
    assert_no_escape_bytes "$reason" "no escape byte reaches Claude without the library" || return 1
}

# The same octal trap as SessionStart's: `08` passes _num_or and aborts the
# KB arithmetic, and a Stop hook that dies emits no decision at all.
test_narrative_reminder_reads_a_leading_zero_budget_as_decimal() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=08 bash "$HOOKS_DIR/narrative-reminder.sh" 2>"$TEST_TMPDIR/stderr")
    assert_file_not_contains "$TEST_TMPDIR/stderr" "value too great for base" "no octal abort" || return 1
    assert_output_contains "$output" "narrative.alice.md is 2 KB, over the 0 KB budget" "the override is decimal 8" || return 1
}

test_narrative_reminder_is_silent_about_budget_when_under() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "the reminder itself still fires" || return 1
    assert_output_not_contains "$output" "over the" "no budget line under budget" || return 1
}

test_narrative_reminder_survives_an_unreadable_narrative() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    _backdate "$nf"
    chmod 000 "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    chmod 644 "$nf"
    assert_output_contains "$output" "decision" "the hook still answers with JSON when a narrative cannot be read" || return 1
}

test_narrative_reminder_budget_line_covers_a_teammates_file() {
    # The line names whichever file is over; the "if it is yours" clause leaves
    # the decision to the reader, since the hook does not resolve the actor.
    { echo "# Session narrative (bob)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.bob.md is 2 KB" "names bob's file" || return 1
    assert_output_contains "$output" "if it is yours" "leaves ownership to the reader" || return 1
}

test_stop_raises_attention_marker() {
    # Turn end raises the machine-local attention flag the statusline shows
    # until the user next interacts. Lives in .cs/local/ (never git-synced).
    rm -rf "$CLAUDE_SESSION_META_DIR/local"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "Stop hook should raise the attention marker" || return 1
}

test_stop_no_attention_marker_for_subagents() {
    rm -rf "$CLAUDE_SESSION_META_DIR/local"
    echo '{"agent_id":"sub-1"}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "subagent stops must not raise the attention marker" || return 1
}

test_narrative_reminder_respects_cooldown() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    date +%s > "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Fresh cooldown should suppress the reminder" || return 1
}

# The stamp sits at the .cs root, where a write needs no approval, so its
# content is whatever anyone put there. Shell arithmetic runs a command
# substitution found in an operand's array subscript; the array is PATH because
# the hook runs under set -u, which stops on an unset name before the
# substitution is reached.
test_narrative_reminder_reads_its_cooldown_stamp_as_data() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    printf 'PATH[$(:>%s)]' "$TEST_TMPDIR/ran-from-stamp" > "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null)
    assert_file_not_exists "$TEST_TMPDIR/ran-from-stamp" "A cooldown stamp's content must never run" || return 1
    assert_output_contains "$output" "block" "A stamp that is not a time counts as no stamp: the reminder fires" || return 1
    assert_output_contains "$output" "narrative.md" "Reminder should point at narrative.md" || return 1
}

test_narrative_reminder_approves_for_subagent() {
    echo "# Session narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{"agent_id":"sub-1"}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "approve" "Subagent should always approve" || return 1
    assert_output_not_contains "$output" "block" "Subagent should never be blocked" || return 1
}

# ============================================================================
# session-auto-approve.sh
# ============================================================================

test_auto_approve_allows_cs_metadata_write() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve writes to .cs/ files" || return 1
}

test_auto_approve_allows_cs_edit() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/summary.md" \
        '{tool_name: "Edit", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' \
        "Should auto-approve edits to .cs/ files" || return 1
}

test_auto_approve_ignores_non_cs_path() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_DIR/src/main.py" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    # Should produce no output (falls through to normal permission prompt)
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-.cs/ paths, got: $output"
        return 1
    fi
}

test_auto_approve_ignores_non_write_tools() {
    local input='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output for non-Write/Edit tools, got: $output"
        return 1
    fi
}

# A ../ traversal spelling that resolves outside .cs/ must NOT be auto-approved.
test_auto_approve_rejects_traversal() {
    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/../../../etc/evil.conf" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: traversal path must fall through to the prompt, got: $output"
        return 1
    fi
}

# A symlink AT the write target resolves inside .cs/ by its parent, so only an
# lstat of the final component catches it. Session directories are git-shared by
# design, so a pulled symlink would otherwise turn every auto-approved metadata
# write into a write outside the session.
test_auto_approve_rejects_leaf_symlink() {
    # A filesystem where `ln -s` produces a regular-file COPY makes the -L guard
    # cannot fire and its approval is correct there (same reason as
    # tests/test_adopt.sh's symlink cases).
    local outside="$TEST_TMPDIR/outside-the-session.conf"
    echo "original" > "$outside"
    ln -s "$outside" "$CLAUDE_SESSION_META_DIR/notes.md"

    local input
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/notes.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: a symlinked target must fall through to the prompt, got: $output"
        return 1
    fi
}

# A hard link has no link to see: a content file under .cs/ that shares its
# inode with a file elsewhere (a project setting, say) passes every path and
# symlink check, and an in-place Edit then changes that other file. An
# existing target with more than one link falls through to the prompt, and
# stderr says how many names it has, the name printed plain as the symlink
# decline prints one; once the second name is gone, the same write is
# approved again and stderr is empty.
test_auto_approve_rejects_a_hard_linked_target() {
    local outside="$TEST_TMPDIR/project-settings.json"
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory"
    echo '{"hooks":{}}' > "$outside"
    ln "$outside" "$CLAUDE_SESSION_META_DIR/memory/config.md" || { echo "  FAIL: hard link fixture"; return 1; }

    _assert_falls_through Edit "$CLAUDE_SESSION_META_DIR/memory/config.md" \
        "a hard-linked target" \
        "cs auto-approve: not approving, $CLAUDE_SESSION_META_DIR/memory/config.md has 2 names" || return 1

    local input output
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/memory/config.md" \
        '{tool_name: "Edit", tool_input: {file_path: $path}}')
    rm -f "$outside"
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh" 2>"$TEST_TMPDIR/auto-approve.err")
    assert_eq "allow" "$(echo "$output" | jq -r '.hookSpecificOutput.decision.behavior')" \
        "the same file with one name is approved" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/auto-approve.err")" \
        "an approval says nothing on stderr" || return 1

    # A name the session's writer chose is printed through the plain-name rule.
    ln "$CLAUDE_SESSION_META_DIR/memory/config.md" "$TEST_TMPDIR/second-name" \
        || { echo "  FAIL: hard link fixture"; return 1; }
    mv "$CLAUDE_SESSION_META_DIR/memory/config.md" "$CLAUDE_SESSION_META_DIR/memory/two words.md"
    _assert_falls_through Edit "$CLAUDE_SESSION_META_DIR/memory/two words.md" \
        "a hard-linked target with a space in its name" \
        "cs auto-approve: not approving, $CLAUDE_SESSION_META_DIR/memory/two_words.md has 2 names" || return 1
}

# A link count that neither stat form can read is no evidence of one name:
# the write falls through to the prompt, and stderr says the count could not
# be read, the name printed plain. The stand-in stat fails both forms; the
# same write with the system stat is approved, so the stand-in is the one
# reason it prompts.
test_auto_approve_declines_a_target_whose_link_count_cannot_be_read() {
    local shim="$TEST_TMPDIR/failing-stat" target="$CLAUDE_SESSION_META_DIR/memory/two words.md"
    mkdir -p "$shim" "$CLAUDE_SESSION_META_DIR/memory"
    printf '#!/bin/sh\nexit 1\n' > "$shim/stat"
    chmod +x "$shim/stat"
    echo "# notes" > "$target"

    _assert_allowed Edit "$target" "a one-name target with the system stat" || return 1
    PATH="$shim:$PATH" _assert_falls_through Edit "$target" \
        "a target whose link count cannot be read" \
        "cs auto-approve: not approving, could not read the link count of $CLAUDE_SESSION_META_DIR/memory/two_words.md" || return 1
}

# The link count is asked last, so a write that also meets an earlier decline
# prints that one: a hard-linked target beside a link under .cs/local names
# the link. With the link gone, the same target declines for its two names,
# so the hard link alone is enough and the first line is the order's.
test_auto_approve_names_a_control_link_before_a_hard_linked_target() {
    local meta="$CLAUDE_SESSION_META_DIR" outside="$TEST_TMPDIR/project-settings.json" real
    mkdir -p "$meta/memory"
    echo '{"hooks":{}}' > "$outside"
    ln "$outside" "$meta/memory/config.md" || { echo "  FAIL: hard link fixture"; return 1; }
    ln -s "$TEST_TMPDIR" "$meta/local/planted"
    real="$(cd "$meta/local" && pwd -P)"

    _assert_falls_through Edit "$meta/memory/config.md" \
        "a hard-linked target beside a link in local/" \
        "$(_link_reason "$real/planted")" || return 1
    rm "$meta/local/planted"
    _assert_falls_through Edit "$meta/memory/config.md" \
        "the same hard-linked target with the link gone" \
        "cs auto-approve: not approving, $meta/memory/config.md has 2 names" || return 1
}

# Audit C2: approval covered every file under .cs/, including the ones cs
# itself acts on: `.cs/local/pre-open` runs at the next open (Edit keeps the
# exec bit), `.cs/claude-config/` is Claude Code's own config in an encrypted
# session, the queue and the mailbox are execution channels. A prompt-injected
# Write there landed with no prompt. Those paths now fall through to the
# prompt; the content files (memory, narratives, handoffs, notes) stay
# frictionless. The parent of every target is created first: a parent that
# does not resolve already falls through, which would make a missing-parent
# test green for the wrong reason.
_auto_approve_output() {
    # $1 tool, $2 path
    local input
    input=$(jq -n --arg tool "$1" --arg path "$2" \
        '{tool_name: $tool, tool_input: {file_path: $path}}')
    echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh"
}

_assert_falls_through() {
    # $1 tool, $2 path, $3 what, [$4 the decline the hook prints on stderr;
    # without it the hook must print nothing there]
    local output
    output=$(_auto_approve_output "$1" "$2" 2>"$TEST_TMPDIR/auto-approve.err")
    if [[ -n "$output" ]]; then
        echo "  FAIL: $3 must fall through to the prompt, got: $output"
        return 1
    fi
    assert_eq "${4:-}" "$(cat "$TEST_TMPDIR/auto-approve.err")" \
        "what the hook prints on stderr for $3" || return 1
}

_assert_allowed() {
    # $1 tool, $2 path, $3 what
    local output
    output=$(_auto_approve_output "$1" "$2")
    assert_output_contains "$output" '"allow"' "$3 should be auto-approved" || return 1
}

test_auto_approve_rejects_pre_open() {
    printf '#!/bin/sh\n' > "$CLAUDE_SESSION_META_DIR/local/pre-open"
    chmod 755 "$CLAUDE_SESSION_META_DIR/local/pre-open"
    _assert_falls_through Edit "$CLAUDE_SESSION_META_DIR/local/pre-open" \
        "an Edit of .cs/local/pre-open" || return 1
    rm "$CLAUDE_SESSION_META_DIR/local/pre-open"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/local/pre-open" \
        "a Write of .cs/local/pre-open" || return 1
}

test_auto_approve_rejects_local_state_files() {
    mkdir -p "$CLAUDE_SESSION_META_DIR/local/queue"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/local/queue/0001" \
        "a queued task" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/local/state" \
        ".cs/local/state" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/local/identity" \
        ".cs/local/identity" || return 1
}

# The marker the rotate skill arms is the one machine-local file Claude writes
# as part of a ritual; session-start.sh rejects any content with a separator,
# so it names a handoff Claude already wrote and nothing else.
test_auto_approve_allows_pending_handoff_marker() {
    _assert_allowed Write "$CLAUDE_SESSION_META_DIR/local/pending-handoff" \
        "the pending-handoff marker" || return 1
}

test_auto_approve_rejects_claude_config_and_keys() {
    mkdir -p "$CLAUDE_SESSION_META_DIR/claude-config" "$CLAUDE_SESSION_META_DIR/age-recipients"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/claude-config/.claude.json" \
        "Claude Code's config" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/age-recipients/x.pub" \
        "an age recipient" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/session.lock" \
        "the session lock" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/secrets.age" \
        "the secret sync file" || return 1
}

# .cs/private holds the content files of an encrypted session beside its queue
# and mailbox: only the content directories stay frictionless there.
test_auto_approve_private_allows_content_not_queue() {
    mkdir -p "$CLAUDE_SESSION_META_DIR/private/handoffs" "$CLAUDE_SESSION_META_DIR/private/queue"
    _assert_allowed Write "$CLAUDE_SESSION_META_DIR/private/handoffs/2026-01-01-x.md" \
        "a handoff in the vault" || return 1
    _assert_allowed Write "$CLAUDE_SESSION_META_DIR/private/pending-handoff" \
        "the vault's pending-handoff marker" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/private/queue/0001" \
        "a queued task in the vault" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/private/session.log" \
        "the vault's session log" || return 1
}

# An encrypted session links memory and claude-config into .cs/vault-mnt
# (lib/63-encrypt.sh), so every real path there starts with vault-mnt/. The
# classification must see memory/ as content and claude-config/ as config
# through the link, not the mount directory as one unknown name.
test_auto_approve_classifies_through_vault_links() {
    local meta="$CLAUDE_SESSION_META_DIR"
    rm -r "$meta/memory"
    mkdir -p "$meta/vault-mnt/memory" "$meta/vault-mnt/claude-config" "$meta/vault-mnt/private"
    ln -s vault-mnt/memory "$meta/memory"
    ln -s vault-mnt/claude-config "$meta/claude-config"
    ln -s vault-mnt/private "$meta/private"
    _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative behind the vault link" || return 1
    _assert_falls_through Write "$meta/claude-config/settings.json" \
        "a setting behind the vault link" || return 1
    # A control name that resolves into the vault is still a name: on a
    # case-sensitive filesystem PRIVATE/ and CLAUDE-CONFIG/ beside the links
    # are plain directories, and a write there prompts as the spelled name
    # does. On APFS they are the links themselves.
    mkdir -p "$meta/PRIVATE" "$meta/CLAUDE-CONFIG"
    _assert_falls_through Write "$meta/PRIVATE/x.md" \
        ".cs/PRIVATE beside a vault-linked private" || return 1
    _assert_falls_through Write "$meta/CLAUDE-CONFIG/settings.json" \
        ".cs/CLAUDE-CONFIG beside a vault-linked claude-config" || return 1
}

# A shared directory under .cs/ can carry a committed symlink into local/;
# the spelled path looks like content, only the real one shows the target.
test_auto_approve_rejects_link_into_local() {
    ln -s ../local "$CLAUDE_SESSION_META_DIR/memory/notes"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/memory/notes/pre-open" \
        "a write through a link into local/" || return 1
}

# Edit keeps the exec bit, so an executable anywhere under .cs/ is a script
# whatever directory it sits in.
test_auto_approve_rejects_executable_target() {
    printf '#!/bin/sh\n' > "$CLAUDE_SESSION_META_DIR/memory/run.sh"
    chmod 755 "$CLAUDE_SESSION_META_DIR/memory/run.sh"
    _assert_falls_through Edit "$CLAUDE_SESSION_META_DIR/memory/run.sh" \
        "an executable file" || return 1
}

# cs refuses to open a session whose .cs or .cs/local is a symlink (audit C1),
# but a claude started in the directory by hand still runs this hook.
test_auto_approve_rejects_linked_cs_dir() {
    local real="$TEST_TMPDIR/elsewhere"
    mkdir -p "$real/memory"
    rm -r "$CLAUDE_SESSION_META_DIR"
    ln -s "$real" "$CLAUDE_SESSION_META_DIR"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        "a write under a linked .cs" || return 1
    rm "$CLAUDE_SESSION_META_DIR"
    mkdir -p "$CLAUDE_SESSION_META_DIR/memory"
    ln -s "$real" "$CLAUDE_SESSION_META_DIR/local"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        "a write under a linked .cs/local" || return 1
}

# APFS keeps the case a caller typed, so pwd -P returns LOCAL/ for local/.
# On a case-sensitive filesystem LOCAL is another directory, and the parent
# is created so the test does not pass on a missing parent there. The
# fixture holds a local/ that the lowercased LOCAL matches, and no
# age-recipients/ or private/: a case variant prompts whether or not the
# control directory it spells exists.
test_auto_approve_rejects_case_variants() {
    mkdir -p "$CLAUDE_SESSION_META_DIR/LOCAL" "$CLAUDE_SESSION_META_DIR/AGE-RECIPIENTS" \
        "$CLAUDE_SESSION_META_DIR/PRIVATE"
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/LOCAL/state" \
        ".cs/LOCAL/state" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/AGE-RECIPIENTS/x.pub" \
        ".cs/AGE-RECIPIENTS/x.pub" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/PRIVATE/x.md" \
        ".cs/PRIVATE/x.md" || return 1
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/SESSION.LOCK" \
        ".cs/SESSION.LOCK" || return 1
}

# The root of .cs/ holds the notes people and Claude read beside the files cs
# acts on: the stamps the Stop hook reads, the locks, the archive marker, the
# timeline, and the names cs gives its control directories. Only a Markdown
# file is approved there, so a name cs reads later cannot be written unseen.
test_auto_approve_prompts_for_a_reminder_stamp() {
    local stamp="$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    _assert_falls_through Write "$stamp" "a new reminder stamp" || return 1
    echo 1700000000 > "$stamp"
    _assert_falls_through Edit "$stamp" "an Edit of the reminder stamp" || return 1
}

# A control directory cs has not made yet is a free name at the root: taken
# by a file, it is what cs finds where it expects its directory.
test_auto_approve_prompts_for_a_control_directory_name_taken_by_a_file() {
    local name
    for name in private claude-config age-recipients .git vault-mnt; do
        _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/$name" \
            "a file named .cs/$name" || return 1
    done
}

test_auto_approve_prompts_for_the_open_lock() {
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/session.mutex.lock" \
        "the lock an open holds" || return 1
}

test_auto_approve_prompts_for_the_archive_marker() {
    _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/archived" \
        "the archive marker" || return 1
}

test_auto_approve_prompts_for_the_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    _assert_falls_through Write "$timeline" "a new timeline" || return 1
    echo '{"event":"session_started"}' > "$timeline"
    _assert_falls_through Edit "$timeline" "an Edit of the timeline" || return 1
}

# Claude Code loads a CLAUDE.md from the directory of a file it reads, so one
# at the root of .cs/ is instructions, not notes.
test_auto_approve_prompts_for_instructions_at_the_root() {
    local name
    for name in CLAUDE.md CLAUDE.local.md claude.md; do
        _assert_falls_through Write "$CLAUDE_SESSION_META_DIR/$name" \
            ".cs/$name" || return 1
    done
}

# The same holds in every directory below .cs/: Claude Code reads the
# CLAUDE.md beside a file it opens, and it opens memory/ in every session.
test_auto_approve_prompts_for_instructions_in_a_content_directory() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/plans" "$meta/private/handoffs"
    _assert_falls_through Write "$meta/memory/CLAUDE.md" \
        ".cs/memory/CLAUDE.md" || return 1
    _assert_falls_through Write "$meta/plans/CLAUDE.local.md" \
        ".cs/plans/CLAUDE.local.md" || return 1
    _assert_falls_through Write "$meta/private/handoffs/claude.md" \
        ".cs/private/handoffs/claude.md" || return 1
    _assert_allowed Write "$meta/memory/claude-notes.md" \
        "a memory topic whose name only starts with claude" || return 1
}

# The Write tool makes a missing parent directory, so the first handoff,
# checkpoint or plan of a session lands in a directory that is not there yet.
# The directories cs itself keeps content in are approved by name, directly
# at the root of .cs/; the hook makes nothing itself.
test_auto_approve_allows_the_first_write_into_a_content_directory() {
    local meta="$CLAUDE_SESSION_META_DIR" name
    rm -r "$meta/memory"
    for name in handoffs checkpoints narrative-archive memory plans research; do
        _assert_allowed Write "$meta/$name/2026-01-01-x.md" \
            "the first file in a missing .cs/$name" || return 1
        assert_not_exists "$meta/$name" "the hook leaves .cs/$name unmade" || return 1
    done
}

# Any other missing directory keeps its prompt: a control directory cs has not
# made yet, a name cs does not use, a second missing level, another spelling,
# one of cs's names below the root, and a dangling link where the directory
# would go.
test_auto_approve_prompts_for_the_first_write_into_any_other_directory() {
    local meta="$CLAUDE_SESSION_META_DIR" path
    for path in private/queue/0001 private/handoffs/x.md queue/0001 notes/x.md \
        handoffs/deep/x.md Handoffs/x.md claude-config/settings.json memory/plans/x.md; do
        _assert_falls_through Write "$meta/$path" \
            "the first file at .cs/$path" || return 1
    done
    ln -s "$TEST_TMPDIR/nowhere" "$meta/plans"
    _assert_falls_through Write "$meta/plans/x.md" \
        "a file behind a dangling link at .cs/plans" || return 1
}

# An encrypted session keeps its handoffs and checkpoints in the vault, so a
# new directory of that name at the plaintext root is not where they go.
test_auto_approve_prompts_for_a_new_plaintext_directory_in_an_encrypted_session() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/private"
    _assert_falls_through Write "$meta/handoffs/2026-01-01-x.md" \
        "a first handoff at the plaintext root of an encrypted session" || return 1
}

test_auto_approve_allows_markdown_at_the_root() {
    _assert_allowed Write "$CLAUDE_SESSION_META_DIR/README.md" \
        "the session README" || return 1
    echo "# Changes" > "$CLAUDE_SESSION_META_DIR/changes.md"
    _assert_allowed Edit "$CLAUDE_SESSION_META_DIR/changes.md" \
        "an Edit of a Markdown file at the root" || return 1
    _assert_allowed Write "$CLAUDE_SESSION_META_DIR/memory/topic_notes.md" \
        "a memory topic" || return 1
}

# A filesystem that folds names (APFS reads a long s as s and the Kelvin sign
# as k) makes a name outside ASCII another spelling of a control file, and no
# comparison of strings sees it. Below .cs/ such a name always prompts. The
# names are written as byte escapes so this file stays ASCII.
test_auto_approve_prompts_for_a_non_ascii_name_in_content() {
    local memory="$CLAUDE_SESSION_META_DIR/memory"
    _assert_falls_through Write "$memory/caf"$'\xc3\xa9'".md" \
        "a memory file named with a precomposed e-acute" || return 1
    _assert_falls_through Write "$memory/cafe"$'\xcc\x81'".md" \
        "a memory file named with a combining acute" || return 1
    mkdir -p "$memory/r"$'\xc3\xa9'"sum"
    _assert_falls_through Write "$memory/r"$'\xc3\xa9'"sum/notes.md" \
        "a file in a memory directory named outside ASCII" || return 1
}

# mkdir -p of the folded spelling is the existing control directory where the
# filesystem folds it and a directory of its own where it does not; the write
# prompts either way, and never on a missing parent.
test_auto_approve_prompts_for_a_folded_control_name() {
    local meta="$CLAUDE_SESSION_META_DIR"
    _assert_falls_through Write "$meta/"$'\xc5\xbf'"ession.lock" \
        "the session lock spelled with a long s" || return 1
    mkdir -p "$meta/age-recipients"
    mkdir -p "$meta/age-recipient"$'\xc5\xbf'
    _assert_falls_through Write "$meta/age-recipient"$'\xc5\xbf'"/k.pub" \
        "a recipient key under a directory spelled with a long s" || return 1
}

# A repository kept below .cs/ (a clone under a notes directory) has a git
# directory of its own, and git reads config and runs hooks from it whenever
# git runs there. The note beside it is the control.
test_auto_approve_prompts_inside_a_git_directory_below_cs() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/artifacts/repo/.git/hooks" "$meta/memory/sub"
    _assert_falls_through Write "$meta/artifacts/repo/.git/config" \
        "the config of a repository kept below .cs" || return 1
    _assert_falls_through Write "$meta/artifacts/repo/.git/hooks/pre-commit" \
        "a hook of a repository kept below .cs" || return 1
    _assert_falls_through Write "$meta/memory/sub/.git" \
        "a .git file in a content directory" || return 1
    _assert_allowed Write "$meta/artifacts/repo/notes.md" \
        "a note beside that repository" || return 1
}

# The name is not what makes a git directory. A .git that is a link resolves
# to its target's name, and a bare clone is a git directory under a name of
# its own; both are read by git the same way.
test_auto_approve_prompts_inside_a_git_directory_reached_by_another_name() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/research/repo" "$meta/research/gitdata"
    ln -s ../gitdata "$meta/research/repo/.git"
    _assert_falls_through Write "$meta/research/repo/.git/config" \
        "the config behind a linked .git" || return 1
    mkdir -p "$meta/artifacts/mirror/objects" "$meta/artifacts/mirror/refs" "$meta/artifacts/mirror/hooks"
    echo 'ref: refs/heads/main' > "$meta/artifacts/mirror/HEAD"
    _assert_falls_through Write "$meta/artifacts/mirror/config" \
        "the config of a bare clone kept below .cs" || return 1
    _assert_falls_through Write "$meta/artifacts/mirror/hooks/pre-commit" \
        "a hook of a bare clone kept below .cs" || return 1
    _assert_allowed Write "$meta/artifacts/notes.md" \
        "a note beside the bare clone" || return 1
    # A linked worktree's own directory holds HEAD and names the shared one in
    # commondir; git reads config.worktree from it.
    mkdir -p "$meta/research/admin"
    echo 'ref: refs/heads/main' > "$meta/research/admin/HEAD"
    echo '/elsewhere/.git' > "$meta/research/admin/commondir"
    _assert_falls_through Write "$meta/research/admin/config.worktree" \
        "the config of a worktree's git directory kept below .cs" || return 1
    _assert_falls_through Write "$meta/research/admin/index" \
        "the index of a worktree's git directory kept below .cs" || return 1
}

# A git directory can be assembled one write at a time. Git takes a directory
# that holds HEAD beside objects/ and refs/, or beside a commondir naming
# another store, and then reads config and config.worktree from it; a
# worktree's own directory names its checkout in gitdir. A write of any of
# these names prompts below .cs/ whatever is there already, and in any case,
# since the Mac volume reads head as HEAD. Each file is written after its
# prompt, as an approval would, so the next name meets what the last left.
test_auto_approve_prompts_for_a_git_file_name_in_any_order() {
    local meta="$CLAUDE_SESSION_META_DIR" name
    for name in config config.worktree HEAD commondir gitdir; do
        _assert_falls_through Write "$meta/memory/$name" \
            ".cs/memory/$name written in turn" || return 1
        case "$name" in
            config|config.worktree) printf '[core]\n\tpager = echo planted\n' > "$meta/memory/$name" ;;
            HEAD) echo 'ref: refs/heads/main' > "$meta/memory/$name" ;;
            *) printf '%s\n' "$CLAUDE_SESSION_DIR/.git" > "$meta/memory/$name" ;;
        esac
        _assert_falls_through Edit "$meta/memory/$name" \
            "an Edit of .cs/memory/$name" || return 1
    done
    mkdir -p "$meta/plans"
    for name in Config CONFIG CONFIG.WORKTREE Config.Worktree head Head CommonDir \
        COMMONDIR GitDir GITDIR; do
        _assert_falls_through Write "$meta/plans/$name" \
            ".cs/plans/$name in an empty directory" || return 1
    done
    for name in config.md headers.md commondir-notes.md gitdir.txt; do
        _assert_allowed Write "$meta/plans/$name" \
            "a note named .cs/plans/$name" || return 1
    done
    # A clone delivers objects/ and refs/ with no HEAD: the config and the
    # HEAD that would make it a bare repository both prompt.
    mkdir -p "$meta/research/x/objects" "$meta/research/x/refs"
    _assert_falls_through Write "$meta/research/x/config" \
        "the config of a bare layout with no HEAD yet" || return 1
    _assert_falls_through Write "$meta/research/x/HEAD" \
        "the HEAD that completes a bare layout" || return 1
}

# A directory is a git directory to the hook by the rule cs refuses a
# session's state by: it holds HEAD. A HEAD that is a link into refs/ counts
# whether or not the link leads anywhere (git takes the directory for a
# repository either way), so does a HEAD with nothing beside it, and so does
# one at the root of .cs/ itself. A write in or below any of them prompts.
test_auto_approve_prompts_inside_any_directory_that_holds_head() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/artifacts/linked/objects" "$meta/artifacts/linked/refs" "$meta/artifacts/linked/hooks"
    ln -s refs/heads/main "$meta/artifacts/linked/HEAD"
    _assert_falls_through Write "$meta/artifacts/linked/config" \
        "the config of a layout whose HEAD is a dangling link" || return 1
    _assert_falls_through Write "$meta/artifacts/linked/hooks/pre-commit" \
        "a hook of a layout whose HEAD is a dangling link" || return 1
    _assert_allowed Write "$meta/artifacts/notes.md" \
        "a note beside that layout" || return 1
    mkdir -p "$meta/research/lone"
    echo 'ref: refs/heads/main' > "$meta/research/lone/HEAD"
    _assert_falls_through Write "$meta/research/lone/notes.md" \
        "a note in a directory holding HEAD and nothing else" || return 1
    mkdir -p "$meta/memory" "$meta/objects" "$meta/refs"
    echo 'ref: refs/heads/main' > "$meta/HEAD"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative under a .cs/ that holds HEAD" || return 1
}

# A write can make a git directory, too: a clone delivers objects/, refs/ and
# a config under .cs/memory with no HEAD (nothing there is a git directory
# yet), and a file named HEAD completes the layout. A commondir names the
# store a HEAD beside it uses. A write of either name prompts, in any case
# (the volume may fold it), and a note beside them is still approved.
test_auto_approve_prompts_for_a_file_that_makes_its_directory_a_git_directory() {
    local meta="$CLAUDE_SESSION_META_DIR" name
    mkdir -p "$meta/memory/objects" "$meta/memory/refs"
    : > "$meta/memory/objects/.keep"
    : > "$meta/memory/refs/.keep"
    printf '[core]\n\tbare = false\n\tworktree = ..\n' > "$meta/memory/config"
    for name in HEAD head Head commondir COMMONDIR; do
        _assert_falls_through Write "$meta/memory/$name" "a write of $name beside objects/ and refs/" || return 1
        _assert_falls_through Edit "$meta/memory/$name" "an Edit of $name beside objects/ and refs/" || return 1
    done
    _assert_allowed Write "$meta/memory/notes.md" "a note beside objects/ and refs/" || return 1
}

# That rule lives in the shared library (cs-shared.sh). A partial deployment
# without it cannot tell a git directory from content, so every write
# prompts, and stderr says what is missing.
test_auto_approve_declines_without_the_shared_library() {
    local partial="$TEST_TMPDIR/partial-hooks" input output err="$TEST_TMPDIR/partial-hook.err"
    mkdir -p "$partial" "$CLAUDE_SESSION_META_DIR/memory"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    rm "$partial/cs-shared.sh"
    input=$(jq -n --arg path "$CLAUDE_SESSION_META_DIR/memory/narrative.md" \
        '{tool_name: "Write", tool_input: {file_path: $path}}')
    output=$(echo "$input" | bash "$partial/session-auto-approve.sh" 2>"$err")
    assert_eq "" "$output" "a narrative write falls through to the prompt" || return 1
    assert_eq "cs auto-approve: not approving, $partial/cs-shared.sh is missing or outdated" "$(cat "$err")" \
        "the hook names the missing library" || return 1
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    assert_output_contains "$output" '"allow"' "the same write is approved with the library" || return 1
}

# The same for a session whose own path has a .git component above .cs/: the
# git-directory rule reads the path below .cs/ only.
test_auto_approve_allows_content_in_a_session_below_a_git_named_directory() {
    local home="$TEST_TMPDIR/checkout/.git"
    mkdir -p "$home"
    mv "$CLAUDE_SESSION_DIR" "$home/session"
    CLAUDE_SESSION_DIR="$home/session" CLAUDE_SESSION_META_DIR="$home/session/.cs" \
        _assert_allowed Write "$home/session/.cs/memory/narrative.md" \
        "a narrative in a session path holding a .git component" || return 1
}

# Only the part of the path below .cs/ is judged: a session that lives under
# a directory named outside ASCII keeps its content writes frictionless.
test_auto_approve_allows_ascii_content_under_a_non_ascii_session_path() {
    local home="$TEST_TMPDIR/caf"$'\xc3\xa9'
    mkdir -p "$home"
    mv "$CLAUDE_SESSION_DIR" "$home/session"
    CLAUDE_SESSION_DIR="$home/session" CLAUDE_SESSION_META_DIR="$home/session/.cs" \
        _assert_allowed Write "$home/session/.cs/memory/narrative.md" \
        "a narrative in a session path named outside ASCII" || return 1
}

# cs accepts a .cs/claude-config that is a link to any resolving directory
# and launches Claude Code with CLAUDE_CONFIG_DIR pointing there. Linked into a
# content directory, the config's real parent reads as memory/ and a write to
# either spelling would land Claude Code settings and hooks. The only
# claude-config link cs places is the one into the vault mount, so this one
# declines every write.
test_auto_approve_rejects_config_linked_into_content() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/config"
    ln -s memory/config "$meta/claude-config"
    _assert_falls_through Write "$meta/claude-config/settings.json" \
        "a setting through the config link" || return 1
    _assert_falls_through Write "$meta/memory/config/settings.json" \
        "a setting at the config link's target" || return 1
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside the linked config" \
        "$(_link_reason "$meta/claude-config")" || return 1
}

# A link beneath a control directory can point the other way, into content:
# Claude Code reads .cs/claude-config/settings.json through the link, and the
# queue drain reads .cs/local/queue through it, while the write itself lands
# in memory/ and reads as content.
test_auto_approve_rejects_settings_link_target() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/claude-config"
    printf '{}\n' > "$meta/memory/config.json"
    ln -s ../memory/config.json "$meta/claude-config/settings.json"
    local reason; reason=$(_link_reason "$(cd "$meta" && pwd -P)/claude-config/settings.json")
    _assert_falls_through Edit "$meta/memory/config.json" \
        "the target of a settings link" "$reason" || return 1
    # A planted link under a control directory declines every write, not
    # only its target: the shapes compound and none is followed.
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside the planted link" "$reason" || return 1
}

test_auto_approve_rejects_queue_link_target() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/tasks"
    ln -s ../memory/tasks "$meta/local/queue"
    local reason; reason=$(_link_reason "$(cd "$meta" && pwd -P)/local/queue")
    _assert_falls_through Write "$meta/memory/tasks/0001" \
        "a file under the target of a queue link" "$reason" || return 1
    # A planted link under a control directory declines every write, not
    # only its target: the shapes compound and none is followed.
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside the planted link" "$reason" || return 1
}

# The link under the control directory can point at another link in content,
# and the file Claude Code reads is the end of that chain.
test_auto_approve_rejects_settings_link_chain_target() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/claude-config"
    printf '{}\n' > "$meta/memory/real.json"
    ln -s real.json "$meta/memory/hop.json"
    ln -s ../memory/hop.json "$meta/claude-config/settings.json"
    _assert_falls_through Edit "$meta/memory/real.json" \
        "the end of a settings link chain" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/claude-config/settings.json")" || return 1
}

# A link inside a linked control directory: local/queue -> memory/tasks, and
# memory/tasks/0001 -> ../task.txt. The queue drain reads task.txt as a task.
test_auto_approve_rejects_link_inside_linked_control_dir() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/tasks"
    printf 'original task\n' > "$meta/memory/task.txt"
    ln -s ../memory/tasks "$meta/local/queue"
    ln -s ../task.txt "$meta/memory/tasks/0001"
    _assert_falls_through Edit "$meta/memory/task.txt" \
        "the target of a link inside a linked queue" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/local/queue")" || return 1
}

# A link name ending in a newline: $(readlink) strips it, so a hop-by-hop
# resolver would check a name that does not exist and lose the chain. The
# control directory scan follows no link, so the planted settings link
# declines the write whatever its chain spells; the scan is what this pins.
test_auto_approve_rejects_newline_link_chain() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/claude-config"
    printf '{}\n' > "$meta/memory/real.json"
    ln -s real.json "$meta/memory/hop
"
    ln -s "../memory/hop
" "$meta/claude-config/settings.json"
    # A decoy at the stripped name points outside the session, so a
    # resolver that lost the newline would call the link harmless.
    ln -s / "$meta/memory/hop"
    _assert_falls_through Edit "$meta/memory/real.json" \
        "the end of a chain through a newline-named link" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/claude-config/settings.json")" || return 1
}

# Claude Code reads the project's own .claude/ and .mcp.json from the
# session root, and both are git-shared: a link from there into .cs/
# content turns an approved content write into settings, a hook or an MCP
# server. No link there is followed: a .claude/ that links elsewhere in the
# session, even a skills directory beside it, prompts for every write.
test_auto_approve_rejects_project_claude_link_into_content() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$root/.claude" "$root/.agents/skills/x"
    printf '{}\n' > "$meta/memory/config.json"
    ln -s ../.cs/memory/config.json "$root/.claude/settings.json"
    _assert_falls_through Edit "$meta/memory/config.json" \
        "the target of a project settings link" \
        "$(_link_reason "$(cd "$root" && pwd -P)/.claude/settings.json")" || return 1
    rm "$root/.claude/settings.json"
    ln -s ../.agents/skills/x "$root/.claude/skills"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a project skills link" \
        "$(_link_reason "$(cd "$root" && pwd -P)/.claude/skills")" || return 1
}

# A hooks directory linked elsewhere in the session, whose entry links on
# into .cs/ content: reachable from .claude/ through the directory link.
test_auto_approve_rejects_project_hook_link_behind_dir_link() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$root/.claude" "$root/.agents/hooks"
    printf 'notes\n' > "$meta/memory/notes.md"
    ln -s ../.agents/hooks "$root/.claude/hooks"
    ln -s ../../.cs/memory/notes.md "$root/.agents/hooks/pre.sh"
    _assert_falls_through Edit "$meta/memory/notes.md" \
        "a hook reached through a linked directory" \
        "$(_link_reason "$(cd "$root" && pwd -P)/.claude/hooks")" || return 1
}

# .mcp.json linked at a content file that does not exist yet: the Write
# creates the file Claude Code will read as MCP servers.
test_auto_approve_rejects_mcp_link_to_new_content() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    ln -s .cs/memory/mcp.json "$root/.mcp.json"
    _assert_falls_through Write "$meta/memory/mcp.json" \
        "the dangling target of an .mcp.json link" \
        "$(_link_reason "$root/.mcp.json")" || return 1
}

# The planted link can step out of .cs/ first: claude-config/settings.json
# -> ../../hop.json at the session root (a shared project file), and hop.json
# -> .cs/memory/config.json. A parent outside .cs/ proves nothing while it is
# inside the session.
test_auto_approve_rejects_link_hopping_through_session_root() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/claude-config"
    printf '{}\n' > "$meta/memory/config.json"
    ln -s .cs/memory/config.json "$CLAUDE_SESSION_DIR/hop.json"
    ln -s ../../hop.json "$meta/claude-config/settings.json"
    _assert_falls_through Edit "$meta/memory/config.json" \
        "the end of a chain through the session root" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/claude-config/settings.json")" || return 1
}

# On a case-sensitive filesystem SESSION/ beside session/ is another
# directory; a containment check that folds case would take its .cs/ for
# ours and classify against ours, which has no claude-config to decline on.
# On a case-insensitive filesystem the mkdir would land in our own .cs/ and
# the write would decline as our own claude-config, proving nothing, so the
# test skips there (reproduced on a case-sensitive APFS image: the old
# containment approved it, the exact one is silent).
test_auto_approve_rejects_case_sibling_session() {
    mkdir -p "$TEST_TMPDIR/Probe"
    [ -d "$TEST_TMPDIR/probe" ] && return 77
    local sibling="$TEST_TMPDIR/SESSION"
    mkdir -p "$sibling/.cs/claude-config"
    _assert_falls_through Write "$sibling/.cs/claude-config/settings.json" \
        "a setting in a case-sibling session" || return 1
}

# A write whose real parent ends in a newline: $(pwd -P) strips it, so the
# hook would judge the plain directory at the stripped name while the write
# lands in the newline-named one. A real path holding a newline falls
# through. The link that reaches it sits in content, which the control
# directory scan does not walk, and the spelled path holds no newline, so the
# exact real path is all that decides.
test_auto_approve_rejects_newline_real_parent() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/store" "$meta/memory/store
"
    ln -s "store
" "$meta/memory/notes"
    _assert_allowed Write "$meta/memory/store/0001" \
        "a write in the plain directory at the stripped name" || return 1
    _assert_falls_through Write "$meta/memory/notes/0001" \
        "a write whose real parent is the newline-named directory" || return 1
}

# CLAUDE_SESSION_META_DIR may sit outside CLAUDE_SESSION_DIR; the metadata
# root is then a containment domain of its own for planted control links.
test_auto_approve_rejects_queue_link_under_separate_meta_dir() {
    export CLAUDE_SESSION_META_DIR="$TEST_TMPDIR/meta"
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/local" "$meta/memory/tasks"
    ln -s ../memory/tasks "$meta/local/queue"
    _assert_falls_through Write "$meta/memory/tasks/0001" \
        "a file under a queue link in a separate metadata root" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/local/queue")" || return 1
}

# .claude itself linked at a content directory, with no settings file yet:
# the Write creates .claude/settings.json. The parent, not a file, is what
# must match.
test_auto_approve_rejects_new_file_under_linked_claude_dir() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    ln -s .cs/memory "$root/.claude"
    _assert_falls_through Write "$meta/memory/settings.json" \
        "a new file in a directory .claude links to" \
        "$(_link_reason "$root/.claude")" || return 1
}

# A requested path that ends in a newline: $(jq -r) strips it, so the hook
# would judge the plain file at the stripped name while the Edit lands on
# the newline-named file beside it. A requested path holding a newline falls
# through. No link is planted, so neither the control directory scan nor a
# link check carries the verdict: the exact read and the newline check do.
test_auto_approve_rejects_newline_file_path() {
    local meta="$CLAUDE_SESSION_META_DIR"
    local target="$meta/memory/config.json
"
    printf '{}\n' > "$target"
    printf '{}\n' > "$meta/memory/config.json"
    _assert_allowed Edit "$meta/memory/config.json" \
        "an Edit of the plain file at the stripped name" || return 1
    _assert_falls_through Edit "$target" \
        "an Edit of the newline-named file beside it" || return 1
}

# cs keeps a CLAUDE_CONFIG_DIR the shell set when the session has no vault
# config (lib/75-launch.sh), so Claude Code's active config directory can be
# a content directory of the session. One outside the session is the user's
# own and stays out of the scan.
test_auto_approve_rejects_config_dir_inside_session() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/cfg" "$meta/plans"
    export CLAUDE_CONFIG_DIR="$meta/memory/cfg"
    _assert_falls_through Write "$meta/memory/cfg/settings.json" \
        "a setting in a CLAUDE_CONFIG_DIR inside the session" || return 1
    _assert_allowed Write "$meta/plans/plan.md" \
        "a plan beside an in-session config dir" || return 1
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/outside-config"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative with the config dir outside the session" || return 1
    unset CLAUDE_CONFIG_DIR
}

# The session's git directory relocated into content (.git -> .cs/memory/repo,
# or a .git file naming it): git reads config there, and core.fsmonitor runs.
test_auto_approve_rejects_git_dir_inside_content() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/memory/repo"
    printf '[core]\n' > "$meta/memory/repo/config"
    ln -s .cs/memory/repo "$root/.git"
    _assert_falls_through Edit "$meta/memory/repo/config" \
        "git config behind a relocated .git link" || return 1
    _assert_falls_through Write "$meta/memory/repo/description" \
        "a file in the git directory a .git link leads to" || return 1
    rm "$root/.git"
    printf 'gitdir: .cs/memory/repo\n' > "$root/.git"
    _assert_falls_through Edit "$meta/memory/repo/config" \
        "git config behind a .git file" || return 1
    _assert_falls_through Write "$meta/memory/repo/description" \
        "a file in the git directory a .git file names" || return 1
    _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative beside the relocated git dir" || return 1
}

# Audit #886: no symlink under a control directory is reasoned about. Any
# link there declines every write, wherever it points, and the hook says
# which link on stderr. The scan roots are .cs/local, .cs/age-recipients,
# .cs/private, .cs/claude-config, the project's .claude/ (and .mcp.json),
# and an in-session CLAUDE_CONFIG_DIR.
_auto_approve_stderr() {
    # $1 tool, $2 path: the hook's stderr, its stdout dropped.
    local input
    input=$(jq -n --arg tool "$1" --arg path "$2" \
        '{tool_name: $tool, tool_input: {file_path: $path}}')
    { echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh" >/dev/null; } 2>&1
}

_link_reason() {
    printf 'cs auto-approve: not approving, symlink under a control directory: %s' "$1"
}

test_auto_approve_declines_on_any_control_link() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    local outside="$TEST_TMPDIR/outside" real
    mkdir -p "$outside" "$meta/private/handoffs"
    # A link under local/ that points outside the session entirely.
    ln -s "$outside" "$meta/local/elsewhere"
    real="$(cd "$meta/local" && pwd -P)"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a link in local/ pointing outside" \
        "$(_link_reason "$real/elsewhere")" || return 1
    assert_eq "$(_link_reason "$real/elsewhere")" \
        "$(_auto_approve_stderr Write "$meta/memory/narrative.md")" \
        "the decline names the link" || return 1
    rm "$meta/local/elsewhere"
    # Nested deep under private/.
    mkdir -p "$meta/private/handoffs/a/b"
    ln -s "$outside" "$meta/private/handoffs/a/b/deep"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a nested link in private/" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/private/handoffs/a/b/deep")" || return 1
    rm "$meta/private/handoffs/a/b/deep"
    # private itself linked anywhere but the vault mount.
    mv "$meta/private" "$outside/private"
    ln -s "$outside/private" "$meta/private"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a private/ linked outside the vault" \
        "$(_link_reason "$meta/private")" || return 1
    rm "$meta/private"
    # Under the project's .claude/, deep and pointing outside.
    mkdir -p "$root/.claude/skills/x/scripts"
    ln -s "$outside" "$root/.claude/skills/x/scripts/ref"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a link in the project's .claude/" \
        "$(_link_reason "$(cd "$root" && pwd -P)/.claude/skills/x/scripts/ref")" || return 1
    rm "$root/.claude/skills/x/scripts/ref"
    # .mcp.json as a link, wherever it points.
    printf '{}\n' > "$outside/mcp.json"
    ln -s "$outside/mcp.json" "$root/.mcp.json"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a linked .mcp.json" \
        "$(_link_reason "$root/.mcp.json")" || return 1
    rm "$root/.mcp.json"
    _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative once every link is gone" || return 1
}

# The positive control for the scan: a session with no link anywhere keeps
# its content writes frictionless, and the hook says nothing on stderr.
test_auto_approve_allows_content_without_links() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/plans" "$meta/private/handoffs" "$meta/claude-config" \
        "$meta/age-recipients" "$root/.claude/skills/x"
    printf '{}\n' > "$root/.claude/settings.json"
    printf '{}\n' > "$meta/claude-config/settings.json"
    _assert_allowed Write "$meta/memory/narrative.md" "a narrative" || return 1
    _assert_allowed Write "$meta/plans/plan.md" "a plan" || return 1
    _assert_allowed Write "$meta/private/handoffs/2026-01-01-x.md" \
        "a handoff in private/" || return 1
    assert_eq "" "$(_auto_approve_stderr Write "$meta/memory/narrative.md")" \
        "an approval says nothing on stderr" || return 1
}

# A clone chooses the name of a link it commits under the project's .claude/,
# and the name can carry a terminal escape: a raw ESC or BEL byte, or
# backslash text echo -e would turn into one. The decline names the link as a
# plain path, each character a plain path lacks replaced by _.
test_auto_approve_names_a_control_link_as_a_plain_path() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR" err real
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    mkdir -p "$root/.claude/skills"
    ln -s "$TEST_TMPDIR/outside" "$root/.claude/skills/link$bad"
    real="$(cd "$root/.claude/skills" && pwd -P)"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a link in the project's .claude/" \
        "$(_link_reason "$real/link$shown")" || return 1
    err=$(_auto_approve_stderr Write "$meta/memory/narrative.md")
    assert_eq "$(_link_reason "$real/link$shown")" "$err" \
        "the decline names the link as a plain path" || return 1
    assert_no_escape_bytes "$err" "no escape byte reaches the terminal" || return 1
}

# cs links the shell's shared config names into .cs/claude-config
# (lib/75-launch.sh _link_shared_claude_config). Those links, by those names
# and pointing where cs points them, are the only ones allowed there.
_make_shared_config_links() {
    # $1 the claude-config directory, $2 the shell config dir
    local name
    mkdir -p "$2/rules" "$2/skills" "$2/plugins"
    printf '{}\n' > "$2/settings.json"
    printf '# shared\n' > "$2/CLAUDE.md"
    for name in settings.json CLAUDE.md rules skills plugins; do
        ln -s "$2/$name" "$1/$name"
    done
}

test_auto_approve_allows_cs_shared_config_links() {
    local meta="$CLAUDE_SESSION_META_DIR" home="$TEST_TMPDIR/home" name
    mkdir -p "$meta/claude-config/projects"
    _make_shared_config_links "$meta/claude-config" "$home/.claude"
    HOME="$home" _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative beside cs's own config links" || return 1
    # A shell that ran with its own CLAUDE_CONFIG_DIR: cs linked from there,
    # and the launch keeps it in CLAUDE_SECURESTORAGE_CONFIG_DIR.
    for name in settings.json CLAUDE.md rules skills plugins; do
        rm "$meta/claude-config/$name"
    done
    _make_shared_config_links "$meta/claude-config" "$TEST_TMPDIR/shell-config"
    HOME="$home" CLAUDE_SECURESTORAGE_CONFIG_DIR="$TEST_TMPDIR/shell-config" \
        _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative beside config links into the shell's own config dir" || return 1
}

test_auto_approve_rejects_foreign_config_link() {
    local meta="$CLAUDE_SESSION_META_DIR" home="$TEST_TMPDIR/home"
    mkdir -p "$meta/claude-config"
    _make_shared_config_links "$meta/claude-config" "$home/.claude"
    # A name cs never links, pointing into the shell config like the rest.
    printf '{}\n' > "$home/.claude/extra.json"
    ln -s "$home/.claude/extra.json" "$meta/claude-config/extra.json"
    local config; config="$(cd "$meta/claude-config" && pwd -P)"
    HOME="$home" _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a foreign-named config link" \
        "$(_link_reason "$config/extra.json")" || return 1
    rm "$meta/claude-config/extra.json"
    # A shared name pointing somewhere cs does not point it.
    printf '{}\n' > "$TEST_TMPDIR/other.json"
    rm "$meta/claude-config/settings.json"
    ln -s "$TEST_TMPDIR/other.json" "$meta/claude-config/settings.json"
    HOME="$home" _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a settings link cs did not make" \
        "$(_link_reason "$config/settings.json")" || return 1
    rm "$meta/claude-config/settings.json"
    ln -s "$home/.claude/settings.json" "$meta/claude-config/settings.json"
    # A shared name one level down is not where cs puts it.
    mkdir -p "$meta/claude-config/sub"
    ln -s "$home/.claude/rules" "$meta/claude-config/sub/rules"
    HOME="$home" _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a shared name below the config root" \
        "$(_link_reason "$config/sub/rules")" || return 1
    rm -r "$meta/claude-config/sub"
    HOME="$home" _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative once only cs's links remain" || return 1
}

# An encrypted session (lib/63-encrypt.sh): memory, plans, claude-config and
# private are links into .cs/vault-mnt by design (CS_VAULT_LINKS), and the
# config dir's shared names link out to the shell config. Content writes
# there must stay frictionless: the scan follows only the root links cs
# places, then looks inside the vault directories they name.
_make_vaulted_meta() {
    # $1 the metadata root, $2 the shell config dir
    local meta="$1" sub
    mkdir -p "$meta/vault-mnt/private/handoffs" "$meta/vault-mnt/claude-config/projects" \
        "$meta/vault-mnt/plans"
    mv "$meta/memory" "$meta/vault-mnt/memory"
    for sub in memory plans claude-config private; do
        ln -s "vault-mnt/$sub" "$meta/$sub"
    done
    _make_shared_config_links "$meta/vault-mnt/claude-config" "$2"
}

test_auto_approve_allows_vaulted_session_content() {
    local meta="$CLAUDE_SESSION_META_DIR" home="$TEST_TMPDIR/home"
    _make_vaulted_meta "$meta" "$home/.claude"
    HOME="$home" CLAUDE_CONFIG_DIR="$meta/claude-config" \
        _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative in an encrypted session" || return 1
    HOME="$home" CLAUDE_CONFIG_DIR="$meta/claude-config" \
        _assert_allowed Write "$meta/plans/plan.md" \
        "a plan in an encrypted session" || return 1
    HOME="$home" CLAUDE_CONFIG_DIR="$meta/claude-config" \
        _assert_allowed Write "$meta/private/handoffs/2026-01-01-x.md" \
        "a handoff in an encrypted session" || return 1
    HOME="$home" CLAUDE_CONFIG_DIR="$meta/claude-config" \
        _assert_falls_through Write "$meta/claude-config/settings.local.json" \
        "a setting in an encrypted session" || return 1
    # A planted link inside the vault's private/ still declines.
    ln -s "$TEST_TMPDIR" "$meta/vault-mnt/private/handoffs/planted"
    HOME="$home" CLAUDE_CONFIG_DIR="$meta/claude-config" \
        _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a link planted inside the vault" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/vault-mnt/private/handoffs/planted")" || return 1
}

# `claude --worktree` keeps whole checkouts under the project's
# .claude/worktrees/, links and all, and Claude Code does not read them as
# this session's config: only that one directory is skipped. A worktrees/
# deeper down is scanned like the rest, and so is a session directory whose
# path holds find's pattern characters.
test_auto_approve_skips_project_worktrees_only() {
    local root="$CLAUDE_SESSION_DIR" meta="$CLAUDE_SESSION_META_DIR"
    local outside="$TEST_TMPDIR/outside"
    mkdir -p "$outside" "$root/.claude/worktrees/w" "$root/.claude/skills/x/worktrees"
    ln -s "$outside" "$root/.claude/worktrees/w/committed-link"
    _assert_allowed Write "$meta/memory/narrative.md" \
        "a narrative beside a link inside a claude worktree" || return 1
    ln -s "$outside" "$root/.claude/skills/x/worktrees/planted"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside a link under a nested worktrees/" \
        "$(_link_reason "$(cd "$root" && pwd -P)/.claude/skills/x/worktrees/planted")" || return 1
    rm "$root/.claude/skills/x/worktrees/planted"
    local odd="$TEST_TMPDIR/odd [x]*"
    mkdir -p "$odd"
    mv "$root" "$odd/session"
    CLAUDE_SESSION_DIR="$odd/session" CLAUDE_SESSION_META_DIR="$odd/session/.cs" \
        _assert_allowed Write "$odd/session/.cs/memory/narrative.md" \
        "a narrative in a session path holding [ ] *" || return 1
}

# Claude Code itself keeps a debug/latest link in its config dir when it
# logs to a file. In an encrypted session that dir is .cs/claude-config, and
# the strict rule declines on it like any other foreign link.
test_auto_approve_declines_on_config_debug_link() {
    local meta="$CLAUDE_SESSION_META_DIR"
    mkdir -p "$meta/claude-config/debug"
    printf 'log\n' > "$meta/claude-config/debug/x.txt"
    ln -s "$meta/claude-config/debug/x.txt" "$meta/claude-config/debug/latest"
    _assert_falls_through Write "$meta/memory/narrative.md" \
        "a narrative beside Claude Code's debug/latest link" \
        "$(_link_reason "$(cd "$meta" && pwd -P)/claude-config/debug/latest")" || return 1
}

test_auto_approve_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Write","tool_input":{"file_path":"/tmp/anything.md"}}'

    local output
    output=$(echo "$input" | bash "$HOOKS_DIR/session-auto-approve.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# subagent-context.sh
# ============================================================================

test_subagent_context_deliverable_is_final_message() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_not_contains "$output" "Document findings in .cs/memory/narrative.md" \
        "a subagent's deliverable is its final message, not a shared narrative file" || return 1
    assert_output_contains "$output" "final message" \
        "subagent context must tell the subagent its final message is the deliverable" || return 1
}

test_subagent_context_points_to_secret_store() {
    # The secrets rule must give the subagent the right action (store it), not
    # just ban the wrong one — otherwise a subagent that meets a credential
    # improvises instead of using the session secret store.
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "cs -secrets set" \
        "the secrets rule must point the subagent at the session secret store" || return 1
}

test_subagent_injects_session_name() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_NAME" \
        "Should include session name" || return 1
}

test_subagent_injects_session_dir() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    assert_output_contains "$output" "$CLAUDE_SESSION_DIR" \
        "Should include session directory" || return 1
}

test_subagent_returns_valid_json() {
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null 2>&1; then
        echo "  FAIL: Output should have hookSpecificOutput.additionalContext"
        echo "  Output: $output"
        return 1
    fi
}

test_subagent_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/subagent-context.sh")
    if [[ -n "$output" ]]; then
        echo "  FAIL: Should produce no output outside session, got: $output"
        return 1
    fi
}

# ============================================================================
# tool-failure-logger.sh
# ============================================================================

test_failure_logged_to_session_log() {
    local input='{"tool_name":"Bash","error":"Command failed with exit code 1"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" \
        "Should log tool name" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Command failed" \
        "Should log error message" || return 1
}

test_failure_log_has_timestamp() {
    local input='{"tool_name":"Write","error":"Permission denied"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$CLAUDE_SESSION_META_DIR/local/session.log" || {
        echo "  FAIL: Log should have timestamp"
        return 1
    }
}

test_failure_truncates_long_errors() {
    local long_error
    long_error=$(python3 -c "print('x' * 500)")
    local input
    input=$(jq -n --arg err "$long_error" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    local log_line
    log_line=$(grep "Tool failure" "$CLAUDE_SESSION_META_DIR/local/session.log" | head -1)
    local line_len=${#log_line}
    if [[ "$line_len" -gt 280 ]]; then
        echo "  FAIL: Log line should be truncated ($line_len chars)"
        return 1
    fi
}

test_failure_handles_huge_multiline_error() {
    # A large multi-line error (long stack trace) must be logged without crashing
    # the hook: its `echo "$err" | head -1 | cut` truncation SIGPIPEs on >64KB and
    # is guarded by `|| true`. Feed jq via --rawfile, NOT --arg — a ~250KB value on
    # jq's command line exceeds Linux's per-arg limit (MAX_ARG_STRLEN, 128KB) and
    # dies with "Argument list too long" before the hook ever runs.
    local errfile="$TEST_TMPDIR/huge_err.txt"
    python3 -c "print('\n'.join(['x' * 500 for _ in range(500)]))" > "$errfile"
    local input
    input=$(jq -n --rawfile err "$errfile" '{tool_name: "Bash", error: $err}')
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Bash" \
        "Should log huge multi-line error without crashing" || return 1
}

test_failure_skips_outside_session() {
    unset CLAUDE_SESSION_NAME
    local input='{"tool_name":"Bash","error":"fail"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    # Should exit cleanly without writing anything
    if [[ -s "$CLAUDE_SESSION_META_DIR/local/session.log" ]]; then
        local content
        content=$(cat "$CLAUDE_SESSION_META_DIR/local/session.log")
        if [[ -n "$content" ]]; then
            echo "  FAIL: Should not log outside session"
            return 1
        fi
    fi
}

test_failure_handles_missing_error() {
    local input='{"tool_name":"Read"}'
    echo "$input" | bash "$HOOKS_DIR/tool-failure-logger.sh"
    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Tool failure: Read" \
        "Should handle missing error field" || return 1
}

# ============================================================================
# session-start.sh: cross-session context
# ============================================================================

# Setup for session-start tests needs CS_SESSIONS_ROOT with sibling sessions
session_start_setup() {
    setup
    # Isolate from an ambient CS_FRESH_REBIND (set when the suite runs from inside
    # a freshly-rebound cs session); the positive test re-supplies it inline.
    # CS_RESOLVED_FROM=walk is what a tmux teammate inherits; it empties the
    # publish target and fails the cs-launch contract test from inside a team.
    unset CS_FRESH_REBIND CS_RESOLVED_FROM 2>/dev/null || true
    # Model a cs-launched lead: the hook rebinds the recorded conversation only
    # when the claude firing it is the process cs exec'd into. Tests that model
    # a child claude or a walked-in front end override CLAUDE_PID inline.
    export CS_LEAD_PID=$$
    export CLAUDE_PID=$$
    # The launch is this cs's, which takes the lead's claim, so a child claude
    # cs's resume arm runs is the lead once its SessionStart claims.
    export CS_LEAD_CLAIM=1
    # test_lib scopes TMUX and the title device at source time; the title
    # tests read the escape from a file of their own.
    export CS_TITLE_TTY="$TEST_TMPDIR/title-tty"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session lives inside SESSIONS_ROOT
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{local,memory}
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"

    # Initialize git so the dynamic context block runs. .cs/local stays out of
    # the commit, as in every session cs makes: hooks act on no file git
    # tracks there.
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > README.md && printf '.cs/local/\n' > .gitignore && git add -A && git commit -q -m init)

    # Create README with frontmatter and placeholder objective
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: []
aliases: ["current-session"]
---
# Session: current-session

## Objective

Current session objective
EOF
}

session_start_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
    export CS_TITLE_TTY="$HOME/title-tty"
}

# While git tracks a file in a session's control directory (a pull brought it
# in), the hooks read no queue, mail or rotation there, and SessionStart writes
# nothing there either: no state line, no context date, no lock, no attention
# drop. Every change it made would be a change to the repository's files.
test_session_start_writes_nothing_into_a_control_directory_git_tracks() {
    session_start_setup
    local m="$CLAUDE_SESSION_META_DIR/local" rc source changed
    printf 'attended\n' > "$m/attention"
    printf 'session_name: current-session\n' > "$m/state"
    mkdir -p "$m/rotation-kick"
    printf 'pending\n' > "$m/rotation-kick/delivered"
    git -C "$CLAUDE_SESSION_DIR" add -f .cs/local
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "ship the control directory"
    # A resume advances the digest watermark and a lead's /clear spends a kick
    # left in flight; each source has writes of its own.
    for source in startup resume clear; do
        rc=0
        echo '{"session_id":"0b7c6a52-5d1e-4c3f-9a8b-1c2d3e4f5a6b","source":"'"$source"'","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
            | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>"$TEST_TMPDIR/ss.err" || rc=$?
        assert_eq "0" "$rc" "SessionStart ($source) stands down, it does not fail: $(cat "$TEST_TMPDIR/ss.err")" || return 1
        changed=$(git -C "$CLAUDE_SESSION_DIR" status --porcelain --ignored -- .cs/local)
        assert_eq "" "$changed" "SessionStart ($source) adds, changes or removes nothing under the tracked .cs/local" || return 1
    done
}

# The status line cannot ask git on every render, so each hook run leaves its
# answer where a render reads it with a builtin test: a mark under
# ~/.cache/cs/tracked named after the session, there while git tracks the
# control files and gone once they are untracked and committed.
test_hooks_mark_the_session_while_git_tracks_its_control_files() {
    session_start_setup
    local mark="$HOME/.cache/cs/tracked/$CLAUDE_SESSION_NAME"
    local input='{"session_id":"0b7c6a52-5d1e-4c3f-9a8b-1c2d3e4f5a6b","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}'
    printf 'session_name: current-session\n' > "$CLAUDE_SESSION_META_DIR/local/state"
    git -C "$CLAUDE_SESSION_DIR" add -f .cs/local/state
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "ship the control directory"
    echo "$input" | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    assert_file_exists "$mark" "a hook run marks the session while git tracks its control files" || return 1
    git -C "$CLAUDE_SESSION_DIR" rm -q --cached .cs/local/state
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "untrack the control directory"
    echo "$input" | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    assert_file_not_exists "$mark" "the next run drops the mark once they are untracked" || return 1
}

# A tmux stub on PATH that records every call's argv, one bracketed word per
# argument so a title split at its space is distinguishable from one passed
# whole. Sets FAKE_TMUX_PATH and FAKE_TMUX_CALLS.
_fake_tmux() {
    FAKE_TMUX_PATH="$TEST_TMPDIR/tmuxbin"
    FAKE_TMUX_CALLS="$TEST_TMPDIR/tmux-calls"
    mkdir -p "$FAKE_TMUX_PATH"
    cat > "$FAKE_TMUX_PATH/tmux" <<EOF
#!/bin/sh
{ printf '[%s]' "\$@"; echo; } >> "$FAKE_TMUX_CALLS"
exit 0
EOF
    chmod +x "$FAKE_TMUX_PATH/tmux"
    : > "$FAKE_TMUX_CALLS"
}

# cs sets the tab title once at launch and never resets it: its EXIT trap is
# unreachable because cs execs into claude. A nested launch on the same tty
# (`cs other` from the `!` prefix) therefore leaves "cs: other" on this
# session's tab for good. Every conversation start re-asserts the title, and
# on `clear` too: that is the first start after a nested launch.
# Every suite that runs the hook inherits the developer's TMUX, and the hook
# renames that window to the fixture's name; outside tmux it paints the tab.
# test_lib scopes both at source time, so no suite has to remember to.
test_test_lib_drops_an_inherited_tmux_and_routes_the_title_to_a_file() {
    local seen
    seen=$(TMUX="/tmp/tmux-1000/default,1234,0" TMUX_PANE="%7" bash -c 'SCRIPT_DIR="$(dirname "$1")"; source "$1" >/dev/null 2>&1; printf "%s|%s|%s" "${TMUX:-unset}" "${TMUX_PANE:-unset}" "${CS_TITLE_TTY:-unset}"' _ "$SCRIPT_DIR/test_lib.sh")
    assert_eq "unset|unset" "${seen%|*}" "test_lib must unset an inherited TMUX and TMUX_PANE" || return 1
    case "${seen##*|}" in
        unset|/dev/tty) echo "  FAIL: CS_TITLE_TTY must point at a scratch file, got '${seen##*|}'"; return 1 ;;
    esac
}

# A session-start test points CS_TITLE_TTY at its own fixture; its teardown
# must hand the scratch file back, or every later hook run in the suite
# reaches the terminal again.
test_session_start_teardown_keeps_the_title_off_the_terminal() {
    session_start_setup
    session_start_teardown
    case "${CS_TITLE_TTY:-unset}" in
        unset|/dev/tty) echo "  FAIL: CS_TITLE_TTY must still point at a scratch file after teardown, got '${CS_TITLE_TTY:-unset}'"; return 1 ;;
    esac
}

test_session_start_reasserts_tab_title_through_tmux() {
    session_start_setup
    _fake_tmux
    echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | PATH="$FAKE_TMUX_PATH:$PATH" TMUX="/tmp/tmux-1000/default,1234,0" TMUX_PANE="%3" \
          bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    assert_file_contains "$FAKE_TMUX_CALLS" "^\[select-pane\]\[-t\]\[%3\]\[-T\]\[cs: current-session\]$" \
        "the pane title is re-asserted on the hook's own pane, as one argument" || return 1
    # The window name itself is composed from every pane's claim; the real-tmux
    # tests below read it back. Here: the claim is this pane's, the name whole.
    assert_file_contains "$FAKE_TMUX_CALLS" "^\[set-option\]\[-p\]\[-t\]\[%3\]\[@cs_session\]\[current-session\]$" \
        "the pane claims its session, as one argument, so the window can be named after it" || return 1
    assert_file_not_exists "$CS_TITLE_TTY" \
        "under tmux the server carries the title; no escape is written to a tty" || return 1
}

# Two cs sessions in two panes of one tmux window share one window name, which
# is the tab's title under iTerm's tmux integration. Each pane records the
# session it runs; the window is named after all of them, in pane order. Real
# tmux on a private socket, so the developer's server is never touched.
_real_tmux_window() {
    require_tool tmux || return $?
    TT_SOCK="$TEST_TMPDIR/tt.sock"
    TT_PANE_A=$(tmux -S "$TT_SOCK" -f /dev/null new-session -d -P -F '#{pane_id}' -x 120 -y 30 'sleep 600') || return 1
    TT_PANE_B=$(tmux -S "$TT_SOCK" split-window -d -h -P -F '#{pane_id}' -t "$TT_PANE_A" 'sleep 600') || return 1
}
_tt() { tmux -S "$TT_SOCK" "$@"; }
_tt_window_name() { _tt display-message -p -t "$TT_PANE_A" '#{window_name}'; }
_tt_hook() {  # hook, pane, session name, source
    echo '{"session_id":"s","source":"'"$4"'","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"x"}' \
        | TMUX="$TT_SOCK,1,0" TMUX_PANE="$2" CLAUDE_SESSION_NAME="$3" \
          bash "$HOOKS_DIR/$1" >/dev/null 2>&1
}

test_two_cs_sessions_in_one_window_name_it_after_both() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt_window_name)" "one session names the window alone" || { _tt kill-server; return 1; }
    _tt_hook session-start.sh "$TT_PANE_B" fignity startup || { _tt kill-server; return 1; }
    assert_eq "cs: current-session | fignity" "$(_tt_window_name)" \
        "a second session in the same window joins the name, in pane order" || { _tt kill-server; return 1; }
    # A /clear restarts a conversation in its pane: the name does not repeat.
    _tt_hook session-start.sh "$TT_PANE_A" current-session clear || { _tt kill-server; return 1; }
    assert_eq "cs: current-session | fignity" "$(_tt_window_name)" \
        "a session re-asserting its own pane is listed once" || { _tt kill-server; return 1; }
    _tt kill-server
}

# The window name lists every cs session in the window; each pane's own title
# (its bar under iTerm's tmux integration) names only the session it runs.
test_each_pane_is_titled_with_its_own_session_alone() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    _tt_hook session-start.sh "$TT_PANE_B" fignity startup || { _tt kill-server; return 1; }
    assert_eq "cs: current-session | fignity" "$(_tt_window_name)" \
        "the window lists both sessions" || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt display-message -p -t "$TT_PANE_A" '#{pane_title}')" \
        "the first pane keeps its own session alone" || { _tt kill-server; return 1; }
    assert_eq "cs: fignity" "$(_tt display-message -p -t "$TT_PANE_B" '#{pane_title}')" \
        "the second pane keeps its own session alone" || { _tt kill-server; return 1; }
    _tt_hook session-end.sh "$TT_PANE_B" fignity user_exit || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt display-message -p -t "$TT_PANE_A" '#{pane_title}')" \
        "a session ending elsewhere leaves this pane's title alone" || { _tt kill-server; return 1; }
    _tt kill-server
}

# Under iTerm's tmux integration the tab shows a title iTerm holds, which tmux
# window renames never reach; only iTerm's Python API sets it. Every claim and
# release hands the window to hooks/cs-iterm-tab.py in the background, and only
# when the terminal is iTerm2 and CS_NO_ITERM2 is unset. A stand-in python3
# records its call, then stays up until the test releases it and fails loudly:
# the hook must return without waiting on it and carry none of its output.
# Whether the hook waited is read from the stand-in, never from the clock: a
# loaded machine makes the hook itself slow, and a time limit then fails a
# hook that waited on nothing.
_fake_tab_python() {
    FAKE_PY_PATH="$TEST_TMPDIR/pybin"
    FAKE_PY_CALLS="$TEST_TMPDIR/py-calls"
    FAKE_PY_RELEASE="$TEST_TMPDIR/py-release"
    FAKE_PY_DONE="$TEST_TMPDIR/py-done"
    mkdir -p "$FAKE_PY_PATH"
    cat > "$FAKE_PY_PATH/python3" <<EOF
#!/bin/sh
{ printf '[%s]' "\$@"; printf '[%s]\n' "\$TMUX"; } >> "$FAKE_PY_CALLS"
echo "stand-in python3 failing on purpose" >&2
i=0
while [ ! -e "$FAKE_PY_RELEASE" ] && [ -d "$FAKE_PY_PATH" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
[ -d "$FAKE_PY_PATH" ] && : > "$FAKE_PY_DONE"
exit 1
EOF
    chmod +x "$FAKE_PY_PATH/python3"
}
_tt_tab_hook() {  # hook, pane, session name, LC_TERMINAL, CS_NO_ITERM2; prints the hook's output
    echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"x"}' \
        | env -u CS_NO_ITERM2 ${5:+CS_NO_ITERM2="$5"} PATH="$FAKE_PY_PATH:$PATH" CS_HOOKS_DIR="$HOOKS_DIR" \
          TMUX="$TT_SOCK,1,0" TMUX_PANE="$2" CLAUDE_SESSION_NAME="$3" LC_TERMINAL="$4" \
          bash "$HOOKS_DIR/$1" 2>&1
}
# The tab helper starts in the background, and a loaded machine can start it
# seconds after the hook returns, so each test waits on its record through
# wait_until (test_lib), whose 120 s guard only stops a hang.

test_a_claim_in_iterm_hands_the_window_to_the_tab_helper() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_tab_python
    local window out rc
    window=$(_tt display-message -p -t "$TT_PANE_A" '#{window_id}')
    out=$(_tt_tab_hook session-start.sh "$TT_PANE_A" current-session iTerm2 ""); rc=$?
    assert_eq "0" "$rc" "the hook succeeds while the helper fails" || { _tt kill-server; return 1; }
    assert_eq "still running" "$([ -e "$FAKE_PY_DONE" ] && echo finished || echo "still running")" \
        "the hook returns while the helper it started still runs" || { _tt kill-server; return 1; }
    wait_until test -s "$FAKE_PY_CALLS"
    : > "$FAKE_PY_RELEASE"
    assert_eq "[$HOOKS_DIR/cs-iterm-tab.py][$window][$TT_SOCK,1,0]" "$(cat "$FAKE_PY_CALLS" 2>/dev/null)" \
        "a claim runs the tab helper once on its window, on the same tmux server" || { _tt kill-server; return 1; }
    assert_output_not_contains "$out" "stand-in python3" \
        "the helper's output never reaches the hook's" || { _tt kill-server; return 1; }
    : > "$FAKE_PY_CALLS"
    _tt_tab_hook session-end.sh "$TT_PANE_A" current-session iTerm2 "" >/dev/null
    wait_until test -s "$FAKE_PY_CALLS"
    assert_eq "[$HOOKS_DIR/cs-iterm-tab.py][$window][$TT_SOCK,1,0]" "$(cat "$FAKE_PY_CALLS" 2>/dev/null)" \
        "a release runs it too, so the tab drops the session that left" || { _tt kill-server; return 1; }
    _tt kill-server
}

# The helper itself, against real tmux on the private socket and a stand-in
# for the iterm2 module (iTerm cannot run here). iTerm is attached to two tmux
# servers: "here" answers for the test server through the real tmux, "there"
# for some other server. FAKE_ITERM_TABS lists the tabs iTerm would report, as
# attachment and window number. Setting a title logs "<tab> <title>" to
# FAKE_ITERM_LOG and renames the tmux window, as iTerm does (measured);
# FAKE_ITERM_ON_SET runs once, after the first set, to land a claim mid-run.
_fake_iterm_module() {
    require_tool python3 || return $?
    FAKE_ITERM_DIR="$TEST_TMPDIR/fake-iterm"
    FAKE_ITERM_LOG="$TEST_TMPDIR/iterm-titles"
    mkdir -p "$FAKE_ITERM_DIR/iterm2"
    cat > "$FAKE_ITERM_DIR/iterm2/__init__.py" <<'EOF'
import asyncio, json, os, subprocess

class _Attachment:
    def __init__(self, connection_id, ours):
        self.connection_id = connection_id
        self._ours = ours
    async def async_send_command(self, command):
        if not self._ours:
            return "99999 /elsewhere/tmux.sock\n"
        return subprocess.run(["sh", "-c", "tmux " + command], capture_output=True, text=True, check=True).stdout

class _Tab:
    def __init__(self, index, spec):
        self.tab_id = str(index)
        self.tmux_connection_id = spec["conn"]
        self.tmux_window_id = spec["window"]
    async def async_set_title(self, title):
        with open(os.environ["FAKE_ITERM_LOG"], "a") as log:
            log.write(f"{self.tab_id} {title}\n")
        subprocess.run(["tmux", "rename-window", "-t", "@" + self.tmux_window_id, title], check=True)
        hook = os.environ.pop("FAKE_ITERM_ON_SET", "")
        if hook:
            subprocess.run(["sh", "-c", hook], check=True)

class _Window:
    def __init__(self, tabs):
        self.tabs = tabs

class _App:
    def __init__(self):
        specs = json.loads(os.environ["FAKE_ITERM_TABS"])
        self.terminal_windows = [_Window([_Tab(i, s) for i, s in enumerate(specs)])]

async def async_get_tmux_connections(connection):
    return [_Attachment("there", False), _Attachment("here", True)]

async def async_get_app(connection):
    return _App()

def run_until_complete(coro):
    asyncio.run(coro(None))
EOF
}
_run_tab_helper() {  # tabs json, window id
    TMUX="$TT_SOCK,1,0" PYTHONPATH="$FAKE_ITERM_DIR" FAKE_ITERM_LOG="$FAKE_ITERM_LOG" FAKE_ITERM_TABS="$1" \
        python3 "$HOOKS_DIR/cs-iterm-tab.py" "$2"
}
_tt_num() { _tt display-message -p -t "$TT_PANE_A" "$1" | tr -d '@%'; }

test_the_tab_helper_titles_the_one_tab_showing_the_window() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_iterm_module || { local rc=$?; _tt kill-server; return $rc; }
    local w
    w=$(_tt_num '#{window_id}')
    _tt set-option -p -t "$TT_PANE_A" @cs_session current-session
    _tt set-option -p -t "$TT_PANE_B" @cs_session fignity
    _run_tab_helper "[{\"conn\": \"there\", \"window\": \"$w\"}, {\"conn\": \"here\", \"window\": \"$w\"}]" "@$w" \
        || { _tt kill-server; return 1; }
    assert_eq "1 cs: current-session | fignity" "$(cat "$FAKE_ITERM_LOG" 2>/dev/null)" \
        "the tab showing this server's window gets every session, in pane order; the same window number on another server is untouched" \
        || { _tt kill-server; return 1; }
    _tt kill-server
}

# Window numbers are per tmux server, and iTerm can attach several: a tab is
# the window's only when its attachment answers for this server, and only when
# no other tab also qualifies.
test_the_tab_helper_leaves_an_unsure_match_alone() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_iterm_module || { local rc=$?; _tt kill-server; return $rc; }
    local w
    w=$(_tt_num '#{window_id}')
    _tt set-option -p -t "$TT_PANE_A" @cs_session current-session
    _run_tab_helper "[{\"conn\": \"there\", \"window\": \"$w\"}]" "@$w" || { _tt kill-server; return 1; }
    _run_tab_helper "[{\"conn\": \"here\", \"window\": \"$w\"}, {\"conn\": \"here\", \"window\": \"$w\"}]" "@$w" \
        || { _tt kill-server; return 1; }
    assert_file_not_exists "$FAKE_ITERM_LOG" \
        "a tab on another server, or two tabs that both match, get no title" || { _tt kill-server; return 1; }
    _tt kill-server
}

# An empty title clears iTerm's and renames the tmux window to nothing, so a
# window with no cs session left gets no title at all.
test_the_tab_helper_never_sets_an_empty_title() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_iterm_module || { local rc=$?; _tt kill-server; return $rc; }
    local w
    w=$(_tt_num '#{window_id}')
    _run_tab_helper "[{\"conn\": \"here\", \"window\": \"$w\"}]" "@$w" || { _tt kill-server; return 1; }
    assert_file_not_exists "$FAKE_ITERM_LOG" "no claim, no title" || { _tt kill-server; return 1; }
    _tt kill-server
}

# Two claims race: the helper of the first may set its title after the second
# claim landed. Setting the title renames the tmux window too, so a stale set
# would drop the newer session from both. The helper re-reads the claims after
# each set and sets again until they agree.
test_the_tab_helper_sets_again_when_a_claim_lands_mid_run() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_iterm_module || { local rc=$?; _tt kill-server; return $rc; }
    local w
    w=$(_tt_num '#{window_id}')
    _tt set-option -p -t "$TT_PANE_A" @cs_session current-session
    FAKE_ITERM_ON_SET="tmux -S '$TT_SOCK' set-option -p -t '$TT_PANE_B' @cs_session late" \
        _run_tab_helper "[{\"conn\": \"here\", \"window\": \"$w\"}]" "@$w" || { _tt kill-server; return 1; }
    assert_eq "0 cs: current-session
0 cs: current-session | late" "$(cat "$FAKE_ITERM_LOG" 2>/dev/null)" \
        "the stale title is followed by the one the claims now make" || { _tt kill-server; return 1; }
    assert_eq "cs: current-session | late" "$(_tt_window_name)" \
        "and the window name the last set left agrees" || { _tt kill-server; return 1; }
    _tt kill-server
}

# The last claim leaves while the helper sets a title: the release already
# handed the window back (automatic-rename on), and the set's rename turned it
# off again with a name no session holds. The helper hands it back once more.
test_the_tab_helper_hands_the_window_back_when_the_last_claim_leaves_mid_run() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_iterm_module || { local rc=$?; _tt kill-server; return $rc; }
    local w
    w=$(_tt_num '#{window_id}')
    _tt set-option -p -t "$TT_PANE_A" @cs_session current-session
    FAKE_ITERM_ON_SET="tmux -S '$TT_SOCK' set-option -p -u -t '$TT_PANE_A' @cs_session" \
        _run_tab_helper "[{\"conn\": \"here\", \"window\": \"$w\"}]" "@$w" || { _tt kill-server; return 1; }
    assert_eq "0 cs: current-session" "$(cat "$FAKE_ITERM_LOG" 2>/dev/null)" \
        "one title was set before the claim left" || { _tt kill-server; return 1; }
    assert_eq "on" "$(_tt show-window-options -v -t "$TT_PANE_A" automatic-rename)" \
        "the window names itself again" || { _tt kill-server; return 1; }
    assert_eq "on" "$(_tt show-window-options -v -t "$TT_PANE_A" allow-rename)" \
        "and programs may rename it again" || { _tt kill-server; return 1; }
    _tt kill-server
}

test_a_claim_outside_iterm_runs_no_tab_helper() {
    session_start_setup
    _real_tmux_window || return $?
    _fake_tab_python
    _tt_tab_hook session-start.sh "$TT_PANE_A" current-session "" "" >/dev/null
    _tt_tab_hook session-start.sh "$TT_PANE_B" fignity iTerm2 1 >/dev/null
    # Positive control on the same server: an iTerm2 claim does run it.
    _tt_tab_hook session-start.sh "$TT_PANE_A" current-session iTerm2 "" >/dev/null
    wait_until test -s "$FAKE_PY_CALLS"
    assert_eq "1" "$(cat "$FAKE_PY_CALLS" 2>/dev/null | wc -l | tr -d ' ')" \
        "neither a terminal other than iTerm2 nor CS_NO_ITERM2 runs the helper; the control does" || { _tt kill-server; return 1; }
    _tt kill-server
}

test_a_session_ending_leaves_the_window_to_the_others() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    _tt_hook session-start.sh "$TT_PANE_B" fignity startup
    _tt_hook session-end.sh "$TT_PANE_A" current-session user_exit || { _tt kill-server; return 1; }
    assert_eq "cs: fignity" "$(_tt_window_name)" \
        "the session that ended leaves the name; the other keeps it" || { _tt kill-server; return 1; }
    _tt_hook session-end.sh "$TT_PANE_B" fignity user_exit || { _tt kill-server; return 1; }
    assert_eq "on" "$(_tt show-window-options -v -t "$TT_PANE_A" automatic-rename)" \
        "with no cs session left the window names itself again" || { _tt kill-server; return 1; }
    _tt kill-server
}

# Panes claim and release at the same moment (a layout restore starting
# several sessions, two /clears): each call reads the claims and then renames,
# so without serialising them a slower rename writes a name from before another
# pane's claim. Six panes, twenty rounds of claims and releases all at once;
# after each round the name must be the claims as they stand.
test_concurrent_claims_leave_the_name_the_claims_make() {
    session_start_setup
    _real_tmux_window || return $?
    local panes="$TT_PANE_A $TT_PANE_B" i p round got want
    for i in 3 4 5 6; do
        panes="$panes $(_tt split-window -d -P -F '#{pane_id}' -t "$TT_PANE_A" 'sleep 600')" || { _tt kill-server; return 1; }
        _tt select-layout -t "$TT_PANE_A" tiled >/dev/null
    done
    for round in $(seq 1 20); do
        i=0
        for p in $panes; do
            i=$((i + 1))
            ( TMUX="$TT_SOCK,1,0" bash -c '. "$1"; cs_tmux_title_window "$2" "$3"' _ "$HOOKS_DIR/cs-shared.sh" "$p" "s$i" ) &
        done
        wait
        want="cs: $(_tt list-panes -t "$TT_PANE_A" -F '#{@cs_session}' | awk '{ out = out (NR > 1 ? " | " : "") $0 } END { print out }')"
        got=$(_tt_window_name)
        assert_eq "$want" "$got" "round $round: concurrent claims name the window after every claim" || { _tt kill-server; return 1; }
        for p in $panes; do
            ( TMUX="$TT_SOCK,1,0" bash -c '. "$1"; cs_tmux_title_window "$2" ""' _ "$HOOKS_DIR/cs-shared.sh" "$p" ) &
        done
        wait
        assert_eq "on" "$(_tt show-window-options -v -t "$TT_PANE_A" automatic-rename)" \
            "round $round: concurrent releases leave no claim and hand the name back" || { _tt kill-server; return 1; }
    done
    _tt kill-server
}

# A lock that can never be made (TMPDIR gone or read-only, a full disk) must
# not stall the title: the wait is bounded at five seconds however the lock
# file's create fails, and the name is still written without the lock. The call runs in the
# background so an unbounded wait fails the test instead of hanging the suite.
test_an_unmakeable_lock_still_names_the_window_in_bounded_time() {
    session_start_setup
    _real_tmux_window || return $?
    local start=$SECONDS waited=0 pid
    TMUX="$TT_SOCK,1,0" TMPDIR="$TEST_TMPDIR/no-such-dir" \
        bash -c '. "$1"; cs_tmux_title_window "$2" solo' _ "$HOOKS_DIR/cs-shared.sh" "$TT_PANE_A" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 0.5; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        _tt kill-server
        assert_eq "returned" "still waiting after 15 s" "the title call returns when its lock cannot be made"
        return 1
    fi
    wait "$pid" 2>/dev/null
    assert_eq "1" "$(( SECONDS - start <= 8 ))" "the wait is bounded near five seconds" || { _tt kill-server; return 1; }
    assert_eq "cs: solo" "$(_tt_window_name)" "the name is written without the lock" || { _tt kill-server; return 1; }
    _tt kill-server
}

# The launch's own cleanup (its EXIT trap: a resume prompt cancelled, or the
# resume arm's claude returning) releases the pane the launch claimed, and the
# window stays named, and locked, after the sessions still in it.
test_a_launch_cleanup_releases_its_pane_and_keeps_the_others_title() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    local lib="$SCRIPT_DIR/../lib"
    _tt respawn-pane -k -t "$TT_PANE_B" "bash -c '. \"$lib/02-shared.sh\"; . \"$lib/05-term.sh\"; set_tab_title \"cs: fignity\" fignity; reset_tab_title; touch \"$TEST_TMPDIR/cleaned\"; sleep 600'" \
        || { _tt kill-server; return 1; }
    # The pane's shell starts later on a loaded machine; wait for its mark.
    wait_until test -e "$TEST_TMPDIR/cleaned"
    assert_eq "cs: current-session" "$(_tt_window_name)" \
        "the cleaned-up launch leaves the window to the session still running" || { _tt kill-server; return 1; }
    assert_eq "" "$(_tt show-options -p -v -t "$TT_PANE_B" @cs_session 2>/dev/null)" \
        "and holds no claim on its pane" || { _tt kill-server; return 1; }
    assert_eq "off" "$(_tt show-window-options -v -t "$TT_PANE_A" allow-rename)" \
        "the surviving session's window stays locked" || { _tt kill-server; return 1; }
    _tt kill-server
}

# A /clear in the window's only session ends it (the window is released and
# unlocked) and starts it again: the claim back must lock the names again, or
# Claude Code retitles the pane and the window for the rest of the session.
test_a_claim_after_the_last_release_locks_the_titles_again() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    _tt_hook session-end.sh "$TT_PANE_A" current-session clear
    _tt_hook session-start.sh "$TT_PANE_A" current-session clear || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt_window_name)" "the window is named again" || { _tt kill-server; return 1; }
    assert_eq "off" "$(_tt show-window-options -v -t "$TT_PANE_A" allow-rename)" \
        "the claim locks the window name against Claude Code's own titles" || { _tt kill-server; return 1; }
    # allow-set-title arrived in tmux 3.5; an older server (ubuntu-latest has
    # 3.4) has no pane-title lock to set, and the claim's set is a no-op there.
    if _tt show-options -gw allow-set-title >/dev/null 2>&1; then
        assert_eq "off" "$(_tt show-window-options -v -t "$TT_PANE_A" allow-set-title)" \
            "the claim locks the pane name against Claude Code's own titles" || { _tt kill-server; return 1; }
    fi
    _tt kill-server
}

# A claude that is not the launched one (a `claude -p` run from inside the
# session inherits its environment and TMUX_PANE) ends without taking the
# lead's claim with it.
test_a_non_lead_end_leaves_the_pane_claimed() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    echo '{"session_id":"s","source":"other","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionEnd"}' \
        | TMUX="$TT_SOCK,1,0" TMUX_PANE="$TT_PANE_A" CS_LEAD_PID=1 CLAUDE_PID=99999 \
          bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt_window_name)" \
        "the lead's session still names the window" || { _tt kill-server; return 1; }
    assert_eq "current-session" "$(_tt show-options -p -v -t "$TT_PANE_A" @cs_session)" \
        "and still holds its pane's claim" || { _tt kill-server; return 1; }
    _tt kill-server
}

# The launch takes its pane's claim too, from inside the pane itself: tmux gives
# the pane its own TMUX and TMUX_PANE, and the pane's terminal is the tty
# set_tab_title requires.
test_a_launch_in_a_second_pane_joins_the_window_name() {
    session_start_setup
    _real_tmux_window || return $?
    _tt_hook session-start.sh "$TT_PANE_A" current-session startup
    local lib="$SCRIPT_DIR/../lib"
    _tt respawn-pane -k -t "$TT_PANE_B" "bash -c '. \"$lib/02-shared.sh\"; . \"$lib/05-term.sh\"; set_tab_title \"cs: fignity\" fignity; touch \"$TEST_TMPDIR/launched\"; sleep 600'" \
        || { _tt kill-server; return 1; }
    # The pane's shell starts later on a loaded machine; wait for its mark.
    wait_until test -e "$TEST_TMPDIR/launched"
    assert_eq "cs: current-session | fignity" "$(_tt_window_name)" \
        "a cs launched in the other pane joins the window name" || { _tt kill-server; return 1; }
    assert_eq "cs: fignity" "$(_tt display-message -p -t "$TT_PANE_B" '#{pane_title}')" \
        "the pane's own title stays its session alone" || { _tt kill-server; return 1; }
    assert_eq "cs: current-session" "$(_tt display-message -p -t "$TT_PANE_A" '#{pane_title}')" \
        "and the pane already running keeps its own" || { _tt kill-server; return 1; }
    _tt kill-server
}

# A tmux teammate is a full claude with its own SessionStart, and Claude Code
# titles its pane with the agent's name. The tab being repaired is the lead's.
test_session_start_tab_title_leaves_a_teammate_pane_alone() {
    session_start_setup
    _fake_tmux
    echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | PATH="$FAKE_TMUX_PATH:$PATH" TMUX="/tmp/tmux-1000/default,1234,0" TMUX_PANE="%9" \
          CS_LEAD_PID=1 CLAUDE_PID=99999 bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    assert_file_not_contains "$FAKE_TMUX_CALLS" "select-pane\|rename-window" \
        "a teammate's pane title and window name are not touched" || return 1
}

# Outside tmux the OSC 0 escape has to reach the terminal itself. A hook's
# stdout is Claude's, so the escape is written to the terminal device.
test_session_start_reasserts_tab_title_on_the_terminal_device() {
    session_start_setup
    echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || return 1
    assert_file_exists "$CS_TITLE_TTY" "the title escape is written to the terminal device" || return 1
    local expected
    expected=$(printf '\033]0;cs: current-session\007' | od -An -c | tr -s ' ')
    assert_eq "$expected" "$(od -An -c < "$CS_TITLE_TTY" | tr -s ' ')" \
        "the device receives exactly one OSC 0 title escape" || return 1
}

# No tmux and no terminal device (the desktop app, a headless front end): the
# title is skipped and the hook's context payload is unaffected.
test_session_start_tab_title_skips_silently_without_a_terminal() {
    session_start_setup
    local output
    output=$(echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_TITLE_TTY="$TEST_TMPDIR/no-such-dir/tty" bash "$HOOKS_DIR/session-start.sh" 2>"$TEST_TMPDIR/stderr") || return 1
    assert_output_contains "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')" \
        "managed Claude Code session: current-session" "the context payload still parses" || return 1
    assert_file_not_contains "$TEST_TMPDIR/stderr" "no-such-dir" \
        "a missing terminal device is not reported" || return 1
}

# The resume instruction is "read your narrative in full", and the Read tool
# refuses a file over 256 KiB. A narrative past its budget is on its way there,
# so the same payload that says "read it" has to say "rotate first" for that
# file, name it and its size, and say whose it is when the actor matches.
test_session_start_warns_about_an_over_budget_narrative() {
    session_start_setup
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } \
        > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (bob)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_NARRATIVE_MAX_BYTES=2048 CS_ACTOR=alice bash "$HOOKS_DIR/session-start.sh" 2>/dev/null) || return 1
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "NARRATIVE OVER BUDGET" "the warning is loud" || return 1
    assert_output_contains "$context" "narrative.alice.md is 2 KB, over the 2 KB budget" \
        "the file and its size are named" || return 1
    assert_output_contains "$context" "yours: run \`cs -narrative rotate\` BEFORE reading it in full (the Read tool refuses a file over 256 KiB)" \
        "the actor's own file is told to rotate before the full read" || return 1
    assert_output_not_contains "$context" "narrative.bob.md is" "a file within budget is not named" || return 1
}

# A teammate's file over budget is that actor's to rotate; the notice still
# names it, so the digest's "read from line N" is not attempted on a file the
# Read tool would refuse.
test_session_start_names_a_teammate_narrative_over_budget_as_theirs() {
    session_start_setup
    { echo "# Session narrative (bob)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } \
        > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    local context
    context=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_NARRATIVE_MAX_BYTES=2048 CS_ACTOR=alice bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "narrative.bob.md is 2 KB, over the 2 KB budget" \
        "the teammate's file is named" || return 1
    assert_output_contains "$context" "not yours: read it only from the line the digest names" \
        "the teammate's file is theirs to rotate" || return 1
    assert_output_not_contains "$context" "run \`cs -narrative rotate\` BEFORE" \
        "the rotate instruction is for the actor's own file only" || return 1
}

# A clone chooses a narrative's file name; the over-budget notice names it as a
# plain name, each character a plain name lacks replaced by _.
test_session_start_names_a_narrative_over_budget_as_a_plain_name() {
    session_start_setup
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m context
    { echo "# Session narrative"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } \
        > "$CLAUDE_SESSION_META_DIR/memory/narrative.b$bad.md"
    context=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_NARRATIVE_MAX_BYTES=2048 CS_ACTOR=alice bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_eq "- narrative.b$shown.md is 2 KB, over the 2 KB budget; not yours: read it only from the line the digest names, never whole" \
        "$(grep '^- narrative\.b' <<< "$context")" "the notice names the narrative as a plain name" || return 1
    assert_no_escape_bytes "$context" "no escape byte reaches Claude" || return 1
}

# Within budget, nothing is added: the warning would otherwise ride every
# conversation start as noise and stop reading as a warning.
test_session_start_is_silent_when_narratives_fit() {
    session_start_setup
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    local context
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_ACTOR=alice bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "managed Claude Code session: current-session" \
        "the payload is a real context, not an empty emit" || return 1
    assert_output_not_contains "$context" "OVER BUDGET" "no warning within budget" || return 1
}

# A feature session has two addresses: cs's, with the '@', and the one Claude
# Code's own tools take, with a '+'. The context names both, so the model
# never hands a peer the spelling SendMessage refuses; a plain session has one
# name and gets no such line.
test_session_start_names_both_addresses_of_a_feature_session() {
    session_start_setup
    local context
    context=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "^Claude Code's own tools (ListAgents, SendMessage) know this session as myproj+fix-auth; cs (cs -msg, cs -rm, the directory) takes myproj@fix-auth.$" \
        "a feature session's context names both spellings" || return 1
    context=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_not_contains "$context" "know this session as" \
        "a plain session gets no such line" || return 1
}

# A leading zero in the override is a plain integer to the validator and an
# octal literal to the arithmetic that renders the budget in KB; `08` is not
# octal, and under errexit that abort would end the hook before its JSON.
test_session_start_survives_a_leading_zero_budget_override() {
    session_start_setup
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } \
        > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_NARRATIVE_MAX_BYTES=08 CS_ACTOR=alice bash "$HOOKS_DIR/session-start.sh" 2>"$TEST_TMPDIR/stderr") || return 1
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "narrative.alice.md is 2 KB, over the 0 KB budget" \
        "the override is read as decimal 8" || return 1
    assert_file_not_contains "$TEST_TMPDIR/stderr" "value too great for base" "no octal abort" || return 1
}

# Helper: create a sibling session with an objective
create_sibling_session() {
    local name="$1"
    local objective="$2"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs/local"
    cat > "$dir/.cs/README.md" << EOF
## Objective

$objective
EOF
    # Touch log to set modification time
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Session started" > "$dir/.cs/local/session.log"
}


# The resume-only Session State block is gated on the session being a git repo.
# This is the baseline: an ordinary session, where .git is a directory.
test_session_start_emits_session_state_on_resume() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "an ordinary session gets the resume state block" || return 1
}

# In a feature worktree .git is a FILE, not a directory, so a `-d` test on it is
# false and the whole block was skipped — for every worktree session, on every
# resume. The rest of the codebase probes with `git rev-parse --git-dir`, which
# is true for both shapes.
test_session_start_emits_session_state_in_a_worktree() {
    session_start_setup
    local base="$CLAUDE_SESSION_DIR"
    local wt="$CS_SESSIONS_ROOT/current-session@feat"
    git -C "$base" worktree add -q -b cs/feat "$wt" >/dev/null 2>&1 || {
        echo "  FAIL: could not create the worktree fixture"
        return 1
    }
    [ -f "$wt/.git" ] || { echo "  FAIL: fixture .git is not a file — the bug is unreachable"; return 1; }
    mkdir -p "$wt/.cs"/{local,memory}
    cp "$CLAUDE_SESSION_META_DIR/README.md" "$wt/.cs/README.md"
    export CLAUDE_SESSION_DIR="$wt"
    export CLAUDE_SESSION_META_DIR="$wt/.cs"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$wt"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "a worktree session must get the resume state block too" || return 1
}

# The commit is aged out of the digest's 7-day window: the line must not depend
# on there being a recent commit to report.
test_session_start_resume_warns_of_actions_its_summary_omits() {
    session_start_setup
    GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
        git -C "$CLAUDE_SESSION_DIR" commit -q --amend --no-edit --date="2020-01-01T00:00:00Z"
    local line="The conversation before this one may have finished actions its summary does not show; check git log, cs -msg log and the remote before repeating a push, a merge, an install or a message."

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_eq "0" "$(grep -c '^Recent commits:' <<< "$context")" \
        "the fixture leaves no recent commit to report" || return 1
    assert_eq "1" "$(grep -c -x -F "$line" <<< "$context")" \
        "a resume carries the line once, as a whole line" || return 1

    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "You are working in a managed Claude Code session" \
        "a startup still builds its context" || return 1
    assert_eq "0" "$(grep -c -x -F "$line" <<< "$context")" \
        "a startup does not carry the line" || return 1
}

test_session_start_announces_worktree_task() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    local output context
    output=$(echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "feature worktree of session 'myproj'" \
        "worktree sessions must be told what they are (on every source)" || return 1
    assert_output_contains "$context" "/finish fix-auth in session myproj" \
        "the integration command must be spelled out" || return 1
    assert_output_contains "$context" "while this conversation is live /finish stages the retire in the base, and the base runs it by itself once the user closes this session" \
        "and the retirement rule: the user closes this session, then /finish again" || return 1
    assert_output_not_contains "$context" "cs myproj --merge" \
        "the retired verb is never named" || return 1
    assert_output_contains "$context" "Do NOT merge" \
        "manual merges must be warned against" || return 1
}


test_session_start_worktree_block_needs_at_shaped_name() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    # task_branch present but the session name lost its @ (corrupted state
    # or env set outside the launcher): emitting commands would misfire —
    # cs -rm on a plain name rm -rf's the BASE session. No block at all.
    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "cs -rm" \
        "no destructive command suggestions without a parseable name" || return 1
    assert_output_not_contains "$output" "feature worktree" \
        "no worktree block when the name shape does not parse" || return 1
}

test_session_start_no_worktree_block_for_plain_sessions() {
    session_start_setup

    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "feature worktree" \
        "plain sessions must not get the worktree block" || return 1
}

test_session_start_worktree_abandon_is_user_gated() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\ncs_base: myproj\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    # The abandon command rm -rf's the whole worktree session. Like the merge
    # command, it must be routed through the user — never left looking self-serve.
    local output context
    output=$(echo '{"session_id":"s","source":"clear","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "ask the user to run: cs -rm" \
        "the destructive abandon command must be gated behind the user, like the merge command" || return 1
    assert_output_contains "$context" "never run this yourself" \
        "the abandon command must warn Claude not to self-serve the worktree deletion" || return 1
}

# Helper: build a refs/worktree/cs/auto shadow ref whose tree differs from HEAD
# in $1 files (simulates the unsaved crash state the recovery path detects).
_seed_crash_shadow() {
    local n="$1" i base
    # Stage only the crash files — git add -A would also sweep in the untracked
    # .cs/README.md session_start_setup leaves behind, inflating the file count.
    # Record the base HEAD in a cs-base trailer, as a real autosave does, so the
    # snapshot reads as sitting on the current HEAD (the ordinary crash case
    # where recovery's whole-tree restore is safe to offer).
    ( cd "$CLAUDE_SESSION_DIR" \
        && base=$(git rev-parse HEAD) \
        && for i in $(seq 1 "$n"); do echo "autosave $i" > "crash_$i.txt"; done \
        && git add crash_*.txt \
        && git commit -q -m "$(printf 'autosaved crash state\n\ncs-base: %s' "$base")" \
        && git update-ref refs/worktree/cs/session/40000000-0000-0000-0000-000000000001 HEAD \
        && git reset -q --hard HEAD~1 )
}

test_session_start_crash_recovery_warns_before_overwrite() {
    session_start_setup
    _seed_crash_shadow 2

    local output context
    output=$(echo '{"session_id":"40000000-0000-0000-0000-000000000001","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "CRASH RECOVERY" \
        "crash recovery context must be injected when a shadow ref has changes" || return 1
    assert_output_contains "$context" "Before starting any other work" \
        "crash recovery must anchor the ask BEFORE Claude starts the first task" || return 1
    assert_output_contains "$context" "overwrites any current uncommitted changes" \
        "crash recovery must warn that restoring clobbers uncommitted work" || return 1
}

test_session_start_crash_count_reflects_all_files() {
    session_start_setup
    # 12 changed files: the count must report 12, not the 10 the list is capped at.
    _seed_crash_shadow 12

    local output context
    output=$(echo '{"session_id":"40000000-0000-0000-0000-000000000001","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "12 file(s)" \
        "the crash file count must reflect all changed files, not the capped list length" || return 1
    assert_output_contains "$context" "first 10 listed" \
        "when the list is capped the context must say so" || return 1
}

test_subagent_context_announces_worktree_task() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'task_branch: cs/fix-auth\n' >> "$CLAUDE_SESSION_META_DIR/local/state"

    local output
    output=$(echo '{}' | CLAUDE_SESSION_NAME="myproj@fix-auth" bash "$HOOKS_DIR/subagent-context.sh" 2>/dev/null)
    assert_output_contains "$output" "feature worktree" \
        "subagents must inherit worktree awareness" || return 1
    assert_output_contains "$output" "/finish" \
        "subagents must know integration goes through /finish in the base" || return 1
    assert_output_contains "$output" "retirement is /finish too" \
        "subagents must know retirement goes through /finish as well" || return 1
}

test_resume_digest_reports_memory_activity() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    ( cd "$CLAUDE_SESSION_DIR" && mkdir -p .cs/memory && echo "fact" > .cs/memory/new-fact.md \
        && git add -A && git commit -q -m "add memory" --author="Bob <bob@x.io>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Since your last session" "resume should inject the activity digest" || return 1
    assert_output_contains "$context" "Bob" "digest should name the contributing author" || return 1

    local head wm
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)
    wm=$(cat "$CLAUDE_SESSION_META_DIR/local/watermark")
    assert_eq "$head" "$wm" "watermark should advance to HEAD after resume" || return 1
}

# A clone's history chooses its commit author names, and git keeps an ESC or
# BEL byte in one. The digest names each author as a plain name, each
# character a plain name lacks replaced by _.
test_resume_digest_names_an_author_as_a_plain_name() {
    session_start_setup
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m context
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    ( cd "$CLAUDE_SESSION_DIR" && mkdir -p .cs/memory && echo "fact" > .cs/memory/new-fact.md \
        && git add -A && GIT_AUTHOR_NAME="Jane $bad" GIT_AUTHOR_EMAIL=jane.roe@example.com git commit -q -m "add memory" )
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "(author: commits): Jane_$shown (1);" \
        "the digest names the author as a plain name" || return 1
    assert_no_escape_bytes "$context" "no escape byte reaches Claude" || return 1
}

# Nobody can read a teammate's whole narrative on resume (one dormant file
# measured 801 KB). Narratives are append-only, so everything committed since
# this actor's watermark is a tail: the digest names each teammate file that
# grew, how many sections were added, and the line the new content starts on.
# The actor's own file is read in full and never listed here.
test_resume_digest_names_where_a_teammates_narrative_grew() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    local mine="$CLAUDE_SESSION_DIR/.cs/memory/narrative.t-t.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    printf -- '---\nname: session-narrative-t-t\ntype: narrative\n---\n## mine\nown line\n' > "$mine"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    # bob's file is 12 lines; the appended section starts on line 13.
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"
    printf -- '\n## mine again\nown new line\n' >> "$mine"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append" --author="Bob <bob@example.com>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 13" \
        "digest must name the teammate file, the section count and the first new line" || return 1
    assert_output_contains "$context" "narrative.t-t.md in full" \
        "digest must tell the actor to read its own narrative in full" || return 1
    assert_output_not_contains "$context" "narrative\.t-t\.md: [0-9][0-9]* new section" \
        "the actor's own narrative is never listed as a teammate delta" || return 1
    assert_output_not_contains "$context" "Skim their narrative" \
        "the whole-file skim instruction is gone" || return 1
}

# A clone chooses a teammate narrative's file name, and the digest hands Claude
# the path to read with sed. git quotes a control byte in a path, but not a
# shell metacharacter, so a name a plain name lacks is passed over, as a
# rotation handoff's is: the path Claude is told is always the file itself.
# A narrative is one file directly below .cs/memory, so one in a directory
# whose name holds the metacharacters is passed over too.
test_resume_digest_passes_over_a_narrative_whose_name_is_not_plain() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    local odd="$CLAUDE_SESSION_DIR/.cs/memory/narrative.x;echo pwned;.md"
    local below="$CLAUDE_SESSION_DIR/.cs/memory/narrative.x;echo pwned;/y.md"
    mkdir -p "${below%/*}"
    printf -- '# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n' > "$bob"
    printf -- '# Session narrative\n\n## 2026-01-01 first\nold finding\n' > "$odd"
    printf -- '# Session narrative\n\n## 2026-01-01 first\nold finding\n' > "$below"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-02 second\nnew finding\n' >> "$bob"
    printf -- '\n## 2026-01-02 second\nnew finding\n' >> "$odd"
    printf -- '\n## 2026-01-02 second\nnew finding\n' >> "$below"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append" --author="Bob <bob@example.com>" )

    local context
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "teammate narratives grew: \.cs/memory/narrative\.bob\.md: 1 new section(s) from line 5\. Read your own" \
        "the digest names only the plain teammate narrative" || return 1
    assert_output_not_contains "$context" "pwned" "the digest never names the narrative whose name is not plain" || return 1
}

# A clone can commit a link named like a narrative. Claude would read its
# target, a file outside the session the clone chose, so the digest names only
# a narrative that is a regular file.
test_resume_digest_passes_over_a_narrative_that_is_a_link() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    local eve="$CLAUDE_SESSION_DIR/.cs/memory/narrative.eve.md"
    printf -- '# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n' > "$bob"
    printf -- '## 2026-01-01 first\n' > "$TEST_TMPDIR/outside1.txt"
    printf -- '## 2026-01-01 first\n\n## 2026-01-02 second\n' > "$TEST_TMPDIR/outside2.txt"
    ln -s "$TEST_TMPDIR/outside1.txt" "$eve"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-02 second\nnew finding\n' >> "$bob"
    ln -sfn "$TEST_TMPDIR/outside2.txt" "$eve"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append" --author="Bob <bob@example.com>" )

    local context
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "teammate narratives grew: \.cs/memory/narrative\.bob\.md: 1 new section(s) from line 5\. Read your own" \
        "the digest names only the teammate narrative that is a file" || return 1
    assert_output_not_contains "$context" "narrative\.eve" "the digest never names a narrative that is a link" || return 1
}

# The same holds for the files the recent commits touched: the hook names
# each one Claude might open, so only a plain name is listed.
test_session_start_lists_only_recent_files_with_plain_names() {
    session_start_setup
    ( cd "$CLAUDE_SESSION_DIR" && GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q --amend --no-edit --date="2020-01-01T00:00:00Z" \
        && echo plan > plan.md && echo odd > "a;echo pwned;.md" && git add plan.md "a;echo pwned;.md" && git commit -q -m "recent" )

    local context
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "^Recent commits: 1 in last 7 days (plan\.md)$" \
        "the recent commits name only the file whose name is plain" || return 1
    assert_output_not_contains "$context" "pwned" "the recent commits never name a file whose name is not plain" || return 1
}

# Checking a name forks (_cs_plain_name's cut, which a stand-in on PATH
# counts), so the list checks at most the first five files the commits touched,
# however many there are. Ten names that are not plain are never written to the
# list, so nothing ends the checks early.
test_session_start_checks_at_most_five_recent_files() {
    session_start_setup
    local shim="$TEST_TMPDIR/shim" calls="$TEST_TMPDIR/cut.calls" i
    mkdir -p "$shim"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec /usr/bin/cut "$@"\n' "$calls" > "$shim/cut"
    chmod +x "$shim/cut"
    ( cd "$CLAUDE_SESSION_DIR" && GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q --amend --no-edit --date="2020-01-01T00:00:00Z" \
        && for i in 0 1 2 3 4 5 6 7 8 9; do echo odd > "x y$i.md"; done && git add -- "x y"*.md && git commit -q -m "recent" )

    local context checks
    context=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | PATH="$shim:$PATH" bash "$HOOKS_DIR/session-start.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext') || return 1
    assert_output_contains "$context" "^Recent commits: 1 in last 7 days$" \
        "the recent commits name no file whose name is not plain" || return 1
    checks=$(grep -c '^-c1-160$' "$calls" 2>/dev/null || true)
    [ "${checks:-0}" -ge 1 ] || { echo "  FAIL: the cut stand-in counted no name check (got '${checks}')"; return 1; }
    [ "$checks" -le 5 ] || { echo "  FAIL: the recent files list checked $checks names, more than five"; return 1; }
}

# Rotation head-truncates a narrative (oldest sections move to the archive), so
# the file can shrink at the top while it grows at the tail. The start line is
# still (lines now - lines added + 1), and the count is of added sections only.
test_resume_digest_delta_survives_a_rotated_teammate_narrative() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    # Rotate away the first section (3 lines gone from the head), then append one.
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-02 second\nanother old finding\n\n## 2026-01-03 third\nnew finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "rotate and append" --author="Bob <bob@example.com>" )

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    # 11 lines now, 3 added: the new section starts on line 9.
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 9" \
        "after a head-truncating rotation the delta is still the tail" || return 1
}

# Two commits after the watermark plus an uncommitted append form one tail:
# the start line is the first added hunk against the working tree, and the
# count covers all three. Two commits pin the range to the watermark rather
# than to HEAD~1; the uncommitted third pins the working-tree comparison.
test_resume_digest_counts_two_commits_and_an_uncommitted_tail() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append 1" --author="Bob <bob@example.com>" )
    printf -- '\n## 2026-01-04 fourth\nnewer finding\n' >> "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "append 2" --author="Bob <bob@example.com>" )
    # Uncommitted growth on top: counted, and the start line stays 13.
    printf -- '\n## 2026-01-05 uncommitted\nnot yet committed\n' >> "$bob"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 3 new section(s) from line 13" \
        "two commits and an uncommitted append since the watermark form one tail from line 13" || return 1
}

# The hooks must parse under the floor shell. An apostrophe inside a heredoc
# that sits inside $(...) is accepted by bash 5 and rejected by bash 3.2, so
# a suite that runs the hooks under whichever bash leads PATH cannot see it.
test_hooks_parse_under_bin_bash() {
    local f
    for f in "$HOOKS_DIR"/*.sh; do
        /bin/bash -n "$f" 2>/dev/null || { echo "  FAIL: /bin/bash -n rejects $(basename "$f")"; return 1; }
    done
}

# In a shared-directory tmux team nobody commits .cs/memory, so the delta is
# taken against the working tree: uncommitted growth is reported too, and again
# on each resume until it is committed.
test_resume_digest_reports_uncommitted_teammate_growth() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Since your last session" "uncommitted growth still produces the digest" || return 1
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 13" \
        "an uncommitted append is named like a committed one" || return 1
}

# A teammate who has not committed their narrative at all is still a teammate.
# A never-committed teammate narrative has no watermark to measure against, so
# the only honest report is its whole length — which is the instruction this
# digest exists to replace, repeated on every resume with no state that could
# ever stop it. Silence is what a resume did before the digest existed.
test_resume_digest_says_nothing_about_an_untracked_teammate_narrative() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n## 2026-01-01 first\nfinding\n\n## 2026-01-02 second\nanother\n' \
        > "$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_not_contains "$context" "narrative\.bob\.md" \
        "an untracked teammate narrative must not be named at all" || return 1
}

# A head edit (the migration rewriting a description line, a dated correction)
# is not growth. The named line is the LAST added hunk: append-only means real
# growth is the final hunk, and a head edit alone still reports zero sections.
test_resume_digest_start_line_ignores_a_head_edit() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ndescription: lab notebook\ntype: narrative\n---\n# Session narrative (bob)\n\n## 2026-01-01 first\nold finding\n\n## 2026-01-02 second\nanother old finding\n' > "$bob"
    ( cd "$CLAUDE_SESSION_DIR" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    sed 's/^description: lab notebook$/description: rewritten by migration/' "$bob" > "$bob.tmp" && mv "$bob.tmp" "$bob"
    printf -- '\n## 2026-01-03 third\nnew finding\n' >> "$bob"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 13" \
        "a head edit must not pull the start line to the head" || return 1
}

# git diff --numstat prints repo-root-relative paths; a session directory that
# sits inside a larger repository must still match its own .cs/memory files.
test_resume_digest_works_when_the_session_is_a_repo_subdirectory() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    # Re-root: the session dir becomes a subdirectory of a parent repository.
    rm -rf "$CLAUDE_SESSION_DIR/.git"
    ( cd "$CS_SESSIONS_ROOT" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m root )
    local bob="$CLAUDE_SESSION_DIR/.cs/memory/narrative.bob.md"
    printf -- '---\nname: session-narrative-bob\ntype: narrative\n---\n## 2026-01-01 first\nold finding\n' > "$bob"
    ( cd "$CS_SESSIONS_ROOT" && git add -A && git commit -q -m "narratives" --author="Bob <bob@example.com>" )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    printf -- '\n## 2026-01-02 second\nnew finding\n' >> "$bob"

    local output context
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "narrative.bob.md: 1 new section(s) from line 7" \
        "a subdirectory session must still see its teammate narrative grow" || return 1
}

# Watermark at HEAD and nothing changed: no digest line at all, not a dangling
# "Since your last session," with an empty tail.
test_resume_digest_silent_when_nothing_changed() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"

    local output
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "Since your last session" "no digest when nothing changed since the watermark" || return 1
}

test_resume_digest_silent_without_watermark() {
    session_start_setup
    rm -f "$CLAUDE_SESSION_META_DIR/local/watermark"

    local output
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "Since your last session" "no digest on first resume (no watermark)" || return 1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/watermark" "watermark should be seeded on first resume" || return 1
}

test_session_start_includes_sibling_sessions() {
    session_start_setup

    create_sibling_session "api-refactor" "Refactor REST API to use GraphQL"
    create_sibling_session "auth-migration" "Migrate auth from JWT to Clerk"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! grep -q "api-refactor" <<< "$context"; then
        echo "  FAIL: Should include sibling session api-refactor"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi
    if ! grep -q "auth-migration" <<< "$context"; then
        echo "  FAIL: Should include sibling session auth-migration"
        session_start_teardown
        return 1
    fi
    if ! grep -q "cs -msg" <<< "$context"; then
        echo "  FAIL: sibling block should name cs -msg as the way to reach another session"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_excludes_current_session() {
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Current session should NOT appear in the sibling list
    # (it's already the session being started)
    if grep -q "Other Sessions" <<< "$context" && grep -q "current-session:" <<< "$context"; then
        echo "  FAIL: Should not include current session in sibling list"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

# Two other places in this hook family mandate AskUserQuestion for a decision the
# user owns: crash recovery, and the wrap-up cue in the CLAUDE.local.md block.
# Routing a request to the session that owns it is the same kind of decision and
# was the one left as passive prose.
test_session_start_sibling_block_mandates_asking() {
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! grep -q "AskUserQuestion" <<< "$context"; then
        echo "  FAIL: sibling block must name AskUserQuestion, not just 'say so'"
        session_start_teardown
        return 1
    fi
    # Picky, not trigger-happy: the wrap-up cue text warns that false positives
    # erode the signal, and a routing prompt that fires on vocabulary overlap
    # becomes the next ignored block.
    if ! grep -qi "substantially" <<< "$context"; then
        echo "  FAIL: sibling block must set a high bar, not fire on any overlap"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_sibling_line_carries_the_send_syntax() {
    # Naming the verb without its syntax is worse than saying nothing: it tells
    # the reader a capability exists and forces a `cs --help` call to use it.
    # Inbound mail is already pushed on every prompt by scope-prompt.sh; this is
    # the only place the outbound form is delivered where sending is possible.
    session_start_setup

    create_sibling_session "other-work" "Some other work"

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! grep -q 'cs -msg <session> "<body>"' <<< "$context"; then
        echo "  FAIL: the sibling line must carry the full send form, not just the verb"
        session_start_teardown
        return 1
    fi
    if ! grep -q 'notify|task|text|result' <<< "$context"; then
        echo "  FAIL: the sibling line must name the --kind values"
        session_start_teardown
        return 1
    fi
    # A task is mail like any other kind: it reaches the recipient's queue only
    # when that session's user runs its accept command (lib/53-mail.sh,
    # lib/55-queue.sh), so the line must not promise an unattended run.
    assert_eq 'Add --kind notify|task|text|result (default text; a task waits in that session'"'"'s mailbox until its user accepts it with cs -queue accept <id>).' \
        "$(grep -F 'Add --kind' <<< "$context")" \
        "the --kind line says where a task waits and what queues it" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_narrative_is_per_actor() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    assert_output_not_contains "$context" "narrative.md: Document" \
        "session-start must not steer findings to the shared narrative.md" || { session_start_teardown; return 1; }
    # The block resolves the actor, so the key-files line can name the real file
    # instead of a placeholder the agent would have to resolve for itself. Read
    # the slug back out of the context and require the two lines to agree —
    # a drifting pair is what would send findings to a file nobody reads.
    local actor
    actor=$(printf '%s\n' "$context" | sed -n 's/^Current actor: \([^ ]*\) .*/\1/p' | head -1)
    [ -n "$actor" ] || {
        echo "  FAIL: the injected context never states the resolved actor"
        session_start_teardown; return 1
    }
    assert_output_contains "$context" "narrative.$actor.md: append findings" \
        "the key-files line must name the same resolved narrative the actor line does" \
        || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_secrets_guidance_is_stdin_and_backend_neutral() {
    session_start_setup

    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    assert_output_not_contains "$context" "stored securely in the OS keychain" \
        "secrets backend may be the encrypted-file fallback, not a keychain" || { session_start_teardown; return 1; }
    assert_output_contains "$context" "on stdin" \
        "secrets guidance must direct the value to stdin (argv/heredoc leak to the log)" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_shows_objectives() {
    session_start_setup

    create_sibling_session "my-project" "Build the analytics dashboard"

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! grep -q "analytics dashboard" <<< "$context"; then
        echo "  FAIL: Should include sibling objective text"
        echo "  Context: $(echo "$context" | tail -10)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_limits_sibling_count() {
    session_start_setup

    # Create 10 sibling sessions
    for i in $(seq 1 10); do
        create_sibling_session "session-$i" "Objective for session $i"
    done

    local output
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # Should show at most 5 siblings
    local sibling_count
    sibling_count=$(echo "$context" | grep -c "^  [a-z]" || echo "0")
    if [[ "$sibling_count" -gt 5 ]]; then
        echo "  FAIL: Should limit to 5 siblings (got $sibling_count)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_updates_last_resumed() {
    session_start_setup

    # Verify no last_resumed yet
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed:" \
        "Should not have last_resumed before resume" || { session_start_teardown; return 1; }

    # Trigger resume
    echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed: 20" \
        "Should set last_resumed in local state after resume" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_last_resumed_not_set_on_startup() {
    session_start_setup

    # source=startup should NOT set last_resumed
    echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "last_resumed:" \
        "Should not set last_resumed on startup" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_skips_siblings_on_startup() {
    session_start_setup

    create_sibling_session "other" "Some work"

    # source=startup (fresh session, not resume)
    local output
    output=$(echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    local context
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    # On startup, no dynamic context is injected (including siblings)
    if grep -q "Other Sessions" <<< "$context"; then
        echo "  FAIL: Should not inject siblings on startup (only on resume)"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

# Helper: seed local state with a recorded claude_session_id
seed_recorded_uuid() {
    local uuid="$1"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    echo "claude_session_id: $uuid" > "$CLAUDE_SESSION_META_DIR/local/state"
}

test_session_start_clears_attention_marker() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"

    echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "session start should clear a stale attention marker" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_uuid_to_live_session() {
    session_start_setup

    # Local state records an old conversation; the hook reports a different
    # live one (claude forks a new UUID on context-limit continuation, leaving
    # the old transcript on disk — the recorded binding goes stale)
    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind claude_session_id to the live session UUID" || { session_start_teardown; return 1; }
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "aaaaaaaa-1111-2222-3333-444444444444" \
        "Stale UUID should be gone after rebind" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_uuid_on_startup() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "Should rebind on startup too (live UUID is authoritative on every source)" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_ignores_invalid_session_id() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # Non-UUID session_id (eg. jq null fallback or harness stub) must not
    # clobber a valid recorded binding
    echo '{"session_id":"not-a-uuid","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "Recorded UUID should survive an invalid live session_id" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebinds_for_a_claude_cs_spawned() {
    # Needs a real `ps -o ppid=`. A ps that accepts
    # only [-aefls] [-u UID] [-p PID] and errors on -o, which would fail this
    # test for a reason that has nothing to do with the property. Nothing is
    # declining is the right answer when no lead process can be identified.
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # cs's resume arm runs claude as a child rather than exec'ing into it — it
    # needs the exit status to fall through to a fresh rebind when there is no
    # conversation to resume — so on the commonest launch of all the recorded
    # conversation's pid is cs's CHILD, not cs itself. A real background job
    # stands in for claude: its parent is this shell, the same relation that
    # launch creates. Recognising only the exec'd shape would silence the
    # rebind on every resume.
    sleep 30 &
    local launched=$!

    CLAUDE_PID="$launched" \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"resume\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    kill "$launched" 2>/dev/null || true
    wait "$launched" 2>/dev/null || true

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: bbbbbbbb-5555-6666-7777-888888888888" \
        "a claude cs spawned as its child must still rebind" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_for_child_claude() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # A child claude — an agent-team teammate, or a headless `claude -p` the
    # lead spawned — runs its own SessionStart against the same checkout. It
    # may carry the lead's exported CS_LEAD_PID, but Claude Code stamps each
    # hook env with the pid of the claude that fired it, so CLAUDE_PID is the
    # child's own. Only the launched conversation owns the single recorded slot.
    CLAUDE_PID=999999 \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a child claude must not take the recorded slot" || { session_start_teardown; return 1; }
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/local/state" "bbbbbbbb-5555-6666-7777-888888888888" \
        "the child's own UUID must never be recorded" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_for_a_live_foreign_parent() {
    # Needs a real `ps -o ppid=` — see the skip note above.
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # The teammate's actual shape: a LIVE claude whose parent is real but is not
    # cs — tmux started it. The sibling decline test uses a dead pid, so it pins
    # only the case where ps finds nothing; an implementation that asked whether
    # a parent EXISTS rather than whether it MATCHES would satisfy that test and
    # re-open this bug. Here ps succeeds and reports this shell, while
    # CS_LEAD_PID names a process that is not it.
    sleep 30 &
    local live=$!

    CLAUDE_PID="$live" CS_LEAD_PID=999999 \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a live claude whose parent is not cs must not take the slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_without_lead_pid() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # A front end that resolved the session by walking the directory — desktop,
    # or a bare `claude` started inside a session checkout. Nothing exported
    # CS_LEAD_PID, so there is no launch to match and the slot is not this
    # conversation's to claim. Asserted separately from the child case because
    # the two fail the gate for different reasons, and an implementation that
    # compares the two variables without requiring both to be set would let
    # this one through on the empty string.
    CLAUDE_PID=999999 CS_LEAD_PID= \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "a walked-in front end must not take the recorded slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

test_session_start_rebind_declines_when_neither_pid_is_set() {
    session_start_setup

    seed_recorded_uuid "aaaaaaaa-1111-2222-3333-444444444444"

    # Both unset is the trap a bare `[ "$CLAUDE_PID" = "$CS_LEAD_PID" ]` falls
    # into: empty equals empty, so every unknown caller would be treated as the
    # lead. The gate must require a launch pid to exist, not merely agree.
    CLAUDE_PID= CS_LEAD_PID= \
        bash -c 'echo "{\"session_id\":\"bbbbbbbb-5555-6666-7777-888888888888\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        2>/dev/null > /dev/null

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        "an unidentifiable caller must not take the recorded slot" || { session_start_teardown; return 1; }

    session_start_teardown
}

# ============================================================================
# session-end.sh: index.md generation
# ============================================================================

# Setup for index tests: need SESSIONS_ROOT with sessions that have frontmatter
index_setup() {
    setup
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"

    # Current session
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-08
tags: [testing, hooks]
---
# Session: current-session

## Objective

Test the index generation feature

## Environment

Local dev
EOF
    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && printf '.cs/local/\n' > .gitignore && git add -A && git commit -q -m init)
}

index_teardown() {
    teardown
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

# Helper: create a session with frontmatter
create_indexed_session() {
    local name="$1"
    local status="$2"
    local objective="$3"
    local tags="${4:-}"
    local dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    cat > "$dir/.cs/README.md" << EOF
---
status: $status
created: 2026-04-01
tags: [$tags]
---
# Session: $name

## Objective

$objective

## Outcome

[pending]
EOF
}

test_session_end_generates_index() {
    index_setup

    create_indexed_session "api-work" "active" "Build the API" "api, backend"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" "index.md should be generated" || { index_teardown; return 1; }

    index_teardown
}

test_index_lists_all_sessions() {
    index_setup

    create_indexed_session "alpha" "active" "Alpha objective"
    create_indexed_session "beta" "completed" "Beta objective"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "alpha" "Should list alpha" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "beta" "Should list beta" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "current-session" "Should list current session" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_objectives() {
    index_setup

    create_indexed_session "my-project" "active" "Build the dashboard"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Build the dashboard" \
        "Should include objective text" || { index_teardown; return 1; }

    index_teardown
}

test_index_shows_status() {
    index_setup

    create_indexed_session "done-project" "completed" "Old work"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "completed" \
        "Should show status" || { index_teardown; return 1; }

    index_teardown
}

test_index_has_auto_generated_notice() {
    index_setup

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" "Auto-generated" \
        "Should have auto-generated notice" || { index_teardown; return 1; }

    index_teardown
}

# A column the README does not fill shows a dash: an unfilled `[...]`
# objective placeholder, and every column of an empty README.
test_index_dashes_unfilled_columns() {
    index_setup

    create_indexed_session "placeholder" "active" "[What is this session for?]"
    mkdir -p "$CS_SESSIONS_ROOT/empty/.cs"
    : > "$CS_SESSIONS_ROOT/empty/.cs/README.md"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CS_SESSIONS_ROOT/index.md" \
        '^| \[placeholder\](placeholder/.cs/README.md) | active | — | 2026-04-01 |$' \
        "a placeholder objective shows a dash" || { index_teardown; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/index.md" \
        '^| \[empty\](empty/.cs/README.md) | — | — | — |$' \
        "an empty README shows a dash in every column" || { index_teardown; return 1; }

    index_teardown
}


# ============================================================================
# timeline.jsonl
# ============================================================================

# The timeline append is best-effort. Redirections apply left to right, so
# with a trailing 2>/dev/null a failed `>>` reports before stderr moves; the
# braced form is what keeps a hook that cannot write quiet.
test_session_start_timeline_write_fails_quietly() {
    session_start_setup
    mkdir -p "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    echo '{"session_id":"abc","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>"$TEST_TMPDIR/stderr" || return 1
    assert_file_not_contains "$TEST_TMPDIR/stderr" "Is a directory" \
        "a timeline that cannot be appended to is not reported" || return 1
}

test_session_start_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Need README with frontmatter for full context
    cat > "$CLAUDE_SESSION_META_DIR/README.md" << 'EOF'
---
status: active
created: 2026-04-09
tags: []
aliases: ["test-session"]
---
# Session: test-session
EOF

    (cd "$CLAUDE_SESSION_DIR" && git init -q -b main && git config user.email t@t && git config user.name T && echo init > f && git add -A && git commit -q -m init) 2>/dev/null || true

    echo '{"session_id":"abc","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1

    assert_exists "$timeline" "timeline.jsonl should be created" || return 1
    # Should contain a started event
    if ! jq -e '. | select(.event == "started")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain a started event"
        echo "  Content: $(cat "$timeline")"
        return 1
    fi
}

test_session_end_appends_to_timeline() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    echo '{"session_id":"abc","reason":"prompt_input_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$timeline" "timeline.jsonl should be created on end" || return 1
    if ! jq -e '. | select(.event == "ended")' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: timeline should contain an ended event"
        return 1
    fi
}

test_timeline_events_are_valid_jsonl() {
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"

    # Write a fake event
    echo '{"ts":"2026-04-09T20:00:00Z","event":"started","source":"resume"}' >> "$timeline"
    echo '{"ts":"2026-04-09T20:30:00Z","event":"ended","source":"user_exit"}' >> "$timeline"

    # Each line must be valid JSON
    while IFS= read -r line; do
        if ! echo "$line" | jq -e . > /dev/null 2>&1; then
            echo "  FAIL: Invalid JSON line: $line"
            return 1
        fi
    done < "$timeline"
}

test_timeline_subagent_skipped() {
    # Subagents shouldn't write to parent's timeline
    # (test indirectly: session-start with agent_id should not append)
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    rm -f "$timeline"
    echo '{}' > "$CLAUDE_SESSION_META_DIR/README.md"

    # SubagentStart doesn't fire session-start, but if a subagent somehow invokes it
    # with agent_id in payload, the hook should skip the timeline append.
    # (This test documents the expectation even though in practice SubagentStart
    # is a different hook event.)
    echo '{"session_id":"abc","source":"startup","agent_id":"sub-123"}' \
        | bash "$HOOKS_DIR/session-start.sh" > /dev/null 2>&1 || true

    # Timeline should not exist or should not have a started event from this
    if [[ -f "$timeline" ]] && jq -e '. | select(.event == "started" and .subagent == true)' "$timeline" > /dev/null 2>&1; then
        echo "  FAIL: subagent invocation should not add timeline entry"
        return 1
    fi
}

# ============================================================================
# session-end.sh: the git-synced README must never receive machine-local
# timestamps — divergent per-machine writes made merge conflicts inevitable
# when a session is shared through git
# ============================================================================

test_session_end_never_stamps_readme() {
    index_setup

    local before
    before=$(cat "$CLAUDE_SESSION_META_DIR/README.md")

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_eq "$before" "$(cat "$CLAUDE_SESSION_META_DIR/README.md")" \
        "session end must leave README byte-identical" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_generates_index_with_many_changes() {
    # Regression: when git has 6+ uncommitted files, the FILE_LIST pipeline
    # used to trip SIGPIPE + pipefail, killing the script before index.md
    # was generated.
    index_setup

    # Create more than 5 uncommitted files in the session repo
    for i in 1 2 3 4 5 6 7 8; do
        echo "content $i" > "$CLAUDE_SESSION_DIR/file_$i.txt"
    done

    echo '{"session_id":"test-123","reason":"prompt_input_exit"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_exists "$CS_SESSIONS_ROOT/index.md" \
        "index.md should be generated even with 6+ uncommitted files" || { index_teardown; return 1; }

    index_teardown
}

# An encrypted session keeps its cs files behind .cs/private, a link into its
# vault. Every hook that writes the session log writes it there, and none
# writes a plaintext copy into .cs/local.
test_lifecycle_hooks_log_into_the_private_dir() {
    index_setup
    rm "$CLAUDE_SESSION_META_DIR/local/session.log"
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$CLAUDE_SESSION_META_DIR/private"
    _mark_hand_made_vault "$CLAUDE_SESSION_DIR"
    # A hand-made vault needs an untracked .cs/local; the fixture's commit took it in.
    git -C "$CLAUDE_SESSION_DIR" rm -rq --cached --ignore-unmatch .cs/local

    echo '{"session_id":"test-123","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1
    echo '{"tool_name":"Bash","error":"Command failed with exit code 1"}' \
        | bash "$HOOKS_DIR/tool-failure-logger.sh"
    echo '{"session_id":"test-123","reason":"clear"}' | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1

    local log="$TEST_TMPDIR/vault/private/session.log"
    assert_file_contains "$log" "Session started (source: startup, ID: test-123)" \
        "session-start should log into the private dir" || { index_teardown; return 1; }
    assert_file_contains "$log" "Tool failure: Bash" \
        "tool-failure-logger should log into the private dir" || { index_teardown; return 1; }
    assert_file_contains "$log" "Session ended (source: clear, ID: test-123)" \
        "session-end should log into the private dir" || { index_teardown; return 1; }
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/session.log" \
        "nothing may be logged in plaintext" || { index_teardown; return 1; }
    index_teardown
}

# A locked vault leaves the link dangling: the hooks still run, and write no
# log anywhere.
test_lifecycle_hooks_log_nothing_while_locked() {
    index_setup
    rm "$CLAUDE_SESSION_META_DIR/local/session.log"
    ln -s "$TEST_TMPDIR/unmounted/private" "$CLAUDE_SESSION_META_DIR/private"

    echo '{"tool_name":"Bash","error":"Command failed with exit code 1"}' \
        | bash "$HOOKS_DIR/tool-failure-logger.sh"
    echo '{"session_id":"test-123","reason":"clear"}' | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1

    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/session.log" \
        "nothing may be logged in plaintext" || { index_teardown; return 1; }
    assert_not_exists "$TEST_TMPDIR/unmounted" "nothing may be created where the vault mounts" \
        || { index_teardown; return 1; }
    index_teardown
}

# SessionEnd carries why the conversation ended in `reason` (clear, resume,
# logout, prompt_input_exit, other). The log and the timeline record that
# value, so a /clear is told apart from quitting.
test_session_end_records_the_end_reason() {
    index_setup

    echo '{"session_id":"test-123","reason":"clear"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/session.log" "Session ended (source: clear, ID: test-123)" \
        "the log names the reason Claude Code sent" || { index_teardown; return 1; }
    local recorded
    recorded=$(jq -r 'select(.event == "ended") | .source' "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_eq "clear" "$recorded" "the timeline records the same reason" || { index_teardown; return 1; }

    index_teardown
}

test_session_end_leaves_legacy_updated_line_alone() {
    index_setup

    # A legacy 'updated:' line (pre-dating the .cs/local/state split) is
    # migrate_session's to remove — the hook must not touch it either way
    sed -i.bak '/^tags:/a\
updated: 2026-01-01' "$CLAUDE_SESSION_META_DIR/README.md" && rm -f "$CLAUDE_SESSION_META_DIR/README.md.bak"

    echo '{"session_id":"test-123"}' | bash "$HOOKS_DIR/session-end.sh"

    assert_file_contains "$CLAUDE_SESSION_META_DIR/README.md" "updated: 2026-01-01" \
        "Hook must not rewrite a legacy updated line" || { index_teardown; return 1; }

    index_teardown
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs session hook tests"
echo "====================="
echo ""

# Discoveries archiver

# Session auto-approve
run_test test_narrative_reminder_approves_outside_session
run_test test_narrative_reminder_approves_when_recently_modified
run_test test_narrative_reminder_blocks_when_stale
run_test test_narrative_reminder_tracks_per_actor
run_test test_narrative_reminder_reads_mtimes_with_gnu_stat_on_a_mac
run_test test_narrative_reminder_asks_for_appended_corrections_not_rewrites
# Without the shared library the budget is unknown, and a warning built on a
# guessed budget is worse than none: the reminder runs and says nothing about
# size. (The actor line is SessionStart's to flag; a Stop hook has no channel.)
test_narrative_reminder_skips_the_budget_check_without_the_shared_library() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local partial="$TEST_TMPDIR/partial-hooks"
    mkdir -p "$partial"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    rm "$partial/cs-shared.sh"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$partial/narrative-reminder.sh")
    assert_output_contains "$output" "Narrative check" "the reminder itself still fires" || return 1
    assert_output_not_contains "$output" "over the" "no budget warning without the budget" || return 1
}

# The tracked-files notice is one hook run's answer. A value that came in with
# the environment changes nothing, even where no shared library loads to drop
# it: the Stop hook gives the turn the answer it gives without one.
test_stop_ignores_an_inherited_tracked_files_notice_without_the_shared_library() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    printf '# Session narrative (alice)\n' > "$nf"
    _backdate "$nf"
    local partial="$TEST_TMPDIR/partial-hooks"
    mkdir -p "$partial"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    rm "$partial/cs-shared.sh"
    local plain inherited
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    plain=$(echo '{}' | bash "$partial/narrative-reminder.sh")
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    inherited=$(echo '{}' | CS_TRACKED_FILES_NOTICE="x is tracked in git" CS_TRACKED_FILES_META="$CLAUDE_SESSION_META_DIR" \
        bash "$partial/narrative-reminder.sh")
    assert_output_contains "$plain" "Narrative check" "the reminder fires" || return 1
    assert_eq "$plain" "$inherited" "an inherited notice changes nothing" || return 1
}

run_test test_narrative_reminder_flags_a_narrative_over_budget
run_test test_narrative_reminder_names_a_narrative_as_a_plain_name
run_test test_stop_ignores_an_inherited_tracked_files_notice_without_the_shared_library
# A zero budget in any spelling is the default, not "warn on everything": the
# validator runs its zero check on the normalised number, and the hook reads
# the result rather than keeping a rule of its own.
test_narrative_reminder_reads_a_double_zero_budget_as_the_default() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=00 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "Narrative check" "the reminder itself still fires" || return 1
    assert_output_not_contains "$output" "over the" "00 is the default budget, and 3 KB is under it" || return 1
}

run_test test_narrative_reminder_skips_the_budget_check_without_the_shared_library
run_test test_narrative_reminder_reads_a_double_zero_budget_as_the_default
run_test test_narrative_reminder_reads_a_leading_zero_budget_as_decimal
run_test test_narrative_reminder_is_silent_about_budget_when_under
run_test test_narrative_reminder_survives_an_unreadable_narrative
run_test test_narrative_reminder_budget_line_covers_a_teammates_file
run_test test_narrative_reminder_respects_cooldown
run_test test_narrative_reminder_reads_its_cooldown_stamp_as_data
run_test test_stop_raises_attention_marker
run_test test_stop_no_attention_marker_for_subagents
run_test test_narrative_reminder_approves_for_subagent
run_test test_auto_approve_allows_cs_metadata_write
run_test test_auto_approve_allows_cs_edit
run_test test_auto_approve_ignores_non_cs_path
run_test test_auto_approve_ignores_non_write_tools
run_test test_auto_approve_rejects_traversal
run_test test_auto_approve_rejects_leaf_symlink
run_test test_auto_approve_rejects_a_hard_linked_target
run_test test_auto_approve_declines_a_target_whose_link_count_cannot_be_read
run_test test_auto_approve_names_a_control_link_before_a_hard_linked_target
run_test test_auto_approve_skips_outside_session
run_test test_auto_approve_rejects_pre_open
run_test test_auto_approve_rejects_local_state_files
run_test test_auto_approve_allows_pending_handoff_marker
run_test test_auto_approve_rejects_claude_config_and_keys
run_test test_auto_approve_private_allows_content_not_queue
run_test test_auto_approve_classifies_through_vault_links
run_test test_auto_approve_rejects_link_into_local
run_test test_auto_approve_rejects_executable_target
run_test test_auto_approve_rejects_linked_cs_dir
run_test test_auto_approve_rejects_case_variants
run_test test_auto_approve_prompts_for_a_reminder_stamp
run_test test_auto_approve_prompts_for_a_control_directory_name_taken_by_a_file
run_test test_auto_approve_prompts_for_the_open_lock
run_test test_auto_approve_prompts_for_the_archive_marker
run_test test_auto_approve_prompts_for_the_timeline
run_test test_auto_approve_prompts_for_instructions_at_the_root
run_test test_auto_approve_prompts_for_instructions_in_a_content_directory
run_test test_auto_approve_allows_the_first_write_into_a_content_directory
run_test test_auto_approve_prompts_for_the_first_write_into_any_other_directory
run_test test_auto_approve_prompts_for_a_new_plaintext_directory_in_an_encrypted_session
run_test test_auto_approve_allows_markdown_at_the_root
run_test test_auto_approve_prompts_for_a_non_ascii_name_in_content
run_test test_auto_approve_prompts_for_a_folded_control_name
run_test test_auto_approve_prompts_inside_a_git_directory_below_cs
run_test test_auto_approve_prompts_inside_a_git_directory_reached_by_another_name
run_test test_auto_approve_prompts_inside_any_directory_that_holds_head
run_test test_auto_approve_prompts_for_a_file_that_makes_its_directory_a_git_directory
run_test test_auto_approve_declines_without_the_shared_library
run_test test_auto_approve_prompts_for_a_git_file_name_in_any_order
run_test test_auto_approve_allows_ascii_content_under_a_non_ascii_session_path
run_test test_auto_approve_allows_content_in_a_session_below_a_git_named_directory
run_test test_auto_approve_rejects_config_linked_into_content
run_test test_auto_approve_rejects_settings_link_target
run_test test_auto_approve_rejects_queue_link_target
run_test test_auto_approve_rejects_settings_link_chain_target
run_test test_auto_approve_rejects_link_inside_linked_control_dir
run_test test_auto_approve_rejects_newline_link_chain
run_test test_auto_approve_rejects_link_hopping_through_session_root
run_test test_auto_approve_rejects_case_sibling_session
run_test test_auto_approve_rejects_project_claude_link_into_content
run_test test_auto_approve_rejects_project_hook_link_behind_dir_link
run_test test_auto_approve_rejects_mcp_link_to_new_content
run_test test_auto_approve_rejects_newline_real_parent
run_test test_auto_approve_rejects_queue_link_under_separate_meta_dir
run_test test_auto_approve_rejects_new_file_under_linked_claude_dir
run_test test_auto_approve_rejects_newline_file_path
run_test test_auto_approve_rejects_config_dir_inside_session
run_test test_auto_approve_rejects_git_dir_inside_content
run_test test_auto_approve_declines_on_any_control_link
run_test test_auto_approve_names_a_control_link_as_a_plain_path
run_test test_auto_approve_allows_content_without_links
run_test test_auto_approve_allows_cs_shared_config_links
run_test test_auto_approve_rejects_foreign_config_link
run_test test_auto_approve_allows_vaulted_session_content
run_test test_auto_approve_declines_on_config_debug_link
run_test test_auto_approve_skips_project_worktrees_only

# Subagent context
run_test test_subagent_injects_session_name
run_test test_subagent_injects_session_dir
run_test test_subagent_returns_valid_json
run_test test_subagent_skips_outside_session
run_test test_subagent_context_points_to_secret_store

# Tool failure logger
run_test test_failure_logged_to_session_log
run_test test_lifecycle_hooks_log_into_the_private_dir
run_test test_lifecycle_hooks_log_nothing_while_locked
run_test test_failure_log_has_timestamp
run_test test_failure_truncates_long_errors
run_test test_failure_handles_huge_multiline_error
run_test test_failure_skips_outside_session
run_test test_failure_handles_missing_error

# Session start: cross-session context
run_test test_test_lib_drops_an_inherited_tmux_and_routes_the_title_to_a_file
run_test test_session_start_teardown_keeps_the_title_off_the_terminal
run_test test_session_start_reasserts_tab_title_through_tmux
run_test test_two_cs_sessions_in_one_window_name_it_after_both
run_test test_each_pane_is_titled_with_its_own_session_alone
run_test test_a_claim_in_iterm_hands_the_window_to_the_tab_helper
run_test test_a_claim_outside_iterm_runs_no_tab_helper
run_test test_the_tab_helper_titles_the_one_tab_showing_the_window
run_test test_the_tab_helper_leaves_an_unsure_match_alone
run_test test_the_tab_helper_never_sets_an_empty_title
run_test test_the_tab_helper_sets_again_when_a_claim_lands_mid_run
run_test test_the_tab_helper_hands_the_window_back_when_the_last_claim_leaves_mid_run
run_test test_a_session_ending_leaves_the_window_to_the_others
run_test test_concurrent_claims_leave_the_name_the_claims_make
run_test test_an_unmakeable_lock_still_names_the_window_in_bounded_time
run_test test_a_launch_in_a_second_pane_joins_the_window_name
run_test test_a_launch_cleanup_releases_its_pane_and_keeps_the_others_title
run_test test_a_claim_after_the_last_release_locks_the_titles_again
run_test test_a_non_lead_end_leaves_the_pane_claimed
run_test test_session_start_tab_title_leaves_a_teammate_pane_alone
run_test test_session_start_reasserts_tab_title_on_the_terminal_device
run_test test_session_start_tab_title_skips_silently_without_a_terminal
run_test test_session_start_warns_about_an_over_budget_narrative
run_test test_session_start_names_a_teammate_narrative_over_budget_as_theirs
run_test test_session_start_names_a_narrative_over_budget_as_a_plain_name
run_test test_session_start_is_silent_when_narratives_fit
run_test test_session_start_survives_a_leading_zero_budget_override
run_test test_session_start_emits_session_state_on_resume
run_test test_session_start_emits_session_state_in_a_worktree
run_test test_session_start_resume_warns_of_actions_its_summary_omits
run_test test_session_start_announces_worktree_task
run_test test_session_start_worktree_block_needs_at_shaped_name
run_test test_session_start_no_worktree_block_for_plain_sessions
run_test test_session_start_worktree_abandon_is_user_gated
run_test test_session_start_crash_recovery_warns_before_overwrite
run_test test_session_start_crash_count_reflects_all_files
run_test test_subagent_context_announces_worktree_task
run_test test_subagent_context_deliverable_is_final_message
run_test test_session_start_narrative_is_per_actor
run_test test_session_start_secrets_guidance_is_stdin_and_backend_neutral
run_test test_resume_digest_reports_memory_activity
run_test test_resume_digest_names_an_author_as_a_plain_name
run_test test_resume_digest_silent_without_watermark
run_test test_resume_digest_names_where_a_teammates_narrative_grew
run_test test_resume_digest_passes_over_a_narrative_whose_name_is_not_plain
run_test test_resume_digest_passes_over_a_narrative_that_is_a_link
run_test test_session_start_lists_only_recent_files_with_plain_names
run_test test_session_start_checks_at_most_five_recent_files
run_test test_resume_digest_delta_survives_a_rotated_teammate_narrative
run_test test_resume_digest_counts_two_commits_and_an_uncommitted_tail
run_test test_hooks_parse_under_bin_bash
run_test test_resume_digest_reports_uncommitted_teammate_growth
run_test test_resume_digest_says_nothing_about_an_untracked_teammate_narrative
run_test test_session_start_writes_nothing_into_a_control_directory_git_tracks
run_test test_hooks_mark_the_session_while_git_tracks_its_control_files
run_test test_resume_digest_start_line_ignores_a_head_edit
run_test test_resume_digest_works_when_the_session_is_a_repo_subdirectory
run_test test_resume_digest_silent_when_nothing_changed
run_test test_session_start_includes_sibling_sessions
run_test test_session_start_excludes_current_session
run_test test_session_start_sibling_block_mandates_asking
run_test test_session_start_sibling_line_carries_the_send_syntax
run_test test_session_start_shows_objectives
run_test test_session_start_limits_sibling_count
run_test test_session_start_updates_last_resumed
run_test test_session_start_last_resumed_not_set_on_startup
run_test test_session_start_skips_siblings_on_startup
run_test test_session_start_clears_attention_marker
run_test test_session_start_rebinds_uuid_to_live_session
run_test test_session_start_rebinds_uuid_on_startup
run_test test_session_start_rebind_ignores_invalid_session_id
run_test test_session_start_rebinds_for_a_claude_cs_spawned
run_test test_session_start_rebind_declines_for_child_claude
run_test test_session_start_rebind_declines_for_a_live_foreign_parent
run_test test_session_start_rebind_declines_without_lead_pid
run_test test_session_start_rebind_declines_when_neither_pid_is_set

# Session end: index.md generation
run_test test_session_end_generates_index
run_test test_index_lists_all_sessions
run_test test_index_shows_objectives
run_test test_index_shows_status
run_test test_index_has_auto_generated_notice
run_test test_index_dashes_unfilled_columns

# Timeline
run_test test_session_start_appends_to_timeline
run_test test_session_start_timeline_write_fails_quietly

# ============================================================================
# session-start.sh: CS_FRESH_REBIND signal — tailored additionalContext when
# the user declined to resume the prior conversation
# ============================================================================

test_session_start_fresh_rebind_injects_clean_break_notice() {
    session_start_setup

    local output context
    output=$(CS_FRESH_REBIND=1 \
        echo '{"session_id":"test","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | CS_FRESH_REBIND=1 bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if ! grep -q "Fresh Conversation" <<< "$context"; then
        echo "  FAIL: fresh-rebind context block missing"
        echo "  Context tail: $(echo "$context" | tail -8)"
        session_start_teardown
        return 1
    fi
    if ! grep -q "clean break" <<< "$context"; then
        echo "  FAIL: fresh-rebind block should mention the clean break"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

test_session_start_without_fresh_rebind_omits_clean_break_notice() {
    session_start_setup

    # No CS_FRESH_REBIND env — context must NOT include the block.
    local output context
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

    if grep -q "Fresh Conversation" <<< "$context"; then
        echo "  FAIL: fresh-rebind block must not appear when CS_FRESH_REBIND is unset"
        session_start_teardown
        return 1
    fi

    session_start_teardown
}

run_test test_session_start_fresh_rebind_injects_clean_break_notice
run_test test_session_start_without_fresh_rebind_omits_clean_break_notice
run_test test_session_end_appends_to_timeline
run_test test_timeline_events_are_valid_jsonl
run_test test_timeline_subagent_skipped

# Session end: updated timestamp
run_test test_session_end_never_stamps_readme
run_test test_session_end_generates_index_with_many_changes
run_test test_session_end_records_the_end_reason
run_test test_session_end_leaves_legacy_updated_line_alone

# ============================================================================
# Retired-hooks cleanup (install.sh + run_uninstall)
# ============================================================================

# The two tests below run cs's own code, sourced from lib/: the uninstaller's
# pass over every hook name (_strip_cs_hook_registrations), which strips each
# one whose file is gone and then drops the events left with nothing, and the
# strip filter that pass and install.sh share (_strip_hook_registration).
test_retired_hooks_strip_settings_json() {
    # Settings.json with one retired hook whose file is gone (PreCompact only)
    # and one hook whose file is still in the flat hooks directory, so its
    # registration stays (PostToolUse)
    local settings='{"hooks":{"PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10}]}],"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local parent="$TEST_TMPDIR/hooks"
    mkdir -p "$parent/cs"
    : > "$parent/discovery-commits.sh"
    local stripped
    stripped=$(. "$SCRIPT_DIR/../lib/01-manifests.sh" && . "$SCRIPT_DIR/../lib/85-adopt-uninstall.sh" \
        && echo "$settings" | _strip_cs_hook_registrations "$parent/cs" "$parent")
    if echo "$stripped" | jq -e '.hooks.PreCompact' >/dev/null 2>&1; then
        echo "  FAIL: PreCompact event should be empty/gone after stripping its only (retired) hook"
        echo "  got: $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[0].command' >/dev/null 2>&1; then
        echo "  FAIL: PostToolUse should still have its (current) hook after stripping unrelated retired"
        return 1
    fi
}

test_retired_hooks_strip_preserves_coexisting_hook() {
    # Two hooks under SAME event — one retired, one current. Only the retired should be stripped.
    local settings='{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/discoveries-archiver.sh","timeout":10},{"type":"command","command":"~/.claude/hooks/discovery-commits.sh","timeout":10}]}]}}'
    local p="$HOME/.claude/hooks/discoveries-archiver.sh"
    local t="~/.claude/hooks/discoveries-archiver.sh"
    local stripped
    stripped=$(. "$SCRIPT_DIR/../lib/01-manifests.sh" && _strip_hook_registration "$settings" "$p" "$t")
    local remaining_count
    remaining_count=$(echo "$stripped" | jq '.hooks.PostToolUse[0].hooks | length')
    if [ "$remaining_count" != "1" ]; then
        echo "  FAIL: expected 1 hook to remain in PostToolUse[0], got $remaining_count"
        echo "  $stripped"
        return 1
    fi
    if ! echo "$stripped" | jq -e '.hooks.PostToolUse[0].hooks[] | select(.command | contains("discovery-commits"))' >/dev/null 2>&1; then
        echo "  FAIL: discovery-commits entry should remain"
        return 1
    fi
}

run_test test_retired_hooks_strip_settings_json
run_test test_retired_hooks_strip_preserves_coexisting_hook

# ============================================================================
# install.sh: cs-hook merge must preserve co-shipped non-cs entries inside
# the same {hooks: [...]} wrapper. Spec tests — embed the exact jq filter
# install.sh must use.
# ============================================================================

# Filter shape documented here as the source of truth. install.sh's 12
# event-specific filters must follow the same pattern: dive into nested
# .hooks, strip only the matching command, drop wrappers that emptied out,
# leave flat or unrelated wrappers untouched, then append the cs entry.
_install_merge_filter() {
    cat << 'JQ'
if .hooks[$event] != null and (.hooks[$event] | type) != "array" then
    error("hooks.\($event) is not a list")
else
    .hooks[$event] = (
        ((.hooks[$event] // []) | map(
            if type == "object" and (.hooks | type) == "array" then
                .hooks |= map(select(type != "object" or (.command != $path and .command != $tilde)))
            else . end
        ) | map(select(type != "object" or (.hooks | type) != "array" or (.hooks | length > 0))))
        + [{ "hooks": [{ "type": "command", "command": $tilde, "timeout": $timeout }] }]
    )
end
JQ
}

# A jq filter text on stdin without its indentation, blank lines or the line
# that appends cs's entry (install.sh.in appends $append, the copy above a
# fixed wrapper), on stdout.
_merge_filter_strip_and_drop_lines() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v -e '^$' -e '^+ \['
}

# The spec tests below run the copy above, never install.sh.in, so they say
# something about the installer only while the two texts are the same: the
# lines of _merge_cs_hook's filter that strip and drop are compared with the
# copy's.
test_install_merge_filter_copy_matches_install_sh_in() {
    local theirs ours
    theirs=$(awk '
        /^[ \t]*_merge_cs_hook\(\) \{/ { infn=1 }
        infn && /--argjson append "\$append" '\''$/ { grab=1; next }
        grab {
            if ($0 ~ /^[ \t]*'\''\)/) exit
            print
        }
    ' "$SCRIPT_DIR/../install.sh.in" | _merge_filter_strip_and_drop_lines)
    ours=$(_install_merge_filter | _merge_filter_strip_and_drop_lines)
    assert_eq "$theirs" "$ours" "the copy of the merge filter matches install.sh.in" || return 1
}

# An event whose value is not a list is the user's: the merge stops, naming
# the event, rather than rewrite it. A null event is one the merge creates.
test_install_merge_stops_on_an_event_that_is_not_a_list() {
    # shellcheck disable=SC2088  # the spelling settings.json holds, never expanded
    local tilde="~/.claude/hooks/session-start.sh" value out rc
    for value in '{"custom":{"hooks":[]}}' 'false' '"notify"' '7'; do
        rc=0
        out=$(jq -n --argjson value "$value" '{hooks: {SessionStart: $value}}' | jq -c \
            --arg event "SessionStart" --arg path "$HOME/.claude/hooks/session-start.sh" \
            --arg tilde "$tilde" --argjson timeout 30 "$(_install_merge_filter)" 2>&1) || rc=$?
        assert_eq "5" "$rc" "jq exit status for the value $value" || { echo "$out"; return 1; }
        assert_output_contains "$out" "^jq: error (at <stdin>:[0-9]*): hooks\.SessionStart is not a list$" \
            "the error names the event for the value $value" || return 1
    done
    out=$(echo '{"hooks":{"SessionStart":null}}' | jq -c \
        --arg event "SessionStart" --arg path "$HOME/.claude/hooks/session-start.sh" \
        --arg tilde "$tilde" --argjson timeout 30 "$(_install_merge_filter)" 2>&1)
    assert_eq '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}]}}' "$out" \
        "a null event becomes the list holding cs's entry" || return 1
}

test_install_preserves_coshipped_hook_in_wrapper() {
    # User has a non-cs hook co-located inside the same wrapper as cs's hook.
    # Common pattern when the user hand-edited settings.json to add another
    # hook next to cs's. The merge must NOT drop the user's hook.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings
    settings=$(cat << EOF
{"hooks":{"SessionStart":[{"hooks":[
  {"type":"command","command":"~/bin/claude-status","timeout":5},
  {"type":"command","command":"$tilde","timeout":30}
]}]}}
EOF
)
    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local user_hook_count
    user_hook_count=$(echo "$result" | jq '[.. | objects | select(.command == "~/bin/claude-status")] | length')
    if [ "$user_hook_count" != "1" ]; then
        echo "  FAIL: claude-status should survive merge exactly once, got $user_hook_count"
        echo "  Result: $result"
        return 1
    fi

    local cs_hook_count
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')
    if [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: cs hook should appear exactly once, got $cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_drops_emptied_wrapper_when_only_cs_hook_present() {
    # Pre-existing standalone wrapper containing only cs's hook. After merge,
    # we want exactly one wrapper containing one cs entry — not two.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/session-start.sh","timeout":30}]}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    local wrapper_count cs_hook_count
    wrapper_count=$(echo "$result" | jq '.hooks.SessionStart | length')
    cs_hook_count=$(echo "$result" | jq --arg t "$tilde" '[.. | objects | select(.command == $t)] | length')

    if [ "$wrapper_count" != "1" ] || [ "$cs_hook_count" != "1" ]; then
        echo "  FAIL: expected 1 wrapper + 1 cs entry; got wrappers=$wrapper_count cs_entries=$cs_hook_count"
        echo "  Result: $result"
        return 1
    fi
}

test_install_leaves_flat_entries_alone() {
    # Old-shape flat entries (no .hooks nesting) must pass through untouched.
    local path="$HOME/.claude/hooks/session-start.sh"
    local tilde="~/.claude/hooks/session-start.sh"
    local settings='{"hooks":{"SessionStart":[{"type":"command","command":"~/bin/claude-status","timeout":5}]}}'

    local result
    result=$(echo "$settings" | jq \
        --arg event "SessionStart" \
        --arg path "$path" \
        --arg tilde "$tilde" \
        --argjson timeout 30 \
        "$(_install_merge_filter)")

    if ! echo "$result" | jq -e '.hooks.SessionStart[] | select(.command == "~/bin/claude-status")' >/dev/null; then
        echo "  FAIL: flat-shape claude-status entry was dropped"
        echo "  Result: $result"
        return 1
    fi
}

run_test test_install_merge_filter_copy_matches_install_sh_in
run_test test_install_merge_stops_on_an_event_that_is_not_a_list
run_test test_install_preserves_coshipped_hook_in_wrapper
run_test test_install_drops_emptied_wrapper_when_only_cs_hook_present
run_test test_install_leaves_flat_entries_alone

# ============================================================================
# session-start.sh: the actor identity anchor
#
# .cs/memory/ is one shared store for every actor on a git-synced session, but
# only narratives are partitioned. A `type: user` memory written by one actor
# ("the user is X, not Y") loads for all of them and reads as settled fact.
# Naming the current actor up front is what keeps identity a question the live
# signals answer, instead of one a stale memory has already closed.
# ============================================================================

_identity_hook() {  # [source]
    echo "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"${1:-startup}\"}" \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
}

_seed_identity_git() {  # email
    git -C "$CLAUDE_SESSION_DIR" init -q 2>/dev/null || mkdir -p "$CLAUDE_SESSION_DIR"
    git -C "$CLAUDE_SESSION_DIR" config user.email "$1" 2>/dev/null
}

test_session_start_names_the_current_actor() {
    _seed_identity_git "john.doe@example.com"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "john.doe@example.com" \
        "the actor's identity is stated, not left to be looked up" || return 1
    assert_output_contains "$out" "narrative.john-doe-example-com.md" \
        "the actor's own narrative file is named" || return 1
}

test_session_start_warns_that_memory_is_shared() {
    _seed_identity_git "john.doe@example.com"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "shared by multiple actors" \
        "the store's multi-actor nature is disclosed" || return 1
    assert_output_contains "$out" "was written by or for another actor" \
        "a conflicting identity memory has an explicit resolution rule" || return 1
}

# A pinned .cs/local/identity outranks git config, matching cs_actor_slug's
# precedence. Without this the anchor would name the wrong person on a machine
# whose git identity differs from the session's pinned one.
test_session_start_actor_honours_pinned_identity() {
    _seed_identity_git "john.doe@example.com"
    printf 'jane.roe@example.com\n' > "$CLAUDE_SESSION_META_DIR/local/identity"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "jane.roe@example.com" \
        "pinned identity outranks git config" || return 1
    assert_output_not_contains "$out" "john.doe@example.com" \
        "the overridden git identity is not also announced" || return 1
}

# cs_actor_slug() ends its search on the identity file EXISTING, not on it
# yielding a value, so a blank pin resolves to "unknown" with no git fallback.
# The hook must stop at the same place: naming an actor cs never resolves would
# point Claude at a narrative file cs does not write.
test_session_start_actor_matches_cs_on_a_blank_pin() {
    _seed_identity_git "john.doe@example.com"
    printf '' > "$CLAUDE_SESSION_META_DIR/local/identity"
    local out
    out=$(_identity_hook)
    assert_output_contains "$out" "Current actor: unknown" \
        "a blank pin resolves to unknown, as cs_actor_slug does" || return 1
    assert_output_not_contains "$out" "john-doe-example-com" \
        "a blank pin must not fall through to git config" || return 1
}

run_test test_session_start_names_the_current_actor
test_session_start_arms_the_mail_watcher() {
    session_start_setup
    # A session that has never exchanged mail has no maildir, and the watcher is
    # handed its path with no existence check: armed on a path missing two
    # levels it never fires again for the process's lifetime. So the fixture
    # must start without one, which is the state of every fresh spawn worker.
    [ ! -d "$CLAUDE_SESSION_META_DIR/local/mail" ] \
        || { echo "  fixture already had a maildir; the test would prove nothing"; session_start_teardown; return 1; }

    local output rc=0
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)

    assert_dir "$CLAUDE_SESSION_META_DIR/local/mail/new" \
        "session start creates the maildir before asking for it to be watched" || rc=1
    local wp
    wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths[0] // ""')
    # Assert which directory the watch lands on, not how it is spelled. Under
    # a path can reach jq through argv translation and come back spelled as a
    # different absolute form for the same directory
    # there. A string compare fails on the spelling while the watch is armed on
    # exactly the right place, so prove identity with a file instead.
    if [ -z "$wp" ]; then
        echo "  FAIL: watchPaths is empty; the maildir was never armed"; rc=1
    else
        local token="watch-probe-$$"
        : > "$CLAUDE_SESSION_META_DIR/local/mail/new/$token"
        [ -f "$wp/$token" ] \
            || { echo "  FAIL: watchPaths does not name the maildir session start created"
                 echo "    watchPaths: $wp"
                 echo "    maildir   : $CLAUDE_SESSION_META_DIR/local/mail/new"; rc=1; }
        rm -f "$CLAUDE_SESSION_META_DIR/local/mail/new/$token"
    fi
    session_start_teardown
    return $rc
}

test_session_start_does_not_arm_the_watcher_for_a_teammate() {
    session_start_setup
    local output
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | env -u CS_LEAD_PID -u CLAUDE_PID bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    local wp; wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths // "none"')
    session_start_teardown
    assert_eq "none" "$wp" \
        "a teammate arms no watcher: one arrival must not wake every claude on the session" || return 1
}


# An encrypted session's mailbox is in its vault: the watch goes there, and a
# locked vault gets no watch rather than a plaintext maildir beside it.
test_session_start_arms_the_vault_maildir() {
    session_start_setup
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$CLAUDE_SESSION_META_DIR/private"
    _mark_hand_made_vault "$CLAUDE_SESSION_DIR"
    # A hand-made vault needs an untracked .cs/local; the fixture's commit took it in.
    git -C "$CLAUDE_SESSION_DIR" rm -rq --cached --ignore-unmatch .cs/local
    local output wp rc=0
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths[0] // ""')
    assert_eq "$CLAUDE_SESSION_META_DIR/private/mail/new" "$wp" "the watch is on the vault's maildir" || rc=1
    assert_dir "$TEST_TMPDIR/vault/private/mail/new" "created before it is armed" || rc=1
    assert_not_exists "$CLAUDE_SESSION_META_DIR/local/mail" "no plaintext maildir" || rc=1
    session_start_teardown
    return $rc
}

test_session_start_arms_no_watch_on_a_locked_vault() {
    session_start_setup
    ln -s "$TEST_TMPDIR/unmounted/private" "$CLAUDE_SESSION_META_DIR/private"
    local output wp rc=0
    output=$(echo '{"session_id":"s","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    wp=$(echo "$output" | jq -r '.hookSpecificOutput.watchPaths // "none"')
    assert_eq "none" "$wp" "a locked vault arms no watch" || rc=1
    assert_not_exists "$CLAUDE_SESSION_META_DIR/local/mail" "no plaintext maildir" || rc=1
    session_start_teardown
    return $rc
}

run_test test_session_start_arms_the_mail_watcher
run_test test_session_start_does_not_arm_the_watcher_for_a_teammate
run_test test_session_start_arms_the_vault_maildir
run_test test_session_start_arms_no_watch_on_a_locked_vault
run_test test_session_start_warns_that_memory_is_shared
# The shared library ships beside the hooks; a partial deployment (an older
# ~/.claude/hooks/cs/ under a newer session-start.sh) has the hook without it.
# The hook must not carry its own copy of the actor rules as a fallback (that
# copy is the drift this library removed), so it says what is missing and what
# redeploys it, and names no actor cs would not.
test_session_start_says_what_to_run_when_the_shared_library_is_missing() {
    _seed_identity_git "john.doe@example.com"
    local partial="$TEST_TMPDIR/partial-hooks"
    mkdir -p "$partial"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    rm "$partial/cs-shared.sh"
    local out err="$TEST_TMPDIR/partial-hook.err" state="$CLAUDE_SESSION_META_DIR/local/state"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    printf 'claude_session_id: 99999999-8888-4777-8666-555555555555\n' > "$state"
    # As the launched claude, so the hook reaches the rebind.
    out=$(echo "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$CLAUDE_SESSION_DIR\",\"source\":\"startup\"}" \
        | CS_LEAD_PID=$$ CLAUDE_PID=$$ bash "$partial/session-start.sh" 2>"$err")
    assert_output_contains "$out" "Current actor: unknown" \
        "no actor is guessed without the shared rules" || return 1
    assert_output_not_contains "$out" "john-doe-example-com" \
        "the hook must not resolve the actor from its own copy of the rules" || return 1
    assert_output_contains "$out" "cs-shared.sh" "names the missing library" || return 1
    assert_output_contains "$out" "install.sh" "names what redeploys it" || return 1
    assert_eq "claude_session_id: 99999999-8888-4777-8666-555555555555" "$(cat "$state")" \
        "the state is left as it was without the locked writer" || return 1
    assert_file_contains "$err" "cs-shared.sh is missing or outdated, so claude_session_id was not recorded" \
        "the hook says the binding was not recorded" || return 1
}

run_test test_session_start_actor_honours_pinned_identity
run_test test_session_start_actor_matches_cs_on_a_blank_pin
run_test test_session_start_says_what_to_run_when_the_shared_library_is_missing

# CS_SESSIONS_ROOT is read by session-end.sh but never exported into a session,
# so `dirname "$SESSION_DIR"` always decides. That is right for a session under
# the sessions root and wrong for an adopted one, whose real directory lives at
# an unrelated project path: the index then lands in that project's parent.
test_session_end_does_not_write_index_beside_an_adopted_session() {
    local proj="$TEST_TMPDIR/code/my-project"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    printf 'session_name: adopted-one\n' > "$proj/.cs/local/state"
    printf -- '---\nstatus: active\ncreated: 2026-07-30\n---\n# Session: adopted-one\n' > "$proj/.cs/README.md"

    unset CS_SESSIONS_ROOT
    export CLAUDE_SESSION_NAME="adopted-one"
    export CLAUDE_SESSION_DIR="$proj"
    export CLAUDE_SESSION_META_DIR="$proj/.cs"

    echo "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    [ ! -f "$TEST_TMPDIR/code/index.md" ] \
        || { echo "  FAIL: index.md written into the adopted project's parent"; return 1; }
}

run_test test_session_end_does_not_write_index_beside_an_adopted_session

# The containment check compares SESSION_DIR against the sessions root. The
# resolver reports physical paths but the CLI exports a logical SESSION_DIR
# built from $HOME, so normalizing only one side stops the index being written
# for any home reached through a symlink (/home -> /var/home, and every
# /tmp-based test environment).
test_session_end_writes_index_when_home_traverses_a_symlink() {
    local fh="$TEST_TMPDIR/symhome" phys
    mkdir -p "$fh/.claude-sessions/sess/.cs/local"
    printf -- '---\nstatus: active\ncreated: 2026-07-30\n---\n# Session: sess\n' \
        > "$fh/.claude-sessions/sess/.cs/README.md"
    phys=$(cd "$fh" && pwd -P)

    env -i HOME="$fh" PATH="$PATH" \
        CLAUDE_SESSION_NAME=sess CLAUDE_SESSION_DIR="$fh/.claude-sessions/sess" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$fh\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ -f "$phys/.claude-sessions/index.md" ] \
        || { echo "  FAIL: index not written when \$HOME traverses a symlink"; return 1; }
}

run_test test_session_end_writes_index_when_home_traverses_a_symlink

# The sessions-root default reads $HOME, which main never did, so under set -u an
# unset HOME turns a step that should skip into an abort. cs-resolve.sh already
# guards HOME; this must match it.
test_session_end_survives_an_unset_home() {
    local proj="$TEST_TMPDIR/nohome/sess"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    env -i PATH="$PATH" CLAUDE_SESSION_NAME=sess CLAUDE_SESSION_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: session-end exited $rc with HOME unset"; return 1; }
}

run_test test_session_end_survives_an_unset_home

# Before hooks resolved a session from the directory, a second front end never
# reached SessionEnd for a session it did not launch. Now closing a desktop
# conversation on a directory a CLI session is live in would remove that
# session's lock, so `cs <name>` opens a duplicate with no collision menu.
test_session_end_spares_a_live_sessions_lock() {
    local proj="$TEST_TMPDIR/.claude-sessions/lockheld"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    # $$ is this test runner: a PID that is definitely alive.
    printf '%s\n' "$$" > "$proj/.cs/session.lock"

    # The real scenario: another front end resolves by WALKING the directory,
    # so no session env is set. A cs launch (env path) still clears its own lock.
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ -f "$proj/.cs/session.lock" ] \
        || { echo "  FAIL: a live session's lock was removed by another front end"; return 1; }
}

# A lock left by a process that is gone is exactly what SessionEnd should clear.
test_session_end_clears_a_stale_lock() {
    local proj="$TEST_TMPDIR/.claude-sessions/lockstale"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    # A PID that cannot be running: start a shell and let it exit.
    local dead
    dead=$( ( exec /bin/bash -c 'echo $$' ) )
    printf '%s\n' "$dead" > "$proj/.cs/session.lock"

    env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
        /bin/bash "$HOOKS_DIR/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || true

    [ ! -f "$proj/.cs/session.lock" ] \
        || { echo "  FAIL: a stale lock was left behind"; return 1; }
}

# SessionEnd reads the lock by live_lock_pid's rule: "0" and "-1" name process
# groups and "+<pid>" is not a pid, so each is a stale lock to clear.
test_session_end_reads_the_lock_by_the_one_lock_rule() {
    local proj="$TEST_TMPDIR/.claude-sessions/lockrule"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    local text
    for text in "0" "-1" "+$$"; do
        printf '%s\n' "$text" > "$proj/.cs/session.lock"
        env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
            /bin/bash "$HOOKS_DIR/session-end.sh" \
            <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
            >/dev/null 2>&1 || true
        [ ! -f "$proj/.cs/session.lock" ] \
            || { echo "  FAIL: a lock of '$text' was left behind: $(cat "$proj/.cs/session.lock")"; return 1; }
    done
}

# A cs-shared.sh from before live_lock_pid shipped in it, under a newer
# session-end.sh, cannot tell a live lock from a stale one, so the hook
# leaves the lock to the next open rather than remove a live session's.
test_session_end_without_the_lock_rule_leaves_the_lock() {
    local partial="$TEST_TMPDIR/partial-hooks"
    mkdir -p "$partial"
    cp "$HOOKS_DIR"/*.sh "$partial/"
    printf '\nunset -f live_lock_pid\n' >> "$partial/cs-shared.sh"
    local proj="$TEST_TMPDIR/.claude-sessions/lockrule-old"
    mkdir -p "$proj/.cs/local"
    touch "$proj/.cs/local/session.log"
    printf '%s\n' "$$" > "$proj/.cs/session.lock"
    local rc=0
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" CLAUDE_PROJECT_DIR="$proj" \
        /bin/bash "$partial/session-end.sh" \
        <<< "{\"session_id\":\"11111111-2222-4333-8444-555555555555\",\"cwd\":\"$proj\",\"source\":\"user_exit\"}" \
        >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the hook runs to its end" || return 1
    assert_eq "$$" "$(cat "$proj/.cs/session.lock" 2>/dev/null)" "the live lock is left as it was" || return 1
}

run_test test_session_end_spares_a_live_sessions_lock
run_test test_session_end_clears_a_stale_lock
run_test test_session_end_reads_the_lock_by_the_one_lock_rule
run_test test_session_end_without_the_lock_rule_leaves_the_lock

# `cs -rm <name> --force` can land while the claude it removes is still ending:
# its SessionEnd has already found the session directory and goes on writing.
# Nothing it writes may bring the directory back, or the picker shows an empty
# shell holding the end's log line, timeline event and lock files. A DEBUG trap
# loaded through BASH_ENV removes the directory before the hook's Nth command,
# for every N the hook runs, so wherever the removal lands is covered without
# naming a line or a command of the hook. The hook runs under the bash running
# this suite; run the suite under /bin/bash too for cs's 3.2 floor.
test_session_end_never_recreates_a_removed_session() {
    local seam="$TEST_TMPDIR/remove-at-step.sh" root="$TEST_TMPDIR/rm-sessions"
    local dir="$root/ending" steps_file="$TEST_TMPDIR/steps" sh="$BASH" steps n rc
    cat > "$seam" << 'SEAM'
_cs_test_step=0
_cs_test_remove_at_step() {
    case "$1" in */session-end.sh) ;; *) return 0 ;; esac
    _cs_test_step=$((_cs_test_step + 1))
    if [ "$_cs_test_step" = "${CS_TEST_REMOVE_AT:-}" ]; then
        rm -rf "$CS_TEST_REMOVE_DIR"
        : > "$CS_TEST_REMOVED_MARK"
    fi
    printf '%s\n' "$_cs_test_step" > "$CS_TEST_STEPS_FILE"
    return 0
}
trap '_cs_test_remove_at_step "${BASH_SOURCE[0]:-}"' DEBUG
SEAM
    _stage_ending_session() {
        rm -rf "$dir"
        mkdir -p "$dir/.cs/local"
        printf '# Session: ending\n' > "$dir/.cs/README.md"
        : > "$dir/.cs/local/session.log"
        printf '%s\n' "$$" > "$dir/.cs/session.lock"
    }
    _run_ending_hook() {  # bash, step to remove at ("" for none)
        env -i HOME="$TEST_TMPDIR" PATH="$PATH" CS_SESSIONS_ROOT="$root" \
            CLAUDE_SESSION_NAME=ending CLAUDE_SESSION_DIR="$dir" \
            CS_RESOLVED_FROM=env CS_LEAD_PID=$$ CLAUDE_PID=$$ \
            BASH_ENV="$seam" CS_TEST_REMOVE_AT="$2" CS_TEST_REMOVE_DIR="$dir" \
            CS_TEST_REMOVED_MARK="$TEST_TMPDIR/removed" CS_TEST_STEPS_FILE="$steps_file" \
            "$1" "$HOOKS_DIR/session-end.sh" \
            <<< '{"session_id":"11111111-2222-4333-8444-555555555555","reason":"other"}' \
            >/dev/null 2>&1
    }
    mkdir -p "$root"
    # Positive control: untouched, the hook writes its end into the session.
    _stage_ending_session
    _run_ending_hook "$sh" "" || { echo "  FAIL: $sh: session-end failed with no removal"; return 1; }
    assert_file_contains "$dir/.cs/timeline.jsonl" '"event":"ended"' \
        "$sh: the hook records the end when the session stays" || return 1
    steps=$(cat "$steps_file")
    [ "$steps" -ge 20 ] || { echo "  FAIL: $sh: the seam counted only $steps hook commands"; return 1; }
    n=1
    while [ "$n" -le "$steps" ]; do
        _stage_ending_session
        rm -f "$TEST_TMPDIR/removed"
        rc=0
        _run_ending_hook "$sh" "$n" || rc=$?
        assert_exists "$TEST_TMPDIR/removed" "$sh: the session was removed before hook command $n" || return 1
        assert_eq "0" "$rc" "$sh: session-end exits 0 when the session goes before command $n" || return 1
        if [ -e "$dir" ]; then
            echo "  FAIL: $sh: removed before hook command $n of $steps, the session came back holding: $(cd "$root" && find ending | tr '\n' ' ')"
            return 1
        fi
        n=$((n + 1))
    done
}

run_test test_session_end_never_recreates_a_removed_session

# The Stop hook runs at every turn end and raises .cs/local/attention after it
# has found the session, so a `cs -rm <name> --force` landing while a turn ends
# meets the same window as SessionEnd. A DEBUG trap loaded through BASH_ENV
# removes the session before the hook's Nth command, for every N. functrace
# carries the trap into functions, sourced files and command substitutions, so
# N also lands inside the library's writers, between their checks and their
# mkdir; the control run proves the trap fired inside cs_mkdir_inside. Each
# command appends one byte to a file every process of the run shares, and the
# file's size is the count, so a command substitution and a pipeline count on
# from their parent. Wherever the removal lands, the hook exits 0 with its
# approval and the session stays removed. Untouched, the hook makes the missing
# .cs/local and raises the marker in it. Eight runs at a time, each in its own
# directory; the hook runs under the bash running this suite.
test_stop_never_recreates_a_removed_session() {
    local seam="$TEST_TMPDIR/remove-at-step.sh" work="$TEST_TMPDIR/rm-steps" sh="$BASH"
    local steps n first w pids ran
    cat > "$seam" << 'SEAM'
set -o functrace
_cs_test_remove_at_step() {
    local seen=""
    [ -n "${CS_TEST_STEPS_FILE:-}" ] || return 0
    printf x >> "$CS_TEST_STEPS_FILE"
    [ "${FUNCNAME[1]:-}" != cs_mkdir_inside ] || : > "$CS_TEST_STEPS_FILE.in-writer"
    [ -n "${CS_TEST_REMOVE_AT:-}" ] || return 0
    [ ! -e "$CS_TEST_STEPS_FILE.removed" ] || return 0
    IFS= read -r -d '' seen < "$CS_TEST_STEPS_FILE" || true
    if [ "${#seen}" -ge "$CS_TEST_REMOVE_AT" ]; then
        rm -rf "$CS_TEST_REMOVE_DIR"
        : > "$CS_TEST_STEPS_FILE.removed"
    fi
    return 0
}
trap _cs_test_remove_at_step DEBUG
SEAM
    _run_stop_hook_removing_at() {  # step ("" for none): leaves <work>/<step or control>/{out,rc,steps*,root}
        local w="$work/${1:-control}"
        mkdir -p "$w/root/ending/.cs/memory" "$w/home"
        printf '# Session: ending\n' > "$w/root/ending/.cs/README.md"
        env -i HOME="$w/home" PATH="$PATH" CS_SESSIONS_ROOT="$w/root" \
            CLAUDE_SESSION_NAME=ending CLAUDE_SESSION_DIR="$w/root/ending" \
            CLAUDE_SESSION_META_DIR="$w/root/ending/.cs" \
            CS_RESOLVED_FROM=env CS_LEAD_PID=$$ CLAUDE_PID=$$ \
            BASH_ENV="$seam" CS_TEST_REMOVE_AT="$1" CS_TEST_REMOVE_DIR="$w/root/ending" \
            CS_TEST_STEPS_FILE="$w/steps" \
            "$sh" "$HOOKS_DIR/narrative-reminder.sh" \
            <<< '{"hook_event_name":"Stop","session_id":"11111111-2222-4333-8444-555555555555"}' \
            > "$w/out" 2>/dev/null
        echo $? > "$w/rc"
    }
    # Positive control: untouched, the hook makes .cs/local and raises the marker.
    _run_stop_hook_removing_at ""
    w="$work/control"
    assert_eq "0" "$(cat "$w/rc")" "$sh: the Stop hook exits 0 with no removal" || return 1
    assert_eq '{"decision": "approve"}' "$(cat "$w/out")" "$sh: the hook approves the stop" || return 1
    assert_file_exists "$w/root/ending/.cs/local/attention" "$sh: the hook raises the attention marker when the session stays" || return 1
    assert_exists "$w/steps.in-writer" "$sh: the seam steps inside cs_mkdir_inside" || return 1
    steps=$(wc -c < "$w/steps" | tr -d ' ')
    n=1
    while [ "$n" -le "$steps" ]; do
        first=$n pids=""
        while [ "$n" -le "$steps" ] && [ $((n - first)) -lt 8 ]; do
            _run_stop_hook_removing_at "$n" &
            pids="$pids $!"
            n=$((n + 1))
        done
        # shellcheck disable=SC2086  # a list of pids
        wait $pids
        while [ "$first" -lt "$n" ]; do
            w="$work/$first"
            if [ ! -e "$w/steps.removed" ]; then
                # A run can end in fewer commands than the control did; then it had nothing to remove before.
                ran=$(wc -c < "$w/steps" | tr -d ' ')
                [ "$ran" -lt "$first" ] \
                    || { echo "  FAIL: $sh: the seam removed nothing before hook command $first, in a run of $ran"; return 1; }
            else
                assert_eq "0" "$(cat "$w/rc")" "$sh: the Stop hook exits 0 when the session goes before command $first" || return 1
                assert_eq '{"decision": "approve"}' "$(cat "$w/out")" "$sh: the hook approves the stop when the session goes before command $first" || return 1
                if [ -e "$w/root/ending" ]; then
                    echo "  FAIL: $sh: removed before hook command $first of $steps, the session came back holding: $(cd "$w/root" && find ending | LC_ALL=C sort | tr '\n' ' ')"
                    return 1
                fi
            fi
            rm -rf "$w"
            first=$((first + 1))
        done
    done
}

run_test test_stop_never_recreates_a_removed_session


# --- A torn JSONL tail must not take the next record down with it ---
# A process killed mid-append leaves a last line with no newline. The next `>>`
# then splices two records onto one line, and cs's tolerant per-line reader drops
# the spliced line whole — losing the torn record AND the intact one after it.

test_session_end_does_not_splice_onto_a_torn_timeline() {
    session_start_setup
    printf '{"ts":"2026-01-01T00:00:00Z","event":"started","session_id":"1111"}\n' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    printf '{"ts":"2026-01-02T00:00:00Z","event":"checkpoint","label":"torn"}' \
        >> "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated; the splice cannot happen"; session_start_teardown; return 1; }

    echo '{"session_id":"3333","reason":"prompt_input_exit"}' \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "checkpoint" "the torn record survives" \
        || { session_start_teardown; return 1; }
    assert_output_contains "$events" "ended" "and so does the record appended after it" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_session_start_does_not_splice_onto_a_torn_timeline() {
    session_start_setup
    printf '{"ts":"2026-01-02T00:00:00Z","event":"checkpoint","label":"torn"}' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated; the splice cannot happen"; session_start_teardown; return 1; }

    echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "checkpoint" "the torn record survives" \
        || { session_start_teardown; return 1; }
    assert_output_contains "$events" "started" "and so does the record appended after it" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_torn_partial_record_costs_only_itself() {
    # The realistic crash leaves a PARTIAL record, not a whole one missing its
    # newline. That record is unrecoverable by design — it was never complete —
    # but the guard still bounds the damage to one record instead of two.
    session_start_setup
    printf '{"ts":"2026-01-01T00:00:00Z","event":"sta' \
        > "$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    jsonl_tail_is_torn "$CLAUDE_SESSION_META_DIR/timeline.jsonl" \
        || { echo "  FAIL: fixture is terminated"; session_start_teardown; return 1; }

    echo '{"session_id":"3333","reason":"prompt_input_exit"}' \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1 || true

    local events
    events=$(jsonl_events "$CLAUDE_SESSION_META_DIR/timeline.jsonl")
    assert_output_contains "$events" "ended" "the new record parses on its own line" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_hook_terminator_survives_a_missing_resolver_library() {
    # An install whose hooks were not redeployed pairs a NEW bin/cs with OLD
    # hooks. Each hook therefore defines its own fallback beside the existing
    # cs_resolve_session one, so the two hottest writers cannot go back to
    # splicing silently when the shared library is absent.
    assert_file_contains "$HOOKS_DIR/session-start.sh" "command -v _cs_terminate_jsonl" \
        "session-start defines a fallback terminator" || return 1
    assert_file_contains "$HOOKS_DIR/session-end.sh" "command -v _cs_terminate_jsonl" \
        "session-end defines a fallback terminator" || return 1
    assert_file_contains "$HOOKS_DIR/cs-resolve.sh" "_cs_terminate_jsonl" \
        "the shared library carries the canonical definition" || return 1
}

run_test test_session_end_does_not_splice_onto_a_torn_timeline
run_test test_session_start_does_not_splice_onto_a_torn_timeline
run_test test_torn_partial_record_costs_only_itself
run_test test_hook_terminator_survives_a_missing_resolver_library


# --- Session State must not manufacture escape sequences out of plain text ---

test_session_state_does_not_interpret_backslash_escapes_in_content() {
    # The block was emitted through `printf '%b'`, which INTERPRETS backslash
    # escapes — so a README objective containing the five literal characters
    # backslash-0-3-3 was converted by cs itself into a real ESC byte. The text
    # was inert on disk; cs made it dangerous. That is worse than the raw-byte
    # case, where a writer has to smuggle a control character in.
    session_start_setup
    printf '# test-session\n\n## Objective\n\nship \\033[31mred\\033[0m thing\n' \
        > "$CLAUDE_SESSION_META_DIR/README.md"
    # Fixture sanity: the file holds NO control byte, only printable characters.
    local on_disk
    on_disk=$(LC_ALL=C tr -dc "$(printf '\033\007')" < "$CLAUDE_SESSION_META_DIR/README.md" | wc -c | tr -d '[:space:]')
    [ "$on_disk" = "0" ] || {
        echo "  FAIL: fixture already contains a control byte; the test would pass for the wrong reason"
        session_start_teardown; return 1
    }

    local output context esc
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "the block must be reached, or nothing is being tested" || { session_start_teardown; return 1; }
    esc=$(printf '%s' "$context" | LC_ALL=C tr -dc "$(printf '\033\007')" | wc -c | tr -d '[:space:]')
    assert_eq "0" "$esc" \
        "cs must not convert literal backslash-033 in content into a real escape byte" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

test_session_state_scrubs_a_real_control_byte_in_content() {
    # The other half: a README that really does carry a raw ESC — written by
    # another session, or pasted — must not reach the terminal with it.
    session_start_setup
    printf '# test-session\n\n## Objective\n\nship \033[31mred\033[0m thing\n' \
        > "$CLAUDE_SESSION_META_DIR/README.md"
    local on_disk
    on_disk=$(LC_ALL=C tr -dc "$(printf '\033')" < "$CLAUDE_SESSION_META_DIR/README.md" | wc -c | tr -d '[:space:]')
    [ "$on_disk" != "0" ] || {
        echo "  FAIL: fixture carries no raw ESC; the scrub is not being exercised"
        session_start_teardown; return 1
    }

    local output context esc
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" \
        "the block must be reached" || { session_start_teardown; return 1; }
    esc=$(printf '%s' "$context" | LC_ALL=C tr -dc "$(printf '\033')" | wc -c | tr -d '[:space:]')
    assert_eq "0" "$esc" "a raw control byte in content must be scrubbed" \
        || { session_start_teardown; return 1; }
    session_start_teardown
}

# The Session State scrub hands tr the C locale through env: the shell never
# changes its own locale for it, which can crash a bash linked against
# libintl in the forked copy the scrub runs in. The control bytes go and a
# multibyte character stays whole.
test_session_state_scrubs_without_the_shell_assigning_its_own_locale() {
    session_start_setup
    printf '# test-session\n\n## Objective\n\nship \033[31mred\033[0m \342\200\224 thing\001\n' \
        > "$CLAUDE_SESSION_META_DIR/README.md"
    local b utf8 output line own
    utf8="$(utf8_locale)"
    for b in $(every_bash); do
        output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
            | env ${utf8:+"LC_ALL=$utf8"} "$b" -x "$HOOKS_DIR/session-start.sh" 2>"$TEST_TMPDIR/trace")
        line=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep '^Objective: ')
        assert_eq "$(printf 'Objective: ship [31mred[0m \342\200\224 thing')" "$line" \
            "$b: the objective, scrubbed byte for byte" || { session_start_teardown; return 1; }
        own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
        assert_eq "" "$own" "$b must not assign its own locale in the SessionStart hook" \
            || { session_start_teardown; return 1; }
    done
    session_start_teardown
}

test_session_state_still_renders_its_own_line_breaks() {
    # The fix removes %b, so cs's OWN newlines must survive the change — the
    # block is multi-line and a regression would fuse it into one line.
    session_start_setup
    local output context lines
    output=$(echo '{"session_id":"test","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
    assert_output_contains "$context" "Session State" "the block renders" \
        || { session_start_teardown; return 1; }
    assert_output_not_contains "$context" 'Objective:.*\\n' \
        "a literal backslash-n must never survive into the rendered block" \
        || { session_start_teardown; return 1; }
    lines=$(printf '%s' "$context" | sed -n '/--- Session State ---/,$p' | grep -c .)
    [ "${lines:-0}" -ge 2 ] \
        || { echo "  FAIL: Session State collapsed to $lines line(s); cs's own newlines were lost"
             session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_state_does_not_interpret_backslash_escapes_in_content
run_test test_session_state_scrubs_a_real_control_byte_in_content
run_test test_session_state_scrubs_without_the_shell_assigning_its_own_locale
run_test test_session_state_still_renders_its_own_line_breaks

# ============================================================================
# session-start.sh: publishing the session contract to the conversation
# ============================================================================

# CLAUDE_ENV_FILE is how a SessionStart hook hands variables to the rest of the
# session. `cs` has already exported the contract before exec, so the write is
# what carries it where the launch could not reach.
test_session_start_publishes_the_contract_for_a_cs_launch() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile"
    : > "$envfile"

    CLAUDE_ENV_FILE="$envfile" bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$CLAUDE_SESSION_DIR"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1

    assert_file_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a cs launch publishes its own contract" || { session_start_teardown; return 1; }
    session_start_teardown
}

# A front end that reached the session by walking the directory it opened is
# not the one cs launched, and the lock, the recorded conversation and the
# index all key off that difference. Publishing the contract into such a
# session would erase the distinction for every hook that fires after it.
test_session_start_withholds_the_contract_from_a_walked_in_front_end() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile" dir="$CLAUDE_SESSION_DIR"
    : > "$envfile"

    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CLAUDE_CODE_ENTRYPOINT="claude-desktop" CLAUDE_PROJECT_DIR="$dir" \
        CLAUDE_ENV_FILE="$envfile" \
        bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$dir"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1

    assert_file_not_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a walked-in front end must not publish the contract" || { session_start_teardown; return 1; }
    session_start_teardown
}

# Claude Code sources CLAUDE_ENV_FILE as shell, so each value is written as
# data: a sessions root holding a quote, a double quote, a command substitution
# and a space must read back as the same path and run nothing when sourced.
test_session_start_publishes_a_path_with_shell_metacharacters_as_data() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile" root got
    root="$TEST_TMPDIR/r 'q\" \$(touch sentinel) x"
    mv "$CS_SESSIONS_ROOT" "$root"
    export CS_SESSIONS_ROOT="$root"
    export CLAUDE_SESSION_DIR="$root/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    : > "$envfile"

    jq -n -c --arg cwd "$CLAUDE_SESSION_DIR" \
        '{session_id: "s", source: "startup", cwd: $cwd, hook_event_name: "SessionStart"}' \
        | CLAUDE_ENV_FILE="$envfile" bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    got=$(cd "$TEST_TMPDIR" && env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR bash -c '. "$1" 2>/dev/null; printf "%s|%s|%s" "$CLAUDE_SESSION_NAME" "$CLAUDE_SESSION_DIR" "$CLAUDE_SESSION_META_DIR"' _ "$envfile")
    assert_not_exists "$TEST_TMPDIR/sentinel" "sourcing the env file runs nothing" || { session_start_teardown; return 1; }
    assert_eq "current-session|$root/current-session|$root/current-session/.cs" "$got" \
        "the env file gives back the exact name and paths" || { session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_start_publishes_the_contract_for_a_cs_launch
run_test test_session_start_withholds_the_contract_from_a_walked_in_front_end
run_test test_session_start_publishes_a_path_with_shell_metacharacters_as_data

# A teammate resolves by walking, and is the one walked-in front end that needs
# the contract: its own `cs -secrets`, `cs -msg` and status line read the
# session out of the environment. What must survive is that it is not the
# launch, which session-end.sh reads to decide whether it owns the lock.
test_session_start_publishes_the_contract_to_a_teammate() {
    session_start_setup
    local envfile="$TEST_TMPDIR/envfile" dir="$CLAUDE_SESSION_DIR" script="$TEST_TMPDIR/fake-claude.sh"
    : > "$envfile"
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$script"; chmod +x "$script"
    "$script" --agent-id a1 --agent-name mate --team-name t >/dev/null 2>&1 &
    local pid=$!
    wait_until pid_args_match "$pid" fake-claude \
        || { kill "$pid" 2>/dev/null; echo "  FAIL: fixture: ps never showed the stand-in teammate"; session_start_teardown; return 1; }

    env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CLAUDE_CODE_ENTRYPOINT="cli" CLAUDE_PID="$pid" CLAUDE_PROJECT_DIR="$dir" \
        CLAUDE_ENV_FILE="$envfile" \
        bash -c 'echo "{\"session_id\":\"s\",\"source\":\"startup\",\"cwd\":\"'"$dir"'\",\"hook_event_name\":\"SessionStart\"}" | bash "'"$HOOKS_DIR"'/session-start.sh"' \
        >/dev/null 2>&1
    kill "$pid" 2>/dev/null

    assert_file_contains "$envfile" "CLAUDE_SESSION_NAME" \
        "a teammate needs the session in its own environment" || { session_start_teardown; return 1; }
    assert_file_contains "$envfile" "CS_RESOLVED_FROM='walk'" \
        "and must stay marked as not being the launch" || { session_start_teardown; return 1; }
    session_start_teardown
}

run_test test_session_start_publishes_the_contract_to_a_teammate


# ============================================================================
# narrative-reminder.sh — council advisor nudge
# ============================================================================

# A fake plugin install record plus the command file it points at. Both halves
# matter: the record can name a directory a later uninstall removed.
_install_fake_council() {
    local root="$TEST_TMPDIR/claude"
    local plug="$root/plugins/cache/hex-plugins/claude-council/2026.9.9"
    mkdir -p "$plug/commands" "$root/plugins"
    touch "$plug/commands/advise.md"
    cat > "$root/plugins/installed_plugins.json" << JSON
{"version": 1, "plugins": {"claude-council@hex-plugins": [
  {"scope": "user", "installPath": "$plug", "version": "2026.9.9"}]}}
JSON
    export CLAUDE_CONFIG_DIR="$root"
}

test_advisor_nudge_is_silent_without_the_council_plugin() {
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/empty-claude"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    # Never advertise a command the user cannot run.
    assert_output_not_contains "$output" "claude-council" \
        "Should not mention the council when the plugin is absent" || return 1
    unset CLAUDE_CONFIG_DIR
}

test_advisor_nudge_appears_when_the_council_is_installed() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "claude-council:advise" \
        "Should name the command when the plugin is installed" || return 1
    unset CLAUDE_CONFIG_DIR
}

test_advisor_nudge_is_silent_when_the_recorded_path_is_gone() {
    _install_fake_council
    # An uninstall removes the directory; the record can outlive it.
    rm -rf "$TEST_TMPDIR/claude/plugins/cache/hex-plugins/claude-council/2026.9.9"
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_not_contains "$output" "claude-council" \
        "A stale install record should not produce a suggestion" || return 1
    unset CLAUDE_CONFIG_DIR
}

test_advisor_nudge_tells_the_model_to_ask_before_sending() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    # Suggest, never send: the conversation goes to third parties.
    assert_output_contains "$output" "ask" \
        "The nudge must say to ask before sending" || return 1
    unset CLAUDE_CONFIG_DIR
}

test_advisor_nudge_does_not_repeat_within_its_cooldown() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    date +%s > "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_not_contains "$output" "claude-council" \
        "A fresh cooldown should suppress the nudge" || return 1
    unset CLAUDE_CONFIG_DIR
}

# The codex plugin ships its own commands; the record key and the probe file
# are its own, so the nudge must key on codex, not on the council being there.
_install_fake_codex() {
    local root="$TEST_TMPDIR/claude"
    local plug="$root/plugins/cache/openai-codex/codex/1.0.6"
    mkdir -p "$plug/commands" "$root/plugins"
    touch "$plug/commands/review.md"
    cat > "$root/plugins/installed_plugins.json" << JSON
{"version": 1, "plugins": {"codex@openai-codex": [
  {"scope": "user", "installPath": "$plug", "version": "1.0.6"}]}}
JSON
    export CLAUDE_CONFIG_DIR="$root"
}

test_advisor_nudge_names_codex_when_only_codex_is_installed() {
    _install_fake_codex
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "codex:review" \
        "Should name the codex review command when codex is installed" || return 1
    # The council is absent here; naming it would advertise a missing command.
    assert_output_not_contains "$output" "claude-council" \
        "Should not name the council when only codex is installed" || return 1
    unset CLAUDE_CONFIG_DIR
}

run_test test_advisor_nudge_names_codex_when_only_codex_is_installed
test_advisor_nudge_names_both_channels_when_both_are_installed() {
    local root="$TEST_TMPDIR/claude"
    local council="$root/plugins/cache/hex-plugins/claude-council/2026.9.9"
    local codex="$root/plugins/cache/openai-codex/codex/1.0.6"
    mkdir -p "$council/commands" "$codex/commands" "$root/plugins"
    touch "$council/commands/advise.md" "$codex/commands/review.md"
    cat > "$root/plugins/installed_plugins.json" << JSON
{"version": 1, "plugins": {
  "claude-council@hex-plugins": [{"scope": "user", "installPath": "$council", "version": "2026.9.9"}],
  "codex@openai-codex": [{"scope": "user", "installPath": "$codex", "version": "1.0.6"}]}}
JSON
    export CLAUDE_CONFIG_DIR="$root"
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "claude-council:advise" \
        "Both installed: the council command should still be named" || return 1
    assert_output_contains "$output" "codex:review" \
        "Both installed: the codex command should also be named" || return 1
    # One note, one slot: a second standing note would double the text.
    local heads
    heads=$(printf '%s' "$output" | grep -o "Standing note" | wc -l | tr -d ' ')
    assert_eq "1" "$heads" "Both installed should still emit one standing note" || return 1
    unset CLAUDE_CONFIG_DIR
}

run_test test_advisor_nudge_names_both_channels_when_both_are_installed
run_test test_advisor_nudge_is_silent_without_the_council_plugin
run_test test_advisor_nudge_appears_when_the_council_is_installed
run_test test_advisor_nudge_is_silent_when_the_recorded_path_is_gone
run_test test_advisor_nudge_tells_the_model_to_ask_before_sending
run_test test_advisor_nudge_does_not_repeat_within_its_cooldown



test_advisor_nudge_cooldown_lands_in_the_machine_local_dir() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null

    # Per-machine state belongs under .cs/local/, which every session already
    # gitignores. A new stamp at the session root would ride into a git-synced
    # session and conflict between machines.
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown" \
        "Cooldown should be written under .cs/local/" || return 1
    if [ -f "$CLAUDE_SESSION_META_DIR/.advisor-nudge-cooldown" ]; then
        echo "Cooldown must not be written at the session root"
        return 1
    fi
    unset CLAUDE_CONFIG_DIR
}

test_advisor_nudge_survives_an_unset_home() {
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"

    # A bare $HOME under `set -u` aborts the hook before it emits, losing the
    # reminder entirely. The sibling session-end hook is tested for the same
    # property; this path must not reintroduce the class.
    local output
    # env -i, not env -u: an ambient CLAUDE_CONFIG_DIR makes the $HOME
    # expansion unreachable, so the test passes without proving anything.
    output=$(echo '{}' | env -i PATH="$PATH" \
        CLAUDE_SESSION_NAME="$CLAUDE_SESSION_NAME" \
        CLAUDE_SESSION_DIR="$CLAUDE_SESSION_DIR" \
        CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_META_DIR" \
        bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null)
    assert_output_contains "$output" "Narrative check" \
        "Hook should still emit its reminder with HOME unset" || return 1
}

test_reminder_carries_the_commit_cadence() {
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"

    # Sessions that track .cs/ were committing once per append (328 such
    # commits in one repo, 74 in a day). The reminder is the only surface that
    # fires AT the append, so the rule rides with it as well as in the
    # session protocol, which is read once at startup and stale by then.
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null)
    # The session protocol's cs:session-commits rule says the same: cs commits
    # files under .cs/ only in the create commit and /finish's integrate merge,
    # and the model commits them only when the user asks (Alex, 2026-10-14:
    # "No commits at all"; 2026-10-15: keep the create commit, fix the text).
    assert_output_contains "$output" "Never commit narrative appends or anything else under .cs/ on your own, not even beside a project change: cs commits files under .cs/ only in the commit that creates a session and the merge /finish makes, and you commit them only when the user asks." \
        "Reminder should say appends are committed only when the user asks, as the protocol does" || return 1
    assert_output_not_contains "$output" "commit them with the next handoff" \
        "no commit is named for appends to ride in" || return 1
    # Naming the safe alternative matters: without it the instruction reads as
    # a reason to delay appends, which loses work the autosave ref already holds.
    assert_output_contains "$output" "autosave" \
        "Cadence should say uncommitted appends are safe" || return 1
    # A session whose own notes say to push after each commit pushed every
    # narrative commit to a deploy branch, one redeploy each. The reminder
    # fires at the append, so it is where the push rule has to be.
    assert_output_contains "$output" "Never push a commit that holds narrative appends unless the user asks." \
        "Cadence should say a narrative-only commit is never pushed" || return 1
}

run_test test_advisor_nudge_cooldown_lands_in_the_machine_local_dir
run_test test_reminder_carries_the_commit_cadence
run_test test_advisor_nudge_survives_an_unset_home


test_advisor_nudge_finds_a_record_that_is_not_first() {
    local root="$TEST_TMPDIR/claude"
    local plug="$root/plugins/cache/hex-plugins/claude-council/2026.9.9"
    mkdir -p "$plug/commands" "$root/plugins"
    touch "$plug/commands/advise.md"
    # Real records carry several entries per plugin and the order is not
    # guaranteed; reading only [0] reads the oldest scope, not the live one.
    cat > "$root/plugins/installed_plugins.json" << JSON
{"version": 1, "plugins": {"claude-council@hex-plugins": [
  {"scope": "project", "installPath": "$root/plugins/cache/gone", "version": "2026.1.1"},
  {"scope": "user", "installPath": "$plug", "version": "2026.9.9"}]}}
JSON
    export CLAUDE_CONFIG_DIR="$root"
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    unset CLAUDE_CONFIG_DIR
    assert_output_contains "$output" "claude-council:advise" \
        "Should find a usable record that is not the first entry" || return 1
}

test_advisor_nudge_finds_the_plugin_in_any_marketplace() {
    local root="$TEST_TMPDIR/claude"
    local plug="$root/plugins/cache/other-market/claude-council/2026.9.9"
    mkdir -p "$plug/commands" "$root/plugins"
    touch "$plug/commands/advise.md"
    # The docs say "when the plugin is present", not "when it came from one
    # marketplace"; a fork or a rename must not silence the nudge.
    cat > "$root/plugins/installed_plugins.json" << JSON
{"version": 1, "plugins": {"claude-council@other-market": [
  {"scope": "user", "installPath": "$plug", "version": "2026.9.9"}]}}
JSON
    export CLAUDE_CONFIG_DIR="$root"
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    unset CLAUDE_CONFIG_DIR
    assert_output_contains "$output" "claude-council:advise" \
        "Marketplace name should not gate detection" || return 1
}

test_advisor_nudge_survives_an_unwritable_cooldown_dir() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    rm -rf "$CLAUDE_SESSION_META_DIR/local"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    _deny_writes "$CLAUDE_SESSION_META_DIR/local" || return 77

    # Hooks fail open: a stamp that cannot be written must never cost the user
    # the reminder it rides on. The stamp is written for the lead only, so the
    # lead is modelled inline rather than inherited from an earlier test.
    local output
    output=$(echo '{}' | CS_LEAD_PID=$$ CLAUDE_PID=$$ bash "$HOOKS_DIR/narrative-reminder.sh" 2>"$TEST_TMPDIR/stderr")
    _allow_writes "$CLAUDE_SESSION_META_DIR/local"
    unset CLAUDE_CONFIG_DIR
    assert_output_contains "$output" "Narrative check" \
        "An unwritable cooldown dir must not lose the reminder" || return 1
    # A trailing 2>/dev/null applies after the `>` has already reported, so
    # the failed write must be silenced by the braced form or it reaches the
    # user's terminal as noise from a hook that meant to fail quietly.
    assert_file_not_contains "$TEST_TMPDIR/stderr" "Permission denied" \
        "a stamp that cannot be written is not reported" || return 1
}

test_advisor_nudge_tolerates_a_padded_cooldown_stamp() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    # A leading zero is a valid integer to _num_or but octal to $(( )).
    printf '0%s' "$(date +%s)" > "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" 2>/dev/null)
    unset CLAUDE_CONFIG_DIR
    assert_output_contains "$output" "Narrative check" \
        "A padded stamp must not break the arithmetic" || return 1
}

run_test test_advisor_nudge_finds_a_record_that_is_not_first
run_test test_advisor_nudge_finds_the_plugin_in_any_marketplace
run_test test_advisor_nudge_survives_an_unwritable_cooldown_dir
run_test test_advisor_nudge_tolerates_a_padded_cooldown_stamp


test_advisor_nudge_stays_silent_for_a_teammate() {
    _install_fake_council
    echo "# narrative" > "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown" \
          "$CLAUDE_SESSION_META_DIR/local/.advisor-nudge-cooldown"

    # A tmux teammate is a full claude in the same directory with its own Stop.
    # It shares the one cooldown stamp, so an ungated nudge lets a teammate
    # consume the lead's 30-minute slot — and in a walk-away run the lead can
    # stop seeing the suggestion entirely.
    local output
    output=$(echo '{}' | CS_LEAD_PID=1 CLAUDE_PID=99999 \
        bash "$HOOKS_DIR/narrative-reminder.sh")
    unset CLAUDE_CONFIG_DIR
    assert_output_not_contains "$output" "claude-council" \
        "A teammate should not consume the lead's nudge slot" || return 1
}

run_test test_advisor_nudge_stays_silent_for_a_teammate

run_test test_session_start_names_both_addresses_of_a_feature_session

report_results
