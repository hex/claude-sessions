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

# .cs/memory is tracked, so a clone chooses a narrative's file name, and the
# name can carry a terminal escape: a raw ESC or BEL byte, or backslash text
# echo -e would turn into one. The warning names it as a plain name, each
# character a plain name lacks replaced by _.
test_doctor_names_a_narrative_over_budget_as_a_plain_name() {
    local bad=$'e\033[1mb\007\\e[0m' shown=e__1mb__e_0m output msg
    { echo "# Session narrative"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } \
        > "$CLAUDE_SESSION_META_DIR/memory/narrative.a$bad.md"
    output=$(CS_NARRATIVE_MAX_BYTES=2048 "$CS_BIN" -doctor 2>&1) || true
    # The [WARN] tag before the message carries cs's own colours.
    msg=$(grep 'Narrative: narrative\.a' <<< "$output")
    msg="Narrative: ${msg#*Narrative: }"
    assert_eq "Narrative: narrative.a$shown.md is 2 KB (budget 2 KB) — run cs -narrative rotate" "$msg" \
        "the warning names the narrative as a plain name" || return 1
    assert_no_escape_bytes "$msg" "no escape byte reaches the terminal" || return 1
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

# A leading zero passes the digit check and reaches the KB arithmetic as an
# octal literal; `08` is not octal, and under errexit doctor would die there.
test_doctor_reads_a_leading_zero_budget_as_decimal() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    local output
    output=$(CS_NARRATIVE_MAX_BYTES=08 "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "value too great for base" "no octal abort" || return 1
    assert_output_contains "$output" "Narrative: narrative.alice.md is 2 KB (budget 0 KB)" "the override is decimal 8" || return 1
    assert_output_contains "$output" "Complete with [1-9][0-9]* warning(s)\." "doctor ran to its summary" || return 1
}

test_doctor_reports_ok_when_narratives_fit() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    # Derive the budget rather than pinning a literal: the number is a tuning
    # decision that has already moved once (128 KiB held about a day of
    # sections), and a hardcoded KB figure here fails the gate on the change
    # itself while catching no defect. What must stay true is that the line
    # names the SAME budget the tool would rotate at.
    local budget_kb
    budget_kb=$(( $(grep -o 'CS_NARRATIVE_MAX_DEFAULT=[0-9]*' "$SCRIPT_DIR/../lib/02-shared.sh" \
        | head -1 | cut -d= -f2) / 1024 ))
    assert_output_contains "$output" "Narrative: all within the $budget_kb KB budget" \
        "ok line names the budget cs -narrative rotate would use" || return 1
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

# The passes /wrap reads deploy beside the hooks, so an edited pass the
# installer has not copied is hook drift too.
test_doctor_warns_on_wrap_pass_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed="$TEST_TMPDIR/deployed"
    make_fake_checkout "$checkout" "$deployed"
    echo 'source pass' > "$checkout/hooks/wrap-sweep.md"
    echo 'deployed pass' > "$deployed/wrap-sweep.md"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook drift: deployed copy differs from source: wrap-sweep.md" \
        "doctor should warn when a deployed wrap pass differs from checkout source" || return 1
}

# ./install.sh replaces a deployed copy cs wrote and keeps one it did not (the
# user's edit), so the drift row's advice follows what the install will do:
# run it for cs's own copy; for a copy kept as the user's, move it aside first.
# The record names session-start.sh as cs's; narrative-reminder.sh is not in
# it and is no content cs ever shipped.
test_doctor_drift_advice_follows_whose_the_deployed_copy_is() {
    local home="$TEST_TMPDIR/drift-home" checkout="$TEST_TMPDIR/keptco" deployed digest output
    deployed="$home/.claude/hooks/cs"
    make_fake_checkout "$checkout" "$deployed"
    echo 'echo source' > "$checkout/hooks/session-start.sh"
    echo 'echo source' > "$checkout/hooks/narrative-reminder.sh"
    echo 'echo an-older-cs-build' > "$deployed/session-start.sh"
    echo 'echo the-users-edit' > "$deployed/narrative-reminder.sh"
    chmod +x "$deployed/session-start.sh" "$deployed/narrative-reminder.sh"
    digest=$(shasum -a 256 "$deployed/session-start.sh" | cut -d' ' -f1)
    printf '%s  .claude/hooks/cs/session-start.sh\n' "$digest" > "$deployed/.installed"

    output=$(cd "$checkout" && HOME="$home" CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Hook drift: deployed copy differs from source: session-start.sh (run ./install.sh)$" \
        "cs's own copy: run the installer" || { echo "$output"; return 1; }
    assert_output_contains "$output" "Hook drift: deployed copy differs from source: narrative-reminder.sh (kept as yours, so ./install.sh does not replace it; move it aside, then run ./install.sh to get cs's copy)$" \
        "the user's copy: move it aside first" || { echo "$output"; return 1; }
    assert_output_not_contains "$output" "narrative-reminder.sh.*(run ./install.sh)$" \
        "the user's copy is not offered the plain advice" || { echo "$output"; return 1; }
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
    if grep -q "differs from source\|not deployed" <<< "$output"; then
        echo "  FAIL: in-sync hooks should not produce drift warnings"
        echo "$output" | grep "Hook drift"
        return 1
    fi
}

# The rotate mod deploys under ~/.claude/skills/cs from mods/ in the
# checkout, so the drift scan has to read that tree too, or an edited module
# ships nowhere and doctor stays green.
test_doctor_warns_on_mod_drift() {
    local checkout="$TEST_TMPDIR/modco" deployed="$TEST_TMPDIR/moddep" skills="$TEST_TMPDIR/modskills"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$checkout/mods/cs/hooks" "$skills/cs/hooks"
    echo 'export const CRIT_PERCENT = 65' > "$checkout/mods/cs/hooks/register.tsx"
    echo 'export const CRIT_PERCENT = 66' > "$skills/cs/hooks/register.tsx"
    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" CS_SKILLS_DIR="$skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Mod drift: deployed copy differs from source: cs/hooks/register.tsx" \
        "an edited module the installer has not copied is drift" || return 1
    cp "$checkout/mods/cs/hooks/register.tsx" "$skills/cs/hooks/register.tsx"
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" CS_SKILLS_DIR="$skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Deploy drift" "the scan ran to its verdict" || return 1
    assert_output_not_contains "$output" "Mod drift" "in sync: silent" || return 1
}

# The cs mod's spinner tips deploy beside its hooks as cs/tips.json, so an
# edited or missing tips file is drift too.
test_doctor_warns_on_mod_tips_drift() {
    local checkout="$TEST_TMPDIR/tipsco" deployed="$TEST_TMPDIR/tipsdep" skills="$TEST_TMPDIR/tipsskills"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$checkout/mods/cs" "$skills/cs"
    echo '{"tips":["one"]}' > "$checkout/mods/cs/tips.json"
    echo '{"tips":["two"]}' > "$skills/cs/tips.json"
    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" CS_SKILLS_DIR="$skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Mod drift: deployed copy differs from source: cs/tips.json" \
        "an edited tips file the installer has not copied is drift" || return 1
    rm "$skills/cs/tips.json"
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" CS_SKILLS_DIR="$skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Mod drift: not deployed: cs/tips.json" \
        "a tips file the installer never copied is drift" || return 1
}

# A mod the installer keeps out (CS_MODS_KEPT_OUT, cs-chat-only) is never deployed,
# so its source is not drift: no "not deployed" row names it.
test_doctor_drift_skips_a_kept_out_mod() {
    local checkout="$TEST_TMPDIR/keptmodco" deployed="$TEST_TMPDIR/keptmoddep" skills="$TEST_TMPDIR/keptmodskills"
    make_fake_checkout "$checkout" "$deployed"
    mkdir -p "$checkout/mods/cs/hooks" "$checkout/mods/cs-chat-only/hooks" "$skills/cs/hooks"
    echo 'export const CRIT_PERCENT = 65' > "$checkout/mods/cs/hooks/register.tsx"
    cp "$checkout/mods/cs/hooks/register.tsx" "$skills/cs/hooks/register.tsx"
    echo 'export const CHAT_ONLY = 1' > "$checkout/mods/cs-chat-only/hooks/register.tsx"
    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$deployed" CS_SKILLS_DIR="$skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Deploy drift" "the scan ran to its verdict" || return 1
    assert_output_not_contains "$output" "Mod drift" "the kept-out mod is not drift" || return 1
}

test_doctor_drift_skipped_outside_checkout() {
    local plain="$TEST_TMPDIR/not-a-checkout" deployed="$TEST_TMPDIR/deployed"
    mkdir -p "$plain" "$deployed"
    echo 'echo deployed' > "$deployed/session-start.sh"
    chmod +x "$deployed/session-start.sh"

    local output
    output=$(cd "$plain" && CS_HOOKS_DIR="$deployed" "$CS_BIN" -doctor 2>&1) || true
    if grep -qi "drift" <<< "$output"; then
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

# Helper: a cs checkout with a TUI source tree whose files carry mtime $2
# (touch -t form), and an empty install dir under a HOME of the test's own.
# install.sh copies a picker it never builds, so the freshness of cs-tui is
# read from these mtimes and bytes.
make_tui_checkout() {  # dir, source_stamp
    local dir="$1"
    make_fake_checkout "$dir" "$TEST_TMPDIR/tui-deployed"
    mkdir -p "$dir/tui/src" "$dir/tui/target/release" "$TEST_TMPDIR/home/.local/bin"
    echo '[package]' > "$dir/tui/Cargo.toml"
    echo '# lock' > "$dir/tui/Cargo.lock"
    echo 'fn main() {}' > "$dir/tui/src/main.rs"
    touch -t "$2" "$dir/tui/Cargo.toml" "$dir/tui/Cargo.lock" "$dir/tui/src/main.rs"
}

# Helper: the line install.sh writes to say where the installed picker came
# from ("checkout <path>" or "release").
record_tui_origin() {  # line
    mkdir -p "$TEST_TMPDIR/tui-deployed"
    printf '%s\n' "$1" > "$TEST_TMPDIR/tui-deployed/.tui-origin"
}

# Doctor run from directory $1 under the test's HOME; prints its output.
doctor_from() {  # dir
    mkdir -p "$1"
    (cd "$1" && HOME="$TEST_TMPDIR/home" CS_HOOKS_DIR="$TEST_TMPDIR/tui-deployed" "$CS_BIN" -doctor 2>&1) || true
}

# The cs-tui row of doctor output $1 with its colour tag stripped, and the
# tag's name in front: "WARN cs-tui: ...", "OK cs-tui: ...", or "NOTE
# cs-tui: ..." for the untagged line doctor prints when it cannot judge.
tui_row() {  # output
    local line
    line=$(grep 'cs-tui: ' <<< "$1") || return 0
    case "$line" in
        "  cs-tui: "*) printf 'NOTE cs-tui: %s\n' "${line#*cs-tui: }" ;;
        *"[WARN]"*) printf 'WARN cs-tui: %s\n' "${line#*cs-tui: }" ;;
        *"[ OK ]"*) printf 'OK cs-tui: %s\n' "${line#*cs-tui: }" ;;
        *) printf 'UNTAGGED %s\n' "$line" ;;
    esac
}

# A merge rewrites tui/src while the build under tui/target stays where cargo
# left it, and install.sh ships that build as it is: the picker goes stale
# with nothing to say so. Doctor reads the checkout from the install's record,
# so it says so from any folder.
test_doctor_tui_warns_when_a_rust_source_changed_after_the_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601010000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/src/main.rs"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the TUI source under $checkout/tui changed after the build $checkout/tui/target/release/cs-tui, so the installed picker may be stale (run cargo build --release --manifest-path $checkout/tui/Cargo.toml, then $checkout/install.sh)" \
        "$(tui_row "$output")" "a .rs file newer than the build is named with the rebuild" || return 1
}

test_doctor_tui_warns_when_cargo_toml_changed_after_the_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601010000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/Cargo.toml"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the TUI source under $checkout/tui changed after the build $checkout/tui/target/release/cs-tui, so the installed picker may be stale (run cargo build --release --manifest-path $checkout/tui/Cargo.toml, then $checkout/install.sh)" \
        "$(tui_row "$output")" "a Cargo.toml newer than the build is named with the rebuild" || return 1
}

test_doctor_tui_warns_when_cargo_lock_changed_after_the_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601010000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/Cargo.lock"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the TUI source under $checkout/tui changed after the build $checkout/tui/target/release/cs-tui, so the installed picker may be stale (run cargo build --release --manifest-path $checkout/tui/Cargo.toml, then $checkout/install.sh)" \
        "$(tui_row "$output")" "a Cargo.lock newer than the build is named with the rebuild" || return 1
}

# Cargo rebuilds only from the files rustc reads, so a Finder .DS_Store or a
# merge's .orig under tui/src newer than the build is no reason to rebuild,
# and a rebuild would not clear a row that counted it.
test_doctor_tui_ok_with_a_stray_file_under_src_newer_than_the_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601010000
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    echo 'finder' > "$checkout/tui/src/.DS_Store"
    echo 'merge leftover' > "$checkout/tui/src/main.rs.orig"
    touch -t 202601030000 "$checkout/tui/src/.DS_Store" "$checkout/tui/src/main.rs.orig"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "OK cs-tui: the installed picker matches the build $checkout/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "files cargo does not read leave the picker OK" || return 1
}

# A rebuild that never reached install.sh leaves the old picker in place.
test_doctor_warns_when_the_installed_tui_differs_from_the_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'new build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    echo 'old build' > "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the installed $TEST_TMPDIR/home/.local/bin/cs-tui differs from the build $checkout/tui/target/release/cs-tui (run $checkout/install.sh)" \
        "$(tui_row "$output")" "an uninstalled rebuild is named with the install" || return 1
}

test_doctor_tui_ok_when_the_installed_picker_is_the_fresh_build() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'new build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "OK cs-tui: the installed picker matches the build $checkout/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "a fresh build, installed, is OK" || return 1
}

# install.sh ships bin/cs-tui when it is newer than the cargo build, so that
# is the build the installed picker is held to: install.sh, the advice the
# warning gives, must be able to clear it.
test_doctor_tui_holds_the_picker_to_the_build_install_sh_ships() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'cargo build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    echo 'copied build' > "$checkout/bin/cs-tui"
    touch -t 202601040000 "$checkout/bin/cs-tui"
    cp "$checkout/bin/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "OK cs-tui: the installed picker matches the build $checkout/bin/cs-tui" \
        "$(tui_row "$output")" "the newer bin/cs-tui is the build install.sh ships" || return 1
}

# A source directory doctor cannot read is said so, and the run goes on to
# its summary.
test_doctor_tui_names_a_source_tree_it_cannot_read() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    mkdir -p "$checkout/tui/src/locked"
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    chmod 000 "$checkout/tui/src/locked"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    chmod 755 "$checkout/tui/src/locked"
    assert_eq "WARN cs-tui: could not read the TUI source under $checkout/tui to compare it with the build $checkout/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "an unreadable source tree is named, not passed" || return 1
    assert_output_contains "$output" "Complete with [1-9][0-9]* warning(s)\." "doctor ran to its summary" || return 1
}

# The record holds the checkout path whole, spaces and all, and the commands
# the row gives are quoted so they paste.
test_doctor_tui_reads_a_recorded_checkout_whose_path_holds_spaces() {
    local checkout="$TEST_TMPDIR/tui co" output
    make_tui_checkout "$checkout" 202601010000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/src/main.rs"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the TUI source under $checkout/tui changed after the build $checkout/tui/target/release/cs-tui, so the installed picker may be stale (run cargo build --release --manifest-path $TEST_TMPDIR/tui\\ co/tui/Cargo.toml, then $TEST_TMPDIR/tui\\ co/install.sh)" \
        "$(tui_row "$output")" "a recorded path with a space is read whole and quoted in the advice" || return 1
}

# A checkout path with a control character in it (here an escape, which a
# terminal obeys) prints in every row as cs prints any name (_printable_name):
# the character as one "?". The advice commands keep the %q form, which
# pastes back as the same path.
test_doctor_tui_prints_a_control_character_in_the_recorded_path_as_a_question_mark() {
    local checkout="$TEST_TMPDIR/co"$'\e'"[31mRED" output
    local shown="$TEST_TMPDIR/co?[31mRED" quoted="\$'$TEST_TMPDIR/co\\E[31mRED'"
    local installed="$TEST_TMPDIR/home/.local/bin/cs-tui"
    make_tui_checkout "$checkout" 202601010000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601020000 "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/src/main.rs"
    cp "$checkout/tui/target/release/cs-tui" "$installed"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the TUI source under $shown/tui changed after the build $shown/tui/target/release/cs-tui, so the installed picker may be stale (run cargo build --release --manifest-path $quoted/tui/Cargo.toml, then $quoted/install.sh)" \
        "$(tui_row "$output")" "a source change: the path's escape prints as ?" || return 1
    touch -t 202601040000 "$checkout/tui/target/release/cs-tui"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "OK cs-tui: the installed picker matches the build $shown/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "a fresh build: the path's escape prints as ?" || return 1
    echo 'other build' > "$installed"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "WARN cs-tui: the installed $installed differs from the build $shown/tui/target/release/cs-tui (run $quoted/install.sh)" \
        "$(tui_row "$output")" "a differing picker: the path's escape prints as ?" || return 1
    mkdir -p "$checkout/tui/src/locked"
    chmod 000 "$checkout/tui/src/locked"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    chmod 755 "$checkout/tui/src/locked"
    assert_eq "WARN cs-tui: could not read the TUI source under $shown/tui to compare it with the build $shown/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "an unreadable source: the path's escape prints as ?" || return 1
    rm "$checkout/tui/Cargo.toml"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: $installed came from $shown, which holds no tui/Cargo.toml now; run ./install.sh from your checkout, or cs -update" \
        "$(tui_row "$output")" "a checkout without its TUI: the path's escape prints as ?" || return 1
}

# install.sh writes the record as one line. A record of more lines is not
# one install.sh wrote, so doctor takes no line of it for the checkout, even
# a first line that names a checkout whose build is installed.
test_doctor_tui_names_an_origin_record_of_more_than_one_line() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"$'\n'"release"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: nothing in $TEST_TMPDIR/tui-deployed/.tui-origin says where $TEST_TMPDIR/home/.local/bin/cs-tui came from; the next ./install.sh from your checkout records it, and cs -update records it where a release picker exists for this platform (and replaces a checkout-built picker with the release one)" \
        "$(tui_row "$output")" "a record of two lines: the not-understood line" || return 1
    assert_eq "1" "$(grep -c 'cs-tui' <<< "$output")" "the line is one line" || return 1
}

# A recorded path that ends in a slash names the same checkout, and its rows
# join the path to tui/ with one slash.
test_doctor_tui_reads_a_recorded_checkout_path_that_ends_in_a_slash() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout/"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "OK cs-tui: the installed picker matches the build $checkout/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "a trailing slash in the record: one slash in the row" || return 1
}

# A worktree or another clone at the same version has its own build. Doctor
# run from there holds the picker to the checkout the install recorded, not
# to the tree it stands in.
test_doctor_tui_judges_the_recorded_checkout_not_the_one_it_runs_in() {
    local checkout="$TEST_TMPDIR/tuico" other="$TEST_TMPDIR/worktree" output
    make_tui_checkout "$checkout" 202601020000
    echo 'installed build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    make_tui_checkout "$other" 202601020000
    echo 'feature build' > "$other/tui/target/release/cs-tui"
    touch -t 202601030000 "$other/tui/target/release/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$other")
    assert_eq "OK cs-tui: the installed picker matches the build $checkout/tui/target/release/cs-tui" \
        "$(tui_row "$output")" "a same-version tree's own build is not the installed picker's" || return 1
}

# A release-asset install has no checkout to hold the picker to, even when
# doctor runs in a same-version clone with a build of its own.
test_doctor_tui_silent_for_a_release_picker() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'local build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601010000 "$checkout/tui/target/release/cs-tui"
    echo 'release asset' > "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "release"
    output=$(doctor_from "$checkout")
    assert_eq "" "$(tui_row "$output")" "a release picker: no cs-tui row" || return 1
    assert_output_contains "$output" "Deploy drift" "doctor ran in the same-version clone" || return 1
}

# An install that predates the record, or one that placed no picker over an
# earlier one, leaves nothing saying where the picker came from: one line
# says it was not checked and which install writes the record: ./install.sh
# from a checkout, or cs -update where a release picker exists.
test_doctor_tui_names_a_missing_origin_record() {
    local output
    mkdir -p "$TEST_TMPDIR/home/.local/bin" "$TEST_TMPDIR/tui-deployed"
    echo 'picker' > "$TEST_TMPDIR/home/.local/bin/cs-tui"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: nothing in $TEST_TMPDIR/tui-deployed/.tui-origin says where $TEST_TMPDIR/home/.local/bin/cs-tui came from; the next ./install.sh from your checkout records it, and cs -update records it where a release picker exists for this platform (and replaces a checkout-built picker with the release one)" \
        "$(tui_row "$output")" "no record: one neutral line naming the fix" || return 1
}

test_doctor_tui_names_an_origin_record_it_does_not_understand() {
    local output
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    echo 'picker' > "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout relative/path"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: nothing in $TEST_TMPDIR/tui-deployed/.tui-origin says where $TEST_TMPDIR/home/.local/bin/cs-tui came from; the next ./install.sh from your checkout records it, and cs -update records it where a release picker exists for this platform (and replaces a checkout-built picker with the release one)" \
        "$(tui_row "$output")" "a record that names no absolute checkout or release: the same line" || return 1
}

# The checkout the picker came from was deleted, or no longer holds the TUI:
# there is no build to hold the picker to, and the fix is an install from the
# checkout in use now, or cs -update.
test_doctor_tui_names_a_recorded_checkout_without_its_tui() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    cp "$checkout/tui/target/release/cs-tui" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    rm "$checkout/tui/Cargo.toml"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: $TEST_TMPDIR/home/.local/bin/cs-tui came from $checkout, which holds no tui/Cargo.toml now; run ./install.sh from your checkout, or cs -update" \
        "$(tui_row "$output")" "a recorded checkout without its TUI: one neutral line" || return 1
    rm -rf "$checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "NOTE cs-tui: not checked: $TEST_TMPDIR/home/.local/bin/cs-tui came from $checkout, which holds no tui/Cargo.toml now; run ./install.sh from your checkout, or cs -update" \
        "$(tui_row "$output")" "a recorded checkout that is gone: the same line" || return 1
}

# install.sh keeps a symlink at ~/.local/bin/cs-tui that points at content it
# did not write, so whatever the record says, the picker is the user's own.
test_doctor_tui_silent_for_a_picker_that_is_a_symlink() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601030000 "$checkout/tui/target/release/cs-tui"
    echo 'own picker' > "$TEST_TMPDIR/own-picker"
    ln -s "$TEST_TMPDIR/own-picker" "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "" "$(tui_row "$output")" "the user's own linked picker: no cs-tui row" || return 1
}

# A recorded checkout with no build (cargo clean, or bin/cs-tui deleted) has
# nothing to hold the picker to: doctor cannot tell, so it says nothing.
test_doctor_tui_silent_without_a_build_in_the_checkout() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'some picker' > "$TEST_TMPDIR/home/.local/bin/cs-tui"
    touch -t 202601010000 "$TEST_TMPDIR/home/.local/bin/cs-tui"
    record_tui_origin "checkout $checkout"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "" "$(tui_row "$output")" "no build: no cs-tui row" || return 1
}

test_doctor_tui_silent_when_no_picker_is_installed() {
    local checkout="$TEST_TMPDIR/tuico" output
    make_tui_checkout "$checkout" 202601020000
    echo 'old build' > "$checkout/tui/target/release/cs-tui"
    touch -t 202601010000 "$checkout/tui/target/release/cs-tui"
    output=$(doctor_from "$TEST_TMPDIR/elsewhere")
    assert_eq "" "$(tui_row "$output")" "nothing installed and no record: no cs-tui row" || return 1
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
    if grep -q "Deployed version.*WARN\|WARN.*Deployed version" <<< "$output"; then
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
    local proj_dir
    proj_dir="$fake_transcripts/$(_encode_cwd_for_claude_test "$CLAUDE_SESSION_DIR")"
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

# Install and uninstall keep a hook event whose value is not a list, and an
# entry or a hook in an event's list that is not an object: they are the
# user's. Every row that reads the hook events reads past them to cs's own
# registrations, wherever they sit, and the run reaches its summary. Cases:
# a string event before cs's events, the same after them, and cs's events
# holding entries and hooks that are not objects.
test_doctor_reads_past_hook_events_and_entries_that_are_not_objects() {
    local fake_claude="$TEST_TMPDIR/claude-nonlist" fake_hooks="$TEST_TMPDIR/hooks-nonlist"
    local id="11111111-2222-3333-4444-555555555555" case_name output rc
    mkdir -p "$fake_claude" "$fake_hooks"
    : > "$fake_hooks/session-start.sh"
    : > "$fake_hooks/autosave-commits.sh"
    chmod +x "$fake_hooks/session-start.sh" "$fake_hooks/autosave-commits.sh"
    for case_name in string-event-first string-event-last entries-not-objects; do
        jq -n --arg case "$case_name" --arg start "$fake_hooks/session-start.sh" \
            --arg autosave "$fake_hooks/autosave-commits.sh" '
            {SessionStart: [{hooks: [{type: "command", command: $start}]}],
             PostToolUse: [{matcher: "Write|Edit", hooks: [{type: "command", command: $autosave}]}]} as $cs
            | {hooks: (
                if $case == "string-event-first" then {Notification: "not-a-list"} + $cs
                elif $case == "string-event-last" then $cs + {Notification: "not-a-list"}
                else {SessionStart: [{hooks: ["bare", {type: "command", command: $start}]}],
                      PostToolUse: ["user-entry", {matcher: "Write|Edit", hooks: [{type: "command", command: $autosave}]}]}
                end)}' > "$fake_claude/settings.json"
        rc=0
        output=$(CLAUDE_CODE_SESSION_ID="$id" CS_CLAUDE_DIR="$fake_claude" CS_HOOKS_DIR="$fake_hooks" \
            "$CS_BIN" -doctor 2>&1) || rc=$?
        assert_output_contains "$output" "Hooks: all registered in settings.json" \
            "$case_name: cs's hooks are found registered" || { echo "$output"; return 1; }
        assert_output_contains "$output" "Hook paths: all registered hooks resolve to existing files" \
            "$case_name: the hook paths row reads every registration" || { echo "$output"; return 1; }
        assert_output_contains "$output" "Audit: 2 hooks, 0 MCPs, 0 perm rules, 0 env vars in settings.json" \
            "$case_name: the audit counts the two hooks" || { echo "$output"; return 1; }
        assert_output_contains "$output" "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)" \
            "$case_name: autosave's registration is found" || { echo "$output"; return 1; }
        # No statusLine in the fixture is always a WARN, so the summary is
        # the warnings line.
        assert_eq "0" "$rc" "$case_name: doctor's exit status" || { echo "$output"; return 1; }
        assert_output_contains "$(tail -n 1 <<< "$output")" "^Complete with [0-9]* warning(s)\.$" \
            "$case_name: doctor runs to its summary" || { echo "$output"; return 1; }
    done
}

# A jq run that fails on a settings file that parses is reported on the row
# that ran it, and doctor goes on to its summary. The fake jq fails every
# filter that reads the hook events and runs the real jq for the rest.
test_doctor_reports_a_failed_read_of_the_hook_events() {
    local fake_claude="$TEST_TMPDIR/claude-jqfail" fake_hooks="$TEST_TMPDIR/hooks-jqfail"
    local fake_bin="$TEST_TMPDIR/jqfail-bin" real_jq id="11111111-2222-3333-4444-555555555555" output
    real_jq=$(command -v jq)
    mkdir -p "$fake_claude" "$fake_hooks" "$fake_bin"
    : > "$fake_hooks/session-start.sh"
    chmod +x "$fake_hooks/session-start.sh"
    jq -n --arg start "$fake_hooks/session-start.sh" \
        '{hooks: {SessionStart: [{hooks: [{type: "command", command: $start}]}]}}' > "$fake_claude/settings.json"
    printf '#!/bin/sh\ncase "$*" in *.hooks*) echo "jq: error: injected" >&2; exit 5 ;; esac\nexec "%s" "$@"\n' \
        "$real_jq" > "$fake_bin/jq"
    chmod +x "$fake_bin/jq"
    output=$(PATH="$fake_bin:$PATH" CLAUDE_CODE_SESSION_ID="$id" CS_CLAUDE_DIR="$fake_claude" \
        CS_HOOKS_DIR="$fake_hooks" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Settings: $fake_claude/settings.json is valid JSON" \
        "positive control: the parse check runs the real jq" || { echo "$output"; return 1; }
    assert_output_contains "$output" "Hooks: cannot read the hook events in $fake_claude/settings.json; registration unknown" \
        "the registration row names the failed read" || { echo "$output"; return 1; }
    assert_output_contains "$output" "Hook paths: cannot read the hook events in $fake_claude/settings.json" \
        "the hook paths row names the failed read" || { echo "$output"; return 1; }
    assert_output_contains "$output" "Audit: cannot count the hooks, MCPs, permission rules and env vars in $fake_claude/settings.json" \
        "the audit row names the failed read" || { echo "$output"; return 1; }
    assert_output_contains "$output" "Shadow ref: cannot read the PostToolUse hooks in $fake_claude/settings.json; autosave's registration unknown" \
        "the shadow ref row names the failed read" || { echo "$output"; return 1; }
    assert_output_contains "$(tail -n 1 <<< "$output")" "^Failed: [0-9]*  Warnings: [0-9]*$" \
        "doctor runs to its summary" || { echo "$output"; return 1; }
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

# The bar draws square ends until this machine answers the caps question, so
# doctor says which state it is in and how to answer.
test_doctor_statusline_caps_row_names_the_answer_or_the_ask() {
    local fake_claude="$TEST_TMPDIR/sl-claude-caps"
    local fake_bin="$TEST_TMPDIR/sl-bin-caps"
    local xdg="$TEST_TMPDIR/xdg-caps"
    mkdir -p "$fake_claude" "$fake_bin" "$xdg/cs"
    printf '#!/bin/sh\n' > "$fake_bin/cs-statusline"
    chmod +x "$fake_bin/cs-statusline"
    printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$fake_bin/cs-statusline" > "$fake_claude/settings.json"
    local output
    output=$(XDG_CONFIG_HOME="$xdg" CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "cs -statusline caps ask" "unanswered: doctor names the ask" || return 1
    printf 'on\n' > "$xdg/cs/statusline-caps"
    output=$(XDG_CONFIG_HOME="$xdg" CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "caps: rounded" "answered on: doctor says rounded" || return 1
}

# One row for cs's Ctrl+X bindings: the installer's recorded answer
# and what keybindings.json holds. A healthy state is OK; a binding the user
# holds on cs's key or on its ctrl+x prefix, keys an older cs bound that the
# next update replaces or moves, or a file Claude Code cannot read, is a WARN.
test_doctor_rotate_wrap_keys_row_names_the_state() {
    local cfg="$TEST_TMPDIR/ok-cfg" xdg="$TEST_TMPDIR/ok-xdg" output kb
    kb="$cfg/keybindings.json"
    mkdir -p "$cfg" "$xdg/cs"
    _ok_doctor() { CLAUDE_CONFIG_DIR="$cfg" XDG_CONFIG_HOME="$xdg" "$CS_BIN" -doctor 2>&1 || true; }

    output=$(_ok_doctor)
    assert_output_contains "$output" "OK.*Rotate/wrap keys: not asked (run cs -update in a terminal to be asked)" \
        "no answer: not asked" || return 1

    printf 'no\n' > "$xdg/cs/option-keys"
    output=$(_ok_doctor)
    assert_output_contains "$output" "OK.*Rotate/wrap keys: declined" "answered no: declined" || return 1

    printf 'yes\n' > "$xdg/cs/option-keys"
    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "OK.*Rotate/wrap keys: bound (Ctrl+X R runs /rotate, Ctrl+X W runs /wrap, Ctrl+X 1 and Ctrl+X 2 press the cs band)" \
        "every key holds cs's values in its context: bound" || return 1

    printf '%s\n' '{"bindings":[{"context":"Global","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap","ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x r is bound outside the Chat context in $kb (run cs -update to move it)" \
        "a command key an earlier cs put in the Global block: the next update moves it" || return 1
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x w is bound outside the Chat context in $kb (run cs -update to move it)" \
        "both command keys are named" || return 1
    assert_output_not_contains "$output" "Rotate/wrap keys: bound" "a file with a misplaced key is not reported bound" || return 1

    # The same file under a no, and under no answer: the installer touches
    # the file only on a recorded yes, so the advice is to move the key by
    # hand, and the row is still a WARN, never the OK of a declined machine.
    printf 'no\n' > "$xdg/cs/option-keys"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x r is bound outside the Chat context in $kb (move it into a block with \"context\": \"Chat\")" \
        "answered no: the misplaced key is still named, with the move to make by hand" || return 1
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x w is bound outside the Chat context in $kb (move it into a block with \"context\": \"Chat\")" \
        "answered no: both command keys are named" || return 1
    assert_output_not_contains "$output" "OK.*Rotate/wrap keys" "answered no: a misplaced key is no OK row" || return 1
    rm "$xdg/cs/option-keys"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x r is bound outside the Chat context in $kb (move it into a block with \"context\": \"Chat\")" \
        "not asked: the misplaced key is still named, with the move to make by hand" || return 1
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x w is bound outside the Chat context in $kb (move it into a block with \"context\": \"Chat\")" \
        "not asked: both command keys are named" || return 1
    assert_output_not_contains "$output" "OK.*Rotate/wrap keys" "not asked: a misplaced key is no OK row" || return 1
    printf 'yes\n' > "$xdg/cs/option-keys"

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x 1 not bound (run cs -update to bind it)" \
        "the chords an earlier cs bound, without the band's: the next update binds them" || return 1

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"chat:submit","ctrl+x w":"command:wrap"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: conflict on ctrl+x r (bound to chat:submit in $kb)" \
        "a user binding on ctrl+x r: conflict" || return 1

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x":"chat:externalEditor"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: conflict on ctrl+x w (ctrl+x is bound to chat:externalEditor in $kb)" \
        "a user binding on the bare prefix: conflict" || return 1

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x":""}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: conflict on ctrl+x r (ctrl+x is bound to \"\" in $kb)" \
        "an empty action on the prefix is named as JSON" || return 1

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 1":"strip:jump1","ctrl+x 2":"strip:jump2","alt+1":"command:rotate","alt+2":"command:wrap"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: alt+1, alt+2 still hold cs's earlier bindings in $kb (run cs -update to remove them)" \
        "chords bound beside cs's alt keys: the alt keys are named" || return 1

    printf '%s\n' '{"bindings":[{"context":"Global","bindings":{"alt+1":"command:rotate","alt+2":"command:wrap"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: ctrl+x r not bound (run cs -update to bind it)" \
        "an older cs's alt+1/alt+2: the next update binds the chords" || return 1

    printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+x 1":"app:redraw","ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}},{"context":"Global","bindings":{"ctrl+x 2":"strip:jump2","alt+1":"command:rotate","alt+2":"command:wrap"}}]}' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: conflict on ctrl+x 1 (bound to app:redraw in $kb)" \
        "a user binding on a band chord: conflict" || return 1
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: alt+1, alt+2 still hold cs's earlier bindings in $kb (run cs -update to remove them)" \
        "with Ctrl+X R and W bound, cs's alt keys are named even beside a band-chord conflict" || return 1

    printf '%s\n' '{"bindings": [' > "$kb"
    output=$(_ok_doctor)
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: $kb is unparseable" "bad JSON: unparseable" || return 1
}

# The cs mod is an opt-in the user links under ~/.claude/skills. Doctor
# says nothing when it is absent, and once present it reports the mod RUNNING
# (a heartbeat the mod writes on session.start), never mere presence: the
# loader is flag-gated, and a managed machine can load a mod and never run it.
test_doctor_rotate_mod_row_observes_execution_not_presence() {
    local fake_claude="$TEST_TMPDIR/claude-mod"
    mkdir -p "$fake_claude"
    echo '{}' > "$fake_claude/settings.json"
    local output
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "cs mod:" "absent opt-in: nothing said" || return 1
    mkdir -p "$fake_claude/skills/cs/hooks"
    rm -f "$CLAUDE_SESSION_META_DIR/local/cs.heartbeat"
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "cs mod: installed but has not run" "installed, never ran: WARN" || return 1
    assert_output_contains "$output" "CS_NO_FUNCTION_HOOKS" "and names the opt-out that withholds the loader flag" || return 1
    echo "$output" | grep "cs mod:" | grep -q "WARN" || { echo "  FAIL: never-ran must be a WARN"; return 1; }
    printf '2026-09-15T05:00:00.000Z\n' > "$CLAUDE_SESSION_META_DIR/local/cs.heartbeat"
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "cs mod: last ran 2026-09-15T05:00:00.000Z" "heartbeat: OK with the stamp" || return 1
    echo "$output" | grep "cs mod:" | grep -q "OK" || { echo "  FAIL: a heartbeat is an OK row"; return 1; }
    # No session selected: the heartbeat is per session, so there is nothing to
    # judge and the row must not warn about a session that was never named.
    output=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_NAME \
        CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "cs mod:" "linked but no session: nothing said" || return 1
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

# A foreign status line can chain to cs-statusline (a bridge that runs the
# original), so inside a session the evidence decides: a context-pct written
# within the heartbeat window means the gates are fed, whatever the command.
test_doctor_statusline_judges_a_foreign_command_by_a_fresh_context_pct() {
    local fake_claude="$TEST_TMPDIR/sl-claude-bridge"
    local cmd="$TEST_TMPDIR/bridge/statusline-bridge.sh"
    local pct="$CLAUDE_SESSION_META_DIR/local/context-pct"
    mkdir -p "$fake_claude" "$CLAUDE_SESSION_META_DIR/local"
    printf '{"statusLine":{"command":"%s"}}\n' "$cmd" > "$fake_claude/settings.json"
    printf '61\n' > "$pct"
    perl -e '$t = time - 60; utime $t, $t, $ARGV[0] or die' "$pct"
    local output line
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    line=$(printf '%s\n' "$output" | grep 'Statusline:' | sed "s/$(printf '\033')\\[[0-9;]*m//g")
    assert_eq "  [ OK ] Statusline: context-pct written 1 min ago through $cmd" "$line" \
        "a fresh context-pct under a foreign command is an OK naming its age" || return 1
    # Past the heartbeat window the evidence is gone: back to the hedged WARN.
    perl -e '$t = time - 1200; utime $t, $t, $ARGV[0] or die' "$pct"
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    line=$(printf '%s\n' "$output" | grep 'Statusline:' | sed "s/$(printf '\033')\\[[0-9;]*m//g")
    assert_eq "  [WARN] Statusline: using a non-cs status line ($cmd) — context-pct is never written, so the rotation nudge and the queue context breaker stay inert, unless it chains to cs-statusline" "$line" \
        "a stale context-pct leaves the hedged WARN" || return 1
    # A fresh but empty file (a teammate's statusline touches it without a
    # reading) feeds no gate: the hedged WARN again.
    : > "$pct"
    output=$(CS_CLAUDE_DIR="$fake_claude" "$CS_BIN" -doctor 2>&1) || true
    line=$(printf '%s\n' "$output" | grep 'Statusline:' | sed "s/$(printf '\033')\\[[0-9;]*m//g")
    assert_eq "  [WARN] Statusline: using a non-cs status line ($cmd) — context-pct is never written, so the rotation nudge and the queue context breaker stay inert, unless it chains to cs-statusline" "$line" \
        "a fresh context-pct holding no reading leaves the hedged WARN" || return 1
}

test_doctor_statusline_caps_follow_a_readable_bridge() {
    # shellcheck disable=SC2088  # the literal path is the value under test
    local home="$TEST_TMPDIR/bridge-home" cmd='~/bridge.sh --example'
    local state output line expected
    mkdir -p "$home/.claude" "$home/config/cs"
    for state in unrelated missing chains rounded; do
        # shellcheck disable=SC2088  # the literal path is the value under test
        cmd='~/bridge.sh --example'
        case "$state" in
            unrelated) printf '%s\n' '#!/bin/sh' 'printf bar' > "$home/bridge.sh" ;;
            missing)
                # shellcheck disable=SC2088  # the literal path is the value under test
                cmd='~/absent.sh --example'
                ;;
            chains) printf '%s\n' '#!/bin/sh' 'exec cs-statusline' > "$home/bridge.sh" ;;
            rounded) printf '%s\n' '#!/bin/sh' 'exec cs-statusline' > "$home/bridge.sh"
                printf '%s\n' on > "$home/config/cs/statusline-caps" ;;
        esac
        jq -n --arg cmd "$cmd" '{statusLine:{command:$cmd}}' > "$home/.claude/settings.json"
        output=$(env -u CLAUDE_SESSION_META_DIR -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_NAME \
            HOME="$home" XDG_CONFIG_HOME="$home/config" CS_CLAUDE_DIR="$home/.claude" \
            "$CS_BIN" -doctor 2> "$TEST_TMPDIR/doctor.stderr") || true
        line=$(printf '%s\n' "$output" | grep -E 'Statusline(:| caps:)' \
            | sed "s/$(printf '\033')\\[[0-9;]*m//g")
        case "$state" in
            unrelated|missing)
                expected="  [WARN] Statusline: using a non-cs status line ($cmd) — context-pct is never written, so the rotation nudge and the queue context breaker stay inert, unless it chains to cs-statusline"
                ;;
            chains)
                expected="  [ OK ] Statusline: $cmd chains to cs-statusline
  [WARN] Statusline caps: square until answered — run: cs -statusline caps ask"
                ;;
            rounded)
                expected="  [ OK ] Statusline: $cmd chains to cs-statusline
  [ OK ] Statusline caps: rounded (this machine's font has the Powerline caps)"
                ;;
        esac
        assert_eq "$expected" "$line" "$state bridge reports its status and caps accurately" || return 1
        assert_eq '' "$(cat "$TEST_TMPDIR/doctor.stderr")" "$state bridge produces no stderr" || return 1
    done
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

# A brief set aside with a stale seed is a second file nothing prunes.
test_doctor_warns_on_stale_spawn_brief() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    : > "$CS_SESSIONS_ROOT/.spawn/gone.seed.stale"
    : > "$CS_SESSIONS_ROOT/.spawn/gone.brief.md.stale"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "gone.brief.md.stale" \
        "doctor should name the aged-out brief beside its seed" || return 1
}

# A cs -spawn killed before it published leaves its dot-named staging file.
# No launch reads it and nothing else removes it, so the doctor names it.
test_doctor_warns_on_abandoned_spawn_staging() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'killed\n' > "$CS_SESSIONS_ROOT/.spawn/.gone.seed.Ab12Cd"
    touch -t 202401010000 "$CS_SESSIONS_ROOT/.spawn/.gone.seed.Ab12Cd"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" ".gone.seed.Ab12Cd" \
        "doctor should name the staging file an interrupted spawn left" || return 1
}

# An open killed outright (no trap runs) leaves the seed it claimed under
# .<name>.seed.claim.<pid>. The doctor names it once that pid is gone, and
# never a claim an open still waiting at the ask holds.
test_doctor_warns_on_a_claimed_seed_whose_open_is_gone() {
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    local dead
    sh -c 'exit 0' & dead=$!
    wait "$dead"
    printf 'claimed\n' > "$CS_SESSIONS_ROOT/.spawn/.gone.seed.claim.$dead"
    printf 'asking\n' > "$CS_SESSIONS_ROOT/.spawn/.live.seed.claim.$$"
    local output
    output=$(CS_TMUX_BIN="$(_doctor_tmux_fake '' '')" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" ".gone.seed.claim.$dead" \
        "doctor should name the seed a killed open claimed" || return 1
    assert_output_not_contains "$output" ".live.seed.claim.$$" \
        "doctor should leave a live open's claim alone" || return 1
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
run_test test_doctor_statusline_caps_follow_a_readable_bridge
run_test test_doctor_subcommand_exists
run_test test_doctor_runs_default_checks_from_session
run_test test_doctor_reports_pass_for_healthy_session
run_test test_doctor_warns_on_a_narrative_over_budget
run_test test_doctor_names_a_narrative_over_budget_as_a_plain_name
run_test test_doctor_reads_a_leading_zero_budget_as_decimal
run_test test_doctor_reports_ok_when_narratives_fit
run_test test_doctor_survives_an_unreadable_narrative
run_test test_doctor_fails_when_hook_not_executable
run_test test_doctor_exits_nonzero_on_failure
run_test test_doctor_completes_when_the_deploy_stamp_is_absent
run_test test_doctor_drift_ignores_a_checkout_that_did_not_produce_the_install
run_test test_doctor_warns_on_hook_drift
run_test test_doctor_warns_on_wrap_pass_drift
run_test test_doctor_drift_advice_follows_whose_the_deployed_copy_is
run_test test_doctor_warns_on_undeployed_hook
run_test test_doctor_drift_silent_when_in_sync
run_test test_doctor_warns_on_mod_drift
run_test test_doctor_warns_on_mod_tips_drift
run_test test_doctor_drift_skips_a_kept_out_mod
run_test test_doctor_drift_skipped_outside_checkout
run_test test_doctor_warns_on_command_drift
run_test test_doctor_warns_on_skill_script_drift
run_test test_doctor_warns_on_skill_drift
run_test test_doctor_tui_warns_when_a_rust_source_changed_after_the_build
run_test test_doctor_tui_warns_when_cargo_toml_changed_after_the_build
run_test test_doctor_tui_warns_when_cargo_lock_changed_after_the_build
run_test test_doctor_tui_ok_with_a_stray_file_under_src_newer_than_the_build
run_test test_doctor_warns_when_the_installed_tui_differs_from_the_build
run_test test_doctor_tui_ok_when_the_installed_picker_is_the_fresh_build
run_test test_doctor_tui_holds_the_picker_to_the_build_install_sh_ships
run_test test_doctor_tui_names_a_source_tree_it_cannot_read
run_test test_doctor_tui_reads_a_recorded_checkout_whose_path_holds_spaces
run_test test_doctor_tui_prints_a_control_character_in_the_recorded_path_as_a_question_mark
run_test test_doctor_tui_names_an_origin_record_of_more_than_one_line
run_test test_doctor_tui_reads_a_recorded_checkout_path_that_ends_in_a_slash
run_test test_doctor_tui_judges_the_recorded_checkout_not_the_one_it_runs_in
run_test test_doctor_tui_silent_for_a_release_picker
run_test test_doctor_tui_names_a_missing_origin_record
run_test test_doctor_tui_names_an_origin_record_it_does_not_understand
run_test test_doctor_tui_names_a_recorded_checkout_without_its_tui
run_test test_doctor_tui_silent_for_a_picker_that_is_a_symlink
run_test test_doctor_tui_silent_without_a_build_in_the_checkout
run_test test_doctor_tui_silent_when_no_picker_is_installed
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
run_test test_doctor_reads_past_hook_events_and_entries_that_are_not_objects
run_test test_doctor_reports_a_failed_read_of_the_hook_events
run_test test_doctor_statusline_ok_when_registered_and_executable
run_test test_doctor_statusline_fails_when_binary_missing
run_test test_doctor_statusline_caps_row_names_the_answer_or_the_ask
run_test test_doctor_rotate_wrap_keys_row_names_the_state
run_test test_doctor_rotate_mod_row_observes_execution_not_presence
run_test test_doctor_statusline_no_fail_when_not_registered
run_test test_doctor_statusline_names_context_gating_when_absent
run_test test_doctor_statusline_names_context_gating_for_foreign_statusline
run_test test_doctor_statusline_judges_a_foreign_command_by_a_fresh_context_pct
run_test test_doctor_subagent_statusline_ok_when_registered_and_executable
run_test test_doctor_subagent_statusline_fails_when_binary_missing
run_test test_doctor_subagent_statusline_no_fail_when_not_registered
run_test test_doctor_runs_token_cost_check
run_test test_doctor_token_cost_sums_jsonl
run_test test_doctor_token_cost_handles_no_transcripts
run_test test_doctor_warns_on_stale_spawn_seeds
run_test test_doctor_warns_on_stale_spawn_brief
run_test test_doctor_completes_after_spawn_warning
run_test test_doctor_warns_on_abandoned_spawn_staging
run_test test_doctor_warns_on_a_claimed_seed_whose_open_is_gone
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

# Doctor reads neither settings.json nor keybindings.json when it is not a
# regular file (here a FIFO each): reading one waits for a writer that never
# comes. Each gets a row, as a file it cannot parse does, and doctor finishes.
test_doctor_names_settings_and_keybindings_that_are_not_regular_files() {
    local cfg="$TEST_TMPDIR/claude-fifo" xdg="$TEST_TMPDIR/xdg-fifo" output rc=0
    mkdir -p "$cfg" "$xdg"
    mkfifo "$cfg/settings.json" "$cfg/keybindings.json"
    _run_bounded 60 env CS_CLAUDE_DIR="$cfg" CLAUDE_CONFIG_DIR="$cfg" XDG_CONFIG_HOME="$xdg" "$CS_BIN" -doctor \
        > "$TEST_TMPDIR/doctor-fifo.out" 2>&1 || rc=$?
    output=$(cat "$TEST_TMPDIR/doctor-fifo.out")
    assert_eq "1" "$rc" "doctor exit status (142: still running after 60 s)" || { echo "$output"; return 1; }
    assert_output_contains "$output" "FAIL.*Settings: $cfg/settings\.json is not a regular file, so cs did not read it$" \
        "the settings.json fifo gets a row" || { echo "$output"; return 1; }
    assert_output_contains "$output" "WARN.*Rotate/wrap keys: $cfg/keybindings\.json is unparseable (not JSON with a \"bindings\" array)$" \
        "the keybindings.json fifo gets a row" || { echo "$output"; return 1; }
    [ -p "$cfg/settings.json" ] && [ -p "$cfg/keybindings.json" ] \
        || { echo "  FAIL: the fifos are not left as they were"; return 1; }
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

# Seed settings.json with one PostToolUse registration, the way install.sh
# writes the autosave hook: matcher "Write|Edit", command ending in
# autosave-commits.sh. yes|no picks that command or an unrelated one; a second
# and third argument override the command and matcher.
_seed_autosave_registration() {  # yes|no [command] [matcher]
    local cmd="/opt/cs/hooks/other.sh" matcher="${3:-Write|Edit}"
    [ "$1" = yes ] && cmd="/opt/cs/hooks/autosave-commits.sh"
    [ -n "${2:-}" ] && cmd="$2"
    cat > "$CS_CLAUDE_DIR/settings.json" << EOF
{"hooks": {"PostToolUse": [{"matcher": "$matcher", "hooks": [{"type": "command", "command": "$cmd"}]}]}}
EOF
}

# Give conversation <uuid> an autosave ref, as the hook would.
_seed_shadow_ref() {  # uuid
    local snap
    snap=$(git -C "$CLAUDE_SESSION_DIR" commit-tree "HEAD^{tree}" -m snapshot) || return 1
    git -C "$CLAUDE_SESSION_DIR" update-ref "refs/worktree/cs/session/$1" "$snap"
}

test_doctor_checks_the_callers_shadow_ref_not_the_recorded_lead() {
    # .cs/local/state holds ONE id per checkout, rebound by the lead only, while
    # the autosave hook keys each conversation's ref on its own session_id. A
    # teammate running doctor must be judged by its own ref: the lead's being
    # present says nothing about the teammate's.
    local lead="11111111-2222-3333-4444-555555555555"
    local mate="66666666-7777-8888-9999-000000000000"
    printf 'claude_session_id: %s\n' "$lead" > "$CLAUDE_SESSION_META_DIR/local/state"
    _seed_shadow_ref "$lead" || { echo "  FAIL: fixture ref"; return 1; }
    _seed_autosave_registration yes

    local output
    output=$(CLAUDE_CODE_SESSION_ID="$mate" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "refs/worktree/cs/session/$lead present" \
        "the lead's ref must not stand in for the caller's" || return 1
    assert_output_contains "$output" "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)" \
        "the caller has no ref of its own" || return 1
}

test_doctor_falls_back_to_the_recorded_id_not_the_launch_id() {
    # Without $CLAUDE_CODE_SESSION_ID (doctor run from a plain shell in the
    # session), the recorded id is the best answer. CS_CLAUDE_SESSION_ID is the
    # LAUNCH id and goes stale after the first /clear, whose SessionEnd has
    # already deleted that conversation's ref.
    local live="11111111-2222-3333-4444-555555555555"
    local launch="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    printf 'claude_session_id: %s\n' "$live" > "$CLAUDE_SESSION_META_DIR/local/state"
    _seed_shadow_ref "$live" || { echo "  FAIL: fixture ref"; return 1; }

    local output
    output=$(env -u CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID="$launch" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "refs/worktree/cs/session/$live present" \
        "doctor must check the recorded conversation's ref" || return 1
    assert_output_not_contains "$output" "$launch" \
        "the stale launch id must not be checked" || return 1
}

test_doctor_does_not_warn_before_the_first_autosave() {
    # Autosave fires on Edit/Write only, and SessionEnd deletes a conversation's
    # ref on a clean /clear. A dirty tree with no ref for the live conversation
    # is the normal state before its first Edit/Write (work done through Bash,
    # or carried over from before the /clear), not a broken hook. Untracked
    # work included: the fixture holds only an untracked file.
    echo "unsaved work" > "$CLAUDE_SESSION_DIR/scratch-note.txt"
    local others
    others=$(git -C "$CLAUDE_SESSION_DIR" ls-files --others --exclude-standard 2>/dev/null || true)
    [ -n "$others" ] || { echo "  FAIL: fixture produced no untracked files"; return 1; }
    _seed_autosave_registration yes

    local output
    output=$(CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "autosave may be broken" \
        "no snapshot yet is not a broken autosave" || return 1
    assert_output_contains "$output" "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)" \
        "doctor must say why there is no ref" || return 1
}

test_doctor_warns_when_the_autosave_hook_is_not_registered() {
    # With no ref, the one thing doctor can still check is that the hook that
    # would write it is registered. The file and registration checks enumerate
    # what IS deployed or registered, so a hook missing from both is invisible
    # to them.
    _seed_autosave_registration no

    local output
    output=$(CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Shadow ref: autosave-commits.sh is not registered for PostToolUse on Write and Edit in $CS_CLAUDE_DIR/settings.json; edits are not snapshotted" \
        "an unregistered autosave hook must warn" || return 1
    assert_output_not_contains "$output" "no snapshot for this conversation yet" \
        "an unregistered hook is not the normal no-snapshot-yet state" || return 1
}

test_doctor_does_not_accept_an_autosave_lookalike_registration() {
    # A registration only counts if it would run the hook on Write and Edit:
    # the hook exits at once for any other tool, so a Read-only matcher never
    # snapshots, and a different script whose name merely ends the same way is
    # not the hook.
    local id="11111111-2222-3333-4444-555555555555" output
    _seed_autosave_registration yes "" "Read"
    output=$(CLAUDE_CODE_SESSION_ID="$id" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "autosave-commits.sh is not registered for PostToolUse on Write and Edit" \
        "a Read-only matcher never fires on an edit" || return 1

    _seed_autosave_registration yes "/opt/cs/hooks/not-autosave-commits.sh"
    output=$(CLAUDE_CODE_SESSION_ID="$id" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "autosave-commits.sh is not registered for PostToolUse on Write and Edit" \
        "a lookalike script name is not the hook" || return 1

    # Positive control: the installer's own form is accepted.
    _seed_autosave_registration yes "~/.claude/hooks/cs/autosave-commits.sh"
    output=$(CLAUDE_CODE_SESSION_ID="$id" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)" \
        "the installer's registration must be accepted" || return 1
}

test_doctor_reads_the_autosave_registration_past_an_invalid_matcher() {
    # Another tool's entry with a matcher that is not a valid regex cannot fire,
    # but it says nothing about the entries after it: the autosave registration
    # that follows still counts.
    local id="11111111-2222-3333-4444-555555555555" output
    cat > "$CS_CLAUDE_DIR/settings.json" << 'EOF'
{"hooks": {"PostToolUse": [
  {"matcher": "(", "hooks": [{"type": "command", "command": "/opt/other/hook.sh"}]},
  {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "~/.claude/hooks/cs/autosave-commits.sh"}]}
]}}
EOF
    output=$(CLAUDE_CODE_SESSION_ID="$id" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Shadow ref: no snapshot for this conversation yet (autosave runs on Edit/Write)" \
        "a registration after an invalid matcher must still be read" || return 1
}
run_test test_doctor_fails_on_unparseable_settings
run_test test_doctor_names_settings_and_keybindings_that_are_not_regular_files
run_test test_doctor_does_not_accept_a_hook_named_only_in_a_permission_rule
run_test test_doctor_checks_the_callers_shadow_ref_not_the_recorded_lead
run_test test_doctor_falls_back_to_the_recorded_id_not_the_launch_id
run_test test_doctor_does_not_warn_before_the_first_autosave
run_test test_doctor_warns_when_the_autosave_hook_is_not_registered
run_test test_doctor_does_not_accept_an_autosave_lookalike_registration
run_test test_doctor_reads_the_autosave_registration_past_an_invalid_matcher
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
    [ "$rc" = "2" ] && return 77
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


# Hooks install silently and can change what the model sees; a terminal title
# needs opt-in but a context injection does not. The authority section makes
# every such injection visible with the switch that turns it off.
test_doctor_lists_every_context_injecting_hook_with_its_switch() {
    local output
    output=$(env -u CS_NO_FUNCTION_HOOKS CS_CLAUDE_DIR="$TEST_TMPDIR/claude-auth" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Authority" "Doctor should have an authority section" || return 1
    assert_output_contains "$output" "scope-prompt" "Should list the grounding hook" || return 1
    assert_output_contains "$output" "CS_SCOPE_DISABLE" "Should name the grounding off-switch" || return 1
    assert_output_contains "$output" "CS_CLARIFY_DISABLE" "Should name the clarify off-switch" || return 1
    assert_output_contains "$output" "CS_DATE_REMINDER_DISABLE" "Should name the date reminder off-switch" || return 1
    assert_output_contains "$output" "CS_REWRITE_DISABLE" "Should name the rewriter off-switch" || return 1
    assert_output_contains "$output" ".cs/local/disabled" "Should name the hooks' off-switch" || return 1
    # The four turn-end notices ride stop-notices.sh; each row names it.
    local label row hook
    for label in "narrative" "council nudge" "ctx warning" "rotate nudge"; do
        row=$(grep -E "^ +(on|off) +$label +[^ ]+ +off: " <<< "$output" | head -1)
        hook=$(awk '{print $1}' <<< "${row#*"$label"}")
        assert_eq "stop-notices" "$hook" "the $label row names the hook that carries it" || return 1
    done
}

_doctor_diagrams_row() {
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    printf '%s\n' "$output" | awk '$2 == "diagrams" {$1=$1; print}'
}

test_doctor_reports_the_diagram_instruction_as_on() {
    cat > "$CLAUDE_SESSION_DIR/CLAUDE.local.md" << 'EOF'
<!-- cs:mermaid-diagrams -->
## Diagrams

Mermaid flowchart fences draw in this terminal.
EOF
    local row
    touch "$CLAUDE_SESSION_META_DIR/local/disabled"
    row=$(CS_NO_FUNCTION_HOOKS=1 _doctor_diagrams_row)
    assert_eq "on diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "the file's instruction stays on when hooks and drawing are disabled" || return 1
    row=$(cd "$CLAUDE_SESSION_DIR" && unset CLAUDE_SESSION_DIR && _doctor_diagrams_row)
    assert_eq "on diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "doctor finds the diagram instruction from the session working directory" || return 1
}

test_doctor_reports_the_diagram_tombstone_as_off() {
    local row
    unset CS_NO_FUNCTION_HOOKS
    # shellcheck source=lib/35-claudemd.sh
    source "$SCRIPT_DIR/../lib/35-claudemd.sh"
    _emit_session_claude_md | sed '/^## Diagrams$/d; /^Mermaid flowchart fences /d; /^To opt out,.*cs:mermaid-diagrams/d' \
        > "$CLAUDE_SESSION_DIR/CLAUDE.local.md"
    row=$(_doctor_diagrams_row)
    assert_eq "off diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "the diagram tombstone has no instruction" || return 1
    cat >> "$CLAUDE_SESSION_DIR/CLAUDE.local.md" << 'EOF'
## Additional instructions

Keep a record of the session outcome.
EOF
    row=$(_doctor_diagrams_row)
    assert_eq "off diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "an unmarked heading ends the diagram section" || return 1
    printf '<!-- cs:mermaid-diagrams -->\n\n' > "$CLAUDE_SESSION_DIR/CLAUDE.local.md"
    cat >> "$CLAUDE_SESSION_DIR/CLAUDE.local.md" << 'EOF'
## Diagrams

<!-- cs:session-commits -->
## Committing session files

Commit session files when wrapping up.
EOF
    row=$(_doctor_diagrams_row)
    assert_eq "off diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "a heading and another managed section do not supply diagram prose" || return 1
    printf 'Unrelated session instructions.\n' > "$CLAUDE_SESSION_DIR/CLAUDE.local.md"
    row=$(_doctor_diagrams_row)
    assert_eq "off diagrams CLAUDE.local.md off: delete the prose under cs:mermaid-diagrams" "$row" \
        "a file without the diagram sentinel has no diagram instruction" || return 1
}

test_doctor_authority_section_shows_a_disabled_injection_as_off() {
    local output
    output=$(CS_SCOPE_DISABLE=1 CS_CLAUDE_DIR="$TEST_TMPDIR/claude-auth" "$CS_BIN" -doctor 2>&1) || true
    # The line for grounding must read as off when its switch is set, or the
    # section reports configuration rather than what is actually happening.
    local line
    line=$(printf '%s\n' "$output" | grep -i "grounding" | head -1)
    [ -n "$line" ] || { echo "no grounding line in authority section"; return 1; }
    # The state is the FIRST field. Every row also carries "off:" as the label
    # for its switch, so a substring match on "off" passes with the state
    # hardcoded to on — which is exactly what this test exists to catch.
    local state
    state=$(printf '%s\n' "$line" | awk '{print $1}')
    [ "$state" = "off" ] || { echo "grounding state is '$state', expected off: $line"; return 1; }
}

# The hooks read their switch as `= "1"`, so an exported 0 leaves the
# injection on. The section must say on, or it reports the variable's
# presence rather than what the hook does with it.
test_doctor_authority_section_shows_a_zero_switch_as_on() {
    local output line state
    output=$(CS_SCOPE_DISABLE=0 CS_CLAUDE_DIR="$TEST_TMPDIR/claude-auth" "$CS_BIN" -doctor 2>&1) || true
    line=$(printf '%s\n' "$output" | grep -i "grounding" | head -1)
    [ -n "$line" ] || { echo "no grounding line in authority section"; return 1; }
    state=$(printf '%s\n' "$line" | awk '{print $1}')
    [ "$state" = "on" ] || { echo "grounding state is '$state' with the switch at 0, expected on: $line"; return 1; }
}

run_test test_doctor_lists_every_context_injecting_hook_with_its_switch
run_test test_doctor_reports_the_diagram_instruction_as_on
run_test test_doctor_reports_the_diagram_tombstone_as_off
run_test test_doctor_authority_section_shows_a_zero_switch_as_on
run_test test_doctor_authority_section_shows_a_disabled_injection_as_off


# The merge driver is per-clone config that setup_merge_attributes writes with
# `|| true`, so a clone where that write failed keeps `.gitattributes` saying
# merge=ours with nothing behind it — and MEMORY.md text-merges on the next
# pull. cs cannot see a pull it was not part of, but it can name the gap.
test_doctor_warns_when_the_session_clone_lacks_the_merge_driver() {
    local sess="$TEST_TMPDIR/sess-nodriver"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    printf '.cs/memory/MEMORY.md merge=ours\n' > "$sess/.gitattributes"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-nd" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "merge.ours.driver" \
        "Doctor should name the missing merge driver" || return 1
    assert_output_contains "$output" "WARN" "A missing driver is a warning" || return 1
}

test_doctor_is_quiet_when_the_session_clone_has_the_merge_driver() {
    local sess="$TEST_TMPDIR/sess-driver"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    git -C "$sess" config merge.ours.driver true
    printf '.cs/memory/MEMORY.md merge=ours\n' > "$sess/.gitattributes"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-d" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "merge.ours.driver not set" \
        "A clone with the driver should not be warned about" || return 1
}

run_test test_doctor_warns_when_the_session_clone_lacks_the_merge_driver
run_test test_doctor_is_quiet_when_the_session_clone_has_the_merge_driver


# Stamp the setup session the way a clean open would for alice: the merge
# driver set, the probe files it has (CLAUDE.md, .cs/README.md) at a fixed old
# time, the stamp a year later. Prints the cs version the stamp names.
_doctor_stamp_session() {
    local dir="$CLAUDE_SESSION_DIR" version
    version=$("$CS_BIN" -version)
    version=${version#cs }
    git -C "$dir" config merge.ours.driver true
    touch -t 202401010000 "$dir/CLAUDE.md" "$dir/.cs/README.md"
    printf '%s\talice\t0\nCLAUDE.md\t.cs/README.md\n' "$version" > "$dir/.cs/local/migrated"
    touch -t 202501010000 "$dir/.cs/local/migrated"
    echo "$version"
}

test_doctor_reports_a_current_migration_stamp() {
    local version output
    version=$(_doctor_stamp_session)
    output=$(CS_ACTOR=alice "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Migration stamp: current for cs $version; opens skip the one-time migration checks. To force them: rm .cs/local/migrated" \
        "a fresh stamp reads as current and names the reset" || return 1
}

test_doctor_reports_a_stale_migration_stamp() {
    local output
    _doctor_stamp_session > /dev/null
    touch -t 202601010000 "$CLAUDE_SESSION_DIR/CLAUDE.md"
    output=$(CS_ACTOR=alice "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Migration stamp: stale (CLAUDE.md changed after the stamp); the next open runs the full migration and restamps. Reset by hand: rm .cs/local/migrated" \
        "a stale stamp names what changed and the reset" || return 1
}

# A worktree open never migrates, so it never stamps: its row would say
# "stale (no stamp)" forever. The worktree open knows itself by task_branch,
# which a worktree whose state lost cs_base still carries.
test_doctor_skips_the_migration_stamp_in_a_worktree_known_by_its_task_branch() {
    local output
    printf 'task_branch: feature/fix-auth\n' >> "$CLAUDE_SESSION_DIR/.cs/local/state"
    output=$(CS_ACTOR=alice "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "Migration stamp:" \
        "a worktree has no migration stamp row" || return 1
}

run_test test_doctor_reports_a_current_migration_stamp
run_test test_doctor_reports_a_stale_migration_stamp
run_test test_doctor_skips_the_migration_stamp_in_a_worktree_known_by_its_task_branch


# `cs <base> -integrate-feature` takes <git-dir>/cs/integrate.lock and the
# autosave hook skips its snapshot while it exists. A lock left behind by a
# killed integrate would silence autosave forever, with nothing to say why.
test_doctor_names_a_lock_with_no_recorded_pid_as_unknown() {
    local sess="$TEST_TMPDIR/sess-stalelock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-sl" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "$sess/.git/cs/integrate.lock" \
        "Doctor should name the lock by path" || return 1
    assert_output_contains "$output" "no holder pid" \
        "a lock with no pid is reported as one cs cannot judge" || return 1
    assert_output_not_contains "$output" "rm -r" \
        "and carries no removal advice: the autosave hook takes this same lock and records no pid, and removing it does not stop its worker" || return 1
    assert_output_contains "$output" "WARN" "still a warning" || return 1
}

# The integrate records its pid inside the lock, and that pid is the only
# liveness evidence doctor consults: a `pgrep` for any integrate on the machine
# reported a fixture's orphan lock as held whenever another suite's integrate
# happened to be running.
test_doctor_reports_a_lock_whose_pid_is_alive_as_held() {
    local sess="$TEST_TMPDIR/sess-livelock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    # This shell outlives the doctor run, so its pid is a live holder.
    echo "$$" > "$sess/.git/cs/integrate.lock/pid"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-ll" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "integrate.lock held by a running integrate (pid $$)" \
        "a lock whose recorded pid is alive is held" || return 1
    assert_output_not_contains "$output" "rm -r" "no removal advice for a held lock" || return 1
}

# A holder doctor cannot signal is still a holder: pid 1 exists on every
# machine and belongs to another user, so `kill -0` answers EPERM, and EPERM
# is a process that exists.
test_doctor_reports_a_lock_held_by_another_users_process_as_held() {
    # The fixture is pid 1, which exists everywhere and belongs to root. As
    # root, though, `kill -0 1` SUCCEEDS, and doctor then answers through the
    # same "held" wording by the ordinary arm -- green without ever reaching
    # the EPERM branch this test exists for. So the fixture is checked first,
    # and a run that cannot produce EPERM skips loudly instead of passing.
    local err
    if err=$(env LC_ALL=C kill -0 1 2>&1); then
        echo "    SKIP: pid 1 is signalable here, so EPERM cannot be exercised"
        return 77
    fi
    case "$err" in
        *"Operation not permitted"*) ;;
        *) echo "    SKIP: pid 1 answered '${err##*: }', not EPERM"; return 77 ;;
    esac
    local sess="$TEST_TMPDIR/sess-foreignlock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    echo 1 > "$sess/.git/cs/integrate.lock/pid"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-fl" "$CS_BIN" -doctor 2>&1) || true
    # The suffix is what separates this branch from the plain success arm: a
    # test that asserted only the shared "held" text would pass either way.
    assert_output_contains "$output" "signalling it is not permitted here" \
        "a holder doctor may not signal is named as such" || return 1
    assert_output_contains "$output" "integrate.lock held by a running integrate (pid 1;" \
        "a live process doctor cannot signal is still a holder" || return 1
    assert_output_not_contains "$output" "rm -r" "no removal advice for a held lock" || return 1
}

# A pid past the pid range is one the kernel can never answer about, so the
# lock is neither held nor gone; doctor must say so and must not tell the
# user to remove the lock. macOS's /bin/kill rejects such a number before the
# syscall; procps kill on Linux truncates it to a pid_t and asks the kernel
# about another process: 999999999999 answers for a pid that is gone, and
# 4294967297 for pid 1, which is held.
test_doctor_does_not_call_a_lock_stale_when_the_pid_cannot_be_checked() {
    local pid sess output
    for pid in 999999999999 4294967297; do
        sess="$TEST_TMPDIR/sess-nocheck-$pid"
        mkdir -p "$sess/.cs/memory"
        git -C "$sess" init -q
        mkdir -p "$sess/.git/cs/integrate.lock"
        echo "$pid" > "$sess/.git/cs/integrate.lock/pid"
        output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
            CS_CLAUDE_DIR="$TEST_TMPDIR/claude-nc" "$CS_BIN" -doctor 2>&1) || true
        assert_output_contains "$output" "cannot tell whether it is running" \
            "a check with no answer is reported as unknown (pid $pid)" || return 1
        assert_output_not_contains "$output" "rm -r" "no removal advice on an unknown (pid $pid)" || return 1
        assert_output_not_contains "$output" "held by a running integrate" "and not held either (pid $pid)" || return 1
    done
}

test_doctor_names_a_lock_whose_pid_is_dead_as_stale() {
    local sess="$TEST_TMPDIR/sess-deadlock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    # A pid that has exited and been reaped: nothing can be running as it.
    sh -c 'exit 0' & local dead=$!; wait "$dead"
    echo "$dead" > "$sess/.git/cs/integrate.lock/pid"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-dl" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "cannot see" \
        "a pid this process cannot see is reported as that, not as proof the lock is dead" || return 1
    assert_output_contains "$output" "nothing is using this checkout" \
        "removal is conditioned on the person confirming it" || return 1
    assert_output_contains "$output" "rm -r" "and the command is still named" || return 1
}

# `kill -0 0` signals the caller's own process group and always succeeds, so
# a pid file reading 0 would report a holder that can never exit. No integrate
# records 0; a file that says so is unreadable, not a holder.
test_doctor_does_not_treat_pid_zero_as_a_holder() {
    local sess="$TEST_TMPDIR/sess-zerolock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    echo 0 > "$sess/.git/cs/integrate.lock/pid"
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-zl" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "held by a running integrate" \
        "pid 0 is not a holder" || return 1
    assert_output_contains "$output" "integrate.lock" "the lock is still reported" || return 1
}

# The liveness check runs kill -0 in a command substitution, a forked copy of
# the shell, and a bash linked against libintl can die when it changes its own
# locale there. The trace shows every locale assignment the shell made during
# the whole doctor run; the C locale reaches kill as an argument of env. Each
# verdict stays exact under every bash: a live holder is held, a reaped pid is
# stale, and pid 1, which another user owns, is held through EPERM.
test_doctor_checks_the_lock_holder_without_the_shell_assigning_its_own_locale() {
    local sess="$TEST_TMPDIR/sess-tracelock" b pid want output own eperm=1 err
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    mkdir -p "$sess/.git/cs/integrate.lock"
    sh -c 'exit 0' & local dead=$!; wait "$dead"
    if err=$(env LC_ALL=C kill -0 1 2>&1); then eperm=""; fi
    case "$err" in *"Operation not permitted"*) ;; *) eperm="" ;; esac
    for b in $(every_bash); do
        for pid in "$$" "$dead" ${eperm:+1}; do
            case "$pid" in
                "$$")    want="integrate.lock held by a running integrate (pid $$)" ;;
                "$dead") want="integrate.lock records pid $dead, which this process cannot see" ;;
                *)       want="integrate.lock held by a running integrate (pid 1; signalling it is not permitted here" ;;
            esac
            echo "$pid" > "$sess/.git/cs/integrate.lock/pid"
            output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
                CS_CLAUDE_DIR="$TEST_TMPDIR/claude-tl" "$b" -x "$CS_BIN" -doctor 2>"$TEST_TMPDIR/trace") || true
            assert_output_contains "$output" "$want" "$b, pid $pid: the verdict" || return 1
            own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
            assert_eq "" "$own" "$b, pid $pid: doctor must not assign its own locale" || return 1
        done
    done
    [ -n "$eperm" ] || { echo "    SKIP (EPERM cell): pid 1 is signalable here"; return 77; }
}

test_doctor_is_silent_with_no_integrate_lock() {
    local sess="$TEST_TMPDIR/sess-nolock"
    mkdir -p "$sess/.cs/memory"
    git -C "$sess" init -q
    local output
    output=$(CLAUDE_SESSION_DIR="$sess" CLAUDE_SESSION_META_DIR="$sess/.cs" \
        CS_CLAUDE_DIR="$TEST_TMPDIR/claude-nl" "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$output" "integrate.lock" \
        "no lock, nothing to report" || return 1
}

run_test test_doctor_does_not_treat_pid_zero_as_a_holder
run_test test_doctor_names_a_lock_with_no_recorded_pid_as_unknown
run_test test_doctor_reports_a_lock_whose_pid_is_alive_as_held
run_test test_doctor_reports_a_lock_held_by_another_users_process_as_held
run_test test_doctor_does_not_call_a_lock_stale_when_the_pid_cannot_be_checked
run_test test_doctor_names_a_lock_whose_pid_is_dead_as_stale
run_test test_doctor_is_silent_with_no_integrate_lock
run_test test_doctor_checks_the_lock_holder_without_the_shell_assigning_its_own_locale

report_results
