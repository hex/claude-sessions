// ABOUTME: Engine test-kit tests for the cs-panel mod: the porcelain parser, the rows and their keys, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from porcelain.md, the golden file (test/golden.ts) and the design's rules, never from the code under test.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, PaneOpenArgs } from 'claude-code'

import { GOLDEN } from './golden'
import { drawPane, ringBack, ringOf, type PanelView } from '../hooks/draw'
import { ASKS, COMMANDS, LOGS, PROBLEMS, REPLIES, STATUS_BODY, TOASTS } from '../hooks/register'
import { parseList, parseReadiness, retireVerdict, rowsOf, sessionName, type Pending, type Readiness, type Row, type Session, type SessionName } from '../hooks/sessions'

function nameOf(text: string): SessionName {
  const name = sessionName(text)
  if (name === undefined) throw new Error(`not a session name: ${text}`)
  return name
}

// What a reader sees of each row: its name, depth and keys.
function shapeOf(rows: readonly Row[]): [string, number, string[]][] {
  return rows.map(r => [r.session.name, r.depth, [...r.actions]])
}

function sessionsOf(stdout: string): Session[] {
  const parsed = parseList(stdout)
  if ('unreadable' in parsed) throw new Error(`the fixture is unreadable: ${parsed.unreadable}`)
  return parsed
}

test('the golden answer parses to its four sessions, unknowns kept unknown', () => {
  expect(sessionsOf(GOLDEN)).toEqual([
    { name: 'alpha', feature: undefined, live: true, context: 41, unread: 2, features: 1 },
    { name: 'alpha@fix', feature: { base: 'alpha', task: 'fix' }, live: false, context: 12, unread: 0, features: 0 },
    { name: 'alpha@stale', feature: { base: 'alpha', task: 'stale' }, live: false, context: undefined, unread: 0, features: 0 },
    { name: 'beta', feature: undefined, live: false, context: undefined, unread: undefined, features: 0 },
  ])
})

test('one line outside the record refuses the whole answer, naming that line; an empty answer is no sessions', () => {
  const good = 'beta\t0\t-\t-\t0'
  for (const bad of ['alpha\t1\t41\t2', 'alpha\t1\t41\t2\t1\t0', 'alpha\t2\t41\t2\t1', 'alpha\t1\t101\t2\t1', 'alpha\t1\t4x\t2\t1', 'alpha\t1\t41\tx\t1', 'alpha\t1\t41\t2\t-', 'bad name\t0\t-\t0\t0', 'alpha@\t0\t-\t0\t0', '@fix\t0\t-\t0\t0']) {
    expect(parseList(`${good}\n${bad}\n`)).toEqual({ unreadable: bad })
  }
  expect(parseList('')).toEqual([])
})

test('features sit under their base in the porcelain order, and one whose base is not listed closes the list at depth 0', () => {
  const answer = 'gamma\t0\t-\t-\t0\ngone@x\t0\t-\t0\t0\n' + GOLDEN
  expect(shapeOf(rowsOf(sessionsOf(answer), undefined, new Map())).map(([name, depth]) => [name, depth])).toEqual([
    ['gamma', 0], ['alpha', 0], ['alpha@fix', 1], ['alpha@stale', 1], ['beta', 0], ['gone@x', 0],
  ])
})

test('each row offers the keys its session allows: open when idle, mail when reachable, retire on an idle feature, none on this session or while pending', () => {
  expect(shapeOf(rowsOf(sessionsOf(GOLDEN), undefined, new Map()))).toEqual([
    ['alpha', 0, ['mail']],
    ['alpha@fix', 1, ['open', 'mail', 'retire']],
    ['alpha@stale', 1, ['open', 'mail', 'retire']],
    ['beta', 0, ['open']],
  ])
  const asSelf = rowsOf(sessionsOf(GOLDEN), nameOf('alpha'), new Map())
  expect(asSelf.map(r => [r.session.name, r.isSelf, [...r.actions]])).toEqual([
    ['alpha', true, []], ['alpha@fix', false, ['open', 'mail', 'retire']], ['alpha@stale', false, ['open', 'mail', 'retire']], ['beta', false, ['open']],
  ])
  const asFeature = rowsOf(sessionsOf(GOLDEN), nameOf('alpha@fix'), new Map())
  expect(asFeature.map(r => [r.session.name, r.isSelf, [...r.actions]])).toEqual([
    ['alpha', false, ['mail']], ['alpha@fix', true, []], ['alpha@stale', false, ['open', 'mail', 'retire']], ['beta', false, ['open']],
  ])
  const liveFeature = sessionsOf('alpha\t1\t41\t2\t1\nalpha@fix\t1\t12\t0\t0\n')
  expect(shapeOf(rowsOf(liveFeature, undefined, new Map()))).toEqual([['alpha', 0, ['mail']], ['alpha@fix', 1, ['mail']]])
  const pending = new Map<SessionName, Pending>([[nameOf('beta'), 'opening']])
  const rows = rowsOf(sessionsOf(GOLDEN), undefined, pending)
  expect(rows.map(r => [r.session.name, r.pending, [...r.actions]])).toEqual([
    ['alpha', undefined, ['mail']], ['alpha@fix', undefined, ['open', 'mail', 'retire']], ['alpha@stale', undefined, ['open', 'mail', 'retire']], ['beta', 'opening', []],
  ])
})

// One `cs <base> -features --porcelain` line, as _feature_readiness prints it:
// task branch ahead merged ff wt_dirty untracked base_dirty lock state.
function readinessLine(f: { ahead?: number; merged?: 0 | 1; wtDirty?: 0 | 1; untracked?: number; lock?: string; state: string }): string {
  return ['fix', 'cs/fix', f.ahead ?? 0, f.merged ?? 0, 1, f.wtDirty ?? 0, f.untracked ?? 0, 0, f.lock ?? 'none', f.state].join('\t')
}

function readinessOf(line: string): Readiness {
  const parsed = parseReadiness(`${line}\n`)
  if ('unreadable' in parsed || parsed[0] === undefined) throw new Error(`the readiness fixture is unreadable: ${line}`)
  return parsed[0]
}

test('a readiness record parses strictly: ten fields, the three lock words, a lowercase state', () => {
  expect(parseReadiness(`${readinessLine({ ahead: 3, state: 'ready' })}\n`)).toEqual([{ task: 'fix', ahead: 3, merged: false, wtDirty: false, untracked: 0, lock: 'none', state: 'ready' }])
  for (const bad of [readinessLine({ state: 'ready' }).split('\t').slice(0, 9).join('\t'), readinessLine({ lock: 'both', state: 'locked' }), readinessLine({ state: 'Ready' }), readinessLine({ state: 'ready' }).replace('cs/fix\t0', 'cs/fix\tx')]) {
    expect(parseReadiness(`${bad}\n`)).toEqual({ unreadable: bad })
  }
})

test('a feature retires when ready with commits; the base\'s own lock does not stop the mail route, but what it hides in front of the merge does', () => {
  const verdict = (f: Parameters<typeof readinessLine>[0], route: 'here' | 'mail') => retireVerdict(readinessOf(readinessLine(f)), route)
  expect(retireVerdict(undefined, 'mail')).toEqual({ go: false, why: 'not a feature git lists' })
  expect(verdict({ ahead: 3, state: 'ready' }, 'here')).toEqual({ go: true })
  expect(verdict({ ahead: 3, state: 'ready' }, 'mail')).toEqual({ go: true })
  expect(verdict({ ahead: 0, state: 'ready' }, 'here')).toEqual({ go: false, why: 'no commits' })
  expect(verdict({ ahead: 3, wtDirty: 1, state: 'dirty' }, 'mail')).toEqual({ go: false, why: 'dirty' })
  expect(verdict({ ahead: 0, merged: 1, state: 'merged' }, 'mail')).toEqual({ go: false, why: 'merged' })
  expect(verdict({ ahead: 2, lock: 'base', state: 'locked' }, 'mail')).toEqual({ go: true })
  expect(verdict({ ahead: 2, lock: 'base', state: 'locked' }, 'here')).toEqual({ go: false, why: 'locked' })
  expect(verdict({ ahead: 2, lock: 'worktree', state: 'locked' }, 'mail')).toEqual({ go: false, why: 'locked' })
  expect(verdict({ ahead: 2, wtDirty: 1, lock: 'base', state: 'locked' }, 'mail')).toEqual({ go: false, why: 'dirty' })
  expect(verdict({ ahead: 2, untracked: 2, lock: 'base', state: 'locked' }, 'mail')).toEqual({ go: false, why: 'untracked' })
  expect(verdict({ ahead: 0, merged: 1, lock: 'base', state: 'locked' }, 'mail')).toEqual({ go: false, why: 'merged' })
  expect(verdict({ ahead: 0, lock: 'base', state: 'locked' }, 'mail')).toEqual({ go: false, why: 'no commits' })
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
function linesOf(tree: unknown): string[] {
  const root = tree as { children?: unknown[] }
  return (root.children ?? []).flatMap(child => {
    const c = child as { type: string; props: Record<string, unknown>; children?: unknown[] }
    return c.type === 'Box' && c.props.flexDirection === 'column' ? (c.children ?? []).map(textOf) : [textOf(c)]
  })
}

// Draws views through the test's own render hook, as the design lab does.
function drawer($: Engine, on: On): (view: PanelView) => Promise<string[]> {
  let view: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => {
    if (view === undefined) throw new Error('no view to draw')
    return drawPane(view, $.ui.resolve(e), NOOP)
  })
  return async next => {
    view = next
    const ui = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture',
      props: { title: 'Sessions', isFocused: next.hasKeys, bodyColumns: next.columns, placement: 'inline', scroll: { offset: 0, bodyRows: next.bodyRows }, view: {} } })
    const lines = linesOf(await ui.drawn())
    await ui.unmount()
    return lines
  }
}

function viewOf(stdout: string, over: Partial<PanelView> & { self?: string } = {}): PanelView {
  const { self, ...rest } = over
  return { rows: rowsOf(sessionsOf(stdout), self === undefined ? undefined : nameOf(self), new Map()), selected: undefined, problem: undefined, columns: 48, bodyRows: 12, hasKeys: true, ...rest }
}

test('the golden answer draws its rows under the strip, features under their base, each row exactly the body wide', async ($, on) => {
  const draw = drawer($, on)
  const lines = await draw(viewOf(GOLDEN))
  expect(lines.map(line => line.trimEnd())).toEqual([
    'm: mail alpha   Esc: close',
    '› alpha         live      41%   2 mail   1 feat',
    '  └ fix         idle      12%',
    '  └ stale       idle',
    '  beta          idle            locked',
  ])
  expect(lines.slice(1).map(line => line.length)).toEqual([48, 48, 48, 48])
  expect(await draw({ ...viewOf(GOLDEN), rows: undefined })).toEqual(['Esc: close', 'asking cs for the sessions…'])
  expect(await draw(viewOf(''))).toEqual(['Esc: close', 'no sessions under the sessions root'])
  expect(await draw({ ...viewOf(GOLDEN), problem: 'cs -list --porcelain exited 1: boom' })).toContain('cs -list --porcelain exited 1: boom')
})

test('the strip names the selected row\'s keys, widest form that fits: targets and hint, targets, verbs, then one key per line', async ($, on) => {
  const draw = drawer($, on)
  const strip = async (over: Partial<PanelView> & { self?: string }) => {
    const lines = await draw(viewOf(GOLDEN, over))
    return lines.slice(0, lines.findIndex(line => line.startsWith('› ') || line.startsWith('  ')))
  }
  const fix = nameOf('alpha@fix')
  expect(await strip({ selected: fix, columns: 72 })).toEqual(['o: open alpha@fix   m: mail alpha@fix   r: retire fix   Esc: close'])
  expect(await strip({ selected: fix, columns: 60 })).toEqual(['o: open alpha@fix   m: mail alpha@fix   r: retire fix'])
  expect(await strip({ selected: fix, columns: 48 })).toEqual(['o: open   m: mail   r: retire'])
  expect(await strip({ selected: fix, columns: 24 })).toEqual(['o: open', 'm: mail', 'r: retire'])
  expect(await strip({ selected: nameOf('beta') })).toEqual(['o: open beta   Esc: close'])
  expect(await strip({ selected: nameOf('alpha') })).toEqual(['m: mail alpha   Esc: close'])
  expect(await strip({ self: 'alpha' })).toEqual(['Esc: close'])
  expect(await strip({ selected: nameOf('beta'), hasKeys: false })).toEqual(['o: open beta   ctrl+x tab: keys'])
})

test('every row and the strip fit 24, 40 and 80 columns, long names and counts cut to their cells', async ($, on) => {
  const draw = drawer($, on)
  const wide = GOLDEN + 'a-session-whose-name-is-long@and-so-is-its-task\t0\t100\t100\t0\nzeta\t1\t7\t3\t123\n'
  for (const columns of [24, 40, 80]) {
    for (const selected of ['alpha', 'alpha@fix', 'beta', 'a-session-whose-name-is-long@and-so-is-its-task', 'zeta']) {
      const lines = await draw(viewOf(wide, { columns, selected: nameOf(selected) }))
      const rows = lines.filter(line => line.startsWith('› ') || line.startsWith('  '))
      expect(rows.map(row => row.length), `rows at ${columns} with ${selected}`).toEqual(rows.map(() => columns))
      expect(lines.filter(line => line.length > columns), `lines past ${columns} with ${selected}`).toEqual([])
    }
  }
  const at40 = await draw(viewOf(wide, { columns: 40 }))
  expect(at40.map(line => line.trimEnd())).toContain('  a-session-wh…  idle      100%  100 ma…')
})

test('a list taller than the body draws a window that keeps the selected row inside it, with a row of margin, and counts the rest', async ($, on) => {
  const draw = drawer($, on)
  const thirty = Array.from({ length: 30 }, (_, i) => `s${String(i).padStart(2, '0')}\t0\t-\t0\t0\n`).join('')
  const window = async (selected: string) => (await draw(viewOf(thirty, { columns: 40, bodyRows: 10, selected: nameOf(selected) })))
    .slice(1).map(line => line.trim().split(/\s+/)[line.startsWith('› ') ? 1 : 0])
  expect(await window('s00')).toEqual(['s00', 's01', 's02', 's03', 's04', 's05', 's06', 's07', '+22'])
  expect(await window('s06')).toEqual(['s00', 's01', 's02', 's03', 's04', 's05', 's06', 's07', '+22'])
  expect(await window('s07')).toEqual(['+4', 's04', 's05', 's06', 's07', 's08', 's09', 's10', '+19'])
  expect(await window('s15')).toEqual(['+12', 's12', 's13', 's14', 's15', 's16', 's17', 's18', '+11'])
  expect(await window('s25')).toEqual(['+22', 's22', 's23', 's24', 's25', 's26', 's27', 's28', 's29'])
  expect((await draw(viewOf(thirty, { columns: 40, bodyRows: 10 }))).length).toBe(10)
})

test('a body too short for the margin keeps the selected row, its +N lines counted in the room: none in one line, one in two', async ($, on) => {
  const draw = drawer($, on)
  const lines = async (selected: string, bodyRows: number, problem?: string) =>
    (await draw(viewOf(GOLDEN, { selected: nameOf(selected), bodyRows, problem }))).map(line => line.trimEnd())
  const fix = '› └ fix         idle      12%'
  expect(await lines('alpha@fix', 2)).toEqual(['o: open   m: mail   r: retire', fix])
  expect(await lines('alpha@fix', 3)).toEqual(['o: open   m: mail   r: retire', fix, '+2 below'])
  expect(await lines('alpha@fix', 4)).toEqual(['o: open   m: mail   r: retire', '+1 above', fix, '+2 below'])
  expect(await lines('alpha@fix', 3, 'cs -list --porcelain exited 1: boom')).toEqual(['o: open   m: mail   r: retire', 'cs -list --porcelain exited 1: boom', fix])
  expect(await lines('alpha', 3)).toEqual(['m: mail alpha   Esc: close', '› alpha         live      41%   2 mail   1 feat', '+3 below'])
  expect(await lines('beta', 3)).toEqual(['o: open beta   Esc: close', '+3 above', '› beta          idle            locked'])
})

test('a drawing that moves the Button the ring was put on sends the ring back to that key, else to the selected row; one that moves nothing sends it nowhere', () => {
  const view = (selected: string, stdout = GOLDEN, pending = new Map<SessionName, Pending>()) =>
    ({ ...viewOf(stdout, { selected: nameOf(selected) }), rows: rowsOf(sessionsOf(stdout), undefined, pending) })
  const put = (v: PanelView, key: string) => ({ key, at: ringOf(v).keys.indexOf(key) })
  // The ring put on alpha@fix holds the third place, which alpha@fix's strip
  // of three keys hands to its r.
  expect(ringOf(view('alpha'))).toEqual({ keys: ['act:mail', 'row:alpha', 'row:alpha@fix', 'row:alpha@stale', 'row:beta'], selected: 'row:alpha' })
  expect(ringOf(view('alpha@fix')).keys.slice(0, 3)).toEqual(['act:open', 'act:mail', 'act:retire'])
  expect(ringBack(put(view('alpha'), 'row:alpha@fix'), ringOf(view('alpha@fix')))).toBe('row:alpha@fix')
  expect(ringBack(put(view('alpha@fix'), 'row:alpha@fix'), ringOf(view('alpha@fix')))).toBe(undefined)
  // The ring on m; alpha@fix going live leaves m alone, first.
  const live = GOLDEN.replace('alpha@fix\t0\t12', 'alpha@fix\t1\t12')
  expect(ringBack(put(view('alpha@fix'), 'act:mail'), ringOf(view('alpha@fix', live)))).toBe('act:mail')
  // The ring on o; opening, alpha@fix offers no key: back on its row.
  const opening = new Map<SessionName, Pending>([[nameOf('alpha@fix'), 'opening']])
  expect(ringBack(put(view('alpha@fix'), 'act:open'), ringOf(view('alpha@fix', GOLDEN, opening)))).toBe('row:alpha@fix')
  // Thirty rows in twelve lines: s09 is the twelfth place under s00..s09, and
  // selected it shifts the window to s05..s13, eleven Buttons in all.
  const thirty = Array.from({ length: 30 }, (_, i) => `s${String(i).padStart(2, '0')}\t0\t-\t0\t0\n`).join('')
  expect(put(view('s08', thirty), 'row:s09').at).toBe(11)
  expect(ringOf(view('s09', thirty)).keys.length).toBe(11)
  expect(ringBack(put(view('s08', thirty), 'row:s09'), ringOf(view('s09', thirty)))).toBe('row:s09')
})

// ── The hooks, through the engine's own `$` ──────────────────────────────

const BIN = '/opt/cs/bin/cs'
const PANE_PROPS = { title: 'Sessions', isFocused: true, bodyColumns: 48, placement: 'inline', scroll: { offset: 0, bodyRows: 12 }, view: {} } as const
const COMMAND = { command: 'cs-panel', args: '', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const

type Answer = { exitCode?: number; stdout?: string; stderr?: string }

// A promise the test settles: what a held answer waits on.
function gate(): { held: Promise<void>; open: () => void } {
  let open = () => {}
  const held = new Promise<void>(resolve => { open = resolve })
  return { held, open }
}

// What sits beneath the mod: the engine's answers to each call it makes, and
// a record of what it asked. `answer` gives cs's reply to an argv; a pane is
// open from its ui.open until a ui.close. While `panesHeld` is set, ui.panes
// answers once it settles, with the panes open when it was asked. While
// `refusal` names a call, that call is refused with its text. `logs` holds
// each line a plugin logged.
function world(on: On, opts: { env?: Record<string, string>; answer?: (argv: readonly string[]) => Answer | Promise<Answer>; sessionId?: () => string; state?: string } = {}) {
  const w = { runs: [] as { argv: string[]; stdin: string | undefined }[], toasts: [] as string[], opens: [] as PaneOpenArgs[], finishes: [] as string[], isOpen: false, invalidations: 0,
    panesHeld: undefined as Promise<void> | undefined, refusal: undefined as { call: 'ui.open' | 'ui.panes' | 'ui.close'; text: string } | undefined, logs: [] as string[] }
  mock.env(on, opts.env ?? { CS_BIN: BIN })
  const clock = mock.clock(on)
  on('process.run', async ($, e) => {
    w.runs.push({ argv: [...e.argv], stdin: e.init?.stdin })
    const a: Answer = await (opts.answer ?? (argv => argv[1] === '-list' ? { stdout: GOLDEN } : {}))(e.argv)
    return { value: { exitCode: a.exitCode ?? 0, stdout: a.stdout ?? '', stderr: a.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', ($, e) => { w.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { w.logs.push(e.text); return { value: undefined } })
  on('ui.open', ($, e) => {
    if (w.refusal?.call === 'ui.open') return { deny: w.refusal.text }
    w.opens.push({ ...e }); w.isOpen = true; return { value: { isPlaced: true } }
  })
  on('ui.panes', async () => {
    if (w.refusal?.call === 'ui.panes') return { deny: w.refusal.text }
    const panes = w.isOpen ? [{ id: 'cs-panel', title: 'Sessions', isShown: true, isFocused: true, isPlaced: true }] : []
    if (w.panesHeld !== undefined) await w.panesHeld
    return { value: panes }
  })
  on('ui.close', () => {
    if (w.refusal?.call === 'ui.close') return { deny: w.refusal.text }
    w.isOpen = false; return { value: undefined }
  })
  on('ui.focus', () => ({}))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('ui.invalidate', ($, e, next) => { w.invalidations++; return next(e) })
  on('command.run', { command: 'finish' }, ($, e) => { w.finishes.push(e.args); return { text: '' } })
  on('session.cwd', () => ({ value: '/sessions/alpha' }))
  on('session.id', () => ({ value: opts.sessionId?.() ?? 'lead-id' }))
  on('fs.exists', () => ({ value: false }))
  on('fs.read', ($, e) => e.path === '/sessions/alpha/.cs/local/state' && opts.state !== undefined ? { value: opts.state } : { deny: `ENOENT: ${e.path}` })
  return { w, clock }
}

// Strips what a drawing carries per mount (press handles, the drawing plugin)
// so two drawings compare by what they show.
function shown(tree: unknown): unknown {
  if (Array.isArray(tree)) return tree.map(shown)
  if (tree === null || typeof tree !== 'object') return tree
  return Object.fromEntries(Object.entries(tree).filter(([k]) => k !== 'press' && k !== 'part').map(([k, v]) => [k, shown(v)]))
}

test('/cs-panel without CS_BIN says cs did not launch this conversation and opens nothing', async ($, on) => {
  const { w } = world(on, { env: {} })
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.noBin })
  expect(w.opens).toEqual([])
  expect(w.runs).toEqual([])
})

test('/cs-panel opens the pane asking for the keys, reads cs at once, and draws what drawPane draws for the same view', async ($, on) => {
  const { w } = world(on)
  let fixture: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => drawPane(fixture ?? viewOf(GOLDEN), $.ui.resolve(e), NOOP))
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  expect(w.opens).toEqual([{ id: 'cs-panel', title: 'Sessions', focus: true, closeOnEscape: true, columns: 56 }])
  expect(w.runs).toEqual([{ argv: [BIN, '-list', '--porcelain'], stdin: undefined }])
  const props = { ...PANE_PROPS, bodyColumns: 40, isFocused: false, scroll: { offset: 0, bodyRows: 8 } }
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props })
  fixture = { ...viewOf(GOLDEN), columns: 40, bodyRows: 8, hasKeys: false }
  const lab = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture', props })
  expect(shown(await pane.drawn())).toEqual(shown(await lab.drawn()))
  expect(linesOf(await pane.drawn()).slice(0, 2).map(line => line.trimEnd())).toEqual(['m: mail alpha   ctrl+x tab: keys', '› alpha          live      41%   2 mail'])
})

test('/cs-panel answers why when the pane does not open or its poll does not arm, and a later draw arms the poll', async ($, on) => {
  const { w, clock } = world(on)
  w.refusal = { call: 'ui.open', text: 'no room for a pane' }
  expect(await $.command.run(COMMAND)).toEqual({ text: 'The panel did not start: cs-panel: $.ui.open: no room for a pane' })
  expect(w.runs).toEqual([])
  w.refusal = { call: 'ui.panes', text: 'panes are not listed' }
  expect(await $.command.run(COMMAND)).toEqual({ text: 'The panel did not start: cs-panel: $.ui.panes: panes are not listed' })
  expect(w.runs).toEqual([])
  w.refusal = undefined
  await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  await clock.settle()
  expect(w.runs).toEqual([LIST])
})

async function openPane($: Engine) {
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  return $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
}

const LIST = { argv: [BIN, '-list', '--porcelain'], stdin: undefined }

test('the ring landing on a row selects it, and the strip names that row; a ring on a strip key keeps the selection', async ($, on) => {
  world(on)
  const pane = await openPane($)
  expect(linesOf(await pane.drawn())[0]).toBe('m: mail alpha   Esc: close')
  await $.ui.focus({ component: 'Pane', requestId: 'cs-panel', plugin: 'cs-panel', element: 'row:beta', origin: { kind: 'person' } })
  expect(linesOf(await pane.drawn())[0]).toBe('o: open beta   Esc: close')
  await $.ui.focus({ component: 'Pane', requestId: 'cs-panel', plugin: 'cs-panel', element: 'act:open', origin: { kind: 'person' } })
  expect(linesOf(await pane.drawn())[0]).toBe('o: open beta   Esc: close')
  await pane.press({ key: 'row:alpha@fix' })
  expect(linesOf(await pane.drawn())[0]).toBe('o: open   m: mail   r: retire')
})

// The kit has no core behind a plugin's $.ui.focus: the mod's ask reaches no
// hook and is refused, and the pane logs the refusal, so the refusals count
// the asks. The test lands the ring as the engine would, by raising the move.
test('the pane asks to put the ring back once for a drawing that moved its Button, and not again once it landed', async ($, on) => {
  const { w, clock } = world(on)
  const pane = await openPane($)
  await clock.settle()
  const asks = () => w.logs.filter(line => line === LOGS.failed('no implementation for ui.focus')).length
  const move = (element: string, origin: { kind: 'person' } | { kind: 'plugin'; name: string }) =>
    $.ui.focus({ component: 'Pane', requestId: 'cs-panel', plugin: 'cs-panel', element, origin })
  await move('row:alpha@fix', { kind: 'person' })
  await pane.drawn()
  await clock.settle()
  expect(asks()).toBe(1)
  await move('row:alpha@fix', { kind: 'plugin', name: 'cs-panel' })
  await pane.redraw()
  await clock.settle()
  expect([asks(), linesOf(await pane.drawn())[0]]).toEqual([1, 'o: open   m: mail   r: retire'])
})

test('o spawns the selected idle session and toasts cs\'s own line, or why it did not open; the list is read again after', async ($, on) => {
  let spawn: Answer = { stdout: 'spawned beta in tmux session cs (window @7). Attach: tmux attach -t cs\n' }
  const { w } = world(on, { answer: argv => argv[1] === '-list' ? { stdout: GOLDEN } : spawn })
  const pane = await openPane($)
  await pane.press({ key: 'row:beta' })
  await pane.press({ key: 'act:open' })
  expect(w.runs).toEqual([LIST, { argv: [BIN, '-spawn', 'beta'], stdin: undefined }, LIST])
  expect(w.toasts).toEqual(['spawned beta in tmux session cs (window @7). Attach: tmux attach -t cs'])
  spawn = { exitCode: 1, stderr: 'Error: Session beta is already live\n' }
  await pane.press({ key: 'act:open' })
  expect(w.toasts.at(-1)).toBe('beta did not open: exited 1: Error: Session beta is already live')
})

test('a key pressed on a row that no longer offers it says so and runs nothing: a second o while the first spawn runs', async ($, on) => {
  const spawned = gate()
  const { w, clock } = world(on, { answer: async argv => {
    if (argv[1] === '-list') return { stdout: GOLDEN }
    await spawned.held
    return { stdout: 'spawned beta in tmux session cs (window @7). Attach: tmux attach -t cs\n' }
  } })
  const pane = await openPane($)
  await pane.press({ key: 'row:beta' })
  const first = pane.press({ key: 'act:open' })
  const second = pane.press({ key: 'act:open' })
  await clock.settle()
  expect(w.toasts).toEqual(['open beta is not offered now'])
  spawned.open()
  await Promise.all([first, second])
  await clock.settle()
  expect(w.runs).toEqual([LIST, { argv: [BIN, '-spawn', 'beta'], stdin: undefined }, LIST])
  expect(w.toasts).toEqual(['open beta is not offered now', 'spawned beta in tmux session cs (window @7). Attach: tmux attach -t cs'])
})

test('m asks for a body and sends it on stdin to cs <name> -msg -; Cancel, a dismissed dialog and an empty body send nothing', async ($, on) => {
  let reply: (question: string) => { result: unknown } | { deny: string } = () => ({ deny: 'dismissed' })
  const asked: unknown[] = []
  const { w } = world(on, { answer: argv => argv[1] === '-list' ? { stdout: GOLDEN } : argv[2] === '-msg' && w.toasts.length === 2 ? { exitCode: 1, stderr: 'Error: no such session\n' } : {} })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => { asked.push(e.questions); return reply(e.questions[0]?.question ?? '') as never })
  const pane = await openPane($)
  const answer = (text: string) => { reply = question => ({ result: { questions: [], answers: { [question]: text } } }) }
  answer('ship it')
  await pane.press({ key: 'act:mail' })
  expect(asked[0]).toEqual([{ question: 'What should alpha read? Type it under Other.', header: 'Mail', multiSelect: false,
    options: [{ label: 'Ask for a status line', description: '' }, { label: 'Cancel', description: '' }] }])
  answer('Ask for a status line')
  await pane.press({ key: 'act:mail' })
  expect(STATUS_BODY).toBe('What are you on right now, and is anything blocked?')
  for (const nothing of ['Cancel', '   ']) { answer(nothing); await pane.press({ key: 'act:mail' }) }
  reply = () => ({ deny: 'dismissed' })
  await pane.press({ key: 'act:mail' })
  expect(w.runs.filter(r => r.argv[2] === '-msg')).toEqual([
    { argv: [BIN, 'alpha', '-msg', '-'], stdin: 'ship it' },
    { argv: [BIN, 'alpha', '-msg', '-'], stdin: STATUS_BODY },
  ])
  expect(w.toasts).toEqual(['mail sent to alpha', 'mail sent to alpha'])
  answer('again')
  await pane.press({ key: 'act:mail' })
  expect(w.toasts.at(-1)).toBe('mail to alpha not sent: exited 1: Error: no such session')
})

test('r from another session checks readiness, then mails the base /finish <task> as a task; what stops the merge is toasted instead', async ($, on) => {
  let features: Answer = { stdout: `${readinessLine({ ahead: 2, lock: 'base', state: 'locked' })}\n` }
  let msg: Answer = {}
  const { w } = world(on, { answer: argv => argv[1] === '-list' ? { stdout: GOLDEN } : argv[2] === '-features' ? features : msg })
  const pane = await openPane($)
  await pane.press({ key: 'row:alpha@fix' })
  await pane.press({ key: 'act:retire' })
  expect(w.runs).toEqual([LIST, { argv: [BIN, 'alpha', '-features', '--porcelain'], stdin: undefined },
    { argv: [BIN, 'alpha', '-msg', '--kind', 'task', '-'], stdin: '/finish fix' }, LIST])
  expect(w.toasts).toEqual(['asked alpha to /finish fix; it runs once alpha accepts the task'])
  features = { stdout: `${readinessLine({ ahead: 2, wtDirty: 1, lock: 'base', state: 'locked' })}\n` }
  await pane.press({ key: 'act:retire' })
  features = { exitCode: 1, stderr: 'Error: Session not found: alpha\n' }
  await pane.press({ key: 'act:retire' })
  features = { stdout: `${readinessLine({ ahead: 2, state: 'ready' })}\n` }
  msg = { exitCode: 1, stderr: 'Error: alpha\'s vault is locked\n' }
  await pane.press({ key: 'act:retire' })
  await pane.press({ key: 'row:alpha@stale' })
  await pane.press({ key: 'act:retire' })
  expect(w.toasts.slice(1)).toEqual(['fix not retired: dirty', 'fix not retired: exited 1: Error: Session not found: alpha',
    'alpha was not asked to retire: exited 1: Error: alpha\'s vault is locked', 'stale not retired: not a feature git lists'])
  expect(w.runs.filter(r => r.argv[2] === '-msg')).toHaveLength(2)
})

test('r in the base\'s lead conversation runs /finish <task> here; in a teammate of the base it is refused before cs is asked', async ($, on) => {
  const lead = { env: { CS_BIN: BIN, CLAUDE_SESSION_NAME: 'alpha' }, state: 'session_name: alpha\nclaude_session_id: "lead-id"\n',
    answer: (argv: readonly string[]) => argv[1] === '-list' ? { stdout: GOLDEN } : { stdout: `${readinessLine({ ahead: 2, state: 'ready' })}\n` } }
  let sessionId = 'lead-id'
  const { w } = world(on, { ...lead, sessionId: () => sessionId })
  const pane = await openPane($)
  await pane.press({ key: 'row:alpha@fix' })
  await pane.press({ key: 'act:retire' })
  expect(w.finishes).toEqual(['fix'])
  expect(w.runs.filter(r => r.argv[2] === '-msg')).toEqual([])
  expect(w.toasts).toEqual([])
  sessionId = 'mate-id'
  const asked = w.runs.length
  await pane.press({ key: 'act:retire' })
  expect(w.toasts).toEqual(["alpha's features retire from its lead conversation; this one is a teammate"])
  expect(w.runs.slice(asked).map(r => r.argv[1])).toEqual(['-list'])
  expect(w.finishes).toEqual(['fix'])
})

const TURN = { text: '', turnId: 't1' }
const DONE = { answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as const

// The kit raises no person's close; a plugin's close of the id is the same
// ui.close the mod hooks (its origin aside, which the mod does not read). The
// command answers the refusal when the close is refused.
const CLOSER = { name: 'closer', register(on: On) {
  on('command.run', { command: 'close-panel' }, async $ => $.ui.close({ id: 'cs-panel' })
    .then(() => ({ text: '' }), (err: unknown) => ({ text: err instanceof Error ? err.message : String(err) })))
} }

test('an open pane reads cs every minute while no turn runs and at each turn\'s end; a subagent\'s turns change nothing; a refused close keeps the reads, a close stops them', { plugins: [CLOSER] }, async ($, on) => {
  const { w, clock } = world(on)
  const lists = () => w.runs.filter(r => r.argv[1] === '-list').length
  const pane = await openPane($)
  expect(lists()).toBe(1)
  await clock.advance(60000)
  expect(lists()).toBe(2)
  const drawn = w.invalidations
  expect(drawn).toBeGreaterThan(0)
  await clock.advance(60000)
  expect([lists(), w.invalidations]).toEqual([3, drawn])
  await $.turn.start(TURN)
  await $.turn.complete({ ...DONE, agentId: 'a1' })
  await clock.advance(120000)
  expect(lists()).toBe(3)
  await $.turn.start({ ...TURN, agentId: 'a1' })
  await $.turn.complete(DONE)
  await clock.settle()
  expect(lists()).toBe(4)
  w.refusal = { call: 'ui.close', text: 'kept open' }
  expect(await $.command.run({ ...COMMAND, command: 'close-panel' })).toEqual({ text: 'closer: $.ui.close: kept open' })
  expect(w.isOpen).toBe(true)
  await clock.advance(60000)
  expect(lists()).toBe(5)
  w.refusal = undefined
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  expect(w.isOpen).toBe(false)
  await clock.advance(180000)
  expect(lists()).toBe(5)
  await pane.redraw()
  await clock.settle()
  expect(lists()).toBe(5)
  w.isOpen = true
  await pane.redraw()
  await clock.settle()
  expect(lists()).toBe(6)
  await clock.advance(60000)
  expect(lists()).toBe(7)
})

// Logs each clock.every dispatch the plugins make: one when a timer is armed,
// then one per period it runs. A plugin's hooks run from their own source,
// sharing no binding with the test, so the count comes back through ui.log.
const EVERIES = { name: 'everies', register(on: On) {
  on('clock.every', async ($, e, next) => { await $.ui.log('clock.every'); return next(e) })
} }

test('a render\'s arming and /cs-panel\'s at once arm one clock: one read at the open and one a minute, none after a close', { plugins: [CLOSER, EVERIES] }, async ($, on) => {
  const { w, clock } = world(on)
  const everies = () => w.logs.filter(line => line === 'clock.every').length
  const lists = () => w.runs.filter(r => r.argv[1] === '-list').length
  const panes = gate()
  w.panesHeld = panes.held
  // The engine draws an opening pane before $.ui.open resolves: that render
  // arms the poll from a timer, whose arming is still asking for the panes
  // when /cs-panel arms its own.
  w.isOpen = true
  await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  await clock.settle()
  const opening = $.command.run(COMMAND)
  await clock.settle()
  w.panesHeld = undefined
  panes.open()
  expect(await opening).toEqual({ text: REPLIES.opened })
  await clock.settle()
  expect([everies(), lists()]).toEqual([1, 1])
  await clock.advance(60000)
  expect(lists()).toBe(2)
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  await clock.advance(180000)
  expect(lists()).toBe(2)
})

test('a close while the poll is being armed leaves no clock, even when a render after the close starts arming again', { plugins: [CLOSER, EVERIES] }, async ($, on) => {
  const { w, clock } = world(on)
  const everies = () => w.logs.filter(line => line === 'clock.every').length
  const lists = () => w.runs.filter(r => r.argv[1] === '-list').length
  const panes = gate()
  w.panesHeld = panes.held
  const opening = $.command.run(COMMAND)
  await clock.settle()
  await $.command.run({ ...COMMAND, command: 'close-panel' })
  expect(w.isOpen).toBe(false)
  await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  await clock.settle()
  w.panesHeld = undefined
  panes.open()
  expect(await opening).toEqual({ text: REPLIES.opened })
  await clock.advance(180000)
  expect([everies(), lists()]).toEqual([0, 0])
})

test('a failed or unreadable answer keeps the rows and draws why above them; the next good answer clears it', async ($, on) => {
  let list: Answer = { stdout: GOLDEN }
  const { clock } = world(on, { answer: () => list })
  const pane = await openPane($)
  const read = async (next: Answer) => { list = next; await $.turn.complete(DONE); await clock.settle(); return (await linesOf(await pane.drawn())).map(line => line.trimEnd()) }
  expect(await read({ exitCode: 1, stderr: 'warming up\nError: boom\n' })).toEqual(['m: mail alpha   Esc: close', 'cs -list --porcelain exited 1: Error: boom',
    '› alpha         live      41%   2 mail   1 feat', '  └ fix         idle      12%', '  └ stale       idle', '  beta          idle            locked'])
  expect((await read({ stdout: 'oops\n' }))[1]).toBe('cs -list --porcelain gave a line the panel cannot read: oops')
  expect((await read({ stdout: GOLDEN }))[1]).toBe('› alpha         live      41%   2 mail   1 feat')
})

test('a read asked for while one runs runs once more after it, never twice, so the newest answer is the one drawn', async ($, on) => {
  let release: (() => void) | undefined
  let list: Answer = { stdout: GOLDEN }
  const { w, clock } = world(on, { answer: async () => {
    if (release !== undefined) return list
    await new Promise<void>(resolve => { release = resolve })
    return list
  } })
  const lists = () => w.runs.filter(r => r.argv[1] === '-list').length
  const opening = $.command.run(COMMAND)
  await clock.settle()
  expect(lists()).toBe(1)
  await $.turn.complete(DONE)
  await $.turn.complete(DONE)
  list = { stdout: 'beta\t0\t-\t-\t0\n' }
  release?.()
  expect(await opening).toEqual({ text: REPLIES.opened })
  await clock.settle()
  expect(lists()).toBe(2)
  const pane = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
  expect(linesOf(await pane.drawn()).map(line => line.trimEnd())).toEqual(['o: open beta   Esc: close', '› beta          idle            locked'])
})

test('the session start registers /cs-panel once, to run mid-turn too, and opens nothing', async ($, on) => {
  const { w } = world(on)
  const specs: unknown[] = []
  on('command.register', ($, e) => { specs.push({ ...e }); return { value: { command: e.name } } })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/sessions/alpha', surface: 'terminal', isInteractive: true })
  await $.session.start({ cwd: '/sessions/alpha', surface: 'terminal', isInteractive: true })
  expect(specs).toEqual([{ name: 'cs-panel', description: 'The cs sessions: live or idle, context, unread mail, features; open, mail or retire one.', immediate: true }])
  expect(w.opens).toEqual([])
})

test('the pane draws on every surface', async ($, on) => {
  world(on)
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const pane = await $.ui.mount({ plugin: 'cs-panel', surface, component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
    expect((await pane.find({ key: 'row:alpha@fix' }))?.props.label, surface).toBe('alpha@fix')
    expect((await pane.find({ key: 'act:mail' }))?.props.hotkey, surface).toBe('m')
    await pane.unmount()
  }
})

test('no line the mod hands the engine names the plugin first: the engine prefixes it', () => {
  const lines = [
    COMMANDS['cs-panel'].description, ...Object.values(REPLIES).map(r => typeof r === 'string' ? r : r('x')),
    ...Object.values(TOASTS).map(t => t('x', 'y')), ...Object.values(PROBLEMS).map(p => p('x')), ...Object.values(LOGS).map(l => l('x')), ASKS.mail('x').question,
  ]
  expect(lines.length).toBe(19)
  expect(lines.filter(line => line.toLowerCase().startsWith('cs-panel'))).toEqual([])
})
