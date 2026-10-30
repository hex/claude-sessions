/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-panel mod: /cs-panel opens a pane listing every cs session from `cs -list --porcelain`, read again while the pane is open and no turn runs.
// ABOUTME: The only effects of the mod: its hooks, its module state, the cs runs, and the tables of every line it hands the engine.
import type { EngineInterface, On } from 'claude-code'
import { drawPane, type Handlers } from './draw'
import { parseList, parseReadiness, retireVerdict, rowsOf, sessionName, type Action, type Pending, type RetireRoute, type Session, type SessionName } from './sessions'

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
const SPAWN_TIMEOUT_MS = 30000
const MSG_TIMEOUT_MS = 10000
// A readiness walk runs git per feature, about 1.4 s each.
const FEATURES_TIMEOUT_MS = 20000

// The mail dialog: free text under Other is the body. `$.ui.ask` wants 2-4
// labels and pads fewer with Yes/No, which would send "Yes"; so the second
// label is a real, common message rather than a filler.
export const MAIL_CANCEL = 'Cancel'
export const MAIL_STATUS = 'Ask for a status line'
export const STATUS_BODY = 'What are you on right now, and is anything blocked?'

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

export const ASKS = {
  mail: (name: string) => ({ question: `What should ${name} read? Type it under Other.`, header: 'Mail', options: [MAIL_STATUS, MAIL_CANCEL] }),
} as const

export const TOASTS = {
  // cs -spawn's own line: the window and how to attach.
  opened: (line: string) => line,
  notOpened: (name: string, why: string) => `${name} did not open: ${why}`,
  mailed: (name: string) => `mail sent to ${name}`,
  notMailed: (name: string, why: string) => `mail to ${name} not sent: ${why}`,
  retireAsked: (base: string, task: string) => `asked ${base} to /finish ${task}; it runs once ${base} accepts the task`,
  retireNotAsked: (base: string, why: string) => `${base} was not asked to retire: ${why}`,
  notRetired: (task: string, why: string) => `${task} not retired: ${why}`,
  retireNotLead: (base: string) => `${base}'s features retire from its lead conversation; this one is a teammate`,
  finishFailed: (task: string, err: string) => `/finish ${task} did not run: ${err}`,
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

// The poll: off, being armed, or running. An arming is claimed before the
// await that checks the pane is open, and arms only if its claim is still the
// poll after it: a stop or a later claim in between supersedes it, so two
// callers cannot arm two clocks and a close mid-arming arms none.
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

  // /cs-panel: open (or raise) the pane and read at once: a running poll reads
  // now, else the poll is armed afresh, superseding an arming that asked for
  // the panes before this open. `immediate`, so it opens mid-turn too: the
  // first read runs at once whatever the turn does; only the clock's reads
  // wait for idle.
  on('command.run', { command: 'cs-panel' }, async ($) => {
    launch ??= await readLaunch($)
    if (launch === undefined) return { text: REPLIES.noBin }
    const opened = await $.ui.open({ id: PANE, title: TITLE, focus: true, closeOnEscape: true, columns: DOCK_COLUMNS })
    if (poll.kind === 'on') await refresh($)
    else { stopPoll(); await startPoll($) }
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

  // Selection follows the focus ring: Tab or an arrow landing on a row selects
  // it, so the strip names that row before any key is pressed. The ring moves
  // first; a ring moved to a strip key keeps the selection.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const moved = await next(e)
    if (moved.deny === undefined && e.element?.startsWith('row:')) {
      const name = sessionName(e.element.slice('row:'.length))
      if (name !== undefined) select($, name)
    }
    return moved
  })

  // Closing the pane (Esc, its mark, a plugin) stops the poll. Rows stay, so a
  // reopen draws the last answer at once and the first read replaces it.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    stopPoll()
    return next(e)
  })

  // The idle source: the main loop's turn events (a subagent's carry
  // agentId). A turn's end may have spawned, mailed or finished something, so
  // an open pane reads at once, without holding the turn's end for it.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) working = true
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      working = false
      if (poll.kind === 'on') inBackground($, refresh($))
    }
    return next(e)
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
// reads at once. A second call while arming or on does nothing, and so does
// one whose claim was superseded during its awaits.
async function startPoll($: EngineInterface): Promise<void> {
  if (poll.kind !== 'off') return
  const claim: Poll = { kind: 'arming' }
  poll = claim
  launch ??= await readLaunch($)
  const isOpen = launch !== undefined && (await $.ui.panes()).some(p => p.id === PANE)
  if (poll !== claim) return
  if (!isOpen) { poll = { kind: 'off' }; return }
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
  return { select: name => select($, name), act: (action, name) => inBackground($, act($, action, name)) }
}

// The one entry for every strip key. The row is looked up afresh and the press
// refused when the action is no longer offered (a press from a drawing older
// than the last read). The row is claimed before the first await, so a second
// press finds nothing offered; whatever happens, it is released and the list
// read again.
async function act($: EngineInterface, action: Action, name: SessionName): Promise<void> {
  const row = sessions && rowsOf(sessions, launch?.self, pending).find(r => r.session.name === name)
  if (row === undefined || !row.actions.includes(action)) return
  pending.set(name, PRESSED[action])
  $.ui.invalidate('ui.render')
  try {
    // A switch, not a table of functions: the engine refuses `$` handed to a
    // callee it cannot name.
    switch (action) {
      case 'open': await openSession($, row.session); break
      case 'mail': await mailSession($, row.session); break
      case 'retire': await retireFeature($, row.session); break
    }
  } finally {
    pending.delete(name)
    $.ui.invalidate('ui.render')
    if (poll.kind === 'on') await refresh($)
  }
}

const PRESSED: Record<Action, Pending> = { open: 'opening', mail: 'mailing', retire: 'checking' }

// open: `cs -spawn <name>` opens a window in the cs tmux session; the toast is
// cs's own line, which names the window and how to attach.
async function openSession($: EngineInterface, s: Session): Promise<void> {
  const run = await runCs($, ['-spawn', s.name], { timeoutMs: SPAWN_TIMEOUT_MS })
  $.ui.toast(run.ok ? TOASTS.opened(lastLine(run.stdout)) : TOASTS.notOpened(s.name, run.why))
}

// mail: the body from the dialog (Other's free text, or the status line), on
// stdin to `cs <name> -msg -`, so it never reaches argv. A dismissed dialog,
// Cancel or an empty body sends nothing and says nothing.
async function mailSession($: EngineInterface, s: Session): Promise<void> {
  const ask = ASKS.mail(s.name)
  let answer: string
  try {
    answer = await $.ui.ask(ask.question, { header: ask.header, options: ask.options })
  } catch {
    return // dismissed: the person chose not to send
  }
  const body = answer === MAIL_CANCEL ? '' : answer === MAIL_STATUS ? STATUS_BODY : answer.trim()
  if (body === '') return
  const run = await runCs($, [s.name, '-msg', '-'], { stdin: body, timeoutMs: MSG_TIMEOUT_MS })
  $.ui.toast(run.ok ? TOASTS.mailed(s.name) : TOASTS.notMailed(s.name, run.why))
}

// retire: readiness on demand, then one of two routes.
//   here : this conversation is the base's lead -> /finish <task> through
//          $.command.run, as the band's press does.
//   mail : any other session -> `cs <base> -msg --kind task -` with
//          `/finish <task>` on stdin; the base's user accepts it.
// This session is the base but a teammate of it: refused, since cs refuses
// mail to the current session and /finish belongs to the lead.
async function retireFeature($: EngineInterface, s: Session): Promise<void> {
  if (s.feature === undefined) throw new Error(`cs-panel: retire pressed on ${s.name}, which is not a feature`)
  const { base, task } = s.feature
  const route: RetireRoute = base === launch?.self ? 'here' : 'mail'
  if (route === 'here' && !(await isLead($))) { $.ui.toast(TOASTS.retireNotLead(base)); return }
  const run = await runCs($, [base, '-features', '--porcelain'], { timeoutMs: FEATURES_TIMEOUT_MS })
  if (!run.ok) { $.ui.toast(TOASTS.notRetired(task, run.why)); return }
  const records = parseReadiness(run.stdout)
  if ('unreadable' in records) { $.ui.toast(TOASTS.notRetired(task, records.unreadable)); return }
  const verdict = retireVerdict(records.find(r => r.task === task), route)
  if (!verdict.go) { $.ui.toast(TOASTS.notRetired(task, verdict.why)); return }
  pending.set(s.name, 'retiring')
  $.ui.invalidate('ui.render')
  if (route === 'here') {
    await $.command.run({ command: 'finish', args: task }).catch(err => $.ui.toast(TOASTS.finishFailed(task, message(err))))
    return
  }
  const sent = await runCs($, [base, '-msg', '--kind', 'task', '-'], { stdin: `/finish ${task}`, timeoutMs: MSG_TIMEOUT_MS })
  $.ui.toast(sent.ok ? TOASTS.retireAsked(base, task) : TOASTS.retireNotAsked(base, sent.why))
}

// The lead conversation is the one whose id cs recorded in .cs/local/state
// before launching it; a teammate in the same directory has its own. No
// sessions-root identity check: the caller has already matched
// CLAUDE_SESSION_NAME, which only a cs launch sets, to the base, and a cloned
// state file cannot carry this conversation's fresh id. The id pattern is
// KEEP IN SYNC with isLead in mods/cs-update and ownsRotation in mods/cs.
async function isLead($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  if (await $.fs.exists(`${cwd}/.cs/local/disabled`)) return false
  let state: string
  try {
    state = await $.fs.read(`${cwd}/.cs/local/state`)
  } catch {
    return false // no state file: cs did not launch this directory
  }
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
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
