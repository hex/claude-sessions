// ABOUTME: Unit tests for the cs-rotate mod against a fake engine `$`.
// ABOUTME: Covers the band's gate (crit, working, survey), the three presses and the wrap key's two-press guard, the armed handoff, and the heartbeat.
import { test, expect, beforeEach } from 'bun:test'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, DEFAULT_PERCENT, GRACE_SECONDS, PREVIEW_PANE, WRAP_QUESTION, WRAP_YES, MARKDOWN_LIMIT, nextStep, surfaceColor, isUnconsumed } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let percent: number | undefined
let filled: any[]
let ran: any[]
let written: Record<string, string>
let existing: Set<string>
let files: Record<string, string>
let sessionId: string
let envVars: Record<string, string | undefined>
let timers: { ms: number; fn: () => void; kind: 'after' | 'every'; cancelled: boolean }[]
let invalidated: string[]
let toasts: string[]
let asks: { question: string; options: any }[]
let panes: { op: 'open' | 'close'; args: any }[]
// What the person does with the next dialog: a label, or a rejection (dismissed, or a `-p` run).
let answer: string | Error
const timer = (kind: 'after' | 'every') => (ms: number, fn: () => void) => {
  const t = { ms, fn, kind, cancelled: false }
  timers.push(t)
  return { cancel: () => { t.cancelled = true } }
}
const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: {
    usage: async () => ({ context: { percent } }),
    cwd: async () => '/work',
    id: async () => sessionId,
  },
  prompt: { fill: async (args: any) => { filled.push(args); return { isFilled: true } } },
  command: { run: async (args: any) => { ran.push(args); return { text: '' } } },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button', Markdown: 'Markdown' }),
    invalidate: (event: string) => { invalidated.push(event) },
    toast: (text: string) => { toasts.push(text) },
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    ask: async (question: string, options: any) => {
      asks.push({ question, options })
      if (answer instanceof Error) throw answer
      return answer
    },
  },
  clock: { after: timer('after'), every: timer('every') },
  fs: {
    write: async (path: string, text: string) => { written[path] = text; files[path] = text },
    exists: async (path: string) => existing.has(path) || path in files,
    read: async (path: string) => { if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
  },
}

const DRAWN = { type: 'Survey', props: {}, children: [] }
const band = (props: Partial<{ isWorking: boolean; hasSurvey: boolean }> = {}) =>
  hooks['ui.render:AbovePrompt']($, { props: { isWorking: false, hasSurvey: false, ...props } }, async () => DRAWN)

function buttons(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
const findButton = (tree: any) => buttons(tree)[0]

beforeEach(() => {
  for (const k of Object.keys(hooks)) delete hooks[k]
  percent = undefined; filled = []; ran = []; written = {}; existing = new Set(['/work/.cs/local'])
  timers = []; invalidated = []; toasts = []; asks = []; answer = WRAP_YES; panes = []
  // The default fixture is the lead conversation of a cs session.
  sessionId = 'uuid-lead'
  envVars = {}
  files = { '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n' }
  register(on as any)
})

test('the default threshold is the statusline warn band', () => {
  expect(DEFAULT_PERCENT).toBe(40)
})

test('CS_STATUSLINE_CTX_WARN moves the band with the bar', async () => {
  envVars.CS_STATUSLINE_CTX_WARN = '50'
  percent = 49
  expect(await band()).toBe(DRAWN)
  percent = 50
  expect(findButton(await band())).toBeDefined()
  envVars.CS_ROTATE_BUTTON_CTX = '10'
  percent = 10
  expect(findButton(await band())).toBeDefined()
})

test('below the threshold the band passes the drawn tree through untouched', async () => {
  percent = 39
  expect(await band()).toBe(DRAWN)
})

test('CS_ROTATE_BUTTON_CTX in the process environment sets the threshold', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = '55'
  percent = 54
  expect(await band()).toBe(DRAWN)
  percent = 55
  expect(findButton(await band())).toBeDefined()
})

test('an unusable CS_ROTATE_BUTTON_CTX falls back to the default', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = 'soon'
  percent = 39
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band())).toBeDefined()
})

test('a quoted claude_session_id in state still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_id: "uuid-lead"  \n'
  percent = 40
  expect(findButton(await band())).toBeDefined()
})

test('at the threshold the band adds the rotate key on hotkey 1, first, beneath what was drawn', async () => {
  percent = 40
  const tree = await band()
  expect(tree).not.toBe(DRAWN)
  expect(buttons(tree)).toHaveLength(2)
  const button = findButton(tree)
  expect(button.props.hotkey).toBe('1')
  expect(button.props.plain).toBe(true)
  // The engine draws the hotkey itself, as "1: label", and it draws that
  // prefix even for an empty label (measured live), so the wording stays on
  // the button rather than being spelled beside it.
  expect(button.props.label).toBe('rotate this conversation')
  const json1 = JSON.stringify(tree)
  expect(json1).toContain('"Survey"')
  expect(json1).not.toContain('"children":["1"]')
  expect(json1).not.toContain('borderStyle')
})

test('the band draws no context gauge: the status bar already carries it', async () => {
  percent = 71
  const tree = JSON.stringify(await band())
  expect(tree).not.toContain('ctx')
  expect(tree).not.toContain('71%')
})

// One blank line above it, and the status bar's own capsule surface under it,
// so the keys read as a band of their own rather than as the last row of
// whatever the transcript ended with.
test('the band sits a line clear of what is above it, on the bar\'s capsule surface', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  percent = 40
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"marginTop":1')
  expect(tree).toContain('"backgroundColor":"rgb(226,222,206)"')
})

test('without a measured terminal background the band keeps the spacing and paints no surface', async () => {
  percent = 40
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"marginTop":1')
  expect(tree).not.toContain('backgroundColor')
})

// KEEP IN SYNC with _bg_shade in bin/cs-statusline (tests/test_mod_rotate.sh
// pins the shift against that file): a tenth away from the background's own
// luminance, darker on a light terminal and lighter on a dark one.
test('the surface is the shade the status bar shades the terminal background to', () => {
  expect(surfaceColor('252;247;229')).toBe('rgb(226,222,206)')
  expect(surfaceColor('30;30;30')).toBe('rgb(52,52,52)')
  expect(surfaceColor(undefined)).toBeUndefined()
  expect(surfaceColor('not a colour')).toBeUndefined()
  expect(surfaceColor('252;247')).toBeUndefined()
  expect(surfaceColor('252;247;300')).toBeUndefined()
})

// A bare line: no box to draw, so no border to light up under the pointer and
// no mark in front of the keys. The key stays: it is the band's identity.
test('the capsule is a keyed box with no border, no hover and no mark', async () => {
  percent = 40
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"key":"cs-rotate-band"')
  expect(tree).not.toContain('borderStyle')
  expect(tree).not.toContain('borderColor')
  expect(tree).not.toContain('hover')
  expect(tree).not.toContain('\u2733')
  expect(tree).not.toContain('"claude"')
})

test('while a turn runs the button is hidden', async () => {
  percent = 90
  expect(await band({ isWorking: true })).toBe(DRAWN)
})

test('while a survey holds the band the hook yields', async () => {
  percent = 90
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
})

test('an unknown percentage draws nothing', async () => {
  percent = undefined
  expect(await band()).toBe(DRAWN)
})

test('a press runs the rotate skill and fills nothing', async () => {
  percent = 80
  const button = findButton(await band())
  await button.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
  expect(filled).toEqual([])
})

test('outside a cs session the band draws nothing at crit', async () => {
  percent = 90
  existing = new Set(); files = {}
  expect(await band()).toBe(DRAWN)
})

test('a session opted out with .cs/local/disabled gets no button', async () => {
  percent = 90
  existing.add('/work/.cs/local/disabled')
  expect(await band()).toBe(DRAWN)
})

test('a teammate conversation (not the one .cs/local/state names) gets no button', async () => {
  percent = 90
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('with no state file to name the lead the band draws nothing', async () => {
  percent = 90
  files = {}
  expect(await band()).toBe(DRAWN)
})

const MARKER = '/work/.cs/local/pending-handoff'
const HANDOFF = '/work/.cs/handoffs/2026-09-15-next-step.md'
const UNCONSUMED = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n## 1. Next Step\n'
// Armed the way the rotate skill leaves it: an unconsumed handoff, then the marker.
const arm = () => { files[HANDOFF] = UNCONSUMED; files[MARKER] = '2026-09-15-next-step.md\n' }

test('an armed handoff turns the button into the clear button, whatever the context', async () => {
  arm()
  for (const p of [undefined, 3, 90]) {
    percent = p
    const tree = await band()
    expect(buttons(tree)).toHaveLength(1)
    const button = findButton(tree)
    expect(button.props.hotkey).toBe('1')
    expect(button.props.plain).toBe(true)
    expect(findButton(tree).props.label).toBe('/clear and continue from the handoff')
    const json = JSON.stringify(tree)
    expect(json).not.toContain('borderStyle')
    expect(json).not.toContain('borderColor')
    expect(json).not.toContain('undefined')
    expect(json).not.toContain('ctx')
  }
})

test('pressing the clear button runs /clear and fills nothing', async () => {
  arm(); percent = 3
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(filled).toEqual([])
})

test('the rotate press never clears', async () => {
  percent = 80
  await findButton(await band()).props.onPress()
  expect(ran).not.toContainEqual({ command: 'clear', args: '' })
})

test('an armed handoff is still lead-only and yields to a running turn', async () => {
  arm(); percent = 90
  expect(await band({ isWorking: true })).toBe(DRAWN)
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('a marker naming a handoff that is gone, consumed, or outside the store does not arm', async () => {
  percent = 39
  arm(); delete files[HANDOFF]
  expect(await band()).toBe(DRAWN)
  arm(); files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  expect(await band()).toBe(DRAWN)
  arm(); files[HANDOFF] = '## no frontmatter\nstatus: unconsumed\n'
  expect(await band()).toBe(DRAWN)
  arm(); files[MARKER] = '../local/state\n'
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band()).props.label).toBe('rotate this conversation')
})

test('an empty marker names no handoff, so the band behaves as unarmed', async () => {
  files[MARKER] = '\n'
  percent = 39
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band()).props.label).toBe('rotate this conversation')
})

test('session.start writes a heartbeat under the session meta dir', async () => {
  const r = await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(r).toEqual({ cwd: '/work' })
  const text = written['/work/.cs/local/cs-rotate.heartbeat']
  expect(text).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z\n$/)
})

test('outside a cs session no heartbeat is written', async () => {
  await hooks['session.start']($, { cwd: '/plain', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

// A turn's end, the way the engine reports it: answered on the main loop unless said otherwise.
const turnComplete = (e: Partial<{ reason: string; agentId: string }> = {}) =>
  hooks['turn.complete']($, { reason: 'answer', answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', ...e }, async () => ({ text: 'ok' }))
// The pending `after` timers, run the way the clock would run them.
const fireAfter = async () => { for (const t of timers.filter(t => t.kind === 'after' && !t.cancelled)) { t.cancelled = true; await t.fn() } }

test('with CS_ROTATE_FORCE_CTX set, a turn ending past it schedules /rotate from a timer, not from the hook', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 70
  await turnComplete()
  expect(ran).toEqual([])
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('without CS_ROTATE_FORCE_CTX a turn ending past the 80% default forces a rotation', async () => {
  percent = 80
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('under the default a turn ending below 80% forces nothing', async () => {
  percent = 79
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
})

test('CS_ROTATE_FORCE_CTX=off, and 0, turn the forcing off entirely', async () => {
  for (const value of ['off', 'OFF', '0']) {
    envVars.CS_ROTATE_FORCE_CTX = value
    percent = 100
    await turnComplete()
    expect(timers).toEqual([])
    expect(ran).toEqual([])
  }
})

test('below the force threshold, or with an unusable value, a turn ending forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 69
  await turnComplete()
  // An unusable value is the default, not "off": a typo must not quietly
  // disable a rotation the person is relying on. 100 is past 80, so it forces.
  envVars.CS_ROTATE_FORCE_CTX = 'critical'
  percent = 100
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a forced rotation runs once per conversation, and a failed /rotate is not retried', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 80
  await turnComplete()
  expect(written['/work/.cs/local/cs-rotate.forced']).toBe('uuid-lead\n')
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  // the marker is written before the timer is scheduled, so a rejected run stays rejected
  $.command.run = async () => { throw new Error('unknown command') }
  await fireAfter()
  expect(toasts).toEqual(['cs-rotate: /rotate did not run: Error: unknown command'])
  await turnComplete()
  expect(timers).toHaveLength(1)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  // a marker from an earlier conversation of the session does not count
  files['/work/.cs/local/cs-rotate.forced'] = 'uuid-earlier\n'
  await turnComplete()
  expect(timers).toHaveLength(2)
})

test('a subagent\'s turn, an aborted, errored or refused one, a teammate, or an unarmed non-cs directory forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  await turnComplete({ agentId: 'agent-1' })
  await turnComplete({ reason: 'aborted' })
  await turnComplete({ reason: 'error' })
  await turnComplete({ reason: 'refusal' })
  sessionId = 'uuid-teammate'
  await turnComplete()
  sessionId = 'uuid-lead'; existing = new Set(); files = {}
  await turnComplete()
  expect(timers).toEqual([])
  expect(Object.keys(written)).toEqual([])
})

test('a turn ending past the force threshold with a handoff already armed runs no second /rotate', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  arm()
  await turnComplete()
  await fireAfter()
  expect(ran).toEqual([])
})

// The countdown's ticker, and one tick of it as the clock would run it.
const ticker = () => timers.find(t => t.kind === 'every' && !t.cancelled)
const tick = async (n = 1) => { for (let i = 0; i < n; i++) await ticker()!.fn() }
const promptSubmit = (text = 'keep going') =>
  hooks['prompt.submit']($, { text, wait: false, origin: { kind: 'composer' } }, async (e) => ({ text: e.text }))

test('with the handoff armed and force on, a turn ending starts a countdown the band shows, one redraw a second', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  expect(ticker()?.ms).toBe(1000)
  expect(GRACE_SECONDS).toBe(20)
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS}s`)
  await tick(3)
  expect(invalidated).toEqual(['ui.render', 'ui.render', 'ui.render'])
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS - 3}s`)
  expect(ran).toEqual([])
  // one countdown at a time: another turn ending does not start a second
  await turnComplete()
  expect(timers.filter(t => t.kind === 'every')).toHaveLength(1)
})

test('at zero the countdown runs /clear, once, and stops ticking', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  const t = ticker()!
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
})

test('a prompt entering the session stops the countdown and passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  expect(await promptSubmit('one more thing')).toEqual({ text: 'one more thing' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
  expect(ran).toEqual([])
  // the next turn ending restarts it from the top
  await turnComplete()
  expect(JSON.stringify(await band())).toContain(`/clear in ${GRACE_SECONDS}s`)
})

test('pressing the clear button mid-countdown stops the ticker before it clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  await findButton(await band()).props.onPress()
  expect(t.cancelled).toBe(true)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a countdown reaching zero while a turn runs or a survey holds the band clears nothing and stops', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  for (const props of [{ isWorking: true }, { hasSurvey: true }]) {
    await band()
    await turnComplete()
    const t = ticker()!
    await band(props)
    await tick(GRACE_SECONDS)
    expect(ran).toEqual([])
    expect(t.cancelled).toBe(true)
  }
})

test('a countdown reaching zero re-checks the handoff: one consumed meanwhile clears nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
})

test('with the forcing off, or outside the lead, an armed handoff starts no countdown and prompt.submit passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = 'off'
  arm(); percent = 80
  await turnComplete()
  envVars.CS_ROTATE_FORCE_CTX = '70'
  sessionId = 'uuid-teammate'
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toEqual([])
  expect(await promptSubmit()).toEqual({ text: 'keep going' })
})

test('a prompt arriving while the zero tick is still checking the handoff wins: nothing clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const zero = tick()
  await promptSubmit('wait, one more thing')
  await zero
  expect(ran).toEqual([])
  // and a press racing the zero tick clears once, not twice
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const button = findButton(await band())
  const zero2 = tick()
  await button.props.onPress()
  await zero2
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a /clear run from anywhere else ends the countdown, so no timer outlives the conversation', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  const t = ticker()!
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  expect(await hooks['command.run:clear']($, e, async () => ({ text: '' }))).toEqual({ text: '' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await band())).not.toContain('/clear in')
})

test('a rejected /clear at zero shows a toast and clears nothing else', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs-rotate: /clear did not run: Error: no session'])
  expect(ran).toEqual([])
})

// The SessionStart hook's own rule (_handoff_is_unconsumed): the frontmatter
// must close, and the status must sit inside it.
test('isUnconsumed follows the hook: unclosed frontmatter, or a status after it, is not armed', () => {
  expect(isUnconsumed('---\nstatus: unconsumed\n---\n')).toBe(true)
  expect(isUnconsumed('---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nparent: x\n---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nstatus: consumed\n---\n')).toBe(false)
  expect(isUnconsumed('')).toBe(false)
})

test('a tick that lands while the zero tick is still reading does not push the count negative or clear twice', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const t = ticker()!
  const first = t.fn()
  const second = t.fn()
  await first; await second
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(JSON.stringify(await band())).not.toContain('/clear in -')
})


test('a conversation met at load is forced whatever it started at; one born of a /clear that starts past the threshold is not, and says so once', async () => {
  // resumed (or launched) already past the line: forced, as asked
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
  // the successor wakes past the line: that is the loop, and it stops here
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 71
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toEqual(['cs-rotate: CS_ROTATE_FORCE_CTX=70 is below this conversation\'s starting context (71%); not forcing a rotation'])
  // a teammate past the line is not the lead: no rotation, and no toast about one
  sessionId = 'uuid-teammate'
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toHaveLength(1)
  // a successor that starts below and works its way past is forced as usual
  sessionId = 'uuid-later'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-later\n'
  percent = 30
  await turnComplete()
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(2)
  // a reload forgets: the conversation it meets next is adopted, whatever it reads
  register(on as any)
  sessionId = 'uuid-reloaded'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-reloaded\n'
  percent = 95
  await turnComplete()
  expect(timers).toHaveLength(3)
})

const clearRun = () =>
  hooks['command.run:clear']($, { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }, async () => ({ text: '' }))

test('a successor that starts past the threshold still gets the countdown once the person arms a handoff themselves', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  arm()
  await turnComplete()
  expect(ticker()).toBeDefined()
})

test('a /clear before any turn ends still marks the next conversation as /clear-born: past the threshold it is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a new conversation id with no /clear seen in this process is a resume: adopted and forced as asked', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('the /clear the mod runs itself marks the successor as /clear-born too, so a wake past the threshold is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-next\n' }
  sessionId = 'uuid-next'
  percent = 75
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a /clear whose successor never answers does not mark a later /resume as /clear-born: the band drawn in the successor consumes the birth', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-wake'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-wake\n'
  await band()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('resuming a conversation that was once judged adopts it afresh: the old judgment is dropped', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  sessionId = 'uuid-other'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-other\n'
  percent = 20
  await turnComplete()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toHaveLength(1)
})

test('a /clear the mod runs itself that is rejected leaves no birth behind: a later /resume past the threshold is forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs-rotate: /clear did not run: Error: no session'])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toHaveLength(1)
  expect(toasts).toHaveLength(1)
})

test('a typed /clear that the engine refuses leaves no birth behind either', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  await expect(hooks['command.run:clear']($, e, async () => { throw new Error('refused') })).rejects.toThrow('refused')
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

// The wrap key: a second button on hotkey 2 that runs /wrap. It draws only
// where the band draws unarmed; once a handoff is armed the band's one job is
// the /clear.
const wrapButton = (tree: any) => buttons(tree).find((b: any) => b.props.hotkey === '2')
test('at the threshold the band adds a second button on hotkey 2 that reads as the wrap key, after the rotate key', async () => {
  percent = 40
  const tree = await band()
  expect(buttons(tree)).toHaveLength(2)
  expect(buttons(tree)[0].props.hotkey).toBe('1')
  const button = wrapButton(tree)
  expect(button.props.plain).toBe(true)
  expect(wrapButton(tree).props.label).toBe('wrap up this session')
})

// One key, then the engine's own dialog. /wrap replaces .cs/summary.md and
// runs two Opus passes, so the press asks rather than acts; a held `2` repeats
// on keydown (contract) and each repeat only re-opens the same question.
test('pressing 2 asks before /wrap, and only the yes runs it', async () => {
  percent = 40
  answer = WRAP_YES
  await wrapButton(await band()).props.onPress()
  expect(asks).toEqual([{ question: WRAP_QUESTION, options: { header: 'Wrap', options: [WRAP_YES, 'Not now'] } }])
  expect(ran).toEqual([{ command: 'wrap', args: '' }])

  answer = 'Not now'
  await wrapButton(await band()).props.onPress()
  expect(asks).toHaveLength(2)
  expect(ran).toHaveLength(1)

  // dismissed, or a `-p` run with nobody to ask: nothing runs and nothing is said
  answer = new Error('dismissed')
  await wrapButton(await band()).props.onPress()
  expect(ran).toHaveLength(1)
  expect(toasts).toEqual([])
})

test('a /wrap the answer runs that the engine refuses is said once', async () => {
  percent = 40
  answer = WRAP_YES
  $.command.run = async () => { throw new Error('no session') }
  await wrapButton(await band()).props.onPress()
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['cs-rotate: /wrap did not run: Error: no session'])
  expect(ran).toEqual([])
})

// A wrap that finished leaves nothing for the key to do until the conversation
// moves on. /wrap's last pass writes .cs/local/wrapped naming the conversation
// it ran in; the band draws the rotate key alone while the marker names this
// one, and the next turn that starts from a prompt empties it. A continuation
// (a turn started with no prompt, as a Stop hook's feedback starts one) does not.
// A summary written any other way proves nothing.
const WRAPPED = '/work/.cs/local/wrapped'
const turnStart = (text: string) => hooks['turn.start']($, { text, turnId: `turn-${text.length}` }, async (e: any) => ({ turnId: e.turnId }))

test('a finished wrap hides the wrap key until a turn starts from a prompt', async () => {
  percent = 40
  await turnStart('please wrap up')
  files[WRAPPED] = 'uuid-lead\n'
  expect(wrapButton(await band())).toBeUndefined()
  expect(findButton(await band()).props.hotkey).toBe('1')

  await turnStart('')
  expect(wrapButton(await band())).toBeUndefined()

  await turnStart('next thing')
  expect(files[WRAPPED]).toBe('')
  expect(wrapButton(await band())).toBeDefined()
})

// Work queued behind the wrap starts its own turn, and a second wrap that fails
// a pass writes no marker of its own: either way the first wrap's marker is gone.
test('queued work, or a second wrap that fails, brings the key back', async () => {
  percent = 40
  files[WRAPPED] = 'uuid-lead\n'
  await turnStart('and then fix the tests')
  expect(wrapButton(await band())).toBeDefined()

  files[WRAPPED] = 'uuid-lead\n'
  await turnStart('/wrap')
  expect(wrapButton(await band())).toBeDefined()
})

test('a summary with no wrap marker, or a marker naming another conversation, keeps the wrap key', async () => {
  percent = 40
  files['/work/.cs/summary.md'] = '# Session Summary\n'
  expect(wrapButton(await band())).toBeDefined()
  files[WRAPPED] = 'uuid-teammate\n'
  expect(wrapButton(await band())).toBeDefined()
  await turnStart('x')
  expect(files[WRAPPED]).toBe('uuid-teammate\n')
})

test('an armed handoff draws the clear key alone: no wrap key', async () => {
  arm(); percent = 90
  expect(buttons(await band())).toHaveLength(1)
  expect(wrapButton(await band())).toBeUndefined()
})

// The engine refuses a tree with a Button under an inline element (measured
// on 2.1.273: "Button inside an inline element; drawing the engine's own"),
// and the whole band vanishes with it.
function buttonsUnderText(tree: any, inText = false): number {
  if (!tree || typeof tree !== 'object') return 0
  if (tree.type === 'Button' && inText) return 1
  const inline = inText || tree.type === 'Text'
  return (tree.children ?? []).reduce((n: number, c: any) => n + buttonsUnderText(c, inline), 0)
}

test('no button is ever nested in a Text, armed or not', async () => {
  percent = 40
  expect(buttonsUnderText(await band())).toBe(0)
  arm()
  expect(buttonsUnderText(await band())).toBe(0)
})

// The contract lets a held key repeat on keydown, and a digit with no button
// on it lands in the composer (measured: a second `2` while armed typed `2`,
// and a non-empty composer takes every hotkey with it). So `2` keeps a button
// while armed: each press only re-arms, the window restarts, nothing is typed,
// and the confirmation sits on `3`.

// The first grace of a session opens a pane beside the band that shows what
// the handoff will do next, so the twenty seconds are spent reading it. The
// pane carries no keys: stopping the count stays on the band. Later graces in
// the same session keep to the band alone.
const pane = (requestId = PREVIEW_PANE) =>
  hooks['ui.render:Pane']($, { requestId, props: { title: 'Handoff', isFocused: false, bodyColumns: 60, placement: 'dock' } }, async () => DRAWN)
const HANDOFF_WITH_STEP = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n# Next Step\n\nRun the secrets suites solo.\nTriage the store file.\n\n# Settled\n\nNothing.\n'

test('the first grace in a session opens the handoff pane from a timer, and it shows the next step and the count', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); files[HANDOFF] = HANDOFF_WITH_STEP; percent = 80
  await band()
  await turnComplete()
  expect(panes).toEqual([])
  await fireAfter()
  expect(panes).toEqual([{ op: 'open', args: { id: PREVIEW_PANE, title: 'Handoff' } }])
  const body = JSON.stringify(await pane())
  expect(body).toContain('Run the secrets suites solo.')
  expect(body).toContain('Triage the store file.')
  expect(body).not.toContain('Settled')
  expect(body).toContain(`/clear in ${GRACE_SECONDS}s`)
  expect(buttons(await pane())).toEqual([])
  await tick(2)
  expect(JSON.stringify(await pane())).toContain(`/clear in ${GRACE_SECONDS - 2}s`)
})

test('any end of the count closes the pane: a prompt, a press, zero', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band(); await turnComplete(); await fireAfter()
  await promptSubmit()
  expect(panes.at(-1)).toEqual({ op: 'close', args: { id: PREVIEW_PANE } })

  register(on as any); panes = []
  arm()
  await band(); await turnComplete(); await fireAfter()
  await findButton(await band()).props.onPress()
  expect(panes.at(-1)).toEqual({ op: 'close', args: { id: PREVIEW_PANE } })

  register(on as any); panes = []; ran = []
  arm()
  await band(); await turnComplete(); await fireAfter()
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(panes.at(-1)).toEqual({ op: 'close', args: { id: PREVIEW_PANE } })
})

// The open is a round trip: a prompt landing while it is in flight stops the
// count and asks for a close that the engine may apply before the open lands.
// A pane opened after its count ended must still be closed, or nothing ever
// closes it.
test('a count that ends while the pane is still opening closes the pane once it lands', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  let land!: () => void
  $.ui.open = (args: any) => new Promise<void>(resolve => { land = () => { panes.push({ op: 'open', args }); resolve() } })
  try {
    await band(); await turnComplete()
    const opening = fireAfter()
    await new Promise(r => setTimeout(r, 0))
    await promptSubmit()
    land()
    await opening
  } finally {
    $.ui.open = async (args: any) => { panes.push({ op: 'open', args }) }
  }
  expect(panes.map(p => p.op)).toContain('open')
  expect(panes.at(-1)).toEqual({ op: 'close', args: { id: PREVIEW_PANE } })
})

test('a later grace in the same session keeps to the band: the pane opens once', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band(); await turnComplete(); await fireAfter()
  await promptSubmit()
  await turnComplete(); await fireAfter()
  expect(ticker()).toBeDefined()
  expect(panes.filter(p => p.op === 'open')).toHaveLength(1)
})

test('a pane drawn for any other id passes through, and a closed preview draws nothing of its own', async () => {
  expect(await pane('someone-else')).toBe(DRAWN)
  expect(await pane()).toBe(DRAWN)
})

test('nextStep reads the handoff\'s Next Step section as written, however it is numbered', () => {
  expect(nextStep(HANDOFF_WITH_STEP)).toEqual({ text: 'Run the secrets suites solo.\nTriage the store file.', cut: false })
  expect(nextStep('---\nstatus: unconsumed\n---\n\n## 1. Next Step\n\nOne thing.\n\n- a\n- b\n')).toEqual({ text: 'One thing.\n\n- a\n- b', cut: false })
  expect(nextStep('---\nstatus: unconsumed\n---\n\nNo heading here.\n')).toEqual({ text: '', cut: false })
  // no line cap: 300 lines come through whole
  const long = '# Next Step\n\n' + Array.from({ length: 300 }, (_, i) => `line ${i}`).join('\n') + '\n\n# Settled\n\nNothing.\n'
  expect(nextStep(long).text.split('\n')).toHaveLength(300)
  expect(nextStep(long).cut).toBe(false)
})

test('a step past the engine\'s markdown bound is cut at a line and says so', () => {
  const line = 'x'.repeat(99)
  const huge = '# Next Step\n\n' + Array.from({ length: 200 }, () => line).join('\n') + '\n'
  const step = nextStep(huge)
  expect(step.cut).toBe(true)
  expect(step.text.length).toBeLessThanOrEqual(MARKDOWN_LIMIT)
  expect(step.text.split('\n').every(l => l === line)).toBe(true)
  expect(step.text.split('\n')).toHaveLength(100)
  // one line past the bound has no line to stop at: it is cut at the bound
  const wide = nextStep('# Next Step\n\n' + 'y'.repeat(MARKDOWN_LIMIT + 50) + '\n')
  expect(wide).toEqual({ text: 'y'.repeat(MARKDOWN_LIMIT), cut: true })
})

test('a # line inside a fenced block belongs to the step, not to a new section', () => {
  const step = '## Next Step\n\nRun:\n\n```bash\n# build first\n./build.sh\n```\n\n~~~\n## not a heading\n~~~\nThen merge.\n\n## Settled\n\nNothing.\n'
  expect(nextStep(step)).toEqual({ text: 'Run:\n\n```bash\n# build first\n./build.sh\n```\n\n~~~\n## not a heading\n~~~\nThen merge.', cut: false })
})

test('nextStep keeps an indented first line\'s indent', () => {
  expect(nextStep('# Next Step\n\n    make test\n\nThen merge.\n').text).toBe('    make test\n\nThen merge.')
})

// The count's colour ramp: the session's own colour while there is time, the
// bar's amber from ten seconds, its crit red under five. The band's
// `/clear in Ns` and the pane's bar and count wear it alike. Inks KEEP IN SYNC
// with _sgr in bin/cs-statusline (tests/test_mod_rotate.sh pins them).
function texts(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(texts)
  const own = tree.type === 'Text' ? [tree] : []
  return [...own, ...(tree.children ?? []).flatMap(texts)]
}
const textOf = (node: any): string => (node.children ?? []).map((c: any) => typeof c === 'string' ? c : '').join('')
function markdowns(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(markdowns)
  return [...(tree.type === 'Markdown' ? [tree] : []), ...(tree.children ?? []).flatMap(markdowns)]
}
const countText = (tree: any) => texts(tree).find(t => /^\/clear in \d+s$/.test(textOf(t)))
const startGrace = async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); files[HANDOFF] = HANDOFF_WITH_STEP; percent = 80
  await band()
  await turnComplete()
}

test('the band\'s count ramps: session colour past ten seconds, amber from ten to five, crit red under five', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  await startGrace()
  let count = countText(await band())
  expect(count.props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  await tick(9) // 11 s left
  expect(countText(await band()).props.color).toBe('rgb(220,38,38)')
  await tick(1) // 10
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
  await tick(5) // 5
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
  await tick(1) // 4
  count = countText(await band())
  expect(textOf(count)).toBe('/clear in 4s')
  expect(count.props.color).toBe('rgb(215,0,21)')
})

test('on a dark terminal the ramp takes the bar\'s dark inks', async () => {
  envVars.CS_TERM_BG_RGB = '30;30;30'
  envVars.CS_TERM_THEME = 'dark'
  files['/work/.cs/local/state'] = 'claude_session_color: cyan\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await band()).props.color).toBe('rgb(8,145,178)')
  await tick(10)
  expect(countText(await band()).props.color).toBe('rgb(253,230,138)')
  await tick(6)
  expect(countText(await band()).props.color).toBe('rgb(255,69,58)')
})

test('a session with no colour, or one outside the palette, keeps the band\'s own ink until the amber', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: chartreuse\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await band()).props.color).toBeUndefined()
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-lead\n'
  expect(countText(await band()).props.color).toBeUndefined()
  await tick(10)
  // no measured background and no theme: the light amber, as the bar picks
  expect(countText(await band()).props.color).toBe('rgb(180,83,9)')
})

test('the pane opens on a header in the session colour and draws the step as markdown', async () => {
  await startGrace(); await fireAfter()
  const tree = await pane()
  const all = texts(tree)
  expect(textOf(all[0])).toBe('Handoff')
  expect(all[0].props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  expect(markdowns(tree)).toEqual([{ type: 'Markdown', props: { key: 'step', text: 'Run the secrets suites solo.\nTriage the store file.' }, children: [] }])
  expect(JSON.stringify(tree)).not.toContain('rest of the step')
})

test('a step cut at the markdown bound ends on a dim note', async () => {
  const huge = Array.from({ length: 200 }, () => 'x'.repeat(99)).join('\n')
  await startGrace(); files[HANDOFF] = `---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n# Next Step\n\n${huge}\n`
  await fireAfter()
  const note = texts(await pane()).find(t => textOf(t) === '… the rest of the step is in the handoff')
  expect(note.props.dimColor).toBe(true)
})

test('the pane counts down on a twenty-block bar in the ramp\'s colour, beside the same count', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  await startGrace(); await fireAfter()
  const bar = (tree: any) => texts(tree).find(t => /^[█░]+$/.test(textOf(t)))
  let b = bar(await pane())
  expect(textOf(b)).toBe('█'.repeat(20))
  expect(b.props.color).toBe('rgb(220,38,38)')
  expect(countText(await pane()).props.color).toBe('rgb(220,38,38)')
  await tick(15) // 5 left
  b = bar(await pane())
  expect(textOf(b)).toBe('█'.repeat(5) + '░'.repeat(15))
  expect(b.props.color).toBe('rgb(180,83,9)')
  expect(JSON.stringify(await pane())).toContain('press 1 to clear now, or send a prompt to stay')
})
