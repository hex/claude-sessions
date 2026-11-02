// ABOUTME: Checks filter chat's hook inventory and behavior through the engine test kit.
// ABOUTME: Recording registrars inspect declarations; rendering and effects use the real engine chains.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { PAINTERS, register } from '../hooks/register'
import { BAND_ELEMENT, BAND_PLUGIN } from '../hooks/settings'

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
/** The row cs's band draws in, which filter chat leaves to cs. */
const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } as const

test('register installs the command, the band press and every filter chat render site, and no other hook', () => {
  const seen: { event: string; matcher: unknown }[] = []
  const record = (event: string, matcher: unknown) => { seen.push({ event, matcher: typeof matcher === 'function' ? undefined : matcher }) }
  register(record as unknown as On, { youInk: 'remember' })
  expect(seen.find(entry => entry.event === 'ui.press')?.matcher).toEqual({ plugin: BAND_PLUGIN, element: BAND_ELEMENT })
  expect(seen).toEqual([
    { event: 'session.start', matcher: undefined },
    { event: 'command.run', matcher: { command: 'filter-chat' } },
    { event: 'ui.press', matcher: { plugin: 'cs', element: 'cs-filter-chat' } },
    ...['UserMessage', 'AssistantMessage', 'ToolUse', 'ToolGroup', 'ToolResult', 'ToolProgress', 'TurnDuration', 'CommandOutput', 'SessionMode'].map(component => ({ event: 'ui.render', matcher: { component } })),
  ])
  expect(seen.filter(entry => entry.event === 'ui.render').map(entry => typeof entry.matcher === 'object' && entry.matcher !== null && 'component' in entry.matcher ? entry.matcher.component : undefined)).toEqual(Object.keys(PAINTERS))
})

test('two quick cs button presses share its held write and filter chat reads on only after it settles', {
  plugins: [{ name: 'cs', register(on) {
    let pending: Promise<void> | undefined
    on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
      const press = () => pending ??= $.fs.write('/session/.cs/local/config', 'CS_FILTER_CHAT=1\n').finally(() => { pending = undefined })
      return $.ui.resolve(e).Button({ key: 'cs-filter-chat', label: 'filter chat', onPress: press })
    })
  } }],
}, async ($, on) => {
  let file = 'CS_FILTER_CHAT=0\n'
  let writes = 0
  const reads: string[] = []
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', ($, e) => {
    if (!e.path.endsWith('/.cs/local/config')) return { deny: 'ENOENT: no such file or directory' }
    reads.push(file)
    return { value: file }
  })
  on('fs.write', async ($, e) => { writes++; entered?.(); await held; file = e.text; return { value: undefined } })
  on('ui.render', { component: 'TurnDuration' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine duration' }))
  const clock = mock.clock(on)
  const band = await $.ui.mount({ plugin: 'cs', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'TurnDuration', props: { word: 'Worked', durationMs: 4000 } })
  expect(reads).toEqual(['CS_FILTER_CHAT=0\n'])
  const first = $.ui.press({ plugin: 'cs', key: 'cs-filter-chat' })
  await started
  const second = $.ui.press({ plugin: 'cs', key: 'cs-filter-chat' })
  await clock.settle()
  expect(writes).toBe(1)
  expect(reads).toEqual(['CS_FILTER_CHAT=0\n'])
  release?.()
  await Promise.all([first, second])
  expect(reads).toEqual(['CS_FILTER_CHAT=0\n', 'CS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT=1\n'])
  expect(await $.command.run({ command: 'filter-chat', args: 'status', ...RUN })).toEqual({ text: 'on' })
  expect(writes).toBe(1)
  await row.unmount()
  await band.unmount()
})

test('session start waits for the /filter-chat registration before the engine starts', async ($, on) => {
  const calls: string[] = []
  let release: (() => void) | undefined
  let entered: (() => void) | undefined
  const held = new Promise<void>(resolve => { release = resolve })
  const started = new Promise<void>(resolve => { entered = resolve })
  on('command.register', async ($, e) => {
    calls.push(`register ${e.name}`)
    entered?.()
    await held
    return { value: { command: e.name } }
  })
  on('session.start', ($, e) => { calls.push('engine start'); return { cwd: e.cwd } })
  const start = $.session.start({ cwd: '/session', surface: 'terminal', isInteractive: true })
  await started
  expect(calls).toEqual(['register filter-chat'])
  release?.()
  expect(await start).toEqual({ cwd: '/session' })
  expect(calls).toEqual(['register filter-chat', 'engine start'])
})

test('session start registers /filter-chat alone, with its menu words, and any word but on, off and status replies the usage line', async ($, on) => {
  const specs: unknown[] = []
  on('command.register', async ($, e) => { specs.push({ ...e }); return { value: { command: e.name } } })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/session', surface: 'terminal', isInteractive: true })
  expect(specs).toEqual([
    { name: 'filter-chat', description: "Show only your messages and Claude's replies in this session: toggle, on, off or status", argumentHint: 'on | off | status', immediate: true },
  ])
  for (const args of ['clean', 'close', 'hide peer', 'on please']) {
    expect(await $.command.run({ command: 'filter-chat', args, ...RUN })).toEqual({ text: '/filter-chat toggles filter chat · /filter-chat on | off | status' })
  }
})
