#!/usr/bin/env bash
# ABOUTME: Tests for the clarify guideline folded into the scope-prompt UserPromptSubmit hook
# ABOUTME: Validates always-on injection, the prefix and env opt-outs, and single-emission composition

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/scope-prompt.sh"

# --- Hook-specific setup / teardown (overrides test_lib's) ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # Drop ambient cs/Claude env FIRST, so running these tests from inside a live
    # cs session can't leak a value the hook reads.
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    export CLAUDE_SESSION_NAME="test-clarify"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    # git init and the identity live in setup, matching tests/test_scope_prompt.sh.
    # The identity is not optional: a bare CI runner auto-detects an empty ident
    # name and every commit here fails.
    git -C "$CLAUDE_SESSION_DIR" init -q
    git -C "$CLAUDE_SESSION_DIR" config user.email "test@cs.local"
    git -C "$CLAUDE_SESSION_DIR" config user.name "cs test"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Track the named files, so scope grounding has something to match.
seed_repo() {
    local f
    for f in "$@"; do
        mkdir -p "$CLAUDE_SESSION_DIR/$(dirname "$f")"
        printf 'placeholder content for %s\n' "$f" > "$CLAUDE_SESSION_DIR/$f"
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "seed" >/dev/null 2>&1
}

# Feed a prompt to the hook as the harness would (JSON on stdin).
run_hook() {
    # Herestring, not a live `jq | hook` pipe: the hook can exit before draining
    # stdin, which would leave jq writing into a closed fd (SIGPIPE) and
    # `set -o pipefail` would surface that as a non-zero exit.
    # The prompt goes in on jq's STDIN, never as an argv value: a leading-slash
    # argument can be rewritten before jq sees it.
    local prompt="$1" _in
    _in=$(printf '%s' "$prompt" | jq -Rs '{prompt: ., hook_event_name: "UserPromptSubmit"}')
    "$HOOK" <<< "$_in"
}

# The additionalContext string the hook emitted (empty if it emitted nothing).
emitted_context() {
    jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# --- Tests ---

test_guideline_injected_on_scope_firing_prompt() {
    seed_repo "src/api.ts"
    local ctx
    ctx=$(run_hook "implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a code-work prompt carries the clarify guideline" || return 1
    assert_output_contains "$ctx" "Scope (auto-grounded)" \
        "the scope block is still emitted alongside it"
}

test_guideline_injected_on_vague_prompt() {
    seed_repo "src/api.ts"
    # "make" is deliberately absent from the hook's work-verb regex, so this
    # prompt exits through the digest path and never reaches the scope emit.
    # It is also the canonical vague prompt this feature exists for.
    local ctx
    ctx=$(run_hook "make it better" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a vague prompt still carries the guideline" || return 1
    assert_output_not_contains "$ctx" "Scope (auto-grounded)" \
        "and does not drag in the scope block"
}

test_short_prompt_is_not_filtered() {
    seed_repo "src/api.ts"
    # Objective capture skips prompts under 8 chars; clarify must not, or it
    # misses exactly the prompts it exists for.
    local ctx
    ctx=$(run_hook "fix it" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a six-character prompt still carries the guideline"
}

run_test test_guideline_injected_on_scope_firing_prompt
run_test test_guideline_injected_on_vague_prompt
run_test test_short_prompt_is_not_filtered

report_results
