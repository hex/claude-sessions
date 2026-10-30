/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: Draws the cs-panel pane from a view: the strip of keys for the selected row, the problem line, and a window of rows fitted to the body.
// ABOUTME: Pure over its view and exported with its word tables, so the design lab draws a fixture without the engine.
import type { EngineInterface, RenderElement } from 'claude-code'
import type { Action, Pending, Row, SessionName } from './sessions'

declare const h: any
declare const Fragment: any

// Everything drawPane needs: the rows (undefined until cs first answers), the
// selection, why the list is stale, and the room the Pane props give.
export type PanelView = {
  rows: readonly Row[] | undefined
  // The selected row by name; one no longer listed falls back to the first.
  selected: SessionName | undefined
  problem: string | undefined
  // Pane props: bodyColumns, scroll.bodyRows, isFocused.
  columns: number
  bodyRows: number
  hasKeys: boolean
}

export type Handlers = {
  // A row pressed (Enter, click).
  select: (name: SessionName) => void
  // A strip key pressed, for the selected row.
  act: (action: Action, name: SessionName) => void
}

// The strip's keys, one per Action, in strip order. Three fixed letters, so no
// two Buttons ever share a hotkey (two clash, later wins), however many rows.
export const ACTIONS: Record<Action, { hotkey: string; verb: string }> = {
  open: { hotkey: 'o', verb: 'open' },
  mail: { hotkey: 'm', verb: 'mail' },
  retire: { hotkey: 'r', verb: 'retire' },
}

// Every word the pane draws itself.
export const WORDS = {
  reading: 'asking cs for the sessions…',
  none: 'no sessions under the sessions root',
  live: 'live',
  idle: 'idle',
  locked: 'locked',
  unread: (n: number) => `${n} mail`,
  features: (n: number) => `${n} feat`,
  above: (n: number) => `+${n} above`,
  below: (n: number) => `+${n} below`,
  pending: { opening: 'opening', mailing: 'mailing', checking: 'checking', retiring: 'retiring' } satisfies Record<Pending, string>,
  close: 'Esc: close',
  takeKeys: 'ctrl+x tab: keys',
} as const

// The columns right of the name, in the order a narrow body drops them from
// the end. Each is drawn cut and padded to its cells, so every row is exactly
// as wide as every other.
type Column = { cells: number; text: (row: Row) => string }
const NAME_MIN = 8
const GAP = 2
// `› ` on the selected row, two spaces elsewhere.
const MARK_CELLS = 2
// Between the strip's keys, and before its hint.
const KEY_GAP = 3
const COLUMNS: readonly Column[] = [
  { cells: 8, text: r => r.pending ? WORDS.pending[r.pending] : r.session.live ? WORDS.live : WORDS.idle },
  { cells: 4, text: r => r.session.context === undefined ? '' : `${r.session.context}%` },
  { cells: 7, text: r => r.session.unread === undefined ? WORDS.locked : r.session.unread === 0 ? '' : WORDS.unread(r.session.unread) },
  { cells: 7, text: r => r.session.features === 0 ? '' : WORDS.features(r.session.features) },
]

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

// `text` cut to `cells` with `…` and padded to them. Every text the panel
// fits is a SessionName, a task out of one, or its own ASCII words, so one
// UTF-16 unit is one cell (`└` and `…` included).
function fit(text: string, cells: number): string {
  return text.length > cells ? `${text.slice(0, Math.max(0, cells - 1))}…` : text.padEnd(cells)
}

// The rows a body of `room` lines draws of `count`: all when they fit, else a
// window that keeps the selected row `at` inside with one row of margin each
// side where the room allows, so the focus ring always has a drawn row to Tab
// onto and the window follows it. The `+N above` / `+N below` lines it needs
// are inside `room`.
export function windowOf(count: number, at: number, room: number): { from: number; to: number } {
  if (count <= room) return { from: 0, to: count }
  if (room < 3) return { from: at, to: at + 1 }
  // Rows drawn beside one count line: the window touching either end.
  const edge = room - 1
  if (at <= edge - 2) return { from: 0, to: edge }
  if (at >= count - edge + 1) return { from: count - edge, to: count }
  const shown = room - 2
  const from = at - Math.floor((shown - 1) / 2)
  return { from, to: from + shown }
}

// The strip for the selected row, fitted widest first: `o: open beta   m: mail
// beta   Esc: close`, then without the hint, then verbs alone (`o: open   m:
// mail`); a body narrower than that stacks the verbs one key per line. A
// plain Button draws `<hotkey>: <label>`, so each key is 3 + label cells and
// the fit is exact.
type Key = { action: Action; label: string }
export function stripFor(row: Row | undefined, columns: number, hasKeys: boolean): { keys: Key[]; hint: string | undefined; stacked: boolean } {
  const hint = hasKeys ? WORDS.close : WORDS.takeKeys
  const actions = row?.actions ?? []
  const targeted = actions.map(action => ({ action, label: `${ACTIONS[action].verb} ${action === 'retire' ? row?.session.feature?.task : row?.session.name}` }))
  const verbs = actions.map(action => ({ action, label: ACTIONS[action].verb }))
  const width = (keys: Key[], withHint: boolean) => [...keys.map(k => 3 + k.label.length), ...(withHint ? [hint.length] : [])]
    .reduce((sum, cells, i) => sum + cells + (i === 0 ? 0 : KEY_GAP), 0)
  if (width(targeted, true) <= columns) return { keys: targeted, hint, stacked: false }
  if (width(targeted, false) <= columns) return { keys: targeted, hint: undefined, stacked: false }
  if (width(verbs, false) <= columns) return { keys: verbs, hint: undefined, stacked: false }
  return { keys: verbs, hint: undefined, stacked: true }
}

// A row's name cell: `└ task` under its base, the full name otherwise.
function nameText(row: Row): string {
  return row.depth === 1 && row.session.feature !== undefined ? `└ ${row.session.feature.task}` : row.session.name
}

// The pane body, top to bottom: the strip (first, so a long list never pushes
// the keys off the pane), the problem line, `+N above`, the rows, `+N below`.
// Each row is one plain Button keyed `row:<name>` whose children are the
// marker, the name cut to its cells (bold for this session) and one dim Text
// of the padded columns: a Button never shrinks, so every row is measured to
// `columns` before it is drawn. The selected row carries autoFocus, so a pane
// opened with focus starts the ring there and the strip's keys have a target.
export function drawPane(v: PanelView, el: ReturnType<EngineInterface['ui']['resolve']>, on: Handlers): RenderElement {
  const { Box, Text, Button } = el
  const rows = v.rows ?? []
  const at = Math.max(0, rows.findIndex(r => r.session.name === v.selected))
  const selected = rows[at]
  const strip = stripFor(selected, v.columns, v.hasKeys)
  const cols = columnsFor(v.columns)
  const nameCells = Math.max(1, v.columns - MARK_CELLS - cols.reduce((sum, c) => sum + GAP + c.cells, 0))
  const notice = v.rows === undefined ? WORDS.reading : rows.length === 0 ? WORDS.none : undefined
  const chrome = (strip.stacked ? strip.keys.length : 1) + (v.problem === undefined ? 0 : 1) + (notice === undefined ? 0 : 1)
  const { from, to } = windowOf(rows.length, at, Math.max(1, v.bodyRows - chrome))
  return (
    <Box flexDirection="column">
      <Box flexDirection={strip.stacked ? 'column' : 'row'} columnGap={KEY_GAP}>
        {strip.keys.map(k => (
          <Button key={`act:${k.action}`} plain hotkey={ACTIONS[k.action].hotkey} label={k.label}
            onPress={() => { if (selected !== undefined) on.act(k.action, selected.session.name) }} />
        ))}
        {strip.hint !== undefined && <Text dimColor>{strip.hint}</Text>}
      </Box>
      {v.problem !== undefined && <Text dimColor wrap="truncate-end">{v.problem}</Text>}
      {notice !== undefined && <Text dimColor wrap="truncate-end">{notice}</Text>}
      {from > 0 && <Text dimColor>{WORDS.above(from)}</Text>}
      {rows.slice(from, to).map(r => (
        <Button key={`row:${r.session.name}`} plain label={r.session.name} {...(r === selected ? { autoFocus: true } : {})}
          onPress={() => on.select(r.session.name)}>
          {r === selected ? '› ' : '  '}
          <Text weight={r.isSelf ? 'bold' : undefined}>{fit(nameText(r), nameCells)}</Text>
          <Text dimColor>{cols.map(c => `${' '.repeat(GAP)}${fit(c.text(r), c.cells)}`).join('')}</Text>
        </Button>
      ))}
      {to < rows.length && <Text dimColor>{WORDS.below(rows.length - to)}</Text>}
    </Box>
  )
}
