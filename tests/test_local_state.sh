#!/usr/bin/env bash
# ABOUTME: Tests that machine-local session state (claude_session_id, color,
# ABOUTME: last_resumed) lives in gitignored .cs/local/state, never in the shared README

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"


HOOKS_DIR="$SCRIPT_DIR/../hooks"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_TRANSCRIPTS_DIR
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_CLAUDE_SESSION_ID 2>/dev/null || true
}

UUID_V4_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
VALID_COLORS_RE='^(red|blue|green|yellow|purple|orange|pink|cyan)$'

# The four keys that hooks/cs write divergently per machine. None of them may
# appear in the git-synced README; the first three live in .cs/local/state.
MACHINE_LOCAL_KEYS=(claude_session_id claude_session_color last_resumed updated)

# Extract a key's value from a .cs/local/state file. Prints empty if absent.
_extract_state_value() {
    local state="$1" key="$2"
    grep -E "^$key:" "$state" 2>/dev/null \
        | head -1 \
        | sed -E "s/^$key:[[:space:]]*//; s/^\"//; s/\"\$//" \
        || true
}

# Assert the README contains none of the machine-local keys.
_assert_readme_clean() {
    local readme="$1" key
    for key in "${MACHINE_LOCAL_KEYS[@]}"; do
        assert_file_not_contains "$readme" "^$key:" \
            "README must not contain machine-local key '$key'" || return 1
    done
}

# ============================================================================
# Cycle 1: new session records uuid + color in .cs/local/state, README stays
# free of machine-local keys
# ============================================================================

test_new_session_records_state_in_local_not_readme() {
    local output
    output=$(umask 022; "$CS_BIN" state-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/state-session"
    local state="$session_dir/.cs/local/state"

    assert_file_exists "$state" \
        ".cs/local/state should exist after first launch" || return 1
    # A new file takes the umask's mode, not the 0600 mktemp gives its temp.
    assert_eq "644" "$(_file_mode "$state")" "a new state file has the umask's mode" || return 1

    local uuid color
    uuid=$(_extract_state_value "$state" claude_session_id)
    color=$(_extract_state_value "$state" claude_session_color)

    if [[ ! "$uuid" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: state claude_session_id is not a valid v4 UUID: '$uuid'"
        return 1
    fi
    if [[ ! "$color" =~ $VALID_COLORS_RE ]]; then
        echo "  FAIL: state claude_session_color is not a valid color: '$color'"
        return 1
    fi

    assert_output_contains "$output" "--session-id $uuid" \
        "claude spawn should pass --session-id from local state" || return 1

    _assert_readme_clean "$session_dir/.cs/README.md" || return 1
}

# ============================================================================
# Cycle 2: resume launches never modify the git-synced README — the
# multi-machine merge-conflict regression test
# ============================================================================

test_resume_leaves_readme_untouched() {
    "$CS_BIN" state-session <<< "" >/dev/null 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/state-session"
    local readme="$session_dir/.cs/README.md"
    local before
    before=$(cat "$readme")

    local state="$session_dir/.cs/local/state"
    local uuid
    uuid=$(_extract_state_value "$state" claude_session_id)
    if [[ ! "$uuid" =~ $UUID_V4_RE ]]; then
        echo "  FAIL: precondition - local state has no valid uuid: '$uuid'"
        return 1
    fi

    local output
    output=$("$CS_BIN" state-session <<< "" 2>&1) || true

    assert_output_contains "$output" "--resume $uuid" \
        "resume should pass --resume with the state uuid" || return 1

    assert_eq "$before" "$(cat "$readme")" \
        "resume must leave README byte-identical (multi-machine conflict guard)" || return 1
}

# ============================================================================
# Cycle 3: migration moves legacy frontmatter fields into local state and
# strips them from the README
# ============================================================================

# The strip is bounded to the frontmatter block. These four keys are ordinary
# English in prose, and .cs/README.md has an Outcome section written by hand, so
# a body line beginning "updated:" is user-owned content — not a stale
# machine-local field. Matching it over the whole file deleted it silently while
# reporting that machine-local fields had been moved.
test_migration_leaves_a_body_line_that_looks_like_a_field() {
    local session_dir="$CS_SESSIONS_ROOT/body-line"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-01-01
claude_session_id: abcd1234-5678-4abc-9def-fedcba987654
tags: []
aliases: ["body-line"]
---
# Session: body-line

## Outcome

updated: the parser rewrite landed, docs still pending
last_resumed: never went back to the follow-up
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" body-line <<< "" >/dev/null 2>&1 || true

    local readme="$session_dir/.cs/README.md"
    assert_file_contains "$readme" "^updated: the parser rewrite landed"         "a body line the user wrote must survive migration" || return 1
    assert_file_contains "$readme" "^last_resumed: never went back"         "and so must the second one" || return 1
    # The frontmatter field is still moved out.
    assert_eq "abcd1234-5678-4abc-9def-fedcba987654"         "$(_extract_state_value "$session_dir/.cs/local/state" claude_session_id)"         "the frontmatter field is still carried into local state" || return 1
    if grep -qE '^claude_session_id:' "$readme"; then
        echo "  FAIL: frontmatter field left in the README"
        return 1
    fi
}

# Phase 6 reframes a README that has no frontmatter. Writing it in place means
# the redirect truncates the user's file before anything is written back; a
# write that does not complete leaves it empty. Through a temp file, a failed
# write leaves the original untouched — which is what this asserts. The README
# is a link into a directory that takes no new files, so the temp file cannot
# be created beside the real file while a write in place still could land.
test_migration_readme_survives_a_failed_frontmatter_write() {
    local session_dir="$CS_SESSIONS_ROOT/no-frontmatter"
    mkdir -p "$session_dir/.cs"/{local,memory} "$TEST_TMPDIR/readme-home"
    local readme="$session_dir/.cs/README.md" real="$TEST_TMPDIR/readme-home/README.md"
    printf '# Session: no-frontmatter\n\n## Objective\n\nkeep me\n' > "$real"
    ln -s "$real" "$readme"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    _deny_writes "$TEST_TMPDIR/readme-home" || return 77

    "$CS_BIN" no-frontmatter <<< "" >/dev/null 2>&1 || true
    _allow_writes "$TEST_TMPDIR/readme-home"

    assert_file_contains "$real" "^## Objective" "the user's README must survive" || return 1
    assert_file_contains "$real" "^keep me" "including its body" || return 1
    if [ "$(head -1 "$real")" = "---" ]; then
        echo "  FAIL: rewrote the README in place despite the write failing"
        return 1
    fi
    [ -L "$readme" ] || { echo "  FAIL: the README link was replaced by a file"; return 1; }
}

# Both README rewrites of the migration go through a uniquely named temp file:
# a sibling the user named README.md.tmp is left alone and the README keeps
# its mode. One session reaches the frontmatter reframe, the other the move of
# machine-local fields.
test_migration_readme_rewrites_leave_a_tmp_sibling_alone_and_keep_the_mode() {
    local a="$CS_SESSIONS_ROOT/no-frontmatter-sib" b="$CS_SESSIONS_ROOT/legacy-frontmatter-sib" d
    for d in "$a" "$b"; do
        mkdir -p "$d/.cs"/{local,memory}
        echo "# Session narrative" > "$d/.cs/memory/narrative.md"
        echo "# Session" > "$d/CLAUDE.md"
    done
    printf '# Session: no-frontmatter-sib\n\n## Objective\n\nkeep me\n' > "$a/.cs/README.md"
    printf -- '---\nstatus: active\ncreated: 2026-01-01\nclaude_session_id: abcd1234-5678-4abc-9def-fedcba987654\ntags: []\naliases: ["legacy-frontmatter-sib"]\n---\n# Session: legacy-frontmatter-sib\n' > "$b/.cs/README.md"
    for d in "$a" "$b"; do
        (cd "$d" && git init -q && git add -A && git commit -q -m "init")
        printf 'USER-OWNED\n' > "$d/.cs/README.md.tmp"
        chmod 750 "$d/.cs/README.md"
    done

    "$CS_BIN" no-frontmatter-sib <<< "" >/dev/null 2>&1 || true
    "$CS_BIN" legacy-frontmatter-sib <<< "" >/dev/null 2>&1 || true

    assert_eq "---" "$(head -1 "$a/.cs/README.md")" "frontmatter added" || return 1
    assert_file_contains "$a/.cs/README.md" "^keep me" "the body is kept" || return 1
    assert_file_not_contains "$b/.cs/README.md" "^claude_session_id:" "machine-local field moved out" || return 1
    for d in "$a" "$b"; do
        assert_eq "USER-OWNED" "$(cat "$d/.cs/README.md.tmp" 2>/dev/null)" "README.md.tmp is untouched in $(basename "$d")" || return 1
        assert_eq "750" "$(_file_mode "$d/.cs/README.md")" "the README keeps its mode in $(basename "$d")" || return 1
    done
}

test_migration_moves_fields_from_readme_to_local_state() {
    local session_dir="$CS_SESSIONS_ROOT/legacy-frontmatter"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-01-01
claude_session_id: abcd1234-5678-4abc-9def-fedcba987654
last_resumed: 2026-06-30
claude_session_color: purple
tags: []
updated: 2026-06-30
aliases: ["legacy-frontmatter"]
---
# Session: legacy-frontmatter
EOF
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" legacy-frontmatter <<< "" >/dev/null 2>&1 || true

    local state="$session_dir/.cs/local/state"
    assert_eq "abcd1234-5678-4abc-9def-fedcba987654" \
        "$(_extract_state_value "$state" claude_session_id)" \
        "migration should carry claude_session_id into local state" || return 1
    assert_eq "purple" \
        "$(_extract_state_value "$state" claude_session_color)" \
        "migration should carry claude_session_color into local state" || return 1

    _assert_readme_clean "$session_dir/.cs/README.md" || return 1

    # Shared frontmatter must survive the strip.
    assert_file_contains "$session_dir/.cs/README.md" "^status: active" || return 1
    assert_file_contains "$session_dir/.cs/README.md" "^created: 2026-01-01" || return 1
    assert_file_contains "$session_dir/.cs/README.md" '^aliases: \["legacy-frontmatter"\]' || return 1
}

# ============================================================================
# Cycle 3a: a conversation id that is not a UUID never reaches claude
# ============================================================================

HOSTILE_ID="--dangerously-skip-permissions --model x"

# A claude stub that records each launch's argv, one line per launch, each
# argument in its own brackets so word boundaries are visible.
_argv_claude_stub() {
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
printf '<%s>' "\$@" >> "$TEST_TMPDIR/claude-args"; echo >> "$TEST_TMPDIR/claude-args"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
}

# A shared session cloned into the sessions folder: the README travels with it,
# .cs/local does not.
_hostile_readme_session() {  # name
    local session_dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$session_dir/.cs/memory"
    printf -- '---\nstatus: active\nclaude_session_id: %s\naliases: ["%s"]\n---\n# Session: %s\n' \
        "$HOSTILE_ID" "$1" "$1" > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    echo "$session_dir"
}

_assert_uuid() {  # value, message
    [[ "$1" =~ $UUID_V4_RE ]] || { echo "  FAIL: $2: '$1'"; return 1; }
}

# Phase 12 imported the README's claude_session_id verbatim, and the resume
# prompt passed it to claude unquoted, so a committed README chose words on
# claude's command line. A value that is not a UUID names no conversation: the
# open starts the first one, as for a session with no id at all.
test_clone_with_a_readme_id_that_is_not_a_uuid_starts_fresh() {
    local session_dir
    session_dir=$(_hostile_readme_session hostile-clone)
    _argv_claude_stub

    local output
    output=$("$CS_BIN" hostile-clone <<< "" 2>&1) || true

    assert_output_not_contains "$output" "Continue previous conversation" "an id that is not a UUID is never offered for resume" || return 1
    assert_output_contains "$output" "(+ new)" "the card calls the launch new" || return 1
    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_eq "1" "$(printf '%s\n' "$launches" | grep -c .)" "claude launches exactly once" || return 1
    assert_output_not_contains "$launches" '--dangerously-skip-permissions' "the README's words never reach claude's argv" || return 1
    recorded=$(_extract_state_value "$session_dir/.cs/local/state" claude_session_id)
    _assert_uuid "$recorded" "the open records a real conversation id" || return 1
    assert_output_contains "$launches" "<--session-id><$recorded>" "claude starts the recorded conversation" || return 1
    _assert_readme_clean "$session_dir/.cs/README.md" || return 1
}

# The same clone on a machine where claude already ran in the folder. Phase 8
# binds the newest transcript; had Phase 12 imported the README value first,
# Phase 8 would print it back to the terminal as the orphan it repaired.
test_migration_never_records_a_readme_id_that_is_not_a_uuid() {
    local session_dir
    session_dir=$(_hostile_readme_session hostile-history)
    local proj uuid="44444444-4444-4444-8444-444444444444"
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$session_dir")"
    mkdir -p "$proj"
    printf '{"type":"user","sessionId":"%s"}\n' "$uuid" > "$proj/$uuid.jsonl"
    _argv_claude_stub

    local output
    output=$("$CS_BIN" hostile-history <<< "" 2>&1) || true

    assert_output_not_contains "$output" '--dangerously-skip-permissions' "the README's value is never recorded or echoed" || return 1
    assert_output_contains "$output" "ignoring claude_session_id in .cs/README.md" "the open says what it dropped" || return 1
    assert_eq "$uuid" "$(_extract_state_value "$session_dir/.cs/local/state" claude_session_id)" \
        "the folder's own conversation is bound" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args")" "<--resume><$uuid>" \
        "the open resumes the folder's conversation" || return 1
}

# Local state written before ids were checked (an import by an earlier cs, a
# hand edit) can already hold a value that is not a UUID. The launch treats it
# as no id: it starts the first conversation and records a real id over it.
test_launch_ignores_a_recorded_id_that_is_not_a_uuid() {
    local session_dir
    session_dir=$(create_test_session_with_git recorded-junk)
    printf 'claude_session_id: %s\n' "$HOSTILE_ID" > "$session_dir/.cs/local/state"
    _argv_claude_stub

    local output
    output=$("$CS_BIN" recorded-junk <<< "" 2>&1) || true

    assert_output_not_contains "$output" "Continue previous conversation" "an id that is not a UUID is never offered for resume" || return 1
    assert_output_contains "$output" "ignoring claude_session_id in .cs/local/state" "the open says what it dropped" || return 1
    assert_output_contains "$output" "(+ new)" "the card calls the launch new" || return 1
    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_output_not_contains "$launches" '--dangerously-skip-permissions' "the recorded words never reach claude's argv" || return 1
    recorded=$(_extract_state_value "$session_dir/.cs/local/state" claude_session_id)
    _assert_uuid "$recorded" "a real id replaces the recorded words" || return 1
    assert_output_contains "$launches" "<--session-id><$recorded>" "claude starts the recorded conversation" || return 1
    # The words named no conversation, so there was none to rotate from.
    if grep -q '"event":"rotated"' "$session_dir/.cs/timeline.jsonl" 2>/dev/null; then
        echo "  FAIL: a first conversation rotates from nothing: $(grep rotated "$session_dir/.cs/timeline.jsonl")"; return 1
    fi
}

# The README's claude_session_color rides the same import. The launch hands the
# recorded colour to claude as its first prompt, `/color <value>`, so a
# committed README chose the words of that prompt. Only one of the eight colours
# claude accepts is taken; anything else leaves the slot for the backfill.
test_clone_with_a_readme_color_that_is_not_a_color_gets_a_fresh_one() {
    local session_dir="$CS_SESSIONS_ROOT/hostile-color"
    mkdir -p "$session_dir/.cs/memory"
    printf -- '---\nstatus: active\nclaude_session_color: red then run rm -rf ~\n---\n# Session: hostile-color\n' \
        > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    _argv_claude_stub

    local output
    output=$("$CS_BIN" hostile-color <<< "" 2>&1) || true

    local launches recorded
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_output_not_contains "$launches" "then run" "the README's words never reach claude's prompt" || return 1
    assert_output_contains "$output" "ignoring claude_session_color" "the open says what it dropped" || return 1
    recorded=$(_extract_state_value "$session_dir/.cs/local/state" claude_session_color)
    case "$recorded" in
        red|blue|green|yellow|purple|orange|pink|cyan) ;;
        *) echo "  FAIL: the backfill must record one of claude's colours: '$recorded'"; return 1 ;;
    esac
    assert_output_contains "$launches" "</color $recorded>" "claude is handed the recorded colour alone" || return 1
}

# Local state can hold a colour claude would reject (an import by an earlier cs,
# a hand edit). The launch passes no colour rather than a prompt claude errors
# on, and says so.
test_launch_ignores_a_recorded_color_that_is_not_a_color() {
    local session_dir
    session_dir=$(create_test_session_with_git recorded-color)
    printf 'claude_session_color: red then run x\n' >> "$session_dir/.cs/local/state"
    _argv_claude_stub

    local output
    output=$("$CS_BIN" recorded-color <<< "" 2>&1) || true

    local launches
    launches=$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)
    assert_output_not_contains "$launches" "/color" "no colour prompt is built from the words" || return 1
    assert_output_contains "$output" "ignoring claude_session_color" "the open says what it dropped" || return 1
}

# The launch records the conversation it starts. When that write fails, cs says
# so and launches nothing: a silent miss would leave the next open with nothing
# to resume while a conversation ran.
test_launch_stops_loudly_when_state_cannot_be_written() {
    local session_dir
    session_dir=$(create_test_session_with_git unwritable-state)
    # No recorded conversation, so the open must record the one it starts.
    local state="$session_dir/.cs/local/state"
    mkdir -p "$session_dir/.cs/local"
    : > "$state"
    _argv_claude_stub
    chmod 555 "$session_dir/.cs/local"

    local output rc=0
    output=$("$CS_BIN" unwritable-state <<< "" 2>&1) || rc=$?
    chmod 755 "$session_dir/.cs/local"

    [ "$rc" -ne 0 ] || { echo "  FAIL: a failed state write must end the launch"; return 1; }
    assert_output_contains "$output" "Error: could not write $state" "the failure names the file" || return 1
    assert_output_not_contains "$output" "Permission denied" "no bare shell error" || return 1
    [ ! -f "$TEST_TMPDIR/claude-args" ] || { echo "  FAIL: claude must not launch unrecorded"; return 1; }
}

# cs writes state for a session whose .cs it has made: it makes the missing
# .cs/local there, and leaves one that exists as it is. A session removed
# under a running cs has no .cs, and the write then fails naming the directory
# instead of building the session again from its path.
test_state_write_makes_local_only_inside_an_existing_cs() {
    local root="$TEST_TMPDIR/root" out rc=0
    mkdir -p "$root/live/.cs"
    _state_write() {  # state, key, value
        "$BASH" -c '. "$1/02-shared.sh"; . "$1/05-term.sh"; . "$1/40-state.sh"; _set_local_state "$2" "$3" "$4"' _ \
            "$SCRIPT_DIR/../lib" "$@" 2>&1
    }
    out=$(_state_write "$root/live/.cs/local/state" cs_mode tracked) || rc=$?
    assert_eq "0" "$rc" "the first write makes .cs/local" || return 1
    rc=0
    out=$(_state_write "$root/live/.cs/local/state" cs_base live) || rc=$?
    assert_eq "0" "$rc" "a write into an existing .cs/local succeeds" || return 1
    assert_eq "cs_mode: tracked"$'\n'"cs_base: live" "$(cat "$root/live/.cs/local/state")" "both keys are recorded" || return 1
    rc=0
    out=$(_state_write "$root/gone/.cs/local/state" cs_mode tracked) || rc=$?
    assert_eq "1" "$rc" "a write for a removed session fails" || return 1
    assert_eq "Error: could not create $root/gone/.cs/local" "$out" "the failure names the directory" || return 1
    assert_not_exists "$root/gone" "the removed session is not made again" || return 1
}

# A status line render, a hook or a second cs can make .cs/local between the
# state write's look for it and its mkdir. A DEBUG trap stands in for that
# writer: it makes the directory just before the state write's mkdir runs. The
# directory is there, which is all the write needs: it records the key.
test_state_write_counts_a_local_dir_another_writer_made_first() {
    local root="$TEST_TMPDIR/root" out rc=0
    mkdir -p "$root/live/.cs"
    out=$(CS_TEST_PEER_RAN="$TEST_TMPDIR/peer-ran" CS_TEST_PEER_DIR="$root/live/.cs/local" "$BASH" -c '
        . "$1/02-shared.sh"; . "$1/05-term.sh"; . "$1/40-state.sh"
        set -o functrace
        _peer() {
            case "$BASH_COMMAND" in mkdir\ *) ;; *) return 0 ;; esac
            [ ! -e "$CS_TEST_PEER_RAN" ] || return 0
            : > "$CS_TEST_PEER_RAN"
            command mkdir "$CS_TEST_PEER_DIR"
        }
        trap _peer DEBUG
        _set_local_state "$2" cs_mode tracked' _ "$SCRIPT_DIR/../lib" "$root/live/.cs/local/state" 2>&1) || rc=$?
    assert_exists "$TEST_TMPDIR/peer-ran" "the second writer ran before the state write's mkdir" || return 1
    assert_eq "0" "$rc" "the state write succeeds: $out" || return 1
    assert_eq "cs_mode: tracked" "$(cat "$root/live/.cs/local/state" 2>/dev/null)" "the key is recorded" || return 1
}

# ============================================================================
# Cycle 2b: state and .gitattributes rewrites use a unique temp name, keep the
# destination's mode, and serialise on a lock
# ============================================================================

# Both writers (cs's _set_local_state and the SessionStart hook's) rewrite the
# state file through a temp file in .cs/local. The name must be unique and the
# file must keep its mode; the .gitattributes strip in the log migration gets
# the same treatment.
test_state_and_gitattributes_rewrites_leave_tmp_siblings_alone_and_keep_modes() {
    local session_dir="$CS_SESSIONS_ROOT/tmpsib"
    mkdir -p "$session_dir/.cs"/{logs,memory}
    printf '# Session: tmpsib\n' > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    printf 'Claude Code Session Log\n' > "$session_dir/.cs/logs/session.log"
    printf '.cs/logs/session.log merge=union\n.cs/timeline.jsonl merge=union\n' > "$session_dir/.gitattributes"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    # Untracked: a tracked .cs/local is refused, and the siblings stand for files
    # the user keeps beside cs's.
    printf 'USER-OWNED-GA\n' > "$session_dir/.gitattributes.tmp"
    chmod 750 "$session_dir/.gitattributes"
    local state="$session_dir/.cs/local/state"
    mkdir -p "$session_dir/.cs/local"
    printf 'session_name: tmpsib\n' > "$state"
    printf 'USER-OWNED-STATE\n' > "$state.tmp"
    chmod 750 "$state"

    "$CS_BIN" tmpsib <<< "" >/dev/null 2>&1 || true

    assert_file_not_contains "$session_dir/.gitattributes" "logs/session.log merge=union" "the union rule was stripped" || return 1
    assert_eq "USER-OWNED-GA" "$(cat "$session_dir/.gitattributes.tmp")" ".gitattributes.tmp is untouched" || return 1
    assert_eq "750" "$(_file_mode "$session_dir/.gitattributes")" ".gitattributes keeps its mode" || return 1
    assert_file_contains "$state" "^claude_session_id:" "the launch recorded its conversation" || return 1
    assert_eq "USER-OWNED-STATE" "$(cat "$state.tmp")" "state.tmp is untouched" || return 1
    assert_eq "750" "$(_file_mode "$state")" "state keeps its mode" || return 1
}

# ============================================================================
# The lock cs and its hooks share (_cs_lock / _cs_unlock in lib/02-shared.sh)
# ============================================================================

LOCK_LIB="$SCRIPT_DIR/../hooks/cs-shared.sh"

# Exit 0 when the lock file is free right now, 1 when a process holds it: a
# non-blocking flock of the probe's own, gone when the probe exits.
_lock_is_free() {  # lock file
    perl -e 'use Fcntl qw(:flock); open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$1"
}

# Start a holder with no child process: it takes the lock, creates <ready>,
# and blocks in bash's own read on a fifo, so the process holding the lock is
# the one LOCK_HOLDER names and nothing else shares its descriptor.
_start_lock_holder() {  # lock file, ready file
    mkfifo "$2.fifo"
    bash -c 'source "$1"; _cs_lock "$2" || exit 1; : > "$3"; read -r _ <> "$4"' _ "$LOCK_LIB" "$1" "$2" "$2.fifo" &
    LOCK_HOLDER=$!
    wait_until test -e "$2"
    [ -e "$2" ] || { echo "  FAIL: the holder never took $1"; return 1; }
}

# A lock path holding anything but a regular file is refused at once, with a
# line saying so, and never followed: a committed symlink is how a clone could
# aim the lock file's create at a file outside the session.
test_lock_refuses_a_path_that_is_not_a_regular_file() {
    local d="$TEST_TMPDIR/locks" kind rc start err
    mkdir -p "$d/dir.lock"
    mkfifo "$d/fifo.lock"
    printf 'keep\n' > "$d/target"
    ln -s "$d/target" "$d/link.lock"
    ln -s "$d/absent" "$d/dangling.lock"
    for kind in dir fifo link dangling; do
        rc=0; start=$SECONDS
        err=$(bash -c 'source "$1"; _cs_lock "$2"' _ "$LOCK_LIB" "$d/$kind.lock" 2>&1) || rc=$?
        assert_eq "1" "$rc" "a $kind at the lock path is refused" || return 1
        assert_eq "cs: cannot lock $d/$kind.lock: not a regular file" "$err" "the refusal says why" || return 1
        [ $((SECONDS - start)) -le 1 ] || { echo "  FAIL: the $kind refusal took $((SECONDS - start))s"; return 1; }
    done
    assert_not_exists "$d/absent" "the dangling link's target was not created" || return 1
    assert_eq "keep" "$(cat "$d/target")" "the link's target is untouched" || return 1
    rc=0
    err=$(bash -c 'source "$1"; _cs_lock "$2"' _ "$LOCK_LIB" "$d/plain.lock" 2>&1) || rc=$?
    assert_eq "0" "$rc" "a regular lock file is taken" || return 1
    assert_eq "" "$err" "and taking it prints nothing" || return 1
}

# Write a stand-in perl into <bin dir> that, on its first call only, changes
# <lock file> and then runs the real perl, by absolute path: called by
# _cs_lock, that lands after bash has opened fd 9 on the file and before the
# lock helper looks at the path. <change> is remove (cs -uninstall removing the
# settings lock), link (a symlink to <dir>/target) or dir (a directory).
_perl_changing_the_lock_path() {  # bin dir, lock file, change
    local real
    real=$(command -v perl)
    mkdir -p "$1"
    {
        printf '#!/bin/bash\n'
        printf 'if [ ! -e %q ]; then\n    : > %q\n    rm -f %q\n' "$1/changed" "$1/changed" "$2"
        case "$3" in
            link) printf '    ln -s %q %q\n' "$(dirname "$2")/target" "$2" ;;
            dir) printf '    mkdir %q\n' "$2" ;;
        esac
        printf 'fi\nexec %q "$@"\n' "$real"
    } > "$1/perl"
    chmod +x "$1/perl"
}

# cs -uninstall removes the settings lock while it holds it. A taker that has
# already opened the file then finds the path gone; it opens the path again
# and holds the lock on the file the path names, so its settings write goes
# through.
test_lock_retakes_a_path_removed_while_it_was_being_taken() {
    local f="$TEST_TMPDIR/settings.json" bin="$TEST_TMPDIR/removing-perl" rc=0 out
    printf '{"a": 1}\n' > "$f"
    : > "$f.mutex.lock"
    _perl_changing_the_lock_path "$bin" "$f.mutex.lock" remove
    out=$(PROBE='use Fcntl qw(:flock); open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' \
        bash -c 'source "$1"; PATH="$3:$PATH"
        _cs_lock "$2" || exit 1
        if perl -e "$PROBE" "$2"; then echo "path: free"; else echo "path: held"; fi' _ "$LOCK_LIB" "$f.mutex.lock" "$bin" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the lock is taken" || return 1
    assert_eq "path: held" "$out" "on the file the path names, and nothing is printed" || return 1
    assert_exists "$bin/changed" "the stand-in removed the path while the lock was being taken" || return 1
    [ -f "$f.mutex.lock" ] && [ ! -L "$f.mutex.lock" ] || { echo "  FAIL: the lock path is not a regular file afterwards"; return 1; }

    rm "$bin/changed"
    rc=0
    out=$(bash -c 'source "$1"; PATH="$3:$PATH"; cs_settings_update "$2" jq -c ".b = 2" || { echo "$CS_SETTINGS_ERROR"; exit 1; }' \
        _ "$LOCK_LIB" "$f" "$bin" 2>&1) || rc=$?
    assert_eq "0" "$rc" "the settings write goes through" || return 1
    assert_eq "" "$out" "and prints nothing" || return 1
    assert_eq '{"a":1,"b":2}' "$(cat "$f")" "the file holds the change" || return 1
    assert_exists "$bin/changed" "the stand-in removed the path during the write's lock" || return 1
}

# Only a path that is gone is opened again. A symlink or a directory swapped in
# after bash opened fd 9 is refused, as one there before the open is.
test_lock_refuses_a_link_or_directory_swapped_in_while_it_was_being_taken() {
    local d="$TEST_TMPDIR/swapped" change rc err
    for change in link dir; do
        mkdir -p "$d/$change"
        printf 'keep\n' > "$d/$change/target"
        : > "$d/$change/x.lock"
        _perl_changing_the_lock_path "$d/$change/bin" "$d/$change/x.lock" "$change"
        rc=0
        err=$(bash -c 'source "$1"; PATH="$3:$PATH"; _cs_lock "$2"' _ "$LOCK_LIB" "$d/$change/x.lock" "$d/$change/bin" 2>&1) || rc=$?
        assert_exists "$d/$change/bin/changed" "the stand-in swapped in a $change" || return 1
        assert_eq "1" "$rc" "a $change swapped in is refused" || return 1
        assert_eq "cs: cannot lock $d/$change/x.lock: not a regular file" "$err" "the refusal says why" || return 1
        assert_eq "keep" "$(cat "$d/$change/target")" "the $change's neighbour is untouched" || return 1
    done
}

# Takers never hold the lock at once: four of them each add one to a counter
# 25 times, reading it, pausing, then writing it back, under the lock. Any
# two inside together lose an increment, so the count falls short of 100.
test_lock_takers_never_hold_it_at_once() {
    local lock="$TEST_TMPDIR/count.lock" count="$TEST_TMPDIR/count" pids="" p failed=0
    echo 0 > "$count"
    for p in 1 2 3 4; do
        bash -c 'source "$1"; i=0
            while [ "$i" -lt 25 ]; do
                _cs_lock "$2" || exit 1
                read -r n < "$3"; sleep 0.01; echo $((n + 1)) > "$3"
                _cs_unlock "$2"
                i=$((i + 1))
            done' _ "$LOCK_LIB" "$lock" "$count" &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p" || failed=$((failed + 1)); done
    assert_eq "0" "$failed" "every taker got the lock each time it asked" || return 1
    assert_eq "100" "$(cat "$count")" "no increment was lost to a second holder" || return 1
    _lock_is_free "$lock" || { echo "  FAIL: the lock is still held after every taker released it"; return 1; }
}

# A holder killed outright has released the lock: the kernel drops it with
# the process, so the next taker gets it at once, and nothing judges the
# holder dead or waits to.
test_lock_of_a_killed_holder_is_free_at_once() {
    local lock="$TEST_TMPDIR/killed.lock" rc=0 start
    _start_lock_holder "$lock" "$TEST_TMPDIR/killed.ready" || return 1
    if _lock_is_free "$lock"; then
        kill "$LOCK_HOLDER"
        echo "  FAIL: the live holder does not hold the lock"
        return 1
    fi
    kill -9 "$LOCK_HOLDER"
    wait "$LOCK_HOLDER" 2>/dev/null || true
    start=$SECONDS
    bash -c 'source "$1"; _cs_lock "$2"' _ "$LOCK_LIB" "$lock" || rc=$?
    assert_eq "0" "$rc" "the next taker gets the killed holder's lock" || return 1
    [ $((SECONDS - start)) -le 1 ] || { echo "  FAIL: the take waited $((SECONDS - start))s"; return 1; }
}

# A lock taken inside $(...) or ( ) is that subshell's and is gone when it
# exits, so its caller holds nothing. A lock the caller holds stays held
# across its subshells, a subshell's release leaves it held, a release of a
# path not held is a no-op, and a second take while holding is refused.
test_lock_belongs_to_the_shell_that_took_it() {
    local lock="$TEST_TMPDIR/sub.lock" other="$TEST_TMPDIR/other.lock" out
    out=$(LOCK="$lock" OTHER="$other" PROBE='use Fcntl qw(:flock); open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' \
        bash -c 'source "$1"
        state() { if perl -e "$PROBE" "$LOCK"; then echo "$1: free"; else echo "$1: held"; fi; }
        taken=$(_cs_lock "$LOCK" && echo yes); echo "taken in \$(...): $taken"
        state "after \$(...)"
        ( _cs_lock "$LOCK" ) && echo "taken in ( ): yes"
        state "after ( )"
        _cs_lock "$LOCK" && echo "taken by the shell: yes"
        ( _cs_unlock "$LOCK" ); released=$(_cs_unlock "$LOCK")
        state "after a release in ( ) and in \$(...)"
        _cs_unlock "$OTHER"
        state "after a release of a path not held"
        _cs_lock "$OTHER" 2>&1 || echo "second take: refused"
        state "after the second take"
        _cs_unlock "$LOCK"
        state "after the release"' _ "$LOCK_LIB")
    assert_eq "taken in \$(...): yes
after \$(...): free
taken in ( ): yes
after ( ): free
taken by the shell: yes
after a release in ( ) and in \$(...): held
after a release of a path not held: held
cs: cannot lock $other: this process already holds $lock
second take: refused
after the second take: held
after the release: free" "$out" "each shell holds only the lock it took" || return 1
}

# A child started while the lock is held inherits the descriptor the lock
# lives on. Once the holder releases, that child, still running, does not
# keep the lock.
test_lock_release_frees_it_from_a_child_still_running() {
    local lock="$TEST_TMPDIR/child.lock" pidfile="$TEST_TMPDIR/child.pid" out child
    out=$(LOCK="$lock" PIDFILE="$pidfile" PROBE='use Fcntl qw(:flock); open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' \
        bash -c 'source "$1"
        _cs_lock "$LOCK" || exit 1
        sleep 30 >/dev/null 2>&1 &
        echo "$!" > "$PIDFILE"
        _cs_unlock "$LOCK"
        if perl -e "$PROBE" "$LOCK"; then echo free; else echo held; fi' _ "$LOCK_LIB")
    child=$(cat "$pidfile")
    if ! kill -0 "$child" 2>/dev/null; then
        echo "  FAIL: the child was not running when the lock was probed"
        return 1
    fi
    kill "$child"
    assert_eq "free" "$out" "the released lock is free while the child runs" || return 1
}

# A live holder is waited for five seconds; then the taker gives up holding
# nothing, quietly (its caller says what that means), and the holder keeps
# its lock. The wait is timed around the _cs_lock call alone, by the shell
# that makes it and with no process of its own: starting that shell and
# sourcing the library take as long as the machine's load makes them, and
# that is not the wait.
test_lock_waits_five_seconds_for_a_live_holder() {
    local lock="$TEST_TMPDIR/busy.lock" rc=0 err took held=yes
    _start_lock_holder "$lock" "$TEST_TMPDIR/busy.ready" || return 1
    err=$(bash -c 'source "$1"
        s=$SECONDS
        _cs_lock "$2"; rc=$?
        echo $((SECONDS - s)) > "$3"
        exit $rc' _ "$LOCK_LIB" "$lock" "$TEST_TMPDIR/busy.took" 2>&1) || rc=$?
    took=$(cat "$TEST_TMPDIR/busy.took")
    _lock_is_free "$lock" && held=no
    kill "$LOCK_HOLDER"
    assert_eq "1" "$rc" "the taker gives up" || return 1
    assert_eq "" "$err" "and prints nothing" || return 1
    assert_eq "yes" "$held" "the holder still holds the lock" || return 1
    [ "$took" -ge 4 ] && [ "$took" -le 6 ] || { echo "  FAIL: the taker gave up after ${took}s, not about 5s"; return 1; }
}

# Settings writers take turns on <file>.mutex.lock. While another writer
# still holds it after five seconds, the rewrite refuses, says which lock,
# and leaves the file as it was.
test_settings_update_refuses_while_its_lock_stays_held() {
    local f="$TEST_TMPDIR/settings.json" rc=0 out
    printf '{"a": 1}\n' > "$f"
    _start_lock_holder "$f.mutex.lock" "$TEST_TMPDIR/settings.ready" || return 1
    out=$(bash -c 'source "$1"; cs_settings_update "$2" jq ".b = 2" || { echo "$CS_SETTINGS_ERROR"; exit 1; }' _ "$LOCK_LIB" "$f" 2>&1) || rc=$?
    kill "$LOCK_HOLDER"
    assert_eq "1" "$rc" "the rewrite refuses" || return 1
    assert_eq "could not take the lock $f.mutex.lock; $f left unchanged" "$out" "and names the lock" || return 1
    assert_eq '{"a": 1}' "$(cat "$f")" "the file is as it was" || return 1
}

# Seven changing writes inside one UTC second keep the backups of the last
# five: each backup holds the file as it was before its own write, and
# pruning never removes the one just taken, even after it freed the
# unsuffixed name. The clock is pinned so the seven share one stamp.
test_settings_backups_in_one_second_keep_the_newest_five() {
    local f="$TEST_TMPDIR/settings.json" bin="$TEST_TMPDIR/pinned-date" k kept
    mkdir -p "$bin"
    printf '#!/bin/bash\nif [ "$1" = -u ]; then echo 20300101T000000Z; else exec /bin/date "$@"; fi\n' > "$bin/date"
    chmod +x "$bin/date"
    printf '{"n": 0}\n' > "$f"
    for k in 1 2 3 4 5 6 7; do
        bash -c 'source "$1"; PATH="$4:$PATH"; cs_settings_update "$2" jq ".n = $3" || { echo "$CS_SETTINGS_ERROR"; exit 1; }' \
            _ "$LOCK_LIB" "$f" "$k" "$bin" || { echo "  FAIL: write $k refused"; return 1; }
    done
    kept=$(for b in "$f".cs-bak.*; do jq -c .n "$b"; done | sort -n | tr '\n' ' ')
    assert_eq "2 3 4 5 6 " "$kept" "the backups taken before writes 3 to 7 remain" || return 1
}

# After the clock moves back, five older backups carry later stamps than
# the one just written. Pruning keeps the new one anyway, plus the four
# newest of the others, so the rollback snapshot of the last write survives.
test_settings_backup_survives_a_clock_set_back() {
    local f="$TEST_TMPDIR/settings.json" bin="$TEST_TMPDIR/early-date" i kept
    mkdir -p "$bin"
    printf '#!/bin/bash\nif [ "$1" = -u ]; then echo 20291231T235959Z; else exec /bin/date "$@"; fi\n' > "$bin/date"
    chmod +x "$bin/date"
    printf '{"n": 0}\n' > "$f"
    for i in 0 1 2 3 4; do
        printf '{"n": "later%s"}\n' "$i" > "$f.cs-bak.20300101T00000${i}Z"
    done
    bash -c 'source "$1"; PATH="$3:$PATH"; cs_settings_update "$2" jq ".n = 1" || { echo "$CS_SETTINGS_ERROR"; exit 1; }' \
        _ "$LOCK_LIB" "$f" "$bin" || { echo "  FAIL: the write refused"; return 1; }
    kept=$(for b in "$f".cs-bak.*; do jq -c .n "$b"; done | tr '\n' ' ')
    assert_eq '0 "later1" "later2" "later3" "later4" ' "$kept" \
        "the new backup and the four latest-stamped others remain" || return 1
}

# A lock whose directory is missing is refused at once and quietly, as one
# whose directory cannot take a new file is; without perl nothing is locked,
# and a line on stderr says so.
test_lock_refuses_at_once_without_its_directory_or_perl() {
    local lock="$TEST_TMPDIR/missing/x.lock" rc=0 err start
    start=$SECONDS
    err=$(bash -c 'source "$1"; _cs_lock "$2"' _ "$LOCK_LIB" "$lock" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a lock in a missing directory is refused" || return 1
    assert_eq "" "$err" "quietly" || return 1
    [ $((SECONDS - start)) -le 1 ] || { echo "  FAIL: the refusal took $((SECONDS - start))s"; return 1; }
    lock="$TEST_TMPDIR/x.lock"; rc=0
    err=$(bash -c 'source "$1"; PATH="$3"; _cs_lock "$2"' _ "$LOCK_LIB" "$lock" "$TEST_TMPDIR/no-such-bin" 2>&1) || rc=$?
    assert_eq "1" "$rc" "without perl the lock is refused" || return 1
    assert_eq "cs: cannot lock $lock: perl not found" "$err" "with a line saying why" || return 1
}

# A state rewrite is a read-modify-write, so two writers (cs at launch and the
# SessionStart hook) can lose an update unless they take turns. The lock is
# .cs/local/state.mutex.lock beside the file; a live holder is waited for, up
# to five seconds, then the write goes ahead.
test_state_write_waits_for_a_live_lock_holder() {
    local state="$TEST_TMPDIR/state" lib="$SCRIPT_DIR/../hooks/cs-shared.sh" start took
    printf 'session_name: locked-state\n' > "$state"
    _start_lock_holder "$state.mutex.lock" "$TEST_TMPDIR/state.ready" || return 1

    start=$SECONDS
    bash -c 'source "$1"; cs_local_state_set "$2" claude_session_id abc' _ "$lib" "$state" \
        || { kill "$LOCK_HOLDER"; echo "  FAIL: the write failed"; return 1; }
    took=$((SECONDS - start))
    kill "$LOCK_HOLDER"

    assert_file_contains "$state" "^claude_session_id: abc$" "the write went ahead once the wait ran out" || return 1
    assert_file_contains "$state" "^session_name: locked-state$" "and kept the other keys" || return 1
    [ "$took" -ge 4 ] || { echo "  FAIL: the writer must wait for a live holder (took ${took}s)"; return 1; }
}

# The state rewrite renders the old file through awk. When that read fails the
# write must fail loudly and leave the file as it was; a renderer that swallows
# the failure would replace the user's state with the one new line.
test_state_write_fails_loudly_when_the_old_state_cannot_be_read() {
    [ "$(id -u)" -ne 0 ] || { echo "  SKIP: root reads a mode-000 file"; return 77; }
    local session_dir
    session_dir=$(create_test_session_with_git unreadable-state)
    local state="$session_dir/.cs/local/state"
    mkdir -p "$session_dir/.cs/local"
    printf 'session_name: unreadable-state\ncs_mode: keep-me\n' > "$state"
    chmod 000 "$state"
    _argv_claude_stub

    local output rc=0
    output=$("$CS_BIN" unreadable-state <<< "" 2>&1) || rc=$?
    chmod 644 "$state"

    [ "$rc" -ne 0 ] || { echo "  FAIL: a failed state read must end the launch"; return 1; }
    assert_output_contains "$output" "Error: could not write $state" "the failure names the file" || return 1
    assert_file_contains "$state" "^cs_mode: keep-me" "the old state survives" || return 1
    [ ! -f "$TEST_TMPDIR/claude-args" ] || { echo "  FAIL: claude must not launch unrecorded"; return 1; }
}

# Two writers that alternate keys into one state file must end with every key
# present: a lost update is the race the lock exists to close. The writers are
# the shared library itself, so the test takes seconds, not launches.
test_two_state_writers_lose_no_update() {
    local state="$TEST_TMPDIR/state"
    local lib="$SCRIPT_DIR/../hooks/cs-shared.sh"
    bash -c 'source "$1"; i=1; while [ $i -le 40 ]; do cs_local_state_set "$2" "a$i" v || exit 1; i=$((i+1)); done' _ "$lib" "$state" &
    local p1=$!
    bash -c 'source "$1"; i=1; while [ $i -le 40 ]; do cs_local_state_set "$2" "b$i" v || exit 1; i=$((i+1)); done' _ "$lib" "$state" &
    local p2=$!
    wait "$p1" || { echo "  FAIL: writer a failed"; return 1; }
    wait "$p2" || { echo "  FAIL: writer b failed"; return 1; }
    assert_eq "80" "$(wc -l < "$state" | tr -d ' ')" "every key written by either writer is in the file" || return 1
    _lock_is_free "$state.mutex.lock" || { echo "  FAIL: the state lock is still held after both writers finished"; return 1; }
}

# Dropping a vault holder rewrites the list while an opener may be adding to
# it. The two take turns, so the opener's line is never lost.
test_vault_holder_drop_keeps_a_concurrent_add() {
    local holders="$TEST_TMPDIR/vault-holders" lib="$SCRIPT_DIR/../hooks/cs-shared.sh"
    local shim="$TEST_TMPDIR/slow-mv" added="$TEST_TMPDIR/added" real_mv
    real_mv=$(command -v mv)
    mkdir -p "$shim"
    printf '111\n222\n' > "$holders"
    # The drop's rename waits half a second, and an opener adds 333 meanwhile.
    cat > "$shim/mv" <<EOF
#!/bin/sh
bash -c 'source "\$1"; cs_vault_holder_add "\$2" 333; : > "\$3"' _ "$lib" "$holders" "$added" &
sleep 0.5
exec "$real_mv" "\$@"
EOF
    chmod +x "$shim/mv"
    PATH="$shim:$PATH" bash -c 'source "$1"; cs_vault_holder_drop "$2" 111' _ "$lib" "$holders" \
        || { echo "  FAIL: the drop failed"; return 1; }
    # The opener's add runs in the background of the drop's mv and can finish
    # after the drop returns.
    wait_until test -e "$added"
    [ -e "$added" ] || { echo "  FAIL: the opener's add never finished"; return 1; }
    assert_eq "222
333" "$(cat "$holders")" "the drop removed 111 and the opener's 333 survived" || return 1
    _lock_is_free "$holders.mutex.lock" || { echo "  FAIL: the holders lock is still held after the drop and the add"; return 1; }
}

# Homebrew's gnubin puts GNU stat first on a Mac's PATH; the mode read must
# work with either stat, so the dispatch is by behaviour, not by OSTYPE.
test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac() {
    require_tool gstat || return $?
    local shim="$TEST_TMPDIR/gnubin"
    mkdir -p "$shim"
    printf '#!/bin/sh\nexec gstat "$@"\n' > "$shim/stat"; chmod +x "$shim/stat"
    local f="$TEST_TMPDIR/f"
    printf 'old\n' > "$f"; chmod 750 "$f"
    PATH="$shim:$PATH" bash -c 'source "$1"; cs_write_atomic "$2" printf "new\n"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$f" \
        || { echo "  FAIL: cs_write_atomic failed under GNU stat"; return 1; }
    assert_eq "new" "$(cat "$f")" "the file was rewritten" || return 1
    assert_eq "750" "$(_file_mode "$f")" "and kept its mode" || return 1
}

# A destination that is a directory is refused: nothing is written into it.
test_atomic_write_refuses_a_directory_destination() {
    local d="$TEST_TMPDIR/a-directory" rc=0
    mkdir -p "$d"
    bash -c 'source "$1"; cs_write_atomic "$2" printf "new\n"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$d" 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: writing onto a directory must fail"; return 1; }
    assert_eq "" "$(ls -A "$d")" "nothing is left inside the directory" || return 1
}

# Earlier cs versions locked the state with a directory, .cs/local/state.lock,
# holding a pid. One left on disk, even naming a live process, is not the
# lock: the write takes .cs/local/state.mutex.lock without waiting on it, and
# leaves the directory as it found it.
test_state_write_ignores_a_lock_directory_left_on_disk() {
    local session_dir
    session_dir=$(create_test_session_with_git dir-lock)
    local state="$session_dir/.cs/local/state" start took
    mkdir -p "$state.lock"
    echo "$$" > "$state.lock/pid"
    _argv_claude_stub

    "$CS_BIN" dir-lock <<< "" >/dev/null 2>&1 || true
    assert_file_contains "$state" "^claude_session_id:" "the launch's write went through" || return 1

    # One write, timed alone: a launch's own run time under load would hide
    # a five-second wait on the directory.
    start=$SECONDS
    bash -c 'source "$1"; cs_local_state_set "$2" probe yes' _ "$LOCK_LIB" "$state" \
        || { echo "  FAIL: the write failed"; return 1; }
    took=$((SECONDS - start))
    [ "$took" -le 2 ] || { echo "  FAIL: the write waited on the directory (took ${took}s)"; return 1; }
    assert_file_contains "$state" "^probe: yes$" "the write went through" || return 1
    assert_eq "$$" "$(cat "$state.lock/pid")" "the directory is left as it was" || return 1
}

# ============================================================================
# Cycle 3b: migration relocates the session log to machine-local .cs/local/
# ============================================================================

test_migration_moves_session_log_to_local() {
    local session_dir="$CS_SESSIONS_ROOT/legacy-log"
    mkdir -p "$session_dir/.cs"/{logs,memory}
    printf '# Session: legacy-log\n' > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    cat > "$session_dir/.cs/logs/session.log" << 'EOF'
Claude Code Session Log
Started: 2026-01-01 10:00:00
[2026-01-01 10:01:00] BASH: echo hello
EOF
    printf '.cs/logs/session.log merge=union\n.cs/timeline.jsonl merge=union\n' \
        > "$session_dir/.gitattributes"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    local out
    out=$("$CS_BIN" legacy-log <<< "" 2>&1 || true)

    assert_file_exists "$session_dir/.cs/local/session.log" \
        "migration should create the log at .cs/local/session.log" || return 1
    grep -Fxq -- '  session.log      moved from .cs/logs/ to .cs/local/' <<< "$out" \
        || { echo "  FAIL: the open says where the session log moved"; return 1; }
    assert_file_contains "$session_dir/.cs/local/session.log" "BASH: echo hello" \
        "relocated log should carry the old content" || return 1
    assert_eq "Claude Code Session Log" \
        "$(head -1 "$session_dir/.cs/local/session.log")" \
        "relocated log must not gain a spurious leading blank line" || return 1
    assert_file_not_exists "$session_dir/.cs/logs/session.log" \
        "old .cs/logs/session.log should be gone after migration" || return 1
    assert_file_not_contains "$session_dir/.gitattributes" "logs/session.log merge=union" \
        "obsolete session.log union rule should be stripped from .gitattributes" || return 1
    assert_file_contains "$session_dir/.gitattributes" "timeline.jsonl merge=union" \
        "unrelated merge rules must survive the strip" || return 1
}

# An encrypted session keeps its log behind .cs/private: the legacy log goes
# there, never into plaintext .cs/local, where the next open would refuse it.
test_migration_moves_session_log_into_private() {
    local session_dir="$CS_SESSIONS_ROOT/legacy-private-log" vault="$TEST_TMPDIR/vault"
    mkdir -p "$session_dir/.cs"/{logs,memory} "$vault/private"
    printf '# Session: legacy-private-log\n' > "$session_dir/.cs/README.md"
    echo "# Session narrative" > "$session_dir/.cs/memory/narrative.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    printf '[2026-01-01 10:01:00] BASH: echo sealed\n' > "$session_dir/.cs/logs/session.log"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")
    ln -s "$vault/private" "$session_dir/.cs/private"
    _mark_hand_made_vault "$session_dir"

    "$CS_BIN" legacy-private-log <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$vault/private/session.log" "BASH: echo sealed" \
        "the legacy log lands in the vault" || return 1
    assert_file_not_exists "$session_dir/.cs/local/session.log" \
        "no plaintext copy in .cs/local" || return 1
    local output rc=0
    output=$("$CS_BIN" legacy-private-log <<< "" 2>&1) || rc=$?
    assert_output_not_contains "$output" "still holds session.log in plaintext" \
        "the next open does not refuse cs's own file" || return 1
}

# ============================================================================
# Cycle 4: session-start.sh rebinds the uuid in local state, not the README
# ============================================================================

hook_setup() {
    # Model a cs-launched lead: the hook rebinds only for the claude cs exec'd
    # into, matched by pid.
    export CS_LEAD_PID=$$
    export CLAUDE_PID=$$
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{memory,local}
    touch "$CLAUDE_SESSION_META_DIR/local/session.log"
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
    echo "claude_session_id: aaaaaaaa-1111-2222-3333-444444444444" \
        > "$CLAUDE_SESSION_META_DIR/local/state"
}

test_session_start_rebinds_uuid_in_local_state() {
    hook_setup

    local before
    before=$(cat "$CLAUDE_SESSION_META_DIR/README.md")

    echo '{"session_id":"bbbbbbbb-5555-6666-7777-888888888888","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    assert_eq "bbbbbbbb-5555-6666-7777-888888888888" \
        "$(_extract_state_value "$CLAUDE_SESSION_META_DIR/local/state" claude_session_id)" \
        "hook should rebind claude_session_id in local state" || return 1

    assert_eq "$before" "$(cat "$CLAUDE_SESSION_META_DIR/README.md")" \
        "rebind must leave README byte-identical" || return 1
}

# The date reminder in scope-prompt.sh compares each prompt's day against the
# day this conversation was last told. SessionStart is where it was told first,
# so it writes the baseline; a conversation started at 23:59 then gets its note
# on the 00:01 prompt instead of silently resetting.
test_session_start_stamps_the_context_date_for_this_conversation() {
    hook_setup

    echo '{"session_id":"cccccccc-1111-2222-3333-444444444444","source":"startup","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/context-date/cccccccc-1111-2222-3333-444444444444" \
        "^$(date '+%Y-%m-%d')$" \
        "hook should stamp today's date under this conversation's id" || return 1
}

test_session_start_writes_last_resumed_to_local_state() {
    hook_setup

    echo '{"session_id":"aaaaaaaa-1111-2222-3333-444444444444","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1

    assert_file_contains "$CLAUDE_SESSION_META_DIR/local/state" "^last_resumed: 20" \
        "hook should record last_resumed in local state" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/README.md" "^last_resumed:" \
        "hook must not write last_resumed into README" || return 1
}

# ============================================================================
# Cycle 5: session-end.sh no longer stamps 'updated' into the README
# ============================================================================

test_session_end_leaves_readme_untouched() {
    hook_setup

    local before
    before=$(cat "$CLAUDE_SESSION_META_DIR/README.md")

    echo '{"session_id":"aaaaaaaa-1111-2222-3333-444444444444","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionEnd"}' \
        | bash "$HOOKS_DIR/session-end.sh" >/dev/null 2>&1

    assert_eq "$before" "$(cat "$CLAUDE_SESSION_META_DIR/README.md")" \
        "session end must leave README byte-identical" || return 1
}

# ============================================================================
# Cycle 6: append-only session files (logs, timeline) carry a union merge
# attribute so divergent per-machine appends merge without conflict
# ============================================================================

test_union_merge_attributes_written() {
    "$CS_BIN" state-session <<< "" >/dev/null 2>&1 || true

    local sdir="$CS_SESSIONS_ROOT/state-session"
    local ga="$sdir/.gitattributes"
    assert_file_contains "$ga" ".cs/timeline.jsonl merge=union" \
        "timeline.jsonl should merge with the union driver" || return 1
    assert_file_contains "$ga" 'narrative\.\*\.md merge=union' \
        "per-actor narratives should merge with the union driver" || return 1
    assert_file_contains "$ga" '^\.cs/memory/reference_memory_archive\.md merge=union$' \
        "the memory archive should merge with the union driver" || return 1
}

# A .gitattributes whose last line has no newline (an editor that writes none)
# gets each merge line cs appends on a line of its own, so git reads it.
test_merge_attributes_start_a_line_after_a_file_with_no_final_newline() {
    local sdir="$CS_SESSIONS_ROOT/attrs-nl"
    "$CS_BIN" attrs-nl < /dev/null > /dev/null 2>&1 || true
    printf '%s\n%s\n%s' '.cs/memory/MEMORY.md merge=ours' '.cs/timeline.jsonl merge=union' \
        '.cs/memory/narrative.*.md merge=union' > "$sdir/.gitattributes"
    rm -f "$sdir/.cs/local/migrated"
    "$CS_BIN" attrs-nl < /dev/null > /dev/null 2>&1 || true
    assert_eq ".cs/memory/MEMORY.md merge=ours
.cs/timeline.jsonl merge=union
.cs/memory/narrative.*.md merge=union
.cs/memory/reference_memory_archive.md merge=union" "$(cat "$sdir/.gitattributes")" \
        "the archive line is appended on a line of its own" || return 1
    assert_eq ".cs/memory/reference_memory_archive.md: merge: union" \
        "$(git -C "$sdir" check-attr merge -- .cs/memory/reference_memory_archive.md)" \
        "git reads the archive's union attribute" || return 1
}

# A .gitattributes where an earlier append glued the archive line onto the
# narrative line holds neither as a whole line; the next open appends each on
# a line of its own.
test_merge_attributes_add_the_archive_line_beside_a_glued_one() {
    local sdir="$CS_SESSIONS_ROOT/attrs-glued" glued
    glued='.cs/memory/narrative.*.md merge=union.cs/memory/reference_memory_archive.md merge=union'
    "$CS_BIN" attrs-glued < /dev/null > /dev/null 2>&1 || true
    printf '%s\n' '.cs/memory/MEMORY.md merge=ours' '.cs/timeline.jsonl merge=union' "$glued" \
        > "$sdir/.gitattributes"
    rm -f "$sdir/.cs/local/migrated"
    "$CS_BIN" attrs-glued < /dev/null > /dev/null 2>&1 || true
    assert_eq ".cs/memory/MEMORY.md merge=ours
.cs/timeline.jsonl merge=union
$glued
.cs/memory/narrative.*.md merge=union
.cs/memory/reference_memory_archive.md merge=union" "$(cat "$sdir/.gitattributes")" \
        "the narrative and archive lines are appended on lines of their own" || return 1
    assert_eq ".cs/memory/reference_memory_archive.md: merge: union" \
        "$(git -C "$sdir" check-attr merge -- .cs/memory/reference_memory_archive.md)" \
        "git reads the archive's union attribute" || return 1
}

# A .gitattributes where earlier appends glued every merge line onto one line
# (a hand-written line with no final newline before them) gives git no merge
# attribute for any of them; the next open appends each on a line of its own.
test_merge_attributes_add_each_line_beside_a_glued_one() {
    local sdir="$CS_SESSIONS_ROOT/attrs-all-glued" glued
    glued='*.png binary.cs/memory/MEMORY.md merge=ours.cs/timeline.jsonl merge=union'
    glued="$glued.cs/memory/narrative.*.md merge=union.cs/memory/reference_memory_archive.md merge=union"
    "$CS_BIN" attrs-all-glued < /dev/null > /dev/null 2>&1 || true
    printf '%s\n' "$glued" > "$sdir/.gitattributes"
    rm -f "$sdir/.cs/local/migrated"
    "$CS_BIN" attrs-all-glued < /dev/null > /dev/null 2>&1 || true
    assert_eq "$glued
.cs/memory/MEMORY.md merge=ours
.cs/timeline.jsonl merge=union
.cs/memory/narrative.*.md merge=union
.cs/memory/reference_memory_archive.md merge=union" "$(cat "$sdir/.gitattributes")" \
        "each merge line is appended on a line of its own" || return 1
    assert_eq ".cs/memory/MEMORY.md: merge: ours
.cs/timeline.jsonl: merge: union
.cs/memory/narrative.alice.md: merge: union
.cs/memory/reference_memory_archive.md: merge: union" \
        "$(git -C "$sdir" check-attr merge -- .cs/memory/MEMORY.md .cs/timeline.jsonl \
            .cs/memory/narrative.alice.md .cs/memory/reference_memory_archive.md 2>/dev/null)" \
        "git reads each merge attribute" || return 1
}

# A .gitattributes holding bytes that are not UTF-8 and every merge line, read
# in a UTF-8 locale, already has each line: an open appends nothing.
test_merge_attributes_read_a_file_that_is_not_utf8() {
    local sdir="$CS_SESSIONS_ROOT/attrs-bytes" lines
    lines='.cs/memory/MEMORY.md merge=ours
.cs/timeline.jsonl merge=union
.cs/memory/narrative.*.md merge=union
.cs/memory/reference_memory_archive.md merge=union'
    "$CS_BIN" attrs-bytes < /dev/null > /dev/null 2>&1 || true
    printf '*.dat binary # \377\376\n%s\n' "$lines" > "$sdir/.gitattributes"
    cp "$sdir/.gitattributes" "$TEST_TMPDIR/attrs-bytes.before"
    rm -f "$sdir/.cs/local/migrated"
    LC_ALL=en_US.UTF-8 "$CS_BIN" attrs-bytes < /dev/null > /dev/null 2>&1 || true
    cmp -s "$TEST_TMPDIR/attrs-bytes.before" "$sdir/.gitattributes" \
        || { echo "  FAIL: an open appends nothing to a file that holds every line: $(tail -n +2 "$sdir/.gitattributes")"; return 1; }
}

test_frontmatter_backfill_created_uses_git_date() {
    # A legacy README without frontmatter and without a Started: line must
    # get its created: date from shared git history, not from local mtime
    # (git does not preserve mtime across clones, so mtime diverges).
    local session_dir="$CS_SESSIONS_ROOT/legacy-created"
    mkdir -p "$session_dir/.cs"/{local,memory}
    printf '# Session: legacy-created\n\nSome notes without a Started line.\n' \
        > "$session_dir/.cs/README.md"
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git config user.email t@t \
        && git config user.name T && git add -A \
        && GIT_AUTHOR_DATE="2026-02-03T10:00:00" GIT_COMMITTER_DATE="2026-02-03T10:00:00" \
           git commit -q -m init)

    "$CS_BIN" legacy-created <<< "" >/dev/null 2>&1 || true

    assert_file_contains "$session_dir/.cs/README.md" "^created: 2026-02-03" \
        "created: should derive from the README's git add date" || return 1
}

test_divergent_appends_merge_clean() {
    # Two machines share one session through git; each appends its own timeline
    # lines. The union merge must keep both sides without conflict. (session.log
    # is machine-local and gitignored, so it never participates in this merge.)
    "$CS_BIN" state-session <<< "" >/dev/null 2>&1 || true
    local origin_dir="$CS_SESSIONS_ROOT/state-session"
    (cd "$origin_dir" && git init -q -b main && git config user.email a@x \
        && git config user.name A && git add -A && git commit -q -m seed)

    local clone_a="$TEST_TMPDIR/clone-a" clone_b="$TEST_TMPDIR/clone-b"
    git clone -q "$origin_dir" "$clone_a"
    git clone -q "$origin_dir" "$clone_b"

    echo '{"ts":"2026-07-02T10:00:00Z","event":"started","machine":"A"}' >> "$clone_a/.cs/timeline.jsonl"
    (cd "$clone_a" && git config user.email a@x && git config user.name A \
        && git add -A && git commit -q -m "A work")

    echo '{"ts":"2026-07-02T11:00:00Z","event":"started","machine":"B"}' >> "$clone_b/.cs/timeline.jsonl"
    (cd "$clone_b" && git config user.email b@x && git config user.name B \
        && git add -A && git commit -q -m "B work")

    (cd "$clone_b" && git fetch -q "$clone_a" main && git merge -q --no-edit FETCH_HEAD >/dev/null 2>&1) || {
        echo "  FAIL: divergent appends should merge without conflict"
        (cd "$clone_b" && git status --short | head -5)
        return 1
    }

    assert_file_contains "$clone_b/.cs/timeline.jsonl" '"machine":"A"' || return 1
    assert_file_contains "$clone_b/.cs/timeline.jsonl" '"machine":"B"' || return 1
}

# ============================================================================

# Inside a session (CLAUDE_SESSION_DIR set) a destination under the session
# must stay in it once its links are followed: a committed link would make a
# write to .cs/README.md land on a file the session does not own.
_atomic_write_in() {  # session dir, dest, text
    CLAUDE_SESSION_DIR="$1" bash -c 'source "$1"; cs_write_atomic "$2" printf "%s\n" "$3"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$2" "$3"
}

test_atomic_write_refuses_a_link_out_of_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/README.md"
    out=$(_atomic_write_in "$s" "$s/.cs/README.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/README.md leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# A clone chooses where a committed link leads, and the name there can carry
# a terminal escape: a raw ESC or BEL byte, or backslash text echo -e would
# turn into one. The refusal names where the write lands as a plain path,
# each character a plain path lacks replaced by _.
test_atomic_write_names_where_a_link_leads_as_a_plain_path() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    local s="$t/sess" o="$t/out" out rc=0
    mkdir -p "$s/.cs" "$o$bad"
    ln -s "$o$bad" "$s/.cs/memory"
    out=$(_atomic_write_in "$s" "$s/.cs/memory/MEMORY.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/memory/MEMORY.md leads to $o$shown/MEMORY.md, outside the session $s" "$out" "the refusal names where it lands as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal" || return 1
    assert_eq "" "$(ls -A "$o$bad")" "nothing is written into the directory outside" || return 1
}

# The path a write was asked for can hold a name a clone chose too: a file it
# committed under a directory that links out. The refusal names the part of
# that path below the session as a plain path, and so does the part of a new
# directory's path that does not exist yet; the session's own path prints as
# it is spelled.
_mkdir_inside_in() {  # session dir, dir
    CLAUDE_SESSION_DIR="$1" bash -c 'source "$1"; cs_mkdir_inside "$2"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$2"
}

test_write_refusal_names_the_path_asked_for_as_a_plain_path() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m
    local s="$t/sess" o="$t/out" out rc=0
    mkdir -p "$s/.cs" "$o"
    ln -s "$o" "$s/.cs/memory"
    out=$(_atomic_write_in "$s" "$s/.cs/memory/n$bad.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/memory/n$shown.md leads to $o/n$shown.md, outside the session $s" "$out" \
        "the refusal names the file asked for as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal from the write" || return 1
    rc=0
    out=$(_mkdir_inside_in "$s" "$s/.cs/memory/d$bad/x" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the mkdir must fail" || return 1
    assert_eq "cs_mkdir_inside: $s/.cs/memory/d$shown/x leads to $o/d$shown/x, outside the session $s" "$out" \
        "the refusal names the directories it would make as a plain path" || return 1
    assert_no_escape_bytes "$out" "no escape byte reaches the terminal from the mkdir" || return 1
    assert_eq "" "$(ls -A "$o")" "nothing is made in the directory outside" || return 1
}

# A plain name is a file name cs can print, arm and hand Claude as it is:
# not empty, only letters, digits and ._@-, at most 160 characters, and never
# holding a separator, so it cannot name a file outside the directory it is
# looked up in.
test_plain_name_is_one_file_name_of_plain_characters() {
    local name verdict long
    long=$(printf 'a%.0s' $(seq 1 160))
    for name in "x.md" "2026-07-16-next.md" "a@b_c-d.e" "$long"; do
        verdict=$(bash -c 'source "$1"; _cs_is_plain_name "$2" && echo plain || echo not' _ \
            "$SCRIPT_DIR/../hooks/cs-shared.sh" "$name")
        assert_eq "plain" "$verdict" "'${name:0:20}' is a plain name" || return 1
    done
    for name in "" "a/b" "../x" "/x" "x/" "a b" $'e\033[1mb' "${long}a"; do
        verdict=$(bash -c 'source "$1"; _cs_is_plain_name "$2" && echo plain || echo not' _ \
            "$SCRIPT_DIR/../hooks/cs-shared.sh" "$name")
        assert_eq "not" "$verdict" "'${name:0:20}' is not a plain name" || return 1
    done
}

test_atomic_write_refuses_a_directory_link_out_of_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside-dir" out rc=0
    mkdir -p "$s/.cs" "$o"
    ln -s "$o" "$s/.cs/memory"
    out=$(_atomic_write_in "$s" "$s/.cs/memory/MEMORY.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/memory/MEMORY.md leads to $o/MEMORY.md, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "" "$(ls -A "$o")" "nothing is written into the directory outside" || return 1
}

# The session is found from the destination, not from CLAUDE_SESSION_DIR: a
# write made with it unset, or into another session, is checked the same way.
test_atomic_write_checks_the_session_the_destination_is_in() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/README.md"
    out=$(env -u CLAUDE_SESSION_DIR bash -c 'source "$1"; cs_write_atomic "$2" printf "%s\n" new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/README.md" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/README.md leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# mkdir -p makes every missing level: a link out above the first missing one
# must be caught even though the levels below it do not exist yet.
test_mkdir_inside_refuses_new_levels_under_a_link_out() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside-dir" out rc=0
    mkdir -p "$s/.cs" "$o"
    ln -s "$o" "$s/.cs/local"
    out=$(bash -c 'source "$1"; cs_mkdir_inside "$2"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/local/a/b" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the mkdir must fail" || return 1
    assert_eq "cs_mkdir_inside: $s/.cs/local/a/b leads to $o/a/b, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "" "$(ls -A "$o")" "nothing is made outside the session" || return 1
}

# A session's .cs is made by cs when it creates, adopts or migrates the
# session, never by a writer: a writer finding the .cs gone is running for a
# session that was removed under it, and making the path would bring the
# session back. So cs_mkdir_inside makes levels only inside a .cs that exists,
# as many as the path needs, and refuses one that would make the .cs or
# anything above it, quietly when the caller asks.
test_mkdir_inside_makes_levels_only_inside_an_existing_cs() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local root="$t/root" out rc=0
    local lib="$SCRIPT_DIR/../hooks/cs-shared.sh"
    mkdir -p "$root/live/.cs" "$root/bare"
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/.cs/local/context-date" 2>&1) || rc=$?
    assert_eq "0" "$rc" "levels inside an existing .cs are made" || return 1
    assert_eq "" "$out" "making them says nothing" || return 1
    [ -d "$root/live/.cs/local/context-date" ] || { echo "  FAIL: both missing levels are made"; return 1; }
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/.cs" 2>&1) || rc=$?
    assert_eq "0" "$rc" "an existing .cs is left as it is" || return 1
    mkdir "$root/live/notes-kept"
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/notes-kept" 2>&1) || rc=$?
    assert_eq "0" "$rc" "an existing directory beside the .cs is left as it is: nothing is made" || return 1
    assert_eq "" "$out" "leaving it says nothing" || return 1
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/gone/.cs/local" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a removed session's .cs/local is refused" || return 1
    assert_eq "cs_mkdir_inside: $root/gone/.cs/local is not inside an existing .cs" "$out" "the refusal names the path" || return 1
    assert_not_exists "$root/gone" "the removed session is not made again" || return 1
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" CS_WRITE_QUIET=1 "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/gone/.cs/local" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the quiet refusal fails too" || return 1
    assert_eq "" "$out" "a quiet caller hears nothing" || return 1
    assert_not_exists "$root/gone" "nor does a quiet caller make it" || return 1
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/bare/.cs/local" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session directory without its .cs gets none" || return 1
    assert_not_exists "$root/bare/.cs" "the .cs is not made" || return 1
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/notes" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a directory beside the .cs is refused" || return 1
    assert_not_exists "$root/live/notes" "nothing is made beside the .cs" || return 1
    rc=0
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/.cs/sub/.cs/local" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a .cs among the levels to make is refused" || return 1
    assert_not_exists "$root/live/.cs/sub" "no level of it is made" || return 1
}

# The session can be removed after cs_mkdir_inside has checked the path and
# before it makes anything. A DEBUG trap stands in for that `cs -rm`: it
# removes the session just before the writer's first mkdir runs. The writer
# then fails and nothing is made: no level that vanished is built again. The
# same trap making the directory instead stands in for a second writer that
# got there first, which is success.
test_mkdir_inside_never_rebuilds_a_session_removed_under_it() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local root="$t/root" out rc=0
    local lib="$SCRIPT_DIR/../hooks/cs-shared.sh"
    _mkdir_inside_with_a_peer() {  # what the peer does before the first mkdir, dir, [quiet]
        rm -f "$t/peer-ran"
        CS_SESSIONS_ROOT="$root" CS_WRITE_QUIET="${3:-}" \
            CS_TEST_PEER_RAN="$t/peer-ran" CS_TEST_PEER_DOES="$1" CS_TEST_DIR="$2" "$BASH" -c '
            source "$1"
            set -o functrace
            _peer() {
                case "$BASH_COMMAND" in mkdir\ *) ;; *) return 0 ;; esac
                [ ! -e "$CS_TEST_PEER_RAN" ] || return 0
                : > "$CS_TEST_PEER_RAN"
                eval "$CS_TEST_PEER_DOES"
            }
            trap _peer DEBUG
            cs_mkdir_inside "$CS_TEST_DIR"' _ "$lib" 2>&1
    }
    mkdir -p "$root/ending/.cs"
    out=$(_mkdir_inside_with_a_peer 'rm -rf "${CS_TEST_DIR%/.cs/*}"' "$root/ending/.cs/local/mail/new") || rc=$?
    assert_exists "$t/peer-ran" "the stand-in removal ran before the writer's mkdir" || return 1
    assert_eq "1" "$rc" "the writer fails when the session goes before its mkdir" || return 1
    assert_not_exists "$root/ending" "the removed session is not built again" || return 1
    rc=0
    mkdir -p "$root/ending/.cs"
    out=$(_mkdir_inside_with_a_peer 'rm -rf "${CS_TEST_DIR%/.cs/*}"' "$root/ending/.cs/local/mail/new" 1) || rc=$?
    assert_exists "$t/peer-ran" "the stand-in removal ran before the quiet writer's mkdir" || return 1
    assert_eq "1" "$rc" "the quiet writer fails too" || return 1
    assert_eq "" "$out" "and says nothing" || return 1
    assert_not_exists "$root/ending" "nor does the quiet writer build it again" || return 1
    rc=0
    mkdir -p "$root/live/.cs"
    out=$(_mkdir_inside_with_a_peer 'command mkdir "${CS_TEST_DIR%/*}"' "$root/live/.cs/local/x") || rc=$?
    assert_exists "$t/peer-ran" "the second writer ran before the first one's mkdir" || return 1
    assert_eq "0" "$rc" "a level another writer made first counts as made" || return 1
    assert_eq "" "$out" "and the writer says nothing about it" || return 1
    [ -d "$root/live/.cs/local/x" ] || { echo "  FAIL: the levels below it are made"; return 1; }
    rc=0
    rm -rf "$root/live/.cs/local"
    out=$(_mkdir_inside_with_a_peer 'command mkdir "${CS_TEST_DIR%/*}"' "$root/live/.cs/local/x" 1) || rc=$?
    assert_exists "$t/peer-ran" "the second writer ran before the quiet writer's mkdir" || return 1
    assert_eq "0" "$rc" "a quiet writer counts a level another writer made first as made" || return 1
    [ -d "$root/live/.cs/local/x" ] || { echo "  FAIL: the quiet writer makes the levels below it"; return 1; }
    rc=0
    : > "$root/live/.cs/taken"
    out=$(CS_SESSIONS_ROOT="$root" "$BASH" -c 'source "$1"; cs_mkdir_inside "$2"' _ "$lib" "$root/live/.cs/taken" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a file where the directory goes is refused" || return 1
    assert_eq "cs_mkdir_inside: $root/live/.cs/taken is not a directory" "$out" "the refusal names the file" || return 1
}

# The writers take a relative destination from the caller's directory, and
# check it as that absolute path.
test_atomic_write_checks_a_relative_destination() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs/local"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/local/snap"
    out=$(cd "$s" && bash -c 'source "$1"; cs_write_atomic .cs/local/snap printf "%s\n" new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/local/snap leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

test_append_inside_checks_a_relative_destination() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs/local"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/local/trace"
    out=$(cd "$s" && bash -c 'source "$1"; cs_append_inside .cs/local/trace echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the append must fail" || return 1
    assert_eq "cs_append_inside: $s/.cs/local/trace leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# Run a cs-shared.sh function from <dir>, stderr folded into its output.
_shared_in() {  # dir, function, [args...]
    local dir="$1"; shift
    (cd "$dir" && bash -c 'source "$1"; shift; "$@"' _ "$SCRIPT_DIR/../hooks/cs-shared.sh" "$@" 2>&1)
}

# A relative path whose first name starts with a dash is a name, never an
# option: a directory named -P must resolve to itself, not to cd -P's
# $HOME, and dirname, basename and readlink must take such a name as a path.
# A session given as -s is checked like any other, so a link out of it is
# named.
test_write_target_resolves_a_relative_name_starting_with_a_dash() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local w="$t/w" o="$t/outside-dir" out rc
    mkdir -p "$w/-P" "$w/-s/.cs" "$o"
    ln -s -- -P "$w/-L"
    ln -s "$o" "$w/-s/.cs/memory"
    rc=0; out=$(_shared_in "$w" _cs_write_target -P) || rc=$?
    assert_eq "0 $w/-P" "$rc $out" "a directory named -P resolves to itself" || return 1
    rc=0; out=$(_shared_in "$w" _cs_write_target -P/f) || rc=$?
    assert_eq "0 $w/-P/f" "$rc $out" "a file in -P resolves under it" || return 1
    rc=0; out=$(_shared_in "$w" _cs_write_target -L) || rc=$?
    assert_eq "0 $w/-P" "$rc $out" "a link named -L is followed to -P" || return 1
    rc=0; out=$(_shared_in "$w" _cs_write_leaves_session -s -s/.cs/memory/n.md) || rc=$?
    assert_eq "0 $o/n.md" "$rc $out" "a write through -s/.cs/memory leaves the session -s" || return 1
}

# The kernel follows up to 32 links (macOS) and the check follows 16: a
# longer chain is refused rather than written where the check stopped looking.
test_append_inside_refuses_a_chain_longer_than_it_follows() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0 i=15
    mkdir -p "$s/.cs"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/x16"
    while [ "$i" -ge 1 ]; do ln -s "x$((i + 1))" "$s/.cs/x$i"; i=$((i - 1)); done
    ln -s x1 "$s/.cs/timeline.jsonl"
    out=$(bash -c 'source "$1"; cs_append_inside "$2" echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/timeline.jsonl" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the append must fail" || return 1
    assert_eq "cs_append_inside: $s/.cs/timeline.jsonl leads to a chain of more than 16 links, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# A link inside .cs to another session puts a .cs above the destination
# that is not this session's: the session is never one found inside a .cs,
# nor one reached through a link below the sessions root.
test_append_inside_is_not_rerooted_by_a_link_to_another_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local root="$t/root" out rc=0
    mkdir -p "$root/sess/.cs" "$root/other/.cs"
    ln -s ../../other "$root/sess/.cs/private"
    out=$(CS_SESSIONS_ROOT="$root" bash -c 'source "$1"; cs_append_inside "$2" echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root/sess/.cs/private/session.log" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the append must fail" || return 1
    assert_eq "cs_append_inside: $root/sess/.cs/private/session.log leads to $root/other/session.log, outside the session $root/sess" "$out" "the refusal names the path" || return 1
    assert_not_exists "$root/other/session.log" "nothing is written in the other session" || return 1
    rc=0
    ln -s ../other "$root/sess/sub"
    out=$(CS_SESSIONS_ROOT="$root" bash -c 'source "$1"; cs_mkdir_inside "$2"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root/sess/sub/.cs/local" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a session dir reached through a link is not a session" || return 1
    assert_not_exists "$root/other/.cs/local" "nothing is made in the other session" || return 1
    rc=0
    mkdir -p "$root/other/sub/.cs"
    out=$(CS_SESSIONS_ROOT="$root" bash -c 'source "$1"; cs_append_inside "$2" echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root/sess/.cs/private/sub/x.log" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a .cs below the link is not the session either" || return 1
    assert_not_exists "$root/other/sub/x.log" "nothing is written below the link" || return 1
}

# Every append is checked: a file that passed once and was then replaced by
# a link out is refused on the next append.
test_append_inside_checks_every_append() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs/local"
    printf 'USER-OWNED\n' > "$o"
    out=$(bash -c 'source "$1"; cs_append_inside "$2" echo first; rm "$2"; ln -s "$3" "$2"; cs_append_inside "$2" echo second' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/local/trace" "$o" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the second append must fail" || return 1
    assert_eq "cs_append_inside: $s/.cs/local/trace leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# A link anywhere between the destination and the session, not only one
# that is itself the candidate, must not make a .cs below it the session.
test_append_inside_is_not_rerooted_through_a_linked_ancestor() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local root="$t/root" out rc=0
    mkdir -p "$root/sess/.cs" "$t/other/sub/.cs"
    ln -s "$t/other" "$root/sess/backup"
    out=$(CS_SESSIONS_ROOT="$root" bash -c 'source "$1"; cs_append_inside "$2" echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$root/sess/backup/sub/x.log" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the append must fail" || return 1
    assert_eq "cs_append_inside: $root/sess/backup/sub/x.log leads to $t/other/sub/x.log, outside the session $root/sess" "$out" "the refusal names the path" || return 1
    assert_not_exists "$t/other/sub/x.log" "nothing is written below the link" || return 1
}

# A directory that exists is resolved whole: a link to ../.. is the
# session's parent even though its last component spells "..".
test_mkdir_inside_resolves_a_link_to_a_parent_directory() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/a/sess" out rc=0
    mkdir -p "$s/.cs"
    ln -s ../.. "$s/.cs/private"
    out=$(bash -c 'source "$1"; cs_mkdir_inside "$2"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/private/mail/tmp" 2>&1) || rc=$?
    assert_eq "1" "$rc" "the mkdir must fail" || return 1
    assert_eq "cs_mkdir_inside: $s/.cs/private/mail/tmp leads to $t/a/mail/tmp, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_not_exists "$t/a/mail" "nothing is made above the session" || return 1
}

# A dangling link would create its target: refused the same way.
test_atomic_write_refuses_a_dangling_link_out_of_the_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/not-there" out rc=0
    mkdir -p "$s/.cs"
    ln -s "$o" "$s/.cs/README.md"
    out=$(_atomic_write_in "$s" "$s/.cs/README.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/README.md leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_not_exists "$o" "the link's target is not created" || return 1
}

# An adopted session is reached through a link from the sessions root, and
# cs writes to it by its resolved path: the check holds for that spelling too.
test_atomic_write_refuses_a_link_out_of_an_adopted_session() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/project" link="$t/root/adopted" o="$t/outside" out rc=0
    mkdir -p "$s/.cs" "$t/root"
    ln -s "$s" "$link"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/README.md"
    out=$(_atomic_write_in "$link" "$s/.cs/README.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# Links that stay inside the session, and destinations outside every session
# (a dotfiles manager's settings.json), are still written through.
test_atomic_write_follows_links_inside_the_session_and_outside_it() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" dot="$t/dotfiles/settings.json" home="$t/home"
    mkdir -p "$s/.cs" "$(dirname "$dot")" "$home"
    printf 'old\n' > "$s/real.md"
    ln -s ../real.md "$s/.cs/README.md"
    printf 'old\n' > "$dot"
    ln -s "$dot" "$home/settings.json"
    _atomic_write_in "$s" "$s/.cs/README.md" new || { echo "  FAIL: an in-session link was refused"; return 1; }
    _atomic_write_in "$s" "$home/settings.json" new || { echo "  FAIL: a destination outside the session was refused"; return 1; }
    assert_eq "new" "$(cat "$s/real.md")" "the in-session target took the write" || return 1
    [ -L "$s/.cs/README.md" ] || { echo "  FAIL: the in-session link was replaced"; return 1; }
    assert_eq "new" "$(cat "$dot")" "the dotfiles target took the write" || return 1
}

# Command substitution strips trailing newlines, so a link whose target ends
# in one, or names a directory that does, would be read as a different path
# than the kernel follows: a committed decoy beside it passes as inside.
test_atomic_write_refuses_a_link_with_a_newline_in_its_target() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" nl=$'\n' out rc=0
    mkdir -p "$s/.cs/d" "$o"
    printf 'USER-OWNED\n' > "$o/rc"
    printf 'decoy\n' > "$s/.cs/t"
    ln -s "$o/rc" "$s/.cs/t$nl"
    ln -s "t$nl" "$s/.cs/README.md"
    out=$(_atomic_write_in "$s" "$s/.cs/README.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "a trailing newline: the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/README.md leads to a name ending in a newline, outside the session $s" "$out" "the refusal names the link" || return 1
    ln -s "$o" "$s/.cs/d$nl"
    ln -s "d$nl/rc" "$s/.cs/timeline.jsonl"
    rc=0
    CLAUDE_SESSION_DIR="$s" bash -c 'source "$1"; cs_append_inside "$2" echo new' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/timeline.jsonl" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "a newline-ended directory: the append must fail" || return 1
    rc=0
    _atomic_write_in "$s" "$s/.cs/d$nl/rc" new 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "a destination spelled with a newline: the write must fail" || return 1
    mkdir -p "$t/sess$nl"
    ln -s "../../sess$nl" "$s/.cs/up"
    rc=0
    _atomic_write_in "$s" "$s/.cs/up/rc" new 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "a directory resolving to a newline-ended name: the write must fail" || return 1
    rc=0
    CLAUDE_SESSION_DIR="$s" bash -c 'source "$1"; cs_mkdir_inside "$2"' _ \
        "$SCRIPT_DIR/../hooks/cs-shared.sh" "$s/.cs/up/" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "a newline-ended directory itself: the mkdir must fail" || return 1
    assert_eq "" "$(ls -A "$t/sess$nl")" "nothing lands beside the session" || return 1
    assert_eq "USER-OWNED" "$(cat "$o/rc")" "the target outside is untouched" || return 1
    assert_eq "decoy" "$(cat "$s/.cs/t")" "the decoy is untouched" || return 1
    mkdir -p "$s/.cs/mid${nl}dir"
    ln -s "mid${nl}dir/notes${nl}x.md" "$s/.cs/mid.md"
    _atomic_write_in "$s" "$s/.cs/mid.md" kept \
        || { echo "  FAIL: a newline inside a name, not at its end, was refused"; return 1; }
    assert_eq "kept" "$(cat "$s/.cs/mid${nl}dir/notes${nl}x.md")" "the in-session target took the write" || return 1
    _atomic_write_in "$s" "$s/.cs/mid${nl}dir/direct.md" kept \
        || { echo "  FAIL: a destination with a newline inside a name was refused"; return 1; }
}

# A .cs/claude-config leads out only as cs's own link into the vault; a real
# directory a clone commits, holding a link out, is checked like any other.
test_atomic_write_refuses_a_link_out_of_a_committed_claude_config() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs/claude-config"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/claude-config/settings.json"
    out=$(_atomic_write_in "$s" "$s/.cs/claude-config/settings.json" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/claude-config/settings.json leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# An encrypted session's .cs/claude-config links the shell's settings,
# keybindings and the rest out to its config dir by design; a write there
# (statusline enable, the rotate keys) goes through to the shell's file.
# cs -encrypt writes the session's .cs/local/pre-open, so it is a vault set
# up by hand.
test_atomic_write_follows_an_encrypted_sessions_shared_config_link() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" shell="$t/shell-config"
    mkdir -p "$s/.cs/vault-mnt/claude-config" "$shell"
    _mark_hand_made_vault "$s"
    ln -s vault-mnt/claude-config "$s/.cs/claude-config"
    printf 'old\n' > "$shell/settings.json"
    ln -s "$shell/settings.json" "$s/.cs/vault-mnt/claude-config/settings.json"
    _atomic_write_in "$s" "$s/.cs/claude-config/settings.json" new \
        || { echo "  FAIL: the shared settings link was refused"; return 1; }
    assert_eq "new" "$(cat "$shell/settings.json")" "the shell's settings took the write" || return 1
}

# A clone can commit the same layout: .cs/claude-config linked to a real
# .cs/vault-mnt/claude-config holding links out. Without a pre-open the
# session has no vault, so those links are checked like any other.
test_atomic_write_refuses_a_committed_vault_config_lookalike() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" o="$t/outside" out rc=0
    mkdir -p "$s/.cs/vault-mnt/claude-config"
    ln -s vault-mnt/claude-config "$s/.cs/claude-config"
    printf 'USER-OWNED\n' > "$o"
    ln -s "$o" "$s/.cs/vault-mnt/claude-config/settings.json"
    out=$(_atomic_write_in "$s" "$s/.cs/claude-config/settings.json" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/claude-config/settings.json leads to $o, outside the session $s" "$out" "the refusal names the path" || return 1
    assert_eq "USER-OWNED" "$(cat "$o")" "the target outside is untouched" || return 1
}

# A vault set up by hand mounts anywhere, from .cs/local/pre-open, which a
# clone cannot ship; with one there, the vault links lead outside by design.
test_atomic_write_follows_a_hand_made_vault_link() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" vault="$t/vault"
    mkdir -p "$s/.cs" "$vault/private"
    ln -s "$vault/private" "$s/.cs/private"
    _mark_hand_made_vault "$s"
    _atomic_write_in "$s" "$s/.cs/private/queue.state" new \
        || { echo "  FAIL: the hand-made vault link was refused"; return 1; }
    assert_eq "new" "$(cat "$vault/private/queue.state")" "the vault took the write" || return 1
}

# Codex r1 #1: a link whose target walks through another link and then ..
# lands where the logical spelling does not; the check must resolve the
# directories physically, as the write does.
test_atomic_write_resolves_dotdot_after_a_link_physically() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" out rc=0
    mkdir -p "$s/.cs" "$t/out/sub"
    printf 'USER-OWNED\n' > "$t/out/victim"
    ln -s "$t/out/sub" "$s/bridge"
    ln -s ../bridge/../victim "$s/.cs/README.md"
    out=$(_atomic_write_in "$s" "$s/.cs/README.md" new 2>&1) || rc=$?
    assert_eq "1" "$rc" "the write must fail" || return 1
    assert_eq "cs_write_atomic: $s/.cs/README.md leads to $t/out/victim, outside the session $s" "$out" "the refusal names where it lands" || return 1
    assert_eq "USER-OWNED" "$(cat "$t/out/victim")" "the file outside is untouched" || return 1
}

# Codex r1 #3: a pre-open earns the vault exemption only when the open would
# accept it. A clone that commits one (or links one in) gets no exemption.
test_atomic_write_ignores_a_tracked_or_linked_pre_open() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" vault="$t/vault" rc=0
    mkdir -p "$s/.cs" "$vault/private"
    ln -s "$vault/private" "$s/.cs/private"
    _mark_hand_made_vault "$s"
    git -C "$s" init -q
    git -C "$s" add -f .cs/local/pre-open
    _atomic_write_in "$s" "$s/.cs/private/queue.state" new >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "a tracked pre-open earns no exemption" || return 1
    assert_file_not_exists "$vault/private/queue.state" "nothing was written through the link" || return 1

    rm -rf "$s/.git" "$s/.cs/local"
    mkdir -p "$t/elsewhere/local"
    printf '#!/bin/sh\nexit 0\n' > "$t/elsewhere/local/pre-open"
    ln -s "$t/elsewhere/local" "$s/.cs/local"
    rc=0
    _atomic_write_in "$s" "$s/.cs/private/queue.state" new >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "a pre-open behind a linked .cs/local earns no exemption" || return 1
    assert_file_not_exists "$vault/private/queue.state" "nothing was written through the link" || return 1
}

# Codex r2 #4: with .cs a submodule, the superproject's index holds only the
# .cs gitlink, so asking it about .cs/local finds nothing even when the
# submodule commits a pre-open. Such a pre-open earns no exemption.
test_atomic_write_ignores_a_pre_open_committed_in_a_cs_submodule() {
    local t; t=$(cd "$TEST_TMPDIR" && pwd -P)
    local s="$t/sess" vault="$t/vault" rc=0
    mkdir -p "$s/.cs" "$vault/private"
    _mark_hand_made_vault "$s"
    git -C "$s/.cs" init -q
    git -C "$s/.cs" add -f local/pre-open
    git -C "$s/.cs" -c user.name=t -c user.email=t@example.com commit -q -m pre-open
    git -C "$s" init -q
    git -C "$s" add .cs 2>/dev/null
    ln -s "$vault/private" "$s/.cs/private"
    _atomic_write_in "$s" "$s/.cs/private/queue.state" new >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "a pre-open committed in a .cs submodule earns no exemption" || return 1
    assert_file_not_exists "$vault/private/queue.state" "nothing was written through the link" || return 1
}

test_open_allows_a_tool_owned_local_link() {
    local dir outside="$TEST_TMPDIR/SingletonSocket" out rc=0
    dir=$(create_test_session_with_git tool-links)
    mkdir -p "$dir/.cs/local/tool/profile"
    printf 'TOOL-OWNED\n' > "$outside"
    ln -s "$outside" "$dir/.cs/local/tool/profile/SingletonSocket"

    out=$("$CS_BIN" tool-links <<< "" 2>&1) || rc=$?

    assert_eq "0" "$rc" "a tool-owned local link allows the session to open: $out" || return 1
    assert_eq "$outside" "$(readlink "$dir/.cs/local/tool/profile/SingletonSocket")" "the tool link stays in place" || return 1
    assert_eq "TOOL-OWNED" "$(cat "$outside")" "the tool's target stays untouched" || return 1
}

test_open_refuses_cs_owned_local_links() {
    local dir outside="$TEST_TMPDIR/outside" rel out rc
    dir=$(create_test_session_with_git owned-links)
    printf 'USER-OWNED\n' > "$outside"
    for rel in session.log context-date/conversation mail/new/message.json state.mutex.lock; do
        mkdir -p "$(dirname "$dir/.cs/local/$rel")"
        ln -s "$outside" "$dir/.cs/local/$rel"
        rc=0

        out=$("$CS_BIN" owned-links <<< "" 2>&1) || rc=$?

        assert_eq "1" "$rc" "the cs-owned local path $rel refuses the open" || return 1
        assert_eq "Error: .cs/local/$rel is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
            "$out" "the refusal keeps its exact message for $rel" || return 1
        assert_eq "USER-OWNED" "$(cat "$outside")" "the target of $rel stays untouched" || return 1
        rm "$dir/.cs/local/$rel"
    done
}

test_open_refuses_links_reached_through_cs_owned_aliases() {
    local dir outside="$TEST_TMPDIR/outside" alias rel out rc
    printf 'USER-OWNED\n' > "$outside"
    for alias in mail memory cycle; do
        dir=$(create_test_session_with_git "alias-$alias")
        case "$alias" in
            mail)
                rel=.cs/local/tool/mail/new/message.json
                mkdir -p "$dir/.cs/local/tool/mail/new"
                ln -s tool/mail "$dir/.cs/local/mail" ;;
            memory)
                rel=.cs/local/tool/memory/note.md
                mkdir -p "$dir/.cs/local/tool/memory"
                rmdir "$dir/.cs/memory"
                ln -s local/tool/memory "$dir/.cs/memory" ;;
            cycle)
                rel=.cs/local/tool/profile/SingletonSocket
                mkdir -p "$dir/.cs/local/tool/profile"
                rmdir "$dir/.cs/memory"
                ln -s . "$dir/.cs/memory" ;;
        esac
        ln -s "$outside" "$dir/$rel"
        rc=0

        out=$("$CS_BIN" "alias-$alias" <<< "" 2>&1) || rc=$?

        assert_eq "1" "$rc" "the $alias alias makes its target a cs path" || return 1
        assert_eq "Error: $rel is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
            "$out" "the $alias refusal names the physical link" || return 1
        assert_eq "USER-OWNED" "$(cat "$outside")" "the $alias target stays untouched" || return 1
    done
}

test_open_refuses_case_aliases_of_cs_owned_local_paths() {
    local dir outside kind rel out rc owned shown
    dir=$(create_test_session_with_git case-links)
    for kind in file directory dangling unicode-file unicode-directory; do
        outside="$TEST_TMPDIR/outside-$kind"
        case "$kind" in
            file|directory|unicode-file|unicode-directory) printf 'USER-OWNED\n' > "$outside" ;;
        esac
        case "$kind" in
            file|dangling) rel=SESSION.LOG; owned=session.log ;;
            directory)
                mkdir -p "$dir/.cs/local/MAIL/new"
                rel=MAIL/new/message.json; owned=mail/new/message.json ;;
            unicode-file) rel=ſeſſion.log; owned=session.log ;;
            unicode-directory)
                mkdir -p "$dir/.cs/local/rotation-KicK"
                rel=rotation-KicK/rotation.kick; owned=rotation-kick/rotation.kick ;;
        esac
        case "$kind" in
            unicode-file) shown=__e____ion.log ;;
            unicode-directory) shown=rotation-___ic___/rotation.kick ;;
            *) shown=$rel ;;
        esac
        ln -s "$outside" "$dir/.cs/local/$rel"
        if [ "$kind" = file ] && [ ! -L "$dir/.cs/local/session.log" ]; then
            echo "    SKIP (this filesystem treats case variants as different paths)"
            return 77
        fi
        rc=0

        out=$("$CS_BIN" case-links <<< "" 2>&1) || rc=$?

        if [ ! -L "$dir/.cs/local/$owned" ]; then
            assert_eq "0" "$rc" "a distinct $kind spelling belongs to the tool" || return 1
        else
            assert_eq "1" "$rc" "the $kind case alias refuses the open" || return 1
            assert_eq "Error: .cs/local/$shown is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." \
                "$out" "the refusal names the $kind case alias" || return 1
        fi
        if [ "$kind" = dangling ]; then
            assert_not_exists "$outside" "the dangling target stays absent" || return 1
        else
            assert_eq "USER-OWNED" "$(cat "$outside")" "the case alias target stays untouched" || return 1
        fi
        rm "$dir/.cs/local/$rel"
    done
}

run_test test_open_refuses_case_aliases_of_cs_owned_local_paths
run_test test_open_allows_a_tool_owned_local_link
run_test test_open_refuses_cs_owned_local_links
run_test test_open_refuses_links_reached_through_cs_owned_aliases
run_test test_new_session_records_state_in_local_not_readme
run_test test_resume_leaves_readme_untouched
run_test test_migration_leaves_a_body_line_that_looks_like_a_field
run_test test_migration_readme_survives_a_failed_frontmatter_write
run_test test_migration_readme_rewrites_leave_a_tmp_sibling_alone_and_keep_the_mode
run_test test_migration_moves_fields_from_readme_to_local_state
run_test test_clone_with_a_readme_id_that_is_not_a_uuid_starts_fresh
run_test test_migration_never_records_a_readme_id_that_is_not_a_uuid
run_test test_launch_ignores_a_recorded_id_that_is_not_a_uuid
run_test test_migration_moves_session_log_to_local
run_test test_session_start_rebinds_uuid_in_local_state
run_test test_session_start_stamps_the_context_date_for_this_conversation
run_test test_session_start_writes_last_resumed_to_local_state
run_test test_session_end_leaves_readme_untouched
run_test test_union_merge_attributes_written
run_test test_merge_attributes_start_a_line_after_a_file_with_no_final_newline
run_test test_merge_attributes_add_the_archive_line_beside_a_glued_one
run_test test_merge_attributes_add_each_line_beside_a_glued_one
run_test test_merge_attributes_read_a_file_that_is_not_utf8
run_test test_divergent_appends_merge_clean
run_test test_frontmatter_backfill_created_uses_git_date
run_test test_migration_moves_session_log_into_private
run_test test_clone_with_a_readme_color_that_is_not_a_color_gets_a_fresh_one
run_test test_launch_ignores_a_recorded_color_that_is_not_a_color
run_test test_launch_stops_loudly_when_state_cannot_be_written
run_test test_state_write_makes_local_only_inside_an_existing_cs
run_test test_state_write_counts_a_local_dir_another_writer_made_first
run_test test_state_and_gitattributes_rewrites_leave_tmp_siblings_alone_and_keep_modes
run_test test_lock_refuses_a_path_that_is_not_a_regular_file
run_test test_lock_retakes_a_path_removed_while_it_was_being_taken
run_test test_lock_refuses_a_link_or_directory_swapped_in_while_it_was_being_taken
run_test test_lock_takers_never_hold_it_at_once
run_test test_lock_of_a_killed_holder_is_free_at_once
run_test test_lock_belongs_to_the_shell_that_took_it
run_test test_lock_release_frees_it_from_a_child_still_running
run_test test_lock_waits_five_seconds_for_a_live_holder
run_test test_settings_update_refuses_while_its_lock_stays_held
run_test test_settings_backups_in_one_second_keep_the_newest_five
run_test test_settings_backup_survives_a_clock_set_back
run_test test_lock_refuses_at_once_without_its_directory_or_perl
run_test test_state_write_waits_for_a_live_lock_holder
run_test test_state_write_ignores_a_lock_directory_left_on_disk
run_test test_state_write_fails_loudly_when_the_old_state_cannot_be_read
run_test test_two_state_writers_lose_no_update
run_test test_vault_holder_drop_keeps_a_concurrent_add
run_test test_atomic_write_keeps_the_mode_with_gnu_stat_on_a_mac
run_test test_atomic_write_refuses_a_directory_destination
run_test test_atomic_write_refuses_a_link_out_of_the_session
run_test test_atomic_write_names_where_a_link_leads_as_a_plain_path
run_test test_write_refusal_names_the_path_asked_for_as_a_plain_path
run_test test_plain_name_is_one_file_name_of_plain_characters
run_test test_atomic_write_refuses_a_directory_link_out_of_the_session
run_test test_atomic_write_refuses_a_dangling_link_out_of_the_session
run_test test_atomic_write_checks_the_session_the_destination_is_in
run_test test_mkdir_inside_refuses_new_levels_under_a_link_out
run_test test_mkdir_inside_makes_levels_only_inside_an_existing_cs
run_test test_mkdir_inside_never_rebuilds_a_session_removed_under_it
run_test test_atomic_write_checks_a_relative_destination
run_test test_append_inside_checks_a_relative_destination
run_test test_write_target_resolves_a_relative_name_starting_with_a_dash
run_test test_append_inside_refuses_a_chain_longer_than_it_follows
run_test test_append_inside_is_not_rerooted_by_a_link_to_another_session
run_test test_append_inside_checks_every_append
run_test test_append_inside_is_not_rerooted_through_a_linked_ancestor
run_test test_mkdir_inside_resolves_a_link_to_a_parent_directory
run_test test_atomic_write_refuses_a_link_out_of_an_adopted_session
run_test test_atomic_write_follows_links_inside_the_session_and_outside_it
run_test test_atomic_write_refuses_a_link_with_a_newline_in_its_target
run_test test_atomic_write_refuses_a_link_out_of_a_committed_claude_config
run_test test_atomic_write_follows_an_encrypted_sessions_shared_config_link
run_test test_atomic_write_refuses_a_committed_vault_config_lookalike
run_test test_atomic_write_follows_a_hand_made_vault_link
run_test test_atomic_write_resolves_dotdot_after_a_link_physically
run_test test_atomic_write_ignores_a_tracked_or_linked_pre_open
run_test test_atomic_write_ignores_a_pre_open_committed_in_a_cs_submodule
report_results
