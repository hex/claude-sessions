/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view in the cs TUI's look: the masthead, the selected row's card, the problem lines, the filter field, the column header and a window of rows fitted to the body.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement, TextProps, ThemeKey } from 'claude-code'
import { filterLines, keyOf, labelOf, shownOf, type Line, type Pending, type Row, type RowId, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, the session name, the room,
// the filter's text and whether the surface draws an Input.
export type PanelView = {
  lines: readonly Line[] | undefined
  // The selected row; one not shown falls back to the first row shown.
  selected: RowId | undefined
  problems: readonly string[]
  session: string | undefined
  // Pane props: bodyColumns, scroll.bodyRows.
  columns: number
  bodyRows: number
  filter: string
  hasField: boolean
}

export type Handlers = {
  // Enter on a row: its dialog, or why it has none.
  change: (id: RowId) => void
  // The field's text, on every edit.
  filter: (text: string) => void
  // Enter in the field: the ring to the first row shown.
  toRows: () => void
}

// The filter field's key; a row's key is its RowId.
export const FILTER = 'filter'

// Every word the pane draws itself.
export const WORDS = {
  reading: 'asking cs for its settings…',
  on: 'on',
  off: 'off',
  none: '-',
  from: { shell: 'shell', launch: 'launch', session: 'session', machine: 'machine', default: 'default' } satisfies Record<Source, string>,
  mod: 'mod',
  locked: 'locked',
  modsGroup: 'Mods', noMatch: (text: string) => `no setting matches ${text}`,
  pending: { asking: 'asking', writing: 'writing' } satisfies Record<Pending, string>,
  above: (n: number) => `+${n} above`,
  below: (n: number) => `+${n} below`,
  filter: 'filter', find: 'type to filter', toRows: 'first row',
  pinned: (key: string, value: string) => `${key}=${value} in your environment wins; unset it there to change it here`,
  shellOnly: (key: string) => `change it from a shell: cs -config set ${key} 1 (on, it unloads every mod at the next launch, this panel too)`,
  reloads: (plugin: string) => `changing it reloads ${plugin}${plugin === 'cs' ? ' (an armed rotation countdown starts over)' : ''}`,
  managed: 'a managed setting owns it',
  noSession: "this session's file sets it, and this conversation has no cs session name to write it with",
  brand: 'claude-sessions',
  title: 'settings',
  settings: (n: number) => `${n} settings`, changed: (n: number) => `${n} changed`,
  heads: { name: 'setting', value: 'value', from: 'from', when: 'when' },
  // The bars, a toggle's dots, a gauge's cells, the rules, the dot, the card's edge, the field's cursor.
  marks: { selected: '▌', on: '●', off: '○', full: '▰', empty: '▱', rule: '─', hero: '━', dot: '·', edge: '▍', cursor: '▏' },
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// Claude Code's theme keys, which the engine resolves to the person's theme
// on each drawing: ink, muted, faint, the soft rules, the session source's
// teal and the machine source's green (blue in the colour-blind themes).
const THEME = { ink: 'text', mut: 'inactive', faint: 'subtle', soft: 'subtle', teal: 'planMode', green: 'success' } as const satisfies Record<string, ThemeKey>

// The brand's accents on every theme: tui/src/theme.rs's amber, hero stops and
// rail, and install.sh.in's wordmark.
type Rgb = readonly [number, number, number]
const rgb = (channels: readonly number[]) => `rgb(${channels.join(',')})`
const BRAND = {
  amber: rgb([246, 154, 0]), hero: [[221, 80, 20], [237, 128, 0], [246, 154, 0], [214, 162, 30]] satisfies Rgb[], rail: [[221, 80, 20], [246, 154, 0], [250, 180, 60]].map(rgb),
  wordmark: [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16], [245, 142, 15], [246, 151, 14],
    [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]].map(rgb),
}

// The TUI's ramp: cell `i` of `n` along the stops, each channel truncated.
function ramp(stops: readonly Rgb[], n: number, i: number): string {
  const at = n <= 1 ? 0 : i / (n - 1) * (stops.length - 1), a = Math.floor(at)
  const from = stops[a], to = stops[Math.min(a + 1, stops.length - 1)]
  if (from === undefined || to === undefined) throw new Error(`ramp: cell ${i} of ${n} falls outside ${stops.length} stops`)
  return rgb(([0, 1, 2] as const).map(c => Math.trunc(from[c] + (at - a) * (to[c] - from[c]))))
}

// A run of one style; a line is a row of runs as wide as their texts.
type Run = { text: string } & Pick<TextProps, 'color' | 'weight'>

// The columns right of the name, dropped from the end by a narrow body.
type Column = { head: string; cells: number; runs: (line: RowLine, cells: number) => Run[] }
const NAME_MIN = 8
const NAME_MOST = 26
const GAP = 2
const MARK_CELLS = 2
const DOT = `  ${WORDS.marks.dot}  `
const GAUGE_CELLS = 10
const VALUE_CELLS = { wide: GAUGE_CELLS + 4, narrow: 11 }
// cs's `when` for a change that applies at once: the when cell leaves it out.
const AT_ONCE = 'now'
const VALUE: Column = { head: WORDS.heads.value, cells: VALUE_CELLS.wide, runs: (l, cells) => fitRuns(valueRuns(l, cells), cells) }
// A default row leaves from and when empty, a mod row its when.
const REST: readonly Column[] = [
  { head: WORDS.heads.from, cells: 7, runs: (l, cells) => l.row.kind === 'mod'
    ? [{ text: fit(l.row.mod.isLocked ? WORDS.locked : WORDS.mod, cells), color: THEME.mut }]
    : l.row.setting.source === 'default' ? [{ text: fit('', cells) }]
      : [{ text: fit(WORDS.from[l.row.setting.source], cells), color: SOURCE_INK[l.row.setting.source] }] },
  { head: WORDS.heads.when, cells: 10, runs: (l, cells) => l.row.kind === 'setting' && l.row.setting.source !== 'default' && l.row.setting.when !== AT_ONCE
    ? [{ text: fit(l.row.setting.when, cells), color: THEME.mut }] : [{ text: fit('', cells) }] },
]

// A source's colour, the shell's amber as it overrides both files.
const SOURCE_INK: Record<Source, string> = { session: THEME.teal, machine: THEME.green, shell: BRAND.amber, launch: THEME.faint, default: THEME.mut }
const CHANGED: ReadonlySet<Source> = new Set(['session', 'machine', 'shell'])

// A percent setting: cs names each one with a label ending in `%`.
const isPercentSetting = (label: string) => label.endsWith('%')

// On (true), off (false), a word the shell pins a flag to, the value or the default's name.
function valueOf(row: Row): boolean | string {
  if (row.kind === 'mod') return typeof row.mod.value === 'boolean' ? row.mod.value : shownOf(row.mod.value)
  const s = row.setting
  if (s.edit === 'flag') return s.value === undefined ? false : s.value === '1' ? true : s.value
  return s.value ?? s.fallback ?? WORDS.none
}

// A value unpadded: what the row waits on, `● on`, `○ off`, a percentage's gauge where
// `room` holds it beside the number, else the value; ink when set, muted at the default.
function valueRuns(l: RowLine, room: number): Run[] {
  if (l.pending !== undefined) return [{ text: WORDS.pending[l.pending], color: THEME.mut }]
  const value = valueOf(l.row)
  const isDefault = l.row.kind === 'setting' && l.row.setting.source === 'default'
  const tone = isDefault ? THEME.mut : THEME.ink
  if (value === true) return [{ text: WORDS.marks.on, color: THEME.green }, { text: ` ${WORDS.on}`, color: tone }]
  if (value === false) return [{ text: `${WORDS.marks.off} ${WORDS.off}`, color: THEME.mut }]
  const isPercent = l.row.kind === 'setting' && isPercentSetting(l.row.setting.label) && /^\d{1,3}$/.test(value) && Number(value) <= 100
  if (!isPercent || room < GAUGE_CELLS + 1 + value.length) return [{ text: value, color: tone }]
  const full = Math.round(Number(value) / 10)
  return [{ text: WORDS.marks.full.repeat(full), color: isDefault ? THEME.faint : BRAND.amber }, { text: WORDS.marks.empty.repeat(GAUGE_CELLS - full), color: THEME.faint },
    { text: ` ${value}`, color: tone }].filter(run => run.text !== '')
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

// Why Enter opens no dialog on the row, why cs skipped a value, when a change
// applies or what reloads.
export function noteOf(row: Row, hasSelf: boolean): string {
  if (row.kind === 'mod') return row.mod.isLocked ? WORDS.managed : WORDS.reloads(row.mod.plugin)
  const s = row.setting
  if (s.source === 'shell') return WORDS.pinned(s.key, s.value ?? WORDS.none)
  if (s.edit === 'shell') return WORDS.shellOnly(s.key)
  if (s.source === 'session' && !hasSelf) return WORDS.noSession
  return s.ignored ?? s.whenText
}

// The selected row's label and key, then its whole value, its source and its note.
function cardOf(l: RowLine, columns: number, most: number, hasSelf: boolean): Run[][] {
  const row = l.row
  const from: Run = row.kind === 'mod' ? { text: row.mod.isLocked ? WORDS.locked : WORDS.mod, color: THEME.mut }
    : { text: WORDS.from[row.setting.source], color: SOURCE_INK[row.setting.source] }
  const dot: Run = { text: ` ${WORDS.marks.dot} `, color: THEME.mut }
  const room = Math.max(1, columns - MARK_CELLS)
  return [clip([{ text: labelOf(row), color: THEME.ink, weight: 'bold' }, { text: '  ' }, { text: keyOf(row), color: THEME.mut }], room),
    ...wrapRuns([...valueRuns(l, Infinity), dot, from, dot, { text: noteOf(row, hasSelf), color: THEME.mut }], room, most)]
    .map(line => [{ text: `${WORDS.marks.edge} `, color: BRAND.rail[1] }, ...line])
}

// `▌ `, the wordmark, settings, the rows, how many a file or the shell sets (a
// /config row tells no default) and the session name, dropped from the right.
function mastheadOf(v: PanelView): Run[] {
  const brand: Run[] = [{ text: `${WORDS.marks.selected} `, color: BRAND.rail[0] }, ...[...WORDS.brand].slice(0, Math.max(0, v.columns - MARK_CELLS)).map((text, i) => ({ text, color: BRAND.wordmark[i] }))]
  const rows = (v.lines ?? []).flatMap(l => l.kind === 'row' ? [l.row] : [])
  const changed = rows.filter(row => row.kind === 'setting' && CHANGED.has(row.setting.source)).length
  const dot: Run = { text: DOT, color: THEME.mut }
  const parts: Run[][] = [[{ text: `  ${WORDS.title}`, color: THEME.ink, weight: 'bold' }],
    ...(v.lines === undefined ? [] : [[dot, { text: WORDS.settings(rows.length), color: THEME.ink }], [dot, { text: WORDS.changed(changed), color: changed > 0 ? THEME.teal : THEME.mut }]]),
    ...(v.session === undefined ? [] : [[dot, { text: v.session, color: THEME.mut }]])]
  const cells = (runs: readonly Run[]) => runs.reduce((sum, run) => sum + run.text.length, 0)
  const room = v.columns - cells(brand)
  const ends = parts.map((_, i) => cells(parts.slice(0, i + 1).flat()))
  return [...brand, ...parts.slice(0, ends.filter(end => end <= room).length).flat()]
}

// A Line, or the empty line above every heading but the first.
type BodyLine = Line | { kind: 'gap' }

const rowsIn = (lines: readonly BodyLine[]) => lines.filter(l => l.kind === 'row').length

// What a view draws, for drawPane and ringOf: the rows the filter shows, under
// the field and the column header once any row is listed; a group's name
// stands for `+0 above`.
function layoutOf(v: PanelView) {
  const isListed = (v.lines ?? []).length > 0
  const lines = filterLines(v.lines ?? [], v.filter).flatMap((l, i): BodyLine[] => l.kind === 'group' && i > 0 ? [{ kind: 'gap' }, l] : [l])
  const listed = lines.findIndex(l => l.kind === 'row' && l.row.id === v.selected)
  const at = listed >= 0 ? listed : lines.findIndex(l => l.kind === 'row')
  const found = lines[at]
  const selected = found?.kind === 'row' ? found : undefined
  const notice = v.lines === undefined && v.problems.length === 0 ? WORDS.reading : undefined
  const noMatch = isListed && lines.length === 0 ? WORDS.noMatch(v.filter.trim()) : undefined
  // The masthead and its rule, the problems, the notice; the field between two empty lines, the header, its rule; the no-match line.
  const top = 2 + v.problems.length + (notice === undefined ? 0 : 1) + (isListed ? 5 : 0) + (noMatch === undefined ? 0 : 1)
  // The card's wrapped lines leave a line for its label and one for the window.
  const card = selected === undefined ? [] : cardOf(selected, v.columns, Math.max(1, v.bodyRows - top - 2), v.session !== undefined)
  const shown = windowOf(lines.length, Math.max(0, at), Math.max(1, v.bodyRows - top - card.length))
  const isEmptyAbove = shown.above && rowsIn(lines.slice(0, shown.from)) === 0
  return { isListed, lines, selected, card, notice, noMatch, ...shown, ...(isEmptyAbove ? { from: 0, above: false } : {}) }
}

// The keys of the elements drawPane draws for a view, in the order the focus
// ring walks them (the field, then the window's rows; a heading is no
// Button), and the selected row's key, undefined with no rows.
export function ringOf(v: PanelView): { keys: string[]; selected: string | undefined } {
  const { isListed, lines, selected, from, to } = layoutOf(v)
  return { keys: [...(isListed && v.hasField ? [FILTER] : []), ...lines.slice(from, to).flatMap(l => l.kind === 'row' ? [l.row.id] : [])], selected: selected?.row.id }
}

// Where the focus ring goes back to after a drawing, or undefined while its
// place still holds the element it was put on. The terminal keeps the ring as
// a place among the elements, not a key, so a drawing that moves that element
// (a shifted window, a row added above, a filter that hides it) hands the
// place to another, or to none past the last. Back on the same key while it
// is drawn, else on the selected row.
export function ringBack(ring: { key: string; at: number }, next: { keys: readonly string[]; selected: string | undefined }): string | undefined {
  if (next.keys[ring.at] === ring.key) return undefined
  return next.keys.includes(ring.key) ? ring.key : next.selected
}

// A group's name in bold ink, then a soft rule to the body's edge.
function headingOf(title: string, columns: number): Run[] {
  const name = cut(title, Math.max(1, columns - 2))
  return [{ text: name, color: THEME.ink, weight: 'bold' }, { text: ` ${WORDS.marks.rule.repeat(Math.max(1, columns - name.length - 1))}`, color: THEME.soft }]
}

// A row's Button holds the label alone (the focus marks it) and never shrinks,
// so every line is measured. Enter in the field sends the ring to the rows.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { isListed, lines, selected, card, notice, noMatch, from, to, above, below } = layoutOf(v)
  const { nameCells, cols } = tableOf(v.columns)
  const runs = (line: readonly Run[]) => line.map(({ text, ...style }) => <Text {...style}>{text}</Text>)
  const Input = v.hasField && 'Input' in el ? el.Input : undefined
  return (
    <Box flexDirection="column">
      <Text>{runs(mastheadOf(v))}</Text>
      <Text>{runs(Array.from({ length: v.columns }, (_, i) => ({ text: WORDS.marks.hero, color: ramp(BRAND.hero, v.columns, i) })))}</Text>
      {card.map(line => <Text>{runs(line)}</Text>)}
      {v.problems.map(problem => <Text color={THEME.mut}>{cut(problem, v.columns)}</Text>)}
      {notice !== undefined && <Text color={THEME.mut}>{cut(notice, v.columns)}</Text>}
      {isListed && <Text>{' '}</Text>}
      {isListed && (Input === undefined ? <Text>{' '}</Text> : <Box flexDirection="row">
        {runs([{ text: `${WORDS.filter} `, color: THEME.ink, weight: 'bold' }, { text: `${WORDS.marks.cursor} `, color: BRAND.rail[1] }])}
        <Input key={FILTER} placeholder={WORDS.find} value={v.filter} submitLabel={WORDS.toRows} autoFocus onInput={on.filter} onSubmit={text => { on.filter(text); on.toRows() }} /></Box>)}
      {isListed && <Text>{' '}</Text>}
      {isListed && <Text color={THEME.mut} weight="bold">
        {`${fit(`${' '.repeat(MARK_CELLS)}${WORDS.heads.name}`, MARK_CELLS + nameCells)}${cols.map(c => `${' '.repeat(GAP)}${fit(c.head, c.cells)}`).join('')}`}</Text>}
      {isListed && <Text color={THEME.soft}>{WORDS.marks.rule.repeat(v.columns)}</Text>}
      {noMatch !== undefined && <Text color={THEME.mut}>{cut(noMatch, v.columns)}</Text>}
      {above && <Text color={THEME.faint}>{WORDS.above(rowsIn(lines.slice(0, from)))}</Text>}
      {lines.slice(from, to).map(l => l.kind === 'gap' ? <Text>{' '}</Text> : l.kind === 'group' ? <Text>{runs(headingOf(l.title, v.columns))}</Text> : (
        <Box flexDirection="row">
          {runs([l === selected ? { text: `${WORDS.marks.selected} `, color: BRAND.rail[1] } : { text: ' '.repeat(MARK_CELLS) }])}
          <Button key={l.row.id} plain label={labelOf(l.row)} {...(l === selected ? { autoFocus: true } : {})} onPress={() => on.change(l.row.id)}>
            {runs([{ text: fit(labelOf(l.row), nameCells), color: THEME.ink, ...(l === selected ? { weight: 'bold' } as const : {}) }])}
          </Button>
          <Text>{runs(cols.flatMap(c => [{ text: ' '.repeat(GAP) }, ...c.runs(l, c.cells)]))}</Text>
        </Box>
      ))}
      {below && <Text color={THEME.faint}>{WORDS.below(rowsIn(lines.slice(to)))}</Text>}
    </Box>
  )
}
