// ABOUTME: Unit tests for the cs-update mod against a fake engine `$`.
// ABOUTME: Covers the span parser, the once-per-load gate (env, option, lead, tombstone), the pane body, the update key and /cs-update.
import { test, expect, beforeEach } from 'bun:test'

;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, parseSpan, stripInline, PANE, OPTION, HEARTBEAT } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let envVars: Record<string, string | undefined>
let files: Record<string, string>
let written: Record<string, string>
let panes: { op: 'open' | 'close'; args: any }[]
let toasts: string[]
let invalidated: string[]
let runs: { argv: string[]; init: any }[]
let runResult: { exitCode: number; stdout: string; stderr: string } | Error
let commands: any[]
let sessionId: string

// The default runner: records the call and answers with `runResult`. A test
// that swaps it in (for a run held in flight) gets it back in beforeEach.
const defaultRun = async (argv: string[], init: any) => {
  runs.push({ argv, init })
  if (runResult instanceof Error) throw runResult
  return runResult
}

const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: { id: async () => sessionId, cwd: async () => '/work' },
  fs: {
    read: async (path: string) => { if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
    exists: async (path: string) => path in files || path === '/work/.cs/local',
    write: async (path: string, text: string) => { written[path] = text },
  },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }),
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    toast: (text: string) => { toasts.push(text) },
    invalidate: (event: string) => { invalidated.push(event) },
  },
  process: { run: defaultRun as (argv: string[], init: any) => Promise<any> },
  command: { register: async (spec: any) => { commands.push(spec); return { command: spec.name } } },
}

const SPAN = `## 2026.99.3

One fix: the statusline is readable on light terminals.

### Fixes

- **Statusline: readable.** The \`chiptext\` token was **wrong** in [two places](https://example.com/x).
  A continuation line.

## 2026.99.2

One change: the locked-session menu is single-keypress.

### Changed

- **Menu: keypress.** Cancel stays the default.
`

const start = () => hooks['session.start']($, { cwd: '/work' }, async () => 'started')
const opens = () => panes.filter(p => p.op === 'open')
// A `.map()` inside JSX lands as an array child, so both walkers flatten
// arrays before reading an element's children.
function texts(tree: any): string[] {
  if (typeof tree === 'string') return [tree]
  if (Array.isArray(tree)) return tree.flatMap(texts)
  if (!tree || typeof tree !== 'object') return []
  return (tree.children ?? []).flatMap(texts)
}
function buttons(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(buttons)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
function headings(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(headings)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Text' && tree.props.bold && tree.props.color) return [tree]
  return (tree.children ?? []).flatMap(headings)
}
const draw = () => hooks['ui.render:Pane']($, { requestId: PANE }, async () => 'other')

function load(options: Record<string, unknown> = {}) {
  for (const k of Object.keys(hooks)) delete hooks[k]
  register(on as any, { [OPTION]: true, ...options } as any)
}

beforeEach(() => {
  envVars = { CS_UPDATE_AVAILABLE: '2026.99.3', CS_UPDATE_BIN: '/opt/cs/bin/cs', HOME: '/home/u' }
  files = {
    '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n',
    '/home/u/.cache/cs/update-notes-full-2026.99.3': SPAN,
  }
  written = {}; panes = []; toasts = []; invalidated = []; runs = []; commands = []
  runResult = { exitCode: 0, stdout: 'ok', stderr: '' }
  ;($ as any).process.run = defaultRun
  sessionId = 'uuid-lead'
  load()
})

test('stripInline drops links, bold and code marks and keeps the words', () => {
  expect(stripInline('The `chiptext` token was **wrong** in [two places](https://example.com/x).'))
    .toBe('The chiptext token was wrong in two places.')
})

test('stripInline strips an unpaired ** and an unpaired backtick too', () => {
  expect(stripInline('a **b `c')).toBe('a b c')
})

test('parseSpan yields one section per version with prose and bullets, headings and blanks dropped', () => {
  const sections = parseSpan(SPAN)
  expect(sections.map(s => s.version)).toEqual(['2026.99.3', '2026.99.2'])
  expect(sections[0].lines).toEqual([
    'One fix: the statusline is readable on light terminals.',
    '- Statusline: readable. The chiptext token was wrong in two places.',
    '  A continuation line.',
  ])
  expect(sections[1].lines).toEqual([
    'One change: the locked-session menu is single-keypress.',
    '- Menu: keypress. Cancel stays the default.',
  ])
})

test('parseSpan of an empty file is no sections', () => {
  expect(parseSpan('')).toEqual([])
})

test('session.start opens the pane once per load and writes the heartbeat', async () => {
  expect(await start()).toBe('started')
  expect(opens()).toHaveLength(1)
  expect(opens()[0].args).toMatchObject({ id: PANE, title: 'cs 2026.99.3 is available', closeOnEscape: true, focus: true })
  expect(written['/work/' + HEARTBEAT]).toMatch(/^\d{4}-/)
  await start()
  expect(opens()).toHaveLength(1)
})

test('no pending version, no pane, no toast', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(opens()).toHaveLength(0)
  expect(toasts).toEqual([])
})

test('the option off skips the launch pane', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
})

test('a teammate (a session that is not the one cs launched) gets no pane', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(opens()).toHaveLength(0)
})

test('a quoted id in the state file still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: "uuid-lead"\n'
  await start()
  expect(opens()).toHaveLength(1)
})

test('no state file (not a cs session) means no pane', async () => {
  delete files['/work/.cs/local/state']
  await start()
  expect(opens()).toHaveLength(0)
})

test('the pane draws the title, every version in the session colour, its lines, and the two keys', async () => {
  await start()
  const tree = await draw()
  const words = texts(tree).join('\n')
  // A lone pane draws no title of its own, so the body carries it.
  expect(words).toContain('cs 2026.99.3 is available')
  expect(headings(tree).map(t => [t.props.color, texts(t).join('')])).toEqual([['red', '2026.99.3'], ['red', '2026.99.2']])
  expect(words).toContain('One fix: the statusline is readable on light terminals.')
  expect(words).toContain('- Menu: keypress. Cancel stays the default.')
  // A continuation line hangs under its bullet: it is indented, not run on.
  const cont = texts(tree).find(t => t.includes('A continuation line.'))
  expect(cont).toBe('  A continuation line.')
  const keys = buttons(tree)
  expect(keys.map(b => b.props.hotkey)).toEqual(['1'])
  expect(keys[0].props.label).toBe('update now')
  expect(words).toContain('Esc: later')
  expect(words).toContain('Installs in place; the new files take effect on your next launch.')
})

test('a tombstone (empty notes file) still opens the pane with the fallback body', async () => {
  files['/home/u/.cache/cs/update-notes-full-2026.99.3'] = ''
  await start()
  expect(opens()).toHaveLength(1)
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Release notes could not be fetched at launch; the update is 2026.99.3.')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a missing notes file reads as the tombstone', async () => {
  delete files['/home/u/.cache/cs/update-notes-full-2026.99.3']
  await start()
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('could not be fetched')
})

test('another pane id is not the mod\'s to draw', async () => {
  await start()
  expect(await hooks['ui.render:Pane']($, { requestId: 'someone-else' }, async () => 'other')).toBe('other')
})

test('a directory opted out of cs (.cs/local/disabled) gets no pane', async () => {
  files['/work/.cs/local/disabled'] = ''
  await start()
  expect(opens()).toHaveLength(0)
})

test('1 runs cs -update once, by the exported path, with a ten-minute timeout, and reports the install', async () => {
  await start()
  // The key is gone from the redraw once pressed, so the callback is kept
  // and pressed twice; the run is held in flight so the second press lands
  // while the first is running.
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => { runs.push({ argv, init }); return new Promise(r => { release = r }) }
  const press = buttons(await draw())[0].props.onPress
  const first = press()
  const second = press()
  await Promise.resolve()
  release({ exitCode: 0, stdout: '', stderr: '' })
  await first; await second
  expect(runs).toHaveLength(1)
  expect(runs[0].argv).toEqual(['/opt/cs/bin/cs', '-update'])
  expect(runs[0].init).toMatchObject({ timeoutMs: 600000 })
  const words = texts(await draw()).join('\n')
  // Version-neutral: cs -update installs whatever is latest when pressed,
  // which may be newer than the launch saw.
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(buttons(await draw())).toHaveLength(0)
  expect(invalidated).toContain('ui.render')
})

test('a second press returns at the running guard before any lookup', async () => {
  await start()
  let giveBin!: (v: any) => void
  ;($ as any).env.get = async (name: string) => name === 'CS_UPDATE_BIN' ? new Promise(r => { giveBin = r }) : envVars[name]
  const press = buttons(await draw())[0].props.onPress
  const a = press(); const b = press()
  await Promise.resolve()
  giveBin('/opt/cs/bin/cs')
  await a; await b
  ;($ as any).env.get = async (name: string) => envVars[name]
  expect(runs).toHaveLength(1)
})

test('while the update runs the pane says so and hides the key', async () => {
  await start()
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => { runs.push({ argv, init }); return new Promise(r => { release = r }) }
  const pressed = buttons(await draw())[0].props.onPress()
  await Promise.resolve()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('updating')
  expect(buttons(await draw())).toHaveLength(0)
  release({ exitCode: 0, stdout: '', stderr: '' })
  await pressed
})

test('a non-zero exit shows the last stderr lines and keeps the key for another try', async () => {
  await start()
  runResult = { exitCode: 1, stdout: '', stderr: 'a\nb\nc\nd\ne\nf\nchecksum mismatch\n' }
  await buttons(await draw())[0].props.onPress()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('cs -update exited 1')
  expect(words).toContain('checksum mismatch')
  expect(words).not.toContain('\na\n')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a run that cannot start shows the rejection', async () => {
  await start()
  runResult = new Error('spawn ENOENT')
  await buttons(await draw())[0].props.onPress()
  expect(texts(await draw()).join('\n')).toContain('spawn ENOENT')
})

test('no CS_UPDATE_BIN means the key says so instead of running nothing', async () => {
  delete envVars.CS_UPDATE_BIN
  await start()
  await buttons(await draw())[0].props.onPress()
  expect(runs).toHaveLength(0)
  expect(texts(await draw()).join('\n')).toContain('cs -update')
})

test('the mod registers /cs-update at load', async () => {
  await start()
  expect(commands.map(c => c.name)).toEqual(['cs-update'])
})

const runCommand = () => hooks['command.run:cs-update']($, { command: 'cs-update', args: '', cwd: '/work' }, async () => ({ text: 'unhandled' }))

test('/cs-update reopens the pane after a dismiss, and with the option off, and answers the command', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
  expect(await runCommand()).toEqual({ text: '' })
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('2026.99.3')
})

test('/cs-update with nothing pending says so as its output and opens nothing', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(await runCommand()).toEqual({ text: 'This launch found no newer cs; the check runs again at the next launch.' })
  expect(opens()).toHaveLength(0)
})

test('/cs-update in a teammate opens nothing', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(await runCommand()).toEqual({ text: 'The release-notes pane belongs to the conversation cs launched.' })
  expect(opens()).toHaveLength(0)
})
