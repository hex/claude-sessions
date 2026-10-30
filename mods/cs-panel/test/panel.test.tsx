// ABOUTME: Engine test-kit tests for the cs-panel mod: the porcelain parser, the rows and their keys, the fitted drawing, and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from porcelain.md, the golden file (test/golden.ts) and the design's rules, never from the code under test.
import { expect, test } from 'claude-code/testing'

import { GOLDEN } from './golden'
import { parseList, rowsOf, sessionName, type Pending, type Row, type Session, type SessionName } from '../hooks/sessions'

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
