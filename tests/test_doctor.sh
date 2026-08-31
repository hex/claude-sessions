#!/usr/bin/env bash
# ABOUTME: Tests for cs -doctor health check subcommand
# ABOUTME: Validates check execution, status reporting, and exit codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    # Isolate the doctor's ~/.claude probes from the developer's real install
    # (tests that need specific settings/hooks seed this dir themselves).
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_SESSIONS_ROOT" "$CS_CLAUDE_DIR"

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/README.md" << 'EOF'
---
status: active
created: 2026-04-21
tags: []
aliases: ["test-session"]
---
# Session: test-session

## Objective
Test doctor
EOF
    echo "# Test" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m init)

    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$session_dir"
    export CLAUDE_SESSION_META_DIR="$session_dir/.cs"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_CLAUDE_DIR 2>/dev/null || true
}

test_doctor_subcommand_exists() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -doctor should be a recognized subcommand" || return 1
}

test_doctor_runs_default_checks_from_session() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Keychain" "should report Keychain check" || return 1
    assert_output_contains "$output" "Hooks" "should report hooks check" || return 1
}

test_doctor_reports_pass_for_healthy_session() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "OK" "healthy session should show OK status" || return 1
}

test_doctor_warns_on_a_narrative_over_budget() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    local output
    output=$(CS_NARRATIVE_MAX_BYTES=2048 "$CS_BIN" -doctor 2>&1) || true
    # Colour escapes may sit between the [WARN] tag and the message, so the two
    # are pinned separately.
    assert_output_contains "$output" "Narrative: narrative.alice.md is 2 KB (budget 2 KB)" "warns with file and budget" || return 1
    assert_output_contains "$output" "run cs -narrative rotate" "points at the rotation" || return 1
    # This fixture never trips a FAIL check, so the summary takes the WARN
    # branch ("Complete with N warning(s).") rather than the FAIL branch's
    # "Warnings: N" — assert against the branch this scenario actually hits.
    assert_output_contains "$output" "Complete with [1-9][0-9]* warning(s)\." "the warning is counted" || return 1
}

test_doctor_reports_ok_when_narratives_fit() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Narrative: all within the 128 KB budget" "ok line names the budget" || return 1
    assert_output_not_contains "$output" "run cs -narrative rotate" "no warning" || return 1
}

test_doctor_survives_an_unreadable_narrative() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    chmod 000 "$nf"
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    chmod 644 "$nf"
    assert_output_contains "$output" "Narrative:" "doctor still reaches the narrative line when a file cannot be read" || return 1
    assert_output_contains "$output" "Complete" "and finishes its run" || return 1
}

test_doctor_fails_when_hook_not_executable() {
    local fake_hook_dir="$TEST_TMPDIR/hooks"
    mkdir -p "$fake_hook_dir"
    touch "$fake_hook_dir/session-start.sh"
    chmod 644 "$fake_hook_dir/session-start.sh"
    local output
    output=$(CS_HOOKS_DIR="$fake_hook_dir" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "FAIL\|not executable" \
        "non-executable hook should produce a failure" || return 1
}

test_doctor_exits_nonzero_on_failure() {
    local fake_hook_dir="$TEST_TMPDIR/hooks"
    mkdir -p "$fake_hook_dir"
    touch "$fake_hook_dir/session-start.sh"
    chmod 644 "$fake_hook_dir/session-start.sh"
    local ec
    CS_HOOKS_DIR="$fake_hook_dir" "$CS_BIN" -doctor > /dev/null 2>&1
    ec=$?
    if [[ "$ec" == "0" ]]; then
        echo "  FAIL: doctor should exit non-zero when a check FAILs (got $ec)"
        return 1
    fi
}

# Helper: build a directory that looks like a cs source checkout
make_fake_checkout() {  # dir, [deploy_dir], [version]
    local dir="$1" deployed="${2:-}" version="${3:-9999.9.9}"
    mkdir -p "$dir/hooks" "$dir/bin"
    : > "$dir/install.sh"
    printf 'VERSION="%s"\n' "$version" > "$dir/bin/cs"
    # The drift scan compares only against the checkout that produced the
    # install, which it recognises by the stamp install.sh writes into the
    # deploy directory. Without a matching stamp it declines to compare.
    if [ -n "$deployed" ]; then
        mkdir -p "$deployed"
        printf '%s\n' "$version" > "$deployed/.version"
    fi
}

# Three filenames are not proof of a cs checkout, let alone THE one that was
# installed: any directory holding hooks/, install.sh and bin/cs passes, and a
# scratch copy of the repo is a common thing to be standing in. Comparing a
# stranger's hooks against the deployed ones reports drift naming files the
# user never touched, and advises `./install.sh`, which from there installs
# something else entirely.
test_doctor_drift_ignores_a_checkout_that_did_not_produce_the_install() {
    local checkout="$TEST_TMPDIR/otherco" deployed="$TEST_TMPDIR/otherdep"
    make_fake_checkout "$checkout" "$deployed" "1111.1.1"
    printf '9999.9.9\n' > "$deployed/.version"   # deployed from a different tree
    echo 'echo source-version'   > "$checkout/hooks/session-start.sh"
    echo 'echo deployed-version' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "differs from source" \
        "an unrelated checkout must not be reported as the drifting source" || return 1
    assert_output_not_contains "$output" "not deployed" \
        "nor its hooks reported as undeployed" || return 1
}

# A machine with nothing installed has no version stamp. Reading a missing one
# through a pipe fails, pipefail promotes it, and errexit takes the whole run
# down mid-check, so every check after this one silently never prints. The
# symptom is not a wrong drift verdict, it is unrelated checks going missing.
test_doctor_completes_when_the_deploy_stamp_is_absent() {
    local checkout="$TEST_TMPDIR/nostamp" deployed="$TEST_TMPDIR/nostampdep"
    make_fake_checkout "$checkout" "$deployed"
    rm -f "$deployed/.version"
    echo 'echo hook' > "$checkout/hooks/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Session UUID" \
        "checks after the drift scan must still run without a version stamp" || return 1
    assert_output_contains "$output" "Auto-memory" \
        "and the rest of the run must not be cut short" || return 1
}

test_doctor_warns_on_hook_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$deployed"
    echo 'echo source-version' > "$checkout/hooks/session-start.sh"
    echo 'echo deployed-version' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "differs from source" \
        "doctor should warn when a deployed hook differs from checkout source" || return 1
}

test_doctor_warns_on_undeployed_hook() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$deployed"
    echo 'echo only-in-source' > "$checkout/hooks/brand-new.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "not deployed" \
        "doctor should warn when a source hook has no deployed copy" || return 1
}

test_doctor_drift_silent_when_in_sync() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$deployed"
    echo 'echo same' > "$checkout/hooks/session-start.sh"
    cp "$checkout/hooks/session-start.sh" "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -q "differs from source\|not deployed"; then
        echo "  FAIL: in-sync hooks should not produce drift warnings"
        echo "$output" | grep "Hook drift"
        return 1
    fi
}

test_doctor_drift_skipped_outside_checkout() {
    local plain="$TEST_TMPDIR/not-a-checkout" deployed="$TEST_TMPDIR/deployed"
    mkdir -p "$plain" "$deployed"
    echo 'echo deployed' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$plain" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -qi "drift"; then
        echo "  FAIL: drift check should be silent outside a cs source checkout"
        return 1
    fi
}

test_doctor_warns_on_command_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_cmds="$TEST_TMPDIR/commands"
    make_fake_checkout "$checkout" "$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$checkout/commands" "$deployed_cmds" "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/commands/summary.md"
    echo 'deployed version' > "$deployed_cmds/summary.md"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_COMMANDS_DIR="$deployed_cmds" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Command drift" \
        "doctor should warn when a deployed command differs from checkout source" || return 1
}

test_doctor_warns_on_skill_script_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_skills="$TEST_TMPDIR/skills"
    make_fake_checkout "$checkout" "$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$checkout/skills/write-as-me/scripts" "$deployed_skills/write-as-me/scripts" \
        "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/skills/write-as-me/scripts/build-corpus.sh"
    echo 'deployed version' > "$deployed_skills/write-as-me/scripts/build-corpus.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_SKILLS_DIR="$deployed_skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "write-as-me/scripts/build-corpus.sh" \
        "doctor should name the drifted skill script" || return 1
    assert_output_contains "$output" "differs from source" \
        "drifted support script should warn" || return 1
}

test_doctor_warns_on_skill_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_skills="$TEST_TMPDIR/skills"
    make_fake_checkout "$checkout" "$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$checkout/skills/store-secret" "$deployed_skills/store-secret" "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/skills/store-secret/SKILL.md"
    echo 'deployed version' > "$deployed_skills/store-secret/SKILL.md"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_SKILLS_DIR="$deployed_skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Skill drift" \
        "doctor should warn when a deployed skill differs from checkout source" || return 1
}

test_doctor_warns_on_version_mismatch() {
    local deployed="$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$deployed"
    echo "0.0.0" > "$deployed/.version"

    local output
    output=$(CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Deployed version" \
        "doctor should warn when the deployed stamp differs from cs VERSION" || return 1
    assert_output_contains "$output" "0.0.0" \
        "warning should name the stamped version" || return 1
}

test_doctor_version_silent_without_stamp() {
    local deployed="$TEST_TMPDIR/deployed-hooks"
    mkdir -p "$deployed"
    echo 'echo x' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -q "Deployed version.*WARN\|WARN.*Deployed version"; then
        echo "  FAIL: missing stamp should not produce a version warning"
        return 1
    fi
}

test_doctor_runs_without_session() {
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Keychain" "global-only checks should still run" || return 1
    assert_output_not_contains "$output" "must be run from inside" \
        "doctor should not require a session context" || return 1
}

test_doctor_runs_audit_check() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Audit" "doctor should report an audit summary" || return 1
}

test_doctor_audit_counts_settings_contents() {
    local fake_claude="$TEST_TMPDIR/claude"
    mkdir -p "$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "hooks": [{"type": "command", "command": "/x.sh"}]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "/y.sh"}, {"type": "command", "command": "/z.sh"}]}
    ]
  },
  "permissions": {"allow": ["Bash(ls:*)", "Read"], "deny": ["Write(secrets/**)"]},
  "mcpServers": {"foo": {}, "bar": {}},
  "env": {"FOO": "1"}
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "3 hooks" "should count 3 hook commands across PreToolUse matchers" || return 1
    assert_output_contains "$output" "2 MCPs" "should count 2 MCP servers" || return 1
    assert_output_contains "$output" "3 perm rules" "should count 2 allow + 1 deny = 3 perm rules" || return 1
    assert_output_contains "$output" "1 env vars" "should count 1 env var" || return 1
}

test_doctor_runs_token_cost_check() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Tokens" "doctor should report a tokens summary inside a session" || return 1
}

test_doctor_token_cost_sums_jsonl() {
    local fake_transcripts="$TEST_TMPDIR/transcripts"
    local resolved encoded
    resolved=$( (cd "$CLAUDE_SESSION_DIR" && pwd -P) || printf '%s' "$CLAUDE_SESSION_DIR" )
    encoded=$(echo "$resolved" | sed 's|/|-|g; s|\.|-|g')
    local proj_dir="$fake_transcripts/$encoded"
    mkdir -p "$proj_dir"
    # req_dup appears twice (streamed content blocks repeat usage): its tokens
    # must count once. Naive sum would be 7.0K input / 1.75K output.
    cat > "$proj_dir/session1.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","requestId":"req_dup","message":{"usage":{"input_tokens":1000,"output_tokens":250}}}
{"type":"assistant","requestId":"req_dup","message":{"usage":{"input_tokens":1000,"output_tokens":250}}}
{"type":"assistant","requestId":"req_two","message":{"usage":{"input_tokens":2000,"output_tokens":500}}}
EOF
    cat > "$proj_dir/session2.jsonl" << 'EOF'
{"type":"assistant","requestId":"req_three","message":{"usage":{"input_tokens":3000,"output_tokens":750}}}
EOF
    local output
    output=$(CS_TRANSCRIPTS_DIR="$fake_transcripts" "$CS_BIN" -doctor 2>&1) || true
    # Deduped: 6000 input, 1500 output
    assert_output_contains "$output" "6.0K input" "should dedup by requestId then sum input to 6000" || return 1
    assert_output_contains "$output" "1.5K output" "should dedup by requestId then sum output to 1500" || return 1
}

test_doctor_token_cost_handles_no_transcripts() {
    local fake_transcripts="$TEST_TMPDIR/empty-transcripts"
    mkdir -p "$fake_transcripts"
    local output
    output=$(CS_TRANSCRIPTS_DIR="$fake_transcripts" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Tokens" "tokens check should still run when no transcripts exist" || return 1
    assert_output_contains "$output" "no transcripts" "should report missing transcripts gracefully" || return 1
}

test_doctor_audit_handles_missing_settings() {
    local fake_claude="$TEST_TMPDIR/claude-empty"
    mkdir -p "$fake_claude"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Audit" "audit check should still run when settings.json is missing" || return 1
}

# --- Hook libraries are not registrations ---
# Files in CS_HOOK_LIBS are sourced by the hooks, never invoked by Claude Code,
# so they are deployed alongside them but never named in settings.json. The
# registration check globs *.sh in the deploy dir, so without an exclusion it
# reports every library as a missing registration — a standing [FAIL] on a
# correct install. Both env vars matter: the deploy dir comes from CS_HOOKS_DIR
# and settings.json from CS_CLAUDE_DIR, so a fixture setting only one silently
# reads the developer's real install.

test_doctor_hook_library_is_not_a_missing_registration() {
    local fake_claude="$TEST_TMPDIR/claude-libs" fake_hooks="$TEST_TMPDIR/hooks-libs"
    mkdir -p "$fake_claude" "$fake_hooks"
    : > "$fake_hooks/session-start.sh"
    : > "$fake_hooks/cs-resolve.sh"
    chmod +x "$fake_hooks/session-start.sh" "$fake_hooks/cs-resolve.sh"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "$fake_hooks/session-start.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" CS_HOOKS_DIR="$fake_hooks" "$CS_BIN" -doctor 2>&1) || true
    # Scoped to the registration line: the drift check legitimately names the
    # library (the fixture's stub differs from the shipped source), so a bare
    # "never mentioned" assertion would fail on correct behavior.
    assert_output_not_contains "$output" "missing in settings.json" \
        "a hook library must not be reported as an unregistered hook" || return 1
    assert_output_contains "$output" "Hooks: all registered" \
        "the registration check should pass when only libraries are unregistered" || return 1
}

# The exclusion must not gut the check: a genuine hook left in the deploy dir
# without a registration is still an orphan worth reporting.
test_doctor_still_fails_on_unregistered_hook() {
    local fake_claude="$TEST_TMPDIR/claude-orph2" fake_hooks="$TEST_TMPDIR/hooks-orph2"
    mkdir -p "$fake_claude" "$fake_hooks"
    : > "$fake_hooks/cs-resolve.sh"
    : > "$fake_hooks/scope-prompt.sh"
    chmod +x "$fake_hooks/cs-resolve.sh" "$fake_hooks/scope-prompt.sh"
    printf '{"hooks": {}}\n' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" CS_HOOKS_DIR="$fake_hooks" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "missing in settings.json: scope-prompt.sh" \
        "an unregistered real hook is still reported" || return 1
    assert_output_not_contains "$output" "missing in settings.json.*cs-resolve.sh" \
        "the library is not named alongside it" || return 1
}

# --- Settings.json hook-resolve scan ---
# Catches the inverse direction of _doctor_check_hooks_registered: hooks registered
# in settings.json that point at files which do not exist on disk. This is the
# class of orphan that aboutme-validator.sh exemplified — a feature-branch
# experiment registered the hook in settings.json without the file ever shipping.

test_doctor_runs_settings_hooks_resolve_check() {
    local fake_claude="$TEST_TMPDIR/claude-resolve"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/exists.sh"
    chmod +x "$fake_claude/hooks/exists.sh"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$fake_claude/hooks/exists.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths" "doctor should report a hook-paths summary" || return 1
}

test_doctor_warns_on_settings_hook_missing_file() {
    local fake_claude="$TEST_TMPDIR/claude-orphan"
    mkdir -p "$fake_claude/hooks"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "$fake_claude/hooks/aboutme-validator.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "WARN.*Hook paths\|registered hook.*missing\|aboutme-validator" \
        "doctor should warn when a registered hook points at a missing file" || return 1
}

test_doctor_passes_when_all_settings_hooks_resolve() {
    local fake_claude="$TEST_TMPDIR/claude-clean"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$fake_claude/hooks/real.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "$fake_claude/hooks/real.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths.*OK\|Hook paths.*resolve\|Hook paths.*all" \
        "all-resolved hooks should produce an OK status" || return 1
    assert_output_not_contains "$output" "registered hook.*missing" \
        "no warning should be raised when every hook file exists" || return 1
}


test_doctor_settings_hooks_resolve_handles_no_hooks_section() {
    local fake_claude="$TEST_TMPDIR/claude-nohooks"
    mkdir -p "$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{ "permissions": {"allow": [], "deny": []} }
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook paths" \
        "check should still run when settings.json has no hooks key" || return 1
    assert_output_not_contains "$output" "registered hook.*missing" \
        "missing hooks key is not a leak" || return 1
}

test_doctor_settings_hooks_resolve_expands_tilde() {
    # settings.json typically uses ~/ in the command path; the check must expand it.
    local fake_claude="$TEST_TMPDIR/claude-tilde"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    local fake_home="$fake_claude"
    cat > "$fake_claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/hooks/real.sh"}]}
    ]
  }
}
EOF
    local output
    output=$(HOME="$fake_home" CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "missing" \
        "tilde-prefixed paths must be expanded before existence check" || return 1
}

test_doctor_skips_inline_shell_hook_commands() {
    # Inline shell snippets (e.g. an `if [ -z "$TMUX" ]...` PreToolUse hook) are
    # valid hook commands, not file paths, and must not be flagged as missing.
    local fake_claude="$TEST_TMPDIR/claude-inline"
    mkdir -p "$fake_claude/hooks"
    : > "$fake_claude/hooks/real.sh"
    chmod +x "$fake_claude/hooks/real.sh"
    jq -n --arg real "$fake_claude/hooks/real.sh" '{
      hooks: {
        PreToolUse: [
          {hooks: [{type: "command", command: "if [ -z \"$TMUX\" ]; then echo hi >&2; fi"}]},
          {matcher: "Bash", hooks: [{type: "command", command: $real}]}
        ]
      }
    }' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "registered hook.*missing" \
        "inline shell-snippet hook commands must not be flagged as missing files" || return 1
}

test_doctor_statusline_ok_when_registered_and_executable() {
    local fake_claude="$TEST_TMPDIR/sl-claude"
    local fake_bin="$TEST_TMPDIR/sl-bin"
    mkdir -p "$fake_claude" "$fake_bin"
    printf '#!/bin/sh\n' > "$fake_bin/cs-statusline"
    chmod +x "$fake_bin/cs-statusline"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$fake_bin/cs-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Statusline" "doctor should run a Statusline check" || return 1
    if echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: Statusline check failed for a healthy registration"
        return 1
    fi
}

test_doctor_statusline_fails_when_binary_missing() {
    local fake_claude="$TEST_TMPDIR/sl-claude-missing"
    mkdir -p "$fake_claude"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$TEST_TMPDIR/absent/cs-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    if ! echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: missing cs-statusline binary not reported as FAIL"
        echo "$output" | grep "Statusline" || echo "  (no Statusline line at all)"
        return 1
    fi
}

test_doctor_statusline_no_fail_when_not_registered() {
    local fake_claude="$TEST_TMPDIR/sl-claude-none"
    mkdir -p "$fake_claude"
    echo '{}' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Statusline" "doctor should mention the Statusline check even when unregistered" || return 1
    if echo "$output" | grep "Statusline" | grep -q "FAIL"; then
        echo "  FAIL: unregistered statusline must not FAIL (it is optional)"
        return 1
    fi
}

# Without cs-statusline nothing writes .cs/local/context-pct, and both gates
# that read it — the Stop hook's rotation nudge and the queue drain's context
# circuit breaker — go silently inert. Reporting a bare "not registered (optional)"
# is a clean bill of health for a session whose context gating is off, so the
# check must name the consequence, not just the state.
test_doctor_statusline_names_context_gating_when_absent() {
    local fake_claude="$TEST_TMPDIR/sl-claude-gate-none"
    mkdir -p "$fake_claude"
    echo '{}' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    echo "$output" | grep "Statusline" | grep -q "context-pct" \
        || { echo "  FAIL: unregistered statusline must name context-pct as unwritten"; \
             echo "$output" | grep "Statusline" || echo "  (no Statusline line)"; return 1; }
    echo "$output" | grep "Statusline" | grep -q "WARN" \
        || { echo "  FAIL: inert context gating is a WARN, not an OK"; return 1; }
}

test_doctor_statusline_names_context_gating_for_foreign_statusline() {
    local fake_claude="$TEST_TMPDIR/sl-claude-gate-foreign"
    mkdir -p "$fake_claude"
    printf '{"statusLine":{"command":"/usr/local/bin/starship"}}\n' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    echo "$output" | grep "Statusline" | grep -q "context-pct" \
        || { echo "  FAIL: a non-cs statusline must name context-pct as unwritten"; return 1; }
    echo "$output" | grep "Statusline" | grep -q "WARN" \
        || { echo "  FAIL: a non-cs statusline leaves gating inert — WARN, not OK"; return 1; }
}

test_doctor_subagent_statusline_ok_when_registered_and_executable() {
    local fake_claude="$TEST_TMPDIR/ssl-claude"
    local fake_bin="$TEST_TMPDIR/ssl-bin"
    mkdir -p "$fake_claude" "$fake_bin"
    printf '#!/bin/sh\n' > "$fake_bin/cs-subagent-statusline"
    chmod +x "$fake_bin/cs-subagent-statusline"
    printf '{"subagentStatusLine":{"type":"command","command":"%s"}}\n' "$fake_bin/cs-subagent-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Subagent statusline" "doctor should run a Subagent statusline check" || return 1
    if echo "$output" | grep "Subagent statusline" | grep -q "FAIL"; then
        echo "  FAIL: Subagent statusline check failed for a healthy registration"
        return 1
    fi
}

test_doctor_subagent_statusline_fails_when_binary_missing() {
    local fake_claude="$TEST_TMPDIR/ssl-claude-missing"
    mkdir -p "$fake_claude"
    printf '{"subagentStatusLine":{"type":"command","command":"%s"}}\n' "$TEST_TMPDIR/absent/cs-subagent-statusline" > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    if ! echo "$output" | grep "Subagent statusline" | grep -q "FAIL"; then
        echo "  FAIL: missing cs-subagent-statusline binary not reported as FAIL"
        echo "$output" | grep "Subagent statusline" || echo "  (no Subagent statusline line at all)"
        return 1
    fi
}

test_doctor_subagent_statusline_no_fail_when_not_registered() {
    local fake_claude="$TEST_TMPDIR/ssl-claude-none"
    mkdir -p "$fake_claude"
    echo '{}' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Subagent statusline" "doctor should mention the Subagent statusline check even when unregistered" || return 1
    if echo "$output" | grep "Subagent statusline" | grep -q "FAIL"; then
        echo "  FAIL: unregistered subagent statusline must not FAIL (it is optional)"
        return 1
    fi
}

# --- Spawn hygiene checks ---
# Leftover .spawn seeds (nothing prunes .seed.stale; an orphan .seed blocks the
# name), spawned-by pointers at deleted sessions, and a tmux session named 'cs'
# that cs did not create.

# Minimal tmux fake for the doctor's spawn tmux check.
#   arg1: "cs" if a session named cs exists, "" otherwise
#   arg2: value returned for @cs_managed (e.g. "1" or "")
_doctor_tmux_fake() {  # has_cs managed
    local fake="$TEST_TMPDIR/fake-tmux"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "$1" in\n'
        printf '  has-session) [ "%s" = cs ]; exit $? ;;\n' "$1"
        printf '  show-option) printf "%%s" "%s" ;;\n' "$2"
        printf 'esac\n'
        printf 'exit 0\n'
    } > "$fake"
    chmod +x "$fake"
    printf '%s' "$fake"
}

test_doctor_warns_on_stale_spawn_seeds() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    : > "$CS_SESSIONS_ROOT/.spawn/gone.seed.stale"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "seed.stale" \
        "doctor should warn about aged-out seeds that nothing prunes" || return 1
}

test_doctor_warns_on_orphaned_spawn_seed() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'boss\ndo work\n' > "$CS_SESSIONS_ROOT/.spawn/ghost.seed"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "ghost" \
        "doctor should warn about a pending seed whose session does not exist" || return 1
}

test_doctor_spawn_ok_when_seeds_clean() {
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Spawn" "doctor should report a Spawn summary" || return 1
    if echo "$output" | grep "Spawn" | grep -q "WARN"; then
        echo "  FAIL: clean spawn state must not warn"
        echo "$output" | grep "Spawn"
        return 1
    fi
}

test_doctor_completes_after_spawn_warning() {
    # A spawn warning sets clean=0; the check must still return 0 so `set -e`
    # does not abort the run before its later checks and the summary.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    : > "$CS_SESSIONS_ROOT/.spawn/gone.seed.stale"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Spawn seeds" "the spawn warning still fires" || return 1
    assert_output_contains "$output" "Auto-memory" \
        "session-gated checks after the spawn check must still run (no set -e abort)" || return 1
}

test_doctor_warns_on_dangling_spawned_by() {
    local child="$CS_SESSIONS_ROOT/child"
    mkdir -p "$child/.cs/local"
    echo "# Test" > "$child/CLAUDE.md"
    printf 'ghost-boss\n' > "$child/.cs/local/spawned-by"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "ghost-boss" \
        "doctor should warn when spawned-by names a session that no longer exists" || return 1
}

test_doctor_spawned_by_ok_when_spawner_exists() {
    local child="$CS_SESSIONS_ROOT/child2"
    mkdir -p "$child/.cs/local"
    echo "# Test" > "$child/CLAUDE.md"
    # test-session exists (created in setup); a live spawner is not dangling.
    printf 'test-session\n' > "$child/.cs/local/spawned-by"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -i "spawned-by\|Spawn links" | grep -q "WARN"; then
        echo "  FAIL: an existing spawner must not be flagged as dangling"
        return 1
    fi
}

test_doctor_warns_on_unmarked_cs_tmux_session() {
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake cs '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "not cs-managed\|@cs_managed\|cs -spawn will refuse" \
        "doctor should warn about a foreign tmux session named cs" || return 1
}

test_doctor_no_warning_when_cs_tmux_session_managed() {
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake cs 1)" "$CS_BIN" -doctor 2>&1) || true
    if echo "$output" | grep -i "tmux" | grep -q "not cs-managed"; then
        echo "  FAIL: a cs-managed tmux session must not warn"
        return 1
    fi
}

echo "Running doctor tests..."
run_test test_doctor_subcommand_exists
run_test test_doctor_runs_default_checks_from_session
run_test test_doctor_reports_pass_for_healthy_session
run_test test_doctor_warns_on_a_narrative_over_budget
run_test test_doctor_reports_ok_when_narratives_fit
run_test test_doctor_survives_an_unreadable_narrative
run_test test_doctor_fails_when_hook_not_executable
run_test test_doctor_exits_nonzero_on_failure
run_test test_doctor_completes_when_the_deploy_stamp_is_absent
run_test test_doctor_drift_ignores_a_checkout_that_did_not_produce_the_install
run_test test_doctor_warns_on_hook_drift
run_test test_doctor_warns_on_undeployed_hook
run_test test_doctor_drift_silent_when_in_sync
run_test test_doctor_drift_skipped_outside_checkout
run_test test_doctor_warns_on_command_drift
run_test test_doctor_warns_on_skill_script_drift
run_test test_doctor_warns_on_skill_drift
run_test test_doctor_warns_on_version_mismatch
run_test test_doctor_version_silent_without_stamp
run_test test_doctor_runs_without_session
run_test test_doctor_runs_audit_check
run_test test_doctor_audit_counts_settings_contents
run_test test_doctor_audit_handles_missing_settings
run_test test_doctor_hook_library_is_not_a_missing_registration
run_test test_doctor_still_fails_on_unregistered_hook
run_test test_doctor_runs_settings_hooks_resolve_check
run_test test_doctor_warns_on_settings_hook_missing_file
run_test test_doctor_passes_when_all_settings_hooks_resolve
run_test test_doctor_settings_hooks_resolve_handles_no_hooks_section
run_test test_doctor_settings_hooks_resolve_expands_tilde
run_test test_doctor_skips_inline_shell_hook_commands
run_test test_doctor_statusline_ok_when_registered_and_executable
run_test test_doctor_statusline_fails_when_binary_missing
run_test test_doctor_statusline_no_fail_when_not_registered
run_test test_doctor_statusline_names_context_gating_when_absent
run_test test_doctor_statusline_names_context_gating_for_foreign_statusline
run_test test_doctor_subagent_statusline_ok_when_registered_and_executable
run_test test_doctor_subagent_statusline_fails_when_binary_missing
run_test test_doctor_subagent_statusline_no_fail_when_not_registered
run_test test_doctor_runs_token_cost_check
run_test test_doctor_token_cost_sums_jsonl
run_test test_doctor_token_cost_handles_no_transcripts
run_test test_doctor_warns_on_stale_spawn_seeds
run_test test_doctor_completes_after_spawn_warning
run_test test_doctor_warns_on_orphaned_spawn_seed
run_test test_doctor_spawn_ok_when_seeds_clean
run_test test_doctor_warns_on_dangling_spawned_by
run_test test_doctor_spawned_by_ok_when_spawner_exists
run_test test_doctor_warns_on_unmarked_cs_tmux_session
run_test test_doctor_no_warning_when_cs_tmux_session_managed

# --- Checks that must not report green on the state they exist to catch ---
# Every fixture below is in the BROKEN state. A green-path test proves nothing
# here: the defect in each case was that the check passed under corruption.

test_doctor_fails_on_unparseable_settings() {
    # Every settings check reads the file with jq and swallows the error, so a
    # syntax error produced a screen of OKs — no hooks missing, no hook paths
    # broken, "0 hooks, 0 MCPs", statusline "not registered (optional)". A
    # diagnostic that reports healthy on a file it cannot read is worse than
    # no diagnostic.
    local fake_claude="$TEST_TMPDIR/claude-badjson"
    mkdir -p "$fake_claude"
    printf '{"hooks": {"SessionStart": [ }\n' > "$fake_claude/settings.json"
    # Fixture sanity: the file really is unparseable, or nothing is being tested.
    if jq -e . "$fake_claude/settings.json" >/dev/null 2>&1; then
        echo "  FAIL: fixture settings.json parses; the defect is unreachable"
        return 1
    fi
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "not valid JSON" \
        "doctor must name the parse failure" || return 1
    assert_output_contains "$output" "FAIL" \
        "an unreadable settings file is a failure, not a warning" || return 1
    assert_output_not_contains "$output" "0 hooks, 0 MCPs" \
        "counts from a failed parse must not be reported as an audit result" || return 1
}

test_doctor_does_not_accept_a_hook_named_only_in_a_permission_rule() {
    # The registration check substring-matched the WHOLE settings file, so a
    # hook path lingering anywhere — a permissions rule, a comment-like string,
    # an env value — read as "registered". The hook never fires, and doctor
    # said the install was fine.
    local fake_claude="$TEST_TMPDIR/claude-permonly" fake_hooks="$TEST_TMPDIR/hooks-permonly"
    mkdir -p "$fake_claude" "$fake_hooks"
    : > "$fake_hooks/session-start.sh"
    chmod +x "$fake_hooks/session-start.sh"
    # session-start.sh appears in the file, but only inside a permission rule —
    # the hooks section registers something else entirely.
    cat > "$fake_claude/settings.json" << EOF
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "$fake_hooks/other.sh"}]}
    ]
  },
  "permissions": {"allow": ["Bash($fake_hooks/session-start.sh)"]}
}
EOF
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" CS_HOOKS_DIR="$fake_hooks" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "missing in settings.json" \
        "a hook absent from the hooks section is not registered" || return 1
    assert_output_contains "$output" "session-start.sh" \
        "the failure must name the unregistered hook" || return 1
}

test_doctor_warns_when_only_untracked_work_has_no_shadow_ref() {
    # The autosave hook snapshots with `git add -A`, which stages untracked
    # files. The check tested `git diff --quiet HEAD` — tracked changes only —
    # so a session whose entire body of work is untracked reported "no
    # uncommitted work to snapshot" on exactly the broken-autosave state.
    local dir="$CLAUDE_SESSION_DIR"
    echo "unsaved work" > "$dir/scratch-note.txt"
    # Fixture sanity: tracked-clean, untracked-dirty, and no shadow ref — the
    # precise state that produced the false OK.
    git -C "$dir" diff --quiet HEAD 2>/dev/null \
        || { echo "  FAIL: fixture has tracked changes; it would pass for the wrong reason"; return 1; }
    local others
    others=$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null || true)
    [ -n "$others" ] || { echo "  FAIL: fixture produced no untracked files"; return 1; }

    local output
    output=$(CS_CLAUDE_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "autosave may be broken" \
        "untracked work with no shadow ref must warn" || return 1
    assert_output_not_contains "$output" "no uncommitted work to snapshot" \
        "untracked work is work" || return 1
}

run_test test_doctor_fails_on_unparseable_settings
run_test test_doctor_does_not_accept_a_hook_named_only_in_a_permission_rule
run_test test_doctor_warns_when_only_untracked_work_has_no_shadow_ref
# Build a PATH resolving everything doctor needs EXCEPT jq. bash included: this
# PATH is what starts the binary, and omitting it fails at exec and reads like a
# doctor bug.
_jq_free_path() {
    local d="$TEST_TMPDIR/nojq"
    mkdir -p "$d"
    _stub_tools "$d" bash sh git grep sed awk cut tr head tail wc sort uniq basename \
                dirname date mkdir rm cat ls find stat printf id kill || return $?
    printf '%s' "$d"
}

test_doctor_does_not_call_a_valid_settings_file_invalid_without_jq() {
    # Every settings check reads the file through jq, so on a machine with no jq
    # its exit 127 is indistinguishable from a parse failure — and doctor then
    # states, falsely and confidently, that the file is not valid JSON. That is
    # the same lying-diagnostic class these gates exist to remove.
    local fake_claude="$TEST_TMPDIR/claude-nojq"
    mkdir -p "$fake_claude"
    printf '{"hooks": {}}\n' > "$fake_claude/settings.json"
    jq -e . "$fake_claude/settings.json" >/dev/null 2>&1 \
        || { echo "  FAIL: fixture is not valid JSON; the test would pass for the wrong reason"; return 1; }

    local p rc=0; p=$(_jq_free_path) || rc=$?
    # 2 means the stub PATH is not constructible on this host.
    [ "$rc" = "2" ] && return 0
    [ "$rc" = "0" ] || { echo "  FAIL: could not build a jq-free PATH"; return 1; }
    # Drop the hashed location of the jq just run above. Under bash 3.2 — the
    # floor, and what macos-latest runs — `command -v` answers from the hash
    # table and a one-command PATH assignment does not invalidate it, so the
    # guard below would report a jq the scrubbed PATH cannot actually reach.
    # doctor itself is unaffected: it runs in a fresh process with no hash.
    hash -r 2>/dev/null || true
    if PATH="$p" command -v jq >/dev/null 2>&1; then
        echo "  FAIL: jq is still resolvable on that PATH"; return 1
    fi
    local output
    output=$(PATH="$p" CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "not valid JSON" \
        "a file doctor cannot READ must not be reported as malformed" || return 1
    assert_output_not_contains "$output" "invalid JSON" \
        "and no downstream check may claim it either" || return 1
    assert_output_contains "$output" "jq" \
        "doctor should say jq is missing rather than blame the file" || return 1
}

run_test test_doctor_does_not_call_a_valid_settings_file_invalid_without_jq

report_results
