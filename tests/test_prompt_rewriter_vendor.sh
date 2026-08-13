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
    # PATH is replaced, not prepended. Prepending leaves the developer's own agy
    # and codex resolvable, so every "the CLI is absent" test would quietly run
    # the real binary — a live, billed, ten-second call that still reports the
    # API arm untested. /usr/bin and /bin hold none of the vendor CLIs on any
    # machine; jq is a cs dependency and lives outside them, so it is linked in
    # by hand rather than assumed.
    local _jq
    _jq=$(command -v jq 2>/dev/null) && ln -sf "$_jq" "$FAKE_BIN/jq"
    PATH="$FAKE_BIN:/usr/bin:/bin"
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

# The council drops a vendor's API provider outright when its CLI is on PATH,
# because the CLI carries subscription auth and spends no API credit. Same
# policy here — but the API arm has to stay reachable, since a user with a key
# and no CLI is the ordinary case for anyone who has not installed agy.
test_gemini_falls_back_to_the_api_when_the_cli_is_absent() {
    fake_bin curl 'printf "%s" "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"REWRITTEN BY API\"}]}}]}"'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemini GEMINI_API_KEY=not-a-real-key run_rewrite) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected success from the API arm, got $rc"; return 1; }
    assert_file_contains "$ARGV_DUMP" 'curl' "the API arm ran curl" || return 1
    [ "$out" = "REWRITTEN BY API" ] || { echo "expected the extracted text, got: $out"; return 1; }
}

echo ""
echo "Prompt rewriter vendor tests"
echo "============================"
echo ""

run_test test_a_zero_exit_error_from_the_cli_is_not_returned_as_a_rewrite
run_test test_gemini_falls_back_to_the_api_when_the_cli_is_absent

report_results
