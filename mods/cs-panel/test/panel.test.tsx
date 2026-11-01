// ABOUTME: Engine test-kit tests for the cs-panel mod: cs's porcelain and the /config rows as settings rows, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from design.md's rules, config-verb.md's reply shapes and the golden porcelain (test/golden.ts), never from the code under test.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { ConfigRow, On, PaneOpenArgs } from 'claude-code'

import { GOLDEN } from './golden'
import { drawPane, ringBack, ringOf, type PanelView } from '../hooks/draw'
import { ASKS, COMMANDS, LOGS, PROBLEMS, REPLIES, TOASTS } from '../hooks/register'
import { filterLines, linesOf, modRowsOf, parseSettings, type RowId, type Setting } from '../hooks/settings'

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
test('a flag the shell pins to a word other than 1 parses and draws that word, and its card says the environment wins', async ($, on) => {
  const row = 'CS_NERD_FONTS\tTerminal\tNerd Font glyphs\tflag\t-\toff\tnow\tapplies at the next cs command\t'
  const pinned = GOLDEN.replace(`${row}-\tdefault\t-`, `${row}0\tshell\t-`)
  expect(pinned).not.toBe(GOLDEN)
  const settings = settingsOf(pinned)
  expect(settings.length).toBe(41)
  expect(settings.find(s => s.key === 'CS_NERD_FONTS')).toMatchObject({ value: '0', source: 'shell' })
  const { lines } = await drawer($, on)(viewOf({ selected: 'cs:CS_NERD_FONTS', lines: linesOf(modRowsOf(MOD_ROWS), settings, new Map(), 'Mods') }))
  expect(headOf(lines)).toEqual(['▍ Nerd Font glyphs  CS_NERD_FONTS', '▍ 0 · shell · CS_NERD_FONTS=0 in your environment wins;', '▍ unset it there to change it here'])
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

const NOOP = { change: () => {}, filter: () => {}, toRows: () => {} }

// The text one line of the drawing shows on the terminal, from the plain-data
// tree: a Button draws its children, or its label when it has none, after
// `<hotkey>: ` when it is plain with a hotkey (the 2.1.316 terminal's Button),
// an Input its label, then its text or else its placeholder, and a row Box
// puts its columnGap between its children and its paddingX either side of them.
type Node = { type: string; props: Record<string, unknown>; children?: unknown[] }
function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  const n = node as Node
  const children = n.children ?? []
  if (n.type === 'Input') return `${String(n.props.label ?? '')}${String(n.props.value || n.props.placeholder || '')}`
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

// The body's lines top to bottom, one per child of its column Box.
function bodyLines(tree: unknown): string[] {
  return ((tree as Node).children ?? []).map(textOf)
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
  return { lines: linesOf(modRowsOf(rows), settingsOf(porcelain), new Map(), 'Mods'), selected: undefined, problems: [], columns: 58, bodyRows: 80, filter: '', hasField: true,
    session: hasSelf ? 'alpha' : undefined, ...rest }
}

// The row Boxes of a drawing, each holding a Button keyed by its RowId, and
// the rows as the terminal shows them.
const rowBoxes = (tree: unknown) => nodesOf(tree).filter(n => n.type === 'Box' && (n.children ?? []).some(c => (c as Node).type === 'Button' && /^(cs|mod):/.test(String((c as Node).props.key))))
const rowsOf = (tree: unknown) => rowBoxes(tree).map(textOf)
// The empty filter field as the terminal shows it: its muted word, then the
// placeholder.
const FIELD = 'filter type to filter'
// The lines between the masthead's two lines and the field (on the mobile
// app, the empty line in its place): the card and the problem lines.
const headOf = (lines: string[]) => {
  const end = lines.findIndex((line, i) => i >= 2 && (line.startsWith('filter ') || line.trim() === ''))
  return end < 0 ? lines.slice(2) : lines.slice(2, end)
}
// The masthead's second line and the column header's rule, the body wide.
const hero = (columns: number) => '━'.repeat(columns)
const soft = (columns: number) => '─'.repeat(columns)
// A group's headline: its name, one space and a rule to the body's edge.
const group = (name: string, columns = 58) => `${name} ${'─'.repeat(columns - name.length - 1)}`

// Claude Code's theme keys the pane draws in, which the engine resolves to
// the person's theme, and tui/src/theme.rs's accents, drawn on every theme.
const COLOURS = { ink: 'text', mut: 'inactive', faint: 'subtle', soft: 'subtle', teal: 'planMode', green: 'success', amber: 'rgb(246,154,0)',
  hero: ['rgb(221,80,20)', 'rgb(237,128,0)', 'rgb(246,154,0)', 'rgb(214,162,30)'], rail: ['rgb(221,80,20)', 'rgb(246,154,0)', 'rgb(250,180,60)'] }

// The masthead's first line and the column header with its rule at the dock's
// 58 columns: 46 settings
// of which the golden's five files and shell set (the launch's Theme is no
// change); the session name does not fit beside them.
const MASTHEAD_AT_58 = '▌ claude-sessions  settings  ·  46 settings  ·  5 changed'
const HEAD_AT_58 = ['  setting              value           from     when', soft(58)]

// design.md's columns at the dock's 58-column body: the name in 19 cells, then
// value 14 (a gauge and its number), from 7 and when 10, each after a gap of
// 2, under each group's headline with an empty line above every group but the
// first; the golden's fields through them, worked out apart from the mod. A
// default row leaves from and when empty, and when is drawn only when it is
// not `now`, so only what a file, the shell or the launch sets reads there.
const GOLDEN_AT_58 = [
  group('Mods'),
  '▌ Band: prompt bars    ○ off           mod',
  '  Band: named prompt   latest          mod',
  '  Band: most bars      10              mod',
  '  Release notes pane   ● on            mod',
  '  Draw mermaid diagr…  ● on            mod',
  '',
  group('Status line'),
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
  group('Prompts'),
  '  No scope grounding   ● on            session',
  '  No scope trace       ○ off',
  '  Scope scan budget …  1500',
  '  No objective captu…  ○ off',
  '  No date reminder     ○ off',
  '  No clarifying ques…  ○ off',
  '',
  group('Turn end'),
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
  group('Rotation'),
  '  Rotate on its own …  ▰▰▰▰▰▰▰▰▱▱ 80',
  '  Rotate button from…  the warn %',
  '  No wake after /cle…  ○ off',
  '  Wake delay (s)       2',
  '',
  group('Rewriter (ctrl+g)'),
  '  Provider             claude',
  '  Model                per provider',
  '  Timeout (s)          25',
  '  Progress             screen',
  '  No rewrite           ○ off',
  '',
  group('Terminal'),
  '  Theme                dark            launch',
  '  Background r;g;b     detected',
  '  No iTerm2 features   ○ off',
  '  Nerd Font glyphs     ○ off',
  '',
  group('Launch'),
  '  No task tools        ○ off',
  '  No update check      ○ off',
  '  No mods              off',
]

test('the golden porcelain and the mod rows draw under the masthead, the first row\'s card, the filter field and the column header, Mods first, each row exactly the body wide', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  expect(lines.map(line => line.trimEnd())).toEqual([
    MASTHEAD_AT_58, hero(58),
    '▍ Band: prompt bars  cs.bandPrompts',
    '▍ ○ off · mod · changing it reloads cs (an armed rotation',
    '▍ countdown starts over)',
    FIELD, ...HEAD_AT_58,
    ...GOLDEN_AT_58,
  ])
  const rows = rowsOf(tree)
  expect(rows.length).toBe(46)
  expect(rows.filter(line => line.length !== 58)).toEqual([])
  // A percent setting is known by its label's `%`, not by a list of keys: a
  // percent set in a file draws the gauge whichever key it is.
  const BUTTON_AT_50 = GOLDEN.replace('applies by your next prompt\t-\tdefault\t-\n', 'applies by your next prompt\t50\tsession\t-\n')
  expect(settingsOf(BUTTON_AT_50).find(s => s.key === 'CS_ROTATE_BUTTON_CTX')?.value).toBe('50')
  expect(rowsOf((await draw(viewOf({ porcelain: BUTTON_AT_50 }))).tree).map(row => row.trimEnd())).toContain('  Rotate button from…  ▰▰▰▰▰▱▱▱▱▱ 50   session')
  // With no mod rows, the first group follows the column header's rule.
  expect((await draw(viewOf({ rows: [] }))).lines.slice(2, 8).map(line => line.trimEnd())).toEqual([
    '▍ Hide the status line  CS_STATUSLINE_DISABLE', '▍ ○ off · default · applies at the next repaint', FIELD, ...HEAD_AT_58, group('Status line')])
  // Under a two-line card the chrome is seven lines: the masthead, its rule,
  // the card, the field, the column header and its rule; the last row ends the pane.
  const layout = (await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.map(line => line.trimEnd())
  expect([...layout.slice(0, 8), ...layout.slice(-1)]).toEqual([MASTHEAD_AT_58, hero(58), '▍ Layout  CS_STATUSLINE_LAYOUT', '▍ band · machine · applies at the next repaint',
    FIELD, ...HEAD_AT_58, group('Mods'), '  No mods              off'])
  expect(layout.length).toBe(7 + 61)
  expect((await draw({ ...viewOf(), lines: undefined })).lines.map(line => line.trimEnd()))
    .toEqual(['▌ claude-sessions  settings  ·  alpha', hero(58), 'asking cs for its settings…'])
  expect((await draw({ ...viewOf(), lines: undefined, problems: ['cs -config list exited 1: Error: boom'] })).lines.map(line => line.trimEnd()))
    .toEqual(['▌ claude-sessions  settings  ·  alpha', hero(58), 'cs -config list exited 1: Error: boom'])
})

test('the card says why no dialog changes a row: the shell pins it, it changes from a shell, a managed setting owns it, or this session\'s file holds it under no session name; and why cs skipped a file\'s value', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[] } = {}) => headOf((await draw(viewOf({ selected, ...over }))).lines)
  expect(await card('cs:CS_STATUSLINE_BAND')).toEqual(['▍ Band colour  CS_STATUSLINE_BAND', '▍ session · default · machine line 4:',
    '▍ CS_STATUSLINE_BAND=magenta: not a palette name, brand,', '▍ periwinkle, session, none or r;g;b'])
  expect(await card('cs:CS_STATUSLINE_FRAME')).toEqual(['▍ Frame columns  CS_STATUSLINE_FRAME', '▍ 6 · shell · CS_STATUSLINE_FRAME=6 in your environment',
    '▍ wins; unset it there to change it here'])
  expect(await card('cs:CS_NO_FUNCTION_HOOKS')).toEqual(['▍ No mods  CS_NO_FUNCTION_HOOKS', '▍ off · default · change it from a shell: cs -config set',
    '▍ CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the', '▍ next launch, this panel too)'])
  expect(await card('cs:CS_NO_FUNCTION_HOOKS', { columns: 150 })).toEqual(['▍ No mods  CS_NO_FUNCTION_HOOKS',
    '▍ off · default · change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the next launch, this panel too)'])
  expect(await card('mod:cs-mermaid.drawDiagrams', { rows: LOCKED })).toEqual(['▍ Draw mermaid diagrams  cs-mermaid.drawDiagrams', '▍ ● on · locked · a managed setting owns it'])
  expect((await draw(viewOf({ rows: LOCKED }))).lines.map(line => line.trimEnd())).toContain('  Draw mermaid diagr…  ● on            locked')
  expect(await card('cs:CS_STATUSLINE_CTX_WARN', { hasSelf: false })).toEqual(['▍ Context warn %  CS_STATUSLINE_CTX_WARN',
    "▍ ▰▰▰▰▰▱▱▱▱▱ 50 · session · this session's file sets it,", '▍ and this conversation has no cs session name to write it', '▍ with'])
  expect(await card('cs:CS_STATUSLINE_CTX_WARN')).toEqual(['▍ Context warn %  CS_STATUSLINE_CTX_WARN', '▍ ▰▰▰▰▰▱▱▱▱▱ 50 · session · applies at the next repaint'])
})

// The golden with Segments set in this machine's file to its whole default.
const SEGMENTS = GOLDEN.replace('logo,session,notes,mail,git,model,ctx,limits\tnow\tapplies at the next repaint\t-\tdefault\t',
  'logo,session,notes,mail,git,model,ctx,limits\tnow\tapplies at the next repaint\tlogo,session,notes,mail,git,model,ctx,limits\tmachine\t')

test('the card names the selected row and its key, then its whole value, where it comes from and when a change applies, wrapped by words to the body', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: Partial<PanelView> & { porcelain?: string } = {}) => headOf((await draw(viewOf({ selected, ...over }))).lines)
  expect(await card('cs:CS_SCOPE_DISABLE')).toEqual(['▍ No scope grounding  CS_SCOPE_DISABLE', '▍ ● on · session · applies at your next prompt'])
  expect(await card('cs:CS_STATUSLINE_CTX_WARN')).toEqual(['▍ Context warn %  CS_STATUSLINE_CTX_WARN', '▍ ▰▰▰▰▰▱▱▱▱▱ 50 · session · applies at the next repaint'])
  expect(await card('cs:CS_CTX_WARN_CTX', { columns: 24 })).toEqual(['▍ Context warning %  CS…', '▍ ▰▰▰▰▱▱▱▱▱▱ 40 ·', '▍ default · applies when', '▍ the next turn ends'])
  expect(await card('cs:CS_TERM_THEME')).toEqual(['▍ Theme  CS_TERM_THEME', '▍ dark · launch · applies at the next repaint'])
  expect(await card('mod:cs.bandPrompt')).toEqual(['▍ Band: named prompt  cs.bandPrompt', '▍ latest · mod · changing it reloads cs (an armed rotation', '▍ countdown starts over)'])
  expect(await card('mod:cs-update.showReleaseNotes')).toEqual(['▍ Release notes pane  cs-update.showReleaseNotes', '▍ ● on · mod · changing it reloads cs-update'])
  expect(SEGMENTS).not.toBe(GOLDEN)
  const segments = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_SEGMENTS', porcelain: SEGMENTS, columns: 40 }))
  expect(headOf(segments.lines)).toEqual(['▍ Segments  CS_STATUSLINE_SEGMENTS', '▍ logo,session,notes,mail,git,model,ctx,', '▍ limits · machine · applies at the next', '▍ repaint'])
  expect(segments.lines.map(line => line.trimEnd())).toContain('▌ Segments       logo,session,…  machine')
})

test('every row, headline, line of the masthead, the card and the field fits 24, 40, 58, 60 and 80 columns, and 46 rows in 12 lines keep the selected row drawn', async ($, on) => {
  const draw = drawer($, on)
  const ids: RowId[] = [...modRowsOf(MOD_ROWS).map(m => `mod:${m.key}` as const), ...settingsOf(GOLDEN).map(s => `cs:${s.key}` as const)]
  expect(ids.length).toBe(46)
  for (const columns of [24, 40, 58, 60, 80]) {
    for (const selected of ids) {
      const { lines, label, tree } = await draw(viewOf({ columns, bodyRows: 12, selected }), selected)
      const rows = rowsOf(tree)
      expect(rows.filter(row => row.length !== columns), `rows at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => / ─+$/.test(line) && !line.startsWith('─') && line.length !== columns), `headlines at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => line.length > columns), `lines past ${columns} with ${selected}`).toEqual([])
      expect([lines[1], lines.find(line => line.startsWith('─'))], `the rules at ${columns}`).toEqual([hero(columns), soft(columns)])
      expect(lines.length <= 12, `${lines.length} lines in 12 at ${columns} with ${selected}`).toBe(true)
      expect(rows.filter(row => row.startsWith('▌ ')).length, `the selected row at ${columns} with ${selected}`).toBe(1)
      expect(label, `${selected} drawn at ${columns}`).not.toBe(undefined)
    }
  }
  // At 24 by 12 the card wraps into four lines and the window keeps the
  // selected row between the counts; by 9 the card gives up its last words to
  // leave the window a line.
  const narrow = async (bodyRows: number) => (await draw(viewOf({ columns: 24, bodyRows, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.map(line => line.trimEnd())
  expect(await narrow(12)).toEqual(['▌ claude-sessions', hero(24), '▍ Layout  CS_STATUSLINE…', '▍ band · machine ·', '▍ applies at the next', '▍ repaint',
    FIELD, '  setting    value', soft(24), '+6 above', '▌ Layout     band', '+39 below'])
  expect(await narrow(9)).toEqual(['▌ claude-sessions', hero(24), '▍ Layout  CS_STATUSLINE…', '▍ band · machine ·', '▍ applies at the next…',
    FIELD, '  setting    value', soft(24), '▌ Layout     band'])
  // 61 lines (46 rows, 8 headlines, the 7 empty lines above all but the
  // first) in the 5 lines of 12 the masthead, a two-line card, the field and
  // the column header leave, 4 under a three-line card and 3 under four: the
  // window holds the selected row and the line either side where it can, or
  // the lines at the end it touches, and +N counts the rows it leaves out; no
  // rows above draws the lines above instead.
  const at = async (selected: RowId) => (await draw(viewOf({ columns: 58, bodyRows: 12, selected }))).lines.map(line => line.trimEnd())
  const top = [MASTHEAD_AT_58, hero(58)]
  expect(await at('cs:CS_STATUSLINE_LAYOUT')).toEqual([...top,
    '▍ Layout  CS_STATUSLINE_LAYOUT', '▍ band · machine · applies at the next repaint', FIELD, ...HEAD_AT_58,
    '+5 above',
    '  Hide the status li…  ○ off',
    '▌ Layout               band            machine',
    '  Segments             logo,session,…',
    '+38 below',
  ])
  expect(await at('cs:CS_STATUSLINE_DISABLE')).toEqual([...top,
    '▍ Hide the status line  CS_STATUSLINE_DISABLE', '▍ ○ off · default · applies at the next repaint', FIELD, ...HEAD_AT_58,
    '+5 above',
    group('Status line'),
    '▌ Hide the status li…  ○ off',
    '  Layout               band            machine',
    '+39 below',
  ])
  expect(await at('mod:cs.bandPrompts')).toEqual([...top,
    '▍ Band: prompt bars  cs.bandPrompts', '▍ ○ off · mod · changing it reloads cs (an armed rotation', '▍ countdown starts over)', FIELD, ...HEAD_AT_58,
    group('Mods'),
    '▌ Band: prompt bars    ○ off           mod',
    '  Band: named prompt   latest          mod',
    '+44 below',
  ])
  expect(await at('cs:CS_NO_UPDATE_CHECK')).toEqual([...top,
    '▍ No update check  CS_NO_UPDATE_CHECK', '▍ ○ off · default · applies at the next launch', FIELD, ...HEAD_AT_58,
    '+43 above',
    group('Launch'),
    '  No task tools        ○ off',
    '▌ No update check      ○ off',
    '  No mods              off',
  ])
  expect(await at('cs:CS_NO_FUNCTION_HOOKS')).toEqual([...top,
    '▍ No mods  CS_NO_FUNCTION_HOOKS', '▍ off · default · change it from a shell: cs -config set',
    '▍ CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the', '▍ next launch, this panel too)', FIELD, ...HEAD_AT_58,
    '+44 above',
    '  No update check      ○ off',
    '▌ No mods              off',
  ])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 12, selected: 'cs:CS_STATUSLINE_DISABLE' })).keys)
    .toEqual(['filter', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT'])
  expect(ringOf(viewOf({ columns: 58, bodyRows: 12, selected: 'mod:cs.bandPrompts', hasField: false })).keys).toEqual(['mod:cs.bandPrompts', 'mod:cs.bandPrompt'])
})

test('a drawing that moves the element the ring was put on sends the ring back to that key, else to the selected row; one that moves nothing sends it nowhere', () => {
  const short = (selected: RowId, filter = '') => ringOf(viewOf({ columns: 58, bodyRows: 12, selected, filter }))
  // The ring walks the field, then the window's rows.
  expect(short('cs:CS_STATUSLINE_LAYOUT')).toEqual({ keys: ['filter', 'cs:CS_STATUSLINE_DISABLE', 'cs:CS_STATUSLINE_LAYOUT', 'cs:CS_STATUSLINE_SEGMENTS'],
    selected: 'cs:CS_STATUSLINE_LAYOUT' })
  expect(ringOf(viewOf()).keys.length).toBe(47)
  // The field holds the first place in every drawing, so typing moves nothing.
  expect(ringBack({ key: 'filter', at: 0 }, short('cs:CS_STATUSLINE_LAYOUT', 'scope'))).toBe(undefined)
  // LAYOUT keeps the third place under DISABLE's window, which starts at the group's headline.
  expect(ringBack({ key: 'cs:CS_STATUSLINE_LAYOUT', at: 2 }, short('cs:CS_STATUSLINE_DISABLE'))).toBe(undefined)
  // SEGMENTS is not drawn under DISABLE: the ring goes to the selected row.
  expect(ringBack({ key: 'cs:CS_STATUSLINE_SEGMENTS', at: 3 }, short('cs:CS_STATUSLINE_DISABLE'))).toBe('cs:CS_STATUSLINE_DISABLE')
  // Filtered to `named`, Band: named prompt moves from the third place to the
  // second, and the ring goes back to it there.
  expect(short('mod:cs.bandPrompt', 'named').keys).toEqual(['filter', 'mod:cs.bandPrompt'])
  expect(ringBack({ key: 'mod:cs.bandPrompt', at: 2 }, short('mod:cs.bandPrompt', 'named'))).toBe('mod:cs.bandPrompt')
  // A filter that hides the row the ring was on sends it to the first row shown, now selected.
  expect(short('cs:CS_STATUSLINE_DISABLE', 'scope')).toEqual({ keys: ['filter', 'cs:CS_SCOPE_DISABLE', 'cs:CS_SCOPE_TRACE_DISABLE', 'cs:CS_SCOPE_BUDGET_MS'],
    selected: 'cs:CS_SCOPE_DISABLE' })
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
  expect(shown('').length).toBe(54)
  expect(shown('  ')).toEqual(shown(''))
})

test('filtered, the masthead keeps its counts, the window counts the rows shown, and no match says so under the column header', async ($, on) => {
  const draw = drawer($, on)
  const lines = async (filter: string) => (await draw(viewOf({ bodyRows: 12, filter }))).lines.map(line => line.trimEnd())
  expect(await lines('status')).toEqual([MASTHEAD_AT_58, hero(58),
    '▍ Hide the status line  CS_STATUSLINE_DISABLE', '▍ ○ off · default · applies at the next repaint', 'filter status', ...HEAD_AT_58,
    group('Status line'),
    '▌ Hide the status li…  ○ off',
    '  Layout               band            machine',
    '  Segments             logo,session,…',
    '+7 below',
  ])
  expect(await lines('zzz')).toEqual([MASTHEAD_AT_58, hero(58), 'filter zzz', ...HEAD_AT_58, 'no setting matches zzz'])
})

// ── The look ─────────────────────────────────────────────────────────────

// install.sh.in's show_banner: the wordmark's letters, rust #e64a19 to gold
// #ffc107, on every theme.
const WORDMARK = [[230, 74, 25], [232, 83, 24], [234, 91, 22], [235, 100, 21], [237, 108, 20], [239, 117, 19], [241, 125, 17], [243, 134, 16],
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
  const dot = ['  ·  ', COLOURS.mut, undefined]
  expect(await parts({ porcelain: THREE, columns: 80 })).toEqual([['▌ ', COLOURS.rail[0], undefined], ['  settings', COLOURS.ink, 'bold'], dot, ['46 settings', COLOURS.ink, undefined],
    dot, ['3 changed', COLOURS.teal, undefined], dot, ['alpha', COLOURS.mut, undefined]])
  expect((await parts({ porcelain: NONE, columns: 80 }))[5]).toEqual(['0 changed', COLOURS.mut, undefined])
  const masthead = ((await draw(viewOf())).tree as Node).children?.[0]
  const letters = nodesOf(masthead).filter(n => n.type === 'Text' && textOf(n).length === 1).slice(0, 15).map(n => [textOf(n), n.props.color])
  expect(letters).toEqual([...'claude-sessions'].map((letter, i) => [letter, WORDMARK[i]]))
})

test('under it, a rule of ━ the body wide along the TUI\'s four-stop hero gradient, its first stop on the first cell and its last on the last', async ($, on) => {
  const draw = drawer($, on)
  const cells = async (over: Partial<PanelView>) => {
    const rule = ((await draw(viewOf(over))).tree as Node).children?.[1] as Node
    return { text: textOf(rule), colours: (rule.children ?? []).flatMap(child => [...textOf(child)].map(() => (child as Node).props.color)) }
  }
  for (const columns of [24, 40, 58, 60, 80]) {
    const { text, colours } = await cells({ columns })
    expect([text, colours.length, colours[0], colours.at(-1)], `the rule at ${columns}`).toEqual([hero(columns), columns, COLOURS.hero[0], COLOURS.hero[3]])
  }
  // At 58 cells the four stops fall on cells 0, 19, 38 and 57; at 7, cell 3
  // is halfway from the second stop to the third, each channel truncated as
  // the TUI's ramp does (241.5 draws 241).
  const at58 = (await cells({ columns: 58 })).colours
  expect([0, 19, 38, 57].map(i => at58[i])).toEqual(COLOURS.hero)
  expect((await cells({ columns: 7 })).colours[3]).toBe('rgb(241,141,0)')
})

test('the rows sit under a column header in muted bold, setting, value, from and when over their columns, then a soft rule the body wide; from 80 columns a name has 26 cells and when the rest', async ($, on) => {
  const draw = drawer($, on)
  const head = async (over: Partial<PanelView>) => {
    const parts = ((await draw(viewOf(over))).tree as Node).children as Node[]
    const at = parts.findIndex(part => textOf(part).startsWith('  setting'))
    if (at < 0) throw new Error(`no column header in the drawing: ${parts.map(textOf).slice(0, 6).join(' | ')}`)
    return [parts[at], parts[at + 1]].map(part => [textOf(part), part?.props.color, part?.props.weight])
  }
  expect(await head({ columns: 58 })).toEqual([['  setting              value           from     when      ', COLOURS.mut, 'bold'], [soft(58), COLOURS.soft, undefined]])
  expect((await head({ columns: 80 }))[0]?.[0]).toBe(`  ${'setting'.padEnd(26)}  ${'value'.padEnd(14)}  ${'from'.padEnd(7)}  ${'when'.padEnd(25)}`)
  expect((await head({ columns: 40 }))[0]?.[0]).toBe(`  ${'setting'.padEnd(13)}  ${'value'.padEnd(14)}  ${'from'.padEnd(7)}`)
  expect((await head({ columns: 24 }))[0]?.[0]).toBe('  setting    value      ')
  const row = textOf(rowOf((await draw(viewOf({ columns: 80, porcelain: CLEARED }))).tree, 'cs:CS_NO_ROTATION_WAKE'))
  expect(row).toBe(`  ${'No wake after /clear'.padEnd(26)}  ${'● on'.padEnd(14)}  session  ${'/clear'.padEnd(25)}`)
})

test('a group\'s headline is its name in bold ink, then one space and a soft ─ rule to the body\'s edge; an empty line sits above every group but the first', async ($, on) => {
  const draw = drawer($, on)
  const { lines, tree } = await draw(viewOf())
  const headline = (drawn: unknown, name: string) => nodesOf(drawn).filter(n => n.type === 'Text' && textOf(n).startsWith(`${name} ─`))
    .map(n => (n.children ?? []).map(run => [textOf(run), (run as Node).props.color, (run as Node).props.weight]))
  expect(headline(tree, 'Prompts')).toEqual([[['Prompts', COLOURS.ink, 'bold'], [` ${'─'.repeat(50)}`, COLOURS.soft, undefined]]])
  const groups = ['Mods', 'Status line', 'Prompts', 'Turn end', 'Rotation', 'Rewriter (ctrl+g)', 'Terminal', 'Launch']
  expect(groups.map(name => lines[lines.indexOf(group(name)) - 1]?.trimEnd())).toEqual([soft(58), '', '', '', '', '', '', ''])
  // At 24 columns: 7 cells of name and 16 of rule; 17 and 6.
  const at24 = (await draw(viewOf({ columns: 24 }))).lines
  expect([at24.includes(`Prompts ${'─'.repeat(16)}`), at24.includes(`Rewriter (ctrl+g) ${'─'.repeat(6)}`)]).toEqual([true, true])
})

test('a toggle draws ● on, the dot in green, or ○ off muted; a word the shell pins a flag to draws as it is', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf())
  expect(runsOf(tree, 'cs:CS_SCOPE_DISABLE').slice(2, 5)).toEqual([{ text: '  ' }, { text: '●', color: COLOURS.green }, { text: ' on'.padEnd(13), color: COLOURS.ink }])
  expect(runsOf(tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '○ off'.padEnd(14), color: COLOURS.mut }])
  expect(runsOf(tree, 'mod:cs-update.showReleaseNotes').slice(3, 5)).toEqual([{ text: '●', color: COLOURS.green }, { text: ' on'.padEnd(13), color: COLOURS.ink }])
  const row = 'CS_NERD_FONTS\tTerminal\tNerd Font glyphs\tflag\t-\toff\tnow\tapplies at the next cs command\t'
  const pinned = await draw(viewOf({ porcelain: GOLDEN.replace(`${row}-\tdefault\t-`, `${row}0\tshell\t-`) }))
  expect(runsOf(pinned.tree, 'cs:CS_NERD_FONTS').slice(2, 4)).toEqual([{ text: '  ' }, { text: '0'.padEnd(14), color: COLOURS.ink }])
})

test('a percent row draws a ten-cell gauge before its number where the value column holds both, all faint at the default, else filled in amber and empty faint; else the number alone', async ($, on) => {
  const draw = drawer($, on)
  const at58 = await draw(viewOf())
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Context warning %    ▰▰▰▰▱▱▱▱▱▱ 40')
  expect(runsOf(at58.tree, 'cs:CS_CTX_WARN_CTX').slice(3, 6)).toEqual([{ text: '▰▰▰▰', color: COLOURS.faint }, { text: '▱▱▱▱▱▱', color: COLOURS.faint }, { text: ' 40 ', color: COLOURS.mut }])
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Context warn %       ▰▰▰▰▰▱▱▱▱▱ 50   session')
  expect(runsOf(at58.tree, 'cs:CS_STATUSLINE_CTX_WARN').slice(3, 6)).toEqual([{ text: '▰▰▰▰▰', color: COLOURS.amber }, { text: '▱▱▱▱▱', color: COLOURS.faint }, { text: ' 50 ', color: COLOURS.ink }])
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Rotate button from…  the warn %')
  expect(at58.lines.map(line => line.trimEnd())).toContain('  Width in columns     measured')
  expect(runsOf((await draw(viewOf({ columns: 24 }))).tree, 'cs:CS_CTX_WARN_CTX').slice(1)).toEqual([{ text: 'Context …', color: COLOURS.ink }, { text: '  ' }, { text: '40'.padEnd(11), color: COLOURS.mut }])
})

test('only what is set reads: a default row draws its value muted and leaves from and when empty; a set row draws its value in ink, from in its colour, and when, muted, unless it is now', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf())
  expect(runsOf(tree, 'cs:CS_STATUSLINE_DISABLE').slice(3)).toEqual([{ text: '○ off'.padEnd(14), color: COLOURS.mut }, { text: '  ' }, { text: ' '.repeat(7) }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_SEGMENTS').slice(3)).toEqual([{ text: 'logo,session,…', color: COLOURS.mut }, { text: '  ' }, { text: ' '.repeat(7) }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(3)).toEqual([{ text: 'band'.padEnd(14), color: COLOURS.ink }, { text: '  ' }, { text: 'machine', color: COLOURS.green }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_CTX_WARN')[7]).toEqual({ text: 'session', color: COLOURS.teal })
  expect(runsOf(tree, 'cs:CS_STATUSLINE_FRAME')[5]).toEqual({ text: 'shell  ', color: COLOURS.amber })
  expect(runsOf(tree, 'cs:CS_TERM_THEME')[5]).toEqual({ text: 'launch ', color: COLOURS.faint })
  expect(runsOf(tree, 'mod:cs.bandPrompt').slice(3)).toEqual([{ text: 'latest'.padEnd(14), color: COLOURS.ink }, { text: '  ' }, { text: 'mod    ', color: COLOURS.mut }, { text: '  ' }, { text: ' '.repeat(10) }])
  expect(runsOf((await draw(viewOf({ rows: LOCKED }))).tree, 'mod:cs-mermaid.drawDiagrams')[6]).toEqual({ text: 'locked ', color: COLOURS.mut })
  expect(CLEARED).not.toBe(GOLDEN)
  const cleared = await draw(viewOf({ porcelain: CLEARED }))
  expect(cleared.lines.map(line => line.trimEnd())).toContain('  No wake after /cle…  ● on            session  /clear')
  expect(runsOf(cleared.tree, 'cs:CS_NO_ROTATION_WAKE').slice(-1)).toEqual([{ text: '/clear'.padEnd(10), color: COLOURS.mut }])
})

test('the selected row is a row Box the body wide of the marker Text, the label Button and the columns Text: ▌ in the rail\'s second colour and the label bold in ink; every other row two spaces; no row has a background, and every label is in ink', async ($, on) => {
  const draw = drawer($, on)
  const { tree } = await draw(viewOf({ selected: 'cs:CS_STATUSLINE_LAYOUT' }))
  const row = rowOf(tree, 'cs:CS_STATUSLINE_LAYOUT')
  const [marker, button, columns] = (row.children ?? []) as Node[]
  expect(textOf(row).length).toBe(58)
  expect((row.children ?? []).map(child => (child as Node).type)).toEqual(['Text', 'Button', 'Text'])
  expect([textOf(marker), marker?.props.color]).toEqual(['▌ ', COLOURS.rail[1]])
  expect([button?.props.plain, button?.props.label, button?.props.autoFocus, textOf(button)]).toEqual([true, 'Layout', true, 'Layout'.padEnd(19)])
  expect(textOf(columns)).toBe(`  ${'band'.padEnd(14)}  machine  ${' '.repeat(10)}`)
  expect(runsOf(tree, 'cs:CS_STATUSLINE_LAYOUT').slice(0, 2)).toEqual([{ text: '▌ ', color: COLOURS.rail[1] }, { text: 'Layout'.padEnd(19), color: COLOURS.ink, weight: 'bold' }])
  expect(runsOf(tree, 'cs:CS_STATUSLINE_DISABLE').slice(0, 2)).toEqual([{ text: '  ' }, { text: 'Hide the status li…', color: COLOURS.ink }])
  const other = rowOf(tree, 'cs:CS_STATUSLINE_DISABLE')
  expect(other.children?.map(child => [(child as Node).type, (child as Node).props?.autoFocus])).toEqual([['Text', undefined], ['Button', undefined], ['Text', undefined]])
  expect(rowsOf(tree).filter(line => line.startsWith('▌ '))).toEqual(['▌ Layout               band            machine            '])
  const labels = rowBoxes(tree).map(box => {
    const key = String(((box.children ?? []).find(c => (c as Node).type === 'Button') as Node).props.key)
    const label = runsOf(tree, key)[1]
    return [label?.color, label?.dimColor]
  })
  expect(rowBoxes(tree).length).toBe(46)
  expect(rowBoxes(tree).filter(box => box.props.backgroundColor !== undefined).map(textOf)).toEqual([])
  expect(labels).toEqual(Array.from({ length: 46 }, () => [COLOURS.ink, undefined]))
})

test('the field stands between the card and the column header: filter, muted, then an Input keyed filter holding the text, type to filter its placeholder, focused first, Enter labelled first row', async ($, on) => {
  const draw = drawer($, on)
  const parts = ((await draw(viewOf({ filter: 'scope' }))).tree as Node).children as Node[]
  const at = parts.findIndex(part => (part.children ?? []).some(child => (child as Node).type === 'Input'))
  expect([textOf(parts[at - 1]), textOf(parts[at + 1]).trimEnd()]).toEqual(['▍ ● on · session · applies at your next prompt', HEAD_AT_58[0]])
  const [word, input] = (parts[at]?.children ?? []) as Node[]
  expect([parts[at]?.type, parts[at]?.props.flexDirection, textOf(word), word?.props.color]).toEqual(['Box', 'row', 'filter ', COLOURS.mut])
  expect([input?.type, input?.props.key, input?.props.value, input?.props.placeholder, input?.props.autoFocus, input?.props.submitLabel])
    .toEqual(['Input', 'filter', 'scope', 'type to filter', true, 'first row'])
})

test('each line of the card opens with ▍ in the rail\'s second colour: the label bold in ink and the key muted, then the value as its row draws it, the source in its colour and the note muted', async ($, on) => {
  const draw = drawer($, on)
  const card = async (selected: RowId, over: { rows?: ConfigRow[] } = {}) => {
    const parts = ((await draw(viewOf({ selected, ...over }))).tree as Node).children as Node[]
    return parts.slice(2, parts.findIndex((part, i) => i >= 2 && !textOf(part).startsWith('▍'))).map(line => (line.children ?? [])
      .map(run => [textOf(run), (run as Node).props?.color, (run as Node).props?.weight].filter(v => v !== undefined)))
  }
  const edge = ['▍ ', COLOURS.rail[1]]
  const dot = [' · ', COLOURS.mut]
  expect(await card('cs:CS_STATUSLINE_LAYOUT')).toEqual([
    [edge, ['Layout', COLOURS.ink, 'bold'], ['  '], ['CS_STATUSLINE_LAYOUT', COLOURS.mut]],
    [edge, ['band', COLOURS.ink], dot, ['machine', COLOURS.green], dot, ['applies at the next repaint', COLOURS.mut]],
  ])
  expect((await card('cs:CS_STATUSLINE_DISABLE'))[1]).toEqual([edge, ['○ off', COLOURS.mut], dot, ['default', COLOURS.mut], dot, ['applies at the next repaint', COLOURS.mut]])
  expect((await card('cs:CS_SCOPE_DISABLE'))[1]).toEqual([edge, ['●', COLOURS.green], [' on', COLOURS.ink], dot, ['session', COLOURS.teal], dot,
    ['applies at your next prompt', COLOURS.mut]])
  expect((await card('cs:CS_STATUSLINE_CTX_WARN'))[1]).toEqual([edge, ['▰▰▰▰▰', COLOURS.amber], ['▱▱▱▱▱', COLOURS.faint], [' 50', COLOURS.ink], dot,
    ['session', COLOURS.teal], dot, ['applies at the next repaint', COLOURS.mut]])
  expect((await card('cs:CS_CTX_WARN_CTX'))[1]?.slice(1, 4)).toEqual([['▰▰▰▰', COLOURS.faint], ['▱▱▱▱▱▱', COLOURS.faint], [' 40', COLOURS.mut]])
  expect((await card('cs:CS_STATUSLINE_FRAME'))[1]?.slice(1, 4)).toEqual([['6', COLOURS.ink], dot, ['shell', COLOURS.amber]])
  expect((await card('cs:CS_TERM_THEME'))[1]?.slice(1, 4)).toEqual([['dark', COLOURS.ink], dot, ['launch', COLOURS.faint]])
  expect(await card('mod:cs.bandPrompt')).toEqual([
    [edge, ['Band: named prompt', COLOURS.ink, 'bold'], ['  '], ['cs.bandPrompt', COLOURS.mut]],
    [edge, ['latest', COLOURS.ink], dot, ['mod', COLOURS.mut], dot, ['changing it reloads cs (an armed rotation', COLOURS.mut]],
    [edge, ['countdown starts over)', COLOURS.mut]],
  ])
  expect((await card('mod:cs-mermaid.drawDiagrams', { rows: LOCKED }))[1]?.slice(4, 5)).toEqual([['locked', COLOURS.mut]])
})

test('the pane draws every colour but the brand\'s in a theme key, so the engine follows the person\'s theme; what CS_TERM_THEME reads changes no colour', async ($, on) => {
  const draw = drawer($, on)
  const colours = async (over: Partial<PanelView> & { porcelain?: string }) => nodesOf((await draw(viewOf(over))).tree).map(n => [n.props?.color, n.props?.weight])
  const views: Partial<PanelView>[] = [{},{ columns: 80, selected: 'cs:CS_STATUSLINE_CTX_WARN' }, { columns: 24, filter: 'context' }]
  for (const view of views) expect(await colours({ ...view, porcelain: LIGHT }), `the view ${JSON.stringify(view)}`).toEqual(await colours(view))
  const keys = [...new Set((await colours({})).map(([color]) => color).filter(color => color !== undefined && !String(color).startsWith('rgb(')))].sort()
  expect(keys).toEqual(['inactive', 'planMode', 'subtle', 'success', 'text'])
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
// their writer, the AskUserQuestion dialog (each dialog answers the next of
// `replies`, undefined or none a dismissal), and a record of each call (the
// window's moves among them). A pane is open from its ui.open until a ui.close.
function world(on: On, opts: { env?: Record<string, string>; answer?: (argv: readonly string[]) => Answer | Promise<Answer>; rows?: ConfigRow[] } = {}) {
  const w = {
    runs: [] as string[][], toasts: [] as string[], logs: [] as string[], opens: [] as PaneOpenArgs[], sets: [] as { key: string; value: unknown }[],
    asked: [] as unknown[], replies: [] as (string | undefined)[], rows: opts.rows ?? MOD_ROWS, rowsDeny: undefined as string | undefined,
    setDeny: undefined as string | undefined, openDeny: undefined as string | undefined, lists: 0, isOpen: false, scrolls: 0,
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
    const reply = w.replies.shift()
    return (reply === undefined ? { deny: 'dismissed' } : { result: { questions: [], answers: { [question]: reply } } }) as never
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
  on('ui.scroll', () => { w.scrolls++; return {} })
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

// Each dialog asked, in order: its question and its labels.
function dialogs(w: { asked: unknown[] }): { question: string; options: string[] }[] {
  return w.asked.map(questions => {
    const [first] = questions as { question: string; header: string; multiSelect: boolean; options: { label: string; description: string }[] }[]
    if (first === undefined || first.header !== 'cs' || first.multiSelect || first.options.some(o => o.description !== '')) throw new Error(`not one cs question: ${JSON.stringify(questions)}`)
    return { question: first.question, options: first.options.map(o => o.label) }
  })
}

// cs-panel's question for a setting, with the values it names.
const what = (label: string, key: string, values = '') => `What should ${label} (${key}) be?${values} Pick one, or type a value under Other.`

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
  expect(await $.command.run(COMMAND)).toEqual({ text: 'cs settings are in the panel: type to filter, the arrows move, Enter changes the row, Esc closes.' })
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
  expect([drawn[0], drawn[2], drawn[4]]).toEqual(['▌ claude-sessions  settings  ·  46 settings  ·  5 changed  ·  alpha', '▍ Band: prompt bars  cs.bandPrompts', FIELD])
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
  fixture = { ...viewOf(), columns: 40, bodyRows: 12 }
  const lab = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props })
  expect(bodyLines(await pane.drawn())).toEqual(bodyLines(await lab.drawn()))
  expect(JSON.stringify(await pane.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
    .toBe(JSON.stringify(await lab.drawn(), (k, v) => k === 'press' || k === 'part' ? undefined : v))
  const drawn = bodyLines(await pane.drawn()).map(line => line.trimEnd())
  expect([...drawn.slice(0, 3), drawn[6], drawn.at(-1)]).toEqual(['▌ claude-sessions  settings', hero(40), '▍ Band: prompt bars  cs.bandPrompts', FIELD, '+45 below'])
})

test('the ring landing on a row selects it, and the card names that row; a ring on the field keeps the selection', async ($, on) => {
  world(on)
  const pane = await openPane($)
  const shown = async () => headOf(bodyLines(await pane.drawn()))
  expect(await shown()).toEqual(['▍ Band: prompt bars  cs.bandPrompts', '▍ ○ off · mod · changing it reloads cs (an armed rotation countdown starts over)'])
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  const layout = ['▍ Layout  CS_STATUSLINE_LAYOUT', '▍ band · machine · applies at the next repaint']
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
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: { ...PANE_PROPS, bodyColumns: 58, scroll: { offset: 0, bodyRows: 12 } } })
  await clock.settle()
  // The card's first line, the selected row, and the Button marked for the
  // ring with autoFocus: the selected row's. On a surface that draws the
  // field first that mark is inert (the first autoFocus drawn wins) and the
  // ring moves by $.ui.focus, which the kit refuses, so this pins the mark only.
  const shown = async () => {
    const tree = await pane.drawn()
    await clock.settle()
    const ring = nodesOf(tree).filter(n => n.type === 'Button' && n.props.autoFocus === true).map(n => n.props.key)
    return { card: bodyLines(tree)[2], selected: rowsOf(tree).filter(row => row.startsWith('▌ ')).map(row => row.trimEnd()), ring }
  }
  const prompts = { card: '▍ Band: prompt bars  cs.bandPrompts', selected: ['▌ Band: prompt bars    ○ off           mod'], ring: ['mod:cs.bandPrompts'] }
  const prompt = { card: '▍ Band: named prompt  cs.bandPrompt', selected: ['▌ Band: named prompt   latest          mod'], ring: ['mod:cs.bandPrompt'] }
  expect(await shown()).toEqual(prompts)
  expect([await scroll(1), await shown()]).toEqual([{}, prompt])
  expect([await scroll(1), await shown()]).toEqual([{}, { card: '▍ Band: most bars  cs.bandBars', selected: ['▌ Band: most bars      10              mod'], ring: ['mod:cs.bandBars'] }])
  expect([await scroll(-1), await shown()]).toEqual([{}, prompt])
  expect([await scroll(-5), await shown()]).toEqual([{}, prompts])
  expect(w.logs.length).toBe(4)
  expect([await scroll(-1), await shown()]).toEqual([{}, prompts])
  expect(w.logs.length).toBe(5)
  expect(await scroll(5)).toEqual({})
  expect(bodyLines(await pane.drawn()).map(line => line.trimEnd())).toEqual([MASTHEAD_AT_58, hero(58),
    '▍ Hide the status line  CS_STATUSLINE_DISABLE', '▍ ○ off · default · applies at the next repaint', FIELD, ...HEAD_AT_58,
    '+5 above',
    group('Status line'),
    '▌ Hide the status li…  ○ off',
    '  Layout               band            machine',
    '+39 below',
  ])
  const last = { card: '▍ No mods  CS_NO_FUNCTION_HOOKS', selected: ['▌ No mods              off'], ring: ['cs:CS_NO_FUNCTION_HOOKS'] }
  expect([await scroll(1000), await shown()]).toEqual([{}, last])
  expect(bodyLines(await pane.drawn()).slice(-3).map(line => line.trimEnd())).toEqual(['+44 above', '  No update check      ○ off', '▌ No mods              off'])
  expect([await scroll(1), await shown()]).toEqual([{}, last])
  expect(w.scrolls).toBe(1)
  // The kit answers no plugin's $.ui.focus: each of the six moves sends the
  // ring to its new row once, Up from the first row sends it to the field,
  // and each call's refusal is logged.
  expect(w.logs).toEqual(Array.from({ length: 7 }, () => LOGS.failed('no implementation for ui.focus')))
})

// The golden with Hide the status line on in this machine's file.
const MACHINE_FLAG = GOLDEN.replace('Hide the status line\tflag\t-\toff\tnow\tapplies at the next repaint\t-\tdefault\t-',
  'Hide the status line\tflag\t-\toff\tnow\tapplies at the next repaint\t1\tmachine\t-')

test('Enter on an on/off setting asks Turn on or off, Default when a file holds it, This session only when the change would go to the machine under a session name, and Keep; each answer writes cs\'s exact argv', async ($, on) => {
  expect(MACHINE_FLAG).not.toBe(GOLDEN)
  const { w } = world(on, { answer: argv => argv[2] === 'list' ? { stdout: MACHINE_FLAG } : {} })
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('cs:CS_STATUSLINE_DISABLE', 'Turn off')
  await enter('cs:CS_STATUSLINE_DISABLE', 'Default (off)')
  await enter('cs:CS_STATUSLINE_DISABLE', 'This session only: off')
  await enter('cs:CS_STATUSLINE_DISABLE', 'Keep')
  await enter('cs:CS_NERD_FONTS', 'Turn on')
  await enter('cs:CS_NERD_FONTS', 'This session only: on')
  await enter('cs:CS_SCOPE_DISABLE', 'Turn off')
  await enter('cs:CS_SCOPE_DISABLE', 'Default (off)')
  await enter('cs:CS_NO_MAIL_WAKE', 'Turn on')
  expect(writes(w)).toEqual([
    [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '0'],
    [BIN, '-config', 'unset', 'CS_STATUSLINE_DISABLE'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_DISABLE', '0'],
    [BIN, '-config', 'set', 'CS_NERD_FONTS', '1'],
    [BIN, 'alpha', '-config', 'set', 'CS_NERD_FONTS', '1'],
    [BIN, 'alpha', '-config', 'set', 'CS_SCOPE_DISABLE', '0'],
    [BIN, 'alpha', '-config', 'unset', 'CS_SCOPE_DISABLE'],
    [BIN, 'alpha', '-config', 'set', 'CS_NO_MAIL_WAKE', '1'],
  ])
  const disable = { question: what('Hide the status line', 'CS_STATUSLINE_DISABLE'), options: ['Turn off', 'Default (off)', 'This session only: off', 'Keep'] }
  const nerd = { question: what('Nerd Font glyphs', 'CS_NERD_FONTS'), options: ['Turn on', 'This session only: on', 'Keep'] }
  const scope = { question: what('No scope grounding', 'CS_SCOPE_DISABLE'), options: ['Turn off', 'Default (off)', 'Keep'] }
  expect(dialogs(w)).toEqual([disable, disable, disable, disable, nerd, nerd, scope, scope,
    { question: what('No mail wake', 'CS_NO_MAIL_WAKE'), options: ['Turn on', 'Default (off)', 'Keep'] }])
  expect(w.runs.filter(argv => argv.join(' ') === LIST.join(' ')).length).toBe(1 + 9)
})

test('Enter on a choice asks the other choices that fit beside Default (when a file holds it) and Keep, naming every value when some do not fit; a value bound for the machine then asks where under a session name', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('cs:CS_STATUSLINE_LAYOUT', 'capsules', 'This machine')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'quiet', 'This session only')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'Default (quiet)')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'Keep')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'capsules')
  await enter('cs:CS_REWRITE_PROVIDER', 'xai', 'This machine')
  await enter('cs:CS_REWRITE_PROGRESS', 'line', 'This machine')
  await enter('cs:CS_TERM_THEME', 'light', 'This session only')
  expect(writes(w)).toEqual([
    [BIN, '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'],
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'quiet'],
    [BIN, '-config', 'unset', 'CS_STATUSLINE_LAYOUT'],
    [BIN, '-config', 'set', 'CS_REWRITE_PROVIDER', 'xai'],
    [BIN, '-config', 'set', 'CS_REWRITE_PROGRESS', 'line'],
    [BIN, 'alpha', '-config', 'set', 'CS_TERM_THEME', 'light'],
  ])
  const layout = { question: what('Layout', 'CS_STATUSLINE_LAYOUT'), options: ['quiet', 'capsules', 'Default (quiet)', 'Keep'] }
  const where = (label: string, key: string, value: string) => ({ question: `Where should ${label} (${key}) be ${value}?`, options: ['This machine', 'This session only'] })
  expect(dialogs(w)).toEqual([
    layout, where('Layout', 'CS_STATUSLINE_LAYOUT', 'capsules'),
    layout, where('Layout', 'CS_STATUSLINE_LAYOUT', 'quiet'),
    layout, layout,
    layout, where('Layout', 'CS_STATUSLINE_LAYOUT', 'capsules'),
    { question: what('Provider', 'CS_REWRITE_PROVIDER', ' It takes claude, claude-api, openai, openai-api, gemini, gemini-api, grok, xai.'),
      options: ['claude-api', 'openai', 'openai-api', 'Keep'] }, where('Provider', 'CS_REWRITE_PROVIDER', 'xai'),
    { question: what('Progress', 'CS_REWRITE_PROGRESS'), options: ['native', 'line', 'static', 'Keep'] }, where('Progress', 'CS_REWRITE_PROGRESS', 'line'),
    { question: what('Theme', 'CS_TERM_THEME'), options: ['light', 'Keep'] }, where('Theme', 'CS_TERM_THEME', 'light'),
  ])
})

test('Enter on a typed setting asks Keep <value> and Default, the value typed under Other: this session\'s value is written there, and one bound for the machine asks where', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('cs:CS_STATUSLINE_CTX_WARN', '45')
  await enter('cs:CS_STATUSLINE_CTX_WARN', 'Default (40)')
  await enter('cs:CS_STATUSLINE_CTX_WARN', 'Keep 50')
  await enter('cs:CS_SCOPE_BUDGET_MS', '2000', 'This session only')
  await enter('cs:CS_SCOPE_BUDGET_MS', '2000', 'This machine')
  await enter('cs:CS_SCOPE_BUDGET_MS', 'Default (1500)')
  expect(writes(w)).toEqual([
    [BIN, 'alpha', '-config', 'set', 'CS_STATUSLINE_CTX_WARN', '45'],
    [BIN, 'alpha', '-config', 'unset', 'CS_STATUSLINE_CTX_WARN'],
    [BIN, 'alpha', '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
    [BIN, '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
    [BIN, '-config', 'unset', 'CS_SCOPE_BUDGET_MS'],
  ])
  const warn = { question: what('Context warn %', 'CS_STATUSLINE_CTX_WARN'), options: ['Keep 50', 'Default (40)'] }
  const budget = { question: what('Scope scan budget (ms)', 'CS_SCOPE_BUDGET_MS'), options: ['Keep 1500', 'Default (1500)'] }
  const where = { question: 'Where should Scope scan budget (ms) (CS_SCOPE_BUDGET_MS) be 2000?', options: ['This machine', 'This session only'] }
  expect(dialogs(w)).toEqual([warn, warn, warn, budget, where, budget, where, budget])
})

test('with no session name, no dialog offers This session only or asks where, every write goes to this machine, and a value this session\'s file holds says why it is not changed', async ($, on) => {
  const { w } = world(on, { env: { CS_BIN: BIN }, answer: argv => argv[2] === 'list' ? { stdout: MACHINE_FLAG } : {} })
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('cs:CS_STATUSLINE_DISABLE', 'Turn off')
  await enter('cs:CS_NERD_FONTS', 'Turn on')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'capsules')
  await enter('cs:CS_SCOPE_BUDGET_MS', '2000')
  await enter('cs:CS_STATUSLINE_CTX_WARN', '45')
  expect(writes(w)).toEqual([
    [BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '0'],
    [BIN, '-config', 'set', 'CS_NERD_FONTS', '1'],
    [BIN, '-config', 'set', 'CS_STATUSLINE_LAYOUT', 'capsules'],
    [BIN, '-config', 'set', 'CS_SCOPE_BUDGET_MS', '2000'],
  ])
  expect(dialogs(w)).toEqual([
    { question: what('Hide the status line', 'CS_STATUSLINE_DISABLE'), options: ['Turn off', 'Default (off)', 'Keep'] },
    { question: what('Nerd Font glyphs', 'CS_NERD_FONTS'), options: ['Turn on', 'Keep'] },
    { question: what('Layout', 'CS_STATUSLINE_LAYOUT'), options: ['quiet', 'capsules', 'Default (quiet)', 'Keep'] },
    { question: what('Scope scan budget (ms)', 'CS_SCOPE_BUDGET_MS'), options: ['Keep 1500', 'Default (1500)'] },
  ])
  expect(w.toasts.slice(-1)).toEqual(["Context warn %: this session's file sets it, and this conversation has no cs session name to write it with"])
})

test('Enter on a row no dialog changes toasts the card\'s why and asks and writes nothing: the shell pins it, it changes from a shell, a managed setting owns it', async ($, on) => {
  const { w } = world(on, { rows: LOCKED })
  const pane = await openPane($)
  for (const key of ['cs:CS_STATUSLINE_FRAME', 'cs:CS_NO_FUNCTION_HOOKS', 'mod:cs-mermaid.drawDiagrams']) await pane.press({ key })
  expect(w.toasts).toEqual([
    'Frame columns: CS_STATUSLINE_FRAME=6 in your environment wins; unset it there to change it here',
    'No mods: change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the next launch, this panel too)',
    'Draw mermaid diagrams: a managed setting owns it',
  ])
  expect([writes(w), w.sets, w.asked]).toEqual([[], [], []])
})

test('a dismissed dialog or Keep writes nothing and says nothing', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('cs:CS_STATUSLINE_CTX_WARN')
  await enter('cs:CS_STATUSLINE_CTX_WARN', 'Keep 50')
  await enter('cs:CS_STATUSLINE_DISABLE', 'Keep')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'Keep')
  await enter('cs:CS_STATUSLINE_LAYOUT', 'capsules', 'neither')
  await enter('mod:cs.bandBars')
  await enter('mod:cs.bandBars', 'Keep 10')
  await enter('mod:cs.bandBars', 'Cancel')
  expect([writes(w), w.sets, w.toasts]).toEqual([[], [], []])
  expect(w.asked.length).toBe(9)
})

test('cs\'s reply is the toast: its line when the write lands, and when cs refuses, its own refusal', async ($, on) => {
  let write: Answer = { stdout: 'CS_STATUSLINE_LAYOUT=capsules in ~/.config/cs/config: applies at the next repaint\n' }
  const { w } = world(on, { answer: argv => argv[2] === 'list' ? { stdout: GOLDEN } : write })
  const pane = await openPane($)
  w.replies = ['capsules', 'This machine']
  await pane.press({ key: 'cs:CS_STATUSLINE_LAYOUT' })
  write = { exitCode: 1, stderr: 'Error: CS_STATUSLINE_LAYOUT is quiet, band or capsules; got bands\n' }
  w.replies = ['bands', 'This machine']
  await pane.press({ key: 'cs:CS_STATUSLINE_LAYOUT' })
  expect(w.toasts).toEqual([
    'CS_STATUSLINE_LAYOUT=capsules in ~/.config/cs/config: applies at the next repaint',
    'CS_STATUSLINE_LAYOUT not changed: exited 1: Error: CS_STATUSLINE_LAYOUT is quiet, band or capsules; got bands',
  ])
})

test('Enter on a /config row changes it through $.config.set: a boolean toggles to its negation at once, a choice and a number ask, abc is refused unwritten, a deny is toasted', async ($, on) => {
  const { w } = world(on)
  const pane = await openPane($)
  const enter = async (key: string, ...replies: string[]) => { w.replies = replies; await pane.press({ key }) }
  await enter('mod:cs.bandPrompts')
  await enter('mod:cs.bandPrompt', 'read')
  await enter('mod:cs.bandBars', 'abc')
  await enter('mod:cs.bandBars', '12')
  w.setDeny = 'Band: most bars takes a whole number of 1 or more'
  await enter('mod:cs.bandBars', '0')
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

test('Enter on a row whose last change still runs says so and writes nothing', async ($, on) => {
  const written = gate()
  const { w, clock } = world(on, { answer: async argv => {
    if (argv[2] === 'list') return { stdout: GOLDEN }
    await written.held
    return { stdout: 'CS_STATUSLINE_DISABLE=1 in ~/.config/cs/config: applies at the next repaint\n' }
  } })
  const pane = await openPane($)
  w.replies = ['Turn on']
  const first = pane.press({ key: 'cs:CS_STATUSLINE_DISABLE' })
  const second = pane.press({ key: 'cs:CS_STATUSLINE_DISABLE' })
  await clock.settle()
  expect(w.toasts).toEqual(['CS_STATUSLINE_DISABLE is still changing, or no longer listed; try again'])
  written.open()
  await Promise.all([first, second])
  await clock.settle()
  expect(writes(w)).toEqual([[BIN, '-config', 'set', 'CS_STATUSLINE_DISABLE', '1']])
  expect(w.toasts).toEqual(['CS_STATUSLINE_DISABLE is still changing, or no longer listed; try again', 'CS_STATUSLINE_DISABLE=1 in ~/.config/cs/config: applies at the next repaint'])
  expect(w.asked.length).toBe(1)
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
  const card = ['▍ Band: prompt bars  cs.bandPrompts', '▍ ○ off · mod · changing it reloads cs (an armed rotation countdown starts over)']
  expect(await read({ exitCode: 1, stderr: 'warming up\nError: boom\n' })).toEqual({ head: [...card, 'cs -config list exited 1: Error: boom'], rows: 46 })
  expect(await read({ stdout: 'oops\n' })).toEqual({ head: [...card, 'cs -config list gave a line the panel cannot read: oops'], rows: 46 })
  expect(await read({ stdout: '' })).toEqual({ head: [...card, 'cs -config list printed no settings'], rows: 46 })
  w.rowsDeny = 'the menu is busy'
  expect(await read({ stdout: GOLDEN })).toEqual({ head: [...card, 'the /config rows could not be read: cs-panel: $.config.list: the menu is busy'], rows: 46 })
  w.rowsDeny = undefined
  expect(await read({ stdout: GOLDEN })).toEqual({ head: card, rows: 46 })
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
    return { card: headOf(bodyLines(tree))[0], rows: rowsOf(tree).map(row => row.trimEnd()) }
  }
  const scroll = async (by: number) => {
    await $.ui.scroll({ component: 'Pane', requestId: 'cs-panel', offset: 0, by, bodyRows: 80, contentRows: 80, origin: { kind: 'person' } })
    await clock.settle()
    return headOf(bodyLines(await pane.drawn()))[0]
  }
  const grounding = `  ${'No scope grounding'.padEnd(26)}  ${'● on'.padEnd(14)}  session`
  const trace = `  ${'No scope trace'.padEnd(26)}  ○ off`
  const budget = `  ${'Scope scan budget (ms)'.padEnd(26)}  1500`
  const selected = (row: string) => `▌${row.slice(1)}`
  await focus($, 'cs:CS_SCOPE_BUDGET_MS')
  expect(await type('scope')).toEqual({ card: '▍ Scope scan budget (ms)  CS_SCOPE_BUDGET_MS', rows: [grounding, trace, selected(budget)] })
  const lines = bodyLines(await pane.drawn()).map(line => line.trimEnd())
  expect([lines[0], lines.slice(4, 8)]).toEqual(['▌ claude-sessions  settings  ·  46 settings  ·  5 changed  ·  alpha',
    ['filter scope', `  ${'setting'.padEnd(26)}  ${'value'.padEnd(14)}  ${'from'.padEnd(7)}  when`, soft(80), group('Prompts', 80)]])
  expect(await type('TRACE')).toEqual({ card: '▍ No scope trace  CS_SCOPE_TRACE_DISABLE', rows: [selected(trace)] })
  expect((await type('')).rows.length).toBe(46)
  expect(await type('scope')).toEqual({ card: '▍ Scope scan budget (ms)  CS_SCOPE_BUDGET_MS', rows: [grounding, trace, selected(budget)] })
  expect([await scroll(-1), await scroll(-1), await scroll(5), await scroll(-5)])
    .toEqual(['▍ No scope trace  CS_SCOPE_TRACE_DISABLE', '▍ No scope grounding  CS_SCOPE_DISABLE', '▍ Scope scan budget (ms)  CS_SCOPE_BUDGET_MS', '▍ No scope grounding  CS_SCOPE_DISABLE'])
  const logs = w.logs.length
  expect(await scroll(-1)).toBe('▍ No scope grounding  CS_SCOPE_DISABLE')
  expect(w.logs.length).toBe(logs + 1)
  await focus($, 'cs:CS_SCOPE_BUDGET_MS')
  // Enter in the field: the first row shown is selected and the ring sent to
  // it, which the kit refuses and the mod logs.
  expect(await type('scope', 'submit')).toEqual({ card: '▍ No scope grounding  CS_SCOPE_DISABLE', rows: [selected(grounding), trace, budget] })
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
  expect(headOf(lines).slice(-1)).toEqual(['cs -config list exited 127: cs: command not found'])
  expect([lines[lines.indexOf(soft(80)) + 1], rowsOf(tree).length]).toEqual([group('Mods', 80), 5])
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

test('the pane draws on every surface, its rows as Buttons and its field as an Input, but on the mobile app, which draws no Input: there an empty line stands in its place', async ($, on) => {
  world(on)
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const pane = await $.ui.mount({ plugin: 'cs-panel', surface, component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
    expect((await pane.find({ key: 'cs:CS_STATUSLINE_LAYOUT' }))?.props.label, surface).toBe('Layout')
    expect((await pane.find({ key: 'filter' }))?.type, surface).toBe(surface === 'mobile' ? undefined : 'Input')
    expect(bodyLines(await pane.drawn())[4], surface).toBe(surface === 'mobile' ? ' ' : FIELD)
    await pane.unmount()
  }
})

test('no line the mod hands the engine names the plugin first: the engine prefixes it', () => {
  const call = (f: unknown) => typeof f === 'string' ? f : (f as (...args: string[]) => string)('x', 'y', 'z')
  const lines = [
    COMMANDS['cs-panel'].description, ...Object.values(REPLIES).map(call), ASKS.setting('x', 'y', []), ASKS.setting('x', 'y', ['a', 'b']), ASKS.mod('x', 'y', []),
    ASKS.where('x', 'y', 'z'), ...Object.values(TOASTS).map(call), ...Object.values(PROBLEMS).map(call), ...Object.values(LOGS).map(call),
  ]
  expect(lines.length).toBe(20)
  expect(lines.filter(line => line.toLowerCase().startsWith('cs-panel'))).toEqual([])
})
