# Multi-Person Co-Development — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface what teammates contributed — an on-resume digest of shared memory/narrative activity since you last looked, plus an on-demand `cs -who` contributor feed. Pure async attribution: everything is read from `git log`; no presence, no coordination.

**Architecture:** A per-actor watermark (`.cs/local/watermark`, gitignored) records the last commit SHA seen. On resume, `session-start.sh` diffs `git log <watermark>..HEAD -- .cs/memory` (memories and `narrative.*.md` both live under `.cs/memory`), groups by git author, injects a one-line digest into the existing `DYNAMIC` session-state context, then advances the watermark. `cs -who` summarizes `git log -- .cs/memory` by author (entry count + last date), labelled as recent *activity*, never presence.

**Tech Stack:** Bash 3.2, git, `awk`/`sed`, `tests/test_lib.sh`, the session-start hook.

## Global Constraints

- **bash 3.2 floor**; macOS BSD `sed`/`awk` (`\{1,\}` not `\+`); hooks run minimal-PATH.
- **No presence / no coordination** — read-only over local git state. Label output "recent activity" / "since your last session", never "online".
- **Watermark is per-actor local** — lives in `.cs/local/` (gitignored from Phase 1); never committed.
- **Graceful degradation:** missing watermark (first resume) → no digest, just set it. A watermark SHA absent from history (post-rebase) → skip the digest, reset to HEAD.
- **Naming/comments:** two `# ABOUTME:` lines per new file; evergreen comments.

---

## File Structure

- **Modify `hooks/session-start.sh`:** in the resume `DYNAMIC` block (after "Recent commits", hooks/session-start.sh:177), add the watermark digest; `mkdir -p "$META_DIR/local"` for safety.
- **Modify `bin/cs`:** add `cmd_who` + a `-who)` dispatch arm (beside `-whoami`); add `-who` to `show_help` and README.
- **Tests:** `tests/test_hooks.sh` (digest + watermark advance), `tests/test_actor_identity.sh` (`cs -who`).

---

## Task 1: On-resume digest + watermark

**Files:**
- Modify: `hooks/session-start.sh` (resume `DYNAMIC` block, ~line 177)
- Test: `tests/test_hooks.sh`

**Interfaces:**
- Produces: on resume in a git session, if `.cs/local/watermark` names a reachable commit different from HEAD, the injected context contains a line `Since your last session — shared memory/narrative activity: <Author> (<n>)...`; the watermark file is advanced to HEAD on every resume.

- [ ] **Step 1: Write the failing test** (add to `tests/test_hooks.sh`; the file's session-start tests set `CLAUDE_SESSION_*` and use a git repo — mirror `test_recovery_*`/the resume tests around line 271+)

```bash
test_resume_digest_reports_memory_activity() {
    # Build a session repo with a committed baseline, record a watermark there,
    # then add a memory commit so HEAD advances past the watermark.
    ( cd "$CLAUDE_SESSION_DIR" && git init -q && git config user.email a@b.c && git config user.name "Alice" \
        && mkdir -p .cs/memory .cs/local && echo seed > .cs/memory/seed.md \
        && git add -A && git commit -q -m baseline )
    git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD > "$CLAUDE_SESSION_META_DIR/local/watermark"
    ( cd "$CLAUDE_SESSION_DIR" && echo "fact" > .cs/memory/new-fact.md \
        && git add -A && git commit -q -m "add memory" --author="Bob <bob@x.io>" )

    local output
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_contains "$output" "Since your last session" "resume should inject the activity digest" || return 1
    assert_output_contains "$output" "Bob" "digest should name the contributing author" || return 1

    # Watermark advanced to HEAD
    local head wm
    head=$(git -C "$CLAUDE_SESSION_DIR" rev-parse HEAD)
    wm=$(cat "$CLAUDE_SESSION_META_DIR/local/watermark")
    assert_eq "$head" "$wm" "watermark should advance to HEAD after resume" || return 1
}

test_resume_digest_silent_without_watermark() {
    ( cd "$CLAUDE_SESSION_DIR" && git init -q && git config user.email a@b.c && git config user.name A \
        && mkdir -p .cs/memory .cs/local && echo seed > .cs/memory/seed.md && git add -A && git commit -q -m baseline )
    rm -f "$CLAUDE_SESSION_META_DIR/local/watermark"

    local output
    output=$(echo '{"session_id":"s","source":"resume","cwd":"'"$CLAUDE_SESSION_DIR"'","hook_event_name":"SessionStart"}' \
        | bash "$HOOKS_DIR/session-start.sh" 2>/dev/null)
    assert_output_not_contains "$output" "Since your last session" "no digest on first resume (no watermark)" || return 1
    # But the watermark is now seeded for next time
    assert_file_exists "$CLAUDE_SESSION_META_DIR/local/watermark" "watermark should be created on first resume" || return 1
}
```

Add to the runner block:
```bash
run_test test_resume_digest_reports_memory_activity
run_test test_resume_digest_silent_without_watermark
```

> Check the file's session-start test setup: if it pre-creates `.cs` or git, drop the duplicate init. The assertions (digest phrase, author name, watermark == HEAD) are what matter.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_hooks.sh`
Expected: FAIL — no digest line; watermark not advanced.

- [ ] **Step 3: Implement** in `hooks/session-start.sh`, inside the `if [ "$SOURCE" = "resume" ] && [ -d "$SESSION_DIR/.git" ]; then` block, after the "Recent commits" section (after hooks/session-start.sh:177, before the Objective block):

```bash
    # Per-actor digest: shared memory/narrative activity since this actor last looked.
    mkdir -p "$META_DIR/local" 2>/dev/null || true
    WATERMARK_FILE="$META_DIR/local/watermark"
    LAST_SEEN=""
    [ -f "$WATERMARK_FILE" ] && LAST_SEEN=$(cat "$WATERMARK_FILE" 2>/dev/null || true)
    HEAD_SHA=$(git -C "$SESSION_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
    if [ -n "$LAST_SEEN" ] && [ -n "$HEAD_SHA" ] && [ "$LAST_SEEN" != "$HEAD_SHA" ] \
        && git -C "$SESSION_DIR" rev-parse -q --verify "$LAST_SEEN" >/dev/null 2>&1; then
        DIGEST=$(git -C "$SESSION_DIR" log --no-merges --format='%an' "$LAST_SEEN..HEAD" -- .cs/memory 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(.*\)$/\2 (\1)/' \
            | paste -sd', ' - 2>/dev/null || true)
        if [ -n "$DIGEST" ]; then
            DYNAMIC="${DYNAMIC}Since your last session — shared memory/narrative activity: ${DIGEST}\n"
        fi
    fi
    # Advance the watermark to current HEAD (also seeds it on first resume).
    [ -n "$HEAD_SHA" ] && echo "$HEAD_SHA" > "$WATERMARK_FILE"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test_hooks.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/test_hooks.sh
git commit -m "feat: on-resume digest of teammates' memory/narrative activity"
```

---

## Task 2: `cs -who` contributor feed

**Files:**
- Modify: `bin/cs` — add `cmd_who` (near `cmd_whoami`), a `-who)` dispatch arm, help + README entry
- Test: `tests/test_actor_identity.sh`

**Interfaces:**
- Consumes: `CLAUDE_SESSION_DIR` if set, else the current directory (must contain `.cs`).
- Produces: `cs -who` prints `Contributors to shared memory/narrative (recent activity):` followed by one line per git author touching `.cs/memory`, with entry count and last date, most-active first. Errors if not in a cs session/git repo.

- [ ] **Step 1: Write the failing test** (add to `tests/test_actor_identity.sh`)

```bash
test_who_lists_contributors() {
    local project_dir="$TEST_TMPDIR/proj"
    mkdir -p "$project_dir"
    ( cd "$project_dir" && git init -q && git config user.email a@b.c && git config user.name Alice )
    ( cd "$project_dir" && "$CS_BIN" -adopt s1 >/dev/null 2>&1 )
    ( cd "$project_dir" && mkdir -p .cs/memory && echo m1 > .cs/memory/m1.md \
        && git add -A && git commit -q -m m1 --author="Bob <bob@x.io>" )

    local out
    out=$( cd "$project_dir" && "$CS_BIN" -who 2>&1 )
    assert_output_contains "$out" "Contributors" "who should print a contributors header" || return 1
    assert_output_contains "$out" "Bob" "who should list a contributing author" || return 1
}
```

Add `run_test test_who_lists_contributors` to the runner.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_actor_identity.sh`
Expected: FAIL — `-who` is an unknown command (treated as a session name).

- [ ] **Step 3: Implement** `cmd_who` near `cmd_whoami` in `bin/cs`:

```bash
# Summarize shared memory/narrative contributors from git history (recent
# activity, by author). Not presence — purely a read over git log.
cmd_who() {
    local dir="${CLAUDE_SESSION_DIR:-$PWD}"
    [ -d "$dir/.cs" ] || error "Not in a cs session (no .cs/ in $dir)"
    [ -d "$dir/.git" ] || error "Session is not a git repo; nothing to summarize"
    echo "Contributors to shared memory/narrative (recent activity):"
    git -C "$dir" log --format='%an|%ad' --date=short -- .cs/memory 2>/dev/null \
        | awk -F'|' '
            { count[$1]++; if ($2 > last[$1]) last[$1] = $2 }
            END {
                for (a in count) printf "%6d  %s  (last %s)\n", count[a], a, last[a]
            }' \
        | sort -rn
}
```

- [ ] **Step 4: Add the dispatch arm** beside `-whoami)`:

```bash
        -who)
            cmd_who
            return 0
            ;;
```

- [ ] **Step 5: Document** — add to `show_help` (after the `-whoami` line) and `README.md` (after the `-whoami` line):

help:
```
  -who                Show who contributed to shared memory/narrative (git history)
```
README:
```
cs -who                     # Show who contributed to shared memory/narrative (git history)
```

- [ ] **Step 6: Run to verify it passes**

Run: `bash tests/test_actor_identity.sh`
Expected: PASS.

- [ ] **Step 7: Run the touched suites**

```bash
for t in test_actor_identity test_hooks test_help test_adopt; do r=$(bash "tests/$t.sh" < /dev/null 2>&1 | grep "Results:" | tail -1); printf '%-22s %s\n' "$t" "$r"; done
```
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add bin/cs README.md tests/test_actor_identity.sh
git commit -m "feat: cs -who contributor feed from git history"
```

---

## Self-Review Checklist

- [ ] Digest only fires when watermark exists, is reachable, and differs from HEAD; silent otherwise.
- [ ] Watermark advances to HEAD on every resume (incl. first, where it just seeds).
- [ ] Watermark lives under `.cs/local/` (gitignored); never committed.
- [ ] Digest + `cs -who` say "recent activity" / "since your last session" — never "online"/"presence".
- [ ] `-who` errors cleanly outside a session/git repo.
- [ ] help + README list `-who`; `-whoami` still works.
- [ ] bash 3.2 / BSD: `awk` assoc arrays (awk, not bash), `sed` BRE, `git -C`.

## Done = the multi-person feature is complete

After Phase 3, the loop is closed: contributions are attributed (git), conflict-free (per-actor files + merge=ours), and *surfaced* (resume digest + `cs -who`) — with zero networked coordination. Remaining roadmap item (Phase 4, TUI activity panel) is optional polish.
