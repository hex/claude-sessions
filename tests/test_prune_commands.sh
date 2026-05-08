#!/usr/bin/env bash
# ABOUTME: Tests the session-open cleanup that removes commands.md and related artifacts
# ABOUTME: Verifies idempotent removal of legacy data files and CLAUDE.md @-include line

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Build a session dir that looks like one created by an older cs version:
# command-tracker data files present and CLAUDE.md carries the @-include.
populate_legacy_session() {
    local name="$1"
    local session_dir
    session_dir=$(create_test_session "$name")
    mkdir -p "$session_dir/.cs/memory"

    cat > "$session_dir/.cs/commands.md" << 'EOF'
# Project Commands
Auto-discovered CLI commands from prior sessions.

## Dev
- `rg -n "foo" src/` -- [1x, last: 2026-04-20]

## Git
- `git status --short` -- [3x, last: 2026-04-25]
EOF

    cat > "$session_dir/.cs/command-dates.txt" << 'EOF'
git status --short|2026-04-23
git status --short|2026-04-24
git status --short|2026-04-25
EOF

    cat > "$session_dir/.cs/promoted-commands.txt" << 'EOF'
some-promoted-command
EOF

    : > "$session_dir/.cs/commands.md.tmp"

    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries

## Important finding
- This content must survive the migration.
EOF

    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.

## Session Files - READ THESE ON RESUME

1. **.cs/summary.md** - If exists, read first
2. **.cs/README.md** - Session objective
3. **.cs/discoveries.md** - Findings
6. **.cs/artifacts/MANIFEST.json** - List of tracked artifacts
7. **.cs/commands.md** - CLI commands discovered in prior sessions

## Discovered Commands

Useful CLI commands from prior sessions are tracked automatically. These may be stale if the project setup changed — verify before using.

@.cs/commands.md

## Artifact Auto-Tracking

Scripts and configuration files you create are **automatically saved to .cs/artifacts/**.
EOF

    echo "$session_dir"
}

# Removes legacy data files
test_prune_removes_data_files() {
    local session_dir
    session_dir=$(populate_legacy_session "legacy")

    "$CS_BIN" legacy <<< "" >/dev/null 2>&1 || true

    assert_file_not_exists "$session_dir/.cs/commands.md"          "commands.md should be removed" || return 1
    assert_file_not_exists "$session_dir/.cs/commands.md.tmp"      "commands.md.tmp should be removed" || return 1
    assert_file_not_exists "$session_dir/.cs/command-dates.txt"    "command-dates.txt should be removed" || return 1
    assert_file_not_exists "$session_dir/.cs/promoted-commands.txt" "promoted-commands.txt should be removed" || return 1
}

# Strips the @-include and the surrounding "Discovered Commands" section
test_prune_strips_claude_md_include() {
    local session_dir
    session_dir=$(populate_legacy_session "legacy")

    "$CS_BIN" legacy <<< "" >/dev/null 2>&1 || true

    local claude_md="$session_dir/CLAUDE.md"
    assert_file_not_contains "$claude_md" "@.cs/commands.md"            "CLAUDE.md should not retain @-include" || return 1
    assert_file_not_contains "$claude_md" "## Discovered Commands"      "CLAUDE.md should not retain section header" || return 1
    assert_file_not_contains "$claude_md" "CLI commands discovered"      "CLAUDE.md should not retain section body" || return 1
    # Also drop the index entry pointing at the removed file
    assert_file_not_contains "$claude_md" "**.cs/commands.md**"         "CLAUDE.md should not retain index entry" || return 1
    # Other content must be preserved
    assert_file_contains    "$claude_md" "## Artifact Auto-Tracking"    "CLAUDE.md should retain unrelated sections" || return 1
    assert_file_contains    "$claude_md" "## Session Files"             "CLAUDE.md should retain section above" || return 1
}

# Leaves unrelated session data alone
test_prune_preserves_other_session_data() {
    local session_dir
    session_dir=$(populate_legacy_session "legacy")

    "$CS_BIN" legacy <<< "" >/dev/null 2>&1 || true

    assert_file_exists   "$session_dir/.cs/discoveries.md"           "discoveries.md must survive" || return 1
    assert_file_contains "$session_dir/.cs/discoveries.md" "Important finding" "discoveries content must survive" || return 1
    assert_file_exists   "$session_dir/.cs/artifacts/MANIFEST.json"  "MANIFEST.json must survive" || return 1
}

# Idempotent: a second open does no further work and emits no migration message
test_prune_is_idempotent() {
    local session_dir
    session_dir=$(populate_legacy_session "legacy")

    "$CS_BIN" legacy <<< "" >/dev/null 2>&1 || true
    local second_run
    second_run=$("$CS_BIN" legacy <<< "" 2>&1 || true)

    # No removal message on the second open — nothing to remove.
    assert_output_not_contains "$second_run" "commands.md"  "second open should not mention commands.md" || return 1
    # And the data files still don't exist.
    assert_file_not_exists "$session_dir/.cs/commands.md" "commands.md should still be absent on rerun" || return 1
}

# A modern session (no legacy artifacts, modern CLAUDE.md) is untouched
test_prune_noop_on_clean_session() {
    local session_dir="$CS_SESSIONS_ROOT/clean"
    mkdir -p "$session_dir/.cs"/{artifacts,logs,memory}
    echo "[]" > "$session_dir/.cs/artifacts/MANIFEST.json"
    # Mention .cs/ so Phase 5 leaves CLAUDE.md alone
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

Modern session referencing .cs/ paths.
EOF

    local output
    output=$("$CS_BIN" clean <<< "" 2>&1 || true)

    # No artifact files should ever appear
    assert_file_not_exists "$session_dir/.cs/commands.md"           "no commands.md should be created" || return 1
    assert_file_not_exists "$session_dir/.cs/command-dates.txt"     "no command-dates.txt should be created" || return 1
    assert_file_not_exists "$session_dir/.cs/promoted-commands.txt" "no promoted-commands.txt should be created" || return 1
    # And no removal message
    assert_output_not_contains "$output" "commands.md" "clean session should not mention commands.md" || return 1
}

echo "cs prune-commands migration tests"
echo ""
run_test test_prune_removes_data_files
run_test test_prune_strips_claude_md_include
run_test test_prune_preserves_other_session_data
run_test test_prune_is_idempotent
run_test test_prune_noop_on_clean_session

report_results
