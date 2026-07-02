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
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CLAUDE_ARTIFACT_DIR 2>/dev/null || true
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
    output=$("$CS_BIN" state-session <<< "" 2>&1) || true

    local session_dir="$CS_SESSIONS_ROOT/state-session"
    local state="$session_dir/.cs/local/state"

    assert_file_exists "$state" \
        ".cs/local/state should exist after first launch" || return 1

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

test_migration_moves_fields_from_readme_to_local_state() {
    local session_dir="$CS_SESSIONS_ROOT/legacy-frontmatter"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
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
# Cycle 4: session-start.sh rebinds the uuid in local state, not the README
# ============================================================================

hook_setup() {
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/current-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    export CLAUDE_ARTIFACT_DIR="$CLAUDE_SESSION_DIR/.cs/artifacts"
    export CLAUDE_SESSION_NAME="current-session"
    mkdir -p "$CLAUDE_SESSION_META_DIR"/{logs,artifacts,memory,local}
    touch "$CLAUDE_SESSION_META_DIR/logs/session.log"
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
    assert_file_contains "$ga" ".cs/logs/session.log merge=union" \
        "session.log should merge with the union driver" || return 1
    assert_file_contains "$ga" ".cs/timeline.jsonl merge=union" \
        "timeline.jsonl should merge with the union driver" || return 1
    assert_file_contains "$ga" 'narrative\.\*\.md merge=union' \
        "per-actor narratives should merge with the union driver" || return 1
    assert_file_contains "$ga" ".cs/artifacts/MANIFEST.json merge=manifest" \
        "MANIFEST.json should use the manifest merge driver" || return 1

    local driver
    driver=$(git -C "$sdir" config merge.manifest.driver 2>/dev/null || true)
    if [ -z "$driver" ]; then
        echo "  FAIL: merge.manifest.driver should be configured in the session repo"
        return 1
    fi
}

test_divergent_manifest_appends_merge_clean() {
    # Two machines each track an artifact; the manifest merge driver must
    # combine both entries into one valid JSON array instead of conflicting.
    "$CS_BIN" state-session <<< "" >/dev/null 2>&1 || true
    local origin_dir="$CS_SESSIONS_ROOT/state-session"
    (cd "$origin_dir" && git init -q -b main && git config user.email a@x \
        && git config user.name A && git add -A && git commit -q -m seed) 2>/dev/null

    local clone_a="$TEST_TMPDIR/mclone-a" clone_b="$TEST_TMPDIR/mclone-b"
    git clone -q "$origin_dir" "$clone_a"
    git clone -q "$origin_dir" "$clone_b"
    # Each machine runs cs at least once before merging; mirror the driver
    # config cs installs rather than re-deriving it in the test.
    local driver
    driver=$(git -C "$origin_dir" config merge.manifest.driver)
    git -C "$clone_a" config merge.manifest.driver "$driver"
    git -C "$clone_b" config merge.manifest.driver "$driver"

    local mf=".cs/artifacts/MANIFEST.json"
    jq '. += [{"filename":"a.sh","original_path":"/a/a.sh","timestamp":"2026-07-02T10:00:00Z","contains_secrets":false}]' \
        "$clone_a/$mf" > "$clone_a/$mf.tmp" && mv "$clone_a/$mf.tmp" "$clone_a/$mf"
    (cd "$clone_a" && git config user.email a@x && git config user.name A \
        && git add -A && git commit -q -m "A artifact")

    jq '. += [{"filename":"b.py","original_path":"/b/b.py","timestamp":"2026-07-02T11:00:00Z","contains_secrets":false}]' \
        "$clone_b/$mf" > "$clone_b/$mf.tmp" && mv "$clone_b/$mf.tmp" "$clone_b/$mf"
    (cd "$clone_b" && git config user.email b@x && git config user.name B \
        && git add -A && git commit -q -m "B artifact")

    (cd "$clone_b" && git fetch -q "$clone_a" main && git merge -q --no-edit FETCH_HEAD >/dev/null 2>&1) || {
        echo "  FAIL: divergent manifest appends should merge without conflict"
        (cd "$clone_b" && git status --short | head -5)
        return 1
    }

    jq -e . "$clone_b/$mf" >/dev/null 2>&1 || {
        echo "  FAIL: merged MANIFEST.json must be valid JSON"
        head -20 "$clone_b/$mf"
        return 1
    }
    assert_file_contains "$clone_b/$mf" '"a.sh"' || return 1
    assert_file_contains "$clone_b/$mf" '"b.py"' || return 1
}

test_frontmatter_backfill_created_uses_git_date() {
    # A legacy README without frontmatter and without a Started: line must
    # get its created: date from shared git history, not from local mtime
    # (git does not preserve mtime across clones, so mtime diverges).
    local session_dir="$CS_SESSIONS_ROOT/legacy-created"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
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
    # Two machines share one session through git; each appends its own log
    # and timeline lines. The merge must keep both sides without conflict.
    "$CS_BIN" state-session <<< "" >/dev/null 2>&1 || true
    local origin_dir="$CS_SESSIONS_ROOT/state-session"
    (cd "$origin_dir" && git init -q -b main && git config user.email a@x \
        && git config user.name A && git add -A && git commit -q -m seed)

    local clone_a="$TEST_TMPDIR/clone-a" clone_b="$TEST_TMPDIR/clone-b"
    git clone -q "$origin_dir" "$clone_a"
    git clone -q "$origin_dir" "$clone_b"

    echo "2026-07-02 10:00:00 - machine A event" >> "$clone_a/.cs/logs/session.log"
    echo '{"ts":"2026-07-02T10:00:00Z","event":"started","machine":"A"}' >> "$clone_a/.cs/timeline.jsonl"
    (cd "$clone_a" && git config user.email a@x && git config user.name A \
        && git add -A && git commit -q -m "A work")

    echo "2026-07-02 11:00:00 - machine B event" >> "$clone_b/.cs/logs/session.log"
    echo '{"ts":"2026-07-02T11:00:00Z","event":"started","machine":"B"}' >> "$clone_b/.cs/timeline.jsonl"
    (cd "$clone_b" && git config user.email b@x && git config user.name B \
        && git add -A && git commit -q -m "B work")

    (cd "$clone_b" && git fetch -q "$clone_a" main && git merge -q --no-edit FETCH_HEAD >/dev/null 2>&1) || {
        echo "  FAIL: divergent appends should merge without conflict"
        (cd "$clone_b" && git status --short | head -5)
        return 1
    }

    assert_file_contains "$clone_b/.cs/logs/session.log" "machine A event" || return 1
    assert_file_contains "$clone_b/.cs/logs/session.log" "machine B event" || return 1
    assert_file_contains "$clone_b/.cs/timeline.jsonl" '"machine":"A"' || return 1
    assert_file_contains "$clone_b/.cs/timeline.jsonl" '"machine":"B"' || return 1
}

# ============================================================================

run_test test_new_session_records_state_in_local_not_readme
run_test test_resume_leaves_readme_untouched
run_test test_migration_moves_fields_from_readme_to_local_state
run_test test_session_start_rebinds_uuid_in_local_state
run_test test_session_start_writes_last_resumed_to_local_state
run_test test_session_end_leaves_readme_untouched
run_test test_union_merge_attributes_written
run_test test_divergent_appends_merge_clean
run_test test_divergent_manifest_appends_merge_clean
run_test test_frontmatter_backfill_created_uses_git_date
report_results
