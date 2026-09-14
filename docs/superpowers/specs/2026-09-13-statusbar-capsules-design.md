# Status bar capsules — design

Date: 2026-09-13
Status: draft for Alex's review
Decision trail: Alex asked for a status bar that is "sexier, Dribbble-worthy, Apple-like";
an 8-seat council answered (`.claude/council-cache/council-1789310967.md`, synthesis at the
end); every proposal was rendered as a terminal row (`.cs/research/statusbar-variants.sh`);
Alex picked Antigravity 1 and 2, Codex 2 and 3, Grok-cli B; two rounds of concrete
either/or questions settled the forks; a five-state mock of the result
(`bash .cs/research/statusbar-variants.sh --mock [--dark]`) was shown before this was
written. Every claim below that names a line number was checked against the source at
`0023827`.

## Context and goal

`bin/cs-statusline` prints one line of squared, abutting colour blocks: a coral logo badge,
the session name on its `/color`, an optional notes and mail count, the tmux pane, the
branch on slate, the model on periwinkle, then the gauges (ctx, 5h, wk, fable, optional
cost) on a background-derived surface, and a gradient tail fading into the terminal. Every
council seat gave the same diagnosis: too many chromatic fills so nothing is the accent,
identity loud at rest, healthy gauges wearing alert mass, `%33` reading as a percentage,
one-cell gaps the worst spacing.

The goal is a bar that answers two questions at a glance — where am I, and what needs
attention — with colour used only for the second.

## Decisions

Alex's calls, 2026-09-13, in order:

1. **Codex 2 geometry.** One rounded identity capsule holding mark, session, branch and
   model on a single neutral surface; the Claude mark is the only colour at rest.
2. **Codex 3 gating.** Rate limits are hidden until hot. When one crosses its warn
   threshold it appears as its own capsule; the tightest first, at most two.
3. **ctx is always shown**, as a neutral capsule after the identity capsule; amber ink on
   the number from warn, the capsule inverting to red at crit.
4. **Powerline caps.** Alex confirmed U+E0B6/U+E0B4 render as half-circles in his
   terminal. That is his eye, not a probe: cs cannot detect a font, so a switch exists.
5. **Session name in neutral ink.** The session's `claude_session_color` stays on the
   terminal tab and in claude's own accent; it leaves the bar.
6. **Keep the attention pulse** on the mark, same two corals, same `refreshInterval: 1`.
7. **Drop the tail fade** (gradient, wash and dots). A rounded cap followed by a fade
   contradicts the capsule shape; the empty tail is the terminal's own background.
8. **Honour `pane` and `fable` when a user names them** in `CS_STATUSLINE_SEGMENTS`,
   though both leave the default order. Nothing a user wrote stops working.
9. **`_render` is rewritten** around capsule groups (approach A). The hairline and
   logo-boundary machinery has no consumer afterwards and is removed.
10. **The 17 tail tests are deleted** and one case asserts the line ends at the last cap.

## Layout

One physical line. Capsules sit on the terminal's own background, one empty cell apart.
Inside the identity capsule, items join with `  ·  ` (two spaces, middle dot, two spaces)
in secondary ink.

```
 ✳ claude-sessions  ▤ 2  ✉ 1  ·  feat/ctx-three-bands +2!1  ·  Fable 5.1 medium   ◔ ctx 33% 
```

| State | Bar |
|---|---|
| Rest (ctx < 40, every limit < 70) | identity capsule, ctx capsule |
| ctx warn (40–64) | ctx number in amber ink, capsule surface unchanged |
| ctx crit (≥ 65) | ctx capsule inverts: crit fill, crit ink, bold |
| One limit ≥ 70 | that limit's capsule appears after ctx, number in amber ink, countdown per the existing rules |
| One limit ≥ 90 | that capsule inverts to crit |
| Two or more limits ≥ 70 | the two highest percentages, highest first; the rest stay hidden |

Rounded caps: the left cap `` (U+E0B6) and right cap `` (U+E0B4) are drawn with
foreground equal to the capsule fill and background left at the terminal default, so the
cap reads as the capsule's rounded end. `CS_STATUSLINE_CAPS=0` replaces both caps with one
space of capsule fill, giving square chips with the same gaps; that is the path for a font
without the glyphs.

## Segments

`CS_STATUSLINE_SEGMENTS` keeps its grammar: a comma list, unknown names ignored. The
default becomes `logo,session,notes,mail,git,model,ctx,limits`. Each name maps to a group:

| Name | Group | Rest | Hot | Hidden when |
|---|---|---|---|---|
| `logo` | identity | `✳` in brand coral, bold; pulses brand/brandshade by epoch parity while `.cs/local/attention` exists | — | plain mode (no colour) |
| `session` | identity | name, bold, in its `claude_session_color` when the session has one, else primary ink | — | never |
| `notes` | identity | `▤ N`, amber ink, regular, directly after the session | — | queue empty or absent |
| `mail` | identity | `✉ N`, amber ink, regular, after notes | — | nothing unread |
| `pane` | identity | `◫ 33` (the `%` dropped), secondary ink; only when named | — | not named, or outside a real tmux |
| `git` | identity | branch with the existing arrows and `+N!N` marks, primary ink, bold | — | no `.git` |
| `model` | identity | display name in primary ink bold, effort in secondary ink regular | — | no model on stdin |
| `ctx` | ctx | `◔ ctx N%`, secondary ink | amber ink on the number at 40; crit inversion at 65 (`CS_STATUSLINE_CTX_WARN`/`_CRIT` as today) | no `context_window` on stdin |
| `limits` | limits | hidden | one capsule per hot window: `5h N% · 2h14m`, `wk N% · 5d16h`, `fable N% · 18h`; amber ink at 70, crit inversion at 90 | every window below 70 |
| `fable` | limits | accepted as a name; adds nothing `limits` does not already cover | — | — |
| `cost` | cost | `$N.NN`, secondary ink, its own capsule after limits; only when named | — | not named, or no cost on stdin |

Identity items render in the order named. The identity capsule is omitted entirely when
none of its items produce text. The malformed-stdin fallback (`_fallback`, a bare
directory name and exit 0) is unchanged.

The limits group folds the three windows into one rule. The Fable window is model-scoped
and lives only in the usage cache (see `docs/statusline.md`, "Fable usage"); it joins the
candidate list only on a Fable session, and its refresh kick keeps its existing gate: the
cache is read and the refresher detached whether or not the capsule ends up shown, so a
hidden fable window is still being polled at its 600-second floor. Countdown rules are
unchanged: 5h at 50 and up (always true once shown), wk and fable at 80 and up.

The two files the render writes, `.cs/local/context-pct` and `.cs/local/limits`, are
produced in `_parse_stdin` (bin/cs-statusline:352, :372) before any segment runs and stay
untouched. Hiding a capsule never hides a heartbeat.

## Colour

| Token | Role | Truecolor | 256 | Basic |
|---|---|---|---|---|
| `surface` | every capsule fill | as today: `CS_TERM_BG_RGB` shaded 10% away from itself (`_bg_shade`), taupe fallback when unmeasured | 254/237 | 90 |
| `ink` | primary text | as today's surface text: a 35% shade of the surface on a light surface, `white` on a dark one | 236/255 | 97 |
| `ink2` | secondary text, dots, effort, gauge labels | a 55% shade of the surface when the surface is light (luminance ≥ 1530000), else each channel lifted by 55% toward white — `227;221;204` → `124;121;112`, the light taupe → `197;194;189`, the dark taupe → `203;199;195` | 241/250 | 37/97 |
| `brand` | the mark | unchanged `217;119;87` | 173 | 33 |
| `brandshade` | the pulse's dim phase | unchanged `184;101;74` | 167 | 33 |
| `periwinkle` | the agent rows' model name | light: `76;29;149`; dark: `196;181;253` | 55/147 | 35/95 |
| `amberink` | hot numbers, notes and mail counts | light: `180;83;9`; dark: `253;230;138` | 130/221 | 33 |
| `crit` | inverted capsule fill | light: `215;0;21`; dark: `255;69;58` | 160/203 | 31 |
| `critink` | inverted capsule text | `255;255;255` on both themes | 231 | 97 |
| `critshade` | the crit pulse's dim phase | `255;205;200` | 224 | 97 |

On a cream terminal (`253;246;227`) the derived surface is `227;221;204`, within a few
shades of the council's `#ECE9E0` reference, so the surface stays derived and the hex
values above are the fallback and the documentation reference, not fixed paints.

`amber` today is a fill (`255;183;77`) chosen for black text on it; as ink on cream it fails
contrast, hence a separate `amberink`. The session palette (`red`, `blue`, … `orange`) stays
in `_sgr` untouched: it is Claude Code's shared eight-colour tab palette, KEEP IN SYNC with
`_session_color_rgb` in `bin/cs`, and no longer drawn by the bar. `crit` is its own token so
the gauge's red never depends on that palette's `red`.

Removed tokens: `hairline`, `chiptext` (the mark's bright phase is `brand`), `slate`, `black`,
`amber` as a fill. `periwinkle` stays for the agent rows' model name.

The secondary ink follows the surface for the same reason the primary ink does: the three
final reviewers found the first fixed values (`119;117;110`, and `244`/`90` at 256/basic)
equal to the fill on every surface cs cannot measure, which is where tmux teammate panes
render.
`bin/cs-subagent-statusline` sources this file as a library (its line 8) and paints with
`rowname`, `rowmeta`, `amber`, `red` through `_paint` → `_sgr`; those four names stay, with
`amber` and `red` resolving to `amberink` and `crit` so an agent row's hot ctx keeps the same
two colours as the bar. Its output is otherwise unchanged.

## Render model

`_add TEXT GROUP [INK] [WEIGHT]` replaces `_add TEXT BG [BOLD]`. Four parallel arrays:
text, group (`identity`, `ctx`, `limits`, `cost`), ink token (default `ink2`), weight
(`bold` or empty). A fifth, per-group, records the fill: `surface` unless a segment sets
`crit`, which inverts the whole capsule (every item in it takes `critink`, bold).

`_render`:

1. Plain mode: items joined with ` > ` in group order, no caps, no escapes — today's
   plain contract.
2. Colour: for each group in first-seen order, emit the left cap (or a fill space), then
   the items — identity items joined by `  ·  ` in `ink2`, other groups single-item —
   each with its own fg SGR and explicit intensity (SGR 1 or 22, since bold is stateful),
   then the right cap. Two default-background spaces after identity, one after every other
   group, none after the last.
3. No width accounting, no `COLUMNS`, no tail.

The logo pulse keeps its mechanism: the mark's ink alternates `brand`/`brandshade` by
`_sl_now` parity when the attention marker exists; `CS_STATUSLINE_NOW` still pins the clock
for tests.

`_display_width`, `_build_gradient`, `_build_wash`, `_build_dots`, `_lerp_channel` and
the logo-boundary branch lose their only caller and are removed; `_bg_shade`,
`_luminance` and `_parse_rgb_triplet` stay for the surface.

## Consumers, by path

- `bin/cs-statusline` — the change.
- `bin/cs-subagent-statusline` — sources the library; token names it uses are kept (above).
  No edit expected; its suite proves it.
- `lib/70-statusline.sh` — registration with `refreshInterval: 1`; unchanged.
- `tests/test_statusline.sh` (199 cases) — the 17 tail cases (every `run_test` whose name
  contains `gradient`, `wash`, `dots`, `dotted`, `tail` or `fade`, plus
  `test_columns_fills_the_bar_without_a_measured_bg`) are deleted per Decision 10; `test_logo_boundary_gets_thin_darker_coral_hairline`,
  `test_segment_after_logo_divider_drops_redundant_leading_pad`,
  `test_logo_divider_survives_orange_session_color_collision` go with the hairline; the
  four `test_pane_segment_*` cases become "hidden by default" plus "shown when named";
  `48;2;` pins on session, git and model become asserts that the item carries no fill of
  its own and the capsule carries `surface`; the plain-mode ` > ` pins survive except where
  `pane` or the fable name appears. New cases: caps present and equal to the
  fill; `CS_STATUSLINE_CAPS=0` gives fill spaces and no U+E0B6; limits hidden at 69 and
  shown at 70; three hot windows show the top two in descending order; crit inverts the
  whole capsule and only that capsule; the line ends at the last cap with no gradient,
  wash or dots regardless of `COLUMNS`; `fable` named alone renders the fable window;
  `pane` named renders `◫ 33` inside identity.
- `tests/test_install.sh`, `test_doctor.sh`, `test_run_all.sh`, `test_queue.sh`,
  `test_rotation.sh`, `test_theme.sh` — reference the binary; their pins are on
  registration, files written and plain text, and must pass unchanged.
- `docs/statusline.md` — the Segments table, the Colors section and the layout example
  are rewritten to this document; the "Fable usage" section is unchanged.
- `docs/configuration.md:45-60` — the `CS_TERM_BG_RGB` comment stops describing a fade
  and describes the surface; `CS_STATUSLINE_SEGMENTS` default updated;
  `CS_STATUSLINE_CAPS` added.
- `README.md:75` — the status-line paragraph.
- `CHANGELOG.md` — Unreleased: Changed (the bar, the default segment order, `pane` and
  `fable` still honoured by name), Added (`CS_STATUSLINE_CAPS`), Removed (the tail fade).

## Out of scope

- The agent-panel rows keep their layout; only their two hot colours move with the bar.
- The session colour on the terminal tab and in claude's `/color`: unchanged.
- A doctor check for the Powerline glyphs: cs cannot see the font; the switch is the answer.
- The iterm sidebar's `statusline-bridge.sh`, which is what Alex's live bar runs today; the
  redesign shows once that bridge hands off, and the cold-open check must use a session
  where it is not registered.

## Commits

1. Capsule renderer: the new `_add`/`_render`, identity capsule, ctx capsule, colour
   tokens, caps switch, tail removal, the tests those touch.
2. Limits gating: the merged `limits` group, fable folded in, `pane` and `fable` by name,
   default order, their tests.
3. Docs, README, CHANGELOG, and the `docs/statusline.md` rewrite.
