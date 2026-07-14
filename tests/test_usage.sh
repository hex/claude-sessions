#!/usr/bin/env bash
# ABOUTME: Tests for cs -usage, the per-session token table over rate-limit windows
# ABOUTME: Covers requestId dedup, window filtering, limits anchoring, sorting, scoped form

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# ISO-8601 UTC timestamp N minutes in the past (BSD date first, GNU fallback).
_iso_mins_ago() {
    date -u -v-"$1"M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%S.000Z
}

# Write a transcript project dir for a session dir, echoing the project dir.
# Uses the same symlink-resolved encoding as _claude_project_dir.
_transcripts_for() {
    local sdir="$1" resolved encoded
    resolved=$( (cd "$sdir" && pwd -P) || printf '%s' "$sdir" )
    encoded=$(echo "$resolved" | sed 's|/|-|g; s|\.|-|g')
    local proj="$CS_TRANSCRIPTS_DIR/$encoded"
    mkdir -p "$proj"
    printf '%s' "$proj"
}

test_usage_subcommand_exists() {
    local output
    output=$("$CS_BIN" -usage 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -usage should be a recognized verb" || return 1
}

run_test test_usage_subcommand_exists
report_results
