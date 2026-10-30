// ABOUTME: Engine test-kit tests for the cs-panel mod: the porcelain parser, the rows and their keys, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from porcelain.md, the golden file (test/golden.ts) and the design's rules, never from the code under test.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { GOLDEN } from './golden'
import { drawPane, type PanelView } from '../hooks/draw'
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
