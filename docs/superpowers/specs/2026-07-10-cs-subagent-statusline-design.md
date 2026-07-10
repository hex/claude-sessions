# cs-subagent-statusline — design

Status: approved (design), pending implementation
Date: 2026-07-10
Branch: `feat/cs-subagent-statusline`

## Problem

Claude Code's agent panel — the tree below the prompt — renders each running subagent as
`name · description · token count`. Nothing there says which model is driving the agent, how
full its context window is, or how long it has been running. When several agents run at
different tiers (Sonnet for recon, Opus for synthesis, Fable to finalize) the rows are
indistinguishable, and a subagent that is about to die of context exhaustion looks exactly
like one that just started.

The main status bar cannot help: it reports the *parent* session's model, context, and cost,
and it does not change when you drill into an agent's transcript.

## What the Claude Code contract actually allows

Established by reading the installed 2.1.206 bundle, not the docs. Verbatim evidence is in
the session narrative; the load-bearing findings:

1. **Invocation is gated on tasks existing, not on the current view.** The invoker bails with
   `if (o === void 0 || e.length === 0) return {}` where `e` is the row set
   `tasks.filter(t => UG(t) && t.evictAfter !== 0)`.

2. **Rows survive drilling into an agent.** Entering an agent's transcript sets
   `viewingAgentTaskId` *and* marks that task `retain: true`, clearing `evictAfter`. The
   viewed task therefore stays in the row set and keeps ticking.

3. **The script cannot know which agent you are viewing.** The stdin payload is
   `{...baseHookFields, columns, tasks[]}`. `viewingAgentTaskId` never enters it. Claude Code
   itself passes the viewed id into its own row builder (`w7(tasks, decorations, viewingAgentTaskId, …)`),
   so it already distinguishes that row. We do not, and must not pretend to.

4. **The zero-transition is invisible.** When the last agent exits, `e.length === 0`
   short-circuits *before* the command runs. A file written by this script can never be
   cleared by this script. (This is why the originally-considered `.cs/local/agents`
   cross-feed to the main bar was dropped.)

5. **Registration is snapshot-read** from the settings store
   (`c.settings?.subagentStatusLine?.command !== undefined`), so a mid-session edit does
   nothing. Verified empirically: a probe registered mid-session logged zero ticks in 120 s
   with a live subagent. **Enabling requires a Claude Code restart.**

6. **Runner contract:** `timeout: 5000` ms, `preserveOutputOnError: true`. Each stdout line is
   `JSON.parse`d and schema-checked against `{id, content}`; a malformed line is logged
   (`subagentStatusLine emitted non-JSON line`) and skipped, not fatal. A script that fails
   entirely leaves the previous decorations in place — i.e. stale rows.

### stdin shape

```json
{
  "session_id": "…", "transcript_path": "…", "cwd": "…",
  "columns": 96,
  "tasks": [
    {
      "id": "tm406erky",
      "name": "bundle-recon",          // from agentNameRegistry; may be absent
      "type": "general-purpose",
      "status": "running",
      "description": "Spelunk CC bundle",
      "label": "…",                    // TJ_(task) || description
      "startTime": 1752148800000,      // epoch ms
      "model": "claude-sonnet-5",      // resolved model id; absent until resolved
      "contextWindowSize": 200000,     // absent when model is absent
      "tokenCount": 24310,
      "tokenSamples": [],
      "cwd": "…"
    }
  ]
}
```

`contextWindowSize` and `model` require Claude Code >= 2.1.205.

### stdout shape

One JSON object per line, for rows we want to override:

```
{"id":"tm406erky","content":"\u001b[…m⤷ …"}
```

Omit a task's `id` to keep its default rendering. Emit `""` as `content` to hide the row.
**The content string must be built with `jq -c`**, which escapes `ESC` as `\u001b`; a
hand-rolled JSON string would embed a raw control character and fail the schema check
silently.

## Design

A new standalone script `bin/cs-subagent-statusline`, registered as `subagentStatusLine`.

### Row format

```
⤷ ✦ Sonnet 5   bundle-recon · Spelunk CC bundle        ◔ ctx 12%  ◷ 2m14s
⤷ ✦ Opus 4.8   code-reviewer · Review the diff         ◔ ctx 61%  ◷ 0m18s
⤷ ✦ Fable 5    docs-finalizer · Finalize docs          ◔ ctx 84%  ◷ 0m03s
```

Left to right: a descent glyph marking the row as spawned work; the model chip in cs's
periwinkle (matching the main bar's model segment); the agent's name (falling back to `type`
when `name` is absent); the description; the agent's **own** context-window usage; elapsed
time since `startTime`.

The three columns the default row lacks — model, context, elapsed — are precisely what make a
subagent legible as a separate machine with its own budget.

### Colors

Reuse `bin/cs-statusline`'s existing helpers rather than re-deriving them:

- `_detect_level` — truecolor / 256 / basic / plain ladder, and `NO_COLOR` handling.
- `_sgr` — the palette, including `periwinkle`, `amber`, `surface`, and the dark-terminal
  white softening.
- `_thresh_color` — warn/crit escalation. Context thresholds reuse `CS_STATUSLINE_CTX_WARN`
  (50) and `CS_STATUSLINE_CTX_CRIT` (80), so the row's ctx and the bar's ctx escalate on the
  same rule.
- `_display_width` — for truncating the description to the available `columns`.

Unlike the main bar, rows are **not** self-backgrounded pills: they sit on the terminal
background inside Claude Code's own panel. Only foreground colors are used (`_sgr 38 …`). No
gradient, no surface fill.

This means `_thresh_color`'s default healthy color — `surface`, a tint derived from the
terminal background — is wrong here: as a foreground it would be near-invisible against the
background it was derived from. The rows pass an explicit healthy color as the fourth
argument instead.

### Code sharing: library mode

`bin/cs-statusline` must remain a single self-contained file — `install.sh` fetches it from
one URL (`CS_STATUSLINE_URL`) on remote installs. It cannot `source` a shared `lib/` file at
runtime.

The repo's existing answer to this is hand-synced duplication (`lib/40-state.sh:37`,
`lib/05-term.sh:126` both carry `SYNC WITH bin/cs-statusline` comments). A third copy of the
palette would rot.

Instead, `bin/cs-statusline` gains a library-mode guard on its final line:

```bash
# was: main "$@"
[ "${CS_STATUSLINE_LIB:-}" = "1" ] || main "$@"
```

and `bin/cs-subagent-statusline` opens with:

```bash
CS_STATUSLINE_LIB=1 . "$(dirname "$0")/cs-statusline"
```

`return` is not used, because `return` outside a function is an error in an *executed*
script; short-circuiting the `main` call is equivalent and safe in both modes.

Consequences, accepted:

- `cs-subagent-statusline` requires `cs-statusline` beside it. `install.sh` already installs
  both into `$INSTALL_DIR`.
- Sourcing inherits `set -uo pipefail` (no `errexit`), `SESSIONS_ROOT`, `SL_THEME`, the
  `ICON_*` constants, and `LEVEL="basic"`. The subagent script must be nounset-safe and must
  call `_detect_level` itself.
- `cs-statusline` defines `main`. The subagent script therefore defines its entry point
  *after* the source, under a different name, to avoid clobbering.

### Model id → display name

The row payload carries a resolved **model id** (`claude-sonnet-5`), not the display name the
main bar receives (`model.display_name`). A small table maps the ids we know:

| id | display |
|---|---|
| `claude-fable-5` | Fable 5 |
| `claude-opus-4-8` | Opus 4.8 |
| `claude-sonnet-5` | Sonnet 5 |
| `claude-haiku-4-5-20251001` | Haiku 4.5 |

Matching is on a prefix, so `claude-opus-4-8[1m]` and dated suffixes resolve. An unrecognised
id renders verbatim (truncated to fit) rather than being dropped — a new model must degrade to
"ugly but honest", never to "invisible".

### Null-when-nothing

Every field is optional and every element is omitted when its source is missing:

- no `model` → no model chip, and no ctx (there is no `contextWindowSize` either)
- `contextWindowSize` present but `0` → no ctx (guard against divide-by-zero)
- no `startTime` → no elapsed
- no `name` → fall back to `type`; no `type` either → omit the name field
- `columns` absent or too small → emit nothing for that row, keeping Claude Code's default

### Width budget

`columns` is the usable row width. Fixed-cost fields (glyph, model chip, ctx, elapsed) are
measured first with `_display_width`; the description receives the remainder and is truncated
with a single-character ellipsis. If the remainder is under a floor (8 columns), the
description is dropped before the ctx gauge is — a runaway agent's ctx% is worth more than the
tail of its description.

### Failure posture

Fail-open, matching `bin/cs-statusline`:

- missing `jq`, unparseable stdin, empty `tasks` → print nothing, `exit 0`
- any per-row error → skip that row (default rendering is preserved), continue with the rest
- `CS_SUBAGENT_STATUSLINE_DISABLE=1` → print nothing, `exit 0`

Printing nothing is always safe: an omitted `id` means "keep the default row". A broken row
renderer must never break the agent panel.

Wall-clock: the runner kills us at 5 s. The hot path is one `jq` pass over stdin and one `jq -c`
per row; no forks per field, no git, no network, no file reads.

## Testing

New `tests/test_subagent_statusline.sh`, following the existing `tests/test_statusline.sh`
conventions. **The harness disables `errexit` inside `run_test`, so every assertion must end
with `|| return 1`.**

Cases, in TDD order — each written failing first:

1. Empty `tasks` array → no output, exit 0.
2. One running task with model + tokenCount + contextWindowSize → exactly one JSON line whose
   `.id` matches and whose `.content` (under `NO_COLOR=1`) contains the name, the description,
   `ctx 12%`, and an elapsed field.
3. Task with no `model` → content has no model chip and no `ctx`.
4. Task with `contextWindowSize: 0` → no `ctx`, no crash.
5. Unrecognised model id → id rendered verbatim, not dropped.
6. `name` absent → `type` is used.
7. Colors on (`COLORTERM=truecolor`) → `.content` round-trips through `jq` and the raw stdout
   line contains `\u001b`, never a literal `ESC` byte.
8. ctx at 55 → amber; at 85 → red. (Assert on the SGR sequence, against the same
   `CS_STATUSLINE_CTX_WARN/CRIT` the bar uses.)
9. Narrow `columns` → description truncated, ctx retained; output still one valid JSON line.
10. Malformed stdin → no output, exit 0.
11. `CS_SUBAGENT_STATUSLINE_DISABLE=1` → no output, exit 0.
12. Library mode: `CS_STATUSLINE_LIB=1 . bin/cs-statusline` defines `_sgr` and prints nothing.
13. `bin/cs-statusline` still renders normally when executed (guard regression).

Assertions on `.content` go through `jq -r`, so a test failure distinguishes "wrong content"
from "invalid JSON".

## Integration surface

| File | Change |
|---|---|
| `bin/cs-statusline` | final line becomes the library-mode guard |
| `bin/cs-subagent-statusline` | new |
| `install.sh` | copy + chmod the new binary; add `CS_SUBAGENT_STATUSLINE_URL` for remote installs; install parity count rises |
| `lib/70-statusline.sh` | `cs -statusline enable` registers `subagentStatusLine` alongside `statusLine`; `disable` strips it only when it points at `cs-subagent-statusline`; both paths print the **restart required** notice |
| `lib/85-adopt-uninstall.sh` | remove the binary and the registration |
| `lib/60-doctor.sh` | check registration + executable, informational when absent |
| `docs/statusline.md` | new "Subagent rows" section |
| `README.md` | feature mention |
| `tests/test_subagent_statusline.sh` | new |
| `tests/test_install.sh` | parity count |

`build.sh` is untouched: `bin/cs-statusline` and `bin/cs-subagent-statusline` are both
hand-maintained standalone scripts, only `bin/cs` is assembled from `lib/`.

## Constraints

- macOS stock `/bin/bash` 3.2 and BSD userland. No `local -A`, no `printf '%(…)T'`, no
  `source <()`, no GNU-only `sed`/`awk`/`stat`/`timeout` flags. CI runs the whole suite
  under 3.2.
- No emojis. Unicode Geometric Shapes and dingbats only, matching the existing `ICON_*` set.
- Single-dash cs subcommands (`cs -statusline`), double-dash + short for POSIX modifiers.

## Explicitly out of scope

- **A "you are here" marker.** `viewingAgentTaskId` is not in the payload. Not buildable.
- **An `agents` segment on the main bar.** Requires a writer that survives the zero-transition;
  the row script cannot be that writer (finding 4). Revisit only with a hook-based writer.
- The pre-existing `_read_session_color` / truecolor duplication between `bin/cs` and
  `bin/cs-statusline`. Untouched.
