# Status bar capsules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bar of abutting colour blocks with one neutral identity capsule, a ctx capsule, and rate-limit capsules that appear only when hot, with amber and red as ink on the number until crit inverts the capsule.

**Architecture:** `bin/cs-statusline` keeps its stdin parse, colour ladder, git query and fable cache untouched; the segment model gains a capsule group per item and `_render` is rewritten to emit cap, items, cap, gap per group with no tail. `bin/cs-subagent-statusline` sources the same file and is not edited; only its two hot colours move. Docs, help and changelog follow.

**Tech Stack:** bash 3.2 (macOS stock) and BSD userland; `jq`; the repo's `tests/test_lib.sh` harness (`run_test`, `assert_eq`, `assert_output_contains`, `assert_output_not_contains`, `assert_file_contains`).

**Spec:** `docs/superpowers/specs/2026-09-13-statusbar-capsules-design.md`

**Departures from the spec, decided while planning (Alex rules on these at review):**

1. `_display_width` stays: `bin/cs-subagent-statusline` `_truncate` calls it (its line 68). The spec listed it among the removals.
2. Plain mode joins items inside one capsule with their plain joiner (` · `, or one space) and capsules with ` > `, so `mysess · ⎇ main +1!1 · ✦ Opus high > ◔ ctx 34%`. The spec said plain stays `a > b > c`; with ctx as two items (label and number) that shape would print `◔ ctx > 34%`.
3. The amber ink keeps the name `amber` (no `amberink` token); nothing paints amber as a fill any more. `_thresh_color` emits `crit` in place of `red`, so `red` stays untouched as the session palette entry the tab-colour test pins.
4. Effort is its own identity item joined by one space, so it can take secondary ink while the model name is bold primary.
5. The pulse's bright phase is `brand`, its dim phase `brandshade`. Today's bright phase is `chiptext`, which is removed with the pills.
6. The tail case `test_columns_fills_the_bar_without_a_measured_bg` (its name lacks the spec's five words) is the sixteenth deletion.
7. Eight non-tail tests go too, all in Task 2 Step 1: five that pin the hairline and logo-boundary dividers the pills had (`test_thin_bar_between_same_bg`, `test_abut_between_different_bg`, `test_logo_boundary_gets_thin_darker_coral_hairline`, `test_segment_after_logo_divider_drops_redundant_leading_pad`, `test_logo_divider_survives_orange_session_color_collision`), and the three logo-phase tests, replaced by two that pin the same states on the new inks. Decision 10 named only the tail cases; these need Alex's yes.
8. `_read_session_color` and `_SESSION_COLOR` leave `bin/cs-statusline` with the session fill (no caller remains); the SYNC comment in `lib/40-state.sh` drops its cs-statusline clause.

## Global Constraints

- bash 3.2 and BSD userland: no `local -A`, no `printf %(...)T`, no `mapfile`, no `${var,,}`, no GNU-only sed/awk flags. Parse every edited script with `/bin/bash -n`.
- The render hot path forks nothing new: no command substitution, no subprocess in `_render` or any `_seg_*`.
- The eight session colours in `_sgr` (`red) rgb="220;38;38"` … `cyan)`) are Claude Code's tab palette, KEEP IN SYNC with `_session_color_rgb` in `bin/cs`; `tests/test_statusline.sh::test_tab_color_palette_matches_statusline` greps their exact line shape. Do not rename, reorder or reformat them.
- The default segment list is spelled in four sites and `test_segment_default_in_sync_across_docs_and_help` pins them equal: `bin/cs-statusline` (`CS_STATUSLINE_SEGMENTS:-…`), `lib/10-help.sh:84`, `docs/configuration.md:60`, `docs/statusline.md:13`. Change all four in the same commit.
- `assert_file_contains`, `assert_output_contains` and `assert_output_not_contains` are `grep -q` (BRE, case-sensitive): a pattern opening with `[` is an unterminated bracket expression and fails on a correct build. Every capsule pin therefore uses the fixed-string helpers `assert_output_contains_f` / `assert_output_not_contains_f` that Task 2 Step 2 defines (`grep -qF`). Every assert in a test needs `|| return 1` (`run_test` disables errexit).
- Test output must be pristine: no stray stderr from a fixture.
- No real names, emails or handles in fixtures; `example.com` placeholders only.
- Never push. Commit on `feat/statusbar-capsules`.
- `run_sl` in the statusline suite pipes JSON to `bash "$SL"`; `setup()` unsets every `CS_*`/`CLAUDE_*`/terminal variable and pins `CS_TERM_THEME=light`, `TERM=xterm-256color`. Truecolor tests export `COLORTERM=truecolor`; plain tests export `NO_COLOR=1`.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `bin/cs-statusline` | the bar: parse, colour ladder, segments, render | tokens (Task 1), segment model and render (Task 2), limits gating and names (Task 3) |
| `bin/cs-subagent-statusline` | agent-panel rows; sources the bar as a library | no edit; its suite's two hot-colour pins update (Task 1) |
| `tests/test_statusline.sh` | the bar's suite (199 cases) | tokens (1), render pins and tail deletions (2), limits and names (3), docs sync (3) |
| `tests/test_subagent_statusline.sh` | agent-row suite | two pins (Task 1) |
| `lib/10-help.sh:84` | `cs -statusline` help copy of the default list | Task 3 |
| `docs/configuration.md:45-60` | env reference | default list (Task 3), fade comment and `CS_STATUSLINE_CAPS` (Task 4) |
| `docs/statusline.md` | design doc | default list (Task 3), Segments, Colors, gradient section, Pinning, Configuration (Task 4) |
| `README.md:75` | status-line paragraph | Task 4 |
| `CHANGELOG.md` | Unreleased | Task 4 |

---

### Task 1: Colour tokens and the threshold helper

**Files:**
- Modify: `bin/cs-statusline` `_sgr` (truecolor arm starts at the `case "$name" in` under `truecolor)`, ~line 436; 256 arm ~line 500; basic arm ~line 522) and `_thresh_color` (~line 578)
- Test: `tests/test_statusline.sh`, `tests/test_subagent_statusline.sh`

**Interfaces:**
- Consumes: `_sgr KIND NAME` sets `_SGR` (and `_RGB` in truecolor); `SL_THEME` is `light` or `dark`; `_SURFACE_RGB` memo; `_luminance`, `_parse_rgb_triplet`.
- Produces: tokens `ink`, `ink2`, `crit`, `critink` at all three levels; `amber` re-valued as an ink; `_thresh_color V WARN CRIT [HEALTHY]` sets `_COLOR` to `crit`, `amber`, or `$HEALTHY` (default `ink2`). Task 2 paints with exactly these names.

- [ ] **Step 1: Write the failing token tests**

Append to `tests/test_statusline.sh` directly above the first `run_test` line (the block that begins `run_test test_happy_path_docs_fixture_plain`):

```bash
# ============================================================================
# Capsule colour tokens: the four inks and the crit fill, per level and theme
# ============================================================================

test_sgr_ink_tokens_truecolor_light() {
    export CS_TERM_THEME=light
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=light; _SURFACE_RGB=""
    _sgr 38 ink2;    assert_eq "38;2;119;117;110" "$_SGR" "ink2 light" || return 1
    _sgr 38 amber;   assert_eq "38;2;180;83;9"    "$_SGR" "amber is an ink on light" || return 1
    _sgr 48 crit;    assert_eq "48;2;215;0;21"    "$_SGR" "crit fill light" || return 1
    _sgr 38 critink; assert_eq "38;2;255;255;255" "$_SGR" "crit ink light" || return 1
}

test_sgr_ink_tokens_truecolor_dark() {
    _load_sl_functions
    LEVEL=truecolor; SL_THEME=dark; _SURFACE_RGB=""
    _sgr 38 ink2;    assert_eq "38;2;168;170;166" "$_SGR" "ink2 dark" || return 1
    _sgr 38 amber;   assert_eq "38;2;245;165;36"  "$_SGR" "amber ink dark" || return 1
    _sgr 48 crit;    assert_eq "48;2;255;69;58"   "$_SGR" "crit fill dark" || return 1
    _sgr 38 critink; assert_eq "38;2;37;0;0"      "$_SGR" "crit ink dark" || return 1
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
    _sgr 38 ink2;    assert_eq "38;5;244" "$_SGR" "ink2 256 light" || return 1
    _sgr 38 amber;   assert_eq "38;5;130" "$_SGR" "amber 256 light" || return 1
    _sgr 48 crit;    assert_eq "48;5;160" "$_SGR" "crit 256 light" || return 1
    _sgr 38 critink; assert_eq "38;5;231" "$_SGR" "critink 256 light" || return 1
    SL_THEME=dark
    _sgr 38 ink2;    assert_eq "38;5;248" "$_SGR" "ink2 256 dark" || return 1
    _sgr 38 amber;   assert_eq "38;5;215" "$_SGR" "amber 256 dark" || return 1
    _sgr 48 crit;    assert_eq "48;5;203" "$_SGR" "crit 256 dark" || return 1
    _sgr 38 critink; assert_eq "38;5;232" "$_SGR" "critink 256 dark" || return 1
    LEVEL=basic; SL_THEME=light
    _sgr 38 ink2;    assert_eq "90" "$_SGR" "ink2 basic" || return 1
    _sgr 38 amber;   assert_eq "33" "$_SGR" "amber basic" || return 1
    _sgr 48 crit;    assert_eq "41" "$_SGR" "crit basic bg" || return 1
    _sgr 38 critink; assert_eq "97" "$_SGR" "critink basic light" || return 1
    SL_THEME=dark
    _sgr 38 critink; assert_eq "30" "$_SGR" "critink basic dark" || return 1
}

test_thresh_color_emits_crit_and_defaults_to_ink2() {
    _load_sl_functions
    _thresh_color 10 40 65; assert_eq "ink2"  "$_COLOR" "below warn is the secondary ink" || return 1
    _thresh_color 40 40 65; assert_eq "amber" "$_COLOR" "at warn is amber" || return 1
    _thresh_color 65 40 65; assert_eq "crit"  "$_COLOR" "at crit is crit, not red" || return 1
    _thresh_color 10 40 65 rowmeta; assert_eq "rowmeta" "$_COLOR" "an explicit healthy name is honoured" || return 1
}
```

And add, at the top of the `run_test` block:

```bash
run_test test_sgr_ink_tokens_truecolor_light
run_test test_sgr_ink_tokens_truecolor_dark
run_test test_sgr_ink_follows_surface_luminance
run_test test_sgr_ink_tokens_256_and_basic
run_test test_thresh_color_emits_crit_and_defaults_to_ink2
```

- [ ] **Step 2: Run the five and watch them fail**

Run: `bash tests/test_statusline.sh 2>&1 | grep -E 'sgr_ink|thresh_color_emits' `
Expected: all five FAIL (`ink2` resolves through the `*)` fallback to the taupe, `crit` likewise, `_thresh_color` yields `red`/`surface`).

- [ ] **Step 3: Add the tokens**

In `_sgr`'s truecolor arm, replace the `amber)  rgb="255;183;77" ;;` line with:

```bash
                # Inks. `amber` is a foreground now: the hot number's colour on
                # the neutral capsule, dark enough to hold contrast on cream and
                # bright enough on a dark surface. Nothing paints amber as a fill.
                amber)
                    [ "$SL_THEME" = "dark" ] && rgb="245;165;36" || rgb="180;83;9" ;;
                # Primary text on the capsule surface: a warm 35% shade of the
                # surface on a light one, the soft white on a dark one — the same
                # contrast pivot the old surface text used, resolved from the
                # surface's own luminance rather than the theme flag.
                ink)
                    _sgr 48 surface
                    if _parse_rgb_triplet "$_RGB" && { _luminance; [ "$_LUM" -ge 1530000 ]; }; then
                        rgb="$((_R * 35 / 100));$((_G * 35 / 100));$((_B * 35 / 100))"
                    elif [ "$SL_THEME" = "dark" ]; then rgb="230;230;230"
                    else rgb="255;255;255"; fi ;;
                # Secondary text: separators, effort, gauge labels, resting numbers.
                ink2)
                    [ "$SL_THEME" = "dark" ] && rgb="168;170;166" || rgb="119;117;110" ;;
                # The inverted capsule at crit. Its own token, never the session
                # palette's red: that palette is the tab colour and may change.
                crit)
                    [ "$SL_THEME" = "dark" ] && rgb="255;69;58" || rgb="215;0;21" ;;
                critink)
                    [ "$SL_THEME" = "dark" ] && rgb="37;0;0" || rgb="255;255;255" ;;
```

Note `ink` calls `_sgr 48 surface` recursively to resolve the memoised surface, then overwrites `_SGR` on the way out (the function's last line assigns `_SGR` from `rgb`). Because `_sgr` ends with `_SGR="${kind};2;${rgb}"; _RGB="$rgb"`, the recursive call's side effects are harmless.

In the 256 arm, replace `amber)  idx=215 ;;` with:

```bash
                amber)   [ "$SL_THEME" = "dark" ] && idx=215 || idx=130 ;;
                ink)     [ "$SL_THEME" = "dark" ] && idx=231 || idx=235 ;;
                ink2)    [ "$SL_THEME" = "dark" ] && idx=248 || idx=244 ;;
                crit)    [ "$SL_THEME" = "dark" ] && idx=203 || idx=160 ;;
                critink) [ "$SL_THEME" = "dark" ] && idx=232 || idx=231 ;;
```

In the basic arm, after `amber)  base=33 ;;` add:

```bash
                ink)     [ "$SL_THEME" = "dark" ] && base=97 || base=30 ;;
                ink2)    base=90 ;;
                crit)    base=31 ;;
                critink) [ "$SL_THEME" = "dark" ] && base=30 || base=97 ;;
```

Replace `_thresh_color` with:

```bash
# Set _COLOR by mapping a value against warn/crit thresholds: `crit` at or past
# crit, `amber` at or past warn, else the healthy name ($4, default the
# secondary ink). Callers paint the NUMBER with it; `crit` also tells the
# renderer to invert the whole capsule.
_thresh_color() {
    local v="$1" warn="$2" crit="$3" healthy="${4:-ink2}"
    if [ "$v" -ge "$crit" ]; then
        _COLOR=crit
    elif [ "$v" -ge "$warn" ]; then
        _COLOR=amber
    else
        _COLOR="$healthy"
    fi
}
```

- [ ] **Step 4: Run the five again**

Run: `bash tests/test_statusline.sh 2>&1 | grep -E 'sgr_ink|thresh_color_emits'`
Expected: five PASS. The rest of the suite is now partly red (old `red`/amber-fill pins); Task 2 rewrites those. Do not touch them here.

- [ ] **Step 5: Move the agent-row pins**

In `tests/test_subagent_statusline.sh`, the two tests at ~line 241 and ~255 pin `38;2;255;183;77` and `38;2;220;38;38`. That suite's `setup()` does not pin `CS_TERM_THEME`; check the file and, if it is unset, `export CS_TERM_THEME=light` inside each of the two tests. Then replace every `38;2;255;183;77` with `38;2;180;83;9` and every `38;2;220;38;38` with `38;2;215;0;21`, and update the two comments (`amber 255;183;77` → `amber ink 180;83;9`; `red 220;38;38` → `crit 215;0;21`).

Run: `bash tests/test_subagent_statusline.sh > /tmp/sub.out 2>&1; echo rc=$?; tail -3 /tmp/sub.out`
Expected: rc=0, all cases pass.

- [ ] **Step 6: Commit**

```bash
/bin/bash -n bin/cs-statusline && git add bin/cs-statusline tests/test_statusline.sh tests/test_subagent_statusline.sh \
  && git commit -m "feat(statusline): ink tokens and a crit fill; thresholds emit crit, not the palette red"
```

---

### Task 2: Capsule renderer, identity and ctx capsules, no tail

**Files:**
- Modify: `bin/cs-statusline` — `_add` (~line 557), `_seg_logo` through `_seg_ctx`, `_seg_model`, `_seg_git`, `_seg_cost` (~lines 1115–1290), `_render` (~line 1458), removals of `_build_dots`, `_build_wash`, `_build_gradient`, `_lerp_channel` (~lines 1321–1431), `_read_session_color` (~line 1057) and `ICON_LOGO`'s comment if it mentions the badge
- Modify: `lib/40-state.sh:36-38` — the `_read_local_state` comment's SYNC clause
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: Task 1's tokens; `_sl_now` → `_NOW`; `ICON_*`; `_read_session_color`; `_git_text` → `_GIT_TEXT`; `_num_or` → `_NUM`.
- Produces:
  - `_add TEXT GROUP [INK] [WEIGHT] [JOIN]` — INK defaults `ink2`; WEIGHT `bold` or empty; JOIN `dot` (default), `pad`, `space`, `none`.
  - `_invert GROUP` — marks a capsule crit.
  - `_render` — groups in first-seen order; `identity` gets a two-cell gap after it, every other group one cell; `CS_STATUSLINE_CAPS=0` drops the cap glyphs.
  - Task 3 adds limits capsules with `_add … "lim-5h"` etc. and `_invert "lim-5h"`.

- [ ] **Step 1: Delete the tail and hairline tests**

Delete these sixteen functions and their `run_test` lines: `test_build_gradient_cell_count_and_endpoints`, `test_build_gradient_noop_on_malformed_target`, `test_full_width_gradient_reaches_columns`, `test_gradient_renders_without_a_measured_bg`, `test_unmeasured_tail_is_a_coverage_wash`, `test_wash_does_not_inherit_the_last_segment_background`, `test_wash_grey_ramps_toward_the_theme`, `test_measured_bg_still_uses_the_colour_fade`, `test_tail_gradient_neutral_regardless_of_last_segment`, `test_narrow_terminal_no_gradient`, `test_no_gradient_without_columns`, `test_columns_fills_the_bar_without_a_measured_bg`, `test_no_gradient_outside_truecolor`, `test_basic_terminal_gets_no_dotted_tail`, `test_malformed_background_falls_through_to_a_tail`, `test_dotted_tail_fills_a_256_bar`, `test_truecolor_keeps_the_gradient_not_dots`. Also delete `test_thin_bar_between_same_bg`, `test_abut_between_different_bg`, `test_logo_boundary_gets_thin_darker_coral_hairline`, `test_segment_after_logo_divider_drops_redundant_leading_pad`, `test_logo_divider_survives_orange_session_color_collision` (hairline and logo-boundary behaviour, gone with the pills), and `test_logo_pulses_bright_phase_with_attention_marker`, `test_logo_pulses_dim_phase_with_attention_marker`, `test_logo_steady_without_attention_marker` (superseded by `test_logo_pulse_alternates_brand_and_brandshade` and `test_logo_is_brand_ink_inside_identity` in Step 2, which pin the same three states on the new inks). Alex approved the tail deletions (Decision 10); the other eight are Departure 7. Any other test whose name contains `gradient`, `wash`, `dots`, `dotted`, `tail`, `hairline` or `divider` goes too — grep for them and list what you deleted in the commit body.

- [ ] **Step 2: Write the failing render tests**

Append above the `run_test` block:

```bash
# ============================================================================
# Capsules: one identity capsule, a ctx capsule, caps, no tail
# ============================================================================

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
    assert_output_not_contains_f "$out" "48;2;79;91;140" "no slate fill" || return 1
    assert_output_not_contains_f "$out" "48;2;138;134;236" "no periwinkle fill" || return 1
    assert_output_not_contains_f "$out" "48;2;8;145;178" "no session-colour fill" || return 1
    # Items join with a secondary-ink dot inside the capsule.
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;119;117;110;22m  ·  " "dot joiner in ink2" || return 1
    # Exactly one identity capsule: one left cap before ctx's, two in total.
    local caps; caps=$(printf '%s' "$out" | grep -o "$CAPL" | wc -l | tr -d ' ')
    assert_eq "2" "$caps" "identity and ctx are the only two capsules" || return 1
}

test_capsule_gap_two_cells_after_identity_one_after_gauges() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    export CS_STATUSLINE_SEGMENTS="session,ctx,cost"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"cost":{"total_cost_usd":1.5}}'
    local out; out=$(run_sl "$json")
    local esc=$'\033'
    assert_output_contains_f "$out" "${CAPR}${esc}[0m  ${esc}[49;38;2;227;221;204m${CAPL}" \
        "two default-bg cells between identity and ctx" || return 1
    assert_output_contains_f "$out" "8%${esc}[48;2;227;221;204m ${esc}[49;38;2;227;221;204m${CAPR}${esc}[0m ${esc}[49;38;2;227;221;204m${CAPL}" \
        "one cell between ctx and cost" || return 1
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
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;180;83;9;22m42%" "the number is amber ink" || return 1
    assert_output_not_contains_f "$out" "48;2;255;183;77" "no amber fill anywhere" || return 1
    assert_output_not_contains_f "$out" "48;2;180;83;9" "amber never becomes a fill" || return 1
    assert_output_contains_f "$out" "38;2;119;117;110;22m◔ ctx" "the label stays secondary ink" || return 1
}

test_ctx_crit_inverts_only_its_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":71}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "[49;38;2;215;0;21m${CAPL}" "ctx capsule's caps take the crit fill" || return 1
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◔ ctx" "label inverts to critink bold" || return 1
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

test_logo_pulse_alternates_brand_and_brandshade() {
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
    assert_output_contains_f "$even" "38;2;217;119;87;1m✳" "even second: brand" || return 1
    assert_output_contains_f "$odd"  "38;2;184;101;74;1m✳" "odd second: brandshade" || return 1
}

test_effort_is_secondary_ink_after_the_model() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"model":{"display_name":"Opus"},"effort":{"level":"high"}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "38;2;79;77;71;1m✦ Opus" "model name bold primary" || return 1
    assert_output_contains_f "$out" "✦ Opus${ESC_}[48;2;227;221;204m ${ESC_}[48;2;227;221;204;38;2;119;117;110;22mhigh" \
        "effort one space after, secondary, regular" || return 1
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
```

Add the `run_test` lines for all eleven.

- [ ] **Step 3: Run and watch them fail**

Run: `bash tests/test_statusline.sh > /tmp/sl.out 2>&1; grep -cE '^  (FAIL|PASS)' /tmp/sl.out; grep -E 'capsule|caps_off|last_cap|plain_joins|brand_ink|pulse_alternates|effort_is|notes_and_mail|ctx_amber_is_ink|ctx_crit_inverts' /tmp/sl.out`
Expected: every new case FAILs (no caps in the output, `_add` still takes a bg).

- [ ] **Step 4: Replace the segment model**

Replace `_add` and its comment with:

```bash
# Append one item to a capsule. $1 text; $2 capsule group ("identity", "ctx",
# "lim-5h", "cost" …) — items sharing a group render inside one capsule, in
# first-seen order; $3 ink token (default the secondary ink); $4 "bold" or
# empty; $5 how this item joins the one before it inside the capsule: "dot"
# (default) a secondary-ink "  ·  ", "pad" two fill spaces, "space" one,
# "none" nothing. The first item of a capsule never gets a joiner.
_add() {
    _SEG_TEXT+=("$1")
    _SEG_GROUP+=("$2")
    _SEG_INK+=("${3:-ink2}")
    _SEG_BOLD+=("${4:-}")
    _SEG_JOIN+=("${5:-dot}")
}

# Mark a capsule crit: the renderer fills it with `crit` and paints every item
# in it critink bold. A space-delimited list so bash 3.2 needs no map.
_CRIT_GROUPS=""
_invert() {
    _CRIT_GROUPS="$_CRIT_GROUPS $1 "
}
```

Find every `_SEG_TEXT=()`-style initialisation (grep `_SEG_BG=(`) and replace `_SEG_BG` with `_SEG_GROUP`, adding `_SEG_INK=()` and `_SEG_JOIN=()` beside them.

- [ ] **Step 5: Migrate the segments**

Replace `_seg_logo`, `_seg_session`, the `_add` lines of `_seg_notes` and `_seg_mail`, `_seg_pane`, `_seg_ctx`, `_seg_model`, `_seg_git`, `_seg_cost`:

```bash
# The Claude mark, coral ink on the identity capsule. While the session's
# attention marker exists (raised by the Stop hook when Claude finishes a turn,
# cleared on the next prompt) the mark alternates brand/brandshade by epoch-
# second parity; the statusLine registration's refreshInterval repaints the bar
# every second while idle so the phase keeps advancing. CS_STATUSLINE_NOW pins
# the clock for tests. Plain mode has no colour, so no mark.
_seg_logo() {
    [ "$LEVEL" = "plain" ] && return 0
    local ink=brand
    if [ -n "${CLAUDE_SESSION_NAME:-}" ] \
        && [ -f "$SESSIONS_ROOT/$CLAUDE_SESSION_NAME/.cs/local/attention" ]; then
        _sl_now
        [ $(( ${_NOW:-0} % 2 )) -eq 1 ] && ink=brandshade
    fi
    _add "${ICON_LOGO}" identity "$ink" bold
}

# The session name, bold primary ink. Its claude_session_color stays on the
# terminal tab and in claude's own accent; the bar no longer paints it.
_seg_session() {
    local name="$SL_SESSION"
    [ -n "$name" ] || name="${CLAUDE_SESSION_NAME:-}"
    if [ -z "$name" ]; then
        local dir="${SL_DIR:-$PWD}"
        name="${dir##*/}"
    fi
    _add "${name}" identity ink bold space
}
```

In `_seg_notes` replace `_add "${ICON_NOTES}${n}" "amber"` with `_add "${ICON_NOTES}${n}" identity amber "" pad`; in `_seg_mail` replace `_add "${ICON_MAIL}${unread}" "amber"` with `_add "${ICON_MAIL}${unread}" identity amber "" pad`.

```bash
# The tmux pane hosting this conversation, "◫ 7": the number without its "%"
# so it cannot read as a percentage; prefix it back for a tmux target. Both
# vars are inherited environment, so neither is evidence on its own (see
# SL_ENV_FOREIGN). Off the default order; renders when named.
_seg_pane() {
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
    [ -z "${SL_ENV_FOREIGN:-}" ] || return 0
    _add "${ICON_PANE}${TMUX_PANE#%}" identity ink2 "" pad
}

# Two items in the ctx capsule: the label in secondary ink, the number in the
# threshold colour. At crit the whole capsule inverts.
_seg_ctx() {
    local v="${SL_CTX%%.*}"
    [ -n "$v" ] || return 0
    local warn crit
    _num_or "${CS_STATUSLINE_CTX_WARN:-}" 40; warn="$_NUM"
    _num_or "${CS_STATUSLINE_CTX_CRIT:-}" 65; crit="$_NUM"
    _thresh_color "$v" "$warn" "$crit"
    [ "$_COLOR" = "crit" ] && _invert ctx
    _add "${ICON_CTX}ctx" ctx ink2 "" none
    _add "${v}%" ctx "$_COLOR" "" space
}

_seg_model() {
    [ -n "$SL_MODEL" ] || return 0
    _add "${ICON_MODEL}${SL_MODEL}" identity ink bold
    [ -n "$SL_EFFORT" ] && _add "$SL_EFFORT" identity ink2 "" space
    return 0
}

_seg_git() {
    _git_text "$SL_DIR"
    local t="$_GIT_TEXT"
    [ -n "$t" ] || return 0
    _add "${ICON_GIT}${t}" identity ink bold
}

_seg_cost() {
    [ -n "$SL_COST" ] || return 0
    local formatted
    printf -v formatted '$%.2f' "$SL_COST" 2>/dev/null || return 0
    _add "$formatted" cost
}
```

`ICON_CTX` carries a trailing space (`◔ `), so the label is `◔ ctx` and the number follows after the `space` joiner: plain `◔ ctx 34%`, exactly the old text.

Leave `_seg_limits` and `_seg_fable` on the old `_add` shape for this task? No — they would break the render. Convert them minimally now (Task 3 rewrites them):

```bash
_seg_limits() {
    local h="${SL_5H%%.*}" w="${SL_WK%%.*}"
    if [ -n "$h" ]; then
        _thresh_color "$h" 70 90
        [ "$_COLOR" = "crit" ] && _invert lim-5h
        local label="${h}%"
        if [ "$h" -ge 50 ]; then
            _fmt_rest "$SL_5H_RESET"
            [ -n "$_REST" ] && label="$label · $_REST"
        fi
        _add "${ICON_5H}5h" lim-5h ink2 "" none
        _add "$label" lim-5h "$_COLOR" "" space
    fi
    if [ -n "$w" ]; then
        _thresh_color "$w" 70 90
        [ "$_COLOR" = "crit" ] && _invert lim-wk
        local wlabel="${w}%"
        if [ "$w" -ge 80 ]; then
            _fmt_rest "$SL_WK_RESET"
            [ -n "$_REST" ] && wlabel="$wlabel · $_REST"
        fi
        _add "${ICON_WK}wk" lim-wk ink2 "" none
        _add "$wlabel" lim-wk "$_COLOR" "" space
    fi
}
```

and in `_seg_fable` replace the final two lines (`_thresh_color … _add`) with:

```bash
    _thresh_color "$_FABLE_PCT" 70 90
    [ "$_COLOR" = "crit" ] && _invert lim-fable
    local label="${_FABLE_PCT}%"
    if [ "$_FABLE_PCT" -ge 80 ]; then
        _fmt_rest "$_FABLE_RESET"
        [ -n "$_REST" ] && label="$label · $_REST"
    fi
    _add "${ICON_FABLE}fable" lim-fable ink2 "" none
    _add "$label" lim-fable "$_COLOR" "" space
```

- [ ] **Step 6: Rewrite `_render`**

Replace the whole `_render` function (from its comment block through the closing `}`) with:

```bash
# --- render ----------------------------------------------------------------

# One line of capsules on the terminal's own background. Each group of items
# becomes one capsule: a rounded left cap, a fill space, the items (joined as
# each asked), a fill space, a rounded right cap; two default-background cells
# follow the identity capsule and one follows every other. The caps are
# Powerline glyphs (U+E0B6/U+E0B4) drawn as fill-coloured ink on the default
# background, so they read as the capsule's rounded ends; CS_STATUSLINE_CAPS=0
# drops the glyphs for a font without them and the fill spaces become square
# edges. A crit capsule takes the crit fill and paints every item critink bold.
# SGR bold is stateful, so every item emits its intensity (1 or 22) explicitly.
# No width accounting and no tail: the line ends at the last cap.
_render() {
    local n=${#_SEG_TEXT[@]}
    [ "$n" -gt 0 ] || return 0
    local i g="" out=""

    if [ "$LEVEL" = "plain" ]; then
        for ((i = 0; i < n; i++)); do
            if [ "${_SEG_GROUP[i]}" != "$g" ]; then
                [ -n "$g" ] && out+=" > "
                g="${_SEG_GROUP[i]}"
            else
                case "${_SEG_JOIN[i]}" in
                    dot)       out+=" · " ;;
                    pad|space) out+=" " ;;
                esac
            fi
            out+="${_SEG_TEXT[i]}"
        done
        printf '%s\n' "$out"
        return 0
    fi

    local esc=$'\033' reset=$'\033[0m'
    local capl=$'\xee\x82\xb6' capr=$'\xee\x82\xb4'   # U+E0B6, U+E0B4
    [ "${CS_STATUSLINE_CAPS:-1}" = "0" ] && { capl=""; capr=""; }
    local fill="" fillsgr="" capsgr="" ink weight
    out="$reset"
    for ((i = 0; i < n; i++)); do
        if [ "${_SEG_GROUP[i]}" != "$g" ]; then
            if [ -n "$g" ]; then
                out+="${esc}[${fillsgr}m "
                [ -n "$capr" ] && out+="${esc}[49;${capsgr}m${capr}"
                out+="$reset"
                if [ "$g" = "identity" ]; then out+="  "; else out+=" "; fi
            fi
            g="${_SEG_GROUP[i]}"
            fill=surface
            case "$_CRIT_GROUPS" in *" $g "*) fill=crit ;; esac
            _sgr 48 "$fill"; fillsgr="$_SGR"
            _sgr 38 "$fill"; capsgr="$_SGR"
            [ -n "$capl" ] && out+="${esc}[49;${capsgr}m${capl}"
            out+="${esc}[${fillsgr}m "
        else
            case "${_SEG_JOIN[i]}" in
                dot)   _sgr 38 ink2; out+="${esc}[${fillsgr};${_SGR};22m  ·  " ;;
                pad)   out+="${esc}[${fillsgr}m  " ;;
                space) out+="${esc}[${fillsgr}m " ;;
            esac
        fi
        ink="${_SEG_INK[i]}"; weight=22
        [ -n "${_SEG_BOLD[i]}" ] && weight=1
        if [ "$fill" = "crit" ]; then ink=critink; weight=1; fi
        _sgr 38 "$ink"
        out+="${esc}[${fillsgr};${_SGR};${weight}m${_SEG_TEXT[i]}"
    done
    out+="${esc}[${fillsgr}m "
    [ -n "$capr" ] && out+="${esc}[49;${capsgr}m${capr}"
    out+="$reset"
    printf '%s\n' "$out"
}
```

Delete `_build_dots`, `_build_wash`, `_build_gradient`, `_lerp_channel` and their comment blocks. Keep `_display_width` (the agent rows' `_truncate` uses it), `_parse_rgb_triplet`, `_luminance`, `_bg_shade`. Delete the `hairline`, `chiptext`, `periwinkle`, `slate`, `black` and `brandshade`-comment-only lines from all three `_sgr` arms EXCEPT `brandshade` itself (the pulse uses it); leave the eight session-palette lines and their KEEP IN SYNC comment exactly as they are. Delete `_read_session_color` and its comment (no caller remains once `_seg_session` stops painting the session colour). In `lib/40-state.sh` change the comment sentence `KEEP THE FORMAT IN SYNC WITH bin/cs-statusline's _read_session_color (a pure-bash copy on the render hot path) and hooks/session-start.sh's local_state_set.` to `KEEP THE FORMAT IN SYNC WITH hooks/session-start.sh's local_state_set.` Grep the file for `_SEG_BG`, `boldattention`, `chiptext`, `hairline`, `logosepfg`, `_GRADIENT`, `_WASH`, `_DOTS`, `_SESSION_COLOR`, `COLUMNS` and remove every remaining reference.

- [ ] **Step 7: Run the whole suite and rewrite the old pins**

Run: `bash tests/test_statusline.sh > /tmp/sl.out 2>&1; echo rc=$?; grep -E '^  FAIL' /tmp/sl.out`

The eleven new cases pass. Every remaining failure is an old pin; rewrite each by this table, keeping the test's intent:

| Old pin | New assert |
|---|---|
| `48;2;<session rgb>` or `48;2;79;91;140` or `48;2;138;134;236` (a fill on session/git/model) | `48;2;227;221;204;38;2;79;77;71;1m<text>` when the test exports `CS_TERM_BG_RGB="253;246;227"` (add that export); otherwise assert the item text is present and `assert_output_not_contains_f` the old fill |
| `240;242;255` (chiptext) | `38;2;79;77;71` on a light surface |
| `255;183;77` as `48;2;…` (amber fill) | `38;2;180;83;9` on the number, plus `assert_output_not_contains_f "48;2;255;183;77"` |
| `220;38;38` as `48;2;…` on a gauge (red fill) | `48;2;215;0;21` and `38;2;255;255;255;1m` on that capsule's items |
| `128;120;110` / `140;132;122` (unmeasured surface) | unchanged when the test has no `CS_TERM_BG_RGB`; the fill is still the taupe |
| `▏` or `hairline` | delete the assertion (the test should already be gone) |
| `◫ %7` | `◫ 7` |
| a plain full-line `assert_eq` with ` > ` between identity items | ` · ` between identity items, ` > ` before `◔ ctx`; healthy limits stay visible until Task 3, so keep ` > ◷ 5h 23% > ◑ wk 41%` in this task |
| `test_no_powerline_arrow` | keep as is: it pins U+E0B0/U+E0B1, which the caps are not |
| `test_segment_icons_are_unicode` | keep; if it asserts the badge, assert the mark instead |
| `test_logo_badge_is_brand_coral` | rewrite to assert `38;2;217;119;87;1m✳` and `assert_output_not_contains_f "48;2;217;119;87"` |
| `test_two_accents_default`, `test_git_branch_bold_slate_accent` | rename to `test_identity_items_are_bold_ink` and `test_git_branch_is_bold_ink_no_fill`; assert per row one |

Do not delete any test other than the ones Step 1 named. If a pin cannot be mapped by the table, stop and report it rather than deleting it.

Run again until: `rc=0` and `grep -c '^  FAIL' /tmp/sl.out` is 0. Then `bash tests/test_subagent_statusline.sh > /tmp/sub.out 2>&1; echo rc=$?` — expected 0 (the rows call `_paint` → `_sgr` only).

- [ ] **Step 8: Bash 3.2 parse and a by-hand render**

Run:
```bash
/bin/bash -n bin/cs-statusline && echo PARSE_OK
printf '%s' '{"session_name":"demo","model":{"display_name":"Fable 5.1"},"effort":{"level":"medium"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":52}}' \
  | COLORTERM=truecolor CS_TERM_THEME=light CS_TERM_BG_RGB="253;246;227" /bin/bash bin/cs-statusline
```
Expected: PARSE_OK; one line that, in the terminal, shows a rounded capsule `✳ demo · ✦ Fable 5.1 medium`, a gap, and `◔ ctx 52%` with an amber 52%. Paste the raw line (through `cat -v`) into the commit body.

- [ ] **Step 9: Commit**

```bash
git add bin/cs-statusline lib/40-state.sh tests/test_statusline.sh
git commit -m "feat(statusline): capsules — one identity capsule, ctx capsule, caps, no tail" \
  -m "Deleted tail and hairline tests: <list from Step 1>."
```

---

### Task 3: Limits gating, fable folded in, names honoured, default order

**Files:**
- Modify: `bin/cs-statusline` — `_seg_limits`, `_seg_fable`, `main`'s default list (~line 1661); `lib/10-help.sh:84`; `docs/configuration.md:60`; `docs/statusline.md:13`
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: Task 2's `_add`/`_invert`; `_fable_read` → `_FABLE_PCT`, `_FABLE_RESET`, `_FABLE_DUE`; `_fmt_rest` → `_REST`; `_thresh_color`.
- Produces: `_limits_render NAME PCT RESET GATE` (one capsule); `_seg_limits` (5h, wk, fable candidates; hot ones only, top two by percentage); `_seg_fable` (the fable candidate alone, when `limits` has not already rendered it); default list `logo,session,notes,mail,git,model,ctx,limits`.

- [ ] **Step 1: Write the failing gating tests**

Append above the `run_test` block:

```bash
# ============================================================================
# Limits: hidden until hot, tightest first, at most two, fable folded in
# ============================================================================

test_limits_hidden_below_seventy() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":69},"seven_day":{"used_percentage":69.9}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ◔ ctx 8%" "$out" "both windows at 69 stay hidden" || return 1
}

test_limits_one_hot_window_appears_alone() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":70}}}'
    local out; out=$(run_sl "$json")
    assert_eq "s > ◔ ctx 8% > ◑ wk 70%" "$out" "wk at 70 appears; healthy 5h does not" || return 1
}

test_limits_hot_window_is_amber_ink_then_crit_capsule() {
    export COLORTERM=truecolor
    export CS_TERM_BG_RGB="253;246;227"
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":75},"seven_day":{"used_percentage":12}}}'
    local out; out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;180;83;9;22m75%" "5h 75 is amber ink on the surface" || return 1
    json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":91},"seven_day":{"used_percentage":12}}}'
    out=$(run_sl "$json")
    assert_output_contains_f "$out" "48;2;215;0;21;38;2;255;255;255;1m◷ 5h" "5h 91 inverts its capsule" || return 1
    assert_output_contains_f "$out" "48;2;227;221;204;38;2;79;77;71;1ms" "identity is untouched" || return 1
}

test_limits_three_hot_show_top_two_descending() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":72},"seven_day":{"used_percentage":95}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains_f "$out" "◑ wk 95% > ✧ fable 85%" "wk then fable, highest first" || return 1
    assert_output_not_contains_f "$out" "5h" "the third window stays hidden" || return 1
}

test_limits_countdown_rules_survive_gating() {
    export NO_COLOR=1
    local json='{"session_name":"s","workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":72,"resets_at":1787816200},"seven_day":{"used_percentage":72,"resets_at":1787816200}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains_f "$out" "◷ 5h 72% · 1m" "5h shows its countdown once visible" || return 1
    assert_output_not_contains_f "$out" "wk 72% ·" "wk withholds the countdown below 80" || return 1
}

test_fable_folds_into_limits_and_keeps_polling_while_hidden() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 25 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains_f "$out" "fable 25%" "fable at 25 is hidden" || return 1
    # The read still happens: with the cache past next_poll_at and refresh
    # allowed, the segment kicks the refresher. Prove it by the kick's marker.
    _load_sl_functions
    export CS_USAGE_NO_REFRESH=1
    SL_MODEL_ID="claude-fable-5"; _NOW=1787816400; _SL_NOW_READY=1; LEVEL=plain
    _SEG_TEXT=(); _SEG_GROUP=(); _SEG_INK=(); _SEG_BOLD=(); _SEG_JOIN=(); _CRIT_GROUPS=""
    _seg_limits
    assert_eq "1" "${_FABLE_DUE:-}" "the cache was read and found due even though nothing rendered" || return 1
}

test_fable_named_alone_renders_only_the_fable_window() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    export CS_STATUSLINE_SEGMENTS="session,fable"
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"},"rate_limits":{"five_hour":{"used_percentage":95},"seven_day":{"used_percentage":95}}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s > ✧ fable 85%" "$out" "fable by name: its window, not the plan windows" || return 1
}

test_limits_and_fable_both_named_render_fable_once() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    export CS_STATUSLINE_SEGMENTS="session,limits,fable"
    seed_usage_cache org-abc 85 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_eq "s > ✧ fable 85%" "$out" "one fable capsule, not two" || return 1
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
    assert_eq "my-session ◫ 7 > ◔ ctx 8%" "$out" "named: the pane number without its %, inside identity" || return 1
}
```

Add nine `run_test` lines. The existing `test_pane_segment_shows_tmux_pane_id` becomes redundant with the last case: delete it and its `run_test`; keep the other three pane tests (they assert absence and stay true).

- [ ] **Step 2: Run and watch them fail**

Run: `bash tests/test_statusline.sh > /tmp/sl.out 2>&1; grep -E 'limits_hidden|one_hot|hot_window_is|three_hot|countdown_rules|fable_folds|fable_named|both_named|pane_off' /tmp/sl.out`
Expected: nine FAIL (healthy windows render; three windows render; fable renders at 25; `◫ 7` present by default).

- [ ] **Step 3: Implement the gated limits**

Replace `_seg_limits` and `_seg_fable` with:

```bash
# One rate-limit capsule: label in secondary ink, the number in the threshold
# colour, crit inverting the capsule. $4 is the usage floor above which the
# reset countdown is appended (5h at 50, the seven-day windows at 80: the
# coarse windows only make time-to-reset actionable near exhaustion).
_limits_render() {
    local name="$1" pct="$2" reset="$3" gate="$4" icon="$5"
    _thresh_color "$pct" 70 90
    [ "$_COLOR" = "crit" ] && _invert "lim-$name"
    local label="${pct}%"
    if [ "$pct" -ge "$gate" ]; then
        _fmt_rest "$reset"
        [ -n "$_REST" ] && label="$label · $_REST"
    fi
    _add "${icon}${name}" "lim-$name" ink2 "" none
    _add "$label" "lim-$name" "$_COLOR" "" space
}

# Read the Fable window into the candidate list. Model-scoped, so it is only
# ever a candidate on a Fable session; the cache read and the refresh kick run
# whether or not the capsule is shown, so a hidden window keeps polling at its
# floor. See _fable_read and _refresh_usage.
_fable_candidate() {
    _FABLE_KICKED=""
    case "${SL_MODEL_ID:-}" in claude-fable*) ;; *) return 0 ;; esac
    _fable_read
    if [ -n "$_FABLE_DUE" ] && [ "${CS_USAGE_NO_REFRESH:-}" != "1" ] \
        && command -v curl >/dev/null 2>&1; then
        _FABLE_KICKED=1
        ( "${BASH:-bash}" "$_SL_SELF" --refresh-usage >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
    [ -n "$_FABLE_PCT" ] || return 0
    _LIM_NAME+=("fable"); _LIM_PCT+=("$_FABLE_PCT"); _LIM_RESET+=("$_FABLE_RESET")
    _LIM_GATE+=(80); _LIM_ICON+=("$ICON_FABLE")
}

# Rate limits are hidden until hot: every window at or past 70 becomes a
# candidate, the two highest render highest-first, the rest stay hidden. Their
# arrival is the signal. The three windows are 5h and wk from stdin and, on a
# Fable session, the model-scoped weekly window from the usage cache.
_LIMITS_DONE=""
_seg_limits() {
    _LIM_NAME=(); _LIM_PCT=(); _LIM_RESET=(); _LIM_GATE=(); _LIM_ICON=()
    local h="${SL_5H%%.*}" w="${SL_WK%%.*}"
    if [ -n "$h" ]; then
        _LIM_NAME+=("5h"); _LIM_PCT+=("$h"); _LIM_RESET+=("$SL_5H_RESET"); _LIM_GATE+=(50); _LIM_ICON+=("$ICON_5H")
    fi
    if [ -n "$w" ]; then
        _LIM_NAME+=("wk"); _LIM_PCT+=("$w"); _LIM_RESET+=("$SL_WK_RESET"); _LIM_GATE+=(80); _LIM_ICON+=("$ICON_WK")
    fi
    [ -n "$_LIMITS_DONE" ] || _fable_candidate
    _LIMITS_DONE=1
    _limits_emit_hot
}

# The `fable` name alone: the Fable window only, unless `limits` already
# rendered it. Kept so a CS_STATUSLINE_SEGMENTS written for the old bar still
# shows the Fable window.
_seg_fable() {
    [ -z "$_LIMITS_DONE" ] || return 0
    _LIM_NAME=(); _LIM_PCT=(); _LIM_RESET=(); _LIM_GATE=(); _LIM_ICON=()
    _fable_candidate
    _LIMITS_DONE=1
    _limits_emit_hot
}

# Render the two hottest candidates at or past 70, highest first. At most
# three candidates, so a pass that picks the max twice is the whole sort; no
# subprocess, no bash 4 features.
_limits_emit_hot() {
    local n=${#_LIM_NAME[@]} shown=0 best i
    while [ "$shown" -lt 2 ]; do
        best=-1
        for ((i = 0; i < n; i++)); do
            [ -n "${_LIM_NAME[i]}" ] || continue
            [ "${_LIM_PCT[i]}" -ge 70 ] || continue
            if [ "$best" -lt 0 ] || [ "${_LIM_PCT[i]}" -gt "${_LIM_PCT[best]}" ]; then best=$i; fi
        done
        [ "$best" -ge 0 ] || return 0
        _limits_render "${_LIM_NAME[best]}" "${_LIM_PCT[best]}" "${_LIM_RESET[best]}" \
            "${_LIM_GATE[best]}" "${_LIM_ICON[best]}"
        _LIM_NAME[best]=""
        shown=$((shown + 1))
    done
}
```

Delete the old `_seg_fable` body entirely (the new one above replaces it; its `_FABLE_KICKED` contract moves into `_fable_candidate`). Grep the tests for `_FABLE_KICKED` and `_seg_fable` unit calls: a test that calls `_seg_fable` directly to check the kick must now call `_fable_candidate` — update the call, not the assertion.

Change the default in `main`:

```bash
    local segments="${CS_STATUSLINE_SEGMENTS:-logo,session,notes,mail,git,model,ctx,limits}"
```

And the three prose copies in the same commit: `lib/10-help.sh:84`, `docs/configuration.md:60`, `docs/statusline.md:13` — replace `logo,session,notes,mail,pane,git,model,ctx,limits,fable` with `logo,session,notes,mail,git,model,ctx,limits` (prose around them is Task 4's).

- [ ] **Step 4: Run the suite; fix the old limits and fable pins**

Run: `bash tests/test_statusline.sh > /tmp/sl.out 2>&1; echo rc=$?; grep -E '^  FAIL' /tmp/sl.out`

The nine pass. Old cases that assumed healthy limits render (`test_limits_neutral_when_healthy`, `test_all_segments_ordering_plain`, `test_happy_path_docs_fixture_plain`, `test_limits_threshold_per_block`, `test_limits_threshold_red`, the `test_fable_segment_*` cases, the `test_limits_file_*` cases if they read the bar's text) are rewritten by intent:

- "healthy is neutral" → "healthy is hidden": assert the window text is absent.
- "per block escalation" → seed one window hot and assert its capsule alone carries amber ink / crit fill; the healthy sibling absent.
- `test_fable_segment_only_on_fable`, `_absent_without_a_reading`: unchanged in intent; they pass or need only the `fable` text expectation.
- `test_fable_segment_renders_on_fable` at 42: becomes "hidden at 42", plus a sibling at 85 asserting `fable 85%`.
- `test_fable_segment_countdown_at_80`, `_matches_1m_variant`, `_escalates_colour`: seed ≥ 80/90 as they do; update `48;2;220;38;38` → `48;2;215;0;21`.
- `test_limits_file_*`: the files are written in `_parse_stdin`, independent of rendering; they must pass untouched. If one fails, the parse was broken — stop and report.

Loop until rc=0 and no FAIL. Then run `bash tests/test_subagent_statusline.sh`, `bash tests/test_install.sh`, `bash tests/test_doctor.sh`, `bash tests/test_queue.sh`, `bash tests/test_rotation.sh`, `bash tests/test_theme.sh`, each `> /tmp/x.out 2>&1; echo rc=$?` — all rc=0.

- [ ] **Step 5: Commit**

```bash
/bin/bash -n bin/cs-statusline && git add bin/cs-statusline lib/10-help.sh docs/configuration.md docs/statusline.md tests/test_statusline.sh \
  && git commit -m "feat(statusline): limits hidden until hot, fable folded in; pane and fable still honoured by name"
```

---

### Task 4: Docs, README, changelog

**Files:**
- Modify: `docs/statusline.md` (sections `## Segments`, `## Colors`, `## Full-width gradient`, `### Pinning the background`, `## Configuration`, and the opening example at lines 3–9), `docs/configuration.md:45-60`, `README.md:75`, `CHANGELOG.md` Unreleased
- Test: `tests/test_statusline.sh` (the docs-sync case already passes; add one pin for the new tunable)

**Interfaces:**
- Consumes: the shipped behaviour of Tasks 1–3.
- Produces: nothing code-facing.

- [ ] **Step 1: Write the failing docs pin**

Append above the `run_test` block, plus its `run_test`:

```bash
test_caps_switch_is_documented() {
    assert_file_contains "$SCRIPT_DIR/../docs/configuration.md" "CS_STATUSLINE_CAPS" \
        "the caps switch must be in the env reference" || return 1
    assert_file_contains "$SCRIPT_DIR/../docs/statusline.md" "CS_STATUSLINE_CAPS" \
        "the caps switch must be in the design doc's Configuration section" || return 1
}
```

Run: `bash tests/test_statusline.sh 2>&1 | grep caps_switch` — expected FAIL.

- [ ] **Step 2: Rewrite `docs/statusline.md`**

Opening (lines 3–9): replace the description and example with:

```markdown
`cs-statusline` is the Claude Code status line shipped with cs. It reads the JSON Claude Code pipes to the registered `statusLine.command` on every render and prints exactly one line of rounded capsules on the terminal's own background.

```
 ✳ claude-sessions  ·  ⎇ main↑1 +2!1  ·  ✦ Fable 5.1 medium    ◔ ctx 42%   ◑ wk 84% · 5d16h 
```

One capsule carries identity — the Claude mark, the session, the branch, the model — and one carries the context gauge. Rate-limit capsules appear only when a window is hot. Colour is state: amber ink on a number past its warn threshold, and the capsule inverts to red at crit. The plain form (`NO_COLOR=1`) is `claude-sessions · ⎇ main↑1 +2!1 · ✦ Fable 5.1 medium > ◔ ctx 42% > ◑ wk 84% · 5d16h`.
```

`## Segments`: replace the default-order sentence and the table with the spec's Segments table (`docs/superpowers/specs/2026-09-13-statusbar-capsules-design.md`, section "Segments"), carrying each row's data source column from the current table (`.cs/local/attention`, `.cs/local/queue/`, `mail/new/*.json`, `TMUX_PANE`, one `git status` call, stdin fields, the usage cache). Keep the paragraph about `cost` being off by default; add that `pane` and `fable` are off by default and render when named. Add after the table the paragraph from the spec beginning "The limits group folds the three windows into one rule" and the one beginning "The two files the render writes".

`## Colors`: replace the section body with the spec's Colour section: the token table, the derived-surface paragraph, the `amber`-is-ink paragraph (naming `amber` as the token, per departure 3), the session-palette KEEP IN SYNC note, and the removed-tokens sentence. Then add:

```markdown
Capsule ends are the Powerline glyphs U+E0B6 and U+E0B4, drawn as fill-coloured ink on the terminal's default background so they read as rounded ends. They need a font that carries them (any Nerd Font does); cs cannot probe a font, so `CS_STATUSLINE_CAPS=0` drops the glyphs and the capsules become square chips with the same spacing. Caps render at every colour level — the cap's ink is the capsule's fill, which 256-colour and basic terminals both have — and never in plain mode.
```

`## Full-width gradient`: delete the section. `### Pinning the background`: replace its first sentence with "A measured background always outranks the assumption, and supplying one by hand is how the capsule surface becomes an exact shade of your terminal rather than a shade of the theme's guess." — the rest stands. `## Configuration`: add a `CS_STATUSLINE_CAPS` row/line matching the section's existing shape (read it first), and update any sentence naming `COLUMNS` or the fade. `## Subagent rows`: if it names the amber or red RGB, update to the ink values; otherwise leave it.

- [ ] **Step 3: `docs/configuration.md`**

Replace lines 49–53 (the `CS_TERM_BG_RGB` comment) with:

```sh
# Override the terminal's real background color (default: auto-detected via
# the same OSC 11 query as CS_TERM_THEME, when it succeeds). The statusline's
# capsule surface is a shade of it; unset, the surface is a shade of the
# theme's assumed background instead.
```

After the `CS_STATUSLINE_SEGMENTS` line add:

```sh
# Draw the capsules with square ends instead of the Powerline rounded caps
# (U+E0B6/U+E0B4), for a font that lacks the glyphs
export CS_STATUSLINE_CAPS="0"
```

- [ ] **Step 4: `README.md:75`**

Replace the sentence from "renders Claude Code's status bar as one line of squared pills:" through "and 5-hour/weekly rate limits (each gaining a reset countdown as it fills)" with:

"renders Claude Code's status bar as one line of rounded capsules on the terminal's own background: an identity capsule (the Claude mark, pulsing until your next prompt; the session name; a queued-task count and an unread cross-session mail count when there are any; the git branch with ahead/behind and dirty counts; the model and effort), a context capsule, and rate-limit capsules that appear only when a 5-hour or weekly window is hot (each gaining a reset countdown as it fills). Colour is state: amber ink past a warn threshold, a red capsule at crit"

Leave the rest of the paragraph (the fable sentence adjusts: "it folds Fable's own weekly window into the same rule" replaces "it adds a `fable` chip for Fable's own weekly window").

- [ ] **Step 5: `CHANGELOG.md`**

Under `## Unreleased`, add to `### Changed`:

```markdown
- The status bar is one line of rounded capsules on the terminal's own background. Identity — the Claude mark, session, branch, model — shares one neutral capsule; the context gauge has its own; rate-limit capsules appear only when a window reaches 70%, the tightest first and at most two, with Fable's model-scoped window folded into the same rule. Colour is state: amber ink on a number past its warn threshold, a red capsule at crit. The session name is neutral ink; its colour stays on the terminal tab. The default `CS_STATUSLINE_SEGMENTS` is `logo,session,notes,mail,git,model,ctx,limits`; `pane` (now `◫ 7`, without the `%`) and `fable` still render when named.
```

Add to `### Removed`:

```markdown
- The status bar's full-width tail (gradient, coverage wash and dots). The line ends at the last capsule.
```

Add a `### Added` heading (before `### Changed` if the file's other entries order it that way; check a released section) with:

```markdown
- `CS_STATUSLINE_CAPS=0` draws the status bar's capsules with square ends for a font without the Powerline cap glyphs.
```

- [ ] **Step 6: Run the docs pin and the suite; commit**

Run: `bash tests/test_statusline.sh > /tmp/sl.out 2>&1; echo rc=$?; grep -c '^  FAIL' /tmp/sl.out`
Expected: rc=0, 0.

```bash
git add docs/statusline.md docs/configuration.md README.md CHANGELOG.md tests/test_statusline.sh
git commit -m "docs(statusline): capsules, gated limits, the caps switch; changelog"
```

---

### Task 5: Gate, build, install, cold open

**Files:**
- Read-only except the install.

- [ ] **Step 1: Full suite, in the background**

Run: `CS_TEST_JOBS=4 bash tests/run_all.sh > /tmp/all.out 2>&1; echo rc=$? >> /tmp/all.out` via a background Bash call, then poll the file with `Monitor` or a later `tail -5 /tmp/all.out`; never `sleep` in the foreground.
Expected: the last lines report every suite passing (the count was 64 suites at `0023827`) and `rc=0`.

- [ ] **Step 2: Build and install**

Run: `./build.sh > /tmp/build.out 2>&1; echo rc=$?; ./install.sh > /tmp/install.out 2>&1; echo rc=$?; cs -doctor 2>&1 | grep -iE 'statusline|WARN|FAIL' | head`
Expected: both rc=0; doctor shows the statusline registered and no new WARN (two pre-existing WARNs are known: the iterm sidebar bridge, and an over-budget narrative of another actor).

- [ ] **Step 3: By-hand renders, both themes**

```bash
J='{"session_name":"demo","model":{"id":"claude-fable-5","display_name":"Fable 5.1"},"effort":{"level":"medium"},"workspace":{"current_dir":"/none"},"context_window":{"used_percentage":33},"rate_limits":{"five_hour":{"used_percentage":9},"seven_day":{"used_percentage":84,"resets_at":'$(( $(date +%s) + 490000 ))'}}}'
for t in light dark; do printf '%s' "$J" | COLORTERM=truecolor CS_TERM_THEME=$t CS_USAGE_NO_REFRESH=1 bash bin/cs-statusline; done
printf '%s' "$J" | NO_COLOR=1 bash bin/cs-statusline
```
Expected, in order: a light bar `✳ demo · ✦ Fable 5.1 medium   ◔ ctx 33%   ◑ wk 84% · 5d16h` with 84% in amber; the same on a dark strip; the plain line `demo · ✦ Fable 5.1 medium > ◔ ctx 33% > ◑ wk 84% · 5d16h`. Report the three lines through `cat -v` in the hand-back.

- [ ] **Step 4: Report**

Hand back: suite count and rc, the doctor lines, the three renders, and every departure the implementation took from this plan.

---

## Self-review

**Spec coverage.** Layout and states → Task 2 (render, gaps, caps, crit inversion) and Task 3 (hot limits). Segments table → Task 2 (logo, session, notes, mail, pane, git, model, ctx, cost) and Task 3 (limits, fable, default order, names). Colour table → Task 1. Render model → Task 2. Consumers → Tasks 1 (agent rows), 3 (help, sync), 4 (docs, README, changelog), 5 (other suites, install). Out of scope → none planned. Commits → Tasks 2, 3, 4 map to the spec's three; Task 1 is split out so the token change lands green on its own.

**Placeholders.** None: every code step carries the code; the pin-rewrite table in Task 2 Step 7 names the replacement for each class, and instructs a stop rather than a deletion when a pin has no row.

**Staged.** Task 2's `_add`, `_invert` and `_render` blocks were run as written with a stub `_sgr` returning the light-theme values; the bytes matched the gap, logo, crit-inversion and plain-mode assertions exactly (surface `227;221;204` measured through `_bg_shade`, `1m` and `5d16h` measured through `_fmt_rest`).

**Type consistency.** `_add TEXT GROUP INK WEIGHT JOIN` is used with the same positional shape in Tasks 2 and 3; `_invert GROUP` likewise; `_thresh_color` emits `crit`/`amber`/healthy in Task 1 and every later caller tests `[ "$_COLOR" = "crit" ]`; group names `identity`, `ctx`, `lim-5h`, `lim-wk`, `lim-fable`, `cost` are spelled the same in code and tests; `CAPL`/`CAPR`/`ESC_` are defined once in the suite before the tests that use them.
