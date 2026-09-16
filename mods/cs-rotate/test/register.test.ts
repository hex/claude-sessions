// ABOUTME: Unit tests for the cs-rotate mod against a fake engine `$`.
// ABOUTME: Covers the band's gate (crit, working, survey), the three presses and the wrap key's two-press guard, the armed handoff, and the heartbeat.
import { test, expect, beforeEach } from 'bun:test'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, DEFAULT_PERCENT, DEFAULT_CRIT, GRACE_SECONDS, gaugeColor, meter, isUnconsumed, INK } from '../hooks/register.tsx'

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
  ui: { resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }), invalidate: (event: string) => { invalidated.push(event) }, toast: (text: string) => { toasts.push(text) } },
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
  timers = []; invalidated = []; toasts = []
  // The default fixture is the lead conversation of a cs session.
  sessionId = 'uuid-lead'
  envVars = {}
  files = { '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n' }
  register(on as any)
})

test('the default threshold is the statusline warn band', () => {
  expect(DEFAULT_PERCENT).toBe(40)
  expect(DEFAULT_CRIT).toBe(65)
})

// The status bar's truecolor inks, as bin/cs-statusline paints them on each
// theme (tests/test_mod_rotate.sh pins the triplets against that file).
test('the gauge ink steps where the status bar steps, in the theme\'s own ink', () => {
  const bands = { warn: 40, crit: 65 }
  const table: [number, string, string][] = [
    [0, 'text', 'text'], [39, 'text', 'text'],
    [40, 'rgb(180,83,9)', 'rgb(253,230,138)'], [64, 'rgb(180,83,9)', 'rgb(253,230,138)'],
    [65, 'rgb(215,0,21)', 'rgb(255,69,58)'], [100, 'rgb(215,0,21)', 'rgb(255,69,58)'],
  ]
  for (const [p, light, dark] of table) {
    expect([p, gaugeColor(p, bands, 'light'), gaugeColor(p, bands, 'dark')]).toEqual([p, light, dark])
  }
  expect(gaugeColor(undefined, bands, 'light')).toBe('text')
})

test('the meter fills one cell per ten percent, ten cells wide', () => {
  expect(meter(0)).toEqual(['', '\u2591'.repeat(10)])
  expect(meter(4)).toEqual(['', '\u2591'.repeat(10)])
  expect(meter(5)).toEqual(['\u2588', '\u2591'.repeat(9)])
  expect(meter(47)).toEqual(['\u2588'.repeat(5), '\u2591'.repeat(5)])
  expect(meter(100)).toEqual(['\u2588'.repeat(10), ''])
})

test('CS_STATUSLINE_CTX_WARN and _CRIT move the gauge, the band and its threshold together', async () => {
  envVars.CS_STATUSLINE_CTX_WARN = '50'; envVars.CS_STATUSLINE_CTX_CRIT = '70'
  percent = 49
  expect(await band()).toBe(DRAWN)
  percent = 50
  let tree = JSON.stringify(await band())
  expect(tree).toContain('"\u2588\u2588\u2588\u2588\u2588"')
  expect(tree).toContain('" 50%"')
  expect(tree).toContain(`"color":"${INK.amber.dark}"`)
  percent = 69
  expect(JSON.stringify(await band())).not.toContain(INK.crit.dark)
  percent = 70
  tree = JSON.stringify(await band())
  expect(tree).toContain('" 70%"')
  expect(tree).toContain(`"borderColor":"${INK.crit.dark}"`)
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
  expect(button.props.label).toMatch(/rotate/)
  expect(JSON.stringify(tree)).toContain('"Survey"')
  expect(JSON.stringify(tree)).toContain('"borderStyle":"round"')
})

test('the band carries the context meter in the status bar\'s own inks for the theme cs detected', async () => {
  percent = 71
  let tree = JSON.stringify(await band())
  expect(tree).toContain('"\u2588\u2588\u2588\u2588\u2588\u2588\u2588"')
  expect(tree).toContain('"\u2591\u2591\u2591"')
  expect(tree).toContain('" 71%"')
  expect(tree).toContain(`"color":"${INK.crit.dark}"`)
  expect(tree).not.toContain('ctx')
  envVars.CS_TERM_THEME = 'light'
  tree = JSON.stringify(await band())
  expect(tree).toContain(`"borderColor":"${INK.crit.light}"`)
  expect(tree).toContain(`"color":"${INK.crit.light}"`)
  expect(tree).not.toContain(INK.crit.dark)
  percent = 45
  tree = JSON.stringify(await band())
  expect(tree).toContain('" 45%"')
  expect(tree).toContain(`"color":"${INK.amber.light}"`)
})

test('the capsule is a keyed box that turns coral under the pointer, with the mark in coral', async () => {
  percent = 40
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"key":"cs-rotate-band"')
  expect(tree).toContain(`"hover":{"borderColor":"${INK.coral}"}`)
  expect(tree).toContain(`"color":"${INK.coral}","bold":true},"children":["\u2733 "]`)
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
    expect(button.props.label).toBe('/clear and continue from the handoff')
    const json = JSON.stringify(tree)
    expect(json).toContain('"borderStyle":"round"')
    expect(json).toContain(`"borderColor":"${INK.coral}"`)
    expect(json).not.toContain('undefined')
    if (p === undefined) expect(json).not.toContain('%')
    else expect(json).toContain(`" ${p}%"`)
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
  expect(findButton(await band()).props.label).toMatch(/rotate/)
})

test('an empty marker names no handoff, so the band behaves as unarmed', async () => {
  files[MARKER] = '\n'
  percent = 39
  expect(await band()).toBe(DRAWN)
  percent = 40
  expect(findButton(await band()).props.label).toMatch(/rotate/)
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

test('without CS_ROTATE_FORCE_CTX a turn ending at 100% forces nothing', async () => {
  percent = 100
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
})

test('below the force threshold, or with an unusable value, a turn ending forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 69
  await turnComplete()
  envVars.CS_ROTATE_FORCE_CTX = 'critical'
  percent = 100
  await turnComplete()
  expect(timers).toEqual([])
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

test('without force, or outside the lead, an armed handoff starts no countdown and prompt.submit passes through', async () => {
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
  await findButton(await band()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-next\n' }
  sessionId = 'uuid-next'
  percent = 75
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after')).toEqual([])
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
// The confirmation is a different key: a held `2` repeats on keydown
// (contract) and must never confirm itself.
const confirmButton = (tree: any) => buttons(tree).find((b: any) => b.props.hotkey === '3')

test('at the threshold the band adds a second button on hotkey 2 that reads as the wrap key, after the rotate key', async () => {
  percent = 40
  const tree = await band()
  expect(buttons(tree)).toHaveLength(2)
  expect(buttons(tree)[0].props.hotkey).toBe('1')
  const button = wrapButton(tree)
  expect(button.props.plain).toBe(true)
  expect(button.props.label).toBe('wrap up this session')
})

test('an armed handoff draws the clear key alone: no wrap key', async () => {
  arm(); percent = 90
  expect(buttons(await band())).toHaveLength(1)
  expect(wrapButton(await band())).toBeUndefined()
})

test('the wrap key needs two keys: 2 arms it for a moment and runs nothing, 3 while armed runs /wrap', async () => {
  percent = 40
  expect(confirmButton(await band())).toBeUndefined()
  await wrapButton(await band()).props.onPress()
  expect(ran).toEqual([])
  expect(invalidated).toEqual(['ui.render'])
  let tree = await band()
  expect(wrapButton(tree).props.label).toBe('wrap up this session?')
  expect(confirmButton(tree).props.plain).toBe(true)
  expect(confirmButton(tree).props.label).toBe('yes, run /wrap')
  await confirmButton(tree).props.onPress()
  expect(ran).toEqual([{ command: 'wrap', args: '' }])
  expect(filled).toEqual([])
  // Disarmed by the run: the wrap key is back and 3 presses nothing.
  tree = await band()
  expect(wrapButton(tree).props.label).toBe('wrap up this session')
  expect(confirmButton(tree)).toBeUndefined()
})


test('an armed wrap key disarms on its own after a moment, and a press then only re-arms', async () => {
  percent = 40
  await wrapButton(await band()).props.onPress()
  const t = timers.find(t => t.kind === 'after')
  expect(t).toBeDefined()
  expect(t!.ms).toBe(5000)
  t!.fn()
  expect(wrapButton(await band()).props.label).toBe('wrap up this session')
  expect(confirmButton(await band())).toBeUndefined()
  await wrapButton(await band()).props.onPress()
  expect(ran).toEqual([])
})

test('a prompt entering the session, or a /clear, disarms the wrap key', async () => {
  percent = 40
  await wrapButton(await band()).props.onPress()
  await hooks['prompt.submit']($, { text: 'hi' }, async e => e)
  expect(confirmButton(await band())).toBeUndefined()
  await wrapButton(await band()).props.onPress()
  await hooks['command.run:clear']($, {}, async e => e)
  expect(confirmButton(await band())).toBeUndefined()
  expect(ran).toEqual([])
})

test('a rejected /wrap shows a toast and leaves the key disarmed', async () => {
  percent = 40
  $.command.run = async () => { throw new Error('no such command') }
  await wrapButton(await band()).props.onPress()
  await confirmButton(await band()).props.onPress()
  expect(toasts).toEqual(['cs-rotate: /wrap did not run: Error: no such command'])
  expect(confirmButton(await band())).toBeUndefined()
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
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

test('no button is ever nested in a Text: armed or not, arming the wrap key or not', async () => {
  percent = 40
  expect(buttonsUnderText(await band())).toBe(0)
  await wrapButton(await band()).props.onPress()
  expect(buttonsUnderText(await band())).toBe(0)
  await confirmButton(await band()).props.onPress()
  arm()
  expect(buttonsUnderText(await band())).toBe(0)
})

// The contract lets a held key repeat on keydown, and a digit with no button
// on it lands in the composer (measured: a second `2` while armed typed `2`,
// and a non-empty composer takes every hotkey with it). So `2` keeps a button
// while armed: each press only re-arms, the window restarts, nothing is typed,
// and the confirmation sits on `3`.
test('a held 2 never confirms: while armed 2 only re-arms, restarting the window, and the confirmation sits on 3', async () => {
  percent = 40
  await wrapButton(await band()).props.onPress()
  for (let i = 0; i < 20; i++) {
    const tree = await band()
    expect(wrapButton(tree).props.hotkey).toBe('2')
    expect(confirmButton(tree).props.hotkey).toBe('3')
    await wrapButton(tree).props.onPress()
  }
  expect(ran).toEqual([])
  const afters = timers.filter(t => t.kind === 'after')
  expect(afters).toHaveLength(21)
  expect(afters.filter(t => !t.cancelled)).toHaveLength(1)
  expect(afters[afters.length - 1].cancelled).toBe(false)
})

test('the arm does not survive a conversation switch: the first press in the new one only arms', async () => {
  percent = 40
  await wrapButton(await band()).props.onPress()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  expect(confirmButton(await band())).toBeUndefined()
  await wrapButton(await band()).props.onPress()
  expect(ran).toEqual([])
  expect(confirmButton(await band())).toBeDefined()
})
