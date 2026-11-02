// ABOUTME: Exercises the switch's reads, vets and writes through the engine test kit: the default on, the refusals, the logs and the command queue.
// ABOUTME: Test hooks stand in for the session's files and cs -vet-session; the engine's own drawing sits beneath filter chat.
import { expect, mock, test } from 'claude-code/testing'
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

const STATUS = { command: 'filter-chat', args: 'status', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const
const filterChat = (args: string) => ({ ...STATUS, args })
const PASSED = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const VET = ['/bin/cs', '-vet-session', '/session']
const SET_ON = ['/bin/cs', 'alpha', '-config', 'set', 'CS_FILTER_CHAT', '1']
const SET_OFF = ['/bin/cs', 'alpha', '-config', 'set', 'CS_FILTER_CHAT', '0']
const FILTER_CHAT = '/session/.cs/local/config'

/**
 * A cs session at /session: its files, a cs that trusts it and a theme with
 * no row; every read path, process and log recorded. `outside` takes
 * .cs/local away, `readError` fails every read with it, `bin` is CS_BIN.
 */
function session(on: On, files: Map<string, string>, opts: { outside?: true; readError?: string; bin?: string | undefined } = {}) {
  const seen = { reads: [] as string[], runs: [] as unknown[], logs: [] as string[] }
  const bin = 'bin' in opts ? opts.bin : '/bin/cs'
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => {
    seen.reads.push(e.path)
    if (opts.readError !== undefined) return { deny: opts.readError }
    const text = files.get(e.path)
    return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: !opts.outside && e.path === '/session/.cs/local' }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: bin }))
  on('process.run', ($, e) => { seen.runs.push(e.argv); const text = configSet(e.argv); if (text !== undefined) files.set(FILTER_CHAT, text); return { value: PASSED } })
  on('ui.log', ($, e) => { seen.logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine reply' }))
  return seen
}

test('an off filter chat file reads once per load without asking cs to vet it', async ($, on) => {
  const seen = session(on, new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']]))
  const one = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  const two = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  expect((await one.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect((await two.find({ type: 'Text' }))?.text).toBe('engine reply')
  expect(seen.reads).toEqual([FILTER_CHAT])
  expect(seen.runs).toEqual([])
  expect(seen.logs).toEqual([])
  await one.unmount()
  await two.unmount()
})

test('an absent filter chat file in a cs session reads off with no vet and no log, and the reply stays the engine\'s', async ($, on) => {
  const seen = session(on, new Map())
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect((await row.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.runs).toEqual([])
  expect(seen.logs).toEqual([])
  await row.unmount()
})

test('an absent filter chat file outside a cs session reads off with no vet and no log', async ($, on) => {
  const seen = session(on, new Map(), { outside: true })
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect((await row.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2)).toBe(false)
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.runs).toEqual([])
  expect(seen.logs).toEqual([])
  await row.unmount()
})

test('a line cs would not accept says nothing: filter chat reads off and logs nothing', async ($, on) => {
  const files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=on\n']])
  const seen = session(on, files)
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual([])
  expect(seen.runs).toEqual([])
  await row.unmount()
})

for (const [name, env, machine, session_, reply, vets] of [
  ['the environment pins on over a session file off', { CS_FILTER_CHAT: '1' }, undefined, 'CS_FILTER_CHAT=0\n', 'on', 1],
  ['the environment pins off over a session file on', { CS_FILTER_CHAT: '0' }, undefined, 'CS_FILTER_CHAT=1\n', 'off', 0],
  ['the machine file says on where the session file says nothing', { HOME: '/home/a' }, '/home/a/.config/cs/config', undefined, 'on', 1],
  ['the session file off outranks the machine file on', { HOME: '/home/a' }, '/home/a/.config/cs/config', 'CS_FILTER_CHAT=0\n', 'off', 0],
  ['XDG_CONFIG_HOME names the machine file', { XDG_CONFIG_HOME: '/x', HOME: '/home/a' }, '/x/cs/config', undefined, 'on', 1],
] as const) test(`${name}, as cs resolves a setting`, async ($, on) => {
  const files = new Map<string, string>()
  if (session_ !== undefined) files.set(FILTER_CHAT, session_)
  if (machine !== undefined) files.set(machine, 'CS_FILTER_CHAT=1\n')
  for (const [key, value] of Object.entries(env)) on('env.get', { name: key }, () => ({ value }))
  const seen = session(on, files)
  expect(await $.command.run(STATUS)).toEqual({ text: reply })
  expect(seen.runs).toEqual(vets === 1 ? [VET] : [])
})

test('a switch the environment pins says so instead of claiming the flip', async ($, on) => {
  on('env.get', { name: 'CS_FILTER_CHAT' }, () => ({ value: '1' }))
  const files = new Map<string, string>()
  session(on, files)
  expect(await $.command.run(filterChat('off'))).toEqual({ text: 'CS_FILTER_CHAT in your environment wins, so filter chat stays on until you unset it there.' })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=0\n')
})

for (const [name, answer, refusal] of [
  ['exits 2 with its words', { value: { ...PASSED, exitCode: 2, stderr: 'Error: CS_FILTER_CHAT not changed\n' } }, 'Error: CS_FILTER_CHAT not changed'],
  ['cannot run', { deny: 'spawn ENOENT' }, 'cs -config set did not run: cs-filter-chat: $.process.run: spawn ENOENT'],
] as const) test(`a cs write that ${name} says so and leaves the setting off`, async ($, on) => {
  const files = new Map<string, string>()
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => e.argv.includes('-config') ? answer : { value: PASSED })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: `no filter chat change in this session: ${refusal}` })
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

test('a launch that named no session writes nothing and says why', async ($, on) => {
  const runs: unknown[] = []
  on('env.get', { name: 'CLAUDE_SESSION_NAME' }, () => ({ value: undefined }))
  on('env.get', { name: 'CS_FILTER_CHAT' }, () => ({ value: undefined }))
  on('env.get', { name: 'XDG_CONFIG_HOME' }, () => ({ value: undefined }))
  on('env.get', { name: 'HOME' }, () => ({ value: undefined }))
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', ($, e) => { runs.push(e.argv); return { value: PASSED } })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: 'no filter chat change in this session: the launch did not name this session (CLAUDE_SESSION_NAME)' })
  expect(runs).toEqual([VET])
})

test('a filter chat file that cannot be read for a reason other than its absence reads off, logged once with its path and the error', async ($, on) => {
  const seen = session(on, new Map(), { readError: 'EACCES: permission denied' })
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'answer', isFirstOfReply: true } })
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine reply'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual(['could not read /session/.cs/local/config: cs-filter-chat: $.fs.read: EACCES: permission denied'])
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
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', ($, e) => {
    if (e.path === '/session/.cs/local/config') return { value: 'CS_FILTER_CHAT=1\n' }
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
  const one = $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'one', props: { text: 'answer', isFirstOfReply: true } })
  await started
  const two = $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId: 'two', props: { text: 'answer', isFirstOfReply: true } })
  await bothEntered
  release?.()
  const mounted = await Promise.all([one, two])
  for (const row of mounted) {
    expect((await row.find({ type: 'Text' }))?.text).toBe('engine reply')
    await row.unmount()
  }
  expect(calls).toEqual([{ argv: ['/bin/cs', '-vet-session', '/session'], timeoutMs: 10000 }])
  expect(logs).toEqual(['filter chat is off in this session: not a trusted session'])
})

test('filter-chat status reads a hand edit and vets an outside flip on only once', async ($, on) => {
  const files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  const seen = session(on, files)
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  files.set(FILTER_CHAT, 'CS_FILTER_CHAT=1\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(await $.command.run(STATUS)).toEqual({ text: 'on' })
  expect(seen.runs).toEqual([VET])
  files.set(FILTER_CHAT, 'CS_FILTER_CHAT=0\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  expect(seen.logs).toEqual([])
})

test('filter-chat on refuses a directory without cs local before asking for the binary or writing', async ($, on) => {
  const effects: string[] = []
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('fs.exists', ($, e) => { effects.push(e.path); return { value: false } })
  on('env.get', () => { effects.push('env'); return { value: undefined } })
  on('fs.write', () => { effects.push('write'); return { value: undefined } })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: 'this directory is not a cs session (no .cs/local), so nothing changed.' })
  expect(effects).toEqual(['/session/.cs/local'])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

test('a missing launch binary refuses a filter chat write and preserves the mirror and files', async ($, on) => {
  const files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  session(on, files, { bin: undefined })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: 'no filter chat change in this session: the launch did not say where cs is (CS_BIN)' })
  expect([...files]).toEqual([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

test('a vetted write redraws once per flip, and a write that changes nothing redraws nothing', async ($, on) => {
  const files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  const seen = session(on, files)
  const redraws: string[] = []
  on('ui.invalidate', ($, e) => { redraws.push(e.event); return { value: undefined } })
  expect(await $.command.run(filterChat('on'))).toEqual({ text: "filter chat on: your messages and Claude's replies only" })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=1\n')
  expect(await $.command.run(filterChat('on'))).toEqual({ text: "filter chat on: your messages and Claude's replies only" })
  expect(await $.command.run(filterChat('off'))).toEqual({ text: "filter chat off: Claude Code's own drawing" })
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=0\n')
  expect(redraws).toEqual(['ui.render', 'ui.render'])
  expect(seen.runs).toEqual([VET, SET_ON, VET, SET_ON, VET, SET_OFF])
})

test('a filter chat write queued behind one in flight reads the file the first one wrote', {
  plugins: [{ name: 'command-entry', tier: 'prepend', register(on) {
    on('command.run', { command: 'filter-chat' }, async ($, e, next) => {
      await $.ui.log(`entry ${e.args}`)
      return next(e)
    })
  } }],
}, async ($, on) => {
  const files = new Map([[FILTER_CHAT, 'CS_FILTER_CHAT=0\n']])
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  let second: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  const secondEntered = new Promise<void>(resolve => { second = resolve })
  let first = true
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const text = files.get(e.path); return text === undefined ? { deny: 'ENOENT: no such file or directory' } : { value: text } })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', async ($, e) => {
    const text = configSet(e.argv)
    if (text === undefined) return { value: PASSED }
    if (first) { first = false; entered?.(); await held }
    files.set(FILTER_CHAT, text)
    return { value: PASSED }
  })
  on('ui.log', ($, e) => { if (e.text === 'entry ') second?.(); return { value: undefined } })
  const clock = mock.clock(on)
  const switching = $.command.run(filterChat('on'))
  await started
  const toggling = $.command.run(filterChat(''))
  await secondEntered
  await clock.settle()
  release?.()
  expect(await Promise.all([switching, toggling])).toEqual([{ text: "filter chat on: your messages and Claude's replies only" }, { text: "filter chat off: Claude Code's own drawing" }])
  expect(files.get(FILTER_CHAT)).toBe('CS_FILTER_CHAT=0\n')
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
})

for (const order of ['refusal first', 'write first']) test(`a successful write keeps its fresh vet with an older status refusal: ${order}`, async ($, on) => {
  let file = 'CS_FILTER_CHAT=0\n'
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
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/.cs/local/config') ? { value: file } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', async ($, e) => {
    runs++
    if (runs === 1) {
      vetEntered?.()
      await vetHeld
      return { value: { ...PASSED, exitCode: 1, stderr: 'old refusal\n' } }
    }
    const text = configSet(e.argv)
    if (text !== undefined) { writeEntered?.(); await writeHeld; file = text }
    return { value: PASSED }
  })
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  expect(await $.command.run(STATUS)).toEqual({ text: 'off' })
  file = 'CS_FILTER_CHAT=1\n'
  const status = $.command.run(STATUS)
  await vetStarted
  const write = $.command.run(filterChat('on'))
  await writeStarted
  const switched = { text: "filter chat on: your messages and Claude's replies only" }
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
  expect(file).toBe('CS_FILTER_CHAT=1\n')
  expect(runs).toBe(3)
  expect(logs).toEqual(order === 'refusal first' ? ['filter chat is off in this session: old refusal'] : [])
})
