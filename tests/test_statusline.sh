#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-statusline, the Claude Code powerline statusline
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
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
    # Neutral terminal by default; per-test overrides as needed.
    export TERM="xterm-256color"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_SESSION_NAME NO_COLOR COLORTERM TERM_PROGRAM \
        FORCE_COLOR CS_STATUSLINE_DISABLE CS_STATUSLINE_SEGMENTS CS_STATUSLINE_CTX_WARN \
        CS_STATUSLINE_CTX_CRIT CS_NERD_FONTS CS_DISCOVERIES_MAX_SIZE 2>/dev/null || true
}

# --- Helpers ---

# Run the statusline with $1 as stdin JSON; prints its stdout.
run_sl() {
    printf '%s' "$1" | bash "$SL"
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
    mkdir -p "$sdir/.cs"
    cat > "$sdir/.cs/README.md" <<EOF
---
created: 2026-06-11
claude_session_color: $color
---
# $name
EOF
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
    assert_eq "⌂ my-session > ✱ Opus high > ◔ ctx 8% > ◷ 5h 23% > ◑ wk 41% > \$0.01" "$out" \
        "docs fixture should render identity first, then gauges"
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
    assert_eq "⌂ mysess > ✱ Opus high > ◔ ctx 34% > ⎇ main +1!1 > ◷ 5h 23% > ◑ wk 41% > \$1.23" "$out" \
        "all segments should render in order: identity pair, then gauges"
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
    assert_output_not_contains "$out" "48;2;153;152;255" "healthy limits must not take the accent periwinkle" || return 1
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
    assert_output_contains "$out" "48;2;0;135;135" "session block should carry the session color (cyan)" || return 1
    assert_output_contains "$out" "48;2;153;152;255;38;2;240;242;255" "model should be the usage-chip periwinkle with the chip's text color" || return 1
    local greys
    greys=$(printf '%s' "$out" | grep -o '48;2;88;88;88' | grep -c . ) || greys=0
    if [ "$greys" -lt 4 ]; then
        echo "  FAIL: expected ctx, git-less run, 5h, wk, cost on grey (got $greys grey blocks)"
        return 1
    fi
}

# ============================================================================
# Limits thresholds escalate per block: healthy 5h stays periwinkle, hot wk red
# ============================================================================

test_limits_threshold_per_block() {
    export COLORTERM=truecolor
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":95}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;215;0;0" "wk 95% block should go red" || return 1
    assert_output_not_contains "$out" "48;2;255;183;77" "healthy 5h block must not show amber" || return 1
}

# ============================================================================
# Same-colored neighbor segments separate with a thin chevron, not a solid arrow
# ============================================================================

test_thin_chevron_between_same_bg() {
    export COLORTERM=truecolor
    # Adjacent warn blocks share the amber background: ctx at warn next to a
    # 5h block at warn (segment order trimmed so the two are neighbors).
    export CS_STATUSLINE_SEGMENTS="ctx,limits"
    local json='{"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":55},"rate_limits":{"five_hour":{"used_percentage":75}}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "›" "same-bg neighbors should join with a thin chevron" || return 1
}

test_solid_arrow_between_different_bg() {
    export COLORTERM=truecolor
    # session grey then the periwinkle model accent: differing neighbors keep
    # the solid arrow.
    local json='{"session_name":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" ">" "different-bg neighbors should keep the solid arrow" || return 1
    assert_output_not_contains "$out" "›" "no thin chevron when backgrounds differ" || return 1
}

# ============================================================================
# Segment icons are standard Unicode (render without a Nerd Font);
# CS_NERD_FONTS only changes the separator, not the icons
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

test_no_powerline_arrow_without_nerd_fonts() {
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
    local out arrow branch_icon
    out=$(run_sl "$json")
    arrow=$'\xee\x82\xb0'        # U+E0B0 powerline arrow (Nerd Font only)
    branch_icon=$'\xe2\x8e\x87'  # U+2387 branch (standard Unicode)
    assert_output_not_contains "$out" "$arrow" "powerline arrow must not appear without CS_NERD_FONTS=1" || return 1
    assert_output_contains "$out" "$branch_icon" "Unicode icons still render without CS_NERD_FONTS=1" || return 1
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
    assert_output_contains "$out" "48;2;100;100;108" "dark theme should lift the neutral grey" || return 1
    assert_output_contains "$out" "38;2;230;230;230" "dark theme should soften white text" || return 1
    assert_output_not_contains "$out" "48;2;88;88;88" "dark theme must not use the light-theme grey" || return 1
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
# Missing session_name outside a cs session -> basename of current_dir
# ============================================================================

test_missing_session_name_dir_fallback() {
    export NO_COLOR=1
    local json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/alpha/beta"},"context_window":{"used_percentage":5}}'
    local out
    out=$(run_sl "$json")
    assert_eq "⌂ beta > ✱ Opus > ◔ ctx 5%" "$out" \
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
    assert_eq "⌂ s > ✱ Opus > ◔ ctx 5%" "$out" \
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
    assert_output_contains "$out" "215;0;0" "ctx 84% should use the red background rgb"
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
    assert_output_not_contains "$out" "215;0;0" "ctx 8% must not use red" || return 1
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
    assert_output_contains "$out" "48;2;153;152;255;38;2;240;242;255" \
        "the periwinkle model accent carries the chip's text color rgb(240,242,255)" || return 1
}

test_accent_segments_bold() {
    export COLORTERM=truecolor
    export CLAUDE_SESSION_NAME="boldsess"
    make_cs_session "boldsess" 1000 cyan
    local json='{"session_name":"boldsess","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out
    out=$(run_sl "$json")
    assert_output_contains "$out" "48;2;0;135;135;38;2;240;242;255;1" \
        "the session accent should render bold in the chip text color" || return 1
    assert_output_contains "$out" "48;2;153;152;255;38;2;240;242;255;1" \
        "the model accent should render bold in the chip text color" || return 1
    # SGR bold is stateful: a segment that does not explicitly emit normal
    # intensity (22) inherits bold from the accent before it.
    assert_output_contains "$out" "48;2;88;88;88;38;2;255;255;255;22" \
        "grey segments must explicitly reset to normal intensity" || return 1
    assert_output_not_contains "$out" "48;2;88;88;88;38;2;255;255;255;1m" \
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
    assert_output_contains "$out" "215;0;0" "wk 95% should drive the limits bg red"
}

# ============================================================================
# CS_STATUSLINE_SEGMENTS subset controls which segments render and their order
# ============================================================================

test_segments_subset() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="model,cost"
    local out
    out=$(run_sl "$FIXTURE_DOCS")
    assert_eq "✱ Opus high > \$0.01" "$out" \
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
# Nerd-font glyph toggle: CS_NERD_FONTS=1 emits the U+E0B0 powerline arrow
# ============================================================================

test_nerd_font_glyph() {
    export COLORTERM="truecolor"
    export CS_NERD_FONTS=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8}}'
    local out glyph
    glyph=$(printf '\xee\x82\xb0')
    out=$(run_sl "$json")
    assert_output_contains "$out" "$glyph" "nerd fonts should render the powerline arrow"
    assert_output_not_contains "$out" ">" "nerd glyph should replace the ASCII '>' arrow"
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
    assert_eq "⌂ s > ◔ ctx 0%" "$(run_sl "$with0")" "ctx 0% should render explicitly"
    local without='{"session_name":"s","workspace":{"current_dir":"/none"}}'
    assert_eq "⌂ s" "$(run_sl "$without")" "absent used_percentage should omit the ctx segment"
}

# ============================================================================
# Unknown CS_STATUSLINE_SEGMENTS tokens are skipped, not fatal
# ============================================================================

test_unknown_segment_ignored() {
    export NO_COLOR=1
    export CS_STATUSLINE_SEGMENTS="session,bogus,model"
    local json='{"session_name":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    assert_eq "⌂ s > ✱ Opus" "$(run_sl "$json")" "unknown segment tokens should be skipped"
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
    assert_output_contains "$out" "48;2;88;88;88" \
        "unknown session color should fall back to neutral grey"
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
run_test test_limits_threshold_per_block
run_test test_thin_chevron_between_same_bg
run_test test_solid_arrow_between_different_bg
run_test test_segment_icons_are_unicode
run_test test_no_powerline_arrow_without_nerd_fonts
run_test test_detect_theme_colorfgbg_dark
run_test test_detect_theme_colorfgbg_light
run_test test_detect_theme_konsole_three_part
run_test test_detect_theme_unknown_without_signals
run_test test_detect_theme_tmux_appearance_dark
run_test test_detect_theme_tmux_appearance_light
run_test test_detect_theme_tmux_non_darwin_unknown
run_test test_statusline_dark_theme_variant
run_test test_missing_rate_limits_absent
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
run_test test_nerd_font_glyph
run_test test_git_ahead_arrow
run_test test_force_color_zero_is_plain
run_test test_io_gating_git_subprocess
run_test test_ctx_zero_vs_absent
run_test test_unknown_segment_ignored
run_test test_unknown_session_color_falls_back
report_results
