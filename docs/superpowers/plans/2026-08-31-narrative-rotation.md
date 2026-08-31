# Narrative Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep each per-actor narrative under a byte budget by archiving its oldest `## ` sections verbatim into immutable, content-addressed chunk files, triggered from `/wrap`, the Stop hook and `cs -doctor`.

**Architecture:** One new lib fragment, `lib/51-narrative.sh`, owns the byte-exact rotation (`cs -narrative rotate`). Three existing surfaces point at it: `commands/wrap.md` runs it as Pass 3, `hooks/narrative-reminder.sh` adds one line when a narrative is over budget, `lib/60-doctor.sh` warns. Archives live in `.cs/narrative-archive/<actor>/<through-date>-<blob8>.md`, outside `.cs/memory/`, so no existing `narrative*.md` glob or the auto-memory scan sees them. The resume wording changes from "read all" to "read the live files" on every surface, with a migration for files cs already wrote.

**Tech Stack:** bash 3.2 + BSD userland (`wc`, `awk` under `LC_ALL=C`, `head -c`, `tail -c +N`, `cmp -n`, `git hash-object`), jq for the timeline event, the repo's `tests/test_lib.sh` harness.

**Spec:** `docs/superpowers/specs/2026-08-31-narrative-rotation-design.md`

## Global Constraints

- Everything must run under macOS stock `/bin/bash` 3.2 with BSD userland. No `local -A`, no `mapfile`, no `sed -i`, no GNU `date -d`, no awk brace intervals (`{4}`); `grep -E` intervals are fine.
- Run suites with `/bin/bash tests/<suite>.sh`, never bare `bash` (this machine's `bash` is 5.x).
- `bin/cs` is assembled from `lib/*.sh` by `./build.sh`. Tests run the built `bin/cs`: **run `./build.sh` after every lib edit and before every test run**, and commit `bin/cs` alongside the lib change.
- Every `assert_*` in a test needs `|| return 1` (the harness disables errexit inside `run_test`). `assert_file_contains` takes a **regex** — escape `.`, `*`, `[` in literal pins.
- No real names or addresses in fixtures; actors are `alice`/`bob`, mail is `@example.com`.
- Names and comments are evergreen: no "new", "legacy", "improved", no references to what the code used to do. Every new file starts with two `# ABOUTME:` lines.
- New session-dir write paths are classified before writing: `.cs/narrative-archive/<actor>/*.md` is shared, committed, immutable after creation; the live narrative rewrite is a single interior hunk with the tail byte-identical; temp files are created in the target directory and `mv`ed into place. Nothing new under `.cs/local/`.
- Budget defaults, verbatim from the spec: `CS_NARRATIVE_MAX_BYTES` = 131072, `CS_NARRATIVE_KEEP_BYTES` = 65536.
- Rotation never renames the live file and never lets the removed hunk reach EOF (both resurrect the whole body under `merge=union`, measured).
- The narrative contract is append-only after Task 8: corrections are new dated notes.
- Work on branch `feat/narrative-rotation`. Commit after every green slice.

---

## File map

| Path | Responsibility |
|------|----------------|
| `lib/51-narrative.sh` (create) | `rotate_narrative`, its helpers, `run_narrative` dispatcher |
| `lib/99-main.sh` (modify, dispatch case near `-checkpoint`) | `-narrative` arm |
| `lib/10-help.sh` (modify, near `-checkpoint` lines) | help line |
| `completions/cs.bash`, `completions/_cs` (modify) | `-narrative` in the flag lists (a test enforces this) |
| `tests/test_narrative_rotate.sh` (create) | the rotation suite |
| `hooks/narrative-reminder.sh` (modify, narrative-check block ~L628-664) | append-only wording, budget line |
| `tests/test_hooks.sh` (modify, narrative-reminder section) | wording + budget pins |
| `lib/60-doctor.sh` (modify) | `_doctor_check_narrative_size` |
| `tests/test_doctor.sh` (modify) | WARN/OK pins |
| `commands/wrap.md`, `commands/summary.md` (modify) | Pass 3; live-narrative wording |
| `tests/test_commands.sh` (modify) | pins |
| `lib/65-sessions.sh` (modify, `search_globs`) | archive glob |
| `tests/test_search.sh` (modify) | archive match |
| `lib/35-claudemd.sh` (modify) | template + frontmatter + index wording |
| `lib/45-migrate.sh` (modify) | Phase 13: rewrite wording cs already wrote |
| `hooks/session-start.sh` (modify, L324 and L675) | resume wording |
| `tests/test_migrate_claude_md.sh`, `tests/test_docs.sh` (modify) | migration + no-surface-says-read-all pins |
| `README.md`, `docs/session-layout.md`, `docs/hooks.md`, `docs/configuration.md` (modify) | docs |

---

### Task 1: `cs -narrative rotate` exists and is a no-op under budget

**Files:**
- Create: `lib/51-narrative.sh`
- Modify: `lib/99-main.sh` (add an arm after the `-checkpoint)` arm)
- Modify: `lib/10-help.sh` (after the `-checkpoint show <name>` line)
- Modify: `completions/cs.bash` (`global_flags` string), `completions/_cs` (the `'-checkpoint:...'` list)
- Modify: `README.md` usage list (after the `cs -checkpoint` line) and `docs/configuration.md` (after the `CS_ROTATE_NUDGE_CTX` export)
- Create: `tests/test_narrative_rotate.sh`

**Interfaces:**
- Produces: `run_narrative "$@"` (dispatcher; `rotate` is the only subcommand), `rotate_narrative` (no args; reads `CLAUDE_SESSION_META_DIR`, `CLAUDE_SESSION_DIR`, `CS_NARRATIVE_MAX_BYTES`, `CS_NARRATIVE_KEEP_BYTES`), `_narrative_budget VALUE DEFAULT`, constants `CS_NARRATIVE_MAX_DEFAULT=131072`, `CS_NARRATIVE_KEEP_DEFAULT=65536`. Later tasks extend `rotate_narrative` in place.

- [ ] **Step 1: Write the test file with its fixture builder and the first two tests**

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for cs -narrative rotate: byte-budgeted archival of a narrative's oldest sections
# ABOUTME: Pins the cut rule, content addressing, concurrency guards, git commit and union-merge safety

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Every test rotates actor alice's narrative inside one session. CS_ACTOR is
# the top-precedence identity override, so the machine's git identity never
# leaks into the file name under test.
setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CS_ACTOR="alice"
    mkdir -p "$CS_SESSIONS_ROOT"
    SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    mkdir -p "$SESSION_DIR/.cs"/{local,memory}
    printf '# Session: test-session\n' > "$SESSION_DIR/.cs/README.md"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$SESSION_DIR"
    export CLAUDE_SESSION_META_DIR="$SESSION_DIR/.cs"
    LIVE="$SESSION_DIR/.cs/memory/narrative.alice.md"
    ARCHIVE_DIR="$SESSION_DIR/.cs/narrative-archive/alice"
    # Small budgets so fixtures stay readable: rotate above 4 KiB, keep 2 KiB.
    export CS_NARRATIVE_MAX_BYTES=4096
    export CS_NARRATIVE_KEEP_BYTES=2048
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN CS_ACTOR 2>/dev/null || true
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
    unset CS_NARRATIVE_MAX_BYTES CS_NARRATIVE_KEEP_BYTES CS_NARRATIVE_ROTATE_MIDPOINT 2>/dev/null || true
}

# A narrative with the header block cs writes (5 frontmatter lines + H1) and N
# dated sections. Section i is "\n## 2026-08-DD — section i\n" + BODY bytes of
# 'x' + "\n": with a one-digit i that is exactly 29 + BODY + 1 bytes (the em dash
# is 3 bytes); section 10 is one byte longer. Line layout: header = lines 1-6,
# section i = lines 6+3i-2 .. 6+3i.
_make_narrative() {  # file, sections, body_bytes
    local file="$1" n="$2" body="$3" i filler
    filler=$(head -c "$body" /dev/zero | tr '\0' 'x')
    {
        printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook for alice.\ntype: narrative\n---\n# Session narrative (alice)\n'
        i=1
        while [ "$i" -le "$n" ]; do
            printf '\n## 2026-08-%02d — section %d\n%s\n' $(( (i % 28) + 1 )) "$i" "$filler"
            i=$((i + 1))
        done
    } > "$file"
}

_bytes() { wc -c < "$1" | tr -d ' '; }

# ============================================================================
# under budget
# ============================================================================

test_rotate_is_a_recognised_subcommand() {
    _make_narrative "$LIVE" 2 100
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || true
    assert_output_not_contains "$output" "Unknown command" "cs -narrative must dispatch" || return 1
}

test_rotate_under_budget_is_a_noop() {
    _make_narrative "$LIVE" 2 100          # ~1.3 KB, under the 4 KiB budget
    local before after output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    after=$(_bytes "$LIVE")
    assert_eq "$before" "$after" "live file must be untouched under budget" || return 1
    assert_output_contains "$output" "nothing to rotate" "must say it did nothing" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "no archive dir is created under budget" || return 1
}

test_rotate_requires_a_session() {
    unset CLAUDE_SESSION_META_DIR
    if "$CS_BIN" -narrative rotate > /dev/null 2>&1; then
        echo "  FAIL: must refuse outside a session"
        return 1
    fi
}

test_rotate_rejects_unknown_subcommand() {
    if "$CS_BIN" -narrative frobnicate > /dev/null 2>&1; then
        echo "  FAIL: unknown subcommand must fail"
        return 1
    fi
}

test_help_shows_narrative() {
    local output
    output=$("$CS_BIN" -help 2>&1)
    assert_output_contains "$output" "-narrative rotate" "help must mention -narrative rotate" || return 1
}

echo ""
echo "cs narrative rotation tests"
echo "==========================="
echo ""

run_test test_rotate_is_a_recognised_subcommand
run_test test_rotate_under_budget_is_a_noop
run_test test_rotate_requires_a_session
run_test test_rotate_rejects_unknown_subcommand
run_test test_help_shows_narrative

report_results
```

- [ ] **Step 2: Run it to see it fail**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: `test_rotate_is_a_recognised_subcommand` and `test_help_shows_narrative` FAIL (Unknown command / help missing); the others may pass vacuously — that is fine at this step.

- [ ] **Step 3: Create the lib fragment**

`lib/51-narrative.sh`:

```bash
# ABOUTME: Rotates the current actor's narrative once it passes its byte budget: the
# ABOUTME: oldest '## ' sections move verbatim to .cs/narrative-archive/. Backs 'cs -narrative'.

CS_NARRATIVE_MAX_DEFAULT=131072
CS_NARRATIVE_KEEP_DEFAULT=65536

# A positive integer override, else the default. Empty, non-numeric and zero all
# fall back: a zero budget would rotate on every run.
_narrative_budget() {  # value, default
    case "${1:-}" in ''|*[!0-9]*|0) echo "$2";; *) echo "$1";; esac
}

# Archive the oldest sections of this actor's narrative when the file is over
# CS_NARRATIVE_MAX_BYTES, leaving a tail of about CS_NARRATIVE_KEEP_BYTES.
rotate_narrative() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ] || [ ! -d "${CLAUDE_SESSION_META_DIR}" ]; then
        error "cs -narrative rotate must be run from inside a cs session"
    fi
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    local session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}"
    local actor
    actor=$(cs_actor_slug "$session_dir")
    local live="$meta_dir/memory/narrative.$actor.md"
    [ -f "$live" ] || error "No narrative for actor $actor at $live"

    local max keep size
    max=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
    keep=$(_narrative_budget "${CS_NARRATIVE_KEEP_BYTES:-}" "$CS_NARRATIVE_KEEP_DEFAULT")
    size=$(wc -c < "$live" | tr -d ' ')
    if [ "$size" -le "$max" ]; then
        info "nothing to rotate: narrative.$actor.md is $((size / 1024)) KB (budget $((max / 1024)) KB)"
        return 0
    fi
    error "rotation not implemented yet"
}

# Dispatcher for cs -narrative
run_narrative() {
    local sub="${1:-}"
    case "$sub" in
        rotate)
            rotate_narrative
            ;;
        *)
            error "Usage: cs -narrative rotate   # from inside a session"
            ;;
    esac
}
```

- [ ] **Step 4: Wire the dispatch, help and completions**

`lib/99-main.sh`, directly after the `-checkpoint)` arm:

```bash
        -narrative)
            shift
            run_narrative "$@"
            return 0
            ;;
```

`lib/10-help.sh`, after the `-checkpoint show <name>` line:

```
  -narrative rotate   Archive the oldest sections of your narrative once it passes its byte budget (run from inside a session; /wrap runs it)
```

`completions/cs.bash`: add `-narrative` to `global_flags` right after `-checkpoint`.
`completions/_cs`: add `'-narrative:Archive the oldest sections of your session narrative'` right after the `'-checkpoint:...'` entry.

`README.md`, in the usage list after the `cs -checkpoint "<label>"` line:

```
cs -narrative rotate        # Archive the oldest narrative sections once the file passes its budget (/wrap runs this)
```

`docs/configuration.md`, after the `export CS_ROTATE_NUDGE_CTX="80"` line:

```bash

# Narrative rotation: rotate when the live file passes MAX, keep about KEEP bytes
export CS_NARRATIVE_MAX_BYTES="131072"
export CS_NARRATIVE_KEEP_BYTES="65536"
```

- [ ] **Step 5: Build and run the suite plus the completions and docs guards**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh && /bin/bash tests/test_completions.sh && /bin/bash tests/test_docs.sh && /bin/bash tests/test_help.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/51-narrative.sh lib/99-main.sh lib/10-help.sh completions/cs.bash completions/_cs README.md docs/configuration.md tests/test_narrative_rotate.sh bin/cs
git commit -m "feat(narrative): add cs -narrative rotate, a no-op under budget"
```

---

### Task 2: Rotation core — archive the oldest sections, keep a byte-identical tail

**Files:**
- Modify: `lib/51-narrative.sh` (replace the `error "rotation not implemented yet"` line and add two helpers)
- Modify: `tests/test_narrative_rotate.sh`

**Interfaces:**
- Produces: `_narrative_headings FILE` → lines of `<byte-offset> <heading line>` for every `## ` heading; `_narrative_cut HEADINGS SIZE KEEP` → byte offset of the first retained heading. Archive chunk header is exactly three lines: two HTML comments and a blank line, so `sed '1,3d' chunk` is the verbatim body.

- [ ] **Step 1: Add the failing tests**

Fixture arithmetic for `_make_narrative "$LIVE" 10 500`: measured from one heading to the next, every section is 530 bytes (28-byte heading line, 501-byte body line, the 1-byte blank line that precedes the next heading; section 10 has a 29-byte heading and no trailing blank, so also 530). The file is ~5.3 KB, over the 4096 budget. From the end: sections 10+9+8 = 1590 ≤ 2048, adding 7 gives 2120 > 2048, so the cut is section 8's heading. The header block cs keeps is everything before the first heading — lines 1-7 (frontmatter, H1, and the blank line before section 1). The archived body is therefore lines 8-28 (section 1's heading through the blank line before section 8's heading), and the rotated live file is lines 1-7 followed by section 8 onward.

```bash
# ============================================================================
# over budget: the cut rule
# ============================================================================

test_rotate_archives_oldest_sections_and_keeps_tail() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "^## 2026-08-09 — section 8$" "section 8 opens the kept tail" || return 1
    assert_file_contains "$LIVE" "section 10$" "the newest section stays" || return 1
    assert_file_not_contains "$LIVE" "section 7$" "section 7 is archived" || return 1
    assert_file_not_contains "$LIVE" "section 1$" "section 1 is archived" || return 1
    local tail_bytes
    tail_bytes=$(( $(_bytes "$LIVE") - $(head -7 "$LIVE" | wc -c | tr -d ' ') ))
    assert_eq "1590" "$tail_bytes" "the tail is exactly sections 8, 9 and 10" || return 1
}

test_rotate_keeps_the_header_block() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local first six
    first=$(head -1 "$LIVE")
    assert_eq "---" "$first" "frontmatter still opens the file" || return 1
    six=$(sed -n '6p' "$LIVE")
    assert_eq "# Session narrative (alice)" "$six" "the H1 is still line 6" || return 1
}

test_rotate_cuts_on_a_heading_boundary() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    # Line 7 is the blank line that precedes every section; line 8 is a heading.
    local seven eight
    seven=$(sed -n '7p' "$LIVE"); eight=$(sed -n '8p' "$LIVE")
    assert_eq "" "$seven" "a blank line separates header and first kept section" || return 1
    case "$eight" in "## "*) ;; *) echo "  FAIL: line 8 is not a heading: $eight"; return 1 ;; esac
}

test_rotate_writes_one_chunk_whose_body_is_verbatim() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local count chunk
    count=$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')
    assert_eq "1" "$count" "exactly one chunk" || return 1
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    # Chunk header is exactly two comment lines and a blank line.
    assert_file_contains "$chunk" "^<!-- rotated from narrative\.alice\.md: 7 sections through 2026-08-08 -->$" "chunk names its origin, count and through-date" || return 1
    # Verbatim: original == header block (lines 1-7) + archived body + kept
    # tail (the rotated live file from line 8), byte for byte.
    { head -7 "$TEST_TMPDIR/original.md"; sed '1,3d' "$chunk"; tail -n +8 "$LIVE"; } > "$TEST_TMPDIR/rebuilt.md"
    if ! cmp -s "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md"; then
        echo "  FAIL: header + chunk body + live tail does not rebuild the original byte for byte"
        cmp "$TEST_TMPDIR/original.md" "$TEST_TMPDIR/rebuilt.md" || true
        return 1
    fi
}

test_rotate_reports_what_it_did() {
    _make_narrative "$LIVE" 10 500
    local output
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_output_contains "$output" "rotated 7 sections" "reports the section count" || return 1
    assert_output_contains "$output" "narrative-archive/alice/" "names the archive path" || return 1
}
```

Add to the runner block:

```bash
run_test test_rotate_archives_oldest_sections_and_keeps_tail
run_test test_rotate_keeps_the_header_block
run_test test_rotate_cuts_on_a_heading_boundary
run_test test_rotate_writes_one_chunk_whose_body_is_verbatim
run_test test_rotate_reports_what_it_did
```

- [ ] **Step 2: Run to see them fail**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: the five new tests FAIL ("rotation not implemented yet").

- [ ] **Step 3: Implement the core**

In `lib/51-narrative.sh`, add above `rotate_narrative`:

```bash
# One line per '## ' heading: the heading's byte offset, a space, the heading.
# LC_ALL=C makes awk's length() count bytes, so offsets survive multibyte text
# (real headings carry an em dash).
_narrative_headings() {  # file
    LC_ALL=C awk 'BEGIN { off = 0 } { if (substr($0, 1, 3) == "## ") print off, $0; off += length($0) + 1 }' "$1"
}

# Byte offset of the first heading to KEEP: the earliest one with at most KEEP
# bytes between it and EOF. When even the final section is larger than KEEP,
# that final heading is the cut, so the tail is one oversized section rather
# than nothing.
_narrative_cut() {  # headings, size, keep
    local headings="$1" size="$2" keep="$3" off line
    while read -r off line; do
        [ -n "$off" ] || continue
        if [ $((size - off)) -le "$keep" ]; then
            echo "$off"
            return 0
        fi
    done <<EOF
$headings
EOF
    printf '%s\n' "$headings" | tail -1 | cut -d' ' -f1
}
```

Replace the line `error "rotation not implemented yet"` with:

```bash
    # Work from a snapshot: the cut is computed on bytes that cannot change under
    # us, and the live file is compared against that snapshot before it is rewritten.
    local snap="$meta_dir/memory/.narrative.$actor.rotate.$$"
    cp "$live" "$snap"
    # grep -c exits 1 on zero matches; under set -e -o pipefail that would end
    # cs instead of reaching the warning below, hence the || true.
    local headings count head_end cut
    headings=$(_narrative_headings "$snap")
    count=$(printf '%s\n' "$headings" | grep -c . || true)
    if [ "$count" -lt 2 ]; then
        rm -f "$snap"
        warn "narrative.$actor.md is over budget but has fewer than two sections; nothing can be archived without touching the tail"
        return 0
    fi
    head_end=$(printf '%s\n' "$headings" | head -1 | cut -d' ' -f1)
    cut=$(_narrative_cut "$headings" "$size" "$keep")
    if [ "$cut" -le "$head_end" ]; then
        rm -f "$snap"
        info "nothing to rotate: the first section already starts the retained tail"
        return 0
    fi

    local sections through
    sections=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' | grep -c . || true)
    through=$(printf '%s\n' "$headings" | awk -v c="$cut" '$1 + 0 < c + 0' \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1 || true)
    [ -n "$through" ] || through="undated"

    local arch_dir="$meta_dir/narrative-archive/$actor"
    mkdir -p "$arch_dir"
    local body="$arch_dir/.body.$$"
    # head first, tail second: the bounded producer runs to completion and the
    # consumer reads all of it. The other order lets head close the pipe early
    # and tail die of SIGPIPE, which pipefail turns into a failed rotation on
    # any file whose kept tail is larger than the pipe buffer.
    head -c "$cut" "$snap" | tail -c +$((head_end + 1)) > "$body"
    local blob chunk chunk_tmp
    blob=$(git hash-object "$body" | cut -c1-8)
    chunk="$arch_dir/$through-$blob.md"
    chunk_tmp="$arch_dir/.$through-$blob.md.tmp"
    {
        printf '<!-- rotated from narrative.%s.md: %s sections through %s -->\n' "$actor" "$sections" "$through"
        printf '<!-- verbatim copy of the sections that preceded the live tail; never edited -->\n\n'
        cat "$body"
    } > "$chunk_tmp"
    rm -f "$body"
    mv "$chunk_tmp" "$chunk"

    # The live file must still open with the same bytes the snapshot did up to the
    # cut; a peer merge or an edit inside the archived run means the cut no longer
    # describes this file.
    if ! cmp -s -n "$cut" "$snap" "$live"; then
        rm -f "$snap" "$chunk"
        error "narrative.$actor.md changed during rotation; run cs -narrative rotate again"
    fi
    local live_tmp="$meta_dir/memory/.narrative.$actor.md.tmp"
    { head -c "$head_end" "$snap"; tail -c +$((cut + 1)) "$live"; } > "$live_tmp"
    mv "$live_tmp" "$live"
    rm -f "$snap"

    local archived_kb now_kb
    archived_kb=$(( (cut - head_end) / 1024 ))
    now_kb=$(( $(wc -c < "$live" | tr -d ' ') / 1024 ))
    echo "rotated $sections sections (${archived_kb} KB) -> .cs/narrative-archive/$actor/$(basename "$chunk"); live file now ${now_kb} KB"
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: all PASS, including the byte-for-byte rebuild.

- [ ] **Step 5: Commit**

```bash
git add lib/51-narrative.sh tests/test_narrative_rotate.sh bin/cs
git commit -m "feat(narrative): archive the oldest sections and keep a byte-identical tail"
```

---

### Task 3: Edge rules — oversized final section, single section, huge header

**Files:**
- Modify: `tests/test_narrative_rotate.sh`

The implementation from Task 2 already carries these branches; this task proves them. If any test fails, fix the branch in `lib/51-narrative.sh` — do not weaken the test.

- [ ] **Step 1: Add the tests**

```bash
# ============================================================================
# edge rules
# ============================================================================

test_rotate_keeps_an_oversized_final_section_whole() {
    # 3 sections of 3000 bytes: every section alone exceeds KEEP=2048, so the
    # tail is exactly the last section and the first two are archived.
    _make_narrative "$LIVE" 3 3000
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "section 3$" "the final section is kept" || return 1
    assert_file_not_contains "$LIVE" "section 2$" "section 2 is archived" || return 1
    local heads
    heads=$(grep -c '^## ' "$LIVE")
    assert_eq "1" "$heads" "exactly one section remains" || return 1
}

test_rotate_with_a_single_section_is_a_warned_noop() {
    _make_narrative "$LIVE" 1 6000
    local before output
    before=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "a single-section file is left alone" || return 1
    assert_output_contains "$output" "fewer than two sections" "explains why nothing moved" || return 1
    assert_not_exists "$SESSION_DIR/.cs/narrative-archive" "no chunk is written" || return 1
}

test_rotate_never_leaves_the_removed_hunk_at_eof() {
    # Whatever the budgets, at least one complete section must follow the cut.
    export CS_NARRATIVE_KEEP_BYTES=1
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local heads
    heads=$(grep -c '^## ' "$LIVE")
    assert_eq "1" "$heads" "the final section survives even with KEEP=1" || return 1
    assert_file_contains "$LIVE" "section 10$" "and it is the newest one" || return 1
}

test_rotate_treats_undated_headings_by_position() {
    # An undated heading in the archived run neither breaks the cut nor the name:
    # through-date comes from the last dated heading before the cut.
    _make_narrative "$LIVE" 10 500
    # Replace section 3's heading with an undated one, keeping the byte count
    # irrelevant: the cut is by position, not by date.
    sed 's/^## 2026-08-04 — section 3$/## undated topic note/' "$LIVE" > "$LIVE.tmp" && mv "$LIVE.tmp" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local chunk
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    assert_file_contains "$chunk" "^## undated topic note$" "the undated section rode along" || return 1
    case "$(basename "$chunk")" in 2026-08-08-*.md) ;; *) echo "  FAIL: chunk name should carry through-date 2026-08-08: $(basename "$chunk")"; return 1 ;; esac
}

test_rotate_names_a_fully_undated_run_undated() {
    _make_narrative "$LIVE" 10 500
    sed 's/^## 2026-08-[0-9][0-9] — section \([1-7]\)$/## topic \1/' "$LIVE" > "$LIVE.tmp" && mv "$LIVE.tmp" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local chunk
    chunk=$(find "$ARCHIVE_DIR" -name '*.md' | head -1)
    case "$(basename "$chunk")" in undated-*.md) ;; *) echo "  FAIL: expected undated-<blob>.md, got $(basename "$chunk")"; return 1 ;; esac
}
```

Runner additions:

```bash
run_test test_rotate_keeps_an_oversized_final_section_whole
run_test test_rotate_with_a_single_section_is_a_warned_noop
run_test test_rotate_never_leaves_the_removed_hunk_at_eof
run_test test_rotate_treats_undated_headings_by_position
run_test test_rotate_names_a_fully_undated_run_undated
```

- [ ] **Step 2: Run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: PASS. (If `test_rotate_names_a_fully_undated_run_undated` fails because the sed changed byte counts and moved the cut, the shorter headings make sections 1-7 smaller — the cut still lands on section 8 because the tail arithmetic is unchanged; investigate before touching the code.)

- [ ] **Step 3: Commit**

```bash
git add tests/test_narrative_rotate.sh lib/51-narrative.sh bin/cs
git commit -m "test(narrative): pin the oversized-tail, single-section and undated-heading rules"
```

---

### Task 4: Content addressing — same prefix, same chunk; re-run is a no-op; conflicting chunk aborts

**Files:**
- Modify: `lib/51-narrative.sh` (the `mv "$chunk_tmp" "$chunk"` line)
- Modify: `tests/test_narrative_rotate.sh`

**Interfaces:**
- Produces: `rotate_narrative` sets the local `created=1` when it wrote a chunk this run; Task 5 uses it to decide whether an abort removes the chunk.

- [ ] **Step 1: Add the tests**

The expected chunk name is computed independently of the code: the archived body is lines 8-28 of the fixture (section 1's heading through the blank line before section 8), its blob is `git hash-object` of those bytes, and the through-date is section 7's date (`2026-08-08`).

```bash
# ============================================================================
# content addressing
# ============================================================================

_expected_chunk_name() {  # original file (10x500 fixture)
    local blob
    blob=$(sed -n '8,28p' "$1" | git hash-object --stdin | cut -c1-8)
    echo "2026-08-08-$blob.md"
}

test_rotate_chunk_name_is_content_addressed() {
    _make_narrative "$LIVE" 10 500
    local expected
    expected=$(_expected_chunk_name "$LIVE")
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_exists "$ARCHIVE_DIR/$expected" "chunk is named <through-date>-<blob8>.md from its own bytes" || return 1
}

test_rotate_rerun_is_a_noop() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local after output
    after=$(_bytes "$LIVE")
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    assert_output_contains "$output" "nothing to rotate" "second run finds the file under budget" || return 1
    assert_eq "$after" "$(_bytes "$LIVE")" "second run changes nothing" || return 1
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "still one chunk" || return 1
}

test_rotate_accepts_an_identical_existing_chunk() {
    # Two machines archiving the same prefix produce the same file. Simulate the
    # second machine by restoring the original narrative after a first rotation.
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    cp "$TEST_TMPDIR/original.md" "$LIVE"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "the identical chunk is reused, not duplicated" || return 1
    assert_file_contains "$LIVE" "section 8$" "and the live file was rotated again" || return 1
}

test_rotate_refuses_a_differing_chunk_with_the_same_name() {
    _make_narrative "$LIVE" 10 500
    local expected
    expected=$(_expected_chunk_name "$LIVE")
    mkdir -p "$ARCHIVE_DIR"
    printf 'not the same bytes\n' > "$ARCHIVE_DIR/$expected"
    local before output
    before=$(_bytes "$LIVE")
    if output=$("$CS_BIN" -narrative rotate 2>&1); then
        echo "  FAIL: must refuse to overwrite a differing chunk"
        return 1
    fi
    assert_output_contains "$output" "different content" "says why it refused" || return 1
    assert_eq "$before" "$(_bytes "$LIVE")" "live file untouched after the refusal" || return 1
    assert_eq "not the same bytes" "$(head -1 "$ARCHIVE_DIR/$expected")" "existing chunk untouched" || return 1
}
```

Runner additions:

```bash
run_test test_rotate_chunk_name_is_content_addressed
run_test test_rotate_rerun_is_a_noop
run_test test_rotate_accepts_an_identical_existing_chunk
run_test test_rotate_refuses_a_differing_chunk_with_the_same_name
```

- [ ] **Step 2: Run to see the refusal test fail**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: `test_rotate_refuses_a_differing_chunk_with_the_same_name` FAILS (the chunk is overwritten); `test_rotate_accepts_an_identical_existing_chunk` passes by overwrite, which is not the property — the implementation below makes it pass for the right reason.

- [ ] **Step 3: Implement the existence check**

Replace the single line `mv "$chunk_tmp" "$chunk"` in `rotate_narrative` with:

```bash
    local created=0
    if [ -f "$chunk" ]; then
        if cmp -s "$chunk" "$chunk_tmp"; then
            rm -f "$chunk_tmp"
        else
            rm -f "$chunk_tmp" "$snap"
            error "archive chunk $chunk exists with different content; refusing to overwrite"
        fi
    else
        mv "$chunk_tmp" "$chunk"
        created=1
    fi
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/51-narrative.sh tests/test_narrative_rotate.sh bin/cs
git commit -m "feat(narrative): content-addressed chunks; refuse a differing chunk of the same name"
```

---

### Task 5: Concurrency — an append during rotation survives; an edit inside the archived run aborts

**Files:**
- Modify: `lib/51-narrative.sh` (midpoint seam; abort path removes a chunk this run created)
- Modify: `tests/test_narrative_rotate.sh`

**Interfaces:**
- Produces: `CS_NARRATIVE_ROTATE_MIDPOINT` — a test seam: when set, its value is `eval`ed after the snapshot is taken and before the live file is compared and rewritten. Same class as `CS_PS_BIN`: a hook for tests, documented in the code, never in user docs.

- [ ] **Step 1: Add the tests**

```bash
# ============================================================================
# concurrency
# ============================================================================

test_rotate_keeps_an_append_that_lands_mid_rotation() {
    _make_narrative "$LIVE" 10 500
    export CS_NARRATIVE_ROTATE_MIDPOINT="printf '\n## 2026-09-01 — late note\nlanded during rotation\n' >> '$LIVE'"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "^## 2026-09-01 — late note$" "the late section is in the live file" || return 1
    assert_file_contains "$LIVE" "landed during rotation" "with its body" || return 1
    assert_file_contains "$LIVE" "section 8$" "and the rotation still happened" || return 1
    assert_file_not_contains "$LIVE" "section 7$" "with section 7 archived" || return 1
}

test_rotate_aborts_when_the_archived_run_changed_underneath() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    export CS_NARRATIVE_ROTATE_MIDPOINT="sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' '$LIVE' > '$LIVE.x' && mv '$LIVE.x' '$LIVE'"
    local output
    if output=$("$CS_BIN" -narrative rotate 2>&1); then
        echo "  FAIL: must abort when the prefix changed"
        return 1
    fi
    assert_output_contains "$output" "changed during rotation" "says what happened" || return 1
    assert_file_contains "$LIVE" "section 2 (edited)" "the edited live file is left as the editor left it" || return 1
    assert_file_contains "$LIVE" "section 1$" "nothing was removed" || return 1
    assert_eq "0" "$(find "$SESSION_DIR/.cs/narrative-archive" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" "the chunk written this run is removed on abort" || return 1
}

test_rotate_abort_leaves_a_preexisting_identical_chunk_alone() {
    _make_narrative "$LIVE" 10 500
    cp "$LIVE" "$TEST_TMPDIR/original.md"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    cp "$TEST_TMPDIR/original.md" "$LIVE"
    export CS_NARRATIVE_ROTATE_MIDPOINT="sed 's/^## 2026-08-03 — section 2$/## 2026-08-03 — section 2 (edited)/' '$LIVE' > '$LIVE.x' && mv '$LIVE.x' '$LIVE'"
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 && { echo "  FAIL: must abort"; return 1; }
    assert_eq "1" "$(find "$ARCHIVE_DIR" -name '*.md' | wc -l | tr -d ' ')" "a chunk that predates this run survives the abort" || return 1
}

test_rotate_leaves_no_temp_files_behind() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local strays
    strays=$(find "$SESSION_DIR/.cs" -name '.*rotate*' -o -name '.body.*' -o -name '*.md.tmp' | wc -l | tr -d ' ')
    assert_eq "0" "$strays" "no snapshot, body or tmp files remain" || return 1
}
```

Runner additions:

```bash
run_test test_rotate_keeps_an_append_that_lands_mid_rotation
run_test test_rotate_aborts_when_the_archived_run_changed_underneath
run_test test_rotate_abort_leaves_a_preexisting_identical_chunk_alone
run_test test_rotate_leaves_no_temp_files_behind
```

- [ ] **Step 2: Run to see the seam tests fail**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: the two midpoint tests FAIL (the seam does not exist, so the append/edit never happens); the abort-chunk test FAILS.

- [ ] **Step 3: Add the seam and fix the abort path**

In `rotate_narrative`, directly before the `if ! cmp -s -n "$cut" "$snap" "$live"; then` line, insert:

```bash
    # Test seam: lets a suite change the live file between the snapshot and the
    # rewrite, which is the window every guard below exists for.
    if [ -n "${CS_NARRATIVE_ROTATE_MIDPOINT:-}" ]; then
        eval "$CS_NARRATIVE_ROTATE_MIDPOINT"
    fi
```

Replace the abort body

```bash
        rm -f "$snap" "$chunk"
        error "narrative.$actor.md changed during rotation; run cs -narrative rotate again"
```

with

```bash
        rm -f "$snap"
        [ "$created" -eq 1 ] && rm -f "$chunk"
        error "narrative.$actor.md changed during rotation; run cs -narrative rotate again"
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/51-narrative.sh tests/test_narrative_rotate.sh bin/cs
git commit -m "feat(narrative): keep mid-rotation appends; abort when the archived run changed"
```

---

### Task 6: Git commit when tracked, skip when ignored; timeline event

**Files:**
- Modify: `lib/51-narrative.sh` (before the final `echo`)
- Modify: `tests/test_narrative_rotate.sh`

**Interfaces:**
- Consumes: `_terminate_jsonl FILE` from `lib/40-state.sh`.
- Produces: commit subject `cs: rotate narrative.<actor> (<N> sections -> narrative-archive)`; timeline event `{ts, event: "narrative_rotated", actor, sections, bytes, archive}` where `archive` is the path relative to the session root.

- [ ] **Step 1: Add the tests**

```bash
# ============================================================================
# git and timeline
# ============================================================================

_init_tracked_repo() {
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
}

test_rotate_commits_live_and_chunk_when_tracked() {
    _make_narrative "$LIVE" 10 500
    _init_tracked_repo
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local subject dirty
    subject=$(git -C "$SESSION_DIR" log -1 --format=%s)
    assert_eq "cs: rotate narrative.alice (7 sections -> narrative-archive)" "$subject" "one commit with the rotation subject" || return 1
    dirty=$(git -C "$SESSION_DIR" status --porcelain -- .cs/memory .cs/narrative-archive)
    assert_eq "" "$dirty" "live file and chunk are both committed" || return 1
}

test_rotate_skips_the_commit_when_cs_is_ignored() {
    _make_narrative "$LIVE" 10 500
    printf '.cs/\n' > "$SESSION_DIR/.gitignore"
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
    local before output after
    before=$(git -C "$SESSION_DIR" rev-list --count HEAD)
    output=$("$CS_BIN" -narrative rotate 2>&1) || return 1
    after=$(git -C "$SESSION_DIR" rev-list --count HEAD)
    assert_eq "$before" "$after" "no commit when the narrative is not tracked" || return 1
    assert_output_contains "$output" "not tracked" "says the archive was left uncommitted" || return 1
    assert_file_contains "$LIVE" "section 8$" "the rotation itself still ran" || return 1
}

test_rotate_outside_git_still_rotates() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_file_contains "$LIVE" "section 8$" "rotation does not need a repo" || return 1
}

test_rotate_appends_a_timeline_event() {
    _make_narrative "$LIVE" 10 500
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    assert_exists "$SESSION_DIR/.cs/timeline.jsonl" "timeline written" || return 1
    if ! jq -e 'select(.event == "narrative_rotated" and .actor == "alice" and .sections == 7)' \
        "$SESSION_DIR/.cs/timeline.jsonl" > /dev/null; then
        echo "  FAIL: expected a narrative_rotated event for alice with 7 sections"
        cat "$SESSION_DIR/.cs/timeline.jsonl"
        return 1
    fi
    local archive
    archive=$(jq -r 'select(.event == "narrative_rotated") | .archive' "$SESSION_DIR/.cs/timeline.jsonl")
    case "$archive" in .cs/narrative-archive/alice/2026-08-08-*.md) ;; *) echo "  FAIL: archive field should be session-relative: $archive"; return 1 ;; esac
}

test_rotate_does_not_splice_onto_a_torn_timeline() {
    _make_narrative "$LIVE" 10 500
    local timeline="$SESSION_DIR/.cs/timeline.jsonl"
    printf '{"ts":"2026-01-01T00:00:00Z","event":"started","session_id":"1111"}\n' > "$timeline"
    printf '{"ts":"2026-01-02T00:00:00Z","event":"rotated","reason":"torn"}' >> "$timeline"
    jsonl_tail_is_torn "$timeline" || { echo "  FAIL: fixture is terminated; the splice cannot happen"; return 1; }
    "$CS_BIN" -narrative rotate > /dev/null 2>&1 || return 1
    local events
    events=$(jsonl_events "$timeline")
    assert_output_contains "$events" "rotated" "the torn record survives" || return 1
    assert_output_contains "$events" "narrative_rotated" "and so does the record appended after it" || return 1
}
```

Runner additions:

```bash
run_test test_rotate_commits_live_and_chunk_when_tracked
run_test test_rotate_skips_the_commit_when_cs_is_ignored
run_test test_rotate_outside_git_still_rotates
run_test test_rotate_appends_a_timeline_event
run_test test_rotate_does_not_splice_onto_a_torn_timeline
```

- [ ] **Step 2: Run to see them fail**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: the commit, ignored and timeline tests FAIL.

- [ ] **Step 3: Implement**

In `rotate_narrative`, after `rm -f "$snap"` (the one following the live rewrite) and before the `archived_kb=` lines, insert:

```bash
    local chunk_rel=".cs/narrative-archive/$actor/$(basename "$chunk")"
    if git -C "$session_dir" rev-parse --git-dir >/dev/null 2>&1 \
        && git -C "$session_dir" ls-files --error-unmatch -- "$live" >/dev/null 2>&1; then
        if ! { git -C "$session_dir" add -- "$live" "$chunk" \
            && git -C "$session_dir" commit -q -m "cs: rotate narrative.$actor ($sections sections -> narrative-archive)"; } 2>/dev/null; then
            warn "rotation written but the commit failed; commit .cs/memory/narrative.$actor.md and $chunk_rel by hand"
        fi
    else
        info "narrative.$actor.md is not tracked by git here; the archive chunk is left uncommitted"
    fi

    local timeline="$meta_dir/timeline.jsonl"
    _terminate_jsonl "$timeline"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg actor "$actor" \
           --argjson sections "$sections" \
           --argjson bytes "$((cut - head_end))" \
           --arg archive "$chunk_rel" \
           '{ts: $ts, event: "narrative_rotated", actor: $actor, sections: $sections, bytes: $bytes, archive: $archive}' \
        >> "$timeline" 2>/dev/null || true
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/51-narrative.sh tests/test_narrative_rotate.sh bin/cs
git commit -m "feat(narrative): commit the rotation when tracked and record it on the timeline"
```

---

### Task 7: Union-merge integration — rotate on one clone, append on another, merge clean

**Files:**
- Modify: `tests/test_narrative_rotate.sh`

This is the measurement the whole design rests on, kept as a test so a future change to the cut rule cannot silently reintroduce resurrection.

- [ ] **Step 1: Add the tests**

```bash
# ============================================================================
# union merge across clones
# ============================================================================

# Origin with the narrative committed under merge=union, plus clones A and B
# that each carry the session env when cs runs inside them.
_make_clones() {
    _make_narrative "$LIVE" 10 500
    # The attributes a real session carries: without union on the timeline, two
    # clones that each create .cs/timeline.jsonl would add/add-conflict.
    printf '.cs/memory/narrative.*.md merge=union\n.cs/timeline.jsonl merge=union\n' > "$SESSION_DIR/.gitattributes"
    (cd "$SESSION_DIR" && git init -q -b main && git config user.email alice@example.com && git config user.name alice \
        && git add -A && git commit -q -m init)
    CLONE_A="$TEST_TMPDIR/clone-a"; CLONE_B="$TEST_TMPDIR/clone-b"
    git clone -q "$SESSION_DIR" "$CLONE_A" && git -C "$CLONE_A" config user.email alice@example.com && git -C "$CLONE_A" config user.name alice
    git clone -q "$SESSION_DIR" "$CLONE_B" && git -C "$CLONE_B" config user.email alice@example.com && git -C "$CLONE_B" config user.name alice
}

_rotate_in() {  # clone dir, [keep bytes]
    CLAUDE_SESSION_DIR="$1" CLAUDE_SESSION_META_DIR="$1/.cs" CS_NARRATIVE_KEEP_BYTES="${2:-$CS_NARRATIVE_KEEP_BYTES}" \
        "$CS_BIN" -narrative rotate > /dev/null 2>&1
}

test_rotate_then_peer_append_merges_without_resurrection() {
    _make_clones
    _rotate_in "$CLONE_A" || return 1
    printf '\n## 2026-09-02 — from b\nappended on the other machine\n' >> "$CLONE_B/.cs/memory/narrative.alice.md"
    git -C "$CLONE_B" commit -qam "append on b"
    git -C "$CLONE_A" fetch -q "$CLONE_B" main
    git -C "$CLONE_A" merge -q --no-edit FETCH_HEAD > /dev/null 2>&1 || { echo "  FAIL: merge conflicted"; git -C "$CLONE_A" status --short; return 1; }
    local merged="$CLONE_A/.cs/memory/narrative.alice.md"
    assert_file_not_contains "$merged" "section 1$" "archived sections must not come back" || return 1
    assert_file_not_contains "$merged" "section 7$" "none of them" || return 1
    assert_file_contains "$merged" "section 8$" "the kept tail is intact" || return 1
    assert_file_contains "$merged" "appended on the other machine" "and the peer's append survives" || return 1
    assert_eq "4" "$(grep -c '^## ' "$merged")" "sections 8, 9, 10 and the appended one" || return 1
}

test_two_clones_rotating_at_different_cuts_merge_clean() {
    _make_clones
    _rotate_in "$CLONE_A" || return 1
    # B rotates with a larger tail budget, so its cut is earlier.
    _rotate_in "$CLONE_B" 3000 || return 1
    git -C "$CLONE_A" fetch -q "$CLONE_B" main
    git -C "$CLONE_A" merge -q --no-edit FETCH_HEAD > /dev/null 2>&1 || { echo "  FAIL: merge conflicted"; git -C "$CLONE_A" status --short; return 1; }
    local merged="$CLONE_A/.cs/memory/narrative.alice.md"
    assert_file_not_contains "$merged" "section 1$" "the earliest sections stay archived" || return 1
    assert_file_contains "$merged" "section 10$" "the newest section survives" || return 1
    # Both chunks exist; neither conflicts with the other (distinct names).
    assert_eq "2" "$(find "$CLONE_A/.cs/narrative-archive/alice" -name '*.md' | wc -l | tr -d ' ')" "two distinct chunks after the merge" || return 1
}
```

Runner additions:

```bash
run_test test_rotate_then_peer_append_merges_without_resurrection
run_test test_two_clones_rotating_at_different_cuts_merge_clean
```

- [ ] **Step 2: Run**

Run: `./build.sh && /bin/bash tests/test_narrative_rotate.sh`
Expected: PASS. If the first test fails with resurrected sections, the rewrite is touching the tail or reaching EOF — that is a real defect in `rotate_narrative`, not in the test.

- [ ] **Step 3: Commit**

```bash
git add tests/test_narrative_rotate.sh
git commit -m "test(narrative): prove rotation merges clean under merge=union across clones"
```

---

### Task 8: Stop hook — append-only contract and the over-budget line

**Files:**
- Modify: `hooks/narrative-reminder.sh` (the per-actor loop ~L628-641 and the `REASON=` line ~L660)
- Modify: `docs/hooks.md` (the two narrative-reminder bullets at L132-133)
- Modify: `tests/test_hooks.sh` (narrative-reminder section)

**Interfaces:**
- Consumes: `_num_or VALUE DEFAULT` already defined in the hook.

- [ ] **Step 1: Add the tests**

Insert after `test_narrative_reminder_tracks_per_actor` in `tests/test_hooks.sh`:

```bash
test_narrative_reminder_asks_for_appended_corrections_not_rewrites() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "append a dated correction" "corrections are appended" || return 1
    assert_output_contains "$output" "never rewrite or delete earlier sections" "earlier sections are immutable" || return 1
    assert_output_not_contains "$output" "correct or remove them" "the in-place instruction is gone" || return 1
}

test_narrative_reminder_flags_a_narrative_over_budget() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.alice.md is 2 KB, over the 2 KB budget" "names the file and the budget" || return 1
    assert_output_contains "$output" "cs -narrative rotate" "points at the rotation" || return 1
}

test_narrative_reminder_is_silent_about_budget_when_under() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    echo "# Session narrative (alice)" > "$nf"
    _backdate "$nf"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "block" "the reminder itself still fires" || return 1
    assert_output_not_contains "$output" "over the" "no budget line under budget" || return 1
}

test_narrative_reminder_budget_line_covers_a_teammates_file() {
    # The line names whichever file is over; the "if it is yours" clause leaves
    # the decision to the reader, since the hook does not resolve the actor.
    { echo "# Session narrative (bob)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.bob.md"
    _backdate "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    rm -f "$CLAUDE_SESSION_META_DIR/.narrative-reminder-cooldown"
    local output
    output=$(echo '{}' | CS_NARRATIVE_MAX_BYTES=2048 bash "$HOOKS_DIR/narrative-reminder.sh")
    assert_output_contains "$output" "narrative.bob.md is 2 KB" "names bob's file" || return 1
    assert_output_contains "$output" "if it is yours" "leaves ownership to the reader" || return 1
}
```

Add the four `run_test` lines next to the existing narrative-reminder runs.

- [ ] **Step 2: Run to see them fail**

Run: `/bin/bash tests/test_hooks.sh 2>&1 | grep -A3 -E "asks_for_appended|over_budget|silent_about_budget|teammates_file"`
Expected: the first two and the fourth FAIL.

- [ ] **Step 3: Implement in the hook**

Replace the per-actor loop (from `# Per-actor narratives: track the most recently modified narrative.*.md.` through the closing `done`) with:

```bash
# Per-actor narratives: track the most recently modified narrative.*.md, and
# note any that has outgrown its byte budget. The same stat pass serves both.
NARRATIVE_FILE=""
NARRATIVE_MTIME=0
# KEEP IN SYNC with CS_NARRATIVE_MAX_DEFAULT in lib/51-narrative.sh — hooks
# cannot source lib/, so the default is duplicated here.
NARRATIVE_MAX=$(_num_or "${CS_NARRATIVE_MAX_BYTES:-}" 131072)
NARRATIVE_OVER=""
for _nf in "$META_DIR"/memory/narrative*.md; do
    [ -f "$_nf" ] || continue
    if [[ "$OSTYPE" == "darwin"* ]]; then
        _m=$(stat -f %m "$_nf" 2>/dev/null || echo 0)
    else
        _m=$(stat -c %Y "$_nf" 2>/dev/null || echo 0)
    fi
    if [ "$_m" -ge "$NARRATIVE_MTIME" ]; then
        NARRATIVE_MTIME="$_m"
        NARRATIVE_FILE="$_nf"
    fi
    _sz=$(wc -c < "$_nf" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt "$NARRATIVE_MAX" ]; then
        NARRATIVE_OVER="${NARRATIVE_OVER} $(basename "$_nf") is $((_sz / 1024)) KB, over the $((NARRATIVE_MAX / 1024)) KB budget — if it is yours, run \`cs -narrative rotate\` before appending."
    fi
done
```

Replace the `REASON=` assignment with:

```bash
REASON="Narrative check. Update only your own narrative (run \`cs -whoami\` if unsure which actor you are; never edit a teammate's narrative). Newest on disk is $NARRATIVE_FILE. (1) If recent work disproved or superseded one of your entries, append a dated correction that names it — never rewrite or delete earlier sections. (2) Append any new findings as plain dated notes. If nothing needs changing, say so in one line and stop.${NARRATIVE_OVER}"
```

- [ ] **Step 4: Update `docs/hooks.md`**

Replace the two bullets

```
- Reminds Claude to review and update its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on the most recently modified `narrative.*.md`, when it has not been touched recently
- Cooldown-gated via `.cs/.narrative-reminder-cooldown` (at most once per 5 minutes); no size budget — narratives are native memory topic files that lazy-load
```

with

```
- Reminds Claude to review and append to its per-actor narrative (`.cs/memory/narrative.<actor>.md`, the session lab notebook), keyed on the most recently modified `narrative.*.md`, when it has not been touched recently. The contract is append-only: a disproven entry gets a dated correction that names it; earlier sections are never rewritten or deleted (that is what keeps `cs -narrative rotate`'s head-truncation safe under `merge=union`)
- Cooldown-gated via `.cs/.narrative-reminder-cooldown` (at most once per 5 minutes). The same stat pass measures every narrative against `CS_NARRATIVE_MAX_BYTES` (default 131072) and appends one line per file over budget naming it and pointing at `cs -narrative rotate`; nothing is rotated from the hook
```

- [ ] **Step 5: Run the hook suite and the docs guard**

Run: `/bin/bash tests/test_hooks.sh && /bin/bash tests/test_docs.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add hooks/narrative-reminder.sh docs/hooks.md tests/test_hooks.sh
git commit -m "feat(hooks): append-only narrative contract; flag a narrative over its byte budget"
```

---

### Task 9: `cs -doctor` warns on an oversized narrative

**Files:**
- Modify: `lib/60-doctor.sh` (new check after `_doctor_check_auto_memory`; call it in the session-gated group after `_doctor_check_auto_memory`)
- Modify: `tests/test_doctor.sh`

- [ ] **Step 1: Add the tests**

```bash
test_doctor_warns_on_a_narrative_over_budget() {
    local nf="$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    { echo "# Session narrative (alice)"; head -c 3000 /dev/zero | tr '\0' 'x'; echo; } > "$nf"
    local output
    output=$(CS_NARRATIVE_MAX_BYTES=2048 "$CS_BIN" -doctor 2>&1) || true
    # Colour escapes may sit between the [WARN] tag and the message, so the two
    # are pinned separately.
    assert_output_contains "$output" "Narrative: narrative.alice.md is 2 KB (budget 2 KB)" "warns with file and budget" || return 1
    assert_output_contains "$output" "run cs -narrative rotate" "points at the rotation" || return 1
    assert_output_contains "$output" "Warnings: " "the warning is counted" || return 1
}

test_doctor_reports_ok_when_narratives_fit() {
    echo "# Session narrative (alice)" > "$CLAUDE_SESSION_META_DIR/memory/narrative.alice.md"
    local output
    output=$("$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "Narrative: all within the 128 KB budget" "ok line names the budget" || return 1
    assert_output_not_contains "$output" "run cs -narrative rotate" "no warning" || return 1
}
```

Add `run_test` lines for both after `run_test test_doctor_reports_pass_for_healthy_session`.

- [ ] **Step 2: Run to see them fail**

Run: `./build.sh && /bin/bash tests/test_doctor.sh 2>&1 | grep -B1 -A3 "narrative"`
Expected: both FAIL (no Narrative line).

- [ ] **Step 3: Implement**

In `lib/60-doctor.sh`, after `_doctor_check_auto_memory`:

```bash
# A narrative past CS_NARRATIVE_MAX_BYTES is what `cs -narrative rotate` exists
# for; doctor only reports, it never rotates.
_doctor_check_narrative_size() {
    local dir="$CLAUDE_SESSION_META_DIR/memory"
    local max over=0 f sz
    max=$(_narrative_budget "${CS_NARRATIVE_MAX_BYTES:-}" "$CS_NARRATIVE_MAX_DEFAULT")
    for f in "$dir"/narrative*.md; do
        [ -f "$f" ] || continue
        sz=$(wc -c < "$f" | tr -d ' ')
        if [ "$sz" -gt "$max" ]; then
            _doctor_warn "Narrative: $(basename "$f") is $((sz / 1024)) KB (budget $((max / 1024)) KB) — run cs -narrative rotate"
            over=$((over + 1))
        fi
    done
    [ "$over" -gt 0 ] || _doctor_ok "Narrative: all within the $((max / 1024)) KB budget"
}
```

In `run_doctor`, add `_doctor_check_narrative_size` directly after `_doctor_check_auto_memory` inside the session-gated `if`.

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_doctor.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/60-doctor.sh tests/test_doctor.sh bin/cs
git commit -m "feat(doctor): warn when a narrative is over its byte budget"
```

---

### Task 10: `/wrap` runs the rotation; `/summary` reads live narratives only

**Files:**
- Modify: `commands/wrap.md`, `commands/summary.md`
- Modify: `tests/test_commands.sh`

- [ ] **Step 1: Add the pins**

```bash
test_wrap_rotates_the_narrative_after_the_summary() {
    assert_file_contains "$COMMANDS_DIR/wrap.md" "## Pass 3 — Narrative rotation" \
        "wrap has a third pass" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" 'cs -narrative rotate' \
        "the pass runs the cs helper rather than describing file surgery" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" '3\. \*\*Narrative:\*\*' \
        "the report gains a third item" || return 1
}

test_summary_reads_live_narratives_not_archives() {
    assert_file_not_contains "$COMMANDS_DIR/summary.md" "read all of them" \
        "the read-all instruction is gone" || return 1
    assert_file_contains "$COMMANDS_DIR/summary.md" "narrative-archive" \
        "summary knows where older sections went" || return 1
}
```

Add both to the runner.

- [ ] **Step 2: Run to see them fail**

Run: `/bin/bash tests/test_commands.sh 2>&1 | grep -A3 -E "rotates_the_narrative|live_narratives"`
Expected: both FAIL.

- [ ] **Step 3: Edit `commands/wrap.md`**

Change the opening sentence to: `Wrap up this session: distill durable memory entries, write a comprehensive summary, then rotate the narrative. Run the three passes back-to-back and report.`

Change `Do the passes in order — memory first (...), summary second (...).` to end with `..., rotation third (so the summary was written from the whole live narrative before its oldest sections leave it).`

After the Pass 2 section and before `## Report`, add:

```markdown
## Pass 3 — Narrative rotation

Run `cs -narrative rotate` once and keep its single output line. It archives the oldest `## ` sections of your narrative verbatim into `.cs/narrative-archive/<actor>/` when the live file is over its byte budget, and prints `nothing to rotate` otherwise. Do not read or edit the narrative yourself for this pass; the helper does the byte-exact cut and commits it when the session is tracked.
```

In `## Report`, change `Output a brief report with the two labeled items below.` to `three labeled items` and append:

```markdown
3. **Narrative:** the line `cs -narrative rotate` printed.
```

- [ ] **Step 4: Edit `commands/summary.md`**

Replace the step-1 bullet

```
   - .cs/memory/narrative.*.md (per-actor lab notebooks — read all of them: findings, observations, in-progress state)
```

with

```
   - .cs/memory/narrative.*.md (per-actor lab notebooks — the live files hold recent findings, observations, in-progress state; older sections were rotated into .cs/narrative-archive/<actor>/ and are history — grep one only when the summary needs a date or a detail the live file no longer carries)
```

- [ ] **Step 5: Run**

Run: `/bin/bash tests/test_commands.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add commands/wrap.md commands/summary.md tests/test_commands.sh
git commit -m "feat(commands): /wrap rotates the narrative as its third pass"
```

---

### Task 11: `cs -search` covers the archive

**Files:**
- Modify: `lib/65-sessions.sh` (`search_globs`)
- Modify: `tests/test_search.sh`

- [ ] **Step 1: Add the test**

```bash
test_search_finds_in_narrative_archive() {
    create_test_session "project-beta"
    mkdir -p "$CS_SESSIONS_ROOT/project-beta/.cs/narrative-archive/alice"
    printf '<!-- rotated from narrative.alice.md: 3 sections through 2026-07-01 -->\n\n## 2026-06-30 — the vault incident\nrotated needle-vault\n' \
        > "$CS_SESSIONS_ROOT/project-beta/.cs/narrative-archive/alice/2026-07-01-0123abcd.md"

    local output
    output=$("$CS_BIN" -search "needle-vault" 2>&1)

    assert_output_contains "$output" "project-beta" "Should show session name" || return 1
    assert_output_contains "$output" ".cs/narrative-archive/alice/2026-07-01-0123abcd.md" "Should show the archive path" || return 1
}
```

Add it to the runner.

- [ ] **Step 2: Run to see it fail**

Run: `./build.sh && /bin/bash tests/test_search.sh`
Expected: FAIL (no match).

- [ ] **Step 3: Implement**

In `search_sessions`, change

```bash
    local search_globs=".cs/memory/*.md"
```

to

```bash
    local search_globs=".cs/memory/*.md .cs/narrative-archive/*/*.md"
```

and wrap the glob loop so every pattern gets the session prefix — with two words in `$search_globs`, `"$real_dir"/$search_globs` prefixes only the first. Replace the block from `# Search glob patterns (memory files)` through its closing `done` with:

```bash
        # Search glob patterns (memory files and rotated narrative chunks)
        local glob
        for glob in $search_globs; do
            for filepath in "$real_dir"/$glob; do
                [ -f "$filepath" ] || continue
                local relpath="${filepath#"$real_dir"/}"
                local matches
                matches=$(grep -in -- "$query" "$filepath" 2>/dev/null) || continue
                while IFS= read -r line; do
                    # %s for the matched line: `echo -e` ate escapes in file content,
                    # so a line containing \c truncated the result there and dropped
                    # everything after it.
                    printf "${GOLD}%s${NC}: ${DIM}%s${NC}: %s\n" "$session_name" "$relpath" "$line"
                    found=$((found + 1))
                done <<< "$matches"
            done
        done
```

- [ ] **Step 4: Build and run**

Run: `./build.sh && /bin/bash tests/test_search.sh && /bin/bash tests/test_archive.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/65-sessions.sh tests/test_search.sh bin/cs
git commit -m "feat(search): include archived narrative chunks"
```

---

### Task 12: Resume wording on every surface, with a migration for files cs already wrote

**Files:**
- Modify: `lib/35-claudemd.sh` (`ensure_narrative_file` description and index line; `_emit_session_claude_md` two lines)
- Modify: `hooks/session-start.sh` (L324 and L675)
- Modify: `lib/45-migrate.sh` (Phase 13, called after Phase 4b's `ensure_narrative_file`)
- Modify: `README.md`, `docs/session-layout.md`
- Modify: `tests/test_migrate_claude_md.sh`, `tests/test_docs.sh`

**Interfaces:**
- Produces: `migrate_narrative_resume_wording SESSION_DIR` in `lib/45-migrate.sh`.

- [ ] **Step 1: Add the docs guard and the migration tests**

`tests/test_docs.sh`:

```bash
# Rotation made "read all narratives on resume" false. No user-facing surface
# may say it: the lib templates, the hooks, the commands, README and docs.
test_no_surface_tells_a_resume_to_read_every_narrative() {
    local hits
    hits=$(grep -rniE "read all narrative|read all of them|reads all of them|everyone reads all" \
        "$REPO/lib" "$REPO/hooks" "$REPO/commands" "$REPO/README.md" "$REPO/docs"/*.md 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "  FAIL: these surfaces still tell a resume to read every narrative:"
        printf '    %s\n' "$hits"
        return 1
    fi
}
```

`tests/test_migrate_claude_md.sh`:

```bash
# Files cs wrote before rotation existed carry the read-all sentence in three
# places cs owns: the narrative's own frontmatter, its MEMORY.md pointer and the
# protocol block in CLAUDE.local.md. A resume rewrites all three once.
test_migrate_rewrites_read_all_wording_cs_wrote() {
    local dir
    dir=$(create_test_session "wordy")
    printf -- '---\nname: session-narrative-alice\ndescription: Session lab-notebook and work-in-progress narrative for alice. Looser bar than durable memory. Read all narrative.*.md on resume.\ntype: narrative\n---\n# Session narrative (alice)\n\n## 2026-01-01 — kept\nbody mentions Read all narrative.*.md on resume. verbatim\n' \
        > "$dir/.cs/memory/narrative.alice.md"
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' \
        > "$dir/.cs/memory/MEMORY.md"
    printf '<!-- cs:session-protocol -->\n# Session Documentation Protocol\n\nAppend only to your own; read all narrative.*.md on resume to restore your\nworking narrative and see teammates'"'"' in-progress findings.\n\n<!-- cs:memory-note -->\nnote\n' \
        > "$dir/CLAUDE.local.md"
    CS_ACTOR=alice "$CS_BIN" "wordy" < /dev/null > /dev/null 2>&1 || true

    local desc
    desc=$(sed -n '3p' "$dir/.cs/memory/narrative.alice.md")
    case "$desc" in
        *"Read all narrative"*) echo "  FAIL: frontmatter description still says read all: $desc"; return 1 ;;
        *"narrative-archive"*) ;;
        *) echo "  FAIL: frontmatter description does not point at the archive: $desc"; return 1 ;;
    esac
    assert_file_contains "$dir/.cs/memory/narrative.alice.md" "body mentions Read all narrative\.\*\.md on resume\. verbatim" \
        "the narrative body is never rewritten" || return 1
    assert_file_not_contains "$dir/.cs/memory/MEMORY.md" "read all narrative" "index pointer rewritten" || return 1
    assert_file_contains "$dir/.cs/memory/MEMORY.md" "narrative-archive" "index pointer names the archive" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" "read all narrative" "protocol sentence rewritten" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "grep on demand, never preload" "with the live-plus-archive instruction" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->" "the following block is untouched" || return 1
}

test_migrate_read_all_rewrite_is_idempotent() {
    local dir
    dir=$(create_test_session "wordy2")
    printf -- '- [Session narrative — alice (lab notebook)](narrative.alice.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' \
        > "$dir/.cs/memory/MEMORY.md"
    CS_ACTOR=alice "$CS_BIN" "wordy2" < /dev/null > /dev/null 2>&1 || true
    local once
    once=$(cat "$dir/.cs/memory/MEMORY.md")
    CS_ACTOR=alice "$CS_BIN" "wordy2" < /dev/null > /dev/null 2>&1 || true
    assert_eq "$once" "$(cat "$dir/.cs/memory/MEMORY.md")" "second resume leaves the index byte-identical" || return 1
}
```

Add all three to their runners.

- [ ] **Step 2: Run to see them fail**

Run: `./build.sh && /bin/bash tests/test_docs.sh; /bin/bash tests/test_migrate_claude_md.sh`
Expected: the docs guard FAILS listing every current surface; both migration tests FAIL.

- [ ] **Step 3: Rewrite the templates in `lib/35-claudemd.sh`**

In `ensure_narrative_file`, the frontmatter `description:` line becomes:

```
description: Session lab-notebook and work-in-progress narrative for $actor. Looser bar than durable memory. Read the live narrative.*.md on resume; older sections are archived under .cs/narrative-archive/.
```

The index pointer `printf` becomes:

```bash
        printf -- '- [Session narrative — %s (lab notebook)](narrative.%s.md): looser-bar work-in-progress; read the live narrative.*.md on resume, older sections under .cs/narrative-archive/\n' "$actor" "$actor" >> "$index"
```

In `_emit_session_claude_md`, replace the two lines

```
Append only to your own; read all narrative.*.md on resume to restore your
working narrative and see teammates' in-progress findings.
```

with

```
Append only to your own; on resume read the live narrative.*.md (rotation keeps
them small). Older sections sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload.
```

and the numbered item 3 `Per-actor lab notebooks (yours + teammates'): findings, in-progress state, observations` keeps its text.

- [ ] **Step 4: Rewrite the two hook lines in `hooks/session-start.sh`**

L324:

```
- .cs/memory/narrative.$ACTOR_SLUG.md: append findings as you go; on resume read the live narrative.*.md (older sections: .cs/narrative-archive/<actor>/, grep on demand)
```

L675:

```
- .cs/memory/narrative.*.md — findings and decisions from earlier work (append only to your own actor's file; older sections under .cs/narrative-archive/<actor>/)
```

- [ ] **Step 5: Add Phase 13 to `lib/45-migrate.sh`**

Add the function above `migrate_session`:

```bash
# Rewrite the three read-all-narratives sentences cs wrote into existing
# sessions: a narrative's frontmatter description, its MEMORY.md pointer and the
# protocol block in CLAUDE.local.md. Only the exact sentences cs emitted are
# touched — a narrative body or a user's own prose never is. Temp+mv rather than
# sed -i (BSD/GNU disagree on -i). Idempotent: nothing matches on the second run.
migrate_narrative_resume_wording() {
    local session_dir="$1"
    local mem="$session_dir/.cs/memory" f tmp
    for f in "$mem"/narrative.*.md; do
        [ -f "$f" ] || continue
        head -8 "$f" | grep -q 'Read all narrative\.\*\.md on resume\.' || continue
        tmp="$f.tmp"
        sed '1,8s/Read all narrative\.\*\.md on resume\./Read the live narrative.*.md on resume; older sections are archived under .cs\/narrative-archive\/./' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    done
    f="$mem/MEMORY.md"
    if [ -f "$f" ] && grep -q 'read all narrative\.\*\.md on resume' "$f"; then
        tmp="$f.tmp"
        sed 's/read all narrative\.\*\.md on resume/read the live narrative.*.md on resume, older sections under .cs\/narrative-archive\//' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    fi
    f="$session_dir/CLAUDE.local.md"
    if [ -f "$f" ] && grep -q 'read all narrative\.\*\.md on resume to restore your' "$f"; then
        tmp="$f.tmp"
        awk '
            $0 == "Append only to your own; read all narrative.*.md on resume to restore your" {
                getline nextline
                if (nextline ~ /^working narrative and see teammates/) {
                    print "Append only to your own; on resume read the live narrative.*.md (rotation keeps"
                    print "them small). Older sections sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload."
                    next
                }
                print; print nextline; next
            }
            { print }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
    fi
}
```

In `migrate_session`, directly after the Phase 4b `ensure_narrative_file "$session_dir"` line:

```bash
    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation.
    migrate_narrative_resume_wording "$session_dir"
```

- [ ] **Step 6: README and session-layout**

`README.md` Concepts bullet for **Narrative** becomes:

```
- **Narrative** (`.cs/memory/narrative.<actor>.md`) — A per-actor lab notebook for findings, observations, and ideas during a session. Each co-developer writes their own file (so shared sessions never conflict) and everyone reads the live files on resume. The notebook is append-only — a disproven entry gets a dated correction, never an edit — and `cs -narrative rotate` (run by `/wrap`, flagged by the Stop hook and `cs -doctor`) moves the oldest sections verbatim into `.cs/narrative-archive/<actor>/` once a file passes `CS_NARRATIVE_MAX_BYTES` (128 KiB), keeping a `CS_NARRATIVE_KEEP_BYTES` (64 KiB) tail. Stored as native Claude Code memory files; see [docs/session-layout.md](docs/session-layout.md) for how that works.
```

`README.md` "Sharing a session between machines" — append a bullet after the union-merge one:

```
- **Narrative rotation stays merge-safe.** `cs -narrative rotate` removes one interior run of sections and leaves the tail byte-identical, which is the only rewrite `merge=union` merges cleanly against a peer's append (renaming the file or truncating to EOF both resurrect the whole body — measured). Archive chunks are immutable and content-addressed, so two machines archiving the same sections produce the same file.
```

`README.md` Slash Commands `/wrap` line becomes:

```
- `/wrap` — The canonical end-of-session command: runs the `/sweep` memory pass, then the `/summary` narrative, then `cs -narrative rotate`
```

`README.md` directory tree (around the `memory/` and `checkpoints/` lines): add

```
│   ├── narrative-archive/  # Rotated narrative sections, one immutable chunk per rotation per actor
```

`docs/session-layout.md` table: after the `narrative.<actor>.md` row (and change that row's "everyone reads all of them on resume" to "everyone reads the live files on resume; append-only"), add:

```
| `.cs/narrative-archive/<actor>/<through-date>-<blob8>.md` | Sections `cs -narrative rotate` moved out of the live narrative, verbatim. Immutable once written; the name is derived from the content, so two machines archiving the same sections produce the same file. | default |
```

- [ ] **Step 7: Build and run every touched suite**

Run: `./build.sh && /bin/bash tests/test_docs.sh && /bin/bash tests/test_migrate_claude_md.sh && /bin/bash tests/test_auto_memory.sh && /bin/bash tests/test_memory_rules.sh && /bin/bash tests/test_actor_identity.sh && /bin/bash tests/test_hooks.sh`
Expected: PASS. (No existing test pins the old sentence — verified with `rg -i "read all narrative" tests/` before this plan was written — so a failure here is a real regression, not a stale pin.)

- [ ] **Step 8: Commit**

```bash
git add lib/35-claudemd.sh lib/45-migrate.sh hooks/session-start.sh README.md docs/session-layout.md tests/test_migrate_claude_md.sh tests/test_docs.sh bin/cs
git commit -m "feat(narrative): resume reads live narratives only; migrate the wording cs already wrote"
```

---

### Task 13: Full suite under bash 3.2, spec status, deploy check

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-narrative-rotation-design.md` (status line)

- [ ] **Step 1: Run the whole suite the way CI does**

Run: `./build.sh && /bin/bash tests/run_all.sh`
Expected: every suite green. Any failure is yours to fix before continuing, whether or not this plan caused it.

- [ ] **Step 2: Run the rotation for real against a copy of a large narrative**

```bash
S=$(mktemp -d); mkdir -p "$S/.cs/memory"; cp .cs/memory/narrative.hex-users-noreply-github-com.md "$S/.cs/memory/narrative.alice.md"
CS_ACTOR=alice CLAUDE_SESSION_NAME=probe CLAUDE_SESSION_DIR="$S" CLAUDE_SESSION_META_DIR="$S/.cs" bin/cs -narrative rotate
ls -la "$S/.cs/narrative-archive/alice/"; wc -c "$S/.cs/memory/narrative.alice.md"
{ head -c $(( $(grep -bm1 '^## ' "$S/.cs/memory/narrative.alice.md" | cut -d: -f1) )) "$S/.cs/memory/narrative.alice.md"; sed '1,3d' "$S"/.cs/narrative-archive/alice/*.md; tail -c +$(( $(grep -bm1 '^## ' "$S/.cs/memory/narrative.alice.md" | cut -d: -f1) + 1 )) "$S/.cs/memory/narrative.alice.md"; } | cmp - .cs/memory/narrative.hex-users-noreply-github-com.md && echo "REBUILDS BYTE FOR BYTE"
rm -rf "$S"
```

Expected: one chunk of roughly 700 KB, live file about 64 KB, and `REBUILDS BYTE FOR BYTE`. This is pipeline-produced data, not a fixture; if the rebuild differs, stop and find out why before anything ships.

- [ ] **Step 3: Update the spec status**

Change `**Status:** design, awaiting review` to `**Status:** implemented on feat/narrative-rotation (plan: docs/superpowers/plans/2026-08-31-narrative-rotation.md)`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-31-narrative-rotation-design.md
git commit -m "docs(spec): narrative rotation implemented"
```

- [ ] **Step 5: Hand off**

Report: the suite command and its final tally, the Step 2 output, and that the deployed hooks/commands now differ from the checkout (`cs -doctor` will say so until `./install.sh` or the release deploys them). Merge and deploy are Alex's call.
