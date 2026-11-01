// ABOUTME: Engine test-kit tests for the cs-panel mod: cs's porcelain and the /config rows as settings rows, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from design.md's rules, config-verb.md's reply shapes and the golden porcelain (test/golden.ts), never from the code under test.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { ConfigRow, On, PaneOpenArgs } from 'claude-code'

import { GOLDEN } from './golden'
import { drawPane, ringBack, ringOf, type PanelView } from '../hooks/draw'
import { COMMANDS, LOGS, PROBLEMS, REPLIES, TOASTS } from '../hooks/register'
import { filterLines, linesOf, modRowsOf, parseSettings, type RowId, type Setting } from '../hooks/settings'

// What `$.config.list()` answers in these tests: the five rows cs's mods
// declare, an engine row and a row of a cs-* plugin that is not one of them.
const CS = { plugin: 'cs', tier: 'user' } as const
const MOD_ROWS: ConfigRow[] = [
  { key: 'theme', label: 'Theme', kind: 'choice', value: 'dark', options: ['dark', 'light'], provider: { plugin: 'engine', tier: 'core' }, isLocked: false },
  { key: 'cs.bandPrompts', label: 'cs: Band: prompt bars', kind: 'boolean', value: false, provider: CS, isLocked: false },
  { key: 'cs.bandPrompt', label: 'cs: Band: named prompt', kind: 'choice', value: 'latest', options: ['latest', 'read'], provider: CS, isLocked: false },
  { key: 'cs.bandBars', label: 'cs: Band: most bars', kind: 'number', value: 10, provider: CS, isLocked: false },
  { key: 'cs-feed.digest', label: 'Feed digest', kind: 'boolean', value: true, provider: { plugin: 'cs-feed', tier: 'user' }, isLocked: false },
  { key: 'cs-update.showReleaseNotes', label: 'cs: Release notes pane', kind: 'boolean', value: true, provider: { plugin: 'cs-update', tier: 'user' }, isLocked: false },
  { key: 'cs-mermaid.drawDiagrams', label: 'cs: Draw mermaid diagrams', kind: 'boolean', value: true, provider: { plugin: 'cs-mermaid', tier: 'user' }, isLocked: false },
]
const LOCKED: ConfigRow[] = MOD_ROWS.map(r => r.key === 'cs-mermaid.drawDiagrams' ? { ...r, isLocked: true } : r)

function settingsOf(stdout: string): Setting[] {
  const parsed = parseSettings(stdout)
  if ('unreadable' in parsed) throw new Error(`the fixture is unreadable: ${parsed.unreadable}`)
  return parsed
}

// The golden with `key`'s record changed at the fields named by their place in
// the record from 1: the value is 9, the source 10, the description 12.
function edited(key: string, fields: Record<number, string>, porcelain = GOLDEN): string {
  const line = porcelain.split('\n').find(l => l.startsWith(`${key}\t`))
  if (line === undefined) throw new Error(`the porcelain has no ${key}`)
  return porcelain.replace(line, line.split('\t').map((field, i) => fields[i + 1] ?? field).join('\t'))
}

test('the golden porcelain parses to its 41 settings in cs\'s order, cs\'s words kept and `-` read as none', () => {
  const settings = settingsOf(GOLDEN)
  expect(settings.length).toBe(41)
  expect(settings[0]?.key).toBe('CS_STATUSLINE_DISABLE')
  expect(settings[40]?.key).toBe('CS_NARRATIVE_KEEP_BYTES')
  expect(settings[1]).toEqual({ key: 'CS_STATUSLINE_LAYOUT', group: 'Status line', label: 'Layout', edit: 'choice', choices: ['quiet', 'band', 'capsules'],
    fallback: 'quiet', when: 'now', whenText: 'applies at the next repaint', value: 'band', source: 'machine', ignored: undefined,
    describe: 'How the status line looks: plain text, one full-width band of colour, or capsules.' })
  expect(settings[3]).toEqual({ key: 'CS_STATUSLINE_BAND', group: 'Status line', label: 'Band colour', edit: 'text', choices: [], fallback: 'session', when: 'now',
    whenText: 'applies at the next repaint', value: undefined, source: 'default', ignored: 'machine line 4: CS_STATUSLINE_BAND=magenta: not a palette name, brand, periwinkle, session, none or r;g;b',
    describe: 'The colour of the band and the session chip; session gives each session its own colour.' })
  expect(settings.find(s => s.key === 'CS_NO_MAIL_WAKE')).toEqual({ key: 'CS_NO_MAIL_WAKE', group: 'Mail', label: 'Wake on mail', edit: 'flagoff', choices: [],
    fallback: 'off', when: 'now', whenText: 'applies when the next turn ends', value: undefined, source: 'session', ignored: undefined,
    describe: 'Unread mail from another session takes a turn, so the exchange goes on without you typing.' })
  expect(settings.find(s => s.key === 'CS_NO_FUNCTION_HOOKS')).toMatchObject({ label: 'Mods', edit: 'shelloff', value: undefined, source: 'default' })
})

// cs's readers take any word for a flag the shell exports (`-n` tests), and
// cs prints that word with source shell: the pane draws it as it is and offers
// no key, and keeps every other row.
test('a flag the shell pins to a word other than 1 parses and draws that word, and its footer says the environment wins', async ($, on) => {
  const pinned = edited('CS_NERD_FONTS', { 9: '0', 10: 'shell' })
  expect(pinned).not.toBe(GOLDEN)
  const settings = settingsOf(pinned)
  expect(settings.length).toBe(41)
  expect(settings.find(s => s.key === 'CS_NERD_FONTS')).toMatchObject({ value: '0', source: 'shell' })
  const { lines } = await drawer($, on)(viewOf({ selected: 'cs:CS_NERD_FONTS', lines: linesOf(modRowsOf(MOD_ROWS), settings, new Map(), 'Mods') }))
  expect(cardIn(lines)).toEqual(['▍ selected · Nerd Font glyphs', '▍ Shows Nerd Font icons in cs banners and session lists;…',
    '▍ 0 · shell · CS_NERD_FONTS=0 in your environment wins;', '▍ unset it there to change it here', '▍ CS_NERD_FONTS', hint('shell sets it'), scopeLine()])
  expect(lines.map(line => line.trimEnd())).toContain(at58('Nerd Font glyphs', '0', true))
})

// cs's twelfth field is the setting's description sentence, never `-`. An
// `off` edit is a flag whose 1 turns off what its label names.
test('a record of twelve fields carries its description; flagoff and shelloff parse as the flags they are', () => {
  const record = 'CS_SCOPE_DISABLE\tPrompts\tScope grounding\tflagoff\t-\toff\tnow\tapplies at your next prompt\t1\tsession\t-'
  expect(settingsOf(`${record}\tAdds a short summary of the relevant code to each prompt.\n`)).toEqual([{ key: 'CS_SCOPE_DISABLE', group: 'Prompts', label: 'Scope grounding',
    edit: 'flagoff', choices: [], fallback: 'off', when: 'now', whenText: 'applies at your next prompt', value: '1', source: 'session', ignored: undefined,
    describe: 'Adds a short summary of the relevant code to each prompt.' }])
  expect(settingsOf(`${record.replace('\tflagoff\t', '\tshelloff\t')}\tLets a launch load mods.\n`).map(s => s.edit)).toEqual(['shelloff'])
})

test('one line outside the record refuses the whole answer, naming that line; an empty answer is refused too', () => {
  const good = 'CS_NO_TASK_TOOLS\tLaunch\tTask tools\tflagoff\t-\toff\tlaunch\tapplies at the next launch\t-\tdefault\t-\tGives Claude its task list tools on every model.'
  const fields = good.split('\t')
  const bad = [
    fields.slice(0, 11).join('\t'),
    `${good}\t-`,
    [...fields.slice(0, 11), '-'].join('\t'),
    [...fields.slice(0, 11), ''].join('\t'),
    good.replace('\tflagoff\t-\t', '\tflagoff\ta,b\t'),
    good.replace('CS_NO_TASK_TOOLS', 'cs_no_task_tools'),
    good.replace('\tflagoff\t', '\ttoggle\t'),
    good.replace('\tdefault\t', '\tenv\t'),
    good.replace('\tTask tools\t', '\t\t'),
    good.replace('\tflagoff\t-\t', '\tchoice\t-\t'),
    good.replace('\tflagoff\t-\t', '\ttext\ta,b\t'),
  ]
  expect(settingsOf(good).length).toBe(1)
  for (const line of bad) expect(parseSettings(`${good}\n${line}\n`)).toEqual({ unreadable: line })
  expect(parseSettings('')).toEqual({ unreadable: '' })
})

test('the mod rows are the rows of cs, cs-update and cs-mermaid only: an engine row and another cs-* plugin\'s row are left out', () => {
  expect(modRowsOf(MOD_ROWS).map(m => [m.key, m.plugin, m.kind])).toEqual([
    ['cs.bandPrompts', 'cs', 'boolean'], ['cs.bandPrompt', 'cs', 'choice'], ['cs.bandBars', 'cs', 'number'],
    ['cs-update.showReleaseNotes', 'cs-update', 'boolean'], ['cs-mermaid.drawDiagrams', 'cs-mermaid', 'boolean'],
  ])
})

// ── Drawing ──────────────────────────────────────────────────────────────

const NOOP = { change: () => {}, pick: () => {}, type: () => {}, submit: () => {}, filter: () => {}, toRows: () => {}, reset: () => {}, confirm: () => {}, keep: () => {}, scope: () => {} }

// The text one line of the drawing shows on the terminal, from the plain-data
// tree: a Button draws its children, or its label when it has none, after
// `<hotkey>: ` when it is plain with a hotkey (the 2.1.316 terminal's Button),
// an Input its label, then its text or else its placeholder, and a row Box
// puts its columnGap between its children and its paddingX either side of them.
// A Select draws its first line (selectOf).
type Node = { type: string; props: Record<string, unknown>; children?: unknown[] }
function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  const n = node as Node
  const children = n.children ?? []
  if (n.type === 'Input') return `${String(n.props.label ?? '')}${String(n.props.value || n.props.placeholder || '')}`
  if (n.type === 'Select') return selectOf(n).head
  if (n.type === 'Button') {
    const shown = children.length === 0 ? String(n.props.label) : children.map(textOf).join('')
    return n.props.plain === true && n.props.hotkey !== undefined ? `${n.props.hotkey}: ${shown}` : shown
  }
  if (n.type !== 'Box') return children.map(textOf).join('')
  const pad = ' '.repeat(Number(n.props.paddingX ?? 0))
  return `${pad}${children.map(textOf).join(' '.repeat(Number(n.props.columnGap ?? 0)))}${pad}`
}

// A Select as the 2.1.316 terminal draws it: its label and `: ` when it has
// one, the option it holds (`none` without one) and ▾; focused it is open, ▴
// in the ▾'s place and under it, two cells in, the eight options that end at
// the one it holds or start the list, then `… N more` for those hidden below.
// The kit marks no focus, so the test reads the ring's autoFocus mark as it.
function selectOf(n: Node): { head: string; open: string[] } {
  const options = n.props.options as { value: string; label?: string }[]
  const at = Math.max(0, options.findIndex(o => o.value === n.props.value))
  const held = options[at]?.value === n.props.value ? options[at] : undefined
  const isOpen = n.props.autoFocus === true
  const first = Math.max(0, at - 7), shown = options.slice(first, first + 8), hidden = options.length - first - shown.length
  return { head: `${n.props.label === undefined ? '' : `${String(n.props.label)}: `}${held === undefined ? 'none' : held.label ?? held.value} ${isOpen ? '▴' : '▾'}`,
    open: isOpen ? [...shown.map(o => `  ${o.label ?? o.value}`), ...(hidden > 0 ? [`  … ${hidden} more`] : [])] : [] }
}

// Every element of a drawn tree, outermost first in document order.
function nodesOf(node: unknown): Node[] {
  if (typeof node === 'string') return []
  const n = node as Node
  return [n, ...(n.children ?? []).flatMap(nodesOf)]
}

// The row Box holding the Button keyed `key`.
function rowOf(tree: unknown, key: string): Node {
  const row = nodesOf(tree).find(n => n.type === 'Box' && (n.children ?? []).some(c => (c as Node).type === 'Button' && (c as Node).props.key === key))
  if (row === undefined) throw new Error(`no row Box holds a Button keyed ${key} in the drawing`)
  return row
}

// The Text runs of the row whose Button is keyed `key`, left to right (the
// marker, the label inside the Button, each run of the columns), each its
// text and the style props the brief names.
function runsOf(tree: unknown, key: string): { text: string; color?: unknown; dimColor?: unknown; weight?: unknown }[] {
  const leaves = (node: unknown): unknown[] => typeof node !== 'string' && ((node as Node).type === 'Button' || ((node as Node).children ?? []).some(c => typeof c !== 'string'))
    ? ((node as Node).children ?? []).flatMap(leaves) : [node]
  return (rowOf(tree, key).children ?? []).flatMap(leaves).map(child => {
    const props = typeof child === 'string' ? {} : (child as Node).props ?? {}
    return { text: textOf(child), ...(['color', 'dimColor', 'weight'] as const).reduce((style, k) => props[k] === undefined ? style : { ...style, [k]: props[k] }, {}) }
  })
}

// The body's lines top to bottom, one per child of its column Box, but a Box
// with a border, which the terminal (Ink) draws three lines tall: the border
// above, its line between a side either side, the border below, as wide as
// the Box, and a row Box holding a Select, whose open options fall under its
// first line in its column. The kit lays nothing out, so this is the test's
// model of the terminal, and it knows the round border alone.
function bodyLines(tree: unknown): string[] {
  return ((tree as Node).children ?? []).flatMap(child => {
    const { borderStyle, width } = typeof child === 'string' ? {} : (child as Node).props ?? {}
    const kids = typeof child === 'string' ? [] : (child as Node).children ?? []
    const select = kids.findIndex(c => (c as Node).type === 'Select')
    if (select >= 0) {
      const lead = ' '.repeat(kids.slice(0, select).map(textOf).join('').length)
      return [textOf(child), ...selectOf(kids[select] as Node).open.map(line => `${lead}${line}`)]
    }
    if (borderStyle === undefined) return [textOf(child)]
    if (borderStyle !== 'round' || typeof width !== 'number') throw new Error(`the test draws a round border across a width, not ${String(borderStyle)} across ${String(width)}`)
    return [`╭${'─'.repeat(width - 2)}╮`, `│${textOf(child).padEnd(width - 2)}│`, `╰${'─'.repeat(width - 2)}╯`]
  })
}

function fixtureProps(v: PanelView) {
  return { title: 'cs', isFocused: true, bodyColumns: v.columns, placement: 'inline', scroll: { offset: 0, bodyRows: v.bodyRows }, view: {} } as const
}

// Draws views through the test's own render hook, as the design lab does; with
// `key`, also the label of the Button drawn under that key.
function drawer($: Engine, on: On): (view: PanelView, key?: string) => Promise<{ lines: string[]; label: unknown; tree: unknown }> {
  let view: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => {
    if (view === undefined) throw new Error('no view to draw')
    return drawPane(view, $.ui.resolve(e), NOOP)
  })
  return async (next, key) => {
    view = next
    const ui = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props: fixtureProps(next) })
    const tree = await ui.drawn()
    const lines = bodyLines(tree)
    const label = key === undefined ? undefined : (await ui.find({ key }))?.props.label
    await ui.unmount()
    return { lines, label, tree }
  }
}

// The golden list, or one of its records changed; with a session name (alpha,
// the world's CLAUDE_SESSION_NAME) unless `hasSelf` is false.
function viewOf(over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[]; porcelain?: string } = {}): PanelView {
  const { hasSelf = true, rows = MOD_ROWS, porcelain = GOLDEN, ...rest } = over
  return { lines: linesOf(modRowsOf(rows), settingsOf(porcelain), new Map(), 'Mods'), selected: undefined, problems: [], columns: 58, bodyRows: 90, filter: '', hasField: true,
    session: hasSelf ? 'alpha' : undefined, version: VERSION, update: undefined, chooser: undefined, scope: 'session', ...rest }
}

// The row Boxes of a drawing, each holding a Button keyed by its RowId, and
// the rows as the terminal shows them.
const rowBoxes = (tree: unknown) => nodesOf(tree).filter(n => n.type === 'Box' && (n.children ?? []).some(c => (c as Node).type === 'Button' && /^(cs|mod):/.test(String((c as Node).props.key))))
const rowsOf = (tree: unknown) => rowBoxes(tree).map(textOf)
// A round box as the terminal shows it, the body wide: its border above, each
// line of text one cell in and at least one short of the right side, its
// border below. The masthead draws install.sh.in's banner so, and the search
// box holds its text or else its placeholder so.
const boxed = (columns: number, ...texts: string[]) => [`╭${'─'.repeat(columns - 2)}╮`, ...texts.map(text => `│ ${text.padEnd(columns - 4)} │`), `╰${'─'.repeat(columns - 2)}╯`]
const field = (columns: number, text = 'search settings') => boxed(columns, text)
// The masthead's lines with no update pending: its border, the words, its border.
const MASTHEAD_LINES = 3
// Where the search box starts, or the empty lines that stand in its place.
const boxAt = (lines: string[]) => lines.findIndex((line, i) => i >= MASTHEAD_LINES && (line.trim() === '' || line.startsWith('╭')))
// The lines between the masthead and the search box: the problem lines and
// the reading notice, or every line after the masthead with no box.
const aboveIn = (lines: string[]) => boxAt(lines) < 0 ? lines.slice(MASTHEAD_LINES) : lines.slice(MASTHEAD_LINES, boxAt(lines))
// The lines under the pane's last rule the body wide, the footer's: the
// selected row's lines, then the keys' line.
const cardIn = (lines: string[]) => lines.slice(lines.findLastIndex(line => /^─+$/.test(line)) + 1)
// The footer's last line, the body wide: two cells in, the keys, the middle
// one Enter's or why Enter changes nothing on the row, cut to leave a cell
// before `reset all…` at the right end.
const hint = (middle = 'Enter change', columns = 58) => `  ${cut(`↑↓ move · ${middle} · Esc close`, columns - 13).padEnd(columns - 12)}reset all…`
const cut = (text: string, cells: number) => text.length > cells ? `${text.slice(0, cells - 1)}…` : text
// The footer's scope line under a session name, under the keys' line: two
// cells in, `writes to: `, then the two scope Buttons, ● on the file writes
// go to. A line that cannot hold the lead leaves it out, and one that cannot
// hold both Buttons cuts each to the same width.
const scopeLine = (columns = 58, chosen: 'session' | 'machine' = 'session') => {
  const buttons = [`${chosen === 'session' ? '●' : '○'} this session`, `${chosen === 'machine' ? '●' : '○'} this machine`]
  if (columns >= 43) return `  writes to: ${buttons.join('  ')}`
  if (columns >= 32) return `  ${buttons.join('  ')}`
  return `  ${buttons.map(b => cut(b, Math.floor((columns - 4) / 2))).join('  ')}`
}
// A line of a chooser as the terminal shows it: four cells in, its choices
// with ` · ` between them.
const options = (...labels: string[]) => `    ${labels.join(' · ')}`
// A chooser's picker as the terminal shows it four cells in: the value it
// holds and ▾, or with the ring on it ▴ and every option under it two cells
// further in.
const picked = (value: string, open?: readonly string[]) => open === undefined ? [`    ${value} ▾`] : [`    ${value} ▴`, ...open.map(option => `      ${option}`)]
// cs's choices of the rewrite provider, in its order.
const PROVIDERS = ['claude', 'claude-api', 'openai', 'openai-api', 'gemini', 'gemini-api', 'grok', 'xai']
// The keys' line while reset all… asks to confirm: two cells in, what the
// reset removes cut to leave its two Buttons room, then ` · confirm · keep`.
const confirming = (text: string, columns = 58) => `  ${cut(text, columns - 19)} · confirm · keep`
// The lines of the chooser open under the selected row: those right under it
// that start four cells in or further.
const chooserIn = (lines: string[]) => {
  const at = lines.findIndex(line => line.startsWith('▌ '))
  const end = lines.findIndex((line, i) => i > at && !/^ {4,}\S/.test(line))
  return lines.slice(at + 1, end < 0 ? lines.length : end).map(line => line.trimEnd())
}
// A row as the terminal shows it at the dock's 58 columns, trimmed: below 72
// columns the value is the only column, so the name takes the 40 cells it
// leaves, then a gap of 2 and the value in 14 cells, cut with ….
const at58 = (label: string, value: string, isSelected = false) => `${isSelected ? '▌' : ' '} ${label.padEnd(40)}  ${cut(value, 14)}`.trimEnd()
// The column header's rule and the footer's, the body wide.
const soft = (columns: number) => '─'.repeat(columns)
// A group's headline: its name, one space and a rule to the body's edge.
const group = (name: string, columns = 58) => `${name} ${'─'.repeat(columns - name.length - 1)}`

// Claude Code's theme keys the pane draws in, which the engine resolves to
// the person's theme, then what draws the same on every theme: tui/src/theme.rs's
// amber, and install.sh.in's banner, its RUST and GOLD (lines 25 and 26) and
// the wordmark's letters from one to the other (line 62).
const COLOURS = { ink: 'text', mut: 'inactive', faint: 'subtle', soft: 'subtle', teal: 'planMode', green: 'success', amber: 'rgb(246,154,0)',
  rust: 'rgb(230,74,25)', gold: 'rgb(255,193,7)',
  wordmark: [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16],
    [245, 142, 15], [246, 151, 14], [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]].map(([r, g, b]) => `rgb(${r},${g},${b})`) }

// What the world's cs prints for `cs -version`, and the version it holds.
const VERSION = '2026.10.11'

// The masthead's words and lines and the column header with its rule at the
// dock's 58 columns: 46 settings of which the golden's five files and shell
// override (the launch's Theme is none); the session name does not fit beside them.
const WORDS_AT_58 = 'claude-sessions 2026.10.11 · 46 settings · 5 overrides'
const MASTHEAD_AT_58 = boxed(58, WORDS_AT_58)
// The masthead's words at 80 columns, the session name too.
const WORDS_AT_80 = 'claude-sessions 2026.10.11 · 46 settings · 5 overrides · alpha'
const HEAD_AT_58 = [`  ${'Setting'.padEnd(40)}  Value`, soft(58)]
// The column header at 72 columns and up: the source and applies columns
// return, the name has 26 cells and applies the rest.
const headAt = (columns: number) => `  ${'Setting'.padEnd(26)}  ${'Value'.padEnd(14)}  ${'Source'.padEnd(7)}  ${'Applies'.padEnd(columns - 55)}`

// design.md's columns at the dock's 58-column body: the name and the value,
// under each group's headline with an empty line above every group but the
// first; the golden's values through them, worked out apart from the mod. A
// toggle reads ● on or ○ off, an off flag ● on while unset, a percent its
// number and %.
const GOLDEN_AT_58 = [
  group('Mods'),
  at58('Band: prompt bars', '○ off', true),
  at58('Band: named prompt', 'latest'),
  at58('Band: most bars', '10'),
  at58('Release notes pane', '● on'),
  at58('Draw mermaid diagrams', '● on'),
  '',
  group('Status line'),
  at58('Status line', '● on'),
  at58('Layout', 'band'),
  at58('Segments', 'logo,session,notes,mail,git,model,ctx,limits'),
  at58('Band colour', 'session'),
  at58('Width in columns', 'measured'),
  at58('Frame columns', '6'),
  at58('Context warn %', '50%'),
  at58('Context critical %', '65%'),
  at58('Usage refresh', '● on'),
  at58('Subagent rows', '● on'),
  '',
  group('Prompts'),
  at58('Scope grounding', '○ off'),
  at58('Scope trace', '● on'),
  at58('Scope scan budget (ms)', '1500'),
  at58('Objective capture', '● on'),
  at58('Date reminder', '● on'),
  at58('Clarifying questions', '● on'),
  '',
  group('Rotation'),
  at58('Context warning %', '40%'),
  at58('Rotate button from %', 'the warn %'),
  at58('Rotation nudge %', '65%'),
  at58('Rotate on its own past %', '80%'),
  at58('Wake after /clear', '● on'),
  at58('Wake delay (s)', '2'),
  '',
  group('Rewriter (ctrl+g)'),
  at58('Provider', 'claude'),
  at58('Model', 'per provider'),
  at58('Timeout (s)', '25'),
  at58('Progress', 'screen'),
  at58('Rewrite (ctrl+g)', '● on'),
  '',
  group('Terminal'),
  at58('Theme', 'dark'),
  at58('Background r;g;b', 'detected'),
  at58('iTerm2 features', '● on'),
  at58('Nerd Font glyphs', '○ off'),
  '',
  group('Mail'),
  at58('Wake on mail', '● on'),
  at58('Wakes in a row', '5'),
  '',
  group('Launch'),
  at58('Task tools', '● on'),
  at58('Update check', '● on'),
  at58('Mods', '● on'),
  '',
  group('Queue'),
  at58('Stops after failures', '5'),
  at58('Stops past context %', '85%'),
  at58('Stops past 5h limit %', '85%'),
  '',
  group('Narrative'),
  at58('Budget (bytes)', '131072'),
  at58('Tail kept (bytes)', '65536'),
]
// The lines the golden draws at 80 rows and up: 46 rows, 10 headlines and the
// 9 empty lines above all but the first.
const GOLDEN_LINES = 65

test('the golden porcelain and the mod rows draw under the masthead, the search box and the column header, Mods first, each row exactly the body wide, and the first row\'s footer under a rule', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  expect(lines.map(line => line.trimEnd())).toEqual([
    ...MASTHEAD_AT_58,
    ...field(58),
    ...HEAD_AT_58,
    ...GOLDEN_AT_58,
    soft(58),
    '▍ selected · Band: prompt bars',
    '▍ ○ off · mod · changing it reloads cs (an armed rotation',
    '▍ countdown starts over)',
    '▍ cs.bandPrompts',
    hint('Enter flip'),
    scopeLine(),
  ])
  const rows = rowsOf(tree)
  expect(rows.length).toBe(46)
  expect(rows.filter(line => line.length !== 58)).toEqual([])
  // A percent setting is known by its label's `%`, not by a list of keys: a
  // percent set in a file draws its % whichever key it is.
  const BUTTON_AT_50 = edited('CS_ROTATE_BUTTON_CTX', { 9: '50', 10: 'session' })
  expect(settingsOf(BUTTON_AT_50).find(s => s.key === 'CS_ROTATE_BUTTON_CTX')?.value).toBe('50')
  expect(rowsOf((await draw(viewOf({ porcelain: BUTTON_AT_50 }))).tree).map(row => row.trimEnd())).toContain(at58('Rotate button from %', '50%'))
  // With no mod rows, the first group follows the column header's rule.
  const bare = (await draw(viewOf({ rows: [] }))).lines.map(line => line.trimEnd())
  expect([bare.slice(3, 9), cardIn(bare)]).toEqual([[...field(58), ...HEAD_AT_58, group('Status line')],
    ['▍ selected · Status line', '▍ Draws the line under the prompt with the session,', '▍ branch, model, context and usage limits.',
      '▍ ● on · default · applies at the next repaint', '▍ CS_STATUSLINE_DISABLE', hint('Enter flip'), scopeLine()]])
  // Under a two-line description and a one-line value the chrome above the
  // rows is eight lines, the masthead's three, the search box's three, the
  // column header and its rule, and below them eight, the footer's rule, the
  // label, the description, the value line, the key, the keys and the scope line.
  const layout = (await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.map(line => line.trimEnd())
  expect([...layout.slice(0, 9), ...layout.slice(-9)]).toEqual([...MASTHEAD_AT_58, ...field(58), ...HEAD_AT_58, group('Mods'),
    at58('Tail kept (bytes)', '65536'), soft(58), '▍ selected · Layout', '▍ How the status line looks: plain text, one full-width', '▍ band of colour, or capsules.',
    '▍ band · machine · applies at the next repaint', '▍ CS_STATUSLINE_LAYOUT', hint(), scopeLine()])
  expect(layout.length).toBe(8 + GOLDEN_LINES + 8)
  expect((await draw({ ...viewOf(), lines: undefined })).lines.map(line => line.trimEnd()))
    .toEqual([...boxed(58, 'claude-sessions 2026.10.11 · alpha'), 'asking cs for its settings…'])
  expect((await draw({ ...viewOf(), lines: undefined, problems: ['cs -config list exited 1: Error: boom'] })).lines.map(line => line.trimEnd()))
    .toEqual([...boxed(58, 'claude-sessions 2026.10.11 · alpha'), 'cs -config list exited 1: Error: boom'])
})

test('the footer says why Enter changes nothing on a row, and its keys\' line names the lock: the shell pins it, it changes from a shell only, a managed setting owns it, or this session\'s file holds it under no session name; and why cs skipped a file\'s value', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[] } = {}) => cardIn((await draw(viewOf({ selected, ...over }))).lines)
  expect(await card('cs:CS_STATUSLINE_BAND')).toEqual(['▍ selected · Band colour', '▍ The colour of the band and the session chip; session…',
    '▍ session · default · machine line 4:', '▍ CS_STATUSLINE_BAND=magenta: not a palette name, brand,…', '▍ CS_STATUSLINE_BAND', hint(), scopeLine()])
  expect(await card('cs:CS_STATUSLINE_FRAME')).toEqual(['▍ selected · Frame columns', '▍ Columns the prompt frame takes from the measured width,…',
    '▍ 6 · shell · CS_STATUSLINE_FRAME=6 in your environment', '▍ wins; unset it there to change it here', '▍ CS_STATUSLINE_FRAME', hint('shell sets it'), scopeLine()])
  expect(await card('cs:CS_NO_FUNCTION_HOOKS')).toEqual(['▍ selected · Mods', '▍ Lets a launch load mods, the cs band and settings pane…',
    '▍ ● on · default · change it from a shell: cs -config set', '▍ CS_NO_FUNCTION_HOOKS 1 loads no mod from the next…', '▍ CS_NO_FUNCTION_HOOKS', hint('shell only'), scopeLine()])
  expect(await card('cs:CS_NO_FUNCTION_HOOKS', { columns: 150 })).toEqual(['▍ selected · Mods',
    '▍ Lets a launch load mods, the cs band and settings pane among them; off, none loads.',
    '▍ ● on · default · change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 loads no mod from the next launch, this panel included',
    '▍ CS_NO_FUNCTION_HOOKS', hint('shell only', 150), scopeLine(150)])
  expect(await card('mod:cs-mermaid.drawDiagrams', { rows: LOCKED })).toEqual(['▍ selected · Draw mermaid diagrams', '▍ ● on · locked · a managed setting owns it',
    '▍ cs-mermaid.drawDiagrams', hint('managed'), scopeLine()])
  expect((await draw(viewOf({ rows: LOCKED, columns: 80 }))).lines.map(line => line.trimEnd())).toContain(`  ${'Draw mermaid diagrams'.padEnd(26)}  ${'● on'.padEnd(14)}  locked`)
  expect(await card('cs:CS_STATUSLINE_CTX_WARN', { hasSelf: false })).toEqual(['▍ selected · Context warn %', '▍ Context use at which the gauge turns to its warning…',
    "▍ 50% · session · this session's file sets it, and this", '▍ conversation has no cs session name to write it with', '▍ CS_STATUSLINE_CTX_WARN', hint('no session name')])
  expect(await card('cs:CS_STATUSLINE_CTX_WARN')).toEqual(['▍ selected · Context warn %', '▍ Context use at which the gauge turns to its warning', '▍ colour.',
    '▍ 50% · session · applies at the next repaint', '▍ CS_STATUSLINE_CTX_WARN', hint(), scopeLine()])
})

// The golden with Segments set in this machine's file to its whole default.
const SEGMENTS = GOLDEN.replace('logo,session,notes,mail,git,model,ctx,limits\tnow\tapplies at the next repaint\t-\tdefault\t',
  'logo,session,notes,mail,git,model,ctx,limits\tnow\tapplies at the next repaint\tlogo,session,notes,mail,git,model,ctx,limits\tmachine\t')

test('the footer names the selected row, then its whole value, where it comes from and when a change applies, wrapped by words to the body, then its key', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: Partial<PanelView> & { porcelain?: string } = {}) => cardIn((await draw(viewOf({ selected, ...over }))).lines)
  expect(await card('cs:CS_SCOPE_DISABLE')).toEqual(['▍ selected · Scope grounding', '▍ Adds a short summary of the relevant code to each prompt', '▍ that asks for code work.',
    '▍ ○ off · session · applies at your next prompt', '▍ CS_SCOPE_DISABLE', hint(), scopeLine()])
  expect(await card('cs:CS_CTX_WARN_CTX', { columns: 24 })).toEqual(['▍ selected · Context wa…', '▍ Context use at which…', '▍ 40% · default ·', '▍ applies when the next…',
    '▍ CS_CTX_WARN_CTX', hint('Enter change', 24), scopeLine(24)])
  expect(await card('cs:CS_TERM_THEME')).toEqual(['▍ selected · Theme', '▍ Whether cs draws for a light or a dark terminal; unset,', '▍ cs detects it at launch.',
    '▍ dark · launch · applies at the next repaint', '▍ CS_TERM_THEME', hint(), scopeLine()])
  expect(await card('mod:cs.bandPrompt')).toEqual(['▍ selected · Band: named prompt', '▍ latest · mod · changing it reloads cs (an armed rotation',
    '▍ countdown starts over)', '▍ cs.bandPrompt', hint(), scopeLine()])
  expect(await card('mod:cs-update.showReleaseNotes')).toEqual(['▍ selected · Release notes pane', '▍ ● on · mod · changing it reloads cs-update', '▍ cs-update.showReleaseNotes',
    hint('Enter flip'), scopeLine()])
  expect(SEGMENTS).not.toBe(GOLDEN)
  const segments = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_SEGMENTS', porcelain: SEGMENTS, columns: 40 }))
  expect(cardIn(segments.lines)).toEqual(['▍ selected · Segments', '▍ Which items the status line shows, in…', '▍ logo,session,notes,mail,git,model,ctx,',
    '▍ limits · machine · applies at the nex…', '▍ CS_STATUSLINE_SEGMENTS', hint('Enter change', 40), scopeLine(40)])
  expect(segments.lines.map(line => line.trimEnd())).toContain(`▌ ${'Segments'.padEnd(22)}  logo,session,…`)
})

// cs's description of a setting, the porcelain's twelfth field, and a /config
// row's own: the footer's second line, in ink. With the value line they take
// three lines at most; a description that does not fit is cut with …, and it
// keeps a line beside a value line that would take all three.
test('the footer\'s second line is what the setting does, in ink, cut with … where it and the value line pass three lines', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))
  const parts = ((tree as Node).children ?? []) as Node[]
  const about = parts.find(part => textOf(part).startsWith('▍ How'))
  expect((about?.children ?? []).map(run => [textOf(run), (run as Node).props?.color])).toEqual([['▍ ', COLOURS.soft], ['How the status line looks: plain text, one full-width', COLOURS.ink]])
  const long = edited('CS_STATUSLINE_LAYOUT', { 12: 'How the status line looks: plain text, one full-width band of colour, or capsules, each a segment of its own drawn apart.' })
  expect(cardIn((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', porcelain: long }))).lines).slice(1, 3))
    .toEqual(['▍ How the status line looks: plain text, one full-width', '▍ band of colour, or capsules, each a segment of its own…'])
  const band = edited('CS_STATUSLINE_BAND', { 12: 'The colour of the band and the session chip.' })
  expect(cardIn((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_BAND', porcelain: band }))).lines)).toEqual(['▍ selected · Band colour',
    '▍ The colour of the band and the session chip.', '▍ session · default · machine line 4:', '▍ CS_STATUSLINE_BAND=magenta: not a palette name, brand,…',
    '▍ CS_STATUSLINE_BAND', hint(), scopeLine()])
  const described = MOD_ROWS.map(r => r.key === 'cs.bandBars' ? { ...r, description: 'How many prompts the band draws as bars.' } : r)
  expect(cardIn((await draw(viewOf({ selected: 'mod:cs.bandBars', rows: described }))).lines)).toEqual(['▍ selected · Band: most bars',
    '▍ How many prompts the band draws as bars.', '▍ 10 · mod · changing it reloads cs (an armed rotation', '▍ countdown starts over)', '▍ cs.bandBars', hint(), scopeLine()])
})

test('every row, headline, line of the masthead, the card and the field fits 24, 40, 58, 60 and 80 columns, and 46 rows in 15 lines keep the selected row drawn', async ($, on) => {
  const draw = drawer($, on)
  const ids: RowId[] = [...modRowsOf(MOD_ROWS).map(m => `mod:${m.key}` as const), ...settingsOf(GOLDEN).map(s => `cs:${s.key}` as const)]
  expect(ids.length).toBe(46)
  for (const columns of [24, 40, 58, 60, 80]) {
    for (const selected of ids) {
      const { lines, label, tree } = await draw(viewOf({ columns, bodyRows: 15, selected }), selected)
      const rows = rowsOf(tree)
      expect(rows.filter(row => row.length !== columns), `rows at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => / ─+$/.test(line) && !line.startsWith('─') && line.length !== columns), `headlines at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => line.length > columns), `lines past ${columns} with ${selected}`).toEqual([])
      expect([lines.slice(0, MASTHEAD_LINES).map(line => line.length), lines.filter(line => /^─+$/.test(line))], `the masthead and the rules at ${columns}`)
        .toEqual([[columns, columns, columns], [soft(columns), soft(columns)]])
      expect(lines.length <= 15, `${lines.length} lines in 15 at ${columns} with ${selected}`).toBe(true)
      expect(rows.filter(row => row.startsWith('▌ ')).length, `the selected row at ${columns} with ${selected}`).toBe(1)
      expect(label, `${selected} drawn at ${columns}`).not.toBe(undefined)
    }
  }
  // At 24 by 17 the footer takes all it can: the value line wraps into two
  // lines and gives up its last words, the description keeps one line, the
  // key, the keys' line and the scope line follow, and the window keeps the
  // selected row alone. By 13 the description, the key and the keys' line go
  // and the value line keeps one line, so the scope line stays.
  const narrow = async (bodyRows: number) => (await draw(viewOf({ columns: 24, bodyRows, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.map(line => line.trimEnd())
  expect(await narrow(17)).toEqual([...boxed(24, 'claude-sessions'), ...field(24), '  Setting    Value', soft(24), '▌ Layout     band',
    soft(24), '▍ selected · Layout', '▍ How the status line…', '▍ band · machine ·', '▍ applies at the next…', '▍ CS_STATUSLINE_LAYOUT', hint('Enter change', 24), scopeLine(24)])
  expect(await narrow(13)).toEqual([...boxed(24, 'claude-sessions'), ...field(24), '  Setting    Value', soft(24), '▌ Layout     band',
    soft(24), '▍ selected · Layout', '▍ band · machine ·…', scopeLine(24)])
  // With no session name there is no scope line, and at 13 the keys' line stays.
  expect((await draw(viewOf({ columns: 24, bodyRows: 13, selected: 'cs:CS_STATUSLINE_LAYOUT', hasSelf: false }))).lines.slice(-1)).toEqual([hint('Enter change', 24)])
  // 65 lines (46 rows, 10 headlines, the 9 empty lines above all but the
  // first) in the 11 lines of 19 the masthead, the search box and the column
  // header leave: a footer of a one-line value and a two-line description
  // takes eight and leaves the window 3, a mod row's two-line value and no
  // description seven and 4. The window holds the selected row and the line
  // either side where it can, or the lines at the end it touches, and +N
  // counts the rows it leaves out; no rows above draws the lines above instead.
  const at = async (selected: RowId, bodyRows = 19) => (await draw(viewOf({ columns: 58, bodyRows, selected }))).lines.map(line => line.trimEnd())
  const top = [...MASTHEAD_AT_58, ...field(58), ...HEAD_AT_58]
  expect(await at('cs:CS_STATUSLINE_LAYOUT')).toEqual([...top,
    '+6 above',
    at58('Layout', 'band', true),
    '+39 below',
    soft(58), '▍ selected · Layout', '▍ How the status line looks: plain text, one full-width', '▍ band of colour, or capsules.',
    '▍ band · machine · applies at the next repaint', '▍ CS_STATUSLINE_LAYOUT', hint(), scopeLine(),
  ])
  expect(await at('mod:cs.bandPrompts')).toEqual([...top,
    group('Mods'),
    at58('Band: prompt bars', '○ off', true),
    at58('Band: named prompt', 'latest'),
    '+44 below',
    soft(58), '▍ selected · Band: prompt bars', '▍ ○ off · mod · changing it reloads cs (an armed rotation', '▍ countdown starts over)', '▍ cs.bandPrompts', hint('Enter flip'),
    scopeLine(),
  ])
  expect(await at('cs:CS_NO_FUNCTION_HOOKS')).toEqual([...top,
    '+40 above',
    at58('Mods', '● on', true),
    '+5 below',
    soft(58), '▍ selected · Mods', '▍ Lets a launch load mods, the cs band and settings pane…', '▍ ● on · default · change it from a shell: cs -config set',
    '▍ CS_NO_FUNCTION_HOOKS 1 loads no mod from the next…', '▍ CS_NO_FUNCTION_HOOKS', hint('shell only'), scopeLine(),
  ])
  expect(await at('cs:CS_NARRATIVE_KEEP_BYTES')).toEqual([...top,
    '+44 above',
    at58('Budget (bytes)', '131072'),
    at58('Tail kept (bytes)', '65536', true),
    soft(58), '▍ selected · Tail kept (bytes)', '▍ How much of the newest narrative stays in the live file', '▍ when it rotates.',
    '▍ 65536 · default · applies when the next turn ends', '▍ CS_NARRATIVE_KEEP_BYTES', hint(), scopeLine(),
  ])
  // Two lines more give the window five: the selected row, one either side,
  // and the counts, or the headline that stands for +0 above.
  expect((await at('cs:CS_STATUSLINE_DISABLE', 21)).slice(8, -8)).toEqual(['+5 above', group('Status line'), at58('Status line', '● on', true),
    at58('Layout', 'band'), '+39 below'])
  expect((await at('cs:CS_STATUSLINE_LAYOUT', 21)).slice(8, -8)).toEqual(['+5 above', at58('Status line', '● on'), at58('Layout', 'band', true),
    at58('Segments', 'logo,session,notes'), '+38 below'])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 21, selected: 'cs:CS_STATUSLINE_DISABLE' })).keys)
    .toEqual(['filter', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT', 'reset', 'scope:session', 'scope:machine'])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 19, selected: 'mod:cs.bandPrompts', hasField: false })).keys)
    .toEqual(['mod:cs.bandPrompts', 'mod:cs.bandPrompt', 'reset', 'scope:session', 'scope:machine'])
})

test('a drawing that moves the element the ring was put on sends the ring back to that key, else to the selected row; one that moves nothing sends it nowhere', () => {
  const short = (selected: RowId, filter = '') => ringOf(viewOf({ columns: 58, bodyRows: 21, selected, filter }))
  // The ring walks the field, then the window's rows, then the footer's reset
  // control and the scope line's two Buttons.
  expect(short('cs:CS_STATUSLINE_LAYOUT')).toEqual({ keys: ['filter', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT', 'cs:CS_STATUSLINE_SEGMENTS', 'reset',
    'scope:session', 'scope:machine'], selected: 'cs:CS_STATUSLINE_LAYOUT' })
  expect(ringOf(viewOf()).keys.length).toBe(50)
  // The field holds the first place in every drawing, so typing moves nothing.
  expect(ringBack({ key: 'filter', at: 0 }, short('cs:CS_STATUSLINE_LAYOUT', 'scope'))).toBe(undefined)
  // LAYOUT keeps the third place under DISABLE's window, which starts at the group's headline.
  expect(ringBack({ key: 'cs:CS_STATUSLINE_LAYOUT', at: 2 }, short('cs:CS_STATUSLINE_DISABLE'))).toBe(undefined)
  // SEGMENTS is not drawn under DISABLE: the ring goes to the selected row.
  expect(ringBack({ key: 'cs:CS_STATUSLINE_SEGMENTS', at: 3 }, short('cs:CS_STATUSLINE_DISABLE'))).toBe('cs:CS_STATUSLINE_DISABLE')
  // Filtered to `named`, Band: named prompt moves from the third place to the
  // second, and the ring goes back to it there.
  expect(short('mod:cs.bandPrompt', 'named').keys).toEqual(['filter', 'mod:cs.bandPrompt', 'reset', 'scope:session', 'scope:machine'])
  expect(ringBack({ key: 'mod:cs.bandPrompt', at: 2 }, short('mod:cs.bandPrompt', 'named'))).toBe('mod:cs.bandPrompt')
  // The reset control moves with the rows above it, and the ring goes back to it.
  expect(ringBack({ key: 'reset', at: 4 }, short('cs:CS_STATUSLINE_LAYOUT'))).toBe(undefined)
  expect(ringBack({ key: 'reset', at: 4 }, short('mod:cs.bandPrompt', 'named'))).toBe('reset')
  // A filter that matches nothing draws no footer, so no reset control: the ring goes to no row.
  expect(short('cs:CS_STATUSLINE_LAYOUT', 'zzz')).toEqual({ keys: ['filter'], selected: undefined })
  // A filter that hides the row the ring was on sends it to the first row shown, now selected.
  expect(short('cs:CS_STATUSLINE_DISABLE', 'scope')).toEqual({ keys: ['filter', 'cs:CS_SCOPE_DISABLE', 'cs:CS_SCOPE_TRACE_DISABLE', 'cs:CS_SCOPE_BUDGET_MS', 'reset',
    'scope:session', 'scope:machine'], selected: 'cs:CS_SCOPE_DISABLE' })
  expect(ringBack({ key: 'cs:CS_STATUSLINE_DISABLE', at: 1 }, short('cs:CS_STATUSLINE_DISABLE', 'scope'))).toBe('cs:CS_SCOPE_DISABLE')
  // A row the ring is headed for holds no place yet: the drawing puts it there.
  expect(ringBack({ key: 'cs:CS_STATUSLINE_LAYOUT', at: -1 }, short('cs:CS_STATUSLINE_LAYOUT'))).toBe('cs:CS_STATUSLINE_LAYOUT')
})

test('the filter keeps the rows whose label, key or group holds the text in any case, each under its group, and drops a group left empty', () => {
  const lines = viewOf().lines ?? []
  const shown = (text: string) => filterLines(lines, text).map(l => l.kind === 'group' ? l.title : l.row.id)
  expect(shown('scope')).toEqual(['Prompts', 'cs:CS_SCOPE_DISABLE', 'cs:CS_SCOPE_TRACE_DISABLE', 'cs:CS_SCOPE_BUDGET_MS'])
  expect(shown('REWRITER')).toEqual(['Rewriter (ctrl+g)', 'cs:CS_REWRITE_PROVIDER', 'cs:CS_REWRITE_MODEL', 'cs:CS_REWRITE_TIMEOUT', 'cs:CS_REWRITE_PROGRESS', 'cs:CS_REWRITE_DISABLE'])
  expect(shown('nerd_fonts')).toEqual(['Terminal', 'cs:CS_NERD_FONTS'])
  expect(shown('mods')).toEqual(['Mods', 'mod:cs.bandPrompts', 'mod:cs.bandPrompt', 'mod:cs.bandBars', 'mod:cs-update.showReleaseNotes', 'mod:cs-mermaid.drawDiagrams',
    'Launch', 'cs:CS_NO_FUNCTION_HOOKS'])
  expect(shown('zzz')).toEqual([])
  expect(shown('').length).toBe(56)
  expect(shown('  ')).toEqual(shown(''))
})

// The column header's line while the filter holds text: the heads, cut where
// they leave the count no room, and how many rows the filter shows of all 46
// at the right edge.
const counted = (columns: number, heads: string, count: string) => `${cut(heads, columns - count.length - 1).padEnd(columns - count.length)}${count}`

test('filtered, the masthead keeps its counts, the column header says how many rows show of all of them, the window counts the rows shown, and no match says so with no footer', async ($, on) => {
  const draw = drawer($, on)
  const lines = async (filter: string, columns = 58) => (await draw(viewOf({ bodyRows: 19, filter, columns }))).lines.map(line => line.trimEnd())
  expect(await lines('status')).toEqual([...MASTHEAD_AT_58, ...field(58, 'status'), counted(58, HEAD_AT_58[0] ?? '', '10 of 46'), soft(58),
    group('Status line'),
    at58('Status line', '● on', true),
    '+9 below',
    soft(58), '▍ selected · Status line', '▍ Draws the line under the prompt with the session,', '▍ branch, model, context and usage limits.',
    '▍ ● on · default · applies at the next repaint', '▍ CS_STATUSLINE_DISABLE', hint('Enter flip'), scopeLine(),
  ])
  expect(await lines('zzz')).toEqual([...MASTHEAD_AT_58, ...field(58, 'zzz'), counted(58, HEAD_AT_58[0] ?? '', '0 of 46'), soft(58), 'no setting matches zzz'])
  expect((await lines('context', 24))[6]).toBe('  Setting    Va… 4 of 46')
  const { tree } = await draw(viewOf({ filter: 'scope' }))
  const header = (((tree as Node).children ?? []) as Node[]).find(part => textOf(part).startsWith('  Setting'))
  expect((header?.children ?? []).map(run => [textOf(run), (run as Node).props?.color, (run as Node).props?.weight]))
    .toEqual([[HEAD_AT_58[0]?.padEnd(51), COLOURS.mut, 'bold'], ['3 of 46', COLOURS.mut, undefined]])
})

// ── The look ─────────────────────────────────────────────────────────────

const LIGHT = GOLDEN.replace('applies at the next repaint\tdark\tlaunch', 'applies at the next repaint\tlight\tlaunch')
// The golden with three settings set (Layout by the machine's file, Scope
// grounding and Wake on mail by this session's), and with none: each other
// record a file or the shell sets put back to the default.
const THREE = GOLDEN.replace('\t6\tshell\t', '\t-\tdefault\t').replace('\t50\tsession\t', '\t-\tdefault\t')
const NONE = THREE.replace('\tband\tmachine\t', '\t-\tdefault\t').replace('\t1\tsession\t', '\t-\tdefault\t').replace('when the next turn ends\t-\tsession\t', 'when the next turn ends\t-\tdefault\t')
// The golden with Layout alone set, by the machine's file.
const ONE = THREE.replace('\t1\tsession\t', '\t-\tdefault\t').replace('when the next turn ends\t-\tsession\t', 'when the next turn ends\t-\tdefault\t')
// The golden with No wake after /clear set in this session's file.
const CLEARED = edited('CS_NO_ROTATION_WAKE', { 9: '1', 10: 'session' })

// The masthead's lines in a drawing, each a list of its runs' text, colour and weight.
const mastheadIn = (tree: unknown, count = MASTHEAD_LINES) => (((tree as Node).children ?? []) as Node[]).slice(0, count)
  .map(line => (line.children ?? []).map(run => [textOf(run), (run as Node).props?.color, (run as Node).props?.weight].filter(v => v !== undefined)))

test('the masthead is the wordmark, cs\'s version, how many settings, how many a file or the shell overrides and the session name in install.sh.in\'s round box the body wide, dropped from the right where they do not fit', async ($, on) => {
  const draw = drawer($, on)
  const words = async (over: Partial<PanelView> & { hasSelf?: boolean; porcelain?: string }) => {
    const columns = over.columns ?? 58
    const masthead = (await draw(viewOf(over))).lines.slice(0, MASTHEAD_LINES)
    const text = (masthead[1] ?? '').slice(2, -2).trimEnd()
    expect(masthead, `the masthead at ${columns}`).toEqual(boxed(columns, text))
    return text
  }
  const set = (porcelain: string) => settingsOf(porcelain).filter(s => s.source === 'session' || s.source === 'machine' || s.source === 'shell').map(s => s.key)
  expect([set(THREE), set(ONE), set(NONE)]).toEqual([['CS_STATUSLINE_LAYOUT', 'CS_SCOPE_DISABLE', 'CS_NO_MAIL_WAKE'], ['CS_STATUSLINE_LAYOUT'], []])
  for (const [porcelain, overrides] of [[THREE, '3 overrides'], [ONE, '1 override'], [NONE, '0 overrides']] as const) {
    expect(await words({ porcelain, columns: 80 })).toBe(`claude-sessions 2026.10.11 · 46 settings · ${overrides} · alpha`)
    expect(await words({ porcelain, columns: 58 })).toBe(`claude-sessions 2026.10.11 · 46 settings · ${overrides}`)
    expect(await words({ porcelain, columns: 40 })).toBe('claude-sessions 2026.10.11')
    expect(await words({ porcelain, columns: 24 })).toBe('claude-sessions')
  }
  expect(await words({ columns: 80, hasSelf: false })).toBe('claude-sessions 2026.10.11 · 46 settings · 5 overrides')
  expect(await words({ columns: 80, session: 'a-very-long-session-name-for-this-test' })).toBe('claude-sessions 2026.10.11 · 46 settings · 5 overrides')
  expect(await words({ columns: 16 })).toBe('claude-sess…')
  // Until cs tells its version, the masthead goes on without it.
  expect(await words({ columns: 58, version: undefined })).toBe('claude-sessions · 46 settings · 5 overrides · alpha')
})

test('the masthead draws install.sh.in\'s banner on no background: its top border and left side rust, its right side and bottom border gold, the wordmark bold letter by letter from rust to gold, the counts in ink and the version, the dots and the session muted', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ columns: 80 }))
  const wordmark = [...'claude-sessions'].map((letter, i) => [letter, COLOURS.wordmark[i], 'bold'])
  const dot = [' · ', COLOURS.mut]
  expect(mastheadIn(tree)).toEqual([
    [[`╭${'─'.repeat(78)}╮`, COLOURS.rust]],
    [['│', COLOURS.rust], [' '], ...wordmark, [' ', COLOURS.mut], ['2026.10.11', COLOURS.mut], dot, ['46 settings', COLOURS.ink], dot, ['5 overrides', COLOURS.ink],
      dot, ['alpha', COLOURS.mut], [' '.repeat(80 - 3 - WORDS_AT_80.length)], ['│', COLOURS.gold]],
    [[`╰${'─'.repeat(78)}╯`, COLOURS.gold]],
  ])
  expect(nodesOf(tree).filter(n => n.props?.backgroundColor !== undefined).map(n => n.type)).toEqual([])
  // Cut to fit, the wordmark ends in … in the colour of the letter it stands for.
  expect(mastheadIn((await draw(viewOf({ columns: 16 }))).tree)[1]?.slice(11, 13)).toEqual([['s', COLOURS.wordmark[9], 'bold'], ['s…', COLOURS.wordmark[10], 'bold']])
})

test('with an update pending, a second line in the masthead says which cs is available, its version amber and the rest muted, and what to run, dropped from the right; none when the masthead\'s version is that one', async ($, on) => {
  const draw = drawer($, on)
  const lines = async (over: Partial<PanelView>) => (await draw(viewOf({ update: '2026.10.12', ...over }))).lines
  expect((await lines({})).slice(0, 4)).toEqual(boxed(58, WORDS_AT_58, 'cs 2026.10.12 available · run cs -update'))
  expect((await lines({ columns: 40 })).slice(0, 4)).toEqual(boxed(40, 'claude-sessions 2026.10.11', 'cs 2026.10.12 available'))
  expect((await lines({ columns: 24 })).slice(0, 4)).toEqual(boxed(24, 'claude-sessions', 'cs 2026.10.12 avail…'))
  expect((await lines({ version: undefined })).slice(0, 4)).toEqual(boxed(58, 'claude-sessions · 46 settings · 5 overrides · alpha', 'cs 2026.10.12 available · run cs -update'))
  const { tree } = await draw(viewOf({ update: '2026.10.12' }))
  expect(mastheadIn(tree, 4).slice(2)).toEqual([
    [['│', COLOURS.rust], [' '], ['cs ', COLOURS.mut], ['2026.10.12', COLOURS.amber], [' available', COLOURS.mut], [' · ', COLOURS.mut], ['run cs -update', COLOURS.mut],
      [' '.repeat(58 - 3 - 40)], ['│', COLOURS.gold]],
    [[`╰${'─'.repeat(56)}╯`, COLOURS.gold]],
  ])
  // The pane goes on under it a line lower: under a one-line value and a
  // two-line description the chrome is nine lines above the rows and eight
  // below, in a body that holds every row.
  const layout = await lines({ selected: 'cs:CS_STATUSLINE_LAYOUT', bodyRows: 90 })
  expect([layout.slice(4, 7), layout.length]).toEqual([field(58), 9 + GOLDEN_LINES + 8])
  // cs already at the pending version, as after an update installed from this
  // conversation, draws no update line; nothing pending draws none.
  expect((await draw(viewOf({ version: '2026.10.12', update: '2026.10.12' }))).lines.slice(0, 3)).toEqual(boxed(58, 'claude-sessions 2026.10.12 · 46 settings · 5 overrides'))
  expect((await draw(viewOf())).lines.slice(0, 3)).toEqual(MASTHEAD_AT_58)
})

test('the rows sit under a column header in muted bold, then a soft rule the body wide: below 72 columns Setting and Value, the name taking all the value leaves; from 72 Source and Applies too, a name 26 cells and Applies the rest', async ($, on) => {
  const draw = drawer($, on)
  const head = async (over: Partial<PanelView>) => {
    const parts = ((await draw(viewOf(over))).tree as Node).children as Node[]
    const at = parts.findIndex(part => textOf(part).startsWith('  Setting'))
    if (at < 0) throw new Error(`no column header in the drawing: ${parts.map(textOf).slice(0, 6).join(' | ')}`)
    return [parts[at], parts[at + 1]].map(part => part?.props?.color === undefined
      ? (part?.children ?? []).map(run => [textOf(run), (run as Node).props?.color, (run as Node).props?.weight]) : [[textOf(part), part.props.color, part.props.weight]])
  }
  expect(await head({ columns: 58 })).toEqual([[[`  ${'Setting'.padEnd(40)}  ${'Value'.padEnd(14)}`, COLOURS.mut, 'bold']], [[soft(58), COLOURS.soft, undefined]]])
  const text = async (columns: number) => (await head({ columns }))[0]?.[0]?.[0]
  expect(await text(80)).toBe(headAt(80))
  expect(await text(72)).toBe(headAt(72))
  expect(await text(71)).toBe(`  ${'Setting'.padEnd(53)}  ${'Value'.padEnd(14)}`)
  expect(await text(40)).toBe(`  ${'Setting'.padEnd(22)}  ${'Value'.padEnd(14)}`)
  expect(await text(24)).toBe(`  ${'Setting'.padEnd(9)}  ${'Value'.padEnd(11)}`)
  const row = async (columns: number) => textOf(rowOf((await draw(viewOf({ columns, porcelain: CLEARED }))).tree, 'cs:CS_NO_ROTATION_WAKE'))
  expect(await row(80)).toBe(`  ${'Wake after /clear'.padEnd(26)}  ${'○ off'.padEnd(14)}  session  ${'/clear'.padEnd(25)}`)
  expect(await row(72)).toBe(`  ${'Wake after /clear'.padEnd(26)}  ${'○ off'.padEnd(14)}  session  ${'/clear'.padEnd(17)}`)
  expect(await row(58)).toBe(`  ${'Wake after /clear'.padEnd(40)}  ${'○ off'.padEnd(14)}`)
})

test('a group\'s headline is its name in bold ink, then one space and a soft ─ rule to the body\'s edge; an empty line sits above every group but the first', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  const headline = (drawn: unknown, name: string) => nodesOf(drawn).filter(n => n.type === 'Text' && textOf(n).startsWith(`${name} ─`))
    .map(n => (n.children ?? []).map(run => [textOf(run), (run as Node).props.color, (run as Node).props.weight]))
  expect(headline(tree, 'Prompts')).toEqual([[['Prompts', COLOURS.ink, 'bold'], [` ${'─'.repeat(50)}`, COLOURS.soft, undefined]]])
  const groups = ['Mods', 'Status line', 'Prompts', 'Rotation', 'Rewriter (ctrl+g)', 'Terminal', 'Mail', 'Launch', 'Queue', 'Narrative']
  expect(groups.map(name => lines[lines.indexOf(group(name)) - 1]?.trimEnd())).toEqual([soft(58), '', '', '', '', '', '', '', '', ''])
  // At 24 columns: 7 cells of name and 16 of rule; 17 and 6.
  const at24 = (await draw(viewOf({ columns: 24 }))).lines
  expect([at24.includes(`Prompts ${'─'.repeat(16)}`), at24.includes(`Rewriter (ctrl+g) ${'─'.repeat(6)}`)]).toEqual([true, true])
})

test('a toggle draws ● on, the dot in green, or ○ off, both in ink; a word the shell pins a flag to draws as it is', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf())
  expect(runsOf(tree, 'cs:CS_SCOPE_TRACE_DISABLE').slice(2, 5)).toEqual([{ text: '  ' }, { text: '●', color: COLOURS.green }, { text: ' on'.padEnd(13), color: COLOURS.ink }])
  expect(runsOf(tree, 'cs:CS_SCOPE_DISABLE').slice(2, 4)).toEqual([{ text: '  ' }, { text: '○ off'.padEnd(14), color: COLOURS.ink }])
  expect(runsOf(tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '○ off'.padEnd(14), color: COLOURS.ink }])
  expect(runsOf(tree, 'mod:cs-update.showReleaseNotes').slice(3, 5)).toEqual([{ text: '●', color: COLOURS.green }, { text: ' on'.padEnd(13), color: COLOURS.ink }])
  const pinned = await draw(viewOf({ porcelain: edited('CS_NERD_FONTS', { 9: '0', 10: 'shell' }) }))
  expect(runsOf(pinned.tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '0'.padEnd(14), color: COLOURS.ink }])
})

test('a percent row draws its number and a %, in ink at the default too; a percent whose value is no number draws as it is; no gauge is drawn', async ($, on) => {
  const draw = drawer($, on)
  const at58s = await draw(viewOf())
  expect(at58s.lines.map(line => line.trimEnd())).toContain(at58('Context warning %', '40%'))
  expect(runsOf(at58s.tree, 'cs:CS_CTX_WARN_CTX').slice(3)).toEqual([{ text: '40%'.padEnd(14), color: COLOURS.ink }])
  expect(runsOf(at58s.tree, 'cs:CS_STATUSLINE_CTX_WARN').slice(3)).toEqual([{ text: '50%'.padEnd(14), color: COLOURS.ink }])
  expect(at58s.lines.map(line => line.trimEnd())).toContain(at58('Rotate button from %', 'the warn %'))
  expect(at58s.lines.map(line => line.trimEnd())).toContain(at58('Width in columns', 'measured'))
  expect(runsOf((await draw(viewOf({ columns: 24 }))).tree, 'cs:CS_CTX_WARN_CTX').slice(1)).toEqual([{ text: 'Context …', color: COLOURS.ink }, { text: '  ' }, { text: '40%'.padEnd(11), color: COLOURS.ink }])
  const at80 = await draw(viewOf({ columns: 80, selected: 'cs:CS_STATUSLINE_CTX_WARN' }))
  expect([...at58s.lines, ...at80.lines].filter(line => /[▰▱]/.test(line))).toEqual([])
})

test('every value draws in ink, at its default too, and only the source says what overrides it: from 72 columns a default row leaves source and applies empty, a set row draws its source in that source\'s colour and applies, muted, unless it is now; below 72 the row ends at its value', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ columns: 80 }))
  const blank = [{ text: '  ' }, { text: ' '.repeat(7) }, { text: '  ' }, { text: ' '.repeat(25) }]
  expect(runsOf(tree, 'cs:CS_NERD_FONTS').slice(3)).toEqual([{ text: '○ off'.padEnd(14), color: COLOURS.ink }, ...blank])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_COLS').slice(3)).toEqual([{ text: 'measured'.padEnd(14), color: COLOURS.ink }, ...blank])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_SEGMENTS').slice(3)).toEqual([{ text: 'logo,session,…', color: COLOURS.ink }, ...blank])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(3)).toEqual([{ text: 'band'.padEnd(14), color: COLOURS.ink }, { text: '  ' }, { text: 'machine', color: COLOURS.green }, { text: '  ' }, { text: ' '.repeat(25) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_CTX_WARN')[5]).toEqual({ text: 'session', color: COLOURS.teal })
  expect(runsOf(tree, 'cs:CS_STATUSLINE_FRAME')[5]).toEqual({ text: 'shell  ', color: COLOURS.amber })
  expect(runsOf(tree, 'cs:CS_TERM_THEME')[5]).toEqual({ text: 'launch ', color: COLOURS.faint })
  expect(runsOf(tree, 'mod:cs.bandPrompt').slice(3)).toEqual([{ text: 'latest'.padEnd(14), color: COLOURS.ink }, { text: '  ' }, { text: 'mod    ', color: COLOURS.mut }, { text: '  ' }, { text: ' '.repeat(25) }])
  expect(runsOf((await draw(viewOf({ rows: LOCKED, columns: 80 }))).tree, 'mod:cs-mermaid.drawDiagrams')[6]).toEqual({ text: 'locked ', color: COLOURS.mut })
  expect(CLEARED).not.toBe(GOLDEN)
  const cleared = await draw(viewOf({ porcelain: CLEARED, columns: 80 }))
  expect(cleared.lines.map(line => line.trimEnd())).toContain(`  ${'Wake after /clear'.padEnd(26)}  ${'○ off'.padEnd(14)}  session  /clear`)
  expect(runsOf(cleared.tree, 'cs:CS_NO_ROTATION_WAKE').slice(-1)).toEqual([{ text: '/clear'.padEnd(25), color: COLOURS.mut }])
  expect(runsOf((await draw(viewOf())).tree, 'cs:CS_STATUSLINE_LAYOUT').slice(3)).toEqual([{ text: 'band'.padEnd(14), color: COLOURS.ink }])
})

test('each row is a row Box the body wide of the marker Text and one plain Button holding the rest of the row: ▌ in amber and the label bold in ink on the selected row, two spaces on the others; the Button\'s label is the row\'s and its children Texts alone; no row nor the field has a background', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))
  const row = rowOf(tree, 'cs:CS_STATUSLINE_LAYOUT')
  const [marker, button] = (row.children ?? []) as Node[]
  expect(textOf(row).length).toBe(58)
  expect((row.children ?? []).map(child => (child as Node).type)).toEqual(['Text', 'Button'])
  expect([textOf(marker), marker?.props.color]).toEqual(['▌ ', COLOURS.amber])
  expect([button?.props.plain, button?.props.label, button?.props.autoFocus, textOf(button)]).toEqual([true, 'Layout', true, `${'Layout'.padEnd(40)}  ${'band'.padEnd(14)}`])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(0, 2)).toEqual([{ text: '▌ ', color: COLOURS.amber }, { text: 'Layout'.padEnd(40), color: COLOURS.ink, weight: 'bold' }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_DISABLE').slice(0, 2)).toEqual([{ text: '  ' }, { text: 'Status line'.padEnd(40), color: COLOURS.ink }])
  const other = rowOf(tree, 'cs:CS_STATUSLINE_DISABLE')
  expect(other.children?.map(child => [(child as Node).type, (child as Node).props?.autoFocus])).toEqual([['Text', undefined], ['Button', undefined]])
  expect(rowsOf(tree).filter(line => line.startsWith('▌ '))).toEqual([`▌ ${'Layout'.padEnd(40)}  ${'band'.padEnd(14)}`])
  // The rows' Buttons, the footer's reset control and its scope line's two.
  const buttons = nodesOf(tree).filter(n => n.type === 'Button')
  expect(buttons.length).toBe(49)
  expect(buttons.flatMap(b => (b.children ?? []).map(c => typeof c === 'string' ? 'string' : (c as Node).type)).filter(type => type !== 'Text')).toEqual([])
  const labels = rowBoxes(tree).map(box => {
    const key = String(((box.children ?? []).find(c => (c as Node).type === 'Button') as Node).props.key)
    const label = runsOf(tree, key)[1]
    return [label?.color, label?.dimColor]
  })
  expect(rowBoxes(tree).length).toBe(46)
  expect(labels).toEqual(Array.from({ length: 46 }, () => [COLOURS.ink, undefined]))
  // A background under a focused element draws as a slab: no node of the pane has one.
  expect(nodesOf(tree).filter(n => n.props?.backgroundColor !== undefined).map(n => n.type)).toEqual([])
})

test('the field is a search box right under the masthead, over the column header: a round border in the rules\' soft colour across the body, one cell in, on no background, around an Input alone, keyed filter, holding the text, search settings its placeholder, focused first, Enter labelled select', async ($, on) => {
  const draw = drawer($, on)
  const parts = ((await draw(viewOf({ filter: 'scope' }))).tree as Node).children as Node[]
  const at = parts.findIndex(part => (part.children ?? []).some(child => (child as Node).type === 'Input'))
  expect([...parts.slice(at - MASTHEAD_LINES, at), parts[at + 1]].map(part => textOf(part).trimEnd())).toEqual([...MASTHEAD_AT_58, counted(58, HEAD_AT_58[0] ?? '', '3 of 46')])
  expect([parts[at]?.type, parts[at]?.props]).toEqual(['Box', { borderStyle: 'round', borderColor: COLOURS.soft, paddingX: 1, flexDirection: 'row', width: 58 }])
  const [input, ...rest] = (parts[at]?.children ?? []) as Node[]
  expect([input?.type, input?.props.key, input?.props.value, input?.props.placeholder, input?.props.autoFocus, input?.props.submitLabel, rest.length])
    .toEqual(['Input', 'filter', 'scope', 'search settings', true, 'select', 0])
})

test('the footer sits under a soft rule the body wide, each line of the selected row opening with ▍ in the rules\' soft colour: selected · muted and the label bold in ink, then the value as its row draws it, the source in its colour and the note muted, then the key muted; under them the keys\' line, muted, two cells in, and the reset control at its right end', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: { rows?: ConfigRow[] } = {}) => {
    const parts = ((await draw(viewOf({ selected, ...over }))).tree as Node).children as Node[]
    const rule = parts.findLastIndex(part => /^─+$/.test(textOf(part)))
    expect([textOf(parts[rule]), parts[rule]?.props.color], `the footer's rule with ${selected}`).toEqual([soft(58), COLOURS.soft])
    return parts.slice(rule + 1).map(line => (line.children ?? [])
      .map(run => [textOf(run), (run as Node).props?.color, (run as Node).props?.weight].filter(v => v !== undefined)))
  }
  const edge = ['▍ ', COLOURS.soft]
  const dot = [' · ', COLOURS.mut]
  const caption = ['selected · ', COLOURS.mut]
  const keys = (middle = 'Enter change') => [['  '], [`↑↓ move · ${middle} · Esc close`.padEnd(46), COLOURS.mut], ['reset all…']]
  const scope = [['  '], ['writes to: ', COLOURS.mut], ['● this session'], ['  '], ['○ this machine']]
  expect(await card('cs:CS_STATUSLINE_LAYOUT')).toEqual([
    [edge, caption, ['Layout', COLOURS.ink, 'bold']],
    [edge, ['How the status line looks: plain text, one full-width', COLOURS.ink]],
    [edge, ['band of colour, or capsules.', COLOURS.ink]],
    [edge, ['band', COLOURS.ink], dot, ['machine', COLOURS.green], dot, ['applies at the next repaint', COLOURS.mut]],
    [edge, ['CS_STATUSLINE_LAYOUT', COLOURS.mut]],
    keys(),
    scope,
  ])
  // The value line: the fourth line from the end, over the key, the keys and the scope line.
  const value = async (selected: RowId) => (await card(selected)).at(-4)
  expect(await value('cs:CS_STATUSLINE_DISABLE')).toEqual([edge, ['●', COLOURS.green], [' on', COLOURS.ink], dot, ['default', COLOURS.mut], dot, ['applies at the next repaint', COLOURS.mut]])
  expect(await value('cs:CS_SCOPE_DISABLE')).toEqual([edge, ['○ off', COLOURS.ink], dot, ['session', COLOURS.teal], dot, ['applies at your next prompt', COLOURS.mut]])
  expect(await value('cs:CS_NERD_FONTS')).toEqual([edge, ['○ off', COLOURS.ink], dot, ['default', COLOURS.mut], dot, ['applies at the next cs command', COLOURS.mut]])
  expect(await value('cs:CS_STATUSLINE_CTX_WARN')).toEqual([edge, ['50%', COLOURS.ink], dot, ['session', COLOURS.teal], dot, ['applies at the next repaint', COLOURS.mut]])
  expect((await value('cs:CS_CTX_WARN_CTX'))?.slice(1, 2)).toEqual([['40%', COLOURS.ink]])
  expect((await card('cs:CS_STATUSLINE_FRAME')).at(-5)?.slice(1, 4)).toEqual([['6', COLOURS.ink], dot, ['shell', COLOURS.amber]])
  expect((await card('cs:CS_STATUSLINE_FRAME')).at(-2)).toEqual(keys('shell sets it'))
  expect((await value('cs:CS_TERM_THEME'))?.slice(1, 4)).toEqual([['dark', COLOURS.ink], dot, ['launch', COLOURS.faint]])
  expect(await card('mod:cs.bandPrompt')).toEqual([
    [edge, caption, ['Band: named prompt', COLOURS.ink, 'bold']],
    [edge, ['latest', COLOURS.ink], dot, ['mod', COLOURS.mut], dot, ['changing it reloads cs (an armed rotation', COLOURS.mut]],
    [edge, ['countdown starts over)', COLOURS.mut]],
    [edge, ['cs.bandPrompt', COLOURS.mut]],
    keys(),
    scope,
  ])
  expect((await card('mod:cs-mermaid.drawDiagrams', { rows: LOCKED }))[1]?.slice(4, 5)).toEqual([['locked', COLOURS.mut]])
})

test('the keys\' line is a row Box ending in the reset control, one plain Button keyed reset holding reset all… muted, with no hotkey and no focus mark; the column header keeps its heads and the filter\'s count; with no footer or no keys\' line there is no control', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  const box = rowOf(tree, 'reset')
  const [indent, keys, button] = (box.children ?? []) as Node[]
  expect([box.props.flexDirection, textOf(box), (box.children ?? []).length]).toEqual(['row', hint('Enter flip'), 3])
  expect([indent?.type, textOf(indent), keys?.type, keys?.props.color, button?.type]).toEqual(['Text', '  ', 'Text', COLOURS.mut, 'Button'])
  expect([button?.props.key, button?.props.plain, button?.props.label, button?.props.hotkey, button?.props.autoFocus]).toEqual(['reset', true, 'reset all…', undefined, undefined])
  expect((button?.children ?? []).map(c => [(c as Node).type, textOf(c), (c as Node).props.color])).toEqual([['Text', 'reset all…', COLOURS.mut]])
  expect(lines.at(-2)).toBe('  ↑↓ move · Enter flip · Esc close              reset all…')
  expect(lines.slice(6, 8)).toEqual([HEAD_AT_58[0]?.padEnd(58), soft(58)])
  expect((await draw(viewOf({ filter: 'scope' }))).lines[6]).toBe(counted(58, HEAD_AT_58[0] ?? '', '3 of 46'))
  // At 24 columns the keys give up their end to leave a cell before it.
  expect((await draw(viewOf({ columns: 24 }))).lines.at(-2)).toBe('  ↑↓ move · … reset all…')
  const hasReset = async (over: Partial<PanelView>) => nodesOf((await draw(viewOf(over))).tree).some(n => n.props?.key === 'reset')
  expect([await hasReset({ filter: 'zzz' }), await hasReset({ columns: 24, bodyRows: 12 }), await hasReset({ hasField: false })]).toEqual([false, false, true])
})

// The Button or Input keyed `key` in a drawing, and the Text runs it draws.
function elementOf(tree: unknown, key: string): Node {
  const found = nodesOf(tree).find(n => ['Button', 'Input', 'Select'].includes(n.type) && n.props.key === key)
  if (found === undefined) throw new Error(`nothing keyed ${key} in the drawing`)
  return found
}
const runsIn = (node: Node) => (node.children ?? []).map(c => [textOf(c), (c as Node).props?.color])

test('under a session name the footer ends in the scope line under the keys\' line: writes to: muted, then two plain Buttons keyed scope:session and scope:machine, ● in green on the file writes go to and ○ in ink on the other, the lead left out where it does not fit and both cut alike below that; with no session name there is none', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  expect(lines.at(-1)).toBe('  writes to: ● this session  ○ this machine')
  const box = rowOf(tree, 'scope:session')
  expect([box.props.flexDirection, (box.children ?? []).map(c => (c as Node).type), runsIn(box).slice(0, 2)])
    .toEqual(['row', ['Text', 'Text', 'Button', 'Text', 'Button'], [['  ', undefined], ['writes to: ', COLOURS.mut]]])
  const scope = ['scope:session', 'scope:machine'].map(key => elementOf(tree, key))
  expect(scope.map(b => [b.props.plain, b.props.label, b.props.hotkey, b.props.autoFocus])).toEqual([[true, 'this session', undefined, undefined], [true, 'this machine', undefined, undefined]])
  expect(scope.map(runsIn)).toEqual([[['●', COLOURS.green], [' this session', COLOURS.ink]], [['○ this machine', COLOURS.ink]]])
  const machine = await draw(viewOf({ scope: 'machine' }))
  expect([machine.lines.at(-1), ['scope:session', 'scope:machine'].map(key => runsIn(elementOf(machine.tree, key)))]).toEqual(['  writes to: ○ this session  ● this machine',
    [[['○ this session', COLOURS.ink]], [['●', COLOURS.green], [' this machine', COLOURS.ink]]]])
  expect((await draw(viewOf({ columns: 40 }))).lines.at(-1)).toBe('  ● this session  ○ this machine')
  expect((await draw(viewOf({ columns: 24 }))).lines.at(-1)).toBe('  ● this se…  ○ this ma…')
  for (const columns of [24, 31, 32, 42, 43, 80, 150]) expect((await draw(viewOf({ columns }))).lines.at(-1), `the scope line at ${columns}`).toBe(scopeLine(columns))
  const bare = await draw(viewOf({ hasSelf: false }))
  expect([bare.lines.at(-1), nodesOf(bare.tree).filter(n => String(n.props?.key).startsWith('scope:')).length]).toEqual([hint('Enter flip'), 0])
})

// The golden with Nerd Font glyphs on in this machine's file.
const MACHINE_FLAG = edited('CS_NERD_FONTS', { 9: '1', 10: 'machine' })

// The status line off in this machine's file too: an off flag a file holds.
const MACHINE_FLAGS = edited('CS_STATUSLINE_DISABLE', { 9: '1', 10: 'machine' }, MACHINE_FLAG)

// A row's chooser open, its field holding `text`, the ring on its first element.
const opened = (id: RowId, text = '') => ({ kind: 'row', id, text, at: 0 }) as const

test('a row\'s chooser draws under it, four cells in: a choice a picker of every choice holding the current one, then Default while a file holds the value and Keep as plain Buttons with · between them; a flag a file holds Turn on or off, Default and Keep; a typed setting its Input on a line of its own, then Default and Keep <value>; a mod row a picker of its options, or its Input, then Keep; Buttons that do not fit wrap by whole choices', async ($, on) => {
  const draw = drawer($, on)
  const under = async (id: RowId, text = '', over: Partial<PanelView> & { porcelain?: string; hasSelf?: boolean } = {}) =>
    chooserIn((await draw(viewOf({ selected: id, chooser: opened(id, text), ...over }))).lines)
  expect(await under('cs:CS_NERD_FONTS', '', { porcelain: MACHINE_FLAGS })).toEqual([options('Turn off', 'Default (off)', 'Keep')])
  expect(await under('cs:CS_STATUSLINE_DISABLE', '', { porcelain: MACHINE_FLAGS })).toEqual([options('Turn on', 'Default (on)', 'Keep')])
  expect(await under('cs:CS_SCOPE_DISABLE')).toEqual([options('Turn on', 'Default (on)', 'Keep')])
  expect(await under('cs:CS_NO_MAIL_WAKE')).toEqual([options('Turn off', 'Default (on)', 'Keep')])
  expect(await under('cs:CS_STATUSLINE_LAYOUT')).toEqual([...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')])
  expect(await under('cs:CS_STATUSLINE_LAYOUT', '', { hasSelf: false })).toEqual([...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')])
  // With the ring off the picker it is its one line.
  expect(chooserIn((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', chooser: { ...opened('cs:CS_STATUSLINE_LAYOUT'), at: 1 } }))).lines))
    .toEqual([...picked('band'), options('Default (quiet)', 'Keep')])
  expect(await under('cs:CS_REWRITE_PROVIDER')).toEqual([...picked('claude', PROVIDERS), options('Keep')])
  expect(await under('cs:CS_REWRITE_PROGRESS')).toEqual([...picked('screen', ['screen', 'native', 'line', 'static']), options('Keep')])
  expect(await under('cs:CS_TERM_THEME')).toEqual([...picked('dark', ['light', 'dark']), options('Keep')])
  // A row at a default that is none of its choices holds none in the picker.
  expect(await under('cs:CS_TERM_THEME', '', { porcelain: edited('CS_TERM_THEME', { 9: '-', 10: 'default' }) })).toEqual([...picked('none', ['light', 'dark']), options('Keep')])
  expect(await under('cs:CS_STATUSLINE_CTX_WARN', '50')).toEqual(['    50', options('Default (40)', 'Keep 50')])
  // An empty field shows the default's name.
  expect(await under('cs:CS_SCOPE_BUDGET_MS')).toEqual(['    1500', options('Default (1500)', 'Keep 1500')])
  expect(await under('cs:CS_STATUSLINE_SEGMENTS', 'logo,session,notes,mail,git,model,ctx,limits', { porcelain: SEGMENTS })).toEqual(['    logo,session,notes,mail,git,model,ctx,limits',
    options('Default (logo,session,notes,mail,git,model,ctx,limits)'), options('Keep logo,session,notes,mail,git,model,ctx,limits')])
  expect(await under('mod:cs.bandPrompt')).toEqual([...picked('latest', ['latest', 'read']), options('Keep')])
  expect(await under('mod:cs.bandBars', '10')).toEqual(['    10', options('Keep 10')])
  // A row Enter flips at once, a locked row and a row not selected draw no chooser.
  expect(await under('cs:CS_NERD_FONTS')).toEqual([])
  expect(await under('cs:CS_STATUSLINE_FRAME')).toEqual([])
  expect(await under('cs:CS_STATUSLINE_CTX_WARN', '50', { hasSelf: false })).toEqual([])
  expect(chooserIn((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_DISABLE', chooser: opened('cs:CS_STATUSLINE_LAYOUT') }))).lines)).toEqual([])
  // At 24 columns the Buttons wrap into what 20 cells hold and one wider is cut.
  expect(await under('cs:CS_STATUSLINE_CTX_WARN', '50', { columns: 24 })).toEqual(['    50', options('Default (40)'), options('Keep 50')])
  expect((await under('cs:CS_STATUSLINE_SEGMENTS', 'logo', { porcelain: SEGMENTS, columns: 24 })).slice(1)).toEqual([options('Default (logo,sessi…'), options('Keep logo,session,n…')])
  // The elements: the picker a Select keyed picker with no label, each choice
  // an option by its value, the one the row holds its value; each Button plain,
  // keyed option:<label>, its text in ink, the dots muted; the field an Input
  // keyed typed, `set` its Enter; the ring's mark on the element the ring is
  // on, and off the row.
  const { tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', chooser: { ...opened('cs:CS_STATUSLINE_LAYOUT'), at: 2 } }))
  const picker = elementOf(tree, 'picker')
  expect([picker.type, picker.props.label, picker.props.options, picker.props.value, picker.props.autoFocus])
    .toEqual(['Select', undefined, [{ value: 'quiet' }, { value: 'band' }, { value: 'capsules' }], 'band', undefined])
  expect(elementOf((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', chooser: opened('cs:CS_STATUSLINE_LAYOUT') }))).tree, 'picker').props.autoFocus).toBe(true)
  expect(['option:Default (quiet)', 'option:Keep'].map(key => elementOf(tree, key)).map(b => [b.props.plain, b.props.label, b.props.autoFocus, runsIn(b)])).toEqual([
    [true, 'Default (quiet)', undefined, [['Default (quiet)', COLOURS.ink]]], [true, 'Keep', true, [['Keep', COLOURS.ink]]]])
  expect(runsIn(rowOf(tree, 'option:Keep'))).toEqual([['    ', undefined], ['Default (quiet)', undefined], [' · ', COLOURS.mut], ['Keep', undefined]])
  expect(elementOf(tree, 'cs:CS_STATUSLINE_LAYOUT').props.autoFocus).toBe(undefined)
  const typed = (await draw(viewOf({ selected: 'cs:CS_STATUSLINE_CTX_WARN', chooser: opened('cs:CS_STATUSLINE_CTX_WARN', '45') }))).tree
  const input = elementOf(typed, 'typed')
  expect([input.type, input.props.value, input.props.placeholder, input.props.submitLabel, input.props.autoFocus]).toEqual(['Input', '45', '40', 'set', true])
  expect(elementOf(typed, 'option:Default (40)').props.autoFocus).toBe(undefined)
  // No line of a chooser passes the body, the open picker's included, but the
  // field's: the terminal scrolls an Input's text inside it, the kit draws it whole.
  for (const columns of [24, 40, 58, 80]) {
    for (const [id, fields] of [['cs:CS_REWRITE_PROVIDER', 0], ['cs:CS_STATUSLINE_SEGMENTS', 1], ['cs:CS_STATUSLINE_LAYOUT', 0], ['mod:cs.bandPrompt', 0]] as const) {
      const lines = chooserIn((await draw(viewOf({ selected: id, chooser: opened(id), porcelain: SEGMENTS, columns }))).lines).slice(fields)
      expect([lines.length > 0, lines.filter(line => line.length > columns)], `${id}'s chooser at ${columns}`).toEqual([true, []])
    }
  }
})

test('the window counts the chooser\'s lines, a picker with the ring on it open to every option: at 18 rows the selected row, its chooser, and a footer of the label, the value line and the scope line; at 16 the label alone; with the ring off the picker 14 rows hold the label and the value line; a field\'s two lines leave 14 rows the label and the value line and 12 no footer; nine choices take a line more for the one past eight', async ($, on) => {
  const draw = drawer($, on)
  const at = async (id: RowId, bodyRows: number, text = '', over: Partial<PanelView> & { porcelain?: string } = {}) => {
    const view = viewOf({ selected: id, chooser: opened(id, text), bodyRows, ...over })
    return { lines: (await draw(view)).lines.map(line => line.trimEnd()), keys: ringOf(view).keys }
  }
  const top = [...MASTHEAD_AT_58, ...field(58), ...HEAD_AT_58]
  const row = at58('Layout', 'band', true)
  const layout = [...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')]
  const keys = ['picker', 'option:Default (quiet)', 'option:Keep']
  expect(await at('cs:CS_STATUSLINE_LAYOUT', 18)).toEqual({ lines: [...top, row, ...layout,
    soft(58), '▍ selected · Layout', '▍ band · machine · applies at the next repaint', scopeLine()],
    keys: ['filter', 'cs:CS_STATUSLINE_LAYOUT', ...keys, 'scope:session', 'scope:machine'] })
  expect(await at('cs:CS_STATUSLINE_LAYOUT', 16)).toEqual({ lines: [...top, row, ...layout, soft(58), '▍ selected · Layout'],
    keys: ['filter', 'cs:CS_STATUSLINE_LAYOUT', ...keys] })
  expect(await at('cs:CS_STATUSLINE_LAYOUT', 14, '', { chooser: { ...opened('cs:CS_STATUSLINE_LAYOUT'), at: 1 } })).toEqual({
    lines: [...top, row, ...picked('band'), options('Default (quiet)', 'Keep'), soft(58), '▍ selected · Layout', '▍ band · machine · applies at the next repaint'],
    keys: ['filter', 'cs:CS_STATUSLINE_LAYOUT', ...keys] })
  expect(await at('cs:CS_STATUSLINE_CTX_WARN', 14, '50')).toEqual({ lines: [...top, at58('Context warn %', '50%', true), '    50', options('Default (40)', 'Keep 50'),
    soft(58), '▍ selected · Context warn %', '▍ 50% · session · applies at the next repaint'],
    keys: ['filter', 'cs:CS_STATUSLINE_CTX_WARN', 'typed', 'option:Default (40)', 'option:Keep 50'] })
  expect(await at('cs:CS_STATUSLINE_CTX_WARN', 12, '50')).toEqual({ lines: [...top, at58('Context warn %', '50%', true), '    50', options('Default (40)', 'Keep 50'), '+34 below'],
    keys: ['filter', 'cs:CS_STATUSLINE_CTX_WARN', 'typed', 'option:Default (40)', 'option:Keep 50'] })
  // The picker draws eight options and a line for the rest: 20 rows hold the selected row and its eleven lines.
  const nine = edited('CS_REWRITE_PROVIDER', { 5: [...PROVIDERS, 'local'].join(',') })
  expect((await at('cs:CS_REWRITE_PROVIDER', 20, '', { porcelain: nine })).lines).toEqual([...top, at58('Provider', 'claude', true), ...picked('claude', PROVIDERS), '      … 1 more', options('Keep')])
  // In a tall body the chooser sits in the window under its row, the rows go on under it.
  const tall = (await at('cs:CS_STATUSLINE_LAYOUT', 90)).lines
  expect(tall.slice(tall.indexOf(row) - 1, tall.indexOf(row) + 7))
    .toEqual([at58('Status line', '● on'), row, ...layout, at58('Segments', 'logo,session,notes,mail,git,model,ctx,limits')])
  expect(tall.length).toBe(8 + GOLDEN_LINES + 5 + 8)
})

test('reset all… pressed swaps the keys\' line for its confirmation: how many overrides the scope line\'s file holds, cut to fit, what stays while it fits, then plain Buttons keyed confirm and keep; the ring walks them where it walked the reset control', async ($, on) => {
  const draw = drawer($, on)
  const line = async (over: Partial<PanelView> & { porcelain?: string; hasSelf?: boolean; rows?: ConfigRow[] } = {}) => {
    const { lines } = await draw(viewOf({ chooser: { kind: 'reset' }, ...over }))
    return lines.at(over.hasSelf === false ? -1 : -2)
  }
  expect(await line()).toBe('  remove 3 overrides from this session\'s… · confirm · keep')
  expect(await line({ scope: 'machine' })).toBe(confirming('remove 1 override from this machine\'s file'))
  expect(await line({ columns: 80 })).toBe('  remove 3 overrides from this session\'s file · confirm · keep')
  expect(await line({ columns: 150 })).toBe(confirming('remove 3 overrides from this session\'s file; your shell\'s exports stay; mod rows keep their values', 150))
  expect(await line({ columns: 150, porcelain: THREE })).toBe(confirming('remove 2 overrides from this session\'s file; mod rows keep their values', 150))
  expect(await line({ columns: 150, porcelain: NONE, rows: [] })).toBe(confirming('remove 0 overrides from this session\'s file', 150))
  expect(await line({ columns: 150, hasSelf: false })).toBe(confirming('remove 1 override from this machine\'s file; your shell\'s exports stay; mod rows keep their values', 150))
  const view = viewOf({ chooser: { kind: 'reset' }, bodyRows: 21, selected: 'cs:CS_STATUSLINE_DISABLE' })
  const { lines, tree } = await draw(view)
  expect(lines.filter(l => l.includes('reset all…'))).toEqual([])
  const box = rowOf(tree, 'confirm')
  expect(runsIn(box)).toEqual([['  ', undefined], ['remove 3 overrides from this session\'s…', COLOURS.mut], [' · ', COLOURS.mut], ['confirm', undefined], [' · ', COLOURS.mut], ['keep', undefined]])
  expect(['confirm', 'keep'].map(key => elementOf(tree, key)).map(b => [b.props.plain, b.props.label, b.props.hotkey, runsIn(b)]))
    .toEqual([[true, 'confirm', undefined, [['confirm', COLOURS.ink]]], [true, 'keep', undefined, [['keep', COLOURS.ink]]]])
  expect(ringOf(view).keys).toEqual(['filter', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT', 'confirm', 'keep', 'scope:session', 'scope:machine'])
})

test('the pane draws every colour but the brand\'s in a theme key, so the engine follows the person\'s theme; what CS_TERM_THEME reads changes no colour', async ($, on) => {
  const draw = drawer($, on)
  const colours = async (over: Partial<PanelView> & { porcelain?: string }) => nodesOf((await draw(viewOf(over))).tree)
    .map(n => [n.props?.color, n.props?.borderColor, n.props?.backgroundColor, n.props?.weight])
  const views: Partial<PanelView>[] = [{},{ columns: 80, selected: 'cs:CS_STATUSLINE_CTX_WARN' }, { columns: 24, filter: 'context' }]
  for (const view of views) expect(await colours({ ...view, porcelain: LIGHT }), `the view ${JSON.stringify(view)}`).toEqual(await colours(view))
  const keys = [...new Set((await colours({ columns: 80 })).flatMap(([color, border]) => [color, border]).filter(color => color !== undefined && !String(color).startsWith('rgb(')))].sort()
  expect(keys).toEqual(['inactive', 'planMode', 'subtle', 'success', 'text'])
})

// ── The hooks, through the engine's own `$` ──────────────────────────────

const BIN = '/opt/cs/bin/cs'
const PANE_PROPS = { title: 'cs', isFocused: true, bodyColumns: 80, placement: 'inline', scroll: { offset: 0, bodyRows: 90 }, view: {} } as const
const COMMAND = { command: 'cs', args: '', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const LIST = [BIN, '-config', 'list', '--porcelain']
const ASK_VERSION = [BIN, '-version']

type Answer = { exitCode?: number; stdout?: string; stderr?: string }

// A promise the test settles: what a held answer waits on.
function gate(): { held: Promise<void>; open: () => void } {
  let open = () => {}
  const held = new Promise<void>(resolve => { open = resolve })
  return { held, open }
}

// What sits beneath the mod: cs's answer to each argv (`cs 2026.10.11` for
// `-version` unless `version` says, the golden for the listing, nothing for a
// write unless `answer` says), the /config rows and their writer, and a
// record of each call (the window's moves among them). A pane is open from its
// ui.open until a ui.close. Nothing answers a dialog: the pane asks in itself.
function world(on: On, opts: { env?: Record<string, string>; answer?: (argv: readonly string[]) => Answer | Promise<Answer>; version?: Answer; rows?: ConfigRow[] } = {}) {
  const w = {
    runs: [] as string[][], toasts: [] as string[], logs: [] as string[], opens: [] as PaneOpenArgs[], sets: [] as { key: string; value: unknown }[],
    rows: opts.rows ?? MOD_ROWS, rowsDeny: undefined as string | undefined,
    setDeny: undefined as string | undefined, openDeny: undefined as string | undefined, lists: 0, isOpen: false, scrolls: 0,
  }
  mock.env(on, opts.env ?? { CS_BIN: BIN, CLAUDE_SESSION_NAME: 'alpha' })
  const clock = mock.clock(on)
  on('process.run', async ($, e) => {
    w.runs.push([...e.argv])
    const a: Answer = e.argv[1] === '-version' ? opts.version ?? { stdout: `cs ${VERSION}\n` } : await (opts.answer ?? (argv => argv[2] === 'list' ? { stdout: GOLDEN } : {}))(e.argv)
    return { value: { exitCode: a.exitCode ?? 0, stdout: a.stdout ?? '', stderr: a.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('config.list', () => { w.lists++; return w.rowsDeny === undefined ? { value: w.rows } : { deny: w.rowsDeny } })
  on('config.set', ($, e) => { w.sets.push({ key: e.key, value: e.value }); return w.setDeny === undefined ? { value: e.value } : { deny: w.setDeny } })
  on('ui.toast', ($, e) => { w.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { w.logs.push(e.text); return { value: undefined } })
  on('ui.open', ($, e) => {
    if (w.openDeny !== undefined) return { deny: w.openDeny }
    w.opens.push({ ...e }); w.isOpen = true; return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({ value: w.isOpen ? [{ id: 'cs-panel', title: 'cs', isShown: true, isFocused: true, isPlaced: true }] : [] }))
  on('ui.close', () => { w.isOpen = false; return { value: undefined } })
  on('ui.focus', () => ({}))
  on('ui.scroll', () => { w.scrolls++; return {} })
  on('turn.complete', () => ({ text: '' }))
  return { w, clock }
}

// cs's writes: every run but the version and the listing.
function writes(w: { runs: string[][] }): string[][] {
  return w.runs.filter(argv => ![ASK_VERSION, LIST].some(read => argv.join(' ') === read.join(' ')))
}

async function openPane($: Engine) {
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  return $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
}

// The ring landing on a row, as Tab or an arrow lands it.
function focus($: Engine, element: string) {
  return $.ui.focus({ component: 'Pane', requestId: 'cs-panel', plugin: 'cs-panel', element, origin: { kind: 'person' } })
}

type Pane = Awaited<ReturnType<typeof openPane>>

// Enter on a row, as a person presses it; the lines of its chooser then.
async function enter(pane: Pane, key: string): Promise<string[]> {
  await pane.press({ key })
  return chooserIn(bodyLines(await pane.drawn()))
}

// Enter on the open chooser's choice labelled `label`, or Enter in its field with `text`.
const pick = (pane: Pane, label: string) => pane.press({ key: `option:${label}` })
const submit = (pane: Pane, text: string) => pane.input({ key: 'typed', text, kind: 'submit' })
// A pick of `value` in the open chooser's picker.
const choose = (pane: Pane, value: string) => pane.select({ key: 'picker', value })

// How many times cs listed its settings.
const listings = (w: { runs: string[][] }) => w.runs.filter(argv => argv.join(' ') === LIST.join(' ')).length

const DONE = { answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as const

test('/cs and /cs-panel without CS_BIN say cs did not launch this conversation and open nothing', async ($, on) => {
  const { w } = world(on, { env: {} })
  expect(await $.command.run(COMMAND)).toEqual({ text: 'The launch did not say where cs is (CS_BIN); open this conversation with cs to change its settings.' })
  expect(await $.command.run({ ...COMMAND, command: 'cs-panel' })).toEqual({ text: REPLIES.noBin })
  expect([w.opens, w.runs, w.lists]).toEqual([[], [], 0])
})

test('bare /cs opens the pane and reads cs\'s version, cs and /config at once; /cs with an argument is passed on to the hook beneath', async ($, on) => {
  const { w } = world(on)
  // The cs mod's rail, beneath this plugin.
  on('command.run', { command: 'cs' }, ($, e) => ({ text: `rail ${e.args}` }))
  expect(await $.command.run({ ...COMMAND, args: 'next' })).toEqual({ text: 'rail next' })
  expect([w.opens, w.runs, w.lists]).toEqual([[], [], 0])
  expect(await $.command.run(COMMAND)).toEqual({ text: 'cs settings are in the panel: type to filter, the arrows move, Enter changes the row, Esc closes.' })
  expect(w.opens).toEqual([{ id: 'cs-panel', title: 'cs', focus: true, closeOnEscape: true, columns: 60 }])
  expect([w.runs, w.lists]).toEqual([[ASK_VERSION, LIST], 1])
  expect(await $.command.run({ ...COMMAND, command: 'cs-panel' })).toEqual({ text: REPLIES.opened })
  expect(w.opens.length).toBe(2)
})

test('/cs answers why when the pane does not open, and reads nothing', async ($, on) => {
  const { w } = world(on)
  w.openDeny = 'no room for a pane'
  expect(await $.command.run(COMMAND)).toEqual({ text: 'The panel did not start: cs-panel: $.ui.open: no room for a pane' })
  expect([w.runs, w.lists]).toEqual([[], 0])
})

test('a pane drawn after a reload reads both sources once $.ui.panes lists it open; one drawn after a close reads nothing', async ($, on) => {
  const { w, clock } = world(on)
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  await clock.settle()
  expect([w.runs, w.lists]).toEqual([[], 0])
  w.isOpen = true
  await pane.redraw()
  await clock.settle()
  expect([w.runs, w.lists]).toEqual([[ASK_VERSION, LIST], 1])
  const drawn = bodyLines(await pane.drawn())
  expect([drawn[1], drawn[4], cardIn(drawn)[0]]).toEqual([boxed(80, WORDS_AT_80)[1], field(80)[1], '▍ selected · Band: prompt bars'])
  await $.turn.complete(DONE)
  await clock.settle()
  expect(w.lists).toBe(2)
})

test('the pane\'s drawing is what drawPane draws for the same view', async ($, on) => {
  world(on)
  let fixture: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => drawPane(fixture ?? viewOf(), $.ui.resolve(e), NOOP))
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  const props = { ...PANE_PROPS, bodyColumns: 40, isFocused: false, scroll: { offset: 0, bodyRows: 14 } }
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props })
  fixture = { ...viewOf(), columns: 40, bodyRows: 14 }
  const lab = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props })
  expect(bodyLines(await pane.drawn())).toEqual(bodyLines(await lab.drawn()))
  expect(JSON.stringify(await pane.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
    .toBe(JSON.stringify(await lab.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
  const drawn = bodyLines(await pane.drawn()).map(line => line.trimEnd())
  expect([drawn[1], drawn[4], cardIn(drawn)[0], drawn.find(line => line.startsWith('▌ '))]).toEqual([boxed(40, 'claude-sessions 2026.10.11')[1], field(40)[1],
    '▍ selected · Band: prompt bars', `▌ ${'Band: prompt bars'.padEnd(22)}  ○ off`])
})

test('the ring landing on a row selects it, and the card names that row; a ring on the field keeps the selection', async ($, on) => {
  world(on)
  const pane = await openPane($)
  const shown = async () => cardIn(bodyLines(await pane.drawn()))
  expect(await shown()).toEqual(['▍ selected · Band: prompt bars', '▍ ○ off · mod · changing it reloads cs (an armed rotation countdown starts over)',
    '▍ cs.bandPrompts', hint('Enter flip', 80), scopeLine(80)])
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  const layout = ['▍ selected · Layout', '▍ How the status line looks: plain text, one full-width band of colour, or', '▍ capsules.',
    '▍ band · machine · applies at the next repaint', '▍ CS_STATUSLINE_LAYOUT', hint('Enter change', 80), scopeLine(80)]
  expect(await shown()).toEqual(layout)
  await focus($, 'filter')
  expect(await shown()).toEqual(layout)
  await focus($, 'cs:CS_NOT_A_ROW')
  expect(await shown()).toEqual(layout)
})

test('an arrow, the wheel or a page key moves the selection by its rows, held to the last row and to the first, where Up goes on to the field; the window and the ring follow; with no rows the move passes on', async ($, on) => {
  const { w, clock } = world(on)
  const scroll = async (by: number) => {
    const moved = await $.ui.scroll({ component: 'Pane', requestId: 'cs-panel', offset: 0, by, bodyRows: 12, contentRows: 12, origin: { kind: 'person' } })
    await clock.settle()
    return moved
  }
  expect([await scroll(1), w.scrolls]).toEqual([{}, 1])
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: { ...PANE_PROPS, bodyColumns: 58, scroll: { offset: 0, bodyRows: 19 } } })
  await clock.settle()
  // The card's first line, the selected row, and the Button marked for the
  // ring with autoFocus: the selected row's. On a surface that draws the
  // field first that mark is inert (the first autoFocus drawn wins) and the
  // ring moves by $.ui.focus, which the kit refuses, so this pins the mark only.
  const shown = async () => {
    const tree = await pane.drawn()
    await clock.settle()
    const ring = nodesOf(tree).filter(n => n.type === 'Button' && n.props.autoFocus === true).map(n => n.props.key)
    return { card: cardIn(bodyLines(tree))[0], selected: rowsOf(tree).filter(row => row.startsWith('▌ ')).map(row => row.trimEnd()), ring }
  }
  const prompts = { card: '▍ selected · Band: prompt bars', selected: [at58('Band: prompt bars', '○ off', true)], ring: ['mod:cs.bandPrompts'] }
  const prompt = { card: '▍ selected · Band: named prompt', selected: [at58('Band: named prompt', 'latest', true)], ring: ['mod:cs.bandPrompt'] }
  expect(await shown()).toEqual(prompts)
  expect([await scroll(1), await shown()]).toEqual([{}, prompt])
  expect([await scroll(1), await shown()]).toEqual([{}, { card: '▍ selected · Band: most bars', selected: [at58('Band: most bars', '10', true)], ring: ['mod:cs.bandBars'] }])
  expect([await scroll(-1), await shown()]).toEqual([{}, prompt])
  expect([await scroll(-5), await shown()]).toEqual([{}, prompts])
  expect(w.logs.length).toBe(4)
  expect([await scroll(-1), await shown()]).toEqual([{}, prompts])
  expect(w.logs.length).toBe(5)
  expect(await scroll(5)).toEqual({})
  expect(bodyLines(await pane.drawn()).map(line => line.trimEnd())).toEqual([...MASTHEAD_AT_58, ...field(58), ...HEAD_AT_58,
    '+5 above',
    at58('Status line', '● on', true),
    '+40 below',
    soft(58), '▍ selected · Status line', '▍ Draws the line under the prompt with the session,', '▍ branch, model, context and usage limits.',
    '▍ ● on · default · applies at the next repaint', '▍ CS_STATUSLINE_DISABLE', hint('Enter flip'), scopeLine(),
  ])
  const last ={ card: '▍ selected · Tail kept (bytes)', selected: [at58('Tail kept (bytes)', '65536', true)], ring: ['cs:CS_NARRATIVE_KEEP_BYTES'] }
  expect([await scroll(1000), await shown()]).toEqual([{}, last])
  expect(bodyLines(await pane.drawn()).slice(-13).map(line => line.trimEnd())).toEqual([...HEAD_AT_58, '+44 above', at58('Budget (bytes)', '131072'),
    at58('Tail kept (bytes)', '65536', true), soft(58), '▍ selected · Tail kept (bytes)', '▍ How much of the newest narrative stays in the live file',
    '▍ when it rotates.', '▍ 65536 · default · applies when the next turn ends', '▍ CS_NARRATIVE_KEEP_BYTES', hint(), scopeLine()])
  expect([await scroll(1), await shown()]).toEqual([{}, last])
  expect(w.scrolls).toBe(1)
  // The kit answers no plugin's $.ui.focus: each of the six moves sends the
  // ring to its new row once, Up from the first row sends it to the field,
  // and each call's refusal is logged.
  expect(w.logs).toEqual(Array.from({ length: 7 }, () => LOGS.failed('no implementation for ui.focus')))
})

const CLOSER = { name: 'closer', register(on: On) {
  on('command.run', { command: 'close-panel' }, async $ => { await $.ui.close({ id: 'cs-panel' }); return { text: '' } })
} }

test('Enter on an on/off setting a file holds opens Turn on or off, Default and Keep under it, an off flag in its feature\'s words; a choice writes to the file the scope line names, but a value this session\'s file holds stays there and Default unsets the file that holds it; Keep closes it and writes nothing', async ($, on) => {
  expect([MACHINE_FLAG === GOLDEN, MACHINE_FLAGS === MACHINE_FLAG]).toEqual([false, false])
  const { w } = world(on, { answer: argv => argv[2] === 'list' ? { stdout: MACHINE_FLAGS } : {} })
  const pane = await openPane($)
  expect(await enter(pane, 'cs:CS_NERD_FONTS')).toEqual([options('Turn off', 'Default (off)', 'Keep')])
  await pick(pane, 'Turn off')
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([])
  await enter(pane, 'cs:CS_NERD_FONTS'); await pick(pane, 'Default (off)')
  await enter(pane, 'cs:CS_NERD_FONTS'); await pick(pane, 'Keep')
  await pane.press({ key: 'scope:machine' })
  await enter(pane, 'cs:CS_NERD_FONTS'); await pick(pane, 'Turn off')
  expect(await enter(pane, 'cs:CS_STATUSLINE_DISABLE')).toEqual([options('Turn on', 'Default (on)', 'Keep')])
  await pick(pane, 'Turn on')
  await pane.press({ key: 'scope:session' })
  await enter(pane, 'cs:CS_STATUSLINE_DISABLE'); await pick(pane, 'Turn on')
  expect(await enter(pane, 'cs:CS_SCOPE_DISABLE')).toEqual([options('Turn on', 'Default (on)', 'Keep')])
  await pick(pane, 'Turn on')
  await pane.press({ key: 'scope:machine' })
  await enter(pane, 'cs:CS_SCOPE_DISABLE'); await pick(pane, 'Default (on)')
  expect(await enter(pane, 'cs:CS_NO_MAIL_WAKE')).toEqual([options('Turn off', 'Default (on)', 'Keep')])
  await pick(pane, 'Turn off')
  expect(writes(w)).toEqual([
    [BIN, 'alpha', '-config', 'set', 'CS_NERD_FONTS', '0'],
    [BIN, '-config', 'unset', 'CS_NERD_FONTS'],
    [BIN, '-config', 'set', 'CS_NERD_FONTS', '0'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '0'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_DISABLE', '0'],
    [BIN, 'alpha', '-config', 'set', 'CS_SCOPE_DISABLE', '0'],
    [BIN, 'alpha', '-config', 'unset', 'CS_SCOPE_DISABLE'],
    [BIN, 'alpha', '-config', 'set', 'CS_NO_MAIL_WAKE', '1'],
  ])
  // Each write reads cs again; Keep reads nothing.
  expect(listings(w)).toBe(1 + 8)
})

test('Enter on a choice opens a picker of every choice holding the current one, then Default while a file holds the value and Keep; a pick writes the file the scope line names, and a pick of the current one writes nothing and reads nothing again', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  expect(await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')).toEqual([...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')])
  await choose(pane, 'capsules')
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([])
  await pane.press({ key: 'scope:machine' })
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT'); await choose(pane, 'quiet')
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT'); await pick(pane, 'Default (quiet)')
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT'); await pick(pane, 'Keep')
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT'); await choose(pane, 'band')
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([])
  expect(await enter(pane, 'cs:CS_REWRITE_PROVIDER')).toEqual([...picked('claude', PROVIDERS), options('Keep')])
  await choose(pane, 'xai')
  await pane.press({ key: 'scope:session' })
  expect(await enter(pane, 'cs:CS_REWRITE_PROGRESS')).toEqual([...picked('screen', ['screen', 'native', 'line', 'static']), options('Keep')])
  await choose(pane, 'line')
  expect(await enter(pane, 'cs:CS_TERM_THEME')).toEqual([...picked('dark', ['light', 'dark']), options('Keep')])
  await choose(pane, 'light')
  expect(writes(w)).toEqual([
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'quiet'],
    [BIN, '-config', 'unset', 'CS_STATUSLINE_LAYOUT'],
    [BIN, '-config', 'set', 'CS_REWRITE_PROVIDER', 'xai'],
    [BIN, 'alpha', '-config', 'set', 'CS_REWRITE_PROGRESS', 'line'],
    [BIN, 'alpha', '-config', 'set', 'CS_TERM_THEME', 'light'],
  ])
  expect(listings(w)).toBe(1 + 6)
})

test('Enter on a typed setting opens its field holding the value, the default\'s name while it is empty, then Default and Keep <value>; Enter in the field writes what it holds, this session\'s value there whatever the scope line says, any other to the file the scope line names; the field keeps its text over a redraw', async ($, on) => {
  const { w, clock } = world(on)
  const pane = await openPane($)
  expect(await enter(pane, 'cs:CS_STATUSLINE_CTX_WARN')).toEqual(['    50', options('Default (40)', 'Keep 50')])
  const field = await pane.find({ key: 'typed' })
  expect([field?.type, field?.props.value, field?.props.placeholder, field?.props.submitLabel]).toEqual(['Input', '50', '40', 'set'])
  await submit(pane, '45')
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([])
  await enter(pane, 'cs:CS_STATUSLINE_CTX_WARN'); await pick(pane, 'Default (40)')
  await enter(pane, 'cs:CS_STATUSLINE_CTX_WARN'); await pick(pane, 'Keep 50')
  await pane.press({ key: 'scope:machine' })
  await enter(pane, 'cs:CS_STATUSLINE_CTX_WARN'); await submit(pane, '46')
  expect(await enter(pane, 'cs:CS_SCOPE_BUDGET_MS')).toEqual(['    1500', options('Default (1500)', 'Keep 1500')])
  expect([(await pane.find({ key: 'typed' }))?.props.value, (await pane.find({ key: 'typed' }))?.props.placeholder]).toEqual(['', '1500'])
  await submit(pane, '2000')
  await pane.press({ key: 'scope:session' })
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS'); await submit(pane, '2000')
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS'); await pick(pane, 'Default (1500)')
  expect(writes(w)).toEqual([
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_CTX_WARN', '45'],
    [BIN, 'alpha', '-config', 'unset', 'CS_STATUSLINE_CTX_WARN'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_CTX_WARN', '46'],
    [BIN, '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
    [BIN, 'alpha', '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
    [BIN, '-config', 'unset', 'CS_SCOPE_BUDGET_MS'],
  ])
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS')
  await pane.input({ key: 'typed', text: '25', kind: 'change' })
  await $.turn.complete(DONE)
  await clock.settle()
  await pane.redraw()
  expect((await pane.find({ key: 'typed' }))?.props.value).toBe('25')
})

// A flag whose 1 turns off what its label names (cs's flagoff): Scope
// grounding is off at 1, in this session's file in the golden, and on unset.
const GROUNDING_ON = edited('CS_SCOPE_DISABLE', { 9: '-', 10: 'default' })

test('an off flag draws its feature: ○ off at 1 and ● on unset, and its footer says what the feature does', async ($, on) => {
  expect(GROUNDING_ON).not.toBe(GOLDEN)
  const draw = drawer($, on)
  const off = await draw(viewOf({ selected: 'cs:CS_SCOPE_DISABLE' }))
  expect(off.lines.map(line => line.trimEnd())).toContain(at58('Scope grounding', '○ off', true))
  const unset = await draw(viewOf({ porcelain: GROUNDING_ON, selected: 'cs:CS_SCOPE_DISABLE' }))
  expect(unset.lines.map(line => line.trimEnd())).toContain(at58('Scope grounding', '● on', true))
  expect(cardIn(unset.lines)).toEqual(['▍ selected · Scope grounding', '▍ Adds a short summary of the relevant code to each prompt', '▍ that asks for code work.',
    '▍ ● on · default · applies at your next prompt', '▍ CS_SCOPE_DISABLE', hint('Enter flip'), scopeLine()])
})

test('with no session name the pane draws no scope line, every write goes to this machine, and a value this session\'s file holds opens nothing and says why it is not changed', async ($, on) => {
  const { w } = world(on, { env: { CS_BIN: BIN }, answer: argv => argv[2] === 'list' ? { stdout: MACHINE_FLAG } : {} })
  const pane = await openPane($)
  expect(await enter(pane, 'cs:CS_NERD_FONTS')).toEqual([options('Turn off', 'Default (off)', 'Keep')])
  await pick(pane, 'Turn off')
  expect(await enter(pane, 'cs:CS_STATUSLINE_DISABLE')).toEqual([])
  expect(await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')).toEqual([...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')])
  await choose(pane, 'capsules')
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS'); await submit(pane, '2000')
  expect(await enter(pane, 'cs:CS_STATUSLINE_CTX_WARN')).toEqual([])
  expect(writes(w)).toEqual([
    [BIN, '-config', 'set', 'CS_NERD_FONTS', '0'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'],
    [BIN, '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
  ])
  expect(w.toasts.slice(-1)).toEqual(["Context warn %: this session's file sets it, and this conversation has no cs session name to write it with"])
  const tree = await pane.drawn()
  expect([bodyLines(tree).filter(line => line.includes('writes to')), nodesOf(tree).filter(n => String(n.props?.key).startsWith('scope:')).length]).toEqual([[], 0])
})

test('Enter on an on/off setting no file holds flips it at once through cs\'s write, opening nothing: a flag writes 1 to turn its feature on, an off flag 1 to turn its feature off; cs\'s line is the toast, both sources are read again, and the keys\' line says Enter flip', async ($, on) => {
  const { w } = world(on, { env: { CS_BIN: BIN }, answer: argv => argv[2] === 'list' ? { stdout: GOLDEN } : { stdout: `${argv.at(-2)}=${argv.at(-1)} written\n` } })
  const pane = await openPane($)
  expect([await enter(pane, 'cs:CS_NERD_FONTS'), await enter(pane, 'cs:CS_STATUSLINE_DISABLE')]).toEqual([[], []])
  expect([writes(w), w.toasts]).toEqual([[[BIN, '-config', 'set', 'CS_NERD_FONTS', '1'], [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1']],
    ['CS_NERD_FONTS=1 written', 'CS_STATUSLINE_DISABLE=1 written']])
  expect([listings(w), w.lists]).toEqual([3, 3])
  expect(cardIn(bodyLines(await pane.drawn())).at(-1)).toBe(hint('Enter flip', 80))
  await focus($, 'cs:CS_NERD_FONTS')
  expect(cardIn(bodyLines(await pane.drawn())).at(-1)).toBe(hint('Enter flip', 80))
})

test('under a session name, Enter on an on/off setting no file holds flips it at once to the file the scope line names', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  expect(await enter(pane, 'cs:CS_NERD_FONTS')).toEqual([])
  await pane.press({ key: 'scope:machine' })
  expect(await enter(pane, 'cs:CS_STATUSLINE_DISABLE')).toEqual([])
  expect(writes(w)).toEqual([[BIN, 'alpha', '-config', 'set', 'CS_NERD_FONTS', '1'], [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1']])
})

test('Enter on a row nothing changes toasts the card\'s why and opens and writes nothing: the shell pins it, it changes from a shell, a managed setting owns it', async ($, on) => {
  const { w } = world(on, { rows: LOCKED })
  const pane = await openPane($)
  const chooser: string[][] = []
  for (const key of ['cs:CS_STATUSLINE_FRAME', 'cs:CS_NO_FUNCTION_HOOKS', 'mod:cs-mermaid.drawDiagrams']) chooser.push(await enter(pane, key))
  expect(w.toasts).toEqual([
    'Frame columns: CS_STATUSLINE_FRAME=6 in your environment wins; unset it there to change it here',
    'Mods: change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 loads no mod from the next launch, this panel included',
    'Draw mermaid diagrams: a managed setting owns it',
  ])
  expect([writes(w), w.sets, chooser]).toEqual([[], [], [[], [], []]])
})

test('Keep, or a pick of the value a row holds, closes the chooser and writes nothing, says nothing and reads nothing again', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  for (const [key, label] of [['cs:CS_STATUSLINE_CTX_WARN', 'Keep 50'], ['cs:CS_SCOPE_DISABLE', 'Keep'], ['cs:CS_STATUSLINE_LAYOUT', 'Keep'], ['mod:cs.bandBars', 'Keep 10'],
    ['mod:cs.bandPrompt', 'Keep']] as const) {
    await enter(pane, key)
    await pick(pane, label)
    expect(chooserIn(bodyLines(await pane.drawn())), `${key} after ${label}`).toEqual([])
  }
  for (const [key, value] of [['cs:CS_STATUSLINE_LAYOUT', 'band'], ['cs:CS_REWRITE_PROVIDER', 'claude'], ['mod:cs.bandPrompt', 'latest']] as const) {
    await enter(pane, key)
    await choose(pane, value)
    expect(chooserIn(bodyLines(await pane.drawn())), `${key} after ${value}`).toEqual([])
  }
  expect([writes(w), w.sets, w.toasts, listings(w), w.lists]).toEqual([[], [], [], 1, 1])
})

test('cs\'s reply is the toast: its line when the write lands, and when cs refuses, its own refusal', async ($, on) => {
  const { w } = world(on, { answer: argv => argv[2] === 'list' ? { stdout: GOLDEN } : argv.includes('CS_STATUSLINE_LAYOUT')
    ? { stdout: 'CS_STATUSLINE_LAYOUT=capsules in ~/.claude-sessions/alpha/.cs/local/config: applies at the next repaint\n' }
    : { exitCode: 1, stderr: 'Error: CS_SCOPE_BUDGET_MS is a whole number of milliseconds; got lots\n' } })
  const pane = await openPane($)
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT'); await choose(pane, 'capsules')
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS'); await submit(pane, 'lots')
  expect(w.toasts).toEqual([
    'CS_STATUSLINE_LAYOUT=capsules in ~/.claude-sessions/alpha/.cs/local/config: applies at the next repaint',
    'CS_SCOPE_BUDGET_MS not changed: exited 1: Error: CS_SCOPE_BUDGET_MS is a whole number of milliseconds; got lots',
  ])
})

// cs's reset of each file.
const RESET_MACHINE = [BIN, '-config', 'reset', '--yes']
const RESET_SESSION = [BIN, 'alpha', '-config', 'reset', '--yes']

test('reset all… swaps the keys\' line for its confirmation of the scope line\'s file; confirm runs cs -config reset --yes on that file, cs\'s line is the toast, both sources are read again and the keys\' line comes back; keep brings it back and runs nothing', async ($, on) => {
  let reply: Answer = { stdout: '3 settings removed from ~/.claude-sessions/alpha/.cs/local/config\n' }
  const { w } = world(on, { answer: argv => argv.includes('reset') ? reply : argv[2] === 'list' ? { stdout: GOLDEN } : {} })
  const pane = await openPane($)
  const foot = async () => bodyLines(await pane.drawn()).slice(-2).map(line => line.trimEnd())
  const reads = () => [listings(w), w.lists]
  expect([await foot(), reads()]).toEqual([[hint('Enter flip', 80), scopeLine(80)], [1, 1]])
  await pane.press({ key: 'reset' })
  expect([await foot(), writes(w), w.toasts]).toEqual([[confirming('remove 3 overrides from this session\'s file', 80), scopeLine(80)], [], []])
  await pane.press({ key: 'confirm' })
  expect([writes(w), w.toasts, reads(), await foot()]).toEqual([[RESET_SESSION], ['3 settings removed from ~/.claude-sessions/alpha/.cs/local/config'], [2, 2],
    [hint('Enter flip', 80), scopeLine(80)]])
  await pane.press({ key: 'reset' })
  await pane.press({ key: 'keep' })
  expect([writes(w), await foot()]).toEqual([[RESET_SESSION], [hint('Enter flip', 80), scopeLine(80)]])
  await pane.press({ key: 'scope:machine' })
  await pane.press({ key: 'reset' })
  expect(await foot()).toEqual([confirming('remove 1 override from this machine\'s file', 80), scopeLine(80, 'machine')])
  reply = { stdout: 'no settings file at ~/.config/cs/config; nothing to reset\n' }
  await pane.press({ key: 'confirm' })
  expect([writes(w), w.toasts.slice(1), reads()]).toEqual([[RESET_SESSION, RESET_MACHINE], ['no settings file at ~/.config/cs/config; nothing to reset'], [3, 3]])
})

test('with no session name reset all… confirms this machine\'s file and confirm resets it', async ($, on) => {
  const { w } = world(on, { env: { CS_BIN: BIN } })
  const pane = await openPane($)
  await pane.press({ key: 'reset' })
  expect(bodyLines(await pane.drawn()).at(-1)?.trimEnd()).toBe(confirming('remove 1 override from this machine\'s file', 80))
  await pane.press({ key: 'confirm' })
  expect(writes(w)).toEqual([RESET_MACHINE])
})

test('a reset cs refuses toasts its refusal and reads cs again; before cs first lists its settings reset all… says so and asks nothing', async ($, on) => {
  let list: Answer = { exitCode: 1, stderr: 'Error: boom\n' }
  const { w, clock } = world(on, { answer: argv => argv.includes('reset') ? { exitCode: 1, stderr: 'Error: cannot write ~/.claude-sessions/alpha/.cs/local/config: Permission denied\n' } : list })
  const pane = await openPane($)
  await pane.press({ key: 'reset' })
  expect([w.toasts, writes(w), bodyLines(await pane.drawn()).at(-2)]).toEqual([['cs has not listed its settings yet, so nothing was reset'], [], hint('Enter flip', 80)])
  list = { stdout: GOLDEN }
  await $.turn.complete(DONE)
  await clock.settle()
  const lists = w.lists
  await pane.press({ key: 'reset' })
  await pane.press({ key: 'confirm' })
  expect([writes(w), w.toasts.slice(1), w.lists]).toEqual([[RESET_SESSION], ['cs settings not reset: exited 1: Error: cannot write ~/.claude-sessions/alpha/.cs/local/config: Permission denied'],
    lists + 1])
})

test('Enter on a /config row changes it through $.config.set: a boolean toggles to its negation at once, a choice opens a picker of its options and Keep, a number its field and Keep <value>; abc is refused unwritten, a deny is toasted', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  expect(await enter(pane, 'mod:cs.bandPrompts')).toEqual([])
  expect(await enter(pane, 'mod:cs.bandPrompt')).toEqual([...picked('latest', ['latest', 'read']), options('Keep')])
  await choose(pane, 'read')
  expect(await enter(pane, 'mod:cs.bandBars')).toEqual(['    10', options('Keep 10')])
  await submit(pane, 'abc')
  await enter(pane, 'mod:cs.bandBars'); await submit(pane, '12')
  w.setDeny = 'Band: most bars takes a whole number of 1 or more'
  await enter(pane, 'mod:cs.bandBars'); await submit(pane, '0')
  expect(w.sets).toEqual([{ key: 'cs.bandPrompts', value: true }, { key: 'cs.bandPrompt', value: 'read' }, { key: 'cs.bandBars', value: 12 }, { key: 'cs.bandBars', value: 0 }])
  expect(w.toasts).toEqual([
    'cs.bandPrompts=true in /config: cs reloads with it',
    'cs.bandPrompt=read in /config: cs reloads with it',
    'Band: most bars takes a number; got abc',
    'cs.bandBars=12 in /config: cs reloads with it',
    'cs.bandBars not changed: Band: most bars takes a whole number of 1 or more',
  ])
  expect(writes(w)).toEqual([])
})

test('Enter on a row whose last change still runs says so and writes nothing', async ($, on) => {
  const written = gate()
  const { w, clock } = world(on, { answer: async argv => {
    if (argv[2] === 'list') return { stdout: GOLDEN }
    await written.held
    return { stdout: 'CS_STATUSLINE_DISABLE=1 in ~/.claude-sessions/alpha/.cs/local/config: applies at the next repaint\n' }
  } })
  const pane = await openPane($)
  const first = pane.press({ key: 'cs:CS_STATUSLINE_DISABLE' })
  await clock.settle()
  const second = pane.press({ key: 'cs:CS_STATUSLINE_DISABLE' })
  await clock.settle()
  expect(w.toasts).toEqual(['CS_STATUSLINE_DISABLE is still changing, or no longer listed; try again'])
  written.open()
  await Promise.all([first, second])
  await clock.settle()
  expect(writes(w)).toEqual([[BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_DISABLE', '1']])
  expect(w.toasts).toEqual(['CS_STATUSLINE_DISABLE is still changing, or no longer listed; try again',
    'CS_STATUSLINE_DISABLE=1 in ~/.claude-sessions/alpha/.cs/local/config: applies at the next repaint'])
})

// The terminal raises no ui.scroll while the ring is on a Select: its arrows
// move the Select's own highlight. The kit raises one wherever the ring is.
test('with a chooser open the arrows walk its elements, held to the first and the last, and the selection stays; Enter on the row puts the ring on its first element and a choice made puts it back on the row: each move goes by $.ui.focus, which the kit refuses, so the element marked for the ring is pinned', async ($, on) => {
  const { w, clock } = world(on)
  const pane = await openPane($)
  const scroll = async (by: number) => {
    expect(await $.ui.scroll({ component: 'Pane', requestId: 'cs-panel', offset: 0, by, bodyRows: 80, contentRows: 80, origin: { kind: 'person' } })).toEqual({})
    await clock.settle()
  }
  const shown = async () => {
    const tree = await pane.drawn()
    await clock.settle()
    return { card: cardIn(bodyLines(tree))[0], ring: nodesOf(tree).filter(n => n.props?.autoFocus === true).map(n => n.props.key) }
  }
  const layout = (ring: string) => ({ card: '▍ selected · Layout', ring: ['filter', ring] })
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')
  expect(await shown()).toEqual(layout('picker'))
  await scroll(1)
  expect(await shown()).toEqual(layout('option:Default (quiet)'))
  await scroll(5)
  expect(await shown()).toEqual(layout('option:Keep'))
  const moved = w.logs.length
  await scroll(1)
  expect([await shown(), w.logs.length]).toEqual([layout('option:Keep'), moved])
  await scroll(-10)
  expect(await shown()).toEqual(layout('picker'))
  expect(w.scrolls).toBe(0)
  await pick(pane, 'Keep')
  await clock.settle()
  expect(await shown()).toEqual(layout('cs:CS_STATUSLINE_LAYOUT'))
  // A typed row's field comes first.
  await enter(pane, 'cs:CS_SCOPE_BUDGET_MS')
  await scroll(1)
  expect((await shown()).ring).toEqual(['filter', 'option:Default (1500)'])
  await scroll(-1)
  expect((await shown()).ring).toEqual(['filter', 'typed'])
  // Enter, the three moves the ring makes, the ring back on the row, Enter and two moves.
  expect(w.logs).toEqual(Array.from({ length: 8 }, () => LOGS.failed('no implementation for ui.focus')))
})

test('Enter on another row opens its chooser and closes the first; the ring landing on another row or an edit of the filter closes it; a close forgets the chooser, the confirmation and the scope line\'s choice', { plugins: [CLOSER] }, async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const shown = async () => { const lines = bodyLines(await pane.drawn()); return { chooser: chooserIn(lines), foot: lines.slice(-2).map(line => line.trimEnd()) } }
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')
  expect(await enter(pane, 'cs:CS_TERM_THEME')).toEqual([...picked('dark', ['light', 'dark']), options('Keep')])
  expect(bodyLines(await pane.drawn()).filter(line => line.includes('capsules'))).toEqual([])
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  expect((await shown()).chooser).toEqual([])
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')
  await pane.input({ key: 'filter', text: 'lay', kind: 'change' })
  expect((await shown()).chooser).toEqual([])
  await pane.input({ key: 'filter', text: '', kind: 'change' })
  await pane.press({ key: 'scope:machine' })
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')
  await pane.press({ key: 'reset' })
  expect(await shown()).toEqual({ chooser: [], foot: [confirming('remove 1 override from this machine\'s file', 80), scopeLine(80, 'machine')] })
  await pane.press({ key: 'keep' })
  await enter(pane, 'cs:CS_STATUSLINE_LAYOUT')
  expect((await shown()).chooser).toEqual([...picked('band', ['quiet', 'band', 'capsules']), options('Default (quiet)', 'Keep')])
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  await pane.redraw()
  expect(await shown()).toEqual({ chooser: [], foot: [hint('Enter change', 80), scopeLine(80)] })
  await pane.press({ key: 'reset' })
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  await pane.redraw()
  expect((await shown()).foot).toEqual([hint('Enter change', 80), scopeLine(80)])
  expect([writes(w), w.sets]).toEqual([[], []])
})

test('a /config menu change of a cs mod\'s row reads the mod rows again and redraws; an engine row\'s change and a refused one do not', async ($, on) => {
  const { w, clock } = world(on)
  const pane = await openPane($)
  const bars = async () => bodyLines(await pane.drawn()).find(line => line.includes('Band: most bars'))?.trimEnd()
  expect(await bars()).toBe(`  ${'Band: most bars'.padEnd(26)}  ${'10'.padEnd(14)}  mod`)
  const read = w.lists
  w.rows = MOD_ROWS.map(r => r.key === 'cs.bandBars' ? { ...r, value: 12 } : r)
  await $.config.set({ key: 'cs.bandBars', value: 12, previous: 10, provider: CS, origin: { kind: 'composer' } })
  await clock.settle()
  expect(w.lists).toBe(read + 1)
  expect(await bars()).toBe(`  ${'Band: most bars'.padEnd(26)}  ${'12'.padEnd(14)}  mod`)
  await $.config.set({ key: 'theme', value: 'light', previous: 'dark', provider: { plugin: 'engine', tier: 'core' }, origin: { kind: 'composer' } })
  w.setDeny = 'no'
  await $.config.set({ key: 'cs.bandBars', value: 0, previous: 12, provider: CS, origin: { kind: 'composer' } })
  await clock.settle()
  expect(w.lists).toBe(read + 1)
})

test('a failed or unreadable porcelain and unreadable /config rows keep the rows and draw why above them; the next good answer clears it; only an open pane reads at a main-loop turn\'s end', { plugins: [CLOSER] }, async ($, on) => {
  let list: Answer = { stdout: GOLDEN }
  const { w, clock } = world(on, { answer: () => list })
  const pane = await openPane($)
  const read = async (next: Answer) => {
    list = next
    await $.turn.complete(DONE)
    await clock.settle()
    const tree = await pane.drawn()
    return { above: aboveIn(bodyLines(tree)), card: cardIn(bodyLines(tree)), rows: rowsOf(tree).length }
  }
  const card = ['▍ selected · Band: prompt bars', '▍ ○ off · mod · changing it reloads cs (an armed rotation countdown starts over)', '▍ cs.bandPrompts', hint('Enter flip', 80),
    scopeLine(80)]
  expect(await read({ exitCode: 1, stderr: 'warming up\nError: boom\n' })).toEqual({ above: ['cs -config list exited 1: Error: boom'], card, rows: 46 })
  expect(await read({ stdout: 'oops\n' })).toEqual({ above: ['cs -config list gave a line the panel cannot read: oops'], card, rows: 46 })
  expect(await read({ stdout: '' })).toEqual({ above: ['cs -config list printed no settings'], card, rows: 46 })
  w.rowsDeny = 'the menu is busy'
  expect(await read({ stdout: GOLDEN })).toEqual({ above: ['the /config rows could not be read: cs-panel: $.config.list: the menu is busy'], card, rows: 46 })
  w.rowsDeny = undefined
  expect(await read({ stdout: GOLDEN })).toEqual({ above: [], card, rows: 46 })
  const runs = w.runs.length
  await $.turn.complete({ ...DONE, agentId: 'a1' })
  await clock.settle()
  expect(w.runs.length).toBe(runs)
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  await $.turn.complete(DONE)
  await clock.settle()
  expect(w.runs.length).toBe(runs)
})

test('typing in the field shows the rows it matches as it changes, keeps the selected row while it is shown, else selects the first shown; the arrows walk the rows shown; Enter sends the ring to the first; a close forgets the text', { plugins: [CLOSER] }, async ($, on) => {
  const { w, clock } = world(on)
  const pane = await openPane($)
  const type = async (text: string, kind: 'change' | 'submit' = 'change') => {
    await pane.input({ key: 'filter', text, kind })
    await clock.settle()
    const tree = await pane.drawn()
    return { card: cardIn(bodyLines(tree))[0], rows: rowsOf(tree).map(row => row.trimEnd()) }
  }
  const scroll = async (by: number) => {
    await $.ui.scroll({ component: 'Pane', requestId: 'cs-panel', offset: 0, by, bodyRows: 80, contentRows: 80, origin: { kind: 'person' } })
    await clock.settle()
    return cardIn(bodyLines(await pane.drawn()))[0]
  }
  const grounding = `  ${'Scope grounding'.padEnd(26)}  ${'○ off'.padEnd(14)}  session`
  const trace = `  ${'Scope trace'.padEnd(26)}  ● on`
  const budget = `  ${'Scope scan budget (ms)'.padEnd(26)}  1500`
  const selected = (row: string) => `▌${row.slice(1)}`
  await focus($, 'cs:CS_SCOPE_BUDGET_MS')
  expect(await type('scope')).toEqual({ card: '▍ selected · Scope scan budget (ms)', rows: [grounding, trace, selected(budget)] })
  const lines = bodyLines(await pane.drawn()).map(line => line.trimEnd())
  expect([lines[1], lines.slice(3, 6), lines.slice(6, 9)]).toEqual([boxed(80, WORDS_AT_80)[1], field(80, 'scope'),
    [counted(80, headAt(80).trimEnd(), '3 of 46'), soft(80), group('Prompts', 80)]])
  expect(await type('TRACE')).toEqual({ card: '▍ selected · Scope trace', rows: [selected(trace)] })
  expect((await type('')).rows.length).toBe(46)
  expect(await type('scope')).toEqual({ card: '▍ selected · Scope scan budget (ms)', rows: [grounding, trace, selected(budget)] })
  expect([await scroll(-1), await scroll(-1), await scroll(5), await scroll(-5)])
    .toEqual(['▍ selected · Scope trace', '▍ selected · Scope grounding', '▍ selected · Scope scan budget (ms)', '▍ selected · Scope grounding'])
  const logs = w.logs.length
  expect(await scroll(-1)).toBe('▍ selected · Scope grounding')
  expect(w.logs.length).toBe(logs + 1)
  await focus($, 'cs:CS_SCOPE_BUDGET_MS')
  // Enter in the field: the first row shown is selected and the ring sent to
  // it, which the kit refuses and the mod logs.
  expect(await type('scope', 'submit')).toEqual({ card: '▍ selected · Scope grounding', rows: [selected(grounding), trace, budget] })
  expect(w.logs.slice(logs + 1)).toEqual([LOGS.failed('no implementation for ui.focus')])
  // Reopened, the pane is drawn afresh.
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  await pane.redraw()
  expect([(await pane.find({ key: 'filter' }))?.props.value, rowsOf(await pane.drawn()).length]).toEqual(['', 46])
})

test('the first porcelain failing draws the mod rows and why, with no settings rows', async ($, on) => {
  world(on, { answer: () => ({ exitCode: 127, stderr: 'cs: command not found\n' }) })
  const pane = await openPane($)
  const tree = await pane.drawn()
  const lines = bodyLines(tree).map(line => line.trimEnd())
  expect(aboveIn(lines)).toEqual(['cs -config list exited 127: cs: command not found'])
  expect([lines[lines.indexOf(soft(80)) + 1], rowsOf(tree).length]).toEqual([group('Mods', 80), 5])
})

test('the masthead draws the version cs -version prints, asked once a load when the pane first opens; a failed or unreadable answer is logged, draws none, and the next open asks again', { plugins: [CLOSER] }, async ($, on) => {
  const answers: { version: Answer } = { version: { exitCode: 1, stderr: 'warming up\nboom\n' } }
  const { w } = world(on, answers)
  const pane = await openPane($)
  const reopen = async () => {
    await $.command.run({ ...COMMAND, command: 'close-panel' })
    expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  }
  const words = async () => { await pane.redraw(); return bodyLines(await pane.drawn())[1] }
  const asked = () => w.runs.filter(argv => argv.join(' ') === ASK_VERSION.join(' ')).length
  const unversioned = boxed(80, 'claude-sessions · 46 settings · 5 overrides · alpha')[1]
  expect([await words(), w.logs, asked()]).toEqual([unversioned, ['cs -version exited 1: boom'], 1])
  answers.version = { stdout: 'claude-sessions 2026.10.11\n' }
  await reopen()
  expect([await words(), w.logs.slice(1), asked()]).toEqual([unversioned, ['cs -version printed claude-sessions 2026.10.11'], 2])
  answers.version = { stdout: 'cs 2026.10.11\n' }
  await reopen()
  expect([await words(), w.logs.length, asked()]).toEqual([boxed(80, WORDS_AT_80)[1], 2, 3])
  await reopen()
  expect([await words(), w.logs.length, asked()]).toEqual([boxed(80, WORDS_AT_80)[1], 2, 3])
})

test('a launch that found a newer cs (CS_UPDATE_AVAILABLE) draws a second line in the masthead naming it and cs -update, over the search box', async ($, on) => {
  world(on, { env: { CS_BIN: BIN, CLAUDE_SESSION_NAME: 'alpha', CS_UPDATE_AVAILABLE: '2026.10.12' } })
  const pane = await openPane($)
  expect(bodyLines(await pane.drawn()).slice(0, 5)).toEqual([...boxed(80, WORDS_AT_80, 'cs 2026.10.12 available · run cs -update'), field(80)[0]])
})

test('the session start registers /cs-panel once, to run mid-turn too, and opens nothing', async ($, on) => {
  const { w } = world(on)
  const specs: unknown[] = []
  on('command.register', ($, e) => { specs.push({ ...e }); return { value: { command: e.name } } })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/sessions/alpha', surface: 'terminal', isInteractive: true })
  await $.session.start({ cwd: '/sessions/alpha', surface: 'terminal', isInteractive: true })
  expect(specs).toEqual([{ name: 'cs-panel', description: "cs's settings: its mods' /config rows and its own CS_* settings, per machine or per session.", immediate: true }])
  expect(w.opens).toEqual([])
})

test('the pane draws on every surface, its rows as Buttons, its field as an Input in the search box and a choice\'s picker as a Select, but on the mobile app, which draws neither: there three empty lines stand in the box\'s place, so the chrome is as tall, and a choice offers Buttons', async ($, on) => {
  world(on)
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const pane = await $.ui.mount({ plugin: 'cs-panel', surface, component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
    expect((await pane.find({ key: 'cs:CS_STATUSLINE_LAYOUT' }))?.props.label, surface).toBe('Layout')
    expect((await pane.find({ key: 'filter' }))?.type, surface).toBe(surface === 'mobile' ? undefined : 'Input')
    const drawn = bodyLines(await pane.drawn())
    expect([drawn.slice(3, 6), drawn[6]?.trimEnd(), drawn.length, drawn.slice(-2)], surface)
      .toEqual([surface === 'mobile' ? [' ', ' ', ' '] : field(80), headAt(80).trimEnd(), 8 + GOLDEN_LINES + 6, [hint('Enter flip', 80), scopeLine(80)]])
    await pane.unmount()
  }
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const pane = await $.ui.mount({ plugin: 'cs-panel', surface, component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
    await pane.press({ key: 'cs:CS_STATUSLINE_LAYOUT' })
    expect([(await pane.find({ key: 'picker' }))?.type, (await pane.find({ key: 'option:capsules' }))?.type], surface)
      .toEqual(surface === 'mobile' ? [undefined, 'Button'] : ['Select', undefined])
    await pane.press({ key: 'option:Keep' })
    await pane.unmount()
  }
})

test('on the mobile app, which draws no Input or Select, a typed setting\'s chooser is its Default and Keep alone and the ring skips the field; a choice\'s chooser is its other choices, Default while a file holds it, and Keep, as Buttons that write as the picker does', async ($, on) => {
  const { w } = world(on)
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'mobile', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  await pane.press({ key: 'cs:CS_STATUSLINE_CTX_WARN' })
  expect([chooserIn(bodyLines(await pane.drawn())), (await pane.find({ key: 'typed' }))?.type]).toEqual([[options('Default (40)', 'Keep 50')], undefined])
  expect(ringOf(viewOf({ hasField: false, selected: 'cs:CS_STATUSLINE_CTX_WARN', chooser: opened('cs:CS_STATUSLINE_CTX_WARN', '50') })).keys.filter(key => key.startsWith('option:') || key === 'typed'))
    .toEqual(['option:Default (40)', 'option:Keep 50'])
  await pane.press({ key: 'cs:CS_STATUSLINE_LAYOUT' })
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([options('quiet', 'capsules', 'Default (quiet)', 'Keep')])
  expect(ringOf(viewOf({ hasField: false, selected: 'cs:CS_STATUSLINE_LAYOUT', chooser: opened('cs:CS_STATUSLINE_LAYOUT') })).keys.filter(key => key.startsWith('option:') || key === 'picker'))
    .toEqual(['option:quiet', 'option:capsules', 'option:Default (quiet)', 'option:Keep'])
  await pane.press({ key: 'option:capsules' })
  await pane.press({ key: 'cs:CS_STATUSLINE_LAYOUT' }); await pane.press({ key: 'option:Default (quiet)' })
  await pane.press({ key: 'mod:cs.bandPrompt' })
  expect(chooserIn(bodyLines(await pane.drawn()))).toEqual([options('read', 'Keep')])
  await pane.press({ key: 'option:read' })
  expect([writes(w), w.sets]).toEqual([[[BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'], [BIN, '-config', 'unset', 'CS_STATUSLINE_LAYOUT']],
    [{ key: 'cs.bandPrompt', value: 'read' }]])
})

test('no line the mod hands the engine names the plugin first: the engine prefixes it', () => {
  const call = (f: unknown) => typeof f === 'string' ? f : (f as (...args: string[]) => string)('x', 'y', 'z')
  const lines = [
    COMMANDS['cs-panel'].description, ...Object.values(REPLIES).map(call),
    ...Object.values(TOASTS).map(call), ...Object.values(PROBLEMS).map(call), ...Object.values(LOGS).map(call),
  ]
  expect(lines.length).toBe(19)
  expect(lines.filter(line => line.toLowerCase().startsWith('cs-panel'))).toEqual([])
})
