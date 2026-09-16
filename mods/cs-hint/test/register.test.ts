// ABOUTME: Unit tests for the cs-hint mod against a fake engine `$`.
// ABOUTME: Covers the line's gate (lead, draft, working), each fact in priority order, the tips and the off switch.
import { test, expect, beforeEach } from 'bun:test'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, TIPS } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let written: Record<string, string>
let existing: Set<string>
let files: Record<string, string>
let sessionId: string
let model: string
let envVars: Record<string, string | undefined>
let timers: { ms: number; fn: () => void; kind: 'after' | 'every'; cancelled: boolean }[]
let invalidated: string[]
const timer = (kind: 'after' | 'every') => (ms: number, fn: () => void) => {
  const t = { ms, fn, kind, cancelled: false }
  timers.push(t)
  return { cancel: () => { t.cancelled = true } }
}
// A directory listing derived from the fixture: a file is an entry of `files`
// one segment below the path, a dir a member of `existing` one segment below.
const list = async (path: string) => {
  const out: { name: string; kind: 'file' | 'dir'; size?: number }[] = []
  const child = (p: string) => (p.startsWith(`${path}/`) && !p.slice(path.length + 1).includes('/')) ? p.slice(path.length + 1) : undefined
  for (const p of Object.keys(files)) { const n = child(p); if (n !== undefined) out.push({ name: n, kind: 'file', size: files[p].length }) }
  for (const p of existing) { const n = child(p); if (n !== undefined && !(p in files)) out.push({ name: n, kind: 'dir' }) }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}
const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: {
    cwd: async () => '/work',
    id: async () => sessionId,
    model: async () => model,
  },
  ui: { resolve: async () => ({ Box: 'Box', Text: 'Text' }), invalidate: (event: string) => { invalidated.push(event) } },
  clock: { after: timer('after'), every: timer('every') },
  fs: {
    write: async (path: string, text: string) => { written[path] = text; files[path] = text },
    exists: async (path: string) => existing.has(path) || path in files,
    read: async (path: string) => { if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
    list,
  },
}

const ENGINE_HINT = '? for shortcuts'
let received: any
const DRAWN = { engine: true }
// `next` records what it was handed and stands for the engine's own draw.
const next = async (e: any) => { received = e; return DRAWN }
// Nothing waiting on the lead: the line is one of the tips, not the engine's.
const expectTip = (text: string) => expect(TIPS).toContain(text)
// What the line reads after the hook: the engine's own text when the hook
// left it alone (a rewrite of `hint` draws nothing on this build while the
// permission-mode notice owns the line, measured on 2.1.273), else the text
// of the one dim Text the mod draws beneath it.
const line = async (props: Partial<{ isDraft: boolean; isWorking: boolean }> = {}) => {
  const e = { props: { isDraft: false, isWorking: false, hint: ENGINE_HINT, ...props } }
  const out = await hooks['ui.render:PromptHint']($, e, next)
  if (out === DRAWN) {
    expect(received).toBe(e)
    return ENGINE_HINT
  }
  expect(out.type).toBe('Text')
  expect(out.props).toEqual({ dimColor: true })
  return out.children.join('') as string
}

beforeEach(() => {
  for (const k of Object.keys(hooks)) delete hooks[k]
  written = {}; existing = new Set(['/work/.cs/local']); timers = []; invalidated = []; received = undefined
  // The default fixture is the lead conversation of a cs session.
  sessionId = 'uuid-lead'
  model = 'claude-opus-5'
  envVars = {}
  files = { '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n' }
  register(on as any)
})

test('a teammate, a plain conversation and a draft all get the engine\'s own line', async () => {
  sessionId = 'uuid-mate'
  expect(await line()).toBe(ENGINE_HINT)
  sessionId = 'uuid-lead'
  existing.delete('/work/.cs/local')
  expect(await line()).toBe(ENGINE_HINT)
  existing.add('/work/.cs/local')
  existing.add('/work/.cs/local/disabled')
  expect(await line()).toBe(ENGINE_HINT)
  existing.delete('/work/.cs/local/disabled')
  // Shortcuts matter while typing, and the interrupt shortcut while a turn runs.
  expect(await line({ isDraft: true })).toBe(ENGINE_HINT)
  expect(await line({ isWorking: true })).toBe(ENGINE_HINT)
})

const mail = (name: string, from: string, ts = Number(name.split('-')[0])) => {
  files[`/work/.cs/local/mail/new/${name}.json`] = JSON.stringify({ id: name, ts, from, actor: 'x', kind: 'result', ref: null, body: 'hi' })
}

test('unread mail leads the line, counted from mail/new, the newest sender named', async () => {
  existing.add('/work/.cs/local/mail/new')
  expect(await line()).not.toContain('message')
  mail('1784400000-1-a', 'alpha')
  expect(await line()).toBe('1 message from alpha · cs -msg')
  mail('1784400076-2-b', 'beta')
  expect(await line()).toBe('2 messages from beta · cs -msg')
  // A sender outside a cs session writes "" (never null): no "from" clause.
  mail('1784400099-3-c', '')
  expect(await line()).toBe('3 messages · cs -msg')
  // A teammate in the same directory does not read the lead's mail.
  sessionId = 'uuid-mate'
  expect(await line()).toBe(ENGINE_HINT)
})

test('only the .json files cs reads count as mail, and the sender named is the latest by its timestamp, not by name', async () => {
  existing.add('/work/.cs/local/mail/new')
  files['/work/.cs/local/mail/new/notes.txt'] = 'not mail'
  expectTip(await line())
  // Same second, pids 900 then 1000: the name order puts 1000 first, the timestamps say 900 came... later.
  mail('1784400000-900', 'earlier', 1784400000)
  mail('1784400000-1000', 'later', 1784400001)
  expect(await line()).toBe('2 messages from later \u00b7 cs -msg')
})

const HANDOFF = '---\nparent: x\nstatus: unconsumed\n---\n\n## 1. Next Step\n'
const arm = (name = '2026-09-16-next.md', text = HANDOFF) => {
  files['/work/.cs/local/pending-handoff'] = `${name}\n`
  files[`/work/.cs/handoffs/${name}`] = text
}

test('an armed handoff shows the /clear that continues it, after any mail', async () => {
  arm()
  expect(await line()).toBe('handoff armed · /clear continues it')
  existing.add('/work/.cs/local/mail/new')
  mail('1784400000-1-a', 'alpha')
  expect(await line()).toBe('1 message from alpha · cs -msg · handoff armed · /clear continues it')
})

test('a marker the SessionStart hook would refuse does not arm the line', async () => {
  arm('2026-09-16-next.md', HANDOFF.replace('unconsumed', 'consumed\nconsumed_by: other'))
  expectTip(await line())
  arm('../escape.md')
  expectTip(await line())
  files['/work/.cs/local/pending-handoff'] = 'missing.md\n'
  expectTip(await line())
  arm('2026-09-16-next.md', '---\nstatus: unconsumed\n')
  expectTip(await line())
})

test('the marker is read as the hook reads it: every whitespace character dropped', async () => {
  arm('2026-09-16-next.md')
  files['/work/.cs/local/pending-handoff'] = ' 2026-09-16-\tnext.md \n'
  expect(await line()).toBe('handoff armed \u00b7 /clear continues it')
})

const queue = (n: number) => {
  existing.add('/work/.cs/local/queue')
  for (let i = 1; i <= n; i++) files[`/work/.cs/local/queue/000000000${i}-1-000${i}`] = `task ${i}\n`
}

test('queued tasks show their count and the gate\'s state; an empty queue says nothing whatever the state file reads', async () => {
  existing.add('/work/.cs/local/queue')
  files['/work/.cs/local/queue.state'] = 'armed\n'
  expectTip(await line())
  queue(1)
  delete files['/work/.cs/local/queue.state']
  expect(await line()).toBe('1 queued · gate waiting')
  files['/work/.cs/local/queue.state'] = 'idle\n'
  expect(await line()).toBe('1 queued · gate waiting')
  queue(3)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  expect(await line()).toBe('3 queued · draining')
  files['/work/.cs/local/queue.state'] = 'draining\n'
  expect(await line()).toBe('3 queued · draining')
})

test('a declined gate reads deferred for the hook\'s ten-minute cooldown, then waits again', async () => {
  queue(2)
  files['/work/.cs/local/queue.state'] = 'idle\n'
  const now = Math.floor(Date.now() / 1000)
  files['/work/.cs/local/queue.declined'] = `${now - 599}\n`
  expect(await line()).toBe('2 queued · deferred')
  files['/work/.cs/local/queue.declined'] = `${now - 601}\n`
  expect(await line()).toBe('2 queued · gate waiting')
  files['/work/.cs/local/queue.declined'] = 'garbage\n'
  expect(await line()).toBe('2 queued · gate waiting')
})

test('the line carries at most two facts, in priority order', async () => {
  queue(1)
  arm()
  existing.add('/work/.cs/local/mail/new')
  mail('1784400000-1-a', 'alpha')
  expect(await line()).toBe('1 message from alpha · cs -msg · handoff armed · /clear continues it')
  delete files['/work/.cs/local/mail/new/1784400000-1-a.json']
  expect(await line()).toBe('handoff armed · /clear continues it · 1 queued · gate waiting')
})

const consumed = (by: string, purpose = 'build the hint mod') => {
  existing.add('/work/.cs/handoffs')
  files['/work/.cs/handoffs/2026-09-16-old.md'] = '---\nstatus: consumed\nconsumed_by: uuid-earlier\npurpose: something earlier\n---\n'
  files['/work/.cs/handoffs/2026-09-16-mine.md'] = `---\nparent: x\npurpose: ${purpose}\nstatus: consumed\nconsumed_by: ${by}\n---\n`
}
const submit = (kind: string) => hooks['prompt.submit']($, { text: 'go', wait: false, origin: { kind } }, async (e: any) => e)

test('a conversation continuing a handoff shows its purpose until the person types something', async () => {
  consumed('uuid-lead')
  expect(await line()).toBe('continuing: build the hint mod')
  // The rotation wake is not the person: the line stays through it.
  await submit('task-notification')
  expect(await line()).toBe('continuing: build the hint mod')
  await submit('composer')
  expectTip(await line())
})

test('the person\'s prompt ends the resumed step even before the line was ever drawn, and through a reload', async () => {
  consumed('uuid-lead')
  await submit('composer')
  expectTip(await line())
  // The flag outlives the module: a reload must not bring the step back.
  register(on as any)
  expectTip(await line())
})

test('a Remote Control message is the person too', async () => {
  consumed('uuid-lead')
  expect(await line()).toBe('continuing: build the hint mod')
  await submit('bridge')
  expectTip(await line())
})

test('a handoff another conversation consumed is not this one\'s', async () => {
  consumed('uuid-other')
  expectTip(await line())
})

test('the resumed step ranks below mail, handoff and queue', async () => {
  consumed('uuid-lead')
  queue(1)
  expect(await line()).toBe('1 queued · gate waiting · continuing: build the hint mod')
})

const turn = (reason = 'answer', agentId?: string) => hooks['turn.complete']($, { reason, agentId }, async (e: any) => e)

test('with nothing waiting the line is one cs tip, which changes at the end of a turn, never between', async () => {
  const first = await line()
  expect(TIPS).toContain(first)
  expect(await line()).toBe(first)
  expect(await line()).toBe(first)
  await turn()
  const second = await line()
  expect(TIPS).toContain(second)
  expect(second).not.toBe(first)
  // A subagent's turn, an interrupted or an errored one is not a turn of the conversation.
  await turn('answer', 'agent-1')
  await turn('aborted')
  expect(await line()).toBe(second)
})

test('the first tip fits the session: /feature in a plain one, /finish in a worktree', async () => {
  expect(await line()).toBe('/feature <name> spawns a worktree session from a brief')
  files['/work/.cs/local/state'] += 'task_branch: feat/thing\n'
  expect(await line()).toBe('/finish <name> lands a feature branch and retires its worktree')
})

test('a new conversation starts the tips over', async () => {
  const first = await line()
  await turn()
  expect(await line()).not.toBe(first)
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  expect(await line()).toBe(first)
})

test('the caps tip describes what cs -statusline caps does: the rounded capsule ends, not the plan limits', () => {
  const caps = TIPS.find(t => t.includes('cs -statusline caps'))
  expect(caps).toBe('cs -statusline caps ask checks whether your font draws the rounded capsule ends')
})

test('a fact always outranks a tip', async () => {
  queue(1)
  expect(await line()).toBe('1 queued · gate waiting')
})

test('CS_NO_HINTS=1 or a hints: off line in the state file leaves the engine\'s line alone', async () => {
  queue(1)
  envVars.CS_NO_HINTS = '1'
  expect(await line()).toBe(ENGINE_HINT)
  envVars.CS_NO_HINTS = undefined
  files['/work/.cs/local/state'] += 'hints: off\n'
  expect(await line()).toBe(ENGINE_HINT)
})

test('session.start writes the heartbeat doctor reads, in a cs session only', async () => {
  await hooks['session.start']($, { cwd: '/work' }, async (e: any) => e)
  expect(written['/work/.cs/local/cs-hint.heartbeat']).toMatch(/^\d{4}-\d\d-\d\dT.*Z\n$/)
  written = {}
  await hooks['session.start']($, { cwd: '/elsewhere' }, async (e: any) => e)
  expect(Object.keys(written)).toEqual([])
})

test('the lead\'s first render starts one five-second ticker that redraws the line; a teammate starts none', async () => {
  sessionId = 'uuid-mate'
  await line()
  expect(timers).toEqual([])
  sessionId = 'uuid-lead'
  await line()
  await line()
  expect(timers.map(t => [t.kind, t.ms])).toEqual([['every', 5000]])
  timers[0].fn()
  expect(invalidated).toEqual(['ui.render'])
})

test('a dotfile in the queue is not a task, and a state word the hook does not know promises no gate', async () => {
  existing.add('/work/.cs/local/queue')
  files['/work/.cs/local/queue/.DS_Store'] = ''
  expectTip(await line())
  queue(1)
  files['/work/.cs/local/queue.state'] = 'broken\n'
  expect(await line()).toBe('1 queued')
  files['/work/.cs/local/queue.state'] = ' ar med \n'
  expect(await line()).toBe('1 queued · draining')
})
