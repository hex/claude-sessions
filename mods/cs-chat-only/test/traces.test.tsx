// ABOUTME: Walks the design's traces and refusal paths end to end through the engine test kit: flips both ways, a planted refused on, vet answers.
// ABOUTME: Test hooks stand in for the session's files, cs and the engine's own drawing beneath chat only.
import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const RUN = { origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const chatOnly = (args: string) => ({ command: 'chat-only', args, ...RUN })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']
const CHAT_ONLY = '/session/.cs/local/chat-only'
const ON = "chat only on: your messages and Claude's replies only"
const OFF = "chat only off: Claude Code's own drawing"
/** The row cs's band draws in, which chat only leaves to cs. */
const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } as const

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
] as const) test(`a chat only write refused by a cs that ${name} writes nothing and says cs's reason`, async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return answer })
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: `no chat only change in this session: ${refusal}` })
  expect([...files]).toEqual([[CHAT_ONLY, 'off\n']])
  expect(runs).toEqual([VET])
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET])
})

test('a chat only write whose vet cannot run writes nothing and says why', async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'off\n']])
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ deny: 'spawn /bin/cs ENOENT' }))
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: 'no chat only change in this session: cs -vet-session did not run: cs-chat-only: $.process.run: spawn /bin/cs ENOENT' })
  expect([...files]).toEqual([[CHAT_ONLY, 'off\n']])
})

test('chat-only status and an unknown word run no process while the file is off', async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  expect(await $.command.run(chatOnly('close'))).toEqual({ text: '/chat-only toggles chat only · /chat-only on | off | status' })
  expect(runs).toEqual([])
  expect([...files]).toEqual([[CHAT_ONLY, 'off\n']])
})

test('bare chat-only flips the file it reads: no file is on, so it writes off, then on', async ($, on) => {
  const files: Files = new Map()
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(chatOnly(''))).toEqual({ text: OFF })
  expect(files.get(CHAT_ONLY)).toBe('off\n')
  expect(await $.command.run(chatOnly(''))).toEqual({ text: ON })
  expect(files.get(CHAT_ONLY)).toBe('on\n')
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'on' })
  expect(runs).toEqual([VET, VET, VET])
})

test('an on file vetted at the load draws chat only after one process with cs\'s exact argv', async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'on\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs }); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const one = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'Done.', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'Done.', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect((await two.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'on' })
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  await one.unmount()
  await two.unmount()
})

test('a refusal the read side already logged is not logged again when an outside on is vetted again', async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'on\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: 'not this session\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  files.set(CHAT_ONLY, 'off\n')
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  files.set(CHAT_ONLY, 'on\n')
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET, VET])
  expect(logs).toEqual(['chat only is off in this session: not this session'])
})

for (const planted of ['on\n', undefined]) test(`trace 7: ${planted === undefined ? 'no file' : 'a planted on'} in a session cs refuses draws nothing, logs once, and a press, chat-only off and chat-only status add no log`, {
  plugins: [{ name: 'cs', register(on) {
    // cs's band refuses this session too: its press vets, is refused, and writes nothing.
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-chat-only', label: 'chat only', onPress: async () => {} }))
  } }],
}, async ($, on) => {
  const files: Files = new Map(planted === undefined ? [] : [[CHAT_ONLY, planted]])
  const runs: unknown[] = []
  const logs: string[] = []
  const redraws: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: '.cs/local is tracked by git\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(logs).toEqual(['chat only is off in this session: .cs/local is tracked by git'])
  await $.ui.press({ plugin: 'cs', key: 'cs-chat-only' })
  expect(await $.command.run(chatOnly('off'))).toEqual({ text: 'no chat only change in this session: .cs/local is tracked by git' })
  expect(await $.command.run(chatOnly('status'))).toEqual({ text: 'off' })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(files.get(CHAT_ONLY)).toBe(planted)
  expect(logs).toEqual(['chat only is off in this session: .cs/local is tracked by git'])
  expect(runs).toEqual([VET, VET])
  expect(redraws).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('trace 1 both ways: the band key turns chat only on, then off, and the rows follow', {
  plugins: [{ name: 'cs', register(on) {
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-chat-only', label: 'chat only', onPress: async () => {
      const now = await $.fs.read('/session/.cs/local/chat-only')
      await $.fs.write('/session/.cs/local/chat-only', now === 'on\n' ? 'off\n' : 'on\n')
    } }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'off\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  await $.ui.press({ plugin: 'cs', key: 'cs-chat-only' })
  expect(files.get(CHAT_ONLY)).toBe('on\n')
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine markdown'))).toBe(true)
  await $.ui.press({ plugin: 'cs', key: 'cs-chat-only' })
  expect(files.get(CHAT_ONLY)).toBe('off\n')
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(runs).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('traces 2 and 3: a typed flip mid-call passes the running call\'s row through, and back on hides it again', async ($, on) => {
  const files: Files = new Map([[CHAT_ONLY, 'on\n']])
  const writes: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine call' }))
  const call = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'ToolUse', props: { tool_use_id: 'slow', tool: 'Bash', input: { command: 'python3 slow.py' }, isRunning: true, isErrored: false, isInterrupted: false, output: undefined } })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(await $.command.run(chatOnly('off'))).toEqual({ text: OFF })
  expect((await call.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine call'])
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: ON })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(writes).toEqual([])
  await call.unmount()
})
