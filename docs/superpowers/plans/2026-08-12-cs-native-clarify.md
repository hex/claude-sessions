# cs-native clarify (ask-questions half) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude ask clarifying questions instead of guessing when a cs session prompt is ambiguous, by injecting a short guideline into the existing `UserPromptSubmit` hook's `additionalContext`.

**Architecture:** A new stage folded into `hooks/scope-prompt.sh`, sitting **above** the work-verb classifier because a vague prompt carries no work verb and would otherwise be dropped before the check ran. The guideline is injected on every non-empty prompt (no code-level vagueness gate — the model judges ambiguity, which is the one thing a basic regular expression cannot do). The hook emits exactly **one** `additionalContext` object per run, so the guideline is composed with the existing digest and scope blocks rather than emitted separately.

**Tech Stack:** bash, jq. No new dependencies, no new hook file, no registration changes.

## Global Constraints

- **bash 3.2 / BSD userland floor.** `macos-latest` CI runs the whole suite under stock `/bin/bash` 3.2. No `local -A`, no `printf '%(...)T'`, no `source <()`, no GNU-only `sed`/`awk`/`stat`/`timeout`.
- **Fold into the existing hook.** All changes land in `hooks/scope-prompt.sh`. Creating a new hook file is out of scope — it costs 5-site registration overhead.
- **One emission per run.** `UserPromptSubmit` consumes a single `hookSpecificOutput` object. Every exit path emits at most once.
- **`assert_file_contains` takes a basic regular expression, not a literal.** Escape `[` and `]` in any pinned string or the pin becomes unpassable or vacuous.
- **Asserts need `|| return 1`** unless the assert is the function's last statement — `run_test` disables errexit.
- **No real identities in fixtures.** Use `example.com`, `alice`, `test-session`.
- **New files start with two `ABOUTME: ` comment lines.**
- **Never reformat untouched lines.** Match the surrounding style of `scope-prompt.sh`.

### Settled design decisions (do not relitigate)

| Decision | Value |
|---|---|
| Gating | Always inject; wording carries the load |
| Per-turn opt-out | Leading `~` (verified to survive the composer) |
| Opted-out turn | Injects **nothing** at all |
| Session switch | `CS_CLARIFY_DISABLE=1` (its own, not `CS_SCOPE_DISABLE`) |
| Prefix skips | `/`, `!`, `~` |
| Minimum length | **None.** Do not transplant objective capture's 8-char floor — "fix it" is six characters and is this feature's primary audience |
| Empty prompt | Skipped — an empty prompt is a mail wake, not vague input |

---

### Task 1: Inject the guideline on a scope-firing prompt

The smallest end-to-end slice: a prompt that already reaches the final emit gains the guideline.

**Files:**
- Modify: `hooks/scope-prompt.sh` (add the guideline text and decision after the wake-budget block at :126-128; append `$CLARIFY` at the final emit :467-474)
- Test: `tests/test_clarify.sh` (create)

**Interfaces:**
- Produces: shell variable `CLARIFY` — the guideline text, or empty string when suppressed. Read by both emit paths.
- Produces: `CLARIFY_TEXT` — the constant guideline body, single-quoted (contains no apostrophe, deliberately).

- [ ] **Step 1: Write the failing test**

Create `tests/test_clarify.sh`. The setup mirrors `tests/test_objective_capture.sh` — copy its env-scrubbing `setup`, its `teardown`, and its `run_hook` verbatim; those solve real problems (a live session leaking `CS_*`/`CLAUDE_*` values in, and a SIGPIPE from a `jq | hook` pipe when the hook exits before draining stdin).

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the clarify guideline folded into the scope-prompt UserPromptSubmit hook
# ABOUTME: Validates always-on injection, the prefix and env opt-outs, and single-emission composition

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HOOK="$SCRIPT_DIR/../hooks/scope-prompt.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # Drop ambient cs/Claude env so a live session can't leak values the hook reads.
    local _v
    while IFS='=' read -r _v _; do
        case "$_v" in CS_*|CLAUDE_*) unset "$_v" 2>/dev/null || true ;; esac
    done < <(env)
    export CLAUDE_SESSION_NAME="test-clarify"
    export CLAUDE_SESSION_DIR="$TEST_TMPDIR/session"
    export CLAUDE_SESSION_META_DIR="$CLAUDE_SESSION_DIR/.cs"
    mkdir -p "$CLAUDE_SESSION_META_DIR/local"
    # git init and the identity live in setup, matching tests/test_scope_prompt.sh.
    # The identity is not optional: a bare CI runner auto-detects an empty ident
    # name and every commit here fails.
    git -C "$CLAUDE_SESSION_DIR" init -q
    git -C "$CLAUDE_SESSION_DIR" config user.email "test@cs.local"
    git -C "$CLAUDE_SESSION_DIR" config user.name "cs test"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Track the named files, so scope grounding has something to match.
# Same signature as the helper in tests/test_scope_prompt.sh.
seed_repo() {
    local f
    for f in "$@"; do
        mkdir -p "$CLAUDE_SESSION_DIR/$(dirname "$f")"
        printf 'placeholder content for %s\n' "$f" > "$CLAUDE_SESSION_DIR/$f"
    done
    git -C "$CLAUDE_SESSION_DIR" add -A >/dev/null 2>&1
    git -C "$CLAUDE_SESSION_DIR" commit -q -m "seed" >/dev/null 2>&1
}

# Feed a prompt to the hook as the harness would (JSON on stdin).
run_hook() {
    # Herestring, not a live `jq | hook` pipe: the hook can exit before draining
    # stdin, which would leave jq writing into a closed fd (SIGPIPE) and
    # `set -o pipefail` would surface that as a non-zero exit.
    # The prompt goes in on jq's STDIN, never as an argv value: a leading-slash
    # argument can be rewritten before jq sees it.
    local prompt="$1" _in
    _in=$(printf '%s' "$prompt" | jq -Rs '{prompt: ., hook_event_name: "UserPromptSubmit"}')
    "$HOOK" <<< "$_in"
}

# The additionalContext string the hook emitted (empty if it emitted nothing).
emitted_context() {
    jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

test_guideline_injected_on_scope_firing_prompt() {
    seed_repo
    local ctx
    ctx=$(run_hook "implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a code-work prompt carries the clarify guideline" || return 1
    assert_output_contains "$ctx" "Scope (auto-grounded)" \
        "the scope block is still emitted alongside it"
}

run_test test_guideline_injected_on_scope_firing_prompt

report_results
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_clarify.sh`

Expected: FAIL on the first assert — the emitted context contains the scope block but not `Before acting on this request`.

Note the explicit `/bin/bash`: plain `bash` on this machine is 5.x, but the floor and `macos-latest` CI are 3.2.

- [ ] **Step 3: Write minimal implementation**

In `hooks/scope-prompt.sh`, immediately after the wake-budget block that ends at line 128 (before the `# --- Queue inbox digest` comment), add:

```bash
# --- Clarify guideline (every prompt; the model judges ambiguity, not a regex) ---

# Injected on every prompt rather than gated by a classifier. The hook's existing
# work-verb classifier guards EXPENSIVE git work, which is what earns its
# false-positive risk; this guards ~700 bytes of text, so a gate would buy
# nothing and pay for itself in misclassification. Vagueness is a semantic
# judgement and the model is the only component here that can make it.
#
# Single-quoted, so the body must stay free of apostrophes — a heredoc would
# cost a fork on a hot path.
CLARIFY_TEXT='## Clarify

Before acting on this request, judge whether it is actionable as written. If you genuinely cannot determine the intended outcome, target, or scope — or it could mean materially different things ("it", "that thing", "make it better") — do not guess. Ask first: one AskUserQuestion call with 1-3 targeted questions, offering your best-guess interpretation as the first option, marked (Recommended). If intent is clear from the prompt plus conversation and repo context, proceed without asking — do not ask confirmation questions about requests you already understand, and never ask more than once per request. A prompt beginning with `~` is an explicit opt-out of this check: treat the `~` as noise and proceed without asking.'

CLARIFY=""
if [ "${CS_CLARIFY_DISABLE:-}" != "1" ] && [ -n "$PROMPT" ]; then
    # Fork-free leading-whitespace strip, so " ~foo" still reads as opted out.
    _clarify_lead=${PROMPT#"${PROMPT%%[![:space:]]*}"}
    # Slash commands and shell passthrough carry their own instructions; a
    # competing "ask questions first" would fight them. `~` is the opt-out.
    case "$_clarify_lead" in
        /*|!*|'~'*) ;;
        *) CLARIFY="$CLARIFY_TEXT" ;;
    esac
fi
_trace clarify
```

Then change the final emit (currently lines 473-474) so the guideline rides last — closest to the prompt, where an instruction reads most strongly:

```bash
[ -n "$CLARIFY" ] && BLOCK="$BLOCK

$CLARIFY"

jq -n --arg c "$BLOCK" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
```

Place that append **after** the 8000-byte token cap at :461-465, so the cap keeps bounding the scan output it was written for and never truncates the guideline mid-sentence.

- [ ] **Step 4: Run test to verify it passes**

Run: `/bin/bash tests/test_clarify.sh`
Expected: PASS, 1/1.

Then confirm nothing regressed: `/bin/bash tests/test_scope_prompt.sh` and `/bin/bash tests/test_objective_capture.sh` — expected PASS, 33/33 and 12/12.

- [ ] **Step 5: Commit**

```bash
git add tests/test_clarify.sh hooks/scope-prompt.sh
git commit -m "feat(clarify): inject the clarify guideline on scope-firing prompts"
```

---

### Task 2: Inject on prompts that do not fire scope grounding

"make it better" is the prompt this feature exists for, and it exits through `_digest_exit` long before the final emit — which today emits nothing at all unless a digest is pending. This task makes that path emit.

**Files:**
- Modify: `hooks/scope-prompt.sh` (add `_emit_context` helper; rewire `_digest_exit` :246-254 and the final emit)
- Test: `tests/test_clarify.sh`

**Interfaces:**
- Consumes: `CLARIFY` from Task 1.
- Produces: `_emit_context <part>...` — prints one `additionalContext` JSON object built from the non-empty parts joined by blank lines; prints nothing when every part is empty.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_clarify.sh`, above the `run_test` lines:

```bash
test_guideline_injected_on_vague_prompt() {
    seed_repo
    # "make" is deliberately absent from the hook's work-verb regex, so this
    # prompt exits through the digest path and never reaches the scope emit.
    local ctx
    ctx=$(run_hook "make it better" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a vague prompt still carries the guideline" || return 1
    assert_output_not_contains "$ctx" "Scope (auto-grounded)" \
        "and does not drag in the scope block"
}

test_short_prompt_is_not_filtered() {
    seed_repo
    # Objective capture skips prompts under 8 chars; clarify must not, or it
    # misses exactly the prompts it exists for.
    local ctx
    ctx=$(run_hook "fix it" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "a six-character prompt still carries the guideline"
}
```

Register both:

```bash
run_test test_guideline_injected_on_vague_prompt
run_test test_short_prompt_is_not_filtered
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_clarify.sh`
Expected: FAIL on both new tests — the hook emits nothing at all on these prompts, so `$ctx` is empty.

- [ ] **Step 3: Write minimal implementation**

Add the helper immediately above `_digest_exit` in `hooks/scope-prompt.sh`:

```bash
# Emit the run's single additionalContext object from the non-empty parts,
# separated by blank lines. UserPromptSubmit consumes exactly one object, so
# every exit path funnels through here rather than emitting its own.
_emit_context() {  # part...
    local out="" part
    for part in "$@"; do
        [ -n "$part" ] || continue
        if [ -n "$out" ]; then
            out="$out

$part"
        else
            out="$part"
        fi
    done
    [ -n "$out" ] || return 0
    jq -n --arg c "$out" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
}
```

Rewrite `_digest_exit` to use it:

```bash
_digest_exit() {
    _emit_context "$DIGEST" "$CLARIFY"
    _commit_digest "${CLAUDE_SESSION_META_DIR:-}/local"
    _trace exit
    exit 0
}
```

Replace the final emit and the `if [ -n "$DIGEST" ]` prepend above it (currently :467-474, plus the `[ -n "$CLARIFY" ]` append added in Task 1) with a single call:

```bash
_emit_context "$DIGEST" "$BLOCK" "$CLARIFY"
```

Delete the now-dead `if [ -n "$DIGEST" ]; then BLOCK="$DIGEST\n\n$BLOCK"; fi` prepend and the Task 1 `[ -n "$CLARIFY" ]` append — `_emit_context` does both, in the same order.

- [ ] **Step 4: Run test to verify it passes**

Run: `/bin/bash tests/test_clarify.sh`
Expected: PASS, 3/3.

Regression gate — the digest path is shared, so run the suites that exercise it:
`/bin/bash tests/test_scope_prompt.sh`, `/bin/bash tests/test_objective_capture.sh`, `/bin/bash tests/test_msg.sh`, `/bin/bash tests/test_queue_supervision.sh`.
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/test_clarify.sh hooks/scope-prompt.sh
git commit -m "feat(clarify): inject on every prompt, via a single-emission helper"
```

---

### Task 3: The opt-outs

**Files:**
- Modify: `hooks/scope-prompt.sh` only if a test fails (Task 1 should already satisfy these)
- Test: `tests/test_clarify.sh`

**Interfaces:**
- Consumes: `CLARIFY`, `_emit_context` from Tasks 1-2.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_clarify.sh`:

```bash
test_tilde_prefix_opts_out() {
    seed_repo
    local ctx
    ctx=$(run_hook "~implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "a leading tilde suppresses the guideline" || return 1
    # The opt-out is for the questions, not for grounding.
    assert_output_contains "$ctx" "Scope (auto-grounded)" \
        "scope grounding still runs on an opted-out turn"
}

test_leading_whitespace_before_tilde_still_opts_out() {
    seed_repo
    local ctx
    ctx=$(run_hook "  ~implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "leading whitespace does not defeat the tilde opt-out"
}

test_slash_command_skipped() {
    seed_repo
    local ctx
    ctx=$(run_hook "/color red" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "slash commands carry their own instructions"
}

test_bang_passthrough_skipped() {
    seed_repo
    local ctx
    ctx=$(run_hook "!printenv CS_TERM_THEME" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "shell passthrough is not a request to clarify"
}

test_empty_prompt_skipped() {
    seed_repo
    # An empty prompt is a mail wake, not vague input. Injecting here would put
    # the guideline on every unattended wake turn.
    local ctx
    ctx=$(run_hook "" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "a wake turn carries no prompt and gets no guideline"
}

test_opt_out_via_disable_env() {
    seed_repo
    local ctx
    ctx=$(CS_CLARIFY_DISABLE=1 run_hook "implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_not_contains "$ctx" "Before acting on this request" \
        "CS_CLARIFY_DISABLE suppresses the guideline" || return 1
    assert_output_contains "$ctx" "Scope (auto-grounded)" \
        "and leaves scope grounding alone"
}

test_scope_disable_does_not_suppress_clarify() {
    seed_repo
    # The two switches are independent by design: silencing grounding must not
    # silence the questions.
    local ctx
    ctx=$(CS_SCOPE_DISABLE=1 run_hook "implement a retry wrapper in src/api.ts" | emitted_context)
    assert_output_contains "$ctx" "Before acting on this request" \
        "CS_SCOPE_DISABLE leaves the clarify guideline in place" || return 1
    assert_output_not_contains "$ctx" "Scope (auto-grounded)" \
        "while still suppressing scope grounding"
}
```

Register all seven:

```bash
run_test test_tilde_prefix_opts_out
run_test test_leading_whitespace_before_tilde_still_opts_out
run_test test_slash_command_skipped
run_test test_bang_passthrough_skipped
run_test test_empty_prompt_skipped
run_test test_opt_out_via_disable_env
run_test test_scope_disable_does_not_suppress_clarify
```

- [ ] **Step 2: Run the tests**

Run: `/bin/bash tests/test_clarify.sh`

Expected: PASS, 10/10. Task 1's implementation should already satisfy every one of these — these tests exist to pin the behavior, not to drive new code.

**If any fails, that is the finding.** Do not weaken the test to match the code. The likely culprits, in order: `test_scope_disable_does_not_suppress_clarify` (would fail if the clarify stage was placed below the `CS_SCOPE_DISABLE` gate at :297 instead of above the classifier), and `test_leading_whitespace_before_tilde_still_opts_out` (would fail if the `${PROMPT%%[![:space:]]*}` trim was dropped).

- [ ] **Step 3: Fix only what failed**

If a test failed, move the clarify stage or restore the trim. Make one change, re-run, do not stack fixes.

- [ ] **Step 4: Full regression**

Run: `/bin/bash tests/run_all.sh`
Expected: all suites PASS. This takes ~5-6 minutes of wall time; check `ps -eo etime` on the pid before concluding it hung.

- [ ] **Step 5: Commit**

```bash
git add tests/test_clarify.sh
git commit -m "test(clarify): pin the tilde, prefix, wake and env opt-outs"
```

---

### Task 4: Single emission and ordering

The hook must emit exactly one JSON object however many components are live. This task proves it with all three present at once.

**Files:**
- Test: `tests/test_clarify.sh`

**Interfaces:**
- Consumes: `_emit_context` from Task 2.

- [ ] **Step 1: Write the failing test**

```bash
test_emits_exactly_one_object_with_all_parts() {
    seed_repo
    # Seed a pending queue digest so all three components are live at once.
    printf '%s\n' '{"event":"task_done"}' \
        > "$CLAUDE_SESSION_META_DIR/local/notifications.jsonl"

    local raw
    raw=$(run_hook "implement a retry wrapper in src/api.ts")

    # One object, not a stream: jq -s wraps the input in an array.
    local count
    count=$(printf '%s' "$raw" | jq -s 'length' 2>/dev/null)
    assert_eq "1" "$count" "the hook emits exactly one JSON object" || return 1

    local ctx
    ctx=$(printf '%s' "$raw" | emitted_context)
    assert_output_contains "$ctx" "cs queue while you were away" \
        "the digest is present" || return 1
    assert_output_contains "$ctx" "Scope (auto-grounded)" \
        "the scope block is present" || return 1
    assert_output_contains "$ctx" "Before acting on this request" \
        "the guideline is present" || return 1

    # Order: digest, then scope, then the guideline last — an instruction reads
    # most strongly closest to the prompt.
    printf '%s\n' "$ctx" \
        | awk '/^cs queue while you were away/{d=NR} /^## Scope/{s=NR} /^## Clarify/{c=NR}
               END{exit !(d && s && c && d < s && s < c)}' \
        || { echo "  FAIL: components out of order (want digest, scope, clarify)"; return 1; }
}
```

Register it:

```bash
run_test test_emits_exactly_one_object_with_all_parts
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `/bin/bash tests/test_clarify.sh`

Expected: PASS, 11/11, if Task 2 wired `_emit_context "$DIGEST" "$BLOCK" "$CLARIFY"` in that argument order. A FAIL on the order check means the arguments are in the wrong sequence — fix the call site, not the test.

- [ ] **Step 3: Commit**

```bash
git add tests/test_clarify.sh
git commit -m "test(clarify): pin single emission and component order"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/hooks.md` (after the objective-capture paragraph at :158)
- Modify: `docs/configuration.md` (after the `CS_OBJECTIVE_CAPTURE_DISABLE` entry at :51)
- Modify: `README.md` (the scope-prompt hook description)
- Modify: `CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: Add the hooks.md entry**

Append after the objective-capture paragraph, matching its voice and length:

```markdown
**Clarify.** Injects a short guideline asking Claude to question an ambiguous request rather than guess at it. Deliberately ungated: the hook's work-verb classifier exists to guard expensive git work, whereas this guards a few hundred bytes of text, so a code-level vagueness check would buy nothing and cost misclassifications — and a vague prompt carries no work verb, so the classifier would drop it anyway. The guideline sets a high bar for asking ("genuinely cannot determine"), caps it at one batched question, and makes proceeding the default. Skips empty prompts (a mail wake carries none), slash commands and `!` shell passthrough. Opt out for one turn with a leading `~`; opt out per-session: `export CS_CLARIFY_DISABLE=1`.
```

- [ ] **Step 2: Add the configuration.md entry**

```bash
# Opt a session out of the clarify guideline (see hooks.md)
export CS_CLARIFY_DISABLE="1"
```

- [ ] **Step 3: Update README.md**

`README.md:40` is the `**Auto-grounded scope**` bullet. Add one sentence to the end of that bullet, immediately before the closing `See [docs/hooks.md](docs/hooks.md)`:

```markdown
The same hook asks Claude to question an ambiguous request rather than guess at it; skip one turn with a leading `~`, or the session with `CS_CLARIFY_DISABLE=1`.
```

Do not add a separate top-level bullet — one hook, one entry.

- [ ] **Step 4: Add the CHANGELOG entry**

Under `## [Unreleased]`, in `### Added`:

```markdown
- Clarify guideline in the prompt hook: Claude asks about an ambiguous request instead of guessing. Skip one turn with a leading `~`, or a session with `CS_CLARIFY_DISABLE=1`.
```

- [ ] **Step 5: Verify and commit**

Run: `/bin/bash tests/run_all.sh`
Expected: all PASS — `tests/test_doctor.sh` and `tests/test_install.sh` read the docs and manifests, so a docs change can genuinely break them.

```bash
git add docs/hooks.md docs/configuration.md README.md CHANGELOG.md
git commit -m "docs(clarify): document the guideline and CS_CLARIFY_DISABLE"
```

---

## Deferred: the prompt-rewrite half

Not in this plan. The `dodo-reach/pi-clarify` capability — rewriting a rough prompt into a precise one — **cannot be built as a hook**. Verified against Claude Code 2.1.228 both by reading the bundle and by running it: a `UserPromptSubmit` hook that blocks produces `num_turns=0`, `input_tokens=0`, `output_tokens=0`, `modelUsage={}`. The model is never called, so a block reason cannot carry a rewritten prompt. `suppressOriginalPrompt` only decides whether the resulting user-facing warning echoes what was typed.

Surviving options, pending an adversarial review and Alex's choice: drop it; a `/clarify` slash command; or the hook appending a rewrite instruction as ordinary context. See `.cs/memory/narrative.hex-users-noreply-github-com.md` for the full evidence.
