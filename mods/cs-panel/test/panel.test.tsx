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
    good.replace('launch\t-\tdefault', 'launch\t2\tdefault'),
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
// tree: a plain Button with a hotkey is `<hotkey>: <label>`, one with children
// draws its children, and a row Box puts its columnGap between its children.
function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  const n = node as { type: string; props: Record<string, unknown>; children?: unknown[] }
  const children = n.children ?? []
  if (n.type === 'Button' && children.length === 0) return n.props.hotkey === undefined ? String(n.props.label) : `${n.props.hotkey}: ${n.props.label}`
  if (n.type === 'Box') return children.map(textOf).join(' '.repeat(Number(n.props.columnGap ?? 0)))
  return children.map(textOf).join('')
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
function drawer($: Engine, on: On): (view: PanelView, key?: string) => Promise<{ lines: string[]; label: unknown }> {
  let view: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => {
    if (view === undefined) throw new Error('no view to draw')
    return drawPane(view, $.ui.resolve(e), NOOP)
  })
  return async (next, key) => {
    view = next
    const ui = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props: fixtureProps(next) })
    const lines = bodyLines(await ui.drawn())
    const label = key === undefined ? undefined : (await ui.find({ key }))?.props.label
    await ui.unmount()
    return { lines, label }
  }
}

function viewOf(over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[] } = {}): PanelView {
  const { hasSelf = true, rows = MOD_ROWS, ...rest } = over
  return { lines: linesOf(modRowsOf(rows), settingsOf(GOLDEN), new Map(), hasSelf), selected: undefined, problems: [], columns: 58, bodyRows: 70, hasKeys: true, ...rest }
}

// design.md's columns at the dock's 58-column body: the name in 22 cells, then
// value 11, from 7 and when 10, each after a gap of 2; the golden's fields
// through them, worked out apart from the mod.
const GOLDEN_AT_58 = [
  'Mods',
  '› Band: prompt bars       off          mod      now',
  '  Band: named prompt      latest       mod      now',
  '  Band: most bars         10           mod      now',
  '  Release notes pane      on           mod      now',
  '  Draw mermaid diagrams   on           mod      now',
  'Status line',
  '  Hide the status line    off          default  now',
  '  Layout                  band         machine  now',
  '  Segments                logo,sessi…  default  now',
  '  Band colour             session      default  now',
  '  Width in columns        measured     default  now',
  '  Frame columns           6            shell    now',
  '  Context warn %          50           session  now',
  '  Context critical %      65           default  now',
  '  Usage from cache only   off          default  now',
  '  Hide the subagent rows  off          default  now',
  'Prompts',
  '  No scope grounding      on           session  now',
  '  No scope trace          off          default  now',
  '  Scope scan budget (ms)  1500         default  now',
  '  No objective capture    off          default  now',
  '  No date reminder        off          default  now',
  '  No clarifying questio…  off          default  now',
  'Turn end',
  '  Context warning %       40           default  now',
  '  Rotation nudge %        65           default  now',
  '  Queue stops after fai…  5            default  now',
  '  Queue stops past cont…  85           default  now',
  '  Queue stops past 5h l…  85           default  now',
  '  Mail wakes in a row     5            default  now',
  '  No mail wake            off          session  now',
  '  Narrative budget (byt…  131072       default  now',
  '  Narrative tail kept (…  65536        default  now',
  'Rotation',
  '  Rotate on its own pas…  80           default  now',
  '  Rotate button from %    the warn %   default  now',
  '  No wake after /clear    off          default  /clear',
  '  Wake delay (s)          2            default  now',
  'Rewriter (ctrl+g)',
  '  Provider                claude       default  now',
  '  Model                   per provid…  default  now',
  '  Timeout (s)             25           default  now',
  '  Progress                screen       default  now',
  '  No rewrite              off          default  now+launch',
  'Terminal',
  '  Theme                   dark         launch   now',
  '  Background r;g;b        detected     default  now',
  '  No iTerm2 features      off          default  now+launch',
  '  Nerd Font glyphs        off          default  now',
  'Launch',
  '  No task tools           off          default  launch',
  '  No update check         off          default  launch',
  '  No mods                 off          default  launch',
]

test('the golden porcelain and the mod rows draw under their groups, Mods first, each row exactly the body wide, under the first row\'s strip and detail', async ($, on) => {
  const draw = drawer($, on)
  const { lines } = await draw(viewOf())
  expect(lines.map(line => line.trimEnd())).toEqual([
    'c: change   Esc: close',
    'cs.bandPrompts: changing it reloads cs (an armed rotation',
    'countdown starts over)',
    ...GOLDEN_AT_58,
  ])
  const rows = lines.filter(line => line.startsWith('› ') || line.startsWith('  '))
  expect(rows.length).toBe(46)
  expect(rows.filter(line => line.length !== 58)).toEqual([])
  expect((await draw({ ...viewOf(), lines: undefined })).lines).toEqual(['Esc: close', 'asking cs for its settings…'])
})

test('a row offers c, u where a file sets it and p under a session name; a shell row, CS_NO_FUNCTION_HOOKS and a locked row offer no key and say why', async ($, on) => {
  const draw = drawer($, on)
  const head = async (selected: RowId, over: Partial<PanelView> & { hasSelf?: boolean; rows?: ConfigRow[] } = {}) => {
    const { lines } = await draw(viewOf({ selected, ...over }))
    return lines.slice(0, lines.indexOf('Mods'))
  }
  expect(await head('cs:CS_STATUSLINE_LAYOUT')).toEqual(['c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT: applies at the next repaint'])
  expect(await head('cs:CS_STATUSLINE_DISABLE')).toEqual(['c: change   p: this session only   Esc: close', 'CS_STATUSLINE_DISABLE: applies at the next repaint'])
  expect(await head('cs:CS_STATUSLINE_LAYOUT', { hasSelf: false })).toEqual(['c: change   u: default   Esc: close', 'CS_STATUSLINE_LAYOUT: applies at the next repaint'])
  expect((await head('cs:CS_STATUSLINE_CTX_WARN', { hasSelf: false }))[0]).toBe('Esc: close')
  expect(await head('cs:CS_STATUSLINE_BAND')).toEqual(['c: change   p: this session only   Esc: close',
    'CS_STATUSLINE_BAND: machine line 4:', 'CS_STATUSLINE_BAND=magenta: not a palette name, brand,…'])
  expect(await head('cs:CS_STATUSLINE_FRAME')).toEqual(['Esc: close', 'CS_STATUSLINE_FRAME=6 in your environment wins; unset it', 'there to change it here'])
  expect(await head('cs:CS_NO_FUNCTION_HOOKS')).toEqual(['Esc: close', 'change it from a shell: cs -config set', 'CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the…'])
  expect(await head('cs:CS_NO_FUNCTION_HOOKS', { columns: 130 })).toEqual(['Esc: close',
    'change it from a shell: cs -config set CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the next launch, this panel too)'])
  expect(await head('mod:cs-mermaid.drawDiagrams', { rows: LOCKED })).toEqual(['Esc: close', 'cs-mermaid.drawDiagrams: a managed setting owns it'])
  const { lines } = await draw(viewOf({ rows: LOCKED }))
  expect(lines.map(line => line.trimEnd())).toContain('  Draw mermaid diagrams   on           locked   now')
  expect(ringOf(viewOf({ selected: 'cs:CS_STATUSLINE_FRAME' })).keys.filter(k => k.startsWith('act:'))).toEqual([])
  expect(await head('cs:CS_STATUSLINE_LAYOUT', { hasKeys: false })).toEqual(['c: change   u: default   p: this session only', 'CS_STATUSLINE_LAYOUT: applies at the next repaint'])
  expect((await head('cs:CS_STATUSLINE_FRAME', { hasKeys: false }))[0]).toBe('ctrl+x tab: keys')
})

test('every row, the strip and the detail fit 24, 40, 60 and 80 columns, and 46 rows in 12 lines keep the selected row drawn', async ($, on) => {
  const draw = drawer($, on)
  const ids: RowId[] = [...modRowsOf(MOD_ROWS).map(m => `mod:${m.key}` as const), ...settingsOf(GOLDEN).map(s => `cs:${s.key}` as const)]
  expect(ids.length).toBe(46)
  for (const columns of [24, 40, 60, 80]) {
    for (const selected of ids) {
      const { lines, label } = await draw(viewOf({ columns, bodyRows: 12, selected }), selected)
      const rows = lines.filter(line => line.startsWith('› ') || line.startsWith('  '))
      expect(rows.filter(row => row.length !== columns), `rows at ${columns} with ${selected}`).toEqual([])
      expect(lines.filter(line => line.length > columns), `lines past ${columns} with ${selected}`).toEqual([])
      expect(lines.length <= 12, `${lines.length} lines in 12 at ${columns} with ${selected}`).toBe(true)
      expect(rows.filter(row => row.startsWith('› ')).length, `the selected row at ${columns} with ${selected}`).toBe(1)
      expect(label, `${selected} drawn at ${columns}`).not.toBe(undefined)
    }
  }
  expect((await draw(viewOf({ columns: 24, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines.slice(0, 3)).toEqual(['c: change', 'u: default', 'p: session'])
  expect((await draw(viewOf({ columns: 40, selected: 'cs:CS_STATUSLINE_LAYOUT' }))).lines[0]).toBe('c: change   u: default   p: session')
  // 54 lines (46 rows, 8 headings) in the 10 the strip and detail leave: the
  // window holds the selected row a line from either edge, and +N counts the
  // rows it leaves out.
  const at = async (selected: RowId) => (await draw(viewOf({ columns: 58, bodyRows: 12, selected }))).lines.map(line => line.trimEnd())
  expect(await at('cs:CS_STATUSLINE_LAYOUT')).toEqual([
    'c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT: applies at the next repaint',
    '+4 above',
    '  Draw mermaid diagrams   on           mod      now',
    'Status line',
    '  Hide the status line    off          default  now',
    '› Layout                  band         machine  now',
    '  Segments                logo,sessi…  default  now',
    '  Band colour             session      default  now',
    '  Width in columns        measured     default  now',
    '  Frame columns           6            shell    now',
    '+35 below',
  ])
  expect(await at('cs:CS_NO_UPDATE_CHECK')).toEqual([
    'c: change   p: this session only   Esc: close', 'CS_NO_UPDATE_CHECK: applies at the next launch',
    '+39 above',
    'Terminal',
    '  Theme                   dark         launch   now',
    '  Background r;g;b        detected     default  now',
    '  No iTerm2 features      off          default  now+launch',
    '  Nerd Font glyphs        off          default  now',
    'Launch',
    '  No task tools           off          default  launch',
    '› No update check         off          default  launch',
    '  No mods                 off          default  launch',
  ])
  expect(await at('cs:CS_NO_FUNCTION_HOOKS')).toEqual([
    'Esc: close', 'change it from a shell: cs -config set', 'CS_NO_FUNCTION_HOOKS 1 (on, it unloads every mod at the…',
    '+39 above',
    '  Theme                   dark         launch   now',
    '  Background r;g;b        detected     default  now',
    '  No iTerm2 features      off          default  now+launch',
    '  Nerd Font glyphs        off          default  now',
    'Launch',
    '  No task tools           off          default  launch',
    '  No update check         off          default  launch',
    '› No mods                 off          default  launch',
  ])
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

// ── The hooks, through the engine's own `$` ──────────────────────────────

const BIN = '/opt/cs/bin/cs'
const PANE_PROPS = { title: 'cs', isFocused: true, bodyColumns: 80, placement: 'inline', scroll: { offset: 0, bodyRows: 70 }, view: {} } as const
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
  expect(bodyLines(await pane.drawn())[0]).toBe('c: change   Esc: close')
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
  expect(bodyLines(await pane.drawn())[0]).toBe('c: change   ctrl+x tab: keys')
})

test('the ring landing on a row selects it, and the strip and detail name that row; a ring on a strip key keeps the selection', async ($, on) => {
  world(on)
  const pane = await openPane($)
  const head = async () => bodyLines(await pane.drawn()).slice(0, 2)
  expect(await head()).toEqual(['c: change   Esc: close', 'cs.bandPrompts: changing it reloads cs (an armed rotation countdown starts over)'])
  await focus($, 'cs:CS_STATUSLINE_LAYOUT')
  expect(await head()).toEqual(['c: change   u: default   p: this session only   Esc: close', 'CS_STATUSLINE_LAYOUT: applies at the next repaint'])
  await focus($, 'act:unset')
  expect((await head())[1]).toBe('CS_STATUSLINE_LAYOUT: applies at the next repaint')
  await focus($, 'cs:CS_NOT_A_ROW')
  expect((await head())[1]).toBe('CS_STATUSLINE_LAYOUT: applies at the next repaint')
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
  expect(bodyLines(await pane.drawn()).slice(0, 2)).toEqual(['Esc: close', 'cs-mermaid.drawDiagrams: a managed setting owns it'])
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
  expect(bodyLines(await pane.drawn())[1]).toBe('CS_STATUSLINE_DISABLE: applies at the next repaint')
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
  expect(await bars()).toBe('  Band: most bars                               10           mod      now')
  const read = w.lists
  w.rows = MOD_ROWS.map(r => r.key === 'cs.bandBars' ? { ...r, value: 12 } : r)
  await $.config.set({ key: 'cs.bandBars', value: 12, previous: 10, provider: CS, origin: { kind: 'composer' } })
  await clock.settle()
  expect(w.lists).toBe(read + 1)
  expect(await bars()).toBe('  Band: most bars                               12           mod      now')
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
    return bodyLines(await pane.drawn()).map(line => line.trimEnd())
  }
  const rowsIn = (lines: string[]) => lines.filter(line => line.startsWith('› ') || line.startsWith('  ')).length
  let lines = await read({ exitCode: 1, stderr: 'warming up\nError: boom\n' })
  expect(lines.slice(0, 4)).toEqual(['c: change   Esc: close', 'cs.bandPrompts: changing it reloads cs (an armed rotation countdown starts over)', 'cs -config list exited 1: Error: boom', 'Mods'])
  expect(rowsIn(lines)).toBe(46)
  lines = await read({ stdout: 'oops\n' })
  expect([lines[2], rowsIn(lines)]).toEqual(['cs -config list gave a line the panel cannot read: oops', 46])
  lines = await read({ stdout: '' })
  expect([lines[2], rowsIn(lines)]).toEqual(['cs -config list printed no settings', 46])
  w.rowsDeny = 'the menu is busy'
  lines = await read({ stdout: GOLDEN })
  expect([lines[2], lines[3], rowsIn(lines)]).toEqual(['the /config rows could not be read: cs-panel: $.config.list: the menu is busy', 'Mods', 46])
  w.rowsDeny = undefined
  lines = await read({ stdout: GOLDEN })
  expect(lines[2]).toBe('Mods')
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
  const lines = bodyLines(await pane.drawn()).map(line => line.trimEnd())
  expect(lines.slice(2, 4)).toEqual(['cs -config list exited 127: cs: command not found', 'Mods'])
  expect(lines.filter(line => line.startsWith('› ') || line.startsWith('  ')).length).toBe(5)
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
