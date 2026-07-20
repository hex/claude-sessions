#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-statusline, the Claude Code squared-pill statusline
# ABOUTME: Covers segment rendering, ordering, thresholds, color ladder, and defensive fallbacks

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SL="$SCRIPT_DIR/../bin/cs-statusline"
CS_BIN="${CS_BIN:-$SCRIPT_DIR/../bin/cs}"

# The docs' example statusline JSON, verbatim values (session_name "my-session",
# ctx 8%, Opus/high, 5h 23.5, wk 41.2, cost 0.01234, non-git current_dir).
FIXTURE_DOCS='{"cwd":"/current/working/directory","session_id":"abc123","session_name":"my-session","model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"/current/working/directory","project_dir":"/orig"},"cost":{"total_cost_usd":0.01234},"context_window":{"used_percentage":8},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}'

# --- Setup / teardown: isolate from ambient cs/Claude env and terminal vars ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR|TMUX|TMUX_PANE)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    # COLUMNS drives the full-width gradient; unset so tests never inherit
    # whatever width the ambient terminal running the suite happens to have.
    unset COLUMNS 2>/dev/null || true
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    # Neutral terminal by default; per-test overrides as needed.
    export TERM="xterm-256color"
    # Pin the theme so render tests are deterministic regardless of the runner's
    # OS appearance: _sl_detect_theme now reads the live macOS appearance when
    # CS_TERM_THEME is unset, which setup() strips above. The theme-resolution
    # tests unset this in their own subshells to exercise the live path.
    export CS_TERM_THEME="light"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_SESSION_NAME NO_COLOR COLORTERM TERM_PROGRAM \
        FORCE_COLOR CS_STATUSLINE_DISABLE CS_STATUSLINE_SEGMENTS CS_STATUSLINE_CTX_WARN \
        CS_STATUSLINE_CTX_CRIT CS_DISCOVERIES_MAX_SIZE COLUMNS CS_TERM_BG_RGB \
        TMUX TMUX_PANE 2>/dev/null || true
}

# --- Helpers ---

# Run the statusline with $1 as stdin JSON; prints its stdout.
run_sl() {
    printf '%s' "$1" | bash "$SL"
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
    # git absent (non-git dir) and disc absent (no cs session).
    assert_eq "my-session > ✦ Opus high > ◔ ctx 8% > ◷ 5h 23% > ◑ wk 41% > \$0.01" "$out" \
        "docs fixture should render identity first, then gauges (no badge in plain mode)"
}

# ============================================================================
# All six segments render in order with git present (plain)
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
        rate_limits:{five_hour:{used_percentage:23.5},seven_day:{used_percentage:41.2}},
        cost:{total_cost_usd:1.23}
    }')
    local out
    out=$(run_sl "$json")
    assert_eq "mysess > ⎇ main +1!1 > ✦ Opus high > ◔ ctx 34% > ◷ 5h 23% > ◑ wk 41% > \$1.23" "$out" \
        "all segments should render in order: session, branch, model, then gauges (no badge in plain mode)"
}

# ============================================================================
# Limits render quietly when healthy: grey blocks, no accent colors
# ============================================================================

test_limits_neutral_when_healthy() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":41}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 23%" "5h block should render" || return 1
    assert_output_contains "$out" "wk 41%" "wk block should render" || return 1
    assert_output_not_contains "$out" "48;2;138;134;236" "healthy limits must not take the accent periwinkle" || return 1
    assert_output_not_contains "$out" "48;2;255;183;77" "healthy limits must not show amber" || return 1
}

# ============================================================================
# Two accents by default: session color and model; every other healthy
# segment is quiet grey
# ============================================================================

test_two_accents_default() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="accents"
    make_cs_session "accents" 30720 cyan
    local json='{"session_name":"accents","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"cost":{"total_cost_usd":1.0},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":40}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;8;145;178" "session block should carry the session color (cyan)" || return 1
    assert_output_contains "$out" "48;2;138;134;236;38;2;240;242;255" "model should be the usage-chip periwinkle with the chip's text color" || return 1
    local greys
    greys=$(printf '%s' "$out" | grep -o '48;2;128;120;110' | grep -c . ) || greys=0
    if [ "$greys" -lt 4 ]; then
        echo "  FAIL: expected ctx, git-less run, 5h, wk, cost on grey (got $greys grey blocks)"
        return 1
    fi
}

# ============================================================================
# The branch pill is a bold slate-blue accent, ordered before the model
# ============================================================================

test_git_branch_bold_slate_accent() {
    export COLORTERM=truecolor
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
    assert_output_contains "$out" "48;2;79;91;140;38;2;240;242;255;1" \
        "branch should render bold in slate-blue with the chip text color" || return 1
    # Branch sits before the model: the slate branch bg appears earlier in the
    # output stream than the periwinkle model bg.
    local slate_pos peri_pos
    slate_pos=$(printf '%s' "$out" | grep -bo '48;2;79;91;140' | head -1 | cut -d: -f1)
    peri_pos=$(printf '%s' "$out" | grep -bo '48;2;138;134;236' | head -1 | cut -d: -f1)
    [ -n "$slate_pos" ] && [ -n "$peri_pos" ] && [ "$slate_pos" -lt "$peri_pos" ] || {
        echo "  FAIL: branch (slate@$slate_pos) should appear before model (periwinkle@$peri_pos)"
        return 1
    }
}

# ============================================================================
# Limits thresholds escalate per block: healthy 5h stays periwinkle, hot wk red
# ============================================================================

test_limits_threshold_per_block() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;220;38;38" "wk 95% block should go red" || return 1
    assert_output_not_contains "$out" "48;2;255;183;77" "healthy 5h block must not show amber" || return 1
}

# ============================================================================
# Squared pills: same-bg neighbors join with a faint bar, and
# differing-bg neighbors abut so the color change itself is the divider
# ============================================================================

test_thin_bar_between_same_bg() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="250;248;242"
    # Two healthy gauges share the bg-derived surface: ctx next to a 5h block,
    # both the surface shade (segment order trimmed so the two are neighbors).
    # They are split by a thin one-eighth bar inked in a faint shade of that
    # surface — a discreet tonal step, not a wide gap and not a foreign grey.
    export CS_STATUSLINE_SEGMENTS="ctx,limits"
    local json='{"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10},"rate_limits":{"five_hour":{"used_percentage":20}}}'
    local out surface ink
    surface=$( ( _load_sl_functions; _bg_shade "250;248;242"; echo "$_R;$_G;$_B" ) )
    ink=$( ( _load_sl_functions; _bg_shade "$surface"; echo "$_R;$_G;$_B" ) )
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;${surface};38;2;${ink}m▏" \
        "same-surface neighbors should join with a thin bar inked in a faint shade of the surface" || return 1
}

test_abut_between_different_bg() {
    export COLORTERM=truecolor
    # session grey then the periwinkle model accent (logo excluded — it always
    # gets its own hairline, tested separately below): differing neighbors
    # abut squarely, with no divider glyph — the color change is the boundary.
    export CS_STATUSLINE_SEGMENTS="session,model"
    local json='{"session_name":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "▏" "no faint bar between differing backgrounds" || return 1
}

test_logo_badge_is_brand_coral() {
    export COLORTERM=truecolor
    # The bar opens with a brand badge: the Claude mark on the Claude-coral bg.
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "✳" "logo badge glyph should render" || return 1
    assert_output_contains "$out" "48;2;217;119;87" "logo badge should sit on the Claude-coral background" || return 1
}

# Claude Code's TUI parses the statusline ANSI and re-emits only bold/fg/bg,
# so terminal blink (SGR 5) can never reach the screen. The pulse is instead
# software-driven: while the attention marker exists the mark's foreground
# alternates chiptext/brandshade by epoch-second parity, and the statusLine
# registration's refreshInterval repaints the bar every second while idle so
# the phase keeps advancing. CS_STATUSLINE_NOW pins the clock for tests.
test_logo_pulses_bright_phase_with_attention_marker() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="blinksess"
    make_cs_session "blinksess" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/blinksess/.cs/local"
    touch "$CS_SESSIONS_ROOT/blinksess/.cs/local/attention"
    local json='{"session_name":"blinksess","workspace":{"current_dir":"/none"}}'
    local out
    out=$(CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains "$out" '240;242;255;1m ✳' \
        "even-second phase should render the mark in chiptext" || return 1
}

test_logo_pulses_dim_phase_with_attention_marker() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="blinksess"
    make_cs_session "blinksess" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/blinksess/.cs/local"
    touch "$CS_SESSIONS_ROOT/blinksess/.cs/local/attention"
    local json='{"session_name":"blinksess","workspace":{"current_dir":"/none"}}'
    local out
    out=$(CS_STATUSLINE_NOW=1001 run_sl "$json")
    assert_output_contains "$out" '184;101;74;1m ✳' \
        "odd-second phase should dim the mark to brandshade" || return 1
}

test_logo_steady_without_attention_marker() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="steadysess"
    make_cs_session "steadysess" 1024 blue
    local json='{"session_name":"steadysess","workspace":{"current_dir":"/none"}}'
    local out
    out=$(CS_STATUSLINE_NOW=1001 run_sl "$json")
    assert_output_contains "$out" '240;242;255;1m ✳' \
        "without the marker the mark stays chiptext on every phase" || return 1
}

test_logo_boundary_gets_thin_darker_coral_hairline() {
    export COLORTERM=truecolor
    # The logo (coral) and a blue session pill are visibly different colors,
    # but the logo is a fixed brand mark, so its boundary always gets a
    # divider. It works exactly like every other hairline in the bar: a
    # `▏` (U+258F) glyph, which inks only its LEFT ~1/8 with the foreground
    # color and shows the cell BACKGROUND in the other ~7/8. The one thing
    # that makes any hairline read as *thin* is that its background matches a
    # neighbor, so 7/8 of the cell disappears into that pill and only the 1/8
    # ink sliver is visible. Here the non-logo neighbor is the session pill,
    # so the divider's background is the session color (blue) and the ink is
    # the darker coral. Every earlier attempt gave the cell a distinct
    # background (bright coral, darker coral, grey, black), which made the
    # whole one-column cell read as a solid block, not a thin line.
    export CLAUDE_SESSION_NAME="s"
    make_cs_session "s" 1024 blue
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;106;155;204;38;2;184;101;74m▏" \
        "the divider background should be the session color with a thin darker-coral ink sliver" || return 1
    assert_output_not_contains "$out" "48;2;184;101;74" \
        "the darker coral must never be a background (that is the full-width block bug), only the thin ink" || return 1
    assert_output_not_contains "$out" "38;2;30;30;30m▏" "the logo boundary must not use near-black" || return 1
    assert_output_not_contains "$out" "38;2;170;161;148m▏" "the logo boundary must not use the light hairline grey" || return 1
}

test_segment_after_logo_divider_drops_redundant_leading_pad() {
    export COLORTERM=truecolor
    # The logo divider is a full cell painted in the session's background, so
    # the session pill's own leading pad space would stack a second
    # session-colored cell to the left of the name — making it sit one column
    # right of centre while every other pill is symmetric. The divider cell IS
    # the leading pad, so the name must start immediately after it: the session
    # SGR is followed directly by the name character, never by a space.
    export CLAUDE_SESSION_NAME="s"
    make_cs_session "s" 1024 blue
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;106;155;204;38;2;240;242;255;1ms" \
        "the session name must start immediately after the logo divider (no redundant leading pad)" || return 1
    assert_output_not_contains "$out" "48;2;106;155;204;38;2;240;242;255;1m s" \
        "the session pill after the logo divider must not add its own leading pad space" || return 1
}

test_logo_divider_survives_orange_session_color_collision() {
    export COLORTERM=truecolor
    # The "orange" session color and the logo's "brand" color share the exact
    # same RGB (217;119;87). The divider background is the session's color
    # (bright coral here), so its 7/8 merges into the orange session pill; the
    # thin darker-coral ink sliver is still visibly distinct from both, so the
    # logo and an identically-colored session never merge into one block.
    export CLAUDE_SESSION_NAME="s"
    make_cs_session "s" 1024 orange
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;217;119;87;38;2;184;101;74m▏" "logo and an orange session pill must still show a visible ink sliver" || return 1
}

# ============================================================================
# Segment icons are standard Unicode (render in any monospace font)
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
        rate_limits:{five_hour:{used_percentage:23},seven_day:{used_percentage:41}}
    }')
    local out branch_glyph clock_glyph
    out=$(run_sl "$json")
    branch_glyph=$'\xe2\x8e\x87'   # U+2387 branch
    clock_glyph=$'\xe2\x97\xb7'    # U+25F7 clock
    assert_output_contains "$out" "$branch_glyph" "git segment should carry the branch icon" || return 1
    assert_output_contains "$out" "$clock_glyph" "5h segment should carry the clock icon" || return 1
}

test_tab_color_palette_matches_statusline() {
    # The tab color (bin/cs _session_color_rgb, comma form) must equal the
    # statusline session palette (cs-statusline truecolor rgb, semicolon form)
    # for all 8 names, or the tab and the session block drift apart.
    local c sl cs
    for c in red blue green yellow purple orange pink cyan; do
        sl=$(grep -E "^[[:space:]]*$c\)[[:space:]]*rgb=" "$SL" | grep -oE '[0-9]+;[0-9]+;[0-9]+' | tr ';' ',')
        cs=$(grep -E "$c\).*echo \"[0-9]+,[0-9]+,[0-9]+\"" "$CS_BIN" | grep -oE '[0-9]+,[0-9]+,[0-9]+')
        assert_eq "$sl" "$cs" "tab color RGB for '$c' must match the statusline palette" || return 1
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
    assert_output_not_contains "$out" "$arrow" "squared pills must not use the powerline arrow" || return 1
    assert_output_not_contains "$out" "$chevron" "squared pills must not use the powerline chevron" || return 1
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

test_detect_theme_unknown_without_signals() {
    local out
    out=$(env -u COLORFGBG -u TMUX "$CS_BIN" -detect-theme 2>&1 < /dev/null)
    assert_output_contains "$out" "unknown" "no COLORFGBG and no tty should classify as unknown" || return 1
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
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;140;132;122" "dark theme should lift the neutral grey" || return 1
    assert_output_contains "$out" "38;2;230;230;230" "dark theme should soften white text" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110" "dark theme must not use the light-theme grey" || return 1
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
        rate_limits:{five_hour:{used_percentage:23,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 23% · 2h14m" "5h block should append time until reset"
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
        return 0
    fi
    local now reset_at
    now=$(date +%s)   # not the %(%s)T builtin: empty under the bash 3.2 that runs this suite on macOS
    reset_at=$(( now + 2 * 3600 + 14 * 60 + 30 ))   # 2h14m30s out -> "2h14m"
    local json
    json=$(jq -nc --argjson r "$reset_at" '{
        session_name:"s",
        workspace:{current_dir:"/none"},
        rate_limits:{five_hour:{used_percentage:23,resets_at:$r}}
    }')
    local out
    out=$(printf '%s' "$json" | "$old_bash" "$SL")
    assert_output_contains "$out" "5h 23% · 2h14m" "reset countdown must render under bash <4.2 via date fallback"
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
        rate_limits:{five_hour:{used_percentage:50,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 50% · 45m" "5h block should show minutes-only rest time under an hour" || return 1
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
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 23%" "5h percentage should render" || return 1
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
        rate_limits:{five_hour:{used_percentage:5,resets_at:$r}}
    }')
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "5h 5%" "5h percentage should still render" || return 1
    assert_output_not_contains "$out" "·" "no reset separator when the window already reset"
}

# ============================================================================
# Missing session_name outside a cs session -> basename of current_dir
# ============================================================================

test_missing_session_name_dir_fallback() {
    export NO_COLOR=1
    local json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/alpha/beta"},"context_window":{"used_percentage":5}}'
    local out
    out=$(run_sl "$json")
    assert_eq "beta > ✦ Opus > ◔ ctx 5%" "$out" \
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
    if printf '%s' "$out" | grep -q $'\033'; then
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
    if printf '%s' "$out" | grep -q $'\033'; then
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
    assert_eq "s > ✦ Opus > ◔ ctx 5%" "$out" \
        "git segment should be absent for a non-git workspace"
}

# ============================================================================
# Threshold colors: ctx >= crit renders red; healthy renders neutral grey
# ============================================================================

test_ctx_threshold_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":84}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "220;38;38" "ctx 84% should use the red background rgb"
    if ! printf '%s' "$out" | grep -qF "$(printf '\033[0m')"; then
        echo "  FAIL: colored line must contain a reset"
        return 1
    fi
}

test_ctx_normal_neutral_not_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "0;135;0" "healthy ctx must not shout green" || return 1
    assert_output_not_contains "$out" "220;38;38" "ctx 8% must not use red" || return 1
}

test_model_neutral_not_blue() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "Opus" "model segment should render" || return 1
    assert_output_not_contains "$out" "0;95;175" "model segment must not use the blue background" || return 1
}

test_white_text_on_periwinkle() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;138;134;236;38;2;240;242;255" \
        "the periwinkle model accent carries the chip's text color rgb(240,242,255)" || return 1
}

test_accent_segments_bold() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="boldsess"
    make_cs_session "boldsess" 1000 cyan
    local json='{"session_name":"boldsess","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;8;145;178;38;2;240;242;255;1" \
        "the session accent should render bold in the chip text color" || return 1
    assert_output_contains "$out" "48;2;138;134;236;38;2;240;242;255;1" \
        "the model accent should render bold in the chip text color" || return 1
    # SGR bold is stateful: a segment that does not explicitly emit normal
    # intensity (22) inherits bold from the accent before it.
    assert_output_contains "$out" "48;2;128;120;110;38;2;255;255;255;22" \
        "grey segments must explicitly reset to normal intensity" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110;38;2;255;255;255;1m" \
        "grey segments must not render bold" || return 1
}

test_dark_text_on_amber_warn() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":55}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;255;183;77;38;2;30;30;30" \
        "warn blocks should be warm amber with dark text" || return 1
}

# ============================================================================
# Limits threshold: max(5h,wk) >= crit renders red
# ============================================================================

test_limits_threshold_red() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "220;38;38" "wk 95% should drive the limits bg red"
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
    # session bg = grey -> basic bg code 100, text fg white -> 97; the
    # session accent carries bold (1), plain segments normal intensity (22)
    assert_output_contains "$out" "100;97;1m" "basic level should emit 8/16-color SGR codes with accent bold"
    assert_output_contains "$out" "100;97;22m" "basic level plain segments should reset to normal intensity"
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
    if printf '%s' "$out" | grep -q $'\033'; then
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
    if printf '%s' "$out" | grep -q $'\033'; then
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
    assert_eq "s > ◔ ctx 0%" "$(run_sl "$with0")" "ctx 0% should render explicitly"
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
    assert_eq "s > ✦ Opus" "$(run_sl "$json")" "unknown segment tokens should be skipped"
}

# ============================================================================
# A session color name outside the table falls back to neutral grey, no crash
# ============================================================================

test_unknown_session_color_falls_back() {
    export COLORTERM="truecolor"
    export CLAUDE_SESSION_NAME="weird"
    make_cs_session "weird" 1024 chartreuse   # not one of the 8 valid color names
    local json='{"session_name":"weird","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":5}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;128;120;110" \
        "unknown session color should fall back to neutral grey"
}

# ============================================================================
# Full-width gradient: display-width counting, RGB lerp, and the fade itself
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

test_lerp_channel_hits_exact_endpoints() {
    ( _load_sl_functions
      _lerp_channel 20 200 0 8
      assert_eq "20" "$_LC" "the first cell (i=0) must equal the source channel exactly" || exit 1
      _lerp_channel 20 200 7 8
      assert_eq "200" "$_LC" "the last cell (i=steps-1) must equal the destination channel exactly" || exit 1
      _lerp_channel 20 200 0 1
      assert_eq "200" "$_LC" "a single-cell gradient should jump straight to the destination" )
}

test_build_gradient_cell_count_and_endpoints() {
    ( _load_sl_functions
      _build_gradient "128;120;110" "250;248;242" 4
      local count
      count=$(printf '%s' "$_GRADIENT" | grep -o '48;2;' | grep -c .)
      assert_eq "4" "$count" "requesting 4 cells should emit exactly 4 background SGRs" || exit 1
      assert_output_contains "$_GRADIENT" "48;2;128;120;110" "the gradient should start at the source color" || exit 1
      assert_output_contains "$_GRADIENT" "48;2;250;248;242" "the gradient should end at the destination color" )
}

test_build_gradient_noop_on_malformed_target() {
    ( _load_sl_functions
      _build_gradient "128;120;110" "not-a-color" 10
      assert_eq "" "$_GRADIENT" "a malformed destination should produce no gradient at all" )
}

test_full_width_gradient_reaches_columns() {
    export COLORTERM=truecolor
    export COLUMNS=80
    export CS_TERM_BG_RGB="250;248;242"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":5}}'
    local out stripped width
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;250;248;242" \
        "a wide terminal with a known bg should render a gradient reaching that color" || return 1
    stripped=$(printf '%s' "$out" | sed -E $'s/\033\\[[0-9;]*m//g')
    width=$( ( _load_sl_functions; _display_width "$stripped"; echo "$_WIDTH" ) )
    assert_eq "80" "$width" "the bar plus its gradient should fill exactly COLUMNS cells"
}

test_narrow_terminal_no_gradient() {
    export COLORTERM=truecolor
    export COLUMNS=5
    export CS_TERM_BG_RGB="250;248;242"
    local json='{"session_name":"averylongsessionnamethatfillsthebar","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "48;2;250;248;242" \
        "a bar already wider than COLUMNS should add no gradient" || return 1
}

test_no_gradient_without_columns() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="250;248;242"
    unset COLUMNS
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "48;2;250;248;242" \
        "no gradient should render when COLUMNS is unknown" || return 1
}

test_no_gradient_without_bg_rgb() {
    export COLORTERM=truecolor
    unset CS_TERM_BG_RGB
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out_unset out_wide
    out_unset=$(run_sl "$json")
    out_wide=$(COLUMNS=80 run_sl "$json")
    assert_eq "$out_unset" "$out_wide" \
        "COLUMNS must have no effect on rendering when CS_TERM_BG_RGB is unknown" || return 1
}

test_no_gradient_outside_truecolor() {
    export TERM="xterm-256color"
    unset COLORTERM
    export COLUMNS=80
    export CS_TERM_BG_RGB="250;248;242"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_not_contains "$out" "48;2;250;248;242" \
        "256-color/basic modes should not attempt a truecolor gradient" || return 1
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
    # A colored session so the only thing that could show the fixed grey is a
    # gauge wrongly ignoring the derived surface.
    export CLAUDE_SESSION_NAME="s"
    make_cs_session "s" 1024 red
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10}}'
    local out surface sr sg sb tr tg tb
    surface=$( ( _load_sl_functions; _bg_shade "250;248;242"; echo "$_R;$_G;$_B" ) )
    IFS=';' read -r sr sg sb <<< "$surface"
    tr=$((sr * 35 / 100)); tg=$((sg * 35 / 100)); tb=$((sb * 35 / 100))
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;${surface};38;2;${tr};${tg};${tb}" \
        "a healthy gauge should render on the bg-derived surface with softened tonal text" || return 1
    assert_output_not_contains "$out" "48;2;128;120;110" \
        "a gauge with a known background must not use the fixed grey" || return 1
}

test_gauge_falls_back_to_grey_without_bg() {
    export COLORTERM=truecolor CS_TERM_THEME=light
    unset CS_TERM_BG_RGB
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":10}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;128;120;110;38;2;255;255;255" \
        "with no known background a gauge falls back to the warm neutral grey with light text" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_statusline.sh"
echo ""
run_test test_happy_path_docs_fixture_plain
run_test test_all_segments_ordering_plain
run_test test_limits_neutral_when_healthy
run_test test_two_accents_default
run_test test_git_branch_bold_slate_accent
run_test test_limits_threshold_per_block
run_test test_thin_bar_between_same_bg
run_test test_bg_shade_darkens_light_background
run_test test_bg_shade_lightens_dark_background
run_test test_bg_shade_noop_on_malformed
run_test test_gauge_uses_bg_derived_surface
run_test test_gauge_falls_back_to_grey_without_bg
run_test test_logo_badge_is_brand_coral
run_test test_logo_pulses_bright_phase_with_attention_marker
run_test test_logo_pulses_dim_phase_with_attention_marker
run_test test_logo_steady_without_attention_marker
run_test test_logo_boundary_gets_thin_darker_coral_hairline
run_test test_segment_after_logo_divider_drops_redundant_leading_pad
run_test test_logo_divider_survives_orange_session_color_collision
run_test test_abut_between_different_bg
run_test test_segment_icons_are_unicode
run_test test_tab_color_palette_matches_statusline
run_test test_no_powerline_arrow
run_test test_detect_theme_colorfgbg_dark
run_test test_detect_theme_colorfgbg_light
run_test test_detect_theme_konsole_three_part
run_test test_detect_theme_unknown_without_signals
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
run_test test_missing_session_name_dir_fallback
run_test test_no_color_emits_no_escapes
run_test test_disable_prints_nothing
run_test test_malformed_stdin_fallback
run_test test_non_git_workspace_absent
run_test test_ctx_threshold_red
run_test test_ctx_normal_neutral_not_red
run_test test_model_neutral_not_blue
run_test test_white_text_on_periwinkle
run_test test_accent_segments_bold
run_test test_dark_text_on_amber_warn
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
run_test test_unknown_session_color_falls_back
run_test test_display_width_counts_codepoints_not_bytes
run_test test_parse_rgb_triplet_accepts_valid_and_rejects_malformed
run_test test_lerp_channel_hits_exact_endpoints
run_test test_build_gradient_cell_count_and_endpoints
run_test test_build_gradient_noop_on_malformed_target
run_test test_full_width_gradient_reaches_columns
run_test test_narrow_terminal_no_gradient
run_test test_no_gradient_without_columns
run_test test_no_gradient_without_bg_rgb
run_test test_no_gradient_outside_truecolor

# ============================================================================
# Notes segment: queue depth after the session name
# ============================================================================

test_notes_segment_shows_queue_depth() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="notesess"
    make_cs_session "notesess" 0 cyan
    printf 'task a\ntask b\ntask c\n' > "$CS_SESSIONS_ROOT/notesess/.cs/local/queue"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "▤ 3" "notes segment shows the queue depth" || return 1
}

test_notes_segment_absent_when_queue_empty() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="emptyq"
    make_cs_session "emptyq" 0 cyan
    : > "$CS_SESSIONS_ROOT/emptyq/.cs/local/queue"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "▤" "notes segment hidden when queue empty" || return 1
}

# The queue count skips whitespace-only lines (a blank line is not a task). The
# pure-bash line loop must preserve awk's NF semantics.
test_notes_segment_skips_whitespace_only_lines() {
    export NO_COLOR=1
    export CLAUDE_SESSION_NAME="wsq"
    make_cs_session "wsq" 0 cyan
    printf 'task a\n   \ntask b\n' > "$CS_SESSIONS_ROOT/wsq/.cs/local/queue"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "▤ 2" "whitespace-only queue lines are not counted" || return 1
}

test_pane_segment_shows_tmux_pane_id() {
    export NO_COLOR=1
    export TMUX="/tmp/tmux-1000/default,12345,0"
    export TMUX_PANE="%7"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_contains "$out" "◫ %7" "pane segment shows the tmux pane id" || return 1
}

test_pane_segment_absent_outside_tmux() {
    export NO_COLOR=1
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_output_not_contains "$out" "◫" "pane segment hidden outside tmux" || return 1
}

test_pane_segment_needs_both_tmux_vars() {
    # A stale TMUX_PANE without TMUX (e.g. env leaked past a detach) must not render.
    export NO_COLOR=1
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

test_session_state_color_roundtrip() {
    # cs's _set_local_state is the writer; the statusline's _read_session_color
    # re-implements the parser (documented standalone necessity). This pins the
    # format so a serialization change in cs fails here instead of silently
    # stripping session colors.
    local state="$TEST_TMPDIR/state"
    ( source "$SCRIPT_DIR/../lib/40-state.sh" 2>/dev/null \
        && _set_local_state "$state" claude_session_color cyan ) || {
        echo "  FAIL: could not write state via lib/40-state.sh _set_local_state"
        return 1
    }
    local got
    got=$( CS_STATUSLINE_LIB=1 . "$SL" >/dev/null 2>&1; _read_session_color "$state"; printf '%s' "$_SESSION_COLOR" )
    assert_eq "cyan" "$got" "statusline reader must parse cs's state writer output" || return 1
}

test_library_mode_defines_helpers_without_rendering() {
    local out
    out=$( CS_STATUSLINE_LIB=1 . "$SL" >/dev/null 2>&1; \
           _detect_level; \
           _sgr 38 periwinkle; \
           printf 'LEVEL=%s SGR=%s' "$LEVEL" "$_SGR" )
    assert_output_contains "$out" "LEVEL=256" "library mode runs _detect_level" || return 1
    assert_output_contains "$out" "SGR=38;5;105" "library mode exposes _sgr's periwinkle" || return 1
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

run_test test_notes_segment_shows_queue_depth
run_test test_notes_segment_absent_when_queue_empty
run_test test_notes_segment_skips_whitespace_only_lines
run_test test_pane_segment_shows_tmux_pane_id
run_test test_pane_segment_absent_outside_tmux
run_test test_pane_segment_needs_both_tmux_vars
run_test test_segment_default_in_sync_across_docs_and_help
run_test test_session_state_color_roundtrip
run_test test_library_mode_defines_helpers_without_rendering
run_test test_library_mode_prints_nothing
run_test test_executed_directly_still_renders
run_test test_enable_registers_both_status_lines
run_test test_disable_leaves_a_foreign_subagent_statusline_alone
run_test test_enable_warns_that_a_restart_is_required

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

# Every render-time epoch read (limits stamp, countdown, pulse) goes through one
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
# and let a garbage value reach the stamp and the pulse arithmetic).
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

# The attention pulse parity uses the shared clock; an inherited garbage _NOW must
# not reach the arithmetic (crashes bash 3.2 under set -u). With the pin at an even
# second the mark renders chiptext regardless of the inherited value.
test_pulse_ignores_inherited_now() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="inhpulse"
    make_cs_session "inhpulse" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/inhpulse/.cs/local"
    touch "$CS_SESSIONS_ROOT/inhpulse/.cs/local/attention"
    local json='{"session_name":"inhpulse","workspace":{"current_dir":"/none"}}'
    local out
    out=$(_NOW=garbage CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains "$out" '240;242;255;1m ✳' "pin wins over inherited _NOW; even second stays chiptext" || return 1
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

# Same both-inherited case on the pulse path: sanitized memo state means the
# garbage _NOW never reaches the arithmetic (which would crash bash 3.2 set -u).
test_pulse_ignores_inherited_ready_flag() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="inhrpulse"
    make_cs_session "inhrpulse" 1024 blue
    mkdir -p "$CS_SESSIONS_ROOT/inhrpulse/.cs/local"
    touch "$CS_SESSIONS_ROOT/inhrpulse/.cs/local/attention"
    local json='{"session_name":"inhrpulse","workspace":{"current_dir":"/none"}}'
    local out
    out=$(_SL_NOW_READY=1 _NOW=garbage CS_STATUSLINE_NOW=1000 run_sl "$json")
    assert_output_contains "$out" '240;242;255;1m ✳' "inherited ready flag + garbage _NOW sanitized; pin parity holds" || return 1
}

# A leading-zero clock value (e.g. a pin of 08) passes a bare digit check but is
# read as octal by bash arithmetic, aborting on an 8/9 digit. The clock must be
# normalized to canonical base-10 before it reaches the stamp/countdown/pulse.
test_shared_clock_normalizes_leading_zero_pin() {
    export CLAUDE_SESSION_NAME="zeropin"
    mkdir -p "$CS_SESSIONS_ROOT/zeropin/.cs/local"
    local fixture='{"session_name":"zeropin","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":23}}}'
    CS_STATUSLINE_NOW=08 run_sl "$fixture" > /dev/null
    local lim="$CS_SESSIONS_ROOT/zeropin/.cs/local/limits"
    assert_file_contains "$lim" "stamped_at: 8$" "leading-zero pin normalized to base-10" || return 1
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

# A pin beats the live OS appearance even on macOS (terminal decoupled from OS).
test_sl_theme_macos_pin_beats_live() {
    ( _load_sl_functions
      export CS_TERM_THEME=light
      unset CS_TERM_THEME_AUTO 2>/dev/null || true
      OSTYPE="darwin24"
      defaults() { return 0; }   # OS is dark, but the pin says light
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "a pin overrides live macOS detection" || return 1 )
}

# Auto-detected launch value (CS_TERM_THEME + the AUTO marker) yields to the live
# macOS appearance so a mid-session switch is tracked.
test_sl_theme_follows_macos_dark_appearance() {
    ( _load_sl_functions
      export CS_TERM_THEME=light CS_TERM_THEME_AUTO=1   # launch detected light
      OSTYPE="darwin24"
      defaults() { return 0; }   # AppleInterfaceStyle key present => now dark
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "live macOS dark appearance overrides the launch theme" || return 1 )
}

test_sl_theme_follows_macos_light_appearance() {
    ( _load_sl_functions
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1   # launch detected dark
      OSTYPE="darwin24"
      defaults() { return 1; }   # key absent => now light
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "live macOS light appearance overrides the launch theme" || return 1 )
}

test_sl_theme_non_macos_uses_frozen_launch_value() {
    ( _load_sl_functions
      export CS_TERM_THEME=dark CS_TERM_THEME_AUTO=1
      OSTYPE="linux-gnu"
      _sl_detect_theme
      assert_eq "dark" "$SL_THEME" "non-macOS keeps the launch theme" || return 1 )
}

test_sl_theme_non_macos_defaults_light() {
    ( _load_sl_functions
      unset CS_TERM_THEME CS_TERM_THEME_AUTO 2>/dev/null || true
      OSTYPE="linux-gnu"
      _sl_detect_theme
      assert_eq "light" "$SL_THEME" "non-macOS with no launch theme defaults light" || return 1 )
}

# _sl_invalidate_stale_bg blanks CS_TERM_BG_RGB once the live theme (SL_THEME)
# has left the launch theme (CS_TERM_THEME + auto marker), so surfaces/gradient
# don't tint toward the old background.
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
run_test test_pulse_ignores_inherited_now
run_test test_shared_clock_ignores_inherited_ready_flag
run_test test_pulse_ignores_inherited_ready_flag
run_test test_shared_clock_normalizes_leading_zero_pin
run_test test_sl_theme_user_pin_overrides
run_test test_sl_theme_macos_pin_beats_live
run_test test_sl_theme_follows_macos_dark_appearance
run_test test_sl_theme_follows_macos_light_appearance
run_test test_sl_theme_non_macos_uses_frozen_launch_value
run_test test_sl_theme_non_macos_defaults_light
run_test test_sl_bg_rgb_dropped_after_switch
run_test test_sl_bg_rgb_kept_when_theme_matches
run_test test_sl_bg_rgb_kept_for_manual_value
report_results
