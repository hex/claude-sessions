/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view: the strip of keys for the selected row, its detail line, the problem lines, and a window of rows fitted to the body.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement } from 'claude-code'
import { shownOf, type Action, type Line, type Pending, type Row, type RowId, type Setting, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, and the room the Pane props
// give.
export type PanelView = {
  lines: readonly Line[] | undefined
  // The selected row; one no longer listed falls back to the first row.
  selected: RowId | undefined
  problems: readonly string[]
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
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// The columns right of the name, in the order a narrow body drops them from
// the end. Each is drawn cut and padded to its cells, so every row is exactly
// as wide as every other.
type Column = { cells: number; text: (line: RowLine) => string }
const NAME_MIN = 8
const GAP = 2
// `› ` on the selected row, two spaces elsewhere.
const MARK_CELLS = 2
// Between the strip's keys, and before its hint.
const KEY_GAP = 3
// How many lines the detail sentence takes at most.
const DETAIL_LINES = 2
const COLUMNS: readonly Column[] = [
  { cells: 11, text: l => l.pending === undefined ? valueOf(l.row) : WORDS.pending[l.pending] },
  { cells: 7, text: l => l.row.kind === 'mod' ? (l.row.mod.isLocked ? WORDS.locked : WORDS.mod) : WORDS.from[l.row.setting.source] },
  { cells: 10, text: l => l.row.kind === 'mod' ? WORDS.modWhen : l.row.setting.when },
]

// What a row's value cell says: a flag or a toggle on or off, else the value,
// else cs's name for the default.
function valueOf(row: Row): string {
  if (row.kind === 'mod') return typeof row.mod.value === 'boolean' ? (row.mod.value ? WORDS.on : WORDS.off) : shownOf(row.mod.value)
  const s = row.setting
  if (s.edit === 'flag') return s.value === '1' ? WORDS.on : WORDS.off
  return s.value ?? s.fallback ?? WORDS.none
}

function labelOf(row: Row): string {
  return row.kind === 'mod' ? row.mod.label : row.setting.label
}

// The longest prefix of COLUMNS that leaves the name NAME_MIN cells.
export function columnsFor(columns: number): readonly Column[] {
  let kept = 0
  let used = MARK_CELLS
  for (const column of COLUMNS) {
    if (columns - used - GAP - column.cells < NAME_MIN) break
    used += GAP + column.cells
    kept++
  }
  return COLUMNS.slice(0, kept)
}

// `text` cut to `cells` with `…`. Every text the panel fits is cs's ASCII
// words, a /config label or its own words, so one UTF-16 unit is one cell
// (`›` and `…` included).
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

// The strip for the selected row, fitted widest first: `c: change   u:
// default   p: this session only   Esc: close`, then without the hint, then
// the short labels (`p: session`); a body narrower than that stacks them one
// key per line. A plain Button draws `<hotkey>: <label>`, so each key is 3 +
// label cells and the fit is exact.
type Key = { action: Action; label: string }
export function stripFor(line: RowLine | undefined, columns: number, hasKeys: boolean): { keys: Key[]; hint: string | undefined; stacked: boolean } {
  const hint = hasKeys ? WORDS.close : WORDS.takeKeys
  const actions = line?.actions ?? []
  const full = actions.map(action => ({ action, label: KEYS[action].verb }))
  const short = actions.map(action => ({ action, label: KEYS[action].short }))
  const width = (keys: Key[], withHint: boolean) => [...keys.map(k => 3 + k.label.length), ...(withHint ? [hint.length] : [])]
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

// The Buttons' keys: a strip key by its action, a row by its RowId.
const actKey = (action: Action) => `act:${action}`

const rowsIn = (lines: readonly Line[]) => lines.filter(l => l.kind === 'row').length

// What a view draws, worked out once for drawPane and ringOf: the lines, the
// selected row (an id no longer listed falls back to the first row), the
// strip, the detail, the notice in place of lines, and the window of lines the
// room left takes.
function layoutOf(v: PanelView) {
  const lines = v.lines ?? []
  const listed = lines.findIndex(l => l.kind === 'row' && l.row.id === v.selected)
  const at = listed >= 0 ? listed : lines.findIndex(l => l.kind === 'row')
  const found = lines[at]
  const selected = found?.kind === 'row' ? found : undefined
  const strip = stripFor(selected, v.columns, v.hasKeys)
  const detail = detailOf(selected, v.columns)
  const notice = v.lines === undefined && v.problems.length === 0 ? WORDS.reading : undefined
  const chrome = (strip.stacked ? strip.keys.length : 1) + detail.length + v.problems.length + (notice === undefined ? 0 : 1)
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

// The pane body, top to bottom: the strip (first, so a long list never pushes
// the keys off the pane), the selected row's detail, the problem lines, `+N
// above`, the window of lines, `+N below`; `+N` counts rows, not headings. A
// heading is bold dim Text; a row is one plain Button keyed by its RowId whose
// children are the marker, the label cut to its cells and one dim Text of the
// padded columns: a Button never shrinks, so every line is measured to
// `columns` before it is drawn. A row's press changes it (Enter on the ring's
// row, a click, a tap), or selects it when it offers no change. The selected
// row carries autoFocus, so a pane opened with focus starts the ring there.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { lines, selected, strip, detail, notice, from, to, above, below } = layoutOf(v)
  const cols = columnsFor(v.columns)
  const nameCells = Math.max(1, v.columns - MARK_CELLS - cols.reduce((sum, c) => sum + GAP + c.cells, 0))
  return (
    <Box flexDirection="column">
      <Box flexDirection={strip.stacked ? 'column' : 'row'} columnGap={KEY_GAP}>
        {strip.keys.map(k => (
          <Button key={actKey(k.action)} plain hotkey={KEYS[k.action].hotkey} label={k.label}
            onPress={() => { if (selected !== undefined) on.act(k.action, selected.row.id) }} />
        ))}
        {strip.hint !== undefined && <Text dimColor>{strip.hint}</Text>}
      </Box>
      {detail.map(text => <Text dimColor>{text}</Text>)}
      {v.problems.map(problem => <Text dimColor>{cut(problem, v.columns)}</Text>)}
      {notice !== undefined && <Text dimColor>{cut(notice, v.columns)}</Text>}
      {above && <Text dimColor>{WORDS.above(rowsIn(lines.slice(0, from)))}</Text>}
      {lines.slice(from, to).map(l => l.kind !== 'row'
        ? <Text weight="bold" dimColor>{cut(l.kind === 'mods' ? WORDS.modsGroup : l.title, v.columns)}</Text>
        : (
          <Button key={l.row.id} plain label={labelOf(l.row)} {...(l === selected ? { autoFocus: true } : {})}
            onPress={() => l.actions.includes('change') ? on.act('change', l.row.id) : on.select(l.row.id)}>
            {l === selected ? '› ' : '  '}
            <Text>{fit(labelOf(l.row), nameCells)}</Text>
            <Text dimColor>{cols.map(c => `${' '.repeat(GAP)}${fit(c.text(l), c.cells)}`).join('')}</Text>
          </Button>
        ))}
      {below && <Text dimColor>{WORDS.below(rowsIn(lines.slice(to)))}</Text>}
    </Box>
  )
}
