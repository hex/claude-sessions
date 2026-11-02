// ABOUTME: Checks each filter chat painter's visible words through real mounted engine render chains: your line, Claude's reply, its error line, and nothing for the work.
// ABOUTME: Test hooks supply the session's switch and retain an observable engine drawing beneath filter chat.
import { expect, test } from 'claude-code/testing'
import type { On, PromptOrigin } from 'claude-code'
import { YOU_INKS } from '../hooks/settings'

/** No pin and no machine file; the launch named this session alpha. */
function launchEnv(on: On) {
  on('env.get', { name: 'CS_FILTER_CHAT' }, () => ({ value: undefined }))
  on('env.get', { name: 'XDG_CONFIG_HOME' }, () => ({ value: undefined }))
  on('env.get', { name: 'HOME' }, () => ({ value: undefined }))
  on('env.get', { name: 'CLAUDE_SESSION_NAME' }, () => ({ value: 'alpha' }))
}

/** A cs session whose filter chat file says on and which cs trusts. */
function session(on: On) {
  launchEnv(on); on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/.cs/local/config') ? { value: 'CS_FILTER_CHAT=1\n' } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
}

test('UserMessage draws the terminal you margin and leaves the desktop engine body intact', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'UserMessage' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine prompt' }) })
  const terminal = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await terminal.find({ type: 'Text', text: '❯' }))?.text).toBe('❯')
  expect((await terminal.find({ type: 'Text', text: '❯' }))?.props.color).toBe('remember')
  expect((await terminal.find({ type: 'Text', text: '❯' }))?.props.bold).toBe(true)
  expect((await terminal.find({ type: 'Text', text: 'Read the notes' }))?.text).toBe('Read the notes')
  expect(await terminal.find({ text: 'engine prompt' })).toBeUndefined()
  const desktop = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'desktop', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('engine prompt')
  expect(calls).toBe(2)
  await terminal.unmount()
  await desktop.unmount()
})

test('UserMessage keeps the engine row for an origin filter chat has no rule for, envelope text included', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const origins: PromptOrigin[] = [
    { kind: 'plugin', name: 'helper-plugin' },
    { kind: 'channel', server: 'example' },
    { kind: 'slack-ping' },
    { kind: 'auto-continuation' },
  ]
  for (const [index, origin] of origins.entries()) {
    const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: `row-${index}`, props: { text: '<teammate-message teammate_id="alice">Ready</teammate-message>', origin, isExpanded: false } })
    expect((await row.find({ type: 'Text' }))?.text).toBe('engine prompt')
    await row.unmount()
  }
})

test('UserMessage draws nothing for a peer, a sent message, a task notification, a teammate, hook feedback or a row with no provenance', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'UserMessage' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine prompt' }) })
  const rows: { text: string; origin: PromptOrigin; from?: { name: string } }[] = [
    { text: 'Another session finished', origin: { kind: 'peer' }, from: { name: 'bob' } },
    { text: 'Ready for review', origin: { kind: 'peer-send-message' } },
    { text: 'Agent "Read the notes" completed', origin: { kind: 'task-notification' } },
    { text: 'Ready', origin: { kind: 'unclassified' }, from: { name: 'alice' } },
    { text: 'Stop hook feedback:\nTests need another pass', origin: { kind: 'unclassified' } },
  ]
  for (const [index, props] of rows.entries()) {
    const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: `row-${index}`, props: { ...props, isExpanded: false } })
    expect(await row.findAll({ type: 'Text' })).toEqual([])
    await row.unmount()
  }
  const unstamped = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: 'unstamped', props: { text: 'Read the notes', origin: { kind: 'unclassified' }, isExpanded: false } })
  expect((await unstamped.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['❯', 'Read the notes'])
  await unstamped.unmount()
  expect(calls).toBe(rows.length + 1)
})

test('UserMessage draws your text in the you ink, and a slash command with its name in that ink and its arguments dim', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const plain = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: 'plain', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await plain.find({ type: 'Text', text: 'Read the notes' }))?.props.color).toBe('remember')
  const command = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: 'command', props: { text: '/filter-chat status now', origin: { kind: 'composer' }, isExpanded: false } })
  const name = await command.find({ type: 'Text', text: '/filter-chat' })
  const args = await command.find({ type: 'Text', text: 'status now' })
  expect([name?.text, name?.props.color, name?.props.dimColor]).toEqual(['/filter-chat', 'remember', undefined])
  expect([args?.text, args?.props.dimColor]).toEqual(['status now', true])
  await plain.unmount()
  await command.unmount()
})

// The /config row cs-filter-chat.youInk names the you ink; the tests above load
// with no value set, so they draw the manifest's default, remember.
for (const ink of YOU_INKS) {
  test(`with the you ink set to ${ink}, UserMessage draws the bold ❯, your text and a slash command's name in ${ink}`, { options: { youInk: ink } }, async ($, on) => {
    session(on)
    on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
    const plain = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: 'plain', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
    const command = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', requestId: 'command', props: { text: '/filter-chat status now', origin: { kind: 'composer' }, isExpanded: false } })
    const mark = await plain.find({ type: 'Text', text: '❯' })
    const text = await plain.find({ type: 'Text', text: 'Read the notes' })
    const name = await command.find({ type: 'Text', text: '/filter-chat' })
    const args = await command.find({ type: 'Text', text: 'status now' })
    expect([mark?.props.color, mark?.props.bold, text?.props.color, name?.props.color, args?.props.color, args?.props.dimColor]).toEqual([ink, true, ink, ink, undefined, true])
    await plain.unmount()
    await command.unmount()
  })
}

test('a stored you ink outside the row\'s options draws in remember: Claude Code reads it as the default before the mod loads', { options: { youInk: 'chartreuse' } }, async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect([(await row.find({ type: 'Text', text: '❯' }))?.props.color, (await row.find({ type: 'Text', text: 'Read the notes' }))?.props.color]).toEqual(['remember', 'remember'])
  await row.unmount()
})

test('an expanded row (ctrl+o, --verbose) keeps the engine drawing', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  on('ui.render', { component: 'ToolGroup' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine group' }))
  const prompt = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'UserMessage', props: { text: 'Ready', origin: { kind: 'peer' }, isExpanded: true } })
  const group = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolGroup', props: { calls: [], isActive: false, isExpanded: true } })
  expect((await prompt.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine prompt'])
  expect((await group.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine group'])
  await prompt.unmount()
  await group.unmount()
})

test('AssistantMessage frames the engine markdown once under the terminal margin, with no name', async ($, on) => {
  session(on)
  const flags: boolean[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => { flags.push(e.props.isFirstOfReply); return $.ui.resolve(e).Text({ children: 'engine markdown' }) })
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Here is the answer.', isFirstOfReply: true } })
  expect(await row.find({ type: 'Text', text: 'claude' })).toBeUndefined()
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine markdown'])
  expect((await row.findAll({ type: 'Box' })).some(box => box.props.paddingLeft === 2 && JSON.stringify(box.children).includes('engine markdown'))).toBe(true)
  expect(flags).toEqual([false])
  await row.unmount()
})

test('AssistantMessage draws a failed reply as one line in the colour of who acts, with its remedies dim, in the reply\'s place', async ($, on) => {
  session(on)
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine markdown' }))
  const drawn = async (requestId: string, text: string) => {
    const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'AssistantMessage', requestId, props: { text, isFirstOfReply: true } })
    const texts = (await row.findAll({ type: 'Text' })).map(text => [text.text, text.props.color, text.props.dimColor])
    await row.unmount()
    return texts
  }
  expect(await drawn('safeguard', "API Error: Sonnet's safeguards stopped the response above")).toEqual([["Sonnet's safeguards cut the reply above", 'merged', undefined], ['Claude continues', undefined, true], ['esc esc goes back to an earlier message', undefined, true]])
  expect(await drawn('limit', 'Claude AI usage limit reached, resets 3pm')).toEqual([['Usage limit reached', 'error', undefined], ['resets 3pm', undefined, true], ['nothing is lost', undefined, true], ['/model to switch', undefined, true]])
  expect(await drawn('connection', 'API Error: Connection error.')).toEqual([['Connection lost', 'text', undefined], ['check your internet', undefined, true], ['send again to retry', undefined, true]])
})

test('the work draws nothing while on: a call, a group, a result, the progress hint and the turn timing, each still passing through the engine', async ($, on) => {
  session(on)
  const engine: string[] = []
  on('ui.render', { component: 'ToolUse' }, ($, e) => { engine.push('call'); return $.ui.resolve(e).Text({ children: 'engine call' }) })
  on('ui.render', { component: 'ToolGroup' }, ($, e) => { engine.push('group'); return $.ui.resolve(e).Text({ children: 'engine group' }) })
  on('ui.render', { component: 'ToolResult' }, ($, e) => { engine.push('result'); return $.ui.resolve(e).Text({ children: 'engine result' }) })
  on('ui.render', { component: 'ToolProgress' }, ($, e) => { engine.push(`hint ${e.props.hint}`); return $.ui.resolve(e).Text({ children: 'engine progress' }) })
  on('ui.render', { component: 'TurnDuration' }, ($, e) => { engine.push('duration'); return $.ui.resolve(e).Text({ children: 'engine duration' }) })
  const read = { tool_use_id: 'notes', tool: 'Read', input: { file_path: '/repo/notes.md' }, isRunning: false, isErrored: false, isInterrupted: false, output: 'the notes' }
  const rows = [
    await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolUse', requestId: 'notes', props: read }),
    await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolGroup', props: { calls: [read, { ...read, tool_use_id: 'more' }], isActive: true, isExpanded: false } }),
    await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolResult', props: { tool_use_id: 'notes', tool: 'Read', output: 'the notes', isErrored: false } }),
    await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'ToolProgress', props: { tool_use_id: 'notes', kind: 'background_hint', hint: 'ctrl+b to run in background' } }),
    await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'TurnDuration', props: { word: 'Worked', durationMs: 4000 } }),
  ]
  for (const row of rows) {
    expect(await row.findAll({ type: 'Text' })).toEqual([])
    await row.unmount()
  }
  expect(engine).toEqual(['call', 'group', 'result', 'hint ctrl+b to run in background', 'duration'])
})

test('the working line is Claude Code\'s own: filter chat leaves its words and suffix as the engine set them', async ($, on) => {
  session(on)
  const seen: unknown[] = []
  on('ui.render', { component: 'Spinner' }, ($, e) => { seen.push([e.props.message, e.props.suffix]); return $.ui.resolve(e).Text({ children: e.props.word }) })
  const line = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'Spinner', props: { word: 'Sauteing', message: null, suffix: '…', mode: 'tool-use' } })
  expect((await line.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['Sauteing'])
  expect(seen).toEqual([[null, '…']])
  await line.unmount()
})

test('SessionMode appends the filter chat mode while preserving the engine modes', async ($, on) => {
  session(on)
  on('ui.render', { component: 'SessionMode' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.modes.join(' | ') }))
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'SessionMode', props: { modes: ['auto mode on'] } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('auto mode on | filter chat · /filter-chat to switch')
  await row.unmount()
})

test('CommandOutput draws the cleaned command answer beside a dim dot', async ($, on) => {
  session(on)
  on('ui.render', { component: 'CommandOutput' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine command' }))
  const row = await $.ui.mount({ plugin: 'cs-filter-chat', surface: 'terminal', component: 'CommandOutput', props: { command: 'filter-chat', args: 'status', text: 'cs-filter-chat: on', isErrored: false } })
  expect((await row.find({ type: 'Text', text: 'on' }))?.text).toBe('on')
  expect((await row.find({ type: 'Text', text: '·' }))?.text).toBe('·')
  expect((await row.find({ type: 'Text', text: 'on' }))?.props.dimColor).toBe(true)
  await row.unmount()
})
