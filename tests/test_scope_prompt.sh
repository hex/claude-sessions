#!/usr/bin/env bash
# ABOUTME: Tests for the scope-prompt UserPromptSubmit hook
# ABOUTME: Validates classifier, grounded scan, exclusions, token cap, and defensive no-ops

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/scope-prompt.sh"

# Inline snapshot of the adversarial corpus. SPEC: .cs/scope-probe/corpus.md (owned by
# Adversary). Embedded here because tests/ is tracked but .cs/ is gitignored — reading the
# corpus at runtime would break on a fresh CI checkout. `classifier_fires` is the expected
# output of the v1 regex classifier (verb-union OR file-extension match), derived from each
# fixture's corpus `why` analysis; `expect` is the ground-truth label (kept for documentation).
FIXTURES=$(cat <<'CORPUS'
{"prompt": "implement a retry wrapper around the fetch call in src/api.ts so failed requests back off exponentially", "expect": "positive", "classifier_fires": true, "attack_category": "clear-code-task"}
{"prompt": "good morning! how's it going today?", "expect": "negative", "classifier_fires": false, "attack_category": "pure-chitchat"}
{"prompt": "honestly that was one of the most genuinely helpful sessions I have had in a really long while", "expect": "negative", "classifier_fires": false, "attack_category": "pure-chitchat"}
{"prompt": "what's the difference between a mutex and a semaphore?", "expect": "negative", "classifier_fires": false, "attack_category": "code-question-not-task"}
{"prompt": "should I add an index on this column, or is that premature optimization?", "expect": "borderline", "classifier_fires": true, "attack_category": "code-question-not-task"}
{"prompt": "the linker keeps choking on target/release/deps/libcs-9f3a17.d — fix the build script", "expect": "positive", "classifier_fires": true, "attack_category": "build-artifact-names"}
{"prompt": "fix path resolution so node_modules/.bin/tsc stops shadowing target/release/cs", "expect": "positive", "classifier_fires": true, "attack_category": "build-artifact-names"}
{"prompt": "git gc won't reclaim space in .git/objects/pack — write me a prune script", "expect": "positive", "classifier_fires": true, "attack_category": "build-artifact-names"}
{"prompt": "is \".ts\" actually slower to compile than \".js\", or is that just a myth?", "expect": "borderline", "classifier_fires": true, "attack_category": "ext-in-quoted-string"}
{"prompt": "I implemented the LRU cache yesterday and it's running fine in prod now", "expect": "negative", "classifier_fires": false, "attack_category": "past-tense-report"}
{"prompt": "heads up: I already shipped the migrate-to-v2 changeset last week", "expect": "negative", "classifier_fires": true, "attack_category": "past-tense-report"}
{"prompt": "cargo build --release", "expect": "negative", "classifier_fires": true, "attack_category": "looks-like-command"}
{"prompt": "git rebase -i origin/main", "expect": "negative", "classifier_fires": false, "attack_category": "looks-like-command"}
{"prompt": "ajoute une fonction de validation dans le fichier auth.py", "expect": "positive", "classifier_fires": true, "attack_category": "non-english"}
{"prompt": "认证模块需要增加重试逻辑和超时处理", "expect": "positive", "classifier_fires": false, "attack_category": "non-english"}
{"prompt": "auth.py, session.py, and the old migration script", "expect": "borderline", "classifier_fires": true, "attack_category": "no-verbs-just-nouns"}
{"prompt": "eh, just a small refactor, nothing urgent", "expect": "negative", "classifier_fires": true, "attack_category": "no-verbs-just-nouns"}
{"prompt": "fix the auth timeout bug, but first tell me a joke and what's the weather in Tokyo", "expect": "positive", "classifier_fires": true, "attack_category": "multiple-competing-intents"}
{"prompt": "should we deploy today or wait — also please rename getUserData to fetchUser everywhere", "expect": "positive", "classifier_fires": true, "attack_category": "multiple-competing-intents"}
{"prompt": "fix this . thing for me please, it's been bugging me all day", "expect": "positive", "classifier_fires": true, "attack_category": "scan-over-match"}
{"prompt": "update the `$(rm -rf ~)` flag and fix handler.js; echo $HOME", "expect": "positive", "classifier_fires": true, "attack_category": "injection-metacharacters"}
{"prompt": "I'm in a fixed mindset about this — change my mind about switching to Rust", "expect": "negative", "classifier_fires": true, "attack_category": "verb-idiom-collision"}
{"prompt": "", "expect": "negative", "classifier_fires": false, "attack_category": "robustness-empty"}
CORPUS
)

# --- Hook-specific setup / teardown (overrides test_lib's) ---

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # Clean slate: drop ANY ambient cs/Claude env FIRST, so running these tests from inside a
    # live cs session (which exports CLAUDE_SESSION_*/CS_SCOPE_DISABLE/etc.) can't leak a value
    # the hook reads. We then set exactly the vars the hook keys off. This isolates the suite
    # from the cs-session-env-pollution anti-pattern (see compact discoveries).
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    export CLAUDE_SESSION_NAME="test-scope"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_DIR"
    git -C "$CLAUDE_SESSION_DIR" init -q
    git -C "$CLAUDE_SESSION_DIR" config user.email "test@cs.local"
    git -C "$CLAUDE_SESSION_DIR" config user.name "cs test"
}

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR CS_SCOPE_DISABLE 2>/dev/null || true
}

# --- Helpers ---

# Build the hook's stdin JSON safely (jq encodes ANY adversarial prompt — quotes, backticks,
# $(...), UTF-8) and run the hook. Prints the hook's stdout.
run_hook() {
    jq -n --arg p "$1" '{prompt: $p, hook_event_name: "UserPromptSubmit"}' | bash "$HOOK"
}

# Extract additionalContext from the hook's output JSON (empty if absent/invalid).
additional_context() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}


# Create + track files (paths relative to the session repo) and commit them.
seed_repo() {
    local f
    for f in "$@"; do
        mkdir -p "$CLAUDE_SESSION_DIR/$(dirname "$f")"
        printf 'placeholder content for %s\n' "$f" > "$CLAUDE_SESSION_DIR/$f"
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "seed" >/dev/null 2>&1
}

# ============================================================================
# Classifier behaviour (data-driven over the inline corpus snapshot)
# ============================================================================

test_prompt_clears_attention_marker() {
    # Any prompt (even a slash command) means the user is back; the
    # statusline's finished-blink marker must drop immediately.
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    run_hook "/color red" >/dev/null 2>&1 || true
    assert_file_not_exists "$CLAUDE_SESSION_META_DIR/local/attention" \
        "a submitted prompt should clear the attention marker" || return 1
}

test_classifier_fires_emit_scope_block() {
    local line p cat out rc fails=0
    while IFS= read -r line; do
        p=$(printf '%s' "$line" | jq -r '.prompt')
        cat=$(printf '%s' "$line" | jq -r '.attack_category')
        out=$(run_hook "$p" 2>/dev/null) && rc=0 || rc=$?
        if [ "$rc" -ne 0 ]; then echo "  FAIL: hook exit $rc on firing prompt [$cat]: $p"; fails=1; continue; fi
        if ! printf '%s' "$out" | grep -q "Scope (auto-grounded)"; then
            echo "  FAIL: expected a scope block for firing prompt [$cat]: $p"; fails=1
        fi
    done < <(printf '%s\n' "$FIXTURES" | jq -c 'select(.classifier_fires == true)')
    return $fails
}

test_classifier_silent_passthrough() {
    local line p cat out rc fails=0
    while IFS= read -r line; do
        p=$(printf '%s' "$line" | jq -r '.prompt')
        cat=$(printf '%s' "$line" | jq -r '.attack_category')
        out=$(run_hook "$p" 2>/dev/null) && rc=0 || rc=$?
        # Anti-vacuous-pass: a MISSING hook also yields empty output, so REQUIRE exit 0.
        if [ "$rc" -ne 0 ]; then echo "  FAIL: hook must exit 0 (got $rc) on silent prompt [$cat]: $p"; fails=1; continue; fi
        if [ -n "$out" ]; then echo "  FAIL: expected silent pass-through, got output for [$cat]: $p"; fails=1; fi
    done < <(printf '%s\n' "$FIXTURES" | jq -c 'select(.classifier_fires == false)')
    return $fails
}

test_classifier_borderline_fires_as_documented() {
    # Ground-truth borderline prompts; the v1 regex classifier FIRES on all of them
    # (documented false-positives). Pin that so later classifier tuning is noticed.
    local line p cat out rc fails=0
    while IFS= read -r line; do
        p=$(printf '%s' "$line" | jq -r '.prompt')
        cat=$(printf '%s' "$line" | jq -r '.attack_category')
        out=$(run_hook "$p" 2>/dev/null) && rc=0 || rc=$?
        if [ "$rc" -ne 0 ]; then echo "  FAIL: hook exit $rc on borderline [$cat]: $p"; fails=1; continue; fi
        printf '%s' "$out" | grep -q "Scope (auto-grounded)" \
            || { echo "  FAIL: borderline should fire (documented FP) [$cat]: $p"; fails=1; }
    done < <(printf '%s\n' "$FIXTURES" | jq -c 'select(.expect == "borderline")')
    return $fails
}

# ============================================================================
# Grounded scan
# ============================================================================

test_scope_block_frames_matches_as_non_authoritative() {
    seed_repo "src/api.ts" "src/unrelated.ts"
    local out ac
    out=$(run_hook "implement a retry wrapper around the fetch call in src/api.ts")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "src/api.ts" \
        || { echo "  FAIL: precondition — block should fire with the file"; return 1; }
    printf '%s' "$ac" | grep -q "not a task boundary" \
        || { echo "  FAIL: scope block must frame the list as orientation, not a task boundary"; return 1; }
}

test_scan_surfaces_relevant_file() {
    seed_repo "src/api.ts" "src/unrelated.ts"
    local out ac
    out=$(run_hook "implement a retry wrapper around the fetch call in src/api.ts so failed requests back off exponentially")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "src/api.ts" || { echo "  FAIL: scan should surface src/api.ts"; return 1; }
}

test_scan_includes_recent_commits() {
    seed_repo "src/api.ts"
    printf '// tweak\n' >> "$CLAUDE_SESSION_DIR/src/api.ts"
    git -C "$CLAUDE_SESSION_DIR" commit -aq -m "DISTINCTIVE_COMMIT_MARKER tweak api" >/dev/null 2>&1
    local out ac
    out=$(run_hook "implement a retry wrapper around the fetch call in src/api.ts")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "DISTINCTIVE_COMMIT_MARKER" \
        || { echo "  FAIL: scope should include recent commits touching the file"; return 1; }
}

test_scan_excludes_build_and_meta_dirs() {
    # CRITICAL regression: build/vendor/meta dirs must never leak into the scope block —
    # even when the prompt explicitly NAMES them. The .cs/ exclusion is load-bearing:
    # without it /scope would inject the session's own metadata.
    seed_repo \
        "src/auth.ts" \
        "dist/auth.js" \
        "build/auth.o" \
        "node_modules/auth/index.js" \
        "target/release/deps/auth-1a2b.d" \
        "target/release/auth-cli" \
        "target/debug/auth.o" \
        "coverage/auth.html" \
        ".next/auth.js" \
        ".cs/auth-notes.md"
    local out ac bad
    out=$(run_hook "fix the auth handler, then clean up dist and the .cs auth notes")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "src/auth.ts" || { echo "  FAIL: should surface the real file src/auth.ts"; return 1; }
    # target/ must be excluded WHOLESALE, not just target/release/deps/ (finding-02).
    for bad in "dist/auth.js" "build/auth.o" "node_modules/auth/index.js" \
               "target/release/deps/auth-1a2b.d" "target/release/auth-cli" "target/debug/auth.o" \
               "coverage/auth.html" ".next/auth.js" ".cs/auth-notes.md"; do
        if printf '%s' "$ac" | grep -q "$bad"; then
            echo "  FAIL: excluded path leaked into scope block: $bad"; return 1
        fi
    done
}

test_scan_over_match_lone_dot_defused() {
    # SCAN BOMB (#20): the tokenizer can emit a lone '.' token that, as an rg fixed-string,
    # matches every path containing a period. The hook must drop it. Positive anchor first
    # (prompt fires on 'fix') so an empty RED output can't pass vacuously.
    seed_repo "src/api.ts" "lib/util.ts" "core/engine.ts"
    local out ac bad
    out=$(run_hook "fix this . thing for me please, it's been bugging me all day")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "Scope (auto-grounded)" \
        || { echo "  FAIL: prompt fires on 'fix'; expected a scope block (RED guard)"; return 1; }
    for bad in "src/api.ts" "lib/util.ts" "core/engine.ts"; do
        if printf '%s' "$ac" | grep -q "$bad"; then
            echo "  FAIL: lone-'.' scan bomb surfaced unrelated file: $bad"; return 1
        fi
    done
}

# Count the entries listed under the "### Relevant files" subsection.
relevant_files_count() {
    printf '%s' "$1" | awk '/^### Relevant files$/{f=1;next} /^### /{f=0} f && NF {c++} END{print c+0}'
}

test_scan_bounded_on_common_words() {
    # finding-03a: bare dictionary words (>=4 chars) used to substring-match many paths.
    # A firing prompt made only of filler words must NOT dump a pile of tangential files.
    local w i
    mkdir -p "$CLAUDE_SESSION_DIR/src"
    for w in this that from with; do
        for i in 1 2 3; do printf 'x\n' > "$CLAUDE_SESSION_DIR/src/${w}_mod${i}.ts"; done
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m seed >/dev/null 2>&1
    local out ac count
    out=$(run_hook "fix this with that from then than")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "Scope (auto-grounded)" || { echo "  FAIL: prompt fires on 'fix'; expected a block (RED guard)"; return 1; }
    count=$(relevant_files_count "$ac")
    [ "$count" -lt 10 ] || { echo "  FAIL: filler-only prompt over-matched $count files (stoplist not applied?)"; return 1; }
}

test_scan_handles_spaces_in_filenames() {
    # finding-03b: $RELEVANT_FILES must be passed to `git log` quoted, else a tracked path
    # with a space splits into bogus pathspecs and the recent-commits section silently empties.
    mkdir -p "$CLAUDE_SESSION_DIR/src"
    printf 'x\n' > "$CLAUDE_SESSION_DIR/src/weird name.ts"
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "SPACEFILE_COMMIT add weird name" >/dev/null 2>&1
    local out ac rc
    out=$(run_hook "fix the weird handler logic" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 with spaced filenames (got $rc)"; return 1; }
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -qF "src/weird name.ts" || { echo "  FAIL: spaced filename should surface in relevant files"; return 1; }
    printf '%s' "$ac" | grep -q "SPACEFILE_COMMIT" || { echo "  FAIL: recent commits must resolve for spaced filenames (unquoted \$RELEVANT_FILES?)"; return 1; }
}

test_scan_surfaces_short_dir_tokens() {
    # finding-05: short dir/identifier tokens (api, db) must NOT be dropped by the length floor.
    # Paths are named so they can ONLY be matched via the 'api'/'db' tokens — no other word in
    # the prompt is a substring of them — so this fails red if the floor over-drops.
    seed_repo "api/core.ts" "db/store.ts" "docs/guide.md"
    local out ac
    out=$(run_hook "refactor the api and the db")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "api/core.ts" || { echo "  FAIL: 'api' token should surface api/core.ts (length floor over-drops short tokens)"; return 1; }
    printf '%s' "$ac" | grep -q "db/store.ts" || { echo "  FAIL: 'db' token should surface db/store.ts (length floor over-drops short tokens)"; return 1; }
}

test_scan_no_substring_overmatch() {
    # finding-06: bare words must match path COMPONENTS, not substrings. A zero-intent prompt
    # firing on "fix" must not drag in files via incidental substrings (me -> README/runtime).
    seed_repo "README.md" "docs/readme.md" "lib/runtime.ts" "src/components/Menu.ts" \
              "src/components/theme.ts" "src/names.ts" "src/payment.ts" "src/today.ts"
    local out ac bad
    out=$(run_hook "fix this . thing for me please, it has been bugging me all day")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "Scope (auto-grounded)" || { echo "  FAIL: prompt fires on 'fix'; expected a block (RED guard)"; return 1; }
    for bad in README.md docs/readme.md lib/runtime.ts src/components/Menu.ts \
               src/components/theme.ts src/names.ts src/payment.ts src/today.ts; do
        if printf '%s' "$ac" | grep -qF "$bad"; then
            echo "  FAIL: substring over-match surfaced $bad (short word matched as a substring)"; return 1
        fi
    done
}

test_scan_component_matches_unexcluded_dir() {
    # team-lead edge: a bare token equal to a real dir component NOT under an excluded dir must
    # surface via the matcher — proving the exclusion isn't masking a matcher gap (a deps/ dir
    # outside target/ is legitimate ground).
    seed_repo "myapp/deps/loader.go" "src/other.ts"
    local out ac
    out=$(run_hook "fix the deps issue")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "myapp/deps/loader.go" || { echo "  FAIL: 'deps' should component-match myapp/deps/loader.go"; return 1; }
}

test_scan_camelcase_component_match() {
    # team-lead camelCase requirement: bare 'api' must surface apiHandler.ts via a camelCase split.
    seed_repo "src/apiHandler.ts" "src/tokenStore.ts"
    local out ac
    out=$(run_hook "refactor the api error handling")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "src/apiHandler.ts" || { echo "  FAIL: 'api' should match apiHandler.ts via camelCase split"; return 1; }
    printf '%s' "$ac" | grep -q "src/tokenStore.ts" && { echo "  FAIL: 'api' should NOT match tokenStore.ts"; return 1; }
    return 0
}

test_scan_trailing_punctuation_recall() {
    # finding-08: a sentence-final period must not turn a bare word into a dead path-like token.
    # "refactor the api." -> token "api." must still component-match api/, not substring-miss.
    seed_repo "api/handler.ts" "db/store.ts"
    local out ac
    out=$(run_hook "refactor the api. and the db.")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "api/handler.ts" || { echo "  FAIL: trailing '.' killed recall for 'api.'"; return 1; }
    printf '%s' "$ac" | grep -q "db/store.ts" || { echo "  FAIL: trailing '.' killed recall for 'db.'"; return 1; }
}

test_scan_acronym_component_match() {
    # finding-07: acronym prefixes must split (APIClient -> API + Client) so 'api'/'html' ground.
    seed_repo "src/APIClient.ts" "src/HTMLParser.ts" "src/plain.ts"
    local out ac
    out=$(run_hook "refactor the api and html layers")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "src/APIClient.ts" || { echo "  FAIL: 'api' should match APIClient.ts (acronym split)"; return 1; }
    printf '%s' "$ac" | grep -q "src/HTMLParser.ts" || { echo "  FAIL: 'html' should match HTMLParser.ts (acronym split)"; return 1; }
}

test_working_tree_truncation_cue() {
    # finding: `git diff --stat HEAD | tail -10` silently drops leading stat lines when the tree
    # has >10 changed paths, so a file absent from the list reads as unmodified. The Working tree
    # header must flag the truncation — and a small diff must NOT be falsely flagged.
    seed_repo "src/loader.ts"

    # Small dirty tree: one changed file -> no truncation, plain header.
    printf '// edit\n' >> "$CLAUDE_SESSION_DIR/src/loader.ts"
    local out ac
    out=$(run_hook "refactor the loader module")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "### Working tree" \
        || { echo "  FAIL: expected a Working tree section for a dirty tree"; return 1; }
    if printf '%s' "$ac" | grep -q "truncated"; then
        echo "  FAIL: a small (<=10 line) diff must not carry a truncation cue"; return 1
    fi

    # Large dirty tree: >10 changed files -> tail drops lines, header must say so.
    local i
    for i in $(seq 1 15); do printf 'x\n' > "$CLAUDE_SESSION_DIR/extra$i.txt"; done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    out=$(run_hook "refactor the loader module")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "### Working tree (truncated" \
        || { echo "  FAIL: truncated diff --stat must carry a truncation cue in the Working tree header"; return 1; }
}

# ============================================================================
# Token cap
# ============================================================================

test_token_cap_under_8000_bytes() {
    # Force a pre-truncation block well over 8000 bytes: 35 long paths sharing a real "loader"
    # component. The long segments are separate nested dirs so each stays under the 255-char
    # filename limit while the full path is long enough that 30 of them exceed 8000 bytes.
    local seg i
    seg=$(printf 'x%.0s' $(seq 1 200))
    mkdir -p "$CLAUDE_SESSION_DIR/src/loader/$seg/$seg"
    for i in $(seq 1 35); do
        printf 'x\n' > "$CLAUDE_SESSION_DIR/src/loader/$seg/$seg/f$i.ts"
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m seed >/dev/null 2>&1
    local out ac bytes
    out=$(run_hook "refactor the loader module")
    ac=$(additional_context "$out")
    bytes=$(printf '%s' "$ac" | wc -c | tr -d ' ')
    [ "$bytes" -gt 0 ] || { echo "  FAIL: expected a non-empty scope block"; return 1; }
    [ "$bytes" -le 8000 ] || { echo "  FAIL: additionalContext is $bytes bytes (> 8000 cap)"; return 1; }
}

test_token_cap_marks_truncation() {
    # finding: head -c 8000 can sever a path/commit mid-token with no marker, so a truncated tail
    # reads as a real (but nonexistent) path. When the block overflows the cap it must end with an
    # explicit truncation marker on its own final line. Same over-cap setup as the byte-cap test.
    local seg i
    seg=$(printf 'x%.0s' $(seq 1 200))
    mkdir -p "$CLAUDE_SESSION_DIR/src/loader/$seg/$seg"
    for i in $(seq 1 35); do
        printf 'x\n' > "$CLAUDE_SESSION_DIR/src/loader/$seg/$seg/f$i.ts"
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m seed >/dev/null 2>&1
    local out ac bytes
    out=$(run_hook "refactor the loader module")
    ac=$(additional_context "$out")
    bytes=$(printf '%s' "$ac" | wc -c | tr -d ' ')
    [ "$bytes" -le 8000 ] || { echo "  FAIL: capped block is $bytes bytes (> 8000)"; return 1; }
    printf '%s' "$ac" | grep -qF "[scope block truncated]" \
        || { echo "  FAIL: a truncated scope block must carry the truncation marker"; return 1; }
    # The marker must be the LAST line — nothing severed after it.
    [ "$(printf '%s' "$ac" | tail -1)" = "[scope block truncated]" ] \
        || { echo "  FAIL: truncation marker must be the final line of the block"; return 1; }
}

# ============================================================================
# Integration / defensive posture (every error path exits 0)
# ============================================================================

test_noop_outside_cs_session() {
    unset CLAUDE_SESSION_NAME
    local out rc
    out=$(run_hook "implement a retry wrapper in src/api.ts" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 outside a cs session (got $rc)"; return 1; }
    [ -z "$out" ] || { echo "  FAIL: hook must be silent outside a cs session"; return 1; }
}

test_opt_out_via_disable_env() {
    export CS_SCOPE_DISABLE=1
    seed_repo "src/api.ts"
    local out rc
    out=$(run_hook "implement a retry wrapper in src/api.ts" 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 when disabled (got $rc)"; return 1; }
    [ -z "$out" ] || { echo "  FAIL: CS_SCOPE_DISABLE=1 must suppress the scope block"; return 1; }
}

test_graceful_malformed_input() {
    local rc
    printf 'this is not json {{{\n' | bash "$HOOK" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 on malformed input (got $rc)"; return 1; }
}

test_empty_tree_tombstone_marker() {
    # The session repo is git-init'd in setup with ZERO tracked files. A firing prompt should
    # still emit a distinct tombstone block (not a silent skip).
    local out ac
    out=$(run_hook "implement a retry wrapper around the fetch call in src/api.ts")
    ac=$(additional_context "$out")
    printf '%s' "$ac" | grep -q "Scope (auto-grounded)" || { echo "  FAIL: tombstone block should still carry the header"; return 1; }
    printf '%s' "$ac" | grep -qF "Scope: no tracked files matched" || { echo "  FAIL: expected the pinned empty-tree tombstone marker"; return 1; }
}

test_injection_prompt_is_data_not_code() {
    # SECURITY (#21): the prompt carries `$(rm -rf ~)`. The hook MUST treat it as data and
    # never eval it. HOME is sandboxed for the hook invocation so a regression cannot touch
    # the real home; a surviving canary proves no command substitution executed.
    local sbhome="$TEST_TMPDIR/sandbox-home"
    mkdir -p "$sbhome"; printf 'keep\n' > "$sbhome/canary"
    seed_repo "src/handler.js"
    local out rc
    out=$(HOME="$sbhome" run_hook 'update the `$(rm -rf ~)` flag and fix handler.js; echo $HOME' 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 on the injection prompt (got $rc)"; return 1; }
    [ -f "$sbhome/canary" ] || { echo "  FAIL: embedded \$(rm -rf ~) executed — prompt was not treated as data"; return 1; }
}

test_firing_prompt_exits_zero() {
    seed_repo "src/api.ts"
    local rc
    run_hook "implement a retry wrapper around the fetch call in src/api.ts" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { echo "  FAIL: hook must exit 0 on a firing prompt (got $rc)"; return 1; }
}

# ============================================================================

echo ""
echo "cs scope-prompt tests"
echo "====================="
echo ""

run_test test_prompt_clears_attention_marker
run_test test_classifier_fires_emit_scope_block
run_test test_classifier_silent_passthrough
run_test test_classifier_borderline_fires_as_documented
run_test test_scope_block_frames_matches_as_non_authoritative
run_test test_scan_surfaces_relevant_file
run_test test_scan_includes_recent_commits
run_test test_scan_excludes_build_and_meta_dirs
run_test test_scan_over_match_lone_dot_defused
run_test test_scan_bounded_on_common_words
run_test test_scan_handles_spaces_in_filenames
run_test test_scan_surfaces_short_dir_tokens
run_test test_scan_no_substring_overmatch
run_test test_scan_component_matches_unexcluded_dir
run_test test_scan_camelcase_component_match
run_test test_scan_trailing_punctuation_recall
run_test test_scan_acronym_component_match
run_test test_working_tree_truncation_cue
run_test test_token_cap_under_8000_bytes
run_test test_token_cap_marks_truncation
run_test test_noop_outside_cs_session
run_test test_opt_out_via_disable_env
run_test test_graceful_malformed_input
run_test test_empty_tree_tombstone_marker
run_test test_injection_prompt_is_data_not_code
run_test test_firing_prompt_exits_zero

report_results
