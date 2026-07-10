# Cross-Session Comms Phase 1: Presence & Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two cs commands — `cs -live` (list sessions running right now on this machine) and `cs -status` (set/get/clear the current session's advertised status) — backed by one per-machine file.

**Architecture:** Pure single-host, file-based, no daemon. Liveness reuses the existing `.cs/session.lock` PID + `kill -0` signal (the same one `cs-tui` trusts). `cs -status` writes a single-line `.cs/local/presence` file atomically; `cs -live` enumerates sessions (mirroring `list_sessions`), filters to live, and shows actor + uptime + status. Status falls back to the README objective read live, so no seeding is needed and no hook changes.

**Tech Stack:** Bash (macOS stock `/bin/bash` 3.2 + BSD userland), assembled from `lib/*.sh` into `bin/cs` by `build.sh`. Bash test harness under `tests/`.

## Global Constraints

- **Machine-local only.** No networked/cross-machine coordination; never imply "online" beyond a same-host process being alive. (Spec: stays inside `multi-person-codev.md:28` design law.)
- **bash 3.2 + BSD userland.** CI runs the whole suite under macOS stock bash 3.2. No bash 4+ features (`local -A`, `mapfile`, `${x^^}`, `printf %(...)T`), no GNU-only `sed`/`awk`/`stat`/`timeout`. Cross-platform `stat` needs a BSD/GNU branch.
- **Source of truth is `lib/*.sh`.** Never hand-edit `bin/cs`. After ANY `lib/` change, run `./build.sh` and commit the regenerated `bin/cs` — CI's `build-sync` job fails otherwise.
- **The lock file is `<session>/.cs/session.lock`** (sibling to `.cs/local/`, NOT inside it).
- **Presence is the one new write path:** `<session>/.cs/local/presence`, single line, per-machine, gitignored (`.cs/local/` is ignored wholesale), single-writer under normal use. No merge driver. Local clock permitted because the file is untracked.
- **Single-dash verb convention.** `-live` is global (top-level dispatch only, like `-list`); `-status` is in-session (top-level dispatch, resolves the current session from ambient `CLAUDE_SESSION_META_DIR`, like `-queue`). Neither is wired in the session-scoped arm.
- **Tests run against the built `bin/cs`.** Every test assertion line ends `|| return 1` (the harness disables errexit only at the top-level `run_test` call).
- **No hooks are modified in Phase 1.**

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `lib/56-presence.sh` | **create** | presence file r/w, README-objective fallback, effective-status resolver, `run_status` (`cs -status`) |
| `lib/15-lock.sh` | modify | add `read_lock_pid`, `session_is_live`, `session_uptime_secs`, `_epoch_mtime` (lock-file liveness + launch-time) |
| `lib/40-state.sh` | modify | add `session_actor_slug` (per-session actor, bypassing `$CS_ACTOR`) |
| `lib/65-sessions.sh` | modify | add `_humanize_secs` + `cmd_live` (`cs -live`) |
| `lib/99-main.sh` | modify | wire `-status` and `-live` in the top-level arm |
| `lib/10-help.sh` | modify | add `-status` (Task 1) and `-live` (Task 2) to `show_help` |
| `completions/_cs`, `completions/cs.bash` | modify | add `-live`, `-status` to the global-flag lists |
| `README.md` | modify | document both commands |
| `bin/cs` | regenerated | `./build.sh` output, committed each lib-touching task |
| `tests/test_presence.sh` | **create** | `cs -status` behavior |
| `tests/test_live.sh` | **create** | `cs -live` behavior |

---

## Task 1: `cs -status` + presence primitive

**Files:**
- Create: `lib/56-presence.sh`
- Modify: `lib/99-main.sh` (top-level arm, before the `-*)` catch-all at ~`:136`)
- Modify: `lib/10-help.sh` (add the `-status` line to `show_help`)
- Regenerate + commit: `bin/cs` (via `./build.sh`)
- Test: `tests/test_presence.sh`

**Interfaces:**
- Produces (later tasks rely on these):
  - `session_status <session_dir>` → prints the session's effective status (presence file → README objective → empty). `<session_dir>` is the session root; its meta dir is `<session_dir>/.cs`.
  - `_read_presence <meta_dir>` → prints the raw presence line (empty if unset). `<meta_dir>` is the `.cs` dir.
  - `run_status "$@"` → the `cs -status` dispatcher (requires ambient `CLAUDE_SESSION_META_DIR`).
- Consumes: `error` (from `lib/05-term.sh`), `CLAUDE_SESSION_META_DIR` / `CLAUDE_SESSION_DIR` (exported by a launched session).

- [ ] **Step 1: Write the failing test**

Create `tests/test_presence.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the cs -status verb and the .cs/local/presence file.
# ABOUTME: Covers set/get/clear, special-char preservation, README fallback, guards.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    export CLAUDE_SESSION_NAME="test-session"
    export CLAUDE_SESSION_DIR="$CS_SESSIONS_ROOT/test-session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

PFILE() { printf '%s' "$CLAUDE_SESSION_META_DIR/local/presence"; }
# Write a README with the given objective under a '## Objective' heading.
seed_readme() { # objective-text
    printf '# test-session\n\n## Objective\n\n%s\n' "$1" > "$CLAUDE_SESSION_DIR/.cs/README.md"
}

test_status_set_writes_presence_file() {
    "$CS_BIN" -status "refactoring the parser" >/dev/null 2>&1
    assert_file_contains "$(PFILE)" "refactoring the parser" "set writes the status" || return 1
    assert_eq "1" "$(grep -c . "$(PFILE)")" "presence is a single line" || return 1
}

# assert_file_contains matches with grep BRE; the string below has no BRE
# metacharacters, so it matches literally. The point is to prove quotes and '='
# survive the write (unlike _read_local_state, which would strip the quotes).
test_status_preserves_quotes_and_equals() {
    "$CS_BIN" -status 'fix the "auth" bug = hard' >/dev/null 2>&1
    assert_file_contains "$(PFILE)" 'fix the "auth" bug = hard' "special chars preserved verbatim" || return 1
}

test_status_joins_multiple_words() {
    "$CS_BIN" -status wiring the mailbox up >/dev/null 2>&1
    assert_file_contains "$(PFILE)" "wiring the mailbox up" "unquoted words are joined" || return 1
}

test_status_get_shows_presence() {
    "$CS_BIN" -status "doing X" >/dev/null 2>&1
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "doing X" "get shows the set status" || return 1
}

test_status_get_falls_back_to_readme_objective() {
    seed_readme "Ship the presence feature"
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "Ship the presence feature" "get falls back to README objective" || return 1
}

test_status_get_none_when_empty() {
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "(none)" "get shows (none) with no status and no objective" || return 1
}

test_status_clear_removes_file() {
    "$CS_BIN" -status "doing X" >/dev/null 2>&1
    "$CS_BIN" -status --clear >/dev/null 2>&1
    assert_file_not_exists "$(PFILE)" "clear removes the presence file" || return 1
}

test_status_empty_string_is_usage_error() {
    if "$CS_BIN" -status "" >/dev/null 2>&1; then
        echo "  FAIL: expected non-zero for empty status"; return 1
    fi
    return 0
}

test_status_requires_session() {
    unset CLAUDE_SESSION_META_DIR
    local out; if out=$("$CS_BIN" -status "x" 2>&1); then
        echo "  FAIL: expected non-zero outside a session"; return 1
    fi
    assert_output_contains "$out" "session" "explains it needs a session" || return 1
}

test_status_set_leaves_no_temp() {
    "$CS_BIN" -status "hello" >/dev/null 2>&1
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/presence.tmp" "no temp file remains after set" || return 1
}

test_status_clear_reverts_to_objective() {
    seed_readme "Ship the presence feature"
    "$CS_BIN" -status "temporary note" >/dev/null 2>&1
    "$CS_BIN" -status --clear >/dev/null 2>&1
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "Ship the presence feature" "clear reverts get to the README objective" || return 1
}

test_status_get_filters_readme_placeholder() {
    printf '# test-session\n\n## Objective\n\n[Describe what you are trying to accomplish]\n' > "$CLAUDE_SESSION_DIR/.cs/README.md"
    local out; out="$("$CS_BIN" -status 2>&1)"
    assert_output_contains "$out" "(none)" "unfilled placeholder objective yields (none)" || return 1
}

run_test test_status_set_writes_presence_file
run_test test_status_preserves_quotes_and_equals
run_test test_status_joins_multiple_words
run_test test_status_get_shows_presence
run_test test_status_get_falls_back_to_readme_objective
run_test test_status_get_none_when_empty
run_test test_status_clear_removes_file
run_test test_status_empty_string_is_usage_error
run_test test_status_requires_session
run_test test_status_set_leaves_no_temp
run_test test_status_clear_reverts_to_objective
run_test test_status_get_filters_readme_placeholder

report_results
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_presence.sh`
Expected: FAIL — `cs -status` is an unknown command (`Unknown command: -status`), so every case errors.

- [ ] **Step 3: Create `lib/56-presence.sh`**

```bash
# ABOUTME: Per-session advertised status (presence). Backs 'cs -status'.
# ABOUTME: A single-line status file at .cs/local/presence, read by 'cs -live'.

# Absolute path to a session's presence file. Arg: the session's .cs meta dir.
_presence_file() {  # meta_dir
    printf '%s' "$1/local/presence"
}

# Write a one-line status atomically (tmp+mv). Newlines/CRs collapse to spaces so
# the file stays exactly one line. Arg: meta_dir, text.
_write_presence() {  # meta_dir, text
    local meta_dir="$1" text="$2" file
    file="$(_presence_file "$meta_dir")"
    mkdir -p "$(dirname "$file")"
    text="$(printf '%s' "$text" | tr '\n\r' '  ')"
    printf '%s\n' "$text" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Print a session's raw presence status (empty if unset). Arg: meta_dir.
_read_presence() {  # meta_dir
    local file line
    file="$(_presence_file "$1")"
    [ -f "$file" ] || return 0
    IFS= read -r line < "$file" || true
    printf '%s' "${line:-}"
}

# Print a session's objective from its README (first non-empty line under the
# '## Objective' heading), with the unfilled [Describe...] placeholder filtered
# to empty. Arg: session_dir (the session root, whose README is .cs/README.md).
_session_objective() {  # session_dir
    local readme="$1/.cs/README.md"
    [ -f "$readme" ] || return 0
    awk '
        /^##[[:space:]]+Objective/ { grab=1; next }
        grab && /^##[[:space:]]/    { exit }
        grab && NF {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\[.*\]$/) next
            print line
            exit
        }
    ' "$readme" 2>/dev/null || true
}

# Print a session's effective status: presence file, else README objective,
# else empty. Arg: session_dir (the session root).
session_status() {  # session_dir
    local session_dir="$1" status
    status="$(_read_presence "$session_dir/.cs")"
    [ -n "$status" ] || status="$(_session_objective "$session_dir")"
    printf '%s' "$status"
}

# Dispatcher for 'cs -status'. In-session only (ambient env), like run_queue.
run_status() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -status must be run inside a cs session"
    fi
    local meta_dir="$CLAUDE_SESSION_META_DIR"
    if [ $# -eq 0 ]; then
        local session_dir status
        session_dir="${CLAUDE_SESSION_DIR:-$(dirname "$meta_dir")}"
        status="$(session_status "$session_dir")"
        if [ -n "$status" ]; then printf '%s\n' "$status"; else echo "(none)"; fi
        return 0
    fi
    case "$1" in
        --clear|-c)
            rm -f "$(_presence_file "$meta_dir")"
            ;;
        "")
            error "cs -status: empty status; use 'cs -status --clear' to clear"
            ;;
        *)
            _write_presence "$meta_dir" "$*"
            ;;
    esac
}
```

- [ ] **Step 4: Wire `-status` into the top-level dispatch**

In `lib/99-main.sh`, inside the top-level `case "$cmd" in` block, add this arm immediately BEFORE the `-*)` catch-all (currently at `:136`), right after the `-queue)` arm:

```bash
        -status)
            shift
            run_status "$@"
            return 0
            ;;
```

Then add `-status` to `cs -help`. In `lib/10-help.sh`'s `show_help` heredoc, insert the `-status` line after the `-who` line:

Change:
```
  -who                Show who contributed to shared memory/narrative (git history)
  -remove, -rm <name> Remove a session
```
to:
```
  -who                Show who contributed to shared memory/narrative (git history)
  -status "<text>"    Set this session's advertised status (also: -status, -status --clear)
  -remove, -rm <name> Remove a session
```

- [ ] **Step 5: Rebuild `bin/cs`**

Run: `./build.sh`
Expected: `Built bin/cs from N lib fragments (... lines)` with no `bash -n` error. (The new `lib/56-presence.sh` is picked up automatically by the numeric glob.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test_presence.sh`
Expected: PASS — all 9 tests OK.

- [ ] **Step 7: Commit**

```bash
git add lib/56-presence.sh lib/99-main.sh lib/10-help.sh bin/cs tests/test_presence.sh
git commit -m "feat(cs): add cs -status (per-session presence)"
```

---

## Task 2: `cs -live` + discovery helpers

**Files:**
- Modify: `lib/15-lock.sh` (add liveness/uptime helpers)
- Modify: `lib/40-state.sh` (add `session_actor_slug`)
- Modify: `lib/65-sessions.sh` (add `_humanize_secs`, `cmd_live`)
- Modify: `lib/99-main.sh` (top-level arm: wire `-live`)
- Modify: `lib/10-help.sh` (add the `-live` line to `show_help`)
- Regenerate + commit: `bin/cs` (via `./build.sh`)
- Test: `tests/test_live.sh`

**Interfaces:**
- Consumes (from Task 1): `session_status <session_dir>`.
- Consumes (existing): `is_session_dir <dir>` (`lib/65-sessions.sh`), `_slugify <str>` (`lib/40-state.sh`), `SESSIONS_ROOT`, `error`, color vars `GOLD`/`COMMENT`/`NC` (`lib/05-term.sh`).
- Produces: `session_is_live <meta_dir>`, `session_uptime_secs <meta_dir> <now_epoch>`, `read_lock_pid <meta_dir>`, `session_actor_slug <session_dir>`, `cmd_live`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_live.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the cs -live verb (list live sessions on this machine).
# ABOUTME: Covers live/dead filtering, actor/uptime/status columns, current marker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CLAUDE_CODE_BIN="echo"
    mkdir -p "$CS_SESSIONS_ROOT"
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_ACTOR 2>/dev/null || true
}
teardown() {
    # Reap sleepers by reading PIDs from the lock files the fixtures wrote (a
    # subshell-safe alternative to a shell array), then drop the temp tree.
    local lf pid
    if [ -n "${CS_SESSIONS_ROOT:-}" ]; then
        for lf in "$CS_SESSIONS_ROOT"/*/.cs/session.lock; do
            [ -f "$lf" ] || continue
            pid="$(cat "$lf" 2>/dev/null || true)"
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Create a live session: real .cs/, lock holding a RUNNING pid. NEVER call this
# via $(...) — the backgrounded sleep inherits the command-substitution's pipe
# write end, so the substitution would block ~300s. Call it directly; the path
# is deterministic ($CS_SESSIONS_ROOT/<name>).
make_live_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}
# Create a session whose lock holds a dead pid (started, then killed+reaped).
make_dead_session() { # name
    local sdir="$CS_SESSIONS_ROOT/$1" p
    mkdir -p "$sdir/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true
    printf '%s\n' "$p" > "$sdir/.cs/session.lock"
}

test_live_includes_live_excludes_dead() {
    make_live_session alive-one >/dev/null
    make_dead_session dead-one >/dev/null
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alive-one" "live session listed" || return 1
    case "$out" in *dead-one*) echo "  FAIL: dead session listed"; return 1;; esac
    return 0
}

test_live_shows_presence_status() {
    make_live_session busy-one
    printf 'wiring the mailbox\n' > "$CS_SESSIONS_ROOT/busy-one/.cs/local/presence"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "wiring the mailbox" "status column shows presence" || return 1
}

test_live_falls_back_to_readme_objective() {
    make_live_session obj-one
    printf '# obj-one\n\n## Objective\n\nShip presence\n' > "$CS_SESSIONS_ROOT/obj-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "Ship presence" "status falls back to objective" || return 1
}

test_live_filters_readme_placeholder() {
    make_live_session ph-one
    printf '# ph-one\n\n## Objective\n\n[Describe what you are trying to accomplish]\n' > "$CS_SESSIONS_ROOT/ph-one/.cs/README.md"
    local out; out="$("$CS_BIN" -live 2>&1)"
    case "$out" in *Describe*) echo "  FAIL: placeholder shown as status"; return 1;; esac
    return 0
}

test_live_marks_current_session() {
    make_live_session mine >/dev/null
    export CLAUDE_SESSION_NAME="mine"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "(this session)" "current session marked" || return 1
    unset CLAUDE_SESSION_NAME
}

test_live_actor_is_sessions_own_not_invoker() {
    make_live_session actor-one
    printf 'alice@example.com\n' > "$CS_SESSIONS_ROOT/actor-one/.cs/local/identity"
    export CS_ACTOR="bob@invoker.com"
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "alice" "row shows the session's own actor" || return 1
    case "$out" in *bob*) echo "  FAIL: invoker CS_ACTOR leaked onto row"; return 1;; esac
    unset CS_ACTOR
}

test_live_none_message_when_no_live() {
    make_dead_session only-dead
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "No other live cs sessions" "prints the empty message" || return 1
}

test_live_marks_current_via_symlink() {
    # Reached through a symlink; the marker matches by CLAUDE_SESSION_NAME
    # (basename), not by resolved path, so the row is still marked.
    local target="$TEST_TMPDIR/real-target" p
    mkdir -p "$target/.cs/local"
    sleep 300 >/dev/null 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$target/.cs/session.lock"
    ln -s "$target" "$CS_SESSIONS_ROOT/linked-one"
    export CLAUDE_SESSION_NAME="linked-one"
    export CLAUDE_SESSION_DIR="$target"   # resolved path, differs from the symlink path
    local out; out="$("$CS_BIN" -live 2>&1)"
    kill "$p" 2>/dev/null || true
    assert_output_contains "$out" "(this session)" "symlinked current session marked by name" || return 1
}

test_live_uptime_from_lock_mtime() {
    make_live_session up-one
    local lock="$CS_SESSIONS_ROOT/up-one/.cs/session.lock"
    # Back-date the lock ~2h. BSD: touch -A -HHMMSS; GNU: touch -d "2 hours ago".
    if ! touch -A -020000 "$lock" 2>/dev/null; then
        touch -d "2 hours ago" "$lock" 2>/dev/null || true
    fi
    local out; out="$("$CS_BIN" -live 2>&1)"
    assert_output_contains "$out" "2h" "uptime reflects the lock mtime (~2h)" || return 1
}

test_live_empty_root_message_and_exit0() {
    rm -rf "$CS_SESSIONS_ROOT"   # exercise the [ ! -d "$SESSIONS_ROOT" ] branch
    local out rc
    out="$("$CS_BIN" -live 2>&1)"; rc=$?
    assert_output_contains "$out" "No other live cs sessions" "empty root prints the message" || return 1
    assert_eq "0" "$rc" "empty root exits 0" || return 1
}

run_test test_live_includes_live_excludes_dead
run_test test_live_shows_presence_status
run_test test_live_falls_back_to_readme_objective
run_test test_live_filters_readme_placeholder
run_test test_live_marks_current_session
run_test test_live_marks_current_via_symlink
run_test test_live_actor_is_sessions_own_not_invoker
run_test test_live_uptime_from_lock_mtime
run_test test_live_empty_root_message_and_exit0
run_test test_live_none_message_when_no_live

report_results
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_live.sh`
Expected: FAIL — `-live` is an unknown command, so every case fails.

- [ ] **Step 3: Add liveness/uptime helpers to `lib/15-lock.sh`**

Append these functions to `lib/15-lock.sh` (after `release_session_lock`):

```bash
# Print the PID recorded in a session's lock file (empty if none). Arg: meta_dir.
read_lock_pid() {  # meta_dir
    local f="$1/session.lock"
    [ -f "$f" ] || return 0
    cat "$f" 2>/dev/null || true
}

# True (exit 0) when a session's process is currently alive on this machine.
# Arg: meta_dir (the session's .cs dir).
session_is_live() {  # meta_dir
    local pid
    pid="$(read_lock_pid "$1")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Epoch mtime of a file (BSD/GNU stat), 0 on error. Arg: path.
_epoch_mtime() {  # path
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f %m "$1" 2>/dev/null || echo 0
    else
        stat -c %Y "$1" 2>/dev/null || echo 0
    fi
}

# Seconds since a session was last launched (its lock file's mtime).
# Args: meta_dir, now_epoch. Prints 0 if the lock is absent/unreadable.
session_uptime_secs() {  # meta_dir, now_epoch
    local f="$1/session.lock" now="$2" started
    [ -f "$f" ] || { echo 0; return 0; }
    started="$(_epoch_mtime "$f")"
    case "$started" in ''|*[!0-9]*) echo 0; return 0;; esac
    [ "$started" -gt 0 ] || { echo 0; return 0; }
    echo $(( now - started ))
}
```

- [ ] **Step 4: Add `session_actor_slug` to `lib/40-state.sh`**

Append to `lib/40-state.sh` (after `cs_actor_slug`):

```bash
# Resolve a SPECIFIC session's actor slug from its own dir, bypassing $CS_ACTOR
# (which cs_actor_slug honours first and would otherwise stamp the caller's
# identity onto every 'cs -live' row). Arg: session_dir (session root).
# Falls back to git config in that dir, then 'unknown'. Always slugified.
session_actor_slug() {  # session_dir
    local session_dir="$1" raw="" id_file="$1/.cs/local/identity"
    if [ -f "$id_file" ]; then IFS= read -r raw < "$id_file" || true; fi
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.email 2>/dev/null || true)"
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.name 2>/dev/null || true)"
    [ -n "$raw" ] || raw="unknown"
    _slugify "$raw"
}
```

- [ ] **Step 5: Add `_humanize_secs` + `cmd_live` to `lib/65-sessions.sh`**

Append to `lib/65-sessions.sh`:

```bash
# Compact duration string from seconds: 45s, 12m, 3h, 2d. Arg: secs.
_humanize_secs() {  # secs
    local s="$1"
    case "$s" in ''|*[!0-9]*) echo "0s"; return 0;; esac
    if   [ "$s" -lt 60 ];    then echo "${s}s"
    elif [ "$s" -lt 3600 ];  then echo "$(( s / 60 ))m"
    elif [ "$s" -lt 86400 ]; then echo "$(( s / 3600 ))h"
    else echo "$(( s / 86400 ))d"
    fi
}

# List cs sessions whose process is currently alive on THIS machine.
cmd_live() {
    if [ ! -d "$SESSIONS_ROOT" ]; then
        echo "No other live cs sessions."
        return 0
    fi
    local now current others=0
    now="$(date +%s)"
    current="${CLAUDE_SESSION_NAME:-}"

    local dir name meta actor up status
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        meta="$dir/.cs"
        session_is_live "$meta" || continue
        name="$(basename "$dir")"
        actor="$(session_actor_slug "$dir")"
        up="$(_humanize_secs "$(session_uptime_secs "$meta" "$now")")"
        if [ "$name" = "$current" ]; then
            status="(this session)"
        else
            others=$(( others + 1 ))
            status="$(session_status "$dir")"
        fi
        printf "${GREEN}●${NC} ${GOLD}%-18s${NC} ${COMMENT}%-10s %-5s${NC} %s\n" \
            "$name" "$actor" "$up" "$status"
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 | sort -z)

    if [ "$others" -eq 0 ]; then
        echo "No other live cs sessions."
    fi
}
```

> `${GREEN}` exists in `lib/05-term.sh` (alongside `GOLD`, `COMMENT`, `NC`), and every palette var renders empty under a non-TTY, so test assertions see plain text.

- [ ] **Step 6: Wire `-live` into the top-level dispatch**

In `lib/99-main.sh`, add this arm before the `-*)` catch-all (next to `-status` from Task 1):

```bash
        -live)
            cmd_live
            return 0
            ;;
```

Then add `-live` to `cs -help`. In `lib/10-help.sh`'s `show_help` heredoc, insert the `-live` line above the `-status` line added in Task 1:

Change:
```
  -who                Show who contributed to shared memory/narrative (git history)
  -status "<text>"    Set this session's advertised status (also: -status, -status --clear)
```
to:
```
  -who                Show who contributed to shared memory/narrative (git history)
  -live               List sessions running right now on this machine
  -status "<text>"    Set this session's advertised status (also: -status, -status --clear)
```

- [ ] **Step 7: Rebuild and test**

Run: `./build.sh && bash tests/test_live.sh`
Expected: `Built bin/cs ...` then all 7 `cs -live` tests PASS. Also re-run Task 1's suite to confirm no regression: `bash tests/test_presence.sh` (all PASS).

- [ ] **Step 8: Commit**

```bash
git add lib/15-lock.sh lib/40-state.sh lib/65-sessions.sh lib/99-main.sh lib/10-help.sh bin/cs tests/test_live.sh
git commit -m "feat(cs): add cs -live (list live sessions on this machine)"
```

---

## Task 3: Completions + README docs

**Files:**
- Modify: `completions/_cs` (zsh global-flag list)
- Modify: `completions/cs.bash` (bash global-flag string)
- Modify: `README.md` (Usage block + a short subsection)
- No `lib/` change → no `build.sh` needed. (The `cs -help` text was already updated in Tasks 1 & 2 — do NOT touch `lib/10-help.sh` here, or you would need a rebuild + `bin/cs` commit and the "no build" claim breaks.)

**Interfaces:** none produced/consumed (documentation + completion only).

- [ ] **Step 1: Add the verbs to zsh completion**

In `completions/_cs`, in the `global_flags=( ... )` array (the block ending ~`:99`), add after the `-queue` line:

```zsh
        '-live:List sessions running right now on this machine'
        '-status:Set or show this session'\''s advertised status'
```

- [ ] **Step 2: Add the verbs to bash completion**

In `completions/cs.bash`, append `-live -status` to the `global_flags` string (currently `:14`):

```bash
    local global_flags="-list -ls -adopt -remove -rm -whoami -who -secrets -checkpoint -queue -search -lint -statusline -detect-theme -doctor -diag -update -uninstall -help -h -version -v -live -status"
```

- [ ] **Step 3: Verify completions still load (smoke test)**

Run: `bash -n completions/cs.bash && zsh -n completions/_cs`
Expected: no syntax errors from either shell's parse check. (`zsh` is present on macOS; if unavailable in the runner, `bash -n` on the bash file is the required check and the zsh edit is a one-line additive array entry.)

- [ ] **Step 4: Document both commands in the README Usage block**

In `README.md`, in the `## Usage` fenced block (near the `-list` line, ~`:85`), add:

```
cs -live                    # List sessions running right now on this machine
cs -status "<text>"         # Set this session's status (also: cs -status, cs -status --clear)
```

- [ ] **Step 5: Add a short subsection under Advanced**

In `README.md`, under `## Advanced` (alongside `### Task queue`), add:

```markdown
### Live sessions & status

See which cs sessions are running right now on this machine, and let each one
say what it's working on:

\`\`\`bash
cs -live                       # list live sessions: name, actor, uptime, status
cs -status "refactoring auth"  # set this session's status
cs -status                     # show this session's status (falls back to the README objective)
cs -status --clear             # clear it (revert to the objective)
\`\`\`

Liveness is a local fact — a session is "live" when its process is running on
this machine (the same `.cs/session.lock` signal the TUI uses). There is no
network or cross-machine presence. A session that never sets a status shows its
README objective instead.
```

(Replace the `\`\`\`` fences above with real triple-backticks when writing the file.)

- [ ] **Step 6: Commit**

```bash
git add completions/_cs completions/cs.bash README.md
git commit -m "docs(cs): document and complete cs -live / cs -status"
```

---

## Self-Review (author checklist — completed)

**Spec coverage:**
- `cs -live` (list, actor, uptime, status, current marker, empty message) → Task 2. ✓
- `cs -status` set/get/clear, multi-word, empty-error, session guard → Task 1. ✓
- Presence file single-line under `.cs/local/`, atomic write → Task 1. ✓
- Liveness via `.cs/session.lock` + `kill -0` → Task 2 (`session_is_live`). ✓
- Uptime from lock mtime → Task 2 (`session_uptime_secs`), tested via a back-dated lock. ✓
- Per-session actor bypassing `$CS_ACTOR` → Task 2 (`session_actor_slug`), tested. ✓
- README objective fallback with placeholder filter → Task 1 (`_session_objective`), tested in both suites. ✓
- Atomic write leaves no temp / clear reverts to objective / empty root / symlinked current marker → tested (Fable-mandated additions). ✓
- No hooks changed; no seed/clear → confirmed (no hook files in any task). ✓
- Completions + README → Task 3; `cs -help` → Tasks 1 & 2. ✓
- `build.sh` re-run + `bin/cs` committed on every lib-touching task → Tasks 1 & 2. ✓

**Fable 5 plan-validation fixes folded in (verdict was EXECUTE-WITH-FIXES):**
- CRITICAL: removed the `sdir="$(make_live_session …)"` capture that would hang ~300s (the backgrounded `sleep` inherits the command-substitution pipe) — fixtures are now called directly with deterministic paths.
- Teardown reaps sleepers from the on-disk lock files (subshell-safe) instead of a lost `LIVE_PIDS` array.
- Added the four spec tests that had been dropped (uptime, no-temp, clear-reverts, empty-root) plus a symlinked-current-marker test.
- Added `-status`/`-live` to `cs -help` (repo convention: help enumerates all verbs) inside the lib-touching tasks, keeping Task 3 build-free.
- Confirmed clean and left as-is: `GREEN` exists, no function-name collisions, dispatch wiring, bash 3.2/BSD constructs.

**Placeholder scan:** none — every code and test step contains complete code.

**Type/name consistency:** `session_status`, `_read_presence`, `_presence_file`, `session_is_live`, `session_uptime_secs`, `session_actor_slug`, `cmd_live`, `run_status`, `_humanize_secs`, `_epoch_mtime` are used with identical signatures where consumed across tasks (Task 2 consumes Task 1's `session_status <session_dir>`). ✓

**Known follow-ups (out of scope, not defects):**
- `cmd_live` uses fixed column widths, not the dynamic-width alignment `list_sessions` computes — acceptable for a compact live view; revisit if names overflow.
- `--force` double-launch multi-writer / lock-removal race is an inherited PID-lock limitation, documented in the spec, not addressed here.
