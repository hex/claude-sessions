// ABOUTME: Engine test-kit tests for the cs-panel mod: the porcelain parser, the rows and their keys, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from porcelain.md, the golden file (test/golden.ts) and the design's rules, never from the code under test.
import { expect, test } from 'claude-code/testing'

import { GOLDEN } from './golden'
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
