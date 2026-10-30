#!/usr/bin/env bash
# ABOUTME: Tests for the cs mod under mods/cs (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest shape and the default threshold; runs the bun unit tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_and_its_module() {
    assert_eq "cs" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
}

# By default the band appears where the status bar turns amber and the Stop
# hook gives its one-time headroom notice. Both defaults are literals in two
# languages, so this test is the only thing holding them together.
test_mod_default_threshold_matches_the_statusline_warn_default() {
    local mod_default sl_warn
    mod_default="$(sed -n 's/^export const DEFAULT_PERCENT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    sl_warn="$(sed -n 's/.*_num_or "\${CS_STATUSLINE_CTX_WARN:-}" \([0-9]*\).*/\1/p' "$SCRIPT_DIR/../bin/cs-statusline")"
    [ -n "$mod_default" ] || { echo "  FAIL: DEFAULT_PERCENT literal not found in register.tsx"; return 1; }
    [ -n "$sl_warn" ] || { echo "  FAIL: ctx warn default not found in bin/cs-statusline"; return 1; }
    assert_eq "$sl_warn" "$mod_default" "mod default == statusline warn default" || return 1
}

# The forced-rotation threshold is decided twice: by the mod, which acts on it,
# and by the launch notice, which tells the person what it is. A comment kept
# them together; this keeps the number itself together, so a notice can never
# quote a threshold the mod does not use.
test_mod_force_default_matches_the_launch_notice() {
    local mod_default shell_default
    mod_default="$(sed -n 's/^export const FORCE_DEFAULT = \([0-9]*\)$/\1/p' "$MOD/hooks/register.tsx")"
    # The fallback the shell resolver prints for an unset value: the line is
    # found by what it does (an empty raw echoing a number), and the number is
    # read off it, so reformatting the line cannot turn a mismatch into a
    # "not found" that passes for a different reason.
    shell_default="$(grep -F 'z "$raw" ] && { echo' "$SCRIPT_DIR/../lib/75-launch.sh" \
        | head -1 | sed -n 's/.*echo \([0-9][0-9]*\).*/\1/p')"
    [ -n "$mod_default" ] || { echo "  FAIL: FORCE_DEFAULT literal not found in register.tsx"; return 1; }
    [ -n "$shell_default" ] || { echo "  FAIL: unset fallback not found in lib/75-launch.sh"; return 1; }
    assert_eq "$mod_default" "$shell_default" "mod FORCE_DEFAULT == the notice's default" || return 1
    # And the two agree on what turns it off, so `off` cannot mean one thing to
    # the mod and another to the notice.
    grep -q "raw.toLowerCase() === 'off'" "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the mod no longer spells the off switch as 'off'"; return 1; }
    grep -q 'off) return 0 ;;' "$SCRIPT_DIR/../lib/75-launch.sh" \
        || { echo "  FAIL: the notice no longer spells the off switch as 'off'"; return 1; }
}

# The countdown's ramp paints the bar's own inks: the session palette, amber
# and crit, each a literal in two languages (KEEP IN SYNC); cs-update's version
# headings carry their own copy of the palette. Read out of _sgr's
# truecolor arm, so a colour changed in the bar and not in the mod fails here.
test_mod_ramp_inks_match_the_statusline() {
    local sl="$SCRIPT_DIR/../bin/cs-statusline" mod="$MOD/hooks/register.tsx"
    local update="$SCRIPT_DIR/../mods/cs-update/hooks/register.tsx"
    local truecolor name sl_rgb mod_rgb update_rgb
    truecolor="$(sed -n '/^_sgr() {/,/^        256)/p' "$sl")"
    for name in red blue green yellow purple orange pink cyan; do
        sl_rgb="$(sed -n "s/^ *$name) *rgb=\"\([0-9;]*\)\" ;;.*/\1/p" <<< "$truecolor" | tr ';' ',')"
        mod_rgb="$(sed -n "s/.*[{ ]$name: '\([0-9,]*\)'.*/\1/p" "$mod")"
        update_rgb="$(sed -n "s/.*[{ ]$name: '\([0-9,]*\)'.*/\1/p" "$update")"
        [ -n "$sl_rgb" ] || { echo "  FAIL: palette colour $name not found in _sgr"; return 1; }
        assert_eq "$sl_rgb" "$mod_rgb" "mod palette $name == statusline $name" || return 1
        assert_eq "$sl_rgb" "$update_rgb" "cs-update palette $name == statusline $name" || return 1
    done

    local amber crit
    amber="$(sed -n '/^ *amber)$/,/fi ;;/p' <<< "$truecolor")"
    crit="$(sed -n 's/^ *\[ "\$SL_THEME" = "dark" \] && rgb="\([0-9;]*\)" || rgb="\([0-9;]*\)" ;;$/\1 \2/p' <<< "$(sed -n '/^ *crit)$/,/;;/p' <<< "$truecolor")")"
    assert_eq "$(sed -n 's/.*_LUM" -ge \([0-9]*\) \] && rgb="\([0-9;]*\)" || rgb="\([0-9;]*\)".*/\1 \2 \3/p' <<< "$amber" | tr ';' ',')" \
        "$(sed -n 's/.*722 \* rgb\[2\] >= \([0-9]*\) :.*/\1/p' "$mod") $(sed -n "s/^export const AMBER_LIGHT = '\([0-9,]*\)'$/\1/p" "$mod") $(sed -n "s/^export const AMBER_DARK = '\([0-9,]*\)'$/\1/p" "$mod")" \
        "mod amber pivot, light and dark == statusline amber" || return 1
    assert_eq "$(tr ';' ',' <<< "$crit")" \
        "$(sed -n "s/^export const CRIT_DARK = '\([0-9,]*\)'$/\1/p" "$mod") $(sed -n "s/^export const CRIT_LIGHT = '\([0-9,]*\)'$/\1/p" "$mod")" \
        "mod crit dark and light == statusline crit" || return 1
}

# The installer deploys the mod under ~/.claude/skills/cs and a cs
# launch exports the flag Claude Code loads it behind, so the mod runs with
# nothing for the person to place. Both halves are pinned here by name; the
# install and launch suites test the behaviour.
test_mod_is_deployed_by_the_installer_and_enabled_at_launch() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "^    cs/hooks/register.tsx$" "install.sh lists the module" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/75-launch.sh" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS" "launch exports the loader flag" || return 1
}

test_mod_unit_tests_pass_under_bun() {
    require_tool bun || return $?
    local out
    out="$(cd "$MOD" && bun test 2>&1)" || { echo "$out"; return 1; }
    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

# `claude plugin validate` inventories the module's hooks and $ calls with the
# function-hooks flag OFF, so this runs wherever the binary is.
test_mod_validate_inventories_the_hooks_and_calls() {
    require_tool claude || return $?
    local out raw="${TMPDIR:-/tmp}/cs-mod-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    # A Claude Code from before function hooks validates the manifest and
    # prints no inventory; the pins below are about the inventory.
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    assert_output_contains "$out" "hooks: session.start, command.run{command=queue}, command.run{command=cs}, config.set, turn.complete, skill.prompt{skill=finish}, prompt.submit, command.run{command=clear}, turn.start, ui.render{component=UserMessage}, ui.render{component=AbovePrompt}, ui.focus{component=AbovePrompt, plugin=cs}" "all twelve hooks inventoried, config.set refusing a band value the band cannot draw" || return 1
    assert_output_contains "$out" "gating hook without .catch: command.run{command=cs}" "/cs is a gate: it answers an argument itself and hands bare /cs to the cs panel's hook" || return 1
    assert_output_not_contains "$out" '$.prompt.fill' "nothing fills the composer any more" || return 1
    assert_output_contains "$out" 'env reads: CLAUDE_CONFIG_DIR, CS_BIN, CS_ROTATE_BUTTON_CTX, CS_ROTATE_FORCE_CTX, CS_SESSIONS_ROOT, CS_STATUSLINE_CTX_WARN, CS_TERM_BG_RGB, CS_TERM_THEME, CS_TRANSCRIPTS_DIR, HOME' "the cs path, the two thresholds, the bar's warn band, the measured background and the theme (the count's amber pivot), where keybindings.json lives, the sessions root and where transcripts live are read from the environment; the caps consent is not" || return 1
    assert_output_contains "$out" '$.process.run, $.prompt.submit (via offerToStart), $.session.compact (via offerToStart), $.session.cwd' "/queue runs cs from its own hook and its start offer, which alone submits a prompt and compacts; the rotation asks cs -vet-session before it arms; the /finish watch runs kill -0 to ask after cs's pid" || return 1
    assert_output_contains "$out" '$.command.list, $.command.register, $.command.run (via askToWrap, clearAndContinue, noteConversation, pressFinish, rotate)' "the band discovers commands; the wrap, clear, finish and rotate keys and conversation colour keep their command routes" || return 1
    assert_output_contains "$out" '$.clock.after, $.clock.every (via readFeatures, startCountdown, watchFinish), $.clock.now (via gateWord)' "the forced /rotate, the next-step toast and the rail's redraw are one-shot timers, the grace, the /finish watch and the idle features read tickers, and the gate word alone reads the time" || return 1
    local src="$MOD/hooks/register.tsx" scroll_lines jump_range feed_range
    # The validator cuts its calls line at a fixed length (`… [+N chars]`);
    # every assert on it must name something before the cut. $.ui.log and
    # selected later calls are checked on the source instead.
    assert_eq "6" "$(grep -c '\$\.ui\.log' "$src")" "six calls log a features word read failure, a features complaint, a transcript read failure, a /color that did not run, a feed read failure and a settings read complaint" || return 1
    feed_range=$(awk '/^async function pressFeed\(/ { start = NR } start && !end && /^}/ { end = NR } END { print start, end }' "$src")
    set -- $feed_range
    assert_eq "1" "$(awk -v start="$1" -v end="$2" 'NR > start && NR < end && /\$\.fs\.write/ { count++ } END { print count + 0 }' "$src")" "one call inside pressFeed writes the feed file" || return 1
    assert_output_contains "$out" '$.session.id, $.session.usage, $.ui.ask (via askToWrap, offerToStart), $.ui.invalidate' "the visible inventory includes the session, dialogs and redraw calls" || return 1
    scroll_lines=$(grep -n '\$\.ui\.scroll' "$src" | cut -d: -f1 | tr '\n' ' ')
    jump_range=$(awk '/^async function jumpTo\(/ { start = NR } start && !end && /^}/ { end = NR } END { print start, end }' "$src")
    assert_eq "1" "$(grep -c '\$\.ui\.scroll' "$src")" "one call scrolls the transcript" || return 1
    set -- $jump_range
    [ "${scroll_lines% }" -gt "$1" ] && [ "${scroll_lines% }" -lt "$2" ] \
        || { echo "  FAIL: \$.ui.scroll at line ${scroll_lines% } is outside jumpTo (lines $1-$2)"; return 1; }
    assert_output_contains "$out" '$.ui.ask (via askToWrap, offerToStart)' "the wrap key and the /queue start offer ask through the engine's own dialog" || return 1
    assert_eq "0" "$(grep -c '\$\.ui\.open' "$src")" "the mod opens no pane" || return 1
    assert_eq "0" "$(grep -c '\$\.ui\.close' "$src")" "and closes none" || return 1
    assert_eq "0" "$(grep -c '\$\.ui\.panes' "$src")" "and lists none" || return 1
    assert_output_contains "$out" '$.fs.list (via hasFeatureDirs, queueLength, unreadMail)' "the band counts the queue's tasks and the mailbox's unread mail by listing their directories, and looks for a base's feature directories at the sessions root before asking cs; nothing else lists one" || return 1
    assert_output_contains "$out" '$.fs.read (via armedHandoff, boundChords, clearPressed, csSessionName, forceRotation, queueRunning, readFeed, readFinish, readState, readWrapped, refreshRail)' "the wrap marker, the press marker, the state (for the session's recorded name too), the queue's state, the feed file, the /finish record, keybindings.json and the transcript are read" || return 1
    assert_output_contains "$out" '$.fs.stat (via refreshRail, resolvedPath)' "stat resolves where a path lands, to prove the cwd is the sessions root's entry, and gates the transcript's re-read on its size and mtime; no other rule hangs on a modification time" || return 1
}

run_test test_mod_manifest_names_the_plugin_and_its_module
run_test test_mod_default_threshold_matches_the_statusline_warn_default
run_test test_mod_force_default_matches_the_launch_notice
run_test test_mod_ramp_inks_match_the_statusline
run_test test_mod_is_deployed_by_the_installer_and_enabled_at_launch
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
