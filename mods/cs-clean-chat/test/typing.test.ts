// ABOUTME: Exercises the typing clock across a turn with the kit's held clock: it bumps the typing counter each period while the main turn is open and clean chat is on, and stops at the turn's end or a switch off with no further write.
// ABOUTME: Recording hooks capture the state writes and the waits; an agent's run never starts it.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

/** A cs session whose clean chat file says `file`; `writes` and `waits` record the clock's work. */
function session(on: On, file: () => string, writes: unknown[], waits: number[]) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/clean-chat') ? { value: file() } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('config.list', () => ({ value: [] }))
  on('state.set', async ($, e, next) => { writes.push([e.key, e.value]); return next(e) })
  on('clock.after', { ms: 400 }, async ($, e, next) => { waits.push(e.ms); return next(e) })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('ui.render', { component: 'Spinner' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.word }))
  return mock.clock(on)
}

const SPINNER = { word: 'Sauteing', message: null, suffix: '…', mode: 'tool-use' } as const

test('the typing counter climbs one per 400 ms while the main turn is open, and the turn\'s end stops it at the next period with no write', async ($, on) => {
  const writes: unknown[] = []
  const waits: number[] = []
  const clock = session(on, () => 'on\n', writes, waits)
  await $.turn.start({ text: 'Work', turnId: 'turn' })
  const line = await $.ui.mount({ plugin: 'cs-clean-chat', surface: 'terminal', component: 'Spinner', props: SPINNER })
  expect((await line.find({ type: 'Text' }))?.text).toBe('·')
  await clock.advance(400)
  expect(writes).toEqual([['typing', 1]])
  expect((await line.find({ type: 'Text' }))?.text).toBe('· ·')
  await clock.advance(800)
  expect(writes).toEqual([['typing', 1], ['typing', 2], ['typing', 3]])
  expect((await line.find({ type: 'Text' }))?.text).toBe('·')
  await $.turn.complete({ answer: 'Done.', durationMs: 1, isAborted: false, turnId: 'turn', reason: 'answer' })
  await clock.advance(2000)
  expect(writes).toEqual([['typing', 1], ['typing', 2], ['typing', 3]])
  expect(waits).toEqual([400, 400, 400, 400])
  await line.unmount()
})

test('an agent\'s run never starts the clock, and a session switched off gets no bump', async ($, on) => {
  const writes: unknown[] = []
  const waits: number[] = []
  let file = 'off\n'
  const clock = session(on, () => file, writes, waits)
  await $.turn.start({ text: 'Work', turnId: 'agent-turn', agentId: 'helper' })
  await clock.advance(1000)
  expect(waits).toEqual([])
  await $.turn.start({ text: 'Work', turnId: 'turn' })
  const line = await $.ui.mount({ plugin: 'cs-clean-chat', surface: 'terminal', component: 'Spinner', props: SPINNER })
  expect((await line.find({ type: 'Text' }))?.text).toBe('Sauteing')
  await clock.advance(1000)
  expect(writes).toEqual([])
  expect(waits).toEqual([])
  await line.unmount()
  file = 'on\n'
})
