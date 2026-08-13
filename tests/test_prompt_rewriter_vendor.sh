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

# The rewrite runs from a directory holding nothing, which is not a git repo, and
# codex refuses to start outside one — a guard meant for interactive sessions
# that is pure friction when the caller only ever reads stdout. The read-only
# sandbox is not friction: the prompt is untrusted text, and this is the only
# thing standing between an embedded instruction and codex's file tools.
test_openai_prefers_the_codex_cli() {
    fake_bin codex 'printf "REWRITTEN BY CODEX"'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=openai run_rewrite) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected success from the codex arm, got $rc"; return 1; }
    [ "$out" = "REWRITTEN BY CODEX" ] || { echo "expected the CLI output, got: $out"; return 1; }
    assert_file_contains "$ARGV_DUMP" 'skip-git-repo-check' \
        "codex refuses to run outside a git repo without it" || return 1
    assert_file_contains "$ARGV_DUMP" '\-s read-only' \
        "an untrusted prompt must not reach codex's file tools"
}

# Reasoning models are the wrong tool here and the endpoint choice follows from
# that: /v1/chat/completions only. A rewrite blocks the whole interface, and a
# model that spends its budget thinking either truncates or returns nothing —
# measured, not assumed. An o3/o4 model set through CS_REWRITE_MODEL 400s on
# this endpoint, which declines and leaves the typed prompt exactly as it was.
test_openai_falls_back_to_the_api_when_the_cli_is_absent() {
    fake_bin curl 'printf "%s" "{\"choices\":[{\"message\":{\"content\":\"REWRITTEN BY OPENAI\"},\"finish_reason\":\"stop\"}]}"'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=openai OPENAI_API_KEY=not-a-real-key run_rewrite) || rc=$?
    [ "$rc" -eq 0 ] || { echo "expected success from the API arm, got $rc"; return 1; }
    assert_file_contains "$ARGV_DUMP" 'curl' "the API arm ran curl" || return 1
    [ "$out" = "REWRITTEN BY OPENAI" ] || { echo "expected the extracted text, got: $out"; return 1; }
}

# The key travels in a mode-600 curl config file, never on the command line,
# where `ps` shows it to every user on the box and a URL query string would
# carry it into logs at the far end.
test_the_api_key_never_reaches_argv() {
    # Assembled rather than written out: push protection rejects a literal
    # credential shape even in a fixture, and taking the unblock URL to ship a
    # fake one trains the wrong reflex.
    local fake_key
    fake_key="AIza""SyNotARealGeminiKey"
    fake_bin curl 'printf "%s" "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}"'
    CS_REWRITE_PROVIDER=gemini GEMINI_API_KEY="$fake_key" run_rewrite >/dev/null
    assert_exists "$ARGV_DUMP" "curl ran, so there is an argv to inspect" || return 1
    assert_file_not_contains "$ARGV_DUMP" "$fake_key" \
        "the key must never appear on the command line"
}

# The prompt is untrusted text. On the API arm it rides a payload file, so a
# shell in any later link of the chain never sees it. The CLI arms are the
# documented exception: agy and codex both take the prompt as an argument and
# offer no stdin path, which is the council's position too.
test_the_prompt_never_reaches_argv_on_the_api_arm() {
    fake_bin curl 'printf "%s" "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}"'
    CS_REWRITE_PROVIDER=gemini GEMINI_API_KEY=not-a-real-key \
        run_rewrite 'rm -rf $HOME && echo pwned' >/dev/null
    assert_exists "$ARGV_DUMP" "curl ran, so there is an argv to inspect" || return 1
    assert_file_not_contains "$ARGV_DUMP" 'pwned' "no prompt text reaches argv"
}

# No CLI and no key is not an error to report, it is a decline. The shim keeps
# the typed prompt on any non-zero status, so the user sees their own words
# rather than a diagnostic they did not ask for.
test_a_provider_with_neither_a_cli_nor_a_key_declines() {
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemini run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected a decline with no CLI and no key, got $rc"; return 1; }
    [ -z "$out" ] || { echo "expected no output, got: $out"; return 1; }
    rc=0
    out=$(CS_REWRITE_PROVIDER=openai run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected a decline for openai too, got $rc"; return 1; }
}

# A typo in a shell profile must not silently pick a provider. Unset lands here
# too: this script is only ever reached when the shim resolved a vendor, so an
# empty value means the resolution went wrong rather than "use the default".
test_an_unknown_provider_declines() {
    fake_bin agy 'printf "SHOULD NOT RUN"'
    fake_bin codex 'printf "SHOULD NOT RUN"'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemeni run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected a decline for an unknown provider, got $rc"; return 1; }
    assert_not_exists "$ARGV_DUMP" "no vendor may run for a name we do not know" || return 1
    rc=0
    out=$(run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected a decline for an unset provider, got $rc"; return 1; }
}

# Measured, not hypothetical: generativelanguage.googleapis.com answered three
# consecutive requests with HTTP 404 and a zero-byte body, then served the
# identical request normally a minute later.
test_an_empty_api_response_declines() {
    fake_bin curl 'exit 0'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemini GEMINI_API_KEY=not-a-real-key run_rewrite) || rc=$?
    assert_exists "$ARGV_DUMP" "curl ran, so the decline came from the gate" || return 1
    [ "$rc" -ne 0 ] || { echo "expected a decline for an empty body, got $rc"; return 1; }
    [ -z "$out" ] || { echo "expected no output, got: $out"; return 1; }
}

# A truncated rewrite is worse than none: it is non-empty, so it passes every
# emptiness check, and it silently drops whatever the user typed past the cut.
# gemini-2.5-flash produces exactly this, spending 1963 tokens on reasoning
# against a 2048 cap and stopping mid-sentence.
test_a_truncated_api_answer_declines() {
    fake_bin curl 'printf "%s" "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"parts\":[{\"text\":\"Fix the statusline by\"}]}}]}"'
    local out rc=0
    out=$(CS_REWRITE_PROVIDER=gemini GEMINI_API_KEY=not-a-real-key run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected a decline for a truncated answer, got $rc"; return 1; }
    [ -z "$out" ] || { echo "a truncated rewrite was returned: $out"; return 1; }
}

# codex reads AGENTS.md from its working directory and agy takes that directory
# as its workspace, so a rewrite launched from the user's checkout inherits that
# project's instructions — the leak prompt-rewriter-model.sh closed for claude -p
# by running from a directory that holds nothing.
test_the_cli_runs_outside_the_project() {
    fake_bin agy 'printf "%s\n" "PWD=$PWD" >> "$CS_TEST_ARGV_DUMP"
printf "ok"'
    CS_REWRITE_PROVIDER=gemini run_rewrite >/dev/null
    assert_file_contains "$ARGV_DUMP" "PWD=$TEST_TMPDIR/cache/cs/rewrite-config" \
        "the CLI runs from the hermetic directory, not the caller's" || return 1
    assert_file_not_contains "$ARGV_DUMP" "PWD=$PWD" "never the project directory"
}

# The shim's cancel handler signals the rewriter's whole process group, so this
# script is killed mid-call as a matter of routine, not as an edge case. Cleaning
# up only on the way out of the normal path leaves the mode-600 config file
# behind — and that file holds the API key.
#
# BSD mktemp ignores TMPDIR (it resolves the per-user directory through confstr),
# so the temp files cannot be redirected into the test's own tree. The assertion
# diffs the real temp directory instead and inspects only what this run added.
test_a_killed_rewrite_leaves_no_credential_on_disk() {
    # Unique per run: the temp directory is shared machine-wide, so a concurrent
    # run of this same suite would otherwise leave a file carrying the identical
    # key and this run would read it as its own leak.
    local fake_key
    fake_key="AIza""SyNotAReal$$"
    fake_bin curl 'sleep 30'
    local tmproot before after leaked
    tmproot=$(dirname "$(mktemp -u)")
    before="$TEST_TMPDIR/before"
    ls -A "$tmproot" > "$before" 2>/dev/null

    # Job control for the fork alone, so the rewriter and its curl land in one
    # process group this test can address as a unit — exactly what the shim does
    # with `set -m` before forking. A `pkill -f` pattern would reach any other
    # process on the machine matching it, including a concurrent run of this very
    # suite, and the two would kill each other's processes.
    set -m
    ( printf 'fix the login thing' | CS_REWRITE_PROVIDER=gemini \
        GEMINI_API_KEY="$fake_key" "$VENDOR" >/dev/null 2>&1 ) &
    local pid=$! waited=0
    set +m
    while [ "$waited" -lt 50 ] && [ -z "$(pgrep -g "$pid" -f 'sleep 30' 2>/dev/null)" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -n "$(pgrep -g "$pid" -f 'sleep 30' 2>/dev/null)" ] || { echo "the API arm never reached curl"; return 1; }

    # The whole group, exactly as the shim's cancel handler does. Signalling the
    # script alone would leave it blocked in curl with the cleanup unreached,
    # since bash defers a trap until the foreground child returns — a state
    # production never produces.
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # Only files this run created are inspected; the shared temp directory holds
    # other processes' files and none of them are ours to read.
    after="$TEST_TMPDIR/after"
    ls -A "$tmproot" > "$after" 2>/dev/null
    leaked=0
    while IFS= read -r f; do
        [ -f "$tmproot/$f" ] || continue
        if grep -ql "$fake_key" "$tmproot/$f" 2>/dev/null; then
            echo "a killed rewrite left the API key in $tmproot/$f"
            rm -f "$tmproot/$f"
            leaked=1
        fi
    done < <(comm -13 "$before" "$after" 2>/dev/null)
    [ "$leaked" -eq 0 ]
}

echo ""
echo "Prompt rewriter vendor tests"
echo "============================"
echo ""

run_test test_a_zero_exit_error_from_the_cli_is_not_returned_as_a_rewrite
run_test test_gemini_falls_back_to_the_api_when_the_cli_is_absent
run_test test_openai_prefers_the_codex_cli
run_test test_openai_falls_back_to_the_api_when_the_cli_is_absent
run_test test_the_api_key_never_reaches_argv
run_test test_the_prompt_never_reaches_argv_on_the_api_arm
run_test test_a_provider_with_neither_a_cli_nor_a_key_declines
run_test test_an_unknown_provider_declines
run_test test_an_empty_api_response_declines
run_test test_a_truncated_api_answer_declines
run_test test_the_cli_runs_outside_the_project
run_test test_a_killed_rewrite_leaves_no_credential_on_disk

report_results
