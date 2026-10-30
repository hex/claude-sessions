#!/usr/bin/env bash
# ABOUTME: Tests for cs's settings files: cs -config list|get|set|unset, the loader every reader runs,
# ABOUTME: its precedence (shell > session > machine > default), its deliveries and the readers that see a file value

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$REPO/hooks"
SL="$REPO/bin/cs-statusline"

# Each test starts from no CS_* setting at all: the files are what is under
# test, and a value the runner exported would pin the key above them. Every
# case seeds its own files under its own HOME.
setup() {
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_SESSION_*|COLORFGBG|COLORTERM|TERM_PROGRAM|ITERM_PROFILE|NO_COLOR) unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset XDG_CONFIG_HOME
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    mkdir -p "$CS_TRANSCRIPTS_DIR"
    export TERM=xterm-256color
    MCFG="$HOME/.config/cs/config"
}

teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        chmod -R u+rwx "$TEST_TMPDIR" 2>/dev/null || true
        rm -rf "$TEST_TMPDIR"
    fi
}

# cs with colour escapes dropped from both streams, stdout then stderr.
cs_plain() {
    "$CS_BIN" "$@" 2>&1 | sed "s/$(printf '\033')\[[0-9;]*m//g"
    return "${PIPESTATUS[0]}"
}

machine_cfg() {  # line...
    mkdir -p "$HOME/.config/cs"
    printf '%s\n' "$@" > "$MCFG"
}

session_cfg() {  # session_dir, line...
    local dir="$1"; shift
    mkdir -p "$dir/.cs/local"
    printf '%s\n' "$@" > "$dir/.cs/local/config"
}

# --- The loader ---------------------------------------------------------------

# A reader under set -euo pipefail goes on with the environment alone when the
# machine's file is missing, is a directory, or cannot be read: no exit, no
# word on either stream, every key at its default.
test_loader_reads_nothing_from_a_file_it_cannot_read() {
    local probe="$TEST_TMPDIR/probe.sh" out rc=0
    cat > "$probe" <<'EOF'
set -euo pipefail
. "$1"
cs_config_source CS_STATUSLINE_LAYOUT
printf '%s|%s|%s|%s\n' "${CS_STATUSLINE_LAYOUT-unset}" "$_CS_CFG_SOURCE" "$_CS_CONFIG_IGNORED" "$_CS_CONFIG_COUNT_M"
EOF
    out=$(bash "$probe" "$HOOKS/cs-config.sh" 2>&1) || rc=$?
    assert_eq "0|unset|default||0" "$rc|$out" "no file: exit 0, nothing filled, nothing said" || return 1
    mkdir -p "$MCFG"
    out=$(bash "$probe" "$HOOKS/cs-config.sh" 2>&1) || rc=$?
    assert_eq "0|unset|default||0" "$rc|$out" "a directory at the path reads as no file" || return 1
    rmdir "$MCFG"
    machine_cfg 'CS_STATUSLINE_LAYOUT=band'
    out=$(bash "$probe" "$HOOKS/cs-config.sh" 2>&1) || rc=$?
    assert_eq "0|band|machine||1" "$rc|$out" "the readable file fills the key (sensitivity)" || return 1
    chmod 000 "$MCFG"
    if [ -r "$MCFG" ]; then
        SKIP_REASON="a mode-000 file is readable here (running as root)"
        return 77
    fi
    out=$(bash "$probe" "$HOOKS/cs-config.sh" 2>&1) || rc=$?
    assert_eq "0|unset|default||0" "$rc|$out" "an unreadable file reads as no file" || return 1
    out=$(cs_plain -config get CS_STATUSLINE_LAYOUT) || rc=$?
    assert_eq "0|" "$rc|$out" "cs itself starts, and get prints the empty default" || return 1
}

# --- The verb --------------------------------------------------------------------

# A first set makes ~/.config/cs and writes the one line, and says where it
# went and when a change takes hold.
test_set_writes_a_new_machine_file() {
    local out rc=0
    out=$(cs_plain -config set CS_STATUSLINE_LAYOUT band) || rc=$?
    assert_eq "0|CS_STATUSLINE_LAYOUT=band in ~/.config/cs/config: applies at the next repaint" "$rc|$out" \
        "set says where the value went and when it applies" || return 1
    assert_eq "CS_STATUSLINE_LAYOUT=band" "$(cat "$MCFG")" "the file holds the one line" || return 1
    assert_eq "26" "$(wc -c < "$MCFG" | tr -d ' ')" "and ends in one newline" || return 1
}

# Every line a person typed stays, in order; the key's lines collapse into one,
# at the end; the same set again leaves the same bytes.
test_set_keeps_every_other_line() {
    machine_cfg '# my settings' 'CS_STATUSLINE_LAYOUT=capsules' '' 'CS_FOO=1' 'export CS_SCOPE_DISABLE=1' \
        'CS_STATUSLINE_CTX_WARN=45' 'CS_STATUSLINE_LAYOUT=quiet'
    cs_plain -config set CS_STATUSLINE_LAYOUT band > /dev/null || { echo "  FAIL: set exited non-zero"; return 1; }
    assert_eq "# my settings

CS_FOO=1
export CS_SCOPE_DISABLE=1
CS_STATUSLINE_CTX_WARN=45
CS_STATUSLINE_LAYOUT=band" "$(cat "$MCFG")" "other lines kept in order, the key once at the end" || return 1
    local before
    before=$(cat "$MCFG"; printf x)
    cs_plain -config set CS_STATUSLINE_LAYOUT band > /dev/null || { echo "  FAIL: the second set exited non-zero"; return 1; }
    assert_eq "$before" "$(cat "$MCFG"; printf x)" "the same set twice leaves the same bytes" || return 1
}

# unset removes every line of the key and keeps the rest; a key the file
# does not hold, or no file at all, changes nothing and is no error.
test_unset_removes_every_line_of_the_key() {
    local out rc=0
    out=$(cs_plain -config unset CS_STATUSLINE_LAYOUT) || rc=$?
    assert_eq "0|CS_STATUSLINE_LAYOUT is not in ~/.config/cs/config; nothing changed" "$rc|$out" "unset with no file" || return 1
    assert_not_exists "$MCFG" "unset makes no file" || return 1
    machine_cfg 'CS_STATUSLINE_LAYOUT=capsules' '# keep' 'CS_STATUSLINE_LAYOUT=band'
    out=$(cs_plain -config unset CS_STATUSLINE_LAYOUT) || rc=$?
    assert_eq "0|CS_STATUSLINE_LAYOUT removed from ~/.config/cs/config" "$rc|$out" "unset says what it removed" || return 1
    assert_eq "# keep" "$(cat "$MCFG")" "every line of the key went, the comment stayed" || return 1
    local before
    before=$(cat "$MCFG"; printf x)
    out=$(cs_plain -config unset CS_STATUSLINE_LAYOUT) || rc=$?
    assert_eq "0|CS_STATUSLINE_LAYOUT is not in ~/.config/cs/config; nothing changed" "$rc|$out" "unset of an absent key" || return 1
    assert_eq "$before" "$(cat "$MCFG"; printf x)" "and the bytes stay" || return 1
}

# Each refusal names the key and what it takes, exits 1 and writes nothing.
_refused() {  # expected message, cs arguments...
    local want="$1" out rc=0
    shift
    out=$(cs_plain "$@") || rc=$?
    assert_eq "1|Error: $want" "$rc|$out" "cs $*" || return 1
}

test_set_refuses_what_no_reader_takes() {
    machine_cfg '# untouched'
    local before key reason
    before=$(cat "$MCFG")
    _refused "CS_FOO is not a cs setting; cs -config list names every one" -config set CS_FOO 1 || return 1
    while IFS='|' read -r key reason; do
        _refused "$key is not kept in cs's config: $reason. Export it in your shell." -config set "$key" x || return 1
    done <<'EOF2'
CS_SECRETS_PASSWORD|it is a secret, and the file is plain text
CLAUDE_CODE_BIN|it names a program cs runs, which a file a plugin can write must not choose
CS_TMUX_BIN|it names a program cs runs, which a file a plugin can write must not choose
CS_REWRITE_CMD|it names a program cs runs, which a file a plugin can write must not choose
CS_REAL_EDITOR|it names a program cs runs, which a file a plugin can write must not choose
CS_SESSIONS_ROOT|it names where every session lives, and each process keys on it
CS_SECRETS_BACKEND|it moves where cs-secrets looks, and every stored secret would vanish from view until it moved back
CS_PLATFORM_OVERRIDE|it moves where cs-secrets looks, and every stored secret would vanish from view until it moved back
CS_USAGE_DIR|it names a directory the status line writes to
CS_ACTOR|identity has its own per-session file, .cs/local/identity, which outranks a machine-wide name
EOF2
    _refused "CS_STATUSLINE_CAPS is not kept in cs's config: it has its own record, which cs -statusline caps on|off|ask writes. Export it in your shell." \
        -config set CS_STATUSLINE_CAPS 1 || return 1
    _refused "CS_STATUSLINE_LAYOUT is quiet, band or capsules; got bands" -config set CS_STATUSLINE_LAYOUT bands || return 1
    _refused "CS_STATUSLINE_SEGMENTS is a comma-separated list of logo, session, notes, mail, pane, git, model, ctx, limits, fable and cost, each at most once; got logo,logo" \
        -config set CS_STATUSLINE_SEGMENTS logo,logo || return 1
    _refused "CS_STATUSLINE_BAND is a palette name, brand, periwinkle, session, none or r;g;b; got magenta" -config set CS_STATUSLINE_BAND magenta || return 1
    _refused "CS_STATUSLINE_COLS is a column count from 1 to 9999; got 080" -config set CS_STATUSLINE_COLS 080 || return 1
    _refused "CS_STATUSLINE_CTX_WARN is a whole number of 1 to 3 digits; got 1000" -config set CS_STATUSLINE_CTX_WARN 1000 || return 1
    _refused "CS_SCOPE_BUDGET_MS is a whole number of milliseconds of 1 to 7 digits (0 skips the scan); got 12345678" \
        -config set CS_SCOPE_BUDGET_MS 12345678 || return 1
    _refused "CS_NARRATIVE_MAX_BYTES is a byte count above 0 of at most 15 digits; got 0" -config set CS_NARRATIVE_MAX_BYTES 0 || return 1
    _refused "CS_ROTATE_FORCE_CTX is off, 0 or a percentage from 1 to 100; got 101" -config set CS_ROTATE_FORCE_CTX 101 || return 1
    _refused "CS_REWRITE_PROVIDER is claude, claude-api, openai, openai-api, gemini, gemini-api, grok or xai; got grok-api" \
        -config set CS_REWRITE_PROVIDER grok-api || return 1
    _refused "CS_REWRITE_MODEL is a model name of letters, digits and . _ : / -, starting with a letter or digit, at most 128 characters; got -x" \
        -config set CS_REWRITE_MODEL -x || return 1
    _refused "CS_TERM_BG_RGB is r;g;b, each 0 to 255; got 1;2;256" -config set CS_TERM_BG_RGB '1;2;256' || return 1
    _refused "CS_SCOPE_DISABLE is 1 (on) or 0 (off); got yes" -config set CS_SCOPE_DISABLE yes || return 1
    _refused "CS_REWRITE_TIMEOUT is a whole number of seconds of 1 to 7 digits; got 2s" -config set CS_REWRITE_TIMEOUT 2s || return 1
    _refused "CS_SCOPE_DISABLE takes a value; cs -config unset CS_SCOPE_DISABLE removes it" -config set CS_SCOPE_DISABLE '' || return 1
    _refused "CS_STATUSLINE_BAND is a palette name, brand, periwinkle, session, none or r;g;b; got red?x" \
        -config set CS_STATUSLINE_BAND "red$(printf '\t')x" || return 1
    _refused "CS_STATUSLINE_BAND is a palette name, brand, periwinkle, session, none or r;g;b; got red?x" \
        -config set CS_STATUSLINE_BAND "red
x" || return 1
    _refused "Usage: cs [<name>] -config list [--porcelain] | get <KEY> | set <KEY> <value> | unset <KEY>" -config set CS_SCOPE_DISABLE || return 1
    _refused "Usage: cs [<name>] -config list [--porcelain] | get <KEY> | set <KEY> <value> | unset <KEY>" -config || return 1
    _refused "CS_FOO is not a cs setting; cs -config list names every one" -config get CS_FOO || return 1
    _refused "CS_ACTOR is not kept in cs's config: identity has its own per-session file, .cs/local/identity, which outranks a machine-wide name. Export it in your shell." \
        -config unset CS_ACTOR || return 1
    assert_eq "$before" "$(cat "$MCFG")" "no refusal wrote the file" || return 1
}

# The named form writes the session's own file, after the session's vet: a
# session whose .cs/local git tracks a file, or whose config is a link out,
# is refused before anything is written.
test_named_set_writes_the_session_file() {
    local dir out rc=0 outside="$TEST_TMPDIR/outside"
    dir=$(create_test_session_with_git alpha)
    out=$(cs_plain alpha -config set CS_SCOPE_DISABLE 1) || rc=$?
    assert_eq "0|CS_SCOPE_DISABLE=1 in alpha/.cs/local/config: applies at your next prompt" "$rc|$out" "the named set says the session's file" || return 1
    assert_eq "CS_SCOPE_DISABLE=1" "$(cat "$dir/.cs/local/config")" "the session's file holds the line" || return 1
    assert_not_exists "$MCFG" "the machine's file is not written" || return 1
    _refused "No such session: nosuch" nosuch -config set CS_SCOPE_DISABLE 1 || return 1
    rm "$dir/.cs/local/config"
    printf 'theirs\n' > "$outside"
    ln -s "$outside" "$dir/.cs/local/config"
    out=$(cs_plain alpha -config set CS_SCOPE_DISABLE 1) || rc=$?
    assert_eq "1" "$rc" "a config linked out of the session is refused; output: $out" || return 1
    assert_eq "Error: .cs/local/config is a symlink to $outside, outside the session, and cs writes through it. Replace it with a real file or directory, or cs -rm the session." "$out" \
        "the vet names the link" || return 1
    assert_eq "theirs" "$(cat "$outside")" "the link's target is unchanged" || return 1
    rm "$dir/.cs/local/config"
    printf 'x\n' > "$dir/.cs/local/state"
    (cd "$dir" && git add -f .cs/local/state && git commit -q -m "track local state")
    rc=0
    out=$(cs_plain alpha -config set CS_SCOPE_DISABLE 1) || rc=$?
    assert_eq "1" "$rc" "a session whose .cs/local git tracks is refused; output: $out" || return 1
    assert_eq "Error: .cs/local/state is tracked in git (per-actor state must stay local). Fix with: git -C $dir --literal-pathspecs rm -r --cached -- .cs/local && git -C $dir commit -m 'stop tracking .cs/local'" "$out" \
        "the refusal names the tracked file and the fix" || return 1
    assert_not_exists "$dir/.cs/local/config" "nothing is written" || return 1
}

# Precedence: the environment over the session's file over the machine's over
# nothing. A session's 0 turns a machine's 1 off for both reader shapes.
test_get_follows_the_precedence() {
    local dir
    dir=$(create_test_session alpha)
    machine_cfg 'CS_STATUSLINE_CTX_WARN=45' 'CS_NO_MAIL_WAKE=1'
    session_cfg "$dir" 'CS_STATUSLINE_CTX_WARN=50' 'CS_NO_MAIL_WAKE=0'
    assert_eq "55" "$(CS_STATUSLINE_CTX_WARN=55 cs_plain alpha -config get CS_STATUSLINE_CTX_WARN)" "the shell wins" || return 1
    assert_eq "50" "$(cs_plain alpha -config get CS_STATUSLINE_CTX_WARN)" "the session's file next" || return 1
    assert_eq "50" "$(CLAUDE_SESSION_DIR="$dir" cs_plain -config get CS_STATUSLINE_CTX_WARN)" \
        "inside the session the session's file counts" || return 1
    assert_eq "45" "$(cs_plain -config get CS_STATUSLINE_CTX_WARN)" "outside any session the machine's" || return 1
    assert_eq "" "$(cs_plain alpha -config get CS_NO_MAIL_WAKE)" "a session 0 reads as unset" || return 1
    assert_eq "1" "$(cs_plain -config get CS_NO_MAIL_WAKE)" "the machine's 1 stands outside it" || return 1
    rm "$MCFG"
    local out rc=0
    out=$(cs_plain -config get CS_STATUSLINE_CTX_WARN) || rc=$?
    assert_eq "0|" "$rc|$out" "nothing sets it: empty, exit 0" || return 1
}

# The porcelain is the one record the panel and the cs mod parse: one line per
# allowed key, table order, eleven tab-separated fields, nothing else.
_porcelain_world() {
    local dir
    dir=$(create_test_session alpha)
    machine_cfg '# machine settings' 'CS_STATUSLINE_LAYOUT=band' 'CS_STATUSLINE_CTX_WARN=45' \
        'CS_STATUSLINE_BAND=magenta' 'CS_NO_MAIL_WAKE=1' 'CS_FOO=1'
    session_cfg "$dir" 'CS_STATUSLINE_CTX_WARN=50' 'CS_NO_MAIL_WAKE=0' 'CS_SCOPE_DISABLE=1' 'CS_ROTATE_FORCE_CTX=101'
}

test_list_porcelain_equals_the_golden_record() {
    _porcelain_world
    local out rc=0
    out=$(CS_STATUSLINE_FRAME=6 CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 "$CS_BIN" alpha -config list --porcelain 2>"$TEST_TMPDIR/err") || rc=$?
    assert_eq "0" "$rc" "list --porcelain exits 0" || return 1
    assert_eq "" "$(cat "$TEST_TMPDIR/err")" "and says nothing on stderr" || return 1
    assert_eq "$(cat "$SCRIPT_DIR/fixtures/config-porcelain.txt")" "$out" "stdout is the golden record" || return 1
    assert_eq "41" "$(printf '%s\n' "$out" | awk -F'\t' 'NF == 11' | wc -l | tr -d ' ')" "41 records of 11 fields" || return 1
}

# The human listing: every group, every key with its value, source and when,
# the note where the shell hides a file value, and the skipped lines.
test_list_prints_the_table_and_the_skipped_lines() {
    _porcelain_world
    local out
    out=$(CS_STATUSLINE_CTX_WARN=60 cs_plain alpha -config list) || { echo "  FAIL: list exited non-zero: $out"; return 1; }
    assert_eq "Status line" "$(printf '%s\n' "$out" | sed -n 1p)" "the first group heading" || return 1
    assert_eq "  CS_STATUSLINE_LAYOUT            band          machine  now" \
        "$(printf '%s\n' "$out" | grep '^  CS_STATUSLINE_LAYOUT ')" "a machine row" || return 1
    assert_eq "  CS_STATUSLINE_CTX_WARN          60            shell    now        (alpha/.cs/local/config has 50; your environment wins)" \
        "$(printf '%s\n' "$out" | grep '^  CS_STATUSLINE_CTX_WARN ')" "a shell row hiding a session value" || return 1
    assert_eq "  CS_SCOPE_DISABLE                1             session  now" \
        "$(printf '%s\n' "$out" | grep '^  CS_SCOPE_DISABLE ')" "a session row" || return 1
    assert_eq "  CS_STATUSLINE_BAND              session       default  now" \
        "$(printf '%s\n' "$out" | grep '^  CS_STATUSLINE_BAND ')" "a default row shows the default" || return 1
    assert_eq "Ignored in ~/.config/cs/config
  line 4: CS_STATUSLINE_BAND=magenta: not a palette name, brand, periwinkle, session, none or r;g;b
  line 6: CS_FOO=1: not a cs setting
Ignored in alpha/.cs/local/config
  line 4: CS_ROTATE_FORCE_CTX=101: not off, 0 or a percentage from 1 to 100" \
        "$(printf '%s\n' "$out" | sed -n '/^Ignored in /,$p')" "the skipped lines, file by file, at the end" || return 1
    assert_eq "Status line|Prompts|Turn end|Rotation|Rewriter (ctrl+g)|Terminal|Launch|Ignored in ~/.config/cs/config|Ignored in alpha/.cs/local/config" \
        "$(printf '%s\n' "$out" | grep '^[A-Z]' | paste -sd '|' -)" "the seven groups in table order, then the two files' skips" || return 1
    local rc=0
    out=$(cs_plain -config list) || rc=$?
    assert_eq "0|Status line|Prompts|Turn end|Rotation|Rewriter (ctrl+g)|Terminal|Launch|Ignored in ~/.config/cs/config" \
        "$rc|$(printf '%s\n' "$out" | grep '^[A-Z]' | paste -sd '|' -)" "outside any session: the machine's file alone" || return 1
}

# Two sets of different keys started together both land: the writer takes the
# file's lock.
test_concurrent_sets_both_land() {
    "$CS_BIN" -config set CS_STATUSLINE_LAYOUT band > /dev/null 2>&1 &
    local a=$!
    "$CS_BIN" -config set CS_SCOPE_DISABLE 1 > /dev/null 2>&1 &
    local b=$!
    wait "$a" || { echo "  FAIL: the first set failed"; return 1; }
    wait "$b" || { echo "  FAIL: the second set failed"; return 1; }
    assert_eq "CS_SCOPE_DISABLE=1
CS_STATUSLINE_LAYOUT=band" "$(LC_ALL=C sort "$MCFG")" "both lines landed" || return 1
}

# The verb and the loader under macOS's bash 3.2, which cs supports: /bin
# first on PATH, so cs's env bash is that one.
test_verb_runs_under_bash_32() {
    case "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" in
        3) ;;
        *) SKIP_REASON="no bash 3 at /bin/bash"; return 77 ;;
    esac
    _porcelain_world
    local out rc=0
    out=$(PATH="/bin:$PATH" CS_STATUSLINE_FRAME=6 CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 \
        "$CS_BIN" alpha -config list --porcelain 2>&1) || rc=$?
    assert_eq "0" "$rc" "list --porcelain exits 0 under bash 3.2: $out" || return 1
    assert_eq "$(cat "$SCRIPT_DIR/fixtures/config-porcelain.txt")" "$out" "the same record under bash 3.2" || return 1
    out=$(PATH="/bin:$PATH" cs_plain alpha -config set CS_STATUSLINE_LAYOUT capsules) || rc=$?
    assert_eq "0|CS_STATUSLINE_LAYOUT=capsules in alpha/.cs/local/config: applies at the next repaint" "$rc|$out" "set under bash 3.2" || return 1
    assert_eq "capsules" "$(PATH="/bin:$PATH" cs_plain alpha -config get CS_STATUSLINE_LAYOUT)" "get under bash 3.2" || return 1
}

# --- Readers ---------------------------------------------------------------------

SL_JSON='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":10}}'

# One status line repaint in a bare environment: the test's HOME (where the
# machine's file lives) and the given VAR=value pairs, nothing inherited.
sl_run() {  # VAR=value...
    printf '%s' "$SL_JSON" | env -i PATH="$PATH" HOME="$HOME" TERM=xterm-256color COLORTERM=truecolor \
        CS_SESSIONS_ROOT="$CS_SESSIONS_ROOT" CS_STATUSLINE_NOW=1000 "$@" "$SL"
}

# A theme in a file is a pin over the launch's measurement: the bar draws as a
# shell pin of that theme would, and the measured background of the other
# theme no longer tints it.
test_a_file_theme_wins_over_the_launch_measurement() {
    local filed light dark
    machine_cfg 'CS_TERM_THEME=light'
    filed=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 'CS_TERM_BG_RGB=30;30;30')
    rm "$MCFG"
    light=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=light)
    dark=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 'CS_TERM_BG_RGB=30;30;30')
    [ -n "$light" ] || { echo "  FAIL: the light render is empty"; return 1; }
    [ "$dark" != "$light" ] || { echo "  FAIL: the dark measurement draws as light; nothing here would tell them apart"; return 1; }
    assert_eq "$light" "$filed" "the file's light draws as a light pin, untinted by 30;30;30" || return 1
}

# A measurement the loader did not fill stays: a file that sets other keys
# leaves the launch's light theme as it found it.
test_the_launch_measurement_stands_without_a_file_theme() {
    local kept dark light
    machine_cfg 'CS_STATUSLINE_CTX_WARN=40'
    kept=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=light CS_TERM_THEME_AUTO=1)
    light=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=light)
    dark=$(sl_run CS_STATUSLINE_LAYOUT=capsules CS_TERM_THEME=dark)
    [ "$dark" != "$light" ] || { echo "  FAIL: light and dark draw alike; nothing here would tell them apart"; return 1; }
    assert_eq "$light" "$kept" "the measured light still draws light" || return 1
}

# An edit reaches the next repaint: the same bar, its file rewritten between
# two renders, draws the second layout the second time.
test_the_status_line_follows_a_file_edit() {
    local first second band
    machine_cfg 'CS_STATUSLINE_LAYOUT=quiet'
    first=$(sl_run CS_TERM_THEME=light)
    machine_cfg 'CS_STATUSLINE_LAYOUT=band'
    second=$(sl_run CS_TERM_THEME=light)
    rm "$MCFG"
    band=$(sl_run CS_TERM_THEME=light CS_STATUSLINE_LAYOUT=band)
    [ "$first" != "$band" ] || { echo "  FAIL: quiet and band draw alike; nothing here would tell them apart"; return 1; }
    assert_eq "$band" "$second" "the repaint after the edit draws the band" || return 1
}

_scope_prompt() {  # session_dir
    CLAUDE_SESSION_DIR="$1" CLAUDE_SESSION_NAME="${1##*/}" CLAUDE_SESSION_META_DIR="$1/.cs" CS_SCOPE_BUDGET_MS=600000 \
        bash "$HOOKS/scope-prompt.sh" <<< '{"prompt":"look at the readme","hook_event_name":"UserPromptSubmit","session_id":"sid-test"}'
}

# scope-prompt.sh reads CS_SCOPE_TRACE_DISABLE for its launch mark before it
# loads any library, so it loads the settings first: a session file's 1
# leaves no trace at all.
test_scope_prompt_sees_a_session_file_before_its_launch_mark() {
    local dir
    dir=$(create_test_session_with_git alpha)
    session_cfg "$dir" 'CS_SCOPE_TRACE_DISABLE=1'
    _scope_prompt "$dir" > /dev/null 2>&1
    assert_not_exists "$dir/.cs/local/scope-prompt.trace" "the session's file turned the trace off" || return 1
    rm "$dir/.cs/local/config"
    _scope_prompt "$dir" > /dev/null 2>&1
    assert_file_exists "$dir/.cs/local/scope-prompt.trace" "without it the hook traces (sensitivity)" || return 1
}

# The ctrl+g shim and its child read the provider from the session's file: the
# shim hands the buffer to the vendor rewriter, and the vendor rewriter names
# the engine the file chose.
test_the_rewriter_and_its_child_read_the_file() {
    local dir hooks="$TEST_TMPDIR/hooks" f rc=0 out
    dir=$(create_test_session alpha)
    mkdir -p "$hooks"
    cp "$HOOKS/prompt-rewriter.sh" "$HOOKS/cs-config.sh" "$HOOKS/cs-shared.sh" "$hooks/"
    for f in vendor model; do
        printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\n[ "${1:-}" = --label ] && exit 0\nprintf "%s: %%s" "$(cat)"\n' \
            "$f" "$TEST_TMPDIR/rewriters.log" "$f" > "$hooks/prompt-rewriter-$f.sh"
        chmod +x "$hooks/prompt-rewriter-$f.sh"
    done
    session_cfg "$dir" 'CS_REWRITE_PROVIDER=openai-api'
    f="$TEST_TMPDIR/claude-prompt-11111111-2222-3333-4444-555555555555.md"
    printf 'make it better' > "$f"
    CLAUDE_SESSION_DIR="$dir" bash "$hooks/prompt-rewriter.sh" "$f" < /dev/null > /dev/null 2>&1 || rc=$?
    assert_eq "0|vendor: make it better" "$rc|$(cat "$f")" "the shim took the vendor rewriter the file named" || return 1
    assert_eq "vendor --label
vendor " "$(cat "$TEST_TMPDIR/rewriters.log")" "and only the vendor rewriter ran" || return 1
    rm "$dir/.cs/local/config"
    printf 'make it better' > "$f"
    CLAUDE_SESSION_DIR="$dir" bash "$hooks/prompt-rewriter.sh" "$f" < /dev/null > /dev/null 2>&1
    assert_eq "model: make it better" "$(cat "$f")" "without the file the default rewriter runs (sensitivity)" || return 1
    session_cfg "$dir" 'CS_REWRITE_PROVIDER=gemini-api'
    out=$(CLAUDE_SESSION_DIR="$dir" GEMINI_API_KEY=not-a-real-key PATH=/usr/bin:/bin bash "$HOOKS/prompt-rewriter-vendor.sh" --label) || rc=$?
    assert_eq "0|api · gemini-flash-lite-latest" "$rc|$out" "the vendor child names the engine the file chose" || return 1
    rm "$dir/.cs/local/config"
    rc=0
    out=$(CLAUDE_SESSION_DIR="$dir" GEMINI_API_KEY=not-a-real-key PATH=/usr/bin:/bin bash "$HOOKS/prompt-rewriter-vendor.sh" --label) || rc=$?
    assert_eq "1|" "$rc|$out" "without the file it names none (sensitivity)" || return 1
}

# The launch reads the target session's file for its own decisions, and
# hands claude none of the file's values: claude's children read the files
# themselves, and a value claude inherited would pin the key over every later
# edit. The terminal is measured dark; the session's file says light.
test_the_launch_hands_claude_no_file_value() {
    local dir stub="$TEST_TMPDIR/claude-stub" got="$TEST_TMPDIR/claude-env" k
    dir=$(create_test_session_with_git alpha)
    {
        echo '#!/usr/bin/env bash'
        echo '{'
        for k in CS_NO_TASK_TOOLS CS_STATUSLINE_LAYOUT CS_TERM_THEME CS_TERM_THEME_AUTO CLAUDE_CODE_ENABLE_TODO_TOOLS; do
            printf "    printf '%s=%%s\\\\n' \"\${%s-<unset>}\"\n" "$k" "$k"
        done
        printf '} > "%s"\n' "$got"
    } > "$stub"
    chmod +x "$stub"
    machine_cfg 'CS_STATUSLINE_LAYOUT=band'
    session_cfg "$dir" 'CS_NO_TASK_TOOLS=1' 'CS_TERM_THEME=light'
    CLAUDE_CODE_BIN="$stub" CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1 CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 \
        "$CS_BIN" alpha <<< "" > "$TEST_TMPDIR/launch.out" 2>&1 || { echo "  FAIL: the launch failed"; cat "$TEST_TMPDIR/launch.out"; return 1; }
    assert_eq "CS_NO_TASK_TOOLS=<unset>
CS_STATUSLINE_LAYOUT=<unset>
CS_TERM_THEME=<unset>
CS_TERM_THEME_AUTO=<unset>
CLAUDE_CODE_ENABLE_TODO_TOOLS=<unset>" "$(cat "$got")" "the file decided the launch, and claude inherits none of it" || return 1
    rm "$dir/.cs/local/config" "$MCFG"
    CLAUDE_CODE_BIN="$stub" CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1 CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 \
        "$CS_BIN" alpha <<< "" > "$TEST_TMPDIR/launch.out" 2>&1 || { echo "  FAIL: the second launch failed"; cat "$TEST_TMPDIR/launch.out"; return 1; }
    assert_eq "CS_NO_TASK_TOOLS=<unset>
CS_STATUSLINE_LAYOUT=<unset>
CS_TERM_THEME=dark
CS_TERM_THEME_AUTO=1
CLAUDE_CODE_ENABLE_TODO_TOOLS=1" "$(cat "$got")" "without the files the measurement and the opt-in go through (sensitivity)" || return 1
}

# Which scripts must load the settings is derived from the allow-list: every
# script under hooks/ and bin/ that reads an allowed ${CS_KEY loads them first,
# at its top level (sourcing cs-config.sh, cs-shared.sh or cs-statusline), or
# carries the status line's spliced block.
test_every_reader_loads_the_settings_before_its_first_read() {
    local keys f got read load bad=""
    keys=$(sed -n "/^_CS_CONFIG_SPEC=(/,/^)/s/^    '\(CS_[A-Z0-9_]*\)|.*/\1/p" "$REPO/lib/03-config.sh" | paste -sd'|' -)
    assert_eq "41" "$(printf '%s\n' "$keys" | awk -F'|' '{ print NF }')" "the allow-list's 41 keys" || return 1
    for f in "$REPO"/hooks/*.sh "$REPO"/bin/cs-statusline "$REPO"/bin/cs-subagent-statusline "$REPO"/bin/cs-secrets; do
        case "${f##*/}" in cs-config.sh|cs-shared.sh) continue ;; esac
        got=$(awk -v keys="$keys" '
            BEGIN { re = "\\$\\{(" keys ")[:}=+-]" }
            /^# >>> lib\/03-config\.sh/ && !load { load = NR }
            /^[^[:space:]#]/ && /(^|[;&| ] *)(\.|source) / && /cs-config\.sh|cs-shared\.sh|cs-statusline|\$_cs_config|\$_cs_shared/ && !load { load = NR }
            !/^[[:space:]]*#/ && $0 ~ re && !read { read = NR }
            END { print read + 0, load + 0 }' "$f")
        read=${got% *}
        load=${got#* }
        [ "$read" -gt 0 ] || continue
        if [ "$load" -eq 0 ] || [ "$load" -gt "$read" ]; then
            bad="$bad ${f##*/}:read=$read,load=$load"
        fi
    done
    assert_eq "" "$bad" "every reader loads the settings before its first read" || return 1
}

# --- Doctor and uninstall -----------------------------------------------------------

# Doctor reads the same loader: a skipped line is a warning naming the file,
# the line and why; a shell value that hides a file's is said; the count row
# names both files; an Authority row says where its switch comes from.
test_doctor_names_skipped_lines_and_hidden_values() {
    local dir out
    dir=$(create_test_session alpha)
    machine_cfg 'CS_STATUSLINE_BAND=magenta' 'CS_STATUSLINE_CTX_WARN=45' 'CS_NO_MAIL_WAKE=1'
    session_cfg "$dir" 'CS_SCOPE_DISABLE=1'
    out=$(CS_STATUSLINE_CTX_WARN=50 CLAUDE_SESSION_DIR="$dir" CLAUDE_SESSION_META_DIR="$dir/.cs" CLAUDE_SESSION_NAME=alpha \
        cs_plain -doctor) || true
    assert_eq "  [ OK ] config: 2 settings in ~/.config/cs/config, 1 in this session's
  [WARN] config: ~/.config/cs/config line 1: CS_STATUSLINE_BAND=magenta: not a palette name, brand, periwinkle, session, none or r;g;b (skipped)
  [INFO] config: CS_STATUSLINE_CTX_WARN=50 in your environment hides 45 in ~/.config/cs/config" \
        "$(printf '%s\n' "$out" | grep -E '^  \[[A-Z ]{4}\] config: ')" "the config rows" || return 1
    assert_eq "off grounding scope-prompt off: CS_SCOPE_DISABLE=1 (this session's config)" \
        "$(printf '%s\n' "$out" | awk '$2 == "grounding" {$1=$1; print}')" "the Authority row names the session's file" || return 1
    assert_eq "on clarify scope-prompt off: CS_CLARIFY_DISABLE=1" \
        "$(printf '%s\n' "$out" | awk '$2 == "clarify" {$1=$1; print}')" "a default row names no source" || return 1
    rm "$MCFG" "$dir/.cs/local/config"
    out=$(cs_plain -doctor) || true
    assert_eq "  [ OK ] config: no ~/.config/cs/config (cs -config set keeps one)" \
        "$(printf '%s\n' "$out" | grep -E '^  \[[A-Z ]{4}\] config: ')" "no file, outside a session" || return 1
}

# Uninstall keeps the settings file, as it keeps statusline-caps: a reinstall
# should find the person's settings.
test_uninstall_keeps_the_settings_file() {
    local stub="$TEST_TMPDIR/mount-stub" out rc=0 f
    mkdir -p "$HOME/.local/bin" "$HOME/.claude"
    for f in cs cs-secrets cs-statusline cs-subagent-statusline; do
        printf '#!/bin/sh\n' > "$HOME/.local/bin/$f"
        chmod +x "$HOME/.local/bin/$f"
    done
    machine_cfg 'CS_STATUSLINE_LAYOUT=band'
    _stub_mount_table "$stub" "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" || return 1
    out=$(printf 'ynnn' | PATH="$stub:$PATH" cs_plain -uninstall) || rc=$?
    assert_eq "0" "$rc" "uninstall completes: $out" || return 1
    assert_not_exists "$HOME/.local/bin/cs" "cs is gone" || return 1
    assert_eq "CS_STATUSLINE_LAYOUT=band" "$(cat "$MCFG")" "the settings file is kept as it was" || return 1
    assert_eq "Kept ~/.config/cs/config (your cs settings; delete it to forget them)" \
        "$(printf '%s\n' "$out" | grep '^Kept ~/.config/cs/config')" "and uninstall says so" || return 1
}

# --- Deliveries -----------------------------------------------------------------

# build.sh delivers lib/03-config.sh into the status line between two marker
# lines: the block is the fragment without its ABOUTME header, a second build
# changes nothing, and the committed status line is what the build writes.
test_build_splices_the_fragment_into_the_status_line() {
    local repo="$TEST_TMPDIR/build" d first
    mkdir -p "$repo/bin"
    cp -R "$REPO/lib" "$repo/lib"
    cp "$REPO/build.sh" "$REPO/install.sh.in" "$repo/"
    for d in hooks commands skills mods completions; do
        cp -R "$REPO/$d" "$repo/$d"
    done
    cp -p "$REPO/bin/cs-secrets" "$REPO/bin/cs-statusline" "$REPO/bin/cs-subagent-statusline" "$repo/bin/"
    rm -f "$repo/hooks/cs-config.sh" "$repo/hooks/cs-shared.sh"
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: build.sh failed"; return 1; }
    first=$(cat "$repo/bin/cs-statusline")
    (cd "$repo" && bash build.sh > /dev/null) || { echo "  FAIL: the second build.sh failed"; return 1; }
    assert_eq "$first" "$(cat "$repo/bin/cs-statusline")" "a second build leaves the status line as the first wrote it" || return 1
    assert_eq "$(sed '/^# ABOUTME:/d' "$REPO/lib/03-config.sh" | sed '1{/^$/d;}')" \
        "$(awk '/^# >>> lib\/03-config.sh/{f=1;next} /^# <<< lib\/03-config.sh/{f=0} f' "$repo/bin/cs-statusline")" \
        "the block is lib/03-config.sh without its header" || return 1
    [ -x "$repo/bin/cs-statusline" ] || { echo "  FAIL: the spliced status line lost its exec bit"; return 1; }
    assert_eq "$(cat "$REPO/bin/cs-statusline")" "$first" "the committed status line is the build's (run ./build.sh)" || return 1
    assert_eq "$(cat "$REPO/hooks/cs-config.sh")" "$(cat "$repo/hooks/cs-config.sh")" \
        "the committed hooks/cs-config.sh is the build's" || return 1
    assert_eq "$(cat "$REPO/lib/02-shared.sh" "$REPO/lib/03-config.sh")" "$(sed '1,2d' "$repo/hooks/cs-shared.sh")" \
        "hooks/cs-shared.sh carries both shared fragments" || return 1
}

echo ""
echo "cs -config tests"
echo "================"
echo ""

run_test test_loader_reads_nothing_from_a_file_it_cannot_read
run_test test_set_writes_a_new_machine_file
run_test test_set_keeps_every_other_line
run_test test_unset_removes_every_line_of_the_key
run_test test_set_refuses_what_no_reader_takes
run_test test_named_set_writes_the_session_file
run_test test_get_follows_the_precedence
run_test test_list_porcelain_equals_the_golden_record
run_test test_list_prints_the_table_and_the_skipped_lines
run_test test_concurrent_sets_both_land
run_test test_verb_runs_under_bash_32
run_test test_a_file_theme_wins_over_the_launch_measurement
run_test test_the_launch_measurement_stands_without_a_file_theme
run_test test_the_status_line_follows_a_file_edit
run_test test_scope_prompt_sees_a_session_file_before_its_launch_mark
run_test test_the_rewriter_and_its_child_read_the_file
run_test test_the_launch_hands_claude_no_file_value
run_test test_every_reader_loads_the_settings_before_its_first_read
run_test test_doctor_names_skipped_lines_and_hidden_values
run_test test_uninstall_keeps_the_settings_file
run_test test_build_splices_the_fragment_into_the_status_line

report_results
