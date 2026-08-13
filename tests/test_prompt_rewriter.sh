#!/usr/bin/env bash
# ABOUTME: Tests for the $EDITOR shim that rewrites Claude Code's composer buffer in place
# ABOUTME: Covers the rewrite, the pass-through classes, and fail-safe behaviour on rewriter failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SHIM="$SCRIPT_DIR/../hooks/prompt-rewriter.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    # A stub rewriter: uppercases nothing, just wraps, so the assertion is about
    # the shim's plumbing and not about any model's output.
    STUB="$TEST_TMPDIR/stub-rewrite.sh"
    cat > "$STUB" <<'STUBEOF'
#!/bin/bash
printf 'PRECISE: %s' "$(cat)"
STUBEOF
    chmod +x "$STUB"
    export CS_REWRITE_CMD="$STUB"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Claude Code hands the shim a file named claude-prompt-<uuid>.md holding the
# composer buffer, then reads the file back and replaces the composer with it.
composer_file() {  # content
    local f="$TEST_TMPDIR/claude-prompt-11111111-2222-3333-4444-555555555555.md"
    printf '%s' "$1" > "$f"
    printf '%s' "$f"
}

# Run the shim under a real pty in a given progress mode and return the capture
# path. Only a pty makes [ -t 2 ] true; without one every rendering assertion
# below would pass against a shim that draws nothing.
render_in_mode() {  # mode, [prompt], [stub_seconds]
    local mode="$1" text="${2:-make the login thing better}" secs="${3:-1.8}"
    local slow="$TEST_TMPDIR/slow-rewrite.sh"
    printf '#!/bin/bash\nsleep %s\nprintf "PRECISE"\n' "$secs" > "$slow"
    chmod +x "$slow"
    local f; f=$(composer_file "$text")
    local out="$TEST_TMPDIR/pty-$mode"
    # script(1) tcgetattr's its OWN stdin and dies on a socket, which is what a
    # CI runner or an agent harness often hands it; /dev/null still gets the
    # child a pty.
    CS_REWRITE_PROGRESS="$mode" CS_REWRITE_CMD="$slow" \
        script -q /dev/null "$SHIM" "$f" < /dev/null > "$out" 2>&1
    printf '%s' "$out"
}

test_rewrites_the_composer_file_in_place() {
    local f; f=$(composer_file "make the login thing better")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "PRECISE: make the login thing better" "$(cat "$f")" \
        "the composer file holds the rewritten prompt"
}

# A file that is not the composer buffer belongs to the user's real editor.
test_non_composer_file_goes_to_the_real_editor() {
    local f="$TEST_TMPDIR/CLAUDE.md"
    printf 'my memory file\n' > "$f"
    local marker="$TEST_TMPDIR/real-editor-ran"
    cat > "$TEST_TMPDIR/fake-editor.sh" <<EOF
#!/bin/bash
printf '%s' "\$1" > "$marker"
EOF
    chmod +x "$TEST_TMPDIR/fake-editor.sh"
    CS_REAL_EDITOR="$TEST_TMPDIR/fake-editor.sh" "$SHIM" "$f" >/dev/null 2>&1
    assert_exists "$marker" "the real editor was exec'd for a non-composer file" || return 1
    assert_eq "my memory file" "$(cat "$f")" "and the file was not rewritten"
}

test_slash_command_passes_through() {
    local f; f=$(composer_file "/color red")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "/color red" "$(cat "$f")" "a slash command is already precise"
}

test_bang_passthrough_passes_through() {
    local f; f=$(composer_file "!printenv PATH")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "!printenv PATH" "$(cat "$f")" "shell passthrough is not prose"
}

test_memory_entry_passes_through() {
    local f; f=$(composer_file "#remember the deploy runs at 5")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "#remember the deploy runs at 5" "$(cat "$f")" "a memory entry is not a request"
}

test_empty_buffer_passes_through() {
    local f; f=$(composer_file "   ")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "   " "$(cat "$f")" "an empty buffer has nothing to rewrite"
}

# The composer buffer carries placeholders, not the pasted bodies. Rewriting the
# placeholder away destroys the attachment.
test_pasted_text_placeholder_passes_through() {
    local f; f=$(composer_file "explain this [Pasted text #1 +40 lines]")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "explain this [Pasted text #1 +40 lines]" "$(cat "$f")" \
        "a buffer carrying a paste placeholder is left alone"
}

test_image_placeholder_passes_through() {
    local f; f=$(composer_file "what is wrong here [Image #1]")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "what is wrong here [Image #1]" "$(cat "$f")" \
        "a buffer carrying an image placeholder is left alone"
}

# Fail-safe: the user's typed text must survive every rewriter failure.
test_failing_rewriter_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\nexit 7\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "a rewriter that exits non-zero must not lose the prompt"
}

test_empty_rewrite_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\ncat >/dev/null; printf ""\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "an empty rewrite must not erase the prompt"
}

test_whitespace_only_rewrite_leaves_the_buffer_untouched() {
    local f; f=$(composer_file "make the login thing better")
    printf '#!/bin/bash\ncat >/dev/null; printf "  \\n "\n' > "$TEST_TMPDIR/stub-rewrite.sh"
    "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "a whitespace-only rewrite must not erase the prompt"
}

test_opt_out_via_disable_env() {
    local f; f=$(composer_file "make the login thing better")
    CS_REWRITE_DISABLE=1 "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "CS_REWRITE_DISABLE suppresses the rewrite"
}

# The rewriter is a separate switch from the clarifying-questions guideline.
test_clarify_disable_does_not_suppress_the_rewriter() {
    local f; f=$(composer_file "make the login thing better")
    CS_CLARIFY_DISABLE=1 "$SHIM" "$f" >/dev/null 2>&1
    assert_eq "PRECISE: make the login thing better" "$(cat "$f")" \
        "CS_CLARIFY_DISABLE governs the guideline, not the rewriter"
}

test_prompt_text_is_data_not_code() {
    local canary="$TEST_TMPDIR/canary"
    local f; f=$(composer_file "run \$(touch $canary) now")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_not_exists "$canary" "prompt text must never be executed"
}

test_shim_never_leaves_a_temp_file_behind() {
    local f; f=$(composer_file "make the login thing better")
    "$SHIM" "$f" >/dev/null 2>&1
    assert_not_exists "$f.cs-tmp" "the tmp+rename leaves no residue"
}

# Every mode must put something on that blank screen — that is the entire point
# of the feature, and the one property all three share.
test_every_progress_mode_paints_something() {
    local mode out
    for mode in screen line static native; do
        out=$(render_in_mode "$mode")
        assert_file_contains "$out" 'ewriting' \
            "mode '$mode' painted the screen" || return 1
    done
}

# An unrecognised value must not silently restore the blank screen the feature
# exists to remove.
test_unknown_progress_mode_falls_back_to_a_display() {
    local out; out=$(render_in_mode 'nonsense-value')
    assert_file_contains "$out" 'ewriting' "an unknown mode still paints"
}

# Only the screen mode echoes the prompt, so only it can clip one. A pasted
# essay must not scroll the header away, and the user has to be told it was
# clipped rather than shown a fragment that reads like the whole thing.
test_screen_mode_caps_a_long_prompt_and_marks_it() {
    local long='' i=''
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        long="$long line $i of a very long prompt that keeps going and going;"
    done
    local out; out=$(render_in_mode screen "$long")
    # A bare '…' would match the 'working…' in the spinner line and pass
    # against a shim that never clips anything, so pin the whole marker.
    assert_file_contains "$out" '… prompt clipped' "the clip is marked, not silent" || return 1
    local shown
    shown=$(perl -0777 -ne 's/.*\e\[H//s; print' < "$out" | tr '\r' '\n' | grep -c 'of a very long prompt')
    [ "$shown" -le 8 ] || { echo "    expected <=8 prompt lines, got $shown"; return 1; }
}

# The line and static modes are deliberately bare: no prompt echo, so a pasted
# secret or a long essay never reaches the screen at all.
test_line_and_static_modes_do_not_echo_the_prompt() {
    local mode out
    for mode in line static native; do
        out=$(render_in_mode "$mode" "correct-horse-battery-staple")
        assert_file_not_contains "$out" 'correct-horse-battery-staple' \
            "mode '$mode' keeps the prompt off screen" || return 1
    done
}

# Claude Code writes its own progress as a sentence-case gerund with the elapsed
# in parentheses, and suppresses the elapsed until it has been running long
# enough to be worth reading:
#
#     m = f >= 5 ? `${d} (${f}s)` : d
#
# The native mode follows that. Under five seconds it must show the label with
# no clock at all — a counter ticking 1s, 2s on a rewrite that always takes
# about ten is noise Claude Code deliberately leaves out.
test_animated_modes_withhold_the_elapsed_under_five_seconds() {
    local mode out
    for mode in native screen; do
        out=$(render_in_mode "$mode" '' 1)
        assert_file_not_contains "$out" '([0-9]*s)' \
            "mode '$mode' shows no elapsed before five seconds" || return 1
    done
}

test_animated_modes_show_the_elapsed_past_five_seconds() {
    local mode out
    # screen is excluded deliberately: it shows time REMAINING against the
    # budget, so it has no elapsed to withhold. See test_screen_mode_counts_down.
    for mode in native; do
        out=$(render_in_mode "$mode" '' 6)
        assert_file_contains "$out" '(5s)' \
            "mode '$mode' shows the elapsed once it is worth reading" || return 1
    done
}

# cosmetic problem it solves. Both halves are asserted together for that reason.
test_progress_hides_the_cursor_and_restores_it() {
    local mode out hide show
    for mode in screen line static native; do
        out=$(render_in_mode "$mode")
        assert_file_contains "$out" $'\033\[?25l' "mode '$mode' hides the cursor" || return 1
        # Order matters, not just presence: restoring before hiding would
        # satisfy a presence check and still leave the cursor hidden.
        hide=$(grep -abo $'\033\[?25l' "$out" | head -1 | cut -d: -f1)
        show=$(grep -abo $'\033\[?25h' "$out" | tail -1 | cut -d: -f1)
        [ -n "$hide" ] && [ -n "$show" ] && [ "$show" -gt "$hide" ] \
            || { echo "mode '$mode': restore at '$show' does not follow hide at '$hide'"; return 1; }
    done
}

# No mode may offer ctrl+c. The terminal delivers SIGINT to the whole foreground
# process group, which contains Claude Code, so the keystroke ends the session —
# no handler in a spawned shim can intercept it. Advertising it as a way to keep
# your prompt costs the user their session.
test_no_progress_mode_advertises_ctrl_c() {
    local mode out
    for mode in screen line static native; do
        out=$(render_in_mode "$mode")
        # Guard the guard: if nothing painted, absence of the hint proves nothing.
        assert_file_contains "$out" 'ewriting' "mode '$mode' painted" || return 1
        assert_file_not_contains "$out" '\^C' "mode '$mode' must not offer ctrl+c" || return 1
        assert_file_not_contains "$out" 'ctrl+c' "mode '$mode' must not spell it out" || return 1
    done
}

# Cancelling a rewrite must read as "keep what I typed", not as a crash: Claude
# Code renders any non-zero status as "<editor> quit unexpectedly".
#
# Signalled with TERM, and the shim handles INT and TERM with one handler, so
# this covers the handler, the restored buffer, the exit status and the reaped
# tree. It does NOT cover ctrl+c itself, and cannot: run_all.sh launches each
# suite inside a background subshell with no job control, which leaves SIGINT
# set to SIG_IGN for the suite and everything it spawns, and bash cannot trap a
# signal it inherited as ignored. `set -m` does not undo it either — it hands
# out a new process group, not a new disposition. A suite that sent INT would
# pass when run by hand in the foreground and fail inside the gate, against
# identical code. Delivery of the keystroke is an interactive property and is
# verified by hand.
test_cancel_keeps_the_original_and_exits_clean() {
    # The stub outlives the test by a wide margin on purpose. A short one makes
    # the test race it: if load stretches readiness-polling and signal delivery
    # past the stub's own life, the rewrite completes and the buffer changes,
    # which reads as a broken trap rather than as a slow machine. The cancel
    # path kills this process, so the long sleep costs nothing when it works.
    local slow="$TEST_TMPDIR/slow-rewrite.sh"
    printf '#!/bin/bash\nsleep 120\nprintf "PRECISE: rewritten"\n' > "$slow"
    chmod +x "$slow"
    local f; f=$(composer_file "make the login thing better")
    CS_REWRITE_CMD="$slow" "$SHIM" "$f" >/dev/null 2>&1 &
    local shim=$!
    # Wait for the shim to fork the rewriter rather than guessing at a delay.
    # The trap is armed before that fork, so a visible child proves the handler
    # is installed. A fixed sleep raced it whenever the gate's other lanes made
    # forking slow, and the lost signal let the rewrite land.
    local waited=0
    while [ "$waited" -lt 50 ] && ! pgrep -P "$shim" >/dev/null 2>&1; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ "$waited" -lt 50 ] || { echo "shim never forked a rewriter"; kill "$shim" 2>/dev/null; return 1; }
    kill -TERM "$shim" 2>/dev/null
    local st=0; wait "$shim" || st=$?
    assert_eq "0" "$st" "exits 0, so Claude Code reports no editor error" || return 1
    assert_eq "make the login thing better" "$(cat "$f")" \
        "the buffer comes back exactly as typed" || return 1
    assert_not_exists "$f.cs-out" "the rewriter's output file is cleaned up on cancel"
}

# Meaningful only as the other half of test_progress_renders_under_a_pty: this
# one asserts absence and would pass against a shim that never draws at all.
# The pair is what pins the behaviour — draws on a tty, silent off one.
test_progress_is_silent_without_a_tty() {
    local slow="$TEST_TMPDIR/slow-rewrite.sh"
    printf '#!/bin/bash\nsleep 0.6\nprintf "PRECISE"\n' > "$slow"
    chmod +x "$slow"
    local f; f=$(composer_file "make the login thing better")
    local err="$TEST_TMPDIR/err"
    CS_REWRITE_CMD="$slow" "$SHIM" "$f" >/dev/null 2>"$err"
    assert_eq "" "$(cat "$err")" "a piped run draws nothing" || return 1
    assert_eq "PRECISE" "$(cat "$f")" "and the rewrite still lands"
}

# Cancelling must reap the whole rewriter tree, not just the process the shim
# forked. The real rewriter is a script that spawns `claude -p` and waits, so a
# kill that stops at the script leaves a live API call behind, unattached to
# anything and still being paid for.
test_cancel_reaps_the_whole_rewriter_tree() {
    local pidfile="$TEST_TMPDIR/grandchild.pid"
    local slow="$TEST_TMPDIR/slow-rewrite.sh"
    cat > "$slow" <<SLOWEOF
#!/bin/bash
sleep 120 &
printf '%s' "\$!" > "$pidfile"
wait
SLOWEOF
    chmod +x "$slow"
    local f; f=$(composer_file "make the login thing better")
    CS_REWRITE_CMD="$slow" "$SHIM" "$f" >/dev/null 2>&1 &
    local shim=$!
    local waited=0
    while [ "$waited" -lt 50 ] && [ ! -s "$pidfile" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -s "$pidfile" ] || { echo "rewriter never recorded its child"; kill "$shim" 2>/dev/null; return 1; }
    local grandchild; grandchild=$(cat "$pidfile")
    kill -TERM "$shim" 2>/dev/null
    wait "$shim" 2>/dev/null
    # Give the group kill a moment to land before declaring a leak.
    local settle=0
    while [ "$settle" -lt 20 ] && kill -0 "$grandchild" 2>/dev/null; do
        sleep 0.1
        settle=$((settle + 1))
    done
    if kill -0 "$grandchild" 2>/dev/null; then
        kill -9 "$grandchild" 2>/dev/null
        echo "the rewriter's own child outlived the cancel"
        return 1
    fi
}

# The provider knob picks which shipped rewriter runs. A fake agy on PATH stands
# in for the vendor CLI so the assertion is about the shim's routing and never
# makes a live call.
test_the_provider_knob_selects_the_vendor_rewriter() {
    unset CS_REWRITE_CMD
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\nprintf "VENDOR PATH TAKEN"\n' > "$bin/agy"
    chmod +x "$bin/agy"
    local f
    f=$(composer_file "make the login thing better")
    PATH="$bin:$PATH" XDG_CACHE_HOME="$TEST_TMPDIR/cache" CS_REWRITE_PROVIDER=gemini \
        "$SHIM" "$f"
    assert_file_contains "$f" 'VENDOR PATH TAKEN' \
        "CS_REWRITE_PROVIDER routes to the vendor rewriter"
}

# CS_REWRITE_CMD is the older, wider contract: any executable reading the prompt
# on stdin. A user who set it has said exactly what they want run, so the
# provider knob must not quietly override it.
test_an_explicit_rewrite_cmd_outranks_the_provider_knob() {
    local f
    f=$(composer_file "make the login thing better")
    CS_REWRITE_PROVIDER=gemini "$SHIM" "$f"
    assert_file_contains "$f" '^PRECISE: ' "CS_REWRITE_CMD wins over the provider knob"
}

# A typo in a shell profile should cost the user their choice of model, never
# their prompt, so an unrecognised provider falls back to the default rewriter
# rather than declining. A fake claude on PATH proves which one ran without a
# live call.
test_an_unknown_provider_falls_back_to_the_default_rewriter() {
    unset CS_REWRITE_CMD
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\nprintf "DEFAULT PATH TAKEN"\n' > "$bin/claude"
    chmod +x "$bin/claude"
    local f
    f=$(composer_file "make the login thing better")
    PATH="$bin:$PATH" XDG_CACHE_HOME="$TEST_TMPDIR/cache" CS_REWRITE_PROVIDER=gemeni \
        "$SHIM" "$f"
    assert_file_contains "$f" 'DEFAULT PATH TAKEN' \
        "an unrecognised provider must not cost the user their prompt"
}

# The header names the engine and the model, and both come from the vendor
# rewriter's own resolution rather than a second copy of it here — a header that
# said `api` while `agy` answered would be worse than no header at all. A pty is
# required: without one the shim draws nothing and this would pass against a
# header that was never painted.
test_the_header_names_the_resolved_engine_and_model() {
    unset CS_REWRITE_CMD
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\nsleep 1.8\nprintf "REWRITTEN"\n' > "$bin/agy"
    chmod +x "$bin/agy"
    local f out
    f=$(composer_file "make the login thing better")
    out="$TEST_TMPDIR/pty-label"
    PATH="$bin:$PATH" XDG_CACHE_HOME="$TEST_TMPDIR/cache" \
        CS_REWRITE_PROVIDER=gemini CS_REWRITE_MODEL=gemini-3.6-flash \
        script -q /dev/null "$SHIM" "$f" < /dev/null > "$out" 2>&1
    assert_file_contains "$out" 'agy' "the header names the engine that answers" || return 1
    assert_file_contains "$out" 'gemini-3.6-flash' "the header names the model"
}

# claude-api is the one provider name that routes AWAY from the default
# rewriter for the same vendor: bare `claude` is the shipped agent path, and the
# suffix picks the Messages endpoint instead.
test_claude_api_routes_to_the_vendor_rewriter() {
    unset CS_REWRITE_CMD
    local bin="$TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\nprintf "%%s" "{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"VIA MESSAGES\\"}],\\"stop_reason\\":\\"end_turn\\"}"\n' > "$bin/curl"
    chmod +x "$bin/curl"
    local f
    f=$(composer_file "make the login thing better")
    PATH="$bin:$PATH" XDG_CACHE_HOME="$TEST_TMPDIR/cache" \
        CS_REWRITE_PROVIDER=claude-api ANTHROPIC_API_KEY=not-a-real-key "$SHIM" "$f"
    assert_file_contains "$f" 'VIA MESSAGES' "claude-api routes to the vendor rewriter"
}

# A rewrite shorter than the draw threshold must leave the terminal alone. On
# gemini-api the whole call is ~0.9s, so a screen that paints at 0.3s appears
# and vanishes before it can be read — a flash is worse than nothing.
test_a_fast_rewrite_draws_nothing() {
    local out
    out=$(render_in_mode screen '' 0.4)
    # Not "the file is empty": script(1) writes its own bytes to the capture no
    # matter what the child does. Assert the absence of OUR markers instead.
    assert_file_not_contains "$out" 'ewriting' "a sub-threshold rewrite must not paint" || return 1
    assert_file_not_contains "$out" '▏' "no margin rule below the threshold" || return 1
    # Guard the guard: the two assertions above also pass against a shim that
    # never paints at all, so prove the same helper DOES paint when the rewrite
    # outlives the threshold.
    out=$(render_in_mode screen)
    assert_file_contains "$out" '▏' "the same path paints above the threshold"
}

# The prompt is the subject of this screen, held in a margin rule the way a
# quoted passage is marked up — not body text under a header.
test_screen_mode_frames_the_prompt_in_a_margin() {
    local out; out=$(render_in_mode screen)
    assert_file_contains "$out" '▏' "the prompt sits in a margin rule" || return 1
    assert_file_contains "$out" 'make the login thing better' "the prompt is on screen"
}

# Elapsed is a number you cannot act on: nothing here can be cancelled. What is
# left against the budget is the only fact worth showing.
test_screen_mode_counts_down_not_up() {
    local out; out=$(render_in_mode screen)
    assert_file_contains "$out" 'left' "the budget counts down" || return 1
    assert_file_not_contains "$out" 'Working…' "the generic label is gone"
}

# The margin rule carries the liveness, so the spinner beside it is redundant —
# two things animating for one fact.
test_screen_mode_has_no_spinner() {
    local out; out=$(render_in_mode screen)
    assert_file_not_contains "$out" '⠙' "no braille spinner in screen mode" || return 1
    assert_file_not_contains "$out" '⠹' "no braille spinner in screen mode"
}

run_test test_every_progress_mode_paints_something
run_test test_unknown_progress_mode_falls_back_to_a_display
run_test test_screen_mode_caps_a_long_prompt_and_marks_it
run_test test_line_and_static_modes_do_not_echo_the_prompt
run_test test_animated_modes_withhold_the_elapsed_under_five_seconds
run_test test_animated_modes_show_the_elapsed_past_five_seconds
run_test test_a_fast_rewrite_draws_nothing
run_test test_screen_mode_frames_the_prompt_in_a_margin
run_test test_screen_mode_counts_down_not_up
run_test test_screen_mode_has_no_spinner
run_test test_the_header_names_the_resolved_engine_and_model
run_test test_progress_hides_the_cursor_and_restores_it
run_test test_no_progress_mode_advertises_ctrl_c
run_test test_cancel_reaps_the_whole_rewriter_tree
run_test test_progress_is_silent_without_a_tty
run_test test_cancel_keeps_the_original_and_exits_clean
run_test test_rewrites_the_composer_file_in_place
run_test test_non_composer_file_goes_to_the_real_editor
run_test test_slash_command_passes_through
run_test test_bang_passthrough_passes_through
run_test test_memory_entry_passes_through
run_test test_empty_buffer_passes_through
run_test test_pasted_text_placeholder_passes_through
run_test test_image_placeholder_passes_through
run_test test_failing_rewriter_leaves_the_buffer_untouched
run_test test_empty_rewrite_leaves_the_buffer_untouched
run_test test_whitespace_only_rewrite_leaves_the_buffer_untouched
run_test test_opt_out_via_disable_env
run_test test_clarify_disable_does_not_suppress_the_rewriter
run_test test_prompt_text_is_data_not_code
run_test test_shim_never_leaves_a_temp_file_behind
run_test test_the_provider_knob_selects_the_vendor_rewriter
run_test test_an_explicit_rewrite_cmd_outranks_the_provider_knob
run_test test_an_unknown_provider_falls_back_to_the_default_rewriter
run_test test_claude_api_routes_to_the_vendor_rewriter

report_results
