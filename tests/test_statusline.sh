#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-statusline, the Claude Code capsule statusline
# ABOUTME: Covers segment rendering, ordering, thresholds, color ladder, and defensive fallbacks

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SL="$SCRIPT_DIR/../bin/cs-statusline"
# Every cs launch exports CS_BIN (the installed cs), so a run from inside a cs
# session inherits one: this suite tests the checkout's cs, and setup() unsets
# every exported CS_* variable, which would leave CS_BIN unbound. Drop the
# inherited export before assigning, so the assignment stays shell-local.
unset CS_BIN
CS_BIN="$SCRIPT_DIR/../bin/cs"

# The docs' example statusline JSON, verbatim values (session_name "my-session",
# ctx 8%, Opus/high, 5h 23.5, wk 41.2, cost 0.01234, non-git current_dir).
FIXTURE_DOCS='{"cwd":"/current/working/directory","session_id":"abc123","session_name":"my-session","model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"/current/working/directory","project_dir":"/orig"},"cost":{"total_cost_usd":0.01234},"context_window":{"used_percentage":8},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}'

# --- Setup / teardown: isolate from ambient cs/Claude env and terminal vars ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR|TMUX|TMUX_PANE|COLORFGBG|ITERM_PROFILE|LC_TERMINAL|SSH_CONNECTION)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    # The render no longer reads COLUMNS, but unset it anyway so no test can
    # accidentally depend on the ambient terminal's width.
    unset COLUMNS 2>/dev/null || true
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    # A private HOME per test: the render keeps its caches (git line, tmux
    # ancestry verdict, org id) under ~/.cache/cs, keyed on values that many
    # tests here share (a fake TMUX server pid, this runner's parent pid), so a
    # suite-wide HOME would let one test's verdict answer the next.
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # Neutral terminal by default; per-test overrides as needed.
    export TERM="xterm-256color"
    # Pin the theme so render tests are deterministic regardless of the runner's
    # OS appearance: _sl_detect_theme now reads the live macOS appearance when
    # CS_TERM_THEME is unset, which setup() strips above. The theme-resolution
    # tests unset this in their own subshells to exercise the live path.
    export CS_TERM_THEME="light"
    # Fail closed on credentials, on BOTH readers: a test that forgets to
    # install the shims must read nothing, never the developer's real Claude
    # Code token. CS_SECURITY_BIN closes the Keychain path; CLAUDE_CONFIG_DIR
    # closes the plaintext one, which would otherwise fall back to
    # $HOME/.claude/.credentials.json — the live credential on every Linux box
    # and on any Mac that has written one.
    export CS_SECURITY_BIN="$TEST_TMPDIR/no-such-security"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/no-such-config"
    # The capsule pins below were written for rounded caps, which the renderer
    # draws only once this machine has answered the install question. Answer
    # it here; the caps tests remove or rewrite the file for their own cases.
    export XDG_CONFIG_HOME="$TEST_TMPDIR/xdg"
    mkdir -p "$XDG_CONFIG_HOME/cs"
    printf 'on\n' > "$XDG_CONFIG_HOME/cs/statusline-caps"
    # The capsule pins below predate the band and the quiet layout, which is
    # the default; the band and quiet tests export their layout by name in
    # band_env and quiet_env.
    export CS_STATUSLINE_LAYOUT=capsules
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset COLORFGBG 2>/dev/null || true
    unset CS_SESSIONS_ROOT CLAUDE_SESSION_NAME NO_COLOR COLORTERM TERM_PROGRAM \
        FORCE_COLOR CS_STATUSLINE_DISABLE CS_STATUSLINE_SEGMENTS CS_STATUSLINE_CTX_WARN \
        CS_STATUSLINE_CTX_CRIT CS_DISCOVERIES_MAX_SIZE COLUMNS CS_TERM_BG_RGB \
        CS_USAGE_DIR CS_USAGE_NO_REFRESH CS_SECURITY_BIN CLAUDE_CONFIG_DIR \
        TMUX TMUX_PANE 2>/dev/null || true
}

# --- Helpers ---

# Run the statusline with $1 as stdin JSON; prints its stdout.
run_sl() {
    printf '%s' "$1" | bash "$SL"
}

# Run the statusline with $1 as stdin JSON; prints its stderr, discarding stdout.
# A threshold the shell cannot compare errors from inside `[`, which leaves the
# rendered line looking plausible while a band silently stops working, so the
# quiet channel is the one worth asserting on.
run_sl_stderr() {
    printf '%s' "$1" | bash "$SL" 2>&1 >/dev/null
}

CAPL=$'\xee\x82\xb6'   # U+E0B6 rounded left cap
CAPR=$'\xee\x82\xb4'   # U+E0B4 rounded right cap
ESC_=$'\033'

# Fixed-string output asserts: the capsule pins open with `[`, which the
# grep-based helpers in test_lib.sh read as a bracket expression.
assert_output_contains_f() {
    grep -qF -- "$2" <<< "$1" || {
        echo "  FAIL: ${3:-output should contain '$2'}"
        echo "    output: $(head -3 <<< "$1")"
        return 1
    }
}
assert_output_not_contains_f() {
    ! grep -qF -- "$2" <<< "$1" || { echo "  FAIL: ${3:-output should not contain '$2'}"; return 1; }
}

# The SGR run carrying the ctx NUMBER ($2, e.g. 42): the label and the number
# are separate items, so a run never carries both. Replaces ctx_pill for
# every test that isolates the gauge's colour.
ctx_num_run() {
    printf '%s' "$1" | tr '\033' '\n' | grep -F "m${2}%" | head -1
}

# Isolate the ctx pill from a rendered line ($1) given its reading ($2): the
# label and the number are separate items, so this just forwards to the
# run carrying the number.
ctx_pill() {
    ctx_num_run "$1" "$2"
}

# Source cs-statusline's functions without running main, so internal helpers can
# be unit tested directly instead of only through a full run_sl invocation.
_load_sl_functions() {
    CS_STATUSLINE_LIB=1 . "$SL" 2>/dev/null
}

# Build a git working tree on branch main with one staged + one modified file.
# Echoes the directory path.
make_git_work() {
    local dir="$TEST_TMPDIR/work"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    git -C "$dir" config user.email "t@cs.local"
    git -C "$dir" config user.name "cs test"
    printf 'tracked\n' > "$dir/a.txt"
    git -C "$dir" add a.txt
    git -C "$dir" commit -q -m init
    printf 'changed\n' >> "$dir/a.txt"   # modified, unstaged -> ` M`
    printf 'new\n' > "$dir/b.txt"
    git -C "$dir" add b.txt               # staged -> `A `
    echo "$dir"
}

# Seed a cs session under CS_SESSIONS_ROOT with a color and a discoveries file
# of $2 bytes. $1 = session name, $3 = color.
make_cs_session() {
    local name="$1" bytes="$2" color="$3"
    local sdir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$sdir/.cs/local"
    cat > "$sdir/.cs/README.md" <<EOF
---
created: 2026-06-11
---
# $name
EOF
    echo "claude_session_color: $color" > "$sdir/.cs/local/state"
    dd if=/dev/zero of="$sdir/.cs/discoveries.md" bs=1024 \
        count="$((bytes / 1024))" 2>/dev/null
}

# ============================================================================
# Happy path: documented fixture renders the visible segments in order (plain)
# ============================================================================

test_happy_path_docs_fixture_plain() {
    export NO_COLOR=1
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    # git absent (non-git dir) and disc absent (no cs session); both rate-limit
    # windows sit below seventy, so limits stays hidden entirely.
    assert_eq "my-session · ✦ Opus high > ○ ctx 8% > ◷ 5h 23%" "$out" \
        "docs fixture should render identity first, the ctx gauge, then the always-on 5h window (no badge in plain mode)"
}


# ============================================================================
# All default segments render in order with git present (plain)
# ============================================================================

test_all_segments_ordering_plain() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="mysess"
    make_cs_session "mysess" 49152 cyan
    local work
    work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{
        session_name:"mysess",
        model:{display_name:"Opus"},
        effort:{level:"high"},
        workspace:{current_dir:$dir},
        context_window:{used_percentage:34},
        rate_limits:{five_hour:{used_percentage:95},seven_day:{used_percentage:72}},
        cost:{total_cost_usd:1.23}
    }')
    local out
    out=$(run_sl "$json")
    assert_eq "mysess · ⎇ main +1!1 · ✦ Opus high > ◔ ctx 34% > ◷ 5h 95% ⋮ ◶ wk 72%" "$out" \
        "all segments should render in order: session, branch, model, ctx, then the shared quota capsule, 5h then wk"
}

# ============================================================================
# Limits hide when healthy: nothing renders below 70
# ============================================================================

test_limits_healthy_shows_5h_and_hides_wk() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":41}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "◷ 5h" "5h stays on the bar while healthy" || return 1
    assert_output_contains_f "$out" "22m23%" "5h 23 sits at normal intensity, the secondary ink" || return 1
    assert_output_not_contains "$out" "◶ wk" "wk at 41 stays hidden below fifty" || return 1
}

# ============================================================================
# Identity items are bold ink on the shared surface; no item carries a fill
# of its own
# ============================================================================

test_identity_items_are_bold_ink() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CLAUDE_SESSION_NAME="accents"
    make_cs_session "accents" 30720 cyan
    local json='{"session_name":"accents","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"cost":{"total_cost_usd":1.0},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":40}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1maccents" "session is bold ink on the surface" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1m✦ Opus" "model is bold ink on the surface" || return 1
    assert_output_not_contains "$out" "8;145;178" "the session colour never reaches the bar" || return 1
    assert_output_not_contains "$out" "76;29;149" "no periwinkle in the bar" || return 1
}

# ============================================================================
# The branch item is bold ink, no fill of its own, ordered before the model
# ============================================================================

test_git_branch_is_bold_ink_no_fill() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local work
    work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{
        session_name:"s",
        model:{display_name:"Opus"},
        workspace:{current_dir:$dir}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1m⎇ main +1!1" \
        "branch is bold ink on the surface" || return 1
    # Branch sits before the model, both inside the identity capsule.
    local branch_pos model_pos
    branch_pos=$(printf '%s' "$out" | grep -bo '⎇ main' | head -1 | cut -d: -f1)
    model_pos=$(printf '%s' "$out" | grep -bo '✦ Opus' | head -1 | cut -d: -f1)
    [ -n "$branch_pos" ] && [ -n "$model_pos" ] && [ "$branch_pos" -lt "$model_pos" ] || {
        echo "  FAIL: branch@$branch_pos should appear before model@$model_pos"
        return 1
    }
}

# ============================================================================
# Limits thresholds escalate per block: a healthy 5h hides; a hot wk shows and escalates on its own value
# ============================================================================

test_limits_threshold_per_block() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◶ wk" "wk 95% block should invert to the crit fill" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m95%" "the wk number inverts too" || return 1
    assert_output_contains_f "$out" "◷ 5h" "the healthy 5h window stays on the bar" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◷ 5h" "5h at 12 rides the shared capsule, which a wk at 95 inverts whole" || return 1
}

test_logo_mark_is_brand_ink() {
    export COLORTERM=truecolor
    # The bar opens with the Claude mark, coral ink on the identity capsule.
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains "$out" "✳" "the mark should render" || return 1
    assert_output_contains_f "$out" "38;2;217;119;87;1m✳" "the mark should be coral ink" || return 1
    assert_output_not_contains_f "$out" "48;2;217;119;87" "the coral must never be a fill" || return 1
}

# ============================================================================
# Segment icons are standard Unicode; the capsule caps are the only
# private-use glyphs
# ============================================================================

test_segment_icons_are_unicode() {
    export NO_COLOR=1
    local work
    work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{
        session_name:"s",
        model:{display_name:"Opus"},
        workspace:{current_dir:$dir},
        context_window:{used_percentage:34},
        rate_limits:{five_hour:{used_percentage:75},seven_day:{used_percentage:41}}
    }')
    local out branch_glyph clock_glyph
    out=$(run_sl "$json")
    branch_glyph=$'\xe2\x8e\x87'   # U+2387 branch
    clock_glyph=$'\xe2\x97\xb7'    # U+25F7 clock
    assert_output_contains "$out" "$branch_glyph" "git segment should carry the branch icon" || return 1
    assert_output_contains "$out" "$clock_glyph" "5h segment should carry the clock icon" || return 1
}

test_session_pill_palette_matches_statusline() {
    # The session pill (bin/cs _session_color_rgb, comma form) must equal the
    # statusline session palette (cs-statusline truecolor rgb, semicolon form)
    # for all 8 names, or the pill and the session block drift apart.
    local c sl cs
    for c in red blue green yellow purple orange pink cyan; do
        sl=$(grep -E "^[[:space:]]*$c\)[[:space:]]*rgb=" "$SL" | grep -oE '[0-9]+;[0-9]+;[0-9]+' | tr ';' ',')
        cs=$(grep -E "$c\).*echo \"[0-9]+,[0-9]+,[0-9]+\"" "$CS_BIN" | grep -oE '[0-9]+,[0-9]+,[0-9]+')
        assert_eq "$sl" "$cs" "session pill RGB for '$c' must match the statusline palette" || return 1
    done
}

test_no_powerline_arrow() {
    export COLORTERM=truecolor
    local work
    work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{
        session_name:"s",
        model:{display_name:"Opus"},
        workspace:{current_dir:$dir},
        context_window:{used_percentage:34},
        rate_limits:{five_hour:{used_percentage:23},seven_day:{used_percentage:41}}
    }')
    local out arrow chevron branch_icon
    out=$(run_sl "$json")
    arrow=$'\xee\x82\xb0'        # U+E0B0 powerline arrow (private-use glyph)
    chevron=$'\xee\x82\xb1'      # U+E0B1 powerline chevron (private-use glyph)
    branch_icon=$'\xe2\x8e\x87'  # U+2387 branch (standard Unicode)
    assert_output_not_contains "$out" "$arrow" "capsules must not use the powerline arrow" || return 1
    assert_output_not_contains "$out" "$chevron" "capsules must not use the powerline chevron" || return 1
    assert_output_contains "$out" "$branch_icon" "standard Unicode icons still render" || return 1
}

# ============================================================================
# Terminal theme: cs -detect-theme classification and the dark statusline
# variant behind CS_TERM_THEME
# ============================================================================

test_detect_theme_colorfgbg_dark() {
    local out
    out=$(env -u TMUX COLORFGBG="15;0" "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "dark" "COLORFGBG bg index 0 should classify as dark" || return 1
}

test_detect_theme_colorfgbg_light() {
    local out
    out=$(env -u TMUX COLORFGBG="0;15" "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "light" "COLORFGBG bg index 15 should classify as light" || return 1
}

test_detect_theme_konsole_three_part() {
    local out
    out=$(env -u TMUX COLORFGBG="0;default;7" "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "light" "three-part COLORFGBG should classify by its last field" || return 1
}

# No tty to answer OSC 11, no COLORFGBG, and a platform with no appearance
# setting to read: with every signal absent the classification is unknown.
# OSTYPE is pinned non-darwin because on macOS the OS appearance IS a signal.
test_detect_theme_unknown_without_signals() {
    local out
    out=$(env -u COLORFGBG -u TMUX OSTYPE="linux-gnu" "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "unknown" \
        "no tty, no COLORFGBG and no OS appearance should classify as unknown" || return 1
}

# Outside tmux on macOS the OS appearance is the last resort, exactly as it is
# under tmux: a terminal answering no OSC 11 query and exporting no COLORFGBG
# (Terminal.app) must not be left unknown, because unknown leaves cs on its dark
# default and dark on a light terminal is the wrong-way failure.
test_detect_theme_no_tmux_uses_os_appearance() {
    _make_appearance_fakes light
    local out
    out=$(env -u COLORFGBG -u TMUX OSTYPE="darwin24.0" PATH="$TEST_TMPDIR/fakebin:$PATH" \
        "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "light" \
        "no tty and no COLORFGBG must fall back to the OS appearance, not to unknown" || return 1
}

# Under tmux, OSC 11 is answered by tmux itself (default-black) and COLORFGBG
# is the server's start-time snapshot — both misreport. Detection must ignore
# them and read the OS appearance instead. Each test sets a CONTRADICTING
# COLORFGBG to prove the tty signals are not consulted.

_make_appearance_fakes() {
    # $1: "dark" makes `defaults read -g AppleInterfaceStyle` succeed,
    #     "light" makes it fail (key absent). The OS check itself reads
    #     $OSTYPE (no fork), which bash inherits from the environment, so
    #     tests inject it directly instead of faking uname.
    mkdir -p "$TEST_TMPDIR/fakebin"
    if [ "$1" = "dark" ]; then
        printf '#!/bin/sh\necho Dark\nexit 0\n' > "$TEST_TMPDIR/fakebin/defaults"
    else
        printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/defaults"
    fi
    chmod +x "$TEST_TMPDIR/fakebin/defaults"
}

test_detect_theme_tmux_appearance_dark() {
    _make_appearance_fakes dark
    local out
    out=$(TMUX="fake,1,0" OSTYPE="darwin24.0" COLORFGBG="0;15" PATH="$TEST_TMPDIR/fakebin:$PATH" \
        "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "dark" \
        "tmux + dark OS appearance must classify dark despite light COLORFGBG" || return 1
}

test_detect_theme_tmux_appearance_light() {
    _make_appearance_fakes light
    local out
    out=$(TMUX="fake,1,0" OSTYPE="darwin24.0" COLORFGBG="15;0" PATH="$TEST_TMPDIR/fakebin:$PATH" \
        "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "light" \
        "tmux + light OS appearance must classify light despite dark COLORFGBG" || return 1
}

test_detect_theme_tmux_non_darwin_unknown() {
    _make_appearance_fakes dark
    local out
    out=$(TMUX="fake,1,0" OSTYPE="linux-gnu" COLORFGBG="15;0" PATH="$TEST_TMPDIR/fakebin:$PATH" \
        "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "unknown" \
        "tmux without a macOS appearance source must classify unknown, not trust COLORFGBG" || return 1
}

test_statusline_dark_theme_variant() {
    export COLORTERM=truecolor
    export CS_TERM_THEME=dark
    unset CS_TERM_BG_RGB
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;50;50;50;38;2;230;230;230;1m" \
        "an unmeasured dark terminal shades the assumed background with soft white ink" || return 1
    local pill; pill=$(ctx_num_run "$out" 8)
    assert_output_contains_f "$pill" "48;2;50;50;50;38;2;162;162;162;22m" \
        "the dark fallback gauge uses the surface's secondary ink" || return 1
    assert_output_not_contains "$out" "48;2;140;132;122" "the dark fallback must not paint dark taupe" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110" "the dark fallback must not paint light taupe" || return 1
}

# ============================================================================
# Missing rate_limits -> limits segment absent
# ============================================================================

test_missing_rate_limits_absent() {
    export NO_COLOR=1
    local json='{"session_name":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10},"cost":{"total_cost_usd":0.5}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "5h " "limits segment should be absent without rate_limits"
    assert_output_contains "$out" "ctx 10%" "other segments should still render"
}

# ============================================================================
# 5h block appends time until the window resets, computed from resets_at
# ============================================================================

test_5h_rest_time_appended() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))   # 2h14m30s out -> "2h14m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:75,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 75% · 2h14m" "5h block should append time until reset"
}

# The reset countdown must render even under bash <4.2, which lacks the
# printf '%(%s)T' epoch builtin (e.g. macOS stock /bin/bash 3.2). Regression:
# _fmt_rest silently produced an empty countdown there, so the bar showed
# "5h 23%" with no "· 2h14m" suffix. Skips when no old bash is available.
test_5h_rest_time_on_old_bash() {
    export NO_COLOR=1
    local old_bash=/bin/bash
    if [ ! -x "$old_bash" ] || "$old_bash" -c 'printf -v n "%(%s)T" -1 2>/dev/null; [[ "$n" =~ ^[0-9]+$ ]]' 2>/dev/null; then
        echo "    SKIP: no bash lacking the %(%s)T builtin available to exercise the fallback"
        return 77
    fi
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))   # 2h14m30s out -> "2h14m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:75,resets_at:$r}}
    }')
    local out
    out=$(printf '%s' "$json" | "$old_bash" "$SL")
    assert_output_contains "$out" "5h 75% · 2h14m" "reset countdown must render under bash <4.2 via date fallback"
}

# Under an hour the rest time is minutes-only, with no zero-hour prefix.
test_5h_rest_time_minutes_only() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now + 45 * 60 + 30 ))   # 45m30s -> "45m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:75,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 75% · 45m" "5h block should show minutes-only rest time under an hour" || return 1
    assert_output_not_contains "$out" "0h" "minutes-only rest time must not carry a zero-hour prefix"
}

# Sub-minute rest time collapses to a fixed "<1m" marker.
test_5h_rest_time_sub_minute() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now + 30 ))   # 30s out -> "<1m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:88,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 88% · <1m" "5h block should show <1m when under a minute remains" || return 1
    assert_output_not_contains "$out" "0m" "sub-minute rest time must not render a zero-minute count"
}

# No reset suffix when resets_at is missing.
test_5h_rest_time_absent_without_resets_at() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":75}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 75%" "5h percentage should render" || return 1
    assert_output_not_contains "$out" "·" "no reset separator when resets_at is absent"
}

# No reset suffix once the window has already reset (resets_at in the past).
test_5h_rest_time_absent_when_past() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now - 60 ))
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:75,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 75%" "5h percentage should still render" || return 1
    assert_output_not_contains "$out" "·" "no reset separator when the window already reset"
}

# The 5h window is hidden until it is hot: below 70% it does not render at all,
# reset countdown included.
test_5h_below_seventy_shows_without_countdown() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:69,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "◷ 5h 69%" "5h at 69 is on the bar" || return 1
    assert_output_not_contains "$out" "69% ·" "5h withholds the countdown below seventy" || return 1
}

# The weekly block gains a reset countdown, gated at 80%: at or above 80% it
# appends the time until the seven-day window resets.
test_wk_rest_shown_at_or_above_80() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))   # 2h14m30s -> "2h14m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{seven_day:{used_percentage:85,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "wk 85% · 2h14m" "wk block appends reset countdown at or above 80%"
}

# A multi-day countdown reads in days+hours, not raw hours: a weekly window
# resetting in 5d16h shows "5d16h", not the unfriendly "136h14m".
test_wk_rest_time_days_format() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)
    reset_at=$(( now + 5 * 86400 + 16 * 3600 + 14 * 60 ))   # 5d16h14m -> "5d16h"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{seven_day:{used_percentage:85,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "wk 85% · 5d16h" "multi-day reset shows friendly day+hour format" || return 1
    assert_output_not_contains "$out" "136h" "multi-day reset must not show raw hours"
}

# Just over a day still rolls into days: 25h30m -> "1d1h".
test_rest_time_just_over_a_day() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)
    reset_at=$(( now + 25 * 3600 + 30 * 60 ))   # 1d1h30m -> "1d1h"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{seven_day:{used_percentage:90,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "wk 90% · 1d1h" "just over a day rolls into days+hours" || return 1
    assert_output_not_contains "$out" "25h" "over-a-day reset must not show raw hours"
}

# Below 80% the weekly reset countdown stays hidden even when resets_at is known.
# The fixture carries only the seven-day window, so the only possible reset
# separator is the weekly one.
test_wk_rest_hidden_below_80() {
    export NO_COLOR=1
    local now reset_at
    now=$(date +%s)
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{seven_day:{used_percentage:75,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "wk 75%" "wk percentage should render once hot" || return 1
    assert_output_not_contains "$out" "·" "wk reset suffix is hidden below 80% usage"
}

# ============================================================================
# Missing session_name outside a cs session -> basename of current_dir
# ============================================================================

test_missing_session_name_dir_fallback() {
    export NO_COLOR=1
    local json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/alpha/beta"},"context_window":{"used_percentage":5}}'
    local out
    out=$(run_sl "$json")
    assert_eq "beta · ✦ Opus > ○ ctx 5%" "$out" \
        "session label should fall back to basename of current_dir"
}

# ============================================================================
# NO_COLOR -> no ANSI escape sequences in the output
# ============================================================================

test_no_color_emits_no_escapes() {
    export NO_COLOR=1
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    [ -n "$out" ] || { echo "  FAIL: expected non-empty output, got nothing"; return 1; }
    if grep -q $'\033' <<< "$out"; then
        echo "  FAIL: NO_COLOR output contained an ESC byte"
        return 1
    fi
}

# ============================================================================
# CS_STATUSLINE_DISABLE=1 -> empty output, exit 0
# ============================================================================

test_disable_prints_nothing() {
    export CS_STATUSLINE_DISABLE=1
    local out rc
    out=$(run_sl "$FIXTURE_DOCS"); rc=$?
    assert_eq "0" "$rc" "disabled statusline should exit 0"
    assert_eq "" "$out" "disabled statusline should print nothing"
}

# ============================================================================
# Malformed stdin -> plain fallback (dir basename), exit 0
# ============================================================================

test_malformed_stdin_fallback() {
    export NO_COLOR=1
    local out rc
    out=$(run_sl 'this is not json {{{'); rc=$?
    assert_eq "0" "$rc" "malformed stdin must still exit 0"
    if [ -z "$out" ]; then
        echo "  FAIL: expected a non-empty fallback line"
        return 1
    fi
    if grep -q $'\033' <<< "$out"; then
        echo "  FAIL: fallback should be plain text"
        return 1
    fi
}

# ============================================================================
# Non-git workspace -> git segment absent
# ============================================================================

test_non_git_workspace_absent() {
    export NO_COLOR=1
    local json
    json=$(jq -nc --arg dir "$TEST_TMPDIR" '{
        session_name:"s",
        model:{display_name:"Opus"},
        workspace:{current_dir:$dir},
        context_window:{used_percentage:5}
    }')
    local out
    out=$(run_sl "$json")
    # current_dir is a real, non-git directory; output must end at the ctx
    # segment with no git slot appended.
    assert_eq "s · ✦ Opus > ○ ctx 5%" "$out" \
        "git segment should be absent for a non-git workspace"
}

# ============================================================================
# Threshold colors: ctx >= crit renders red; healthy renders neutral grey
# ============================================================================

test_ctx_threshold_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":60}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◕ ctx" "ctx 60% should invert to the crit fill" || return 1
    if ! grep -qF "$(printf '\033[0m')" <<< "$out"; then
        echo "  FAIL: colored line must contain a reset"
        return 1
    fi
}

test_ctx_normal_neutral_not_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_not_contains "$out" "0;135;0" "healthy ctx must not shout green" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "ctx 8% must not use the crit fill" || return 1
    local pill
    pill=$(ctx_num_run "$out" 8)
    assert_output_contains "$pill" "38;2;125;125;125;22m" "ctx 8% number should sit at the secondary ink" || return 1
}

test_ctx_amber_band_is_amber() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":42}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m42%" "ctx 42% should use the amber ink" || return 1
    assert_output_not_contains "$out" "48;2;255;183;77" "ctx 42% amber must never be a fill" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "ctx 42% must not use the crit fill" || return 1
}

# The ctx icon is a pie that fills with the band: empty below 13, quarter to
# the warn threshold, half through the amber band, three-quarters at crit,
# full from 88. The shape changes where the ink changes, so the two agree.
test_ctx_icon_fills_with_band() {
    export NO_COLOR=1
    local pct icon out
    for pair in "8:○" "31:◔" "47:◑" "71:◕" "92:●"; do
        pct="${pair%%:*}"; icon="${pair#*:}"
        out=$(CS_STATUSLINE_NOW=1000 run_sl "{\"session_name\":\"s\",\"workspace\":{\"current_dir\":\"/none\"},\"context_window\":{\"used_percentage\":$pct}}")
        assert_output_contains "$out" "$icon ctx ${pct}%" "ctx ${pct}% should show the $icon pie" || return 1
    done
}

test_ctx_below_warn_is_neutral() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":39}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    local pill
    pill=$(ctx_pill "$out" 39)
    assert_output_contains "$pill" "38;2;125;125;125;22m" "ctx 39% should sit at the secondary ink" || return 1
    assert_output_not_contains "$pill" "180;83;9" "ctx 39% must not use amber" || return 1
    assert_output_not_contains "$pill" "215;0;21" "ctx 39% must not use the crit fill" || return 1
}

test_ctx_warn_band_still_amber() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":50}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m50%" "ctx 50% should still use the amber ink" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "ctx 50% must not use the crit fill" || return 1
}

test_ctx_below_crit_is_amber_not_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":59}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m59%" "ctx 59% should still be amber" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "ctx 59% must not use the crit fill" || return 1
}

test_ctx_warn_threshold_is_configurable() {
    export COLORTERM=truecolor
    export CS_STATUSLINE_CTX_WARN=20
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":25}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m25%" "ctx 25% should be amber when warn is 20" || return 1
}

# The amber band's lower edge is inclusive, and 40 is the only reading that
# tells `-ge` apart from `-gt`.
test_ctx_warn_edge_is_amber_at_the_threshold() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":40}}'
    local out
    out=$(run_sl "$json")
    local pill
    pill=$(ctx_pill "$out" 40)
    assert_output_contains_f "$pill" "38;2;180;83;9;1m" "ctx 40% is inside the amber band" || return 1
    assert_output_not_contains_f "$out" "48;2;215;0;21" "ctx 40% must not reach the crit fill" || return 1
}

# The launch card and the resume prompt paint the bar's crit inks from
# setup_palette (lib/05-term.sh), by CS_TERM_THEME: the crit red, which the
# card's figure and the line above the ask wear from warn, and the crit
# capsule, white on that red. Each is a literal in both files, read here out of
# the crit) and critink) arms of _sgr and out of setup_palette's light and dark
# branches, so a colour changed in one and not the other fails.
_card_ink() {  # theme, variable
    awk -v theme="$1" '
        /^    if \[ "\$\{CS_TERM_THEME:-dark\}" = "light" \]; then$/ { branch = "light"; next }
        branch != "" && /^    else$/ { branch = "dark"; next }
        branch != "" && /^    fi$/ { branch = ""; next }
        branch == theme { print }
    ' "$SCRIPT_DIR/../lib/05-term.sh" | sed -n "s/^ *$2='\\\\033\\[\\([0-9;]*\\)m'\$/\\1/p"
}

test_launch_card_inks_are_the_statuslines() {
    local truecolor crit critink crit_dark crit_light
    truecolor="$(sed -n '/^_sgr() {/,/^        256)/p' "$SL")"
    crit="$(sed -n '/^ *crit)$/,/;;/p' <<< "$truecolor" \
        | sed -n 's/^ *\[ "\$SL_THEME" = "dark" \] && rgb="\([0-9;]*\)" || rgb="\([0-9;]*\)" ;;$/\1 \2/p')"
    crit_dark=${crit% *}
    crit_light=${crit#* }
    critink="$(sed -n 's/^ *critink) rgb="\([0-9;]*\)" ;;$/\1/p' <<< "$truecolor")"
    [ -n "$crit_dark" ] && [ -n "$crit_light" ] && [ "$crit_dark" != "$crit" ] || { echo "  FAIL: _sgr's crit) arm not found"; return 1; }
    [ -n "$critink" ] || { echo "  FAIL: _sgr's critink) arm not found"; return 1; }
    assert_eq "38;2;$crit_light" "$(_card_ink light CRIT)" "the card's light crit ink is the bar's" || return 1
    assert_eq "48;2;$crit_light;38;2;$critink" "$(_card_ink light CRIT_FILL)" "the card's light crit capsule is the bar's" || return 1
    assert_eq "38;2;$crit_dark" "$(_card_ink dark CRIT)" "the card's dark crit ink is the bar's" || return 1
    assert_eq "48;2;$crit_dark;38;2;$critink" "$(_card_ink dark CRIT_FILL)" "the card's dark crit capsule is the bar's" || return 1
}

# A threshold override is environment, so it can be anything. Anything that is
# not a plain integer of at most three digits takes the default, the way the
# Stop hook's tiers do: a word must not switch a band off, and a number too wide
# for the shell's integers must not error inside `[`.
test_ctx_threshold_non_numeric_falls_back_to_default() {
    export COLORTERM=truecolor
    # A three-character word, not a long one: a long word is also too wide to be
    # a threshold, so it would be rejected by the width rule alone and never
    # exercise the digits rule. Short enough to pass the width rule is the only
    # value that tells the two apart.
    export CS_STATUSLINE_CTX_WARN=hot CS_STATUSLINE_CTX_CRIT=hot
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":42}}'
    local out err
    out=$(run_sl "$json")
    err=$(run_sl_stderr "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m42%" "a word override keeps the default 40 amber band" || return 1
    assert_eq "" "$err" "a word override must not reach the shell's integer comparison" || return 1
}

test_ctx_threshold_out_of_range_falls_back_to_default() {
    export COLORTERM=truecolor
    local huge=999999999999999999999999
    export CS_STATUSLINE_CTX_WARN="$huge" CS_STATUSLINE_CTX_CRIT="$huge"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":42}}'
    local out err
    out=$(run_sl "$json")
    err=$(run_sl_stderr "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m42%" "an oversized override keeps the default 40 amber band" || return 1
    assert_eq "" "$err" "an oversized override must not error inside \`[\`" || return 1
}

# Three digits, not 0-100: a threshold above any reachable reading is how a band
# is turned off, and cs -doctor already uses that idiom on the Stop hook's tiers.
test_ctx_threshold_above_100_disables_its_band() {
    export COLORTERM=truecolor
    export CS_STATUSLINE_CTX_CRIT=101
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":100}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m100%" "ctx 100% stays amber when crit is out of reach" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "a crit of 101 must switch the crit fill off, not fall back to 60" || return 1
}

test_model_neutral_not_blue() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "Opus" "model segment should render" || return 1
    assert_output_not_contains "$out" "0;95;175" "model segment must not use the blue background" || return 1
}

test_model_is_bold_ink_no_fill() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;79;77;71;1m✦ Opus" "the model is bold ink on the surface" || return 1
    assert_output_not_contains_f "$out" "76;29;149" "no periwinkle in the bar" || return 1
}

test_accent_segments_bold() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CLAUDE_SESSION_NAME="boldsess"
    make_cs_session "boldsess" 1000 cyan
    local json='{"session_name":"boldsess","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1mboldsess" \
        "the session name should render bold ink" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1m✦ Opus" \
        "the model should render bold ink" || return 1
    # SGR bold is stateful: a segment that does not explicitly emit normal
    # intensity (22) inherits bold from the accent before it.
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;124;121;112;22m○ ctx" \
        "the ctx label must explicitly reset to normal intensity" || return 1
    assert_output_not_contains "$out" "8;145;178" "the session colour never reaches the bar" || return 1
}

test_ctx_amber_is_ink_not_dark_fill_text() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":55}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;180;83;9;1m55%" "warn readings should be amber ink, not a fill" || return 1
    assert_output_not_contains "$out" "48;2;255;183;77" "amber must never be a fill" || return 1
}

# ============================================================================
# Limits threshold: max(5h,wk) >= crit renders red
# ============================================================================

test_limits_threshold_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◶ wk" "wk 95% should invert the lim-wk capsule to the crit fill" || return 1
    assert_output_contains_f "$out" "◷ 5h" "the healthy 5h window stays on the bar"
}

# ============================================================================
# CS_STATUSLINE_SEGMENTS subset controls which segments render and their order
# ============================================================================

test_segments_subset() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="model,cost"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "✦ Opus high > \$0.01" "$out" \
        "subset should render only the named segments in order"
    assert_output_not_contains "$out" "ctx" "excluded segments must not appear"
}


# ============================================================================
# Git: an untracked file must not be counted as modified (no phantom `!`)
# ============================================================================

test_git_untracked_not_modified() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="git"
    local work="$TEST_TMPDIR/untracked"
    mkdir -p "$work"
    git -C "$work" init -q
    git -C "$work" symbolic-ref HEAD refs/heads/main
    git -C "$work" config user.email "t@cs.local"
    git -C "$work" config user.name "cs test"
    printf 'tracked\n' > "$work/a.txt"
    git -C "$work" add a.txt
    git -C "$work" commit -q -m init
    printf 'loose\n' > "$work/untracked.txt"   # `?? untracked.txt`, nothing else
    local json
    json=$(jq -nc --arg dir "$work" '{session_name:"s",workspace:{current_dir:$dir}}')
    local out
    out=$(run_sl "$json")
    assert_eq "⎇ main" "$out" "untracked-only repo should render a clean branch, no markers"
}

# ============================================================================
# Color ladder: 256-color level uses indexed codes, not truecolor
# ============================================================================

test_color_level_256() {
    # setup() leaves TERM=xterm-256color and COLORTERM unset.
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;5;" "256-color level should emit indexed bg codes"
    assert_output_not_contains "$out" "48;2;" "256-color level must not emit truecolor codes"
}

# ============================================================================
# Color ladder: basic ANSI when neither truecolor nor 256color is advertised
# ============================================================================

test_color_level_basic() {
    export TERM="xterm"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "48;5;" "basic level must not emit indexed codes"
    assert_output_not_contains "$out" "48;2;" "basic level must not emit truecolor codes"
    # The surface fill is basic bg code 100; identity's primary ink is fg 97
    # with bold (1), ctx's secondary ink is fg 37 (light theme) with normal
    # intensity (22): fill 100 is the surface base 90 shifted by 10.
    assert_output_contains "$out" "100;97;1m" "basic level should emit 8/16-color SGR codes with identity bold"
    assert_output_contains "$out" "100;37;22m" "basic level plain segments should reset to normal intensity"
}

# ============================================================================
# Color ladder: TERM=dumb forces plain output
# ============================================================================

test_term_dumb_is_plain() {
    export TERM="dumb"
    export COLORTERM="truecolor"   # must be overridden by the dumb check
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    [ -n "$out" ] || { echo "  FAIL: expected non-empty output, got nothing"; return 1; }
    if grep -q $'\033' <<< "$out"; then
        echo "  FAIL: TERM=dumb should suppress all escapes"
        return 1
    fi
}

# ============================================================================
# Git ahead-of-upstream renders the ahead arrow
# ============================================================================

test_git_ahead_arrow() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="git"
    local origin="$TEST_TMPDIR/origin.git" work="$TEST_TMPDIR/clone"
    git init -q --bare "$origin"
    git clone -q "$origin" "$work" 2>/dev/null
    git -C "$work" symbolic-ref HEAD refs/heads/main
    git -C "$work" config user.email "t@cs.local"
    git -C "$work" config user.name "cs test"
    printf 'one\n' > "$work/a.txt"
    git -C "$work" add a.txt
    git -C "$work" commit -q -m one
    git -C "$work" push -q -u origin main 2>/dev/null
    printf 'two\n' > "$work/b.txt"          # one local commit ahead of origin/main
    git -C "$work" add b.txt
    git -C "$work" commit -q -m two
    local json
    json=$(jq -nc --arg dir "$work" '{session_name:"s",workspace:{current_dir:$dir}}')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "main↑1" "git segment should show the ahead arrow"
}

# ============================================================================
# Color ladder: FORCE_COLOR=0 forces plain output (overrides COLORTERM)
# ============================================================================

test_force_color_zero_is_plain() {
    export FORCE_COLOR=0
    export COLORTERM="truecolor"   # must be overridden by FORCE_COLOR=0
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    if grep -q $'\033' <<< "$out"; then
        echo "  FAIL: FORCE_COLOR=0 should suppress all escapes"
        return 1
    fi
}

# ============================================================================
# I/O gating: the git subprocess forks only when "git" is an enabled segment
# ============================================================================

test_io_gating_git_subprocess() {
    local bindir="$TEST_TMPDIR/fakebin"
    mkdir -p "$bindir"
    # Fake git records each invocation so we can assert whether it ran.
    cat > "$bindir/git" <<EOF
#!/usr/bin/env bash
echo invoked >> "$TEST_TMPDIR/git-calls"
exit 0
EOF
    chmod +x "$bindir/git"
    local work="$TEST_TMPDIR/repo"
    mkdir -p "$work/.git"   # looks like a repo so the .git existence check passes
    local json
    json=$(jq -nc --arg dir "$work" '{session_name:"s",model:{display_name:"Opus"},workspace:{current_dir:$dir}}')

    # git NOT in the segment list -> the subprocess must never fork.
    printf '%s' "$json" | env PATH="$bindir:$PATH" NO_COLOR=1 \
        CS_STATUSLINE_SEGMENTS="session,model" bash "$SL" >/dev/null
    if [ -f "$TEST_TMPDIR/git-calls" ]; then
        echo "  FAIL: git forked despite 'git' not being in CS_STATUSLINE_SEGMENTS"
        return 1
    fi

    # git IN the segment list -> git is consulted (proves the gate isn't a no-op).
    printf '%s' "$json" | env PATH="$bindir:$PATH" NO_COLOR=1 \
        CS_STATUSLINE_SEGMENTS="git" bash "$SL" >/dev/null
    if [ ! -f "$TEST_TMPDIR/git-calls" ]; then
        echo "  FAIL: git was not invoked when 'git' is enabled"
        return 1
    fi
}

# ============================================================================
# Context %: 0 renders explicitly; absent omits the segment
# ============================================================================

test_ctx_zero_vs_absent() {
    export NO_COLOR=1
    local with0='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":0}}'
    assert_eq "s > ○ ctx 0%" "$(run_sl "$with0")" "ctx 0% should render explicitly"
    local without='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    assert_eq "s" "$(run_sl "$without")" "absent used_percentage should omit the ctx segment"
}

# ============================================================================
# Unknown CS_STATUSLINE_SEGMENTS tokens are skipped, not fatal
# ============================================================================

test_unknown_segment_ignored() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="session,bogus,model"
    local json='{"session_name":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    assert_eq "s · ✦ Opus" "$(run_sl "$json")" "unknown segment tokens should be skipped"
}

# ============================================================================
# claude_session_color is the session name's ink; a bogus name falls back to
# ink, and the colour is never a fill
# ============================================================================

test_session_color_never_reaches_the_bar() {
    export COLORTERM="truecolor"
    export CS_TERM_BG_RGB="253;246;227"
    export CLAUDE_SESSION_NAME="weird"
    local json='{"session_name":"weird","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":5}}'
    make_cs_session "weird" 1024 blue         # a valid palette color
    local out_valid; out_valid=$(run_sl "$json")
    assert_output_contains_f "$out_valid" "38;2;79;77;71;1mweird" \
        "the session name is ink even when the session has a colour" || return 1
    assert_output_not_contains_f "$out_valid" "106;155;204" "the session palette blue never reaches the bar" || return 1
    make_cs_session "weird" 1024 chartreuse   # not one of the 8 valid color names
    local out_bogus; out_bogus=$(run_sl "$json")
    assert_output_contains_f "$out_bogus" "38;2;79;77;71;1mweird" \
        "a claude_session_color outside the palette is ink too" || return 1
}

# ============================================================================
# Display-width counting and RGB triplet parsing
# ============================================================================

test_display_width_counts_codepoints_not_bytes() {
    ( _load_sl_functions
      _display_width "ctx 42%"
      assert_eq "7" "$_WIDTH" "plain ASCII width should equal its character count" || exit 1
      _display_width ""
      assert_eq "0" "$_WIDTH" "empty string should be zero width" || exit 1
      _display_width "$ICON_LOGO"
      assert_eq "1" "$_WIDTH" "a bare 3-byte UTF-8 icon should count as one cell" || exit 1
      _display_width $'caf\xc3\xa9'
      assert_eq "4" "$_WIDTH" "a multibyte session name should count codepoints, not bytes" )
}

# The width is counted the same way under every bash and locale, and the
# shell never changes its own locale for it: a bash linked against libintl
# that sets a locale of its own inside a command substitution, with no locale
# variable set, dies of SIGSEGV. Each cell is one fresh bash with one locale
# setting, counting "café ✳" (six codepoints) inside $( ).
test_display_width_leaves_the_shells_own_locale_alone() {
    local b utf8 loc out own
    utf8="$(utf8_locale)"
    for b in $(every_bash); do
        for loc in ${utf8:+"LC_ALL=$utf8"} LC_ALL=C none; do
            [ "$loc" = none ] && loc=""
            out=$(env -i PATH="$PATH" HOME="$TEST_TMPDIR" $loc "$b" -c '
                CS_STATUSLINE_LIB=1 . "$1" 2>/dev/null
                set -x
                w=$(_display_width "$2"; printf "%s" "$_WIDTH")
                printf "%s" "$w"' x "$SL" "$(printf 'caf\303\251 \342\234\263')" 2>"$TEST_TMPDIR/trace")
            assert_eq "6" "$out" "$b ${loc:-with no locale}: the width of the name" || return 1
            own="$(shell_locale_assignments "$TEST_TMPDIR/trace")"
            assert_eq "" "$own" "$b ${loc:-with no locale} must not assign its own locale in _display_width" || return 1
        done
    done
}

test_parse_rgb_triplet_accepts_valid_and_rejects_malformed() {
    ( _load_sl_functions
      _parse_rgb_triplet "250;248;242"
      assert_eq "0" "$?" "a well-formed triplet should parse" || exit 1
      assert_eq "250" "$_R" "R channel should parse correctly" || exit 1
      assert_eq "248" "$_G" "G channel should parse correctly" || exit 1
      assert_eq "242" "$_B" "B channel should parse correctly" || exit 1
      _parse_rgb_triplet ""; assert_eq "1" "$?" "an empty string should be rejected" || exit 1
      _parse_rgb_triplet "1;2"; assert_eq "1" "$?" "a missing channel should be rejected" || exit 1
      _parse_rgb_triplet "1;2;3;4"; assert_eq "1" "$?" "an extra field should be rejected" || exit 1
      _parse_rgb_triplet "1;2;300"; assert_eq "1" "$?" "an out-of-range channel should be rejected" || exit 1
      _parse_rgb_triplet "r;g;b"; assert_eq "1" "$?" "non-numeric channels should be rejected" )
}

# ============================================================================
# Background-derived gauge surface: the quiet gauges tint from the terminal
# background instead of a fixed grey, with contrast-aware text
# ============================================================================

test_bg_shade_darkens_light_background() {
    ( _load_sl_functions
      _bg_shade "250;248;242" || exit 1
      { [ "$_R" -lt 250 ] && [ "$_G" -lt 248 ] && [ "$_B" -lt 242 ]; } \
        || { echo "  FAIL: a light background should darken (got $_R;$_G;$_B)"; exit 1; }
      { [ "$_R" -gt 200 ] && [ "$_G" -gt 200 ] && [ "$_B" -gt 190 ]; } \
        || { echo "  FAIL: the darkened shade drifted too far from the bg (got $_R;$_G;$_B)"; exit 1; } )
}

test_bg_shade_lightens_dark_background() {
    ( _load_sl_functions
      _bg_shade "30;30;30" || exit 1
      { [ "$_R" -gt 30 ] && [ "$_G" -gt 30 ] && [ "$_B" -gt 30 ]; } \
        || { echo "  FAIL: a dark background should lighten (got $_R;$_G;$_B)"; exit 1; }
      { [ "$_R" -lt 90 ] && [ "$_G" -lt 90 ] && [ "$_B" -lt 90 ]; } \
        || { echo "  FAIL: the lightened shade drifted too far from the bg (got $_R;$_G;$_B)"; exit 1; } )
}

test_bg_shade_noop_on_malformed() {
    ( _load_sl_functions
      if _bg_shade "not-a-color"; then echo "  FAIL: a malformed bg must not yield a shade"; exit 1; fi )
}

test_gauge_uses_bg_derived_surface() {
    export COLORTERM=truecolor CS_TERM_THEME=light CS_TERM_BG_RGB="250;248;242"
    # No CLAUDE_SESSION_NAME/claude_session_color here on purpose: with one, the
    # session name would paint in that colour instead of plain ink, and the
    # bold-ink pin below assumes ink.
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10}}'
    local out
    # 250;248;242 shaded 10% darker is 225;223;217; its 35% shade (ink) is
    # 78;78;75 and its 55% shade (ink2) is 123;122;119.
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;225;223;217;38;2;78;78;75;1m" \
        "identity should render on the bg-derived surface with softened tonal text" || return 1
    local pill; pill=$(ctx_num_run "$out" 10)
    assert_output_contains_f "$pill" "48;2;225;223;217;38;2;123;122;119;22m" \
        "a healthy gauge number should sit on the bg-derived surface at the secondary ink" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110" \
        "a gauge with a known background must not use the fixed grey" || return 1
}

test_gauge_shades_the_assumed_light_background_without_bg() {
    export COLORTERM=truecolor CS_TERM_THEME=light
    unset CS_TERM_BG_RGB
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;229;229;229;38;2;80;80;80;1m" \
        "an unmeasured light terminal shades the assumed background with primary ink" || return 1
    local pill; pill=$(ctx_num_run "$out" 10)
    assert_output_contains_f "$pill" "48;2;229;229;229;38;2;125;125;125;22m" \
        "the light fallback gauge uses the surface's secondary ink" || return 1
    assert_output_not_contains "$out" "48;2;140;132;122" "the light fallback must not paint dark taupe" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110" "the light fallback must not paint light taupe" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_statusline.sh"
echo ""
# --- TMUX inherited into a terminal it does not describe -------------------
#
# TMUX is ordinary environment: anything a tmux-launched process spawns
# inherits it, including an app that shells out and then draws its own window.
# Such a process claims a tmux membership it does not have. _sl_tmux_is_real
# settles it from the one fact that cannot be inherited: a genuine pane has the
# tmux SERVER (TMUX's second field) among its ancestors.
#
# Stub `ps` with a fixed pid/ppid table so the walk is exercised without ever
# reading — or touching — the real process tree or a live tmux server.
_make_ps_chain() {
    # $1: space-separated "pid:ppid" pairs forming the table `ps -ax` returns.
    mkdir -p "$TEST_TMPDIR/fakebin"
    {
        printf '#!/bin/sh\n'
        local _pair
        for _pair in $1; do
            printf 'echo "%s %s"\n' "${_pair%%:*}" "${_pair##*:}"
        done
    } > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
}

test_sl_tmux_real_when_server_is_ancestor() {
    ( _load_sl_functions
      _make_ps_chain "500:400 400:300 300:2216 2216:1"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _sl_tmux_is_real 500
      assert_eq "0" "$?" "server pid among the ancestors means a real pane" || return 1 )
}

# The bug case: TMUX present, but the walk never reaches the server because
# this process descends from an app that merely inherited the variable.
test_sl_tmux_fake_when_server_not_ancestor() {
    ( _load_sl_functions
      _make_ps_chain "500:400 400:300 300:99 99:1 2216:1"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _sl_tmux_is_real 500 && { echo "    expected non-zero"; return 1; }
      return 0 )
}

test_sl_tmux_fake_when_server_field_malformed() {
    ( _load_sl_functions
      _make_ps_chain "500:2216 2216:1"
      export TMUX="/tmp/fake,notapid,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _sl_tmux_is_real 500 && { echo "    expected non-zero"; return 1; }
      return 0 )
}

# A pid reused between the ps read and the walk can make the table cyclic; the
# walk must give up rather than spin.
test_sl_tmux_walk_terminates_on_cycle() {
    ( _load_sl_functions
      _make_ps_chain "500:400 400:500 2216:1"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _sl_tmux_is_real 500 && { echo "    expected non-zero"; return 1; }
      return 0 )
}

# A foreign TMUX makes the whole inherited terminal description suspect, not
# just the tmux rungs: CS_TERM_THEME describes the terminal cs measured, which
# is not this one. Fall to dark, the same answer cs gives anywhere else it has
# nothing trustworthy to go on, rather than believing the inherited light.
test_sl_theme_dark_when_tmux_is_foreign() {
    ( _load_sl_functions
      _make_ps_chain "$$:99 99:1 2216:1"
      export TMUX="/tmp/fake,2216,0" TMUX_PANE="%32" PATH="$TEST_TMPDIR/fakebin:$PATH"
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1
      unset COLORFGBG 2>/dev/null || true
      _sl_mark_foreign_env
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "an inherited light theme from another terminal must not be believed" || return 1 )
}

# The regression guard for the ordinary case: a real pane still consults the
# client rung, and a client that answers is still trusted.
test_sl_theme_uses_client_rung_when_tmux_is_real() {
    ( _load_sl_functions
      _make_ps_chain "$$:2216 2216:1"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1
      tmux() { printf 'light\t/dev/ttys002\n'; }
      _sl_mark_foreign_env
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" \
        "a real pane must still take the attached client's own reported theme" || return 1 )
}

# SL_ENV_FOREIGN is a render-scoped flag, and bash seeds a bare global from an
# inherited variable of the same name. A caller exporting it must not be able
# to make a real pane look foreign — nor may the reset land after detection
# has already set it, which silently blanks the finding.
test_sl_env_foreign_ignores_inherited_value() {
    local out
    out=$(SL_ENV_FOREIGN=1 CS_TERM_THEME=light TMUX_PANE="%9" \
          run_sl "$FIXTURE_DOCS" 2>/dev/null)
    assert_output_contains "$out" "my-session" \
        "an inherited SL_ENV_FOREIGN must not disturb a normal render" || return 1
    ( _load_sl_functions
      export SL_ENV_FOREIGN=1
      _make_ps_chain "$$:2216 2216:1"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1
      tmux() { printf 'light\t/dev/ttys002\n'; }
      _sl_mark_foreign_env
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" \
        "an inherited foreign flag must not override a real pane's client theme" || return 1 )
}

# The theme comparison alone cannot catch a foreign environment: when the
# inherited theme happens to equal the fallback, SL_THEME == CS_TERM_THEME and
# the staleness test is satisfied while the RGB still describes another
# terminal. The foreign flag is what distinguishes "same theme" from "same
# terminal", so it must drop the tint on its own.
test_sl_bg_rgb_dropped_when_foreign_despite_matching_theme() {
    ( _load_sl_functions
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1 CS_TERM_BG_RGB="252;247;229"
      SL_THEME=dark          # equal to the launch theme: the old guard is satisfied
      SL_ENV_FOREIGN=1       # but the environment came from another terminal
      _sl_invalidate_stale_bg
      assert_eq "" "$CS_TERM_BG_RGB" \
        "a foreign environment's RGB must be dropped even when the themes agree" || return 1 )
}

# A hand-set RGB carries no auto marker and stays the user's business, foreign
# environment or not — unchanged from the existing contract.
test_sl_bg_rgb_kept_for_manual_value_when_foreign() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO 2>/dev/null || true
      export CS_TERM_BG_RGB="1;2;3"
      SL_THEME=dark
      SL_ENV_FOREIGN=1
      _sl_invalidate_stale_bg
      assert_eq "1;2;3" "$CS_TERM_BG_RGB" \
        "a manually-set RGB is never dropped, foreign environment included" || return 1 )
}

# An RGB set before a launch that detected the theme sits beside the theme's
# auto marker; the launch marks it pinned, and a theme switch keeps it.
test_sl_bg_rgb_kept_when_pinned_beside_an_auto_theme() {
    ( _load_sl_functions
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1 CS_TERM_BG_RGB="1;2;3" CS_TERM_BG_RGB_PINNED=1
      SL_THEME=dark
      _sl_invalidate_stale_bg
      assert_eq "1;2;3" "$CS_TERM_BG_RGB" "a pinned RGB survives a theme switch" || return 1
      unset CS_TERM_BG_RGB_PINNED
      _sl_invalidate_stale_bg
      assert_eq "" "$CS_TERM_BG_RGB" "a measured RGB is dropped on the same switch" || return 1 )
}

# Fake `ps` tables for render-level tests, where the walk starts inside the
# cs-statusline process and its pid cannot be known in advance.
#   real   : every process's parent is rewritten to the server, so the walk
#            reaches it in one step from whatever pid it starts at.
#   foreign: the table holds only the server, so the walk never finds its own
#            starting pid and gives up — an app that merely inherited TMUX.
_make_ps_table() {
    mkdir -p "$TEST_TMPDIR/fakebin"
    if [ "$1" = "real" ]; then
        printf '#!/bin/sh\n/bin/ps -ax -o pid=,ppid= | sed "s/^ *\\([0-9][0-9]*\\).*/\\1 %s/"\necho "%s 1"\n' "$2" "$2" \
            > "$TEST_TMPDIR/fakebin/ps"
    else
        printf '#!/bin/sh\necho "%s 1"\n' "$2" > "$TEST_TMPDIR/fakebin/ps"
    fi
    chmod +x "$TEST_TMPDIR/fakebin/ps"
}

# Block until the detached child a render spawned has left its ancestry
# verdict for parent $1 and the TMUX claim $2, so the next render reads a
# settled answer rather than racing one. Non-zero if it never arrives.
settle_tmux_verdict() {
    local key="$1,$2"
    key=${key//\//-}; key=${key//[^A-Za-z0-9._,-]/_}   # as _cache_key sanitises
    wait_until test -s "$HOME/.cache/cs/tmux-real/$key"
}

# The pane id is a claim about where this conversation lives, and TMUX_PANE is
# inherited alongside TMUX. Rendering it for a process that is not in that
# server prints a pane belonging to someone else's terminal.
test_pane_segment_hidden_when_tmux_is_foreign() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="session,pane,ctx"
    _make_ps_table foreign 12345
    export TMUX="/tmp/tmux-1000/default,12345,0" TMUX_PANE="%7"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    # Named, so the verdict the first render's child writes is the one the
    # render below looks up: a pipeline gives each render its own parent.
    export CS_STATUSLINE_PARENT=4242
    local out
    run_sl "$FIXTURE_DOCS" >/dev/null   # kicks the walk off the render path
    settle_tmux_verdict 4242 "$TMUX" || { echo "  FAIL: no verdict was written"; return 1; }
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "◫" \
        "pane id must not render for a tmux membership this process does not have" || return 1
}


# A pane cs did not launch carries none of cs's environment — an agent-teams
# teammate is spawned straight off the tmux server and inherits TMUX but no
# CS_TERM_*. It can still establish WHICH TERMINAL it is on, though: the tmux
# client's tty, asked over the socket and therefore safe from a render. cs
# writes its launch measurement under that key, so any pane on the same client
# finds it.
#
# The key IS the terminal's identity, which is what makes this safe where a
# tmux session variable was not: re-attach from a different terminal and the
# tty differs, so the lookup MISSES and falls through to the default. The
# failure mode is no answer, never a confidently stale one.
test_client_cache_supplies_theme_and_background() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      export TMUX="/tmp/fake,1,0"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf '\t/dev/ttys002\n'; }
      _sl_theme_from_client_cache || { echo "    lookup failed"; return 1; }
      assert_eq "light" "$SL_THEME" "the cached theme must be adopted" || return 1
      assert_eq "252;247;229" "$CS_TERM_BG_RGB" "the cached background must be adopted" || return 1 )
}

test_client_cache_misses_after_reattach_from_another_terminal() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      export TMUX="/tmp/fake,1,0"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf '\t/dev/ttys009\n'; }   # re-attached from a different terminal
      _sl_theme_from_client_cache && { echo "    stale entry was used"; return 1; }
      assert_eq "" "${CS_TERM_BG_RGB:-}" "a miss must not invent a background" || return 1 )
}

# A user-set background is the user's business and outranks anything cached.
test_client_cache_does_not_override_an_explicit_background() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      export TMUX="/tmp/fake,1,0" CS_TERM_BG_RGB="1;2;3"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO 2>/dev/null || true
      tmux() { printf '\t/dev/ttys002\n'; }
      _sl_theme_from_client_cache
      assert_eq "1;2;3" "$CS_TERM_BG_RGB" "an explicit background must survive" || return 1 )
}

# Garbage in the cache must be refused rather than rendered.
test_client_cache_rejects_a_malformed_entry() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'chartreuse not-a-colour %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      export TMUX="/tmp/fake,1,0"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf '\t/dev/ttys002\n'; }
      _sl_theme_from_client_cache && { echo "    malformed entry was accepted"; return 1; }
      return 0 )
}

# Claude Code mutes a truecolor status line to a fallback palette inside tmux
# unless CLAUDE_CODE_TMUX_TRUECOLOR is set (docs/statusline.md, lib/00-header.sh).
# cs exports it at launch, so a pane cs launched has it — but an agent-teams
# teammate is spawned straight off the tmux server and inherits nothing, so its
# bar gets downsampled to the 256 cube. A warm off-white has no near neighbour
# there and lands on index 224, which is pink: the smooth ramp came out as three
# flat blocks, one of them pink.
#
# When the output is going to be snapped anyway, emit colours that are already
# palette entries. Then the snap is a no-op and nothing shifts.
test_level_drops_to_256_when_truecolor_will_be_muted() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,1,0" COLORTERM=truecolor TERM=xterm-256color
      unset CLAUDE_CODE_TMUX_TRUECOLOR NO_COLOR FORCE_COLOR 2>/dev/null || true
      _detect_level
      assert_eq "256" "$LEVEL" \
        "inside tmux without the truecolor flag, cs must not emit 24-bit for the host to mangle" || return 1 )
}

test_level_stays_truecolor_when_the_flag_is_present() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,1,0" COLORTERM=truecolor TERM=xterm-256color CLAUDE_CODE_TMUX_TRUECOLOR=1
      unset NO_COLOR FORCE_COLOR 2>/dev/null || true
      _detect_level
      assert_eq "truecolor" "$LEVEL" \
        "a pane cs launched keeps full colour" || return 1 )
}

test_level_stays_truecolor_outside_tmux() {
    ( _load_sl_functions
      export COLORTERM=truecolor TERM=xterm-256color
      unset TMUX CLAUDE_CODE_TMUX_TRUECOLOR NO_COLOR FORCE_COLOR 2>/dev/null || true
      _detect_level
      assert_eq "truecolor" "$LEVEL" \
        "outside tmux nothing mutes the line, so the flag is irrelevant" || return 1 )
}

# The tmux mute only applies when this process is really in that tmux server.
# A process that merely inherited TMUX is drawing on its own terminal, nothing
# is quantising its output, and downgrading it discards colour for no reason.
test_foreign_tmux_does_not_downgrade_a_real_truecolor_terminal() {
    ( _load_sl_functions
      _make_ps_chain "$$:99 99:1 2216:1"
      export TMUX="/tmp/fake,2216,0" COLORTERM=truecolor TERM=xterm-256color
      export PATH="$TEST_TMPDIR/fakebin:$PATH"
      unset CLAUDE_CODE_TMUX_TRUECOLOR 2>/dev/null || true
      _sl_mark_foreign_env
      _detect_level
      assert_eq "truecolor" "$LEVEL" \
        "an inherited TMUX must not cost a real terminal its colour" || return 1 )
}

# The host quantises by muting truecolor, which has nothing to do with what TERM
# says. Gating the workaround on a "256color" substring silently skips every
# tmux whose default-terminal is screen, tmux-256color's cousins, or anything
# else — the population the workaround exists for.
test_tmux_mute_applies_regardless_of_term_name() {
    ( _load_sl_functions
      _make_ps_chain "$$:2216 2216:1"
      export TMUX="/tmp/fake,2216,0" COLORTERM=truecolor TERM=screen
      export PATH="$TEST_TMPDIR/fakebin:$PATH"
      unset CLAUDE_CODE_TMUX_TRUECOLOR 2>/dev/null || true
      _sl_mark_foreign_env
      _detect_level
      assert_eq "256" "$LEVEL" \
        "the mute workaround must not depend on TERM naming 256color" || return 1 )
}

# The cache is keyed by terminal identity, and outside tmux that identity is
# this process's own tty — which launch already writes under. Refusing to read
# it there left the answer on disk unreachable.
test_client_cache_is_read_outside_tmux_too() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys009"
      unset TMUX CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tty() { printf '/dev/ttys009\n'; }
      _sl_theme_from_client_cache || { echo "    cache unreadable outside tmux"; return 1; }
      assert_eq "light" "$SL_THEME" "the plain-tty entry must be found" || return 1 )
}

# A ps that is missing or restricted returns an empty table, which the walk
# cannot distinguish from "the server is not an ancestor". Scoring a tool
# failure as proof of the negative makes a genuine pane render dark and lose
# its pane id. An empty table means "cannot tell", so the claim stands.
test_unusable_ps_is_not_evidence_of_a_foreign_tmux() {
    ( _load_sl_functions
      mkdir -p "$TEST_TMPDIR/fakebin"
      printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/ps"
      chmod +x "$TEST_TMPDIR/fakebin/ps"
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _sl_mark_foreign_env
      assert_eq "" "${SL_ENV_FOREIGN:-}" \
        "a ps that cannot answer must not be read as a foreign environment" || return 1 )
}

# tty device names are recycled: a dark terminal on ttys002 closes, a light one
# opens on the same device, and the cached entry is then a confidently wrong
# answer rather than the miss the design depends on. Age is the only signal
# available, so an entry older than the boundary is refused.
test_client_cache_refuses_a_stale_entry() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      local f="$HOME/.cache/cs/term/ttys002"
      printf 'light 252;247;229 %s\n' "$(( $(date +%s) - 43201 ))" > "$f"
      export TMUX="/tmp/fake,1,0"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf '\t/dev/ttys002\n'; }
      _sl_theme_from_client_cache && { echo "    a stale entry was used"; return 1; }
      return 0 )
}

test_client_cache_accepts_a_fresh_entry() {
    ( _load_sl_functions
      export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      export TMUX="/tmp/fake,1,0"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf '\t/dev/ttys002\n'; }
      _sl_theme_from_client_cache || { echo "    a fresh entry was refused"; return 1; }
      assert_eq "light" "$SL_THEME" "the fresh entry must be adopted" || return 1 )
}

run_test test_happy_path_docs_fixture_plain
run_test test_all_segments_ordering_plain
run_test test_limits_healthy_shows_5h_and_hides_wk
run_test test_identity_items_are_bold_ink
run_test test_git_branch_is_bold_ink_no_fill
run_test test_limits_threshold_per_block
run_test test_bg_shade_darkens_light_background
run_test test_bg_shade_lightens_dark_background
run_test test_bg_shade_noop_on_malformed
run_test test_gauge_uses_bg_derived_surface
run_test test_gauge_shades_the_assumed_light_background_without_bg
run_test test_logo_mark_is_brand_ink
run_test test_segment_icons_are_unicode
run_test test_session_pill_palette_matches_statusline
run_test test_no_powerline_arrow
run_test test_detect_theme_colorfgbg_dark
run_test test_detect_theme_colorfgbg_light
run_test test_detect_theme_konsole_three_part
run_test test_detect_theme_unknown_without_signals
run_test test_detect_theme_no_tmux_uses_os_appearance
run_test test_detect_theme_tmux_appearance_dark
run_test test_detect_theme_tmux_appearance_light
run_test test_detect_theme_tmux_non_darwin_unknown
run_test test_statusline_dark_theme_variant
run_test test_missing_rate_limits_absent
run_test test_5h_rest_time_appended
run_test test_5h_rest_time_on_old_bash
run_test test_5h_rest_time_minutes_only
run_test test_5h_rest_time_sub_minute
run_test test_5h_rest_time_absent_without_resets_at
run_test test_5h_rest_time_absent_when_past
run_test test_5h_below_seventy_shows_without_countdown
run_test test_wk_rest_shown_at_or_above_80
run_test test_wk_rest_hidden_below_80
run_test test_wk_rest_time_days_format
run_test test_rest_time_just_over_a_day
run_test test_missing_session_name_dir_fallback
run_test test_no_color_emits_no_escapes
run_test test_disable_prints_nothing
run_test test_malformed_stdin_fallback
run_test test_non_git_workspace_absent
run_test test_ctx_threshold_red
run_test test_ctx_normal_neutral_not_red
run_test test_ctx_amber_band_is_amber
run_test test_ctx_icon_fills_with_band
run_test test_ctx_below_warn_is_neutral
run_test test_ctx_warn_band_still_amber
run_test test_ctx_below_crit_is_amber_not_red
run_test test_ctx_warn_threshold_is_configurable
run_test test_ctx_warn_edge_is_amber_at_the_threshold
run_test test_launch_card_inks_are_the_statuslines
run_test test_ctx_threshold_non_numeric_falls_back_to_default
run_test test_ctx_threshold_out_of_range_falls_back_to_default
run_test test_ctx_threshold_above_100_disables_its_band
run_test test_model_neutral_not_blue
run_test test_model_is_bold_ink_no_fill
run_test test_accent_segments_bold
run_test test_ctx_amber_is_ink_not_dark_fill_text
run_test test_limits_threshold_red
run_test test_segments_subset
run_test test_git_untracked_not_modified
run_test test_color_level_256
run_test test_color_level_basic
run_test test_term_dumb_is_plain
run_test test_git_ahead_arrow
run_test test_force_color_zero_is_plain
run_test test_io_gating_git_subprocess
run_test test_ctx_zero_vs_absent
run_test test_unknown_segment_ignored
run_test test_session_color_never_reaches_the_bar
run_test test_display_width_counts_codepoints_not_bytes
run_test test_display_width_leaves_the_shells_own_locale_alone
run_test test_parse_rgb_triplet_accepts_valid_and_rejects_malformed

# ============================================================================
# Notes segment: queue depth after the session name
# ============================================================================

test_notes_segment_shows_queue_depth() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="notesess"
    make_cs_session "notesess" 0 cyan
    local qdir="$CS_SESSIONS_ROOT/notesess/.cs/local/queue"
    mkdir -p "$qdir"
    printf 'task a\n' > "$qdir/0000000001-a"
    printf 'task b\n' > "$qdir/0000000002-b"
    printf 'task c\n' > "$qdir/0000000003-c"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "▤ 3" "notes segment shows the queue depth" || return 1
}

test_notes_segment_absent_when_queue_empty() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="emptyq"
    make_cs_session "emptyq" 0 cyan
    mkdir -p "$CS_SESSIONS_ROOT/emptyq/.cs/local/queue"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "▤" "notes segment hidden when queue empty" || return 1
}

# Only regular files count as tasks: a subdirectory must not inflate the badge.
test_notes_segment_counts_only_files() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="wsq"
    make_cs_session "wsq" 0 cyan
    local qdir="$CS_SESSIONS_ROOT/wsq/.cs/local/queue"
    mkdir -p "$qdir/subdir"
    printf 'task a\n' > "$qdir/0000000001-a"
    printf 'task b\n' > "$qdir/0000000002-b"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "▤ 2" "only task files are counted" || return 1
}

# Mail segment: unread cross-session mail after the notes queue. Unread is the
# count of mail/new/*.json documents (cs -msg moves what it prints to cur/),
# matching the shell reader and the TUI.
# ============================================================================

test_mail_segment_shows_unread_count() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="mailsess"
    make_cs_session "mailsess" 0 cyan
    local mdir="$CS_SESSIONS_ROOT/mailsess/.cs/local/mail"
    mkdir -p "$mdir/new" "$mdir/cur"
    printf '{"a":1}\n' > "$mdir/new/0000000001-a.json"
    printf '{"a":2}\n' > "$mdir/new/0000000002-b.json"
    printf '{"a":3}\n' > "$mdir/new/0000000003-c.json"
    printf '{"a":4}\n' > "$mdir/cur/0000000000-read.json"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "✉ 3" "mail segment counts new/*.json only (read mail in cur/ excluded)" || return 1
}

test_mail_segment_absent_when_all_read() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="readmail"
    make_cs_session "readmail" 0 cyan
    local mdir="$CS_SESSIONS_ROOT/readmail/.cs/local/mail"
    mkdir -p "$mdir/new" "$mdir/cur"
    printf '{"a":1}\n' > "$mdir/cur/0000000001-a.json"
    printf '{"a":2}\n' > "$mdir/cur/0000000002-b.json"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "✉" "mail segment hidden when all mail is read" || return 1
}

# Only regular *.json files are mail: a .DS_Store, a staging leftover or a
# subdirectory in new/ must not inflate the badge — a phantom unread that
# cs -msg cannot clear would never go out. The DIRECTORY named *.json is the
# case that matters: every other stray is excluded by the glob itself, so only
# this one reaches the `-f` guard and separates this reader from `cs -msg`.
test_mail_segment_ignores_non_json_entries() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="straymail"
    make_cs_session "straymail" 0 cyan
    local mdir="$CS_SESSIONS_ROOT/straymail/.cs/local/mail"
    mkdir -p "$mdir/new/subdir"
    mkdir -p "$mdir/new/0000000005-dir.json"
    printf '{"a":1}\n' > "$mdir/new/0000000001-a.json"
    printf '{"a":2}\n' > "$mdir/new/0000000002-b.json"
    printf '{"a":3}\n' > "$mdir/new/0000000003-c.json"
    printf 'stray\n' > "$mdir/new/.DS_Store"
    printf '{"a":4' > "$mdir/new/0000000004-torn.json.partial"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "✉ 3" "non-.json entries are not counted as unread" || return 1
}

# An encrypted session's mailbox is behind .cs/private, a link into its vault;
# while the link dangles (the vault locked) there is nothing to count.
test_notes_segment_counts_the_vault_queue() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="vaultq"
    make_cs_session "vaultq" 0 cyan
    local meta="$CS_SESSIONS_ROOT/vaultq/.cs"
    mkdir -p "$TEST_TMPDIR/vaultq/private/queue"
    ln -s "$TEST_TMPDIR/vaultq/private" "$meta/private"
    printf 'task a\n' > "$TEST_TMPDIR/vaultq/private/queue/0000000001-a"
    printf 'task b\n' > "$TEST_TMPDIR/vaultq/private/queue/0000000002-b"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "▤ 2" "the vault's queue is counted" || return 1
    mv "$TEST_TMPDIR/vaultq" "$TEST_TMPDIR/vaultq-unmounted"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "▤" "a locked vault shows no queue" || return 1
}

test_mail_segment_counts_the_vault_mailbox() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="vaultmail"
    make_cs_session "vaultmail" 0 cyan
    local meta="$CS_SESSIONS_ROOT/vaultmail/.cs"
    mkdir -p "$TEST_TMPDIR/vault/private/mail/new"
    ln -s "$TEST_TMPDIR/vault/private" "$meta/private"
    printf '{"a":1}\n' > "$TEST_TMPDIR/vault/private/mail/new/0000000001-a.json"
    printf '{"a":2}\n' > "$TEST_TMPDIR/vault/private/mail/new/0000000002-b.json"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "✉ 2" "the vault's unread mail is counted" || return 1
    mv "$TEST_TMPDIR/vault" "$TEST_TMPDIR/unmounted"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "✉" "a locked vault shows no mail" || return 1
}

test_pane_segment_absent_outside_tmux() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="session,pane,ctx"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "◫" "pane segment hidden outside tmux" || return 1
}

test_pane_segment_needs_both_tmux_vars() {
    # A stale TMUX_PANE without TMUX (e.g. env leaked past a detach) must not render.
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="session,pane,ctx"
    export TMUX_PANE="%7"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "◫" "pane segment needs the live TMUX socket too" || return 1
}

test_segment_default_in_sync_across_docs_and_help() {
    # The default segment list is spelled in four sites: the code fallback
    # (authoritative) plus three prose copies. The help copy drifted once.
    local code_default
    code_default=$(sed -n 's/.*CS_STATUSLINE_SEGMENTS:-\([a-z,]*\).*/\1/p' "$SL" | head -1)
    [ -n "$code_default" ] || { echo "  FAIL: could not extract segment default from cs-statusline"; return 1; }
    local f
    for f in "$SCRIPT_DIR/../lib/10-help.sh" \
             "$SCRIPT_DIR/../docs/configuration.md" \
             "$SCRIPT_DIR/../docs/statusline.md"; do
        grep -qF "$code_default" "$f" || {
            echo "  FAIL: $(basename "$f") does not carry the code's segment default: $code_default"
            return 1
        }
    done
}

test_library_mode_defines_helpers_without_rendering() {
    local out
    out=$( CS_STATUSLINE_LIB=1 . "$SL" >/dev/null 2>&1; \
           _detect_level; \
           _sgr 38 periwinkle; \
           printf 'LEVEL=%s SGR=%s' "$LEVEL" "$_SGR" )
    assert_output_contains "$out" "LEVEL=256" "library mode runs _detect_level" || return 1
    assert_output_contains "$out" "SGR=38;5;55" "library mode exposes _sgr's periwinkle" || return 1
}

test_library_mode_prints_nothing() {
    local out
    out=$( CS_STATUSLINE_LIB=1 . "$SL" )
    assert_eq "" "$out" "sourcing in library mode must not render" || return 1
}

test_executed_directly_still_renders() {
    export NO_COLOR=1
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "my-session" "guard must not break direct execution" || return 1
}

test_enable_registers_both_status_lines() {
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_CLAUDE_DIR"
    echo '{}' > "$CS_CLAUDE_DIR/settings.json"
    bash "$CS_BIN" -statusline enable >/dev/null 2>&1
    local sl ssl
    sl=$(jq -r '.statusLine.command' "$CS_CLAUDE_DIR/settings.json")
    ssl=$(jq -r '.subagentStatusLine.command' "$CS_CLAUDE_DIR/settings.json")
    assert_output_contains "$sl" "/cs-statusline" "statusLine registered" || return 1
    assert_output_contains "$ssl" "/cs-subagent-statusline" "subagentStatusLine registered" || return 1
}

test_disable_leaves_a_foreign_subagent_statusline_alone() {
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_CLAUDE_DIR"
    jq -n '{subagentStatusLine: {type: "command", command: "/opt/theirs/rows.sh"}}' \
        > "$CS_CLAUDE_DIR/settings.json"
    bash "$CS_BIN" -statusline disable >/dev/null 2>&1
    local ssl
    ssl=$(jq -r '.subagentStatusLine.command' "$CS_CLAUDE_DIR/settings.json")
    assert_eq "/opt/theirs/rows.sh" "$ssl" "a foreign row renderer is never stripped" || return 1
}

test_enable_warns_that_a_restart_is_required() {
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    mkdir -p "$CS_CLAUDE_DIR"
    echo '{}' > "$CS_CLAUDE_DIR/settings.json"
    local out
    out=$(bash "$CS_BIN" -statusline enable 2>&1)
    assert_output_contains "$out" "restart" "enabling must mention the restart requirement" || return 1
}

# cs rewrites settings.json where it lies: a symlinked file (a dotfiles
# manager's) stays a link, and the file keeps its permission bits.
test_enable_and_disable_rewrite_settings_in_place() {
    export CS_CLAUDE_DIR="$TEST_TMPDIR/claude"
    local real="$TEST_TMPDIR/dotfiles/settings.json" step
    mkdir -p "$CS_CLAUDE_DIR" "$TEST_TMPDIR/dotfiles"
    echo '{"model":"opus"}' > "$real"
    chmod 750 "$real"
    ln -s "$real" "$CS_CLAUDE_DIR/settings.json"
    for step in enable disable; do
        bash "$CS_BIN" -statusline "$step" >/dev/null 2>&1 || { echo "  FAIL: cs -statusline $step failed"; return 1; }
        [ -L "$CS_CLAUDE_DIR/settings.json" ] \
            || { echo "  FAIL: $step replaced the symlinked settings.json with a plain file"; return 1; }
        assert_eq "750" "$(_file_mode "$real")" "$step keeps settings.json's mode" || return 1
        assert_eq "opus" "$(jq -r '.model' "$real")" "$step keeps the other settings" || return 1
    done
    assert_eq "null" "$(jq -r '.statusLine' "$real")" "disable removed the registration enable wrote" || return 1
}

run_test test_notes_segment_shows_queue_depth
run_test test_notes_segment_absent_when_queue_empty
run_test test_notes_segment_counts_only_files
run_test test_mail_segment_shows_unread_count
run_test test_mail_segment_absent_when_all_read
run_test test_mail_segment_ignores_non_json_entries
run_test test_mail_segment_counts_the_vault_mailbox
run_test test_notes_segment_counts_the_vault_queue
run_test test_pane_segment_hidden_when_tmux_is_foreign
run_test test_pane_segment_absent_outside_tmux
run_test test_pane_segment_needs_both_tmux_vars
run_test test_segment_default_in_sync_across_docs_and_help
run_test test_library_mode_defines_helpers_without_rendering
run_test test_library_mode_prints_nothing
run_test test_executed_directly_still_renders
run_test test_enable_registers_both_status_lines
run_test test_disable_leaves_a_foreign_subagent_statusline_alone
run_test test_enable_warns_that_a_restart_is_required
run_test test_enable_and_disable_rewrite_settings_in_place

# ============================================================================
# Rate-limit stamp: the render writes .cs/local/limits for cs -usage anchoring
# ============================================================================

# rate_limits present + a session context: the render stamps .cs/local/limits.
test_limits_file_written_from_rate_limits() {
    export CLAUDE_SESSION_NAME="limsess"
    mkdir -p "$CS_SESSIONS_ROOT/limsess/.cs/local"
    local fixture='{"session_name":"limsess","model":{"display_name":"Opus"},"context_window":{"used_percentage":8},"cost":{"total_cost_usd":0},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1784041200},"seven_day":{"used_percentage":41.2,"resets_at":1784457600}},"workspace":{"current_dir":"/tmp"}}'
    run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/limsess/.cs/local/limits"
    assert_file_exists "$lim" "limits file should be written" || return 1
    assert_file_contains "$lim" "five_hour_used_pct: 23" "5h pct stamped (integer)" || return 1
    assert_file_contains "$lim" "five_hour_resets_at: 1784041200" "5h reset stamped" || return 1
    assert_file_contains "$lim" "seven_day_used_pct: 41" "week pct stamped (integer)" || return 1
    assert_file_contains "$lim" "seven_day_resets_at: 1784457600" "week reset stamped" || return 1
    assert_file_contains "$lim" "stamped_at: " "stamp present" || return 1
}

# No rate_limits in the stdin JSON (older Claude Code): no limits file.
test_limits_file_skipped_without_rate_limits() {
    export CLAUDE_SESSION_NAME="limsess2"
    mkdir -p "$CS_SESSIONS_ROOT/limsess2/.cs/local"
    local fixture='{"session_name":"limsess2","model":{"display_name":"Opus"},"context_window":{"used_percentage":8},"workspace":{"current_dir":"/tmp"}}'
    run_sl "$fixture" > /dev/null
    assert_file_not_exists "$CS_SESSIONS_ROOT/limsess2/.cs/local/limits" "no limits file without rate_limits" || return 1
}

# Every render-time epoch read (limits stamp, countdown) goes through one
# shared clock; CS_STATUSLINE_NOW pins it, so the stamp reflects the pin rather
# than a raw wall-clock fork.
test_limits_stamp_uses_shared_clock() {
    export CLAUDE_SESSION_NAME="clocksess"
    mkdir -p "$CS_SESSIONS_ROOT/clocksess/.cs/local"
    local fixture='{"session_name":"clocksess","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    CS_STATUSLINE_NOW=1234567890 run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/clocksess/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: 1234567890" "stamp uses the pinned shared clock" || return 1
}

# _sl_now initializes the shared clock in-process; an inherited _NOW from the
# environment must NOT be trusted as already-computed (that would bypass the pin
# and let a garbage value reach the stamp).
test_shared_clock_ignores_inherited_now() {
    export CLAUDE_SESSION_NAME="inhsess"
    mkdir -p "$CS_SESSIONS_ROOT/inhsess/.cs/local"
    local fixture='{"session_name":"inhsess","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    _NOW=garbage CS_STATUSLINE_NOW=1234567890 run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/inhsess/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: 1234567890" "inherited _NOW ignored; pin wins in the stamp" || return 1
}

# Without a pin, an inherited garbage _NOW must be replaced by a real epoch, never
# persisted verbatim (a stale value would make the limits file look newest forever).
test_shared_clock_replaces_inherited_garbage() {
    export CLAUDE_SESSION_NAME="inhsess2"
    mkdir -p "$CS_SESSIONS_ROOT/inhsess2/.cs/local"
    local fixture='{"session_name":"inhsess2","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    _NOW=garbage run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/inhsess2/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: [0-9]" "stamp is a real epoch, not inherited garbage" || return 1
}

# The memo ready-flag itself must not be trusted from the environment: with BOTH
# _SL_NOW_READY and a garbage _NOW inherited, the render still sanitizes them and
# honors the pin (not the inherited garbage) in the stamp.
test_shared_clock_ignores_inherited_ready_flag() {
    export CLAUDE_SESSION_NAME="inhready"
    mkdir -p "$CS_SESSIONS_ROOT/inhready/.cs/local"
    local fixture='{"session_name":"inhready","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    _SL_NOW_READY=1 _NOW=garbage CS_STATUSLINE_NOW=1234567890 run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/inhready/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: 1234567890" "inherited ready flag + garbage _NOW sanitized; pin wins" || return 1
}

# A leading-zero clock value (e.g. a pin of 08) passes a bare digit check but is
# read as octal by bash arithmetic, aborting on an 8/9 digit. The clock must be
# normalized to canonical base-10 before it reaches the stamp/countdown.
test_shared_clock_normalizes_leading_zero_pin() {
    export CLAUDE_SESSION_NAME="zeropin"
    mkdir -p "$CS_SESSIONS_ROOT/zeropin/.cs/local"
    local fixture='{"session_name":"zeropin","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    CS_STATUSLINE_NOW=08 run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/zeropin/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: 8$" "leading-zero pin normalized to base-10" || return 1
}

# The bar repaints on every Claude Code event and once a minute when idle, so
# a claude still running after `cs -rm <name> --force` renders for a session
# that is gone. The render stamps context-pct and limits only in a .cs that
# is there, making the missing .cs/local in it; a removed session stays
# removed. Rendered under the bash running this suite.
test_render_never_recreates_a_removed_session() {
    local fixture='{"session_name":"s","workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20}}}'
    mkdir -p "$CS_SESSIONS_ROOT/live/.cs"
    printf '%s' "$fixture" | CLAUDE_SESSION_NAME=live "$BASH" "$SL" > /dev/null \
        || { echo "  FAIL: the render for a live session failed"; return 1; }
    assert_eq "42" "$(cat "$CS_SESSIONS_ROOT/live/.cs/local/context-pct" 2>/dev/null)" "a live session gets its context-pct" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/live/.cs/local/limits" "^five_hour_used_pct: 10$" "a live session gets its limits" || return 1
    printf '%s' "$fixture" | CLAUDE_SESSION_NAME=gone "$BASH" "$SL" > /dev/null \
        || { echo "  FAIL: the render for a removed session failed"; return 1; }
    assert_not_exists "$CS_SESSIONS_ROOT/gone" "the render does not make a removed session again" || return 1
}

# A hook or a second render can make .cs/local between a render's look for it
# and its mkdir. A DEBUG trap loaded through BASH_ENV stands in for that
# writer: before each mkdir of the render it makes the directory. The
# directory is there, which is all the stamp needs: the render still writes
# its reading, the context one and, in a render that carries only limits, the
# limits one.
test_render_counts_a_local_dir_another_writer_made_first() {
    local seam="$TEST_TMPDIR/peer-seam.sh"
    cat > "$seam" << 'SEAM'
set -o functrace
_cs_test_peer() {
    case "$BASH_COMMAND" in mkdir\ *) ;; *) return 0 ;; esac
    command mkdir "$CS_TEST_PEER_DIR" 2>/dev/null
    : > "$CS_TEST_PEER_RAN"
    return 0
}
trap _cs_test_peer DEBUG
SEAM
    mkdir -p "$CS_SESSIONS_ROOT/ctx/.cs" "$CS_SESSIONS_ROOT/lim/.cs"
    printf '%s' '{"session_name":"s","workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42}}' \
        | CLAUDE_SESSION_NAME=ctx BASH_ENV="$seam" CS_TEST_PEER_RAN="$TEST_TMPDIR/peer-ran-ctx" \
            CS_TEST_PEER_DIR="$CS_SESSIONS_ROOT/ctx/.cs/local" "$BASH" "$SL" > /dev/null \
        || { echo "  FAIL: the context render failed"; return 1; }
    assert_exists "$TEST_TMPDIR/peer-ran-ctx" "the second writer ran before the context render's mkdir" || return 1
    assert_eq "42" "$(cat "$CS_SESSIONS_ROOT/ctx/.cs/local/context-pct" 2>/dev/null)" "the context reading is stamped" || return 1
    printf '%s' '{"session_name":"s","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":10}}}' \
        | CLAUDE_SESSION_NAME=lim BASH_ENV="$seam" CS_TEST_PEER_RAN="$TEST_TMPDIR/peer-ran-lim" \
            CS_TEST_PEER_DIR="$CS_SESSIONS_ROOT/lim/.cs/local" "$BASH" "$SL" > /dev/null \
        || { echo "  FAIL: the limits render failed"; return 1; }
    assert_exists "$TEST_TMPDIR/peer-ran-lim" "the second writer ran before the limits render's mkdir" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/lim/.cs/local/limits" "^five_hour_used_pct: 10$" "the limits reading is stamped" || return 1
}

# ============================================================================
# Theme resolution: CS_TERM_THEME pin wins; else follow the terminal live
# (macOS OS appearance, tty-safe) so a mid-session dark-mode switch is tracked;
# else the frozen launch fallback. See _sl_detect_theme in cs-statusline.
# ============================================================================

# _sl_detect_theme assigns SL_THEME (no subshell). An explicit pin is
# CS_TERM_THEME set with NO auto marker; it wins everywhere.
test_sl_theme_user_pin_overrides() {
    ( _load_sl_functions
      export CS_TERM_THEME=dark
      unset CS_TERM_THEME_AUTO 2>/dev/null || true
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "an explicit CS_TERM_THEME pin wins" || return 1 )
}


test_sl_theme_non_macos_uses_frozen_launch_value() {
    ( _load_sl_functions
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1
      OSTYPE="linux-gnu"
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "non-macOS keeps the launch theme" || return 1 )
}

# cs assumes dark wherever it has nothing to go on — lib/05-term.sh and the
# rewriter shim both read ${CS_TERM_THEME:-dark}. The statusline read
# ${CS_TERM_THEME:-light}, so the same unknown produced two different palettes
# in one product. This pins them to agree.
test_sl_theme_non_macos_defaults_dark() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO 2>/dev/null || true
      OSTYPE="linux-gnu"
      # The appearance probe is macOS-only and costs a fork; off macOS the
      # theme must resolve without reaching for it at all, not merely land on
      # the same answer after asking.
      _defaults_called=0; defaults() { _defaults_called=1; return 0; }
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "non-macOS with no launch theme defaults dark, as the rest of cs does" || return 1
      assert_eq "0" "$_defaults_called" "non-macOS must not run the appearance probe" || return 1 )
}


# The OS appearance describes the system, not the terminal the capsules are
# drawn on, and the two are unrelated for a fixed-theme terminal or one
# embedded in an app. With no signal from the terminal itself, an unknown is
# dark — the assumption the rest of cs makes — rather than a guess sourced
# from the OS.
test_sl_theme_unknown_is_dark_on_macos() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO COLORFGBG TMUX 2>/dev/null || true
      OSTYPE="darwin24"
      _defaults_called=0; defaults() { _defaults_called=1; return 1; }
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "an unknown terminal is dark, not whatever macOS is wearing" || return 1
      assert_eq "0" "$_defaults_called" "and the OS is not consulted at all" || return 1 )
}

# The cost of the above, pinned so it is a decision on the record rather than a
# surprise: a light terminal that reports nothing now renders the dark palette.
# Terminals that do report — or sessions cs launched, which measure the
# background — are unaffected, which is what keeps the blast radius narrow.
test_sl_theme_unknown_light_terminal_now_renders_dark() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO COLORFGBG 2>/dev/null || true
      TMUX="/tmp/fake,1,0"; OSTYPE="darwin24"
      tmux() { printf '\t/dev/ttys002\n'; }     # client reports no theme
      defaults() { return 1; }    # macOS is light, and no longer consulted
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "a silent light terminal renders dark: the accepted cost of not asking the OS" || return 1 )
}

# A measured session still wins over the default: cs-launched sessions carry the
# real background and must not be dragged to dark by it.
test_sl_theme_measured_launch_beats_the_dark_default() {
    ( _load_sl_functions
      unset COLORFGBG TMUX 2>/dev/null || true
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1
      OSTYPE="darwin24"
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "a measured light terminal stays light" || return 1 )
}

# A session cs did not launch carries none of cs's environment, so the ladder
# falls straight to the OS appearance and renders light on a dark terminal —
# the palette follows macOS rather than the surface the capsules sit on. Two
# rungs fill that gap, each mirroring a policy the launch detector already has.

# Outside tmux, COLORFGBG is the terminal's own statement about itself.
test_sl_theme_uses_colorfgbg_outside_tmux() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO TMUX 2>/dev/null || true
      COLORFGBG="15;0"; OSTYPE="darwin24"
      defaults() { return 1; }   # macOS says light; the terminal says dark
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "a terminal reporting a dark background outranks the OS appearance" || return 1 )
}

test_sl_theme_colorfgbg_light_outside_tmux() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO TMUX 2>/dev/null || true
      COLORFGBG="0;15"; OSTYPE="darwin24"
      defaults() { return 0; }   # macOS says dark; the terminal says light
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "and in the other direction" || return 1 )
}

# Inside tmux it is the tmux server's start-time snapshot and goes stale across
# theme changes — the repo records observing 15;0 under a light terminal — so it
# must not speak there, exactly as the launch detector refuses it.
test_sl_theme_ignores_colorfgbg_inside_tmux() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO 2>/dev/null || true
      TMUX="/tmp/fake,1,0"; COLORFGBG="15;0"; OSTYPE="darwin24"
      tmux() { return 1; }       # no client theme available
      defaults() { return 1; }   # macOS says light
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "a stale COLORFGBG must not speak inside tmux; unknown falls through to dark" || return 1 )
}

# Inside tmux the live signal is the client's own reported theme, when the
# terminal reports one at all.
test_sl_theme_uses_tmux_client_theme() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO COLORFGBG 2>/dev/null || true
      TMUX="/tmp/fake,1,0"; OSTYPE="darwin24"
      tmux() { printf 'dark\t/dev/ttys002\n'; }   # the attached client reports dark
      defaults() { return 1; }      # macOS says light
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "the attached client's reported theme outranks the OS" || return 1 )
}

# Empty is the common case — most terminals report nothing — and must fall
# through rather than being read as a value.
test_sl_theme_falls_through_empty_client_theme() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO COLORFGBG 2>/dev/null || true
      TMUX="/tmp/fake,1,0"; OSTYPE="darwin24"
      tmux() { printf '\t/dev/ttys002\n'; }
      defaults() { return 0; }   # macOS says dark
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" \
        "an empty client theme must fall through to the OS, not blank the palette" || return 1 )
}

# _sl_invalidate_stale_bg blanks CS_TERM_BG_RGB once the live theme (SL_THEME)
# has left the launch theme (CS_TERM_THEME + auto marker), so the surface
# doesn't tint toward the old background.
test_sl_bg_rgb_dropped_after_switch() {
    ( _load_sl_functions
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1 CS_TERM_BG_RGB="250;248;242"
      SL_THEME=dark   # live theme switched away from the launch light
      _sl_invalidate_stale_bg
      assert_eq "" "$CS_TERM_BG_RGB" "stale RGB dropped when the live theme left the launch theme" || return 1 )
}

test_sl_bg_rgb_kept_when_theme_matches() {
    ( _load_sl_functions
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1 CS_TERM_BG_RGB="250;248;242"
      SL_THEME=light   # live theme still matches launch
      _sl_invalidate_stale_bg
      assert_eq "250;248;242" "$CS_TERM_BG_RGB" "RGB kept when the live theme matches launch" || return 1 )
}

test_sl_bg_rgb_kept_for_manual_value() {
    ( _load_sl_functions
      unset CS_TERM_THEME_AUTO CS_TERM_THEME 2>/dev/null || true
      export CS_TERM_BG_RGB="1;2;3"
      SL_THEME=dark
      _sl_invalidate_stale_bg
      assert_eq "1;2;3" "$CS_TERM_BG_RGB" "a manually-set RGB (no auto marker) is never dropped" || return 1 )
}

run_test test_limits_file_written_from_rate_limits
run_test test_limits_file_skipped_without_rate_limits
run_test test_limits_stamp_uses_shared_clock
run_test test_shared_clock_ignores_inherited_now
run_test test_shared_clock_replaces_inherited_garbage
run_test test_shared_clock_ignores_inherited_ready_flag
run_test test_shared_clock_normalizes_leading_zero_pin
run_test test_render_never_recreates_a_removed_session
run_test test_render_counts_a_local_dir_another_writer_made_first
run_test test_sl_theme_user_pin_overrides
run_test test_sl_theme_non_macos_uses_frozen_launch_value
run_test test_sl_theme_non_macos_defaults_dark
run_test test_sl_theme_unknown_is_dark_on_macos
run_test test_sl_theme_unknown_light_terminal_now_renders_dark
run_test test_sl_theme_measured_launch_beats_the_dark_default
run_test test_sl_theme_uses_colorfgbg_outside_tmux
run_test test_sl_theme_colorfgbg_light_outside_tmux
run_test test_sl_theme_ignores_colorfgbg_inside_tmux
run_test test_sl_theme_uses_tmux_client_theme
run_test test_client_cache_supplies_theme_and_background
run_test test_client_cache_misses_after_reattach_from_another_terminal
run_test test_client_cache_does_not_override_an_explicit_background
run_test test_client_cache_rejects_a_malformed_entry
run_test test_level_drops_to_256_when_truecolor_will_be_muted
run_test test_level_stays_truecolor_when_the_flag_is_present
run_test test_level_stays_truecolor_outside_tmux
run_test test_foreign_tmux_does_not_downgrade_a_real_truecolor_terminal
run_test test_tmux_mute_applies_regardless_of_term_name
run_test test_client_cache_is_read_outside_tmux_too
run_test test_unusable_ps_is_not_evidence_of_a_foreign_tmux
run_test test_client_cache_refuses_a_stale_entry
run_test test_client_cache_accepts_a_fresh_entry
run_test test_sl_theme_falls_through_empty_client_theme
run_test test_sl_bg_rgb_dropped_after_switch
run_test test_sl_bg_rgb_kept_when_theme_matches
run_test test_sl_bg_rgb_kept_for_manual_value
run_test test_sl_tmux_real_when_server_is_ancestor
run_test test_sl_tmux_fake_when_server_not_ancestor
run_test test_sl_tmux_fake_when_server_field_malformed
run_test test_sl_tmux_walk_terminates_on_cycle
run_test test_sl_theme_dark_when_tmux_is_foreign
run_test test_sl_theme_uses_client_rung_when_tmux_is_real
run_test test_sl_env_foreign_ignores_inherited_value
run_test test_sl_bg_rgb_dropped_when_foreign_despite_matching_theme
run_test test_sl_bg_rgb_kept_for_manual_value_when_foreign
run_test test_sl_bg_rgb_kept_when_pinned_beside_an_auto_theme

# --- Fable usage segment ----------------------------------------------------

# The usage endpoint sends ISO 8601 with fractional seconds and a +00:00 offset;
# _fmt_rest wants epoch seconds. The expected value is an independently known
# instant, not one recomputed with the same date call the helper uses.
test_iso_epoch_parses_endpoint_format() {
    _load_sl_functions
    _iso_epoch "2026-08-29T03:59:59.686034+00:00"
    assert_eq "1787975999" "$_EPOCH" "fractional seconds and +00:00 offset must parse as UTC" || return 1
    _iso_epoch "2026-08-29T03:59:59Z"
    assert_eq "1787975999" "$_EPOCH" "a trailing Z must parse to the same instant" || return 1
    _iso_epoch "2026-08-29T03:59:59"
    assert_eq "1787975999" "$_EPOCH" "a bare timestamp must be read as UTC" || return 1
}

# Garbage must yield empty, never a partial value and never a previous one left
# standing: a stale epoch would render a confidently wrong countdown.
test_iso_epoch_rejects_junk() {
    _load_sl_functions
    _iso_epoch "2026-08-29T03:59:59Z"
    _iso_epoch "not-a-timestamp"
    assert_eq "" "$_EPOCH" "unparseable input must clear _EPOCH" || return 1
    _iso_epoch ""
    assert_eq "" "$_EPOCH" "empty input must yield empty" || return 1
    _iso_epoch "2026-13-45T99:99:99Z"
    assert_eq "" "$_EPOCH" "an out-of-range timestamp must yield empty" || return 1
}

run_test test_iso_epoch_parses_endpoint_format
run_test test_iso_epoch_rejects_junk

# The fable gate keys on the model id, so the parse must carry it. One value per
# line means a field added in the wrong position silently shifts every later
# field, so this pins a neighbour on each side rather than the new field alone.
test_parse_carries_model_id() {
    _load_sl_functions
    _parse_stdin '{"model":{"id":"claude-fable-5","display_name":"Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":8}}'
    assert_eq "claude-fable-5" "$SL_MODEL_ID" "model id must be parsed from stdin" || return 1
    assert_eq "high" "$SL_EFFORT" "the field after model id must not be shifted" || return 1
    assert_eq "8" "$SL_CTX" "the field before model id must not be shifted" || return 1
    assert_eq "Fable" "$SL_MODEL" "display name must still land in SL_MODEL" || return 1
}

run_test test_parse_carries_model_id

# Put a fake keychain reader and a fake curl in place so the refresher runs its
# real code path with no network and no Keychain. $1 is the HTTP status the fake
# curl reports, $2 the body it writes to curl's -o target. Echoes the bin dir.
# `security` is reached through CS_SECURITY_BIN rather than PATH because the
# production path is pinned absolute (a credential reader must not be
# interceptable by a PATH entry); curl is not a credential tool, so PATH is fine.
#
# Sets USAGE_BINDIR rather than echoing it, and MUST NOT be called through
# $(...): the CS_SECURITY_BIN export would die with the substitution subshell
# and the refresher would read the developer's real Keychain instead.
make_usage_shims() {
    local code="$1" body="$2"
    local bindir="$TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
# Record argv and stdin so a test can prove where the bearer travelled.
printf '%s\n' "\$*" > "$TEST_TMPDIR/curl-argv"
cat > "$TEST_TMPDIR/curl-stdin"
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "\$out" ] && printf '%s' '$body' > "\$out"
printf '%s' '$code'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    USAGE_BINDIR="$bindir"
}

# Point the refresher at a scratch cache and a scratch Claude config naming
# account "org-abc".
use_scratch_usage_env() {
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
}

# Shaped like the real endpoint: the unified windows sit in the same limits[]
# array with a null model scope and must be skipped. Selecting by position, or
# taking the first entry, would silently record the 5-hour number as Fable's.
USAGE_BODY='{"five_hour":{"utilization":31.0},"seven_day":{"utilization":49.0},"limits":[{"scope":{"type":"unified"},"percent":31,"resets_at":"2026-08-27T10:39:59.6Z"},{"scope":{"type":"unified"},"percent":49,"resets_at":"2026-08-29T03:59:59.6Z"},{"scope":{"model":{"display_name":"Fable"}},"percent":86,"resets_at":"2026-08-29T03:59:59.686034+00:00"}]}'

test_refresh_writes_fable_window() {
    make_usage_shims 200 "$USAGE_BODY"
    use_scratch_usage_env
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local cache="$CS_USAGE_DIR/fable.org-abc.json"
    assert_file_exists "$cache" "refresh must write the cache" || return 1
    assert_eq "86" "$(jq -r '.pct' "$cache")" "must record the Fable bucket, not a unified window" || return 1
    assert_eq "2026-08-29T03:59:59.686034+00:00" "$(jq -r '.resets_at' "$cache")" "must record the Fable reset stamp" || return 1
    assert_eq "org-abc" "$(jq -r '.org' "$cache")" "must stamp the account the reading belongs to" || return 1
    assert_eq "1787816000" "$(jq -r '.fetched_at' "$cache")" "must stamp when it was fetched" || return 1
    assert_eq "1787816600" "$(jq -r '.next_poll_at' "$cache")" "next poll must be the 600s floor out" || return 1
}

# The bearer must never reach argv, where any process on the machine can read it
# out of `ps`. It goes to curl on stdin as a -K config line.
test_refresh_keeps_token_off_argv() {
    make_usage_shims 200 "$USAGE_BODY"
    use_scratch_usage_env
    PATH="$USAGE_BINDIR:$PATH" bash "$SL" --refresh-usage
    # Assert on a yes/no derivative, never on the captured bytes: an assertion
    # that echoes its input prints a live credential the day this test fails.
    local on_argv=no on_stdin=no
    grep -q 'test-token-not-real' "$TEST_TMPDIR/curl-argv" && on_argv=yes
    grep -q 'test-token-not-real' "$TEST_TMPDIR/curl-stdin" && on_stdin=yes
    assert_eq "no" "$on_argv" "the access token must not appear in curl's arguments" || return 1
    assert_eq "yes" "$on_stdin" "the access token must reach curl on stdin" || return 1
}

# A 429 must not overwrite the last good reading, and must back off past the
# 300s floor: a 429 does not reliably clear at its stated horizon.
test_refresh_429_backs_off_and_keeps_last_good() {
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":42,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787815000,"next_poll_at":1787815300}' \
        > "$CS_USAGE_DIR/fable.org-abc.json"
    make_usage_shims 429 ''
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local cache="$CS_USAGE_DIR/fable.org-abc.json"
    assert_eq "42" "$(jq -r '.pct' "$cache")" "a 429 must leave the last good reading intact" || return 1
    assert_eq "1787815000" "$(jq -r '.fetched_at' "$cache")" "a 429 must not restamp the reading as fresh" || return 1
    assert_eq "1787816600" "$(jq -r '.next_poll_at' "$cache")" "a 429 must back off at least the failure interval" || return 1
}

# An account with no Fable window must record no percentage rather than leave a
# previous account's number standing behind a fresh timestamp.
test_refresh_no_fable_bucket_clears() {
    use_scratch_usage_env
    make_usage_shims 200 '{"limits":[{"scope":{"type":"unified"},"percent":31,"resets_at":"2026-08-27T10:39:59Z"}]}'
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "null" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "an account with no Fable window must record no percentage" || return 1
}

# Every failure path must still stamp next_poll_at, or a broken account makes
# every single render fire another request at an already-strained budget.
test_refresh_without_a_token_still_schedules() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    printf '#!/bin/bash\nexit 44\n' > "$bindir/security"   # errSecItemNotFound
    printf '#!/bin/bash\nexit 1\n' > "$bindir/curl"
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "1787816600" "$(jq -r '.next_poll_at' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "a missing credential must still back off rather than re-fire every render" || return 1
}

# A refresher already running holds the lock; a second must return rather than
# queue behind it and fire a duplicate request.
test_refresh_respects_a_held_lock() {
    make_usage_shims 200 "$USAGE_BODY"
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR/.lock"
    # Pin the lock's mtime 40s before the pinned clock. Without this the age is
    # (pinned NOW - real mtime), which is negative and passes the freshness
    # check for the wrong reason — the test would have started failing the
    # moment real time overtook the pin.
    TZ=UTC touch -t 202608270732.40 "$CS_USAGE_DIR/.lock"
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_file_not_exists "$CS_USAGE_DIR/fable.org-abc.json" \
        "a refresher must not run while another holds a fresh lock" || return 1
}

# The other half of the lock contract, which had no test at all: a lock left by
# a refresher that was killed mid-flight must be reclaimed, or the chip is dead
# on this machine until someone removes the directory by hand.
test_refresh_reclaims_an_abandoned_lock() {
    make_usage_shims 200 "$USAGE_BODY"
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR/.lock"
    TZ=UTC touch -t 202608270730.00 "$CS_USAGE_DIR/.lock"   # 200s before the pin
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "a lock older than the reclaim window must not block a refresh" || return 1
    assert_not_exists "$CS_USAGE_DIR/.lock" "the reclaiming refresher must release the lock" || return 1
}

# The caches keyed on the parent pid (tmux-client3 and the tmux-client and
# tmux-client2 entries written before it, tmux-real, tty, stty) mint a new entry per conversation
# and nothing on the render path may fork to remove them, so the refresher
# sweeps them. Only those: a cache keyed on a repeating identity is left alone.
test_refresh_prunes_the_pid_keyed_caches() {
    make_usage_shims 200 "$USAGE_BODY"
    use_scratch_usage_env
    local cache="$HOME/.cache/cs"
    mkdir -p "$cache/tmux-client" "$cache/tmux-client2" "$cache/tmux-client3" "$cache/tmux-real" "$cache/tmux-walking" "$cache/tty" "$cache/stty" "$cache/git"
    TZ=UTC touch -t 202608270730.00 "$cache/tmux-client/old" "$cache/tmux-client2/old" "$cache/tmux-client3/old" "$cache/tmux-real/old" "$cache/tmux-walking/old" "$cache/tty/old" "$cache/stty/old" "$cache/git/old"
    touch "$cache/tmux-client/fresh" "$cache/tmux-client2/fresh" "$cache/tmux-client3/fresh" "$cache/tmux-real/fresh" "$cache/tty/fresh" "$cache/stty/fresh"
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_not_exists "$cache/tmux-client/old" "an old tmux-client entry must be swept" || return 1
    assert_not_exists "$cache/tmux-real/old" "an old tmux-real entry must be swept" || return 1
    assert_not_exists "$cache/tty/old" "an old tty entry must be swept" || return 1
    assert_not_exists "$cache/tmux-client2/old" "an old tmux-client2 entry must be swept" || return 1
    assert_not_exists "$cache/tmux-client3/old" "an old tmux-client3 entry must be swept" || return 1
    assert_not_exists "$cache/stty/old" "an old stty entry must be swept" || return 1
    assert_exists "$cache/tmux-client/fresh" "a fresh tmux-client entry must survive" || return 1
    assert_exists "$cache/tmux-real/fresh" "a fresh tmux-real entry must survive" || return 1
    assert_exists "$cache/tty/fresh" "a fresh tty entry must survive" || return 1
    assert_exists "$cache/tmux-client2/fresh" "a fresh tmux-client2 entry must survive" || return 1
    assert_exists "$cache/tmux-client3/fresh" "a fresh tmux-client3 entry must survive" || return 1
    assert_exists "$cache/stty/fresh" "a fresh stty entry must survive" || return 1
    assert_exists "$cache/git/old" "the sweep must not touch a cache keyed on a repeating identity" || return 1
}

# The Retry-After branch had no test: a server asking for a longer wait than the
# floor must be honoured, or cs keeps knocking while it is blocked.
test_refresh_honours_retry_after() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
hdr=""
while [ \$# -gt 0 ]; do
    case "\$1" in -D) hdr="\$2"; shift 2 ;; *) shift ;; esac
done
[ -n "\$hdr" ] && printf 'HTTP/2 429\r\nretry-after: 900\r\n\r\n' > "\$hdr"
printf '429'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "1787816960" "$(jq -r '.next_poll_at' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "Retry-After must be honoured with a 60s margin (900+60) over the 600s floor" || return 1
}

# A Retry-After too long for the shell's arithmetic wraps to a positive number
# centuries away, and cs would never poll usage again. A header cs cannot judge
# takes the floor, the same answer as a header that is not a number at all.
test_refresh_ignores_an_overflowing_retry_after() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
hdr=""
while [ \$# -gt 0 ]; do
    case "\$1" in -D) hdr="\$2"; shift 2 ;; *) shift ;; esac
done
[ -n "\$hdr" ] && printf 'HTTP/2 429\r\nretry-after: 99999999999999999999\r\n\r\n' > "\$hdr"
: > "$TEST_TMPDIR/curl.ran"
printf '429'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "1787816600" "$(jq -r '.next_poll_at' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "an unusable Retry-After falls back to the 600s floor" || return 1
    # The 600 s floor is also what a missing token or a curl that never ran
    # writes, so the assertion above proves nothing on its own.
    assert_file_exists "$TEST_TMPDIR/curl.ran" "the 429 path was reached, not a credential failure" || return 1
}

# A Retry-After short enough to pass the digit cap can still park the next poll
# past any horizon worth honouring: 999999999999999 seconds is 31 million years,
# and the cache consumer waits wherever the deadline says. Backoff has a ceiling.
test_refresh_caps_a_huge_retry_after() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
hdr=""
while [ \$# -gt 0 ]; do
    case "\$1" in -D) hdr="\$2"; shift 2 ;; *) shift ;; esac
done
[ -n "\$hdr" ] && printf 'HTTP/2 429\r\nretry-after: 999999999999999\r\n\r\n' > "\$hdr"
: > "$TEST_TMPDIR/curl.ran"
printf '429'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "1787819600" "$(jq -r '.next_poll_at' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "a Retry-After past the ceiling waits an hour, not an age" || return 1
    assert_file_exists "$TEST_TMPDIR/curl.ran" "the 429 path was reached, not a credential failure" || return 1
}

run_test test_refresh_writes_fable_window
run_test test_refresh_keeps_token_off_argv
run_test test_refresh_429_backs_off_and_keeps_last_good
run_test test_refresh_no_fable_bucket_clears
run_test test_refresh_without_a_token_still_schedules
run_test test_refresh_respects_a_held_lock
run_test test_refresh_reclaims_an_abandoned_lock
run_test test_refresh_prunes_the_pid_keyed_caches
run_test test_refresh_honours_retry_after
run_test test_refresh_ignores_an_overflowing_retry_after
run_test test_refresh_caps_a_huge_retry_after

# Seed a cache record and a Claude config naming account "org-abc".
# $1 org, $2 pct, $3 resets_at, $4 fetched_at, $5 next_poll_at.
seed_usage_cache() {
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    jq -n --arg o "$1" --argjson p "$2" --arg r "$3" --argjson f "$4" --argjson n "$5" \
        '{org:$o,pct:$p,resets_at:$r,fetched_at:$f,next_poll_at:$n}' > "$CS_USAGE_DIR/fable.$1.json"
}

test_fable_read_returns_fresh_reading() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59.686034+00:00" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "86" "$_FABLE_PCT" "a fresh same-account reading must be returned" || return 1
    assert_eq "1787975999" "$_FABLE_RESET" "resets_at must arrive as epoch seconds" || return 1
    assert_eq "" "$_FABLE_DUE" "a cache inside its poll interval must not be due" || return 1
}

# Swapping accounts must blank the chip at once rather than leave the previous
# account's percentage up until the next poll — an account swap happens when one
# account is near a limit, which is exactly when a wrong number misleads most.
test_fable_read_blanks_on_account_mismatch() {
    _load_sl_functions
    seed_usage_cache org-other 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "" "$_FABLE_PCT" "a reading for another account must not render" || return 1
    assert_eq "1" "$_FABLE_DUE" "an account mismatch must force a refresh" || return 1
}

test_fable_read_blanks_when_stale() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787819500
    CS_STATUSLINE_NOW=1787819000 _NOW="" _SL_NOW_READY="" _fable_read   # 3000s after the fetch
    assert_eq "" "$_FABLE_PCT" "a reading older than 1800s must not render" || return 1
}

test_fable_read_marks_due_past_next_poll() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816400 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "1" "$_FABLE_DUE" "past next_poll_at the cache must be due" || return 1
    assert_eq "86" "$_FABLE_PCT" "a due cache still renders its last good reading" || return 1
}

test_fable_read_absent_cache_is_due_and_blank() {
    _load_sl_functions
    export CS_USAGE_DIR="$TEST_TMPDIR/usage-none"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "" "$_FABLE_PCT" "no cache means no reading" || return 1
    assert_eq "1" "$_FABLE_DUE" "no cache must be due for a first fetch" || return 1
}

# A record written for an account with no Fable window carries pct null; that
# must read as "nothing to show", not as a zero percent.
test_fable_read_null_pct_is_blank_not_zero() {
    _load_sl_functions
    seed_usage_cache org-abc null "" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "" "$_FABLE_PCT" "a null percentage must render nothing, not 0%" || return 1
}

run_test test_fable_read_returns_fresh_reading
run_test test_fable_read_blanks_on_account_mismatch
run_test test_fable_read_blanks_when_stale
run_test test_fable_read_marks_due_past_next_poll
run_test test_fable_read_absent_cache_is_due_and_blank
run_test test_fable_read_null_pct_is_blank_not_zero

# The chip renders only on Fable. Every other model must pay nothing for it.
test_fable_segment_only_on_fable() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-opus-5","display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains "$out" "fable" "a non-fable model must not render the fable chip" || return 1
}

test_fable_segment_hidden_below_seventy_on_fable() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 42 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains "$out" "fable 42%" "a fable window below seventy stays hidden" || return 1
}

test_fable_segment_renders_when_hot() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 85%" "a hot fable session renders the window" || return 1
}

# A context-window suffix must not defeat the gate: the id arrives as
# claude-fable-5[1m] on a 1M-context session.
test_fable_segment_matches_1m_variant() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5[1m]","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 85% · 1d20h" "claude-fable-5[1m] must still gate on" || return 1
}

# At 80% and up the countdown appears, matching the weekly block's gate. The
# expected string comes from the two known instants (1787975999 - 1787816100 =
# 159899s = 1d20h), not from _fmt_rest recomputing it the same way the code does.
test_fable_segment_countdown_at_80() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 86% · 1d20h" "at 80%+ the countdown must be appended" || return 1
}

test_fable_segment_escalates_colour() {
    export CS_USAGE_NO_REFRESH=1 COLORTERM=truecolor
    seed_usage_cache org-abc 95 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable" "the chip must render" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m95%" "at 90%+ the capsule must invert to the crit fill" || return 1
}

# A stale or absent reading must cost the bar the chip, not give it a wrong one.
test_fable_segment_absent_without_a_reading() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    export CS_USAGE_DIR="$TEST_TMPDIR/usage-none"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    local json='{"session_name":"zulu-session","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains "$out" "fable " "no reading means no chip" || return 1
    assert_output_contains "$out" "zulu-session" "the rest of the bar must still render" || return 1
}

# Cheapness off Fable is a design property, not an accident: a session on any
# other model must not read the cache, evaluate whether a poll is due, or add a
# segment. Asserted synchronously against the segment function. An earlier
# version watched for the detached refresher's side effects instead and was
# vacuous — adversarial review proved it passed even with the gate widened to
# every model, because assert_not_exists ran before the orphaned refresher
# reached its mkdir.
test_fable_segment_costs_nothing_off_fable() {
    _load_sl_functions
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    export CS_USAGE_DIR="$TEST_TMPDIR/usage-untouched"
    SL_MODEL_ID="claude-sonnet-5"
    SL_5H=""; SL_WK=""
    # Sentinels the gate must leave alone: _fable_read clears all three on its
    # first lines, so surviving values prove it was never entered.
    _FABLE_PCT=sentinel; _FABLE_RESET=sentinel; _FABLE_DUE=sentinel
    _SEG_TEXT=(); _SEG_GROUP=(); _SEG_INK=(); _SEG_BOLD=(); _SEG_JOIN=(); _SEG_ROLE=()
    _GROUPS=(); _GROUPS_SEEN=""; _CRIT_GROUPS=""
    _seg_limits
    assert_eq "sentinel" "$_FABLE_PCT" "a non-fable model must not read the cache" || return 1
    assert_eq "sentinel" "$_FABLE_DUE" "a non-fable model must not evaluate whether a poll is due" || return 1
    assert_eq "0" "${#_SEG_TEXT[@]}" "a non-fable model must add no segment" || return 1
    assert_not_exists "$CS_USAGE_DIR" "a non-fable model must not create the usage cache dir" || return 1
}

# Exits 0 when the cached fable reading for org-abc is <pct>.
_usage_pct_is() {  # pct
    [ "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json" 2>/dev/null)" = "$1" ]
}

# The refresh must actually fire when the cache is due — a render that never
# kicks one would leave the chip frozen at its first reading forever.
test_fable_segment_kicks_a_refresh_when_due() {
    export NO_COLOR=1
    make_usage_shims 200 "$USAGE_BODY"
    seed_usage_cache org-abc 42 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816400 run_sl "$json" >/dev/null
    # The refresher is detached and starts later on a loaded machine, so wait
    # for its write rather than racing it.
    wait_until _usage_pct_is 86
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "a due cache must trigger a detached refresh that rewrites the reading" || return 1
}

run_test test_fable_segment_only_on_fable
run_test test_fable_segment_hidden_below_seventy_on_fable
run_test test_fable_segment_renders_when_hot
run_test test_fable_segment_matches_1m_variant
run_test test_fable_segment_countdown_at_80
run_test test_fable_segment_escalates_colour
run_test test_fable_segment_absent_without_a_reading
run_test test_fable_segment_costs_nothing_off_fable
run_test test_fable_segment_kicks_a_refresh_when_due

# C1: a failed fetch must not re-label the previous account's reading with the
# account signed in now. Carrying a number forward is only ever valid within one
# account; across a swap it renders another account's usage as this one's, and
# the carried fetched_at keeps it looking fresh so no refresh is even due.
test_refresh_failure_does_not_relabel_another_accounts_reading() {
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR"
    # Another account's record, sitting in the same cache directory.
    printf '%s' '{"org":"org-other","pct":86,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787816000,"next_poll_at":1787816300}' \
        > "$CS_USAGE_DIR/fable.org-other.json"
    make_usage_shims 429 ''
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816100 bash "$SL" --refresh-usage
    # Records are addressed by account, so a failed fetch for org-abc cannot
    # reach org-other's reading at all — the carry-forward has nothing of
    # another account's to carry. This is the stronger form of the original
    # guarantee: not "discards it correctly" but "can never see it".
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-other.json")" \
        "another account's record must be untouched by this account's refresh" || return 1
    local mine="$CS_USAGE_DIR/fable.org-abc.json"
    assert_file_exists "$mine" "the failure must still schedule this account's retry" || return 1
    assert_eq "null" "$(jq -r '.pct' "$mine")" "with no prior reading of its own, this account records none" || return 1
    assert_eq "0" "$(jq -r '.fetched_at' "$mine")" "and it must not be stamped fresh" || return 1
    assert_eq "1787816700" "$(jq -r '.next_poll_at' "$mine")" "a failure must back off 600s" || return 1
}

run_test test_refresh_failure_does_not_relabel_another_accounts_reading

# I2: a corrupt cache must still be due. Otherwise the jq failure returns before
# _FABLE_DUE is raised, no refresh is ever kicked, and the chip stays dead until
# somebody deletes the file by hand.
test_fable_read_corrupt_cache_is_due() {
    _load_sl_functions
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    printf '%s' 'not json at all' > "$CS_USAGE_DIR/fable.org-abc.json"
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "" "$_FABLE_PCT" "a corrupt cache must render nothing" || return 1
    assert_eq "1" "$_FABLE_DUE" "a corrupt cache must be due so the next render repairs it" || return 1
}

run_test test_fable_read_corrupt_cache_is_due

# Linux and WSL2 are supported platforms and have no Keychain: Claude Code keeps
# the same credential in <config_home>/.credentials.json there. Without this the
# chip could never render off macOS, which no doc said.
test_refresh_reads_the_plaintext_credential_when_security_is_absent() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir" "$TEST_TMPDIR/cfg"
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > "$TEST_TMPDIR/curl-stdin"
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/no-such-security"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/cfg/.claude.json"
    printf '%s' '{"claudeAiOauth":{"accessToken":"plaintext-token-not-real"}}' \
        > "$TEST_TMPDIR/cfg/.credentials.json"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "with no Keychain the plaintext credential file must be used" || return 1
    local on_stdin=no
    grep -q 'plaintext-token-not-real' "$TEST_TMPDIR/curl-stdin" && on_stdin=yes
    assert_eq "yes" "$on_stdin" "the plaintext bearer must still travel on stdin" || return 1
}

# A non-UTC offset must be refused rather than silently read as UTC: the
# endpoint sends +00:00 today, but reading "+02:00" as UTC would put the reset
# two hours late, and a countdown that is confidently wrong is worse than none.
test_iso_epoch_refuses_a_non_utc_offset() {
    _load_sl_functions
    _iso_epoch "2026-08-29T03:59:59.686034+02:00"
    assert_eq "" "$_EPOCH" "a non-UTC offset must be refused, not silently read as UTC" || return 1
    _iso_epoch "2026-08-29T03:59:59-05:00"
    assert_eq "" "$_EPOCH" "a negative offset must be refused too" || return 1
    _iso_epoch "2026-08-29T03:59:59+00:00"
    assert_eq "1787975999" "$_EPOCH" "an explicit +00:00 must still parse" || return 1
}

run_test test_refresh_reads_the_plaintext_credential_when_security_is_absent
run_test test_iso_epoch_refuses_a_non_utc_offset

# M1: with no curl on the machine the cache is never written, so every render is
# perpetually "due" — and each one forked a subshell plus a full bash load of
# this script only to bail. On every render, per open Fable session.
test_fable_segment_does_not_spawn_a_refresher_without_curl() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    SL_MODEL_ID="claude-fable-5"
    SL_5H=""; SL_WK=""
    _SEG_TEXT=(); _SEG_GROUP=(); _SEG_INK=(); _SEG_BOLD=(); _SEG_JOIN=(); _SEG_ROLE=()
    _GROUPS=(); _GROUPS_SEEN=""; _CRIT_GROUPS=""
    local nocurl="$TEST_TMPDIR/nocurl"; mkdir -p "$nocurl"
    # Symlink, not copy: macOS kills a copied system binary whose code
    # signature no longer validates (SIGKILL, exit 137), which would make this
    # test report "no curl" for the wrong reason — it was jq that died.
    ln -s "$(command -v jq)" "$nocurl/jq"
    # NOW is past next_poll_at, so this render is unambiguously due.
    CS_STATUSLINE_NOW=1787816400 _NOW="" _SL_NOW_READY="" PATH="$nocurl" _seg_limits
    assert_eq "1" "$_FABLE_DUE" "the cache must genuinely be due, or this test proves nothing" || return 1
    assert_eq "" "$_FABLE_KICKED" "with no curl the render must not fork a refresher it knows will fail" || return 1
}

# The other half: with curl present a due cache does kick, so the guard above
# cannot be passing merely because nothing ever kicks.
test_fable_segment_does_spawn_when_curl_is_present() {
    _load_sl_functions
    make_usage_shims 200 "$USAGE_BODY"
    seed_usage_cache org-abc 42 "2026-08-29T03:59:59Z" 1787816000 1787816300
    SL_MODEL_ID="claude-fable-5"
    SL_5H=""; SL_WK=""
    _SEG_TEXT=(); _SEG_GROUP=(); _SEG_INK=(); _SEG_BOLD=(); _SEG_JOIN=(); _SEG_ROLE=()
    _GROUPS=(); _GROUPS_SEEN=""; _CRIT_GROUPS=""
    CS_STATUSLINE_NOW=1787816400 _NOW="" _SL_NOW_READY="" PATH="$USAGE_BINDIR:$PATH" _seg_limits
    assert_eq "1" "$_FABLE_KICKED" "a due cache with curl available must kick a refresher" || return 1
    assert_eq "0" "${#_SEG_TEXT[@]}" "a window below seventy stays hidden even while a refresh is kicked" || return 1
    # Wait for the refresher's WRITE, not for its lock: the lock appears tens of
    # ms after the spawn, so a loop waiting for it to vanish can fall through
    # before it ever exists and leave teardown racing a live refresher. The
    # seeded pct differs from the shim body's 86 so the write is observable.
    wait_until _usage_pct_is 86
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" "the kicked refresher must complete its write" || return 1
    # The refresher drops its lock after the write; teardown waits for that.
    wait_until test ! -d "$CS_USAGE_DIR/.lock" \
        || { echo "  FAIL: the kicked refresher never dropped its lock"; return 1; }
}

run_test test_fable_segment_does_not_spawn_a_refresher_without_curl
run_test test_fable_segment_does_spawn_when_curl_is_present

# I4: an account swap that lands while the fetch is in flight would stamp the
# old account's number with the new org and a fresh timestamp — C1's failure via
# the success path, and immune to C1's fix because that only guards the
# carry-forward branch. The fake curl performs the swap mid-request.
test_refresh_discards_a_result_if_the_account_changed_mid_fetch() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
# The swap happens here, between the org read and the write.
printf '%s' '{"oauthAccount":{"organizationUuid":"org-swapped"}}' > "$TEST_TMPDIR/.claude.json"
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    # The account swapped to already holds a good reading of its own. Seeding it
    # is what makes this test able to fail: without it, "wrote null over
    # nothing" and "wrote null over a good reading" look identical, and the
    # assertion would codify the second as correct.
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-swapped","pct":55,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787815990,"next_poll_at":1787816590}' \
        > "$CS_USAGE_DIR/fable.org-swapped.json"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    # org-abc's schedule may be recorded — its budget paid for the request —
    # but never the reading, which is no longer attributable to a signed-in
    # account.
    if [ -f "$CS_USAGE_DIR/fable.org-abc.json" ]; then
        assert_eq "null" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
            "a reading for an account that swapped away must not be stored under it" || return 1
    fi
    # And the account swapped TO must be left entirely alone: it did not make
    # this request, and blanking it would empty the chip for a full interval on
    # the account that just became active.
    assert_eq "55" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-swapped.json")" \
        "the new account's own good reading must survive a swap detected mid-fetch" || return 1
    assert_eq "1787815990" "$(jq -r '.fetched_at' "$CS_USAGE_DIR/fable.org-swapped.json")" \
        "and must not be restamped, which would hide its age" || return 1
}

# Finding 3: with no identifiable account there was no file to address, so the
# cadence check had nothing to read AND no schedule was written — every render
# fetched again. The old shared-file code held the cadence even here; the
# per-account rewrite dropped it.
test_refresh_without_an_account_still_holds_the_cadence() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
echo hit >> "$TEST_TMPDIR/hits"
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    printf '' > "$TEST_TMPDIR/.claude.json"     # torn config: no account
    local i
    for i in 1 2 3 4 5; do
        PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    done
    local hits=0
    [ -f "$TEST_TMPDIR/hits" ] && hits=$(wc -l < "$TEST_TMPDIR/hits" | tr -d ' ')
    assert_eq "1" "$hits" "an unidentifiable account must still burn only one request per window" || return 1
    # The schedule may be recorded, but never a reading: nothing is attributable.
    local readings
    readings=$(grep -l '"pct": *[0-9]' "$CS_USAGE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "0" "$readings" "and must still store no attributable reading" || return 1
}

run_test test_refresh_discards_a_result_if_the_account_changed_mid_fetch
run_test test_refresh_without_an_account_still_holds_the_cadence

# N1: the credential seam must stay closed on BOTH readers. setup() pins
# CS_SECURITY_BIN at a nonexistent path, but the plaintext fallback reads
# CLAUDE_CONFIG_DIR (defaulting to $HOME/.claude), so a test that forgets to
# repoint it would read the developer's real credential on any Linux/WSL box —
# and on a Mac that has ever written one. Fail closed on both, or the seam that
# printed a live token during development is only half shut.
test_setup_closes_both_credential_readers() {
    local home="$TEST_TMPDIR/fakehome"
    mkdir -p "$home/.claude"
    printf '%s' '{"claudeAiOauth":{"accessToken":"home-token-not-real"}}' \
        > "$home/.claude/.credentials.json"
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > "$TEST_TMPDIR/curl-stdin"
printf '000'
CURL
    chmod +x "$bindir/curl"
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    # Deliberately NOT setting CLAUDE_CONFIG_DIR: this test stands in for one
    # that forgot to, and asserts setup()'s posture is safe by itself.
    HOME="$home" PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local leaked=no
    [ -f "$TEST_TMPDIR/curl-stdin" ] && grep -q 'home-token-not-real' "$TEST_TMPDIR/curl-stdin" && leaked=yes
    assert_eq "no" "$leaked" "setup() must close the plaintext credential reader too, not just the keychain one" || return 1
}

run_test test_setup_closes_both_credential_readers

# N3(a): a torn or unreadable config during the request must not throw away a
# good reading for the account we actually asked about. _fable_read already
# treats an empty org as "unknown, not a mismatch"; the refresher must agree, or
# the two disagree about the same value and the chip blanks for a full interval.
test_refresh_keeps_a_good_reading_when_the_config_is_unreadable_mid_fetch() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
printf '' > "$TEST_TMPDIR/.claude.json"      # torn mid-request, not swapped
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "an unreadable config is not evidence of a swap; the reading must survive" || return 1
}

# N2: the refresher must honour the interval it stamped. A stray DUE from the
# render — a torn config, a corrupt cache — otherwise reaches an unguarded
# fetcher and spends a request that the cadence had already scheduled.
test_refresh_declines_when_the_cache_is_not_yet_due() {
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":42,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787816000,"next_poll_at":1787816600}' \
        > "$CS_USAGE_DIR/fable.org-abc.json"
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
echo hit >> "$TEST_TMPDIR/curl-hits"
printf '000'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816100 bash "$SL" --refresh-usage
    assert_file_not_exists "$TEST_TMPDIR/curl-hits" \
        "a refresher must not spend a request before its own next_poll_at" || return 1
    assert_eq "42" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "and must leave the not-yet-due reading exactly as it found it" || return 1
}

# The other side: once the interval has elapsed the refresher must still fetch,
# so the guard above cannot be passing by declining everything.
test_refresh_proceeds_once_due() {
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":42,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787816000,"next_poll_at":1787816600}' \
        > "$CS_USAGE_DIR/fable.org-abc.json"
    make_usage_shims 200 "$USAGE_BODY"
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816700 bash "$SL" --refresh-usage
    assert_eq "86" "$(jq -r '.pct' "$CS_USAGE_DIR/fable.org-abc.json")" \
        "past next_poll_at the refresher must fetch" || return 1
}

run_test test_refresh_keeps_a_good_reading_when_the_config_is_unreadable_mid_fetch
run_test test_refresh_declines_when_the_cache_is_not_yet_due
run_test test_refresh_proceeds_once_due

# Review finding 1: the cache is machine-global but held one account's record,
# and an org mismatch deliberately overrides the interval — so two sessions
# signed into different accounts each bypassed the other's stamped backoff and
# fetched forever. Measured at 12 requests inside one 600s window. Per-account
# cache files give each account its own cadence.
test_two_accounts_do_not_defeat_the_poll_floor() {
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir" "$TEST_TMPDIR/cfgA" "$TEST_TMPDIR/cfgB"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
echo hit >> "$TEST_TMPDIR/hits"
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-A"}}' > "$TEST_TMPDIR/cfgA/.claude.json"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-B"}}' > "$TEST_TMPDIR/cfgB/.claude.json"
    local i cfg
    for i in 1 2 3; do
        for cfg in cfgA cfgB; do
            CLAUDE_CONFIG_DIR="$TEST_TMPDIR/$cfg" PATH="$bindir:$PATH" \
                CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
        done
    done
    local hits=0
    [ -f "$TEST_TMPDIR/hits" ] && hits=$(wc -l < "$TEST_TMPDIR/hits" | tr -d ' ')
    # One per account inside the window, not one per render.
    assert_eq "2" "$hits" "two accounts must each poll once per window, not ping-pong past the floor" || return 1
}

# Review finding 2: _read_org yields "" for a torn config, the success path wrote
# that as the record's org, and _fable_read treats an empty org as "matches" —
# so the reading rendered for every account. Empty-org-is-unknown is the right
# rule for READING a cache and the wrong one for writing one.
test_refresh_never_writes_a_reading_under_an_empty_account() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf '%s' '$USAGE_BODY' > "\$out"
printf '200'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    printf '' > "$TEST_TMPDIR/.claude.json"     # torn at refresh time
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    # Assert on the WRITE, not on the render. The render also refuses to
    # address a record without an account, so a render-only assertion passes
    # whether or not this guard exists — verified by mutation: seeding the
    # write with a fallback name left a render-only version of this test green.
    # A schedule-only record is expected (it holds the cadence when the account
    # cannot be named); what must never be stored is the reading itself, which
    # nothing could later attribute.
    local readings
    readings=$(grep -l '"pct": *[0-9]' "$CS_USAGE_DIR"/fable.*.json 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "0" "$readings" \
        "a reading fetched with no identifiable account must not be stored" || return 1
    # And nothing may then render it for a named account.
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-A"}}' > "$TEST_TMPDIR/.claude.json"
    local out
    out=$(printf '%s' '{"session_name":"s","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"/none"}}' \
        | CS_USAGE_NO_REFRESH=1 NO_COLOR=1 CS_STATUSLINE_NOW=1787816100 bash "$SL")
    assert_output_not_contains "$out" "fable 86%" \
        "and it must never render for a named one" || return 1
}

# Review finding 3: a 200 whose body is not the API's JSON (a captive portal or
# proxy interstitial) parsed to no Fable window, which is indistinguishable from
# "this account has no Fable bucket" — so it wiped the last good reading and
# stamped it fresh. The failure paths deliberately carry forward; this must too.
test_refresh_treats_an_unparseable_200_as_a_failure() {
    use_scratch_usage_env
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":42,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787815000,"next_poll_at":1787815300}' \
        > "$CS_USAGE_DIR/fable.org-abc.json"
    make_usage_shims 200 '<html><body>Sign in to the network</body></html>'
    PATH="$USAGE_BINDIR:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local cache="$CS_USAGE_DIR/fable.org-abc.json"
    assert_eq "42" "$(jq -r '.pct' "$cache")" "a non-API 200 must not discard the last good reading" || return 1
    assert_eq "1787815000" "$(jq -r '.fetched_at' "$cache")" "and must not stamp it fresh" || return 1
}

run_test test_two_accounts_do_not_defeat_the_poll_floor
run_test test_refresh_never_writes_a_reading_under_an_empty_account
run_test test_refresh_treats_an_unparseable_200_as_a_failure

# ============================================================================
# Capsule colour tokens: the four inks and the crit fill, per level and theme
# ============================================================================

test_sgr_ink_tokens_truecolor_light() {
    export CS_TERM_THEME=light
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=light; _SURFACE_RGB="227;221;204"
    _sgr 38 ink2;    assert_eq "38;2;124;121;112" "$_SGR" "ink2 light" || return 1
    _sgr 38 amber;   assert_eq "38;2;180;83;9"    "$_SGR" "amber is an ink on light" || return 1
    _sgr 48 crit;    assert_eq "48;2;215;0;21"    "$_SGR" "crit fill light" || return 1
    _sgr 38 critink; assert_eq "38;2;255;255;255" "$_SGR" "crit ink light" || return 1
}

test_sgr_ink_tokens_truecolor_dark() {
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=dark; _SURFACE_RGB="46;48;50"
    _sgr 38 ink2;    assert_eq "38;2;160;161;162" "$_SGR" "ink2 dark" || return 1
    _sgr 38 amber;   assert_eq "38;2;251;191;36"  "$_SGR" "amber ink dark" || return 1
    _sgr 48 crit;    assert_eq "48;2;255;69;58"   "$_SGR" "crit fill dark" || return 1
    _sgr 38 critink; assert_eq "38;2;255;255;255" "$_SGR" "crit ink is white on dark too" || return 1
}

test_sgr_amber_follows_surface_luminance_not_the_theme() {
    # A measured light background with a theme that resolved dark (no rung
    # answered, or a manual CS_TERM_BG_RGB) must still paint the light amber:
    # the number sits on that background, not on the theme.
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=dark; CS_TERM_BG_RGB="253;246;227"
    _sgr 38 amber; assert_eq "38;2;180;83;9" "$_SGR" "light background takes the light amber under a dark theme" || return 1
    SL_THEME=light; CS_TERM_BG_RGB="30;30;30"
    _sgr 38 amber; assert_eq "38;2;251;191;36" "$_SGR" "dark background takes the dark amber under a light theme" || return 1
    SL_THEME=dark; CS_TERM_BG_RGB=""
    _sgr 38 amber; assert_eq "38;2;251;191;36" "$_SGR" "no measurement: the theme decides" || return 1
    # A mid-grey terminal (luminance between the shading pivot and the ink
    # pivot) gets white ink on its surface, so amber must take the dark-theme shade
    # there too: the two inks flip at the same brightness.
    SL_THEME=light; CS_TERM_BG_RGB="128;128;128"
    _sgr 38 amber; assert_eq "38;2;251;191;36" "$_SGR" "mid-grey background: the dark-theme amber, like white ink" || return 1
}

test_sgr_ink_follows_surface_luminance() {
    # ink is the 35% shade of a light surface and white on a dark one, exactly
    # the contrast rule the old surface text used.
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=light; _SURFACE_RGB="227;221;204"
    _sgr 38 ink; assert_eq "38;2;79;77;71" "$_SGR" "ink on a light surface is its 35% shade" || return 1
    SL_THEME=dark; _SURFACE_RGB="46;48;50"
    _sgr 38 ink; assert_eq "38;2;230;230;230" "$_SGR" "ink on a dark surface is the soft white" || return 1
}

test_sgr_ink_tokens_256_and_basic() {
    _load_sl_functions
    LEVEL=256; SL_THEME=light
    _sgr 48 surface;    assert_eq "48;5;254" "$_SGR" "surface 256 light" || return 1
    _sgr 38 ink;        assert_eq "38;5;236" "$_SGR" "ink 256 light" || return 1
    _sgr 38 ink2;    assert_eq "38;5;241" "$_SGR" "ink2 256 light" || return 1
    _sgr 38 periwinkle; assert_eq "38;5;55"  "$_SGR" "periwinkle 256 light" || return 1
    _sgr 38 amber;   assert_eq "38;5;130" "$_SGR" "amber 256 light" || return 1
    _sgr 48 crit;    assert_eq "48;5;160" "$_SGR" "crit 256 light" || return 1
    _sgr 38 critink; assert_eq "38;5;231" "$_SGR" "critink 256 light" || return 1
    _sgr 38 brand;      assert_eq "38;5;173" "$_SGR" "brand 256" || return 1
    _sgr 38 brandshade; assert_eq "38;5;167" "$_SGR" "brandshade 256, apart from brand" || return 1
    SL_THEME=dark
    _sgr 48 surface;    assert_eq "48;5;237" "$_SGR" "surface 256 dark" || return 1
    _sgr 38 ink;        assert_eq "38;5;255" "$_SGR" "ink 256 dark" || return 1
    _sgr 38 ink2;    assert_eq "38;5;250" "$_SGR" "ink2 256 dark" || return 1
    _sgr 38 periwinkle; assert_eq "38;5;147" "$_SGR" "periwinkle 256 dark" || return 1
    _sgr 38 amber;   assert_eq "38;5;214" "$_SGR" "amber 256 dark" || return 1
    _sgr 48 crit;    assert_eq "48;5;203" "$_SGR" "crit 256 dark" || return 1
    _sgr 38 critink; assert_eq "38;5;231" "$_SGR" "critink 256 dark is white" || return 1
    LEVEL=basic; SL_THEME=light
    _sgr 38 ink;     assert_eq "97" "$_SGR" "ink basic light" || return 1
    _sgr 38 ink2;    assert_eq "37" "$_SGR" "ink2 basic light" || return 1
    _sgr 38 amber;   assert_eq "33" "$_SGR" "amber basic" || return 1
    _sgr 48 crit;    assert_eq "41" "$_SGR" "crit basic bg" || return 1
    _sgr 38 critink; assert_eq "97" "$_SGR" "critink basic light" || return 1
    _sgr 38 brand;      assert_eq "33" "$_SGR" "brand basic" || return 1
    _sgr 38 brandshade; assert_eq "31" "$_SGR" "brandshade basic, apart from brand" || return 1
    SL_THEME=dark
    _sgr 38 ink;     assert_eq "97" "$_SGR" "ink basic dark" || return 1
    _sgr 38 ink2;    assert_eq "97" "$_SGR" "ink2 basic dark" || return 1
    _sgr 38 critink; assert_eq "97" "$_SGR" "critink basic dark is white" || return 1
}

test_sgr_unknown_truecolor_name_uses_the_surface() {
    _load_sl_functions
    unset CS_TERM_BG_RGB
    LEVEL=truecolor; SL_THEME=dark; _SURFACE_RGB=""
    _sgr 48 nonsense || return 1
    assert_eq "48;2;50;50;50" "$_SGR" "an unknown dark token uses the assumed surface" || return 1
    SL_THEME=light; _SURFACE_RGB=""
    _sgr 48 nonsense || return 1
    assert_eq "48;2;229;229;229" "$_SGR" "an unknown light token uses the assumed surface" || return 1
}

test_thresh_color_emits_crit_and_defaults_to_ink2() {
    _load_sl_functions
    _thresh_color 10 40 65; assert_eq "ink2"  "$_COLOR" "below warn is the secondary ink" || return 1
    _thresh_color 40 40 65; assert_eq "amber" "$_COLOR" "at warn is amber" || return 1
    _thresh_color 65 40 65; assert_eq "crit"  "$_COLOR" "at crit is crit, not red" || return 1
    _thresh_color 10 40 65 rowmeta; assert_eq "rowmeta" "$_COLOR" "an explicit healthy name is honoured" || return 1
}

run_test test_sgr_ink_tokens_truecolor_light
run_test test_sgr_ink_tokens_truecolor_dark
run_test test_sgr_amber_follows_surface_luminance_not_the_theme
run_test test_sgr_ink_follows_surface_luminance
run_test test_sgr_ink_tokens_256_and_basic
run_test test_sgr_unknown_truecolor_name_uses_the_surface
run_test test_thresh_color_emits_crit_and_defaults_to_ink2

# ============================================================================
# Capsules: one identity capsule, a ctx capsule, caps, no tail
# ============================================================================

test_interleaved_segments_still_one_identity_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CS_STATUSLINE_SEGMENTS="session,ctx,model"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":8}}'
    local out; out=$(run_sl "$json")
    local caps; caps=$(printf '%s' "$out" | grep -o "$CAPL" | wc -l | tr -d ' ')
    assert_eq "2" "$caps" "session and model share one capsule even with ctx named between them" || return 1
    assert_output_contains_f "$out" "1ms${ESC_}[48;2;227;221;204;38;2;124;121;112;22m  ·  ${ESC_}[48;2;227;221;204;38;2;79;77;71;1m✦ Opus" \
        "model follows session inside identity" || return 1
    out=$(NO_COLOR=1 run_sl "$json")
    assert_eq "s · ✦ Opus > ○ ctx 8%" "$out" "plain: groups render in first-seen order, items in their own order" || return 1
}

test_plain_joins_identity_with_dots_and_capsules_with_gt() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="mysess"
    make_cs_session "mysess" 49152 cyan
    local work; work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{
        session_name:"mysess", model:{display_name:"Opus"}, effort:{level:"high"},
        workspace:{current_dir:$dir}, context_window:{used_percentage:34}
    }')
    local out; out=$(run_sl "$json")
    assert_eq "mysess · ⎇ main +1!1 · ✦ Opus high > ◔ ctx 34%" "$out" \
        "plain: identity items joined by a dot, capsules by ' > '" || return 1
}

test_identity_is_one_capsule_on_the_surface() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local work; work=$(make_git_work)
    local json
    json=$(jq -nc --arg dir "$work" '{session_name:"s", model:{display_name:"Opus"}, workspace:{current_dir:$dir}, context_window:{used_percentage:8}}')
    local out; out=$(run_sl "$json")
    # One left cap opens identity, inked in the surface on the default bg.
    assert_output_contains_f "$out" "[49;38;2;227;221;204m${CAPL}" "left cap is surface ink on the terminal bg" || return 1
    # Session and branch sit on the same fill; neither has a fill of its own.
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1ms" "session is bold ink on the surface" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1m⎇ main +1!1" "branch is bold ink on the same surface" || return 1
    assert_output_not_contains_f "$out" "76;29;149" "no periwinkle in the bar" || return 1
    assert_output_not_contains_f "$out" "8;145;178" "the session colour never reaches the bar" || return 1
    # Items join with a secondary-ink dot inside the capsule.
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;124;121;112;22m  ·  " "dot joiner in ink2" || return 1
    # Exactly one identity capsule: one left cap before ctx's, two in total.
    local caps; caps=$(printf '%s' "$out" | grep -o "$CAPL" | wc -l | tr -d ' ')
    assert_eq "2" "$caps" "identity and ctx are the only two capsules" || return 1
}

test_capsule_gap_one_cell_between_every_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CS_STATUSLINE_SEGMENTS="session,ctx,cost"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"cost":{"total_cost_usd":1.5}}'
    local out; out=$(run_sl "$json")
    local esc=$'\033'
    assert_output_contains_f "$out" "s${esc}[49;38;2;227;221;204m${CAPR}${esc}[0m ${esc}[49;38;2;227;221;204m${CAPL}" \
        "one default-bg cell between identity and ctx" || return 1
    assert_output_not_contains_f "$out" "${esc}[0m  ${esc}[49" "no two-cell gap anywhere" || return 1
    assert_output_contains_f "$out" "8%${esc}[49;38;2;227;221;204m${CAPR}${esc}[0m ${esc}[49;38;2;227;221;204m${CAPL}" \
        "one cell between ctx and cost" || return 1
}

# The rounded caps are the one private-use glyph in the bar, so a machine
# that has not answered the install question gets square ends, not tofu.
test_caps_unanswered_renders_square() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    rm -f "$XDG_CONFIG_HOME/cs/statusline-caps"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out; out=$(run_sl "$json")
    assert_output_not_contains_f "$out" "$CAPL" "unanswered: no left cap glyph" || return 1
    assert_output_not_contains_f "$out" "$CAPR" "unanswered: no right cap glyph" || return 1
}

# A directory where the answer file should be is not an answer: square ends,
# and nothing on stderr, since the bar repaints on every Claude Code event.
test_caps_path_that_is_a_directory_renders_square_and_silent() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    rm -f "$XDG_CONFIG_HOME/cs/statusline-caps"
    mkdir -p "$XDG_CONFIG_HOME/cs/statusline-caps"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out err
    out=$(run_sl "$json")
    err=$(run_sl_stderr "$json")
    assert_output_not_contains_f "$out" "$CAPL" "a directory is not an answer: no cap glyph" || return 1
    assert_eq "" "$err" "nothing on stderr for a directory at the caps path" || return 1
}

test_caps_file_off_renders_square() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    printf 'off\n' > "$XDG_CONFIG_HOME/cs/statusline-caps"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out; out=$(run_sl "$json")
    assert_output_not_contains_f "$out" "$CAPL" "file off: no left cap glyph" || return 1
}

test_caps_env_overrides_file_both_ways() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    printf 'off\n' > "$XDG_CONFIG_HOME/cs/statusline-caps"
    out=$(CS_STATUSLINE_CAPS=1 run_sl "$json")
    assert_output_contains_f "$out" "$CAPL" "env 1 beats file off" || return 1
    printf 'on\n' > "$XDG_CONFIG_HOME/cs/statusline-caps"
    out=$(CS_STATUSLINE_CAPS=0 run_sl "$json")
    assert_output_not_contains_f "$out" "$CAPL" "env 0 beats file on" || return 1
}

test_caps_off_gives_square_chips() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CS_STATUSLINE_CAPS=0
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out; out=$(run_sl "$json")
    assert_output_not_contains_f "$out" "$CAPL" "no left cap glyph" || return 1
    assert_output_not_contains_f "$out" "$CAPR" "no right cap glyph" || return 1
    assert_output_contains_f "$out" "[48;2;227;221;204m ${ESC_}[48;2;227;221;204;38;2;79;77;71;1ms" \
        "the chip opens with a fill space, then the bold session name" || return 1
}

test_line_ends_at_the_last_cap_regardless_of_columns() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local narrow wide
    narrow=$(run_sl "$json")
    wide=$(COLUMNS=200 run_sl "$json")
    assert_eq "$narrow" "$wide" "COLUMNS no longer changes the render" || return 1
    case "$wide" in
        *"${CAPR}"$'\033[0m') ;;
        *) echo "    line must end with the right cap and a reset"; return 1 ;;
    esac
    assert_output_not_contains_f "$wide" "░" "no coverage wash" || return 1
    assert_output_not_contains_f "$wide" "·  ·" "no dotted tail" || return 1
}

test_ctx_amber_is_ink_on_the_surface() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":42}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;180;83;9;1m42%" "the number is amber ink" || return 1
    assert_output_not_contains_f "$out" "48;2;255;183;77" "no amber fill anywhere" || return 1
    assert_output_not_contains_f "$out" "48;2;180;83;9" "amber never becomes a fill" || return 1
    assert_output_contains_f "$out" "38;2;124;121;112;22m◑ ctx" "the label stays secondary ink" || return 1
}

test_ctx_crit_inverts_only_its_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":71}}'
    local out; out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "[49;38;2;215;0;21m${CAPL}" "ctx capsule's caps take the crit fill" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◕ ctx" "label inverts to critink bold" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m71%" "number inverts too" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1ms" "identity stays on the surface" || return 1
    assert_output_not_contains_f "$out" "48;2;220;38;38" "the session palette red is not the crit fill" || return 1
}

test_logo_is_brand_ink_inside_identity() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;217;119;87;1m✳" "the mark is coral ink on the surface" || return 1
    assert_output_not_contains_f "$out" "48;2;217;119;87" "no coral fill" || return 1
    assert_output_contains_f "$out" "✳${ESC_}[48;2;227;221;204m ${ESC_}[48;2;227;221;204;38;2;79;77;71;1ms" \
        "one fill space between the mark and the session name" || return 1
}

test_logo_holds_brandshade_while_attention_is_raised() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CLAUDE_SESSION_NAME="blinksess"
    make_cs_session "blinksess" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/blinksess/.cs/local"
    touch "$CS_SESSIONS_ROOT/blinksess/.cs/local/attention"
    local json='{"session_name":"blinksess","workspace":{"current_dir":"/none"}}'
    local even odd
    even=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    odd=$(CS_STATUSLINE_NOW=1001 run_sl "$json")
    assert_output_contains_f "$even" "38;2;184;101;74;1m✳" "attention: brandshade on an even second" || return 1
    assert_output_contains_f "$odd"  "38;2;184;101;74;1m✳" "attention: brandshade on an odd second" || return 1
}

test_crit_text_holds_white_on_the_red_fill() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":71}}'
    local even odd
    even=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    odd=$(CS_STATUSLINE_NOW=1001 run_sl "$json")
    assert_output_contains_f "$even" "48;2;215;0;21;38;2;255;255;255;1m71%" "even second: white on the red fill" || return 1
    assert_output_contains_f "$odd"  "48;2;215;0;21;38;2;255;255;255;1m71%" "odd second: still white on the red fill" || return 1
    assert_output_contains_f "$odd"  "48;2;215;0;21;38;2;255;255;255;1m◕ ctx" "the label stays white with the number" || return 1
    assert_output_not_contains_f "$odd" "38;2;255;205;200" "no reddish white on any second" || return 1
}

# The effort word takes Claude Code's own /effort colours (pixel-sampled from
# its light picker, 2026-09-14): low gold, medium green, high blue, xhigh
# violet, and max a three-stop gradient across its letters.
test_effort_takes_claude_codes_effort_colours() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"},"effort":{"level":"high"}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;79;77;71;1m✦ Opus" "model name bold ink" || return 1
    assert_output_contains_f "$out" "✦ Opus${ESC_}[48;2;227;221;204m ${ESC_}[48;2;227;221;204;38;2;87;105;247;22mhigh" \
        "high: one space after the model, Claude Code's blue, regular weight" || return 1
    for pair in "low:150;108;30" "medium:44;122;57" "xhigh:135;0;255"; do
        json="{\"session_name\":\"s\",\"workspace\":{\"current_dir\":\"/none\"},\"model\":{\"display_name\":\"Opus\"},\"effort\":{\"level\":\"${pair%%:*}\"}}"
        out=$(run_sl "$json")
        assert_output_contains_f "$out" "38;2;${pair#*:};22m${pair%%:*}" "${pair%%:*} takes its sampled colour" || return 1
    done
}

test_effort_max_is_a_gradient_across_its_letters() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"},"effort":{"level":"max"}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;130;170;220;22mm${ESC_}[48;2;227;221;204;38;2;155;130;200;22ma${ESC_}[48;2;227;221;204;38;2;200;130;179;22mx" \
        "m blue, a lavender, x pink, no joiner between the letters" || return 1
    export NO_COLOR=1
    out=$(run_sl "$json")
    assert_output_contains "$out" "✦ Opus max" "plain mode keeps the word whole" || return 1
}

tag_session() {  # name tags
    local readme="$CS_SESSIONS_ROOT/$1/.cs/README.md"
    printf -- '---\ncreated: 2026-06-11\ntags: [%s]\n---\n# %s\n' "$2" "$1" > "$readme"
}

test_encrypted_session_shows_a_lock_after_its_name() {
    export NO_COLOR=1 CS_STATUSLINE_CAPS=1 CLAUDE_SESSION_NAME="vsess"
    make_cs_session "vsess" 1024 blue
    tag_session vsess 'home, "encrypted"'
    local out; out=$(run_sl '{"session_name":"vsess","workspace":{"current_dir":"/none"}}')
    assert_output_contains "$out" $'vsess \xef\x80\xa3' "Nerd Font lock follows the name when caps are on" || return 1
}

test_encrypted_lock_falls_back_to_text_without_the_patched_font() {
    export NO_COLOR=1 CS_STATUSLINE_CAPS=0 CLAUDE_SESSION_NAME="vsess"
    make_cs_session "vsess" 1024 blue
    tag_session vsess 'encrypted'
    local out; out=$(run_sl '{"session_name":"vsess","workspace":{"current_dir":"/none"}}')
    assert_output_contains "$out" "vsess enc" "text marker when the font is unconfirmed" || return 1
    assert_output_not_contains "$out" $'\xef\x80\xa3' "no private-use glyph without consent" || return 1
}

test_untagged_or_lookalike_tag_shows_no_lock() {
    export NO_COLOR=1 CS_STATUSLINE_CAPS=0 CLAUDE_SESSION_NAME="vsess"
    make_cs_session "vsess" 1024 blue
    tag_session vsess 'encrypted-later, notencrypted'
    local out; out=$(run_sl '{"session_name":"vsess","workspace":{"current_dir":"/none"}}')
    assert_output_not_contains "$out" "enc " "a tag that only contains the word is not the marker" || return 1
    assert_output_contains "$out" "vsess" "the name still renders" || return 1
}

test_notes_and_mail_are_amber_ink_after_the_session() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CLAUDE_SESSION_NAME="qsess"
    make_cs_session "qsess" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/qsess/.cs/local/queue" "$CS_SESSIONS_ROOT/qsess/.cs/local/mail/new"
    printf 'x\n' > "$CS_SESSIONS_ROOT/qsess/.cs/local/queue/a"
    printf 'x\n' > "$CS_SESSIONS_ROOT/qsess/.cs/local/queue/b"
    printf '{}' > "$CS_SESSIONS_ROOT/qsess/.cs/local/mail/new/1.json"
    local json='{"session_name":"qsess","workspace":{"current_dir":"/none"}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "qsess${ESC_}[48;2;227;221;204m  ${ESC_}[48;2;227;221;204;38;2;180;83;9;22m▤ 2" \
        "notes: two fill spaces then amber ink" || return 1
    assert_output_contains_f "$out" "38;2;180;83;9;22m✉ 1" "mail in amber ink" || return 1
    assert_output_not_contains_f "$out" "48;2;255;183;77" "no amber fill" || return 1
}

run_test test_interleaved_segments_still_one_identity_capsule
run_test test_plain_joins_identity_with_dots_and_capsules_with_gt
run_test test_identity_is_one_capsule_on_the_surface
run_test test_capsule_gap_one_cell_between_every_capsule
run_test test_caps_unanswered_renders_square
run_test test_caps_path_that_is_a_directory_renders_square_and_silent
run_test test_caps_file_off_renders_square
run_test test_caps_env_overrides_file_both_ways
run_test test_caps_off_gives_square_chips
run_test test_line_ends_at_the_last_cap_regardless_of_columns
run_test test_ctx_amber_is_ink_on_the_surface
run_test test_ctx_crit_inverts_only_its_capsule
run_test test_logo_is_brand_ink_inside_identity
run_test test_logo_holds_brandshade_while_attention_is_raised
run_test test_crit_text_holds_white_on_the_red_fill
run_test test_effort_takes_claude_codes_effort_colours
run_test test_effort_max_is_a_gradient_across_its_letters
run_test test_notes_and_mail_are_amber_ink_after_the_session
run_test test_encrypted_session_shows_a_lock_after_its_name
run_test test_encrypted_lock_falls_back_to_text_without_the_patched_font
run_test test_untagged_or_lookalike_tag_shows_no_lock

# ============================================================================
# Limits: hidden until hot, tightest first, at most two, fable folded in
# ============================================================================

# 5h is the window you spend today, so it is always on the bar; the coarse
# windows (wk, fable) arrive at 50. Reveal and colour are separate: every
# window is neutral below 70, amber from 70, crit from 90.
test_limits_5h_always_shown_and_coarse_windows_arrive_at_fifty() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":49.9}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ○ ctx 8% > ◷ 5h 12%" "$out" "5h at 12 shows; wk at 49 stays hidden" || return 1
    json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":50}}}'
    out=$(run_sl "$json")
    assert_eq "s > ○ ctx 8% > ◷ 5h 12% ⋮ ◶ wk 50%" "$out" "wk arrives at 50, beside the fixed 5h, joined by a bar" || return 1
}

test_limits_shown_window_is_neutral_below_seventy() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":31},"seven_day":{"used_percentage":55}}}'
    local out; out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_not_contains "$out" "180;83;9" "no amber below 70" || return 1
    assert_output_not_contains "$out" "48;2;215;0;21" "no crit fill below 90" || return 1
    assert_output_contains_f "$out" "38;2;125;125;125;22m31%" "5h 31 sits at the secondary ink" || return 1
}

test_limits_at_sixty_nine_show_5h_then_wk() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":69},"seven_day":{"used_percentage":69.9}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ○ ctx 8% > ◷ 5h 69% ⋮ ◶ wk 69%" "$out" "both at 69 show, 5h first, neutral" || return 1
}

# The weekly icon must not be the half pie the ctx gauge now shows in its
# amber band, or a hot week next to a mid context reads as two of one thing.
test_wk_icon_differs_from_the_half_pie() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":47},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":72}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ◑ ctx 47% > ◷ 5h 12% ⋮ ◶ wk 72%" "$out" "wk takes the lower-left quadrant, distinct from the ctx half pie" || return 1
}

test_limits_wk_arrives_after_the_fixed_5h() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":70}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ○ ctx 8% > ◷ 5h 12% ⋮ ◶ wk 70%" "$out" "wk at 70 appears beside the fixed 5h" || return 1
}

test_limits_hot_window_is_amber_ink_then_crit_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":75},"seven_day":{"used_percentage":12}}}'
    local out; out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;180;83;9;1m75%" "5h 75 is amber ink on the surface" || return 1
    json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":91},"seven_day":{"used_percentage":12}}}'
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◷ 5h" "5h 91 inverts its capsule" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1ms" "identity is untouched" || return 1
}

# Capsules never swap places as numbers move: the order is fixed 5h, wk, fable.
# 5h and wk are one quota, so they share a capsule joined by a bar; the
# model-scoped fable window stays a capsule of its own.
test_limits_5h_and_wk_share_a_capsule_fable_stands_alone() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 95 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":55}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s · ✦ Fable > ◷ 5h 12% ⋮ ◶ wk 55% > ✧ fable 95% · 1d20h" "$out" "5h and wk joined by a vertical ellipsis in one capsule; fable is its own" || return 1
}

# One hot window inverts the shared quota capsule as a whole: a red capsule
# means throttling is near, whichever window tripped.
test_limits_shared_capsule_inverts_when_either_window_is_crit() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out; out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◷ 5h" "5h at 12 is painted on the crit fill beside a wk at 95" || return 1
}

test_limits_order_is_fixed_5h_wk_fable() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 95 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":55}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s · ✦ Fable > ◷ 5h 12% ⋮ ◶ wk 55% > ✧ fable 95% · 1d20h" "$out" "fable hotter than wk still renders after it" || return 1
}

test_limits_all_three_show_in_fixed_order() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":72},"seven_day":{"used_percentage":95}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains_f "$out" "◷ 5h 72% ⋮ ◶ wk 95% > ✧ fable 85% · 1d20h" "5h, wk, fable in that order; fable past 80 carries its countdown" || return 1
}

test_limits_countdown_rules_survive_gating() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":72,"resets_at":1787816200},"seven_day":{"used_percentage":72,"resets_at":1787816200}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains_f "$out" "◷ 5h 72% · 1m" "5h shows its countdown once visible" || return 1
    assert_output_not_contains_f "$out" "wk 72% ·" "wk withholds the countdown below 80" || return 1
}

test_fable_hidden_below_seventy_but_cache_still_read() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 25 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains_f "$out" "fable 25%" "fable at 25 is hidden" || return 1
    # The cache is still read on the hidden path (the kick itself is proven by
    # the two existing kick tests, moved onto _seg_limits in Step 4).
    _load_sl_functions
    SL_MODEL_ID="claude-fable-5"; SL_5H=""; SL_WK=""; _NOW=1787816400; _SL_NOW_READY=1; LEVEL=plain
    _SEG_TEXT=(); _SEG_GROUP=(); _SEG_INK=(); _SEG_BOLD=(); _SEG_JOIN=(); _SEG_ROLE=(); _GROUPS=(); _GROUPS_SEEN=""; _CRIT_GROUPS=""
    _seg_limits
    assert_eq "1" "${_FABLE_DUE:-}" "the cache was read and found due even though nothing rendered" || return 1
    assert_eq "0" "${#_SEG_TEXT[@]}" "nothing was added for a 25% window" || return 1
}

test_fable_named_alone_renders_only_the_fable_window() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    export CS_STATUSLINE_SEGMENTS="session,fable"
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":95},"seven_day":{"used_percentage":95}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s > ✧ fable 85% · 1d20h" "$out" "fable by name: its window, not the plan windows" || return 1
}

test_limits_and_fable_both_named_render_once_in_either_order() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":72},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(CS_STATUSLINE_SEGMENTS="session,limits,fable" CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s > ◷ 5h 72% ⋮ ◶ wk 95% > ✧ fable 85% · 1d20h" "$out" "limits then fable: one pass, all three, 5h first" || return 1
    out=$(CS_STATUSLINE_SEGMENTS="session,fable,limits" CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s > ◷ 5h 72% ⋮ ◶ wk 95% > ✧ fable 85% · 1d20h" "$out" "fable named first changes nothing: limits owns all three windows" || return 1
}

test_pane_off_by_default_and_rendered_when_named() {
    _make_ps_table real 12345
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    export NO_COLOR=1
    export TMUX="/tmp/tmux-1000/default,12345,0"
    export TMUX_PANE="%7"
    local out; out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains_f "$out" "◫" "pane is not in the default order" || return 1
    out=$(CS_STATUSLINE_SEGMENTS="session,pane,ctx" run_sl "$FIXTURE_DOCS")
    assert_eq "my-session ◫ 7 > ○ ctx 8%" "$out" "named: the pane number without its %, inside identity" || return 1
}

run_test test_limits_5h_always_shown_and_coarse_windows_arrive_at_fifty
run_test test_limits_shown_window_is_neutral_below_seventy
run_test test_limits_at_sixty_nine_show_5h_then_wk
run_test test_wk_icon_differs_from_the_half_pie
run_test test_limits_wk_arrives_after_the_fixed_5h
run_test test_limits_hot_window_is_amber_ink_then_crit_capsule
run_test test_limits_5h_and_wk_share_a_capsule_fable_stands_alone
run_test test_limits_shared_capsule_inverts_when_either_window_is_crit
run_test test_limits_order_is_fixed_5h_wk_fable
run_test test_limits_all_three_show_in_fixed_order
run_test test_limits_countdown_rules_survive_gating
run_test test_fable_hidden_below_seventy_but_cache_still_read
run_test test_fable_named_alone_renders_only_the_fable_window
run_test test_limits_and_fable_both_named_render_once_in_either_order
run_test test_pane_off_by_default_and_rendered_when_named

test_caps_switch_is_documented() {
    assert_file_contains "$SCRIPT_DIR/../docs/configuration.md" "CS_STATUSLINE_CAPS" \
        "the caps switch must be in the env reference" || return 1
    assert_file_contains "$SCRIPT_DIR/../docs/statusline.md" "CS_STATUSLINE_CAPS" \
        "the caps switch must be in the design doc's Configuration section" || return 1
}

run_test test_caps_switch_is_documented

# ink2 and ink must both read against the surface they sit on, at every color
# level and theme: a token that lands on the same SGR parameters as the fill
# beneath it is invisible on that terminal. Compared at a shared kind (38) so
# a truecolor/256 "38;..." prefix and a basic bare code line up the same way.
test_ink_tokens_contrast_every_surface() {
    _load_sl_functions
    local level theme surface token color
    for level in truecolor 256 basic; do
        for theme in light dark; do
            LEVEL="$level"; SL_THEME="$theme"; _SURFACE_RGB=""
            _sgr 38 surface; surface="${_SGR#38;}"
            for token in ink2 ink periwinkle amber; do
                _sgr 38 "$token"; color="${_SGR#38;}"
                [ "$color" != "$surface" ] \
                    || { echo "  FAIL: $level/$theme $token ($color) does not contrast the surface"; return 1; }
            done
        done
    done
}

run_test test_ink_tokens_contrast_every_surface

# With caps on, a capsule opens cap-then-item and closes item-then-cap: no fill
# space sits between the cap glyph and the item beside it (CS_STATUSLINE_CAPS=0
# keeps that fill space as the chip's square edge; see test_caps_off_gives_square_chips).
test_capsule_has_no_inner_padding() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out; out=$(run_sl "$json")
    local esc=$'\033'
    assert_output_contains_f "$out" "${CAPL}${esc}[48;2;227;221;204;38;2;217;119;87;1m" \
        "the left cap opens directly into the first item's SGR, no fill space" || return 1
    assert_output_contains_f "$out" "8%${esc}[49;38;2;227;221;204m${CAPR}" \
        "the last item's text runs directly into the right cap, no fill space" || return 1
}

run_test test_capsule_has_no_inner_padding

# --- Render cost ------------------------------------------------------------

# Count, into FORKS, the external commands one render forks. Every executable the script
# names is shadowed on PATH by a shim that logs its name and execs the real
# one, PATH left shadowed so a child process (git under timeout) is logged too.
# Not a command substitution: the render's parent must be this shell on every
# run, as Claude Code is for every render of a conversation, or the ancestry
# verdict cache (keyed on the parent pid) can never hit.
# The shim list is derived from the script's own text, so a command it starts
# calling is counted without anyone maintaining a list. Under load a render's
# wall time is this count times the per-fork cost, so the count is the cost.
count_render_forks() {  # json
    local shims="$TEST_TMPDIR/shims" log="$TEST_TMPDIR/forks" word
    if [ ! -d "$shims" ]; then
        mkdir -p "$shims"
        printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> %q\nexec "$(PATH=%q command -v "${0##*/}")" "$@"\n' \
            "$log" "$PATH" > "$shims/.shim"
        chmod +x "$shims/.shim"
        for word in $(grep -oE '\b[a-z][a-z0-9_-]+\b' "$SL" | sort -u); do
            case "$(type -t "$word" 2>/dev/null)" in file) ln -s "$shims/.shim" "$shims/$word" ;; esac
        done
    fi
    : > "$log"
    printf '%s' "$1" > "$TEST_TMPDIR/stdin.json"
    # Output to a file, not a substitution: the render's parent must stay this
    # shell (see above).
    PATH="$shims:$PATH" bash "$SL" < "$TEST_TMPDIR/stdin.json" > "$TEST_TMPDIR/stdout.txt" 2>/dev/null
    FORKS_RC=$?
    FORKS_OUT=$(cat "$TEST_TMPDIR/stdout.txt")
    FORKS=0
    local line
    while IFS= read -r line; do FORKS=$((FORKS + 1)); done < "$log"
}

# A lead Fable render with every optional stage live: a matching session id in
# state (so context-pct is written), rate limits (the limits stamp), a Fable
# model id with an org and the usage record the refresher leaves (JSON and its
# sidecar), a git work tree, and a real tmux pane whose theme comes from the
# attached client (the ancestry verdict a first render would have cached, a
# fake tmux that reports no theme, the launch's terminal measurement). Sets
# FULL_JSON; the environment it exports is part of the fixture, so it runs in
# the caller's shell.
make_full_render_fixture() {
    export CLAUDE_SESSION_NAME=s
    local sdir="$CS_SESSIONS_ROOT/s/.cs/local"
    mkdir -p "$sdir"
    printf 'claude_session_id: "sid-1"\n' > "$sdir/state"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
    printf '{"oauthAccount":{"organizationUuid":"org-1"}}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"; mkdir -p "$CS_USAGE_DIR"
    export CS_USAGE_NO_REFRESH=1
    printf '{"org":"org-1","pct":12,"resets_at":"2099-01-01T00:00:00Z","fetched_at":4102444800,"next_poll_at":4102444800}\n' \
        > "$CS_USAGE_DIR/fable.org-1.json"
    printf '%s\n' 12 "2099-01-01T00:00:00Z" 4102444800 4102444800 4070908800 > "$CS_USAGE_DIR/fable.org-1.json.fields"
    export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
    unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
    mkdir -p "$TEST_TMPDIR/fakebin" "$HOME/.cache/cs/tmux-real" "$HOME/.cache/cs/term"
    printf '#!/bin/sh\nprintf "\\t/dev/ttys002\\n"\n' > "$TEST_TMPDIR/fakebin/tmux"
    chmod +x "$TEST_TMPDIR/fakebin/tmux"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    printf '%s\t%s\nreal\n' "$(date +%s)" "$$,$TMUX" > "$HOME/.cache/cs/tmux-real/$$,-tmp-fake,1,0"
    printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
    local work
    work=$(make_git_work)
    FULL_JSON=$(jq -nc --arg dir "$work" '{
        session_id:"sid-1", session_name:"s",
        model:{id:"claude-fable-5-1", display_name:"Fable"},
        effort:{level:"high"},
        workspace:{current_dir:$dir},
        context_window:{used_percentage:30},
        rate_limits:{five_hour:{used_percentage:42, resets_at:"2099-01-01T00:00:00Z"},
                     seven_day:{used_percentage:55, resets_at:"2099-01-01T00:00:00Z"}}
    }')
}

# The bar repaints on every event; a render that has painted once before, in
# the same second, forks exactly two external commands: the interpreter and jq
# for stdin. Every other fork is behind a cache (git line, tmux ancestry, org
# id, fable fields) or a stamp cadence, and comes back at most once in its
# interval. On a loaded machine a fork costs 0.3 s (load 25), so a render that
# forks a dozen runs past Claude Code's limit and the tick is killed.
test_warm_render_forks_only_the_interpreter_and_jq() {
    make_full_render_fixture
    # Every cache ages against the render's own clock, so the renders share one
    # pinned second: "warm" is a fact about that clock, not about how quickly
    # this machine gets from one render to the next.
    local now; now=$(date +%s)
    # What the bar shows without the shims, rendered from this same shell (a
    # pipeline would give it another parent and so another ancestry verdict).
    printf '%s' "$FULL_JSON" > "$TEST_TMPDIR/stdin.json"
    CS_STATUSLINE_NOW="$now" bash "$SL" < "$TEST_TMPDIR/stdin.json" > "$TEST_TMPDIR/plain.txt" 2>/dev/null
    local plain; plain=$(cat "$TEST_TMPDIR/plain.txt")
    CS_STATUSLINE_NOW="$now" count_render_forks "$FULL_JSON"   # the cold render fills the caches
    CS_STATUSLINE_NOW="$now" count_render_forks "$FULL_JSON"
    assert_eq "0" "$FORKS_RC" "the counted render exits cleanly" || return 1
    assert_eq "$plain" "$FORKS_OUT" "the counted render draws the same line" || return 1
    assert_output_contains_f "$FORKS_OUT" "main +1!1" "and the line carries the git segment" || return 1
    assert_output_contains_f "$FORKS_OUT" "5h" "and the limits" || return 1
    # The instrumentation itself: the two forks every render makes must have
    # been seen, or the shims were never installed and the count means nothing.
    grep -qx bash "$TEST_TMPDIR/forks" || { echo "  FAIL: the interpreter was not counted; shims missing"; return 1; }
    grep -qx jq "$TEST_TMPDIR/forks" || { echo "  FAIL: jq was not counted; shims missing"; return 1; }
    [ "$FORKS" -le 2 ] || { echo "  FAIL: warm render forked $FORKS external commands (limit 2):"; sed 's/^/    /' "$TEST_TMPDIR/forks"; return 1; }
    # The clock itself, read for real: a bash without a builtin clock (3.2,
    # macOS stock) forks date once for the render's shared clock, never once
    # per reader. Only date is counted here, since this render's caches may
    # have aged.
    count_render_forks "$FULL_JSON"
    local dates; dates=$(grep -cx date "$TEST_TMPDIR/forks" || true)
    [ "$dates" -le 1 ] || { echo "  FAIL: a render on the real clock forked date $dates times (limit 1)"; return 1; }
}

run_test test_warm_render_forks_only_the_interpreter_and_jq


# The git line is reused for GIT_CACHE_TTL seconds and re-read after: a change
# to the tree shows at the first render past the TTL, and the clock is the
# pinned one.
test_git_line_is_cached_for_the_ttl_then_refreshed() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    local work json
    work=$(make_git_work)
    json=$(jq -nc --arg dir "$work" '{workspace:{current_dir:$dir}}')
    local first second third
    first=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    printf 'more\n' >> "$work/a.txt"; printf 'new\n' > "$work/c.txt"; git -C "$work" add c.txt
    second=$(CS_STATUSLINE_NOW=1004 run_sl "$json")
    third=$(CS_STATUSLINE_NOW=1006 run_sl "$json")
    assert_output_contains_f "$first" "main +1!1" "the first render reads the tree" || return 1
    assert_eq "$first" "$second" "within the TTL the cached line is reused" || return 1
    assert_output_contains_f "$third" "main +2!1" "past the TTL the tree is read again" || return 1
}

run_test test_git_line_is_cached_for_the_ttl_then_refreshed

# The tmux-ancestry verdict is kept for TMUX_REAL_CACHE_TTL under the parent
# pid and the TMUX claim: the walk (ps and awk) runs once per conversation,
# not on every render, and a stale verdict is re-walked.
test_tmux_ancestry_verdict_is_cached_then_rewalked() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _make_ps_chain "$$:2216 2216:1"
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    a real chain must pass"; return 1; }
      _make_ps_chain "$$:1"      # the process tree now says foreign
      CS_STATUSLINE_NOW=1010 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    within the TTL the cached verdict must answer"; return 1; }
      CS_STATUSLINE_NOW=1301 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          && { echo "    past the TTL the tree must be walked again"; return 1; }
      return 0 )
}

run_test test_tmux_ancestry_verdict_is_cached_then_rewalked

# A ps that cannot answer leaves no verdict behind: the next render walks again
# rather than trusting a guess for five minutes.
test_unusable_ps_verdict_is_not_cached() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      mkdir -p "$TEST_TMPDIR/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/ps"; chmod +x "$TEST_TMPDIR/fakebin/ps"
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    a failing ps is not evidence of a foreign tmux"; return 1; }
      _make_ps_chain "$$:2216 2216:1"
      CS_STATUSLINE_NOW=1001 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    the failed walk must not have been cached as a verdict"; return 1; }
      return 0 )
}

run_test test_unusable_ps_verdict_is_not_cached

# A conversation's first render is the only one that has ever paid for the
# ancestry walk, and it is the render Claude Code kills. It no longer waits:
# the verdict is taken as real, the walk runs in a detached child under the
# render's own parent identity, and the next render reads
# what the child left. A foreign environment is corrected by then; a real one,
# which is every pane cs launches, never sees a wrong palette at all.
test_first_render_defers_the_ancestry_walk() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    # Named, because a pipeline gives each render a different parent and the
    # verdict the child writes must be the one the next render looks up.
    export CS_STATUSLINE_PARENT=4242
    _make_ps_chain "2216:1"   # the server is nobody's ancestor: foreign
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}'
    local first second
    first=$(run_sl "$json")
    assert_output_contains_f "$first" "7" \
        "the first render draws the pane instead of walking the tree" || return 1
    settle_tmux_verdict 4242 "$TMUX" \
        || { echo "  FAIL: the detached walk left no verdict"; return 1; }
    second=$(run_sl "$json")
    grep -qF -- "7" <<< "$second" && {
        echo "  FAIL: the second render must read the foreign verdict the child cached"
        return 1
    }
    return 0
}

run_test test_first_render_defers_the_ancestry_walk

# The other half of the deferral: the child walks from the render's PARENT,
# the pid every render of a conversation shares, and a pane cs launched has
# the tmux server above that pid. A walk started from the render's own pid —
# gone by the time the child looks — would answer foreign for every real pane
# and hide the pane id from the second render on, with the test above green.
test_the_deferred_walk_starts_from_the_parent_and_caches_real() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    export CS_STATUSLINE_PARENT=4242
    _make_ps_chain "4242:2216 2216:1"   # the parent sits under the server: real
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}'
    local second key
    run_sl "$json" >/dev/null
    settle_tmux_verdict 4242 "$TMUX" \
        || { echo "  FAIL: the detached walk left no verdict"; return 1; }
    key="4242,$TMUX"; key=${key//\//-}; key=${key//[^A-Za-z0-9._,-]/_}
    assert_eq "real" "$(tail -1 "$HOME/.cache/cs/tmux-real/$key")" \
        "a parent under the tmux server is cached as real" || return 1
    second=$(run_sl "$json")
    assert_output_contains_f "$second" "7" \
        "the second render keeps the pane id on the real verdict" || return 1
    [ ! -e "$HOME/.cache/cs/tmux-walking/$key" ] \
        || { echo "  FAIL: the child must clear its in-flight mark"; return 1; }
}

run_test test_the_deferred_walk_starts_from_the_parent_and_caches_real

# Exits 0 once the stalled ps stand-in has logged at least <count> calls.
_stalled_walkers_reach() {  # count
    [ "$(wc -l < "$STALLLOG" | tr -d ' ')" -ge "$1" ]
}

# A `ps` that never answers must not mint a walker every render. The render that
# spawns one marks the walk in flight, and every render inside
# TMUX_WALK_MARK_TTL renders without spawning another; past the TTL one render
# tries again, so a walk whose child died leaves nothing wedged.
test_a_stalled_walk_is_not_respawned_every_render() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    # The longest deadline the render accepts, so the first walker still holds
    # its mark while the four renders run.
    export CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_WALK_DEADLINE=9
    # A ps that never returns within the run: each invocation records itself,
    # so the count of records is the count of walkers spawned.
    mkdir -p "$TEST_TMPDIR/fakebin"
    export STALLLOG="$TEST_TMPDIR/stalled"
    : > "$STALLLOG"
    printf '#!/bin/sh\necho x >> "$STALLLOG"\nexec sleep 300\n' > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}' i=0 spawned stamp
    local mark="$HOME/.cache/cs/tmux-walking/4242,-tmp-fake,2216,0"
    while [ "$i" -lt 4 ]; do
        i=$((i + 1))
        CS_STATUSLINE_NOW=$((1000 + i)) run_sl "$json" >/dev/null
    done
    # A render that spawns a walker stamps the mark with its own clock first,
    # in the render itself, so the stamp names the last render that spawned
    # one however late that walker's ps would start.
    stamp=""
    [ -f "$mark" ] && IFS=$'\t' read -r stamp _ < "$mark"
    assert_eq "1001" "$stamp" "only the first of four renders inside the TTL spawns a walker" || return 1
    # The walker is detached and its ps starts later on a loaded machine.
    wait_until test -s "$STALLLOG"
    spawned=$(wc -l < "$STALLLOG" | tr -d ' ')
    assert_eq "1" "$spawned" "four renders inside the TTL must spawn one walker" || return 1
    # Past the mark's TTL a render tries again, so a dead child cannot wedge
    # the verdict for the rest of the conversation.
    CS_STATUSLINE_NOW=1012 run_sl "$json" >/dev/null   # past TMUX_WALK_MARK_TTL (10)
    wait_until _stalled_walkers_reach 2
    spawned=$(wc -l < "$STALLLOG" | tr -d ' ')
    assert_eq "2" "$spawned" "past the TTL one render walks again" || return 1
}

run_test test_a_stalled_walk_is_not_respawned_every_render

# A `sleep` for the render's PATH that logs each call to $DEADLOG as
# "<parent pid> <own pid> <seconds asked>", then sleeps what it was asked plus
# $2 seconds, if any. With no extra it execs the real sleep, so the own pid is
# the sleep's. A walker kills ps only once its deadline sleep ends, so a logged
# line comes before the kill and before the mark is cleared: the distinct
# parents count walkers without racing them, as a stalled ps logging itself
# would, whatever number of sleeps a walker's deadline takes. The deadline
# being a single sleep is pinned by the wall-time test alone.
_make_deadline_sleep() {  # dir extra-seconds
    local real
    real=$(command -v sleep)
    mkdir -p "$1"
    if [ "$2" = 0 ]; then
        printf '#!/bin/sh\necho "$PPID $$ $1" >> "$DEADLOG"\nexec %s "$@"\n' "$real" > "$1/sleep"
    else
        printf '#!/bin/sh\necho "$PPID $$ $1" >> "$DEADLOG"\n%s "$@"\nexec %s %s\n' "$real" "$real" "$2" > "$1/sleep"
    fi
    chmod +x "$1/sleep"
}

# The mark only spaces walkers out; what keeps them from piling up is that a
# walker gives its ps a deadline shorter than the mark and kills it by the pid
# it recorded. Across mark windows a ps that never answers leaves nothing alive.
test_a_stalled_walker_is_killed_before_its_mark_expires() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    export CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_WALK_DEADLINE=1
    local real_sleep deadbin="$TEST_TMPDIR/deadbin"
    real_sleep=$(command -v sleep)
    mkdir -p "$TEST_TMPDIR/fakebin"
    export STALLLOG="$TEST_TMPDIR/stalled" DEADLOG="$TEST_TMPDIR/deadlines"
    : > "$STALLLOG"; : > "$DEADLOG"
    # The ps logs its pid for the alive check below; it may be killed before
    # it gets that far, so walkers are counted by their deadlines instead. It
    # stalls far longer than the poll below can stretch under load, so only
    # the walker's kill can end it while the test watches.
    printf '#!/bin/sh\necho "$$" >> "$STALLLOG"\nexec %s 300\n' "$real_sleep" > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
    _make_deadline_sleep "$deadbin" 0
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}' now p alive
    local mark="$HOME/.cache/cs/tmux-walking/4242,-tmp-fake,2216,0"
    for now in 1001 1012 1023; do
        PATH="$deadbin:$PATH" CS_STATUSLINE_NOW=$now run_sl "$json" >/dev/null
        # The walker clears the mark as its last act, after it has killed and
        # reaped its ps, so a cleared mark means this window's walker is done.
        # The next window starts only then. The wait outlasts the walker's 1 s
        # deadline however loaded the machine, and a walker that never kills
        # leaves its ps, and so its mark, up for 300 s, past the wait.
        wait_until test ! -e "$mark"
        [ ! -e "$mark" ] \
            || { echo "  FAIL: the walker spawned at $now never killed its stalled ps"; return 1; }
    done
    assert_eq "3" "$(cut -d' ' -f1 "$DEADLOG" | sort -u | wc -l | tr -d ' ')" "each mark window spawns one walker" || return 1
    # Every walker has cleared its mark, which it does only after killing and
    # reaping its ps, so no recorded ps may still be alive.
    alive=0
    while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done < "$STALLLOG"
    assert_eq "0" "$alive" "no stalled ps outlives its deadline" || return 1
    # The killed walk is a ps that could not answer: no verdict, and the pane
    # still draws as real.
    [ ! -e "$HOME/.cache/cs/tmux-real/4242,-tmp-fake,2216,0" ] \
        || { echo "  FAIL: a killed walk must not leave a verdict"; return 1; }
}

run_test test_a_stalled_walker_is_killed_before_its_mark_expires

# The deadline is wall time. On a loaded machine every `sleep` costs its fork
# on top of what it was asked for, so a deadline counted in sleeps runs long
# by that cost once per sleep and can outlast the mark, letting the next render
# start a second walker beside the first. Here each sleep the walker runs takes
# 1 s longer than asked: a deadline of 1 s counted as 10 sleeps of 0.1 s
# would take 11 s, past TMUX_WALK_MARK_TTL (10 s); one sleep takes 2 s.
test_the_walk_deadline_holds_in_wall_time_when_sleeps_run_long() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    export CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_WALK_DEADLINE=1
    local real_sleep slowbin="$TEST_TMPDIR/slowbin"
    real_sleep=$(command -v sleep)
    mkdir -p "$TEST_TMPDIR/fakebin"
    export STALLLOG="$TEST_TMPDIR/stalled" DEADLOG="$TEST_TMPDIR/deadlines"
    : > "$STALLLOG"; : > "$DEADLOG"
    printf '#!/bin/sh\necho "$$" >> "$STALLLOG"\nexec %s 300\n' "$real_sleep" > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
    _make_deadline_sleep "$slowbin" 1
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}' alive=0 p start
    local mark="$HOME/.cache/cs/tmux-walking/4242,-tmp-fake,2216,0"
    start=$SECONDS
    # Only the render, and the walker it leaves behind, see the slow sleep.
    PATH="$slowbin:$PATH" CS_STATUSLINE_NOW=1001 run_sl "$json" >/dev/null
    # Wall time, because that is how the mark ages. SECONDS counts whole
    # seconds, so this gives up between 9 and 10 s after the render started.
    while [ -e "$mark" ] && [ $((SECONDS - start)) -lt 10 ]; do sleep 0.1; done
    [ ! -e "$mark" ] \
        || { echo "  FAIL: the walker still held its stalled ps when its mark expired"; return 1; }
    assert_eq "1" "$(cut -d' ' -f3 "$DEADLOG")" "the walker sleeps once, for its 1 s deadline" || return 1
    while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done < "$STALLLOG"
    assert_eq "0" "$alive" "the walker's ps is dead once its mark is cleared" || return 1
}

run_test test_the_walk_deadline_holds_in_wall_time_when_sleeps_run_long

# A ps that answers ends the walk at once: the walker stops its watchdog and
# the watchdog's sleep instead of waiting out the deadline, and leaves neither
# behind. With a 9 s deadline, a walker that waited on its watchdog would land
# its verdict and clear its mark 9 s late, and a sleep left running would
# still be alive after the mark is gone.
test_a_walk_whose_ps_answers_stops_its_deadline() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    export CS_STATUSLINE_SEGMENTS=pane
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    export CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_WALK_DEADLINE=9
    local deadbin="$TEST_TMPDIR/deadbin" real_sleep
    real_sleep=$(command -v sleep)
    export DEADLOG="$TEST_TMPDIR/deadlines"
    : > "$DEADLOG"
    _make_deadline_sleep "$deadbin" 0
    # The ps answers (the parent under the server) as soon as the watchdog's
    # sleep has started, so there is a sleep to stop; a ps that won outright
    # would leave nothing to check. Its own pauses use the real sleep.
    mkdir -p "$TEST_TMPDIR/fakebin"
    printf '#!/bin/sh\ni=0\nwhile [ ! -s "$DEADLOG" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); %s 0.05; done\necho "4242 2216"\necho "2216 1"\n' \
        "$real_sleep" > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    local json='{"session_id":"sid-1"}' start elapsed p alive
    local key="4242,-tmp-fake,2216,0"
    local mark="$HOME/.cache/cs/tmux-walking/$key"
    start=$SECONDS
    PATH="$deadbin:$PATH" CS_STATUSLINE_NOW=1001 run_sl "$json" >/dev/null
    # Bounded past the deadline, so a walker that waits it out is measured,
    # not cut off.
    while [ -e "$mark" ] && [ $((SECONDS - start)) -lt 15 ]; do sleep 0.1; done
    elapsed=$((SECONDS - start))
    [ ! -e "$mark" ] || { echo "  FAIL: the walker never cleared its mark"; return 1; }
    assert_eq "real" "$(tail -1 "$HOME/.cache/cs/tmux-real/$key" 2>/dev/null)" \
        "the walk caches the answered verdict" || return 1
    # SECONDS counts whole seconds, so 5 is under 6 s of wall time: far past a
    # walk on a loaded machine, far short of the 9 s deadline.
    [ "$elapsed" -le 5 ] \
        || { echo "  FAIL: the verdict took ${elapsed}s, waiting on the 9 s deadline"; return 1; }
    assert_eq "1" "$(wc -l < "$DEADLOG" | tr -d ' ')" "the walker arms one deadline" || return 1
    # The watchdog signals its sleep on its way out; give the signal a moment.
    start=$SECONDS
    while :; do
        alive=0
        while read -r _ p _; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done < "$DEADLOG"
        [ "$alive" -eq 0 ] || [ $((SECONDS - start)) -ge 2 ] && break
        sleep 0.1
    done
    assert_eq "0" "$alive" "no deadline sleep outlives an answered walk" || return 1
}

run_test test_a_walk_whose_ps_answers_stops_its_deadline

# The usage refresher paints no bar, so it has no use for the terminal's theme
# or the ancestry verdict behind it. It must not run the walk at all: a ps that
# stalls would hold every refresher short of its lock, and the renders that
# keep surviving would keep launching more.
test_usage_refresher_never_walks_the_process_tree() {
    export TMUX="/tmp/fake,2216,0" TMUX_PANE="%7"
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"; mkdir -p "$CS_USAGE_DIR"
    mkdir -p "$TEST_TMPDIR/fakebin"
    export PSLOG="$TEST_TMPDIR/pslog"
    : > "$PSLOG"
    printf '#!/bin/sh\necho x >> "$PSLOG"\necho "2216 1"\n' > "$TEST_TMPDIR/fakebin/ps"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/curl"
    chmod +x "$TEST_TMPDIR/fakebin/ps" "$TEST_TMPDIR/fakebin/curl"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"
    bash "$SL" --refresh-usage >/dev/null 2>&1
    assert_eq "0" "$(wc -l < "$PSLOG" | tr -d ' ')" "the refresher must not run ps" || return 1
    [ ! -d "$HOME/.cache/cs/tmux-real" ] \
        || { echo "  FAIL: the refresher must not write an ancestry verdict"; return 1; }
    # The verdict and the ps log are a detached child's, which may land after
    # these asserts; the in-flight mark is the refresher's own synchronous
    # write, so its absence is the deterministic proof that no walk was kicked.
    [ ! -d "$HOME/.cache/cs/tmux-walking" ] \
        || { echo "  FAIL: the refresher must not mark a walk in flight"; return 1; }
}

run_test test_usage_refresher_never_walks_the_process_tree

# The walker's deadline reaches shell arithmetic, which runs a command
# substitution held in an array subscript. PATH[...] is the payload because
# set -u aborts on an unset array base before the subscript is expanded.
_walk_deadline_payload() {  # marker
    printf 'PATH[$(touch %s)]' "$1"
}

# The subagent bar sources this script in library mode, which walks in-process
# at load, so a _SL_WALK_DEADLINE in its environment would reach the walk.
test_an_inherited_walk_deadline_is_never_read() {
    local marker="$TEST_TMPDIR/ran"
    _make_ps_chain "2216:1"
    export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
    printf '%s' '{"columns":80,"tasks":[]}' \
        | _SL_WALK_DEADLINE="$(_walk_deadline_payload "$marker")" \
            bash "$SCRIPT_DIR/../bin/cs-subagent-statusline" >/dev/null 2>&1
    assert_not_exists "$marker" "an inherited _SL_WALK_DEADLINE must not run as code" || return 1
}

# A well-formed number inherited from the environment is ignored too: the
# in-process walk reads ps directly, over a pipe, and only the detached walker
# takes the deadline path, which writes ps's answer to a file.
test_an_inherited_numeric_walk_deadline_is_ignored() {
    local log="$TEST_TMPDIR/ps-stdout"
    mkdir -p "$TEST_TMPDIR/fakebin"
    printf '#!/bin/sh\nk=other; [ -p /dev/stdout ] && k=pipe\necho "$k" >> "%s"\necho "2216 1"\n' \
        "$log" > "$TEST_TMPDIR/fakebin/ps"
    chmod +x "$TEST_TMPDIR/fakebin/ps"
    export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
    printf '%s' '{"columns":80,"tasks":[]}' \
        | _SL_WALK_DEADLINE=5 bash "$SCRIPT_DIR/../bin/cs-subagent-statusline" >/dev/null 2>&1
    assert_eq "pipe" "$(cat "$log" 2>/dev/null)" \
        "the walk must read ps directly, not by an inherited deadline" || return 1
}

test_the_walk_reads_its_deadline_only_as_digits() {
    local marker="$TEST_TMPDIR/ran"
    ( _load_sl_functions
      _make_ps_chain "500:2216 2216:1"
      export PATH="$TEST_TMPDIR/fakebin:$PATH"
      mkdir -p "$HOME/.cache/cs/tmux-walking"
      _SL_WALK_DEADLINE="$(_walk_deadline_payload "$marker")"
      _sl_tmux_walk 500 2216 2>/dev/null
      assert_eq "0" "$?" "a walk with an unusable deadline still answers from ps" || return 1 )
    assert_not_exists "$marker" "a non-numeric deadline must not run as code" || return 1
}

run_test test_an_inherited_walk_deadline_is_never_read
run_test test_an_inherited_numeric_walk_deadline_is_ignored
run_test test_the_walk_reads_its_deadline_only_as_digits

# The org id is kept for ORG_CACHE_TTL under the config path, so an account
# swap shows within five minutes and a render never walks the config twice in
# that time.
test_org_id_is_cached_then_reread() {
    ( _load_sl_functions
      local cfg="$TEST_TMPDIR/cfg.json"
      printf '{"oauthAccount":{"organizationUuid":"org-1"}}\n' > "$cfg"
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "org-1" "$_ORG" "first read parses the config" || return 1
      printf '{"oauthAccount":{"organizationUuid":"org-2"}}\n' > "$cfg"
      CS_STATUSLINE_NOW=1010 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "org-1" "$_ORG" "within the TTL the cached org answers" || return 1
      CS_STATUSLINE_NOW=1301 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "org-2" "$_ORG" "past the TTL the config is read again" || return 1 )
}

run_test test_org_id_is_cached_then_reread

# An unchanged context is stamped once a minute, not on every render: the mv is
# a fork, and the heartbeat readers allow fifteen minutes. A changed value is
# written at once.
test_context_pct_rewritten_on_change_or_once_a_minute() {
    export CLAUDE_SESSION_NAME=stampsess
    local dir="$CS_SESSIONS_ROOT/stampsess/.cs/local"
    mkdir -p "$dir"
    local at="$dir/context-pct.at" pct="$dir/context-pct"
    CS_STATUSLINE_NOW=1000 run_sl '{"context_window":{"used_percentage":30},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "30" "$(cat "$pct")" "first render writes the value" || return 1
    assert_eq "1000 30" "$(cat "$at")" "and records the write" || return 1
    CS_STATUSLINE_NOW=1010 run_sl '{"context_window":{"used_percentage":30},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "1000 30" "$(cat "$at")" "an unchanged value ten seconds later is not rewritten" || return 1
    CS_STATUSLINE_NOW=1020 run_sl '{"context_window":{"used_percentage":31},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "31" "$(cat "$pct")" "a changed value is written at once" || return 1
    assert_eq "1020 31" "$(cat "$at")" "and recorded" || return 1
    CS_STATUSLINE_NOW=1081 run_sl '{"context_window":{"used_percentage":31},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "1081 31" "$(cat "$at")" "an unchanged value is rewritten after a minute (the heartbeat)" || return 1
}

run_test test_context_pct_rewritten_on_change_or_once_a_minute

# The refresher lays the record's fields beside the JSON, one per line with the
# reset as an epoch, and a render takes them over the JSON: no jq, no date.
# The render itself never writes the sidecar, so a slow parse of an old record
# cannot overwrite a refresher's newer one.
test_fable_fields_written_beside_the_json() {
    _load_sl_functions
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"; mkdir -p "$CS_USAGE_DIR"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    CS_STATUSLINE_NOW=1787816000 _NOW="" _SL_NOW_READY="" _usage_write org-abc 86 "2026-08-29T03:59:59.686034+00:00" 600
    local f="$CS_USAGE_DIR/fable.org-abc.json.fields"
    assert_file_exists "$f" "the refresher writes the sidecar with the record" || return 1
    assert_eq "86
2026-08-29T03:59:59.686034+00:00
1787816000
1787816600
1787975999" "$(cat "$f")" "pct, resets_at, fetched_at, next_poll_at, reset epoch" || return 1
    printf 'not json\n' > "$CS_USAGE_DIR/fable.org-abc.json"
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "86" "$_FABLE_PCT" "the render reads the sidecar, not the JSON" || return 1
    assert_eq "1787975999" "$_FABLE_RESET" "with the reset already an epoch" || return 1
    # A record with no sidecar (written before it existed) is parsed, and the
    # render leaves no sidecar behind.
    rm -f "$f"
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59.686034+00:00" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "86" "$_FABLE_PCT" "a record without a sidecar is still read" || return 1
    assert_file_not_exists "$f" "and the render does not write one" || return 1
}

run_test test_fable_fields_written_beside_the_json


# One theme pass asks the tmux server once, whatever rungs it climbs: the
# client's own theme and its tty come back from the same query, so a client
# that reports no theme costs no second fork on the way to the cached one.
test_theme_pass_queries_tmux_once() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _make_ps_chain "$$:2216 2216:1"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      mkdir -p "$HOME/.cache/cs/term"
      printf 'light 252;247;229 %s\n' "$(date +%s)" > "$HOME/.cache/cs/term/ttys002"
      tmux() { printf 'q\n' >> "$TEST_TMPDIR/tmux-calls"; printf '\t/dev/ttys002\n'; }
      _sl_mark_foreign_env
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "the cached measurement answers when the client reports no theme" || return 1
      assert_eq "1" "$(wc -l < "$TEST_TMPDIR/tmux-calls" | tr -d ' ')" "tmux was asked once for both theme and tty" || return 1 )
}

run_test test_theme_pass_queries_tmux_once


# Two workspaces whose paths sanitise to the same file name never answer for
# each other: the entry carries the path it was made from.
test_git_cache_entries_are_bound_to_their_path() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    local a="$TEST_TMPDIR/x/a/b" b="$TEST_TMPDIR/x/a-b"
    mkdir -p "$a" "$b"
    for d in "$a" "$b"; do
        git -C "$d" init -q; git -C "$d" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m i
    done
    git -C "$b" checkout -q -b other
    local ja jb
    ja=$(jq -nc --arg dir "$a" '{workspace:{current_dir:$dir}}')
    jb=$(jq -nc --arg dir "$b" '{workspace:{current_dir:$dir}}')
    local outa outb
    outa=$(CS_STATUSLINE_NOW=1000 run_sl "$ja")
    outb=$(CS_STATUSLINE_NOW=1001 run_sl "$jb")
    assert_output_contains_f "$outa" "⎇ " "the first workspace shows a branch" || return 1
    assert_output_not_contains_f "$outa" "⎇ other" "and it is its own" || return 1
    assert_output_contains_f "$outb" "⎇ other" "the second, one second later, shows its own branch and not the first's" || return 1
}

run_test test_git_cache_entries_are_bound_to_their_path

# A workspace path between 100 and 200 characters is cached like any other.
test_git_cache_keys_a_long_path() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    local long="$TEST_TMPDIR/$(printf 'd%.0s' $(seq 1 60))/$(printf 'e%.0s' $(seq 1 60))"
    mkdir -p "$long"
    git -C "$long" init -q; git -C "$long" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m i
    local json; json=$(jq -nc --arg dir "$long" '{workspace:{current_dir:$dir}}')
    CS_STATUSLINE_NOW=1000 run_sl "$json" >/dev/null
    git -C "$long" checkout -q -b other || { echo "  FAIL: could not switch the branch"; return 1; }
    [ "$(git -C "$long" rev-parse --abbrev-ref HEAD)" = "other" ] || { echo "  FAIL: the tree is not on the new branch"; return 1; }
    local out; out=$(CS_STATUSLINE_NOW=1002 run_sl "$json")
    assert_output_contains_f "$out" "⎇ ma" "the long path's cached branch (main or master) answers" || return 1
    assert_output_not_contains_f "$out" "⎇ other" "within the TTL, not the new one" || return 1
}

run_test test_git_cache_keys_a_long_path

# The refresher never trusts the cached account id: it attributes a reading and
# detects a swap across its own fetch, and a stale identity there would file one
# account's usage under another.
test_refresher_reads_the_account_fresh() {
    ( _load_sl_functions
      local cfg="$TEST_TMPDIR/cfg.json"
      printf '{"oauthAccount":{"organizationUuid":"org-1"}}\n' > "$cfg"
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      printf '{"oauthAccount":{"organizationUuid":"org-2"}}\n' > "$cfg"
      CS_STATUSLINE_NOW=1010 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg" fresh
      assert_eq "org-2" "$_ORG" "a fresh read parses the config whatever the cache holds" || return 1
      CS_STATUSLINE_NOW=1011 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "org-2" "$_ORG" "and renews the cache for the renders" || return 1 )
}

run_test test_refresher_reads_the_account_fresh

# The attached client's answer is kept for TMUX_CLIENT_CACHE_TTL: a theme
# toggle shows at the first render past it, and no render inside it asks again.
test_tmux_client_answer_is_cached_for_the_ttl() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _make_ps_chain "$$:2216 2216:1"
      unset CS_TERM_THEME CS_TERM_THEME_AUTO CS_TERM_BG_RGB 2>/dev/null || true
      tmux() { printf 'q\n' >> "$TEST_TMPDIR/tmux-calls"; printf 'light\t/dev/ttys002\n'; }
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _sl_mark_foreign_env
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _sl_detect_theme
      assert_eq "light" "$SL_THEME" "the client's theme" || return 1
      tmux() { printf 'q\n' >> "$TEST_TMPDIR/tmux-calls"; printf 'dark\t/dev/ttys002\n'; }
      CS_STATUSLINE_NOW=1003 _NOW="" _SL_NOW_READY="" _sl_detect_theme
      assert_eq "light" "$SL_THEME" "within the TTL the cached answer stands" || return 1
      assert_eq "1" "$(wc -l < "$TEST_TMPDIR/tmux-calls" | tr -d ' ')" "and tmux was not asked again" || return 1
      CS_STATUSLINE_NOW=1006 _NOW="" _SL_NOW_READY="" _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "past the TTL the client is asked again" || return 1 )
}

run_test test_tmux_client_answer_is_cached_for_the_ttl

# A teammate's heartbeat touch keeps its own cadence record, so lead and
# teammate renders alternating do not read each other's value as a change and
# rewrite the file on every render between them.
test_teammate_heartbeat_does_not_reset_the_lead_cadence() {
    export CLAUDE_SESSION_NAME=altsess
    local dir="$CS_SESSIONS_ROOT/altsess/.cs/local"
    mkdir -p "$dir"
    printf 'claude_session_id: "lead"\n' > "$dir/state"
    local lead='{"session_id":"lead","context_window":{"used_percentage":30},"workspace":{"current_dir":"/none"}}'
    local mate='{"session_id":"mate","context_window":{"used_percentage":55},"workspace":{"current_dir":"/none"}}'
    CS_STATUSLINE_NOW=1000 run_sl "$lead" >/dev/null
    CS_STATUSLINE_NOW=1001 run_sl "$mate" >/dev/null
    CS_STATUSLINE_NOW=1002 run_sl "$lead" >/dev/null
    assert_eq "30" "$(cat "$dir/context-pct")" "the lead's value stands" || return 1
    assert_eq "1000 30" "$(cat "$dir/context-pct.at")" "the lead's cadence record was not reset by the teammate" || return 1
    assert_eq "1001 " "$(cat "$dir/context-pct.heartbeat.at")" "the teammate keeps its own" || return 1
}

run_test test_teammate_heartbeat_does_not_reset_the_lead_cadence

# The render records the width in cells of the line it printed, beside the id
# of the conversation it drew for and the pid of the Claude Code that ran it
# (CS_STATUSLINE_PARENT stands in for it here): the cs mod draws its keys at
# the right of the row under the bar only where the bar leaves them room. The
# escapes take no cell, so the quiet line counts as its text alone; the layout
# is named, since this suite draws the capsules unless a test says otherwise.
test_render_records_the_width_of_the_line_it_printed() {
    export CLAUDE_SESSION_NAME=widthsess CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/widthsess/.cs/local" out
    mkdir -p "$dir"
    printf 'claude_session_id: lead\n' > "$dir/state"
    local input='{"session_id":"lead","model":{"id":"claude-opus-4-8","display_name":"Opus"},"effort":{"level":"high"},"context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}'
    out=$(NO_COLOR=1 run_sl "$input")
    assert_eq "widthsess · ✦ Opus high > ○ ctx 8%" "$out" "the plain line" || return 1
    assert_eq "lead 34 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "the plain line's 34 cells are recorded" || return 1
    out=$(CS_STATUSLINE_LAYOUT=quiet COLORTERM=truecolor run_sl "$input")
    assert_output_contains_f "$out" "${ESC_}[" "the quiet line carries escapes" || return 1
    assert_eq "lead 42 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "the quiet line's 42 cells are recorded, its escapes not counted" || return 1
    assert_eq "statusline-width" "$(cd "$dir" && ls | grep '^statusline-width')" "the record is moved into place, and nothing is left beside it" || return 1
}

run_test test_render_records_the_width_of_the_line_it_printed

# A line as wide as the last is not written again: the write is a fork, and
# the bar repaints on every event. The file's inode tells a rewrite, since the
# record is moved into place; a wider line moves it, so the check is sensitive.
test_render_leaves_an_unchanged_width_record_alone() {
    export CLAUDE_SESSION_NAME=samesess NO_COLOR=1 CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/samesess/.cs/local" first second third
    mkdir -p "$dir"
    printf 'claude_session_id: lead\n' > "$dir/state"
    local input='{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}'
    run_sl "$input" >/dev/null
    first=$(ls -i "$dir/statusline-width" | awk '{print $1}')
    run_sl "$input" >/dev/null
    second=$(ls -i "$dir/statusline-width" | awk '{print $1}')
    assert_eq "$first" "$second" "the same width is not written again" || return 1
    run_sl "${input/8/18}" >/dev/null
    third=$(ls -i "$dir/statusline-width" | awk '{print $1}')
    assert_eq "lead 20 4242" "$(cat "$dir/statusline-width")" "a wider line is recorded" || return 1
    [ "$third" != "$second" ] || { echo "  FAIL: a changed width should replace the record"; return 1; }
}

run_test test_render_leaves_an_unchanged_width_record_alone

# Only the launched conversation records its line: a tmux teammate shares the
# directory and draws a bar of its own, and the lead's mod would place the
# lead's keys by the teammate's width. A session whose state names no
# conversation yet gets no record either, since the mod trusts none.
test_teammate_render_leaves_the_lead_width_record() {
    export CLAUDE_SESSION_NAME=matesess NO_COLOR=1 CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/matesess/.cs/local"
    mkdir -p "$dir"
    printf 'claude_session_id: "lead"\n' > "$dir/state"
    run_sl '{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}' >/dev/null
    run_sl '{"session_id":"mate","model":{"display_name":"Sonnet"},"context_window":{"used_percentage":55},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "lead 19 4242" "$(cat "$dir/statusline-width")" "the lead's record stands" || return 1
    CS_STATUSLINE_SEGMENTS=none run_sl '{"session_id":"mate","context_window":{"used_percentage":55},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_eq "lead 19 4242" "$(cat "$dir/statusline-width")" "and stands when the teammate's bar prints no line" || return 1
    : > "$dir/state"
    rm "$dir/statusline-width"
    run_sl '{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}' >/dev/null
    assert_not_exists "$dir/statusline-width" "a state naming no conversation records nothing" || return 1
}

run_test test_teammate_render_leaves_the_lead_width_record

# The record is true of the line on screen or it is gone: a run that prints no
# line of this conversation's (the bar turned off, stdin it cannot read, no
# segment to draw) removes the record a wider or narrower line left, and the
# next line is recorded again. Each case starts from a record, so a run that
# left it alone would fail.
test_a_render_that_prints_no_line_removes_the_width_record() {
    export CLAUDE_SESSION_NAME=gonesess NO_COLOR=1 CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/gonesess/.cs/local" out
    local input='{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}'
    mkdir -p "$dir"
    printf 'claude_session_id: lead\n' > "$dir/state"
    run_sl "$input" >/dev/null
    assert_eq "lead 19 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "a line is recorded" || return 1
    out=$(CS_STATUSLINE_DISABLE=1 run_sl "$input")
    assert_eq "" "$out" "the bar turned off prints nothing" || return 1
    assert_not_exists "$dir/statusline-width" "and removes the record" || return 1
    run_sl "$input" >/dev/null
    assert_eq "lead 19 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "the bar back on records its line again" || return 1
    out=$(cd "$TEST_TMPDIR" && run_sl 'not json')
    assert_eq "$(basename "$TEST_TMPDIR")" "$out" "stdin that is not JSON prints the directory's name" || return 1
    assert_not_exists "$dir/statusline-width" "which is not the recorded line: the record goes" || return 1
    run_sl "$input" >/dev/null
    out=$(CS_STATUSLINE_SEGMENTS=none run_sl "$input")
    assert_eq "" "$out" "no segment prints no line" || return 1
    assert_not_exists "$dir/statusline-width" "and removes the record" || return 1
}

run_test test_a_render_that_prints_no_line_removes_the_width_record

# The width counts one cell a character, which is true of ASCII and of the
# glyphs the bar draws itself. A character from outside (a conversation's
# title, a branch, a model's name) may take two cells or none, and bash has
# no table to tell: such a line's width is unknown, and its record is removed
# rather than written short. `漢字` would count 2 where it takes 4.
test_a_line_with_a_character_of_unknown_width_is_not_recorded() {
    export CLAUDE_SESSION_NAME=widesess NO_COLOR=1 CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/widesess/.cs/local" title out
    mkdir -p "$dir"
    printf 'claude_session_id: lead\n' > "$dir/state"
    for title in $'\xe6\xbc\xa2\xe5\xad\x97' $'ship \xf0\x9f\x9a\x80' $'caf\xc3\xa9' $'e\xcc\x81'; do
        run_sl '{"session_id":"lead","session_name":"plain","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}' >/dev/null
        assert_eq "lead 16 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "an ASCII title is counted with the bar's own glyphs" || return 1
        out=$(run_sl '{"session_id":"lead","session_name":"'"$title"'","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}')
        assert_output_contains_f "$out" "$title" "the title is on the line" || return 1
        assert_not_exists "$dir/statusline-width" "a line holding $title has no recorded width" || return 1
    done
}

run_test test_a_line_with_a_character_of_unknown_width_is_not_recorded

# Every character past ASCII that the script can print of its own is one the
# width counts as a cell (_SL_NARROW): a glyph added to a segment and not to
# that list would make every line that shows it a line of unknown width. The
# glyphs are read from the script's code lines, written out or as \x bytes.
test_every_glyph_the_bar_draws_is_one_the_width_counts() {
    local glyphs missed
    glyphs=$(perl -ne '
        next if /^\s*#/;
        s/\s#\s.*$//;
        my @runs = /((?:\\x[0-9a-fA-F]{2}){2,})/g;
        for my $run (@runs) { (my $hex = $run) =~ s/\\x//g; $_ .= " " . pack("H*", $hex) }
        print "$1\n" while /([\xC2-\xF4][\x80-\xBF]+)/g;
    ' "$SL" | LC_ALL=C sort -u)
    assert_eq "21" "$(printf '%s\n' "$glyphs" | grep -c .)" "the script's code holds 21 glyphs past ASCII" || return 1
    missed=$(
        CS_STATUSLINE_LIB=1; . "$SL"
        while IFS= read -r glyph; do
            _known_cells "a${glyph}b" && [ "$_WIDTH" = 3 ] || printf ' %s' "$(printf '%s' "$glyph" | od -An -tx1 | tr -d ' \n')"
        done <<< "$glyphs"
    )
    assert_eq "" "$missed" "each is counted as one cell (the bytes of any that is not)" || return 1
    ( CS_STATUSLINE_LIB=1; . "$SL"; _known_cells $'a\xe6\xbc\xa2b' ) \
        && { echo "  FAIL: a character from outside the list should have no known width"; return 1; }
    ( CS_STATUSLINE_LIB=1; . "$SL"; _known_cells $'a\tb' ) \
        && { echo "  FAIL: a control character should have no known width"; return 1; }
    return 0
}

run_test test_every_glyph_the_bar_draws_is_one_the_width_counts

# A conversation resumed in a second terminal has two Claude Codes drawing
# its bar into one record, each as wide as its own terminal lets it be. The
# second to draw marks the record shared, which gives the cs mod no width, and
# neither rewrites it while the other lives (the inode tells a rewrite); the
# one left when the other exits records its width again. This suite's shell
# and its parent stand in for the two; a pid already reaped for one that
# exited.
test_two_live_writers_share_the_width_record_without_trading_it() {
    export CLAUDE_SESSION_NAME=twosess NO_COLOR=1
    local dir="$CS_SESSIONS_ROOT/twosess/.cs/local" one="$$" two="$PPID" gone marked
    local input='{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}'
    mkdir -p "$dir"
    printf 'claude_session_id: lead\n' > "$dir/state"
    ( exit 0 ) & gone=$!
    wait "$gone"
    CS_STATUSLINE_PARENT=$gone run_sl "$input" >/dev/null
    CS_STATUSLINE_PARENT=$one run_sl "$input" >/dev/null
    assert_eq "lead 18 $one" "$(cat "$dir/statusline-width")" "a writer that exited is replaced" || return 1
    CS_STATUSLINE_PARENT=$two run_sl "${input/8/18}" >/dev/null
    assert_eq "lead - $two $one" "$(cat "$dir/statusline-width")" "a second live writer marks the record shared, with no width" || return 1
    marked=$(ls -i "$dir/statusline-width" | awk '{print $1}')
    CS_STATUSLINE_PARENT=$one run_sl "$input" >/dev/null
    CS_STATUSLINE_PARENT=$two run_sl "${input/8/18}" >/dev/null
    CS_STATUSLINE_PARENT=$gone run_sl "$input" >/dev/null
    assert_eq "lead - $two $one" "$(cat "$dir/statusline-width")" "the shared record stands" || return 1
    assert_eq "$marked" "$(ls -i "$dir/statusline-width" | awk '{print $1}')" "and no render of either rewrites it" || return 1
    printf 'lead - %s %s\n' "$gone" "$one" > "$dir/statusline-width"
    CS_STATUSLINE_PARENT=$one run_sl "$input" >/dev/null
    assert_eq "lead 18 $one" "$(cat "$dir/statusline-width")" "the writer left alone records its width again" || return 1
}

run_test test_two_live_writers_share_the_width_record_without_trading_it

# The record is written under a name of the writing process's own and moved
# into place, so two renders never write one temporary file, and a write the
# directory refuses says nothing on stderr. A directory left at the name every
# render once shared would refuse that write: the record is written all the
# same, and quietly.
test_width_record_is_written_under_a_per_process_name() {
    export CLAUDE_SESSION_NAME=tmpsess NO_COLOR=1 CS_STATUSLINE_PARENT=4242
    local dir="$CS_SESSIONS_ROOT/tmpsess/.cs/local" err
    mkdir -p "$dir/statusline-width.tmp"
    printf 'claude_session_id: lead\n' > "$dir/state"
    err=$(run_sl_stderr '{"session_id":"lead","context_window":{"used_percentage":8},"workspace":{"current_dir":"/none"}}')
    assert_eq "" "$err" "the render says nothing on stderr" || return 1
    assert_eq "lead 18 4242" "$(cat "$dir/statusline-width" 2>/dev/null)" "and records its line" || return 1
    assert_eq "statusline-width statusline-width.tmp" "$(cd "$dir" && ls | grep '^statusline-width' | tr '\n' ' ' | sed 's/ $//')" "leaving no file of its own beside the record" || return 1
}

run_test test_width_record_is_written_under_a_per_process_name

# While git tracks the session's control files the hooks mark the session under
# ~/.cache/cs/tracked (hooks/cs-resolve.sh), and the render adds, changes and
# removes nothing in .cs/local: neither the context stamp nor the limits stamp.
# The control render, unmarked, writes both, so the check is sensitive.
test_render_writes_nothing_into_a_tracked_control_directory() {
    export CLAUDE_SESSION_NAME=trackedsess CS_STATUSLINE_PARENT=4242
    local sess="$CS_SESSIONS_ROOT/trackedsess" porcelain
    local input='{"session_id":"lead","context_window":{"used_percentage":30},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000}},"workspace":{"current_dir":"/none"}}'
    mkdir -p "$sess/.cs/local"
    printf 'claude_session_id: lead\n' > "$sess/.cs/local/state"
    git -C "$sess" init -q
    git -C "$sess" add .cs/local/state
    git -C "$sess" -c user.name=t -c user.email=t@example.com commit -q -m tracked
    mkdir -p "$HOME/.cache/cs/tracked"
    : > "$HOME/.cache/cs/tracked/trackedsess"
    CS_STATUSLINE_NOW=1000 run_sl "$input" >/dev/null
    porcelain=$(git -C "$sess" status --porcelain --ignored -- .cs/local)
    assert_eq "" "$porcelain" "a marked session's control directory is left as git has it" || return 1
    rm "$HOME/.cache/cs/tracked/trackedsess"
    CS_STATUSLINE_NOW=1000 run_sl "$input" >/dev/null
    assert_eq "30" "$(cat "$sess/.cs/local/context-pct" 2>/dev/null)" "unmarked, the render stamps the context" || return 1
    assert_file_exists "$sess/.cs/local/limits" "and the limits" || return 1
    assert_eq "lead 38 4242" "$(cat "$sess/.cs/local/statusline-width" 2>/dev/null)" "and the width of its 38-cell line of three capsules" || return 1
}

run_test test_render_writes_nothing_into_a_tracked_control_directory

# The mark is read under the rule hooks/cs-resolve.sh writes it by: a session
# name that is empty or holds "/" is never marked, so it never reads as
# tracked, whatever a path built from it happens to reach under
# ~/.cache/cs/tracked. A plain name with its mark present is the control.
test_tracked_mark_is_read_only_for_a_name_the_hooks_mark() {
    ( _load_sl_functions
      mkdir -p "$HOME/.cache/cs/tracked/grp"
      : > "$HOME/.cache/cs/tracked/sess"
      : > "$HOME/.cache/cs/tracked/grp/sess"
      local rc
      rc=0; CLAUDE_SESSION_NAME=sess _session_files_tracked || rc=$?
      assert_eq "0" "$rc" "a plain name with its mark reads as tracked" || return 1
      rc=0; CLAUDE_SESSION_NAME=grp/sess _session_files_tracked || rc=$?
      assert_eq "1" "$rc" "a name holding / reads as not tracked" || return 1
      rc=0; CLAUDE_SESSION_NAME=../tracked/sess _session_files_tracked || rc=$?
      assert_eq "1" "$rc" "a name climbing out of the mark directory reads as not tracked" || return 1
      rc=0; CLAUDE_SESSION_NAME='' _session_files_tracked || rc=$?
      assert_eq "1" "$rc" "an empty name reads as not tracked" || return 1 )
}

run_test test_tracked_mark_is_read_only_for_a_name_the_hooks_mark


# A config that yields no account (caught mid-rewrite, or malformed) leaves no
# cache entry behind: the next render parses it again rather than showing no
# Fable window for the whole TTL.
test_org_cache_does_not_remember_an_empty_answer() {
    ( _load_sl_functions
      local cfg="$TEST_TMPDIR/cfg.json"
      printf '{"oauthAccount":{"organizationUu\n' > "$cfg"
      CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "" "$_ORG" "a torn config yields no account" || return 1
      printf '{"oauthAccount":{"organizationUuid":"org-1"}}\n' > "$cfg"
      CS_STATUSLINE_NOW=1001 _NOW="" _SL_NOW_READY="" _read_org_from "$cfg"
      assert_eq "org-1" "$_ORG" "the next read parses the config again" || return 1 )
}

run_test test_org_cache_does_not_remember_an_empty_answer


# A wrapper Claude Code runs in place of this script names the pid it is the
# child of in CS_STATUSLINE_PARENT, and the per-conversation caches key on
# that, so a bridge that is a new process every tick still hits them.
test_cache_keys_on_the_named_parent() {
    ( _load_sl_functions
      export TMUX="/tmp/fake,2216,0" PATH="$TEST_TMPDIR/fakebin:$PATH"
      _make_ps_chain "$$:2216 2216:1"
      CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_NOW=1000 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    a real chain must pass"; return 1; }
      _make_ps_chain "$$:1"
      CS_STATUSLINE_PARENT=4242 CS_STATUSLINE_NOW=1010 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          || { echo "    the verdict cached under the named parent must answer"; return 1; }
      CS_STATUSLINE_NOW=1011 _NOW="" _SL_NOW_READY="" _sl_tmux_is_real \
          && { echo "    without the name the key is this shell's own parent, a miss"; return 1; }
      return 0 )
}

run_test test_cache_keys_on_the_named_parent

# A cache file caught between its two lines is a miss, not an empty answer.
test_cache_read_rejects_a_half_written_entry() {
    ( _load_sl_functions
      mkdir -p "$HOME/.cache/cs/org"
      _cache_key "/c.json"
      printf '1000\t/c.json\n' > "$HOME/.cache/cs/org/$_CACHE_KEY"
      CS_STATUSLINE_NOW=1001 _NOW="" _SL_NOW_READY="" _cache_read org /c.json 300 \
          && { echo "    a header with no text line was taken as a hit"; return 1; }
      printf '1000\t/c.json\norg-1' > "$HOME/.cache/cs/org/$_CACHE_KEY"
      CS_STATUSLINE_NOW=1001 _NOW="" _SL_NOW_READY="" _cache_read org /c.json 300 \
          && { echo "    an unterminated text line was taken as a hit"; return 1; }
      printf '1000\t/c.json\norg-1\n' > "$HOME/.cache/cs/org/$_CACHE_KEY"
      CS_STATUSLINE_NOW=1001 _NOW="" _SL_NOW_READY="" _cache_read org /c.json 300 \
          || { echo "    a complete entry must hit"; return 1; }
      assert_eq "org-1" "$_CACHE_TEXT" "with its text" || return 1 )
}

run_test test_cache_read_rejects_a_half_written_entry

# The JSON's schedule is the one the refresher honours, so a backoff a 429
# recorded is never skipped; a sidecar left stale by a killed refresher is
# rewritten from the JSON without a fetch.
test_refresher_repairs_a_stale_sidecar_without_fetching() {
    use_scratch_usage_env
    local bindir="$TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/security" <<'SEC'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
SEC
    cat > "$bindir/curl" <<CURL
#!/bin/bash
cat > /dev/null
echo hit >> "$TEST_TMPDIR/curl-hits"
printf '500'
CURL
    chmod +x "$bindir/security" "$bindir/curl"
    export CS_SECURITY_BIN="$bindir/security"
    # JSON: a backoff into the future. Sidecar: stale, its schedule long past.
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":55,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787815990,"next_poll_at":1787999999}' \
        > "$CS_USAGE_DIR/fable.org-abc.json"
    printf '%s\n' 41 "2026-08-28T03:59:59Z" 1787700000 1787815000 1787889599 > "$CS_USAGE_DIR/fable.org-abc.json.fields"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_file_not_exists "$TEST_TMPDIR/curl-hits" "the recorded backoff is honoured: no fetch" || return 1
    assert_eq "55
2026-08-29T03:59:59Z
1787815990
1787999999
1787975999" "$(cat "$CS_USAGE_DIR/fable.org-abc.json.fields")" "the sidecar is rewritten from the JSON" || return 1
}

run_test test_refresher_repairs_a_stale_sidecar_without_fetching

# The workspace's current_dir follows the Bash tool's cwd, so a `cd` into a
# subdirectory of the checkout must not blank the branch: the segment reads
# the nearest ancestor that holds .git, and caches under that ancestor, so a
# subdirectory render within the TTL answers from the checkout's own entry.
test_git_branch_shows_from_a_subdirectory_of_the_checkout() {
    export CS_TERM_THEME=light FORCE_COLOR=0
    local work sub json_top json_sub
    work=$(make_git_work)
    sub="$work/mods/deep"; mkdir -p "$sub"
    json_top=$(jq -nc --arg dir "$work" '{workspace:{current_dir:$dir}}')
    json_sub=$(jq -nc --arg dir "$sub" '{workspace:{current_dir:$dir}}')
    local top first slash later
    top=$(CS_STATUSLINE_NOW=1000 run_sl "$json_top")
    assert_output_contains_f "$top" "⎇ main +1!1" "the checkout itself shows the branch" || return 1
    # The checkout alone is warm. A subdirectory rendered inside the TTL must
    # answer from that entry: one that read the tree itself would see the new
    # branch. A trailing slash on the checkout path names the same entry.
    git -C "$work" checkout -q -b other
    first=$(CS_STATUSLINE_NOW=1001 run_sl "$json_sub")
    assert_output_contains_f "$first" "⎇ main +1!1" "a subdirectory answers from the checkout's own cache entry" || return 1
    assert_output_not_contains_f "$first" "⎇ other" "not from a fresh read" || return 1
    slash=$(CS_STATUSLINE_NOW=1002 run_sl "$(jq -nc --arg dir "$work/" '{workspace:{current_dir:$dir}}')")
    assert_output_contains_f "$slash" "⎇ main +1!1" "the checkout path with a trailing slash is the same entry" || return 1
    slash=$(CS_STATUSLINE_NOW=1003 run_sl "$(jq -nc --arg dir "$work//mods/deep/" '{workspace:{current_dir:$dir}}')")
    assert_output_contains_f "$slash" "⎇ main +1!1" "a doubled slash inside the path climbs to the same entry" || return 1
    later=$(CS_STATUSLINE_NOW=1006 run_sl "$json_sub")
    assert_output_contains_f "$later" "⎇ other" "past the TTL the subdirectory reads the tree" || return 1
    # A worktree checkout's .git is a file, not a directory: it is found too.
    local wt="$TEST_TMPDIR/wt"
    git -C "$work" worktree add -q "$wt" -b wt-branch 2>/dev/null || { echo "  FAIL: could not add a worktree"; return 1; }
    mkdir -p "$wt/inner"
    local json_wt out_wt
    json_wt=$(jq -nc --arg dir "$wt/inner" '{workspace:{current_dir:$dir}}')
    out_wt=$(CS_STATUSLINE_NOW=1010 run_sl "$json_wt")
    assert_output_contains_f "$out_wt" "⎇ wt-branch" "a subdirectory of a worktree shows the worktree's branch" || return 1
}

run_test test_git_branch_shows_from_a_subdirectory_of_the_checkout

# The bar repaints on every event in every open session, and an endpoint agent
# charges the machine for every process born, so what a warm render costs is
# the number of processes it starts, not the number of programs it runs: a
# command substitution and each side of a pipeline are processes too. The only
# program a warm render needs is the single jq pass over stdin; a bash without
# a builtin clock (stock macOS 3.2) adds its date. A trace names them, since a
# child shows as a deeper `+` level. Measured on a quiet machine, that leaves
# three processes per render on bash 5 (this script, the shell of the jq
# substitution, jq) and five on 3.2, where the clock is a second substitution.
test_a_warm_render_runs_no_program_but_jq() {
    export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1 FORCE_COLOR=0
    # The theme pin carries the auto marker, so the ladder runs as it does in a
    # live session rather than short-circuiting on the pin.
    export CS_STATUSLINE_PARENT=4242
    unset COLORFGBG
    local trace children
    trace="$TEST_TMPDIR/render.trace"
    # The first render fills the caches; the second is the warm one measured.
    printf '%s' "$FIXTURE_DOCS" | bash "$SL" >/dev/null 2>/dev/null
    printf '%s' "$FIXTURE_DOCS" | bash -x "$SL" >/dev/null 2>"$trace"
    children=$(grep '^++ ' "$trace" | awk '{print $2}' | sort -u | grep -v -x -e jq -e date)
    [ -z "$children" ] || {
        echo "  FAIL: a warm render runs a program other than jq: $(echo $children)"
        return 1
    }
}

run_test test_a_warm_render_runs_no_program_but_jq

# --- band layout -------------------------------------------------------------

# The band tests' common ground: the docs fixture on a dark terminal of a known
# background, truecolor, 80 cells wide.
band_env() {
    export CS_STATUSLINE_LAYOUT=band CS_STATUSLINE_COLS=80 \
        CS_TERM_THEME=dark CS_TERM_BG_RGB="21;24;40" COLORTERM=truecolor
}

# The cells rendered line $1 takes on screen: its escapes stripped, counted the
# way _display_width counts.
band_cells() {
    local plain
    plain=$(printf '%s' "$1" | sed "s/$ESC_\[[0-9;]*m//g")
    ( _load_sl_functions; _display_width "$plain"; printf '%s' "$_WIDTH" )
}

test_band_fills_exactly_the_width() {
    band_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq 80 "$(band_cells "$out")" "an 80-column band is 80 cells" || return 1
    out=$(CS_STATUSLINE_COLS=40 CS_STATUSLINE_SEGMENTS=logo,session run_sl "$FIXTURE_DOCS")
    assert_eq 40 "$(band_cells "$out")" "a 40-column band is 40 cells" || return 1
    assert_eq "${ESC_}[0m" "${out: -4}" "the line ends with a reset" || return 1
}

# The docs fixture's items take 55 cells (one band cell, ✳, my-session, Opus
# high, ○ ctx 8%, ◷ 5h 23%, and the joiners between them). Past the width they
# are all emitted, uncut and with no fill after them: Claude Code truncates.
test_band_overflow_emits_every_item_and_no_fill() {
    band_env
    local out
    out=$(CS_STATUSLINE_COLS=40 run_sl "$FIXTURE_DOCS")
    assert_eq 55 "$(band_cells "$out")" "items wider than the band are emitted whole" || return 1
    assert_eq " ✳ my-session  ·  ✦ Opus high  ·  ○ ctx 8%  ·  ◷ 5h 23%" \
        "$(printf '%s' "$out" | sed "s/$ESC_\[[0-9;]*m//g")" "every item, uncut, and no fill after the last" || return 1
}

# Under the C locale bash sees bytes, and a glyph's continuation bytes must
# stay in its cell rather than each take a cell of gradient.
test_band_width_holds_under_the_c_locale() {
    band_env
    local out
    out=$(LC_ALL=C run_sl "$FIXTURE_DOCS")
    assert_eq 80 "$(band_cells "$out")" "the C locale still yields 80 cells" || return 1
}

# The frame comes off a measured width; CS_STATUSLINE_COLS is already the
# width the caller may use, so none comes off it.
test_band_frame_is_subtracted_from_a_measured_width() {
    band_env
    unset CS_STATUSLINE_COLS
    local json out
    json=$(jq -c '. + {columns: 100}' <<< "$FIXTURE_DOCS")
    out=$(run_sl "$json")
    assert_eq 96 "$(band_cells "$out")" "the default frame takes 4 columns" || return 1
    out=$(CS_STATUSLINE_FRAME=10 run_sl "$json")
    assert_eq 90 "$(band_cells "$out")" "a padded frame takes what it names" || return 1
    out=$(CS_STATUSLINE_FRAME=0 run_sl "$json")
    assert_eq 100 "$(band_cells "$out")" "no frame takes nothing" || return 1
    out=$(CS_STATUSLINE_FRAME=wide run_sl "$json")
    assert_eq 96 "$(band_cells "$out")" "a frame that is not a number is the default" || return 1
    out=$(CS_STATUSLINE_COLS=120 run_sl "$json")
    assert_eq 120 "$(band_cells "$out")" "the override is the final width, the frame untouched" || return 1
    out=$(CS_STATUSLINE_COLS=120 CS_STATUSLINE_FRAME=10 run_sl "$json")
    assert_eq 120 "$(band_cells "$out")" "a named frame leaves the override alone too" || return 1
}

test_band_width_floors_at_twenty() {
    band_env
    export CS_STATUSLINE_SEGMENTS=logo
    local out
    out=$(CS_STATUSLINE_COLS=10 run_sl "$FIXTURE_DOCS")
    assert_eq 20 "$(band_cells "$out")" "a ten-column override floors at twenty" || return 1
    unset CS_STATUSLINE_COLS
    out=$(run_sl "$(jq -c '. + {columns: 22}' <<< "$FIXTURE_DOCS")")
    assert_eq 20 "$(band_cells "$out")" "a frame that drops a measured width below twenty floors there" || return 1
}

test_band_columns_from_stdin_rank_below_the_override() {
    band_env
    unset CS_STATUSLINE_COLS
    local json out
    json=$(jq -c '. + {columns: 100}' <<< "$FIXTURE_DOCS")
    out=$(run_sl "$json")
    assert_eq 96 "$(band_cells "$out")" ".columns sets the width, less the frame" || return 1
    out=$(CS_STATUSLINE_COLS=80 run_sl "$json")
    assert_eq 80 "$(band_cells "$out")" "CS_STATUSLINE_COLS outranks .columns" || return 1
    out=$(CS_STATUSLINE_COLS=abc run_sl "$json")
    assert_eq 96 "$(band_cells "$out")" "an override that is not a number is ignored" || return 1
}

# Outside tmux and without a terminal to measure, the band is 120 columns.
# stty is a failing shim, so a runner that does have a terminal measures nothing
# either.
test_band_width_defaults_to_120() {
    band_env
    unset CS_STATUSLINE_COLS
    mkdir -p "$TEST_TMPDIR/fakebin"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/stty"
    chmod +x "$TEST_TMPDIR/fakebin/stty"
    local out
    out=$(PATH="$TEST_TMPDIR/fakebin:$PATH" run_sl "$FIXTURE_DOCS")
    assert_eq 116 "$(band_cells "$out")" "nothing measured is 120, less the frame" || return 1
}

# A cached stty answer is read the way a fresh one is: an entry that is not a
# column count (a hand-edited file, a torn write, another cs's format) is a
# miss, so the band is 120 less the frame and nothing reaches stderr.
test_band_width_ignores_a_poisoned_stty_cache() {
    band_env
    unset CS_STATUSLINE_COLS
    export CS_STATUSLINE_PARENT=4242
    mkdir -p "$TEST_TMPDIR/fakebin" "$HOME/.cache/cs/stty"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/stty"
    chmod +x "$TEST_TMPDIR/fakebin/stty"
    local bad out err
    for bad in nope "80 24" 500000000000; do
        printf '%s\t4242\n%s\n' "$(date +%s)" "$bad" > "$HOME/.cache/cs/stty/4242"
        out=$(PATH="$TEST_TMPDIR/fakebin:$PATH" run_sl "$FIXTURE_DOCS" 2>"$TEST_TMPDIR/err")
        err=$(cat "$TEST_TMPDIR/err")
        assert_eq 116 "$(band_cells "$out")" "a cached '$bad' is a miss, not a width" || return 1
        assert_eq "" "$err" "a cached '$bad' prints nothing to stderr" || return 1
    done
}

# Inside a real tmux the width is the pane's, from the one query the client
# rung already makes, asked about the pane in TMUX_PANE.
test_band_width_from_the_tmux_pane() {
    band_env
    unset CS_STATUSLINE_COLS
    export TMUX="/tmp/fake,1,0" TMUX_PANE="%7" CS_STATUSLINE_PARENT=4242
    mkdir -p "$TEST_TMPDIR/fakebin" "$HOME/.cache/cs/tmux-real"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nprintf "dark\\t/dev/ttys002\\t90\\n"\n' \
        "$TEST_TMPDIR/tmux.args" > "$TEST_TMPDIR/fakebin/tmux"
    chmod +x "$TEST_TMPDIR/fakebin/tmux"
    printf '%s\t%s\nreal\n' "$(date +%s)" "4242,$TMUX" > "$HOME/.cache/cs/tmux-real/4242,-tmp-fake,1,0"
    local out
    out=$(PATH="$TEST_TMPDIR/fakebin:$PATH" run_sl "$FIXTURE_DOCS")
    assert_eq 86 "$(band_cells "$out")" "the pane's width sets the band, less the frame" || return 1
    assert_output_contains_f "$(cat "$TEST_TMPDIR/tmux.args")" "-t %7" "the width asked for is TMUX_PANE's" || return 1
    out=$(PATH="$TEST_TMPDIR/fakebin:$PATH" run_sl "$FIXTURE_DOCS")
    assert_eq 1 "$(wc -l < "$TEST_TMPDIR/tmux.args" | tr -d ' ')" "a second render reads the cached answer" || return 1
}

# A TMUX this process only inherited names a pane it is not in: its width is
# not the band's.
test_band_width_ignores_a_foreign_tmux() {
    band_env
    unset CS_STATUSLINE_COLS
    export TMUX="/tmp/fake,1,0" TMUX_PANE="%7" CS_STATUSLINE_PARENT=4242
    mkdir -p "$TEST_TMPDIR/fakebin" "$HOME/.cache/cs/tmux-real"
    printf '#!/bin/sh\nprintf "dark\\t/dev/ttys002\\t90\\n"\n' > "$TEST_TMPDIR/fakebin/tmux"
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/fakebin/stty"
    chmod +x "$TEST_TMPDIR/fakebin/tmux" "$TEST_TMPDIR/fakebin/stty"
    printf '%s\t%s\nforeign\n' "$(date +%s)" "4242,$TMUX" > "$HOME/.cache/cs/tmux-real/4242,-tmp-fake,1,0"
    local out
    out=$(PATH="$TEST_TMPDIR/fakebin:$PATH" run_sl "$FIXTURE_DOCS")
    assert_eq 116 "$(band_cells "$out")" "a foreign pane's width is not used" || return 1
}

# Run command string $1 under a pseudo-terminal, so /dev/tty opens; 77 (skip)
# where no `script` here can provide one. BSD script takes the command after
# the file, util-linux script takes it in -c; each form is proved by a probe
# that leaves a file behind, since the other form can exit 0 without running
# the command at all.
in_pty() {
    local probe="$TEST_TMPDIR/pty-probe"
    rm -f "$probe"
    script -q /dev/null /bin/sh -c "touch '$probe'" </dev/null >/dev/null 2>&1
    if [ -f "$probe" ]; then
        script -q /dev/null /bin/sh -c "$1" </dev/null >/dev/null 2>&1
        return 0
    fi
    script -qec "touch '$probe'" /dev/null </dev/null >/dev/null 2>&1
    if [ -f "$probe" ]; then
        script -qec "$1" /dev/null </dev/null >/dev/null 2>&1
        return 0
    fi
    SKIP_REASON="no script(1) to provide a terminal"
    return 77
}

# On a terminal and outside tmux the width is the terminal's, measured once per
# conversation: a resize inside the cache window is not measured again.
test_band_width_from_the_terminal_is_measured_once() {
    band_env
    unset CS_STATUSLINE_COLS
    export CS_STATUSLINE_PARENT=4243
    printf '%s' "$FIXTURE_DOCS" > "$TEST_TMPDIR/in.json"
    in_pty "stty cols 100 rows 30 </dev/tty; bash '$SL' < '$TEST_TMPDIR/in.json' > '$TEST_TMPDIR/first.txt'; stty cols 60 </dev/tty; bash '$SL' < '$TEST_TMPDIR/in.json' > '$TEST_TMPDIR/second.txt'" || return $?
    assert_eq 96 "$(band_cells "$(cat "$TEST_TMPDIR/first.txt")")" "the terminal's 100 columns set the band, less the frame" || return 1
    assert_eq 96 "$(band_cells "$(cat "$TEST_TMPDIR/second.txt")")" "the second render reuses the measurement" || return 1
}

test_band_render_writes_nothing_to_stderr() {
    band_env
    unset CS_STATUSLINE_COLS
    assert_eq "" "$(run_sl_stderr "$FIXTURE_DOCS")" "the band renders silently" || return 1
}

# The fill the band starts at: the run that opens the line after its reset,
# one blank cell.
band_first_cell() {
    printf '%s' "${1:4:40}" | sed -n "s/^\($ESC_\[[0-9;]*m\) .*/\1/p" | tr -d '\033'
}

# A session whose machine-local state names colour $1.
band_session_colour() {
    export CLAUDE_SESSION_NAME=band-sess
    mkdir -p "$CS_SESSIONS_ROOT/band-sess/.cs/local"
    printf 'claude_session_color: %s\n' "$1" > "$CS_SESSIONS_ROOT/band-sess/.cs/local/state"
}

# The first cell is the band colour, and the last cell is the background
# itself. With no session and no override the colour is neutral, which takes
# no pull: the dark background 21;24;40 lifted to 61;64;90.
test_band_fades_from_the_band_colour_to_the_background() {
    band_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[0m" "$(printf '%s' "${out:0:4}" | tr -d '\033')" "the line opens with a reset" || return 1
    assert_eq "[48;2;61;64;90m" "$(band_first_cell "$out")" "the first cell is the neutral band colour" || return 1
    local tail="${ESC_}[48;2;21;24;40m ${ESC_}[0m"
    assert_eq "$tail" "${out: -${#tail}}" "the last cell is the background" || return 1
}

# A light terminal's neutral is the background darkened 30 a channel:
# 250;246;235 to 220;216;205.
test_band_neutral_darkens_a_light_background() {
    band_env
    export CS_TERM_THEME=light CS_TERM_BG_RGB="250;246;235"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;220;216;205m" "$(band_first_cell "$out")" "a light neutral is a darker step" || return 1
}

# On cream 253;246;227 the neutral is 223;216;197, asked for with `none` or
# reached with no session colour, and still that colour at the first cell.
test_band_neutral_on_cream_takes_no_pull() {
    band_env
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    local out
    out=$(CS_STATUSLINE_BAND=none run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;223;216;197m" "$(band_first_cell "$out")" "none on cream" || return 1
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;223;216;197m" "$(band_first_cell "$out")" "no session colour on cream" || return 1
}

# The session colour from the state file: blue 106;155;204, halfway to its
# luminance 145 is 125;150;175, and 78% of the way from there to 21;24;40 is
# 44;52;70.
test_band_takes_the_session_colour() {
    band_env
    band_session_colour blue
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "the session colour starts the band" || return 1
}

# The same desaturated blue 125;150;175 pulled 78% toward cream 253;246;227 is
# 224;224;215, and toward the dark 21;24;40 is 44;52;70.
test_band_hue_is_desaturated_and_pulled_per_theme() {
    band_env
    local out
    out=$(CS_STATUSLINE_BAND=blue CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227" run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;224;224;215m" "$(band_first_cell "$out")" "blue on cream" || return 1
    out=$(CS_STATUSLINE_BAND=blue run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "blue on dark" || return 1
}

test_band_without_a_usable_session_colour_is_neutral() {
    band_env
    local out
    band_session_colour magenta
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;61;64;90m" "$(band_first_cell "$out")" "a colour outside the palette is neutral" || return 1
    rm -f "$CS_SESSIONS_ROOT/band-sess/.cs/local/state"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;61;64;90m" "$(band_first_cell "$out")" "a session without state is neutral" || return 1
}

# CS_STATUSLINE_BAND outranks the session colour: red 220;38;38 desaturates to
# 156;65;65 and pulls to 51;34;46 (the -31.98 truncates to -31), the triplet
# 100;200;0 to 44;57;48, brand 217;119;87 to 57;48;57. `session` and anything
# unusable fall to the session colour (blue, 44;52;70); `none` is the neutral
# even with one set.
test_band_colour_override_precedence() {
    band_env
    band_session_colour blue
    local out
    out=$(CS_STATUSLINE_BAND=red run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;51;34;46m" "$(band_first_cell "$out")" "a palette name" || return 1
    out=$(CS_STATUSLINE_BAND="100;200;0" run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;57;48m" "$(band_first_cell "$out")" "an r;g;b triplet" || return 1
    out=$(CS_STATUSLINE_BAND=brand run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;57;48;57m" "$(band_first_cell "$out")" "the brand coral" || return 1
    out=$(CS_STATUSLINE_BAND=session run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "session names the session colour" || return 1
    out=$(CS_STATUSLINE_BAND=chartreuse run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "an unknown word falls to the session colour" || return 1
    out=$(CS_STATUSLINE_BAND="red blue" run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "two palette names are not one" || return 1
    out=$(CS_STATUSLINE_BAND="300;0;0" run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;44;52;70m" "$(band_first_cell "$out")" "an out-of-range triplet falls to the session colour" || return 1
    out=$(CS_STATUSLINE_BAND=none run_sl "$FIXTURE_DOCS")
    assert_eq "[48;2;61;64;90m" "$(band_first_cell "$out")" "none is the neutral band" || return 1
    assert_eq "" "$(CS_STATUSLINE_BAND=chartreuse run_sl_stderr "$FIXTURE_DOCS")" "an unusable override is silent" || return 1
}


# The docs fixture with its ctx and limits readings replaced: $1 ctx, $2 5h,
# $3 wk.
band_fixture() {
    jq -c --argjson c "$1" --argjson h "$2" --argjson w "$3" \
        '.context_window.used_percentage = $c
         | .rate_limits.five_hour.used_percentage = $h
         | .rate_limits.seven_day.used_percentage = $w' <<< "$FIXTURE_DOCS"
}

# An amber reading is amber ink, bold, on the gradient, on either theme: ctx 45
# starts at cell 40, 40/79 of the way from 61;64;90 to 21;24;40, so 41;44;65,
# and the dot joiner's first space follows at cell 43, 40;43;63. On cream the
# number is the light amber 180;83;9, and a crit group is still a red island.
test_band_amber_reading_is_ink() {
    band_env
    local out
    out=$(run_sl "$(band_fixture 45 23.5 41.2)")
    assert_output_contains_f "$out" \
        "${ESC_}[48;2;41;44;65;38;2;251;191;36;1m4" "the ctx number at warn is amber ink on the gradient" || return 1
    assert_output_contains_f "$out" \
        "%${ESC_}[48;2;40;43;63;38;2;150;165;200;22m " "the joiner follows on the next cell" || return 1
    assert_eq 80 "$(band_cells "$out")" "the amber cells are counted" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$(band_fixture 45 23.5 41.2)")
    assert_output_contains_f "$out" ";38;2;180;83;9;1m4" "the ctx number on cream is light amber, bold" || return 1
    assert_output_not_contains_f "$out" "48;2;251;232;196" "no amber fill on cream" || return 1
    out=$(run_sl "$(band_fixture 8 95 60)")
    assert_output_contains_f "$out" "${ESC_}[48;2;215;0;21;38;2;255;255;255;1m ◷ 5h 95% " "crit on cream is the red island" || return 1
}

# The amber island's tokens are gone: like any unknown name, they paint the
# surface at every level.
test_band_amber_island_tokens_are_unknown() {
    ( _load_sl_functions
      local level want
      for level in truecolor 256 basic; do
          LEVEL=$level; SL_THEME=light; _SURFACE_RGB=""
          _sgr 48 surface; want="$_SGR"
          _sgr 48 amberfill; assert_eq "$want" "$_SGR" "amberfill at $level is the surface" || return 1
          _sgr 48 amberink;  assert_eq "$want" "$_SGR" "amberink at $level is the surface" || return 1
      done )
}

# A crit group is one red island, its joiners inside it: 5h at crit takes wk
# with it. The island ends at cell 67, and the fade runs on from cell 68 at
# 27;30;47.
test_band_crit_group_is_one_red_island() {
    band_env
    local out
    out=$(run_sl "$(band_fixture 8 95 60)")
    assert_output_contains_f "$out" \
        "${ESC_}[48;2;255;69;58;38;2;255;255;255;1m ◷ 5h 95% ⋮ ◶ wk 60% ${ESC_}[48;2;27;30;47m    " \
        "the limits group at crit is one red island" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;2;38;41;61;38;2;150;165;200;22m ${ESC_}[48;2;255;69;58;" \
        "the dot before the island sits on the gradient, its last cell at 46" || return 1
    assert_eq 80 "$(band_cells "$out")" "the island's cells are counted" || return 1
}

# The band's own inks on a dark terminal, each cell on its own fill: the mark
# keeps the brand coral (cell 1), bold text takes the primary (my-session from
# cell 3), the effort word its own colour (cell 25), a label the dim ink
# (cell 34).
test_band_inks_on_a_dark_terminal() {
    band_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "${ESC_}[48;2;61;64;90;38;2;217;119;87;1m✳" "the mark is brand coral" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;2;60;63;89;38;2;255;255;255;1mm" "the session name is primary" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;2;49;52;75;38;2;146;158;250;22mh" "the effort word keeps its colour" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;2;44;47;69;38;2;150;165;200;22m○" "a label is dim" || return 1
}

# The three band inks per theme, which no default item exercises all of. On a
# light theme they are shades of the band's hue, here blue 106;155;204: 34%,
# 44% and 56% of each channel.
test_band_ink_roles_per_theme() {
    ( _load_sl_functions
      LEVEL=truecolor; SL_THEME=dark
      _HUE_R=106; _HUE_G=155; _HUE_B=204
      _band_ink ink bold; assert_eq "38;2;255;255;255" "$_BAND_FG" "dark primary" || return 1
      _band_ink white "";  assert_eq "38;2;255;255;255" "$_BAND_FG" "white is the primary" || return 1
      _band_ink ink "";    assert_eq "38;2;214;222;240" "$_BAND_FG" "dark secondary" || return 1
      _band_ink ink2 "";   assert_eq "38;2;150;165;200" "$_BAND_FG" "dark dim" || return 1
      SL_THEME=light
      _band_ink ink bold; assert_eq "38;2;36;52;69" "$_BAND_FG" "light primary" || return 1
      _band_ink white "";  assert_eq "38;2;36;52;69" "$_BAND_FG" "white is the light primary" || return 1
      _band_ink ink "";    assert_eq "38;2;46;68;89" "$_BAND_FG" "light secondary" || return 1
      _band_ink ink2 "";   assert_eq "38;2;59;86;114" "$_BAND_FG" "light dim" || return 1
      _band_ink periwinkle ""; assert_eq "38;2;76;29;149" "$_BAND_FG" "periwinkle keeps its colour" || return 1 )
}

# A light band's inks come from the raw hue, not the pale band it is pulled
# to: blue gives the session name 36;52;69 and a label 59;86;114. The neutral
# on cream, 223;216;197, gives 75;73;66 and 124;120;110. Nothing on a light
# band is bold, the mark included.
test_band_inks_on_a_light_terminal() {
    band_env
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    local out
    out=$(CS_STATUSLINE_BAND=blue run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" ";38;2;36;52;69;22mm" "the session name is the blue primary, regular weight" || return 1
    assert_output_contains_f "$out" ";38;2;59;86;114;22m○" "a label is the blue dim" || return 1
    assert_output_contains_f "$out" ";38;2;217;119;87;22m✳" "the mark is regular weight" || return 1
    assert_output_not_contains_f "$out" ";1m" "no item is bold" || return 1
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" ";38;2;75;73;66;22mm" "the session name is the neutral's primary" || return 1
    assert_output_contains_f "$out" ";38;2;124;120;110;22m○" "a label is the neutral's dim" || return 1
}

test_band_plain_level_prints_the_plain_line() {
    band_env
    export NO_COLOR=1
    local want out
    want=$(CS_STATUSLINE_LAYOUT="" run_sl "$FIXTURE_DOCS")
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "$want" "$out" "plain ignores the layout" || return 1
}

# Below truecolor the band is a flat surface fill, every cell, the amber ink
# and the crit island in the level's own tokens.
test_band_256_is_a_flat_fill() {
    band_env
    unset COLORTERM
    local out
    out=$(run_sl "$(band_fixture 45 95 60)")
    assert_eq 80 "$(band_cells "$out")" "a flat band is 80 cells" || return 1
    assert_output_not_contains_f "$out" "48;2;" "no truecolor fill" || return 1
    assert_eq "[48;5;237m" "$(band_first_cell "$out")" "the band is the 256 surface" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;5;237;38;5;214;1m45%" "the amber number in 256 tokens on the flat fill" || return 1
    assert_output_contains_f "$out" "${ESC_}[48;5;203;38;5;231;1m ◷ 5h 95% ⋮ ◶ wk 60% " "the crit island in 256 tokens" || return 1
}

test_band_basic_is_a_flat_fill() {
    band_env
    unset COLORTERM
    export TERM=xterm
    local out
    out=$(run_sl "$(band_fixture 45 23.5 41.2)")
    assert_eq 80 "$(band_cells "$out")" "a basic band is 80 cells" || return 1
    assert_output_not_contains_f "$out" "48;" "no 256 or truecolor fill" || return 1
    assert_eq "[100m" "$(band_first_cell "$out")" "the band is the basic surface" || return 1
    assert_output_contains_f "$out" "${ESC_}[100;93;1m45%" "the amber number in basic tokens on the flat fill" || return 1
}


run_test test_band_fills_exactly_the_width
run_test test_band_overflow_emits_every_item_and_no_fill
run_test test_band_width_holds_under_the_c_locale
run_test test_band_frame_is_subtracted_from_a_measured_width
run_test test_band_width_floors_at_twenty
run_test test_band_columns_from_stdin_rank_below_the_override
run_test test_band_width_defaults_to_120
run_test test_band_width_ignores_a_poisoned_stty_cache
run_test test_band_width_from_the_tmux_pane
run_test test_band_width_ignores_a_foreign_tmux
run_test test_band_width_from_the_terminal_is_measured_once
run_test test_band_render_writes_nothing_to_stderr
run_test test_band_fades_from_the_band_colour_to_the_background
run_test test_band_neutral_darkens_a_light_background
run_test test_band_neutral_on_cream_takes_no_pull
run_test test_band_takes_the_session_colour
run_test test_band_hue_is_desaturated_and_pulled_per_theme
run_test test_band_without_a_usable_session_colour_is_neutral
run_test test_band_colour_override_precedence
run_test test_band_amber_reading_is_ink
run_test test_band_amber_island_tokens_are_unknown
run_test test_band_crit_group_is_one_red_island
run_test test_band_inks_on_a_dark_terminal
run_test test_band_inks_on_a_light_terminal
run_test test_band_ink_roles_per_theme
run_test test_band_plain_level_prints_the_plain_line
run_test test_band_256_is_a_flat_fill
run_test test_band_basic_is_a_flat_fill

# --- quiet layout ------------------------------------------------------------

# The quiet tests' common ground: the docs fixture on a dark terminal of a
# known background, truecolor.
quiet_env() {
    export CS_STATUSLINE_LAYOUT=quiet CS_TERM_THEME=dark CS_TERM_BG_RGB="21;24;40" \
        COLORTERM=truecolor
}

# Quiet is the default: unset, empty and unknown layouts draw it, and the band
# and the capsules are drawn only when named.
test_layout_unset_empty_or_unknown_is_quiet() {
    quiet_env
    local want out
    want=$(run_sl "$FIXTURE_DOCS")
    assert_eq " ✳ my-session   ·  ✦ Opus high  ·  ○ ctx 8%  ·  ◷ 5h 23%" \
        "$(printf '%s' "$want" | sed "s/$ESC_\[[0-9;]*m//g")" "quiet draws the items with no fill after them" || return 1
    out=$(CS_STATUSLINE_LAYOUT="" run_sl "$FIXTURE_DOCS")
    assert_eq "$want" "$out" "an empty layout is quiet" || return 1
    out=$(CS_STATUSLINE_LAYOUT=ribbon run_sl "$FIXTURE_DOCS")
    assert_eq "$want" "$out" "an unknown layout is quiet" || return 1
    out=$(CS_STATUSLINE_LAYOUT=band CS_STATUSLINE_COLS=80 run_sl "$FIXTURE_DOCS")
    assert_eq 80 "$(band_cells "$out")" "band draws the 80-cell band" || return 1
    local tail="${ESC_}[48;2;21;24;40m ${ESC_}[0m"
    assert_eq "$tail" "${out: -${#tail}}" "the band fades to the background" || return 1
    out=$(CS_STATUSLINE_LAYOUT=capsules run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "$CAPL" "capsules draws the capsules" || return 1
    unset CS_STATUSLINE_LAYOUT
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "$want" "$out" "an unset layout is quiet" || return 1
}

# The line opening with one chip of mark and name, filled $1 and the name in
# ink $2 (both r;g;b), the mark in Claude's coral 217;119;87.
quiet_chip() {
    local chip="${ESC_}[0m${ESC_}[0;48;2;$1m ${ESC_}[48;2;$1;38;2;217;119;87;1m✳"
    chip+="${ESC_}[48;2;$1m ${ESC_}[48;2;$1;38;2;$2;1mmy-session"
    printf '%s' "$chip${ESC_}[48;2;$1m ${ESC_}[0m"
}

# The mark and the session name share one chip: the session colour seen
# through the background, the name in a shade of that colour. Session blue
# 106;155;204 on the dark 21;24;40 keeps 35%, 106+(21-106)*65/100 = 51, so
# 51;70;98, and the name is 60% of the way to white, 106+149*60/100 = 195, so
# 195;215;234. On cream 253;246;227 it keeps 15%, 106+147*85/100 = 230, so
# 230;232;223, and the name is halfway to black, 53;78;102. The mark stays
# Claude's coral while the attention marker would shade it on the capsules.
test_quiet_chip_holds_the_mark_and_the_session_name() {
    quiet_env
    band_session_colour blue
    touch "$CS_SESSIONS_ROOT/band-sess/.cs/local/attention"
    local out chip
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "51;70;98" "195;215;234")
    assert_eq "$chip" "${out:0:${#chip}}" "the line opens with one chip of mark and name" || return 1
    assert_output_not_contains_f "$out" "184;101;74" "the mark is not the attention shade" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "230;232;223" "53;78;102")
    assert_eq "$chip" "${out:0:${#chip}}" "on cream the chip is a pale tint, the name a dark shade" || return 1
}

# With no session colour the chip is the background's neutral step, lighter on
# a dark terminal (21;24;40 lifted to 61;64;90) and darker on a light one
# (253;246;227 less 30, 223;216;197), the name in the terminal's own ink.
test_quiet_chip_without_a_session_colour_is_neutral() {
    quiet_env
    local out chip
    out=$(run_sl "$FIXTURE_DOCS")
    chip="${ESC_}[0m${ESC_}[0;48;2;61;64;90m ${ESC_}[48;2;61;64;90;38;2;217;119;87;1m✳"
    chip+="${ESC_}[48;2;61;64;90m ${ESC_}[48;2;61;64;90;39;1mmy-session"
    assert_eq "$chip" "${out:0:${#chip}}" "the dark neutral chip" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$FIXTURE_DOCS")
    chip="${ESC_}[0m${ESC_}[0;48;2;223;216;197m ${ESC_}[48;2;223;216;197;38;2;217;119;87;1m✳"
    chip+="${ESC_}[48;2;223;216;197m ${ESC_}[48;2;223;216;197;39;1mmy-session"
    assert_eq "$chip" "${out:0:${#chip}}" "the light neutral chip" || return 1
}

# The branch is the terminal's green: its glyph and its name, the path before
# the last / the same green faint, and the marks after it in the fade of its
# run, the first after the chip, 35%: 147;153;170.
test_quiet_branch_is_the_terminal_green() {
    quiet_env
    local work json out
    work=$(make_git_work)
    git -C "$work" checkout -q -b feat/ui/chip
    json=$(jq -c --arg dir "$work" '.workspace.current_dir = $dir' <<< "$FIXTURE_DOCS")
    out=$(run_sl "$json")
    assert_output_contains_f "$out" \
        "${ESC_}[0;32m⎇ ${ESC_}[0;2;32mfeat/ui/${ESC_}[0;32mchip${ESC_}[0;38;2;147;153;170m +1!1" \
        "glyph and name green, the path faint, the marks faded" || return 1
    git -C "$work" checkout -q main
    rm -rf "$HOME/.cache/cs"
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "${ESC_}[0;32m⎇ main${ESC_}[0;38;2;147;153;170m +1!1" \
        "a name with no path is green throughout" || return 1
    git init -q --bare "$TEST_TMPDIR/origin.git"
    git -C "$work" remote add origin "$TEST_TMPDIR/origin.git"
    git -C "$work" push -q -u origin main 2>/dev/null
    git -C "$work" commit -q -m two
    rm -rf "$HOME/.cache/cs"
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "${ESC_}[0;32m⎇ main${ESC_}[0;38;2;147;153;170m↑1 !1" \
        "the ahead arrow fades with the marks" || return 1
}

# Labels and joiners fade from the quiet ink toward the background, run by
# run: a run starts at each group and at each item a dot joins. The docs
# fixture has three runs after the chip (model, ctx, limits) at 35%, 45% and
# 55%. Dark: from 214;222;240 to 21;24;40, so 214+(21-214)*35/100 = 147 and
# 147;153;170, then 128;133;150 and 108;114;130. Cream 253;246;227: the quiet
# ink is 24% of the background, 60;59;54, so 127;124;114, 146;143;131 and
# 166;161;149.
test_quiet_labels_and_joiners_fade_run_by_run() {
    quiet_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "${ESC_}[0;38;2;147;153;170m  ·  " "the first run's joiner at 35%" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;2;128;133;150m  ·  ${ESC_}[0;38;2;128;133;150m○ ctx" \
        "the second run's joiner and label at 45%" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;2;108;114;130m  ·  ${ESC_}[0;38;2;108;114;130m◷ 5h" \
        "the last run's joiner and label at 55%" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "${ESC_}[0;38;2;127;124;114m  ·  " "the first run on cream" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;2;146;143;131m  ·  ${ESC_}[0;38;2;146;143;131m○ ctx" \
        "the second run on cream" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;2;166;161;149m  ·  ${ESC_}[0;38;2;166;161;149m◷ 5h" \
        "the last run on cream" || return 1
}

# A reading is the terminal's own foreground, bold, whatever its run and
# whatever theme cs believes the terminal wears.
test_quiet_readings_are_bold_terminal_ink() {
    quiet_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "${ESC_}[0;39;1m8%" "the ctx reading" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;39;1m23%" "the 5h reading in the last run" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" "${ESC_}[0;39;1m8%" "the ctx reading on cream" || return 1
}

test_quiet_amber_reading_is_bold_amber() {
    quiet_env
    local out
    out=$(run_sl "$(band_fixture 45 23.5 41.2)")
    assert_output_contains_f "$out" "${ESC_}[0;38;2;251;191;36;1m45%" "ctx at warn is bold dark-theme amber" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$(band_fixture 45 23.5 41.2)")
    assert_output_contains_f "$out" "${ESC_}[0;38;2;180;83;9;1m45%" "ctx at warn on cream is bold amber" || return 1
}

# 5h at crit: its label and reading are one red chip, critink bold on crit, a
# fill space on each side. The chip's pad stands for one space of the dot
# joiner before it, and wk, joined by a bar, stays outside in its fade.
test_quiet_crit_reading_and_its_label_are_one_red_chip() {
    quiet_env
    local out red="${ESC_}[48;2;255;69;58;38;2;255;255;255;1m"
    out=$(run_sl "$(band_fixture 8 95 60)")
    assert_output_contains_f "$out" \
        "${ESC_}[0;38;2;108;114;130m  · ${ESC_}[0;48;2;255;69;58m ${red}◷ 5h${red} ${red}95%${ESC_}[48;2;255;69;58m ${ESC_}[0m" \
        "the 5h label and reading are one red chip" || return 1
    assert_output_contains_f "$out" \
        "${ESC_}[48;2;255;69;58m ${ESC_}[0m${ESC_}[0;38;2;108;114;130m ⋮ ${ESC_}[0;38;2;108;114;130m◶ wk${ESC_}[0m ${ESC_}[0;39;1m60%" \
        "wk follows outside the chip" || return 1
}

# ctx and 5h both at crit: two chips, the dot joiner between them single-spaced
# since each chip's pad stands for one of its spaces.
test_quiet_two_crit_groups_are_two_chips() {
    quiet_env
    local out red="${ESC_}[48;2;255;69;58;38;2;255;255;255;1m"
    out=$(run_sl "$(band_fixture 95 95 60)")
    assert_output_contains_f "$out" \
        "${red}95%${ESC_}[48;2;255;69;58m ${ESC_}[0m${ESC_}[0;38;2;108;114;130m · ${ESC_}[0;48;2;255;69;58m ${red}◷ 5h" \
        "the ctx chip closes, a single-spaced dot, the 5h chip opens" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;48;2;255;69;58m ${red}● ctx${red} ${red}95%" "ctx is a chip of its own" || return 1
}

# The model's glyph wears the effort's colour, max's first letter for max,
# and the effort word keeps its own; with no effort the glyph is the run's
# fade like the model name.
test_quiet_model_glyph_wears_the_effort_colour() {
    quiet_env
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains_f "$out" \
        "${ESC_}[0;38;2;146;158;250m✦${ESC_}[0;38;2;147;153;170m Opus${ESC_}[0m ${ESC_}[0;38;2;146;158;250mhigh" \
        "high: the glyph and the word in effort-high, the name in the fade" || return 1
    out=$(run_sl "$(jq -c '.effort.level = "max"' <<< "$FIXTURE_DOCS")")
    assert_output_contains_f "$out" \
        "${ESC_}[0;38;2;174;200;232m✦${ESC_}[0;38;2;147;153;170m Opus${ESC_}[0m ${ESC_}[0;38;2;174;200;232mm${ESC_}[0m${ESC_}[0;38;2;190;174;219ma${ESC_}[0m${ESC_}[0;38;2;219;174;206mx" \
        "max: the glyph in effort-max-1, the word letter by letter" || return 1
    out=$(run_sl "$(jq -c 'del(.effort)' <<< "$FIXTURE_DOCS")")
    assert_output_contains_f "$out" "${ESC_}[0;38;2;147;153;170m✦ Opus${ESC_}[0;38;2;128;133;150m" \
        "no effort: the glyph in the fade" || return 1
}

# Below truecolor there is no fade and no session tint: the chip is a gray,
# dark with white text on a dark terminal and light with the terminal's ink on
# a light one; labels and joiners are the secondary ink, readings the
# terminal's foreground, bold.
test_quiet_256_has_no_fade() {
    quiet_env
    unset COLORTERM
    local out
    out=$(run_sl "$(band_fixture 45 95 60)")
    assert_output_not_contains_f "$out" "38;2;" "no truecolor ink" || return 1
    assert_output_not_contains_f "$out" "48;2;" "no truecolor fill" || return 1
    assert_output_contains_f "$out" \
        "${ESC_}[0;48;5;241m ${ESC_}[48;5;241;38;5;173;1m✳${ESC_}[48;5;241m ${ESC_}[48;5;241;38;5;231;1mmy-session" \
        "the chip is a dark gray with white text" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;5;250m  ·  ${ESC_}[0;38;5;250m◑ ctx" "a label is the 256 secondary ink" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;38;5;250m ⋮ ${ESC_}[0;38;5;250m◶ wk${ESC_}[0m ${ESC_}[0;39;1m60%" \
        "the last label is the same ink, the reading the terminal's foreground" || return 1
    export CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227"
    out=$(run_sl "$(band_fixture 45 95 60)")
    assert_output_contains_f "$out" \
        "${ESC_}[0;48;5;253m ${ESC_}[48;5;253;38;5;173;1m✳${ESC_}[48;5;253m ${ESC_}[48;5;253;39;1mmy-session" \
        "on a light terminal the chip is a light gray in the terminal's ink" || return 1
}

# At basic colours quiet draws on the terminal's own background, where the
# capsules' white inks vanish on a light theme: its labels are bright black
# and its readings the terminal's own foreground, on either theme.
test_quiet_basic_inks_read_on_the_terminal() {
    quiet_env
    unset COLORTERM
    export TERM=xterm CS_TERM_THEME=light CS_TERM_BG_RGB="252;247;229"
    local out
    out=$(run_sl "$(band_fixture 8 23.5 41.2)")
    assert_output_not_contains_f "$out" "${ESC_}[0;37m" "no white label on a light terminal" || return 1
    assert_output_not_contains_f "$out" "${ESC_}[0;97" "no bright white reading on a light terminal" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;90m  ·  ${ESC_}[0;90m○ ctx${ESC_}[0m ${ESC_}[0;39;1m8%" \
        "a label in bright black, the reading in the terminal's foreground, bold" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;47m ${ESC_}[47;33;1m✳${ESC_}[47m ${ESC_}[47;39;1mmy-session" \
        "the chip is white with the terminal's ink" || return 1
    export CS_TERM_THEME=dark CS_TERM_BG_RGB="21;24;40"
    out=$(run_sl "$(band_fixture 8 23.5 41.2)")
    assert_output_contains_f "$out" "${ESC_}[0;90m  ·  ${ESC_}[0;90m○ ctx${ESC_}[0m ${ESC_}[0;39;1m8%" \
        "the same inks on a dark terminal" || return 1
    assert_output_contains_f "$out" "${ESC_}[0;100m ${ESC_}[100;33;1m✳${ESC_}[100m ${ESC_}[100;97;1mmy-session" \
        "on a dark terminal the chip is bright black with bright white text" || return 1
}

test_quiet_plain_level_prints_the_plain_line() {
    quiet_env
    export NO_COLOR=1
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "my-session · ✦ Opus high > ○ ctx 8% > ◷ 5h 23%" "$out" "plain prints the plain line" || return 1
    assert_eq "$(CS_STATUSLINE_LAYOUT=capsules run_sl "$FIXTURE_DOCS")" "$out" "plain ignores the layout" || return 1
}

# The iTerm tests write real preferences with PlistBuddy, which only macOS has.
iterm_tool() {
    [ -x /usr/libexec/PlistBuddy ] && return 0
    echo "    SKIP: /usr/libexec/PlistBuddy missing"
    SKIP_REASON="/usr/libexec/PlistBuddy missing"
    return 77
}

# Add background colour $3 (r;g;b) at key path $2 of preferences file $1, each
# component a fraction of 255 the way iTerm stores it.
iterm_colour() {
    local r g b
    IFS=';' read -r r g b <<< "$3"
    /usr/libexec/PlistBuddy -c "Add '$2' dict" \
        -c "Add '$2:Red Component' real $(awk -v v="$r" 'BEGIN { printf "%.6f", v / 255 }')" \
        -c "Add '$2:Green Component' real $(awk -v v="$g" 'BEGIN { printf "%.6f", v / 255 }')" \
        -c "Add '$2:Blue Component' real $(awk -v v="$b" 'BEGIN { printf "%.6f", v / 255 }')" \
        "$1" >/dev/null
}

# Write iTerm's preferences under the test HOME: $1 other profiles, then the
# profile named $2 with background $3, or with separate dark $3 and light $4.
iterm_prefs() {
    local f="$HOME/Library/Preferences/com.googlecode.iterm2.plist" i p=":New Bookmarks:$1"
    mkdir -p "$HOME/Library/Preferences"
    /usr/libexec/PlistBuddy -c "Add ':New Bookmarks' array" "$f" >/dev/null
    for ((i = 0; i < $1; i++)); do
        /usr/libexec/PlistBuddy -c "Add ':New Bookmarks:$i' dict" \
            -c "Add ':New Bookmarks:$i:Name' string other-$i" "$f" >/dev/null
    done
    /usr/libexec/PlistBuddy -c "Add '$p' dict" -c "Add '$p:Name' string $2" "$f" >/dev/null
    if [ -n "${4:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add '$p:Use Separate Colors for Light and Dark Mode' bool true" "$f" >/dev/null
        iterm_colour "$f" "$p:Background Color (Dark)" "$3"
        iterm_colour "$f" "$p:Background Color (Light)" "$4"
    else
        iterm_colour "$f" "$p:Background Color" "$3"
    fi
}

# A local iTerm pane on profile Work that cs launched on cream, so the launch
# theme is a measured light, with macOS in appearance $1 as of the clock.
iterm_env() {
    quiet_env
    export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1 CS_TERM_BG_RGB="253;246;227" \
        ITERM_PROFILE=Work LC_TERMINAL=iTerm2 CS_STATUSLINE_NOW=1000
    mkdir -p "$HOME/.cache/cs/macos-appearance"
    printf '1000\tglobal\n%s\n' "$1" > "$HOME/.cache/cs/macos-appearance/global"
}

# In iTerm the theme and the background come from the pane's profile, read
# live, so a dark-mode switch after launch reaches the line. A profile with
# separate light and dark colours follows macOS: in dark mode the chip is the
# dark one over the profile's 21;24;40 (as in the chip test), in light mode
# session blue keeps 15% over the profile's white, 106+149*85/100 = 232, so
# 232;240;247. The profile sits 65th, past eight batches of names.
test_quiet_follows_the_iterm_profile_across_appearances() {
    iterm_tool || return $?
    iterm_env dark
    band_session_colour blue
    iterm_prefs 64 Work "21;24;40" "255;255;255"
    local out chip
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "51;70;98" "195;215;234")
    assert_eq "$chip" "${out:0:${#chip}}" "macOS dark: the dark chip over the profile's dark background" || return 1
    printf '1000\tglobal\nlight\n' > "$HOME/.cache/cs/macos-appearance/global"
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "232;240;247" "53;78;102")
    assert_eq "$chip" "${out:0:${#chip}}" "macOS light: the light chip over the profile's light background" || return 1
}

# A profile with one background is light or dark by that background: navy is
# dark although cs measured cream at launch and macOS is light. A component
# below zero, as a colour outside the profile's colour space stores it, reads
# as 0: red -0.2 makes the background 0;24;40, so blue keeps 35% over it,
# 106+(0-106)*65/100 = 38, so 38;70;98. A mid tone is split at the launch's
# BT.709 line: 140;120;140 is dark there (1256960 < 1275000), so blue keeps
# 35% over it, 106+(140-106)*65/100 = 128, so 128;133;163.
test_quiet_iterm_single_background_sets_the_theme() {
    iterm_tool || return $?
    iterm_env light
    band_session_colour blue
    iterm_prefs 0 Work "21;24;40"
    local out chip
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "51;70;98" "195;215;234")
    assert_eq "$chip" "${out:0:${#chip}}" "the dark chip over the profile's navy" || return 1
    rm -rf "$HOME/Library/Preferences/com.googlecode.iterm2.plist" "$HOME/.cache/cs/iterm-profile"
    iterm_prefs 0 Work "-51;24;40"
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "38;70;98" "195;215;234")
    assert_eq "$chip" "${out:0:${#chip}}" "a component below zero reads as 0" || return 1
    rm -rf "$HOME/Library/Preferences/com.googlecode.iterm2.plist" "$HOME/.cache/cs/iterm-profile"
    iterm_prefs 0 Work "140;120;140"
    out=$(run_sl "$FIXTURE_DOCS")
    chip=$(quiet_chip "128;133;163" "195;215;234")
    assert_eq "$chip" "${out:0:${#chip}}" "a mid tone is dark by the launch's luminance line" || return 1
}

# The profile is not read over ssh, where the preferences on disk are not the
# terminal's, nor with CS_NO_ITERM2 set, and a profile missing from the
# preferences reads as nothing: the launch theme and background stand. So does
# a profile behind a nameless one, rather than the nameless one's colours
# (white, which would draw 232;240;247). A background set by hand outranks the
# profile's, under the profile's theme, whether or not a launch detected the
# theme beside it: 106+(30-106)*65/100 = 57, so 57;74;91.
test_quiet_iterm_profile_stands_down() {
    iterm_tool || return $?
    iterm_env dark
    band_session_colour blue
    iterm_prefs 1 Work "21;24;40" "253;246;227"
    local out light chip f="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
    light=$(quiet_chip "230;232;223" "53;78;102")
    out=$(SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22" run_sl "$FIXTURE_DOCS")
    assert_eq "$light" "${out:0:${#light}}" "over ssh the launch theme stands" || return 1
    out=$(CS_NO_ITERM2=1 run_sl "$FIXTURE_DOCS")
    assert_eq "$light" "${out:0:${#light}}" "CS_NO_ITERM2 keeps the launch theme" || return 1
    out=$(ITERM_PROFILE=Elsewhere run_sl "$FIXTURE_DOCS")
    assert_eq "$light" "${out:0:${#light}}" "a profile not in the preferences keeps the launch theme" || return 1
    chip=$(quiet_chip "57;74;91" "195;215;234")
    out=$(CS_TERM_THEME="" CS_TERM_THEME_AUTO="" CS_TERM_BG_RGB="30;30;30" run_sl "$FIXTURE_DOCS")
    assert_eq "$chip" "${out:0:${#chip}}" "a background set by hand outranks the profile's" || return 1
    out=$(CS_TERM_BG_RGB="30;30;30" CS_TERM_BG_RGB_PINNED=1 run_sl "$FIXTURE_DOCS")
    assert_eq "$chip" "${out:0:${#chip}}" "so does one set before a launch that detected the theme" || return 1
    /usr/libexec/PlistBuddy -c "Delete ':New Bookmarks:0:Name'" "$f" >/dev/null
    iterm_colour "$f" ":New Bookmarks:0:Background Color" "255;255;255"
    rm -rf "$HOME/.cache/cs/iterm-profile"
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "$light" "${out:0:${#light}}" "a profile behind a nameless one keeps the launch theme" || return 1
}

# Inside tmux the pane's ITERM_PROFILE is the one it was started with, so the
# profile answers only while the attached client is iTerm2: in control mode,
# iTerm's tmux integration, or of a terminal type tmux reports as iTerm2. A
# client tmux knows as another terminal leaves the rung to the ones after it.
test_quiet_iterm_profile_inside_tmux_needs_an_iterm_client() {
    iterm_tool || return $?
    iterm_prefs 0 Work "21;24;40"
    ( export ITERM_PROFILE=Work LC_TERMINAL=iTerm2 TMUX="/tmp/fake,1,0"
      _load_sl_functions
      tmux() { printf '\t/dev/ttys002\t80\t0\tghostty 1.2.0\n'; }
      if _sl_theme_from_iterm; then
          echo "    FAIL: another terminal attached, yet the profile answered"; return 1
      fi
      rm -rf "$HOME/.cache/cs/tmux-client3"; _TMUX_CLIENT_ASKED=""
      tmux() { printf '\t/dev/ttys002\t80\t1\t\n'; }
      _sl_theme_from_iterm || { echo "    FAIL: iTerm's tmux integration attached, yet the profile did not answer"; return 1; }
      assert_eq "dark 21;24;40" "$SL_THEME $_SL_LIVE_BG" "the profile answers in control mode" || return 1
      rm -rf "$HOME/.cache/cs/tmux-client3"; _TMUX_CLIENT_ASKED=""; SL_THEME=""; _SL_LIVE_BG=""
      tmux() { printf '\t/dev/ttys002\t80\t0\tiTerm2 3.5.0\n'; }
      _sl_theme_from_iterm || { echo "    FAIL: an iTerm2 client attached, yet the profile did not answer"; return 1; }
      assert_eq "dark 21;24;40" "$SL_THEME $_SL_LIVE_BG" "the profile answers for an iTerm2 client" || return 1 )
}

run_test test_layout_unset_empty_or_unknown_is_quiet
run_test test_quiet_chip_holds_the_mark_and_the_session_name
run_test test_quiet_chip_without_a_session_colour_is_neutral
run_test test_quiet_branch_is_the_terminal_green
run_test test_quiet_labels_and_joiners_fade_run_by_run
run_test test_quiet_readings_are_bold_terminal_ink
run_test test_quiet_amber_reading_is_bold_amber
run_test test_quiet_crit_reading_and_its_label_are_one_red_chip
run_test test_quiet_two_crit_groups_are_two_chips
run_test test_quiet_model_glyph_wears_the_effort_colour
run_test test_quiet_256_has_no_fade
run_test test_quiet_basic_inks_read_on_the_terminal
run_test test_quiet_plain_level_prints_the_plain_line
run_test test_quiet_follows_the_iterm_profile_across_appearances
run_test test_quiet_iterm_single_background_sets_the_theme
run_test test_quiet_iterm_profile_stands_down
run_test test_quiet_iterm_profile_inside_tmux_needs_an_iterm_client

report_results
