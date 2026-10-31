/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view: the header, the strip of keys for the selected row, its detail line, the problem lines, and a window of rows fitted to the body.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement, TextProps } from 'claude-code'
import { shownOf, type Action, type Line, type Pending, type Row, type RowId, type Setting, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, the session name the header
// names, and the room the Pane props give.
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
  from: { shell: 'shell', launch: 'launch', session: 'session', machine: 'machine', default: 'default' } satisfies Record<Source, string>,
  mod: 'mod',
  locked: 'locked',
  modsGroup: 'Mods',
  modWhen: 'now',
  pending: { asking: 'asking', writing: 'writing' } satisfies Record<Pending, string>,
  above: (n: number) => `+${n} above`,
  below: (n: number) => `+${n} below`,
  close: 'Esc: close',
  takeKeys: 'ctrl+x tab: keys',
  // The selected row's detail line.
  about: (key: string, text: string) => `${key}: ${text}`,
  pinned: (key: string, value: string) => `${key}=${value} in your environment wins; unset it there to change it here`,
  shellOnly: (key: string) => `change it from a shell: cs -config set ${key} 1 (on, it unloads every mod at the next launch, this panel too)`,
  reloads: (plugin: string) => `changing it reloads ${plugin}${plugin === 'cs' ? ' (an armed rotation countdown starts over)' : ''}`,
  managed: 'a managed setting owns it',
  brand: 'claude-sessions',
  title: 'settings',
  // The selected row's bar, a toggle's dot, a gauge's cells, a heading's
  // rule, and the header's bar and dot.
  marks: { selected: '▌', on: '●', off: '○', full: '▰', empty: '▱', rule: '─', bar: '▍', dot: '·' },
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// The colours of lib/05-term.sh's palette the pane draws in, by the
// porcelain's CS_TERM_THEME: `light` (a cream terminal) takes the muted set,
// anything else the vivid one. `accent` is cs's amber, `rule` its rust, and
// the wordmark install.sh.in's rust-to-gold gradient, one colour a letter
// (the muted one run between the muted rust and gold).
type Ink = { accent: string; rule: string; wordmark: readonly string[] }
type Rgb = readonly [number, number, number]
const rgb = ([r, g, b]: Rgb) => `rgb(${r},${g},${b})`
function gradient([r1, g1, b1]: Rgb, [r2, g2, b2]: Rgb, n: number): string[] {
  const at = (from: number, to: number, i: number) => Math.round(from + (to - from) * i / (n - 1))
  return Array.from({ length: n }, (_, i) => rgb([at(r1, r2, i), at(g1, g2, i), at(b1, b2, i)]))
}
const INKS = {
  dark: { accent: rgb([255, 183, 77]), rule: rgb([230, 74, 25]), wordmark: ([[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20],
    [239, 117, 19], [241, 125, 17], [243, 134, 16], [245, 142, 15], [246, 151, 14], [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]] as const).map(rgb) },
  light: { accent: rgb([162, 122, 58]), rule: rgb([166, 86, 60]), wordmark: gradient([166, 86, 60], [156, 118, 56], WORDS.brand.length) },
} satisfies Record<'dark' | 'light', Ink>

function inkOf(lines: readonly Line[]): Ink {
  return lines.some(l => l.kind === 'row' && l.row.kind === 'setting' && l.row.setting.key === 'CS_TERM_THEME' && l.row.setting.value === 'light') ? INKS.light : INKS.dark
}

// A run of one style. Every line the pane draws is a row of runs exactly as
// wide as their texts are long.
type Run = { text: string } & Pick<TextProps, 'color' | 'dimColor' | 'weight'>

// The columns right of the name, in the order a narrow body drops them from
// the end. Each is drawn cut and padded to its cells, so every row is exactly
// as wide as every other.
type Column = { cells: number; runs: (line: RowLine, cells: number, ink: Ink) => Run[] }
const NAME_MIN = 8
const GAP = 2
// `▌ ` on the selected row, two spaces elsewhere.
const MARK_CELLS = 2
// Between the strip's keys, and before its hint.
const KEY_GAP = 1
// A strip key's cells besides its label: its hotkey and `: ` (a plain Button
// draws `<hotkey>: <label>`) and the cell of padding either side of its chip.
const KEY_CELLS = 5
// How many lines the detail sentence takes at most.
const DETAIL_LINES = 2
// A value cell holds a gauge and its number (up to 100) when it is wide.
const GAUGE_CELLS = 10
const VALUE_CELLS = { wide: GAUGE_CELLS + 4, narrow: 11 }
const VALUE: Column = { cells: VALUE_CELLS.wide, runs: valueRuns }
const REST: readonly Column[] = [
  { cells: 7, runs: (l, cells, ink) => l.row.kind === 'mod'
    ? [{ text: fit(l.row.mod.isLocked ? WORDS.locked : WORDS.mod, cells), dimColor: true }]
    : [{ text: fit(WORDS.from[l.row.setting.source], cells), ...SOURCE_INK[l.row.setting.source](ink) }] },
  { cells: 10, runs: (l, cells) => [{ text: fit(l.row.kind === 'mod' ? WORDS.modWhen : l.row.setting.when, cells), dimColor: true }] },
]

// Where a value comes from, in colour: a file's in the theme's claude
// (session) or success (machine) colour, the shell's in the accent, as it
// overrides both, the launch's and the default's dim.
const SOURCE_INK: Record<Source, (ink: Ink) => Pick<Run, 'color' | 'dimColor'>> = {
  session: () => ({ color: 'claude' }), machine: () => ({ color: 'success' }), shell: ink => ({ color: ink.accent }),
  launch: () => ({ dimColor: true }), default: () => ({ dimColor: true }),
}

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

// A value cell: what the row waits on, dim; on as `● on`, the dot in success;
// off as `○ off`, dim; a percentage that reads as a whole number up to 100 as
// a gauge of its tenths (filled in the accent, the rest dim) and the number,
// where the cell holds both; else the value.
function valueRuns(l: RowLine, cells: number, ink: Ink): Run[] {
  if (l.pending !== undefined) return [{ text: fit(WORDS.pending[l.pending], cells), dimColor: true }]
  const value = valueOf(l.row)
  if (value === true) return [{ text: WORDS.marks.on, color: 'success' }, { text: fit(` ${WORDS.on}`, cells - 1) }]
  if (value === false) return [{ text: fit(`${WORDS.marks.off} ${WORDS.off}`, cells), dimColor: true }]
  const isPercent = l.row.kind === 'setting' && PERCENT_KEYS.has(l.row.setting.key) && /^\d{1,3}$/.test(value) && Number(value) <= 100
  if (!isPercent || cells < GAUGE_CELLS + 1 + value.length) return [{ text: fit(value, cells) }]
  const full = Math.round(Number(value) / 10)
  return [{ text: WORDS.marks.full.repeat(full), color: ink.accent }, { text: WORDS.marks.empty.repeat(GAUGE_CELLS - full), dimColor: true },
    { text: fit(` ${value}`, cells - GAUGE_CELLS) }].filter(run => run.text !== '')
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

// The strip for the selected row, fitted widest first: ` c: change   u:
// default   p: this session only  Esc: close`, each key a chip, then without
// the hint, then the short labels (`p: session`); a body narrower than that
// stacks them one key per line. Each key is KEY_CELLS + label cells, so the
// fit is exact.
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

// The first line: the wordmark, one colour a letter, then ` ▍ settings`, the
// bar in the accent, then ` · <session>` dim, fitted widest first: the
// session name only from 40 columns, cut to the room left; `settings` only
// where it fits; a body narrower than the wordmark cuts it.
function headerOf(columns: number, session: string | undefined, ink: Ink): Run[] {
  const letters: Run[] = [...WORDS.brand].slice(0, columns).map((text, i) => ({ text, color: ink.wordmark[i] }))
  const title = [{ text: ` ${WORDS.marks.bar}`, color: ink.accent }, { text: ` ${WORDS.title}` }]
  const named = ` ${WORDS.marks.dot} `
  const room = columns - WORDS.brand.length - title.reduce((sum, run) => sum + run.text.length, 0)
  if (room < 0) return letters
  if (session === undefined || columns < 40 || room <= named.length) return [...letters, ...title]
  return [...letters, ...title, { text: `${named}${cut(session, room - named.length)}`, dimColor: true }]
}

// A group's heading, the body wide: `── <name> ───…`, the name bold in the
// text colour and the rule in the rust.
function ruleOf(title: string, columns: number, ink: Ink): Run[] {
  const name = cut(title, Math.max(1, columns - 4))
  const rule = WORDS.marks.rule
  return [{ text: `${rule}${rule} `, color: ink.rule }, { text: name, weight: 'bold' }, { text: ` ${rule.repeat(Math.max(0, columns - name.length - 4))}`, color: ink.rule }]
}

// The Buttons' keys: a strip key by its action, a row by its RowId.
const actKey = (action: Action) => `act:${action}`

const rowsIn = (lines: readonly Line[]) => lines.filter(l => l.kind === 'row').length

// What a view draws, worked out once for drawPane and ringOf: the lines, the
// selected row (an id no longer listed falls back to the first row), the
// strip, the detail, the notice in place of lines, and the window of lines the
// room left under the header takes.
function layoutOf(v: PanelView) {
  const lines = v.lines ?? []
  const listed = lines.findIndex(l => l.kind === 'row' && l.row.id === v.selected)
  const at = listed >= 0 ? listed : lines.findIndex(l => l.kind === 'row')
  const found = lines[at]
  const selected = found?.kind === 'row' ? found : undefined
  const strip = stripFor(selected, v.columns, v.hasKeys)
  const detail = detailOf(selected, v.columns)
  const notice = v.lines === undefined && v.problems.length === 0 ? WORDS.reading : undefined
  const chrome = 1 + (strip.stacked ? strip.keys.length : 1) + detail.length + v.problems.length + (notice === undefined ? 0 : 1)
  return { lines, selected, strip, detail, notice, ...windowOf(lines.length, Math.max(0, at), Math.max(1, v.bodyRows - chrome)) }
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

// The pane body, top to bottom: the header, the strip (before the rows, so a
// long list never pushes the keys off the pane), the selected row's detail,
// the problem lines, `+N above`, the window of lines, `+N below`; `+N` counts
// rows, not headings. Each strip key is a plain Button on a `subtle` Box
// padded a cell either side, a chip. A heading is its rule; a row is one plain
// Button keyed by its RowId whose children are the runs of the marker, the
// label (bold when selected) cut to its cells and the padded columns: a Button
// never shrinks, so every line is measured to `columns` before it is drawn. A
// row's press changes it (Enter on the ring's row, a click, a tap), or selects
// it when it offers no change. The selected row carries autoFocus, so a pane
// opened with focus starts the ring there.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { lines, selected, strip, detail, notice, from, to, above, below } = layoutOf(v)
  const ink = inkOf(lines)
  const cols = columnsFor(v.columns)
  const nameCells = Math.max(1, v.columns - MARK_CELLS - cols.reduce((sum, c) => sum + GAP + c.cells, 0))
  const runs = (line: readonly Run[]) => line.map(({ text, ...style }) => <Text {...style}>{text}</Text>)
  const rowRuns = (l: RowLine): Run[] => [
    l === selected ? { text: `${WORDS.marks.selected} `, color: ink.accent } : { text: ' '.repeat(MARK_CELLS) },
    { text: fit(labelOf(l.row), nameCells), ...(l === selected ? { weight: 'bold' } as const : {}) },
    ...cols.flatMap(c => [{ text: ' '.repeat(GAP) }, ...c.runs(l, c.cells, ink)]),
  ]
  return (
    <Box flexDirection="column">
      <Text>{runs(headerOf(v.columns, v.session, ink))}</Text>
      <Box flexDirection={strip.stacked ? 'column' : 'row'} columnGap={KEY_GAP}>
        {strip.keys.map(k => (
          <Box backgroundColor="subtle" paddingX={1} alignSelf="flex-start">
            <Button key={actKey(k.action)} plain hotkey={KEYS[k.action].hotkey} label={k.label}
              onPress={() => { if (selected !== undefined) on.act(k.action, selected.row.id) }} />
          </Box>
        ))}
        {strip.hint !== undefined && <Text dimColor>{strip.hint}</Text>}
      </Box>
      {detail.map(text => <Text dimColor>{text}</Text>)}
      {v.problems.map(problem => <Text dimColor>{cut(problem, v.columns)}</Text>)}
      {notice !== undefined && <Text dimColor>{cut(notice, v.columns)}</Text>}
      {above && <Text dimColor>{WORDS.above(rowsIn(lines.slice(0, from)))}</Text>}
      {lines.slice(from, to).map(l => l.kind !== 'row'
        ? <Text>{runs(ruleOf(l.kind === 'mods' ? WORDS.modsGroup : l.title, v.columns, ink))}</Text>
        : (
          <Button key={l.row.id} plain label={labelOf(l.row)} {...(l === selected ? { autoFocus: true } : {})}
            onPress={() => l.actions.includes('change') ? on.act('change', l.row.id) : on.select(l.row.id)}>
            {runs(rowRuns(l))}
          </Button>
        ))}
      {below && <Text dimColor>{WORDS.below(rowsIn(lines.slice(to)))}</Text>}
    </Box>
  )
}
