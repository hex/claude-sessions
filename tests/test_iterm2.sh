#!/usr/bin/env bash
# ABOUTME: Tests for iTerm2 awareness: the attention dock bounce fired by the
# ABOUTME: hooks through it2attention, and the doctor's integration-surface line

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + ambient env + a fake it2 toolkit that logs its argv instead
# of emitting terminal escapes. test_lib's setup exports CS_NO_ITERM2=1 for
# every suite; tests that expect a fire unset it explicitly.
_it2_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
    export IT2_LOG="$TEST_TMPDIR/it2.log"
    export CS_IT2_DIR="$TEST_TMPDIR/it2bin"
    export CS_IT2_TTY="$TEST_TMPDIR/tty-sink"
    mkdir -p "$CS_IT2_DIR"
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$IT2_LOG" > "$CS_IT2_DIR/it2attention"
    chmod +x "$CS_IT2_DIR/it2attention"
}

test_stop_hook_bounces_dock_in_iterm() {
    _it2_session "bounce"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/stop-blocks.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "start" "turn end should start the bounce" || return 1
}

test_no_bounce_outside_iterm() {
    _it2_session "notiterm"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="Apple_Terminal"
    echo '{}' | bash "$HOOKS_DIR/stop-blocks.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: it2attention fired outside iTerm2: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_no_bounce_when_disabled() {
    _it2_session "killed"
    export CS_NO_ITERM2=1
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/stop-blocks.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: CS_NO_ITERM2 must disable the bounce: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_missing_it2_tool_is_silent_and_harmless() {
    _it2_session "notool"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    rm -f "$CS_IT2_DIR/it2attention"
    local ec=0
    echo '{}' | bash "$HOOKS_DIR/stop-blocks.sh" >/dev/null 2>&1 || ec=$?
    assert_eq "0" "$ec" "hook must not fail when it2 is absent" || return 1
}

test_prompt_hook_stops_the_bounce() {
    _it2_session "stopper"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "a new prompt should stop the bounce" || return 1
}

test_session_start_stops_the_bounce() {
    _it2_session "starter"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"source":"resume"}' | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "session start should stop a stale bounce" || return 1
}

test_doctor_reports_iterm2_surface() {
    _it2_session "docsess"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    local out
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "iTerm2" "doctor should mention iTerm2 inside it" || return 1
    assert_output_contains "$out" "attention bounce active" "it2 present reads as active" || return 1

    rm -f "$CS_IT2_DIR/it2attention"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "shell integration not installed" \
        "missing it2 reads as bounce off" || return 1

    export TERM_PROGRAM="Apple_Terminal"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$out" "iTerm2" "doctor stays silent outside iTerm2" || return 1
}

# A claude install laid out like the native installer's: bin/claude is a
# symlink to versions/<version>, the stub there prints its argv0 and its
# environment. A fake tmux answers the control-mode query with $FAKE_CC and
# accepts everything else. The ambient env is iTerm2 reached through tmux.
_tab_launch_env() {  # control_mode
    local inst="$TEST_TMPDIR/inst"
    mkdir -p "$inst/versions" "$inst/bin"
    printf '#!/usr/bin/env bash\necho "argv0=$0"\necho "args=$*"\nenv\n' > "$inst/versions/9.9.9"
    chmod +x "$inst/versions/9.9.9"
    ln -sf ../versions/9.9.9 "$inst/bin/claude"
    cat > "$inst/bin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
case "$*" in
    *client_control_mode*) echo "$FAKE_CC" ;;
esac
exit 0
TMUX_EOF
    chmod +x "$inst/bin/tmux"
    export PATH="$inst/bin:$PATH"
    export CS_TMUX_BIN="$inst/bin/tmux"
    export FAKE_CC="$1"
    export TMUX="/tmp/fake-tmux-socket,1,0"
    export TERM=xterm-256color TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.7c
    export LC_TERMINAL=iTerm2 LC_TERMINAL_VERSION=3.7.1
    unset CLAUDE_CODE_BIN CS_NO_ITERM2 CLAUDE_CONFIG_DIR
}

# The value of NAME in the stub's printed environment, or the argv0 line.
_launched() {  # output name
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

test_launch_under_iterm_cc_shows_loader_and_icon() {
    _tab_launch_env 1
    local out argv0
    out=$("$CS_BIN" tabsess <<< "" 2>&1) || true
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" \
        "claude must see iTerm.app so it sends the progress loader" || return 1
    assert_eq "3.7.1" "$(_launched "$out" TERM_PROGRAM_VERSION)" \
        "the version claude gates the loader on is iTerm's own" || return 1
    argv0=$(_launched "$out" argv0)
    assert_eq "claude" "$(basename "$argv0")" \
        "claude must run under the name iTerm maps to its icon" || return 1
    [ "$argv0" -ef "$TEST_TMPDIR/inst/versions/9.9.9" ] || {
        echo "  FAIL: launched $argv0 is not the installed version file"; return 1; }
    [ ! -L "$argv0" ] || { echo "  FAIL: $argv0 is a symlink, its process name stays the version"; return 1; }
}

# Claude Code reads iTerm.app plus a TERM outside screen*/tmux* as tmux -CC.
# In plain tmux with such a TERM that would be false, so claude keeps tmux's
# name there; with a tmux TERM the reading cannot misfire and the loader works.
test_plain_tmux_keeps_tmux_name_unless_term_is_tmux() {
    _tab_launch_env 0
    local out
    out=$("$CS_BIN" plaintmux <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" \
        "plain tmux with an xterm TERM must not look like tmux -CC to claude" || return 1
    export TERM=tmux-256color
    out=$("$CS_BIN" plaintmux <<< "" 2>&1) || true
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" \
        "plain tmux with a tmux TERM gets the loader" || return 1
}

test_outside_iterm_launch_is_untouched() {
    _tab_launch_env 1
    unset LC_TERMINAL
    local out
    out=$("$CS_BIN" notiterm <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" "no iTerm2, no rename" || return 1
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "no iTerm2, claude runs as found on PATH" || return 1
}

test_iterm_integrations_off_leaves_launch_untouched() {
    _tab_launch_env 1
    export CS_NO_ITERM2=1
    local out
    out=$("$CS_BIN" itermoff <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" "CS_NO_ITERM2 keeps tmux's name" || return 1
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "CS_NO_ITERM2 runs claude as found on PATH" || return 1
}

# After a claude update the link still names the old version's file; the next
# launch must run the version bin/claude now points at.
test_link_follows_a_claude_update() {
    _tab_launch_env 1
    "$CS_BIN" before-update <<< "" > /dev/null 2>&1 || true
    printf '#!/usr/bin/env bash\necho "argv0=$0"\necho "version=10.0.0"\n' > "$TEST_TMPDIR/inst/versions/10.0.0"
    chmod +x "$TEST_TMPDIR/inst/versions/10.0.0"
    ln -sf ../versions/10.0.0 "$TEST_TMPDIR/inst/bin/claude"
    local out
    out=$("$CS_BIN" after-update <<< "" 2>&1) || true
    assert_eq "10.0.0" "$(_launched "$out" version)" "the updated claude must run" || return 1
    assert_eq "claude" "$(basename "$(_launched "$out" argv0)")" "still under the name claude" || return 1
}

# Each version gets its own link, so a launch that resolved one version runs
# that version even if another launch links a newer one before it execs.
# A link outlives its version only until the installer removes that file.
test_each_version_has_its_own_link() {
    _tab_launch_env 1
    local inst="$TEST_TMPDIR/inst" out old new
    out=$("$CS_BIN" v-old <<< "" 2>&1) || true
    old=$(_launched "$out" argv0)
    printf '#!/usr/bin/env bash\necho "argv0=$0"\n' > "$inst/versions/10.0.0"
    chmod +x "$inst/versions/10.0.0"
    ln -sf ../versions/10.0.0 "$inst/bin/claude"
    out=$("$CS_BIN" v-new <<< "" 2>&1) || true
    new=$(_launched "$out" argv0)
    [ "$old" != "$new" ] || { echo "  FAIL: both versions ran from one path: $old"; return 1; }
    [ "$old" -ef "$inst/versions/9.9.9" ] || {
        echo "  FAIL: linking 10.0.0 changed what $old runs"; return 1; }
    # A launch may still be waiting to exec a link it picked moments ago, so a
    # link whose version is gone stays until nothing has picked it for a day.
    rm "$inst/versions/9.9.9"
    "$CS_BIN" v-recent <<< "" > /dev/null 2>&1 || true
    [ -e "$old" ] || { echo "  FAIL: $old went while a launch may still need it"; return 1; }
    touch -t 202001010000 "$(dirname "$old")"
    "$CS_BIN" v-pruned <<< "" > /dev/null 2>&1 || true
    [ ! -e "$old" ] || { echo "  FAIL: $old kept a removed version alive"; return 1; }
}

# The launch sites expand CLAUDE_CODE_BIN unquoted (it may carry arguments),
# so a link path with a space in it would be split; such a HOME gets no link.
test_home_with_a_space_runs_claude_as_found() {
    _tab_launch_env 1
    export HOME="$TEST_TMPDIR/a home"
    mkdir -p "$HOME"
    local out
    out=$("$CS_BIN" spacehome <<< "" 2>&1) || true
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "a HOME with a space must not break the launch" || return 1
}

# The icon is cosmetic: a launch that cannot make the link runs claude anyway.
test_unlinkable_claude_still_launches() {
    _tab_launch_env 1
    mkdir -p "$HOME/.local/share"
    : > "$HOME/.local/share/cs"
    local out
    out=$("$CS_BIN" nolink <<< "" 2>&1) || true
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "with no place for the link, claude runs as found on PATH" || return 1
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" "the loader does not need the link" || return 1
}

# Only a file sitting directly in a versions directory and named by a dotted
# version number is the native installer's; a binary elsewhere, or one that
# merely has a versions directory in its path, runs as given.
test_non_native_claude_binaries_are_run_as_given() {
    _tab_launch_env 1
    local inst="$TEST_TMPDIR/inst" out bin
    for bin in "$inst/own/claude" "$inst/versions/3.12.1/bin/claude" "$inst/versions/1x.2y.3z" "$inst/releases/1.2.3" "$inst/versions/1.2" "$inst/versions/1..2.3" "$inst/versions/.1.2.3" "$inst/versions/1.2.3."; do
        mkdir -p "$(dirname "$bin")"
        cp "$inst/versions/9.9.9" "$bin"
        export CLAUDE_CODE_BIN="$bin --flag"
        out=$("$CS_BIN" "own$RANDOM" <<< "" 2>&1) || true
        assert_eq "$bin" "$(_launched "$out" argv0)" "$bin must run as given" || return 1
        assert_eq "--flag" "$(_launched "$out" args | cut -d' ' -f1)" "its flags are kept" || return 1
    done
}

# A CLAUDE_CODE_BIN that names the native install and carries flags runs the
# link with the flags, split the way every launch site splits the value.
test_native_claude_with_flags_runs_the_link_with_its_flags() {
    _tab_launch_env 1
    local out argv0
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/inst/bin/claude --permission-mode plan"
    out=$("$CS_BIN" flagged <<< "" 2>&1) || true
    argv0=$(_launched "$out" argv0)
    assert_eq "claude" "$(basename "$argv0")" "the flagged native claude runs under the name claude" || return 1
    [ "$argv0" -ef "$TEST_TMPDIR/inst/versions/9.9.9" ] || {
        echo "  FAIL: launched $argv0 is not the installed version file"; return 1; }
    [ ! -L "$argv0" ] || { echo "  FAIL: $argv0 is a symlink, its process name stays the version"; return 1; }
    assert_eq "--permission-mode plan --name flagged --session-id" \
        "$(_launched "$out" args | cut -d' ' -f1-5)" "the flags stay in front, in order" || return 1
    export CLAUDE_CODE_BIN="  $TEST_TMPDIR/inst/bin/claude	--permission-mode	plan"
    out=$("$CS_BIN" tabbed <<< "" 2>&1) || true
    assert_eq "claude" "$(basename "$(_launched "$out" argv0)")" "leading spaces and a tab around the path are split like the launch splits them" || return 1
    assert_eq "--permission-mode plan --name tabbed" \
        "$(_launched "$out" args | cut -d' ' -f1-4)" "flags after a tab are kept" || return 1
    export CLAUDE_CODE_BIN="claude --add-dir claude"
    out=$("$CS_BIN" repeated <<< "" 2>&1) || true
    assert_eq "--add-dir claude --name repeated" \
        "$(_launched "$out" args | cut -d' ' -f1-4)" "a flag that repeats the command word is kept" || return 1
    ln -sf ../versions/9.9.9 "$TEST_TMPDIR/inst/bin/c[l]aude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/inst/bin/c[l]aude --flag"
    out=$("$CS_BIN" bracketed <<< "" 2>&1) || true
    assert_eq "claude" "$(basename "$(_launched "$out" argv0)")" "a path with glob characters is linked, not expanded" || return 1
    assert_eq "--flag --name bracketed" \
        "$(_launched "$out" args | cut -d' ' -f1-3)" "the path with glob characters is not repeated as an argument" || return 1
}

# tmux names a pane after the leader of its foreground process group. A
# resume that ran claude as cs's child left cs's bash leading it, so the tab
# showed bash; when the resume is sure to land, cs runs claude in its place.
# A stub whose argv, parent and launch prompt the tests read.
_resume_session() {  # name -> prints the recorded conversation id
    local inst="$TEST_TMPDIR/inst"
    printf '#!/usr/bin/env bash\necho "argv0=$0"\necho "args=$*"\necho "parent=$(ps -o args= -p $PPID)"\necho "claim=$(cat "$CLAUDE_SESSION_META_DIR/local/lead-pid" 2>/dev/null || echo none)"\necho "marker=${CS_LEAD_CLAIM:-unset}"\n' \
        > "$inst/versions/9.9.9"
    "$CS_BIN" "$1" <<< "" > /dev/null 2>&1 || true
    awk '/^claude_session_id:/ { print $2; exit }' "$CS_SESSIONS_ROOT/$1/.cs/local/state"
}

_transcript() {  # name, uuid -> prints the transcript path cs reads
    local proj
    proj="$CS_TRANSCRIPTS_DIR/$(_encode_cwd_for_claude_test "$CS_SESSIONS_ROOT/$1")"
    mkdir -p "$proj"
    printf '%s\n' "$proj/$2.jsonl"
}

_user_record() {
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
}

# A hook knows the lead by the claim its SessionStart writes, keyed by the
# launch pid. A claim a previous launch left would speak for a later launch
# that drew the same pid, so every launch clears it before claude starts: the
# one where cs stays as claude's parent and the one where claude takes cs's
# place alike. Both say in CS_LEAD_CLAIM that they take the claim, which a
# launch by a cs from before the claim does not say.
test_a_launch_clears_the_lead_claim_a_previous_launch_left() {
    _tab_launch_env 1
    local uuid out claim="$CS_SESSIONS_ROOT/marked/.cs/local/lead-pid"
    uuid=$(_resume_session marked)
    [ -n "$uuid" ] || { echo "  FAIL: the first launch recorded no conversation"; return 1; }
    printf '1 1 stale\n' > "$claim"
    out=$("$CS_BIN" marked <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "marked" "no transcript: cs stays the parent" || return 1
    assert_eq "none" "$(_launched "$out" claim)" "a launch that stays claude's parent clears the claim" || return 1
    assert_eq "1" "$(_launched "$out" marker)" "a launch that stays claude's parent takes the claim" || return 1
    _user_record > "$(_transcript marked "$uuid")"
    printf '1 1 stale\n' > "$claim"
    out=$("$CS_BIN" marked <<< "" 2>&1) || true
    assert_output_not_contains "$(_launched "$out" parent)" "marked" "a real conversation: claude replaces cs" || return 1
    assert_eq "none" "$(_launched "$out" claim)" "a launch claude replaces clears the claim" || return 1
    assert_eq "1" "$(_launched "$out" marker)" "a launch claude replaces takes the claim" || return 1
}

# Something other than a file where the claim goes. A link (one that stays in
# the session: the open refuses one that leads out), to a file or to a
# directory, is removed, never followed, so what it names is left as it was
# and claude starts. A directory may hold what someone put there, so cs
# removes nothing: it refuses the open, names the directory, starts no claude
# and lets the session lock go.
test_a_launch_removes_a_link_and_refuses_a_directory_in_place_of_the_claim() {
    _tab_launch_env 1
    local uuid out rc=0 claim="$CS_SESSIONS_ROOT/odd/.cs/local/lead-pid" target="$CS_SESSIONS_ROOT/odd/notes.txt"
    uuid=$(_resume_session odd)
    [ -n "$uuid" ] || { echo "  FAIL: the first launch recorded no conversation"; return 1; }
    printf 'kept\n' > "$target"
    ln -s "$target" "$claim"
    out=$("$CS_BIN" odd <<< "" 2>&1) || true
    assert_eq "none" "$(_launched "$out" claim)" "a launch removes a link in place of the claim" || return 1
    assert_eq "kept" "$(cat "$target")" "the file the link names is left as it was" || return 1
    mkdir "$CS_SESSIONS_ROOT/odd/kept"
    printf 'kept\n' > "$CS_SESSIONS_ROOT/odd/kept/notes.txt"
    ln -s "$CS_SESSIONS_ROOT/odd/kept" "$claim"
    out=$("$CS_BIN" odd <<< "" 2>&1) || true
    assert_eq "none" "$(_launched "$out" claim)" "a launch removes a link to a directory in place of the claim" || return 1
    assert_eq "kept" "$(cat "$CS_SESSIONS_ROOT/odd/kept/notes.txt")" \
        "the directory the link names is left as it was" || return 1
    mkdir "$claim"
    out=$("$CS_BIN" odd <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a launch with a directory in place of the claim fails" || return 1
    assert_eq "Error: $claim is a directory, where cs keeps the lead's claim on its launch; remove it and open the session again" \
        "$(printf '%s\n' "$out" | grep '^Error: ')" "the refusal names the directory" || return 1
    assert_eq "" "$(_launched "$out" argv0)" "no claude starts" || return 1
    assert_dir "$claim" "the directory is left in place" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/odd/.cs/session.lock" "the refused open lets the session lock go" || return 1
}

test_resume_of_a_real_conversation_runs_claude_in_place_of_cs() {
    _tab_launch_env 1
    local uuid out argv0
    uuid=$(_resume_session resumer)
    [ -n "$uuid" ] || { echo "  FAIL: the first launch recorded no conversation"; return 1; }
    _user_record > "$(_transcript resumer "$uuid")"
    out=$("$CS_BIN" resumer <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" args)" "--resume $uuid" "the second open resumes" || return 1
    assert_output_not_contains "$(_launched "$out" parent)" "resumer" \
        "claude must replace cs, not run as its child" || return 1
    assert_output_contains "$(_launched "$out" args)" "/color" "the launch prompt reaches the resumed claude" || return 1
    # The seed as cs -spawn writes it (line 1 the token, line 2 the spawner),
    # opened as the spawn's own window via CS_SPAWN_TOKEN.
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'feedfacefeedfacefeedfacefeedface\n\n--- cs-spawn-brief ---\nbrief\n' > "$CS_SESSIONS_ROOT/.spawn/resumer.seed"
    out=$(CS_SPAWN_TOKEN=feedfacefeedfacefeedfacefeedface "$CS_BIN" resumer <<< "" 2>&1) || true
    assert_output_not_contains "$(_launched "$out" parent)" "resumer" "a spawned resume replaces cs too" || return 1
    assert_output_contains "$(_launched "$out" args)" "Your brief is .cs/brief.md" \
        "a spawn kick, not the colour, reaches the resumed claude" || return 1
    argv0=$(_launched "$out" argv0)
    assert_eq "claude" "$(basename "$argv0")" "the resumed claude runs under the name claude" || return 1
    [ ! -L "$argv0" ] || { echo "  FAIL: $argv0 is a symlink"; return 1; }
}

# cs stays claude's parent whenever the resume might not land, so a quick
# failure can still start a fresh conversation, and whenever cs has cleanup to
# do after claude: an encrypted session's vault waits on cs to detach it.
test_resume_that_might_not_land_keeps_cs_as_the_parent() {
    _tab_launch_env 1
    local uuid out
    uuid=$(_resume_session unsure)
    out=$("$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" "no transcript: cs stays the parent" || return 1
    echo '{"type":"launched"}' > "$(_transcript unsure "$uuid")"
    out=$("$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" "a transcript with no message: cs stays the parent" || return 1
    printf '%s\n' '{"type":"progress","data":{"message":{"type":"user","message":{"content":"hi"}}}}' \
        >> "$(_transcript unsure "$uuid")"
    out=$("$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" \
        "a user message nested in another record: cs stays the parent" || return 1
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"h' >> "$(_transcript unsure "$uuid")"
    out=$("$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" "a torn user record: cs stays the parent" || return 1
    _user_record >> "$(_transcript unsure "$uuid")"
    out=$(CLAUDE_CONFIG_DIR="" "$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" \
        "an empty CLAUDE_CONFIG_DIR: cs stays the parent" || return 1
    out=$(CLAUDE_CONFIG_DIR="$TEST_TMPDIR/other-config" "$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" \
        "claude reading another config dir: cs stays the parent" || return 1
    : > "$CS_SESSIONS_ROOT/unsure/.cs/local/vault"
    out=$("$CS_BIN" unsure <<< "" 2>&1) || true
    assert_output_contains "$(_launched "$out" parent)" "unsure" "an encrypted session: cs stays the parent" || return 1
}

# A CLAUDE_CODE_BIN with no command word cannot launch anything; the error
# names the value rather than a missing dependency.
test_claude_bin_without_a_command_is_refused_by_name() {
    local out rc=0
    out=$(CLAUDE_CODE_BIN="--permission-mode plan" "$CS_BIN" nocommand <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a flag-first CLAUDE_CODE_BIN fails" || return 1
    assert_output_contains "$out" "CLAUDE_CODE_BIN must start with a command: '--permission-mode plan'" \
        "the error names the value" || return 1
    rc=0
    out=$(CLAUDE_CODE_BIN="   " "$CS_BIN" blankcommand <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "a blank CLAUDE_CODE_BIN fails" || return 1
    assert_output_contains "$out" "CLAUDE_CODE_BIN must start with a command: '   '" "the blank value is named" || return 1
}

# An npm install resolves claude to a cli.js that loads files beside it; run
# from a hard link elsewhere it would lose them. Only the native installer's
# self-contained versions/<version> file is linked.
test_npm_shaped_claude_is_not_linked() {
    _tab_launch_env 1
    local inst="$TEST_TMPDIR/inst"
    mkdir -p "$inst/lib/node_modules/claude-code"
    cp "$inst/versions/9.9.9" "$inst/lib/node_modules/claude-code/cli.js"
    ln -sf ../lib/node_modules/claude-code/cli.js "$inst/bin/claude"
    local out
    out=$("$CS_BIN" npmclaude <<< "" 2>&1) || true
    assert_eq "$inst/bin/claude" "$(_launched "$out" argv0)" \
        "a claude that is not a versions/<version> file runs as found on PATH" || return 1
}

run_test test_launch_under_iterm_cc_shows_loader_and_icon
run_test test_npm_shaped_claude_is_not_linked
run_test test_claude_bin_without_a_command_is_refused_by_name
run_test test_a_launch_clears_the_lead_claim_a_previous_launch_left
run_test test_a_launch_removes_a_link_and_refuses_a_directory_in_place_of_the_claim
run_test test_resume_of_a_real_conversation_runs_claude_in_place_of_cs
run_test test_resume_that_might_not_land_keeps_cs_as_the_parent
run_test test_native_claude_with_flags_runs_the_link_with_its_flags
run_test test_plain_tmux_keeps_tmux_name_unless_term_is_tmux
run_test test_outside_iterm_launch_is_untouched
run_test test_iterm_integrations_off_leaves_launch_untouched
run_test test_link_follows_a_claude_update
run_test test_each_version_has_its_own_link
run_test test_home_with_a_space_runs_claude_as_found
run_test test_unlinkable_claude_still_launches
run_test test_non_native_claude_binaries_are_run_as_given
run_test test_stop_hook_bounces_dock_in_iterm
run_test test_no_bounce_outside_iterm
run_test test_no_bounce_when_disabled
run_test test_missing_it2_tool_is_silent_and_harmless
run_test test_prompt_hook_stops_the_bounce
run_test test_session_start_stops_the_bounce
run_test test_doctor_reports_iterm2_surface

report_results
