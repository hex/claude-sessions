# cs-subagent-statusline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Style Claude Code's agent-panel rows so each subagent shows the model driving it, its own context-window usage, and its elapsed time.

**Architecture:** A new standalone `bin/cs-subagent-statusline` registered as Claude Code's `subagentStatusLine`. It sources its sibling `bin/cs-statusline` in library mode to reuse the color ladder, palette, and width helpers rather than making a third hand-synced copy. One `jq` pass parses stdin; one `jq -c` per row emits the `{"id","content"}` line Claude Code expects.

**Tech Stack:** POSIX shell targeting macOS stock `/bin/bash` 3.2, `jq`, BSD userland.

**Spec:** `docs/superpowers/specs/2026-07-10-cs-subagent-statusline-design.md`

## Global Constraints

- Must run on macOS stock `/bin/bash` 3.2 + BSD userland. No `local -A`, no `printf '%(…)T'`, no `source <()`, no `mapfile`, no GNU-only `sed`/`awk`/`stat`/`timeout` flags. CI (macos-latest) runs the whole suite under 3.2.
- Fail-open, always `exit 0`. Printing nothing is safe: an omitted `id` means Claude Code keeps that row's default rendering. A broken renderer must never break the agent panel.
- The `content` string MUST be built with `jq -c`. `ESC` is a JSON control character; `jq` escapes it as `\u001b`. A hand-rolled JSON string embeds a raw control byte, fails Claude Code's schema check, and is silently skipped.
- The runner kills the command at 5000 ms. No git, no network, no file reads in the hot path.
- `tests/test_lib.sh`'s `run_test` disables `errexit`. **Every assertion must end with `|| return 1`** or a failing assert passes silently.
- No emojis. Unicode Geometric Shapes and dingbats only, matching the existing `ICON_*` constants.
- Single-dash cs subcommands (`cs -statusline`); double-dash + short for POSIX modifiers.
- `bin/cs` is assembled from `lib/*.sh` by `./build.sh`. **Any `lib/` edit requires re-running `./build.sh` and committing the regenerated `bin/cs`.** `bin/cs-statusline` and `bin/cs-subagent-statusline` are NOT generated — they are hand-maintained standalone files.
- Every file starts with two `# ABOUTME: ` lines.

## File Structure

| File | Responsibility |
|---|---|
| `bin/cs-statusline` | Unchanged, except its final line becomes a library-mode guard. Owns the palette, color ladder, thresholds, width measurement. |
| `bin/cs-subagent-statusline` | **New.** Reads the subagent payload, builds one row per task, emits `{"id","content"}` lines. |
| `tests/test_subagent_statusline.sh` | **New.** Row content, thresholds, truncation, fail-open. |
| `tests/test_statusline.sh` | `_load_sl_functions` switches to library mode; adds a guard regression test. |
| `lib/70-statusline.sh` | `cs -statusline enable/disable` also manages the `subagentStatusLine` registration. |
| `lib/85-adopt-uninstall.sh` | Removes the new binary and its registration. |
| `lib/60-doctor.sh` | Reports the subagent row registration. |
| `install.sh` | Installs the new binary; adds its remote URL. |
| `tests/test_install.sh` | Install/uninstall parity count. |
| `docs/statusline.md`, `README.md` | Docs. |

---

### Task 1: Library-mode guard on cs-statusline

Sourcing `cs-statusline` must define its helpers without rendering. `tests/test_statusline.sh:54` currently neutralizes the entry point with `eval "$(sed 's/^main "\$@"$/:/' "$SL")"` — a regex matching the exact line `main "$@"`. Changing that line breaks the regex, and `main` would then execute during the existing suite. Fixing the loader is part of this task, not a follow-up.

**Files:**
- Modify: `bin/cs-statusline:748`
- Modify: `tests/test_statusline.sh:53-55`
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Produces: sourcing `bin/cs-statusline` with `CS_STATUSLINE_LIB=1` defines `_detect_level`, `_sgr`, `_thresh_color`, `_display_width`, and the `ICON_*` constants, sets `LEVEL="basic"` and `SL_THEME`, applies `set -uo pipefail`, and prints nothing.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_statusline.sh`, immediately before the `run_test` block at the end:

```bash
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
```

Register them by adding these three lines above `report_results` at the file's end:

```bash
run_test test_library_mode_defines_helpers_without_rendering
run_test test_library_mode_prints_nothing
run_test test_executed_directly_still_renders
```

`LEVEL=256` is the expected value because `setup()` exports `TERM="xterm-256color"` and unsets `COLORTERM`. `38;5;105` is `_sgr`'s 256-color periwinkle index, read from `bin/cs-statusline:206`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_subagent_statusline.sh 2>/dev/null; bash tests/test_statusline.sh`

Expected: `test_library_mode_prints_nothing` FAILS — sourcing today runs `main "$@"`, which blocks reading stdin or prints a fallback line. The other two may pass incidentally; all three must pass at the end.

- [ ] **Step 3: Add the guard**

In `bin/cs-statusline`, replace the final line:

```bash
main "$@"
```

with:

```bash
# Sourced with CS_STATUSLINE_LIB=1, this file is a library: the palette, color
# ladder, and width helpers load without rendering. `return` is not usable here
# because it is an error outside a function in an executed script.
[ "${CS_STATUSLINE_LIB:-}" = "1" ] || main "$@"
```

- [ ] **Step 4: Switch the test loader to library mode**

In `tests/test_statusline.sh`, replace:

```bash
# Source cs-statusline's functions without running main (the unconditional
# `main "$@"` tail is neutralized to `:`), so internal helpers can be unit
# tested directly instead of only through a full run_sl invocation.
_load_sl_functions() {
    eval "$(sed 's/^main "\$@"$/:/' "$SL")" 2>/dev/null
}
```

with:

```bash
# Source cs-statusline's functions without running main, so internal helpers can
# be unit tested directly instead of only through a full run_sl invocation.
_load_sl_functions() {
    CS_STATUSLINE_LIB=1 . "$SL" 2>/dev/null
}
```

- [ ] **Step 5: Run the full statusline suite**

Run: `bash tests/test_statusline.sh`
Expected: PASS, including every pre-existing test that used `_load_sl_functions`.

- [ ] **Step 6: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): library mode so siblings can reuse the palette"
```

---

### Task 2: Skeleton — fail-open, disable, empty tasks

**Files:**
- Create: `bin/cs-subagent-statusline`
- Create: `tests/test_subagent_statusline.sh`

**Interfaces:**
- Consumes: library mode from Task 1.
- Produces: `_parse_tasks <json>` prints one TSV line per task (`id`, `cols`, `model`, `name`, `desc`, `ctx`, `elapsed_s`) and returns non-zero when `jq` is missing or stdin does not parse. `render_rows` is the entry point (named to avoid clobbering `cs-statusline`'s `main`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_subagent_statusline.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for bin/cs-subagent-statusline, the Claude Code agent-panel row renderer
# ABOUTME: Covers row content, model mapping, ctx thresholds, truncation, and fail-open posture

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SSL="$SCRIPT_DIR/../bin/cs-subagent-statusline"

# startTime is pinned against CS_SUBAGENT_NOW_MS so elapsed is deterministic.
# 1752148800000 ms + 134 s -> "2m14s".
NOW_MS=1752148934000
FIXTURE_ONE='{"columns":96,"tasks":[{"id":"t1","name":"bundle-recon","type":"general-purpose","status":"running","description":"Spelunk CC bundle","startTime":1752148800000,"model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":24000}]}'
FIXTURE_EMPTY='{"columns":96,"tasks":[]}'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in
            CS_*|CLAUDE_*|NO_COLOR|COLORTERM|TERM_PROGRAM|FORCE_COLOR)
                unset "$_v" 2>/dev/null || true ;;
        esac
    done < <(env)
    unset COLUMNS 2>/dev/null || true
    export TERM="xterm-256color"
    export CS_SUBAGENT_NOW_MS="$NOW_MS"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset NO_COLOR COLORTERM TERM_PROGRAM FORCE_COLOR CS_SUBAGENT_NOW_MS \
        CS_SUBAGENT_STATUSLINE_DISABLE CS_STATUSLINE_CTX_WARN CS_STATUSLINE_CTX_CRIT 2>/dev/null || true
}

# Run the row renderer with $1 as stdin JSON; prints its stdout.
run_ssl() {
    printf '%s' "$1" | bash "$SSL"
}

# Extract the .content of the row whose .id is $2, from the raw stdout in $1.
row_content() {
    printf '%s\n' "$1" | jq -r --arg id "$2" 'select(.id == $id) | .content'
}

test_empty_tasks_prints_nothing() {
    local out
    out=$(run_ssl "$FIXTURE_EMPTY")
    assert_eq "" "$out" "no tasks means no rows" || return 1
}

test_malformed_stdin_exits_clean() {
    local out rc
    out=$(printf 'not json' | bash "$SSL"); rc=$?
    assert_eq "0" "$rc" "malformed stdin must exit 0" || return 1
    assert_eq "" "$out" "malformed stdin must print nothing" || return 1
}

test_disable_env_prints_nothing() {
    export CS_SUBAGENT_STATUSLINE_DISABLE=1
    local out
    out=$(run_ssl "$FIXTURE_ONE")
    assert_eq "" "$out" "CS_SUBAGENT_STATUSLINE_DISABLE=1 silences the renderer" || return 1
}

run_test test_empty_tasks_prints_nothing
run_test test_malformed_stdin_exits_clean
run_test test_disable_env_prints_nothing
report_results
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_subagent_statusline.sh`
Expected: FAIL — `bin/cs-subagent-statusline` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `bin/cs-subagent-statusline`:

```bash
#!/usr/bin/env bash
# ABOUTME: Claude Code subagentStatusLine command — one styled row per running subagent
# ABOUTME: Reads {columns,tasks[]} on stdin, prints one {"id","content"} JSON line per row

# cs-statusline owns the palette, the color ladder, and width measurement.
# Sourcing it in library mode defines them without rendering the main bar, so
# the two scripts cannot drift. It also applies `set -uo pipefail`.
CS_STATUSLINE_LIB=1 . "$(dirname "$0")/cs-statusline" 2>/dev/null || exit 0

# U+2937 arrow pointing rightwards then curving downwards: the row hangs off the
# main thread. ICON_MODEL (✦), ICON_CTX (◔) and ICON_5H (◷) come from the source.
ICON_ROW=$'\xe2\xa4\xb7 '

_STDIN=""
_TASKS=""

_read_all_stdin() {
    _STDIN=""
    [ -t 0 ] && return 0
    IFS= read -r -d '' _STDIN 2>/dev/null || true
}

# One jq pass: every field the rows need, one TSV line per task. @tsv escapes
# any literal tab or newline inside a description, so the fields stay aligned.
# ctx% and elapsed are computed here to keep the hot path fork-free.
# CS_SUBAGENT_NOW_MS pins the clock for tests; production uses jq's `now`.
_parse_tasks() {
    local input="$1"
    command -v jq >/dev/null 2>&1 || return 1
    [ -n "$input" ] || return 1
    _TASKS=$(printf '%s' "$input" | jq -r --arg nowms "${CS_SUBAGENT_NOW_MS:-}" '
        ($nowms | if . == "" then (now * 1000) else tonumber end) as $now
        | (.columns // 0) as $cols
        | .tasks[]?
        | [ (.id // ""),
            ($cols | tostring),
            (.model // ""),
            (.name // .type // ""),
            (.description // ""),
            (if (.contextWindowSize // 0) > 0
             then ((.tokenCount // 0) * 100 / .contextWindowSize | floor | tostring)
             else "" end),
            (if .startTime then (($now - .startTime) / 1000 | floor | tostring) else "" end)
          ] | @tsv' 2>/dev/null) || return 1
}

render_rows() {
    [ "${CS_SUBAGENT_STATUSLINE_DISABLE:-}" = "1" ] && exit 0
    _read_all_stdin
    _parse_tasks "$_STDIN" || exit 0
    [ -n "$_TASKS" ] || exit 0
    _detect_level
}

render_rows "$@"
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `chmod +x bin/cs-subagent-statusline && bash tests/test_subagent_statusline.sh`
Expected: PASS, 3/3.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-subagent-statusline tests/test_subagent_statusline.sh
git commit -m "feat(statusline): subagent row renderer skeleton with fail-open posture"
```

---

### Task 3: Row content in plain mode

**Files:**
- Modify: `bin/cs-subagent-statusline`
- Test: `tests/test_subagent_statusline.sh`

**Interfaces:**
- Consumes: `_parse_tasks` from Task 2.
- Produces: `_model_display <id>` sets `_MODEL`; `_fmt_elapsed <seconds>` sets `_ELAPSED`; `_emit_row <id> <content>` prints one `jq -c` line.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_subagent_statusline.sh`, before the `run_test` block:

```bash
test_row_has_model_name_desc_ctx_elapsed() {
    export NO_COLOR=1
    local out c
    out=$(run_ssl "$FIXTURE_ONE")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "Sonnet 5" "model display name" || return 1
    assert_output_contains "$c" "bundle-recon" "agent name" || return 1
    assert_output_contains "$c" "Spelunk CC bundle" "description" || return 1
    assert_output_contains "$c" "ctx 12%" "24000/200000 is 12 percent" || return 1
    assert_output_contains "$c" "2m14s" "134 seconds elapsed" || return 1
}

test_no_model_means_no_model_and_no_ctx() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","startTime":1752148800000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "ctx" "no contextWindowSize means no ctx gauge" || return 1
    assert_output_not_contains "$c" "✦" "no model means no model chip" || return 1
    assert_output_contains "$c" "d" "description still renders" || return 1
}

test_zero_context_window_is_not_a_divide_by_zero() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":0,"tokenCount":5}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "ctx" "contextWindowSize 0 yields no gauge" || return 1
    assert_output_contains "$c" "Sonnet 5" "model still renders" || return 1
}

test_unknown_model_id_renders_verbatim() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-zephyr-9"}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "claude-zephyr-9" "an unknown model degrades to its id, never to invisible" || return 1
}

test_missing_name_falls_back_to_type() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":96,"tasks":[{"id":"t1","type":"general-purpose","description":"d"}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "general-purpose" "type is the fallback for a missing name" || return 1
}

test_elapsed_over_an_hour_uses_hours() {
    export NO_COLOR=1
    local fx out c
    # startTime is 3900 s (1h05m) before CS_SUBAGENT_NOW_MS.
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","startTime":1752145034000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "1h05m" "3900 seconds is 1h05m" || return 1
}
```

Register each with a `run_test` line above `report_results`.

The expected values are worked by hand from the spec, not recomputed from the code: `24000 * 100 / 200000 = 12`; `1752148934 - 1752148800 = 134 s = 2m14s`; `1752148934 - 1752145034 = 3900 s = 1h05m`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_subagent_statusline.sh`
Expected: FAIL — `render_rows` prints nothing yet, so `row_content` is empty.

- [ ] **Step 3: Implement row assembly**

In `bin/cs-subagent-statusline`, add above `render_rows`:

```bash
# Resolved model ids arrive here, not the display names the main bar receives.
# Prefix matching so dated suffixes and `[1m]` context markers resolve. An
# unrecognised id renders verbatim: a new model must degrade to ugly, not absent.
_model_display() {
    case "$1" in
        "")                _MODEL="" ;;
        claude-fable-5*)   _MODEL="Fable 5" ;;
        claude-opus-4-8*)  _MODEL="Opus 4.8" ;;
        claude-sonnet-5*)  _MODEL="Sonnet 5" ;;
        claude-haiku-4-5*) _MODEL="Haiku 4.5" ;;
        *)                 _MODEL="$1" ;;
    esac
}

# Seconds since the agent started, as "2m14s" or "1h05m". A negative value
# (clock skew) is rejected by the digit guard along with every non-number.
_fmt_elapsed() {
    _ELAPSED=""
    case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
    local s="$1" h m
    if [ "$s" -ge 3600 ]; then
        h=$((s / 3600)); m=$(((s % 3600) / 60))
        _ELAPSED="${h}h$(printf '%02d' "$m")m"
    else
        m=$((s / 60))
        _ELAPSED="${m}m$(printf '%02d' $((s % 60)))s"
    fi
}

# jq -c escapes the ESC byte as \u001b. A hand-rolled JSON string would embed a
# raw control character, fail Claude Code's schema check, and drop the row.
_emit_row() {
    jq -cn --arg id "$1" --arg content "$2" '{id: $id, content: $content}' 2>/dev/null
}
```

Then replace the body of `render_rows` after `_detect_level` with:

```bash
    local id cols model name desc ctx elapsed
    while IFS=$'\t' read -r id cols model name desc ctx elapsed; do
        [ -n "$id" ] || continue

        _model_display "$model"
        _fmt_elapsed "$elapsed"

        local content="$ICON_ROW"
        [ -n "$_MODEL" ] && content="${content}${ICON_MODEL}${_MODEL}  "
        [ -n "$name" ]   && content="${content}${name}"
        [ -n "$desc" ]   && content="${content} · ${desc}"
        [ -n "$ctx" ]    && content="${content}  ${ICON_CTX}ctx ${ctx}%"
        [ -n "$_ELAPSED" ] && content="${content}  ${ICON_5H}${_ELAPSED}"

        _emit_row "$id" "$content"
    done <<< "$_TASKS"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_subagent_statusline.sh`
Expected: PASS, 9/9.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-subagent-statusline tests/test_subagent_statusline.sh
git commit -m "feat(statusline): subagent rows show model, context, and elapsed"
```

---

### Task 4: Colors and the JSON escaping contract

**Files:**
- Modify: `bin/cs-subagent-statusline`
- Test: `tests/test_subagent_statusline.sh`

**Interfaces:**
- Consumes: `_sgr`, `_thresh_color`, `LEVEL` from library mode.
- Produces: `_paint <text> <colorname>` sets `_PAINTED`.

`_sgr`'s `case` has no `plain` arm — `LEVEL="plain"` falls through to `*` and yields basic ANSI. The caller must branch on `LEVEL` itself, exactly as `_render` does at `bin/cs-statusline:567`.

`_thresh_color`'s default healthy color is `surface`, a tint derived from the terminal background. As a *foreground* it would be near-invisible against the background it was derived from, so the rows pass an explicit healthy color.

- [ ] **Step 1: Write the failing tests**

```bash
test_content_escapes_esc_as_unicode() {
    export COLORTERM=truecolor
    local out
    out=$(run_ssl "$FIXTURE_ONE")
    assert_output_contains "$out" 'u001b' "the raw line must carry the escaped form" || return 1
    printf '%s' "$out" | LC_ALL=C grep -q $'\033' && {
        echo "  FAIL: raw ESC byte leaked into the JSON line"; return 1; }
    printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || {
        echo "  FAIL: emitted line is not valid JSON"; return 1; }
}

test_ctx_escalates_to_amber_then_red() {
    export COLORTERM=truecolor
    local fx out c
    # 110000/200000 = 55% -> past warn (50), below crit (80) -> amber 255;183;77
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":110000}]}'
    out=$(run_ssl "$fx"); c=$(row_content "$out" "t1")
    assert_output_contains "$c" "38;2;255;183;77" "55% context renders amber" || return 1

    # 170000/200000 = 85% -> past crit (80) -> red 220;38;38
    fx='{"columns":96,"tasks":[{"id":"t1","name":"a","description":"d","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":170000}]}'
    out=$(run_ssl "$fx"); c=$(row_content "$out" "t1")
    assert_output_contains "$c" "38;2;220;38;38" "85% context renders red" || return 1
}

test_plain_mode_has_no_escape_sequences() {
    export NO_COLOR=1
    local out c
    out=$(run_ssl "$FIXTURE_ONE")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "38;2;" "NO_COLOR must suppress SGR parameters" || return 1
    assert_output_contains "$c" "ctx 12%" "text survives in plain mode" || return 1
}
```

Expected RGB values are read from `bin/cs-statusline`: amber `255;183;77` (line 158), red `220;38;38` (line 147). Thresholds 50/80 are `CS_STATUSLINE_CTX_WARN`/`CRIT` defaults from `bin/cs-statusline:419`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_subagent_statusline.sh`
Expected: `test_ctx_escalates_to_amber_then_red` and `test_content_escapes_esc_as_unicode` FAIL — no colors are emitted yet.

- [ ] **Step 3: Implement painting**

Add above `render_rows`:

```bash
# Rows sit on the terminal background inside Claude Code's own panel, not on
# self-backgrounded pills, so only foreground colors are used. LEVEL=plain is
# handled here, not in _sgr, whose case falls through to basic ANSI.
_paint() {
    if [ "$LEVEL" = "plain" ]; then
        _PAINTED="$1"
        return 0
    fi
    _sgr 38 "$2"
    _PAINTED=$'\033['"$_SGR"'m'"$1"$'\033[0m'
}
```

Replace the content assembly inside the `while` loop with:

```bash
        local content="$ICON_ROW"
        if [ -n "$_MODEL" ]; then
            _paint "${ICON_MODEL}${_MODEL}" periwinkle
            content="${content}${_PAINTED}  "
        fi
        if [ -n "$name" ]; then
            _paint "$name" chiptext
            content="${content}${_PAINTED}"
        fi
        if [ -n "$desc" ]; then
            _paint "· ${desc}" hairline
            content="${content} ${_PAINTED}"
        fi
        if [ -n "$ctx" ]; then
            _thresh_color "$ctx" "${CS_STATUSLINE_CTX_WARN:-50}" "${CS_STATUSLINE_CTX_CRIT:-80}" hairline
            _paint "${ICON_CTX}ctx ${ctx}%" "$_COLOR"
            content="${content}  ${_PAINTED}"
        fi
        if [ -n "$_ELAPSED" ]; then
            _paint "${ICON_5H}${_ELAPSED}" hairline
            content="${content}  ${_PAINTED}"
        fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_subagent_statusline.sh`
Expected: PASS, 12/12.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-subagent-statusline tests/test_subagent_statusline.sh
git commit -m "feat(statusline): color subagent rows on the shared threshold ladder"
```

---

### Task 5: Width budget and truncation

The row must fit `columns`. Fixed elements are measured first; the description takes the remainder. When space runs short the description is truncated, then dropped — the ctx gauge outranks the tail of a description, because a runaway agent's context percentage is the thing worth seeing.

**Files:**
- Modify: `bin/cs-subagent-statusline`
- Test: `tests/test_subagent_statusline.sh`

**Interfaces:**
- Consumes: `_display_width` (sets `_WIDTH`).
- Produces: `_truncate <text> <max_cols>` sets `_TRUNC`.

- [ ] **Step 1: Write the failing tests**

```bash
test_narrow_columns_truncates_description_keeps_ctx() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":56,"tasks":[{"id":"t1","name":"bundle-recon","description":"Spelunk the Claude Code bundle for the row contract","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":24000,"startTime":1752148800000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "ctx 12%" "the ctx gauge survives a narrow row" || return 1
    assert_output_contains "$c" "…" "an over-long description is elided" || return 1
    assert_output_not_contains "$c" "row contract" "the description tail is cut" || return 1
    printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || {
        echo "  FAIL: truncated row is not valid JSON"; return 1; }
}

test_very_narrow_columns_drops_description_entirely() {
    export NO_COLOR=1
    local fx out c
    fx='{"columns":34,"tasks":[{"id":"t1","name":"bundle-recon","description":"Spelunk the bundle","model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":24000}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_not_contains "$c" "Spelunk" "no room for a description" || return 1
    assert_output_contains "$c" "ctx 12%" "the gauge is kept over the description" || return 1
}

test_absent_columns_renders_untruncated() {
    export NO_COLOR=1
    local fx out c
    fx='{"tasks":[{"id":"t1","name":"a","description":"a description that is not short"}]}'
    out=$(run_ssl "$fx")
    c=$(row_content "$out" "t1")
    assert_output_contains "$c" "a description that is not short" "no columns means no budget to enforce" || return 1
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_subagent_statusline.sh`
Expected: the two truncation tests FAIL — the full description is currently emitted at any width.

- [ ] **Step 3: Implement the budget**

Add above `render_rows`:

```bash
# Cut $1 to at most $2 display columns, marking the cut with a single ellipsis.
# `${s%?}` removes one character (not one byte) under a UTF-8 locale, and
# _display_width counts characters by skipping UTF-8 continuation bytes.
_truncate() {
    local s="$1" max="$2"
    _display_width "$s"
    if [ "$_WIDTH" -le "$max" ]; then
        _TRUNC="$s"
        return 0
    fi
    if [ "$max" -lt 2 ]; then
        _TRUNC=""
        return 0
    fi
    while [ -n "$s" ]; do
        s="${s%?}"
        _display_width "$s"
        [ "$_WIDTH" -le $((max - 1)) ] && break
    done
    _TRUNC="${s}…"
}
```

Inside the loop, between `_fmt_elapsed` and the content assembly, insert the budget calculation. It measures the *plain* text, because SGR sequences occupy no display cells:

```bash
        # The description is the only elastic field. Everything else is measured
        # first; what is left over is its budget. Below the floor it is dropped
        # rather than reduced to an ellipsis and one letter.
        if [ -n "$desc" ] && [ "${cols:-0}" -gt 0 ]; then
            local fixed="$ICON_ROW"
            [ -n "$_MODEL" ]   && fixed="${fixed}${ICON_MODEL}${_MODEL}  "
            [ -n "$name" ]     && fixed="${fixed}${name}"
            [ -n "$ctx" ]      && fixed="${fixed}  ${ICON_CTX}ctx ${ctx}%"
            [ -n "$_ELAPSED" ] && fixed="${fixed}  ${ICON_5H}${_ELAPSED}"
            _display_width "$fixed"
            local avail=$((cols - _WIDTH - 3))   # 3 = the " · " that joins it
            if [ "$avail" -lt 8 ]; then
                desc=""
            else
                _truncate "$desc" "$avail"
                desc="$_TRUNC"
            fi
        fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_subagent_statusline.sh`
Expected: PASS, 15/15.

- [ ] **Step 5: Verify bash 3.2 compatibility**

Run: `/bin/bash --version | head -1 && /bin/bash -n bin/cs-subagent-statusline && /bin/bash tests/test_subagent_statusline.sh`
Expected: version reports 3.2.x; syntax check silent; suite PASSes.

- [ ] **Step 6: Commit**

```bash
git add bin/cs-subagent-statusline tests/test_subagent_statusline.sh
git commit -m "feat(statusline): budget subagent row width, gauge outranks description"
```

---

### Task 6: Install, enable/disable, uninstall, doctor

Registration is snapshot-read by Claude Code at session start, so enabling requires a restart. Say so at the point of enabling — a silent no-op is the worst outcome here.

**Files:**
- Modify: `install.sh:79` (URL), `install.sh:198-211` (install block)
- Modify: `lib/70-statusline.sh:4-55`
- Modify: `lib/85-adopt-uninstall.sh:169`, `:198-206`
- Modify: `lib/60-doctor.sh:275`
- Modify: `tests/test_install.sh` (parity count)
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: `bin/cs-subagent-statusline` from Tasks 2-5.
- Produces: `_strip_subagent_statusline_registration <settings_file>` returning 0 stripped / 1 foreign-or-absent / 2 write failure, mirroring `_strip_statusline_registration`.

`endswith("/cs-statusline")` does not match `/cs-subagent-statusline` (its last 14 characters are `ent-statusline`), so the two strippers cannot cross-fire.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_statusline.sh`:

```bash
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
```

Register all three with `run_test` lines.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_statusline.sh`
Expected: all three FAIL — `subagentStatusLine` is never written, and no restart notice is printed.

- [ ] **Step 3: Extend lib/70-statusline.sh**

Add after `_strip_statusline_registration`:

```bash
_strip_subagent_statusline_registration() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 1
    jq -e '.subagentStatusLine.command // "" | endswith("/cs-subagent-statusline")' \
        "$settings_file" >/dev/null 2>&1 || return 1
    local _tmp
    _tmp=$(mktemp)
    if jq 'del(.subagentStatusLine)' "$settings_file" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$settings_file"
        return 0
    fi
    rm -f "$_tmp"
    return 2
}
```

In `run_statusline_cmd`, add beside the existing `bin` local:

```bash
    local subbin="$HOME/.local/bin/cs-subagent-statusline"
```

Replace the `enable` arm's `jq` invocation and its `info` with:

```bash
            if jq --arg cmd "$bin" --arg subcmd "$subbin" \
                '.statusLine = {type: "command", command: $cmd, refreshInterval: 1}
                 | .subagentStatusLine = {type: "command", command: $subcmd}' \
                "$settings" > "$_tmp" 2>/dev/null; then
                mv "$_tmp" "$settings"
                info "Registered cs-statusline as the Claude Code status line"
                info "Registered cs-subagent-statusline for the agent panel rows"
                info "Claude Code reads both at startup: restart it to see them."
            else
```

Add `[ -x "$subbin" ] || warn "cs-subagent-statusline binary not found at $subbin (run install.sh first)"` beside the existing `bin` check.

Replace the `disable` arm's body with:

```bash
            [ -f "$settings" ] || { info "No settings.json; nothing to disable."; return 0; }
            _strip_statusline_registration "$settings"
            case $? in
                0) info "Removed the cs-statusline registration" ;;
                1) info "Status line is not cs-statusline; leaving it untouched." ;;
                *) error "Could not update $settings" ;;
            esac
            _strip_subagent_statusline_registration "$settings"
            case $? in
                0) info "Removed the cs-subagent-statusline registration" ;;
                1) : ;;
                *) error "Could not update $settings" ;;
            esac
```

- [ ] **Step 4: Rebuild bin/cs**

`lib/` changed, so the assembled `bin/cs` is stale.

Run: `./build.sh`
Expected: `Built bin/cs from N lib fragments (…)`.

- [ ] **Step 5: Extend install.sh**

After line 79 add:

```bash
CS_SUBAGENT_STATUSLINE_URL="${REPO_URL}/bin/cs-subagent-statusline"
```

After the existing `chmod +x "$INSTALL_DIR/cs-statusline"` block, mirror it:

```bash
# Install cs-subagent-statusline (Claude Code agent-panel rows). It sources
# cs-statusline for the shared palette, so the two must land in the same dir.
installed "cs-subagent-statusline" "$INSTALL_DIR/cs-subagent-statusline"
if [ "$INSTALL_METHOD" = "local" ]; then
    cp "$SCRIPT_DIR/bin/cs-subagent-statusline" "$INSTALL_DIR/cs-subagent-statusline"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$CS_SUBAGENT_STATUSLINE_URL" -o "$INSTALL_DIR/cs-subagent-statusline" \
        || error "Failed to download cs-subagent-statusline"
else
    wget -q "$CS_SUBAGENT_STATUSLINE_URL" -O "$INSTALL_DIR/cs-subagent-statusline" \
        || error "Failed to download cs-subagent-statusline"
fi
chmod +x "$INSTALL_DIR/cs-subagent-statusline"
```

Match the surrounding style exactly — read lines 198-211 first and mirror their `if/elif/else` shape rather than pasting this verbatim if it differs.

- [ ] **Step 6: Extend uninstall and doctor**

In `lib/85-adopt-uninstall.sh`, add `cs-subagent-statusline` to the path list at line 169, and mirror the removal block at lines 198-206:

```bash
    if [ -f "$install_dir/cs-subagent-statusline" ]; then
        rm "$install_dir/cs-subagent-statusline"
        info "Removed $install_dir/cs-subagent-statusline"
    fi
```

and strip its registration alongside the existing one.

In `lib/60-doctor.sh`, beside the `*/cs-statusline)` arm, report the subagent registration: OK when registered and executable, FAIL when it points at a missing binary, informational otherwise.

Rebuild: `./build.sh`

- [ ] **Step 7: Update the install parity test**

`tests/test_install.sh` asserts that every installed artifact is removed by uninstall. Add `cs-subagent-statusline` to whichever list drives that check, and bump the expected count.

Run: `bash tests/test_install.sh`
Expected: PASS with the new count.

- [ ] **Step 8: Run every affected suite**

Run: `bash tests/test_statusline.sh && bash tests/test_subagent_statusline.sh && bash tests/test_install.sh && bash tests/test_doctor.sh`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add bin/cs lib/70-statusline.sh lib/85-adopt-uninstall.sh lib/60-doctor.sh \
        install.sh tests/test_statusline.sh tests/test_install.sh
git commit -m "feat(statusline): install and register the subagent row renderer"
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/statusline.md`
- Modify: `README.md`

- [ ] **Step 1: Add a "Subagent rows" section to docs/statusline.md**

Place it after the "Colors" section. It must state:

- What the rows show and in what order, with a rendered example.
- That the rows keep rendering while you view an agent's transcript, because Claude Code retains the viewed task.
- That a "you are here" marker is impossible: `viewingAgentTaskId` is not in the payload.
- That `cs -statusline enable` registers both, and **Claude Code must be restarted** because the registration is read at startup.
- The `CS_SUBAGENT_STATUSLINE_DISABLE=1` escape hatch.
- That `bin/cs-subagent-statusline` sources `bin/cs-statusline` in library mode and therefore requires it to sit beside it.
- Model-id prefix matching, and that an unknown id renders verbatim.

- [ ] **Step 2: Mention the feature in README.md**

Add it wherever the status line is introduced. One or two sentences.

- [ ] **Step 3: Verify no raw ESC bytes landed in the docs**

Writing about `\u001b` invites typing a literal escape byte. Check:

Run: `LC_ALL=C grep -c $'\033' docs/statusline.md README.md docs/superpowers/plans/2026-07-10-cs-subagent-statusline.md`
Expected: `0` for every file.

- [ ] **Step 4: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: every suite green.

- [ ] **Step 5: Commit**

```bash
git add docs/statusline.md README.md
git commit -m "docs: subagent status line rows"
```

---

## Self-Review

**Spec coverage.** Row format → Task 3-5. Colors and the explicit healthy color → Task 4. Library mode → Task 1. Model id mapping → Task 3. Null-when-nothing → Task 3 (tests 2-5). Width budget → Task 5. Failure posture → Task 2. Testing list items 1-13 → Tasks 2-6. Integration surface table → Task 6-7. Constraints → Global Constraints plus the bash 3.2 check in Task 5 Step 5.

**Type consistency.** `_MODEL`, `_ELAPSED`, `_TRUNC`, `_PAINTED`, `_WIDTH`, `_COLOR`, `_SGR`, `_TASKS`, `_STDIN` are the only globals. `_paint` is defined in Task 4 and used only from Task 4 onward. `_truncate` is defined in Task 5 and used only there. `render_rows` is the entry point in every task, never `main`.

**Known gap accepted.** `_display_width` counts characters, not display cells, so a double-width CJK description would over-run `columns` by one cell per wide character. `bin/cs-statusline` has the same property; matching it is better than diverging.
