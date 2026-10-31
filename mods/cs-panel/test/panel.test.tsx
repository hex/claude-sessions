// ABOUTME: Engine test-kit tests for the cs-panel mod: cs's porcelain and the /config rows as settings rows, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from design.md's rules, config-verb.md's reply shapes and the golden porcelain (test/golden.ts), never from the code under test.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { ConfigRow, On, PaneOpenArgs } from 'claude-code'

import { GOLDEN } from './golden'
import { drawPane, ringBack, ringOf, type PanelView } from '../hooks/draw'
import { ASKS, COMMANDS, LOGS, PROBLEMS, REPLIES, TOASTS } from '../hooks/register'
import { linesOf, modRowsOf, parseSettings, type RowId, type Setting } from '../hooks/settings'

// What `$.config.list()` answers in these tests: the five rows cs's mods
// declare, an engine row and a row of a cs-* plugin that is not one of them.
const CS = { plugin: 'cs', tier: 'user' } as const
const MOD_ROWS: ConfigRow[] = [
  { key: 'theme', label: 'Theme', kind: 'choice', value: 'dark', options: ['dark', 'light'], provider: { plugin: 'engine', tier: 'core' }, isLocked: false },
  { key: 'cs.bandPrompts', label: 'Band: prompt bars', kind: 'boolean', value: false, provider: CS, isLocked: false },
  { key: 'cs.bandPrompt', label: 'Band: named prompt', kind: 'choice', value: 'latest', options: ['latest', 'read'], provider: CS, isLocked: false },
  { key: 'cs.bandBars', label: 'Band: most bars', kind: 'number', value: 10, provider: CS, isLocked: false },
  { key: 'cs-feed.digest', label: 'Feed digest', kind: 'boolean', value: true, provider: { plugin: 'cs-feed', tier: 'user' }, isLocked: false },
  { key: 'cs-update.showReleaseNotes', label: 'Release notes pane', kind: 'boolean', value: true, provider: { plugin: 'cs-update', tier: 'user' }, isLocked: false },
  { key: 'cs-mermaid.drawDiagrams', label: 'Draw mermaid diagrams', kind: 'boolean', value: true, provider: { plugin: 'cs-mermaid', tier: 'user' }, isLocked: false },
]
const LOCKED: ConfigRow[] = MOD_ROWS.map(r => r.key === 'cs-mermaid.drawDiagrams' ? { ...r, isLocked: true } : r)

function settingsOf(stdout: string): Setting[] {
  const parsed = parseSettings(stdout)
  if ('unreadable' in parsed) throw new Error(`the fixture is unreadable: ${parsed.unreadable}`)
  return parsed
}

test('the golden porcelain parses to its 41 settings in cs\'s order, cs\'s words kept and `-` read as none', () => {
  const settings = settingsOf(GOLDEN)
  expect(settings.length).toBe(41)
  expect(settings[0]?.key).toBe('CS_STATUSLINE_DISABLE')
  expect(settings[40]?.key).toBe('CS_NO_FUNCTION_HOOKS')
  expect(settings[1]).toEqual({ key: 'CS_STATUSLINE_LAYOUT', group: 'Status line', label: 'Layout', edit: 'choice', choices: ['quiet', 'band', 'capsules'],
    fallback: 'quiet', when: 'now', whenText: 'applies at the next repaint', value: 'band', source: 'machine', ignored: undefined })
  expect(settings[3]).toEqual({ key: 'CS_STATUSLINE_BAND', group: 'Status line', label: 'Band colour', edit: 'text', choices: [], fallback: 'session', when: 'now',
    whenText: 'applies at the next repaint', value: undefined, source: 'default', ignored: 'machine line 4: CS_STATUSLINE_BAND=magenta: not a palette name, brand, periwinkle, session, none or r;g;b' })
  expect(settings.find(s => s.key === 'CS_NO_MAIL_WAKE')).toEqual({ key: 'CS_NO_MAIL_WAKE', group: 'Turn end', label: 'No mail wake', edit: 'flag', choices: [],
    fallback: 'off', when: 'now', whenText: 'applies when the next turn ends', value: undefined, source: 'session', ignored: undefined })
})

// cs's readers take any word for a flag the shell exports (`-n` tests), and
// cs prints that word with source shell: the pane draws it as it is and offers
// no key, and keeps every other row.
test('a flag the shell pins to a word other than 1 parses, draws that word and offers no key', async ($, on) => {
  const row = 'CS_NERD_FONTS\tTerminal\tNerd Font glyphs\tflag\t-\toff\tnow\tapplies at the next cs command\t'
  const pinned = GOLDEN.replace(`${row}-\tdefault\t-`, `${row}0\tshell\t-`)
  expect(pinned).not.toBe(GOLDEN)
  const settings = settingsOf(pinned)
  expect(settings.length).toBe(41)
  expect(settings.find(s => s.key === 'CS_NERD_FONTS')).toMatchObject({ value: '0', source: 'shell' })
  const { lines } = await drawer($, on)(viewOf({ selected: 'cs:CS_NERD_FONTS', lines: linesOf(modRowsOf(MOD_ROWS), settings, new Map(), true) }))
  expect(headOf(lines).join(' ')).toBe('Esc: close CS_NERD_FONTS=0 in your environment wins; unset it there to change it here')
  expect(lines.map(line => line.trimEnd())).toContain('▌ Nerd Font glyphs     0               shell')
})

test('one line outside the record refuses the whole answer, naming that line; an empty answer is refused too', () => {
  const good = 'CS_NO_TASK_TOOLS\tLaunch\tNo task tools\tflag\t-\toff\tlaunch\tapplies at the next launch\t-\tdefault\t-'
  const bad = [
    good.split('\t').slice(0, 10).join('\t'),
    `${good}\t-`,
    good.replace('CS_NO_TASK_TOOLS', 'cs_no_task_tools'),
    good.replace('\tflag\t', '\ttoggle\t'),
    good.replace('\tdefault\t', '\tenv\t'),
    good.replace('\tNo task tools\t', '\t\t'),
    good.replace('\tflag\t-\t', '\tchoice\t-\t'),
    good.replace('\tflag\t-\t', '\ttext\ta,b\t'),
  ]
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

const NOOP = { select: () => {}, act: () => {} }

// The text one line of the drawing shows on the terminal, from the plain-data
// tree: a Button draws its children, or its label when it has none, after
// `<hotkey>: ` when it is plain with a hotkey (the 2.1.316 terminal's Button),
// and a row Box puts its columnGap between its children and its paddingX
// either side of them.
type Node = { type: string; props: Record<string, unknown>; children?: unknown[] }
function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  const n = node as Node
  const children = n.children ?? []
  if (n.type === 'Button') {
    const shown = children.length === 0 ? String(n.props.label) : children.map(textOf).join('')
    return n.props.plain === true && n.props.hotkey !== undefined ? `${n.props.hotkey}: ${shown}` : shown
  }
  if (n.type !== 'Box') return children.map(textOf).join('')
  const pad = ' '.repeat(Number(n.props.paddingX ?? 0))
  return `${pad}${children.map(textOf).join(' '.repeat(Number(n.props.columnGap ?? 0)))}${pad}`
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

// The body's lines top to bottom: a column Box (the stacked strip) gives one
// line per child.
function bodyLines(tree: unknown): string[] {
  const root = tree as { children?: unknown[] }
  return (root.children ?? []).flatMap(child => {
    const c = child as { type: string; props: Record<string, unknown>; children?: unknown[] }
    return c.type === 'Box' && c.props.flexDirection === 'column' ? (c.children ?? []).map(textOf) : [textOf(c)]
  })
}

function fixtureProps(v: PanelView) {
  return { title: 'cs', isFocused: v.hasKeys, bodyColumns: v.columns, placement: 'inline', scroll: { offset: 0, bodyRows: v.bodyRows }, view: {} } as const
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
  return { lines: linesOf(modRowsOf(rows), settingsOf(porcelain), new Map(), hasSelf), selected: undefined, problems: [], columns: 58, bodyRows: 70, hasKeys: true,
    session: hasSelf ? 'alpha' : undefined, ...rest }
}

// The rows of a drawing: the row Boxes, each holding a Button keyed by its
// RowId (a strip key's is `act:`), as the terminal shows them.
const rowsOf = (tree: unknown) => nodesOf(tree).filter(n => n.type === 'Box' && (n.children ?? []).some(c => (c as Node).type === 'Button' && /^(cs|mod):/.test(String((c as Node).props.key)))).map(textOf)
// The lines between the masthead's two lines and its empty line, and the
// empty line under them: the strip, the detail and the problem lines.
const headOf = (lines: string[]) => lines.slice(3, lines.findIndex((line, i) => i > 3 && line.trim() === ''))
// The masthead's second line and the column header's rule, the body wide.
const hero = (columns: number) => '━'.repeat(columns)
const soft = (columns: number) => '─'.repeat(columns)

// tui/src/theme.rs's two palettes, which the pane takes by CS_TERM_THEME.
const TUI = {
  dark: { ink: 'rgb(245,230,211)', mut: 'rgb(161,136,127)', faint: 'rgb(120,104,96)', soft: 'rgb(56,50,46)', wash: 'rgb(60,46,36)', teal: 'rgb(45,212,191)',
    green: 'rgb(139,195,74)', amber: 'rgb(246,154,0)', hero: ['rgb(221,80,20)', 'rgb(237,128,0)', 'rgb(246,154,0)', 'rgb(214,162,30)'], rail: ['rgb(221,80,20)', 'rgb(246,154,0)', 'rgb(250,180,60)'] },
  light: { ink: 'rgb(43,33,24)', mut: 'rgb(122,106,88)', faint: 'rgb(168,151,130)', soft: 'rgb(226,213,196)', wash: 'rgb(255,240,218)', teal: 'rgb(15,118,110)',
    green: 'rgb(92,140,84)', amber: 'rgb(242,167,53)', hero: ['rgb(143,50,28)', 'rgb(216,90,36)', 'rgb(242,167,53)', 'rgb(214,162,30)'], rail: ['rgb(193,58,29)', 'rgb(228,91,34)', 'rgb(232,167,46)'] },
}
const DARK = TUI.dark

// The masthead, the empty line, the strip and the detail of the first row,
// the empty line and the column header at the dock's 58 columns: 46 settings
// of which the golden's five files and shell set (the launch's Theme is no
// change); the session name does not fit beside them.
const MASTHEAD_AT_58 = '▌ claude-sessions  settings  ·  46 settings  ·  5 changed'
const HEAD_AT_58 = ['  setting              value           from     when', soft(58)]

// design.md's columns at the dock's 58-column body: the name in 19 cells, then
// value 14 (a gauge and its number), from 7 and when 10, each after a gap of
// 2, under each group's name with an empty line above every group but the
// first; the golden's fields through them, worked out apart from the mod. A
// default row leaves from and when empty, and when is drawn only when it is
// not `now`, so only what a file, the shell or the launch sets reads there.
const GOLDEN_AT_58 = [
  '  Mods',
  '▌ Band: prompt bars    ○ off           mod',
  '  Band: named prompt   latest          mod',
  '  Band: most bars      10              mod',
  '  Release notes pane   ● on            mod',
  '  Draw mermaid diagr…  ● on            mod',
  '',
  '  Status line',
  '  Hide the status li…  ○ off',
  '  Layout               band            machine',
  '  Segments             logo,session,…',
  '  Band colour          session',
  '  Width in columns     measured',
  '  Frame columns        6               shell',
  '  Context warn %       ▰▰▰▰▰▱▱▱▱▱ 50   session',
  '  Context critical %   ▰▰▰▰▰▰▰▱▱▱ 65',
  '  Usage from cache o…  ○ off',
  '  Hide the subagent …  ○ off',
  '',
  '  Prompts',
  '  No scope grounding   ● on            session',
  '  No scope trace       ○ off',
  '  Scope scan budget …  1500',
  '  No objective captu…  ○ off',
  '  No date reminder     ○ off',
  '  No clarifying ques…  ○ off',
  '',
  '  Turn end',
  '  Context warning %    ▰▰▰▰▱▱▱▱▱▱ 40',
  '  Rotation nudge %     ▰▰▰▰▰▰▰▱▱▱ 65',
  '  Queue stops after …  5',
  '  Queue stops past c…  ▰▰▰▰▰▰▰▰▰▱ 85',
  '  Queue stops past 5…  ▰▰▰▰▰▰▰▰▰▱ 85',
  '  Mail wakes in a row  5',
  '  No mail wake         ○ off           session',
  '  Narrative budget (…  131072',
  '  Narrative tail kep…  65536',
  '',
  '  Rotation',
  '  Rotate on its own …  ▰▰▰▰▰▰▰▰▱▱ 80',
  '  Rotate button from…  the warn %',
  '  No wake after /cle…  ○ off',
  '  Wake delay (s)       2',
  '',
  '  Rewriter (ctrl+g)',
  '  Provider             claude',
  '  Model                per provider',
  '  Timeout (s)          25',
  '  Progress             screen',
  '  No rewrite           ○ off',
  '',
  '  Terminal',
  '  Theme                dark            launch',
  '  Background r;g;b     detected',
  '  No iTerm2 features   ○ off',
  '  Nerd Font glyphs     ○ off',
  '',
  '  Launch',
  '  No task tools        ○ off',
  '  No update check      ○ off',
  '  No mods              off',
]

test('the golden porcelain and the mod rows draw under the masthead, the first row\'s strip and detail and the column header, Mods first, each row exactly the body wide', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  expect(lines.map(line => line.trimEnd())).toEqual([
    MASTHEAD_AT_58, hero(58), '',
    'c: change   Esc: close',
    'cs.bandPrompts · changing it reloads cs (an armed rotation',
    'countdown starts over)',
    '', ...HEAD_AT_58,
    ...GOLDEN_AT_58,
  ])
  const rows = rowsOf(tree)
  expect(rows.length).toBe(46)
  expect(rows.filter(line => line.length !== 58)).toEqual([])
  // With no mod rows, the first group follows the column header's rule.
  expect((await draw(viewOf({ rows: [] }))).lines.slice(3, 9).map(line => line.trimEnd())).toEqual([
    'c: change   p: this session only   Esc: close', 'CS_STATUSLINE_DISABLE · applies at the next repaint', '', ...HEAD_AT_58, '  Status line'])
  expect((await draw({ ...viewOf(), lines: undefined })).lines.map(line => line.trimEnd()))
    .toEqual(['▌ claude-sessions  settings  ·  alpha', hero(58), '', 'Esc: close', 'asking cs for its settings…'])
})

test('a row offers c, u where a file sets it and p under a session name; a shell row, CS_NO_FUNCTION_HOOKS and a locked row offer no key and say why', async ($, on) => {
  const draw = drawer($, on)
  const head = async (selected: RowId, over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[] } = {}) => {
    const { lines } = await draw(viewOf({ selected, ...over }))
    return headOf(lines)
  }
  expect(await head('cs:CS_STATUSLINE_LAYOUT')).toEqual(['c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT · applies at the next repaint'])
  expect(await head('cs:CS_STATUSLINE_DISABLE')).toEqual(['c: change   p: this session only   Esc: close', 'CS_STATUSLINE_DISABLE · applies at the next repaint'])
  expect(await head('cs:CS_STATUSLINE_LAYOUT', { hasSelf: false })).toEqual(['c: change   u: default   Esc: close', 'CS_STATUSLINE_LAYOUT · applies at the next repaint'])
  expect((await head('cs:CS_STATUSLINE_CTX_WARN', { hasSelf: false }))[0]).toBe('Esc: close')
  expect(await head('cs:CS_STATUSLINE_BAND')).toEqual(['c: change   p: this session only   Esc: close',
    'CS_STATUSLINE_BAND · machine line 4:', 'CS_STATUSLINE_BAND=magenta: not a palette name, brand,…'])
  expect(await head('cs:CS_STATUSLINE_FRAME')).toEqual(['Esc: close', 'CS_STATUSLINE_FRAME=6 in your environment wins; unset it', 'there to change it here'])
  expect(await head('cs:CS_NO_FUNCTION_HOOKS')).toEqual(['Esc: close', 'change it from a shell: cs -config set', 'CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the…'])
  expect(await head('cs:CS_NO_FUNCTION_HOOKS', { columns: 130 })).toEqual(['Esc: close',
    'change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the next launch, this panel too)'])
  expect(await head('mod:cs-mermaid.drawDiagrams', { rows: LOCKED })).toEqual(['Esc: close', 'cs-mermaid.drawDiagrams · a managed setting owns it'])
  const { lines } = await draw(viewOf({ rows: LOCKED }))
  expect(lines.map(line => line.trimEnd())).toContain('  Draw mermaid diagr…  ● on            locked')
  expect(ringOf(viewOf({ selected: 'cs:CS_STATUSLINE_FRAME' })).keys.filter(k => k.startsWith('act:'))).toEqual([])
  expect(await head('cs:CS_STATUSLINE_LAYOUT', { hasKeys: false })).toEqual(['c: change   u: default   p: this session only', 'CS_STATUSLINE_LAYOUT · applies at the next repaint'])
  expect((await head('cs:CS_STATUSLINE_FRAME', { hasKeys: false }))[0]).toBe('ctrl+x tab: keys')
})

test('every row, the masthead, the strip and the detail fit 24, 40, 58, 60 and 80 columns, and 46 rows in 12 lines keep the selected row drawn', async ($, on) => {
  const draw = drawer($, on)
  const ids: RowId[] = [...modRowsOf(MOD_ROWS).map(m => `mod:${m.key}` as const), ...settingsOf(GOLDEN).map(s => `cs:${s.key}` as const)]
  expect(ids.length).toBe(46)
  for (const columns of [24, 40, 58, 60, 80]) {
    for (const selected of ids) {
      const { lines, label, tree } = await draw(viewOf({ columns, bodyRows: 12, selected }), selected)
      const rows = rowsOf(tree)
      expect(rows.filter(row => row.length !== columns), `rows at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => line.length > columns), `lines past ${columns} with ${selected}`).toEqual([])
      expect([lines[1], lines.find(line => line.startsWith('─'))], `the rules at ${columns}`).toEqual([hero(columns), soft(columns)])
      expect(lines.length <= 12, `${lines.length} lines in 12 at ${columns} with ${selected}`).toBe(true)
      expect(rows.filter(row => row.startsWith('▌ ')).length, `the selected row at ${columns} with ${selected}`).toBe(1)
      expect(label, `${selected} drawn at ${columns}`).not.toBe(undefined)
    }
  }
  expect((await draw(viewOf({ columns: 24, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.slice(3, 6)).toEqual(['c: change', 'u: default', 'p: session'])
  expect((await draw(viewOf({ columns: 40, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines[3]).toBe('c: change   u: default   p: session')
  // 61 lines (46 rows, 8 group names, the 7 empty lines above all but the
  // first) in the 4 lines of 12 the masthead, the strip, a one-line detail and
  // the column header leave, 3 under a two-line detail: the window holds the
  // selected row and the next, or the rows at the end it touches, and +N
  // counts the rows it leaves out; no rows above draws the lines above instead.
  const at = async (selected: RowId) => (await draw(viewOf({ columns: 58, bodyRows: 12, selected }))).lines.map(line => line.trimEnd())
  const top = [MASTHEAD_AT_58, hero(58), '']
  expect(await at('cs:CS_STATUSLINE_LAYOUT')).toEqual([...top,
    'c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT · applies at the next repaint', '', ...HEAD_AT_58,
    '+6 above',
    '▌ Layout               band            machine',
    '  Segments             logo,session,…',
    '+38 below',
  ])
  expect(await at('cs:CS_STATUSLINE_DISABLE')).toEqual([...top,
    'c: change   p: this session only   Esc: close', 'CS_STATUSLINE_DISABLE · applies at the next repaint', '', ...HEAD_AT_58,
    '+5 above',
    '▌ Hide the status li…  ○ off',
    '  Layout               band            machine',
    '+39 below',
  ])
  expect(await at('mod:cs.bandPrompts')).toEqual([...top,
    'c: change   Esc: close', 'cs.bandPrompts · changing it reloads cs (an armed rotation', 'countdown starts over)', '', ...HEAD_AT_58,
    '  Mods',
    '▌ Band: prompt bars    ○ off           mod',
    '+45 below',
  ])
  expect(await at('cs:CS_NO_UPDATE_CHECK')).toEqual([...top,
    'c: change   p: this session only   Esc: close', 'CS_NO_UPDATE_CHECK · applies at the next launch', '', ...HEAD_AT_58,
    '+43 above',
    '  No task tools        ○ off',
    '▌ No update check      ○ off',
    '  No mods              off',
  ])
  expect(await at('cs:CS_NO_FUNCTION_HOOKS')).toEqual([...top,
    'Esc: close', 'change it from a shell: cs -config set', 'CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the…', '', ...HEAD_AT_58,
    '+44 above',
    '  No update check      ○ off',
    '▌ No mods              off',
  ])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 12, selected: 'cs:CS_STATUSLINE_DISABLE' })).keys)
    .toEqual(['act:change', 'act:session', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT'])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 12, selected: 'mod:cs.bandPrompts' })).keys).toEqual(['act:change', 'mod:cs.bandPrompts'])
})

test('a drawing that moves the Button the ring was put on sends the ring back to that key, else to the selected row; one that moves nothing sends it nowhere', () => {
  const layout = viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' })
  const disable = viewOf({ selected: 'cs:CS_STATUSLINE_DISABLE' })
  expect(ringOf(layout).keys.slice(0, 4)).toEqual(['act:change', 'act:unset', 'act:session', 'mod:cs.bandPrompts'])
  expect(ringOf(layout).selected).toBe('cs:CS_STATUSLINE_LAYOUT')
  expect(ringOf(disable).keys.slice(0, 3)).toEqual(['act:change', 'act:session', 'mod:cs.bandPrompts'])
  expect(ringOf(layout).keys.filter(k => !/^(act|mod|cs):/.test(k))).toEqual([])
  // p held the third place under LAYOUT's three keys; DISABLE's two hand it
  // to the first row, so the ring goes back to p, still drawn.
  expect(ringBack({ key: 'act:session', at: 2 }, ringOf(disable))).toBe('act:session')
  // DISABLE offers no u: the ring goes to the selected row.
  expect(ringBack({ key: 'act:unset', at: 1 }, ringOf(disable))).toBe('cs:CS_STATUSLINE_DISABLE')
  expect(ringBack({ key: 'act:change', at: 0 }, ringOf(disable))).toBe(undefined)
})

// ── The look ─────────────────────────────────────────────────────────────

// install.sh.in's show_banner: the wordmark's letters, rust #e64a19 to gold
// #ffc107. On a light terminal lib/05-term.sh's muted rust and gold end it.
const WORDMARK_DARK = [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16],
  [245, 142, 15], [246, 151, 14], [248, 159, 12], [250, 168, 11], [252, 176, 10], [254, 185, 9], [255, 193, 7]].map(([r, g, b]) => `rgb(${r},${g},${b})`)
const LIGHT = GOLDEN.replace('applies at the next repaint\tdark\tlaunch', 'applies at the next repaint\tlight\tlaunch')
// The golden with three settings set (Layout by the machine's file, No scope
// grounding and No mail wake by this session's), and with none: each other
// record a file or the shell sets put back to the default.
const THREE = GOLDEN.replace('\t6\tshell\t', '\t-\tdefault\t').replace('\t50\tsession\t', '\t-\tdefault\t')
const NONE = THREE.replace('\tband\tmachine\t', '\t-\tdefault\t').replace('\t1\tsession\t', '\t-\tdefault\t').replace('when the next turn ends\t-\tsession\t', 'when the next turn ends\t-\tdefault\t')
// The golden with No wake after /clear set in this session's file.
const CLEARED = GOLDEN.replace('applies at the next /clear or launch\t-\tdefault\t-', 'applies at the next /clear or launch\t1\tsession\t-')

test('the masthead is ▌ and the wordmark, then settings, how many settings, how many are changed and the session name, dropped from the right where they do not fit', async ($, on) => {
  const draw = drawer($, on)
  const first = async (over: Partial<PanelView> & { hasSelf?: boolean; porcelain?: string }) => (await draw(viewOf(over))).lines[0]
  const set = (porcelain: string) => settingsOf(porcelain).filter(s => s.source === 'session' || s.source === 'machine' || s.source === 'shell').map(s => s.key)
  expect([set(THREE), set(NONE)]).toEqual([['CS_STATUSLINE_LAYOUT', 'CS_SCOPE_DISABLE', 'CS_NO_MAIL_WAKE'], []])
  for (const [porcelain, changed] of [[THREE, 3], [NONE, 0]] as const) {
    expect(await first({ porcelain, columns: 80 })).toBe(`▌ claude-sessions  settings  ·  46 settings  ·  ${changed} changed  ·  alpha`)
    expect(await first({ porcelain, columns: 58 })).toBe(`▌ claude-sessions  settings  ·  46 settings  ·  ${changed} changed`)
    expect(await first({ porcelain, columns: 40 })).toBe('▌ claude-sessions  settings')
    expect(await first({ porcelain, columns: 24 })).toBe('▌ claude-sessions')
  }
  expect(await first({ columns: 80, hasSelf: false })).toBe('▌ claude-sessions  settings  ·  46 settings  ·  5 changed')
  expect(await first({ columns: 80, session: 'a-very-long-session-name-for-this-test' })).toBe('▌ claude-sessions  settings  ·  46 settings  ·  5 changed')
  expect(await first({ columns: 16 })).toBe('▌ claude-session')
  const parts = async (over: Partial<PanelView> & { porcelain?: string }) => ((((await draw(viewOf(over))).tree as Node).children?.[0] as Node).children ?? [])
    .map(child => [textOf(child), (child as Node).props.color, (child as Node).props.weight]).filter(([text]) => String(text).length > 1)
  expect(await parts({ porcelain: THREE, columns: 80 })).toEqual([['▌ ', DARK.rail[0], undefined], ['  settings', DARK.ink, 'bold'], ['  ·  46 settings', DARK.ink, undefined],
    ['  ·  3 changed', DARK.teal, undefined], ['  ·  alpha', DARK.mut, undefined]])
  expect((await parts({ porcelain: NONE, columns: 80 }))[3]).toEqual(['  ·  0 changed', DARK.mut, undefined])
  expect((await parts({ porcelain: LIGHT, columns: 80 })).map(([, color]) => color)).toEqual([TUI.light.rail[0], TUI.light.ink, TUI.light.ink, TUI.light.teal, TUI.light.mut])
  const letters = async (porcelain: string) => {
    const masthead = ((await draw(viewOf({ porcelain }))).tree as Node).children?.[0]
    return nodesOf(masthead).filter(n => n.type === 'Text' && textOf(n).length === 1).slice(0, 15).map(n => [textOf(n), n.props.color])
  }
  expect(await letters(GOLDEN)).toEqual([...'claude-sessions'].map((letter, i) => [letter, WORDMARK_DARK[i]]))
  const light = await letters(LIGHT)
  expect([light[0], light[14]]).toEqual([['c', 'rgb(166,86,60)'], ['s', 'rgb(156,118,56)']])
})

test('under it, a rule of ━ the body wide along the TUI\'s four-stop hero gradient, its first stop on the first cell and its last on the last', async ($, on) => {
  const draw = drawer($, on)
  const cells = async (over: Partial<PanelView> & { porcelain?: string }) => {
    const rule = ((await draw(viewOf(over))).tree as Node).children?.[1] as Node
    return { text: textOf(rule), colours: (rule.children ?? []).flatMap(child => [...textOf(child)].map(() => (child as Node).props.color)) }
  }
  for (const columns of [24, 40, 58, 60, 80]) {
    const { text, colours } = await cells({ columns })
    expect([text, colours.length, colours[0], colours.at(-1)], `the rule at ${columns}`).toEqual([hero(columns), columns, DARK.hero[0], DARK.hero[3]])
  }
  // At 58 cells the four stops fall on cells 0, 19, 38 and 57; at 7, cell 3
  // is halfway from the second stop to the third, each channel truncated as
  // the TUI's ramp does (241.5 draws 241).
  const at58 = (await cells({ columns: 58 })).colours
  expect([0, 19, 38, 57].map(i => at58[i])).toEqual(DARK.hero)
  expect((await cells({ columns: 7 })).colours[3]).toBe('rgb(241,141,0)')
  const light = await cells({ porcelain: LIGHT, columns: 80 })
  expect([light.colours[0], light.colours[79], (await cells({ porcelain: LIGHT, columns: 7 })).colours[3]]).toEqual([TUI.light.hero[0], TUI.light.hero[3], 'rgb(229,128,44)'])
})

test('the rows sit under a column header in muted bold, setting, value, from and when over their columns, then a soft rule the body wide; from 80 columns a name has 26 cells and when the rest', async ($, on) => {
  const draw = drawer($, on)
  const head = async (over: Partial<PanelView> & { porcelain?: string }) => {
    const parts = ((await draw(viewOf(over))).tree as Node).children as Node[]
    const at = parts.findIndex(part => textOf(part).startsWith('  setting'))
    if (at < 0) throw new Error(`no column header in the drawing: ${parts.map(textOf).slice(0, 6).join(' | ')}`)
    return [parts[at], parts[at + 1]].map(part => [textOf(part), part?.props.color, part?.props.weight])
  }
  expect(await head({ columns: 58 })).toEqual([['  setting              value           from     when      ', DARK.mut, 'bold'], [soft(58), DARK.soft, undefined]])
  expect((await head({ columns: 80 }))[0]?.[0]).toBe(`  ${'setting'.padEnd(26)}  ${'value'.padEnd(14)}  ${'from'.padEnd(7)}  ${'when'.padEnd(25)}`)
  expect((await head({ columns: 40 }))[0]?.[0]).toBe(`  ${'setting'.padEnd(13)}  ${'value'.padEnd(14)}  ${'from'.padEnd(7)}`)
  expect((await head({ columns: 24 }))[0]?.[0]).toBe('  setting    value      ')
  expect((await head({ porcelain: LIGHT })).map(([, color]) => color)).toEqual([TUI.light.mut, TUI.light.soft])
  const row = textOf(rowOf((await draw(viewOf({ columns: 80, porcelain: CLEARED }))).tree, 'cs:CS_NO_ROTATION_WAKE'))
  expect(row).toBe(`  ${'No wake after /clear'.padEnd(26)}  ${'● on'.padEnd(14)}  session  ${'/clear'.padEnd(25)}`)
})

test('a group is its name in muted bold on a line of its own, two cells in, with no rule; an empty line sits above every group but the first', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  const named = (drawn: unknown, name: string) => nodesOf(drawn).filter(n => n.type === 'Text' && textOf(n) === `  ${name}`).map(n => [n.props.color, n.props.weight])
  expect(named(tree, 'Status line')).toEqual([[DARK.mut, 'bold']])
  expect(named((await draw(viewOf({ porcelain: LIGHT }))).tree, 'Mods')).toEqual([[TUI.light.mut, 'bold']])
  const groups = ['Mods', 'Status line', 'Prompts', 'Turn end', 'Rotation', 'Rewriter (ctrl+g)', 'Terminal', 'Launch']
  expect(groups.map(name => lines[lines.indexOf(`  ${name}`) - 1]?.trimEnd())).toEqual([soft(58), '', '', '', '', '', '', ''])
  expect(lines.filter(line => line.includes('─') && line !== soft(58))).toEqual([])
  expect((await draw(viewOf({ columns: 24 }))).lines).toContain('  Rewriter (ctrl+g)')
})

test('a toggle draws ● on, the dot in green, or ○ off muted; a word the shell pins a flag to draws as it is', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf())
  expect(runsOf(tree, 'cs:CS_SCOPE_DISABLE').slice(2, 5)).toEqual([{ text: '  ' }, { text: '●', color: DARK.green }, { text: ' on'.padEnd(13), color: DARK.ink }])
  expect(runsOf(tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '○ off'.padEnd(14), color: DARK.mut }])
  expect(runsOf(tree, 'mod:cs-update.showReleaseNotes').slice(3, 5)).toEqual([{ text: '●', color: DARK.green }, { text: ' on'.padEnd(13), color: DARK.ink }])
  expect(runsOf((await draw(viewOf({ porcelain: LIGHT }))).tree, 'cs:CS_SCOPE_DISABLE')[3]).toEqual({ text: '●', color: TUI.light.green })
  const row = 'CS_NERD_FONTS\tTerminal\tNerd Font glyphs\tflag\t-\toff\tnow\tapplies at the next cs command\t'
  const pinned = await draw(viewOf({ porcelain: GOLDEN.replace(`${row}-\tdefault\t-`, `${row}0\tshell\t-`) }))
  expect(runsOf(pinned.tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '0'.padEnd(14), color: DARK.ink }])
})

test('a percent row draws a ten-cell gauge before its number where the value column holds both, all faint at the default, else filled in amber and empty faint; else the number alone', async ($, on) => {
  const draw = drawer($, on)
  const at58 = await draw(viewOf())
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Context warning %    ▰▰▰▰▱▱▱▱▱▱ 40')
  expect(runsOf(at58.tree, 'cs:CS_CTX_WARN_CTX').slice(3, 6)).toEqual([{ text: '▰▰▰▰', color: DARK.faint }, { text: '▱▱▱▱▱▱', color: DARK.faint }, { text: ' 40 ', color: DARK.mut }])
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Context warn %       ▰▰▰▰▰▱▱▱▱▱ 50   session')
  expect(runsOf(at58.tree, 'cs:CS_STATUSLINE_CTX_WARN').slice(3, 6)).toEqual([{ text: '▰▰▰▰▰', color: DARK.amber }, { text: '▱▱▱▱▱', color: DARK.faint }, { text: ' 50 ', color: DARK.ink }])
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Rotate button from…  the warn %')
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Width in columns     measured')
  expect(runsOf((await draw(viewOf({ columns: 24 }))).tree, 'cs:CS_CTX_WARN_CTX').slice(1)).toEqual([{ text: 'Context …', color: DARK.ink }, { text: '  ' }, { text: '40'.padEnd(11), color: DARK.mut }])
  expect(runsOf((await draw(viewOf({ porcelain: LIGHT }))).tree, 'cs:CS_STATUSLINE_CTX_WARN')[3]).toEqual({ text: '▰▰▰▰▰', color: TUI.light.amber })
})

test('only what is set reads: a default row draws its value muted and leaves from and when empty; a set row draws its value in ink, from in its colour, and when, muted, unless it is now', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf())
  expect(runsOf(tree, 'cs:CS_STATUSLINE_DISABLE').slice(3)).toEqual([{ text: '○ off'.padEnd(14), color: DARK.mut }, { text: '  ' }, { text: ' '.repeat(7) }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_SEGMENTS').slice(3)).toEqual([{ text: 'logo,session,…', color: DARK.mut }, { text: '  ' }, { text: ' '.repeat(7) }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(3)).toEqual([{ text: 'band'.padEnd(14), color: DARK.ink }, { text: '  ' }, { text: 'machine', color: DARK.green }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_CTX_WARN')[7]).toEqual({ text: 'session', color: DARK.teal })
  expect(runsOf(tree, 'cs:CS_STATUSLINE_FRAME')[5]).toEqual({ text: 'shell  ', color: DARK.amber })
  expect(runsOf(tree, 'cs:CS_TERM_THEME')[5]).toEqual({ text: 'launch ', color: DARK.faint })
  expect(runsOf(tree, 'mod:cs.bandPrompt').slice(3)).toEqual([{ text: 'latest'.padEnd(14), color: DARK.ink }, { text: '  ' }, { text: 'mod    ', color: DARK.mut }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf((await draw(viewOf({ rows: LOCKED }))).tree, 'mod:cs-mermaid.drawDiagrams')[6]).toEqual({ text: 'locked ', color: DARK.mut })
  const light = (await draw(viewOf({ porcelain: LIGHT }))).tree
  expect([runsOf(light, 'cs:CS_STATUSLINE_FRAME')[5], runsOf(light, 'cs:CS_STATUSLINE_CTX_WARN')[7]]).toEqual([{ text: 'shell  ', color: TUI.light.amber }, { text: 'session', color: TUI.light.teal }])
  expect(CLEARED).not.toBe(GOLDEN)
  const cleared = await draw(viewOf({ porcelain: CLEARED }))
  expect(cleared.lines.map(line => line.trimEnd())).toContain('  No wake after /cle…  ● on            session  /clear')
  expect(runsOf(cleared.tree, 'cs:CS_NO_ROTATION_WAKE').slice(-1)).toEqual([{ text: '/clear'.padEnd(10), color: DARK.mut }])
})

test('the selected row is a row Box on the wash, the body wide, of the marker Text, the label Button and the columns Text: ▌ in the rail\'s second colour and the label bold in ink; every other row two spaces and its label in ink, on no wash', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))
  const row = rowOf(tree, 'cs:CS_STATUSLINE_LAYOUT')
  const [marker, button, columns] = (row.children ?? []) as Node[]
  expect([row.props.backgroundColor, textOf(row).length]).toEqual([DARK.wash, 58])
  expect((row.children ?? []).map(child => (child as Node).type)).toEqual(['Text', 'Button', 'Text'])
  expect([textOf(marker), marker?.props.color]).toEqual(['▌ ', DARK.rail[1]])
  expect([button?.props.plain, button?.props.label, button?.props.autoFocus, textOf(button)]).toEqual([true, 'Layout', true, 'Layout'.padEnd(19)])
  expect(textOf(columns)).toBe(`  ${'band'.padEnd(14)}  machine  ${' '.repeat(10)}`)
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(0, 2)).toEqual([{ text: '▌ ', color: DARK.rail[1] }, { text: 'Layout'.padEnd(19), color: DARK.ink, weight: 'bold' }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_DISABLE').slice(0, 2)).toEqual([{ text: '  ' }, { text: 'Hide the status li…', color: DARK.ink }])
  const other = rowOf(tree, 'cs:CS_STATUSLINE_DISABLE')
  expect([other.props.backgroundColor, other.children?.map(child => [(child as Node).type, (child as Node).props?.autoFocus])])
    .toEqual([undefined, [['Text', undefined], ['Button', undefined], ['Text', undefined]]])
  expect(rowsOf(tree).filter(line => line.startsWith('▌ '))).toEqual(['▌ Layout               band            machine            '])
  const light = rowOf((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', porcelain: LIGHT }))).tree, 'cs:CS_STATUSLINE_LAYOUT')
  expect([light.props.backgroundColor, (light.children?.[0] as Node).props.color]).toEqual([TUI.light.wash, TUI.light.rail[1]])
})

test('the strip is the plain hotkey Buttons and Esc: close three cells apart, the labels muted, and under it the detail faint; stacked, one Button a line', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))
  const [, , , strip, detail] = ((tree as Node).children ?? []) as Node[]
  const parts = (box: Node | undefined) => (box?.children ?? []).map(child => {
    const n = child as Node
    return n.type === 'Button' ? [n.type, n.props.hotkey, n.props.plain, ...(n.children ?? []).map(c => [textOf(c), (c as Node).props.color])] : [n.type, textOf(n), n.props.color]
  })
  expect(parts(strip)).toEqual([['Button', 'c', true, ['change', DARK.mut]], ['Button', 'u', true, ['default', DARK.mut]], ['Button', 'p', true, ['this session only', DARK.mut]],
    ['Text', 'Esc: close', DARK.mut]])
  expect(lines[3]).toBe('c: change   u: default   p: this session only   Esc: close')
  expect([detail?.type, textOf(detail), detail?.props.color]).toEqual(['Text', 'CS_STATUSLINE_LAYOUT · applies at the next repaint', DARK.faint])
  const stacked = ((await draw(viewOf({ columns: 24, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).tree as Node).children?.[3] as Node
  expect([stacked.props.flexDirection, parts(stacked)]).toEqual(['column', [['Button', 'c', true, ['change', DARK.mut]], ['Button', 'u', true, ['default', DARK.mut]],
    ['Button', 'p', true, ['session', DARK.mut]]]])
  const light = ((await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT', porcelain: LIGHT }))).tree as Node).children as Node[]
  expect([parts(light[3])[0], light[4]?.props.color]).toEqual([['Button', 'c', true, ['change', TUI.light.mut]], TUI.light.faint])
})

// ── The hooks, through the engine's own `$` ──────────────────────────────

const BIN = '/opt/cs/bin/cs'
const PANE_PROPS = { title: 'cs', isFocused: true, bodyColumns: 80, placement: 'inline', scroll: { offset: 0, bodyRows: 80 }, view: {} } as const
const COMMAND = { command: 'cs', args: '', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const LIST = [BIN, '-config', 'list', '--porcelain']

type Answer = { exitCode?: number; stdout?: string; stderr?: string }

// A promise the test settles: what a held answer waits on.
function gate(): { held: Promise<void>; open: () => void } {
  let open = () => {}
  const held = new Promise<void>(resolve => { open = resolve })
  return { held, open }
}

// What sits beneath the mod: cs's answer to each argv (the golden for the
// listing, nothing for a write unless `answer` says), the /config rows and
// their writer, the AskUserQuestion dialog (`reply` is the answer, undefined a
// dismissal), and a record of each call. A pane is open from its ui.open until
// a ui.close.
function world(on: On, opts: { env?: Record<string, string>; answer?: (argv: readonly string[]) => Answer | Promise<Answer>; rows?: ConfigRow[] } = {}) {
  const w = {
    runs: [] as string[][], toasts: [] as string[], logs: [] as string[], opens: [] as PaneOpenArgs[], sets: [] as { key: string; value: unknown }[],
    asked: [] as unknown[], reply: undefined as string | undefined, rows: opts.rows ?? MOD_ROWS, rowsDeny: undefined as string | undefined,
    setDeny: undefined as string | undefined, openDeny: undefined as string | undefined, lists: 0, isOpen: false,
  }
  mock.env(on, opts.env ?? { CS_BIN: BIN, CLAUDE_SESSION_NAME: 'alpha' })
  const clock = mock.clock(on)
  on('process.run', async ($, e) => {
    w.runs.push([...e.argv])
    const a: Answer = await (opts.answer ?? (argv => argv[2] === 'list' ? { stdout: GOLDEN } : {}))(e.argv)
    return { value: { exitCode: a.exitCode ?? 0, stdout: a.stdout ?? '', stderr: a.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('config.list', () => { w.lists++; return w.rowsDeny === undefined ? { value: w.rows } : { deny: w.rowsDeny } })
  on('config.set', ($, e) => { w.sets.push({ key: e.key, value: e.value }); return w.setDeny === undefined ? { value: e.value } : { deny: w.setDeny } })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    w.asked.push(e.questions)
    const question = e.questions[0]?.question ?? ''
    return (w.reply === undefined ? { deny: 'dismissed' } : { result: { questions: [], answers: { [question]: w.reply } } }) as never
  })
  on('ui.toast', ($, e) => { w.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { w.logs.push(e.text); return { value: undefined } })
  on('ui.open', ($, e) => {
    if (w.openDeny !== undefined) return { deny: w.openDeny }
    w.opens.push({ ...e }); w.isOpen = true; return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({ value: w.isOpen ? [{ id: 'cs-panel', title: 'cs', isShown: true, isFocused: true, isPlaced: true }] : [] }))
  on('ui.close', () => { w.isOpen = false; return { value: undefined } })
  on('ui.focus', () => ({}))
  on('turn.complete', () => ({ text: '' }))
  return { w, clock }
}

// cs's writes: every run but the listing.
function writes(w: { runs: string[][] }): string[][] {
  return w.runs.filter(argv => argv.join(' ') !== LIST.join(' '))
}

async function openPane($: Engine) {
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  return $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
}

// The ring landing on a row, as Tab or an arrow lands it.
function focus($: Engine, element: string) {
  return $.ui.focus({ component: 'Pane', requestId: 'cs-panel', plugin: 'cs-panel', element, origin: { kind: 'person' } })
}

const DONE = { answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as const

test('/cs and /cs-panel without CS_BIN say cs did not launch this conversation and open nothing', async ($, on) => {
  const { w } = world(on, { env: {} })
  expect(await $.command.run(COMMAND)).toEqual({ text: 'The launch did not say where cs is (CS_BIN); open this conversation with cs to change its settings.' })
  expect(await $.command.run({ ...COMMAND, command: 'cs-panel' })).toEqual({ text: REPLIES.noBin })
  expect([w.opens, w.runs, w.lists]).toEqual([[], [], 0])
})

test('bare /cs opens the pane and reads cs and /config at once; /cs with an argument is passed on to the hook beneath', async ($, on) => {
  const { w } = world(on)
  // The cs mod's rail, beneath this plugin.
  on('command.run', { command: 'cs' }, ($, e) => ({ text: `rail ${e.args}` }))
  expect(await $.command.run({ ...COMMAND, args: 'next' })).toEqual({ text: 'rail next' })
  expect([w.opens, w.runs, w.lists]).toEqual([[], [], 0])
  expect(await $.command.run(COMMAND)).toEqual({ text: 'cs settings are in the panel: Tab moves, c or Enter changes, u puts back the default, p changes it for this session only, Esc closes.' })
  expect(w.opens).toEqual([{ id: 'cs-panel', title: 'cs', focus: true, closeOnEscape: true, columns: 60 }])
  expect([w.runs, w.lists]).toEqual([[LIST], 1])
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
  expect([w.runs, w.lists]).toEqual([[LIST], 1])
  const drawn = bodyLines(await pane.drawn())
  expect([drawn[0], drawn[3]]).toEqual(['▌ claude-sessions  settings  ·  46 settings  ·  5 changed  ·  alpha', 'c: change   Esc: close'])
  await $.turn.complete(DONE)
  await clock.settle()
  expect(w.lists).toBe(2)
})

test('the pane\'s drawing is what drawPane draws for the same view', async ($, on) => {
  world(on)
  let fixture: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => drawPane(fixture ?? viewOf(), $.ui.resolve(e), NOOP))
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  const props = { ...PANE_PROPS, bodyColumns: 40, isFocused: false, scroll: { offset: 0, bodyRows: 12 } }
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props })
  fixture = { ...viewOf(), columns: 40, bodyRows: 12, hasKeys: false }
  const lab = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props })
  expect(bodyLines(await pane.drawn())).toEqual(bodyLines(await lab.drawn()))
  expect(JSON.stringify(await pane.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
    .toBe(JSON.stringify(await lab.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
  expect(bodyLines(await pane.drawn()).slice(0, 4).map(line => line.trimEnd())).toEqual(['▌ claude-sessions  settings', hero(40), '', 'c: change   ctrl+x tab: keys'])
})

test('the ring landing on a row selects it, and the strip and detail name that row; a ring on a strip key keeps the selection', async ($, on) => {
  world(on)
  const pane = await openPane($)
  const head = async () => bodyLines(await pane.drawn()).slice(3, 5)
  expect(await head()).toEqual(['c: change   Esc: close', 'cs.bandPrompts · changing it reloads cs (an armed rotation countdown starts'])
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  expect(await head()).toEqual(['c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT · applies at the next repaint'])
  await focus($, 'act:unset')
  expect((await head())[1]).toBe('CS_STATUSLINE_LAYOUT · applies at the next repaint')
  await focus($, 'cs:CS_NOT_A_ROW')
  expect((await head())[1]).toBe('CS_STATUSLINE_LAYOUT · applies at the next repaint')
})

test('each edit writes cs\'s exact argv: a flag toggles, a choice is picked, a value typed, Default unsets, p writes the session, u unsets where the value lives', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const press = async (row: string, key: string, reply?: string) => { await focus($, row); w.reply = reply; await pane.press({ key }) }
  await press('cs:CS_STATUSLINE_DISABLE', 'act:change')
  await press('cs:CS_SCOPE_DISABLE', 'act:change')
  await press('cs:CS_STATUSLINE_LAYOUT', 'act:change', 'capsules')
  await press('cs:CS_STATUSLINE_LAYOUT', 'act:change', 'Default (quiet)')
  await press('cs:CS_STATUSLINE_CTX_WARN', 'act:change', '45')
  await press('cs:CS_STATUSLINE_CTX_WARN', 'act:unset')
  await press('cs:CS_STATUSLINE_LAYOUT', 'act:unset')
  await press('cs:CS_STATUSLINE_DISABLE', 'act:session')
  await press('cs:CS_TERM_THEME', 'act:session', 'light')
  w.reply = 'xai'
  await pane.press({ key: 'cs:CS_REWRITE_PROVIDER' })
  await press('cs:CS_REWRITE_PROGRESS', 'act:change', 'line')
  expect(writes(w)).toEqual([
    [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1'],
    [BIN, 'alpha', '-config', 'set', 'CS_SCOPE_DISABLE', '0'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'],
    [BIN, '-config', 'unset', 'CS_STATUSLINE_LAYOUT'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_CTX_WARN', '45'],
    [BIN, 'alpha', '-config', 'unset', 'CS_STATUSLINE_CTX_WARN'],
    [BIN, '-config', 'unset', 'CS_STATUSLINE_LAYOUT'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_DISABLE', '1'],
    [BIN, 'alpha', '-config', 'set', 'CS_TERM_THEME', 'light'],
    [BIN, '-config', 'set', 'CS_REWRITE_PROVIDER', 'xai'],
    [BIN, '-config', 'set', 'CS_REWRITE_PROGRESS', 'line'],
  ])
  const option = (label: string) => ({ label, description: '' })
  expect(w.asked).toEqual([
    [{ question: 'What should Layout (CS_STATUSLINE_LAYOUT) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false,
      options: ['quiet', 'band', 'capsules', 'Default (quiet)'].map(option) }],
    [{ question: 'What should Layout (CS_STATUSLINE_LAYOUT) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false,
      options: ['quiet', 'band', 'capsules', 'Default (quiet)'].map(option) }],
    [{ question: 'What should Context warn % (CS_STATUSLINE_CTX_WARN) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false,
      options: ['Keep 50', 'Default (40)'].map(option) }],
    [{ question: 'What should Theme (CS_TERM_THEME) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false,
      options: ['light', 'dark', 'Default (detected)'].map(option) }],
    [{ question: 'What should Provider (CS_REWRITE_PROVIDER) be? It takes claude, claude-api, openai, openai-api, gemini, gemini-api, grok, xai. Pick one, or type a value under Other.',
      header: 'cs', multiSelect: false, options: ['claude', 'claude-api', 'openai', 'Default (claude)'].map(option) }],
    [{ question: 'What should Progress (CS_REWRITE_PROGRESS) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false,
      options: ['screen', 'native', 'line', 'static'].map(option) }],
  ])
  expect(w.runs.filter(argv => argv.join(' ') === LIST.join(' ')).length).toBe(1 + 11)
})

test('a dismissed dialog or Keep writes nothing and says nothing', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  await focus($, 'cs:CS_STATUSLINE_CTX_WARN')
  w.reply = undefined
  await pane.press({ key: 'act:change' })
  w.reply = 'Keep 50'
  await pane.press({ key: 'act:change' })
  await focus($, 'mod:cs.bandBars')
  w.reply = undefined
  await pane.press({ key: 'act:change' })
  w.reply = 'Keep 10'
  await pane.press({ key: 'act:change' })
  w.reply = 'Cancel'
  await pane.press({ key: 'act:change' })
  expect([writes(w), w.sets, w.toasts]).toEqual([[], [], []])
  expect(w.asked.length).toBe(5)
})

test('cs\'s reply is the toast: its line when the write lands, and when cs refuses, its own refusal', async ($, on) => {
  let write: Answer = { stdout: 'CS_STATUSLINE_LAYOUT=capsules in ~/.config/cs/config: applies at the next repaint\n' }
  const { w } = world(on, { answer: argv => argv[2] === 'list' ? { stdout: GOLDEN } : write })
  const pane = await openPane($)
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  w.reply = 'capsules'
  await pane.press({ key: 'act:change' })
  write = { exitCode: 1, stderr: 'Error: CS_STATUSLINE_LAYOUT is quiet, band or capsules; got bands\n' }
  w.reply = 'bands'
  await pane.press({ key: 'act:change' })
  expect(w.toasts).toEqual([
    'CS_STATUSLINE_LAYOUT=capsules in ~/.config/cs/config: applies at the next repaint',
    'CS_STATUSLINE_LAYOUT not changed: exited 1: Error: CS_STATUSLINE_LAYOUT is quiet, band or capsules; got bands',
  ])
})

test('a /config row changes through $.config.set: a boolean toggles to its negation, a choice and a number ask, abc is refused unwritten, a deny is toasted, a locked row offers nothing', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  await pane.press({ key: 'act:change' })
  await focus($, 'mod:cs.bandPrompt')
  w.reply = 'read'
  await pane.press({ key: 'act:change' })
  await focus($, 'mod:cs.bandBars')
  w.reply = 'abc'
  await pane.press({ key: 'act:change' })
  w.reply = '12'
  await pane.press({ key: 'act:change' })
  w.setDeny = 'Band: most bars takes a whole number of 1 or more'
  w.reply = '0'
  await pane.press({ key: 'act:change' })
  expect(w.sets).toEqual([{ key: 'cs.bandPrompts', value: true }, { key: 'cs.bandPrompt', value: 'read' }, { key: 'cs.bandBars', value: 12 }, { key: 'cs.bandBars', value: 0 }])
  expect(w.toasts).toEqual([
    'cs.bandPrompts=true in /config: cs reloads with it',
    'cs.bandPrompt=read in /config: cs reloads with it',
    'Band: most bars takes a number; got abc',
    'cs.bandBars=12 in /config: cs reloads with it',
    'cs.bandBars not changed: Band: most bars takes a whole number of 1 or more',
  ])
  const option = (label: string) => ({ label, description: '' })
  expect(w.asked.slice(0, 2)).toEqual([
    [{ question: 'What should Band: named prompt (cs.bandPrompt) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false, options: ['latest', 'read'].map(option) }],
    [{ question: 'What should Band: most bars (cs.bandBars) be? Pick one, or type a value under Other.', header: 'cs', multiSelect: false, options: ['Keep 10', 'Cancel'].map(option) }],
  ])
  expect(writes(w)).toEqual([])
})

test('a locked /config row draws no key and a press on it changes nothing', async ($, on) => {
  const { w } = world(on, { rows: LOCKED })
  const pane = await openPane($)
  await focus($, 'mod:cs-mermaid.drawDiagrams')
  expect(headOf(bodyLines(await pane.drawn()))).toEqual(['Esc: close', 'cs-mermaid.drawDiagrams · a managed setting owns it'])
  await pane.press({ key: 'mod:cs-mermaid.drawDiagrams' })
  expect([w.sets, w.toasts, w.asked]).toEqual([[], [], []])
})

test('a key pressed on a row that no longer offers it says so and writes nothing: a second c while the first write runs', async ($, on) => {
  const written = gate()
  const { w, clock } = world(on, { answer: async argv => {
    if (argv[2] === 'list') return { stdout: GOLDEN }
    await written.held
    return { stdout: 'CS_STATUSLINE_DISABLE=1 in ~/.config/cs/config: applies at the next repaint\n' }
  } })
  const pane = await openPane($)
  await focus($, 'cs:CS_STATUSLINE_DISABLE')
  // Both presses land on the drawing that names the row, as two quick c's do.
  expect(bodyLines(await pane.drawn())[4]).toBe('CS_STATUSLINE_DISABLE · applies at the next repaint')
  const first = pane.press({ key: 'act:change' })
  const second = pane.press({ key: 'act:change' })
  await clock.settle()
  expect(w.toasts).toEqual(['change is not offered for CS_STATUSLINE_DISABLE now'])
  written.open()
  await Promise.all([first, second])
  await clock.settle()
  expect(writes(w)).toEqual([[BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1']])
  expect(w.toasts).toEqual(['change is not offered for CS_STATUSLINE_DISABLE now', 'CS_STATUSLINE_DISABLE=1 in ~/.config/cs/config: applies at the next repaint'])
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

const CLOSER = { name: 'closer', register(on: On) {
  on('command.run', { command: 'close-panel' }, async $ => { await $.ui.close({ id: 'cs-panel' }); return { text: '' } })
} }

test('a failed or unreadable porcelain and unreadable /config rows keep the rows and draw why above them; the next good answer clears it; only an open pane reads at a main-loop turn\'s end', { plugins: [CLOSER] }, async ($, on) => {
  let list: Answer = { stdout: GOLDEN }
  const { w, clock } = world(on, { answer: () => list })
  const pane = await openPane($)
  const read = async (next: Answer) => {
    list = next
    await $.turn.complete(DONE)
    await clock.settle()
    const tree = await pane.drawn()
    return { head: headOf(bodyLines(tree)), rows: rowsOf(tree).length }
  }
  const strip = ['c: change   Esc: close', 'cs.bandPrompts · changing it reloads cs (an armed rotation countdown starts', 'over)']
  expect(await read({ exitCode: 1, stderr: 'warming up\nError: boom\n' })).toEqual({ head: [...strip, 'cs -config list exited 1: Error: boom'], rows: 46 })
  expect(await read({ stdout: 'oops\n' })).toEqual({ head: [...strip, 'cs -config list gave a line the panel cannot read: oops'], rows: 46 })
  expect(await read({ stdout: '' })).toEqual({ head: [...strip, 'cs -config list printed no settings'], rows: 46 })
  w.rowsDeny = 'the menu is busy'
  expect(await read({ stdout: GOLDEN })).toEqual({ head: [...strip, 'the /config rows could not be read: cs-panel: $.config.list: the menu is busy'], rows: 46 })
  w.rowsDeny = undefined
  expect(await read({ stdout: GOLDEN })).toEqual({ head: strip, rows: 46 })
  const runs = w.runs.length
  await $.turn.complete({ ...DONE, agentId: 'a1' })
  await clock.settle()
  expect(w.runs.length).toBe(runs)
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  await $.turn.complete(DONE)
  await clock.settle()
  expect(w.runs.length).toBe(runs)
})

test('the first porcelain failing draws the mod rows and why, with no settings rows', async ($, on) => {
  world(on, { answer: () => ({ exitCode: 127, stderr: 'cs: command not found\n' }) })
  const pane = await openPane($)
  const tree = await pane.drawn()
  const lines = bodyLines(tree).map(line => line.trimEnd())
  expect(headOf(lines).slice(-1)).toEqual(['cs -config list exited 127: cs: command not found'])
  expect([lines[lines.indexOf(soft(80)) + 1], rowsOf(tree).length]).toEqual(['  Mods', 5])
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

test('the pane draws on every surface, its rows and keys as Buttons', async ($, on) => {
  world(on)
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const pane = await $.ui.mount({ plugin: 'cs-panel', surface, component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
    expect((await pane.find({ key: 'cs:CS_STATUSLINE_LAYOUT' }))?.props.label, surface).toBe('Layout')
    expect((await pane.find({ key: 'act:change' }))?.props.hotkey, surface).toBe('c')
    await pane.unmount()
  }
})

test('no line the mod hands the engine names the plugin first: the engine prefixes it', () => {
  const call = (f: unknown) => typeof f === 'string' ? f : (f as (...args: string[]) => string)('x', 'y', 'z')
  const lines = [
    COMMANDS['cs-panel'].description, ...Object.values(REPLIES).map(call), ASKS.setting('x', 'y', []), ASKS.setting('x', 'y', ['a', 'b']), ASKS.mod('x', 'y', []),
    ...Object.values(TOASTS).map(call), ...Object.values(PROBLEMS).map(call), ...Object.values(LOGS).map(call),
  ]
  expect(lines.length).toBe(18)
  expect(lines.filter(line => line.toLowerCase().startsWith('cs-panel'))).toEqual([])
})
