/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view in the cs TUI's look: the masthead, the problem lines, the search box, the column header, a window of rows fitted to the body and the selected row's footer, which the reset control ends.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement, TextProps, ThemeKey } from 'claude-code'
import { filterLines, keyOf, labelOf, lockOf, shownOf, turnsOff, type Line, type Lock, type Pending, type Row, type RowId, type Source } from './settings'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the lines (undefined until cs or /config first
// answers), the selection, why a source is stale, the session name, cs's
// version and a pending one, the room, the filter's text and the Input.
export type PanelView = {
  lines: readonly Line[] | undefined
  // The selected row; one not shown falls back to the first row shown.
  selected: RowId | undefined
  problems: readonly string[]
  session: string | undefined
  version: string | undefined
  update: string | undefined
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
  // Enter on the reset control: its dialog.
  reset: () => void
}

// The filter field's key and the reset control's; a row's key is its RowId.
export const FILTER = 'filter'
export const RESET = 'reset'

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
  find: 'search settings', toRows: 'select',
  pinned: (key: string, value: string) => `${key}=${value} in your environment wins; unset it there to change it here`,
  shellOnly: (key: string) => `change it from a shell: cs -config set ${key} 1 loads no mod from the next launch, this panel included`,
  reloads: (plugin: string) => `changing it reloads ${plugin}${plugin === 'cs' ? ' (an armed rotation countdown starts over)' : ''}`,
  managed: 'a managed setting owns it',
  noSession: "this session's file sets it, and this conversation has no cs session name to write it with",
  brand: 'claude-sessions', cs: 'cs', available: 'available', toUpdate: 'run cs -update', caption: 'selected',
  settings: (n: number) => `${n} settings`, overrides: (n: number) => n === 1 ? '1 override' : `${n} overrides`,
  shown: (n: number, of: number) => `${n} of ${of}`, percent: (value: string) => `${value}%`,
  heads: { name: 'Setting', value: 'Value', source: 'Source', applies: 'Applies' },
  // The footer's last line: the keys, the middle one why Enter changes nothing on a locked row.
  hint: { move: '↑↓ move', change: 'Enter change', close: 'Esc close',
    locked: { pinned: 'shell sets it', shellOnly: 'shell only', managed: 'managed', noSession: 'no session name' } satisfies Record<Lock, string> },
  // The reset control at the right end of the keys' line.
  reset: 'reset all…',
  // The bars, a toggle's dots, the rules, the dot, the footer's edge, the masthead's box.
  marks: { selected: '▌', on: '●', off: '○', rule: '─', dot: '·', edge: '▍', box: { top: ['╭', '╮'], bottom: ['╰', '╯'], side: '│' } },
} as const

type RowLine = Extract<Line, { kind: 'row' }>

// Claude Code's theme keys, which the engine resolves to the person's theme
// on each drawing: ink, muted, faint, the soft rules, the session source's
// teal and the machine source's green (blue in the colour-blind themes).
const THEME = { ink: 'text', mut: 'inactive', faint: 'subtle', soft: 'subtle', teal: 'planMode', green: 'success' } as const satisfies Record<string, ThemeKey>

// The brand's accents on every theme: tui/src/theme.rs's amber, and
// install.sh.in's banner, its rust and gold and the wordmark's letters from one to the other.
const rgb = (channels: readonly number[]) => `rgb(${channels.join(',')})`
const BRAND = {
  amber: rgb([246, 154, 0]), rust: rgb([230, 74, 25]), gold: rgb([255, 193, 7]),
  wordmark: [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16], [245, 142, 15], [246, 151, 14],
    [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]].map(rgb),
}

// A run of one style; a line is a row of runs as wide as their texts.
type Run = { text: string } & Pick<TextProps, 'color' | 'weight'>

// The columns right of the name: the value, then from SOURCE_COLUMNS the source and when a change applies.
type Column = { head: string; cells: number; runs: (line: RowLine, cells: number) => Run[] }
const NAME_MIN = 8
const NAME_MOST = 26
const GAP = 2
const MARK_CELLS = 2
const DOT = ` ${WORDS.marks.dot} `
// Wide enough for every value cs names but a list, which the footer shows
// whole; narrow where wide leaves the name less than NAME_MIN.
const VALUE_CELLS = { wide: 14, narrow: 11 }
// The body from which the source and applies columns draw; under it the footer says both.
const SOURCE_COLUMNS = 72
// The search box's lines on the terminal: its border above, the field, its border below.
const BOX_LINES = 3
// cs's `when` for a change that applies at once: the applies cell leaves it out.
const AT_ONCE = 'now'
// The footer's lines of the description and the value line together, at most.
const WRAPPED_MOST = 3
const VALUE: Column = { head: WORDS.heads.value, cells: VALUE_CELLS.wide, runs: (l, cells) => fitRuns(valueRuns(l), cells) }
// A default row leaves source and applies empty, a mod row its applies.
const REST: readonly Column[] = [
  { head: WORDS.heads.source, cells: 7, runs: (l, cells) => l.row.kind === 'mod'
    ? [{ text: fit(l.row.mod.isLocked ? WORDS.locked : WORDS.mod, cells), color: THEME.mut }]
    : l.row.setting.source === 'default' ? [{ text: fit('', cells) }]
      : [{ text: fit(WORDS.from[l.row.setting.source], cells), color: SOURCE_INK[l.row.setting.source] }] },
  { head: WORDS.heads.applies, cells: 10, runs: (l, cells) => l.row.kind === 'setting' && l.row.setting.source !== 'default' && l.row.setting.when !== AT_ONCE
    ? [{ text: fit(l.row.setting.when, cells), color: THEME.mut }] : [{ text: fit('', cells) }] },
]

// A source's colour, the shell's amber as it overrides both files.
const SOURCE_INK: Record<Source, string> = { session: THEME.teal, machine: THEME.green, shell: BRAND.amber, launch: THEME.faint, default: THEME.mut }
const OVERRIDES: ReadonlySet<Source> = new Set(['session', 'machine', 'shell'])

// A percent setting: cs names each one with a label ending in `%`.
const isPercentSetting = (label: string) => label.endsWith('%')

// On (true), off (false), a word the shell pins a flag to, the value or the
// default's name. An off flag is on while unset and off at 1.
function valueOf(row: Row): boolean | string {
  if (row.kind === 'mod') return typeof row.mod.value === 'boolean' ? row.mod.value : shownOf(row.mod.value)
  const s = row.setting
  if (s.edit === 'choice' || s.edit === 'text') return s.value ?? s.fallback ?? WORDS.none
  return s.value === undefined || s.value === '1' ? (s.value === '1') !== turnsOff(s.edit) : s.value
}

// A value unpadded: what the row waits on, muted; else in ink, at its default
// too, `● on` (the dot green), `○ off`, a percentage with its `%`, or the value.
function valueRuns(l: RowLine): Run[] {
  if (l.pending !== undefined) return [{ text: WORDS.pending[l.pending], color: THEME.mut }]
  const value = valueOf(l.row)
  if (value === true) return [{ text: WORDS.marks.on, color: THEME.green }, { text: ` ${WORDS.on}`, color: THEME.ink }]
  if (value === false) return [{ text: `${WORDS.marks.off} ${WORDS.off}`, color: THEME.ink }]
  const isPercent = l.row.kind === 'setting' && isPercentSetting(l.row.setting.label) && /^\d{1,3}$/.test(value) && Number(value) <= 100
  return [{ text: isPercent ? WORDS.percent(value) : value, color: THEME.ink }]
}

// The columns a body this wide draws: the value, the wide cell where it leaves
// the name NAME_MIN; from SOURCE_COLUMNS the source and applies too.
export function columnsFor(columns: number): readonly Column[] {
  if (columns >= SOURCE_COLUMNS) return [VALUE, ...REST]
  const cells = [VALUE_CELLS.wide, VALUE_CELLS.narrow].find(c => columns - MARK_CELLS - GAP - c >= NAME_MIN)
  return cells === undefined ? [] : [{ ...VALUE, cells }]
}

// The name takes what the columns leave, beside the source and applies up to
// NAME_MOST, the last column the rest.
function tableOf(columns: number): { nameCells: number; cols: readonly Column[] } {
  const cols = columnsFor(columns)
  const room = columns - MARK_CELLS - cols.reduce((sum, c) => sum + GAP + c.cells, 0)
  const nameCells = Math.max(1, cols.length > 1 ? Math.min(NAME_MOST, room) : room)
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
  const lock = lockOf(row, hasSelf)
  if (row.kind === 'mod') return lock === undefined ? WORDS.reloads(row.mod.plugin) : WORDS.managed
  const s = row.setting
  if (lock === 'pinned') return WORDS.pinned(s.key, s.value ?? WORDS.none)
  if (lock === 'shellOnly') return WORDS.shellOnly(s.key)
  if (lock === 'noSession') return WORDS.noSession
  return s.ignored ?? s.whenText
}

// The footer's lines: the selected row's, then the keys' line, which the reset
// control ends, or undefined where the body has no room for it.
type Footer = { card: Run[][]; keys: Run[] | undefined }

// The selected row's footer, in `room` lines where it can: the label after a
// caption that says so; what the setting does; its whole value, its source and
// its note; its key; then the keys, the middle one why Enter changes nothing
// on a locked row, cut to leave a cell before the reset control. A short body
// takes back the description and the value line's later lines, then the key,
// then the keys' line; the description gives way to the value line, and keeps
// a line beside it where two are left.
function footerOf(l: RowLine, columns: number, room: number, hasSelf: boolean): Footer {
  const row = l.row
  const from: Run = row.kind === 'mod' ? { text: row.mod.isLocked ? WORDS.locked : WORDS.mod, color: THEME.mut }
    : { text: WORDS.from[row.setting.source], color: SOURCE_INK[row.setting.source] }
  const dot: Run = { text: DOT, color: THEME.mut }
  const width = Math.max(1, columns - MARK_CELLS)
  const describe = row.kind === 'mod' ? row.mod.description : row.setting.describe
  const wrapped = Math.max(1, Math.min(WRAPPED_MOST, room - 3))
  const value = wrapRuns([...valueRuns(l), dot, from, dot, { text: noteOf(row, hasSelf), color: THEME.mut }], width, describe === '' || wrapped < 2 ? wrapped : wrapped - 1)
  const about = describe === '' || value.length === wrapped ? [] : wrapRuns([{ text: describe, color: THEME.ink }], width, wrapped - value.length)
  const lock = lockOf(row, hasSelf)
  const keys = [WORDS.hint.move, lock === undefined ? WORDS.hint.change : WORDS.hint.locked[lock], WORDS.hint.close].join(DOT)
  const card = [clip([{ text: `${WORDS.caption}${DOT}`, color: THEME.mut }, { text: labelOf(row), color: THEME.ink, weight: 'bold' }], width), ...about, ...value,
    ...(room >= 4 ? [[{ text: cut(keyOf(row), width), color: THEME.mut }]] : [])]
  const keysCells = Math.max(1, width - WORDS.reset.length - 1)
  return { card: card.map(line => [{ text: `${WORDS.marks.edge} `, color: THEME.soft }, ...line]),
    keys: room >= 3 ? [{ text: ' '.repeat(MARK_CELLS) }, { text: cut(keys, keysCells).padEnd(keysCells + 1), color: THEME.mut }] : undefined }
}

// The masthead, install.sh.in's banner the body wide: a round box, its top
// border and left side rust and its right side and bottom border gold, around
// the wordmark in bold letter by letter from rust to gold, cs's version, the
// rows, how many a file or the shell overrides (a /config row tells no default) and
// the session name, then, while cs is short of the version an update waits at,
// that version and what installs it. A line starts a cell in from the left side
// and ends at least a cell short of the right, its first part cut to fit and
// the rest dropped from the right.
function mastheadOf(v: PanelView): Run[][] {
  const width = (runs: readonly Run[]) => runs.reduce((sum, run) => sum + run.text.length, 0)
  const room = Math.max(1, v.columns - 4)
  const { box } = WORDS.marks
  const border = ([left, right]: readonly [string, string], color: string): Run[] => [{ text: `${left}${WORDS.marks.rule.repeat(Math.max(0, v.columns - 2))}${right}`, color }]
  const line = (first: readonly Run[], rest: readonly Run[][]): Run[] => {
    const kept = [...clip(first, room), ...rest.slice(0, rest.filter((_, i) => width(first) + width(rest.slice(0, i + 1).flat()) <= room).length).flat()]
    return [{ text: box.side, color: BRAND.rust }, { text: ' ' }, ...kept, { text: ' '.repeat(Math.max(1, v.columns - 3 - width(kept))) }, { text: box.side, color: BRAND.gold }]
  }
  const after = (gap: string, text: string | undefined, color: string): Run[][] => text === undefined ? [] : [[{ text: gap, color: THEME.mut }, { text, color }]]
  const rows = (v.lines ?? []).flatMap(l => l.kind === 'row' ? [l.row] : [])
  const overrides = rows.filter(row => row.kind === 'setting' && OVERRIDES.has(row.setting.source)).length
  const counts = v.lines === undefined ? [] : [...after(DOT, WORDS.settings(rows.length), THEME.ink), ...after(DOT, WORDS.overrides(overrides), THEME.ink)]
  const wordmark = [...WORDS.brand].map((text, i): Run => ({ text, color: BRAND.wordmark[i], weight: 'bold' }))
  const words = line(wordmark, [...after(' ', v.version, THEME.mut), ...counts, ...after(DOT, v.session, THEME.mut)])
  const update = v.update === undefined || v.update === v.version ? []
    : [line([{ text: `${WORDS.cs} `, color: THEME.mut }, { text: v.update, color: BRAND.amber }, { text: ` ${WORDS.available}`, color: THEME.mut }], after(DOT, WORDS.toUpdate, THEME.mut))]
  return [border(box.top, BRAND.rust), words, ...update, border(box.bottom, BRAND.gold)]
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
  const masthead = mastheadOf(v)
  // The masthead, the problems, the notice; the search box, the header, its rule; the no-match line.
  const top = masthead.length + v.problems.length + (notice === undefined ? 0 : 1) + (isListed ? BOX_LINES + 2 : 0) + (noMatch === undefined ? 0 : 1)
  // The footer under the window, its rule then the selected row's lines in what the body leaves past one line of window.
  const footer = selected === undefined ? undefined : footerOf(selected, v.columns, v.bodyRows - top - 2, v.session !== undefined)
  const bottom = footer === undefined ? 0 : 1 + footer.card.length + (footer.keys === undefined ? 0 : 1)
  const shown = windowOf(lines.length, Math.max(0, at), Math.max(1, v.bodyRows - top - bottom))
  const isEmptyAbove = shown.above && rowsIn(lines.slice(0, shown.from)) === 0
  // While the filter holds text, how many rows it shows of all of them.
  const count = v.filter.trim() === '' ? undefined : WORDS.shown(rowsIn(lines), rowsIn(v.lines ?? []))
  return { masthead, isListed, lines, selected, footer, notice, noMatch, count, ...shown, ...(isEmptyAbove ? { from: 0, above: false } : {}) }
}

// The keys of the elements drawPane draws for a view, in the order the focus
// ring walks them (the field, the window's rows, then the reset control; a
// heading is no Button), and the selected row's key, undefined with no rows.
export function ringOf(v: PanelView): { keys: string[]; selected: string | undefined } {
  const { isListed, lines, selected, footer, from, to } = layoutOf(v)
  return { keys: [...(isListed && v.hasField ? [FILTER] : []), ...lines.slice(from, to).flatMap(l => l.kind === 'row' ? [l.row.id] : []),
    ...(footer?.keys === undefined ? [] : [RESET])], selected: selected?.row.id }
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

// The column header in muted bold over the columns, and while the filter holds
// text how many rows it shows, muted, at the right, the heads cut to leave it room.
function headerOf(columns: number, nameCells: number, cols: readonly Column[], count: string | undefined): Run[] {
  const heads = `${fit(`${' '.repeat(MARK_CELLS)}${WORDS.heads.name}`, MARK_CELLS + nameCells)}${cols.map(c => `${' '.repeat(GAP)}${fit(c.head, c.cells)}`).join('')}`
  if (count === undefined) return [{ text: heads, color: THEME.mut, weight: 'bold' }]
  const room = Math.max(1, columns - count.length)
  return [{ text: cut(heads.trimEnd(), room - 1).padEnd(room), color: THEME.mut, weight: 'bold' }, { text: count, color: THEME.mut }]
}

// A group's name in bold ink, then a soft rule to the body's edge.
function headingOf(title: string, columns: number): Run[] {
  const name = cut(title, Math.max(1, columns - 2))
  return [{ text: name, color: THEME.ink, weight: 'bold' }, { text: ` ${WORDS.marks.rule.repeat(Math.max(1, columns - name.length - 1))}`, color: THEME.soft }]
}

// A row's Button holds the whole row after its mark (the focus inverts it all)
// and never shrinks, so every line is measured. Enter in the field sends the
// ring to the rows. The keys' line ends in the reset control's Button.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const { masthead, isListed, lines, selected, footer, notice, noMatch, count, from, to, above, below } = layoutOf(v)
  const { nameCells, cols } = tableOf(v.columns)
  const runs = (line: readonly Run[]) => line.map(({ text, ...style }) => <Text {...style}>{text}</Text>)
  const Input = v.hasField && 'Input' in el ? el.Input : undefined
  return (
    <Box flexDirection="column">
      {masthead.map(line => <Text>{runs(line)}</Text>)}
      {v.problems.map(problem => <Text color={THEME.mut}>{cut(problem, v.columns)}</Text>)}
      {notice !== undefined && <Text color={THEME.mut}>{cut(notice, v.columns)}</Text>}
      {isListed && (Input === undefined ? Array.from({ length: BOX_LINES }, () => <Text>{' '}</Text>) : <Box borderStyle="round" borderColor={THEME.soft} paddingX={1} flexDirection="row" width={v.columns}>
        <Input key={FILTER} placeholder={WORDS.find} value={v.filter} submitLabel={WORDS.toRows} autoFocus onInput={on.filter} onSubmit={text => { on.filter(text); on.toRows() }} /></Box>)}
      {isListed && <Text>{runs(headerOf(v.columns, nameCells, cols, count))}</Text>}
      {isListed && <Text color={THEME.soft}>{WORDS.marks.rule.repeat(v.columns)}</Text>}
      {noMatch !== undefined && <Text color={THEME.mut}>{cut(noMatch, v.columns)}</Text>}
      {above && <Text color={THEME.faint}>{WORDS.above(rowsIn(lines.slice(0, from)))}</Text>}
      {lines.slice(from, to).map(l => l.kind === 'gap' ? <Text>{' '}</Text> : l.kind === 'group' ? <Text>{runs(headingOf(l.title, v.columns))}</Text> : (
        <Box flexDirection="row">
          {runs([l === selected ? { text: `${WORDS.marks.selected} `, color: BRAND.amber } : { text: ' '.repeat(MARK_CELLS) }])}
          <Button key={l.row.id} plain label={labelOf(l.row)} {...(l === selected ? { autoFocus: true } : {})} onPress={() => on.change(l.row.id)}>
            {runs([{ text: fit(labelOf(l.row), nameCells), color: THEME.ink, ...(l === selected ? { weight: 'bold' } as const : {}) },
              ...cols.flatMap(c => [{ text: ' '.repeat(GAP) }, ...c.runs(l, c.cells)])])}
          </Button>
        </Box>
      ))}
      {below && <Text color={THEME.faint}>{WORDS.below(rowsIn(lines.slice(to)))}</Text>}
      {footer !== undefined && <Text color={THEME.soft}>{WORDS.marks.rule.repeat(v.columns)}</Text>}
      {footer?.card.map(line => <Text>{runs(line)}</Text>)}
      {footer?.keys !== undefined && <Box flexDirection="row">{runs(footer.keys)}<Button key={RESET} plain label={WORDS.reset} onPress={on.reset}>
        <Text color={THEME.mut}>{WORDS.reset}</Text></Button></Box>}
    </Box>
  )
}
