/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view in the cs TUI's look: the masthead, the selected row's card, the problem lines, the column header, a window of rows fitted to the body and the keys under it.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement, TextProps } from 'claude-code'
import { shownOf, type Action, type Line, type Pending, type Row, type RowId, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, the session name, the room.
export type PanelView = {
  lines: readonly Line[] | undefined
  // The selected row; one no longer listed falls back to the first row.
  selected: RowId | undefined
  problems: readonly string[]
  session: string | undefined
  // Pane props: bodyColumns, scroll.bodyRows, isFocused.
  columns: number
  bodyRows: number
  hasKeys: boolean
}

export type Handlers = {
  // The row pressed offers no change: select it.
  select: (id: RowId) => void
  // A strip key, or a row's press (change), for that row.
  act: (action: Action, id: RowId) => void
}

// The strip's keys, one per Action, in strip order. Three fixed letters, so no
// two Buttons ever share a hotkey (two clash, later wins), however many rows.
// `short` is the label a narrow strip draws.
export const KEYS: Record<Action, { hotkey: string; verb: string; short: string }> = {
  change: { hotkey: 'c', verb: 'change', short: 'change' },
  unset: { hotkey: 'u', verb: 'default', short: 'default' },
  session: { hotkey: 'p', verb: 'this session only', short: 'session' },
}

// Every word the pane draws itself.
export const WORDS = {
  reading: 'asking cs for its settings…',
  on: 'on',
  off: 'off',
  none: '-',
  from: { shell: 'shell', launch: 'launch', session: 'session', machine: 'machine', default: 'default' } satisfies Record<Source, string>,
  mod: 'mod',
  locked: 'locked',
  modsGroup: 'Mods',
  pending: { asking: 'asking', writing: 'writing' } satisfies Record<Pending, string>,
  above: (n: number) => `+${n} above`,
  below: (n: number) => `+${n} below`,
  close: 'Esc: close',
  takeKeys: 'ctrl+x tab: keys',
  pinned: (key: string, value: string) => `${key}=${value} in your environment wins; unset it there to change it here`,
  shellOnly: (key: string) => `change it from a shell: cs -config set ${key} 1 (on, it unloads every mod at the next launch, this panel too)`,
  reloads: (plugin: string) => `changing it reloads ${plugin}${plugin === 'cs' ? ' (an armed rotation countdown starts over)' : ''}`,
  managed: 'a managed setting owns it',
  brand: 'claude-sessions',
  title: 'settings',
  settings: (n: number) => `${n} settings`, changed: (n: number) => `${n} changed`,
  heads: { name: 'setting', value: 'value', from: 'from', when: 'when' },
  // The bars, a toggle's dots, a gauge's cells, the rules, the dot, the card's edge.
  marks: { selected: '▌', on: '●', off: '○', full: '▰', empty: '▱', rule: '─', hero: '━', dot: '·', edge: '▍' },
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// tui/src/theme.rs's palettes and install.sh.in's wordmark (lib/05-term.sh's when light).
type Rgb = readonly [number, number, number]
const rgb = (channels: readonly number[]) => `rgb(${channels.join(',')})`
type Palette = Record<'ink' | 'mut' | 'faint' | 'soft' | 'teal' | 'green' | 'amber', string> & { hero: readonly Rgb[]; rail: readonly string[]; wordmark: readonly string[] }

// The TUI's ramp: cell `i` of `n` along the stops, each channel truncated.
function ramp(stops: readonly Rgb[], n: number, i: number): string {
  const at = n <= 1 ? 0 : i / (n - 1) * (stops.length - 1), a = Math.floor(at)
  const from = stops[a], to = stops[Math.min(a + 1, stops.length - 1)]
  if (from === undefined || to === undefined) throw new Error(`ramp: cell ${i} of ${n} falls outside ${stops.length} stops`)
  return rgb(([0, 1, 2] as const).map(c => Math.trunc(from[c] + (at - a) * (to[c] - from[c]))))
}

const PALETTES = {
  dark: { ink: rgb([245, 230, 211]), mut: rgb([161, 136, 127]), faint: rgb([120, 104, 96]), soft: rgb([56, 50, 46]), teal: rgb([45, 212, 191]),
    green: rgb([139, 195, 74]), amber: rgb([246, 154, 0]), hero: [[221, 80, 20], [237, 128, 0], [246, 154, 0], [214, 162, 30]], rail: [[221, 80, 20], [246, 154, 0], [250, 180, 60]].map(rgb),
    wordmark: [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16], [245, 142, 15], [246, 151, 14],
      [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]].map(rgb) },
  light: { ink: rgb([43, 33, 24]), mut: rgb([122, 106, 88]), faint: rgb([168, 151, 130]), soft: rgb([226, 213, 196]), teal: rgb([15, 118, 110]),
    green: rgb([92, 140, 84]), amber: rgb([242, 167, 53]), hero: [[143, 50, 28], [216, 90, 36], [242, 167, 53], [214, 162, 30]], rail: [[193, 58, 29], [228, 91, 34], [232, 167, 46]].map(rgb),
    wordmark: Array.from(WORDS.brand, (_, i) => ramp([[166, 86, 60], [156, 118, 56]], WORDS.brand.length, i)) },
} satisfies Record<'dark' | 'light', Palette>

function paletteOf(lines: readonly Line[]): Palette {
  return lines.some(l => l.kind === 'row' && l.row.kind === 'setting' && l.row.setting.key === 'CS_TERM_THEME' && l.row.setting.value === 'light') ? PALETTES.light : PALETTES.dark
}

// A run of one style; a line is a row of runs as wide as their texts.
type Run = { text: string } & Pick<TextProps, 'color' | 'weight'>

// The columns right of the name, dropped from the end by a narrow body.
type Column = { head: string; cells: number; runs: (line: RowLine, cells: number, p: Palette) => Run[] }
const NAME_MIN = 8
const NAME_MOST = 26
const GAP = 2
const MARK_CELLS = 2
const DOT = `  ${WORDS.marks.dot}  `
const KEY_GAP = 3
// A plain Button draws `<hotkey>: <label>`.
const KEY_CELLS = 3
// The selected row, a row and a count either side: the strip's empty line keeps them.
const WINDOW_FULL = 5
const GAUGE_CELLS = 10
const VALUE_CELLS = { wide: GAUGE_CELLS + 4, narrow: 11 }
// cs's `when` for a change that applies at once: the when cell leaves it out.
const AT_ONCE = 'now'
const VALUE: Column = { head: WORDS.heads.value, cells: VALUE_CELLS.wide, runs: (l, cells, p) => fitRuns(valueRuns(l, cells, p), cells) }
// A default row leaves from and when empty, a mod row its when.
const REST: readonly Column[] = [
  { head: WORDS.heads.from, cells: 7, runs: (l, cells, p) => l.row.kind === 'mod'
    ? [{ text: fit(l.row.mod.isLocked ? WORDS.locked : WORDS.mod, cells), color: p.mut }]
    : l.row.setting.source === 'default' ? [{ text: fit('', cells) }]
      : [{ text: fit(WORDS.from[l.row.setting.source], cells), color: p[SOURCE_INK[l.row.setting.source]] }] },
  { head: WORDS.heads.when, cells: 10, runs: (l, cells, p) => l.row.kind === 'setting' && l.row.setting.source !== 'default' && l.row.setting.when !== AT_ONCE
    ? [{ text: fit(l.row.setting.when, cells), color: p.mut }] : [{ text: fit('', cells) }] },
]

// A source's colour, the shell's amber as it overrides both files.
const SOURCE_INK: Record<Source, 'teal' | 'green' | 'amber' | 'faint' | 'mut'> = { session: 'teal', machine: 'green', shell: 'amber', launch: 'faint', default: 'mut' }
const CHANGED: ReadonlySet<Source> = new Set(['session', 'machine', 'shell'])

const PERCENT_KEYS: ReadonlySet<string> = new Set(['CS_STATUSLINE_CTX_WARN', 'CS_STATUSLINE_CTX_CRIT', 'CS_CTX_WARN_CTX', 'CS_ROTATE_NUDGE_CTX',
  'CS_QUEUE_MAX_CTX', 'CS_QUEUE_MAX_5H', 'CS_ROTATE_FORCE_CTX'])

// On (true), off (false), a word the shell pins a flag to, the value or the default's name.
function valueOf(row: Row): boolean | string {
  if (row.kind === 'mod') return typeof row.mod.value === 'boolean' ? row.mod.value : shownOf(row.mod.value)
  const s = row.setting
  if (s.edit === 'flag') return s.value === undefined ? false : s.value === '1' ? true : s.value
  return s.value ?? s.fallback ?? WORDS.none
}

// A value unpadded: what the row waits on, `● on`, `○ off`, a percentage's gauge where
// `room` holds it beside the number, else the value; ink when set, muted at the default.
function valueRuns(l: RowLine, room: number, p: Palette): Run[] {
  if (l.pending !== undefined) return [{ text: WORDS.pending[l.pending], color: p.mut }]
  const value = valueOf(l.row)
  const isDefault = l.row.kind === 'setting' && l.row.setting.source === 'default'
  const tone = isDefault ? p.mut : p.ink
  if (value === true) return [{ text: WORDS.marks.on, color: p.green }, { text: ` ${WORDS.on}`, color: tone }]
  if (value === false) return [{ text: `${WORDS.marks.off} ${WORDS.off}`, color: p.mut }]
  const isPercent = l.row.kind === 'setting' && PERCENT_KEYS.has(l.row.setting.key) && /^\d{1,3}$/.test(value) && Number(value) <= 100
  if (!isPercent || room < GAUGE_CELLS + 1 + value.length) return [{ text: value, color: tone }]
  const full = Math.round(Number(value) / 10)
  return [{ text: WORDS.marks.full.repeat(full), color: isDefault ? p.faint : p.amber }, { text: WORDS.marks.empty.repeat(GAUGE_CELLS - full), color: p.faint },
    { text: ` ${value}`, color: tone }].filter(run => run.text !== '')
}

function labelOf(row: Row): string {
  return row.kind === 'mod' ? row.mod.label : row.setting.label
}

// The longest prefix of `from` that leaves the name NAME_MIN cells.
function fitted(from: readonly Column[], columns: number): readonly Column[] {
  let kept = 0
  let used = MARK_CELLS
  for (const column of from) {
    if (columns - used - GAP - column.cells < NAME_MIN) break
    used += GAP + column.cells
    kept++
  }
  return from.slice(0, kept)
}

// The columns a body this wide draws, the wide value cell unless it drops one.
export function columnsFor(columns: number): readonly Column[] {
  const wide = fitted([VALUE, ...REST], columns)
  const narrow = fitted([{ ...VALUE, cells: VALUE_CELLS.narrow }, ...REST], columns)
  return wide.length >= narrow.length ? wide : narrow
}

// The name takes what the columns leave, up to NAME_MOST; the last column the rest.
function tableOf(columns: number): { nameCells: number; cols: readonly Column[] } {
  const cols = columnsFor(columns)
  const room = columns - MARK_CELLS - cols.reduce((sum, c) => sum + GAP + c.cells, 0)
  const nameCells = Math.max(1, Math.min(NAME_MOST, room))
  return { nameCells, cols: cols.map((c, i) => i === cols.length - 1 ? { ...c, cells: c.cells + Math.max(0, room - nameCells) } : c) }
}

// `text` cut to `cells` with `…`. Every text the panel fits is cs's ASCII
// words, a /config label or its own words, so one UTF-16 unit is one cell
// (its marks and `…` included).
function cut(text: string, cells: number): string {
  return text.length > cells ? `${text.slice(0, Math.max(0, cells - 1))}…` : text
}

function fit(text: string, cells: number): string {
  return cut(text, cells).padEnd(cells)
}

// `runs` cut to `cells` with `…` in the style of the run it cuts.
function clip(runs: readonly Run[], cells: number): Run[] {
  if (runs.reduce((sum, run) => sum + run.text.length, 0) <= cells) return [...runs]
  const kept: Run[] = []
  let left = cells - 1
  for (const run of runs) {
    if (run.text.length >= left) return [...kept, { ...run, text: `${run.text.slice(0, left)}…` }]
    kept.push(run)
    left -= run.text.length
  }
  throw new Error(`clip: ${runs.length} runs longer than ${cells} cells ended before the cut`)
}

// `runs` cut or padded to exactly `cells`, the last run taking the padding.
function fitRuns(runs: readonly Run[], cells: number): Run[] {
  const kept = clip(runs, cells), last = kept.at(-1), width = kept.reduce((sum, run) => sum + run.text.length, 0)
  return last === undefined || width >= cells ? kept : [...kept.slice(0, -1), { ...last, text: last.text.padEnd(last.text.length + cells - width) }]
}

// The rows a body of `room` lines (at least one) draws of `count`, and which
// of the `+N above` / `+N below` lines go with them, all inside `room`: every
// row when they fit, else a window that keeps the selected row `at` inside
// with one row of margin each side where the room allows, so the focus ring
// always has a drawn row to Tab onto and the window follows it. One line draws
// the selected row alone; two, it and the count of the rows below it, or of
// those above for the last row.
export function windowOf(count: number, at: number, room: number): { from: number; to: number; above: boolean; below: boolean } {
  if (count <= room) return { from: 0, to: count, above: false, below: false }
  if (room === 1) return { from: at, to: at + 1, above: false, below: false }
  if (room === 2) return { from: at, to: at + 1, above: at === count - 1, below: at < count - 1 }
  // Rows drawn beside one count line: the window touching either end.
  const edge = room - 1
  if (at <= edge - 2) return { from: 0, to: edge, above: false, below: true }
  if (at >= count - edge + 1) return { from: count - edge, to: count, above: true, below: false }
  const shown = room - 2
  const from = at - Math.floor((shown - 1) / 2)
  return { from, to: from + shown, above: true, below: true }
}

// The selected row's strip: all of it, no hint, the short labels, else stacked.
type Key = { action: Action; label: string }
export function stripFor(line: RowLine | undefined, columns: number, hasKeys: boolean): { keys: Key[]; hint: string | undefined; stacked: boolean } {
  const hint = hasKeys ? WORDS.close : WORDS.takeKeys
  const actions = line?.actions ?? []
  const full = actions.map(action => ({ action, label: KEYS[action].verb }))
  const short = actions.map(action => ({ action, label: KEYS[action].short }))
  const width = (keys: Key[], withHint: boolean) => [...keys.map(k => KEY_CELLS + k.label.length), ...(withHint ? [hint.length] : [])]
    .reduce((sum, cells, i) => sum + cells + (i === 0 ? 0 : KEY_GAP), 0)
  if (width(full, true) <= columns) return { keys: full, hint, stacked: false }
  if (width(full, false) <= columns) return { keys: full, hint: undefined, stacked: false }
  if (width(short, false) <= columns) return { keys: short, hint: undefined, stacked: false }
  return { keys: short, hint: undefined, stacked: true }
}

// `runs` in at most `most` lines of `columns` broken between words, then cut with `…`.
function wrapRuns(runs: readonly Run[], columns: number, most: number): Run[][] {
  type Cell = { char: string; run: number }
  const words: { space: Cell; word: Cell[] }[] = []
  let space: Cell = { char: ' ', run: 0 }, word: Cell[] = []
  const end = () => { if (word.length > 0) words.push({ space, word }); word = [] }
  runs.forEach((run, i) => { for (const char of run.text) if (char === ' ') { end(); space = { char, run: i } } else word.push({ char, run: i }) })
  end()
  const lines: Cell[][] = []
  let line: Cell[] = []
  for (const w of words) {
    if (line.length > 0 && line.length + 1 + w.word.length <= columns) { line.push(w.space, ...w.word); continue }
    if (line.length > 0) lines.push(line)
    let rest = w.word
    for (; rest.length > columns; rest = rest.slice(columns)) lines.push(rest.slice(0, columns))
    line = rest
  }
  if (line.length > 0) lines.push(line)
  const last = lines[most - 1]
  const kept = lines.length <= most || last === undefined ? lines
    : [...lines.slice(0, most - 1), [...last.slice(0, columns - 1), { char: '…', run: last.at(-1)?.run ?? 0 }]]
  return kept.map(cells => cells.reduce<{ run: number; text: string }[]>((out, cell) => {
    const prev = out.at(-1)
    if (prev?.run === cell.run) prev.text += cell.char
    else out.push({ run: cell.run, text: cell.char })
    return out
  }, []).map(({ run, text }) => ({ ...runs[run], text })))
}

// Why no key reaches the row, why cs skipped a value, when a change applies or what reloads.
function noteOf(row: Row): string {
  if (row.kind === 'mod') return row.mod.isLocked ? WORDS.managed : WORDS.reloads(row.mod.plugin)
  const s = row.setting
  if (s.source === 'shell') return WORDS.pinned(s.key, s.value ?? WORDS.none)
  if (s.edit === 'shell') return WORDS.shellOnly(s.key)
  return s.ignored ?? s.whenText
}

// The selected row's label and key, then its whole value, its source and its note.
function cardOf(l: RowLine, columns: number, most: number, p: Palette): Run[][] {
  const row = l.row
  const from: Run = row.kind === 'mod' ? { text: row.mod.isLocked ? WORDS.locked : WORDS.mod, color: p.mut }
    : { text: WORDS.from[row.setting.source], color: p[SOURCE_INK[row.setting.source]] }
  const dot: Run = { text: ` ${WORDS.marks.dot} `, color: p.mut }
  const room = Math.max(1, columns - MARK_CELLS)
  return [clip([{ text: labelOf(row), color: p.ink, weight: 'bold' }, { text: '  ' }, { text: row.kind === 'mod' ? row.mod.key : row.setting.key, color: p.mut }], room),
    ...wrapRuns([...valueRuns(l, Infinity, p), dot, from, dot, { text: noteOf(row), color: p.mut }], room, most)]
    .map(line => [{ text: `${WORDS.marks.edge} `, color: p.rail[1] }, ...line])
}

// `▌ `, the wordmark, settings, the rows, how many a file or the shell sets (a
// /config row tells no default) and the session name, dropped from the right.
function mastheadOf(v: PanelView, p: Palette): Run[] {
  const brand: Run[] = [{ text: `${WORDS.marks.selected} `, color: p.rail[0] }, ...[...WORDS.brand].slice(0, Math.max(0, v.columns - MARK_CELLS)).map((text, i) => ({ text, color: p.wordmark[i] }))]
  const rows = (v.lines ?? []).flatMap(l => l.kind === 'row' ? [l.row] : [])
  const changed = rows.filter(row => row.kind === 'setting' && CHANGED.has(row.setting.source)).length
  const dot: Run = { text: DOT, color: p.mut }
  const parts: Run[][] = [[{ text: `  ${WORDS.title}`, color: p.ink, weight: 'bold' }],
    ...(v.lines === undefined ? [] : [[dot, { text: WORDS.settings(rows.length), color: p.ink }], [dot, { text: WORDS.changed(changed), color: changed > 0 ? p.teal : p.mut }]]),
    ...(v.session === undefined ? [] : [[dot, { text: v.session, color: p.mut }]])]
  const cells = (runs: readonly Run[]) => runs.reduce((sum, run) => sum + run.text.length, 0)
  const room = v.columns - cells(brand)
  const ends = parts.map((_, i) => cells(parts.slice(0, i + 1).flat()))
  return [...brand, ...parts.slice(0, ends.filter(end => end <= room).length).flat()]
}

// The Buttons' keys: a strip key by its action, a row by its RowId.
const actKey = (action: Action) => `act:${action}`

// A Line, or the empty line above every heading but the first.
type BodyLine = Line | { kind: 'gap' }

const rowsIn = (lines: readonly BodyLine[]) => lines.filter(l => l.kind === 'row').length

// What a view draws, for drawPane and ringOf; a group's name stands for `+0 above`.
function layoutOf(v: PanelView) {
  const p = paletteOf(v.lines ?? [])
  const lines = (v.lines ?? []).flatMap((l, i): BodyLine[] => l.kind !== 'row' && i > 0 ? [{ kind: 'gap' }, l] : [l])
  const listed = lines.findIndex(l => l.kind === 'row' && l.row.id === v.selected)
  const at = listed >= 0 ? listed : lines.findIndex(l => l.kind === 'row')
  const found = lines[at]
  const selected = found?.kind === 'row' ? found : undefined
  const strip = stripFor(selected, v.columns, v.hasKeys)
  const notice = v.lines === undefined && v.problems.length === 0 ? WORDS.reading : undefined
  // The masthead and its rule, the problems, the notice; a gap, the header, its rule.
  const top = 2 + v.problems.length + (notice === undefined ? 0 : 1) + (lines.length > 0 ? 3 : 0)
  const keys = strip.stacked ? strip.keys.length : 1
  // The card's wrapped lines leave a line for its label and one for the window.
  const card = selected === undefined ? [] : cardOf(selected, v.columns, Math.max(1, v.bodyRows - top - keys - 2), p)
  const room = v.bodyRows - top - card.length - keys
  const isGapped = room - 1 >= Math.min(lines.length, WINDOW_FULL)
  const shown = windowOf(lines.length, Math.max(0, at), Math.max(1, room - (isGapped ? 1 : 0)))
  const isEmptyAbove = shown.above && rowsIn(lines.slice(0, shown.from)) === 0
  return { p, lines, selected, card, strip, notice, isGapped, ...shown, ...(isEmptyAbove ? { from: 0, above: false } : {}) }
}

// The keys of the Buttons drawPane draws for a view, in the order the focus
// ring walks them (the window's rows, then the strip's; a heading is no
// Button), and the selected row's key, undefined with no rows.
export function ringOf(v: PanelView): { keys: string[]; selected: string | undefined } {
  const { lines, selected, strip, from, to } = layoutOf(v)
  return { keys: [...lines.slice(from, to).flatMap(l => l.kind === 'row' ? [l.row.id] : []), ...strip.keys.map(k => actKey(k.action))], selected: selected?.row.id }
}

// Where the focus ring goes back to after a drawing, or undefined while its
// place still holds the Button it was put on. The terminal keeps the ring as
// a place among the Buttons, not a key, so a drawing that moves that Button
// (a strip of another length, a shifted window, a row added above) hands the
// place to another, or to none past the last. Back on the same key while it
// is drawn, else on the selected row.
export function ringBack(ring: { key: string; at: number }, next: { keys: readonly string[]; selected: string | undefined }): string | undefined {
  if (next.keys[ring.at] === ring.key) return undefined
  return next.keys.includes(ring.key) ? ring.key : next.selected
}

// The strip goes last, so a long list never pushes it off. A row's Button holds
// the label alone (the focus marks it) and never shrinks, so every line is measured.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { p, lines, selected, card, strip, notice, isGapped, from, to, above, below } = layoutOf(v)
  const { nameCells, cols } = tableOf(v.columns)
  const runs = (line: readonly Run[]) => line.map(({ text, ...style }) => <Text {...style}>{text}</Text>)
  const hint = strip.hint === undefined ? [] : [<Text color={p.mut}>{strip.hint}</Text>]
  const keys = [...strip.keys.map(k => <Button key={actKey(k.action)} plain hotkey={KEYS[k.action].hotkey} label={k.label}
    onPress={() => { if (selected !== undefined) on.act(k.action, selected.row.id) }}><Text color={p.mut}>{k.label}</Text></Button>), ...hint]
  return (
    <Box flexDirection="column">
      <Text>{runs(mastheadOf(v, p))}</Text>
      <Text>{runs(Array.from({ length: v.columns }, (_, i) => ({ text: WORDS.marks.hero, color: ramp(p.hero, v.columns, i) })))}</Text>
      {card.map(line => <Text>{runs(line)}</Text>)}
      {v.problems.map(problem => <Text color={p.mut}>{cut(problem, v.columns)}</Text>)}
      {notice !== undefined && <Text color={p.mut}>{cut(notice, v.columns)}</Text>}
      {lines.length > 0 && <Text>{' '}</Text>}
      {lines.length > 0 && <Text color={p.mut} weight="bold">
        {`${fit(`${' '.repeat(MARK_CELLS)}${WORDS.heads.name}`, MARK_CELLS + nameCells)}${cols.map(c => `${' '.repeat(GAP)}${fit(c.head, c.cells)}`).join('')}`}</Text>}
      {lines.length > 0 && <Text color={p.soft}>{WORDS.marks.rule.repeat(v.columns)}</Text>}
      {above && <Text color={p.faint}>{WORDS.above(rowsIn(lines.slice(0, from)))}</Text>}
      {lines.slice(from, to).map(l => l.kind === 'gap' ? <Text>{' '}</Text> : l.kind !== 'row'
        ? <Text color={p.mut} weight="bold">{`${' '.repeat(MARK_CELLS)}${cut(l.kind === 'mods' ? WORDS.modsGroup : l.title, Math.max(1, v.columns - MARK_CELLS))}`}</Text>
        : (
          <Box flexDirection="row">
            {runs([l === selected ? { text: `${WORDS.marks.selected} `, color: p.rail[1] } : { text: ' '.repeat(MARK_CELLS) }])}
            <Button key={l.row.id} plain label={labelOf(l.row)} {...(l === selected ? { autoFocus: true } : {})}
              onPress={() => l.actions.includes('change') ? on.act('change', l.row.id) : on.select(l.row.id)}>
              {runs([{ text: fit(labelOf(l.row), nameCells), color: p.ink, ...(l === selected ? { weight: 'bold' } as const : {}) }])}
            </Button>
            <Text>{runs(cols.flatMap(c => [{ text: ' '.repeat(GAP) }, ...c.runs(l, c.cells, p)]))}</Text>
          </Box>
        ))}
      {below && <Text color={p.faint}>{WORDS.below(rowsIn(lines.slice(to)))}</Text>}
      {isGapped && <Text>{' '}</Text>}
      <Box flexDirection={strip.stacked ? 'column' : 'row'} columnGap={KEY_GAP}>{keys}</Box>
    </Box>
  )
}
