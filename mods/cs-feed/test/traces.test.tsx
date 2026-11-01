// ABOUTME: Walks the design's traces and refusal paths end to end through the engine test kit: flips both ways, a planted refused on, vet answers.
// ABOUTME: Test hooks stand in for the session's files, cs and the engine's own drawing beneath the feed.
import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const RUN = { origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const feed = (args: string) => ({ command: 'feed', args, ...RUN })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']
const FEED = '/session/.cs/local/feed'
const ON = "feed on: your messages and Claude's replies only"
const OFF = "feed off: Claude Code's own drawing"
/** The row cs's band draws in, which the feed leaves to cs. */
const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } as const

type Files = Map<string, string>
function filesOn(on: On, files: Files) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const text = files.get(e.path); return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text } })
  on('fs.exists', ($, e) => ({ value: e.path === '/session/.cs/local' }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
  on('config.list', () => ({ value: [] }))
}

for (const [name, answer, refusal] of [
  ['exits 1 with a stderr line', { value: { ...PASSED, exitCode: 1, stderr: 'warming up\n.cs/local is tracked by git\n' } }, '.cs/local is tracked by git'],
  ['exits 1 with no stderr', { value: { ...PASSED, exitCode: 1 } }, 'cs -vet-session exited 1'],
] as const) test(`a feed write refused by a cs that ${name} writes nothing and says cs's reason`, async ($, on) => {
  const files: Files = new Map([[FEED, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return answer })
  expect(await $.command.run(feed('on'))).toEqual({ text: `no feed change in this session: ${refusal}` })
  expect([...files]).toEqual([[FEED, 'off\n']])
  expect(runs).toEqual([VET])
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET])
})

test('a feed write whose vet cannot run writes nothing and says why', async ($, on) => {
  const files: Files = new Map([[FEED, 'off\n']])
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ deny: 'spawn /bin/cs ENOENT' }))
  expect(await $.command.run(feed('on'))).toEqual({ text: 'no feed change in this session: cs -vet-session did not run: cs-feed: $.process.run: spawn /bin/cs ENOENT' })
  expect([...files]).toEqual([[FEED, 'off\n']])
})

test('feed status and an unknown word run no process while the file is off', async ($, on) => {
  const files: Files = new Map([[FEED, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  expect(await $.command.run(feed('close'))).toEqual({ text: '/feed toggles the feed · /feed on | off | status' })
  expect(runs).toEqual([])
  expect([...files]).toEqual([[FEED, 'off\n']])
})

test('bare feed flips the file it reads: no file is on, so it writes off, then on', async ($, on) => {
  const files: Files = new Map()
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(feed(''))).toEqual({ text: OFF })
  expect(files.get(FEED)).toBe('off\n')
  expect(await $.command.run(feed(''))).toEqual({ text: ON })
  expect(files.get(FEED)).toBe('on\n')
  expect(await $.command.run(feed('status'))).toEqual({ text: 'on' })
  expect(runs).toEqual([VET, VET, VET])
})

test('an on file vetted at the load draws the feed after one process with cs\'s exact argv', async ($, on) => {
  const files: Files = new Map([[FEED, 'on\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs }); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const one = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'Done.', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'Done.', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect((await two.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  expect(await $.command.run(feed('status'))).toEqual({ text: 'on' })
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  await one.unmount()
  await two.unmount()
})

test('a refusal the read side already logged is not logged again when an outside on is vetted again', async ($, on) => {
  const files: Files = new Map([[FEED, 'on\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: 'not this session\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  files.set(FEED, 'off\n')
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  files.set(FEED, 'on\n')
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET, VET])
  expect(logs).toEqual(['the feed is off in this session: not this session'])
})

for (const planted of ['on\n', undefined]) test(`trace 7: ${planted === undefined ? 'no file' : 'a planted on'} in a session cs refuses draws nothing, logs once, and a press, feed off and feed status add no log`, {
  plugins: [{ name: 'cs', register(on) {
    // cs's band refuses this session too: its press vets, is refused, and writes nothing.
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-feed', label: 'feed', onPress: async () => {} }))
  } }],
}, async ($, on) => {
  const files: Files = new Map(planted === undefined ? [] : [[FEED, planted]])
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
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(logs).toEqual(['the feed is off in this session: .cs/local is tracked by git'])
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(await $.command.run(feed('off'))).toEqual({ text: 'no feed change in this session: .cs/local is tracked by git' })
  expect(await $.command.run(feed('status'))).toEqual({ text: 'off' })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(files.get(FEED)).toBe(planted)
  expect(logs).toEqual(['the feed is off in this session: .cs/local is tracked by git'])
  expect(runs).toEqual([VET, VET])
  expect(redraws).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('trace 1 both ways: the band key turns the feed on, then off, and the rows follow', {
  plugins: [{ name: 'cs', register(on) {
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-feed', label: 'feed', onPress: async () => {
      const now = await $.fs.read('/session/.cs/local/feed')
      await $.fs.write('/session/.cs/local/feed', now === 'on\n' ? 'off\n' : 'on\n')
    } }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([[FEED, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(files.get(FEED)).toBe('on\n')
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine markdown'))).toBe(true)
  await $.ui.press({ plugin: 'cs', key: 'cs-feed' })
  expect(files.get(FEED)).toBe('off\n')
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(runs).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('traces 2 and 3: a typed flip mid-call passes the running call\'s row through, and back on hides it again', async ($, on) => {
  const files: Files = new Map([[FEED, 'on\n']])
  const writes: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine call' }))
  const call = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', props: { tool_use_id: 'slow', tool: 'Bash', input: { command: 'python3 slow.py' }, isRunning: true, isErrored: false, isInterrupted: false, output: undefined } })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(await $.command.run(feed('off'))).toEqual({ text: OFF })
  expect((await call.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine call'])
  expect(await $.command.run(feed('on'))).toEqual({ text: ON })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(writes).toEqual([])
  await call.unmount()
})
