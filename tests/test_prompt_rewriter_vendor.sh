#!/usr/bin/env bash
# ABOUTME: Tests for the OpenAI and Gemini rewriter, which prefers a vendor CLI over the API
# ABOUTME: Pins provider resolution, the decline gate, and that no credential reaches argv

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

VENDOR="$SCRIPT_DIR/../hooks/prompt-rewriter-vendor.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|ANTHROPIC_*|OPENAI_*|GEMINI_*|GOOGLE_*) unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    # Keep the hermetic run dir inside the test, so a run never touches the real
    # one at ~/.cache/cs/rewrite-config.
    export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
    FAKE_BIN="$TEST_TMPDIR/bin"
    ARGV_DUMP="$TEST_TMPDIR/argv"
    mkdir -p "$FAKE_BIN"
    export CS_TEST_ARGV_DUMP="$ARGV_DUMP"
    PATH="$FAKE_BIN:$PATH"
    export PATH
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Writes a fake vendor binary that records the argv it was handed, then behaves
# as the test dictates. The recorder is the seam every resolution test reads.
fake_bin() {  # name, body
    cat > "$FAKE_BIN/$1" <<FAKEEOF
#!/usr/bin/env bash
printf '%s\n' "\$0 \$*" >> "\$CS_TEST_ARGV_DUMP"
$2
FAKEEOF
    chmod +x "$FAKE_BIN/$1"
}

run_rewrite() {  # [prompt]
    printf '%s' "${1:-fix the login thing}" | "$VENDOR" 2>/dev/null
}

# agy reports its own failures on STDOUT and still exits 0 — a positional prompt
# instead of -p launches its interactive TUI, which dies with
# "CLI error: bubbletea: error opening TTY" and a zero status. The rewriter
# contract is "non-zero to decline", so a status check alone hands that string
# back as the user's next message. Judge the output, never the status alone.
test_a_zero_exit_error_from_the_cli_is_not_returned_as_a_rewrite() {
    fake_bin agy 'printf "CLI error: bubbletea: error opening TTY: could not open /dev/tty"
exit 0'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemini run_rewrite) || rc=$?
    # Proves the decline came from the gate rather than from the script being
    # absent: a missing rewriter also exits non-zero with no output, and would
    # satisfy both assertions below without ever running anything.
    assert_exists "$ARGV_DUMP" "the vendor CLI was invoked" || return 1
    [ "$rc" -ne 0 ] || { echo "expected non-zero for a CLI error, got $rc"; return 1; }
    [ -z "$out" ] || { echo "error text was returned as a rewrite: $out"; return 1; }
}

echo ""
echo "Prompt rewriter vendor tests"
echo "============================"
echo ""

run_test test_a_zero_exit_error_from_the_cli_is_not_returned_as_a_rewrite

report_results
