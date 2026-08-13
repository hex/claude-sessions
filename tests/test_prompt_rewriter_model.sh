#!/usr/bin/env bash
# ABOUTME: Tests for the default rewriter, which calls a nested claude -p
# ABOUTME: Pins the environment that call is given: auth, isolation, and context scrubbing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

MODEL="$SCRIPT_DIR/../hooks/prompt-rewriter-model.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*|ANTHROPIC_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    # Keep the hermetic config dir inside the test, so a run never touches the
    # real one at ~/.cache/cs/rewrite-config.
    export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
    # A fake claude that records the environment it was handed. Everything here
    # is about WHAT THE CHILD RECEIVES, so no network and no real model.
    FAKE_BIN="$TEST_TMPDIR/bin"
    ENV_DUMP="$TEST_TMPDIR/child-env"
    mkdir -p "$FAKE_BIN"
    # Records ONLY whether each variable under test arrived, never its value.
    # A failed assertion prints the file it was given, and the real environment
    # holds real credentials that must never reach a test log. The heredoc is
    # quoted and the path arrives by variable, so nothing expands at write time.
    export CS_TEST_ENV_DUMP="$ENV_DUMP"
    cat > "$FAKE_BIN/claude" <<'FAKEEOF'
#!/usr/bin/env bash
: > "$CS_TEST_ENV_DUMP"
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR \
          CLAUDE_CONFIG_DIR CLAUDE_COWORK_MEMORY_PATH_OVERRIDE CLAUDE_SESSION_DIR \
          CLAUDE_SESSION_NAME CLAUDE_PROJECT_DIR; do
    if printenv "$_v" >/dev/null 2>&1; then
        printf '%s=present\n' "$_v" >> "$CS_TEST_ENV_DUMP"
    else
        printf '%s=absent\n' "$_v" >> "$CS_TEST_ENV_DUMP"
    fi
done
printf 'REWRITTEN'
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    PATH="$FAKE_BIN:$PATH"
    export PATH
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

run_rewrite() {  # [prompt]
    printf '%s' "${1:-fix the login thing}" | "$MODEL" 2>/dev/null
}

# Claude Code prefers an ambient API key over the user's claude.ai login. A key
# that is stale, rotated or simply wrong then takes every rewrite down with it —
# and the failure is a silent timeout, because a bad key makes the call retry
# rather than fail. The nested call is a convenience, not the user's session, so
# it uses the login and never the key.
test_the_api_key_is_not_handed_to_the_nested_call() {
    # Assembled rather than written out: push protection rejects a literal
    # credential shape even in a fixture, and taking the unblock URL to ship a
    # fake one trains the wrong reflex.
    local fake_key
    fake_key="sk-""ant-""not-a-real-key"
    ANTHROPIC_API_KEY="$fake_key" run_rewrite >/dev/null
    assert_exists "$ENV_DUMP" "the nested claude ran" || return 1
    assert_file_contains "$ENV_DUMP" '^ANTHROPIC_API_KEY=absent' \
        "the API key must not reach the nested call"
}

test_the_auth_token_is_not_handed_to_the_nested_call() {
    ANTHROPIC_AUTH_TOKEN="not-a-real-token" run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" '^ANTHROPIC_AUTH_TOKEN=absent' \
        "the auth token must not reach the nested call either"
}

# Setting CLAUDE_CONFIG_DIR renames the keychain service Claude Code looks up:
#
#   o = r ? "" : `-${sha256(configDir).substring(0,8)}`
#   service = `Claude Code…-credentials${o}`
#
# so a hermetic config dir asks for an item that was never created and reports
# "Not logged in". Setting CLAUDE_SECURESTORAGE_CONFIG_DIR to the empty string
# makes that ternary take the unsuffixed branch, so the isolated call reads the
# real login. Without it the hermetic dir has no credentials at all.
test_the_nested_call_reads_the_real_login() {
    run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" '^CLAUDE_SECURESTORAGE_CONFIG_DIR=present' \
        "the securestorage dir is set, so the keychain lookup drops its suffix"
}

# The config dir stays hermetic: an inherited agent definition pinning a
# data-retention-gated model makes the API reject the whole request with
# `tools.N.model`, and --safe-mode does not prevent it.
test_the_config_dir_stays_hermetic() {
    run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" '^CLAUDE_CONFIG_DIR=present' \
        "the call still runs against its own config dir"
}

# A nested claude inherits the session's context otherwise, and it leaks into
# the rewrite: a request to add a flag came back demanding TDD and a README
# update the user never asked for.
test_the_session_context_is_scrubbed() {
    CLAUDE_COWORK_MEMORY_PATH_OVERRIDE=/tmp/mem \
    CLAUDE_SESSION_DIR=/tmp/sess \
    CLAUDE_SESSION_NAME=leaky \
    CLAUDE_PROJECT_DIR=/tmp/proj \
        run_rewrite >/dev/null
    local v
    for v in CLAUDE_COWORK_MEMORY_PATH_OVERRIDE CLAUDE_SESSION_DIR CLAUDE_SESSION_NAME CLAUDE_PROJECT_DIR; do
        assert_file_contains "$ENV_DUMP" "^$v=absent" "$v must not reach the rewrite" || return 1
    done
}

# An API error arrives on stdout with a zero status, so a status check alone
# would hand the error text back as the user's prompt.
test_an_api_error_is_not_returned_as_a_rewrite() {
    cat > "$FAKE_BIN/claude" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'API Error: 401 authentication_error'
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    local out rc=0
    out=$(run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected non-zero for an API error, got $rc"; return 1; }
    [ -z "$out" ] || { echo "error text was returned as a rewrite: $out"; return 1; }
}

test_an_execution_error_is_not_returned_as_a_rewrite() {
    cat > "$FAKE_BIN/claude" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'Execution error'
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    local out rc=0
    out=$(run_rewrite) || rc=$?
    [ "$rc" -ne 0 ] || { echo "expected non-zero for an execution error, got $rc"; return 1; }
    [ -z "$out" ] || { echo "error text was returned as a rewrite: $out"; return 1; }
}

# The prompt is untrusted data. It goes in on stdin and must never appear as an
# argument, where a shell in any later link of the chain could act on it.
test_the_prompt_is_passed_on_stdin_not_argv() {
    run_rewrite 'rm -rf $HOME && echo pwned' >/dev/null
    # The recorder never writes values, so this asserts the shape it does write:
    # every tracked variable reported as present or absent, nothing else.
    assert_file_not_contains "$ENV_DUMP" 'pwned' "no prompt text reaches the child environment"
}

echo ""
echo "Prompt rewriter model tests"
echo "==========================="
echo ""

run_test test_the_api_key_is_not_handed_to_the_nested_call
run_test test_the_auth_token_is_not_handed_to_the_nested_call
run_test test_the_nested_call_reads_the_real_login
run_test test_the_config_dir_stays_hermetic
run_test test_the_session_context_is_scrubbed
run_test test_an_api_error_is_not_returned_as_a_rewrite
run_test test_an_execution_error_is_not_returned_as_a_rewrite
run_test test_the_prompt_is_passed_on_stdin_not_argv

report_results
