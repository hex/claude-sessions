/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view in the cs TUI's look: the masthead, the strip of keys for the selected row, its detail line, the problem lines, the column header and a window of rows fitted to the body.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement, TextProps } from 'claude-code'
import { shownOf, type Action, type Line, type Pending, type Row, type RowId, type Setting, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, the session name the
// masthead names, and the room the Pane props give.
export type PanelView = {
  lines: readonly Line[] | undefined
  // The selected row; one no longer listed falls back to the first row.
  selected: RowId | undefined
  problems: readonly string[]
  // The session name cs launched this conversation under, if any.
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
  from: { shell: 'shell', launch: 'launch', session: 'session', machine: 'machine' } satisfies Record<Exclude<Source, 'default'>, string>,
  mod: 'mod',
  locked: 'locked',
  modsGroup: 'Mods',
  pending: { asking: 'asking', writing: 'writing' } satisfies Record<Pending, string>,
  above: (n: number) => `+${n} above`,
  below: (n: number) => `+${n} below`,
  close: 'Esc: close',
  takeKeys: 'ctrl+x tab: keys',
  // The selected row's detail line.
  about: (key: string, text: string) => `${key} · ${text}`,
  pinned: (key: string, value: string) => `${key}=${value} in your environment wins; unset it there to change it here`,
  shellOnly: (key: string) => `change it from a shell: cs -config set ${key} 1 (on, it unloads every mod at the next launch, this panel too)`,
  reloads: (plugin: string) => `changing it reloads ${plugin}${plugin === 'cs' ? ' (an armed rotation countdown starts over)' : ''}`,
  managed: 'a managed setting owns it',
  brand: 'claude-sessions',
  title: 'settings',
  settings: (n: number) => `${n} settings`, changed: (n: number) => `${n} changed`,
  heads: { name: 'setting', value: 'value', from: 'from', when: 'when' },
  // The bars, a toggle's dots, a gauge's cells, the rules, the masthead's dot.
  marks: { selected: '▌', on: '●', off: '○', full: '▰', empty: '▱', rule: '─', hero: '━', dot: '·' },
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// The cs TUI's palettes (tui/src/theme.rs), the light one when the porcelain's
// CS_TERM_THEME is `light` (a cream terminal): `hero` is the masthead rule's
// gradient, `rail` the selection bar's, and the wordmark install.sh.in's
// rust-to-gold, one colour a letter (lib/05-term.sh's muted pair when light).
type Rgb = readonly [number, number, number]
const rgb = (channels: readonly number[]) => `rgb(${channels.join(',')})`
type Palette = Record<'ink' | 'mut' | 'faint' | 'soft' | 'teal' | 'green' | 'amber', string> & { hero: readonly Rgb[]; rail: readonly string[]; wordmark: readonly string[] }

// The TUI's ramp: cell `i` of `n` along the stops, linear between the two it
// falls between, each channel truncated; one cell takes the first stop.
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

// A run of one style. Every line the pane draws is a row of runs exactly as
// wide as their texts are long.
type Run = { text: string } & Pick<TextProps, 'color' | 'weight'>

// The columns right of the name, under their heads, dropped from the end by a
// narrow body; each cut and padded to its cells, so all rows are as wide.
type Column = { head: string; cells: number; runs: (line: RowLine, cells: number, p: Palette) => Run[] }
const NAME_MIN = 8
// The most a name takes; a wider body gives the rest to the last column.
const NAME_MOST = 26
const GAP = 2
// `▌ ` on the selected row, two spaces elsewhere.
const MARK_CELLS = 2
// Between the masthead's parts, and between the strip's keys and its hint.
const DOT = `  ${WORDS.marks.dot}  `
const KEY_GAP = 3
// A strip key's cells besides its label: its hotkey and `: ` (a plain Button
// draws `<hotkey>: <label>`).
const KEY_CELLS = 3
// How many lines the detail sentence takes at most.
const DETAIL_LINES = 2
// A value cell holds a gauge and its number (up to 100) when it is wide.
const GAUGE_CELLS = 10
const VALUE_CELLS = { wide: GAUGE_CELLS + 4, narrow: 11 }
// cs's `when` for a change that applies at once: the when cell leaves it out.
const AT_ONCE = 'now'
const VALUE: Column = { head: WORDS.heads.value, cells: VALUE_CELLS.wide, runs: valueRuns }
// Only what is set reads in the from and when cells: a default row leaves
// both empty, a mod row its when.
const REST: readonly Column[] = [
  { head: WORDS.heads.from, cells: 7, runs: (l, cells, p) => l.row.kind === 'mod'
    ? [{ text: fit(l.row.mod.isLocked ? WORDS.locked : WORDS.mod, cells), color: p.mut }]
    : l.row.setting.source === 'default' ? [{ text: fit('', cells) }]
      : [{ text: fit(WORDS.from[l.row.setting.source], cells), color: p[SOURCE_INK[l.row.setting.source]] }] },
  { head: WORDS.heads.when, cells: 10, runs: (l, cells, p) => l.row.kind === 'setting' && l.row.setting.source !== 'default' && l.row.setting.when !== AT_ONCE
    ? [{ text: fit(l.row.setting.when, cells), color: p.mut }] : [{ text: fit('', cells) }] },
]

// A set source's colour, the shell's amber as it overrides both files.
const SOURCE_INK: Record<Exclude<Source, 'default'>, 'teal' | 'green' | 'amber' | 'faint'> = { session: 'teal', machine: 'green', shell: 'amber', launch: 'faint' }
const CHANGED: ReadonlySet<Source> = new Set(['session', 'machine', 'shell'])

// The settings whose value is a percentage, by key.
const PERCENT_KEYS: ReadonlySet<string> = new Set(['CS_STATUSLINE_CTX_WARN', 'CS_STATUSLINE_CTX_CRIT', 'CS_CTX_WARN_CTX', 'CS_ROTATE_NUDGE_CTX',
  'CS_QUEUE_MAX_CTX', 'CS_QUEUE_MAX_5H', 'CS_ROTATE_FORCE_CTX'])

// What a row's value cell says: a flag or a toggle on (true) or off (false),
// a word the shell pins a flag to (its readers take any), else the value,
// else cs's name for the default.
function valueOf(row: Row): boolean | string {
  if (row.kind === 'mod') return typeof row.mod.value === 'boolean' ? row.mod.value : shownOf(row.mod.value)
  const s = row.setting
  if (s.edit === 'flag') return s.value === undefined ? false : s.value === '1' ? true : s.value
  return s.value ?? s.fallback ?? WORDS.none
}

// A value cell: what the row waits on, muted; `● on`, the dot green; `○ off`
// muted; a whole percentage up to 100 as a gauge of its tenths and the number
// where the cell holds both; else the value. A set value is in ink and its
// gauge filled in amber, a default's muted and its gauge all faint.
function valueRuns(l: RowLine, cells: number, p: Palette): Run[] {
  if (l.pending !== undefined) return [{ text: fit(WORDS.pending[l.pending], cells), color: p.mut }]
  const value = valueOf(l.row)
  const isDefault = l.row.kind === 'setting' && l.row.setting.source === 'default'
  const tone = isDefault ? p.mut : p.ink
  if (value === true) return [{ text: WORDS.marks.on, color: p.green }, { text: fit(` ${WORDS.on}`, cells - 1), color: tone }]
  if (value === false) return [{ text: fit(`${WORDS.marks.off} ${WORDS.off}`, cells), color: p.mut }]
  const isPercent = l.row.kind === 'setting' && PERCENT_KEYS.has(l.row.setting.key) && /^\d{1,3}$/.test(value) && Number(value) <= 100
  if (!isPercent || cells < GAUGE_CELLS + 1 + value.length) return [{ text: fit(value, cells), color: tone }]
  const full = Math.round(Number(value) / 10)
  return [{ text: WORDS.marks.full.repeat(full), color: isDefault ? p.faint : p.amber }, { text: WORDS.marks.empty.repeat(GAUGE_CELLS - full), color: p.faint },
    { text: fit(` ${value}`, cells - GAUGE_CELLS), color: tone }].filter(run => run.text !== '')
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

// The columns a body this wide draws: the wide value cell when that drops no
// column the narrow one keeps.
export function columnsFor(columns: number): readonly Column[] {
  const wide = fitted([VALUE, ...REST], columns)
  const narrow = fitted([{ ...VALUE, cells: VALUE_CELLS.narrow }, ...REST], columns)
  return wide.length >= narrow.length ? wide : narrow
}

// The name's cells and the columns a body this wide draws: the name takes
// what the columns leave, up to NAME_MOST, and the last column the rest.
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

// The strip for the selected row, the widest that fits, KEY_GAP cells apart:
// `c: change   u: default   p: this session only   Esc: close`, no hint, the
// short labels (`p: session`), else stacked; a key is KEY_CELLS + its label.
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

// `text` in lines of `columns` broken between words (a word longer than a line
// is broken inside), at most `most` of them, the last cut with `…` when more
// was left.
function wrapped(text: string, columns: number, most: number): string[] {
  const lines: string[] = []
  let line = ''
  for (let word of text.split(' ')) {
    while (word.length > columns) {
      if (line !== '') { lines.push(line); line = '' }
      lines.push(word.slice(0, columns))
      word = word.slice(columns)
    }
    if (line === '') line = word
    else if (line.length + 1 + word.length <= columns) line = `${line} ${word}`
    else { lines.push(line); line = word }
  }
  if (line !== '') lines.push(line)
  if (lines.length <= most) return lines
  const last = lines[most - 1] ?? ''
  return [...lines.slice(0, most - 1), last.length + 1 <= columns ? `${last}…` : cut(last, columns)]
}

// The selected row's sentence, in at most two lines of `columns`:
//   setting, pinned by the shell -> WORDS.pinned
//   setting, changed from a shell -> WORDS.shellOnly
//   setting, a file value skipped -> <key>: <why cs skipped it>
//   setting                       -> <key>: <when a change applies>
//   mod row, locked               -> <key>: WORDS.managed
//   mod row                       -> <key>: WORDS.reloads(<plugin>)
export function detailOf(line: RowLine | undefined, columns: number): string[] {
  if (line === undefined) return []
  const row = line.row
  return wrapped(row.kind === 'mod'
    ? WORDS.about(row.mod.key, row.mod.isLocked ? WORDS.managed : WORDS.reloads(row.mod.plugin))
    : sentenceOf(row.setting), columns, DETAIL_LINES)
}

function sentenceOf(s: Setting): string {
  if (s.source === 'shell') return WORDS.pinned(s.key, s.value ?? WORDS.none)
  if (s.edit === 'shell') return WORDS.shellOnly(s.key)
  return WORDS.about(s.key, s.ignored ?? s.whenText)
}

// The masthead's first line, as the cs TUI's: `▌ `, the wordmark (cut by a
// narrower body), `  settings`, `  ·  <rows> settings`, `  ·  <M> changed`
// (teal unless 0) and `  ·  <session>`, each `·` muted, dropped from the
// right to fit. M counts settings a file or the shell sets: a /config row
// tells no default.
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

// A line of the body below the counts: a Line, or the empty line above every
// heading but the first, which takes a line of the window like any other.
type BodyLine = Line | { kind: 'gap' }

const rowsIn = (lines: readonly BodyLine[]) => lines.filter(l => l.kind === 'row').length

// What a view draws, worked out once for drawPane and ringOf: the body's
// lines, the selected row (an id no longer listed falls back to the first
// row), the strip, the detail, the notice in place of lines, and the window
// of lines the room under the column header takes, with the first group's
// name in place of `+0 above`.
function layoutOf(v: PanelView) {
  const lines = (v.lines ?? []).flatMap((l, i): BodyLine[] => l.kind !== 'row' && i > 0 ? [{ kind: 'gap' }, l] : [l])
  const listed = lines.findIndex(l => l.kind === 'row' && l.row.id === v.selected)
  const at = listed >= 0 ? listed : lines.findIndex(l => l.kind === 'row')
  const found = lines[at]
  const selected = found?.kind === 'row' ? found : undefined
  const strip = stripFor(selected, v.columns, v.hasKeys)
  const detail = detailOf(selected, v.columns)
  const notice = v.lines === undefined && v.problems.length === 0 ? WORDS.reading : undefined
  // The masthead and its rule; with lines, a gap, the header, its rule.
  const chrome = 2 +(strip.stacked ? strip.keys.length : 1) + detail.length + v.problems.length + (notice === undefined ? 0 : 1) + (lines.length > 0 ? 3 : 0)
  const shown = windowOf(lines.length, Math.max(0, at), Math.max(1, v.bodyRows - chrome))
  const isEmptyAbove = shown.above && rowsIn(lines.slice(0, shown.from)) === 0
  return { lines, selected, strip, detail, notice, ...shown, ...(isEmptyAbove ? { from: 0, above: false } : {}) }
}

// The keys of the Buttons drawPane draws for a view, in the order the focus
// ring walks them (the strip's, then the window's rows; a heading is no
// Button), and the selected row's key, undefined with no rows.
export function ringOf(v: PanelView): { keys: string[]; selected: string | undefined } {
  const { lines, selected, strip, from, to } = layoutOf(v)
  return {
    keys: [...strip.keys.map(k => actKey(k.action)), ...lines.slice(from, to).flatMap(l => l.kind === 'row' ? [l.row.id] : [])],
    selected: selected?.row.id,
  }
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

// The pane body: the masthead and its hero rule, the strip (above the rows, so
// a long list never pushes the keys off), the detail, the problems, an empty
// line, the column header and its rule, `+N above`, the
// window and `+N below` (`+N` counts rows). A row is a row Box of the marker's
// Text, a plain Button keyed by its RowId holding only the label (the focus
// marks it alone) and the padded columns' Text: a Button never shrinks, so
// every line is measured to `columns`. A press changes the row, or selects it
// when it offers no change; the selected row takes autoFocus.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { lines, selected, strip, detail, notice, from, to, above, below } = layoutOf(v)
  const p = paletteOf(v.lines ?? [])
  const { nameCells, cols } = tableOf(v.columns)
  const runs = (line: readonly Run[]) => line.map(({ text, ...style }) => <Text {...style}>{text}</Text>)
  const hint = strip.hint === undefined ? [] : [<Text color={p.mut}>{strip.hint}</Text>]
  const keys = [...strip.keys.map(k => <Button key={actKey(k.action)} plain hotkey={KEYS[k.action].hotkey} label={k.label}
    onPress={() => { if (selected !== undefined) on.act(k.action, selected.row.id) }}><Text color={p.mut}>{k.label}</Text></Button>), ...hint]
  return (
    <Box flexDirection="column">
      <Text>{runs(mastheadOf(v, p))}</Text>
      <Text>{runs(Array.from({ length: v.columns }, (_, i) => ({ text: WORDS.marks.hero, color: ramp(p.hero, v.columns, i) })))}</Text>
      <Box flexDirection={strip.stacked ? 'column' : 'row'} columnGap={KEY_GAP}>{keys}</Box>
      {detail.map(text => <Text color={p.faint}>{text}</Text>)}
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
    </Box>
  )
}
