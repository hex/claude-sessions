// ABOUTME: Exercises the switch's reads, vets and writes through the engine test kit: the default on, the refusals, the logs and the command queue.
// ABOUTME: Test hooks stand in for the session's files and cs -vet-session; the engine's own drawing sits beneath chat only.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const STATUS = { command: 'chat-only', args: 'status', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const
const chatOnly = (args: string) => ({ ...STATUS, args })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']
const CHAT_ONLY = '/session/.cs/local/chat-only'

/**
 * A cs session at /session: its files, a cs that trusts it and a theme with
 * no row; every read path, process and log recorded. `outside` takes
 * .cs/local away, `readError` fails every read with it, `bin` is CS_BIN.
 */
function session(on: On, files: Map<string, string>, opts: { outside?: true; readError?: string; bin?: string | undefined } = {}) {
  const seen = { reads: [] as string[], runs: [] as unknown[], logs: [] as string[] }
  const bin = 'bin' in opts ? opts.bin : '/bin/cs'
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    seen.reads.push(e.path)
    if (opts.readError !== undefined) return { deny: opts.readError }
    const text = files.get(e.path)
    return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: !opts.outside && e.path === '/session/.cs/local' }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: bin }))
  on('process.run', ($, e) => { seen.runs.push(e.argv); return { value: PASSED } })
  on('ui.log', ($, e) => { seen.logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine reply' }))
  return seen
}

test('an off chat only file reads once per load without asking cs to vet it', async ($, on) => {
  const seen = session(on, new Map([[CHAT_ONLY, 'off\n']]))
  const one = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect((await two.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect(seen.reads).toEqual([CHAT_ONLY])
  expect(seen.runs).toEqual([])
  expect(seen.logs).toEqual([])
  await one.unmount()
  await two.unmount()
})

test('an absent chat only file in a cs session reads on: one vet, then the reply draws at the margin', async ($, on) => {
  const seen = session(on, new Map())
  const row = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine reply'))).toBe(true)
  expect(seen.runs).toEqual([VET])
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(seen.runs).toEqual([VET])
  expect(seen.logs).toEqual([])
  await row.unmount()
})

test('an absent chat only file outside a cs session reads off with no vet and no log', async ($, on) => {
  const seen = session(on, new Map(), { outside: true })
  const row = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect((await row.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.runs).toEqual([])
  expect(seen.logs).toEqual([])
  await row.unmount()
})

test('chat only text that is neither on nor off reads off and each kind is logged once per load, whichever read finds it', async ($, on) => {
  const files = new Map([[CHAT_ONLY, 'on']])
  const seen = session(on, files)
  const row = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  const torn = 'could not use /session/.cs/local/chat-only: it is torn, with no closing newline; chat only is off until /chat-only or the band\'s chat only key writes the file again'
  expect(seen.logs).toEqual([torn])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual([torn])
  files.set(CHAT_ONLY, 'on\nyes\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual([torn, 'could not use /session/.cs/local/chat-only: it holds "on\\nyes\\n", neither on nor off; chat only is off until /chat-only or the band\'s chat only key writes the file again'])
  expect(seen.runs).toEqual([])
  await row.unmount()
})

test('a chat only file that cannot be read for a reason other than its absence reads off, logged once with its path and the error', async ($, on) => {
  const seen = session(on, new Map(), { readError: 'EACCES: permission denied' })
  const row = await $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual(['could not read /session/.cs/local/chat-only: cs-chat-only: $.fs.read: EACCES: permission denied'])
  expect(seen.runs).toEqual([])
  await row.unmount()
})

test('two renders share an on-read vet and a refusal keeps both on the engine with one log', {
  plugins: [{ name: 'render-entry', tier: 'prepend', register(on) {
    on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
      await $.ui.log('render-entry')
      return next(e)
    })
  } }],
}, async ($, on) => {
  const calls: unknown[] = []
  const logs: string[] = []
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  let overlap: (() => void) | undefined
  let entries = 0
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const bothEntered = new Promise<void>(resolve => { overlap = resolve })
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    if (e.path === '/session/.cs/local/chat-only') return { value: 'on\n' }
    return { deny: 'ENOENT: no such file or directory' }
  })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', async ($, e) => {
    calls.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs })
    entered?.()
    await held
    return { value: { exitCode: 1, stdout: '', stderr: 'first line\nnot a trusted session\n\n', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', ($, e) => {
    if (e.text === 'render-entry') {
      entries++
      if (entries === 2) overlap?.()
    } else logs.push(e.text)
    return { value: undefined }
  })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine reply' }))
  const one = $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  await started
  const two = $.ui.mount({ plugin: 'cs-chat-only', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  await bothEntered
  release?.()
  const mounted = await Promise.all([one, two])
  for (const row of mounted) {
    expect((await row.find({ type: 'Text' }))?.text).toBe('engine reply')
    await row.unmount()
  }
  expect(calls).toEqual([{ argv: ['/bin/cs', '-vet-session', '/session'], timeoutMs: 10000 }])
  expect(logs).toEqual(['chat only is off in this session: not a trusted session'])
})

test('chat-only status reads a hand edit and vets an outside flip on only once', async ($, on) => {
  const files = new Map([[CHAT_ONLY, 'off\n']])
  const seen = session(on, files)
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  files.set(CHAT_ONLY, 'on\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(seen.runs).toEqual([VET])
  files.set(CHAT_ONLY, 'off\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual([])
})

test('chat-only on refuses a directory without cs local before asking for the binary or writing', async ($, on) => {
  const effects: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('fs.exists', ($, e) => { effects.push(e.path); return { value: false } })
  on('env.get', () => { effects.push('env'); return { value: undefined } })
  on('fs.write', () => { effects.push('write'); return { value: undefined } })
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: 'this directory is not a cs session (no .cs/local), so nothing changed.' })
  expect(effects).toEqual(['/session/.cs/local', '/session/.cs/local'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

test('a missing launch binary refuses a chat only write and preserves the mirror and files', async ($, on) => {
  const files = new Map([[CHAT_ONLY, 'off\n']])
  session(on, files, { bin: undefined })
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: 'no chat only change in this session: the launch did not say where cs is (CS_BIN)' })
  expect([...files]).toEqual([[CHAT_ONLY, 'off\n']])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

test('a vetted write redraws once per flip, and a write that changes nothing redraws nothing', async ($, on) => {
  const files = new Map([[CHAT_ONLY, 'off\n']])
  const seen = session(on, files)
  const redraws: string[] = []
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: "chat only on: your messages and Claude's replies only" })
  expect(files.get(CHAT_ONLY)).toBe('on\n')
  expect(await $.command.run(chatOnly('on'))).toEqual({ text: "chat only on: your messages and Claude's replies only" })
  expect(await $.command.run(chatOnly('off'))).toEqual({ text: "chat only off: Claude Code's own drawing" })
  expect(files.get(CHAT_ONLY)).toBe('off\n')
  expect(redraws).toEqual(['ui.render', 'ui.render'])
  expect(seen.runs).toEqual([VET, VET, VET])
})

test('a chat only write queued behind one in flight reads the file the first one wrote', {
  plugins: [{ name: 'command-entry', tier: 'prepend', register(on) {
    on('command.run', { command: 'chat-only' }, async ($, e, next) => {
      await $.ui.log(`entry ${e.args}`)
      return next(e)
    })
  } }],
}, async ($, on) => {
  const files = new Map([[CHAT_ONLY, 'off\n']])
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  let second: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const secondEntered = new Promise<void>(resolve => { second = resolve })
  let first = true
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const text = files.get(e.path); return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text } })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: PASSED }))
  on('ui.log', ($, e) => { if (e.text === 'entry ') second?.(); return { value: undefined } })
  on('fs.write', async ($, e) => {
    if (first) { first = false; entered?.(); await held }
    files.set(e.path, e.text)
    return { value: undefined }
  })
  const clock = mock.clock(on)
  const switching = $.command.run(chatOnly('on'))
  await started
  const toggling = $.command.run(chatOnly(''))
  await secondEntered
  await clock.settle()
  release?.()
  expect(await Promise.all([switching, toggling])).toEqual([{ text: "chat only on: your messages and Claude's replies only" }, { text: "chat only off: Claude Code's own drawing" }])
  expect(files.get(CHAT_ONLY)).toBe('off\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

for (const order of ['refusal first', 'write first']) test(`a successful write keeps its fresh vet with an older status refusal: ${order}`, async ($, on) => {
  let file = 'off\n'
  let runs = 0
  let releaseVet: (() => void) | undefined
  let vetEntered: (() => void) | undefined
  let releaseWrite: (() => void) | undefined
  let writeEntered: (() => void) | undefined
  const vetHeld = new Promise<void>(resolve => { releaseVet = resolve })
  const vetStarted = new Promise<void>(resolve => { vetEntered = resolve })
  const writeHeld = new Promise<void>(resolve => { releaseWrite = resolve })
  const writeStarted = new Promise<void>(resolve => { writeEntered = resolve })
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/chat-only') ? { value: file } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', async () => {
    runs++
    if (runs === 1) {
      vetEntered?.()
      await vetHeld
      return { value: { ...PASSED, exitCode: 1, stderr: 'old refusal\n' } }
    }
    return { value: PASSED }
  })
  on('fs.write', async ($, e) => { writeEntered?.(); await writeHeld; file = e.text; return { value: undefined } })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  file = 'on\n'
  const status = $.command.run(STATUS)
  await vetStarted
  const write = $.command.run(chatOnly('on'))
  await writeStarted
  const switched = { text: "chat only on: your messages and Claude's replies only" }
  if (order === 'refusal first') {
    releaseVet?.()
    expect(await status).toEqual({ text: 'off' })
    releaseWrite?.()
    expect(await write).toEqual(switched)
  } else {
    releaseWrite?.()
    expect(await write).toEqual(switched)
    releaseVet?.()
    expect(await status).toEqual({ text: 'on' })
  }
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(file).toBe('on\n')
  expect(runs).toBe(2)
  expect(logs).toEqual(order === 'refusal first' ? ['chat only is off in this session: old refusal'] : [])
})
