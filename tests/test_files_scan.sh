#!/usr/bin/env bash
# ABOUTME: Tests for files-scan.sh — the workspace file indexer for .cs/files.md
# ABOUTME: Validates indexing, exclusions, token estimation, and description preservation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SCAN="$SCRIPT_DIR/../hooks/files-scan.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# Helper: populate workspace with a typical mix of files
seed_workspace() {
    mkdir -p "$CLAUDE_SESSION_DIR"/{bin,src,node_modules/lib,dist,build}
    echo "# Session README" > "$CLAUDE_SESSION_DIR/README.md"
    echo "#!/bin/sh" > "$CLAUDE_SESSION_DIR/bin/foo"
    echo "export const main = () => 42;" > "$CLAUDE_SESSION_DIR/src/main.ts"
    echo "module.exports = {}" > "$CLAUDE_SESSION_DIR/node_modules/lib/index.js"
    echo "console.log(1)" > "$CLAUDE_SESSION_DIR/dist/output.js"
    echo "compiled" > "$CLAUDE_SESSION_DIR/build/out.bin"
    : > "$CLAUDE_SESSION_DIR/.DS_Store"
}

# ============================================================================
# Core indexing
# ============================================================================

test_scan_creates_files_md() {
    seed_workspace
    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/files.md" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/files.md" "^## README.md$" \
        "files.md should index README.md" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/files.md" "^## bin/foo$" \
        "files.md should index bin/foo" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/files.md" "^## src/main.ts$" \
        "files.md should index src/main.ts" || return 1
}

test_scan_excludes_dotdirs() {
    seed_workspace
    mkdir -p "$CLAUDE_SESSION_DIR/.git/objects"
    echo "[core]" > "$CLAUDE_SESSION_DIR/.git/config"
    echo "notes" > "$CLAUDE_SESSION_META_DIR/discoveries.md"
    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "\.git/" \
        "files.md should not index anything under .git/" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "\.cs/" \
        "files.md should not index anything under .cs/" || return 1
}

test_scan_excludes_build_outputs() {
    seed_workspace
    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "node_modules/" \
        "node_modules/ should be pruned" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "dist/" \
        "dist/ should be pruned" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "build/" \
        "build/ should be pruned" || return 1
    assert_file_not_contains "$CLAUDE_SESSION_META_DIR/files.md" "DS_Store" \
        ".DS_Store should be skipped" || return 1
}

test_scan_includes_token_estimate() {
    seed_workspace
    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1
    assert_file_contains "$CLAUDE_SESSION_META_DIR/files.md" "~[0-9][0-9]* tokens" \
        "each entry should carry a ~N tokens estimate" || return 1
}

test_scan_arg_overrides_env_meta_dir() {
    # Regression: when invoked with an explicit workspace arg, META_DIR must
    # derive from that arg, not from an inherited CLAUDE_SESSION_META_DIR
    # that points elsewhere. Caught in dev when scan wrote to the wrong .cs/.
    seed_workspace
    local stray_meta="$TEST_TMPDIR/stray-session/.cs"
    mkdir -p "$stray_meta"
    CLAUDE_SESSION_META_DIR="$stray_meta" bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1
    assert_file_exists "$CLAUDE_SESSION_META_DIR/files.md" \
        "scan must write to arg-derived .cs/, not env var" || return 1
    assert_file_not_exists "$stray_meta/files.md" \
        "scan must not write to env-var .cs/ when arg is present" || return 1
}

test_scan_preserves_descriptions() {
    seed_workspace
    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1

    # Hand-edit: insert a description under README.md (single line between heading and ~N tokens)
    awk '
        /^## README\.md$/ {print; print "Session overview written by hand."; next}
        { print }
    ' "$CLAUDE_SESSION_META_DIR/files.md" > "$CLAUDE_SESSION_META_DIR/files.md.tmp"
    mv "$CLAUDE_SESSION_META_DIR/files.md.tmp" "$CLAUDE_SESSION_META_DIR/files.md"

    # Mutate the file so token estimate should change on re-scan
    printf '# Session README\nSecond line.\nThird line.\n' > "$CLAUDE_SESSION_DIR/README.md"

    bash "$SCAN" "$CLAUDE_SESSION_DIR" || return 1

    assert_file_contains "$CLAUDE_SESSION_META_DIR/files.md" \
        "Session overview written by hand" \
        "re-scan must preserve hand-written description" || return 1
}

# ============================================================================
# Run
# ============================================================================

echo "Running files-scan tests..."
run_test test_scan_creates_files_md
run_test test_scan_excludes_dotdirs
run_test test_scan_excludes_build_outputs
run_test test_scan_includes_token_estimate
run_test test_scan_arg_overrides_env_meta_dir
run_test test_scan_preserves_descriptions

report_results
