// ABOUTME: Checks each feed painter's visible words through real mounted engine render chains.
// ABOUTME: Test hooks supply recorded session inputs and retain an observable engine drawing beneath the feed.
import { expect, mock, test } from 'claude-code/testing'
import type { AgentInfo, On, PromptOrigin, RenderPropsOf, SessionMessage } from 'claude-code'
import type { Engine } from 'claude-code/testing'

function session(on: On, rows: SessionMessage[] = [], agents: () => AgentInfo[] = () => [], view?: string) {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : e.path.endsWith('/feed-view') && view !== undefined ? { value: view } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : rows }))
  on('agent.list', () => ({ value: agents() }))
  on('config.list', () => ({ value: [] }))
  return mock.clock(on)
}

type Drawn = { readonly type: string; readonly props?: Readonly<Record<string, unknown>>; readonly children?: readonly unknown[] }
function isDrawn(value: unknown): value is Drawn {
  return typeof value === 'object' && value !== null && 'type' in value && typeof value.type === 'string'
}
/**
 * The lines a drawn tree shows on the 2.1.310 terminal, text only and without
 * indents: a row's children `gap` cells apart (Ink's default gap is 0), a
 * column one line per child, a plain Button its label (`hotkey: label` with a
 * hotkey), any other Button `[ label ]`, as the bundle's Button draws them.
 * A `flexWrap: 'wrap'` row in `columns` cells packs its children onto as
 * many lines as it needs, `columnGap` (else `gap`) cells apart and `rowGap`
 * (else `gap`) blank lines between, as Yoga packs a wrapping row. Every glyph
 * drawn here is one cell.
 */
function shown(node: unknown, columns = Infinity): string[] {
  if (typeof node === 'string') return [node]
  if (!isDrawn(node)) return []
  const props = node.props ?? {}
  const children = node.children ?? []
  switch (node.type) {
    case 'Text': return [children.flatMap(child => shown(child, columns)).join('')]
    case 'Button': {
      const label = String(props.label)
      return [props.plain ? props.hotkey ? `${String(props.hotkey)}: ${label}` : label : `[ ${label} ]`]
    }
    case 'Box': {
      if (props.flexDirection === 'column') return children.flatMap(child => shown(child, columns))
      const parts = children.map(child => {
        const lines = shown(child, columns)
        if (lines.length > 1) throw new Error(`a row child draws ${lines.length} lines: ${JSON.stringify(child)}`)
        return lines[0]
      }).filter(part => part !== undefined)
      const between = ' '.repeat(Number(props.columnGap ?? props.gap ?? 0))
      if (props.flexWrap !== 'wrap') return parts.length ? [parts.join(between)] : []
      const rows: string[] = []
      for (const part of parts) {
        const last = rows[rows.length - 1]
        if (last !== undefined && [...last].length + between.length + [...part].length <= columns) rows[rows.length - 1] = last + between + part
        else rows.push(part)
      }
      return rows.flatMap((row, i) => i === 0 ? [row] : [...Array.from({ length: Number(props.rowGap ?? props.gap ?? 0) }, () => ''), row])
    }
    default: throw new Error(`no text rule for a ${node.type}`)
  }
}

const NORMAL_VIEW = '{"group":false,"clear":false,"keep":true,"style":"subtle","commands":"grouped","after":"keep","hide":[]}\n'
const WORK: SessionMessage[] = [
  { role: 'user', text: 'Look around', toolUses: [] },
  { role: 'assistant', text: '', toolUses: [
    { tool_use_id: 'tests', tool: 'Bash', input: { command: 'npm test' }, result: { stdout: 'ok\nok' } },
    { tool_use_id: 'build', tool: 'Bash', input: { command: 'make' }, result: { stderr: 'broke' }, isError: true },
    { tool_use_id: 'notes', tool: 'Read', input: { file_path: '/repo/notes.md' }, result: {}, text: 'notes' },
    { tool_use_id: 'helper', tool: 'Agent', input: { description: 'Read the notes' }, result: {}, text: 'done', durationMs: 4000 },
  ] },
]
const TOOL = { isRunning: false, isErrored: false, isInterrupted: false } as const
const LOOSE_READ = { ...TOOL, tool_use_id: 'loose', tool: 'Read', input: { file_path: '/repo/notes.md' }, output: 'the notes' } as const

async function rowLines($: Engine, props: RenderPropsOf['ToolUse'], isFullscreen = false): Promise<string[]> {
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', requestId: props.tool_use_id, viewport: { columns: 80, rows: 24, isFullscreen }, props })
  const lines = shown(await row.drawn())
  await row.unmount()
  return lines
}

test('a tool row draws its mark, words, each chip and its chevron one cell apart', async ($, on) => {
  session(on, WORK, () => [], NORMAL_VIEW)
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine tool' }))
  expect(await rowLines($, { ...TOOL, tool_use_id: 'tests', tool: 'Bash', input: { command: 'npm test' }, output: 'ok\nok' })).toEqual(['○ Ran 2 shell commands · read 1 file 1 failed +4 lines ›'])
  expect(await rowLines($, LOOSE_READ)).toEqual(['○ Read notes.md +1 line ›'])
  expect(await rowLines($, { ...TOOL, tool_use_id: 'helper', tool: 'Agent', input: { description: 'Read the notes' }, output: 'done' })).toEqual(['Read the notes · finished · 4s ›'])
})

test('the steps line draws its chevron one cell after its words', async ($, on) => {
  session(on, WORK)
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine tool' }))
  expect(await rowLines($, { ...TOOL, tool_use_id: 'tests', tool: 'Bash', input: { command: 'npm test' }, output: 'ok\nok' })).toEqual(['· 3 steps ›'])
})

test('a pressable chevron draws as the bare glyph, dim like the one that cannot be pressed', async ($, on) => {
  session(on, WORK, () => [], NORMAL_VIEW)
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine tool' }))
  expect(await rowLines($, LOOSE_READ, true)).toEqual(['○ Read notes.md +1 line ›'])
  expect(await rowLines($, { ...TOOL, tool_use_id: 'helper', tool: 'Agent', input: { description: 'Read the notes' }, output: 'done' }, true)).toEqual(['Read the notes · finished · 4s ›'])
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', viewport: { columns: 80, rows: 24, isFullscreen: true }, props: LOOSE_READ })
  expect((await row.find({ type: 'Button' }))?.props.dimColor).toBe(true)
  await $.ui.press({ plugin: 'cs-feed', key: 'loose' })
  expect(shown(await row.drawn())).toEqual(['○ Read notes.md +1 line ⌄', 'the notes'])
  await row.unmount()
})

test('a helper whose call is still in flight reads as running, one state', async ($, on) => {
  session(on, WORK, () => [], NORMAL_VIEW)
  on('ui.render', { component: 'ToolUse' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine tool' }))
  expect(await rowLines($, { ...TOOL, isRunning: true, tool_use_id: 'working', tool: 'Agent', input: { description: 'Read the notes' } })).toEqual(['Read the notes · running ›'])
})

test('UserMessage draws the terminal you margin and leaves the desktop engine body intact', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'UserMessage' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine prompt' }) })
  const terminal = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await terminal.find({ type: 'Text', text: '❯' }))?.text).toBe('❯')
  expect((await terminal.find({ type: 'Text', text: '❯' }))?.props.color).toBe('#9fb4c8')
  expect((await terminal.find({ type: 'Text', text: 'Read the notes' }))?.text).toBe('Read the notes')
  expect(await terminal.find({ text: 'engine prompt' })).toBeUndefined()
  const desktop = await $.ui.mount({ plugin: 'cs-feed', surface: 'desktop', component: 'UserMessage', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await desktop.find({ type: 'Text' }))?.text).toBe('engine prompt')
  expect(calls).toBe(2)
  await terminal.unmount()
  await desktop.unmount()
})

test('UserMessage keeps the engine row for an origin the feed has no rule for, envelope text included', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const origins: PromptOrigin[] = [
    { kind: 'plugin', name: 'helper-plugin' },
    { kind: 'channel', server: 'example' },
    { kind: 'slack-ping' },
    { kind: 'auto-continuation' },
  ]
  for (const [index, origin] of origins.entries()) {
    const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: `row-${index}`, props: { text: '<teammate-message teammate_id="alice">Ready</teammate-message>', origin, isExpanded: false } })
    expect((await row.find({ type: 'Text' }))?.text).toBe('engine prompt')
    await row.unmount()
  }
})

test('UserMessage draws your text in the you ink, and a slash command with its name in that ink and its arguments dim', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const plain = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'plain', props: { text: 'Read the notes', origin: { kind: 'composer' }, isExpanded: false } })
  expect((await plain.find({ type: 'Text', text: 'Read the notes' }))?.props.color).toBe('#9fb4c8')
  const command = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'command', props: { text: '/feed clean now', origin: { kind: 'composer' }, isExpanded: false } })
  const name = await command.find({ type: 'Text', text: '/feed' })
  const args = await command.find({ type: 'Text', text: 'clean now' })
  expect([name?.text, name?.props.color, name?.props.dimColor]).toEqual(['/feed', '#9fb4c8', undefined])
  expect([args?.text, args?.props.dimColor]).toEqual(['clean now', true])
  await plain.unmount()
  await command.unmount()
})

test('UserMessage keeps hook feedback as a quiet circle line', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine prompt' }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', props: { text: 'Stop hook feedback:\nTests need another pass', origin: { kind: 'unclassified' }, isExpanded: false } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('○ Tests need another pass')
  await row.unmount()
})

test('AssistantMessage frames the engine markdown once under the terminal margin, with no name', async ($, on) => {
  session(on)
  const flags: boolean[] = []
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => { flags.push(e.props.isFirstOfReply); return $.ui.resolve(e).Text({ children: 'engine markdown' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AssistantMessage', props: { text: 'Here is the answer.', isFirstOfReply: true } })
  expect(await row.find({ type: 'Text', text: 'claude' })).toBeUndefined()
  expect((await row.find({ type: 'Text', text: 'engine markdown' }))?.text).toBe('engine markdown')
  expect(flags).toEqual([false])
  await row.unmount()
})

test('ToolUse draws a completed read with its own words and a fullscreen disclosure', async ($, on) => {
  session(on)
  let calls = 0
  on('ui.render', { component: 'ToolUse' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine tool' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolUse', viewport: { columns: 80, rows: 24, isFullscreen: true }, props: { tool_use_id: 'read', tool: 'Read', input: { file_path: '/repo/notes.md' }, isRunning: false, isErrored: false, isInterrupted: false, output: 'the notes' } })
  expect((await row.find({ type: 'Text', text: 'Read notes.md' }))?.text).toBe('Read notes.md')
  expect((await row.find({ type: 'Button' }))?.props.label).toBe('›')
  expect(calls).toBe(1)
  await $.ui.press({ plugin: 'cs-feed', key: 'read' })
  expect((await row.find({ type: 'Text', text: 'the notes' }))?.text).toBe('the notes')
  expect((await row.find({ type: 'Button' }))?.props.label).toBe('⌄')
  expect(calls).toBe(2)
  await row.unmount()
})

test('ToolResult hides a filed result while its own expanded row stays with the engine', async ($, on) => {
  session(on, [{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'read', tool: 'Read', input: {} }] }])
  let calls = 0
  on('ui.render', { component: 'ToolResult' }, ($, e) => { calls++; return $.ui.resolve(e).Text({ children: 'engine result' }) })
  const props = { tool_use_id: 'read', tool: 'Read', output: 'notes', isErrored: false }
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolResult', requestId: 'normal', props })
  expect(await row.findAll({ type: 'Text' })).toEqual([])
  const expanded = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolResult', requestId: 'expanded', props: { ...props, isExpanded: true } })
  expect((await expanded.find({ type: 'Text' }))?.text).toBe('engine result')
  expect(calls).toBe(2)
  await row.unmount()
  await expanded.unmount()
})

test('prompt peer observations group two stored messages under their first row', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'head', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'First update' }] } })
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'tail', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'Second update' }] } })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  expect((await row.find({ type: 'Text', text: '⇄' }))?.text.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  const tail = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'tail', props: { text: 'Second update', origin: { kind: 'peer' }, isExpanded: false } })
  expect(await tail.findAll({ type: 'Text' })).toEqual([])
  await row.unmount()
  await tail.unmount()
})

test('an already drawn peer head becomes a burst when the next peer arrives', async ($, on) => {
  const clock = session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'head', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'First update' }] } })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('⇄ another session · First update')
  await clock.settle()
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'tail', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'Second update' }] } })
  const tail = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'tail', props: { text: 'Second update', origin: { kind: 'peer' }, isExpanded: false } })
  await clock.settle()
  expect((await row.find({ type: 'Text', text: '⇄' }))?.text.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  expect(await tail.findAll({ type: 'Text' })).toEqual([])
  await row.unmount()
  await tail.unmount()
})

const PEER_MARK = { name: 'peer-mark', tier: 'prepend' as const, register(on: On) {
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    await $.ui.log('row-start')
    try { return await next(e) } finally { await $.ui.log('row-end') }
  })
} }

test('a burst head reads LIVE while its burst is open, and once your message closes it the feed never redraws it again', { plugins: [PEER_MARK] }, async ($, on) => {
  let rows: SessionMessage[] = []
  const clock = mock.clock(on)
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'on\n' } : { deny: 'ENOENT: no such file or directory' })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', ($, e) => ({ value: e.as === 'api' ? [] : rows }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  const evaluations: (string | undefined)[][] = []
  let drawing = false
  on('ui.log', ($, e) => { if (e.text === 'row-start') { drawing = true; evaluations.push([]) } if (e.text === 'row-end') drawing = false; return { value: undefined } })
  on('state.get', async ($, e, next) => { if (drawing) evaluations.at(-1)?.push(e.key); return next(e) })
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  const peer = (uuid: string, text: string) => $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid, message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text }] } })
  await peer('head', 'First update')
  await peer('tail', 'Second update')
  const head = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  await clock.settle()
  expect(evaluations.at(-1)).toEqual(['live'])
  rows = [{ role: 'user', text: 'Thanks, carry on', toolUses: [] }]
  await $.session.append({ door: 'prompt', origin: { kind: 'composer' }, uuid: 'mine', message: { type: 'user', role: 'user', content: [{ type: 'text', text: 'Thanks, carry on' }] } })
  await clock.settle()
  expect(evaluations.at(-1)).toEqual([])
  const settled = evaluations.length
  rows = [...rows, { role: 'assistant', text: 'Carrying on.', toolUses: [] }]
  await $.session.append({ door: 'response', origin: { kind: 'model', model: 'model' }, uuid: 'reply', message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: 'Carrying on.' }] } })
  await clock.settle()
  expect(evaluations.length).toBe(settled)
  expect((await head.find({ type: 'Text', text: '⇄' }))?.text.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  await head.unmount()
})

test('an opened burst shows each of its messages as its own indented line, once', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine peer' }))
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'head', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'First update' }] } })
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'tail', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: 'Second update' }] } })
  const viewport = { columns: 80, rows: 24, isFullscreen: true }
  const head = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'head', viewport, props: { text: 'First update', origin: { kind: 'peer' }, isExpanded: false } })
  const tail = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: 'tail', viewport, props: { text: 'Second update', origin: { kind: 'peer' }, isExpanded: false } })
  expect(await tail.findAll({ type: 'Text' })).toEqual([])
  await $.ui.press({ plugin: 'cs-feed', key: 'burst-head' })
  const headTexts = (await head.findAll({ type: 'Text' })).map(text => text.text)
  expect(headTexts.length).toBe(2)
  expect(headTexts[0]?.split(' · ').slice(0, 2)).toEqual(['⇄ 2 messages', 'another session'])
  expect(headTexts[1]).toBe('⇄ another session · First update')
  expect((await tail.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['⇄ another session · Second update'])
  const indent = async (row: typeof tail, text: string) => (await row.findAll({ type: 'Box' })).find(box => box.props.paddingLeft !== undefined && JSON.stringify(box.children).includes(text))?.props.paddingLeft
  expect(await indent(tail, 'Second update')).toBe(4)
  await head.unmount()
  await tail.unmount()
})

test('a helper report frame draws its verdict card, and a plain report its Markdown lead with the lines left out', async ($, on) => {
  session(on)
  on('ui.render', { component: 'UserMessage' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine report' }))
  const card = '<teammate-message teammate_id="reviewer" summary="Review">Looks good.\n\n{"status":"passed","target":{"name":"app","model":"small"},"checks":[{"status":"passed"},{"status":"failed"}],"notes":["one","two"],"report_file":"/tmp/out/report.md"}</teammate-message>'
  const lead = '<teammate-message teammate_id="docs" summary="Docs built">Built.\n\n- a\n- b</teammate-message>'
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'card', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: card }] } })
  await $.session.append({ door: 'prompt', origin: { kind: 'peer' }, uuid: 'lead', message: { type: 'user', role: 'user', isMeta: true, content: [{ type: 'text', text: lead }] } })
  const shown = async (uuid: string) => {
    const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'UserMessage', requestId: uuid, props: { text: 'stripped', origin: { kind: 'peer' }, isExpanded: false } })
    const all = (await row.findAll({})).filter(element => element.type === 'Text' || element.type === 'Markdown').map(element => `${element.type}:${element.text}`)
    await row.unmount()
    return all
  }
  expect(await shown('card')).toEqual([
    'Text:⇄ reviewer · Review',
    'Markdown:Looks good.',
    'Text:✓', 'Text:passed',
    'Text:target app · small',
    'Text:checks', 'Text:●', 'Text:●', 'Text:1 of 2 pass',
    'Text:notes', 'Text:2', 'Text:· one',
    'Text:report report.md',
    'Text:ctrl+o shows the whole report',
  ])
  expect(await shown('lead')).toEqual([
    'Text:⇄ docs · Docs built',
    'Markdown:Built.',
    'Text:+2 more lines · ctrl+o shows all',
  ])
})

test('SessionMode appends the feed mode while preserving the engine modes', async ($, on) => {
  session(on)
  on('ui.render', { component: 'SessionMode' }, ($, e) => $.ui.resolve(e).Text({ children: e.props.modes.join(' | ') }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'SessionMode', props: { modes: ['auto mode on'] } })
  expect((await row.find({ type: 'Text' }))?.text).toBe('auto mode on | feed clean · /feed to switch')
  await row.unmount()
})

test('CommandOutput draws the cleaned command answer beside a dim dot', async ($, on) => {
  session(on)
  on('ui.render', { component: 'CommandOutput' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine command' }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'CommandOutput', props: { command: 'feed', args: 'clean', text: 'cs-feed: Chat view: clean.', isErrored: false } })
  expect((await row.find({ type: 'Text', text: 'Chat view: clean.' }))?.text).toBe('Chat view: clean.')
  expect((await row.find({ type: 'Text', text: '·' }))?.text).toBe('·')
  expect((await row.find({ type: 'Text', text: 'Chat view: clean.' }))?.props.dimColor).toBe(true)
  await row.unmount()
})

const BAND = { hasSurvey: false, maxRows: 6, bodyColumns: 90, scroll: { offset: 0, bodyRows: 6 }, view: {} } as const
const SPAWN = { prompt: 'Work', provider: { plugin: 'engine', tier: 'core' }, parentModel: 'model', background: false, fork: false } as const

// The tokens a band evaluation reads, told apart from the clocks' own reads:
// a prepend-tier plugin (its own environment, so it speaks through ui.log)
// marks each AbovePrompt evaluation in flight above cs-feed's hook.
const BAND_MARK = { name: 'band-mark', tier: 'prepend' as const, register(on: On) {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    await $.ui.log('band-start')
    try { return await next(e) } finally { await $.ui.log('band-end') }
  })
} }
function bandReads(on: On, reads: string[]) {
  let drawing = false
  on('ui.log', ($, e) => { if (e.text === 'band-start') drawing = true; if (e.text === 'band-end') drawing = false; return { value: undefined } })
  on('state.get', async ($, e, next) => { if (drawing) reads.push(e.key); return next(e) })
}

test('an idle band with nothing to show reads no redraw token and is not redrawn while the clocks run', { plugins: [BAND_MARK] }, async ($, on) => {
  const clock = session(on)
  const reads: string[] = []
  let evaluations = 0
  bandReads(on, reads)
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => { evaluations++; return $.ui.resolve(e).Text({ children: 'engine band' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AbovePrompt', props: { ...BAND, isWorking: false } })
  await clock.settle()
  const settled = evaluations
  await clock.advance(3000)
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine band'])
  expect(reads).toEqual([])
  expect(evaluations).toBe(settled)
  await row.unmount()
})

test('helpers spawned in a turn reach the band through the spawn, and a vanished helper keeps its kind', { plugins: [BAND_MARK] }, async ($, on) => {
  let agents: AgentInfo[] = []
  const clock = session(on, [], () => agents)
  const reads: string[] = []
  bandReads(on, reads)
  on('agent.spawn', ($, e) => ({ model: 'model', agentId: e.tool_use_id === 'read-call' ? 'reader' : 'planner' }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine band' }))
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'AbovePrompt', props: { ...BAND, isWorking: true } })
  await clock.settle()
  expect((await row.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['engine band'])
  expect([...new Set(reads)]).toEqual(['live'])
  agents = [{ id: 'reader', type: 'Explore', description: 'Read notes', status: 'pending' }, { id: 'planner', type: 'Plan', description: 'Make a plan', status: 'running' }]
  await $.agent.spawn({ ...SPAWN, tool_use_id: 'read-call', description: 'Read notes', subagentType: 'Explore' })
  await $.agent.spawn({ ...SPAWN, tool_use_id: 'plan-call', description: 'Make a plan', subagentType: 'Plan' })
  await clock.settle()
  expect((await row.find({ type: 'Text', text: '2 helpers' }))?.text.split(' · ').slice(0, 2)).toEqual(['2 helpers', '2 running'])
  expect((await row.findAll({ type: 'Text' })).at(-1)?.text).toBe('engine band')
  expect([...new Set(reads)].sort()).toEqual(['live', 'pulse', 'tick'])
  agents = [{ id: 'reader', type: 'Explore', description: 'Read notes', status: 'pending' }]
  await clock.advance(1000)
  expect((await row.find({ type: 'Text', text: '2 helpers' }))?.text.split(' · ').slice(0, 3)).toEqual(['2 helpers', '1 done', '1 running'])
  expect((await row.find({ type: 'Text', text: 'Plan' }))?.text).toBe('Plan')
  await row.unmount()
})

test('ToolGroup draws known helpers as a batch and opens their names without unfolding the engine group', async ($, on) => {
  const calls = [
    { tool_use_id: 'reader', tool: 'Agent', input: { description: 'Read the notes', subagent_type: 'Explore' }, isRunning: true, isErrored: false, isInterrupted: false },
    { tool_use_id: 'planner', tool: 'Agent', input: { description: 'Plan the change', subagent_type: 'Plan' }, isRunning: false, isErrored: false, isInterrupted: false },
  ]
  session(on, [{ role: 'assistant', text: '', toolUses: calls }])
  const expanded: boolean[] = []
  on('ui.render', { component: 'ToolGroup' }, ($, e) => { expanded.push(e.props.isExpanded); return $.ui.resolve(e).Text({ children: 'engine group' }) })
  const row = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'ToolGroup', viewport: { columns: 80, rows: 24, isFullscreen: true }, props: { calls, isActive: true, isExpanded: false, isCallsOnly: true } })
  expect((await row.find({ type: 'Text', text: '2 helpers' }))?.text).toBe('2 helpers · 1 done · 1 running')
  expect(shown(await row.drawn())[0]?.slice(2)).toBe('2 helpers · 1 done · 1 running ›')
  expect((await row.find({ type: 'Text', text: 'Explore' }))?.text).toBe('Explore')
  expect((await row.find({ type: 'Text', text: 'Plan' }))?.text).toBe('Plan')
  expect(await row.find({ type: 'Text', text: 'Read the notes' })).toBeUndefined()
  await $.ui.press({ plugin: 'cs-feed', key: 'helpers-reader' })
  expect((await row.find({ type: 'Text', text: 'Read the notes' }))?.text).toBe('Read the notes')
  expect((await row.find({ type: 'Text', text: 'Plan the change' }))?.text).toBe('Plan the change')
  expect(expanded).toEqual([false, false])
  await row.unmount()
})

test('the settings pane stays usable while off and pressing group enables this session with that field changed', async ($, on) => {
  const files = new Map([['/session/.cs/local/feed', 'off\n']])
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => { const value = files.get(e.path); return value === undefined ? { deny: 'ENOENT: no such file or directory' } : { value } })
  on('fs.exists', () => ({ value: true }))
  on('fs.write', ($, e) => { files.set(e.path, e.text); return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: '/bin/cs' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  mock.clock(on)
  on('ui.render', { component: 'Pane' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine pane' }))
  const pane = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Pane', requestId: 'cs-feed', props: { title: 'Chat view', isFocused: true, placement: 'inline', bodyColumns: 80, scroll: { offset: 0, bodyRows: 24 }, view: {} } })
  expect((await pane.find({ type: 'Text', text: 'Chat view' }))?.text).toBe('Chat view')
  expect((await pane.find({ type: 'Text', text: 'raw' }))?.text).toBe('raw')
  expect((await pane.find({ type: 'Button', key: 'btn-group' }))?.props.label).toBe('Group a turn into one line')
  expect((await pane.find({ type: 'Text', text: /\/feed group/ }))?.text).toBe('· /feed group off')
  await $.ui.press({ plugin: 'cs-feed', key: 'btn-group' })
  expect(files.get('/session/.cs/local/feed')).toBe('on\n')
  expect(files.get('/session/.cs/local/feed-view')).toBe('{"group":false,"clear":true,"keep":false,"style":"subtle","commands":"grouped","after":"clear","hide":[]}\n')
  expect((await pane.find({ type: 'Text', text: 'custom' }))?.text).toBe('custom')
  await pane.unmount()
})

test('the settings pane draws every Show chip, on two rows in an 80-column pane and on one at 120', async ($, on) => {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('config.list', () => ({ value: [] }))
  on('ui.render', { component: 'Pane' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine pane' }))
  // Inside the frame: 76 cells at 80 columns, 116 at 120.
  const chips = async (bodyColumns: number) => {
    const pane = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Pane', requestId: 'cs-feed', props: { title: 'Chat view', isFocused: true, placement: 'inline', bodyColumns, scroll: { offset: 0, bodyRows: 24 }, view: {} } })
    const lines = shown(await pane.drawn(), bodyColumns)
    await pane.unmount()
    const show = lines.indexOf('Show')
    return lines.slice(show + 1, lines.findIndex((line, i) => i > show && line.startsWith('/feed hide')))
  }
  expect(await chips(76)).toEqual(['[ ● you ] [ ● said ] [ ● tool ] [ ● agent ] [ ● question ] [ ● peer ]', '[ ● helper ] [ ● search ]'])
  expect(await chips(116)).toEqual(['[ ● you ] [ ● said ] [ ● tool ] [ ● agent ] [ ● question ] [ ● peer ] [ ● helper ] [ ● search ]'])
})

test('a refused settings-pane press writes nothing and logs the refusal once without the plugin name', async ($, on) => {
  const writes: string[] = []
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', ($, e) => e.path.endsWith('/feed') ? { value: 'off\n' } : { deny: 'ENOENT: no such file or directory' })
  on('fs.exists', () => ({ value: true }))
  on('fs.write', ($, e) => { writes.push(e.path); return { value: undefined } })
  on('env.get', { name: 'CS_BIN' }, () => ({ value: undefined }))
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'Pane' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine pane' }))
  const pane = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Pane', requestId: 'cs-feed', props: { title: 'Chat view', isFocused: true, placement: 'inline', bodyColumns: 80, scroll: { offset: 0, bodyRows: 24 }, view: {} } })
  await $.ui.press({ plugin: 'cs-feed', key: 'btn-group' })
  expect(writes).toEqual([])
  expect(logs).toEqual(['no feed change in this session: the launch did not say where cs is (CS_BIN)'])
  await pane.unmount()
})

const HELPERS_PANE = { title: 'Helpers', isFocused: true, placement: 'inline', bodyColumns: 80, scroll: { offset: 0, bodyRows: 24 }, view: {} } as const

test('the helpers pane says when no helper ran, whatever the toggle says', async ($, on) => {
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('session.messages', () => ({ value: [] }))
  on('agent.list', () => ({ value: [] }))
  on('ui.render', { component: 'Pane' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine pane' }))
  const pane = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Pane', requestId: 'cs-feed-helpers', props: HELPERS_PANE })
  expect((await pane.findAll({ type: 'Text' })).map(text => text.text)).toEqual(['No helper ran in this session.'])
  await pane.unmount()
})

test('the helpers pane shows the newest helpers first with their state, step and own calls, and keeps a head whose transcript is unreadable', async ($, on) => {
  const main: SessionMessage[] = [
    { role: 'user', text: 'Look around', toolUses: [] },
    { role: 'assistant', text: '', toolUses: [
      { tool_use_id: 'read-call', tool: 'Agent', input: { description: 'Read the notes' }, result: {}, text: 'done', agentId: 'reader', durationMs: 4000 },
      { tool_use_id: 'plan-call', tool: 'Agent', input: { description: 'Make a plan' }, agentId: 'planner' },
      { tool_use_id: 'gone-call', tool: 'Agent', input: { description: 'Check the build' }, result: {}, text: 'failed', isError: true, agentId: 'checker', durationMs: 2000 },
    ] },
  ]
  const own: Record<string, SessionMessage[]> = {
    reader: [{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'r1', tool: 'Read', input: { file_path: '/repo/notes.md' }, result: {}, text: 'notes' }] }],
    planner: [{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'p1', tool: 'Grep', input: {}, result: {}, text: 'hits' }, { tool_use_id: 'p2', tool: 'Edit', input: { file_path: '/repo/plan.md' } }] }],
  }
  const logs: string[] = []
  on('session.cwd', () => ({ value: '/session' }))
  on('fs.read', () => ({ deny: 'ENOENT: no such file or directory' }))
  on('session.messages', ($, e) => {
    if (e.agentId === undefined) return { value: e.as === 'api' ? [] : main }
    const rows = own[e.agentId]
    return { value: rows ?? { deny: `no transcript for ${e.agentId}` } }
  })
  on('agent.list', () => ({ value: [
    { id: 'reader', type: 'Explore', description: 'Read the notes', status: 'completed' },
    { id: 'planner', type: 'Plan', description: 'Make a plan', status: 'running' },
    { id: 'checker', type: 'general-purpose', description: 'Check the build', status: 'failed' },
  ] }))
  on('ui.log', ($, e) => { logs.push(e.text); return { value: undefined } })
  on('ui.render', { component: 'Pane' }, ($, e) => $.ui.resolve(e).Text({ children: 'engine pane' }))
  const pane = await $.ui.mount({ plugin: 'cs-feed', surface: 'terminal', component: 'Pane', requestId: 'cs-feed-helpers', props: HELPERS_PANE })
  const texts = (await pane.findAll({ type: 'Text' })).map(text => text.text)
  expect(texts).toEqual([
    '○', 'Check the build · failed · 2s',
    '●', 'Make a plan · working',
    'now: Editing plan.md',
    'Searched the code', 'Editing plan.md',
    '○', 'Read the notes · finished · 4s',
    'Read notes.md',
  ])
  expect(logs).toEqual(["could not read helper checker's transcript: no transcript for checker"])
  await pane.unmount()
})

