# /voice Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `/voice` skill that distills the user's typed messages from Claude Code transcripts into a two-layer style profile and drafts messages/replies/PR text/docs in the user's own voice — with zero user-facing cs commands.

**Architecture:** A standalone bash extractor (`skills/voice/scripts/build-corpus.sh`) walks `~/.claude/projects/*/*.jsonl`, keeps only genuinely-typed user messages, redacts credential shapes, and writes `corpus.md` to `$SESSIONS_ROOT/.voice/`. The SKILL.md teaches Claude to run that script when no profile exists, distill `profile.md` (portable fingerprint + per-register dials), and draft from the profile. The installer grows a `CS_SKILL_FILES` manifest so skills can ship support files beyond SKILL.md; doctor's drift scan learns to check them.

**Tech Stack:** bash 3.2 + BSD userland, jq, existing cs test harness (tests/test_lib.sh).

**Spec:** docs/superpowers/specs/2026-07-17-voice-skill-design.md (read it for rationale; this plan is the how).

## Global Constraints

- bash 3.2 + BSD userland floor: no `mapfile`, no `local -A`, no `source <(...)`, no GNU-only flags; CI runs the whole suite under stock `/bin/bash` 3.2.
- `set -euo pipefail` discipline: never expand a possibly-empty array under `set -u`; no early-exiting consumer (grep -q, sed q, head) downstream of a pipe whose producer may write >64KB — write to a file, read the file.
- `bin/cs` is GENERATED from `lib/` by `./build.sh`: any `lib/*.sh` change requires `./build.sh` BEFORE running tests, and `bin/cs` is committed in the SAME commit as the lib change.
- Test harness law: suites source `tests/test_lib.sh` after setting `SCRIPT_DIR`; `run_test` disables errexit inside test fns so EVERY assert needs `|| return 1`; `report_results` is the last line; run a suite with `/bin/bash tests/<suite>.sh`.
- Skill deploy contract: `CS_SKILLS` entries deploy `skills/<name>/SKILL.md`; the new `CS_SKILL_FILES` entries (format `<skill>/<relative-path>`) deploy verbatim under `~/.claude/skills/`. Both arrays are duplicated in `lib/00-header.sh` and `install.sh` with KEEP-IN-SYNC comments and covered by `test_manifest_arrays_in_sync`.
- Extractor env contract: transcripts root `${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}`, output dir `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice` (created `chmod 700`). The test harness `setup()` already exports both overrides.
- Corpus numbers (from spec): short-ack threshold 20 chars, paste guard 2000 chars, cap 4000 messages, appendix top 50.
- Never push to origin. No emojis anywhere.

---

## File Structure

- `skills/voice/scripts/build-corpus.sh` — extractor (new, executable)
- `skills/voice/SKILL.md` — the skill (new)
- `tests/test_voice_corpus.sh` — extractor suite (new)
- `tests/test_voice_skill.sh` — skill-text + registration pins (new)
- `lib/00-header.sh` — add `voice` to CS_SKILLS, add CS_SKILL_FILES
- `install.sh` — mirror both arrays, deploy support files (local + curl + wget modes)
- `lib/60-doctor.sh` — drift scan covers `skills/*/scripts/*.sh`
- `tests/test_install.sh` — sync loop gains CS_SKILL_FILES + repo-reality check
- `tests/test_doctor.sh` — skill-script drift test
- `README.md` — feature bullet + skills list

### Task 1: Corpus extractor script + suite

**Files:**
- Create: `skills/voice/scripts/build-corpus.sh` (mode 755)
- Test: `tests/test_voice_corpus.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `skills/voice/scripts/build-corpus.sh` honoring `CS_TRANSCRIPTS_DIR`/`CS_SESSIONS_ROOT`, exit 0 with `corpus.md` written on success, exit 1 with a stderr message containing "nothing to learn from" when there is no input. Task 2's SKILL.md names this path; Task 3's manifest lists it.

- [ ] **Step 1: Write the failing suite**

Create `tests/test_voice_corpus.sh` exactly:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the /voice corpus extractor (skills/voice/scripts/build-corpus.sh)
# ABOUTME: Covers typed-message filtering, redaction, dedupe, caps, and error paths

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

VOICE_SCRIPT="$SCRIPT_DIR/../skills/voice/scripts/build-corpus.sh"

# Corpus lands here; setup() exports CS_SESSIONS_ROOT and CS_TRANSCRIPTS_DIR.
corpus_path() { echo "$CS_SESSIONS_ROOT/.voice/corpus.md"; }

# Append one typed-user entry to transcript file $1: text $2, ts $3, extra JSON $4
add_msg() {
    local file="$1" text="$2" ts="${3:-2026-07-01T10:00:00Z}" extra="${4:-}"
    [ -n "$extra" ] || extra='{}'
    mkdir -p "$(dirname "$file")"
    jq -nc --arg t "$text" --arg ts "$ts" --argjson x "$extra" \
        '{type: "user", timestamp: $ts, message: {content: $t}} + $x' >> "$file"
}

proj_file() { echo "$CS_TRANSCRIPTS_DIR/$1/session-1.jsonl"; }

run_build() { "$VOICE_SCRIPT" 2>&1; }

test_typed_string_message_lands_in_corpus() {
    add_msg "$(proj_file projA)" "here is a genuinely typed message about the build system"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "genuinely typed message about the build" \
        "typed string message should be kept" || return 1
    assert_file_contains "$(corpus_path)" "[projA, 2026-07-01]" \
        "block carries project and date attribution" || return 1
}

test_array_text_parts_join() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:00:00Z","message":{"content":[{"type":"text","text":"first fragment of the thought"},{"type":"tool_result","content":"IGNORED_TOOL_PAYLOAD"},{"type":"text","text":"second fragment of the thought"}]}}' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "first fragment of the thought second fragment of the thought" \
        "array text parts should join with a space" || return 1
    if grep -qF "IGNORED_TOOL_PAYLOAD" "$(corpus_path)"; then
        echo "  FAIL: tool_result payload leaked into corpus"; return 1
    fi
}

test_tool_result_only_entry_dropped() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    printf '%s\n' '{"type":"user","timestamp":"2026-07-01T10:00:00Z","message":{"content":[{"type":"tool_result","content":"TOOL_ONLY_PAYLOAD"}]}}' >> "$f"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "1 non-typed" \
        "stats should count the tool_result-only entry as non-typed" || return 1
}

test_meta_and_sidechain_dropped() {
    add_msg "$(proj_file projA)" "meta message that must never appear anywhere" "2026-07-01T10:00:00Z" '{"isMeta": true}'
    add_msg "$(proj_file projA)" "sidechain message that must never appear anywhere" "2026-07-01T10:00:01Z" '{"isSidechain": true}'
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "must never appear anywhere" "$(corpus_path)"; then
        echo "  FAIL: isMeta/isSidechain entry leaked into corpus"; return 1
    fi
}

test_subagent_transcripts_skipped() {
    add_msg "$CS_TRANSCRIPTS_DIR/projA/sess-uuid/subagents/agent-abc.jsonl" \
        "subagent dispatch prompt that is not the user talking"
    add_msg "$CS_TRANSCRIPTS_DIR/projA/agent-topx.jsonl" \
        "agent-named transcript that is not the user talking"
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "not the user talking" "$(corpus_path)"; then
        echo "  FAIL: subagent transcript leaked into corpus"; return 1
    fi
}

test_harness_sentinels_dropped() {
    local f; f="$(proj_file projA)"
    add_msg "$f" "Caveat: the messages below were generated while running local commands"
    add_msg "$f" "This session is being continued from a previous conversation that ran out"
    add_msg "$f" "<command-name>/compact</command-name> padding padding padding"
    add_msg "$f" "<local-command-stdout>Compacted</local-command-stdout> padding pad"
    add_msg "$f" "<system-reminder>background reminder text goes here</system-reminder>"
    add_msg "$f" "Stop hook feedback: the hook says to do more work right now"
    add_msg "$f" "[Request interrupted by user] and some trailing content here"
    add_msg "$f" "TASKMASTER (1/20): Completion signal not found anywhere at all"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "8 harness-injected" \
        "stats should count all eight sentinel classes" || return 1
    if grep -q "Completion signal not found" "$(corpus_path)"; then
        echo "  FAIL: sentinel message leaked into corpus"; return 1
    fi
}

test_short_acks_go_to_appendix() {
    local f; f="$(proj_file projA)"
    add_msg "$f" "approved" "2026-07-01T10:00:00Z"
    add_msg "$f" "approved" "2026-07-01T11:00:00Z"
    add_msg "$f" "go" "2026-07-01T12:00:00Z"
    add_msg "$f" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "  2  approved" \
        "appendix should count the repeated short ack" || return 1
    assert_file_contains "$(corpus_path)" "  1  go" \
        "appendix should list the single short ack" || return 1
    if grep -q "^\[projA, .*\]$" "$(corpus_path)" && grep -B1 "^approved$" "$(corpus_path)" | grep -q "^\[projA"; then
        echo "  FAIL: short ack appeared as a corpus body block"; return 1
    fi
}

test_paste_over_2000_chars_dropped() {
    local blob
    blob="$(printf '%02100d' 0 | tr '0' 'x')"
    add_msg "$(proj_file projA)" "$blob"
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    if grep -q "xxxxxxxxxx" "$(corpus_path)"; then
        echo "  FAIL: >2000-char paste leaked into corpus"; return 1
    fi
    assert_file_contains "$(corpus_path)" "1 pastes over 2000 chars" \
        "stats should count the dropped paste" || return 1
}

test_credential_lines_redacted() {
    local msg
    msg="$(printf 'line one is ordinary prose talking about deploys\napi_key: supersecretvalue123456\nline three continues the ordinary thought')"
    add_msg "$(proj_file projA)" "$msg"
    add_msg "$(proj_file projA)" "the token parser handles this case fine in ordinary prose"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    assert_file_contains "$(corpus_path)" "[redacted line]" \
        "credential-shaped line should be replaced" || return 1
    assert_file_contains "$(corpus_path)" "line one is ordinary prose" \
        "surrounding prose should survive redaction" || return 1
    assert_file_contains "$(corpus_path)" "the token parser handles this case fine" \
        "the word token without a value should not trigger redaction" || return 1
    if grep -q "supersecretvalue123456" "$(corpus_path)"; then
        echo "  FAIL: secret value leaked into corpus"; return 1
    fi
}

test_duplicates_collapse_to_newest() {
    add_msg "$(proj_file projA)" "the duplicated message body typed twice over time" "2026-01-05T10:00:00Z"
    add_msg "$(proj_file projB)" "the duplicated message body typed twice over time" "2026-06-05T10:00:00Z"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local n
    n=$(grep -c "the duplicated message body typed twice" "$(corpus_path)")
    assert_eq "1" "$n" "duplicate should collapse to one occurrence" || return 1
    assert_file_contains "$(corpus_path)" "[projB, 2026-06-05]" \
        "collapsed duplicate should keep the newest attribution" || return 1
}

test_newest_first_ordering() {
    add_msg "$(proj_file projA)" "january era message that should come second" "2026-01-10T10:00:00Z"
    add_msg "$(proj_file projA)" "june era message that should come first here" "2026-06-10T10:00:00Z"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local first second
    first=$(grep -n "june era message" "$(corpus_path)" | cut -d: -f1)
    second=$(grep -n "january era message" "$(corpus_path)" | cut -d: -f1)
    if [ "$first" -ge "$second" ]; then
        echo "  FAIL: newest message should appear before older ones ($first vs $second)"
        return 1
    fi
}

test_cap_enforced_at_4000() {
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    awk 'BEGIN {
        for (i = 1; i <= 4010; i++)
            printf("{\"type\":\"user\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"message\":{\"content\":\"unique corpus filler message number %d for cap testing\"}}\n", i)
    }' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local n
    n=$(grep -c "^\[projA, " "$(corpus_path)")
    assert_eq "4000" "$n" "body should hold exactly the cap" || return 1
    assert_file_contains "$(corpus_path)" "capped at 4000" \
        "stats header should note the cap was hit" || return 1
}

test_empty_transcripts_root_errors() {
    local output ec=0
    output=$(run_build) || ec=$?
    if [ "$ec" -eq 0 ]; then
        echo "  FAIL: expected non-zero exit with no transcripts"; return 1
    fi
    assert_output_contains "$output" "nothing to learn from" \
        "error should say there is nothing to learn from" || return 1
}

test_large_transcript_builds_cleanly() {
    # SIGPIPE probe: total payload well over the 64KB pipe buffer.
    local f; f="$(proj_file projA)"; mkdir -p "$(dirname "$f")"
    awk 'BEGIN {
        pad = "steady prose about the work keeps flowing along nicely here"
        big = pad
        while (length(big) < 300) big = big " " pad
        for (i = 1; i <= 300; i++)
            printf("{\"type\":\"user\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"message\":{\"content\":\"message %d says %s\"}}\n", i, big)
    }' >> "$f"
    run_build > /dev/null || { echo "  FAIL: build died on a >64KB transcript"; return 1; }
    assert_file_contains "$(corpus_path)" "message 7 says steady prose" \
        "large-transcript content should land in the corpus" || return 1
}

test_voice_dir_permissions() {
    add_msg "$(proj_file projA)" "one real message so the build has something to keep"
    run_build > /dev/null || { echo "  FAIL: build exited non-zero"; return 1; }
    local mode
    mode=$(_file_mode "$CS_SESSIONS_ROOT/.voice")
    assert_eq "700" "$mode" ".voice directory should be private" || return 1
}

run_test test_typed_string_message_lands_in_corpus
run_test test_array_text_parts_join
run_test test_tool_result_only_entry_dropped
run_test test_meta_and_sidechain_dropped
run_test test_subagent_transcripts_skipped
run_test test_harness_sentinels_dropped
run_test test_short_acks_go_to_appendix
run_test test_paste_over_2000_chars_dropped
run_test test_credential_lines_redacted
run_test test_duplicates_collapse_to_newest
run_test test_newest_first_ordering
run_test test_cap_enforced_at_4000
run_test test_empty_transcripts_root_errors
run_test test_large_transcript_builds_cleanly
run_test test_voice_dir_permissions

report_results
```

Note there is deliberately NO missing-jq test: simulating an absent jq requires a hand-built PATH sandbox with symlinks for every other tool the script uses, which is fragile across machines. The guard is a single `command -v` line; the reviewer eyeballs it.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `/bin/bash tests/test_voice_corpus.sh`
Expected: every test FAILs (the script does not exist yet; run_build exits 127).

- [ ] **Step 3: Write the extractor**

Create `skills/voice/scripts/build-corpus.sh` exactly:

```bash
#!/usr/bin/env bash
# ABOUTME: Builds the /voice skill's writing corpus from Claude Code transcripts
# ABOUTME: Keeps the user's typed messages, drops harness noise, redacts credential shapes
set -euo pipefail

TRANSCRIPTS_ROOT="${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
VOICE_DIR="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice"
MAX_MESSAGES=4000
SHORT_CHARS=20
PASTE_CHARS=2000

command -v jq >/dev/null 2>&1 || {
    echo "voice: jq is required (brew install jq / apt-get install jq)" >&2
    exit 1
}
if [ ! -d "$TRANSCRIPTS_ROOT" ]; then
    echo "voice: no transcript directory at $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Transcripts sit one level deep (<project>/<session>.jsonl). Subagent
# transcripts sit deeper (<project>/<session>/subagents/agent-*.jsonl) and
# their "user" messages are dispatch prompts, not the user's typing; the
# depth bound excludes them, the name filter is belt and braces.
find "$TRANSCRIPTS_ROOT" -mindepth 2 -maxdepth 2 -name '*.jsonl' ! -name 'agent-*.jsonl' > "$workdir/files"

files_scanned=0
files_failed=0
: > "$workdir/all.jsonl"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    files_scanned=$((files_scanned + 1))
    proj="$(basename "$(dirname "$f")")"
    if ! jq -c --arg proj "$proj" --argjson paste "$PASTE_CHARS" '
        select(.type == "user")
        | select((.isMeta // false) | not)
        | select((.isSidechain // false) | not)
        | (.message.content // "") as $c
        | (if ($c | type) == "string" then $c
           elif ($c | type) == "array"
           then ($c | map(select(type == "object" and .type == "text") | .text) | join(" "))
           else "" end) as $raw
        | ($raw | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $t
        | (if ($t | length) == 0 then "not-typed"
           elif ($t | startswith("Caveat:")) then "sentinel"
           elif ($t | startswith("This session is being continued")) then "sentinel"
           elif ($t | test("<command-name>|<local-command-stdout>|<system-reminder>|Stop hook feedback:|\\[Request interrupted|TASKMASTER")) then "sentinel"
           elif ($t | length) > $paste then "paste"
           else null end) as $drop
        | {ts: (.timestamp // ""), proj: $proj, drop: $drop,
           text: (if $drop != null then ""
                  else ($t | split("\n")
                        | map(if test("(api[_-]?key|token|secret|password|bearer)[[:space:]]*[=:][[:space:]]*[^[:space:]]+"; "i")
                                 or test("sk-[A-Za-z0-9]{16,}")
                                 or test("[A-Za-z0-9+/=]{40,}")
                              then "[redacted line]" else . end)
                        | join("\n"))
                  end)}
    ' "$f" >> "$workdir/all.jsonl" 2>/dev/null; then
        files_failed=$((files_failed + 1))
    fi
done < "$workdir/files"

kept=$(jq -s '[.[] | select(.drop == null)] | length' "$workdir/all.jsonl")
if [ "$kept" -eq 0 ]; then
    echo "voice: no typed messages found under $TRANSCRIPTS_ROOT — nothing to learn from" >&2
    exit 1
fi

jq -r -s \
    --arg built "$(date '+%Y-%m-%d %H:%M')" \
    --argjson scanned "$files_scanned" \
    --argjson failed "$files_failed" \
    --argjson max "$MAX_MESSAGES" \
    --argjson short "$SHORT_CHARS" '
    map(select(.drop == null)) as $typed
    | (map(select(.drop == "sentinel")) | length) as $n_sentinel
    | (map(select(.drop == "paste")) | length) as $n_paste
    | (map(select(.drop == "not-typed")) | length) as $n_nottyped
    | ($typed | map(select((.text | length) < $short))) as $acks
    | ($typed | map(select((.text | length) >= $short))) as $long
    | ($long | group_by(.text) | map(max_by(.ts)) | sort_by(.ts) | reverse) as $uniq
    | ($uniq[0:$max]) as $body
    | ($acks | group_by(.text) | map({text: .[0].text, n: length})
       | sort_by(-.n) | .[0:50]) as $appendix
    | ([
        "# Voice corpus",
        "",
        "Built: \($built)",
        "Files scanned: \($scanned) (\($failed) unreadable)",
        ("Messages kept: \($body | length) (from \($long | length) typed, "
         + "\(($long | length) - ($uniq | length)) duplicates collapsed)"
         + (if ($uniq | length) > $max then ", capped at \($max)" else "" end)),
        "Short acks in appendix: \($acks | length) occurrences, \($appendix | length) distinct",
        "Dropped: \($n_sentinel) harness-injected, \($n_paste) pastes over 2000 chars, \($n_nottyped) non-typed",
        "",
        "---"
      ]
      + ($body | map("[\(.proj), \(.ts[0:10])]\n\(.text)\n---"))
      + ["", "## Short-ack frequency (top \($appendix | length))", ""]
      + ($appendix | map("  \(.n)  \(.text)"))
      ) | join("\n")
' "$workdir/all.jsonl" > "$workdir/corpus.md"

mkdir -p "$VOICE_DIR"
chmod 700 "$VOICE_DIR"
mv "$workdir/corpus.md" "$VOICE_DIR/corpus.md"
echo "voice: corpus built at $VOICE_DIR/corpus.md ($kept typed messages considered)"
```

Then: `chmod +x skills/voice/scripts/build-corpus.sh`

Design notes the implementer should not "fix": drops are tagged (not filtered) in pass 1 so pass 2 can report counts by reason; dropped entries carry `text: ""` so the temp file never holds pasted payloads; hex secrets are covered by the base64 character-class alternation; the final `mv` keeps interrupted runs from leaving a truncated corpus.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `/bin/bash tests/test_voice_corpus.sh`
Expected: `Results: 15/15 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add skills/voice/scripts/build-corpus.sh tests/test_voice_corpus.sh
git commit -m "feat: /voice corpus extractor — typed-message mining with redaction"
```

---

### Task 2: SKILL.md + skill-text suite

**Files:**
- Create: `skills/voice/SKILL.md`
- Test: `tests/test_voice_skill.sh`

**Interfaces:**
- Consumes: `skills/voice/scripts/build-corpus.sh` from Task 1 (deployed path `~/.claude/skills/voice/scripts/build-corpus.sh`; exit 1 + "nothing to learn from" on empty input).
- Produces: `skills/voice/SKILL.md` whose pinned phrases Task 2's suite asserts. Registration in manifests happens in Task 3 — this task's suite pins only the SKILL.md text (manifest pins land in Task 3's suite edits).

- [ ] **Step 1: Write the failing suite**

Create `tests/test_voice_skill.sh` exactly:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests that the voice skill ships and teaches the profile-driven drafting rules
# ABOUTME: Contract pins for skills/voice/SKILL.md

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

SKILL="$SCRIPT_DIR/../skills/voice/SKILL.md"

test_voice_skill_exists_with_frontmatter() {
    [ -f "$SKILL" ] || { echo "  FAIL: skills/voice/SKILL.md missing"; return 1; }
    assert_eq "---" "$(head -1 "$SKILL")" "SKILL.md opens with YAML frontmatter" || return 1
    assert_file_contains "$SKILL" "name: voice" "frontmatter names the skill" || return 1
    assert_file_contains "$SKILL" "description:" "frontmatter has a description" || return 1
}

test_voice_skill_teaches_the_drafting_rules() {
    assert_file_contains "$SKILL" "scripts/build-corpus.sh" "names the builder script" || return 1
    assert_file_contains "$SKILL" "single source of style truth" "profile governs the voice" || return 1
    assert_file_contains "$SKILL" "Never fabricate" "no invented quotes or commitments" || return 1
    assert_file_contains "$SKILL" "spelled correctly" "typos are described, not reproduced" || return 1
    assert_file_contains "$SKILL" "[redacted line]" "redacted content stays redacted" || return 1
    assert_file_contains "$SKILL" "older than 30 days" "staleness policy stated" || return 1
    assert_file_contains "$SKILL" "never send" "drafts are delivered, not sent" || return 1
    assert_file_contains "$SKILL" "nothing to learn from" "empty-corpus outcome handled" || return 1
}

test_voice_skill_defines_the_profile_shape() {
    assert_file_contains "$SKILL" "## Fingerprint" "portable layer present" || return 1
    assert_file_contains "$SKILL" "## Registers" "register layer present" || return 1
    assert_file_contains "$SKILL" "Chat & comms" "chat register named" || return 1
    assert_file_contains "$SKILL" "Dev artifacts" "dev register named" || return 1
    assert_file_contains "$SKILL" "Long-form" "long-form register named" || return 1
    assert_file_contains "$SKILL" "## Phrase bank" "phrase bank present" || return 1
    assert_file_contains "$SKILL" "## Provenance" "provenance stamp present" || return 1
}

run_test test_voice_skill_exists_with_frontmatter
run_test test_voice_skill_teaches_the_drafting_rules
run_test test_voice_skill_defines_the_profile_shape

report_results
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/bin/bash tests/test_voice_skill.sh`
Expected: FAIL — skills/voice/SKILL.md missing.

- [ ] **Step 3: Write the skill**

Create `skills/voice/SKILL.md` exactly:

```markdown
---
name: voice
description: Draft messages, replies, PR/issue/commit text, or longer prose in the user's own writing voice, learned from their Claude Code transcripts. Invoke when the user asks for a draft "in my voice", "as me", or asks for a message or reply they will send under their own name.
---

Write AS the user, not as an assistant writing about them. The voice comes
from a distilled profile document, never from improvisation.

## Files

- Profile: `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice/profile.md`
- Corpus: `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice/corpus.md`
- Builder: `~/.claude/skills/voice/scripts/build-corpus.sh`

## Flow

1. Read the profile. If it exists, go to step 4.
2. No profile: run the builder script, then distill the corpus into a
   profile (next section), then continue.
3. If the builder exits with "nothing to learn from", tell the user exactly
   that — there are no transcripts to distill on this machine — and stop.
4. Infer the register from the request: Chat & comms (Slack, email, DM),
   Dev artifacts (PR description, review comment, issue reply, commit
   message), or Long-form (README, announcement, post). If genuinely
   ambiguous, ask one question.
5. Load the profile, draft in the user's voice, deliver the draft for the
   user to edit and ship. Iterate on feedback. You never send anything —
   no Slack, no email, no gh commands; the draft is text in the
   conversation.
6. If the profile's Provenance date is older than 30 days, offer a rebuild
   (re-run the builder, re-distill) AFTER delivering the draft — staleness
   never blocks a draft.

## Distilling the profile

Read the corpus (with offset/limit chunks when it exceeds ~200 KB) and
write the profile with exactly these sections:

- `# Voice profile`
- `## Fingerprint` — portable traits that survive any register: directness,
  sentence rhythm and length, vocabulary, how disagreement is voiced, how
  questions are asked, greeting/sign-off habits (or their absence).
- `## Registers` — three subsections: `### Chat & comms`, `### Dev
  artifacts`, `### Long-form`. Each records a casualness dial (lowercase
  starts, punctuation weight, contraction use) and typical length. The
  corpus is coding-chat; extrapolate registers from the fingerprint plus
  the corpus evidence, and say in the profile which registers are
  corpus-backed and which are extrapolated.
- `## Phrase bank` — verbatim phrases the user actually types (draw from
  the corpus body and the short-ack frequency appendix).
- `## Languages` — languages observed and where they are used.
- `## Anti-patterns` — what the user never writes (e.g. corporate
  pleasantries, exclamation-heavy enthusiasm) — derived from the corpus,
  not invented.
- `## Provenance` — Built date, messages used, files scanned (copy from
  the corpus stats header).

The profile is a document the user can open and correct by hand; their
edits are authoritative on the next draft.

## Rules

- The profile is the single source of style truth. Do not apply traits the
  profile does not record.
- Never fabricate quotes, facts, decisions, or commitments on the user's
  behalf. A draft may carry placeholders like [date] for facts you lack.
- Typos in the corpus are a described trait; drafts are spelled correctly.
- Never reproduce `[redacted line]` markers or anything credential-shaped
  from the corpus into a draft.
- Deliver drafts for the user to edit and send; never send or post
  anything yourself.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `/bin/bash tests/test_voice_skill.sh`
Expected: `Results: 3/3 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add skills/voice/SKILL.md tests/test_voice_skill.sh
git commit -m "feat: /voice skill — profile-driven drafting in the user's voice"
```

---

### Task 3: Registration, deployment, doctor drift, README

**Files:**
- Modify: `lib/00-header.sh` (CS_SKILLS + new CS_SKILL_FILES)
- Modify: `install.sh` (both arrays + three deploy modes)
- Modify: `lib/60-doctor.sh` (drift scan support-script case)
- Modify: `tests/test_install.sh` (sync loop + repo-reality test)
- Modify: `tests/test_doctor.sh` (skill-script drift test)
- Modify: `README.md` (feature bullet + skills list)

**Interfaces:**
- Consumes: `voice/scripts/build-corpus.sh` (Task 1) and the `voice` skill directory (Task 2).
- Produces: `CS_SKILL_FILES` array (same literal in `lib/00-header.sh` and `install.sh`), entry format `<skill>/<relative-path>`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_install.sh`, change the sync loop line

```bash
    for arr in CS_HOOKS RETIRED_HOOKS CS_COMMANDS CS_SKILLS; do
```

to

```bash
    for arr in CS_HOOKS RETIRED_HOOKS CS_COMMANDS CS_SKILLS CS_SKILL_FILES; do
```

and add after the `test_skills_match_repo`-style CS_SKILLS/directory test (around line 195's test function, after its closing brace):

```bash
test_skill_files_exist_in_repo() {
    local entry
    for entry in $(extract_array "$SCRIPT_DIR/../install.sh" CS_SKILL_FILES); do
        if [ ! -f "$SCRIPT_DIR/../skills/$entry" ]; then
            echo "  FAIL: CS_SKILL_FILES entry missing from repo: skills/$entry"
            return 1
        fi
        if [ ! -x "$SCRIPT_DIR/../skills/$entry" ]; then
            echo "  FAIL: skill support script not executable: skills/$entry"
            return 1
        fi
    done
}
```

and register it next to the other run_test lines:

```bash
run_test test_skill_files_exist_in_repo
```

In `tests/test_doctor.sh`, add after `test_doctor_warns_on_command_drift`'s function body:

```bash
test_doctor_warns_on_skill_script_drift() {
    local checkout="$TEST_TMPDIR/checkout" deployed_skills="$TEST_TMPDIR/skills"
    make_fake_checkout "$checkout"
    mkdir -p "$checkout/skills/voice/scripts" "$deployed_skills/voice/scripts" \
        "$TEST_TMPDIR/deployed-hooks"
    echo 'source version' > "$checkout/skills/voice/scripts/build-corpus.sh"
    echo 'deployed version' > "$deployed_skills/voice/scripts/build-corpus.sh"

    local output
    output=$(cd "$checkout" && CS_HOOKS_DIR="$TEST_TMPDIR/deployed-hooks" \
        CS_SKILLS_DIR="$deployed_skills" "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$output" "voice/scripts/build-corpus.sh" \
        "doctor should name the drifted skill script" || return 1
    assert_output_contains "$output" "differs from source" \
        "drifted support script should warn" || return 1
}
```

and register it: `run_test test_doctor_warns_on_skill_script_drift`

- [ ] **Step 2: Run both suites to verify the new tests fail**

Run: `/bin/bash tests/test_install.sh && /bin/bash tests/test_doctor.sh`
Expected: `test_manifest_arrays_in_sync` FAILs (CS_SKILL_FILES not found), `test_skill_files_exist_in_repo` passes vacuously or fails, `test_doctor_warns_on_skill_script_drift` FAILs (no warning emitted).

- [ ] **Step 3: Implement the manifests and deploy loops**

In `lib/00-header.sh`, immediately after the `CS_SKILLS=( ... )` block, change `merge` to be followed by `voice` inside CS_SKILLS:

```bash
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    merge
    voice
)
```

and add below the block:

```bash
# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
# KEEP THIS LIST IN SYNC WITH install.sh's CS_SKILL_FILES.
CS_SKILL_FILES=(
    voice/scripts/build-corpus.sh
)
```

In `install.sh`, mirror both edits on its CS_SKILLS block (same five entries, same new array with the comment pointing at bin/cs). Then extend the three deploy modes:

```bash
if [ "$INSTALL_METHOD" = "local" ]; then
    for skill in "${CS_SKILLS[@]}"; do
        cp "$SKILLS_SOURCE/$skill/SKILL.md" "$SKILLS_DIR/$skill/"
    done
    for skill_file in "${CS_SKILL_FILES[@]}"; do
        mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
        cp -p "$SKILLS_SOURCE/$skill_file" "$SKILLS_DIR/$skill_file"
    done
else
    if command -v curl >/dev/null 2>&1; then
        for skill in "${CS_SKILLS[@]}"; do
            curl -fsSL "$REPO_URL/skills/$skill/SKILL.md" -o "$SKILLS_DIR/$skill/SKILL.md" || error "Failed to download $skill skill"
        done
        for skill_file in "${CS_SKILL_FILES[@]}"; do
            mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
            curl -fsSL "$REPO_URL/skills/$skill_file" -o "$SKILLS_DIR/$skill_file" || error "Failed to download $skill_file"
            chmod +x "$SKILLS_DIR/$skill_file"
        done
    elif command -v wget >/dev/null 2>&1; then
        for skill in "${CS_SKILLS[@]}"; do
            wget -q "$REPO_URL/skills/$skill/SKILL.md" -O "$SKILLS_DIR/$skill/SKILL.md" || error "Failed to download $skill skill"
        done
        for skill_file in "${CS_SKILL_FILES[@]}"; do
            mkdir -p "$SKILLS_DIR/$(dirname "$skill_file")"
            wget -q "$REPO_URL/skills/$skill_file" -O "$SKILLS_DIR/$skill_file" || error "Failed to download $skill_file"
            chmod +x "$SKILLS_DIR/$skill_file"
        done
    fi
fi
```

(`cp -p` preserves the executable bit locally; downloads need the explicit `chmod +x`. CS_SKILL_FILES must never be emptied while the bash 3.2 floor stands — expanding an empty array under `set -u` errors there.)

In `lib/60-doctor.sh`, inside `_drift_scan`, extend the keying:

```bash
            if [[ "$src" == */SKILL.md ]]; then
                name=$(basename "$(dirname "$src")")
                deployed="$deploy_root/$name/SKILL.md"
            elif [[ "$src" == skills/*/scripts/* ]]; then
                name="${src#skills/}"
                deployed="$deploy_root/$name"
            else
```

and extend the call site:

```bash
    _drift_scan "Skill" "$skills_dir" skills/*/SKILL.md skills/*/scripts/*.sh
```

- [ ] **Step 4: Build and run the touched suites**

```bash
./build.sh
/bin/bash tests/test_install.sh
/bin/bash tests/test_doctor.sh
/bin/bash tests/test_voice_skill.sh
/bin/bash tests/test_voice_corpus.sh
```

Expected: all pass. (`build.sh` is mandatory here: lib/ changed, and test_install compares arrays against the BUILT bin/cs.)

- [ ] **Step 5: README**

In `README.md`, add to the feature bullets (near the conversation-rotation bullet around line 48):

```markdown
- **Voice drafting** - `/voice` drafts messages, replies, PR text, or docs in your own writing voice. On first use it distills your typed messages from Claude Code transcripts into an editable profile at `~/.claude-sessions/.voice/profile.md`; drafting loads the profile and writes as you.
```

and update the skills list line (around line 68):

```markdown
- Adds `/summary`, `/checkpoint`, `/sweep`, and `/wrap` commands, and the `store-secret`, `prose-hygiene`, `rotate`, `merge`, and `voice` skills to `~/.claude/`
```

- [ ] **Step 6: Full gate and commit**

```bash
/bin/bash tests/run_all.sh
git add lib/00-header.sh install.sh lib/60-doctor.sh bin/cs tests/test_install.sh tests/test_doctor.sh README.md
git commit -m "feat: register /voice skill; CS_SKILL_FILES support-file deployment and drift check"
```

Expected: all suites green (44 suites after the two new ones).

---

## Plan Self-Review (done at write time)

- Spec coverage: Decisions 1-7 map to Tasks 1-3; error handling → Task 1 tests 13 (empty) and stats counting; testing section → the two new suites + sync/doctor edits; out-of-scope list introduces no tasks. The spec's "installer grows generic support-file deployment" is Task 3; "chmod 700" is Task 1 test 15.
- Placeholders: none; every step carries complete code.
- Type consistency: script path `skills/voice/scripts/build-corpus.sh` is identical in Task 1 (create), Task 2 (SKILL.md reference + pin), Task 3 (manifest entry, doctor fixture); env vars CS_TRANSCRIPTS_DIR/CS_SESSIONS_ROOT match test_lib setup exports; "nothing to learn from" is pinned in Task 1's error test and Task 2's SKILL.md pin.
- Fixture-reaches-branch: each Task 1 test seeds input that exercises exactly the asserted branch, and every "leak" assert has a positive companion (a kept message) so an empty corpus cannot vacuously pass; the paste, sentinel, and non-typed counts assert exact stats-line literals derived from fixture arithmetic.
