// ABOUTME: Walks the design's traces and refusal paths end to end through the engine test kit: flips both ways, a planted refused on, vet answers, refresh coalescing.
// ABOUTME: Test hooks stand in for the session's files, cs, the clock and the engine's own drawing beneath the feed.
import { expect, mock, test } from 'claude-code/testing'
import type { On, SessionMessage } from 'claude-code'

const RUN = { origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const feed = (args: string) => ({ command: 'feed', args, ...RUN })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']

type Files = Map<string, string>
function filesOn(on: On, files: Files) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const text = files.get(e.path); return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text } })
  on('fs.exists', ($, e) => ({ value: e.path === '/session/.cs/local' }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
}

for (const [name, answer, refusal] of [
  ['exits 1 with a stderr line', { value: { ...PASSED, exitCode: 1, stderr: 'warming up\n.cs/local is tracked by git\n' } }, '.cs/local is tracked by git'],
  ['exits 1 with no stderr', { value: { ...PASSED, exitCode: 1 } }, 'cs -vet-session exited 1'],
] as const) test(`a feed write refused by a cs that ${name} writes nothing and says cs's reason`, async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return answer })
  expect(await $.command.run(feed('clean'))).toEqual({ text: `no feed change in this session: ${refusal}` })
  expect([...files]).toEqual([['/session/.cs/local/feed', 'off\n']])
  expect(runs).toEqual([VET])
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  expect(runs).toEqual([VET])
})

test('a feed write whose vet cannot run writes nothing and says why', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'off\n']])
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ deny: 'spawn /bin/cs ENOENT' }))
  expect(await $.command.run(feed('on'))).toEqual({ text: 'no feed change in this session: cs -vet-session did not run: cs-feed: $.process.run: spawn /bin/cs ENOENT' })
  expect([...files]).toEqual([['/session/.cs/local/feed', 'off\n']])
})

test('bare feed, feed close and feed status run no process while the file is off', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  const panes: string[] = []
  on('ui.open', ($, e) => { panes.push(`open ${e.id}`); return { value: { isPlaced: true } } })
  on('ui.close', ($, e) => { panes.push(`close ${e.id}`); return { value: undefined } })
  expect(await $.command.run(feed(''))).toEqual({ text: 'Chat view: raw. Settings are open above the prompt; /feed close shuts them.' })
  expect(await $.command.run(feed('close'))).toEqual({ text: 'Chat view settings closed.' })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  expect(panes).toEqual(['open cs-feed', 'close cs-feed'])
  expect(runs).toEqual([])
})

test('an on file vetted at the load draws the feed after one process with cs\'s exact argv', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs }); return { value: PASSED } })
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  mock.clock(on)
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const one = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'Done.', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'Done.', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect((await two.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  expect(await $.command.run(feed('status'))).toEqual({ text: 'on · clean' })
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  await one.unmount()
  await two.unmount()
})

test('a refusal the read side already logged is not logged again when an outside on is vetted again', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: 'not this session\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  files.set('/session/.cs/local/feed', 'off\n')
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  files.set('/session/.cs/local/feed', 'on\n')
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  expect(runs).toEqual([VET, VET])
  expect(logs).toEqual(['the feed is off in this session: not this session'])
})

test('trace 7: a planted on in a session cs refuses draws nothing, logs once, and a press, feed off and feed status add no log', {
  plugins: [{ name: 'cs', register(on) {
    // cs's band refuses this session too: its press vets, is refused, and writes nothing.
    on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-feed', label: 'feed', onPress: async () => {} }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  const redraws: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: '.cs/local is tracked by git\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(logs).toEqual(['the feed is off in this session: .cs/local is tracked by git'])
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(await $.command.run(feed('off'))).toEqual({ text: 'no feed change in this session: .cs/local is tracked by git' })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off · raw' })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(files.get('/session/.cs/local/feed')).toBe('on\n')
  expect(logs).toEqual(['the feed is off in this session: .cs/local is tracked by git'])
  expect(runs).toEqual([VET, VET])
  expect(redraws).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('trace 1 both ways: the band key turns the feed on, then off, and the rows follow', {
  plugins: [{ name: 'cs', register(on) {
    on('ui.render', { component: 'ToolProgress' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-feed', label: 'feed', onPress: async () => {
      const now = await $.fs.read('/session/.cs/local/feed')
      await $.fs.write('/session/.cs/local/feed', now === 'on\n' ? 'off\n' : 'on\n')
    } }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  mock.clock(on)
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b' } })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(files.get('/session/.cs/local/feed')).toBe('on\n')
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine markdown'))).toBe(true)
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(files.get('/session/.cs/local/feed')).toBe('off\n')
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(runs).toEqual([])
  await reply.unmount()
  await band.unmount()
})

const RUNNING: SessionMessage[] = [
  { role: 'user', text: 'Run the tests', toolUses: [] },
  { role: 'assistant', text: '', toolUses: [{ tool_use_id: 'slow', tool: 'Bash', input: { command: 'python3 slow.py' } }] },
]

test('traces 2 and 3: a typed flip mid-call passes every row through with no token write, and back on draws them again', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  const writes: string[] = []
  const spinner: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : RUNNING }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  const clock = mock.clock(on)
  on('ui.render', { component: 'Spinner' }, ($, e) => { spinner.push([e.props.message, e.props.suffix]); return $.ui.resolve(e).Text({ children: e.props.message ?? 'engine words' }) })
  await $.turn.start({ text: 'Run the tests', turnId: 'turn' })
  const line = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Spinner', props: { word: 'Running', message: null, suffix: '…', mode: 'tool-use' } })
  await clock.settle()
  expect(spinner.at(-1)).toEqual(['Running a shell command · step 1', ''])
  expect(await $.command.run(feed('off'))).toEqual({ text: 'Chat view: off.' })
  writes.length = 0
  await clock.advance(5000)
  expect(spinner.at(-1)).toEqual([null, '…'])
  expect(writes).toEqual([])
  expect(await $.command.run(feed('on'))).toEqual({ text: 'Chat view: on.' })
  await clock.settle()
  expect(spinner.at(-1)).toEqual(['Running a shell command · step 1', ''])
  await line.unmount()
})

for (const dirties of [1, 3]) test(`${dirties} dirty ${dirties === 1 ? 'call' : 'calls'} during a refresh in flight cost exactly one more read`, async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  let reads = 0
  let hold = false
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('session.messages', async ($, e) => {
    if (e.as === 'api') return { value: [] }
    reads++
    if (hold) { hold = false; entered?.(); await held }
    return { value: [] }
  })
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  const clock = mock.clock(on)
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  await clock.settle()
  expect(reads).toBe(1)
  hold = true
  const reply = (uuid: string) => $.session.append({ door: 'response', origin: { kind: 'model', model: 'model' }, uuid, message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: uuid }] } })
  await reply('first')
  const settling = clock.settle()
  await started
  for (let n = 0; n < dirties; n++) await reply(`during-${n}`)
  release?.()
  await settling
  await clock.settle()
  expect(reads).toBe(3)
  await row.unmount()
})

test('the turn timing row draws nothing, the progress hint is blanked, and the engine\'s own working words keep their suffix', async ($, on) => {
  const files: Files = new Map([['/session/.cs/local/feed', 'on\n']])
  const seen: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  mock.clock(on)
  on('ui.render', { component: 'TurnDuration' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine duration' }))
  on('ui.render', { component: 'ToolProgress' }, ($, e) => { seen.push(['hint', e.props.hint]); return $.ui.resolve(e).Text({ children: 'engine progress' }) })
  on('ui.render', { component: 'Spinner' }, ($, e) => { seen.push([e.props.message, e.props.suffix]); return $.ui.resolve(e).Text({ children: 'engine spinner' }) })
  const duration = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'TurnDuration', props: { word: 'Worked', durationMs: 4000 } })
  const progress = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'call', kind: 'background_hint', hint: 'ctrl+b to run in background' } })
  const compacting = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Spinner', props: { word: 'Compacting', message: 'Compacting conversation', suffix: '…', mode: 'thinking' } })
  expect(await duration.findAll({ type: 'Text' })).toEqual([])
  expect(seen).toEqual([['hint', ''], ['Compacting conversation', '…']])
  await duration.unmount()
  await progress.unmount()
  await compacting.unmount()
})
