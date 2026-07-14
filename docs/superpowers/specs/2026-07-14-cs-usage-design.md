# cs -usage: per-session token attribution over rate-limit windows — design

Date: 2026-07-14
Status: pending spec review
Decision trail: ranked #1 in a four-provider council deep-research pass on cs
capability gaps (grok/perplexity/antigravity consensus on per-session cost
attribution); brainstormed with Alex 2026-07-14. Ground truth verified by a
seven-reader research workflow over the cs source and the installed Claude
Code bundle (v2.1.209): transcript JSONL schema, statusline stdin contract,
and the doctor token check were all read at source level.

## Context and goal

With many concurrent sessions there is no way to answer "which of these
sessions is eating my 5-hour or weekly rate-limit budget?" `cs -doctor` shows
one cumulative token line for the current project only, and the statusline
shows live percentages for the current session only. The answer requires a
table across sessions.

Three verified facts shape the design:

- **Transcript usage lines repeat per content block.** Streamed assistant
  responses write one transcript line per content block, each carrying the
  same `message.usage`. Measured on a real 11MB transcript: 1,294 usage lines
  but 542 distinct `requestId`s — a naive sum overcounts ~2.9x.
  `_doctor_check_token_cost` (lib/60-doctor.sh:315) has exactly this bug
  today. All usage math must dedup by `requestId` first.
- **Dollar figures are dead under subscription auth.** Claude Code computes
  `costUSD: 0` for subscription accounts (verified in `~/.claude/stats-cache.json`),
  and cs has no pricing table. Tokens and window percentages are the only
  honest currency.
- **Per-session attribution is structural.** Every cs session runs in its own
  cwd, so its transcripts land in their own `~/.claude/projects/<encoded>/`
  directory — including worktree tasks (`name@task` has a distinct dir). The
  statusline stdin JSON also carries `rate_limits.five_hour/seven_day`
  `used_percentage` + `resets_at` (undocumented), which cs-statusline
  currently discards after each render.

## Decisions (approved by Alex 2026-07-14)

1. **Right-now attribution, not historical accounting.** The v1 job is the
   window table. No persistent rollups, no trends, no export. (Alex chose
   this explicitly over the historical design.)
2. **Parse transcripts on demand** (Approach A). Claude Code's own
   `~/.claude/usage-data/session-meta/*.json` aggregates were rejected:
   lifetime-only totals that cannot answer a window question, computed
   lazily, undocumented internal schema.
3. **Dedup by `requestId`**, keeping one usage record per request.
4. **Fold the doctor fix in.** The shared summer replaces
   `_doctor_check_token_cost`'s math, and the doctor path adopts the
   symlink-safe `_claude_project_dir` resolution it currently skips
   (latent divergence for adopted sessions).
5. **Persist rate-limit state from the statusline.** cs-statusline extends
   its existing per-render `context-pct` write with a sibling
   `.cs/local/limits` file so `cs -usage` can anchor windows at the true
   reset boundaries.
6. **Tokens only.** No dollars anywhere in the feature.

## Non-goals

- No historical rollups, trends, CSV/JSON export, or `--json` flag.
- No TUI cost column in v1 (revisit when the tags/archive work touches the
  TUI; the data contract this feature creates is enough to add it later).
- No dollar cost estimation and no pricing table.
- No budget enforcement or warnings (that is feature 4's circuit-breaker
  territory).
- No cross-machine usage merging. Transcripts are machine-local; the table
  reports this machine's view, like `cs -live`.

## Design

### Command grammar

    cs -usage              # table across all sessions, sorted by 5h usage
    cs -usage --all        # include sessions with zero usage in both windows
    cs -usage <session>    # per-conversation breakdown for one session
    cs <session> -usage    # site-B alias for the scoped form

Single-dash verb per the flag convention, wired at both dispatch sites like
`-queue` (site A global arm; site B arm exporting the ambient session env).
The site-B error message enumeration (lib/99-main.sh:197) gains `-usage`.

### Output

    Rate limits: 5h 62% (resets 17:00) · week 41%

    SESSION            5H IN/OUT      WEEK IN/OUT     LAST ACTIVE
    claude-sessions ●  1.2M / 89K     6.4M / 410K     2m
    debug-api          340K / 12K     1.1M / 88K      3h
    research-llms      —              240K / 31K      2d

- Header: freshest `.cs/local/limits` across all sessions (rate limits are
  account-global; newest stamp wins). Absent everywhere: header says
  `Rate limits: unknown (statusline not running); windows are rolling`.
- `●` = live, via the existing `session_is_live` (lib/15-lock.sh).
- IN counts sum `input_tokens + cache_creation_input_tokens`;
  `cache_read_input_tokens` is excluded (reads are cheap and would swamp
  the signal); OUT is `output_tokens`. Humanized with doctor's `fmt` rules.
- LAST ACTIVE: newest transcript mtime in the session's project dir via
  `stat` (metadata only — the 8-day prefilter bounds which files get
  *parsed*, not which get stat'ed, so a dormant session still shows a
  truthful age under `--all`). Humanized like the TUI Age column
  (`2m`, `3h`, `2d`).
- Rows sorted by 5-hour total (in+out) descending, then week total. Rows
  with zero in both windows are hidden unless `--all`.
- Scoped form (`cs -usage <name>`): one row per conversation (jsonl file) in
  that session's project dir — short UUID, model (last seen), 5h, week, plus
  a LIFETIME column (single-dir scan makes it cheap; the global table omits
  lifetime deliberately), and last-active. No mtime prefilter in this form.

### Data path

1. Enumerate session dirs the way `cs -list` does (including adopted
   symlinks).
2. Resolve each session's transcript dir with `_claude_project_dir`
   (lib/40-state.sh:72 — `pwd -P` symlink resolution, matching Claude Code's
   own realpath-then-encode behavior). `CS_TRANSCRIPTS_DIR` stays the test
   seam.
3. Global table prefilter: skip transcript files with mtime older than 8
   days (`find -mtime` BSD-compatible) — they cannot contribute to either
   window. This is what keeps the whole-fleet scan fast.
4. One jq pass per session emitting tab-separated
   `timestamp  requestId  input  cache_create  output` for
   `type == "assistant"` lines with `.message.usage`; one awk pass dedups by
   `requestId` (first occurrence wins — repeated lines carry identical
   usage) and accumulates per-window component sums. Window comparison is
   lexicographic on ISO-8601 UTC strings (BSD awk has no `mktime`): bash
   converts the epoch window starts to ISO once, via the portable
   `date -u -r <epoch> ... || date -u -d @<epoch> ...` fallback idiom, and
   passes them as awk variables. An empty boundary string means lifetime
   (every timestamp sorts after it).
5. Subagent transcripts (`agent-*.jsonl` in per-session subdirs) are
   included in the glob if present — subagent tokens count against the same
   rate limits. (Verify the exact layout during implementation; if absent,
   the glob simply matches nothing.)
6. Window boundaries: with a limits file, 5h window = `[five_hour_resets_at
   - 5h, now]` and week = `[seven_day_resets_at - 7d, now]`. Without one,
   rolling `[now - 5h]` / `[now - 7d]`, and the header labels the windows
   approximate.

### The limits file (`.cs/local/limits`)

Written atomically (tmp+mv) by `bin/cs-statusline` on every render, next to
the existing `context-pct` write and in the same key:value format as
`.cs/local/state`:

    five_hour_used_pct: 62
    five_hour_resets_at: 1784041200
    seven_day_used_pct: 41
    seven_day_resets_at: 1784457600
    stamped_at: 1784034861

Machine-local, gitignored, ephemeral — same classification as `context-pct`
under the multi-user partition rule. Absent `rate_limits` in the stdin JSON
(older Claude Code) skips the write entirely. `cs -usage` scans all
sessions' limits files and uses the newest `stamped_at`.

### Shared summer + doctor fix

New fragment `lib/57-usage.sh` (between 56-presence and 60-doctor):

- `_usage_scan_dir <transcripts_dir> <five_h_start_iso> <week_start_iso>` —
  the jq+awk pipeline; prints one line of per-window *component* sums
  (input, cache_create, output for each window). Empty boundary strings
  mean "lifetime". Consumers compose: the usage table shows
  IN = input + cache_create; the doctor keeps its existing bare
  input/output semantics — its fix is dedup only, not a definition change.
- `run_usage()` — dispatcher: enumeration, limits lookup, table rendering,
  `--all`, scoped form.
- `_doctor_check_token_cost` (lib/60-doctor.sh) is rewritten on top of the
  same scan with lifetime bounds, fixing the ~3x overcount and adopting
  `_claude_project_dir`. Its output format ("Tokens (this project): X input,
  Y output") is unchanged; the numbers become correct.

### Wiring checklist (from the dispatch research recipe)

- `lib/99-main.sh`: site-A arm (exactly 8-space indent — the completions
  drift guard awk-parses it), site-B arm, site-B error message update.
- `lib/10-help.sh`: one Commands line (unquoted heredoc — no backticks).
- `completions/_cs` and `completions/cs.bash`: `-usage` in global flags
  (tests/test_completions.sh enforces both).
- `README.md`: command-reference line + a short feature bullet.
- `docs/statusline.md`: note the `limits` sibling of `context-pct`.
- `./build.sh` after every lib/ edit; CI fails on bin/cs drift.

## Testing (TDD, vertical slices)

`tests/test_usage.sh`, driving the assembled `bin/cs` through the harness
seams (`CS_TRANSCRIPTS_DIR`, `CS_SESSIONS_ROOT`), every assert `|| return 1`:

1. RED: `cs -usage` not "Unknown command".
2. Dedup: fixture transcript with 3 lines sharing one `requestId` (identical
   usage) plus a distinct request; sum must count each request once. The
   fixture must reach the dedup branch (distinct-requestId control proves
   the summer isn't just taking one line total).
3. Window edges: fixture timestamps straddling a window start passed as an
   explicit boundary; one in, one out.
4. Attribution: two fake sessions with distinct encoded dirs; each row shows
   only its own tokens.
5. Sorting, zero-row hiding, `--all`.
6. Limits file: seeded `.cs/local/limits` → header shows anchored resets;
   absent → "rolling" label.
7. Scoped form: per-conversation rows + lifetime column; site-B invocation.
8. Doctor regression: extend the existing doctor fixture with duplicated
   `requestId` lines; the asserted totals change to the deduped values.
9. Statusline: `tests/test_statusline.sh` gains a case asserting the limits
   file is written from a fixture with `rate_limits`, and not written when
   the field is absent.

Bash 3.2 + BSD only (no `mapfile`, no associative arrays; awk does the
aggregation). Full gate: `bash tests/run_all.sh`; cargo untouched.

## Performance and risks

- Transcript volume: multi-MB files x many sessions is the main cost; the
  8-day mtime prefilter bounds the global scan to window-relevant files.
  One jq process per session (doctor precedent), not per file.
- Schema drift: all jq field access uses `// 0` / `// empty` defaults;
  garbage lines are ignored, never fatal. The fields used are the same ones
  doctor already depends on, plus `requestId` and `timestamp`.
- Pollution: a bare `claude` run in a session's cwd outside cs lands in the
  same project dir and is attributed to that session. Acceptable — it is
  still that session's work.
- Clock skew on `resets_at`: values come from Claude Code's own rate-limit
  state; cs only subtracts the window length. Rolling fallback degrades
  gracefully.
- `last_resumed` and other `.cs/local/state` keys are untouched; no new
  synced files exist, so the multi-user matrix is unaffected.
