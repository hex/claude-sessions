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
# The securestorage value is a config directory path, never a credential, and
# the mirroring assertion needs it rather than a present/absent flag.
printf 'SECURESTORAGE_VALUE=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR-<unset>}" >> "$CS_TEST_ENV_DUMP"
printf 'ARGV=%s\n' "$*" >> "$CS_TEST_ENV_DUMP"
printf 'CWD=%s\n' "$PWD" >> "$CS_TEST_ENV_DUMP"
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

# Claude Code walks up from the CWD collecting CLAUDE.md as PROJECT memory, and
# the hermetic config dir lives under $HOME — so the walk reached
# $HOME/.claude/CLAUDE.md and injected the user's private global instructions,
# labelled as project instructions that OVERRIDE default behavior. Those
# instructions tell an agent to stop and ask the user for clarification, which
# is the exact opposite of this rewriter's contract, and on question-shaped
# inputs the model obeyed them and answered the user instead of rewriting. The
# config dir may stay where it is; the working directory is the vector.
test_the_nested_call_runs_outside_home() {
    # The default fixture points XDG_CACHE_HOME at a temp dir, so the hermetic
    # dir already sits outside $HOME and the assertion would pass without
    # exercising anything. Reproduce the shipped layout instead: no
    # XDG_CACHE_HOME, so cfg resolves to $HOME/.cache/cs/rewrite-config.
    # The fake HOME must not sit under the directory the call runs from, or the
    # prefix test compares the wrong way round and reports a pass. TEST_TMPDIR
    # is inside TMPDIR, which is exactly where the run dir resolves, so this
    # home goes somewhere neither contains nor is contained by it.
    local fake_home
    fake_home=$(cd "$TEST_TMPDIR" && pwd -P)/../home-$$
    mkdir -p "$fake_home"
    fake_home=$(cd "$fake_home" && pwd -P)
    # setup() exports XDG_CACHE_HOME, which wins over $HOME/.cache and would
    # keep cfg out of the fake home entirely. Drop it so cfg resolves the way
    # it does on a real machine.
    ( unset XDG_CACHE_HOME; HOME="$fake_home" run_rewrite >/dev/null )
    local cfg_under_home="$fake_home/.cache/cs/rewrite-config"
    [ -d "$cfg_under_home" ] \
        || { echo "  FAIL: fixture did not put the hermetic dir under HOME ($cfg_under_home)"; return 1; }
    local rc=0
    _assert_cwd_outside "$fake_home" || rc=1
    rm -rf "$fake_home"
    return "$rc"
}

_assert_cwd_outside() {  # home_dir
    assert_exists "$ENV_DUMP" "the nested claude ran" || return 1
    local cwd
    cwd=$(awk -F= '/^CWD=/ { sub(/^CWD=/, ""); print; exit }' "$ENV_DUMP")
    [ -n "$cwd" ] || { echo "  FAIL: the child recorded no working directory"; return 1; }
    case "$cwd/" in
        "$1"/*) echo "  FAIL: the child ran under HOME ($cwd), where the CLAUDE.md walk reaches it"; return 1 ;;
    esac
}

# The rewriter transforms text and needs no tools. Left armed, the tool
# definitions and their skills/agents reminders push the model back toward
# acting like a coding agent — it narrated a blocked Read attempt and asked
# whether to go ahead, instead of returning a rewritten request.
test_the_nested_call_arms_no_tools() {
    run_rewrite >/dev/null
    assert_exists "$ENV_DUMP" "the nested claude ran" || return 1
    assert_file_contains "$ENV_DUMP" '^ARGV=.*--tools' \
        "the nested call must pass --tools" || return 1
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

# ANTHROPIC_AUTH_TOKEN is deliberately NOT scrubbed, and the asymmetry is the
# whole reason. An ambient API key wins unconditionally in print mode
# (`if(pfr()&&t)return{key:t,source:"ANTHROPIC_API_KEY"}`) while interactive
# mode requires it to be in `customApiKeyResponses.approved` — so a dead key
# kills every nested rewrite while the parent session stays healthy, silently.
# The auth token has no such asymmetry: it is checked identically in both
# modes, so a dead one breaks the parent's own messages and the user already
# knows. Scrubbing it would also strand proxy users, whose ANTHROPIC_BASE_URL
# and ANTHROPIC_CUSTOM_HEADERS stay in place — the rewrite would send a
# keychain OAuth bearer at their gateway. Scrub exactly the credentials whose
# precedence differs between parent and child.
test_the_auth_token_is_left_alone() {
    ANTHROPIC_AUTH_TOKEN="not-a-real-token" run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" '^ANTHROPIC_AUTH_TOKEN=present' \
        "the auth token is not ours to strip"
}

# A parent running its own CLAUDE_CONFIG_DIR keeps its login under
# `Claude Code-credentials-<sha256(thatDir)[0:8]>`. Hardcoding the empty string
# would point the child at the unsuffixed default item, which that user never
# wrote — not logged in, or worse, a stale different login. Mirror whatever the
# parent resolved.
test_the_securestorage_dir_mirrors_the_parent() {
    local sentinel="$TEST_TMPDIR/parent-config"
    mkdir -p "$sentinel"
    CLAUDE_CONFIG_DIR="$sentinel" run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" "^SECURESTORAGE_VALUE=$sentinel\$" \
        "the child mirrors the parent's config dir, not the hermetic one"
}

# With no parent CLAUDE_CONFIG_DIR the mirror resolves to empty, which is the
# value that makes the keychain lookup drop its suffix.
test_the_securestorage_dir_is_empty_by_default() {
    run_rewrite >/dev/null
    assert_file_contains "$ENV_DUMP" '^SECURESTORAGE_VALUE=$' \
        "no parent config dir means the default, unsuffixed keychain item"
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

# A user whose only credential is a Console API key has no login for the scrub
# to fall back to, so the first attempt fails in about a second. Rather than
# leave the feature dead for them, retry once with the key in place.
test_a_key_only_user_gets_a_retry_with_the_key() {
    cat > "$FAKE_BIN/claude" <<'FAKEEOF'
#!/usr/bin/env bash
# Stands in for a machine with no claude.ai login: works only with the key.
if printenv ANTHROPIC_API_KEY >/dev/null 2>&1; then
    printf 'REWRITTEN VIA KEY'
else
    printf 'Not logged in · Please run /login'
    exit 1
fi
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    local out fake_key
    fake_key="sk-""ant-""still-not-real"
    out=$(ANTHROPIC_API_KEY="$fake_key" run_rewrite)
    assert_eq "REWRITTEN VIA KEY" "$out" "the retry runs with the key present"
}

# With no key there is nothing to retry with, so the failure must stay a single
# attempt rather than looping or re-running the same doomed call.
test_no_key_means_no_retry() {
    local counter="$TEST_TMPDIR/attempts"
    : > "$counter"
    cat > "$FAKE_BIN/claude" <<FAKEEOF
#!/usr/bin/env bash
echo x >> "$counter"
printf 'Not logged in'
exit 1
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    run_rewrite >/dev/null 2>&1
    local n; n=$(grep -c . "$counter" 2>/dev/null || echo 0)
    [ "$n" -eq 1 ] || { echo "expected 1 attempt with no key, got $n"; return 1; }
}

# The retry is for a fast failure only. A first attempt that hung has already
# spent the timeout, and running a second would double the freeze the whole
# feature exists to bound.
test_a_slow_failure_is_not_retried() {
    local counter="$TEST_TMPDIR/attempts"
    : > "$counter"
    cat > "$FAKE_BIN/claude" <<FAKEEOF
#!/usr/bin/env bash
echo x >> "$counter"
sleep 6
printf 'Execution error'
exit 1
FAKEEOF
    chmod +x "$FAKE_BIN/claude"
    local fake_key; fake_key="sk-""ant-""still-not-real"
    ANTHROPIC_API_KEY="$fake_key" run_rewrite >/dev/null 2>&1
    local n; n=$(grep -c . "$counter" 2>/dev/null || echo 0)
    [ "$n" -eq 1 ] || { echo "a slow failure must not be retried, got $n attempts"; return 1; }
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

# Stock macOS ships neither timeout(1) nor gtimeout, which is the case the
# best-effort bound exists for — and the case where the whole rewrite used to
# die before reaching the model. bash 3.2 treats a plain `"${a[@]}"` on an EMPTY
# array as an unbound variable under `set -u`, so the empty _tmo aborted the
# script. Every other test here passes on a developer box because Homebrew's
# coreutils puts timeout on PATH; only hiding it reproduces the user's machine.
test_the_rewrite_works_without_timeout_on_path() {
    local shim="$FAKE_BIN/timeout"
    # A PATH holding the fake claude and the system utilities, but no timeout
    # and no gtimeout, whatever the developer has installed.
    local out
    out=$(printf 'fix the login thing' | PATH="$FAKE_BIN:/usr/bin:/bin" "$MODEL" 2>/dev/null)
    [ "$out" = "REWRITTEN" ] || { echo "expected the rewrite, got: '$out'"; return 1; }
    assert_exists "$ENV_DUMP" "the nested claude ran without timeout(1)"
}

echo ""
echo "Prompt rewriter model tests"
echo "==========================="
echo ""

run_test test_the_nested_call_runs_outside_home
run_test test_the_nested_call_arms_no_tools
run_test test_the_api_key_is_not_handed_to_the_nested_call
run_test test_the_auth_token_is_left_alone
run_test test_the_securestorage_dir_mirrors_the_parent
run_test test_the_securestorage_dir_is_empty_by_default
run_test test_the_nested_call_reads_the_real_login
run_test test_the_config_dir_stays_hermetic
run_test test_the_session_context_is_scrubbed
run_test test_a_key_only_user_gets_a_retry_with_the_key
run_test test_no_key_means_no_retry
run_test test_a_slow_failure_is_not_retried
run_test test_an_api_error_is_not_returned_as_a_rewrite
run_test test_an_execution_error_is_not_returned_as_a_rewrite
run_test test_the_prompt_is_passed_on_stdin_not_argv
run_test test_the_rewrite_works_without_timeout_on_path

report_results
