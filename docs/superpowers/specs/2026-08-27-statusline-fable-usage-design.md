# Fable usage segment — design

**Status:** approved by Alex 2026-08-27
**Implements:** "when using fable as a model we need to have an extra statusline
section only for fable usage/reset time"

## Problem

`cs-statusline` renders `5h` and `wk` from the two rate-limit windows Claude Code
puts on stdin. Those are the plan-wide unified windows. Fable draws on a
*separate*, model-scoped weekly bucket, so on Fable the bar shows two numbers
that do not describe the limit actually about to bite.

## Why the data cannot come from stdin

Verified against the installed Claude Code bundle (2.1.247). The statusline
payload builder picks exactly two windows and emits them only when one exists:

```js
O = { ...P.five_hour && {five_hour:{used_percentage: P.five_hour.utilization*100, resets_at: …}},
      ...P.seven_day && {seven_day:{…}} }
…(O.five_hour || O.seven_day) && { rate_limits: O }
```

The per-model windows (`rate_limits.model_scoped[]`, `{display_name, utilization,
resets_at}`) exist in-process but are projected only into the control-protocol
`get_usage` response — the SDK / remote thin-client channel, not a hook.

Other local sources were checked and ruled out: session transcript JSONL carries
no rate-limit records, and nothing under `~/.claude` (including the 424 KB
`~/.claude.json`) caches a utilization figure. The only `seven_day` string on
disk is a GrowthBook promo-notice flag.

## Source of truth

`GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code
itself polls. Proven end to end from a cs-shaped call on 2026-08-27:

```
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

```json
{ "five_hour": {"utilization": 31.0}, "seven_day": {"utilization": 49.0},
  "limits": [ {"scope":{…},              "percent":31, "resets_at":"2026-08-27T10:39:59.685643+00:00"},
              {"scope":{…},              "percent":49, "resets_at":"2026-08-29T03:59:59.685669+00:00"},
              {"scope":{"model":{"display_name":"Fable"}},
                                         "percent":86, "resets_at":"2026-08-29T03:59:59.686034+00:00"} ] }
```

The Fable bucket is the `limits[]` entry whose `scope.model.display_name` is
non-null. The unified windows appear in the same array with a null model scope,
which is why the filter keys on the model display name rather than on position.

**`percent` is already 0–100 on the wire.** The `*100` in the bundle applies to
an internal normalized store, not to this response. Do not scale it.

`resets_at` is an ISO 8601 string with fractional seconds and a `+00:00` offset —
not the epoch integer the stdin schema uses. `_fmt_rest` takes epoch, so the
value is converted at parse time.

The access token is Claude Code's own, read from the macOS Keychain:

```
/usr/bin/security find-generic-password -a "$USER" -s "Claude Code-credentials" -w
```

which yields JSON whose `.claudeAiOauth.accessToken` is the bearer. cs **reads**
that credential and never refreshes or writes it — Claude Code owns it. An
expired token therefore surfaces as a 401, which cs treats as a transient
failure and backs off; Claude Code will rotate it on its own.

## Rate-limit budget (the constraint that shapes the cadence)

The endpoint enforces roughly **28–30 requests per identity per rolling
60-minute window**, and under one of two observed 429 regimes that identity is
the **account/org**, not the token. Capacity returns only as old requests age
out, so a burst saturates for a full hour and pausing does not restore headroom
early. (Measured and documented at length by the claude-swap author in
`poll_policy.py`; corroborated by that project's `EDGE_BACKOFF_S`/`MIN_INTERVAL_S`
constants of 300/180 s.)

Alex runs claude-swap alongside cs, so cs is a *second* consumer of one shared
budget. Three consequences are binding on this design:

1. **One poll per machine, not per session.** The cache is machine-global, under
   `$SESSIONS_ROOT/.usage/`, alongside the existing `.spawn` and `.voice`
   machine-global dirs. Every cs session on the host reads the same file.
2. **A floor of 300 s between polls**, so cs contributes at most ~12 requests an
   hour and leaves the rest of the budget to claude-swap and to Claude Code.
3. **Polling happens only while the active model is Fable.** The trigger lives
   inside the segment, which is itself gated on the model, so a session on any
   other model costs nothing.

On a 429, cs waits `Retry-After` plus a 60 s margin, floored at 600 s. A 429
does not reliably clear at its stated horizon, which is why the margin exists.

## Behaviour

A third limits chip, rendered **only** when the active model is Fable:

```
✧ fable 86% · 1d20h
```

- **Gate:** stdin `.model.id` begins `claude-fable`. The id is the stable
  predicate; `display_name` is a server-supplied label. The prefix match covers
  context-window suffixes such as `claude-fable-5[1m]`.
- **Colour:** the shared threshold ladder — grey surface, amber at 70 %, red at
  90 % — escalating on its own value, exactly like the `5h` and `wk` blocks.
- **Countdown:** appended once usage is tight, gated at **80 %**, matching the
  `wk` block. Fable's is a weekly window, so time-to-reset only matters as it
  nears exhaustion. Format is `_fmt_rest`'s existing compact form (`45m`,
  `2h14m`, `1d20h`).
- **Null-when-nothing:** no cache, no Fable entry, an unreadable or stale record,
  a different account, or no `jq`/`curl` all mean the chip and its separator
  simply do not render. This never degrades to a wrong number.

## Freshness and account identity

The cache records `org` — the active account's `oauthAccount.organizationUuid`
from `~/.claude.json` — beside the reading. The render compares it against the
live value and blanks the chip on a mismatch, so swapping accounts cannot leave
the previous account's percentage on screen for the rest of a poll interval.
That check matters because Alex swaps between three accounts precisely when one
is near a limit, which is when a wrong number is most misleading.

The render also blanks a reading older than 1800 s. The countdown is always
recomputed from `resets_at` at render time, so it never drifts even when the
percentage beside it is a few minutes old.

## Cost of the render path

`docs/statusline.md` currently states the render path has "no network access,
and no caching". This design changes that, deliberately and narrowly:

- The **render** still performs no network I/O. On a Fable session it adds one
  `jq` fork that reads the cache and `~/.claude.json` together (~15 ms measured);
  on any other model it adds nothing at all.
- The **refresh** is a detached, locked, interval-gated re-invocation of
  `cs-statusline --refresh-usage`. Re-invoking the same script avoids installing
  a second binary and the five-site registration that would carry.

A `mkdir` lock serialises refreshers across concurrent sessions; a lock older
than 120 s is treated as abandoned and reclaimed.

## Explicitly out of scope

- `extra_usage` / pay-as-you-go credit spend. A separate axis from the weekly
  window, and not what was asked for.
- A general per-model framework. Only the Fable bucket is read and rendered.
- Any dependency on claude-swap. Alex ruled it out; cs fetches its own data.
