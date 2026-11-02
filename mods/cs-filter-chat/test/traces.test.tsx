// ABOUTME: Walks the design's traces and refusal paths end to end through the engine test kit: flips both ways, a planted refused on, vet answers.
// ABOUTME: Test hooks stand in for the session's files, cs and the engine's own drawing beneath filter chat.
import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

/** No pin and no machine file; the launch named this session alpha. */
function launchEnv(on: On) {
  on('env.get', { name: 'CS_FILTER_CHAT' }, () => ({ value: undefined }))
  on('env.get', { name: 'XDG_CONFIG_HOME' }, () => ({ value: undefined }))
  on('env.get', { name: 'HOME' }, () => ({ value: undefined }))
  on('env.get', { name: 'CLAUDE_SESSION_NAME' }, () => ({ value: 'alpha' }))
}
/** What `cs alpha -config set CS_FILTER_CHAT <v>` leaves in this session's file, or undefined for any other argv. */
const configSet = (argv: readonly string[]) => argv.includes('-config') ? `CS_FILTER_CHAT=${argv.at(-1)}\n` : undefined

const RUN = { origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const
const filterChat = (args: string) => ({ command: 'filter-chat', args, ...RUN })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']
const SET_ON = ['/bin/cs', 'alpha', '-config', 'set', 'CS_FILTER_CHAT', '1']
const SET_OFF = ['/bin/cs', 'alpha', '-config', 'set', 'CS_FILTER_CHAT', '0']
const FILTER_CHAT = '/session/.cs/local/config'
const ON = "filter chat on: your messages and Claude's replies only"
const OFF = "filter chat off: Claude Code's own drawing"
/** The row cs's band draws in, which filter chat leaves to cs. */
const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } as const

type Files = Map<string, string>
function filesOn(on: On, files: Files) {
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const text = files.get(e.path); return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text } })
  on('fs.exists', ($, e) => ({ value: e.path === '/session/.cs/local' }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
}

for (const [name, answer, refusal] of [
  ['exits 1 with a stderr line', { value: { ...PASSED, exitCode: 1, stderr: 'warming up\n.cs/local is tracked by git\n' } }, '.cs/local is tracked by git'],
  ['exits 1 with no stderr', { value: { ...PASSED, exitCode: 1 } }, 'cs -vet-session exited 1'],
] as const) test(`a filter chat write refused by a cs that ${name} writes nothing and says cs's reason`, async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return answer })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: `no filter chat change in this session: ${refusal}` })
  expect([...files]).toEqual([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  expect(runs).toEqual([VET])
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET])
})

test('a filter chat write whose vet cannot run writes nothing and says why', async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ deny: 'spawn /bin/cs ENOENT' }))
  expect(await $.command.run(filterChat('on'))).toEqual({ text: 'no filter chat change in this session: cs -vet-session did not run: cs-filter-chat: $.process.run: spawn /bin/cs ENOENT' })
  expect([...files]).toEqual([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
})

test('filter-chat status and an unknown word run no process while the file is off', async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  expect(await $.command.run(filterChat('close'))).toEqual({ text: '/filter-chat toggles filter chat · /filter-chat on | off | status' })
  expect(runs).toEqual([])
  expect([...files]).toEqual([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
})

test('bare filter-chat flips the file it reads: no file is off, so it writes on, then off', async ($, on) => {
  const files: Files = new Map()
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); const text = configSet(e.argv); if (text !== undefined) files.set(FILTER_CHAT, text); return { value: PASSED } })
  expect(await $.command.run(filterChat(''))).toEqual({ text: ON })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=1\n')
  expect(await $.command.run(filterChat(''))).toEqual({ text: OFF })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=0\n')
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET, SET_ON, VET, SET_OFF])
})

test('an on file vetted at the load draws filter chat after one process with cs\'s exact argv', async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=1\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs }); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const one = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'Done.', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'Done.', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect((await two.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'on' })
  expect(runs).toEqual([{ argv: VET, timeoutMs: 10000 }])
  await one.unmount()
  await two.unmount()
})

test('a refusal the read side already logged is not logged again when an outside on is vetted again', async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=1\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: 'not this session\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  files.set(FILTER_CHAT, 'CS_FILTER_CHAT=0\n')
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  files.set(FILTER_CHAT, 'CS_FILTER_CHAT=1\n')
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  expect(runs).toEqual([VET, VET])
  expect(logs).toEqual(['filter chat is off in this session: not this session'])
})

test('trace 7: a planted on in a session cs refuses draws nothing, logs once, and a press, filter-chat off and filter-chat status add no log', {
  plugins: [{ name: 'cs', register(on) {
    // cs's band refuses this session too: its press vets, is refused, and writes nothing.
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-filter-chat', label: 'filter chat', onPress: async () => {} }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=1\n']])
  const runs: unknown[] = []
  const logs: string[] = []
  const redraws: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { ...PASSED, exitCode: 1, stderr: '.cs/local is tracked by git\n' } } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(logs).toEqual(['filter chat is off in this session: .cs/local is tracked by git'])
  await $.ui.press({ plugin: 'cs', key: 'cs-filter-chat' })
  expect(await $.command.run(filterChat('off'))).toEqual({ text: 'no filter chat change in this session: .cs/local is tracked by git' })
  expect(await $.command.run(filterChat('status'))).toEqual({ text: 'off' })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=1\n')
  expect(logs).toEqual(['filter chat is off in this session: .cs/local is tracked by git'])
  expect(runs).toEqual([VET, VET])
  expect(redraws).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('trace 1 both ways: the band key turns filter chat on, then off, and the rows follow', {
  plugins: [{ name: 'cs', register(on) {
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Button({ key: 'cs-filter-chat', label: 'filter chat', onPress: async () => {
      const now = await $.fs.read('/session/.cs/local/config')
      await $.fs.write('/session/.cs/local/config', now === 'CS_FILTER_CHAT=1\n' ? 'CS_FILTER_CHAT=0\n' : 'CS_FILTER_CHAT=1\n')
    } }))
  } }],
}, async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  const runs: unknown[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const reply = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Done.', isFirstOfReply: true } })
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  await $.ui.press({ plugin: 'cs', key: 'cs-filter-chat' })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=1\n')
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine markdown'))).toBe(true)
  await $.ui.press({ plugin: 'cs', key: 'cs-filter-chat' })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=0\n')
  expect((await reply.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect((await reply.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(runs).toEqual([])
  await reply.unmount()
  await band.unmount()
})

test('traces 2 and 3: a typed flip mid-call passes the running call\'s row through, and back on hides it again', async ($, on) => {
  const files: Files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=1\n']])
  const writes: string[] = []
  filesOn(on, files)
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { const text = configSet(e.argv); if (text !== undefined) files.set(FILTER_CHAT, text); return { value: PASSED } })
  on('state.set', async ($, e, next) => { writes.push(e.key); return next(e) })
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine call' }))
  const call = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolUse', props: { tool_use_id: 'slow', tool: 'Bash', input: { command: 'python3 slow.py' }, isRunning: true, isErrored: false, isInterrupted: false, output: undefined } })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(await $.command.run(filterChat('off'))).toEqual({ text: OFF })
  expect((await call.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine call'])
  expect(await $.command.run(filterChat('on'))).toEqual({ text: ON })
  expect(await call.findAll({ type: 'Text' })).toEqual([])
  expect(writes).toEqual([])
  await call.unmount()
})
