#!/usr/bin/env bash
# ABOUTME: Tests for cs -tag: frontmatter read/write contract, validation, and the -list --tag filter
# ABOUTME: Pins the spec's worked examples shared with the TUI's Rust parser

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# A session dir with a README carrying the given frontmatter tags line (or none).
_session_with_readme() {  # name, tags_line ("" = no tags line)
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    {
        echo "---"
        echo "status: active"
        echo "created: 2026-07-15"
        [ -n "$2" ] && echo "$2"
        echo 'aliases: ["'"$1"'"]'
        echo "---"
        echo ""
        echo "## Objective"
        echo "test session"
    } > "$dir/.cs/README.md"
    printf '%s' "$dir"
}

_in_session() {  # name — export ambient env for the in-session verb form
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/$1"
    export CLAUDE_SESSION_META_DIR="$CS_SESSIONS_ROOT/$1/.cs"
}

test_tag_subcommand_exists() {
    local output
    output=$("$CS_BIN" -tag 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -tag should be a recognized verb" || return 1
}

test_tag_add_and_list_roundtrip() {
    _session_with_readme "rt" "tags: []" >/dev/null
    _in_session "rt"
    "$CS_BIN" -tag add api >/dev/null 2>&1 || { echo "  FAIL: add exited non-zero"; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/rt/.cs/README.md" "tags: \[api\]" "canonical single-tag form" || return 1
    "$CS_BIN" -tag add infra-migration >/dev/null 2>&1 || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/rt/.cs/README.md" "tags: \[api, infra-migration\]" "append preserves order" || return 1
    local output
    output=$("$CS_BIN" -tag list rt 2>&1) || true
    assert_output_contains "$output" "api" "list shows first tag" || return 1
    assert_output_contains "$output" "infra-migration" "list shows second tag" || return 1
    "$CS_BIN" -tag rm api >/dev/null 2>&1 || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/rt/.cs/README.md" "tags: \[infra-migration\]" "rm removes only the named tag" || return 1
    # Repeated writes must REPLACE the tags line, never insert a second one.
    # Pins the replace branch of _tags_write: if _tags_read_line_exists breaks
    # (e.g. the awk END-clobbers-exit trap), every write inserts and the grep
    # asserts above still pass on the corrupted file — this count does not.
    assert_eq "1" "$(grep -c '^tags:' "$CS_SESSIONS_ROOT/rt/.cs/README.md")" \
        "exactly one tags line after repeated writes" || return 1
}

test_tag_add_inserts_line_and_preserves_rest_byte_for_byte() {
    local dir
    dir=$(_session_with_readme "ins" "")
    local before after
    before=$(cat "$dir/.cs/README.md")
    _in_session "ins"
    "$CS_BIN" -tag add api >/dev/null 2>&1 || return 1
    after=$(cat "$dir/.cs/README.md")
    # Removing exactly the inserted line must reproduce the original file.
    assert_eq "$before" "$(printf '%s\n' "$after" | grep -v '^tags: \[api\]$')" \
        "every non-tags line preserved byte-for-byte" || return 1
    # Inserted after status: (spec: after status when present)
    printf '%s\n' "$after" | grep -A1 '^status:' | grep -q '^tags: \[api\]$' || {
        echo "  FAIL: tags line should insert directly after status:"
        return 1
    }
}

test_tag_validation() {
    _session_with_readme "val" "tags: []" >/dev/null
    _in_session "val"
    "$CS_BIN" -tag add API >/dev/null 2>&1 || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/val/.cs/README.md" "tags: \[api\]" "uppercase lowercased on write" || return 1
    local output
    if output=$("$CS_BIN" -tag add "bad/tag" 2>&1); then
        echo "  FAIL: bad/tag should be rejected"
        return 1
    fi
    assert_output_contains "$output" "a-z0-9._-" "rejection names the allowed charset" || return 1
    "$CS_BIN" -tag add api >/dev/null 2>&1 || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/val/.cs/README.md" "tags: \[api\]" "duplicate add is a no-op" || return 1
}

test_tag_refuses_block_style_lists() {
    local dir="$CS_SESSIONS_ROOT/blocky"
    mkdir -p "$dir/.cs/local"
    printf -- '---\nstatus: active\ntags:\n  - api\n---\n' > "$dir/.cs/README.md"
    local before output
    before=$(cat "$dir/.cs/README.md")
    _in_session "blocky"
    if output=$("$CS_BIN" -tag add infra 2>&1); then
        echo "  FAIL: block-style list must be refused"
        return 1
    fi
    assert_output_contains "$output" "README.md" "refusal names the file" || return 1
    assert_eq "$before" "$(cat "$dir/.cs/README.md")" "refused file left untouched" || return 1
}

test_tag_add_outside_session_errors() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    local output
    if output=$("$CS_BIN" -tag add api 2>&1); then
        echo "  FAIL: bare add outside a session should error"
        return 1
    fi
    assert_output_contains "$output" "In-session only" "error explains the site-B form" || return 1
}

test_tag_site_b_targets_named_session() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    _session_with_readme "siteb" "tags: []" >/dev/null
    "$CS_BIN" siteb -tag add api >/dev/null 2>&1 || { echo "  FAIL: site-B add exited non-zero"; return 1; }
    assert_file_contains "$CS_SESSIONS_ROOT/siteb/.cs/README.md" "tags: \[api\]" "site-B form tags the named session" || return 1
}

test_tag_list_bare_counts_across_sessions() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    _session_with_readme "c1" "tags: [api, infra]" >/dev/null
    _session_with_readme "c2" "tags: [api]" >/dev/null
    local output
    output=$("$CS_BIN" -tag list 2>&1) || true
    assert_output_contains "$output" "api (2)" "api counted across both sessions" || return 1
    assert_output_contains "$output" "infra (1)" "infra counted once" || return 1
}

test_list_filters_by_tag() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    _session_with_readme "tagged" "tags: [api]" >/dev/null
    _session_with_readme "untagged" "tags: []" >/dev/null
    local output
    output=$("$CS_BIN" -list --tag api 2>&1) || true
    assert_output_contains "$output" "tagged" "tagged session listed" || return 1
    assert_output_not_contains "$output" "untagged" "untagged session filtered out" || return 1
    if output=$("$CS_BIN" -list --tag 2>&1); then
        echo "  FAIL: --tag without a value should error"
        return 1
    fi
}

test_list_tag_filter_matches_dots_literally() {
    # --tag reaches grep as a BRE pattern; an unescaped "." matches any char,
    # so "v1.2" would wrongly also match a tag literally spelled "v1x2".
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    _session_with_readme "sess-real-dot" "tags: [v1.2]" >/dev/null
    _session_with_readme "sess-fake-dot" "tags: [v1x2]" >/dev/null
    local output
    output=$("$CS_BIN" -list --tag v1.2 2>&1) || true
    assert_output_contains "$output" "sess-real-dot" "exact dotted-tag session listed" || return 1
    assert_output_not_contains "$output" "sess-fake-dot" "dot must match literally, not as a wildcard" || return 1
}

run_test test_tag_subcommand_exists
run_test test_tag_add_and_list_roundtrip
run_test test_tag_add_inserts_line_and_preserves_rest_byte_for_byte
run_test test_tag_validation
run_test test_tag_refuses_block_style_lists
run_test test_tag_add_outside_session_errors
run_test test_tag_site_b_targets_named_session
run_test test_tag_list_bare_counts_across_sessions
run_test test_list_filters_by_tag
run_test test_list_tag_filter_matches_dots_literally
report_results
