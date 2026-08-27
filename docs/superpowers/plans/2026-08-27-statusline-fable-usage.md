# Fable Usage Segment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `fable` segment to `cs-statusline` that shows the Fable-scoped weekly usage percentage and its reset countdown, rendered only when the active model is Fable.

**Architecture:** The figure does not exist in the statusline stdin payload, so cs fetches it itself from `GET /api/oauth/usage` using Claude Code's own Keychain OAuth token, read-only. The render never touches the network: it reads a machine-global JSON cache under `$SESSIONS_ROOT/.usage/` and, when that cache is due, detaches a `cs-statusline --refresh-usage` re-invocation of the same script. Both the cache read and the refresh trigger sit behind the model gate, so a session on any other model costs nothing.

**Tech Stack:** bash 3.2, jq, curl, `/usr/bin/security` (macOS Keychain), BSD/GNU `date` and `stat`.

**Spec:** `docs/superpowers/specs/2026-08-27-statusline-fable-usage-design.md`

## Global Constraints

- **bash 3.2 + BSD userland.** No `local -A`, no `printf '%(…)T'`, no `source <()`. Every `date`/`stat` call needs a BSD arm first and a GNU arm as fallback. macos-latest CI runs the whole suite under stock `/bin/bash` 3.2.
- **The render path performs no network I/O.** Fetching happens only in the detached `--refresh-usage` mode.
- **Never write, log, echo, or place the OAuth token on a command line.** It reaches `curl` through stdin (`-K -`) so it never appears in `ps` output, and it is never persisted.
- **cs reads Claude Code's credential; it never refreshes or writes it.** A 401 is a transient failure to back off from, not something to repair.
- **Null-when-nothing.** Any missing file, missing tool, stale record, or account mismatch means the segment does not render. It must never degrade to a wrong number.
- **Minimum 300 s between polls, machine-wide.** The endpoint's budget is ~28–30 requests per account per rolling hour and is shared with claude-swap and Claude Code itself.
- **Percent is 0–100 on the wire.** Do not multiply by 100.
- No new installed binary: the refresher is a mode of `bin/cs-statusline`, invoked as `--refresh-usage`.

---

### Task 1: ISO 8601 → epoch conversion

The usage endpoint sends `"2026-08-29T03:59:59.686034+00:00"`. `_fmt_rest` takes epoch seconds. This is the adapter, and it is pure, so it is tested directly.

**Files:**
- Modify: `bin/cs-statusline` (new helper, place immediately above `_fmt_rest`)
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Produces: `_iso_epoch "<iso string>"` → sets global `_EPOCH` to epoch seconds, or `""` when absent/unparseable.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_statusline.sh`, in the section with the other `_fmt_rest` tests:

```bash
# The usage endpoint sends ISO 8601 with fractional seconds and a +00:00 offset;
# _fmt_rest wants epoch seconds. The expected value is an independently known
# instant, not one recomputed with the same date call the helper uses.
test_iso_epoch_parses_endpoint_format() {
    _load_sl_functions
    _iso_epoch "2026-08-29T03:59:59.686034+00:00"
    assert_eq "$_EPOCH" "1787975999" "fractional seconds and +00:00 offset must parse as UTC" || return 1
    _iso_epoch "2026-08-29T03:59:59Z"
    assert_eq "$_EPOCH" "1787975999" "a trailing Z must parse to the same instant" || return 1
    _iso_epoch "2026-08-29T03:59:59"
    assert_eq "$_EPOCH" "1787975999" "a bare timestamp must be read as UTC" || return 1
}

# Garbage must yield empty, never a partial or a stale previous value.
test_iso_epoch_rejects_junk() {
    _load_sl_functions
    _iso_epoch "2026-08-29T03:59:59Z"
    _iso_epoch "not-a-timestamp"
    assert_eq "$_EPOCH" "" "unparseable input must clear _EPOCH" || return 1
    _iso_epoch ""
    assert_eq "$_EPOCH" "" "empty input must yield empty" || return 1
    _iso_epoch "2026-13-45T99:99:99Z"
    assert_eq "$_EPOCH" "" "an out-of-range timestamp must yield empty" || return 1
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | grep -A3 iso_epoch`
Expected: FAIL — `_iso_epoch: command not found`.

- [ ] **Step 3: Write the implementation**

Insert into `bin/cs-statusline` directly above `_fmt_rest`:

```bash
# Convert an ISO 8601 timestamp into epoch seconds in _EPOCH; empty when the
# value is missing or unparseable. The usage endpoint sends fractional seconds
# and an explicit "+00:00" offset ("2026-08-29T03:59:59.686034+00:00"), so both
# are trimmed and the remainder read as UTC — which is the only zone that
# endpoint emits. The shape is checked with a glob before `date` sees it, so a
# malformed value can never reach a locale-dependent parser and come back as
# something plausible. BSD date (macOS, the 3.2 floor) takes -j -f; GNU date
# takes -d, and each rejects the other's flags, so trying both in order needs no
# platform probe.
_iso_epoch() {
    _EPOCH=""
    local iso="${1:-}" base
    [ -n "$iso" ] || return 0
    base="${iso%%.*}"     # drop fractional seconds
    base="${base%%+*}"    # drop a "+HH:MM" offset
    base="${base%Z}"      # drop a trailing Z
    case "$base" in
        [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]) ;;
        *) return 0 ;;
    esac
    _EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$base" +%s 2>/dev/null)
    [ -n "$_EPOCH" ] || _EPOCH=$(date -u -d "$base" +%s 2>/dev/null)
    [[ "${_EPOCH:-}" =~ ^[0-9]+$ ]] || _EPOCH=""
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | tail -5`
Expected: PASS, and the pre-existing statusline tests still pass.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): parse ISO 8601 reset stamps into epoch seconds"
```

---

### Task 2: Carry the model id through the stdin parse

The segment gates on `.model.id`, which the parse does not currently extract. `display_name` is a server-supplied label; the id is the stable predicate.

**Files:**
- Modify: `bin/cs-statusline` — the jq field list and the matching `read` block in `_parse_stdin`
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Produces: global `SL_MODEL_ID`, e.g. `claude-fable-5`, `claude-opus-5[1m]`, or `""`.

- [ ] **Step 1: Write the failing test**

```bash
# The fable gate keys on the model id, so the parse must carry it. One value per
# line means a field added in the wrong position shifts every later field, so
# this asserts a neighbour too.
test_parse_carries_model_id() {
    _load_sl_functions
    _parse_stdin '{"model":{"id":"claude-fable-5","display_name":"Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":8}}'
    assert_eq "$SL_MODEL_ID" "claude-fable-5" "model id must be parsed from stdin" || return 1
    assert_eq "$SL_EFFORT" "high" "the field after model id must not be shifted" || return 1
    assert_eq "$SL_CTX" "8" "the field before model id must not be shifted" || return 1
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | grep -A3 parse_carries_model_id`
Expected: FAIL — `SL_MODEL_ID: unbound variable`.

- [ ] **Step 3: Write the implementation**

In `_parse_stdin`, add the id to the jq array immediately after `display_name`:

```
          (.model.display_name // ""),
          (.model.id // ""),
          (.effort.level // ""),
```

and the matching read immediately after `SL_MODEL`:

```bash
        IFS= read -r SL_MODEL
        IFS= read -r SL_MODEL_ID
        IFS= read -r SL_EFFORT
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | tail -5`
Expected: PASS. The whole suite matters here — a misplaced field would break unrelated segment tests.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): carry the resolved model id through the stdin parse"
```

---

### Task 3: The refresher — `cs-statusline --refresh-usage`

Fetches the Fable window and writes the machine-global cache. Never called from the render path synchronously.

**Files:**
- Modify: `bin/cs-statusline` — new helpers plus an argument branch in `main`
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: `_iso_epoch` (Task 1), `_sl_now`
- Produces:
  - `_usage_cache_dir` → echoes `${CS_USAGE_DIR:-$SESSIONS_ROOT/.usage}`
  - `_claude_config_file` → echoes `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`
  - `_file_age <path>` → sets `_AGE` to seconds since mtime, or `""`
  - `_refresh_usage` → writes `<cache dir>/fable.json`, honouring lock and backoff
  - Cache record: `{"org":…,"pct":86,"resets_at":"…","fetched_at":…,"next_poll_at":…}`

- [ ] **Step 1: Write the failing tests**

These shim `security` and `curl` onto `PATH`, so no network or Keychain access happens in the suite. Add a helper and the tests:

```bash
# Put fake `security` and `curl` on PATH so the refresher runs its real code path
# with no network and no Keychain. $1 is the HTTP status the fake curl reports,
# $2 the response body it writes to curl's -o target.
make_usage_shims() {
    local code="$1" body="$2"
    local bindir="$TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/security" <<'EOF'
#!/bin/bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}'
EOF
    cat > "$bindir/curl" <<EOF
#!/bin/bash
# Record what we were handed so a test can prove the token never hit argv.
printf '%s\n' "\$*" > "$TEST_TMPDIR/curl-argv"
cat > "$TEST_TMPDIR/curl-stdin"
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in -o) out="\$2"; shift 2 ;; -D) shift 2 ;; *) shift ;; esac
done
[ -n "\$out" ] && printf '%s' '$body' > "\$out"
printf '%s' '$code'
EOF
    chmod +x "$bindir/security" "$bindir/curl"
    echo "$bindir"
}

# A response shaped like the real endpoint: the unified windows carry a null
# model scope and must be skipped; only the Fable bucket is wanted.
USAGE_BODY='{"five_hour":{"utilization":31.0},"seven_day":{"utilization":49.0},"limits":[{"scope":{"type":"unified"},"percent":31,"resets_at":"2026-08-27T10:39:59.6Z"},{"scope":{"model":{"display_name":"Fable"}},"percent":86,"resets_at":"2026-08-29T03:59:59.686034+00:00"}]}'

test_refresh_writes_fable_window() {
    local bindir; bindir=$(make_usage_shims 200 "$USAGE_BODY")
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local cache="$CS_USAGE_DIR/fable.json"
    assert_file_exists "$cache" "refresh must write the cache" || return 1
    assert_eq "$(jq -r '.pct' "$cache")" "86" "must record the Fable bucket, not a unified window" || return 1
    assert_eq "$(jq -r '.resets_at' "$cache")" "2026-08-29T03:59:59.686034+00:00" "must record the Fable reset stamp" || return 1
    assert_eq "$(jq -r '.org' "$cache")" "org-abc" "must stamp the active account" || return 1
    assert_eq "$(jq -r '.next_poll_at' "$cache")" "1787816300" "next poll must be 300s out" || return 1
}

# The token must never reach argv, where any process on the machine can read it
# out of `ps`. It goes to curl on stdin as a -K config line.
test_refresh_keeps_token_off_argv() {
    local bindir; bindir=$(make_usage_shims 200 "$USAGE_BODY")
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    PATH="$bindir:$PATH" bash "$SL" --refresh-usage
    assert_output_not_contains "$(cat "$TEST_TMPDIR/curl-argv")" "test-token-not-real" \
        "the access token must not appear in curl's arguments" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/curl-stdin")" "test-token-not-real" \
        "the access token must reach curl on stdin" || return 1
}

# A 429 must not overwrite the last good reading, and must back off past the
# 300s floor: a 429 does not reliably clear at its stated horizon.
test_refresh_429_backs_off_and_keeps_last_good() {
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' '{"org":"org-abc","pct":42,"resets_at":"2026-08-29T03:59:59Z","fetched_at":1787815000,"next_poll_at":1787815300}' \
        > "$CS_USAGE_DIR/fable.json"
    local bindir; bindir=$(make_usage_shims 429 '')
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    local cache="$CS_USAGE_DIR/fable.json"
    assert_eq "$(jq -r '.pct' "$cache")" "42" "a 429 must leave the last good reading intact" || return 1
    assert_eq "$(jq -r '.next_poll_at' "$cache")" "1787816600" "a 429 must back off 600s, not the 300s floor" || return 1
}

# A response with no model-scoped bucket (an account with no Fable window) must
# clear rather than keep showing a number that no longer applies.
test_refresh_no_fable_bucket_clears() {
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    local bindir; bindir=$(make_usage_shims 200 '{"limits":[{"scope":{"type":"unified"},"percent":31,"resets_at":"2026-08-27T10:39:59Z"}]}')
    PATH="$bindir:$PATH" CS_STATUSLINE_NOW=1787816000 bash "$SL" --refresh-usage
    assert_eq "$(jq -r '.pct // "null"' "$CS_USAGE_DIR/fable.json")" "null" \
        "an account with no Fable window must record no percentage" || return 1
}
```

Add `CS_USAGE_DIR CLAUDE_CONFIG_DIR` to `teardown`'s `unset` list.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | grep -A3 test_refresh`
Expected: FAIL — the cache file is never created (`--refresh-usage` is an unknown argument and `main` ignores it).

- [ ] **Step 3: Write the implementation**

Add near the top of `bin/cs-statusline`, after `SESSIONS_ROOT`:

```bash
# Machine-global usage cache. Not per-session: the /api/oauth/usage budget is
# ~28-30 requests per account per rolling hour and is shared with Claude Code
# and any other tool on the machine, so every cs session on this host must poll
# through one file rather than one each.
_usage_cache_dir() { printf '%s\n' "${CS_USAGE_DIR:-$SESSIONS_ROOT/.usage}"; }

# Claude Code's global config, whose oauthAccount names the active account.
_claude_config_file() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"; }

# Seconds since $1 was last modified, in _AGE; empty when it cannot be read.
# BSD stat takes -f %m, GNU stat -c %Y, and each rejects the other's flag.
_file_age() {
    _AGE=""
    local m
    m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || return 0
    [[ "$m" =~ ^[0-9]+$ ]] || return 0
    _sl_now
    [[ "${_NOW:-}" =~ ^[0-9]+$ ]] || return 0
    _AGE=$(( _NOW - m ))
}
```

Add the refresher (place it after `_fmt_rest`, before the segment functions):

```bash
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
USAGE_BETA="oauth-2025-04-20"
USAGE_MIN_INTERVAL=300     # floor between polls; see the budget note above
USAGE_FAIL_BACKOFF=600     # a 429 does not reliably clear at its stated horizon

# Rewrite the cache, preserving the previous reading's fields for any argument
# passed as "-". $1 org, $2 pct, $3 resets_at, $4 next_poll_at offset seconds.
_usage_write() {
    local dir cache tmp org="$1" pct="$2" reset="$3" offset="$4"
    dir=$(_usage_cache_dir); cache="$dir/fable.json"; tmp="$cache.tmp.$$"
    _sl_now
    [[ "${_NOW:-}" =~ ^[0-9]+$ ]] || return 0
    local prev_pct=null prev_reset="" prev_fetched=0
    if [ -f "$cache" ]; then
        prev_pct=$(jq -r '.pct // "null"' "$cache" 2>/dev/null) || prev_pct=null
        prev_reset=$(jq -r '.resets_at // ""' "$cache" 2>/dev/null) || prev_reset=""
        prev_fetched=$(jq -r '.fetched_at // 0' "$cache" 2>/dev/null) || prev_fetched=0
    fi
    local fetched="$_NOW"
    if [ "$pct" = "-" ]; then pct="$prev_pct"; reset="$prev_reset"; fetched="$prev_fetched"; fi
    [ -n "$pct" ] || pct=null
    jq -n --arg org "$org" --argjson pct "$pct" --arg reset "$reset" \
        --argjson fetched "$fetched" --argjson next "$(( _NOW + offset ))" \
        '{org:$org, pct:$pct, resets_at:$reset, fetched_at:$fetched, next_poll_at:$next}' \
        > "$tmp" 2>/dev/null && mv "$tmp" "$cache" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
}

# Fetch the Fable weekly window and rewrite the cache. Runs detached from the
# render, one at a time per machine. Every failure path still stamps a
# next_poll_at, so a broken account cannot make every render re-fetch.
_refresh_usage() {
    command -v jq >/dev/null 2>&1 || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local dir lock; dir=$(_usage_cache_dir); lock="$dir/.lock"
    mkdir -p "$dir" 2>/dev/null || return 0
    # Reclaim a lock left behind by a refresher that was killed mid-flight.
    if [ -d "$lock" ]; then
        _file_age "$lock"
        [ -n "${_AGE:-}" ] && [ "$_AGE" -gt 120 ] && rmdir "$lock" 2>/dev/null
    fi
    mkdir "$lock" 2>/dev/null || return 0
    trap 'rmdir "$lock" 2>/dev/null' EXIT

    local org=""
    local cfg; cfg=$(_claude_config_file)
    [ -f "$cfg" ] && org=$(jq -r '.oauthAccount.organizationUuid // ""' "$cfg" 2>/dev/null)

    local creds token=""
    creds=$(/usr/bin/security find-generic-password -a "${USER:-$(id -un 2>/dev/null)}" \
        -s "Claude Code-credentials" -w 2>/dev/null) || creds=""
    if [ -n "$creds" ]; then
        token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    creds=""
    if [ -z "$token" ]; then _usage_write "$org" - "" "$USAGE_FAIL_BACKOFF"; return 0; fi

    local body="$dir/.resp.$$" hdr="$dir/.hdr.$$" code
    # The bearer goes to curl on stdin as a -K config line: on argv it would be
    # readable in `ps` by every process on the machine.
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - \
        --max-time 8 -o "$body" -D "$hdr" -w '%{http_code}' \
        -H "anthropic-beta: $USAGE_BETA" -H "User-Agent: cs-statusline" \
        "$USAGE_URL" 2>/dev/null) || code=000
    token=""

    if [ "$code" = "200" ]; then
        local pct reset
        pct=$(jq -r 'first(.limits[]? | select((.scope.model.display_name // "") | test("^fable"; "i")) | .percent) // empty' "$body" 2>/dev/null)
        reset=$(jq -r 'first(.limits[]? | select((.scope.model.display_name // "") | test("^fable"; "i")) | .resets_at) // empty' "$body" 2>/dev/null)
        [[ "${pct:-}" =~ ^[0-9.]+$ ]] || pct=""
        _usage_write "$org" "${pct:-null}" "${reset:-}" "$USAGE_MIN_INTERVAL"
    else
        local wait="$USAGE_FAIL_BACKOFF" ra
        if [ "$code" = "429" ] && [ -f "$hdr" ]; then
            ra=$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="retry-after:"{print $2; exit}')
            if [[ "${ra:-}" =~ ^[0-9]+$ ]] && [ $(( ra + 60 )) -gt "$wait" ]; then wait=$(( ra + 60 )); fi
        fi
        _usage_write "$org" - "" "$wait"
    fi
    rm -f "$body" "$hdr" 2>/dev/null
}
```

In `main`, branch before anything else reads stdin:

```bash
main() {
    [ "${CS_STATUSLINE_DISABLE:-}" = "1" ] && exit 0

    if [ "${1:-}" = "--refresh-usage" ]; then
        _NOW=""; _SL_NOW_READY=""
        _refresh_usage
        exit 0
    fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): fetch the Fable usage window into a machine-global cache"
```

---

### Task 4: Read the cache, gated on freshness and account

The render side. One jq reads the cache and Claude Code's config together, so the account check costs no extra fork.

**Files:**
- Modify: `bin/cs-statusline`
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: `_usage_cache_dir`, `_claude_config_file`, `_iso_epoch`, `_sl_now`
- Produces: `_fable_read` → sets `_FABLE_PCT` (integer string or `""`), `_FABLE_RESET` (epoch or `""`), `_FABLE_DUE` (`1` when a refresh should be triggered)

- [ ] **Step 1: Write the failing tests**

```bash
# Seed a cache record. $1 org, $2 pct, $3 resets_at, $4 fetched_at, $5 next_poll_at.
seed_usage_cache() {
    export CS_USAGE_DIR="$TEST_TMPDIR/usage"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    mkdir -p "$CS_USAGE_DIR"
    printf '%s' "{\"oauthAccount\":{\"organizationUuid\":\"org-abc\"}}" > "$TEST_TMPDIR/.claude.json"
    jq -n --arg o "$1" --argjson p "$2" --arg r "$3" --argjson f "$4" --argjson n "$5" \
        '{org:$o,pct:$p,resets_at:$r,fetched_at:$f,next_poll_at:$n}' > "$CS_USAGE_DIR/fable.json"
}

test_fable_read_returns_fresh_reading() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59.686034+00:00" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "$_FABLE_PCT" "86" "a fresh same-account reading must be returned" || return 1
    assert_eq "$_FABLE_RESET" "1787975999" "resets_at must arrive as epoch seconds" || return 1
    assert_eq "$_FABLE_DUE" "" "a cache inside its poll interval must not be due" || return 1
}

# Swapping accounts must blank the chip immediately rather than leave the
# previous account's percentage up until the next poll — that is exactly when a
# wrong number is most misleading.
test_fable_read_blanks_on_account_mismatch() {
    _load_sl_functions
    seed_usage_cache org-other 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "$_FABLE_PCT" "" "a reading for another account must not render" || return 1
    assert_eq "$_FABLE_DUE" "1" "an account mismatch must force a refresh" || return 1
}

test_fable_read_blanks_when_stale() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787819000 _NOW="" _SL_NOW_READY="" _fable_read   # 3000s later
    assert_eq "$_FABLE_PCT" "" "a reading older than 1800s must not render" || return 1
}

test_fable_read_marks_due_past_next_poll() {
    _load_sl_functions
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    CS_STATUSLINE_NOW=1787816400 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "$_FABLE_DUE" "1" "past next_poll_at the cache must be due" || return 1
    assert_eq "$_FABLE_PCT" "86" "a due cache still renders its last good reading" || return 1
}

test_fable_read_absent_cache_is_due_and_blank() {
    _load_sl_functions
    export CS_USAGE_DIR="$TEST_TMPDIR/usage-none"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    CS_STATUSLINE_NOW=1787816100 _NOW="" _SL_NOW_READY="" _fable_read
    assert_eq "$_FABLE_PCT" "" "no cache means no reading" || return 1
    assert_eq "$_FABLE_DUE" "1" "no cache must be due for a first fetch" || return 1
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | grep -A3 test_fable_read`
Expected: FAIL — `_fable_read: command not found`.

- [ ] **Step 3: Write the implementation**

```bash
USAGE_MAX_AGE=1800   # past this a reading is too old to show beside a live countdown

# Read the cached Fable window into _FABLE_PCT (integer) and _FABLE_RESET
# (epoch), and set _FABLE_DUE when a refresh should be kicked. One jq reads the
# cache and Claude Code's config together, so verifying the reading belongs to
# the account now signed in costs no extra fork. Anything unreadable, stale, or
# belonging to another account yields no reading — the chip must never show a
# number that is not this account's, right now.
_fable_read() {
    _FABLE_PCT=""; _FABLE_RESET=""; _FABLE_DUE=""
    command -v jq >/dev/null 2>&1 || return 0
    local cache cfg; cache="$(_usage_cache_dir)/fable.json"; cfg=$(_claude_config_file)
    if [ ! -f "$cache" ]; then _FABLE_DUE=1; return 0; fi
    [ -f "$cfg" ] || return 0
    _sl_now
    [[ "${_NOW:-}" =~ ^[0-9]+$ ]] || return 0
    local fields
    fields=$(jq -r --slurpfile cfg "$cfg" '
        (($cfg[0].oauthAccount.organizationUuid) // "") as $live
        | [ (if (.org // "") == "" or $live == "" or (.org == $live) then "1" else "0" end),
            (.pct // "" | tostring),
            (.resets_at // ""),
            (.fetched_at // 0 | tostring),
            (.next_poll_at // 0 | tostring) ] | .[]' "$cache" 2>/dev/null) || return 0
    local ok pct reset fetched next
    {
        IFS= read -r ok
        IFS= read -r pct
        IFS= read -r reset
        IFS= read -r fetched
        IFS= read -r next
    } <<EOF
$fields
EOF
    [[ "${next:-}" =~ ^[0-9]+$ ]] || next=0
    [ "$_NOW" -ge "$next" ] && _FABLE_DUE=1
    [ "${ok:-0}" = "1" ] || { _FABLE_DUE=1; return 0; }
    [[ "${fetched:-}" =~ ^[0-9]+$ ]] || return 0
    [ $(( _NOW - fetched )) -le "$USAGE_MAX_AGE" ] || return 0
    [[ "${pct:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    _FABLE_PCT="${pct%%.*}"
    _iso_epoch "$reset"
    _FABLE_RESET="${_EPOCH:-}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): read the cached Fable window, gated on freshness and account"
```

---

### Task 5: The segment

**Files:**
- Modify: `bin/cs-statusline` — icon, `_seg_fable`, default segment list, `main` dispatch
- Test: `tests/test_statusline.sh`

**Interfaces:**
- Consumes: `_fable_read` (Task 4), `SL_MODEL_ID` (Task 2), `_thresh_color`, `_fmt_rest`, `_add`
- Produces: segment name `fable`, default order `logo,session,notes,mail,pane,git,model,ctx,limits,fable`

- [ ] **Step 1: Write the failing tests**

```bash
# The chip renders only on Fable. Every other model must pay nothing — no chip,
# and (asserted separately) no poll.
test_fable_segment_only_on_fable() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-opus-5","display_name":"Opus"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_not_contains "$out" "fable" "a non-fable model must not render the fable chip" || return 1
}

test_fable_segment_renders_on_fable() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 42 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 42%" "a fable session must render the chip" || return 1
    assert_output_not_contains "$out" "fable 42% ·" "below 80% the countdown must be withheld" || return 1
}

# A context-window suffix must not defeat the gate.
test_fable_segment_matches_1m_variant() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    seed_usage_cache org-abc 42 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5[1m]","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 42%" "claude-fable-5[1m] must still gate on" || return 1
}

# At 80% and up the countdown appears, matching the weekly block's gate. The
# expected string is computed from the known instants, not from _fmt_rest.
test_fable_segment_countdown_at_80() {
    export NO_COLOR=1 CS_USAGE_NO_REFRESH=1
    # reset 2026-08-29T03:59:59Z = 1787975999; now 1787816100 -> 159899s = 1d20h
    seed_usage_cache org-abc 86 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 86% · 1d20h" "at 80%+ the countdown must be appended" || return 1
}

test_fable_segment_escalates_colour() {
    export CS_USAGE_NO_REFRESH=1 COLORTERM=truecolor
    seed_usage_cache org-abc 95 "2026-08-29T03:59:59Z" 1787816000 1787816300
    local json='{"session_name":"s","model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/none"}}'
    local out; out=$(CS_STATUSLINE_NOW=1787816100 run_sl "$json")
    assert_output_contains "$out" "fable 95%" "the chip must render" || return 1
    assert_output_contains "$out" "48;2;229;115;115" "at 90%+ the chip must go red" || return 1
}

# Cheapness is a design property, not an incidental one: a non-fable session
# must not even look at the cache, let alone poll.
test_fable_segment_costs_nothing_off_fable() {
    export NO_COLOR=1
    export CS_USAGE_DIR="$TEST_TMPDIR/usage-unwritable"
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR"
    printf '%s' '{"oauthAccount":{"organizationUuid":"org-abc"}}' > "$TEST_TMPDIR/.claude.json"
    local json='{"session_name":"s","model":{"id":"claude-sonnet-5","display_name":"Sonnet"},"workspace":{"current_dir":"/none"}}'
    run_sl "$json" >/dev/null
    assert_not_exists "$CS_USAGE_DIR" "a non-fable session must not create the usage cache dir" || return 1
}
```

Add `CS_USAGE_NO_REFRESH` to `teardown`'s `unset` list.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | grep -A3 test_fable_segment`
Expected: FAIL — no `fable` text in the output.

- [ ] **Step 3: Write the implementation**

Add the icon beside the others:

```bash
ICON_FABLE=$'\xe2\x9c\xa7 '     # U+2727 white four-pointed star (model-scoped limit)
```

Add the segment after `_seg_limits`:

```bash
# Fable's weekly window, which is model-scoped and so appears in none of the
# rate_limits Claude Code puts on stdin. Rendered only on Fable: on any other
# model the gate returns before the cache is touched, so the segment costs
# nothing — no file read, no fork, and no poll against a budget shared with
# Claude Code itself.
_seg_fable() {
    case "${SL_MODEL_ID:-}" in claude-fable*) ;; *) return 0 ;; esac
    _fable_read
    if [ -n "$_FABLE_DUE" ] && [ "${CS_USAGE_NO_REFRESH:-}" != "1" ]; then
        # Detached: the render never waits on the network. The subshell exits
        # immediately, orphaning the refresher, and the refresher's own lock
        # keeps concurrent sessions from stampeding the endpoint.
        ( "${BASH:-bash}" "$_SL_SELF" --refresh-usage >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
    [ -n "$_FABLE_PCT" ] || return 0
    _thresh_color "$_FABLE_PCT" 70 90
    local label="fable ${_FABLE_PCT}%"
    # Gated at 80% like the weekly block: this is a seven-day window, so
    # time-to-reset only becomes actionable as it nears exhaustion.
    if [ "$_FABLE_PCT" -ge 80 ]; then
        _fmt_rest "$_FABLE_RESET"
        [ -n "$_REST" ] && label="$label · $_REST"
    fi
    _add "${ICON_FABLE}${label}" "$_COLOR"
}
```

Record the script's own path near the top, so the detached re-invocation works whether the file is run from `bin/` or from the installed `~/.local/bin/cs-statusline`:

```bash
_SL_SELF="${BASH_SOURCE[0]}"
```

Wire into `main`:

```bash
    local segments="${CS_STATUSLINE_SEGMENTS:-logo,session,notes,mail,pane,git,model,ctx,limits,fable}"
```
```bash
            limits)  _seg_limits ;;
            fable)   _seg_fable ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/bin/bash tests/test_statusline.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/cs-statusline tests/test_statusline.sh
git commit -m "feat(statusline): render a Fable usage chip when the model is Fable"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/statusline.md` — segment table, the "no network access" paragraph, the env-var list
- Modify: `README.md` — the statusline section

- [ ] **Step 1: Update the segment table**

Add a row after `limits`:

```markdown
| `fable` | Fable's own weekly usage as a single block, `fable 86% · 1d20h`, rendered only when the active model is Fable. Fable draws on a model-scoped weekly bucket that the plan-wide `5h`/`wk` numbers do not describe, so without this block a Fable session shows two figures for a limit that is not the one about to bite. The countdown appends at 80% and up, like `wk` | `GET /api/oauth/usage`, cached machine-globally (see below) | Grey; escalates to amber at 70% and red at 90% |
```

- [ ] **Step 2: Correct the cost paragraph**

Replace the sentence "There is no transcript parsing, no network access, and no caching." with:

```markdown
There is no transcript parsing. The render performs no network access: the one
figure that cannot come from stdin — Fable's model-scoped weekly window — is
read from a cache, and only on a Fable session, where it costs one extra `jq`
that reads the cache and Claude Code's config together. On every other model the
segment returns before touching either.

That cache is refreshed out of band. When the reading is due, the render
detaches `cs-statusline --refresh-usage`, which reads Claude Code's own OAuth
token from the macOS Keychain (never refreshing or writing it — Claude Code owns
that credential), calls `GET /api/oauth/usage`, and rewrites
`$CS_SESSIONS_ROOT/.usage/fable.json`. The token reaches `curl` on stdin, never
on a command line where `ps` would expose it.

The cache is machine-global rather than per-session on purpose. That endpoint
admits roughly 28-30 requests per account per rolling hour — capacity returns
only as old requests age out, so a burst saturates the account for a full hour —
and the budget is shared with Claude Code itself and with any other tool on the
machine. One cache and a 300-second floor keep cs to about twelve requests an
hour no matter how many sessions are open; a `mkdir` lock serialises refreshers,
and a 429 backs off for `Retry-After` plus a minute, floored at ten.
```

- [ ] **Step 3: Document the environment variables**

Add to the env-var section:

```markdown
# Where the machine-global usage cache lives (default $CS_SESSIONS_ROOT/.usage)
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the fable chip from cache only, never triggering a refresh
export CS_USAGE_NO_REFRESH=1
```

- [ ] **Step 4: Update README.md**

In the statusline section, add `fable` to the listed segments and note it appears only on Fable.

- [ ] **Step 5: Commit**

```bash
git add docs/statusline.md README.md
git commit -m "docs(statusline): document the fable segment and its out-of-band refresh"
```

---

## Final verification

- [ ] Run the full suite on the 3.2 floor: `/bin/bash tests/run_all.sh`
- [ ] Confirm the live bar: with a Fable session open, `cat "$CS_SESSIONS_ROOT/.usage/fable.json"` shows a reading whose `org` matches `jq -r .oauthAccount.organizationUuid ~/.claude.json`, and the rendered bar carries the chip.
- [ ] Confirm the poll floor holds: two consecutive renders inside 300 s must not produce a second fetch (check `fetched_at` is unchanged).
