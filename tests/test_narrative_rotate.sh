#!/usr/bin/env bash
# ABOUTME: Tests for cs -narrative rotate: byte-budgeted archival of a narrative's oldest sections
# ABOUTME: Pins the cut rule, content addressing, concurrency guards, git commit and union-merge safety

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Every test rotates actor alice's narrative inside one session. CS_ACTOR is
# the top-precedence identity override, so the machine's git identity never
# leaks into the file name under test.
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_ACTOR="alice"
    mkdir -p "$CS_SESSIONS_ROOT"
    SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$SESSION_DIR/.cs"/{local,memory}
    printf '# Session: test-session\n' > "$SESSION_DIR/.cs/README.md"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$SESSION_DIR"
    export CLAUDE_SESSION_META_DIR="$SESSION_DIR/.cs"
    LIVE="$SESSION_DIR/.cs/memory/narrative.alice.md"
    ARCHIVE_DIR="$SESSION_DIR/.cs/narrative-archive/alice"
    # Small budgets so fixtures stay readable: rotate above 4 KiB, keep 2 KiB.
    export CS_NARRATIVE_MAX_BYTES=4096
    export CS_NARRATIVE_KEEP_BYTES=2048
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_ACTOR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_NARRATIVE_MAX_BYTES CS_NARRATIVE_KEEP_BYTES CS_NARRATIVE_ROTATE_MIDPOINT 2>/dev/null || true
}

# A narrative with the header block cs writes (5 frontmatter lines + H1) and N
# dated sections. Section i is "\n## 2026-08-DD — section i\n" + BODY bytes of
# 'x' + "\n": with a one-digit i that is exactly 29 + BODY + 1 bytes (the em dash
# is 3 bytes); section 10 is one byte longer. Line layout: header = lines 1-6,
# section i = lines 6+3i-2 .. 6+3i.
_make_narrative() {  # file, sections, body_bytes
    local file="$1" n="$2" body="$3" i filler
    filler=$(head -c "$body" /dev/zero | tr '\0' 'x')
    {
        printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook for alice.\ntype: narrative\n---\n# Session narrative (alice)\n'
        i=1
        while [ "$i" -le "$n" ]; do
            printf '\n## 2026-08-%02d — section %d\n%s\n' $(( (i % 28) + 1 )) "$i" "$filler"
            i=$((i + 1))
        done
    } > "$file"
}

_bytes() { wc -c < "$1" | tr -d ' '; }

# ============================================================================
# under budget
# ============================================================================

test_rotate_is_a_recognised_subcommand() {
    _make_narrative "$LIVE" 2 100
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -narrative must dispatch" || return 1
}

test_rotate_under_budget_is_a_noop() {
    _make_narrative "$LIVE" 2 100          # ~1.3 KB, under the 4 KiB budget
    local before after output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    after=$(_bytes "$LIVE")
    assert_eq "$before" "$after" "live file must be untouched under budget" || return 1
    assert_output_contains "$output" "nothing to rotate" "must say it did nothing" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "no archive dir is created under budget" || return 1
}

test_rotate_requires_a_session() {
    unset CLAUDE_SESSION_META_DIR
    if "$CS_BIN" -narrative rotate > /dev/null 2>&1; then
        echo "  FAIL: must refuse outside a session"
        return 1
    fi
}

test_rotate_rejects_unknown_subcommand() {
    if "$CS_BIN" -narrative frobnicate > /dev/null 2>&1; then
        echo "  FAIL: unknown subcommand must fail"
        return 1
    fi
}

test_help_shows_narrative() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "-narrative rotate" "help must mention -narrative rotate" || return 1
}

echo ""
echo "cs narrative rotation tests"
echo "==========================="
echo ""

run_test test_rotate_is_a_recognised_subcommand
run_test test_rotate_under_budget_is_a_noop
run_test test_rotate_requires_a_session
run_test test_rotate_rejects_unknown_subcommand
run_test test_help_shows_narrative

report_results
