/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-hint mod: one dim line under the prompt tells the lead conversation of a cs session what is waiting.
// ABOUTME: Unread mail, an armed handoff, queued tasks, the resumed handoff's step, else one cs tip; nothing while typing or working.
import type { On, EngineInterface } from 'claude-code'

declare const h: any
declare const Fragment: any

// The handoff this conversation continues, found once per conversation id
// (the store only grows, and the hook writes consumed_by before the first
// render). Module state survives a /clear, so the id is what keys it.
let resumed: { id: string; purpose?: string } | undefined

// The conversation the person has spoken in, by id: once they have, the
// resumed step is theirs to remember. On disk, not in module state: a reload
// of the mod must not bring the step back, and a prompt can land before the
// line is ever drawn.
export const SPOKEN = '.cs/local/cs-hint.spoken'

// Which tip the line shows when nothing is waiting: one step per turn of the
// conversation, never on a timer, so the line holds still while it is read.
// A new conversation (a new id) starts over.
let turns = { id: '', count: 0 }

// The refresh: mail, the queue and the marker change from outside the process
// (another session's cs -msg, the queue drain, the rotate skill), so once the
// lead has drawn the line it is redrawn every five seconds. One ticker per
// load; module state survives a /clear, and a reload drops the ticker.
let ticker: { cancel: () => void } | undefined
export const REFRESH_MS = 5000

// Doctor observes the mod RUNNING, not merely installed. Written when the
// plugin loads (session.start does not fire on /clear), relative to the
// session's cwd, which under cs is the session directory (or its worktree).
export const HEARTBEAT = '.cs/local/cs-hint.heartbeat'

// The tips, fixed and never generated. The first shown fits the session
// (see firstTip); the rest rotate by turn count. Each names one cs surface
// the person may not have found. Short: the line truncates.
export const TIPS = [
  '/feature <name> spawns a worktree session from a brief',
  '/finish <name> lands a feature branch and retires its worktree',
  'cs -statusline caps ask checks whether your font draws the rounded capsule ends',
  '/rotate hands a heavy conversation to a fresh one',
  'press 1 on the band above the prompt to rotate',
  'cs -msg <session> "text" mails another session',
  'cs -live shows who is idle, busy or in a shell',
  'cs -queue add "task" queues work for a walk-away run',
  'cs -secrets set <name> reads the value from stdin, never argv',
  'cs -doctor names every hook that injects context, and its off switch',
  '/checkpoint <label> snapshots git state and the narrative',
  '/wrap distills memory and writes the session summary',
  'cs -conversations shows a session\'s rotation chain',
  'CS_ROTATE_FORCE_CTX=<percent> rotates on its own past that context',
  'CS_NO_HINTS=1 turns this line off',
]

export function register(on: On) {
  resumed = undefined; turns = { id: '', count: 0 }; ticker = undefined
  on('session.start', async ($, e, next) => {
    // Only a cs session has .cs/local; anywhere else the mod stays silent.
    if (await $.fs.exists(`${e.cwd}/.cs/local`)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    // A subagent's turn, an interrupted or an errored one is not a turn of the conversation.
    if (e.reason === 'answer' && e.agentId === undefined) (await turnsOf($)).count += 1
    return next(e)
  })
  // The person's own prompt ends the resumed step's showing; the rotation
  // wake, a peer's message or a plugin's prompt is not the person.
  // Recorded only where the line is drawn: a teammate's prompt must not
  // stand for the lead's, and outside a cs session (or with the line off)
  // nothing is written, since fs.write would create .cs/local there.
  on('prompt.submit', async ($, e, next) => {
    if ((e.origin.kind === 'composer' || e.origin.kind === 'bridge') && (await ownsLine($))) {
      await $.fs.write(`${await $.session.cwd()}/${SPOKEN}`, `${await $.session.id()}\n`)
    }
    return next(e)
  })
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    // Shortcuts matter while typing, and the interrupt shortcut while a turn runs.
    if (e.props.isDraft || e.props.isWorking) return next(e)
    if (!(await ownsLine($))) return next(e)
    if (!ticker) ticker = $.clock.every(REFRESH_MS, () => $.ui.invalidate('ui.render'))
    const facts = await gatherFacts($)
    const hint = facts.length > 0 ? facts.slice(0, 2).join(' \u00b7 ') : await tip($)
    // The mod draws its own line rather than rewriting `hint`: measured on
    // 2.1.273, a rewrite draws nothing while the permission-mode notice
    // (`auto mode on`) owns the engine's line, which in a cs session it
    // always does; a tree is drawn beneath that notice, which stays.
    const { Text } = await $.ui.resolve(e)
    return <Text dimColor>{hint}</Text>
  })
}

// Mail cs delivered to this session and no conversation has read: the .json
// files under mail/new, as cs's own reader (_mail_read) selects them. The
// sender named is the one with the latest `ts` (names carry the epoch too,
// but cs warns that their order is not arrival order); a sender outside a cs
// session writes "" (never null), and then no sender is named.
export const MAIL_NEW = '.cs/local/mail/new'

// The rotate skill's last step writes the handoff's basename here; cs's
// SessionStart hook reads it on the next conversation. The cs-rotate mod's
// capsule offers the /clear too; this line says so in words, in its own slot.
export const MARKER = '.cs/local/pending-handoff'
export const HANDOFFS = '.cs/handoffs'

// What is waiting, in the order the person should learn it: mail first.
async function gatherFacts($: EngineInterface): Promise<string[]> {
  const cwd = await $.session.cwd()
  const facts: string[] = []
  const mail = await unreadMail($, cwd)
  if (mail) facts.push(mail)
  if (await handoffArmed($, cwd)) facts.push('handoff armed \u00b7 /clear continues it')
  const queued = await queuedTasks($, cwd)
  if (queued) facts.push(queued)
  const step = await resumedStep($, cwd)
  if (step) facts.push(step)
  return facts
}

// The purpose line of the handoff whose frontmatter names this conversation
// as consumer (cs's SessionStart hook writes `consumed_by: <uuid>` when it
// consumes the marker). Shown until the person's first prompt here.
async function resumedStep($: EngineInterface, cwd: string): Promise<string | undefined> {
  const id = await $.session.id()
  if (resumed?.id !== id) resumed = { id, purpose: await purposeConsumedBy($, cwd, id) }
  if (resumed.purpose === undefined) return undefined
  if ((await readOr($, `${cwd}/${SPOKEN}`)).trim() === id) return undefined
  return `continuing: ${resumed.purpose}`
}

// The tip counter of the current conversation, started over for a new id.
async function turnsOf($: EngineInterface) {
  const id = await $.session.id()
  if (turns.id !== id) turns = { id, count: 0 }
  return turns
}

async function purposeConsumedBy($: EngineInterface, cwd: string, id: string): Promise<string | undefined> {
  const dir = `${cwd}/${HANDOFFS}`
  if (!(await $.fs.exists(dir))) return undefined
  for (const entry of await $.fs.list(dir)) {
    if (entry.kind !== 'file') continue
    const front = frontmatter(await readOr($, `${dir}/${entry.name}`))
    if (front.consumed_by !== id) continue
    return front.purpose ?? entry.name
  }
  return undefined
}

// The `key: value` lines of a closed frontmatter block; {} where there is none.
function frontmatter(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  const lines = text.split('\n')
  if (lines[0] !== '---') return out
  for (const line of lines.slice(1)) {
    if (line === '---') return out
    const m = line.match(/^([A-Za-z_][\w-]*): *(.*?)\s*$/)
    if (m) out[m[1]] = m[2]
  }
  return {}
}

// The walk-away queue, as cs -queue and the narrative-reminder hook keep it:
// one file per task under queue/ (a glob, so a dotfile is not a task), one
// word in queue.state, and queue.declined holding the epoch of a "Not yet"
// the hook honours for ten minutes. An empty queue is never gating, whatever
// the state file records (the hook's rule).
export const QUEUE = '.cs/local/queue'
export const DECLINE_SECONDS = 600

async function queuedTasks($: EngineInterface, cwd: string): Promise<string | undefined> {
  if (!(await $.fs.exists(`${cwd}/${QUEUE}`))) return undefined
  const count = (await $.fs.list(`${cwd}/${QUEUE}`)).filter(f => f.kind === 'file' && !f.name.startsWith('.')).length
  if (count === 0) return undefined
  const gate = await gateState($, cwd)
  return gate ? `${count} queued \u00b7 ${gate}` : `${count} queued`
}

// The hook's reading of the state word (every whitespace character dropped):
// armed or draining is a drain in progress; idle, or no word, is a gate the
// Stop hook will raise unless a decline is still fresh; any other word the
// hook does not act on, so nothing is promised for it.
async function gateState($: EngineInterface, cwd: string): Promise<string | undefined> {
  const state = (await readOr($, `${cwd}/${QUEUE}.state`)).replace(/\s+/g, '')
  if (state === 'armed' || state === 'draining') return 'draining'
  if (state !== '' && state !== 'idle') return undefined
  const declined = (await readOr($, `${cwd}/${QUEUE}.declined`)).trim()
  if (/^\d+$/.test(declined) && Date.now() / 1000 - Number(declined) < DECLINE_SECONDS) return 'deferred'
  return 'gate waiting'
}

// The file's text, or "" where there is none or it cannot be read.
async function readOr($: EngineInterface, path: string): Promise<string> {
  try {
    return await $.fs.read(path)
  } catch {
    return ''
  }
}

async function unreadMail($: EngineInterface, cwd: string): Promise<string | undefined> {
  const dir = `${cwd}/${MAIL_NEW}`
  if (!(await $.fs.exists(dir))) return undefined
  const names = (await $.fs.list(dir)).filter(f => f.kind === 'file' && f.name.endsWith('.json')).map(f => f.name).sort()
  if (names.length === 0) return undefined
  let from = ''
  let latest = -Infinity
  for (const name of names) {
    try {
      const parsed = JSON.parse(await $.fs.read(`${dir}/${name}`))
      const ts = typeof parsed?.ts === 'number' ? parsed.ts : 0
      if (ts >= latest) { latest = ts; from = typeof parsed?.from === 'string' ? parsed.from : '' }
    } catch {
      // an unreadable or half-written message still counts; it just names nobody
    }
  }
  const count = `${names.length} message${names.length === 1 ? '' : 's'}`
  return `${count}${from ? ` from ${from}` : ''} \u00b7 cs -msg`
}

// Only the lead conversation of a cs session gets the line: .cs/local marks a
// cs session, .cs/local/disabled opts a directory out of cs, and the UUID in
// .cs/local/state belongs to the one conversation cs launched (a teammate
// claude in the same directory would read the lead's mail as its own). The
// value may be quoted and may carry trailing spaces, as cs's own state readers
// allow.
// A user-visible surface needs a revocable off switch: CS_NO_HINTS=1 in the
// launching shell (the literal name: `claude plugin validate` lists what a
// module reads), or `hints: off` in the state file for one session.
async function ownsLine($: EngineInterface): Promise<boolean> {
  if ((await $.env.get("CS_NO_HINTS")) === '1') return false
  const local = `${await $.session.cwd()}/.cs/local`
  if (!(await $.fs.exists(local)) || (await $.fs.exists(`${local}/disabled`))) return false
  const state = await readOr($, `${local}/state`)
  if (stateValue(state, 'hints') === 'off') return false
  const lead = stateValue(state, 'claude_session_id')
  return lead !== undefined && lead === (await $.session.id())
}

// One value from .cs/local/state, as cs's own readers allow it: optionally
// quoted, trailing spaces ignored.
function stateValue(state: string, key: string): string | undefined {
  return state.match(new RegExp(`^${key}: *"?([^"\\s]+)"?[ \\t]*$`, 'm'))?.[1]
}

// The tip for this turn: the one that fits the session first, then the rest
// in order, one step per turn, round and round.
async function tip($: EngineInterface): Promise<string> {
  const first = await firstTip($)
  const rest = TIPS.filter(t => t !== first)
  const { count } = await turnsOf($)
  return count === 0 ? first : rest[(count - 1) % rest.length]
}

// A worktree session (task_branch pinned in the state file) is there to be
// landed; a plain one can spawn worktrees.
async function firstTip($: EngineInterface): Promise<string> {
  const state = await readOr($, `${await $.session.cwd()}/.cs/local/state`)
  return stateValue(state, 'task_branch') !== undefined ? TIPS[1] : TIPS[0]
}

// Armed means the marker names a handoff the SessionStart hook will accept
// after the /clear: a bare basename read as the hook reads it (every
// whitespace character dropped; a separator is rejected), a file in the
// store, and frontmatter that still says unconsumed.
async function handoffArmed($: EngineInterface, cwd: string): Promise<boolean> {
  if (!(await $.fs.exists(`${cwd}/${MARKER}`))) return false
  try {
    const name = (await $.fs.read(`${cwd}/${MARKER}`)).replace(/\s+/g, '')
    if (name === '' || /[/\\]/.test(name)) return false
    return isUnconsumed(await $.fs.read(`${cwd}/${HANDOFFS}/${name}`))
  } catch {
    return false
  }
}

// The hook's own rule (_handoff_is_unconsumed in hooks/session-start.sh): a
// frontmatter block opened by `---` on the first line and CLOSED by the next
// `---`, carrying `status: unconsumed` between them. A file the closing line
// never reaches (a truncated write) is not armed.
export function isUnconsumed(text: string): boolean {
  const lines = text.split('\n')
  if (lines[0] !== '---') return false
  let matched = false
  for (const line of lines.slice(1)) {
    if (line === '---') return matched
    if (line === 'status: unconsumed') matched = true
  }
  return false
}
