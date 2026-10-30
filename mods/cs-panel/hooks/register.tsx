/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-panel mod: /cs-panel opens a pane listing every cs session from `cs -list --porcelain`, read again while the pane is open and no turn runs.
// ABOUTME: The only effects of the mod: its hooks, its module state, the cs runs, and the tables of every line it hands the engine.
import type { EngineInterface, On } from 'claude-code'
import { drawPane, type Handlers } from './draw'
import { parseList, rowsOf, sessionName, type Pending, type Session, type SessionName } from './sessions'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-panel'
const TITLE = 'Sessions'
// The dock opens this wide when there is room (ignored inline): a 20-cell name
// and every column.
const DOCK_COLUMNS = 56
// How often an open pane asks cs again while no turn runs: a listing costs a
// few forks per session (about 3 s on a root of 150), and a turn's end and
// every key read it at once anyway. How long each cs run may take.
const POLL_MS = 60000
const LIST_TIMEOUT_MS = 20000

// Every line handed to an engine surface, one table per surface; none names
// the plugin first (the engine prefixes it). tests/test_mod_tables.sh greps
// this file for inline literals.
export const COMMANDS = {
  'cs-panel': { name: 'cs-panel', description: 'The cs sessions: live or idle, context, unread mail, features; open, mail or retire one.', immediate: true },
} as const

export const REPLIES = {
  noBin: 'The launch did not say where cs is (CS_BIN); open this conversation with cs to list its sessions.',
  opened: 'The sessions are in the panel: Tab moves, o opens, m mails, r retires, Esc closes.',
  notPlaced: (reason: string) => `The panel is open but not drawn yet: ${reason}`,
} as const

// Lines the pane draws above the rows when the list is stale or missing.
// `why` is runCs's: `exited <code>: <stderr's last line>`, or why it did not start.
export const PROBLEMS = {
  failed: (why: string) => `cs -list --porcelain ${why}`,
  unreadable: (line: string) => `cs -list --porcelain gave a line the panel cannot read: ${line}`,
} as const

// Work a timer or a press starts and nothing awaits.
export const LOGS = {
  failed: (err: string) => `the panel's background read failed: ${err}`,
} as const

// What the launch exported: where cs is, and the name this conversation runs
// under. Read once per load; the environment does not change under a process.
type Launch = { bin: string; self: SessionName | undefined }

// The poll: off, being armed (claimed before the await that checks the pane
// is open, so two callers cannot arm two clocks), or running.
type Poll = { kind: 'off' } | { kind: 'arming' } | { kind: 'on'; cancel: () => void }

// Module state. Reset in register(): a reload drops it and the engine cancels
// its timers; a /clear keeps it.
let launch: Launch | undefined
let sessions: Session[] | undefined
// The porcelain text `sessions` was parsed from: an identical answer redraws
// nothing.
let answered: string | undefined
let problem: string | undefined
let selected: SessionName | undefined
let pending = new Map<SessionName, Pending>()
let working = false
let reading = false
let readAgain = false
let poll: Poll = { kind: 'off' }
let registered = false

export function register(on: On) {
  launch = undefined; sessions = undefined; answered = undefined; problem = undefined
  selected = undefined; pending = new Map(); working = false; reading = false; readAgain = false
  poll = { kind: 'off' }; registered = false

  // The command, once per load. Nothing opens here: the panel opens only when
  // asked.
  on('session.start', async ($, e, next) => {
    if (!registered) {
      registered = true
      await $.command.register(COMMANDS['cs-panel'])
    }
    return next(e)
  })

  // /cs-panel: open (or raise) the pane and arm the poll afresh. `immediate`,
  // so it opens mid-turn too: the first read runs at once whatever the turn
  // does; only the clock's reads wait for idle.
  on('command.run', { command: 'cs-panel' }, async ($) => {
    launch ??= await readLaunch($)
    if (launch === undefined) return { text: REPLIES.noBin }
    const opened = await $.ui.open({ id: PANE, title: TITLE, focus: true, closeOnEscape: true, columns: DOCK_COLUMNS })
    stopPoll()
    await startPoll($)
    return { text: opened.isPlaced ? REPLIES.opened : REPLIES.notPlaced(opened.reason) }
  })

  // A render with the poll off is a pane that outlived a reload (the engine
  // re-renders an open pane the moment it reloads the module): the poll is
  // armed from a timer, since an invalidate inside a render loops, and
  // startPoll asks $.ui.panes() first so a stray render after a close arms
  // nothing.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    if (poll.kind === 'off') $.clock.after(0, () => inBackground($, startPoll($)))
    launch ??= await readLaunch($)
    const rows = sessions && rowsOf(sessions, launch?.self, pending)
    return drawPane({ rows, selected, problem, columns: e.props.bodyColumns, bodyRows: e.props.scroll.bodyRows, hasKeys: e.props.isFocused },
      $.ui.resolve(e), handlers($))
  })
}

// CS_BIN and CLAUDE_SESSION_NAME; undefined without CS_BIN. A name that is not
// a SessionName counts as no self.
async function readLaunch($: EngineInterface): Promise<Launch | undefined> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return undefined
  const name = await $.env.get('CLAUDE_SESSION_NAME')
  return { bin, self: name === undefined ? undefined : sessionName(name) }
}

// Arms the clock if the pane is open, cs is known and nothing is armed, then
// reads at once. A second call while arming or on does nothing.
async function startPoll($: EngineInterface): Promise<void> {
  if (poll.kind !== 'off') return
  poll = { kind: 'arming' }
  launch ??= await readLaunch($)
  if (launch === undefined || !(await $.ui.panes()).some(p => p.id === PANE)) { poll = { kind: 'off' }; return }
  const timer = $.clock.every(POLL_MS, () => { if (!working) inBackground($, refresh($)) })
  poll = { kind: 'on', cancel: timer.cancel }
  await refresh($)
}

function stopPoll(): void {
  if (poll.kind === 'on') poll.cancel()
  poll = { kind: 'off' }
}

// One `cs -list --porcelain`, single-flight: a read asked for while one runs
// runs once more after it, so an action's effect is never lost to a read that
// started before it. Redraws only when the text or the problem changed. A
// failed or unreadable answer keeps the last rows and says why above them.
async function refresh($: EngineInterface): Promise<void> {
  if (reading) { readAgain = true; return }
  reading = true
  try {
    do {
      readAgain = false
      const run = await runCs($, ['-list', '--porcelain'], { timeoutMs: LIST_TIMEOUT_MS })
      let next = problem
      if (!run.ok) next = PROBLEMS.failed(run.why)
      else if (run.stdout === answered) next = undefined
      else {
        const parsed = parseList(run.stdout)
        if ('unreadable' in parsed) next = PROBLEMS.unreadable(parsed.unreadable)
        else { sessions = parsed; answered = run.stdout; next = undefined; $.ui.invalidate('ui.render') }
      }
      if (next !== problem) { problem = next; $.ui.invalidate('ui.render') }
    } while (readAgain)
  } finally {
    reading = false
  }
}

function select($: EngineInterface, name: SessionName): void {
  if (name === selected) return
  selected = name
  $.ui.invalidate('ui.render')
}

function handlers($: EngineInterface): Handlers {
  return { select: name => select($, name), act: () => {} }
}

// Work nothing awaits (a timer's, a press's) reports a failure in the
// transcript rather than vanishing.
function inBackground($: EngineInterface, work: Promise<void>): void {
  work.catch(err => $.ui.log(LOGS.failed(message(err))))
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// Every cs run goes through here: the launch's CS_BIN, an argv, no shell. One
// shape for success and one for failure, so each toast and problem line says
// a failure the same way.
type CsRun = { ok: true; stdout: string } | { ok: false; why: string }
async function runCs($: EngineInterface, args: readonly string[], init: { stdin?: string; timeoutMs: number }): Promise<CsRun> {
  if (launch === undefined) throw new Error(`cs-panel: cs ${args.join(' ')} asked before the launch was read`)
  try {
    const r = await $.process.run([launch.bin, ...args], init)
    return r.exitCode === 0 ? { ok: true, stdout: r.stdout } : { ok: false, why: `exited ${r.exitCode}: ${lastLine(r.stderr)}` }
  } catch (err) {
    return { ok: false, why: `did not run: ${message(err)}` }
  }
}

function lastLine(text: string): string {
  return text.split('\n').filter(line => line.trim() !== '').at(-1) ?? ''
}
